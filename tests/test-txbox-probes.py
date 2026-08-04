#!/usr/bin/env python3
"""txbox 沙箱的探针必须能被确定性地停下来。

每个 Box 会起三个真探针线程(1 个 UDP DNS 应答器 + 2 个 TCP 监听)。以前 `clean()` 只关
socket, 不保存也不 join 线程 —— 而在 Linux 上, 关闭 fd **不会**唤醒另一个线程里阻塞的
`recvfrom()` / `accept()`。于是每个 Box 留下 3 个永远醒不来的线程: 建 30 个 Box 之后进程
里有 91 个线程, 再等多久也不会减。

这不是"看着不舒服"的问题: 一个测试进程里跑几十笔事务是常态, 线程、socket 与 fd 就这么
一直堆着, 而堆到什么程度会出事没人说得清 —— 说不清本身就是要修的理由。

判据都落在**真实资源**上: 线程对象活没活、端口还听不听、临时目录还在不在。不看实现细节,
所以换一种停法也照样能验。
"""
import os
import socket
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from txbox import Box, load_tx  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   %s" % m); PASS[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL[0] += 1


def others():
    """当前除主线程外还活着的线程集合。"""
    me = threading.current_thread()
    return {t for t in threading.enumerate() if t is not me}


def wait_gone(threads, deadline=8.0):
    """等这批线程退出; 返回超时后仍活着的。"""
    end = time.time() + deadline
    while time.time() < end:
        alive = [t for t in threads if t.is_alive()]
        if not alive:
            return []
        time.sleep(0.05)
    return [t for t in threads if t.is_alive()]


def port_open(port, kind="tcp"):
    if kind == "tcp":
        s = socket.socket()
        s.settimeout(1.0)
        try:
            return s.connect_ex(("127.0.0.1", port)) == 0
        finally:
            s.close()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.0)
    try:
        s.sendto(b"\x12\x34" + b"\x00" * 10, ("127.0.0.1", port))
        s.recvfrom(512)
        return True
    except OSError:
        return False
    finally:
        s.close()


def tmpdirs():
    return [d for d in os.listdir("/tmp") if d.startswith("pdgtx-box.")]


def main():
    base_threads = others()
    base_tmp = set(tmpdirs())
    print("── 1. 三个真探针都能用 ──")
    b = Box()
    born = others() - base_threads
    if len(born) == 3:
        ok("一个 Box 起了 3 个探针线程")
    else:
        bad("探针线程数不对: %d(期望 3)" % len(born))
    tx = load_tx(b.env)
    if tx._dns_answers("127.0.0.1", b.dns_port, timeout=2.0):
        ok("UDP DNS 应答器真的在答(走生产 _dns_answers)")
    else:
        bad("DNS 应答器没答")
    if tx._tcp_listening(b.redir_port) and tx._tcp_listening(b.dot_port):
        ok("两个 TCP 监听真的在听(走生产 _tcp_listening)")
    else:
        bad("TCP 监听没起来: redir=%s dot=%s"
            % (tx._tcp_listening(b.redir_port), tx._tcp_listening(b.dot_port)))

    print()
    print("── 2. clean() 之后三个线程都要退出 ──")
    ports = (b.dns_port, b.redir_port, b.dot_port)
    b.clean()
    stuck = wait_gone(born)
    if not stuck:
        ok("clean() 后 3 个探针线程全部退出")
    else:
        bad("clean() 后仍有 %d 个线程活着(等了 8 秒)" % len(stuck))

    print()
    print("── 3. 清理后端口不再监听 ──")
    still = []
    if port_open(ports[1], "tcp"):
        still.append("redir:%d" % ports[1])
    if port_open(ports[2], "tcp"):
        still.append("dot:%d" % ports[2])
    if port_open(ports[0], "udp"):
        still.append("dns:%d" % ports[0])
    if not still:
        ok("三个端口都不再应答")
    else:
        bad("这些端口还活着: %s" % ", ".join(still))

    print()
    print("── 4. 停掉探针后, 生产健康检查必须真的失败 ──")
    b2 = Box()
    tx2 = load_tx(b2.env)
    pre = (tx2._dns_answers("127.0.0.1", b2.dns_port, timeout=2.0),
           tx2._tcp_listening(b2.redir_port))
    dns_p, redir_p = b2.dns_port, b2.redir_port
    b2.stop_probes()
    post = (tx2._dns_answers("127.0.0.1", dns_p, timeout=2.0),
            tx2._tcp_listening(redir_p))
    if pre == (True, True) and post == (False, False):
        ok("停探针前健康检查通过, 停掉之后**真的失败**(判据没有被架空)")
    else:
        bad("停探针前后不对: 前 %s 后 %s" % (pre, post))

    print()
    print("── 5. stop_probes() / clean() 可重复调用 ──")
    try:
        b2.stop_probes()
        b2.stop_probes()
        b2.clean()
        b2.clean()
        ok("重复调用 stop_probes()/clean() 不报错")
    except Exception as e:  # noqa: BLE001
        bad("重复调用报错了: %r" % (e,))

    print()
    print("── 6. 某个探针已提前退出时, 其余资源仍要清干净 ──")
    b3 = Box()
    born3 = others() - base_threads - {t for t in others() if not t.is_alive()}
    born3 = {t for t in others() if t not in base_threads}
    # 手动关掉其中一个 socket: 那个线程会自己退出, 另外两个还在。
    if getattr(b3, "_probes", None):
        try:
            b3._probes[0].close()
        except OSError:
            pass
    time.sleep(0.5)
    try:
        b3.clean()
        stuck3 = wait_gone(born3)
        if not stuck3:
            ok("一个探针提前退出后, clean() 仍把其余线程收干净")
        else:
            bad("还剩 %d 个线程" % len(stuck3))
    except Exception as e:  # noqa: BLE001
        bad("提前退出的情况下 clean() 抛了: %r" % (e,))

    print()
    print("── 7. 连续 50 个 Box: 线程数回到基线 ──")
    peak = 0
    for _ in range(50):
        bx = Box()
        tx3 = load_tx(bx.env)
        tx3._dns_answers("127.0.0.1", bx.dns_port, timeout=1.0)   # 真用一下
        bx.clean()
        peak = max(peak, threading.active_count())
    left = others() - base_threads
    left = {t for t in left if t.is_alive()}
    if not left:
        ok("50 个 Box 建了又清, 线程数回到基线(峰值 %d)" % peak)
    else:
        bad("50 个 Box 之后残留 %d 个线程(峰值 %d)" % (len(left), peak))

    print()
    print("── 8. 不留临时目录 ──")
    leaked = set(tmpdirs()) - base_tmp
    if not leaked:
        ok("没有残留 pdgtx-box.* 临时目录")
    else:
        bad("残留 %d 个临时目录: %s" % (len(leaked), sorted(leaked)[:3]))

    print("─" * 40)
    total = PASS[0] + FAIL[0]
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    if total == 0:
        print("零断言 —— 判失败")
        return 1
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

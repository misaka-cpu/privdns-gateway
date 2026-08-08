#!/usr/bin/env python3
"""救援平面的 socket 交接与抗畸形请求回归(5.2)。

真机上监听口由 systemd 持有(socket activation), 服务只是接管一个已经在监听的 fd。这条路径
以前没测过 —— 它恰恰是"服务崩了监听口还在"的基础, 而写错的表现是: 服务自己又 bind 一个,
机器上出现两个救援入口, 用户连上哪个全看运气。

这里不需要真 systemd: 父测试自己建监听 socket, 按 systemd 的约定(fd 3 + LISTEN_FDS +
LISTEN_PID)交给子进程, 然后**通过那个 socket 发一次真实 HTTPS 请求**。真 systemd 的端到端
验证仍留到 commit 10。

另外补上一条硬要求: 大量畸形/超长请求、错误 TLS、连续认证失败都不得把进程搞崩 —— 登录限速
只在内存里, 进程一崩计数就清零, 那样攻击者靠"打崩再重启"就能绕过限速。
"""
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from rescuebox import Inst, TOKEN  # noqa: E402

RESCUE = os.path.join(ROOT, "deploy/rescue/rescue.py")
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


work = tmpguard.mkdtemp(prefix="rescue-sock.")


def make_env(inst, **over):
    e = inst.env()
    e.pop("PDG_RESCUE_BIND", None)          # 交接模式下不需要自己绑
    e.update(over)
    return e


# 子进程包装: dup2 到 fd 3, 再把 LISTEN_PID 设成**自己的** pid(exec 保留 pid, 与 systemd 同义)
WRAP = ("import os, sys\n"
        "os.dup2(int(sys.argv[1]), 3)\n"
        "os.set_inheritable(3, True)\n"
        "os.environ['LISTEN_FDS'] = os.environ.get('PDG_TEST_FDS', '1')\n"
        "os.environ['LISTEN_PID'] = os.environ.get('PDG_TEST_PID') or str(os.getpid())\n"
        "os.execve(sys.executable, [sys.executable, sys.argv[2]], os.environ)\n")


def spawn_with_fd(inst, lsock, env_over=None, dup_target=True):
    env = make_env(inst, **(env_over or {}))
    args = [sys.executable, "-c", WRAP, str(lsock.fileno() if dup_target else 0), RESCUE]
    return subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, pass_fds=(lsock.fileno(),))


def wait_dead(p, timeout=6.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if p.poll() is not None:
            return True
        time.sleep(0.1)
    return False


def stop(p):
    if p.poll() is None:
        p.send_signal(signal.SIGTERM)
        try:
            p.wait(timeout=8)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=8)
    try:
        return p.stdout.read() or ""
    finally:
        p.stdout.close()


# ── A1. 正常交接: 接管现有 fd, 不再 bind, 并能真的服务请求 ──────────────────
inst = Inst(work)
lsock = socket.socket()
lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
lsock.bind(("127.0.0.1", inst.port))
lsock.listen(16)
lsock.set_inheritable(True)
proc = spawn_with_fd(inst, lsock)
ready = False
t0 = time.time()
while time.time() - t0 < 8:
    if proc.poll() is not None:
        break
    try:
        c = socket.create_connection(("127.0.0.1", inst.port), timeout=0.3)
        c.close()
        ready = True
        break
    except OSError:
        time.sleep(0.1)
if ready:
    ok("socket 交接: 子进程接管 fd 3 并开始服务")
else:
    bad("交接后没起来: %r" % (stop(proc) or "")[:300])

# 真的走这个 socket 发一次 HTTPS 请求(而不是只看进程活着)
if ready:
    inst.proc = proc                      # 借用 Inst 的请求封装
    st, body, _sc, _h = inst.req("GET", "/")
    if st == 200 and "救援 Token" in body:
        ok("socket 交接: 通过交接来的监听口完成了一次真实 HTTPS 请求")
    else:
        bad("交接后的请求不对: st=%s" % st)
    st2, cookie = inst.login()
    st3, body3, _sc, _h = inst.req("GET", "/", cookie=cookie)
    if st2 == 200 and st3 == 200 and "状态总览" in body3:
        ok("socket 交接: 认证与状态页在交接模式下同样工作")
    else:
        bad("交接模式下登录/状态页异常: %s/%s" % (st2, st3))
    log = ""
    # 日志里应写明走的是 socket activation(便于现场判断监听口归谁)
    inst.proc = None
    log = stop(proc)
    if "socket activation" in log:
        ok("socket 交接: 日志写明监听口来自 socket activation")
    else:
        bad("日志没说明交接模式: %r" % log[-200:])
lsock.close()

# ── A2. 四种不自洽 → 必须拒绝启动, 不许退回自行绑定 ────────────────────────
def refuse_case(label, env_over, use_fd=True, want=None):
    i2 = Inst(work)
    ls = None
    if use_fd:
        ls = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("127.0.0.1", i2.port))
        ls.listen(8)
        ls.set_inheritable(True)
        p = spawn_with_fd(i2, ls, env_over)
    else:
        # fd 3 指向一个**普通文件**(不是 socket)
        f = open(os.path.join(work, "notasocket.txt"), "w+")
        env = make_env(i2, **(env_over or {}))
        args = [sys.executable, "-c", WRAP, str(f.fileno()), RESCUE]
        p = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             universal_newlines=True, pass_fds=(f.fileno(),))
        f.close()
    died = wait_dead(p)
    out = stop(p)
    # 还要确认它**没有**自己 bind 一个新的监听口
    selfbound = False
    if not use_fd:
        try:
            probe = socket.create_connection(("127.0.0.1", i2.port), timeout=0.3)
            probe.close()
            selfbound = True
        except OSError:
            pass
    if ls:
        ls.close()
    if died and (want is None or want in out) and not selfbound:
        ok("拒绝启动: %s" % label)
    else:
        bad("%s 未被拒绝(died=%s selfbound=%s out=%r)" % (label, died, selfbound, out[-160:]))


refuse_case("LISTEN_PID 不是本进程", {"PDG_TEST_PID": "999999"}, want="不是本进程")
refuse_case("LISTEN_FDS 非法(非数字)", {"PDG_TEST_FDS": "abc"}, want="不是数字")
refuse_case("LISTEN_FDS 数量不对", {"PDG_TEST_FDS": "3"}, want="恰好 1 个")
refuse_case("fd 3 不是 socket", {}, use_fd=False, want="不是 socket")

# LISTEN_PID/LISTEN_FDS 只给一个
i3 = Inst(work)
p3 = subprocess.Popen([sys.executable, RESCUE], env=make_env(i3, LISTEN_FDS="1"),
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
d3 = wait_dead(p3)
o3 = stop(p3)
if d3 and "只给了一个" in o3:
    ok("拒绝启动: 只设了 LISTEN_FDS 而没有 LISTEN_PID")
else:
    bad("单个环境变量未被拒绝: %r" % o3[-160:])

# 两个都不设 → 正常自行绑定(不能把普通启动也拒了)
i4 = Inst(work)
if i4.start():
    ok("两个变量都不存在 → 正常自行绑定(普通启动不受影响)")
else:
    bad("普通启动被误拒: %r" % (i4.err or "")[:200])
i4.stop()

# ── A3. 收尾: 没有残留进程/临时文件 ────────────────────────────────────────
time.sleep(0.3)
alive = []
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")[:-1]
    except OSError:
        continue
    if argv and b"python" in argv[0] and any(b"rescue.py" in a for a in argv[1:]):
        alive.append(pid)
if not alive:
    ok("收尾: 没有残留的救援进程")
else:
    bad("残留进程: %s" % alive)

# ── B. 抗畸形请求: 打不崩(否则重启就能清掉内存里的限速计数)──────────────────
inst5 = Inst(work)
if not inst5.start():
    bad("抗压实例起不来")
else:
    port = inst5.port
    ctx = ssl._create_unverified_context()

    def raw(payload, tls=True, timeout=3):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
            if tls:
                s = ctx.wrap_socket(s)
            s.sendall(payload)
            try:
                s.recv(256)
            except OSError:
                pass
            s.close()
        except (OSError, ssl.SSLError):
            pass

    # 1) 明文打 TLS 口 / 垃圾字节 / 半截握手
    for _ in range(20):
        raw(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n", tls=False)
        raw(b"\x16\x03\x01\x00\x05rubbish", tls=False)
        raw(os.urandom(64), tls=False)
    # 2) 畸形 HTTP: 超长请求行/头、非法方法、错版本、超大 body 声明
    raw(b"GET /" + b"A" * 100000 + b" HTTP/1.1\r\n\r\n")
    raw(b"BREW / HTTP/1.1\r\nHost: x\r\n\r\n")
    raw(b"GET / HTTP/9.9\r\n\r\n")
    raw(b"POST /login HTTP/1.1\r\nContent-Length: 99999999\r\n\r\nshort")
    raw(b"POST /login HTTP/1.1\r\nContent-Length: notanumber\r\n\r\n")
    raw(b"GET / HTTP/1.1\r\n" + b"X-Pad: y\r\n" * 5000 + b"\r\n")
    raw(b"\r\n\r\n\r\n")
    # 3) 连续认证失败(限速路径也要扛住)
    for i in range(30):
        try:
            inst5.req("POST", "/login", body="csrf=x&token=bad-%d" % i)
        except Exception:  # noqa: BLE001
            pass
    time.sleep(0.5)
    if inst5.proc.poll() is None:
        ok("抗畸形请求: 上百个畸形/超长/错 TLS/认证失败请求之后进程仍然活着")
    else:
        bad("进程被打崩了(退出码 %s) —— 重启即可清空内存限速计数" % inst5.proc.poll())
    # 崩没崩之外, 还要确认它仍然**能正常服务**
    st, cookie5 = inst5.login()
    st6, body6, _sc, _h = inst5.req("GET", "/", cookie=cookie5)
    if st == 200 and st6 == 200 and "状态总览" in body6:
        ok("抗畸形请求: 之后仍能正常登录并返回状态页")
    else:
        bad("被打过之后服务不正常: %s/%s" % (st, st6))
inst5.stop()

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

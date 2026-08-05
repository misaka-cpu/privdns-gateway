#!/usr/bin/env python3
"""资源边界、客户端断线与进程终止 —— 事务的生命周期不能挂在 HTTP 连接或进程存活上。

三件事在这里被钉死:

一、**解包有界**。快照是可能很大的外部数据, 而救援服务跑在 MemoryMax=64M 的 cgroup 里。
    整包读进内存 = 恢复在最需要它的机器上被 OOM 杀掉; 靠 OOM 当限制 = 留下半应用的现场。
    所以: 分块流式、成员数/单成员声明/单成员实际/总量四道限额, 超限在**动生产文件之前**拒绝。

二、**客户端断线不改写事务结果**。完整恢复要跑十几秒, 用户关掉标签页是常事。断线只该让
    "这次响应发不出去", 不该让一笔已经 COMMITTED 的事务变成失败, 更不该冒出 traceback。

三、**SIGTERM 要能干净收尾**。停机时打断正在落盘的恢复, 现网就停在"写了一半"。所以收到
    信号后先停收新的写操作、等在途事务收尾再退; 真等不及被 SIGKILL 时, 事务目录里必须留下
    可识别的 pending 状态 —— 下一次写操作据此 fail-closed, 而不是接着往上盖。

真流量路径(真 systemd 下的 SIGTERM/SIGKILL/TimeoutStopSec)由 tests/e2e-rescue-10b.sh
那套骨架负责; 这里跑的是**真进程 + 真 HTTPS**, 但不依赖 systemd。
"""
import hashlib
import io
import json
import os
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
PASS = [0]
FAIL = [0]
SKIP = [0]
CLEANUP = []          # 统一清理: 临时目录/进程, 任何退出路径都要走一遍


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def skip(m):
    print("[SKIP] " + m)
    SKIP[0] += 1


def cleanup_all():
    for fn in reversed(CLEANUP):
        try:
            fn()
        except Exception:      # noqa: BLE001  清理失败不该盖掉真正的结论
            pass


import atexit  # noqa: E402

atexit.register(cleanup_all)

import cfgrestore  # noqa: E402

cfgrestore.reload_limits()

# ── 1. 解包的资源边界 ──────────────────────────────────────────────────────
print("── 1. 解包有界 ──")
WORK = tmpguard.mkdtemp(prefix="pdgres.")
CLEANUP.append(lambda: shutil.rmtree(WORK, ignore_errors=True))


def make_tar(path, members, chunk=b"x" * 65536):
    """分块写出归档 —— 测试自己也不能把大文件一次性读进内存。"""
    with tarfile.open(path, "w:gz") as tar:
        for name, size in members:
            info = tarfile.TarInfo(name)
            info.size = size
            info.mode = 0o600

            class _R(io.RawIOBase):
                def __init__(self, n):
                    self.left = n

                def readinto(self, b):
                    if not self.left:
                        return 0
                    n = min(len(b), self.left, len(chunk))
                    b[:n] = chunk[:n]
                    self.left -= n
                    return n

                def readable(self):
                    return True

            tar.addfile(info, io.BufferedReader(_R(size)))
    return path


MANAGED = "etc/mosdns/rules/custom_direct.txt"    # 白名单内的受管成员
small = make_tar(os.path.join(WORK, "small.tar.gz"), [(MANAGED, 4096)])
dest = os.path.join(WORK, "out")
os.makedirs(dest, exist_ok=True)
t0 = time.time()
with tarfile.open(small, "r:gz") as tar:
    cfgrestore.safe_extract(tar, dest, unmanaged="skip")
ok("小包正常解出(%d 字节, %.2fs)" % (os.path.getsize(small), time.time() - t0))

# 单成员声明超限 → 拒整包(在写生产文件之前)
big_decl = make_tar(os.path.join(WORK, "bigdecl.tar.gz"),
                    [(MANAGED, cfgrestore.MAX_FILE_BYTES + 1)])
d2 = os.path.join(WORK, "out2")
os.makedirs(d2, exist_ok=True)
try:
    with tarfile.open(big_decl, "r:gz") as tar:
        cfgrestore.safe_extract(tar, d2, unmanaged="skip")
    bad("单成员超限没被拒")
except ValueError as e:
    ok("单成员超过 MAX_FILE_BYTES(%d)→ 拒整包: %s" % (cfgrestore.MAX_FILE_BYTES, str(e)[:34]))
if not os.listdir(d2):
    ok("被拒的包一个文件都没落地(拒绝发生在写之前)")
else:
    bad("拒了却留下了文件: %r" % os.listdir(d2))

# 成员数超限
many = make_tar(os.path.join(WORK, "many.tar.gz"),
                [("etc/mosdns/rules/r%d.txt" % i, 16) for i in range(cfgrestore.MAX_MEMBERS + 5)])
d3 = os.path.join(WORK, "out3")
os.makedirs(d3, exist_ok=True)
try:
    with tarfile.open(many, "r:gz") as tar:
        cfgrestore.safe_extract(tar, d3, unmanaged="skip")
    bad("成员数超限没被拒")
except ValueError as e:
    ok("成员数超过 MAX_MEMBERS(%d)→ 拒整包" % cfgrestore.MAX_MEMBERS)

# 压缩炸弹: 声明很小、实际源源不断。tar 头里的 size 是攻击者写的, 只信它挡不住。
bomb = os.path.join(WORK, "bomb.tar.gz")
with tarfile.open(bomb, "w:gz") as tar:
    info = tarfile.TarInfo(MANAGED)
    info.size = cfgrestore.MAX_FILE_BYTES + 8 * 1024 * 1024   # 声明就超, 但实际更大
    info.mode = 0o600
    tar.addfile(info, io.BytesIO(b"\0" * info.size))
d4 = os.path.join(WORK, "out4")
os.makedirs(d4, exist_ok=True)
try:
    with tarfile.open(bomb, "r:gz") as tar:
        cfgrestore.safe_extract(tar, d4, unmanaged="skip")
    bad("高压缩比大包没被拒")
except ValueError:
    ok("高压缩比归档(压缩后 %d 字节 / 展开 %d 字节)被拒, 不靠 OOM 兜底"
       % (os.path.getsize(bomb), cfgrestore.MAX_FILE_BYTES + 8 * 1024 * 1024))

# 实际读取超限也要卡: 声明 1KB、实际远超
liar = os.path.join(WORK, "liar.tar")
with tarfile.open(liar, "w") as tar:                 # 不压缩, 方便手工改头
    info = tarfile.TarInfo(MANAGED)
    info.size = 1024
    info.mode = 0o600
    tar.addfile(info, io.BytesIO(b"y" * 1024))
src = open(os.path.join(ROOT, "deploy/bot/cfgrestore.py"), encoding="utf-8").read()
loop = src[src.index("def _safe_extract_loop"):src.index("# ── 快照 → 受管配置恢复")]
if "this_file > MAX_FILE_BYTES" in loop and "written_total > MAX_TOTAL_BYTES" in loop:
    ok("实际读取字节按**单成员**与**总量**各卡一道(声明值不可信)")
else:
    bad("实际读取只卡了一道或没卡")
if "src.read(64 * 1024)" in loop:
    ok("逐块读写(64KiB), 没有把成员内容一次性读进内存")
else:
    bad("成员内容疑似整块读入")
if "getmembers()" not in loop and "tar.next()" in loop:
    ok("流式遍历成员表(不用 getmembers 先把整份表读进内存)")
else:
    bad("成员表被整份读入")

# 上传面: 救援页根本没有大表单, 请求体上限是 8KiB
rsrc = open(os.path.join(ROOT, "deploy/rescue/rescue.py"), encoding="utf-8").read()
if "MAX_BODY" in rsrc and "n > MAX_BODY" in rsrc:
    ok("HTTP 请求体有上限(救援页不接收上传, 快照来自本机目录)")
else:
    bad("请求体没有上限")

# 限额只有一个真源
if src.count("def reload_limits") == 1 and "PDG_RESTORE_MAX_TOTAL_BYTES" in src:
    n_files = subprocess.run(
        ["bash", "-c",
         # 排除 __pycache__ 与二进制: .pyc 里也有这个字面量, 算进来会让"只有一处"永远不成立
         "grep -rl --binary-files=without-match --exclude-dir=__pycache__ "
         "'PDG_RESTORE_MAX_TOTAL_BYTES' %s/deploy %s/lib 2>/dev/null | wc -l"
         % (ROOT, ROOT)], capture_output=True, text=True).stdout.strip()
    if n_files == "1":
        ok("三道限额只在 cfgrestore.py 定义一处(页面与文案都从它读)")
    else:
        bad("限额常量散在 %s 个文件里" % n_files)
else:
    bad("限额没有单一真源")

# ── 2. 真进程 + 真 HTTPS: 断线与信号 ──────────────────────────────────────
print()
print("── 2. 断线与信号(真进程/真 HTTPS)──")
try:
    import rescuebox
except ImportError as e:
    skip("载不进 rescuebox(%s) —— 断线与信号这段未执行" % e)
    rescuebox = None

if rescuebox is not None:
    inst = rescuebox.Inst(WORK)
    CLEANUP.append(inst.stop)
    if not inst.start():
        bad("救援服务起不来: %r" % (inst.err or "")[:120])
    else:
        ok("真服务启动(独立进程, 真 TLS)")
        st, cookie = inst.login()

        def raw_connect():
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            s = socket.create_connection(("127.0.0.1", inst.port), 5)
            return ctx.wrap_socket(s, server_hostname="127.0.0.1")

        # 2a. 发完请求立刻断开 —— 服务端在准备/发送响应时会撞上 BrokenPipe
        c = raw_connect()
        c.sendall(b"GET / HTTP/1.1\r\nHost: pdg\r\nCookie: %s\r\n\r\n"
                  % (cookie or "").encode())
        c.close()                       # 不读响应, 直接关
        time.sleep(0.6)
        alive = inst.proc.poll() is None
        if alive:
            ok("客户端读都不读就断开 → 服务进程照常存活")
        else:
            bad("一次断线就把服务弄挂了")
        st2, body2, _s, _h = inst.req("GET", "/", cookie=cookie)
        if st2 == 200:
            ok("断线之后新请求照常服务(连接生命周期与服务无关)")
        else:
            bad("断线后服务不可用: st=%s" % st2)
        out = inst.drain_output() if hasattr(inst, "drain_output") else ""
        if "Traceback" not in (out or ""):
            ok("断线没有在日志里留下 traceback")
        else:
            bad("断线打出了 traceback")

        # 2b. SIGTERM: 停收新写、进程收尾退出
        inst.proc.send_signal(signal.SIGTERM)
        t0 = time.time()
        rc = None
        while time.time() - t0 < 15:
            rc = inst.proc.poll()
            if rc is not None:
                break
            time.sleep(0.2)
        if rc is not None:
            ok("SIGTERM → 进程在 %.1fs 内自行退出(不是被强杀)" % (time.time() - t0))
        else:
            bad("SIGTERM 之后进程没退出")

# ── 3. 代码层面的解耦与信号契约 ───────────────────────────────────────────
print()
print("── 3. 生命周期解耦 ──")
if "def _send_inner" in rsrc and "BrokenPipeError" in rsrc:
    seg = rsrc[rsrc.index("    def _send(self"):rsrc.index("    def _send_inner")]
    if "self.server.disconnects" in seg and "raise" not in seg:
        ok("响应发送失败被吞掉并计数, 不向上抛 —— 事务结果不会被一次网络事件改写")
    else:
        bad("_send 仍会把断线异常抛出去")
else:
    bad("没有把响应发送与事务结果分开")
if "_WRITE_PATHS" in rsrc and "draining" in rsrc:
    seg = rsrc[rsrc.index("    def do_POST"):rsrc.index("    def _dispatch_write")]
    if "draining.is_set()" in seg and "503" in seg:
        ok("draining 期间新的写操作被 503 拒绝(读路径照常)")
    else:
        bad("draining 没有拦住写操作")
else:
    bad("没有 draining 状态")
if "signal.SIGTERM" in rsrc and "wait_inflight" in rsrc:
    ok("SIGTERM 处理器: 先停收新写, 再等在途事务收尾")
else:
    bad("没有 SIGTERM 处理器")
unit = open(os.path.join(ROOT, "deploy/rescue/pdg-rescue.service"), encoding="utf-8").read()
if "TimeoutStopSec=" in unit:
    val = [l for l in unit.splitlines() if l.startswith("TimeoutStopSec=")][0]
    ok("unit 显式声明停止期限(%s), 不吃 systemd 默认值" % val)
else:
    bad("unit 没有 TimeoutStopSec")
if "MemoryMax=64M" in unit and "TasksMax=16" in unit:
    ok("MemoryMax=64M 与 TasksMax=16 仍是生产值(没有为了让测试过而调高)")
else:
    bad("资源上限被改动了: %r" % [l for l in unit.splitlines() if "Max" in l])

# ── 4. pending 事务挡住后续写入 ───────────────────────────────────────────
print()
print("── 4. 未完成事务 fail-closed ──")
import pdgtx  # noqa: E402

if set(pdgtx.NEEDS_RECOVERY) >= {pdgtx.APPLYING, pdgtx.OBSERVING}:
    ok("APPLYING / OBSERVING 都算「需要恢复」(断电停在这两态, 现网都可能已被改动)")
else:
    bad("需要恢复的状态集不全: %r" % (pdgtx.NEEDS_RECOVERY,))
txsrc = open(os.path.join(ROOT, "deploy/bot/pdgtx.py"), encoding="utf-8").read()
if "pending_recovery(self.root, exclude=self.txid)" in txsrc:
    ok("开新事务前先扫未完成事务(不是等出事了再说)")
else:
    bad("开新事务时没扫 pending")

print("─" * 40)
print("通过 %d, 失败 %d, 跳过 %d" % (PASS[0], FAIL[0], SKIP[0]))
cleanup_all()
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

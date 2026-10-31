#!/usr/bin/env python3
"""install.sh 从管道读进来时, bash 必须先把整份脚本读完, 再执行第一行。

README 一键安装是 `curl -fsSL <raw>/install.sh | sudo bash`。bash 从管道逐行读脚本, 读到自举那几行
(约 3.4 KB)就 exec 到第二段, 管道里剩下的没人读。脚本比管道缓冲(64 KiB)大, curl 就写不完 ——
报 "(23) Failure writing output to destination" 并以 23 退出(2026-10-31 照 README 一键安装实测,
合成复现 9/9, 60000 字节的对照 6/6 不出现)。开了 pipefail 的自动化会把装好了的机器判成安装失败。

修法是把整份脚本包进 { … }: bash 要读到配对的 } 才开始执行。这里不看写法, 只看行为:
  · 把 install.sh 原样从管道喂给 bash, 测试自己留着管道读端的一份副本;
  · 以非 root 运行, 脚本必定死在第一道门「请用 root 运行」—— 那之前的代码只是赋值、定义函数、
    解析参数, 没有副作用;
  · bash 退出之后, 从副本读端把管道里剩下的读出来: 剩 0 字节 = bash 在执行之前读完了整份脚本。
    没包起来时, bash 读到那道门就执行、退出, 后面几十 KB 留在管道里。
判据只看"剩下多少字节", 不依赖脚本有多大, 也不依赖管道缓冲是多少。
"""
import os
import subprocess
import sys
import threading

import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.environ.get("PDG_INSTALL_SH") or os.path.join(ROOT, "install.sh")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def finish():
    print("-" * 62)
    print("test-install-pipe-readall.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


data = open(INSTALL, "rb").read()
print("── install.sh: %s, %d 字节 ──" % (INSTALL, len(data)))
if not data:
    bad("install.sh 是空的 —— 判据会空对空成立, 不往下测")
    finish()

# root 下脚本会过第一道门、真去装 —— 那就降到 nobody 跑; 降不了就不跑(不拿 SKIP 冒充通过)。
cmd = ["bash"]
if os.geteuid() == 0:
    cmd = ["setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", "bash"]

work = tmpguard.mkdtemp(prefix="pdgtx-pipe-readall.")
os.chmod(work, 0o755)
env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": work, "LC_ALL": "C.UTF-8"}

r, w = os.pipe()
keep = os.dup(r)                 # 测试自己的读端副本: bash 退了管道也不会断, 剩下的还能读出来
wrote = [0]
werr = [None]


def writer():
    try:
        mv = memoryview(data)
        while wrote[0] < len(data):
            wrote[0] += os.write(w, mv[wrote[0]:wrote[0] + 4096])
    except OSError as e:     # noqa: PERF203
        werr[0] = e
    finally:
        os.close(w)


t = threading.Thread(target=writer, daemon=True)
t.start()
try:
    p = subprocess.run(cmd, stdin=r, cwd=work, env=env, capture_output=True, timeout=60)
except FileNotFoundError as e:
    bad("起不了 bash(%s)" % e)
    finish()
os.close(r)

# bash 已经退出; 把写端剩下的写完(读端副本还开着, 写端不会挨 EPIPE), 再读出管道里剩的
leftover = 0
os.set_blocking(keep, False)
while True:
    try:
        chunk = os.read(keep, 65536)
    except BlockingIOError:
        if not t.is_alive():
            try:
                chunk = os.read(keep, 65536)
            except BlockingIOError:
                break
        else:
            t.join(0.05)
            continue
    if not chunk:
        break
    leftover += len(chunk)
t.join(10)
os.close(keep)

err = p.stderr.decode("utf-8", "replace")
print("── bash 退出码 %d; 写端写入 %d / %d 字节; 管道里剩 %d 字节 ──" % (p.returncode, wrote[0], len(data), leftover))

if werr[0] is None and wrote[0] == len(data):
    ok("写端把整份脚本写进了管道(%d 字节)" % len(data))
else:
    bad("写端没写完: %d / %d 字节(%s)" % (wrote[0], len(data), werr[0]))

if "请用 root 运行" in err and p.returncode == 1:
    ok("bash 执行到了第一道门并按预期退出(非 root → 「请用 root 运行」, 退出码 1)")
else:
    bad("bash 没按预期停在第一道门: 退出码 %d, stderr 末尾: %r" % (p.returncode, err[-300:]))

if leftover == 0:
    ok("bash 在执行之前读完了整份脚本(管道里剩 0 字节)")
else:
    bad("管道里还剩 %d 字节没被读 —— bash 读到一半就开始执行了(脚本没整体包进 { … })" % leftover)

finish()

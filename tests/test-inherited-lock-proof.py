#!/usr/bin/env python3
"""继承锁的**凭据**必须真的是凭据。

`pdg update` 持锁调 `pdg __migrate`, 里面的 Python 子进程不能再去抢同一把锁(新的 OFD 会撞上
父进程自己)。判法是"证明那把锁已经在手上", 而不是"被告知别锁"。

第一版的证明有一个**假阳性**, 而且它的后果不是少一层保护, 是反过来制造了一把没人知道的锁:

    父进程只是 `exec 9>"$LOCK"` 打开了 fd, 还没 `flock` ——
    子进程在 fd 9 上跑 `flock(LOCK_EX|LOCK_NB)`, **成功**(本来就没人持锁),
    于是判成"继承", 而且按继承的规矩**退出时不释放**。
    从此那把锁挂在父进程的 fd 9 上, 谁也不知道它是什么时候被谁拿走的。

"能锁上"证明不了"已经锁着"。要分清这两件事, 必须先从**另一个 OFD** 试一次:

    · 另开一个 probe fd, 非阻塞抢锁。
      抢到了 ⇒ 原先**没人持锁** ⇒ 候选 fd 不是继承锁 ⇒ 立刻还回去, 走普通锁;
      被挡住 ⇒ 确实有人持锁 ⇒ 再看候选 fd:
        候选也能锁上 ⇒ 它与持锁者共享同一个 OFD ⇒ **这才是继承**;
        候选锁不上 ⇒ 锁在别人手里 ⇒ 拒绝。

本支用真实 flock 验这四种情形, 不看调用记录。
"""
import fcntl
import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   " + m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] " + m)


def chk(c, m):
    (ok if c else bad)(m)


WORK = tmpguard.mkdtemp(prefix="pdg-inhlock.")
LOCK = os.path.join(WORK, "privdns-gateway.lock")
open(LOCK, "w").close()
os.environ["PDG_LOCKFILE"] = LOCK
os.environ["PDG_TX_FSROOT"] = WORK

import pdgtx  # noqa: E402

pdgtx.LOCKFILE = LOCK


def outsider_can_lock(path=LOCK):
    """一个**独立进程**能不能拿到这把锁。独立进程 = 独立 OFD, 不会因为同进程的 fd 而误判。"""
    r = subprocess.run([sys.executable, "-c", textwrap.dedent("""
        import fcntl, sys
        f = open(sys.argv[1], "w")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit(1)
        sys.exit(0)
    """), path], capture_output=True)
    return r.returncode == 0


class Holder:
    """另一个**进程**持着锁, 直到 __exit__。"""

    def __init__(self, path=LOCK):
        self.path = path
        self.p = None

    def __enter__(self):
        self.p = subprocess.Popen(
            [sys.executable, "-c", textwrap.dedent("""
                import fcntl, sys
                f = open(sys.argv[1], "w")
                fcntl.flock(f, fcntl.LOCK_EX)
                sys.stdout.write("held\\n"); sys.stdout.flush()
                sys.stdin.readline()
            """), self.path],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert self.p.stdout.readline().strip() == "held"
        return self

    def __exit__(self, *a):
        try:
            self.p.stdin.write("go\n"); self.p.stdin.flush()
        except Exception:  # noqa: BLE001
            pass
        self.p.wait(timeout=10)
        return False


def call_with_fd(fd_obj, env_fd=None):
    """把一个已打开的文件对象当成候选 fd, 调 inherited_lock_fd。"""
    os.environ["PDG_LOCK_FD"] = str(env_fd if env_fd is not None else fd_obj.fileno())
    try:
        return pdgtx.inherited_lock_fd()
    finally:
        os.environ.pop("PDG_LOCK_FD", None)


# ══ 1. 假阳性: 父进程只是打开了 fd, 并没有加锁 ═══════════════════════════════
print("══ 1. 打开但未加锁的 fd ══")
f = open(LOCK, "w")                       # 只 open, **不** flock —— 父进程还没取锁
got = call_with_fd(f)
chk(got is None, "打开但未加锁的 fd → 不判成继承锁(实得 %r)" % got)
# 更要紧的一条: 判完之后**不许**那个 fd 莫名其妙地持上锁。
chk(outsider_can_lock(), "判定过程没有让那个 fd 意外持锁(独立进程仍抢得到)")
f.close()
chk(outsider_can_lock(), "关掉候选 fd 之后锁仍然是空闲的")

# ══ 2. 真的继承: fd 所在的 OFD 已经持锁 ══════════════════════════════════════
print()
print("══ 2. 真正继承且已锁的 fd ══")
g = open(LOCK, "w")
fcntl.flock(g, fcntl.LOCK_EX | fcntl.LOCK_NB)      # 这个 OFD **确实**持着锁
got = call_with_fd(g)
chk(got == g.fileno(), "已持锁的 fd → 判成继承锁(实得 %r)" % got)
chk(not outsider_can_lock(), "判定之后锁仍在(没有被顺手释放 —— 那是父进程的锁)")
fcntl.flock(g, fcntl.LOCK_UN)
g.close()

# ══ 3. 指错文件 ══════════════════════════════════════════════════════════════
print()
print("══ 3. fd 指向的不是锁文件 ══")
other = os.path.join(WORK, "not-the-lock")
h = open(other, "w")
fcntl.flock(h, fcntl.LOCK_EX | fcntl.LOCK_NB)
got = call_with_fd(h)
chk(got is None, "fd 指向别的文件(dev+ino 对不上)→ 拒绝(实得 %r)" % got)
chk(outsider_can_lock(), "拒绝时没有动锁文件上的锁")
fcntl.flock(h, fcntl.LOCK_UN); h.close()

# ══ 4. 锁在**别人**手里 ═════════════════════════════════════════════════════
print()
print("══ 4. 另一个进程持锁, 候选 fd 只是同一个文件的另一次 open ══")
with Holder():
    k = open(LOCK, "w")                    # 另一个 OFD, 不持锁
    got = call_with_fd(k)
    chk(got is None, "锁在别的进程手里 → 拒绝(实得 %r)" % got)
    k.close()
chk(outsider_can_lock(), "持锁进程退出后锁被正常释放")

# 同进程、另一个 OFD 持锁 —— 同样不算继承
print()
m1 = open(LOCK, "w")
fcntl.flock(m1, fcntl.LOCK_EX | fcntl.LOCK_NB)
m2 = open(LOCK, "w")                       # 另一次 open = 另一个 OFD
got = call_with_fd(m2)
chk(got is None, "同进程但**另一个 OFD** 持锁 → 候选 fd 不算继承(实得 %r)" % got)
fcntl.flock(m1, fcntl.LOCK_UN); m1.close(); m2.close()

# ══ 5. 没有继承 fd: 走普通锁, 且用完要还 ════════════════════════════════════
print()
print("══ 5. 没有继承 fd ══")
os.environ.pop("PDG_LOCK_FD", None)
chk(pdgtx.inherited_lock_fd() is None, "没有 PDG_LOCK_FD 且 fd 9 不是锁文件 → None")
lk = pdgtx._Lock(LOCK)
lk.__enter__()
chk(not outsider_can_lock(), "普通锁: 持有期间别人抢不到")
lk.__exit__()
chk(outsider_can_lock(), "普通锁: 用完还回去了")

# 明确关掉
os.environ["PDG_LOCK_FD"] = "none"
chk(pdgtx.inherited_lock_fd() is None, "PDG_LOCK_FD=none → 明确不找继承锁")
os.environ.pop("PDG_LOCK_FD", None)

# ══ 6. 撤销修复对照 ═════════════════════════════════════════════════════════
print()
print("══ 6. 撤销修复对照 ══")
# 把 probe 那一步拿掉(退回"候选 fd 上能锁上就算继承"), 第 1 节必须转红。
_real = pdgtx.inherited_lock_fd


def _naive(path=None):
    raw = os.environ.get(pdgtx.LOCK_FD_ENV, "")
    if raw.strip().lower() in ("none", "off"):
        return None
    try:
        fd = int(raw) if raw.strip() else pdgtx.LOCK_FD_DEFAULT
    except ValueError:
        return None
    try:
        st = os.fstat(fd)
        want = os.stat(path or pdgtx.LOCKFILE)
    except OSError:
        return None
    if (st.st_dev, st.st_ino) != (want.st_dev, want.st_ino):
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return fd


try:
    pdgtx.inherited_lock_fd = _naive
    ff = open(LOCK, "w")
    naive_got = call_with_fd(ff)
    leaked = not outsider_can_lock()
    chk(naive_got is not None and leaked,
        "撤掉 probe 那一步后: 未加锁的 fd 被判成继承, 而且锁被它意外拿走 —— 第 1 节有牙")
    try:
        fcntl.flock(ff, fcntl.LOCK_UN)
    except OSError:
        pass
    ff.close()
finally:
    pdgtx.inherited_lock_fd = _real

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

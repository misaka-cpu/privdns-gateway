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
import json
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

# 同进程、另一个 OFD 持锁 —— 这一格的判据**随所有权证据一起变了**, 而且是变对了。
#
# 旧判据(在候选 fd 上 flock)会拒: 候选那个 OFD 锁不上。但拒的后果是调用方转头自己去抢同一把
# 锁 —— 它已经在本进程手上了, 于是必然 TxBusy。那是个假报警: 配置**已经**被保护着。
#
# 新判据问的是"这把锁归谁"。答案是"本进程", 那就没有再抢一次的道理, 也没有并发风险。
# 真正要拒的是**别人**持着(上一格), 那才是并发。
print()
m1 = open(LOCK, "w")
fcntl.flock(m1, fcntl.LOCK_EX | fcntl.LOCK_NB)
m2 = open(LOCK, "w")                       # 另一次 open = 另一个 OFD
got = call_with_fd(m2)
chk(got == m2.fileno(),
    "锁在**本进程**手上(哪怕是另一个 OFD)→ 不必再抢, 按已在手处理(实得 %r)" % got)
chk(not outsider_can_lock(), "这一格没有动那把锁(它还在 m1 手上)")
fcntl.flock(m1, fcntl.LOCK_UN); m1.close(); m2.close()
chk(outsider_can_lock(), "m1 释放后锁恢复空闲")

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

# ══ 5b. 竞争窗口: 持锁者**在我们看它的时候**放手 ═══════════════════════════
print()
print("══ 5b. 判定过程中持锁者放手 ══")
# 这是前两版判据的死穴, 而且不是理论上的:
#
#     确认"有人持着" → 在候选 fd 上 flock
#                      ↑ 就在这一瞬, 持锁者退出了
#     于是那次 flock **成功**了 —— 拿到的是一把**全新的**锁, 不是继承来的。判成继承 ⇒ 按
#     继承的规矩退出时不释放 ⇒ 又一把没人认领的锁。
#
# 不靠重试去撞窗口(那样结果取决于机器快慢, "偶尔绿"比红更糟)。这里钉死窗口, 并断言那条
# **真正该守的不变量**:
#
#     判定返回"不是继承"时, 锁的状态必须与调用前**一模一样** —— 没多一把, 也没少一把。
#
# 这条与实现细节无关: 下一版换成别的证据也照样管用。(它比"一次 flock 都别调"更准确 ——
# 真正有害的不是调 flock, 是**留下**一把不属于自己的锁。)


class TimedHolder:
    """持锁, 直到被明确叫停。用管道同步, 不靠 sleep。"""

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

    def release_now(self):
        if self.p and self.p.poll() is None:
            try:
                self.p.stdin.write("go\n"); self.p.stdin.flush()
            except Exception:  # noqa: BLE001
                pass
            self.p.wait(timeout=10)

    def __exit__(self, *a):
        self.release_now()
        return False


# 把窗口钉在**读所有权证据的那一刻**: 证据刚读完(说"有人持着"), 持锁者立刻退出 ——
# 接下来那次 flock 于是**会成功**, 拿到的是一把新锁。这正是 v2 栽进去的那个窗口。
with TimedHolder() as holder:
    q = open(LOCK, "w")                     # 候选 fd: 另一个 OFD, 自己不持锁
    _real_rec = pdgtx._flock_record
    _fired = {"n": 0}

    def _rec_then_release(st):
        r = _real_rec(st)
        if _fired["n"] == 0:
            _fired["n"] = 1
            holder.release_now()            # 证据读完了, 持锁者这一刻放手
        return r

    pdgtx._flock_record = _rec_then_release
    try:
        got = call_with_fd(q)
    finally:
        pdgtx._flock_record = _real_rec

    chk(_fired["n"] == 1, "窗口被钉死了(所有权证据确实被读过, 钩子打中)")
    chk(got is None,
        "在窗口里拿到的是**新锁**, 不算继承(实得 %r)" % got)
    # 最要紧的一条: 那把顺手拿到的新锁必须当场还回去。
    chk(outsider_can_lock(), "顺手拿到的新锁已经还回去了(没有留下无人认领的锁)")
    q.close()
chk(outsider_can_lock(), "关掉候选 fd 之后锁仍然空闲")

# 同一条不变量在**每一种**输入上都要成立。
# 一格一格来, **不能把几个 fd 同时开着**: 判据问的是"这把锁归谁", 只要本进程有任何一个 fd
# 持着它答案就是"本进程" —— 于是"未加锁的 fd"那一格会被旁边那个持锁的 fd 带偏。
# 用例之间互相污染是这类测试最常见的假绿来源。
print()
_bad = []


def _invariant_case(label, make, want_fn):
    """make() → (fd 对象, 收尾函数); want_fn(fobj) 给出期望的判定结果。
    除了判定结果, 还要证明**锁状态没被这次判定改变**。"""
    fobj, done = make()
    free_before = outsider_can_lock()
    got = call_with_fd(fobj)
    free_after = outsider_can_lock()
    want = want_fn(fobj)
    if got != want:
        _bad.append("%s: 判定结果 %r ≠ %r" % (label, got, want))
    if got is None and free_after != free_before:
        _bad.append("%s: 判成「不是继承」却改变了锁状态(前 free=%s 后 free=%s)"
                    % (label, free_before, free_after))
    done()


def _mk_plain():
    f = open(LOCK, "w")
    return f, f.close


def _mk_locked():
    f = open(LOCK, "w")
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def done():
        fcntl.flock(f, fcntl.LOCK_UN)
        f.close()
    return f, done


def _mk_other():
    f = open(os.path.join(WORK, "not-the-lock-2"), "w")
    return f, f.close


_invariant_case("未加锁的 fd", _mk_plain, lambda f: None)
_invariant_case("本进程持锁的 fd", _mk_locked, lambda f: f.fileno())
_invariant_case("指错文件的 fd", _mk_other, lambda f: None)
chk(not _bad, "每一种输入: 判定结果如预期, 且判成「非继承」时锁状态原封不动(实得 %s)"
    % (_bad or "全对"))
chk(outsider_can_lock(), "这一组跑完锁仍然空闲")

# 真正继承的那一格也要证明"没有多拿也没有少还": 判定之后锁必须**仍然**在, 且还是原来那把。
print()
with TimedHolder():
    pass          # 确认起点干净
_sub = subprocess.run(
    [sys.executable, "-c", textwrap.dedent("""
        import fcntl, json, os, sys
        sys.path.insert(0, sys.argv[2])
        lock = sys.argv[1]
        os.environ["PDG_LOCKFILE"] = lock
        import pdgtx
        pdgtx.LOCKFILE = lock
        f = open(lock, "w")
        os.dup2(f.fileno(), 9)                 # 模拟 shell 的 exec 9>LOCK
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        st = os.stat(lock)
        before = pdgtx._flock_record(st)
        os.environ["PDG_LOCK_FD"] = "9"
        got = pdgtx.inherited_lock_fd()
        after = pdgtx._flock_record(st)
        print(json.dumps({"got": got, "same_record": before == after,
                          "holder_is_me": after[1] == os.getpid()}))
    """), LOCK, str(ROOT / "deploy" / "bot")],
    capture_output=True, text=True, timeout=60)
try:
    info = json.loads(_sub.stdout.strip().splitlines()[-1])
    chk(info["got"] == 9, "同 OFD 已持锁 → 判成继承(实得 %r)" % info["got"])
    chk(info["same_record"], "判定没有改写那条锁记录(还是原来那把锁, 不是新拿的)")
except Exception as e:  # noqa: BLE001
    bad("继承那一格跑不起来(%s): %s" % (type(e).__name__, (_sub.stderr or "")[-160:]))
chk(outsider_can_lock(), "子进程退出后锁被释放")

# ══ 5c. 只有**真正的锁竞争**才算"有人持着" ═════════════════════════════════
print()
print("══ 5c. 竞争判据 ══")
# flock 失败的原因不止"被别人占着"。把任意 OSError 都当成竞争, 一台 /run 出问题的机器会被
# 报成"已有配置操作正在执行" —— 而真正的原因(只读挂载、fd 不可用)被那句话盖掉, 人照着它去
# 找"另一个 pdg 进程", 永远找不到。
import errno as _errno  # noqa: E402

_real_flock = fcntl.flock


def _flock_raising(err):
    def f(fd, op):
        if op & fcntl.LOCK_EX:
            raise OSError(err, os.strerror(err))
        return _real_flock(fd, op)
    return f


for err, name, want_busy in ((_errno.EWOULDBLOCK, "EWOULDBLOCK", True),
                             (_errno.ENOLCK, "ENOLCK", False),
                             (_errno.EBADF, "EBADF", False)):
    fcntl.flock = _flock_raising(err)
    try:
        lk2 = pdgtx._Lock(LOCK)
        kind = None
        try:
            lk2.__enter__()
            kind = "成功"
        except pdgtx.TxBusy:
            kind = "TxBusy"
        except pdgtx.TxRefused:
            kind = "TxRefused"
        except OSError:
            kind = "OSError 直接漏出去"
        finally:
            try:
                lk2.__exit__()
            except Exception:  # noqa: BLE001
                pass
    finally:
        fcntl.flock = _real_flock
    if want_busy:
        chk(kind == "TxBusy", "flock 报 %s → 判成竞争(TxBusy)(实得 %s)" % (name, kind))
    else:
        chk(kind == "TxRefused",
            "flock 报 %s → **不是**竞争, 要按环境故障拒绝(实得 %s)" % (name, kind))

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

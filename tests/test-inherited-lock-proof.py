#!/usr/bin/env python3
"""继承锁的**凭据**必须真的是凭据。

`pdg update` 持锁调 `pdg __migrate`, 里面的 Python 子进程不能再去抢同一把锁(新的 OFD 会撞上
父进程自己, 必然 TxBusy, 整次更新回滚)。判法是"证明那把锁已经在手上", 而不是"被告知别锁"。

这条判据前后错过三次, 三次的教训都写在下面的用例里:

  v1 「能锁上就算继承」——  父进程只 `exec 9>"$LOCK"` 打开了 fd 还没 flock, 子进程一锁就成,
     判成继承, 而按继承的规矩退出时不释放 ⇒ 凭空多出一把没人认领的锁(§1、§6)。
  v2 「先用另一个 OFD 探一探」—— 探完到锁候选 fd 之间有个真实窗口, 持锁者恰好在这一瞬放手,
     拿到的仍是新锁(§5b)。
  v3 「/proc/locks 里的持有者 PID 是我自己就算继承」—— PID 是**进程**级的, flock 锁却挂在
     **打开文件描述(OFD)**上: 同进程另一次 open() 出来的 fd 不持锁, 却和真正持锁的那个 fd
     共用一个 PID ⇒ 任意一个 fd 都能冒充继承, 持锁方还在临界区里冒充者就被放进去了(§7);
     而 v3 分辨新旧锁靠的那次**回读**一旦失败, 它会 LOCK_UN —— 解掉的是**父进程**那把(§8)。

现在的判据是 OFD 级的: `/proc/self/fdinfo/<fd>` 里那行 `lock:` 只在**这个 fd 背后的 OFD 自己
持锁**时才有。判定全程一次 flock 都不调, 于是既不会顺手攒出一把新锁, 也没有任何 LOCK_UN
去动别人的锁 —— "判定前后锁状态原封不动"这条不变量在每一格里都直接断言。

本支全程用真实 flock、真实线程、真实子进程(含 `exec 9>LOCK; flock -n 9` 这个真实 CLI 形态)
来验, 不看调用记录, 也不靠 sleep 猜时序。
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import threading
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

# 同进程、另一个 OFD 持锁 —— 这一格曾经判错, 而且错得很重。
#
# 一度的判据是"/proc/locks 里那把锁的持有者 PID 就是我自己 ⇒ 算继承"。可 PID 是**进程**级的,
# flock 锁却挂在**打开文件描述(OFD)**上: 同一个进程里另一次 open() 出来的 fd 是另一个 OFD,
# 它根本不持锁, 却和真正持锁的那个 fd 共用一个 PID。于是任意一个 fd 都能冒充继承 ——
# 持锁的那一方还在临界区里, 冒充者就被放进去了(完整复现见 §7)。
#
# 判据问的必须是"这把锁是不是就在**这个 fd** 手里", 而不是"本进程有没有人持着"。
print()
m1 = open(LOCK, "w")
fcntl.flock(m1, fcntl.LOCK_EX | fcntl.LOCK_NB)
m2 = open(LOCK, "w")                       # 另一次 open = 另一个 OFD, 自己不持锁
got = call_with_fd(m2)
chk(got is None,
    "锁在本进程另一个 OFD 手上 → **不算**继承(同 PID 不是持有凭据; 实得 %r)" % got)
chk(call_with_fd(m1) == m1.fileno(),
    "同一时刻, 真正持锁的那个 fd 仍被正确识别(真继承没被误伤)")
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
    _real_rec = pdgtx._fd_holds_lock
    _fired = {"n": 0}

    def _rec_then_release(fd, st):
        r = _real_rec(fd, st)
        if _fired["n"] == 0:
            _fired["n"] = 1
            holder.release_now()            # 证据读完了, 持锁者这一刻放手
        return r

    pdgtx._fd_holds_lock = _rec_then_release
    try:
        got = call_with_fd(q)
    finally:
        pdgtx._fd_holds_lock = _real_rec

    chk(_fired["n"] == 1, "窗口被钉死了(所有权证据确实被读过, 钩子打中)")
    chk(got is None,
        "持锁者在窗口里放了手, 候选 fd 自己从来没持过锁 → 不算继承(实得 %r)" % got)
    # 最要紧的一条: 判定不许在这个窗口里顺手攒出一把没人认领的锁。
    chk(outsider_can_lock(), "窗口里没有多出一把无人认领的锁")
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
        def record():
            # 测试自己读 /proc/locks —— 不借产品的辅助函数来给产品打分。
            st = os.stat(lock)
            want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
            out = []
            with open("/proc/locks") as fh:
                for line in fh:
                    q = line.split()
                    if len(q) >= 6 and q[1] == "FLOCK" and q[5] == want:
                        out.append(" ".join(q[1:]))
            return out
        f = open(lock, "w")
        os.dup2(f.fileno(), 9)                 # 模拟 shell 的 exec 9>LOCK
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = record()
        os.environ["PDG_LOCK_FD"] = "9"
        got = pdgtx.inherited_lock_fd()
        after = record()
        print(json.dumps({"got": got, "same_record": before == after,
                          "held": bool(after)}))
    """), LOCK, str(ROOT / "deploy" / "bot")],
    capture_output=True, text=True, timeout=60)
try:
    info = json.loads(_sub.stdout.strip().splitlines()[-1])
    chk(info["got"] == 9, "同 OFD 已持锁 → 判成继承(实得 %r)" % info["got"])
    chk(info["same_record"] and info["held"],
        "判定前后那条锁记录一个字没变(还是原来那把, 不是新拿的)")
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

# ══ 7. A 组: 同 PID **不等于**同一把锁的持有凭据 ═══════════════════════════
print()
print("══ 7. 同 PID / 不同 OFD: 互斥与锁生命周期 ══")
# 判据按 PID 认继承 ⇒ 同一个进程里的**任何**一个 fd 都能冒充"继承来的锁"。
# 后果是互斥直接失守, 而且不是理论上的:
#
#   · 线程 A 用真实 _Lock 持锁, 进入临界区;
#   · 线程 B 的候选 fd 只是同一文件的**另一次 open**(不同 OFD, 自己不持锁);
#   · B 经真实 _LifecycleLock 被判成"继承", 于是和 A **同时**在临界区里;
#   · A 退出后 B 还在临界区, 而此刻第三个独立 fd 已经能把锁拿走 —— 谁都不认为自己该拦它。
#
# 这一组全程用 Event 做屏障, 不用 sleep 猜前提; 也不拿"两个线程都跑完了"当互斥的证明 ——
# 要证的是**重叠**: A 还持着的那一刻 B 到底进没进去。
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import iosstate as _ios  # noqa: E402

_ios.pdgtx.LOCKFILE = LOCK


def outsider_lock_fails():
    """第三个**独立进程**拿不到锁 = 此刻确实有人持着。"""
    return not outsider_can_lock()


a_holding = threading.Event()      # A 已经真的持锁了
b_tried = threading.Event()        # B 已经做完那次判定
a_release = threading.Event()      # 让 A 松手
rec = {}


def _thread_a():
    lk = pdgtx._Lock(LOCK)
    try:
        lk.__enter__()
        rec["a_got"] = True
        rec["a_lock_seen_by_outsider"] = outsider_lock_fails()
        a_holding.set()
        b_tried.wait(20)                    # 等 B 判定完, 这期间 A **一直**持着
        rec["a_still_holding_when_b_done"] = True
    except Exception as e:                  # noqa: BLE001
        rec["a_got"] = False
        rec["a_err"] = "%s: %s" % (type(e).__name__, e)
        a_holding.set()
    finally:
        a_release.wait(20)
        try:
            lk.__exit__()
        except Exception:                   # noqa: BLE001
            pass
        rec["a_released"] = True


def _thread_b():
    a_holding.wait(20)
    fb = open(LOCK, "w")                    # 另一次 open = 不同 OFD, 自己不持锁
    rec["b_fd"] = fb.fileno()
    os.environ["PDG_LOCK_FD"] = str(fb.fileno())
    try:
        # **真实入口**: 不喂辅助函数字符串, 走 _LifecycleLock 那条路。
        lk = _ios._LifecycleLock(True, "B 的操作")
        try:
            lk.__enter__()
            rec["b_entered"] = True
            rec["b_inherited"] = lk.inherited
        except _ios.StateError as e:
            rec["b_entered"] = False
            rec["b_refuse"] = str(e)[:60]
        else:
            lk.__exit__()
    finally:
        os.environ.pop("PDG_LOCK_FD", None)
        fb.close()
        b_tried.set()


ta, tb = threading.Thread(target=_thread_a), threading.Thread(target=_thread_b)
ta.start(); tb.start()
b_tried.wait(25); a_release.set()
tb.join(25); ta.join(25)

chk(rec.get("a_got") is True, "前提: 线程 A 用真实 _Lock 拿到了锁(%s)" % rec.get("a_err", "ok"))
chk(rec.get("a_lock_seen_by_outsider") is True, "前提: A 持锁期间第三方确实抢不到")
chk(rec.get("b_entered") is False,
    "A 还持着锁时, B **没有**从继承捷径进临界区(实得 entered=%r inherited=%r)"
    % (rec.get("b_entered"), rec.get("b_inherited")))
chk(rec.get("b_entered") is False and "已有配置操作" in (rec.get("b_refuse") or ""),
    "B 按既有非阻塞语义被判成竞争(实得 %r)" % (rec.get("b_refuse"),))

# A 松手之后, B 正常重试应当能拿到**自己的**锁 —— 不能靠一律拒绝继承把路堵死。
ta.join(10)
_fb2 = open(LOCK, "w")
os.environ["PDG_LOCK_FD"] = str(_fb2.fileno())
_lk2 = _ios._LifecycleLock(True, "B 重试")
try:
    _lk2.__enter__()
    _b2_ok = True
except _ios.StateError:
    _b2_ok = False
os.environ.pop("PDG_LOCK_FD", None)
chk(_b2_ok, "A 释放后 B 正常重试拿到了自己的锁")
chk(not _lk2.inherited, "那是**自己取的**锁, 不是继承(inherited=%r)" % _lk2.inherited)
chk(outsider_lock_fails(), "B 合法持锁期间, 第三个独立 OFD 取锁失败")
_lk2.__exit__(); _fb2.close()
chk(outsider_can_lock(), "B 退出后第三个独立 OFD 才能取得")

# ══ 8. B 组: 凭据二次读取失败, 不许把父进程那把锁解掉 ══════════════════════
print()
print("══ 8. 真实继承锁 + 凭据读取失败 ══")
# 现在的实现在候选 fd 上 flock 成功之后, 要**再读一次**锁记录来分辨"刚拿到的新锁"与"本来
# 就持着的旧锁"。那次读取失败时它会 LOCK_UN —— 而那把锁是**父进程的**(同一个 OFD),
# 于是一次读 /proc 失败就把父进程的临界区拆了, 父 fd 还开着, 别人已经能进来。


def run_in_cli_lock(pycode, extra_env=None):
    """按**真实 CLI 形态**造一把继承锁: 父打开 fd 9, 外部 flock 加锁后退出, 父继续持有该 OFD。
    然后在那个父进程里跑 pycode。返回 (rc, stdout, stderr)。"""
    script = (
        'exec 9>"$1"\n'
        'flock -n 9 || exit 9\n'
        'python3 - "$1" "$2" <<\'PYEOF\'\n' + pycode + '\nPYEOF\n'
    )
    env = dict(os.environ)
    env.pop("PDG_LOCK_FD", None)
    env.update(extra_env or {})
    r = subprocess.run(["bash", "-c", script, "_", LOCK, str(ROOT / "deploy" / "bot")],
                       capture_output=True, text=True, timeout=90, env=env)
    return r.returncode, r.stdout, r.stderr


_CHILD = """
import json, os, sys
lock, botdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, botdir)
os.environ["PDG_LOCKFILE"] = lock
import pdgtx, iosstate
pdgtx.LOCKFILE = lock
iosstate.pdgtx.LOCKFILE = lock
if os.environ.get("CAND_FD") == "OWN":
    _own = open(lock, "w")                # 另一次 open = 另一个 OFD, 自己不持锁
    os.environ["PDG_LOCK_FD"] = str(_own.fileno())
else:
    os.environ["PDG_LOCK_FD"] = os.environ.get("CAND_FD", "9")

# 注入点: 判据靠读内核凭据来立论, 这里让**从第 N 次读取起**读不出来。
# 用"从第 N 次起持续失败"而不是一次性打嗝, 是因为 /proc 读不到通常是环境条件(没挂、被容器
# 挡住); 而且这样才压得到**调用方自己那次读取** —— 否则它独立重读一遍就绕过注入了。
# N=2 正好落在旧实现"flock 之后那次回读"的位置。
#
# 钩住所有在用的凭据读取函数, 不预设实现用的是哪一个 —— 同一份测试既压当前实现, 也压负控里
# 恢复出来的旧实现(否则注入空转, 负控就没牙了)。
NTH = int(os.environ.get("EVIDENCE_FAIL_FROM", "0"))
reads = [0]
fired = [0]
hooked = []
if NTH:
    def arm(name, failval):
        real = getattr(pdgtx, name, None)
        if real is None:
            return
        hooked.append(name)

        def wrapper(*a, **kw):
            reads[0] += 1
            if reads[0] >= NTH:
                fired[0] += 1
                return failval            # 模拟 /proc 这会儿读不出来
            return real(*a, **kw)
        setattr(pdgtx, name, wrapper)
    arm("_fd_holds_lock", None)           # 当前实现: 读不到 = 证明不了
    arm("_flock_record", "unknown")       # 旧实现(负控恢复的那版)同样的语义

got = "skipped" if os.environ.get("SKIP_PROBE") else pdgtx.inherited_lock_fd()
probe_reads = reads[0]

def parent_lock_still_held():
    # 用**另一个独立 OFD** 去试: 拿得到就说明父进程那把锁已经被解掉了。
    import fcntl
    probe = open(lock, "w")
    try:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        probe.close()

held_after_probe = parent_lock_still_held()

# 真实调用方拿到这个结果之后到底怎么做 —— 只看辅助函数返回 None 是不够的。
caller = {}
if os.environ.get("RUN_CALLER"):
    lk = iosstate._LifecycleLock(True, "子进程的操作")
    try:
        lk.__enter__()
        caller = {"entered": True, "inherited": lk.inherited}
        lk.__exit__()
    except iosstate.StateError as e:
        caller = {"entered": False, "refuse": str(e)[:60]}

print(json.dumps({"got": got, "parent_lock_still_held": held_after_probe,
                  "reads": reads[0], "probe_reads": probe_reads, "fired": fired[0],
                  "hooked": hooked,
                  "caller": caller,
                  "parent_lock_at_end": parent_lock_still_held()}))
"""


def cli_case(label, env=None, expect_got=None):
    rc, out, err = run_in_cli_lock(_CHILD, env)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception as e:  # noqa: BLE001
        bad("%s: 跑不起来(%s) %s" % (label, type(e).__name__, (err or out)[-240:]))
        return None


# ① 健康对照: 不注入任何失败
info = cli_case("健康对照")
if info:
    chk(info["got"] == 9, "健康对照: 真实继承(外部 flock 已退出)被识别(实得 %r)" % info["got"])
    chk(info["parent_lock_still_held"], "健康对照: 判定之后父进程那把锁**还在**")
chk(outsider_can_lock(), "父进程退出后锁被释放(没有泄漏)")

# ①b 健康对照下, 真实调用方确实走继承那条, 而且不还锁
info = cli_case("健康对照(过调用方)", {"RUN_CALLER": "1"})
if info:
    chk(info["caller"].get("entered") is True and info["caller"].get("inherited") is True,
        "健康对照: _LifecycleLock 认出继承并进了临界区(实得 %r)" % (info["caller"],))
    chk(info["parent_lock_at_end"], "健康对照: 调用方用完**没有**把父进程的锁还掉")
chk(outsider_can_lock(), "这一格跑完锁没有泄漏")

# ② 候选 fd 是子进程**自己**新开的 —— 同一个文件、父进程正持着锁, 但不是同一个 OFD
info = cli_case("不同 OFD 候选", {"CAND_FD": "OWN", "RUN_CALLER": "1"})
if info:
    chk(info["got"] is None, "候选是另一次 open 的 fd → 不算继承(实得 %r)" % info["got"])
    chk(info["parent_lock_still_held"], "拒绝时没有动父进程那把锁")
    chk(info["caller"].get("entered") is False
        and "已有配置操作" in (info["caller"].get("refuse") or ""),
        "调用方据此按竞争拒绝, 没有硬闯临界区(实得 %r)" % (info["caller"],))
chk(outsider_can_lock(), "这一格跑完锁没有泄漏")

# ③ 只注入凭据读取失败, **单次判定**: 不跑调用方, 读取次数才数得清。
#    N=2 正是旧实现里"flock 成功之后那次回读"的位置 —— 它失败时旧实现会 LOCK_UN, 解掉的
#    是父进程那把锁(同一个 OFD)。这一格就是负控要打红的那条。
for nth, label in ((2, "第二次"), (1, "第一次")):
    info = cli_case("注入%s读取失败" % label, {"EVIDENCE_FAIL_FROM": str(nth)})
    if not info:
        continue
    chk(info["hooked"], "注入%s: 钩子确实挂上了(挂住 %s)" % (label, info["hooked"]))
    chk(info["parent_lock_still_held"],
        "注入%s凭据读取失败 → **没有**把父进程那把锁解掉(这次判定读了 %d 次凭据, 失败 %d 次)"
        % (label, info["probe_reads"], info["fired"]))
    chk(info["got"] in (None, 9),
        "注入%s读取失败 → 要么如实说不确定, 要么仍正确识别; 不能是别的(实得 %r)"
        % (label, info["got"]))
    chk(info["parent_lock_at_end"], "注入%s: 这一格从头到尾父进程的锁都在" % label)

# 一次判定到底读几次凭据 —— "回读失败就解锁"那条分支还在不在的直接度量。
info = cli_case("读取次数", {"EVIDENCE_FAIL_FROM": "99"})
if info:
    chk(info["probe_reads"] == 1,
        "一次判定只读一次凭据 ⇒ 根本不存在「回读失败就解锁」那条分支(实得 %d 次)"
        % info["probe_reads"])

# ④ 调用方在"证明不了"时怎么做: 从第一次读取起就失败, 把它自己那次重读也盖住。
info = cli_case("调用方遇到证明不了",
                {"EVIDENCE_FAIL_FROM": "1", "SKIP_PROBE": "1", "RUN_CALLER": "1"})
if info:
    chk(info["fired"] >= 1, "调用方那次凭据读取确实被注入了(命中 %d 次)" % info["fired"])
    chk(info["caller"].get("entered") is False
        and "已有配置操作" in (info["caller"].get("refuse") or ""),
        "证明不了 → 调用方不硬闯临界区, 按既有非阻塞语义拒绝(实得 %r)" % (info["caller"],))
    chk(info["parent_lock_at_end"], "证明不了 → 调用方也没有去解父进程那把锁")
chk(outsider_can_lock(), "这一组跑完锁没有泄漏")

# ══ 9. 资源归属与收尾: 按对象分别记账 ═════════════════════════════════════
print()
print("══ 9. 资源收尾 ══")
# 四类资源分开数, 不合成一个"跑完了没崩"的笼统判断; 而且是**判完之后**才数 ——
# 先主动清一遍再数, 数出来的只是清理动作本身, 证明不了这些用例没留东西。


def open_fds_under(dirpath):
    out = []
    for name in os.listdir("/proc/self/fd"):
        try:
            tgt = os.readlink("/proc/self/fd/" + name)
        except OSError:
            continue
        if tgt.startswith(dirpath + os.sep) or tgt == dirpath:
            out.append("%s→%s" % (name, tgt))
    return sorted(out)


def live_children():
    out = []
    me = os.getpid()
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry) as fh:
                fields = fh.read().rsplit(") ", 1)[1].split()
            if int(fields[1]) == me:
                out.append(entry)
        except (OSError, IndexError, ValueError):
            continue
    return out


_fds = open_fds_under(WORK)
chk(not _fds, "fd: 用例开的文件描述符都关干净了(残留 %s)" % (_fds or "无",))

_thr = [t.name for t in threading.enumerate() if t is not threading.current_thread()]
chk(not _thr, "线程: 没有还活着的工作线程(残留 %s)" % (_thr or "无",))

_kids = live_children()
chk(not _kids, "子进程: 持锁进程/子调用都已回收(残留 pid %s)" % (_kids or "无",))

chk(outsider_can_lock(), "锁: 全部跑完后锁是空闲的(没有谁把它带走)")

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

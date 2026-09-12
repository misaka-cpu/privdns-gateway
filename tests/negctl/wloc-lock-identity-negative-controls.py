#!/usr/bin/env python3
"""负控: 继承锁的**身份判据**有没有牙。

盯 `deploy/bot/pdgtx.py` 的 `inherited_lock_fd` / `_fd_holds_lock`。逐格把修复**撤回去**,
跑 `tests/test-inherited-lock-proof.py`, 比较**具名失败集合**。

撤回的是两条已实测的缺陷:
  ① 同 PID 直接放行 —— 同一个进程里任意一个 fd 都能冒充继承, 持锁方还在临界区里冒充者就
     被放进去了(互斥与锁生命周期一起失守);
  ② 二次凭据读取失败就 LOCK_UN —— 解掉的是**父进程**那把锁(同一个 OFD);
外加一条 ③ 读不到凭据就当继承(fail-open), 和一条 ④ 只加无关注释的空转对照。

每格五步: 锚点恰好命中 / 替换真的落进文件 / 语法门仍过 / 具名失败有新增 / finally 核对
正式树 sha256。0 条转红 = 这一格无效, 判 FAIL。
"""
import collections
import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TX = "deploy/bot/pdgtx.py"
TOUCHED = [ROOT / TX]
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


# ── 子测试的执行有效性 ───────────────────────────────────────────────────────
#
# 以前这里只把 stdout+stderr 拼起来抓行首 [FAIL], **退出码整个丢掉**。于是至少三种形态能
# 冒充绿, 而且长得和"真的没问题"一模一样:
#
#   · rc=1 + Traceback + 零断言  → 失败集合是空的 → 基线判"全绿", 反向对照判"零新增";
#   · rc=0 + 只有说明文字        → 同上;
#   · 打印目标 [FAIL] 后 rc=3    → 失败集合里有目标 → 变异判"有牙"。
#
# 这三种都不是"判据没牙", 是"压根没跑起来"。二者混为一谈, 负控就从证据退化成装饰。
#
# 判读依据是 tests/test-inherited-lock-proof.py 的**实际**约定(读过源码, 不是照惯例猜):
#   · 唯一出口是结尾的 sys.exit(1 if FAIL else 0) ⇒ 正常结束只可能是 0 或 1;
#   · 断言一条一行, 行首是 "[OK]   " / "[FAIL] "; 别处引用这两个标记不算断言;
#   · 最后打印 "[SUM] OK=n FAIL=m";
#   · 未捕获异常同样以 1 退出, 但**跑不到** [SUM] —— 这正是把"断言失败"和"崩了"分开的锚;
#   · 实测健康一次: rc=0, stderr 为空, 65 条行首断言, SUM 与行数一致, 无游离标记。
#
# 仓库里最接近的现成实现是 negctl/bot-update-check-negative-controls.py 里的 run_pos():
# 它在脚本的 try 块内、无 __main__ 守卫(import 即 clone 整个仓库并跑完整支负控), 而且
# **完全不看 returncode** —— 上面第三种形态它照样漏。复用会引入不相关运行副作用且仍有缺口,
# 所以这里写本支需要的最小判定, 不新建通用框架。
SUM_RE = re.compile(r"^\[SUM\] OK=(\d+) FAIL=(\d+)\s*$", re.M)
OK_RE = re.compile(r"^\[OK\]\s", re.M)
FAIL_RE = re.compile(r"^\[FAIL\]\s", re.M)
TRACEBACK = "Traceback (most recent call last)"

Outcome = collections.namedtuple("Outcome", "status reason failures rc out err")


def failures(out):
    s = set()
    for line in out.splitlines():
        if not FAIL_RE.match(line):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


def verdict(rc, out, err, timed_out=False, launch_error=""):
    """把一次子测试执行判成三态之一:

      "ok"      正常成功 —— rc=0, 有效断言非零, 无失败;
      "failed"  正常断言失败 —— rc=1, 有具名失败, 计数自洽。**可以**进入负控比较;
      "anomaly" 执行异常 —— 启动失败/超时/信号/退出码越界/零断言/计数矛盾/未捕获异常。

    不把"所有非零退出"一律当异常: rc=1 且有具名失败是这支测试的正常表达方式。
    """
    def anomaly(why):
        return Outcome("anomaly", why, set(), rc, out, err)

    if launch_error:
        return anomaly("子测试启动失败(%s)" % launch_error)
    if timed_out:
        return anomaly("子测试超时被强杀")
    if rc is None:
        return anomaly("拿不到退出码 —— 这一次执行的结局本身就是未知的")
    if rc < 0:
        name = signal.Signals(-rc).name if -rc in set(int(x) for x in signal.Signals) else str(-rc)
        return anomaly("子测试被信号 %s 终止" % name)
    if TRACEBACK in err:
        # 只看 stderr: 断言文案里引用的子进程输出走的是 stdout, 那是文字不是异常。
        tail = [ln for ln in err.strip().splitlines() if ln.strip()][-1:]
        return anomaly("子测试 stderr 有未捕获异常(%s)" % (tail[0][:70] if tail else "Traceback"))

    n_ok, n_fail = len(OK_RE.findall(out)), len(FAIL_RE.findall(out))
    sums = SUM_RE.findall(out)
    if len(sums) != 1:
        return anomaly("没有唯一的 [SUM] 汇总行(找到 %d 条)—— 子测试没跑到结尾" % len(sums))
    s_ok, s_fail = int(sums[0][0]), int(sums[0][1])
    if (s_ok, s_fail) != (n_ok, n_fail):
        return anomaly("行首断言计数(OK=%d FAIL=%d)与 [SUM](OK=%d FAIL=%d)不一致 —— "
                       "输出里混进了引用的断言标记, 或中途异常" % (n_ok, n_fail, s_ok, s_fail))
    if n_ok + n_fail == 0:
        return anomaly("零有效断言 —— 这一次什么都没验")
    if rc not in (0, 1):
        return anomaly("退出码 %d 超出该支约定(它只会以 0/1 退出)" % rc)
    if rc != (1 if n_fail else 0):
        return anomaly("退出码 %d 与失败数 %d 矛盾" % (rc, n_fail))
    return Outcome("failed" if n_fail else "ok",
                   "%d 条有效断言, %d 条失败" % (n_ok + n_fail, n_fail),
                   failures(out), rc, out, err)


SUITES = (["python3", "tests/test-inherited-lock-proof.py"],)


def run_suites(wd):
    """跑子测试并给出裁决。多支时: 任何一支异常即整体异常, 失败集合取并集。"""
    merged, worst = set(), None
    for cmd in SUITES:
        try:
            r = run(cmd, cwd=wd)
        except subprocess.TimeoutExpired:
            return Outcome("anomaly", "子测试超时被强杀(%s)" % cmd[-1], set(), None, "", "")
        except OSError as e:
            return Outcome("anomaly", "子测试启动失败(%s: %s)" % (cmd[-1], e), set(), None, "", "")
        res = verdict(r.returncode, r.stdout, r.stderr)
        if res.status == "anomaly":
            return res._replace(reason="%s: %s" % (cmd[-1], res.reason))
        merged |= res.failures
        worst = res if (worst is None or res.status == "failed") else worst
    return worst._replace(failures=merged)


def refuse(stage, res):
    """把一次执行异常报成具名失败, 点明阶段与原因, 并把三路证据留住。"""
    bad("%s: 子测试**没有正常执行**, 这一格不作数 —— %s" % (stage, res.reason))
    print("       rc=%r  stdout=%d 字节  stderr=%d 字节" % (res.rc, len(res.out), len(res.err)))
    for label, blob in (("stdout", res.out), ("stderr", res.err)):
        tail = [ln for ln in (blob or "").splitlines() if ln.strip()][-3:]
        for ln in tail:
            print("       %s| %s" % (label, ln[:100]))


# 当前判据的尾巴: 唯一的放行点。
GATE = '''    if _fd_holds_lock(fd, want) is not True:                # ②
        return None                                         # False/None 都不足以证明
    return fd'''

# ① 撤回成"同 PID 直接放行"(v3 的 ③ 步)。/proc/locks 记的是**当初调用 flock 的进程**,
#    它与"这个 fd 持不持锁"是两码事 —— 这正是问题 A。
SAME_PID = '''    _me = os.getpid()
    _key = "%02x:%02x:%d" % (os.major(want.st_dev), os.minor(want.st_dev), want.st_ino)
    try:
        with open("/proc/locks", encoding="utf-8") as _f:
            for _ln in _f:
                _p = _ln.split()
                if (len(_p) >= 6 and _p[1] == "FLOCK" and _p[3] == "WRITE"
                        and _p[5] == _key and _p[4].isdigit() and int(_p[4]) == _me):
                    return fd
    except OSError:
        pass
''' + GATE

# ② 撤回成 v3 的 ④ 步: flock 一把, 再回读一次记录分辨新旧锁, 回读失败就 LOCK_UN。
#    `_flock_record` 要摆在模块层, 测试里的注入钩子才挂得上 —— 否则注入空转, 这一格会
#    得到一个误导性的"0 条转红"。
RECORD_FN = '''def _flock_record(st):
    want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    try:
        with open("/proc/locks", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 6 or parts[1] == "->":
                    continue
                if parts[1] != "FLOCK" or parts[3] != "WRITE" or parts[5] != want:
                    continue
                try:
                    return parts[0], int(parts[4])
                except ValueError:
                    return parts[0], -1
    except OSError:
        return "unknown"
    return None


def inherited_lock_fd(path=None):'''

RELOCK = '''    before = _flock_record(want)
    if before is None or before == "unknown":
        return None
    if before[1] == os.getpid():
        return fd
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    after = _flock_record(want)
    if after == "unknown" or after is None or after[1] == os.getpid():
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        return None
    return fd'''

# ③ 读不到凭据就当继承 —— 把 fail-closed 改成 fail-open。
FAIL_OPEN = GATE.replace("is not True", "is False")

MUT = [
    ("① 同 PID 直接放行", TX, [(GATE, SAME_PID, 1)],
     "A 还持着锁时"),
    ("② 回读失败就 LOCK_UN", TX,
     [("def inherited_lock_fd(path=None):", RECORD_FN, 1), (GATE, RELOCK, 1)],
     "没有**把父进程那把锁解掉"),
    ("③ 读不到凭据就当继承(fail-open)", TX, [(GATE, FAIL_OPEN, 1)],
     "不硬闯临界区"),
    ("④ 只加一行无关注释(反向对照)", TX,
     [("def _fd_holds_lock(fd, st):",
       "# (负控的空转对照, 不改变任何行为)\ndef _fd_holds_lock(fd, st):", 1)],
     None),
]

def main():
    before_sha = {p: sha(p) for p in TOUCHED}
    modes = {p: os.stat(p).st_mode for p in TOUCHED}
    started = False
    wd = tmpguard.mkdtemp(prefix="pdg-lockid-negctl.")
    try:
        for sub in ("tests", "deploy", "lib"):
            shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                            symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
        pristine = {TX: (Path(wd) / TX).read_text(encoding="utf-8")}
        base_res = run_suites(wd)
        base = base_res.failures
        if base_res.status == "anomaly":
            # 执行异常时**不打印"基线全绿"、不开跑变异**: 拿一次没跑起来的执行当比较基准,
            # 后面每一格的"新增失败"都是空集合减空集合, 结论全是误导性的。
            refuse("基线", base_res)
            started = False
        elif base:
            bad("基线(未改坏)就有 %d 条失败 —— 后面每格的'新增'都算不出来: %s"
                % (len(base), sorted(base)[:2]))
            started = False
        else:
            ok("基线: 继承锁证明支在工作副本里正常跑完且全绿(%s)" % base_res.reason)
            started = True

        for label, rel, edits, want in (MUT if started else ()):
            target = Path(wd) / rel
            text = pristine[rel]
            anchored = True
            for anchor, repl, hits in edits:
                n = text.count(anchor)
                if n != hits:
                    bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, n, hits))
                    anchored = False
                    break
                text = text.replace(anchor, repl, 1)
            if not anchored:
                target.write_text(pristine[rel], encoding="utf-8")
                continue
            if text == pristine[rel]:
                bad("%s: 替换没有真的落进文件" % label)
                continue
            target.write_text(text, encoding="utf-8")
            syn = run(["python3", "-m", "py_compile", str(target)])
            if syn.returncode != 0:
                bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)" % (label, (syn.stderr or "")[:80]))
                target.write_text(pristine[rel], encoding="utf-8")
                continue
            got_res = run_suites(wd)
            target.write_text(pristine[rel], encoding="utf-8")
            if got_res.status == "anomaly":
                # 关键的一条: 哪怕输出里已经有目标 [FAIL], 只要这次执行本身不正常, 就不算"有牙"
                # —— 那条 [FAIL] 可能是崩在半路留下的, 证明不了判据在起作用。
                # 反向对照同理: 崩溃不能冒充"零新增失败"。
                refuse(label, got_res)
                continue
            new = got_res.failures - base
            if want is None:
                (ok if not new else bad)(
                    "%s: 新增失败 0 条(判据没在看噪声)" % label if not new
                    else "%s: 不该有新失败, 却新增 %d 条: %s" % (label, len(new), sorted(new)[:2]))
                continue
            if not new:
                bad("%s: **0 条转红** —— 这一格的判据没有牙" % label)
            elif not any(want in n for n in new):
                bad("%s: 转红了但没命中预期判据(%s): %s" % (label, want, sorted(new)[:2]))
            else:
                hit = sorted(n for n in new if want in n)[0]
                ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:74]))
    finally:
        drift = [str(p) for p in TOUCHED if sha(p) != before_sha[p]]
        if drift:
            bad("正式树被改动了(负控只该改工作副本): %s" % drift)
        else:
            ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
        for p in TOUCHED:
            if os.stat(p).st_mode != modes[p]:
                bad("正式树文件 mode 变了: %s" % p)

    print("-" * 62)
    print("wloc-lock-identity-negative-controls.py: 通过 %d, 失败 %d%s"
          % (PASS[0], FAIL[0], "" if started else "(基线未通过, 变异未开跑)"))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

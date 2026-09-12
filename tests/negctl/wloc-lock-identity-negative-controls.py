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
import time
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


SUITE_TIMEOUT = 900     # 正式预算。测试只覆盖**它自己那次**调用, 不动这个默认值。
REAP_BUDGET = 10        # 收尾自己的上限 —— kill 完不能再用无期限的 wait 卡死


def _txt(v):
    """把管道读出来的东西统一成 str, 别让一次解码错误盖住真正的失败。"""
    if v is None:
        return ""
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v


def _confirm_group_gone(pgid, budget=REAP_BUDGET):
    """有界确认那个进程组是不是真的空了。返回 (确认清空, 说明)。

    信号发出去了不等于组已经空 —— SIGKILL 不可捕获, 但后代要等被 init 收尸才从进程表消失。
    所以这里轮询 killpg(pgid, 0): 抛 ProcessLookupError 才算确认。有界, 到点就如实说没确认。
    """
    deadline = time.monotonic() + budget
    while True:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return True, "进程组已清空"
        except PermissionError:
            return False, "无权确认进程组状态"
        except OSError as e:
            return False, "确认进程组状态失败(%s)" % e
        if time.monotonic() >= deadline:
            return False, "%ds 内进程组仍未清空" % budget
        time.sleep(0.02)


def _kill_own_group(p):
    """结束**本次自己创建的那个进程组**。返回 (pgid 或 None, 说明)。

    只打这一次 Popen 建出来的组 —— start_new_session=True 保证组里只可能有本次启动的进程,
    所以不必、也绝不按进程名或命令行做宽匹配(那会打到别的检查、别人的 python, 甚至自己)。
    """
    try:
        pgid = os.getpgid(p.pid)
    except (ProcessLookupError, PermissionError, OSError) as e:
        try:
            p.kill()
        except OSError:
            pass
        return None, "拿不到进程组(%s), 后代去向无法确认" % e
    if pgid == os.getpgid(0):
        # 没能独占进程组: 这时 killpg 会打到我们自己身上, 绝不能发。
        try:
            p.kill()
        except OSError:
            pass
        return None, "子进程没有独占进程组, 只结束了直接子进程, 后代去向无法确认"
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass                     # 组已经空了, 也算打到位
    except OSError as e:
        try:
            p.kill()
        except OSError:
            pass
        return None, "killpg 失败(%s)" % e
    return pgid, ""


def run(cmd, cwd=None, timeout=SUITE_TIMEOUT):
    """跑一条子测试。超时按**本次自己创建的进程组**收干净, 并把已经产生的输出带出来。

    为什么不能只让外层 return: 子测试会派生后代(持锁进程、桩子进程)。直接子进程被杀之后
    后代还攥着锁、还连着我们这一端的管道 —— 于是"超时"根本没真正结束: 下一格会在一把没人
    释放的锁上跑, 删工作目录时还可能撞上仍在写的进程。实测过修前的行为: 执行器 2.00s 返回
    anomaly, 而后代仍是 S 状态、临时锁仍拿不到、stdout/stderr 却是空的。

    start_new_session=True 让这一次调用独占一个进程组, killpg 打到的只可能是本次启动的进程。
    同样的形状产品侧 deploy/bot/pdg-bot.py 的 _git() 已经在用; 那是产品模块, import 它会把
    整个 bot 拉进来, 所以这里照它的语义写本支需要的最小一份, 不新建通用框架。

    超时时抛 TimeoutExpired, 并挂上三件事实(彼此分开, 不合成一句"已强杀完成"):
      · output/stderr —— 超时前实际产生的输出, 有什么留什么, 不清空;
      · pdg_reaped    —— **确认**收干净了没有; 确认不了就是 False;
      · pdg_rc        —— 真拿到的退出状态(被 SIGKILL 就是 -9); 拿不到是 None, 不伪造。
    """
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, errors="replace", start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as first:
        early_out, early_err = _txt(first.output), _txt(first.stderr)
        pgid, note = _kill_own_group(p)
        try:
            # 收尸 + 把管道读干净。communicate 是**续读**同一对缓冲区, 返回的是全量,
            # 所以直接取它, 不与 early 拼接(拼了会重复)。
            out, err = p.communicate(timeout=REAP_BUDGET)
            out, err = _txt(out) or early_out, _txt(err) or early_err
            reaped, why = (False, note) if pgid is None else _confirm_group_gone(pgid)
        except subprocess.TimeoutExpired:
            # 连尸体都收不掉: 不假装收干净, 也不把已有输出清空。
            out, err, reaped = early_out, early_err, False
            why = "%ds 内管道都没读干净" % REAP_BUDGET
        exc = subprocess.TimeoutExpired(cmd, timeout, output=out, stderr=err)
        exc.pdg_reaped = reaped
        exc.pdg_note = "; ".join(x for x in (note, why) if x) or "进程组已清空"
        exc.pdg_rc = p.returncode
        raise exc
    return subprocess.CompletedProcess(cmd, p.returncode, _txt(out), _txt(err))


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

# halt: 这次执行留下了**没确认收干净**的东西(还在跑的后代、没释放的锁)。带着它继续做下一格
# 等于在污染过的现场做实验, 所以上层见到 halt 就停, 不再开新格、也不动相关目录。
Outcome = collections.namedtuple("Outcome", "status reason failures rc out err halt")
Outcome.__new__.__defaults__ = (False,)


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


def _suite_name(cmd):
    """给这条命令起个认得出的名字: 取第一个像脚本的参数, 而不是最后一个 argv。"""
    for a in cmd[1:]:
        if a.endswith(".py") or a.endswith(".sh"):
            return a
    return cmd[-1]


def run_suites(wd):
    """跑子测试并给出裁决。多支时: 任何一支异常即整体异常, 失败集合取并集。"""
    merged, worst = set(), None
    for cmd in SUITES:
        name = _suite_name(cmd)
        try:
            # 预算显式传进去: 测试要覆盖的是**自己那次调用**的预算, 不该去改正式默认值。
            r = run(cmd, cwd=wd, timeout=SUITE_TIMEOUT)
        except subprocess.TimeoutExpired as e:
            # 超时和收尾是两件事, 分开记。收尾没确认就**明说没确认**, 并让上层停下来 ——
            # 带着还在跑的后代进下一格, 等于在一把没人释放的锁上继续做实验。
            reaped = getattr(e, "pdg_reaped", False)
            note = getattr(e, "pdg_note", "收尾结果未知")
            return Outcome("anomaly",
                           "%s: 子测试超时被强杀(%ss); 收尾%s —— %s"
                           % (name, e.timeout, "已完成" if reaped else "**未完成**", note),
                           set(), getattr(e, "pdg_rc", None),
                           _txt(e.output), _txt(e.stderr), halt=not reaped)
        except OSError as e:
            return Outcome("anomaly", "子测试启动失败(%s: %s)" % (name, e), set(), None, "", "")
        res = verdict(r.returncode, r.stdout, r.stderr)
        if res.status == "anomaly":
            return res._replace(reason="%s: %s" % (name, res.reason))
        merged |= res.failures
        worst = res if (worst is None or res.status == "failed") else worst
    return worst._replace(failures=merged)


def halt_now(stage, wd):
    """收尾没确认时的停机: 现场可能还有在跑的后代和没释放的锁。

    不删工作目录 —— 往一个可能还有进程在写的目录上 rmtree, 既可能删不干净, 也会把唯一能
    排查的残骸抹掉。tmpguard 的 PDG_KEEP_TMP 就是为留现场准备的公开开关, 这里只在停机这一
    条路上打开它, 并把路径说出来。
    """
    os.environ[tmpguard.KEEP_ENV] = "1"
    print("       %s: 现场保留在 %s(收尾未确认, 不删目录、不开下一格)" % (stage, wd))


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
    started = halted = False
    wd = tmpguard.mkdtemp(prefix="pdg-lockid-negctl.")
    try:
        for sub in ("tests", "deploy", "lib"):
            shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                            symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
        pristine = {TX: (Path(wd) / TX).read_text(encoding="utf-8")}
        base_res = run_suites(wd)
        base = base_res.failures
        if base_res.halt:
            refuse("基线", base_res)
            halt_now("基线", wd)
            started = False
        elif base_res.status == "anomaly":
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
            if got_res.halt:
                # 收尾没确认: 既不回滚工作副本(那是往可能还有进程在写的目录里写), 也不开
                # 下一格。带着污染的现场继续做实验, 后面每一格的结论都没有意义。
                refuse(label, got_res)
                halt_now(label, wd)
                halted = True
                break
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
    tail = ""
    if not started:
        tail = "(基线未通过, 变异未开跑)"
    elif halted:
        tail = "(收尾未完成, 已停机, 后续变异未开跑)"
    print("wloc-lock-identity-negative-controls.py: 通过 %d, 失败 %d%s"
          % (PASS[0], FAIL[0], tail))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

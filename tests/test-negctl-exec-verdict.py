#!/usr/bin/env python3
"""锁身份负控的**执行有效性判定**本身可不可信。

negctl/wloc-lock-identity-negative-controls.py 靠"跑一次子测试, 比较具名失败集合"下结论。
它曾经只拼 stdout+stderr 抓行首 [FAIL], 把退出码整个丢掉 —— 于是"压根没跑起来"和"判据
没牙"长得一模一样, 至少三种形态能冒充绿:

    rc=1 + Traceback + 零断言   → 空失败集合 → 基线判"全绿", 反向对照判"零新增";
    rc=0 + 只有说明文字         → 同上;
    打印目标 [FAIL] 后 rc=3     → 失败集合里有目标 → 变异判"有牙"。

本支盯两件事:
  ① verdict() 在**真实子进程**的各种结局上给出正确的三态(正常成功 / 正常断言失败 / 执行异常)
     —— 不是把字符串喂给辅助函数, 每一格都真的起一个进程跑出那个结局;
  ② 基线 / 变异 / 反向对照这三条**实际裁决路径**真的接上了判定。做法是搭一座微型假仓库
     (负控本体是真的, 子测试换成可控桩), 把负控整支跑起来, 直接断言它的最终退出码与输出。

只用自造数据与自有临时目录; 不碰真实生产锁、服务或配置。完整锁负控仍是本地手动门, 本支
是它的轻量正控。
"""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import sys
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]
NEGCTL = ROOT / "tests" / "negctl" / "wloc-lock-identity-negative-controls.py"

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


# 负控有 __main__ 守卫, 所以 import 它只拿到函数, 不会触发整支负控(那会 clone 仓库并真跑锁用例)。
_spec = importlib.util.spec_from_file_location("wloc_lock_negctl", NEGCTL)
_neg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_neg)

WORK = tmpguard.mkdtemp(prefix="pdg-negexec.")


# ══ 1. verdict(): 每一格都真起一个子进程, 拿它的真实结局来判 ═══════════════
print("══ 1. 三态判定(真实子进程) ══")

CASES = [
    ("正常成功",
     'print("[OK]   甲")\nprint("[OK]   乙")\nprint()\nprint("[SUM] OK=2 FAIL=0")\n'
     'raise SystemExit(0)',
     "ok", "2 条有效断言"),
    ("正常断言失败(rc=1 且有具名失败)",
     'print("[OK]   甲")\nprint("[FAIL] 乙没过")\nprint()\nprint("[SUM] OK=1 FAIL=1")\n'
     'raise SystemExit(1)',
     "failed", "1 条失败"),
    ("导入期崩溃, 零断言",
     'import nonexistent_module_for_this_test  # noqa',
     "anomaly", "未捕获异常"),
    ("rc=0 但零断言",
     'print("只是一段说明文字")\nraise SystemExit(0)',
     "anomaly", "[SUM]"),
    ("打印目标 [FAIL] 后 rc=3",
     'print("[FAIL] 目标断言")\nprint()\nprint("[SUM] OK=0 FAIL=1")\nraise SystemExit(3)',
     "anomaly", "退出码 3 超出"),
    ("被信号终止",
     'import os, signal\nprint("[OK]   先打一条")\nsys.stdout.flush()\n'
     'os.kill(os.getpid(), signal.SIGKILL)',
     "anomaly", "信号 SIGKILL"),
    ("rc=0 却有失败",
     'print("[FAIL] 有失败")\nprint()\nprint("[SUM] OK=0 FAIL=1")\nraise SystemExit(0)',
     "anomaly", "与失败数"),
    ("rc=1 却无失败",
     'print("[OK]   没失败")\nprint()\nprint("[SUM] OK=1 FAIL=0")\nraise SystemExit(1)',
     "anomaly", "与失败数"),
    ("说明文字引用断言标记, 零真实断言",
     'print("提示: 子进程里出现过 [FAIL] 与 [OK] 字样, 仅供参考")\n'
     'print("  [FAIL] 这行是缩进的引用")\nraise SystemExit(0)',
     "anomaly", "[SUM]"),
    ("SUM 与行首计数矛盾",
     'print("[OK]   一条")\nprint()\nprint("[SUM] OK=5 FAIL=0")\nraise SystemExit(0)',
     "anomaly", "不一致"),
]

for i, (label, body, want_status, want_in) in enumerate(CASES):
    script = Path(WORK) / ("case%d.py" % i)
    script.write_text("import sys\n" + body + "\n", encoding="utf-8")
    r = subprocess.run([sys.executable, str(script)], capture_output=True, text=True, timeout=120)
    res = _neg.verdict(r.returncode, r.stdout, r.stderr)
    chk(res.status == want_status and want_in in res.reason,
        "%s → %s(%s)" % (label, res.status, res.reason[:60])
        if res.status == want_status and want_in in res.reason
        else "%s → 期望 %s 且理由含「%s」, 实得 %s / %s"
             % (label, want_status, want_in, res.status, res.reason[:70]))

# 启动失败与超时不经过 returncode, 单独走一遍真实路径。
try:
    subprocess.run([str(Path(WORK) / "does-not-exist")], capture_output=True, timeout=30)
    _launch = ""
except OSError as e:
    _launch = str(e)
res = _neg.verdict(None, "", "", launch_error=_launch)
chk(_launch and res.status == "anomaly" and "启动失败" in res.reason,
    "启动失败 → anomaly(%s)" % res.reason[:60])

# 真的让它超时: run(stdin=PIPE) 不给 input 会立刻关掉 stdin, 读 stdin 挡不住 —— 用真 sleep。
blocker = Path(WORK) / "blocker.py"
blocker.write_text("import time\ntime.sleep(60)\n", encoding="utf-8")
try:
    subprocess.run([sys.executable, str(blocker)], capture_output=True, text=True, timeout=2)
    _timed = False
except subprocess.TimeoutExpired:
    _timed = True
chk(_timed, "前提: 那个子进程确实被超时强杀了(不是自己跑完的)")
res = _neg.verdict(None, "", "", timed_out=_timed)
chk(res.status == "anomaly" and "超时" in res.reason,
    "超时被强杀 → anomaly(%s)" % res.reason[:60])

# 退出码本身拿不到(既不是启动失败也不是超时)也必须拒, 不能拿 None 去比大小。
res = _neg.verdict(None, "[OK]   一条\n[SUM] OK=1 FAIL=0\n", "")
chk(res.status == "anomaly" and "退出码" in res.reason,
    "拿不到退出码 → anomaly(%s)" % res.reason[:60])


# ══ 2. 三条实际裁决路径 ═════════════════════════════════════════════════════
print()
print("══ 2. 基线 / 变异 / 反向对照(跑真负控) ══")

FAKE_TX = '''import fcntl
import os


def _fd_holds_lock(fd, st):
    return True


def inherited_lock_fd(path=None):
    fd = 9
    want = os.stat("/dev/null")
    if _fd_holds_lock(fd, want) is not True:                # ②
        return None                                         # False/None 都不足以证明
    return fd
'''

STUB = r'''#!/usr/bin/env python3
"""可控子测试桩: 先认出自己处在哪一格(基线/①②③④), 再按 STUB_PLAN 作答。"""
import os, signal, sys

TX = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                  "deploy", "bot", "pdgtx.py")
src = open(TX, encoding="utf-8").read()
if "_me = os.getpid()" in src:
    phase = "m1"
elif "def _flock_record(st):" in src:
    phase = "m2"
elif "is False:" in src:
    phase = "m3"
elif "负控的空转对照" in src:
    phase = "m4"
else:
    phase = "base"

TARGET = {"m1": "[FAIL] A 还持着锁时, B **没有**从继承捷径进临界区(桩)",
          "m2": "[FAIL] 注入第二次凭据读取失败 → **没有**把父进程那把锁解掉(桩)",
          "m3": "[FAIL] 证明不了 → 调用方不硬闯临界区, 按既有非阻塞语义拒绝(桩)"}


def normal():
    if phase in TARGET:
        print(TARGET[phase]); print("[OK]   桩: 其余断言")
        print(); print("[SUM] OK=1 FAIL=1"); sys.exit(1)
    print("[OK]   桩: 断言甲"); print("[OK]   桩: 断言乙")
    print(); print("[SUM] OK=2 FAIL=0"); sys.exit(0)


plan = os.environ.get("STUB_PLAN", "healthy")
if plan != "healthy" and os.environ.get("STUB_BREAK_PHASE", "") == phase:
    if plan == "crash_zero":
        raise RuntimeError("桩: 崩溃模拟")
    if plan == "rc0_zero":
        print("桩: 只有说明文字, 没有断言"); sys.exit(0)
    if plan == "target_then_rc3":
        print(TARGET.get(phase, "[FAIL] 桩: 目标断言"))
        print(); print("[SUM] OK=0 FAIL=1"); sys.exit(3)
    if plan == "hang":
        # 挂住不返回 —— 用来触发执行器那边的超时与收尾。
        print("[OK]   桩: 挂起前写出的标记"); sys.stdout.flush()
        import time as _t
        _t.sleep(600)
    raise SystemExit("桩: 未知形态 " + plan)
normal()
'''


def build_fake():
    """微型假仓库: 负控本体是真的, 子测试换成可控桩。"""
    dest = Path(tmpguard.mkdtemp(prefix="pdg-negexec-fake."))
    (dest / "tests" / "negctl").mkdir(parents=True)
    (dest / "deploy" / "bot").mkdir(parents=True)
    (dest / "lib").mkdir(parents=True)
    (dest / "lib" / ".keep").write_text("")
    shutil.copy2(ROOT / "tests" / "tmpguard.py", dest / "tests" / "tmpguard.py")
    shutil.copy2(NEGCTL, dest / "tests" / "negctl" / NEGCTL.name)
    (dest / "deploy" / "bot" / "pdgtx.py").write_text(FAKE_TX, encoding="utf-8")
    stub = dest / "tests" / "test-inherited-lock-proof.py"
    stub.write_text(STUB, encoding="utf-8")
    stub.chmod(0o755)
    return dest


def run_negctl(plan="healthy", phase=""):
    dest = build_fake()
    env = dict(os.environ, STUB_PLAN=plan, STUB_BREAK_PHASE=phase)
    env.pop("TMPDIR", None)
    r = subprocess.run([sys.executable, str(dest / "tests" / "negctl" / NEGCTL.name)],
                       cwd=str(dest), capture_output=True, text=True, timeout=600, env=env)
    return r.returncode, r.stdout + r.stderr


def line_for(out, needle):
    for ln in out.splitlines():
        if needle in ln and (ln.startswith("[OK]") or ln.startswith("[FAIL]")):
            return ln
    return ""


# 健康正路: 判定不能把正常执行误拒, 否则这层保护本身就是个新的假红来源。
rc, out = run_negctl()
chk(rc == 0 and "通过 6, 失败 0" in out,
    "健康: 负控 rc=0 且六格全过(实得 rc=%d / %s)"
    % (rc, (line_for(out, "通过 ") or out.strip().splitlines()[-1:] or [""])[0][:50]))
chk(line_for(out, "① 同 PID").startswith("[OK]"), "健康: 变异确实开跑了")

# 基线异常 → 必停, 不进入变异, 不打印"基线全绿"。
for plan, what in (("crash_zero", "崩溃且零断言"), ("rc0_zero", "rc=0 且零断言")):
    rc, out = run_negctl(plan, "base")
    base_line = line_for(out, "基线")
    chk(rc != 0, "基线%s → 负控非零结束(实得 rc=%d)" % (what, rc))
    chk(base_line.startswith("[FAIL]") and "没有正常执行" in base_line,
        "基线%s → 点名基线未正常执行(实得 %s)" % (what, base_line[:66] or "无基线行"))
    chk("正常跑完且全绿" not in out, "基线%s → **没有**打印「基线全绿」" % what)
    chk(not line_for(out, "① 同 PID"), "基线%s → 变异一格都没开跑" % what)
    chk("rc=" in out and ("stdout=" in out and "stderr=" in out),
        "基线%s → stdout/stderr/退出码分别留了证" % what)

# 变异异常 → 即使输出里已有目标 [FAIL], 也不算"有牙"。
rc, out = run_negctl("target_then_rc3", "m1")
m1 = line_for(out, "① 同 PID")
chk(m1.startswith("[FAIL]") and "没有正常执行" in m1,
    "变异①打印目标 [FAIL] 后 rc=3 → 不记有牙, 记执行异常(实得 %s)" % m1[:66])
chk("退出码 3 超出" in out, "变异①: 理由点明退出码越界")
chk(rc != 0, "变异①异常 → 负控非零结束(实得 rc=%d)" % rc)
chk(line_for(out, "② 回读失败").startswith("[OK]"), "变异①异常不影响其余格的裁决")

# 反向对照异常 → 不能冒充"零新增失败"。
rc, out = run_negctl("crash_zero", "m4")
m4 = line_for(out, "④ 只加一行无关注释")
chk(m4.startswith("[FAIL]") and "没有正常执行" in m4,
    "反向对照崩溃 → 不记通过, 记执行异常(实得 %s)" % m4[:66])
chk("新增失败 0 条" not in m4, "反向对照崩溃 → 没有冒充「零新增失败」")
chk(rc != 0, "反向对照异常 → 负控非零结束(实得 rc=%d)" % rc)


# ══ 3. 超时的收尾: 走真实 run_suites()/run() ═══════════════════════════════
print()
print("══ 3. 超时收尾(真实执行器) ══")
# 只把 timed_out=True 喂给 verdict() 是测不出这件事的 —— 问题在执行器那一层: 直接子进程
# 被杀, 不等于它启动的后代也结束了。后代还攥着锁、还连着管道, "超时"就没真正结束: 下一格
# 会在一把没人释放的锁上跑, 删工作目录时还可能撞上仍在写的进程。
#
# 所以这一节调**真实** run_suites(), 只覆盖它自己那次调用的预算(不动正式默认值 900s),
# 而且所有正式判据都在测试做任何兜底清理**之前**取。

import signal      # noqa: E402
import threading   # noqa: E402
import time        # noqa: E402


def proc_state(pid):
    """运行 / 僵尸 / 已回收 —— 单凭 kill(pid, 0) 分不开前两者。"""
    if pid is None:
        return "无 pid"
    try:
        with open("/proc/%d/stat" % pid) as f:
            st = f.read().rsplit(") ", 1)[1].split()[0]
    except OSError:
        return "已回收"
    return "僵尸" if st == "Z" else "运行(%s)" % st


PROBE = ("import fcntl, sys\n"
         "f = open(sys.argv[1], 'w')\n"
         "try:\n"
         "    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
         "except OSError:\n"
         "    sys.exit(1)\n"
         "sys.exit(0)\n")


def outsider_can_lock(path):
    """独立进程 = 独立 OFD, 不会被本进程的 fd 带偏。"""
    r = subprocess.run([sys.executable, "-c", PROBE, path], capture_output=True, timeout=60)
    return r.returncode == 0


DESCENDANT = (
    "import fcntl, os, sys, time\n"
    "f = open(sys.argv[1], 'w')\n"
    "fcntl.flock(f, fcntl.LOCK_EX)\n"                 # 后代持住本轮自造的临时锁
    "open(sys.argv[3], 'w').write(str(os.getpid()))\n"
    "print('DESCENDANT-READY'); sys.stdout.flush()\n"
    "print('DESCENDANT-STDERR', file=sys.stderr); sys.stderr.flush()\n"
    "open(sys.argv[2], 'w').write('1')\n"             # 就绪标记最后落地: 见到它前面就都成了
    "time.sleep(600)\n")

SUB_HEAD = ("import subprocess, sys, time\n"
            "print('[OK]   子测试: 超时前的 stdout 标记'); sys.stdout.flush()\n"
            "print('SUBTEST-STDERR', file=sys.stderr); sys.stderr.flush()\n")


def make_case(with_descendant):
    """造一次子测试调用。返回 (cmd, 锁路径, 就绪文件, pid 文件)。"""
    d = tmpguard.mkdtemp(prefix="pdg-negexec-reap.")
    lock = os.path.join(d, "descendant.lock")
    open(lock, "w").close()
    ready, pidf = os.path.join(d, "ready"), os.path.join(d, "pid")
    body = SUB_HEAD
    if with_descendant:
        body += ("subprocess.Popen([sys.executable, '-c', %r,\n"
                 "                  sys.argv[1], sys.argv[2], sys.argv[3]])\n" % DESCENDANT)
    body += "time.sleep(600)\n"
    script = Path(d) / "subtest.py"
    script.write_text(body, encoding="utf-8")
    return [sys.executable, str(script), lock, ready, pidf], lock, ready, pidf


def call_executor(cmd, budget, ready=None, pidf=None, lock=None):
    """跑真实 run_suites(); 顺便在**触发超时之前**把前提确认下来。"""
    state = {}

    def watch():
        t0 = time.monotonic()
        while time.monotonic() - t0 < 60:
            if os.path.exists(ready) and os.path.exists(pidf):
                try:
                    state["pid"] = int(open(pidf).read())
                except (OSError, ValueError):
                    return
                state["ready_at"] = time.monotonic()
                state["held_before"] = not outsider_can_lock(lock)   # 前提: 后代真持着锁
                state["state_before"] = proc_state(state["pid"])
                return
            time.sleep(0.01)

    th = threading.Thread(target=watch)
    if ready:
        th.start()
    old_budget, old_suites = _neg.SUITE_TIMEOUT, _neg.SUITES
    _neg.SUITE_TIMEOUT, _neg.SUITES = budget, (cmd,)
    t0 = time.monotonic()
    try:
        res = _neg.run_suites(os.path.dirname(cmd[1]))
    finally:
        _neg.SUITE_TIMEOUT, _neg.SUITES = old_budget, old_suites
    state["returned_at"] = time.monotonic()
    state["elapsed"] = state["returned_at"] - t0
    if ready:
        th.join(65)
    return res, state


def reap_leftover(pid):
    """测试自己的兜底清理 —— 与执行器的收尾**分开记**, 且只清本测试造出来的东西。"""
    if pid is None:
        return "无 pid"
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return "已不在(执行器收尾时就没了)"
    except OSError as e:
        return "兜底清理失败(%s)" % e
    t0 = time.monotonic()
    while time.monotonic() - t0 < 10:
        if proc_state(pid) == "已回收":
            return "兜底清掉了"
        time.sleep(0.02)
    return "兜底也没清掉"


# ── A. 普通超时: 没有后代 ──
cmd, lock, ready, pidf = make_case(False)
res, st = call_executor(cmd, 2)
chk(res.status == "anomaly" and "超时" in res.reason,
    "A 普通超时 → 裁决是超时异常(%s)" % res.reason[:66])
chk(res.halt is False and "收尾已完成" in res.reason, "A 普通超时 → 收尾已完成, 不停机")
chk(res.rc == -9, "A 普通超时 → 保留真实退出状态 rc=%r(被 SIGKILL), 不伪造" % (res.rc,))
chk("超时前的 stdout 标记" in (res.out or ""), "A 普通超时 → 超时前的 stdout 留住了")
chk("SUBTEST-STDERR" in (res.err or ""), "A 普通超时 → 超时前的 stderr 留住了")
chk(st["elapsed"] < 2 + _neg.REAP_BUDGET,
    "A 普通超时 → 收尾有界, 没有再卡一次(耗时 %.2fs, 上限 %ds)"
    % (st["elapsed"], 2 + _neg.REAP_BUDGET))

# ── B. 带后代的超时 ──
cmd, lock, ready, pidf = make_case(True)
res, st = call_executor(cmd, 4, ready, pidf, lock)
dpid = st.get("pid")

# 先确认前提真的成立过 —— 否则"后代没了"证明不了任何东西。
chk(dpid is not None and st.get("ready_at") is not None,
    "B 前提: 后代起来了并写出就绪标记(pid=%s)" % dpid)
chk(st.get("held_before") is True, "B 前提: 就绪时后代确实持着那把临时锁(外人抢不到)")
chk(str(st.get("state_before", "")).startswith("运行"),
    "B 前提: 就绪时后代处于运行态(实得 %s)" % st.get("state_before"))
chk(st.get("ready_at", 0) < st.get("returned_at", 0),
    "B 前提: 就绪发生在执行器返回**之前**, 不是事后才起来")

# 正式判据 —— 全部在测试做任何兜底清理之前取。
after_state = proc_state(dpid)
after_lock = outsider_can_lock(lock)
chk(after_state == "已回收", "B 执行器返回时后代已不运行且已被回收(实得 %s)" % after_state)
chk(after_lock, "B 执行器返回时独立 OFD 能取得那把临时锁(后代确实放手了)")
chk("超时前的 stdout 标记" in (res.out or "") and "DESCENDANT-READY" in (res.out or ""),
    "B 超时前的 stdout 标记仍在(子测试与后代两边都在)")
chk("SUBTEST-STDERR" in (res.err or "") and "DESCENDANT-STDERR" in (res.err or ""),
    "B 超时前的 stderr 标记仍在")
chk(res.status == "anomaly" and "超时" in res.reason,
    "B 裁决是超时异常, 不是正常成功也不是正常断言失败(实得 %s)" % res.status)
chk(res.halt is False and "收尾已完成" in res.reason, "B 收尾确认完成, 不停机")
chk(st["elapsed"] < 4 + _neg.REAP_BUDGET,
    "B 收尾没有无限等待(耗时 %.2fs, 上限 %ds)" % (st["elapsed"], 4 + _neg.REAP_BUDGET))
print("       [记账] 执行器收尾: %s ｜ 测试兜底: %s"
      % (res.reason.split("—— ")[-1], reap_leftover(dpid)))

# ── C. 清理失败(受控注入) ──
# 只注入**确认**那一步的失败: killpg 照常真的发出去, 所以不会留下真的杀不掉的进程。
# 要验的是"确认不了的时候怎么报、还继不继续"。
cmd, lock, ready, pidf = make_case(True)
_real_confirm = _neg._confirm_group_gone
_neg._confirm_group_gone = lambda pgid, budget=None: (False, "注入: 无权确认进程组状态")
try:
    res, st = call_executor(cmd, 4, ready, pidf, lock)
finally:
    _neg._confirm_group_gone = _real_confirm
dpid = st.get("pid")
chk(st.get("held_before") is True, "C 前提: 就绪时后代确实持着那把临时锁")
chk("超时" in res.reason and "收尾**未完成**" in res.reason,
    "C 原始超时与清理失败**同时**保留在报告里(%s)" % res.reason[-56:])
chk("注入: 无权确认进程组状态" in res.reason, "C 报告点名了清理失败的原因")
chk(res.halt is True, "C 收尾未确认 → halt=True, 上层据此停机")
chk("超时前的 stdout 标记" in (res.out or ""), "C 清理失败时也没有清空已有输出")
chk("已清干净" not in res.reason and "强杀完成" not in res.reason, "C 没有宣称已清干净")
print("       [记账] 执行器收尾: 未确认(受控注入) ｜ 测试兜底: %s" % reap_leftover(dpid))


# ── C2. 停机要一直传到驱动层: 后续变异不得开跑 ──
# ── C2 的临时目录: 归属先于清理 ───────────────────────────────────────────────
#
# 上一版从子负控的日志里**读出**一条路径就 rmtree 它, 只检查 startswith(临时目录)。
# 受控复核(删除调用全部拦截)证明这条通道给得太宽:
#     "现场保留在 /tmp/../home/codex/privdns-gateway" → 它真的把受保护主仓选成了删除目标。
# 换成 commonpath 也只能证明"在整个 /tmp 里", 证明不了"这个目录是本测试造的"。
#
# 所以干脆取消"日志内容赋予删除权限"这条通道:
#   · C2 开跑前, 由本测试建一个**唯一、专属**的父目录, 路径从创建那一刻就握在手里;
#   · 子负控的 TMPDIR 指到这个父目录(实测: tmpguard.mkdtemp 不传 dir 时走
#     tempfile.gettempdir(), 它认 TMPDIR) —— 只改这一个子进程的环境, 不动全局临时目录配置;
#   · 要删的永远只有这个父目录本身, 而不是日志里说的任何东西;
#   · 日志只用来**核对**"现场确实落在这个父目录里", 核对结果单独记账。核对失败不影响
#     清理本测试自己明确拥有、且已无进程使用的那个父目录 —— 那两件事互不代偿。
C2_OWNED = []        # 事先创建、能证明归属的父目录; 删除目标只可能来自这里
C2_LOGCHECK = []     # 日志核对结果(与删除授权无关)
C2_CLEANED = []      # 实际清理结果, 逐条核实


def _report_paths(out):
    """从报告里取出它点名的现场路径。纯解析, 不产生任何删除目标。"""
    return [ln.split("现场保留在 ", 1)[1].split("(")[0].strip()
            for ln in out.splitlines() if "现场保留在 " in ln]


def _verify_reported(owned, out):
    """核对报告点名的现场是不是**本轮这个专属父目录**里的东西。返回 (是否核对通过, 结论)。"""
    hits = _report_paths(out)
    if len(hits) != 1:
        return False, "报告里有 %d 条现场路径(应恰好 1 条), 不作数" % len(hits)
    raw = hits[0]
    real_owned, real = os.path.realpath(owned), os.path.realpath(raw)
    if os.path.islink(raw):
        return False, "报告路径是符号链接, 不认"
    if real == real_owned:
        return False, "报告指向专属父目录本身, 而不是它下面的现场"
    if os.path.commonpath([real, real_owned]) != real_owned:
        return False, "报告路径解析后落在专属父目录之外: %s" % real
    if not os.path.isdir(real):
        return False, "报告路径不是一个真实目录: %s" % raw
    return True, "现场在专属父目录内: %s" % os.path.relpath(real, real_owned)


def _users_of(path):
    """还有哪些进程的 cwd 或已打开的 fd 落在 path 下。用来确认"确实没人在用了"。"""
    real = os.path.realpath(path) + os.sep
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if (os.path.realpath("/proc/%s/cwd" % entry) + os.sep).startswith(real):
                found.append(entry + ":cwd")
                continue
            for fd in os.listdir("/proc/%s/fd" % entry):
                if (os.path.realpath("/proc/%s/fd/%s" % (entry, fd)) + os.sep).startswith(real):
                    found.append("%s:fd%s" % (entry, fd))
                    break
        except OSError:
            continue
    return found


def _wait_unused(path, budget=10):
    """有界等到没人用这个目录。不因为"日志打了一行"就假定进程已经结束。"""
    t0 = time.monotonic()
    while True:
        users = _users_of(path)
        if not users:
            return True, "无进程占用"
        if time.monotonic() - t0 >= budget:
            return False, "%ds 后仍有进程占用: %s" % (budget, users[:3])
        time.sleep(0.05)


def _rmtree_owned(path):
    """删掉本测试自己创建的那个父目录, 并**核实结果**。

    不用 ignore_errors —— 那会把"删失败了"和"本来就没有"混成一句话。
    rmtree 遇到目录内的符号链接是 unlink 掉它, 不会顺着链接删外面的东西; §4 有哨兵钉着这条。
    """
    if not os.path.isdir(path):
        return "已不在"
    try:
        shutil.rmtree(path)
    except OSError as e:
        return "清理失败(%s)" % e
    return "已删除" if not os.path.exists(path) else "调用了 rmtree 但目录仍在"


def cleanup_owned(owned, label="C2", record=True):
    """清理本测试事先掌握的那个父目录: 先确认没人用, 再删, 再核实。

    record=False 用于"删除调用被拦截"的那一格 —— 那一次本来就不会真删, 记进账本会把
    "拦截"和"清理失败"混为一谈。
    """
    free, why = _wait_unused(owned)
    if not free:
        if record:
            C2_CLEANED.append((owned, "未清理(%s)" % why))
        return "未清理(%s)" % why
    how = _rmtree_owned(owned)
    if record:
        C2_CLEANED.append((owned, how))
    return how


def run_negctl_patched(patches, plan="healthy", phase=""):
    """在假仓库里给负控**副本**打补丁再整支跑 —— 补丁只落在测试自有的副本上。

    返回 (rc, 输出, 本次专属父目录)。子负控的一切临时目录都落在那个父目录里。
    """
    dest = build_fake()
    f = dest / "tests" / "negctl" / NEGCTL.name
    txt = f.read_text(encoding="utf-8")
    for old, new in patches:
        if txt.count(old) != 1:
            return None, "锚点命中 %d 次: %s" % (txt.count(old), old[:40])
        txt = txt.replace(old, new, 1)
    f.write_text(txt, encoding="utf-8")
    # 专属父目录: 路径从**创建**那一刻就握在手里, 后面要删的只可能是它。
    owned = tmpguard.mkdtemp(prefix="pdg-negexec-c2own.")
    C2_OWNED.append(owned)
    # 只改这一个子进程的 TMPDIR —— 子负控的 tmpguard.mkdtemp 不传 dir, 走 gettempdir(),
    # 于是它建的每个目录(含停机时故意留下的现场)都落在 owned 里。全局配置不受影响。
    env = dict(os.environ, STUB_PLAN=plan, STUB_BREAK_PHASE=phase, TMPDIR=owned)
    env.pop(tmpguard.KEEP_ENV, None)
    r = subprocess.run([sys.executable, str(f)], cwd=str(dest), capture_output=True,
                       text=True, timeout=600, env=env)
    out = r.stdout + r.stderr
    # 日志只用来**核对**, 不用来挑删除目标。核不过就如实记一笔, 不改变任何删除行为。
    C2_LOGCHECK.append(_verify_reported(owned, out))
    return r.returncode, out, owned


rc, out, c2_owned = run_negctl_patched(
    [("SUITE_TIMEOUT = 900", "SUITE_TIMEOUT = 3"),
     ("def _confirm_group_gone(pgid, budget=REAP_BUDGET):",
      "def _confirm_group_gone(pgid, budget=REAP_BUDGET):\n"
      "    return False, '注入: 无权确认进程组状态'\n\n\n"
      "def _shelved_confirm(pgid, budget=REAP_BUDGET):")],
    plan="hang", phase="m1")
if rc is None:
    bad("C2 打不上补丁: %s" % out)
else:
    chk(rc != 0, "C2 收尾未完成 → 负控非零结束(实得 rc=%s)" % rc)
    chk("收尾**未完成**" in out, "C2 报告说了收尾未完成")
    chk("现场保留在" in out, "C2 停机时保留现场, 没有去删工作目录")
    chk(not line_for(out, "② 回读失败"), "C2 后续变异一格都没开跑")
    chk("已停机" in out, "C2 汇总行说明已停机")

# ── D. 正常对照: 正常结束不许被当成超时, 也不许被误杀 ──
_d = tmpguard.mkdtemp(prefix="pdg-negexec-ok.")
for _label, _body, _want, _rc in (
        ("健康成功", "[OK]   甲\n[OK]   乙\n\n[SUM] OK=2 FAIL=0\n", "ok", 0),
        ("正常 rc=1 且有具名失败", "[OK]   甲\n[FAIL] 乙没过\n\n[SUM] OK=1 FAIL=1\n", "failed", 1)):
    _sc = Path(_d) / ("ok-%s.py" % _want)
    _sc.write_text("import sys\nsys.stdout.write(%r)\nsys.exit(%d)\n" % (_body, _rc),
                   encoding="utf-8")
    res, _ = call_executor([sys.executable, str(_sc)], 60)
    chk(res.status == _want and res.rc == _rc and res.halt is False,
        "D %s → 裁决 %s / rc=%r / 不停机(实得 %s / %r / %r)"
        % (_label, _want, _rc, res.status, res.rc, res.halt))


# ══ 4. 清理的边界: 删谁由归属决定, 不由日志决定 ═════════════════════════════
print()
print("══ 4. C2 现场清理的边界 ══")
# 上一版从子负控的日志里读一条路径就删它, 只检查 startswith(临时目录)。受控复核(删除调用
# 全部拦截)证明这条通道能把 "/tmp/../home/codex/privdns-gateway" 选成删除目标。
# 现在删除目标只可能是本测试**事先创建**的那个专属父目录; 日志降级成核对材料。
# 所有危险反例只用两种方式跑: 拦截并记录删除调用, 或者全自有的哨兵目录。

# 造哨兵: 一个在专属父目录**外面**(供符号链接逃逸用), 一个是系统临时目录里的无关目录。
_out_sent = tmpguard.mkdtemp(prefix="pdg-negexec-outside.")
Path(_out_sent, "SENTINEL").write_text("外部哨兵: 必须活下来\n", encoding="utf-8")
_unrelated = tmpguard.mkdtemp(prefix="pdg-negexec-unrelated.")
Path(_unrelated, "SENTINEL").write_text("无关目录哨兵: 必须活下来\n", encoding="utf-8")


def sentinels_alive():
    return (Path(_out_sent, "SENTINEL").exists(), Path(_unrelated, "SENTINEL").exists())


# ── A. 合法路径: 真实停机现场确实落在专属父目录里, 并且能被正常清掉 ──
_ok_log, _why = C2_LOGCHECK[-1] if C2_LOGCHECK else (False, "没有核对记录")
chk(_ok_log, "A 日志核对: 报告点名的现场确实在本轮专属父目录内(%s)" % _why)
_inside = sorted(os.listdir(c2_owned)) if os.path.isdir(c2_owned) else []
chk(_inside, "A 停机现场真的留在专属父目录里(%s)" % (_inside[:2] or "空"))
_reported = _report_paths(out)
chk(len(_reported) == 1
    and os.path.commonpath([os.path.realpath(_reported[0]), os.path.realpath(c2_owned)])
    == os.path.realpath(c2_owned),
    "A 子负控确实被圈在专属父目录里(TMPDIR 生效, 报告路径 %s)"
    % (os.path.relpath(_reported[0], c2_owned) if _reported else "无"))

# 符号链接逃逸的哨兵: 放在**将被删除**的父目录里, 指向外面。
os.symlink(_out_sent, os.path.join(c2_owned, "escape-link"))

_how = cleanup_owned(c2_owned, "A")
chk(_how == "已删除",
    "A 清理结果经核实(实得 %s) —— 不是「调用过 rmtree」就算数" % _how)
chk(not os.path.exists(c2_owned), "A 专属父目录确已不在")
_o, _u = sentinels_alive()
chk(_o, "D 符号链接逃逸: 删父目录没有顺着链接删掉外部哨兵")
chk(Path(_out_sent).is_dir(), "D 外部目录本身仍在")
chk(_u, "C 无关目录(同在系统临时目录内)的哨兵完好")

# ── B/C/D/E. 伪造日志一律不改变删除目标 ──
# 这几格是**纯核对**: _verify_reported 不产生删除目标, 只给结论。
_probe_owned = tmpguard.mkdtemp(prefix="pdg-negexec-probe.")
_scene = os.path.join(_probe_owned, "pdg-lockid-negctl.fake")
os.makedirs(_scene)
os.symlink(_out_sent, os.path.join(_probe_owned, "link-out"))

# `..` 越界: 从专属父目录走出去, 落到本测试自己的外部哨兵上。用自有目录而不是真实主仓 ——
# 首份红灯里那次"解析到受保护主仓"的机制复现是在删除调用全程拦截下做的(见归档 10-red-first),
# 提交进来的用例不拿受保护对象当实验材料。
_ESCAPE = os.path.join(_probe_owned, "..", os.path.basename(_out_sent))

FORGED = [
    ("B  .. 越界(解析后落到专属父目录之外)",
     "       ①: 现场保留在 %s(收尾未确认)" % _ESCAPE, "之外"),
    ("C  无关目录(在系统临时目录内但不属于本次)",
     "       ①: 现场保留在 %s(收尾未确认)" % _unrelated, "之外"),
    ("D  符号链接",
     "       ①: 现场保留在 %s(收尾未确认)" % os.path.join(_probe_owned, "link-out"), "符号链接"),
    ("E1 父目录冒充子目录",
     "       ①: 现场保留在 %s(收尾未确认)" % _probe_owned, "父目录本身"),
    ("E2 报告缺失", "[FAIL] ①: 收尾**未完成**", "应恰好 1 条"),
    ("E3 报告歧义(两条互相矛盾)",
     "       ①: 现场保留在 %s(x)\n       ②: 现场保留在 %s(x)" % (_scene, _ESCAPE),
     "应恰好 1 条"),
]
for _label, _log, _want in FORGED:
    _got_ok, _got_why = _verify_reported(_probe_owned, _log)
    chk(_got_ok is False and _want in _got_why,
        "%s → 核对拒绝, 理由含「%s」(实得 %s)" % (_label, _want, _got_why[:56]))
_got_ok, _got_why = _verify_reported(_probe_owned, "       ①: 现场保留在 %s(ok)" % _scene)
chk(_got_ok, "A2 合法现场仍被接受 —— 不是「一律拒绝」的假修复(%s)" % _got_why)

# ── 决定性一格: 端到端证明日志内容改变不了实际删除目标 ──
# 给负控副本再打一行补丁, 让它**额外打印**几条伪造的"现场保留在"(含指向受保护主仓的那条),
# 然后把 shutil.rmtree 换成记录器跑一遍: 记到的删除目标必须只有本测试自己的专属父目录。
_FORGE = ('    print("       ①: 现场保留在 %s(伪造)")\n'
          '    print("       ①: 现场保留在 %s(伪造)")\n' % (_ESCAPE, _unrelated))
_calls = []
_real_rmtree = shutil.rmtree
shutil.rmtree = lambda path, *a, **kw: _calls.append(os.path.abspath(path))
try:
    _rc2, _out2, _owned2 = run_negctl_patched(
        [("SUITE_TIMEOUT = 900", "SUITE_TIMEOUT = 3"),
         ("def _confirm_group_gone(pgid, budget=REAP_BUDGET):",
          "def _confirm_group_gone(pgid, budget=REAP_BUDGET):\n"
          "    return False, '注入: 无权确认进程组状态'\n\n\n"
          "def _shelved_confirm(pgid, budget=REAP_BUDGET):"),
         ('    print("-" * 62)', _FORGE + '    print("-" * 62)')],
        plan="hang", phase="m1")
    if _rc2 is None:
        bad("决定性一格: 打不上补丁(%s)" % _out2)
        _owned2 = None
    else:
        cleanup_owned(_owned2, "forged", record=False)     # 这一次删除调用被拦截, 不记账
finally:
    shutil.rmtree = _real_rmtree

if _owned2 is not None:
    chk(_ESCAPE in _out2 and _unrelated in _out2,
        "决定性一格: 伪造的越界路径与无关目录确实出现在了日志里(注入生效)")
    chk(_calls == [os.path.abspath(_owned2)],
        "决定性一格: 实际删除目标只有本测试自己的专属父目录, 伪造路径一个都没进来(实得 %s)"
        % [os.path.basename(c) for c in _calls])
    _owned_roots = [os.path.realpath(d) for d in C2_OWNED]
    _stray = [c for c in _calls
              if not any(os.path.realpath(c) == r
                         or os.path.commonpath([os.path.realpath(c), r]) == r
                         for r in _owned_roots)]
    chk(not _stray,
        "决定性一格: 没有任何删除目标解析到本测试自有的专属父目录之外(实得 %s)" % _stray)
    _o2, _u2 = sentinels_alive()
    chk(_o2 and _u2, "决定性一格: 两个哨兵都完好")
    # 拦截期间没有真删, 这里如实补上(仍然只删本测试自己的那个父目录)。
    print("       [记账] 拦截期间未真删, 现补清: %s" % cleanup_owned(_owned2, "forged-真清"))
    chk(not os.path.exists(_owned2), "决定性一格: 补清之后专属父目录不在了")

shutil.rmtree(_probe_owned, ignore_errors=True)


# ══ 5. 收尾 ════════════════════════════════════════════════════════════════
print()
kids = []
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    try:
        with open("/proc/%s/stat" % entry) as fh:
            if int(fh.read().rsplit(") ", 1)[1].split()[1]) == os.getpid():
                kids.append(entry)
    except (OSError, IndexError, ValueError):
        continue
chk(not kids, "子进程: 本支起的进程都已回收(残留 pid %s)" % (kids or "无",))
chk(C2_OWNED and not [d for d in C2_OWNED if os.path.exists(d)],
    "临时目录: 本测试事先创建的 %d 个专属父目录都已清掉, 无残留" % len(C2_OWNED))
chk(all(how == "已删除" for _p, how in C2_CLEANED) and C2_CLEANED,
    "临时目录: 每一次清理的结果都经过核实(%s)"
    % ", ".join(sorted({how for _p, how in C2_CLEANED})))
print("       [记账] 被测清理(子负控自己的收尾): 见 §3 的 [记账] 行 ｜ "
      "本测试兜底清理: 专属父目录 %d 个, 日志核对 %d 次(通过 %d)"
      % (len(C2_OWNED), len(C2_LOGCHECK), sum(1 for okk, _ in C2_LOGCHECK if okk)))

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

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


# ══ 3. 收尾 ════════════════════════════════════════════════════════════════
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

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

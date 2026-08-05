#!/usr/bin/env python3
"""临时物卫生: **一支测试跑完, 它自己建的临时目录不该还在**。

起因是实测出来的: 跑一趟全量, /tmp 里就多出一批 `pdgtx-faults.*`(每天十几个)、
`pdgtx-box.*`(一趟五十个)、`/tmp/pdg-cidr-test-bin`、以及 e2e 脚本写的 `/tmp/e2e-*.out`。
都是沙箱, 跑完没人清。

判法有意选了"**私有 TMPDIR**"这一条路, 而不是"扫 /tmp 把匹配前缀的删掉":
  · 前缀扫描删的是**别人**的沙箱 —— 并发跑测试时隔壁进程正用着同名前缀的目录, 删了之后
    症状是"另一支测试莫名其妙红了", 排查成本极高;
  · 私有 TMPDIR 只观察"这一次这支测试造了什么", 不需要知道任何前缀, 也永远不会误伤;
  · 顺带把"写死 /tmp/xxx"这类 TMPDIR 管不到的路径逼出来 —— 那是最坏的一种(并发必冲突),
    所以静态那一节专门盯它。

五节:
  1. 动态 —— 选出的用例在私有 TMPDIR 下真跑一遍, 跑完那个目录必须是空的;
  2. 失败路径 —— 抛异常 / 非 0 退出 / SIGTERM 三条路都必须清干净(测试红的时候恰恰最容易漏);
  3. 留现场 —— PDG_KEEP_TMP=1 时必须**留着**, 且路径要打出来。这一节同时证明第 1 节不是
     因为"根本没建过目录"而通过的;
  4. 静态 —— 新写的用例不许再退回老写法(裸 tempfile.mkdtemp / 写死 /tmp 路径);
  5. E2E —— harness 自己那份 $E2E_TMP 同样要在退出/被杀时消失, 留现场时留着。
"""
import ast
import os
import re
import subprocess
import sys
import tokenize
from pathlib import Path

import tmpguard          # 这道门自己的探针目录也走它 —— 判据不能自己漏

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


# ── 动态那一节跑哪些 ────────────────────────────────────────────────────────
# 挑的是**这次真漏过**的那几种形态, 且都够快(全量里最慢的几支不进来, 这道门要能常跑):
#   · pdgtx-faults.*  —— 用例自己 mkdtemp 的顶层沙箱
#   · pdgtx-box.*     —— txbox 夹具建的沙箱(三支用例从来不调 clean())
#   · pdg-cidr-*      —— 写死路径改成一次性目录
#   · 一支 shell 用例 —— mktemp -d + trap 那条路也要有人盯
DYNAMIC = [
    "test-rule-hijack-sync.py",
    "test-snapshot-matrix.py",
    "test-cidr-input.py",
    "test-report-backend.py",
    "test-tfo.py",
    "test-explicit-proxy-nc.sh",
]

# 静态白名单: 允许出现写死 /tmp 的地方。判据分不清"写进去"和"只是提到", 所以这里逐条
# 记下理由 —— 想加一条就得说明它为什么不会在磁盘上留东西。
TMP_LITERAL_OK = {
    # ── shell ──
    # 一次性沙箱根自己的默认值 —— 它就是被清掉的那个东西, 不能再往 $E2E_TMP 里放。
    ("e2e-lib.sh", "/tmp/e2e-box."),
    ("e2e-lib.sh", "/tmp/e2e-inner."),
    # 这支盯的正是"不许再用固定共享路径", 断言里必须原样出现那个旧路径。
    ("test-e2e-probe-lifecycle.sh", "/tmp/e2e-tx-probe."),
    # 只渲染模板不跑 mosdns, 证书目录只是个占位字面量, 没人会去建它。
    ("test-hijack-shape.sh", "/tmp/nocert"),
    # 判据本身就是"凭据不许落在 /tmp", 不提这个词就没法验。
    ("test-rescue-constants.sh", "/tmp/*"),
    # ── python(都是"被拒绝/被记录的路径字面量", 谁也不会去创建它) ──
    ("test-e2e-repo-guard.py", "/tmp/nope.git"),      # 守卫必须拒掉的 remote URL
    ("test-e2e-repo-guard.py", "/tmp/x.git"),         # 同上
    ("test-invariants.py", "/tmp/pdg-update-staging"),   # 快照对比用的样例值
    ("test-render-refusal.py", "/tmp/%s/x.list"),        # 渲染必须拒绝的路径
    ("test-restore-transaction.py", "/tmp/rs/foo.json"),  # 恢复必须拒绝的绝对路径
    ("test-wda-mihomo.py", "/tmp/unlock.json"),          # 配置样例里的路径, 不落盘
    # 观察 E2E 残留用的常量; 没有 $E2E_TMP 时的回退值, 只读不写。
    ("update_invariants.py", "/tmp"),
    # TMPDIR 没设时的回退值 —— 观察点跟着 TMPDIR 走, 这里只是兜底。
    ("test-ios-profile-snapshot-exact.py", "/tmp"),
    # tar 安全用例: linkname 故意指到解压根之外, 那个值就得是这个字面量。
    ("test-restore-tar-safety.py", "/tmp"),
}


def run(cmd, env=None, cwd=None, timeout=900):
    e = dict(os.environ)
    if env:
        e.update(env)
    return subprocess.run(cmd, cwd=str(cwd or ROOT), env=e, timeout=timeout,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def run_isolated(name, keep=False, timeout=900):
    """在一个私有空 TMPDIR 里跑一支测试, 返回 (rc, 该目录里剩下的东西, 目录路径)。"""
    box = tmpguard.mkdtemp(prefix="hygiene-probe.")
    t = TESTS / name
    cmd = [sys.executable, str(t)] if name.endswith(".py") else ["bash", str(t)]
    env = {"TMPDIR": box}
    if keep:
        env["PDG_KEEP_TMP"] = "1"
    else:
        env.pop("PDG_KEEP_TMP", None)
        env["PDG_KEEP_TMP"] = ""
    r = run(cmd, env=env, timeout=timeout)
    return r, sorted(os.listdir(box)), box


def main():
    print("── 1. 跑完不留自己建的临时目录 ──")
    for name in DYNAMIC:
        if not (TESTS / name).exists():
            bad("%s 不存在(名单该更新了)" % name)
            continue
        try:
            r, left, _box = run_isolated(name)
        except subprocess.TimeoutExpired:
            bad("%s 超时" % name)
            continue
        if r.returncode != 0:
            # 这道门只管"清没清干净"。用例本身红了要如实说, 但别把它算成卫生问题。
            bad("%s 本身没通过(rc=%d), 卫生结论无从谈起: %s"
                % (name, r.returncode, r.stdout.strip().splitlines()[-1:] or ""))
            continue
        if left:
            bad("%s 跑完还留着 %d 个: %s" % (name, len(left), left[:4]))
        else:
            ok("%s: 私有 TMPDIR 跑完是空的" % name)

    print()
    print("── 2. 失败路径也要清(红灯时最容易漏的就是这里) ──")
    # 造一支必然失败的用例: 建目录 → 按要求的方式死。三条路都得清干净。
    child = TESTS / "_tmp_hygiene_child.py"
    child.write_text(
        "import os, signal, sys\n"
        "sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\n"
        "import tmpguard\n"
        "d = tmpguard.mkdtemp(prefix='hygiene-child.')\n"
        "open(os.path.join(d, 'x'), 'w').write('x')\n"
        "print(d)\n"
        "how = sys.argv[1]\n"
        "if how == 'raise':\n"
        "    raise RuntimeError('故意炸')\n"
        "if how == 'exit':\n"
        "    sys.exit(3)\n"
        "if how == 'sigterm':\n"
        "    os.kill(os.getpid(), signal.SIGTERM)\n",
        encoding="utf-8")
    try:
        for how, why in (("raise", "抛异常"), ("exit", "非 0 退出"), ("sigterm", "被 SIGTERM 杀")):
            box = tmpguard.mkdtemp(prefix="hygiene-probe.")
            r = run([sys.executable, str(child), how], env={"TMPDIR": box, "PDG_KEEP_TMP": ""},
                    timeout=60)
            left = sorted(os.listdir(box))
            if left:
                bad("%s 时没清干净: %s" % (why, left))
            else:
                ok("%s: 临时目录仍被清掉(rc=%d)" % (why, r.returncode))
    finally:
        child.unlink(missing_ok=True)

    print()
    print("── 3. PDG_KEEP_TMP=1 要留现场 ──")
    # 这一节还有第二个作用: 证明第 1 节的"空"是真的清掉了, 而不是压根没建过。
    probe = TESTS / "_tmp_hygiene_child.py"
    probe.write_text(
        "import os, sys\n"
        "sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\n"
        "import tmpguard\n"
        "print(tmpguard.mkdtemp(prefix='hygiene-keep.'))\n",
        encoding="utf-8")
    try:
        box = tmpguard.mkdtemp(prefix="hygiene-probe.")
        r = run([sys.executable, str(probe)], env={"TMPDIR": box, "PDG_KEEP_TMP": "1"}, timeout=60)
        left = sorted(os.listdir(box))
        if len(left) == 1 and left[0].startswith("hygiene-keep."):
            ok("PDG_KEEP_TMP=1: 目录留着了(%s)" % left[0])
        else:
            bad("PDG_KEEP_TMP=1 却没留下: %s" % left)
        if "PDG_KEEP_TMP" in r.stdout and left and left[0] in r.stdout:
            ok("留现场时把路径打出来了(不用自己去 /tmp 里翻)")
        else:
            bad("留现场没打印路径: %s" % r.stdout.strip()[-160:])

        box2 = tmpguard.mkdtemp(prefix="hygiene-probe.")
        run([sys.executable, str(probe)], env={"TMPDIR": box2, "PDG_KEEP_TMP": ""}, timeout=60)
        if os.listdir(box2):
            bad("默认(不设 PDG_KEEP_TMP)竟然也留着 —— 默认必须是清")
        else:
            ok("默认就是清(留现场是显式开关, 不是默认行为)")
    finally:
        probe.unlink(missing_ok=True)

    print()
    print("── 4. 不许退回老写法 ──")
    # (a) 顶层沙箱必须走 tmpguard。带 dir= 的是建在别人沙箱里的子目录, 父目录清掉时
    #     它自然跟着走, 不必登记。
    #     走 AST 而不是 grep: 负控文件里的改坏器**字符串**恰好含 `tempfile.mkdtemp(`,
    #     按文本扫会把它算成违规 —— 那种假红比漏报更烦, 因为没人能"修"它。
    offenders = []
    for f in sorted(TESTS.glob("*.py")) + sorted((TESTS / "negctl").glob("*.py")):
        if f.name in ("tmpguard.py", "test-tmp-hygiene.py"):
            continue
        try:
            tree = ast.parse(f.read_text(encoding="utf-8"))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fn = node.func
            if not (isinstance(fn, ast.Attribute) and fn.attr == "mkdtemp"
                    and isinstance(fn.value, ast.Name) and fn.value.id == "tempfile"):
                continue
            if not any(k.arg == "dir" for k in node.keywords):
                offenders.append("%s:%d" % (f.name, node.lineno))
    if offenders:
        bad("这些地方还在裸调 tempfile.mkdtemp(顶层沙箱必须走 tmpguard): %s"
            % offenders[:6])
    else:
        ok("tests/ 里没有裸调 tempfile.mkdtemp 的顶层沙箱")

    # (b) 写死的 /tmp 路径。TMPDIR 管不到它们, 所以第 1 节看不见 —— 但并发跑必然互相踩,
    #     而且跑完照样留在宿主的 /tmp 里。注释和 docstring 里的不算(那是在讲历史)。
    #     裸 "/tmp"(不带斜杠)同样要抓: `os.listdir("/tmp")` 这类"观察点写死了"的写法,
    #     在私有 TMPDIR 下会看向错误的目录, 判据于是静默失效 —— 比漏清更难发现。
    lits = []
    for f in sorted(TESTS.glob("*.py")):
        if f.name == "test-tmp-hygiene.py":
            continue
        try:
            with open(f, "rb") as fh:
                toks = list(tokenize.tokenize(fh.readline))
        except (tokenize.TokenError, SyntaxError):
            continue
        # docstring 不算: 那是在讲历史("老写法认 /tmp/mihomo"), 不是在写路径。
        # 判法 = 该 STRING 自成一条语句(前一个有效 token 是 ENCODING/NEWLINE/INDENT/DEDENT)。
        prev = tokenize.ENCODING
        for t in toks:
            if t.type == tokenize.STRING and re.search(r"/tmp(/|['\"])", t.string):
                is_doc = prev in (tokenize.ENCODING, tokenize.NEWLINE,
                                  tokenize.INDENT, tokenize.DEDENT)
                allowed = any(f.name == n and p in t.string for n, p in TMP_LITERAL_OK)
                if not is_doc and not allowed:
                    lits.append("%s:%d" % (f.name, t.start[0]))
            if t.type not in (tokenize.COMMENT, tokenize.NL):
                prev = t.type
    for f in sorted(TESTS.glob("*.sh")) + sorted((TESTS / "negctl").glob("*.sh")):
        for i, line in enumerate(f.read_text(encoding="utf-8").split("\n"), 1):
            code = line.split("#", 1)[0]
            if "/tmp/" not in code:
                continue
            if any(f.name == n and p in code for n, p in TMP_LITERAL_OK):
                continue
            lits.append("%s:%d" % (f.name, i))
    if lits:
        bad("写死的 /tmp 路径(改用 tmpguard.mkdtemp / $E2E_TMP / ${TMPDIR:-/tmp}): %s"
            % lits[:8])
    else:
        ok("tests/ 里没有写死的 /tmp 路径")

    print()
    print("── 5. E2E harness 自己的临时目录 ──")
    # 不跑整支 E2E(那要一两分钟), 直接驱动 e2e-lib.sh 的那段: 建 $E2E_TMP → 往里写点东西 →
    # 按指定方式退出。三条路分别断言"没了 / 没了 / 还在", 判的是真实的目录存在与否。
    harness = ("set -u\n"
               'source "%s/e2e-lib.sh"\n'
               "e2e_tmp_init || exit 9\n"
               'echo "TMP=$E2E_TMP"\n'
               'mkdir -p "$E2E_TMP/e2e-svc"; : > "$E2E_TMP/e2e-calls.log"\n'
               "%s\n") % (TESTS, "%s")
    for how, cmd, keep, want_gone in (
            ("正常退出", "exit 0", False, True),
            ("非 0 退出", "exit 4", False, True),
            ("被 SIGTERM 杀", "kill -TERM $$", False, True),
            ("PDG_KEEP_TMP=1", "exit 0", True, False)):
        box = tmpguard.mkdtemp(prefix="hygiene-probe.")
        env = {"TMPDIR": box, "PDG_KEEP_TMP": "1" if keep else ""}
        r = run(["bash", "-c", harness % cmd], env=env, timeout=120)
        m = re.search(r"^TMP=(.+)$", r.stdout, re.M)
        if not m:
            bad("e2e_tmp_init 没建出目录(%s): %s" % (how, r.stdout.strip()[-160:]))
            continue
        gone = not os.path.isdir(m.group(1).strip())
        if gone == want_gone:
            ok("e2e harness %s: 临时目录%s" % (how, "已清掉" if gone else "留着了(留现场)"))
        else:
            bad("e2e harness %s: 期望%s, 实际%s"
                % (how, "清掉" if want_gone else "留着", "清掉" if gone else "留着"))


    print("─" * 46)
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    if PASS[0] + FAIL[0] == 0:
        print("零断言 —— 判失败")
        return 1
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

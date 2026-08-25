#!/usr/bin/env python3
"""CI 覆盖守卫: 每个测试文件都必须真的被 workflow 调用。

为什么需要它: 本轮盘点发现 6 个测试文件从来没进过 CI —— 其中 4 个是 5.2 这一路新写的。
它们在本地跑得好好的, 谁也没注意到远端根本没跑。测试不进 CI 等于没有: 改坏了不会有人知道,
而"本地跑过"这件事不会随代码一起留下来。

这条守卫只认**文件名出现在 workflow 里**这一个事实。它防不住"步骤被注释掉"之类的花样,
但能挡住最常见也最容易发生的那一种: 新写了用例、忘了登记。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CI = os.path.join(ROOT, ".github/workflows/ci.yml")

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


# 这些不是用例, 是被用例 import 的夹具/工具 —— 它们的覆盖来自调用它们的用例。
HELPERS = {
    "rescuebox.py", "rescueform.py", "snapmatrix.py", "txbox.py", "mihomobin.py",
    "mock_dns.py", "mock_socks.py", "sni_client.py", "e2e-lib.sh", "prepare-mihomo.sh",
    "prepare-mosdns.sh", "update_invariants.py", "lan-fixture.sh",
}

if not os.path.exists(CI):
    bad("找不到 .github/workflows/ci.yml")
    print("\n断言 1 项: 通过 0, 失败 1")
    sys.exit(1)

ci = open(CI, encoding="utf-8").read()

files = sorted(f for f in os.listdir(HERE)
               if (f.startswith("test-") or f.startswith("e2e-") or f == "functional-test.sh"
                   or f.startswith("dns-policy"))
               and (f.endswith(".py") or f.endswith(".sh")))
files = [f for f in files if f not in HELPERS]

print("== 1. 每个测试文件都要出现在 workflow 里 ==")
# 只认**非注释行**。注释里提一句文件名不是登记 —— 负控 NC-CI-1 就是这么发现的:
# 把 e2e-dot-migrate.sh 的 matrix 条目整条删掉, 守卫仍绿, 因为同 job 的注释里解释过
# 它为什么用那个域名。那种"登记"跑不了任何东西。
ci_exec = "\n".join(l for l in ci.splitlines() if not l.lstrip().startswith("#"))
missing = [f for f in files if f not in ci_exec]
if not missing:
    ok("%d 个测试文件全部被 ci.yml 引用" % len(files))
else:
    bad("这些测试文件没进 CI(写了等于没写): %s" % "、".join(missing))

print("\n== 2. 关键测试必须在名单里 ==")
# 点名的是本轮及 5.2 全程新增/改动最大的那些。它们要是掉出 CI, 上面那条也会红, 但点名能让
# 失败信息直接说清是哪一块没了覆盖, 而不是丢一串文件名。
KEY = {
    "事务核心": "test-config-transaction.py",
    "事务故障注入": "test-config-transaction-faults.py",
    "事务恢复": "test-rescue-recover.py",
    "救援生命周期": "test-rescue-lifecycle.sh",
    "救援来源过滤": "test-rescue-source.py",
    "救援表单闭环": "test-rescue-formflow.py",
    "资源与中断": "test-rescue-interrupt.py",
    "卸载保留用户防火墙": "test-uninstall-firewall.py",
    "重装保留用户数据": "test-reinstall-preserve.py",
    "跨版本快照矩阵": "test-snapshot-matrix.py",
    "安装闭包": "test-install-closure.py",
    "Mihomo 渲染与钉版": "test-rescue-sets.py",
}
gone = [k for k, f in KEY.items() if f not in ci]
if not gone:
    ok("%d 项关键测试均在 CI 名单内" % len(KEY))
else:
    bad("关键测试掉出 CI: %s" % "、".join(gone))

print("\n== 3. 严格模式与钉死内核 ==")
if re.search(r"PDG_TEST_STRICT:\s*[\"']?1", ci):
    ok("workflow 开了 PDG_TEST_STRICT=1(缺关键能力判失败, 不许 SKIP 冒充通过)")
else:
    bad("workflow 没开 PDG_TEST_STRICT —— 缺 mihomo/nft 时会 SKIP 成绿")
if "prepare-mihomo.sh" in ci:
    ok("workflow 会准备钉死版 Mihomo")
else:
    bad("workflow 没有准备 Mihomo 的步骤")
# mosdns 同样是硬前提: 事务的候选校验会真启动它。少了这一步, 需要真 mosdns 的用例会在
# CI 上整片失败, 而本地因为有残留二进制照样全绿 —— v1.7.0 的第一次真实 CI 就是这么红的。
if "prepare-mosdns.sh" in ci:
    ok("workflow 会准备钉死版 mosdns")
else:
    bad("workflow 没有准备 mosdns 的步骤 —— 需要真 mosdns 的事务用例会在 CI 上失败")

print("\n== 4. 需要 root/nft 的测试必须拿到 root ==")
# 拿 root 有两条路: 容器 job 里本来就是 root, 或者在 runner 上 `sudo -E`(GitHub 的 ubuntu
# runner 免密 sudo, 项目里 e2e-rescue-10b.sh 一直是这么跑的)。没拿到 root 的话, nft 那几条
# 会 SKIP —— 而 CI 里 SKIP 不算通过。
ROOT_TESTS = ("test-uninstall-firewall.py",)
blocks = re.split(r"\n  (?=[a-z0-9-]+:\n)", ci)
containered = "".join(b for b in blocks if "container:" in b)
notroot = []
for t in ROOT_TESTS:
    if t not in ci:
        continue
    if t in containered:
        continue
    if re.search(r"sudo -E[^\n]*" + re.escape(t), ci):
        continue
    notroot.append(t)
if not notroot:
    ok("%d 项需要 root/nft 的测试都能拿到 root(容器 job 或 sudo -E)" % len(ROOT_TESTS))
else:
    bad("这些测试需要 root 却没有 root: %s" % "、".join(notroot))

print()
print("== 5. 静态守卫不许顶替真实行为测试 ==")
# tests/test-release-flow.sh 只核对源码里的标识符, 不跑任何流程。它一度在 CI 里挂着
# "发布链路回归"的名字, 于是"发布链路有覆盖"这句话名不副实 —— 只要标识符还在, 链路真坏了
# 也照绿。名字已经改成"静态守卫", 但光改名挡不住下一次: 有人把下面两支真实 E2E 从
# workflow 里摘掉(嫌慢), 静态守卫仍然绿, 覆盖就又空了。所以这条盯的是**它们还在不在**。
BEHAVIOURAL = ("e2e-update.sh", "e2e-upgrade-from-release.sh")
missing = [t for t in BEHAVIOURAL if t not in ci]
if not missing:
    ok("发布链路的两支真实行为 E2E 都还接在 workflow 里(%s)" % "、".join(BEHAVIOURAL))
else:
    bad("真实行为 E2E 从 workflow 里消失了: %s —— 只剩静态守卫的话, "
        "「发布链路有覆盖」就是假的" % "、".join(missing))
_rf_path = os.path.join(HERE, "test-release-flow.sh")     # HERE 是 str, 不是 Path
_rf = open(_rf_path, encoding="utf-8").read() if os.path.exists(_rf_path) else ""
if not _rf:
    bad("找不到 test-release-flow.sh, 无法核对它的自我描述")
elif "静态守卫" in _rf and "不是端到端" in _rf:
    ok("静态守卫自己写明了「不是端到端」, 并指向真实行为测试")
else:
    bad("test-release-flow.sh 没把自己说清楚(必须写明它是静态守卫、不是端到端)")
for _name in ("发布链路静态守卫", "e2e-update"):
    if _name in ci:
        ok("CI step 名称如实: 含「%s」" % _name)
    else:
        bad("CI step 名称里找不到「%s」—— 别把 grep 测试描述成端到端验证" % _name)

print()
print("== 6. 容器 job 的 shell 与快照路径闭包 ==")
# 这一节盯的是**接线**而不是被测代码 —— 两条都是真在远端红过的:
#   · e2e-dot 在 debian:12 容器里跑, GitHub 对 run: 的默认 shell 是 sh(=dash), dash 不认
#     `-o pipefail`, 于是"装 mosdns 并校验 SHA256"那步以 "Illegal option" 退出 2。本地
#     用 bash 跑同一段永远复现不出来。
#   · dot-systemd 的快照准备写死一个路径, 而 e2e-dot-systemd.sh 的默认回落是另一个,
#     两处各自都"对", 合起来 source e2e-lib.sh 就 No such file。
# 判据都做成结构化的: 按缩进切 job / 切 step, 只看该 step 自己的 run: 与 shell:, 不做
# 全文关键词计数 —— 计数式判据在别处加一行同名文本就会被糊弄过去。


def _jobs(src):
    """{job 名: 该 job 的原文}。job 是 jobs: 下缩进 2 空格的键。"""
    out, cur, buf = {}, None, []
    for line in src.splitlines(True):
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            if cur:
                out[cur] = "".join(buf)
            cur, buf = m.group(1), [line]
        elif cur:
            buf.append(line)
    if cur:
        out[cur] = "".join(buf)
    return out


def _steps(job_src):
    """[(step 原文, step 名)]。step 以缩进 6 的 `- ` 起头。"""
    out, buf = [], None
    for line in job_src.splitlines(True):
        if re.match(r"^      - ", line):
            if buf is not None:
                out.append("".join(buf))
            buf = [line]
        elif buf is not None:
            if line.strip() and not re.match(r"^       ", line):
                out.append("".join(buf))
                buf = None
            else:
                buf.append(line)
    if buf is not None:
        out.append("".join(buf))
    return [(s, (re.search(r"name:\s*(.+)", s) or [None, "(无名步骤)"])[1].strip()) for s in out]


def _run_body(step):
    """step 里 run: 块的正文。用来区分"这步真的写了 pipefail"和"名字里有这个词"。"""
    m = re.search(r"^        run:(.*)$", step, re.M)
    if not m:
        return ""
    body, started = [m.group(1)], False
    for line in step[m.end():].splitlines(True):
        if not started and not line.strip():
            continue
        if line.strip() and not re.match(r"^          ", line):
            break
        started = True
        body.append(line)
    return "".join(body)


jobs = _jobs(ci)
for _j in ("e2e-dot", "dot-systemd"):
    if _j not in jobs:
        bad("workflow 里找不到 job `%s` —— 6.2A 的 DoT 覆盖没了" % _j)

if "e2e-dot" in jobs:
    _job = jobs["e2e-dot"]
    # job 级 defaults 也算"显式声明 bash", 不强求每步都写
    _dflt = re.search(r"^    defaults:\n(?:.*\n)*?      shell:\s*bash\s*$", _job, re.M)
    _naked = []
    for _s, _n in _steps(_job):
        if "pipefail" not in _run_body(_s):
            continue
        if _dflt or re.search(r"^        shell:\s*bash\s*$", _s, re.M):
            continue
        _naked.append(_n)
    if not _naked:
        _cnt = sum(1 for _s, _ in _steps(_job) if "pipefail" in _run_body(_s))
        ok("e2e-dot: %d 个用了 pipefail 的步骤都显式声明了 bash(容器默认 sh=dash 不认 pipefail)"
           % _cnt)
    else:
        bad("e2e-dot 这些步骤用了 pipefail 却没写 `shell: bash`, 在 debian 容器里会以 "
            "\"Illegal option -o pipefail\" 直接失败: %s" % "、".join(_naked))

if "dot-systemd" in jobs:
    _job = jobs["dot-systemd"]
    _m = re.search(r"^    env:\n(?:      [A-Za-z0-9_]+:.*\n)*?      PDG_DOTW_REPO:\s*(\S+)\s*$",
                   _job, re.M)
    if not _m:
        bad("dot-systemd 没有在 job 级定义 PDG_DOTW_REPO —— 快照路径就没有唯一来源, "
            "脚本会回落到它自己的默认值而 source 不到 e2e-lib.sh")
    else:
        _path = _m.group(1)
        ok("dot-systemd 在 job 级定义了唯一快照根 PDG_DOTW_REPO=%s" % _path)
        # 闭包: 这个字面量除了定义处, 不许在任何 run:/注释里再出现一次
        _dup = [ln for ln in _job.splitlines()
                if _path in ln and not re.match(r"^      PDG_DOTW_REPO:", ln)]
        if _dup:
            bad("dot-systemd 路径闭包破了: 字面量 %s 在定义处之外还出现 %d 次(%s) —— "
                "两份路径各自都对、合起来不成立, 正是上次远端红的形态"
                % (_path, len(_dup), _dup[0].strip()[:60]))
        else:
            ok("dot-systemd 路径闭包成立: %s 只在定义处出现一次" % _path)
        # 准备快照与执行测试必须都走这个变量
        _prep = [(_s, _n) for _s, _n in _steps(_job) if "git archive" in _run_body(_s)]
        _exec = [(_s, _n) for _s, _n in _steps(_job)
                 if "e2e-dot-systemd.sh" in _run_body(_s)]
        for _what, _hits in (("快照准备(git archive)", _prep), ("执行 e2e-dot-systemd.sh", _exec)):
            if len(_hits) != 1:
                bad("dot-systemd 里「%s」的步骤有 %d 个, 预期恰好 1 个" % (_what, len(_hits)))
            elif re.search(r"\$\{?PDG_DOTW_REPO\b", _run_body(_hits[0][0])):
                ok("dot-systemd 「%s」引用 $PDG_DOTW_REPO" % _what)
            else:
                bad("dot-systemd 「%s」没有引用 $PDG_DOTW_REPO(步骤: %s)" % (_what, _hits[0][1]))
        # 进门前提: source 得到 e2e-lib.sh 这条必须先被断言, 否则又是"跑起来才发现路径错"
        if re.search(r'test -f "\$PDG_DOTW_REPO/tests/e2e-lib\.sh"', _job):
            ok("dot-systemd 在跑测试前先断言 $PDG_DOTW_REPO/tests/e2e-lib.sh 存在")
        else:
            bad("dot-systemd 没有前置断言 e2e-lib.sh 存在 —— 路径错了要等脚本跑崩才知道")

print()
print("== 7. 真 systemd+mosdns E2E job 的接线 ==")
# 这一节盯 dot-systemd-e2e。它是唯一同时给到真 PID1 systemd 与真 mosdns 的 job, 两支
# 最容易假绿的 E2E 挂在上面 —— 接线一松, 它们会以"整支 SKIP 然后 rc=0"的形态逃生, 而
# job 照样绿。判据全部按 job/step 切片, 不做全文关键词计数。
_J = "dot-systemd-e2e"
if _J not in jobs:
    bad("找不到 %s job —— 两支真 systemd E2E 没有执行路径" % _J)
else:
    _job = jobs[_J]
    # ① 每格都必须显式带上隔离门。少了它, 脚本进门就 SKIP 并 rc=0。
    _iso = [(_s, _n) for _s, _n in _steps(_job) if "PDG_E2E_ISOLATED=1" in _run_body(_s)]
    # 只认**真的去执行**的步骤: 光提到文件名不算(快照那步会 test -f 断言夹具存在,
    # 那是检查不是执行 —— 早期版本的选择器把它数了进来, 报了一条假阳性)。
    _runs = [(_s, _n) for _s, _n in _steps(_job)
             if re.search(r"bash \"\$PDG_DOTE2E_SNAP/tests/", _run_body(_s))]
    if len(_runs) < 2:
        bad("%s 里找不到夹具与测试两步(实得 %d) —— 判据失效" % (_J, len(_runs)))
    elif len(_iso) < len(_runs):
        bad("%s 有 %d 步在跑夹具/测试, 却只有 %d 步带 PDG_E2E_ISOLATED=1 —— "
            "缺了那步会让脚本整支 SKIP 却仍 rc=0" % (_J, len(_runs), len(_iso)))
    else:
        ok("%s 的夹具与测试步骤都带 PDG_E2E_ISOLATED=1(%d 步)" % (_J, len(_iso)))
    # ② 用了 pipefail 就必须显式 shell: bash(GitHub 默认 sh; ubuntu runner 上是 dash 语义之外
    #    的 bash-as-sh, 但显式声明才是这条守卫的意义 —— 别让别的 job 的教训在这里重演)
    _bad = [_n for _s, _n in _steps(_job)
            if "pipefail" in _run_body(_s) and not re.search(r"^        shell:\s*bash\s*$", _s, re.M)]
    (ok if not _bad else bad)(
        "%s 所有用 pipefail 的步骤都声明了 shell: bash" % _J if not _bad
        else "%s 这些步骤用了 pipefail 却没声明 shell: bash: %s" % (_J, _bad))
    # ③ 快照根只能有一个定义处, 且执行与清理都引用它
    _m2 = re.search(r"^    env:\n(?:      [A-Za-z0-9_]+:.*\n)*?      PDG_DOTE2E_SNAP:\s*(\S+)\s*$",
                    _job, re.M)
    if not _m2:
        bad("%s 没有在 job 级定义 PDG_DOTE2E_SNAP —— 快照路径就没有唯一来源" % _J)
    else:
        _p2 = _m2.group(1)
        _dup2 = [ln for ln in _job.splitlines()
                 if _p2 in ln and not re.match(r"^      PDG_DOTE2E_SNAP:", ln)]
        (ok if not _dup2 else bad)(
            "%s 路径闭包成立: %s 只在定义处出现一次" % (_J, _p2) if not _dup2
            else "%s 路径闭包破了: %s 在定义处之外还出现 %d 次(%s)"
                 % (_J, _p2, len(_dup2), _dup2[0].strip()[:60]))
        _ref = [_n for _s, _n in _steps(_job) if "$PDG_DOTE2E_SNAP" in _run_body(_s)]
        (ok if len(_ref) >= 3 else bad)(
            "%s 快照准备/夹具/测试都引用 $PDG_DOTE2E_SNAP(%d 步)" % (_J, len(_ref)) if len(_ref) >= 3
            else "%s 只有 %d 步引用 $PDG_DOTE2E_SNAP —— 有人写了字面量" % (_J, len(_ref)))
    # ④ 汇总门必须同时卡住"通过>0 / 失败 0 / 跳过 0"与"内部 [SKIP] 0"。
    #    只看退出码会被"零断言也退 0"骗过去; 少卡跳过会让 SKIP 冒充通过。
    _sum = [_s for _s, _n in _steps(_job) if "失败 " in _run_body(_s) and "test " in _run_body(_s)]
    if not _sum:
        bad("%s 没有解析汇总数字的步骤 —— 只靠退出码判绿" % _J)
    else:
        _b = _run_body(_sum[0])
        _need = [('test "$np" -gt 0', "通过数非零"),
                 ('test "$nf" -eq 0', "失败为 0"),
                 ('test "$ns" -eq 0', "跳过为 0"),
                 ("[SKIP", "脚本内部 [SKIP] 为 0")]
        _miss = [d for t, d in _need if t not in _b]
        (ok if not _miss else bad)(
            "%s 汇总门四条齐全(通过>0 / 失败 0 / 跳过 0 / 内部 SKIP 0)" % _J if not _miss
            else "%s 汇总门缺: %s —— 少一条就能假绿" % (_J, "、".join(_miss)))
    # ⑤ 污染检查必须挂 if: always()
    _cl = [_s for _s, _n in _steps(_job) if "残留" in _s or "污染" in _s]
    (ok if _cl and any(re.search(r"^        if:\s*always\(\)", _s, re.M) for _s in _cl) else bad)(
        "%s 的污染检查挂了 if: always()" % _J if _cl and any(
            re.search(r"^        if:\s*always\(\)", _s, re.M) for _s in _cl)
        else "%s 的污染检查没挂 if: always() —— 测试红了就不清场" % _J)


total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

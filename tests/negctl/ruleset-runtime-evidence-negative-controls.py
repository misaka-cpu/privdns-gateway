#!/usr/bin/env python3
"""负控: **check_rulesets 的运行期证据**这条判据有没有牙。

正控在 tests/test-ruleset-runtime-evidence.py。

这一类退化最难看出来: 退化之后 doctor 仍然"有输出、看着正常" —— 要么把"读不到"说成绿,
要么把"声明了没加载 / 解析出 0 条"放过去。机器上规则是死的, 报告却是绿的。

五格 + 反向对照:

  ① 读不到管理面时退回 ok        —— 把"无结论"冒充成"已验证";
  ② 不查"声明了却没同名 provider" —— 规则被静默丢弃却报绿;
  ③ ruleCount==0 放过            —— "有 provider"被当成"有规则";
  ④ 去掉回环限制                 —— 判据会去连非回环的控制面(能改配置、切出站的那个口);
  ⑤ 缺 ruleCount 当成通过        —— 字段缺失被当成证据齐全;
  ⑥ 只加无关注释(反向对照)       —— 不该产生任何新失败。

④ 的判据落在**理由文案**上而不是 level: 去掉限制之后连非回环也只是连不上, level 照样是
warn —— 只有理由从「不在回环」变成「读不到管理面」才暴露它真的去连了。
"""
import hashlib, os, re, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TGT = "deploy/bot/checks.py"
TOUCHED = [ROOT / TGT]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=1200)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("✗")}

T = ["python3", "tests/test-ruleset-runtime-evidence.py"]

SRC = (ROOT / TGT).read_text(encoding="utf-8")
def lift(pattern, max_lines=20, flags=re.M | re.S):
    """从产品源码原样取锚点。

    除了"整段唯一", 还要卡**跨度上限**: `.*?` 若从一个更早的同名起始行开始匹配, 整段照样
    唯一, 却会把中间几百行一起换掉 —— 那是改坏了别的判据, 不是本格要测的东西。本轮就踩过
    一次: `if missing:` 在 LAN 面板判据里也有一处, 非贪婪匹配从那儿起跳, 一口气吞掉 821 行。"""
    m = re.search(pattern, SRC, flags)
    assert m, pattern
    g = m.group(0)
    assert SRC.count(g) == 1, pattern
    n = g.count("\n") + 1
    assert n <= max_lines, "锚点跨度 %d 行, 超过上限 %d —— 八成从更早的同名行起跳了: %s" % (n, max_lines, pattern)
    return g

UNAVAIL   = lift(r'^    provs, why = _clash_rule_providers\(\)\n    if provs is None:\n.*?^                              % \(len\(meta\), why\)\)$')
MISSING   = lift(r'^    if missing:\n        return \("fail", name, "这些规则集在配置里声明了.*?可达。" \+ note\)$')
EMPTY     = lift(r'^    if empty:\n        return \("fail", name, "这些规则集在运行期.*?重建。" \+ note\)$')
# v1.11.13+ 的地址门改成了"严格解析数字 IP 再看 is_loopback"(不再有 is_loop 变量),
# 锚点跟着挪到 `if not ip.is_loopback:` 这两行。
LOOPBACK  = lift(r'^    if not ip\.is_loopback:\n        return None, "external-controller 不在回环 —— 本项不主动连非回环管理端口"$')
INCOMPL   = lift(r'^    if incomplete:\n        # 没有确定性失败.*?incomplete\[:6\]\)\)\)$')

MUT = [
    ("① 读不到管理面时退回 ok",
     [(UNAVAIL, '    provs, why = _clash_rule_providers()\n'
                '    if provs is None:\n'
                '        return ("ok", name, "%d 个: 形态没问题" % len(meta))', 1)]),
    ("② 不查「声明了却没同名 provider」",
     [(MISSING, '    if False:  # 变异: 不再报缺失的 provider\n        pass', 1)]),
    ("③ ruleCount==0 放过",
     [(EMPTY, '    if False:  # 变异: 0 条也放过\n        pass', 1)]),
    ("④ 去掉回环限制(会去连非回环控制面)",
     [(LOOPBACK, '    if False:  # 变异: 不再限制回环\n        return None, "x"', 1)]),
    ("⑤ 缺 ruleCount 当成通过",
     [(INCOMPL, '    if False:  # 变异: 字段缺失也当证据齐全\n        pass', 1)]),
    ("⑥ 只加无关注释(反向对照)",
     [(LOOPBACK, "    # 变异: 一条无关注释\n" + LOOPBACK, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-rsrt-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / TGT
    pristine = target.read_text(encoding="utf-8")

    def suite():
        """返回 (具名失败集合, 是否整支塌掉)。

        改坏之后正控**根本没跑起来**(import 期就 NameError/SyntaxError)时, 它一条 ✗ 也不会
        打印 —— 那与"判据没牙"长得一模一样。必须分开: 塌掉是夹具/改坏器的问题, 不能记成
        这一格有牙, 也不能记成无效。"""
        r = run(T, cwd=wd)
        out = r.stdout + r.stderr
        crashed = ("Traceback (most recent call last)" in out) or ("通过 " not in out)
        return failures(out), crashed

    base, base_crash = suite()
    if base_crash:
        bad("基线就跑不起来(正控在未改坏的副本上崩了)"); raise SystemExit(1)
    if base:
        bad("基线就不绿(%d 条):" % len(base))
        for f in sorted(base)[:4]: print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 正控在未改坏的副本上 0 条具名失败")

    for label, edits in MUT:
        mutated, aborted = pristine, False
        for old, new, want in edits:
            hits = mutated.count(old)
            if hits != want:
                bad("%s → 锚点命中 %d 次, 预期 %d" % (label, hits, want)); aborted = True; break
            if new == old:
                bad("%s → 改坏器空转: 替换文本与原文一字不差" % label); aborted = True; break
            mutated = mutated.replace(old, new, 1)
        if aborted: continue
        target.write_text(mutated, encoding="utf-8")
        if run(["python3", "-m", "py_compile", str(target)], cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法" % label); target.write_text(pristine, encoding="utf-8"); continue
        got, crashed = suite()
        added = got - base
        target.write_text(pristine, encoding="utf-8")
        if crashed:
            bad("%s → 改坏后正控整支塌掉(import/语法期就崩), 这一格没测到判据, "
                "多半是锚点吞掉了别处代码" % label)
            continue
        if label.startswith("⑥"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        if added:
            ok("%s → 新增具名失败 %d 条" % (label, len(added)))
            print("       " + sorted(added)[0][:130])
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: checks.py sha256 与 mode 均一致" if clean else "正式树被改动了!")
print("-" * 62)
print("ruleset-runtime-evidence-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

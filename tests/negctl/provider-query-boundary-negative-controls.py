#!/usr/bin/env python3
"""负控: **管理面查询的接收端边界 + 多故障判定优先级** 这几条判据有没有牙。

正控在 tests/test-provider-query-boundary.py。

这几处退化都不会让 doctor 看起来异常 —— 该绿的照样绿。露馅的地方在别处: 凭据被送到另一个
接收端、请求打到另一个监听实例、或者一个已经证实是死规则的 provider 被"无结论"盖掉。

四格 + 反向对照, 逐条撤销本轮的修复:

  ① 撤销"禁止重定向"     —— 302 之后会去请求 Location, 并把 Authorization 一起带过去;
  ② 撤销"禁用环境代理"   —— 环境里有代理时整个请求(连同凭据)交给代理;
  ③ 撤销"IPv6 地址保留" —— [::1] 又被改写成 127.0.0.1, 可能是另一个监听实例;
  ④ 撤销"FAIL 优先级"   —— 确定性失败重新被 WARN 遮住;
  ⑤ 只加无关注释(反向对照) —— 不该产生任何新失败。

①② 的判据落在正控记录的**真实接收次数**上, 不是源码形状。
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
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=1800)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("✗")}

T = ["python3", "tests/test-provider-query-boundary.py"]
SRC = (ROOT / TGT).read_text(encoding="utf-8")


def lift(pattern, max_lines=20, flags=re.M | re.S):
    """锚点从产品源码原样取出, 并卡**跨度上限** —— `.*?` 从更早的同名行起跳时整段照样唯一,
    却会把中间几百行一起换掉(本仓库踩过一次, 见 ruleset-runtime-evidence 负控的注释)。"""
    m = re.search(pattern, SRC, flags)
    assert m, pattern
    g = m.group(0)
    assert SRC.count(g) == 1, pattern
    n = g.count("\n") + 1
    assert n <= max_lines, "锚点跨度 %d 行, 超上限 %d: %s" % (n, max_lines, pattern)
    return g


OPENER  = lift(r'^    return urllib\.request\.build_opener\(urllib\.request\.ProxyHandler\(\{\}\), _NoRedirect\(\)\)$')
V6KEEP  = lift(r'^    if raw\.startswith\("\["\):\n.*?^        literal = host$')
PRIO    = lift(r'^    note = \(.*?\n    if missing:$')

MUT = [
    ("① 撤销「禁止重定向」",
     [(OPENER, "    return urllib.request.build_opener(urllib.request.ProxyHandler({}))", 1)]),
    ("② 撤销「禁用环境代理」",
     [(OPENER, "    return urllib.request.build_opener(_NoRedirect())", 1)]),
    ("③ 撤销「IPv6 地址保留」(改回硬编码 127.0.0.1)",
     [(V6KEEP, '    if raw.startswith("["):\n'
               '        host = raw[1:raw.find("]")]\n'
               '        port = raw[raw.find("]") + 2:]\n'
               '        literal = "127.0.0.1"   # 变异: 又改写成 IPv4\n'
               '    else:\n'
               '        host, _, port = raw.rpartition(":")\n'
               '        literal = "127.0.0.1"   # 变异: 同上', 1)]),
    ("④ 撤销「FAIL 优先级」(incomplete 重新排到前面)",
     [(PRIO, '    note = ""\n'
             '    if incomplete:\n'
             '        return ("warn", name, "%d 个: 变异 —— 无结论重新盖住确定性失败: %s"\n'
             '                              % (len(meta), "、".join(incomplete[:6])))\n'
             '    if missing:', 1)]),
    ("⑤ 只加无关注释(反向对照)",
     [(OPENER, "    # 变异: 一条无关注释\n" + OPENER, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-pqb-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / TGT
    pristine = target.read_text(encoding="utf-8")

    def suite():
        """(具名失败集合, 是否整支塌掉)。改坏后正控若在 import/语法期就崩, 一条 ✗ 也不会打印,
        与"判据没牙"长得一样 —— 必须分开。"""
        r = run(T, cwd=wd)
        out = r.stdout + r.stderr
        crashed = ("Traceback (most recent call last)" in out) or ("通过 " not in out)
        return failures(out), crashed

    base, base_crash = suite()
    if base_crash:
        bad("基线就跑不起来"); raise SystemExit(1)
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
            bad("%s → 改坏后正控整支塌掉, 这一格没测到判据" % label); continue
        if label.startswith("⑤"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        if added:
            ok("%s → 新增具名失败 %d 条" % (label, len(added)))
            print("       " + sorted(added)[0][:135])
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: checks.py sha256 与 mode 均一致" if clean else "正式树被改动了!")
print("-" * 62)
print("provider-query-boundary-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

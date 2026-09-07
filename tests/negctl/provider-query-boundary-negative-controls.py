#!/usr/bin/env python3
"""负控: **管理面查询的接收端边界 / 地址门 / 多故障判定优先级** 这几条判据有没有牙。

正控在 tests/test-provider-query-boundary.py。

这几处退化都不会让 doctor 看起来异常 —— 该绿的照样绿。露馅的地方在别处: 凭据被送到另一个
接收端、请求打到另一个监听实例、连到哪里由系统解析器说了算, 或者一个已经证实是死规则的
provider 被"无结论"盖掉。

七格 + 反向对照, 逐条撤销本轮与上一轮的修复:

  ① 撤销「禁止重定向」   —— 302 之后会去请求 Location, 并把 Authorization 一起带过去;
  ② 撤销「禁用环境代理」 —— 环境里有代理时整个请求(连同凭据)交给代理;
  ③ 撤销「地址族保留」   —— [::1] 又被改写成 127.0.0.1, 可能是另一个监听实例;
  ④ 撤销「FAIL 优先级」  —— 确定性失败重新被 WARN 遮住;
  ⑤ 撤销「名字不放行」   —— localhost 直接放行, 检查对象与实际连接对象脱节;
  ⑥ 撤销「严格解析地址」 —— 换回 `^127\\.\\d+\\.\\d+\\.\\d+$` 只比形状, 放行 127.999.1.1;
  ⑦ **改坏测试自己**     —— 地址门那一格误走完整网络查询, 于是去碰不属于本轮的端口;
  ⑧ 只加无关注释(反向对照) —— 不该产生任何新失败。

①② 的判据落在正控记录的**真实接收次数**上, 不是源码形状。⑦ 改的是测试而不是产品, 命中的是
正控的收尾格(越界连接记账): 那些连接**全部由测试自带的拦截器在 connect 发包前拒掉**, 一个
包也不会打到宿主上的任何服务。
"""
import hashlib, os, re, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CHECKS = "deploy/bot/checks.py"
PQB = "tests/test-provider-query-boundary.py"
TOUCHED = [ROOT / CHECKS, ROOT / PQB]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=1800)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("✗")}

T = ["python3", PQB]
SRC = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (CHECKS, PQB)}


def lift(rel, pattern, max_lines=20, flags=re.M | re.S):
    """锚点从源码原样取出, 并卡**跨度上限** —— `.*?` 从更早的同名行起跳时整段照样唯一,
    却会把中间几百行一起换掉(本仓库踩过一次: 一个 `if missing:` 吞了 821 行)。"""
    src = SRC[rel]
    m = re.search(pattern, src, flags)
    assert m, "%s: %s" % (rel, pattern)
    g = m.group(0)
    assert src.count(g) == 1, "%s: %s" % (rel, pattern)
    n = g.count("\n") + 1
    assert n <= max_lines, "锚点跨度 %d 行, 超上限 %d: %s" % (n, max_lines, pattern)
    return g


OPENER = lift(CHECKS, r'^    return urllib\.request\.build_opener\(urllib\.request\.ProxyHandler\(\{\}\), _NoRedirect\(\)\)$')
# 地址族的保留点在**返回那一行**(v1.11.13+ 改成 ipaddress 严格解析后再拼回去)。
V6KEEP = lift(CHECKS, r'^    return "http://%s:%s" % \(\(\("\[%s\]" % host\) if ip\.version == 6 else host\), port\), ""$')
VALERR = lift(CHECKS, r'^    try:\n        ip = ipaddress\.ip_address\(host\)\n    except ValueError:\n.*?不对名字做解析"\)$')
STRICT = lift(CHECKS, r'^    try:\n        ip = ipaddress\.ip_address\(host\)\n.*?^        return None, "external-controller 不在回环 —— 本项不主动连非回环管理端口"$')
PRIO   = lift(CHECKS, r'^    note = \(.*?\n    if missing:$')
GATEQ  = lift(PQB, r'^    p = subprocess\.run\(\[sys\.executable, "-c", CTRL,.*?驱动异常:" \+ \(p\.stdout \+ p\.stderr\)\[:120\]\]$')

MUT = [
    ("① 撤销「禁止重定向」", CHECKS,
     [(OPENER, "    return urllib.request.build_opener(urllib.request.ProxyHandler({}))", 1)]),
    ("② 撤销「禁用环境代理」", CHECKS,
     [(OPENER, "    return urllib.request.build_opener(_NoRedirect())", 1)]),
    ("③ 撤销「地址族保留」(又硬编码回 127.0.0.1)", CHECKS,
     [(V6KEEP, '    return "http://127.0.0.1:%s" % port, ""   # 变异: 地址族被静默改写', 1)]),
    ("④ 撤销「FAIL 优先级」(incomplete 重新排到前面)", CHECKS,
     [(PRIO, '    note = ""\n'
             '    if incomplete:\n'
             '        return ("warn", name, "%d 个: 变异 —— 无结论重新盖住确定性失败: %s"\n'
             '                              % (len(meta), "、".join(incomplete[:6])))\n'
             '    if missing:', 1)]),
    ("⑤ 撤销「名字不放行」(localhost 直接放行)", CHECKS,
     [(VALERR, '    try:\n'
               '        ip = ipaddress.ip_address(host)\n'
               '    except ValueError:\n'
               '        if host == "localhost":\n'
               '            # 变异: 只把名字放行, 真正连到哪里交给系统解析器决定\n'
               '            return "http://%s:%s" % (host, port), ""\n'
               '        return None, "external-controller 是主机名或非法数字地址"', 1)]),
    ("⑥ 撤销「严格解析地址」(换回只比形状的 127.* 正则)", CHECKS,
     [(STRICT, '    # 变异: 只比形状, 不做地址解析 —— 127.999.1.1 这类非法地址会被放行\n'
               '    if not re.match(r"^127\\.\\d+\\.\\d+\\.\\d+$", host) and host != "::1":\n'
               '        return None, "external-controller 不在回环(变异: 只比形状)"\n'
               '    ip = ipaddress.ip_address("::1" if host == "::1" else "127.0.0.1")', 1)]),
    ("⑦ 改坏测试自己: 地址门那一格误走完整网络查询", PQB,
     [(GATEQ, '    # 变异: 本该只调地址解析函数, 却发起完整查询 —— 目标是不属于本轮的端口\n'
              '    r = query(controller, secret="")\n'
              '    return [r["base"], r["why"]]', 1)]),
    ("⑧ 只加无关注释(反向对照)", CHECKS,
     [(OPENER, "    # 变异: 一条无关注释\n" + OPENER, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-pqb-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (CHECKS, PQB)}

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

    for label, rel, edits in MUT:
        target = Path(wd) / rel
        mutated, aborted = pristine[rel], False
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
            bad("%s → 改坏后语法不合法" % label); target.write_text(pristine[rel], encoding="utf-8"); continue
        got, crashed = suite()
        added = got - base
        target.write_text(pristine[rel], encoding="utf-8")
        if crashed:
            bad("%s → 改坏后正控整支塌掉, 这一格没测到判据" % label); continue
        if label.startswith("⑧"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        if added:
            ok("%s → 新增具名失败 %d 条" % (label, len(added)))
            for f in sorted(added)[:2]:
                print("       " + f[:135])
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: checks.py 与正控 py 的 sha256/mode 均一致"
                       if clean else "正式树被改动了!")
print("-" * 62)
print("provider-query-boundary-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

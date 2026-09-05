#!/usr/bin/env python3
"""负控: **本轮收尾停住自己的生成者** 这条判据有没有牙。

正控在 tests/test-ios-offer-abortgen.py。

这处退化最难看出来: 退出码始终是对的(129/130/143), 通道也确实不再服务 —— 只有等生成器
自己落笔, 盘上才会多出一个没有 sentinel 的壳, 而那时早已没人在看。

一格 + 反向对照。为什么只有一格, 三条实测理由写在下面:

  ① teardown 完全不管生成器  —— 缺陷本体, 八格正控同时转红;
  ② 反向对照                —— 不该产生任何新失败。

**「gen_run 不把 pid 交给收尾」咬不动**: 收尾会退回目录凭据那条路, 照样认出并停住它。那是
设计上的第二道保险, 不是判据失灵。为了让格子好看去把第二道保险拆掉, 是本末倒置。

**「停不掉 / 认不出时保留目录与记录」不单列一格**: 那条分支没有独立的判据保护它 —— 它就是
①(以及孤儿回收那一侧的 unknown 分支)变红时观测到的东西。再拿一个变异去打同一条分支,
只是把同一件事重复一遍。

**「僵尸感知退化成 kill -0」实测也咬不动, 而这一条值得记**: 退化之后
`_ios_offer_stop_child` 仍会在 `wait` 收尸**之后**做最后一次判定, 那时 pid 已经不在,
于是照样返回成功 —— 只是白白走完 TERM/KILL 的全部升级、多花约 5 秒。也就是说僵尸感知
是**延迟与推理正确性**上的改进, 不是正确性闸门。要让它可观测就得断言收尾时长, 而那是一条
时序敏感的判据, 在负控连跑多套件时会漂(本项目刚为这种漂修过一轮)。所以如实撤掉这一格,
而不是引入一条会自己响的断言。
"""
import hashlib, os, re, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
TOUCHED = [ROOT / PDG]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=3000)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("[FAIL]")}

T_AG = ["python3", "tests/test-ios-offer-abortgen.py"]

PDG_TEXT = (ROOT / PDG).read_text(encoding="utf-8")
def lift(pattern, flags=re.M | re.S):
    """锚点从产品源码原样取出, 不手写转义。"""
    m = re.search(pattern, PDG_TEXT, flags)
    assert m, pattern
    assert PDG_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

TD_GEN = lift(r'^  if \[\[ -n "\$\{_IOS_OFFER_GEN:-\}" \]\]; then\n.*?^  fi\n  # 顺序要紧')
PROC_DEAD = lift(r"^_ios_offer_proc_dead\(\)\{\n.*?^\}$")

MUT = [
    ("① teardown 完全不管生成器",
     [(TD_GEN, "  :  # 变异: 收尾不管生成器\n  # 顺序要紧", 1)], [T_AG]),
    ("② 只加无关注释(反向对照)",
     [(PROC_DEAD, "# 变异: 一条无关注释\n" + PROC_DEAD, 1)], [T_AG]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iosag-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / PDG
    pristine = target.read_text(encoding="utf-8")

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd); out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_AG])
    if base:
        bad("基线就不绿(%d 条):" % len(base))
        for f in sorted(base)[:4]: print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 正控在未改坏的副本上 0 条具名失败")

    for label, edits, targets in MUT:
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
        if run(["bash", "-n", str(target)], cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法" % label); target.write_text(pristine, encoding="utf-8"); continue
        added = suite(targets) - base
        target.write_text(pristine, encoding="utf-8")
        if label.startswith("②"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "EXTRACT-MISSING" not in a and "屏障没到达" not in a]
        if real:
            ok("%s → 新增具名失败 %d 条(其中直指目标 %d 条)" % (label, len(added), len(real)))
            print("       " + sorted(real)[0][:130])
        elif added:
            bad("%s → 只让夹具塌了(%d 条), 没有直指目标行为的具名失败" % (label, len(added)))
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: pdg.sh sha256 与 mode 均一致" if clean else "正式树被改动了!")
print("-" * 62)
print("ios-offer-abortgen-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

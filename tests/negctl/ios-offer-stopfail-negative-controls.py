#!/usr/bin/env python3
"""负控: **停不掉要有界返回、状态读不到不算已退出** 这两条判据有没有牙。

正控在 tests/test-ios-offer-stopfail.py。

这两处退化都不改退出码, 也不改正常路径的任何观测: 生成器能停住时一切照旧, 只有在
"停不住"或"读不到状态"这两条罕见分支上才会分道扬镳 —— 一边是有界地把失败报出来并
保留现场, 一边是无声地卡死或把还在写盘的进程当成已经走了。

四格 + 反向对照, 每一格各自守一件事:

  ① 恢复"无条件 wait"                    —— 停不住时卡死, 失败送不出去;
  ② 读失败重新判成"已退出"                —— 未知冒充确定;
  ③ 停不住时照样删会话目录                —— 删掉的是线索, 写入者随后会把目录重建成空壳;
  ④ 停不住时照样删运行期所有权记录        —— 下一次会话会拿着本该消失的记录做身份核对;
  ⑤ 反向对照                             —— 不该产生任何新失败。

**不用「收尾完全不管生成器」当替身。** 那个变异确实会让一大片格子转红, 但它红的是
"有没有处理生成器", 不是"处理不成功时怎么办" —— 拿它冒充 ①③④ 会把三条各自独立的
分支糊成一条, 而真正退化时(处理了、但把失败吞了)它一格也不会响。上一轮的
ios-offer-abortgen 负控守的才是那件事, 两边不重复。
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

T_SF = ["python3", "tests/test-ios-offer-stopfail.py"]

PDG_TEXT = (ROOT / PDG).read_text(encoding="utf-8")
def lift(pattern, flags=re.M | re.S):
    """锚点从产品源码原样取出, 不手写转义。"""
    m = re.search(pattern, PDG_TEXT, flags)
    assert m, pattern
    assert PDG_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

# stop_child 尾部的三态裁决 —— 只有确证退出才 wait
STOP_TAIL   = lift(r'^  _ios_offer_proc_dead "\$pid"\n  case "\$\?" in\n.*?^  esac$')
# proc_dead 里"读失败 ≠ 已退出"的那道门
READ_GUARD  = lift(r'^  if ! st="\$\(cat "/proc/\$1/stat" 2>/dev/null\)"; then\n.*?^  fi$')
# 收尾里"停不住就不删"的两道门。开关后来从 gen_unsafe 换成了 keep_scene(生成者与 HTTP
# 任一未确认安全结束都保留), 锚点随之更新 —— 这两格守的仍是生成者那一侧的分支。
DIR_GUARD   = lift(r'^    if \[\[ -n "\$keep_scene" \]\]; then$')
STATE_GUARD = lift(r'^  if \[\[ -z "\$keep_scene" && -n "\$\{_IOS_OFFER_STATE_OWNED:-\}" \]\]; then$')

MUT = [
    ("① 恢复无条件 wait(停不住时卡死, 失败送不出去)",
     [(STOP_TAIL, '  wait "$pid" 2>/dev/null\n  _ios_offer_proc_dead "$pid"', 1)]),
    ("② 读 /proc/<pid>/stat 失败重新判成已退出",
     [(READ_GUARD, '  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0', 1)]),
    ("③ 停不住/认不出时照样删会话目录",
     [(DIR_GUARD, '    if [[ -n "" ]]; then  # 变异: 保留现场那条路走不到了', 1)]),
    ("④ 停不住/认不出时照样删运行期所有权记录",
     [(STATE_GUARD, '  if [[ -n "${_IOS_OFFER_STATE_OWNED:-}" ]]; then  # 变异: 不再看保留开关', 1)]),
    ("⑤ 只加无关注释(反向对照)",
     [(READ_GUARD, "  # 变异: 一条无关注释\n" + READ_GUARD, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iossf-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / PDG
    pristine = target.read_text(encoding="utf-8")

    def suite():
        r = run(T_SF, cwd=wd)
        return failures(r.stdout + r.stderr)

    base = suite()
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
        if run(["bash", "-n", str(target)], cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法" % label); target.write_text(pristine, encoding="utf-8"); continue
        added = suite() - base
        target.write_text(pristine, encoding="utf-8")
        if label.startswith("⑤"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "夹具没保持住" not in a and "EXTRACT-MISSING" not in a]
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
print("ios-offer-stopfail-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

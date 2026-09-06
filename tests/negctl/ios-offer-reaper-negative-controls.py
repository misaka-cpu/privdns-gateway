#!/usr/bin/env python3
"""负控: **存活生成者 / 身份判定 / 枚举完整性** 三组判据有没有牙。

正控在 tests/test-ios-offer-reaper.py, 并连带 tests/test-ios-offer-prestate.py。

这三类退化的共同点仍是"看起来更成功": 不查生成者凭据, 平时一个字都不会变, 只有强杀正好
落在生成中才露馅; 把身份未知当成已退出, 绝大多数时候删的确实是自己的目录; 吞掉 find 的
退出码, 只有枚举真的失败那一次才出事 —— 而那一次它会凭"不曾看到"删东西。

七格 + 反向对照:
  ① 生成器不登记身份            —— 后继认不出还在写的人;
  ② 回收不查生成者凭据          —— 删完目录被它重建成没有 sentinel 的壳;
  ③ starttime 不符判成 gone     —— 把"分不清"当成"已经退出";
  ④ 凭据损坏判成 gone           —— 同上, 更直接;
  ⑤ 回收把 unknown 当安全       —— 身份不明照删;
  ⑥ 枚举吞掉 find 的退出码      —— "不曾看到"等同"不存在";
  ⑦ 目录内容枚举失败退化成"不是我们的" —— 把"没看全"报成"归属不符", 掩盖真正的原因;
     这一格只让**诊断**退化: 结果仍然 fail-closed, 目录不会被删。保留它而不是撤掉, 是因为
     在真机上这两句话把人引向完全不同的排查方向 —— 一个去查权限与文件系统, 一个去查这个
     目录到底是谁建的。判据的价值不只在"拦没拦住", 也在"说没说清楚是哪一种失败"。
  ⑧ 只加无关注释(反向对照)     —— 不该产生任何新失败。
"""
import hashlib, os, re, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
TOUCHED = [ROOT / PDG, ROOT / "tests/test-ios-offer-reaper.py"]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=3000)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("[FAIL]")}

T_REAP = ["python3", "tests/test-ios-offer-reaper.py"]
T_PRE = ["python3", "tests/test-ios-offer-prestate.py"]

PDG_TEXT = (ROOT / PDG).read_text(encoding="utf-8")
def lift(pattern, flags=re.M | re.S):
    """锚点从产品源码原样取出, 不手写转义 —— 手写过一次, 结果是改坏器空转。"""
    m = re.search(pattern, PDG_TEXT, flags)
    assert m, pattern
    assert PDG_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

GEN_REG = lift(r"^  gstart=\"\$\(_ios_offer_starttime \"\$gpid\"\)\"\n.*?^  fi$")
GEN_PENDING = lift(r"^  \(umask 077 && printf 'pending\\n' > \"\$gf\"\) 2>/dev/null \|\| return 1$")
REAP_GEN = lift(r"^  st=\"\$\(_ios_offer_proc_state \"\$dir/\$IOS_OFFER_GENFILE\"\)\"\n.*?^  esac$")
ST_START = lift(r'^  \[\[ "\$now" == "\$start" \]\] \|\| \{ echo "unknown pid \$pid 的 starttime 与凭据不符"; return 0; \}$')
ST_CORRUPT = lift(r'^    echo "unknown 凭据内容损坏或尚未登记"; return 0$')
LIST_FN = lift(r'^  out="\$\(find "\$1" -mindepth 1 -maxdepth 1 -print 2>/dev/null\)"; rc=\$\?$')
DIROK_2 = lift(r'^  listing="\$\(_ios_offer_list "\$dir"\)" \|\| return 2$')
REAP_UNKNOWN = lift(r'^    \*\)\n      echo "❌ 上一轮临时下载服务的身份无法确认.*?^      return 1 ;;$')

T_REAP_FILE = "tests/test-ios-offer-reaper.py"
REAP_TEXT = (ROOT / T_REAP_FILE).read_text(encoding="utf-8")

def lift_reap(pattern, flags=re.M | re.S):
    '''同样的取法, 但锚点在**正控自己**身上 —— A 组的登记门属于夹具。'''
    m = re.search(pattern, REAP_TEXT, flags)
    assert m, pattern
    assert REAP_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

A_GATE = lift_reap(r"^    gated, why_not = wait_registered\(env, d, genpid, limit=30\)$")

MUT = [
    ("① 生成器不登记身份",
     [(GEN_REG, "  :  # 变异: 不登记生成者身份", 1)], [T_REAP]),
    ("② 回收不查生成者凭据",
     [(REAP_GEN, "  :  # 变异: 不查生成者", 1)], [T_REAP]),
    ("③ starttime 不符判成 gone",
     [(ST_START, '  [[ "$now" == "$start" ]] || { echo gone; return 0; }  # 变异', 1)], [T_REAP]),
    ("④ 凭据损坏判成 gone",
     [(ST_CORRUPT, "    echo gone; return 0  # 变异", 1)], [T_REAP]),
    ("⑤ 回收把 unknown 当安全",
     [(REAP_UNKNOWN, "    *) ;;  # 变异: 身份不明也放行", 1)], [T_REAP]),
    ("⑥ 枚举吞掉 find 的退出码",
     [(LIST_FN, '  out="$(find "$1" -mindepth 1 -maxdepth 1 -print 2>/dev/null)"; rc=0  # 变异', 1)],
     [T_REAP]),
    ("⑦ 目录内容枚举失败退化成「不是我们的」",
     [(DIROK_2, '  listing="$(_ios_offer_list "$dir")" || return 1  # 变异', 1)], [T_REAP]),
    # ⑨ 改的是**正控自己的夹具**: A 组靠登记门决定何时发 SIGKILL。退回"只等 gen-started"
    # 之后, 受控登记延迟让信号确定性地落在 pending 窗口, 后继按"身份尚不能确认"拒绝 ——
    # A 组要测的"先停住还活着的写入方再删目录"根本考不到。
    ("⑨ A 组屏障退回「只等 gen-started」",
     [(A_GATE, '    gated, why_not = (True, "")  # 变异: 不再等身份登记完成',
       1, T_REAP_FILE)], [T_REAP]),
    ("⑧ 只加无关注释(反向对照)",
     [(GEN_PENDING, "  # 变异: 一条无关注释\n" + GEN_PENDING, 1)], [T_REAP, T_PRE]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iosrp-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    targets_files = {PDG: Path(wd) / PDG, T_REAP_FILE: Path(wd) / T_REAP_FILE}
    pristine_files = {k: v.read_text(encoding="utf-8") for k, v in targets_files.items()}

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd); out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_REAP, T_PRE])
    if base:
        bad("基线就不绿(%d 条):" % len(base))
        for f in sorted(base)[:4]: print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 两支正控在未改坏的副本上 0 条具名失败")

    def restore():
        for k, v in targets_files.items():
            v.write_text(pristine_files[k], encoding="utf-8")

    for label, edits, targets in MUT:
        work = dict(pristine_files)
        aborted = False
        for e in edits:
            old, new, want = e[0], e[1], e[2]
            where = e[3] if len(e) > 3 else PDG
            hits = work[where].count(old)
            if hits != want:
                bad("%s → 锚点在 %s 命中 %d 次, 预期 %d" % (label, where, hits, want))
                aborted = True; break
            if new == old:
                bad("%s → 改坏器空转: 替换文本与原文一字不差" % label); aborted = True; break
            work[where] = work[where].replace(old, new, 1)
        if aborted: continue
        for k, v in targets_files.items():
            v.write_text(work[k], encoding="utf-8")
        if run(["bash", "-n", str(targets_files[PDG])], cwd=wd).returncode != 0:
            bad("%s → 改坏后 pdg.sh 语法不合法" % label); restore(); continue
        if run(["python3", "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())",
                str(targets_files[T_REAP_FILE])], cwd=wd).returncode != 0:
            bad("%s → 改坏后正控语法不合法" % label); restore(); continue
        added = suite(targets) - base
        restore()
        if label.startswith("⑧"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "EXTRACT-MISSING" not in a and "屏障没命中" not in a and "前提不成立" not in a]
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
(ok if clean else bad)("正式树未被污染: pdg.sh 与正控 sha256/mode 均一致" if clean else "正式树被改动了!")
print("-" * 62)
print("ios-offer-reaper-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

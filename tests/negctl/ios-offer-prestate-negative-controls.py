#!/usr/bin/env python3
"""负控: **pre-state 生命周期所有权** 与 **父目录先验后改** 的判据有没有牙。

正控在 tests/test-ios-offer-prestate.py(四个 SIGKILL 窗口 / 根目录矩阵 / 外来目录),
并连带 tests/test-ios-offer-session.py(会话凭据不一致时不删不杀)。

这一类退化照旧"看起来更成功": 回收退回"只认记录", 平时一个字都不会变, 只有强杀正好落在
那段真空里才露馅; 根目录先 chmod 后验, 正常路径也完全正常, 只有指向别处的符号链接才出事。

八格:
  ① 回收退回"仅有 state 才收"      —— 目录已建、记录尚无的残留永远没人收;
  ② 撤掉建目录时的 staging 记录     —— 所有权记录又变成"HTTP 起来才有";
  ③ 生成子进程重新继承 fd 6         —— 父 shell 死后锁被它攥着, 后继会话 BUSY;
  ④ 服务不再往目录里写 pid 凭据     —— HTTP 已起、记录未落盘那一刻收不掉;
  ⑤ 根目录恢复"先 chmod 后验"       —— 符号链接的目标先被改了权限;
  ⑥ 目录扫描放宽为只看名称之外      —— 外来目录也被卷进所有权判断;
  ⑦ 身份不明仍照收                  —— 证不明归属的目录被删掉;
  ⑧ 只加无关注释(反向对照)         —— 不该产生任何新失败。
"""
import hashlib, os, re, shutil, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
TOUCHED = [ROOT / PDG, ROOT / "tests/test-ios-offer-prestate.py"]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)
def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=2400)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("[FAIL]")}

T_PRE = ["python3", "tests/test-ios-offer-prestate.py"]
T_SESS = ["python3", "tests/test-ios-offer-session.py"]

PDG_TEXT = (ROOT / PDG).read_text(encoding="utf-8")

def lift(pattern, flags=re.M | re.S):
    """把锚点**从产品源码里原样取出**, 不手写转义 —— 手写过一次, 结果是替换文本与原文
    一字不差, 改坏器空转, 而现场长得跟"判据没牙"一模一样。"""
    m = re.search(pattern, PDG_TEXT, flags)
    assert m, pattern
    assert PDG_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

REAP_HEAD = lift(r"^_ios_offer_reap_orphan\(\)\{\n")
STAGING = lift(r"^  if ! _ios_offer_state_write staging .*?\n  fi\n")
# 两个调用方现在都经 _ios_offer_gen_run 启动生成器, `6>&-` 随之挪进了那个函数。
# 这一格问的仍是同一件事: 生成子进程会不会继承会话锁的 fd。
GEN_FD = lift(r'^  "\$@" 6>&- &$')
PIDWRITE = lift(r"^_fd = os\.open\(PIDF.*?^os\.close\(_fd\)$")
ROOTORDER = lift(r"^  if \[\[ -e \"\$IOS_OFFER_ROOT\" \|\| -L \"\$IOS_OFFER_ROOT\" \]\]; then\n.*?^  fi\n")
NAMEGUARD = lift(r'^      \[\[ "\$base" =~ \^s\\\.\[0-9a-f\]\{16\}\$ \]\] \|\| continue$')
# dir_ok 的调用点改成了先取 rc(2 = 没看全, 1 = 不是我们的), 身份判定挪进了 `dok != 0`
# 这一支。这一格问的仍是: 证不明归属时会不会照收。
IDGUARD = lift(r'^      if \[\[ "\$dok" != 0 \]\]; then\n.*?^      fi$')

ROOT_OLD = '''  mkdir -p "$IOS_OFFER_ROOT" 2>/dev/null
  chmod 0700 "$IOS_OFFER_ROOT" 2>/dev/null
  if ! _ios_offer_root_ok || [[ "$(stat -c %a "$IOS_OFFER_ROOT" 2>/dev/null)" != 700 ]]; then
    _ios_offer_abort "会话目录的父目录不可信($IOS_OFFER_ROOT) —— 未开放任何临时端口。"
    return 1
  fi
'''

T_PRE_FILE = "tests/test-ios-offer-prestate.py"
PRE_TEXT = (ROOT / T_PRE_FILE).read_text(encoding="utf-8")

def lift_pre(pattern, flags=re.M | re.S):
    '''同样的取法, 但锚点在**正控自己**身上 —— 登记门属于夹具, 退化也发生在夹具里。'''
    m = re.search(pattern, PRE_TEXT, flags)
    assert m, pattern
    assert PRE_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

GATE_CALL = lift_pre(r"^        gated, why_not = wait_registered\(env, d, genpid, limit=30\)$")
GATE_BODY = lift_pre(r"^            txt = read\(os\.path\.join\(dirs\[0\], \"\.pdg-offer-gen\"\)\)\n.*?^                return True, \"\"$")
# 产品侧: 回收面对"身份认不出"时的那条拒绝分支(pending 落在这里)
GEN_UNKNOWN = lift(r'^    \*\)\n      echo "❌ 上一轮的描述文件生成器身份无法确认.*?^      return 1 ;;$')

GATE_WEAK = (
    '            txt = read(os.path.join(dirs[0], ".pdg-offer-gen"))\n'
    '            if txt:                      # 变异: 凭据一落盘就放行, 不看完整性与一致性\n'
    '                return True, ""\n'
    '            last = "生成者凭据还没落盘"')

MUT = [
    # 这两格原本是分开的。实测单独任一个都改变不了行为: 回收现在完全由**扫会话根目录**
    # 驱动, 记录不再是恢复的必要条件 —— 加回 state 门时 staging 记录还在, 门就形同虚设;
    # 只撤 staging 时扫描照样把残留收走。所以①改打记录本身的契约(目录一落盘就得有 staging),
    # ②做成两处编辑的复合变异, 即完整回退到旧设计。为了让格子好看去弱化产品是本末倒置。
    ("① 撤掉建目录时的 staging 记录", [(STAGING, "  : # 变异: 不记 staging\n", 1)], [T_PRE]),
    ("② 完整回退旧设计(仅有 state 才收 + 不记 staging)",
     [(REAP_HEAD, REAP_HEAD + '  [[ -s "$IOS_OFFER_STATE" ]] || return 0  # 变异\n', 1),
      (STAGING, "  : # 变异: 不记 staging\n", 1)], [T_PRE]),
    ("③ 生成子进程重新继承 fd 6",
     [(GEN_FD, GEN_FD.replace(' 6>&- &', ' &'), 1)], [T_PRE]),
    ("④ 服务不再往目录里写 pid 凭据", [(PIDWRITE, "pass", 1)], [T_PRE]),
    ("⑤ 根目录恢复「先 chmod 后验」", [(ROOTORDER, ROOT_OLD, 1)], [T_PRE]),
    ("⑥ 目录扫描不再限定命名", [(NAMEGUARD, "      :  # 变异", 1)], [T_PRE]),
    ("⑦ 身份不明仍照收",
     [(IDGUARD, '      if [[ "$dok" != 0 ]]; then\n'
                '        :  # 变异: 证不明归属也照收\n      fi', 1)], [T_SESS]),
    # ⑨⑩ 改的是**正控自己的夹具**: 登记门属于测试侧, 退化也发生在测试侧。受控登记延迟
    # 让这两格确定性地转红, 不靠撞时序。
    #
    # 这两格转红时会连带报一句"生成子进程继承了会话锁 fd 6"。那是夹具的副作用, 不是
    # 产品退化: `_ios_offer_starttime` 跑在 `$( )` 里, 那个命令替换子 shell 同样持有
    # fd 6(与更早一轮 mktemp 屏障遇到的是同一件事), 而变异后我们恰好在延迟**期间**
    # 强杀父 shell, 于是锁短暂地还被它攥着。未改坏的跑法在登记门放行之后才发信号,
    # 那时延迟早已结束、子 shell 也已退出, 不会出现这一条。判据落在"后继会话跑完后
    # 旧目录仍在"与"后继会话没能开通(rc=1)"上, 那两条才是这两格要抓的东西。
    ("⑨ 屏障退回「只等 gen-started」",
     [(GATE_CALL, '        gated, why_not = (True, "")  # 变异: 不再等身份登记完成',
       1, T_PRE_FILE)], [T_PRE]),
    ("⑩ 登记门接受不完整凭据(pending / 缺 start=)",
     [(GATE_BODY, GATE_WEAK, 1, T_PRE_FILE)], [T_PRE]),
    ("⑪ pending 身份认不出时照样回收",
     [(GEN_UNKNOWN, "    *)\n      :  # 变异: 认不出也当成可回收\n      ;;", 1)], [T_PRE]),
    ("⑧ 只加无关注释(反向对照)",
     [(NAMEGUARD, "      # 变异: 一条无关注释\n" + NAMEGUARD, 1)], [T_PRE, T_SESS]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iospre-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    targets_files = {PDG: Path(wd) / PDG, T_PRE_FILE: Path(wd) / T_PRE_FILE}
    pristine_files = {k: v.read_text(encoding="utf-8") for k, v in targets_files.items()}

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd); out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_PRE, T_SESS])
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
                str(targets_files[T_PRE_FILE])], cwd=wd).returncode != 0:
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
print("ios-offer-prestate-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

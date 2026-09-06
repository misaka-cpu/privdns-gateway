#!/usr/bin/env python3
"""负控: **HTTP 停不掉时保住恢复线索** 这条判据有没有牙。

正控在 tests/test-ios-offer-srvkeep.py。

这处退化不改退出码(收尾照样返回非零)、不改正常路径的任何观测, 只在"HTTP 停不住"这条
罕见分支上把恢复线索删掉 —— 端口还开着、服务还在发同一份描述文件, 而下一次会话再也
定位不到它。只看返回码什么也发现不了。

三格 + 反向对照, 各守一件事:

  ① HTTP 失败后仍删会话目录      —— 连同 pid+starttime 凭据与 sentinel 一起没了;
  ② HTTP 失败后仍删运行期记录    —— pid/start/www 没了;
  ③ HTTP 停止失败被当成成功      —— 返回值本身就错, 保留分支根本不进。

①② 的改法是把保留开关退回成只看 `gen_unsafe`, 也就是本轮修复之前那个形状 —— 于是
**生成者那一格(⑦)仍然是绿的**, 只有 HTTP 那几格转红。这正是"不能拿生成者负控替代
HTTP 负控"的意思: 生成者一侧的保护完好, HTTP 一侧照样能悄悄把线索删掉。

**防火墙是夹具**(nft 用桩), 所以这里和正控一样, 不对真实规则撤除或公网可达性下结论。
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

T_SK = ["python3", "tests/test-ios-offer-srvkeep.py"]

PDG_TEXT = (ROOT / PDG).read_text(encoding="utf-8")
def lift(pattern, flags=re.M | re.S):
    """锚点从产品源码原样取出, 不手写转义。"""
    m = re.search(pattern, PDG_TEXT, flags)
    assert m, pattern
    assert PDG_TEXT.count(m.group(0)) == 1, pattern
    return m.group(0)

DIR_GUARD   = lift(r'^    if \[\[ -n "\$keep_scene" \]\]; then$')
STATE_GUARD = lift(r'^  if \[\[ -z "\$keep_scene" && -n "\$\{_IOS_OFFER_STATE_OWNED:-\}" \]\]; then$')
SRV_FAIL    = lift(r'^    if ! _ios_offer_stop_child "\$_IOS_OFFER_SRV"; then\n.*?^    fi$')

MUT = [
    ("① HTTP 失败后仍删会话目录(保留开关退回只看生成者)",
     [(DIR_GUARD, '    if [[ -n "$gen_unsafe" ]]; then  # 变异: HTTP 那一侧不再保留', 1)]),
    ("② HTTP 失败后仍删运行期所有权记录",
     [(STATE_GUARD,
       '  if [[ -z "$gen_unsafe" && -n "${_IOS_OFFER_STATE_OWNED:-}" ]]; then  # 变异: 同上', 1)]),
    ("③ HTTP 停止失败被当成成功",
     [(SRV_FAIL, '    _ios_offer_stop_child "$_IOS_OFFER_SRV" || true  # 变异: 吞掉停止失败', 1)]),
    ("④ 只加无关注释(反向对照)",
     [(SRV_FAIL, "    # 变异: 一条无关注释\n" + SRV_FAIL, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iossk-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / PDG
    pristine = target.read_text(encoding="utf-8")

    def suite():
        r = run(T_SK, cwd=wd)
        return failures(r.stdout + r.stderr)

    base = suite()
    if base:
        bad("基线就不绿(%d 条):" % len(base))
        for f in sorted(base)[:4]: print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 正控在未改坏的副本上 0 条具名失败")

    # 这三格必须打中的直接断言 —— 只有夹具塌了或只报"没测到东西"不算。
    WANT = ("恢复线索", "被删了", "旧服务没被停掉", "teardown 返回 0", "回收返回")

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
        if label.startswith("④"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        real = [a for a in added if "没测到东西" not in a and "夹具没" not in a
                and "EXTRACT-MISSING" not in a]
        direct = [a for a in real if any(w in a for w in WANT)]
        # ①② 把保留开关退回成只看 gen_unsafe。若生成者那一格也跟着转红, 说明这个变异
        # 打的不只是 HTTP 那条分支 —— 那就没资格说"HTTP 负控不可由生成者负控替代"。
        gen_hit = [a for a in added if "⑦ 生成者" in a]
        if direct and label[0] in "①②" and gen_hit:
            bad("%s → 生成者那一格也转红了(%d 条), 这个变异不是 HTTP 专属" % (label, len(gen_hit)))
        elif direct:
            extra = " ; 生成者一格仍绿(HTTP 专属)" if label[0] in "①②" else ""
            ok("%s → 新增具名失败 %d 条(直指线索丢失/未回收/返回值错 %d 条)%s"
               % (label, len(added), len(direct), extra))
            print("       " + sorted(direct)[0][:130])
        elif real:
            bad("%s → 有 %d 条新增, 但没有一条直指线索丢失/旧服务未回收/返回值错" % (label, len(real)))
        elif added:
            bad("%s → 只让夹具塌了(%d 条)" % (label, len(added)))
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: pdg.sh sha256 与 mode 均一致" if clean else "正式树被改动了!")
print("-" * 62)
print("ios-offer-srvkeep-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

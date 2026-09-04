#!/usr/bin/env python3
"""负控: **会话目录所有权** 的判据有没有牙。

正控在 tests/test-ios-offer-session.py(真实调用方 SIGKILL / 过期孤儿 / 凭据不符 / 进程拓扑 /
state 删除失败), 并连带 tests/test-ios-offer-hardening.py。

这一类退化仍然"看起来更成功": 记录里少记一个目录, 屏幕上一个字都不会变; 凭据不核, 大多数
时候删的也确实是自己的目录; 外层套回 timeout, 平时也跑得好好的 —— 只有被强杀那一次才露馅。

六格 + 反向对照:
  ① state 不记录目录          —— 后继会话不知道该收哪个;
  ② PID 不在时删记录、留目录   —— 线索没了, 目录永远留着;
  ③ 目录删除不核会话凭据       —— 只要形态像就删, 那是拿 rm -rf 认字符串;
  ④ state unlink 恢复 || true —— 删不掉却报成功;
  ⑤ 恢复外层 timeout          —— 记录的 PID 不是听端口那个, 收尾跨两层且留子进程;
  ⑥ 只加无关注释(反向对照)    —— 不该产生任何新失败。
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
def run(c, cwd): return subprocess.run(c, cwd=cwd, capture_output=True, text=True, timeout=2400)
def failures(out):
    return {re.sub(r"\s+", " ", l.strip())[:150] for l in out.splitlines()
            if l.strip().startswith("[FAIL]")}

T_SESS = ["python3", "tests/test-ios-offer-session.py"]
T_HARD = ["python3", "tests/test-ios-offer-hardening.py"]

# 锚点全部从产品源码原样取出。本轮服务行多收了 pid 凭据参数、state 记录多了 phase、
# 回收整段重写 —— 手写转义踩过一次, 结果是改坏器空转, 而那和"判据没牙"长得一样。
PRINTF = '  if ! printf \'phase=%s\\nsid=%s\\npid=%s\\nstart=%s\\nwww=%s\\n\' \\\n        "$phase" "$sid" "$pid" "$start" "$www" > "$tmp" 2>/dev/null; then'
PRINTF_NO_DIR = PRINTF.replace('\\nwww=%s', '').replace(' "$www"', '')
RMDIR = '  rm -rf "$dir"\n  [[ -e "$dir" ]] && { echo "❌ 删不掉上一轮的会话目录($dir)。"; return 1; }'
SENTINEL = '  [[ "$(cat "$dir/$IOS_OFFER_SENTINEL" 2>/dev/null)" == "$sid" ]] || return 1'
TD_STATE = '    if ! rm -f "$IOS_OFFER_STATE" 2>/dev/null || [[ -e "$IOS_OFFER_STATE" ]]; then\n      echo "❌ 清不掉上一轮的运行期所有权记录($IOS_OFFER_STATE) —— 下一次会话会拿它做身份核对。"\n      rc=1\n    fi'
SERVE = '  ( cd "$WWW" && exec python3 -c "$IOS_OFFER_SERVER" \\\n        "$PORT" "/$TOK.mobileconfig" "$WWW/$TOK.mobileconfig" 0.0.0.0 \\\n        "$WWW/$IOS_OFFER_PIDFILE" >/dev/null 2>&1 ) 6>&- &'
SERVE_TIMEOUT = SERVE.replace('exec python3 -c', 'exec timeout 600 python3 -c')

MUT = [
    # ① 原本打的是"state 不记录目录"。它已经打不动了, 而且是**因为修复本身**: 回收现在
    # 由扫会话根目录驱动, 记录里的 www 字段不再参与恢复 —— 去掉它不改变任何行为。记录自己
    # 的契约(目录一落盘就得有 staging 相、且不带 pid)由
    # tests/negctl/ios-offer-prestate-negative-controls.py 的 ① 盯着。
    # 与其为了让格子变红去弱化产品(比如把扫描删掉), 不如把这一格撤掉并说明。
    # 回收改成了"先证明归属 → 停数据面 → 删目录", 删除挪进了 _ios_offer_reap_dir。
    ("② PID 不在时不删目录",
     [(RMDIR, '  [[ -n "$pid" ]] && rm -rf "$dir"  # 变异', 1)], [T_SESS]),
    ("③ 目录删除不核会话凭据", [(SENTINEL, "  :  # 变异", 1)], [T_SESS]),
    ("④ state unlink 恢复 || true",
     [(TD_STATE, '    rm -f "$IOS_OFFER_STATE" 2>/dev/null || true  # 变异\n'
                 '    _IOS_OFFER_STATE_OWNED=""', 1)], [T_SESS]),
    ("⑤ 恢复外层 timeout(记录的 PID 不是听端口那个)", [(SERVE, SERVE_TIMEOUT, 1)], [T_SESS]),
    ("⑥ 只加无关注释(反向对照)",
     [(RMDIR, "  # 变异: 一条无关注释\n" + RMDIR, 1)], [T_SESS, T_HARD]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-iossess-negctl.")
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

    base = suite([T_SESS, T_HARD])
    if base:
        bad("基线就不绿(%d 条):" % len(base))
        for f in sorted(base)[:4]: print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 两支正控在未改坏的副本上 0 条具名失败")

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
        if label.startswith("⑥"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added))); continue
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "EXTRACT-MISSING" not in a and "没就绪" not in a and "前提" not in a]
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
print("ios-offer-session-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""负控: **不可枚举 / state 可信落盘 / 孤儿回收所有权 / 收尾再入** 的判据有没有牙。

正控在 tests/test-ios-offer-hardening.py(并连带 tests/test-ios-offer-lifecycle.py)。
这一支回答另一个问题: **如果这四条又退回去了, 我们会不会知道?**

这一类退化的共同点还是"看起来更成功": 换回 `-m http.server` 连一行输出都不会变;
state 写失败继续走, 屏幕上一样是二维码; 收尾期间不屏蔽信号, 大多数时候也跑得完。
所以每一格都必须直指目标行为。

七格 + 反向对照:
  ① 换回 `python3 -m http.server`   —— 根路径又能列目录, 一次性 token 形同虚设;
  ② state 写失败退回 `|| true`      —— 自愈建立在没发生的写入上;
  ③ state mode 放宽成 0644          —— pid 与本机路径对同机其它用户可读;
  ④ 先 nft 后 orphan                —— 链读不到就跳过回收, 旧 HTTP 继续占端口;
  ⑤ 目录删除移出身份校验             —— 一份能解析的 state 就能点名任意目录;
  ⑥ 收尾期间的信号从 ignore 改回默认  —— 第二个信号把收尾杀在半路;
  ⑦ 只加无关注释(反向对照)          —— 不该产生任何新失败。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
TOUCHED = [ROOT / PDG]

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=2400)


def failures(out):
    s = set()
    for l in out.splitlines():
        t = l.strip()
        if t.startswith("[FAIL]"):
            s.add(re.sub(r"\s+", " ", t)[:150])
    return s


T_HARD = ["python3", "tests/test-ios-offer-hardening.py"]
T_LIFE = ["python3", "tests/test-ios-offer-lifecycle.py"]

# 外层 `timeout 600` 已去掉(只保留服务脚本自带的 Timer), 锚点跟着走。
SERVE = '  ( cd "$WWW" && exec python3 -c "$IOS_OFFER_SERVER" \\\n        "$PORT" "/$TOK.mobileconfig" "$WWW/$TOK.mobileconfig" 0.0.0.0 \\\n        "$WWW/$IOS_OFFER_PIDFILE" >/dev/null 2>&1 ) 6>&- &'
SERVE_OLD = ('  ( cd "$WWW" && exec timeout 20 python3 -m http.server "$PORT" '
             '--bind 127.0.0.1 >/dev/null 2>&1 ) 6>&- &')
STAGING = '  if ! _ios_offer_state_write staging "$_IOS_OFFER_SID" "" "" "$dir"; then\n    rm -rf "$dir"; _IOS_OFFER_WWW=""\n    _ios_offer_abort "写不下会话所有权记录($IOS_OFFER_STATE) —— 未开放任何临时端口。"; return 1\n  fi'
STATEW = '  if ! _ios_offer_state_write serving "$_IOS_OFFER_SID" "$_IOS_OFFER_SRV" \\\n        "$(_ios_offer_starttime "$_IOS_OFFER_SRV")" "$WWW"; then\n    _ios_offer_abort "写不下运行期所有权记录($IOS_OFFER_STATE) —— 强杀之后将无法自愈, 本次不开通道。"; return 1\n  fi'
STATEW_OLD = ('  _ios_offer_state_write serving "$_IOS_OFFER_SID" "$_IOS_OFFER_SRV" '
              '"$(_ios_offer_starttime "$_IOS_OFFER_SRV")" "$WWW" || true  # 变异')
CHMOD = '  chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }'
ORDER = '''  local reap_rc=0 sweep_rc=0
  _ios_offer_reap_orphan || reap_rc=1
  _ios_offer_nft_close   || sweep_rc=1'''
ORDER_OLD = '''  local reap_rc=0 sweep_rc=0
  _ios_offer_nft_close   || sweep_rc=1
  [[ "$sweep_rc" -ne 0 ]] && { _ios_offer_abort "变异: 清理失败直接停"; return 1; }
  _ios_offer_reap_orphan || reap_rc=1'''
TRAPIGN = '  trap "" HUP INT TERM'

MUT = [
    ("① 换回 python3 -m http.server(根路径又能列目录)", [(SERVE, SERVE_OLD, 1)], [T_HARD]),
    # 现在有**两次** state 写入: 建目录时的 staging 与 HTTP 起来后的 serving。只改后者的话,
    # 前者仍然 fail-closed, 会话在更早的地方就停了 —— 变异被自己的加固掩盖。要复原
    # "best-effort 写记录"这个缺陷, 两处都得退回去。
    ("② 两次 state 写入都退回 || true",
     [(STAGING, '  _ios_offer_state_write staging "$_IOS_OFFER_SID" "" "" "$dir" || true  # 变异', 1),
      (STATEW, STATEW_OLD, 1)], [T_HARD]),
    ("③ state mode 放宽成 0644", [(CHMOD, CHMOD.replace("0600", "0644"), 1)], [T_HARD]),
    ("④ 先 nft 后 orphan(链读不到就跳过回收)", [(ORDER, ORDER_OLD, 1)], [T_HARD]),
    # ⑤ 原本打的是"目录删除移出身份校验"。那条代码路径已经不存在了: 归属现在由
    # _ios_offer_dir_ok 在**任何删除之前**证明(安全父目录/非符号链接/属主/0700/会话凭据/
    # 允许内容集合), 而 tests/negctl/ios-offer-session-negative-controls.py 的 ③ 打的正是
    # 那处校验。在这里再复制一份不会多证明任何东西, 所以撤掉而不是硬凑一个锚点。
    ("⑥ 收尾期间的信号改回默认处置", [(TRAPIGN, '  trap - HUP INT TERM  # 变异', 1)], [T_HARD]),
    ("⑦ 只加无关注释(反向对照)", [(TRAPIGN, "  # 变异: 一条无关注释\n" + TRAPIGN, 1)], [T_HARD, T_LIFE]),
]

def _sweep_leftover_servers():
    """按**确切 PID** 收掉变异体留下的临时服务, 并等 8443 释放。
    改坏之后的产品可能起一个我们的收尾逻辑管不到的服务(比如 ① 恢复的 `-m http.server`
    带自己的 timeout), 它会一直占着端口, 把后面每一格的基线都带红。
    绝不用宽模式 `pkill -f`(HANDOFF §9.13: 它会咬到发起命令的 shell 自己)。"""
    import signal as _sig, socket as _sock, time as _t
    needle = "-m http" + ".server 8443"
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cl = open("/proc/%s/cmdline" % d, "rb").read().replace(b"\0", b" ").decode("utf8", "replace")
        except OSError:
            continue
        if needle in cl and str(os.getpid()) != d:
            try:
                os.kill(int(d), _sig.SIGKILL)
            except OSError:
                pass
    end = _t.time() + 10
    while _t.time() < end:
        s_ = _sock.socket()
        try:
            s_.connect(("127.0.0.1", 8443)); s_.close(); _t.sleep(0.2)
        except OSError:
            s_.close(); return
    return


before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-ioshd-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / PDG
    pristine = target.read_text(encoding="utf-8")

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd)
            out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_HARD, T_LIFE])
    if base:
        bad("基线就不绿(%d 条), 后面每一格都无从判断:" % len(base))
        for f in sorted(base)[:4]:
            print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 两支正控在未改坏的副本上 0 条具名失败")

    for label, edits, targets in MUT:
        mutated, aborted = pristine, False
        for old, new, want in edits:
            hits = mutated.count(old)
            if hits != want:
                bad("%s → 锚点命中 %d 次, 预期 %d(改坏器没打在预期位置)" % (label, hits, want))
                aborted = True
                break
            if new == old:
                bad("%s → 改坏器空转: 替换文本与原文一字不差" % label)
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
        if aborted:
            continue
        target.write_text(mutated, encoding="utf-8")
        if run(["bash", "-n", str(target)], cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            target.write_text(pristine, encoding="utf-8")
            continue
        added = suite(targets) - base
        target.write_text(pristine, encoding="utf-8")
        _sweep_leftover_servers()

        if label.startswith("⑦"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added)))
            continue
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "EXTRACT-MISSING" not in a and "没就绪" not in a]
        if real:
            ok("%s → 新增具名失败 %d 条(其中直指目标 %d 条)" % (label, len(added), len(real)))
            print("       " + sorted(real)[0][:130])
        elif added:
            bad("%s → 只让夹具塌了(%d 条), 没有直指目标行为的具名失败" % (label, len(added)))
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = True
for p in TOUCHED:
    if sha(p) != before[p]:
        bad("正式树被改动了! %s" % p.name); clean = False
    if os.stat(p).st_mode != modes[p]:
        bad("正式树权限位变了! %s" % p.name); clean = False
if clean:
    ok("正式树未被污染: pdg.sh sha256 与 mode 均一致")

print("-" * 62)
print("ios-offer-hardening-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

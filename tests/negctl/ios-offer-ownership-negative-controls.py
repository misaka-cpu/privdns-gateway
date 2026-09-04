#!/usr/bin/env python3
"""负控: 临时下载通道的 **fail-closed 与会话所有权** 有没有牙。

正控在 tests/test-ios-offer-lifecycle.py(失败路径/并发/SIGKILL)与
tests/test-ios-offer-download-leak.py(四条退出路径/规则顺序/精确撤除)。
这一支回答另一个问题: **如果这些判据又退化了, 我们会不会知道?**

为什么值得单独立一支: 这一类退化**看起来全是绿的**。假成功尤其如此 ——
`nft` 读失败被 `2>/dev/null` 吞成空集合之后, 函数照样打印"已关闭临时下载服务",
退出码照样是 0, 而机器上那条放行还在。上一轮线上就是这么过去的: 唯一的症状是几周后
另一台机器 `pdg update` 每次回滚, 从那条红灯查回病因用了整整一轮。

判据是**正控里新增的具名失败**, 不是退出码(HANDOFF §9.15)。

十一格:
  ①  链读取失败重新当成空集合  —— 假成功本体;
  ②  吞掉删除失败并固定返回 0  —— 撤不掉也说撤掉了;
  ③  恢复 _nft_apply_main 整表兜底 —— 顺手冲掉救援平面和别人的运行期规则;
  ④  忽略 nft add 的返回码      —— 通道不通却打二维码;
  ⑤  删除 HTTP 就绪验证         —— "进程还没死"被当成"服务好了";
  ⑥  删除会话锁                 —— 两条会话互相拆台;
  ⑦  HTTP 子进程继承锁 fd       —— 父进程被 SIGKILL 后锁被攥满十分钟;
  ⑧  BUSY 时仍继续往下走        —— 后来者删掉前一条正在服务的规则;
  ⑨  收尾失败仍打印成功         —— 最坏的一种: 用户以为关了;
  ⑩  删掉 token / mktemp 的判据 —— 描述文件写到文件系统根目录;
  ⑪  只加无关注释(反向对照)     —— 不该产生任何新失败。
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
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=1800)


def failures(out):
    s = set()
    for l in out.splitlines():
        t = l.strip()
        if t.startswith("[FAIL]"):
            s.add(re.sub(r"\s+", " ", t)[:150])
    return s


T_LIFE = ["python3", "tests/test-ios-offer-lifecycle.py"]
T_LEAK = ["python3", "tests/test-ios-offer-download-leak.py"]

CHAIN = "_ios_offer_chain(){ nft -a list chain inet pdg input 2>&1; }"
LEFT = '  [[ "$left" == 0 ]] && return 0'
DELLOOP = ('''  for h in $(printf '%s\\n' "$txt" | _ios_offer_marks); do
    nft delete rule inet pdg input handle "$h" >/dev/null 2>&1 || true
  done''')
LOCKCALL = "  _ios_offer_lock_acquire || return 1"
SRVLINE = ('  ( cd "$WWW" && exec timeout 600 python3 -m http.server "$PORT" '
           '--bind 0.0.0.0 >/dev/null 2>&1 ) 6>&- &')
READY = ('''  if ! _ios_offer_ready "$PROBE"; then
    _ios_offer_abort "临时 HTTP 没能就绪(端口 $PORT 可能被占) —— 未开放任何临时端口。"; return 1
  fi''')
ADD = ('''  if ! nft add rule inet pdg input ip saddr "$CIDR" tcp dport "$PORT" accept \\
        comment "$IOS_OFFER_MARK" 2>/dev/null; then
    _ios_offer_abort "添加临时放行失败(nft add) —— 通道未开放。"; return 1
  fi''')
TDOWN = "  if _ios_offer_teardown; then"
TOKCHK = ('''  if [[ ! "$TOK" =~ ^[0-9a-f]{12}$ ]]; then
    _ios_offer_abort "生成一次性下载令牌失败(openssl) —— 未开放任何临时端口。"; return 1
  fi''')
TMPCHK = ('''  if [[ -z "$WWW" || ! -d "$WWW" ]]; then
    _ios_offer_abort "创建临时下载目录失败(mktemp -d) —— 未开放任何临时端口。"; return 1
  fi''')

MUT = [
    ("① 链读取失败重新当成空集合(假成功本体)",
     [(CHAIN, "_ios_offer_chain(){ nft -a list chain inet pdg input 2>/dev/null; return 0; }", 1)],
     [T_LIFE]),
    ("② 吞掉删除失败并固定返回 0",
     [(LEFT, "  return 0  # 变异", 1)], [T_LIFE]),
    ("③ 恢复 _nft_apply_main 整表兜底",
     [(DELLOOP, DELLOOP + "\n  _nft_apply_main >/dev/null 2>&1 || true  # 变异", 1)], [T_LIFE, T_LEAK]),
    ("④ 忽略 nft add 的返回码",
     [(ADD, '  nft add rule inet pdg input ip saddr "$CIDR" tcp dport "$PORT" accept \\\n'
            '      comment "$IOS_OFFER_MARK" 2>/dev/null || true  # 变异', 1)], [T_LIFE]),
    ("⑤ 删除 HTTP 就绪验证",
     [(READY, "  : # 变异: 不验就绪", 1)], [T_LIFE]),
    ("⑥ 删除会话锁",
     [(LOCKCALL, "  : # 变异: 不加锁", 1)], [T_LIFE]),
    ("⑦ HTTP 子进程继承锁 fd",
     [(SRVLINE, SRVLINE.replace(" ) 6>&- &", " ) &"), 1)], [T_LIFE]),
    ("⑧ BUSY 时仍继续往下走",
     [(LOCKCALL, "  _ios_offer_lock_acquire || true  # 变异", 1)], [T_LIFE]),
    ("⑨ 收尾失败仍打印成功",
     [(TDOWN, "  if _ios_offer_teardown || true; then  # 变异", 1)], [T_LIFE]),
    ("⑩ 删掉 token / mktemp 的 fail-closed 判据",
     [(TOKCHK, "  : # 变异: 不查 token", 1), (TMPCHK, "  : # 变异: 不查 mktemp", 1)], [T_LIFE]),
    ("⑪ 只加无关注释(反向对照)",
     [(LOCKCALL, "  # 变异: 一条无关注释\n" + LOCKCALL, 1)], [T_LIFE]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-iosown-negctl.")
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

    base = suite([T_LIFE, T_LEAK])
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
            mutated = mutated.replace(old, new, 1)
            if new and new not in mutated:
                bad("%s → 替换内容没落进文件里" % label)
                aborted = True
                break
        if aborted:
            continue
        target.write_text(mutated, encoding="utf-8")
        if run(["bash", "-n", str(target)], cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            target.write_text(pristine, encoding="utf-8")
            continue
        added = suite(targets) - base
        target.write_text(pristine, encoding="utf-8")

        if label.startswith("⑪"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added)))
            continue
        if added:
            ok("%s → 新增具名失败 %d 条" % (label, len(added)))
            print("       " + sorted(added)[0][:128])
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
print("ios-offer-ownership-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

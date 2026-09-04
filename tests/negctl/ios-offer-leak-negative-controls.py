#!/usr/bin/env python3
"""负控: 那条临时下载通道的"收得回来"到底有没有牙。

正控在 tests/test-ios-offer-download-leak.py。这一支回答另一个问题: **如果收尾又退化了,
我们会不会知道?**

为什么值得单独立一支: 这个缺陷线上真发生过, 而它的现场**看不出因果** —— jp2 上只表现为
一条 `pdg doctor` 的红 `Tailscale 入口隔离`, 连带 `pdg update` 每次整轮回滚; 从那条红灯
一路查到"是 iOS 描述文件下载通道的 trap 漏了 HUP"用了整整一轮。这种"症状与病因隔着三层"
的缺陷一旦回归, 最可能的形态就是没人发现, 直到又一台机器升不上去。

判据是**正控里新增的具名失败**, 不是退出码(HANDOFF §9.15)。

九格:
  ① trap 去掉 HUP        —— 缺陷本体: SSH 断开 / 非交互调用时收尾一行都不跑;
  ② trap 去掉 EXIT       —— 其余异常退出路径的兜底没了;
  ③ add 改回 insert      —— 规则又插到链首, 排在 tailscale0 排除之前 → doctor 判红;
  ④ 去掉标记             —— 收尾只能按端口猜, 会误删用户自己的同端口放行;
  ⑤ 撤除函数空壳化       —— 三条信号路径全泄漏;
  ⑥ 入场清理删掉         —— 兜不住的路径(SIGKILL)留下的残留永远不会被带走;
  ⑦ 精确删除换成整表重载 —— 撤得掉, 但把别人的运行期规则一起冲了;
  ⑧ 抽取改成按端口匹配   —— 越权: 把用户自己写的同端口放行也当成自己的删掉;
  ⑨ 只加无关注释(反向对照)—— 不该产生任何新失败。
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
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=900)


def failures(out):
    s = set()
    for l in out.splitlines():
        t = l.strip()
        if t.startswith("[FAIL]"):
            s.add(re.sub(r"\s+", " ", t)[:150])
    return s


T_LEAK = ["python3", "tests/test-ios-offer-download-leak.py"]
T_UX = ["python3", "tests/test-ios-profile-ux.py"]

TRAP = "  trap '_ios_offer_teardown' EXIT HUP INT TERM"
# 锚点跟着产品走。收尾在 1e1a48b 里从"整表兜底"改成了"精确删除 + 复查最终状态", 会话锁
# 也是那一笔加的 —— 下面五个锚点当时全部失效。它们没有静默变哑弹, 而是被"锚点命中 0 次"
# 当场报出来(HANDOFF §9.18 立的规矩), 这里只是把它们接回新形态。
ADD = '  if ! nft add rule inet pdg input ip saddr "$CIDR" tcp dport "$PORT" accept \\'
MARK = '        comment "$IOS_OFFER_MARK" 2>/dev/null; then'
CLOSE_HEAD = "_ios_offer_nft_close(){\n  local txt h left"
SWEEP = "  if ! _ios_offer_nft_close; then"
PRECISE = ("""  for h in $(printf '%s\\n' "$txt" | _ios_offer_marks); do\n"""
           '    nft delete rule inet pdg input handle "$h" >/dev/null 2>&1 || true\n'
           '  done')
AWKMARK = '  awk -v m="comment \\"$IOS_OFFER_MARK\\"" \\'

MUT = [
    ("① trap 去掉 HUP(缺陷本体)",
     [(TRAP, "  trap '_ios_offer_teardown' EXIT INT TERM", 1)], [T_LEAK]),
    ("② trap 去掉 EXIT(异常退出没兜底)",
     [(TRAP, "  trap '_ios_offer_teardown' HUP INT TERM", 1)], [T_LEAK]),
    ("③ add 改回 insert(又插到链首)",
     [(ADD, ADD.replace("nft add rule", "nft insert rule"), 1)], [T_LEAK, T_UX]),
    ("④ 去掉标记(收尾只能按端口猜)",
     [(MARK, "        2>/dev/null; then", 1)], [T_LEAK, T_UX]),
    ("⑤ 撤除函数空壳化(三条信号路径全泄漏)",
     [(CLOSE_HEAD, "_ios_offer_nft_close(){\n  return 0  # 变异\n  local txt h left", 1)], [T_LEAK]),
    ("⑥ 入场清理删掉(残留永远不会被带走)",
     [(SWEEP, "  if false; then  # 变异: 不清残留", 1)], [T_LEAK]),
    ("⑦ 精确删除换成整表重载(冲掉别人的运行期规则)",
     [(PRECISE, "  _nft_apply_main >/dev/null 2>&1 || true  # 变异: 直接整表重载", 1)], [T_LEAK]),
    # 替换体也要跟着形态走: 抽取从"管道接一段 awk"变成了独立函数 _ios_offer_marks 里的
    # 一行 awk, 缩进和有没有前导管道都变了。照旧写法替换会造出语法错误 —— 那不是负控,
    # 是改坏器自己坏了(改坏器语法不合法这一格会被显式判掉, 不会伪装成"有效负控")。
    ("⑧ 抽取改成按端口匹配(越权删别人的规则)",
     [(AWKMARK, '  awk -v m="tcp dport 8443" \\', 1)], [T_LEAK]),
    ("⑨ 只加无关注释(反向对照)",
     [(TRAP, "  # 变异: 一条无关注释\n" + TRAP, 1)], [T_LEAK]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-iosleak-negctl.")
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

    base = suite([T_LEAK, T_UX])
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
        syn = run(["bash", "-n", str(target)], cwd=wd)
        if syn.returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            target.write_text(pristine, encoding="utf-8")
            continue
        added = suite(targets) - base
        target.write_text(pristine, encoding="utf-8")

        if label.startswith("⑨"):
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
print("ios-offer-leak-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""负控:Telegram 内联去广告入口 + 事务 CLI 的判据有没有牙。

盯三个生产文件 —— `deploy/bot/pdg-bot.py`(入口/授权/状态/调用边界)、`deploy/bot/pdg.sh`
(事务边界与回滚)、`deploy/bot/adblock.py`(规则语义)。逐格把生产代码改坏(只改工作副本,
正式树一个字节不动), 跑两支聚焦测试, 看具名失败集合相对基线有没有新增。

每格五步(规矩见 HANDOFF §6): 锚点恰好命中 / 替换真的落进文件 / 语法门仍过 /
具名失败集合有新增 / finally 恢复正式树并核对 sha256。0 条转红 = 这一格无效, 判 FAIL。
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
BOT = "deploy/bot/pdg-bot.py"
PDG = "deploy/bot/pdg.sh"
ADB = "deploy/bot/adblock.py"
TOUCHED = [ROOT / BOT, ROOT / PDG, ROOT / ADB]
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def failures(out):
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


SUITES = (["python3", "tests/test-bot-adblock-inline.py"],
          ["bash", "tests/test-adblock-rule-cli.sh"])


def run_suites(wd):
    out = ""
    for cmd in SUITES:
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


MUT = [
    ("① 摘掉 callback 授权前置", BOT,
     [('                    if q["from"]["id"] in ALLOWED:\n', "                    if True:\n", 1)],
     "callback 授权"),
    ("② 摘掉文本输入授权前置", BOT,
     [('                    if m["from"]["id"] not in ALLOWED:\n                        continue\n', "", 1)],
     "文本授权"),
    ("③ 状态不带发起者(退回纯 chat 键)", BOT,
     [('    state[chat] = "adblock_%s:%s" % (kind, uid if uid is not None else "")',
       '    state[chat] = "adblock_%s:" % (kind,)', 1)],
     "不能完成甲"),
    ("④ 取消后不清状态", BOT,
     [('        if act in ("menu", "back", "cancel"):\n            state.pop(chat, None)',
       '        if act in ("menu", "back", "cancel"):\n            pass', 1)],
     "取消后状态被清除"),
    # 只摘守卫的话, 未知 act 会在下面的字典查找上抛 KeyError —— 那是"崩了", 不是
    # "未知 callback 执行了动作"。要如实模拟后者, 查找也得一并变宽容。
    ("⑤ 未知 callback 也照做", BOT,
     [('        if act not in ("menu", "status", "add", "del", "check", "cancel", "back"):',
       '        if False:', 1),
      ('        kind = {"add": "add", "del": "del", "check": "check"}[act]',
       '        kind = {"add": "add", "del": "del", "check": "check"}.get(act, "add")', 1)],
     "未知 adblock callback"),
    ("⑥ 把域名写进 callback_data", BOT,
     [('    [{"text": "🔎 查询域名", "callback_data": "adblock:check"}],',
       '    [{"text": "🔎 查询域名", "callback_data": "adblock:check:example.com"}],', 1)],
     "callback_data"),
    ("⑦ Bot 直接写规则文件", BOT,
     [('        if kind in ("add", "del"):\n            d = _adblock_cli("rule-" + kind, text)',
       '        if kind in ("add", "del"):\n'
       '            open("/tmp/adblock_block.txt", "w").write(text)\n'
       '            d = _adblock_cli("rule-" + kind, text)', 1)],
     "直接写规则文件"),
    ("⑧ CLI 改成 shell 字符串执行", BOT,
     [('    r = sh([PDG_CLI, "adblock", *args])',
       '    r = subprocess.run("%s adblock %s" % (PDG_CLI, " ".join(args)), shell=True,\n'
       '                       capture_output=True, text=True)', 1)],
     "shell=True"),
    ("⑨ 删除改成子串匹配", ADB,
     [("    kept = [ln for ln in lines if ln.strip() != canon]",
       "    kept = [ln for ln in lines if norm not in ln]", 1)],
     "误删"),
    ("⑩ 停用态也编译并重启", PDG,
     [('      if [[ "$(_adblock_intent)" != 1 ]]; then\n        rm -f "$_src_bak"',
       '      if false; then\n        rm -f "$_src_bak"', 1)],
     "停用态"),
    ("⑪ 幂等操作也重启", PDG,
     [('      if [[ "$_change" == none ]]; then\n        rm -f "$_src_bak"',
       '      if false; then\n        rm -f "$_src_bak"', 1)],
     "already_exists"),
    ("⑫ 启用态顺手重新下载第三方表", PDG,
     [('      if ! python3 "$mod" compile 1 "$ADB_STATE_DIR" "$ADB_USER_BLOCK" >/dev/null 2>&1; then',
       '      python3 "$mod" update >/dev/null 2>&1\n'
       '      if ! python3 "$mod" compile 1 "$ADB_STATE_DIR" "$ADB_USER_BLOCK" >/dev/null 2>&1; then', 1)],
     "下载了第三方表"),
    ("⑬ mosdns 起不来仍然提交", PDG,
     [('        if ! systemctl is-active --quiet mosdns; then', '        if false; then', 1)],
     "没恢复"),
    ("⑭ 重启失败不恢复前像", PDG,
     [('        cp -a "$_src_bak" "$ADB_USER_BLOCK" 2>/dev/null || _bad=1', "        :", 1)],
     "没恢复"),
    ("⑮ LKG 被覆盖", PDG,
     [('      _adb_emit applied "$_change" "$_restarted" "$_ovr"',
       '      : > "$ADB_STATE_DIR/list.lkg"\n      _adb_emit applied "$_change" "$_restarted" "$_ovr"', 1)],
     "LKG"),
    ("⑯ 失败路径仍回成功文案", BOT,
     [('    "apply_failed_rolled_back": "❌ 应用失败，已回滚，规则未生效。"',
       '    "apply_failed_rolled_back": "✅ 已添加"', 1)],
     "成功文案"),
    ("⑰ 恢复 /adblock_add slash handler", BOT,
     [('        if cmd == "/addrule":',
       '        if cmd == "/adblock_add":\n'
       '            state[chat] = "adblock_add:"; send_plain(chat, "发域名"); return\n'
       '        if cmd == "/addrule":', 1)],
     "slash"),
    ("⑱ 只加一行无关注释(反向对照)", BOT,
     [("def _adblock_cli(", "# (负控的空转对照, 不改变任何行为)\ndef _adblock_cli(", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-botadb-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (BOT, PDG, ADB)}
    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每格的'新增'都算不出来: %s" % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 两支聚焦测试在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want in MUT:
        target = Path(wd) / rel
        text = pristine[rel]
        anchored = True
        for anchor, repl, hits in edits:
            n = text.count(anchor)
            if n != hits:
                bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, n, hits))
                anchored = False
                break
            text = text.replace(anchor, repl, 1)
        if not anchored:
            target.write_text(pristine[rel], encoding="utf-8")
            continue
        if text == pristine[rel]:
            bad("%s: 替换没有真的落进文件" % label)
            continue
        target.write_text(text, encoding="utf-8")
        syn = run(["bash", "-n", str(target)]) if rel.endswith(".sh") \
            else run(["python3", "-m", "py_compile", str(target)])
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)" % (label, (syn.stderr or "")[:80]))
            target.write_text(pristine[rel], encoding="utf-8")
            continue
        got = run_suites(wd)
        new = got - base
        target.write_text(pristine[rel], encoding="utf-8")
        if want is None:
            (ok if not new else bad)(
                "%s: 新增失败 0 条(判据没在看噪声)" % label if not new
                else "%s: 不该有新失败, 却新增 %d 条: %s" % (label, len(new), sorted(new)[:2]))
            continue
        if not new:
            bad("%s: **0 条转红** —— 这一格的判据没有牙" % label)
        elif not any(want in n for n in new):
            bad("%s: 转红了但没命中预期判据(%s): %s" % (label, want, sorted(new)[:2]))
        else:
            hit = sorted(n for n in new if want in n)[0]
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:76]))
finally:
    drift = [str(p) for p in TOUCHED if sha(p) != before[p]]
    if drift:
        bad("正式树被改动了(负控只该改工作副本): %s" % drift)
    else:
        ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
    for p in TOUCHED:
        if os.stat(p).st_mode != modes[p]:
            bad("正式树文件 mode 变了: %s" % p)

print("-" * 62)
print("bot-adblock-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

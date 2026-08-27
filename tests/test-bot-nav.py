#!/usr/bin/env python3
"""Static regressions for Telegram bot navigation after operation results."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
bot = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")

assert "OPS_BACK" in bot, "ops result keyboard must be explicit, not the full first-level MENU"
assert '"callback_data": "nav:ops"' in bot, "ops result keyboard should return to the ops submenu"
assert 'set_tfo(data == "tfo:on"); edit(chat, mid, msg if ok else ("❌ " + msg), OPS_BACK)' in bot, (
    "TFO toggle result must not show the whole first-level menu"
)
# 「🔄 重启服务」的每条出口(内核失败 / mosdns 起不来 / 全部成功)都必须留在运维子菜单,
# 不许刷出一级菜单。这里按分支取代码段再逐条查, 而不是钉死某一行字面量 —— 那样文案一改
# 断言就废, 却又不是真的坏了。
_restart_branch = bot.split('if data == "restart":', 1)[1].split('if data == "updgeo":', 1)[0]
_edits = _restart_branch.count("edit(chat, mid")
assert _edits >= 3, "重启分支应当分别处理: 内核失败 / mosdns 起不来 / 全部成功"
# 每次编辑都配一个 OPS_BACK(消息可能跨行, 所以数总量而不是逐行看)
assert _restart_branch.count("OPS_BACK") >= _edits, "restart result must stay in ops navigation"
assert "MENU)" not in _restart_branch, "重启结果不该刷出一级菜单"
assert "mosdns 未能起来" in _restart_branch, (
    "mosdns 重启结果必须核实 —— 不能只看 apply_sb 成功就回「已重启」"
)
assert 'msg = f"✅ geosite 已更新; 规则集刷新 {n} 个"' in bot and "edit(chat, mid, msg, OPS_BACK)" in bot, (
    "rule-update result path should stay covered"
)
assert '), OPS_BACK); return' in bot, "rule-update result must use OPS_BACK"


def assert_near(marker: str, expected: str, message: str, window: int = 2000) -> None:
    start = bot.find(marker)
    assert start >= 0, f"missing marker: {marker}"
    assert expected in bot[start:start + window], message


assert "EXIT_BACK" in bot, "exit-management third-level screens should return to the exit submenu"
assert "RULE_BACK" in bot, "rule-management third-level screens should return to the rule submenu"
assert '"callback_data": "nav:exit"' in bot, "exit back keyboard should return to exit management"
assert '"callback_data": "nav:rule"' in bot, "rule back keyboard should return to rule management"
assert '"callback_data": "exit_list"' in bot, "exit submenu list should not reuse the main-level exits callback"
assert_near('if data == "exit_list":', "EXIT_BACK", "exit list should return to exit management")
assert_near('if data == "rules":', "RULE_BACK", "rule list should return to rule management")
assert_near('if data == "add_exit":', "EXIT_BACK", "add-exit prompt should return to exit management")
assert_near('if data == "add_grp":', "EXIT_BACK", "add-group prompt should return to exit management")
assert_near('if data == "order_exit":', "EXIT_BACK", "exit ordering prompt should return to exit management")
assert_near('if data.startswith("delx:"):', "EXIT_BACK", "exit deletion result should return to exit management")
assert_near('if data.startswith("fin:"):', "EXIT_BACK", "default-exit result should return to exit management")
assert_near('if data == "add_rule":', "RULE_BACK", "add-rule prompt should return to rule management")
assert_near('if data == "edit_rule":', "RULE_BACK", "edit-rule selector should return to rule management")
assert_near('if data.startswith("ero:"):', "RULE_BACK", "changing a rule outbound should return to rule management")
assert_near('if data == "del_rule":', "RULE_BACK", "delete-rule selector should return to rule management")
assert_near('if data == "ddel":', "RULE_BACK", "bulk domain deletion should return to rule management")
assert_near('if data == "testdom":', "RULE_BACK", "test-domain prompt should return to rule management")
assert_near('if data == "add_rs":', "RULE_BACK", "add-ruleset prompt should return to rule management")
assert_near('if data == "del_rs":', "RULE_BACK", "delete-ruleset selector should return to rule management")
assert_near('if data == "edit_rs":', "RULE_BACK", "rename-ruleset selector should return to rule management")
assert_near('if data.startswith("delrs:"):', "RULE_BACK", "ruleset deletion result should return to rule management")
assert_near('if data == "test":', 'edit(chat, mid, "测试中…", BACK)', (
    "exit latency test progress message should show only a back button, not the full first-level menu"
))
assert 'edit(chat, mid, "测试中…", None)' not in bot, (
    "passing None to edit() falls back to the full first-level MENU"
)
assert_near('if data == "upd_check":', 'edit(chat, mid, "🔄 检查更新中…", BACK)', (
    "update-check progress message should show only a back button, not the full first-level menu"
))
assert 'edit(chat, mid, "🔄 检查更新中…", None)' not in bot, (
    "passing None to edit() falls back to the full first-level MENU"
)
none_progress_edits = re.findall(r"edit\(chat, mid, [^\n]+, None\)", bot)
assert not none_progress_edits, (
    "progress/result edits must pass an explicit keyboard; None falls back to the full first-level MENU: "
    + ", ".join(none_progress_edits)
)
assert_near('if data == "dnsup":', '"callback_data": "menu"', (
    "DNS upstream page should include a main-menu button"
), window=1600)
assert_near('if data == "tfo":', '"callback_data": "menu"', (
    "TFO page should include a main-menu button"
), window=900)

callback_block = bot[bot.find('elif "callback_query" in u:'):]
answer_pos = callback_block.find('answer_cb_async(q["id"])')
# 用**前缀**定位这次调用, 不锁死整行字节: 这条判据要验的是"先 answer 再 handle"的顺序,
# 而不是调用点长什么样。锁死整行的话, 往 handle_cb 加一个参数(例如把发起者 uid 传下去)
# 就会让它红 —— 红的是形态, 不是顺序。test-link-bot.py 一直是按前缀找的, 这里跟齐。
handle_pos = callback_block.find('handle_cb(q["message"]')
assert answer_pos >= 0 and handle_pos >= 0, "callback loop should answer and handle callback queries"
assert answer_pos < handle_pos, "answerCallbackQuery should be sent before slow callback handling"

# ── 动态回归: 返回主菜单/切子菜单必须清掉待输入状态和删除勾选 ──
# 否则: 点「iOS 描述文件」进入 ios_ssid 输入态 → 点返回 → 下一条随手发的文字被误当 SSID 名单生成描述文件。
import importlib.util

spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

mod.edit = lambda chat, mid, text, kb=None: None   # 不出网
mod.status_text = lambda: "s"
mod._dot_host = lambda: "dot.test"                 # nav:client 标题会用到

for data in ("menu", "status", "nav:client", "nav:exit", "nav:rule", "nav:ops"):
    mod.state[1] = "ios_ssid"
    mod.del_sel[1] = {"x.com"}
    mod.handle_cb(1, 9, data)
    assert 1 not in mod.state, f"{data} 后待输入状态应被清掉"
    assert 1 not in mod.del_sel, f"{data} 后删除勾选应被清掉"

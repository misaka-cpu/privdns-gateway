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
assert 'edit(chat, mid, "✅ 已重启 sing-box + mosdns" if ok else msg, OPS_BACK)' in bot, (
    "restart result must stay in ops navigation"
)
assert 'edit(chat, mid, (f"✅ geosite 已更新; 规则集刷新 {n} 个" if r.returncode == 0' in bot, (
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
handle_pos = callback_block.find('handle_cb(q["message"]["chat"]["id"], q["message"]["message_id"], q["data"])')
assert answer_pos >= 0 and handle_pos >= 0, "callback loop should answer and handle callback queries"
assert answer_pos < handle_pos, "answerCallbackQuery should be sent before slow callback handling"

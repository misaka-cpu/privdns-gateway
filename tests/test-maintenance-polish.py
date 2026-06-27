#!/usr/bin/env python3
"""Static regressions for small CLI/report/bot polish fixes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
bot = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
pdg = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
report = (ROOT / "deploy/bot/report.py").read_text(encoding="utf-8")


def block_after(text: str, marker: str, window: int = 900) -> str:
    start = text.find(marker)
    assert start >= 0, f"missing marker: {marker}"
    return text[start:start + window]


send_plain = block_after(bot, "def send_plain")
assert "p.pop(\"parse_mode\", None)" in send_plain, (
    "send_plain should retry without HTML parse_mode when Telegram rejects unescaped user/error text"
)
assert send_plain.count("post(\"sendMessage\", p)") >= 2, (
    "send_plain should attempt HTML first, then plain text fallback"
)

pdg_pos = report.find('"inet", "pdg", "input"')
filter_pos = report.find('"inet", "filter", "input"')
assert pdg_pos >= 0, "pdg report should read the current firewall chain inet pdg/input"
assert filter_pos >= 0, "pdg report should keep fallback compatibility with old inet filter/input installs"
assert pdg_pos < filter_pos, "pdg report should prefer inet pdg before falling back to inet filter"

assert 'printf "选择: "' in pdg, "menu prompt should be printed explicitly so it survives after update output"
assert "read -r c" in pdg, "menu input should use read -r after printing the prompt"
assert 'read -rp "选择: " c' not in pdg, "read -p prompt can disappear in some terminals"
assert '3) cmd_update && exec /usr/local/bin/pdg menu;;' in pdg, (
    "after a successful menu update, pdg should re-exec the freshly installed script"
)

assert '9090(local clash_api)' in pdg, "status output should label 9090 as local clash_api, not a normal exposed port"

rollback = block_after(pdg, "cmd_rollback()", window=1600)
assert '[[ "$idx" =~ ^[0-9]+$ ]]' in rollback, "rollback index should reject non-numeric input"
assert 'idx >= ${#snaps[@]}' in rollback, "rollback index should reject out-of-range input"

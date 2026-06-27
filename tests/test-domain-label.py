#!/usr/bin/env python3
"""Regression: domain test should show a renamed ruleset label, not rs_xxxx."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy/bot/pdg-bot.py"

spec = importlib.util.spec_from_file_location("pdg_bot", BOT)
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

bot.load = lambda: {
    "route": {
        "rules": [{"rule_set": "rs_9d05f092", "outbound": "hk"}],
        "final": "direct",
    }
}
bot._rs_meta = lambda: {"rs_9d05f092": {"label": "line", "count": 24}}
bot._match_ruleset = lambda name, domain, suffixes: name == "rs_9d05f092" and domain == "line-apps.com"

tag, why = bot._singbox_route("line-apps.com")

assert tag == "hk"
assert why == "规则集 line"
assert "rs_9d05f092" not in why

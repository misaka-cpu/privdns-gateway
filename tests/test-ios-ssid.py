#!/usr/bin/env python3
"""Regression: iOS 描述文件 —— Wi-Fi 按 :81 探测判定 + 可选 SSID 强制直连名单."""
import importlib.util
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy/bot/pdg-bot.py"

spec = importlib.util.spec_from_file_location("pdg_bot", BOT)
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

bot.IOS_TMPL = str(ROOT / "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
bot._platform = lambda: "ios"      # _ios_profile 现要求 iOS 平台(最底层门控)
bot._dot_host = lambda: "dot.example.com"
bot._server_ip = lambda: "203.0.113.10"
IDS = {"root": "11111111-1111-1111-1111-111111111111",
       "dns": "22222222-2222-2222-2222-222222222222",
       "ca": "33333333-3333-3333-3333-333333333333"}

# ── 无 SSID: Wi-Fi 探测 → Wi-Fi 兜底直连 → 蜂窝探测 → 全局兜底 ──
p = plistlib.loads(bot._ios_profile())
rules = p["PayloadContent"][0]["OnDemandRules"]
want = [
    ("WiFi", "Connect", True),        # Wi-Fi 能探到 :81(走专线) → 启用 DoT
    ("WiFi", "Disconnect", False),    # 其它 Wi-Fi → 直连
    ("Cellular", "Connect", True),    # 蜂窝内网卡 → 启用 DoT
    (None, "Disconnect", False),      # 兜底
]
assert len(rules) == len(want), rules
for r, (iface, action, probe) in zip(rules, want):
    assert r.get("InterfaceTypeMatch") == iface, r
    assert r["Action"] == action, r
    assert ("URLStringProbe" in r) == probe, r
    if probe:
        assert r["URLStringProbe"] == "http://203.0.113.10:81/probe", r
    assert "SSIDMatch" not in r, r
dns = p["PayloadContent"][0]["DNSSettings"]
assert dns["ServerName"] == "dot.example.com" and dns["ServerAddresses"] == ["203.0.113.10"]

# ── 带 SSID: 名单规则插在最前(优先于探测), 其余不变; 特殊字符不破 XML ──
# SSID 名单会被**排序**后写入: 用户两次填同样几个 Wi-Fi 但顺序不同, 不该被判成"配置变了"
# 而多出一个修订号(见 iosprofile.norm_ssids)。所以这里比对的是排序后的名单。
ssids = ["Home WiFi", "A&B<C>\"", "办公室"]
p2 = plistlib.loads(bot._ios_profile(ssids))
rules2 = p2["PayloadContent"][0]["OnDemandRules"]
assert len(rules2) == len(want) + 1
first = rules2[0]
assert first == {"InterfaceTypeMatch": "WiFi", "SSIDMatch": sorted(ssids),
                 "Action": "Disconnect"}, first
assert [r["Action"] for r in rules2[1:]] == [a for _, a, _ in want]
# 顺序不同的同一组 SSID → 逐字节相同(否则"点一下重新生成"就会凭空造出一个新版本)
assert bot._ios_profile(list(reversed(ssids)), ids=IDS) == bot._ios_profile(ssids, ids=IDS)

print("ios-ssid regression OK")

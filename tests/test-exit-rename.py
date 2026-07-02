#!/usr/bin/env python3
"""Regression: rename_exit 真改名并级联更新所有引用(规则/故障组/final/TG/规则集元数据)."""
import copy
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy/bot/pdg-bot.py"

spec = importlib.util.spec_from_file_location("pdg_bot", BOT)
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

cfg = {
    "outbounds": [
        {"type": "direct", "tag": "jp"},
        {"type": "shadowsocks", "tag": "hk", "server": "203.0.113.10", "server_port": 1},
        {"type": "shadowsocks", "tag": "tw", "server": "203.0.113.11", "server_port": 1},
        {"type": "urltest", "tag": "auto", "outbounds": ["hk", "tw"]},
    ],
    "route": {
        "rules": [
            {"action": "reject", "ip_cidr": ["203.0.113.1/32"]},
            {"inbound": ["tg-proxy"], "outbound": "hk"},
            {"rule_set": "rs_11111111", "outbound": "hk"},
            {"domain_suffix": ["x.com"], "outbound": "hk"},
            {"domain_suffix": ["y.com"], "outbound": "tw"},
            {"domain_suffix": ["z.com"], "outbound": "auto"},
        ],
        "final": "hk",
    },
}

bot.load = lambda: copy.deepcopy(cfg)

def fake_apply(mod):
    cc = copy.deepcopy(cfg)
    mod(cc)
    cfg.clear(); cfg.update(cc)
    return True, ""
bot.apply_sb = fake_apply

meta = {"rs_11111111": {"url": "http://example.com/x.list", "outbound": "hk", "label": "币安"}}
bot._rs_meta = lambda: copy.deepcopy(meta)
def fake_save(m):
    meta.clear(); meta.update(m)
bot._save_rs_meta = fake_save

# ── 改代理出口: hk → hk2, 所有引用级联 ──
ok, msg = bot.rename_exit("hk", "hk2")
assert ok, msg
tags = [o["tag"] for o in cfg["outbounds"]]
assert "hk2" in tags and "hk" not in tags
auto = next(o for o in cfg["outbounds"] if o["tag"] == "auto")
assert auto["outbounds"] == ["hk2", "tw"], auto              # 故障组成员
assert all(r.get("outbound") != "hk" for r in cfg["route"]["rules"])
tg = next(r for r in cfg["route"]["rules"] if r.get("inbound") == ["tg-proxy"])
assert tg["outbound"] == "hk2"                               # TG 出口规则
rs = next(r for r in cfg["route"]["rules"] if r.get("rule_set"))
assert rs["outbound"] == "hk2"                               # 规则集规则
assert cfg["route"]["final"] == "hk2"                        # 默认出口
assert meta["rs_11111111"]["outbound"] == "hk2"              # 规则集元数据
assert "hk2" in msg and "已改名" in msg

# ── 改故障组名: auto → main, 指向组的规则级联 ──
ok, msg = bot.rename_exit("auto", "main")
assert ok, msg
assert any(o["tag"] == "main" and o["type"] == "urltest" for o in cfg["outbounds"])
zr = next(r for r in cfg["route"]["rules"] if r.get("domain_suffix") == ["z.com"])
assert zr["outbound"] == "main"

# ── 拒绝分支 ──
ok, msg = bot.rename_exit("jp", "jp2")                       # direct 不可改(WDA 依赖)
assert not ok, msg
ok, msg = bot.rename_exit("nope", "x")                       # 不存在
assert not ok, msg
ok, msg = bot.rename_exit("tw", "main")                      # 与现有出口/组重名
assert not ok and "占用" in msg, msg
ok, msg = bot.rename_exit("tw", "tw")                        # 同名
assert not ok, msg
ok, msg = bot.rename_exit("tw", "中文名")                     # 非法字符(清洗后无字母数字)
assert not ok, msg
ok, msg = bot.rename_exit("tw", "direct")                    # 保留字
assert not ok, msg
snap = copy.deepcopy(cfg)

# ── apply_sb 失败 → 原样返回错误, 元数据不动 ──
bot.apply_sb = lambda mod: (False, "boom")
ok, msg = bot.rename_exit("tw", "tw9")
assert not ok and msg == "boom"
assert meta["rs_11111111"]["outbound"] == "hk2"
assert cfg == snap

print("exit-rename regression OK")

#!/usr/bin/env python3
"""Regression: 观测面板 (zashboard) 开关 + clash_api secret 适配。"""
import importlib.util
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

# ── clash_get: 有 secret 带 Bearer, 无 secret 不带 ──────────────────────────
cap = {}
def fake_urlopen(req, timeout=None):
    cap["auth"] = req.get_header("Authorization")
    class R:
        def __enter__(s): return s
        def __exit__(s, *a): pass
        def read(s): return b'{"v":1}'
    return R()
bot.urllib.request.urlopen = fake_urlopen

bot.load = lambda: {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
bot.clash_get("/version")
assert cap["auth"] is None, "无 secret 不该带 Authorization"
bot.load = lambda: {"experimental": {"clash_api": {"secret": "S3CR3T"}}}
bot.clash_get("/version")
assert cap["auth"] == "Bearer S3CR3T", ("有 secret 应带 Bearer", cap["auth"])
print("[OK]   clash_get 按 secret 带/不带 Bearer")

# ── set_panel(on): clash_api 改 0.0.0.0 + secret + external_ui, 生成一键链接 ──
_REAL_ENSURE = bot._ensure_zashboard        # 存真函数, 供后面 SHA 校验用例
bot._ensure_zashboard = lambda: (True, "")
bot._panel_cidr = lambda: "172.22.0.0/16"
_REAL_FW = bot._panel_firewall              # 存真函数, 供后面 firewall 用例
fw = []
bot._panel_firewall = lambda on, cidr: fw.append((on, cidr))
bot._server_ip = lambda: "203.0.113.9"
cfg = {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
def fake_apply(mod):
    mod(cfg); return True, ""
bot.apply_sb = fake_apply

ok, link = bot.set_panel(True)
assert ok, link
api = cfg["experimental"]["clash_api"]
assert api["external_controller"] == "0.0.0.0:9090", api
assert api["external_ui"] == bot.UI_DIST
sec = api["secret"]; assert sec and len(sec) >= 16
assert link == f"http://203.0.113.9:9090/ui/#/setup?hostname=203.0.113.9&port=9090&secret={sec}", link
assert bot._panel_on(cfg) is True
assert fw and fw[-1] == (True, "172.22.0.0/16"), "应放行内网卡段 → 9090"
print("[OK]   set_panel(on): clash_api 0.0.0.0+secret+external_ui + 一键链接 + 放行内网 9090")

# ── set_panel(off): 收回 127.0.0.1, 去掉 secret/external_ui, 撤防火墙 ──────────
ok, msg = bot.set_panel(False)
assert ok, msg
api = cfg["experimental"]["clash_api"]
assert api["external_controller"] == "127.0.0.1:9090"
assert "secret" not in api and "external_ui" not in api
assert bot._panel_on(cfg) is False
assert fw[-1] == (False, "172.22.0.0/16"), "应撤销 9090 放行"
print("[OK]   set_panel(off): 收回 127.0.0.1 + 去 secret/external_ui + 撤放行")

# ── 无内网段 → 拒绝开启(不裸奔) ──────────────────────────────────────────────
bot._panel_cidr = lambda: ""
ok, err = bot.set_panel(True)
assert not ok and "内网" in err, ("无内网段应拒绝", ok, err)
print("[OK]   读不到内网卡段 → 拒绝开启")

# ── _ensure_zashboard: SHA256 不符 → 拒绝(供应链校验)────────────────────────
bot._ensure_zashboard = _REAL_ENSURE        # 恢复真函数
bot._fetch_bytes = lambda url: b"not-a-real-zashboard-zip"
bot.UI_DIR = tempfile.mkdtemp(); bot.UI_DIST = os.path.join(bot.UI_DIR, "dist")
ok, err = bot._ensure_zashboard()
assert not ok and "SHA256" in err, ("SHA 不符应拒绝", ok, err)
print("[OK]   zashboard SHA256 不符 → 拒绝安装")

# ── 定时自动关闭: arm 排定时器 + 记链接; autoclose 关面板+删链接 ──────────────
# 让 set_panel 走前面的 mock(可开可关), _ensure/cidr/firewall/server_ip 已 mock
bot._ensure_zashboard = lambda: (True, "")
bot._panel_cidr = lambda: "172.22.0.0/16"
cfg2 = {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
bot.apply_sb = lambda mod: (mod(cfg2), (True, ""))[1]
deleted = []
bot.delete_message = lambda ch, m: deleted.append((ch, m))
sent2 = []
bot.send_plain = lambda ch, t: sent2.append(t)

bot.set_panel(True)
bot._panel_arm(42, 999, 0.05)                    # 50ms 后自动关
assert bot._panel_link == (42, 999) and bot._panel_timer is not None, "arm 应记链接+排定时器"
assert bot._panel_on(cfg2) is True
import time as _t; _t.sleep(0.2)                 # 等定时器触发
assert bot._panel_on(cfg2) is False, "到时应自动关面板"
assert (42, 999) in deleted, "到时应删掉含密钥的链接消息"
assert bot._panel_link is None and bot._panel_timer is None
print("[OK]   定时到期: 自动关面板 + 删链接消息")

# 手动关也删链接 + 取消定时器
bot.set_panel(True); bot._panel_arm(7, 555, 3600)
bot._panel_cancel_timer(); bot._panel_delete_link()
assert bot._panel_timer is None and bot._panel_link is None and (7, 555) in deleted
print("[OK]   手动关: 取消定时器 + 删链接消息")

# ── _panel_firewall: off 只删(供启动兜底清残留放行), on 删旧+加 ────────────────
bot._panel_firewall = _REAL_FW              # 恢复真函数
calls = []
class _R:
    def __init__(s, out=""): s.stdout = out
def fake_sh(cmd):
    calls.append(cmd)
    if len(cmd) > 1 and cmd[1] == "-a":          # nft -a list chain … → 返回一条 pdg-panel 规则
        return _R('ip saddr 172.22.0.0/16 tcp dport 9090 accept comment "pdg-panel" # handle 15\n')
    return _R("")
bot.sh = fake_sh
calls.clear(); bot._panel_firewall(False, "172.22.0.0/16")
assert any(c[:4] == ["nft", "delete", "rule", "inet"] and "15" in c for c in calls), "off 应按 handle 删残留规则"
assert not any("insert" in c for c in calls), "off 不应 insert"
calls.clear(); bot._panel_firewall(True, "172.22.0.0/16")
assert any("insert" in c for c in calls), "on 应 insert 放行规则"
print("[OK]   _panel_firewall: off 只删残留 / on 删旧+加(启动兜底可清 config-off 的残留放行)")

# ── 菜单/回调接线 ────────────────────────────────────────────────────────────
src = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
assert '"callback_data": "panel"' in src, "运维菜单应有观测面板入口"
for cb in ('if data == "panel":', 'if data.startswith("panel:on:"):', 'if data == "panel:off":'):
    assert cb in src, f"缺回调 {cb}"
for token in ('"panel:on:10"', '"panel:on:30"', '"panel:on:0"'):
    assert token in src, f"缺时长按钮 {token}"
assert "_panel_arm(chat, link_mid" in src and "if _panel_on():" in src, "缺 arm 调用 / 启动兜底关面板"
assert "_panel_firewall(False, _panel_cidr())" in src, "启动兜底应能清 config-off 但残留的放行规则"
print("[OK]   运维菜单 + 时长按钮 + 回调接线 + 启动兜底(含清残留放行)")

print("panel regression OK")

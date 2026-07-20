#!/usr/bin/env python3
"""TFO(TCP Fast Open)状态回归。

修复的 bug: 原来 TFO 状态靠"所有代理出口都带 tcp_fast_open"推断, 加一个新出口
(parse_link 出来的不带标志)就把 all(...) 打成假 → "开了 TFO 却显示关闭、新出口没享受到"。
改为持久化意图(profile.env: PDG_TFO), apply_sb 每次把意图同步到含新增的所有出口。
"""
import importlib.util as u
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = u.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = u.module_from_spec(spec); spec.loader.exec_module(bot)

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def apply_like(c, mod):
    """模拟 apply_sb 内的 TFO 同步顺序(改动前判定意图 → mod → 同步到所有出口)。"""
    tfo = bot._tfo_intent(c); mod(c); bot._tfo_apply(c, tfo); return c


def cfg():
    return {"outbounds": [
        {"type": "shadowsocks", "tag": "ss1", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "x"},
        {"type": "hysteria2", "tag": "hy", "server": "2.2.2.2", "server_port": 443, "password": "y"},
        {"type": "direct", "tag": "jp"}],
        "inbounds": [{"type": "direct", "tag": "in", "listen_port": 443}],
        "route": {"rules": [], "final": "jp"}}


def main():
    tmp = tempfile.mkdtemp()
    bot.PROFILE_ENV = os.path.join(tmp, "profile.env")

    c = cfg()
    assert bot._tfo_on(c) is False; ok("初始(无 PDG_TFO, 出口无标志)→ 关闭")

    # 开启 → 持久化 + 同步
    bot._profile_set("PDG_TFO", "1"); apply_like(c, lambda cc: None)
    assert bot._tfo_on(c) is True
    assert all(o.get("tcp_fast_open") for o in c["outbounds"] if o["type"] in bot.PROXY_TYPES)
    ok("开启 → _tfo_on True + 所有代理出口带标志")

    # 核心回归: 加新出口不冲掉 TFO 状态, 且新出口继承
    apply_like(c, lambda cc: cc["outbounds"].insert(
        0, {"type": "vmess", "tag": "new", "server": "3.3.3.3", "server_port": 443, "uuid": "u"}))
    assert bot._tfo_on(c) is True, "加新出口后 TFO 不该翻成关闭"
    assert c["outbounds"][0].get("tcp_fast_open") is True, "新出口应继承 TFO"
    ok("加新出口 → 状态保持开启 + 新出口继承(原 bug 已修)")

    # 关闭 → 清标志
    bot._profile_set("PDG_TFO", "0"); apply_like(c, lambda cc: None)
    assert bot._tfo_on(c) is False
    assert not any(o.get("tcp_fast_open") for o in c["outbounds"])
    ok("关闭 → _tfo_on False + 清掉所有标志")

    # 老装回退: 无 PDG_TFO 但出口都带标志 → 推断为开
    os.remove(bot.PROFILE_ENV)
    legacy = cfg()
    for o in legacy["outbounds"]:
        if o["type"] in bot.PROXY_TYPES:
            o["tcp_fast_open"] = True
    assert bot._tfo_intent(legacy) is True; ok("老装(无 PDG_TFO, 出口都带标志)→ 回退推断为开")
    empty = {"outbounds": [{"type": "direct", "tag": "jp"}], "route": {}}
    assert bot._tfo_intent(empty) is False; ok("老装无代理出口 → 关闭")

    # profile.env upsert 不破坏其它键
    bot.PROFILE_ENV = os.path.join(tmp, "p3.env")
    bot._profile_set("PDG_LOWMEM", "1"); bot._profile_set("PDG_TFO", "1"); bot._profile_set("PDG_LOWMEM", "0")
    assert bot._profile_get("PDG_LOWMEM") == "0" and bot._profile_get("PDG_TFO") == "1"
    ok("profile.env upsert 保留其它键(PDG_LOWMEM 与 PDG_TFO 共存)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

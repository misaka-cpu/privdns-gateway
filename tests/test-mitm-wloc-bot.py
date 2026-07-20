#!/usr/bin/env python3
"""WLOC bot 后端回归: set_wloc 配置/开关/平台门控/接管域名同源(打桩, 不起真服务)。
全链路(pdg-mitm+mosdns+mihomo+WLOC 改写)由 .200 真机集成测试覆盖。"""
import importlib.util as u
import json
import os
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = u.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = u.module_from_spec(spec); spec.loader.exec_module(bot)

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def main():
    tmp = tempfile.mkdtemp()
    bot.MITM_CONFIG = os.path.join(tmp, "mitm.json")
    bot.MITM_HIJACK_FILE = os.path.join(tmp, "mitm_hijack.txt")
    bot.apply_sb = lambda mod: (True, "")                 # 不起真核心
    bot.sh = lambda cmd: types.SimpleNamespace(returncode=0, stdout="", stderr="")
    bot._mitm_ca_pem = lambda: ""                          # 跳过 CA 生成

    # ── 安卓平台: 拒绝 ──
    bot._platform = lambda: "android"
    okr, msg = bot.set_wloc(True)
    assert okr is False and "仅 iOS" in msg; ok("安卓平台 set_wloc 被拒")

    # ── iOS: 开启需先有坐标 ──
    bot._platform = lambda: "ios"
    okr, msg = bot.set_wloc(True)
    assert okr is False and "坐标" in msg; ok("iOS 无坐标开启 → 提示先设坐标")

    # ── 设坐标 + 开启 ──
    okr, msg = bot.set_wloc(True, lat=35.6812, lon=139.7671)
    assert okr is True, msg
    cfg = json.load(open(bot.MITM_CONFIG))
    assert cfg["wloc"]["enabled"] is True and cfg["wloc"]["lat"] == 35.6812 and cfg["wloc"]["lon"] == 139.7671
    ok("开启 WLOC: mitm.json 写入坐标+enabled")
    assert open(bot.MITM_HIJACK_FILE).read().strip() == "domain:gs-loc.apple.com"
    ok("接管域名写入 mitm_hijack.txt(gs-loc.apple.com)")
    assert bot._mitm_enabled_domains() == ["gs-loc.apple.com"]; ok("_mitm_enabled_domains 与 mihomo 路由同源")

    # ── _mitm_domains 仅 iOS 生效(渲染器读它)──
    assert bot._mitm_domains() == ["gs-loc.apple.com"]; ok("_mitm_domains(iOS) 返回接管域名")
    bot._platform = lambda: "android"
    assert bot._mitm_domains() == []; ok("_mitm_domains(android) 为空(不接管)")
    bot._platform = lambda: "ios"

    # ── 关闭: 清接管域名 ──
    okr, msg = bot.set_wloc(False)
    assert okr is True
    assert json.load(open(bot.MITM_CONFIG))["wloc"]["enabled"] is False
    assert open(bot.MITM_HIJACK_FILE).read().strip() == "" and bot._mitm_enabled_domains() == []
    ok("关闭 WLOC: enabled=False + 清空接管域名")

    # ── set_wloc 保留坐标(关了再开不用重设)──
    okr, _ = bot.set_wloc(True)
    assert okr is True and json.load(open(bot.MITM_CONFIG))["wloc"]["lat"] == 35.6812
    ok("坐标持久化(关→开无需重设)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

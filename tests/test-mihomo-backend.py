#!/usr/bin/env python3
"""bot 内核后端切换层回归(pdg-bot.py 的 mihomo 分支)。

不起真核心/真 systemd: 把 sh/_svc_active/路径常量打桩, 验证:
  - _core_backend 标记识别 + 默认 singbox
  - _panel_render_args 把 clash_api 面板状态透传给渲染器
  - _render_mihomo_file 从 model 渲染 mihomo 配置落盘(chmod 600)
  - _core_apply 三态: 成功 / 校验失败(未重启) / 重启失败(已重启)
  - apply_sb 事务: mihomo 模式下成功写入; 校验失败还原 model 且不残留坏渲染、不误重启
"""
import importlib.util
import json
import os
import stat
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))    # 供 pdg-bot 内部 `import sb2mihomo`
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

SAMPLE = {
    "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
    "outbounds": [
        {"type": "shadowsocks", "tag": "ss1", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "pw"},
        {"type": "direct", "tag": "jp"},
    ],
    "route": {"rules": [{"ip_cidr": ["127.0.0.0/8"], "action": "reject"}], "final": "jp"},
}

pass_n = 0


def ok(msg):
    global pass_n
    print("[OK]  ", msg); pass_n += 1


class FakeSh:
    """记录命令; mihomo -t / sing-box check 返回码可控; 其它一律 rc0。"""
    def __init__(self):
        self.calls = []
        self.mihomo_t_rc = 0
        self.mihomo_t_err = "boom"
        self.sbcheck_rc = 0

    def __call__(self, cmd):
        self.calls.append(list(cmd))
        rc, out, err = 0, "", ""
        if cmd and cmd[0] == "mihomo" and "-t" in cmd:
            rc, err = self.mihomo_t_rc, (self.mihomo_t_err if self.mihomo_t_rc else "")
        elif cmd[:2] == ["sing-box", "check"]:
            rc, err = self.sbcheck_rc, ("bad" if self.sbcheck_rc else "")
        return types.SimpleNamespace(returncode=rc, stdout=out, stderr=err)

    def has(self, prefix):
        return any(c[:len(prefix)] == prefix for c in self.calls)


def setup(tmp, backend="mihomo", svc_active=True):
    bot.SB = os.path.join(tmp, "config.json")
    bot.MIHOMO_DIR = os.path.join(tmp, "mihomo")
    bot.MIHOMO_CFG = os.path.join(bot.MIHOMO_DIR, "config.yaml")
    bot.BACKEND_MARKER = os.path.join(tmp, "backend")
    bot.LOCKFILE = os.path.join(tmp, "lock")
    with open(bot.SB, "w") as f:
        json.dump(SAMPLE, f)
    with open(bot.BACKEND_MARKER, "w") as f:
        f.write(backend)
    fake = FakeSh()
    bot.sh = fake
    bot._svc_active = lambda unit, **k: svc_active
    return fake


def main():
    # ── _core_backend ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp, backend="mihomo")
        assert bot._core_backend() == "mihomo"; ok("_core_backend 识别 mihomo")
        with open(bot.BACKEND_MARKER, "w") as f:
            f.write("singbox")
        assert bot._core_backend() == "singbox"; ok("_core_backend 识别 singbox")
        os.remove(bot.BACKEND_MARKER)
        assert bot._core_backend() == "singbox"; ok("_core_backend 缺标记默认 singbox")
        with open(bot.BACKEND_MARKER, "w") as f:
            f.write("garbage")
        assert bot._core_backend() == "singbox"; ok("_core_backend 非法值默认 singbox")

    # ── _panel_render_args ──
    args = bot._panel_render_args({"experimental": {"clash_api": {
        "external_controller": "0.0.0.0:9090", "secret": "S",
        "external_ui": "/etc/sing-box/ui/dist", "external_ui_download_url": "https://x/z.zip"}}})
    assert args == {"controller": "0.0.0.0:9090", "secret": "S",
                    "external_ui": "/etc/sing-box/ui/dist", "external_ui_url": "https://x/z.zip"}
    ok("_panel_render_args 透传面板 clash_api")
    args0 = bot._panel_render_args({})
    assert args0["controller"] == "127.0.0.1:9090" and args0["secret"] is None
    ok("_panel_render_args 缺省本地控制器/无 secret")

    # ── _render_mihomo_file: 落盘 + 内容 + 权限 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        meta = bot._render_mihomo_file()
        cfg = json.load(open(bot.MIHOMO_CFG))
        assert cfg["redir-port"] == 7893
        assert any(p["name"] == "ss1" and p["type"] == "ss" for p in cfg["proxies"])
        assert cfg["rules"][-1] == "MATCH,DIRECT"
        assert "IP-CIDR,127.0.0.0/8,REJECT,no-resolve" in cfg["rules"]
        mode = stat.S_IMODE(os.stat(bot.MIHOMO_CFG).st_mode)
        assert mode == 0o600, oct(mode)
        assert meta["unknown_proxies"] == []
        ok("_render_mihomo_file 渲染落盘 + chmod 600")

    # ── _core_apply: 成功 ──
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, svc_active=True)
        ret = bot._core_apply()
        assert ret == (True, "", True), ret
        assert fake.has(["mihomo", "-t"]) and fake.has(["systemctl", "restart", "mihomo"])
        ok("_core_apply mihomo 成功 → (True,'',True) 且校验+重启 mihomo")

    # ── _core_apply: 校验失败(核心未重启) ──
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, svc_active=True)
        fake.mihomo_t_rc = 1
        okr, err, restarted = bot._core_apply()
        assert okr is False and restarted is False and "校验失败" in err
        assert not fake.has(["systemctl", "restart", "mihomo"]), "校验失败不该重启核心"
        ok("_core_apply mihomo 校验失败 → 未重启")

    # ── _core_apply: 重启失败(已重启) ──
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, svc_active=False)     # 重启后 svc 起不来
        okr, err, restarted = bot._core_apply()
        assert okr is False and restarted is True and "重启 mihomo 失败" in err
        ok("_core_apply mihomo 重启失败 → restarted=True")

    # ── apply_sb: mihomo 成功写入 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp, svc_active=True)
        okr, msg = bot.apply_sb(lambda cc: cc["route"]["rules"].insert(
            0, {"domain_suffix": ["openai.com"], "outbound": "ss1"}))
        assert okr is True, msg
        model = json.load(open(bot.SB))
        assert any("openai.com" in r.get("domain_suffix", []) for r in model["route"]["rules"])
        cfg = json.load(open(bot.MIHOMO_CFG))
        assert "DOMAIN-SUFFIX,openai.com,ss1" in cfg["rules"]
        ok("apply_sb mihomo 成功: model 改动 + mihomo 配置同步")

    # ── apply_sb: 校验失败回滚(model 还原, 不留坏渲染, 不误重启) ──
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, svc_active=True)
        before = json.load(open(bot.SB))
        bot._render_mihomo_file()               # 先有一份 good 渲染
        fake.calls.clear(); fake.mihomo_t_rc = 1
        okr, msg = bot.apply_sb(lambda cc: cc["route"]["rules"].insert(
            0, {"domain_suffix": ["bad.example"], "outbound": "ss1"}))
        assert okr is False and "校验失败" in msg
        after = json.load(open(bot.SB))
        assert after == before, "校验失败必须把 model 还原"
        cfg = json.load(open(bot.MIHOMO_CFG))
        assert not any("bad.example" in r for r in cfg["rules"]), "回滚后不该残留坏渲染"
        assert not fake.has(["systemctl", "restart", "mihomo"]), "校验失败不该重启核心"
        ok("apply_sb mihomo 校验失败: model 还原 + 渲染同步回 good + 未重启")

    # ── 向后兼容: sing-box 分支不受重构影响 ──
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, backend="singbox", svc_active=True)
        ret = bot._core_apply()
        assert ret == (True, "", True), ret
        assert fake.has(["sing-box", "check", "-c", bot.SB])
        assert fake.has(["systemctl", "restart", "sing-box"])
        assert not fake.has(["mihomo", "-t"]), "singbox 模式不该碰 mihomo"
        assert not os.path.exists(bot.MIHOMO_CFG), "singbox 模式不该渲染 mihomo 配置"
        ok("_core_apply singbox 成功 → 校验+重启 sing-box, 不渲染 mihomo")
    with tempfile.TemporaryDirectory() as tmp:
        fake = setup(tmp, backend="singbox", svc_active=True)
        fake.sbcheck_rc = 1
        okr, err, restarted = bot._core_apply()
        assert okr is False and restarted is False and "校验失败" in err
        assert not fake.has(["systemctl", "restart", "sing-box"]), "校验失败不该重启"
        ok("_core_apply singbox 校验失败 → 未重启")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""面板表校验(门二)与反代生成的测试。

同样的纪律: **每条判据配空测**。生成器这边尤其要紧 —— 那些改写指令(Location / Referer /
TLS transport)只在面板显式要求时才该出现, 一个"总是全都加上"的实现能让所有正面用例通过,
而它在真机上的后果是给不需要改写的设备也改了头, 症状隐蔽得多。
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "deploy/bot/lanpanel.py"

spec = importlib.util.spec_from_file_location("lanpanel", MOD)
lp = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(lp)


def cfg(*panels):
    return {"panels": list(panels)}


def P(**kw):
    base = {"name": "nas", "host": "nas.home.example.com",
            "target": "https://192.168.1.50", "insecure_upstream": True}
    base.update(kw)
    return base


# ── ① 合法表通过 ─────────────────────────────────────────────────────────────
assert lp.validate(cfg(P())) == []
assert lp.validate(cfg(P(), P(name="router", host="r.home.example.com",
                             target="https://192.168.1.1:8443"))) == []
# http 上游不需要 insecure_upstream(没有证书可校验)
assert lp.validate(cfg(P(target="http://192.168.1.7", insecure_upstream=None))) == []

# ── ② 通配 host —— 门二的核心 ────────────────────────────────────────────────
e = lp.validate(cfg(P(host="*.home.example.com")))
assert e and "通配" in e[0], e
# 空测: 普通域名不该被当成通配
assert lp.validate(cfg(P(host="a.b.c.home.example.com"))) == []

# ── ③ 上游必须是字面 IP ──────────────────────────────────────────────────────
e = lp.validate(cfg(P(target="https://nas.lan")))
assert e and "字面 IP" in e[0], e
# 空测: 字面 IP 放行, IPv6 也放行
assert lp.validate(cfg(P(target="https://192.168.1.50"))) == []
assert lp.validate(cfg(P(target="https://[fd00::1]:8443"))) == []
# 环回上游指向网关自己, 拒
e = lp.validate(cfg(P(target="https://127.0.0.1:8443")))
assert e and "环回" in e[0], e

# ── ④ https 上游必须显式表态 ────────────────────────────────────────────────
e = lp.validate(cfg(P(insecure_upstream=None)))
assert e and "insecure_upstream" in e[0], e
# 空测: 显式写 false 也算表过态
assert lp.validate(cfg(P(insecure_upstream=False))) == []

# ── ⑤ 重复 ───────────────────────────────────────────────────────────────────
e = lp.validate(cfg(P(), P(host="other.home.example.com")))          # name 重复
assert any("name" in x and "重复" in x for x in e), e
e = lp.validate(cfg(P(), P(name="two")))                             # host 重复
assert any("host" in x and "重复" in x for x in e), e

# ── ⑥ 认不出的字段不能静默忽略 ──────────────────────────────────────────────
e = lp.validate(cfg(P(insecure_upstrem=True)))     # 故意拼错
assert any("认不出" in x for x in e), e

# ── ⑦ 派生出站白名单 ────────────────────────────────────────────────────────
t = lp.targets(cfg(P(), P(name="r", host="r.home.example.com", target="http://192.168.1.1:8443")))
assert t == [("192.168.1.50", 443), ("192.168.1.1", 8443)], t
# 省略端口时按 scheme 取默认值 —— 防火墙要的是具体端口
assert lp.targets(cfg(P(target="http://10.0.0.9"))) == [("10.0.0.9", 80)]

# ── ⑧ 生成: 改写指令只在被要求时出现(这是本文件最要紧的一组空测) ────────────
plain = lp.render_caddy(cfg(P()), "/c")
assert "header_down Location" not in plain, "没要求就不该改 Location"
assert "header_up Referer" not in plain, "没要求就不该改 Referer"
assert "redir" not in plain, "没要求就不该注入跳转"

loc = lp.render_caddy(cfg(P(rewrite_location=True)), "/c")
assert "header_down Location" in loc
assert "header_up Referer" not in loc, "只要了 Location, 不该顺手改 Referer"

ref = lp.render_caddy(cfg(P(fix_referer=True)), "/c")
assert "header_up Referer" in ref and "header_up Origin" in ref
assert "header_down Location" not in ref

q = lp.render_caddy(cfg(P(entry_query="magicpath=abc123")), "/c")
assert "redir @bare /?magicpath=abc123 302" in q

# ── ⑨ 生成: 上游协议决定 transport ──────────────────────────────────────────
https = lp.render_caddy(cfg(P()), "/c")
assert "tls_insecure_skip_verify" in https
http = lp.render_caddy(cfg(P(target="http://192.168.1.7", insecure_upstream=None)), "/c")
assert "transport http" not in http, "http 上游不该生成 tls transport"
assert "tls_insecure_skip_verify" not in http
strict = lp.render_caddy(cfg(P(insecure_upstream=False)), "/c")
assert "transport http" in strict and "tls_insecure_skip_verify" not in strict, \
    "显式 false 时要用 tls 但不跳过校验"

# ── ⑩ 生成前先校验, 不合法就拒绝落盘 ────────────────────────────────────────
try:
    lp.render_caddy(cfg(P(host="*.evil.example.com")), "/c")
    raise AssertionError("通配的表不该能生成出配置")
except lp.PanelError as ex:
    assert "通配" in str(ex), ex

# ── ⑪ 老 TLS 套件的面板单独列出(要给 unit 加 GODEBUG, Caddyfile 管不了) ─────
assert lp.legacy_tls_panels(cfg(P(legacy_tls=True))) == ["nas"]
assert lp.legacy_tls_panels(cfg(P())) == []

# ── ⑫ 生成的配置里每个面板都要 bind 到指定地址 ──────────────────────────────
two = lp.render_caddy(cfg(P(), P(name="r", host="r.home.example.com",
                                 target="http://192.168.1.1:8443")), "/c", bind="100.64.1.2")
assert two.count("bind 100.64.1.2") == 2
assert two.count("tls /c/") == 2

# ── ⑬ 命令行契约 ─────────────────────────────────────────────────────────────
def cli(*args, table=None):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(table if table is not None else cfg(P()), f)
        path = f.name
    p = subprocess.run([sys.executable, str(MOD), args[0], path] + list(args[1:]),
                       capture_output=True, text=True)
    return p.returncode, p.stdout


rc, out = cli("check")
assert rc == 0 and out.strip() == "", (rc, out)

rc, out = cli("check", table=cfg(P(host="*.x.example.com")))
assert rc == 2 and "通配" in out, (rc, out)

rc, out = cli("targets")
assert rc == 0 and out.strip() == "192.168.1.50\t443", (rc, out)

rc, out = cli("render", "--certs", "/etc/pdg/lan-certs")
assert rc == 0 and "reverse_proxy https://192.168.1.50:443" in out, (rc, out)

rc, out = cli("render")           # 缺 --certs
assert rc == 3, (rc, out)

rc, out = cli("render", "--certs", "/c", table=cfg(P(target="https://nas.lan")))
assert rc == 2 and "字面 IP" in out, (rc, out)

print("test-lanpanel.py: OK")

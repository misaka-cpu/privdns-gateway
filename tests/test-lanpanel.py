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

# ── ⑭ 门三: 出站白名单的**结构**(真 nft 的行为验证要 NET_ADMIN, CI 给不了 ──────
#     见 tests/negctl/lan-egress-live.sh, 那是本地门)
def nft(cfg_, uid="pdg-lan"):
    return lp.render_nft(cfg_, uid)


rules = nft(cfg(P(), P(name="ups", host="ups.home.example.com",
                       target="http://192.168.1.9:8080")))
lines = [l.strip() for l in rules.splitlines() if l.strip() and not l.strip().startswith("#")]

# uid 判据必须**排在白名单之前**。排在后面的话白名单对所有进程生效 —— 那正好把
# "按 uid 过滤"这条设计取消掉, 而规则看起来一条不少。
i_uid = next(n for n, l in enumerate(lines) if "skuid" in l)
i_first_allow = next(n for n, l in enumerate(lines) if "daddr" in l)
assert i_uid < i_first_allow, (i_uid, i_first_allow)

# reject 必须是链里最后一条 —— 后面还有规则的话它们永远走不到
i_reject = next(n for n, l in enumerate(lines) if l.startswith("reject"))
assert all("daddr" not in l for l in lines[i_reject:]), lines[i_reject:]

# 白名单逐条对上面板表, 不多不少
assert rules.count("ip daddr 192.168.1.50 tcp dport 443 accept") == 1
assert rules.count("ip daddr 192.168.1.9 tcp dport 8080 accept") == 1
assert "192.168.1.1" not in rules, "表里没有的地址不该出现在规则里"

# 环回响应要放行, 否则反代回不了包
assert "oif lo accept" in rules

# IPv6 用 ip6 daddr
v6 = nft(cfg(P(target="https://[fd00::5]:8443")))
assert "ip6 daddr fd00::5 tcp dport 8443 accept" in v6, v6

# **空表必须是"什么都不许连", 不能是"随便连"**。一份没有面板的配置最容易被当成
# "还没配, 先放开" —— 那会让反代在配置好之前拥有整个内网的可达性。
empty = nft(cfg())
assert "daddr" not in empty and "reject with icmpx admin-prohibited" in empty, empty

# uid 形态不合法就拒绝生成(拼错的用户名会让 nft 加载失败 —— 而那是 fail-open 的)
for bad_uid in ("", "Root", "a b", "x" * 40, 1000):
    try:
        nft(cfg(P()), bad_uid)
        raise AssertionError("uid %r 不该被接受" % (bad_uid,))
    except lp.PanelError:
        pass

# 面板表不合法时连规则也不生成 —— 否则会派生出一份"按半张表放行"的白名单
try:
    nft(cfg(P(target="https://nas.lan")))
    raise AssertionError("不合法的表不该派生出防火墙规则")
except lp.PanelError:
    pass

# ── ⑮ 候选生成: add / rm 不写盘, 只产出新表 ─────────────────────────────────
base = cfg(P())
c2 = lp.add_panel(base, {"name": "ups", "host": "ups.home.example.com",
                         "target": "http://192.168.1.9:8080"})
assert len(c2["panels"]) == 2
assert len(base["panels"]) == 1, "add_panel 不该改原对象"

# 候选要**整体**过校验, 不只校验新增那条 —— 撞 name/host 只有放在一起看才发现得了
for dup in ({"name": "nas", "host": "x.home.example.com", "target": "http://10.0.0.1"},
            {"name": "other", "host": "nas.home.example.com", "target": "http://10.0.0.1"}):
    try:
        lp.add_panel(base, dup)
        raise AssertionError("重复的 %r 不该加得进去" % dup["name"])
    except lp.PanelError as ex:
        assert "重复" in str(ex), ex

# 删不到要报错, 不能静默成功 —— "删了个不存在的"和"删掉了"事后看起来一模一样
try:
    lp.rm_panel(base, "nope")
    raise AssertionError("删不存在的面板不该成功")
except lp.PanelError as ex:
    assert "没有名叫" in str(ex), ex

c3 = lp.rm_panel(c2, "nas")
assert [p["name"] for p in c3["panels"]] == ["ups"]
assert len(c2["panels"]) == 2, "rm_panel 不该改原对象"

# 落盘文本要稳定 —— 事务比对 before/after, 格式抖动会让"没改内容"看起来像改过
assert lp.dumps(base) == lp.dumps(json.loads(lp.dumps(base)))

# 命令行 add: 生成候选到 stdout, 原文件一个字节都不动
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
    json.dump(base, f)
    tpath = f.name
before = open(tpath, encoding="utf-8").read()
p_ = subprocess.run([sys.executable, str(MOD), "add", tpath, "--name", "ups",
                     "--host", "ups.home.example.com", "--target", "http://192.168.1.9:8080"],
                    capture_output=True, text=True)
assert p_.returncode == 0, p_.stdout + p_.stderr
assert len(json.loads(p_.stdout)["panels"]) == 2
assert open(tpath, encoding="utf-8").read() == before, "add 不该写原文件"

# https 上游没表态 → 拒绝, 且原文件仍不动
p_ = subprocess.run([sys.executable, str(MOD), "add", tpath, "--name", "z",
                     "--host", "z.home.example.com", "--target", "https://192.168.1.11"],
                    capture_output=True, text=True)
assert p_.returncode == 2 and "insecure_upstream" in p_.stdout, p_.stdout
assert open(tpath, encoding="utf-8").read() == before

# --no-insecure 是表过态的
p_ = subprocess.run([sys.executable, str(MOD), "add", tpath, "--name", "z",
                     "--host", "z.home.example.com", "--target", "https://192.168.1.11",
                     "--no-insecure"], capture_output=True, text=True)
assert p_.returncode == 0, p_.stdout

# ── ⑯ 风险②: DNS token 的爆炸半径(面板域名与 DoT 域名同 zone = 权限升级) ─────
assert lp.shared_zone("nas.home.example.com", "dot.example.com") == "example.com"
assert lp.shared_zone("nas.lan.mydom.io", "dot.mydom.io") == "mydom.io"
# 空测: 不同注册域不该报
assert lp.shared_zone("nas.home.example.com", "dot.other.net") is None
assert lp.shared_zone("a.example.com", "b.example.org") is None
# 只共有 TLD 不算 —— 否则所有 .com 域名两两之间都会报, 这条判据立刻变成噪音
assert lp.shared_zone("a.com", "b.com") is None
assert lp.shared_zone("x.co.uk", "y.co.uk") == "co.uk"    # 宁可多报: co.uk 会命中
# 大小写与末尾点不影响判定(DNS 里它们是同一个名字)
assert lp.shared_zone("NAS.Home.Example.COM", "dot.example.com.") == "example.com"

r = lp.zone_risk(cfg(P(host="nas.home.example.com"),
                     P(name="b", host="b.elsewhere.net", target="http://10.0.0.2")),
                 "dot.example.com")
assert r == [("nas.home.example.com", "example.com")], r
# 空测: 没配 DoT 域名时不报(判据没有输入, 不能凭空成立)
assert lp.zone_risk(cfg(P()), "") == []
assert lp.zone_risk(cfg(P()), None) == []
# 空测: DoT 在别的注册域时不报
assert lp.zone_risk(cfg(P(host="nas.home.example.com")), "dot.other.net") == []

print("test-lanpanel.py: OK")

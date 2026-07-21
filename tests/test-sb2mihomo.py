#!/usr/bin/env python3
"""sb2mihomo 渲染层回归: sing-box 出站/路由 → mihomo 各字段映射正确。

只做纯函数级断言(不起 mihomo)。真 schema 校验由 .200 上的 `mihomo -t` 覆盖,
此处保证"翻译逻辑"稳定: 协议字段、tls/reality/transport、url-test 组、rules、
final、direct→DIRECT、rule_set 归属与丢弃报告。JSON 即合法 YAML 也一并断言。
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy" / "bot"))
import sb2mihomo  # noqa: E402

SB = {
    "outbounds": [
        {"type": "shadowsocks", "tag": "ss1", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "sp", "tcp_fast_open": True},
        {"type": "vmess", "tag": "vm1", "server": "2.2.2.2", "server_port": 443,
         "uuid": "u-vm", "alter_id": 0, "security": "auto",
         "tls": {"enabled": True, "server_name": "cdn.a"},
         "transport": {"type": "ws", "path": "/w", "headers": {"Host": "cdn.a"}}},
        {"type": "trojan", "tag": "tj1", "server": "3.3.3.3", "server_port": 443,
         "password": "tp", "tls": {"enabled": True, "server_name": "tj.a", "insecure": True},
         "transport": {"type": "grpc", "service_name": "svc"}},
        {"type": "vless", "tag": "vl1", "server": "4.4.4.4", "server_port": 443,
         "uuid": "u-vl", "flow": "xtls-rprx-vision",
         "tls": {"enabled": True, "server_name": "ms.a",
                 "reality": {"enabled": True, "public_key": "PK", "short_id": "sid"},
                 "utls": {"enabled": True, "fingerprint": "chrome"}}},
        {"type": "hysteria2", "tag": "hy1", "server": "5.5.5.5", "server_port": 443,
         "password": "hp", "tls": {"enabled": True, "server_name": "hy.a", "alpn": ["h3"]},
         "obfs": {"type": "salamander", "password": "op"}},
        {"type": "tuic", "tag": "tu1", "server": "6.6.6.6", "server_port": 443,
         "uuid": "u-tu", "password": "tup", "congestion_control": "bbr", "udp_relay_mode": "native",
         "tls": {"enabled": True, "server_name": "tu.a", "alpn": ["h3"]}},
        {"type": "anytls", "tag": "at1", "server": "7.7.7.7", "server_port": 443,
         "password": "ap", "tls": {"enabled": True, "server_name": "at.a"}},
        {"type": "socks", "tag": "sk1", "server": "8.8.8.8", "server_port": 1080,
         "version": "5", "username": "us", "password": "pw"},
        {"type": "http", "tag": "ht1", "server": "9.9.9.9", "server_port": 8443,
         "username": "hu", "password": "hpw", "tls": {"enabled": True, "server_name": "ht.a"}},
        {"type": "urltest", "tag": "grp", "outbounds": ["ss1", "vm1", "jp"],
         "url": "https://x/generate_204", "interval": "3m", "tolerance": 50},
        {"type": "direct", "tag": "jp"},
    ],
    "route": {
        "rules": [
            {"ip_cidr": ["203.0.113.1/32", "127.0.0.0/8"], "action": "reject"},
            {"domain_suffix": ["openai.com", "chatgpt.com"], "outbound": "vl1"},
            {"domain_suffix": ["youtube.com"], "outbound": "grp"},
            {"domain": ["exact.example"], "outbound": "jp"},
            {"domain_keyword": ["porn"], "outbound": "at1"},
            {"rule_set": "geosite-netflix", "outbound": "hy1"},
        ],
        "final": "jp",
    },
}


def P(cfg, name):
    return next(p for p in cfg["proxies"] if p["name"] == name)


def main():
    cfg, meta = sb2mihomo.singbox_to_mihomo(SB, redir_port=7893)

    # ── 入站/嗅探 ──
    assert cfg["redir-port"] == 7893
    assert cfg["sniffer"]["enable"] is True
    assert cfg["sniffer"]["override-destination"] is True
    assert 443 in cfg["sniffer"]["sniff"]["TLS"]["ports"]
    assert 5228 in cfg["sniffer"]["sniff"]["TLS"]["ports"]
    assert 80 in cfg["sniffer"]["sniff"]["HTTP"]["ports"]

    # ── shadowsocks: method→cipher, tfo ──
    ss = P(cfg, "ss1")
    assert ss["type"] == "ss" and ss["cipher"] == "aes-256-gcm" and ss["password"] == "sp"
    assert ss["udp"] is True and ss["tfo"] is True

    # ── vmess: alterId/cipher + tls servername + ws-opts ──
    vm = P(cfg, "vm1")
    assert vm["type"] == "vmess" and vm["uuid"] == "u-vm" and vm["alterId"] == 0 and vm["cipher"] == "auto"
    assert vm["tls"] is True and vm["servername"] == "cdn.a"
    assert vm["network"] == "ws" and vm["ws-opts"]["path"] == "/w"
    assert vm["ws-opts"]["headers"]["Host"] == "cdn.a"

    # ── trojan: sni + skip-cert-verify + grpc-opts ──
    tj = P(cfg, "tj1")
    assert tj["type"] == "trojan" and tj["sni"] == "tj.a" and tj["skip-cert-verify"] is True
    assert tj["network"] == "grpc" and tj["grpc-opts"]["grpc-service-name"] == "svc"

    # ── vless: flow + reality-opts + client-fingerprint ──
    vl = P(cfg, "vl1")
    assert vl["type"] == "vless" and vl["flow"] == "xtls-rprx-vision" and vl["tls"] is True
    assert vl["servername"] == "ms.a"
    assert vl["reality-opts"] == {"public-key": "PK", "short-id": "sid"}
    assert vl["client-fingerprint"] == "chrome"

    # ── hysteria2: obfs + obfs-password + alpn ──
    hy = P(cfg, "hy1")
    assert hy["type"] == "hysteria2" and hy["password"] == "hp" and hy["sni"] == "hy.a"
    assert hy["obfs"] == "salamander" and hy["obfs-password"] == "op" and hy["alpn"] == ["h3"]

    # ── tuic: congestion-controller / udp-relay-mode / alpn ──
    tu = P(cfg, "tu1")
    assert tu["type"] == "tuic" and tu["uuid"] == "u-tu" and tu["password"] == "tup"
    assert tu["congestion-controller"] == "bbr" and tu["udp-relay-mode"] == "native" and tu["alpn"] == ["h3"]

    # ── anytls ──
    at = P(cfg, "at1")
    assert at["type"] == "anytls" and at["password"] == "ap" and at["sni"] == "at.a"

    # ── socks5 / http ──
    sk = P(cfg, "sk1")
    assert sk["type"] == "socks5" and sk["username"] == "us" and sk["password"] == "pw"
    ht = P(cfg, "ht1")
    assert ht["type"] == "http" and ht["tls"] is True and ht["sni"] == "ht.a"
    assert ht["username"] == "hu" and ht["password"] == "hpw"

    # ── direct 出口不进 proxies(内建 DIRECT) ──
    assert all(p["name"] != "jp" for p in cfg["proxies"]), "direct 出口不应出现在 proxies"

    # ── url-test 组: jp→DIRECT, interval 秒 ──
    grp = next(g for g in cfg["proxy-groups"] if g["name"] == "grp")
    assert grp["type"] == "url-test" and grp["proxies"] == ["ss1", "vm1", "DIRECT"]
    assert grp["interval"] == 180 and grp["tolerance"] == 50

    # ── rules: reject→IP-CIDR no-resolve, 各类域名, final→MATCH,DIRECT ──
    rules = cfg["rules"]
    assert "IP-CIDR,203.0.113.1/32,REJECT,no-resolve" in rules
    assert "IP-CIDR,127.0.0.0/8,REJECT,no-resolve" in rules
    assert "DOMAIN-SUFFIX,openai.com,vl1" in rules
    assert "DOMAIN-SUFFIX,chatgpt.com,vl1" in rules
    assert "DOMAIN-SUFFIX,youtube.com,grp" in rules
    assert "DOMAIN,exact.example,DIRECT" in rules            # outbound jp → DIRECT
    assert "DOMAIN-KEYWORD,porn,at1" in rules
    assert rules[-1] == "MATCH,DIRECT"                        # final=jp → DIRECT, 且在最后
    # IP-CIDR 反自环必须在具体域名规则之前
    assert rules.index("IP-CIDR,203.0.113.1/32,REJECT,no-resolve") < rules.index("DOMAIN-SUFFIX,openai.com,vl1")

    # ── 无 rulesets 时 rule_set 被丢弃并报告(不静默) ──
    assert not any("netflix" in r for r in rules), "无 rule-providers 时不应产出 RULE-SET"
    assert {"rule_set": "geosite-netflix", "outbound": "hy1"} in meta["dropped"]
    assert meta["unknown_proxies"] == []

    # ── 提供 rulesets 时正确产出 rule-providers + RULE-SET ──
    cfg2, meta2 = sb2mihomo.singbox_to_mihomo(
        SB, rulesets={"geosite-netflix": {"url": "https://x/netflix.txt", "behavior": "domain"}})
    assert "RULE-SET,geosite-netflix,hy1" in cfg2["rules"]
    assert "geosite-netflix" in cfg2["rule-providers"]
    assert cfg2["rule-providers"]["geosite-netflix"]["url"] == "https://x/netflix.txt"
    assert all(d.get("rule_set") != "geosite-netflix" for d in meta2["dropped"])

    # ── panel: secret / external-ui 透传 ──
    cfg3, _ = sb2mihomo.singbox_to_mihomo(SB, secret="S3", external_ui="/etc/mihomo/ui",
                                          external_ui_url="https://x/ui.zip")
    assert cfg3["secret"] == "S3" and cfg3["external-ui"] == "/etc/mihomo/ui"
    assert cfg3["external-ui-url"] == "https://x/ui.zip"

    # ── mixed 入站(TG 代理 :8445)→ mihomo listeners + IN-NAME 路由(pin 到出口/final)──
    sb_tg = {**SB,
             "inbounds": [{"type": "direct", "tag": "in-https", "listen_port": 443},
                          {"type": "mixed", "tag": "tg-proxy", "listen": "0.0.0.0", "listen_port": 8445}],
             "route": {**SB["route"], "rules": SB["route"]["rules"] + [{"inbound": ["tg-proxy"], "outbound": "vm1"}]}}
    cfg4, _ = sb2mihomo.singbox_to_mihomo(sb_tg)
    assert cfg4["listeners"] == [{"name": "tg-proxy", "type": "mixed", "port": 8445, "listen": "0.0.0.0"}]
    assert "IN-NAME,tg-proxy,vm1" in cfg4["rules"]                    # pin 到 route 里的出口
    assert all(l["name"] != "in-https" for l in cfg4["listeners"])    # direct 入站不渲染成 listener(靠 nft REDIRECT)
    sb_tg2 = {**SB, "inbounds": [{"type": "mixed", "tag": "tg-proxy", "listen_port": 8445}]}
    assert "IN-NAME,tg-proxy,DIRECT" in sb2mihomo.singbox_to_mihomo(sb_tg2)[0]["rules"]   # 无 inbound 规则 → 跟 final(jp=direct)

    # ── JSON 即合法 YAML: 必须能 json.dumps(mihomo 只吃 YAML, JSON 是其子集) ──
    json.dumps(cfg)

    print("[OK] sb2mihomo 渲染层全部断言通过")


if __name__ == "__main__":
    main()

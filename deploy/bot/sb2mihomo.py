#!/usr/bin/env python3
"""sing-box 配置 → mihomo(clash.meta)配置 的后端渲染层。

原型阶段的核心:privdns-gateway 的数据模型(出口/规则/故障组)全部沿用 bot 现有的
sing-box 出站 dict 与 route.rules 结构,这里只做"翻译成 mihomo"这一件事。

关键映射:
  入站:  sing-box direct(sniff+override)  → mihomo redir-port(靠 nft REDIRECT 送入) + sniffer.override-destination
  出站:  sing-box outbounds[proxy]         → mihomo proxies[]
         sing-box outbounds[urltest]       → mihomo proxy-groups[url-test]
         sing-box outbounds[direct] "jp"   → mihomo 内建 DIRECT
  路由:  route.rules[{ip_cidr,reject}]     → IP-CIDR,...,REJECT,no-resolve(反自环)
         route.rules[{domain_suffix,out}]  → DOMAIN-SUFFIX,...,<target>
         route.rules[{domain,out}]         → DOMAIN,...,<target>
         route.rules[{domain_keyword,out}] → DOMAIN-KEYWORD,...,<target>
         route.rules[{rule_set,out}]       → RULE-SET,<name>,<target>(需 rule-providers, 见 rulesets 参数)
         route.final                        → MATCH,<target>

mihomo 只吃 YAML;但 YAML 1.2 是 JSON 超集,合法 JSON 即合法 YAML,故直接 json.dumps 即可,
不引入额外 YAML 依赖(已在 .200 用 `mihomo -t` 实测确认可解析)。
"""
from __future__ import annotations
import json

# 可作出口的代理协议(与 pdg-bot.py 的 PROXY_TYPES 对齐)
PROXY_TYPES = ("shadowsocks", "vmess", "trojan", "vless", "hysteria", "hysteria2",
               "tuic", "anytls", "shadowtls", "socks", "http")

# 默认劫持端口 → 嗅探类型(原始 dport, 非 redir 端口)
DEFAULT_TLS_PORTS = [443, 5228, 5229, 5230]
DEFAULT_HTTP_PORTS = [80]


def _tls_common(ob, p):
    """把 sing-box outbound 的 tls 块翻译进 mihomo proxy dict p。"""
    tls = ob.get("tls")
    if not tls or not tls.get("enabled"):
        return
    p["tls"] = True
    if tls.get("server_name"):
        p["servername"] = tls["server_name"]
    if tls.get("insecure"):
        p["skip-cert-verify"] = True
    if tls.get("alpn"):
        p["alpn"] = list(tls["alpn"])
    reality = tls.get("reality")
    if reality and reality.get("enabled"):
        p["reality-opts"] = {"public-key": reality.get("public_key", ""),
                             "short-id": reality.get("short_id", "")}
    utls = tls.get("utls")
    if utls and utls.get("fingerprint"):
        p["client-fingerprint"] = utls["fingerprint"]


def _transport_common(ob, p):
    """sing-box transport(ws/grpc)→ mihomo network + *-opts。"""
    tr = ob.get("transport")
    if not tr:
        return
    t = tr.get("type")
    if t == "ws":
        p["network"] = "ws"
        opts = {"path": tr.get("path", "/")}
        hdrs = tr.get("headers") or {}
        if hdrs:
            opts["headers"] = dict(hdrs)
        p["ws-opts"] = opts
    elif t == "grpc":
        p["network"] = "grpc"
        p["grpc-opts"] = {"grpc-service-name": tr.get("service_name", "")}


def _sni(ob):
    tls = ob.get("tls") or {}
    return tls.get("server_name")


def convert_proxy(ob):
    """单个 sing-box 代理出站 → mihomo proxy dict(不含 direct/urltest)。未知类型返回 None。"""
    typ = ob.get("type")
    name = ob["tag"]
    server = ob.get("server")
    port = ob.get("server_port")
    base = {"name": name, "server": server, "port": port}

    if typ == "shadowsocks":
        return {**base, "type": "ss", "cipher": ob.get("method"), "password": ob.get("password"), "udp": True}
    if typ == "vmess":
        p = {**base, "type": "vmess", "uuid": ob.get("uuid"),
             "alterId": ob.get("alter_id", 0), "cipher": ob.get("security", "auto"), "udp": True}
        _tls_common(ob, p); _transport_common(ob, p)
        return p
    if typ == "trojan":
        p = {**base, "type": "trojan", "password": ob.get("password"), "udp": True}
        sni = _sni(ob)
        if sni:
            p["sni"] = sni
        if (ob.get("tls") or {}).get("insecure"):
            p["skip-cert-verify"] = True
        _transport_common(ob, p)
        return p
    if typ == "vless":
        p = {**base, "type": "vless", "uuid": ob.get("uuid"), "udp": True}
        if ob.get("flow"):
            p["flow"] = ob["flow"]
        _tls_common(ob, p); _transport_common(ob, p)
        return p
    if typ in ("hysteria2", "hysteria"):
        p = {**base, "type": "hysteria2", "password": ob.get("password", ob.get("auth_str", "")), "udp": True}
        sni = _sni(ob)
        if sni:
            p["sni"] = sni
        if (ob.get("tls") or {}).get("insecure"):
            p["skip-cert-verify"] = True
        if (ob.get("tls") or {}).get("alpn"):
            p["alpn"] = list(ob["tls"]["alpn"])
        obfs = ob.get("obfs")
        if obfs:
            p["obfs"] = obfs.get("type")
            if obfs.get("password"):
                p["obfs-password"] = obfs["password"]
        return p
    if typ == "tuic":
        p = {**base, "type": "tuic", "uuid": ob.get("uuid"), "password": ob.get("password"), "udp": True}
        sni = _sni(ob)
        if sni:
            p["sni"] = sni
        if (ob.get("tls") or {}).get("insecure"):
            p["skip-cert-verify"] = True
        if (ob.get("tls") or {}).get("alpn"):
            p["alpn"] = list(ob["tls"]["alpn"])
        if ob.get("congestion_control"):
            p["congestion-controller"] = ob["congestion_control"]
        if ob.get("udp_relay_mode"):
            p["udp-relay-mode"] = ob["udp_relay_mode"]
        return p
    if typ == "anytls":
        p = {**base, "type": "anytls", "password": ob.get("password"), "udp": True}
        sni = _sni(ob)
        if sni:
            p["sni"] = sni
        if (ob.get("tls") or {}).get("insecure"):
            p["skip-cert-verify"] = True
        return p
    if typ == "socks":
        p = {**base, "type": "socks5", "udp": True}
        if ob.get("username"):
            p["username"] = ob["username"]
        if ob.get("password"):
            p["password"] = ob["password"]
        return p
    if typ == "http":
        p = {**base, "type": "http"}
        if ob.get("username"):
            p["username"] = ob["username"]
        if ob.get("password"):
            p["password"] = ob["password"]
        if (ob.get("tls") or {}).get("enabled"):
            p["tls"] = True
            sni = _sni(ob)
            if sni:
                p["sni"] = sni
        return p
    return None


def _direct_tags(sb):
    return {o["tag"] for o in sb.get("outbounds", []) if o.get("type") == "direct"}


def _map_target(tag, direct_tags):
    """出口 tag → mihomo 策略名(direct 出口 → 内建 DIRECT)。"""
    if tag in direct_tags:
        return "DIRECT"
    return tag


def _rules_from_route(sb, direct_tags, rulesets):
    rules = []
    dropped = []
    for r in sb.get("route", {}).get("rules", []):
        action = r.get("action")
        if action == "reject":
            for cidr in r.get("ip_cidr", []):
                rules.append(f"IP-CIDR,{cidr},REJECT,no-resolve")
            continue
        out = r.get("outbound")
        if not out:
            dropped.append(r)
            continue
        target = _map_target(out, direct_tags)
        if r.get("rule_set"):
            name = r["rule_set"]
            if rulesets is not None and name in rulesets:
                rules.append(f"RULE-SET,{name},{target}")
            else:
                dropped.append({"rule_set": name, "outbound": out})
            continue
        for d in r.get("domain_suffix", []):
            rules.append(f"DOMAIN-SUFFIX,{d},{target}")
        for d in r.get("domain", []):
            rules.append(f"DOMAIN,{d},{target}")
        for kw in r.get("domain_keyword", []):
            rules.append(f"DOMAIN-KEYWORD,{kw},{target}")
    final = sb.get("route", {}).get("final")
    rules.append(f"MATCH,{_map_target(final, direct_tags) if final else 'DIRECT'}")
    return rules, dropped


def singbox_to_mihomo(sb, *, redir_port=7893, controller="127.0.0.1:9090",
                      secret=None, external_ui=None, external_ui_url=None,
                      tls_ports=None, http_ports=None, rulesets=None,
                      mitm_domains=None, mitm_port=7894):
    """把 sing-box 配置 dict 翻译成 mihomo 配置 dict。

    rulesets: 可选 {name: {url, behavior, format}} —— 提供则渲染 rule-providers + RULE-SET,
              未提供的 rule_set 规则会被丢弃并记入返回的 dropped(原型阶段先只保证域名规则)。
    返回 (mihomo_config_dict, meta) —— meta.dropped 列出没能翻译的规则(供调用方告警)。
    """
    direct_tags = _direct_tags(sb)
    proxies, unknown = [], []
    # TCP Fast Open: sing-box tcp_fast_open → mihomo tfo, 仅 TCP 类协议(QUIC 的 hy2/tuic 无意义)
    tfo_types = {"ss", "vmess", "trojan", "vless", "http", "socks5", "anytls"}
    for o in sb.get("outbounds", []):
        if o.get("type") in PROXY_TYPES:
            p = convert_proxy(o)
            if p is None:
                unknown.append(o.get("tag"))
            else:
                if o.get("tcp_fast_open") and p.get("type") in tfo_types:
                    p["tfo"] = True
                proxies.append(p)

    groups = []
    for o in sb.get("outbounds", []):
        if o.get("type") == "urltest":
            groups.append({
                "name": o["tag"], "type": "url-test",
                "proxies": [_map_target(m, direct_tags) for m in o.get("outbounds", [])],
                "url": o.get("url", "https://www.gstatic.com/generate_204"),
                "interval": _dur_secs(o.get("interval", "3m")),
                "tolerance": o.get("tolerance", 50),
            })

    rules, dropped = _rules_from_route(sb, direct_tags, rulesets)

    # MITM(Feature B / iOS): 接管域名路由到本地 MITM 服务(socks5 出站, 由它终止 TLS 交插件)。
    # 规则插在开头的 IP-CIDR REJECT(反自环)之后、普通域名规则之前, 优先级最高。
    if mitm_domains:
        proxies.append({"name": "MITM-OUT", "type": "socks5",
                        "server": "127.0.0.1", "port": mitm_port, "udp": False})
        mitm_rules = [f"DOMAIN,{d},MITM-OUT" for d in mitm_domains]
        i = 0
        while i < len(rules) and rules[i].startswith("IP-CIDR") and rules[i].endswith("REJECT,no-resolve"):
            i += 1
        rules = rules[:i] + mitm_rules + rules[i:]

    tls_ports = tls_ports if tls_ports is not None else DEFAULT_TLS_PORTS
    http_ports = http_ports if http_ports is not None else DEFAULT_HTTP_PORTS

    cfg = {
        "redir-port": redir_port,
        "bind-address": "*",
        "allow-lan": True,
        "mode": "rule",
        "log-level": "warning",
        "external-controller": controller,
        "sniffer": {
            "enable": True,
            "override-destination": True,
            "force-dns-mapping": True,
            "parse-pure-ip": True,
            "sniff": {
                "TLS": {"ports": tls_ports},
                "HTTP": {"ports": http_ports},
            },
        },
        "proxies": proxies,
        "proxy-groups": groups,
    }
    if secret:
        cfg["secret"] = secret
    if external_ui:
        cfg["external-ui"] = external_ui
    if external_ui_url:
        cfg["external-ui-url"] = external_ui_url
    if rulesets:
        _ext = {"text": "txt", "yaml": "yaml", "mrs": "mrs"}
        cfg["rule-providers"] = {
            name: {"type": "http", "url": rs["url"],
                   "behavior": rs.get("behavior", "domain"),
                   "format": rs.get("format", "text"),
                   "path": f"./ruleset/{name}.{_ext.get(rs.get('format', 'text'), 'txt')}",
                   "interval": 86400}
            for name, rs in rulesets.items()
        }
    cfg["rules"] = rules

    meta = {"dropped": dropped, "unknown_proxies": unknown}
    return cfg, meta


def _dur_secs(v):
    """sing-box 时长(如 '3m'/'30s'/数字秒)→ mihomo interval 秒(int)。"""
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip()
    try:
        if s.endswith("ms"):
            return max(1, int(float(s[:-2]) / 1000))
        if s.endswith("s"):
            return int(float(s[:-1]))
        if s.endswith("m"):
            return int(float(s[:-1]) * 60)
        if s.endswith("h"):
            return int(float(s[:-1]) * 3600)
        return int(float(s))
    except ValueError:
        return 180


def render(sb, **kw):
    """便捷:直接返回可写入的 mihomo 配置文本(JSON 即合法 YAML)。"""
    cfg, _ = singbox_to_mihomo(sb, **kw)
    return json.dumps(cfg, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    import sys
    src = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else json.load(sys.stdin)
    cfg, meta = singbox_to_mihomo(src)
    print(json.dumps(cfg, ensure_ascii=False, indent=2))
    if meta["dropped"] or meta["unknown_proxies"]:
        sys.stderr.write("WARN meta: " + json.dumps(meta, ensure_ascii=False) + "\n")

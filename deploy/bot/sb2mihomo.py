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
# 不是代理、但也不该被当成"转换失败"的出站: sing-box 内建动作与组类型(组另行渲染)。
NON_PROXY_TYPES = ("direct", "block", "dns", "urltest", "selector")

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
    if typ == "hysteria":
        # Hysteria v1 与 v2 是**不同协议**(不同握手/鉴权/拥塞), mihomo 各有独立 type,
        # 不能把 v1 塞进 hysteria2(会静默连不上)。v1 → mihomo type:hysteria。
        p = {**base, "type": "hysteria", "udp": True}
        if ob.get("auth_str"):            # 字符串鉴权 → auth-str
            p["auth-str"] = ob["auth_str"]
        elif ob.get("auth"):              # base64 字节鉴权 → auth
            p["auth"] = ob["auth"]
        # 带宽: sing-box up/down(字符串)或 up_mbps/down_mbps(整数 Mbps)→ mihomo up/down
        up = ob.get("up") or (f"{ob['up_mbps']} Mbps" if ob.get("up_mbps") else None)
        down = ob.get("down") or (f"{ob['down_mbps']} Mbps" if ob.get("down_mbps") else None)
        if up:
            p["up"] = up
        if down:
            p["down"] = down
        if ob.get("obfs"):                # v1 obfs 是字符串(区别于 v2 的 {type,password})
            p["obfs"] = ob["obfs"]
        if ob.get("protocol"):            # udp(默认)/faketcp/wechat-video
            p["protocol"] = ob["protocol"]
        sni = _sni(ob)
        if sni:
            p["sni"] = sni
        if (ob.get("tls") or {}).get("insecure"):
            p["skip-cert-verify"] = True
        if (ob.get("tls") or {}).get("alpn"):
            p["alpn"] = list(ob["tls"]["alpn"])
        if ob.get("recv_window_conn"):
            p["recv-window-conn"] = ob["recv_window_conn"]
        if ob.get("recv_window"):
            p["recv-window"] = ob["recv_window"]
        return p
    if typ == "hysteria2":
        p = {**base, "type": "hysteria2", "password": ob.get("password", ""), "udp": True}
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


def _rule_set_names(value):
    """route rule 的 rule_set → 规则集名列表; 返回 (names, err), err 非空即 fail-closed。

    sing-box 的合法形态是字符串**或字符串数组**。本项目自己只写字符串, 但从备份恢复、或用户
    从别处导入的 model 完全可能带数组 —— 原实现直接当标量用, 数组会一路 TypeError 冒到调用方,
    渲染整个失败(而报出来的只是个 TypeError, 看不出是哪条规则)。

    只报**安全标识**: 规则集名是本项目生成的 rs_<hash> 或用户给的标签, 不含订阅 URL/凭据;
    形态不合法时只报类型名与个数, 绝不把原值放进结果 —— 那可能是一个装着任意内容的对象。"""
    if isinstance(value, str):
        vals = [value]
    elif isinstance(value, list):
        vals = value
    else:
        return None, "(rule_set 形态不合法: %s)" % type(value).__name__
    if not vals:
        return None, "(rule_set 为空)"
    names = []
    for v in vals:
        if not isinstance(v, str):
            return None, "(rule_set 数组里有非字符串: %s)" % type(v).__name__
        if not v.strip():
            return None, "(rule_set 含空名)"
        names.append(v)
    return names, ""


# 本路径**当前实际支持**的匹配字段(有序 —— 决定 AND 里条件组的输出顺序, 顺序稳定才可测)。
# 这是一次盘点的结果, 不是愿望清单: 只有这四个字段有对应的 mihomo 规则前缀。
_MATCH_FIELDS = (("rule_set", "RULE-SET"), ("domain_suffix", "DOMAIN-SUFFIX"),
                 ("domain", "DOMAIN"), ("domain_keyword", "DOMAIN-KEYWORD"))
# 不是"匹配条件"的键: action 在上面的 reject 分支处理, outbound 是目标本身。
_NON_COND_KEYS = frozenset({"action", "outbound"})
# inbound 由 _mixed_listeners 单独译成 IN-NAME(见那个函数)。它**单独出现**时本路径不产规则,
# 这是既有行为; 但和别的条件混在一条规则里就没法在这里表达了 —— 那时 fail-closed。
_ELSEWHERE_KEYS = frozenset({"inbound"})


def _cond_values(field, raw):
    """取一个匹配字段的值列表(同字段多值 = OR 组)。返回 (values, err)。"""
    if field == "rule_set":
        return _rule_set_names(raw)
    vals = [raw] if isinstance(raw, str) else raw
    if not isinstance(vals, list) or not vals:
        return None, "(%s 形态不合法: %s)" % (field, type(raw).__name__)
    for v in vals:
        if not isinstance(v, str):
            return None, "(%s 里有非字符串: %s)" % (field, type(v).__name__)
        if not v.strip():
            return None, "(%s 含空值)" % field
    return list(vals), ""


def _rule_condition_groups(r):
    """一条 sing-box route 规则 → (条件组列表, err)。

    条件组 = **同一字段**的多个值(它们之间是 OR); 组与组之间是 **AND** —— 这正是 sing-box
    的规则语义。原实现遇到 rule_set 就 continue, 把同一条规则里的其它条件全丢了; 而把混合
    条件摊平成多条顶层 mihomo 规则同样不行 —— 顶层规则之间是 OR, 那会**扩大**命中范围。

    认不出的字段一律 fail-closed 并点名: 静默忽略的后果是"规则看着加了却没按预期生效"。"""
    groups = []
    for field, prefix in _MATCH_FIELDS:
        if field not in r:
            continue
        vals, err = _cond_values(field, r[field])
        if err:
            return None, err
        groups.append((prefix, vals))
    extra = sorted(set(r) - _NON_COND_KEYS - _ELSEWHERE_KEYS
                   - {f for f, _ in _MATCH_FIELDS})
    if extra:
        return None, "(本转换器不支持的条件字段: %s)" % ", ".join(extra)
    elsewhere = sorted(set(r) & _ELSEWHERE_KEYS)
    if elsewhere:
        # inbound 只在**单独出现**时才由 _mixed_listeners 负责(译成 IN-NAME)。它和域名等
        # 条件混在同一条规则里就是一个 AND, 而本路径表达不了"入口 + 域名" —— 若只译域名那
        # 一半, 命中范围会从"该入口的这些域名"扩大成"所有入口的这些域名"。
        if groups:
            return None, "(本转换器无法表达 %s 与其它条件的组合)" % ", ".join(elsewhere)
        return [], ""
    if not groups:
        return None, "(规则没有可翻译的匹配条件)"
    return groups, ""


def _logic_rule(groups, target):
    """多个条件组 → 一条 mihomo 逻辑规则(外层 AND, 同字段多值时内层 OR)。

    形态取自钉死版 mihomo 的实测:
      AND,((OR,((RULE-SET,a),(RULE-SET,b))),(DOMAIN-SUFFIX,x)),TARGET
    顺序由 _MATCH_FIELDS 与各字段的原始值序决定 —— 稳定可测, 不排序也不去重。"""
    parts = []
    for prefix, vals in groups:
        atoms = ["(%s,%s)" % (prefix, v) for v in vals]
        parts.append(atoms[0] if len(atoms) == 1 else "(OR,(%s))" % ",".join(atoms))
    return "AND,(%s),%s" % (",".join(parts), target)


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
        groups, err = _rule_condition_groups(r)
        if err:
            # fail-closed: 形态或字段不认识就整条不译, 交上层点名报错。绝不把认不出的东西
            # 近似成一条"差不多"的规则 —— 那会渲染出一条永不命中(或命中过宽)的规则, 而
            # 用户以为分流已经生效。
            dropped.append({"rule_set": err, "outbound": out})
            continue
        if not groups:
            continue                      # 纯 inbound 规则, 由 _mixed_listeners 负责
        # 规则集必须真的存在才译得出。多条件组时缺一个就整条不译 —— 少一个 AND 条件就是
        # **扩大**命中范围, 比不译更危险。
        missing = [v for prefix, vals in groups if prefix == "RULE-SET"
                   for v in vals if rulesets is None or v not in rulesets]
        if missing and len(groups) > 1:
            dropped.append({"rule_set": missing[0], "outbound": out})
            continue
        if len(groups) == 1:
            # 单条件组: 沿用原来的扁平输出 —— 同字段多值时顶层多条规则之间正是 OR, 语义相同,
            # 而且现有普通配置的产出逐字节不变。
            prefix, vals = groups[0]
            for v in vals:
                if prefix == "RULE-SET" and v in missing:
                    dropped.append({"rule_set": v, "outbound": out})
                else:
                    rules.append(f"{prefix},{v},{target}")
            continue
        rules.append(_logic_rule(groups, target))
    final = sb.get("route", {}).get("final")
    rules.append(f"MATCH,{_map_target(final, direct_tags) if final else 'DIRECT'}")
    return rules, dropped


def _mixed_listeners(sb, direct_tags):
    """sing-box 的 mixed 入站(如 tg-proxy :8445)→ mihomo listeners + IN-NAME 路由规则。
    direct 入站(80/443/5228-5230)不在此列——它们靠 nft REDIRECT→redir-port 覆盖。
    每个 mixed 入站按 route 里 `inbound:[tag]→出口` 定 pin(没有则跟 route.final)。
    返回 (listeners, in_rules)。"""
    route = sb.get("route", {})
    final = route.get("final")
    listeners, in_rules = [], []
    for i in sb.get("inbounds", []):
        if i.get("type") != "mixed" or not i.get("listen_port"):
            continue
        tag = i.get("tag") or "mixed-in"
        listeners.append({"name": tag, "type": "mixed",
                          "port": i["listen_port"], "listen": i.get("listen", "0.0.0.0")})
        exit_tag = next((r["outbound"] for r in route.get("rules", [])
                         if tag in (r.get("inbound") or []) and r.get("outbound")), None) or final
        in_rules.append(f"IN-NAME,{tag},{_map_target(exit_tag, direct_tags) if exit_tag else 'DIRECT'}")
    return listeners, in_rules


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
        t = o.get("type")
        # 既不是可转协议、也不是内建/组类型 → 必须记成"转不了"。
        # 以前这类出站(wireguard / ssh 等)被**静默跳过**: 不进 proxies 也不进 unknown_proxies,
        # 于是"有出口无法转换"的守卫压根不触发; 而指向它的分流规则照样渲染出去, 最终由
        # mihomo 报 `proxy [X] not found` 拒绝整份配置 —— 用户只看到内核的报错, 既不知道是
        # 哪个出口的问题, 也永远切不过去。
        if t not in PROXY_TYPES and t not in NON_PROXY_TYPES:
            unknown.append(o.get("tag")); continue
        if t in PROXY_TYPES:
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

    # mixed 入站(TG 代理 :8445 等)→ mihomo listeners + IN-NAME 路由(pin 到其出口/final)。
    listeners, in_rules = _mixed_listeners(sb, direct_tags)

    # 规则插入点: 开头的 IP-CIDR REJECT(反自环)之后; 顺序 = reject → IN-NAME(入站 pin) → MITM → 其余。
    i = 0
    while i < len(rules) and rules[i].startswith("IP-CIDR") and rules[i].endswith("REJECT,no-resolve"):
        i += 1
    if in_rules:
        rules = rules[:i] + in_rules + rules[i:]; i += len(in_rules)

    # MITM(Feature B / iOS): 接管域名路由到本地 MITM 服务(socks5 出站, 由它终止 TLS 交插件)。
    if mitm_domains:
        proxies.append({"name": "MITM-OUT", "type": "socks5",
                        "server": "127.0.0.1", "port": mitm_port, "udp": False})
        rules = rules[:i] + [f"DOMAIN-SUFFIX,{d},MITM-OUT" for d in mitm_domains] + rules[i:]

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
    if listeners:
        cfg["listeners"] = listeners
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

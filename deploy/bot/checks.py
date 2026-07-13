#!/usr/bin/env python3
"""PrivDNS Gateway 只读检查库。doctor.py 跑全部, healthcheck.py 跑子集。
每个 check() 返回 (level, label, detail), level ∈ 'ok'|'warn'|'fail'|'info'。只读, 不改任何东西。"""
import os, re, json, ipaddress, subprocess, urllib.request

SB = "/etc/sing-box/config.json"
MOSDNS_CONF = "/etc/mosdns/config.yaml"
DOT_DOMAIN_FILE = "/opt/pdg-bot/dot-domain"

def _run(cmd, t=10):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=t)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)

def _mos():
    try:
        return open(MOSDNS_CONF).read()
    except Exception:  # noqa: BLE001
        return ""

def _server_ip():
    try:
        for r in json.load(open(SB)).get("route", {}).get("rules", []):
            if r.get("action") == "reject":
                for x in r.get("ip_cidr", []):
                    if x.endswith("/32") and not x.startswith("127."):
                        return x.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    return ""

def _cert_path():
    m = re.search(r'cert:\s*"([^"]+)"', _mos())
    return m.group(1) if m else os.environ.get("PDG_CERT", "/etc/mosdns/certs/fullchain.pem")

def _internal_cidr():
    m = re.search(r'ips:\s*\[\s*"([^"]+)"', _mos())
    return m.group(1) if m else ""

def _cert_cn():
    _, out, _ = _run(["openssl", "x509", "-in", _cert_path(), "-noout", "-subject"])
    m = re.search(r"CN\s*=\s*([A-Za-z0-9.*-]+)", out)
    return m.group(1) if m else ""

def _dot_domain():
    # 证书 CN = mosdns 实际服务、手机 TLS 必须匹配的域名(权威); dot-domain 文件只是续期提示, 可能过期
    return _cert_cn() or _dot_file()

def _dot_file():
    try:
        return open(DOT_DOMAIN_FILE).read().strip()
    except Exception:  # noqa: BLE001
        return ""

def check_services():
    bad = [s for s in ("mosdns", "sing-box", "pdg-bot", "pdg-probe81")
           if _run(["systemctl", "is-active", s])[1].strip() != "active"]
    return ("fail", "服务", "未运行: " + ", ".join(bad)) if bad \
        else ("ok", "服务", "mosdns/sing-box/pdg-bot/pdg-probe81 都在")

def check_singbox_version():
    _, out, _ = _run(["sing-box", "version"])
    m = re.search(r"version\s+(\d+)\.(\d+)", out)
    if not m:
        return ("warn", "sing-box 版本", "读不到版本")
    major, minor = int(m.group(1)), int(m.group(2)); v = f"{major}.{minor}"
    if (major, minor) == (1, 12):
        return ("ok", "sing-box 版本", v + ".x ✓")
    if (major, minor) >= (1, 13):
        return ("fail", "sing-box 版本", v + " 太新! 1.13+ 移除了 sniff_override_destination, 网关失效, 须降回 1.12.x")
    return ("warn", "sing-box 版本", v + " 偏旧, 建议 1.12.x")

def check_dot_arecord():
    d = _dot_domain(); sip = _server_ip()
    if not d or not sip:
        return ("warn", "DoT A 记录", "域名或本机 IP 读不到")
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@1.1.1.1", d, "A"])
    ips = [x for x in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
    if sip in ips:
        return ("ok", "DoT A 记录", f"{d} → {sip} ✓")
    if not ips:
        return ("warn", "DoT A 记录", f"{d} 解析不到 A 记录")
    return ("fail", "DoT A 记录", f"{d} → {ips[0]}, 不是本机 {sip}")

def check_dot_domain_sync():
    """dot-domain 文件(续期 deploy-hook 据它选证书)应与证书 CN 一致, 否则续期会部署错证书、DoT 失配。"""
    cn = _cert_cn(); f = _dot_file()
    if not cn or not f:
        return ("ok", "DoT 域名一致性", "无需检查")
    if f != cn:
        return ("warn", "DoT 域名一致性",
                f"dot-domain={f} 与证书 CN={cn} 不一致; 续期可能部署错证书。建议: echo {cn} > {DOT_DOMAIN_FILE}")
    return ("ok", "DoT 域名一致性", f"{cn} ✓")

def check_internal_cidr():
    c = _internal_cidr()
    if not c:
        return ("fail", "内网卡段", "未配置(npn_clients 空)")
    try:
        net = ipaddress.ip_network(c, strict=False)
    except Exception:  # noqa: BLE001
        return ("fail", "内网卡段", f"{c} 不是合法 CIDR")
    if net.prefixlen == 0:
        return ("fail", "内网卡段", f"{c} 等于全网, 会劫持所有来源!")
    cgnat = ipaddress.ip_network("100.64.0.0/10")   # 运营商 CGNAT(RFC 6598), py<3.13 的 is_private 不含它
    if not (net.is_private or net.subnet_of(cgnat) or net == cgnat):
        return ("fail", "内网卡段", f"{c} 是公网段, 危险")
    if net.prefixlen < 12:
        return ("warn", "内网卡段", f"{c} 偏宽(/{net.prefixlen}), 建议收到内网卡精确 /16")
    return ("ok", "内网卡段", c)

def check_nft():
    # 兼容两种表名: 新版独立表 inet pdg; 旧装(尚未迁移)仍是 inet filter。
    _, out, _ = _run(["nft", "list", "chain", "inet", "pdg", "input"])
    if not out:
        _, out, _ = _run(["nft", "list", "chain", "inet", "filter", "input"])
    if not out:
        return ("warn", "防火墙", "读不到 nftables")
    leaked = set()
    for ln in out.splitlines():
        s = ln.strip()
        if "saddr" in s or "accept" not in s:
            continue  # 限定来源的行 / 非 accept 行, 跳过
        m = re.search(r"dport\s*\{?\s*([0-9,\-\s]+)", s)   # 端口集可含区间(如 5228-5230)
        if m:
            sens = {"53", "80", "81", "443", "853", "5228", "5229", "5230", "8445"}
            for tok in m.group(1).split(","):
                tok = tok.strip()
                if tok.isdigit() and tok in sens:
                    leaked.add(tok)
                elif re.match(r"^\d+-\d+$", tok):          # 区间: 判敏感端口是否落在区间内, 不枚举(1-65535 也能报全)
                    a, b = (int(x) for x in tok.split("-"))
                    leaked |= {p for p in sens if a <= int(p) <= b}
    if leaked:
        return ("fail", "防火墙", "这些口对全网开放(应只限内网卡): " + ", ".join(sorted(leaked)))
    return ("ok", "防火墙", "53/80/81/443/853/5228-5230/8445 仅限内网卡来源")

def check_gms():
    """GMS/FCM 推送端口(5228-5230)是否完整启用。只读、不触发迁移: 老装第一次 pdg update
    跑在旧脚本里, 迁移要等下一次 root 管理类命令; 没落地前用 warn 提示(不 fail, 自定义防火墙用户合法缺席)。"""
    try:
        have = {i.get("listen_port") for i in json.load(open(SB)).get("inbounds", [])}
    except Exception:  # noqa: BLE001
        have = set()
    sb_ok = {5228, 5229, 5230} <= have
    _, out, _ = _run(["nft", "list", "chain", "inet", "pdg", "input"])
    if not out:
        _, out, _ = _run(["nft", "list", "chain", "inet", "filter", "input"])
    if not out:                                  # 没 nft 权限/没装时退回看 on-disk 配置
        try:
            out = open("/etc/nftables.conf").read()
        except OSError:
            out = ""
    fw_ok = any("saddr" in ln and "5228" in ln and "tcp" in ln and "accept" in ln
                for ln in out.splitlines())      # 覆盖原装形态(内网来源 + 5228-5230 区间)即可
    if sb_ok and fw_ok:
        return ("ok", "GMS 推送", "GMS/FCM 5228-5230 已启用")
    return ("warn", "GMS 推送", "GMS/FCM 推送端口未完整启用; 运行 sudo pdg restart 或 sudo pdg 触发迁移。"
                                "若使用自定义防火墙, 请手动放行内网卡段 → 5228-5230/tcp。")

def _internal_seq_block(conf):
    """截取 mosdns config 里 internal_sequence 一段文本 (到下一个顶层 '  - tag:' 为止)。"""
    lines = conf.splitlines()
    out, grab = [], False
    for ln in lines:
        if ln.startswith("  - tag: internal_sequence"):
            grab = True; out.append(ln); continue
        if grab and ln.startswith("  - tag: "):
            break
        if grab:
            out.append(ln)
    return "\n".join(out)

_RL_WARN = ("warn", "限流", "mosdns 单客户端 QPS 兜底(rate_limiter)缺失或参数/动作异常; "
                            "运行 sudo pdg restart 或 sudo pdg 触发迁移。高度自定义配置请手动在 "
                            "internal_sequence 缓存前加 client_limiter(qps200/burst400/mask4-32/mask6-128)+ "
                            "'!$client_limiter → reject 5'。")
_RL_WANT = {"qps": "200", "burst": "400", "mask4": "32", "mask6": "128"}

def check_mosdns_ratelimit():
    """单客户端 QPS 兜底(rate_limiter)是否就位且参数/动作正确:
    插件 client_limiter 是 rate_limiter 且 qps200/burst400/mask4-32/mask6-128;
    internal_sequence 缓存查询之前 '!$client_limiter' 的动作确为 reject 5。
    只读; 任一不符 → warn(不 fail, 老装未迁移或高度自定义配置属合法缺席)。"""
    conf = _mos()
    if not conf:
        return ("warn", "限流", "读不到 mosdns 配置")
    # 1) 精确解析插件块参数(client_limiter / type: rate_limiter / args {...})
    m = re.search(r"-\s*tag:\s*client_limiter\s*\n\s*type:\s*rate_limiter\s*\n\s*args:\s*\{([^}]*)\}", conf)
    if not m:
        return _RL_WARN
    args = m.group(1)
    for k, v in _RL_WANT.items():
        mm = re.search(r"\b" + k + r"\s*:\s*(\d+)", args)
        if not mm or mm.group(1) != v:
            return _RL_WARN
    # 2) internal_sequence 里 '!$client_limiter' 的紧邻 exec 必须是 reject 5, 且在缓存查询之前
    blk = _internal_seq_block(conf)
    i_lim = blk.find("!$client_limiter")
    i_cache = blk.find("$lazy_cache")
    if i_lim < 0 or (i_cache >= 0 and i_lim >= i_cache):
        return _RL_WARN
    step = re.search(r'matches:\s*"?!\$client_limiter"?\s*\n\s*exec:\s*reject\s+5\b', blk)
    if not step:
        return _RL_WARN
    return ("ok", "限流", "单客户端 QPS 兜底已就位(rate_limiter qps200/burst400, reject 5, 缓存前)")

PROFILE_ENV = "/etc/privdns-gateway/profile.env"

def check_mem():
    """显示当前内存模式 + mosdns cache size(只读, 不写 profile)。始终 ok, 仅信息展示。"""
    mode = None
    try:
        for ln in open(PROFILE_ENV):
            if ln.startswith("PDG_LOWMEM="):
                mode = ln.strip().split("=", 1)[1]
    except OSError:
        pass
    if mode not in ("0", "1"):                      # 无 profile → 按内存推断(不写盘)
        try:
            kb = int(next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemTotal:")))
            mode = "1" if kb <= 1331200 else "0"    # 1300 MiB
        except Exception:  # noqa: BLE001
            mode = "?"
    label = {"1": "低内存", "0": "标准", "?": "未知"}[mode]
    size = "?"
    m = re.search(r"tag: lazy_cache.*?size:\s*(\d+)", _mos(), re.S)
    if m:
        size = m.group(1)
    return ("ok", "内存模式", f"{label} · mosdns cache={size}")

def check_cert():
    p = _cert_path()
    if not os.path.exists(p):
        return ("fail", "证书", f"{p} 不存在")
    rc, _, _ = _run(["openssl", "x509", "-checkend", str(14 * 86400), "-noout", "-in", p])
    return ("warn", "证书", "14 天内过期, 查 certbot.timer") if rc != 0 else ("ok", "证书", "存在且 >14 天")

def check_dns():
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@127.0.0.1", "example.com", "A"])
    return ("ok", "本机DNS", "mosdns 应答正常") if out.strip() \
        else ("fail", "本机DNS", "127.0.0.1:53 不应答(mosdns?)")

def check_singbox_config():
    rc, out, err = _run(["sing-box", "check", "-c", SB], t=20)
    return ("ok", "sing-box 配置", "check 通过") if rc == 0 \
        else ("fail", "sing-box 配置", "check 失败: " + (out + err)[-200:])

# ── 深度(慢速)端到端检查: `pdg doctor --deep` 用, 仍只读 ──
def check_deep_dot_handshake():
    d = _dot_domain()
    try:
        p = subprocess.run(["openssl", "s_client", "-connect", "127.0.0.1:853",
                            "-servername", d or "localhost"],
                           input="Q\n", capture_output=True, text=True, timeout=12)
        out = p.stdout + p.stderr
    except Exception as e:  # noqa: BLE001
        return ("fail", "DoT 握手(853)", f"连接失败: {e}")
    if "BEGIN CERTIFICATE" not in out and "Verify return code" not in out:
        return ("fail", "DoT 握手(853)", "TLS 握手未完成(mosdns DoT 没起?)")
    m = re.search(r"subject=.*?CN\s*=\s*([A-Za-z0-9.*-]+)", out)
    cn = m.group(1) if m else "?"
    if d and cn not in ("?", d):
        return ("warn", "DoT 握手(853)", f"握手 OK 但证书 CN={cn} 与 DoT 域名 {d} 不符")
    return ("ok", "DoT 握手(853)", f"TLS 握手成功, CN={cn}")

def check_deep_probe81():
    rc, out, _ = _run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                       "--max-time", "5", "http://127.0.0.1:81/probe"])
    code = out.strip()
    return ("ok", "iOS 探测(:81)", "返回 200 ✓") if code == "200" \
        else ("fail", "iOS 探测(:81)", f"返回 {code or '无响应'}(iOS 需要 200)")

def check_deep_dns_cn():
    # 本机源(127.0.0.1)不在内网卡段 → 走 remote_upstream; 国内域名应得真实 IP(非本机)
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@127.0.0.1", "www.qq.com", "A"])
    ips = [x for x in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
    sip = _server_ip()
    if not ips:
        return ("fail", "DNS 解析(国内)", "www.qq.com 无 A 记录(mosdns/上游异常?)")
    if sip and sip in ips:
        return ("warn", "DNS 解析(国内)", f"www.qq.com → 本机 {sip}?? 国内域名不该被劫持")
    return ("ok", "DNS 解析(国内)", f"www.qq.com → {ips[0]}(直连)")

def check_deep_clash():
    try:
        with urllib.request.urlopen("http://127.0.0.1:9090/proxies", timeout=5) as r:
            n = len(json.load(r).get("proxies", {}))
        return ("ok", "clash_api", f"127.0.0.1:9090 可读, {n} 个出站/组")
    except Exception as e:  # noqa: BLE001
        return ("warn", "clash_api", f"读不到 127.0.0.1:9090 ({e})")

def check_deep_hijack_note():
    c = _internal_cidr() or "内网卡段"
    return ("info", "代理劫持验证",
            f"A 劫持 / AAAA 抑制只对来源 {c} 生效; 本机 dig(源 127.0.0.1)走直连上游, "
            "无法复现劫持。端到端请用手机走内网卡实测。")

# ── DNS 上游可观测性: 逐上游探测可达性/延迟 + 近 1h mosdns 上游错误计数 ──
def _upstreams_of(tag):
    """从 mosdns 配置里抽某个 forward 块的 upstream addr 列表。"""
    m = re.search(r"- tag:\s*" + re.escape(tag) + r"\b(.*?)(?:\n\s*- tag:|\Z)", _mos(), re.S)
    return re.findall(r'addr:\s*"([^"]+)"', m.group(1)) if m else []

def _dns_query(qname="example.com"):
    """构造一个 A 查询的 wire bytes, 返回 (qid, bytes)。"""
    import os, struct
    qid = os.getpid() & 0xffff
    hdr = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)              # RD=1
    qn = b"".join(bytes([len(x)]) + x.encode() for x in qname.split(".")) + b"\x00"
    return qid, hdr + qn + struct.pack(">HH", 1, 1)                   # QTYPE=A, QCLASS=IN

def _dns_resp_ok(resp, qid):
    """合法 DNS 应答: ID 匹配 + QR=1 + RCODE=0(NOERROR) + 至少 1 条回答。"""
    import struct
    if len(resp) < 12:
        return False
    rid, flags, _, an = struct.unpack(">HHHH", resp[:8])
    return rid == qid and bool(flags & 0x8000) and (flags & 0x000f) == 0 and an >= 1

def _recvn(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            break
        b += c
    return b

def _probe_upstream(addr):
    """返回 (addr, 毫秒|None, 说明)。None=不健康。每种协议都发真实 DNS 查询并校验应答(ID/RCODE/有回答),
    避免"端口被别的服务占着也算健康"——CDN/反代/错服务过不了 DNS 应答校验。"""
    import time, socket
    t0 = time.monotonic()
    ok = False; note = ""
    try:
        if addr.startswith(("udp://", "tcp://")):
            hp = addr.split("://", 1)[1]; host, _, port = hp.partition(":"); port = port or "53"
            args = ["dig", "+time=2", "+tries=1", "+short", "@" + host, "-p", port, "example.com", "A"]
            if addr.startswith("tcp://"):
                args.insert(1, "+tcp")
            rc, out, _ = _run(args, t=4); ok = (rc == 0 and bool(out.strip()))   # dig 已校验 RCODE/回答
        elif addr.startswith("https://"):                                        # DoH: 发真实 wire query
            import urllib.request
            qid, wire = _dns_query()
            req = urllib.request.Request(addr, data=wire,
                headers={"content-type": "application/dns-message", "accept": "application/dns-message"})
            with urllib.request.urlopen(req, timeout=3) as r:
                ok = (getattr(r, "status", 200) == 200) and _dns_resp_ok(r.read(), qid)
        elif addr.startswith("tls://"):                                          # DoT: TLS + DNS-over-TCP
            import ssl, struct
            hp = addr.split("://", 1)[1]; host, _, port = hp.partition(":")
            qid, wire = _dns_query()
            ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            with socket.create_connection((host, int(port or 853)), timeout=3) as raw:
                with ctx.wrap_socket(raw, server_hostname=host) as tls:
                    tls.sendall(struct.pack(">H", len(wire)) + wire)
                    head = _recvn(tls, 2)
                    body = _recvn(tls, struct.unpack(">H", head)[0]) if len(head) == 2 else b""
                    ok = _dns_resp_ok(body, qid)
        else:
            return (addr, None, "未知协议")
    except Exception as e:  # noqa: BLE001
        note = str(e)[:40]
    ms = int((time.monotonic() - t0) * 1000)
    return (addr, ms if ok else None, note or ("不可达/超时" if not ok else ""))

def check_deep_upstreams():
    rank = {"ok": 0, "warn": 1, "fail": 2}; level = "ok"; parts = []
    for name, tag in (("国际remote", "remote_upstream"), ("国内local", "local_upstream")):
        ups = _upstreams_of(tag)
        if not ups:
            parts.append(f"{name} 读不到配置"); level = max(level, "warn", key=rank.get); continue
        oks = []; bad = []
        for a in ups:
            _, ms, msg = _probe_upstream(a)
            (bad if ms is None else oks).append(f"{a} {msg}" if ms is None else (a, ms))
        if not oks:
            level = max(level, "fail", key=rank.get)
            parts.append(f"{name} 0/{len(ups)} ❌ ({'; '.join(bad)})")
        else:
            slow = max(oks, key=lambda x: x[1])
            seg = f"{name} {len(oks)}/{len(ups)} 最慢 {slow[0]} {slow[1]}ms"
            if bad:
                level = max(level, "warn", key=rank.get); seg += f" ⚠️挂:{'; '.join(bad)}"
            parts.append(seg)
    _, log, _ = _run(["journalctl", "-u", "mosdns", "--since", "-1h", "--no-pager", "-o", "cat"], t=8)
    nerr = log.count("upstream error")
    if nerr:
        parts.append(f"近1h上游错误 {nerr} 次")
        level = max(level, "warn", key=rank.get)
    return (level, "DNS 上游探测", " ; ".join(parts))

ALL = [check_services, check_singbox_version, check_dot_arecord, check_dot_domain_sync,
       check_internal_cidr, check_nft, check_gms, check_mosdns_ratelimit, check_mem,
       check_cert, check_dns, check_singbox_config]
ALERT = [check_services, check_dns, check_cert]  # healthcheck 用的轻量子集(运行期故障)
DEEP = [check_deep_dot_handshake, check_deep_probe81, check_deep_dns_cn,
        check_deep_clash, check_deep_upstreams, check_deep_hijack_note]  # pdg doctor --deep 追加

def run(funcs=None):
    return [f() for f in (funcs or ALL)]

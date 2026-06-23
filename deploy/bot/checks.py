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
        m = re.search(r"dport\s*\{?\s*([0-9,\s]+)", s)
        if m:
            ports = {p.strip() for p in m.group(1).split(",") if p.strip().isdigit()}
            leaked |= ports & {"53", "80", "81", "443", "853"}
    if leaked:
        return ("fail", "防火墙", "这些口对全网开放(应只限内网卡): " + ", ".join(sorted(leaked)))
    return ("ok", "防火墙", "53/80/81/443/853 仅限内网卡来源")

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

ALL = [check_services, check_singbox_version, check_dot_arecord, check_dot_domain_sync,
       check_internal_cidr, check_nft, check_cert, check_dns, check_singbox_config]
ALERT = [check_services, check_dns, check_cert]  # healthcheck 用的轻量子集(运行期故障)
DEEP = [check_deep_dot_handshake, check_deep_probe81, check_deep_dns_cn,
        check_deep_clash, check_deep_hijack_note]  # pdg doctor --deep 追加

def run(funcs=None):
    return [f() for f in (funcs or ALL)]

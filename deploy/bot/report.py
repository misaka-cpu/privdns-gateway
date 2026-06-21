#!/usr/bin/env python3
"""pdg report —— 收集一份诊断快照, 方便排障。只读, 不改任何配置。
默认**脱敏**(隐藏 TG token / 代理密码 / uuid / server/user/id / 出口链接), 写到
/opt/pdg-bot/pdg-report-YYYYmmdd-HHMMSS.txt (权限 600)。
  pdg report               默认脱敏
  pdg report --redact-ip   额外隐藏公网 IP / 内网 CIDR / DoT 域名(贴公开 issue 用)
  pdg report --full        不脱敏(仅本机查看, 含真实 IP/域名)"""
import os, re, sys, ipaddress, subprocess, datetime

sys.path.insert(0, "/opt/pdg-bot")
try:
    import checks  # 复用证书路径 / DoT 域名 / 本机 IP 推断
except Exception:  # noqa: BLE001
    checks = None

# ── 默认脱敏规则(在最终文本上统一过一遍) ──
_REDACTORS = [
    # Telegram bot token: 数字:长串 (含 URL 里的 .../bot<token>/...; 故不加前导 \b)
    (re.compile(r'\d{6,}:[A-Za-z0-9_-]{20,}'), '[REDACTED_TOKEN]'),
    # UUID(vmess/vless id)
    (re.compile(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
                r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'), '[REDACTED_UUID]'),
    # JSON 里的敏感字段(若有泄漏)
    (re.compile(r'("(?:password|uuid|user|username|id|server|method)"\s*:\s*)"[^"]*"'),
     r'\1"[REDACTED]"'),
    # 出口分享链接
    (re.compile(r'((?:ss|ssr|vmess|vless|trojan|hysteria2?|tuic)://)\S+', re.I),
     r'\1[REDACTED]'),
    # bot.env 行 / 启动日志里的 allowed id
    (re.compile(r'(?mi)^(PDG_BOT_TOKEN|PDG_BOT_ALLOWED)=.*$'), r'\1=[REDACTED]'),
    (re.compile(r'(allowed:\s*)[\{\[][^\}\]]*[\}\]]'), r'\1[REDACTED]'),
]
# --redact-ip 时保留的非敏感地址(公共 DNS / 本地), 不打码以保可读
_KEEP_IP = {"1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "223.5.5.5", "223.6.6.6",
            "9.9.9.9", "0.0.0.0"}

def redact(s):
    for rx, rep in _REDACTORS:
        s = rx.sub(rep, s)
    return s

def redact_ip(s):
    """额外隐藏公网 IP / 内网 CIDR / DoT 域名(精确匹配 + 公网 IPv4 兜底)。"""
    if checks:
        for v, lbl in [(checks._internal_cidr(), "[REDACTED_CIDR]"),
                       (checks._dot_domain(), "[REDACTED_DOMAIN]"),
                       (checks._cert_cn(), "[REDACTED_DOMAIN]"),
                       (checks._server_ip(), "[REDACTED_IP]")]:  # 本机公网 IP 显式兜底
            if v:
                s = s.replace(v, lbl)

    def _repl(m):
        ip = m.group(0)
        try:
            a = ipaddress.ip_address(ip)
        except ValueError:
            return ip
        if a.is_private or a.is_loopback or a.is_unspecified or ip in _KEEP_IP:
            return ip
        return "[REDACTED_IP]"
    return re.sub(r'\b\d{1,3}(?:\.\d{1,3}){3}\b', _repl, s)

def run(cmd, t=15):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=t)
        return (p.stdout + p.stderr).strip() or "(无输出)"
    except Exception as e:  # noqa: BLE001
        return f"(执行失败: {e})"

def section(title, body):
    return f"\n===== {title} =====\n{body.rstrip()}\n"

def main():
    full = "--full" in sys.argv
    rip = "--redact-ip" in sys.argv
    mode = "未脱敏(仅本机)" if full else ("脱敏+隐藏IP/域名" if rip else "脱敏")

    cert = checks._cert_path() if checks else "/etc/mosdns/certs/fullchain.pem"
    dom = checks._dot_domain() if checks else ""
    sip = checks._server_ip() if checks else ""

    parts = [f"PrivDNS Gateway 诊断报告 ({mode})\n生成: {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\n"
             f"主机: {run(['hostname'])}"]
    parts.append(section("自检 doctor --json", run(["python3", "/opt/pdg-bot/doctor.py", "--json"])))
    parts.append(section("服务状态", "\n".join(
        f"  {s:<14}{run(['systemctl', 'is-active', s])}"
        for s in ("mosdns", "sing-box", "pdg-bot", "pdg-probe81",
                  "pdg-rules-update.timer", "pdg-health.timer", "vnstat"))))
    parts.append(section("sing-box 版本", run(["sing-box", "version"])))
    parts.append(section("监听端口 (ss -lntu)", run(["ss", "-lntu"])))
    parts.append(section("证书 (CN / 有效期)",
                         run(["openssl", "x509", "-in", cert, "-noout", "-subject", "-enddate"])))
    parts.append(section(f"DoT A 记录 ({dom or '?'} @1.1.1.1, 本机应为 {sip or '?'})",
                         run(["dig", "+short", dom, "@1.1.1.1"]) if dom else "(未知 DoT 域名)"))
    parts.append(section("防火墙 input 链", run(["nft", "list", "chain", "inet", "filter", "input"])))
    parts.append(section("最近日志 (pdg-bot / mosdns / sing-box, 80 行)",
                         run(["journalctl", "-u", "pdg-bot", "-u", "mosdns", "-u", "sing-box",
                              "-n", "80", "--no-pager", "-o", "short-iso"], t=20)))

    text = "".join(parts)
    if not full:
        text = redact(text)
        if rip:
            text = redact_ip(text)

    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = f"/opt/pdg-bot/pdg-report-{'full-' if full else ''}{ts}.txt"
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    print(f"✅ 已生成诊断报告(600, {mode}): {out}")
    if full:
        print("   ⚠️ 此文件含真实 IP/域名等, 仅供本机查看, 别直接外发。")
    else:
        print("   已隐藏 token/密码/uuid/出口链接。" +
              ("公网 IP/内网段/DoT 域名也已打码。" if rip
               else "贴公开 issue 前建议加 --redact-ip 连 IP/域名一起隐藏。"))

if __name__ == "__main__":
    main()

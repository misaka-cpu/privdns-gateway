#!/usr/bin/env python3
"""Static + dynamic regression for doctor firewall port coverage."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
checks_src = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")

assert '{"53", "80", "81", "443", "853", "5228", "5229", "5230", "7893", "8445"}' in checks_src, (
    "doctor firewall leak detection must include TG SOCKS5 8445, GMS 5228-5230 and mihomo redir 7893"
)
assert "53/80/81/443/853/5228-5230/7893/8445" in checks_src, (
    "doctor firewall OK text should mention 8445, 5228-5230 and 7893"
)

# 动态: 端口区间写法(如 5228-5230)对全网开放也要被识别为泄露; 限内网来源则不报。
spec = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checks)

checks._run = lambda cmd: (0, "chain input {\n tcp dport { 22 } accept\n"
                              " tcp dport { 5228-5230 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "fail" and "5228" in msg and "5230" in msg, (st, msg)

checks._run = lambda cmd: (0, "chain input {\n tcp dport { 22 } accept\n"
                              " ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 8445 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "ok", (st, msg)

# 宽区间对全网开放: 不枚举也要把落在区间内的敏感端口全报出来
checks._run = lambda cmd: (0, "chain input {\n tcp dport { 1-65535 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "fail", (st, msg)
for p in ("53", "443", "5228", "5230", "8445"):
    assert p in msg, (p, msg)

# 宽区间但限定内网来源: 不算泄露
checks._run = lambda cmd: (0, "chain input {\n ip saddr 172.22.0.0/16 tcp dport { 1-65535 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "ok", (st, msg)

# ── mihomo redir 端口 7893(Issue 6) ──
# 对全网 accept → fail(代理入口被暴露成开放中继)
checks._run = lambda cmd: (0, "chain input {\n tcp dport { 22 } accept\n"
                              " tcp dport { 7893 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "fail" and "7893" in msg, (st, msg)

# 限内网来源(mihomo 原装模板形态)→ ok, 不误报
checks._run = lambda cmd: (0, "chain input {\n ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 7893, 8445 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "ok", (st, msg)

# 宽区间对全网开放要把 7893 一并报出
checks._run = lambda cmd: (0, "chain input {\n tcp dport { 7000-8000 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "fail" and "7893" in msg, (st, msg)

# sing-box 模式(规则里根本没有 7893)→ 不因"缺 7893"误报
checks._run = lambda cmd: (0, "chain input {\n ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 8445 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "ok", (st, msg)

# ── check_redirect: mihomo 代理入口(80/443 REDIRECT)必须在, 缺了判 fail ──
# 回归 .200 事故: iOS GMS 清理迁移把整条 redirect 删掉, 代理链路断了好几天, 而当时
# doctor 全绿 —— 因为防火墙那项只查"敏感端口有没有对全网开放", 规则消失反而更"干净"。
PRE_OK_IOS = ("chain prerouting {\n type nat hook prerouting priority dstnat; policy accept;\n"
              " ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893\n}")
PRE_OK_ANDROID = ("chain prerouting {\n type nat hook prerouting priority dstnat; policy accept;\n"
                  " ip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n}")
PRE_EMPTY = "chain prerouting {\n type nat hook prerouting priority dstnat; policy accept;\n}"

checks._mihomo_redir_port = lambda: 7893
# 隔离宿主机: check_redirect 兜底会读 NFT_CONF, 真机上那份文件的内容不该影响断言
checks.NFT_CONF = "/nonexistent/pdg-test-nftables.conf"

def redir_case(core, pre):
    checks._core = lambda: core
    checks._run = lambda cmd: (0, pre, "")
    return checks.check_redirect()

st, _, msg = redir_case("mihomo", PRE_OK_IOS)
assert st == "ok" and "7893" in msg, (st, msg)

st, _, msg = redir_case("mihomo", PRE_OK_ANDROID)          # 安卓形态(含 GMS)同样算就位
assert st == "ok", (st, msg)

st, _, msg = redir_case("mihomo", PRE_EMPTY)               # .200 当时的样子
assert st == "fail" and "80/443" in msg, (st, msg)

# 目标端口与 mihomo 实际 redir-port 不一致 → 也算断
st, _, msg = redir_case("mihomo",
    "chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7891\n}")
assert st == "fail", (st, msg)

# 只 redirect 了 80 没有 443 → 不算就位
st, _, msg = redir_case("mihomo",
    "chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80 } redirect to :7893\n}")
assert st == "fail", (st, msg)

# sing-box 后端没有这条 REDIRECT(走入站/tproxy) → 返回 None 跳过, 不得误报
assert redir_case("singbox", PRE_EMPTY) is None

# ── check_gms: sing-box 三入站 + 防火墙内网放行 → ok; 任一缺失 → warn(不 fail) ──
import json, tempfile

NFT_OK = ("chain input {\n ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 8445 } accept\n}")
NFT_NO_GMS = ("chain input {\n ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 8445 } accept\n}")

def gms_case(ports, nft_out):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"inbounds": [{"type": "direct", "listen_port": p} for p in ports]}, f)
        path = f.name
    checks.SB = path
    checks._run = lambda cmd: (0, nft_out, "")
    return checks.check_gms()

st, _, msg = gms_case([443, 80, 5228, 5229, 5230], NFT_OK)
assert st == "ok" and "5228-5230" in msg, (st, msg)

st, _, msg = gms_case([443, 80, 5229, 5230], NFT_OK)          # sing-box 缺 5228
assert st == "warn" and "pdg" in msg, (st, msg)

st, _, msg = gms_case([443, 80, 5228, 5229, 5230], NFT_NO_GMS)  # 防火墙缺 5228-5230
assert st == "warn", (st, msg)

st, _, msg = gms_case([443, 80], NFT_NO_GMS)                    # 双缺也只 warn, 不 fail
assert st == "warn", (st, msg)

# ── check_gms iOS: 正常无残留 → None(不显示); sing-box/nft 端口集残留 5228 → warn ──
_orig_platform = checks._platform
checks._platform = lambda: "ios"
try:
    def ios_case(sb_text, nft_out):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write(sb_text)
            checks.SB = f.name
        checks._run = lambda cmd: (0, nft_out, "")
        return checks.check_gms()

    # 干净 iOS: sing-box 无 in-gms, nft 无 5228 → None
    assert ios_case('{"inbounds": []}', "chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893\n}") is None

    # sing-box 仍带 in-gms-5228 入站 → warn 指出 sing-box
    r = ios_case('{"inbounds": [{"tag": "in-gms-5228", "listen_port": 5228}]}', "chain input {}")
    assert r is not None and r[0] == "warn" and "sing-box" in r[2], r

    # nft 端口集残留 5228-5230 → warn 指出 nft
    r = ios_case('{"inbounds": []}', "chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n}")
    assert r is not None and r[0] == "warn" and "nft" in r[2], r
finally:
    checks._platform = _orig_platform

print("doctor-firewall regression OK")

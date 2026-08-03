#!/usr/bin/env python3
"""Static + dynamic regression for doctor firewall port coverage."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
checks_src = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")

assert '{"53", "80", "81", "443", "853", "5228", "5229", "5230", "7893", "8445"}' in checks_src, (
    "doctor firewall leak detection must include TG SOCKS5 8445, GMS 5228-5230 and mihomo redir 7893"
)
# 端口清单必须**按平台**生成: iOS 上不能声称 GMS 5228-5230 已就位(装机就剥掉了),
# Android 上也不该提 :81(那是 iOS 专属的 OnDemand 探测端点)。8445 是两平台共用的 TG SOCKS5。
assert "def platform_ports_text(" in checks_src, "端口清单应由 platform_ports_text() 按平台生成"
_code = "\n".join(ln for ln in checks_src.splitlines()
                   if not ln.lstrip().startswith("#") and '"""' not in ln)
assert '"53/80/81/443/853/5228-5230/7893/8445"' not in _code, (
    "不该再有写死的全平台端口串(注释里作为反面例子提到不算)"
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

# ── check_gms(Android): 5228-5230 靠 nft prerouting REDIRECT 进 mihomo 嗅探; 缺 → warn(不 fail) ──
import json, tempfile

# v1.6.0: mihomo 是唯一内核, GMS 判据从"sing-box 入站 + input accept"改为 prerouting REDIRECT。
PRE_GMS_OK = ("chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80, 443, 5228-5230 } redirect to :7893\n}")
PRE_GMS_NO = ("chain prerouting {\n ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893\n}")

def gms_case(ports, nft_out):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump({"inbounds": [{"type": "direct", "listen_port": p} for p in ports]}, f)
        path = f.name
    checks.SB = path
    checks._run = lambda cmd: (0, nft_out, "")
    return checks.check_gms()

st, _, msg = gms_case([443, 80, 5228, 5229, 5230], PRE_GMS_OK)
assert st == "ok" and "5228-5230" in msg, (st, msg)

st, _, msg = gms_case([443, 80], PRE_GMS_OK)      # 模型入站已不参与判据, 仍按防火墙判 ok
assert st == "ok", (st, msg)

st, _, msg = gms_case([443, 80, 5228, 5229, 5230], PRE_GMS_NO)  # 防火墙缺 5228-5230 → warn
assert st == "warn", (st, msg)

st, _, msg = gms_case([443, 80], PRE_GMS_NO)                    # 双缺也只 warn, 不 fail
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

# ── 端口文案按平台动态生成 ──────────────────────────────────────────────────
import os, tempfile  # noqa: E402

_d = tempfile.mkdtemp()
checks.PLATFORM_FILE = os.path.join(_d, "platform")
checks._run = lambda cmd: (0, "chain input {\n ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 7893, 8445 } accept\n}", "")

open(checks.PLATFORM_FILE, "w").write("android")
_t = checks.platform_ports_text()
assert "5228-5230" in _t and "仅 Android" in _t, _t
# 6.1B: probe81 已是公共件, 两平台都监听并放行 81 —— Android 也该列出来。
assert "81" in _t.replace("8445", ""), "Android 也该提 :81(公共件): " + _t
assert "8445" in _t, "8445(TG SOCKS5)两平台共用"
_st, _, _detail = checks.check_nft()
assert _st == "ok" and "5228-5230" in _detail and "仅 Android" in _detail, (_st, _detail)
print("[OK]   Android: 端口文案含 5228-5230(仅 Android), 也含 :81(公共件)")

open(checks.PLATFORM_FILE, "w").write("ios")
_t = checks.platform_ports_text()
# 6.1B: 81 不再是 iOS 专属, 文案里也不该再写"(仅 iOS)"。
assert "81" in _t.replace("8445", "") and "81(仅 iOS)" not in _t, _t
assert "5228" not in _t, "iOS 上不得声称 GMS 5228-5230 已就位: " + _t
assert "8445" in _t, "8445(TG SOCKS5)两平台共用"
_st, _, _detail = checks.check_nft()
assert _st == "ok" and "5228" not in _detail \
    and "81" in _detail.replace("8445", "") and "81(仅 iOS)" not in _detail, (_st, _detail)
print("[OK]   iOS: 端口文案含 81(不再标「仅 iOS」), 不含 5228-5230")
print("platform port text regression OK")

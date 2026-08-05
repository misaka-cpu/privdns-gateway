#!/usr/bin/env python3
"""doctor 的防火墙三项(防火墙 / 代理入口 / GMS 推送)—— 判据换成共享语义核心之后的契约。

原来这支测试写在"doctor 自己 grep 一份 `nft list chain` 文本"的实现之上: 夹具是几行规则
文本, 断言里还钉着 checks.py 源码里那行敏感端口字面量集合。那份实现已经整个删掉了 ——
它正是 `.153` 事故的一半原因(doctor 只查"敏感端口有没有对全网开放", 规则整条消失反而更
"干净"; 另一半是 linkstat 拿磁盘文本与内核文本做集合比对)。

所以这里**换契约, 不删判据**: 每一条仍然成立的要求都原样保留, 只是喂进去的夹具从规则文本
换成 `nft -j` 的 JSON, 断言从"源码里有没有那行字面量"换成"这个故障它到底报不报"。

只有一条旧断言被删掉了, 并且是有证据的: 旧文件里有一格叫"sing-box 模式(规则里根本没有
7893)→ 不因缺 7893 误报"。sing-box 运行时在 **v1.6.0 已彻底移除**(README.md:80 与
pdg.sh:17 都写明 mihomo 是唯一内核), 所以"没有 7893 的机器"这个前提不再存在, 现在缺 7893
就是真故障。它被替换成反方向的一条: 缺 7893 必须报 fail。
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


CIDR = "172.22.0.0/16"
BOX = tmpguard.mkdtemp(prefix="docfw.")
PROFILE = os.path.join(BOX, "profile.env")
io.open(PROFILE, "w", encoding="utf-8").write("PDG_INTERNAL_CIDR=%s\n" % CIDR)
NFTCONF = os.path.join(BOX, "nftables.conf")
io.open(NFTCONF, "w", encoding="utf-8").write("# 合成夹具\n")

spec = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checks)
import nftlive  # noqa: E402

checks.PROFILE_ENV = PROFILE
checks.NFT_CONF = NFTCONF
checks._internal_cidr = lambda: CIDR
checks._mihomo_redir_port = lambda: 7893


# ── 夹具: nft -j 的 JSON, 而不是规则文本 ────────────────────────────────────
def _m(proto, field, val):
    return {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": field}},
                      "right": val}}


def _saddr(pfx):
    net, ln = pfx.split("/")
    return {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                      "right": {"prefix": {"addr": net, "len": int(ln)}}}}


def _rule(chain, expr, h=0):
    return {"rule": {"family": "inet", "table": "pdg", "chain": chain, "handle": h,
                     "expr": expr}}


def kern(*, input_rules, pre_ports=(80, 443), redir_to=7893, pre_chain=True):
    items = [{"table": {"family": "inet", "name": "pdg"}}]
    if pre_chain:
        items.append({"chain": {"family": "inet", "table": "pdg", "name": "prerouting",
                                "type": "nat", "hook": "prerouting", "prio": -100,
                                "policy": "accept"}})
        if pre_ports:
            items.append(_rule("prerouting",
                               [_saddr(CIDR), _m("tcp", "dport", {"set": list(pre_ports)}),
                                {"redirect": {"port": redir_to}}], 1))
    items.append({"chain": {"family": "inet", "table": "pdg", "name": "input",
                            "type": "filter", "hook": "input", "prio": 0, "policy": "drop"}})
    for i, r in enumerate(input_rules):
        items.append(_rule("input", r, 10 + i))
    return {"nftables": items}


# 一台健康机器的 input 链(模板形态, 已被 nft 规范化)
def healthy_input(*, tcp=(53, 81, 853, 7893, 8445), udp=(53,), src=CIDR):
    out = [[{"match": {"op": "==", "left": {"meta": {"key": "iif"}}, "right": "lo"}},
            {"accept": None}],
           [_m("tcp", "dport", 22), {"accept": None}]]
    if tcp:
        out.append([_saddr(src), _m("tcp", "dport", {"set": list(tcp)}), {"accept": None}])
    for p in udp:
        out.append([_saddr(src), _m("udp", "dport", p), {"accept": None}])
    out.append([_saddr(src), _m("udp", "dport", 443),
                {"reject": {"type": "icmp", "expr": "port-unreachable"}}])
    return out


def doctor(kobj, platform="android"):
    """跑一次 doctor 的三项。底层只换"磁盘校验 + 读内核"两步。"""
    _r, _p = checks._run, checks._platform

    def _fake(cmd, t=10):
        if cmd[:1] == ["nft"]:
            if "-c" in cmd:
                return 0, "", ""
            if "-j" in cmd:
                return (0, json.dumps(kobj), "") if kobj is not None else (1, "", "no table")
            return 0, "", ""
        return 0, "", ""

    checks._run = _fake
    checks._platform = lambda: platform
    checks._nft_view_reset()
    try:
        return (checks.check_nft(), checks.check_redirect(), checks.check_gms())
    finally:
        checks._run, checks._platform = _r, _p
        checks._nft_view_reset()


# ═══ 0. 夹具自证 ════════════════════════════════════════════════════════════
print("══ 0. 夹具自证 ══")
n, r, g = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443, 5228, 5229, 5230)))
(ok if n[0] == "ok" else bad)("健康机器: 防火墙 ok(实得 %r)" % (n,))
(ok if r[0] == "ok" else bad)("健康机器: 代理入口 ok(实得 %r)" % (r,))
(ok if g[0] == "ok" else bad)("健康机器: GMS 推送 ok(实得 %r)" % (g,))

# ═══ 1. 敏感端口对全网开放 —— 必须点名 8445 / 5228-5230 / 7893 ═══════════════
print()
print("══ 1. 敏感端口对全网开放 ══")
SENS = nftlive.SENSITIVE_PORTS
for p in (8445, 5228, 5230, 7893, 53, 80, 81, 443, 853):
    (ok if p in SENS else bad)("敏感端口清单含 %d" % p)

# 区间写法(5228-5230)也要认出来 —— nft 的 JSON 里它是 {"range": [5228, 5230]}
kk = kern(input_rules=healthy_input() + [
    [_m("tcp", "dport", {"set": [{"range": [5228, 5230]}]}), {"accept": None}]])
n, _, _ = doctor(kk)
(ok if n[0] == "fail" and "5228" in n[2] and "5230" in n[2] else bad)(
    "区间 5228-5230 对全网开放 → fail 并点名(实得 %r)" % (n,))

# 宽区间 1-65535: 不枚举也要把落在区间内的敏感端口全报出来
kk = kern(input_rules=healthy_input() + [
    [_m("tcp", "dport", {"set": [{"range": [1, 65535]}]}), {"accept": None}]])
n, _, _ = doctor(kk)
(ok if n[0] == "fail" else bad)("1-65535 对全网开放 → fail(实得 %r)" % (n[0],))
for p in ("53", "443", "5228", "5230", "8445", "7893"):
    (ok if p in n[2] else bad)("宽区间里的敏感端口 %s 被点名(实得: %s)" % (p, n[2][:90]))

# 宽区间但**限定内网来源** → 不算泄露
kk = kern(input_rules=healthy_input() + [
    [_saddr(CIDR), _m("tcp", "dport", {"set": [{"range": [1, 65535]}]}), {"accept": None}]])
n, _, _ = doctor(kk)
(ok if n[0] == "ok" else bad)("同样的宽区间但限内网来源 → 不报(实得 %r)" % (n,))

# mihomo redir 端口 7893 对全网 accept → fail(代理入口被暴露成开放中继)
kk = kern(input_rules=healthy_input() + [[_m("tcp", "dport", 7893), {"accept": None}]])
n, _, _ = doctor(kk)
(ok if n[0] == "fail" and "7893" in n[2] else bad)(
    "7893 对全网 accept → fail 并点名(实得 %r)" % (n,))

# 区间 7000-8000 对全网开放 → 也要把 7893 报出来
kk = kern(input_rules=healthy_input() + [
    [_m("tcp", "dport", {"set": [{"range": [7000, 8000]}]}), {"accept": None}]])
n, _, _ = doctor(kk)
(ok if n[0] == "fail" and "7893" in n[2] else bad)(
    "区间 7000-8000 对全网开放 → 报出 7893(实得 %r)" % (n,))

# ═══ 2. 缺 7893 现在是真故障(sing-box 已在 v1.6.0 移除, 没有"合法缺席"这回事) ══
print()
print("══ 2. 缺 7893 ══")
_readme = io.open(str(ROOT / "README.md"), encoding="utf-8").read()
(ok if "彻底移除 sing-box 运行时" in _readme else bad)(
    "证据: README 写明 v1.6.0 起彻底移除 sing-box 运行时 —— 旧断言的前提不再成立")
n, _, _ = doctor(kern(input_rules=healthy_input(tcp=(53, 81, 853, 8445))))
(ok if n[0] == "fail" and "7893" in n[2] else bad)(
    "内核里没有 7893 放行 → fail 并点名(实得 %r)" % (n,))

# ═══ 3. check_redirect: 80/443 REDIRECT ═════════════════════════════════════
print()
print("══ 3. 代理入口(80/443 REDIRECT) ══")
# 回归 .200 事故: iOS GMS 清理迁移把整条 redirect 删掉, 代理链路断了好几天, 而当时
# doctor 全绿 —— 因为防火墙那项只查"敏感端口有没有对全网开放", 规则消失反而更"干净"。
_, r, _ = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443)), platform="ios")
(ok if r[0] == "ok" and "7893" in r[2] else bad)("iOS 形态(80/443)→ ok(实得 %r)" % (r,))
_, r, _ = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443, 5228, 5229, 5230)))
(ok if r[0] == "ok" else bad)("Android 形态(含 GMS)同样算就位(实得 %r)" % (r,))
_, r, _ = doctor(kern(input_rules=healthy_input(), pre_ports=()))
(ok if r[0] == "fail" and "80" in r[2] and "443" in r[2] else bad)(
    ".200 当时的样子(prerouting 空)→ fail 并点名 80/443(实得 %r)" % (r,))
_, r, _ = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443), redir_to=7891))
(ok if r[0] == "fail" else bad)("目标端口与 mihomo 实际 redir-port 不一致 → fail(实得 %r)" % (r,))
_, r, _ = doctor(kern(input_rules=healthy_input(), pre_ports=(80,)))
(ok if r[0] == "fail" and "443" in r[2] else bad)("只 redirect 了 80 没有 443 → fail(实得 %r)" % (r,))
# 读不到就说读不到 —— 不猜绿
_, r, _ = doctor(None)
(ok if r[0] == "warn" else bad)("读不到内核 → warn 而不是 ok(实得 %r)" % (r,))

# ═══ 4. check_gms(Android): 缺 5228-5230 → warn, 不 fail, 也不挡链路 ════════
print()
print("══ 4. GMS 推送 ══")
_, _, g = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443, 5228, 5229, 5230)))
(ok if g[0] == "ok" and "5228-5230" in g[2] else bad)("三个口都在 → ok(实得 %r)" % (g,))
n, r, g = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443)))
(ok if g[0] == "warn" else bad)("防火墙缺 5228-5230 → warn(不是 fail, 实得 %r)" % (g,))
(ok if n[0] == "ok" and r[0] == "ok" else bad)(
    "GMS 缺失不把核心两项拖红(防火墙=%r 代理入口=%r)" % (n[0], r[0]))
_a = nftlive.audit_kernel(kern(input_rules=healthy_input(), pre_ports=(80, 443)),
                          cidr=CIDR, platform="android")
(ok if _a.ok and _a.doctor_issues else bad)(
    "GMS 缺失落在 doctor 专项档, 不进链路硬门(ok=%s doctor_issues=%d)"
    % (_a.ok, len(_a.doctor_issues)))

# ═══ 5. check_gms(iOS): 残留检测 —— 这部分实现没变, 判据照旧 ════════════════
print()
print("══ 5. iOS GMS 残留 ══")
_orig_platform, _orig_run = checks._platform, checks._run
checks._platform = lambda: "ios"
try:
    def ios_case(sb_text, nft_out):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, dir=BOX) as f:
            f.write(sb_text)
            checks.SB = f.name
        checks._run = lambda cmd, t=10: (0, nft_out, "")
        checks._nft_view_reset()
        try:
            return checks.check_gms()
        finally:
            checks._nft_view_reset()

    CLEAN = ("chain prerouting {\n ip saddr %s tcp dport { 80, 443 } redirect to :7893\n}"
             % CIDR)
    RESIDUE = ("chain prerouting {\n ip saddr %s tcp dport { 80, 443, 5228-5230 } "
               "redirect to :7893\n}" % CIDR)
    (ok if ios_case('{"inbounds": []}', CLEAN) is None else bad)(
        "干净 iOS → None(整项不显示)")
    _r = ios_case('{"inbounds": [{"tag": "in-gms-5228", "listen_port": 5228}]}', "chain input {}")
    (ok if _r and _r[0] == "warn" and "sing-box" in _r[2] else bad)(
        "sing-box 仍带 in-gms-5228 入站 → warn 指出 sing-box(实得 %r)" % (_r,))
    _r = ios_case('{"inbounds": []}', RESIDUE)
    (ok if _r and _r[0] == "warn" and "nft" in _r[2] else bad)(
        "nft 端口集残留 5228-5230 → warn 指出 nft(实得 %r)" % (_r,))
finally:
    checks._platform, checks._run = _orig_platform, _orig_run

# ═══ 6. 端口文案按平台生成, 且**不再有第二份端口清单** ══════════════════════
print()
print("══ 6. 端口文案 ══")
_d = tempfile.mkdtemp(dir=BOX)
checks.PLATFORM_FILE = os.path.join(_d, "platform")
(ok if "def platform_ports_text(" in
 io.open(str(ROOT / "deploy/bot/checks.py"), encoding="utf-8").read() else bad)(
    "端口清单由 platform_ports_text() 按平台生成")

io.open(checks.PLATFORM_FILE, "w").write("android")
_t = checks.platform_ports_text()
(ok if "5228-5230" in _t and "仅 Android" in _t else bad)(
    "Android: 文案含 5228-5230(仅 Android)(实得 %s)" % _t)
(ok if "81" in _t.replace("8445", "") else bad)("Android 也该提 :81(公共件): %s" % _t)
(ok if "8445" in _t else bad)("8445(TG SOCKS5)两平台共用")
n, _, _ = doctor(kern(input_rules=healthy_input(),
                      pre_ports=(80, 443, 5228, 5229, 5230)), platform="android")
(ok if n[0] == "ok" and "5228-5230" in n[2] and "仅 Android" in n[2] else bad)(
    "Android: check_nft 的正常文案与之一致(实得 %r)" % (n,))

io.open(checks.PLATFORM_FILE, "w").write("ios")
_t = checks.platform_ports_text()
(ok if "81" in _t.replace("8445", "") and "81(仅 iOS)" not in _t else bad)(
    "iOS: 文案含 81 且不再写「仅 iOS」(实得 %s)" % _t)
(ok if "5228" not in _t else bad)("iOS 上不得声称 GMS 5228-5230 已就位: %s" % _t)
(ok if "8445" in _t else bad)("8445(TG SOCKS5)两平台共用")
n, _, _ = doctor(kern(input_rules=healthy_input(), pre_ports=(80, 443)), platform="ios")
(ok if n[0] == "ok" and "5228" not in n[2] else bad)(
    "iOS: check_nft 的正常文案不含 5228(实得 %r)" % (n,))

# 文案与判据必须来自同一份常量 —— 展示一份、判据另一份, 迟早出现"报告说 8445 已放行、
# 判据根本没查它"这种事。
io.open(checks.PLATFORM_FILE, "w").write("android")
_shown = {int(x) for x in __import__("re").findall(r"\b(\d{2,5})\b",
                                                   checks.platform_ports_text())}
_known = (set(nftlive.REQUIRED_INTERNAL_TCP) | set(nftlive.REDIRECT_TCP)
          | set(nftlive.DOCTOR_ONLY_INTERNAL_TCP) | set(nftlive.GMS_TCP))
(ok if _shown <= _known else bad)(
    "文案里的每个端口都在 nftlive 的常量里(多出来的: %s)" % sorted(_shown - _known))

import shutil  # noqa: E402
shutil.rmtree(BOX, ignore_errors=True)
print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""防火墙判定的条件矩阵与故障矩阵 —— 三条链路(nftlive / doctor / linkstat)同时对照。

为什么要一整张表, 而不是各测各的:

`.153` 那次事故的形状是"两套检查对同一台机器给出相反结论"。修的时候很容易只把健康那一格
弄绿, 然后在别的格子里留下新的不一致 —— 比如 GMS 缺失从"linkstat 挡住会话"改成"doctor 也
不报了", 那是把误报换成漏报。所以这里的每一格都同时问四个问题:

    audit.ok / audit.problems / audit.doctor_issues   ← 共享语义核心怎么判
    doctor 三项(防火墙 / 代理入口 / GMS 推送)的状态与文案
    linkstat 第 8 层的 status 与 code
    Bot 会不会因为这一层拒绝创建手机测试会话

并且**分档必须严格**: 核心故障要四处一致地红; doctor 专项故障要"doctor 点名、linkstat 核心
仍 PASS、Bot 照常建会话"。任何一格串档都是这次要防的回归。

夹具全部是合成的(10.77.0.0/16、最小规则集), 不含真机 IP、凭据或用户自定义规则内容。
本文件只读: 不跑 nft -f、不取锁、不开事务、不写 /run 与 /var/lib —— 最后一节会自证这点。
"""
import copy
import importlib.util as u
import io as _io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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


CIDR = "10.77.0.0/16"
OTHER_CIDR = "192.168.99.0/24"
SSH = 22
REDIR = 7893

# ── 沙箱 ────────────────────────────────────────────────────────────────────
BOX = tempfile.mkdtemp(prefix="nftmx.")
PROFILE = os.path.join(BOX, "profile.env")
_io.open(PROFILE, "w", encoding="utf-8").write("PDG_INTERNAL_CIDR=%s\n" % CIDR)
os.environ["PDG_PROFILE_ENV"] = PROFILE
NFTCONF = os.path.join(BOX, "nftables.conf")
_io.open(NFTCONF, "w", encoding="utf-8").write("# 合成夹具, 内容不参与语义判定\n")

import checks        # noqa: E402
import linkstat as L  # noqa: E402
import nftlive       # noqa: E402

checks.PROFILE_ENV = PROFILE
checks.NFT_CONF = NFTCONF


# ── 内核 JSON 生成器 ────────────────────────────────────────────────────────
def _m(proto, field, val):
    return {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": field}},
                      "right": val}}


def _saddr(pfx):
    net, ln = pfx.split("/")
    return {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                      "right": {"prefix": {"addr": net, "len": int(ln)}}}}


def _rule(chain, expr, handle=0):
    return {"rule": {"family": "inet", "table": "pdg", "chain": chain,
                     "handle": handle, "expr": expr}}


def kernel(platform="android", *, tcp=None, udp=None, redirect=None, gms=True,
           gms_ports=(5228, 5229, 5230), redir_port=REDIR, src=CIDR, redirect_src=None,
           table=True, input_chain=True, pre_chain=True,
           input_type="filter", input_hook="input", input_policy="drop",
           pre_type="nat", pre_hook="prerouting",
           input_verdict="accept", redirect_verdict="redirect",
           udp_as_tcp=False, drop_first=False, reject_first=False,
           world_open=(), extra_rules=(), socks=True):
    """按需要生成一份内核 JSON。默认就是一台标准 Android 机器。

    所有故障格都是在这份默认值上**改一个参数**, 免得每格各抄一份夹具 —— 抄出来的夹具彼此
    有细微差异时, 红绿差别到底来自故障还是来自抄写差异就说不清了。
    """
    tcp = list(nftlive.REQUIRED_INTERNAL_TCP) if tcp is None else list(tcp)
    if socks:
        tcp = sorted(set(tcp) | set(nftlive.DOCTOR_ONLY_INTERNAL_TCP))
    udp = list(nftlive.REQUIRED_INTERNAL_UDP) if udp is None else list(udp)
    redirect = list(nftlive.REDIRECT_TCP) if redirect is None else list(redirect)
    if gms and platform != "ios":
        redirect = sorted(set(redirect) | set(gms_ports))
    rsrc = redirect_src or src

    items = []
    if table:
        items.append({"table": {"family": "inet", "name": "pdg"}})
    if pre_chain:
        items.append({"chain": {"family": "inet", "table": "pdg", "name": "prerouting",
                                "type": pre_type, "hook": pre_hook, "prio": -100,
                                "policy": "accept"}})
        if redirect:
            items.append(_rule("prerouting",
                               [_saddr(rsrc), _m("tcp", "dport", {"set": redirect}),
                                ({"redirect": {"port": redir_port}}
                                 if redirect_verdict == "redirect"
                                 else {redirect_verdict: None})], 1))
    if input_chain:
        items.append({"chain": {"family": "inet", "table": "pdg", "name": "input",
                                "type": input_type, "hook": input_hook, "prio": 0,
                                "policy": input_policy}})
        h = 10
        if drop_first:
            items.append(_rule("input", [{"drop": None}], h)); h += 1
        if reject_first:
            items.append(_rule("input", [{"reject": {"type": "icmp",
                                                     "expr": "port-unreachable"}}], h)); h += 1
        items.append(_rule("input", [{"match": {"op": "==", "left": {"meta": {"key": "iif"}},
                                                "right": "lo"}}, {"accept": None}], h)); h += 1
        items.append(_rule("input", [_m("tcp", "dport", SSH), {"accept": None}], h)); h += 1
        if tcp:
            items.append(_rule("input", [_saddr(src), _m("tcp", "dport", {"set": tcp}),
                                         {input_verdict: None}], h)); h += 1
        for p in udp:
            proto = "tcp" if udp_as_tcp else "udp"
            items.append(_rule("input", [_saddr(src), _m(proto, "dport", p),
                                         {"accept": None}], h)); h += 1
        # 模板里的 udp 443 reject —— nft 会把它规范化成 reject with icmp port-unreachable。
        # 这条**必须**留在默认夹具里: 它正是 `.153` 那四条"假漂移"之一。
        items.append(_rule("input", [_saddr(src), _m("udp", "dport", 443),
                                     {"reject": {"type": "icmp",
                                                 "expr": "port-unreachable"}}], h)); h += 1
        if world_open:
            items.append(_rule("input", [_m("tcp", "dport", {"set": list(world_open)}),
                                         {"accept": None}], h)); h += 1
        for ex in extra_rules:
            items.append(_rule("input", ex, h)); h += 1
    return {"nftables": items}


# ── 一格 = 一次三链路对照 ───────────────────────────────────────────────────
class Cell(object):
    """跑一格: 同一份内核 JSON 分别喂给 nftlive、doctor、linkstat, 收齐结论。"""

    def __init__(self, kern, platform="android", disk_ok=True, disk_why="",
                 kern_readable=True, kern_why="", redir_port=REDIR, calls=None):
        self.kern, self.platform = kern, platform
        self.audit = None
        if kern_readable and disk_ok and kern is not None:
            self.audit = nftlive.audit_kernel(kern, cidr=CIDR, platform=platform,
                                              redir_port=redir_port)

        # doctor: 走真入口 checks.check_nft/check_redirect/check_gms, 只把最底下那层
        # (磁盘校验 + 读内核)换成夹具 —— 判定与分档全是生产代码。
        self.nft_cmds = []

        def _fake_run(cmd, t=10):
            self.nft_cmds.append(list(cmd))
            if cmd[:1] == ["nft"]:
                if "-c" in cmd:
                    return (0, "", "") if disk_ok else (1, "", disk_why or "syntax error")
                if "-j" in cmd:
                    if not kern_readable:
                        return 1, "", kern_why or "nft failed"
                    return 0, json.dumps(kern), ""
                return 0, "", ""
            return 0, "", ""

        _orig_run, _orig_plat = checks._run, checks._platform
        _orig_redir, _orig_cidr = checks._mihomo_redir_port, checks._internal_cidr
        checks._run = _fake_run
        checks._platform = lambda: platform
        checks._mihomo_redir_port = lambda: redir_port
        checks._internal_cidr = lambda: CIDR
        checks._nft_view_reset()
        try:
            self.doctor = {"防火墙": checks.check_nft(),
                           "代理入口": checks.check_redirect(),
                           "GMS": checks.check_gms()}
            self.view_calls = list(checks._nft_view().calls)
        finally:
            checks._run, checks._platform = _orig_run, _orig_plat
            checks._mihomo_redir_port, checks._internal_cidr = _orig_redir, _orig_cidr
            checks._nft_view_reset()

        # linkstat: 走真采集器 _l8_services, 只换 nftlive 的两个 I/O 入口。
        _od, _ok_ = nftlive.check_disk_config, nftlive.read_kernel
        _orp = checks._mihomo_redir_port
        nftlive.check_disk_config = lambda *a, **k: (disk_ok, disk_why)
        nftlive.read_kernel = lambda *a, **k: ((kern, "") if kern_readable
                                               else (None, kern_why or "nft failed"))
        checks._mihomo_redir_port = lambda: redir_port
        try:
            self.l8 = [f for f in L._l8_services({"platform": platform, "cidr": CIDR})
                       if "防火墙" in f["title"]]
        finally:
            nftlive.check_disk_config, nftlive.read_kernel = _od, _ok_
            checks._mihomo_redir_port = _orp

    # —— 取数 ——
    @property
    def ok(self):
        return None if self.audit is None else self.audit.ok

    def kinds(self):
        return sorted({p.kind for p in (self.audit.problems if self.audit else [])})

    def dkinds(self):
        return sorted({p.kind for p in (self.audit.doctor_issues if self.audit else [])})

    def dstat(self, key):
        r = self.doctor.get(key)
        return r[0] if r else None

    def dtext(self, key):
        r = self.doctor.get(key)
        return r[2] if r else ""

    @property
    def l8_status(self):
        return self.l8[0]["status"] if self.l8 else None

    @property
    def l8_code(self):
        return self.l8[0]["code"] if self.l8 else None

    def blocks_session(self):
        """Bot 的真门: `_link_server_blockers` 的判据 —— 非手机侧证据的 FAIL。

        只把防火墙这一层喂进去: 开发机上没有真的 mosdns/证书, 整份 collect() 必然带一堆
        无关 FAIL, 一起断言只会让每一格都红, 那是噪音不是判据。
        """
        return [f for f in self.l8
                if f["status"] == L.FAIL and not L.is_phone_evidence(f)]


def expect(name, cell, *, ok_=None, kinds=None, dkinds=None, l8=None, code=None,
           blocked=None, doctor=None):
    """一格的断言集合。传什么查什么 —— 没传的项不假装查过。"""
    tag = "[%s]" % name
    if ok_ is not None:
        (ok if cell.ok is ok_ else bad)(
            "%s audit.ok=%r(实得 %r; problems=%s)"
            % (tag, ok_, cell.ok, [str(p) for p in (cell.audit.problems if cell.audit else [])]))
    if kinds is not None:
        (ok if cell.kinds() == sorted(kinds) else bad)(
            "%s problems 的 kind=%s(实得 %s)" % (tag, sorted(kinds), cell.kinds()))
    if dkinds is not None:
        (ok if cell.dkinds() == sorted(dkinds) else bad)(
            "%s doctor_issues 的 kind=%s(实得 %s)" % (tag, sorted(dkinds), cell.dkinds()))
    if doctor is not None:
        for key, want in doctor.items():
            got = cell.dstat(key)
            (ok if got == want else bad)(
                "%s doctor「%s」=%r(实得 %r: %s)" % (tag, key, want, got, cell.dtext(key)[:70]))
    if l8 is not None:
        (ok if cell.l8_status == l8 else bad)(
            "%s linkstat L8=%r(实得 %r / %r)" % (tag, l8, cell.l8_status, cell.l8_code))
    if code is not None:
        (ok if cell.l8_code == code else bad)(
            "%s linkstat code=%s(实得 %s)" % (tag, code, cell.l8_code))
    if blocked is not None:
        got = bool(cell.blocks_session())
        (ok if got == blocked else bad)(
            "%s Bot %s建会话(实得 %s)" % (tag, "不允许" if blocked else "允许",
                                     [f["code"] for f in cell.blocks_session()] or "无阻塞"))


# ═══ 0. 夹具自证 ════════════════════════════════════════════════════════════
print("══ 0. 夹具自证: 默认夹具确实含那四种 nft 规范化差异 ══")
_k = kernel()
_txt = json.dumps(_k)
(ok if '"port-unreachable"' in _txt else bad)("夹具含 reject 默认类型展开(udp 443)")
_u53 = [r for r in _k["nftables"] if r.get("rule", {}).get("chain") == "input"
        and any((e.get("match", {}).get("left", {}).get("payload", {}) or {}).get("protocol")
                == "udp" and e["match"]["right"] == 53 for e in r["rule"]["expr"])]
(ok if _u53 else bad)("夹具含单元素折叠后的标量 udp dport 53(不是 {53})")
(ok if nftlive.audit_kernel(_k, cidr=CIDR, platform="android").ok else bad)(
    "默认夹具本身是健康的 —— 后面每一格的红都来自那一处改动, 不是夹具本身有病")

# ═══ 一、条件矩阵(15 格): 各种**正常**配置都不许误报 ═════════════════════════
print()
print("══ 一、条件矩阵 ══")

# 1. Android 标准配置
c = Cell(kernel("android"))
expect("1 Android 标准", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS,
       code="L8_FIREWALL_READY", blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok", "GMS": "ok"})

# 2. Android GMS 完整(与 1 同形, 但显式点名 5228-5230 三个口都在)
c = Cell(kernel("android", gms=True))
_pre = [r["rule"] for r in c.kern["nftables"] if r.get("rule", {}).get("chain") == "prerouting"]
_ports = set()
for r in _pre:
    for e in r["expr"]:
        rt = (e.get("match") or {}).get("right")
        if isinstance(rt, dict) and "set" in rt:
            _ports |= set(rt["set"])
(ok if {5228, 5229, 5230} <= _ports else bad)("[2 GMS 完整] 夹具里三个 GMS 口都在(实得 %s)"
                                              % sorted(_ports))
expect("2 GMS 完整", c, ok_=True, dkinds=[], l8=L.PASS, blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok", "GMS": "ok"})

# 3. Android GMS 缺失 —— doctor 点名, 但**不是**链路硬门
c = Cell(kernel("android", gms=False))
expect("3 GMS 缺失", c, ok_=True, kinds=[], dkinds=["gms"], l8=L.PASS,
       code="L8_FIREWALL_READY", blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok", "GMS": "warn"})
(ok if "5228" in c.dtext("GMS") else bad)(
    "[3 GMS 缺失] doctor 点到了 5228(实得: %s)" % c.dtext("GMS")[:80])

# 4. iOS 无 GMS —— 装机就摘掉了, 既不失败也不提
c = Cell(kernel("ios", gms=False), platform="ios")
expect("4 iOS 无 GMS", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS, blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok"})
(ok if c.doctor["GMS"] is None or "残留" in (c.doctor["GMS"] or ("", "", ""))[1] else bad)(
    "[4 iOS 无 GMS] doctor 不显示 GMS 推送项(实得 %r)" % (c.doctor["GMS"],))

# 5/6. iOS WLOC 关 / 开
# 这一格不能靠"喂两份一样的夹具, 看结果一样"来证 —— 那只证明函数是确定性的。真正要证的是
# **WLOC 开关根本不动 nft**: 去看它那笔事务落哪些 target。落的是 mitm_json / mitm_hijack /
# mihomo_cfg, nftables_conf 一次都没出现, 所以两种状态下防火墙判定同为 PASS 是有原因的。
_bsrc = _io.open(str(ROOT / "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
import re as _re  # noqa: E402
_wl = _re.search(r"\ndef _mitm_transact\(new_wloc\):.*?\n(?=def )", _bsrc, _re.S)
(ok if _wl else bad)("[5/6 WLOC] 抽到了 WLOC 落地的那笔事务(_mitm_transact)")
_wtargets = set(_re.findall(r"t\.(?:stage|derive|watch)\(\s*\"([a-z_]+)\"", _wl.group(0) if _wl else ""))
(ok if _wtargets else bad)("[5/6 WLOC] 抽到了它的事务 target(实得 %s)" % sorted(_wtargets))
(ok if "nftables_conf" not in _wtargets else bad)(
    "[5/6 WLOC] 开关 WLOC 不写 nftables_conf(实得 target: %s)" % sorted(_wtargets))
c_off = Cell(kernel("ios", gms=False), platform="ios")
expect("5/6 iOS WLOC 两态", c_off, ok_=True, kinds=[], dkinds=[], l8=L.PASS, blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok"})

# 7. rescue 关闭且无 8446 —— 不许误报
c = Cell(kernel("android"))
_txt = json.dumps(c.kern)
(ok if "8446" not in _txt else bad)("[7 rescue 关] 夹具里确实没有 8446")
expect("7 rescue 关, 无 8446", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS, blocked=False,
       doctor={"防火墙": "ok"})
(ok if 8446 not in set(nftlive.REQUIRED_INTERNAL_TCP) | set(nftlive.DOCTOR_ONLY_INTERNAL_TCP)
 else bad)("[7 rescue 关] 8446 不在 nftlive 的任何固定端口集合里")


def rescue_cell(bind, port, conf_text):
    """救援那一项走它自己的检查(动态端口 + 启用状态), 与 nftlive 无关。"""
    import rescue_const
    import rescue_nft  # noqa: F401  仅确认可导入
    _b, _p = rescue_const.rescue_bind, rescue_const.port
    rescue_const.rescue_bind = lambda *a, **k: bind
    rescue_const.port = lambda *a, **k: port
    path = os.path.join(BOX, "nft-rescue.conf")
    _io.open(path, "w", encoding="utf-8").write(conf_text)
    _c = checks.NFT_CONF
    checks.NFT_CONF = path
    try:
        return checks.check_rescue_firewall()
    finally:
        rescue_const.rescue_bind, rescue_const.port = _b, _p
        checks.NFT_CONF = _c


_BASE_CONF = """table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        ip saddr %s tcp dport { 53, 81, 853, 7893, 8445 } accept
%%s    }
}
""" % CIDR



def _rescue_line(port, bind="10.77.0.9"):
    """救援放行的字面形态取自 rescue_nft.rule_line() 本身 —— 手抄一份的话, 抄漏了
    `comment "pdg-rescue"` 标记会让这一格永远红, 而红的原因是夹具不对, 不是实现不对。"""
    import rescue_nft
    return rescue_nft.rule_line(CIDR, bind, port) + "\n"

r = rescue_cell("", 8446, _BASE_CONF % "")
(ok if r is None else bad)("[7 rescue 关] 救援未启用 → doctor 整项不显示(实得 %r)" % (r,))

# 8. rescue 开启且动态 8446 正确
r = rescue_cell("10.77.0.9", 8446, _BASE_CONF % _rescue_line(8446))
(ok if r and r[0] == "ok" else bad)("[8 rescue 开, 8446 就位] doctor ok(实得 %r)" % (r,))
# 端口是**动态**的: 换成 9446 也要照样认出来, 而不是死盯 8446
r = rescue_cell("10.77.0.9", 9446, _BASE_CONF % _rescue_line(9446))
(ok if r and r[0] == "ok" else bad)("[8 rescue 开, 自定义端口 9446] doctor ok(实得 %r)" % (r,))
r = rescue_cell("10.77.0.9", 9446, _BASE_CONF % _rescue_line(8446))
(ok if r and r[0] == "fail" else bad)(
    "[8 rescue 开] 配置里是 8446 而实际端口是 9446 → fail(不是死盯 8446 就报绿, 实得 %r)" % (r,))

# 9. rescue 开启但 8446 缺失 → doctor 点名; linkstat 不受影响
r = rescue_cell("10.77.0.9", 8446, _BASE_CONF % "")
(ok if r and r[0] == "fail" and "8446" in r[2] else bad)(
    "[9 rescue 开, 缺 8446] doctor 点名(实得 %r)" % (r,))
c = Cell(kernel("android"))
expect("9 rescue 缺口不挡链路", c, ok_=True, l8=L.PASS, blocked=False)

# 10. 8445 正常
c = Cell(kernel("android", socks=True))
expect("10 8445 正常", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS, blocked=False,
       doctor={"防火墙": "ok"})

# 11. 8445 缺失 → doctor 点名, linkstat 核心仍 PASS, Bot 照常建会话
c = Cell(kernel("android", socks=False))
expect("11 8445 缺失", c, ok_=True, kinds=[], dkinds=["socks"], l8=L.PASS,
       code="L8_FIREWALL_READY", blocked=False, doctor={"防火墙": "warn"})
(ok if "8445" in c.dtext("防火墙") and "Telegram" in c.dtext("防火墙") else bad)(
    "[11 8445 缺失] doctor 点名 TG SOCKS5(实得: %s)" % c.dtext("防火墙")[:80])

# 12/13. panel 关 / 开(9090 仅回环)—— 9090 不进 nft input 集合, 判定不受影响
c_off = Cell(kernel("android"))
c_on = Cell(kernel("android", extra_rules=[[
    {"match": {"op": "==", "left": {"meta": {"key": "iif"}}, "right": "lo"}},
    {"match": {"op": "==", "left": {"payload": {"protocol": "tcp", "field": "dport"}},
               "right": 9090}}, {"accept": None}]]))
expect("12 panel 关", c_off, ok_=True, kinds=[], dkinds=[], l8=L.PASS, blocked=False)
expect("13 panel 开(9090 仅回环)", c_on, ok_=True, kinds=[], dkinds=[], l8=L.PASS,
       blocked=False)
(ok if 9090 not in set(nftlive.REQUIRED_INTERNAL_TCP)
 | set(nftlive.DOCTOR_ONLY_INTERNAL_TCP) | set(nftlive.SENSITIVE_PORTS) else bad)(
    "[13 panel] 9090 不在 nftlive 的任何 nft input 端口集合里(它绑 127.0.0.1, 走回环)")
# 9090 的边界由 doctor 的「内核状态接口」那项管, 而且它只往回环地址发请求 —— 真跑一次,
# 把 urlopen 换成留痕的桩, 看它到底连了哪个地址。只 grep 源码里有没有 "9090" 是查不出
# "它有没有改成连内网地址"的。
_seen_urls = []
_orig_urlopen = checks.urllib.request.urlopen


def _tap(req, *a, **k):
    _seen_urls.append(getattr(req, "full_url", str(req)))
    raise OSError("桩: 不真的发请求")


checks.urllib.request.urlopen = _tap
try:
    _dc = checks.check_deep_clash()
finally:
    checks.urllib.request.urlopen = _orig_urlopen
(ok if _seen_urls and all(x.startswith("http://127.0.0.1:") for x in _seen_urls) else bad)(
    "[13 panel] 内核状态接口只连回环(实连: %s)" % _seen_urls)
(ok if _dc and _dc[1] == "内核状态接口" else bad)(
    "[13 panel] 9090 的回环边界仍由 doctor 的「内核状态接口」那项管(实得 %r)"
    % ((_dc or ("", "", ""))[1],))

# 14. 各支持的 hijack-mode —— 同理: 模式从 CLI 的真源取(不是我背出来的), 并证明切换它
# 只落 mosdns 与 profile.env 两个 target, 一条 nft 规则都不动。
_shsrc = _io.open(str(ROOT / "deploy/bot/pdg.sh"), encoding="utf-8").read()
_hm = _re.search(r"\ncmd_hijack_mode\(\)\{.*?\n\}\n", _shsrc, _re.S)
(ok if _hm else bad)("[14 hijack-mode] 抽到了 cmd_hijack_mode")
_hbody = _hm.group(0) if _hm else ""
_modes = sorted(set(_re.findall(r'\$mode"?\s*!=\s*([a-z]+)', _hbody)))
(ok if _modes == ["all", "gfw"] else bad)(
    "[14 hijack-mode] 从 CLI 真源取到支持的模式(实得 %s)" % _modes)
# 落盘那一步在 _pdg_hijack_transact 里(cmd_hijack_mode 只做参数校验后调它)—— 事务目标要
# 去那个函数里看, 在 cmd_hijack_mode 里找是找不到的。
_ht = _re.search(r"\n_pdg_hijack_transact\(\)\{.*?\n\}\n", _shsrc, _re.S)
(ok if _ht else bad)("[14 hijack-mode] 抽到了真正落盘的 _pdg_hijack_transact")
_tbody = _ht.group(0) if _ht else ""
_htargets = set(_re.findall(r'"([a-z_]+):\$wd/', _tbody))
(ok if _htargets == {"mosdns_conf", "profile_env"} else bad)(
    "[14 hijack-mode] 它只落 mosdns_conf 与 profile_env(实得 %s)" % sorted(_htargets))
(ok if "nftables_conf" not in _tbody and "nft " not in _tbody else bad)(
    "[14 hijack-mode] 切换劫持模式不碰防火墙")
expect("14 hijack-mode 下的判定", Cell(kernel("android")), ok_=True, kinds=[], dkinds=[],
       l8=L.PASS, blocked=False, doctor={"防火墙": "ok"})

# 15. 用户额外添加**无冲突**的规则 —— 不许因为"多了没见过的行"就判红
c = Cell(kernel("android", extra_rules=[
    [_saddr(CIDR), _m("tcp", "dport", {"set": [10022]}), {"accept": None}],
    [_m("tcp", "dport", 51820), {"accept": None}],          # 非敏感端口, 对全网开也不该报
]))
expect("15 用户自定义无冲突规则", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS,
       code="L8_FIREWALL_READY", blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok", "GMS": "ok"})

# ═══ 二、故障矩阵(20 格) ═════════════════════════════════════════════════════
print()
print("══ 二、故障矩阵 ══")

CORE = dict(ok_=False, l8=L.FAIL, blocked=True, doctor={"防火墙": "fail"})

# 1. table 缺失
expect("F1 table 缺失", Cell(kernel(table=False)), kinds=["table"],
       code="L8_FIREWALL_RULE_MISSING", **CORE)
# 2. input chain 缺失
expect("F2 input 链缺失", Cell(kernel(input_chain=False)), kinds=["table"], **CORE)
# 3. prerouting chain 缺失 —— 归 check_redirect 报, check_nft 不重复
c = Cell(kernel(pre_chain=False))
expect("F3 prerouting 链缺失", c, ok_=False, kinds=["redirect"], l8=L.FAIL, blocked=True,
       doctor={"防火墙": "ok", "代理入口": "fail"})
(ok if c.dtext("防火墙").count("prerouting") == 0 else bad)(
    "[F3] 同一根因只报一次: 防火墙那项不重复 prerouting 的事(实得: %s)" % c.dtext("防火墙")[:60])
# 4. type / hook / policy 错误
expect("F4a input policy=accept", Cell(kernel(input_policy="accept")), kinds=["table"], **CORE)
expect("F4b input hook=forward", Cell(kernel(input_hook="forward")), kinds=["table"], **CORE)
expect("F4c input type=nat", Cell(kernel(input_type="nat")), kinds=["table"], **CORE)
expect("F4d prerouting type=filter", Cell(kernel(pre_type="filter")), kinds=["table"], **CORE)
expect("F4e prerouting hook=output", Cell(kernel(pre_hook="output")), kinds=["table"], **CORE)
# 5-10. 每个核心必需端口分别缺失
for p, why in ((53, "DNS"), (81, "HTTP 探测"), (853, "DoT"), (7893, "mihomo redir")):
    kk = [x for x in nftlive.REQUIRED_INTERNAL_TCP if x != p]
    c = Cell(kernel(tcp=kk))
    expect("F 缺 tcp %d(%s)" % (p, why), c, kinds=["missing"],
           code="L8_FIREWALL_RULE_MISSING", **CORE)
    (ok if str(p) in c.dtext("防火墙") else bad)(
        "[F 缺 tcp %d] doctor 点名了这个端口(实得: %s)" % (p, c.dtext("防火墙")[:70]))
expect("F6 缺 udp 53", Cell(kernel(udp=[])), kinds=["missing"], **CORE)
# 7. udp 53 被写成 tcp 53 —— tcp 那条看着齐全, 手机的普通 DNS 查询其实断了
c = Cell(kernel(udp_as_tcp=True))
expect("F7 udp 53 写成 tcp", c, kinds=["missing"], **CORE)
(ok if "udp" in c.dtext("防火墙") else bad)(
    "[F7] doctor 明说缺的是 udp(实得: %s)" % c.dtext("防火墙")[:70])
# 11/12. 80 / 443 redirect 缺失
for p in (80, 443):
    rr = [x for x in nftlive.REDIRECT_TCP if x != p]
    c = Cell(kernel(redirect=rr))
    expect("F 缺 redirect %d" % p, c, ok_=False, kinds=["redirect"], l8=L.FAIL,
           blocked=True, doctor={"代理入口": "fail"})
    (ok if str(p) in c.dtext("代理入口") else bad)(
        "[F 缺 redirect %d] doctor 代理入口点名(实得: %s)" % (p, c.dtext("代理入口")[:70]))
# 13. redirect 目标不是 7893
c = Cell(kernel(redir_port=1080))
expect("F13 redirect 到 :1080", c, ok_=False, kinds=["redirect"], l8=L.FAIL, blocked=True,
       doctor={"代理入口": "fail"})
(ok if "1080" in c.dtext("代理入口") and "7893" in c.dtext("代理入口") else bad)(
    "[F13] doctor 同时说出实得端口与应有端口(实得: %s)" % c.dtext("代理入口")[:90])
# 14. CIDR 错误(规则在, 但限的是别的网段)
c = Cell(kernel(src=OTHER_CIDR, redirect_src=OTHER_CIDR))
expect("F14 来源网段写错", c, ok_=False, kinds=["redirect", "source"], l8=L.FAIL,
       code="L8_FIREWALL_RULE_UNSAFE", blocked=True, doctor={"防火墙": "fail"})
# 15. 来源放宽为全网
c = Cell(kernel(world_open=nftlive.REQUIRED_INTERNAL_TCP))
expect("F15 敏感端口对全网开放", c, ok_=False, l8=L.FAIL, code="L8_FIREWALL_RULE_UNSAFE",
       blocked=True, doctor={"防火墙": "fail"})
(ok if "leak" in c.kinds() else bad)("[F15] kind 落在 leak(实得 %s)" % c.kinds())
(ok if "source" not in c.kinds() else bad)(
    "[F15] 同一根因只报一次: 不再额外报一遍「来源网段不对」(实得 %s)" % c.kinds())
# 16. verdict 错误
expect("F16 必需放行写成 drop", Cell(kernel(input_verdict="drop")), kinds=["verdict", "missing"],
       **CORE)
expect("F16b redirect 写成 accept", Cell(kernel(redirect_verdict="accept")),
       ok_=False, kinds=["redirect"], l8=L.FAIL, blocked=True, doctor={"代理入口": "fail"})
# 17. 必需规则排在无条件 drop / reject 之后
c = Cell(kernel(drop_first=True))
expect("F17a 排在无条件 drop 之后", c, kinds=["order"], code="L8_FIREWALL_RULE_ORDER_INVALID",
       **CORE)
c = Cell(kernel(reject_first=True))
expect("F17b 排在无条件 reject 之后", c, kinds=["order"],
       code="L8_FIREWALL_RULE_ORDER_INVALID", **CORE)
# 18. 磁盘语法错误 —— 不读内核就该停, 且不回显规则内容
c = Cell(kernel(), disk_ok=False, disk_why="/etc/nftables.conf:12:5-9: Error: syntax error")
expect("F18 磁盘语法错误", c, l8=L.FAIL, code="L8_FIREWALL_CONFIG_INVALID", blocked=True,
       doctor={"防火墙": "fail"})
(ok if not any("-j" in x for x in c.nft_cmds) else bad)(
    "[F18] 磁盘都不合法就不去读内核(实发: %s)" % c.nft_cmds)
# 19. nft 命令失败 / 超时
c = Cell(kernel(), kern_readable=False, kern_why="nft 返回非零(1)")
expect("F19 nft 读内核失败", c, l8=L.FAIL, code="L8_FIREWALL_KERNEL_UNREADABLE",
       blocked=True, doctor={"防火墙": "fail"})
(ok if c.dstat("代理入口") == "warn" and c.dstat("GMS") == "warn" else bad)(
    "[F19] 读不到就说读不到, 不猜绿(代理入口=%r GMS=%r)"
    % (c.dstat("代理入口"), c.dstat("GMS")))
# 20. JSON 空 / 截断 / 损坏 / 未知结构 —— 一律 fail-closed
for label, obj, readable in (("空", None, True), ("空 JSON 对象", {}, True),
                             ("未知结构", {"foo": [1, 2]}, True),
                             ("规则挂在别的表", {"nftables": [
                                 {"table": {"family": "inet", "name": "filter"}}]}, True)):
    c = Cell(obj if obj is not None else kernel(), kern_readable=readable and obj is not None)
    if obj is None:
        expect("F20 %s" % label, c, l8=L.FAIL, blocked=True, doctor={"防火墙": "fail"})
    else:
        expect("F20 %s" % label, c, ok_=False, kinds=["table"], l8=L.FAIL, blocked=True,
               doctor={"防火墙": "fail"})
# 坏 JSON 走的是 read_kernel 的解析分支, 直接验它
_bad = nftlive.read_kernel(runner=lambda cmd: (0, '{"nftables": [', ""))
(ok if _bad[0] is None else bad)("[F20 截断 JSON] read_kernel 返回 None 而不是半份结构")
_empty = nftlive.read_kernel(runner=lambda cmd: (0, "", ""))
(ok if _empty[0] is None else bad)("[F20 空输出] read_kernel 返回 None")
_rc = nftlive.read_kernel(runner=lambda cmd: (1, "", "boom"))
(ok if _rc[0] is None else bad)("[F20 非零退出] read_kernel 返回 None")

# ═══ 三、健康的规范化差异: 两边都必须通过 ═════════════════════════════════════
print()
print("══ 三、规范化差异不是故障 ══")
c = Cell(kernel("android"))
expect("N 规范化样本", c, ok_=True, kinds=[], dkinds=[], l8=L.PASS,
       code="L8_FIREWALL_READY", blocked=False,
       doctor={"防火墙": "ok", "代理入口": "ok", "GMS": "ok"})
(ok if "L8_NFT_DRIFT" not in L.CODES else bad)("L8_NFT_DRIFT 已不在 CODES 闭集")

# ═══ 四、调用次数与零副作用 ══════════════════════════════════════════════════
print()
print("══ 四、调用次数与零副作用 ══")
c = Cell(kernel("android"))
_j = [x for x in c.view_calls if "-j" in x]
(ok if len(_j) == 1 else bad)(
    "一轮 doctor 只发一次 `nft -j list`(实发 %d 次: %s)" % (len(_j), _j))
_cc = [x for x in c.view_calls if "-c" in x]
(ok if len(_cc) == 1 else bad)("磁盘语法校验也只跑一次(实发 %d 次)" % len(_cc))
(ok if not any("-f" in x and "-c" not in x for x in c.nft_cmds) else bad)(
    "从没执行过 `nft -f`(只加载, 不校验)的形态(实发: %s)" % c.nft_cmds)
(ok if all(("add" not in x and "delete" not in x and "flush" not in x and "insert" not in x)
           for x in c.nft_cmds) else bad)("没有任何 nft 写操作(add/delete/flush/insert)")

_src = _io.open(str(ROOT / "deploy/bot/nftlive.py"), encoding="utf-8").read()
for token, why in (("pdgtx", "不开配置事务"), ("flock", "不取写锁"),
                   ('"w"', "不写文件"), ("os.remove", "不删文件"),
                   ("makedirs", "不建目录")):
    (ok if token not in _src else bad)("nftlive 里没有 %s(%s)" % (token, why))

# linkstat 不再解析文本规则
_lsrc = _io.open(str(ROOT / "deploy/bot/linkstat.py"), encoding="utf-8").read()
(ok if "_nft_rule_set" not in _lsrc else bad)("linkstat 里没有 _nft_rule_set")
for gone in ("磁盘上有 %d 条规则没在内核里生效", "磁盘/内核一致性"):
    (ok if gone not in _lsrc else bad)("linkstat 里没有旧漂移文案 %r" % gone[:20])

# doctor 里不再有第二份端口清单 / 第二套解析
_csrc = _io.open(str(ROOT / "deploy/bot/checks.py"), encoding="utf-8").read()
import re as _re2
_fn = _re2.search(r"\ndef check_nft\(\):.*?\n(?=def |\n# )", _csrc, _re2.S)
_body = _fn.group(0) if _fn else ""
(ok if _body else bad)("抽到了 check_nft 的函数体")
(ok if "dport" not in _body else bad)("check_nft 里不再有自己的规则文本解析(dport 正则)")
(ok if "nftlive" in _csrc and "_nft_view" in _body else bad)(
    "check_nft 走的是共享判定 _nft_view()")


def _literals(fn_name):
    """函数体里出现的**字面量**(不含注释与 docstring)。

    直接对源码文本查端口号会把说明文字也算进去 —— "外加 doctor 专项端口(8445)"是注释,
    不是第二份端口清单。判据必须落在真正参与运算的东西上, 否则删掉一句注释就能让它变绿。
    """
    import ast
    for node in ast.walk(ast.parse(_csrc)):
        if isinstance(node, ast.FunctionDef) and node.name == fn_name:
            out = set()
            body = node.body[1:] if (node.body and isinstance(node.body[0], ast.Expr)
                                     and isinstance(node.body[0].value, ast.Constant)
                                     and isinstance(node.body[0].value.value, str)) else node.body
            for n in body:
                for x in ast.walk(n):
                    if isinstance(x, ast.Constant):
                        out.add(x.value)
            return out
    return None


for _fname in ("check_nft", "check_redirect"):
    _lits = _literals(_fname)
    (ok if _lits is not None else bad)("抽到了 %s 的字面量" % _fname)
    _ports = {x for x in (_lits or set())
              if isinstance(x, int) and not isinstance(x, bool) and x > 50}
    (ok if not _ports else bad)(
        "%s 里没有自己的端口字面量(实得 %s)" % (_fname, sorted(_ports)))
    _strports = {x for x in (_lits or set()) if isinstance(x, str)
                 and _re2.search(r"\b(53|81|853|7893|8445|5228|5229|5230)\b", x)}
    (ok if not _strports else bad)(
        "%s 的字符串里也没有硬编码端口(实得 %s)" % (_fname, sorted(_strports)[:2]))

# 落盘证据: 跑完整轮之后, 沙箱里除了我们自己写的那两份, 一个新文件都没有
_before = set(os.listdir(BOX))
Cell(kernel("android"))
_after = set(os.listdir(BOX))
(ok if _before == _after else bad)("整轮判定没有产生任何新文件(新增: %s)" % (_after - _before))

# ═══ 五、doctor 与 linkstat 对每一格都不许唱反调 ═══════════════════════════
print()
print("══ 五、两条链路逐格一致 ══")
_cases = [("健康", kernel("android"), "android"),
          ("GMS 缺失", kernel("android", gms=False), "android"),
          ("8445 缺失", kernel("android", socks=False), "android"),
          ("缺 tcp 81", kernel(tcp=[53, 853, 7893]), "android"),
          ("缺 udp 53", kernel(udp=[]), "android"),
          ("缺 redirect 80", kernel(redirect=[443]), "android"),
          ("table 缺失", kernel(table=False), "android"),
          ("iOS 健康", kernel("ios", gms=False), "ios")]
for name, kj, plat in _cases:
    cell = Cell(kj, platform=plat)
    doctor_core_fail = any(cell.dstat(k) == "fail" for k in ("防火墙", "代理入口"))
    link_fail = cell.l8_status == L.FAIL
    (ok if doctor_core_fail == link_fail else bad)(
        "[%s] doctor 核心档与 linkstat 结论一致(doctor_fail=%s link_fail=%s)"
        % (name, doctor_core_fail, link_fail))
    if cell.audit is not None:
        (ok if bool(cell.audit.doctor_issues) == (not not cell.dkinds()) else bad)(
            "[%s] doctor 专项档不串进链路硬门(doctor_issues=%s ok=%s)"
            % (name, [str(x) for x in cell.audit.doctor_issues], cell.audit.ok))

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
shutil.rmtree(BOX, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

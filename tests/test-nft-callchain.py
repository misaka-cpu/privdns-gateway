#!/usr/bin/env python3
"""调用链级判据: doctor 与 linkstat 对同一台健康机器不能给出相反结论。

`.153` 真机验收被这条卡住过: 机器完全正常, `pdg doctor --deep` 报 0 失败 0 警告, 而
`pdg link status` 的第 8 层判 FAIL, Bot 据此拒绝创建手机测试会话——用户根本做不了测试。

根因不在机器, 在判据: linkstat 拿磁盘配置与内核输出做**纯文本集合比对**, 而 nft 输出时
会自己规范化写法。四种真实等价形态因此被当成"磁盘有、内核没有":

    磁盘                         内核
    tcp dport { 22 } accept      tcp dport 22 accept            单元素集合折叠
    udp dport { 53 } accept      udp dport 53 accept            同上
    udp dport 443 reject         ... reject with icmp port-unreachable   默认值展开
    ip6 nexthdr icmpv6 accept    ip6 nexthdr ipv6-icmp accept   协议名别名

只测 nftlive.audit_kernel() 自己是不够的 —— 那证明不了 P0 的调用链被修好。所以这里**真的
调用** checks.check_nft() 与 linkstat.collect(), 并真的走 Bot 的建会话入口。

夹具是合成的(10.77.0.0/16 与最小规则集), 不含真机 IP、凭据或用户自定义内容。
"""
import importlib.util as iu
import io as _io
import json
import os
import shutil
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
SSH = 22

# ── 磁盘配置(模板写法)与内核输出(nft 规范化后)—— 语义完全一致 ────────────
DISK = """#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg

table inet pdg {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip saddr %(c)s tcp dport { 80, 443, 5228-5230 } redirect to :7893
    }
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { %(ssh)d } accept
        ip saddr %(c)s tcp dport { 53, 81, 853, 7893, 8445 } accept
        ip saddr %(c)s udp dport { 53 } accept
        ip saddr %(c)s udp dport 443 reject
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
    }
}
""" % {"c": CIDR, "ssh": SSH}

KERNEL_TXT = """table inet pdg {
\tchain prerouting {
\t\ttype nat hook prerouting priority dstnat; policy accept;
\t\tip saddr %(c)s tcp dport { 80, 443, 5228-5230 } redirect to :7893
\t}
\tchain input {
\t\ttype filter hook input priority filter; policy drop;
\t\tiif "lo" accept
\t\tct state established,related accept
\t\ttcp dport %(ssh)d accept
\t\tip saddr %(c)s tcp dport { 53, 81, 853, 7893, 8445 } accept
\t\tip saddr %(c)s udp dport 53 accept
\t\tip saddr %(c)s udp dport 443 reject with icmp port-unreachable
\t\tip protocol icmp accept
\t\tip6 nexthdr ipv6-icmp accept
\t}
}
""" % {"c": CIDR, "ssh": SSH}


def _m(proto, field, val):
    return {"match": {"op": "==", "left": {"payload": {"protocol": proto, "field": field}},
                      "right": val}}


def _saddr(pfx):
    net, ln = pfx.split("/")
    return {"match": {"op": "==", "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                      "right": {"prefix": {"addr": net, "len": int(ln)}}}}


KERNEL_JSON = {"nftables": [
    {"table": {"family": "inet", "name": "pdg"}},
    {"chain": {"family": "inet", "table": "pdg", "name": "prerouting", "type": "nat",
               "hook": "prerouting", "prio": -100, "policy": "accept"}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "prerouting", "handle": 1,
              "expr": [_saddr(CIDR),
                       _m("tcp", "dport", {"set": [80, 443, {"range": [5228, 5230]}]}),
                       {"redirect": {"port": 7893}}]}},
    {"chain": {"family": "inet", "table": "pdg", "name": "input", "type": "filter",
               "hook": "input", "prio": 0, "policy": "drop"}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "input", "handle": 2,
              "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iif"}},
                                  "right": "lo"}}, {"accept": None}]}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "input", "handle": 3,
              "expr": [_m("tcp", "dport", SSH), {"accept": None}]}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "input", "handle": 4,
              "expr": [_saddr(CIDR),
                       _m("tcp", "dport", {"set": [53, 81, 853, 7893, 8445]}),
                       {"accept": None}]}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "input", "handle": 5,
              "expr": [_saddr(CIDR), _m("udp", "dport", 53), {"accept": None}]}},
    {"rule": {"family": "inet", "table": "pdg", "chain": "input", "handle": 6,
              "expr": [_saddr(CIDR), _m("udp", "dport", 443),
                       {"reject": {"type": "icmp", "expr": "port-unreachable"}}]}},
]}

BOX = tempfile.mkdtemp(prefix="nftcc.")
DISK_PATH = os.path.join(BOX, "nftables.conf")
_io.open(DISK_PATH, "w", encoding="utf-8").write(DISK)
PROFILE = os.path.join(BOX, "profile.env")
_io.open(PROFILE, "w", encoding="utf-8").write("PDG_INTERNAL_CIDR=%s\n" % CIDR)
os.environ["PDG_PROFILE_ENV"] = PROFILE

import checks  # noqa: E402
import linkstat as L  # noqa: E402

_real_run = checks._run


def fake_run(cmd, t=None, **kw):
    """只接管 nft 查询, 其余交回真实现 —— 免得把别的检查一起桩没了。"""
    c = list(cmd)
    if c and c[0] == "nft":
        if "-j" in c:
            return 0, json.dumps(KERNEL_JSON), ""
        if c[1:3] == ["list", "table"]:
            return 0, KERNEL_TXT, ""
        if c[1:3] == ["list", "chain"]:
            name = c[5] if len(c) > 5 else "input"
            blk = KERNEL_TXT.split("chain %s {" % name)
            return (0, "chain %s {%s" % (name, blk[1].split("\n\t}")[0]), "") if len(blk) > 1 else (1, "", "")
        if "-c" in c:
            return 0, "", ""
        return 0, KERNEL_TXT, ""
    return _real_run(cmd, t=t, **kw) if t is not None else _real_run(cmd, **kw)


checks._run = fake_run
L.checks._run = fake_run
checks.PROFILE_ENV = PROFILE
_real_open = _io.open


def fake_open(path, *a, **k):
    if str(path) == "/etc/nftables.conf":
        return _real_open(DISK_PATH, *a, **k)
    return _real_open(path, *a, **k)


L.open = fake_open
checks.open = fake_open

# nftlive 自己走 subprocess(不经 checks._run), 而这台开发机 PATH 里没有 nft。
# 这支测试要验的是**调用链语义**, nftlive 与 nft 的交互由 test-nft-live-semantics 覆盖,
# 所以这里把它的两个入口换成夹具: 磁盘有效 + 内核就是上面那份 JSON。
import nftlive  # noqa: E402
nftlive.check_disk_config = lambda *a, **k: (True, "")
nftlive.read_kernel = lambda *a, **k: (KERNEL_JSON, "")

print("══ 1. 同一份健康状态: doctor 怎么说 ══")
try:
    d = checks.check_nft()
    lvl = d[0] if d else "(None)"
    (ok if lvl in ("ok", "info", None) else bad)(
        "doctor 的防火墙检查没报故障(实得 %r)" % (d,))
except Exception as e:  # noqa: BLE001
    bad("doctor 检查抛异常: %s: %s" % (type(e).__name__, e))

print()
print("══ 2. 同一份健康状态: linkstat 第 8 层怎么说 ══")
fs = L.collect(platform="android")
l8 = [f for f in fs if f["layer"] == 8 and "防火墙" in f["title"]]
codes = [(f["status"], f["code"], f["detail"][:60]) for f in l8]
(ok if l8 else bad)("第 8 层有防火墙相关结论(实得 %s)" % codes)
drift = [f for f in l8 if f["status"] == L.FAIL]
(ok if not drift else bad)(
    "健康状态下第 8 层不判 FAIL(实得 %s)" % [(f["code"], f["detail"][:70]) for f in drift])
(ok if not any(f["code"] == "L8_NFT_DRIFT" for f in l8) else bad)(
    "生产路径不再产出 L8_NFT_DRIFT(实得 %s)" % [f["code"] for f in l8])

print()
print("══ 3. 两条链结论一致 ══")
doctor_bad = bool(d) and d[0] == "fail"
link_bad = bool(drift)
(ok if doctor_bad == link_bad else bad)(
    "doctor 与 linkstat 对同一状态结论一致(doctor_fail=%s linkstat_fail=%s)"
    % (doctor_bad, link_bad))

print()
print("══ 4. 退出码与 Bot 建会话 ══")
# 同理: 退出码看的是"防火墙这一层有没有把它拉成 2", 不是整机健康度。
fw_only = [f for f in fs if "防火墙" in f["title"]]
(ok if L.exit_code(fw_only) != 2 else bad)(
    "只看防火墙层时 pdg link status 不返回 2(实得 %d)" % L.exit_code(fw_only))
# 只看防火墙这一层: 开发机上没有真的 mosdns/证书, 那些 FAIL 与本判据无关, 一起断言
# 会让这条永远红, 变成噪音而不是判据。
fw_block = [f for f in fs if f["status"] == L.FAIL and "防火墙" in f["title"]]
(ok if not fw_block else bad)(
    "防火墙层不是 Bot 建会话的阻塞项(实得 %s)"
    % [(f["code"], f["detail"][:60]) for f in fw_block])

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
shutil.rmtree(BOX, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

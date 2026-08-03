#!/usr/bin/env python3
"""nftables 运行态的**语义**判据 —— doctor 与 linkstat 共用这一份。

为什么不是"磁盘与内核逐条比对": nft 输出时会自己规范化写法, 同一条规则两边长得不一样 ——
单元素集合折叠成标量、`reject` 补上默认的 `with icmp port-unreachable`、`icmpv6` 归一成
`ipv6-icmp`。拿两种写法做字符串集合差, 结论必然是"磁盘有、内核没有", 而规则其实一条不少。
`.153` 真机就是这么被判成红的, 而同机 doctor 是绿的 —— 两套检查对同一台健康机器给出相反
结论, 错的是文本那一套。

能不能把磁盘配置也规范化后再比? 实测 nft v1.0.6:
  · `nft -c -f FILE`     只做语法检查, 不产出任何 JSON;
  · `nft -c -j -f FILE`  rc=0 但 stdout **0 字节** —— `-j` 是给 `list` 的, 不是给 `-f` 的;
  · `nft -j -f FILE`     同样 0 字节, 而且**真的会应用到内核**;
  · `nft -j list …`      只对 live kernel 输出, 且已经是规范化后的形态。
也就是说, 候选配置的规范化 JSON **拿不到, 除非真的加载它**。而加载要么污染宿主机内核、
要么每次自检建 netns —— 两者都越过了 linkstat 已验收的只读边界(零写入、无写锁、不留临时
内核状态)。所以"全量逐条审计"这件事本阶段做不到, 明确移交后续阶段, 不用文本近似冒充。

本模块因此只判两件**各自成立**的事实:
  1. 磁盘配置有效     —— 语法过 `nft -c`, 且项目管理块在(交给调用方用现有扫描器判);
  2. 内核必需规则已生效 —— 读 live kernel 的 JSON, 按表达式判项目运行必需的不变量。

只读: 只跑 `nft -j list table …`。不写盘、不取锁、不开事务、不建 netns、不跑 `nft -f`。
"""
import json
import os
import subprocess

TABLE_FAMILY = "inet"
TABLE_NAME = "pdg"

# 手机链路必需的入站放行端口(来源必须限定在内网卡段):
#   53  DNS      853 DoT      81 链路诊断的 HTTP 探测入口(6.1B 起两平台公共)
#   7893 mihomo redir 入口    8445 救援平面
# 少任何一个, 手机那条路就有一段不通, 而用户只会看到"连不上"。
# 取自 deploy/firewall/nftables-mihomo.conf 的 input 链(唯一真源), 不是凭印象列的:
#   ip saddr <CIDR> tcp dport { 53, 81, 853, 7893, 8445 } accept
#   53 DNS · 81 链路诊断 HTTP 探测(6.1B 起两平台公共) · 853 DoT
#   7893 mihomo redir 的落点(80/443 在 prerouting 被改写到这里) · 8445 救援平面
REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893, 8445)
# UDP 53 单独列: 手机的普通 DNS 查询走 UDP, 少了它整条链路第一步就断。以前 doctor 只查
# "敏感端口有没有对全网开放", 根本不看必需规则在不在 —— 于是把 udp 53 写成 tcp 53 这种
# 错误两套检查都发现不了(测试里那一格就是这么红的)。
REQUIRED_INTERNAL_UDP = (53,)
# 这些端口若出现在放行里, 来源必须限定 —— 对全网开放等于把网关变成开放中继。
SENSITIVE_PORTS = frozenset({53, 80, 81, 443, 853, 5228, 5229, 5230, 7893, 8445})


class Audit(object):
    """判定结果。ok=True 表示必需不变量都成立; problems 逐条说清缺什么。"""

    def __init__(self):
        self.ok = True
        self.problems = []
        self.details = []

    def fail(self, msg):
        self.ok = False
        self.problems.append(msg)

    def note(self, msg):
        self.details.append(msg)

    def __repr__(self):
        return "Audit(ok=%r, problems=%r)" % (self.ok, self.problems)


def read_kernel(family=TABLE_FAMILY, table=TABLE_NAME, runner=None):
    """读 live kernel 的 JSON。返回 (obj, err)。**只读**。

    runner 只为测试注入; 生产走 subprocess。取不到时返回 (None, 原因) —— 由调用方
    fail-closed, 绝不当成"没问题"。
    """
    cmd = ["nft", "-j", "list", "table", family, table]
    try:
        if runner is not None:
            rc, out = runner(cmd)
        else:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            rc, out = p.returncode, p.stdout
    except Exception as e:  # noqa: BLE001
        return None, "执行 nft 失败(%s)" % type(e).__name__
    if rc != 0:
        return None, "nft 返回非零(%s)" % rc
    if not (out or "").strip():
        return None, "nft 没有输出"
    try:
        return json.loads(out), ""
    except ValueError:
        return None, "nft 输出不是合法 JSON"


# ── 表达式解析: 只认语义, 不认写法 ──────────────────────────────────────────
def _payload(e):
    m = e.get("match") or {}
    left = m.get("left") or {}
    return (left.get("payload") or {}), m


def _saddr_prefix(expr):
    """这条规则限定的来源前缀, 形如 '10.0.0.0/8'; 没限定返回 None。"""
    for e in expr:
        pl, m = _payload(e)
        if pl.get("field") == "saddr":
            r = m.get("right")
            if isinstance(r, dict) and "prefix" in r:
                return "%s/%s" % (r["prefix"]["addr"], r["prefix"]["len"])
            if isinstance(r, str):
                return r
    return None


def _dports(expr):
    """(协议, 端口集合)。集合折叠与否、顺序如何, 这里都归一成 set —— 这正是文本比对
    做不到的那一步。"""
    for e in expr:
        pl, m = _payload(e)
        if pl.get("field") != "dport":
            continue
        proto = pl.get("protocol")
        r = m.get("right")
        if isinstance(r, int):
            return proto, {r}
        if isinstance(r, dict) and "set" in r:
            out = set()
            for item in r["set"]:
                if isinstance(item, int):
                    out.add(item)
                elif isinstance(item, dict) and "range" in item:
                    a, b = item["range"]
                    out.update(range(int(a), int(b) + 1))
            return proto, out
        if isinstance(r, str) and r.isdigit():
            return proto, {int(r)}
    return None, set()


def _verdict(expr):
    """accept / drop / reject / redirect / … —— reject 无论有没有写 `with icmp …`
    都归一成 'reject'(默认展开不算差异)。"""
    for e in expr:
        for k in ("accept", "drop", "reject", "redirect", "jump", "goto", "return",
                  "masquerade", "dnat", "snat", "queue", "continue"):
            if k in e:
                return k
    return None


def _rules_of(obj, chain):
    out = []
    for o in (obj or {}).get("nftables", []):
        r = o.get("rule")
        if r and r.get("chain") == chain:
            out.append(r.get("expr") or [])       # handle 一律不看
    return out


def _chain_meta(obj, chain):
    for o in (obj or {}).get("nftables", []):
        c = o.get("chain")
        if c and c.get("name") == chain:
            return c
    return None


def _has_table(obj, family=TABLE_FAMILY, table=TABLE_NAME):
    for o in (obj or {}).get("nftables", []):
        t = o.get("table")
        if t and t.get("family") == family and t.get("name") == table:
            return True
    return False


def audit_kernel(obj, cidr, platform="android", family=TABLE_FAMILY, table=TABLE_NAME):
    """内核里项目运行必需的不变量是否成立。obj = `nft -j list table …` 的解析结果。

    判的是语义: 端口集合归一、reject 默认展开归一、协议别名由 nft 自己归一、handle 忽略。
    顺序只在**会改变行为**时看 —— 必需放行若排在一条无条件 drop 之后, 它永远轮不到。
    """
    a = Audit()
    if not _has_table(obj, family, table):
        a.fail("内核里没有 %s %s 表" % (family, table))
        return a
    meta = _chain_meta(obj, "input")
    if not meta:
        a.fail("内核里没有 input 链")
        return a
    if meta.get("hook") != "input":
        a.fail("input 链的 hook 不是 input(实得 %r)" % meta.get("hook"))
    if meta.get("policy") != "drop":
        a.fail("input 链的 policy 不是 drop(实得 %r) —— 默认放行等于门没关"
               % meta.get("policy"))

    rules = _rules_of(obj, "input")
    if not rules:
        a.fail("input 链里一条规则都没有")
        return a

    # 无条件 drop 的位置: 排在它后面的放行永远轮不到
    cut = len(rules)
    for i, ex in enumerate(rules):
        if _verdict(ex) == "drop" and not _saddr_prefix(ex) and not _dports(ex)[1]:
            cut = i
            break

    want = set(REQUIRED_INTERNAL_TCP)
    got, misplaced, bad_src = set(), set(), set()
    for i, ex in enumerate(rules):
        proto, ports = _dports(ex)
        if proto != "tcp" or not ports:
            continue
        hit = ports & want
        if not hit:
            continue
        if _verdict(ex) != "accept":
            a.fail("端口 %s 的规则不是放行(实得 %s)"
                   % (",".join(str(p) for p in sorted(hit)), _verdict(ex)))
            continue
        src = _saddr_prefix(ex)
        if src != cidr:
            bad_src |= hit
            a.note("端口 %s 的来源是 %r, 期望 %r" % (sorted(hit), src, cidr))
            continue
        if i > cut:
            misplaced |= hit
            continue
        got |= hit

    miss = want - got - misplaced - bad_src
    if miss:
        a.fail("内核缺少必需放行: tcp %s(来源应限 %s)"
               % (", ".join(str(p) for p in sorted(miss)), cidr))
    if bad_src:
        a.fail("端口 %s 的来源网段不是配置的内网卡段(%s)"
               % (", ".join(str(p) for p in sorted(bad_src)), cidr))
    if misplaced:
        a.fail("端口 %s 的放行规则顺序错: 排在无条件 drop 之后, 永远轮不到"
               % ", ".join(str(p) for p in sorted(misplaced)))

    # UDP 必需放行(与 TCP 同样口径: 来源限内网段、必须是 accept、不能排在无条件 drop 之后)
    want_u = set(REQUIRED_INTERNAL_UDP)
    got_u, mis_u, bad_u = set(), set(), set()
    for i, ex in enumerate(rules):
        proto, ports = _dports(ex)
        if proto != "udp" or not ports:
            continue
        hit = ports & want_u
        if not hit:
            continue
        if _verdict(ex) != "accept":
            continue                      # udp 443 reject 是有意的, 不算"必需放行"
        src = _saddr_prefix(ex)
        if src != cidr:
            bad_u |= hit
            continue
        if i > cut:
            mis_u |= hit
            continue
        got_u |= hit
    miss_u = want_u - got_u - mis_u - bad_u
    if miss_u:
        a.fail("内核缺少必需放行: udp %s(来源应限 %s) —— 手机的普通 DNS 查询走这条"
               % (", ".join(str(p) for p in sorted(miss_u)), cidr))
    if bad_u:
        a.fail("udp %s 的来源网段不是配置的内网卡段(%s)"
               % (", ".join(str(p) for p in sorted(bad_u)), cidr))
    if mis_u:
        a.fail("udp %s 的放行规则顺序错: 排在无条件 drop 之后"
               % ", ".join(str(p) for p in sorted(mis_u)))

    # ── prerouting 的 REDIRECT: 手机的 80/443 靠它进 mihomo ──────────────────
    # 模板: ip saddr <CIDR> tcp dport { 80, 443, 5228-5230 } redirect to :7893
    # iOS 装机时 install.sh 会把 5228-5230 摘掉(走 APNs 不需要 GMS), 所以 5228-5230
    # **按平台判**: Android 必需, iOS 不要求也不禁止。80/443 两平台都必需 —— 少了它们
    # 手机的网页流量根本进不了内核, 而 input 链看起来一切正常。
    pre_meta = _chain_meta(obj, "prerouting")
    if not pre_meta:
        a.fail("内核里没有 prerouting 链 —— 手机的 80/443 无法改写进 mihomo")
    else:
        if pre_meta.get("hook") != "prerouting":
            a.fail("prerouting 链的 hook 不是 prerouting(实得 %r)" % pre_meta.get("hook"))
        if pre_meta.get("type") != "nat":
            a.fail("prerouting 链的 type 不是 nat(实得 %r)" % pre_meta.get("type"))
        pre = _rules_of(obj, "prerouting")
        want_r = {80, 443} | ({5228, 5229, 5230} if platform != "ios" else set())
        got_r, badsrc_r = set(), set()
        for ex in pre:
            proto, ports = _dports(ex)
            if proto != "tcp" or not ports:
                continue
            hit = ports & want_r
            if not hit:
                continue
            if _verdict(ex) != "redirect":
                a.fail("端口 %s 在 prerouting 里不是 redirect(实得 %s)"
                       % (", ".join(str(p) for p in sorted(hit)), _verdict(ex)))
                continue
            if _saddr_prefix(ex) != cidr:
                badsrc_r |= hit
                continue
            got_r |= hit
        miss_r = want_r - got_r - badsrc_r
        if miss_r:
            a.fail("prerouting 缺少必需的 redirect: tcp %s → mihomo(来源应限 %s)"
                   % (", ".join(str(p) for p in sorted(miss_r)), cidr))
        if badsrc_r:
            a.fail("prerouting 里 tcp %s 的来源网段不是配置的内网卡段(%s)"
                   % (", ".join(str(p) for p in sorted(badsrc_r)), cidr))

    # 敏感端口不得对全网放行(这条与 doctor 原有判据同语义, 现在两边共用)
    leaked = set()
    for ex in rules:
        if _verdict(ex) != "accept" or _saddr_prefix(ex):
            continue
        _proto, ports = _dports(ex)
        leaked |= (ports & SENSITIVE_PORTS)
    if leaked:
        a.fail("这些端口对全网放行(应只限内网卡来源): %s"
               % ", ".join(str(p) for p in sorted(leaked)))
    return a


def audit_live(cidr, platform="android", runner=None):
    """生产入口: 读 live kernel 再判。取不到内核状态一律 fail-closed。"""
    obj, err = read_kernel(runner=runner)
    if obj is None:
        a = Audit()
        a.fail("无法读取内核防火墙状态: %s" % err)
        return a
    return audit_kernel(obj, cidr=cidr, platform=platform)

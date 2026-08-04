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
DISK_CONF = "/etc/nftables.conf"
# nft 二进制。调用方可以显式传别的路径(测试夹具、非标准安装), 但默认只认 PATH 里的 nft ——
# 这里不去猜 /usr/sbin/nft 之类的绝对路径, 猜错会在只有 sbin 不在 PATH 的机器上静默失败。
NFT_BIN = "nft"

# **手机链路核心**的入站放行端口(来源必须限定在内网卡段)。少任何一个, 手机那条路就有一段
# 不通, 而用户只会看到"连不上" —— 所以它们是创建手机链路测试会话的硬门。
#   53   DNS(mosdns)
#   81   链路诊断的 HTTP 探测入口(6.1B 起 Android/iOS 公共)
#   853  DoT
#   7893 mihomo 的 redir 落点 —— 80/443 在 prerouting 被改写到这里
#
# 模板那一行是 `tcp dport { 53, 81, 853, 7893, 8445 } accept`, 但 **8445 不在这份清单里**:
# 查过真源(lib/rescue.sh:19 与 CHANGELOG)—— 8445 是 **Telegram SOCKS5**(mihomo 的 mixed
# 监听, TG 内置代理填 网关IP:8445), 救援平面是 **8446**(PDG_RESCUE_PORT 默认值, 模板里
# 单独一行 `tcp dport __RESCUE_PORT__ accept`)。我上一轮把 8445 注成"救援平面", 是错的。
# TG SOCKS5 与救援平面都是可选功能: 它们不通不会让"HTTP 探测到没到达网关"这个结论失真,
# 因此由 doctor 点名即可, 不该挡住基础链路测试。
REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893)
# doctor 关心、但**不进链路硬门**的入站端口。名字要说清这层意思 —— 上一版叫
# OPTIONAL_INTERNAL_TCP, 读起来像"这些端口可有可无", 而实际含义是"缺了要报, 但不该拦住
# 手机链路测试"。8445 在标准安装里是恒定渲染的, 缺了确实该 FAIL, 只是不该挡会话。
#
# 8446(救援平面)**不在这里**: 它的端口是动态的(rescue_const.port()), 且只有配了
# PDG_RESCUE_BIND 才启用 —— 写死进固定集合会让"救援关着"的机器被误报缺规则。
# 9090 也不在这里: 它默认绑 127.0.0.1(mihomorender 的 external_controller), 走回环,
# 根本不需要 nft input 放行, 放进来就是凭空要求一条不存在的规则。
DOCTOR_ONLY_INTERNAL_TCP = {8445: "Telegram SOCKS5"}
# UDP 53 单独列: 手机的普通 DNS 查询走 UDP, 少了它整条链路第一步就断。以前 doctor 只查
# "敏感端口有没有对全网开放", 根本不看必需规则在不在 —— 于是把 udp 53 写成 tcp 53 这种
# 错误两套检查都发现不了(测试里那一格就是这么红的)。
REQUIRED_INTERNAL_UDP = (53,)
# prerouting 里必须被改写进 mihomo 的端口。80/443 是**手机网页流量的入口**, 两平台都必需;
# GMS 5228-5230 只在 Android 上存在(iOS 装机时 install.sh 就把它摘了), 且属于 doctor 专项。
REDIRECT_TCP = (80, 443)
GMS_TCP = (5228, 5229, 5230)
# prerouting 的改写目标 —— 装机固定 7893。真源是 mihomo 配置里的 redir-port, 调用方
# (doctor / linkstat)读一次后显式传进 audit_kernel; 这里只是读不到时的兜底默认值。
REDIR_PORT = 7893
# 这些端口若出现在放行里, 来源必须限定 —— 对全网开放等于把网关变成开放中继。
SENSITIVE_PORTS = frozenset({53, 80, 81, 443, 853, 5228, 5229, 5230, 7893, 8445})


class Issue(str):
    """一条判定结论 —— 就是它的中文说明, 外加一个 kind 标签。

    继承 str 是为了不给调用方添麻烦: 已有的 `"; ".join(audit.problems)` 一类写法照旧,
    而需要分派的调用方(doctor 要把"代理入口"那条交给 check_redirect、把 GMS 那条交给
    check_gms, 免得同一个根因在报告里出现两次)可以按 kind 精确挑, 不用再去猜文案里有没有
    "顺序"两个字 —— 靠文案关键字分类, 改一次措辞就会静默错档。
    """

    def __new__(cls, msg, kind):
        o = str.__new__(cls, msg)
        o.kind = kind
        return o


# kind 取值(闭集, 加新值要同时想清楚 doctor 那边谁认领它):
#   table    表/链本身的结构问题(不存在、hook/type/policy 不对)
#   missing  必需放行缺失
#   source   放行存在, 但来源网段不是内网卡段
#   order    放行存在, 但排在无条件 drop/reject 之后, 永远轮不到
#   verdict  规则命中了端口, 但动作不是该有的那个
#   leak     敏感端口对全网放行
#   redirect prerouting 里 80/443 → mihomo 的改写(核心链路)
#   gms      Android GMS 5228-5230 的改写(doctor 专项)
#   socks    Telegram SOCKS5 8445 的放行(doctor 专项)
KINDS = ("table", "missing", "source", "order", "verdict", "leak", "redirect", "gms", "socks")


class Audit(object):
    """判定结果 —— 同一份事实, 两个调用方按**范围**各取所需。

    分两档, 因为"防火墙有问题"和"手机链路做不了测试"不是一回事:

      problems(link_required)  少了它手机主链路就有一段不通 → linkstat 判 FAIL 并挡住
                               创建测试会话; doctor 也报。
      doctor_issues            专项功能的规则不对(TG SOCKS5、Android GMS 推送…)。
                               doctor 该点名, 但**不该挡住基础 HTTP 链路测试** —— 那次测试
                               本来就只证明"HTTP 请求到没到达网关", 从不声称 Google Play
                               或推送正常, 所以拿 GMS 去挡它是拿不相干的事阻断诊断。

    ok 只看 link_required: 调用方要展示专项问题就读 doctor_issues, 不用再解析一遍规则。
    """

    def __init__(self):
        self.ok = True
        self.problems = []
        self.doctor_issues = []
        self.details = []
        # 真正走到过的判据区域。空集合与"这块没问题"不是一回事: 表都不存在时 prerouting
        # 根本没查过, 调用方若把"没有 redirect 问题"读成"redirect 正常", 就是把读不到当成绿灯。
        self.evaluated = set()

    def fail(self, msg, kind):
        """链路硬门失败。"""
        self.ok = False
        self.problems.append(Issue(msg, kind))

    def doctor_fail(self, msg, kind):
        """专项功能失败: doctor 展示, 但不影响 ok, 因而不挡手机链路测试。"""
        self.doctor_issues.append(Issue(msg, kind))

    def note(self, msg):
        self.details.append(msg)

    def of_kind(self, *kinds):
        """按 kind 取 —— doctor 用它把同一份判定分派给各自的检查项, 一个根因只报一次。"""
        k = set(kinds)
        return [i for i in self.problems + self.doctor_issues if i.kind in k]

    def __repr__(self):
        return "Audit(ok=%r, problems=%r)" % (self.ok, list(map(str, self.problems)))


def read_kernel(family=TABLE_FAMILY, table=TABLE_NAME, runner=None, nft_bin=NFT_BIN):
    """读 live kernel 的 JSON。返回 (obj, err)。**只读**。

    runner(cmd) → (rc, stdout, stderr), 由调用方注入 —— doctor 传自己那个 `_run`, 于是
    "这轮 doctor 到底发了几条 nft 命令"是可数的; 不传就走 subprocess。取不到时返回
    (None, 原因) —— 由调用方 fail-closed, 绝不当成"没问题"。
    """
    cmd = [nft_bin, "-j", "list", "table", family, table]
    try:
        if runner is not None:
            rc, out, _err = runner(cmd)
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


def _redirect_port(expr):
    """redirect 的目标端口; 不是 redirect 或没写端口返回 None。

    nft 的 JSON 里这个值可能是 int 也可能是字符串, 还可能整个 redirect 只是 `{"redirect": null}`
    (`redirect` 不带端口 = 保持原端口)—— 三种都要认, 不能只认自己写测试时用的那一种。
    """
    for e in expr:
        if "redirect" not in e:
            continue
        r = e["redirect"]
        if isinstance(r, dict):
            p = r.get("port")
            if isinstance(p, int):
                return p
            if isinstance(p, str) and p.isdigit():
                return int(p)
        return None
    return None


def _first_redirect_port(rules, ports):
    """报文案用: 这批端口实际被改写到了哪个口(取第一条命中的)。"""
    for ex in rules:
        _proto, got = _dports(ex)
        if got & ports:
            return _redirect_port(ex)
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


def audit_kernel(obj, cidr, platform="android", family=TABLE_FAMILY, table=TABLE_NAME,
                 redir_port=REDIR_PORT):
    """内核里项目运行必需的不变量是否成立。obj = `nft -j list table …` 的解析结果。

    判的是语义: 端口集合归一、reject 默认展开归一、协议别名由 nft 自己归一、handle 忽略。
    顺序只在**会改变行为**时看 —— 必需放行若排在一条无条件 drop 之后, 它永远轮不到。

    redir_port 由调用方从真源(mihomo 配置的 redir-port)读一次后传进来 —— 本模块不自己去
    翻配置文件, 免得同一个事实在项目里出现第二份。
    """
    a = Audit()
    if not _has_table(obj, family, table):
        a.fail("内核里没有 %s %s 表" % (family, table), "table")
        return a
    meta = _chain_meta(obj, "input")
    if not meta:
        a.fail("内核里没有 input 链", "table")
        return a
    a.evaluated.add("input")
    if meta.get("hook") != "input":
        a.fail("input 链的 hook 不是 input(实得 %r)" % meta.get("hook"), "table")
    if meta.get("type") != "filter":
        a.fail("input 链的 type 不是 filter(实得 %r)" % meta.get("type"), "table")
    if meta.get("policy") != "drop":
        a.fail("input 链的 policy 不是 drop(实得 %r) —— 默认放行等于门没关"
               % meta.get("policy"), "table")

    rules = _rules_of(obj, "input")
    if not rules:
        a.fail("input 链里一条规则都没有", "missing")
        return a

    # 无条件 drop/reject 的位置: 排在它后面的放行永远轮不到。reject 也要算 —— 它同样终结
    # 这条报文的处理, 只是多回一个 ICMP; 只认 drop 会漏掉"必需放行被一条兜底 reject 挡死"。
    cut = len(rules)
    for i, ex in enumerate(rules):
        if (_verdict(ex) in ("drop", "reject") and not _saddr_prefix(ex)
                and not _dports(ex)[1]):
            cut = i
            break

    # 核心必需端口与 doctor 专项端口一起扫(同一批规则), 出结论时再按范围分开 —— 分两遍扫
    # 等于把同一份解析写两次, 而这正是这次要消灭的东西。
    want_core = set(REQUIRED_INTERNAL_TCP)
    want_extra = set(DOCTOR_ONLY_INTERNAL_TCP)
    want = want_core | want_extra
    got, misplaced, bad_src, leaked_t = set(), set(), set(), set()
    for i, ex in enumerate(rules):
        proto, ports = _dports(ex)
        if proto != "tcp" or not ports:
            continue
        hit = ports & want
        if not hit:
            continue
        if _verdict(ex) != "accept":
            core_hit, extra_hit = hit & want_core, hit & want_extra
            if core_hit:
                a.fail("端口 %s 的规则不是放行(实得 %s)"
                       % (",".join(str(p) for p in sorted(core_hit)), _verdict(ex)), "verdict")
            for p in sorted(extra_hit):
                a.doctor_fail("%s 的端口 %d 规则不是放行(实得 %s)"
                              % (DOCTOR_ONLY_INTERNAL_TCP[p], p, _verdict(ex)), "socks")
            continue
        src = _saddr_prefix(ex)
        if src is None:
            # 来源完全没限定 = 对全网开放。这与"来源写错了网段"是同一条规则的两种毛病, 但
            # 根因只有一个, 下面统一按 leak 报一次, 不要在 source 那边再报第二次。
            leaked_t |= hit
            continue
        if src != cidr:
            bad_src |= hit
            a.note("端口 %s 的来源是 %r, 期望 %r" % (sorted(hit), src, cidr))
            continue
        if i > cut:
            misplaced |= hit
            continue
        got |= hit

    def _split(s):
        return s & want_core, s & want_extra

    def _names(s):
        return ", ".join("%d(%s)" % (p, DOCTOR_ONLY_INTERNAL_TCP[p]) for p in sorted(s))

    miss = want - got - misplaced - bad_src - leaked_t
    miss_c, miss_e = _split(miss)
    if miss_c:
        a.fail("内核缺少必需放行: tcp %s(来源应限 %s)"
               % (", ".join(str(p) for p in sorted(miss_c)), cidr), "missing")
    if miss_e:
        a.doctor_fail("内核缺少 tcp %s 的放行(来源应限 %s)" % (_names(miss_e), cidr), "socks")
    bad_c, bad_e = _split(bad_src)
    if bad_c:
        a.fail("端口 %s 的来源网段不是配置的内网卡段(%s)"
               % (", ".join(str(p) for p in sorted(bad_c)), cidr), "source")
    if bad_e:
        a.doctor_fail("tcp %s 的来源网段不是配置的内网卡段(%s)" % (_names(bad_e), cidr), "socks")
    mis_c, mis_e = _split(misplaced)
    if mis_c:
        a.fail("端口 %s 的放行规则顺序错: 排在无条件 drop 之后, 永远轮不到"
               % ", ".join(str(p) for p in sorted(mis_c)), "order")
    if mis_e:
        a.doctor_fail("tcp %s 的放行排在无条件 drop 之后, 永远轮不到" % _names(mis_e), "socks")

    # UDP 必需放行(与 TCP 同样口径: 来源限内网段、必须是 accept、不能排在无条件 drop 之后)
    want_u = set(REQUIRED_INTERNAL_UDP)
    got_u, mis_u, bad_u, leaked_u = set(), set(), set(), set()
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
        if src is None:
            # 同上: 无来源限定统一按 leak 报一次。这个集合必须与 TCP 那个分开 —— 端口号
            # 在两个协议里各算各的, 共用一个会让"tcp 53 对全网开着"顺手把"udp 53 根本没有"
            # 这条真故障吞掉。
            leaked_u |= hit
            continue
        if src != cidr:
            bad_u |= hit
            continue
        if i > cut:
            mis_u |= hit
            continue
        got_u |= hit
    miss_u = want_u - got_u - mis_u - bad_u - leaked_u
    if miss_u:
        a.fail("内核缺少必需放行: udp %s(来源应限 %s) —— 手机的普通 DNS 查询走这条"
               % (", ".join(str(p) for p in sorted(miss_u)), cidr), "missing")
    if bad_u:
        a.fail("udp %s 的来源网段不是配置的内网卡段(%s)"
               % (", ".join(str(p) for p in sorted(bad_u)), cidr), "source")
    if mis_u:
        a.fail("udp %s 的放行规则顺序错: 排在无条件 drop 之后"
               % ", ".join(str(p) for p in sorted(mis_u)), "order")

    # ── prerouting 的 REDIRECT: 手机的 80/443 靠它进 mihomo ──────────────────
    # 模板: ip saddr <CIDR> tcp dport { 80, 443, 5228-5230 } redirect to :7893
    # iOS 装机时 install.sh 会把 5228-5230 摘掉(走 APNs 不需要 GMS), 所以 5228-5230
    # **按平台判**: Android 必需, iOS 不要求也不禁止。80/443 两平台都必需 —— 少了它们
    # 手机的网页流量根本进不了内核, 而 input 链看起来一切正常。
    pre_meta = _chain_meta(obj, "prerouting")
    if not pre_meta:
        a.fail("内核里没有 prerouting 链 —— 手机的 80/443 无法改写进 mihomo", "redirect")
    else:
        a.evaluated.add("prerouting")
        if pre_meta.get("hook") != "prerouting":
            a.fail("prerouting 链的 hook 不是 prerouting(实得 %r)" % pre_meta.get("hook"),
                   "table")
        if pre_meta.get("type") != "nat":
            a.fail("prerouting 链的 type 不是 nat(实得 %r)" % pre_meta.get("type"), "table")
        pre = _rules_of(obj, "prerouting")
        # 80/443 是链路硬门; GMS 5228-5230 只在 Android 上算**专项**(见下)。两者都要扫,
        # 所以先合起来找, 出结论时再按范围分开。
        gms_want = set(GMS_TCP) if platform != "ios" else set()
        want_r = set(REDIRECT_TCP) | gms_want
        got_r, badsrc_r, badport_r = set(), set(), set()
        for ex in pre:
            proto, ports = _dports(ex)
            if proto != "tcp" or not ports:
                continue
            hit = ports & want_r
            if not hit:
                continue
            if _verdict(ex) != "redirect":
                a.fail("端口 %s 在 prerouting 里不是 redirect(实得 %s)"
                       % (", ".join(str(p) for p in sorted(hit)), _verdict(ex)), "redirect")
                continue
            if _saddr_prefix(ex) != cidr:
                badsrc_r |= hit
                continue
            # 改写目标必须是 mihomo 真正在监听的那个口。以前只看"是不是 redirect" ——
            # 改到一个没人听的端口, 规则形态完全正常, 手机却全线连不上。
            if _redirect_port(ex) != redir_port:
                badport_r |= hit
                continue
            got_r |= hit
        miss_r = want_r - got_r - badsrc_r - badport_r
        bp_core = badport_r - gms_want
        if bp_core:
            a.fail("prerouting 里 tcp %s 被改写到 :%s, 而 mihomo 监听的是 :%d —— "
                   "端口写错等于把流量送进没人听的口"
                   % (", ".join(str(p) for p in sorted(bp_core)),
                      _first_redirect_port(pre, bp_core), redir_port), "redirect")
        bp_gms = badport_r & gms_want
        if bp_gms:
            a.doctor_fail("Android GMS 的 redirect 目标不是 mihomo 的 :%d" % redir_port, "gms")
        # 80/443 少了 = 手机网页流量进不了 mihomo → 硬门。
        miss_core = miss_r - gms_want
        if miss_core:
            a.fail("prerouting 缺少必需的 redirect: tcp %s → mihomo(来源应限 %s)"
                   % (", ".join(str(p) for p in sorted(miss_core)), cidr), "redirect")
        # GMS 少了 = Google Play 推送不走网关 —— 该报, 但**不挡**基础 HTTP 链路测试:
        # 那次测试只证明"HTTP 请求到没到达网关", 从不声称推送或 Play 正常。
        miss_gms = miss_r & gms_want
        if miss_gms:
            a.doctor_fail("prerouting 缺少 Android GMS 推送的 redirect: tcp %s → mihomo"
                          % ", ".join(str(p) for p in sorted(miss_gms)), "gms")
        bad_core = badsrc_r - gms_want
        if bad_core:
            a.fail("prerouting 里 tcp %s 的来源网段不是配置的内网卡段(%s)"
                   % (", ".join(str(p) for p in sorted(bad_core)), cidr), "redirect")
        bad_gms = badsrc_r & gms_want
        if bad_gms:
            a.doctor_fail("Android GMS 的 redirect 来源网段不是配置的内网卡段(%s)" % cidr, "gms")
    # GMS 只在"prerouting 真查过 且 平台是 Android"时才算判过。iOS 上装机就把 5228-5230
    # 摘掉了, 这件事在那边根本不成立 —— 标成判过会让 doctor 显示一条 iOS 不该有的项。
    if platform != "ios" and "prerouting" in a.evaluated:
        a.evaluated.add("gms")

    # 敏感端口不得对全网放行(这条与 doctor 原有判据同语义, 现在两边共用)
    leaked = set()
    for ex in rules:
        if _verdict(ex) != "accept" or _saddr_prefix(ex):
            continue
        _proto, ports = _dports(ex)
        leaked |= (ports & SENSITIVE_PORTS)
    if leaked:
        a.fail("这些端口对全网放行(应只限内网卡来源): %s"
               % ", ".join(str(p) for p in sorted(leaked)), "leak")
    a.evaluated.add("leak")
    return a


def check_disk_config(path=DISK_CONF, runner=None, nft_bin=NFT_BIN):
    """磁盘配置有效性 —— **只读**的 `nft -c -f`, 不加载、不改内核。

    实测(nftables v1.0.6): `nft -c -f` 只做语法/语义校验, 校验后内核里不会多出任何表;
    而 `nft -c -j -f` **不输出任何内容**(0 字节), 所以拿不到"候选配置的规范化形态" ——
    这正是本模块不做"磁盘逐条 vs 内核逐条"的原因: 要取规范形态就得真加载, 那越过了
    linkstat 只读、无副作用的边界。

    返回 (ok, 原因)。读不到、语法错、nft 不可用一律 fail-closed。
    """
    try:
        with open(path, encoding="utf-8") as f:
            f.read(1)
    except OSError as e:
        return False, "读不到 %s(%s)" % (path, type(e).__name__)
    cmd = [nft_bin, "-c", "-f", path]
    try:
        if runner is not None:
            rc, out, err = runner(cmd)
        else:
            pr = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            rc, out, err = pr.returncode, pr.stdout, pr.stderr
    except Exception as e:  # noqa: BLE001
        return False, "nft 无法执行(%s)" % type(e).__name__
    if rc != 0:
        msg = (err or out or "").strip().splitlines()
        # 只回第一行, 且不回显规则内容 —— 用户自定义规则可能含敏感信息
        head = msg[0][:120] if msg else "nft -c 返回 %d" % rc
        return False, head
    return True, ""


def audit_live(cidr, platform="android", runner=None, redir_port=REDIR_PORT):
    """生产入口: 读 live kernel 再判。取不到内核状态一律 fail-closed。"""
    obj, err = read_kernel(runner=runner)
    if obj is None:
        a = Audit()
        a.fail("无法读取内核防火墙状态: %s" % err, "table")
        return a
    return audit_kernel(obj, cidr=cidr, platform=platform, redir_port=redir_port)

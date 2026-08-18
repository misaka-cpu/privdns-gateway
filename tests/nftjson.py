#!/usr/bin/env python3
"""把项目自己的 nft 配置文本转成 `nft -j list table` 那种形状的 JSON —— 只给测试桩用。

为什么需要它: 沙箱里的 nft 是桩, 而 nftlive 读的是 `nft -j list table inet pdg` 的 JSON。
共享桩以前对 `-j` 什么都不返回, 于是 nftlive 按设计 fail-closed(读不到内核 = 不知道现在
放行了什么, 绝不当成没问题), 更新后自检判红、整次 update 回滚 —— 测出来的是桩的病。

设计上只有两条要紧的:

  1. **它是转换器, 不是常量。** 输入是 `nft -f` 真正装载过的那份文本, 输出随之变化:
     配置里删掉 tcp 81, JSON 里就没有 81, audit_kernel 就会失败。写死一份"永远健康"的
     JSON 等于把所有防火墙判据废掉, 而且废得悄无声息。
  2. **只有这一份解析。** 沙箱里已经有三支各自抄了一遍"有状态 nft 桩"(e2e-custom-nft /
     e2e-install-nft / e2e-platform-switch), 再抄第四份迟早互相漂移。e2e-lib 的共享桩
     统一调这里。

覆盖的语法就是 deploy/firewall/nftables-mihomo.conf 那套形态(它是渲染出来的, 不是手写的,
所以形态有限)。遇到不认识的行**跳过而不是猜** —— 猜出来的规则会让判据对着不存在的东西打转。
"""
import json
import re
import sys

_TABLE = re.compile(r"^\s*table\s+(?P<family>\w+)\s+(?P<name>\S+)\s*\{")
_CHAIN = re.compile(r"^\s*chain\s+(?P<name>\S+)\s*\{")
_TYPE = re.compile(r"^\s*type\s+(?P<type>\w+)\s+hook\s+(?P<hook>\w+)\s+priority\s+"
                   r"(?P<prio>[\w-]+)\s*;\s*policy\s+(?P<policy>\w+)\s*;")
_SADDR = re.compile(r"\bip\s+saddr\s+(?P<cidr>[0-9.]+/[0-9]+)")
_DADDR = re.compile(r"\bip\s+daddr\s+(?P<ip>[0-9.]+)")
_DPORT = re.compile(r"\b(?P<proto>tcp|udp)\s+dport\s+(?:\{(?P<set>[^}]*)\}|(?P<one>\d+))")
_REDIR = re.compile(r"\bredirect\s+to\s+:?(?P<port>\d+)")
# iif 与 iifname 是**两个**匹配: 前者按接口索引(加载时解析), 后者按名字(运行时比对)。
# 只认 iif 会让 `iifname "x" ...` 的接口条件被静默丢掉 —— 规则还在, 匹配没了, 而那是
# 最会骗人的失真形态: 判据按接口名去找就永远找不到, 内核里其实有。
# 先匹配 iifname(更长的那个), 否则 \biif 会先命中 iifname 的前三个字符。
_IIFNAME = re.compile(r'\biifname\s+"(?P<dev>[^"]+)"')
_IIF = re.compile(r'\biif\s+"(?P<dev>[^"]+)"')
_CT = re.compile(r"\bct\s+state\s+(?P<states>[\w,]+)")
_PROTO = re.compile(r"\bip6?\s+(?:protocol|nexthdr)\s+(?P<p>[\w-]+)")
_COMMENT = re.compile(r'\bcomment\s+"(?P<c>[^"]*)"')

_PRIO = {"dstnat": -100, "filter": 0, "srcnat": 100, "raw": -300, "mangle": -150}
_VERDICTS = ("accept", "drop", "reject", "return", "masquerade", "continue")


def _ports(spec):
    """`53, 81, 853` / `80, 443, 5228-5230` → nft JSON 的 right 值。

    单元素**不**折叠成标量: 真 nft 会折叠, 但两种形态 nftlive 都认(那正是它存在的理由),
    这里保持集合形态更贴近"配置里写了个集合"这件事本身。
    """
    out = []
    for tok in spec.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if "-" in tok:
            a, b = tok.split("-", 1)
            out.append({"range": [int(a), int(b)]})
        elif tok.isdigit():
            out.append(int(tok))
    return out


def _match(proto, field, right):
    return {"match": {"op": "==",
                      "left": {"payload": {"protocol": proto, "field": field}},
                      "right": right}}


def _rule_expr(line):
    """一行规则 → expr 列表。认不出来的返回 None(跳过, 不猜)。"""
    expr = []
    m = _IIFNAME.search(line)
    if m:
        expr.append({"match": {"op": "==", "left": {"meta": {"key": "iifname"}},
                               "right": m.group("dev")}})
    else:
        m = _IIF.search(line)
        if m:
            expr.append({"match": {"op": "==", "left": {"meta": {"key": "iif"}},
                                   "right": m.group("dev")}})
    m = _CT.search(line)
    if m:
        expr.append({"match": {"op": "in", "left": {"ct": {"key": "state"}},
                               "right": m.group("states").split(",")}})
    m = _SADDR.search(line)
    if m:
        net, ln = m.group("cidr").split("/")
        expr.append({"match": {"op": "==",
                               "left": {"payload": {"protocol": "ip", "field": "saddr"}},
                               "right": {"prefix": {"addr": net, "len": int(ln)}}}})
    m = _DADDR.search(line)
    if m:
        expr.append({"match": {"op": "==",
                               "left": {"payload": {"protocol": "ip", "field": "daddr"}},
                               "right": m.group("ip")}})
    m = _PROTO.search(line)
    if m:
        # nft 会把 icmpv6 归一成 ipv6-icmp —— 桩也照做, 好让"协议别名不算漂移"这条判据
        # 在沙箱里同样成立(它正是 .153 那四条假漂移之一)。
        p = m.group("p")
        expr.append({"match": {"op": "==",
                               "left": {"payload": {"protocol": "ip6" if "6" in line.split()[0]
                                                    else "ip", "field": "nexthdr"
                                                    if "nexthdr" in line else "protocol"}},
                               "right": "ipv6-icmp" if p == "icmpv6" else p}})
    m = _DPORT.search(line)
    if m:
        right = ({"set": _ports(m.group("set"))} if m.group("set") is not None
                 else int(m.group("one")))
        expr.append(_match(m.group("proto"), "dport", right))
    m = _REDIR.search(line)
    if m:
        expr.append({"redirect": {"port": int(m.group("port"))}})
    else:
        for v in _VERDICTS:
            if re.search(r"\b%s\b" % v, line):
                if v == "reject":
                    # nft 打印 reject 时会补上默认类型 —— 同样是那四条"假漂移"之一
                    expr.append({"reject": {"type": "icmp", "expr": "port-unreachable"}})
                else:
                    expr.append({v: None})
                break
    m = _COMMENT.search(line)
    if m:
        expr.append({"comment": m.group("c")})
    # 只有 match 没有 verdict, 或者两者都没有 → 认不出来
    if not expr or not any(k in e for e in expr
                           for k in ("accept", "drop", "reject", "redirect", "return",
                                     "masquerade", "continue")):
        return None
    return expr


def to_json(text, family="inet", table="pdg"):
    """配置文本 → `nft -j list table <family> <table>` 形状的 dict。

    找不到那张表就返回**只有空 nftables 数组**的结果 —— 不是"健康", 是"这张表不在",
    nftlive 会据此判 fail。桩绝不能在表不存在时假装一切正常。
    """
    items = []
    lines = (text or "").splitlines()
    in_table = False
    chain = None
    depth = 0
    handle = 0
    for raw in lines:
        line = raw.split("#", 1)[0].rstrip()      # 真 nft 不回显配置里的注释
        if not line.strip():
            continue
        m = _TABLE.match(line)
        if m:
            if m.group("family") == family and m.group("name") == table:
                in_table = True
                depth = 1
                items.append({"table": {"family": family, "name": table}})
            continue
        if not in_table:
            continue
        m = _CHAIN.match(line)
        if m:
            chain = m.group("name")
            depth = 2
            items.append({"chain": {"family": family, "table": table, "name": chain}})
            continue
        m = _TYPE.match(line)
        if m and chain:
            prio = m.group("prio")
            items[-1]["chain"].update({
                "type": m.group("type"), "hook": m.group("hook"),
                "prio": _PRIO.get(prio, int(prio) if re.match(r"^-?\d+$", prio) else 0),
                "policy": m.group("policy")})
            continue
        if line.strip() == "}":
            depth -= 1
            if depth <= 1:
                chain = None
            if depth <= 0:
                in_table = False
            continue
        if chain:
            expr = _rule_expr(line)
            if expr is not None:
                handle += 1
                items.append({"rule": {"family": family, "table": table, "chain": chain,
                                       "handle": handle, "expr": expr}})
    return {"nftables": items}


def main(argv):
    fam = argv[1] if len(argv) > 1 else "inet"
    tab = argv[2] if len(argv) > 2 else "pdg"
    obj = to_json(sys.stdin.read(), fam, tab)
    if not obj["nftables"]:
        # 表不在: 真 nft 会报错退非零, 桩照做 —— 绝不返回一个"看着健康"的空壳
        sys.stderr.write("Error: No such file or directory\n")
        return 1
    sys.stdout.write(json.dumps(obj))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

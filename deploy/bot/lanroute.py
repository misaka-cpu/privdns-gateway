#!/usr/bin/env python3
"""内网面板(方案 B)的**门一**: 判断家里通告过来的子网路由能不能接受。

为什么这道门是灾难级、必须写进代码而不是文档:

Tailscale 的子网路由一旦被本机接受, 那些网段的流量就**从本机的路由表走进 tailnet**。
如果通告的网段与本项目正在用的段有交集, 手机的分流数据面会直接错乱 —— 而且从任何一份
配置上都看不出来: nft 规则没变、mosdns 没变、mihomo 没变, 只是包不再走原来那条路了。
排查这种故障要先想到"是不是别人给我通告了一个网段", 而那正是最难想到的一层。

所以判据必须在**接受之前**跑, 并且拒绝时点名是哪个网段与什么冲突。笼统说一句
"路由不合法"等于把上面那段排查过程原样丢回给用户。

判据是纯计算: 输入全部由调用方采集好传进来, 这里一个系统调用都不做。这样 doctor 能常驻
跑它, 测试也不必去造网络现场。

用法:
  lanroute.py judge --internal <CIDR> [--local <CIDR>]... [--] <通告段>...
退出码: 0=全部可接受; 2=至少一个被拒(理由写到 stdout); 3=参数不合法。
"""
import argparse
import ipaddress
import sys

# 拒绝理由的稳定标识。调用方(pdg lan / doctor)按它分类, 不去匹配中文文案 ——
# 文案会为了讲清楚而改, 标识不会。
R_DEFAULT = "default-route"
R_INTERNAL = "overlap-internal"
R_LOCAL = "overlap-local"
R_TAILNET = "overlap-tailnet"
R_LOOPBACK = "overlap-loopback"

# Tailscale 自己的地址段。家里把它整个通告过来, 等于让 tailnet 的流量绕道回家 ——
# 结果是 tailnet 自身失联, 而 tailnet 正是唯一能把它救回来的通道。
TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")
TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")


def parse_net(s):
    """接受 CIDR 文本, 返回 ip_network。带主机位的写法(192.168.1.5/24)一律按网段取整,
    因为"接口地址所在网段"本来就是这个含义 —— 让调用方先算一遍反而多一处出错的地方。"""
    return ipaddress.ip_network(s.strip(), strict=False)


def judge_one(net, internal, locals_, ):
    """判一个通告段。返回 (标识, 说明) 的列表 —— 一个网段可能同时踩中好几条,
    全列出来比只报第一条有用: 用户改完第一条又撞上第二条, 那种来回是能一次说完的。"""
    bad = []

    # ① 默认路由。这不是"网段太大", 是性质不同的一件事: 接受之后本机的**所有**出站流量
    #    都会走进 tailnet 去家里那台, 网关变成家里的出口节点。手机的国际流量会绕地球一圈,
    #    而且家里那台的带宽和公网 IP 会替网关背锅。
    if net.prefixlen == 0:
        bad.append((R_DEFAULT, "%s 是默认路由 —— 接受它会把网关变成你家的出口节点, "
                               "手机的所有流量都要绕经家里" % net))
        return bad          # 已经是最坏情形, 再比对下面几条没有信息量

    # ② 与本项目的内网卡来源段相交。这是最隐蔽的一条: 分流的判据就是"源地址在这个段里",
    #    段被路由劫走之后, 判据还在、包却不来了。
    if internal is not None and net.version == internal.version and net.overlaps(internal):
        bad.append((R_INTERNAL, "%s 与内网卡来源段 %s 相交 —— 手机的流量会被路由进 tailnet, "
                                "分流数据面直接错乱" % (net, internal)))

    # ③ 与本机某个接口所在网段相交。命中之后本机发往那个网段的包会被送进 tailnet,
    #    最典型的后果是**本机自己的默认网关到不了**, 表现为整台机器断网。
    for loc in locals_:
        if net.version == loc.version and net.overlaps(loc):
            bad.append((R_LOCAL, "%s 与本机接口网段 %s 相交 —— 本机发往该段的包会被送进 "
                                 "tailnet, 严重时整台机器断网" % (net, loc)))

    # ④ 与 tailnet 自身的段相交。踩中这条会把救援通道本身弄断。
    for ts in (TAILNET_V4, TAILNET_V6):
        if net.version == ts.version and net.overlaps(ts):
            bad.append((R_TAILNET, "%s 与 Tailscale 自身地址段 %s 相交 —— tailnet 会失联, "
                                   "而它正是唯一能把机器救回来的通道" % (net, ts)))

    # ⑤ 环回。没有任何正当用途, 但写错网段时很容易撞上(比如手滑写成 127.0.0.0/8)。
    if net.is_loopback or (net.version == 4 and net.overlaps(ipaddress.ip_network("127.0.0.0/8"))):
        bad.append((R_LOOPBACK, "%s 覆盖环回地址 —— 这不会有正当用途, 多半是网段写错了" % net))

    return bad


def judge(advertised, internal=None, locals_=()):
    """返回 [(网段文本, [(标识, 说明), ...]), ...], 只含**被拒**的那些。全部可接受时返回空列表。"""
    out = []
    for a in advertised:
        try:
            net = parse_net(a)
        except ValueError as e:
            out.append((a, [("bad-cidr", "%s 不是合法网段(%s)" % (a, e))]))
            continue
        bad = judge_one(net, internal, locals_)
        if bad:
            out.append((str(net), bad))
    return out


USAGE = "用法: lanroute.py judge --internal <CIDR> [--local <CIDR>]... <通告段>..."


def main(argv):
    # 子命令自己取, 不交给 argparse: 两个位置参数被 --internal 隔开时 argparse 会把
    # 后面的网段当成"多余参数"报错(nets 被贪婪地绑到第一组位置参数上)。踩过一次,
    # 表现是合法调用直接退 3, 而错误信息里只字不提真正的原因。
    if len(argv) < 2 or argv[1] != "judge":
        print(USAGE)
        return 3
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--internal", default=None)
    ap.add_argument("--local", action="append", default=[])
    ap.add_argument("nets", nargs="*")
    try:
        ns = ap.parse_args(argv[2:])
    except SystemExit:
        print(USAGE)
        return 3

    internal = None
    if ns.internal:
        try:
            internal = parse_net(ns.internal)
        except ValueError:
            print("内网卡来源段不合法: %s" % ns.internal)
            return 3
    locs = []
    for l in ns.local:
        try:
            locs.append(parse_net(l))
        except ValueError:
            print("本机接口网段不合法: %s" % l)
            return 3
    if not ns.nets:
        return 0

    rejected = judge(ns.nets, internal, locs)
    for cidr, reasons in rejected:
        for tag, why in reasons:
            print("%s\t%s" % (tag, why))
    return 2 if rejected else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

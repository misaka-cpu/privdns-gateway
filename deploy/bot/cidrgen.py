#!/usr/bin/env python3
"""内网卡来源段变更的**候选生成**(5.2/T7 的事务化配套)。

detect-cidr 要同时改三份生产文件, 以前是 `sed -i` 直接改临时副本再 cp 覆盖, 每份的替换规则
各写一遍、转义各处理一次。这里把"从现网内容生成候选内容"抽成纯函数: 输入是当前内容, 输出是
候选内容, 一个字节都不写盘 —— 落盘、校验、观察、回滚全交给 pdgtx。

三种目标的替换规则不同, 不能一把 sed 走天下:
  · profile.env  只改 PDG_INTERNAL_CIDR 这一个键, **保持行序**, 其余用户自定义键原样不动;
                 键不存在就追加到末尾(不插到中间, 免得看起来像被重排过)。
  · nftables.conf 把旧段的**每一处**换成新段 —— 与历史行为一致(用户可能在自己的规则里也引用
                 了同一个段); 找不到旧段即失败, 绝不"猜一个位置插进去"。
  · mosdns 配置   只换 npn_clients 的 ips: ["..."] 里那一个值。

用法: cidrgen.py {profile|nft|mosdns} <新段> [旧段] < 当前内容 > 候选内容
退出码: 0=已生成; 2=没找到可替换的位置(调用方必须中止, 不许落盘); 3=参数不合法。
"""
import ipaddress
import re
import sys


def valid_cidr(s):
    """形态 + 私网判定。公网段一旦写进 nft, REDIRECT 与放行就对全网生效 —— 这不是"配置不当",
    是把网关变成开放中继, 所以在生成候选之前就挡掉。CGNAT(100.64/10)算私网(运营商内网卡常用,
    py<3.13 的 is_private 不含它)。"""
    try:
        net = ipaddress.ip_network(s, strict=False)
    except Exception:  # noqa: BLE001
        return False, "不是合法 CIDR"
    if net.version != 4:
        return False, "只支持 IPv4 段"
    if net.prefixlen == 0:
        return False, "等于全网, 会劫持所有来源"
    cgnat = ipaddress.ip_network("100.64.0.0/10")
    if not (net.is_private or net.subnet_of(cgnat)):
        return False, "是公网段, 拒绝写入(会把网关变成开放中继)"
    return True, ""


def profile_set(text, cidr, key="PDG_INTERNAL_CIDR"):
    """只改这一个键, 保持行序; 不存在则追加。返回 (新内容, 是否有变化)。"""
    out, seen, changed = [], False, False
    for line in text.splitlines(True):
        m = re.match(r"^([ \t]*)%s=" % re.escape(key), line)
        if m:
            new = "%s%s=%s\n" % (m.group(1), key, cidr)
            if not seen:                       # 只保留第一处(重复键取最后一个才生效, 这里收敛成一处)
                changed = changed or new != line
                out.append(new)
                seen = True
            else:
                changed = True                 # 丢掉重复键也是变化
            continue
        out.append(line)
    if not seen:
        if out and not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append("%s=%s\n" % (key, cidr))
        changed = True
    return "".join(out), changed


def nft_replace(text, new, old):
    """把旧段的每一处换成新段。找不到 → (None, 0), 调用方必须中止。"""
    if not old:
        return None, 0
    n = text.count(old)
    if n == 0:
        return None, 0
    return text.replace(old, new), n


_MOS_RE = re.compile(r'(ips:\s*\[\s*")([0-9./]+)("\s*\])')


def mosdns_replace(text, new):
    """只换 npn_clients 的 ips 值。找不到 → (None, 0)。"""
    hits = _MOS_RE.findall(text)
    if not hits:
        return None, 0
    return _MOS_RE.sub(lambda m: m.group(1) + new + m.group(3), text), len(hits)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 3
    kind, new = argv[1], argv[2]
    old = argv[3] if len(argv) > 3 else ""
    good, why = valid_cidr(new)
    if not good:
        print("新内网卡段不可用: %s (%s)" % (new, why), file=sys.stderr)
        return 3
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if kind == "profile":
        out, _changed = profile_set(text, new)
    elif kind == "nft":
        out, n = nft_replace(text, new, old)
        if not out:
            print("nftables 配置里没找到可替换的内网卡段 %r(自定义形态?)" % old, file=sys.stderr)
            return 2
    elif kind == "mosdns":
        out, n = mosdns_replace(text, new)
        if not out:
            print("mosdns 配置里没找到可替换的 ips 段(自定义形态?)", file=sys.stderr)
            return 2
    else:
        print("未知目标类型: %s" % kind, file=sys.stderr)
        return 3
    sys.stdout.buffer.write(out.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

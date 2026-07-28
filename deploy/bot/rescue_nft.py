#!/usr/bin/env python3
"""救援端口放行的**候选注入** —— 让恢复出来的那份 nft 配置里从一开始就带着救援规则。

以前的做法是 `nft -f 旧快照` 之后再 `nft insert` 一条救援规则: 两次 apply 之间存在一个真实
窗口, 期间新的救援连接会被 policy drop 挡掉 —— 而完整恢复正是最需要那个入口的时刻。

现在改成: 在 staging 里就把救援规则注入到候选内容中, `nft -c` 校验整份候选, 通过后原子写盘、
**只执行一次** `nft -f`。于是不存在"缺少救援规则的运行态"这个中间状态。

为什么用**独立的表**(inet pdgrescue)而不是往 inet pdg 的 input 链里塞一行:
  · 快照里的 pdg 块形态千差万别(旧版本、用户改过、甚至根本没有), 往里改要解析别人的结构;
  · 候选里可能有 `flush ruleset` / `delete table inet pdg` —— 只要我们的表**声明在它们之后**,
    同一次 nft transaction 结束时它一定存在;
  · 用户自己的规则一个字节都不用动。
"""
import re
import sys

TABLE = "pdgrescue"
BANNER = ("# ==== PrivDNS Gateway 救援入口(独立表, 由救援平面维护; 完整恢复时自动保留) ====\n"
          "# 与 table inet pdg 分开, 是为了让恢复整份旧防火墙不会顺手切断救援入口。\n")


def rule_block(cidr, port):
    """独立表: 只放行内网卡来源到救援端口。priority 比 pdg 的 input(0)更早, 先 accept 掉。"""
    return (BANNER +
            "table inet %s\n"
            "delete table inet %s\n"
            "table inet %s {\n"
            "    chain input {\n"
            "        type filter hook input priority -10; policy accept;\n"
            "        ip saddr %s tcp dport %d accept\n"
            "    }\n"
            "}\n" % (TABLE, TABLE, TABLE, cidr, port))


_OURS_RE = re.compile(r"^# ==== PrivDNS Gateway 救援入口.*?^\}\n", re.S | re.M)

# 补进别人链里的那一行, 用行尾标记认领。只认这个标记, 于是"我们加的"与"用户自己写的同端口
# 放行"始终分得开 —— 撤销时绝不会误删后者。
_MARK = "# pdg-rescue(自动补入; 撤销救援时由 --strip 一并移除)"
_INLINE_RE = re.compile(r"^.*%s\n" % re.escape(_MARK), re.M)

# `type filter hook input <优先级>; policy drop;` 这一行 —— 后面紧跟的就是链里第一条规则的位置
_DROP_INPUT_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<decl>type\s+filter\s+hook\s+input\b[^\n]*policy\s+drop\s*;)[ \t]*$",
    re.M)


def strip_ours(text):
    """去掉我们自己上一次注入的东西(幂等: 反复注入不会越堆越多)。

    两部分都要摘: 独立表整块, 以及补进别人 input 链里的那些行。"""
    return _INLINE_RE.sub("", _OURS_RE.sub("", text or ""))


def _patch_drop_chains(text, cidr, port):
    """给候选里**每个 policy drop 的 input 基链**补一条救援放行, 返回 (新文本, 补了几处)。

    为什么光有独立表不够 —— 这是 10b 在真 nftables 上验出来的:
    同一个 hook 上注册多个 base chain 时, 数据包会**挨个走一遍**; 某条链里的 `accept` 只终止
    **本链**, 后面优先级的链照样能把它丢掉。于是恢复一份 5.2 之前的旧防火墙(inet pdg 是
    policy drop 且没有救援放行)之后, 独立表 inet pdgrescue 里的 accept 完全不管用 ——
    真机实测: 内网来源连救援口直接超时, 救援门在最需要它的时刻是关着的。
    (对照: 同一份规则下 SSH 口回的是 Connection refused 而不是超时, 说明确实是被 drop 掉的。)

    所以除了独立表, 还要往每条会丢包的 input 链里补一行。插在链首(紧跟 type 声明), 不解析
    链里其余结构 —— 别人的规则一个字节都不动, 只是多一条更靠前的放行。
    """
    n = [0]

    def _ins(m):
        n[0] += 1
        return "%s%s\n%s    ip saddr %s tcp dport %d accept   %s" % (
            m.group("indent"), m.group("decl"), m.group("indent"), cidr, port, _MARK)

    return _DROP_INPUT_RE.sub(_ins, text), n[0]


def ensure_rescue_rule(text, cidr, port):
    """把救援规则注入候选内容。返回 (新内容, 是否有变化)。

    **总是追加到末尾** —— nft 按文件顺序执行, 追加在后面意味着候选里任何 flush/delete 都发生
    在我们之前, 事务结束时救援表一定在。"""
    if not cidr or not port:
        raise ValueError("注入救援规则需要内网卡段与端口")
    base = strip_ours(text or "")
    if base and not base.endswith("\n"):
        base += "\n"
    base, _patched = _patch_drop_chains(base, cidr, port)   # 先补别人的 drop 链
    out = base + rule_block(cidr, port)                     # 再追加自己的独立表
    return out, out != (text or "")


def has_rescue_rule(text, port):
    """运行态/候选里还有救援放行吗(只认我们自己的表)。"""
    if not text:
        return False
    m = re.search(r"table\s+inet\s+%s\b" % TABLE, text)
    return bool(m) and bool(re.search(r"dport\s+%d\b" % port, text))


def main(argv):
    """用法: rescue_nft.py <内网卡段> <端口> < 候选内容 > 注入后的候选
             rescue_nft.py --strip            < 候选内容 > 移除救援块后的候选"""
    if len(argv) >= 2 and argv[1] == "--strip":
        # 只摘掉**我们自己注入的那个独立表**(靠 BANNER 定界)。绝不按端口去删行 ——
        # 用户完全可能自己写了一条同端口的放行, 那是他的规则, 与我们无关。
        txt = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        sys.stdout.buffer.write(strip_ours(txt).encode("utf-8", "surrogateescape"))
        return 0
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    try:
        out, _changed = ensure_rescue_rule(
            sys.stdin.buffer.read().decode("utf-8", "surrogateescape"), argv[1], int(argv[2]))
    except (ValueError, TypeError) as e:
        print("注入失败: %s" % e, file=sys.stderr)
        return 2
    sys.stdout.buffer.write(out.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

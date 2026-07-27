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


def strip_ours(text):
    """去掉我们自己上一次注入的块(幂等: 反复注入不会越堆越多)。"""
    return _OURS_RE.sub("", text or "")


def ensure_rescue_rule(text, cidr, port):
    """把救援规则注入候选内容。返回 (新内容, 是否有变化)。

    **总是追加到末尾** —— nft 按文件顺序执行, 追加在后面意味着候选里任何 flush/delete 都发生
    在我们之前, 事务结束时救援表一定在。"""
    if not cidr or not port:
        raise ValueError("注入救援规则需要内网卡段与端口")
    base = strip_ours(text or "")
    if base and not base.endswith("\n"):
        base += "\n"
    out = base + rule_block(cidr, port)
    return out, out != (text or "")


def has_rescue_rule(text, port):
    """运行态/候选里还有救援放行吗(只认我们自己的表)。"""
    if not text:
        return False
    m = re.search(r"table\s+inet\s+%s\b" % TABLE, text)
    return bool(m) and bool(re.search(r"dport\s+%d\b" % port, text))


def main(argv):
    """用法: rescue_nft.py <内网卡段> <端口> < 候选内容 > 注入后的候选"""
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

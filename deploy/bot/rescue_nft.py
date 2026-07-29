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

# 旧版(5.2 早期)的独立表签名。**只用于识别与清除**, 生产路径不再生成它。
# 为什么废弃: 同一 hook 上注册多条 base chain 时数据包会挨个走完, 某条链里的 accept 只终止
# 本链 —— `inet pdg` 的 policy drop 照样把包丢掉。10b 在真 nftables 上实测过: 恢复一份没有
# 救援放行的旧防火墙之后, 独立表存在但救援口不可达。而且项目自己的 doctor 一直把"pdg 之外
# 挂 input hook 的表"判成冲突(它的说明正是这个机制), 于是启用救援平面的机器每次 pdg update
# 的更新后自检都会失败并整次回滚。两头都指向同一个结论: 这个设计不成立。
LEGACY_TABLE = "pdgrescue"
LEGACY_BANNER_RE = re.compile(r"^# ==== PrivDNS Gateway 救援入口.*?^\}\n", re.S | re.M)
# 旧表的**完整签名**: 必须四项全中才认定是我们生成的。用户自己建了一张同名表却不是这个形状
# 时, 绝不擅自删 —— 那是别人的规则, 宁可 fail-closed 点名让人自己处理。
_LEGACY_SIG = (
    re.compile(r"table\s+inet\s+%s\s*\{" % LEGACY_TABLE),
    re.compile(r"type\s+filter\s+hook\s+input\s+priority\s+-10\s*;\s*policy\s+accept\s*;"),
    re.compile(r"ip\s+saddr\s+\S+\s+tcp\s+dport\s+\d+\s+accept"),
    LEGACY_BANNER_RE,
)

# 现在唯一的生产形态: 往项目自己的 `inet pdg` input 链里加一条带标记的规则。
# 标记既是"这条是我们的"的凭证, 也是精确撤销的依据 —— 绝不按端口模糊删除, 用户完全可能
# 自己写过一条同端口放行。
MARK = "pdg-rescue"
_MARK_CMT = 'comment "%s"' % MARK


def rule_line(cidr, bind, port, indent="        "):
    """一条完整的救援放行。四要素缺一不可: 来源段 + 目的地址(就是我们绑的那个) + 端口 + 标记。
    只写来源不写目的地址的话, 同一台机器上别的地址也会跟着被放行。"""
    return "%sip saddr %s ip daddr %s tcp dport %d accept %s" % (
        indent, cidr, bind, port, _MARK_CMT)


_INLINE_RE = re.compile(r"^[ \t]*ip saddr \S+ ip daddr \S+ tcp dport \d+ accept "
                        r"comment \"%s\"[ \t]*\n" % MARK, re.M)
# 5.2 早期那版补入行(行尾注释形态), 迁移时一并清掉
_INLINE_OLD_RE = re.compile(r"^.*# pdg-rescue\(自动补入[^\n]*\n", re.M)

# input 基链声明行 —— 规则插在它后面, 即链首, 天然位于链尾的 drop/reject 之前
_INPUT_CHAIN_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<decl>type\s+filter\s+hook\s+input\b[^\n]*;)[ \t]*$", re.M)
# 项目自己的表(带花括号的定义块)。**只在这里面动手** —— 用户自己的表哪怕也挂 input hook,
# 也一个字节都不改: 那是别人的规则, 我们没有资格往里塞东西。
PDG_TABLE = "pdg"
_PDG_BLOCK_RE = re.compile(r"^table\s+inet\s+%s\s*\{.*?^\}\n" % PDG_TABLE, re.S | re.M)


def legacy_present(text):
    """文本里有没有**我们自己**的旧独立表。返回 (有没有, 是不是完整签名)。"""
    if not text:
        return (False, False)
    named = re.search(r"table\s+inet\s+%s\b" % LEGACY_TABLE, text)
    if not named:
        return (False, False)
    return (True, all(rx.search(text) for rx in _LEGACY_SIG))


def strip_legacy(text):
    """摘掉旧独立表管理块(只在完整签名匹配时)。签名不符 → 原样返回, 由调用方 fail-closed。"""
    present, full = legacy_present(text)
    if not present or not full:
        return text
    return LEGACY_BANNER_RE.sub("", text)


def strip_ours(text):
    """去掉我们注入的一切: 链内标记规则 + 旧版补入行 + 旧独立表。幂等。"""
    out = _INLINE_RE.sub("", text or "")
    out = _INLINE_OLD_RE.sub("", out)
    return strip_legacy(out)


def has_rescue_rule(text, port, bind=None):
    """磁盘/候选文本里有没有我们的放行。

    没有任何 input 基链时返回 True: 那台机器上根本没有会丢包的链, 端口本来就通, 不需要补。
    """
    if not text:
        return False
    for m in _INLINE_RE.finditer(text):
        line = m.group(0)
        if ("dport %d " % port) in line and (bind is None or (" ip daddr %s " % bind) in line):
            return True
    return not _INPUT_CHAIN_RE.search(text)


def count_rules(text, port=None):
    """我们的规则有几条 —— 用来盯"恰好一条"。"""
    n = 0
    for m in _INLINE_RE.finditer(text or ""):
        if port is None or ("dport %d " % port) in m.group(0):
            n += 1
    return n


def ensure_rescue_rule(text, cidr, port, bind=None):
    """把救援放行注入候选内容。返回 (新内容, 是否有变化)。

    只做一件事: 在**项目自己的** `inet pdg` input 链链首插一条带标记的规则。插链首是为了
    确定落在链尾的 drop/reject 之前 —— 位置错了等于没放行, 而"看着开了实际不通"最难查。
    旧独立表(若在)顺手清掉, 同一次候选里完成迁移, 不留无防护窗口。
    """
    if not cidr or not port:
        raise ValueError("注入救援规则需要来源段与端口")
    if not bind:
        raise ValueError("注入救援规则需要监听地址(PDG_RESCUE_BIND) —— 不接受省略: "
                         "只写来源不写目的地址会把本机其它地址上的同端口一起放行")
    present, full = legacy_present(text or "")
    if present and not full:
        raise ValueError("配置里有一张名为 inet %s 的表, 但形态与本项目生成的不一致 —— "
                         "拒绝擅自改动别人的表, 请自行确认后处理" % LEGACY_TABLE)
    base = strip_ours(text or "")
    if base and not base.endswith("\n"):
        base += "\n"
    n = [0]

    def _ins(m):
        n[0] += 1
        return "%s%s\n%s" % (m.group("indent"), m.group("decl"),
                             rule_line(cidr, bind, port, m.group("indent")))

    def _patch_pdg(block):
        return _INPUT_CHAIN_RE.sub(_ins, block.group(0), count=1)

    out = _PDG_BLOCK_RE.sub(_patch_pdg, base, count=1)
    if n[0] == 0 and _INPUT_CHAIN_RE.search(base):
        # 有会丢包的 input 链, 却不是项目自己的表 —— 我们无处可插, 而端口确实过不去。
        # 这时**明确失败**, 不假装成功: 那会造出"启用了但进不去"的最坏状态。
        raise ValueError("候选里没有 table inet %s 的 input 链, 无处安放救援放行; "
                         "而别的表挂着 input hook 会把端口挡住 —— 拒绝在这种配置上假装启用"
                         % PDG_TABLE)
    return out, out != (text or "")


def main(argv):
    """用法: rescue_nft.py <来源段> <端口> <监听地址> < 候选 > 注入后的候选
             rescue_nft.py --strip                  < 候选 > 移除我们全部注入后的候选
             rescue_nft.py --legacy-check           < 候选 > 旧独立表: 0=无 1=有(完整签名) 2=同名但形态不符
    """
    if len(argv) >= 2 and argv[1] == "--strip":
        txt = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        present, full = legacy_present(txt)
        if present and not full:
            print("配置里的 inet %s 形态与本项目不符, 拒绝擅自删除" % LEGACY_TABLE, file=sys.stderr)
            return 3
        sys.stdout.buffer.write(strip_ours(txt).encode("utf-8", "surrogateescape"))
        return 0
    if len(argv) >= 2 and argv[1] == "--legacy-check":
        txt = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
        present, full = legacy_present(txt)
        return 0 if not present else (1 if full else 2)
    if len(argv) < 4:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    try:
        out, _changed = ensure_rescue_rule(
            sys.stdin.buffer.read().decode("utf-8", "surrogateescape"),
            argv[1], int(argv[2]), argv[3])
    except (ValueError, TypeError) as e:
        print("注入失败: %s" % e, file=sys.stderr)
        return 2
    sys.stdout.buffer.write(out.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""卸载时从**当前** /etc/nftables.conf 里摘掉本项目的管理块 —— 而不是拿装机前的备份整份盖回去。

为什么要有这个模块: 旧写法是 `mv /etc/nftables.conf.pdg-orig /etc/nftables.conf`, 即"还原到
装机前"。听起来合理, 实际后果是**用户装完 PDG 之后加的所有防火墙配置一并消失**, 而且没有任何
提示 —— WireGuard 的转发、fail2ban 的表、自己写的放行, 卸载完才发现没了, 那时现网配置已经被
覆盖。备份文件是好东西, 但它是**参考材料**, 不是可以拿来覆盖现网的权威版本。

现在的做法: 只删能**证明**是本项目生成的东西
  · `table inet pdg` 的管理块(声明 + delete + 定义, 就是模板那三段的固定形态);
  · 救援平面留下的东西(链内标记规则 / 旧独立表)由 rescue_nft.py 负责, 那边已有精确判据。
其余一个字节不动。形态认不出来就 fail-closed —— 宁可让人手工处理, 也不能拿"看起来像"去删
别人的规则。
"""
import re
import sys

TABLE = "pdg"

# 模板固定形态: 先声明再删(为了幂等), 然后是定义块。三段都在才认定是我们生成的。
_DECL_RE = re.compile(r"^table\s+inet\s+%s\s*$" % TABLE, re.M)
_DEL_RE = re.compile(r"^delete\s+table\s+inet\s+%s\s*$" % TABLE, re.M)
_BLOCK_RE = re.compile(r"^table\s+inet\s+%s\s*\{.*?^\}[ \t]*\n?" % TABLE, re.S | re.M)
# 声明 + delete + 定义连在一起(中间允许空行/注释)—— 整段一起摘
_MANAGED_RE = re.compile(
    r"^table\s+inet\s+%s[ \t]*\n"
    r"delete\s+table\s+inet\s+%s[ \t]*\n"
    r"(?:[ \t]*(?:#[^\n]*)?\n)*"
    r"table\s+inet\s+%s\s*\{.*?^\}[ \t]*\n?" % (TABLE, TABLE, TABLE), re.S | re.M)


class Unrecognized(Exception):
    """配置里有 table inet pdg, 但形态不是我们生成的 —— 拒绝猜, 交给人处理。"""


def has_project_table(text):
    return bool(re.search(r"\btable\s+inet\s+%s\b" % TABLE, text or ""))


def strip_project(text):
    """摘掉本项目的 inet pdg 管理块。返回新文本。

    找不到我们的表 → 原样返回(幂等)。
    找到了但形态对不上 → Unrecognized: 那可能是用户自己建的同名表, 删掉就是越权。
    """
    t = text or ""
    if not has_project_table(t):
        return t
    out, n = _MANAGED_RE.subn("", t)
    if n:
        return out
    # 退一步: 只有定义块(没有声明+delete 那两行)的老形态也认, 但必须**恰好**一个块,
    # 且块里出现过项目自己的特征(hook input + policy drop, 或 redirect 到 mihomo 的 redir 口)。
    blocks = _BLOCK_RE.findall(t)
    if len(blocks) == 1 and ("hook input" in blocks[0] or "redirect to" in blocks[0]):
        out = _BLOCK_RE.sub("", t, count=1)
        out = _DECL_RE.sub("", out)
        out = _DEL_RE.sub("", out)
        return out
    raise Unrecognized(
        "配置里有 table inet %s, 但形态与本项目生成的不一致(%d 个定义块)—— "
        "拒绝擅自删除, 请自行确认后处理" % (TABLE, len(blocks)))


def main(argv):
    """用法: nftpurge.py --strip  < 当前配置 > 摘掉项目块后的候选
             nftpurge.py --check  < 配置    ; 0=没有项目痕迹 1=还有 2=形态不符"""
    mode = argv[1] if len(argv) > 1 else ""
    txt = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if mode == "--check":
        return 1 if has_project_table(txt) else 0
    if mode != "--strip":
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    try:
        out = strip_project(txt)
    except Unrecognized as e:
        print("%s" % e, file=sys.stderr)
        return 2
    sys.stdout.buffer.write(out.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

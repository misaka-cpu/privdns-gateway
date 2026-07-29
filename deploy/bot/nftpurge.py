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


# 本项目写进配置的那行注释头(见 nftmerge.BANNER)。它自己就含着 "table inet pdg" 五个字 ——
# 摘块时必须连它一起摘, 否则下面的残留检查会被自家的注释绊住。
BANNER_RE = re.compile(r"^#[ \t]*=+[^\n]*PrivDNS Gateway[^\n]*\n", re.M)


def _decomment(text):
    """去掉 `#` 注释后的文本 —— 判"有没有表"只能看真语句。

    nft 配置里 `#` 到行尾都是注释, 而项目自己的注释头里恰好写着 `table inet pdg`。拿正则
    扫全文的话, 一次**干净的**卸载会因为那行注释被判成"仍有残留"并以非 0 退出, 任何按退出码
    判断的自动化都会认为卸载失败(`.200` 上就是这么撞出来的)。
    """
    return "\n".join(l.split("#", 1)[0] for l in (text or "").split("\n"))


def has_project_table(text):
    return bool(re.search(r"\btable\s+inet\s+%s\b" % TABLE, _decomment(text)))


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
        return BANNER_RE.sub("", out)
    # 退一步: 只有定义块(没有声明+delete 那两行)的老形态也认, 但必须**恰好**一个块,
    # 且块里出现过项目自己的特征(hook input + policy drop, 或 redirect 到 mihomo 的 redir 口)。
    blocks = _BLOCK_RE.findall(t)
    if len(blocks) == 1 and ("hook input" in blocks[0] or "redirect to" in blocks[0]):
        out = _BLOCK_RE.sub("", t, count=1)
        out = _DECL_RE.sub("", out)
        out = _DEL_RE.sub("", out)
        return BANNER_RE.sub("", out)
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

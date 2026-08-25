#!/usr/bin/env python3
"""把一份 mosdns 配置退回"还没有明确代理优先级"的形态(= v1.7.0)。

按行删, 不拿注释文案当锚点 —— 要处理的有两种来源: 仓库模板(带成段注释)和迁移写进去的
(没有注释)。用注释定位的话, 对第二种就是空跑, 而调用方还以为夹具造好了。

删三样: explicit_proxy 域名集块、explicit_proxy_seq 序列块、internal_sequence 里那道判断;
每样连同紧挨在它上面的注释一起删。删不干净就报错退出。
"""
import re
import sys


def drop_block(lines, head_pred, end_pred):
    """删掉第一个满足 head_pred 的行起、到 end_pred 为止的块, 连同紧邻其上的注释行。"""
    for i, ln in enumerate(lines):
        if not head_pred(ln):
            continue
        j = i + 1
        while j < len(lines) and not end_pred(lines[j]):
            j += 1
        k = i
        while k > 0 and lines[k - 1].lstrip().startswith("#"):
            k -= 1
        return lines[:k] + lines[j:], True
    return lines, False


def main():
    f = sys.argv[1]
    lines = open(f, encoding="utf-8").read().splitlines(keepends=True)

    def top(l):
        return l.startswith("  - tag: ")

    # 1) 两个插件块: 各删到下一个顶层 "  - tag: " 为止
    for tag in ("  - tag: explicit_proxy\n", "  - tag: explicit_proxy_seq\n"):
        lines, _ = drop_block(lines, lambda l, t=tag: l == t, top)

    # 2) internal_sequence 里的判断: "- matches: qname $explicit_proxy" 连同它下面那条 exec
    lines, _ = drop_block(
        lines,
        lambda l: l.strip() == "- matches: qname $explicit_proxy",
        lambda l: l.strip().startswith("- matches:") or l.startswith("  - tag: "))

    out = "".join(lines)
    # 去广告受管块(v1.11.0)也引用 $explicit_proxy —— 那是"第三方表不得压过用户显式分流"
    # 那条合取。退回 v1.7.0 形态时它整段都不该在, 连同 plugins 那一段一起剥掉;
    # 剥不干净会立刻表现为下面那条"仍残留 explicit_proxy"。
    out = re.sub(r" *# 不要手工编辑下面这一段[^\n]*\n *# >>> pdg-adblock managed block \(plugins\)"
                 r"[\s\S]*?# <<< pdg-adblock managed block \(plugins\)\n", "", out)
    out = re.sub(r" *# 不要手工编辑下面这一段[^\n]*\n *# >>> pdg-adblock managed block \(internal_sequence\)"
                 r"[\s\S]*?# <<< pdg-adblock managed block \(internal_sequence\)\n", "", out)
    if "explicit_proxy" in out:
        sys.exit("没退回到 v1.7.0 形态: 仍残留 explicit_proxy")
    open(f, "w", encoding="utf-8").write(out)


if __name__ == "__main__":
    main()

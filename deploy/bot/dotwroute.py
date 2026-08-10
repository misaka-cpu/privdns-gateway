#!/usr/bin/env python3
"""mosdns 配置里 DoT 证据端路由的**受管块**读写。

为什么需要它: v1.9.0 装出来的机器盘上没有 witness 路由, 而 `pdg update` 从不用模板
重渲 /etc/mosdns/config.yaml —— 它只做外科式迁移。只补 unit 不补路由的话, 机器会停在
"service active、查询永远到不了 witness"这个状态, 而 linkstat 会据此对用户说
"你手机的加密 DNS 没到达网关"。那是假话, 比直接说"不可用"有害得多。

三条纪律:

  · **只在自己的起止标记之间增删。** 用户写的分流规则、上游顺序、缓存、ECS、劫持
    一个字节都不碰。判据不是"看见 dotwitness_fwd 就当装好了" —— 那认不出半安装
    (有插件没分支 / 有分支没插件), 而半安装恰恰是最危险的那种。

  · **锚点不唯一就 fail-closed。** 这份文件用户可能改过。找不到、或找到多处, 一律
    不动并报错; 猜位置比不改危险得多。

  · **幂等靠"先删净受管块再重建"**, 不靠"检测到就跳过"。后者遇到内容漂移(比如域名
    改过)会留着旧的那份不动。
"""
import re
import sys

BEGIN_P = "  # >>> pdg-dotwitness managed block (plugins)"
END_P = "  # <<< pdg-dotwitness managed block (plugins)"
BEGIN_S = "      # >>> pdg-dotwitness managed block (main_sequence)"
END_S = "      # <<< pdg-dotwitness managed block (main_sequence)"

# 插入锚点。两者都必须**恰好出现一次**。
ANCHOR_PLUGIN = "  - tag: main_sequence"          # 插件段插在它之前
ANCHOR_SEQ = "      - matches: client_ip $npn_clients"   # 探测分支插在它之前

WITNESS_PORT = 5399          # 与 dotwitness.DOTWITNESS_PORT 对齐, 由 test-dot-render 守住

# 域名形状: 只接受普通主机名。这个值会被拼进 mosdns 配置, 放宽等于允许注入。
DOMAIN_RE = re.compile(r"\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\Z")


def plugins_block():
    return "\n".join([
        BEGIN_P,
        "  - tag: dotwitness_fwd",
        "    type: forward",
        "    args:",
        "      concurrent: 1",
        "      upstreams:",
        '        - addr: "udp://127.0.0.1:%d"' % WITNESS_PORT,
        "  - tag: probe_seq",
        "    type: sequence",
        "    args:",
        "      - exec: $dotwitness_fwd",
        "      - exec: jump has_resp",
        END_P,
    ])


def seq_block(domain):
    return "\n".join([
        BEGIN_S,
        "      - matches:",
        "          - qname suffix probe.%s" % domain,
        "          - string_exp server_name eq %s" % domain,
        "        exec: goto probe_seq",
        END_S,
    ])


def strip(text):
    """删掉所有受管块。只认成对标记; 落单的标记也一并删掉(半安装要能被清干净)。"""
    out, skip = [], False
    for line in text.splitlines():
        if line == BEGIN_P or line == BEGIN_S:
            skip = True
            continue
        if line == END_P or line == END_S:
            skip = False
            continue
        if not skip:
            out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def state(text):
    """当前配置处于哪种状态。返回 'full' / 'partial' / 'absent' / 'malformed'。"""
    np, nps = text.count(BEGIN_P), text.count(END_P)
    ns, nss = text.count(BEGIN_S), text.count(END_S)
    if np != nps or ns != nss:
        return "malformed"          # 标记不成对: 有人手工编辑过
    if np > 1 or ns > 1:
        return "malformed"          # 重复受管块
    if np == 1 and ns == 1:
        return "full"
    if np == 0 and ns == 0:
        # 标记一个都没有, 但插件名可能是别的途径塞进来的 —— 那不算我们管的, 要报出来
        if "dotwitness_fwd" in text or "probe_seq" in text:
            return "malformed"
        return "absent"
    return "partial"                # 有插件没分支, 或反过来


def render(text, domain):
    """返回 (ok, 新配置或错误说明)。幂等: 先删净受管块再按锚点重建。"""
    if not isinstance(domain, str) or not DOMAIN_RE.match(domain) or len(domain) > 253:
        return False, "DoT 域名不合法: %r" % (domain,)
    st = state(text)
    if st == "malformed":
        return False, ("mosdns 配置里的 witness 受管块结构不明(标记不成对、重复, 或"
                       "存在不带标记的 witness 插件)。不做任何改动 —— 这种半安装状态"
                       "要人看一眼再决定。")
    base = strip(text)
    n_plugin = base.count("\n" + ANCHOR_PLUGIN + "\n")
    n_seq = base.count("\n" + ANCHOR_SEQ + "\n")
    if n_plugin != 1 or n_seq != 1:
        return False, ("mosdns 配置的锚点不唯一(main_sequence=%d, 内网分流分支=%d)。"
                       "这份配置的结构与预期不符, 不做任何改动 —— 猜位置比不改危险。"
                       % (n_plugin, n_seq))
    base = base.replace("\n" + ANCHOR_PLUGIN + "\n",
                        "\n" + plugins_block() + "\n" + ANCHOR_PLUGIN + "\n", 1)
    base = base.replace("\n" + ANCHOR_SEQ + "\n",
                        "\n" + seq_block(domain) + "\n" + ANCHOR_SEQ + "\n", 1)
    return True, base


def user_part(text):
    """把受管块摘掉之后剩下的东西 —— 迁移前后这一部分必须逐字节相同。

    这是"没动用户配置"的判据本身: 比对整份文件会被我们自己新增的那两段干扰, 比对
    "摘掉我们那两段之后剩下的"才是真正该不变的东西。
    """
    return strip(text)


def main(argv=None):
    a = list(sys.argv[1:] if argv is None else argv)
    if len(a) < 2:
        print("用法: dotwroute.py <render|state|userpart> <配置文件> [域名]", file=sys.stderr)
        return 2
    cmd, path = a[0], a[1]
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        print("读不到 %s: %s" % (path, e), file=sys.stderr)
        return 2
    if cmd == "state":
        print(state(text))
        return 0
    if cmd == "userpart":
        sys.stdout.write(user_part(text))
        return 0
    if cmd == "render":
        if len(a) < 3:
            print("render 需要 DoT 域名", file=sys.stderr)
            return 2
        good, res = render(text, a[2])
        if not good:
            print(res, file=sys.stderr)
            return 1
        sys.stdout.write(res)
        return 0
    print("未知子命令: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

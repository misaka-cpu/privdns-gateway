#!/usr/bin/env python3
"""nftables input base chain 冲突扫描 —— 迁移前置门(pdg.sh)与自检(doctor)共用的**单一判据**。

为什么这条是硬门槛: PDG 的 input chain 是 `policy drop`, 而 nftables 里同一 hook 上的多个
base chain **都会执行** —— 任一条判 drop, 包就没了。于是用户自己 input 链里对 9443 /
WireGuard 的 accept 会被架空: 配置文本还在, 端口实际已经不通。这种"看着保留、其实失效"
比直接报错难查得多。

"读不到"与"读到了且没有"必须分开: `nft list ruleset` 失败(非 root / nft 不可用)时, 只存在于
内存的冲突链根本没进视野 —— 把它当成现场干净, 等于换个入口把老毛病放回来。故 live_ruleset()
额外返回 readable, 调用方据此选择"中止/告警"而不是"放行"。

CLI:  nftscan.py [nftables.conf]
退出码: 0=有冲突(已打印) 1=确认无冲突 2=读不到运行 ruleset, 无法确认。
"""
import os
import re
import subprocess
import sys

NFT_CONF = "/etc/nftables.conf"
OURS = "inet pdg"                    # 本项目自己的表, 不算冲突

_TBL_OPEN = re.compile(r"^\s*table\s+(\S+)\s+(\S+)\s*\{?\s*$")
# 只认**真正的 base chain 声明**(`type <类型> hook input priority …`), 不认注释或字符串里
# 恰好出现的字样。误报虽然方向保守(中止迁移), 代价却是用户被一行注释永久挡在升级门外, 而且
# 从配置上完全看不出为什么 —— 那行明明只是注释。
_HOOK_IN = re.compile(r"\btype\s+\w+\s+hook\s+input\b")
_QUOTED = re.compile(r'"[^"]*"')
_POLICY_DROP = re.compile(r"\bpolicy\s+drop\b")
# PATH 里找不到 nft 时依次试这些位置(Debian 装在 /usr/sbin)。列成常量: 测试可以指到别处,
# 免得为了验"PATH 没有但 sbin 里有"去 patch os.path.isfile 这类底层函数。
NFT_CANDIDATES = ("/usr/sbin/nft", "/sbin/nft", "/usr/local/sbin/nft",
                  "/usr/bin/nft", "/bin/nft", "/usr/local/bin/nft")


def _strip_noise(line):
    """去掉行内注释与字符串字面量 —— 判据只该看真正生效的配置。"""
    return _QUOTED.sub('""', line).split("#", 1)[0]



# 本项目 input 链已经放行的东西(见 deploy/firewall/nftables-mihomo.conf):
#     iif "lo" accept / ct state established,related accept / ip protocol icmp accept
#     ip6 nexthdr icmpv6 accept
# 外来 input 链里如果**只有这些**, 装上去不会架空任何东西 —— 我们的链原样放行同样的流量。
# 发行版自带的 nftables.conf 骨架基本就是这几条, 拦它等于绝大多数机器都装不上。
#
# 判据只认**精确形态**, 不做语义推理: 判错的代价是不对称的 ——
#   误判为"安全"→ 用户的放行被静默架空, 端口看着开着实际不通(这道门存在的全部理由);
#   误判为"冲突"→ 装不上, 烦人但安全。
# 所以宁可漏放几种写法, 也不要靠猜。带端口的放行(tcp dport …)一律不在此列: 扫描发生在
# install.sh 问 SSH 端口**之前**, 这里无从判断那个端口是不是我们也会放行的那个。
_COVERED = tuple(re.compile(r"^" + pat + r"$") for pat in (
    r'iif(name)?\s+"?lo"?\s+(counter\s+)?accept',
    r"ct\s+state\s+established\s*,\s*related\s+(counter\s+)?accept",
    r"ct\s+state\s+\{\s*established\s*,\s*related\s*\}\s+(counter\s+)?accept",
    r"ct\s+state\s+vmap\s+\{\s*established\s*:\s*accept\s*,\s*related\s*:\s*accept"
    r"(\s*,\s*invalid\s*:\s*drop)?\s*\}",
    r"ip\s+protocol\s+icmp\s+(counter\s+)?accept",
    r"ip6\s+nexthdr\s+(icmpv6|ipv6-icmp)\s+(counter\s+)?accept",
    r"meta\s+l4proto\s+(icmpv6|ipv6-icmp)\s+(counter\s+)?accept",
))


def _pdg_covers(raw):
    """这条外来规则是不是本项目 input 链已经放行的同一类流量。"""
    ln = raw.split("#", 1)[0].strip().rstrip(";").strip()
    ln = re.sub(r"\s+", " ", ln)
    return any(p.match(ln) for p in _COVERED)


# ── 把外来 input 链里的放行搬进本项目的自定义放行目录 ────────────────────────
# 为什么这么做: 问题从来不是"用户有自己的 input 链", 而是本项目的 policy drop 架空了他的
# accept。把那些 accept **复制**一份进我们的链, 他的流量就通了 —— 他原来那条链留着不动也
# 无妨, 只是变成冗余。这样我们一个字节都不用改他的表。
#
# 只搬**判决为 accept** 的规则:
#   · drop / reject 不搬 —— 那会给他加限制, 是改变行为而不是保持行为;
#   · limit / log 不搬 —— 我们的链里再来一条无限制的 accept, 等于把他的限速/日志绕过去了;
#   · jump / goto 不搬 —— 目标链在他自己的表里, 搬过来根本不合法。
# 剩下引用了他表内 set/map 的规则, 由调用方用 `nft -c` 在一张试验表里验一遍挡住。
_VERDICT_ACCEPT = re.compile(r"\baccept\s*$")
_UNMOVABLE = re.compile(r"\b(limit|log|jump|goto|queue|dup|fwd)\b")


def extract_accepts(conf_txt, live_txt):
    """→ (可搬的规则行, 搬不动的 [(规则, 原因)])。只看外来 input base chain。"""
    movable, stuck = [], []
    for txt in (conf_txt or "", live_txt or ""):
        cur, depth, chain_depth = None, 0, None
        for raw in txt.split("\n"):
            ln = _strip_noise(raw)
            m = _TBL_OPEN.match(ln)
            if m and cur is None:
                cur, depth = "%s %s" % (m.group(1), m.group(2)), 0
            if cur is None:
                continue
            depth += ln.count("{") - ln.count("}")
            if _HOOK_IN.search(ln) and cur != OURS:
                chain_depth = depth
                continue
            if chain_depth is None:
                if depth <= 0:
                    cur = None
                continue
            if depth < chain_depth:
                chain_depth = None
                if depth <= 0:
                    cur = None
                continue
            body = raw.split("#", 1)[0].strip()
            if not body or body in ("{", "}"):
                continue
            if _pdg_covers(raw):
                continue                       # 我们的链本来就有, 不必重复搬
            if not _VERDICT_ACCEPT.search(body):
                stuck.append((body, "判决不是 accept(搬过去会改变行为)"))
            elif _UNMOVABLE.search(body):
                stuck.append((body, "带 limit/log/jump 之类, 复制一份会把原来的语义绕过去"))
            elif body not in movable:
                movable.append(body)
    return movable, stuck


def _describe(src, table, n_rules, policy_drop, samples):
    """冲突描述。**把具体规则贴出来** —— 只说"1 条规则"的话, 用户既不知道是哪条、也就无从
    判断该并进 pdg 还是改挂别的 hook; 远程协助时同样只能靠猜。"""
    why = "policy drop" if policy_drop else "%d 条规则" % n_rules
    item = "%s: 表 `%s` 有挂 hook input 的 base chain(%s)" % (src, table, why)
    if samples:
        item += "\n      " + "\n      ".join(samples)
        if n_rules > len(samples):
            item += "\n      …(共 %d 条, 只列前 %d 条)" % (n_rules, len(samples))
    return item


def scan_text(conf_txt, live_txt):
    """扫描配置文本与运行 ruleset 文本, 返回冲突描述列表(每源一条, 已去重)。

    **空骨架不算冲突**: Debian 的 nftables 包自带一份 /etc/nftables.conf, 里面是一个
    `table inet filter`, 三条 base chain 全是 `policy accept` 且一条规则都没有 —— 全新
    VPS 上装了 nftables 就长这样。它既不 drop 任何包、也没有会被架空的放行, 完全惰性;
    把它当冲突拒掉, 等于绝大多数新机器都装不上, 而用户根本不知道要删哪一行。
    真正要挡的是两种: 链里**有规则**(那些放行会被 PDG 的 policy drop 架空), 或者链自己
    就是 **policy drop**(那它会把本项目要放行的端口直接丢掉)。"""
    found, seen = [], set()
    for src, txt in (("配置文件", conf_txt or ""), ("运行 ruleset", live_txt or "")):
        cur, depth, opened = None, 0, False
        chain_depth = None          # 正处在某条 foreign input chain 里
        chain_rules = 0
        chain_samples = []          # 具体是哪几条 —— 只报个数字, 用户没法判断该怎么办
        chain_policy_drop = False
        for raw in txt.split("\n"):
            ln = _strip_noise(raw)
            m = _TBL_OPEN.match(ln)
            if m and cur is None:
                cur, depth, opened = "%s %s" % (m.group(1), m.group(2)), 0, False
            if cur is None:
                continue
            depth += ln.count("{") - ln.count("}")
            if depth > 0:
                opened = True
            if _HOOK_IN.search(ln) and cur != OURS:
                chain_depth = depth                     # 从下一行起是链体
                chain_rules = 0
                chain_samples = []
                chain_policy_drop = bool(_POLICY_DROP.search(ln))
            elif chain_depth is not None:
                if depth < chain_depth:                 # 链结束: 结账
                    if chain_rules or chain_policy_drop:
                        item = _describe(src, cur, chain_rules, chain_policy_drop, chain_samples)
                        if item not in seen:
                            seen.add(item); found.append(item)
                    chain_depth = None
                elif ln.strip().strip("{}").strip():     # 非空、非纯括号 = 一条规则
                    if _pdg_covers(raw):
                        continue                        # 我们的链原样放行同样的流量 → 不算架空
                    chain_rules += 1
                    if len(chain_samples) < 3:
                        chain_samples.append(raw.strip()[:90])
            if opened and depth <= 0:
                cur, opened = None, False
        if chain_depth is not None and (chain_rules or chain_policy_drop):   # 文本到头还没闭合
            item = _describe(src, cur, chain_rules, chain_policy_drop, chain_samples)
            if item not in seen:
                seen.add(item); found.append(item)
    return found


def nft_bin():
    """找到 nft 可执行文件的路径(找不到返回 "")。

    不能只靠 PATH: nft 装在 /usr/sbin, 而 `su`(不带 -)、cron、某些容器的 root PATH 里没有
    sbin 目录。那时 `nft` 找不到 → 读不到运行 ruleset → 扫描返回"无法确认", 调用方再按
    "nft 没装, 没有现网规则可冲突"放行 —— 机器上明明有一整套 input 链, 却被当成裸机装上去。
    所以按 PATH → 常见 sbin 路径依次找; 这也是 shell 侧(install.sh)判断"nft 到底在不在"的
    同一份依据(见 --nft-path)。"""
    from shutil import which
    p = which("nft")
    if p:
        return p
    for cand in NFT_CANDIDATES:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return ""


def live_ruleset():
    """(文本, readable)。readable=False 表示**没读到**, 不代表现场干净。"""
    exe = nft_bin()
    if not exe:
        return "", False
    try:
        p = subprocess.run([exe, "list", "ruleset"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return "", False
    if p.returncode != 0:
        return "", False
    return p.stdout, True


def read_conf(conf=NFT_CONF):
    try:
        with open(conf, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def scan(conf=NFT_CONF):
    """(冲突列表, 运行 ruleset 是否读到)。"""
    live, readable = live_ruleset()
    return scan_text(read_conf(conf), live), readable


def main(argv):
    # --nft-path: 只回答"nft 到底在不在(在哪)" —— 让 shell 侧不必自己 `command -v nft`,
    # 那个判断会漏掉 PATH 里没有 sbin 的情况, 两处各写一份迟早给出相反答案。
    # 找到 → 打印路径并 exit 0; 找不到 → 不打印, exit 1。
    if "--nft-path" in argv[1:]:
        exe = nft_bin()
        if exe:
            print(exe)
            return 0
        return 1
    # --extract-accepts: 把外来 input 链里可以安全搬走的 accept 规则打印出来(每行一条)。
    # 装机据此把它们复制进 /etc/privdns-gateway/nft-input.d/, 用户的放行就不再被我们的
    # policy drop 架空 —— 而他自己那张表一个字节都不用改。
    # 退出码: 0=有可搬的(已打印) 1=没有可搬的 2=有搬不动的(原因打到 stderr)/读不到 ruleset。
    if "--extract-accepts" in argv[1:]:
        rest = [a for a in argv[1:] if a != "--extract-accepts"]
        conf = rest[0] if rest else NFT_CONF
        try:
            with open(conf, encoding="utf-8") as f:
                conf_txt = f.read()
        except OSError:
            conf_txt = ""
        live_txt, readable = live_ruleset()
        if not readable:
            print("读不到运行 ruleset, 无法判断要搬哪些规则", file=sys.stderr)
            return 2
        movable, stuck = extract_accepts(conf_txt, live_txt)
        for body, why in stuck:
            print("%s\t%s" % (body, why), file=sys.stderr)
        if stuck:
            return 2
        if not movable:
            return 1
        print("\n".join(movable))
        return 0
    conf = argv[1] if len(argv) > 1 else NFT_CONF
    found, readable = scan(conf)
    if found:
        print("\n".join(found))
        return 0                     # 有冲突: 比"读不到"更严, 优先按冲突处理
    if not readable:
        print("读不到运行中的 nftables ruleset(nft 不可用或权限不足), 无法确认内存里是否还有 input 链")
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

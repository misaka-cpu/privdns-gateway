#!/usr/bin/env python3
"""把渲染好的 `table inet pdg` 块**合并**进现网 /etc/nftables.conf —— 装机与迁移共用的
单一实现(以前只有迁移侧有, 装机直接整文件覆盖, 用户的 VPN/NAT/转发/开放端口就没了)。

只替换本项目管理区(table inet pdg 的声明 / delete / 表体), 其余内容逐字节保留。
无法证明能安全合并(pdg 块括号不配平 / flush ruleset 会冲掉只存在于运行中的表)→ 返回非 0,
调用方必须在改动运行环境**之前**中止。

用法: nftmerge.py <渲染好的块> <现网 nftables.conf> <输出文件>
退出码: 0=已写出合并结果; 2=pdg 块括号不配平;
        3=文件里的 flush ruleset 会冲掉只存在于运行中的表; 1=其它错误。
"""
import re
import subprocess
import sys

if len(sys.argv) < 4:
    print(__doc__.strip().splitlines()[-2], file=sys.stderr)
    sys.exit(1)
block_f, target_f, out_f = sys.argv[1:4]
block = open(block_f, encoding="utf-8").read()
# 只取模板里的规则部分(从第一处 `table inet pdg` 起) —— 整个模板带 shebang 与大段头注释,
# 原样插进现网文件中段会多出一个 `#!/usr/sbin/nft -f`, 既难看也容易误导读者。
BANNER = "# ==== PrivDNS Gateway 管理区(table inet pdg): 由 pdg 自动维护, 勿手改 ===="
_m = re.search(r"^\s*table\s+inet\s+pdg\b", block, re.M)
if _m:
    block = BANNER + "\n" + block[_m.start():]
block = block.rstrip("\n")
try:
    lines = open(target_f, encoding="utf-8").read().split("\n")
except OSError:
    lines = []

decl = re.compile(r"^\s*table\s+inet\s+pdg\s*$")
dele = re.compile(r"^\s*delete\s+table\s+inet\s+pdg\s*$")
open_ = re.compile(r"^\s*table\s+inet\s+pdg\s*\{")
other_table = re.compile(r"^\s*(table)\s+\S+\s+(\S+)")

keep, i, first_hit, n = [], 0, None, len(lines)
while i < n:
    ln = lines[i]
    # 上一次合并插进去的横幅也属于管理区 —— 不摘掉的话每合并一次就多一条, 反复跑同一条命令
    # 文件都在变(幂等性没了, diff 也没法看)
    if ln.strip() == BANNER or decl.match(ln) or dele.match(ln):
        first_hit = len(keep) if first_hit is None else first_hit
        i += 1; continue
    if open_.match(ln):                      # 整个 table inet pdg { ... } 块
        first_hit = len(keep) if first_hit is None else first_hit
        start_line = i + 1                   # 1-indexed, 报给用户看
        depth = 0
        while i < n:
            depth += lines[i].count("{") - lines[i].count("}")
            i += 1
            if depth <= 0:
                break
        if depth > 0:
            print("冲突位置: %s 第 %d 行起的 `table inet pdg {` 块括号不配平(到文件末尾仍未闭合)"
                  % (target_f, start_line), file=sys.stderr)
            print("  该行: %s" % lines[start_line - 1].strip(), file=sys.stderr)
            sys.exit(2)
        continue
    keep.append(ln); i += 1

# 一张"只存在于运行中"的表被 flush 掉, 到底会不会真丢东西。
#
# 判据与 nftscan.py 的"空骨架不算冲突"同源: 没有任何规则、也没有 policy drop 的表是**惰性**的。
# Debian 上 iptables 默认是 iptables-nft, 任何东西碰一下 iptables(cloud-init、包的 postinst、
# 甚至一句 `iptables -L`)就会在内核里建出空的 `table ip filter` / `table ip nat` —— 链在、
# 策略 accept、一条规则都没有。全新 Debian 13 装完就长这样。冲掉它什么也没丢, iptables-nft
# 下次用到时自己重建。而 Docker / fail2ban 那种真往里塞了规则的, 冲掉就是真丢, 必须拦。
#
# 读不出来 → 当成有内容(fail-closed): 判不了就别赌。
def _table_is_inert(family, name):
    txt = None
    for args in (["nft", "-j", "list", "table", family, name],
                 ["nft", "list", "table", family, name]):
        try:
            p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               universal_newlines=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            return False
        if p.returncode == 0 and p.stdout.strip():
            txt = p.stdout
            if args[1] == "-j":
                try:
                    import json
                    objs = json.loads(txt).get("nftables") or []
                except Exception:  # noqa: BLE001
                    continue                       # JSON 版不可用 → 退到文本版再判
                for o in objs:
                    if not isinstance(o, dict):
                        continue
                    if "rule" in o:
                        return False               # 有规则 → 冲掉就是真丢
                    ch = o.get("chain")
                    if isinstance(ch, dict) and str(ch.get("policy", "accept")) != "accept":
                        return False               # policy drop/其它 → 不是惰性的
                    if "set" in o or "map" in o or "element" in o:
                        return False
                return True
            break
    if txt is None:
        return False
    # 文本兜底: 去注释后, 表体里除了 table/chain 声明、type…hook…policy accept 与括号,
    # 再有别的内容就当作"有规则"。policy 非 accept 同样算。
    for raw in txt.split("\n"):
        ln = raw.split("#", 1)[0].strip()
        if not ln or ln in ("{", "}"):
            continue
        if re.match(r"^table\s+\S+\s+\S+\s*\{?$", ln):
            continue
        if re.match(r"^chain\s+\S+\s*\{?$", ln):
            continue
        if re.match(r"^type\s+\w+\s+hook\s+\w+\s+priority\s+[^;]+;\s*(policy\s+accept\s*;)?\s*\}?$", ln):
            continue
        if re.match(r"^type\s+\w+\s+hook\s+\w+\s+priority\s+[^;]+;\s*policy\s+\w+\s*;", ln):
            return False                           # policy 不是 accept
        return False
    return True


# 文件顶上的 `flush ruleset` 会在应用时清掉**全部**运行中的表。但文件里写着的那些表随后
# 又会被同一份文件重建 —— 真正会消失的只有"只存在于运行时、不在文件里"的表(Docker、
# fail2ban、k8s 这类自己往内核里塞规则的)。
# 早先这里一律按"有 flush + 还有别的表"就拒, 结果把最常见的现场也挡住了: Debian 的
# nftables 包自带的 /etc/nftables.conf 正是 `flush ruleset` + 一个空的 table inet filter,
# 全新 VPS 装了 nftables 就长这样, 于是谁都装不上。而且那个 flush 本来就是管理员自己文件里
# 的东西, 我们的合并并没有让它多冲掉任何一张表。
rest_lines = keep
flush_ln = next((k + 1 for k, ln in enumerate(rest_lines)
                 if re.match(r"^\s*flush\s+ruleset\s*$", ln)), None)
if flush_ln:
    in_file = set()
    for ln in rest_lines:
        m2 = other_table.match(ln)
        if m2:
            parts = ln.split()
            if len(parts) >= 3:
                in_file.add("%s %s" % (parts[1], parts[2].rstrip("{")))
    in_file.add("inet pdg")                   # 合并进去的就是它
    live = []
    try:
        p = subprocess.run(["nft", "list", "tables"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=15)
        if p.returncode == 0:
            for ln in p.stdout.splitlines():
                parts = ln.split()
                if len(parts) >= 3 and parts[0] == "table":
                    live.append("%s %s" % (parts[1], parts[2]))
    except (OSError, subprocess.SubprocessError):
        live = []                             # 读不到运行 ruleset: flush 本就是文件自带的,
                                              # 我们没让情况变糟 → 不因此拒绝合并
    lost = [t for t in live if t not in in_file]
    # 惰性的(没规则、没 policy drop)不算损失: 见 _table_is_inert。全新 Debian 13 上
    # iptables-nft 建出来的空 ip filter / ip nat 正属此类, 早先一律拒等于新机器装不上。
    inert = [t for t in lost if _table_is_inert(*t.split(None, 1))]
    lost = [t for t in lost if t not in inert]
    if inert:
        print("提示: 这些只存在于运行中的表是空的(没有规则, 策略 accept), 应用时会被 "
              "`flush ruleset` 一并清掉, 但**什么都不会丢** —— iptables-nft 之类下次用到会自己重建:",
              file=sys.stderr)
        for t in inert[:5]:
            print("    table %s" % t, file=sys.stderr)
    if lost:
        print("冲突位置: %s 第 %d 行 `flush ruleset` —— 这些**只存在于运行中**的表不在文件里, "
              "而且里面**有规则**(或策略不是 accept), 应用后会被一起冲掉:"
              % (target_f, flush_ln), file=sys.stderr)
        for t in lost[:5]:
            print("    table %s   (看内容: nft list table %s)" % (t, t), file=sys.stderr)
        print("  常见来源: Docker / fail2ban / k8s 这类自己往内核塞规则的程序。", file=sys.stderr)
        print("  请先把它们写进 /etc/nftables.conf(或去掉那行 flush ruleset)再重试。", file=sys.stderr)
        sys.exit(3)

if first_hit is None:                         # 现网没有 pdg 区 → 追加到末尾
    while keep and not keep[-1].strip():
        keep.pop()
    merged = "\n".join(keep) + ("\n\n" if keep else "") + block
else:
    head, tail = keep[:first_hit], keep[first_hit:]
    while head and not head[-1].strip():          # 管理区前后的空行由本函数统一给,
        head.pop()                                # 否则每次合并都会多攒一个空行
    while tail and not tail[0].strip():
        tail.pop(0)
    merged = "\n".join(head + ([""] if head else []) + block.split("\n")
                        + ([""] if tail else []) + tail)
if not merged.endswith("\n"):
    merged += "\n"
open(out_f, "w", encoding="utf-8").write(merged)
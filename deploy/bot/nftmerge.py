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
import os
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

# 这张表是谁在管 —— 决定给什么建议。把 Docker 的动态规则"写进 /etc/nftables.conf"是**错的**:
# 它随容器起停不断变, 冻进静态文件下次就对不上。这类只能去掉那行 flush ruleset。
_OWNERS = (
    ("Docker",   ("DOCKER", "DOCKER-USER", "DOCKER-ISOLATION-STAGE-1",
                  "DOCKER-ISOLATION-STAGE-2", "DOCKER-INGRESS")),
    ("fail2ban", ("f2b-sshd", "f2b-SSH")),
    ("libvirt",  ("LIBVIRT_INP", "LIBVIRT_OUT", "LIBVIRT_FWO", "LIBVIRT_FWI", "LIBVIRT_PRT")),
    ("Kubernetes/CNI", ("KUBE-SERVICES", "KUBE-NODEPORTS", "KUBE-FIREWALL", "cali-INPUT")),
)


def _owner_of(chains):
    up = {c.upper() for c in chains}
    for name, marks in _OWNERS:
        if any(m.upper() in up for m in marks) or any(
                c.startswith(marks[0].upper().split("-")[0]) for c in up if marks[0][0].isupper()):
            return name
    return None


# 去掉 `flush ruleset` 之后, 这份文件还能不能反复 `nft -f` 而不出问题。
#
# 那行的作用是让重复应用幂等。去掉它, 文件里**带规则**的表会在每次 reload 时把规则再加一遍
# (nftables 的 table 块是叠加的), 越攒越多。所以只有当文件里除 pdg 之外的表**都是空的**
# (只有链声明与 policy accept, 没有规则)时, 去掉才是无害的 —— 那正是发行版自带的那份骨架。
#
# 本项目自己的块不依赖那行 flush: 模板是 `table inet pdg` + `delete table inet pdg` +
# 表体, 先声明再删, 每次只重建自己这一张。
def _file_table_blocks(lines):
    """文件里的顶层 table 块 → [(名字, 起始行下标, 结束行下标, 有没有规则, 链名集合)]。

    解析不确定就返回 None(调用方据此 fail-closed) —— 宁可让人自己动手, 也不要在猜的基础上
    往别人的防火墙文件里插 `delete table`。"""
    out, cur, start, depth, has_rule, chains = [], None, 0, 0, False, set()
    for i, raw in enumerate(lines):
        ln = raw.split("#", 1)[0].strip()
        if not ln:
            continue
        if cur is None:
            m = other_table.match(ln)
            if not m:
                continue
            parts = ln.split()
            if len(parts) < 3:
                continue
            if "{" not in ln:
                continue                      # 只是声明行(table X / delete table X), 不是块
            cur = "%s %s" % (parts[1], parts[2].rstrip("{"))
            start, depth, has_rule, chains = i, ln.count("{") - ln.count("}"), False, set()
            continue
        depth += ln.count("{") - ln.count("}")
        body = ln.strip("{}").strip()
        if body:
            mc = re.match(r"^chain\s+(\S+)$", body)
            if mc:
                chains.add(mc.group(1))
            elif re.match(r"^type\s+\w+\s+hook\s+\w+\s+priority\s+[^;]+;"
                          r"(\s*policy\s+\w+\s*;)?$", body):
                pass
            else:
                has_rule = True
        if depth <= 0:
            out.append((cur, start, i, has_rule, chains))
            cur, depth = None, 0
    if cur is not None:
        return None                           # 括号没闭合 → 解析不可信
    return out


def _make_tables_self_rebuilding(lines, probed):
    """给文件里**带规则**的表加上 `table X` + `delete table X`, 让它们各自幂等。

    这样去掉全局 flush 之后, 重复 `nft -f` 也不会让规则累积 —— 每张表只重建自己, 文件外的
    表(Docker 等)原样留着。与本项目自己那块用的是同一个写法。

    有一种情况不能这么干: 那张表**别人也在往里加东西**(内核里的链比文件里声明的多), 比如
    用户写了 `table ip filter { chain INPUT … }` 而 Docker 又往 ip filter 里加了 DOCKER-USER。
    `delete table ip filter` 会把 Docker 那部分一起删掉。这时返回 None, 交由调用方中止。

    返回 (新行列表, 处理过的表名) 或 (None, 冲突表名)。"""
    blocks = _file_table_blocks(lines)
    if blocks is None:
        return None, None
    todo = [b for b in blocks if b[3] and b[0] != "inet pdg"]
    for name, _s, _e, _hr, file_chains in todo:
        fam_name = name.split(None, 1)
        if len(fam_name) != 2:
            return None, name
        live_inert, live_chains = probed.get(name) or _table_probe(*fam_name)
        if live_chains - file_chains:         # 内核里有文件没声明的链 = 这张表是共管的
            return None, name
    out, done = list(lines), []
    for name, start, _e, _hr, _c in sorted(todo, key=lambda b: -b[1]):
        prev = out[start - 1].strip() if start > 0 else ""
        if prev == "delete table %s" % name:
            continue                          # 已经是自重建形态
        out[start:start] = ["# ↓ 由 pdg 补上: 让这张表自己重建, 去掉全局 flush 后也不会累积规则",
                            "table %s" % name,
                            "delete table %s" % name]
        done.append(name)
    return out, done


def _file_tables_are_empty(lines):
    cur, depth = None, 0
    for raw in lines:
        ln = raw.split("#", 1)[0].strip()
        if not ln:
            continue
        m = other_table.match(ln)
        if m and cur is None and depth == 0:
            parts = ln.split()
            cur = "%s %s" % (parts[1], parts[2].rstrip("{")) if len(parts) >= 3 else None
            depth = ln.count("{") - ln.count("}")
            continue
        if cur is None:
            continue
        depth += ln.count("{") - ln.count("}")
        body = ln.strip("{}").strip()
        if body and cur != "inet pdg":
            if re.match(r"^chain\s+\S+$", body):
                pass
            elif re.match(r"^type\s+\w+\s+hook\s+\w+\s+priority\s+[^;]+;"
                          r"(\s*policy\s+accept\s*;)?$", body):
                pass
            else:
                return False, cur              # 有规则(或 policy 非 accept)→ 去掉 flush 会累积
        if depth <= 0:
            cur, depth = None, 0
    return True, None


# 一张"只存在于运行中"的表被 flush 掉, 到底会不会真丢东西。
#
# 判据与 nftscan.py 的"空骨架不算冲突"同源: 没有任何规则、也没有 policy drop 的表是**惰性**的。
# Debian 上 iptables 默认是 iptables-nft, 任何东西碰一下 iptables(cloud-init、包的 postinst、
# 甚至一句 `iptables -L`)就会在内核里建出空的 `table ip filter` / `table ip nat` —— 链在、
# 策略 accept、一条规则都没有。全新 Debian 13 装完就长这样。冲掉它什么也没丢, iptables-nft
# 下次用到时自己重建。而 Docker / fail2ban 那种真往里塞了规则的, 冲掉就是真丢, 必须拦。
#
# 读不出来 → 当成有内容(fail-closed): 判不了就别赌。
def _table_probe(family, name):
    """返回 (是否惰性, 链名集合)。链名用来判断这张表是谁在管(见 _owner_of)。"""
    chains = set()
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
                inert = True
                for o in objs:
                    if not isinstance(o, dict):
                        continue
                    ch = o.get("chain")
                    if isinstance(ch, dict):
                        if ch.get("name"):
                            chains.add(str(ch["name"]))
                        if str(ch.get("policy", "accept")) != "accept":
                            inert = False          # policy drop/其它 → 不是惰性的
                    if "rule" in o:
                        inert = False              # 有规则 → 冲掉就是真丢
                        r = o.get("rule")
                        if isinstance(r, dict) and r.get("chain"):
                            chains.add(str(r["chain"]))
                    if "set" in o or "map" in o or "element" in o:
                        inert = False
                return inert, chains
            break
    if txt is None:
        return False, chains
    # 文本兜底: 去注释后, 表体里除了 table/chain 声明、type…hook…policy accept 与括号,
    # 再有别的内容就当作"有规则"。policy 非 accept 同样算。
    inert = True
    for raw in txt.split("\n"):
        ln = raw.split("#", 1)[0].strip()
        if not ln or ln in ("{", "}"):
            continue
        if re.match(r"^table\s+\S+\s+\S+\s*\{?$", ln):
            continue
        mc = re.match(r"^chain\s+(\S+)\s*\{?$", ln)
        if mc:
            chains.add(mc.group(1))
            continue
        if re.match(r"^type\s+\w+\s+hook\s+\w+\s+priority\s+[^;]+;\s*(policy\s+accept\s*;)?\s*\}?$", ln):
            continue
        inert = False                              # 规则 / policy 非 accept
    return inert, chains


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
    probed = {t: _table_probe(*t.split(None, 1)) for t in lost}
    inert = [t for t in lost if probed[t][0]]
    lost = [t for t in lost if t not in inert]
    owners = {}
    for t in lost:
        o = _owner_of(probed[t][1])
        if o:
            owners.setdefault(o, []).append(t)
    if inert:
        print("提示: 这些只存在于运行中的表是空的(没有规则, 策略 accept), 应用时会被 "
              "`flush ruleset` 一并清掉, 但**什么都不会丢** —— iptables-nft 之类下次用到会自己重建:",
              file=sys.stderr)
        for t in inert[:5]:
            print("    table %s" % t, file=sys.stderr)
    # 真会丢东西, 但如果文件里除 pdg 外的表都是空的, 那么**去掉那行 flush 就两全**:
    # 运行中的表(Docker 等)不再被冲, 文件重复应用也不会累积规则。这一步是装机能否在
    # Docker 主机上自动跑通的关键 —— 否则每个用 Docker 的人都得先手工改一遍防火墙文件。
    # PDG_KEEP_FLUSH=1 可以关掉这个行为(保持中止, 由人自己处置)。
    if lost and os.environ.get("PDG_KEEP_FLUSH", "") not in ("1", "yes", "true"):
        empty_ok, culprit = _file_tables_are_empty(rest_lines)
        rebuilt = []
        if not empty_ok:
            # 文件里的表有规则也不必立刻投降: 给它们各自加上 declare+delete, 让每张表自己
            # 重建 —— 全局 flush 的幂等效果就有了替代, 而文件外的表不再被牵连。
            newlines, info = _make_tables_self_rebuilding(rest_lines, probed)
            if newlines is not None:
                keep = newlines
                rest_lines = newlines
                flush_ln = next((k + 1 for k, ln in enumerate(rest_lines)
                                 if re.match(r"^\s*flush\s+ruleset\s*$", ln)), flush_ln)
                rebuilt, empty_ok = info, True
            else:
                culprit = info or culprit
        if empty_ok:
            note = ("  # ↑ 由 pdg 注释掉: 这行会把只存在于运行中的表(%s)一并冲掉。"
                    % "、".join(lost[:3]))
            keep[flush_ln - 1] = "# " + keep[flush_ln - 1].strip() + note
            keep.insert(flush_ln,
                        ("#   你自己的表已补上 `table X`+`delete table X`(各自重建), 因此不会累积;"
                         if rebuilt else
                         "#   本文件里除 pdg 外的表都是空的, 去掉它不会造成规则累积;"))
            keep.insert(flush_ln + 1, "#   pdg 自己的表用 `delete table inet pdg` 重建, 不依赖它。")
            keep.insert(flush_ln + 2, "#   要恢复原样: 删掉本行与上下两行的注释即可。")
            print("注意: 已把 %s 第 %d 行的 `flush ruleset` **注释掉**(原行保留在文件里)。"
                  % (target_f, flush_ln), file=sys.stderr)
            print("  原因: 它会把这些只存在于运行中的表一并冲掉 —— %s。"
                  % "、".join(lost[:3]), file=sys.stderr)
            for t in lost[:3]:
                o = _owner_of(probed[t][1])
                if o:
                    print("        table %s 看链名像是 %s 在管。" % (t, o), file=sys.stderr)
            print("  这行本来就会在每次 `systemctl reload nftables` 时冲掉它们, 与本项目无关;",
                  file=sys.stderr)
            if rebuilt:
                print("  同时给你自己的表补上了 `table X` + `delete table X`(每张表自己重建), "
                      "所以去掉全局 flush 之后重复应用也不会让规则累积: %s。"
                      % "、".join(rebuilt[:3]), file=sys.stderr)
            else:
                print("  本文件里除 pdg 外的表都是空的, 去掉它不会让规则累积。", file=sys.stderr)
            print("  不想让我们动它: 设 PDG_KEEP_FLUSH=1 重跑, 本次改动会被拒绝而不是自动处理。",
                  file=sys.stderr)
            lost = []
        else:
            print("提示: 本可以注释掉 `flush ruleset` 来两全, 但 `table %s` 在内核里还有"
                  "文件没声明的链 —— 它是和别人(Docker 之类)共管的, 给它加 `delete table` 会"
                  "把别人那部分一起删掉, 所以没动。" % culprit, file=sys.stderr)
    if lost:
        print("冲突位置: %s 第 %d 行 `flush ruleset` —— 这些**只存在于运行中**的表不在文件里, "
              "而且里面**有规则**(或策略不是 accept), 应用后会被一起冲掉:"
              % (target_f, flush_ln), file=sys.stderr)
        for t in lost[:5]:
            o = _owner_of(probed[t][1])
            print("    table %s%s   (看内容: nft list table %s)"
                  % (t, ("   ← 看链名像是 %s 在管" % o) if o else "", t), file=sys.stderr)
        if owners:
            print("  %s 的规则是**动态**的(随容器/服务起停不断变), 把它们抄进 "
                  "/etc/nftables.conf 是错的 —— 下次就对不上了。" % "、".join(sorted(owners)),
                  file=sys.stderr)
            print("  这种情况请**去掉 `flush ruleset` 那一行**:", file=sys.stderr)
            print("      sudo sed -i '/^flush ruleset$/d' %s" % target_f, file=sys.stderr)
            print("  那行本来就会在每次 `systemctl reload nftables` 时把这些表冲掉 —— "
                  "去掉它对你有好处, 与本项目无关。", file=sys.stderr)
        else:
            print("  常见来源: Docker / fail2ban / k8s 这类自己往内核塞规则的程序。", file=sys.stderr)
            print("  请先把它们写进 %s, 或者去掉 `flush ruleset` 那一行:" % target_f, file=sys.stderr)
            print("      sudo sed -i '/^flush ruleset$/d' %s" % target_f, file=sys.stderr)
        print("  改完重跑即可; 本项目自己的规则在独立的 table inet pdg 里, 不依赖那行 flush。",
              file=sys.stderr)
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
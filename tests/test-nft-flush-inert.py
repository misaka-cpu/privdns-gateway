#!/usr/bin/env python3
"""`flush ruleset` 那道门: 只该拦真会丢东西的表, 不该拦空骨架。

用户现场(全新 Debian 13, 2026-07-30 报): `/etc/nftables.conf` 是 nftables 包自带的那份
(`flush ruleset` + 一个空的 `table inet filter`), 而内核里还有 `table ip nat` / `table ip
filter` —— Debian 上 iptables 默认是 iptables-nft, 任何东西碰一下 iptables(cloud-init、
包的 postinst、甚至一句 `iptables -L`)就会把这两张空表建出来。装机因此中止:

    冲突位置: /etc/nftables.conf 第 3 行 flush ruleset —— 这些只存在于运行中的表不在文件里
        table ip nat
        table ip filter
    [x] 无法安全合并 → 未改动防火墙。

那两张表里一条规则都没有, 冲掉什么也不丢, iptables-nft 下次用到自己重建。nftscan.py 早就
按"空骨架不算冲突"处理了同一类现场, nftmerge.py 这道门没跟上 —— 于是**全新机器装不上**。

判据: 表里有规则、或策略不是 accept → 真会丢, 继续拒(Docker / fail2ban 就是这样);
      都没有 → 惰性, 放行并如实告知; 读不出来 → 当成有内容(fail-closed)。
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MERGE = os.path.join(ROOT, "deploy/bot/nftmerge.py")

pass_n = fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   " + m)
    pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] " + m)
    fail_n += 1


# 用户那台机器上 /etc/nftables.conf 的原样内容(Debian nftables 包自带)
STOCK_CONF = """#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
        chain forward {
                type filter hook forward priority filter;
        }
        chain output {
                type filter hook output priority filter;
        }
}
"""

BLOCK = """#!/usr/sbin/nft -f
table inet pdg {
        chain input { type filter hook input priority 0; policy drop; }
}
"""

# iptables-nft 按需建出来的空表: 链在、策略 accept、零规则
EMPTY_NAT = """{"nftables":[{"table":{"family":"ip","name":"nat"}},
{"chain":{"family":"ip","table":"nat","name":"PREROUTING","type":"nat","hook":"prerouting","policy":"accept"}},
{"chain":{"family":"ip","table":"nat","name":"POSTROUTING","type":"nat","hook":"postrouting","policy":"accept"}}]}"""
EMPTY_FILTER = """{"nftables":[{"table":{"family":"ip","name":"filter"}},
{"chain":{"family":"ip","table":"filter","name":"INPUT","type":"filter","hook":"input","policy":"accept"}}]}"""
# Docker 那种: 真往里塞了规则
DOCKER_NAT = """{"nftables":[{"table":{"family":"ip","name":"nat"}},
{"chain":{"family":"ip","table":"nat","name":"DOCKER","policy":"accept"}},
{"rule":{"family":"ip","table":"nat","chain":"POSTROUTING","expr":[{"masquerade":null}]}}]}"""
DROP_TABLE = """{"nftables":[{"table":{"family":"ip","name":"nat"}},
{"chain":{"family":"ip","table":"nat","name":"INPUT","type":"filter","hook":"input","policy":"drop"}}]}"""
# 文本兜底(没有 -j 的老 nft)
EMPTY_TEXT = """table ip nat {
	chain PREROUTING {
		type nat hook prerouting priority dstnat; policy accept;
	}
}"""
RULED_TEXT = """table ip nat {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "eth0" masquerade
	}
}"""


def make_nft(d, tables, bodies, json_ok=True):
    """造一个假 nft。tables=['ip nat',…]; bodies={'ip nat': json/text}。"""
    path = os.path.join(d, "nft")
    lines = ["#!/bin/sh",
             'if [ "$1" = "list" ] && [ "$2" = "tables" ]; then',
             "  printf '%s'" % "".join("table %s\\n" % t for t in tables),
             "  exit 0", "fi"]
    if json_ok:
        lines += ['if [ "$1" = "-j" ] && [ "$2" = "list" ] && [ "$3" = "table" ]; then',
                  '  case "$4 $5" in']
        for t, body in bodies.items():
            lines += ['    "%s") cat <<%s' % (t, "'JEOF'"), body, "JEOF", "      exit 0;;"]
        lines += ["  esac", "  exit 1", "fi"]
    else:
        # 没有 -j: 第一条命令失败, 走文本兜底
        lines += ['if [ "$1" = "-j" ]; then exit 1; fi',
                  'if [ "$1" = "list" ] && [ "$2" = "table" ]; then',
                  '  case "$3 $4" in']
        for t, body in bodies.items():
            lines += ['    "%s") cat <<%s' % (t, "'TEOF'"), body, "TEOF", "      exit 0;;"]
        lines += ["  esac", "  exit 1", "fi"]
    lines.append("exit 1")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


def run_merge(d, tables, bodies, json_ok=True, conf=STOCK_CONF):
    make_nft(d, tables, bodies, json_ok)
    cf = os.path.join(d, "nftables.conf")
    bf = os.path.join(d, "block.conf")
    of = os.path.join(d, "out.conf")
    with open(cf, "w") as f:
        f.write(conf)
    with open(bf, "w") as f:
        f.write(BLOCK)
    env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])
    p = subprocess.run([sys.executable, MERGE, bf, cf, of],
                       capture_output=True, text=True, timeout=120, env=env)
    out = ""
    if os.path.exists(of):
        with open(of) as f:
            out = f.read()
    return p.returncode, (p.stdout + p.stderr), out


def main():
    d = tempfile.mkdtemp(prefix="nftflush.")
    try:
        # ── 1. 用户现场: 空的 ip nat / ip filter → 必须放行 ──
        rc, msg, merged = run_merge(d, ["inet filter", "ip nat", "ip filter"],
                                    {"ip nat": EMPTY_NAT, "ip filter": EMPTY_FILTER})
        if rc == 0:
            ok("全新 Debian 13 现场(空的 ip nat / ip filter)→ 合并放行")
        else:
            bad("仍被拒(rc=%d): %s" % (rc, msg.strip().splitlines()[:1]))
        if "table inet pdg" in merged and "table inet filter" in merged:
            ok("合并结果里用户的表与 pdg 管理区都在")
        else:
            bad("合并结果不完整")
        if "什么都不会丢" in msg and "ip nat" in msg:
            ok("如实告知了这些空表会被 flush 掉但不丢东西")
        else:
            bad("没有告知空表的处置: %r" % msg[:120])

        # ── 2. Docker 那种(表里有规则)→ 必须继续拒 ──
        rc, msg, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DOCKER_NAT})
        if rc == 3 and "有规则" in msg:
            ok("表里有真规则(Docker/fail2ban)→ 仍然拒, 并说明原因")
        else:
            bad("有规则的表竟被放行(rc=%d)" % rc)
        if "nft list table ip nat" in msg:
            ok("给出了查看内容的命令")
        else:
            bad("没给排查命令")

        # ── 3. 策略不是 accept → 必须继续拒 ──
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DROP_TABLE})
        ok("policy drop 的表 → 仍然拒") if rc == 3 else bad("policy drop 被放行(rc=%d)" % rc)

        # ── 4. 读不出那张表 → fail-closed ──
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {})
        ok("读不出表内容 → fail-closed 拒绝(判不了就别赌)") if rc == 3 \
            else bad("读不出却放行了(rc=%d)" % rc)

        # ── 5. 老 nft 没有 -j: 文本兜底也要能分辨 ──
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": EMPTY_TEXT}, json_ok=False)
        ok("没有 -j 的老 nft: 空表走文本兜底 → 放行") if rc == 0 \
            else bad("文本兜底把空表拒了(rc=%d)" % rc)
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": RULED_TEXT}, json_ok=False)
        ok("没有 -j 的老 nft: 有规则的表 → 仍然拒") if rc == 3 \
            else bad("文本兜底放行了有规则的表(rc=%d)" % rc)

        # ── 6. 没有 flush ruleset 的文件, 这道门根本不该介入 ──
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DOCKER_NAT},
                             conf=STOCK_CONF.replace("flush ruleset\n", ""))
        ok("文件里没有 flush ruleset → 不因运行中的表拒绝") if rc == 0 \
            else bad("没有 flush 却被拒(rc=%d)" % rc)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print("────────────────────────────────────────")
    print("通过 %d, 失败 %d" % (pass_n, fail_n))
    return 1 if fail_n else 0


if __name__ == "__main__":
    sys.exit(main())

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
import re
import shutil
import subprocess
import sys
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

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

RULED_CONF = """#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter; policy drop;
                tcp dport 22 accept
        }
}
"""

# 边界现场: 用户自己在 nftables.conf 里写了**带规则**的表(不挂 input hook, 免得撞上另一道门)
OWN_RULED_CONF = """#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
}
table ip myforward {
        chain fwd {
                type filter hook forward priority filter; policy accept;
                ip saddr 10.8.0.0/24 accept
        }
}
"""

# 共管: 文件写了 ip filter, 内核里那张表还有文件没声明的链(Docker 加的)
SHARED_CONF = """#!/usr/sbin/nft -f

flush ruleset

table ip filter {
        chain FORWARD {
                type filter hook forward priority filter; policy accept;
                ip saddr 10.8.0.0/24 accept
        }
}
"""
MYFWD = """{"nftables":[{"table":{"family":"ip","name":"myforward"}},
{"chain":{"family":"ip","table":"myforward","name":"fwd","policy":"accept"}},
{"rule":{"family":"ip","table":"myforward","chain":"fwd","expr":[{"accept":null}]}}]}"""
SHARED_FILTER = """{"nftables":[{"table":{"family":"ip","name":"filter"}},
{"chain":{"family":"ip","table":"filter","name":"FORWARD","policy":"accept"}},
{"chain":{"family":"ip","table":"filter","name":"DOCKER-USER","policy":"accept"}},
{"rule":{"family":"ip","table":"filter","chain":"DOCKER-USER","expr":[{"accept":null}]}}]}"""

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
{"chain":{"family":"ip","table":"nat","name":"POSTROUTING","type":"nat","hook":"postrouting","policy":"accept"}},
{"rule":{"family":"ip","table":"nat","chain":"POSTROUTING","expr":[{"masquerade":null}]}}]}"""
# 谁都认不出来的第三方表: 建议要退回通用版(可以写进文件, 也可以去掉 flush)
UNKNOWN_RULED = """{"nftables":[{"table":{"family":"ip","name":"nat"}},
{"chain":{"family":"ip","table":"nat","name":"MYCHAIN","policy":"accept"}},
{"rule":{"family":"ip","table":"nat","chain":"MYCHAIN","expr":[{"accept":null}]}}]}"""
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


def run_merge(d, tables, bodies, json_ok=True, conf=STOCK_CONF, extra_env=None):
    make_nft(d, tables, bodies, json_ok)
    cf = os.path.join(d, "nftables.conf")
    bf = os.path.join(d, "block.conf")
    of = os.path.join(d, "out.conf")
    with open(cf, "w") as f:
        f.write(conf)
    with open(bf, "w") as f:
        f.write(BLOCK)
    # 上一轮的产物必须先删掉 —— 否则这一轮"中止、什么都没写"会读到旧文件, 判据就废了。
    if os.path.exists(of):
        os.unlink(of)
    env = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])
    env.pop("PDG_KEEP_FLUSH", None)
    env.update(extra_env or {})
    p = subprocess.run([sys.executable, MERGE, bf, cf, of],
                       capture_output=True, text=True, timeout=120, env=env)
    out = ""
    if os.path.exists(of):
        with open(of) as f:
            out = f.read()
    return p.returncode, (p.stdout + p.stderr), out


def flush_live(merged):
    """产物里的 flush ruleset 还生效吗(注释掉的不算)。"""
    for ln in merged.split("\n"):
        if re.match(r"^\s*flush\s+ruleset\s*$", ln):
            return True
    return False


def preserved(name, rc, merged):
    """核心不变量: 运行中、文件里没有、可能有内容的表, 绝不能因为我们被冲掉。

    两条达成路径都算合格 ——
      · rc=0 且产物里的 flush 已经不生效(注释掉了)→ 那张表活下来了;
      · rc=3 且没写出产物 → 什么都没动, 用户自己处置。
    不可接受的只有一种: rc=0 而产物里 flush 仍然生效。"""
    if rc == 3 and not merged:
        ok(name + ": 中止且未改动任何文件")
        return
    if rc == 0 and not flush_live(merged):
        ok(name + ": 放行, 且产物里的 flush 已失效 → 那张表不会被冲掉")
        return
    bad("%s: 危险组合(rc=%d, flush 仍生效=%s)" % (name, rc, flush_live(merged)))


def main():
    d = tmpguard.mkdtemp(prefix="nftflush.")
    try:
        # ── 1. 全新 Debian 13(iptables-nft 的空壳)→ 放行, 且不做多余改动 ──
        rc, msg, merged = run_merge(d, ["inet filter", "ip nat", "ip filter"],
                                    {"ip nat": EMPTY_NAT, "ip filter": EMPTY_FILTER})
        ok("全新 Debian 13 现场(空壳 ip nat / ip filter)→ 放行") if rc == 0 \
            else bad("空壳现场仍被拒(rc=%d)" % rc)
        if "table inet pdg" in merged and "table inet filter" in merged:
            ok("用户的表与 pdg 管理区都在")
        else:
            bad("合并结果不完整")
        if flush_live(merged):
            ok("空壳现场: flush 原样保留(表是空的, 冲掉也不丢, 不必多改一行)")
        else:
            bad("空壳现场把 flush 也动了 —— 多余的改动")
        if "什么都不会丢" in msg:
            ok("如实告知了空壳表的处置")
        else:
            bad("没告知空壳表的处置")

        # ── 2. Docker 主机, 文件里的表是空的 → 注释掉 flush, 装机继续 ──
        # 这是"算不算真修好"的分界: 只改错误信息, Docker 用户还得自己动手改防火墙文件。
        rc, msg, merged = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DOCKER_NAT})
        preserved("Docker 主机(文件表为空)", rc, merged)
        ok("Docker 主机能一把装上(rc=0)") if rc == 0 else bad("Docker 主机仍要人工干预(rc=%d)" % rc)
        if merged.count("# flush ruleset") == 1:
            ok("原行被注释掉而不是删掉(留痕可还原)")
        else:
            bad("flush 行处理得不对")
        if "由 pdg 注释掉" in merged and "要恢复原样" in merged:
            ok("文件里写清了是谁改的、为什么、怎么还原")
        else:
            bad("注释没有自我说明")
        if "已把" in msg and "注释掉" in msg and "PDG_KEEP_FLUSH=1" in msg:
            ok("终端如实告知, 并给了关掉这个行为的开关")
        else:
            bad("终端没说清: %r" % msg[-160:])
        if "Docker" in msg:
            ok("点名了那张表看着像谁在管")
        else:
            bad("没点名归属")

        # ── 3. 真正走不通的那一局: 文件写的表**和别人共管**(内核里有它没声明的链)──
        # 自重建那条路在这里不能走 —— `delete table ip filter` 会把 Docker 加进去的
        # DOCKER-USER 一并删掉。只能中止, 并给出正确的建议。
        rc, msg, merged = run_merge(d, ["ip filter", "ip nat"],
                                    {"ip nat": DOCKER_NAT, "ip filter": SHARED_FILTER},
                                    conf=SHARED_CONF)
        preserved("共管表 + Docker", rc, merged)
        if "共管" in msg:
            ok("说明了为什么这一局不能自动处理(表是共管的)")
        else:
            bad("没解释为什么没自动处理: %r" % msg[-200:])
        if "Docker" in msg and "动态" in msg:
            ok("认出 Docker → 给的是「去掉 flush」而不是「抄进文件」")
        else:
            bad("没给 Docker 专属建议")
        if "sed -i '/^flush ruleset$/d'" in msg:
            ok("给了可直接粘贴的命令")
        else:
            bad("没给可执行命令")
        if "抄进" in msg and "是错的" in msg:
            ok("明确否定了「写进 nftables.conf」这条错路")
        else:
            bad("没否定错误做法")
        if "nft list table ip nat" in msg:
            ok("给了查看表内容的命令")
        else:
            bad("没给排查命令")

        # ── 4. 同样走不通, 但那张表认不出归属 → 通用建议, 不瞎认成 Docker ──
        rc, msg, merged = run_merge(d, ["ip filter", "ip nat"],
                                    {"ip nat": UNKNOWN_RULED, "ip filter": SHARED_FILTER},
                                    conf=SHARED_CONF)
        preserved("共管表 + 未知归属", rc, merged)
        if "Docker 的规则是" not in msg and "常见来源" in msg:
            ok("认不出归属 → 给通用建议, 不瞎认")
        else:
            bad("对未知表给错了建议")

        # ── 5. policy drop / 读不出 / 文本兜底: 不变量都必须成立 ──
        for nm, bodies, jsn in (("policy drop 的表", {"ip nat": DROP_TABLE}, True),
                                ("读不出内容的表", {}, True),
                                ("文本兜底: 有规则", {"ip nat": RULED_TEXT}, False)):
            b = dict(bodies); b.setdefault("ip filter", SHARED_FILTER)
            rc, _, merged = run_merge(d, ["ip filter", "ip nat"], b,
                                      json_ok=jsn, conf=SHARED_CONF)
            preserved(nm, rc, merged)
        rc, _, merged = run_merge(d, ["inet filter", "ip nat"], {"ip nat": EMPTY_TEXT},
                                  json_ok=False)
        ok("文本兜底: 空壳表照常放行") if rc == 0 else bad("文本兜底把空壳拒了(rc=%d)" % rc)

        # ── 8. 边界: Docker 在跑, 而且用户自己的表也有规则 ──
        # 全局 flush 的幂等效果可以按表复现(declare + delete, 与本项目自己那块同一个写法),
        # 所以这一局也能自动跑通, 不必让用户二选一。
        rc, msg, merged = run_merge(d, ["inet filter", "ip nat", "ip myforward"],
                                    {"ip nat": DOCKER_NAT, "ip myforward": MYFWD},
                                    conf=OWN_RULED_CONF)
        preserved("Docker + 用户自己的表有规则", rc, merged)
        ok("这一局也能一把装上(rc=0)") if rc == 0 else bad("边界仍要人工干预(rc=%d)" % rc)
        if "delete table ip myforward" in merged and "table ip myforward\n" in merged:
            ok("用户带规则的表被补成自重建形态(declare + delete)")
        else:
            bad("没给用户的表加自重建")
        if merged.index("delete table ip myforward") < merged.index("table ip myforward {"):
            ok("declare/delete 插在表体之前(顺序对, 否则 nft 会报错)")
        else:
            bad("declare/delete 插错位置")
        if "由 pdg 补上" in merged:
            ok("补的那几行有自我说明")
        else:
            bad("补的行没说明来历")
        if "各自重建" in merged and "都是空的" not in merged:
            ok("文件里的说明写的是这一局真正的理由(自重建, 不是「表都是空的」)")
        else:
            bad("文件说明与实际路径对不上")
        if "补上了" in msg and "myforward" in msg:
            ok("终端也说清了给哪张表补了什么")
        else:
            bad("终端没说清: %r" % msg[-200:])

        # ── 6. PDG_KEEP_FLUSH=1: 用户说了别动, 就别动 ──
        rc, _, merged = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DOCKER_NAT},
                                  extra_env={"PDG_KEEP_FLUSH": "1"})
        preserved("PDG_KEEP_FLUSH=1", rc, merged)
        ok("设了 KEEP_FLUSH → 保持中止") if rc == 3 else bad("设了 KEEP_FLUSH 却自动改了(rc=%d)" % rc)

        # ── 7. 文件里没有 flush ruleset → 这道门根本不该介入 ──
        rc, _, _ = run_merge(d, ["inet filter", "ip nat"], {"ip nat": DOCKER_NAT},
                             conf=STOCK_CONF.replace("flush ruleset\n", ""))
        ok("文件里没有 flush → 不因运行中的表拒绝") if rc == 0 \
            else bad("没有 flush 却被拒(rc=%d)" % rc)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print("────────────────────────────────────────")
    print("通过 %d, 失败 %d" % (pass_n, fail_n))
    return 1 if fail_n else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""内网卡来源段的**唯一真源**回归(5.2/T7)。

以前"当前网段是多少"没有权威答案: 装机把它渲染进 nft 与 mosdns 两份配置, 读回时 checks 从
mosdns 正则抠, detect-cidr 又用 sed 同时改两处。少改一处的表现各不相同但都难查, 而救援服务
要靠这个值决定监听地址 —— 猜错就是把恢复入口绑到一个防火墙没放行(打不开)或没预期到的位置。

这里验的是真实行为:
  · profile.env 是真源, mosdns 只在"老装尚未迁移"时回退, 且此时必须被 doctor 报出来;
  · 四方漂移(真源/nft/mosdns/网卡)要能被检出并点名是哪一方偏了;
  · 迁移**保守**: 两处不一致或读不到, 一律不写入、不改动。
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


import checks  # noqa: E402


def _reset(profile=None, mosdns=None, nft_out=""):
    """把 checks 的三个来源指到临时文件/桩上。"""
    checks.PROFILE_ENV = profile or "/nonexistent/profile.env"
    checks.MOSDNS_CONF = mosdns or "/nonexistent/mosdns.yaml"
    checks._run = lambda cmd, **kw: (0, nft_out, "") if cmd[:2] == ["nft", "list"] else (0, "", "")


# ── 1. 真源优先: profile.env 与 mosdns 都有值时, 必须取 profile.env ──
with tempfile.TemporaryDirectory() as d:
    prof = os.path.join(d, "profile.env")
    mos = os.path.join(d, "mosdns.yaml")
    open(prof, "w").write("PDG_LOWMEM=0\nPDG_INTERNAL_CIDR=172.22.0.0/16\n")
    open(mos, "w").write('  - tag: npn_clients\n    args: { ips: ["10.9.0.0/16"] }\n')
    _reset(prof, mos)
    got = checks._internal_cidr()
    if got == "172.22.0.0/16":
        ok("真源优先: profile.env 的值胜过 mosdns 里的旧值")
    else:
        bad("真源没被优先采用, 拿到 %r" % got)

    # 2. 老装回退: 真源缺失时才读 mosdns
    open(prof, "w").write("PDG_LOWMEM=0\n")
    _reset(prof, mos)
    got = checks._internal_cidr()
    if got == "10.9.0.0/16":
        ok("老装回退: 真源缺失时读 mosdns(兼容尚未迁移的机器)")
    else:
        bad("回退失效, 拿到 %r" % got)

    # 3. 回退状态必须被 doctor 报出来, 不能静悄悄地用着
    _reset(prof, mos, nft_out="ip saddr 10.9.0.0/16 tcp dport { 53 } accept")
    r = checks.check_cidr_drift()
    if r and r[0] == "warn" and "PDG_INTERNAL_CIDR" in r[2]:
        ok("真源缺失时 doctor 报 warn 并指出要迁移")
    else:
        bad("真源缺失却没报出来: %r" % (r,))

# ── 4. 漂移检出: 三处不一致要点名是哪一方 ──
with tempfile.TemporaryDirectory() as d:
    prof = os.path.join(d, "profile.env")
    mos = os.path.join(d, "mosdns.yaml")
    open(prof, "w").write("PDG_INTERNAL_CIDR=172.22.0.0/16\n")
    open(mos, "w").write('    args: { ips: ["10.9.0.0/16"] }\n')
    _reset(prof, mos, nft_out="ip saddr 172.22.0.0/16 tcp dport { 53 } accept")
    r = checks.check_cidr_drift()
    if r and r[0] == "fail" and "mosdns=10.9.0.0/16" in r[2] and "172.22.0.0/16" in r[2]:
        ok("漂移检出: mosdns 落后时判 fail 并点名 mosdns")
    else:
        bad("mosdns 漂移没被正确报出: %r" % (r,))

    _reset(prof, mos, nft_out="ip saddr 10.0.0.0/8 tcp dport { 53 } accept")
    open(mos, "w").write('    args: { ips: ["172.22.0.0/16"] }\n')
    r = checks.check_cidr_drift()
    if r and r[0] == "fail" and "nft=10.0.0.0/8" in r[2]:
        ok("漂移检出: nft 落后时判 fail 并点名 nft")
    else:
        bad("nft 漂移没被正确报出: %r" % (r,))

    # 5. 三处一致 → ok
    _reset(prof, mos, nft_out="ip saddr 172.22.0.0/16 tcp dport { 53 } accept")
    r = checks.check_cidr_drift()
    if r and r[0] == "ok" and "172.22.0.0/16" in r[2]:
        ok("三处一致时判 ok")
    else:
        bad("三处一致却没判 ok: %r" % (r,))

    # 6. 真源里是非法 CIDR → fail(不能因为"三处一致"就放过一个坏值)
    open(prof, "w").write("PDG_INTERNAL_CIDR=not-a-cidr\n")
    open(mos, "w").write('    args: { ips: ["not-a-cidr"] }\n')
    _reset(prof, mos, nft_out="")
    r = checks.check_cidr_drift()
    if r and r[0] == "fail" and "合法 CIDR" in r[2]:
        ok("真源是非法 CIDR 时判 fail")
    else:
        bad("非法 CIDR 没被拦: %r" % (r,))

# ── 7-10. 迁移的保守语义(真跑 migrate_cidr_single_source) ──
PDG = os.path.join(ROOT, "deploy", "bot", "pdg.sh")


def run_migration(nft_text, mos_text, profile_text="PDG_LOWMEM=0\n"):
    """在临时根下真跑迁移函数, 返回 (退出码, 输出, 迁移后的 profile.env 内容)。"""
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "etc/privdns-gateway"), exist_ok=True)
    os.makedirs(os.path.join(d, "etc/mosdns"), exist_ok=True)
    prof = os.path.join(d, "etc/privdns-gateway/profile.env")
    open(prof, "w").write(profile_text)
    if nft_text is not None:
        open(os.path.join(d, "etc/nftables.conf"), "w").write(nft_text)
    if mos_text is not None:
        open(os.path.join(d, "etc/mosdns/config.yaml"), "w").write(mos_text)
    # 抽出函数体, 把三个绝对路径重指到临时根 —— 不打桩、不改实现, 跑的是真代码
    src = open(PDG, encoding="utf-8").read()
    m = re.search(r"^migrate_cidr_single_source\(\)\{.*?^\}", src, re.S | re.M)
    body = m.group(0).replace("/etc/privdns-gateway/profile.env", prof) \
                     .replace("/etc/nftables.conf", os.path.join(d, "etc/nftables.conf")) \
                     .replace("/etc/mosdns/config.yaml", os.path.join(d, "etc/mosdns/config.yaml")) \
                     .replace("mktemp /etc/privdns-gateway/", "mktemp " + os.path.join(d, "etc/privdns-gateway/"))
    script = "c_y(){ echo \"$*\"; }\nc_g(){ echo \"$*\"; }\n" + body + "\nmigrate_cidr_single_source\n"
    p = subprocess.run(["bash", "-c", script], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
    return p.returncode, p.stdout, open(prof, encoding="utf-8").read()


rc, out, prof = run_migration('ip saddr 172.22.0.0/16 tcp dport { 53 } accept\n',
                              '    args: { ips: ["172.22.0.0/16"] }\n')
if "PDG_INTERNAL_CIDR=172.22.0.0/16" in prof and rc == 0:
    ok("迁移: 两处一致 → 写入真源")
else:
    bad("一致却没写入真源: rc=%s prof=%r out=%r" % (rc, prof, out))
if "PDG_LOWMEM=0" in prof:
    ok("迁移: 保留 profile.env 里的其它键")
else:
    bad("迁移把别的键弄丢了: %r" % prof)

rc, out, prof = run_migration('ip saddr 10.0.0.0/8 tcp dport { 53 } accept\n',
                              '    args: { ips: ["172.22.0.0/16"] }\n')
if "PDG_INTERNAL_CIDR" not in prof:
    ok("迁移保守: 两处不一致 → **不写入**真源")
else:
    bad("不一致却把猜测固化进真源: %r" % prof)
if "不一致" in out and "detect-cidr" in out:
    ok("迁移保守: 不一致时说明原因并给出 detect-cidr 指引")
else:
    bad("不一致时没有可执行提示: %r" % out)

rc, out, prof = run_migration(None, None)
if "PDG_INTERNAL_CIDR" not in prof and "detect-cidr" in out:
    ok("迁移保守: 两处都读不到 → 不写入并提示")
else:
    bad("都读不到时行为不对: prof=%r out=%r" % (prof, out))

rc, out, prof = run_migration('ip saddr 10.9.0.0/16 tcp dport { 53 } accept\n',
                              '    args: { ips: ["10.9.0.0/16"] }\n',
                              profile_text="PDG_INTERNAL_CIDR=172.22.0.0/16\n")
if prof.strip() == "PDG_INTERNAL_CIDR=172.22.0.0/16":
    ok("迁移幂等: 已有真源时一个字节都不改")
else:
    bad("已有真源却被覆盖: %r" % prof)

# ── 11. 装机确实写入真源(读 install.sh 的实际写入与复核语句) ──
inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
if "PDG_INTERNAL_CIDR=%s" in inst and '"$INTERNAL_CIDR"' in inst:
    ok("装机: profile.env 写入 PDG_INTERNAL_CIDR")
else:
    bad("装机没有写入真源")
if 'grep -q "^PDG_INTERNAL_CIDR=$INTERNAL_CIDR$"' in inst:
    ok("装机: 写完复核真源确实落盘(不落盘即 die)")
else:
    bad("装机没有复核真源落盘")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""Tailscale 入口隔离判据的负控: 把修复逐项改坏, 守卫必须转红。

判断一支测试有没有牙齿的唯一办法, 是把被测的修复撤掉再看它红不红 —— 这个仓库里
反复出现过"测试全绿但其实什么都没守住"的情况, 所以每条判据都要在这里过一遍。

纪律(与 firewall-render-negative-controls.py 一致):
  · 改坏器必须**命中且只命中一次**。打空了却"看见红"是假阳性, 那说明红来自别处。
  · 语法错误造成的红不算数 —— 那证明的是"nft 不认识乱码", 不是"判据在守卫"。
  · 反向格: 无关改动(注释)必须**仍然全绿**, 否则判据认的是"任何改动"而不是语义。
  · 收尾必须证明正式树逐字节、mode、git 状态都没被这支测试弄脏。

在工作副本里改, 不碰正式树。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TEST = "tests/test-tailscale-ingress-isolation.py"
NFT = "deploy/firewall/nftables-mihomo.conf"
DET = "lib/detect-internal-range.sh"
CHK = "deploy/bot/checks.py"
TOUCHED = [NFT, DET, CHK]

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(65536), b""):
            h.update(c)
    return h.hexdigest()


BASE_SHA = {r: sha(os.path.join(ROOT, r)) for r in TOUCHED}
MODE = {r: os.stat(os.path.join(ROOT, r)).st_mode & 0o777 for r in TOUCHED}

if os.geteuid() != 0 and subprocess.run(
        "sudo -n true", shell=True, capture_output=True).returncode != 0:
    print("[SKIP] 需要 root 或免密 sudo —— 这支要真加载 nft 才有判据")
    print("\n有效 0, 失败 0")
    sys.exit(0)

WCROOT = tmpguard.mkdtemp(prefix="pdg-ts-nc-")
WC = os.path.join(WCROOT, "repo")
shutil.copytree(ROOT, WC, symlinks=True,
                ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"))


def run_suite():
    """在工作副本里跑隔离测试, 返回 (通过数, 失败行列表)。"""
    p = subprocess.run("python3 %s" % os.path.join(WC, TEST), shell=True,
                       capture_output=True, text=True, cwd=WC)
    out = (p.stdout or "") + (p.stderr or "")
    fails = [L for L in out.splitlines() if L.startswith("[FAIL]")]
    m = re.search(r"通过 (\d+), 失败 (\d+)", out)
    npass_ = int(m.group(1)) if m else -1
    return npass_, fails, out


print("── 基线: 修复到位时必须全绿, 且动态段真的跑了 ──")
b_pass, b_fails, b_out = run_suite()
if b_fails:
    bad("基线就红了(%d 条), 后面每格都无从判断" % len(b_fails))
    for L in b_fails[:4]:
        print("       " + L[:100])
    sys.exit(1)
if b_pass <= 0:
    bad("基线一条断言都没跑出来 —— '0 条失败'不等于绿")
    sys.exit(1)
if "真 netns 流量" not in b_out:
    bad("动态 netns 段被跳过了 —— 这支必须在能建 netns 的环境里跑")
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0, 且真流量段确实执行了" % b_pass)


def cell(n, name, rel, old, new, want, expect_red=True):
    """改坏一处 → 跑 → 判断是否按预期转红 → 恢复。"""
    path = os.path.join(WC, rel)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    hits = src.count(old)
    if hits != 1:
        bad("NC-TS-%d %s → 锚点命中 %d 次, 预期 1(改坏器没打在预期位置)" % (n, name, hits))
        return
    before = sha(path)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("NC-TS-%d %s → 摘要没变, mutation 没生效" % (n, name))
        return
    try:
        # 语法门: 改坏后本身就不合法的话, 红灯证明不了判据在守卫
        if rel == DET:
            p = subprocess.run("bash -n %s" % path, shell=True, capture_output=True)
            if p.returncode != 0:
                bad("NC-TS-%d %s → 改坏后 shell 语法不合法, 这格不算有效负控" % (n, name))
                return
        if rel == CHK:
            p = subprocess.run("python3 -m py_compile %s" % path, shell=True,
                               capture_output=True)
            if p.returncode != 0:
                bad("NC-TS-%d %s → 改坏后 python 语法不合法, 这格不算有效负控" % (n, name))
                return
        np_, fails, out = run_suite()
        if "Traceback" in out:
            bad("NC-TS-%d %s → 出现 Traceback, 不算转红" % (n, name))
            return
        if not expect_red:
            if fails:
                bad("NC-TS-%d %s → **不该红却红了**(%s) —— 判据该认语义不认任何改动"
                    % (n, name, fails[0][:70]))
            else:
                ok("NC-TS-%d %-28s → 仍全绿(通过 %d), 判据认的是语义" % (n, name, np_))
            return
        if not fails:
            bad("NC-TS-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name))
            return
        if want and not any(want in L for L in fails):
            bad("NC-TS-%d %s → 转红但没点名 %r: %s" % (n, name, want, fails[0][:80]))
            return
        ok("NC-TS-%d %-28s → 转红 %d 条: %s" % (n, name, len(fails), fails[0][7:88]))
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


TS_PRE = '        iifname "tailscale0" return\n        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 } redirect to :7893'
TS_IN = '        iifname "tailscale0" return\n        # 80/443/5228-5230 已在 prerouting 被改写为 7893'
ICMP_BLOCK = ('        ip protocol icmp accept\n'
              '        ip6 nexthdr icmpv6 accept\n')

# 0a) 把 tailnet return 挪回 ICMP **之前** —— 这正是上一轮的形态。ICMP 管理可达性必须转红,
#     而数据面隔离仍然成立(所以这一格证明的是"顺序错了", 不是"隔离没了")。
def cell_icmp_before():
    path = os.path.join(WC, NFT)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    old = ICMP_BLOCK + '        # Tailscale 入口隔离'
    if src.count(old) != 1:
        bad("NC-TS-0a 锚点命中 %d 次, 预期 1" % src.count(old))
        return
    # 先摘掉 ICMP 两行, 再把它们插到 return 之后 → 等价于 return 挪到 ICMP 之前
    mutated = src.replace(ICMP_BLOCK, "", 1).replace(
        '        iifname "tailscale0" return\n        # 80/443',
        '        iifname "tailscale0" return\n' + ICMP_BLOCK + '        # 80/443', 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(mutated)
    try:
        np_, fails, out = run_suite()
        if "Traceback" in out:
            bad("NC-TS-0a 出现 Traceback, 不算转红")
        elif any("ICMP" in L for L in fails):
            hit = [L for L in fails if "ICMP" in L]
            ok("NC-TS-0a return 挪回 ICMP 之前     → ICMP 可达性转红 %d 条: %s"
               % (len(hit), hit[0][7:80]))
        else:
            bad("NC-TS-0a return 挪回 ICMP 之前, ICMP 那几格**没红** —— 可达性判据没有牙齿")
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


cell_icmp_before()


# 0b) 把 return 挪到**全部数据面规则之后** → 隔离整个失效: DNS/受保护端口格必须转红。
def cell_after_dataplane():
    path = os.path.join(WC, NFT)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    ret = '        iifname "tailscale0" return\n'
    tail = '        ip saddr __INTERNAL_CIDR__ udp dport 443 reject'
    if src.count(ret) != 2 or src.count(tail) != 1:
        bad("NC-TS-0b 锚点命中 return=%d tail=%d, 预期 2/1" % (src.count(ret), src.count(tail)))
        return
    # 只动 input 那一条(第二处), prerouting 的保持不动
    head, sep, rest = src.partition('        # Tailscale 入口隔离')
    rest = rest.replace(ret, "", 1)
    rest = rest.replace(tail, ret + tail, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(head + sep + rest)
    try:
        np_, fails, out = run_suite()
        if "Traceback" in out:
            bad("NC-TS-0b 出现 Traceback, 不算转红")
        elif any(("DNS 接管链" in L or "受保护端口" in L) for L in fails):
            hit = [L for L in fails if "DNS 接管链" in L or "受保护端口" in L]
            ok("NC-TS-0b return 挪到数据面之后    → 隔离失效转红 %d 条: %s"
               % (len(hit), hit[0][7:80]))
        else:
            bad("NC-TS-0b return 挪到数据面之后, 隔离格**没红** —— 顺序判据没有牙齿")
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


cell_after_dataplane()

# 1) 只撤掉 prerouting 的排除。
#    注意这里**动态流量不会漏** —— input 的排除仍在, 会把改写后的包收口, 两道排除构成
#    纵深防御。所以这一格的判据只能是静态门。要证明真流量能进 REDIRECT, 见第 2b 格。
cell(1, "撤掉 prerouting 排除", NFT,
     TS_PRE,
     '        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 } redirect to :7893',
     "prerouting")

# 2) 只撤掉 input 的排除 → tailnet 进 DNS 接管链
cell(2, "撤掉 input 排除", NFT,
     TS_IN,
     '        # 80/443/5228-5230 已在 prerouting 被改写为 7893',
     "DNS 接管链")

# 2b) 两道排除**一起**撤掉 → 真 netns 流量确实进 REDIRECT 落到 7893 的监听上。
#     这一格才是"真流量证据", 前两格证的是静态门。
def cell_both():
    path = os.path.join(WC, NFT)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    n = src.count('        iifname "tailscale0" return\n')
    if n != 2:
        bad("NC-TS-2b 锚点命中 %d 次, 预期 2" % n)
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace('        iifname "tailscale0" return\n', "", 2))
    try:
        np_, fails, out = run_suite()
        if "Traceback" in out:
            bad("NC-TS-2b 出现 Traceback, 不算转红")
        elif any("REDIRECT" in L for L in fails):
            ok("NC-TS-2b 两道排除全撤            → 真流量进 REDIRECT: %s"
               % [L for L in fails if "REDIRECT" in L][0][7:88])
        else:
            bad("NC-TS-2b 全撤之后真流量**仍没进** REDIRECT —— 动态判据没有牙齿")
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


cell_both()

# 3) 把排除挪到来源匹配之后 → 顺序门必须转红(且真流量也该漏)
cell(3, "排除挪到来源匹配之后", NFT,
     TS_PRE,
     '        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 } redirect to :7893\n'
     '        iifname "tailscale0" return',
     "之后")

# 4) 过度排除: 把判据改成"除物理口外全排除" → 合法运营商 CGNAT 那格必须转红。
#    这一格防的是"用一个大而泛的虚拟网卡排除框架顺手把真实来源也挡了"。
cell(4, "过度排除(除 lo 外全挡)", NFT,
     '        iifname "tailscale0" return\n        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 }',
     '        iifname != "lo" return\n        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 }',
     "破坏了既有运营商支持")

# 5) 用 iif 代替 iifname → 接口不存在时整份规则加载失败
cell(5, "iif 代替 iifname", NFT,
     '        iifname "tailscale0" return\n        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 }',
     '        iif "tailscale0" return\n        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 }',
     "")

# 6) 反向格: 无关注释必须仍全绿
cell(6, "追加无关注释", NFT,
     "table inet pdg {\n",
     "table inet pdg {\n    # 负控用的无关注释, 不改变任何行为\n",
     "", expect_red=False)

# ── 检测器一侧(不依赖 netns, 单独判)────────────────────────────────────────
print("\n── 检测器: 撤掉 tailscale0 排除必须可检出 ──")
det = os.path.join(WC, DET)
with open(det, encoding="utf-8") as f:
    dsrc = f.read()
# 整行删掉(含行首管道与行尾续行符), 而不是把中段挖空 —— 挖空会留下 `| | grep`,
# 那是语法错误, 红灯来自 bash 而不是判据, 不算有效负控。
anchor = '      | awk -v ts="$TS_IF" \'$2 != ts\' \\\n'
if dsrc.count(anchor) != 1:
    bad("NC-TS-7 检测器锚点命中 %d 次, 预期 1" % dsrc.count(anchor))
else:
    with open(det, "w", encoding="utf-8") as f:
        f.write(dsrc.replace(anchor, "", 1))
    p = subprocess.run("bash -n %s" % det, shell=True, capture_output=True)
    if p.returncode != 0:
        bad("NC-TS-7 改坏后 shell 语法不合法, 不算有效负控")
    else:
        still = 'awk -v ts="$TS_IF"' in open(det, encoding="utf-8").read()
        if still:
            bad("NC-TS-7 排除仍在, mutation 没生效")
        else:
            ok("NC-TS-7 撤掉检测器排除            → 抓包结果不再按接口过滤(语法仍合法, 是真的改坏了)")
    with open(det, "w", encoding="utf-8") as f:
        f.write(dsrc)

# ── 收尾 ──────────────────────────────────────────────────────────────────────
print("\n── 收尾: 正式树必须毫发无损 ──")
for rel in TOUCHED:
    p = os.path.join(ROOT, rel)
    (ok if sha(p) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
    (ok if os.stat(p).st_mode & 0o777 == MODE[rel] else bad)(
        "%s mode 恢复为 %o" % (rel, MODE[rel]))
# 只看**已跟踪文件有没有被改动**。未跟踪文件不算脏 —— 这支自己第一次跑时就还没被提交,
# 把 `??` 也算进去会让它必然自我判红。
g = subprocess.run("git -C %s status --porcelain" % ROOT, shell=True,
                   capture_output=True, text=True)
dirty = [L for L in g.stdout.splitlines() if L and not L.startswith("??")]
(ok if not dirty else bad)(
    "已跟踪文件无改动(这支没弄脏仓库)%s" % ("" if not dirty else ": " + "; ".join(dirty[:3])))

shutil.rmtree(WCROOT, ignore_errors=True)
print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

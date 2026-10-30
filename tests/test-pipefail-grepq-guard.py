#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`set -o pipefail` + `| grep -q` 的条件反转: 守住真实风险, 而不是守住形态。

机理: `grep -q` 一命中就退出并关掉管道。上游如果**还在写**, 就挨 SIGPIPE(退出码 141),
pipefail 把整条管道判成失败 —— 于是 `if 上游 | grep -q P; then` 在**命中时走 else 分支**,
条件整个反过来, 而且没有任何报错。

但这不是"只要用了 `| grep -q` 就有问题"。决定因素是 grep -q **命中之后上游还写不写**:
一次写完的上游没机会挨 SIGPIPE, 分几次写的上游输出再小也会反转。总量只是其中一种成因
(写满管道缓冲之后还要接着写)。本仓实测:

    cat 文件 418 / 20508 字节          → rc=0    (一次写完)
    cat 文件 205008 字节               → rc=141  (写满 64KiB 缓冲之后还要写)
    install.sh 整份透传(72642 字节)   → rc=141
    nft list table inet pdg(783 字节)  → 300 次里 296 次 141(nft 1.0.6: 列表分好几次写)
    systemctl list-unit-files(约 15KB) → 200 次里 77 次 141(.200 真机)
    ss -lun(16KB)、内建 printf(16KB)、git config --get-all(4.7KB)、nft list tables → 都是 300 次 0 次

注意"读了多大"与"写了多少"是两回事: `sed -n '500p' pdg.sh` 读 416KB 却只输出一行,
写完就不再写, 永远不会反转。所以按形态一刀切会得出"仓库里有几十处债务"的结论, 而逐处查上游,
生产脚本里真会反转的是两处: uninstall.sh 探测 resolved(systemctl list-unit-files, 已改)与
pdg.sh 的 _rescue_nft_has_kernel(nft list table, 没有调用方, 已改)。

这支守卫分两块:
  · 第 3 节: 测试脚本里"整体透传大文件 → grep -q"(本仓第一次触发就是这一种: 新写的测试把
    install.sh 整份透传给 grep -q, 两条断言在生产代码没改的情况下报绿);
  · 第 4 节: 生产脚本里每一处 `| grep -q` 都要登记上游是谁、凭什么安全; 已知分次写的上游一律
    不许接 grep -q。这是卸载脚本漏启用 resolved 之后补的 —— 那一处只有十几 KB, 第 3 节管不到。
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PIPE_BUF = 64 * 1024

PASS = [0]
FAIL = [0]
def ok(m): print("[OK]   %s" % m); PASS[0] += 1
def bad(m): print("[FAIL] %s" % m); FAIL[0] += 1


print("══ 1. 判据本身是真的(现场实测, 不背书本)══")
def probe(nbytes):
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("MATCHME\n" + ("x" * 40 + "\n") * (nbytes // 41))
        p = f.name
    try:
        r = subprocess.run(["bash", "-c", "set -o pipefail; cat %s | grep -q MATCHME" % p],
                           capture_output=True)
        return r.returncode, os.path.getsize(p)
    finally:
        os.unlink(p)
rc_small, sz_small = probe(8 * 1024)
rc_big, sz_big = probe(512 * 1024)
(ok if rc_small == 0 else bad)("小于缓冲(%d 字节)时不反转(rc=%d)" % (sz_small, rc_small))
(ok if rc_big != 0 else bad)("远大于缓冲(%d 字节)时确实反转(rc=%d) —— 判据成立" % (sz_big, rc_big))
# 总量不是唯一判据: 十几个字节, 只要命中之后上游还要再写一次, 照样反转
r = subprocess.run(["bash", "-c", "set -o pipefail; { echo MATCHME; sleep 0.5; echo tail; } | grep -q MATCHME"],
                   capture_output=True)
(ok if r.returncode != 0 else bad)("只有十几个字节、但命中之后还要再写时也反转(rc=%d) —— 看的是还写不写" % r.returncode)

print()
print("══ 2. 哪些文件大到能撑爆缓冲(动态取, 文件长大了自动纳入)══")
big = {}
out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout.split()
for rel in out:
    p = os.path.join(ROOT, rel)
    try:
        sz = os.path.getsize(p)
    except OSError:
        continue
    if sz > PIPE_BUF:
        big[os.path.basename(rel)] = sz
print("   共 %d 个(仅列文本类前 6 个): %s" % (
    len(big), ", ".join("%s(%d)" % (k, v) for k, v in sorted(big.items())[:6])))
(ok if big else bad)("取到了大文件清单")

print()
print("══ 3. 扫描: pipefail 脚本里有没有「整体透传大文件 → grep -q」══")
# 上游被这些形态限制过输出的, 都不算危险: sed -n / 地址范围 / head / grep -m / tail
LIMITED = re.compile(r"sed\s+-n|/\s*,\s*/|\bhead\b|\btail\b|grep[^|]*\s-m\s*\d")
PIPEQ = re.compile(r"\|\s*grep\s+-q")
offenders = []
scanned = 0
for fn in sorted(os.listdir(HERE)):
    if not fn.endswith(".sh"):
        continue
    path = os.path.join(HERE, fn)
    txt = io.open(path, encoding="utf-8", errors="replace").read()
    if not re.search(r"set\s+-[a-z]*o?\s*pipefail|set\s+-o\s+pipefail", txt):
        continue
    for i, line in enumerate(txt.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split("#")[0]
        if not PIPEQ.search(code):
            continue
        scanned += 1
        up = code.split("|")[0]
        if LIMITED.search(up):
            continue
        # 只有**文本处理命令在读这个文件**才算透传。文件名出现在命令行里不等于被透传 ——
        # `python3 .../pdgtx.py pending` 里 pdgtx.py 是被执行的脚本, 它的输出是 pending
        # 列表(很小), 不是那 110KB 源码。第一版没区分这一点, 当场报了一个假阳性,
        # 差一点就去"修"一处根本没问题的代码。
        for name, sz in big.items():
            if not re.search(r"(?:^|[;&|(]|\s)(cat|sed|awk|grep|tac|nl|expand|tr|cut)\b[^|]*"
                             + re.escape(name), up):
                continue
            offenders.append("%s:%d  %s(%d 字节) 整体透传" % (fn, i, name, sz))
            break
print("   扫了 %d 处 `| grep -q`(仅限开了 pipefail 的脚本)" % scanned)
if offenders:
    bad("发现整体透传大文件到 grep -q —— 条件会在命中时反转:")
    for o in offenders:
        print("       " + o)
    print("       改法: 先收进变量再判(out=$(上游); grep -q P <<<\"$out\"),")
    print("             或用计数(  [[ \"$(上游 | grep -c P || true)\" != 0 ]]  ),")
    print("             或给上游限量(sed -n / head)。")
else:
    ok("没有整体透传大文件到 grep -q 的调用点(%d 处全部安全)" % scanned)

print()
print("══ 4. 生产脚本: 每一处 `| grep -q` 都登记过上游 ══")
# 生产脚本的上游五花八门, "命中之后还写不写"静态判不了, 所以逐处登记: 上游是谁、凭什么安全。
# 新增一处没登记 → 红; 登记了却在代码里找不到 → 也红(登记表不许过期)。
# 已知分次写的上游(KNOWN_MULTIWRITE)登记了也不放过: 改法是先收进变量再判。
# tools/legacy-cli-v1.11.15/ 是给 v1.11.15 用户的冻结补丁件, 按它自己的规矩管, 不在这里改。
PROD_EXCLUDE = ("tests/", "tools/legacy-cli-v1.11.15/")
PIPEQ_ANY = re.compile(r"(?<!\|)\|(?!\|)\s*grep\s+(?:-[A-Za-z0-9]+\s+)*-[A-Za-z]*q[A-Za-z]*\b")
KNOWN_MULTIWRITE = [
    (re.compile(r"(?i)nft\S*\s+list\s+(?:table|ruleset|chain|set|map)\b"),
     "nft list table/ruleset 分好几次写(783 字节 300 次里 296 次反转)"),
    (re.compile(r"\bsystemctl\b.*\blist-(?:unit-files|units)\b"),
     "systemctl list-unit-files 分次写(约 15KB, .200 上 200 次里 77 次反转)"),
]
REVIEWED = {
    ("deploy/bot/pdg-set-token.sh", 'printf %s "$T"'): "一个 token; 内建 printf 一次写完",
    ("deploy/bot/pdg.sh", 'printf \'%s\' "$norm"'): "一行 nft 配置; 内建 printf 一次写完(16KB 也 0/300)",
    ("deploy/bot/pdg.sh", 'head -1 "$f"'): "只出一行",
    ("deploy/bot/pdg.sh", 'printf \'%s\' "$out"'): "迁移结果是一行 JSON; 内建 printf 一次写完",
    ("deploy/bot/pdg.sh", "ss -lun 2>/dev/null"): "ss 攒齐再写(252 行 16KB 也 0/300)",
    ("deploy/bot/pdg.sh", "ss -ltn 2>/dev/null"): "同 ss -lun",
    ("deploy/bot/pdg.sh", "nft list tables 2>/dev/null"): "只列表名, 一次写完(8 张表 0/300)",
    ("deploy/bot/pdg.sh", "awk '{print $2}'"): "几行候选地址; awk 攒齐再写(100 行 0/300)",
    ("deploy/bot/pdg.sh", "/usr/local/bin/caddy version 2>/dev/null"): "只出一行",
    ("install.sh", "git config --system --get-all safe.directory 2>/dev/null"): "git 攒齐再写(51 条 4.7KB 0/300)",
    ("lib/detect-internal-range.sh", "timeout 3 tcpdump -ni any -c 1 2>/dev/null"): "-c 1: 只抓一个包、只出一行",
    ("uninstall.sh", '"$_UN_NFT" list tables 2>/dev/null'): "只列表名, 一次写完(8 张表 0/300)",
}


def upstream(code, m):
    """紧挨着 grep -q 的那一段上游(多段管道里, 往 grep -q 写的只有它)。"""
    seg = re.split(r"(?<!\|)\|(?!\|)", code[:m.start()])[-1]
    seg = re.split(r"\$\(|&&|\|\||;|\bdo\b|\bthen\b|\bif\b|(?<![\w\"'])!(?=\s)", seg)[-1]
    return " ".join(seg.split())


prod = [f for f in subprocess.run(["git", "ls-files", "*.sh"], cwd=ROOT, capture_output=True,
                                  text=True).stdout.split() if not f.startswith(PROD_EXCLUDE)]
seen = {}
nfiles = 0
for rel in prod:
    txt = io.open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace").read()
    if not re.search(r"set\s+-[a-z]*o?\s*pipefail|set\s+-o\s+pipefail", txt):
        continue
    nfiles += 1
    for i, line in enumerate(txt.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        code = re.split(r"(?:^|\s)#", line)[0]
        for m in PIPEQ_ANY.finditer(code):
            seen.setdefault((rel, upstream(code, m)), []).append(i)
print("   %d 个开了 pipefail 的生产脚本, %d 处 `| grep -q`, %d 种上游" % (
    nfiles, sum(len(v) for v in seen.values()), len(seen)))
(ok if nfiles and seen else bad)("扫到了生产脚本与调用点(扫不到说明扫描本身坏了)")
hard = [(k, v, why) for k, v in seen.items() for rx, why in KNOWN_MULTIWRITE if rx.search(k[1])]
unreg = [(k, v) for k, v in seen.items() if k not in REVIEWED]
stale = [k for k in REVIEWED if k not in seen]
if hard:
    bad("已知分次写的上游接了 grep -q —— 命中时条件会反转:")
    for (rel, up), lines, why in hard:
        print("       %s:%s  %s  (%s)" % (rel, ",".join(map(str, lines)), up, why))
    print("       改法: 先收进变量再判: out=\"$(上游)\"; grep -q P <<<\"$out\"")
else:
    ok("没有已知分次写的上游(nft list table/ruleset、systemctl list-unit-files)接 grep -q")
if unreg:
    bad("有没登记过的 `| grep -q`(先确认上游是否一次写完, 再登记到 REVIEWED 或改成先收进变量):")
    for (rel, up), lines in unreg:
        print("       %s:%s  上游: %s" % (rel, ",".join(map(str, lines)), up))
else:
    ok("每一处 `| grep -q` 的上游都登记过(%d 种)" % len(seen))
if stale:
    bad("登记表里有代码中已经找不到的上游(过期, 删掉或更正): %s" % stale)
else:
    ok("登记表没有过期条目")

print("-" * 62)
print("test-pipefail-grepq-guard.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`set -o pipefail` + `| grep -q` 的条件反转: 守住真实风险, 而不是守住形态。

机理: `grep -q` 一命中就退出并关掉管道。上游如果**还在写**, 就挨 SIGPIPE(退出码 141),
pipefail 把整条管道判成失败 —— 于是 `if 上游 | grep -q P; then` 在**命中时走 else 分支**,
条件整个反过来, 而且没有任何报错。

但这不是"只要用了 `| grep -q` 就有问题"。决定因素是**上游的输出量**能不能撑爆管道缓冲
(Linux 上 64KiB): 输出装得下时上游早就写完退出了, 根本没机会挨 SIGPIPE。本仓实测:

    文件 418 / 20508 字节   → rc=0    (正常)
    文件 205008 字节        → rc=141  (反转)
    install.sh 整份透传(72642 字节) → rc=141

注意"读了多大"与"写了多少"是两回事: `sed -n '500p' pdg.sh` 读 416KB 却只输出一行,
写完就不再写, 永远不会反转。按形态数会得出"仓库里有 60 处债务"的结论 —— 而按真实判据
(整体透传 >64KiB 文件)数, 是 0 处。这支守卫钉的是后者。

历史: 这个坑在本仓唯一一次真正触发, 是一段新写的测试代码把 install.sh 整份透传给
`grep -q`, 结果两条断言在生产代码没改的情况下报绿。
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

print("-" * 62)
print("test-pipefail-grepq-guard.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""E2E 夹具渲染闭包判据的负控: 把修复逐项改坏, 守卫必须转红。

纪律与 firewall-render-negative-controls.py 一致:
  · 改坏器必须**命中且只命中一次**; 打空了却"看见红"证明红来自别处。
  · 语法损坏造成的红不算 —— 那证明的是"bash 不认识乱码", 不是判据在守卫。
  · 反向格: 无关改动必须仍绿, 否则判据认的是"任何改动"而非语义。
  · 收尾必须证明正式树逐字节、mode、git 状态都没被弄脏。

在工作副本里改, 不碰正式树。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tmpguard

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LIB = "tests/e2e-lib.sh"
TPL = "deploy/firewall/nftables-mihomo.conf"
TEST = "tests/test-e2e-seed-render.py"
TOUCHED = [LIB, TPL]

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

WCROOT = tmpguard.mkdtemp(prefix="pdg-seednc-")
WC = os.path.join(WCROOT, "repo")
shutil.copytree(ROOT, WC, symlinks=True,
                ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"))


def run_guard():
    p = subprocess.run("python3 %s" % os.path.join(WC, TEST), shell=True,
                       capture_output=True, text=True, cwd=WC)
    out = (p.stdout or "") + (p.stderr or "")
    fails = [L for L in out.splitlines() if L.startswith("[FAIL]")]
    m = re.search(r"通过 (\d+), 失败 (\d+)", out)
    return (int(m.group(1)) if m else -1), fails, out


print("── 基线: 修复到位时守卫必须全绿 ──")
b_pass, b_fails, b_out = run_guard()
if b_fails:
    bad("基线就红了(%d 条), 后面每格都无从判断" % len(b_fails))
    for L in b_fails[:3]:
        print("       " + L[:100])
    sys.exit(1)
if b_pass <= 0:
    bad("基线一条断言都没跑出来 —— '0 条失败'不等于绿")
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0" % b_pass)


def cell(n, name, rel, old, new, want, expect_red=True):
    path = os.path.join(WC, rel)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    hits = src.count(old)
    if hits != 1:
        bad("NC-SR-%d %s → 锚点命中 %d 次, 预期 1(改坏器没打在预期位置)" % (n, name, hits))
        return
    before = sha(path)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("NC-SR-%d %s → 摘要没变, mutation 没生效" % (n, name))
        return
    try:
        if rel == LIB:
            p = subprocess.run("bash -n %s" % path, shell=True, capture_output=True)
            if p.returncode != 0:
                bad("NC-SR-%d %s → 改坏后 shell 语法不合法, 这格不算有效负控" % (n, name))
                return
        np_, fails, out = run_guard()
        if "Traceback" in out:
            bad("NC-SR-%d %s → 出现 Traceback, 不算转红" % (n, name))
            return
        if not expect_red:
            if fails:
                bad("NC-SR-%d %s → **不该红却红了**(%s)" % (n, name, fails[0][:70]))
            else:
                ok("NC-SR-%d %-30s → 仍全绿(通过 %d), 判据认的是语义" % (n, name, np_))
            return
        if not fails:
            bad("NC-SR-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name))
            return
        if want and not any(want in L for L in fails):
            bad("NC-SR-%d %s → 转红但没点名 %r: %s" % (n, name, want, fails[0][:80]))
            return
        ok("NC-SR-%d %-30s → 转红 %d 条: %s" % (n, name, len(fails), fails[0][7:86]))
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


SUB = '-e "s|__RESCUE_PORT__|$_rp|g" '
GUARD = '''  local _left
  _left="$(grep -oE '__[A-Z][A-Z0-9_]*__' /etc/nftables.conf | sort -u | tr '\\n' ' ')"
  if [[ -n "${_left// /}" ]]; then
    echo "e2e_seed_nft: 模板未完整渲染, 残留占位符: $_left" >&2; return 1
  fi'''

# 1) 摘掉 __RESCUE_PORT__ 替换 → 闭包判据必须转红
cell(1, "摘掉 RESCUE_PORT 替换", LIB, SUB, "", "__RESCUE_PORT__")

# 2) 连守卫一起摘掉 → 端口来源判据仍须转红(证明不是只靠守卫兜着)
def cell2():
    path = os.path.join(WC, LIB)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if src.count(SUB) != 1 or src.count(GUARD) != 1:
        bad("NC-SR-2 锚点命中 sub=%d guard=%d, 预期 1/1" % (src.count(SUB), src.count(GUARD)))
        return
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(SUB, "", 1).replace(GUARD, "", 1))
    try:
        if subprocess.run("bash -n %s" % path, shell=True, capture_output=True).returncode != 0:
            bad("NC-SR-2 改坏后语法不合法, 不算有效负控")
            return
        np_, fails, out = run_guard()
        if "Traceback" in out:
            bad("NC-SR-2 出现 Traceback")
        elif any("漏渲染" in L or "来源不明" in L or "没有替换" in L for L in fails):
            ok("NC-SR-2 摘掉替换+守卫              → 仍转红 %d 条: %s" % (len(fails), fails[0][7:82]))
        else:
            bad("NC-SR-2 摘掉替换和守卫后**没红** —— 判据全靠守卫兜着, 闭包本身没牙")
    finally:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


cell2()

# 3) 模板新增一个合成占位符 → 闭包判据必须发现夹具没跟进
cell(3, "模板新增合成占位符", TPL,
     "        ip saddr __INTERNAL_CIDR__ udp dport { 53 } accept",
     "        ip saddr __INTERNAL_CIDR__ udp dport { 53 } accept\n"
     "        ip saddr __INTERNAL_CIDR__ tcp dport __SYNTHETIC_PORT__ accept",
     "漏渲染")

# 4) 救援端口渲染成写死的错误值 → 来源判据必须转红(不能只看 token 消失)
cell(4, "救援端口写成字面量", LIB, '-e "s|__RESCUE_PORT__|$_rp|g" ',
     '-e "s|__RESCUE_PORT__|9999|g" ', "字面量")

# 5) 摘掉守卫本身 → 守卫存在性判据必须转红
cell(5, "摘掉残留占位符守卫", LIB, GUARD, "", "守卫")

# 6) 反向格: 无关注释必须仍绿
cell(6, "追加无关注释", LIB, "e2e_seed_nft(){\n",
     "e2e_seed_nft(){\n  # 负控用的无关注释, 不改变任何行为\n", "", expect_red=False)

# 7) 反向格: 模板里加注释也必须仍绿
cell(7, "模板加无关注释", TPL, "table inet pdg {\n",
     "table inet pdg {\n    # 负控用的无关注释\n", "", expect_red=False)

print("\n── 收尾: 正式树必须毫发无损 ──")
for rel in TOUCHED:
    (ok if sha(os.path.join(ROOT, rel)) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
    (ok if os.stat(os.path.join(ROOT, rel)).st_mode & 0o777 == MODE[rel] else bad)(
        "%s mode 恢复为 %o" % (rel, MODE[rel]))
g = subprocess.run("git -C %s status --porcelain -- %s" % (ROOT, " ".join(TOUCHED)),
                   shell=True, capture_output=True, text=True)
(ok if not g.stdout.strip() else bad)("已跟踪文件无改动: %s" % (g.stdout.strip() or "(干净)"))
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

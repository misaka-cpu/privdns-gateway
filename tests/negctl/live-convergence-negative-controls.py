#!/usr/bin/env python3
"""磁盘/内核收敛判据的负控: 把三态逐项改坏, 守卫必须转红。

纪律与其它 negctl 一致: 锚点命中且只命中一次; 语法损坏不算有效红; 反向格必须仍绿;
收尾证明正式树逐字节、mode、git 状态干净。在工作副本里改, 不碰正式树。
"""
import hashlib, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tmpguard

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PDG = "deploy/bot/pdg.sh"
TEST = "tests/test-firewall-live-drift.py"
TOUCHED = [PDG]
npass = nfail = 0


def ok(m):
    global npass; npass += 1; print("[OK]   %s" % m)


def bad(m):
    global nfail; nfail += 1; print("[FAIL] %s" % m)


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(65536), b""): h.update(c)
    return h.hexdigest()


if os.geteuid() != 0 and subprocess.run("sudo -n true", shell=True,
                                        capture_output=True).returncode != 0:
    print("[SKIP] 需要 root 或免密 sudo —— 这支要真建 netns 并加载 nft")
    print("\n有效 0, 失败 0"); sys.exit(0)

BASE_SHA = {r: sha(os.path.join(ROOT, r)) for r in TOUCHED}
MODE = {r: os.stat(os.path.join(ROOT, r)).st_mode & 0o777 for r in TOUCHED}
WCROOT = tmpguard.mkdtemp(prefix="pdg-lcnc-")
WC = os.path.join(WCROOT, "repo")
shutil.copytree(ROOT, WC, symlinks=True,
                ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"))


def run_suite():
    p = subprocess.run("python3 %s" % os.path.join(WC, TEST), shell=True,
                       capture_output=True, text=True, cwd=WC)
    out = (p.stdout or "") + (p.stderr or "")
    fails = [L for L in out.splitlines() if L.startswith("[FAIL]")]
    m = re.search(r"通过 (\d+), 失败 (\d+)", out)
    return (int(m.group(1)) if m else -1), fails, out


print("── 基线: 修复到位时必须全绿 ──")
b_pass, b_fails, b_out = run_suite()
if b_fails or b_pass <= 0:
    bad("基线不绿(通过 %d, 失败 %d), 后面每格都无从判断" % (b_pass, len(b_fails)))
    for L in b_fails[:3]: print("       " + L[:100])
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0" % b_pass)


def cell(n, name, old, new, want, expect_red=True):
    path = os.path.join(WC, PDG)
    with open(path, encoding="utf-8") as f: src = f.read()
    if src.count(old) != 1:
        bad("NC-LC-%d %s → 锚点命中 %d 次, 预期 1" % (n, name, src.count(old))); return
    with open(path, "w", encoding="utf-8") as f: f.write(src.replace(old, new, 1))
    try:
        if subprocess.run("bash -n %s" % path, shell=True, capture_output=True).returncode != 0:
            bad("NC-LC-%d %s → 改坏后语法不合法, 不算有效负控" % (n, name)); return
        np_, fails, out = run_suite()
        if "Traceback" in out:
            bad("NC-LC-%d %s → Traceback, 不算转红" % (n, name)); return
        if not expect_red:
            (ok if not fails else bad)(
                "NC-LC-%d %-26s → %s" % (n, name, "仍全绿(通过 %d)" % np_ if not fails
                                         else "**不该红却红了**: " + fails[0][:60])); return
        if not fails:
            bad("NC-LC-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name)); return
        if want and not any(want in L for L in fails):
            bad("NC-LC-%d %s → 转红但没点名 %r: %s" % (n, name, want, fails[0][:70])); return
        ok("NC-LC-%d %-26s → 转红 %d 条: %s" % (n, name, len(fails), fails[0][7:80]))
    finally:
        with open(path, "w", encoding="utf-8") as f: f.write(src)


NOOP = '''    if _fw_live_has_template_invariants; then
      return 0                     # B 态: 磁盘新、内核新 —— 真 no-op, 不写盘不加载
    fi'''
RECHECK = '''    if ! _fw_live_has_template_invariants; then
      c_y "重新加载后内核仍未收敛到模板承诺的规则 —— 不当作成功, 请人工检查。"
      return 1
    fi'''
PRECHECK = '''    if ! nft -c -f "$f" >/dev/null 2>&1; then
      c_y "内核规则落后于磁盘, 但磁盘配置 nft -c 未过 → 不加载, 请人工检查。"
      return 1
    fi'''

# 1) 退回"磁盘相同就直接 no-op" → C 态红灯必须转红
cell(1, "退回磁盘相同即 no-op", NOOP + "\n", "    return 0\n", "内核")
# 2) 摘掉 reload 后复核 → 不收敛时不再被抓
cell(2, "摘掉 reload 后复核", RECHECK + "\n", "", "")
# 3) B 态改成无条件 reload → 幂等/不写盘判据必须转红
cell(3, "B 态改成无条件 reload", NOOP, "    :", "")
# 4) 不设此格: reload 前那道 nft -c 守的是**不可达状态**。
#    C 态成立的前提是"磁盘 == 候选", 而候选是模板渲染的产物, 必然通过 nft -c。
#    把磁盘改成非法就不再等于候选, 函数走 A 态去了 —— 那验的是别的分支。
#    留着那道检查是纵深防御, 但这里不假装能触发它: 造不出的红不算负控。
# 5) reload 失败仍返回 0
cell(5, "reload 失败仍返回 0",
     '      c_y "防火墙重新加载失败 —— 内核仍是加载前那份, 磁盘未动。"\n      return 1',
     '      c_y "防火墙重新加载失败 —— 内核仍是加载前那份, 磁盘未动。"\n      return 0', "")
# 6) 反向格: 无关注释
cell(6, "追加无关注释", "migrate_firewall_template_sync(){\n",
     "migrate_firewall_template_sync(){\n  # 负控用的无关注释\n", "", expect_red=False)

print("\n── 收尾 ──")
for rel in TOUCHED:
    (ok if sha(os.path.join(ROOT, rel)) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
    (ok if os.stat(os.path.join(ROOT, rel)).st_mode & 0o777 == MODE[rel] else bad)(
        "%s mode 恢复为 %o" % (rel, MODE[rel]))
g = subprocess.run("git -C %s status --porcelain -- %s" % (ROOT, PDG),
                   shell=True, capture_output=True, text=True)
(ok if not g.stdout.strip() else bad)("git 干净: %s" % (g.stdout.strip() or "(是)"))
shutil.rmtree(WCROOT, ignore_errors=True)
print("\n" + "─" * 62); print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

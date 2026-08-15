#!/usr/bin/env python3
"""标记契约判据的负控: 把修复逐个拆掉, 证明 test-dot-route-markers.py 会转红并点名;
再加一格无关改动, 证明它不是"见改就红"。

修复刚落地, 测试当场 27/0。但"变绿"不说明判据有牙齿 —— 这支回答的是"如果哪天有人
把模板标记的后缀加回去、或让 state 与 strip 又用上两套匹配, 我们会不会当场知道"。

改坏落在工作副本, 正式树一个字节不动。每格四步缺一不可:
锚点唯一命中 → 摘要确实变化 → 语法门通过 → 新增可点名失败(第九格反过来: 必须仍全绿)。
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST = "tests/test-dot-route-markers.py"
ROUTE = "deploy/bot/dotwroute.py"
TPLR = "deploy/mosdns/config.yaml"
TOUCHED = [ROUTE, TPLR]

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
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


WCROOT = tmpguard.mkdtemp(prefix="pdg-mknc-")
WC = os.path.join(WCROOT, "wc")
for rel in TOUCHED + [TEST]:
    os.makedirs(os.path.join(WC, os.path.dirname(rel)), exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), os.path.join(WC, rel))
PRISTINE = {rel: open(os.path.join(WC, rel), "rb").read() for rel in TOUCHED}
MODE = {rel: os.stat(os.path.join(WC, rel)).st_mode & 0o777 for rel in TOUCHED}
BASE_SHA = {rel: sha(os.path.join(REPO, rel)) for rel in TOUCHED}


def run_test():
    p = subprocess.run([sys.executable, os.path.join(WC, TEST)],
                       cwd=WC, capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    fails = sorted(l for l in out.splitlines() if l.startswith("[FAIL]"))
    n_ok = sum(1 for l in out.splitlines() if l.startswith("[OK]"))
    return fails, n_ok, out


def restore():
    for rel in TOUCHED:
        path = os.path.join(WC, rel)
        with open(path, "wb") as f:
            f.write(PRISTINE[rel])
        os.chmod(path, MODE[rel])


print("── 基线: 修复到位时必须全绿 ──")
BASE_FAILS, BASE_OK, base_out = run_test()
if BASE_FAILS or "Traceback" in base_out:
    bad("基线不干净(失败 %d 条), 后面每格都无从判断" % len(BASE_FAILS))
    print("\n".join("      " + x for x in BASE_FAILS[:3]))
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0" % BASE_OK)


def cell(n, name, rel, old, new, want, expect_red=True, old2=None, new2=None):
    """old2/new2: 有些守卫互为兜底(拆一个另一个仍接住), 只有整对拆掉才谈得上
    "这一对有没有牙齿"。那种格子用两处锚点, 两处都必须唯一命中。"""
    path = os.path.join(WC, rel)
    src = open(path, encoding="utf-8").read()
    hits = src.count(old) if old2 is None else min(src.count(old), src.count(old2))
    if hits != 1 or (old2 is not None and (src.count(old) != 1 or src.count(old2) != 1)):
        bad("NC-MK-%d %s → 锚点命中 %d 次, 预期 1" % (n, name, hits))
        restore()
        return
    before = sha(path)
    new_src = src.replace(old, new, 1)
    if old2 is not None:
        new_src = new_src.replace(old2, new2, 1)
    open(path, "w", encoding="utf-8").write(new_src)
    if sha(path) == before:
        bad("NC-MK-%d %s → 摘要没变, mutation 没生效" % (n, name))
        restore()
        return
    if rel.endswith(".py"):
        g = subprocess.run([sys.executable, "-m", "py_compile", path], capture_output=True)
        if g.returncode != 0:
            bad("NC-MK-%d %s → 改坏后语法不合法, 这格不算有效负控" % (n, name))
            restore()
            return
    fails, n_ok, out = run_test()
    added = [x for x in fails if x not in BASE_FAILS]
    if "Traceback" in out:
        bad("NC-MK-%d %s → 出现 Traceback, 不算转红" % (n, name))
    elif not expect_red:
        if fails:
            bad("NC-MK-%d %s → **不该红却红了**: %s" % (n, name, fails[0][:70]))
        else:
            ok("NC-MK-%d %-30s → 仍全绿(通过 %d), 判据认语义不认任何改动" % (n, name, n_ok))
    elif not added:
        bad("NC-MK-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name))
    elif not any(want in x for x in added):
        bad("NC-MK-%d %s → 转红但没点名 %r: %s" % (n, name, want, added[0][:80]))
    else:
        ok("NC-MK-%d %-30s → 新增 %d 条: %s" % (n, name, len(added), added[0][7:88]))
    restore()
    if sha(path) != sha(os.path.join(REPO, rel)):
        bad("NC-MK-%d %s → 恢复后摘要与正式树不一致" % (n, name))


BP = '  # >>> pdg-dotwitness managed block (plugins)'

print("\n── 九格 ──")
# 1) 模板 BEGIN 标记重新加后缀 —— 这次事故的原始形态
cell(1, "模板 BEGIN 重新加后缀", TPLR,
     BP + "\n", BP + " —— 不要手工编辑\n", "canonical")

# 2) 冗余对照 C: 近似守卫 + 收口**一起**拆掉, 仍必须全绿。
#    原因是还有第三层: 带后缀的 BEGIN 不等于 canonical, 于是 BEGIN 少一个而 END 还在,
#    成对计数直接不相等 → malformed。近似标记实际被三层独立守卫防住(成对计数 / 近似
#    守卫 / 收口), 拆掉其中两层都还接得住。真正的牙齿在第 6 格 —— 那里把近似标记映射
#    成 absent, 绕过全部三层, 当场 6 条新增失败。
cell(2, "冗余对照C: 近似守卫+收口一起拆", ROUTE,
     "    if near:\n        # 近似标记绝不能当成 absent —— 那会让 render 以为没装过而追加第二份块。\n        return \"malformed\"\n",
     "    if False:\n        return \"malformed\"\n", "", expect_red=False,
     old2="    if _has_managed(strip(text)):\n        return \"malformed\"\n",
     new2="    if False:\n        return \"malformed\"\n")

# 3) strip 换成与 state 不同的匹配方式(更严: canonical 也删不掉)
cell(3, "strip 与 state 语义分叉", ROUTE,
     "        if line == BEGIN_P or line == BEGIN_S:\n",
     "        if line == BEGIN_P + \" \" or line == BEGIN_S:\n", "期望 full")

# 4) partial 被误判成 full
cell(4, "partial 误判为 full", ROUTE,
     '    return "full" if (np == 1 and ns == 1) else "partial"\n',
     '    return "full"\n', "期望 partial")

# 5) duplicate 被接受
# 同理: 重复检查与乱序检查互为兜底(BP,BP 既是"重复"也是"交错")。
cell(5, "整对拆掉: 重复 + 乱序检查", ROUTE,
     "    if np > 1 or ns > 1:\n        return \"malformed\"          # 重复受管块\n",
     "    if False:\n        return \"malformed\"          # 重复受管块\n", "期望 malformed",
     old2="    if not _well_ordered(seq):\n        return \"malformed\"          # 乱序 / 交错\n",
     new2="    if False:\n        return \"malformed\"          # 乱序 / 交错\n")

# 6) 近似标记被当成 absent(render 会当没装过, 直接追加第二份)
cell(6, "近似标记被当成 absent", ROUTE,
     "    if near:\n        # 近似标记绝不能当成 absent —— 那会让 render 以为没装过而追加第二份块。\n        return \"malformed\"\n",
     "    if near:\n        return \"absent\"\n", "absent")

# 7) 冗余对照 A: 只拆收口。必须**仍全绿** —— 近似守卫能独立把这些输入判死。
#    这一格不是"没有牙齿", 而是把防御纵深记录在案: 哪一条能单独兜住, 白纸黑字。
cell(7, "冗余对照A: 只拆收口", ROUTE,
     "    if _has_managed(strip(text)):\n        return \"malformed\"\n",
     "    if False:\n        return \"malformed\"\n", "", expect_red=False)

# 8) 冗余对照 B: 只拆乱序检查。必须仍全绿 —— 收口(strip 后仍有受管内容)能独立兜住。
cell(8, "冗余对照B: 只拆乱序检查", ROUTE,
     "    if not _well_ordered(seq):\n        return \"malformed\"          # 乱序 / 交错\n",
     "    if False:\n        return \"malformed\"          # 乱序 / 交错\n", "", expect_red=False)

# 9) 反向格: 无关注释
cell(9, "追加无关注释", ROUTE,
     "def _has_managed(text):\n",
     "# 负控用的无关注释, 不改变任何行为\ndef _has_managed(text):\n", "", expect_red=False)

print("\n── 收尾 ──")
for rel in TOUCHED:
    (ok if sha(os.path.join(REPO, rel)) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
    (ok if os.stat(os.path.join(WC, rel)).st_mode & 0o777 == MODE[rel] else bad)(
        "%s mode 恢复为 %o" % (rel, MODE[rel]))
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

#!/usr/bin/env python3
"""nft 渲染判据的负控: 把修复逐个拆掉, 证明 test-firewall-render-tokens.py 会转红,
并且**点得出名字**; 再加一格无关改动, 证明它不是"见改就红"。

为什么要有: 那两个 `-e` 刚补上, 测试当场变绿。但"变绿"不说明判据有牙齿 —— 一条写宽了
的正则、一个恒真的集合比较, 在接线正确时同样是绿的。这支回答的是"如果哪天有人把
rescue port 的替换又摘掉, 我们会不会知道"。

改坏落在工作副本, 正式树一个字节不动。每格四步缺一不可:
锚点唯一命中 → 摘要确实变化 → 语法门通过 → 新增可点名失败(第 5 格反过来: 必须仍全绿)。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST = "tests/test-firewall-render-tokens.py"
TOUCHED = ["deploy/bot/pdg.sh", "deploy/firewall/nftables-mihomo.conf"]

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


WCROOT = tmpguard.mkdtemp(prefix="pdg-fwnc-")
WC = os.path.join(WCROOT, "wc")
os.makedirs(WC)
for rel in TOUCHED + [TEST]:
    d = os.path.join(WC, os.path.dirname(rel))
    os.makedirs(d, exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), os.path.join(WC, rel))
# 判据要按仓库根解析路径, 给它一个最小但完整的目录形态。
# lib/rescue.sh 也必须在: 被测判据从那里读救援端口(全仓不变量: 端口字面量只许出现在
# 那一个文件)。少拷它的话每一格都会因为"读不出端口"而红 —— 那种红与被测的东西无关。
shutil.copy2(os.path.join(REPO, "install.sh"), os.path.join(WC, "install.sh"))
os.makedirs(os.path.join(WC, "lib"), exist_ok=True)
shutil.copy2(os.path.join(REPO, "lib", "rescue.sh"), os.path.join(WC, "lib", "rescue.sh"))
PRISTINE = {rel: open(os.path.join(WC, rel), "rb").read() for rel in TOUCHED}
MODE = {rel: os.stat(os.path.join(WC, rel)).st_mode & 0o777 for rel in TOUCHED}
BASE_SHA = {rel: sha(os.path.join(REPO, rel)) for rel in TOUCHED}


def run_test():
    p = subprocess.run([sys.executable, os.path.join(WC, TEST)],
                       cwd=WC, capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    fails = sorted(l for l in out.splitlines() if l.startswith("[FAIL]"))
    skips = sum(1 for l in out.splitlines() if l.startswith("[SKIP]"))
    n_ok = sum(1 for l in out.splitlines() if l.startswith("[OK]"))
    return fails, n_ok, skips, out


def restore():
    for rel in TOUCHED:
        path = os.path.join(WC, rel)
        with open(path, "wb") as f:
            f.write(PRISTINE[rel])
        os.chmod(path, MODE[rel])


print("── 基线: 修复到位时必须全绿, 且动态段真的跑了 ──")
BASE_FAILS, BASE_OK, BASE_SKIP, base_out = run_test()
if BASE_FAILS:
    bad("基线就红了(%d 条), 后面每格都无从判断" % len(BASE_FAILS))
    print("\n".join("      " + x for x in BASE_FAILS[:3]))
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0, 跳过 %d" % (BASE_OK, BASE_SKIP))
if BASE_SKIP:
    bad("动态 nft -c 段被跳过了 —— 这支负控必须在 nft 能当裁判的环境里跑(root/容器)")
    sys.exit(1)
ok("动态 nft -c 段真的执行了(跳过 0), 后面的红才算数")


def cell(n, name, rel, old, new, want, expect_red=True):
    path = os.path.join(WC, rel)
    src = open(path, encoding="utf-8").read()
    hits = src.count(old)
    if hits != 1:
        bad("NC-FW-%d %s → 锚点命中 %d 次, 预期 1(改坏器没打在预期位置)" % (n, name, hits))
        restore()
        return
    before = sha(path)
    open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("NC-FW-%d %s → 摘要没变, mutation 没生效" % (n, name))
        restore()
        return
    if rel.endswith(".sh"):
        g = subprocess.run(["bash", "-n", path], capture_output=True)
        if g.returncode != 0:
            bad("NC-FW-%d %s → 改坏后 shell 语法不合法, 这格不算有效负控" % (n, name))
            restore()
            return
    fails, n_ok, skips, out = run_test()
    added = [x for x in fails if x not in BASE_FAILS]
    if "Traceback" in out:
        bad("NC-FW-%d %s → 出现 Traceback, 不算转红" % (n, name))
    elif not expect_red:
        if fails:
            bad("NC-FW-%d %s → **不该红却红了**(%s) —— 判据是'见改就红'"
                % (n, name, fails[0][:60]))
        else:
            ok("NC-FW-%d %-30s → 仍全绿(通过 %d), 判据认的是语义不是任何改动"
               % (n, name, n_ok))
    elif not added:
        bad("NC-FW-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name))
    elif not any(want in x for x in added):
        bad("NC-FW-%d %s → 转红但没点名 %r: %s" % (n, name, want, added[0][:80]))
    else:
        ok("NC-FW-%d %-30s → 新增 %d 条: %s" % (n, name, len(added), added[0][7:90]))
    restore()
    if sha(path) != sha(os.path.join(REPO, rel)):
        bad("NC-FW-%d %s → 恢复后摘要与正式树不一致" % (n, name))


print("\n── 五格 ──")
# 1) 摘掉平台切换渲染器的 rescue port 替换
cell(1, "平台切换摘掉 rescue port", "deploy/bot/pdg.sh",
     '  sed -e "s|__SSH_PORT__|$sshp|g" -e "s|__INTERNAL_CIDR__|$icidr|g" \\\n'
     '      -e "s|__RESCUE_PORT__|$PDG_RESCUE_PORT|g" \\\n',
     '  sed -e "s|__SSH_PORT__|$sshp|g" -e "s|__INTERNAL_CIDR__|$icidr|g" \\\n',
     "漏替换 __RESCUE_PORT__")

# 2) 摘掉 migrate-fw 渲染器的替换
cell(2, "migrate-fw 摘掉 rescue port", "deploy/bot/pdg.sh",
     '  sed -e "s/__SSH_PORT__/$port/g" -e "s#__INTERNAL_CIDR__#$cidr#g" \\\n'
     '      -e "s#__RESCUE_PORT__#$PDG_RESCUE_PORT#g" \\\n',
     '  sed -e "s/__SSH_PORT__/$port/g" -e "s#__INTERNAL_CIDR__#$cidr#g" \\\n',
     "漏替换 __RESCUE_PORT__")

# 3) 换成写死的错误端口: 覆盖判据仍满足, 但"必须用现有常量"这条语义判据要抓住
cell(3, "换成写死的错误端口", "deploy/bot/pdg.sh",
     '      -e "s|__RESCUE_PORT__|$PDG_RESCUE_PORT|g" \\\n',
     '      -e "s|__RESCUE_PORT__|9999|g" \\\n',
     "用的不是现有常量")

# 4) 模板新增一个谁都没替换的 token: 产物里必留字面量, 真 nft -c 必须判死。
#    这一格同时验证"需替换集合是从模板读出来的"——写死清单的判据在这里会瞎。
cell(4, "模板新增未被替换的 token", "deploy/firewall/nftables-mihomo.conf",
     "        ip saddr __INTERNAL_CIDR__ tcp dport __RESCUE_PORT__ accept",
     "        ip saddr __INTERNAL_CIDR__ tcp dport __RESCUE_PORT__ accept\n"
     "        ip saddr __INTERNAL_CIDR__ tcp dport __NEW_TOKEN__ accept",
     "nft -c 不过")

# 5) 反向格: 无关注释。必须仍全绿。
cell(5, "追加无关注释", "deploy/bot/pdg.sh",
     "migrate_firewall_to_pdg(){\n",
     "migrate_firewall_to_pdg(){\n  # 负控用的无关注释, 不改变任何行为\n",
     "", expect_red=False)

print("\n── 收尾 ──")
for rel in TOUCHED:
    (ok if sha(os.path.join(REPO, rel)) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
    (ok if os.stat(os.path.join(WC, rel)).st_mode & 0o777 == MODE[rel] else bad)(
        "%s mode 恢复为 %o" % (rel, MODE[rel]))
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

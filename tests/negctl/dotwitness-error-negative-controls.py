#!/usr/bin/env python3
"""错误可观测性判据的负控: 把理由逐条拆掉, 证明 test-dotwitness-error-reasons.py 会
转红并点名; 再加一格无关改动, 证明它不是"见改就红"。

那支是**静态**判据 —— 静态判据最容易写成永远绿的摆设(正则写宽一点、集合比较恒真,
接线正确时照样全绿)。这支回答的是: 哪天有人把某条理由摘掉、或把域名回显加回去,
我们会不会当场知道。

"把失败改成 return 0" 那一类不在这里 —— 静态判据本来就不该管运行时行为, 那条由
tests/e2e-dot-migrate.sh 的故障矩阵与 tests/negctl/dot-lifecycle-negative-controls.py
负责。这支只咬"理由存不存在、区不区分得开、漏不漏私有值"。

改坏落在工作副本, 正式树一个字节不动。每格四步缺一不可:
锚点唯一命中 → 摘要确实变化 → bash -n 通过 → 新增可点名失败(末格反过来: 必须仍全绿)。
"""
import hashlib
import os
import shutil
import subprocess
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST = "tests/test-dotwitness-error-reasons.py"
TARGET = "deploy/bot/pdg.sh"

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


WCROOT = tmpguard.mkdtemp(prefix="pdg-dwenc-")
WC = os.path.join(WCROOT, "wc")
for rel in (TARGET, TEST):
    os.makedirs(os.path.join(WC, os.path.dirname(rel)), exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), os.path.join(WC, rel))
PRISTINE = open(os.path.join(WC, TARGET), "rb").read()
MODE = os.stat(os.path.join(WC, TARGET)).st_mode & 0o777
BASE_SHA = sha(os.path.join(REPO, TARGET))


def restore():
    p = os.path.join(WC, TARGET)
    with open(p, "wb") as f:
        f.write(PRISTINE)
    os.chmod(p, MODE)


def run_test():
    p = subprocess.run([sys.executable, os.path.join(WC, TEST)],
                       cwd=WC, capture_output=True, text=True, timeout=120)
    out = (p.stdout or "") + (p.stderr or "")
    return sorted(l for l in out.splitlines() if l.startswith("[FAIL]")), \
        sum(1 for l in out.splitlines() if l.startswith("[OK]")), out


print("── 基线: 理由齐全时必须全绿 ──")
BASE_FAILS, BASE_OK, base_out = run_test()
if BASE_FAILS or "Traceback" in base_out:
    bad("基线不干净(%d 条), 后面每格都无从判断" % len(BASE_FAILS))
    print("\n".join("      " + x for x in BASE_FAILS[:3]))
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0" % BASE_OK)


def cell(n, name, old, new, want, expect_red=True):
    path = os.path.join(WC, TARGET)
    src = open(path, encoding="utf-8").read()
    hits = src.count(old)
    if hits != 1:
        bad("NC-DW-%d %s → 锚点命中 %d 次, 预期 1" % (n, name, hits))
        restore()
        return
    before = sha(path)
    open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("NC-DW-%d %s → 摘要没变, mutation 没生效" % (n, name))
        restore()
        return
    g = subprocess.run(["bash", "-n", path], capture_output=True)
    if g.returncode != 0:
        bad("NC-DW-%d %s → 改坏后语法不合法, 这格不算有效负控" % (n, name))
        restore()
        return
    fails, n_ok, out = run_test()
    added = [x for x in fails if x not in BASE_FAILS]
    if "Traceback" in out:
        bad("NC-DW-%d %s → 判据崩了(Traceback), 不算转红" % (n, name))
    elif not expect_red:
        if fails:
            bad("NC-DW-%d %s → **不该红却红了**: %s" % (n, name, fails[0][:70]))
        else:
            ok("NC-DW-%d %-28s → 仍全绿(通过 %d), 认语义不认任何改动" % (n, name, n_ok))
    elif not added:
        bad("NC-DW-%d %s → **没有新增失败**, 这条判据没有守卫" % (n, name))
    elif not any(want in x for x in added):
        bad("NC-DW-%d %s → 转红但没点名 %r: %s" % (n, name, want, added[0][:80]))
    else:
        ok("NC-DW-%d %-28s → 新增 %d 条: %s" % (n, name, len(added), added[0][7:86]))
    restore()


print("\n── 五格 ──")

# 1) 摘掉 mktemp 那条理由 —— 正是本轮修掉的那条静默路径, 让它退回原样
cell(1, "把 mktemp 的理由摘掉",
     '  local work; work="$(mktemp -d)" || {\n'
     '    c_y "  ❌ 建不出 witness 的临时工作区(磁盘满 / TMPDIR 不可写?) —— 未做任何改动。"\n'
     '    return 1; }',
     '  local work; work="$(mktemp -d)" || return 1',
     "一个字都不说")

# 2) 把域名回显加回去 —— 这次修掉的隐私问题的原始形态
cell(2, "域名回显加回日志",
     '    c_y "  ❌ DoT 域名非法: /opt/pdg-bot/dot-domain 的内容不是合法域名(不回显内容) —— 不部署 observer。"',
     '    c_y "  ❌ DoT 域名非法($dom) —— 不部署 observer。"',
     "回显进日志")

# 3) 缺失与非法合并成一句 —— 处置动作不同却给同一句话
cell(3, "缺失与非法合成一句",
     '    c_y "  ❌ DoT 域名缺失: /opt/pdg-bot/dot-domain 不存在或为空 —— 不部署 observer(拼进配置的值不能靠猜)。"',
     '    c_y "  ❌ witness 迁移失败。"',
     "没分开")

# 4) 让候选校验与 5399 说同一句话 —— 两个处置完全不同的故障被混成一个
cell(4, "校验失败与 5399 混为一句",
     '    c_y "  ❌ pdg-dotwitness 已启动但没有在 127.0.0.1:5399 监听, 正在回滚。"',
     '    c_y "  ❌ mosdns 路由候选未通过校验, 保持原配置不动:"',
     "各自成句")

# 5) 反向格: 无关注释。必须仍全绿。
cell(5, "追加无关注释",
     "migrate_dotwitness(){\n",
     "migrate_dotwitness(){\n  # 负控用的无关注释, 不改变任何行为\n",
     "", expect_red=False)

print("\n── 收尾 ──")
(ok if sha(os.path.join(REPO, TARGET)) == BASE_SHA else bad)("正式树 %s 逐字节一致" % TARGET)
(ok if os.stat(os.path.join(WC, TARGET)).st_mode & 0o777 == MODE else bad)(
    "工作副本 mode 恢复为 %o" % MODE)
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

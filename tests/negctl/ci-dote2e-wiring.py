#!/usr/bin/env python3
"""dot-systemd-e2e 接线判据的守卫级负控(六格 + 反向对照)。

两支最容易假绿的 E2E 挂在这个 job 上。它们进门都有隔离门, 缺了那道门会以"整支 SKIP
然后 rc=0"的形态逃生 —— job 照样绿。所以接线本身必须有守卫, 而守卫本身必须有牙齿。
这支回答的就是后半句。

改坏落在工作副本, 正式树一个字节不动。每格四步缺一不可:
锚点唯一命中 → 摘要确实变化 → YAML 仍能解析(语法损坏不算有效负控) → 守卫点名转红。

真 E2E 级的四格(夹具漏装模块 / 不用 v1.9.0 形态 / 域名不一致 / 跳过生产状态机)在
tests/negctl/ci-dote2e-fixture.sh —— 那四格要起真 systemd 容器, 单独一支。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WF = ".github/workflows/ci.yml"
GUARD = "tests/test-ci-coverage.py"

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


WCROOT = tempfile.mkdtemp(prefix="pdg-ciwnc-")
WC = os.path.join(WCROOT, "wc")
subprocess.run(["git", "-C", REPO, "worktree", "list"], capture_output=True)
shutil.copytree(REPO, WC, symlinks=True,
                ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"))
PRISTINE = open(os.path.join(WC, WF), "rb").read()
MODE = os.stat(os.path.join(WC, WF)).st_mode & 0o777
BASE_SHA = sha(os.path.join(REPO, WF))


def restore():
    p = os.path.join(WC, WF)
    with open(p, "wb") as f:
        f.write(PRISTINE)
    os.chmod(p, MODE)


def run_guard():
    p = subprocess.run([sys.executable, os.path.join(WC, GUARD)],
                       cwd=WC, capture_output=True, text=True, timeout=300)
    out = (p.stdout or "") + (p.stderr or "")
    fails = sorted(l for l in out.splitlines() if l.strip().startswith("✗"))
    n_ok = sum(1 for l in out.splitlines() if l.strip().startswith("✓"))
    return fails, n_ok, out


def yaml_ok(path):
    """YAML 必须仍能解析 —— 解析不了的红灯是语法损坏, 不算有效负控。
    宿主没有 pyyaml 时退化成一条结构性检查: 缩进 2 的 job 键数量不变。"""
    try:
        import yaml  # noqa: F401
    except ImportError:
        a = len(re.findall(r"^  [a-z0-9][a-z0-9-]*:$", PRISTINE.decode(), re.M))
        b = len(re.findall(r"^  [a-z0-9][a-z0-9-]*:$", open(path, encoding="utf-8").read(), re.M))
        return a == b, "(无 pyyaml, 退化为 job 键计数 %d→%d)" % (a, b)
    import yaml
    try:
        yaml.safe_load(open(path, encoding="utf-8"))
        return True, ""
    except Exception as e:
        return False, str(e)[:80]


print("── 基线: 接线完整时守卫必须全绿 ──")
BASE_FAILS, BASE_OK, base_out = run_guard()
if BASE_FAILS:
    bad("基线守卫就红了(%d 条)" % len(BASE_FAILS))
    print("\n".join("      " + x.strip() for x in BASE_FAILS[:3]))
    sys.exit(1)
ok("基线绿: 守卫 %d 条断言全过" % BASE_OK)


def cell(n, name, old, new, want, expect_red=True):
    path = os.path.join(WC, WF)
    src = open(path, encoding="utf-8").read()
    hits = src.count(old)
    if hits != 1:
        bad("NC-CI-%d %s → 锚点命中 %d 次, 预期 1" % (n, name, hits))
        restore()
        return
    before = sha(path)
    open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("NC-CI-%d %s → 摘要没变" % (n, name))
        restore()
        return
    good, why = yaml_ok(path)
    if not good:
        bad("NC-CI-%d %s → 改坏后 YAML 不合法%s, 这格不算有效负控" % (n, name, why))
        restore()
        return
    fails, n_ok, out = run_guard()
    added = [x for x in fails if x not in BASE_FAILS]
    if "Traceback" in out:
        bad("NC-CI-%d %s → 守卫崩了(Traceback), 不算转红" % (n, name))
    elif not expect_red:
        if fails:
            bad("NC-CI-%d %s → **不该红却红了**: %s" % (n, name, fails[0].strip()[:70]))
        else:
            ok("NC-CI-%d %-32s → 守卫仍全绿(%d 条), 认语义不认任何改动" % (n, name, n_ok))
    elif not added:
        bad("NC-CI-%d %s → **守卫没有新增失败**, 这条接线没有守卫" % (n, name))
    elif not any(want in x for x in added):
        bad("NC-CI-%d %s → 转红但没点名 %r: %s" % (n, name, want, added[0].strip()[:80]))
    else:
        ok("NC-CI-%d %-32s → 新增 %d 条: %s" % (n, name, len(added), added[0].strip()[2:86]))
    restore()


MIG = ("          - script: e2e-dot-migrate.sh\n"
       "            mode: pre\n"
       "            domain: dot.example.test\n")
P0 = ("          - script: e2e-dot-p0.sh\n"
      "            mode: deployed\n"
      "            domain: dot.p0ci.test\n")

print("\n── 六格(守卫级) ──")
cell(1, "删掉 migrate 的登记", MIG, "", "e2e-dot-migrate.sh")
cell(2, "删掉 P0 的登记", P0, "", "e2e-dot-p0.sh")
cell(3, "摘掉测试步骤的隔离门",
     'PDG_E2E_ISOLATED=1 PDG_DOTW_REPO="$PDG_DOTE2E_SNAP" \\\n'
     '            bash "$PDG_DOTE2E_SNAP/tests/${{ matrix.script }}"',
     'PDG_DOTW_REPO="$PDG_DOTE2E_SNAP" \\\n'
     '            bash "$PDG_DOTE2E_SNAP/tests/${{ matrix.script }}"',
     "PDG_E2E_ISOLATED=1")
cell(4, "汇总门那步改回默认 sh",
     '      - name: "跑 ${{ matrix.script }} 并核对汇总(通过>0 / 失败 0 / 跳过 0)"\n'
     '        shell: bash\n',
     '      - name: "跑 ${{ matrix.script }} 并核对汇总(通过>0 / 失败 0 / 跳过 0)"\n',
     "shell: bash")
cell(5, "拆掉快照路径的唯一定义",
     "      PDG_DOTE2E_SNAP: /srv/pdg-dote2e\n",
     "      PDG_DOTE2E_SNAP_ALT: /srv/pdg-dote2e\n",
     "PDG_DOTE2E_SNAP")
cell(6, "放宽汇总门(不再卡跳过)",
     '          test "$ns" -eq 0\n', "", "跳过为 0")

print("\n── 反向对照 ──")
cell(7, "只追加无关注释",
     "  dot-systemd-e2e:\n",
     "  # 负控用的无关注释, 不改变任何接线\n  dot-systemd-e2e:\n",
     "", expect_red=False)

print("\n── 收尾 ──")
(ok if sha(os.path.join(REPO, WF)) == BASE_SHA else bad)("正式树 %s 逐字节一致" % WF)
(ok if os.stat(os.path.join(WC, WF)).st_mode & 0o777 == MODE else bad)("工作副本 mode 恢复为 %o" % MODE)
dirty = subprocess.run(["git", "-C", REPO, "status", "--porcelain"],
                       capture_output=True, text=True).stdout.strip()
(ok if not dirty else bad)("正式树 git status 干净%s" % ("" if not dirty else ": " + dirty[:60]))
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 66)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

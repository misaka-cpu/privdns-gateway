#!/usr/bin/env python3
"""E2E 沙箱硬门: 破坏性操作只能落在本轮创建的一次性根内。

为什么需要这条: `PDG_E2E_ISOLATED=1` + root 时 E2E 直接跑在当前容器根上, 而 CI 与本地都会
把仓库以**可写**方式挂进去。于是一次失败的 `cd`、一个写错的 `rm -rf`、一句 `git reset`,
打的就是开发者的真仓库。这不是假设 —— 本分支上真的因此多出过一个 author 为 t<t@t> 的
"base" 提交、origin 被换成 /tmp 里的裸库、还打了个 v9.9.9 标签。

`PDG_E2E_ISOLATED=1` 是调用方的一句声明, 证明不了任何事。硬门只认自己建的、带本轮 nonce
的 marker, 且目标要经 realpath 解析后确实落在那个根之内。
"""
import os
import re
import subprocess
import sys
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LIB = os.path.join(HERE, "e2e-lib.sh")

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


def sh(body, env=None, cwd=None):
    """在 source 过 e2e-lib.sh 的 shell 里跑一段脚本, 返回 (rc, 输出)。"""
    e = dict(os.environ)
    e["E2E_ROOT"] = ROOT
    e.update(env or {})
    script = 'set -uo pipefail\nE2E_ROOT="%s"\nsource "%s"\n%s' % (ROOT, LIB, body)
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                       env=e, cwd=cwd or ROOT, timeout=180)
    return r.returncode, (r.stdout + r.stderr)


BOX = tmpguard.mkdtemp(prefix="sandboxtest.")
INIT = 'e2e_sandbox_init "%s/box" >/dev/null || exit 9\n' % BOX

print("== 硬门: 目标路径 ==")
for name, target, expect in (
        ("根目录 /", "/", "根目录"),
        ("真实仓库", ROOT, "源码仓库"),
        ("仓库父目录", os.path.dirname(ROOT), "父目录"),
        ("/root", "/root", "系统目录"),
        ("/home", "/home", "系统目录"),
):
    rc, out = sh(INIT + 'e2e_guard_path "%s"' % target)
    if rc != 0 and expect in out:
        ok("%s → 拒绝(%s)" % (name, expect))
    else:
        bad("%s 没被拒: rc=%s %s" % (name, rc, out.strip()[:90]))

print("\n== 硬门: symlink 绕过 ==")
link = os.path.join(BOX, "sneaky")
os.symlink(ROOT, link)
rc, out = sh(INIT + 'e2e_guard_path "%s"' % link)
if rc != 0 and "源码仓库" in out:
    ok("经 symlink 指向真实仓库 → realpath 解析后仍被拒")
else:
    bad("symlink 绕过成功了: rc=%s %s" % (rc, out.strip()[:90]))
rc, out = sh(INIT + 'e2e_guard_path "%s/box/../../etc"' % BOX)
if rc != 0:
    ok("用 `..` 逃出沙箱 → realpath 解析后被拒")
else:
    bad("`..` 逃逸没被挡")

print("\n== 硬门: marker 与 nonce ==")
rc, out = sh(INIT + 'rm -f "%s/box/.e2e-disposable"; e2e_guard_path "%s/box/x"' % (BOX, BOX))
if rc != 0 and "marker" in out:
    ok("marker 被删 → 拒绝")
else:
    bad("marker 缺失仍放行: rc=%s" % rc)
rc, out = sh(INIT + 'printf "deadbeefdeadbeef 1\\n" > "%s/box/.e2e-disposable"; '
             'e2e_guard_path "%s/box/x"' % (BOX, BOX))
if rc != 0 and "nonce" in out:
    ok("marker 里的 nonce 换成别的 → 拒绝(不是只看文件名)")
else:
    bad("nonce 不匹配仍放行: rc=%s" % rc)
rc, out = sh('e2e_guard_path "%s/box/x"' % BOX)      # 没跑 init
if rc != 0 and ("未初始化" in out or "沙箱" in out):
    ok("没跑 e2e_sandbox_init 就用 → 拒绝(默认关闭)")
else:
    bad("未初始化仍放行: rc=%s" % rc)

print("\n== 硬门: 正常路径 ==")
rc, out = sh(INIT + 'e2e_guard_path "%s/box/sub/deep"' % BOX)
if rc == 0:
    ok("沙箱内尚未存在的子路径 → 放行")
else:
    bad("沙箱内路径被误拒: %s" % out.strip()[:90])
rc, out = sh(INIT + 'mkdir -p "%s/box/todel"; e2e_rm_rf "%s/box/todel" && '
             '[[ ! -d "%s/box/todel" ]] && echo DELETED' % (BOX, BOX, BOX))
if rc == 0 and "DELETED" in out:
    ok("e2e_rm_rf 对沙箱内目标正常删除")
else:
    bad("沙箱内删除失败: %s" % out.strip()[:90])
rc, out = sh(INIT + 'e2e_rm_rf "%s"; echo "rc=$?"' % ROOT)
if "rc=1" in out and os.path.exists(os.path.join(ROOT, "install.sh")):
    ok("e2e_rm_rf 指向真实仓库 → 拒绝且仓库完好")
else:
    bad("e2e_rm_rf 删向真实仓库没被挡: %s" % out.strip()[:90])

print("\n== 真实仓库可写挂载时不被改动 ==")
before = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"],
                        capture_output=True, text=True).stdout
tree_before = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD^{tree}"],
                             capture_output=True, text=True).stdout.strip()
rc, out = sh(INIT + 'e2e_rm_rf "%s/box/x" >/dev/null 2>&1; '
             'e2e_guard_path "%s/.git" || true' % (BOX, ROOT))
after = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"],
                       capture_output=True, text=True).stdout
tree_after = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD^{tree}"],
                            capture_output=True, text=True).stdout.strip()
if before == after and tree_before == tree_after:
    ok("跑完之后真实仓库的 status 与 tree 都没变")
else:
    bad("真实仓库被动过: status 变化=%s tree 变化=%s"
        % (before != after, tree_before != tree_after))

print("\n== cd 失败后不得继续执行 ==")
lib_txt = open(LIB, encoding="utf-8").read()
cli = open(os.path.join(HERE, "e2e-cli-ops.sh"), encoding="utf-8").read()
unguarded = [l for l in cli.split("\n")
             if re.match(r"^\s*\(\s*cd\s", l) and "||" not in l]
if not unguarded:
    ok("e2e-cli-ops.sh 里的子 shell `cd` 都带 `||` 兜底")
else:
    bad("这些子 shell cd 没有兜底: %s" % unguarded[0].strip()[:70])
rc, out = sh('( cd /definitely/not/here || { echo GUARDED; exit 1; }; echo REACHED ) ; true')
if "GUARDED" in out and "REACHED" not in out:
    ok("cd 失败 → 后续命令一条都不执行")
else:
    bad("cd 失败后仍在执行: %s" % out.strip()[:80])

print("\n== 中断时仍清理沙箱、不碰原仓库 ==")
rc, out = sh(INIT + 'e2e_add_exit_hook e2e_sandbox_cleanup; '
             'echo BOXPATH=$E2E_SANDBOX; kill -INT $$ 2>/dev/null; sleep 1')
m = re.search(r"BOXPATH=(\S+)", out)
if m and not os.path.exists(m.group(1)):
    ok("收到 SIGINT 后 exit hook 仍把沙箱清掉了")
elif m:
    bad("中断后沙箱残留: %s" % m.group(1))
else:
    bad("拿不到沙箱路径: %s" % out.strip()[:80])
# `.git` 在 **git worktree** 里是一个指向真 gitdir 的**文件**, 不是目录。只认目录的话,
# 任何在 worktree 里跑的人都会看到"原仓库受损"这条假警报 —— 而热修分支正是在 worktree 里
# 开发的。判据换成"仓库还认得出自己": 存在(文件或目录)且 git 能解析出 gitdir。
_git = os.path.join(ROOT, ".git")
_repo_ok = os.path.exists(_git) and subprocess.run(
    ["git", "-C", ROOT, "rev-parse", "--git-dir"],
    capture_output=True, text=True).returncode == 0
if os.path.exists(os.path.join(ROOT, "install.sh")) and _repo_ok:
    ok("中断路径没有碰到原仓库")
else:
    bad("原仓库受损")

print("\n== 判据只有一份 ==")
copies = [f for f in os.listdir(HERE)
          if f.startswith("e2e-") and f.endswith(".sh") and f != "e2e-lib.sh"
          and "realpath -m" in open(os.path.join(HERE, f), encoding="utf-8").read()]
if not copies:
    ok("各 E2E 脚本没有各自抄一份 realpath 判据")
else:
    bad("这些脚本自带了判据副本: %s" % "、".join(copies))
if "PDG_E2E_ISOLATED" in lib_txt and "只是调用方的一句声明" in lib_txt:
    ok("PDG_E2E_ISOLATED 已明确不再当作安全证明")
else:
    bad("仍把 PDG_E2E_ISOLATED 当隔离依据")

subprocess.run(["rm", "-rf", BOX], timeout=60)
total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

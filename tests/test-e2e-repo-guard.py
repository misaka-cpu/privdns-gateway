#!/usr/bin/env python3
"""e2e 不许碰共享的 git ref 库 —— 复现 2026-07-31 那次事故并钉死。

那天丢掉了开发者真仓库的**全部 56 个 tag 和全部 remote-tracking ref**, 还多出两个作者是
`t <t@t>`、消息是 "base" 的提交。经过是这样的:

  · `tests/e2e-cli-ops.sh` 里有一段 `cd /opt/privdns-gateway || exit` 守着的 git 操作
    (`git config user.email t@t` / `git add -A && git commit -qm base` /
     `git remote remove origin` / `git tag -f v9.9.9`);
  · 那段守卫只检查**目录存不存在**。沙箱里那个目录确实存在, 于是整块放行;
  · 而它是一个 **linked worktree** —— `.git` 是一行 `gitdir:` 指针文件, refs 与 config
    与主仓库**共享**。于是每一条都打在了开发者的真仓库上。

所以判据不能是"目录在不在", 也不能是"路径在不在沙箱里"(worktree 的路径完全可以在沙箱内)。
唯一站得住的判据是 **`--git-common-dir` 不能与源码仓库的是同一个**。

这个文件只用一次性的临时仓库, 不碰本仓库的任何 ref。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LIB = os.path.join(HERE, "repoguard.sh")

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def sh(script, cwd=None, env=None):
    e = dict(os.environ)
    e.setdefault("E2E_ROOT", ROOT)
    if env:
        e.update(env)
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                       cwd=cwd or ROOT, timeout=300, env=e)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def git(args, cwd, check=True):
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise RuntimeError("git %s → %s" % (" ".join(args), r.stderr[-200:]))
    return (r.stdout or "").strip()


def make_dev_repo():
    """造一个"开发者真仓库"的替身: 有提交、有 tag、有 remote-tracking, 外加一个 worktree。"""
    base = tempfile.mkdtemp(prefix="repoguard-")
    TMPS.append(base)
    upstream = os.path.join(base, "upstream.git")
    dev = os.path.join(base, "dev")
    wt = os.path.join(base, "wt")
    git(["init", "-q", "--bare", upstream], base)
    git(["init", "-q", "-b", "main", dev], base)
    for k, v in (("user.email", "dev@example.com"), ("user.name", "dev"),
                 ("commit.gpgsign", "false")):
        git(["config", k, v], dev)
    open(os.path.join(dev, "install.sh"), "w").write("#!/bin/sh\n")
    git(["add", "-A"], dev)
    git(["commit", "-qm", "real work"], dev)
    git(["tag", "v1.0.0"], dev)
    git(["remote", "add", "origin", upstream], dev)
    git(["push", "-q", "origin", "main", "--tags"], dev)
    git(["fetch", "-q", "origin"], dev)
    git(["worktree", "add", "-q", "-b", "sidebranch", wt], dev)
    return base, dev, wt


def snapshot(dev):
    return {
        "tags": sorted(git(["tag"], dev).split()),
        "remotes": sorted(git(["branch", "-r"], dev).split()),
        "head": git(["rev-parse", "HEAD"], dev),
        "branch": git(["rev-parse", "--abbrev-ref", "HEAD"], dev),
        "user": git(["config", "user.name"], dev, check=False),
        "origin": git(["config", "remote.origin.url"], dev, check=False),
    }


print("══ 一、判据本身: 只有一次性仓库才放行 ══")
base, dev, wt = make_dev_repo()
fresh = tempfile.mkdtemp(prefix="repoguard-fresh-")
TMPS.append(fresh)
git(["init", "-q", fresh], fresh)
plain = tempfile.mkdtemp(prefix="repoguard-plain-")
TMPS.append(plain)

CALL = ('source "%s"\nE2E_ROOT=%%r\ne2e_guard_repo %%r\n' % LIB) % (ROOT, "%s")
# 每条都带上**必须由哪道门给出的理由**。只断言"被拒了"是不够的: 这几道门互为兜底,
# 拆掉任何一道另一道都会补位, 于是负控咬不住 —— 而每道门存在的意义正是它那句话本身
# (比如"不是 git 仓库"要告诉你 git 会向上找到别的仓库, 这是最容易被忽略的一种)。
# ROOT 自己可能就是个 linked worktree —— 本仓库的 .claude/worktrees/* 正是, 而这套用例
# 也会在那里面跑。那时"拒绝源码仓库"会先被**自持**那道门(ref 库不属于这个目录自己)拦下,
# 而不是"与源码仓库共用"那道。两句都是对的, 哪句先开口取决于仓库是怎么检出的 —— 所以期望
# 值要按实际形态算出来, 不能写死一句。写死的下场就是在 worktree 里一片假红, 而假红的原因
# 与被测对象无关: 这正是今天已经栽过三次的那类毛病。
_cd = subprocess.run(["git", "-C", ROOT, "rev-parse", "--git-common-dir"],
                     capture_output=True, text=True, timeout=60).stdout.strip()
_root_is_worktree = os.path.realpath(os.path.join(ROOT, _cd)) != \
    os.path.realpath(os.path.join(ROOT, ".git"))
ROOT_WHY = "ref 库不属于这个目录自己" if _root_is_worktree else "共用同一个 ref 库"

for label, target, want_ok, want_why in (
        ("源码仓库本体", ROOT, False, ROOT_WHY),
        ("一次性 /tmp 仓库", fresh, True, None),
        ("根本不是仓库的目录", plain, False, "不是 git 仓库"),
        ("不存在的目录", os.path.join(plain, "nope"), False, "目录不存在")):
    rc, out = sh(('source "%s"\nE2E_ROOT=%r\ne2e_guard_repo %r\n' % (LIB, ROOT, target)))
    got_ok = (rc == 0)
    if got_ok != want_ok:
        bad("%s → 期望%s实际%s: %s" % (label, "放行" if want_ok else "拒绝",
                                      "放行" if got_ok else "拒绝", out.strip()[:120]))
    elif want_ok:
        ok("%s → 放行" % label)
    elif want_why in out:
        ok("%s → 由「%s」这道门拒绝" % (label, want_why))
    else:
        bad("%s 是被拒了, 但不是「%s」那道门开的口: %s" % (label, want_why, out.strip()[:110]))

# worktree 那条单独造: 要用**本仓库自己的** worktree 才算数(共用 ref 库的正是它)
_wt = tempfile.mkdtemp(prefix="repoguard-selfwt-")
TMPS.append(_wt)
_wtdir = os.path.join(_wt, "w")
_made = subprocess.run(["git", "-C", ROOT, "worktree", "add", "-q", "--detach", _wtdir, "HEAD"],
                       capture_output=True, text=True, timeout=180)
if _made.returncode == 0:
    rc, out = sh(('source "%s"\nE2E_ROOT=%r\ne2e_guard_repo %r\n' % (LIB, ROOT, _wtdir)))
    # 判据是"因为 ref 库的归属被拒", 不钉死具体哪一道门先开口 —— 自持那道
    # (ref 库不属于这个目录自己)会比"与源码仓库同库"更早命中, 两句都算数。
    if rc != 0 and "ref 库" in out:
        ok("源码仓库的 worktree → 拒绝: %s" % out.strip().split(": ", 1)[-1][:52])
    else:
        bad("worktree 竟然被放行了 —— 这正是事故那天的形态: rc=%d %s" % (rc, out.strip()[:150]))
    subprocess.run(["git", "-C", ROOT, "worktree", "remove", "--force", _wtdir],
                   capture_output=True, timeout=180)
else:
    bad("造不出 worktree, 这条最关键的判据没验到: %s" % _made.stderr[-160:])

print()
print("══ 二、复现事故: 拿真实的那段代码打一个 worktree ══")
# 从 e2e-cli-ops.sh 里**原样**抽出那段会动 ref 的子 shell —— 不是照抄一份, 抄的会跟着漂。
src = open(os.path.join(HERE, "e2e-cli-ops.sh"), encoding="utf-8").read()
m = re.search(r"^\( cd /opt/privdns-gateway \|\|.*?\)\s*\|\|\s*true\s*$",
              src, re.S | re.M)
if not m:
    bad("抽不到 e2e-cli-ops.sh 里那段 git 块 —— 判据失去依据, 不能算过")
else:
    ok("抽到了真实的那段 git 块(%d 行), 不是照抄的副本" % m.group(0).count("\n"))
    block = m.group(0).replace("/opt/privdns-gateway", wt)
    before = snapshot(dev)
    rc, out = sh('source "%s"\nE2E_ROOT=%r\n%s\n' % (LIB, ROOT, block), cwd=base)
    after = snapshot(dev)
    if after == before:
        ok("那段代码打在 worktree 上时, 上游仓库的 tag/remote/HEAD/身份**一个都没动**")
    else:
        diff = [k for k in before if before[k] != after[k]]
        bad("上游仓库被打坏了, 变化的字段: %s\n       before=%r\n       after =%r"
            % (", ".join(diff), {k: before[k] for k in diff}, {k: after[k] for k in diff}))

print()
print("══ 三、每个会动 ref 的脚本都必须过这道门 ══")
DANGEROUS = re.compile(r"git\s+(?:-C\s+\S+\s+)?(?:tag\s+-[df]|tag\s+--delete|remote\s+remove|"
                       r"remote\s+add|commit\b|update-ref\s+-d|push\b)")
missing = []
for fn in sorted(os.listdir(HERE)):
    if not fn.endswith(".sh") or fn == "e2e-lib.sh":
        continue
    txt = open(os.path.join(HERE, fn), encoding="utf-8").read()
    code = "\n".join(l for l in txt.split("\n") if not l.lstrip().startswith("#"))
    if DANGEROUS.search(code) and "e2e_guard_repo" not in code:
        missing.append(fn)
if not missing:
    ok("所有会动 ref 的 e2e 脚本都调了 e2e_guard_repo")
else:
    bad("这些脚本会动 ref 却没过守卫: %s" % ", ".join(missing))

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

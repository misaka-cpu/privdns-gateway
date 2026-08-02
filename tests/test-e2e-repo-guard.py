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
print("══ 三、e2e_git: 守卫与动作绑成一件事 ══")
# 守卫写对了不等于守卫跑到了。e2e_git 把两者合成一次调用, 于是"忘了守""守晚了"这两种形态
# 在语法上就不存在。这里验它确实先守后跑, 且拒绝时**一条 git 都没执行**。
_wt2 = tempfile.mkdtemp(prefix="repoguard-e2egit-")
TMPS.append(_wt2)
_wtdir2 = os.path.join(_wt2, "w")
_made2 = subprocess.run(["git", "-C", ROOT, "worktree", "add", "-q", "--detach", _wtdir2, "HEAD"],
                        capture_output=True, text=True, timeout=180)
if _made2.returncode != 0:
    bad("造不出 worktree, e2e_git 的判据没验到: %s" % _made2.stderr[-160:])
else:
    _before_remote = git(["config", "--get", "remote.origin.url"], ROOT, check=False)
    rc, out = sh('source "%s"\nE2E_ROOT=%r\ne2e_git %r remote add e2eprobe /tmp/nope.git\n'
                 % (LIB, ROOT, _wtdir2))
    _after_remote = git(["config", "--get", "remote.origin.url"], ROOT, check=False)
    _probe = git(["config", "--get", "remote.e2eprobe.url"], ROOT, check=False)
    if rc != 0 and "ref 库" in out:
        ok("e2e_git 打在 worktree 上 → 先被守卫拒掉(rc=%d)" % rc)
    else:
        bad("e2e_git 没拦住 worktree —— 守卫没跑在动作前面: rc=%d %s" % (rc, out.strip()[:150]))
    if not _probe and _after_remote == _before_remote:
        ok("被拒时上游仓库的 remote **一条都没写进去**(不是先写后报错)")
    else:
        bad("守卫拒了但 git 还是执行了: remote.e2eprobe.url=%r, origin %r→%r"
            % (_probe, _before_remote, _after_remote))
    # 正例: 一次性的独立仓库要放行, 否则守卫会把所有 e2e 卡死
    _solo = os.path.join(_wt2, "solo")
    os.makedirs(_solo, exist_ok=True)
    git(["init", "-q"], _solo)
    rc, out = sh('source "%s"\nE2E_ROOT=%r\ne2e_git %r remote add origin /tmp/x.git\n'
                 % (LIB, ROOT, _solo))
    if rc == 0 and git(["config", "--get", "remote.origin.url"], _solo, check=False) == "/tmp/x.git":
        ok("e2e_git 对一次性独立仓库放行, 且动作真的执行了")
    else:
        bad("e2e_git 把正常仓库也拒了(守卫过紧, 会把 e2e 全卡死): rc=%d %s" % (rc, out.strip()[:150]))
    subprocess.run(["git", "-C", ROOT, "worktree", "remove", "--force", _wtdir2],
                   capture_output=True, timeout=180)

print()
print("══ 四、每一处会动 ref/config 的 git 调用都必须自带守卫 ══")
# 这一节以前是**文件级**判据: 文件里出现危险 git 调用、且文件里任何地方出现过 e2e_guard_repo
# 就算过。e2e-cli-ops.sh 恰好两个条件都满足 —— 而它有两条 `git -C … remote add origin` 前面
# 一条守卫都没有, 另一处更是把守卫写在三行改动**之后**(先改后守, 守了也白守)。2026-08-02
# 开发者仓库的 origin 被改指到 /tmp 裸库, 就是从那里出去的。判据本身没错, 错在它只数文件、
# 不看调用点 —— 于是"这个文件里有守卫"被当成了"这一行被守住了"。
#
# 现在按**每一次调用**判: 会写 ref/config/index 的 git 一律要写成 e2e_git。只读查询
# (rev-parse/describe/tag -l/archive…)不受限 —— 逼它们绕守卫只会让"目标故意不是仓库"的
# 用例假失败。`git init`/`git clone` 也不受限: 仓库还不存在时守卫必然假拒。
MUT = {"config", "add", "commit", "tag", "remote", "push", "checkout", "reset", "branch",
       "update-ref", "fetch", "switch", "restore", "stash", "am", "rebase", "merge",
       "cherry-pick", "revert", "gc", "prune", "replace", "notes", "worktree"}
# 这些子命令名虽然在 MUT 里, 但带上这些参数就是**纯查询**。漏收一个的后果是假阳性 ——
# 拦下一条无害的只读调用, 吵但安全; 反过来把某个写形态误收进来才是真漏, 所以只准逐个列举
# 明确的只读形态, 不准写成"带 -- 开头的都算只读"。
READONLY_FORM = (
    re.compile(r"^tag\s+(-l|--list|--points-at|--contains|--no-contains"
               r"|--merged|--no-merged|-n\d*)\b"),
    re.compile(r"^remote\s+(-v|show|get-url)\b"),
    re.compile(r"^config\s+(--get\S*|--list|-l)\b"),
    re.compile(r"^branch\s+(-l|--list|--show-current|--contains|--points-at)\b"),
    re.compile(r"^stash\s+(list|show)\b"),
    re.compile(r"^notes\s+(list|show)\b"),
)
# `git` 前面不能紧跟标识符字符 —— 否则 `e2e_git . tag -d` 自己会被算成裸调用。
RAW_GIT = re.compile(r"(?<![\w.-])git\s+(?:-C\s+\S+\s+)?(?:-c\s+\S+\s+)*(?=[a-z])")
# 出现在 grep 模式 / 断言标题里的 "git …" 是**字符串**, 不是调用。
QUOTED = re.compile(r"\b(grep|rg|assert_\w+|echo|printf)\b")
offenders = []
for fn in sorted(os.listdir(HERE)):
    if not fn.endswith(".sh") or fn == "repoguard.sh":   # repoguard.sh 自己就是守卫的实现
        continue
    for lineno, line in enumerate(open(os.path.join(HERE, fn), encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):
            continue
        code = line.split("#")[0]
        for m in RAW_GIT.finditer(code):
            rest = code[m.end():]
            sub = (rest.split() or [""])[0]
            if sub not in MUT or any(p.match(rest) for p in READONLY_FORM):
                continue
            if QUOTED.search(code[:m.start()]):
                continue
            offenders.append("%s:%d  %s" % (fn, lineno, line.strip()[:76]))
if not offenders:
    ok("tests/ 下每一处会动 ref/config 的 git 调用都走 e2e_git(逐调用点核对, 不是逐文件)")
else:
    bad("这些调用点会动 ref/config 却没走 e2e_git —— 守卫漏掉它们就是事故那天的形态:\n       "
        + "\n       ".join(offenders[:12])
        + ("\n       …共 %d 处" % len(offenders) if len(offenders) > 12 else ""))

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

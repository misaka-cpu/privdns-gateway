#!/usr/bin/env python3
"""6.2A 测试卫生: 两支 dot 测试在**任何**退出路径上都不许留下临时目录。

为什么要单独一支盯它: 负控的工作方式就是把被测测试改红甚至改崩, 而
`test-dot-faults.py` / `test-dot-privacy.py` 原先把 `shutil.rmtree` 放在脚本末尾 ——
一崩就跳过, 宿主 /tmp 里于是攒下了 7 个 `pdg-dotfault-*` / `pdg-dotpriv-*`。
清理必须挂在退出钩子上, 而不是"跑到最后一行"。

判据不看源码写法, 直接**制造那三种退出**再数目录。
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGETS = {
    "test-dot-faults.py": "pdg-dotfault-",
    "test-dot-privacy.py": "pdg-dotpriv-",
}

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


def dirs_in(sandbox, prefix):
    try:
        return sorted(n for n in os.listdir(sandbox) if n.startswith(prefix))
    except OSError:
        return []


def run(name, sandbox, mode, keep=False):
    """在独立 TMPDIR 沙箱里跑目标测试。mode 决定注入哪种退出路径。

    注入靠环境变量而不是改文件 —— 改文件就变成"测另一份代码"了。
    """
    env = dict(os.environ)
    env["TMPDIR"] = sandbox
    env.pop("E2E_TMP", None)
    env["PDG_TMPGUARD_SELFTEST"] = mode          # 目标测试认这个变量, 见下方说明
    if keep:
        env["PDG_KEEP_TMP"] = "1"
    else:
        env.pop("PDG_KEEP_TMP", None)
    p = subprocess.run([sys.executable, os.path.join(ROOT, "tests", name)],
                       capture_output=True, text=True, env=env, timeout=900)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


head("1. 三种退出路径都必须清理")
for name, prefix in TARGETS.items():
    for mode, why in (("", "正常退出"), ("raise", "未捕获异常"),
                      ("sysexit", "SystemExit"), ("kbint", "KeyboardInterrupt")):
        sandbox = tempfile.mkdtemp(prefix="pdg-tmpguard-")
        try:
            rc, out = run(name, sandbox, mode)
            left = dirs_in(sandbox, prefix)
            (ok if not left else bad)(
                "%s / %s → 沙箱里 %s* 残留 %d 个" % (name, why, prefix, len(left)))
        finally:
            subprocess.run(["rm", "-rf", sandbox])

head("2. PDG_KEEP_TMP=1 时保留并打印准确路径")
for name, prefix in TARGETS.items():
    sandbox = tempfile.mkdtemp(prefix="pdg-tmpguard-")
    try:
        rc, out = run(name, sandbox, "", keep=True)
        left = dirs_in(sandbox, prefix)
        printed = re.findall(r"\[PDG_KEEP_TMP\][^\n]*?(%s\S+)" % re.escape(prefix), out)
        (ok if left else bad)("%s / KEEP_TMP → 目录被保留(%d 个)" % (name, len(left)))
        (ok if printed and any(os.path.basename(p.rstrip("/")) in left or
                               any(l in p for l in left) for p in printed)
            else bad)("%s / KEEP_TMP → 打印了准确路径(%s)" % (name, printed[:1] or "无"))
    finally:
        subprocess.run(["rm", "-rf", sandbox])

head("3. 只清自己的, 不按宽前缀扫别人")
for name, prefix in TARGETS.items():
    sandbox = tempfile.mkdtemp(prefix="pdg-tmpguard-")
    try:
        # 放两个"别人的"目录: 同前缀但不是本进程建的, 以及完全无关的
        alien = os.path.join(sandbox, prefix + "someoneelse")
        other = os.path.join(sandbox, "unrelated-dir")
        os.makedirs(alien)
        os.makedirs(other)
        run(name, sandbox, "")
        (ok if os.path.isdir(alien) else bad)(
            "%s → 同前缀但非本进程建的目录未被误删" % name)
        (ok if os.path.isdir(other) else bad)("%s → 无关目录未被误删" % name)
    finally:
        subprocess.run(["rm", "-rf", sandbox])

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

#!/usr/bin/env python3
"""生命周期接线的负控: 逐个把 install/uninstall/doctor 的接线点拆掉,
证明 test-dot-lifecycle.py 会**新增一条点得出名字的失败**。

为什么要有: 那六条待办红灯刚刚转绿, 但"转绿"本身不说明判据有牙齿 —— 一条写宽了的
正则、一个恒真的 in 判断, 在接线正确的时候也是绿的。这支回答的是"如果哪天有人把
witness 从装机清单里摘掉, 我们会不会知道"。

外加一格**严重级别反向验证**: 把 doctor 里 witness 的 warn 改成 fail。witness 是旁路
观察端 —— 它挂了普通 DNS 一点不受影响(P0 隔离门实测两种故障下 UDP/TCP/DoT 各 9/9)。
把它升级成 fail, 等于让一个辅助件的故障把整台机器判成坏的。

改坏落在**工作副本**, 正式树一个字节不动。每格四步缺一不可: 锚点精确命中 → 摘要确实
变化 → 语法门通过 → 至少新增一条可点名失败, 且原有断言不减。
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
TOUCHED = ["install.sh", "uninstall.sh", "deploy/bot/checks.py"]
TEST = "tests/test-dot-lifecycle.py"

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


WCROOT = tmpguard.mkdtemp(prefix="pdg-lcnc-")
WC = os.path.join(WCROOT, "wc")
subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", REPO, WC], check=True)
head = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"],
                      capture_output=True, text=True).stdout.strip()
subprocess.run(["git", "-C", WC, "checkout", "-q", head], check=True)
for rel in TOUCHED + [TEST]:
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


print("── 基线: 接线完整时必须全绿 ──")
BASE_FAILS, BASE_OK, base_out = run_test()
if BASE_FAILS:
    bad("基线就红了(%d 条), 后面每一格都无从判断" % len(BASE_FAILS))
    print("\n".join("      " + x for x in BASE_FAILS[:3]))
    sys.exit(1)
if "Traceback" in base_out:
    bad("基线有 Traceback")
    sys.exit(1)
ok("基线绿: 通过 %d, 失败 0" % BASE_OK)


def cell(n, name, rel, old, new, want_name):
    """一格。want_name = 新增失败里必须出现的字串。"""
    path = os.path.join(WC, rel)
    src = open(path, encoding="utf-8").read()
    hits = src.count(old)
    if hits != 1:
        bad("LC-%d %s → 锚点命中 %d 次, 预期 1(改坏器没打在预期位置)" % (n, name, hits))
        restore()
        return
    before = sha(path)
    open(path, "w", encoding="utf-8").write(src.replace(old, new, 1))
    if sha(path) == before:
        bad("LC-%d %s → 摘要没变, mutation 没生效" % (n, name))
        restore()
        return
    # 语法门: shell 用 bash -n, Python 用 py_compile
    if rel.endswith(".sh"):
        g = subprocess.run(["bash", "-n", path], capture_output=True)
    else:
        g = subprocess.run([sys.executable, "-m", "py_compile", path], capture_output=True)
    if g.returncode != 0:
        bad("LC-%d %s → 改坏后语法不合法, 这格不算有效负控" % (n, name))
        restore()
        return
    fails, n_ok, out = run_test()
    added = [x for x in fails if x not in BASE_FAILS]
    if "Traceback" in out:
        bad("LC-%d %s → 出现 Traceback, 不算转红" % (n, name))
    elif n_ok + len(fails) < BASE_OK:
        bad("LC-%d %s → 断言总数从 %d 掉到 %d, 疑似提前退出"
            % (n, name, BASE_OK, n_ok + len(fails)))
    elif not added:
        bad("LC-%d %s → **没有新增失败**, 这条接线没有守卫" % (n, name))
    elif not any(want_name in x for x in added):
        bad("LC-%d %s → 转红但没点名 %r: %s" % (n, name, want_name, added[0][:70]))
    else:
        ok("LC-%d %-30s → 新增 %d 条: %s" % (n, name, len(added), added[0][7:75]))
    restore()
    if sha(path) != sha(os.path.join(REPO, rel)):
        bad("LC-%d %s → 恢复后摘要与正式树不一致" % (n, name))


print("\n── 七格接线 ──")
cell(1, "install unit 闭包删掉它", "install.sh",
     "pdg-bot.service pdg-probe81.service pdg-dotwitness.service mosdns.service",
     "pdg-bot.service pdg-probe81.service mosdns.service", "witness unit")
cell(2, "删掉 unit 安装行", "install.sh",
     'install -m644 "$REPO_DIR"/deploy/bot/pdg-dotwitness.service /etc/systemd/system/\n',
     "", "witness unit")
cell(3, "删掉 enable --now", "install.sh",
     'systemctl enable --now pdg-dotwitness >/dev/null 2>&1 \\\n'
     '  || die "pdg-dotwitness 未能启用 —— DoT 证据端不可用, 不把这次安装报成成功"\n',
     "", "enable witness")
cell(4, "uninstall 服务列表删掉", "uninstall.sh",
     "disable --now pdg-bot pdg-probe81 pdg-dotwitness mosdns",
     "disable --now pdg-bot pdg-probe81 mosdns", "disable --now")
cell(5, "uninstall unit 列表删掉", "uninstall.sh",
     "{pdg-bot,pdg-probe81,pdg-dotwitness,mosdns,",
     "{pdg-bot,pdg-probe81,mosdns,", "删 unit 文件")
cell(6, "删掉 doctor 的 DEEP 登记", "deploy/bot/checks.py",
     "check_deep_probe81, check_deep_dot_witness, check_deep_dns_cn,",
     "check_deep_probe81, check_deep_dns_cn,", "登记进 DEEP")
# 第 7 格: 把 witness 塞进关键 DNS 服务集。这是整套里最不该发生的一种退化 ——
# 那个集合决定"普通 DNS 算不算坏", 放进去等于让旁路件的故障把整台机器判成坏的。
cell(7, "witness 塞进 expected_services", "deploy/bot/checks.py",
     '    names = ["mosdns", svc, "pdg-probe81"]',
     '    names = ["mosdns", svc, "pdg-probe81", "pdg-dotwitness"]',
     "expected_services")

print("\n── 反向格: 严重级别从 warn 升成 fail ──")
# witness 是旁路观察端。它的异常用 warn 而不是 fail, 是因为普通 DNS 完全不受影响。
# 升成 fail 等于把一次诊断辅助件的故障说成"这台机器的 DNS 坏了"。
chk = os.path.join(WC, "deploy/bot/checks.py")
src = open(chk, encoding="utf-8").read()
warns = re.findall(r'return \("warn", "DoT 证据端"', src)
if len(warns) < 3:
    bad("反向格 → checks.py 里 witness 的 warn 分支只有 %d 处, 少于预期" % len(warns))
else:
    open(chk, "w", encoding="utf-8").write(
        src.replace('return ("warn", "DoT 证据端"', 'return ("fail", "DoT 证据端"'))
    g = subprocess.run([sys.executable, "-m", "py_compile", chk], capture_output=True)
    if g.returncode != 0:
        bad("反向格 → 改坏后语法不合法")
    else:
        fails, n_ok, out = run_test()
        added = [x for x in fails if x not in BASE_FAILS]
        if added:
            ok("反向格 warn→fail(%d 处) → 新增 %d 条: %s" % (len(warns), len(added), added[0][7:70]))
        else:
            bad("反向格 warn→fail(%d 处) → **没有守卫抓住** —— "
                "旁路件被升级成关键故障不会被任何测试发现" % len(warns))
    restore()

print("\n── 收尾 ──")
for rel in TOUCHED:
    (ok if sha(os.path.join(REPO, rel)) == BASE_SHA[rel] else bad)("正式树 %s 逐字节一致" % rel)
dirty = subprocess.run(["git", "-C", WC, "status", "--short"],
                       capture_output=True, text=True).stdout.strip()
(ok if not dirty else bad)("工作副本 git status 干净%s" % ("" if not dirty else ": " + dirty[:60]))
shutil.rmtree(WCROOT, ignore_errors=True)

print("\n" + "─" * 62)
print("有效 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

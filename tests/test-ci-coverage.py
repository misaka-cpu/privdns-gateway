#!/usr/bin/env python3
"""CI 覆盖守卫: 每个测试文件都必须真的被 workflow 调用。

为什么需要它: 本轮盘点发现 6 个测试文件从来没进过 CI —— 其中 4 个是 5.2 这一路新写的。
它们在本地跑得好好的, 谁也没注意到远端根本没跑。测试不进 CI 等于没有: 改坏了不会有人知道,
而"本地跑过"这件事不会随代码一起留下来。

这条守卫只认**文件名出现在 workflow 里**这一个事实。它防不住"步骤被注释掉"之类的花样,
但能挡住最常见也最容易发生的那一种: 新写了用例、忘了登记。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CI = os.path.join(ROOT, ".github/workflows/ci.yml")

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


# 这些不是用例, 是被用例 import 的夹具/工具 —— 它们的覆盖来自调用它们的用例。
HELPERS = {
    "rescuebox.py", "rescueform.py", "snapmatrix.py", "txbox.py", "mihomobin.py",
    "mock_dns.py", "mock_socks.py", "sni_client.py", "e2e-lib.sh", "prepare-mihomo.sh",
    "prepare-mosdns.sh", "update_invariants.py",
}

if not os.path.exists(CI):
    bad("找不到 .github/workflows/ci.yml")
    print("\n断言 1 项: 通过 0, 失败 1")
    sys.exit(1)

ci = open(CI, encoding="utf-8").read()

files = sorted(f for f in os.listdir(HERE)
               if (f.startswith("test-") or f.startswith("e2e-") or f == "functional-test.sh"
                   or f.startswith("dns-policy"))
               and (f.endswith(".py") or f.endswith(".sh")))
files = [f for f in files if f not in HELPERS]

print("== 1. 每个测试文件都要出现在 workflow 里 ==")
missing = [f for f in files if f not in ci]
if not missing:
    ok("%d 个测试文件全部被 ci.yml 引用" % len(files))
else:
    bad("这些测试文件没进 CI(写了等于没写): %s" % "、".join(missing))

print("\n== 2. 关键测试必须在名单里 ==")
# 点名的是本轮及 5.2 全程新增/改动最大的那些。它们要是掉出 CI, 上面那条也会红, 但点名能让
# 失败信息直接说清是哪一块没了覆盖, 而不是丢一串文件名。
KEY = {
    "事务核心": "test-config-transaction.py",
    "事务故障注入": "test-config-transaction-faults.py",
    "事务恢复": "test-rescue-recover.py",
    "救援生命周期": "test-rescue-lifecycle.sh",
    "救援来源过滤": "test-rescue-source.py",
    "救援表单闭环": "test-rescue-formflow.py",
    "资源与中断": "test-rescue-interrupt.py",
    "卸载保留用户防火墙": "test-uninstall-firewall.py",
    "重装保留用户数据": "test-reinstall-preserve.py",
    "跨版本快照矩阵": "test-snapshot-matrix.py",
    "安装闭包": "test-install-closure.py",
    "Mihomo 渲染与钉版": "test-rescue-sets.py",
}
gone = [k for k, f in KEY.items() if f not in ci]
if not gone:
    ok("%d 项关键测试均在 CI 名单内" % len(KEY))
else:
    bad("关键测试掉出 CI: %s" % "、".join(gone))

print("\n== 3. 严格模式与钉死内核 ==")
if re.search(r"PDG_TEST_STRICT:\s*[\"']?1", ci):
    ok("workflow 开了 PDG_TEST_STRICT=1(缺关键能力判失败, 不许 SKIP 冒充通过)")
else:
    bad("workflow 没开 PDG_TEST_STRICT —— 缺 mihomo/nft 时会 SKIP 成绿")
if "prepare-mihomo.sh" in ci:
    ok("workflow 会准备钉死版 Mihomo")
else:
    bad("workflow 没有准备 Mihomo 的步骤")
# mosdns 同样是硬前提: 事务的候选校验会真启动它。少了这一步, 需要真 mosdns 的用例会在
# CI 上整片失败, 而本地因为有残留二进制照样全绿 —— v1.7.0 的第一次真实 CI 就是这么红的。
if "prepare-mosdns.sh" in ci:
    ok("workflow 会准备钉死版 mosdns")
else:
    bad("workflow 没有准备 mosdns 的步骤 —— 需要真 mosdns 的事务用例会在 CI 上失败")

print("\n== 4. 需要 root/nft 的测试必须拿到 root ==")
# 拿 root 有两条路: 容器 job 里本来就是 root, 或者在 runner 上 `sudo -E`(GitHub 的 ubuntu
# runner 免密 sudo, 项目里 e2e-rescue-10b.sh 一直是这么跑的)。没拿到 root 的话, nft 那几条
# 会 SKIP —— 而 CI 里 SKIP 不算通过。
ROOT_TESTS = ("test-uninstall-firewall.py",)
blocks = re.split(r"\n  (?=[a-z0-9-]+:\n)", ci)
containered = "".join(b for b in blocks if "container:" in b)
notroot = []
for t in ROOT_TESTS:
    if t not in ci:
        continue
    if t in containered:
        continue
    if re.search(r"sudo -E[^\n]*" + re.escape(t), ci):
        continue
    notroot.append(t)
if not notroot:
    ok("%d 项需要 root/nft 的测试都能拿到 root(容器 job 或 sudo -E)" % len(ROOT_TESTS))
else:
    bad("这些测试需要 root 却没有 root: %s" % "、".join(notroot))

total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

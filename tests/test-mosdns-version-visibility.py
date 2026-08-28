#!/usr/bin/env python3
"""doctor 必须报出 mosdns 的版本, 并与钉死值对照。

现状: doctor 报 mihomo 版本, **不报 mosdns 的**。而这两个组件的处境完全不同 ——

  · mihomo 活跃维护, 版本随项目发布更新, 所以那条判据只报"读到了什么";
  · mosdns 近乎停摆(最后一次发布 2026-01-11, 最后一次提交 2026-02-27, 近 100 笔提交的
    时间跨度回到 2023-11)。它是这台机器上**唯一不能坏**的组件, 而上游已经没人在修了。

那么"现在跑的是不是钉死的那一版"就成了一个需要随时看得见的事实: 换核议题(见项目文档里
那四条触发条件)真被触发时, 第一件要问的就是它。

判据只做**对照**, 不做建议: 版本一致就报绿, 不一致就报出两边的值。它不会告诉你该升还是
该降 —— 那是人的决定, 而 mosdns 的版本恰恰不该被自动跟随。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy/bot"))

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


import checks                                                # noqa: E402

SRC = open(os.path.join(ROOT, "deploy/bot/checks.py"), encoding="utf-8").read()
VERS = open(os.path.join(ROOT, "lib/versions.sh"), encoding="utf-8").read()

print("══ 1. 判据存在, 且钉死值有单一真源 ══")
(ok if hasattr(checks, "check_mosdns_version") else
 bad)("checks.py 里有 check_mosdns_version")
m = re.search(r'^MOSDNS_VER="([^"]+)"', VERS, re.M)
(ok if m else bad)("lib/versions.sh 里有 MOSDNS_VER(实得 %r)" % (m.group(1) if m else None))
# **不许在 checks.py 里再写一份版本号** —— 两处手写必然漂, 而漂掉的表现是判据报绿而实际不符
(ok if m and ('"%s"' % m.group(1)) not in SRC else
 bad)("checks.py 里没有硬编码的版本号(它要从 lib/versions.sh 读)")

print()
print("══ 2. 真跑判据 ══")
if hasattr(checks, "check_mosdns_version"):
    _run = checks._run

    def stub(seq):
        def f(cmd, *a, **k):
            if cmd and "mosdns" in cmd[0]:
                return seq
            return _run(cmd, *a, **k)
        return f

    pinned = m.group(1) if m else "v5.3.4"
    # ① 版本一致 → ok
    checks._run = stub((0, "mosdns %s-0-gb732318\n" % pinned, ""))
    r = checks.check_mosdns_version()
    (ok if r and r[0] == "ok" else bad)("版本与钉死值一致时判绿(实得 %r)" % (r,))
    (ok if r and pinned in r[2] else bad)("绿的时候把版本号说出来(实得 %r)" % (r[2] if r else None,))

    # ② 版本不符 → warn, 且**两个值都要报出来**
    checks._run = stub((0, "mosdns v9.9.9-0-gdeadbee\n", ""))
    r2 = checks.check_mosdns_version()
    (ok if r2 and r2[0] == "warn" else bad)("版本不符时判黄(实得 %r)" % (r2,))
    (ok if r2 and "v9.9.9" in r2[2] and pinned in r2[2] else
     bad)("不符时把**两边**的值都报出来, 否则不知道该看哪个(实得 %r)" % (r2[2] if r2 else None,))

    # ③ 读不到版本 → warn + 明说无结论, 不能判绿
    checks._run = stub((1, "", "command not found"))
    r3 = checks.check_mosdns_version()
    (ok if r3 and r3[0] != "ok" else
     bad)("读不到版本时不判绿 —— 那不是「没问题」, 是「不知道」(实得 %r)" % (r3,))

    # ④ 子串不能算命中: 期望 v5.3.4 时跑着 v5.3.40 必须判不符
    checks._run = stub((0, "mosdns %s0-0-gx\n" % pinned, ""))
    r4 = checks.check_mosdns_version()
    (ok if r4 and r4[0] != "ok" else
     bad)("%s0 不能被当成 %s(子串判断的老坑, 见 test-version-match)(实得 %r)"
          % (pinned, pinned, r4))

    checks._run = _run

print()
print("══ 3. 判据只对照, 不替人做决定 ══")
# mosdns 的版本**不该被自动跟随** —— 上游停摆, 换不换是人的判断。判据里不许出现"请升级"
# 这类话, 否则它会把一个需要权衡的决定说成一条例行操作。
body = re.search(r"def check_mosdns_version\(.*?\n(?=\ndef |\n# )", SRC, re.S)
(ok if body else bad)("抽得到函数体")
if body:
    b = body.group(0)
    bads = [w for w in ("请升级", "建议升级", "自动更新", "apt", "curl") if w in b]
    (ok if not bads else bad)("判据里没有「去升级」这类建议(实得 %r)" % bads)

print()
print("══ 4. 接进 doctor 的清单 ══")
(ok if "check_mosdns_version" in SRC.split("def check_mosdns_version")[0] or
       SRC.count("check_mosdns_version") >= 2 else
 bad)("check_mosdns_version 被登记进判据清单(不登记就永远不会跑)")

print("-" * 62)
print("test-mosdns-version-visibility.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

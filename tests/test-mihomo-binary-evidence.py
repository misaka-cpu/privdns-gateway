#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doctor 对 mihomo 的两条判据必须**分开**说, 而且都不许"能解析就绿"。

修之前 check_core_version 是三重假绿, 三层都实测复现过:
  · 它跑 PATH 上的 `mihomo`, 而 systemd 执行的是 /usr/local/bin/mihomo;
  · 对**任何**能解析出来的版本都返回 ok, 文案还写"版本随项目发布更新" —— v0.0.1 也绿;
  · 吞掉退出码: 命令非零但输出里带个版本号照样绿。

现在分成两条, 措辞必须能区分"自报版本"与"文件内容摘要":
  check_core_version   —— 绝对路径 + 退出码 + 自报版本精确相等
  check_mihomo_binary  —— 该文件内容的 SHA256 等于该架构的钉值
四态: 缺失/版本不符/摘要不符 → fail; 架构未知或读不到钉值 → warn 且明说无结论; 全中 → ok。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import checks  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   %s" % m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] %s" % m)
    FAIL[0] += 1


import tempfile  # noqa: E402

WORK = tempfile.mkdtemp(prefix="pdg-mihev.")
PIN_VER = checks._pinned_mihomo_ver()


def mk(path, ver, marker, rc=0):
    with open(path, "w", encoding="utf-8") as f:
        f.write('#!/bin/sh\n# %s\ncase "$1" in -v) echo "Mihomo Meta %s linux amd64";; esac\nexit %d\n'
                % (marker, ver, rc))
    os.chmod(path, 0o755)


def sha_of(p):
    import hashlib
    h = hashlib.sha256()
    with open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


print("══ 0. 判据存在且登记进 ALL ══")
(ok if hasattr(checks, "check_mihomo_binary") else bad)("checks.py 里有 check_mihomo_binary")
names = [f.__name__ for f in checks.ALL]
(ok if "check_mihomo_binary" in names else bad)("check_mihomo_binary 登记进了 ALL(不登记就永远不会跑)")
(ok if "check_core_version" in names else bad)("check_core_version 仍在 ALL 里")
(ok if PIN_VER else bad)("从 lib/versions.sh 读到 MIHOMO_VER=%s" % (PIN_VER or "<空>"))

print()
print("══ 1. 判据钉在 systemd 真正执行的绝对路径上 ══")
(ok if getattr(checks, "MIHOMO_BIN", "") == "/usr/local/bin/mihomo" else
 bad)("MIHOMO_BIN = /usr/local/bin/mihomo(不是 PATH 上随便哪个 mihomo)")
src = open(os.path.join(ROOT, "deploy/bot/checks.py"), encoding="utf-8").read()
seg = src[src.index("def check_core_version"):src.index("def _pinned_mihomo_ver")]
(bad if '_run(["mihomo"' in seg else ok)("check_core_version 不再用裸 `mihomo`(那问的是 PATH)")

print()
print("══ 2. check_core_version 四态 ══")
good = os.path.join(WORK, "good")
mk(good, PIN_VER, "OFFICIAL")
cases = [
    ("自报版本精确相等",          lambda: (mk(good, PIN_VER, "X"), good)[1],   "ok"),
    ("自报旧版 v1.19.29",         lambda: (mk(good, "v1.19.29", "X"), good)[1], "fail"),
    ("自报 v0.0.1(以前也绿)",     lambda: (mk(good, "v0.0.1", "X"), good)[1],  "fail"),
    ("退出码非零但输出有版本号",   lambda: (mk(good, PIN_VER, "X", 3), good)[1], "fail"),
    ("绝对路径文件不存在",        lambda: os.path.join(WORK, "nosuch"),        "fail"),
]
for name, setup, want in cases:
    p = setup()
    lvl, chk, detail = checks.check_core_version(_bin=p)
    if lvl == want:
        ok("[%s] → %s(%s)" % (name, lvl, detail[:52]))
    else:
        bad("[%s] 期望 %s, 实得 %s: %s" % (name, want, lvl, detail))
lvl, _, detail = checks.check_core_version(_bin=good, _pin="")
(ok if lvl == "warn" and "无结论" in detail else
 bad)("[读不到钉死版本] → warn 且明说无结论(实得 %s: %s)" % (lvl, detail))

print()
print("══ 3. check_mihomo_binary 四态 ══")
mk(good, PIN_VER, "OFFICIAL")
GOOD_SHA = sha_of(good)
drift = os.path.join(WORK, "drift")
mk(drift, PIN_VER, "DRIFTED-CONTENT")
lvl, _, d = checks.check_mihomo_binary(_bin=good, _pin=GOOD_SHA, _arch="amd64")
(ok if lvl == "ok" else bad)("[内容与钉值一致] → ok(实得 %s)" % lvl)
lvl, _, d = checks.check_mihomo_binary(_bin=drift, _pin=GOOD_SHA, _arch="amd64")
(ok if lvl == "fail" else bad)("[同版本、内容不符] → fail(实得 %s)" % lvl)
(ok if "内容" in d else bad)("[同版本、内容不符] 文案点明是**内容**不符: %s" % d[:56])
lvl, _, d = checks.check_mihomo_binary(_bin=os.path.join(WORK, "nosuch"), _pin=GOOD_SHA, _arch="amd64")
(ok if lvl == "fail" else bad)("[文件不存在] → fail(实得 %s)" % lvl)
lvl, _, d = checks.check_mihomo_binary(_bin=good, _arch="riscv64")
(ok if lvl == "warn" and "无结论" in d else
 bad)("[未知架构] → warn 且明说无结论(实得 %s: %s)" % (lvl, d))
lvl, _, d = checks.check_mihomo_binary(_bin=good, _pin="", _arch="amd64")
(ok if lvl == "warn" and "无结论" in d else
 bad)("[读不到钉值] → warn 且明说无结论(实得 %s: %s)" % (lvl, d))

print()
print("══ 4. 两条判据的措辞必须能区分「自报版本」与「文件内容」 ══")
mk(good, PIN_VER, "OFFICIAL")
_, _, dv = checks.check_core_version(_bin=good)
_, _, db = checks.check_mihomo_binary(_bin=good, _pin=sha_of(good), _arch="amd64")
(ok if "自报" in dv else bad)("版本判据的文案里出现「自报」: %s" % dv[:56])
(ok if ("内容" in db or "sha256" in db) else bad)("内容判据的文案里出现「内容/sha256」: %s" % db[:56])
(bad if "版本随项目发布更新" in dv else
 ok)("旧那句「版本随项目发布更新」已经不在(它对任何版本都绿)")

print()
print("══ 5. 真二进制端到端(有钉死版才跑, 没有则明确 SKIP 而不是冒充通过) ══")
REAL = os.environ.get("PDG_TEST_MIHOMO", "")
if REAL and os.path.exists(REAL):
    lvl, _, d = checks.check_core_version(_bin=REAL)
    (ok if lvl == "ok" else bad)("真 %s 二进制 → 版本判据 ok(实得 %s: %s)" % (PIN_VER, lvl, d[:40]))
    lvl, _, d = checks.check_mihomo_binary(_bin=REAL, _arch="amd64")
    (ok if lvl == "ok" else bad)("真 %s 二进制 → 内容判据 ok(实得 %s: %s)" % (PIN_VER, lvl, d[:40]))
else:
    print("[SKIP] 没有真 mihomo(设 PDG_TEST_MIHOMO=<路径> 可跑这一节) —— 这是未验, 不是通过")

print("-" * 62)
print("test-mihomo-binary-evidence.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""来源网段证据能不能在**真实的 DynamicUser 边界**上产生。

`.153` 真机验收时发现的 P0: pdg-probe81 以 DynamicUser 跑, 而 profile.env 是 0600 root:root、
所在目录 0700 root:root —— 动态用户读不到它。linksess._profile() 里的 `except OSError: pass`
把 PermissionError 静默吞掉返回空串, 于是 inside_internal_cidr() 只能返回 None, 6.1C 两条
证据里的第二条(来源在不在内网卡段)在真机上**永远产不出来**。

沙箱之前一次都没碰到这条边界: 所有测试都以同一个用户跑、文件可读。同一个 uid 下怎么测都是
空转 —— root 建的文件当然 root 自己读得到。所以判据只能落在**真的换 UID**上, 这支测试把
tests/linksess_profile_uid_probe.py 以 root 调起, 由它 fork + setuid 后走 probe81 的同一个
入口 consume()。

拿不到 root(也没有免密 sudo)时明确 SKIP —— 不能把"没验"说成"通过"。CI 是 root 容器,
PDG_TEST_STRICT=1 下 SKIP 直接判失败。
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


STRICT = bool(os.environ.get("PDG_TEST_STRICT")) or os.environ.get("CI") == "true"

probe = ROOT / "tests" / "linksess_profile_uid_probe.py"
cmd = [sys.executable, str(probe)]
if os.geteuid() != 0:
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0:
        cmd = ["sudo", "-n", "-E"] + cmd
    else:
        cmd = None

if cmd is None:
    msg = "非 root 且没有免密 sudo —— 双 UID 边界未验证(不是通过)"
    if STRICT:
        bad(msg + " —— 严格模式判失败")
    else:
        print("[SKIP] " + msg)
    print("──────────────────────────────────────────────")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)

r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
seen_skip = False
for line in (r.stdout or "").splitlines():
    if line.startswith("[OK]"):
        ok(line.split("] ", 1)[-1].strip())
    elif line.startswith("[FAIL]"):
        bad(line.split("] ", 1)[-1].strip())
    elif line.startswith("[SKIP]"):
        seen_skip = True
        msg = line.split("] ", 1)[-1].strip()
        if STRICT:
            bad(msg + " —— 严格模式判失败")
        else:
            print("[SKIP] " + msg)
    elif line.startswith("[PROBE]"):
        print("  " + line)
if r.returncode != 0 and not FAIL[0]:
    bad("探针退出码 %d 但没报出具体失败: %s" % (r.returncode, (r.stderr or "")[-200:]))
if not PASS[0] and not FAIL[0] and not seen_skip:
    bad("探针零断言 —— 判失败")

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

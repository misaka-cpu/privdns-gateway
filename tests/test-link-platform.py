#!/usr/bin/env python3
"""6.1A 的平台隔离: Android 不许被要求有 probe81, iOS 不许看到 Android 专属步骤。

这条容易被写反, 所以判据说清楚: `pdg-probe81` / 端口 81 / probe81.py 是 **iOS 专属**
(lib/modules.sh 的 PDG_IOS_MODULES 里列着, nft 模板里 81 也只对内网卡段开)。Android 上
它根本不装、不监听、也不放行 —— 那不是"缺失", 而是**不适用**。把它判成 FAIL 会让 Android
用户去修一个本来就不该存在的东西。
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
import linkstat as L  # noqa: E402

PASS_N = [0]
FAIL_N = [0]


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def by_layer(fs, layer):
    return [f for f in fs if f["layer"] == layer]


print("── 1. 事实核对: probe81 确实是 iOS 专属 ──")
mods = (ROOT / "lib/modules.sh").read_text(encoding="utf-8")
ios_block = mods.split("PDG_IOS_MODULES=")[1] if "PDG_IOS_MODULES=" in mods else ""
rt_block = mods.split("PDG_RUNTIME_MODULES=")[1].split("PDG_IOS_MODULES=")[0] \
    if "PDG_RUNTIME_MODULES=" in mods else ""
if "probe81.py" in ios_block and "probe81.py" not in rt_block:
    ok("probe81.py 只在 PDG_IOS_MODULES 里, 不在通用运行模块里")
else:
    bad("probe81.py 的归属不对(iOS 块=%s, 通用块=%s)"
        % ("probe81.py" in ios_block, "probe81.py" in rt_block))

print()
print("── 2. Android: 第 3 层必须 SKIP, 不能报缺失 ──")
fa = L.collect(platform="android")
l3 = by_layer(fa, 3)
if len(l3) == 1 and l3[0]["status"] == L.SKIP and l3[0]["code"] == "L3_PLATFORM_NA":
    ok("Android 的第 3 层是 SKIP / L3_PLATFORM_NA")
else:
    bad("Android 第 3 层不对: %r" % [(f["status"], f["code"]) for f in l3])
if l3 and l3[0]["platform"] == "android":
    ok("该条目标注 platform=android")
else:
    bad("平台标注不对: %r" % (l3[0]["platform"] if l3 else None))
# 最要紧的一条: Android 不许因为没有 probe81 而出现任何 FAIL
android_fails = [f["code"] for f in fa if f["status"] == L.FAIL and f["layer"] == 3]
if not android_fails:
    ok("**Android 不会因为没有 probe81 而判 FAIL**")
else:
    bad("Android 竟然因 probe81 判了 FAIL: %r" % android_fails)
if L.exit_code([f for f in fa if f["layer"] == 3]) == 0:
    ok("Android 的第 3 层不影响退出码")
else:
    bad("Android 第 3 层拖累了退出码")

print()
print("── 3. iOS: 第 3 层要真去检查服务器就绪 ──")
fi = L.collect(platform="ios")
l3i = by_layer(fi, 3)
if len(l3i) == 1 and l3i[0]["code"] in ("L3_SERVER_PROBE_READY",):
    ok("iOS 的第 3 层给出 L3_SERVER_PROBE_READY(PASS 或 FAIL 取决于本机是否真起了)")
else:
    bad("iOS 第 3 层不对: %r" % [(f["status"], f["code"]) for f in l3i])
if l3i and l3i[0]["platform"] == "ios":
    ok("该条目标注 platform=ios")
else:
    bad("平台标注不对")
if l3i and l3i[0]["status"] != L.SKIP:
    ok("iOS 不跳过这一层(它是 iOS 的真实依赖)")
else:
    bad("iOS 竟然跳过了 probe81 检查")
# 文案必须自己划清界限: 本机 200 不等于手机连得上
if l3i and l3i[0]["status"] == L.PASS:
    if "不" in l3i[0]["detail"] and "手机" in l3i[0]["detail"]:
        ok("iOS PASS 的文案明说了「不代表手机连得上」")
    else:
        bad("iOS PASS 文案没划清界限: %s" % l3i[0]["detail"])

print()
print("── 4. 文案不串台 ──")
ta = L.render_text(fa)
ti = L.render_text(fi)
# Android 的输出里不该出现 iOS 专属名词的"要求"语气; iOS 的输出里不该出现 GMS
if "OnDemand" not in ta and "描述文件" not in ta:
    ok("Android 输出里没有 iOS 专属步骤(OnDemand / 描述文件)")
else:
    bad("Android 输出串台了")
if "GMS" not in ti and "5228" not in ti:
    ok("iOS 输出里没有 Android 专属内容(GMS / 5228-5230)")
else:
    bad("iOS 输出串台了")
if "81" in ti:
    ok("iOS 输出提到 :81(它对 iOS 是真实依赖)")
else:
    bad("iOS 输出没提 :81")

print()
print("── 5. 两个平台的层级集合一致(只有第 3 层的处置不同) ──")
la = sorted({f["layer"] for f in fa})
li = sorted({f["layer"] for f in fi})
if la == li:
    ok("两平台覆盖同样的层: %s" % la)
else:
    bad("层级集合不一致: android=%s ios=%s" % (la, li))
# 有的层(5 证书 / 8 服务+nft)会返回**多条** finding, 所以要比"每层的 code 多重集合",
# 不能拿 next() 取第一条比 —— 那样多条时比的是谁完全看顺序, 会假红。
def codes_by_layer(fs):
    m = {}
    for f in fs:
        m.setdefault(f["layer"], []).append(f["code"])
    return {k: sorted(v) for k, v in m.items()}

ca, ci = codes_by_layer(fa), codes_by_layer(fi)
diff = {k for k in set(ca) | set(ci) if ca.get(k) != ci.get(k)}
if diff <= {3}:
    ok("两平台唯一的处置差异就在第 3 层(逐层比 code 多重集合)")
else:
    bad("除第 3 层外还有差异: %s(android=%s ios=%s)"
        % (sorted(diff), {k: ca.get(k) for k in diff}, {k: ci.get(k) for k in diff}))

print("─" * 40)
total = PASS_N[0] + FAIL_N[0]
print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL_N[0] else 0)

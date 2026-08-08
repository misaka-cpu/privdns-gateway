#!/usr/bin/env python3
"""链路诊断的平台隔离: iOS 不许看到 Android 专属步骤, 反之亦然。

历史: 6.1A 时 `pdg-probe81` / 端口 81 / probe81.py 是 **iOS 专属**, 这支测试原本守着
"Android 不装 = 正确"。6.1B 把它改成 Android/iOS **公共组件**(两平台都装、都起, nft
模板里 81 本来就只有一份、对内网卡段放行)。所以本文件里凡涉及 probe81 归属的判据都
按新事实翻了面 —— 翻面, 不是删除。

仍然成立的部分: 平台专属的东西(iOS 的描述文件/OnDemand、Android 的 GMS 5228-5230)
不许串台。
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


print("── 1. 事实核对: probe81 是 Android/iOS 公共组件(6.1B 起) ──")
mods = (ROOT / "lib/modules.sh").read_text(encoding="utf-8")
ios_block = mods.split("PDG_IOS_MODULES=")[1] if "PDG_IOS_MODULES=" in mods else ""
rt_block = mods.split("PDG_RUNTIME_MODULES=")[1].split("PDG_IOS_MODULES=")[0] \
    if "PDG_RUNTIME_MODULES=" in mods else ""
# 6.1A 时这里断言的是"只在 PDG_IOS_MODULES 里"。6.1B 把 probe81 变成公共件之后,
# 那条断言的**事实前提**没了 —— 翻面而不是删掉: 现在要求它在通用运行模块里, 且不许
# 同时留在 iOS 块(留着会让 iOS 装两遍)。
if "probe81.py" in rt_block and "probe81.py" not in ios_block:
    ok("probe81.py 在 PDG_RUNTIME_MODULES 里, 且没重复留在 iOS 块")
else:
    bad("probe81.py 的归属不对(通用块=%s, iOS 块=%s)"
        % ("probe81.py" in rt_block, "probe81.py" in ios_block))

print()
print("── 2. 第 3 层: probe81 已是两平台公共件, 判据不再按平台分岔 ──")
# 契约变更备案(勿改回去): 6.1A 时 probe81 是 iOS 专属, 所以第 3 层在 Android 上 SKIP。
# **6.1B 把它转成了 Android/iOS 公共组件** —— 手机链路测试的 HTTP 探测端点两平台都用它。
# 旧断言("Android 第 3 层必须 SKIP / L3_PLATFORM_NA")因此不再成立, 而且它在 `.153` 真机上
# 直接造成了误导: 同一台机器 probe81 active、:81 在听、nft 有放行、curl 200、doctor 报绿,
# linkstat 却说"Android 不安装 pdg-probe81, 也不监听/放行 81"。判据现在两平台同形。
_orig_run = L.checks._run


def _with_probe(code):
    """把 curl 探测端点这一步换成给定的 HTTP 码, 其余命令交回真实现。"""
    def _r(cmd, t=10):
        if cmd and cmd[0] == "curl":
            return (0, code, "")
        return _orig_run(cmd, t)
    return _r


for _plat in ("android", "ios"):
    L.checks._run = _with_probe("200")
    try:
        _l3 = by_layer(L.collect(platform=_plat), 3)
    finally:
        L.checks._run = _orig_run
    if len(_l3) == 1 and _l3[0]["status"] == L.PASS and _l3[0]["code"] == "L3_SERVER_PROBE_READY":
        ok("%s: 端点返回 200 → PASS / L3_SERVER_PROBE_READY" % _plat)
    else:
        bad("%s 第 3 层不对: %r" % (_plat, [(f["status"], f["code"]) for f in _l3]))

for _plat in ("android", "ios"):
    L.checks._run = _with_probe("000")
    try:
        _l3 = by_layer(L.collect(platform=_plat), 3)
    finally:
        L.checks._run = _orig_run
    if _l3 and _l3[0]["status"] == L.FAIL:
        ok("%s: 端点不通 → FAIL(两平台同一判据, 不再有平台豁免)" % _plat)
    else:
        bad("%s 端点不通却没判 FAIL: %r" % (_plat, [(f["status"], f["code"]) for f in _l3]))

# 标题不再自称 iOS 专属
L.checks._run = _with_probe("200")
try:
    _t3 = by_layer(L.collect(platform="android"), 3)[0]["title"]
finally:
    L.checks._run = _orig_run
if "iOS" not in _t3:
    ok("第 3 层标题不再自称 iOS 专属(实得 %r)" % _t3)
else:
    bad("标题仍写着 iOS: %r" % _t3)

print()
print("── 3. iOS: 第 3 层要真去检查服务器就绪 ──")
fi = L.collect(platform="ios")
l3i = by_layer(fi, 3)
if len(l3i) == 1 and l3i[0]["code"] in ("L3_SERVER_PROBE_READY",):
    ok("iOS 的第 3 层给出 L3_SERVER_PROBE_READY(PASS 或 FAIL 取决于本机是否真起了)")
else:
    bad("iOS 第 3 层不对: %r" % [(f["status"], f["code"]) for f in l3i])
# 这一层 6.1B 起两平台公用, 所以不再标 platform=ios —— 标了反而会让渲染按平台过滤掉它
if l3i and l3i[0]["platform"] == "both":
    ok("该条目标注 platform=both(probe81 已是两平台公共件)")
else:
    bad("平台标注不对: %r" % (l3i[0]["platform"] if l3i else None))
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
fa = L.collect(platform="android")
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

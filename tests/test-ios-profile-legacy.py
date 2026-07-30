#!/usr/bin/env python3
"""v1.7.8 之前的 iOS 描述文件生成 —— **特征化测试**(characterization test)。

它不主张现状是对的, 只把现状**如实钉住**, 好让 5.4 的改动能被逐条对照:
  · 每次生成都是新的随机身份 → 对 iOS 来说每装一次都是"另一个描述文件";
  · Bot 与 CLI 各写一套: SSID 排除与 WLOC CA 只有 Bot 有;
  · 模板占位符只有四个, 其中两个就是那对随机 UUID。

这些断言在 5.4 推进过程中会**逐条被故意翻转** —— 翻转出现在本文件的 diff 里, 那就是"这次
改动改掉了哪一条现状"的证据。已经翻转的:
  · CLI 自己拼占位符 → 改调 iosprofile.py(收敛由 test-ios-profile-shared.py 逐字节验证)。
仍然成立的(受管生命周期启用后才会变):
  · 未启用受管生命周期时, Bot 每次生成仍是随机身份。
"""
import os
import plistlib
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# ── 1. 模板: 占位符与结构 ────────────────────────────────────────────────────
tmpl = open(TMPL, encoding="utf-8").read()
holes = sorted(set(re.findall(r"__[A-Z0-9_]+__", tmpl)))
if holes == ["__DOT_HOST__", "__JP_IP__", "__UUID1__", "__UUID2__"]:
    ok("模板占位符恰好是四个: %s" % ", ".join(holes))
else:
    bad("占位符变了: %r" % holes)

rendered = (tmpl.replace("__DOT_HOST__", "dot.example.com")
                .replace("__JP_IP__", "203.0.113.10")
                .replace("__UUID1__", "AAAAAAAA-0000-0000-0000-000000000001")
                .replace("__UUID2__", "AAAAAAAA-0000-0000-0000-000000000002"))
try:
    p = plistlib.loads(rendered.encode())
    ok("模板渲染后是合法 plist")
except Exception as e:  # noqa: BLE001
    bad("模板渲染后不是合法 plist: %s" % type(e).__name__)
    p = {}

if p.get("PayloadType") == "Configuration" and p.get("PayloadVersion") == 1:
    ok("顶层是 Configuration 且 PayloadVersion=1(Apple 规定值)")
else:
    bad("顶层结构不对: %r" % {k: p.get(k) for k in ("PayloadType", "PayloadVersion")})

dns = (p.get("PayloadContent") or [{}])[0]
if dns.get("PayloadType") == "com.apple.dnsSettings.managed" \
        and dns.get("DNSSettings", {}).get("DNSProtocol") == "TLS":
    ok("DNS payload 是 managed DoT")
else:
    bad("DNS payload 不对: %r" % dns.get("PayloadType"))

if "OnDemandRules" in dns and "OnDemandRules" not in dns.get("DNSSettings", {}):
    ok("OnDemandRules 与 DNSSettings 平级(不是嵌进去的)")
else:
    bad("OnDemandRules 位置不对")

rules = dns.get("OnDemandRules") or []
kinds = [(r.get("InterfaceTypeMatch"), r.get("Action")) for r in rules]
if kinds == [("WiFi", "Connect"), ("WiFi", "Disconnect"),
             ("Cellular", "Connect"), (None, "Disconnect")]:
    ok("OnDemand 四条规则顺序: WiFi 探测 → WiFi 断 → Cellular 探测 → 兜底断")
else:
    bad("OnDemand 规则顺序变了: %r" % kinds)

if p["PayloadIdentifier"].endswith("AAAAAAAA-0000-0000-0000-000000000002") \
        and dns["PayloadIdentifier"].endswith("AAAAAAAA-0000-0000-0000-000000000001"):
    ok("现状: 顶层与 DNS payload 的 Identifier **把 UUID 拼在里面**(所以身份随 UUID 变)")
else:
    bad("Identifier 形态与预期不符")

# ── 2. Bot 侧: 每次生成都是新身份 ───────────────────────────────────────────
BOT_SNIPPET = r'''
import os, sys, plistlib, uuid, json
sys.path.insert(0, %(bot_dir)r)
os.environ.setdefault("PDG_BOT_TOKEN", "x")
# 只取 _ios_profile 需要的那几样, 不启动 bot 主循环
import importlib.util
spec = importlib.util.spec_from_file_location("botmod", %(bot_py)r)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
m.IOS_TMPL = %(tmpl)r
m._platform = lambda: "ios"
m._dot_host = lambda: "dot.example.com"
m._server_ip = lambda: "203.0.113.10"
m._mitm_enabled_domains = lambda: %(wloc)s
m._mitm_ca_der = lambda: %(der)r
out = []
for _ in range(2):
    out.append(m._ios_profile(%(ssids)s))
sys.stdout.buffer.write(b"---SPLIT---".join(out))
'''


def bot_profile(ssids="()", wloc="[]", der=b""):
    code = BOT_SNIPPET % {"bot_dir": os.path.join(ROOT, "deploy/bot"),
                          "bot_py": os.path.join(ROOT, "deploy/bot/pdg-bot.py"),
                          "tmpl": TMPL, "ssids": ssids, "wloc": wloc, "der": der}
    p = subprocess.run([sys.executable, "-c", code], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, timeout=180)
    if p.returncode != 0:
        return None, p.stderr.decode("utf-8", "replace")[-400:]
    return p.stdout.split(b"---SPLIT---"), ""


outs, err = bot_profile()
if outs is None:
    bad("Bot 侧生成失败: %s" % err)
else:
    a, b = outs[0], outs[1]
    if a != b:
        ok("现状(Bot): 同样输入连生成两次, 文件**不一样** —— 每次都是新身份")
    else:
        bad("Bot 两次生成竟然一致(现状应当是随机的)")
    pa, pb = plistlib.loads(a), plistlib.loads(b)
    if pa["PayloadUUID"] != pb["PayloadUUID"]:
        ok("现状(Bot): 顶层 PayloadUUID 每次都变(%s… → %s…)"
           % (pa["PayloadUUID"][:8], pb["PayloadUUID"][:8]))
    else:
        bad("顶层 UUID 没变")
    if pa["PayloadIdentifier"] != pb["PayloadIdentifier"]:
        ok("现状(Bot): 顶层 PayloadIdentifier 每次都变 → iOS 视为两个不同的描述文件")
    else:
        bad("顶层 Identifier 没变")

# ── 3. Bot 侧: SSID 排除与 WLOC CA(CLI 没有这两样)────────────────────────
outs, err = bot_profile(ssids="('MyWiFi',)")
if outs:
    p0 = plistlib.loads(outs[0])
    r0 = p0["PayloadContent"][0]["OnDemandRules"][0]
    if r0.get("SSIDMatch") == ["MyWiFi"] and r0.get("Action") == "Disconnect":
        ok("现状(Bot): SSID 排除插在 OnDemandRules 最前面")
    else:
        bad("SSID 规则不对: %r" % r0)
else:
    bad("SSID 用例生成失败: %s" % err)

FAKE_DER = b"\x30\x82\x01\x0a\xfake-ca-der-bytes"
outs, err = bot_profile(wloc="['x.example']", der=FAKE_DER)
if outs:
    p0 = plistlib.loads(outs[0])
    cas = [x for x in p0["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
    if len(cas) == 1 and cas[0]["PayloadContent"] == FAKE_DER:
        ok("现状(Bot): WLOC 启用时附上 root CA payload(DER 原文)")
    else:
        bad("CA payload 不对: %d 个" % len(cas))
    if cas and cas[0].get("PayloadIdentifier") == "com.privdns.mitm.ca":
        ok("现状(Bot): CA payload 的 Identifier 是固定值, 但 UUID 仍是随机的")
    else:
        bad("CA identifier 变了")
else:
    bad("WLOC 用例生成失败: %s" % err)

outs, err = bot_profile(wloc="[]", der=FAKE_DER)
if outs and not [x for x in plistlib.loads(outs[0])["PayloadContent"]
                 if x.get("PayloadType") == "com.apple.security.root"]:
    ok("现状(Bot): WLOC 未启用时不带 CA payload")
else:
    bad("WLOC 关闭却带了 CA")

# ── 4. CLI 侧 ──────────────────────────────────────────────────────────────
# v1.7.8 这里是 `sed` 换四个占位符, 既不支持 SSID 排除也不附 WLOC 根证书。收敛到统一生成器
# 之后这两条断言翻转了(收敛本身由 test-ios-profile-shared.py 逐字节验证), 留下的是临时下载
# 通道那部分 —— 那是 CLI 独有的, 不该被这次重构动到。
pdg_sh = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
m = re.search(r"^cmd_ios\(\)\{.*?^\}", pdg_sh, re.S | re.M)
cli = m.group(0) if m else ""
if "iosstate.py" in cli and "__UUID" not in cli and "random/uuid" not in cli:
    ok("CLI 不再自己拼占位符/自取随机 UUID, 改调 iosstate.py(与 Bot 同一份实现与记录)")
else:
    bad("CLI 仍在自己生成描述文件")
if "python3 -m http.server" in cli and "nft insert rule" in cli:
    ok("现状(CLI): 临时 HTTP + 临时 nft 放行, 退出时 nft -f 还原")
else:
    bad("CLI 的临时下载通道形态变了")

# ── 5. 平台门控(现状) ─────────────────────────────────────────────────────
BOT_GATE = r'''
import os, sys, importlib.util
sys.path.insert(0, %(bot_dir)r)
os.environ.setdefault("PDG_BOT_TOKEN", "x")
spec = importlib.util.spec_from_file_location("botmod", %(bot_py)r)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
m.IOS_TMPL = %(tmpl)r
m._platform = lambda: "android"
try:
    m._ios_profile()
    print("NO-RAISE")
except Exception as e:
    print("RAISED", type(e).__name__)
''' % {"bot_dir": os.path.join(ROOT, "deploy/bot"),
       "bot_py": os.path.join(ROOT, "deploy/bot/pdg-bot.py"), "tmpl": TMPL}
p = subprocess.run([sys.executable, "-c", BOT_GATE], stdout=subprocess.PIPE,
                   stderr=subprocess.DEVNULL, timeout=180, universal_newlines=True)
if p.stdout.strip().startswith("RAISED"):
    ok("现状: Android 平台调 _ios_profile 直接抛错(最底层门控)")
else:
    bad("Android 上竟然生成了 iOS 描述文件: %r" % p.stdout.strip())

if "ic_gate || return 1" in cli and "iOS 描述文件仅 iOS 平台可用" in pdg_sh:
    ok("CLI cmd_ios 第一件事就是过平台门控(门控本体在 ic_gate 里)")
else:
    bad("CLI 缺少平台门控")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

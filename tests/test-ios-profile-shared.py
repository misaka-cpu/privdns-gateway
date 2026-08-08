#!/usr/bin/env python3
"""Bot 与 CLI 共用同一个描述文件生成器 —— 行为验证。

关键判据不是"两边都 import 了 iosprofile"(那是看源码, 证明不了运行结果), 而是:
**同样的输入, 两条路径真的跑出来的字节完全一样**。所以这里真的跑 Bot 的 _ios_profile,
也真的跑 pdg.sh 用的那条 `iosprofile.py render` 命令行, 然后逐字节比对。
"""
import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy/bot"))
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
GEN = os.path.join(ROOT, "deploy/bot/iosprofile.py")

import iosprofile  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def expect_error(fn, want, label):
    try:
        fn()
    except iosprofile.ProfileError as e:
        if want in str(e):
            ok("%s → 拒绝: %s" % (label, str(e)[:60]))
        else:
            bad("%s 拒绝了, 但理由不对: %s" % (label, e))
        return
    except Exception as e:  # noqa: BLE001
        bad("%s 抛的不是 ProfileError 而是 %s: %s" % (label, type(e).__name__, e))
        return
    bad("%s 竟然通过了" % label)


# 一张真的自签 CA(用 openssl 现造), 不是拼出来的假 PEM —— 假 PEM 证明不了 DER 解析。
CA_DIR = tmpguard.mkdtemp(prefix="iosprof-ca-")
CA_CRT = os.path.join(CA_DIR, "ca.crt")
CA_KEY = os.path.join(CA_DIR, "ca.key")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", CA_KEY, "-out", CA_CRT, "-days", "1",
                "-subj", "/CN=PDG Test CA"], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
CA_PEM = open(CA_CRT, encoding="utf-8").read()
CA_DER = iosprofile.ca_der_from_pem(CA_PEM)

IDS = {"root": "11111111-1111-1111-1111-111111111111",
       "dns": "22222222-2222-2222-2222-222222222222",
       "ca": "33333333-3333-3333-3333-333333333333"}

# ── 1. 确定性: 同输入同字节 ────────────────────────────────────────────────
a = iosprofile.render("dot.example.com", "203.0.113.10", (), b"", IDS, TMPL)
b = iosprofile.render("dot.example.com", "203.0.113.10", (), b"", IDS, TMPL)
if a == b:
    ok("同样输入 + 同样身份 → 逐字节相同(%d 字节)" % len(a))
else:
    bad("同样输入却产出不同字节")

# SSID 顺序不同不算"配置变了"
s1 = iosprofile.render("dot.example.com", "203.0.113.10", ["B", "A"], b"", IDS, TMPL)
s2 = iosprofile.render("dot.example.com", "203.0.113.10", ["A", "B", "A"], b"", IDS, TMPL)
if s1 == s2:
    ok("SSID 顺序不同 / 有重复 → 规范化后字节仍相同")
else:
    bad("SSID 规范化没生效")
if s1 != a:
    ok("加了 SSID 之后字节确实变了(规范化不是把输入吃掉)")
else:
    bad("加 SSID 没有任何影响")

# ── 2. Bot 与 CLI 走同一条路 ──────────────────────────────────────────────
BOT = r'''
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
m._platform = lambda: "ios"
m._dot_host = lambda: "dot.example.com"
m._server_ip = lambda: "203.0.113.10"
m._mitm_enabled_domains = lambda: %(wloc)s
m._mitm_ca_pem = lambda: %(pem)r
sys.stdout.buffer.write(m._ios_profile(%(ssids)s, %(ids)r))
'''


def bot_run(ssids="()", wloc="[]", pem="", ids=IDS):
    code = BOT % {"bot_dir": os.path.join(ROOT, "deploy/bot"),
                  "bot_py": os.path.join(ROOT, "deploy/bot/pdg-bot.py"),
                  "tmpl": TMPL, "wloc": wloc, "pem": pem, "ssids": ssids, "ids": ids}
    return subprocess.run([sys.executable, "-c", code], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=180)


def cli_run(args):
    return subprocess.run([sys.executable, GEN, "render", "--template", TMPL] + args,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)


ids_args = ["--uuid-root", IDS["root"], "--uuid-dns", IDS["dns"], "--uuid-ca", IDS["ca"]]
base_args = ["--dot-host", "dot.example.com", "--server-ip", "203.0.113.10"] + ids_args

pb = bot_run()
pc = cli_run(base_args)
if pb.returncode == 0 and pc.returncode == 0 and pb.stdout == pc.stdout == a:
    ok("Bot 与 CLI 生成的字节完全相同(无 SSID / 无 CA)")
else:
    bad("Bot/CLI 字节不一致: bot rc=%d %d 字节, cli rc=%d %d 字节\n%s%s"
        % (pb.returncode, len(pb.stdout), pc.returncode, len(pc.stdout),
           pb.stderr.decode()[-200:], pc.stderr.decode()[-200:]))

pb = bot_run(ssids="['Home','Cafe']")
pc = cli_run(base_args + ["--ssid", "Home", "--ssid", "Cafe"])
if pb.returncode == 0 and pb.stdout == pc.stdout and pb.stdout:
    ok("Bot 与 CLI 在带 SSID 排除时字节相同 —— CLI 以前**根本不支持** SSID")
else:
    bad("带 SSID 时 Bot/CLI 不一致: %s / %s"
        % (pb.stderr.decode()[-200:], pc.stderr.decode()[-200:]))

mitm_on = os.path.join(CA_DIR, "mitm-on.json")
json.dump({"wloc": {"enabled": True}}, open(mitm_on, "w"))
pb = bot_run(wloc="['gs-loc.apple.com']", pem=CA_PEM)
pc = cli_run(base_args + ["--wloc-config", mitm_on, "--ca-crt", CA_CRT])
if pb.returncode == 0 and pb.stdout == pc.stdout and pb.stdout:
    ok("Bot 与 CLI 在 WLOC 启用时字节相同 —— CLI 以前**从不附**根证书")
    p = plistlib.loads(pb.stdout)
    cas = [x for x in p["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
    if len(cas) == 1 and cas[0]["PayloadContent"] == CA_DER:
        ok("附上的确实是那张 CA 的 DER")
    else:
        bad("CA payload 内容不对")
else:
    bad("WLOC 时 Bot/CLI 不一致: %s / %s"
        % (pb.stderr.decode()[-200:], pc.stderr.decode()[-200:]))

mitm_off = os.path.join(CA_DIR, "mitm-off.json")
json.dump({"wloc": {"enabled": False}}, open(mitm_off, "w"))
pc = cli_run(base_args + ["--wloc-config", mitm_off, "--ca-crt", CA_CRT])
if pc.returncode == 0 and pc.stdout == a:
    ok("WLOC 未启用 → CLI 不附根证书(信任面不无故扩大)")
else:
    bad("WLOC 关闭时 CLI 仍然带了 CA")

# ── 3. 输出格式统一 ────────────────────────────────────────────────────────
# v1.7.8 有两种输出格式: 没 SSID 也没 CA 时直接吐模板原文(连模板里讲部署细节的 XML 注释
# 一起发给用户), 否则走 plistlib。受管生命周期要拿"字节是否相同"当证据, 格式就不能取决于
# 走了哪个分支。现在只有一种。
with_ca = iosprofile.render("dot.example.com", "203.0.113.10", (), CA_DER, IDS, TMPL)
if b"<!--" not in a and b"<!--" not in with_ca:
    ok("两种情形的输出都不再夹带模板里那段讲部署细节的 XML 注释")
else:
    bad("模板注释仍然出现在发给用户的文件里")
if a.split(b"<plist")[0] == with_ca.split(b"<plist")[0]:
    ok("带不带 CA 的输出头部格式一致(只有一种序列化路径)")
else:
    bad("输出格式仍然分叉")

# ── 4. 私钥绝不进描述文件 ─────────────────────────────────────────────────
KEY_PEM = open(CA_KEY, encoding="utf-8").read()
expect_error(lambda: iosprofile.ca_der_from_pem(KEY_PEM), "私钥", "PEM 里只有私钥")
expect_error(lambda: iosprofile.ca_der_from_pem(CA_PEM + KEY_PEM), "私钥", "证书后面跟着私钥")
expect_error(lambda: iosprofile.ca_der_from_pem(KEY_PEM + CA_PEM), "私钥", "私钥在证书前面")

key_file = os.path.join(CA_DIR, "wrong.crt")
open(key_file, "w").write(KEY_PEM)
pc = cli_run(base_args + ["--wloc-config", mitm_on, "--ca-crt", key_file])
if pc.returncode != 0 and b"\xe7\xa7\x81\xe9\x92\xa5" in pc.stderr and not pc.stdout:
    ok("CA 路径误指向 key 文件 → CLI 拒绝生成且不输出任何字节")
else:
    bad("误指向 key 文件竟然生成了: rc=%d out=%d" % (pc.returncode, len(pc.stdout)))

expect_error(lambda: iosprofile.validate(
    b"<?xml version='1.0'?><plist version='1.0'><dict><key>k</key>"
    b"<string>-----BEGIN PRIVATE KEY-----</string></dict></plist>"),
    "私钥标记", "最终字节里出现私钥标记")

# ── 5. WLOC 开着但 CA 坏了/没有 → 拒绝, 不是悄悄发一份没 CA 的 ─────────────
expect_error(lambda: iosprofile.ca_der_for(True, os.path.join(CA_DIR, "nope.crt")),
             "拒绝生成", "WLOC 启用但 CA 文件不存在")
broken = os.path.join(CA_DIR, "broken.crt")
open(broken, "w").write("-----BEGIN CERTIFICATE-----\nnot-base64!!!\n-----END CERTIFICATE-----\n")
expect_error(lambda: iosprofile.ca_der_for(True, broken), "损坏", "CA base64 坏了")
notder = os.path.join(CA_DIR, "notder.crt")
open(notder, "w").write("-----BEGIN CERTIFICATE-----\n"
                        + base64.b64encode(b"hello world").decode() + "\n"
                        "-----END CERTIFICATE-----\n")
expect_error(lambda: iosprofile.ca_der_for(True, notder), "DER", "解出来不是 DER 结构")

bad_json = os.path.join(CA_DIR, "bad.json")
open(bad_json, "w").write("{ not json")
expect_error(lambda: iosprofile.wloc_enabled(bad_json), "拒绝生成", "MITM 配置解析失败")
if iosprofile.wloc_enabled(os.path.join(CA_DIR, "absent.json")) is False:
    ok("MITM 配置不存在 → 视为未启用(那台机器从没开过 WLOC)")
else:
    bad("配置缺失时判定不对")

# ── 6. 缺输入一律拒绝, 而不是生成一份连不上的文件 ───────────────────────
expect_error(lambda: iosprofile.render("", "203.0.113.10", (), b"", IDS, TMPL),
             "DoT 主机名", "DoT 主机名为空")
expect_error(lambda: iosprofile.render("dot.example.com", "", (), b"", IDS, TMPL),
             "网关地址", "网关地址为空")
expect_error(lambda: iosprofile.render("dot.example.com", "203.0.113.10", (), b"",
                                       {"root": "nope", "dns": IDS["dns"]}, TMPL),
             "合法 UUID", "身份 UUID 不合法")
expect_error(lambda: iosprofile.render("dot.example.com", "203.0.113.10", (), b"", IDS,
                                       os.path.join(CA_DIR, "no-such.tmpl")),
             "缺少描述文件模板", "模板文件不存在")
broken_tmpl = os.path.join(CA_DIR, "broken.tmpl")
open(broken_tmpl, "w").write("<plist><dict><key>oops</key>")
expect_error(lambda: iosprofile.render("dot.example.com", "203.0.113.10", (), b"", IDS,
                                       broken_tmpl), "模板", "模板不是合法 plist")

# ── 7. 输出校验真的会挡住结构错误 ────────────────────────────────────────
p = plistlib.loads(a)
p["PayloadVersion"] = 2
expect_error(lambda: iosprofile.validate(plistlib.dumps(p)), "PayloadVersion",
             "PayloadVersion 被改成 2")
p = plistlib.loads(a)
d = p["PayloadContent"][0]
d["DNSSettings"]["OnDemandRules"] = d.pop("OnDemandRules")
expect_error(lambda: iosprofile.validate(plistlib.dumps(p)), "平级",
             "OnDemandRules 被嵌进 DNSSettings")
p = plistlib.loads(a)
p["PayloadContent"][0]["OnDemandRules"] = [
    {"InterfaceTypeMatch": "WiFi", "Action": "Connect"}, {"Action": "Disconnect"}]
expect_error(lambda: iosprofile.validate(plistlib.dumps(p)), "探测",
             "探测规则被删光(会变成无条件启用 DoT)")
p = plistlib.loads(a)
p["PayloadContent"][0]["DNSSettings"]["DNSProtocol"] = "HTTPS"
expect_error(lambda: iosprofile.validate(plistlib.dumps(p)), "TLS", "DNSProtocol 被改")

# ── 8. 平台门控没有被重构掉 ──────────────────────────────────────────────
code = BOT % {"bot_dir": os.path.join(ROOT, "deploy/bot"),
              "bot_py": os.path.join(ROOT, "deploy/bot/pdg-bot.py"),
              "tmpl": TMPL, "wloc": "[]", "pem": "", "ssids": "()", "ids": IDS}
code = code.replace('m._platform = lambda: "ios"', 'm._platform = lambda: "android"')
pb = subprocess.run([sys.executable, "-c", code], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=180)
if pb.returncode != 0 and not pb.stdout and b"RuntimeError" in pb.stderr:
    ok("Android 平台上 Bot 仍然拒绝生成, 且不产出任何字节")
else:
    bad("Android 门控失效: rc=%d out=%d" % (pb.returncode, len(pb.stdout)))

# ── 9. 生成器不反向依赖 Bot ──────────────────────────────────────────────
probe = os.path.join(CA_DIR, "probe.py")
open(probe, "w").write(
    "import sys\n"
    "sys.path.insert(0, %r)\n" % os.path.join(ROOT, "deploy/bot") +
    "import iosprofile\n"
    "assert 'botmod' not in sys.modules and 'pdg-bot' not in sys.modules\n"
    "print(','.join(sorted(m for m in sys.modules if m.startswith(('mitm', 'pdgtx', 'cfgrestore')))))\n")
pp = subprocess.run([sys.executable, "-I", probe], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=60, universal_newlines=True)
if pp.returncode == 0 and not pp.stdout.strip():
    ok("iosprofile 单独 import 干净: 没拉进 bot / pdgtx / mitm 任何一个")
else:
    bad("iosprofile 有反向依赖或 import 失败: %s%s" % (pp.stdout.strip(), pp.stderr[-200:]))

import shutil  # noqa: E402
shutil.rmtree(CA_DIR, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

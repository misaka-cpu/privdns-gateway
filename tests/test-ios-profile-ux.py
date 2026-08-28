#!/usr/bin/env python3
"""iOS 描述文件生命周期的 Bot / CLI 交互 —— 行为验证。

两条硬要求贯穿全篇:
  1. **绝不声称设备状态**。服务器不知道 iPhone 上此刻装的是哪一版, 所以每一屏文案都不许
     出现"已安装""设备已是最新""更新已生效""已替换手机上的旧描述文件"这类断言;
  2. **Android 一律看不到也用不了**。不只是隐藏按钮 —— 旧消息里的按钮被点、命令被打,
     后端也要拒, 并且不产生任何文件、不写任何记录。
"""
import hashlib
import importlib.util as u
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
BOTDIR = str(ROOT / "deploy" / "bot")
TMPL = str(ROOT / "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# 服务器无从知道、因而一句都不许说的话。
FORBIDDEN = ("已安装", "已经安装", "设备已是最新", "已是最新版", "更新已在手机生效",
             "已在手机生效", "已成功替换", "已替换手机上", "手机上已", "已生效在手机")


def check_wording(label, *texts):
    blob = "\n".join(t for t in texts if t)
    hit = [w for w in FORBIDDEN if w in blob]
    if hit:
        bad("%s 出现了服务器无法知道的设备状态断言: %s" % (label, ", ".join(hit)))
    return not hit


ROOTFS = tmpguard.mkdtemp(prefix="iosux-")
TMPS.append(ROOTFS)
os.makedirs(ROOTFS + "/etc/privdns-gateway", exist_ok=True)
os.makedirs(ROOTFS + "/run", exist_ok=True)
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = ROOTFS + "/run/privdns-gateway.lock"

sys.path.insert(0, BOTDIR)
spec = u.spec_from_file_location("pdg_bot", str(ROOT / "deploy/bot/pdg-bot.py"))
bot = u.module_from_spec(spec)
spec.loader.exec_module(bot)

META = ROOTFS + "/etc/privdns-gateway/ios-profile.json"
ART = ROOTFS + "/var/lib/privdns-gateway/ios-profile"
bot.iosstate.META = META
bot.iosstate.ART_DIR = ART

SENT = []
EDITS = []
PLAIN = []


def setup(platform="ios"):
    SENT.clear(); EDITS.clear(); PLAIN.clear()
    bot.send_document = lambda chat, name, data, cap="": SENT.append((name, data, cap))
    bot.edit = lambda chat, mid, text, kb=None: EDITS.append((text, kb))
    bot.send = lambda chat, text, kb=None: EDITS.append((text, kb))
    bot.send_plain = lambda chat, text: PLAIN.append(text)
    bot.answer_cb_async = lambda *a, **k: None
    bot.state = {}
    bot._platform = lambda: platform
    bot._dot_host = lambda: "dot.example.com"
    bot._server_ip = lambda: "203.0.113.10"
    bot._mitm_enabled_domains = lambda: []
    bot.IOS_TMPL = TMPL


def kb_cbs(kb):
    return [b.get("callback_data") for row in (kb or {}).get("inline_keyboard", []) for b in row]


def reset_state():
    for p in (META, os.path.join(ART, "current.mobileconfig"),
              os.path.join(ART, "previous.mobileconfig")):
        try:
            os.unlink(p)
        except OSError:
            pass


# ── 1. 首次生成: 先问"以前装过吗", 不擅自决定 ─────────────────────────────
setup()
reset_state()
bot.handle_cb(1, 2, "iosgen")
txt, kb = EDITS[-1]
if not SENT and "iosgen:legacy" in kb_cbs(kb) and "iosgen:fresh" in kb_cbs(kb):
    ok("首次生成先问「以前装过吗」, 此时还没有生成任何文件")
else:
    bad("首次生成没有问, 或者已经先斩后奏: sent=%d cbs=%r" % (len(SENT), kb_cbs(kb)))
check_wording("首次询问页", txt) and ok("首次询问页文案不声称设备状态")
if "另一个" in txt and "删" in txt:
    ok("询问页说清了后果: 不删旧的就会变成**另一个**描述文件")
else:
    bad("询问页没说清后果")

# 选"没装过" → 直接生成, 不显示迁移提示
setup()
reset_state()
bot.handle_cb(1, 2, "iosgen:fresh")
meta = json.load(open(META, encoding="utf-8"))
if SENT and SENT[0][0] == "PrivDNS-Gateway.mobileconfig" and not meta["migration_pending"]:
    ok("选「没装过」→ 直接生成并发送, 不提示迁移")
else:
    bad("没装过的路径不对: sent=%r pending=%s" % ([s[0] for s in SENT], meta.get("migration_pending")))
if meta["current"]["sent_at"]:
    ok("发送成功之后才记 sent_at(记的是「我们发了」, 不是「手机装了」)")
else:
    bad("sent_at 没记上")

# 选"装过" → 迁移提示 + 明确要求先删旧的
setup()
reset_state()
bot.handle_cb(1, 2, "iosgen:legacy")
meta = json.load(open(META, encoding="utf-8"))
cap = SENT[0][2] if SENT else ""
if meta["migration_pending"] and "删除旧的" in cap:
    ok("选「装过」→ 记为待迁移, 文件说明里要求先删除旧描述文件")
else:
    bad("迁移路径不对: pending=%s cap=%r" % (meta.get("migration_pending"), cap[:80]))
check_wording("迁移文件说明", cap) and ok("迁移文件说明不声称已替换旧文件")

# ── 2. 状态页 ──────────────────────────────────────────────────────────────
setup()
bot.handle_cb(1, 2, "ios")
txt, kb = EDITS[-1]
if "第 1 版" in txt and "无法确认" in txt:
    ok("状态页给出版本号并明说服务器无法确认设备上是什么")
else:
    bad("状态页内容不对: %r" % txt[:120])
if "iosack" in kb_cbs(kb):
    ok("待迁移时状态页有「旧描述文件我已删除」按钮")
else:
    bad("缺少迁移确认按钮: %r" % kb_cbs(kb))
check_wording("状态页", txt) and ok("状态页文案不声称设备状态")

bot.handle_cb(1, 2, "iosack")
txt, kb = EDITS[-1]
meta = json.load(open(META, encoding="utf-8"))
if not meta["migration_pending"] and "无从核实" in txt:
    ok("确认迁移只是记下用户的自述, 并明说服务器无从核实")
else:
    bad("迁移确认不对: pending=%s txt=%r" % (meta.get("migration_pending"), txt[:80]))

# ── 3. 重复生成不制造新版本 ───────────────────────────────────────────────
setup()
rev0 = json.load(open(META, encoding="utf-8"))["current"]["revision"]
bot.handle_cb(1, 2, "iosgen")
txt, kb = EDITS[-1]
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["revision"] == rev0 and "没有变化" in txt:
    ok("配置没变时再点一次: 重新发送同一版, 不产生新版本")
else:
    bad("重复生成造出了新版本: %d → %d" % (rev0, meta["current"]["revision"]))

# ── 4. 配置变了 → 新版本 + 差异 + 取回上一版 ──────────────────────────────
setup()
bot._dot_host = lambda: "dot.new.example"
bot.handle_cb(1, 2, "iosgen")
txt, kb = EDITS[-1]
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["revision"] == rev0 + 1 and "必须更新" not in txt:
    ok("DoT 域名变了 → 生成第 %d 版" % meta["current"]["revision"])
else:
    bad("换域名后的行为不对: rev=%d" % meta["current"]["revision"])
if "iosdiff" in kb_cbs(kb) and "iosprev" in kb_cbs(kb):
    ok("有上一版之后, 状态页出现「对比」和「取回上一版」")
else:
    bad("缺少对比/取回按钮: %r" % kb_cbs(kb))

bot.handle_cb(1, 2, "iosdiff")
txt, _ = EDITS[-1]
if "DoT 主机名" in txt and "dot.example.com" in txt and "dot.new.example" in txt:
    ok("差异是字段级的, 直接给出旧值 → 新值")
else:
    bad("差异输出不对: %r" % txt[:150])
check_wording("差异页", txt) and ok("差异页文案不声称设备状态")

setup()
bot.handle_cb(1, 2, "iosprev")
if SENT and SENT[0][0] == "PrivDNS-Gateway-prev.mobileconfig" and "不会因此回退" in SENT[0][2]:
    ok("取回上一版只是把旧文件再给一次, 并说明当前版本不会回退")
else:
    bad("取回上一版不对: %r" % ([s[0] for s in SENT],))
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["dot_host"] == "dot.new.example":
    ok("取回上一版之后, 服务器记录的当前版本没有变")
else:
    bad("取回上一版把当前版本改回去了")

# ── 4b. Bot 的「生成/更新」按钮不许清掉已配好的 SSID ──────────────────────
setup()
bot._dot_host = lambda: "dot.new.example"
bot.handle_cb(1, 2, "ios_ssid")            # 进入 SSID 输入流程(真的走回调)
bot.handle_text(1, "Home\nOffice")          # 再真的走文本处理
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == ["Home", "Office"]:
    ok("通过 Bot 文本流程配好强制直连名单: %s" % ", ".join(meta["current"]["inputs"]["ssids"]))
else:
    bad("SSID 没配上: %r" % meta["current"]["inputs"].get("ssids"))
rev_before = meta["current"]["revision"]
setup()
bot._dot_host = lambda: "dot.new.example"
bot.handle_cb(1, 2, "iosgen")               # 再点一次「生成/更新描述文件」
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == ["Home", "Office"] \
        and meta["current"]["revision"] == rev_before:
    ok("再点「生成/更新」→ 名单沿用, revision 不变(没有把用户配的东西悄悄抹掉)")
else:
    bad("按钮把 SSID 清掉了: ssids=%r rev=%s→%s"
        % (meta["current"]["inputs"].get("ssids"), rev_before, meta["current"]["revision"]))
setup()
bot._dot_host = lambda: "dot.new.example"
bot.handle_cb(1, 2, "ios")
txt, _ = EDITS[-1]
if "无需更新" in txt:
    ok("状态页也不再冒出幻影「建议更新」")
else:
    bad("状态页出现了谁也没做过的变化: %r" % txt[:160])

# ── 5. CA 只显示指纹 ──────────────────────────────────────────────────────
CA_DIR = tmpguard.mkdtemp(prefix="iosux-ca-")
TMPS.append(CA_DIR)
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", CA_DIR + "/ca.key", "-out", CA_DIR + "/ca.crt", "-days", "1",
                "-subj", "/CN=PDG Test CA"], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
CA_PEM = open(CA_DIR + "/ca.crt", encoding="utf-8").read()
setup()
bot._dot_host = lambda: "dot.new.example"
bot._mitm_enabled_domains = lambda: ["gs-loc.apple.com"]
bot._mitm_ca_pem = lambda: CA_PEM
bot.handle_cb(1, 2, "iosgen")
bot.handle_cb(1, 2, "ios")
txt, _ = EDITS[-1]
if "含根证书: 是" in txt and "BEGIN CERTIFICATE" not in txt and "PRIVATE" not in txt:
    ok("状态页只显示根证书指纹前缀, 不输出证书正文")
else:
    bad("状态页的证书展示不对: %r" % txt[:200])

setup()
bot._dot_host = lambda: "dot.new.example"
bot._mitm_enabled_domains = lambda: ["gs-loc.apple.com"]
bot._mitm_ca_pem = lambda: ""
bot.handle_cb(1, 2, "iosgen")
txt, _ = EDITS[-1]
if "生成失败" in txt and "CA" in txt and not SENT:
    ok("WLOC 开着但 CA 读不到 → Bot 报失败且不发文件")
else:
    bad("CA 缺失时仍然发了文件: %r" % txt[:120])

# ── 6. Android: 一个都不许露, 一个都不许动 ────────────────────────────────
before = open(META, "rb").read()
setup("android")
title, kb = bot._nav("client")
if "ios" not in kb_cbs(kb) and "描述文件" not in title:
    ok("Android 客户端菜单没有 iOS 描述文件入口")
else:
    bad("Android 菜单露出了 iOS 入口: %r" % kb_cbs(kb))
for data in ("ios", "ios_ssid", "iosgen", "iosgen:fresh", "iosgen:legacy",
             "iosdiff", "iosprev", "iosack"):
    SENT.clear()
    bot.handle_cb(1, 2, data)
    if SENT:
        bad("Android 上 %s 竟然发了文件" % data)
        break
else:
    ok("Android 上 8 个 iOS 回调全被后端门控拦下, 一个文件都没发")
if open(META, "rb").read() == before:
    ok("Android 上这些操作没有改动任何生命周期记录")
else:
    bad("Android 上竟然改了记录")

setup("android")
bot.handle_msg = getattr(bot, "handle_msg", None)
try:
    bot._ios_generate()
    bad("Android 上 _ios_generate 没有抛错")
except RuntimeError:
    ok("Android 上最底层的 _ios_generate 直接抛错(绕过按钮也没用)")

# ── 7. CLI 与 Bot 共用同一份记录和同一套措辞 ──────────────────────────────
ST = str(ROOT / "deploy/bot/iosstate.py")
env = dict(os.environ, PDG_TX_FSROOT=ROOTFS, PDG_LOCKFILE=ROOTFS + "/run/privdns-gateway.lock")
r = subprocess.run([sys.executable, ST, "status"], capture_output=True, text=True,
                   timeout=120, env=env)
if r.returncode == 0 and "第 " in r.stdout and "无法确认" in r.stdout:
    ok("CLI status 读的是同一份记录, 并同样声明服务器无法确认设备状态")
else:
    bad("CLI status 不对: rc=%d %r" % (r.returncode, r.stdout[:150]))
check_wording("CLI status", r.stdout) and ok("CLI status 文案不声称设备状态")

r = subprocess.run([sys.executable, ST, "diff"], capture_output=True, text=True,
                   timeout=120, env=env)
meta = json.load(open(META, encoding="utf-8"))
want = ["第 %d 版 → 第 %d 版" % (meta["previous"]["revision"], meta["current"]["revision"])]
want += [bot.iosstate.FIELD_LABEL[k]
         for k, _, _, _ in bot.iosstate.diff_fields(meta["previous"]["inputs"],
                                                    meta["current"]["inputs"])]
if r.returncode == 0 and all(w in r.stdout for w in want) and "必须更新" in r.stdout:
    ok("CLI diff 逐字段列出 %s, 并标了各自的更新等级" % "、".join(want[1:]))
else:
    bad("CLI diff 不对: rc=%d 缺 %r\n%s"
        % (r.returncode, [w for w in want if w not in r.stdout], r.stdout[:200]))
if "BEGIN CERTIFICATE" not in r.stdout and "PRIVATE" not in r.stdout \
        and meta["current"]["inputs"]["wloc_ca_sha256"][:16] in r.stdout:
    ok("CLI diff 里的根证书只有指纹前缀, 没有证书正文")
else:
    bad("CLI diff 输出了证书正文或漏了指纹")

out = ROOTFS + "/prev.mobileconfig"
r = subprocess.run([sys.executable, ST, "previous", "--out", out], capture_output=True,
                   text=True, timeout=120, env=env)
if r.returncode == 0 and open(out, "rb").read() == \
        open(os.path.join(ART, "previous.mobileconfig"), "rb").read():
    ok("CLI previous 取出的就是那份上一版产物")
else:
    bad("CLI previous 不对: rc=%d" % r.returncode)

# CLI 生成一次 → Bot 立刻看得到同一版本(共用记录, 不是各记各的)
rev_before = json.load(open(META, encoding="utf-8"))["current"]["revision"]
r = subprocess.run([sys.executable, ST, "generate", "--dot-host", "dot.cli.example",
                    "--server-ip", "203.0.113.10", "--template", TMPL,
                    "--out", ROOTFS + "/cli.mobileconfig"],
                   capture_output=True, text=True, timeout=120, env=env)
setup()
bot._dot_host = lambda: "dot.cli.example"
bot.handle_cb(1, 2, "ios")
txt, _ = EDITS[-1]
meta = json.load(open(META, encoding="utf-8"))
if r.returncode == 0 and meta["current"]["revision"] == rev_before + 1 \
        and ("第 %d 版" % meta["current"]["revision"]) in txt:
    ok("CLI 生成的版本 Bot 立刻看得到(同一份记录, 不是各记各的)")
else:
    bad("CLI/Bot 记录不同源: rc=%d rev=%d txt=%r" % (r.returncode,
                                                    meta["current"]["revision"], txt[:100]))

# ── 8. CLI 的平台门控 ─────────────────────────────────────────────────────
sh = subprocess.run(
    ["bash", "-c",
     "set -e; sed -n '/^ic_gate()/,/^}/p' deploy/bot/pdg.sh > ${TMPDIR:-/tmp}/icg.$$;"
     " . ${TMPDIR:-/tmp}/icg.$$; _pdg_platform(){ echo android; };"
     " ic_gate && echo ALLOWED || echo REFUSED; rm -f ${TMPDIR:-/tmp}/icg.$$"],
    capture_output=True, text=True, cwd=str(ROOT), timeout=120)
if "REFUSED" in sh.stdout and "仅 iOS 平台可用" in sh.stdout:
    ok("CLI 的 iOS 门控在 android 上拒绝(真的跑了那个函数)")
else:
    bad("CLI 门控没生效: %r" % sh.stdout[:150])

sh = subprocess.run(
    ["bash", "-c",
     "set -e; sed -n '/^ic_gate()/,/^}/p' deploy/bot/pdg.sh > ${TMPDIR:-/tmp}/icg2.$$;"
     " . ${TMPDIR:-/tmp}/icg2.$$; _pdg_platform(){ echo ios; };"
     " ic_gate && echo ALLOWED || echo REFUSED; rm -f ${TMPDIR:-/tmp}/icg2.$$"],
    capture_output=True, text=True, cwd=str(ROOT), timeout=120)
if sh.stdout.strip() == "ALLOWED":
    ok("CLI 的 iOS 门控在 ios 上放行")
else:
    bad("iOS 上被误拒: %r" % sh.stdout[:150])

pdg = open(ROOT / "deploy/bot/pdg.sh", encoding="utf-8").read()
if "ic_gate || return 1" in pdg and pdg.count("ic_gate || return 1") >= 2:
    ok("cmd_ios 与 cmd_ios_state 都在门控之后才做事")
else:
    bad("有 iOS 命令没走门控")

# ── 9. 每个子命令都必须落到它该去的那条路 ─────────────────────────────────
# 两个方向的错都很贵, 而且都不报错:
#   · 只读子命令掉进默认分支 = 生成 + 装 qrencode + 开临时 8443 + 起 HTTP 服务。用户以为在
#     修一个文件, 实际上在生产机上开了个下载口;
#   · `previous` 只把文件写到服务器上而**不开下载通道** = 手机根本拿不到它, 可命令还在说
#     "已取出上一版" —— 看起来能用, 实际上只有 Telegram Bot 那条路能取回上一版。
# 子命令清单从 iosstate.py 自己的 argparse 取 —— 写死一份就等于"以后新增的照样漏"。
_help = subprocess.run([sys.executable, str(ROOT / "deploy/bot/iosstate.py"), "--help"],
                       capture_output=True, text=True, timeout=120).stdout
_m = re.search(r"\{([a-z,\-]+)\}", _help)
ALL_SUBS = [x for x in (_m.group(1).split(",") if _m else []) if x]
# `pdg ios` **不**暴露的内部子命令: cmd_rollback 在覆盖生产文件之前直接调它并传 --tree,
# 不走 cmd_ios 的分派。列在这里而不是悄悄跳过 —— 下面那条守卫会确认它确实是这个身份。
INTERNAL_SUBS = {"verify-restore"}
SUBS = [x for x in ALL_SUBS if x != "generate" and x not in INTERNAL_SUBS]
if len(SUBS) >= 5:
    ok("从 iosstate.py 的 argparse 取到 %d 个 generate 之外的子命令: %s" % (len(SUBS), ", ".join(SUBS)))
else:
    bad("取不到子命令清单: %r" % _help[:200])
_pdgsrc = open(ROOT / "deploy/bot/pdg.sh", encoding="utf-8").read()
_disp = re.search(r"^cmd_ios_state\(\)\{.*?^\}", _pdgsrc, re.S | re.M)
for _s in sorted(INTERNAL_SUBS):
    if _s not in ALL_SUBS:
        bad("内部子命令 %s 已经不存在了, 这份豁免清单该清理" % _s)
    elif _disp and _s in _disp.group(0):
        bad("%s 被 cmd_ios_state 分派了, 它不该被当成内部子命令豁免" % _s)
    elif _s not in _pdgsrc:
        bad("内部子命令 %s 在 pdg.sh 里根本没被调用 —— 它是死代码还是漏接了?" % _s)
    else:
        ok("内部子命令 %s 确实不走 `pdg ios` 分派, 由别处(cmd_rollback)直接调用" % _s)

# 真的把 cmd_ios / cmd_ios_previous / ic_gate 抽出来跑一遍, 只把它依赖的外部动作换成桩。
HARNESS = r"""
set -u
grep -E '^IOS_TMPL='                 deploy/bot/pdg.sh >  ${TMPDIR:-/tmp}/iosdisp.$$
sed -n '/^ic_gate()/,/^}/p'          deploy/bot/pdg.sh >> ${TMPDIR:-/tmp}/iosdisp.$$
sed -n '/^cmd_ios_state()/,/^}/p'    deploy/bot/pdg.sh >> ${TMPDIR:-/tmp}/iosdisp.$$
sed -n '/^cmd_ios_previous()/,/^}/p' deploy/bot/pdg.sh >> ${TMPDIR:-/tmp}/iosdisp.$$
sed -n '/^cmd_ios()/,/^}/p'          deploy/bot/pdg.sh >> ${TMPDIR:-/tmp}/iosdisp.$$
need_root(){ :; }
_pdg_platform(){ echo ios; }
_pdg_module(){ echo /nonexistent/$1; }
_ios_dot_host(){ echo dot.example.com; }
_ios_server_ip(){ echo 203.0.113.10; }
_ios_internal_cidr(){ echo 172.22.0.0/16; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
PDG_IOS_LEGACY=n                   # 首次生成的那句问话在非交互场景下显式给出, 不卡住
# 只读路径的落点: 换成一句可识别的输出, 于是"走到了哪条分支"是**可观察**的
python3(){ shift; echo "READONLY:${1:-none}"; }   # 调用形态是 python3 <模块> <子命令> …
# 临时下载通道的落点: 同样给一句可识别的输出 —— "有没有给手机开取件的路"因此也是可观察的
_ios_offer_download(){ echo "CHANNEL:$1"; }
# 生成路径上那些会真动机器的动作: 一旦被走到就立刻暴露
apt-get(){ echo "DANGER:apt-get $*"; return 1; }
qrencode(){ echo "DANGER:qrencode"; return 1; }
nft(){ echo "DANGER:nft $*"; return 1; }
mktemp(){ echo ${TMPDIR:-/tmp}/iosdisp-www.$$; }
# shellcheck source=/dev/null
. ${TMPDIR:-/tmp}/iosdisp.$$
rm -f ${TMPDIR:-/tmp}/iosdisp.$$
IOS_TMPL="$2"
cmd_ios ${1:+"$1"} 2>&1 | head -8
"""


def dispatch(sub=""):
    r = subprocess.run(["bash", "-c", HARNESS, "_", sub, TMPL], capture_output=True,
                       text=True, cwd=str(ROOT), timeout=120)
    return (r.stdout or "") + (r.stderr or "")


# 判据必须是**正向**的: "真的走到了只读分支"/"真的走到了下载通道"。第一版写成"没出现危险
# 标记"就假绿了 —— 没被分发的子命令在抽出的函数里因未定义变量提前退出, 同样不产生危险标记。
# previous 与其余五个的判据在这里是**反着的**: 它必须开通道, 它们必须不开。
_leaks = []
for sub in SUBS:
    out = dispatch(sub)
    want_channel = sub == "previous"
    if ("READONLY:" + sub) not in out or "DANGER:" in out \
            or (("CHANNEL:" in out) != want_channel):
        _leaks.append("%s → %s" % (sub, (out.strip().splitlines() or ["(无输出)"])[0][:70]))
if not _leaks:
    ok("%d 个子命令各就各位: previous 取到字节后开临时下载通道, 其余 %d 个只读且不开端口"
       % (len(SUBS), len(SUBS) - 1))
else:
    bad("这些子命令落错了地方(掉进默认分支, 或该开/不该开下载通道): %s" % "; ".join(_leaks))

# 手机取件只有一条路: `pdg ios`(当前版)与 `pdg ios previous`(上一版)必须是同一条。
_cur = dispatch("")
if "CHANNEL:" in _cur and "READONLY:generate" in _cur:
    ok("`pdg ios`(当前版)也走同一个 _ios_offer_download —— 两条路共用一处实现")
else:
    bad("当前版没走共用通道: %r" % _cur.strip()[:150])

_usage = re.search(r'echo "用法: pdg ios \{([^}]*)\}"', pdg)
_listed = set((_usage.group(1).split("|") if _usage else []))
if _listed == set(SUBS):
    ok("用法提示里列的子命令与实际支持的一致")
else:
    bad("用法提示与实际不符: 提示 %r 实际 %r" % (sorted(_listed), sorted(SUBS)))

# ── 10. 那条临时下载通道: 一处实现, 并且真的跑一遍 ─────────────────────────
# 复制一份的代价不是"多几行", 是**两份会分头长歪**: 加固(令牌、放行范围、超时)只改到一边,
# 另一边照旧, 而两边看起来都在正常工作。
_OFFER = re.search(r"^_ios_offer_download\(\)\{.*?^\}", pdg, re.S | re.M)
_OFFER = _OFFER.group(0) if _OFFER else ""
_dup = [lbl for pat, lbl in (("python3 -m http.server", "临时 HTTP"),
                             ("nft insert rule", "临时 nft 放行"),
                             ("qrencode -t", "终端二维码"))
        if pdg.count(pat) != 1 or pat not in _OFFER]
if not _OFFER:
    bad("抽不到 _ios_offer_download —— 下载通道没有被收成一个函数")
elif _dup:
    bad("下载通道不是一处实现(这几样在别处还有一份, 或不在通道函数里): %s" % "、".join(_dup))
else:
    ok("临时 HTTP / nft 放行 / 二维码全仓各只有一处, 都在 _ios_offer_download 里")

# 真的把这个函数跑起来。会真动机器的三样(nft / qrencode / 起 HTTP 的 timeout)换成**真文件**
# 桩 —— 函数里是 `exec timeout …`, exec 只认可执行文件, shell 函数在这里换不掉它。
CH = tmpguard.mkdtemp(prefix="ioschan-")
TMPS.append(CH)
CHBIN = os.path.join(CH, "bin")
os.makedirs(CHBIN)
CHLOG = os.path.join(CH, "log")
CHREADY = os.path.join(CH, "ready")
CHSRC = os.path.join(CH, "prev.mobileconfig")
with open(CHSRC, "wb") as f:
    f.write(b"<?xml version=\"1.0\"?><plist><dict><key>prev</key></dict></plist>\n")
CHSHA = hashlib.sha256(open(CHSRC, "rb").read()).hexdigest()

for _name, _body in (
        ("nft", '#!/bin/sh\necho "nft $*" >> "$PDG_TEST_LOG"\n'),
        ("qrencode", '#!/bin/sh\necho "qrencode $*" >> "$PDG_TEST_LOG"\n'),
        # timeout 记下自己被怎么调起来、服务目录里到底是什么, 然后变成一个可被 kill 的长命
        # 进程 —— "按回车即收"到底收没收干净, 靠它活着还是死了来判。
        ("timeout", '#!/bin/sh\n'
                    '{ echo "timeout-args=$*"\n'
                    '  echo "serve-cwd=$PWD"\n'
                    '  echo "serve-files=$(ls)"\n'
                    '  echo "serve-sha=$(sha256sum -- *.mobileconfig | awk \'{print $1}\')"\n'
                    '  echo "serve-pid=$$"\n'
                    '} >> "$PDG_TEST_LOG"\n'
                    ': > "$PDG_TEST_READY"\n'
                    'exec sleep 30\n')):
    _p = os.path.join(CHBIN, _name)
    with open(_p, "w", encoding="utf-8") as f:
        f.write(_body)
    os.chmod(_p, 0o755)

HARNESS_CH = r"""
set -u
sed -n '/^_ios_offer_download()/,/^}/p' deploy/bot/pdg.sh > "$CH_DIR/fn.sh"
# 收尾还原走 _nft_apply_main(它顺带把内网面板的白名单补回内核)。**抽取清单要跟着依赖走**
# —— 漏了它, 那次还原调到一个未定义的名字, nft 日志里就没有 `-f /etc/nftables.conf`,
# 断言看起来像"没还原防火墙"这个产品缺陷, 其实是夹具少抽了一个函数。
sed -n '/^_nft_apply_main()/,/^}/p'  deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
sed -n '/^_lan_nft_reapply()/,/^}/p' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
# 常量也要跟着抽。`set -u` 下漏一个就是 unbound variable, 而那会让 _nft_apply_main 在
# 调 _lan_nft_reapply 时半途死掉 —— 表现同样是"没还原防火墙", 与漏抽函数一模一样。
# (_lan_nft_reapply 原先把这个路径写死在函数体里, 于是这里不抽也能跑; 路径收归常量之后
#  就不行了 —— 写死路径让夹具"碰巧能用", 那本身就是它该被改掉的理由之一。)
grep -E '^LAN_NFT_CONF=' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
grep -q 'http.server' "$CH_DIR/fn.sh" || { echo "EXTRACT-FAIL"; exit 9; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
# shellcheck source=/dev/null
. "$CH_DIR/fn.sh"
# 桩里的 HTTP 一起来就 touch ready, 这里的"回车"随之到达 —— 不靠 sleep 猜时序。
_ios_offer_download "$CH_SRC" 203.0.113.10 172.22.0.0/16 "这一份是**上一版**" \
  < <(n=0; while [ ! -e "$PDG_TEST_READY" ]; do sleep 0.05
        n=$((n+1)); [ "$n" -gt 200 ] && break; done)
echo "RC=$?"
"""
_chenv = dict(os.environ, PATH=CHBIN + os.pathsep + os.environ.get("PATH", ""),
              PDG_TEST_LOG=CHLOG, PDG_TEST_READY=CHREADY, CH_DIR=CH, CH_SRC=CHSRC)
_r = subprocess.run(["bash", "-c", HARNESS_CH], capture_output=True, text=True,
                    cwd=str(ROOT), timeout=180, env=_chenv)
_chout = (_r.stdout or "") + (_r.stderr or "")
_chlog = open(CHLOG, encoding="utf-8").read() if os.path.exists(CHLOG) else ""


def _lv(key):
    m = re.search(r"^%s=(.*)$" % re.escape(key), _chlog, re.M)
    return m.group(1).strip() if m else ""


if _lv("timeout-args") == "600 python3 -m http.server 8443 --bind 0.0.0.0":
    ok("下载通道真的起了 HTTP:8443, 并自带 10 分钟硬超时(没人管也会自己收)")
else:
    bad("HTTP 没按预期起: timeout-args=%r\n%s" % (_lv("timeout-args"), _chout[:300]))

_tok = re.match(r"^([0-9a-f]{12})\.mobileconfig$", _lv("serve-files"))
_url = "http://203.0.113.10:8443/%s.mobileconfig" % (_tok.group(1) if _tok else "?")
if _tok and _lv("serve-sha") == CHSHA and _url in _chout:
    ok("服务目录里只有那一份产物且逐字节相同, 路径是一次性随机名(同网段猜不到)")
else:
    bad("服务的内容/路径不对: files=%r sha=%r" % (_lv("serve-files"), _lv("serve-sha")))

_nft = re.findall(r"^nft (.*)$", _chlog, re.M)
_ins = [i for i, x in enumerate(_nft)
        if x == "insert rule inet pdg input ip saddr 172.22.0.0/16 tcp dport 8443 accept"]
_res = [i for i, x in enumerate(_nft) if x == "-f /etc/nftables.conf"]
if _ins and _res and _res[-1] > _ins[0]:
    ok("放行只对内网卡段开 8443, 收尾时 nft -f 原样还原")
else:
    bad("nft 动作不对: %r" % (_nft,))

if ("qrencode -o /opt/pdg-bot/ios-qr.png " + _url) in _chlog \
        and ("qrencode -t ANSIUTF8 " + _url) in _chlog:
    ok("二维码(终端 + PNG)指向的就是这一次的临时链接")
else:
    bad("二维码不对: %r" % [x for x in _chlog.splitlines() if x.startswith("qrencode")])

if _lv("serve-cwd") and not os.path.exists(_lv("serve-cwd")):
    ok("收尾时临时目录连同那份产物一起删掉了, 服务器上不留副本")
else:
    bad("临时目录还在: %r" % _lv("serve-cwd"))

_pid = int(_lv("serve-pid") or 0)
_alive = True
for _ in range(60):
    try:
        os.kill(_pid, 0)
    except OSError:
        _alive = False
        break
    except ValueError:
        break
    subprocess.run(["sleep", "0.05"], timeout=10)
if _pid and not _alive:
    ok("按回车即收: HTTP 进程当场就没了, 不是留着等 10 分钟超时")
else:
    bad("退出后 HTTP 进程还活着(pid=%s) —— 端口会一直开到超时" % _pid)
    if _pid:
        try:
            os.kill(_pid, 9)
        except OSError:
            pass

if "RC=0" in _chout and "这一份是**上一版**" in _chout:
    ok("通道把调用方给的附注原样带给用户, 正常收尾返回 0")
else:
    bad("通道收尾不对: %r" % _chout[-300:])

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

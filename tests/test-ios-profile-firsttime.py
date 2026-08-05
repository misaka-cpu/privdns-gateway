#!/usr/bin/env python3
"""首次启用受管描述文件时, 服务器**不许猜**"这台机器以前装没装过"。

按钮那条路径早就在问了。文本那条(发 SSID 名单)没有: 它看到"记录里没有 current"就直接推断
成"以前装过"(legacy=True), 然后立刻生成。两种猜法都有代价, 而且都不可逆:

  · 猜"装过"而其实没装 → 用户白被要求去 iPhone 上删一个根本不存在的描述文件, 状态页还会
    一直挂着迁移提示;
  · 猜"没装过"而其实装过 → 旧那份用的是随机身份, iOS 会把新的当成**另一个**描述文件并存,
    于是手机上悄悄多出一个永远不会被更新的配置, 而且没有任何一处会报错。

服务器没有任何渠道能知道这件事 —— 本项目不是 MDM。用户知道。所以先把 SSID 收下暂存, 问清
楚再生成; 没回答就什么都不写(不建记录、不落产物、不占身份)。
"""
import importlib.util as u
import json
import os
import shutil
import sys
import tempfile
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


# 服务器无从知道、因而一句都不许说的话(与 test-ios-profile-ux.py 同一份口径)。
FORBIDDEN = ("已安装", "已经安装", "设备已是最新", "已是最新版", "更新已在手机生效",
             "已在手机生效", "已成功替换", "已替换手机上", "手机上已", "已生效在手机",
             "检测到你装过", "我们知道你")


def check_wording(label, *texts):
    blob = "\n".join(t for t in texts if t)
    hit = [w for w in FORBIDDEN if w in blob]
    if hit:
        bad("%s 出现了服务器无法知道的设备状态断言: %s" % (label, ", ".join(hit)))
        return False
    return True


ROOTFS = tmpguard.mkdtemp(prefix="iosft-")
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
    # 主菜单/导航页会去读真机的 sing-box 配置 —— 这条用例只关心"离开这一页会不会清掉暂存",
    # 所以把那两屏换成桩, 免得沙箱里去碰 /etc。
    bot.status_text = lambda: "(主菜单)"
    bot._nav = lambda k: ("(%s)" % k, {"inline_keyboard": []})


def kb_cbs(kb):
    return [b.get("callback_data") for row in (kb or {}).get("inline_keyboard", []) for b in row]


def wipe():
    """回到"这台机器从没启用过受管生命周期"的状态。"""
    for p in (META, os.path.join(ART, "current.mobileconfig"),
              os.path.join(ART, "previous.mobileconfig")):
        try:
            os.unlink(p)
        except OSError:
            pass


def artifacts():
    try:
        return sorted(os.listdir(ART))
    except OSError:
        return []


def untouched(label):
    """什么都没写: 没有记录、没有产物。首次流程没得到回答时必须是这个样子。"""
    if os.path.exists(META):
        bad("%s: 竟然写下了记录(身份已被占用, 而用户还没回答)" % label)
        return False
    if artifacts():
        bad("%s: 竟然落了产物 %r" % (label, artifacts()))
        return False
    ok("%s: 没有记录、没有产物 —— 一个字节都没写" % label)
    return True


def last_texts():
    return [t for t, _kb in EDITS] + list(PLAIN)


print("══ 一、首次 + 文本流发 SSID: 必须先问, 不许猜 ══")
setup()
wipe()
bot.handle_cb(1, 2, "ios_ssid")
bot.handle_text(1, "Home\nOffice")
if not SENT:
    ok("还没有发出任何描述文件")
else:
    bad("先斩后奏: 已经发了 %r" % [s[0] for s in SENT])
untouched("首次发 SSID 之后")
asked = [kb for _t, kb in EDITS if "iosgen:legacy" in kb_cbs(kb) and "iosgen:fresh" in kb_cbs(kb)]
if asked:
    ok("问了「以前装过 / 从未装过」, 并且给了取消的出口: %r" % kb_cbs(asked[-1]))
else:
    bad("没问就走了: 界面上给的按钮是 %r" % [kb_cbs(kb) for _t, kb in EDITS])
if asked and any(c and c.endswith("cancel") for c in kb_cbs(asked[-1])):
    ok("有明确的「取消」而不是只能靠返回")
else:
    bad("没有取消的出口: %r" % (kb_cbs(asked[-1]) if asked else None))
txt = "\n".join(last_texts())
check_wording("首次询问页(文本流)", txt) and ok("询问页文案不声称服务器知道手机上有什么")
if "另一个" in txt and "删" in txt:
    ok("询问页说清了后果: 不删旧的就会变成另一个描述文件")
else:
    bad("询问页没说清后果: %s" % txt[-200:])

print()
print("══ 二、回答之后才生成, 并且用的是刚才发的那份 SSID ══")
setup()
bot.handle_cb(1, 2, "iosgen:fresh")
if SENT:
    ok("回答「从未装过」→ 这才生成并发送")
else:
    bad("回答之后仍然没有生成")
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == ["Home", "Office"]:
    ok("刚才发的 SSID 名单被带上了(暂存没丢): %r" % meta["current"]["inputs"]["ssids"])
else:
    bad("SSID 丢了或被清空: %r" % meta["current"]["inputs"].get("ssids"))
if meta["migration_pending"] is False:
    ok("「从未装过」→ 不挂迁移提示")
else:
    bad("从未装过却记成了待迁移")

print()
print("══ 三、回答「以前装过」→ 记待迁移并要求先删旧的 ══")
setup()
wipe()
bot.handle_cb(1, 2, "ios_ssid")
bot.handle_text(1, "Cafe")
untouched("发 SSID 之后(第二轮)")
setup()
bot.handle_cb(1, 2, "iosgen:legacy")
meta = json.load(open(META, encoding="utf-8"))
cap = SENT[0][2] if SENT else ""
if meta["migration_pending"] and "删除旧的" in cap:
    ok("记为待迁移, 且文件说明里要求先在 iPhone 上删掉旧的那份")
else:
    bad("迁移路径不对: pending=%s cap=%r" % (meta.get("migration_pending"), cap[:80]))
if meta["current"]["inputs"]["ssids"] == ["Cafe"]:
    ok("这一轮的 SSID 也带上了: %r" % meta["current"]["inputs"]["ssids"])
else:
    bad("SSID 不对: %r" % meta["current"]["inputs"].get("ssids"))
check_wording("迁移文件说明", cap) and ok("迁移说明不声称已经替换掉了手机上的旧文件")

print()
print("══ 四、取消 / 返回 → 什么都不写, 暂存也要清掉 ══")
setup()
wipe()
bot.handle_cb(1, 2, "ios_ssid")
bot.handle_text(1, "WillCancel")
bot.handle_cb(1, 2, "iosgen:cancel")
untouched("点了取消之后")
setup()
bot.handle_cb(1, 2, "iosgen:fresh")          # 取消之后再从头生成
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == []:
    ok("取消清掉了暂存: 之后的生成不会莫名其妙带上 WillCancel")
else:
    bad("暂存没清掉, 泄漏到了下一次生成: %r" % meta["current"]["inputs"]["ssids"])

for esc, label in (("menu", "回主菜单"), ("nav:client", "切到别的页"), ("ios", "退回 iOS 页")):
    setup()
    wipe()
    bot.handle_cb(1, 2, "ios_ssid")
    bot.handle_text(1, "Leaked-" + esc)
    bot.handle_cb(1, 2, esc)
    untouched("%s 之后" % label)
    setup()
    bot.handle_cb(1, 2, "iosgen:fresh")
    meta = json.load(open(META, encoding="utf-8"))
    if meta["current"]["inputs"]["ssids"] == []:
        ok("%s 清掉了暂存" % label)
    else:
        bad("%s 之后暂存还在: %r" % (label, meta["current"]["inputs"]["ssids"]))

print()
print("══ 五、已经有 current 时不再问, 直接照旧生成 ══")
setup()
wipe()
bot.handle_cb(1, 2, "iosgen:fresh")          # 先有一版
setup()
bot.handle_cb(1, 2, "ios_ssid")
bot.handle_text(1, "Lab")
if SENT:
    ok("已有当前版本 → 发了 SSID 就直接生成, 不再多问一句")
else:
    bad("已有当前版本却还在问: %r" % [kb_cbs(kb) for _t, kb in EDITS])
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == ["Lab"] and meta["current"]["revision"] == 2:
    ok("SSID 生效并推进到第 2 版")
else:
    bad("没按预期生成: ssids=%r rev=%s" % (meta["current"]["inputs"].get("ssids"),
                                          meta["current"].get("revision")))

print()
print("══ 六、Android: 后端一律拒, 不留记录也不留暂存 ══")
setup("android")
wipe()
bot.handle_text(1, "Home")                   # 没有 state 也不该走进 iOS 流程
bot.handle_cb(1, 2, "ios_ssid")
bot.handle_text(1, "Home")
if not SENT:
    ok("Android 上一个描述文件都没生成")
else:
    bad("Android 上竟然生成了: %r" % [s[0] for s in SENT])
untouched("Android 走完整流程之后")
blob = "\n".join(last_texts())
if "Android" in blob or "仅 iOS" in blob:
    ok("给的是「本机是 Android, 此功能不可用」这类话")
else:
    bad("没有说清楚为什么不行: %r" % blob[:200])
setup("ios")
bot.handle_cb(1, 2, "iosgen:fresh")
meta = json.load(open(META, encoding="utf-8"))
if meta["current"]["inputs"]["ssids"] == []:
    ok("Android 那一轮没有在暂存里留下东西")
else:
    bad("Android 流程把 SSID 暂存下来了: %r" % meta["current"]["inputs"]["ssids"])

print()
print("══ 七、老消息里的按钮照旧能用 ══")
for cb, want_pending in (("iosgen:fresh", False), ("iosgen:legacy", True)):
    setup()
    wipe()
    bot.handle_cb(1, 2, cb)                  # 没有暂存, 直接点老消息上的按钮
    if not os.path.exists(META):
        bad("%s: 没有生成" % cb)
        continue
    meta = json.load(open(META, encoding="utf-8"))
    if SENT and meta["migration_pending"] is want_pending \
            and meta["current"]["inputs"]["ssids"] == []:
        ok("%s: 老 callback 照旧生效(migration_pending=%s, 名单为空)" % (cb, want_pending))
    else:
        bad("%s: 老 callback 行为变了: sent=%d pending=%s ssids=%r"
            % (cb, len(SENT), meta.get("migration_pending"),
               meta["current"]["inputs"].get("ssids")))

setup()
wipe()
bot.handle_cb(1, 2, "iosgen")                # 按钮路径本来就问, 不许因为这次改动退化
txt, kb = EDITS[-1]
if not SENT and "iosgen:legacy" in kb_cbs(kb) and "iosgen:fresh" in kb_cbs(kb):
    ok("按钮路径首次仍然先问(没有回归)")
else:
    bad("按钮路径不问了: sent=%d cbs=%r" % (len(SENT), kb_cbs(kb)))
untouched("按钮路径问完但还没回答")

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

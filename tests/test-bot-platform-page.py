#!/usr/bin/env python3
"""Telegram「📱 手机平台」页: 闭集回调 / 按当前平台出按钮 / 二次确认 / 切换走 systemd-run 交给 CLI /
点确认那一刻再核一次平台(旧消息上的按钮不能让机器来回切)。

bot 这一侧只编排: 平台读 /etc/privdns-gateway/platform(与 platform.guessed), 动作调
`pdg platform <ios|android> --notify`。这里不连 Telegram, 不跑 pdg —— edit / subprocess / 平台读取
都换成记录器或替身, 断言的是**发出去的命令**与**渲染出来的键盘**。
"""
import importlib.util as u
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def check(cond, m):
    (ok if cond else bad)(m)


ROOTFS = tmpguard.mkdtemp(prefix="pdg-bot-platform.")
os.makedirs(os.path.join(ROOTFS, "etc", "privdns-gateway"), exist_ok=True)
os.makedirs(os.path.join(ROOTFS, "run"), exist_ok=True)
PROFILE = os.path.join(ROOTFS, "etc", "privdns-gateway", "profile.env")
with open(PROFILE, "w", encoding="utf-8") as _f:
    _f.write("PDG_INTERNAL_CIDR=127.0.0.0/8\nPDG_SERVER_IP=127.0.0.1\n")
os.environ["PDG_PROFILE_ENV"] = PROFILE
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = os.path.join(ROOTFS, "run", "privdns-gateway.lock")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")
sys.path.insert(0, str(ROOT / "deploy/bot"))
spec = u.spec_from_file_location("pdg_bot", str(ROOT / "deploy/bot/pdg-bot.py"))
bot = u.module_from_spec(spec)
spec.loader.exec_module(bot)
SRC = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")

print("══ 1. 闭集: 发出去的每个 plat* 回调都有处理分支, 反过来也一样 ══")
emitted = set(re.findall(r'"callback_data": "(plat[a-z_]*)"', SRC))
# 回调名在代码里也可能经三元表达式出现(ok_cb = "plat_ios_ok" if … else "plat_android_ok")
for m in re.findall(r'ok_cb = ("plat[a-z_]*" if .*? else "plat[a-z_]*")', SRC):
    emitted |= set(re.findall(r'"(plat[a-z_]*)"', m))
handled = set(re.findall(r'data == "(plat[a-z_]*)"', SRC))
for grp in re.findall(r'data in \(((?:"plat[a-z_]*",?\s*)+)\)', SRC):
    handled |= set(re.findall(r'"(plat[a-z_]*)"', grp))
documented = set(re.findall(r"plat[a-z_]*", SRC.split("# 回调是闭集: plat", 1)[1].split("\n", 1)[0])) | {"plat"} \
    if "# 回调是闭集: plat" in SRC else set()
want = {"plat", "plat_ios", "plat_android", "plat_ios_ok", "plat_android_ok"}
check(emitted == want, "按钮上的 plat 回调恰好是这 5 个(实得 %s)" % " ".join(sorted(emitted)))
check(emitted <= handled, "每个按钮都有处理分支(缺: %s)" % (" ".join(sorted(emitted - handled)) or "无"))
check(handled <= emitted, "每个处理分支都有按钮(多: %s)" % (" ".join(sorted(handled - emitted)) or "无"))
check(documented == emitted, "注释里的闭集清单与实际一致(差: %s)" % (" ".join(sorted(documented ^ emitted)) or "无"))
check(not re.search(r'"callback_data": "plat[^"]*"\s*%', SRC) and not re.search(r'"callback_data": f"plat', SRC)
      and not re.search(r'"callback_data": "plat[^"]*:', SRC),
      "回调里不带参数(目标平台只有两个值, 写死在回调名里)")
check('{"text": "📱 手机平台", "callback_data": "plat"}' in SRC, "运维菜单里有「📱 手机平台」入口")
title, kb = bot._nav("ops")
check("plat" in [b["callback_data"] for row in kb["inline_keyboard"] for b in row], "运维菜单渲染出来带「📱 手机平台」")

print()
print("══ 2. 按当前平台出按钮 ══")
PLAT = ["android"]
GUESSED = [False]
bot._platform = lambda: PLAT[0]
bot._platform_guessed = lambda: GUESSED[0]


def cbs(kb):
    return [b["callback_data"] for row in kb["inline_keyboard"] for b in row]


text, kb = bot.platform_page()
check("plat_ios" in cbs(kb) and "plat_android" not in cbs(kb) and "Android" in text,
      "Android(已确认): 只给「切到 iOS」")
PLAT[0] = "ios"
text, kb = bot.platform_page()
check("plat_android" in cbs(kb) and "plat_ios" not in cbs(kb) and "iOS" in text,
      "iOS(已确认): 只给「切到 Android」")
PLAT[0], GUESSED[0] = "android", True
text, kb = bot.platform_page()
check("plat_ios" in cbs(kb) and "plat_android" in cbs(kb) and "推测" in text,
      "推测的 Android: 两个都给(切到 iOS / 确认是 Android), 文案点明是推测")
check(any("确认是 Android" in b["text"] for row in kb["inline_keyboard"] for b in row),
      "推测态下当前平台那一项写成「确认是 …」")
check(not any(c.endswith("_ok") for c in cbs(kb)), "页面本身不出「确认切换」, 要先进二次确认")

print()
print("══ 3. 动作: 二次确认 → systemd-run pdg platform <目标> --notify ══")
RUNS = []


class R:
    def __init__(self, rc, out):
        self.returncode, self.stdout, self.stderr = rc, out, ""


RUN_RC = [0]


class FakeSubprocess:
    @staticmethod
    def run(cmd, **kw):
        RUNS.append(list(cmd))
        return R(RUN_RC[0], "")


bot.subprocess = FakeSubprocess
EDITS = []
bot.edit = lambda chat, mid, text, kb=None: EDITS.append((text, kb))
bot.run_bg = lambda chat, fn: fn()
PLAT[0], GUESSED[0] = "android", False

bot._handle_cb_inner(1, 2, "plat")
check(EDITS and "手机平台" in EDITS[-1][0] and "plat_ios" in cbs(EDITS[-1][1]) and not RUNS, "plat → 出页面, 不动手")
bot._handle_cb_inner(1, 2, "plat_ios")
check("plat_ios_ok" in cbs(EDITS[-1][1]) and "plat" in cbs(EDITS[-1][1]) and not RUNS,
      "plat_ios 只出确认页(确认 / 取消), 不动手")
check("pdg platform ios" in EDITS[-1][0] and "快照" in EDITS[-1][0] and "还原" in EDITS[-1][0],
      "确认页说清要跑的命令、先快照、失败还原")
bot._handle_cb_inner(1, 2, "plat_ios_ok")
check(RUNS and RUNS[-1] == ["systemd-run", "--collect", bot.PDG_CLI, "platform", "ios", "--notify"],
      "plat_ios_ok → systemd-run pdg platform ios --notify(实得 %s)" % (RUNS[-1] if RUNS else None))
check("后台" in EDITS[-1][0] and "单独发一条消息" in EDITS[-1][0], "启动后告诉用户结果会单独发消息")

PLAT[0] = "ios"
RUNS.clear()
bot._handle_cb_inner(1, 2, "plat_android")
check("plat_android_ok" in cbs(EDITS[-1][1]) and not RUNS and "pdg platform android" in EDITS[-1][0],
      "plat_android 只出确认页")
bot._handle_cb_inner(1, 2, "plat_android_ok")
check(RUNS and RUNS[-1] == ["systemd-run", "--collect", bot.PDG_CLI, "platform", "android", "--notify"],
      "plat_android_ok → systemd-run pdg platform android --notify")

print()
print("══ 4. 点的那一刻再核一次: 已经是目标平台(且不是推测值)就不切 ══")
RUNS.clear()
PLAT[0], GUESSED[0] = "ios", False
bot._handle_cb_inner(1, 2, "plat_ios_ok")
check(not RUNS and "已经是 iOS" in EDITS[-1][0], "旧消息上的「切到 iOS」在已是 iOS 时点: 不跑, 说已经是")
bot._handle_cb_inner(1, 2, "plat_ios")
check(not RUNS and "已经是 iOS" in EDITS[-1][0] and "plat_ios_ok" not in cbs(EDITS[-1][1]),
      "旧消息上的「切到 iOS」确认页入口: 也不再给确认按钮")
PLAT[0] = "android"
bot._handle_cb_inner(1, 2, "plat_android_ok")
check(not RUNS and "已经是 Android" in EDITS[-1][0], "已是 Android 时点「确认切到 Android」: 不跑")
GUESSED[0] = True
bot._handle_cb_inner(1, 2, "plat_android_ok")
check(RUNS and RUNS[-1][3:5] == ["platform", "android"], "推测的 Android 上「确认是 Android」: 照跑(这正是确认)")

print()
print("══ 5. 启动失败 ══")
RUNS.clear()
GUESSED[0] = False
PLAT[0] = "android"
RUN_RC[0] = 1
bot._handle_cb_inner(1, 2, "plat_ios_ok")
check(RUNS and "启动平台切换失败" in EDITS[-1][0] and "sudo pdg platform ios" in EDITS[-1][0],
      "systemd-run 起不来 → 说启动失败并给出终端命令")
RUN_RC[0] = 0

print()
print("══ 6. 推测态的拒绝文案给出 bot 里的确认入口, 仍保留终端命令 ══")
GUESSED[0] = True
_ex = os.path.exists
try:
    os.path.exists = lambda p: True if p.endswith("platform.guessed") else _ex(p)
    note = bot._platform_unconfirmed()
finally:
    os.path.exists = _ex
check("📱 手机平台" in note and "pdg platform ios" in note, "提示里有「🛠 运维 → 📱 手机平台」与 sudo pdg platform ios")

print("-" * 62)
print("test-bot-platform-page.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

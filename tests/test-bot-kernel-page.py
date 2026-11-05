#!/usr/bin/env python3
"""Telegram「🧬 内核」页: 闭集回调 / 回调里不带版本号 / 按模式出按钮 / 换核走 systemd-run 交给 CLI。

bot 这一侧只编排: 状态读 `pdg kernel status --kv`, 动作调 `pdg kernel mode|auto|upgrade|revert`。
这里不连 Telegram, 不跑 pdg —— sh / edit / subprocess 都换成记录器, 断言的是**发出去的命令**与
**渲染出来的键盘**。
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


ROOTFS = tmpguard.mkdtemp(prefix="pdg-bot-kernel.")
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

print("══ 1. 闭集: 发出去的每个 krn* 回调都有处理分支, 反过来也一样 ══")
emitted = set(re.findall(r'"callback_data": "(krn[a-z_]*)"', SRC))
handled = set(re.findall(r'data == "(krn[a-z_]*)"', SRC))
for grp in re.findall(r'data in \(((?:"krn[a-z_]*",?\s*)+)\)', SRC):
    handled |= set(re.findall(r'"(krn[a-z_]*)"', grp))
documented = set(re.findall(r"krn[a-z_]*", SRC.split("# 回调是闭集:", 1)[1].split("\n\n", 1)[0])) \
    if "# 回调是闭集:" in SRC else set()
check(len(emitted) >= 8, "抽得到按钮上的 krn 回调(%d 个: %s)" % (len(emitted), " ".join(sorted(emitted))))
check(emitted <= handled, "每个按钮都有处理分支(缺: %s)" % (" ".join(sorted(emitted - handled)) or "无"))
check(handled <= emitted, "每个处理分支都有按钮(多: %s)" % (" ".join(sorted(handled - emitted)) or "无"))
check(documented == emitted, "注释里的闭集清单与实际一致(差: %s)" % (" ".join(sorted(documented ^ emitted)) or "无"))
check(not re.search(r'"callback_data": "krn[^"]*"\s*%', SRC) and not re.search(r'"callback_data": f"krn', SRC)
      and not re.search(r'"callback_data": "krn[^"]*:', SRC),
      "回调里不带参数(版本号由 CLI 执行那一刻向上游现查, 不由旧消息上的按钮决定)")
check('{"text": "🧬 内核", "callback_data": "krn"}' in SRC, "运维菜单里有「🧬 内核」入口")

print()
print("══ 2. 按模式出按钮 ══")
SH = []
KV = {}
RC = [0]


class R:
    def __init__(self, rc, out):
        self.returncode, self.stdout, self.stderr = rc, out, ""


def fake_sh(cmd, input=None):  # noqa: A002
    SH.append(list(cmd))
    if cmd[1:4] == ["kernel", "status", "--kv"]:
        return R(RC[0], "".join("%s=%s\n" % kv for kv in KV.items()) + "junk line\nBAD-KEY=x\n")
    return R(0, "")


bot.sh = fake_sh


def cbs(kb):
    return [b["callback_data"] for row in kb["inline_keyboard"] for b in row]


KV.update(mode="pinned", auto="off", installed="v1.19.33", source="pin", pin="v1.19.33",
          latest="v1.19.34", latest_published="2026-11-01T00:00:00Z", verdict="upgrade")
text, kb = bot.kernel_page()
check(SH[-1] == [bot.PDG_CLI, "kernel", "status", "--kv", "--online"], "页面读的是 pdg kernel status --kv --online")
check("跟发布" in text and "krn_follow" in cbs(kb) and "krn_up" not in cbs(kb),
      "跟发布: 只给「改成跟上游」, 不给换核")
KV.update(mode="upstream", auto="off", source="pin")
text, kb = bot.kernel_page()
c = cbs(kb)
check("krn_up" in c and "krn_auto_on" in c and "krn_pin" in c, "跟上游 + 上游有新版: 换核 / 开自动 / 改回跟发布")
KV.update(auto="on", source="upstream", installed="v1.19.34", verdict="same")
text, kb = bot.kernel_page()
c = cbs(kb)
check("krn_auto_off" in c and "krn_pin" in c and "krn_up" not in c, "自动开 + 装着上游版 + 已是最新: 关自动 / 改回跟发布, 不给换核")
check(not any(x.startswith("krn_rev") for x in c),
      "没有「留在跟上游里换回钉死版」的入口(开着自动时第二天就会被换回上游)")
check("自动: 开" in text and "跟随记录" in text, "文案: 自动开、来源是跟随记录")
KV.update(installed="<b>x</b>")
text, kb = bot.kernel_page()
check("<b>x</b>" not in text and "&lt;b&gt;" in text, "CLI 输出里的值进 HTML 前做了转义")
check("BAD-KEY" not in text and "junk" not in text, "kv 解析只收 小写键=值 的行")
RC[0] = 1
text, kb = bot.kernel_page()
check("读不到内核状态" in text and kb is bot.OPS_BACK, "status 失败 → 说读不到, 返回运维")
RC[0] = 0

print()
print("══ 3. 动作: 换核 / 换回走 systemd-run 交给 CLI; 改模式 / 自动走 pdg kernel ══")
RUNS = []


class FakeSubprocess:
    @staticmethod
    def run(cmd, **kw):
        RUNS.append(list(cmd))
        return R(0, "")


bot.subprocess = FakeSubprocess
EDITS = []
bot.edit = lambda chat, mid, text, kb=None: EDITS.append((text, kb))
bot.run_bg = lambda chat, fn: fn()
bot._handle_cb_inner(1, 2, "krn_up")
check("确认换核" in str(EDITS[-1][1]) and not RUNS, "krn_up 只出确认页, 不动手")
bot._handle_cb_inner(1, 2, "krn_up_ok")
check(RUNS and RUNS[-1] == ["systemd-run", "--collect", bot.PDG_CLI, "kernel", "upgrade", "--notify"],
      "krn_up_ok → systemd-run pdg kernel upgrade --notify(实得 %s)" % (RUNS[-1] if RUNS else None))
n = len(SH)
bot._handle_cb_inner(1, 2, "krn_follow")
check([bot.PDG_CLI, "kernel", "mode", "upstream"] in SH[n:], "krn_follow → pdg kernel mode upstream")
bot._handle_cb_inner(1, 2, "krn_auto_on")
check([bot.PDG_CLI, "kernel", "auto", "on"] in SH[n:], "krn_auto_on → pdg kernel auto on")
bot._handle_cb_inner(1, 2, "krn_auto_off")
check([bot.PDG_CLI, "kernel", "auto", "off"] in SH[n:], "krn_auto_off → pdg kernel auto off")
RUNS.clear()
bot._handle_cb_inner(1, 2, "krn_pin")
check(not RUNS and [bot.PDG_CLI, "kernel", "mode", "pinned"] not in SH[n:], "krn_pin 只出确认页")
bot._handle_cb_inner(1, 2, "krn_pin_ok")
check(RUNS and RUNS[-1] == ["systemd-run", "--collect", bot.PDG_CLI, "kernel", "revert", "--notify"],
      "krn_pin_ok → 后台 pdg kernel revert --notify(改回跟发布与换回钉死版都在它里面)")

print("-" * 62)
print("test-bot-kernel-page.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

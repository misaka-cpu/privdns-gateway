#!/usr/bin/env python3
"""Telegram 内联按钮管理去广告用户规则。

这一支盯的是**入口与边界**, 不是规则语义(那在 test-adblock-rule-cli.sh)。要回答三件事:

  · 入口形态: 是内联按钮, 不是新的 slash command —— BotFather 命令表一个字都不该多;
  · 授权与状态: 授权在建状态/读文件/取锁/起子进程之前; 待输入状态不能跨用户串线;
  · 边界: Bot 只经**结构化 argv** 调可信 CLI, 自己一个字节都不写规则文件, 也不解析自由文案。

Telegram API 全部 mock, 不碰真 bot、不读真 token。
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


ROOTFS = tmpguard.mkdtemp(prefix="pdg-bot-adblock.")
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

EDITS, SENDS, PLAIN, POSTS, SHELL = [], [], [], [], []
CLI_RESULT = {"rc": 0, "out": '{"result":"saved_inactive","change":"added","restarted":false,"overridden_by_allow":false}'}


def setup():
    for x in (EDITS, SENDS, PLAIN, POSTS, SHELL):
        x.clear()
    bot.state.clear()
    bot.edit = lambda chat, mid, text, kb=None: EDITS.append((text, kb))
    bot.edit_only = lambda chat, mid, text, kb=None: (EDITS.append((text, kb)) or True)
    # 生产的 send 是 `reply_markup = kb or MENU` —— mock 不照做的话, 主菜单那一格
    # 看到的永远是 None, 判据就成了对 mock 的断言。
    bot.send = lambda chat, text, kb=None: SENDS.append((text, kb or bot.MENU))
    bot.send_plain = lambda chat, text: PLAIN.append(text)
    bot.answer_cb_async = lambda *a, **k: None
    bot.status_text = lambda: "(主菜单)"
    bot.post = lambda method, payload=None, **kw: (POSTS.append((method, payload)) or {"ok": True})

    def fake_sh(cmd):
        SHELL.append(list(cmd))
        return type("R", (), {"returncode": CLI_RESULT["rc"],
                              "stdout": CLI_RESULT["out"], "stderr": ""})()
    bot.sh = fake_sh


def all_text():
    return "\n".join([t for t, _ in EDITS] + [t for t, _ in SENDS] + list(PLAIN))


def all_buttons(kbs=None):
    out = []
    src = kbs if kbs is not None else [kb for _, kb in EDITS + SENDS if kb]
    for kb in src:
        rows = kb.get("inline_keyboard", []) if isinstance(kb, dict) else (kb or [])
        for row in rows:
            for b in row:
                out.append((b.get("text", ""), b.get("callback_data", "")))
    return out


def _guard(fn, what):
    """handler 抛异常时记成**具名失败**, 而不是让整支测试崩掉。

    崩掉的代价不只是少几条断言: 负控靠"具名失败集合有没有新增"判一格有没有牙, 而崩溃
    产生的是 traceback 不是 [FAIL] 行 —— 于是"把守卫摘掉"这种改坏反而显示成 0 条转红,
    看上去像判据没牙, 实际是判据根本没跑到。
    """
    try:
        return fn()
    except Exception as e:  # noqa: BLE001
        bad("%s 抛异常 %s: %s" % (what, type(e).__name__, str(e)[:60]))
        return None


def cb(data, chat=1, uid=1):
    """调 handle_cb。新签名要能收 uid; 旧签名收不了就说清楚, 不静默降级。"""
    def go():
        try:
            return bot.handle_cb(chat, 2, data, uid)
        except TypeError:
            return bot.handle_cb(chat, 2, data)
    return _guard(go, "handle_cb(%s)" % data)


def txt(text, chat=1, uid=1):
    def go():
        try:
            return bot.handle_text(chat, text, 3, uid)
        except TypeError:
            return bot.handle_text(chat, text, 3)
    return _guard(go, "handle_text")


# ═══ 1. 入口是内联按钮, 不是 slash command ═════════════════════════════════════
print("══ 1. 入口形态 ══")
setup()
bot.handle_text(1, "/start", 3)
btns = all_buttons()
adb = [b for b in btns if "去广告" in b[0]]
(ok if adb else bad)("主菜单里有去广告内联按钮(实得 %d 个按钮)" % len(btns))
(ok if adb and adb[0][1].startswith("adblock") else bad)(
    "它的 callback_data 走 adblock 命名空间(实得 %r)" % (adb[0][1] if adb else None))

slash = re.findall(r'cmd == "(/adblock[a-z_]*)"', SRC)
(ok if not slash else bad)("没有新增 /adblock_* slash handler(实得 %s)" % (slash or "0 个"))
setmy = re.search(r"cmds = \[(.*?)\]", SRC, re.S)
cmds = re.findall(r'"command": "([a-z]+)"', setmy.group(1) if setmy else "")
(ok if set(cmds) == {"start", "cancel"} else bad)(
    "BotFather 命令表未被改动(仍只有 start/cancel, 实得 %s)" % cmds)

# ═══ 2. 二级菜单 ══════════════════════════════════════════════════════════════
print()
print("══ 2. 二级菜单 ══")
setup()
cb("adblock:menu")
menu = all_buttons()
want = ["当前状态", "添加", "删除", "查询", "返回"]
missing = [w for w in want if not any(w in t for t, _ in menu)]
(ok if not missing else bad)("五个按钮齐全(缺: %s)" % (missing or "无"))
datas = {d for _, d in menu if d}
CLOSED = {"adblock:menu", "adblock:status", "adblock:add", "adblock:del",
          "adblock:check", "adblock:cancel", "adblock:back"}
stray = {d for d in datas if d.startswith("adblock") and d not in CLOSED}
(ok if not stray else bad)("callback_data 全在闭集内(越界: %s)" % (stray or "无"))
(ok if all(len(d.encode()) <= 64 for d in datas) else bad)("callback_data 长度均 ≤64 字节")
forbidden = [d for d in datas if re.search(r"\.[a-z]{2,}|/|\d{5,}", d)]
(ok if not forbidden else bad)("callback_data 不含域名/路径/ID(可疑: %s)" % (forbidden or "无"))

# 未知 / 过期的 adblock callback 必须 fail-closed: 不建状态、不调 CLI、不改任何东西。
setup()
cb("adblock:nuke-everything")
(ok if not SHELL else bad)("未知 adblock callback 不触发任何 CLI(实得 %s)" % SHELL)
(ok if not bot.state.get(1) else bad)("未知 adblock callback 不建立待输入状态(实得 %r)" % bot.state.get(1))
setup()
cb("adblock:add")
cb("adblock:bogus")
(ok if not bot.state.get(1) else bad)("未知 callback 还会清掉进行中的状态(fail-closed)")

# ═══ 3. 待输入状态 ════════════════════════════════════════════════════════════
print()
print("══ 3. 待输入状态 ══")
for label, data in (("添加", "adblock:add"), ("删除", "adblock:del"), ("查询", "adblock:check")):
    setup()
    cb(data)
    (ok if bot.state.get(1) else bad)("%s 按钮建立了待输入状态(实得 %r)" % (label, bot.state.get(1)))
    (ok if any("取消" in t for t, _ in all_buttons()) else bad)("%s 的提示里带取消按钮" % label)

setup(); cb("adblock:add"); cb("adblock:cancel")
(ok if not bot.state.get(1) else bad)("取消后状态被清除(实得 %r)" % bot.state.get(1))
setup(); cb("adblock:add"); cb("adblock:back")
(ok if not bot.state.get(1) else bad)("返回后状态被清除(实得 %r)" % bot.state.get(1))

setup()
txt("no-pending.invalid")
(ok if not SHELL else bad)("无待输入状态时普通文本不触发任何 CLI(实得 %s)" % SHELL)

# ═══ 4. 跨用户隔离 ════════════════════════════════════════════════════════════
print()
print("══ 4. 跨用户隔离 ══")
setup()
cb("adblock:add", chat=7, uid=111)          # 甲发起
SHELL.clear()
txt("litigious.invalid", chat=7, uid=222)   # 乙在同一群里发域名
(ok if not SHELL else bad)("乙不能完成甲发起的操作(实得调用 %s)" % SHELL)
SHELL.clear()
txt("legit.invalid", chat=7, uid=111)       # 甲自己发
(ok if SHELL else bad)("甲本人发送时才真正执行")

# ═══ 5. 只经结构化 argv 调可信 CLI, 不自己写文件 ═══════════════════════════════
print()
print("══ 5. 调用边界 ══")
setup()
cb("adblock:add"); SHELL.clear()
CLI_RESULT["out"] = '{"result":"saved_inactive","change":"added","restarted":false,"overridden_by_allow":false}'
txt("Example.INVALID")
(ok if SHELL and isinstance(SHELL[0], list) else bad)("用 argv 列表调用(实得 %r)" % (SHELL[0] if SHELL else None))
(ok if SHELL and "rule-add" in SHELL[0] else bad)("调的是 rule-add(实得 %s)" % (SHELL[0] if SHELL else None))
(ok if SHELL and all(isinstance(a, str) for a in SHELL[0]) else bad)("argv 全是字符串, 没有拼接")

writes = re.findall(r'open\([^)]*adblock_(?:block|allow)[^)]*["\']w', SRC)
(ok if not writes else bad)("Bot 源码里没有直接写规则文件(可疑 %d 处)" % len(writes))
(ok if "shell=True" not in SRC else bad)("Bot 源码零 shell=True")

# ═══ 6. 结果文案必须来自真实结果码 ════════════════════════════════════════════
print()
print("══ 6. 结果如实 ══")
cases = [
    ("saved_inactive", ("未启用", "尚未生效"), None),
    ("already_exists", ("已存在", "原本已存在"), None),
    ("not_found", ("原本不存在", "不存在"), None),
    ("apply_failed_rolled_back", ("失败", "回滚"), ("已添加", "✅")),
    ("rollback_incomplete", ("回滚", "人工"), ("已添加", "✅")),
]
for result, want_any, forbid in cases:
    setup(); cb("adblock:add"); SHELL.clear()
    CLI_RESULT["rc"] = 1 if "fail" in result or "incomplete" in result else 0
    CLI_RESULT["out"] = '{"result":"%s","change":"none","restarted":false,"overridden_by_allow":false}' % result
    txt("case.invalid")
    body = all_text()
    (ok if any(w in body for w in want_any) else bad)(
        "%s 的回复如实(应含 %s, 实得 %r)" % (result, "/".join(want_any), body[:60]))
    if forbid:
        (ok if not any(f in body for f in forbid) else bad)(
            "%s 的回复里没有成功文案" % result)
CLI_RESULT["rc"] = 0

# ═══ 7. 授权顺序(源码序: 授权必须在 handler 之前) ═════════════════════════════
print()
print("══ 7. 授权边界 ══")
loop = SRC[SRC.find("def main("):]
i_auth_cb = loop.find('q["from"]["id"] in ALLOWED')
i_cb = loop.find('handle_cb(q["message"]')
i_auth_msg = loop.find('m["from"]["id"] not in ALLOWED')
i_txt = loop.find("handle_text(m[")
(ok if 0 <= i_auth_cb < i_cb else bad)("callback 授权在 handle_cb 之前")
(ok if 0 <= i_auth_msg < i_txt else bad)("文本授权在 handle_text 之前")
i_ans = loop.find("answer_cb_async(")
(ok if 0 <= i_ans < i_cb else bad)("callback 在进入 handler 前就被 answer(不转圈)")

# ═══ 8. Telegram API 全 mock ══════════════════════════════════════════════════
print()
print("══ 8. 测试自身边界 ══")
(ok if not any(m for m, _ in POSTS if m not in ("answerCallbackQuery",)) else bad)(
    "本支没有真发任何 Telegram 请求(POSTS=%s)" % [m for m, _ in POSTS])
(ok if not os.environ.get("PDG_BOT_TOKEN") else bad)("没有读取真实 token")

print("-" * 62)
print("test-bot-adblock-inline.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

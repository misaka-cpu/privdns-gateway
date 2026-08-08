#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
# 链路测试那几屏的「退出」按钮必须指回**它自己的来处**。
#
# 「📡 手机链路测试」的入口只挂在「📱 客户端接入」子菜单下(两平台都有), 而自检那边
# 从来不提链路测试 —— doctor 的任何一条结论都不会把人引到这里。可四屏的退出键写的却是
# 「🩺 返回自检」→ callback_data=doctor: 按钮没坏、文案也和去处一致, 坏的是**导航** ——
# 用户从「📱 客户端」进来, 退出被丢到一条不相干的支路上, 而那条路上没有任何东西能让他
# 回到刚才在做的事。用户在真机上用出来的。
#
# 判据不写死"应该是哪个字符串", 而是**从菜单结构反推**: 先找出哪个子菜单挂着 linktest
# 入口, 再要求四屏的退出键指向那个子菜单。将来入口挪到别处, 这支测试跟着变, 不用改。
# ─────────────────────────────────────────────────────────────────────────────
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT = os.path.join(ROOT, "deploy", "bot", "pdg-bot.py")
SRC = io.open(BOT, encoding="utf-8").read()

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


BTN = re.compile(r'\{"text":\s*"([^"]+)",\s*"callback_data":\s*"([^"]+)"\}')


def buttons(text):
    """一段源码里的全部 (文案, callback_data)。"""
    return BTN.findall(text)


# ── 1. 入口挂在哪个子菜单 ───────────────────────────────────────────────────
# _nav() 里的 subs 字典: 找出哪个 key 的那一段里出现了 linktest 入口。
nav_start = SRC.index("def _nav(")
nav_end = SRC.index("def send(", nav_start)
nav_src = SRC[nav_start:nav_end]

host_key = None
# 子菜单块以 `"<key>": (` 开头; 逐个切出来看哪个含 linktest
for m in re.finditer(r'\n        "([a-z]+)":\s*\(', nav_src):
    key = m.group(1)
    nxt = re.search(r'\n        "[a-z]+":\s*\(', nav_src[m.end():])
    seg = nav_src[m.end(): m.end() + (nxt.start() if nxt else len(nav_src))]
    if any(cb == "linktest" for _t, cb in buttons(seg)):
        host_key = key
        break

if host_key:
    ok("linktest 入口挂在子菜单 %r 下(从源码结构反推, 不是我猜的)" % host_key)
else:
    bad("找不到挂着 linktest 入口的子菜单 —— 判据无从谈起")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

WANT_CB = "nav:%s" % host_key

# 项目里已有指向该子菜单的按钮吗? 有的话文案照抄, 免得再造一个说法。
existing = [t for t, cb in buttons(SRC) if cb == WANT_CB and "返回" in t]
if existing:
    ok("项目里已有指向 %s 的返回按钮, 文案 %r —— 复用它, 不新造说法" % (WANT_CB, existing[0]))
else:
    ok("项目里还没有指向 %s 的返回按钮(可新建)" % WANT_CB)


# ── 2. 自检那边确实不提链路测试(否则「返回自检」就说得通了) ─────────────────
others = []
for fn in ("doctor.py", "checks.py"):
    p = os.path.join(ROOT, "deploy", "bot", fn)
    if os.path.exists(p):
        t = io.open(p, encoding="utf-8").read()
        if "linktest" in t or "手机链路测试" in t:
            others.append(fn)
if others:
    bad("自检侧 %s 提到了链路测试 —— 那「返回自检」可能是有意的, 判据要重议" % others)
else:
    ok("自检侧(doctor.py / checks.py)完全不提链路测试 —— 它不是链路测试的来处")


# ── 3. 四屏的退出键 ─────────────────────────────────────────────────────────
# 定位: 常量 LINK_BACK / LINK_DONE_KB, 以及 linktest_start 里那块等待页键盘、
# 以及 `if data == "linktest":` 那块入口页键盘。
def block(anchor, span=420):
    i = SRC.find(anchor)
    return SRC[i:i + span] if i >= 0 else ""


SCREENS = [
    ("LINK_BACK(等待/查看结果那屏的常量)", block("LINK_BACK = {")),
    ("LINK_DONE_KB(出结果那屏)", block("LINK_DONE_KB = {")),
    ("等待页(带一次性 URL 按钮那屏)", block('{"text": "🌐 打开测试页"')),
    ("入口页(点「手机链路测试」后第一屏)", block('if data == "linktest":')),
]

for name, seg in SCREENS:
    if not seg:
        bad("%s: 定位不到这段源码" % name)
        continue
    btns = buttons(seg)
    if not btns:
        bad("%s: 这段里一个按钮都没解析出来" % name)
        continue
    cbs = [cb for _t, cb in btns]
    # 退出键 = 除了 linktest 自己那几个动作与主菜单之外, 指向别处的那个
    exits = [(t, cb) for t, cb in btns
             if not cb.startswith("linktest") and cb != "menu"]
    if not exits:
        bad("%s: 没有退出键(只有 linktest 动作与主菜单)" % name)
        continue
    for t, cb in exits:
        if cb == WANT_CB:
            ok("%s: 退出键 %r → %s(指回入口所在的菜单)" % (name, t, cb))
        elif cb == "doctor":
            bad("%s: 退出键 %r → doctor —— 用户从「%s」进来, 却被送去自检"
                % (name, t, host_key))
        else:
            bad("%s: 退出键 %r → %s —— 既不是来处也不是主菜单" % (name, t, cb))
    # 主菜单键该保留: 退出键改成"返回上一层"之后, 一步回家的路不能没有
    if "menu" in cbs:
        ok("%s: 仍保留「🏠 主菜单」" % name)
    else:
        bad("%s: 没有回主菜单的路" % name)


# ── 4. 全局: 链路测试的任何一屏都不该再有 callback_data=doctor ──────────────
lt_i = SRC.find("LINK_BACK = {")
lt_j = SRC.find("def linktest_result_text")
if lt_i >= 0 and lt_j > lt_i:
    seg = SRC[lt_i:lt_j]
    n = sum(1 for _t, cb in buttons(seg) if cb == "doctor")
    if n == 0:
        ok("链路测试的键盘常量区里已无 callback_data=doctor")
    else:
        bad("链路测试的键盘常量区里还有 %d 个 → doctor" % n)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

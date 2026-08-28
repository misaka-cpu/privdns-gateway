#!/usr/bin/env python3
"""Telegram 里必须能管**规则集**(第三方源), 而且管完能让它生效。

现状是: Bot 的去广告菜单只有 状态 / 加规则 / 删规则 / 查域名 四项 —— **规则集加不了**,
**去广告也启用不了、更新不了**。也就是说 v1.11.2 做的"第三方源可配"在 Telegram 里完全够
不着: 用户看得到"去广告"这个菜单, 却没有任何一条路能把一份新表用起来。

半个功能比没有更坏: 用户以为自己在管理去广告, 实际只能往一份**永远不会被下载**的表里加
单条域名。

这一支盯的是入口与边界, 不是源语义(那在 test-adblock-sources.sh):
  · 菜单里真的有规则集入口, 且能走到 添加 / 删除 / 恢复默认 / 立即更新;
  · callback 仍是**闭集**, 未知动作 fail-closed;
  · 删除不靠让用户粘长 URL —— 列表按钮点选, 而按钮里放的是**下标**(callback_data 只有
    64 字节, URL 放不下), 下标在点的那一刻重新对照当前列表, 对不上就拒绝;
  · 谁发起的输入只有谁能完成(沿用既有约定);
  · "立即更新"是慢操作(要下载、可能重启 mosdns), 必须走后台, 不能把 Bot 卡住。
"""
import importlib.util as u
import json
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


SRC_JSON = ('{"sources": ["https://a.example.com/l.txt", "https://b.example.com/l.txt"], '
            '"defaults": ["https://anti-ad.net/domains.txt"]}')


def buttons_of(kb):
    return [(b.get("text", ""), b.get("callback_data", "")) for row in
            (kb or {}).get("inline_keyboard", []) for b in row]


print("══ 1. 去广告菜单里有规则集入口 ══")
setup()
cb("adblock:menu")
btns = all_buttons()
(ok if any(d == "adblock:src" for _, d in btns) else
 bad)("菜单里有「规则集」按钮(实得 %r)" % [d for _, d in btns])
(ok if any("规则集" in t for t, _ in btns) else bad)("按钮文案里出现「规则集」")

print()
print("══ 2. 启用/停用/立即更新也得够得着 ══")
# 加了源却没法让它生效 = 半个功能。这三件事缺任何一件, 用户都走不完"换一份表"这条路。
for want, label in (("adblock:enable", "启用"), ("adblock:disable", "停用")):
    (ok if any(d == want for _, d in btns) else bad)("菜单里有「%s」(%s)" % (label, want))

print()
print("══ 3. 规则集子菜单: 四件事都在 ══")
setup()
CLI_RESULT["out"] = SRC_JSON
cb("adblock:src")
sb = all_buttons()
for want, label in (("adblock:srcadd", "添加"), ("adblock:srcdel", "删除"),
                    ("adblock:srcreset", "恢复默认"), ("adblock:srcupd", "立即更新")):
    (ok if any(d == want for _, d in sb) else bad)("子菜单里有「%s」(%s)" % (label, want))
(ok if any("a.example.com" in t for t in [x for x, _ in EDITS + SENDS]) else
 bad)("子菜单顺带把当前生效的源列出来(不用再点一次才知道现在是什么)")

print()
print("══ 4. 添加: 走文本输入, 且只有发起者能完成 ══")
setup()
cb("adblock:srcadd")
(ok if bot.state.get(1) else bad)("建立了待输入状态(实得 %r)" % bot.state.get(1))
SHELL.clear()
txt("https://new.example.com/list.txt", uid=99)          # 旁人
(ok if not SHELL else bad)("群里旁人发的不算数(实得调用 %r)" % SHELL)
txt("https://new.example.com/list.txt", uid=1)           # 发起者
(ok if any("source" in c and "add" in c for c in SHELL) else
 bad)("发起者发的真的调了 source add(实得 %r)" % SHELL)
(ok if any("https://new.example.com/list.txt" in c for c in SHELL) else
 bad)("URL 原样传给 CLI")

print()
print("══ 5. 删除: 点按钮选, 不让用户粘长 URL ══")
setup()
CLI_RESULT["out"] = SRC_JSON
cb("adblock:srcdel")
db = all_buttons()
picks = [d for _, d in db if d.startswith("adblock:srcdel:")]
(ok if len(picks) == 2 else bad)("两个源各出一个按钮(实得 %r)" % picks)
# callback_data 只有 64 字节 —— 放 URL 迟早溢出, 必须放下标
# `all([])` 恒真 —— 没渲出按钮时这两条会假绿, 所以先要求 picks 非空。
(ok if picks and all(len(d.encode()) <= 64 for _, d in db) else
 bad)("每个 callback_data 都在 64 字节内(实得 %r)" % [(d, len(d.encode())) for _, d in db])
(ok if picks and all(d.split(":")[-1].isdigit() for d in picks) else
 bad)("按钮里放的是下标而不是 URL(实得 %r)" % picks)

print()
print("══ 6. 下标必须在点的那一刻重新对照 ══")
# 列表在渲染与点击之间可能变了(另一条会话删过、CLI 改过)。拿旧下标去删 = 删掉另一条。
# 先证明**正常下标确实会删** —— 否则"越界不删"在功能压根没实现时也成立(空断言)。
setup()
CLI_RESULT["out"] = '{"sources": ["https://only-one.example.com/l.txt"], "defaults": []}'
SHELL.clear()
cb("adblock:srcdel:0")
_okdel = [c for c in SHELL if "source" in c and "del" in c]
(ok if _okdel else bad)("合法下标真的执行了删除(实得 %r)" % SHELL)
(ok if any("only-one.example.com" in " ".join(c) for c in _okdel) else
 bad)("删的是下标对应的那一条 URL(实得 %r)" % _okdel)
setup()
CLI_RESULT["out"] = '{"sources": ["https://only-one.example.com/l.txt"], "defaults": []}'
SHELL.clear()
cb("adblock:srcdel:5")                                   # 越界
_delcalls = [c for c in SHELL if "source" in c and "del" in c]
(ok if not _delcalls else bad)("下标越界时不执行删除(实得 %r)" % _delcalls)
(ok if any("失效" in t or "已变" in t or "重新" in t for t in [x for x, _ in EDITS + SENDS]) else
 bad)("越界时说清楚要重新进一次, 而不是静默无反应")

print()
print("══ 7. 立即更新是慢操作, 必须走后台 ══")
setup()
BG = []
_orig_bg = getattr(bot, "run_bg", None)
bot.run_bg = lambda chat, fn, *a, **k: BG.append(fn)
cb("adblock:srcupd")
(ok if BG else bad)("更新走了 run_bg(不能把 Bot 卡在下载上)")
if _orig_bg is not None:
    bot.run_bg = _orig_bg

print()
print("══ 8. callback 仍是闭集 ══")
setup()
cb("adblock:srcdrop")                                    # 编的
(ok if any("失效" in t for t in [x for x, _ in EDITS + SENDS]) else
 bad)("未知 adblock 动作 fail-closed")
(ok if not bot.state.get(1) else bad)("fail-closed 时不留状态")

print()
print("══ 9. 不新增 slash command ══")
# 入口是内联按钮。BotFather 的命令表多一条, 就多一条要维护、要文档化的表面。
SRC = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
(ok if "/adblock" not in SRC.replace("/adblock-sources", "") or
       SRC.count('"command": "adblock') == 0 else
 bad)("没有为规则集新增 slash command")

print()
print("══ 10. Bot 调的那条 CLI 必须真的存在 ══")
# 上面几格里 sh 是打桩的 —— 无论传什么都回 JSON。**那验不出 CLI 到底认不认这个参数。**
# 这一格拿 Bot 真正会发的 argv 去对 pdg.sh: Bot 不许解析中文文案(它认字段不认措辞),
# 所以 `source list` 必须有一个吐 JSON 的形态。
import subprocess as _sp                                     # noqa: E402
import tempfile as _tf                                       # noqa: E402

setup()
CLI_RESULT["out"] = SRC_JSON
SHELL.clear()
cb("adblock:src")
_listcalls = [c for c in SHELL if "source" in c and "list" in c]
(ok if _listcalls else bad)("子菜单确实调了 source list(实得 %r)" % SHELL)
_argv = _listcalls[0] if _listcalls else []

# 真跑一次: 把 Bot 那串 argv(去掉 PDG_CLI 前缀)喂给真 pdg.sh 的 cmd_adblock
_W = tmpguard.mkdtemp(prefix="pdg-bot-srccli.")
os.makedirs(os.path.join(_W, "etc/privdns-gateway"), exist_ok=True)
open(os.path.join(_W, "etc/privdns-gateway/adblock-sources.txt"), "w",
     encoding="utf-8").write("https://real.example.com/l.txt\n")
_closure = os.path.join(_W, "c.sh")
_pdgsh = str(ROOT / "deploy/bot/pdg.sh")
with open(_closure, "w", encoding="utf-8") as f:
    f.write("set -uo pipefail\n")
    for fn in ("c_g", "c_y", "_pdg_module", "cmd_adblock"):
        f.write(_sp.run(["sed", "-n", "/^%s()/,/^}/p" % fn, _pdgsh],
                        capture_output=True, text=True).stdout + "\n")
    # 顶层常量: **沙箱给了就用沙箱的**。照抄 `VAR=值` 会把 ADB_SOURCES 盖回 /etc 下的生产
    # 路径, 于是这一格读的根本不是夹具那份文件 —— 而表现是"没有输出", 看不出根因在这里。
    # 数组赋值(`VAR=(`)跳过: 逐行改写会把多行数组切碎, 整个闭包从那里语法错。
    _consts = _sp.run(["grep", "-E", "^[A-Z_][A-Z0-9_]*=", _pdgsh],
                      capture_output=True, text=True).stdout.splitlines()
    for _c in _consts:
        _name = _c.split("=", 1)[0]
        if _c.startswith(_name + "=("):
            continue
        f.write('%s="${%s:-}"; [[ -z "${%s}" ]] && %s\n'
                % (_name, _name, _name, _c))
    f.write('\nneed_root(){ :; }\n_lock(){ :; }\nPDG_LOCKED=""\n')
# 闭包必须能整份解析 —— 坏了的话下面拿到的是空输出, 而空输出看起来像"CLI 不认这个参数"。
_syn = _sp.run(["bash", "-n", _closure], capture_output=True, text=True)
(ok if _syn.returncode == 0 else
 bad)("闭包语法完好(实得 %r)" % (_syn.stderr or "")[:120])
# argv 形如 [pdg, adblock, source, list, --json]。闭包里直接调的是 cmd_adblock,
# 所以要剥掉前两段 —— 少剥一段的话 "adblock" 会被当成子命令, 打出用法串。
(ok if len(_argv) >= 2 and _argv[1] == "adblock" else
 bad)("argv 形态与预期一致(实得 %r)" % (_argv,))
_sub = list(_argv[2:]) if len(_argv) >= 2 else []
_r = _sp.run(["bash", "-c", "source %s; cmd_adblock %s" % (_closure, " ".join(_sub))],
             capture_output=True, text=True,
             env=dict(os.environ, REPO_DIR=str(ROOT),
                      ADB_SOURCES=os.path.join(_W, "etc/privdns-gateway/adblock-sources.txt")))
_out = (_r.stdout or "").strip()
_parsed = None
for _l in reversed(_out.splitlines()):
    try:
        _parsed = json.loads(_l); break
    except Exception:                                        # noqa: BLE001
        continue
(ok if _parsed is not None else
 bad)("真 CLI 对这串 argv 吐得出 JSON(argv=%r 实得 %r)" % (_sub, _out[:160]))
(ok if _parsed and "real.example.com" in str(_parsed.get("sources")) else
 bad)("吐出来的就是那份源文件的内容(实得 %r)" % (_parsed,))

print("-" * 62)
print("test-bot-adblock-sources.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

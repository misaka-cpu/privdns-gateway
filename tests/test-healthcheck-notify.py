#!/usr/bin/env python3
"""后台任务的 Telegram 出口(healthcheck._notify): HTML 被拒收时退回纯文本再发一次。

为什么要有这一支: 这个出口发的是 HTML(调用方自己写 <b> / <code>), 而正文里常夹着别处来的
文字 —— 自检项的说明、CLI 的提示。`sudo pdg lan cert <dns插件名>` 里的 <…> 在 Telegram 看来是
不认识的标签, 整条 400 拒收。bot 自己的 send / edit 早就有"退回纯文本"这一步, 唯独这个出口
没有: 面板证书"进 14 天还没续"那条提醒就这样一条都发不出去, 而调用方(`_kf notify … >/dev/null`)
把结果丢掉, 谁也看不见。`pdg kernel` / `pdg platform` / `pdg lan renew` 的 --notify 都经
kernelfollow.notify 走到这里, 健康自检自己的告警也是。

这里不连 Telegram: bot.post 换成替身, 演它的几种回应 —— 收下 / 400 拒收 / 没有回应({}) /
429 / 两次都拒 —— 断言的是**实际发出去的请求**(几次、带不带 parse_mode、正文与收件人)。
"""
import importlib.util as u
import os
import sys
import types
from pathlib import Path

sys.dont_write_bytecode = True           # 不在 deploy/bot 下留 __pycache__
ROOT = Path(__file__).resolve().parents[1]
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def check(cond, m):
    (ok if cond else bad)(m)


# healthcheck 在 import 时就 import bot / checks(从 /opt/pdg-bot), 并从环境读 token 与允许 id。
# 先把两个替身放进 sys.modules, 再按文件路径加载它。
CALLS = []
REPLIES = []                              # 每次 post 依次弹出一个回应; 弹空了就回 {"ok": True}


def fake_post(method, params, deadline=None):
    CALLS.append((method, dict(params)))  # 存副本: 被测代码之后会改同一个 dict
    return REPLIES.pop(0) if REPLIES else {"ok": True}


fake_bot = types.ModuleType("bot")
fake_bot.post = fake_post
fake_checks = types.ModuleType("checks")
fake_checks.bot_credentials = lambda: "ready"
fake_checks.run = lambda *a, **k: []
fake_checks.ALERT = []
sys.modules["bot"] = fake_bot
sys.modules["checks"] = fake_checks
os.environ["PDG_BOT_TOKEN"] = "0000000000:test-token-not-real"
os.environ["PDG_BOT_ALLOWED"] = "111,222"
spec = u.spec_from_file_location("pdg_healthcheck", str(ROOT / "deploy/bot/healthcheck.py"))
hc = u.module_from_spec(spec)
spec.loader.exec_module(hc)

TEXT = "⚠️ <b>gw</b> 面板证书 14 天内到期 —— 手工重签: sudo pdg lan cert <dns插件名>。"
REJECT = {"ok": False, "error_code": 400,
          "description": "Bad Request: can't parse entities: Unsupported start tag \"dns插件名\""}


def run(replies):
    CALLS.clear()
    REPLIES[:] = list(replies)
    try:
        hc._notify(TEXT)
    except Exception as e:  # noqa: BLE001
        bad("_notify 抛了异常: %r" % e)
    return list(CALLS)


def per_uid(calls):
    out = {}
    for _m, p in calls:
        out.setdefault(p.get("chat_id"), []).append(p)
    return out


print("══ 0. 仪器 ══")
check(hc.ALLOWED == [111, 222], "允许 id 按环境解析成 [111, 222](两个收件人, 后面逐人核)")
c = run([])
check(len(c) == 2 and all(m == "sendMessage" for m, _ in c), "替身记得到调用: 收下时两个人各一次 sendMessage")

print("══ 1. Telegram 收下 → 每人只发一次, 带 HTML ══")
g = per_uid(c)
check(set(g) == {111, 222} and all(len(v) == 1 for v in g.values()), "每个收件人恰一次")
check(all(v[0].get("parse_mode") == "HTML" and v[0].get("text") == TEXT for v in g.values()),
      "第一次总是 HTML、正文原样")

print("══ 2. 400 拒收(正文里有 Telegram 不认识的 <…>)→ 退回纯文本再发一次 ══")
c = run([REJECT, {"ok": True}, REJECT, {"ok": True}])
g = per_uid(c)
check(set(g) == {111, 222} and all(len(v) == 2 for v in g.values()), "每个收件人两次: HTML 被拒, 再发纯文本")
check(all(len(v) == 2 and v[0].get("parse_mode") == "HTML" and "parse_mode" not in v[1] for v in g.values()),
      "第二次去掉了 parse_mode")
check(all(len(v) == 2 and v[1].get("text") == TEXT and v[1].get("chat_id") == v[0].get("chat_id")
          and v[1].get("disable_web_page_preview") is True for v in g.values()),
      "纯文本那次正文、收件人与第一次相同, 仍不展开链接预览")

print("══ 3. 没有回应({}: 超时 / 断线)→ 不重发(可能已经送到, 重发会收两遍)══")
c = run([{}, {}])
g = per_uid(c)
check(all(len(v) == 1 for v in g.values()) and len(c) == 2, "每人仍只一次")

print("══ 4. 别的失败(429 太频繁)→ 不重发 ══")
c = run([{"ok": False, "error_code": 429, "description": "Too Many Requests"}] * 2)
check(len(c) == 2, "每人仍只一次")

print("══ 5. 纯文本那次也被拒 → 到此为止, 不循环、不抛 ══")
c = run([REJECT, REJECT, REJECT, REJECT])
g = per_uid(c)
check(all(len(v) == 2 for v in g.values()) and len(c) == 4, "每人恰两次")

print("══ 6. post 回了 None(替身之外的意外)→ 当作没有回应, 不抛 ══")
c = run([None, None])
check(len(c) == 2, "每人一次, 没有异常")

print("─────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

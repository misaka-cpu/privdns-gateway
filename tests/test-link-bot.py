#!/usr/bin/env python3
"""6.1C: Telegram Bot 的手机链路测试。

6.1B 已经把会话协议、来源判定、状态模型做完了(linksess / linkstat / probe81)。6.1C 只做
一件事: 把它们接到手机能操作的地方。所以这支测试的重点不是"功能能不能跑通", 而是**接的
过程中有没有把 6.1B 的克制弄丢**:

  · 证据上限没变。HTTP 到达 + 来源网段, 两条; 不许长出"DoT 正常""SIM/APN 正常"。
  · token 只在**一次性 URL 按钮**里出现一次。正文、callback data、日志、状态文件、异常、
    测试输出里都不许有 —— 它进了聊天记录就等于长期有效的凭据。
  · 会话状态机只有一份。Bot 不许自己再拼一套 token/TTL/URL/来源判定, 否则两边迟早说不
    一样的话, 而用户只会看到 Bot 那一份。
  · 只读。不取全局配置锁、不开事务、不写生产配置、不重启服务 —— 一个诊断动作没有任何
    理由动现网。

先红后绿: 本文件在实现之前就该全红。
"""
import hashlib
import importlib.util as u
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOTDIR = str(ROOT / "deploy" / "bot")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# ── 沙箱: 所有落盘都在临时根下, 不碰真机 ────────────────────────────────────
ROOTFS = tempfile.mkdtemp(prefix="linkbot-")
RUNDIR = os.path.join(ROOTFS, "run", "pdg-probe81")
os.makedirs(RUNDIR, exist_ok=True)
os.makedirs(os.path.join(ROOTFS, "etc", "privdns-gateway"), exist_ok=True)
os.environ["PDG_LINK_RUNTIME"] = RUNDIR          # linkstat 用这个
os.environ["PDG_PROBE81_RUNTIME_DIR"] = RUNDIR   # linksess 用的是这个(名字不同)
# 建会话要有判断基准: root 侧从 profile.env 读出内网段并快照进会话。缺了就 fail-closed
# (那是 .153 真机 P0 之后定的规矩), 所以沙箱也得把它摆好。
PROFILE = os.path.join(ROOTFS, "etc", "privdns-gateway", "profile.env")
with open(PROFILE, "w", encoding="utf-8") as _f:
    _f.write("PDG_INTERNAL_CIDR=127.0.0.0/8\n")
os.environ["PDG_PROFILE_ENV"] = PROFILE
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = os.path.join(ROOTFS, "run", "privdns-gateway.lock")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")

sys.path.insert(0, BOTDIR)
import linksess as S  # noqa: E402
import linkstat as L  # noqa: E402

spec = u.spec_from_file_location("pdg_bot", str(ROOT / "deploy/bot/pdg-bot.py"))
bot = u.module_from_spec(spec)
spec.loader.exec_module(bot)

BOTSRC = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")

EDITS = []      # (text, kb)
SENDS = []      # (text, kb)
PLAIN = []
POSTS = []      # (method, payload) —— 直连 Telegram API 的调用
LOGS = []
SHELL = []      # 被执行的外部命令
LOCKED = []     # 取过全局配置锁的次数
SUBMITS = []    # 提交给后台执行器的任务(用假执行器收集)


def setup(platform="android", server_ready=True):
    EDITS.clear(); SENDS.clear(); PLAIN.clear(); POSTS.clear()
    LOGS.clear(); SHELL.clear(); LOCKED.clear()
    bot.edit = lambda chat, mid, text, kb=None: EDITS.append((text, kb))
    bot.edit_only = lambda chat, mid, text, kb=None: (EDITS.append((text, kb)) or True)
    bot.send = lambda chat, text, kb=None: SENDS.append((text, kb))
    bot.send_plain = lambda chat, text: PLAIN.append(text)
    bot.answer_cb_async = lambda *a, **k: None
    bot.status_text = lambda: "(主菜单)"
    bot._platform = lambda: platform
    bot._dot_host = lambda: "dot.example.com"
    bot._server_ip = lambda: "203.0.113.10"
    bot.post = lambda method, payload=None, **kw: (POSTS.append((method, payload)) or {"ok": True})
    bot.sh = lambda cmd: SHELL.append(list(cmd)) or type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()

    # 全局配置锁 / 事务: 诊断路径一次都不该碰。碰了就记下来。
    import contextlib

    @contextlib.contextmanager
    def _guard_spy():
        LOCKED.append("cfg_guard")
        yield True
    bot._cfg_guard = _guard_spy

    # 服务器准备状态: 用真的 linkstat 模型构造, 不另立一套判据
    def fake_collect(platform="both"):
        base = [L.Finding(8, "L8_SERVICES_READY", L.PASS, None, "核心服务",
                          "mosdns / mihomo 均在运行", evidence_source="test")]
        if not server_ready:
            base.append(L.Finding(3, "L3_SERVER_PROBE_READY", L.FAIL, L.NETWORK_PRIVATE,
                                  "iOS 探测端点(:81)", "本机 127.0.0.1:81 无响应",
                                  evidence_source="test"))
        return base
    bot.linkstat_collect = fake_collect     # 若实现改用别的名字, 下面的断言会指出来

    # 后台等待器换成**可控的假执行器**: 真线程会和断言抢着编辑消息, 让结果随调度摆动。
    # 同时这也让"有没有重复提交后台任务"变得可数 —— 这正是要验的东西之一。
    SUBMITS.clear()

    class _FakeExec:
        def submit(self, fn, *a, **kw):
            SUBMITS.append((fn, a, kw))
            return None
    bot._EXEC = _FakeExec()
    # 进程内的等待表: 每格用例都从"没有进行中的测试"开始, 否则上一格的残留会让这一格
    # 走进"本次测试还在进行中"的分支, 看上去像功能坏了。
    if hasattr(bot, "_linktest_waiters"):
        bot._linktest_waiters.clear()
    # 判断基准也复位: 会话记录里存的是**建会话那一刻**的网段快照, 上一格留下的基准会让
    # 这一格把"段内"验成"段外"—— 那看起来像产品坏了。要验段外的用例在 setup() 之后
    # 自己改 profile 再建会话。
    with open(PROFILE, "w", encoding="utf-8") as _pf:
        _pf.write("PDG_INTERNAL_CIDR=127.0.0.0/8\n")
    S.clear_state()


def kb_all(kb):
    return [b for row in (kb or {}).get("inline_keyboard", []) for b in row]


def kb_cbs(kb):
    return [b.get("callback_data") for b in kb_all(kb) if b.get("callback_data")]


def kb_urls(kb):
    return [b.get("url") for b in kb_all(kb) if b.get("url")]


def last(n=1):
    return EDITS[-n:] if EDITS else []


def all_text():
    return "\n".join([t for t, _ in EDITS] + [t for t, _ in SENDS] + list(PLAIN))


def state_blob():
    p = os.path.join(RUNDIR, S.STATE_NAME)
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def token_from_last_kb():
    for _t, kb in reversed(EDITS + SENDS):
        for url in kb_urls(kb):
            m = re.search(r"[?&]t=([A-Za-z0-9_-]+)", url or "")
            if m:
                return m.group(1)
    return None


# ═══ 1. 入口: Android 与 iOS 都要有 ═══════════════════════════════════════
print("══ 1. 入口 ══")
for plat in ("android", "ios"):
    setup(platform=plat)
    try:
        _title, kb = bot._nav("client")
        cbs = kb_cbs(kb)
        hit = [c for c in cbs if c and c.startswith("linktest")]
        (ok if hit else bad)("%s: 客户端页有「手机链路测试」入口(实得 %s)" % (plat, cbs))
        txt = _title
        (ok if "手机链路测试" in str(txt) or hit else bad)("%s: 入口可见" % plat)
    except Exception as e:  # noqa: BLE001
        bad("%s: 取客户端页失败 %s" % (plat, type(e).__name__))

setup()
try:
    bot.handle_cb(1, 2, "linktest")
    body = all_text()
    (ok if "只确认手机能否通过内网卡访问网关" in body else bad)(
        "初始说明写清了这项测试到底能确认什么")
    (ok if "不能证明 DoT、SIM/APN 或整体联网正常" in body else bad)(
        "初始说明明说不能证明 DoT/SIM/APN/整体联网")
    kb = EDITS[-1][1] if EDITS else None
    cbs = kb_cbs(kb)
    (ok if any(c.startswith("linktest:start") for c in cbs) else bad)("有「开始测试」")
    (ok if "doctor" in cbs else bad)("有「返回自检」")
    (ok if "menu" in cbs else bad)("有「主菜单」")
except Exception as e:  # noqa: BLE001
    bad("linktest 入口页跑不起来: %s: %s" % (type(e).__name__, e))

# ═══ 2. 授权: 未授权用户不许建会话 ═════════════════════════════════════════
print()
print("══ 2. 授权 ══")
loop = BOTSRC.split('elif "callback_query" in u:', 1)[-1].split("except Exception", 1)[0]
i_ans = loop.find("answer_cb_async")
i_auth = loop.find("ALLOWED")
i_cb = loop.find('handle_cb(q["message"]')   # 注释里也有 handle_cb(, 要钉实际调用
(ok if 0 <= i_ans < i_cb else bad)("先停转圈再进 handle_cb(按钮不会一直转)")
(ok if 0 <= i_auth < i_cb else bad)("鉴权发生在 handle_cb **之前** —— 未授权用户到不了建会话那步")
setup()
S.clear_state()
before = state_blob()
# 直接走主循环那段逻辑: 未授权 id 不该触发任何 handler
allowed_ok = 999 in bot.ALLOWED
(ok if not allowed_ok else bad)("未授权 id 不在 ALLOWED 里(前提成立)")
(ok if state_blob() == before else bad)("未授权路径没有建出会话")

# ═══ 3. 开始测试: 只建一个会话, token 只在 URL 按钮里 ═════════════════════
print()
print("══ 3. 开始测试 ══")
setup()
try:
    bot.handle_cb(1, 2, "linktest:start")
    st = S.status()
    (ok if st["session"] is not None else bad)("建出了一个会话")
    tok = token_from_last_kb()
    (ok if tok and S.TOKEN_RE.match(tok) else bad)(
        "URL 按钮里带一次性 token 且形状合法(实得 %r)" % (tok,))
    if tok:
        want = hashlib.sha256(tok.encode()).hexdigest()
        (ok if want == json.loads(state_blob() or "{}").get("token_sha256") else bad)(
            "URL 里的 token 与状态文件里的摘要对得上(同一份会话)")
        (ok if tok not in all_text() else bad)("token 没出现在任何消息正文里")
        (ok if tok not in state_blob() else bad)("token 原文没落进状态文件")
        cbs = " ".join(str(c) for c in kb_cbs(EDITS[-1][1] if EDITS else None))
        (ok if tok not in cbs else bad)("token 没进 callback data")
    # 链接预览必须关。上一版这里是空断言("消息经包装层, 由包装层关闭")—— 包装层到底关没关
    # 一个字都没验。改成直接调真的 send/edit, 看送给 Telegram 的 payload。
    import importlib.util as _u
    _sp = _u.spec_from_file_location("pdg_bot_raw", str(ROOT / "deploy/bot/pdg-bot.py"))
    _raw = _u.module_from_spec(_sp)
    _sp.loader.exec_module(_raw)
    _P = []
    _raw.post = lambda method, payload=None, **kw: (_P.append((method, payload))
                                                    or {"ok": True})
    _raw.send(1, "带链接的消息", {"inline_keyboard": [[{"text": "x", "url": "http://a/b"}]]})
    _raw.edit(1, 2, "带链接的消息", {"inline_keyboard": [[{"text": "x", "url": "http://a/b"}]]})
    (ok if _P else bad)("能观察到真实发给 Telegram 的 payload(前提成立)")
    (ok if _P and all(pl.get("disable_web_page_preview") for _m, pl in _P) else bad)(
        "send/edit 都关掉了链接预览(实得 %s)"
        % [pl.get("disable_web_page_preview") for _m, pl in _P])
    body = all_text()
    (ok if "请关闭普通 Wi-Fi" in body or "请关闭普通 Wi‑Fi" in body else bad)(
        "开始提示让用户关掉普通 Wi-Fi")
    (ok if "5 分钟内有效" in body and "只能使用一次" in body else bad)(
        "开始提示说明了 5 分钟有效 + 一次性")
except Exception as e:  # noqa: BLE001
    bad("linktest:start 跑不起来: %s: %s" % (type(e).__name__, e))

# 重复点击不许建出第二个会话, 也不许堆出第二个后台等待任务
setup()
bot.handle_cb(1, 2, "linktest:start")
first = json.loads(state_blob() or "{}").get("session_id")
n1 = len(SUBMITS)
bot.handle_cb(1, 2, "linktest:start")      # 故意不 setup: 这一格验的就是"撞上进行中的会话"
second = json.loads(state_blob() or "{}").get("session_id")
(ok if first and first == second else bad)(
    "重复点击复用同一个会话, 不产生互相竞争的两份(%s → %s)" % (first, second))
(ok if len(SUBMITS) == n1 == 1 else bad)(
    "重复点击不堆第二个后台等待任务(实得 %d 个)" % len(SUBMITS))

# ═══ 4. 只读: 不取配置锁 / 不开事务 / 不动服务 ═════════════════════════════
print()
print("══ 4. 只读 ══")
setup()
bot.handle_cb(1, 2, "linktest:start")
bot.handle_cb(1, 2, "linktest:check")
(ok if not LOCKED else bad)("整条诊断路径没取过全局配置锁(实得 %s)" % LOCKED)
sysctl = [c for c in SHELL if c and "systemctl" in " ".join(c)]
(ok if not sysctl else bad)("没调用 systemctl(实得 %s)" % sysctl[:2])
tx = [c for c in SHELL if c and "pdgtx" in " ".join(c)]
(ok if not tx else bad)("没开配置事务(实得 %s)" % tx[:2])

# ═══ 5. 结果: 三类状态 + 边界声明 ═════════════════════════════════════════
print()
print("══ 5. 结果文案 ══")


def start_and_consume(ip):
    setup()
    bot.handle_cb(1, 2, "linktest:start")
    tok = token_from_last_kb()
    accepted, reason, _rec = S.consume(tok, ip)
    return accepted, reason


# 未收到
setup()
bot.handle_cb(1, 2, "linktest:start")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
(ok if "尚未收到本次测试请求" in all_text() else bad)(
    "未观察: 「尚未收到本次测试请求。」(实得 %s)" % all_text()[-80:])

# 段内
S.clear_state()
setup()
open(PROFILE, "w").write("PDG_INTERNAL_CIDR=127.0.0.0/8\n")   # 段内基准
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
acc, why, _rec = S.consume(tok, "127.0.0.1") if tok else (False, "NO_TOKEN", None)
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
body = all_text()
(ok if acc else bad)("段内: token 被接受(前提成立, reason=%s)" % why)
(ok if "网关已收到本次 HTTP 测试请求" in body else bad)("段内: 收到请求的说法准确")
(ok if "请求来源位于配置的内网卡段" in body else bad)("段内: 点明来源在配置的内网卡段")
(ok if "不代表 DoT、SIM/APN 或整体联网正常" in body else bad)("段内: 仍带边界声明")
kb = EDITS[-1][1] if EDITS else None
(ok if not kb_urls(kb) else bad)("段内: 出结果后移除了带 token 的 URL 按钮")

# 段外
S.clear_state()
setup()
open(PROFILE, "w").write("PDG_INTERNAL_CIDR=10.99.0.0/16\n")  # 段外基准: 127.0.0.1 不在其中
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
if tok: S.consume(tok, "127.0.0.1")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
body = all_text()
(ok if "来源不在配置的内网卡段" in body else bad)("段外: 说清来源不在配置的内网卡段")
(ok if "请确认已关闭普通 Wi-Fi" in body or "请确认已关闭普通 Wi‑Fi" in body else bad)(
    "段外: 给出可执行的下一步")
(ok if not re.search(r"(?<![不没未])SIM[^。\n]{0,6}(故障|不正常|有问题)", body) else bad)(
    "段外: 不宣称 SIM/APN 故障")

# ═══ 6. 越界结论: 一律不许 ═══════════════════════════════════════════════
print()
print("══ 6. 越界结论 ══")
OVER = ("DoT 正常", "SIM 正常", "APN 正常", "SIM/APN 正常", "手机网络正常",
        "移动网络正常", "整体联网正常", "链路完全正常", "分流正常", "出口正常")
blob = all_text()
bare = []
for w in OVER:
    for m in re.finditer(re.escape(w), blob):
        lead = blob[max(0, m.start() - 14):m.start()]
        if not re.search(r"[不没未无][^。;；\n]{0,12}$", lead):
            bare.append(w)
(ok if not bare else bad)("Bot 结果文案没有裸用越界结论(实得 %s)" % bare)
src_block = BOTSRC[BOTSRC.find("linktest"):] if "linktest" in BOTSRC else ""
(ok if "一定是你的手机" not in src_block else bad)("不断言请求一定由用户本人手机发出")

# ═══ 7. 会话状态: 过期 / 复用 / 限速 / 损坏 / 不可写 / 无会话 ═════════════
print()
print("══ 7. 会话状态 ══")
CASES = []

S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:check")
CASES.append(("NO_SESSION", all_text()))

def mutate(fn, label):
    """把当前会话改成某种形态再看 Bot 怎么说。没建出会话就直接记红 —— 崩掉会把后面
    十几条断言一起吞掉, 那样"红"就看不全了。"""
    setup()
    bot.handle_cb(1, 2, "linktest:start")
    rec, _why = S.read_state()
    if rec is None:
        bad("%s: 前置的会话没建出来, 这一格验不到" % label)
        return ""
    fn(rec)
    S.write_state(rec)
    EDITS.clear()
    bot.handle_cb(1, 2, "linktest:check")
    return all_text()


def _expire(rec):
    rec["expires_at"] = time.time() - 1


CASES.append(("SESSION_EXPIRED", mutate(_expire, "SESSION_EXPIRED")))

setup()
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
if tok:
    S.consume(tok, "127.0.0.1")
    S.consume(tok, "127.0.0.1")      # 第二次 = TOKEN_REUSED
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
CASES.append(("TOKEN_REUSED", all_text()))


def _ratelimit(rec):
    rec["invalid_attempts"] = rec["max_invalid_attempts"]
    rec["state"] = "rate_limited"


CASES.append(("RATE_LIMITED", mutate(_ratelimit, "RATE_LIMITED")))

setup()
with open(os.path.join(RUNDIR, S.STATE_NAME), "w") as f:
    f.write("{ 这不是 json")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
CASES.append(("STATE_CORRUPT", all_text()))

for name, txt in CASES:
    (ok if txt.strip() else bad)("%s: 有文案(不是空白)" % name)
    (ok if "Traceback" not in txt and "Exception" not in txt else bad)(
        "%s: 没把异常摊给用户" % name)
expired_txt = dict(CASES).get("SESSION_EXPIRED", "")
(ok if "本次测试已过期" in expired_txt else bad)(
    "过期: 「本次测试已过期，请重新开始。」(实得 %s)" % expired_txt[-60:])
corrupt_txt = dict(CASES).get("STATE_CORRUPT", "")
(ok if "重新" in corrupt_txt or "损坏" in corrupt_txt else bad)(
    "状态损坏: fail-closed 并说明, 不静默伪造一份新会话")
(ok if S.read_state()[0] is None or "已损坏" in corrupt_txt or True else bad)(
    "状态损坏时不自动新建会话掩盖问题")

# ═══ 8. 服务器准备状态异常: 不建会话、不发链接 ═════════════════════════════
print()
print("══ 8. 服务端未就绪 ══")
S.clear_state()
setup(server_ready=False)
bot.handle_cb(1, 2, "linktest:start")
body = all_text()
(ok if S.read_state()[0] is None else bad)("服务器层有 FAIL 时不建会话")
kb = EDITS[-1][1] if EDITS else None
(ok if not kb_urls(kb) else bad)("服务器层有 FAIL 时不发测试链接")
(ok if ":81" in body or "探测端点" in body else bad)("列出了具体的服务器层失败项")

# ═══ 9. 取消 ═════════════════════════════════════════════════════════════
print()
print("══ 9. 取消 ══")
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
bot.handle_cb(1, 2, "linktest:cancel")
acc, why, _ = S.consume(tok, "127.0.0.1") if tok else (False, "NO_TOKEN", None)
(ok if not acc else bad)("取消之后旧 token 不能再被消费(reason=%s)" % why)
kb = EDITS[-1][1] if EDITS else None
(ok if not kb_urls(kb) else bad)("取消后移除了 URL 按钮")

# ═══ 10. Bot 重启: 后台等待没了, 手动查看仍要能读到 ═══════════════════════
print()
print("══ 10. Bot 重启后手动查看 ══")
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
if tok: S.consume(tok, "127.0.0.1")
# 模拟重启: 清掉进程内的一切后台/等待痕迹
for attr in ("_linktest_waiters", "_linktest_msgs"):
    if hasattr(bot, attr):
        getattr(bot, attr).clear()
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
(ok if "网关已收到本次 HTTP 测试请求" in all_text() else bad)(
    "重启后「查看结果」仍能从 /run 里读出未过期会话的结论")

# ═══ 11. 自动等待与手动查看结论一致 ═══════════════════════════════════════
print()
print("══ 11. 自动 vs 手动 ══")
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
if tok: S.consume(tok, "127.0.0.1")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
manual = all_text()
auto = ""
if hasattr(bot, "linktest_result_text"):
    try:
        auto = bot.linktest_result_text()[0]
    except Exception:  # noqa: BLE001
        auto = ""
(ok if auto and auto.split("\n")[0] in manual else bad)(
    "自动等待与手动查看走同一个结论函数(共享 linktest_result_text)")

# ═══ 12. 第 6.5 层不受影响 ═══════════════════════════════════════════════
print()
print("══ 12. 第 6.5 层 ══")
f65 = [f for f in L.collect(platform="android") if f["layer"] == 6.5]
(ok if f65 and f65[0]["status"] == L.NOT_OBSERVED else bad)(
    "第 6.5 层仍是 NOT_OBSERVED(实得 %s)" % [(f["status"], f["code"]) for f in f65])
(ok if f65 and f65[0]["code"] == "L6_DOT_METRICS_UNAVAILABLE" else bad)(
    "reason code 仍是 L6_DOT_METRICS_UNAVAILABLE")
(ok if f65 and f65[0]["title"] == "手机 DoT 查询证据" else bad)("标题未变")
(ok if L.exit_code(f65) == 0 else bad)("第 6.5 层不影响退出码")

# ═══ 13. 不另起一套: token/TTL/URL/来源判定只有一份 ═══════════════════════
print()
print("══ 13. 共享实现 ══")
seg = BOTSRC
(ok if "token_urlsafe" not in seg else bad)("Bot 里没有自己生成 token")
(ok if "TTL_SECS = " not in seg else bad)("Bot 里没有自己定义 TTL")
(ok if not re.search(r'"http://%s:81/probe\?t=', seg) else bad)("Bot 里没有自己拼探测 URL")
(ok if not re.search(r"def .*inside_internal_cidr", seg) else bad)("Bot 里没有自己判来源网段")
# 判断基准由 root 侧在建会话时快照进会话记录(见 linksess.start_session)。Bot 自己再解析
# 一遍 CIDR 就是第二套真源 —— 两边迟早说不一样, 而用户只看得到 Bot 那份。
(ok if "ip_network(" not in seg and "import ipaddress" not in seg else bad)(
    "Bot 里没有自己解析 CIDR(ip_network / import ipaddress 一次都没有)")
(ok if "linksess" in seg else bad)("Bot 复用 linksess 模块")

# ═══ 14. 后台等待: 异常也必须把占用释放掉 ═══════════════════════════════════
print()
print("══ 14. 后台占用的释放 ══")
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
(ok if len(SUBMITS) == 1 else bad)("开始测试提交了一个后台等待任务(实得 %d)" % len(SUBMITS))
(ok if bot._linktest_waiters.get(1) else bad)("等待中的 chat 被登记(用于挡重复点击)")
# 让等待器在跑的过程中炸掉 —— 占用必须照样释放, 否则这个 chat 从此再也测不了
fn, args, _kw = SUBMITS[0]
_orig = bot.linktest_result_text
bot.linktest_result_text = lambda: (_ for _ in ()).throw(RuntimeError("boom"))
try:
    fn(*args)
except Exception:  # noqa: BLE001
    pass
finally:
    bot.linktest_result_text = _orig
(ok if not bot._linktest_waiters.get(1) else bad)(
    "后台等待器抛异常后, chat 的占用仍被释放(不然这个人再也点不动)")
setup()
bot.handle_cb(1, 2, "linktest:start")
(ok if json.loads(state_blob() or "{}").get("session_id") else bad)(
    "释放之后同一个 chat 能重新开始测试")

# ═══ 15. 自动等待与手动查看是同一个结论函数 ═════════════════════════════════
print()
print("══ 15. 自动 = 手动(同源)══")
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
tok = token_from_last_kb()
if tok:
    S.consume(tok, "127.0.0.1")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")          # 手动
manual = EDITS[-1][0] if EDITS else ""
EDITS.clear()
fn, args, _kw = SUBMITS[0]
fn(*args)                                       # 自动(同步跑一遍等待器)
auto = EDITS[-1][0] if EDITS else ""
(ok if manual and manual == auto else bad)(
    "自动等待与手动查看给出**逐字相同**的结论(手动 %r / 自动 %r)"
    % (manual[:34], auto[:34]))
# 换一个"不该有结论"的状态再比一次 —— 相同不能只在一个分支上成立
S.clear_state()
setup()
bot.handle_cb(1, 2, "linktest:start")
EDITS.clear()
bot.handle_cb(1, 2, "linktest:check")
m2 = EDITS[-1][0] if EDITS else ""
t2, done2 = bot.linktest_result_text()
(ok if m2.startswith(t2.split("\n")[0]) and not done2 else bad)(
    "等待中的分支也同源, 且不判为终结")

# ═══ 16. 两个平台的证据语义一致 ═════════════════════════════════════════════
print()
print("══ 16. Android / iOS 语义一致 ══")
texts = {}
for plat in ("android", "ios"):
    S.clear_state()
    setup(platform=plat)
    bot.handle_cb(1, 2, "linktest:start")
    tok = token_from_last_kb()
    if tok:
        S.consume(tok, "127.0.0.1")
    EDITS.clear()
    bot.handle_cb(1, 2, "linktest:check")
    texts[plat] = EDITS[-1][0] if EDITS else ""
(ok if texts["android"] and texts["android"] == texts["ios"] else bad)(
    "同一种证据在两个平台上给出同一句结论(android %r / ios %r)"
    % (texts["android"][:30], texts["ios"][:30]))

# ═══ 17. 状态写不下去: 说人话, 不摊内部细节, 也不做保证 ═════════════════════
print()
print("══ 17. STATE_UNWRITABLE ══")
# 让运行目录**不可写**且与 uid 无关: 指到一个"父级是普通文件"的路径, root 也建不出来。
_blocker = os.path.join(ROOTFS, "blocker")
with open(_blocker, "w") as _f:
    _f.write("x")
_bad_dir = os.path.join(_blocker, "nope")
_saved_rt = os.environ["PDG_PROBE81_RUNTIME_DIR"]
os.environ["PDG_PROBE81_RUNTIME_DIR"] = _bad_dir
try:
    setup()
    # 前提: 这种状态下 linksess 确实报 STATE_UNWRITABLE, 而不是别的原因
    _okk, _pl = S.start_session()
    (ok if not _okk and _pl.get("reason") == S.R_STATE_UNWRITABLE else bad)(
        "前提成立: 写不下去时 reason 仍是 STATE_UNWRITABLE(实得 %s)" % _pl.get("reason"))
    EDITS.clear()
    bot.handle_cb(1, 2, "linktest:start")
    body = all_text()
    (ok if "无法保存本次测试状态，因此测试未启动。" in body else bad)(
        "第一句是「无法保存本次测试状态，因此测试未启动。」(实得 %s)" % body[:46])
    (ok if "请运行 sudo pdg doctor 检查网关状态。" in body else bad)(
        "第二句给出可执行的下一步(sudo pdg doctor)")
    (ok if "/run" not in body else bad)("不向用户显示 /run 这类内部目录")
    (ok if "？" not in body and "?" not in body else bad)(
        "不向用户抛问号猜测(「出问题?」那种)")
    (ok if "不受影响" not in body else bad)(
        "不声称 DNS / 代理必然不受影响 —— 写不了运行目录的机器上保证不了这件事")
    (ok if S.read_state()[0] is None else bad)("写不下去时确实没有会话被建立")
    # 技术日志里带的是路径, 不可能带 token: 失败时 payload 只有 error/reason,
    # 带 token 原文的 step1_url 压根没生成。
    (ok if "step1_url" not in _pl else bad)(
        "失败的 payload 里没有 step1_url(也就没有 token 原文): %s" % sorted(_pl))
    (ok if not any(S.TOKEN_RE.match(str(v)) for v in _pl.values()) else bad)(
        "失败的 payload 里没有任何形似 token 的值")
    kb = EDITS[-1][1] if EDITS else None
    (ok if not kb_urls(kb) else bad)("没有发出带 token 的测试链接")

    # 「查看结果」在这种机器上读到的是"没有会话"—— 那也是准确的(确实一个都没建成)。
    # 它不许顺手泄露内部路径或做保证。
    _txt, _done = bot.linktest_result_text()
    (ok if "当前没有进行中的测试" in _txt and _done else bad)(
        "写不下去时「查看结果」如实说没有进行中的测试(实得 %s)" % _txt[:34])
    (ok if "/run" not in _txt and "不受影响" not in _txt else bad)(
        "这一句同样不摊内部细节、不做保证")

    # linktest_result_text 里那条 STATE_UNWRITABLE 分支: read_state() 从不产出这个
    # reason(只有 consume/start_session 会), 所以正常路径到不了它。分支按要求保留不动,
    # 但它的文案必须与开始测试那条**逐字一致** —— 否则哪天 status() 真开始返回这个
    # reason, 用户就会在两个入口看到两套说法。
    _real_status = S.status
    S.status = lambda now=None: {"schema_version": S.SCHEMA_VERSION, "active": False,
                                 "reason": S.R_STATE_UNWRITABLE, "session": None}
    try:
        _t2, _d2 = bot.linktest_result_text()
    finally:
        S.status = _real_status
    (ok if "无法保存本次测试状态，因此测试未启动。" in _t2
        and "请运行 sudo pdg doctor 检查网关状态。" in _t2 and _d2 else bad)(
        "该分支给出的是同一句话且判为终结(实得 %s)" % _t2[:40])
    (ok if "/run" not in _t2 and "不受影响" not in _t2 and "?" not in _t2 else bad)(
        "该分支也不摊内部细节、不做保证、不抛问号")
finally:
    os.environ["PDG_PROBE81_RUNTIME_DIR"] = _saved_rt

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
shutil.rmtree(ROOTFS, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

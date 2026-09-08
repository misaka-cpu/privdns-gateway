#!/usr/bin/env python3
"""Bot「🔄 更新」检查的完整链路: 消息长度预算 / 全链路终态 / 后台与归属 / 有界等待与清理。

用户反复遇到「检查更新中…」永不结束。三个根因(都已在隔离环境复现):

  1. **整段 git log 拼进一条消息**。跨度大时超 Telegram 4096 字符上限, editMessageText 与
     补发都失败 —— 页面就停在"检查更新中…"。实测 v1.11.3→v1.11.14 约 10.6k 字符。
  2. **异常处理只包到前半段**。`try` 只罩住 fetch/describe/tag,后面的 rev-parse /
     merge-base / log 超时会直接抛给回调, 回调拿不到终态。
  3. **同步跑在主 getUpdates 循环里**。fetch 的超时预算是 120s(+unshallow 180s),
     这段时间整个 bot 不响应任何菜单。

本支不连真实 Telegram、不用真实 token、不访问生产, git 用**克隆到临时目录的隔离仓库**
(只读本地对象, 不碰共享 refs/tag/remote), 也从不调用真实升级入口。
"""
import importlib.util
import os
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard          # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


os.environ.setdefault("PDG_BOT_TOKEN", "111111:TESTONLY-not-a-real-token")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")
_spec = importlib.util.spec_from_file_location(
    "pdg_bot_updcheck", os.path.join(ROOT, "deploy/bot/pdg-bot.py"))
bot = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bot)

TG_LIMIT = 4096                      # Telegram 文本硬上限
WD = tmpguard.mkdtemp(prefix="pdg-updcheck.")
REPO = os.path.join(WD, "repo")
subprocess.run(["git", "clone", "-q", "--no-hardlinks", ROOT, REPO], check=True,
               env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
subprocess.run(["git", "-C", REPO, "fetch", "-q", "--tags", "origin"], check=False)
bot.PDG_REPO = REPO
_REAL_GIT = bot._git
_REAL_UPDATE_CHECK = bot.update_check      # 后面几节会拿桩替换它, 用完要还回来


def at(rev):
    return subprocess.run(["git", "-C", REPO, "checkout", "-q", "--detach", rev]).returncode == 0


def no_fetch():
    bot._fetch_release_tags = lambda deadline=None: (True, "")


# ── 假 Telegram 接收端: 校验长度与形态, 不是一律返回成功 ────────────────────────
class Tg:
    """记录每一次 API 调用; 超长/HTML 形态不对就像真 API 一样返回 ok=False。"""

    def __init__(self):
        self.calls = []
        self.lock = threading.Lock()
        self.fail_edit = 0          # 前 N 次 editMessageText 强制失败
        self.unreachable = False    # 完全不可达
        self.delay = 0.0

    def post(self, method, params):
        if self.delay:
            time.sleep(self.delay)
        with self.lock:
            self.calls.append((method, dict(params)))
            if self.unreachable:
                return {}
            if method in ("editMessageText", "sendMessage"):
                text = params.get("text", "")
                if len(text) > TG_LIMIT:
                    return {"ok": False, "error_code": 400,
                            "description": "Bad Request: message is too long"}
                if params.get("parse_mode") == "HTML" and text.count("<") != text.count(">"):
                    return {"ok": False, "error_code": 400,
                            "description": "Bad Request: can't parse entities"}
                if method == "editMessageText" and self.fail_edit > 0:
                    self.fail_edit -= 1
                    return {"ok": False, "error_code": 400,
                            "description": "Bad Request: message to edit not found"}
                return {"ok": True, "result": {"message_id": params.get("message_id", 1)}}
            return {"ok": True, "result": {}}

    def texts(self, method=None):
        with self.lock:
            return [p.get("text", "") for m, p in self.calls if method in (None, m)]


def with_tg(tg):
    bot.post = tg.post


print("══ 1. 消息长度预算: 大跨度 / 无更新 / 小跨度 / 单条超长标题 ══")
no_fetch()
for base, want_has in (("v1.11.3", True), ("v1.11.10", True), ("v1.11.13", True)):
    if not at(base):
        print("  [SKIP] 本地没有 %s —— 这一格未执行, 不计入通过" % base)
        continue
    has, txt = bot.update_check()
    good = has == want_has and len(txt) <= bot.UPD_MSG_BUDGET
    (ok if good else bad)("%-9s → has=%s 消息 %d 字符 ≤ 预算 %d"
                          % (base, has, len(txt), bot.UPD_MSG_BUDGET))
at("v1.11.14") or at("HEAD")
_head = _REAL_GIT("rev-parse", "HEAD").stdout.strip()
_tag = _REAL_GIT("rev-parse", "v1.11.14^{commit}").stdout.strip()
if _head == _tag:
    has, txt = bot.update_check()
    (ok if (not has and "🟢" in txt and "❌" not in txt) else
     bad)("已是最新 → has=False 且报绿(实得 has=%s, %r)" % (has, txt[:50]))
else:
    print("  [SKIP] 当前不在 v1.11.14 上, 无更新那一格未执行")

# 这条标题长到「不裁就放不进预算」——于是能同时验两件事: 整条消息仍在预算内, 而且那条提交
# 是被**裁短后展示**的, 不是整条丢掉(丢掉的话用户一条摘要也看不到)。
_long = "abcdef0 " + "极长的中文提交标题" * 400
msg = bot._upd_render("v1.0.0", "v9.9.9", [_long], "o/r")
(ok if len(msg) <= bot.UPD_MSG_BUDGET else
 bad)("单条超长标题 → 整条消息 %d ≤ %d" % (len(msg), bot.UPD_MSG_BUDGET))
(ok if "<pre>" in msg and "极长的中文提交标题" in msg and "…" in msg else
 bad)("单条超长标题被**裁短后展示**, 不是整条丢弃(有 <pre>=%s, 有正文=%s, 有省略号=%s)"
      % ("<pre>" in msg, "极长的中文提交标题" in msg, "…" in msg))
_body = msg[msg.index("<pre>") + 5:msg.index("</pre>")] if "<pre>" in msg else ""
(ok if len(_body) <= bot.UPD_LINE_MAX * 6 else
 bad)("展示出来的那一条长度受 UPD_LINE_MAX 约束(实得 %d 字符)" % len(_body))

print()
print("══ 2. 中文 / emoji / HTML 特殊字符: 长度达标且形态有效 ══")
lines = ["1111111 修复 <script>alert(1)</script> & \"引号\"",
         "2222222 🎉🚀 emoji 与 <b>标签</b>",
         "3333333 中文标题" * 20]
msg = bot._upd_render("v1.0.0", "v1.1.0", lines, "misaka-cpu/privdns-gateway")
(ok if "<script>" not in msg and "&lt;script&gt;" in msg else
 bad)("原始 HTML 被转义, 没有原样进消息")
import re as _re                                                    # noqa: E402
(ok if not _re.search(r"&(?!amp;|lt;|gt;|quot;|#\d+;)", msg) else
 bad)("没有切出半个 HTML 实体")
(ok if msg.count("<pre>") == msg.count("</pre>") == 1 else bad)("<pre> 标签成对且只有一对")
(ok if "共 <b>3</b> 个提交" in msg else bad)("提交总数独立计算(3 条), 不是截取后的条数")
many = ["%07x t%d" % (i, i) for i in range(500)]
m2 = bot._upd_render("v1.0.0", "v1.1.0", many, "o/r")
(ok if "共 <b>500</b> 个提交" in m2 and "条未在此显示" in m2 and len(m2) <= bot.UPD_MSG_BUDGET else
 bad)("500 条 → 总数仍报 500、有未显示提示、整条 %d 字符在预算内" % len(m2))
(ok if "compare/" in m2 and "releases/tag/" in m2 else bad)("给出官方发布说明与完整比较链接")

print()
print("══ 3. 各 Git 阶段非零 / 超时 / 输出异常: 不误报最新, 任务正确结束 ══")
at("v1.11.3")


class _R:
    def __init__(self, rc=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def stage_fault(stage, mode):
    def g(*a, **k):
        if a and a[0] == stage:
            if mode == "timeout":
                raise subprocess.TimeoutExpired(cmd=["git", *a], timeout=1)
            if mode == "rc":
                return _R(3, "", "boom")
            return _R(0, "", "")           # empty
        return _REAL_GIT(*a, **k)
    return g


# 注意 merge-base --is-ancestor 的契约是**只看退出码**, 正常成功时 stdout 本来就是空的 ——
# 对它做 "空输出=故障" 的判断是错的, 所以这一格只测 timeout 与非零返回。
STAGE_MODES = {"describe": ("timeout", "rc", "empty"),
               "tag": ("timeout", "rc", "empty"),
               "rev-parse": ("timeout", "rc", "empty"),
               "merge-base": ("timeout", "rc"),
               "log": ("timeout", "rc", "empty")}
for stage, modes in STAGE_MODES.items():
    for mode in modes:
        bot._git = stage_fault(stage, mode)
        try:
            has, txt = bot.update_check()
            escaped = None
        except BaseException as e:          # noqa: BLE001
            has, txt, escaped = None, "", type(e).__name__
        bot._git = _REAL_GIT
        if escaped:
            bad("%s/%s → 异常逃出 update_check(%s)" % (stage, mode, escaped))
        elif has:
            bad("%s/%s → 误报有更新" % (stage, mode))
        elif "🟢" in txt:
            bad("%s/%s → 误报绿色: %r" % (stage, mode, txt[:60]))
        elif "❌" in txt:
            ok("%s/%-7s → 终态失败: %s" % (stage, mode, txt[:44]))
        else:
            bad("%s/%s → 既不是失败也不是绿: %r" % (stage, mode, txt[:60]))
bot._git = _REAL_GIT
bot._fetch_release_tags = lambda deadline=None: (False, "https://tok@github.com/x/y.git 挂了")
has, txt = bot.update_check()
(ok if (not has and "❌" in txt and "github.com" not in txt and "tok" not in txt) else
 bad)("fetch 失败 → 终态失败且不回显可能含凭据的 Git URL(%r)" % txt[:60])
no_fetch()

print()
print("══ 4. 后台执行: 不占主轮询 / 同会话重复点击受控 / 不同会话不串 ══")
src = open(os.path.join(ROOT, "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
seg = src[src.index('if data == "upd_check":'):]
seg = seg[:seg.index('if data == "upd_apply":')]
(ok if "_upd_check_async" in seg and "has, txt = update_check()" not in seg else
 bad)("upd_check 回调不再同步调 update_check")

gate = threading.Event()
started = threading.Event()


def slow_check(budget=None):
    started.set()
    gate.wait(10)
    return True, "🔄 结果 A"


tg = Tg(); with_tg(tg)
bot.update_check = slow_check
t0 = time.monotonic()
bot.handle_cb(101, 11, "upd_check")
elapsed = time.monotonic() - t0
(ok if elapsed < 1.0 else bad)("回调立即返回(%.2fs), 主轮询未被占用" % elapsed)
started.wait(5)
(ok if not bot._upd_check_async(101, 11) else bad)("同会话在飞时重复点击被拒(不无限提交)")
bot.handle_cb(101, 11, "upd_check")
busy = [t for t in tg.texts("editMessageText") if "还在跑" in t]
(ok if busy else bad)("重复点击有明确反馈: %r" % (busy[0][:40] if busy else "<无>"))
(ok if bot._upd_check_async(202, 22) else bad)("另一个会话不受影响, 可独立发起")
gate.set(); time.sleep(0.6)
(ok if 101 not in bot._upd_inflight and 202 not in bot._upd_inflight else
 bad)("检查结束后占用释放(在飞表: %r)" % (dict(bot._upd_inflight),))
res = [t for t in tg.texts("editMessageText") if "结果 A" in t]
(ok if res else bad)("在飞期间重复点击后, 原消息仍收到真实结果(不停在「还在跑」)")

print()
print("══ 5. 交错: 返回菜单 / 旧任务晚完成 / 新任务已开始 —— 旧结果不覆盖新页面 ══")
gate2 = threading.Event()
bot.update_check = lambda budget=None: (gate2.wait(10), (True, "🔄 旧结果 B"))[1]
tg = Tg(); with_tg(tg)
bot._upd_check_async(303, 33)
time.sleep(0.2)
# 走**真实的** handle_cb 入口(那是作废发生的地方), 只把它渲染菜单要读的生产配置打桩掉 ——
# 本支不读 /etc/sing-box/config.json, 也不碰任何生产文件。
_real_status = bot.status_text
bot.status_text = lambda: "（菜单占位）"
try:
    bot.handle_cb(303, 33, "menu")           # 用户返回菜单 → 该消息归属作废
finally:
    bot.status_text = _real_status
gate2.set(); time.sleep(0.6)
(ok if not any("旧结果 B" in t for t in tg.texts()) else
 bad)("用户已返回菜单 → 旧检查结果不写回")
(ok if not any(m == "sendMessage" and "旧结果 B" in p.get("text", "")
               for m, p in tg.calls) else bad)("也不补发新消息把旧结果推回来")
(ok if 303 not in bot._upd_inflight else bad)("作废后占用仍被释放")

print()
print("══ 6. 消息编辑失败 / 发送失败 / API 不可达: 回退有界, 占用能释放 ══")
bot.update_check = lambda budget=None: (True, "🔄 结果 C")
tg = Tg(); tg.fail_edit = 99; with_tg(tg)
bot._upd_check_async(404, 44); time.sleep(0.8)
n_edit = sum(1 for m, _ in tg.calls if m == "editMessageText")
n_send = sum(1 for m, _ in tg.calls if m == "sendMessage")
(ok if n_edit <= 2 else bad)("编辑一直失败时调用有界(editMessageText %d 次 ≤ 2)" % n_edit)
(ok if n_send == 0 else bad)("编辑失败不补发新消息(sendMessage %d 次)" % n_send)
(ok if 404 not in bot._upd_inflight else bad)("编辑失败后占用释放")

tg = Tg(); tg.unreachable = True; with_tg(tg)
bot._upd_check_async(505, 55); time.sleep(0.8)
(ok if 505 not in bot._upd_inflight else bad)("API 完全不可达: 服务端任务仍结束、占用释放")
(ok if len(tg.calls) <= 2 else bad)("不可达时投递尝试有界(%d 次)" % len(tg.calls))

print()
print("══ 7. 超时后本次 git 子进程被收干净(不是只证明外层函数返回) ══")
probe = os.path.join(WD, "slow.sh")
open(probe, "w", encoding="utf-8").write(
    "#!/bin/sh\nsleep 60 &\necho $! > %s/child.pid\nwait\n" % WD)
os.chmod(probe, 0o755)
fake_git = os.path.join(WD, "bin")
os.makedirs(fake_git, exist_ok=True)
open(os.path.join(fake_git, "git"), "w", encoding="utf-8").write(
    "#!/bin/sh\nexec %s\n" % probe)
os.chmod(os.path.join(fake_git, "git"), 0o755)
_oldpath = os.environ["PATH"]
os.environ["PATH"] = fake_git + os.pathsep + _oldpath
t0 = time.monotonic()
try:
    _REAL_GIT("status", t=1)
    bad("超时没有抛出")
except subprocess.TimeoutExpired:
    el = time.monotonic() - t0
    (ok if el < 15 else bad)("超时在 %.1fs 抛出(有界)" % el)
os.environ["PATH"] = _oldpath
time.sleep(0.5)
try:
    kid = int(open(os.path.join(WD, "child.pid"), encoding="utf-8").read().strip())
    alive = os.path.exists("/proc/%d" % kid)
    (ok if not alive else bad)("超时后本次派生的子进程(pid %d)已被收掉(alive=%s)" % (kid, alive))
except (OSError, ValueError):
    print("  [SKIP] 拿不到子进程 pid —— 这一格未执行, 不计入通过")

print()
print("══ 8. 检查流程从不调用实际升级入口 ══")
called = []
_real_start = bot.start_update
bot.start_update = lambda: called.append("start_update") or True
_real_sh = bot.sh
bot.sh = lambda cmd, input=None: called.append(list(cmd)) or _R(0, "", "")
bot._git = _REAL_GIT
at("v1.11.3")
no_fetch()
has, _txt = bot.update_check()
bot.start_update, bot.sh = _real_start, _real_sh
(ok if not called else bad)("检查全程没有调用 start_update / pdg CLI(实得 %r)" % (called[:2],))
(ok if 'systemd-run' in src and 'if data == "upd_apply"' in src else
 bad)("确认更新仍走原有入口(upd_apply → start_update → systemd-run)")

print()
print("══ 9. 总时限: 后续步骤只拿剩余预算, 不每步重新获得完整等待 ══")
bot.update_check = _REAL_UPDATE_CHECK      # 前面几节替换过, 这一节要验真实实现
_seen = []


def _budget_git(*a, t=60):
    _seen.append((a[0], round(t, 2)))
    if a[0] == "describe":
        time.sleep(0.4)
    return _R(0, {"describe": "v1.0.0", "tag": "v9.9.9\n", "rev-parse": "aaa",
                  "merge-base": "", "log": "1111111 x\n"}.get(a[0], "x"))


bot._git = _budget_git
no_fetch()
bot.update_check(budget=2.0)
bot._git = _REAL_GIT
_caps = [t for _, t in _seen]
(ok if _caps and all(_caps[i] >= _caps[i + 1] for i in range(len(_caps) - 1)) else
 bad)("各步骤拿到的超时单调不增(实得 %r)" % (_caps,))
(ok if _caps and _caps[0] <= 2.0 and _caps[-1] < _caps[0] else
 bad)("首步不超过总预算、末步明显更小(实得 %r)" % (_caps,))


def _slow_git(*a, t=60):
    time.sleep(1.2)
    return _R(0, "v1.0.0")


bot._git = _slow_git
_t0 = time.monotonic()
# 预算耗尽同样必须是**终态返回**, 不是抛给调用方 —— 抛出去就等于回调拿不到结果, 页面
# 又停在"检查更新中…"。所以这里把逃逸也当一种失败来断言, 而不是让整支测试崩掉。
try:
    _has, _txt, _esc_name = (*bot.update_check(budget=1.0), None)
except BaseException as _e:      # noqa: BLE001
    _has, _txt, _esc_name = None, "", type(_e).__name__
_el = time.monotonic() - _t0
bot._git = _REAL_GIT
if _esc_name:
    bad("预算耗尽 → 异常逃出 update_check(%s), 回调拿不到终态" % _esc_name)
else:
    (ok if (not _has and "❌" in _txt and "超时" in _txt) else
     bad)("预算耗尽 → 终态超时失败(实得 has=%s %r)" % (_has, _txt[:44]))
(ok if _el < 10 else bad)("预算耗尽后很快返回(%.2fs), 没有把任务吊住" % _el)

print()
print("-" * 62)
print("test-bot-update-check.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

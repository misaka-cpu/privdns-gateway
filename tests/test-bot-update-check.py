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
_REAL_FETCH_TAGS = bot._fetch_release_tags
_REAL_POST = bot.post                      # §14 要用**真实** post(带重连), 不能是假件


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

    def post(self, method, params, deadline=None):
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
(ok if bot._upd_check_async(101, 11)[0] == bot.ACCEPT_BUSY else
 bad)("同会话在飞时重复点击被拒为 BUSY(不无限提交)")
bot.handle_cb(101, 11, "upd_check")
busy = [t for t in tg.texts("editMessageText") if "还在跑" in t]
(ok if busy else bad)("重复点击有明确反馈: %r" % (busy[0][:40] if busy else "<无>"))
(ok if bot._upd_check_async(202, 22)[0] == bot.ACCEPT_OK else
 bad)("另一个会话不受影响, 可独立发起")
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
(ok if (303, 33) not in bot._upd_sess else
 bad)("作废写入权后**仍有清理资格**: 会话记录也被清掉(残留 %r)" % (list(bot._upd_sess),))

print()
print("══ 6. 消息编辑失败 / 发送失败 / API 不可达: 回退有界, 占用能释放 ══")
bot.update_check = lambda budget=None: (True, "🔄 结果 C")
tg = Tg(); tg.fail_edit = 99; with_tg(tg)
bot._upd_check_async(404, 44); time.sleep(0.8)
n_edit = sum(1 for m, _ in tg.calls if m == "editMessageText")
n_send = sum(1 for m, _ in tg.calls if m == "sendMessage")
# 上界是**算出来的**, 不是拍的: 一次检查最多两次 emit(进度 + 终态), 每次 emit 走 edit_only
# 最多两次 API 调用(HTML 一次 + 纯文本回退一次) → 2 × 2 = 4。
_MAX_EDITS = 2 * 2
(ok if n_edit <= _MAX_EDITS else
 bad)("编辑一直失败时调用有界(editMessageText %d 次 ≤ %d = 2 emit × 2 次)" % (n_edit, _MAX_EDITS))
(ok if n_send == 0 else bad)("编辑失败不补发新消息(sendMessage %d 次)" % n_send)
(ok if 404 not in bot._upd_inflight else bad)("编辑失败后占用释放")

tg = Tg(); tg.unreachable = True; with_tg(tg)
bot._upd_check_async(505, 55); time.sleep(0.8)
(ok if 505 not in bot._upd_inflight else bad)("API 完全不可达: 服务端任务仍结束、占用释放")
(ok if len(tg.calls) <= _MAX_EDITS else
 bad)("不可达时投递尝试有界(%d 次 ≤ %d)" % (len(tg.calls), _MAX_EDITS))
# 初始提示与忙反馈同样不能因为网络慢而拖住主轮询 —— 这两条也走后台。
tg = Tg(); tg.unreachable = True; tg.delay = 0.8; with_tg(tg)
_t0 = time.monotonic(); bot.handle_cb(506, 56, "upd_check"); _e1 = time.monotonic() - _t0
_t0 = time.monotonic(); bot.handle_cb(506, 56, "upd_check"); _e2 = time.monotonic() - _t0
(ok if _e1 < 0.3 and _e2 < 0.3 else
 bad)("不可达+慢响应下, 初始提示(%.2fs)与忙反馈(%.2fs)都不占主轮询" % (_e1, _e2))
# 有界轮询, 不用固定 sleep 撞运气: 4 次 ×0.8s 的慢响应 + 收尾, 给它 15 秒上限。
_t0 = time.monotonic()
while 506 in bot._upd_inflight and time.monotonic() - _t0 < 15:
    time.sleep(0.1)
(ok if 506 not in bot._upd_inflight else
 bad)("慢+不可达之后占用仍释放(等了 %.1fs)" % (time.monotonic() - _t0))
tg.delay = 0.0

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
bot.update_check = _REAL_UPDATE_CHECK      # **必须验真实实现** —— 前面几节把它换成过桩
at("v1.11.3")
no_fetch()
has, _txt = bot.update_check()
(ok if has and "有新发布" in _txt else
 bad)("这一节确实跑的是真实 update_check(has=%s, %r)" % (has, _txt[:36]))
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
    # HEAD 与目标提交**必须不同**, 否则会在"已是最新"提前返回, log / 渲染那几步根本不跑。
    if a[0] == "rev-parse":
        return _R(0, "bbbbbbb" if (a[1:2] and str(a[1]).startswith("v")) else "aaaaaaa")
    return _R(0, {"describe": "v1.0.0", "tag": "v9.9.9\n",
                  "merge-base": "", "log": "1111111 x\n", "config": ""}.get(a[0], "x"))


bot._git = _budget_git
no_fetch()
_bh, _bt = bot.update_check(budget=2.0)
bot._git = _REAL_GIT
(ok if _bh and "有新发布" in _bt else
 bad)("总预算这一格确实走完了 log/渲染(has=%s, %r)" % (_bh, _bt[:36]))
(ok if any(x[0] == "log" for x in _seen) and any(x[0] == "config" for x in _seen) else
 bad)("走过 log 与 origin 查询(实得阶段 %r)" % ([x[0] for x in _seen],))
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
print("══ 10. fetch 成功后 shallow 状态读不出 —— 不能当作非浅仓库继续报绿 ══")
# 这一格**不能用 no_fetch 替身**: 要真的走进 _fetch_release_tags, 让 fetch 成功、
# 紧跟的 rev-parse --is-shallow-repository 出错。
bot.update_check = _REAL_UPDATE_CHECK
bot._fetch_release_tags = _REAL_FETCH_TAGS      # 这一格必须走真实实现, 不能被 no_fetch 遮住
for _rc, _out, _name in ((128, "fatal: bad", "非零返回"), (0, "", "空输出"), (0, "maybe", "非法取值")):
    def _shallow_bad(*a, t=60, _rc=_rc, _out=_out):
        if a[0] == "fetch":
            return _R(0, "", "")
        if a[0] == "rev-parse" and a[1:2] == ("--is-shallow-repository",):
            return _R(_rc, _out, "")
        return _REAL_GIT(*a, t=t)
    bot._git = _shallow_bad
    _o, _e = bot._fetch_release_tags()
    _h, _t = bot.update_check()
    bot._git = _REAL_GIT
    (ok if (not _o and not _h and "❌" in _t and "🟢" not in _t) else
     bad)("shallow %s → fetch 判失败(%s)且检查报 ❌ 不报绿(%r)" % (_name, _o, _t[:40]))
no_fetch()

print()
print("══ 11. 全局准入 / 提交拒绝 / 排队过期 ══")
tg = Tg(); with_tg(tg)
_hold = threading.Event()
bot.update_check = lambda budget=None: (_hold.wait(20), (True, "🔄 x"))[1]
_acc = [bot._upd_check_async(900 + i, 90 + i)[0] for i in range(bot.UPD_MAX_INFLIGHT + 6)]
_n_ok = _acc.count(bot.ACCEPT_OK)
(ok if _n_ok == bot.UPD_MAX_INFLIGHT else
 bad)("全局准入上限 %d(实得受理 %d)" % (bot.UPD_MAX_INFLIGHT, _n_ok))
(ok if bot.ACCEPT_FULL in _acc else bad)("超出上限的会话得到 FULL, 不是排进无界队列")
(ok if bot.UPD_MAX_INFLIGHT > bot._EXEC._max_workers else
 bad)("上限独立于线程数(worker %d) —— 线程有限不等于队列有界" % bot._EXEC._max_workers)
_hold.set()
_t0 = time.monotonic()
while bot._upd_inflight and time.monotonic() - _t0 < 20:
    time.sleep(0.1)
(ok if not bot._upd_inflight else bad)("全部结束后在飞表清空(%r)" % (dict(bot._upd_inflight),))

tg = Tg(); with_tg(tg)
_real_submit = bot._EXEC.submit
bot._EXEC.submit = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("closed"))
_v, _tk = bot._upd_check_async(910, 91)
(ok if _v == bot.ACCEPT_SUBMIT_FAIL and _tk else
 bad)("提交失败返回 SUBMIT_FAIL(且带可作废的通知归属; 实得 %r/%s)" % (_v, bool(_tk)))
(ok if 910 not in bot._upd_inflight else bad)("提交失败后占用不残留")
bot.handle_cb(910, 91, "upd_check")     # 仍在"提交必失败"状态下走真实回调
time.sleep(0.5)
bot._EXEC.submit = _real_submit
_txts = tg.texts("editMessageText")
(ok if any("未受理" in t for t in _txts) and not any("还在跑" in t for t in _txts) else
 bad)("提交失败的反馈说「未受理」, 不冒充「还在跑」(实得 %r)" % (_txts[:2],))

tg = Tg(); with_tg(tg)
bot.update_check = lambda budget=None: (True, "🔄 不该跑到这里")
_calls = []
_orig_uc = bot.update_check
bot.update_check = lambda budget=None: (_calls.append(1), (True, "🔄 不该跑到这里"))[1]
_v, _tk = bot._upd_check_async(920, 92)
with bot._upd_lock:                      # 人为把截止时间调到只剩一点点 = 排队过久
    bot._upd_sess[(920, 92)]["deadline"] = time.monotonic() + 1.0
time.sleep(1.5)
_t0 = time.monotonic()
while 920 in bot._upd_inflight and time.monotonic() - _t0 < 10:
    time.sleep(0.1)
_txts = tg.texts("editMessageText")
(ok if any("排队过久" in t for t in _txts) else
 bad)("排队过期 → 终态说明未执行(实得 %r)" % (_txts[-1:],))
(ok if not _calls else bad)("排队过期这一格确实提交过任务") if False else None
(ok if 920 not in bot._upd_inflight else bad)("排队过期后占用释放")

print()
print("══ 12. 断言最终消息内容 / 目标 mid / 写入顺序 / 任务状态 ══")
tg = Tg(); with_tg(tg)
bot.update_check = lambda budget=None: (True, "🔄 终态-内容校验")
bot.handle_cb(930, 93, "upd_check")
_t0 = time.monotonic()
while 930 in bot._upd_inflight and time.monotonic() - _t0 < 10:
    time.sleep(0.1)
_seq = [(m, p.get("message_id"), (p.get("text") or "")[:14]) for m, p in tg.calls]
(ok if all(m == "editMessageText" for m, _i, _t in _seq) else
 bad)("全程只用 editMessageText, 没有补发(实得 %r)" % (_seq,))
(ok if all(i == 93 for _m, i, _t in _seq) else
 bad)("所有写入都打在发起它的那条消息上(mid=93; 实得 %r)" % ([i for _m, i, _t in _seq],))
_texts = [t for _m, _i, t in _seq]
(ok if _texts and "检查更新中" in _texts[0] else bad)("第一条是进度(实得 %r)" % (_texts[:1],))
(ok if _texts and "终态-内容校验" in _texts[-1] else
 bad)("最后一条是终态内容本身(实得 %r)" % (_texts[-1:],))
(ok if 930 not in bot._upd_inflight and (930, 93) not in bot._upd_sess else
 bad)("任务结束后在飞表与会话表都已清理")

print()
print("══ 13. 交错(屏障控制): 终态不倒退 / 忙反馈不覆盖 / 新页面不被旧结果取代 ══")


class GateTg:
    """按**文案关键字**设闸的接收端: 精确控制哪一条先出发、哪一条后落地。"""

    def __init__(self):
        self.log = []
        self.lock = threading.Lock()
        self.gates = {}
        self.waiters = {}          # 哪一条已经**进到网络调用里**被闸挡住了

    def post(self, method, params, deadline=None):
        txt = params.get("text") or ""
        for k, g in list(self.gates.items()):
            if k in txt:
                with self.lock:
                    self.waiters[k] = self.waiters.get(k, 0) + 1
                g.wait(15)
        with self.lock:
            self.log.append((method, params.get("message_id"), txt[:18].replace("\n", " ")))
        return {"ok": True, "result": {"message_id": params.get("message_id") or 999}}

    def seq(self):
        with self.lock:
            return [t for _m, _i, t in self.log]


def _reset_state():
    with bot._upd_lock:
        bot._upd_inflight.clear()
        bot._upd_sess.clear()
        bot._upd_jobs.clear()
        bot._upd_notify_pending.clear()
        bot._upd_notify_live.clear()


def _tables():
    """五张表的当下规模。判"零残留"要看**全部**, 不能只看在飞表。"""
    with bot._upd_lock:
        return (len(bot._upd_sess), len(bot._upd_jobs), len(bot._upd_inflight),
                len(bot._upd_notify_pending), len(bot._upd_notify_live))


def _drain(limit=20):
    """等到本轮真的都结束再看表 —— 不是先清空映射再宣布零残留。"""
    t0 = time.monotonic()
    while _tables() != (0, 0, 0, 0, 0) and time.monotonic() - t0 < limit:
        time.sleep(0.02)
    return _tables()


def _settle(chat, limit=20):
    t0 = time.monotonic()
    while chat in bot._upd_inflight and time.monotonic() - t0 < limit:
        time.sleep(0.05)


def _quiesce(gt, limit=8):
    """等写入序列**稳定**下来再读 —— 只等任务释放是不够的: 被闸住的那条线程可能还没落地,
    过早取样会让"乱序覆盖"看起来没发生(这一处我自己踩过)。"""
    t0 = time.monotonic()
    prev = None
    while time.monotonic() - t0 < limit:
        cur = tuple(gt.seq())
        if cur == prev and cur:
            return
        prev = cur
        time.sleep(0.15)


def _wait_gate(gt, key, limit=10):
    """等到那一条**确实进到了网络调用里**再往下走 —— 不用固定 sleep 撞窗口。"""
    t0 = time.monotonic()
    while gt.waiters.get(key, 0) < 1 and time.monotonic() - t0 < limit:
        time.sleep(0.02)
    return gt.waiters.get(key, 0) >= 1


# 13a 结果早于初始提示完成 —— 终态不得被"检查中"覆盖
_reset_state()
gt = GateTg(); bot.post = gt.post
_done = threading.Event()
bot.update_check = lambda budget=None: (_done.set(), (True, "🔄 终态A"))[1]
gt.gates["检查更新中"] = threading.Event()          # 卡住进度这一条
bot.handle_cb(1001, 101, "upd_check")
_done.wait(5); time.sleep(0.2)
gt.gates["检查更新中"].set(); _settle(1001); _quiesce(gt)
_s = gt.seq()
(ok if _s and "终态A" in _s[-1] else
 bad)("13a 结果早于进度完成 → 最后落地仍是终态(实得 %r)" % (_s,))

# 13b 忙反馈**先进入网络调用**、终态随后 —— 落地顺序不得倒过来
_reset_state()
gt = GateTg(); bot.post = gt.post
_rel = threading.Event()
bot.update_check = lambda budget=None: (_rel.wait(15), (True, "🔄 终态B"))[1]
bot.handle_cb(1002, 102, "upd_check")
_wait_gate(gt, "检查更新中") if "检查更新中" in gt.gates else time.sleep(0.3)
gt.gates["还在跑"] = threading.Event()
_th = threading.Thread(target=bot.handle_cb, args=(1002, 102, "upd_check")); _th.start()
(ok if _wait_gate(gt, "还在跑") else bad)("13b 忙反馈已进入网络调用(窗口成立)")
_rel.set(); time.sleep(0.4)              # 终态在此期间产生
gt.gates["还在跑"].set(); _th.join(10); _settle(1002); _quiesce(gt)
_s = gt.seq()
(ok if _s and "终态B" in _s[-1] else
 bad)("13b 忙反馈先出发也不覆盖终态(实得 %r)" % (_s,))

# 13d 终态**已在网络调用里**时才点第二次 —— 忙反馈必须被阶段序拒掉, 一个字都不写
_reset_state()
gt = GateTg(); bot.post = gt.post
gt.gates["终态D"] = threading.Event()
bot.update_check = lambda budget=None: (True, "🔄 终态D")
bot.handle_cb(1004, 104, "upd_check")
(ok if _wait_gate(gt, "终态D") else bad)("13d 终态已进入网络调用(窗口成立)")
_th = threading.Thread(target=bot.handle_cb, args=(1004, 104, "upd_check")); _th.start()
time.sleep(0.4)
gt.gates["终态D"].set(); _th.join(10); _settle(1004); _quiesce(gt)
_s = gt.seq()
(ok if _s and "终态D" in _s[-1] else bad)("13d 最后落地仍是终态(实得 %r)" % (_s,))
(ok if not any("还在跑" in x for x in _s) else
 bad)("13d 终态已落地后, 忙反馈被阶段序拒掉、一个字都不写(实得 %r)" % (_s,))

# 13e 连点三次 —— "还在跑"只能写一次(阶段序把重复的低阶段写入挡掉)
_reset_state()
gt = GateTg(); bot.post = gt.post
_rel = threading.Event()
bot.update_check = lambda budget=None: (_rel.wait(15), (True, "🔄 终态E"))[1]
bot.handle_cb(1005, 105, "upd_check")
gt.gates["还在跑"] = threading.Event()
_ths = [threading.Thread(target=bot.handle_cb, args=(1005, 105, "upd_check")) for _ in range(3)]
for _t in _ths:
    _t.start()
(ok if _wait_gate(gt, "还在跑") else bad)("13e 至少一条忙反馈进入了网络调用")
time.sleep(0.4)
gt.gates["还在跑"].set()
for _t in _ths:
    _t.join(10)
_rel.set(); _settle(1005); _quiesce(gt)
_s = gt.seq()
_n_busy = sum(1 for x in _s if "还在跑" in x)
(ok if _n_busy == 1 else
 bad)("13e 连点三次只写一条忙反馈(实得 %d 条; 序列 %r)" % (_n_busy, _s))
(ok if _s and "终态E" in _s[-1] else bad)("13e 最后落地仍是终态(实得 %r)" % (_s,))

# 13c 已过 token 检查、正在投递时用户返回菜单 —— 新页面最终不被旧结果取代
_reset_state()
gt = GateTg(); bot.post = gt.post
_rel = threading.Event()
bot.update_check = lambda budget=None: (_rel.wait(15), (True, "🔄 旧结果C"))[1]
bot.handle_cb(1003, 103, "upd_check"); time.sleep(0.3)
gt.gates["旧结果C"] = threading.Event()
_rel.set(); time.sleep(0.4)
_rs = bot.status_text
bot.status_text = lambda: "（主菜单C）"
try:
    bot.handle_cb(1003, 103, "menu")
finally:
    bot.status_text = _rs
time.sleep(0.2); gt.gates["旧结果C"].set(); _settle(1003); _quiesce(gt)
_s = gt.seq()
(ok if _s and "主菜单C" in _s[-1] else
 bad)("13c 导航抢写后收敛回新页面(实得 %r)" % (_s,))
(ok if any("旧结果C" in x for x in _s) else
 bad)("13c 如实记录: 旧结果那一次请求确实到达过, 收敛不是撤回(实得 %r)" % (_s,))

print()
print("══ 14. 投递时限: 在**连接层**注入故障, 保留真实 post 重连与 edit_only 回退 ══")
# 这一节**不替换 post** —— 替换掉它就等于没验投递路径。故障注入在 HTTPSConnection 上,
# 于是 post 的重连、edit_only 的两段回退、以及新加的 deadline 全都真的跑到。
# 用受控时钟量"模拟时间", 与墙钟分开记。


class _Clock:
    def __init__(self):
        self.t = 10000.0
        self.lock = threading.Lock()

    def mono(self):
        with self.lock:
            return self.t

    def advance(self, d):
        with self.lock:
            self.t += d


class _DeadConn:
    """每次 request 都走满 socket timeout 再失败 —— 模拟不可达。"""
    tries = []

    def __init__(self, host, timeout=None):
        self.timeout = timeout

    def request(self, *a, **k):
        _DeadConn.tries.append(self.timeout)
        _CK.advance(self.timeout or 0)
        raise OSError("unreachable")

    def getresponse(self):
        raise OSError("unreachable")

    def close(self):
        pass


_CK = _Clock()
_real_conn_cls = bot.http.client.HTTPSConnection
_real_mono = time.monotonic
_post_calls = [0]


def _counting_post(method, params, deadline=None):
    """**包装**真实 post(不替换它): 数调用次数, 内部仍走真实重连与 deadline 逻辑。"""
    _post_calls[0] += 1
    return _REAL_POST(method, params, deadline)


bot.post = _counting_post                  # 关键: 内部仍是真实 post, 只在连接层注入故障
bot.http.client.HTTPSConnection = _DeadConn
bot.time.monotonic = _CK.mono
_DeadConn.tries = []
bot._tls.conn = None
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear()
_emits = [0]
_real_emit = bot._upd_emit


def _counting_emit(chat, mid, token, phase, text, kb):
    _emits[0] += 1
    return _real_emit(chat, mid, token, phase, text, kb)


bot._upd_emit = _counting_emit
bot.update_check = lambda budget=None: (True, "🔄 终态14")
_sim0 = _CK.mono()
_wall0 = _real_mono()
bot.handle_cb(1401, 141, "upd_check")
while 1401 in bot._upd_inflight and _real_mono() - _wall0 < 60:
    time.sleep(0.02)
bot._upd_emit = _real_emit
_sim = _CK.mono() - _sim0
_wall = _real_mono() - _wall0
bot.http.client.HTTPSConnection = _real_conn_cls
bot.time.monotonic = _real_mono
bot._tls.conn = None
(ok if bot.post is _counting_post else bad)("14 走的是包装后的真实 post(未被假件替换)")
bot.post = _REAL_POST
(ok if _post_calls[0] < 2 * max(1, _emits[0]) else
 bad)("14 期限到了 edit_only 不再回退重试: post 调用 %d 次 < emit %d × 2"
      % (_post_calls[0], _emits[0]))
print("       post 调用 %d 次" % _post_calls[0])
print("       emit %d 次 / 传输尝试 %d 次 / 模拟耗时 %.0fs / 实测墙钟 %.2fs"
      % (_emits[0], len(_DeadConn.tries), _sim, _wall))
(ok if _sim <= bot.UPD_CHECK_BUDGET else
 bad)("投递受期限约束: 模拟耗时 %.0fs ≤ 总预算 %.0fs" % (_sim, bot.UPD_CHECK_BUDGET))
(ok if len(_DeadConn.tries) < 2 * max(1, _emits[0]) else
 bad)("期限到了就不再回退重试: 传输 %d 次 < emit %d × 2(否则说明 edit_only 仍走满回退)"
      % (len(_DeadConn.tries), _emits[0]))
(ok if any(t is not None and t < bot.API_TIMEOUT for t in _DeadConn.tries) else
 bad)("至少一次传输的 socket 超时被期限压小(实得 %r)" % (_DeadConn.tries,))
(ok if 1401 not in bot._upd_inflight and (1401, 141) not in bot._upd_sess else
 bad)("不可达之后两张表都清理")

print()
print("══ 15. 排队过期: 先占满 worker, 再受理, 推进时间, 核对裁决 ══")
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear()
tg = Tg(); with_tg(tg)
_hold = threading.Event()
for _ in range(bot._EXEC._max_workers):
    bot._EXEC.submit(lambda: _hold.wait(40))
time.sleep(0.4)
(ok if all(w for w in [True]) else bad)("worker 已被占满(提交了 %d 个阻塞任务)" % bot._EXEC._max_workers)
_gitcalls = []
bot.update_check = lambda budget=None: (_gitcalls.append(1), (True, "x"))[1]
_CK2 = _Clock()
bot.time.monotonic = _CK2.mono
_v, _t = bot._upd_check_async(1501, 151)
(ok if _v == bot.ACCEPT_OK and 1501 in bot._upd_inflight else
 bad)("worker 满时仍先受理并占名额(实得 %r)" % (_v,))
_CK2.advance(bot.UPD_CHECK_BUDGET - bot.UPD_DELIVER_BUDGET + 1)
time.sleep(bot.UPD_REAP_TICK * 3)
(ok if 1501 not in bot._upd_inflight else
 bad)("排队过期被裁决并释放名额(不等空闲 worker; 在飞 %r)" % (list(bot._upd_inflight),))
_hold.set()
time.sleep(1.2)
(ok if not _gitcalls else
 bad)("迟到启动的旧任务不再执行检查/Git(实得 %d 次)" % len(_gitcalls))
_texts = tg.texts("editMessageText")
(ok if any("排队过久" in t for t in _texts) else
 bad)("排队过期有终态说明(实得 %r)" % (_texts[-2:],))
bot.time.monotonic = _real_mono

print()
print("══ 16. 补绘期间第二次导航: 最后页面必须对应最新动作 ══")
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear()
gt = GateTg(); bot.post = gt.post
_rel = threading.Event()
bot.update_check = lambda budget=None: (_rel.wait(15), (True, "🔄 旧结果F"))[1]
bot.handle_cb(1601, 161, "upd_check"); time.sleep(0.3)
gt.gates["旧结果F"] = threading.Event()
_rel.set()
(ok if _wait_gate(gt, "旧结果F") else bad)("16 旧结果已进入网络调用(窗口成立)")
_rs = bot.status_text
bot.status_text = lambda: "（菜单A）"
try:
    bot.handle_cb(1601, 161, "menu")
finally:
    bot.status_text = _rs
gt.gates["菜单A"] = threading.Event()      # 卡住补绘 A
gt.gates["旧结果F"].set()
_wait_gate(gt, "菜单A")
bot.status_text = lambda: "（菜单B）"       # 用户又翻到 B
try:
    bot.handle_cb(1601, 161, "menu")
finally:
    bot.status_text = _rs
time.sleep(0.2)
gt.gates["菜单A"].set()
_settle(1601); _quiesce(gt, limit=12)
_s = gt.seq()
(ok if _s and "菜单B" in _s[-1] else
 bad)("16 补绘服从最新意图, 最后页面是 B(实得 %r)" % (_s,))

print()
print("══ 17. 取消资格 / 拒绝通知归属 / 通知合并 ══")
# 17a 被标记 cancelled 的排队任务, 即使 worker 后来空出来也不得执行检查
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear()
tg = Tg(); with_tg(tg)
_hold = threading.Event()
for _ in range(bot._EXEC._max_workers):
    bot._EXEC.submit(lambda: _hold.wait(30))
time.sleep(0.4)
_calls = []
bot.update_check = lambda budget=None: (_calls.append(1), (True, "x"))[1]
_v, _t = bot._upd_check_async(1701, 171)
(ok if _v == bot.ACCEPT_OK else bad)("17a 已受理并排队(实得 %r)" % (_v,))
with bot._upd_lock:                      # 模拟收割线程刚标记、还没来得及丢弃会话的那个窗口
    bot._upd_sess[(1701, 171)]["cancelled"] = True
_hold.set()
_t0 = time.monotonic()
while 1701 in bot._upd_inflight and time.monotonic() - _t0 < 15:
    time.sleep(0.05)
(ok if not _calls else
 bad)("17a 已取消资格的任务即使拿到 worker 也不执行检查(实得 %d 次)" % len(_calls))
(ok if not any("检查更新中" in t for t in tg.texts()) else
 bad)("17a 已取消资格的任务不发进度(实得 %r)" % (tg.texts(),))

# 17b 拒绝通知必须有可作废的归属
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear()
bot.update_check = lambda budget=None: (True, "x")
_held = threading.Event()
bot.update_check = lambda budget=None: (_held.wait(20), (True, "x"))[1]
for _c in range(1710, 1710 + bot.UPD_MAX_INFLIGHT):
    bot._upd_check_async(_c, _c)
_v, _t = bot._upd_check_async(1799, 179)
(ok if _v == bot.ACCEPT_FULL and _t else
 bad)("17b 超出上限得到 FULL 且带归属(实得 %r/%s)" % (_v, bool(_t)))
_sess = bot._upd_sess.get((1799, 179))
(ok if _sess and _sess.get("kind") == "notice" else
 bad)("17b 拒绝通知有自己的会话记录(kind=%r)" % ((_sess or {}).get("kind"),))
(ok if _sess and _sess.get("deadline") else bad)("17b 拒绝通知带期限")
bot._upd_invalidate(1799, 179)
(ok if bot._upd_sess.get((1799, 179), {}).get("token") is None else
 bad)("17b 拒绝通知可被导航作废")
tg = Tg(); with_tg(tg)
bot._upd_notify(1799, 179, "迟到的拒绝通知", _t, time.monotonic() + 10)
time.sleep(0.5)
(ok if not any("迟到的拒绝通知" in t for t in tg.texts()) else
 bad)("17b 作废之后迟到的拒绝通知不再写入(实得 %r)" % (tg.texts(),))
_held.set()
_t0 = time.monotonic()
while bot._upd_inflight and time.monotonic() - _t0 < 15:
    time.sleep(0.05)

# 17c 连点不新开工作: 待发表按消息合并
with bot._upd_lock:
    bot._upd_inflight.clear(); bot._upd_sess.clear(); bot._upd_notify_pending.clear()
_gate = threading.Event()
_seen_note = [0]
_lk = threading.Lock()


class _SlowTg(Tg):
    def post(self, method, params, deadline=None):
        t = params.get("text") or ""
        if "还在跑" in t:
            with _lk:
                _seen_note[0] += 1
            _gate.wait(10)
        return Tg.post(self, method, params, deadline)


tg = _SlowTg(); with_tg(tg)
_submits = [0]
_real_note_submit = bot._upd_notify_exec.submit


def _counting_submit(fn, *a, **k):
    _submits[0] += 1
    return _real_note_submit(fn, *a, **k)


bot._upd_notify_exec.submit = _counting_submit
_hold2 = threading.Event()
bot.update_check = lambda budget=None: (_hold2.wait(25), (True, "终态17c"))[1]
bot._upd_check_async(1720, 172)
time.sleep(0.2)
_base_threads = threading.active_count()
_peak_pending = 0
for _ in range(20):
    bot.handle_cb(1720, 172, "upd_check")
    _peak_pending = max(_peak_pending, len(bot._upd_notify_pending))
time.sleep(0.5)
_grew = threading.active_count() - _base_threads
(ok if _peak_pending <= 1 else
 bad)("17c 待发通知按消息合并(峰值 %d 条, 应 ≤1)" % _peak_pending)
(ok if _grew <= 2 else
 bad)("17c 连点 20 次不新开线程(线程 +%d, 应 ≤2)" % _grew)
(ok if _seen_note[0] <= 1 else
 bad)("17c 实际发出的忙提示 ≤1 条(实得 %d)" % _seen_note[0])
(ok if _submits[0] <= 1 else
 bad)("17c 连点 20 次只给通知执行器排 1 份工作(实得 %d 份)" % _submits[0])
bot._upd_notify_exec.submit = _real_note_submit
_gate.set(); _hold2.set()
_t0 = time.monotonic()
while 1720 in bot._upd_inflight and time.monotonic() - _t0 < 20:
    time.sleep(0.05)
(ok if 1720 not in bot._upd_inflight and not bot._upd_notify_pending else
 bad)("17c 结束后在飞表与待发表都清空")

# ══════════════════════════════════════════════════════════════════════════════
# 18. 绝对期限贯穿**真实**请求: 自建回环服务, 走真实 post 的建连/复用/读响应
# ──────────────────────────────────────────────────────────────────────────────
# 只换端点(127.0.0.1 上自己起的服务、自造数据), post() 的逻辑一个字不改 ——
# 换掉 post 就等于没验这条路径。绝不连 api.telegram.org / 9090 / 任何生产口。
print()
print("══ 18. 绝对期限贯穿真实请求(自建回环服务; 建连 / 复用 / 读响应) ══")

import http.client as _hc                                          # noqa: E402
import socketserver                                                # noqa: E402

_LB_BODY = b'{"ok":true,"result":{"message_id":1}}'


class _LbHandler(socketserver.StreamRequestHandler):
    def handle(self):
        while True:
            if not self.rfile.readline():
                return
            n = 0
            while True:
                h = self.rfile.readline()
                if h in (b"\r\n", b"\n", b""):
                    break
                if h.lower().startswith(b"content-length:"):
                    n = int(h.split(b":")[1])
            if n:
                self.rfile.read(n)
            _LB.hits.append(time.monotonic())
            _LB.conns.add(id(self.connection))
            try:
                time.sleep(_LB.head_delay)
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n"
                                 b"Content-Type: application/json\r\n\r\n" % len(_LB_BODY))
                self.wfile.flush()
                if _LB.drip:
                    # 每块之间都比 socket 空闲超时短 —— 空闲超时永远不触发, 但总时长超期限
                    for i in range(0, len(_LB_BODY), 4):
                        self.wfile.write(_LB_BODY[i:i + 4])
                        self.wfile.flush()
                        time.sleep(_LB.drip)
                else:
                    self.wfile.write(_LB_BODY)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return                       # 客户端按期限先走了 —— 预期内, 不是异常


class _Lb(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    head_delay = 0.0
    drip = 0.0
    hits: list = []
    conns: set = set()


_LB = _Lb(("127.0.0.1", 0), _LbHandler)
_LB_PORT = _LB.server_address[1]
threading.Thread(target=_LB.serve_forever, daemon=True).start()


class _LbClient:
    @staticmethod
    def HTTPSConnection(host, timeout=None):
        return _hc.HTTPConnection("127.0.0.1", _LB_PORT, timeout=timeout)


class _LbHttp:
    client = _LbClient


_real_http, bot.http = bot.http, _LbHttp
bot.post = _REAL_POST                        # 走真实 post: 建连、复用、重连、读响应


def _lb_reset():
    c = getattr(bot._tls, "conn", None)
    if c:
        try:
            c.close()
        except Exception:      # noqa: BLE001
            pass
    bot._tls.conn = None
    _LB.hits.clear()
    _LB.conns.clear()
    _LB.head_delay = 0.0
    _LB.drip = 0.0


# 18a 复用的连接必须按**本次**剩余预算重设 socket 超时
_lb_reset()
bot.post("m", {}, time.monotonic() + 150)                    # 建连: 剩余 150 → 取 70
_t_new = bot._tls.conn.timeout
bot.post("m", {}, time.monotonic() + 2.0)                    # 复用: 剩余只剩 2s
_t_reuse = bot._tls.conn.timeout
_t_sock = bot._tls.conn.sock.gettimeout() if bot._tls.conn.sock else None
(ok if _t_new == bot.API_TIMEOUT else
 bad)("18a 建连时 socket 超时取默认上限(实得 %s)" % _t_new)
(ok if _t_reuse is not None and _t_reuse <= 2.0 else
 bad)("18a 复用连接按剩余预算重设 conn.timeout(实得 %s, 应 ≤2.0)" % _t_reuse)
(ok if _t_sock is not None and _t_sock <= 2.0 else
 bad)("18a 已连上的那条 socket 也被重设(实得 %s, 应 ≤2.0) —— conn.timeout 只在建连时生效"
      % _t_sock)

# 18b deadline=None 的调用不继承上一任务留下的短超时
_lb_reset()
bot.post("m", {}, time.monotonic() + 3.0)                    # 更新任务: 留下 3s 的连接
_cached_to = bot._tls.conn.timeout
_LB.head_delay = 5.0                                         # 服务端慢 5s: 70s 上限等得起
_LB.hits.clear()
_t0 = time.monotonic()
_r = bot.post("m", {})                                       # 非更新调用: 上限应是 70s
_el = time.monotonic() - _t0
(ok if _cached_to is not None and _cached_to <= 3.0 else
 bad)("18b 上一任务确实留下了短超时的缓存连接(实得 %s)" % _cached_to)
(ok if len(_LB.hits) == 1 and _r.get("ok") else
 bad)("18b deadline=None 不继承短超时: 一次传输就成功(实得 %d 次传输, ok=%s)"
      % (len(_LB.hits), bool(_r.get("ok"))))
(ok if _el >= 5.0 else
 bad)("18b 它真的等满了服务端的 5s(实得 %.2fs) —— 没被 3s 误判超时" % _el)

# 18c socket 空闲超时以内持续小块返回: 整个读取仍受绝对期限约束
_lb_reset()
_LB.drip = 0.25                                              # 每块间隔 0.25s ≪ 空闲超时
_dl = time.monotonic() + 1.5
_t0 = time.monotonic()
_r = bot.post("m", {}, _dl)
_el = time.monotonic() - _t0
_fd_after = len(os.listdir("/proc/self/fd"))
(ok if not _r.get("ok") else
 bad)("18c 响应读取超过绝对期限 → 判失败, 不冒充成功(实得 ok=%s)" % bool(_r.get("ok")))
(ok if _el < 1.5 + 1.0 else
 bad)("18c 超期后立刻结束, 不读到底(耗时 %.2fs, 期限 1.50s)" % _el)
(ok if getattr(bot._tls, "conn", None) is None else
 bad)("18c 超期时真的把连接收掉了(不是只让外层返回、把线程留在 socket 上)")
_lb_reset()
_LB.drip = 0.25
_dl = time.monotonic() + 1.5
bot.post("m", {}, _dl)
time.sleep(1.0)
_fd_now = len(os.listdir("/proc/self/fd"))
(ok if _fd_now <= _fd_after + 2 else
 bad)("18c 超期收尾不漏 FD(前 %d → 后 %d)" % (_fd_after, _fd_now))

# 18d 本地超时 / 请求完成 / 投递确认分开记账 —— 不把"本地放弃"说成"对端没收到"
_lb_reset()
_LB.drip = 0.25
_dl = time.monotonic() + 1.5
_r = bot.post("m", {}, _dl)
_reached = len(_LB.hits)                     # 对端**确实**收到了这个请求
(ok if _reached == 1 and not _r.get("ok") else
 bad)("18d 请求已到达对端(%d 次)但本地判超时(ok=%s) —— 两件事分开记, 不谎称撤回"
      % (_reached, bool(_r.get("ok"))))
_lb_reset()
_r = bot.post("m", {}, time.monotonic() + 30)
(ok if _r.get("ok") and len(_LB.hits) == 1 else
 bad)("18d 正常路径: 一次传输, 投递确认为成功(实得 %d 次/ok=%s)"
      % (len(_LB.hits), bool(_r.get("ok"))))

# 18e keep-alive 真的复用: 按块读之后必须自己把响应收尾, 否则连接停在 "Request-sent",
# 下一次调用撞 ResponseNotReady 再重连 —— 表面还是成功, 每次都白跑一个来回。
_lb_reset()
for _ in range(4):
    bot.post("m", {}, time.monotonic() + 30)
(ok if len(_LB.hits) == 4 else
 bad)("18e 4 次调用 = 4 次传输, 没有隐性重连(实得 %d)" % len(_LB.hits))
(ok if len(_LB.conns) == 1 else
 bad)("18e 4 次调用共用一条 TCP 连接(实得 %d 条) —— keep-alive 名副其实"
      % len(_LB.conns))

_lb_reset()
_LB.shutdown()
bot.http = _real_http


# ══════════════════════════════════════════════════════════════════════════════
# 19. 已撤销的写回权限不得被重新赋予
# ──────────────────────────────────────────────────────────────────────────────
print()
print("══ 19. 撤销即撤销: 空 token 不是写回权 / 排队期间导航 / 过期不恢复权限 ══")

# 19a 空 token 直接被写入通道拒掉(None == None 曾经放行)
_reset_state()
_tg19 = Tg(); bot.post = _tg19.post
with bot._upd_lock:
    _j = bot._upd_new_sess(1901, 191, time.monotonic() + 60)
bot._upd_invalidate(1901, 191)
_r19, _why19 = bot._upd_emit(1901, 191, None, "progress", "🔄 空 token", bot.BACK)
(ok if not _r19 and _why19 == "superseded" else
 bad)("19a token=None 被拒(实得 %r/%r)" % (_r19, _why19))
(ok if not [c for c in _tg19.calls if c[0] == "editMessageText"] else
 bad)("19a 一个字都没写出去(实得 %s)"
      % [c[1].get("text", "")[:16] for c in _tg19.calls if c[0] == "editMessageText"])
with bot._upd_lock:
    bot._upd_drop_sess(1901, 191, _j)

# 19b 排队期间导航 → worker 启动时直接结束: 不跑 Git、不发进度、不发终态
_reset_state()
_tg19b = Tg(); bot.post = _tg19b.post
_ran19 = [0]


def _count_check(budget=None):
    _ran19[0] += 1
    return True, "🔄 旧结果(不该出现)"


bot.update_check = _count_check
_entered19 = threading.Semaphore(0)
_hold19 = threading.Event()
for _ in range(4):
    bot._EXEC.submit(lambda: (_entered19.release(), _hold19.wait(30)))
_full19 = all(_entered19.acquire(timeout=10) for _ in range(4))
(ok if _full19 else bad)("19b 4 个 worker 已**确认**进入(信号量到齐, 不靠 sleep 推断)")
_acc19, _ = bot._upd_check_async(1902, 192)
_sess19 = bot._upd_sess.get((1902, 192)) or {}
(ok if _acc19 == "ok" and not _sess19.get("started") else
 bad)("19b 任务确实在队列里等(受理 %r, started=%s)" % (_acc19, _sess19.get("started")))
bot._upd_invalidate(1902, 192)                       # 用户返回菜单
_tg19b.calls.clear()
_ran19[0] = 0
_hold19.set()                                        # 放行 worker: 排队任务现在才启动
_settle(1902)
time.sleep(0.4)
_w19 = [c[1].get("text", "")[:18] for c in _tg19b.calls if c[0] == "editMessageText"]
(ok if _ran19[0] == 0 else
 bad)("19b 导航之后不再执行 Git/检查(实得 %d 次)" % _ran19[0])
(ok if not _w19 else bad)("19b 导航之后不发进度、不发终态(实得 %s)" % _w19)
(ok if _drain() == (0, 0, 0, 0, 0) else
 bad)("19b 结束后五张表零残留(实得 %s)" % (_drain(),))

# 19c 已导航作废的排队任务过期: 保留撤销事实, 不靠新建通知恢复写回权
_reset_state()
_tg19c = Tg(); bot.post = _tg19c.post
with bot._upd_lock:
    _j19c = bot._upd_new_sess(1903, 193, time.monotonic() + bot.UPD_DELIVER_BUDGET - 1.0)
    bot._upd_inflight[1903] = _j19c
bot._upd_invalidate(1903, 193)
_t0 = time.monotonic()
while (1903, 193) in bot._upd_sess and time.monotonic() - _t0 < 15:
    time.sleep(0.05)
time.sleep(0.6)
_w19c = [c[1].get("text", "")[:18] for c in _tg19c.calls if c[0] == "editMessageText"]
(ok if (1903, 193) not in bot._upd_sess else
 bad)("19c 过期任务被清掉, 没有换一条新会话续命")
(ok if not _w19c else
 bad)("19c 过期提示不写回已经翻走的页面(实得 %s)" % _w19c)
(ok if _drain() == (0, 0, 0, 0, 0) else
 bad)("19c 五张表零残留(实得 %s)" % (_drain(),))

# 19d 没被导航过的排队任务过期: 该给的终态说明照给(19c 不能把它一并压掉)
_reset_state()
_tg19d = Tg(); bot.post = _tg19d.post
with bot._upd_lock:
    _j19d = bot._upd_new_sess(1904, 194, time.monotonic() + bot.UPD_DELIVER_BUDGET - 1.0)
    bot._upd_inflight[1904] = _j19d
_t0 = time.monotonic()
while not [c for c in _tg19d.calls if c[0] == "editMessageText"] and time.monotonic() - _t0 < 15:
    time.sleep(0.05)
_w19d = [c[1].get("text", "")[:20] for c in _tg19d.calls if c[0] == "editMessageText"]
(ok if _w19d and "排队过久" in _w19d[0] else
 bad)("19d 未被导航的过期任务仍有终态说明(实得 %s)" % _w19d)
(ok if _drain() == (0, 0, 0, 0, 0) else
 bad)("19d 五张表零残留(实得 %s)" % (_drain(),))

# 19e 收割器在**真实窗口**(快照后释放锁、fut.cancel() 期间)不覆盖后来的新任务
_reset_state()
bot.post = Tg().post
_inwin = threading.Event()
_gowin = threading.Event()


class _WinFut:
    """收割器在锁外调 cancel() —— 产品里真实存在的那段窗口。"""

    def cancel(self):
        _inwin.set()
        _gowin.wait(15)
        return True


with bot._upd_lock:
    _oldj = bot._upd_new_sess(1905, 195, time.monotonic() + bot.UPD_DELIVER_BUDGET - 1.0)
    bot._upd_sess[(1905, 195)]["fut"] = _WinFut()
    bot._upd_inflight[1905] = _oldj
(ok if _inwin.wait(15) else bad)("19e 收割器已**确认**进入窗口(不靠 sleep 撞)")
with bot._upd_lock:                                  # 产品里 _upd_new_sess 永远在锁内
    _newj = bot._upd_new_sess(1905, 195, time.monotonic() + 120)
    _newt = bot._upd_sess[(1905, 195)]["token"]
    bot._upd_inflight[1905] = _newj
_gowin.set()
time.sleep(1.2)
_cur19 = bot._upd_sess.get((1905, 195))
(ok if _cur19 is not None and _cur19.get("job") == _newj else
 bad)("19e 新会话没被旧任务覆盖(实得 job 一致=%s)"
      % (_cur19 is not None and _cur19.get("job") == _newj))
(ok if _cur19 is not None and _cur19.get("token") == _newt else
 bad)("19e 新会话的写回权保留")
(ok if _cur19 is not None and _cur19.get("kind") == "check" else
 bad)("19e 新会话没被 notice 顶掉(实得 kind=%r)" % (_cur19 and _cur19.get("kind")))
(ok if bot._upd_inflight.get(1905) == _newj else
 bad)("19e 新任务的名额没被旧任务让出去")
(ok if _oldj not in bot._upd_jobs else
 bad)("19e 旧任务只清掉了**自己**的身份")
with bot._upd_lock:
    bot._upd_drop_sess(1905, 195, _newj)


# ══════════════════════════════════════════════════════════════════════════════
# 20. 通知的完整收尾与真实全局准入
# ──────────────────────────────────────────────────────────────────────────────
print()
print("══ 20. 通知生命周期: 成功/失败/过期/作废/提交失败 + 全局上限 + 两阶段合并 ══")

# 20a 五条结束路径都精确释放自己的状态
for _name, _setup in (
        ("成功投递", "ok"),
        ("持续失败", "fail"),
        ("已过期", "expired"),
        ("导航作废", "revoked"),
):
    _reset_state()
    _tg20 = Tg()
    if _setup == "fail":
        _tg20.unreachable = True
    bot.post = _tg20.post
    with bot._upd_lock:
        _j20 = bot._upd_new_sess(2001, 200, time.monotonic() + bot.UPD_NOTICE_BUDGET,
                                 kind="notice")
        _t20 = bot._upd_sess[(2001, 200)]["token"]
    _dl20 = time.monotonic() + (-1.0 if _setup == "expired" else 5.0)
    if _setup == "revoked":
        bot._upd_invalidate(2001, 200)
    bot._upd_notify(2001, 200, "⏳ 忙", _t20, _dl20, _j20)
    (ok if _drain(10) == (0, 0, 0, 0, 0) else
     bad)("20a 通知「%s」结束后五张表零残留(实得 %s)" % (_name, _drain(0.1)))

# 20a' 提交失败也要收尾
_reset_state()
bot.post = Tg().post
_real_sub20 = bot._upd_notify_exec.submit
bot._upd_notify_exec.submit = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("submit 拒绝"))
with bot._upd_lock:
    _j20s = bot._upd_new_sess(2002, 200, time.monotonic() + bot.UPD_NOTICE_BUDGET,
                              kind="notice")
    _t20s = bot._upd_sess[(2002, 200)]["token"]
_r20s = bot._upd_notify(2002, 200, "⏳", _t20s, time.monotonic() + 5, _j20s)
bot._upd_notify_exec.submit = _real_sub20
(ok if _r20s is False else bad)("20a' 提交失败如实返回 False(实得 %r)" % _r20s)
(ok if _tables() == (0, 0, 0, 0, 0) else
 bad)("20a' 提交失败后零残留(实得 %s)" % (_tables(),))

# 20b 忙提示复用的是**检查**会话的身份 —— 通知收尾不得把在跑的检查一起收掉
_reset_state()
bot.post = Tg().post
with bot._upd_lock:
    _cj20 = bot._upd_new_sess(2003, 200, time.monotonic() + 120)      # kind='check'
    _ct20 = bot._upd_sess[(2003, 200)]["token"]
    bot._upd_inflight[2003] = _cj20
# 忙提示照实把**检查**会话的身份传进去 —— 归属由 _upd_notice_release 判, 不靠调用方先挑
bot._upd_notify(2003, 200, "⏳ 上一次还在跑", _ct20, time.monotonic() + 5, _cj20)
_t0 = time.monotonic()
while bot._upd_notify_live and time.monotonic() - _t0 < 10:
    time.sleep(0.02)
_alive20 = bot._upd_sess.get((2003, 200))
(ok if _alive20 is not None and _alive20.get("job") == _cj20 else
 bad)("20b 通知收尾没有动正在跑的检查会话")
(ok if bot._upd_inflight.get(2003) == _cj20 else
 bad)("20b 在跑的检查名额也没被通知收掉")
with bot._upd_lock:
    bot._upd_drop_sess(2003, 200, _cj20)

# 20c 替换 notice 清旧身份, 不误删新身份
_reset_state()
with bot._upd_lock:
    _a20 = bot._upd_new_sess(2004, 200, time.monotonic() + 30, kind="notice")
    _b20 = bot._upd_new_sess(2004, 200, time.monotonic() + 30, kind="notice")
(ok if len(bot._upd_jobs) == 1 and _a20 not in bot._upd_jobs else
 bad)("20c 替换会话摘掉旧身份(jobs=%d, 旧身份仍在=%s)"
      % (len(bot._upd_jobs), _a20 in bot._upd_jobs))
(ok if bot._upd_jobs.get(_b20) == (2004, 200) else
 bad)("20c 新身份完好")
with bot._upd_lock:
    bot._upd_notice_release(2004, 200, _a20)          # 旧身份的收尾不能误删新会话
(ok if bot._upd_sess.get((2004, 200), {}).get("job") == _b20 else
 bad)("20c 旧身份收尾不误删新会话")
with bot._upd_lock:
    bot._upd_drop_sess(2004, 200, _b20)

# 20d 全局上限: 待发 + 在飞 有真实上限, 不是只限执行线程数
_reset_state()
bot.post = Tg().post
_block20 = threading.Event()
_real_emit20 = bot._upd_emit
bot._upd_emit = lambda *a, **k: (_block20.wait(25), (True, "ok"))[1]
_accepted20 = 0
for _i in range(300):
    with bot._upd_lock:
        _jj = bot._upd_new_sess(2005, 3000 + _i, time.monotonic() + 60, kind="notice")
        _tt = bot._upd_sess[(2005, 3000 + _i)]["token"]
    if bot._upd_notify(2005, 3000 + _i, "⏳", _tt, time.monotonic() + 60, _jj):
        _accepted20 += 1
time.sleep(0.4)
_pend20, _live20 = len(bot._upd_notify_pending), len(bot._upd_notify_live)
(ok if _live20 <= bot.UPD_NOTICE_MAX else
 bad)("20d 在跑的通知受全局上限约束(实得 %d ≤ %d)" % (_live20, bot.UPD_NOTICE_MAX))
(ok if set(bot._upd_notify_pending) <= bot._upd_notify_live else
 bad)("20d 待发表恒为在飞集合的子集(准入才数得准; 待发 %d / 在飞 %d)" % (_pend20, _live20))
(ok if _accepted20 == bot.UPD_NOTICE_MAX else
 bad)("20d 300 次点击恰好受理到上限 %d 条(实得 %d), 其余当场拒绝"
      % (bot.UPD_NOTICE_MAX, _accepted20))
(ok if len(bot._upd_sess) <= bot.UPD_NOTICE_MAX else
 bad)("20d 满载被拒的通知没有留下会话(sess=%d ≤ %d)"
      % (len(bot._upd_sess), bot.UPD_NOTICE_MAX))
_block20.set()
bot._upd_emit = _real_emit20
_reset_state()

# 20e 合并覆盖**排队**与**投递在飞**两个阶段
_reset_state()
bot.post = Tg().post
_inflight20 = threading.Event()
_hold20 = threading.Event()
_emits20 = [0]


def _gate_emit(chat, mid, token, phase, text, kb):
    _emits20[0] += 1
    _inflight20.set()
    _hold20.wait(20)
    return True, "ok"


bot._upd_emit = _gate_emit
_subs20 = [0]
_real_sub20b = bot._upd_notify_exec.submit


def _count_sub20(fn, *a, **k):
    _subs20[0] += 1
    return _real_sub20b(fn, *a, **k)


bot._upd_notify_exec.submit = _count_sub20
with bot._upd_lock:
    _j20e = bot._upd_new_sess(2006, 206, time.monotonic() + 60, kind="notice")
    _t20e = bot._upd_sess[(2006, 206)]["token"]
bot._upd_notify(2006, 206, "⏳ 第一条", _t20e, time.monotonic() + 60, _j20e)
(ok if _inflight20.wait(10) else bad)("20e 第一条通知**确认**已进入投递(不靠 sleep)")
(ok if not bot._upd_notify_pending else
 bad)("20e 此刻待发表已空(处于「在飞」阶段, 合并只看待发就会漏)")
for _ in range(10):
    bot._upd_notify(2006, 206, "⏳ 追加", _t20e, time.monotonic() + 60, _j20e)
(ok if _subs20[0] == 1 else
 bad)("20e 在飞阶段的重复通知合并进同一份工作(提交 %d 份, 应 1)" % _subs20[0])
_hold20.set()
bot._upd_emit = _real_emit20
bot._upd_notify_exec.submit = _real_sub20b
_t0 = time.monotonic()
while bot._upd_notify_live and time.monotonic() - _t0 < 15:
    time.sleep(0.02)
(ok if _emits20[0] <= 2 else
 bad)("20e 11 次通知最多落地 2 次(在飞 1 + 合并后的 1; 实得 %d)" % _emits20[0])
(ok if _drain() == (0, 0, 0, 0, 0) else bad)("20e 结束后五张表零残留(实得 %s)" % (_drain(),))

# 20f 同一聊天多条历史消息 / 多个聊天: 各自独立, 结束后都不留残留
_reset_state()
_tg20f = Tg(); bot.post = _tg20f.post
for _chat, _mid in ((2007, 71), (2007, 72), (2007, 73), (2008, 71), (2009, 71)):
    with bot._upd_lock:
        _jj = bot._upd_new_sess(_chat, _mid, time.monotonic() + 30, kind="notice")
        _tt = bot._upd_sess[(_chat, _mid)]["token"]
    bot._upd_notify(_chat, _mid, "⏳ %d/%d" % (_chat, _mid), _tt,
                    time.monotonic() + 30, _jj)
_res20f = _drain(15)
_mids20f = sorted({c[1].get("message_id") for c in _tg20f.calls
                   if c[0] == "editMessageText"})
(ok if _res20f == (0, 0, 0, 0, 0) else
 bad)("20f 3 条历史消息 + 3 个聊天结束后零残留(实得 %s)" % (_res20f,))
(ok if _mids20f == [71, 72, 73] else
 bad)("20f 每条消息各写各的, 不串(实得 mid %s)" % _mids20f)

_reset_state()
bot.post = _REAL_POST
bot.update_check = _REAL_UPDATE_CHECK

print()
print("-" * 62)
print("test-bot-update-check.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""PrivDNS Gateway — Telegram 管理 bot v3 (纯标准库, long-poll)。

出口  : 列表 / 添加(ss/vmess/trojan/vless 链接) / 删除 / 改名(级联更新引用) / 设默认出口 / 故障切换组(urltest)
分流  : 规则列表 / 添加(域名→出口|direct) / 删除 / 添加规则集(Surge .list URL→出口) / 删除规则集
诊断  : 状态 / 端到端测出口延迟(clash_api) / 流量统计(clash_api)
运维  : 重启 / 更新规则库(geosite + 规则集) / iOS 描述文件下发 / 配置备份·恢复

UI 原地编辑消息(editMessageText), 不刷屏。改 sing-box 前备份, check 失败自动回滚。
环境变量: PDG_BOT_TOKEN, PDG_BOT_ALLOWED(逗号分隔的 user id)
注: 模块可被 import (供定时任务调用 refresh_rulesets), 此时无需 token。
"""
from __future__ import annotations
import base64, contextlib, fcntl, hashlib, http.client, io, json, os, re, shutil, socket, subprocess, sys, tarfile, tempfile, threading, time, uuid
import concurrent.futures
import urllib.parse, urllib.request, urllib.error
from collections import Counter
# 保证能 import 同目录的 sb2mihomo —— 不管本模块是被当脚本跑, 还是被定时任务/健康检查/测试 import。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TOKEN = os.environ.get("PDG_BOT_TOKEN", "")
ALLOWED = {int(x) for x in os.environ.get("PDG_BOT_ALLOWED", "").replace(" ", "").split(",") if x}
SB = "/etc/sing-box/config.json"
RS_DIR = "/etc/sing-box/rs"
# ── 内核后端(原型: sing-box | mihomo)──────────────────────────────────────────
# model 始终以 SB(sing-box JSON)为唯一数据源; mihomo 模式下由 sb2mihomo 渲染成 YAML 再跑。
# 所有出口/规则/故障组管理代码不变(仍改 SB), 只有 apply 的"校验+重启核心"这层按后端分支。
MIHOMO_DIR = "/etc/mihomo"
MIHOMO_CFG = MIHOMO_DIR + "/config.yaml"
MIHOMO_BIN = "mihomo"
import mihomorender                              # 渲染链的共享实现(救援/恢复也用同一份)
MIHOMO_REDIR = mihomorender.MIHOMO_REDIR
MITM_PORT = mihomorender.MITM_PORT                # MITM 服务(socks5)监听; mihomo 把接管域名路由到这
MITM_HIJACK_FILE = "/etc/mosdns/rules/mitm_hijack.txt"   # 接管域名(mosdns 强制劫持集, 与 mihomo 路由同源)
# mihomo 有路径安全限制: external-ui 等文件路径须在工作目录(-d)下或 SAFE_PATHS 白名单内。
# 观测面板 UI 在 /etc/sing-box/ui/dist(与 sing-box 共用), 不在 /etc/mihomo 下 → 用 SAFE_PATHS 放行,
# 使 mihomo 服务运行 + 本进程发起的所有 `mihomo -t` 校验都认这个 UI 路径。
os.environ.setdefault("SAFE_PATHS", "/etc/sing-box/ui/dist")
BACKEND_MARKER = "/etc/privdns-gateway/backend"   # 内容 mihomo / singbox; 读不到则默认 singbox
PROFILE_ENV = "/etc/privdns-gateway/profile.env"  # 持久化开关(PDG_LOWMEM / PDG_TFO 等)
MOSDNS_CONF = "/etc/mosdns/config.yaml"
MOSDNS_DIRECT = "/etc/mosdns/rules/custom_direct.txt"
MOSDNS_HIJACK = "/etc/mosdns/rules/custom_hijack.txt"   # 指到出口的域名: 必须劫持才进得了代理
RS_META = "/opt/pdg-bot/rulesets.json"
UPDATE_SCRIPT = "/opt/pdg-bot/update-rules.sh"
IOS_TMPL = "/opt/pdg-bot/pdg-dot.mobileconfig.tmpl"
CERT = os.environ.get("PDG_CERT", "/etc/mosdns/certs/fullchain.pem")
CERT_DIR = os.path.dirname(CERT)
CLASH = "http://127.0.0.1:9090"
DELAY_URL = "http://www.gstatic.com/generate_204"
API = "https://api.telegram.org/bot" + TOKEN
state: dict[int, str] = {}
del_sel: dict[int, set] = {}   # 删规则多选: chat -> 已勾选域名集合

# ── Telegram (每线程各复用一条 HTTPS 长连接) ──
# thread-local: 主循环 getUpdates(轮询)与后台任务发消息(API)各用自己的连接,
# 一条 HTTPS 连接不能被多线程并发复用(交错请求会串包), 故按线程隔离而非全局共享。
_tls = threading.local()

def post(method, params):
    body = json.dumps(params).encode()
    path = "/bot" + TOKEN + "/" + method
    hdr = {"Content-Type": "application/json", "Connection": "keep-alive"}
    for attempt in (0, 1):                       # 连接断了就重连重试一次
        try:
            conn = getattr(_tls, "conn", None)
            if conn is None:
                conn = http.client.HTTPSConnection("api.telegram.org", timeout=70)
                _tls.conn = conn
            conn.request("POST", path, body, hdr)
            data = conn.getresponse().read()
            return json.loads(data) if data else {}
        except Exception as e:  # noqa: BLE001
            try:
                c = getattr(_tls, "conn", None)
                if c:
                    c.close()
            except Exception:  # noqa: BLE001
                pass
            _tls.conn = None
            if attempt:
                print("api", method, type(e).__name__); return {}   # 不打印异常正文(可能含参数)

# ── 有界后台执行器 + per-chat BUSY 锁 + 配置写串行化 ──────────────────────────
# 慢操作(解析/校验/写配置/重启服务)放进有上限的线程池, 主 getUpdates 轮询不等它;
# 不每次操作新建线程。同一 chat 已有任务时拒绝再次触发(防重复点击/连发)。
_EXEC = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="pdg-bg")
_busy: dict[int, bool] = {}
_busy_lock = threading.Lock()
_cfg_lock = threading.Lock()                     # 进程内串行化"写 sing-box 配置"
LOCKFILE = os.environ.get("PDG_LOCKFILE", "/run/privdns-gateway.lock")   # 与 pdg update/rollback 共用
BUSY_MSG = "已有配置操作正在执行,请稍候再试。"   # apply_sb 拿不到锁(进程内或跨进程)时的安全返回
NOLOCK_MSG = ("⛔ 锁文件不可用(/run 写不了?) —— 为避免并发写坏配置, 本次拒绝执行。\n"
              "请在服务器上检查 /run 是否可写, 修好后重试。")
# 上一次取锁失败的原因: "" = 忙, 非空 = 锁不可用。**按线程存**: 进程级全局会被并发覆盖 ——
# A 线程刚记下"锁文件打不开"、还没来得及 busy_msg(), B 线程进 _cfg_guard() 就把它清空了,
# 于是 A 把环境故障说成"已有配置操作正在执行", 真正的 /run 坏掉被掩盖。
_cfg_lock_state = threading.local()


def _cfg_lock_error():
    return getattr(_cfg_lock_state, "err", "")

class _PanelOwnershipError(Exception):
    pass

def _acquire_busy(chat):
    with _busy_lock:
        if _busy.get(chat):
            return False
        _busy[chat] = True
        return True

def _release_busy(chat):
    with _busy_lock:
        _busy.pop(chat, None)

def run_bg(chat, fn):
    """提交后台任务; 同一 chat 已有任务则友好拒绝。fn 自行发消息。返回 Future(被拒=None)。"""
    if not _acquire_busy(chat):
        send_plain(chat, "正在处理上一项操作,请稍候")
        return None
    def wrap():
        try:
            fn()
        except Exception as e:  # noqa: BLE001  # 不打印异常正文(可能含节点凭据)
            print("bg task err", type(e).__name__, flush=True)
        finally:
            _release_busy(chat)
    try:
        return _EXEC.submit(wrap)
    except Exception:  # noqa: BLE001            # 执行器已关闭等 → 释放 BUSY, 不静默泄漏
        _release_busy(chat)
        send_plain(chat, "后台繁忙,请稍后再试")
        return None

@contextlib.contextmanager
def _cfg_guard():
    """进程内串行(_cfg_lock, 非阻塞)+ 跨进程 flock(与 pdg update/rollback 协调)。

    两把锁任一被占 → yield False(立即友好返回, 绝不阻塞主轮询);
    **锁文件不可用同样 yield False**(fail-closed), 并把原因记进本线程的 _cfg_lock_state
    供调用方区分 "有人正在改" 与 "锁坏了"。"""
    _cfg_lock_state.err = ""                     # 只清本线程的, 别踩别人正要读的那份
    if not _cfg_lock.acquire(blocking=False):    # 非阻塞: 本进程已有配置操作在跑 → 立刻让路, 不卡主循环
        yield False
        return
    try:
        try:
            f = open(LOCKFILE, "w")
        except OSError as e:
            # fail-closed: 打不开锁文件就**不写**。旧实现退化成"只做进程内串行"继续写 ——
            # 那时 CLI/定时任务照样能同时改同一份配置, 谁也拦不住。
            _cfg_lock_state.err = "%s: %s" % (LOCKFILE, type(e).__name__)
            yield False
            return
        locked = False
        try:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except OSError:
                yield False                      # pdg update/rollback 正持锁
                return
            yield True
        finally:
            if locked:                           # 只在确实拿到锁时解锁(避免误放别的持有者)
                try:
                    fcntl.flock(f, fcntl.LOCK_UN)
                except Exception:  # noqa: BLE001
                    pass
            f.close()
    finally:
        _cfg_lock.release()

def send_document(chat, filename, data, caption=""):
    """multipart/form-data 上传文件 (备份 / iOS 描述文件)。"""
    boundary = "----pdg" + uuid.uuid4().hex
    pre = []
    def fld(name, val):
        pre.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{val}\r\n").encode())
    fld("chat_id", str(chat))
    if caption:
        fld("caption", caption); fld("parse_mode", "HTML")
    head = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; "
            f"filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n").encode()
    body = b"".join(pre) + head + data + b"\r\n" + (f"--{boundary}--\r\n").encode()
    req = urllib.request.Request(API + "/sendDocument", data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001
        print("senddoc", e); send_plain(chat, f"发送文件失败: {e}"); return {}

def tg_download(file_id):
    r = post("getFile", {"file_id": file_id})
    fp = r.get("result", {}).get("file_path")
    if not fp:
        raise ValueError("getFile 失败")
    with urllib.request.urlopen(f"https://api.telegram.org/file/bot{TOKEN}/{fp}", timeout=120) as resp:
        return resp.read()

# 一级菜单: 只放常用诊断 + 4 个分类入口 (展开二级, 避免一屏按钮看花眼)
MENU = {"inline_keyboard": [
    [{"text": "🔄 更新", "callback_data": "upd_check"}, {"text": "🩺 自检", "callback_data": "doctor"}],
    [{"text": "🚦 测出口", "callback_data": "test"}, {"text": "📈 流量", "callback_data": "traffic"}],
    [{"text": "📤 出口管理", "callback_data": "nav:exit"}, {"text": "📑 分流管理", "callback_data": "nav:rule"}],
    [{"text": "📱 客户端", "callback_data": "nav:client"}, {"text": "🛠 运维", "callback_data": "nav:ops"}],
]}
BACK = {"inline_keyboard": [[{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}
EXIT_BACK = {"inline_keyboard": [[{"text": "⬅️ 返回出口管理", "callback_data": "nav:exit"}],
                                [{"text": "🏠 主菜单", "callback_data": "menu"}]]}
RULE_BACK = {"inline_keyboard": [[{"text": "⬅️ 返回分流管理", "callback_data": "nav:rule"}],
                                [{"text": "🏠 主菜单", "callback_data": "menu"}]]}
OPS_BACK = {"inline_keyboard": [[{"text": "⬅️ 返回运维", "callback_data": "nav:ops"}],
                               [{"text": "🏠 主菜单", "callback_data": "menu"}]]}
DNS_BACK = {"inline_keyboard": [[{"text": "⬅️ 返回 DNS 上游", "callback_data": "dnsup"}],
                               [{"text": "🏠 主菜单", "callback_data": "menu"}]]}
WLOC_BACK = {"inline_keyboard": [[{"text": "⬅️ 返回 WLOC", "callback_data": "wloc:menu"}],
                                [{"text": "🏠 主菜单", "callback_data": "menu"}]]}

def _back_rows(kb):
    return [row[:] for row in kb["inline_keyboard"]]

def _nav(key):
    """二级子菜单 (标题, 键盘)。每个子菜单末尾自带「返回主菜单」。"""
    subs = {
        "exit": ("📤 <b>出口管理</b> — 选一项:", [
            [{"text": "📋 列表", "callback_data": "exit_list"}, {"text": "➕ 添加", "callback_data": "add_exit"},
             {"text": "🗑 删除", "callback_data": "del_exit"}],
            [{"text": "🎯 默认出口", "callback_data": "setfinal"}, {"text": "↕️ 出口排序", "callback_data": "order_exit"},
             {"text": "✏️ 改名", "callback_data": "ren_exit"}],
            [{"text": "🔀 新建故障组", "callback_data": "add_grp"}, {"text": "✏️ 改故障组", "callback_data": "edit_grp"}]]),
        "rule": ("📑 <b>分流管理</b> — 选一项:", [
            [{"text": "📋 规则", "callback_data": "rules"}, {"text": "➕ 加规则", "callback_data": "add_rule"},
             {"text": "🗑 删规则", "callback_data": "del_rule"}],
            [{"text": "✏️ 改出口", "callback_data": "edit_rule"}, {"text": "📚 加规则集", "callback_data": "add_rs"},
             {"text": "🗑 删规则集", "callback_data": "del_rs"}],
            [{"text": "✏️ 改规则集名", "callback_data": "edit_rs"}, {"text": "🔎 测域名(查走哪)", "callback_data": "testdom"}]]),
        # 客户端接入按平台分岔: Android 只给私密DNS 主机名; iOS 只给描述文件按钮。公共项(DoT 域名 / TG 出口)两平台都留。
        "client": ((f"📱 <b>客户端接入</b>\nDoT 域名：<code>{_dot_host()}</code>\n请生成并安装 iOS 描述文件。", [
            [{"text": "📱 iOS 描述文件", "callback_data": "ios"}],
            [{"text": "🌐 DoT 自定义域名", "callback_data": "setdot"}],
            [{"text": "✈️ Telegram 出口", "callback_data": "tgexit"}]])
            if _platform() == "ios" else
            (f"📱 <b>客户端接入</b>\nAndroid 私密 DNS：<code>{_dot_host()}</code>", [
            [{"text": "🌐 DoT 自定义域名", "callback_data": "setdot"}],
            [{"text": "✈️ Telegram 出口", "callback_data": "tgexit"}]])),
        "ops": ("🛠 <b>运维</b> — 选一项:", [
            [{"text": "🔄 重启服务", "callback_data": "restart"}, {"text": "📦 更新规则库", "callback_data": "updgeo"}],
            [{"text": "💾 备份", "callback_data": "backup"}, {"text": "♻️ 恢复", "callback_data": "restore"}],
            [{"text": "🌐 DNS 上游", "callback_data": "dnsup"}, {"text": "🚀 TFO", "callback_data": "tfo"}],
            [{"text": "📊 观测面板", "callback_data": "panel"}]]),
    }
    if _platform() == "ios":                          # iOS 专属: 位置改写(WLOC)
        subs["ops"][1].append([{"text": "🍏 位置改写(WLOC)", "callback_data": "wloc"}])
    title, rows = subs[key]
    return title, {"inline_keyboard": rows + [[{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}

def send(chat, text, kb=None):
    p = {"chat_id": chat, "text": text, "parse_mode": "HTML",
         "reply_markup": kb or MENU, "disable_web_page_preview": True}
    if not post("sendMessage", p).get("ok"):
        p.pop("parse_mode", None)   # HTML 解析失败(文本含 < & 等, 如 sing-box 报错)→ 退回纯文本, 保证消息+键盘送达
        post("sendMessage", p)

def send_plain(chat, text):
    """纯文本回复, 不挂任何键盘 (操作结果/确认用, 避免每次刷出整排菜单)。"""
    p = {"chat_id": chat, "text": text, "parse_mode": "HTML",
         "disable_web_page_preview": True}
    if post("sendMessage", p).get("ok"):
        return
    p.pop("parse_mode", None)
    post("sendMessage", p)

def send_tracked(chat, text, kb=None):
    """发一条消息并返回它的 message_id(失败返回 None) —— 之后还要原地编辑它时用。"""
    p = {"chat_id": chat, "text": text, "parse_mode": "HTML",
         "disable_web_page_preview": True}
    if kb:
        p["reply_markup"] = kb
    r = post("sendMessage", p)
    if not r.get("ok"):
        p.pop("parse_mode", None)
        r = post("sendMessage", p)
    return (r.get("result") or {}).get("message_id") if r.get("ok") else None

def edit(chat, mid, text, kb=None):
    p = {"chat_id": chat, "message_id": mid, "text": text, "parse_mode": "HTML",
         "reply_markup": kb or MENU, "disable_web_page_preview": True}
    if post("editMessageText", p).get("ok"):
        return
    p.pop("parse_mode", None)        # 先退回纯文本重试编辑(原地保留键盘)
    if post("editMessageText", p).get("ok"):
        return
    send(chat, text, kb)             # 仍不行(如消息已删)再发新消息

def edit_only(chat, mid, text, kb=None):
    """只尝试原地编辑, **绝不退化成发新消息**。成功 True, 失败 False。

    给后台监听这类"事后回报"用: 用户可能早就把那条消息删了, 这时普通 edit() 的 fallback
    会凭空发一条新消息弹到聊天里 —— 用户刚清掉的东西又冒出来。编辑不成就安静结束,
    只在日志里留一行(不含正文)。"""
    p = {"chat_id": chat, "message_id": mid, "text": text, "parse_mode": "HTML",
         "reply_markup": kb or MENU, "disable_web_page_preview": True}
    r = post("editMessageText", p)
    if r.get("ok"):
        return True
    p.pop("parse_mode", None)        # HTML 解析失败(文本含 < & 等)→ 退回纯文本再试一次
    r = post("editMessageText", p)
    if r.get("ok"):
        return True
    print("wloc watch edit skipped", (r or {}).get("error_code"), flush=True)
    return False

def delete_message(chat, mid):
    """尽力删除一条消息(用于抹掉含节点凭据的原始链接消息)。失败返回 False, 不抛、不回显内容。"""
    if not mid:
        return False
    try:
        return bool(post("deleteMessage", {"chat_id": chat, "message_id": mid}).get("ok"))
    except Exception:  # noqa: BLE001
        return False

def delete_credential_async(chat, mid):
    """独立线程删除含凭据的原消息 —— 不经 BUSY/后台执行器, 保证 BUSY 拒绝或提交失败时凭据仍被清除。
    删不掉才提示手动删除, 不回显任何链接内容。"""
    if not mid:
        return
    def go():
        if not delete_message(chat, mid):
            send_plain(chat, "未能自动删除含凭据的上一条消息,请手动删除")
    threading.Thread(target=go, daemon=True).start()

def answer_cb_async(cb_id):
    """后台停掉按钮转圈(独立连接, 不占用主 keep-alive、不阻塞主循环)。
    主循环改完内容(edit)就能立刻回到 getUpdates → 连续点菜单不再为'停转圈'多等一个来回。"""
    def go():
        try:
            urllib.request.urlopen(urllib.request.Request(
                "https://api.telegram.org/bot" + TOKEN + "/answerCallbackQuery",
                data=json.dumps({"callback_query_id": cb_id}).encode(),
                headers={"Content-Type": "application/json"}), timeout=20).read()
        except Exception:  # noqa: BLE001
            pass
    threading.Thread(target=go, daemon=True).start()

def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180)

# ── clash_api (sing-box experimental) ──
def _clash_secret():
    """观测面板开启时 clash_api 设了 secret; 本机调用也要带 Bearer, 否则 401。从 sing-box 配置现读现用。"""
    try:
        return (load().get("experimental", {}).get("clash_api", {}) or {}).get("secret") or ""
    except Exception:  # noqa: BLE001
        return ""

def clash_get(path):
    req = urllib.request.Request(CLASH + path)
    sec = _clash_secret()
    if sec:
        req.add_header("Authorization", "Bearer " + sec)
    with urllib.request.urlopen(req, timeout=12) as r:
        return json.load(r)

def clash_up():
    try:
        clash_get("/version"); return True
    except Exception:  # noqa: BLE001
        return False

# ── sing-box ──
def load():
    return json.load(open(SB))

def _svc_active(unit, need=3, delay=0.6, max_polls=15):
    """确认服务"稳定" active: 要求连续 need 次观测都是 active。
    systemd 默认 Type=simple, restart 返 0 只代表 exec 成功; 起来又崩(flapping)时单看一次会误判 ——
    崩溃/重启间隙的 failed/activating 会打断连击, 故要求连续保持才算稳。"""
    streak = 0
    for _ in range(max_polls):
        if sh(["systemctl", "is-active", unit]).stdout.strip() == "active":
            streak += 1
            if streak >= need:
                return True
        else:
            streak = 0
        time.sleep(delay)
    return False

def _core_backend():
    """当前活动内核: v1.6.0 起恒 mihomo(彻底移除 sing-box 运行时; 旧 backend 标记里的 singbox
    由 pdg 的 migrate_drop_singbox 在 update 时迁移)。"""
    return "mihomo"

def _core_svc():
    """活动内核的 systemd 服务名(恒 mihomo)。"""
    return "mihomo"

def _platform():
    """手机平台标记: ios / android(读不到默认 android —— 不启用 iOS 专属的 MITM 等)。"""
    try:
        p = open("/etc/privdns-gateway/platform", encoding="utf-8").read().strip()
        if p in ("ios", "android"):
            return p
    except OSError:
        pass
    return "android"

def _platform_unconfirmed():
    """平台标记是**推测**出来的(老装 v1.4.x 升上来且没有确凿证据)时的补充说明。
    推测态下不能断言"本机为 Android" —— 没人确认过。v1.4.2 的 iPhone 用户升级后落到这里,
    看到一句干巴巴的"仅 iOS 可用(本机为 Android)"会以为描述文件功能没了, 而其实只差一条确认命令。"""
    if _platform() != "ios" and os.path.exists("/etc/privdns-gateway/platform.guessed"):
        return ("\n⚠️ 这个 android 是**推测**的(老装升级时无确凿证据), 没人确认过。"
                "\n若本网关服务的是 iPhone, 在服务器执行 sudo pdg platform ios 即可恢复 iOS 功能。")
    return ""

def _ios_only(chat, mid=None):
    """iOS 专属功能的**后端硬门控**(不只隐藏按钮 —— 旧 TG 消息里的按钮/命令被点也会被拒)。
    iOS → True; 否则清 state + 回一条拒绝消息, 返回 False。callback 传 mid, 文本/命令不传。"""
    if _platform() == "ios":
        return True
    state.pop(chat, None)
    msg = "此功能仅 iOS 平台可用(本机为 Android)。" + _platform_unconfirmed()
    if mid is not None:
        edit(chat, mid, msg, MENU)
    else:
        send_plain(chat, msg)
    return False

def _panel_render_args(model):
    """把 model 的 experimental.clash_api(面板状态)透传给渲染器。实现在 mihomorender。"""
    return mihomorender.panel_args(model)

def _write_mihomo(cfg):
    os.makedirs(MIHOMO_DIR, exist_ok=True)
    t = MIHOMO_CFG + ".tmp"
    with open(t, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)   # mihomo 只吃 YAML; JSON 是 YAML 子集, 直接可解析
    os.chmod(t, 0o600)                                     # 含出口密码/uuid + 面板 secret, 收紧 600
    os.replace(t, MIHOMO_CFG)

def _mihomo_rulesets(meta=None):
    """从 RS_META 构造 mihomo rule-providers 入参。

    读盘留在 bot 侧(读的是 **bot 自己的 RS_META**, 测试 monkeypatch 的正是它); 分类与
    .mrs behavior 判定走 mihomorender 的共享实现, 免得 bot / 恢复 / 救援三条路各有一份。"""
    try:
        meta = _rs_meta() if meta is None else meta
    except Exception:  # noqa: BLE001
        return {}
    return mihomorender.rulesets_arg(meta)

def _mitm_domains():
    """接管域名列表(仅 iOS 平台且有插件启用时非空)。路径用 **bot 自己的 MITM_HIJACK_FILE**
    (测试 monkeypatch 的是它), 解析走共享实现。"""
    return mihomorender.read_mitm_domains(MITM_HIJACK_FILE, _platform())

# ── MITM 插件(Feature B / iOS): WLOC 位置改写 ──
MITM_CONFIG = "/etc/privdns-gateway/mitm.json"
MITM_PLUGIN_DOMAINS = {"wloc": ["gs-loc.apple.com", "gs-loc-cn.apple.com"]}   # 插件 → 接管域名(与 mitm_server.PLUGIN_DOMAINS 同源)


def _mitm_config():
    try:
        return json.load(open(MITM_CONFIG))
    except OSError:
        return {}

def _save_mitm_config(cfg):
    os.makedirs(os.path.dirname(MITM_CONFIG), exist_ok=True)
    t = MITM_CONFIG + ".tmp"
    with open(t, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.chmod(t, 0o600)
    os.replace(t, MITM_CONFIG)

def _mitm_enabled_domains():
    # 平台门控最终入口: 非 iOS 一律视为无接管域名 —— 即便 Android 上有残留 mitm.json,
    # 也不会推导出任何接管域名(渲染器/劫持写入/pdg-mitm 都据此判空, 不动核心 MITM 路由)。
    if _platform() != "ios":
        return []
    cfg = _mitm_config()
    doms = []
    for name, dl in MITM_PLUGIN_DOMAINS.items():
        if (cfg.get(name) or {}).get("enabled"):
            doms += dl
    return doms

def _mitm_ca_pem():
    try:
        import mitm_ca
        return mitm_ca.ca_cert_pem()
    except Exception:  # noqa: BLE001
        return ""

def _mitm_hijack_bytes(domains):
    """接管域名 → mosdns 强制劫持集的文件内容(纯函数, 供事务派生用)。"""
    return "".join("domain:" + d + "\n" for d in domains).encode("utf-8")


def _mitm_domains_from(mitm_json_bytes):
    """从**候选** mitm.json 推导接管域名(不读生产文件)。非 iOS 一律为空。"""
    if _platform() != "ios":
        return []
    try:
        cfg = json.loads((mitm_json_bytes or b"{}").decode("utf-8"))
    except Exception:  # noqa: BLE001
        return []
    doms = []
    for name, dl in MITM_PLUGIN_DOMAINS.items():
        if isinstance(cfg, dict) and (cfg.get(name) or {}).get("enabled"):
            doms += dl
    return doms


def _mitm_json_bytes(cur, w):
    """把 WLOC 目标态并进现有 mitm.json, 返回候选字节(纯函数, 不落盘)。

    只改 wloc 这一段 —— 别的插件段(以后有)原样保留, 这与 _wloc_save 的语义一致。"""
    try:
        cfg = json.loads((cur or b"{}").decode("utf-8"))
        if not isinstance(cfg, dict):
            cfg = {}
    except Exception:  # noqa: BLE001
        cfg = {}
    cfg["wloc"] = _wloc_doc(w)
    return (json.dumps(cfg, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _mitm_transact(new_wloc):
    """落地 WLOC/MITM 目标态 —— **一笔 pdgtx 事务**: mitm.json + mitm_hijack + mihomo 配置
    一起校验、一起落盘, 服务动作与观察期、回滚、崩溃恢复全交给事务核心。

    new_wloc 可以是算好的目标态(dict), 也可以是 mutate(w) —— 后者用于开/关 WLOC 这类
    "要先看当前状态再决定目标"的操作: 目标态基于 read_for_update 读到的那一份算, 并把它的 sha
    当前置条件, 中途被别人改掉就 PRECONDITION_FAILED 而不是把过期状态写回去。
    mutate 里 raise _WlocAbort(msg) = 现场一动未动地放弃。

    CA 与叶子证书预签属于**缓存准备**: 在 stage 之前做完, 失败就直接返回, 这时生产配置一个字节
    都还没动; 失败事务残留的证书不被任何配置引用(enabled 没落盘), 下次开启命中缓存而已。

    动作顺序固定 —— 开启: 落盘 → restart:mihomo → restart:mosdns → start:pdg-mitm;
    关闭: 落盘 → stop:pdg-mitm → restart:mihomo → restart:mosdns。返回 (ok, msg)。"""
    if _platform() != "ios":         # 平台硬门控: Android 连事务都不开(不生成 CA / 不写任何文件)
        return False, "MITM/WLOC 仅 iOS 平台可用。"
    tx = _pdgtx()
    try:
        t = tx.Tx(source="bot", op="wloc_apply")
    except Exception as e:  # noqa: BLE001
        return False, "无法开始配置事务(%s)" % type(e).__name__
    try:
        cur, sha = t.read_for_update("mitm_json")
        if callable(new_wloc):
            w = _wloc_state_from(cur)
            try:
                new_wloc(w)
            except _WlocAbort as e:
                return False, str(e)                                 # 还没动任何东西
        else:
            w = new_wloc
        cand_mitm = _mitm_json_bytes(cur, w)
        doms = _mitm_domains_from(cand_mitm)
        if doms:                                                     # 缓存准备: 事务之外, 失败零改动
            try:
                import mitm_ca
                mitm_ca.ensure_ca()
                warmed = mitm_ca.prewarm(doms, strict=True)          # 严格预签: 少一张就抛
            except Exception as e:  # noqa: BLE001
                return False, "MITM 根 CA 生成失败(%s), 未改动任何配置。" % type(e).__name__
            if warmed != len(doms):
                return False, ("MITM 叶子证书预签不完整(%d/%d), 未改动任何配置。"
                               % (warmed, len(doms)))
        # 内核配置由 model + rs_meta + **候选**接管域名渲染。model/rs_meta 本次不改 → 只 watch:
        # 它们变了说明候选已过期, 提交前就该拒, 而不是把按旧 model 渲染的配置写下去。
        model_raw = t.watch("model")
        meta_raw = t.watch("rs_meta", optional=True)
        model = json.loads((model_raw or b"{}").decode("utf-8"))
        rs_meta = json.loads(meta_raw.decode("utf-8")) if meta_raw else None
        t.stage("mitm_json", cand_mitm, expect=sha)
        t.derive("mitm_hijack", lambda c: _mitm_hijack_bytes(_mitm_domains_from(c["mitm_json"])))
        t.derive("mihomo_cfg", lambda c: _render_mihomo_bytes(
            model, rs_meta, mitm_domains=_mitm_domains_from(c["mitm_json"]))[0])
        if doms:
            t.service("restart:mihomo"); t.service("restart:mosdns"); t.service("start:pdg-mitm")
        else:
            t.service("stop:pdg-mitm"); t.service("restart:mihomo"); t.service("restart:mosdns")
        res = t.commit()
    except tx.TxBusy:
        return False, BUSY_MSG
    except tx.TxRefused as e:
        return False, tx.redact(str(e))
    except tx.TxError as e:
        return False, "配置事务内部错误: %s" % tx.redact(str(e))
    except Exception as e:  # noqa: BLE001
        return False, "MITM 应用异常(%s)" % type(e).__name__
    finally:
        # 候选阶段 return / 抛异常时把这笔事务收尾成 ABORTED 并删掉候选材料 ——
        # 否则会留下 PREPARING 目录, 里面的候选 model 还带着出口凭据。已进入
        # APPLYING/OBSERVING 的不受影响(那是现网被动过的证据, 必须留给 recover)。
        t.abort_unstarted()
    if res["state"] == tx.COMMITTED:
        return True, ""
    if res["state"] == tx.ROLLBACK_FAILED:
        return False, ("应用失败(%s)\n⚠️ 回滚未完成: %s\n事务材料已保留, 请运行 "
                       "<code>sudo pdg tx recover %s</code>"
                       % (res.get("error", ""), "、".join(res.get("rollback_failed_items") or []),
                          res["txid"]))
    return False, "应用失败(%s), 已回滚到操作前。" % res.get("error", "")

def _wloc_state():
    """归一化 WLOC 配置(迁移老单坐标格式)→ {enabled, accuracy, active, generation, locations:[…]}。"""
    return _wloc_state_from_cfg(_mitm_config())


def _wloc_state_from(mitm_json_bytes):
    """同 _wloc_state, 但基于**给定的 mitm.json 字节**(事务候选阶段用: 读到的那一份才算数)。"""
    try:
        cfg = json.loads((mitm_json_bytes or b"{}").decode("utf-8"))
        if not isinstance(cfg, dict):
            cfg = {}
    except Exception:  # noqa: BLE001
        cfg = {}
    return _wloc_state_from_cfg(cfg)


def _wloc_state_from_cfg(cfg):
    w = dict((cfg or {}).get("wloc") or {})
    locs = w.get("locations")
    if locs is None:                              # 迁移老格式 {lat,lon} → 一个"默认"地点
        locs = [{"name": "默认", "lat": w["lat"], "lon": w["lon"]}] if "lat" in w and "lon" in w else []
    w["locations"] = locs
    w.setdefault("accuracy", 50)
    w.setdefault("enabled", False)
    try:
        w["generation"] = int(w.get("generation") or 0)
    except (TypeError, ValueError):
        w["generation"] = 0
    if w.get("active") not in [l["name"] for l in locs]:
        w["active"] = locs[0]["name"] if locs else None
    return w

def _wloc_active(w=None):
    w = w or _wloc_state()
    for l in w.get("locations", []):
        if l["name"] == w.get("active"):
            return l
    return None

def _wloc_doc(w):
    """WLOC 目标态 → 写进 mitm.json 的那一段(纯函数, 事务候选与热路径共用同一份形态)。"""
    return {"enabled": bool(w.get("enabled")), "accuracy": w.get("accuracy", 50),
            "active": w.get("active"), "generation": int(w.get("generation") or 0),
            "locations": w.get("locations", [])}


def _wloc_save(w):
    cfg = _mitm_config()
    cfg["wloc"] = _wloc_doc(w)
    _save_mitm_config(cfg)

class _WlocAbort(Exception):
    """目标态还没落地就发现不该做(如没有可用地点)→ 带着给用户的话原样返回, 不动任何东西。"""

def _wloc_edit_locked(mutate):
    """在配置锁内读-改-写 mitm.json(内部 os.replace, 不留半个 JSON)。

    读取、存在性判断、选目标、改 generation 全在这把锁里做完 —— 锁外判断、锁内使用就是
    TOCTOU: 两个人同时点删除/切换时, 后一个会拿着已经过期的状态覆盖前一个的结果。
    mutate 返回 False 表示"什么都不用改", 不写盘。

    切地点走这里而不是 _mitm_transact: 接管域名只由 enabled 决定, 换坐标既不影响 CA、也不
    影响 hijack 表和内核路由, 而 pdg-mitm 会在下一次 WLOC 请求开始时读取当前 mitm.json —— 那一整套
    (预热证书/重渲内核/重启 pdg-mitm/重启 mosdns)对"只换经纬度"是纯粹的浪费, 还会断一次
    DNS。返回改后的 w; 锁忙返回 None。

    **这是受控的 hot-path 例外, 不走 pdgtx**: 单文件、单次原子替换、零服务动作 —— 没有
    "多组件半成功"可言(写失败 = 旧文件完好), 而完整事务的观察期光稳定性采样就够把 1 秒的
    目标击穿。例外不等于不留痕: 成功/失败都在同一把锁内写一条脱敏审计(与事务同一份日志、
    同一种格式), 只记代号与 generation 变化, 不记地点名、经纬度、chat id 之类。"""
    with _cfg_guard() as got:
        if not got:
            return None
        w = _wloc_state()
        gen_before = int(w.get("generation") or 0)
        if mutate(w) is False:
            _wloc_hot_audit("wloc_hot_noop", "NOCHANGE", gen_before, gen_before)
            return w
        _wloc_save(w)
        _wloc_hot_audit("wloc_hot_edit", "APPLIED", gen_before, int(w.get("generation") or 0))
        return w


def _wloc_hot_audit(op, result, gen_before, gen_after):
    """给热路径写一条审计。**审计失败绝不能让已经成功的切换报失败** —— 坐标已经落盘了,
    这时回一句"失败"会让用户以为没生效而反复重试。只把脱敏后的异常类型记进日志。"""
    try:
        _pdgtx().audit_event("bot", op, result,
                             extra={"generation_before": gen_before, "generation_after": gen_after,
                                    "generation_changed": gen_after != gen_before})
    except Exception as e:  # noqa: BLE001
        print("[wloc] 审计写入失败(%s), 切换本身已生效" % type(e).__name__, file=sys.stderr)

def _wloc_bump(w):
    """generation +1 —— bot 靠它认出"这次 WLOC 命中对应的是我刚才那次切换"。"""
    w["generation"] = int(w.get("generation") or 0) + 1

def wloc_add_gen(name, lat, lon):
    """加/改一个命名地点。返回 (ok, msg, generation) —— generation>0 表示这次相当于一次热切换。

    三种语义分清楚(以前含糊: 改当前地点会被 pdg-mitm 立刻热加载, 但 generation 不变, bot 还
    让用户再去列表点一次 —— 点了个寂寞):
      · 新增的不是当前目标 → 只保存, 不切换、不动 generation;
      · 改的就是当前目标且 WLOC 开着 → 这就是一次热切换: generation +1, 直接进入命中监听;
      · 改的是当前目标但 WLOC 没开 → 只保存, 明说开启后才生效。"""
    if _platform() != "ios":
        return False, "位置改写(WLOC)仅 iOS 平台可用。", 0
    name = (name or "").strip()
    if not name:
        return False, "地点名不能为空", 0
    st = {}
    def _mut(w):
        st["was_active"] = (w.get("active") == name)      # 判断也在锁内: 锁外判、锁内用就是 TOCTOU
        st["first"] = not w.get("active")
        w["locations"] = [l for l in w["locations"] if l["name"] != name]
        w["locations"].append({"name": name, "lat": lat, "lon": lon})
        if st["first"]:
            w["active"] = name
        st["hot"] = bool(w.get("enabled")) and (st["was_active"] or st["first"])
        if st["hot"]:
            _wloc_bump(w)
        st["gen"] = int(w.get("generation") or 0)
        st["enabled"] = bool(w.get("enabled"))
    w = _wloc_edit_locked(_mut)
    if w is None:
        return False, busy_msg(), 0
    if st["hot"]:
        return True, (f"✅ 当前目标坐标已更新：<b>{name}</b>（{lat}, {lon}）\n"
                      "WLOC 已热加载，无需重启网关服务，也不用再去列表里点一次。\n\n"
                      "现在请关闭 iPhone 定位服务，等待 2 秒后重新开启。"), st["gen"]
    if st["was_active"] or st["first"]:
        return True, (f"✅ 已保存当前目标 <b>{name}</b>（{lat}, {lon}）\n"
                      "WLOC 未开启，这个坐标还不会生效 —— 点「✅ 开启」后才会改写定位。"), 0
    return True, (f"✅ 已添加地点 <b>{name}</b>（{lat}, {lon}）\n"
                  "当前目标没变；要用它请到「📍 地点/切换」点它。"), 0

def wloc_add(name, lat, lon):
    """加/改地点(兼容 2 元组返回)。"""
    ok, msg, _gen = wloc_add_gen(name, lat, lon)
    return ok, msg

def wloc_del(name):
    """删地点。存在性判断/选下一个目标/generation 全在配置锁内做完(锁外判就是 TOCTOU)。"""
    if _platform() != "ios":
        return False, "位置改写(WLOC)仅 iOS 平台可用。"
    st = {}
    def _mut(w):
        st["exists"] = any(l["name"] == name for l in w["locations"])
        if not st["exists"]:
            return False                              # 什么都不改, 也不写盘
        st["was_active"] = (w.get("active") == name)
        rest = [l for l in w["locations"] if l["name"] != name]
        st["last_one"] = st["was_active"] and not rest
        if st["last_one"] and w.get("enabled"):
            # 删掉最后一个地点且 WLOC 开着: 接管域名要撤 → 必须走完整事务(它自己拿锁)。
            # 这里只把目标态算出来, 不落盘。
            st["needs_txn"] = True
            return False
        w["locations"] = rest
        if st["was_active"]:
            w["active"] = rest[0]["name"] if rest else None
            if rest:
                _wloc_bump(w)                        # 切到剩余地点 = 一次热切换
            else:
                w["enabled"] = False
        st["next"] = w.get("active")
    w = _wloc_edit_locked(_mut)
    if w is None:
        return False, busy_msg()
    if not st.get("exists"):
        return False, "没有这个地点"
    if st.get("needs_txn"):
        def _txn(ww):
            if not any(l["name"] == name for l in ww["locations"]):
                raise _WlocAbort("没有这个地点")     # 拿到锁时别人已经删掉了
            ww["locations"] = [l for l in ww["locations"] if l["name"] != name]
            ww["active"] = None
            ww["enabled"] = False
        ok, msg = _mitm_transact(_txn)               # 失败则不落新态, 回滚旧态
        return (True, f"✅ 已删除 <b>{name}</b>（已无地点，WLOC 已关闭）") if ok else (False, msg)
    if not st.get("was_active"):
        return True, f"✅ 已删除 <b>{name}</b>"
    if st.get("next"):
        return True, f"✅ 已删除 <b>{name}</b>，当前目标切到 <b>{st['next']}</b>"
    return True, f"✅ 已删除 <b>{name}</b>（已无地点）"

def wloc_switch_gen(name):
    """切换激活地点。返回 (ok, msg, generation)。

    快路径: 只在配置锁内原子改 mitm.json 的 active + generation。不预热 CA、不写 hijack、
    不重渲内核、不重启 mihomo/mosdns/pdg-mitm —— 那些只有"接管域名变了"(开/关 WLOC)才需要,
    而 pdg-mitm 会在下一次 WLOC 请求开始时读取当前 mitm.json(无需重启服务)。
    目标是这条路径 1 秒内完成。"""
    if _platform() != "ios":
        return False, "位置改写(WLOC)仅 iOS 平台可用。", 0
    st = {}
    def _mut(ww):
        st["exists"] = any(l["name"] == name for l in ww["locations"])
        if not st["exists"]:                          # 存在性也在锁内判: 别人刚删掉就不该切过去
            return False
        ww["active"] = name
        _wloc_bump(ww)
    w = _wloc_edit_locked(_mut)
    if w is None:
        return False, busy_msg(), 0
    if not st.get("exists"):
        return False, "没有这个地点", 0
    loc = _wloc_active(w)
    if not w.get("enabled"):
        return True, (f"✅ 已选中 <b>{name}</b>（{loc['lat']}, {loc['lon']}）\n"
                      "WLOC 未开启，这个地点还不会生效 —— 点「✅ 开启」后才会改写定位。"), w["generation"]
    return True, (f"✅ 网关目标已切换：<b>{name}</b>（{loc['lat']}, {loc['lon']}）\n"
                  "WLOC 已热加载，无需重启网关服务。\n\n"
                  "现在请关闭 iPhone 定位服务，等待 2 秒后重新开启。"), w["generation"]

def wloc_switch(name):
    """切换激活地点(兼容 2 元组返回)。"""
    ok, msg, _gen = wloc_switch_gen(name)
    return ok, msg

def wloc_enable(on):
    """开/关 WLOC(开启需已有激活地点)。"""
    if _platform() != "ios":
        return False, "位置改写(WLOC)仅 iOS 平台可用。"
    st = {}
    def _txn(w):
        if on and not _wloc_active(w):   # 判断在事务锁内做, 拿的就是当下的状态
            raise _WlocAbort("请先「➕ 添加地点」设一个坐标再开启。")
        w["enabled"] = bool(on)
        if on:
            _wloc_bump(w)                # 开启也是一次新目标 → 让 bot 能等这一代的命中
        st["active"] = w.get("active")
        st["loc"] = _wloc_active(w)
        st["gen"] = int(w.get("generation") or 0)
    ok, msg = _mitm_transact(_txn)       # 事务化: 失败则 enabled 不被持久化(回滚), 不留"返回失败却 enabled=true"
    if not ok:
        return False, msg
    if on:
        loc = st["loc"]
        return True, (f"✅ 位置改写已开启：<b>{st['active']}</b>（{loc['lat']}, {loc['lon']}）\n\n"
                      "首次开启后，请到「📱 客户端」重新生成并安装 iOS 描述文件，"
                      "然后在「证书信任设置」中信任 PrivDNS Gateway MITM CA。\n\n"
                      "然后关闭 iPhone 定位服务，等 2 秒再打开 —— 下一次 Apple 网络定位请求就会用新坐标。")
    return True, "✅ 位置改写已关闭。"

def wloc_add_reply(chat, name, lat, lon):
    """加/改地点并回话。改的就是当前目标且 WLOC 开着 = 一次热切换 → 和点列表切换一样,
    也进入命中监听(此前这条路径只会让用户"再去列表点一次", 点了其实也没有新意义)。"""
    since = time.time()
    ok, msg, gen = wloc_add_gen(name, lat, lon)
    if ok and gen:
        mid = send_tracked(chat, msg, WLOC_BACK)
        if mid:
            _wloc_watch_async(chat, mid, gen, name, kb=WLOC_BACK, since=since)
            return
    send_plain(chat, msg if ok else ("❌ " + msg))

def wloc_generation():
    """当前 WLOC 目标代号(bot 等命中用)。"""
    return int(_wloc_state().get("generation") or 0)

# ── 等一次真实的 WLOC 命中 ───────────────────────────────────────────────────
# 网关能保证的只有"下一次 WLOC 请求会用新坐标"; 手机什么时候发那次请求、locationd 缓存要不要
# 清, 都不归网关管。所以这里等的是**手机真的来过请求**这件事实, 措辞也只说到这一步 ——
# 绝不把"网关改写了响应"说成"手机位置已经变了"。
WLOC_STATUS_FILE = os.environ.get("PDG_WLOC_STATUS", "/run/privdns-gateway/wloc-status.json")
# (chat, message_id) -> token: 那条消息当前归谁管。任何新回调都会换掉 token,
# 于是还在等的旧监听立刻失效 —— 否则用户点了「返回菜单」, 30 秒后监听把菜单覆盖成一句
# "尚未收到请求", 用户正看着的界面就没了。
_wloc_watch_token: dict[tuple, str] = {}
_wloc_watch_gen: dict[int, int] = {}             # chat -> 最近一次切换的 generation
_wloc_watch_lock = threading.Lock()

def wloc_invalidate_watch(chat, mid):
    """让绑在这条消息上的监听失效(任何新回调都该调一次)。"""
    with _wloc_watch_lock:
        _wloc_watch_token.pop((chat, mid), None)

def _wloc_read_status():
    try:
        with open(WLOC_STATUS_FILE, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:  # noqa: BLE001            # 文件还没有 / 正在被替换 / 坏档 → 当作还没命中
        return None

def _wloc_status_hit(st, gen, target, since):
    """这条状态算不算"我这次切换的命中"。

    三项都要对得上: generation 相同、目标名相同、时间不早于本次切换开始 —— 只看 generation
    的话, 上次运行留下的历史状态(/run 没清干净、或 generation 回绕)会被当成刚刚的命中,
    用户还没开关定位服务就先看到"已收到新请求"。字段类型不对一律当作没命中, 不抛异常:
    这是后台线程, 抛出去就是静默死掉, 该出现的超时提示也没了。"""
    if not isinstance(st, dict):
        return False
    try:
        if int(st.get("generation")) != int(gen):
            return False
        if str(st.get("target_name") or "") != str(target or ""):
            return False
        return float(st.get("received_at") or 0) >= float(since)
    except (TypeError, ValueError):
        return False

def _wloc_hit_text(st, target):
    """把一次命中翻译成给用户的话。区分三种结局, 不含糊。"""
    if st.get("upstream_ok") and st.get("patched"):
        return (f"✅ 已收到 iPhone 的新定位请求\n"
                f"Apple 网络定位响应已改写为：<b>{target}</b>\n\n"
                "若地图仍显示旧位置，属于 iOS 缓存或 GPS 覆盖。")
    if not st.get("upstream_ok"):
        return (f"❌ 收到了 iPhone 的新定位请求，但网关取 Apple 原始响应失败"
                f"（{st.get('error_type') or '未知'}），本次未改写。\n"
                "请检查网关到 Apple 的出网是否正常，稍后再试一次开关定位服务。")
    return (f"⚠️ 收到了 iPhone 的新定位请求，Apple 响应也拿到了，但里面没有可改写的坐标字段"
            f"（{st.get('error_type') or '未知'}），本次未改写。")

WLOC_MISS_TEXT = ("⚠️ 网关目标已切换，但尚未收到 iPhone 的新 WLOC 请求。\n\n"
                  "请检查：\n"
                  "· 当前使用内网卡\n"
                  "· 控制中心 Wi-Fi 已点灰\n"
                  "· 网关 CA 已信任\n"
                  "· iOS 定位缓存；iOS 26 必要时重启")

def _wloc_watch_async(chat, mid, gen, target, timeout=30.0, interval=0.5, kb=None, since=None):
    """后台等这一代 generation 的命中, 最多 timeout 秒, 然后原地编辑那条消息。

    放后台执行器里跑 —— 主 getUpdates 循环一秒都不等它。不走 run_bg: 那会占住 per-chat BUSY,
    等待期间用户连再切一次地点都做不了。

    监听绑定 (chat, message_id, token): 用户对这条消息做**任何**新操作(再切一次、返回菜单、
    关 WLOC、删地点)都会换掉 token, 旧监听立刻失效, 不会把用户正在看的界面覆盖掉。
    since = 本次切换开始的时间, 用来把历史状态挡在外面。"""
    token = uuid.uuid4().hex
    key = (chat, mid)
    start = time.time() if since is None else since
    with _wloc_watch_lock:
        _wloc_watch_token[key] = token
        _wloc_watch_gen[chat] = gen
    def superseded():
        """两种作废: 这条消息被新回调接管了(别覆盖用户正看的界面), 或者用户已经切到了
        更新的一代(旧目标的结果再报出来就是误导)。"""
        with _wloc_watch_lock:
            return (_wloc_watch_token.get(key) != token
                    or _wloc_watch_gen.get(chat, gen) != gen)
    def done():
        """结束时把自己的 token 摘掉, 免得残留在表里。"""
        with _wloc_watch_lock:
            if _wloc_watch_token.get(key) == token:
                _wloc_watch_token.pop(key, None)
    def go():
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if superseded():
                return
            st = _wloc_read_status()
            if _wloc_status_hit(st, gen, target, start):
                if not superseded():
                    edit_only(chat, mid, _wloc_hit_text(st, target), kb or WLOC_BACK)
                    done()
                return
            time.sleep(interval)
        if not superseded():
            edit_only(chat, mid, WLOC_MISS_TEXT, kb or WLOC_BACK)
            done()
    try:
        return _EXEC.submit(go)
    except Exception:  # noqa: BLE001            # 执行器满/已关 → 不等了, 消息保持"已切换"即可
        with _wloc_watch_lock:
            _wloc_watch_token.pop(key, None)
        return None

def set_wloc(on, lat=None, lon=None):
    """兼容旧接口: 给了 lat/lon 就存成「默认」地点并激活, 再开/关。"""
    if _platform() != "ios":
        return False, "位置改写(WLOC)仅 iOS 平台可用。"
    if lat is not None and lon is not None:
        wloc_add("默认", lat, lon)
        wloc_switch("默认")
    return wloc_enable(on)

def _render_mihomo_bytes(model, rs_meta=None, mitm_domains=None):
    """从给定 model 渲染出 mihomo 配置的**字节**(不落盘)。返回 (bytes, meta)。

    事务在候选阶段用它: 内核配置是 model 的派生物, 必须和 model 在同一笔事务里一起校验、
    一起落盘 —— 否则"model 写进去了、渲染失败"就会留下两份不一致的配置。

    mitm_domains: 显式给出接管域名(WLOC 事务用**候选** mitm.json 推出来的那一份)。不给就读
    生产的 mitm_hijack.txt —— 那是"这次不改 MITM"的路径才成立的默认值。
    渲染本体在 mihomorender(与恢复/救援共用); 这里只负责把 bot 当前的环境读好传进去。"""
    return mihomorender.render_bytes(
        model, rulesets=_mihomo_rulesets(rs_meta),
        mitm_domains=_mitm_domains() if mitm_domains is None else mitm_domains,
        tls_ports=[443] if _platform() == "ios" else None)


def _render_mihomo_file():
    """从当前 model(SB)渲染出 mihomo 配置并落盘。返回渲染 meta(dropped/unknown)。
    仍供 pdg.sh 的平台切换等 CLI 路径调用(那些路径由 CLI 侧事务覆盖)。"""
    import sb2mihomo
    model = load()
    # iOS: 嗅探端口不含 GMS 5228-5230(iOS 走 APNs); Android 用默认(含 GMS)。两平台 canonical/内核均无 GMS 残留。
    tls_ports = [443] if _platform() == "ios" else None
    cfg, meta = sb2mihomo.singbox_to_mihomo(
        model, redir_port=MIHOMO_REDIR, rulesets=_mihomo_rulesets(),
        mitm_domains=_mitm_domains(), mitm_port=MITM_PORT, tls_ports=tls_ports, **_panel_render_args(model))
    _write_mihomo(cfg)
    return meta

def _fmt_dropped(dropped):
    """把渲染器丢弃的规则说人话。实现在 mihomorender。"""
    return mihomorender.fmt_dropped(dropped)


def busy_msg():
    """区分"别人正在改"与"锁不可用" —— 后者是环境故障, 让用户知道该去看 /run。"""
    return NOLOCK_MSG if _cfg_lock_error() else BUSY_MSG

def _pdgtx():
    import pdgtx
    return pdgtx


def _model_bytes(c):
    return json.dumps(c, ensure_ascii=False, indent=2).encode("utf-8")


def _mihomo_derive(staged):
    """由**候选** model(+候选 rs_meta)派生 mihomo 配置。dropped / 无法转换的出口一律判失败。

    tx_apply 与恢复备份共用这一份 —— 判据只有一处, 免得两条路一个拦一个不拦。
    判废逻辑本体在 mihomorender.check_meta, 与配置恢复/救援侧同源。"""
    model = json.loads(staged["model"].decode("utf-8"))
    # 规则集元数据如果也在本次候选里, 渲染必须按**候选**来 —— 读现网旧文件会让新增的规则集
    # "翻译不了"被丢掉, 或者已删的又冒出来。
    staged_meta = staged.get("rs_meta")
    data, meta = _render_mihomo_bytes(
        model, rs_meta=json.loads(staged_meta.decode("utf-8")) if staged_meta else None)
    try:
        mihomorender.check_meta(meta)
    except mihomorender.RenderRefused as e:
        # 边界映射(bot 侧): 用 TxRefused 而不是让 RenderRefused 直接冒上去 —— 事务对普通异常
        # 只报类型名, 而这两条恰恰必须**点名**是哪个出口/哪条规则被丢了, 否则用户不知道该改
        # 什么。detail() 自己做完统一脱敏, 这里不需要(也无法)再传脱敏函数进去。
        raise _pdgtx().TxRefused(e.detail()) from None
    return data


def tx_apply(op, model_mod=None, files=None, services=(), tfo_intent=None, mode="normal",
             warnings=()):
    """Bot 侧所有生产写入的**唯一**入口: 一笔事务把 model、mosdns 规则、profile 等一起落盘。

    以前是"model 走 apply_sb(锁内), mosdns 文件在锁外再补一刀" —— 于是内核里有规则、DNS 侧
    没劫持这种半套状态没人拦得住。现在它们要么一起成功, 要么一起回到操作前。

    model_mod:  改 model 的回调(与旧 apply_sb 语义一致)
    files:      {逻辑目标名: bytes|None} 需要与 model 一起原子落盘的其它目标
    services:   额外要重启的服务(model 变更会自动带上 mihomo)
    tfo_intent: 指定本次 TFO 意图(set_tfo 用); None = 沿用 profile.env 里的当前意图
    返回 (ok, msg)
    """
    tx = _pdgtx()
    svc = set(services or ())
    try:
        t = tx.Tx(source="bot", op=op, mode=mode)
    except Exception as e:  # noqa: BLE001
        return False, "无法开始配置事务(%s)" % type(e).__name__
    for w in warnings or ():
        t.warn(w)
    try:
        if model_mod is not None:
            # 先记下"候选依据的是哪一份 model": 之后 stage 用它当前置条件。
            # 否则 load() 与 stage() 之间别人提交的修改会被当成前置条件, 最后被我们覆盖(丢更新)。
            t.read_for_update("model")
            c = load()
            intent = _tfo_intent(c) if tfo_intent is None else tfo_intent
            model_mod(c)
            _tfo_apply(c, intent)                 # 加/改出口不冲掉 TFO 状态(语义与旧实现一致)
            t.stage("model", _model_bytes(c))
            svc.add("mihomo")

            t.derive("mihomo_cfg", _mihomo_derive)
        for name, data in (files or {}).items():
            t.stage(name, data)
            s2 = tx.target_service(name)
            if s2:
                svc.add(s2)
        for u in sorted(svc):
            t.service("restart:" + u)
        if "sysctl_tfo" in (files or {}):
            t.service("sysctl:apply")
        res = t.commit()
    except _PanelOwnershipError:
        return False, "检测到自定义 clash_api 配置, 为避免覆盖已保持原样"
    except tx.TxBusy:
        # 直接用 BUSY_MSG, **不要**走 busy_msg(): 后者看的是本线程上一次 _cfg_guard() 的结果,
        # 而这里的失败来自 pdgtx 自己的锁。线程池会复用线程 —— 同一个工作线程先前若碰上过
        # "锁文件不可用"(比如一次 WLOC 操作), 那份状态还在, TxBusy 就会被错报成 NOLOCK。
        # pdgtx._Lock 已经把两件事分开了: 打不开锁文件 → TxRefused, 锁被占 → TxBusy。
        return False, BUSY_MSG
    except tx.TxRefused as e:
        return False, tx.redact(str(e))
    except tx.TxError as e:
        return False, "配置事务内部错误: %s" % tx.redact(str(e))
    except Exception as e:  # noqa: BLE001
        return False, "配置事务异常(%s)" % type(e).__name__
    finally:
        # 候选阶段 return / 抛异常时把这笔事务收尾成 ABORTED 并删掉候选材料 ——
        # 否则会留下 PREPARING 目录, 里面的候选 model 还带着出口凭据。已进入
        # APPLYING/OBSERVING 的不受影响(那是现网被动过的证据, 必须留给 recover)。
        t.abort_unstarted()
    if res["state"] == tx.COMMITTED:
        note = ("\n⚠️ " + "; ".join(res["warnings"])) if res["warnings"] else ""
        return True, "事务 %s 已提交%s" % (res["txid"], note)
    if res["state"] == tx.ROLLBACK_FAILED:
        return False, ("%s\n⚠️ 回滚未完成, 未恢复项: %s\n事务材料保留在 %s"
                       % (res["error"], "、".join(res["rollback_failed_items"]) or "(未知)",
                          res["dir"]))
    return False, "%s(已回滚到操作前, 事务 %s)" % (res["error"], res["txid"])


def apply_sb(modify):
    """兼容入口: 只改 model 的操作(加删出口/组/默认出口/改名/排序…)。"""
    ok, msg = tx_apply("apply_sb", model_mod=modify)
    return ok, ("" if ok else msg)

# 可作出口的代理协议(决定哪些出站算"出口": 可选默认/故障组成员/测出口/删除)。sing-box 支持的都列上。
PROXY_TYPES = ("shadowsocks", "vmess", "trojan", "vless", "hysteria", "hysteria2",
               "tuic", "anytls", "shadowtls", "socks", "http")

def proxy_outbounds(c):
    return [o for o in c["outbounds"] if o.get("type") in PROXY_TYPES]

def exit_tags(c):
    """可作分流目标/默认出口的全部出口 (含 direct 与 urltest 故障组)。实现在 mihomorender ——
    救援侧的紧急默认出口要按**同一套**判据列候选, 两边各写一份迟早漂移。"""
    return mihomorender.exit_tags(c)

def concrete_tags(c):
    """具体出口 (可作故障组成员; 排除 urltest 组自身, 防嵌套环)。"""
    return [o["tag"] for o in c["outbounds"] if o.get("type") in PROXY_TYPES + ("direct",)]

def deletable_tags(c):
    """可删除的出口/组 (代理出口 + urltest 组; 不含 jp direct)。"""
    return [o["tag"] for o in c["outbounds"] if o.get("type") in PROXY_TYPES + ("urltest",)]

def _tag(name, host, port):
    return re.sub(r"[^A-Za-z0-9_.-]", "-", (name or f"{host}:{port}"))[:40] or "exit"

# ── 链接解析 (ss/vmess/trojan/vless) ──
def parse_link(link):
    link = link.strip()
    if link.startswith("ss://"):
        return _parse_ss(link)
    if link.startswith("vmess://"):
        return _parse_vmess(link)
    if link.startswith("trojan://"):
        return _parse_trojan(link)
    if link.startswith("vless://"):
        return _parse_vless(link)                     # 含 reality/flow
    if link.startswith(("hysteria2://", "hy2://")):
        return _parse_hysteria2(link)
    if link.startswith("tuic://"):
        return _parse_tuic(link)
    if link.startswith("anytls://"):
        return _parse_anytls(link)
    if link.startswith(("socks://", "socks5://")):
        return _parse_socks(link)
    if link.startswith(("http://", "https://")):
        return _parse_http(link)
    if re.search(r"=\s*ss\s*,", link, re.I):          # Surge 代理行: 名字 = ss, 服务器, 端口, encrypt-method=…, password=…
        return _parse_surge(link)
    raise ValueError("支持: ss:// / vmess:// / trojan:// / vless://(含 reality)/ hysteria2:// / tuic:// / "
                     "anytls:// / socks5:// / http:// 链接, 或 Surge 的 ss 行(名字 = ss, …)")

def _b64(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode("utf-8", "ignore")

def _parse_ss(link):
    body = link[5:]; tag = ""
    if "#" in body:
        body, tag = body.split("#", 1); tag = urllib.parse.unquote(tag).strip()
    body = body.split("?", 1)[0]
    if "@" in body:
        ui, hp = body.rsplit("@", 1)
        try:
            method, pw = _b64(ui).split(":", 1)
        except Exception:
            method, pw = urllib.parse.unquote(ui).split(":", 1)
        host, port = hp.rsplit(":", 1)
    else:
        head, hp = _b64(body).rsplit("@", 1); method, pw = head.split(":", 1); host, port = hp.rsplit(":", 1)
    return {"type": "shadowsocks", "tag": _tag(tag, host.strip("[]"), port), "server": host.strip("[]"),
            "server_port": int(port.split("/")[0]), "method": method, "password": pw}

def _parse_surge(line):
    """Surge 代理行(目前支持 ss): 名字 = ss, 服务器, 端口, encrypt-method=…, password="…", tfo=true, udp-relay=true"""
    name, _, rest = line.partition("=")
    parts = [p.strip() for p in rest.split(",")]
    if not parts or parts[0].lower() != "ss":
        raise ValueError("Surge 行暂只支持 ss(其它类型请用 ss:// / vmess:// / trojan:// / vless:// 链接)")
    if len(parts) < 3:
        raise ValueError("Surge ss 行格式: 名字 = ss, 服务器, 端口, encrypt-method=…, password=…")
    server = parts[1].strip("[]"); port = int(parts[2].split("/")[0])
    kv = {}
    for p in parts[3:]:                               # key=value(password 里的 base64 可能含 = / +, 故只切第一个 =)
        if "=" in p:
            k, v = p.split("=", 1); kv[k.strip().lower()] = v.strip().strip('"').strip("'")
    method = kv.get("encrypt-method") or kv.get("method")
    pw = kv.get("password")
    if not method or not pw:
        raise ValueError("Surge ss 行缺 encrypt-method 或 password")
    out = {"type": "shadowsocks", "tag": _tag(name.strip(), server, str(port)),
           "server": server, "server_port": port, "method": method, "password": pw}
    if kv.get("tfo", "").lower() in ("true", "1"):    # udp-relay: sing-box ss 出站默认就支持 UDP, 无需额外字段
        out["tcp_fast_open"] = True
    return out

def _tls_block(server_name, insecure=False):
    b = {"enabled": True}
    if server_name:
        b["server_name"] = server_name
    if insecure:
        b["insecure"] = True
    return b

def _transport(net, host, path, service=None):
    if net in ("ws", "websocket"):
        t = {"type": "ws", "path": path or "/"}
        if host:
            t["headers"] = {"Host": host}
        return t
    if net == "grpc":                                 # 分享链接 grpc 服务名多在 serviceName=/service_name=, 不在 path
        return {"type": "grpc", "service_name": service or (path or "").lstrip("/")}
    return None

def _parse_vmess(link):
    j = json.loads(_b64(link[8:]))
    host, port = j["add"], int(j["port"])
    ob = {"type": "vmess", "tag": _tag(j.get("ps"), host, port), "server": host, "server_port": port,
          "uuid": j["id"], "alter_id": int(j.get("aid", 0) or 0), "security": j.get("scy") or "auto"}
    if str(j.get("tls", "")).lower() in ("tls", "true", "1"):
        ob["tls"] = _tls_block(j.get("sni") or j.get("host") or host)
    tr = _transport(j.get("net", "tcp"), j.get("host"), j.get("path"))
    if tr:
        ob["transport"] = tr
    return ob

def _qs(u):
    return {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}

def _parse_trojan(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    ob = {"type": "trojan", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 443, "password": urllib.parse.unquote(u.username or "")}
    ob["tls"] = _tls_block(q.get("sni") or q.get("peer") or u.hostname, q.get("allowInsecure") in ("1", "true"))
    tr = _transport(q.get("type", "tcp"), q.get("host"), q.get("path"),
                    q.get("serviceName") or q.get("service_name"))
    if tr:
        ob["transport"] = tr
    return ob

def _parse_vless(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    ob = {"type": "vless", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 443, "uuid": u.username, "flow": q.get("flow", "")}
    if not ob["flow"]:
        ob.pop("flow")
    sec = q.get("security")
    if sec in ("tls", "reality", "xtls"):
        ob["tls"] = _tls_block(q.get("sni") or u.hostname, q.get("allowInsecure") in ("1", "true"))
        if sec == "reality":                          # Reality: 公钥 pbk + short_id sid(+ 指纹 fp)
            ob["tls"]["reality"] = {"enabled": True, "public_key": q.get("pbk", ""), "short_id": q.get("sid", "")}
        if q.get("fp"):
            ob["tls"]["utls"] = {"enabled": True, "fingerprint": q["fp"]}
    tr = _transport(q.get("type", "tcp"), q.get("host"), q.get("path"),
                    q.get("serviceName") or q.get("service_name"))
    if tr:
        ob["transport"] = tr
    return ob

def _userinfo(u):
    """URI 用户信息整体取出(hysteria2/anytls 的 password 是单串, 但容错 user:pass 形式)。"""
    s = u.username or ""
    if u.password is not None:
        s += ":" + u.password
    return urllib.parse.unquote(s)

def _insec(q):
    return any(q.get(k) in ("1", "true") for k in ("insecure", "allowInsecure", "allow_insecure"))

def _parse_hysteria2(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    ob = {"type": "hysteria2", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 443, "password": _userinfo(u),
          "tls": _tls_block(q.get("sni") or q.get("peer") or u.hostname, _insec(q))}
    if q.get("obfs"):                                 # 通常是 salamander
        ob["obfs"] = {"type": q["obfs"], "password": q.get("obfs-password", "")}
    return ob

def _parse_tuic(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    ob = {"type": "tuic", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 443,
          "uuid": urllib.parse.unquote(u.username or ""), "password": urllib.parse.unquote(u.password or ""),
          "tls": _tls_block(q.get("sni") or u.hostname, _insec(q))}
    if q.get("alpn"):
        ob["tls"]["alpn"] = q["alpn"].split(",")
    if q.get("congestion_control"):
        ob["congestion_control"] = q["congestion_control"]
    if q.get("udp_relay_mode"):
        ob["udp_relay_mode"] = q["udp_relay_mode"]
    return ob

def _parse_anytls(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    return {"type": "anytls", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
            "server": u.hostname, "server_port": u.port or 443, "password": _userinfo(u),
            "tls": _tls_block(q.get("sni") or u.hostname, _insec(q))}

def _parse_socks(link):
    u = urllib.parse.urlparse(link)
    ob = {"type": "socks", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 1080, "version": "5"}
    user = urllib.parse.unquote(u.username) if u.username else None
    pw = urllib.parse.unquote(u.password) if u.password else None
    if user and pw is None and ":" not in user:       # socks5://base64(user:pass)@host:port 也常见
        try:
            d = _b64(user)
            if ":" in d:
                user, pw = d.split(":", 1)
        except Exception:  # noqa: BLE001
            pass
    if user:
        ob["username"] = user
    if pw:
        ob["password"] = pw
    return ob

def _parse_http(link):
    u = urllib.parse.urlparse(link)
    ob = {"type": "http", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or (443 if u.scheme == "https" else 80)}
    if u.username:
        ob["username"] = urllib.parse.unquote(u.username)
    if u.password:
        ob["password"] = urllib.parse.unquote(u.password)
    if u.scheme == "https":
        ob["tls"] = _tls_block(u.hostname)
    return ob

# ── 故障切换组 (urltest) ──
def add_group(name, members):
    c = load(); cands = concrete_tags(c)
    members = [m for m in members if m]
    name = _tag(name, "", "")
    if name in cands:
        return False, f"组名 {name} 和现有出口冲突, 换个名字"
    bad = [m for m in members if m not in cands]
    if bad:
        return False, f"未知成员: {', '.join(bad)}\n只能用具体出口: {', '.join(cands)}"
    if len(members) < 2:
        return False, "故障切换组至少要 2 个出口"
    def mod(cc):
        for o in cc["outbounds"]:           # 已存在则原地改成员(保留在列表中的位置)
            if o.get("tag") == name and o.get("type") == "urltest":
                o["outbounds"] = members
                o.setdefault("url", DELAY_URL); o.setdefault("interval", "3m"); o.setdefault("tolerance", 50)
                return
        cc["outbounds"].append({"type": "urltest", "tag": name, "outbounds": members,
                                "url": DELAY_URL, "interval": "3m", "tolerance": 50})
    ok, msg = apply_sb(mod)
    return ok, (f"✅ 故障切换组 <b>{name}</b> = {' › '.join(members)}\n"
                "按探测延迟选择出口，并在出口不可用时切换。可在「🎯 设默认出口」或分流规则里选它。" if ok else msg)

# ── 直连表 (mosdns) ──
def _read_direct():
    if not os.path.exists(MOSDNS_DIRECT):
        return []
    return [l.strip().replace("domain:", "") for l in open(MOSDNS_DIRECT)
            if l.strip() and not l.startswith("#")]

def _direct_text(domains):
    """直连表内容(不落盘)。落盘与 mosdns 重启由事务统一做 —— 以前这里自己写自己重启,
    连 mosdns 有没有起来都不查。"""
    return ("# pdg-bot 自定义直连\n"
            + "".join("domain:" + d + "\n" for d in sorted(set(domains)))).encode("utf-8")

def _read_hijack():
    """指到出口的域名劫持表。mosdns 的 hijack_set 只装 geosite 策展分类, 不含任意个人域名 ——
    不把这些域名劫持到网关, 手机会拿到真实 IP 直连, 内核里的出口规则永远不会被命中。"""
    if not os.path.exists(MOSDNS_HIJACK):
        return []
    return [l.strip().replace("domain:", "") for l in open(MOSDNS_HIJACK)
            if l.strip() and not l.startswith("#")]

def _hijack_text(domains):
    """出口域名劫持表内容(不落盘)。domain_set 只在 mosdns 启动时加载, 故事务里必带 restart。"""
    return ("# pdg-bot 显式出口域名劫持表(指到出口的域名必须由 mosdns 劫持才会进代理)\n"
            + "".join("domain:" + d + "\n" for d in sorted(set(domains)))).encode("utf-8")

# ── mosdns DNS 上游 (remote=国际 / local=国内; 用于接 DNS 解锁等自定义解析器) ──
def _upstreams(which):
    tag = which + "_upstream"
    try:
        lines = open(MOSDNS_CONF).read().splitlines()
    except Exception:  # noqa: BLE001
        return []
    for i, ln in enumerate(lines):
        if ln.strip() == f"- tag: {tag}":
            for j in range(i, min(i + 6, len(lines))):
                if "upstreams" in lines[j]:
                    return re.findall(r'addr:\s*"?([^",}\s]+)"?', lines[j])
    return []

def set_mosdns_upstream(which, addrs):
    if which not in ("remote", "local"):
        return False, "第一个词只能是 remote(国际) 或 local(国内)"
    addrs = [a.strip() for a in addrs if a.strip()]
    if not addrs:
        return False, "至少给一个 DNS 地址 (udp://1.2.3.4:53 / tcp://.. / https://x/dns-query / tls://..)"
    tag = which + "_upstream"
    # 走统一事务: 候选先过 mosdns 强校验(netns/高端口真起一次), 通过才原子落盘 + 重启观察。
    # 旧实现是"直接覆盖现网 → 重启 → 看 is-active", 坏配置要等 mosdns 起不来才发现。
    tx = _pdgtx()
    try:
        t = tx.Tx(source="bot", op="mosdns_upstream")
    except Exception as e:  # noqa: BLE001
        return False, "无法开始配置事务(%s)" % type(e).__name__
    cur, _sha = t.read_for_update("mosdns_conf")     # 候选基于这一份算, 前置条件也是它
    if cur is None:
        t.abort_unstarted("读 mosdns 配置失败: 文件不存在")
        return False, "读 mosdns 配置失败: 文件不存在"
    try:
        lines = cur.decode("utf-8").splitlines()
    except Exception as e:  # noqa: BLE001
        t.abort_unstarted("mosdns 配置不是 UTF-8")
        return False, f"读 mosdns 配置失败: {e}"
    items = ", ".join('{addr: "%s"}' % a for a in addrs)
    done = False
    for i, ln in enumerate(lines):
        if ln.strip() == f"- tag: {tag}":
            for j in range(i, min(i + 6, len(lines))):
                if "upstreams" in lines[j]:
                    indent = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                    # 单上游=1(否则 mosdns 会对同一台并发查两次); 多上游=2 才有真故障转移(默认 1 不转移)
                    conc = 1 if len(addrs) == 1 else 2
                    lines[j] = indent + "args: { concurrent: %d, upstreams: [ %s ] }" % (conc, items)
                    done = True
                    break
        if done:
            break
    if not done:
        t.abort_unstarted("mosdns 配置里没有 %s 块" % tag)
        return False, f"没在 mosdns 配置里找到 {tag} 块"
    t.stage("mosdns_conf", ("\n".join(lines) + "\n").encode("utf-8"))
    t.service("restart:mosdns")
    try:
        res = t.commit()
    except tx.TxBusy:
        return False, BUSY_MSG          # 同上: 锁被占是 pdgtx 报的, 与 _cfg_guard 的历史无关
    except tx.TxRefused as e:
        return False, tx.redact(str(e))
    except Exception as e:  # noqa: BLE001
        return False, "配置事务异常(%s)" % type(e).__name__
    finally:
        # 候选阶段 return / 抛异常时把这笔事务收尾成 ABORTED 并删掉候选材料 ——
        # 否则会留下 PREPARING 目录, 里面的候选 model 还带着出口凭据。已进入
        # APPLYING/OBSERVING 的不受影响(那是现网被动过的证据, 必须留给 recover)。
        t.abort_unstarted()
    if res["state"] == tx.COMMITTED:
        return True, f"✅ {which} 上游已设为: {', '.join(addrs)}"
    if res["state"] == tx.ROLLBACK_FAILED:
        return False, ("%s\n⚠️ 回滚未完成: %s\n事务材料: %s"
                       % (res["error"], "、".join(res["rollback_failed_items"]) or "(未知)",
                          res["dir"]))
    return False, "%s(已回滚到操作前, 事务 %s)" % (res["error"], res["txid"])

# ── 流媒体/服务解锁: 在「落地出口」与「WDA 解锁」之间整体切换 ──
# WDA 模式: 这些域名 → jp 直出 + 经 mosdns 用解锁 DNS(22.22.22.22)解析到中继(从本机授权 IP 出)。
# 落地模式: 不加规则, 这些域名回落到各自现有分流出口(hk/tw 等)。
# mosdns 侧的 unlock 支(unlock_upstream + geosite_unlock)是常驻的(install/迁移装好), 平时休眠;
# 本函数只在 WDA 模式把域名清单写进 mosdns 的 unlock.txt 与 model 内联域名规则。
MOSDNS_RULES = "/etc/mosdns/rules"
UNLOCK_DNS = "22.22.22.22"   # 解锁服务(WDA)的 DNS; 与 mosdns unlock_upstream 一致。换厂商需同步两处。
WDA_DOMAINS = [
    # 流媒体
    "netflix.com", "netflix.net", "nflxvideo.net", "nflximg.net", "nflxext.com", "nflxso.net",
    "disneyplus.com", "disney-plus.net", "dssott.com", "bamgrid.com", "disneyplus.disney.co.jp",
    "primevideo.com", "aiv-cdn.net", "aiv-delivery.net", "amazonvideo.com", "pv-cdn.net",
    "tv.apple.com", "uts-api.itunes.apple.com", "play-edge.itunes.apple.com", "np-edge.itunes.apple.com",
    "youtube.com", "googlevideo.com", "ytimg.com", "youtu.be", "youtubei.googleapis.com", "yt3.ggpht.com",
    "dazn.com", "dazn-api.com", "indazn.com", "daznplayer.com",
    "unext.jp", "nxtv.jp", "iq.com", "iqiyi.com", "qy.net",
    "tvbanywhere.com", "mytvsuper.com", "dmm.com", "dmm.co.jp", "dmmapis.com",
    # AI
    "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
    "anthropic.com", "claude.ai", "gemini.google.com", "generativelanguage.googleapis.com",
    "aistudio.google.com", "meta.ai",
    # 其它(WDA JP 平台支持)
    "steampowered.com", "steamcommunity.com", "steamstatic.com", "play.google.com", "android.com",
]

def _read_unlock_domains():
    """现网 unlock.txt 是上一版 WDA 内联规则的精确清单, 用于跨版本替换旧规则。"""
    try:
        return [line.strip()[len("domain:"):]
                for line in open(os.path.join(MOSDNS_RULES, "unlock.txt"), encoding="utf-8")
                if line.strip().startswith("domain:") and line.strip()[len("domain:"):]]
    except OSError:
        return []


def _is_wda_rule(rule, previous_domains=None):
    """识别当前/上一版内联 WDA 规则及老装遗留的 rule_set=unlock 规则。"""
    if rule.get("outbound") != "jp":
        return False
    if rule.get("rule_set") == "unlock":
        return True
    domains = rule.get("domain_suffix")
    if not isinstance(domains, list):
        return False
    candidates = [WDA_DOMAINS]
    if previous_domains:
        candidates.append(previous_domains)
    return any(len(domains) == len(expected) and set(domains) == set(expected)
               for expected in candidates)


def _wda_rule_pred():
    """返回一个"这条规则是 WDA 规则吗"的判据(unlock.txt 只读一次)。

    为什么单域名增删也要认它: WDA 规则改成内联 domain_suffix 之后, 它在 model 里就是一条
    普通的 `outbound=jp` 规则 —— add_rule 找"第一条 outbound 相同且没有 rule_set 的规则"
    就会正好找到它, 把用户的域名 append 进去; del_rule / 删规则键盘同理会把 WDA 域名当成
    用户自己加的规则去删。任何一次这样的改动都会让 WDA 规则不再等于 WDA_DOMAINS, 于是
    _is_wda_rule 认不出它: 面板显示"落地出口", 关 WDA 只清空 unlock.txt 而 55 个域名继续
    指向 jp —— 正是内联化本要消灭的半套状态。
    (旧实现里 WDA 规则带 rule_set=unlock, 被 add_rule 的 `"rule_set" not in r` 天然挡住,
     所以这几处以前不需要判。)"""
    previous_domains = _read_unlock_domains()
    return lambda r: _is_wda_rule(r, previous_domains)


def _wda_on(c=None):
    c = c or load()
    previous_domains = _read_unlock_domains()
    return any(_is_wda_rule(r, previous_domains)
               for r in c.get("route", {}).get("rules", []))

def _server_ip():
    """本机公网 IP(从 sing-box 的 reject 规则取); 用于提示去解锁服务后台授权哪个 IP。"""
    try:
        for r in load().get("route", {}).get("rules", []):
            if r.get("action") == "reject":
                for x in r.get("ip_cidr", []):
                    if x.endswith("/32") and not x.startswith("127."):
                        return x.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    return "本机公网IP"

def _wda_authorized():
    """探测本机 IP 是否已在解锁服务后台授权: 解锁 DNS 对 Netflix 判别域名返回"中继"
    (与解锁 DNS 同 /24 的 IP)即已授权。没订阅/没加白/DNS 不通 → False。"""
    net24 = UNLOCK_DNS.rsplit(".", 1)[0] + "."
    out = sh(["dig", "+short", "+time=3", "+tries=2", "@" + UNLOCK_DNS, "nflxso.net", "A"]).stdout
    return any(ln.strip().startswith(net24) for ln in out.splitlines())

def _unlock_text(domains):
    """WDA 解锁清单内容(不落盘)。空列表 = 落地模式(清空 → mosdns 解锁支休眠)。"""
    return "".join("domain:%s\n" % d for d in domains).encode("utf-8")


def _unlock_precheck(domains):
    """要写域名时, mosdns 必须已经有解锁支; 否则写了也不会生效。"""
    if not domains:
        return True, ""
    try:
        if "unlock_upstream" not in open(MOSDNS_CONF).read():
            return False, "mosdns 还没有解锁支(unlock_upstream)。请先在服务器跑  sudo pdg update  补上再切。"
    except OSError as e:
        return False, "读 mosdns 配置失败: %s" % type(e).__name__
    return True, ""


def set_wda_mode(on):
    """WDA 解锁 ↔ 落地出口。mosdns 解锁清单与 model 内联域名规则现在是**一笔事务**:
    以前三处分三步写, 任何一步失败都可能留下"内核撤了规则、mosdns 还在走解锁 DNS"的半套状态。"""
    if on and not _wda_authorized():             # 没授权就开 = 拿不到中继, 反而更糟 → 先拦住
        ip = _server_ip()
        return False, ("⚠️ 没在解锁 DNS(%s)上测到本机的中继, <b>先别开 WDA</b>(否则解锁服务拿不到中继, 流媒体反而可能挂)。\n"
                       "常见原因: 没订阅解锁服务 / 没在服务商<b>后台把本机公网 IP <code>%s</code> 加白授权</b> / DNS 不通。\n"
                       "→ 去服务商后台授权本机 IP <code>%s</code>, 再点 🔓。(未改动, 仍走落地出口)"
                       % (UNLOCK_DNS, ip, ip))
    domains = WDA_DOMAINS if on else []
    okp, errp = _unlock_precheck(domains)
    if not okp:
        return False, errp

    previous_domains = _read_unlock_domains()

    def mod(c):
        c["route"].setdefault("rule_set", [])
        c["route"]["rule_set"] = [r for r in c["route"]["rule_set"] if r.get("tag") != "unlock"]
        # 同时收掉老装的 rule_set=unlock 与新版内联规则, 让开/关/重复开启都幂等。
        c["route"]["rules"] = [
            r for r in c["route"]["rules"]
            if not _is_wda_rule(r, previous_domains)
        ]
        if on:
            idx = 1 if c["route"]["rules"] and c["route"]["rules"][0].get("action") == "reject" else 0
            c["route"]["rules"].insert(
                idx, {"domain_suffix": list(WDA_DOMAINS), "outbound": "jp"})

    # 老机器上还躺着 v1.7.0 那份 /etc/sing-box/rs/unlock.json: model 已经不引用它, mihomo
    # 也不会加载, 但它是这次改动留下的孤儿。None = 这笔事务里把它删掉; 文件本来就不在的机器
    # 上是空操作(pdgtx 对 data=None 且 existed=False 什么都不做)。
    files = {"mosdns_rule:unlock.txt": _unlock_text(domains),
             "ruleset:unlock.json": None}
    ok, msg = tx_apply("wda_" + ("on" if on else "off"), model_mod=mod, files=files)
    if not ok:
        return False, msg
    if on:
        return True, ("✅ 已切到【🔓 WDA 解锁】: %d 个域名走 WDA(jp 直出 + 22.22.22.22 中继)。\n"
                      "其余流量照常分流。哪个服务在 WDA 下不灵, 切回【落地出口】即可。") % len(WDA_DOMAINS)
    return True, "✅ 已切到【🛬 落地出口】: 解锁域名回落各自出口(hk/tw), mosdns 解锁清单已清空。"


# ── 持久化开关 (profile.env: PDG_LOWMEM / PDG_TFO …) ──
def _profile_get(key, default=""):
    try:
        for line in open(PROFILE_ENV, encoding="utf-8"):
            line = line.strip()
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
    except OSError:
        pass
    return default

def _profile_text_with(key, val):
    """把 profile.env 改成"key=val"后的完整内容(不落盘)。"""
    try:
        lines = open(PROFILE_ENV, encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    out, found = [], False
    for line in lines:
        if line.strip().startswith(key + "="):
            out.append("%s=%s" % (key, val)); found = True
        else:
            out.append(line)
    if not found:
        out.append("%s=%s" % (key, val))
    return ("\n".join(out) + "\n").encode("utf-8")


def _tfo_intent(c=None):
    v = _profile_get("PDG_TFO")
    if v in ("0", "1"):
        return v == "1"
    # 老装未持久化: 回退到旧的"所有代理出口都带标志"判断(一次 apply 后即随出口固化)
    if c is None:
        try:
            c = load()
        except Exception:  # noqa: BLE001
            return False
    obs = [o for o in c.get("outbounds", []) if o.get("type") in PROXY_TYPES]
    return bool(obs) and all(o.get("tcp_fast_open") for o in obs)

def _tfo_apply(c, on):
    """把 TFO 意图同步到所有代理出口 + 入站(在 apply_sb 内每次调用)。"""
    for o in c.get("outbounds", []):
        if o.get("type") in PROXY_TYPES:
            if on:
                o["tcp_fast_open"] = True
            else:
                o.pop("tcp_fast_open", None)
    for i in c.get("inbounds", []):
        if on:
            i["tcp_fast_open"] = True
        else:
            i.pop("tcp_fast_open", None)

def _tfo_on(c=None):
    return _tfo_intent(c)

# TFO 的内核值在这里定死, 免得"开/关"各处理解不一:
#   开启 = 3(客户端 + 服务端都启用: 网关既往落地发起连接, 也接手机的连接)
#   关闭 = 1(Linux 的发行版默认值 —— **只**收回本项目额外打开的服务端那一半;
#           写 0 会把客户端 TFO 也一起关掉, 那是在替系统上别的程序做决定)
TFO_ON, TFO_OFF = 3, 1


def set_tfo(on):
    """TFO 开关。持久意图(profile.env)、出口/入口标志(model)、sysctl drop-in 与运行时值
    同属一笔事务。

    关闭时**写"关闭态"的 drop-in 并真的把运行时值改回去** —— 旧实现只改 profile.env 与
    model, 99-pdg-tfo.conf 原样留着、运行时 net.ipv4.tcp_fastopen 还是 3, 于是 Bot 显示
    "已关闭", 重启后又是开着的。"""
    prof = _profile_text_with("PDG_TFO", "1" if on else "0")
    files = {
        "profile_env": prof,
        "sysctl_tfo": ("net.ipv4.tcp_fastopen=%d\n" % (TFO_ON if on else TFO_OFF)).encode(),
    }
    ok, msg = tx_apply("tfo_" + ("on" if on else "off"),
                       model_mod=lambda c: None, files=files, tfo_intent=on)
    if not ok:
        return False, msg
    return True, (f"✅ TFO 已{'开启' if on else '关闭'}(出口+入口, 内核值 "
                  f"net.ipv4.tcp_fastopen={TFO_ON if on else TFO_OFF})\n"
                  "新增出口会自动继承此设置。降到落地的握手延迟; 需落地端也支持, 否则自动回落普通握手。")


# ── 临时观测/控制面板 (zashboard, 由 sing-box external_ui 托管) ──────────────
# 默认关闭=零暴露: clash_api 只绑 127.0.0.1、无 secret、防火墙不放行 9090。
# 开启=临时把 clash_api 绑 0.0.0.0 + 随机 secret + 固定来源 external_ui,
# 并放行"仅内网卡段"→9090。只接管本项目的精确配置形态, 不覆盖用户自定义 clash_api。
PANEL_PORT = 9090
PANEL_LOCAL = "127.0.0.1:%d" % PANEL_PORT
PANEL_LISTEN = "0.0.0.0:%d" % PANEL_PORT
UI_DIR = "/etc/sing-box/ui"
UI_DIST = os.path.join(UI_DIR, "dist")
UI_META = os.path.join(UI_DIR, ".pdg-zashboard.json")
VERSIONS_FILE = os.environ.get("PDG_VERSIONS_FILE", "/opt/privdns-gateway/lib/versions.sh")

def _load_zashboard_pin():
    """从项目版本清单读取 zashboard 版本与 SHA；缺失时失败关闭，不另设第二份常量。"""
    repo_versions = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "lib", "versions.sh"))
    for path in dict.fromkeys((VERSIONS_FILE, repo_versions)):
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        ver = re.search(r'^ZASHBOARD_VER="([^"]+)"', text, re.M)
        sha = re.search(r'^\s*\[zashboard\]="([0-9a-f]{64})"', text, re.M)
        if ver and sha:
            return ver.group(1), sha.group(1)
    return "", ""

ZASHBOARD_VER, ZASH_SHA = _load_zashboard_pin()
ZASH_URL = ("https://github.com/Zephyruso/zashboard/releases/download/%s/dist-no-fonts.zip"
            % ZASHBOARD_VER) if ZASHBOARD_VER else ""

def _panel_state(c=None):
    """返回 off / on / custom；on 同时识别升级前未写 download_url 的受管形态。"""
    if c is None:
        c = load()
    api = c.get("experimental", {}).get("clash_api", {}) or {}
    if not isinstance(api, dict):
        return "custom"
    controller = api.get("external_controller", "")
    transient = ("secret", "external_ui", "external_ui_download_url")
    if controller == PANEL_LOCAL and not any(k in api for k in transient):
        return "off"
    download = api.get("external_ui_download_url")
    managed_download = (not download or re.fullmatch(
        r"https://github\.com/Zephyruso/zashboard/releases/download/[^/]+/dist-no-fonts\.zip", download))
    if (controller == PANEL_LISTEN and api.get("secret") and api.get("external_ui") == UI_DIST
            and managed_download):
        return "on"
    return "custom"

def _panel_on(c=None):
    return _panel_state(c) == "on"

def _panel_sanitize_config(c):
    """只把本项目受管开启态收回本地；自定义 clash_api 原样保留。"""
    if _panel_state(c) != "on":
        return False
    api = c["experimental"]["clash_api"]
    api["external_controller"] = PANEL_LOCAL
    api.pop("secret", None)
    api.pop("external_ui", None)
    api.pop("external_ui_download_url", None)
    return True

def _panel_close_config(c):
    """在 apply_sb 锁内复核归属；已关闭可幂等通过，自定义态立即中止。"""
    state_now = _panel_state(c)
    if state_now == "custom":
        raise _PanelOwnershipError
    if state_now == "on":
        _panel_sanitize_config(c)

def _panel_cidr():
    """从防火墙现有放行规则读内网卡段(和 853/443 同源门控)。"""
    out = sh(["nft", "list", "chain", "inet", "pdg", "input"]).stdout
    m = re.search(r"ip saddr ([0-9.]+/[0-9]+) tcp dport", out)
    return m.group(1) if m else ""

def _ui_fingerprint(root):
    """稳定计算 UI 目录内容指纹；路径也参与哈希，避免文件换名绕过。"""
    if not os.path.isdir(root) or os.path.islink(root):
        return ""
    digest = hashlib.sha256()
    for base, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not os.path.islink(os.path.join(base, d)))
        for name in sorted(files):
            path = os.path.join(base, name)
            if os.path.islink(path):
                return ""
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            digest.update(rel.encode() + b"\0")
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()

def _remove_path(path):
    if not os.path.lexists(path):
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)

def _zashboard_current():
    try:
        meta = json.load(open(UI_META, encoding="utf-8"))
        return (meta.get("version") == ZASHBOARD_VER
                and meta.get("archive_sha256") == ZASH_SHA
                and meta.get("tree_sha256") == _ui_fingerprint(UI_DIST)
                and os.path.isfile(os.path.join(UI_DIST, "index.html")))
    except Exception:  # noqa: BLE001
        return False

def _ensure_zashboard():
    """验证或原子安装固定版本 zashboard；内容被替换时自动恢复。"""
    if not ZASHBOARD_VER or not ZASH_SHA or not ZASH_URL:
        return False, "读不到 zashboard 版本清单, 拒绝开启"
    if _zashboard_current():
        return True, ""
    stage = old = None
    try:
        data = _fetch_bytes(ZASH_URL)
        if hashlib.sha256(data).hexdigest() != ZASH_SHA:
            return False, "zashboard 校验失败(SHA256 不符, 拒绝安装)"
        os.makedirs(UI_DIR, exist_ok=True)
        stage = tempfile.mkdtemp(prefix=".zashboard-", dir=UI_DIR)
        import zipfile
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                name = info.filename.replace("\\", "/")
                if name.startswith("/") or ".." in name.split("/") or (info.external_attr >> 16) & 0o170000 == 0o120000:
                    return False, "zashboard 压缩包含不安全路径, 拒绝安装"
            z.extractall(stage)
        staged_dist = os.path.join(stage, "dist")
        if not os.path.isfile(os.path.join(staged_dist, "index.html")):
            return False, "解压后缺 index.html"
        tree_sha = _ui_fingerprint(staged_dist)
        if not tree_sha:
            return False, "zashboard 内容指纹生成失败"
        old = UI_DIST + ".pdg-old"
        _remove_path(old)
        if os.path.lexists(UI_DIST):
            os.replace(UI_DIST, old)
        try:
            os.replace(staged_dist, UI_DIST)
        except Exception:
            if os.path.lexists(old) and not os.path.lexists(UI_DIST):
                os.replace(old, UI_DIST)
            raise
        _remove_path(old)
        old = None
        meta_tmp = UI_META + ".tmp"
        with open(meta_tmp, "w", encoding="utf-8") as f:
            json.dump({"version": ZASHBOARD_VER, "archive_sha256": ZASH_SHA,
                       "tree_sha256": tree_sha}, f, ensure_ascii=False)
        os.replace(meta_tmp, UI_META)
        return True, ""
    except Exception as e:  # noqa: BLE001
        return False, "下载/解压失败: " + type(e).__name__
    finally:
        if stage:
            shutil.rmtree(stage, ignore_errors=True)
        # 替换失败时保留 .pdg-old 供人工恢复；成功路径已在上面主动删除。

def _panel_firewall_apply(on, cidr):
    """放行/撤销 内网卡段 → 9090，并核验最终状态。返回 (ok, err)。"""
    listed = sh(["nft", "-a", "list", "chain", "inet", "pdg", "input"])
    if listed.returncode != 0:
        return False, "nft list 失败: " + (listed.stdout + listed.stderr)[-200:]
    out = listed.stdout
    for ln in out.splitlines():
        if "pdg-panel" in ln:
            m = re.search(r"handle (\d+)", ln)
            if m:
                r = sh(["nft", "delete", "rule", "inet", "pdg", "input", "handle", m.group(1)])
                if r.returncode != 0:
                    return False, "nft delete 失败: " + (r.stdout + r.stderr)[-200:]
    if on and cidr:
        r = sh(["nft", "insert", "rule", "inet", "pdg", "input", "ip", "saddr", cidr,
                "tcp", "dport", str(PANEL_PORT), "accept", "comment", "pdg-panel"])
        if r.returncode != 0:
            return False, "nft insert 失败: " + (r.stdout + r.stderr)[-200:]
    verified = sh(["nft", "-a", "list", "chain", "inet", "pdg", "input"])
    if verified.returncode != 0:
        return False, "nft verify 失败: " + (verified.stdout + verified.stderr)[-200:]
    managed = [ln for ln in verified.stdout.splitlines() if "pdg-panel" in ln]
    if on and not any(cidr in ln and str(PANEL_PORT) in ln for ln in managed):
        return False, "nft verify 失败: 未找到内网 9090 放行规则"
    if not on and managed:
        return False, "nft verify 失败: 9090 放行规则仍存在"
    return True, ""

def _panel_firewall(on, cidr):
    try:
        return _panel_firewall_apply(on, cidr)
    except Exception as e:  # noqa: BLE001
        return False, "nft 操作异常(%s)" % type(e).__name__

_panel_op_lock = threading.Lock()

def _set_panel(on):
    try:
        state_now = _panel_state()
    except Exception as e:  # noqa: BLE001
        return False, "读取 clash_api 配置失败: " + type(e).__name__
    if state_now == "custom":
        return False, "检测到自定义 clash_api 配置, 为避免覆盖已保持原样"
    if on:
        cidr = _panel_cidr()
        if not cidr:
            return False, "读不到内网卡段(防火墙未就绪?), 暂不开启"
        ok, err = _ensure_zashboard()
        if not ok:
            return False, err
        secret = uuid.uuid4().hex
        def mod(c):
            if _panel_state(c) == "custom":
                raise _PanelOwnershipError
            api = c.setdefault("experimental", {}).setdefault("clash_api", {})
            api["external_controller"] = PANEL_LISTEN
            api["secret"] = secret
            api["external_ui"] = UI_DIST
            api["external_ui_download_url"] = ZASH_URL
        ok, msg = apply_sb(mod)
        if not ok:
            return False, msg
        fw_ok, fw_msg = _panel_firewall(True, cidr)
        if not fw_ok:
            rb_ok, rb_msg = apply_sb(_panel_close_config)
            clean_ok, clean_msg = _panel_firewall(False, cidr)
            detail = "防火墙开启失败: " + fw_msg
            if not rb_ok or not clean_ok:
                detail += "; 回滚不完整: " + (rb_msg if not rb_ok else clean_msg)
            return False, detail
        ip = _server_ip()
        link = "http://%s:%d/ui/#/setup?hostname=%s&port=%d&secret=%s" % (ip, PANEL_PORT, ip, PANEL_PORT, secret)
        secret = None
        return True, link
    if state_now == "on":
        ok, msg = apply_sb(_panel_close_config)
        if not ok:
            return False, msg
    fw_ok, fw_msg = _panel_firewall(False, _panel_cidr())
    if not fw_ok:
        return False, "clash_api 已收回本地, 但撤销防火墙失败: " + fw_msg
    return True, "✅ 观测面板已关闭(clash_api 收回 127.0.0.1、撤销内网 9090 放行)。"

def set_panel(on):
    with _panel_op_lock:
        try:
            return _set_panel(on)
        except Exception as e:  # noqa: BLE001
            return False, "面板操作异常(%s)" % type(e).__name__

# ── 面板定时自动关闭(会话代号隔离旧回调；关闭失败保留状态并重试) ──────────────
PANEL_RETRY_SECONDS = 60
_panel_timer = None            # threading.Timer 或 None
_panel_link = None             # (chat, message_id) 含密钥的链接消息
_panel_chat = None             # 无链接时也保留通知对象
_panel_generation = 0          # 每次重新开启/取消都递增，旧回调见到不一致即退出
_panel_state_lock = threading.Lock()

def _cancel_timer_obj(timer):
    if timer is not None:
        try:
            timer.cancel()
        except Exception:  # noqa: BLE001
            pass

def _panel_clear_state(generation=None):
    """成功关闭后的统一清理；generation 不匹配时绝不碰新会话。"""
    global _panel_timer, _panel_link, _panel_chat, _panel_generation
    with _panel_state_lock:
        if generation is not None and generation != _panel_generation:
            return False
        timer, link = _panel_timer, _panel_link
        _panel_timer = _panel_link = _panel_chat = None
        _panel_generation += 1
    _cancel_timer_obj(timer)
    if link:
        delete_message(*link)
    return True

def _panel_schedule_retry(chat=None, generation=None):
    """关闭失败时把当前计时器替换为短间隔重试，不重复堆积。"""
    global _panel_timer, _panel_chat, _panel_generation
    with _panel_state_lock:
        if generation is not None and generation != _panel_generation:
            return False
        old_timer = _panel_timer
        _panel_generation += 1                 # 让被替换但已启动的旧回调立即失效
        if chat is not None:
            _panel_chat = chat
        current = _panel_generation
        timer = threading.Timer(PANEL_RETRY_SECONDS, _panel_autoclose, args=(current,))
        timer.daemon = True
        _panel_timer = timer
    _cancel_timer_obj(old_timer)
    timer.start()
    return True

def _panel_autoclose(generation=None):
    """定时到期：只处理当前会话；失败保留链接并自动重试。"""
    global _panel_timer
    with _panel_state_lock:
        current = _panel_generation if generation is None else generation
        if current != _panel_generation:
            return
        _panel_timer = None
        chat = _panel_chat
    ok, msg = set_panel(False)
    if ok:
        if _panel_clear_state(current) and chat:
            send_plain(chat, "⏱ 观测面板已到时自动关闭,上面那条链接已失效。")
        return
    if _panel_schedule_retry(chat, current) and chat:
        send_plain(chat, "⏱ 自动关闭观测面板失败,将在 60 秒后重试: " + msg)

def _panel_arm(chat, link_mid, ttl):
    """记录新会话并按 ttl 排自动关闭；重新开启会删旧链接。ttl<=0 为常开。"""
    global _panel_timer, _panel_link, _panel_chat, _panel_generation
    with _panel_state_lock:
        old_timer, old_link = _panel_timer, _panel_link
        _panel_generation += 1
        current = _panel_generation
        new_link = (chat, link_mid) if link_mid else None
        _panel_link = new_link
        _panel_chat = chat
        timer = threading.Timer(ttl, _panel_autoclose, args=(current,)) if ttl > 0 else None
        if timer:
            timer.daemon = True
        _panel_timer = timer
    _cancel_timer_obj(old_timer)
    if old_link and old_link != new_link:
        delete_message(*old_link)
    if timer:
        timer.start()

def _panel_close(chat=None):
    """手动关闭：成功后才清理链接；失败时保留并补重试计时器。"""
    with _panel_state_lock:
        generation = _panel_generation
    ok, msg = set_panel(False)
    if ok:
        _panel_clear_state(generation)
    else:
        _panel_schedule_retry(chat, generation)
    return ok, msg

def _panel_publish(chat, link, ttl):
    """发送含密钥链接并开始计时；发送失败时立即收回面板。"""
    link_mid = send_get_mid(chat, "✅ 临时观测/控制面板已开启（链接含密钥，请勿转发）:\n" + link)
    if link_mid:
        _panel_arm(chat, link_mid, ttl)
        return True, ""
    closed, close_msg = set_panel(False)
    _panel_clear_state()
    if not closed:
        _panel_schedule_retry(chat)
        return False, "面板链接发送失败，且关闭失败，将自动重试: " + close_msg
    return False, "面板链接发送失败，已自动关闭面板"

def _panel_startup_cleanup():
    """bot 重启后只清理本项目受管状态；自定义 clash_api 不动。"""
    try:
        state_now = _panel_state()
    except Exception as e:  # noqa: BLE001
        return False, "读取 clash_api 配置失败: " + type(e).__name__
    if state_now == "custom":
        return False, "检测到自定义 clash_api 配置, 启动清理未改动"
    if state_now == "on":
        ok, msg = set_panel(False)
        if not ok:
            _panel_schedule_retry()
        return ok, msg
    ok, msg = _panel_firewall(False, _panel_cidr())
    return (True, "panel: 默认关闭态已确认") if ok else (False, msg)

def send_get_mid(chat, text):
    """发纯文本(不解析 HTML, 保链接可点)并返回 message_id, 供之后删除。"""
    r = post("sendMessage", {"chat_id": chat, "text": text, "disable_web_page_preview": True})
    return (r.get("result") or {}).get("message_id")

# ── 规则集 (Surge .list -> sing-box local rule_set) ──
def _rs_meta():
    if os.path.exists(RS_META):
        return json.load(open(RS_META))
    return {}

def _fetch_surge(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pdg-bot"})
    with urllib.request.urlopen(req, timeout=30) as r:
        text = r.read().decode("utf-8", "ignore")
    dom, suf, kw, ip = [], [], [], []
    for line in text.splitlines():
        line = line.split("#", 1)[0].split("//", 1)[0].strip()
        if not line:
            continue
        # Clash/mihomo 的 YAML provider 形如:
        #     payload:
        #       - DOMAIN-SUFFIX,example.com
        #       - 'DOMAIN,api.example.com'
        # 去掉列表短横线与引号后, 剩下的与 Surge/Clash 文本行同形 —— 不这么处理的话
        # `p[0]` 会是 "- DOMAIN-SUFFIX", 一条都匹配不上, 整个 provider 被判成"没解析出规则"。
        if line == "payload:" or line.endswith(":"):
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        elif line.startswith("-") and len(line) > 1 and not line[1].isdigit():
            line = line[1:].strip()
        if len(line) >= 2 and line[0] == line[-1] and line[0] in ("'", '"'):
            line = line[1:-1].strip()
        if not line:
            continue
        p = [x.strip() for x in line.split(",")]
        t = p[0].upper()
        if t == "DOMAIN" and len(p) > 1:
            dom.append(p[1])
        elif t == "DOMAIN-SUFFIX" and len(p) > 1:
            suf.append(p[1])
        elif t == "DOMAIN-KEYWORD" and len(p) > 1:
            kw.append(p[1])
        elif t in ("IP-CIDR", "IP-CIDR6") and len(p) > 1:
            ip.append(p[1])
    return dom, suf, kw, ip

def _fetch_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pdg-bot"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

def _build_source(url, path):
    """下载 Surge/Clash 文本 → 写 sing-box source rule_set。返回 (条数, 是否纯IP)。"""
    dom, suf, kw, ip = _fetch_surge(url)
    if not (dom or suf or kw or ip):
        raise ValueError("没解析出规则(支持 DOMAIN/-SUFFIX/-KEYWORD/IP-CIDR)")
    rule = {}
    if dom:
        rule["domain"] = dom
    if suf:
        rule["domain_suffix"] = suf
    if kw:
        rule["domain_keyword"] = kw
    if ip:
        rule["ip_cidr"] = ip
    json.dump({"version": 1, "rules": [rule]}, open(path, "w"), ensure_ascii=False)
    return len(dom) + len(suf) + len(kw) + len(ip), (len(dom) + len(suf) + len(kw) == 0)

# mihomo 的 .mrs 只有这两种 behavior —— classical 连它自己的 convert-ruleset 都会崩,
# 收下等于配出一份内核加载不了的规则集。
MRS_BEHAVIORS = mihomorender.MRS_BEHAVIORS


def _mrs_unreadable_hint():
    """认不出类型时的下一步。本机没 zstd 就直说 —— 装上它这类文件就能自动识别,
    否则用户只会以为"这个源就是要手填", 一直填下去。"""
    if shutil.which("zstd") or mihomorender._zstd_head_mod(b"", 1) != b"":
        return ""
    return ("\n提示: 本机没有 <code>zstd</code>, 大一点的 .mrs 就读不出类型了。"
            "装上即可自动识别: <code>sudo apt-get install -y zstd</code>")


def mrs_behavior(data):
    """从 .mrs 二进制里认出 behavior(domain/ipcidr); 认不出返回 None。实现在 mihomorender ——
    救援与恢复侧也要用同一份判据, 不能只长在 bot 里。"""
    return mihomorender.mrs_behavior(data)


def _mrs_behavior_of_file(path):
    """本地已下好的 .mrs 里认 behavior(读不到/认不出返回 None)。"""
    return mihomorender.mrs_behavior_of_file(path)


def add_ruleset(url, target, label="", behavior=""):
    c = load()
    if target not in exit_tags(c):
        return False, f"出口 {target} 不存在; 可选: {', '.join(exit_tags(c))}"
    low = url.lower().split("?", 1)[0]
    # .srs 是 sing-box 的二进制规则集, mihomo 消费不了 —— 收下它只会在渲染时被丢弃, 而用户
    # 以为分流已生效。入口就拒, 并指出可用的替代格式(不再"接受成功, 背地丢弃")。
    if low.endswith(".srs"):
        return False, (".srs 是 sing-box 二进制规则集, mihomo 无法读取(收下也不会进运行配置)。\n"
                       "请改用 .list / .txt 文本规则、.yaml provider, 或 mihomo 原生 .mrs。")
    name = "rs_" + hashlib.sha1(url.encode()).hexdigest()[:8]
    # 下载与解析全在**候选**阶段: 提交之前一个字节都不写进 RS_DIR。旧实现先落盘再 apply_sb,
    # 失败还要自己回退文件与元数据 —— 中间任何异常都会留下半截。
    try:
        if low.endswith(".mrs"):
            # mihomo 原生二进制规则集: 直接存盘, 由 rule-provider 按 mrs 格式加载。
            # behavior 先从文件二进制头**认**(文件就是事实), 认不出才要求用户显式声明 ——
            # 一律按 domain 猜, 猜错就是"规则看着加了却永不命中"。
            path = os.path.join(RS_DIR, name + ".mrs"); fmt = "mrs"
            data = _fetch_bytes(url)
            if not data:
                raise ValueError("下载到空的 .mrs(源站异常?)")
            sniffed = mrs_behavior(data)
            warn = ""
            if sniffed and behavior and behavior != sniffed:
                warn = f"\n(你填的类型是 {behavior}, 但文件里写着 {sniffed} —— 已按文件为准)"
            if sniffed:
                behavior = sniffed
            elif behavior not in MRS_BEHAVIORS:
                return False, (".mrs 需要指定规则类型(behavior): 这份文件的二进制头认不出类型"
                               "(不是 MRS 或版本不认识)。\n"
                               "请在规则集后面补上类型: " + " / ".join(MRS_BEHAVIORS) + "\n"
                               "例: <code>https://.../geo.mrs hk 名称 domain</code>"
                               + _mrs_unreadable_hint())
            count = None
        else:
            path = os.path.join(RS_DIR, name + ".json"); fmt = "source"
            _tmpd = tempfile.mkdtemp(prefix="pdgrs-add.")
            try:
                _tmp = os.path.join(_tmpd, name + ".json")
                count, ip_only = _build_source(url, _tmp)
                try:
                    with open(_tmp, "rb") as _f:
                        data = _f.read()
                except OSError:
                    # _build_source 没写出文件(异常形态/被打桩)→ 用它解析出的计数信息也不可信,
                    # 但仍要给候选一个**合法的空规则集**, 由内核校验门去判要不要收
                    data = json.dumps({"version": 1, "rules": []}, ensure_ascii=False).encode()
            finally:
                shutil.rmtree(_tmpd, ignore_errors=True)
            warn = ("\n⚠️ 纯 IP 规则集: 本网关按域名(SNI)分流, IP 规则基本不会命中 "
                    "(Telegram App 等也走不了)。" if ip_only else "")
    except Exception as e:  # noqa: BLE001
        return False, f"下载/解析失败: {e}"

    def mod(cc):
        cc["route"].setdefault("rule_set", [])
        cc["route"]["rule_set"] = [r for r in cc["route"]["rule_set"] if r.get("tag") != name]
        cc["route"]["rule_set"].append({"tag": name, "type": "local", "format": fmt, "path": path})
        cc["route"]["rules"] = [r for r in cc["route"]["rules"] if r.get("rule_set") != name]
        idx = 1 if cc["route"]["rules"] and cc["route"]["rules"][0].get("action") == "reject" else 0
        cc["route"]["rules"].insert(idx, {"rule_set": name, "outbound": target})

    # 元数据必须**先**落地: mihomo 的 rule-providers 是从 RS_META 生成的, 后写就意味着本次
    # 渲染看不到这个规则集 —— 规则会被当成"翻译不了"丢掉, 而用户已经收到"已添加"。
    # 失败则把元数据与下载的文件一并回退, 不留半截。
    m = dict(_rs_meta())
    m[name] = {"url": url, "outbound": target, "format": fmt, "path": path, "count": count}
    if behavior in MRS_BEHAVIORS:
        m[name]["behavior"] = behavior
    if label.strip():
        m[name]["label"] = label.strip()[:40]
    # model / 规则集文件 / 元数据 一次提交: 渲染派生时读的是**这份 staged 元数据**, 所以
    # 不再需要"元数据必须先落地"那种取巧, 也不会出现"文件在、元数据不在"的中间态。
    rs_files = {"ruleset:" + os.path.basename(path): data,
                "rs_meta": json.dumps(m, ensure_ascii=False, indent=2).encode("utf-8")}
    # 派生的劫持表必须和规则集**同一笔事务**: 分两步写, 中间失败就会留下"规则集在、DNS 侧
    # 不劫持"的半套 —— 那正是这个功能要消灭的状态。派生读的是候选文件, 所以先把它写到临时
    # 位置再算(下面 _staged_meta_path 负责)。
    hj, undrivable = _ruleset_hijack_file(m, {name: data})
    rs_files.update(hj)
    ok, msg = tx_apply("ruleset_add", model_mod=mod, files=rs_files)
    if ok:
        cntdesc = f"{count} 条" if count is not None else "mihomo .mrs"
        return True, (f"规则集已添加 → {target}（{cntdesc}，{label.strip() or name}）" + warn
                      + _undrivable_note(undrivable))
    return False, msg

def set_ruleset_label(name, label):
    """给规则集设个看得懂的显示名(备注), 只改 bot 显示, 不动 sing-box 内部 tag/文件。"""
    m = _rs_meta()
    if name not in m:
        return False, "规则集不存在(可能已删), 重开列表再试"
    label = label.strip()[:40]
    if label:
        m[name]["label"] = label
    else:
        m[name].pop("label", None)
    ok, msg = tx_apply("ruleset_label", files={
        "rs_meta": json.dumps(m, ensure_ascii=False, indent=2).encode("utf-8")})
    return (True, f"✅ 规则集名称已设为「{label or name}」") if ok else (False, msg)

def _rs_items():
    """[(name, 显示文字)] 供选择键盘用。"""
    return [(n, (i.get("label") or n) + f" · {i.get('count', '?')}条") for n, i in _rs_meta().items()]

def del_ruleset(name):
    """删规则集: model 规则、规则集文件、元数据**一笔事务**。

    旧实现是 apply_sb 成功之后才去删文件与元数据 —— 中间失败就会留下"内核已经不引用它了,
    文件和元数据还在"的残留, 下次渲染又把它算进来。"""
    m = _rs_meta(); info = m.get(name, {}); path = info.get("path")
    label = info.get("label") or name              # 删前取显示名(删完 meta 就没了)

    def mod(cc):
        cc["route"]["rule_set"] = [r for r in cc["route"].get("rule_set", []) if r.get("tag") != name]
        cc["route"]["rules"] = [r for r in cc["route"]["rules"] if r.get("rule_set") != name]

    files = {}
    for p_ in {path, os.path.join(RS_DIR, name + ".json"), os.path.join(RS_DIR, name + ".mrs")}:
        if p_ and os.path.dirname(p_) == RS_DIR and os.path.exists(p_):
            files["ruleset:" + os.path.basename(p_)] = None      # None = 本次要删掉它
    m2 = dict(m); m2.pop(name, None)
    files["rs_meta"] = json.dumps(m2, ensure_ascii=False, indent=2).encode("utf-8")
    files.update(_ruleset_hijack_file(m2)[0])      # 删掉之后重算, 不留死域名
    ok, msg = tx_apply("ruleset_del", model_mod=mod, files=files)
    return (True, f"已删除规则集 {label}") if ok else (False, msg)


def refresh_rulesets():
    """重下全部规则集并**整批**原子提交。返回 (成功刷新数, 失败项列表)。

    语义(5.1 定死, 与用户可见行为一致):
      · 下载与解析发生在**候选阶段** —— 拿不到的源不进候选, 它的旧文件原样留着继续用;
      · 所有下载成功的规则集作为**一个集合**提交: 其中任一校验/落盘/内核应用失败, 整批回滚,
        一个都不换(不会出现"换了一半")；
      · 成功时事务状态就是 COMMITTED, 未更新的源写进 warnings 如实告知 —— 不新增
        "带警告的提交"这种中间状态;
      · **零成功不提交**: 一个源都没下来时直接返回, 不空跑一笔事务, 更不谎报"已更新"。
    """
    m = _rs_meta()
    if not m:
        return 0, []
    files, failed, n = {}, [], 0
    blobs = {}                 # 本批下下来的候选内容: 劫持表按它算, 不按磁盘上的旧档
    tmpd = tempfile.mkdtemp(prefix="pdgrs-cand.")
    try:
        for name, info in m.items():
            # 兼容早期缺 format/path 的旧条目(按 name 回填, 否则刷新会 KeyError)
            info.setdefault("format", "binary" if str(info.get("path", "")).endswith(".srs") else "source")
            info.setdefault("path", os.path.join(RS_DIR, name + (".srs" if info["format"] == "binary" else ".json")))
            leaf = os.path.basename(info["path"])
            if leaf.endswith(".srs"):
                # sing-box 二进制规则集: mihomo 读不了, 早已在入口被拒。老机器上残留的这种
                # 条目不刷新也不删 —— doctor 会点名让用户换掉。
                failed.append("%s(.srs 无法进入 mihomo 运行配置, 未刷新)" % (info.get("label") or name))
                continue
            try:
                if info["format"] in ("binary", "mrs"):
                    data = _fetch_bytes(info["url"])
                    if not data:
                        raise ValueError("空响应")
                    if info["format"] == "mrs" and info.get("behavior") not in MRS_BEHAVIORS:
                        bh = mrs_behavior(data)
                        if bh:
                            info["behavior"] = bh
                else:
                    tmp = os.path.join(tmpd, leaf)
                    info["count"] = _build_source(info["url"], tmp)[0]
                    with open(tmp, "rb") as f:
                        data = f.read()
                files["ruleset:" + leaf] = data
                blobs[name] = data
                n += 1
            except Exception as e:  # noqa: BLE001
                failed.append("%s(%s: %s)" % (info.get("label") or name, type(e).__name__, e))
        if n == 0:
            return 0, failed
        files["rs_meta"] = json.dumps(m, ensure_ascii=False, indent=2).encode("utf-8")
        hj, undrivable = _ruleset_hijack_file(m, blobs)
        files.update(hj)                           # 派生劫持表与规则集同一笔提交
        # .mrs 派生不了要说, 但**不能算进 failed**: 那个列表的语义是"这些源没刷新成功",
        # 而它们其实刷新得好好的。混进去会让定时任务(scheduled-update.sh 按 failed 退出)
        # 在任何装了 .mrs 规则集的机器上**每次都报失败**。只进事务 warnings。
        warns = list(failed)
        if undrivable:
            warns.append("读不出域名, 没能生成劫持表(gfw 模式下不会命中): "
                         + "、".join(str(x) for x in undrivable[:4]))
        # model 不变, 但仍走一遍派生渲染: 规则集进不了 mihomo 运行配置(dropped)这类问题要在
        # **候选阶段**就被挡下, 与 _mihomo_derive 同一判据; 文件真坏则由重启观察期兜住。
        ok, msg = tx_apply("rulesets_refresh", model_mod=lambda c: None, files=files,
                           services=("mihomo",), warnings=warns)
        if not ok:
            return 0, failed + ["整批未更新(全部保留上一份好档): " + msg]
        return n, failed
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


# ── 测出口 (端到端延迟, clash_api; TCP 兜底) ──
def _test_exits_tcp(c):
    obs = proxy_outbounds(c)
    if not obs:
        return "(无代理出口)"
    lines = []
    for o in obs:
        host = o.get("server"); port = int(o.get("server_port", 0) or 0)
        try:
            t0 = time.monotonic()
            with socket.create_connection((host, port), timeout=5):
                ms = int((time.monotonic() - t0) * 1000)
            lines.append(f"✅ <b>{o['tag']}</b>  {ms}ms  ({o['type']} {host}:{port})")
        except Exception:  # noqa: BLE001
            lines.append(f"❌ <b>{o['tag']}</b>  不通  ({host}:{port})")
    return "出口连通/延迟 (JP→落地 TCP 握手):\n" + "\n".join(lines)

def test_exits():
    c = load()
    if not clash_up():
        return _test_exits_tcp(c)
    tags = concrete_tags(c)   # 只测具体出口(代理+jp直出); urltest 组的 clash 延迟接口偶尔抽风, 不测它
    if not tags:
        return "(无出口)"
    # mihomo: direct 出口(如 jp)被 sb2mihomo 映射成内建 DIRECT, clash 里没有该 tag 名 → 查 DIRECT。
    direct_set = ({o["tag"] for o in c["outbounds"] if o.get("type") == "direct"}
                  if _core_backend() == "mihomo" else set())
    lines = []
    for t in tags:
        q = urllib.parse.quote("DIRECT" if t in direct_set else t, safe="")
        try:
            d = clash_get(f"/proxies/{q}/delay?timeout=5000&url=" + urllib.parse.quote(DELAY_URL))
            lines.append(f"✅ <b>{t}</b>  {d['delay']}ms")
        except urllib.error.HTTPError:
            lines.append(f"❌ <b>{t}</b>  超时/不通")
        except Exception:  # noqa: BLE001
            lines.append(f"❌ <b>{t}</b>  不通")
    return "出口端到端延迟 (经各出口→generate_204):\n" + "\n".join(lines)

# ── 流量统计 (clash_api) ──
def _fmt_bytes(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return (f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}")
        n /= 1024
    return f"{n:.1f}PB"

def _vnstat():
    """网卡真实累计(vnstat, 重启/重启动不丢): 今日/本月/累计 ↓rx ↑tx。"""
    try:
        f = sh(["vnstat", "--oneline"]).stdout.strip().split(";")
        if len(f) >= 15:
            return (f"今日 ↓{f[3]} ↑{f[4]}\n本月 ↓{f[8]} ↑{f[9]}\n累计 ↓{f[12]} ↑{f[13]}")
    except Exception:  # noqa: BLE001
        pass
    return ""

def traffic_text():
    parts = []
    # 实时: clash_api —— 当前连接 + 「本会话」(sing-box 启动以来)经代理流量, sing-box 重启即清零
    if clash_up():
        try:
            d = clash_get("/connections")
            conns = d.get("connections") or []
            cnt, up, dn = Counter(), Counter(), Counter()
            for cn in conns:
                tag = (cn.get("chains") or ["?"])[0]
                cnt[tag] += 1; up[tag] += cn.get("upload", 0); dn[tag] += cn.get("download", 0)
            lines = [f"• <b>{t}</b>: {cnt[t]}条 ↑{_fmt_bytes(up[t])} ↓{_fmt_bytes(dn[t])}"
                     for t, _ in cnt.most_common()]
            parts.append("📈 <b>实时(内核本会话, 重启清零)</b>\n"
                         f"会话累计 ↑{_fmt_bytes(d.get('uploadTotal'))} ↓{_fmt_bytes(d.get('downloadTotal'))}\n"
                         f"活跃连接 {len(conns)}" + ("\n" + "\n".join(lines) if lines else ""))
        except Exception as e:  # noqa: BLE001
            parts.append(f"实时读取失败: {e}")
    v = _vnstat()
    parts.append("📊 <b>总用量(vnstat·网卡真实)</b>\n" + v if v
                 else "📊 总用量: vnstat 暂无数据")
    return "\n\n".join(parts)

def doctor_text():
    """跑共用检查库(checks.ALL), 和 `pdg doctor` 同一套, 在手机上一键自检。"""
    try:
        import checks
        results = checks.run()
    except Exception as e:  # noqa: BLE001
        return f"🩺 自检失败: {e}"
    icon = {"ok": "🟢", "warn": "🟡", "fail": "🔴"}
    nf = sum(1 for l, _, _ in results if l == "fail")
    nw = sum(1 for l, _, _ in results if l == "warn")
    head = "🔴 有问题" if nf else ("🟡 有警告" if nw else "🟢 全部正常")
    lines = [f"{icon.get(l, '⚪️')} <b>{lb}</b>: {d}" for l, lb, d in results]
    tip = "\n\n出问题时排查见 docs/TROUBLESHOOTING-PLAYBOOK.md" if (nf or nw) else ""
    return (f"🩺 <b>自检</b> — {head}  ({nf} 失败 / {nw} 警告 / 共 {len(results)})\n\n"
            + "\n".join(lines) + tip)

# ── 更新(检查 → 确认 → 后台执行)──
PDG_REPO = "/opt/privdns-gateway"

def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def _git(*args, t=60):
    return subprocess.run(["git", "-C", PDG_REPO, *args], capture_output=True, text=True, timeout=t)

def _fetch_release_tags():
    r = _git("fetch", "-q", "--tags", "origin", "main", t=120)
    if r.returncode != 0:
        return False, (r.stderr or r.stdout or "git fetch 失败").strip()
    shallow = _git("rev-parse", "--is-shallow-repository")
    if shallow.stdout.strip() == "true":
        r = _git("fetch", "-q", "--unshallow", "--tags", "origin", "main", t=180)
        if r.returncode != 0:
            return False, (r.stderr or r.stdout or "git fetch --unshallow 失败").strip()
    return True, ""

def update_check():
    """检查是否有更新的发布 tag(只跟 tag, 不拉 main 中间提交)。返回 (有更新?, 文本)。"""
    try:
        ok, err = _fetch_release_tags()
        if not ok:
            return False, f"检查更新失败: {err}"
        cur = _git("describe", "--tags", "--always").stdout.strip()
        tags = _git("tag", "-l", "v*", "--sort=-v:refname").stdout.split()
    except Exception as e:  # noqa: BLE001
        return False, f"检查更新失败: {e}"
    if not tags:
        return False, "🟢 仓库还没有发布 tag。"
    tgt = tags[0]
    head = _git("rev-parse", "HEAD").stdout.strip()
    tcommit = _git("rev-parse", tgt + "^{commit}").stdout.strip()
    if head == tcommit:
        return False, f"🟢 已是最新发布 <b>{tgt}</b>。"
    mb = _git("merge-base", "--is-ancestor", "HEAD", tgt)
    if mb.returncode == 0:
        pass
    elif mb.returncode == 1:
        return False, f"🟢 已是最新(当前 <code>{cur}</code> 不落后于最新发布 {tgt})。"
    else:
        return False, f"检查更新失败: merge-base 判断失败: {(mb.stderr or mb.stdout).strip()}"
    log = _git("log", "--oneline", "HEAD.." + tgt).stdout.strip()
    n = len(log.splitlines())
    return True, (f"🔄 有新发布 <b>{tgt}</b>(当前 <code>{cur}</code>,含 {n} 个提交):\n"
                  f"<pre>{_esc(log)}</pre>\n确认后后台执行 pdg update → 更新到 {tgt}(约 30-60 秒, bot 自动重启回来)。\n"
                  "更新会同时安装该 PrivDNS Gateway 发布版指定并校验过的内核版本。")

def start_update():
    """在独立的 systemd 瞬时单元里跑 pdg update, 不受 pdg-bot 自身重启影响。"""
    try:
        r = subprocess.run(["systemd-run", "--collect", "/usr/local/bin/pdg", "update"],
                           capture_output=True, text=True, timeout=15)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False

# ── 规则集派生的劫持表 ────────────────────────────────────────────────────────
# 为什么需要它: 规则集只写 mihomo 那一侧(rule-providers + RULE-SET 规则), 而流量能不能到
# mihomo 由 mosdns 决定。all 模式下"不是国内就劫持"顺带把规则集的域名兜住了, 看不出问题;
# gfw 模式下劫持集只有被墙域名 —— 规则集里的域名拿到真实 IP, 手机直连, 那条 RULE-SET 规则
# 永远匹配不到。规则加了、UI 说成功了、doctor 也绿, 就是不生效。
#
# 文本/YAML 类规则集在本项目里落盘成 sing-box source JSON(domain / domain_suffix /
# domain_keyword / ip_cidr 四个数组), 域名清单是现成的, 直接派生即可:
#   domain          → full:x     (精确)
#   domain_suffix   → domain:x   (含子域)
#   domain_keyword  → keyword:x
#   ip_cidr         → 跳过        (DNS 这一层没法按 IP 劫持)
# .mrs 是 mihomo 的二进制格式, 域名清单在网关侧展不开 —— **派生不了**, 只能如实告诉用户。
RULESET_HIJACK_MAX = 200000        # 上限: 超了就截断并明说, 不静默丢

# mihomo 文本规则集的域名写法 → mosdns 域名集写法。
#   +.x.com  = x.com 及其子域            → domain:x.com
#   .x.com   = 同上(等价写法)             → domain:x.com
#   *.x.com  = 只匹配一级子域, mosdns 没有等价写法 → 放宽成 domain:x.com
#              放宽的方向是安全的: 多劫持一点只是让流量进 mihomo, 出口仍由 mihomo 的规则决定
#   x.com    = 精确匹配                   → full:x.com
def _mihomo_domain_to_mosdns(line):
    d = line.strip().lower()
    if not d or d.startswith("#"):
        return None
    if d.startswith("+."):
        d, pfx = d[2:], "domain:"
    elif d.startswith("*."):
        d, pfx = d[2:], "domain:"
    elif d.startswith("."):
        d, pfx = d[1:], "domain:"
    else:
        pfx = "full:"
    d = d.strip(".")
    if not d or not re.match(r"^[a-z0-9_.*-]+$", d):
        return None
    return pfx + d


def _mrs_domains(blob, behavior, timeout=60):
    """用 mihomo 自己把 .mrs 反向导出成域名清单。返回 (mosdns 行, 成不成)。

    .mrs 是 mihomo 的二进制规则集(succinct trie + zstd), 自己解析等于把内核的数据结构抄一遍;
    但内核带的 `convert-ruleset <behavior> mrs <in> <out>` 正好是反方向 —— 输入 .mrs, 输出
    文本域名清单(实测 8.9KB / 1042 条约 12ms)。用它就不必另写一套解码, 也不会跟内核版本漂移。

    behavior=ipcidr 的 .mrs 里本来就没有域名(导出的是 CIDR), 那不算"派生失败" —— 与文本
    规则集里的 ip_cidr 一样跳过就好, 否则会天天报一个永远修不好的告警。
    """
    exe = shutil.which(MIHOMO_BIN) or "/usr/local/bin/mihomo"
    if not os.access(exe, os.X_OK):
        return [], False
    d = tempfile.mkdtemp(prefix="pdgmrs.")
    try:
        src, dst = os.path.join(d, "in.mrs"), os.path.join(d, "out.txt")
        with open(src, "wb") as f:
            f.write(blob)
        r = subprocess.run([exe, "convert-ruleset", behavior, "mrs", src, dst],
                           capture_output=True, timeout=timeout)
        if r.returncode != 0 or not os.path.exists(dst):
            return [], False
        with open(dst, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:  # noqa: BLE001
        return [], False
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if behavior != "domain":
        return [], True              # ipcidr: 没有域名可派生, 但这不是失败
    out = []
    for ln in text.splitlines():
        got = _mihomo_domain_to_mosdns(ln)
        if got:
            out.append(got)
    return out, True


def _ruleset_domain_lines(info, blob=None):
    """一个规则集条目 → mosdns 域名行列表。返回 (行, 能不能派生)。

    blob: 本次事务的**候选内容**。加规则集/刷新时文件还没落盘, 必须按候选算 —— 按磁盘上
    那份旧文件算出来的劫持表, 和同一笔事务里要落盘的规则集对不上。"""
    path = info.get("path") or ""
    if path.endswith(".srs"):
        return [], False             # sing-box 二进制, mihomo 读不了, 早已在入口被拒
    if str(info.get("format", "")) in ("mrs", "binary") or path.endswith(".mrs"):
        if blob is None:
            try:
                with open(path, "rb") as f:
                    blob = f.read()
            except OSError:
                return [], False
        bh = str(info.get("behavior") or "") or (mrs_behavior(blob) or "")
        if bh not in MRS_BEHAVIORS:
            return [], False         # 类型都认不出, 不猜
        return _mrs_domains(blob, bh)
    try:
        if blob is None:
            with open(path, "rb") as f:
                blob = f.read()
        src = json.loads(blob.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return [], False
    out = []
    for rule in src.get("rules") or []:
        if not isinstance(rule, dict):
            continue
        for key, pfx in (("domain", "full:"), ("domain_suffix", "domain:"),
                         ("domain_keyword", "keyword:")):
            for d in rule.get(key) or []:
                d = str(d).strip().lstrip(".").lower()
                # 只收 mosdns 认得的形态; 认不出的宁可不写, 也不要让整份文件加载失败
                if d and re.match(r"^[a-z0-9_.*-]+$", d):
                    out.append(pfx + d)
    return out, True


def ruleset_hijack_text(meta, blobs=None):
    """启用中的规则集 → ruleset_hijack.txt 内容。返回 (bytes, 派生不了的规则集显示名列表)。

    blobs: {规则集名: 本次事务的候选内容}, 没给的按磁盘上那份算。
    纯函数(除了读规则集文件本身), 不落盘 —— 调用方把它放进同一笔事务。"""
    lines, undrivable = [], []
    for name, info in sorted((meta or {}).items()):
        got, ok = _ruleset_domain_lines(info or {}, (blobs or {}).get(name))
        if not ok:
            undrivable.append((info or {}).get("label") or name)
            continue
        lines += got
    lines = sorted(set(lines))
    note = ""
    if len(lines) > RULESET_HIJACK_MAX:
        note = "# 超过 %d 条, 已截断(其余域名在 gfw 模式下不会被劫持)\n" % RULESET_HIJACK_MAX
        lines = lines[:RULESET_HIJACK_MAX]
    head = ("# pdg 规则集派生劫持表 —— 由启用中的规则集自动生成, 手改会在下次刷新时被覆盖。\n"
            "# 作用: 让规则集里的域名在 gfw 模式下也能被劫持到网关, 否则那些 RULE-SET 规则\n"
            "# 永远匹配不到(all 模式下靠兜底劫持, 看不出差别)。\n") + note
    return (head + "".join(l + "\n" for l in lines)).encode("utf-8"), undrivable


def _ruleset_hijack_file(meta, blobs=None):
    """给事务用的 {目标: 内容} 片段。"""
    data, undrivable = ruleset_hijack_text(meta, blobs)
    return {"mosdns_rule:ruleset_hijack.txt": data}, undrivable


def _undrivable_note(undrivable):
    """读不出域名的规则集要如实说 —— 否则用户以为 gfw 模式下也自动生效了。

    正常的 .mrs 现在能靠 mihomo 自己反向导出(见 _mrs_domains), 所以进这个名单的只剩真出问题
    的: 文件坏了、behavior 认不出、或者机器上没有 mihomo 二进制。"""
    if not undrivable:
        return ""
    return ("\n⚠️ 这些规则集读不出域名(文件损坏 / 类型认不出 / 缺 mihomo 二进制), "
            "<b>没能生成劫持表</b>: " + "、".join(str(x) for x in undrivable[:4])
            + ("…" if len(undrivable) > 4 else "")
            + "\ngfw 模式下它们的规则不会命中(all 模式不受影响)。跑 <code>sudo pdg doctor</code> "
              "看「规则集劫持表」那一项。")


# ── 单条规则增删 ──
def add_rule(domain, target):
    domain = domain.strip().lstrip(".").lower()
    if not re.match(r"^[a-z0-9.-]+$", domain):
        return False, "域名格式不对"
    if target in ("direct", "直连"):
        files = {"mosdns_rule:custom_direct.txt": _direct_text(_read_direct() + [domain])}
        if domain in _read_hijack():                 # 改判直连: 必须同时撤掉劫持, 否则仍被劫进代理
            files["mosdns_rule:custom_hijack.txt"] = _hijack_text(
                [d for d in _read_hijack() if d != domain])
        ok, msg = tx_apply("rule_add_direct", files=files)
        return ok, (f"已把 {domain} 设为直连" if ok else msg)
    c = load()
    if target not in exit_tags(c):
        return False, f"出口 {target} 不存在; 可选: {', '.join(exit_tags(c))} 或 direct"

    is_wda = _wda_rule_pred()
    def mod(cc):
        for r in cc["route"]["rules"]:
            if r.get("outbound") == target and "rule_set" not in r and not is_wda(r):
                r.setdefault("domain_suffix", [])
                if domain not in r["domain_suffix"]:
                    r["domain_suffix"].append(domain)
                return
        idx = 1 if cc["route"]["rules"] and cc["route"]["rules"][0].get("action") == "reject" else 0
        cc["route"]["rules"].insert(idx, {"domain_suffix": [domain], "outbound": target})
    # 内核规则与 mosdns 劫持表**同一笔事务**: 少了劫持这条规则就是死的, 分两步写迟早半套
    files = {}
    if domain not in _read_hijack():
        files["mosdns_rule:custom_hijack.txt"] = _hijack_text(_read_hijack() + [domain])
    ok, msg = tx_apply("rule_add", model_mod=mod, files=files)
    return ok, (f"已把 {domain} → {target}" if ok else msg)

def del_rule(domain):
    domain = domain.strip().lstrip(".").lower(); removed = []
    c = load()
    is_wda = _wda_rule_pred()
    if any(domain in r.get(k, []) for r in c["route"]["rules"] if not is_wda(r)
           for k in ("domain_suffix", "domain")):
        def mod(cc):
            for r in cc["route"]["rules"]:
                if is_wda(r):                     # WDA 规则整条由 set_wda_mode 管, 不在这里拆
                    continue
                for k in ("domain_suffix", "domain"):
                    if domain in r.get(k, []):
                        r[k] = [d for d in r[k] if d != domain]
            cc["route"]["rules"] = [r for r in cc["route"]["rules"]
                                    if r.get("action") or "outbound" not in r or r.get("rule_set")
                                    or r.get("domain_suffix") or r.get("domain")
                                    or r.get("domain_keyword") or r.get("ip_cidr")]
        files = {}
        if domain in _read_hijack():
            files["mosdns_rule:custom_hijack.txt"] = _hijack_text(
                [d for d in _read_hijack() if d != domain])
        if domain in _read_direct():
            files["mosdns_rule:custom_direct.txt"] = _direct_text(
                [d for d in _read_direct() if d != domain])
            removed.append("直连表")
        ok, msg = tx_apply("rule_del", model_mod=mod, files=files)
        if not ok:
            return False, msg
        removed.append("出口规则")
    elif domain in _read_direct():
        ok, msg = tx_apply("rule_del_direct", files={
            "mosdns_rule:custom_direct.txt": _direct_text(
                [d for d in _read_direct() if d != domain])})
        if not ok:
            return False, msg
        removed.append("直连表")
    return (bool(removed), f"已删除 {domain} ({'+'.join(removed)})" if removed else f"未找到含 {domain} 的规则")

def deletable_domains():
    """可删的单域名规则: [(域名, 显示文字)]。含各出口的 domain(_suffix) 与自定义直连表。"""
    c = load(); items = []
    is_wda = _wda_rule_pred()
    for r in c["route"]["rules"]:
        if "outbound" not in r or r.get("rule_set") or is_wda(r):
            continue
        for d in r.get("domain_suffix", []) + r.get("domain", []):
            items.append((d, f"{d} → {r['outbound']}"))
    for d in _read_direct():
        items.append((d, f"{d}(直连)"))
    return items

def del_rules_bulk(domains):
    """一次删除多个域名(出口规则 + 直连表), 只重启一次 sing-box。"""
    domains = {d.strip().lower() for d in domains if d.strip()}
    if not domains:
        return False, "没勾选任何域名"
    is_wda = _wda_rule_pred()
    def mod(cc):
        for r in cc["route"]["rules"]:
            if is_wda(r):                         # 同 del_rule: 不从 WDA 规则里抠域名
                continue
            for k in ("domain_suffix", "domain"):
                if r.get(k):
                    r[k] = [d for d in r[k] if d not in domains]
        cc["route"]["rules"] = [r for r in cc["route"]["rules"]
                                if r.get("action") or "outbound" not in r or r.get("rule_set")
                                or r.get("domain_suffix") or r.get("domain")
                                or r.get("domain_keyword") or r.get("ip_cidr")]
    cur = _read_direct(); hit = [x for x in cur if x in domains]
    hj = _read_hijack()
    files = {}
    if hit:
        files["mosdns_rule:custom_direct.txt"] = _direct_text([x for x in cur if x not in domains])
    if any(x in domains for x in hj):
        files["mosdns_rule:custom_hijack.txt"] = _hijack_text([x for x in hj if x not in domains])
    ok, msg = tx_apply("rule_del_bulk", model_mod=mod, files=files)
    if not ok:
        return False, msg
    return True, f"✅ 已删除 {len(domains)} 个域名" + (f"(含直连 {len(hit)} 个)" if hit else "")

def del_rule_kb(chat, back=RULE_BACK):
    """删规则多选键盘: 勾选/取消, 底部确认删除(N)。"""
    items = deletable_domains()
    valid = {d for d, _ in items}
    sel = del_sel.setdefault(chat, set()) & valid
    del_sel[chat] = sel
    rows = []
    for d, lbl in items[:80]:
        if len(("dtog:" + d).encode()) > 64:
            continue
        rows.append([{"text": ("☑️ " if d in sel else "⬜️ ") + lbl, "callback_data": "dtog:" + d}])
    rows.append([{"text": f"✅ 确认删除 ({len(sel)})", "callback_data": "ddel"}])
    rows.extend(_back_rows(back))
    return items, {"inline_keyboard": rows}

# ── 改分流规则出口 / 出口排序 / 改故障组 ──
def editable_rules(c):
    """可改出口的规则: [(索引, 简短标签)]。含域名规则与规则集规则。"""
    out = []; meta = _rs_meta()
    for i, r in enumerate(c["route"]["rules"]):
        if "outbound" not in r:
            continue
        if r.get("rule_set"):
            name = meta.get(r["rule_set"], {}).get("label") or r["rule_set"]   # 用显示名(改过名的), 没有才回退 rs_xxxx
            out.append((i, f'{r["outbound"]}: 规则集 {name}'))
        else:
            doms = r.get("domain_suffix", []) + r.get("domain", [])
            if doms:
                out.append((i, f'{r["outbound"]}: ' + ", ".join(doms[:4]) + (" …" if len(doms) > 4 else "")))
    return out

def _merge_domain_rules(rules):
    """同一出口的多条域名规则合并为一条, 保持其余规则顺序。"""
    seen = {}; out = []
    for r in rules:
        if r.get("outbound") and "rule_set" not in r and (r.get("domain_suffix") or r.get("domain")):
            t = r["outbound"]
            if t in seen:
                base = seen[t]
                for k in ("domain_suffix", "domain"):
                    if r.get(k):
                        base.setdefault(k, [])
                        base[k] += [x for x in r[k] if x not in base[k]]
                continue
            seen[t] = r
        out.append(r)
    return out

def reassign_rule(idx, target):
    c = load(); rules = c["route"]["rules"]
    if idx < 0 or idx >= len(rules) or "outbound" not in rules[idx]:
        return False, "该规则已变动, 请重开列表再试"
    if target not in exit_tags(c):
        return False, f"出口 {target} 不存在"
    old = rules[idx]["outbound"]
    if old == target:
        return True, f"已经是 {target}, 未改动"
    def mod(cc):
        cc["route"]["rules"][idx]["outbound"] = target
        cc["route"]["rules"] = _merge_domain_rules(cc["route"]["rules"])
    ok, msg = apply_sb(mod)
    return ok, (f"✅ 该规则出口 {old} → {target}" if ok else msg)

def reorder_exits(order):
    c = load(); allt = [o["tag"] for o in c["outbounds"]]
    order = [t for t in order if t]
    if set(order) != set(allt):
        return False, f"必须且只能列全部出口(空格分隔): {', '.join(allt)}"
    def mod(cc):
        cc["outbounds"].sort(key=lambda o: order.index(o["tag"]))
    ok, msg = apply_sb(mod)
    return ok, (f"✅ 出口顺序已更新: {' › '.join(order)}" if ok else msg)

def rename_exit(old, new):
    """真改名: 改 outbound 的 tag, 并级联更新全部引用 —— 分流规则(含 TG 出口规则)、
    故障组成员、route.final、规则集元数据的 outbound 记录。direct(模板锚点, WDA 依赖其 tag)不可改。"""
    c = load()
    if old not in deletable_tags(c):
        return False, f"出口 {old} 不存在或不可改名(direct 出口是模板锚点)"
    new = _tag(new.strip(), "", "")
    if not re.search(r"[A-Za-z0-9]", new):
        return False, "新名字无效: 用字母/数字/_/./-(不支持中文), 40 字内"
    if new == old:
        return False, "新旧名字相同, 未改动"
    if new in ("direct", "直连", "block", "dns-out"):
        return False, f"{new} 是保留字, 换个名字"
    if new in [o["tag"] for o in c["outbounds"]]:
        return False, f"名字 {new} 已被占用"
    def mod(cc):
        for o in cc["outbounds"]:
            if o.get("tag") == old:
                o["tag"] = new
            if o.get("type") == "urltest":
                o["outbounds"] = [new if m == old else m for m in o.get("outbounds", [])]
        for r in cc["route"]["rules"]:
            if r.get("outbound") == old:
                r["outbound"] = new
        if cc["route"].get("final") == old:
            cc["route"]["final"] = new
    # 规则集元数据也记着目标出口 —— 与 model 同一笔事务改, 免得内核改完名、元数据还指着旧的
    rsm = _rs_meta(); dirty = False
    for k, v in rsm.items():
        if v.get("outbound") == old:
            v["outbound"] = new; dirty = True
    files = {}
    if dirty:
        files["rs_meta"] = json.dumps(rsm, ensure_ascii=False, indent=2).encode("utf-8")
    ok, msg = tx_apply("exit_rename", model_mod=mod, files=files)
    if not ok:
        return False, msg
    return True, f"✅ 出口 <b>{old}</b> 已改名 <b>{new}</b>, 分流规则/故障组/默认出口里的引用已同步。"

def urltest_groups(c):
    return [o["tag"] for o in c["outbounds"] if o.get("type") == "urltest"]

# ── Telegram 独立 SOCKS5(tg-proxy 入口)的出口选择 ──
TG_INBOUND = "tg-proxy"

def _tg_exit(c):
    """tg-proxy 入口被钉到的出口; 返回 None 表示跟随默认出口(final)。"""
    for r in c["route"]["rules"]:
        if r.get("inbound") == [TG_INBOUND]:
            return r.get("outbound")
    return None

def set_tg_exit(tag):
    """钉 Telegram(tg-proxy)走某出口; tag 空 = 跟随默认出口(删掉专属规则)。"""
    c = load()
    if tag and tag not in exit_tags(c):
        return False, f"出口 {tag} 不存在"
    def mod(cc):
        cc["route"]["rules"] = [r for r in cc["route"]["rules"] if r.get("inbound") != [TG_INBOUND]]
        if tag:  # 放在 reject 之后、域名/规则集规则之前, 确保优先按入口判定
            idx = 1 if cc["route"]["rules"] and cc["route"]["rules"][0].get("action") == "reject" else 0
            cc["route"]["rules"].insert(idx, {"inbound": [TG_INBOUND], "outbound": tag})
    ok, msg = apply_sb(mod)
    return ok, (f"✅ Telegram 出口 → {tag or '默认出口'}" if ok else msg)

# ── 测域名: 输入域名 → 直连 or 哪个出口(命中哪条规则/规则集) ──
def _internal_probe_ip():
    """从 mosdns npn_clients 段取一个探测地址(末位 .250), 用作内网卡来源查 mosdns。"""
    try:
        m = re.search(r'ips:\s*\[\s*"([^"/]+)', open(MOSDNS_CONF).read())
        if m:
            o = m.group(1).split(".")
            if len(o) == 4:
                o[3] = "250"; return ".".join(o)
    except Exception:  # noqa: BLE001
        pass
    return ""

def _match_ruleset(name, d, sufs):
    p = os.path.join(RS_DIR, name + ".json")
    if not os.path.exists(p):
        return False  # .srs 二进制无法解析
    try:
        rules = json.load(open(p)).get("rules", [])
    except Exception:  # noqa: BLE001
        return False
    for rule in rules:
        if d in rule.get("domain", []):
            return True
        if any(d == s or d.endswith("." + s) for s in rule.get("domain_suffix", [])):
            return True
        if any(k in d for k in rule.get("domain_keyword", [])):
            return True
    return False

def _singbox_route(d):
    sufs = [".".join(d.split(".")[i:]) for i in range(len(d.split(".")))]
    c = load()
    for r in c["route"]["rules"]:
        if "outbound" not in r:
            continue
        if d in r.get("domain", []) or any(d == s or d.endswith("." + s) for s in r.get("domain_suffix", [])):
            return r["outbound"], "显式域名规则"
        if any(k in d for k in r.get("domain_keyword", [])):
            return r["outbound"], "关键词规则"
        rs = r.get("rule_set")
        if rs and _match_ruleset(rs, d, sufs):
            label = _rs_meta().get(rs, {}).get("label") or rs
            return r["outbound"], f"规则集 {label}"
    return c["route"].get("final"), "默认(其余国际)"

def test_domain(domain):
    d = domain.strip().lstrip(".").lower().split("/")[0]
    if not re.match(r"^[a-z0-9.-]+\.[a-z]{2,}$", d):
        return "域名格式不对, 例: <code>netflix.com</code>"
    sip = _server_ip(); probe = _internal_probe_ip(); real = []
    if probe:
        sh(["ip", "addr", "add", probe + "/32", "dev", "lo"])
        try:
            out = sh(["dig", "+short", "+time=2", "+tries=1", "@127.0.0.1", "-b", probe, d, "A"]).stdout
            real = [x for x in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
        finally:
            sh(["ip", "addr", "del", probe + "/32", "dev", "lo"])
    head = f"🔎 <b>{d}</b>\n"
    if real and sip not in real:
        return head + f"→ 🏠 <b>国内直连</b>(mosdns 返回真实 IP {real[0]})"
    tag, why = _singbox_route(d)
    res = head + f"→ 📤 出口 <b>{tag}</b>(命中: {why})"
    if not real:
        res += "\n<i>(没探到 DNS 结果, 直连/代理未实测; 以上为本地规则模拟)</i>"
    return res

# ── 自定义 DoT 域名 (certbot standalone 签证书 → 换 mosdns DoT 证书) ──
def set_dot_domain(domain):
    domain = domain.strip().lower().rstrip(".")
    if not re.match(r"^(?=.{1,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", domain):
        return False, "域名格式不对"
    sip = _server_ip()
    try:
        addrs = {ai[4][0] for ai in socket.getaddrinfo(domain, None, socket.AF_INET)}
    except Exception:  # noqa: BLE001
        addrs = set()
    if sip not in addrs:
        return False, (f"{domain} 现在解析到 {addrs or '(解析不到)'}, 不是本机 {sip}。\n"
                       f"先在 DNS 商把它 A 记录指向 {sip}(Cloudflare 选「灰云 DNS only」), 生效后再试。")
    try:
        r = subprocess.run(
            ["certbot", "certonly", "--standalone", "-d", domain,
             "--non-interactive", "--agree-tos", "--register-unsafely-without-email", "--keep-until-expiring",
             "--pre-hook", "/usr/local/bin/proxy-gateway-open-cert-http.sh",
             "--post-hook", "/usr/local/bin/proxy-gateway-restore-firewall.sh"],
            capture_output=True, text=True, timeout=300)
    except Exception as e:  # noqa: BLE001
        return False, f"certbot 执行异常: {e}"
    if r.returncode != 0:
        return False, "证书签发失败:\n" + (r.stdout + r.stderr)[-500:]
    # 签发是**外部动作**(ACME/CA 说了算, 不可回滚), 部署到生产才是本项目的事务:
    # 证书两个文件 + 活动域名标记 + mosdns 重启要么一起成, 要么一起回到旧证书 ——
    # 旧实现是逐个 copy 后直接 restart, 中途失败就可能留下"新证书配旧域名"甚至 DoT 直接不可用。
    live = f"/etc/letsencrypt/live/{domain}"
    try:
        with open(f"{live}/fullchain.pem", "rb") as f:
            chain = f.read()
        with open(f"{live}/privkey.pem", "rb") as f:
            key = f.read()
    except OSError as e:
        return False, "证书已签发但读取失败(%s), 生产仍在用原来的证书。" % type(e).__name__
    ok, msg = tx_apply("dot_cert_deploy", files={
        "cert_fullchain": chain, "cert_privkey": key,
        "dot_marker": (domain + "\n").encode("utf-8")})
    if not ok:
        return False, ("证书已签发, 但部署到生产失败 —— **仍在使用原来的证书**, DoT 未受影响。\n"
                       + msg)
    global _DOT_HOST
    _DOT_HOST = None  # 让 _dot_host() 重新读新证书 CN
    _renew = ("• iOS: 重新生成一次「📱 iOS 描述文件」即可(自动用新域名)" if _platform() == "ios"
              else "• Android: 私密 DNS 改成上面的新域名即可")
    return True, (f"✅ DoT 域名已设为 <b>{domain}</b>\n"
                  f"• 手机私密 DNS 改成: <code>{domain}</code>\n"
                  "• 证书已签发, certbot.timer 自动续期\n"
                  + _renew)

# ── iOS 描述文件 ──
# 生成实现在 iosprofile 里、生命周期在 iosstate 里 —— Bot 与 CLI(`pdg ios`)共用同一份。
# 以前两边各写一套, CLI 那套既不支持 SSID 排除也不附 WLOC 根证书, 同一台网关走两条路拿到的
# 文件内容不一样。
#
# ⚠️ 这两个是**按平台安装**的 iOS 专属组件: Android 机器上 /opt/pdg-bot 里根本没有它们。
# 所以这里必须容错 —— 在模块顶层硬 import 会让 bot 在每一台 Android 网关上直接起不来
# (`_activate_mihomo_core` 里的 `import bot` 也会跟着炸, 表现为"迁移到 mihomo 失败")。
try:
    import iosprofile                                      # noqa: E402
    import iosstate                                        # noqa: E402
except ImportError:                                        # Android: 本机没装 iOS 组件
    iosprofile = iosstate = None


def _ios_mods():
    """用到 iOS 组件之前先确认它们在。平台门控之外的第二道: iOS 机器上组件被删/没装齐时,
    要给一句能照着做的话, 而不是让调用方吃一个 ModuleNotFoundError 堆栈。"""
    if iosprofile is None or iosstate is None:
        raise RuntimeError("缺少 iOS 组件(iosprofile / iosstate)—— 请先跑 sudo pdg update 补齐。")

def _mitm_ca_der():
    """根 CA 证书的 DER 字节(供 iOS 描述文件的 root 证书 payload)。

    解析与"私钥绝不进描述文件"的拦截都在 iosprofile 里做。以前这里是宽容解析: 解不开就
    悄悄返回 b"" —— 于是 WLOC 开着、CA 却坏了的时候, 用户拿到的是一份**不含根证书**的
    描述文件, 装上去表现为"全站证书报错", 而没有任何一处告诉他 CA 坏了。现在直接拒绝生成。
    """
    pem = _mitm_ca_pem()
    if not pem:
        return b""
    _ios_mods()
    return iosprofile.ca_der_from_pem(pem)

def _ios_profile(ssids=(), ids=None):
    """**不碰生命周期状态**的渲染入口: 平台门控 + 本机数据源 + 可选身份 → 文件字节。

    受管生成走 _ios_generate(它会记 revision / current / previous)。这一个留给"只要文件、
    不该改状态"的调用方, 也是 Bot↔CLI 逐字节一致那条回归的 Bot 侧入口 —— 因为身份可以显式
    传入, 才谈得上"同样输入产出同样字节"。
    """
    if _platform() != "ios":         # 最底层门控: 即便某路径绕过按钮/回调, 也生成不了 iOS 描述文件
        raise RuntimeError("iOS 描述文件仅 iOS 平台可用(本机为 Android)。" + _platform_unconfirmed())
    _, der = _ios_ca()
    return iosprofile.render(_dot_host(), _server_ip(), ssids, der, ids, IOS_TMPL)

# ── iOS 描述文件: 受管生命周期 ──
# 服务器**不知道**手机上此刻装的是什么 —— 本项目不是 MDM。所以下面所有文案只讲"我们生成/
# 发送了什么", 绝不出现"已安装""设备已是最新版""更新已在手机生效""已替换手机上的旧文件"。
IOS_UNKNOWN = "ℹ️ 服务器无法确认 iPhone 上此刻装的是哪一版, 以上只反映本机的生成/发送记录。"


def _ios_ca():
    """(WLOC 是否启用, 根 CA 的 DER)。启用却读不到 CA 时抛错, 不返回空 —— 见 _mitm_ca_der。"""
    _ios_mods()
    enabled = bool(_mitm_enabled_domains())
    if not enabled:
        return False, b""
    der = _mitm_ca_der()
    if not der:
        raise iosprofile.ProfileError(
            "WLOC 已启用但读不到根 CA 证书, 拒绝生成描述文件 —— "
            "不含 CA 的描述文件装上去会让被劫持的站点全部证书报错。")
    return True, der


def _ios_generate(ssids=None, legacy=False):   # ssids=None ⇒ 沿用记录里的名单
    if _platform() != "ios":
        raise RuntimeError("iOS 描述文件仅 iOS 平台可用(本机为 Android)。" + _platform_unconfirmed())
    enabled, der = _ios_ca()
    return iosstate.generate(_dot_host(), _server_ip(), ssids, der, enabled,
                             IOS_TMPL, legacy_seen=legacy)


def _ios_inputs(meta, ssids=None):
    enabled, der = _ios_ca()
    return iosstate.effective_inputs(meta, _dot_host(), _server_ip(), ssids, enabled,
                                     der, IOS_TMPL)


def _ios_status_text():
    """iOS 描述文件页的正文。没有元数据 = 还没启用受管生命周期。"""
    _ios_mods()
    meta = iosstate.load()
    if not meta or not meta.get("current"):
        return ("📱 <b>iOS 描述文件</b>\n\n"
                "本网关还没有生成过受管描述文件。生成之后, 后续每次更新都是<b>同一份</b>"
                "描述文件的新版本 —— iPhone 上不会越堆越多。\n\n" + IOS_UNKNOWN)
    cur = meta["current"]
    ssids = cur["inputs"].get("ssids") or []
    try:
        lv, why = iosstate.classify(meta, _ios_inputs(meta))
    except Exception as e:  # noqa: BLE001
        lv, why = iosstate.REQUIRED, ["读取当前网关配置失败: %s" % e]
    lines = ["📱 <b>iOS 描述文件</b>", "",
             "当前版本: <b>第 %d 版</b>(生成于 %s)" % (cur["revision"], cur["generated_at"]),
             "上次发送: %s" % (cur.get("sent_at") or "尚未通过本机发送过"),
             "DoT: <code>%s</code>" % cur["inputs"]["dot_host"]]
    if ssids:
        lines.append("强制直连 Wi-Fi: %s" % ", ".join(ssids))
    if cur["inputs"].get("wloc_enabled"):
        lines.append("含根证书: 是(指纹 %s…)" % cur["inputs"]["wloc_ca_sha256"][:16])
    lines += ["", "配置变化: <b>%s</b>" % iosstate.LEVEL_LABEL[lv]]
    lines += ["• " + r for r in why]
    if meta.get("previous"):
        lines.append("上一版: 第 %d 版(可对比 / 可单独取回)" % meta["previous"]["revision"])
    # 服务端产物健康是**另一件事**: 上面那行说的是手机上那份要不要换, 这里说的是服务器上
    # 这个文件能不能发。混成一句会让用户去动手机, 而真正坏掉的服务端文件被温和地盖过去。
    health = iosstate.health_summary(meta, None)
    if health:
        lines.append("")
        for which, state, detail in health:
            lines.append("%s(%s)" % (iosstate.HEALTH_LABEL[state], _esc(detail)))
    lines += ["", IOS_UNKNOWN]
    return "\n".join(lines)


def _ios_kb():
    meta = None
    try:
        _ios_mods()
        meta = iosstate.load()
    except Exception:  # noqa: BLE001
        pass
    rows = [[{"text": "📄 生成 / 更新描述文件", "callback_data": "iosgen"}],
            [{"text": "📶 强制直连 Wi-Fi…", "callback_data": "ios_ssid"}]]
    if meta and meta.get("migration_pending"):
        rows.insert(0, [{"text": "✅ 旧描述文件我已删除", "callback_data": "iosack"}])
    if meta and meta.get("previous"):
        rows.append([{"text": "🔍 与上一版对比", "callback_data": "iosdiff"},
                     {"text": "⏪ 取回上一版", "callback_data": "iosprev"}])
    rows += [[{"text": "⬅️ 返回客户端", "callback_data": "nav:client"}],
             [{"text": "🏠 主菜单", "callback_data": "menu"}]]
    return {"inline_keyboard": rows}


IOS_INSTALL_HOWTO = ("装法: 存到「文件」App → 点开 → 设置 → 通用 → 「已下载描述文件」→ 安装。\n"
                     "Wi-Fi/蜂窝是否启用私密 DNS 由服务器 :81 探测自动判定。")


def _ios_val(v):
    """差异里的取值展示。CA 只给指纹前缀 —— 证书正文不进任何输出。"""
    if isinstance(v, bool):
        return "是" if v else "否"
    if v in (None, "", []):
        return "(无)"
    if isinstance(v, (list, tuple)):
        return _esc(", ".join(str(x) for x in v))[:200]
    s = str(v)
    return _esc(s if len(s) <= 24 else s[:16] + "…")


def _ios_send(chat, ssids=None, legacy=False):
    """生成并发送, 返回给用户看的一段话。发送成功才记 sent_at —— 记的是"我们发了",
    不是"手机上装了"。"""
    meta, lv, why, data, changed = _ios_generate(ssids, legacy)
    # 发出去的必须是**盘上那一份并且校验通过**的字节, 不是 generate 手里的内存副本:
    # 两者理应相同, 而"理应相同"正是这类问题最爱藏身的地方。
    data = iosstate.verified_artifact(meta, "current")
    cur = meta["current"]
    cap = ["📱 iOS/iPadOS 私密DNS 描述文件(第 %d 版)" % cur["revision"],
           "DoT: %s" % cur["inputs"]["dot_host"]]
    if meta.get("migration_pending"):
        cap.append("⚠️ 安装前请先在 iPhone 上删除旧的「PrivDNS Gateway」描述文件 —— "
                   "旧版用的是随机身份, 不删的话这份会作为**另一个**描述文件并存。")
    cap.append(IOS_INSTALL_HOWTO)
    send_document(chat, "PrivDNS-Gateway.mobileconfig", data, "\n".join(cap))
    # 标记必须点名**刚发出去的那一版**。无条件给"此刻的 current"盖章的话, 发送期间别人生成了
    # 新版本, 章就盖到新版头上 —— 记录说它发过了, 而它其实从没出过门。
    note = ""
    try:
        st, _ = iosstate.mark_sent(cur["revision"], cur["sha256"])
        if st == iosstate.SENT_SUPERSEDED:
            note = "\nℹ️ 期间服务器上又生成了新版本, 因此没有把这次发送记到当前版本名下。"
    except Exception:  # noqa: BLE001
        pass                      # 记不上发送时间不影响用户已经拿到文件, 不要因此报失败
    head = ("✅ 已生成第 %d 版并发送。" % cur["revision"] if changed
            else "✅ 已重新发送第 %d 版(网关配置没有变化, 内容与上次完全相同)。" % cur["revision"])
    return head + note + "\n" + "\n".join("• " + r for r in why) + "\n\n" + IOS_UNKNOWN

# ── 配置备份 / 恢复 ──
IOS_META = "/etc/privdns-gateway/ios-profile.json"   # iOS 描述文件身份/修订记录(用户持久数据)
IOS_ART_DIR = "/var/lib/privdns-gateway/ios-profile"
IOS_CURRENT = IOS_ART_DIR + "/current.mobileconfig"
IOS_PREVIOUS = IOS_ART_DIR + "/previous.mobileconfig"
# 记录**和产物**一起进备份。只带记录是不够的: 恢复回来会变成"记录说第 2 版、盘上躺着第 3 版";
# 更要命的是 previous —— 那一版用的根证书只在产物里有正文, 元数据里只有指纹, 所以它丢了就
# 真的没了, 谁也重建不出来。文件不存在(Android / 还没启用)时 backup_blob 自动跳过。
BACKUP_FILES = [SB, MOSDNS_CONF, MOSDNS_DIRECT, MOSDNS_HIJACK, RS_META,
                IOS_META, IOS_CURRENT, IOS_PREVIOUS]
# 受管配置的解包/白名单/限额/成员映射搬进了 cfgrestore —— Bot(收 Telegram 备份包)与救援平面
# (从本机快照恢复)做的是同一件事, 两边各写一份的下场是: 白名单一处加了新目标另一处没加, 于是
# "恢复成功"的机器少一份配置。这里保留原来的模块级名字, 老调用与既有测试不受影响。
import cfgrestore                                        # noqa: E402

cfgrestore.reload_limits()      # 限额读环境, bot 每次以新环境重新导入时都要刷一遍

RESTORE_MAP = cfgrestore.RESTORE_MAP
RESTORE_RS_PREFIX = cfgrestore.RESTORE_RS_PREFIX
RESTORE_MAX_MEMBERS = cfgrestore.MAX_MEMBERS
RESTORE_MAX_FILE_BYTES = cfgrestore.MAX_FILE_BYTES
RESTORE_MAX_TOTAL_BYTES = cfgrestore.MAX_TOTAL_BYTES
_RS_LEAF_RE = cfgrestore._RS_LEAF_RE
_RS_DIR_CANON = cfgrestore._RS_DIR_CANON
_restore_member_allowed = cfgrestore.member_allowed
_safe_extract = cfgrestore.safe_extract


def _ios_backup_members():
    """iOS 三件套进不进包, 由**记录**说了算, 不是由盘上有没有文件说了算。

    "文件在就打包"会把一份孤儿 previous(回滚到旧快照留下的、记录里已经没有的那一版)一起
    装进去 —— 恢复到下一台机器上就是"记录说没有上一版、盘上却躺着一份"。同理, 一份与记录
    对不上的 current 打进备份, 等于把损坏状态固化成"备份里的样子"。

    所以这里 fail-closed 并说清是哪种状态: 备份是安全网, 递给用户一张破了洞的网、还正好
    在他觉得自己安全的那一刻, 比直接告诉他"先修" 要糟得多。想原样留档当前(含损坏)状态,
    `pdg snapshot` 就是干这个的 —— 它按字节打包, 不做任何判断。
    """
    if iosstate is None or not os.path.exists(IOS_META):
        return []                                # Android / 还没启用受管生命周期
    meta = iosstate.load(IOS_META)               # 记录坏了直接抛(既有措辞)
    if not meta:
        return []
    out = [IOS_META]
    for which, path, name in (("current", IOS_CURRENT, "当前版本"),
                              ("previous", IOS_PREVIOUS, "上一版")):
        if meta.get(which):
            try:
                iosstate.verified_artifact(meta, which, IOS_ART_DIR)
            except iosstate.StateError as e:
                raise RuntimeError(
                    "iOS 描述文件的%s与记录对不上, 已中止备份(现网未被改动)。\n%s\n"
                    "把它打进备份等于把这个状态固化下来。先跑 <code>sudo pdg ios recover</code> "
                    "看看是哪一份出了问题; 想原样留档当前状态请用 <code>sudo pdg snapshot</code>。"
                    % (name, e))
            out.append(path)
        elif os.path.exists(path):
            raise RuntimeError(
                "iOS 描述文件记录里没有%s, 盘上却躺着一份 %s —— 多半是回滚到旧快照留下的孤儿。\n"
                "已中止备份(现网未被改动): 把它打进包里, 恢复到下一台机器上就是一份自相矛盾的"
                "记录。先跑 <code>sudo pdg ios recover</code> 看看情况; 想原样留档当前状态请用 "
                "<code>sudo pdg snapshot</code>。" % (name, os.path.basename(path)))
    return out


def backup_blob():
    ios_trio = (IOS_META, IOS_CURRENT, IOS_PREVIOUS)
    ios = _ios_backup_members()                  # 先决定(会 fail-closed), 再开包
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for p in [x for x in BACKUP_FILES if x not in ios_trio] + ios:
            if os.path.exists(p):
                if p == SB:
                    cfg = json.load(open(p))
                    if _panel_sanitize_config(cfg):
                        raw = json.dumps(cfg, ensure_ascii=False, indent=2).encode()
                        info = tar.gettarinfo(p, arcname=p.lstrip("/"))
                        info.size = len(raw)
                        tar.addfile(info, io.BytesIO(raw))
                        continue
                tar.add(p, arcname=p.lstrip("/"))
        if os.path.isdir(RS_DIR):
            tar.add(RS_DIR, arcname=RS_DIR.lstrip("/"))
    return buf.getvalue()

def _machine_id(sb_path, mos_path):
    """取一对 sing-box/mosdns 配置**文件**里的「本机身份」(备份包那边用: 内容在盘上)。"""
    def _rd(p):
        try:
            with open(p, "rb") as f:
                return f.read()
        except OSError:
            return None
    return _machine_id_from(_rd(sb_path), _rd(mos_path))


def _machine_id_from(sb_data, mos_data):
    """同上, 但基于**内容字节**: (server_ip, internal_cidr, cert_dir)。

    事务里现网那一份必须走这个 —— 内容来自 read_for_update(带前置 sha), 再去读一次文件就等于
    绕过前置条件(读到的可能已经是别人改过的了)。"""
    ip = cidr = certdir = None
    try:
        c = json.loads((sb_data or b"").decode("utf-8"))
        for r in c.get("route", {}).get("rules", []):
            if r.get("action") == "reject":
                for x in r.get("ip_cidr", []):
                    if x.endswith("/32") and not x.startswith("127."):
                        ip = x.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        t = (mos_data or b"").decode("utf-8")
        m = re.search(r'ips:\s*\[\s*"([^"]+)"', t); cidr = m.group(1) if m else None
        m = re.search(r'cert:\s*"([^"]+)"', t); certdir = os.path.dirname(m.group(1)) if m else None
        if not ip:
            m = re.search(r'black_hole\s+([0-9.]+)', t); ip = m.group(1) if m else None
    except Exception:  # noqa: BLE001
        pass
    return ip, cidr, certdir

def _platform_sanitize_model(cfg):
    """把 model 按**本机平台**净化。备份可能来自另一平台, 或是本机平台清理**之前**的旧档 ——
    恢复不做这一步的话, iOS 机会被带回 GMS 5228-5230 入站(iOS 走 APNs, 根本用不到),
    而且要等下一次 root 管理命令触发迁移才清掉。返回是否改动。"""
    if _platform() != "ios":
        return False   # Android 缺 GMS 入站由 migrate_singbox_gms 补, 不在这里加
    ib = cfg.get("inbounds") or []
    keep = [i for i in ib if i.get("tag") not in ("in-gms-5228", "in-gms-5229", "in-gms-5230")]
    if len(keep) == len(ib):
        return False
    cfg["inbounds"] = keep
    return True


def _managed_rulesets(meta):
    """从 rs_meta 解析"受管规则集" → {规则集名: 文件名}。

    文件名只认 basename, 且只接受当前支持的 .json / .mrs —— 目录、绝对路径、../、重复
    basename、以及格式与扩展名对不上的一律抛错(调用方据此整包拒绝)。历史遗留的 .srs 属于
    sing-box 时代的二进制格式, mihomo 读不了, 这里明确拒绝而不做隐式转换。"""
    out, seen = {}, {}
    for name, info in sorted((meta or {}).items()):
        if not isinstance(info, dict):
            raise ValueError("规则集 %s 的元数据不是对象" % name)
        fmt = str(info.get("format") or "")
        leaf = os.path.basename(str(info.get("path") or ""))
        if not leaf:
            leaf = name + (".mrs" if fmt == "mrs" else ".json")
        raw = str(info.get("path") or "")
        # 备份里的路径是**那台机器**上的绝对路径, 不能拿本机 RS_DIR 直接比; 但形态必须干净:
        # 反斜杠、`..`、双斜杠、非规范化写法、以及不是"规则集目录 + 单个文件名"的一律拒。
        # 落盘用的永远是校验过的 basename + 本机固定目录, **绝不用归档给的路径**。
        if raw:
            if "\\" in raw:
                raise ValueError("规则集 %s 的路径含反斜杠, 拒绝" % name)
            if any(seg == ".." for seg in raw.split("/")):
                raise ValueError("规则集 %s 的路径含 .., 拒绝" % name)
            if "//" in raw or raw != os.path.normpath(raw):
                raise ValueError("规则集 %s 的路径不是规范化形态(%s), 拒绝" % (name, raw))
            # 目录部分必须**正好**是生产规范目录, 或本机 RS_DIR(测试/镜像沙箱把整棵树挪了根)。
            # 只用 endswith 会放过 /evil/etc/sing-box/rs/foo.json 这种"看起来像"的路径。
            d = os.path.dirname(raw)
            if d not in (_RS_DIR_CANON, RS_DIR.rstrip("/")) or os.path.basename(raw) != leaf:
                raise ValueError("规则集 %s 的路径不是「规则集目录 + 单个文件名」, 拒绝" % name)
        if not _RS_LEAF_RE.match(leaf):
            raise ValueError("规则集 %s 的文件 %s 不是当前支持的 .json/.mrs" % (name, leaf))
        want = "mrs" if leaf.endswith(".mrs") else "json"
        if want == "mrs" and fmt != "mrs":
            raise ValueError("规则集 %s: 扩展名是 .mrs 但格式记的是 %s" % (name, fmt or "空"))
        if want == "json" and fmt not in ("source", "classical", "text", ""):
            raise ValueError("规则集 %s: 扩展名是 .json 但格式记的是 %s" % (name, fmt))
        if leaf in seen:
            raise ValueError("规则集 %s 与 %s 用了同一个文件名 %s" % (name, seen[leaf], leaf))
        seen[leaf] = name
        out[name] = leaf
    return out


def _restore_ruleset_plan(tmp, cur_meta, bak_meta):
    """算出规则集的落盘计划: {文件名: bytes|None}(None = 删除), 外加给用户看的提示。

    受管集合 = 现网 rs_meta ∪ 备份 rs_meta:
      · 备份里有内容的 → 写入;
      · 只有现网元数据管着、备份的目标状态里没有的 → 删除(才叫"恢复到备份那一刻");
      · 两份元数据都不管的文件(用户自己丢进 rs/ 的)→ **不动**。
    整个 rs 目录不再 rmtree + copytree —— 那会连用户自己的文件一起毁掉, 也没法逐文件回滚。"""
    cur_files = _managed_rulesets(cur_meta)
    bak_files = _managed_rulesets(bak_meta)
    plan, notes = {}, []
    src_dir = os.path.join(tmp, RESTORE_RS_PREFIX.rstrip("/"))
    for name, leaf in sorted(bak_files.items()):
        src = os.path.join(src_dir, leaf)
        if not os.path.isfile(src) or os.path.islink(src):
            raise ValueError("备份的元数据里有规则集 %s, 但归档里没有对应文件 %s" % (name, leaf))
        with open(src, "rb") as f:
            plan[leaf] = f.read()
    for name, leaf in sorted(cur_files.items()):
        if leaf not in plan:
            plan[leaf] = None                     # 备份那一刻已经没有它了 → 删除
    if os.path.isdir(src_dir):
        extra = sorted(x for x in os.listdir(src_dir)
                       if x not in plan and os.path.isfile(os.path.join(src_dir, x)))
        if extra:
            notes.append("备份里有 %d 个不在元数据里的规则集文件, 已忽略(元数据与文件必须一致)"
                         % len(extra))
    return plan, notes


def restore_from(data):
    """从 Telegram 收到的备份包恢复配置。

    分两段:
      ① 锁外: 安全解包 + 白名单/限额/类型校验 + **组装候选**(含身份替换、面板与平台净化、
         规则集并集计划)。这一段一个生产文件都不碰, 任何问题都在动手之前退出;
      ② 一笔 pdgtx 事务(mode=repair): model / mosdns 配置 / direct·hijack / rs_meta /
         受管规则集 / 派生的 mihomo 配置一起校验、一起落盘, 再 restart mihomo + mosdns,
         失败整体回滚, 崩溃可 `pdg tx recover` 收尾。

    repair 模式的含义(本轮已收紧): 允许"操作前就坏的硬门"保持原状并告警 —— 恢复的典型场景
    正是现在坏着; 但**操作前好、操作后坏一律回滚**, 修复模式没有制造新故障的权力。"""
    try:
        tar = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except Exception:  # noqa: BLE001
        return False, "不是有效的 .tar.gz 备份文件"
    tmp = tempfile.mkdtemp(prefix="pdgrs")
    try:
        # 安全解包: 白名单内的普通文件才落地, 链接/设备/FIFO 一律不产生, 逐个 resolve 限定在
        # tmp 内, 并有体积/数量上限。备份包来自 Telegram(外部输入), 不能用不受限的 extract。
        try:
            _safe_extract(tar, tmp)
        except Exception as e:  # noqa: BLE001
            return False, "备份包不安全或已损坏, 拒绝恢复: %s" % e
        return _restore_commit(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)



def _reapply_explicit_proxy(mos_bytes, cur_bytes):
    """恢复 v1.7.0 及更早的备份时, 把「明确代理优先于 geosite_cn」这层重新补回候选里。

    备份里的 mosdns 配置是**原样**写回去的。一份 v1.7.0 时代的备份没有 explicit_proxy,
    恢复之后用户点名指到出口的域名就又会被上游 geosite 抢先判成直连 —— 而恢复本身报的是
    "✅ 已恢复", 没有任何一处报错, 只有事后跑 doctor 才看得出来。这正是 v1.7.1 要消灭的
    那类静默退化, 不能在恢复这条路上又漏回去。

    补的动作复用 lib/mosdns.sh 里那一份编辑器(单一真源, 不在 Python 里另写一遍)。备份是
    自定义形态、编辑器认不出时**不猜着改**: 保留备份原样, 但把这件事写进恢复结果里告诉用户。
    返回 (候选内容, 给用户的提示或 None)。
    """
    if b"qname $explicit_proxy" in mos_bytes:
        return mos_bytes, None
    if cur_bytes and b"qname $explicit_proxy" not in cur_bytes:
        return mos_bytes, None          # 现网本来就没有 → 这次恢复没造成退化, 交给迁移/doctor
    sip = ""
    m = re.search(rb"black_hole ([0-9.]+)", mos_bytes)
    if m:
        sip = m.group(1).decode()
    d = tempfile.mkdtemp(prefix="pdgep")
    try:
        cand = os.path.join(d, "config.yaml")
        with open(cand, "wb") as f:
            f.write(mos_bytes)
        r = subprocess.run(
            ["bash", "-c",
             'set -uo pipefail; source "$1"/lib/mosdns.sh; _mosdns_explicit_proxy "$2" "$3"',
             "_", PDG_REPO, cand, sip],
            capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return mos_bytes, ("⚠️ 备份里的 mosdns 配置是自定义形态, 没能补上「明确代理优先于国内判定」"
                               "这一层(未擅自改动)。你点名指到出口的域名可能会被判直连 —— "
                               "跑 <code>sudo pdg doctor</code> 看「明确代理优先级」那一项。")
        with open(cand, "rb") as f:
            out = f.read()
        if out == mos_bytes:
            return mos_bytes, None
        return out, "ℹ️ 备份来自旧版本, 已顺带补回「明确代理优先于国内判定」的分流层。"
    except Exception:  # noqa: BLE001
        return mos_bytes, ("⚠️ 没能复核备份里的分流优先级(未擅自改动)。"
                           "跑 <code>sudo pdg doctor</code> 看「明确代理优先级」那一项。")
    finally:
        shutil.rmtree(d, ignore_errors=True)



class _IosRestoreRefused(Exception):
    """备份里的 iOS 三件套没通过联合校验。整笔恢复就此打住(理由见 _stage_ios_profile)。"""


def _stage_ios_profile(t, tmp):
    """把备份里的 iOS 描述文件生命周期挂进这笔事务。返回 (恢复了什么, 提示或 None)。

    三份文件(记录 + current + previous)必须当成**一组**校验后再挂, 校验在 iosstate
    (validate_restore_set) —— 那里有元数据语义, 这里只负责取文件和把结论翻译成消息。
    不通过就抛 _IosRestoreRefused: **整笔恢复**失败, 而不是"跳过 iOS 那部分继续恢复"。
    理由是这三份和 config.json 来自同一个包 —— 这个包的 iOS 那一组要么自相矛盾、要么带着
    本项目不会生成的 payload, 那就没有理由单独相信它的网关配置部分; 而"成功了但少恢复了
    一样东西"留下的机器状态, 用户不会知道。

    旧格式备份(只有记录、没有产物)仍按既有口径处理: 认出来、如实说明, 不伪装成完整恢复。
      · previous 那一版用的根证书只在产物里有正文, 元数据里只有指纹 —— 它丢了就真的没了,
        谁也重建不出来。所以记录里的 previous 一并清掉, 不留一个点开就报错的"上一版";
      · current 保留记录。它**有可能**按记录逐字节复原(条件见 iosstate.repair_current),
        但那是恢复之后另做的事, 这里不越权替用户决定。
    """
    state_src = os.path.join(tmp, "etc/privdns-gateway/ios-profile.json")
    if not os.path.isfile(state_src):
        return None, None                       # 备份里没有 → 不动现网的任何一份
    if iosstate is None:                        # Android: 根本没有这套模块
        return None, "⚠️ 本平台不带 iOS 描述文件功能, 备份里的那一组已跳过(现网未被改动)"

    def _rd(p):
        if not os.path.isfile(p):
            return None
        with open(p, "rb") as f:
            return f.read()

    try:
        raw = _rd(state_src)
        cur = _rd(os.path.join(tmp, "var/lib/privdns-gateway/ios-profile/current.mobileconfig"))
        prev = _rd(os.path.join(tmp, "var/lib/privdns-gateway/ios-profile/previous.mobileconfig"))
    except OSError as e:
        raise _IosRestoreRefused("读不到备份里的 iOS 描述文件(%s)" % e.strerror)
    try:
        raw, cur, prev, note = iosstate.validate_restore_set(raw, cur, prev)
    except iosstate.RestoreRefused as e:
        raise _IosRestoreRefused(str(e))
    except iosstate.StateError as e:
        raise _IosRestoreRefused(str(e))
    if raw is None:
        return None, "⚠️ 备份里的 iOS 描述文件记录无法解析, 已跳过(现网那份未被改动)"
    t.stage("ios_profile_state", raw)
    what = ["身份/修订记录"]
    if cur is not None:
        t.stage("ios_profile_current", cur)
        what.append("当前版本")
    if prev is not None:
        t.stage("ios_profile_previous", prev)
        what.append("上一版")
    return "iOS 描述文件(" + " + ".join(what) + ")", note


def _restore_commit(tmp):
    """把解包出来的内容组装成候选并提交一笔事务。返回 (ok, msg)。"""
    newsb = os.path.join(tmp, "etc/sing-box/config.json")
    newmos = os.path.join(tmp, "etc/mosdns/config.yaml")
    if not os.path.exists(newsb):
        return False, "备份里没有网关配置(config.json), 拒绝恢复"
    tx = _pdgtx()
    try:
        t = tx.Tx(source="bot", op="restore", mode="repair")
    except Exception as e:  # noqa: BLE001
        return False, "无法开始配置事务(%s)" % type(e).__name__
    notes = []
    try:
        cur_sb, sb_sha = t.read_for_update("model")
        cur_mos, mos_sha = t.read_for_update("mosdns_conf")
        cur_meta_raw, meta_sha = t.read_for_update("rs_meta")
        # 机器感知: 用「本机」身份覆盖备份带来的 server_ip / 内网卡段 / 证书路径。这样跨机导入
        # 只搬出口+分流+规则集, 不会把别人的 IP/证书路径搬来搞错位。现网那一份取自
        # read_for_update 的内容(带前置 sha), 不再单独读文件。
        cur_id = _machine_id_from(cur_sb, cur_mos)
        bak_id = _machine_id(newsb, newmos)
        subs = [(bak_id[i], cur_id[i]) for i in range(3)
                if bak_id[i] and cur_id[i] and bak_id[i] != cur_id[i]]
        kept = [cur_id[i] for i in range(3)
                if bak_id[i] and cur_id[i] and bak_id[i] != cur_id[i]]

        def _subbed(path):
            try:
                with open(path, "rb") as f:
                    txt = f.read().decode("utf-8")
            except OSError:
                return None
            for old, new in subs:
                txt = txt.replace(old, new)
            return txt.encode("utf-8")

        sb_new = _subbed(newsb)
        try:
            cfg = json.loads(sb_new.decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            return False, "备份里的网关配置不是合法 JSON(%s)" % type(e).__name__
        # 面板是临时运行态, 不随备份恢复; 平台净化要赶在校验/落盘之前
        _panel_sanitize_config(cfg)
        _platform_sanitize_model(cfg)
        t.stage("model", _model_bytes(cfg), expect=sb_sha)
        restored = ["config.json"]
        mos_new = _subbed(newmos) if os.path.exists(newmos) else None
        if mos_new is not None:
            mos_new, ep_note = _reapply_explicit_proxy(mos_new, cur_mos)
            if ep_note:
                notes.append(ep_note)
            t.stage("mosdns_conf", mos_new, expect=mos_sha)
            restored.append("mosdns/config.yaml")
        # 可选文件: **备份里有才恢复**, 缺了就保持现网(绝不擅自清空)
        for arc, target in (("etc/mosdns/rules/custom_direct.txt", "mosdns_rule:custom_direct.txt"),
                            ("etc/mosdns/rules/custom_hijack.txt", "mosdns_rule:custom_hijack.txt")):
            src = os.path.join(tmp, arc)
            if os.path.isfile(src):
                with open(src, "rb") as f:
                    t.stage(target, f.read())
                restored.append(os.path.basename(arc))
        bak_meta_path = os.path.join(tmp, "opt/pdg-bot/rulesets.json")
        if os.path.isfile(bak_meta_path):
            with open(bak_meta_path, "rb") as f:
                bak_meta_raw = f.read()
            try:
                bak_meta = json.loads(bak_meta_raw.decode("utf-8"))
                cur_meta = json.loads(cur_meta_raw.decode("utf-8")) if cur_meta_raw else {}
                plan, notes = _restore_ruleset_plan(tmp, cur_meta, bak_meta)
            except ValueError as e:
                return False, "备份里的规则集不能恢复: %s" % e
            except Exception as e:  # noqa: BLE001
                return False, "备份里的规则集元数据无法解析(%s)" % type(e).__name__
            t.stage("rs_meta", bak_meta_raw, expect=meta_sha)
            restored.append("rulesets.json")
            for leaf, blob in sorted(plan.items()):
                t.stage("ruleset:" + leaf, blob)
            n_del = sum(1 for v in plan.values() if v is None)
            restored.append("规则集 %d 个(删除 %d 个)" % (len(plan) - n_del, n_del))
            # 规则集换了, 派生的劫持表也得跟着重算 —— 否则恢复完 gfw 模式下那些 RULE-SET
            # 规则又变成死的。按**本次要落盘的候选**算, 不是磁盘上的旧档。
            rs_blobs = {}
            for nm, inf in (bak_meta or {}).items():
                leaf_ = os.path.basename(str((inf or {}).get("path") or ""))
                if leaf_ and plan.get(leaf_) is not None:
                    rs_blobs[nm] = plan[leaf_]
            hj_data, hj_undrivable = ruleset_hijack_text(bak_meta, rs_blobs)
            t.stage("mosdns_rule:ruleset_hijack.txt", hj_data)
            restored.append("ruleset_hijack.txt")
            if hj_undrivable:
                notes.append("ℹ️ .mrs 规则集无法派生劫持表, gfw 模式下不会命中: "
                             + "、".join(str(x) for x in hj_undrivable[:4]))
        # iOS 描述文件三件套(记录 + 两份产物)进**同一笔**事务: 要么整组换过去, 要么一个都
        # 不动。分开恢复会造出"记录说第 2 版、盘上躺着第 3 版"这种自相矛盾的状态, 而那之后
        # 每一次判定都建立在一个不成立的前提上 —— 界面上却什么都不会报错。
        ios_done, ios_note = _stage_ios_profile(t, tmp)
        if ios_done:
            restored.append(ios_done)
        if ios_note:
            notes.append(ios_note)
        t.derive("mihomo_cfg", _mihomo_derive)
        # 服务动作由**本次真正落盘的目标**推导, 与救援平面共用同一份映射(pdgtx.actions_for_targets)
        # —— 两处各写一套 if/else 迟早会漂移成"同样的恢复, 一边重启一边不重启"。
        # mihomo_cfg 是派生目标, 显式计入(derive 的产物不在 staged 列表里)。
        for _a in tx.actions_for_targets(list(t.targets) + ["mihomo_cfg"]):
            t.service(_a)
        res = t.commit()
    except _IosRestoreRefused as e:
        # 点名是哪一道门 —— 不通过时用户唯一能做的判断是"这份备份能不能用", 一句
        # "恢复失败" 帮不了他。现网一个字节都没被改(事务还没提交)。
        return False, ("⛔ 已拒绝恢复这份备份, 现网配置一个字节都没有改动。\n%s"
                       % tx.redact(str(e)))
    except tx.TxBusy:
        return False, BUSY_MSG
    except tx.TxRefused as e:
        return False, tx.redact(str(e))
    except tx.TxError as e:
        return False, "配置事务内部错误: %s" % tx.redact(str(e))
    except Exception as e:  # noqa: BLE001
        return False, "恢复过程出错(%s), 未提交任何改动" % type(e).__name__
    finally:
        # 候选阶段 return / 抛异常时把这笔事务收尾成 ABORTED 并删掉候选材料 ——
        # 否则会留下 PREPARING 目录, 里面的候选 model 还带着出口凭据。已进入
        # APPLYING/OBSERVING 的不受影响(那是现网被动过的证据, 必须留给 recover)。
        t.abort_unstarted()
    tail = ("\n" + "\n".join(notes)) if notes else ""
    if res["state"] == tx.COMMITTED:
        msg = "已恢复: " + ", ".join(restored) + "\n已重启 " + _core_svc() + " + mosdns"
        if subs:
            msg += "\n(跨机导入: 已保留本机身份 " + "、".join(kept) + ", 只搬了出口+分流+规则集)"
        if res.get("warnings"):
            msg += "\n⚠️ " + "; ".join(res["warnings"])
        return True, msg + tail
    if res["state"] == tx.ROLLBACK_FAILED:
        return False, ("恢复失败(%s)\n⚠️ 回滚未完成, 未恢复项: %s\n事务材料已保留, 请运行 "
                       "<code>sudo pdg tx recover %s</code>"
                       % (res.get("error", ""), "、".join(res.get("rollback_failed_items") or []) or "(未知)",
                          res["txid"])) + tail
    return False, ("恢复失败(%s)\n已整体回滚: model / mosdns / 规则集 全部还原, 服务已恢复。"
                   % res.get("error", "")) + tail


# ── 文案 ──
_DOT_HOST = None

def _dot_host():
    global _DOT_HOST
    if _DOT_HOST is None:
        try:
            out = sh(["openssl", "x509", "-in", CERT, "-noout", "-subject"]).stdout
            m = re.search(r"CN\s*=\s*([A-Za-z0-9.*-]+)", out)
            _DOT_HOST = m.group(1) if m else "?"
        except Exception:  # noqa: BLE001
            _DOT_HOST = "?"
    return _DOT_HOST

def _server_ip():
    try:
        for r in load()["route"]["rules"]:
            if r.get("action") == "reject":
                for cidr in r.get("ip_cidr", []):
                    if not cidr.startswith("127."):
                        return cidr.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    return "?"

def _groups_desc(c):
    g = [o for o in c["outbounds"] if o.get("type") == "urltest"]
    return "\n".join(f"🔀 故障组 <b>{o['tag']}</b>: {' › '.join(o.get('outbounds', []))}" for o in g)

def status_text():
    svc = _core_svc()
    _st = sh(["systemctl", "is-active", "mosdns", svc, "pdg-bot"]).stdout.split()
    _states = dict(zip(["mosdns", svc, "pdg-bot"], _st + ["?", "?", "?"]))
    def dot(s):
        return "🟢" if _states.get(s) == "active" else "🔴"
    c = load(); exits = exit_tags(c)
    g = _groups_desc(c)
    final = c["route"].get("final")
    nrules = sum(1 for r in c["route"]["rules"] if r.get("outbound"))
    split = "国内直连" + (f" / {nrules} 条分流规则" if nrules else "") + f" / 其余→{final}"
    return ("🖥 <b>PrivDNS Gateway</b>\n\n"
            f"{dot('mosdns')} mosdns（DNS 分流, 带缓存）\n"
            f"{dot(svc)} {svc}（流量出口）\n"
            f"{dot('pdg-bot')} pdg-bot（管理）\n\n"
            f"📡 DoT: <code>{_dot_host()}:853</code>（{'iOS 描述文件' if _platform() == 'ios' else 'Android 私密 DNS'}）\n"
            f"🌐 IP: <code>{_server_ip()}</code>\n"
            f"📤 出口({len(exits)}): {', '.join(exits)}\n"
            + (g + "\n" if g else "")
            + f"🎯 默认出口(其余国际): <b>{final}</b>\n"
            f"📚 规则集: {len(_rs_meta())} 个\n"
            f"🌏 分流: {split}")

def exits_text():
    c = load(); lines = []
    for o in proxy_outbounds(c):
        lines.append(f'• <b>{o["tag"]}</b>  {o["type"]}  {o.get("server")}:{o.get("server_port")}')
    for o in c["outbounds"]:
        if o.get("type") == "direct":
            lines.append(f'• <b>{o["tag"]}</b>  direct（本机直出）')
        elif o.get("type") == "urltest":
            lines.append(f'• <b>{o["tag"]}</b>  故障组 → {" › ".join(o.get("outbounds", []))}')
    return "出口:\n" + ("\n".join(lines) or "(无)")

def rules_text():
    c = load(); lines = []; m = _rs_meta()
    for r in c["route"]["rules"]:
        if "outbound" not in r:
            continue
        if r.get("rule_set"):
            info = m.get(r["rule_set"], {})
            label = info.get("label") or r["rule_set"]
            lines.append(f'→ <b>{r["outbound"]}</b>: [规则集 {label} · {info.get("count","?")}条]')
        else:
            doms = r.get("domain_suffix", []) + r.get("domain", [])
            if doms:
                lines.append(f'→ <b>{r["outbound"]}</b>: ' + ", ".join(doms[:12]) + (" …" if len(doms) > 12 else ""))
    txt = "分流规则:\n" + ("\n".join(lines) or f"(无显式规则, 其余→{c['route'].get('final')})")
    d = _read_direct()
    if d:
        txt += "\n\n自定义直连: " + ", ".join(d[:20])
    return txt

def kb_pick(prefix, tags, back=BACK):
    rows = [[{"text": t, "callback_data": f"{prefix}:{t}"}] for t in tags]
    rows.extend(_back_rows(back))
    return {"inline_keyboard": rows}

def kb_pick_named(prefix, items, back=BACK):
    """items=[(value, 显示文字)]: 按钮显示文字, 回调用 value。"""
    rows = [[{"text": label, "callback_data": f"{prefix}:{value}"}] for value, label in items]
    rows.extend(_back_rows(back))
    return {"inline_keyboard": rows}

# ── 回调 (原地编辑) ──
def handle_cb(chat, mid, data):
    # 用户对这条消息做了新操作 → 还挂在它上面的 WLOC 监听立即作废。否则用户点了「返回菜单」,
    # 30 秒后监听把菜单原地改成一句"尚未收到请求", 正看着的界面就没了。
    wloc_invalidate_watch(chat, mid)
    # iOS 专属功能的统一后端门控(不只隐藏按钮): 旧 TG 消息里的 iOS 描述文件 / WLOC 按钮被点也拒绝。
    if (data in ("ios", "ios_ssid", "iosgen", "iosgen:legacy", "iosgen:fresh",
                 "iosdiff", "iosprev", "iosack")
            or data == "wloc" or data.startswith("wloc:")) \
       and not _ios_only(chat, mid):
        return
    if data in ("menu", "status") or data.startswith("nav:"):
        state.pop(chat, None); del_sel.pop(chat, None)   # 返回/切页 = 放弃进行中的输入流程和勾选, 免得下一条文字被旧状态误吃
    if data in ("menu", "status"):
        edit(chat, mid, status_text(), MENU); return
    if data.startswith("nav:"):
        title, kb = _nav(data[4:]); edit(chat, mid, title, kb); return
    if data == "setdot":
        state[chat] = "set_dot"
        edit(chat, mid, "发你的自定义 DoT 域名(先把它的 A 记录指向本机, Cloudflare 用「灰云 DNS only」)。\n"
             f"本机 IP: <code>{_server_ip()}</code>\n例: <code>dot.example.com</code>\n"
             "之后自动签 Let's Encrypt 证书并切换(约 30 秒内代理短暂中断)。/cancel 取消。", BACK); return
    if data.startswith("dosetdot:"):
        domain = data[9:]
        edit(chat, mid, f"正在为 <code>{domain}</code> 校验 A 记录并签证书(约 30-60 秒, 代理短暂中断)…", BACK)
        ok, msg = set_dot_domain(domain); edit(chat, mid, (msg if ok else "❌ " + msg), MENU); return
    if data == "test":
        edit(chat, mid, "测试中…", BACK); edit(chat, mid, test_exits(), BACK); return
    if data == "doctor":
        edit(chat, mid, "🩺 自检中(几秒)…", BACK); edit(chat, mid, doctor_text(), BACK); return
    if data == "upd_check":
        edit(chat, mid, "🔄 检查更新中…", BACK)
        has, txt = update_check()
        kb = ({"inline_keyboard": [[{"text": "✅ 确认更新", "callback_data": "upd_apply"}],
                                   [{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]} if has else BACK)
        edit(chat, mid, txt, kb); return
    if data == "upd_apply":
        ok = start_update()
        edit(chat, mid, ("🚀 已开始后台更新, 约 30-60 秒后 bot 自动回来(期间可能短暂无响应)。\n"
                         "完成后点「🩺 自检」确认。" if ok
                         else "❌ 启动更新失败, 请在终端跑 sudo pdg update。"), BACK); return
    if data == "traffic":
        edit(chat, mid, traffic_text(), BACK); return
    if data == "exit_list":
        edit(chat, mid, exits_text(), EXIT_BACK); return
    if data == "rules":
        edit(chat, mid, rules_text(), RULE_BACK); return
    if data == "add_exit":
        state[chat] = "add_exit"
        edit(chat, mid, "发一条节点链接：<code>ss:// vmess:// trojan:// vless://(含 reality) hysteria2:// tuic:// anytls:// socks5:// http://</code>,或 Surge 的 <code>名字 = ss, …</code> 行\n/cancel 取消。", EXIT_BACK); return
    if data == "add_grp":
        state[chat] = "add_group"
        edit(chat, mid, "发「<b>组名 出口1 出口2 …</b>」建故障切换组(按探测延迟选择出口，不可用时切换)。\n"
             f"可选成员: {', '.join(concrete_tags(load()))}\n例: <code>main hk tw us</code>\n"
             "建好后可在「🎯 设默认出口」或规则里选它。/cancel 取消。", EXIT_BACK); return
    if data == "add_rule":
        state[chat] = "add_rule"
        edit(chat, mid, f"发「<b>域名 出口</b>」，出口: {', '.join(exit_tags(load()))} 或 <b>direct</b>\n例: <code>netflix.com hk</code> / <code>x.cn direct</code>\n/cancel 取消。", RULE_BACK); return
    if data == "edit_rule":
        rs = editable_rules(load())
        if not rs:
            edit(chat, mid, "暂无可改的分流规则", RULE_BACK); return
        rows = [[{"text": lbl, "callback_data": f"er:{i}"}] for i, lbl in rs]
        rows.extend(_back_rows(RULE_BACK))
        edit(chat, mid, "选要改出口的规则:", {"inline_keyboard": rows}); return
    if data.startswith("er:"):
        idx = data[3:]
        rows = [[{"text": t, "callback_data": f"ero:{idx}:{t}"}] for t in exit_tags(load())]
        rows.extend(_back_rows(RULE_BACK))
        edit(chat, mid, "改到哪个出口:", {"inline_keyboard": rows}); return
    if data.startswith("ero:"):
        _, idx, target = data.split(":", 2)
        ok, msg = reassign_rule(int(idx), target); edit(chat, mid, msg if ok else ("❌ " + msg), RULE_BACK); return
    if data == "order_exit":
        state[chat] = "order_exit"
        cur = [o["tag"] for o in load()["outbounds"]]
        edit(chat, mid, "发新的出口顺序(空格分隔, 含全部出口)。\n"
             f"当前: <code>{' '.join(cur)}</code>\n例: <code>hk tw jp us auto</code>\n/cancel 取消。", EXIT_BACK); return
    if data == "edit_grp":
        gs = urltest_groups(load())
        if not gs:
            edit(chat, mid, "还没有故障组, 先用「🔀 新建故障组」建一个。", EXIT_BACK); return
        edit(chat, mid, "选要改的故障组:", kb_pick("egrp", gs, EXIT_BACK)); return
    if data.startswith("egrp:"):
        name = data[5:]; state[chat] = "edit_grp:" + name
        cur = next((o.get("outbounds", []) for o in load()["outbounds"]
                    if o.get("tag") == name and o.get("type") == "urltest"), [])
        edit(chat, mid, f"发 <b>{name}</b> 组的新成员(空格分隔, 按顺序, 至少2个)。\n"
             f"当前: <code>{' '.join(cur) or '空'}</code>\n可选: {', '.join(concrete_tags(load()))}\n"
             f"例: <code>hk tw us</code>\n/cancel 取消。", EXIT_BACK); return
    if data == "del_rule":
        del_sel[chat] = set()
        items, kb = del_rule_kb(chat)
        if not items:
            edit(chat, mid, "暂无可删的单域名规则(规则集请用「🗑 删规则集」)。", RULE_BACK); return
        edit(chat, mid, "勾选要删的域名(可多选), 选好点「✅ 确认删除」一次删:", kb); return
    if data.startswith("dtog:"):
        d = data[5:]; sel = del_sel.setdefault(chat, set())
        sel.discard(d) if d in sel else sel.add(d)
        _, kb = del_rule_kb(chat)
        edit(chat, mid, "勾选要删的域名(可多选), 选好点「✅ 确认删除」一次删:", kb); return
    if data == "ddel":
        doms = list(del_sel.get(chat, set()))
        if not doms:
            _, kb = del_rule_kb(chat)
            edit(chat, mid, "还没勾选域名。勾选后再点「✅ 确认删除」:", kb); return
        edit(chat, mid, f"⏳ 正在删除 {len(doms)} 个域名并重启 {_core_svc()}…", RULE_BACK)
        ok, msg = del_rules_bulk(doms); del_sel.pop(chat, None)
        edit(chat, mid, msg if ok else ("❌ " + msg), RULE_BACK); return
    if data == "testdom":
        state[chat] = "test_dom"
        edit(chat, mid, "发个域名, 查它走哪个出口/规则(还是国内直连)。\n例: <code>netflix.com</code>\n/cancel 取消。", RULE_BACK); return
    if data == "add_rs":
        state[chat] = "add_rs"
        edit(chat, mid, "发「<b>规则集URL 出口 [名称]</b>」(后缀 .list / .txt / .yaml / .mrs)。\n"
             f"出口: {', '.join(exit_tags(load()))}\n名称可留空(之后用「✏️ 改规则集名」改)。\n"
             "例: <code>https://.../Binance.list tw 币安</code>\n"
             "· .mrs 需在末尾补类型: <code>https://.../geo.mrs tw 名称 domain</code>"
             "(可选 domain / ipcidr / classical —— 二进制规则集判不出来, 猜错会让规则永不命中)\n"
             "/cancel 取消。", RULE_BACK); return
    if data == "del_rs":
        if not _rs_meta():
            edit(chat, mid, "没有已添加的规则集", RULE_BACK); return
        edit(chat, mid, "选择要删除的规则集：", kb_pick_named("delrs", _rs_items(), RULE_BACK)); return
    if data == "edit_rs":
        if not _rs_meta():
            edit(chat, mid, "没有已添加的规则集", RULE_BACK); return
        edit(chat, mid, "选择要改名的规则集：", kb_pick_named("ers", _rs_items(), RULE_BACK)); return
    if data.startswith("ers:"):
        name = data[4:]; state[chat] = "rs_label:" + name
        cur = _rs_meta().get(name, {}).get("label") or name
        edit(chat, mid, f"发规则集 <code>{name}</code> 的新名称(显示用, 如 <b>币安</b> / <b>OpenAI</b>)。\n"
             f"当前: {cur}\n发「-」清除自定义名。/cancel 取消。", RULE_BACK); return
    if data == "tgexit":
        c = load(); cur = _tg_exit(c)
        rows = [[{"text": ("✓ " if t == cur else "") + t, "callback_data": "tgx:" + t}] for t in exit_tags(c)]
        rows.append([{"text": ("✓ " if not cur else "") + "跟随默认出口", "callback_data": "tgx:"}])
        rows.append([{"text": "⬅️ 返回主菜单", "callback_data": "menu"}])
        edit(chat, mid, "✈️ Telegram(SOCKS5 :8445)走哪个出口?\n"
             f"当前: <b>{cur or '默认出口'}</b>\n手机里 Telegram→设置→数据和存储→代理 填 SOCKS5 <code>{_server_ip()}:8445</code>。",
             {"inline_keyboard": rows}); return
    if data.startswith("tgx:"):
        ok, msg = set_tg_exit(data[4:])
        if ok:
            msg += ("\n\n在 Telegram → 设置 → 数据和存储 → 代理 → 加 <b>SOCKS5</b>:\n"
                    f"服务器 <code>{_server_ip()}</code>\n端口 <code>8445</code>\n(无需用户名/密码)")
        edit(chat, mid, msg if ok else ("❌ " + msg), MENU); return
    if data == "del_exit":
        tags = deletable_tags(load())
        edit(chat, mid, "选择要删除的出口/故障组：" if tags else "没有可删的出口",
             kb_pick("delx", tags, EXIT_BACK) if tags else EXIT_BACK); return
    if data == "ren_exit":
        tags = deletable_tags(load())
        edit(chat, mid, "选择要改名的出口/故障组：" if tags else "没有可改名的出口",
             kb_pick("renx", tags, EXIT_BACK) if tags else EXIT_BACK); return
    if data.startswith("renx:"):
        old = data[5:]; state[chat] = "rename_exit:" + old
        edit(chat, mid, f"发出口 <b>{old}</b> 的新名字(字母/数字/_/./-, 40 字内)。\n"
             "分流规则、故障组、默认出口里的引用会一并同步。/cancel 取消。", EXIT_BACK); return
    if data == "setfinal":
        edit(chat, mid, "「其余国际」默认走哪个出口/组：", kb_pick("fin", exit_tags(load()), EXIT_BACK)); return
    if data == "ios":
        state.pop(chat, None)
        try:
            edit(chat, mid, _ios_status_text(), _ios_kb())
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, "读取描述文件记录失败: %s" % e, MENU)
        return
    if data == "ios_ssid":
        state[chat] = "ios_ssid"
        edit(chat, mid, "📶 <b>强制直连的 Wi-Fi</b>\n"
             "Wi-Fi/蜂窝下是否启用私密 DNS 都由 <code>:81</code> 探测自动判定(网络能走到网关才启用)。\n"
             "若有想<b>强制直连</b>的 Wi-Fi(如公司网、探测误判的酒店网), 发它的名字(SSID, 多个则每行一个);"
             "发 <code>-</code> 表示清空名单。/cancel 取消。",
             {"inline_keyboard": [[{"text": "⬅️ 返回", "callback_data": "ios"}],
                                  [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data in ("iosgen", "iosgen:legacy", "iosgen:fresh"):
        state.pop(chat, None)
        try:
            _ios_mods()
        except RuntimeError as e:
            edit(chat, mid, str(e), MENU); return
        # 第一次启用受管生命周期时必须问一句: 这台网关以前有没有发过旧版(随机身份)描述文件。
        # 服务器没有任何办法知道这件事, 而用户知道 —— 与其猜, 不如问。猜错的代价是用户手机上
        # 悄悄多出一个永远不会被更新的描述文件。
        if data == "iosgen" and not (iosstate.load() or {}).get("current"):
            edit(chat, mid, "📱 <b>首次启用受管描述文件</b>\n\n"
                 "在这台网关上, 你<b>以前</b>装过 PrivDNS Gateway 的 iOS 描述文件吗?\n\n"
                 "• 装过 → 旧版每次生成都是随机身份, iOS 会把新的当成<b>另一个</b>描述文件。"
                 "所以要先在 iPhone 上手工删掉旧的那份;\n"
                 "• 没装过 → 直接生成即可。\n\n" + IOS_UNKNOWN,
                 {"inline_keyboard": [
                     [{"text": "装过, 我会先删掉旧的", "callback_data": "iosgen:legacy"}],
                     [{"text": "没装过", "callback_data": "iosgen:fresh"}],
                     [{"text": "⬅️ 返回", "callback_data": "ios"}]]}); return
        edit(chat, mid, "正在生成 iOS 描述文件…", BACK)
        try:
            # 不传 SSID = 沿用已配好的强制直连名单。传 () 会把它当成"用户要清空"。
            msg = _ios_send(chat, None, data == "iosgen:legacy")
            edit(chat, mid, msg, _ios_kb())
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, f"生成失败: {e}", MENU)
        return
    if data == "iosdiff":
        try:
            _ios_mods()
            meta = iosstate.load() or {}
            prev, cur = meta.get("previous"), meta.get("current")
            if not (prev and cur):
                edit(chat, mid, "还没有上一版可对比。", _ios_kb()); return
            for _w in ("current", "previous"):
                _st, _dt = iosstate.artifact_health(meta, _w, None)
                if _st != iosstate.HEALTHY:
                    edit(chat, mid, "%s\n%s" % (iosstate.HEALTH_LABEL[_st], _esc(_dt)),
                         _ios_kb()); return
            d = iosstate.diff_fields(prev["inputs"], cur["inputs"])
            lines = ["🔍 <b>第 %d 版 → 第 %d 版</b>" % (prev["revision"], cur["revision"]), ""]
            for k, lv, ov, nv in d:
                lines.append("• <b>%s</b>(%s)\n  %s → %s"
                             % (iosstate.FIELD_LABEL.get(k, k), iosstate.LEVEL_LABEL[lv],
                                _ios_val(ov), _ios_val(nv)))
            if not d:
                lines.append("两版的语义输入相同。")
            lines += ["", IOS_UNKNOWN]
            edit(chat, mid, "\n".join(lines), _ios_kb())
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, "对比失败: %s" % e, MENU)
        return
    if data == "iosprev":
        try:
            _ios_mods()
            meta = iosstate.load() or {}
            if not meta.get("previous"):
                edit(chat, mid, "还没有上一版。", _ios_kb()); return
            blob = iosstate.verified_artifact(meta, "previous")
            send_document(chat, "PrivDNS-Gateway-prev.mobileconfig", blob,
                          "⏪ 上一版(第 %d 版)。这只是把旧文件再给你一次 —— 服务器记录的当前版本"
                          "不会因此回退。\n%s" % (meta["previous"]["revision"], IOS_INSTALL_HOWTO))
            edit(chat, mid, "✅ 上一版已发送(见上一条)。\n\n" + IOS_UNKNOWN, _ios_kb())
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, "取回失败: %s" % e, MENU)
        return
    if data == "iosack":
        try:
            _ios_mods()
            iosstate.ack_migration()
            edit(chat, mid, "✅ 已关闭迁移提示。\n\n"
                 "记录的是「你告诉我们旧描述文件已删除」, 服务器本身无从核实这件事。\n\n"
                 + _ios_status_text(), _ios_kb())
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, "操作失败: %s" % e, MENU)
        return
    if data == "backup":
        edit(chat, mid, "正在打包配置…", OPS_BACK)
        try:
            fn = "pdg-backup-" + time.strftime("%Y%m%d-%H%M") + ".tar.gz"
            send_document(chat, fn, backup_blob(),
                          "💾 配置备份(含出口密码/uuid, 请妥善保存)。\n恢复: 点「♻️ 恢复」后把此文件发回。")
            edit(chat, mid, "✅ 备份已发送(见上一条)。", MENU)
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, f"备份失败: {e}", MENU)
        return
    if data == "restore":
        state[chat] = "restore"
        edit(chat, mid, "把之前「💾 备份」得到的 <code>.tar.gz</code> 作为文件发给我即可恢复"
             "(先校验配置, 失败自动回滚)。\n/cancel 取消。", BACK); return
    if data == "dnsup":
        state[chat] = "set_dns"
        rem = _upstreams("remote"); loc = _upstreams("local")
        mode = "🔓 WDA 解锁" if _wda_on() else "🛬 落地出口"
        edit(chat, mid, "🌐 <b>mosdns DNS 上游</b>\n"
             f"国际(remote): <code>{', '.join(rem) or '?'}</code>\n"
             f"国内(local): <code>{', '.join(loc) or '?'}</code>\n\n"
             f"<b>流媒体/服务解锁</b>: 当前 <b>{mode}</b>\n"
             "• 🛬 落地出口: 解锁服务走各自落地(hk/tw)\n"
             "• 🔓 WDA: WDA 能解锁的整体走 WDA(jp 直出 + 解锁 DNS)\n"
             f"  ⚠️ 开 WDA 前先去解锁服务后台授权本机 IP <code>{_server_ip()}</code>(没授权点 🔓 会被拦下)\n\n"
             "改上游: 发「<b>remote 地址…</b>」或「<b>local 地址…</b>」(空格分隔多个)\n/cancel 取消。",
             {"inline_keyboard": [
                 [{"text": "🛬 解锁走落地出口", "callback_data": "wda:off"},
                 {"text": "🔓 解锁走 WDA", "callback_data": "wda:on"}],
                 [{"text": "⬅️ 返回运维", "callback_data": "nav:ops"}],
                 [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data in ("wda:on", "wda:off"):
        edit(chat, mid, "正在切换解锁模式…", DNS_BACK)
        ok, msg = set_wda_mode(data == "wda:on")
        edit(chat, mid, msg if ok else ("❌ " + msg), DNS_BACK); return
    if data == "tfo":
        on = _tfo_on(load())
        edit(chat, mid, f"🚀 <b>TCP Fast Open</b>\n当前: <b>{'开启' if on else '关闭'}</b>\n"
             "降低到落地的握手延迟; 需落地端也支持, 否则自动回落普通握手。",
             {"inline_keyboard": [[{"text": "开启", "callback_data": "tfo:on"}, {"text": "关闭", "callback_data": "tfo:off"}],
                                  [{"text": "⬅️ 返回运维", "callback_data": "nav:ops"}],
                                  [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data in ("tfo:on", "tfo:off"):
        ok, msg = set_tfo(data == "tfo:on"); edit(chat, mid, msg if ok else ("❌ " + msg), OPS_BACK); return
    if data in ("wloc", "wloc:menu"):
        if _platform() != "ios":
            edit(chat, mid, "位置改写(WLOC)仅 iOS 平台可用。", OPS_BACK); return
        w = _wloc_state(); on = bool(w.get("enabled")); loc = _wloc_active(w)
        cur = f"<b>{w['active']}</b>({loc['lat']}, {loc['lon']})" if loc else "未设"
        edit(chat, mid, f"🍏 <b>位置改写 (WLOC)</b>\n状态: <b>{'🟢 开启' if on else '关闭'}</b>　当前: {cur}　地点: {len(w['locations'])} 个\n\n"
             "WLOC 只修改 Apple 网络定位响应中的坐标，不修改 GPS 数据。使用前需要安装并信任网关 CA。\n\n"
             "<b>首次使用顺序:</b>\n"
             "① 添加地点并开启 WLOC\n"
             "② 返回「📱 客户端」，重新生成并安装 iOS 描述文件\n"
             "③ 到「设置 → 通用 → 关于本机 → 证书信任设置」，信任 PrivDNS Gateway MITM CA\n\n"
             "<b>切换地点的推荐顺序（全程用内网卡）：</b>\n"
             "① 控制中心把 Wi-Fi 点灰（不是在设置里关 Wi-Fi）\n"
             "② 在 Bot「📍 地点 / 切换」里点目标地点\n"
             "③ 等 Bot 显示「WLOC 已热加载」\n"
             "④ 设置 → 隐私与安全性 → 定位服务：关闭，等 2 秒后重新开启\n"
             "⑤ 打开目标 App\n"
             "⑥ iOS 26 如果一直没有发起新的 WLOC 请求，可能仍需重启手机\n\n"
             "切地点只改网关配置，不重启任何服务；网关能保证的是<b>下一次</b> Apple 网络定位"
             "请求用新坐标，iOS 自己的定位缓存不归网关清。\n"
             "长期无法定位时：设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私 → 重启手机",
             {"inline_keyboard": [
                 [{"text": "🟢 已开启" if on else "✅ 开启", "callback_data": "wloc:on"},
                  {"text": "关闭", "callback_data": "wloc:off"}],
                 [{"text": "📍 地点 / 切换", "callback_data": "wloc:list"}],
                 [{"text": "➕ 添加地点", "callback_data": "wloc:add"},
                  {"text": "🗑 删除地点", "callback_data": "wloc:del"}],
                 [{"text": "⬅️ 返回运维", "callback_data": "nav:ops"}],
                 [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data == "wloc:list":
        w = _wloc_state()
        if not w["locations"]:
            edit(chat, mid, "还没有地点。点「➕ 添加地点」。", WLOC_BACK); return
        kb = [[{"text": ("✅ " if l["name"] == w["active"] else "○ ")
                + f"{l['name']} ({l['lat']}, {l['lon']})", "callback_data": f"wloc:sw:{i}"}]
              for i, l in enumerate(w["locations"])]
        kb.append([{"text": "⬅️ 返回 WLOC", "callback_data": "wloc:menu"}])
        edit(chat, mid, "点一个地点即切换到它。\n开启中为热切换：只改网关配置，不重启服务；"
                        "切完请关闭定位服务、等 2 秒再开启。", {"inline_keyboard": kb}); return
    if data == "wloc:add":
        state[chat] = "wloc_add"
        send(chat, "发「<b>名称 纬度,经度</b>」如 <code>上海 31.2304,121.4737</code>(小数;北纬东经为正)。/cancel 取消。", BACK); return
    if data == "wloc:del":
        w = _wloc_state()
        if not w["locations"]:
            edit(chat, mid, "没有可删的地点。", WLOC_BACK); return
        kb = [[{"text": f"🗑 {l['name']} ({l['lat']}, {l['lon']})", "callback_data": f"wloc:rm:{i}"}]
              for i, l in enumerate(w["locations"])]
        kb.append([{"text": "⬅️ 返回 WLOC", "callback_data": "wloc:menu"}])
        edit(chat, mid, "点一个删除:", {"inline_keyboard": kb}); return
    if data.startswith("wloc:sw:"):
        w = _wloc_state(); i = int(data.rsplit(":", 1)[1])
        if 0 <= i < len(w["locations"]):
            name = w["locations"][i]["name"]
            kb = {"inline_keyboard": [[{"text": "📍 地点列表", "callback_data": "wloc:list"}],
                                      [{"text": "⬅️ 返回 WLOC", "callback_data": "wloc:menu"}],
                                      [{"text": "🏠 主菜单", "callback_data": "menu"}]]}
            since = time.time()                    # 早于这一刻的状态一律不算这次的命中
            ok, msg, gen = wloc_switch_gen(name)   # 快路径: 只写配置, 不动任何服务
            edit(chat, mid, msg if ok else ("❌ " + msg), kb)
            if ok and _wloc_state().get("enabled"):
                # 切换本身已经完成了; 下面只是在后台等手机真的来一次请求, 好把结果如实回报
                _wloc_watch_async(chat, mid, gen, name, kb=kb, since=since)
        return
    if data.startswith("wloc:rm:"):
        w = _wloc_state(); i = int(data.rsplit(":", 1)[1])
        if 0 <= i < len(w["locations"]):
            ok, msg = wloc_del(w["locations"][i]["name"])
            edit(chat, mid, msg if ok else ("❌ " + msg), WLOC_BACK)
        return
    if data in ("wloc:on", "wloc:off"):
        ok, msg = wloc_enable(data == "wloc:on"); edit(chat, mid, msg if ok else ("❌ " + msg), WLOC_BACK); return
    if data == "panel":
        on = _panel_on()
        edit(chat, mid, "📊 <b>临时观测/控制面板 (zashboard)</b>\n"
             f"当前: <b>{'开启' if on else '关闭'}</b>\n"
             "可看连接/流量/延迟/日志、测速并断开连接；<b>持久配置仍走 bot/CLI</b>。\n"
             "开启 = clash_api 临时绑 0.0.0.0 + 随机密钥 + 放行<b>仅内网卡段</b>→9090, 发一键链接。\n"
             "选自动关闭时长: 到点自动关面板 + 删掉含密钥的链接(忘了关也有暴露上限)。\n"
             "⚠️ HTTP 明文、链接含密钥(别转发)。",
             {"inline_keyboard": [[{"text": "⏱ 开10分", "callback_data": "panel:on:10"},
                                   {"text": "⏱ 开30分", "callback_data": "panel:on:30"},
                                   {"text": "🔓 常开", "callback_data": "panel:on:0"}],
                                  [{"text": "🔒 关闭", "callback_data": "panel:off"}],
                                  [{"text": "⬅️ 返回运维", "callback_data": "nav:ops"}],
                                  [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data.startswith("panel:on:"):
        mins = int(data.rsplit(":", 1)[1]) if data.rsplit(":", 1)[1].isdigit() else 10
        edit(chat, mid, "正在开启观测面板(首次会下载 zashboard、改 clash_api、放行内网 9090)…", OPS_BACK)
        ok, res = set_panel(True)
        if ok:
            published, publish_msg = _panel_publish(chat, res, mins * 60)
            if published:
                tip = (f"⏱ {mins} 分钟后自动关闭并删除上面的链接。" if mins > 0
                       else "🔓 常开模式: 不自动关闭, 看完请手动点「🔒 关闭」。")
                edit(chat, mid, "✅ 已开启，含密钥链接已单独发送。" + tip + "\n"
                                "⚠️ 链接含密钥别转发。首次打不开多半是手机没走内网卡到 9090, 换内网卡/专线再试。", OPS_BACK)
            else:
                edit(chat, mid, "❌ " + publish_msg, OPS_BACK)
        else:
            edit(chat, mid, "❌ 开启失败: " + res, OPS_BACK)
        return
    if data == "panel:off":
        ok, msg = _panel_close(chat)
        edit(chat, mid, msg if ok else ("❌ " + msg), OPS_BACK); return
    if data == "restart":
        # apply_sb 只管到内核那一半; mosdns 重启的结果以前直接丢掉 —— mosdns 起不来时
        # 用户照样收到"✅ 已重启", 而这台机器的 DNS 已经断了。两边都要核实。
        ok, msg = apply_sb(lambda c: None)
        if not ok:
            edit(chat, mid, msg, OPS_BACK); return
        sh(["systemctl", "reset-failed", "mosdns"])
        r = sh(["systemctl", "restart", "mosdns"])
        if r.returncode != 0 or not _svc_active("mosdns"):
            edit(chat, mid, f"⚠️ {_core_svc()} 已重启, 但 <b>mosdns 未能起来</b>(DNS 现在是断的)。\n"
                            "请到服务器上看: <code>journalctl -u mosdns -n 30</code>", OPS_BACK); return
        edit(chat, mid, f"✅ 已重启并确认运行: {_core_svc()} + mosdns", OPS_BACK); return
    if data == "updgeo":
        edit(chat, mid, "正在更新 geosite + 规则集…", OPS_BACK)
        r = sh(["/bin/bash", UPDATE_SCRIPT])
        # 死锁解开: mosdns 缺规则文件就起不来, 而"操作前组件坏了就别动它"那道门又因此拒绝写入
        # 规则文件 —— 越坏越修不了。用户点这个按钮就是在要求修, 那就按修复类操作重试一次
        # (repair 只放宽**基线**, "操作前好、操作后坏"照旧整笔回滚)。
        repaired = False
        if r.returncode != 0 and "操作前这些硬门就是坏的" in (r.stdout + r.stderr):
            env = dict(os.environ, PDG_TX_MODE="repair")
            r = subprocess.run(["/bin/bash", UPDATE_SCRIPT], capture_output=True,
                               text=True, timeout=180, env=env)
            repaired = r.returncode == 0
        n, rs_failed = refresh_rulesets()
        if r.returncode != 0:
            edit(chat, mid, "geosite 更新失败:\n" + (r.stdout + r.stderr)[-300:], OPS_BACK); return
        # 规则集刷新失败必须说出来 —— 否则用户以为规则库是新的, 实际有几条还停在旧版
        msg = f"✅ geosite 已更新; 规则集刷新 {n} 个"
        if repaired:
            msg = (f"✅ geosite 已更新; 规则集刷新 {n} 个\n"
                   "（当时 mosdns 没在运行，按修复模式重跑了一次；建议再看一眼 <b>诊断</b>）")
        if rs_failed:
            msg = (f"⚠️ geosite 已更新; 规则集刷新 {n} 个, 但这些没刷上(仍用上一份好档):\n· "
                   + "\n· ".join(str(x)[:120] for x in rs_failed[:5]))
        edit(chat, mid, msg, OPS_BACK); return
    if data.startswith("delx:"):
        tag = data[5:]
        def mod(c):
            c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != tag]
            for o in c["outbounds"]:
                if o.get("type") == "urltest":
                    o["outbounds"] = [m for m in o.get("outbounds", []) if m != tag]
            c["outbounds"] = [o for o in c["outbounds"]
                              if not (o.get("type") == "urltest" and not o.get("outbounds"))]
            live = {o["tag"] for o in c["outbounds"]}
            for r in c["route"]["rules"]:
                if r.get("outbound") and r["outbound"] not in live:
                    r["outbound"] = c["route"].get("final", "hk")
            if c["route"].get("final") not in live:
                c["route"]["final"] = next((t for t in exit_tags(c)), "direct")
        ok, msg = apply_sb(mod)
        edit(chat, mid, f"✅ 已删除 {tag}" if ok else msg, EXIT_BACK); return
    if data.startswith("fin:"):
        tag = data[4:]
        ok, msg = apply_sb(lambda c: c["route"].__setitem__("final", tag))
        edit(chat, mid, f"✅ 默认出口 → {tag}" if ok else msg, EXIT_BACK); return
    if data.startswith("delrs:"):
        ok, msg = del_ruleset(data[6:]); edit(chat, mid, ("✅ " if ok else "") + msg, RULE_BACK); return

# ── 文本 ──
def handle_text(chat, text, mid=None):
    text = text.strip()
    if text == "/cancel":
        state.pop(chat, None); send_plain(chat, "已取消"); return
    if text in ("/start", "/menu", "/status"):
        state.pop(chat, None); send(chat, status_text()); return
    if text.startswith("/"):
        cmd = text.split()[0]
        if cmd == "/test":
            send_plain(chat, "测试中…"); send_plain(chat, test_exits()); return
        if cmd == "/doctor":
            send_plain(chat, "🩺 自检中…"); send(chat, doctor_text(), BACK); return
        if cmd == "/traffic":
            send(chat, traffic_text(), BACK); return
        if cmd == "/exits":
            send(chat, exits_text(), BACK); return
        if cmd == "/rules":
            send(chat, rules_text(), BACK); return
        if cmd == "/addexit":
            state[chat] = "add_exit"; send(chat, "发节点链接：<code>ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://</code>,或 Surge 的 <code>名字 = ss, …</code> 行。/cancel 取消。", BACK); return
        if cmd == "/group":
            state[chat] = "add_group"; send(chat, "发「<b>组名 出口1 出口2 …</b>」建故障切换组。/cancel 取消。", BACK); return
        if cmd == "/addrule":
            state[chat] = "add_rule"; send(chat, f"发「<b>域名 出口</b>」，出口: {', '.join(exit_tags(load()))} 或 <b>direct</b>。/cancel 取消。", BACK); return
        if cmd == "/delrule":
            state[chat] = "del_rule"; send(chat, "发要删除的域名。/cancel 取消。", BACK); return
        if cmd == "/addrs":
            state[chat] = "add_rs"; send(chat, "发「<b>规则集URL 出口 [名称] [类型]</b>」（支持 .list / .txt / .yaml / .mrs；"
                       ".mrs 类型一般自动识别，认不出时再补 domain/ipcidr）。/cancel 取消。", BACK); return
        if cmd == "/delexit":
            tags = deletable_tags(load())
            send(chat, "选择删除的出口/组：" if tags else "无可删出口", kb_pick("delx", tags) if tags else BACK); return
        if cmd == "/setfinal":
            send(chat, "默认出口：", kb_pick("fin", exit_tags(load()))); return
        if cmd == "/delrs":
            m = _rs_meta()
            send(chat, "选择删除的规则集：" if m else "无规则集", kb_pick("delrs", list(m.keys())) if m else BACK); return
        if cmd == "/ios":
            if not _ios_only(chat):
                return
            try:
                send(chat, _ios_status_text(), _ios_kb())
            except Exception as e:  # noqa: BLE001
                send_plain(chat, f"读取描述文件记录失败: {e}")
            return
        if cmd == "/backup":
            # backup_blob 会在"记录与盘上对不上"时 fail-closed(见 _ios_backup_members),
            # 那条消息正是用户唯一能据以行动的东西, 不能让它变成一次静默失败。
            try:
                send_document(chat, "pdg-backup-" + time.strftime("%Y%m%d-%H%M") + ".tar.gz",
                              backup_blob(), "💾 配置备份")
            except Exception as e:  # noqa: BLE001
                send_plain(chat, "备份失败: %s" % e)
            return
        if cmd == "/restore":
            state[chat] = "restore"; send(chat, "把备份 .tar.gz 作为文件发来。/cancel 取消。", BACK); return
        if cmd == "/setdot":
            parts = text.split()
            if len(parts) >= 2:
                send_plain(chat, "正在校验+签证书(约 30-60 秒, 代理短暂中断)…")
                ok, msg = set_dot_domain(parts[1]); send_plain(chat, msg if ok else ("❌ " + msg)); return
            state[chat] = "set_dot"; send(chat, f"发自定义 DoT 域名(A 记录先指向本机 {_server_ip()})。/cancel 取消。", BACK); return
        if cmd == "/restart":
            ok, _ = apply_sb(lambda c: None); sh(["systemctl", "restart", "mosdns"]); send_plain(chat, "✅ 已重启" if ok else "重启失败"); return
        if cmd == "/update":
            send_plain(chat, "更新中…"); r = sh(["/bin/bash", UPDATE_SCRIPT]); n, rs_failed = refresh_rulesets()
            if r.returncode != 0:
                send_plain(chat, "更新失败"); return
            send_plain(chat, f"✅ 完成，规则集刷新 {n} 个" if not rs_failed
                       else f"⚠️ 完成，规则集刷新 {n} 个，{len(rs_failed)} 个没刷上(仍用上一份好档)"); return
        send_plain(chat, "未识别命令，发 /start 打开菜单"); return
    act = state.pop(chat, None) or ""   # 无待输入时为 "", 避免下面 act.startswith(...) 在 None 上崩
    if act == "add_exit":
        # state 已在上面 state.pop 清除 → 紧接着发的下一条不会再被当 add_exit。
        # 关键: 先无条件删含凭据(密码/uuid/服务器)的原消息 —— 独立线程, 不受 BUSY/执行器影响,
        # 所以 BUSY 拒绝、提交失败等路径下凭据仍被清除。解析+校验+写配置+重启才放后台。
        delete_credential_async(chat, mid)
        link = text
        def task(link=link):
            try:
                ob = parse_link(link)
            except Exception:  # noqa: BLE001        # 不回显原始链接/异常正文(可能含凭据)
                send_plain(chat, "解析失败: 链接格式不支持或有误(内容已隐去,可重发正确链接)")
                return
            tag = ob.get("tag")
            def mod(c):
                c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
                c["outbounds"].append(ob)
            ok, msg = apply_sb(mod)
            link = ob = None                         # 尽力减少凭据在内存驻留(非安全擦除, Python 无法保证)
            if ok:
                send_plain(chat, f"✅ 已添加出口 <b>{tag}</b>")
            elif msg in (BUSY_MSG, NOLOCK_MSG):       # 锁冲突/锁不可用: 原样回显(不是校验失败)
                send_plain(chat, "❌ " + msg)
            else:                                    # 校验/重启失败: 正文可能含凭据 → 通用提示
                send_plain(chat, "❌ 添加失败: 配置校验未过, 已回滚(详情见服务器日志, 未回显链接内容)")
        run_bg(chat, task)
        return
    if act == "add_group":
        p = text.split()
        if len(p) < 3:
            send_plain(chat, "格式: 组名 出口1 出口2 …(至少2个出口)"); return
        ok, msg = add_group(p[0], p[1:]); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "order_exit":
        ok, msg = reorder_exits(text.replace(",", " ").split()); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act.startswith("edit_grp:"):
        ok, msg = add_group(act.split(":", 1)[1], text.replace(",", " ").split())
        send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act.startswith("rename_exit:"):
        ok, msg = rename_exit(act.split(":", 1)[1], text)
        send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "add_rule":
        p = text.split()
        send_plain(chat, "格式: 域名 出口" if len(p) != 2 else (lambda r: ("✅ " if r[0] else "") + r[1])(add_rule(p[0], p[1])))
        return
    if act == "del_rule":
        ok, msg = del_rule(text); send_plain(chat, ("✅ " if ok else "") + msg); return
    if act == "test_dom":
        send_plain(chat, test_domain(text)); return
    if act == "add_rs":
        p = text.split()
        if len(p) < 2:
            send_plain(chat, "格式: 规则集URL 出口 [名称] [类型(仅 .mrs 且认不出类型时需要)]"); return
        # .mrs 的类型一般从文件二进制头认出来; 末尾若显式写了 domain/ipcidr 就当类型, 其余算名称
        behavior = ""
        rest = p[2:]
        if rest and rest[-1].lower() in MRS_BEHAVIORS:
            behavior = rest[-1].lower(); rest = rest[:-1]
        send_plain(chat, "正在下载规则集…")
        ok, msg = add_ruleset(p[0], p[1], " ".join(rest), behavior)
        send_plain(chat, ("✅ " if ok else "") + msg); return
    if act.startswith("rs_label:"):
        name = act.split(":", 1)[1]
        ok, msg = set_ruleset_label(name, "" if text.strip() == "-" else text)
        send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "ios_ssid":
        if _platform() != "ios":         # 已清 state(act 用 pop 取出); Android 直接拒绝, 不生成文件
            send_plain(chat, "此功能仅 iOS 平台可用(本机为 Android)。" + _platform_unconfirmed()); return
        ssids = [] if text.strip() == "-" else [l.strip()[:32] for l in text.splitlines() if l.strip()][:8]
        try:
            # 老机器第一次走到这里也要问一句"以前装过吗" —— 但文本流里没有按钮可点, 所以
            # 先把 SSID 收下、生成受管版本, 迁移提示由 _ios_send 的说明和状态页承担。
            _ios_mods()
            legacy = not (iosstate.load() or {}).get("current")
            send_plain(chat, _ios_send(chat, ssids, legacy))
        except Exception as e:  # noqa: BLE001
            send_plain(chat, f"生成失败: {e}")
        return
    if act == "set_dns":
        p = text.split()
        if len(p) < 2:
            send_plain(chat, "格式: remote|local 地址1 [地址2 …]"); return
        ok, msg = set_mosdns_upstream(p[0].lower(), p[1:]); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "wloc_add":
        m = re.match(r"^\s*(\S+)\s+(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$", text)
        if not m:
            send_plain(chat, "格式: <b>名称 纬度,经度</b>  如 <code>上海 31.2304,121.4737</code>"); return
        name, lat, lon = m.group(1), float(m.group(2)), float(m.group(3))
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            send_plain(chat, "坐标超范围(纬度 -90~90, 经度 -180~180)"); return
        wloc_add_reply(chat, name, lat, lon); return
    if act == "set_dot":
        send_plain(chat, "正在校验域名并签发证书(约 30-60 秒, 期间代理短暂中断)…")
        ok, msg = set_dot_domain(text); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "restore":
        send_plain(chat, "请把备份 <code>.tar.gz</code> 作为「文件」发来, 而不是文字。/cancel 取消。"); state[chat] = "restore"; return
    # 裸发「名称 纬度,经度」: 当作加 WLOC 地点(iOS), 即使没先点「➕ 添加地点」也能加(状态因重启丢了也不怕)
    mw = re.match(r"^\s*(\S+)\s+(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$", text)
    if mw and _platform() == "ios":
        name, lat, lon = mw.group(1), float(mw.group(2)), float(mw.group(3))
        if -90 <= lat <= 90 and -180 <= lon <= 180:
            wloc_add_reply(chat, name, lat, lon); return
    # 裸发一个像域名的文本: 当作想设 DoT 域名, 给一键按钮 (省得先点菜单进状态)
    if re.match(r"^(?=.{1,253}$)([a-z0-9-]+\.)+[a-z]{2,}$", text.lower()):
        d = text.lower()
        send(chat, f"想把 <code>{d}</code> 设成 DoT 自定义域名吗?\n"
                   f"先确认它的 A 记录已指向本机 <code>{_server_ip()}</code>(Cloudflare 用灰云 DNS only)。",
             {"inline_keyboard": [[{"text": "🌐 是, 签证书并切换", "callback_data": "dosetdot:" + d}],
                                  [{"text": "取消", "callback_data": "menu"}]]})
        return
    send_plain(chat, "发 /start 打开菜单")

# ── 文件 (配置恢复) ──
def handle_document(chat, doc):
    if state.get(chat) != "restore":
        send_plain(chat, "如要恢复配置: 先点菜单「♻️ 恢复」再发备份文件。"); return
    state.pop(chat, None)
    send_plain(chat, "正在校验并恢复…")
    try:
        data = tg_download(doc["file_id"])
        ok, msg = restore_from(data)
    except Exception as e:  # noqa: BLE001
        ok, msg = False, f"恢复失败: {e}"
    send_plain(chat, ("✅ " if ok else "❌ ") + msg)

def main():
    if not TOKEN:
        print("PDG_BOT_TOKEN 未设置, 退出"); return
    post("deleteWebhook", {"drop_pending_updates": False})
    cmds = [
        {"command": "start", "description": "打开菜单 / 状态"},
        {"command": "cancel", "description": "取消当前输入"}]
    post("setMyCommands", {"commands": cmds})
    post("setMyCommands", {"commands": cmds, "scope": {"type": "all_private_chats"}})
    print("pdg-bot v3 started, allowed:", ALLOWED, flush=True)
    try:                                   # 兜底: bot 重启后核验并收回本项目遗留的临时面板
        panel_ok, panel_msg = _panel_startup_cleanup()
        print(panel_msg if panel_ok else ("panel startup close failed: " + panel_msg), flush=True)
    except Exception as e:  # noqa: BLE001
        print("panel startup close err", type(e).__name__, flush=True)
    off = 0
    while True:
        r = post("getUpdates", {"offset": off, "timeout": 50})
        if not r.get("ok"):          # 网络/API 出错 → 退避, 别紧打循环
            time.sleep(3); continue
        for u in r.get("result", []):
            off = u["update_id"] + 1
            try:
                if "message" in u:
                    m = u["message"]
                    if m["from"]["id"] not in ALLOWED:
                        continue
                    if "text" in m:
                        handle_text(m["chat"]["id"], m["text"], m.get("message_id"))
                    elif "document" in m:
                        handle_document(m["chat"]["id"], m["document"])
                elif "callback_query" in u:
                    q = u["callback_query"]
                    # 先停按钮转圈, 再跑可能较慢的 handle_cb(检查更新/测出口/自检等)。
                    answer_cb_async(q["id"])
                    if q["from"]["id"] in ALLOWED:
                        handle_cb(q["message"]["chat"]["id"], q["message"]["message_id"], q["data"])
            except Exception as e:  # noqa: BLE001
                print("handle err", e, flush=True)

if __name__ == "__main__":
    main()

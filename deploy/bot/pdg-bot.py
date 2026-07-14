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
import base64, contextlib, fcntl, hashlib, http.client, io, json, os, plistlib, re, shutil, socket, subprocess, tarfile, tempfile, threading, time, uuid
import concurrent.futures
import urllib.parse, urllib.request, urllib.error
from collections import Counter

TOKEN = os.environ.get("PDG_BOT_TOKEN", "")
ALLOWED = {int(x) for x in os.environ.get("PDG_BOT_ALLOWED", "").replace(" ", "").split(",") if x}
SB = "/etc/sing-box/config.json"
RS_DIR = "/etc/sing-box/rs"
MOSDNS_CONF = "/etc/mosdns/config.yaml"
MOSDNS_DIRECT = "/etc/mosdns/rules/custom_direct.txt"
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
LOCKFILE = "/run/privdns-gateway.lock"           # 与 pdg update/rollback 共用, 防跨进程并发改配置
BUSY_MSG = "已有配置操作正在执行,请稍候再试。"   # apply_sb 拿不到锁(进程内或跨进程)时的安全返回

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
    两把锁任一被占 → yield False(立即友好返回, 绝不阻塞主轮询); 锁文件不可用 → 退化为仅进程内串行。"""
    if not _cfg_lock.acquire(blocking=False):    # 非阻塞: 本进程已有配置操作在跑 → 立刻让路, 不卡主循环
        yield False
        return
    try:
        try:
            f = open(LOCKFILE, "w")
        except OSError:
            yield True                           # 无法打开锁文件(权限/路径) → 只做进程内串行
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
        "client": (f"📱 <b>客户端接入</b>\nAndroid 私密DNS 填: <code>{_dot_host()}</code>\niOS 点下方生成描述文件:", [
            [{"text": "📱 iOS 描述文件", "callback_data": "ios"}],
            [{"text": "🌐 DoT 自定义域名", "callback_data": "setdot"}],
            [{"text": "✈️ Telegram 出口", "callback_data": "tgexit"}]]),
        "ops": ("🛠 <b>运维</b> — 选一项:", [
            [{"text": "🔄 重启服务", "callback_data": "restart"}, {"text": "📦 更新规则库", "callback_data": "updgeo"}],
            [{"text": "💾 备份", "callback_data": "backup"}, {"text": "♻️ 恢复", "callback_data": "restore"}],
            [{"text": "🌐 DNS 上游", "callback_data": "dnsup"}, {"text": "🚀 TFO", "callback_data": "tfo"}],
            [{"text": "📊 观测面板", "callback_data": "panel"}]]),
    }
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

def edit(chat, mid, text, kb=None):
    p = {"chat_id": chat, "message_id": mid, "text": text, "parse_mode": "HTML",
         "reply_markup": kb or MENU, "disable_web_page_preview": True}
    if post("editMessageText", p).get("ok"):
        return
    p.pop("parse_mode", None)        # 先退回纯文本重试编辑(原地保留键盘)
    if post("editMessageText", p).get("ok"):
        return
    send(chat, text, kb)             # 仍不行(如消息已删)再发新消息

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

def _write(c):
    t = SB + ".tmp"
    with open(t, "w") as f:
        json.dump(c, f, ensure_ascii=False, indent=2)
    os.chmod(t, 0o600)        # config.json 含出口密码/uuid, 收紧到 600
    os.replace(t, SB)

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

def apply_sb(modify):
    # 串行化配置写 + 与 pdg update/rollback 用同一把 flock 协调(拿不到锁友好返回, 不卡死)。
    with _cfg_guard() as got:
        if not got:
            return False, BUSY_MSG
        shutil.copy(SB, SB + ".botbak"); os.chmod(SB + ".botbak", 0o600)
        wrote = False
        try:
            c = load(); modify(c); _write(c); wrote = True   # 写了新配置后, 任何异常都必须还原
            chk = sh(["sing-box", "check", "-c", SB])
            if chk.returncode != 0:
                shutil.copy(SB + ".botbak", SB)   # 运行中的 sing-box 没动过(check 只在文件上做), 还原文件即可, 不必重启
                return False, "配置校验失败,已回滚:\n" + (chk.stdout + chk.stderr)[-400:]
            sh(["systemctl", "reset-failed", "sing-box"])   # 清掉 start-limit 计数: 连改多条(如连删域名)快速多次重启不会触发限速锁死
            r = sh(["systemctl", "restart", "sing-box"])
            if r.returncode != 0 or not _svc_active("sing-box"):   # 没起来/起来又崩, 还原文件再重启一次, 别把代理留在挂掉状态
                shutil.copy(SB + ".botbak", SB)
                sh(["systemctl", "reset-failed", "sing-box"]); sh(["systemctl", "restart", "sing-box"])
                return False, "重启 sing-box 失败, 已还原上一份配置:\n" + (r.stdout + r.stderr)[-300:]
            return True, ""
        except _PanelOwnershipError:
            return False, "检测到自定义 clash_api 配置, 为避免覆盖已保持原样"
        except Exception as e:  # noqa: BLE001
            # check/restart 超时(TimeoutExpired)、modify/写盘等异常: 绝不留未验证的新配置。
            # 已写过新配置就还原备份并尽力重启回已知good; 返回失败(TG Bot 会据此提示), 不外泄异常正文。
            if wrote:
                try:
                    shutil.copy(SB + ".botbak", SB)
                    sh(["systemctl", "reset-failed", "sing-box"]); sh(["systemctl", "restart", "sing-box"])
                except Exception:  # noqa: BLE001
                    pass
            return False, "应用配置异常(%s),已还原上一份配置。" % type(e).__name__

# 可作出口的代理协议(决定哪些出站算"出口": 可选默认/故障组成员/测出口/删除)。sing-box 支持的都列上。
PROXY_TYPES = ("shadowsocks", "vmess", "trojan", "vless", "hysteria", "hysteria2",
               "tuic", "anytls", "shadowtls", "socks", "http")

def proxy_outbounds(c):
    return [o for o in c["outbounds"] if o.get("type") in PROXY_TYPES]

def exit_tags(c):
    """可作分流目标/默认出口的全部出口 (含 direct 与 urltest 故障组)。"""
    return [o["tag"] for o in c["outbounds"] if o.get("type") in PROXY_TYPES + ("direct", "urltest")]

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
                "自动选最快, 成员故障自动切换。可在「🎯 设默认出口」或分流规则里选它。" if ok else msg)

# ── 直连表 (mosdns) ──
def _read_direct():
    if not os.path.exists(MOSDNS_DIRECT):
        return []
    return [l.strip().replace("domain:", "") for l in open(MOSDNS_DIRECT)
            if l.strip() and not l.startswith("#")]

def _write_direct(domains):
    with open(MOSDNS_DIRECT, "w") as f:
        f.write("# pdg-bot 自定义直连\n" + "".join("domain:" + d + "\n" for d in sorted(set(domains))))
    sh(["systemctl", "restart", "mosdns"])

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
    try:
        lines = open(MOSDNS_CONF).read().splitlines()
    except Exception as e:  # noqa: BLE001
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
        return False, f"没在 mosdns 配置里找到 {tag} 块"
    shutil.copy(MOSDNS_CONF, MOSDNS_CONF + ".botbak")
    with open(MOSDNS_CONF, "w") as f:
        f.write("\n".join(lines) + "\n")
    sh(["systemctl", "restart", "mosdns"])
    if sh(["systemctl", "is-active", "mosdns"]).stdout.strip() != "active":
        shutil.copy(MOSDNS_CONF + ".botbak", MOSDNS_CONF); sh(["systemctl", "restart", "mosdns"])
        return False, "mosdns 重启失败(配置可能不合法), 已回滚"
    return True, f"✅ {which} 上游已设为: {', '.join(addrs)}"

# ── 流媒体/服务解锁: 在「落地出口」与「WDA 解锁」之间整体切换 ──
# WDA 模式: 这些域名 → jp 直出 + 经 mosdns 用解锁 DNS(22.22.22.22)解析到中继(从本机授权 IP 出)。
# 落地模式: 不加规则, 这些域名回落到各自现有分流出口(hk/tw 等)。
# mosdns 侧的 unlock 支(unlock_upstream + geosite_unlock)是常驻的(install/迁移装好), 平时休眠;
# 本函数只在 WDA 模式把域名清单写进 mosdns 的 unlock.txt 与 sing-box 的 rule_set, 并加 sing-box 路由规则。
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

def _wda_on(c=None):
    c = c or load()
    return any(r.get("rule_set") == "unlock" and r.get("outbound") == "jp"
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

def _write_unlock_file(domains):
    """把 domains(可空)写进 mosdns unlock.txt(domain: 前缀); 变了才重启 mosdns(失败回滚)。
    空列表 = 落地模式: 清空文件 → mosdns 解锁支不命中任何域名 = 休眠(本机查询这些域名回落普通上游)。"""
    path = os.path.join(MOSDNS_RULES, "unlock.txt")
    want = "".join("domain:%s\n" % d for d in domains)
    try:
        cur = open(path).read()
    except OSError:
        cur = None
    if cur == want or (want == "" and not cur):
        return True, ""                       # 已是目标(含: 要清空且本来就空/无文件)
    if domains:                               # 只有"写域名"才要求 mosdns 已有解锁支
        try:
            if "unlock_upstream" not in open(MOSDNS_CONF).read():
                return False, "mosdns 还没有解锁支(unlock_upstream)。请先在服务器跑  sudo pdg update  补上再切。"
        except OSError as e:
            return False, f"读 mosdns 配置失败: {e}"
    os.makedirs(MOSDNS_RULES, exist_ok=True)
    if cur is not None:
        shutil.copy(path, path + ".bak")
    open(path, "w").write(want)
    sh(["systemctl", "restart", "mosdns"]); time.sleep(1)
    if sh(["systemctl", "is-active", "mosdns"]).stdout.strip() != "active":
        if os.path.exists(path + ".bak"):
            shutil.copy(path + ".bak", path)
        sh(["systemctl", "restart", "mosdns"])
        return False, "mosdns 重启失败, 已回滚 unlock.txt"
    return True, ""

def set_wda_mode(on):
    was_on = _wda_on()                          # 记下操作前状态: 回滚要还原到它, 而不是无脑清空
    if on:
        if not _wda_authorized():               # 没授权就开 = 流媒体走 jp 直出但拿不到中继, 反而更糟 → 先拦住
            ip = _server_ip()
            return False, ("⚠️ 没在解锁 DNS(%s)上测到本机的中继, <b>先别开 WDA</b>(否则解锁服务拿不到中继, 流媒体反而可能挂)。\n"
                           "常见原因: 没订阅解锁服务 / 没在服务商<b>后台把本机公网 IP <code>%s</code> 加白授权</b> / DNS 不通。\n"
                           "→ 去服务商后台授权本机 IP <code>%s</code>, 再点 🔓。(未改动, 仍走落地出口)"
                           % (UNLOCK_DNS, ip, ip))
        ok, err = _write_unlock_file(WDA_DOMAINS)   # mosdns 侧: 写满解锁清单
        if not ok:
            return False, err
        os.makedirs(RS_DIR, exist_ok=True)
        json.dump({"version": 1, "rules": [{"domain_suffix": WDA_DOMAINS}]},
                  open(os.path.join(RS_DIR, "unlock.json"), "w"), ensure_ascii=False)
    def mod(c):
        c["route"].setdefault("rule_set", [])
        c["route"]["rule_set"] = [r for r in c["route"]["rule_set"] if r.get("tag") != "unlock"]
        c["route"]["rules"] = [r for r in c["route"]["rules"] if r.get("rule_set") != "unlock"]
        if on:
            c["route"]["rule_set"].append({"tag": "unlock", "type": "local", "format": "source",
                                           "path": os.path.join(RS_DIR, "unlock.json")})
            idx = 1 if c["route"]["rules"] and c["route"]["rules"][0].get("action") == "reject" else 0
            c["route"]["rules"].insert(idx, {"rule_set": "unlock", "outbound": "jp"})
    ok, msg = apply_sb(mod)
    if not ok:
        if on and not was_on:                    # 仅"本来关→这次想开"失败才清回空; 本来就开则 apply_sb 已还原成带规则的旧配置, 保持 unlock.txt
            okc, errc = _write_unlock_file([])
            if not okc:                          # 连回滚清空都失败 → 别静默, 明确告知 mosdns 侧可能残留
                msg += "\n⚠️ 且回滚清空 unlock.txt 也失败(" + errc + "): mosdns 侧可能仍残留解锁清单, 请重试或手动清空。"
        return False, msg
    if on:
        return True, ("✅ 已切到【🔓 WDA 解锁】: %d 个域名走 WDA(jp 直出 + 22.22.22.22 中继)。\n"
                      "其余流量照常分流。哪个服务在 WDA 下不灵, 切回【落地出口】即可。") % len(WDA_DOMAINS)
    # 关闭: sing-box 规则已撤; 再清空 mosdns unlock.txt, 让解锁支彻底休眠(否则本机解析这些域名仍走解锁 DNS)
    okc, errc = _write_unlock_file([])
    if okc:
        return True, "✅ 已切到【🛬 落地出口】: 解锁域名回落各自出口(hk/tw), mosdns 解锁清单已清空。"
    return True, ("✅ 已切到【🛬 落地出口】(sing-box 规则已撤)。\n"
                  "⚠️ 但清空 mosdns unlock.txt 失败(" + errc + "): 本机解析这些域名可能仍走解锁 DNS, 可再点一次 🛬 或手动清空。")

# ── TCP Fast Open ──
def _tfo_on(c):
    obs = [o for o in c["outbounds"] if o.get("type") in PROXY_TYPES]
    return bool(obs) and all(o.get("tcp_fast_open") for o in obs)

def set_tfo(on):
    def mod(c):
        for o in c["outbounds"]:
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
    ok, msg = apply_sb(mod)
    if ok and on:
        sh(["sysctl", "-w", "net.ipv4.tcp_fastopen=3"])
        try:
            with open("/etc/sysctl.d/99-pdg-tfo.conf", "w") as f:
                f.write("net.ipv4.tcp_fastopen=3\n")
        except Exception:  # noqa: BLE001
            pass
    return ok, ((f"✅ TFO 已{'开启' if on else '关闭'}(出口+入口)\n"
                 "降到落地的握手延迟; 需落地端也支持, 否则自动回落普通握手。") if ok else msg)

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

def _save_rs_meta(m):
    os.makedirs(os.path.dirname(RS_META), exist_ok=True)
    json.dump(m, open(RS_META, "w"), ensure_ascii=False, indent=2)

def _fetch_surge(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pdg-bot"})
    with urllib.request.urlopen(req, timeout=30) as r:
        text = r.read().decode("utf-8", "ignore")
    dom, suf, kw, ip = [], [], [], []
    for line in text.splitlines():
        line = line.split("#", 1)[0].split("//", 1)[0].strip()
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

def add_ruleset(url, target, label=""):
    c = load()
    if target not in exit_tags(c):
        return False, f"出口 {target} 不存在; 可选: {', '.join(exit_tags(c))}"
    low = url.lower().split("?", 1)[0]
    if low.endswith(".mrs"):
        return False, ".mrs 是 mihomo 二进制格式, sing-box 不支持。请用 .list/.txt 文本规则, 或 sing-box .srs。"
    name = "rs_" + hashlib.sha1(url.encode()).hexdigest()[:8]
    os.makedirs(RS_DIR, exist_ok=True)
    try:
        if low.endswith(".srs"):
            path = os.path.join(RS_DIR, name + ".srs"); fmt = "binary"
            open(path, "wb").write(_fetch_bytes(url)); count = None; warn = ""
        else:
            path = os.path.join(RS_DIR, name + ".json"); fmt = "source"
            count, ip_only = _build_source(url, path)
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
    ok, msg = apply_sb(mod)
    if ok:
        m = _rs_meta(); m[name] = {"url": url, "outbound": target, "format": fmt,
                                   "path": path, "count": count}
        if label.strip():
            m[name]["label"] = label.strip()[:40]
        _save_rs_meta(m)
        cntdesc = f"{count} 条" if count is not None else "sing-box .srs"
        return True, f"规则集已添加 → {target}（{cntdesc}，{label.strip() or name}）" + warn
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
    _save_rs_meta(m)
    return True, f"✅ 规则集名称已设为「{label or name}」"

def _rs_items():
    """[(name, 显示文字)] 供选择键盘用。"""
    return [(n, (i.get("label") or n) + f" · {i.get('count', '?')}条") for n, i in _rs_meta().items()]

def del_ruleset(name):
    m = _rs_meta(); info = m.get(name, {}); path = info.get("path")
    label = info.get("label") or name              # 删前取显示名(删完 meta 就没了)
    def mod(cc):
        cc["route"]["rule_set"] = [r for r in cc["route"].get("rule_set", []) if r.get("tag") != name]
        cc["route"]["rules"] = [r for r in cc["route"]["rules"] if r.get("rule_set") != name]
    ok, msg = apply_sb(mod)
    if ok:
        m.pop(name, None); _save_rs_meta(m)
        for p in (path, os.path.join(RS_DIR, name + ".json"), os.path.join(RS_DIR, name + ".srs")):
            try:
                if p:
                    os.remove(p)
            except OSError:
                pass
        return True, f"已删除规则集 {label}"
    return False, msg

def refresh_rulesets():
    """重下并原子替换所有规则集; sing-box check 通过才重启, 坏档自动回滚、不断网(供 bot 与每日定时调用)。"""
    m = _rs_meta(); n = 0; swapped = []   # (path, bak)
    for name, info in m.items():
        # 兼容早期缺 format/path 的旧条目 (按 name 回填, 否则刷新会 KeyError)。
        info.setdefault("format", "binary" if str(info.get("path", "")).endswith(".srs") else "source")
        info.setdefault("path", os.path.join(RS_DIR, name + (".srs" if info["format"] == "binary" else ".json")))
        tmp = info["path"] + ".new"
        try:
            if info["format"] == "binary":
                data = _fetch_bytes(info["url"])
                if not data:
                    raise ValueError("空响应")
                open(tmp, "wb").write(data)
            else:
                info["count"] = _build_source(info["url"], tmp)[0]   # 先写临时文件
            n += 1
        except Exception as e:  # noqa: BLE001
            print("refresh rs", name, e)
            try:
                os.remove(tmp)
            except OSError:
                pass
    # 原子替换(留 .bak 以便整体回滚)
    for name, info in m.items():
        tmp = info["path"] + ".new"
        if not os.path.exists(tmp):
            continue
        if os.path.exists(info["path"]):
            shutil.copy(info["path"], info["path"] + ".bak")
            swapped.append((info["path"], info["path"] + ".bak"))
        os.replace(tmp, info["path"])
    if n == 0:
        return 0
    if sh(["sing-box", "check", "-c", SB]).returncode != 0:   # 坏档 → 回滚, 不重启(不断网)
        for path, bak in swapped:
            shutil.copy(bak, path)
        print("refresh rs: sing-box check 失败, 已回滚, 不重启")
        return 0
    # 先重启加载新规则集, 确认 sing-box 真的 active 再删 .bak; 起不来则还原旧规则集重启, 不断网。
    sh(["systemctl", "reset-failed", "sing-box"]); sh(["systemctl", "restart", "sing-box"])
    if not _svc_active("sing-box"):
        for path, bak in swapped:
            shutil.copy(bak, path)        # 还原旧规则集
        sh(["systemctl", "reset-failed", "sing-box"]); sh(["systemctl", "restart", "sing-box"])
        if _svc_active("sing-box"):       # 确认旧服务真的恢复, 再清备份
            for _, bak in swapped:
                try:
                    os.remove(bak)
                except OSError:
                    pass
            print("refresh rs: 新规则集致 sing-box 起不来, 已还原旧规则集并恢复")
        else:                             # 连旧档都起不来 → 保留 .bak 备查, 不再删
            print("refresh rs: 还原旧规则集后仍未 active, 保留 .bak 备查")
        return 0
    for _, bak in swapped:                 # 确认 active 后再清备份
        try:
            os.remove(bak)
        except OSError:
            pass
    _save_rs_meta(m)
    return n

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
    lines = []
    for t in tags:
        q = urllib.parse.quote(t, safe="")
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
            parts.append("📈 <b>实时(sing-box 本会话, 重启清零)</b>\n"
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
                  f"<pre>{_esc(log)}</pre>\n确认后后台执行 pdg update → 更新到 {tgt}(约 30-60 秒, bot 自动重启回来)。")

def start_update():
    """在独立的 systemd 瞬时单元里跑 pdg update, 不受 pdg-bot 自身重启影响。"""
    try:
        r = subprocess.run(["systemd-run", "--collect", "/usr/local/bin/pdg", "update"],
                           capture_output=True, text=True, timeout=15)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False

# ── 单条规则增删 ──
def add_rule(domain, target):
    domain = domain.strip().lstrip(".").lower()
    if not re.match(r"^[a-z0-9.-]+$", domain):
        return False, "域名格式不对"
    if target in ("direct", "直连"):
        _write_direct(_read_direct() + [domain]); return True, f"已把 {domain} 设为直连"
    c = load()
    if target not in exit_tags(c):
        return False, f"出口 {target} 不存在; 可选: {', '.join(exit_tags(c))} 或 direct"

    def mod(cc):
        for r in cc["route"]["rules"]:
            if r.get("outbound") == target and "rule_set" not in r:
                r.setdefault("domain_suffix", [])
                if domain not in r["domain_suffix"]:
                    r["domain_suffix"].append(domain)
                return
        idx = 1 if cc["route"]["rules"] and cc["route"]["rules"][0].get("action") == "reject" else 0
        cc["route"]["rules"].insert(idx, {"domain_suffix": [domain], "outbound": target})
    ok, msg = apply_sb(mod)
    return ok, (f"已把 {domain} → {target}" if ok else msg)

def del_rule(domain):
    domain = domain.strip().lstrip(".").lower(); removed = []
    c = load()
    if any(domain in r.get(k, []) for r in c["route"]["rules"] for k in ("domain_suffix", "domain")):
        def mod(cc):
            for r in cc["route"]["rules"]:
                for k in ("domain_suffix", "domain"):
                    if domain in r.get(k, []):
                        r[k] = [d for d in r[k] if d != domain]
            cc["route"]["rules"] = [r for r in cc["route"]["rules"]
                                    if r.get("action") or "outbound" not in r or r.get("rule_set")
                                    or r.get("domain_suffix") or r.get("domain")
                                    or r.get("domain_keyword") or r.get("ip_cidr")]
        apply_sb(mod); removed.append("出口规则")
    if domain in _read_direct():
        _write_direct([d for d in _read_direct() if d != domain]); removed.append("直连表")
    return (bool(removed), f"已删除 {domain} ({'+'.join(removed)})" if removed else f"未找到含 {domain} 的规则")

def deletable_domains():
    """可删的单域名规则: [(域名, 显示文字)]。含各出口的 domain(_suffix) 与自定义直连表。"""
    c = load(); items = []
    for r in c["route"]["rules"]:
        if "outbound" not in r or r.get("rule_set"):
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
    def mod(cc):
        for r in cc["route"]["rules"]:
            for k in ("domain_suffix", "domain"):
                if r.get(k):
                    r[k] = [d for d in r[k] if d not in domains]
        cc["route"]["rules"] = [r for r in cc["route"]["rules"]
                                if r.get("action") or "outbound" not in r or r.get("rule_set")
                                or r.get("domain_suffix") or r.get("domain")
                                or r.get("domain_keyword") or r.get("ip_cidr")]
    ok, msg = apply_sb(mod)
    if not ok:
        return False, msg
    cur = _read_direct(); hit = [x for x in cur if x in domains]
    if hit:
        _write_direct([x for x in cur if x not in domains])   # 直连表改 mosdns 文件(与原 del_rule 一致, 不重启 mosdns)
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
    ok, msg = apply_sb(mod)
    if not ok:
        return False, msg
    m = _rs_meta(); dirty = False          # 规则集元数据也记着目标出口, 同步掉, 免得日后误导
    for info in m.values():
        if info.get("outbound") == old:
            info["outbound"] = new; dirty = True
    if dirty:
        _save_rs_meta(m)
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
        res += "\n<i>(没探到 DNS 结果, 直连/代理未实测; 以上为 sing-box 规则模拟)</i>"
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
    live = f"/etc/letsencrypt/live/{domain}"
    try:
        os.makedirs(CERT_DIR, exist_ok=True)
        shutil.copy(f"{live}/fullchain.pem", os.path.join(CERT_DIR, "fullchain.pem"))
        shutil.copy(f"{live}/privkey.pem", os.path.join(CERT_DIR, "privkey.pem"))
        os.chmod(os.path.join(CERT_DIR, "fullchain.pem"), 0o644)
        os.chmod(os.path.join(CERT_DIR, "privkey.pem"), 0o600)
        with open("/opt/pdg-bot/dot-domain", "w") as f:
            f.write(domain + "\n")
    except Exception as e:  # noqa: BLE001
        return False, f"证书已签发但部署失败: {e}"
    sh(["systemctl", "restart", "mosdns"])
    global _DOT_HOST
    _DOT_HOST = None  # 让 _dot_host() 重新读新证书 CN
    return True, (f"✅ DoT 域名已设为 <b>{domain}</b>\n"
                  f"• 手机私密 DNS 改成: <code>{domain}</code>\n"
                  "• 证书已签发, certbot.timer 自动续期\n"
                  "• iOS: 重新生成一次「📱 iOS 描述文件」即可(自动用新域名)")

# ── iOS 描述文件 ──
def _ios_profile(ssids=()):
    """ssids 非空时在 OnDemandRules 最前插一条「命中这些 SSID 的 Wi-Fi 强制直连(不启用 DoT)」;
    其余 Wi-Fi/蜂窝仍按模板里的 :81 探测判定。用 plistlib 插入, SSID 含 &<> 等也不会破 XML。"""
    if not os.path.exists(IOS_TMPL):
        raise FileNotFoundError("缺少模板 " + IOS_TMPL)
    t = open(IOS_TMPL).read()
    raw = (t.replace("__DOT_HOST__", _dot_host())
            .replace("__JP_IP__", _server_ip())
            .replace("__UUID1__", str(uuid.uuid4()).upper())
            .replace("__UUID2__", str(uuid.uuid4()).upper())).encode()
    if not ssids:
        return raw
    p = plistlib.loads(raw)
    p["PayloadContent"][0]["OnDemandRules"].insert(
        0, {"InterfaceTypeMatch": "WiFi", "SSIDMatch": list(ssids), "Action": "Disconnect"})
    return plistlib.dumps(p)

# ── 配置备份 / 恢复 ──
BACKUP_FILES = [SB, MOSDNS_CONF, MOSDNS_DIRECT, RS_META]
RESTORE_MAP = {
    "etc/sing-box/config.json": SB,
    "etc/mosdns/config.yaml": MOSDNS_CONF,
    "etc/mosdns/rules/custom_direct.txt": MOSDNS_DIRECT,
    "opt/pdg-bot/rulesets.json": RS_META,
}

def backup_blob():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for p in BACKUP_FILES:
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
    """取一对 sing-box/mosdns 配置里的「本机身份」: (server_ip, internal_cidr, cert_dir)。"""
    ip = cidr = certdir = None
    try:
        c = json.load(open(sb_path))
        for r in c.get("route", {}).get("rules", []):
            if r.get("action") == "reject":
                for x in r.get("ip_cidr", []):
                    if x.endswith("/32") and not x.startswith("127."):
                        ip = x.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    try:
        t = open(mos_path).read()
        m = re.search(r'ips:\s*\[\s*"([^"]+)"', t); cidr = m.group(1) if m else None
        m = re.search(r'cert:\s*"([^"]+)"', t); certdir = os.path.dirname(m.group(1)) if m else None
        if not ip:
            m = re.search(r'black_hole\s+([0-9.]+)', t); ip = m.group(1) if m else None
    except Exception:  # noqa: BLE001
        pass
    return ip, cidr, certdir

def restore_from(data):
    try:
        tar = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except Exception:  # noqa: BLE001
        return False, "不是有效的 .tar.gz 备份文件"
    tmp = tempfile.mkdtemp(prefix="pdgrs")
    try:
        for m in tar.getmembers():
            if m.name.startswith("/") or ".." in m.name.split("/"):
                continue
            try:
                tar.extract(m, tmp)
            except Exception:  # noqa: BLE001
                pass
        newsb = os.path.join(tmp, "etc/sing-box/config.json")
        newmos = os.path.join(tmp, "etc/mosdns/config.yaml")
        if not os.path.exists(newsb):
            return False, "备份里没有 sing-box 配置, 拒绝恢复"
        # 机器感知: 用「本机」身份覆盖备份带来的 server_ip / 内网卡段 / 证书路径。
        # 这样跨机导入(如把 .153 的备份导到 .200)只搬出口+分流+规则集, 不会把别人的 IP/证书路径搬来搞错位。
        cur = _machine_id(SB, MOSDNS_CONF)
        bak = _machine_id(newsb, newmos)
        kept = []
        subs = [(bak[i], cur[i]) for i in range(3) if bak[i] and cur[i] and bak[i] != cur[i]]
        if subs:
            kept = [cur[i] for i in range(3) if bak[i] and cur[i] and bak[i] != cur[i]]
            for f in (newsb, newmos):
                if os.path.exists(f):
                    s = open(f).read()
                    for old, new in subs:
                        s = s.replace(old, new)
                    open(f, "w").write(s)
        # 面板是临时运行态，不随备份恢复。只净化本项目受管形态，自定义 clash_api 保持原样。
        cfg = json.load(open(newsb))
        if _panel_sanitize_config(cfg):
            json.dump(cfg, open(newsb, "w"), ensure_ascii=False, indent=2)
        # 校验前把 rule_set 的绝对路径临时指向解包出来的 rs/ —— 否则 check 会去找真实位置
        # (备份里带着这些 rs 文件, 但此刻还没恢复到 /etc/sing-box/rs/, 直接 check 会 "no such file")。
        checksb = newsb
        try:
            cfg = json.load(open(newsb))
            changed = False
            for rs in cfg.get("route", {}).get("rule_set", []):
                p = rs.get("path", "")
                cand = os.path.join(tmp, p.lstrip("/")) if p.startswith("/") else ""
                if cand and os.path.exists(cand):
                    rs["path"] = cand; changed = True
            if changed:
                checksb = newsb + ".check"
                json.dump(cfg, open(checksb, "w"), ensure_ascii=False)
        except Exception:  # noqa: BLE001
            pass
        chk = sh(["sing-box", "check", "-c", checksb])
        if chk.returncode != 0:
            return False, "备份的 sing-box 配置校验失败:\n" + (chk.stdout + chk.stderr)[-300:]
        ts = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy(SB, SB + ".pre-restore-" + ts)
        restored = []
        for arc, dst in RESTORE_MAP.items():
            src = os.path.join(tmp, arc)
            if os.path.exists(src):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy(src, dst); restored.append(os.path.basename(dst))
        src_rs = os.path.join(tmp, RS_DIR.lstrip("/"))
        if os.path.isdir(src_rs):
            shutil.rmtree(RS_DIR, ignore_errors=True); shutil.copytree(src_rs, RS_DIR); restored.append("rs/")
        r1 = sh(["systemctl", "restart", "sing-box"])
        if r1.returncode != 0:
            shutil.copy(SB + ".pre-restore-" + ts, SB); sh(["systemctl", "restart", "sing-box"])
            return False, "恢复后 sing-box 启动失败, 已回滚 sing-box"
        sh(["systemctl", "restart", "mosdns"])
        msg = "已恢复: " + ", ".join(restored) + "\n已重启 sing-box + mosdns"
        if subs:
            msg += "\n(跨机导入: 已保留本机身份 " + "、".join(kept) + ", 只搬了出口+分流+规则集)"
        return True, msg
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

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
    _st = sh(["systemctl", "is-active", "mosdns", "sing-box", "pdg-bot"]).stdout.split()
    _states = dict(zip(["mosdns", "sing-box", "pdg-bot"], _st + ["?", "?", "?"]))
    def dot(s):
        return "🟢" if _states.get(s) == "active" else "🔴"
    c = load(); exits = exit_tags(c)
    g = _groups_desc(c)
    final = c["route"].get("final")
    nrules = sum(1 for r in c["route"]["rules"] if r.get("outbound"))
    split = "国内直连" + (f" / {nrules} 条分流规则" if nrules else "") + f" / 其余→{final}"
    return ("🖥 <b>PrivDNS Gateway</b>\n\n"
            f"{dot('mosdns')} mosdns（DNS 分流, 带缓存）\n"
            f"{dot('sing-box')} sing-box（流量出口）\n"
            f"{dot('pdg-bot')} pdg-bot（管理）\n\n"
            f"📡 DoT: <code>{_dot_host()}:853</code>（Android 私密DNS / iOS 描述文件）\n"
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
        edit(chat, mid, "发「<b>组名 出口1 出口2 …</b>」建故障切换组(自动选最快/坏了自动切)。\n"
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
        edit(chat, mid, f"⏳ 正在删除 {len(doms)} 个域名并重启 sing-box…", RULE_BACK)
        ok, msg = del_rules_bulk(doms); del_sel.pop(chat, None)
        edit(chat, mid, msg if ok else ("❌ " + msg), RULE_BACK); return
    if data == "testdom":
        state[chat] = "test_dom"
        edit(chat, mid, "发个域名, 查它走哪个出口/规则(还是国内直连)。\n例: <code>netflix.com</code>\n/cancel 取消。", RULE_BACK); return
    if data == "add_rs":
        state[chat] = "add_rs"
        edit(chat, mid, "发「<b>规则集URL 出口 [名称]</b>」(后缀 .list / .txt / .srs)。\n"
             f"出口: {', '.join(exit_tags(load()))}\n名称可留空(之后用「✏️ 改规则集名」改)。\n"
             "例: <code>https://.../Binance.list tw 币安</code>\n/cancel 取消。", RULE_BACK); return
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
        state[chat] = "ios_ssid"
        edit(chat, mid, "📱 <b>生成 iOS 描述文件</b>\n"
             "Wi-Fi/蜂窝下是否启用私密 DNS 都由 <code>:81</code> 探测自动判定(网络能走到网关才启用)。\n"
             "若有想<b>强制直连</b>的 Wi-Fi(如公司网、探测误判的酒店网), 发它的名字(SSID, 多个则每行一个)再生成;"
             "不需要就点「直接生成」。/cancel 取消。",
             {"inline_keyboard": [[{"text": "⏭ 直接生成", "callback_data": "iosgen"}],
                                  [{"text": "⬅️ 返回客户端", "callback_data": "nav:client"}],
                                  [{"text": "🏠 主菜单", "callback_data": "menu"}]]}); return
    if data == "iosgen":
        state.pop(chat, None)
        edit(chat, mid, "正在生成 iOS 描述文件…", BACK)
        try:
            send_document(chat, "PrivDNS-Gateway.mobileconfig", _ios_profile(),
                          f"📱 iOS/iPadOS 私密DNS 描述文件\nDoT: {_dot_host()}\n"
                          "装法: 存到「文件」App → 点开 → 设置→通用→「已下载描述文件」→ 安装。\n"
                          "Wi-Fi/蜂窝均靠服务器 :81 探测激活, 安装时已自动配好。")
            edit(chat, mid, "✅ 描述文件已发送(见上一条)。", MENU)
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, f"生成失败: {e}", MENU)
        return
    if data == "backup":
        edit(chat, mid, "正在打包配置…", OPS_BACK)
        try:
            fn = "pdg-backup-" + time.strftime("%Y%m%d-%H%M") + ".tar.gz"
            send_document(chat, fn, backup_blob(),
                          "💾 配置备份(含 sing-box 出口密码, 请妥善保存)。\n恢复: 点「♻️ 恢复」后把此文件发回。")
            edit(chat, mid, "✅ 备份已发送(见上一条)。", MENU)
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, f"备份失败: {e}", MENU)
        return
    if data == "restore":
        state[chat] = "restore"
        edit(chat, mid, "把之前「💾 备份」得到的 <code>.tar.gz</code> 作为文件发给我即可恢复"
             "(先 sing-box check, 失败自动回滚)。\n/cancel 取消。", BACK); return
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
        ok, msg = apply_sb(lambda c: None); sh(["systemctl", "restart", "mosdns"])
        edit(chat, mid, "✅ 已重启 sing-box + mosdns" if ok else msg, OPS_BACK); return
    if data == "updgeo":
        edit(chat, mid, "正在更新 geosite + 规则集…", OPS_BACK)
        r = sh(["/bin/bash", UPDATE_SCRIPT]); n = refresh_rulesets()
        edit(chat, mid, (f"✅ geosite 已更新; 规则集刷新 {n} 个" if r.returncode == 0
                         else "geosite 更新失败:\n" + (r.stdout + r.stderr)[-300:]), OPS_BACK); return
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
            state[chat] = "add_rs"; send(chat, "发「<b>规则集URL 出口</b>」（支持 .list / .srs）。/cancel 取消。", BACK); return
        if cmd == "/delexit":
            tags = deletable_tags(load())
            send(chat, "选择删除的出口/组：" if tags else "无可删出口", kb_pick("delx", tags) if tags else BACK); return
        if cmd == "/setfinal":
            send(chat, "默认出口：", kb_pick("fin", exit_tags(load()))); return
        if cmd == "/delrs":
            m = _rs_meta()
            send(chat, "选择删除的规则集：" if m else "无规则集", kb_pick("delrs", list(m.keys())) if m else BACK); return
        if cmd == "/ios":
            try:
                send_document(chat, "PrivDNS-Gateway.mobileconfig", _ios_profile(), "📱 iOS 私密DNS 描述文件"); send_plain(chat, "✅ 已发送")
            except Exception as e:  # noqa: BLE001
                send_plain(chat, f"生成失败: {e}")
            return
        if cmd == "/backup":
            send_document(chat, "pdg-backup-" + time.strftime("%Y%m%d-%H%M") + ".tar.gz", backup_blob(), "💾 配置备份"); return
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
            send_plain(chat, "更新中…"); r = sh(["/bin/bash", UPDATE_SCRIPT]); n = refresh_rulesets()
            send_plain(chat, f"✅ 完成，规则集刷新 {n} 个" if r.returncode == 0 else "更新失败"); return
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
            elif msg == BUSY_MSG:                    # 锁冲突: 安全且准确, 原样回显(不是校验失败)
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
            send_plain(chat, "格式: 规则集URL 出口 [名称]"); return
        send_plain(chat, "正在下载规则集…")
        ok, msg = add_ruleset(p[0], p[1], " ".join(p[2:])); send_plain(chat, ("✅ " if ok else "") + msg); return
    if act.startswith("rs_label:"):
        name = act.split(":", 1)[1]
        ok, msg = set_ruleset_label(name, "" if text.strip() == "-" else text)
        send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "ios_ssid":
        ssids = [] if text.strip() == "-" else [l.strip()[:32] for l in text.splitlines() if l.strip()][:8]
        try:
            send_document(chat, "PrivDNS-Gateway.mobileconfig", _ios_profile(ssids),
                          f"📱 iOS/iPadOS 私密DNS 描述文件\nDoT: {_dot_host()}\n"
                          + (("强制直连 Wi-Fi: " + ", ".join(ssids) + "\n") if ssids else "")
                          + "装法: 存到「文件」App → 点开 → 设置→通用→「已下载描述文件」→ 安装。")
            send_plain(chat, "✅ 已生成" + (f", {len(ssids)} 个 Wi-Fi 设为强制直连" if ssids else ""))
        except Exception as e:  # noqa: BLE001
            send_plain(chat, f"生成失败: {e}")
        return
    if act == "set_dns":
        p = text.split()
        if len(p) < 2:
            send_plain(chat, "格式: remote|local 地址1 [地址2 …]"); return
        ok, msg = set_mosdns_upstream(p[0].lower(), p[1:]); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "set_dot":
        send_plain(chat, "正在校验域名并签发证书(约 30-60 秒, 期间代理短暂中断)…")
        ok, msg = set_dot_domain(text); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "restore":
        send_plain(chat, "请把备份 <code>.tar.gz</code> 作为「文件」发来, 而不是文字。/cancel 取消。"); state[chat] = "restore"; return
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

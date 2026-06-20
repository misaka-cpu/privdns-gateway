#!/usr/bin/env python3
"""PrivDNS Gateway — Telegram 管理 bot v3 (纯标准库, long-poll)。

出口  : 列表 / 添加(ss/vmess/trojan/vless 链接) / 删除 / 设默认出口 / 故障切换组(urltest)
分流  : 规则列表 / 添加(域名→出口|direct) / 删除 / 添加规则集(Surge .list URL→出口) / 删除规则集
诊断  : 状态 / 端到端测出口延迟(clash_api) / 流量统计(clash_api)
运维  : 重启 / 更新规则库(geosite + 规则集) / iOS 描述文件下发 / 配置备份·恢复

UI 原地编辑消息(editMessageText), 不刷屏。改 sing-box 前备份, check 失败自动回滚。
环境变量: PDG_BOT_TOKEN, PDG_BOT_ALLOWED(逗号分隔的 user id)
注: 模块可被 import (供定时任务调用 refresh_rulesets), 此时无需 token。
"""
from __future__ import annotations
import base64, hashlib, http.client, io, json, os, re, shutil, socket, subprocess, tarfile, tempfile, time, uuid
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

# ── Telegram (复用一条 HTTPS 长连接, 省掉每次 TLS 握手 → 按钮响应更快) ──
_conn = None

def post(method, params):
    global _conn
    body = json.dumps(params).encode()
    path = "/bot" + TOKEN + "/" + method
    hdr = {"Content-Type": "application/json", "Connection": "keep-alive"}
    for attempt in (0, 1):                       # 连接断了就重连重试一次
        try:
            if _conn is None:
                _conn = http.client.HTTPSConnection("api.telegram.org", timeout=70)
            _conn.request("POST", path, body, hdr)
            data = _conn.getresponse().read()
            return json.loads(data) if data else {}
        except Exception as e:  # noqa: BLE001
            try:
                if _conn:
                    _conn.close()
            except Exception:  # noqa: BLE001
                pass
            _conn = None
            if attempt:
                print("api", method, e); return {}

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
    [{"text": "📊 状态", "callback_data": "status"}, {"text": "🚦 测出口", "callback_data": "test"},
     {"text": "📈 流量", "callback_data": "traffic"}],
    [{"text": "📤 出口管理", "callback_data": "nav:exit"}, {"text": "📑 分流管理", "callback_data": "nav:rule"}],
    [{"text": "📱 客户端", "callback_data": "nav:client"}, {"text": "🛠 运维", "callback_data": "nav:ops"}],
]}
BACK = {"inline_keyboard": [[{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}

def _nav(key):
    """二级子菜单 (标题, 键盘)。每个子菜单末尾自带「返回主菜单」。"""
    subs = {
        "exit": ("📤 <b>出口管理</b> — 选一项:", [
            [{"text": "📋 列表", "callback_data": "exits"}, {"text": "➕ 添加", "callback_data": "add_exit"},
             {"text": "🗑 删除", "callback_data": "del_exit"}],
            [{"text": "🎯 默认出口", "callback_data": "setfinal"}, {"text": "🔀 故障切换组", "callback_data": "add_grp"}]]),
        "rule": ("📑 <b>分流管理</b> — 选一项:", [
            [{"text": "📋 规则", "callback_data": "rules"}, {"text": "➕ 加规则", "callback_data": "add_rule"},
             {"text": "🗑 删规则", "callback_data": "del_rule"}],
            [{"text": "📚 加规则集", "callback_data": "add_rs"}, {"text": "🗑 删规则集", "callback_data": "del_rs"}]]),
        "client": (f"📱 <b>客户端接入</b>\nAndroid 私密DNS 填: <code>{_dot_host()}</code>\niOS 点下方生成描述文件:", [
            [{"text": "📱 iOS 描述文件", "callback_data": "ios"}],
            [{"text": "🌐 DoT 自定义域名", "callback_data": "setdot"}]]),
        "ops": ("🛠 <b>运维</b> — 选一项:", [
            [{"text": "🔄 重启服务", "callback_data": "restart"}, {"text": "📦 更新规则库", "callback_data": "updgeo"}],
            [{"text": "💾 备份", "callback_data": "backup"}, {"text": "♻️ 恢复", "callback_data": "restore"}],
            [{"text": "🌐 DNS 上游", "callback_data": "dnsup"}, {"text": "🚀 TFO", "callback_data": "tfo"}]]),
    }
    title, rows = subs[key]
    return title, {"inline_keyboard": rows + [[{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}

def send(chat, text, kb=None):
    post("sendMessage", {"chat_id": chat, "text": text, "parse_mode": "HTML",
                         "reply_markup": kb or MENU, "disable_web_page_preview": True})

def send_plain(chat, text):
    """纯文本回复, 不挂任何键盘 (操作结果/确认用, 避免每次刷出整排菜单)。"""
    post("sendMessage", {"chat_id": chat, "text": text, "parse_mode": "HTML",
                         "disable_web_page_preview": True})

def edit(chat, mid, text, kb=None):
    r = post("editMessageText", {"chat_id": chat, "message_id": mid, "text": text, "parse_mode": "HTML",
                                 "reply_markup": kb or MENU, "disable_web_page_preview": True})
    if not r.get("ok"):
        send(chat, text, kb)

def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180)

# ── clash_api (sing-box experimental) ──
def clash_get(path):
    with urllib.request.urlopen(CLASH + path, timeout=12) as r:
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
    os.replace(t, SB)

def apply_sb(modify):
    shutil.copy(SB, SB + ".botbak")
    c = load(); modify(c); _write(c)
    chk = sh(["sing-box", "check", "-c", SB])
    if chk.returncode != 0:
        shutil.copy(SB + ".botbak", SB); sh(["systemctl", "restart", "sing-box"])
        return False, "配置校验失败,已回滚:\n" + (chk.stdout + chk.stderr)[-400:]
    r = sh(["systemctl", "restart", "sing-box"])
    return r.returncode == 0, (r.stdout + r.stderr)[-300:]

PROXY_TYPES = ("shadowsocks", "vmess", "trojan", "vless")

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
        return _parse_vless(link)
    raise ValueError("只支持 ss:// / vmess:// / trojan:// / vless:// 链接")

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

def _tls_block(server_name, insecure=False):
    b = {"enabled": True}
    if server_name:
        b["server_name"] = server_name
    if insecure:
        b["insecure"] = True
    return b

def _transport(net, host, path):
    if net in ("ws", "websocket"):
        t = {"type": "ws", "path": path or "/"}
        if host:
            t["headers"] = {"Host": host}
        return t
    if net == "grpc":
        return {"type": "grpc", "service_name": (path or "").lstrip("/")}
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
    tr = _transport(q.get("type", "tcp"), q.get("host"), q.get("path"))
    if tr:
        ob["transport"] = tr
    return ob

def _parse_vless(link):
    u = urllib.parse.urlparse(link); q = _qs(u)
    ob = {"type": "vless", "tag": _tag(urllib.parse.unquote(u.fragment), u.hostname, u.port),
          "server": u.hostname, "server_port": u.port or 443, "uuid": u.username, "flow": q.get("flow", "")}
    if not ob["flow"]:
        ob.pop("flow")
    if q.get("security") in ("tls", "reality", "xtls"):
        ob["tls"] = _tls_block(q.get("sni") or u.hostname, q.get("allowInsecure") in ("1", "true"))
    tr = _transport(q.get("type", "tcp"), q.get("host"), q.get("path"))
    if tr:
        ob["transport"] = tr
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
        cc["outbounds"] = [o for o in cc["outbounds"] if o.get("tag") != name]
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
                    lines[j] = indent + "args: { upstreams: [ %s ] }" % items
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

def add_ruleset(url, target):
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
                                   "path": path, "count": count}; _save_rs_meta(m)
        cntdesc = f"{count} 条" if count is not None else "sing-box .srs"
        return True, f"规则集已添加 → {target}（{cntdesc}，{name}）" + warn
    return False, msg

def del_ruleset(name):
    m = _rs_meta(); path = m.get(name, {}).get("path")
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
        return True, f"已删除规则集 {name}"
    return False, msg

def refresh_rulesets():
    """重新下载并重建所有规则集 (供 bot 与定时任务调用; 无需 token)。"""
    m = _rs_meta(); n = 0
    for name, info in m.items():
        # 兼容早期缺 format/path 的旧条目 (按 name 回填, 否则刷新会 KeyError)。
        info.setdefault("format", "binary" if str(info.get("path", "")).endswith(".srs") else "source")
        info.setdefault("path", os.path.join(RS_DIR, name + (".srs" if info["format"] == "binary" else ".json")))
        try:
            if info.get("format") == "binary":
                open(info["path"], "wb").write(_fetch_bytes(info["url"]))
            else:
                info["count"] = _build_source(info["url"], info["path"])[0]
            n += 1
        except Exception as e:  # noqa: BLE001
            print("refresh rs", name, e)
    if m:
        _save_rs_meta(m); sh(["systemctl", "restart", "sing-box"])
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
    tags = exit_tags(c)
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

def traffic_text():
    if not clash_up():
        return "clash_api 未响应 (刚重启请稍候重试)。"
    try:
        d = clash_get("/connections")
    except Exception as e:  # noqa: BLE001
        return f"读取连接失败: {e}"
    conns = d.get("connections") or []
    cnt, up, dn = Counter(), Counter(), Counter()
    for cn in conns:
        chain = cn.get("chains") or []
        tag = chain[0] if chain else "?"
        cnt[tag] += 1; up[tag] += cn.get("upload", 0); dn[tag] += cn.get("download", 0)
    lines = [f"• <b>{t}</b>: {cnt[t]}条  ↑{_fmt_bytes(up[t])} ↓{_fmt_bytes(dn[t])}"
             for t, _ in cnt.most_common()]
    return ("📈 <b>流量统计</b>\n"
            f"累计 ↑{_fmt_bytes(d.get('uploadTotal'))}  ↓{_fmt_bytes(d.get('downloadTotal'))}\n"
            f"活跃连接: {len(conns)}\n" + ("按出口:\n" + "\n".join(lines) if lines else "(当前无活跃连接)"))

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
             "--non-interactive", "--agree-tos", "--keep-until-expiring",
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
def _ios_profile():
    if not os.path.exists(IOS_TMPL):
        raise FileNotFoundError("缺少模板 " + IOS_TMPL)
    t = open(IOS_TMPL).read()
    return (t.replace("__DOT_HOST__", _dot_host())
             .replace("__JP_IP__", _server_ip())
             .replace("__UUID1__", str(uuid.uuid4()).upper())
             .replace("__UUID2__", str(uuid.uuid4()).upper())).encode()

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
                tar.add(p, arcname=p.lstrip("/"))
        if os.path.isdir(RS_DIR):
            tar.add(RS_DIR, arcname=RS_DIR.lstrip("/"))
    return buf.getvalue()

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
        if not os.path.exists(newsb):
            return False, "备份里没有 sing-box 配置, 拒绝恢复"
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
        return True, "已恢复: " + ", ".join(restored) + "\n已重启 sing-box + mosdns"
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
            + f"🎯 默认出口(其余国际): <b>{c['route'].get('final')}</b>\n"
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
            lines.append(f'→ <b>{r["outbound"]}</b>: [规则集 {r["rule_set"]} · {info.get("count","?")}条]')
        else:
            doms = r.get("domain_suffix", []) + r.get("domain", [])
            if doms:
                lines.append(f'→ <b>{r["outbound"]}</b>: ' + ", ".join(doms[:12]) + (" …" if len(doms) > 12 else ""))
    txt = "分流规则:\n" + ("\n".join(lines) or f"(无显式规则, 其余→{c['route'].get('final')})")
    d = _read_direct()
    if d:
        txt += "\n\n自定义直连: " + ", ".join(d[:20])
    return txt

def kb_pick(prefix, tags):
    rows = [[{"text": t, "callback_data": f"{prefix}:{t}"}] for t in tags]
    rows.append([{"text": "⬅️ 返回", "callback_data": "menu"}])
    return {"inline_keyboard": rows}

# ── 回调 (原地编辑) ──
def handle_cb(chat, mid, data):
    if data in ("menu", "status"):
        edit(chat, mid, status_text(), MENU); return
    if data.startswith("nav:"):
        title, kb = _nav(data[4:]); edit(chat, mid, title, kb); return
    if data == "setdot":
        state[chat] = "set_dot"
        edit(chat, mid, "发你的自定义 DoT 域名(先把它的 A 记录指向本机, Cloudflare 用「灰云 DNS only」)。\n"
             f"本机 IP: <code>{_server_ip()}</code>\n例: <code>dot.example.com</code>\n"
             "我会自动签 Let's Encrypt 证书并切换(过程会短暂中断代理约 30 秒)。/cancel 取消。", BACK); return
    if data.startswith("dosetdot:"):
        domain = data[9:]
        edit(chat, mid, f"正在为 <code>{domain}</code> 校验 A 记录并签证书(约 30-60 秒, 代理短暂中断)…", None)
        ok, msg = set_dot_domain(domain); edit(chat, mid, (msg if ok else "❌ " + msg), MENU); return
    if data == "test":
        edit(chat, mid, "测试中…", None); edit(chat, mid, test_exits(), BACK); return
    if data == "traffic":
        edit(chat, mid, traffic_text(), BACK); return
    if data == "exits":
        edit(chat, mid, exits_text(), BACK); return
    if data == "rules":
        edit(chat, mid, rules_text(), BACK); return
    if data == "add_exit":
        state[chat] = "add_exit"
        edit(chat, mid, "发一条节点链接：<code>ss:// / vmess:// / trojan:// / vless://</code>\n/cancel 取消。", BACK); return
    if data == "add_grp":
        state[chat] = "add_group"
        edit(chat, mid, "发「<b>组名 出口1 出口2 …</b>」建故障切换组(自动选最快/坏了自动切)。\n"
             f"可选成员: {', '.join(concrete_tags(load()))}\n例: <code>main hk tw us</code>\n"
             "建好后可在「🎯 设默认出口」或规则里选它。/cancel 取消。", BACK); return
    if data == "add_rule":
        state[chat] = "add_rule"
        edit(chat, mid, f"发「<b>域名 出口</b>」，出口: {', '.join(exit_tags(load()))} 或 <b>direct</b>\n例: <code>netflix.com hk</code> / <code>x.cn direct</code>\n/cancel 取消。", BACK); return
    if data == "del_rule":
        state[chat] = "del_rule"
        edit(chat, mid, "发要删除的域名，例 <code>netflix.com</code>。/cancel 取消。", BACK); return
    if data == "add_rs":
        state[chat] = "add_rs"
        edit(chat, mid, f"发「<b>规则集URL 出口</b>」(Surge .list)。出口: {', '.join(exit_tags(load()))}\n例: <code>https://.../Binance.list tw</code>\n/cancel 取消。", BACK); return
    if data == "del_rs":
        m = _rs_meta()
        if not m:
            edit(chat, mid, "没有已添加的规则集", BACK); return
        edit(chat, mid, "选择要删除的规则集：", kb_pick("delrs", list(m.keys()))); return
    if data == "del_exit":
        tags = deletable_tags(load())
        edit(chat, mid, "选择要删除的出口/故障组：" if tags else "没有可删的出口",
             kb_pick("delx", tags) if tags else BACK); return
    if data == "setfinal":
        edit(chat, mid, "「其余国际」默认走哪个出口/组：", kb_pick("fin", exit_tags(load()))); return
    if data == "ios":
        edit(chat, mid, "正在生成 iOS 描述文件…", None)
        try:
            send_document(chat, "PrivDNS-Gateway.mobileconfig", _ios_profile(),
                          f"📱 iOS/iPadOS 私密DNS 描述文件\nDoT: {_dot_host()}\n"
                          "装法: 存到「文件」App → 点开 → 设置→通用→「已下载描述文件」→ 安装。\n"
                          "蜂窝下靠服务器 :81 探测激活, 安装时已自动配好。")
            edit(chat, mid, "✅ 描述文件已发送(见上一条)。", MENU)
        except Exception as e:  # noqa: BLE001
            edit(chat, mid, f"生成失败: {e}", MENU)
        return
    if data == "backup":
        edit(chat, mid, "正在打包配置…", None)
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
        edit(chat, mid, "🌐 <b>mosdns DNS 上游</b>\n"
             f"国际(remote): <code>{', '.join(rem) or '?'}</code>\n"
             f"国内(local): <code>{', '.join(loc) or '?'}</code>\n\n"
             "改: 发「<b>remote 地址…</b>」或「<b>local 地址…</b>」(可多个, 空格分隔)\n"
             "接 DNS 解锁: <code>remote udp://解锁DNS的IP:53</code>\n"
             "恢复默认国际: <code>remote https://1.1.1.1/dns-query udp://8.8.8.8:53</code>\n/cancel 取消。", BACK); return
    if data == "tfo":
        on = _tfo_on(load())
        edit(chat, mid, f"🚀 <b>TCP Fast Open</b>\n当前: <b>{'开启' if on else '关闭'}</b>\n"
             "降低到落地的握手延迟; 需落地端也支持, 否则自动回落普通握手。",
             {"inline_keyboard": [[{"text": "开启", "callback_data": "tfo:on"}, {"text": "关闭", "callback_data": "tfo:off"}],
                                  [{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}); return
    if data in ("tfo:on", "tfo:off"):
        ok, msg = set_tfo(data == "tfo:on"); edit(chat, mid, msg if ok else ("❌ " + msg), MENU); return
    if data == "restart":
        ok, msg = apply_sb(lambda c: None); sh(["systemctl", "restart", "mosdns"])
        edit(chat, mid, "✅ 已重启 sing-box + mosdns" if ok else msg, MENU); return
    if data == "updgeo":
        edit(chat, mid, "正在更新 geosite + 规则集…", None)
        r = sh(["/bin/bash", UPDATE_SCRIPT]); n = refresh_rulesets()
        edit(chat, mid, (f"✅ geosite 已更新; 规则集刷新 {n} 个" if r.returncode == 0
                         else "geosite 更新失败:\n" + (r.stdout + r.stderr)[-300:]), MENU); return
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
        edit(chat, mid, f"✅ 已删除 {tag}" if ok else msg, MENU); return
    if data.startswith("fin:"):
        tag = data[4:]
        ok, msg = apply_sb(lambda c: c["route"].__setitem__("final", tag))
        edit(chat, mid, f"✅ 默认出口 → {tag}" if ok else msg, MENU); return
    if data.startswith("delrs:"):
        ok, msg = del_ruleset(data[6:]); edit(chat, mid, ("✅ " if ok else "") + msg, MENU); return

# ── 文本 ──
def handle_text(chat, text):
    text = text.strip()
    if text == "/cancel":
        state.pop(chat, None); send_plain(chat, "已取消"); return
    if text in ("/start", "/menu", "/status"):
        state.pop(chat, None); send(chat, status_text()); return
    if text.startswith("/"):
        cmd = text.split()[0]
        if cmd == "/test":
            send_plain(chat, "测试中…"); send_plain(chat, test_exits()); return
        if cmd == "/traffic":
            send(chat, traffic_text(), BACK); return
        if cmd == "/exits":
            send(chat, exits_text(), BACK); return
        if cmd == "/rules":
            send(chat, rules_text(), BACK); return
        if cmd == "/addexit":
            state[chat] = "add_exit"; send(chat, "发节点链接：<code>ss:// / vmess:// / trojan:// / vless://</code>。/cancel 取消。", BACK); return
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
    act = state.pop(chat, None)
    if act == "add_exit":
        try:
            ob = parse_link(text)
            def mod(c):
                c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
                c["outbounds"].append(ob)
            ok, msg = apply_sb(mod)
            send_plain(chat, f"✅ 已添加出口 <b>{ob['tag']}</b> ({ob['type']} {ob['server']}:{ob['server_port']})" if ok else msg)
        except Exception as e:  # noqa: BLE001
            send_plain(chat, f"解析失败: {e}")
        return
    if act == "add_group":
        p = text.split()
        if len(p) < 3:
            send_plain(chat, "格式: 组名 出口1 出口2 …(至少2个出口)"); return
        ok, msg = add_group(p[0], p[1:]); send_plain(chat, msg if ok else ("❌ " + msg)); return
    if act == "add_rule":
        p = text.split()
        send_plain(chat, "格式: 域名 出口" if len(p) != 2 else (lambda r: ("✅ " if r[0] else "") + r[1])(add_rule(p[0], p[1])))
        return
    if act == "del_rule":
        ok, msg = del_rule(text); send_plain(chat, ("✅ " if ok else "") + msg); return
    if act == "add_rs":
        p = text.split()
        if len(p) != 2:
            send_plain(chat, "格式: 规则集URL 出口"); return
        send_plain(chat, "正在下载规则集…")
        ok, msg = add_ruleset(p[0], p[1]); send_plain(chat, ("✅ " if ok else "") + msg); return
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
                        handle_text(m["chat"]["id"], m["text"])
                    elif "document" in m:
                        handle_document(m["chat"]["id"], m["document"])
                elif "callback_query" in u:
                    q = u["callback_query"]
                    post("answerCallbackQuery", {"callback_query_id": q["id"]})
                    if q["from"]["id"] in ALLOWED:
                        handle_cb(q["message"]["chat"]["id"], q["message"]["message_id"], q["data"])
            except Exception as e:  # noqa: BLE001
                print("handle err", e, flush=True)

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""PrivDNS Gateway — Telegram 管理 bot v2 (纯标准库, long-poll)。

出口  : 列表 / 添加(ss/vmess/trojan/vless 链接) / 删除 / 设默认出口
分流  : 规则列表 / 添加(域名→出口|direct) / 删除 / 添加规则集(Surge .list URL→出口) / 删除规则集
服务  : 状态 / 重启 / 更新规则库(geosite + 各规则集)

UI 原地编辑消息(editMessageText), 不刷屏。改 sing-box 前备份, check 失败自动回滚。
环境变量: PDG_BOT_TOKEN, PDG_BOT_ALLOWED(逗号分隔的 user id)
"""
from __future__ import annotations
import base64, hashlib, json, os, re, shutil, subprocess, urllib.parse, urllib.request

TOKEN = os.environ["PDG_BOT_TOKEN"]
ALLOWED = {int(x) for x in os.environ.get("PDG_BOT_ALLOWED", "").replace(" ", "").split(",") if x}
SB = "/etc/sing-box/config.json"
RS_DIR = "/etc/sing-box/rs"
MOSDNS_DIRECT = "/etc/mosdns/rules/custom_direct.txt"
RS_META = "/opt/pdg-bot/rulesets.json"
UPDATE_SCRIPT = "/opt/pdg-bot/update-rules.sh"
API = "https://api.telegram.org/bot" + TOKEN
state: dict[int, str] = {}

# ── Telegram ──
def post(method, params):
    try:
        req = urllib.request.Request(API + "/" + method, data=json.dumps(params).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=70) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001
        print("api", method, e); return {}

MENU = {"inline_keyboard": [
    [{"text": "📊 状态", "callback_data": "status"}, {"text": "📋 出口列表", "callback_data": "exits"}],
    [{"text": "➕ 添加出口", "callback_data": "add_exit"}, {"text": "🗑 删除出口", "callback_data": "del_exit"}],
    [{"text": "📑 分流规则", "callback_data": "rules"}, {"text": "➕ 添加规则", "callback_data": "add_rule"}],
    [{"text": "🗑 删除规则", "callback_data": "del_rule"}, {"text": "🎯 设默认出口", "callback_data": "setfinal"}],
    [{"text": "📚 添加规则集", "callback_data": "add_rs"}, {"text": "🗑 删除规则集", "callback_data": "del_rs"}],
    [{"text": "🔄 重启服务", "callback_data": "restart"}, {"text": "📦 更新规则库", "callback_data": "updgeo"}],
]}
BACK = {"inline_keyboard": [[{"text": "⬅️ 返回主菜单", "callback_data": "menu"}]]}

def send(chat, text, kb=None):
    post("sendMessage", {"chat_id": chat, "text": text, "parse_mode": "HTML",
                         "reply_markup": kb or MENU, "disable_web_page_preview": True})

def edit(chat, mid, text, kb=None):
    r = post("editMessageText", {"chat_id": chat, "message_id": mid, "text": text, "parse_mode": "HTML",
                                 "reply_markup": kb or MENU, "disable_web_page_preview": True})
    if not r.get("ok"):
        send(chat, text, kb)

def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180)

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

def proxy_outbounds(c):
    return [o for o in c["outbounds"] if o.get("type") in ("shadowsocks", "vmess", "trojan", "vless")]

def exit_tags(c):
    return [o["tag"] for o in c["outbounds"] if o.get("type") in ("shadowsocks", "vmess", "trojan", "vless", "direct")]

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
    dom, suf, kw = [], [], []
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
    return dom, suf, kw

def _fetch_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pdg-bot"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()

def _build_source(url, path):
    """下载 Surge/Clash 文本 .list/.txt → 写 sing-box source rule_set, 返回域名条数。"""
    dom, suf, kw = _fetch_surge(url)
    if not (dom or suf or kw):
        raise ValueError("没解析出域名规则(仅支持 DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD)")
    rule = {}
    if dom:
        rule["domain"] = dom
    if suf:
        rule["domain_suffix"] = suf
    if kw:
        rule["domain_keyword"] = kw
    json.dump({"version": 1, "rules": [rule]}, open(path, "w"), ensure_ascii=False)
    return len(dom) + len(suf) + len(kw)

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
            open(path, "wb").write(_fetch_bytes(url)); cnt = "sing-box .srs"
        else:
            path = os.path.join(RS_DIR, name + ".json"); fmt = "source"
            cnt = f"{_build_source(url, path)} 条域名"
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
        m = _rs_meta(); m[name] = {"url": url, "outbound": target, "format": fmt, "path": path}; _save_rs_meta(m)
        return True, f"规则集已添加 → {target}（{cnt}，{name}）"
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
    m = _rs_meta(); n = 0
    for name, info in m.items():
        try:
            if info.get("format") == "binary":
                open(info["path"], "wb").write(_fetch_bytes(info["url"]))
            else:
                _build_source(info["url"], info["path"])
            n += 1
        except Exception as e:  # noqa: BLE001
            print("refresh rs", name, e)
    if m:
        sh(["systemctl", "restart", "sing-box"])
    return n

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
                                    or r.get("domain_suffix") or r.get("domain") or r.get("ip_cidr")]
        apply_sb(mod); removed.append("出口规则")
    if domain in _read_direct():
        _write_direct([d for d in _read_direct() if d != domain]); removed.append("直连表")
    return (bool(removed), f"已删除 {domain} ({'+'.join(removed)})" if removed else f"未找到含 {domain} 的规则")

# ── 文案 ──
def status_text():
    a = sh(["systemctl", "is-active", "mosdns", "sing-box"]).stdout.split()
    c = load()
    return ("<b>PrivDNS Gateway</b>\n"
            f"mosdns: {a[0] if a else '?'}   sing-box: {a[1] if len(a) > 1 else '?'}\n"
            f"出口: {', '.join(exit_tags(c))}\n"
            f"默认出口(其余国际): <b>{c['route'].get('final')}</b>\n"
            "国内直连 / AI·加密→tw / 其余按规则+默认出口")

def exits_text():
    c = load(); lines = []
    for o in proxy_outbounds(c):
        lines.append(f'• <b>{o["tag"]}</b>  {o["type"]}  {o.get("server")}:{o.get("server_port")}')
    return "代理出口:\n" + ("\n".join(lines) or "(无)")

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
    if data == "menu":
        edit(chat, mid, status_text(), MENU); return
    if data == "status":
        edit(chat, mid, status_text(), MENU); return
    if data == "exits":
        edit(chat, mid, exits_text(), BACK); return
    if data == "rules":
        edit(chat, mid, rules_text(), BACK); return
    if data == "add_exit":
        state[chat] = "add_exit"
        edit(chat, mid, "发一条节点链接：<code>ss:// / vmess:// / trojan:// / vless://</code>\n/cancel 取消。", BACK); return
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
        edit(chat, mid, "选择要删除的出口：", kb_pick("delx", [o["tag"] for o in proxy_outbounds(load())])); return
    if data == "setfinal":
        edit(chat, mid, "「其余国际」默认走哪个出口：", kb_pick("fin", exit_tags(load()))); return
    if data == "restart":
        ok, msg = apply_sb(lambda c: None); sh(["systemctl", "restart", "mosdns"])
        edit(chat, mid, "✅ 已重启 sing-box + mosdns" if ok else msg, MENU); return
    if data == "updgeo":
        edit(chat, mid, "正在更新 geosite + 规则集…", BACK)
        r = sh(["/bin/bash", UPDATE_SCRIPT]); n = refresh_rulesets()
        edit(chat, mid, (f"✅ geosite 已更新; 规则集刷新 {n} 个" if r.returncode == 0
                         else "geosite 更新失败:\n" + (r.stdout + r.stderr)[-300:]), MENU); return
    if data.startswith("delx:"):
        tag = data[5:]
        def mod(c):
            c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != tag]
            for r in c["route"]["rules"]:
                if r.get("outbound") == tag:
                    r["outbound"] = c["route"].get("final", "hk")
            if c["route"].get("final") == tag:
                c["route"]["final"] = next((t for t in exit_tags(c) if t != tag), "direct")
        ok, msg = apply_sb(mod)
        edit(chat, mid, f"✅ 已删除出口 {tag}" if ok else msg, MENU); return
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
        state.pop(chat, None); send(chat, "已取消"); return
    if text in ("/start", "/menu", "/status"):
        state.pop(chat, None); send(chat, status_text()); return
    if text.startswith("/"):
        cmd = text.split()[0]
        if cmd == "/exits":
            send(chat, exits_text(), BACK); return
        if cmd == "/rules":
            send(chat, rules_text(), BACK); return
        if cmd == "/addexit":
            state[chat] = "add_exit"; send(chat, "发节点链接：<code>ss:// / vmess:// / trojan:// / vless://</code>。/cancel 取消。", BACK); return
        if cmd == "/addrule":
            state[chat] = "add_rule"; send(chat, f"发「<b>域名 出口</b>」，出口: {', '.join(exit_tags(load()))} 或 <b>direct</b>。/cancel 取消。", BACK); return
        if cmd == "/delrule":
            state[chat] = "del_rule"; send(chat, "发要删除的域名。/cancel 取消。", BACK); return
        if cmd == "/addrs":
            state[chat] = "add_rs"; send(chat, "发「<b>规则集URL 出口</b>」（支持 .list / .srs）。/cancel 取消。", BACK); return
        if cmd == "/delexit":
            send(chat, "选择删除的出口：", kb_pick("delx", [o["tag"] for o in proxy_outbounds(load())])); return
        if cmd == "/setfinal":
            send(chat, "默认出口：", kb_pick("fin", exit_tags(load()))); return
        if cmd == "/delrs":
            m = _rs_meta()
            send(chat, "选择删除的规则集：" if m else "无规则集", kb_pick("delrs", list(m.keys())) if m else BACK); return
        if cmd == "/restart":
            ok, _ = apply_sb(lambda c: None); sh(["systemctl", "restart", "mosdns"]); send(chat, "✅ 已重启" if ok else "重启失败"); return
        if cmd == "/update":
            send(chat, "更新中…"); r = sh(["/bin/bash", UPDATE_SCRIPT]); n = refresh_rulesets()
            send(chat, f"✅ 完成，规则集刷新 {n} 个" if r.returncode == 0 else "更新失败"); return
        send(chat, "未知命令", MENU); return
    act = state.pop(chat, None)
    if act == "add_exit":
        try:
            ob = parse_link(text)
            def mod(c):
                c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
                c["outbounds"].append(ob)
            ok, msg = apply_sb(mod)
            send(chat, f"✅ 已添加出口 <b>{ob['tag']}</b> ({ob['type']} {ob['server']}:{ob['server_port']})" if ok else msg)
        except Exception as e:  # noqa: BLE001
            send(chat, f"解析失败: {e}")
        return
    if act == "add_rule":
        p = text.split()
        send(chat, "格式: 域名 出口" if len(p) != 2 else (lambda r: ("✅ " if r[0] else "") + r[1])(add_rule(p[0], p[1])))
        return
    if act == "del_rule":
        ok, msg = del_rule(text); send(chat, ("✅ " if ok else "") + msg); return
    if act == "add_rs":
        p = text.split()
        if len(p) != 2:
            send(chat, "格式: 规则集URL 出口"); return
        send(chat, "正在下载规则集…")
        ok, msg = add_ruleset(p[0], p[1]); send(chat, ("✅ " if ok else "") + msg); return
    send(chat, "用按钮操作：", MENU)

def main():
    post("deleteWebhook", {"drop_pending_updates": False})
    # 菜单只留快捷入口(其余功能走消息里的内联按钮, 避免与按钮重复);
    # 其它斜杠命令(/exits /addexit /addrs …)仍可手打, 只是不塞进左下角菜单。
    cmds = [
        {"command": "start", "description": "打开菜单 / 状态"},
        {"command": "cancel", "description": "取消当前输入"}]
    # 两个 scope 都设, 防被其它 bot 残留的高优先级 scope 盖住
    post("setMyCommands", {"commands": cmds})
    post("setMyCommands", {"commands": cmds, "scope": {"type": "all_private_chats"}})
    print("pdg-bot v2 started, allowed:", ALLOWED, flush=True)
    off = 0
    while True:
        r = post("getUpdates", {"offset": off, "timeout": 50})
        for u in r.get("result", []):
            off = u["update_id"] + 1
            try:
                if "message" in u and "text" in u["message"]:
                    m = u["message"]
                    if m["from"]["id"] in ALLOWED:
                        handle_text(m["chat"]["id"], m["text"])
                elif "callback_query" in u:
                    q = u["callback_query"]
                    post("answerCallbackQuery", {"callback_query_id": q["id"]})
                    if q["from"]["id"] in ALLOWED:
                        handle_cb(q["message"]["chat"]["id"], q["message"]["message_id"], q["data"])
            except Exception as e:  # noqa: BLE001
                print("handle err", e, flush=True)

if __name__ == "__main__":
    main()

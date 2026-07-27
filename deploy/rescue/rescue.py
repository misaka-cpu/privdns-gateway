#!/usr/bin/env python3
"""PrivDNS Gateway 独立救援平面(5.2)—— 只读骨架。

它存在的理由: mihomo 挂了、mosdns 挂了、Bot 连不上、公网出口不通、事务停在 APPLYING 的时候,
手机端仍然要有一个能打开的页面看清"现在到底是什么状态"。所以这个服务:
  · 只用 Python 标准库(没有 Flask/FastAPI/Node —— 为一个保命页引入依赖与它的目的自相矛盾);
  · 不 import bot/checks 那些会去读 config.json 的模块(模型损坏正是它要面对的场景);
  · unit 不依赖 mihomo/mosdns/pdg-bot/tailscaled, 也不等 network-online;
  · 绑定**确认过的私网地址**, 不是 0.0.0.0 —— nft 本身可能就是坏的那一环。

本提交只做只读: 状态总览 / 事务列表与详情 / 快照列表 / 脱敏审计尾部。写操作(recover、恢复
快照、重启服务、紧急默认出口)在后续提交接入, 一律走 pdgtx 或既有受控接口。

启动前提缺一不可 —— 任何一项不满足就**拒绝启动并说明原因**, 绝不降级成"先跑起来再说":
  · 内网卡段真源(profile.env 的 PDG_INTERNAL_CIDR)可读, 且本机确实有一个落在段内的地址;
  · 自签证书与私钥存在;
  · 救援 Token 存在且非空。
"""
import html
import hmac
import http.server
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")
try:
    import rescue_const as C
except ImportError:                                   # 仓库内直跑(开发/测试)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "bot"))
    import rescue_const as C

CSRF_TTL = int(os.environ.get("PDG_RESCUE_CSRF_TTL", "600"))            # CSRF cookie 存活
SESSION_TTL = int(os.environ.get("PDG_RESCUE_SESSION_TTL", "1800"))        # 空闲 30 分钟
SESSION_ABSOLUTE = int(os.environ.get("PDG_RESCUE_SESSION_MAX", "7200"))  # 绝对上限 2 小时
MAX_BODY = 8 * 1024                                    # 请求体上限: 救援页没有大表单
AUDIT_TAIL = 30                                        # 审计只回最近这么多条


# ── 事务核心: 有就用, 没有也要能开页面(它可能正是坏掉的那一个) ────────────────
def _cfgrestore():
    """受管配置恢复的共享实现。它只依赖 pdgtx, **不导入 bot / Telegram 交互层** ——
    救援平面要能在 Bot 起不来时照样工作。"""
    try:
        import cfgrestore
        return cfgrestore
    except Exception:  # noqa: BLE001
        return None


def _pdgtx():
    try:
        import pdgtx
        return pdgtx
    except Exception:  # noqa: BLE001
        return None


def _redact(s):
    tx = _pdgtx()
    if tx is not None:
        try:
            return tx.redact(s)
        except Exception:  # noqa: BLE001
            pass
    # 事务核心不可用时的兜底脱敏 —— 宁可粗一点, 也不让凭据进页面
    out = str(s)
    for rex, rep in ((r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b", "<token>"),
                     (r"\b[0-9a-fA-F]{32,}\b", "<hex>"),
                     (r"(?i)(password|secret|token|uuid|psk)\s*[:=]\s*\S+", r"\1=<redacted>")):
        out = re.sub(rex, rep, out)
    return out


def _run(cmd, timeout=5):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip()
    except (OSError, subprocess.SubprocessError):
        return 127, ""


# ── 启动前提 ────────────────────────────────────────────────────────────────
class StartupRefused(Exception):
    """前提不满足 —— 拒绝启动。猜一个监听地址/跳过认证, 都是把恢复入口开在错误的地方。"""


def local_addr_in(cidr):
    """本机落在该段内的第一个地址。找不到返回 None(调用方据此拒绝启动)。"""
    import ipaddress
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except Exception:  # noqa: BLE001
        return None
    _rc, out = _run(["ip", "-4", "-o", "addr"])
    for a in re.findall(r"inet ([0-9.]+)/", out):
        try:
            if ipaddress.ip_address(a) in net:
                return a
        except Exception:  # noqa: BLE001
            continue
    return None


def preflight():
    """返回 (bind_addr, port, cert, key, token)。任何一项不成立就抛 StartupRefused。"""
    port = C.port()
    paths = C.paths()
    cidr = C.internal_cidr()
    if not cidr:
        raise StartupRefused(
            "读不到内网卡段真源(%s 的 PDG_INTERNAL_CIDR)。救援服务靠它决定监听地址, "
            "绝不回落到 0.0.0.0 —— 那会把恢复入口暴露到公网。请先运行 sudo pdg detect-cidr。"
            % paths["PDG_PROFILE_ENV"])
    bind = os.environ.get("PDG_RESCUE_BIND") or local_addr_in(cidr)
    if not bind:
        raise StartupRefused(
            "本机没有落在内网卡段 %s 内的地址, 无从确定监听地址(内网卡可能没起来)。" % cidr)
    for k, what in (("PDG_RESCUE_CERT", "自签证书"), ("PDG_RESCUE_KEY", "私钥")):
        if not os.path.isfile(paths[k]):
            raise StartupRefused("%s 不存在(%s)。用 sudo pdg rescue rotate --cert 生成。"
                                 % (what, paths[k]))
    try:
        with open(paths["PDG_RESCUE_TOKEN"], encoding="utf-8") as f:
            token = f.read().strip()
    except OSError as e:
        raise StartupRefused("读不到救援 Token(%s: %s)。用 sudo pdg rescue rotate --token 生成。"
                             % (paths["PDG_RESCUE_TOKEN"], type(e).__name__))
    if len(token) < 16:
        raise StartupRefused("救援 Token 太短或为空, 拒绝以弱凭据启动。")
    return bind, port, paths["PDG_RESCUE_CERT"], paths["PDG_RESCUE_KEY"], token


# ── 只读数据源(全部容忍失败: 它们坏掉正是我们要显示的信息)────────────────────
UNITS = ("mosdns", "mihomo", "pdg-bot", "pdg-mitm", "pdg-probe81")


def svc_states():
    out = {}
    for u in UNITS:
        rc, s = _run(["systemctl", "is-active", u])
        out[u] = s or ("未知" if rc == 127 else "inactive")
    return out


def tx_overview():
    tx = _pdgtx()
    if tx is None:
        return {"available": False, "pending": [], "recent": [], "leftover": []}
    def _safe(fn, *a):
        try:
            return fn(*a)
        except Exception:  # noqa: BLE001
            return []
    return {"available": True,
            "pending": _safe(tx.pending_recovery),
            "recent": _safe(tx.list_tx, None, 10),
            "leftover": _safe(tx.leftover_materials)}


def snapshots():
    d = "/var/lib/privdns-gateway/backups"
    out = []
    try:
        names = sorted(os.listdir(d), reverse=True)
    except OSError:
        return out
    for n in names:
        f = os.path.join(d, n, "snap.tar.gz")
        if os.path.isfile(f):
            try:
                st = os.stat(f)
                out.append({"name": n, "size": st.st_size, "mtime": st.st_mtime})
            except OSError:
                continue
    return out


def audit_tail(n=AUDIT_TAIL):
    tx = _pdgtx()
    path = getattr(tx, "AUDIT", None) if tx else None
    path = path or "/var/lib/privdns-gateway/tx/index.jsonl"
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()[-n:]
    except OSError:
        return []
    out = []
    for ln in lines:
        try:
            rec = json.loads(ln)
        except ValueError:
            continue
        out.append({k: rec.get(k) for k in ("ts", "txid", "source", "op", "state", "error")})
    return out


def sysinfo():
    info = {}
    try:
        st = os.statvfs("/")
        info["disk_free_mb"] = st.f_bavail * st.f_frsize // (1024 * 1024)
    except OSError:
        info["disk_free_mb"] = None
    try:
        with open("/proc/uptime") as f:
            info["uptime_h"] = round(float(f.read().split()[0]) / 3600, 1)
    except OSError:
        info["uptime_h"] = None
    try:
        with open("/proc/loadavg") as f:
            info["load"] = f.read().split()[0]
    except OSError:
        info["load"] = None
    info["cidr"] = C.internal_cidr() or "未写入"
    return info


# ── 会话(本提交只做最小可用: 随机 id + TTL; CSRF/限速在下一提交)──────────────
class Sessions:
    """会话: 滑动过期 + 绝对上限, 每个会话自带一个 CSRF token。

    只放内存 —— 救援服务重启(或 Token 轮换)后所有会话立即失效, 这正是想要的语义: 凭据换了
    就不该还有人拿着旧会话在里面点按钮。"""

    def __init__(self, ttl=SESSION_TTL, absolute=SESSION_ABSOLUTE):
        self.ttl, self.absolute = ttl, absolute
        self._s = {}                        # sid -> {"exp","born","csrf"}

    def new(self):
        sid = secrets.token_urlsafe(24)
        now = time.time()
        self._s[sid] = {"exp": now + self.ttl, "born": now,
                        "csrf": secrets.token_urlsafe(24)}
        return sid

    def get(self, sid):
        if not sid:
            return None
        rec = self._s.get(sid)
        if rec is None:
            return None
        now = time.time()
        if now > rec["exp"] or now - rec["born"] > self.absolute:
            self._s.pop(sid, None)          # 空闲超时 / 到达绝对上限, 两条都要收
            return None
        rec["exp"] = now + self.ttl          # 滑动续期(但 born 不动, 绝对上限照样封顶)
        return rec

    def valid(self, sid):
        return self.get(sid) is not None

    def csrf(self, sid):
        rec = self.get(sid)
        return rec["csrf"] if rec else ""

    def drop(self, sid):
        self._s.pop(sid, None)

    def drop_all(self):
        self._s.clear()


class Nonces:
    """一次性确认 nonce: 与会话、快照 ID、快照摘要三者绑定。

    只有 CSRF 的话, 刷新/双击/重放同一个表单会重复执行一次危险操作 —— 而"重复执行一次配置
    恢复"意味着又一轮落盘与重启。nonce 用掉即废, 于是双击的第二下拿到的是明确的"已执行过"。"""

    def __init__(self, ttl=900):
        self.ttl = ttl
        self._n = {}                      # nonce -> (sid, snap, digest, exp)

    def issue(self, sid, snap, digest):
        n = secrets.token_urlsafe(18)
        self._n[n] = (sid, snap, digest, time.time() + self.ttl)
        # 顺手清过期的, 免得长期运行的服务里越积越多
        for k, v in list(self._n.items()):
            if v[3] < time.time():
                self._n.pop(k, None)
        return n

    def consume(self, n, sid, snap, digest):
        """一次性核销。任何一项对不上都不算数, 且**不给出是哪一项不对**。"""
        rec = self._n.pop(n, None)
        if not rec:
            return False
        s_, sn_, dg_, exp = rec
        if time.time() > exp:
            return False
        return (hmac.compare_digest(s_, sid) and hmac.compare_digest(sn_, snap)
                and hmac.compare_digest(dg_, digest))


class RateLimit:
    """登录失败限速 + 锁定。按来源地址计, 只放内存(重启即清)。

    没有它, 一个能连到私网段的设备就可以离线暴力 Token; 有了它, 攻击者每分钟只有几次机会,
    而合法用户从 SSH 拿一次 Token 就能一次进去。"""

    def __init__(self, burst=5, burst_window=60, lock_after=10, lock_window=600, lock_for=900):
        self.burst, self.burst_window = burst, burst_window
        self.lock_after, self.lock_window, self.lock_for = lock_after, lock_window, lock_for
        self._fail = {}                      # ip -> [ts, ...]
        self._locked = {}                    # ip -> until

    def _prune(self, ip, now):
        keep = [t for t in self._fail.get(ip, []) if now - t <= self.lock_window]
        if keep:
            self._fail[ip] = keep
        else:
            self._fail.pop(ip, None)
        return keep

    def blocked(self, ip):
        """返回还需等待的秒数(0 = 放行)。"""
        now = time.time()
        until = self._locked.get(ip)
        if until and now < until:
            return int(until - now) + 1
        if until:
            self._locked.pop(ip, None)
        recent = [t for t in self._prune(ip, now) if now - t <= self.burst_window]
        if len(recent) >= self.burst:
            return int(self.burst_window - (now - recent[-self.burst])) + 1
        return 0

    def fail(self, ip):
        now = time.time()
        self._fail.setdefault(ip, []).append(now)
        if len(self._prune(ip, now)) >= self.lock_after:
            self._locked[ip] = now + self.lock_for

    def ok(self, ip):
        self._fail.pop(ip, None)
        self._locked.pop(ip, None)


# ── 页面(纯文本 HTML: 无 JS、无外部字体/CDN/图片)──────────────────────────────
CSS = """body{font:14px/1.5 system-ui,sans-serif;margin:0;padding:1rem;background:#111;color:#ddd}
h1{font-size:1.1rem;margin:0 0 .8rem}h2{font-size:.95rem;margin:1.2rem 0 .4rem;color:#8bd}
table{border-collapse:collapse;width:100%;margin:.3rem 0}td,th{padding:.25rem .4rem;
border-bottom:1px solid #333;text-align:left;vertical-align:top;word-break:break-all}
.ok{color:#7c7}.bad{color:#f77}.warn{color:#fc6}form{margin:1rem 0}
input{padding:.4rem;width:100%;max-width:26rem;background:#222;color:#eee;border:1px solid #444}
button{padding:.4rem .9rem;margin-top:.5rem;background:#345;color:#eee;border:1px solid #567}
a{color:#8bd}.muted{color:#888;font-size:.85rem}"""


def page(title, body):
    return ("<!doctype html><html lang=zh><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>%s</title><style>%s</style></head><body>%s</body></html>"
            % (html.escape(title), CSS, body)).encode("utf-8")


def login_page(msg="", csrf=""):
    warn = "<p class=bad>%s</p>" % html.escape(msg) if msg else ""
    return page("PDG 救援", "<h1>PrivDNS Gateway 救援平面</h1>%s"
                "<form method=post action=/login>"
                "<input type=hidden name=csrf value='%s'>"
                "<label>救援 Token<br><input type=password name=token autocomplete=off></label>"
                "<br><button type=submit>进入</button></form>"
                "<p class=muted>Token 由 <code>sudo pdg rescue url</code> 在本机显示。"
                "页面不加载任何外部资源。</p>" % (warn, html.escape(csrf)))


def _row(k, v, cls=""):
    return "<tr><th>%s</th><td class='%s'>%s</td></tr>" % (
        html.escape(str(k)), cls, html.escape(str(v)))


def status_page():
    svc = svc_states()
    info = sysinfo()
    tx = tx_overview()
    rows = "".join(_row(u, s, "ok" if s == "active" else "bad") for u, s in svc.items())
    sys_rows = "".join(_row(k, v) for k, v in (
        ("内网卡段", info["cidr"]), ("磁盘可用", "%s MB" % info["disk_free_mb"]),
        ("运行时长", "%s 小时" % info["uptime_h"]), ("负载", info["load"])))
    if not tx["available"]:
        txline = "<p class=bad>事务核心不可用(pdgtx 导入失败)—— 恢复类操作不可用, 请用 SSH 处理。</p>"
    elif tx["pending"]:
        txline = ("<p class=bad>有 %d 笔未完成的事务, 写操作会被拒绝。"
                  "<a href=/tx>查看</a></p>" % len(tx["pending"]))
    else:
        txline = "<p class=ok>没有未完成的事务。<a href=/tx>查看历史</a></p>"
    return page("PDG 救援 · 状态",
                "<h1>状态总览</h1><h2>服务</h2><table>%s</table>"
                "<h2>系统</h2><table>%s</table><h2>配置事务</h2>%s"
                "<h2>其它</h2><p><a href=/snapshots>快照列表</a> · "
                "<a href=/audit>审计(脱敏)</a> · <a href=/logout>退出</a></p>"
                % (rows, sys_rows, txline))


def tx_page():
    t = tx_overview()
    if not t["available"]:
        return page("PDG 救援 · 事务", "<h1>配置事务</h1><p class=bad>事务核心不可用。</p>")
    def _tbl(items, empty):
        if not items:
            return "<p class=muted>%s</p>" % empty
        rows = "".join(
            "<tr><td><a href='/tx/%s'>%s</a></td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                html.escape(str(m.get("txid"))), html.escape(str(m.get("txid"))),
                html.escape(str(m.get("state"))), html.escape(str(m.get("op"))),
                html.escape(_redact(str(m.get("error") or ""))[:80])) for m in items)
        return "<table><tr><th>txid</th><th>状态</th><th>操作</th><th>错误</th></tr>%s</table>" % rows
    return page("PDG 救援 · 事务",
                "<h1>配置事务</h1><h2>未完成(需要处理)</h2>%s<h2>最近</h2>%s"
                "<h2>已收尾但仍留着材料</h2>%s<p><a href=/>返回</a></p>"
                % (_tbl(t["pending"], "没有未完成的事务"),
                   _tbl(t["recent"], "暂无记录"),
                   _tbl(t["leftover"], "没有残留材料")))


_TXID_RE = re.compile(r"^[0-9A-Za-z._-]{1,64}$")


def tx_detail_page(txid, csrf=""):
    """只接受**枚举里出现过的** txid: 参数直接当目录名用是路径穿越的经典入口。"""
    t = tx_overview()
    if not t["available"]:
        return None
    known = {str(m.get("txid")) for m in (t["pending"] + t["recent"] + t["leftover"])}
    if not _TXID_RE.match(txid) or txid not in known:
        return None
    tx = _pdgtx()
    try:
        m = tx.load_meta(os.path.join(tx.TX_ROOT, txid)) or {}
    except Exception:  # noqa: BLE001
        return None
    show = ("txid", "state", "op", "source", "mode", "started_at", "ended_at",
            "targets", "services", "rollback_complete")
    rows = "".join(_row(k, _redact(str(m.get(k)))) for k in show if k in m)
    err = _redact(str(m.get("error") or ""))
    if err:
        rows += _row("错误", err, "bad")
    form = ""
    if m.get("state") in getattr(tx, "NEEDS_RECOVERY", ()):
        # 只有**未完成**的事务才给恢复入口。表单里 txid 是隐藏域, 服务端仍会重新枚举校验 ——
        # 页面上的值一律当作不可信输入。不提供 --force: 覆盖别人的人工修复必须去 SSH 上显式做。
        form = ("<h2>恢复</h2>"
                "<p class=warn>把这笔事务改过的文件按 before-image 还原到操作前。"
                "事务之外有人改过同一个文件时会**停手并报告冲突**, 不会覆盖。</p>"
                "<form method=post action=/tx/recover>"
                "<input type=hidden name=csrf value='%s'>"
                "<input type=hidden name=txid value='%s'>"
                "<label><input type=checkbox name=confirm value=yes> 我确认要恢复这笔事务</label>"
                "<br><button type=submit>执行恢复</button></form>" % (csrf, html.escape(txid)))
    return page("PDG 救援 · 事务 %s" % txid,
                "<h1>事务 %s</h1><table>%s</table>%s<p><a href=/tx>返回列表</a></p>"
                % (html.escape(txid), rows, form))


def recover_result_page(txid, res):
    """恢复结果。**如实呈现**: 回滚不完整就写明 ROLLBACK_FAILED 与未完成项, 不粉饰成"已完成"。"""
    state = str(res.get("state") or "")
    okk = bool(res.get("ok"))
    rows = _row("事务", txid) + _row("结果状态", state, "ok" if okk else "bad")
    if res.get("restored"):
        rows += _row("已还原", "、".join(str(x) for x in res["restored"]))
    if res.get("failed"):
        rows += _row("未能还原", "、".join(_redact(str(x)) for x in res["failed"]), "bad")
    if res.get("conflicts"):
        rows += _row("事务之外被改过(未覆盖)", "、".join(str(x) for x in res["conflicts"]), "warn")
    if res.get("error"):
        rows += _row("说明", _redact(str(res["error"])), "bad")
    tail = ""
    if state == "ROLLBACK_FAILED" or (res.get("failed") and not okk):
        tail = ("<p class=bad>回滚没有完成。现网可能处于中间状态, 材料已保留在事务目录 —— "
                "请用 SSH 登录后 <code>sudo pdg tx show %s</code> 查看再处理。</p>"
                % html.escape(txid))
    elif res.get("conflicts"):
        tail = ("<p class=warn>这些目标在事务之外被改过, 本次**没有覆盖**它们。"
                "确认要用 before-image 盖掉时, 请在 SSH 上执行 "
                "<code>sudo pdg tx recover %s --force</code>(救援页不提供强制覆盖)。</p>"
                % html.escape(txid))
    elif okk:
        tail = "<p class=ok>已按 before-image 还原完成。</p>"
    return page("PDG 救援 · 恢复结果",
                "<h1>恢复结果</h1><table>%s</table>%s"
                "<p><a href=/tx>返回事务列表</a> · <a href=/>返回状态</a></p>" % (rows, tail))


def snapshots_page():
    snaps = snapshots()
    if not snaps:
        body = "<p class=muted>没有快照。</p>"
    else:
        body = "<table><tr><th>快照</th><th>大小</th><th>时间</th><th></th></tr>" + "".join(
            "<tr><td>%s</td><td>%.1f MB</td><td>%s</td>"
            "<td><a href='/snapshot/%s'>查看可恢复的配置</a></td></tr>" % (
                html.escape(s["name"]), s["size"] / 1048576.0,
                time.strftime("%Y-%m-%d %H:%M", time.localtime(s["mtime"])),
                html.escape(s["name"]))
            for s in snaps) + "</table>"
    return page("PDG 救援 · 快照",
                "<h1>快照</h1>%s"
                "<p class=muted>本页只提供**受管配置**的事务恢复(可回滚)。"
                "二进制、Bot 程序、平台/内核标记与凭据不在其中。</p>"
                "<p><a href=/>返回</a></p>" % body)


def snapshot_confirm_page(snap_id, csrf, nonce, sessions=None):
    """确认页: 在动手之前把"会换什么、不会换什么"摊开说清楚。"""
    cr = _cfgrestore()
    if cr is None:
        return None
    if snap_id not in cr.snapshot_ids():
        return None
    members, err = cr.list_members(snap_id)
    if err:
        return page("PDG 救援 · 快照", "<h1>快照 %s</h1><p class=bad>%s</p>"
                    "<p><a href=/snapshots>返回</a></p>" % (html.escape(snap_id), html.escape(err)))
    restorable, excluded, unknown = cr.classify(members)
    fmt = cr.snap_format(members)
    digest = cr.snapshot_digest(snap_id)
    p = cr.snapshot_path(snap_id)
    made = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(p))) if p else "?"
    rows = _row("快照 ID", snap_id) + _row("创建时间", made) \
        + _row("结构版本", "%s(兼容性识别结果, 非快照自带声明)" % fmt) \
        + _row("内容摘要", digest[:16] + "…") + _row("来源", "本机 pdg snapshot")
    tgt = "".join("<li>%s → <code>%s</code></li>" % (html.escape(m), html.escape(t))
                  for m, t in sorted(restorable.items())) or "<li class=muted>没有</li>"
    exc = "".join("<li>%s <span class=muted>(%s)</span></li>" % (html.escape(n), html.escape(k))
                  for n, k in (excluded + unknown)) or "<li class=muted>没有</li>"
    missing = [t for t in sorted(set(cr.MEMBER_TARGET.values()))
               if t not in set(restorable.values())]
    miss = "".join("<li><code>%s</code></li>" % html.escape(t) for t in missing) \
        or "<li class=muted>没有</li>"
    try:
        acts = cr.pdgtx.actions_for_targets(sorted(set(restorable.values()))) if restorable else ()
        acts_txt = "、".join(acts) if acts else "无(纯配置/元数据, 不重启任何服务)"
    except Exception:  # noqa: BLE001
        acts_txt = "无法确定 —— 恢复会被拒绝"
    rows += _row("将执行的服务动作", acts_txt)
    form = ""
    if fmt != "v1.6":
        form = ("<p class=bad>这份快照的结构(%s)无法安全映射成当前的受管配置目标, "
                "只能使用紧急完整恢复。本页不做结构转换。</p>" % html.escape(fmt))
    elif not restorable:
        form = "<p class=bad>这份快照里没有可事务恢复的受管配置。</p>"
    else:
        form = ("<form method=post action=/snapshot/restore>"
                "<input type=hidden name=csrf value='%s'>"
                "<input type=hidden name=snapshot value='%s'>"
                "<input type=hidden name=digest value='%s'>"
                "<input type=hidden name=nonce value='%s'>"
                "<label><input type=checkbox name=confirm value=yes> "
                "我确认只恢复上面列出的受管配置</label>"
                "<br><button type=submit>恢复受管配置</button></form>"
                % (csrf, html.escape(snap_id), html.escape(digest), nonce))
    return page("PDG 救援 · 快照 %s" % snap_id,
                "<h1>快照 %s</h1><table>%s</table>"
                "<h2>可以事务恢复的配置</h2><ul>%s</ul>"
                "<h2>缺失的目标(本次跳过)</h2><ul>%s</ul>"
                "<h2>明确不恢复</h2><ul>%s</ul>"
                "<p class=warn>本操作只换受管配置, 走 pdgtx 事务(有 before-image, 失败自动回滚)。"
                "二进制、Bot 程序、平台/内核标记、凭据一律不动。</p>%s"
                "<p><a href=/snapshots>返回快照列表</a></p>"
                % (html.escape(snap_id), rows, tgt, miss, exc, form))


def cfg_restore_result_page(res):
    rows = _row("快照", res.get("snapshot", "")) + _row("事务", res.get("txid", "")) \
        + _row("结果状态", res.get("state", ""), "ok" if res.get("ok") else "bad")
    if res.get("restored"):
        rows += _row("已恢复的目标", "、".join(str(x) for x in res["restored"]))
    if res.get("skipped"):
        rows += _row("跳过", "、".join(_redact(str(x)) for x in res["skipped"]), "warn")
    if res.get("excluded"):
        rows += _row("未恢复(不在受管范围)", "%d 项" % len(res["excluded"]))
    if res.get("failed"):
        rows += _row("未能还原", "、".join(_redact(str(x)) for x in res["failed"]), "bad")
    if res.get("error"):
        rows += _row("说明", _redact(str(res["error"])), "bad")
    if res.get("state") == "ROLLBACK_FAILED":
        tail = ("<p class=bad>回滚没有完成, 现网可能处于中间状态 —— 材料保留在事务目录, "
                "请用 SSH 处理。</p>")
    elif res.get("ok"):
        tail = "<p class=ok>受管配置已恢复并通过观察期。</p>"
    else:
        tail = ("<p class=warn>未做改动或已完整回滚。本操作**不会**自动改用完整快照恢复 —— "
                "确需整机恢复时请在 SSH 上显式执行。</p>")
    return page("PDG 救援 · 配置恢复结果",
                "<h1>配置恢复结果</h1><table>%s</table>%s"
                "<p><a href=/snapshots>返回快照</a> · <a href=/>返回状态</a></p>" % (rows, tail))


def audit_page():
    recs = audit_tail()
    if not recs:
        body = "<p class=muted>暂无审计记录。</p>"
    else:
        body = "<table><tr><th>时间</th><th>操作</th><th>状态</th><th>来源</th></tr>" + "".join(
            "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                time.strftime("%m-%d %H:%M", time.localtime(r.get("ts") or 0)),
                html.escape(_redact(str(r.get("op")))),
                html.escape(str(r.get("state"))), html.escape(str(r.get("source"))))
            for r in reversed(recs)) + "</table>"
    return page("PDG 救援 · 审计", "<h1>审计(最近 %d 条, 已脱敏)</h1>%s<p><a href=/>返回</a></p>"
                % (AUDIT_TAIL, body))


# ── HTTP ────────────────────────────────────────────────────────────────────
def _cookie_attrs(name, value, max_age):
    """所有 cookie 走同一个构造口。

    HttpOnly: 本项目的表单是**服务端渲染**的隐藏域, 页面里没有一行 JS 需要读这个 cookie ——
    那就不该让脚本读得到。双提交模式常被写成"JS 读 cookie 再塞进请求头", 那种写法才必须去掉
    HttpOnly; 我们不是。Secure/SameSite=Strict/Path=/ 同理固定; **不设 Domain** —— 留空即
    host-only, 写了反而会把 cookie 扩散到子域。"""
    return "%s=%s; Path=/; Max-Age=%d; HttpOnly; Secure; SameSite=Strict" % (name, value, max_age)


def _cookie_clear(name):
    """删除 cookie: 名称与 Path 必须与设置时**完全一致**, 否则浏览器删的是另一个。"""
    return "%s=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict" % name


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "pdg-rescue"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # -- 基础设施 --
    def log_message(self, fmt, *args):
        """只记方法与路径, 不记查询串/请求体/凭据。"""
        sys.stderr.write("[rescue] %s\n" % _redact(fmt % args))

    def _send(self, code, body=b"", ctype="text/html; charset=utf-8", cookie=None,
              extra_headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        for c in ([cookie] if isinstance(cookie, str) else (cookie or [])):
            if c:
                self.send_header("Set-Cookie", c)
        for k, v in extra_headers:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _issue_csrf(self):
        """沿用已有 cookie, 没有才新发 —— 刷新页面不该让上一个表单立刻失效。"""
        cur = self._cookie("pdgcsrf")
        return cur if cur else secrets.token_urlsafe(24)

    def _csrf_ok(self, form):
        """双提交 + 会话绑定, 四种情况全拒: 缺失 / 不同 / 过期(cookie 已不存在) / 跨会话。

        已登录时还要求表单值等于**该会话**自己的 CSRF token: 只比 cookie 与表单的话, 攻击者
        若能诱导受害者带上自己那一份 cookie+token(cookie tossing 之类), 双提交就成了摆设。"""
        cookie_v = self._cookie("pdgcsrf")
        form_v = form.get("csrf", [""])[0]
        if not cookie_v or not form_v or not hmac.compare_digest(form_v, cookie_v):
            return False
        rec = self.server.sessions.get(self._sid())
        if rec is not None:
            return hmac.compare_digest(form_v, rec["csrf"])
        return True

    def _sid(self):
        raw = self.headers.get("Cookie") or ""
        m = re.search(r"(?:^|;\s*)pdgsid=([A-Za-z0-9_-]+)", raw)
        return m.group(1) if m else ""

    def _authed(self):
        return self.server.sessions.valid(self._sid())

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None
        if n > MAX_BODY:
            return None
        return self.rfile.read(n) if n > 0 else b""

    # -- 路由 --
    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if not self._authed():
            csrf = self._issue_csrf()
            self._send(401 if path != "/" else 200, login_page("", csrf),
                       cookie=_cookie_attrs("pdgcsrf", csrf, CSRF_TTL))
            return
        if path == "/":
            self._send(200, status_page())
        elif path == "/tx":
            self._send(200, tx_page())
        elif path.startswith("/tx/"):
            body = tx_detail_page(path[4:], self.server.sessions.csrf(self._sid()))
            self._send(200, body) if body else self._send(404, page("404", "<p>没有这笔事务。</p>"))
        elif path == "/snapshots":
            self._send(200, snapshots_page())
        elif path.startswith("/snapshot/"):
            snap = path[len("/snapshot/"):]
            cr = _cfgrestore()
            if cr is None or snap not in cr.snapshot_ids():
                self._send(404, page("404", "<p>没有这份快照。</p>"))
                return
            sid = self._sid()
            body = snapshot_confirm_page(snap, self.server.sessions.csrf(sid),
                                         self.server.nonces.issue(sid, snap,
                                                                  cr.snapshot_digest(snap)))
            self._send(200, body) if body else self._send(404, page("404", "<p>没有这份快照。</p>"))
        elif path == "/audit":
            self._send(200, audit_page())
        elif path == "/logout":
            self.server.sessions.drop(self._sid())
            # 会话没了, 与它绑定的 CSRF token 也不该再留在浏览器里
            self._send(200, login_page("已退出。"),
                       cookie=[_cookie_clear("pdgsid"), _cookie_clear("pdgcsrf")])
        else:
            self._send(404, page("404", "<p>没有这个页面。</p>"))

    def _post_recover(self):
        """把一笔中断的事务按 before-image 还原。

        纪律: 必须已登录; CSRF 必须与本会话绑定; txid **只能是本次枚举出来的未完成事务**
        (页面上的值一律当不可信输入重新校验); 必须勾了确认; 不提供 --force。
        恢复本身的锁、漂移保护、材料校验、审计全在 pdgtx.recover 里 —— 救援页不重写一套。"""
        if not self._authed():
            self._send(401, login_page("请先登录。", self._issue_csrf()))
            return
        form = self._read_form()
        if form is None:
            self._send(413, page("413", "<p>请求体过大。</p>"))
            return
        if not self._csrf_ok(form):
            self._send(403, page("403", "<p>表单已过期或来源不可信, 未执行任何操作。</p>"))
            return
        tx = _pdgtx()
        if tx is None:
            self._send(503, page("503", "<p class=bad>事务核心不可用, 恢复功能无法执行。"
                                        "请用 SSH 处理。</p>"))
            return
        txid = (form.get("txid") or [""])[0]
        try:
            pend = {str(m.get("txid")) for m in tx.pending_recovery()}
        except Exception:  # noqa: BLE001
            self._send(503, page("503", "<p class=bad>读不到事务目录, 未执行任何操作。</p>"))
            return
        if not _TXID_RE.match(txid or "") or txid not in pend:
            # 不在"未完成"名单里就没有恢复的意义 —— 也堵住了拿路径当参数的那条路
            self._send(404, page("404", "<p>没有这笔待恢复的事务(可能已经处理过了)。</p>"))
            return
        if (form.get("confirm") or [""])[0] != "yes":
            self._send(400, page("400", "<p>没有勾选确认, 未执行任何操作。</p>"))
            return
        # 同一时刻只放一个恢复进核心: 重复点击/刷新重放/并发请求都会堆在 pdgtx 的 flock 上,
        # 把请求线程一个个占死。这里非阻塞地抢一把进程内的锁, 抢不到立刻 409 —— 不排队。
        if not self.server.recover_gate.acquire(blocking=False):
            self._send(409, page("409", "<p class=warn>恢复正在执行, 请勿重复操作。"
                                        "完成后刷新 <a href=/tx>事务列表</a> 查看结果。</p>"))
            return
        self.log_message("recover %s", txid)
        try:
            # trigger_source 由服务端**硬编码**: 从请求里接这个值等于让客户端自己决定审计里
            # 写什么, 那条记录也就没有取证价值了。
            res = tx.recover(txid, trigger_source="rescue")
        except Exception as e:  # noqa: BLE001
            name = type(e).__name__
            if name == "TxBusy":
                self._send(409, page("409", "<p class=warn>已有配置操作正在执行, "
                                            "本次未做任何改动, 请稍后再试。</p>"))
            elif name == "TxRefused":
                self._send(409, page("409", "<p class=bad>拒绝执行(未做任何改动): %s</p>"
                                     % html.escape(_redact(str(e)))))
            else:
                self._send(500, page("500", "<p class=bad>恢复过程出错(%s), "
                                            "请用 SSH 查看事务目录。</p>" % html.escape(name)))
            return
        finally:
            # 恢复已经跑完(或已抛出)才放锁。浏览器中途断开只影响下面这次写响应, 不影响上面
            # 已经完成的恢复 —— 服务端不会因为对端消失就把恢复做一半。
            self.server.recover_gate.release()
        try:
            self._send(200, recover_result_page(txid, res))
        except OSError:
            # 对端早就走了: 恢复与审计都已完成, 这里没什么可补救的, 也不该把线程炸掉
            self.log_message("recover %s: 客户端已断开, 结果未能送达", txid)

    def _post_cfg_restore(self):
        """恢复受管配置(pdgtx 事务)。**不做完整快照恢复**, 失败也不自动降级成完整恢复。"""
        if not self._authed():
            self._send(401, login_page("请先登录。", self._issue_csrf()))
            return
        form = self._read_form()
        if form is None:
            self._send(413, page("413", "<p>请求体过大。</p>"))
            return
        if not self._csrf_ok(form):
            self._send(403, page("403", "<p>表单已过期或来源不可信, 未执行任何操作。</p>"))
            return
        cr = _cfgrestore()
        if cr is None:
            self._send(503, page("503", "<p class=bad>配置恢复模块不可用, 请用 SSH 处理。</p>"))
            return
        snap = (form.get("snapshot") or [""])[0]
        digest = (form.get("digest") or [""])[0]
        nonce = (form.get("nonce") or [""])[0]
        if snap not in cr.snapshot_ids():          # 只认服务端索引里的逻辑 ID
            self._send(404, page("404", "<p>没有这份快照。</p>"))
            return
        if (form.get("confirm") or [""])[0] != "yes":
            self._send(400, page("400", "<p>没有勾选确认, 未执行任何操作。</p>"))
            return
        if not self.server.nonces.consume(nonce, self._sid(), snap, digest):
            # 一次性票据: 刷新/双击/重放拿到的是这条, 而不是又跑一遍恢复
            self._send(409, page("409", "<p class=warn>这个确认已经用过或已失效(重复提交?)。"
                                        "请回到 <a href=/snapshots>快照列表</a> 重新确认。</p>"))
            return
        if not self.server.recover_gate.acquire(blocking=False):
            self._send(409, page("409", "<p class=warn>恢复正在执行, 请勿重复操作。</p>"))
            return
        self.log_message("config_restore %s", snap)
        try:
            res = cr.restore_managed(snap, expect_digest=digest, trigger_source="rescue")
        except Exception as e:  # noqa: BLE001
            self._send(500, page("500", "<p class=bad>配置恢复过程出错(%s), 请用 SSH 查看。</p>"
                                 % html.escape(type(e).__name__)))
            return
        finally:
            self.server.recover_gate.release()
        code = 200 if res.get("ok") else (409 if res.get("busy") else 200)
        try:
            self._send(code, cfg_restore_result_page(res))
        except OSError:
            self.log_message("config_restore %s: 客户端已断开, 结果未能送达", snap)

    def do_HEAD(self):
        self.do_GET()

    def _client(self):
        try:
            return self.client_address[0]
        except Exception:  # noqa: BLE001
            return "?"

    def _cookie(self, name):
        raw = self.headers.get("Cookie") or ""
        m = re.search(r"(?:^|;\s*)%s=([A-Za-z0-9_-]+)" % re.escape(name), raw)
        return m.group(1) if m else ""

    def _read_form(self):
        raw = self._body()
        if raw is None:
            return None
        import urllib.parse
        return urllib.parse.parse_qs(raw.decode("utf-8", "replace"))

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == "/tx/recover":
            self._post_recover()
            return
        if path == "/snapshot/restore":
            self._post_cfg_restore()
            return
        if path != "/login":
            # 白名单之外的写路径一律明确拒绝(而不是 404 装作没有)
            self._send(405, page("405", "<p>这个操作不在救援平面的白名单里。</p>"))
            return
        ip = self._client()
        wait = self.server.rate.blocked(ip)
        if wait:
            # 429 + Retry-After: 明确告诉合法用户要等多久, 同时把暴力尝试的速率压下来
            body = login_page("尝试过于频繁, 请 %d 秒后再试。" % wait)
            self.send_response(429)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Retry-After", str(wait))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        raw = self._body()
        if raw is None:
            self._send(413, login_page("请求体过大。"))
            return
        import urllib.parse
        form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
        # CSRF(双提交 cookie): 表单里的值必须与 GET / 时下发的 cookie 一致。配合 SameSite=Strict,
        # 跨站页面既拿不到这个 cookie 也带不上它 —— 别人的网页无法替用户提交登录/后续写操作。
        if not self._csrf_ok(form):
            # 换发一个新的 —— 旧的要么不存在要么已不可信, 让用户拿新表单重来
            fresh = secrets.token_urlsafe(24)
            self._send(403, login_page("表单已过期, 请重新打开页面再试。", fresh),
                       cookie=_cookie_attrs("pdgcsrf", fresh, CSRF_TTL))
            return
        self.server.refresh_token()      # rotate 之后不必重启服务
        got = form.get("token", [""])[0]
        # 常数时间比对: 逐字符早退会把"对了几位"泄漏成时间差
        if not hmac.compare_digest(got, self.server.token):
            self.server.rate.fail(ip)
            self.log_message("login failed from %s", ip)
            self._send(401, login_page("Token 不正确。", self._cookie("pdgcsrf")))
            return
        self.server.rate.ok(ip)
        sid = self.server.sessions.new()
        # 登录成功 = 权限升级, CSRF token 一并轮换成与新会话绑定的那一个(会话固定攻击里,
        # 攻击者预置的旧 token 在这一刻失效)
        self._send(200, status_page(),
                   cookie=[_cookie_attrs("pdgsid", sid, SESSION_TTL),
                           _cookie_attrs("pdgcsrf", self.server.sessions.csrf(sid), SESSION_TTL)])


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, token, ctx, fd=None, token_path=None):
        self.token = token
        self.token_path = token_path
        self.sessions = Sessions()
        self.rate = RateLimit()
        self.recover_gate = threading.Lock()      # 恢复的并发闸门(非阻塞获取, 抢不到即 409)
        self.nonces = Nonces()                    # 危险操作的一次性确认票
        if fd is not None:                      # systemd socket activation: 直接接管那个 fd
            http.server.HTTPServer.__init__(self, addr, Handler, bind_and_activate=False)
            self.socket.close()          # TCPServer 自建的那个不用了, 别泄漏 fd
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM, fileno=fd)
            self.server_address = self.socket.getsockname()
        else:
            http.server.HTTPServer.__init__(self, addr, Handler)
        self.socket = ctx.wrap_socket(self.socket, server_side=True)

    def refresh_token(self):
        """Token 文件变了就换掉并清空所有会话 —— 轮换的语义就是"旧的立刻不算数",
        包括别人手里已经登录的那一个。读不到就保持现状(不因为一次读失败把自己锁死)。"""
        if not self.token_path:
            return
        try:
            with open(self.token_path, encoding="utf-8") as f:
                cur = f.read().strip()
        except OSError:
            return
        if len(cur) >= 16 and cur != self.token:
            self.token = cur
            self.sessions.drop_all()


SD_LISTEN_FDS_START = 3


def systemd_fd():
    """systemd 传进来的监听 fd(socket activation)。

    两个环境变量**都不存在** → 返回 None, 走自行绑定(手动运行/测试的正常路径)。
    存在但不自洽 → **拒绝启动**, 不退回自行绑定: 那意味着 systemd 本来要把监听口交给我们, 而
    现在情况不对 —— 此时自己再 bind 一个, 机器上就会有两个"救援入口", 一个由 systemd 持有、
    一个是我们自己的, 用户连上哪个全看运气, 出事根本查不清。"""
    pid_s, fds_s = os.environ.get("LISTEN_PID"), os.environ.get("LISTEN_FDS")
    if pid_s is None and fds_s is None:
        return None
    if pid_s is None or fds_s is None:
        raise StartupRefused("LISTEN_PID 与 LISTEN_FDS 只给了一个, 无法确认 socket 交接")
    try:
        pid, n = int(pid_s), int(fds_s)
    except ValueError:
        raise StartupRefused("LISTEN_PID/LISTEN_FDS 不是数字(%r/%r)" % (pid_s[:16], fds_s[:16]))
    if pid != os.getpid():
        raise StartupRefused("LISTEN_PID=%d 不是本进程(%d) —— 这些 fd 不是给我们的" % (pid, os.getpid()))
    if n != 1:
        raise StartupRefused("期望恰好 1 个监听 fd, LISTEN_FDS=%d" % n)
    fd = SD_LISTEN_FDS_START
    try:
        st = os.fstat(fd)
    except OSError as e:
        raise StartupRefused("拿不到交接过来的 fd %d(%s)" % (fd, type(e).__name__))
    import stat as _stat
    if not _stat.S_ISSOCK(st.st_mode):
        raise StartupRefused("fd %d 不是 socket, 拒绝当监听口使用" % fd)
    # 还要确认它**已经在监听**: 交接过来一个没 listen 的 socket, accept 会一直失败
    try:
        probe = socket.fromfd(fd, socket.AF_INET, socket.SOCK_STREAM)   # dup, 用完即关
        try:
            if not probe.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN):
                raise StartupRefused("fd %d 不是处于监听状态的 socket" % fd)
        finally:
            probe.close()
    except OSError as e:
        raise StartupRefused("检查 fd %d 失败(%s)" % (fd, type(e).__name__))
    return fd


def main():
    try:
        bind, port, cert, key, token = preflight()
    except StartupRefused as e:
        sys.stderr.write("[rescue] 拒绝启动: %s\n" % e)
        return 2
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    try:
        ctx.load_cert_chain(cert, key)
    except (OSError, ssl.SSLError) as e:
        sys.stderr.write("[rescue] 拒绝启动: 证书/私钥不可用(%s)\n" % type(e).__name__)
        return 2
    try:
        fd = systemd_fd()
    except StartupRefused as e:
        sys.stderr.write("[rescue] 拒绝启动: %s\n" % e)
        return 2
    srv = Server((bind, port), token, ctx, fd=fd, token_path=C.paths()["PDG_RESCUE_TOKEN"])
    sys.stderr.write("[rescue] 监听 https://%s:%d/ (%s)\n"
                     % (bind, port, "socket activation" if fd else "自行绑定"))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

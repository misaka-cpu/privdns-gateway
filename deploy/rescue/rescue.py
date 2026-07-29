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
import ipaddress
import os
import re
import secrets
import signal
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
OP_CONFIG = "config"                                   # 确认票的操作维度
OP_BREAKGLASS = "full_breakglass_restore"              # 与结果/审计里的 operation 同名
OP_EMERGENCY = "emergency_default_exit"                # 紧急默认出口(启用/恢复共用票据维度)
EMERGENCY_API = ("enable", "restore", "status", "candidates")
AUDIT_TAIL = 30                                        # 审计只回最近这么多条


# ── 事务核心: 有就用, 没有也要能开页面(它可能正是坏掉的那一个) ────────────────
# pdgtx.py 与 cfgrestore.py **属于业务恢复范围**(有意不列入救援保护清单): 一次完整恢复本来
# 就该把它们换成快照里的版本。于是"恢复完之后它们是旧版"是**正常结果**, 不是故障。
#
# 但"import 得进来"不等于"能用": 旧版本往往少几个函数, 直接调用的下场是 AttributeError 一路
# 冒到 HTTP 层 —— 用户在最需要一个能打开的页面的时刻拿到 500 堆栈。所以这里按**接口齐全**
# 判定: 不齐全一律当作不可用, 页面显示"旧核心不支持"并禁用对应按钮, 而状态页与紧急完整恢复
# 照常可用(它们不依赖这两个模块)。
CFGRESTORE_API = ("snapshot_ids", "snapshot_digest", "list_members", "snap_format",
                  "classify", "restore_managed", "MEMBER_TARGET")
PDGTX_API = ("pending_recovery", "list_tx", "leftover_materials", "recover", "redact", "TX_ROOT")
BREAKGLASS_API = ("run", "_protected_paths", "snap_api")
DEGRADED = "旧核心不支持"          # 页面上统一的说法, 各处不要各写一句


def _mod(name, api):
    try:
        m = __import__(name)
    except Exception:  # noqa: BLE001
        return None                       # 缺失 / 语法错误 / import 期异常
    return m if all(hasattr(m, n) for n in api) else None      # 版本不兼容


def _cfgrestore():
    """受管配置恢复的共享实现。它只依赖 pdgtx, **不导入 bot / Telegram 交互层** ——
    救援平面要能在 Bot 起不来时照样工作。

    事务核心不可用时它一并算作不可用: 配置恢复整个建立在 pdgtx 事务之上, 而旧版 pdgtx 往往
    "import 得进来但少函数" —— cfgrestore 于是能加载, 却会在**事务跑到一半**时 AttributeError。
    与其半途炸在落盘中间, 不如在按钮上就说清"旧核心不支持"。"""
    if _pdgtx() is None:
        return None
    return _mod("cfgrestore", CFGRESTORE_API)


def _breakglass():
    """紧急完整恢复。与配置恢复分开加载: 它不可用时配置恢复照样能用。"""
    return _mod("breakglass", BREAKGLASS_API)


def _pdgtx():
    return _mod("pdgtx", PDGTX_API)


def _emergency():
    """紧急默认出口。与配置恢复一样属于"要事务才能做"的写操作, 事务核心不可用时它也不可用。"""
    if _pdgtx() is None:
        return None
    return _mod("emergency", EMERGENCY_API)


def _tx_paths():
    """渲染派生要用的三个路径。跟随事务沙箱根 —— 真机上 FSROOT 是空串, 与写死绝对路径一致。"""
    root = _fsroot() or ""
    return {"rs_meta_path": root + "/opt/pdg-bot/rulesets.json",
            "mitm_hijack_file": root + "/etc/mosdns/rules/mitm_hijack.txt",
            "platform_file": root + "/etc/privdns-gateway/platform"}


def _emergency_digest(stt):
    """把"页面看到的那个状态"压成一个摘要, 供票据绑定。状态读不到时给一个固定串 ——
    那种情况下页面本来就不给表单, 票也签不出有效的操作。"""
    import hashlib
    if not stt:
        return "no-state"
    key = json.dumps({k: stt.get(k) for k in ("active", "stale", "current_final",
                                              "emergency_final", "original_final",
                                              "original_present", "candidates")},
                     ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def _emergency_status():
    """页面用的状态。**纯读**: GET 不写任何文件。读不到就当未启用。"""
    em = _emergency()
    if em is None:
        return None
    try:
        tx = _pdgtx()
        model_raw, _st = tx._read_target(tx.FSROOT + "/etc/sing-box/config.json")
        state_raw, _st2 = tx._read_target(
            tx.FSROOT + "/var/lib/privdns-gateway/rescue-state.json")
        return em.status(json.loads((model_raw or b"{}").decode("utf-8")), state_raw)
    except Exception:  # noqa: BLE001
        return None


def _forget_business_modules():
    """把业务恢复范围内的模块从 import 缓存里丢掉, 下次访问按**盘上现在那一份**重新判定。

    Python 一个模块只 import 一次。完整恢复把 cfgrestore.py / pdgtx.py 换成旧版之后, 不丢缓存
    的话页面会拿着内存里那份旧对象继续显示"一切正常", 而盘上早已是另一回事 —— 要到下次重启
    才暴露。"恢复后重新做能力检测"要真的重新检测, 就得先忘掉。
    breakglass 与 rescue 自身在保护清单里, 不会被换, 不必忘。"""
    for m in ("cfgrestore", "pdgtx", "emergency", "mihomorender"):
        sys.modules.pop(m, None)


def caps():
    """三个模块此刻到底能不能用 —— 页面据此决定"正常显示"还是"禁用 + 旧核心不支持"。"""
    return {"pdgtx": _pdgtx() is not None,
            "cfgrestore": _cfgrestore() is not None,
            "breakglass": _breakglass() is not None,
            "emergency": _emergency() is not None}


def _ct_eq(a, b):
    """恒定时间比较。转字节再比: hmac.compare_digest 对 str 只接受 ASCII, 而确认框里的内容
    完全可能是用户随手粘进来的中文 —— 那不该变成一个 500, 它只是"输错了"。"""
    return hmac.compare_digest(str(a).encode("utf-8", "replace"),
                               str(b).encode("utf-8", "replace"))


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
    # 监听地址与来源段是**两件事**: 来源段管"谁可以连", 这里管"绑在本机哪个地址上"。
    # 真实网关上后者往往不在前者里(.200 实机), 所以只读 PDG_RESCUE_BIND, 不从来源段推导。
    #
    # 缺这个值该不该拒绝启动, 取决于**谁在绑**:
    #   · systemd socket activation: 监听 socket 已经绑好递过来了, 这个值只是显示用 ——
    #     因为一个配置键缺失就拒绝启动, 等于让救援门在最需要的时候自己关上;
    #   · 自己 bind(调试/无 systemd): 没有值就无处可绑, 必须拒绝, 绝不回落 0.0.0.0。
    # 判断放到 main 里(那时才知道有没有 fd), 这里只负责取值与校验格式。
    bind = os.environ.get("PDG_RESCUE_BIND") or C.rescue_bind()
    if bind and not _valid_bind(bind):
        raise StartupRefused("PDG_RESCUE_BIND=%r 不是合法的 IPv4 监听地址(禁止主机名 / "
                             "0.0.0.0 / 广播 / 组播)。" % bind[:40])
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
    return bind, port, paths["PDG_RESCUE_CERT"], paths["PDG_RESCUE_KEY"], token, cidr


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


def _fsroot():
    """沙箱根。事务核心可用时以它为准, 不可用时读同一个环境变量 —— **不能**在这里退回写死的
    绝对路径: 那样一来"pdgtx 坏了"就变成"顺便还换了一套路径", 而降级恰恰是最需要它去对地方
    的时刻(真机上 FSROOT 是空串, 两条路径本来就重合, 所以这不影响生产行为)。"""
    tx = _pdgtx()
    return getattr(tx, "FSROOT", None) if tx is not None else os.environ.get("PDG_TX_FSROOT", "")


def _snap_dir():
    return os.environ.get("PDG_SNAP_DIR", (_fsroot() or "") + "/var/lib/privdns-gateway/backups")


def _audit_file():
    tx = _pdgtx()
    if tx is not None:
        return os.path.join(tx.TX_ROOT, "index.jsonl")
    root = os.environ.get("PDG_TX_ROOT", (_fsroot() or "") + "/var/lib/privdns-gateway/tx")
    return os.path.join(root, "index.jsonl")


def snapshots():
    d = _snap_dir()
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
    path = _audit_file()
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
        out.append({k: rec.get(k) for k in ("ts", "txid", "source", "op", "state", "error",
                                            "snapshot", "pre_rescue_snapshot")})
    return out


def last_breakglass():
    """审计里最近一次紧急完整恢复(没有则 None)。

    为什么要从审计里读: pre-rescue 快照 ID 是"把机器换回去"的唯一凭据, 它不能只活在那一次的
    结果页里 —— 用户关掉页面、或者救援服务重启之后, 那个 ID 就找不回来了。审计是重启后还在
    的那一份, 而且它的读取路径不依赖 pdgtx(见 audit_tail 的兜底路径)。"""
    for rec in reversed(audit_tail(200)):
        if rec.get("op") == OP_BREAKGLASS:
            return rec
    return None


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


def _snap_facts(api, snap_id):
    """快照的三个事实: 成员、结构版本、内容摘要。确认页与执行时**各算一次**并比对 ——
    "确认的是这一份、执行的是另一份"是这里最不该发生的事, 而快照文件是可以在两次请求之间
    被换掉的(定时任务、另一个会话、手工 scp)。返回 (members, fmt, digest, err)。"""
    members, err = api.list_members(snap_id)
    if err:
        return [], "", "", err
    return members, api.snap_format(members), api.snapshot_digest(snap_id), ""


def _snap_api():
    """快照读取接口。cfgrestore 坏了也要能做完整恢复 —— 所以走 breakglass 那个单一决策点,
    它在 cfgrestore 不可用时会退到自带的最小实现(校验强度一致)。"""
    bg = _breakglass()
    return bg.snap_api(_cfgrestore()) if bg is not None else _cfgrestore()


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
        self._n = {}                      # nonce -> (sid, snap, digest, op, fmt, exp)

    def issue(self, sid, snap, digest, op="config", fmt=""):
        n = secrets.token_urlsafe(18)
        self._n[n] = (sid, snap, digest, op, fmt, time.time() + self.ttl)
        # 顺手清过期的, 免得长期运行的服务里越积越多
        for k, v in list(self._n.items()):
            if v[5] < time.time():
                self._n.pop(k, None)
        return n

    def consume(self, n, sid, snap, digest, op="config", fmt=""):
        """一次性核销。会话/快照/摘要/操作类型/**快照结构版本**五项全对才算数, 且不提示是
        哪一项不对。
        op 维度: 否则"恢复受管配置"的确认票能被拿去执行整机完整恢复。
        fmt 维度: 旧结构(legacy-dnsdist)要走更强的确认, 而**票据本身**就得区分开 —— 否则在
        v1.6 页面上拿到的票, 换个快照就能绕过旧结构那道更强的门。"""
        rec = self._n.pop(n, None)
        if not rec:
            return False
        s_, sn_, dg_, op_, fmt_, exp = rec
        if time.time() > exp:
            return False
        return (_ct_eq(s_, sid) and _ct_eq(sn_, snap) and _ct_eq(dg_, digest)
                and _ct_eq(op_, op) and _ct_eq(fmt_, fmt))


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
                "<p class=warn>输 token 之前先核对证书指纹 —— 指纹要从 SSH 上 "
            "<code>sudo pdg rescue fingerprint</code> 单独取, <b>不要</b>拿本页显示的那串"
            "核对本页(伪造页面的人也能伪造页面上的指纹)。浏览器看不到完整 SHA-256 时不要输 token。</p>"
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
    cap = caps()
    if not tx["available"]:
        txline = ("<p class=bad>事务核心不可用 —— 「事务 recover」与「恢复受管配置」已禁用(%s)。"
                  "状态页与紧急完整恢复不受影响。<a href=/tx>详情</a></p>" % DEGRADED)
    elif tx["pending"]:
        txline = ("<p class=bad>有 %d 笔未完成的事务, 写操作会被拒绝。"
                  "<a href=/tx>查看</a></p>" % len(tx["pending"]))
    else:
        txline = "<p class=ok>没有未完成的事务。<a href=/tx>查看历史</a></p>"
    # 能力一览: 哪些还能用、哪些"旧核心不支持"。降级是可以接受的状态, 但必须是**看得见**的。
    cap_rows = "".join(
        _row(label, "可用" if cap[k] else DEGRADED, "ok" if cap[k] else "bad")
        for k, label in (("pdgtx", "事务核心(recover)"),
                         ("cfgrestore", "恢复受管配置"),
                         ("emergency", "紧急默认出口"),
                         ("breakglass", "紧急完整恢复")))
    last = last_breakglass()
    if last:
        pre = last.get("pre_rescue_snapshot") or ""
        cap_rows += _row("上次完整恢复", "%s · %s" % (
            time.strftime("%m-%d %H:%M", time.localtime(last.get("ts") or 0)),
            str(last.get("state") or "")))
        # pre-rescue ID 是"换回去"的唯一凭据 —— 结果页关掉了、服务重启了, 它都得还在
        cap_rows += _row("可用于换回的 pre-rescue 快照",
                         ("<a href='/breakglass/%s'>%s</a>" % (html.escape(pre), html.escape(pre)))
                         if pre else "(无)")
    return page("PDG 救援 · 状态",
                "<h1>状态总览</h1><h2>服务</h2><table>%s</table>"
                "<h2>系统</h2><table>%s</table><h2>配置事务</h2>%s"
                "<h2>恢复能力</h2><table>%s</table>"
                "<h2>其它</h2><p><a href=/emergency>紧急默认出口</a> · "
                "<a href=/snapshots>快照列表</a> · "
                "<a href=/audit>审计(脱敏)</a> · <a href=/logout>退出</a></p>"
                % (rows, sys_rows, txline, cap_rows))


# 这句话必须原样出现在页面上。用户看到"紧急默认出口"很容易理解成"全部流量强制走这一个",
# 于是在排障时得出完全错误的结论(比如以为某个域名也走了这条链路)。实际只换 route.final。
EMERGENCY_SCOPE = ("紧急默认出口只修改 route.final。已有高优先级规则仍会命中各自出口, "
                   "这不是全局强制单出口。")
# 候选是从**当前模型**枚举出来的, 只说明"这个出口配置在那儿"。这里刻意**不做**任何公网可达性
# 探测: 用户打开这个页面时往往正处在网络不通的状态, 探测只会把本来就慢的页面拖住, 还可能把
# "探不通"误判成"这个出口不能选" —— 而那恰恰可能是他唯一能用的那个。
EMERGENCY_REACH = "候选仅表示配置存在, 不保证当前网络可达。"


def emergency_page(csrf, nonce, msg="", cls="warn"):
    """紧急默认出口页。GET 纯读 —— 状态只看不写。"""
    em = _emergency()
    if em is None:
        return degraded_page("紧急默认出口", why="事务核心或紧急出口模块不可用")
    stt = _emergency_status()
    if stt is None:
        return degraded_page("紧急默认出口", why="读不到当前数据模型")
    cur = stt["current_final"]
    if stt["stale"]:
        state_txt, state_cls = "已过期(stale)", "bad"
    elif stt["active"]:
        state_txt, state_cls = "启用中", "warn"
    else:
        state_txt, state_cls = "未启用", "ok"
    rows = _row("紧急模式状态", state_txt, state_cls) \
        + _row("当前 route.final", cur if cur is not None else "(未设置)")
    if stt["active"]:
        rows += _row("启用前的原出口",
                     (stt["original_final"] if stt["original_present"] else "(原本没有 route.final)")) \
            + _row("当前紧急出口", stt["emergency_final"]) \
            + _row("启用时间", time.strftime("%Y-%m-%d %H:%M",
                                             time.localtime(stt["enabled_at"] or 0)))
    note = ""
    if stt["stale"]:
        note = ("<p class=bad>当前默认出口已经不是记录里的紧急出口了 —— 这期间有别的入口"
                "(Bot / CLI / 配置恢复 / 完整恢复)改过配置。一键恢复**已停用**: 拿旧记录覆盖"
                "过去会把你后来的修改抹掉。要继续用紧急出口, 请在下面**重新选一次** ——"
                "那时会以当前值作为新的原值。</p>")
    elif stt["active"] and not stt["original_available"]:
        note = ("<p class=bad>启用前的原出口 <code>%s</code> 现在已经不存在了, 恢复无法进行。"
                "状态会保留 —— 把它加回来, 或直接选一个出口作为新的默认。</p>"
                % html.escape(str(stt["original_final"])))
    opts = "".join("<option value='%s'>%s</option>" % (html.escape(t), html.escape(t))
                   for t in stt["candidates"])
    hidden = ("<input type=hidden name=csrf value='%s'>"
              "<input type=hidden name=nonce value='%s'>" % (csrf, nonce))
    forms = ""
    if stt["candidates"]:
        forms = ("<form method=post action=/emergency/enable>%s"
                 "<label>把默认出口(route.final)换成: <select name=tag>%s</select></label>"
                 "<br><button type=submit>%s</button></form>"
                 % (hidden, opts, "切换紧急出口" if stt["active"] else "启用紧急默认出口"))
    else:
        forms = "<p class=bad>当前模型里没有可用的出口, 无法设置。</p>"
    if stt["active"] and not stt["stale"] and stt["original_available"]:
        forms += ("<form method=post action=/emergency/restore>%s"
                  "<br><button type=submit>一键恢复到启用前</button></form>" % hidden)
    return page("PDG 救援 · 紧急默认出口",
                "<h1>紧急默认出口</h1>"
                "<p class=warn>%s</p>"
                "<p class=muted>%s</p>"
                "<table>%s</table>%s"
                "<h2>会改什么</h2>"
                "<ul><li>只改数据模型里的 <code>route.final</code>, 以及由它派生的 mihomo 配置;</li>"
                "<li>分流规则、优先级、规则集**一个字都不动**;</li>"
                "<li>model / mihomo 配置 / 救援状态在**同一笔事务**里落盘, 失败一起回滚;</li>"
                "<li>只重启内核(mihomo); mosdns、Bot、救援服务都不动。</li></ul>"
                "%s%s<p><a href=/>返回状态</a></p>"
                % (html.escape(EMERGENCY_SCOPE), html.escape(EMERGENCY_REACH), rows, note,
                   forms, ("<p class=%s>%s</p>" % (cls, html.escape(msg))) if msg else ""))


def emergency_result_page(res, action):
    rows = _row("操作", action) + _row("事务", res.get("txid") or "(无)") \
        + _row("结果", res.get("state") or "", "ok" if res.get("ok") else "bad")
    if res.get("changed"):
        rows += _row("本次改动的目标", "、".join(res["changed"]))
    if res.get("executed_actions"):
        rows += _row("执行的服务动作", "、".join(res["executed_actions"]) or "(无)")
    if res.get("note"):
        rows += _row("说明", res["note"])
    if res.get("error"):
        rows += _row("错误", res["error"], "bad")
    tail = ("<p class=ok>已生效。</p>" if res.get("ok")
            else "<p class=bad>未生效 —— 事务已回滚到操作前, 现网配置没有半套状态。</p>")
    return page("PDG 救援 · 紧急默认出口结果",
                "<h1>紧急默认出口 · %s</h1><table>%s</table>%s"
                "<p class=muted>%s</p>"
                "<p><a href=/emergency>返回</a> · <a href=/>状态总览</a></p>"
                % (html.escape(action), rows, tail, html.escape(EMERGENCY_SCOPE)))


def degraded_page(what, snap_id="", why="事务核心不可用"):
    """某个功能因为"旧核心不支持"而不可用时的页面。

    要点是**不报错**: 用户走到这里通常是刚做完一次完整恢复, 机器正处在半旧不新的状态 ——
    这时候一个 500 或者堆栈只会让人以为救援平面也挂了。所以说清三件事: 为什么不可用、
    什么仍然可用、下一步怎么走。"""
    more = ("<p><a href='/breakglass/%s'>用这份快照做紧急完整恢复</a>(仍然可用)</p>"
            % html.escape(snap_id)) if snap_id else ""
    return page("PDG 救援 · %s" % what,
                "<h1>%s</h1>"
                "<p class=bad>%s: %s(缺失、损坏或版本不兼容), 本功能已禁用。</p>"
                "<p class=muted>这通常是刚做过一次紧急完整恢复的正常结果: "
                "<code>pdgtx.py</code> 与 <code>cfgrestore.py</code> 属于业务恢复范围, "
                "会被快照里的版本覆盖。</p>"
                "<h2>仍然可用</h2>"
                "<ul><li>状态总览与审计</li><li>紧急完整恢复(可再选 pre-rescue 快照换回来)</li></ul>"
                "%s<p><a href=/>返回状态</a> · <a href=/snapshots>快照列表</a></p>"
                % (html.escape(what), DEGRADED, html.escape(why), more))


def tx_page():
    t = tx_overview()
    if not t["available"]:
        return degraded_page("配置事务", why="事务核心不可用")
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
        can_cfg = _cfgrestore() is not None
        def _act(name):
            # 配置恢复不可用时**禁用**这个入口(纯文字, 不是链接), 但完整恢复照常给路 ——
            # 那是降级状态下把机器换回去的唯一办法。
            if can_cfg:
                return "<a href='/snapshot/%s'>查看可恢复的配置</a>" % html.escape(name)
            return ("<span class=muted>%s</span> · <a href='/breakglass/%s'>紧急完整恢复</a>"
                    % (DEGRADED, html.escape(name)))
        body = "<table><tr><th>快照</th><th>大小</th><th>时间</th><th></th></tr>" + "".join(
            "<tr><td>%s</td><td>%.1f MB</td><td>%s</td><td>%s</td></tr>" % (
                html.escape(s["name"]), s["size"] / 1048576.0,
                time.strftime("%Y-%m-%d %H:%M", time.localtime(s["mtime"])),
                _act(s["name"]))
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
                "<p class=muted>需要连二进制与 Bot 程序一起换回去? "
                "<a href='/breakglass/%s'>紧急完整恢复</a>(独立操作, 风险更高)</p>"
                "<p><a href=/snapshots>返回快照列表</a></p>"
                % (html.escape(snap_id), rows, tgt, miss, exc, form, html.escape(snap_id)))


# 旧结构快照的确认前缀。用户必须完整打出 `LEGACY-<末6位>` —— 比"末 6 位"多打 7 个字符,
# 目的不是防碰撞, 是让手指停一下: 旧结构恢复完可能连服务都起不来, 那不该和普通回滚一样顺手。
LEGACY_FMT = "legacy-dnsdist"
LEGACY_PREFIX = "LEGACY-"


def _expected_confirm(snap_id, fmt):
    """该输入什么。v1.6 = 末 6 位; 旧结构 = LEGACY-<末6位>。单一来源, 页面与校验共用。"""
    return (LEGACY_PREFIX if fmt == LEGACY_FMT else "") + (snap_id or "")[-6:]


def breakglass_confirm_page(snap_id, csrf, nonce, api=None, fmt="", digest="", err=""):
    """紧急完整恢复的确认页 —— 与配置恢复**分开**, 用词、票据、按钮都不共用。"""
    bg = _breakglass()
    if bg is None:
        return None
    api = api or _snap_api()
    if api is None or snap_id not in api.snapshot_ids():
        return None
    if err:
        return page("PDG 救援 · 紧急完整恢复",
                    "<h1>紧急完整恢复</h1><p class=bad>%s</p>"
                    "<p><a href=/snapshots>返回</a></p>" % html.escape(err))
    p = api.snapshot_path(snap_id)
    made = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(p))) if p else "?"
    rows = _row("快照 ID", snap_id) + _row("创建时间", made) + _row("来源", "本机 pdg snapshot") \
        + _row("结构版本", "%s(兼容性识别结果, 非快照自带声明)" % fmt) \
        + _row("内容摘要", digest[:16] + "…")
    protected = "".join("<li><code>%s</code></li>" % html.escape(os.path.basename(x))
                        for x in bg._protected_paths())
    hidden = ("<input type=hidden name=csrf value='%s'>"
              "<input type=hidden name=snapshot value='%s'>"
              "<input type=hidden name=digest value='%s'>"
              "<input type=hidden name=nonce value='%s'>"
              % (csrf, html.escape(snap_id), html.escape(digest), nonce))
    legacy_note = ""
    if fmt == LEGACY_FMT:
        legacy_note = ("<p class=bad>这是**旧结构**快照: 允许用于紧急完整恢复, 但恢复后"
                       "**不保证当前服务能启动** —— 恢复完请立刻在本页确认 mihomo/mosdns 状态, "
                       "必要时用 pre-rescue 快照回来。救援入口的保护对旧结构同样生效。</p>")
    if fmt not in ("v1.6", LEGACY_FMT):
        # unknown / 歧义结构: 不给表单, 也不给票 —— 连"手滑点一下"的机会都不留
        form = "<p class=bad>快照结构无法识别(%s), 拒绝执行。</p>" % html.escape(fmt)
    elif fmt == LEGACY_FMT:
        # 旧结构走**更强**的确认: 勾选 + 更长的固定格式 + 专属票据(票绑着 fmt, 见 Nonces)
        form = ("<form method=post action=/breakglass/restore>%s"
                "<label><input type=checkbox name=legacy_ack value=yes> "
                "我理解该旧快照恢复后可能无法启动当前 mihomo/mosdns</label><br>"
                "<label>请手工输入 <code>%s%s</code> 以确认: "
                "<input name=confirm_text autocomplete=off></label>"
                "<br><button type=submit>执行紧急完整恢复(旧结构)</button></form>"
                % (hidden, LEGACY_PREFIX, html.escape(snap_id[-6:])))
    else:
        form = ("<form method=post action=/breakglass/restore>%s"
                "<label>请手工输入快照 ID 的末 6 位以确认: "
                "<input name=confirm_text autocomplete=off></label>"
                "<br><button type=submit>执行紧急完整恢复</button></form>" % hidden)
    return page("PDG 救援 · 紧急完整恢复",
                "<h1>紧急完整恢复</h1><table>%s</table>"
                "<h2>会恢复什么</h2>"
                "<ul><li>mihomo / mosdns 的二进制与配置</li><li>Bot 程序与 bot.env</li>"
                "<li>平台与内核标记(platform / backend)</li><li>WLOC / MITM 配置</li>"
                "<li>快照正式覆盖的其它项目文件与 unit</li></ul>"
                "<h2>会保留什么</h2>"
                "<p>完整恢复覆盖 PDG 业务运行环境, 但保留当前救援入口, 避免恢复过程中失联。</p>"
                "<ul>%s</ul>"
                "<h2>对救援功能自身的影响</h2>"
                "<p>事务核心(<code>pdgtx.py</code>)与配置恢复模块(<code>cfgrestore.py</code>)"
                "**属于业务恢复范围**, 会被这份快照里的版本覆盖 —— 这是有意的, 它们不在保护清单里。</p>"
                "<ul><li>换成旧版之后,「恢复受管配置」与「事务 recover」可能不可用: "
                "届时页面会标注「%s」并禁用对应按钮, 不会报错页;</li>"
                "<li>**状态页与本页(紧急完整恢复)仍然保留** —— 它们不依赖这两个模块, "
                "救援服务重启后也能进到降级状态页, pre-rescue 快照 ID 仍可查。</li></ul>"
                "<h2>与「恢复受管配置」的区别</h2>%s"
                "<p class=bad>这个操作**没有 pdgtx 的二次自动回滚**。失败时只能靠本次操作前自动"
                "创建的 pre-rescue 快照, 或 SSH 手工处理。只想换配置请回到 "
                "<a href='/snapshot/%s'>恢复受管配置</a>。</p>%s"
                "<p><a href=/snapshots>返回快照列表</a></p>"
                % (rows, protected, DEGRADED, legacy_note, html.escape(snap_id), form))


def breakglass_result_page(res):
    """结果页: 字段全部 HTML 转义, 只呈现受控结构化结果。"""
    v = res.get("validation") or {}
    rows = _row("操作", res.get("operation", "")) + _row("快照", res.get("snapshot_id", "")) \
        + _row("操作前快照(pre-rescue)", res.get("pre_rescue_snapshot_id", "") or "(无)") \
        + _row("最终状态", res.get("final_state", ""),
               "ok" if res.get("final_state") == "RESTORED" else "bad")
    if res.get("error_class"):
        rows += _row("错误类别", res["error_class"], "bad")
    if res.get("failed"):
        rows += _row("失败项", "、".join(str(x) for x in res["failed"]), "bad")
    if res.get("protected"):
        rows += _row("全程保护(未被覆盖)", "%d 项: %s" % (
            len(res["protected"]), "、".join(os.path.basename(x) for x in res["protected"])))
    for k, label in (("protected_intact", "受保护文件全程未被改动"),
                     ("nft_applies", "防火墙应用次数(期望 1)"),
                     ("rescue_port_before", "恢复前救援端口放行"),
                     ("rescue_port_after", "恢复后救援端口放行"),
                     ("rescue_port_reopened", "救援端口已补回"),
                     ("rescue_service_untouched", "救援服务未被停止/重启"),
                     ("kernel", "mihomo"), ("dns", "mosdns")):
        if k in v:
            val = v[k]
            val = "、".join(str(x) for x in val) if isinstance(val, list) else str(val)
            rows += _row(label, val or "(无)")
    if res.get("audit_warning"):
        rows += _row("审计告警", res["audit_warning"], "warn")
    if res.get("detail"):
        rows += _row("恢复输出摘要(已脱敏)", res["detail"][-800:])
    if res.get("final_state") == "RESTORED":
        tail = "<p class=ok>完整恢复完成, 救援入口保持可用。</p>"
    else:
        tail = ("<p class=bad>这次恢复**没有**自动二次回滚。证据已保留 —— 下一步可以用操作前的"
                "pre-rescue 快照 <code>%s</code> 再恢复一次, 或用 SSH 登录后 "
                "<code>sudo pdg rollback --dir /var/lib/privdns-gateway/backups/%s</code> 处理。</p>"
                % (html.escape(res.get("pre_rescue_snapshot_id", "") or "(无)"),
                   html.escape(res.get("pre_rescue_snapshot_id", "") or "<id>")))
    return page("PDG 救援 · 完整恢复结果",
                "<h1>紧急完整恢复结果</h1><table>%s</table>%s"
                "<p><a href=/>返回状态</a> · <a href=/snapshots>返回快照</a></p>" % (rows, tail))


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
        """发响应。客户端提前断开只影响**这一次响应**, 不影响已经做完的事情。

        这条边界很实在: 完整恢复要跑十几秒, 用户等不及关掉标签页是常事。若断线冒出
        BrokenPipe 并被当成"操作失败", 事务结果就会被一次网络事件改写 —— 而事务此刻早已
        COMMITTED, 文件也已经落盘。所以这里把发送失败吞掉并只记一行, 绝不向上抛。"""
        try:
            self._send_inner(code, body, ctype, cookie, extra_headers)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as e:
            self.server.disconnects += 1
            sys.stderr.write("[rescue] 客户端提前断开, 响应未发出(%s); "
                             "已完成的操作不受影响\n" % type(e).__name__)

    def _send_inner(self, code, body=b"", ctype="text/html; charset=utf-8", cookie=None,
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
        elif path.startswith("/breakglass/"):
            snap = path[len("/breakglass/"):]
            # 完整恢复是最后一道门: cfgrestore 坏了也必须走得进来(_snap_api 会退到自带实现)
            api = _snap_api()
            if api is None or snap not in api.snapshot_ids():
                self._send(404, page("404", "<p>没有这份快照。</p>"))
                return
            sid = self._sid()
            _m, fmt, digest, err = _snap_facts(api, snap)
            # **独立**的一次性票: op 维度是完整恢复, 且绑着快照结构版本 —— 配置恢复的票、
            # 或者在 v1.6 快照页上拿到的票, 都到不了旧结构这道更强的门后面
            nonce = "" if (err or fmt not in ("v1.6", LEGACY_FMT)) else \
                self.server.nonces.issue(sid, snap, digest, OP_BREAKGLASS, fmt)
            body = breakglass_confirm_page(snap, self.server.sessions.csrf(sid), nonce,
                                           api=api, fmt=fmt, digest=digest, err=err)
            self._send(200, body) if body else self._send(404, page("404", "<p>没有这份快照。</p>"))
        elif path.startswith("/snapshot/"):
            snap = path[len("/snapshot/"):]
            cr = _cfgrestore()
            if cr is None:
                # 模块缺失/语法错/版本不兼容: 明说"旧核心不支持"并指向仍然可用的完整恢复,
                # 而不是丢一个 404 让人以为快照没了
                self._send(200, degraded_page("恢复受管配置", snap,
                                              why="配置恢复模块不可用"))
                return
            if snap not in cr.snapshot_ids():
                self._send(404, page("404", "<p>没有这份快照。</p>"))
                return
            sid = self._sid()
            _m, fmt, digest, err = _snap_facts(cr, snap)
            nonce = "" if err else self.server.nonces.issue(sid, snap, digest, OP_CONFIG, fmt)
            body = snapshot_confirm_page(snap, self.server.sessions.csrf(sid), nonce)
            self._send(200, body) if body else self._send(404, page("404", "<p>没有这份快照。</p>"))
        elif path == "/emergency":
            sid = self._sid()
            stt = _emergency_status()
            # 票绑当前**模型摘要**: 页面发出去之后模型被改过, 这张票就作废 —— 避免"看着 A
            # 的候选列表按下去, 落到 B 上"。fmt 维度复用成"当前 final", 同样参与绑定。
            digest = _emergency_digest(stt)
            nonce = self.server.nonces.issue(sid, "emergency", digest, OP_EMERGENCY,
                                             str((stt or {}).get("current_final")))
            self._send(200, emergency_page(self.server.sessions.csrf(sid), nonce))
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
        _m, fmt, digest_now, err = _snap_facts(cr, snap)
        if err or not digest_now or not _ct_eq(digest_now, digest):
            self._send(409, page("409", "<p class=bad>快照内容在确认之后发生了变化, 未执行任何"
                                        "操作。请回到快照页重新确认。</p>"))
            return
        if not self.server.nonces.consume(nonce, self._sid(), snap, digest, OP_CONFIG, fmt):
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

    def _post_breakglass(self):
        """紧急完整恢复。与配置恢复完全分开的入口、票据与按钮 —— 配置恢复失败**不会**自动
        走到这里, 只有用户明确来点这个页面才会执行。"""
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
        bg = _breakglass()
        if bg is None:
            self._send(503, page("503", "<p class=bad>完整恢复模块不可用, 请用 SSH 处理。</p>"))
            return
        # cfgrestore 可能正是上一次完整恢复换旧的那一个 —— 完整恢复不能因此做不了
        api = _snap_api()
        cr = _cfgrestore()
        snap = (form.get("snapshot") or [""])[0]
        digest = (form.get("digest") or [""])[0]
        nonce = (form.get("nonce") or [""])[0]
        typed = (form.get("confirm_text") or [""])[0].strip()
        acked = "yes" in (form.get("legacy_ack") or [])
        if api is None or snap not in api.snapshot_ids():
            self._send(404, page("404", "<p>没有这份快照。</p>"))
            return
        # 重新读盘: 确认页发出去之后, 快照文件可能被换过(定时任务/另一个会话/手工 scp)。
        # 摘要、成员、结构版本任一变化都中止 —— 否则用户确认的是 A, 执行的是 B。
        _members, fmt, digest_now, err = _snap_facts(api, snap)
        if err:
            self._send(409, page("409", "<p class=bad>快照现在读不出来(%s), 未执行任何操作。</p>"
                                 % html.escape(err)))
            return
        if fmt not in ("v1.6", LEGACY_FMT):
            self._send(400, page("400", "<p class=bad>快照结构无法识别(%s), 拒绝执行。</p>"
                                 % html.escape(fmt)))
            return
        if not digest_now or not _ct_eq(digest_now, digest):
            self._send(409, page("409", "<p class=bad>快照内容在确认之后发生了变化, 未执行任何"
                                        "操作。请回到快照页重新确认。</p>"))
            return
        # 旧结构走更强的确认: 勾选 + 更长的固定格式。缺一不可, 且分别给出明确原因。
        if fmt == LEGACY_FMT and not acked:
            self._send(400, page("400", "<p>未勾选旧结构风险确认, 未执行任何操作。</p>"))
            return
        # 手工输入: 让"点错了"和"真的要做"分开 —— 勾选框太容易顺手点过去。
        # 错误响应**不回显**用户输入, 也不回显期望值: 回显等于把确认字符从页面搬到了错误页,
        # 而错误页是最容易被截图、被缓存、被转发的那一个。
        if not typed or not _ct_eq(typed, _expected_confirm(snap, fmt)):
            self._send(400, page("400", "<p>确认字符不正确, 未执行任何操作。"
                                        "请返回确认页, 按页面上的提示重新输入。</p>"))
            return
        # 票据绑着 fmt: v1.6 的票用不到旧结构上, 反之亦然
        if not self.server.nonces.consume(nonce, self._sid(), snap, digest,
                                          OP_BREAKGLASS, fmt):
            self._send(409, page("409", "<p class=warn>这个确认已经用过或已失效(重复提交?)。"
                                        "请回到快照页重新确认。</p>"))
            return
        if not self.server.recover_gate.acquire(blocking=False):
            self._send(409, page("409", "<p class=warn>已有恢复操作正在执行, 请勿重复操作。</p>"))
            return
        self.log_message("breakglass %s", snap)
        try:
            res = bg.run(snap, expect_digest=digest, trigger_source="rescue", cfgrestore=cr)
        except Exception as e:  # noqa: BLE001
            self._send(500, page("500", "<p class=bad>完整恢复过程出错(%s), 请用 SSH 查看。</p>"
                                 % html.escape(type(e).__name__)))
            return
        finally:
            self.server.recover_gate.release()
            # 恢复很可能刚把 pdgtx.py / cfgrestore.py 换成了旧版。丢掉 import 缓存, 让**下一个
            # 请求**按盘上现在那份重新判定能力 —— 放在结果算完之后, 本次恢复与它的审计不受影响。
            _forget_business_modules()
        try:
            self._send(200, breakglass_result_page(res))
        except OSError:
            self.log_message("breakglass %s: 客户端已断开, 结果未能送达", snap)

    def _post_emergency(self, action):
        """紧急默认出口的启用/恢复。两者共用一套门: 会话 + CSRF + 与模型摘要绑定的一次性票。"""
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
        em = _emergency()
        if em is None:
            self._send(200, degraded_page("紧急默认出口", why="事务核心或紧急出口模块不可用"))
            return
        stt = _emergency_status()
        if stt is None:
            self._send(200, degraded_page("紧急默认出口", why="读不到当前数据模型"))
            return
        nonce = (form.get("nonce") or [""])[0]
        # 票绑当前模型摘要与当前 final: 页面发出去之后模型被改过, 这张票就不该还能用
        if not self.server.nonces.consume(nonce, self._sid(), "emergency",
                                          _emergency_digest(stt), OP_EMERGENCY,
                                          str(stt.get("current_final"))):
            self._send(409, page("409", "<p class=warn>这个确认已经用过或已失效"
                                        "(重复提交? 或配置在此期间变过)。请回到"
                                        " <a href=/emergency>紧急默认出口</a> 重新确认。</p>"))
            return
        if action == "enable":
            tag = (form.get("tag") or [""])[0]
            # **重新枚举**核对: HTTP 传什么进来都不算数, 只认当前模型里真实存在的出口
            if tag not in (stt.get("candidates") or []):
                self._send(400, page("400", "<p>这个出口不在当前模型里, 未执行任何操作。</p>"))
                return
        if not self.server.recover_gate.acquire(blocking=False):
            self._send(409, page("409", "<p class=warn>已有恢复操作正在执行, 请勿重复操作。</p>"))
            return
        self.log_message("emergency %s", action)
        try:
            if action == "enable":
                res = em.enable(tag, paths=_tx_paths(), trigger_source="rescue")
            else:
                res = em.restore(paths=_tx_paths(), trigger_source="rescue")
        except Exception as e:  # noqa: BLE001
            self._send(500, page("500", "<p class=bad>紧急默认出口操作出错(%s), 请用 SSH 查看。</p>"
                                 % html.escape(type(e).__name__)))
            return
        finally:
            self.server.recover_gate.release()
        code = 200 if res.get("ok") else (409 if res.get("busy") else 200)
        try:
            self._send(code, emergency_result_page(
                res, "启用/切换" if action == "enable" else "一键恢复"))
        except OSError:
            self.log_message("emergency %s: 客户端已断开, 结果未能送达", action)

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

    # 会真正落盘的写路径。draining 期间这些一律拒新的, 读路径照常 —— 停机时还能看状态,
    # 但不会再开一笔新事务。
    _WRITE_PATHS = ("/tx/recover", "/snapshot/restore", "/breakglass/restore",
                    "/emergency/enable", "/emergency/restore")

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in self._WRITE_PATHS:
            if self.server.draining.is_set():
                self._send(503, page("服务正在停止",
                                     "<p>救援服务正在停止(收到停止信号), 已不再接受新的写操作。</p>"
                                     "<p>在途的操作会跑完再退出。稍后服务会被 socket 重新拉起, "
                                     "那时再试。</p>"), extra_headers=(("Retry-After", "10"),))
                return
            self.server.write_begin()
            try:
                self._dispatch_write(path)
            finally:
                self.server.write_end()
            return
        self._dispatch_read(path)

    def _dispatch_write(self, path):
        if path == "/tx/recover":
            self._post_recover()
            return
        if path == "/snapshot/restore":
            self._post_cfg_restore()
            return
        if path == "/breakglass/restore":
            self._post_breakglass()
            return
        if path in ("/emergency/enable", "/emergency/restore"):
            self._post_emergency(path.rsplit("/", 1)[1])
            return
        self._send(405, page("405", "<p>这个操作不在救援平面的白名单里。</p>"))

    def _dispatch_read(self, path):
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


def _valid_bind(v):
    """监听地址只收 IPv4 字面量。主机名 / 0.0.0.0 / 广播 / 组播一律不收。"""
    try:
        ip = ipaddress.ip_address(v)
    except ValueError:
        return False
    if ip.version != 4:
        return False
    return not (ip.is_unspecified or ip.is_multicast or ip.is_reserved
                or str(ip) == "255.255.255.255")


def _peer_ip(addr):
    """从 accept 拿到的 peer 地址里取出规范化的 IP。

    IPv4-mapped IPv6(::ffff:1.2.3.4)必须先规范成 1.2.3.4 再判 —— 不然同一个来源换个协议
    栈写法就绕过了整条判断。"""
    try:
        ip = ipaddress.ip_address(addr[0])
    except (ValueError, IndexError, TypeError):
        return None
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip


class SourceGuard:
    """第二层来源限制: 只放行来自 PDG_INTERNAL_CIDR 的客户端。

    为什么 nft 之外还要一层: 真实网关必须把 socket 绑在一个可能全局可路由的地址上
    (来源段是客户端所在的运营商内网, 网关自己的地址在另一张网上)。那样一来, 防火墙一旦被
    清空、写错或恢复成旧版本, 这个恢复入口就直接暴露在公网。两层独立机制里任何一层还在,
    门就还是关的。

    判据只用**内核给的 peer 地址**。X-Forwarded-For / Forwarded 这类头一律不看 ——
    它们由客户端随便填, 拿它做访问控制等于没有访问控制。

    CIDR 解析不了 → fail-closed(谁都不放行), 绝不退化成"不限制来源"。
    """

    def __init__(self, cidr):
        self.raw = cidr
        try:
            self.net = ipaddress.ip_network(cidr, strict=False)
        except (ValueError, TypeError):
            self.net = None                      # 无效 → 全部拒绝

    def allows(self, addr):
        # 顺序有讲究: **先**判来源段能不能解析。解析不了就谁都不放行, 连回环也不例外 ——
        # 否则"配置坏掉"这件事会悄悄变成"限制放宽了", 而那正是最不该在恢复入口上发生的事。
        if self.net is None:
            return False
        ip = _peer_ip(addr)
        if ip is None:
            return False
        if ip.is_loopback:
            return True                          # 本机自检/受控测试
        try:
            return ip in self.net
        except TypeError:                        # v4 网段 vs v6 地址
            return False


class Draining(Exception):
    """收到 SIGTERM 之后到进程退出之间的窗口 —— 只拒新的写操作, 读照常。"""


class BlockedSource(OSError):
    """来源不在允许网段 —— 继承 OSError, socketserver 会当成"这次 accept 不算", 干净跳过。"""


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, token, ctx, fd=None, token_path=None, guard=None):
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
        # **不**在这里 wrap 监听 socket: 那样握手会发生在 accept 内部, 非法来源也能把我们
        # 拖进一次 TLS 协商(拿到证书、消耗 CPU)。改成每连接 wrap, 于是来源检查排在握手之前。
        self.ctx = ctx
        self.guard = guard or SourceGuard(None)
        self.rejected = 0                        # 被来源拦下的连接数(status 用, 不含地址)
        self.disconnects = 0                     # 客户端提前断开的次数(只做计数, 不含地址)
        self.draining = threading.Event()        # 收到 SIGTERM: 不再接受新的写操作
        self.inflight = threading.Semaphore(1)   # 在途写操作(与 pdgtx 的全局锁是两件事)
        self._inflight_n = 0
        self._inflight_lock = threading.Lock()

    def write_begin(self):
        """一笔写操作开始。draining 期间直接拒绝 —— 停机中再放新事务进来, 等于自找"停到一半
        又开了一笔"的局面。"""
        if self.draining.is_set():
            raise Draining("服务正在停止")
        with self._inflight_lock:
            self._inflight_n += 1

    def write_end(self):
        with self._inflight_lock:
            self._inflight_n = max(0, self._inflight_n - 1)

    def wait_inflight(self, timeout):
        """等在途写操作收尾。返回 True=都结束了。"""
        t0 = time.time()
        while time.time() - t0 < timeout:
            with self._inflight_lock:
                if self._inflight_n == 0:
                    return True
            time.sleep(0.2)
        with self._inflight_lock:
            return self._inflight_n == 0

    def get_request(self):
        """accept 之后**第一件事**就是判来源 —— 早于 TLS 握手, 更早于读 body/token/session。
        非法来源直接关掉连接: 拿不到登录页、拿不到证书、也分不出"token 对不对"。"""
        sock, addr = self.socket.accept()
        # systemd 交过来的监听 fd 可能是非阻塞的, accept 出来的连接会继承这一属性; 非阻塞
        # socket 上做 TLS 握手会立刻抛 SSLWantRead, 表现成客户端"握手超时"。以前 wrap 的是
        # 监听 socket, 这个属性由 SSLSocket.accept() 内部处理掉了, 换成逐连接 wrap 就露出来了。
        sock.setblocking(True)
        if not self.guard.allows(addr):
            self.rejected += 1
            try:
                sock.close()
            finally:
                raise BlockedSource("来源不在允许网段内")
        # 握手就发生在 accept 循环里(逐连接 wrap 与旧的"wrap 监听 socket"在这点上一样),
        # 所以必须给它一个超时: 一个连上就走的探测连接会让 do_handshake 一直等 ClientHello,
        # 整个服务在那期间**谁都服务不了**。超时后连接直接丢弃, 不当成错误。
        sock.settimeout(15)
        try:
            ssock = self.ctx.wrap_socket(sock, server_side=True)
        except (ssl.SSLError, OSError) as e:
            try:
                sock.close()
            finally:
                raise BlockedSource("TLS 握手未完成: %s" % type(e).__name__)
        ssock.settimeout(None)
        return ssock, addr

    def handle_error(self, request, client_address):
        """被来源拦下不是错误, 不该打印堆栈(也不该给攻击者留下可区分的日志噪音)。"""
        if sys.exc_info()[0] is BlockedSource:
            return
        super().handle_error(request, client_address)

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
        bind, port, cert, key, token, cidr = preflight()
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
    if fd is None and not bind:
        sys.stderr.write("[rescue] 拒绝启动: 没有 systemd 交接的监听 fd, 也没有配置 "
                         "PDG_RESCUE_BIND —— 无处可绑, 且绝不回落到 0.0.0.0。"
                         "请运行 sudo pdg rescue bind <IPv4>。\n")
        return 2
    # 第二层来源限制在这里装上。CIDR 解析不了 → SourceGuard 谁都不放行(fail-closed),
    # 服务绝不以"无来源限制"的形态跑起来。
    guard = SourceGuard(cidr)
    if guard.net is None:
        sys.stderr.write("[rescue] 拒绝启动: PDG_INTERNAL_CIDR=%r 解析不了 —— "
                         "不以无来源限制的形态启动。\n" % (cidr or "")[:40])
        return 2
    srv = Server((bind or "127.0.0.1", port), token, ctx, fd=fd,
                 token_path=C.paths()["PDG_RESCUE_TOKEN"],
                 guard=guard)

    # SIGTERM: 停止收新的写操作 → 等在途事务收尾 → 再退。
    #
    # 没有这段的话, systemd 一 stop 就把进程打断: 正在落盘的恢复停在 APPLYING, 现网处在
    # "新配置写了一半"的状态。pdgtx 的 pending/recover 是兜底(下一次写操作会 fail-closed
    # 并要求先 recover), 但能干净收尾就不该让用户走那条路。
    # 等待上限比 unit 的 TimeoutStopSec 略小 —— 超过它 systemd 会 SIGKILL, 那时留下 pending
    # 反而是对的: 与其硬拖, 不如把"没做完"这件事如实留在事务目录里。
    def _drain(signum, _frame):
        srv.draining.set()
        done = srv.wait_inflight(110)
        sys.stderr.write("[rescue] 收到信号 %d: 已停止接受新的写操作, 在途事务%s\n"
                         % (signum, "已收尾" if done else "仍未结束(交给 pdgtx 的 pending 兜底)"))
        threading.Thread(target=srv.shutdown, daemon=True).start()

    for _sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(_sig, _drain)
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

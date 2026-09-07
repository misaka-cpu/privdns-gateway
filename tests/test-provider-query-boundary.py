#!/usr/bin/env python3
"""管理面查询的**接收端边界**与**多故障判定优先级**。

v1.11.13 让 `check_rulesets` 去读 mihomo 管理面取运行期证据, 这一步本身是对的。但那次实现
留了三个洞, 本支逐个钉死:

  A. **接收端可能不是配置指向的那一个。** 查询走 `urllib.request.urlopen` 的默认 opener,
     它自带 ProxyHandler(读 `http_proxy`/`HTTP_PROXY` 等环境变量)与 HTTPRedirectHandler。
     于是: 环境里有代理时请求会交给代理; 管理面回一个 302 时会去请求 Location。
     而我们**带着 `Authorization: Bearer <secret>`** —— 凭据可能被送到另一个接收端。
     判据必须落在**真实接收次数与凭据是否越界**上, 不是"源码里有没有 urlopen"。

  B. **地址被静默改写。** `_clash_ctrl` 解析出 host 之后一律返回 `http://127.0.0.1:<port>`,
     配置写 `[::1]:9090` 也会被打到 IPv4 回环 —— 那可能是**另一个监听实例**。

  C. **确定性 FAIL 被 WARN 遮住。** 判定顺序是 incomplete → missing → empty, 于是"A 缺失 +
     B 缺 ruleCount"整体只报 WARN, 一个已经证实为死规则的 provider 被一条"无结论"盖掉。

  D. **地址门认的是"形状"而不是地址。** `^127\.\d+\.\d+\.\d+$` 这种正则会放行 `127.999.1.1`
     这类**非法数字地址**; 而 `localhost` 被直接放行, 于是真正连到哪里由系统解析器决定 ——
     检查对象与实际连接对象脱节。收紧成: 用 `ipaddress` 严格解析数字 IP 并看 `is_loopback`,
     主机名一律无结论、**不做解析**。

本支所有接收端都是**本轮自己起的回环端口(随机可用端口)**, 用自造 token, 不用真实 secret、
不访问公网或生产。**完整查询格会核对连接目标属于本格登记的服务**; 地址门那一格只调地址解析
函数, 不走网络。超时只用于回收故障夹具, 不作判据。
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402

PASS = [0]; FAIL = [0]
def ok(m):  PASS[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL[0] += 1; print("  ✗ %s" % m)

WD = tmpguard.mkdtemp(prefix="pdg-pqb.")
TOKEN = "acc-selfmade-token-2f9c41a7"          # 自造, 与任何真实 secret 无关

FULL = {"rs_a": {"name": "rs_a", "ruleCount": 13, "updatedAt": "2026-09-06T13:30:45Z"},
        "rs_b": {"name": "rs_b", "ruleCount": 44, "updatedAt": "2026-09-06T13:30:49Z"}}
META2 = {"rs_a": {"label": "A"}, "rs_b": {"label": "B"}}


class Rec(http.server.BaseHTTPRequestHandler):
    """记录每一次接收: 路径与是否带 Authorization。行为由 server.mode 决定。"""
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _record(self):
        self.server.hits.append({"path": self.path,
                                 "auth": self.headers.get("Authorization"),
                                 "host": self.headers.get("Host")})

    def do_GET(self):
        self._record()
        m = self.server.mode
        if m == "redirect":
            body = b""
            self.send_response(302)
            self.send_header("Location", self.server.location)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps({"providers": self.server.providers}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(mode="ok", providers=None, location=None, family=socket.AF_INET):
    class S(http.server.HTTPServer):
        address_family = family
    host = "127.0.0.1" if family == socket.AF_INET else "::1"
    srv = S((host, 0), Rec)
    srv.mode = mode; srv.providers = providers or FULL; srv.location = location
    srv.hits = []
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def addr_of(srv):
    a = srv.server_address
    return ("[%s]:%d" % (a[0], a[1])) if srv.address_family == socket.AF_INET6 else "%s:%d" % (a[0], a[1])


DRIVER = r'''
import importlib.util, json, os, socket, sys
# 记账 + 拦截: 解析与连接都要留痕; 目标不在本格登记的白名单里就**在发包前**拒掉。
# [["127.0.0.1", 41234], ...] -> {(host, port)}; json 给的是 list, 直接 set() 会 unhashable。
ALLOW = {(a, int(b)) for a, b in json.loads(sys.argv[4])}
STATS = {"getaddrinfo": 0, "connect": [], "blocked": []}
FAKE = json.loads(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else {}
_gai = socket.getaddrinfo
def gai(host, port, *a, **k):
    STATS["getaddrinfo"] += 1
    if host in FAKE:            # 模拟解析: 名字被解到一个**非回环**地址
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (FAKE[host], int(port)))]
    return _gai(host, port, *a, **k)
socket.getaddrinfo = gai
_conn = socket.socket.connect
def conn(self, addr):
    try:
        hp = (addr[0], int(addr[1]))
    except Exception:
        hp = (str(addr), -1)
    STATS["connect"].append(list(hp))
    if hp not in ALLOW:
        STATS["blocked"].append(list(hp))
        raise OSError("blocked-by-test: %s 不属于本格登记的回环服务" % (hp,))
    return _conn(self, addr)
socket.socket.connect = conn
spec = importlib.util.spec_from_file_location("checks", sys.argv[1])
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
c.MIHOMO_CFG = sys.argv[2]; c.RS_META = sys.argv[3]; c.SB = sys.argv[2] + ".nosuch"
base, why = c._clash_ctrl()
r = c.check_rulesets()
print(json.dumps({"base": base, "why": why, "res": list(r) if r else None, "stats": STATS}))
'''


def query(controller, meta=META2, secret=TOKEN, env=None, own=(), fake=None):
    """在**子进程**里跑一次真实查询(代理等环境变量只有新进程才确定生效)。

    `own` 是本格**自己起的**回环服务列表; 连接目标不在其中的, 在 socket.connect 里就被拦下并
    记账 —— 测试绝不去碰不属于本轮的监听端口。"""
    cfg = os.path.join(WD, "mihomo.json")
    d = {}
    if controller is not None: d["external-controller"] = controller
    if secret: d["secret"] = secret
    json.dump(d, open(cfg, "w", encoding="utf-8"))
    mp = os.path.join(WD, "rulesets.json")
    json.dump(meta, open(mp, "w", encoding="utf-8"))
    e = dict(os.environ)
    for k in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy", "no_proxy", "NO_PROXY"):
        e.pop(k, None)
    if env: e.update(env)
    allow = json.dumps([[srv.server_address[0], srv.server_address[1]] for srv in own])
    p = subprocess.run([sys.executable, "-c", DRIVER, str(ROOT / "deploy/bot/checks.py"), cfg, mp, allow,
                        json.dumps(fake or {})],
                       capture_output=True, text=True, timeout=60, env=e)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return {"base": None, "why": "驱动异常", "res": None, "stats": {"getaddrinfo": 0, "connect": [], "blocked": []},
                "err": (p.stdout + p.stderr)[:300]}


print("== A1. 管理面回 302: 不得请求 Location, 更不得把 Authorization 交给另一端 ==")
other = serve(mode="ok")
conf = serve(mode="redirect", location="http://%s/providers/rules" % addr_of(other))
r = query(addr_of(conf), own=(conf, other))
lvl = (r["res"] or [None])[0]
auth_leaked = [h for h in other.hits if h["auth"]]
if other.hits:
    bad("重定向目标收到了 %d 次请求(应 0); 其中带 Authorization 的 %d 次 —— 凭据越过了配置指向的接收端"
        % (len(other.hits), len(auth_leaked)))
elif lvl == "warn":
    ok("302 → 目标端 0 次接收, 判据给 warn(不把重定向后的响应当运行期证据)")
else:
    bad("302 → 目标端未被请求, 但判据给了 %s(应 warn): %s" % (lvl, (r["res"] or ["","",""])[2][:80]))
conf.shutdown(); other.shutdown()

print("== A2. 环境里有代理: 仍须直连配置端, 代理接收次数必须为 0 ==")
proxy = serve(mode="ok", providers={"proxied": {"name": "proxied", "ruleCount": 1}})
conf = serve(mode="ok")
paddr = "http://%s" % addr_of(proxy)
r = query(addr_of(conf), env={"http_proxy": paddr, "HTTP_PROXY": paddr, "all_proxy": paddr}, own=(conf, proxy))
lvl = (r["res"] or [None])[0]
pauth = [h for h in proxy.hits if h["auth"]]
if proxy.hits:
    bad("代理收到了 %d 次管理面请求(应 0); 其中带 Authorization 的 %d 次; 配置端实收 %d 次"
        % (len(proxy.hits), len(pauth), len(conf.hits)))
elif conf.hits and lvl == "ok":
    ok("代理 0 次接收, 配置端实收 %d 次, 判据正常给出 ok" % len(conf.hits))
else:
    bad("代理 0 次, 但配置端实收 %d 次 / 判据 %s" % (len(conf.hits), lvl))
conf.shutdown(); proxy.shutdown()

print("== A3. 凭据不得出现在文案里 ==")
conf = serve(mode="ok")
r = query(addr_of(conf), own=(conf,))
txt = json.dumps(r, ensure_ascii=False)
(ok if TOKEN not in txt else bad)("返回结构与文案里不含自造 token")
got_auth = [h for h in conf.hits if h["auth"] == "Bearer " + TOKEN]
(ok if got_auth else bad)("配置端确实收到了 Authorization(%d 次) —— 有鉴权路径仍能工作" % len(got_auth))
conf.shutdown()

print("== B. 地址门(只调地址解析函数, 零网络; 端口用不占用的高位号, 不连任何服务)==")
CTRL = r'''
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("checks", sys.argv[1])
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
c.MIHOMO_CFG = sys.argv[2]
print(json.dumps(list(c._clash_ctrl())))
'''


def ctrl(controller):
    """只问地址门, 不跑 check_rulesets —— 这一格一个包都不发。"""
    cfg = os.path.join(WD, "ctrl.json")
    json.dump({} if controller is None else {"external-controller": controller},
              open(cfg, "w", encoding="utf-8"))
    p = subprocess.run([sys.executable, "-c", CTRL, str(ROOT / "deploy/bot/checks.py"), cfg],
                       capture_output=True, text=True, timeout=30)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return [None, "驱动异常:" + (p.stdout + p.stderr)[:120]]


GATE = [
    ("127.0.0.1:45001", "http://127.0.0.1:45001", None),
    ("[::1]:45002",     "http://[::1]:45002",     None),
    ("127.0.0.53:45003","http://127.0.0.53:45003", None),
    ("127.999.1.1:45004", None, "不是合法"),
    ("localhost:45005",   None, "数字回环"),
    ("10.0.0.5:45006",    None, "不在回环"),
    (":45007",            None, "通配"),
    ("127.0.0.1:abc",     None, "端口"),
    ("127.0.0.1:0",       None, "端口"),
]
for raw, want_base, want_why in GATE:
    base, why = ctrl(raw)
    if want_base is not None:
        (ok if base == want_base else bad)("%-20s → %s" % (raw, base if base == want_base else "实得 %r(期望 %s)" % (base, want_base)))
    elif base is not None:
        bad("%-20s → 被放行为 %s(应拒绝: %s)" % (raw, base, want_why))
    elif want_why in (why or ""):
        ok("%-20s → 拒绝, 理由含「%s」: %s" % (raw, want_why, (why or "")[:44]))
    else:
        bad("%-20s → 拒绝了但理由不对(期望含 %r): %s" % (raw, want_why, why))

print("== B3. 名字不做解析: 模拟把 localhost 解到非回环地址, 解析与连接都必须为 0 次 ==")
# 拦截器在 socket.connect **发包之前**记账并拒绝, 全程不产生任何真实非回环连接;
# 也不改 hosts、不动系统 DNS。
r = query("localhost:45111", secret="", own=(), fake={"localhost": "203.0.113.7"})
st = r.get("stats") or {}
gai_n = st.get("getaddrinfo", -1)
conns = st.get("connect") or []
nonloop = [c for c in conns if not str(c[0]).startswith("127.") and c[0] != "::1"]
if gai_n == 0 and not conns:
    ok("localhost 在地址门就被拒(理由: %s); 解析 0 次、连接尝试 0 次" % (r["why"] or "")[:44])
else:
    bad("localhost 未在地址门拦下: 解析 %d 次, 连接尝试 %s(其中非回环 %s) —— "
        "检查对象与实际连接对象脱节" % (gai_n, conns, nonloop))
(ok if not nonloop else bad)("全程没有对非回环地址发起过连接(拦截器记录 %d 条被拦: %s)"
                             % (len(st.get("blocked") or []), (st.get("blocked") or [])[:2]))

print("== B2. IPv6 实连(隔离环境; 不可用则明确记录, 不冒充通过)==")
try:
    s6 = serve(family=socket.AF_INET6)
    r = query(addr_of(s6), secret="", own=(s6,))
    lvl = (r["res"] or [None])[0]
    if s6.hits and lvl == "ok":
        ok("[::1] 上的假管理面实收 %d 次, 判据给 ok —— IPv6 目标真的连通了" % len(s6.hits))
    else:
        bad("IPv6 实连未成立: 接收 %d 次, 判据 %s, base=%s why=%s" % (len(s6.hits), lvl, r["base"], r["why"]))
    s6.shutdown()
except OSError as e:
    print("  [SKIP] 本环境 IPv6 回环不可用(%s) —— 实连这一格未执行, 不计入通过" % e)

print("== C. 混合异常: 确定性 FAIL 不得被 WARN 遮住 ==")
cases = [
    ("A 缺失 + B 缺 ruleCount", {"rs_b": {"name": "rs_b"}}, "fail"),
    ("A 为 0 条 + B 缺 ruleCount", {"rs_a": {"name": "rs_a", "ruleCount": 0}, "rs_b": {"name": "rs_b"}}, "fail"),
    ("仅字段不完整", {"rs_a": {"name": "rs_a"}, "rs_b": {"name": "rs_b"}}, "warn"),
    ("仅缺失", {"rs_a": FULL["rs_a"]}, "fail"),
    ("仅 0 条", {"rs_a": dict(FULL["rs_a"], ruleCount=0), "rs_b": FULL["rs_b"]}, "fail"),
    ("全部正常", FULL, "ok"),
]
for label, provs, want in cases:
    srv = serve(mode="ok", providers=provs)
    r = query(addr_of(srv), secret="", own=(srv,))
    got = (r["res"] or [None])[0]
    msg = (r["res"] or ["", "", ""])[2]
    if got == want:
        ok("%-24s → %s" % (label, got))
    else:
        bad("%-24s → 实得 %s, 期望 %s: %s" % (label, got, want, msg[:90]))
    srv.shutdown()

print()
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""下载器的安全边界:scheme / host / 端口 / 重定向 / 地址族 / TLS / 代理。

这一支**不碰外网**。它起一个本地真 TLS 服务,用自签 CA 让客户端真的做证书校验,再把
resolver 与 connector 注入进去 —— 于是"校验过的那个地址是不是就是真正连上去的地址"
这种问题才有确定答案。用真实端点是测不出这些的:你没法让 anti-ad.net 给你回一个 302,
也没法让它把 A 记录换成 127.0.0.1。

三条要害,都是上一轮安全终审实测出来的:

  · **重定向**。urllib 默认跟随。实测让本地服务回 `302 → http://127.0.0.1:<port>/`,
    客户端照单跟过去并取回内容 —— 上游一旦被劫持或 DNS 被污染(对一个墙内 DNS 网关
    不是遥远的威胁模型), 它就能让网关去访问自己的回环与内网。
  · **scheme**。没有白名单时明文 http:// 照样能取。
  · **DNS 与实际连接地址必须绑定**。"先解析检查一遍, 再让 HTTP 客户端自己去解析一遍"
    等于没检查 —— 两次解析之间可以换答案(DNS rebinding)。判据要能证明只解析了一次,
    且连的就是校验过的那一个。
"""
import http.server
import importlib.util
import os
import socket
import ssl
import subprocess
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "deploy/bot/adblock.py"

PASS, FAIL = [0], []


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL.append(m)
    print("[FAIL] %s" % m)


spec = importlib.util.spec_from_file_location("adblock", MOD)
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)

WORK = Path(tmpguard.mkdtemp(prefix="adblock-fetchsec."))
HOST = "anti-ad.net"                       # 白名单里的正式主机名, 全程只在本地解析


def make_cert(cn, work):
    """自签一张覆盖 cn 的证书, 用来做**真的**主机名与证书校验。"""
    key, crt = work / ("%s.key" % cn), work / ("%s.crt" % cn)
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
         "-keyout", str(key), "-out", str(crt), "-subj", "/CN=%s" % cn,
         "-addext", "subjectAltName=DNS:%s" % cn],
        check=True, capture_output=True)
    return str(key), str(crt)


class Server:
    """本地 TLS 服务:可控状态码,并**记账收到了几次请求**(重定向有没有被跟随全靠它)。"""

    def __init__(self, work, cn=HOST, mode="ok"):
        self.mode = mode
        self.hits = []
        key, crt = make_cert(cn, work)
        self.ca = crt
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):                                  # noqa: N802
                outer.hits.append(self.path)
                if outer.mode.startswith("redirect"):
                    code = int(outer.mode.split(":")[1])
                    self.send_response(code)
                    self.send_header("Location", "http://127.0.0.1:%d/inner" % outer.port)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if outer.mode == "404":
                    self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
                    return
                body = ("\n".join("a%05d.invalid" % i for i in range(2000)) + "\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):                          # noqa: A002
                pass

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()


def client_ctx(ca):
    c = ssl.create_default_context(cafile=ca)
    return c


def fetch(url, srv, addrs=None, record=None, ctx=None, max_bytes=8 * 1024 * 1024):
    """调**生产** _safe_fetch,注入 resolver 与 connector。连接一律落到本地服务。"""
    def _resolve(host):
        record and record.setdefault("resolved", []).append(host)
        return addrs if addrs is not None else ["203.0.113.9"]

    def _connect(addr, port, timeout):
        record and record.setdefault("connected", []).append((addr, port))
        return socket.create_connection(("127.0.0.1", srv.port), timeout=timeout)

    return A._safe_fetch(url, max_bytes, resolve=_resolve, connect=_connect,
                         ssl_context=ctx or client_ctx(srv.ca))


f = getattr(A, "_safe_fetch", None)
if f is None:
    bad("adblock.py 缺少 _safe_fetch()(可注入 resolve / connect / ssl_context 的安全下载器)")
    print("-" * 58)
    print("通过 %d, 失败 %d" % (PASS[0], len(FAIL)))
    sys.exit(1)

srv = Server(WORK)

# ══ ① scheme / host / 端口 / URL 结构 ══════════════════════════════════════
print("══ ① URL 边界 ══")
cases = [
    ("明文 http://", "http://%s/domains.txt" % HOST),
    ("ftp://", "ftp://%s/domains.txt" % HOST),
    ("file://", "file:///etc/hostname"),
    ("非白名单主机", "https://evil.invalid/domains.txt"),
    ("相似后缀主机", "https://anti-ad.net.evil.invalid/domains.txt"),
    ("白名单主机的子域", "https://sub.%s/domains.txt" % HOST),
    ("userinfo", "https://user:pw@%s/domains.txt" % HOST),
    ("非 443 端口", "https://%s:8443/domains.txt" % HOST),
    ("IPv4 字面量", "https://203.0.113.9/domains.txt"),
    ("IPv6 字面量", "https://[2606:4700::1111]/domains.txt"),
]
for label, url in cases:
    srv.hits.clear()
    try:
        fetch(url, srv)
        bad("%s 被接受了(URL=%s)" % (label, url))
    except Exception:                                          # noqa: BLE001
        if srv.hits:
            bad("%s 虽被拒, 但**已经发出过请求**(应在连接前就拒)" % label)
        else:
            ok("%s → 连接前被拒" % label)

# 白名单里的正式 URL 必须能过
srv.hits.clear()
try:
    text, ctype, status = fetch("https://%s/domains.txt" % HOST, srv)
    (ok if status == 200 and "a00000.invalid" in text else bad)(
        "白名单 https 正式 URL 正常取回(%d 字节, %s)" % (len(text), ctype)
        if status == 200 else "正式 URL 取回异常: status=%s" % status)
except Exception as e:                                          # noqa: BLE001
    bad("白名单正式 URL 被误拒: %r" % (e,))

# ══ ② 重定向:一律不跟随 ════════════════════════════════════════════════════
print("══ ② 重定向 ══")
for code in (301, 302, 303, 307, 308):
    srv.mode = "redirect:%d" % code
    srv.hits.clear()
    try:
        fetch("https://%s/domains.txt" % HOST, srv)
        bad("%d 被跟随了" % code)
    except Exception:                                          # noqa: BLE001
        if len(srv.hits) == 1:
            ok("%d → 失败且**只发生一次请求**(没有第二跳)" % code)
        else:
            bad("%d 失败了, 但发出了 %d 次请求" % (code, len(srv.hits)))
srv.mode = "ok"

srv.mode = "404"
srv.hits.clear()
try:
    fetch("https://%s/domains.txt" % HOST, srv)
    bad("404 被当成成功")
except Exception:                                              # noqa: BLE001
    ok("404 → 失败(只接受 200)")
srv.mode = "ok"

# ══ ③ 非公网地址 ═══════════════════════════════════════════════════════════
print("══ ③ 地址族 ══")
NONPUB = ["127.0.0.1", "10.1.2.3", "172.16.5.6", "192.168.1.1", "169.254.1.1",
          "100.64.1.1", "0.0.0.0", "224.0.0.1", "255.255.255.255",
          "::1", "fc00::1", "fe80::1", "::", "ff02::1"]
for a in NONPUB:
    srv.hits.clear()
    try:
        fetch("https://%s/domains.txt" % HOST, srv, addrs=[a])
        bad("解析到 %s 却仍然连接了" % a)
    except Exception:                                          # noqa: BLE001
        (ok if not srv.hits else bad)(
            "解析到 %s → 连接前失败" % a if not srv.hits
            else "解析到 %s 被拒但已发出请求" % a)

# 公网 + 非公网混合 → 整次失败(不许挑一个能用的)
srv.hits.clear()
try:
    fetch("https://%s/domains.txt" % HOST, srv, addrs=["203.0.113.9", "127.0.0.1"])
    bad("公网+非公网混合时仍然连接了 —— 应整次失败")
except Exception:                                              # noqa: BLE001
    ok("公网与非公网混合 → 整次失败(不挑能用的那个)")

# ══ ④ DNS 结果与实际连接地址绑定 ═══════════════════════════════════════════
print("══ ④ DNS 与连接地址绑定 ══")
rec = {}
fetch("https://%s/domains.txt" % HOST, srv, addrs=["203.0.113.9"], record=rec)
(ok if rec.get("resolved") == [HOST] else bad)(
    "整个下载只解析了一次(%s)" % rec.get("resolved") if rec.get("resolved") == [HOST]
    else "解析次数不是一次: %r —— 两次解析之间可以换答案(rebinding)" % rec.get("resolved"))
(ok if rec.get("connected") == [("203.0.113.9", 443)] else bad)(
    "连接用的就是校验过的那个地址与端口 %r" % (rec.get("connected"),)
    if rec.get("connected") == [("203.0.113.9", 443)]
    else "连接地址与校验地址对不上: %r" % (rec.get("connected"),))

# ══ ⑤ TLS 仍以原主机名校验 ═════════════════════════════════════════════════
print("══ ⑤ TLS ══")
other = Server(WORK, cn="someone-else.invalid")
try:
    fetch("https://%s/domains.txt" % HOST, other, ctx=client_ctx(other.ca))
    bad("证书主机名对不上却通过了 —— hostname 校验被削弱")
except ssl.SSLCertVerificationError:
    ok("证书 CN/SAN 不是原主机名 → TLS 校验失败(以原 host 校验)")
except Exception as e:                                          # noqa: BLE001
    ok("证书不匹配 → 失败(%s)" % e.__class__.__name__)
finally:
    other.close()

ctx_default = ssl.create_default_context()
try:
    fetch("https://%s/domains.txt" % HOST, srv, ctx=ctx_default)
    bad("自签证书在系统 CA 下竟然通过了")
except Exception:                                              # noqa: BLE001
    ok("默认使用系统 CA(自签证书不被接受)")
(ok if ctx_default.verify_mode == ssl.CERT_REQUIRED and ctx_default.check_hostname else bad)(
    "默认 ssl 上下文: check_hostname=True, verify_mode=CERT_REQUIRED")

# ══ ⑥ 不继承环境代理 ═══════════════════════════════════════════════════════
print("══ ⑥ 代理 ══")
old = {k: os.environ.get(k) for k in ("HTTPS_PROXY", "https_proxy", "ALL_PROXY")}
try:
    for k in old:
        os.environ[k] = "http://127.0.0.1:9"
    rec2 = {}
    fetch("https://%s/domains.txt" % HOST, srv, addrs=["203.0.113.9"], record=rec2)
    (ok if rec2.get("connected") == [("203.0.113.9", 443)] else bad)(
        "设了 HTTPS_PROXY 仍直连校验过的地址(不采用环境代理)"
        if rec2.get("connected") == [("203.0.113.9", 443)]
        else "环境代理影响了连接目标: %r" % (rec2.get("connected"),))
finally:
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v

# ══ ⑦ 危险 URL 不得进入异常文案 ════════════════════════════════════════════
print("══ ⑦ 文案 ══")
try:
    fetch("https://user:SECRETPW@%s/domains.txt" % HOST, srv)
    bad("userinfo URL 没被拒")
except Exception as e:                                          # noqa: BLE001
    (ok if "SECRETPW" not in str(e) else bad)(
        "拒绝 userinfo 时不回显其中的口令" if "SECRETPW" not in str(e)
        else "异常文案里带出了口令: %s" % e)

srv.close()

# ══ ⑧ shell → Python 字面量插值(静态)═════════════════════════════════════
print("══ ⑧ shell/Python 边界 ══")
pdgsh = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
import re as _re
body = _re.search(r"^_adblock_status\(\)\{.*?^\}", pdgsh, _re.S | _re.M)
if not body:
    bad("抽不到 _adblock_status")
else:
    hits = _re.findall(r"'\"\$[A-Za-z_][A-Za-z0-9_]*\"'", body.group(0))
    (ok if not hits else bad)(
        "_adblock_status 里没有把 shell 变量插进 Python 字面量" if not hits
        else "仍有 %d 处 shell→Python 字面量插值: %s" % (len(hits), hits[:2]))

print("-" * 58)
print("通过 %d, 失败 %d" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)

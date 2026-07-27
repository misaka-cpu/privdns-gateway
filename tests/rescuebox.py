#!/usr/bin/env python3
"""救援平面测试的共享夹具: 起一个真实实例(自签证书 + 私网绑定 + 真 HTTPS)。

供 test-rescue-server.py(骨架行为)与 test-rescue-auth.py(凭据/认证硬化)共用 —— 两边各写
一份"怎么起服务、怎么发请求"迟早会漂移, 而漂移的那一份验的就不是同一个东西了。
"""
import http.client
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RESCUE = os.path.join(ROOT, "deploy/rescue/rescue.py")
TOKEN = "T0ken-for-tests-0123456789abcdef"
SENTINEL = "S3CRET-SENTINEL-rescue-4f9a"

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Inst:
    """一个跑起来的救援服务实例(绑 127.0.0.1, 端口临时分配)。"""

    def __init__(self, work, token=TOKEN, cert=True, cidr="127.0.0.0/8",
                 with_pdgtx=True, port=None, extra_env=None):
        self.work = work
        self.port = port or free_port()
        self.dir = tempfile.mkdtemp(prefix="inst.", dir=work)
        self.profile = os.path.join(self.dir, "profile.env")
        with open(self.profile, "w", encoding="utf-8") as f:
            f.write("PDG_LOWMEM=0\n")
            if cidr:
                f.write("PDG_INTERNAL_CIDR=%s\n" % cidr)
            f.write("PDG_BOT_TOKEN=123456789:%s\n" % SENTINEL)   # 页面里绝不能出现
        self.cert = os.path.join(self.dir, "cert.pem")
        self.key = os.path.join(self.dir, "key.pem")
        if cert:
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", self.key, "-out", self.cert, "-days", "1",
                            "-subj", "/CN=pdg-rescue-test"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        self.tokenf = os.path.join(self.dir, "token")
        if token is not None:
            with open(self.tokenf, "w", encoding="utf-8") as f:
                f.write(token + "\n")
        self.token = token
        self.with_pdgtx = with_pdgtx
        self.extra_env = dict(extra_env or {})     # 事务沙箱路径等, 由用例注入
        self.proc = None
        self.err = ""

    def env(self):
        e = dict(os.environ)
        e.update({"PDG_RESCUE_PORT": str(self.port), "PDG_RESCUE_DIR": self.dir,
                  "PDG_RESCUE_CERT": self.cert, "PDG_RESCUE_KEY": self.key,
                  "PDG_RESCUE_TOKEN": self.tokenf, "PDG_PROFILE_ENV": self.profile,
                  "PDG_RESCUE_BIND": "127.0.0.1",
                  "PYTHONPYCACHEPREFIX": os.path.join(self.work, "pycache")})
        e.update(self.extra_env)
        if not self.with_pdgtx:
            # 让 import pdgtx 必然失败: 只保留一个不含 pdgtx 的搜索路径
            e["PDG_RESCUE_NO_PDGTX"] = "1"
        return e

    def start(self, wait=8.0):
        env = self.env()
        script = RESCUE
        if not self.with_pdgtx:
            # 造一个"只有救援服务本体, 没有事务核心"的安装目录 —— 真机上 pdgtx.py 丢失/损坏
            # 就是这个样子。rescue_const 与它并排放着, 所以不会回落到仓库的 deploy/bot
            # (那里有 pdgtx, 一回落场景就没了)。
            d = tempfile.mkdtemp(prefix="nopdgtx.", dir=self.work)
            shutil.copy2(RESCUE, os.path.join(d, "rescue.py"))
            shutil.copy2(os.path.join(ROOT, "deploy/bot/rescue_const.py"),
                         os.path.join(d, "rescue_const.py"))
            shutil.copy2(os.path.join(ROOT, "lib/rescue.sh"), os.path.join(d, "rescue.sh"))
            script = os.path.join(d, "rescue.py")
        args = [sys.executable, script]
        self.proc = subprocess.Popen(args, env=env, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, universal_newlines=True)
        t0 = time.time()
        while time.time() - t0 < wait:
            if self.proc.poll() is not None:
                self.err = self.proc.stdout.read()
                return False
            try:
                c = socket.create_connection(("127.0.0.1", self.port), timeout=0.3)
                c.close()
                return True
            except OSError:
                time.sleep(0.1)
        return False

    def req(self, method, path, body=None, cookie=None):
        ctx = ssl._create_unverified_context()
        conn = http.client.HTTPSConnection("127.0.0.1", self.port, context=ctx, timeout=10)
        headers = {}
        if cookie:
            headers["Cookie"] = cookie
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read().decode("utf-8", "replace")
        setcookie = r.getheader("Set-Cookie") or ""
        hdrs = dict(r.getheaders())
        conn.close()
        return r.status, data, setcookie, hdrs

    def csrf(self):
        """像浏览器那样先 GET 一次: 拿到 pdgcsrf cookie 与表单里的同一个值。"""
        _st, body, sc, _h = self.req("GET", "/")
        m = re.search(r"pdgcsrf=([A-Za-z0-9_-]+)", sc)
        hidden = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body)
        return (m.group(1) if m else ""), (hidden.group(1) if hidden else "")

    def login(self, token=None):
        """像浏览器那样走完整流程, 返回 (状态码, 登录后应该带的 Cookie 串)。

        登录成功时服务端会**轮换** CSRF cookie 并绑定到新会话, 所以返回的 cookie 串里两个都带
        —— 只带 pdgsid 的话, 后续写操作的 CSRF 校验会因为"cookie 没了"而失败。"""
        c, hidden = self.csrf()
        body = "csrf=%s&token=%s" % (hidden or c, token if token is not None else self.token)
        st, _b, sc, _h = self.req("POST", "/login", body=body, cookie="pdgcsrf=" + c)
        sid = re.search(r"pdgsid=([A-Za-z0-9_-]+)", sc)
        newcsrf = re.search(r"pdgcsrf=([A-Za-z0-9_-]+)", sc)
        if not sid:
            return st, ""
        jar = "pdgsid=" + sid.group(1)
        if newcsrf and newcsrf.group(1):
            jar += "; pdgcsrf=" + newcsrf.group(1)
        return st, jar

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        if self.proc:
            try:
                self.err = (self.err or "") + (self.proc.stdout.read() or "")
            except Exception:  # noqa: BLE001
                pass
            self.proc.stdout.close()

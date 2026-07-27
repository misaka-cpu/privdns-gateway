#!/usr/bin/env python3
"""救援平面只读骨架的行为回归(5.2/commit 4)。

不 mock HTTP: 真的用自签证书起一个服务、真的发 HTTPS 请求、真的核对返回码与页面内容。
重点验的是"别的都坏了它还在"以及"永远不存在无认证状态":
  · 内网卡段真源 / 证书 / Token 任一缺失 → **拒绝启动**并说明原因(不降级、不猜);
  · 未认证只能看到登录页, 任何数据页面都是 401;
  · 事务核心不可用(pdgtx 导入失败)时页面仍然打得开, 并如实说明恢复功能不可用;
  · txid 只接受列表里出现过的, 路径穿越拿不到任何东西;
  · 页面不含任何外部资源、不含凭据。
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

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Inst:
    """一个跑起来的救援服务实例(绑 127.0.0.1, 端口临时分配)。"""

    def __init__(self, work, token=TOKEN, cert=True, cidr="127.0.0.0/8",
                 with_pdgtx=True, port=None):
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
        self.proc = None
        self.err = ""

    def env(self):
        e = dict(os.environ)
        e.update({"PDG_RESCUE_PORT": str(self.port), "PDG_RESCUE_DIR": self.dir,
                  "PDG_RESCUE_CERT": self.cert, "PDG_RESCUE_KEY": self.key,
                  "PDG_RESCUE_TOKEN": self.tokenf, "PDG_PROFILE_ENV": self.profile,
                  "PDG_RESCUE_BIND": "127.0.0.1",
                  "PYTHONPYCACHEPREFIX": os.path.join(self.work, "pycache")})
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

    def login(self):
        st, _b, sc, _h = self.req("POST", "/login", body="token=" + self.token)
        m = re.search(r"pdgsid=([A-Za-z0-9_-]+)", sc)
        return st, ("pdgsid=" + m.group(1)) if m else ""

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


work = tempfile.mkdtemp(prefix="rescue-test.")

# ── 1. 启动前提: 三项缺一不可, 缺了必须拒绝启动并说明 ───────────────────────
for label, kw, want in (("内网卡段真源缺失", {"cidr": ""}, "PDG_INTERNAL_CIDR"),
                        ("证书缺失", {"cert": False}, "自签证书"),
                        ("Token 缺失", {"token": None}, "Token")):
    inst = Inst(work, **kw)
    started = inst.start(wait=4.0)
    inst.stop()
    if not started and want in (inst.err or ""):
        ok("%s → 拒绝启动并说明原因" % label)
    else:
        bad("%s 却启动了或没说明原因: started=%s err=%r" % (label, started, (inst.err or "")[:200]))

inst = Inst(work, token="short")
started = inst.start(wait=4.0)
inst.stop()
if not started and "Token 太短" in (inst.err or ""):
    ok("弱 Token → 拒绝启动(不以弱凭据起服务)")
else:
    bad("弱 Token 却启动了: %r" % (inst.err or "")[:200])

# ── 2. 正常实例: 认证与只读页面 ─────────────────────────────────────────────
inst = Inst(work)
if not inst.start():
    bad("正常实例起不来: %r" % (inst.err or "")[:400])
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("正常实例: 起来了并接受 TLS 连接")

st, body, _sc, hdrs = inst.req("GET", "/")
if st == 200 and "救援 Token" in body and "状态总览" not in body:
    ok("未认证访问 / → 只给登录页, 不泄漏任何状态")
else:
    bad("未认证的 / 返回不对: st=%s" % st)
for p in ("/tx", "/snapshots", "/audit", "/tx/whatever"):
    st, body, _sc, _h = inst.req("GET", p)
    if st != 401:
        bad("未认证访问 %s 应为 401, 实际 %s" % (p, st))
        break
else:
    ok("未认证访问所有数据页面 → 401")

st, _b, _sc, _h = inst.req("POST", "/login", body="token=wrong-token-xxxxxxxxxxxx")
if st == 401:
    ok("错误 Token → 401")
else:
    bad("错误 Token 返回 %s" % st)

st, cookie = inst.login()
if st == 200 and cookie:
    ok("正确 Token → 200 并下发会话 cookie")
else:
    bad("登录失败: st=%s cookie=%r" % (st, cookie))

_st, _b, sc, _h = inst.req("POST", "/login", body="token=" + TOKEN)
for attr in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
    if attr not in sc:
        bad("会话 cookie 缺少 %s: %r" % (attr, sc))
        break
else:
    ok("会话 cookie 带 HttpOnly / Secure / SameSite=Strict")

st, body, _sc, hdrs = inst.req("GET", "/", cookie=cookie)
if st == 200 and "状态总览" in body:
    ok("已认证: 状态页可打开")
else:
    bad("状态页打不开: st=%s" % st)
for unit in ("mosdns", "mihomo", "pdg-bot"):
    if unit not in body:
        bad("状态页没有列出 %s" % unit)
        break
else:
    ok("状态页列出了核心服务状态")
if "内网卡段" in body and "磁盘可用" in body:
    ok("状态页含系统信息(内网卡段/磁盘)")
else:
    bad("状态页缺系统信息")

# ── 3. 安全头 / 无外部资源 / 无凭据 ─────────────────────────────────────────
csp = hdrs.get("Content-Security-Policy", "")
if "default-src 'none'" in csp and hdrs.get("X-Frame-Options") == "DENY" \
        and hdrs.get("X-Content-Type-Options") == "nosniff" and hdrs.get("Cache-Control") == "no-store":
    ok("响应带 CSP / X-Frame-Options / nosniff / no-store")
else:
    bad("安全头不全: %r" % {k: hdrs.get(k) for k in
                            ("Content-Security-Policy", "X-Frame-Options",
                             "X-Content-Type-Options", "Cache-Control")})
pages = {}
for p in ("/", "/tx", "/snapshots", "/audit"):
    st, b, _sc, _h = inst.req("GET", p, cookie=cookie)
    pages[p] = b
    if st != 200:
        bad("%s 返回 %s" % (p, st))
allhtml = "".join(pages.values())
if not re.search(r"https?://(?!127\.0\.0\.1)", allhtml) and "<script" not in allhtml.lower():
    ok("四个页面均无外部资源引用、无 <script>")
else:
    bad("页面引用了外部资源或含脚本")
if SENTINEL not in allhtml and TOKEN not in allhtml:
    ok("页面不含 Token 与哨兵凭据")
else:
    bad("页面里出现了凭据")

# ── 4. txid 只认枚举值, 路径穿越拿不到东西 ──────────────────────────────────
for evil in ("/tx/../../etc/passwd", "/tx/..%2f..%2fetc%2fpasswd", "/tx/does-not-exist",
             "/tx/" + "A" * 200):
    st, b, _sc, _h = inst.req("GET", evil, cookie=cookie)
    if st not in (400, 404) or "root:" in b:
        bad("路径穿越/未知 txid 未被拒: %s → %s" % (evil, st))
        break
else:
    ok("未知 txid 与路径穿越一律 404, 不返回任何文件内容")

# ── 5. 只读: 任何写操作都被拒绝 ─────────────────────────────────────────────
st, _b, _sc, _h = inst.req("POST", "/tx/recover", body="txid=x", cookie=cookie)
if st == 405:
    ok("本版本的写操作端点一律 405(明确拒绝, 不装作 404)")
else:
    bad("写操作返回 %s" % st)

# ── 6. 请求体上限 ───────────────────────────────────────────────────────────
st, _b, _sc, _h = inst.req("POST", "/login", body="token=" + "x" * 20000)
if st == 413:
    ok("超大请求体 → 413")
else:
    bad("超大请求体返回 %s" % st)

# ── 7. 退出登录后会话立即失效 ───────────────────────────────────────────────
st, _b, _sc, _h = inst.req("GET", "/logout", cookie=cookie)
st2, _b2, _sc2, _h2 = inst.req("GET", "/tx", cookie=cookie)
if st == 200 and st2 == 401:
    ok("退出登录: 旧 cookie 立即失效")
else:
    bad("退出后 cookie 仍可用: %s/%s" % (st, st2))

# ── 8. 只监听指定地址(不是 0.0.0.0)────────────────────────────────────────
rc = subprocess.run(["ss", "-ltnp"], stdout=subprocess.PIPE, universal_newlines=True)
listening = [l for l in rc.stdout.splitlines() if ":%d " % inst.port in l]
if listening and all("0.0.0.0:%d" % inst.port not in l and "*:%d" % inst.port not in l
                    for l in listening):
    ok("只监听指定的私网地址, 没有 0.0.0.0 监听")
elif not listening:
    print("[INFO] ss 看不到监听行(容器权限), 该项由绑定参数与连接行为间接覆盖")
else:
    bad("出现了 0.0.0.0 监听: %r" % listening)
inst.stop()

# ── 9. 事务核心不可用时, 页面仍要打得开并如实说明 ───────────────────────────
inst2 = Inst(work, with_pdgtx=False)
if inst2.start():
    st, cookie2 = inst2.login()
    st2, body2, _sc, _h = inst2.req("GET", "/", cookie=cookie2)
    if st2 == 200 and "事务核心不可用" in body2:
        ok("pdgtx 不可用: 状态页仍打得开并如实说明恢复功能不可用")
    else:
        bad("pdgtx 不可用时的页面不对: st=%s" % st2)
    st3, body3, _sc, _h = inst2.req("GET", "/tx", cookie=cookie2)
    if st3 == 200 and "事务核心不可用" in body3:
        ok("pdgtx 不可用: 事务页如实说明, 不是 500")
    else:
        bad("事务页返回 %s" % st3)
else:
    bad("pdgtx 不可用的实例起不来: %r" % (inst2.err or "")[:300])
inst2.stop()

# ── 10. 收尾: 没有残留进程 ──────────────────────────────────────────────────
time.sleep(0.3)
alive = []
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")[:-1]
    except OSError:
        continue
    if any(b"rescue.py" in a for a in argv[1:]) and argv and b"python" in argv[0]:
        alive.append(pid)
if not alive:
    ok("测试结束: 没有残留的救援服务进程")
else:
    bad("残留进程: %s" % alive)
shutil.rmtree(work, ignore_errors=True)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

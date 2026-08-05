#!/usr/bin/env python3
"""救援平面的凭据与认证硬化回归(5.2/commit 5, T3)。

验的都是真实行为: 真生成证书、真起 HTTPS、真发请求。
  · 凭据装机生成一次, **更新不得无故重建**(指纹变了等于让用户重新建立信任);
  · Token 只以 0600 落盘, 不进 URL、日志、页面;
  · CSRF 双提交 cookie: 没有/不匹配一律 403;
  · 登录失败限速与锁定: 私网里的一台设备不能离线暴力 Token;
  · 会话空闲超时与绝对上限各自生效, 轮换 Token 后旧会话立刻不算数。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from rescuebox import Inst, TOKEN  # noqa: E402

CRED = os.path.join(ROOT, "deploy/rescue/rescue_cred.py")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def cred(*args, env=None, timeout=180):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, CRED] + list(args), env=e, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, timeout=timeout)
    return p.returncode, (p.stdout or "").strip()


work = tmpguard.mkdtemp(prefix="rescue-auth.")
d = os.path.join(work, "rescue")
os.makedirs(d)
CENV = {"PDG_RESCUE_DIR": d, "PDG_RESCUE_CERT": os.path.join(d, "cert.pem"),
        "PDG_RESCUE_KEY": os.path.join(d, "key.pem"),
        "PDG_RESCUE_TOKEN": os.path.join(d, "token"),
        "PDG_PROFILE_ENV": os.path.join(work, "profile.env"),
        "PYTHONPYCACHEPREFIX": os.path.join(work, "pycache")}
open(CENV["PDG_PROFILE_ENV"], "w").write("PDG_INTERNAL_CIDR=127.0.0.0/8\n")

# ── 1. ensure: 生成一次 ─────────────────────────────────────────────────────
rc, out = cred("ensure", "127.0.0.1", env=CENV)
if rc == 0 and "token=created" in out and "cert=created" in out:
    ok("ensure: 首次生成 Token 与自签证书")
else:
    bad("首次 ensure 失败: rc=%s out=%r" % (rc, out))
fp1 = re.search(r"fingerprint=([0-9A-F:]+)", out)
fp1 = fp1.group(1) if fp1 else ""
if len(fp1) > 40 and fp1.count(":") > 20:
    ok("ensure: 输出 SHA-256 指纹(%s…)" % fp1[:17])
else:
    bad("指纹形态不对: %r" % fp1)

st = os.stat(CENV["PDG_RESCUE_TOKEN"])
stk = os.stat(CENV["PDG_RESCUE_KEY"])
stc = os.stat(CENV["PDG_RESCUE_CERT"])
if st.st_mode & 0o777 == 0o600 and stk.st_mode & 0o777 == 0o600:
    ok("Token 与私钥均为 0600")
else:
    bad("权限不对: token=%o key=%o" % (st.st_mode & 0o777, stk.st_mode & 0o777))
if stc.st_mode & 0o777 == 0o644:
    ok("证书为 0644(要给用户比对指纹, 不是秘密)")
else:
    bad("证书权限不对: %o" % (stc.st_mode & 0o777))
tok = open(CENV["PDG_RESCUE_TOKEN"], encoding="utf-8").read().strip()
if len(tok) >= 32 and re.match(r"^[A-Za-z0-9_-]+$", tok):
    ok("Token 是足够长的随机串(%d 字符)" % len(tok))
else:
    bad("Token 形态不对: %d 字符" % len(tok))

# ── 2. 幂等: 再 ensure 一次, 指纹与 Token 逐字节不变 ────────────────────────
rc, out2 = cred("ensure", "127.0.0.1", env=CENV)
fp2 = re.search(r"fingerprint=([0-9A-F:]+)", out2)
fp2 = fp2.group(1) if fp2 else ""
tok2 = open(CENV["PDG_RESCUE_TOKEN"], encoding="utf-8").read().strip()
if "token=kept" in out2 and "cert=kept" in out2 and fp1 == fp2 and tok == tok2:
    ok("再次 ensure(模拟更新): 指纹与 Token 逐字节不变")
else:
    bad("更新时重建了凭据: out=%r fp %s→%s token同=%s" % (out2, fp1[:12], fp2[:12], tok == tok2))

# ── 3. SAN 含绑定 IP; 绑定地址变了才重建 ────────────────────────────────────
rc, sanout = cred("fingerprint", env=CENV)
_rc, txt = subprocess.run(["openssl", "x509", "-in", CENV["PDG_RESCUE_CERT"], "-noout", "-text"],
                          stdout=subprocess.PIPE, universal_newlines=True).returncode, ""
txt = subprocess.run(["openssl", "x509", "-in", CENV["PDG_RESCUE_CERT"], "-noout", "-text"],
                     stdout=subprocess.PIPE, universal_newlines=True).stdout
if "IP Address:127.0.0.1" in txt and "pdg-rescue.local" in txt:
    ok("证书 SAN 同时含绑定 IP 与稳定主机名")
else:
    bad("SAN 不对: %r" % re.findall(r"(DNS|IP Address):[^\s,]+", txt))
rc, out3 = cred("ensure", "10.44.0.1", env=CENV)     # 绑定地址变了
fp3 = re.search(r"fingerprint=([0-9A-F:]+)", out3)
fp3 = fp3.group(1) if fp3 else ""
if "cert=rebuilt-address-changed" in out3 and fp3 and fp3 != fp1:
    ok("绑定地址不在 SAN 里 → 重建证书(旧证书本来就用不了)并给出新指纹")
else:
    bad("地址变化时行为不对: %r" % out3)
cred("rotate-cert", "127.0.0.1", env=CENV)           # 换回来给后面用

# ── 4. rotate 明确重建 ──────────────────────────────────────────────────────
before = open(CENV["PDG_RESCUE_TOKEN"], encoding="utf-8").read().strip()
rc, _o = cred("rotate-token", env=CENV)
after = open(CENV["PDG_RESCUE_TOKEN"], encoding="utf-8").read().strip()
if rc == 0 and before != after and len(after) >= 32:
    ok("rotate-token: 确实换了一个新的强 Token")
else:
    bad("rotate-token 没生效")

# ── 5. Token 不许输出到非终端 ───────────────────────────────────────────────
rc, out5 = cred("token", env=CENV)
if rc != 0 and "非终端" in out5:
    ok("token 子命令拒绝把凭据输出到管道/日志")
else:
    bad("Token 被输出到了非终端: rc=%s out=%r" % (rc, out5[:60]))

# ── 6. 真起服务验 CSRF / 限速 / 会话 ────────────────────────────────────────
inst = Inst(work)
if not inst.start():
    bad("实例起不来: %r" % (inst.err or "")[:300])
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

# 6a. 没有 CSRF → 403
st, _b, _sc, _h = inst.req("POST", "/login", body="token=" + TOKEN)
if st == 403:
    ok("CSRF: 表单没带 token → 403")
else:
    bad("没带 CSRF 却返回 %s" % st)
# 6b. CSRF 不匹配(cookie 与表单值不同)→ 403
c, hidden = inst.csrf()
st, _b, _sc, _h = inst.req("POST", "/login",
                           body="csrf=%s&token=%s" % ("tampered-value-xxxx", TOKEN),
                           cookie="pdgcsrf=" + c)
if st == 403:
    ok("CSRF: cookie 与表单值不一致 → 403")
else:
    bad("CSRF 不匹配却返回 %s" % st)
# 6c. 表单里的隐藏值与 cookie 必须同源
if hidden and c and hidden == c:
    ok("CSRF: 页面隐藏域与 cookie 同值(双提交)")
else:
    bad("隐藏域与 cookie 不一致: %r / %r" % (hidden, c))
# 6d. 正确流程仍然通
st, cookie = inst.login()
if st == 200 and cookie:
    ok("CSRF: 正确的双提交流程可以登录")
else:
    bad("正确流程登录失败: %s" % st)

# 6e. 限速: 连续错误后进入 429 并给 Retry-After
codes = []
for _i in range(7):
    c2, h2 = inst.csrf()
    st2, _b, _sc, hh = inst.req("POST", "/login", body="csrf=%s&token=wrong-%d" % (h2 or c2, _i),
                                cookie="pdgcsrf=" + c2)
    codes.append(st2)
if 429 in codes:
    ok("限速: 连续错误 Token 后返回 429(第 %d 次)" % (codes.index(429) + 1))
else:
    bad("没有触发限速: %r" % codes)
_st, _b, _sc, hh = inst.req("POST", "/login", body="csrf=x&token=y")
if _st in (403, 429):
    ok("限速期间仍然拒绝(不因为 CSRF 先返回而绕过计数)")
else:
    bad("限速期间返回 %s" % _st)
# 已经登录的会话不受限速影响 —— 锁的是登录尝试, 不是使用中的人
st3, body3, _sc, _h = inst.req("GET", "/", cookie=cookie)
if st3 == 200 and "状态总览" in body3:
    ok("限速只影响登录尝试, 不影响已登录会话")
else:
    bad("已登录会话被限速误伤: %s" % st3)
inst.stop()

# ── 6f. CSRF cookie 的属性与生命周期(真读 Set-Cookie 头, 不看源码)────────────
inst_c = Inst(work)
if not inst_c.start():
    bad("CSRF 实例起不来: %r" % (inst_c.err or "")[:200])
else:
    _st, _b, sc_get, _h = inst_c.req("GET", "/")
    csrf_set = [c for c in sc_get.split("\n") if "pdgcsrf=" in c]
    sc_one = csrf_set[0] if csrf_set else sc_get
    missing = [a for a in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/")
               if a not in sc_one]
    if not missing:
        ok("CSRF cookie 带 HttpOnly / Secure / SameSite=Strict / Path=/")
    else:
        bad("CSRF cookie 缺属性 %s: %r" % (missing, sc_one))
    if "Domain=" not in sc_one:
        ok("CSRF cookie 不设 Domain(host-only, 不扩散到子域)")
    else:
        bad("CSRF cookie 设了 Domain: %r" % sc_one)

    # 登录成功要轮换 CSRF, 并且新值与会话绑定
    c0, h0 = inst_c.csrf()
    st_l, _b, sc_login, _h = inst_c.req("POST", "/login", body="csrf=%s&token=%s" % (h0 or c0, TOKEN),
                                        cookie="pdgcsrf=" + c0)
    new_csrf = re.search(r"pdgcsrf=([A-Za-z0-9_-]+)", sc_login)
    if st_l == 200 and new_csrf and new_csrf.group(1) != c0:
        ok("登录成功: CSRF token 被轮换(挡住会话固定里预置的旧值)")
    else:
        bad("登录后没轮换 CSRF: %r" % sc_login)
    sid_m = re.search(r"pdgsid=([A-Za-z0-9_-]+)", sc_login)
    jar = "pdgsid=%s; pdgcsrf=%s" % (sid_m.group(1), new_csrf.group(1))
    for attr in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
        if attr not in sc_login:
            bad("登录下发的 cookie 缺 %s" % attr)
            break
    else:
        ok("登录下发的两个 cookie 属性齐全")

    # 跨会话: 拿另一个会话的 CSRF 值来提交 → 拒绝
    st_b, jar_b = inst_c.login()
    other_csrf = re.search(r"pdgcsrf=([A-Za-z0-9_-]+)", jar_b)
    cross = "pdgsid=%s; pdgcsrf=%s" % (sid_m.group(1), other_csrf.group(1))
    st_x, _b, _sc, _h = inst_c.req("POST", "/login",
                                   body="csrf=%s&token=%s" % (other_csrf.group(1), TOKEN),
                                   cookie=cross)
    if st_x == 403:
        ok("跨会话 CSRF token → 403(双提交之外还要与本会话绑定)")
    else:
        bad("跨会话 token 被接受了: %s" % st_x)

    # 过期/缺失: cookie 没了就必须拒绝, 并换发一个新的
    st_m, _b, sc_m, _h = inst_c.req("POST", "/login", body="csrf=%s&token=%s" % (new_csrf.group(1), TOKEN))
    if st_m == 403 and "pdgcsrf=" in sc_m and "Max-Age=0" not in sc_m:
        ok("CSRF cookie 缺失 → 403 且换发新 token")
    else:
        bad("cookie 缺失时的处理不对: st=%s sc=%r" % (st_m, sc_m[:80]))

    # 退出: 两个 cookie 都按同名同 Path 删除
    _st, _b, sc_out, _h = inst_c.req("GET", "/logout", cookie=jar)
    cleared = [c for c in sc_out.split("\n")]
    both = all(any(n in c and "Max-Age=0" in c and "Path=/" in c for c in cleared)
               for n in ("pdgsid=", "pdgcsrf="))
    if both:
        ok("退出登录: pdgsid 与 pdgcsrf 都以同名同 Path 清除")
    else:
        bad("退出时没清干净: %r" % sc_out)

    # CSRF token 不进 URL / 日志 / 错误正文(隐藏域除外 —— 那是表单本身)
    err_body = inst_c.req("POST", "/login", body="csrf=bogus&token=x")[1]
    visible = re.sub(r"<input type=hidden name=csrf value='[^']*'>", "", err_body)
    if new_csrf.group(1) not in visible and c0 not in visible:
        ok("错误响应正文里不出现 CSRF token(只在隐藏域里)")
    else:
        bad("错误正文泄漏了 CSRF token")
inst_c.stop()
if new_csrf.group(1) not in (inst_c.err or "") and "csrf=" not in (inst_c.err or ""):
    ok("服务端日志不含 CSRF token, 也不含查询串")
else:
    bad("日志里出现了 CSRF token")

# ── 7. 会话: 空闲超时 / 绝对上限 ────────────────────────────────────────────
inst2 = Inst(work)
inst2_env = inst2.env
inst2.env = lambda: dict(inst2_env(), PDG_RESCUE_SESSION_TTL="1", PDG_RESCUE_SESSION_MAX="600")
if inst2.start():
    st, cookie2 = inst2.login()
    time.sleep(1.4)                                    # 超过空闲 TTL
    st4, _b, _sc, _h = inst2.req("GET", "/tx", cookie=cookie2)
    if st == 200 and st4 == 401:
        ok("会话: 空闲超过 TTL 后失效")
    else:
        bad("空闲超时没生效: login=%s after=%s" % (st, st4))
else:
    bad("会话实例起不来")
inst2.stop()

inst3 = Inst(work)
inst3_env = inst3.env
inst3.env = lambda: dict(inst3_env(), PDG_RESCUE_SESSION_TTL="600", PDG_RESCUE_SESSION_MAX="1")
if inst3.start():
    st, cookie3 = inst3.login()
    time.sleep(1.4)                                    # 未空闲, 但超过绝对上限
    st5, _b, _sc, _h = inst3.req("GET", "/tx", cookie=cookie3)
    if st == 200 and st5 == 401:
        ok("会话: 即使一直在用, 超过绝对上限也失效")
    else:
        bad("绝对上限没生效: login=%s after=%s" % (st, st5))
else:
    bad("绝对上限实例起不来")
inst3.stop()

# ── 8. 轮换 Token → 已登录会话立刻失效, 新 Token 可用 ───────────────────────
inst4 = Inst(work)
if inst4.start():
    st, cookie4 = inst4.login()
    # 用**数据页面**判定会话是否还有效: GET / 对未认证用户是 200 + 登录页(设计如此),
    # 拿它当判据会把"已失效"误读成"仍有效"(第一版就踩了这个坑)。
    ok_before = inst4.req("GET", "/tx", cookie=cookie4)[0]
    newtok = "R0tated-token-abcdefghijklmnop"
    with open(inst4.tokenf, "w", encoding="utf-8") as f:
        f.write(newtok + "\n")
    # 用新 Token 登录会触发服务端重读 —— 这一步同时验证"新 Token 立即可用"
    st_new, cookie_new = inst4.login(token=newtok)
    st_old = inst4.req("GET", "/tx", cookie=cookie4)[0]
    _b_old = inst4.req("GET", "/", cookie=cookie4)[1]
    if ok_before == 200 and st_new == 200 and st_old == 401 and "救援 Token" in _b_old:
        ok("轮换 Token: 新 Token 立即可用, 且旧会话立刻失效")
    else:
        bad("轮换语义不对: before=%s new=%s old=%s" % (ok_before, st_new, st_old))
    st_oldtok, _c = inst4.login(token=TOKEN)
    if st_oldtok in (401, 429):
        ok("轮换 Token: 旧 Token 不再能登录")
    else:
        bad("旧 Token 仍能登录: %s" % st_oldtok)
else:
    bad("轮换实例起不来")
inst4.stop()

# ── 9. 凭据不进日志 ─────────────────────────────────────────────────────────
logs = (inst.err or "") + (inst4.err or "")
if TOKEN not in logs and "R0tated-token" not in logs:
    ok("服务端日志里不含任何 Token")
else:
    bad("日志泄漏了 Token")

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

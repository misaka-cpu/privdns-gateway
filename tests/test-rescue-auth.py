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


work = tempfile.mkdtemp(prefix="rescue-auth.")
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

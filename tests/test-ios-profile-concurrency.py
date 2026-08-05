#!/usr/bin/env python3
"""生命周期的读-改-写必须整段在同一把锁里 —— 并发行为验证。

`iosstate` 的写操作原本是这个形状:

    meta = load()            # ← 锁外
    inputs = …; data = render(…)   # ← 锁外, 基于刚读到的 meta 算 revision
    with _Txn(lock=True):    # ← 到这里才拿锁
        写 current / previous / state

于是两个进程可以**同时**读到同一版记录, 各自算出"下一版 = 第 2 版", 再一前一后落盘:
后写的那个把先写的那一版**整个盖掉**, 而两边都收到"成功"。丢的不是提示, 是用户刚做的那次
配置变更 —— 而且 revision 还是连号的, 事后从记录上看不出中间少了一版。

判据不是"跑很多轮看会不会撞", 那种测试今天绿明天红。这里用**确定性交错**: 把子进程里的
`load()` 包一层, 让它读完之后停在栅栏上, 由测试决定另一个进程什么时候插进来。栅栏卡在
"读完了、还没拿锁"这个位置 —— 正是要证明存在的那个窗口。修好之后读发生在锁内, 同一个
栅栏就会卡在**持锁期间**, 于是另一个进程拿不到锁而被明确拒绝(fail-closed), 断言照样成立。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def newbox():
    root = tmpguard.mkdtemp(prefix="iosconc-")
    TMPS.append(root)
    for d in ("etc/privdns-gateway", "run", "var/lib/privdns-gateway"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    return root


def env_for(root):
    return dict(os.environ, PDG_TX_FSROOT=root,
                PDG_LOCKFILE=os.path.join(root, "run/privdns-gateway.lock"))


def meta_of(root):
    p = os.path.join(root, "etc/privdns-gateway/ios-profile.json")
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except OSError:
        return None


def art_sha(root, which="current"):
    p = os.path.join(root, "var/lib/privdns-gateway/ios-profile/%s.mobileconfig" % which)
    try:
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


def seed(root, host="dot.seed.example"):
    """先造出第 1 版, 两个并发进程都从它出发。"""
    code = (
        "import sys; sys.path.insert(0, %r)\n"
        "import iosstate as S\n"
        "S.generate(%r, '203.0.113.10', (), b'', False, %r)\n" % (BOTDIR, host, TMPL))
    r = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                       capture_output=True, text=True, timeout=180)
    assert r.returncode == 0, r.stderr[-300:]


def wait_for(path, timeout=60):
    """等一个栅栏文件出现。忙等而不是 sleep —— 这里要的是"另一端到位了"这个事实。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        os.stat(os.path.dirname(path))      # 触发一次真实系统调用, 不空转
    return False


# 子进程: 把 load() 包一层, 读完停在栅栏上。栅栏卡在"读完、未拿锁"处 —— 修好之后这个位置
# 就落在锁内, 交错结果随之改变, 而断言不变。
PAUSED = r'''
import json, os, sys, time
sys.path.insert(0, %(botdir)r)
import iosstate as S
READY, GO = %(ready)r, %(go)r
_orig = S.load
_hit = []
def patched(path=None):
    m = _orig(path)
    if not _hit:                       # 只在第一次读时停 —— 后面锁内重读不再卡
        _hit.append(1)
        open(READY, "w").close()
        while not os.path.exists(GO):
            os.stat(os.path.dirname(GO))
    return m
S.load = patched
out = {"ok": False}
try:
    meta, lv, why, data, changed = S.generate(%(host)r, "203.0.113.10", (), b"", False, %(tmpl)r)
    out = {"ok": True, "rev": meta["current"]["revision"],
           "host": meta["current"]["inputs"]["dot_host"],
           "sha": meta["current"]["sha256"]}
except Exception as e:
    out = {"ok": False, "err": type(e).__name__, "msg": str(e)[:120]}
open(%(res)r, "w").write(json.dumps(out, ensure_ascii=False))
'''


def run_plain(root, host):
    """不带栅栏的一次生成, 用来在对方停住时插进去。"""
    code = (
        "import json, sys; sys.path.insert(0, %r)\n"
        "import iosstate as S\n"
        "out={'ok':False}\n"
        "try:\n"
        "    m,l,w,d,c = S.generate(%r, '203.0.113.10', (), b'', False, %r)\n"
        "    out={'ok':True,'rev':m['current']['revision'],"
        "'host':m['current']['inputs']['dot_host'],'sha':m['current']['sha256']}\n"
        "except Exception as e:\n"
        "    out={'ok':False,'err':type(e).__name__,'msg':str(e)[:120]}\n"
        "print(json.dumps(out, ensure_ascii=False))\n" % (BOTDIR, host, TMPL))
    r = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                       capture_output=True, text=True, timeout=180)
    for line in reversed((r.stdout or "").splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    return {"ok": False, "err": "no-output", "msg": (r.stderr or "")[-200:]}


print("══ 一、两个进程从同一版出发, 不得都以同一个 revision 成功 ══")
root = newbox()
seed(root)
rev1 = meta_of(root)["current"]["revision"]
ready = os.path.join(root, "READY")
go = os.path.join(root, "GO")
res = os.path.join(root, "RES.json")
codeA = PAUSED % {"botdir": BOTDIR, "ready": ready, "go": go, "res": res,
                  "host": "dot.procA.example", "tmpl": TMPL}
A = subprocess.Popen([sys.executable, "-c", codeA], env=env_for(root),
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    if not wait_for(ready, 60):
        bad("A 没能停在栅栏上, 这组并发没验到")
        A.kill()
    else:
        ok("A 已读到第 %d 版并停在「读完、尚未落盘」处" % rev1)
        B = run_plain(root, "dot.procB.example")
        open(go, "w").close()
        A.wait(timeout=120)
        rA = json.loads(open(res, encoding="utf-8").read()) if os.path.exists(res) else \
            {"ok": False, "err": "no-result"}
        final = meta_of(root)
        print("       A=%r" % (rA,))
        print("       B=%r" % (B,))
        print("       最终记录: rev=%s host=%s" % (final["current"]["revision"],
                                                   final["current"]["inputs"]["dot_host"]))
        both_ok = rA.get("ok") and B.get("ok")
        if both_ok and rA.get("rev") == B.get("rev"):
            bad("两个进程都成功且都拿到第 %s 版 —— 同一个 revision 被用了两次" % rA.get("rev"))
        else:
            ok("没有出现「两个都成功且 revision 相同」")
        # 丢更新: 某一方被告知成功, 而最终记录里根本没有它写的东西
        lost = [n for n, r in (("A", rA), ("B", B))
                if r.get("ok") and r.get("sha") != final["current"]["sha256"]
                and r.get("host") != final["current"]["inputs"]["dot_host"]]
        if lost:
            bad("丢更新: %s 收到成功, 但最终记录里没有它写的那一版" % "/".join(lost))
        else:
            ok("没有丢更新: 每个收到成功的进程, 它写的那一版都还在记录里")
        # 记录与产物必须自洽
        st = art_sha(root)
        if st == final["current"]["sha256"]:
            ok("最终记录与盘上产物一致(sha 相同)")
        else:
            bad("记录说 %s…, 盘上是 %s…" % (final["current"]["sha256"][:12], (st or "无")[:12]))
finally:
    if A.poll() is None:
        A.kill()

print()
print("══ 二、repair 与 generate 并发之后, 记录与产物仍要自洽 ══")
root = newbox()
seed(root)
os.unlink(os.path.join(root, "var/lib/privdns-gateway/ios-profile/current.mobileconfig"))
ready = os.path.join(root, "READY2")
go = os.path.join(root, "GO2")
res = os.path.join(root, "RES2.json")
REPAIR = r'''
import json, os, sys
sys.path.insert(0, %(botdir)r)
import iosstate as S
READY, GO = %(ready)r, %(go)r
_orig = S.load
_hit = []
def patched(path=None):
    m = _orig(path)
    if not _hit:
        _hit.append(1)
        open(READY, "w").close()
        while not os.path.exists(GO):
            os.stat(os.path.dirname(GO))
    return m
S.load = patched
out = {"ok": False}
try:
    m = S.repair_current(b"", %(tmpl)r)
    out = {"ok": True, "rev": m["current"]["revision"]}
except Exception as e:
    out = {"ok": False, "err": type(e).__name__, "msg": str(e)[:120]}
open(%(res)r, "w").write(json.dumps(out, ensure_ascii=False))
''' % {"botdir": BOTDIR, "ready": ready, "go": go, "res": res, "tmpl": TMPL}
R = subprocess.Popen([sys.executable, "-c", REPAIR], env=env_for(root),
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    if not wait_for(ready, 60):
        bad("repair 没能停在栅栏上")
        R.kill()
    else:
        G = run_plain(root, "dot.newver.example")
        open(go, "w").close()
        R.wait(timeout=120)
        rR = json.loads(open(res, encoding="utf-8").read()) if os.path.exists(res) else {}
        final = meta_of(root)
        print("       repair=%r  generate=%r" % (rR, G))
        code = ("import sys; sys.path.insert(0, %r)\n"
                "import iosstate as S, json\n"
                "m = S.load()\n"
                "print(json.dumps(list(S.artifact_health(m, 'current'))))\n" % BOTDIR)
        h = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                           capture_output=True, text=True, timeout=120)
        state = json.loads([l for l in h.stdout.splitlines() if l.startswith("[")][-1])[0] \
            if h.returncode == 0 and "[" in h.stdout else "?"
        if state == "healthy" and art_sha(root) == final["current"]["sha256"]:
            ok("并发之后 current 仍 healthy, 且与记录 sha 一致(第 %s 版)"
               % final["current"]["revision"])
        else:
            bad("并发之后自相矛盾: health=%s 记录=%s… 盘上=%s…"
                % (state, final["current"]["sha256"][:12], (art_sha(root) or "无")[:12]))
finally:
    if R.poll() is None:
        R.kill()

print()
print("══ 三、发送旧版期间并发出新版, mark_sent 不得给新版盖章 ══")
root = newbox()
seed(root)
sent_meta = meta_of(root)
sent_rev, sent_sha = sent_meta["current"]["revision"], sent_meta["current"]["sha256"]
run_plain(root, "dot.brandnew.example")          # 并发产生第 2 版
after = meta_of(root)
code = ("import sys, json; sys.path.insert(0, %r)\n"
        "import iosstate as S\n"
        "try:\n"
        "    st, m = S.mark_sent(expect_revision=%r, expect_sha256=%r)\n"
        "    print(json.dumps({'ok': True, 'status': st,"
        " 'sent_at': ((m or {}).get('current') or {}).get('sent_at')}))\n"
        "except TypeError as e:\n"
        "    print(json.dumps({'ok': False, 'err': 'TypeError', 'msg': str(e)[:120]}))\n"
        "except Exception as e:\n"
        "    print(json.dumps({'ok': False, 'err': type(e).__name__, 'msg': str(e)[:120]}))\n"
        % (BOTDIR, sent_rev, sent_sha))
r = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                   capture_output=True, text=True, timeout=180)
out = {}
for line in reversed((r.stdout or "").splitlines()):
    if line.startswith("{"):
        out = json.loads(line)
        break
final = meta_of(root)
print("       发送的是第 %s 版; 此刻记录是第 %s 版" % (sent_rev, final["current"]["revision"]))
print("       mark_sent → %r" % (out,))
if out.get("err") == "TypeError":
    bad("mark_sent 不接受 expect_revision/expect_sha256 —— 无法把标记绑定到真正发出去的那一版")
elif final["current"].get("sent_at"):
    bad("给第 %s 版盖了 sent_at, 而发出去的是第 %s 版"
        % (final["current"]["revision"], sent_rev))
elif out.get("status") != "superseded":
    bad("没盖章, 但返回状态不是 superseded: %r" % (out,))
else:
    ok("current 已经变成第 %s 版 → 返回 superseded 且不盖章, sent_at 仍为空"
       % final["current"]["revision"])

# 正常路径: 发送的就是当前版 → 必须盖上
root = newbox()
seed(root)
m0 = meta_of(root)
code = ("import sys, json; sys.path.insert(0, %r)\n"
        "import iosstate as S\n"
        "try:\n"
        "    st, m = S.mark_sent(expect_revision=%r, expect_sha256=%r)\n"
        "    print(json.dumps({'ok': True, 'status': st,"
        " 'sent_at': ((m or {}).get('current') or {}).get('sent_at')}))\n"
        "except Exception as e:\n"
        "    print(json.dumps({'ok': False, 'err': type(e).__name__, 'msg': str(e)[:120]}))\n"
        % (BOTDIR, m0["current"]["revision"], m0["current"]["sha256"]))
r = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                   capture_output=True, text=True, timeout=180)
if meta_of(root)["current"].get("sent_at"):
    ok("发送的就是当前版 → 正常盖上 sent_at")
else:
    bad("匹配的情况下反而没盖上: %s" % (r.stdout or r.stderr)[-160:])

print()
print("══ 四、recover 清残留时必须拿同一把锁, 不能删正在提交的候选 ══")
root = newbox()
seed(root)
art = os.path.join(root, "var/lib/privdns-gateway/ios-profile")
ready = os.path.join(root, "READY4")
go = os.path.join(root, "GO4")
HOLD = r'''
import os, sys, time
sys.path.insert(0, %(botdir)r)
import iosstate as S
# 模拟"事务正在进行": 持锁, 并在锁内放一个活跃候选文件
with S._Txn(lock=True):
    open(os.path.join(%(art)r, "current.mobileconfig.cand"), "w").write("active")
    open(%(ready)r, "w").close()
    while not os.path.exists(%(go)r):
        os.stat(os.path.dirname(%(go)r))
''' % {"botdir": BOTDIR, "art": art, "ready": ready, "go": go}
H = subprocess.Popen([sys.executable, "-c", HOLD], env=env_for(root),
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    if not wait_for(ready, 60):
        bad("持锁进程没起来")
        H.kill()
    else:
        code = ("import sys, json; sys.path.insert(0, %r)\n"
                "import iosstate as S\n"
                "try:\n"
                "    print(json.dumps({'ok': True, 'msgs': S.recover()}, ensure_ascii=False))\n"
                "except Exception as e:\n"
                "    print(json.dumps({'ok': False, 'err': type(e).__name__,"
                " 'msg': str(e)[:120]}, ensure_ascii=False))\n" % BOTDIR)
        rr = subprocess.run([sys.executable, "-c", code], env=env_for(root),
                            capture_output=True, text=True, timeout=180)
        cand_alive = os.path.exists(os.path.join(art, "current.mobileconfig.cand"))
        rout = {}
        for line in reversed((rr.stdout or "").splitlines()):
            if line.startswith("{"):
                rout = json.loads(line)
                break
        print("       recover → %r" % (rout,))
        if cand_alive:
            ok("活跃候选没被删掉(recover 要么等锁要么被拒)")
        else:
            bad("recover 把正在提交的候选删了 —— 它没拿锁")
        open(go, "w").close()
        H.wait(timeout=120)
finally:
    if H.poll() is None:
        H.kill()

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

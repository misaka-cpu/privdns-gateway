#!/usr/bin/env python3
"""iOS 描述文件生命周期的**恢复闭环**: 快照回滚 / Bot 备份恢复 / 旧格式备份 / 恢复失败回滚。

这里验的是一件很具体的事: 恢复之后, 记录说的那一版和盘上躺着的那一份**必须是同一个东西**。
分开恢复(只带记录不带产物、或者只覆盖了一半)会造出"记录说第 2 版、盘上是第 3 版"的状态,
而那之后每一次判定都建立在一个不成立的前提上 —— 界面上却什么都不会报错。

WLOC 的根证书让这件事更硬: 每一版用的 CA 只在**产物**里有正文, 元数据里只有指纹。
所以 previous 丢了就是真的没了, 谁也重建不出来。A→B→C 那组用例盯的就是这条。
"""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
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


def mkca(name):
    d = tmpguard.mkdtemp(prefix="iosrst-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    def __init__(self):
        self.root = tmpguard.mkdtemp(prefix="iosrst-")
        TMPS.append(self.root)
        for d in ("etc/privdns-gateway", "run", "var/lib/privdns-gateway"):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = self.root
        os.environ["PDG_LOCKFILE"] = self.root + "/run/privdns-gateway.lock"
        for m in ("iosstate", "iosprofile", "pdgtx", "cfgrestore"):
            sys.modules.pop(m, None)
        sys.path.insert(0, BOTDIR)
        import iosstate
        self.s = iosstate
        self.meta = self.root + "/etc/privdns-gateway/ios-profile.json"
        self.art = self.root + "/var/lib/privdns-gateway/ios-profile"

    def gen(self, host="dot.example.com", ca=b""):
        return self.s.generate(host, "203.0.113.10", (), ca, bool(ca), TMPL,
                               self.meta, self.art, True, False)

    def cur(self):
        return os.path.join(self.art, "current.mobileconfig")

    def prev(self):
        return os.path.join(self.art, "previous.mobileconfig")

    def trio(self):
        def rd(p):
            try:
                with open(p, "rb") as f:
                    return f.read()
            except OSError:
                return None
        return rd(self.meta), rd(self.cur()), rd(self.prev())

    def read_meta(self):
        with open(self.meta, encoding="utf-8") as f:
            return json.load(f)


sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402

CA_A = iosprofile.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())
CA_B = iosprofile.ca_der_from_pem(open(mkca("PDG CA B"), encoding="utf-8").read())
CA_C = iosprofile.ca_der_from_pem(open(mkca("PDG CA C"), encoding="utf-8").read())


def life(box):
    """造一条真实的生命周期: rev1(CA=A) → rev2(CA=B), 此时 current=rev2、previous=rev1。"""
    box.gen(ca=CA_A)
    box.gen(host="dot.v2.example", ca=CA_B)
    return box.trio()


print("══ 一、CLI 快照 → 回滚 ══")
b = Box()
snapshot = life(b)
# 快照按 cmd_snapshot 的候选路径打包(相对 /, 与生产同形)
snapdir = tmpguard.mkdtemp(prefix="iosrst-snap-")
TMPS.append(snapdir)
subprocess.run(["bash", "-c",
                "cd %s && tar czf %s/snap.tar.gz etc/privdns-gateway "
                "var/lib/privdns-gateway/ios-profile" % (b.root, snapdir)],
               check=True, capture_output=True)
b.gen(host="dot.v3.example", ca=CA_C)       # rev3
members = subprocess.run(["tar", "tzf", snapdir + "/snap.tar.gz"],
                         capture_output=True, text=True).stdout.split()
if any(m.endswith("ios-profile/current.mobileconfig") for m in members) \
        and any(m.endswith("ios-profile/previous.mobileconfig") for m in members) \
        and any(m.endswith("ios-profile.json") for m in members):
    ok("快照包里三件齐全(记录 + current + previous)")
else:
    bad("快照包缺件: %r" % [m for m in members if "ios" in m])
# 越界守卫必须放行这些成员(否则 cmd_rollback 会整包拒收)
guard = subprocess.run(
    ["bash", "-c", "printf '%s\\n' " + " ".join("'%s'" % m for m in members)
     + " | grep -Evq '^(etc|opt|usr/local/bin|var/lib/privdns-gateway/ios-profile)(/|\\$)'"],
    capture_output=True, text=True)
if guard.returncode != 0:
    ok("回滚的越界守卫放行快照里的每一个成员")
else:
    bad("越界守卫会把这份快照整包拒收")
subprocess.run(["bash", "-c", "tar xzf %s/snap.tar.gz -C %s" % (snapdir, b.root)],
               check=True, capture_output=True)
if b.trio() == snapshot:
    ok("回滚之后三件逐字节回到快照那一刻")
else:
    bad("回滚后内容对不上")
for which in ("current", "previous"):
    st, detail = b.s.artifact_health(b.read_meta(), which, b.art)
    if st == "healthy":
        ok("回滚后 %s 健康: %s" % (which, detail))
    else:
        bad("回滚后 %s 不健康: %s %s" % (which, st, detail))

print()
print("══ 二、Bot 备份 → 恢复(真的走 restore_from)══")
b = Box()
backup_trio = life(b)
os.makedirs(b.root + "/etc/sing-box", exist_ok=True)
os.makedirs(b.root + "/etc/mosdns", exist_ok=True)
json.dump({"outbounds": [], "route": {"rules": []}},
          open(b.root + "/etc/sing-box/config.json", "w"))
open(b.root + "/etc/mosdns/config.yaml", "w").write("log:\n  level: info\n")


def make_backup(root, with_cur=True, with_prev=True):
    """按生产 BACKUP_FILES 的形态打一个包(归档路径去掉前导 /)。"""
    buf = io.BytesIO()
    items = [("etc/sing-box/config.json", root + "/etc/sing-box/config.json"),
             ("etc/mosdns/config.yaml", root + "/etc/mosdns/config.yaml"),
             ("etc/privdns-gateway/ios-profile.json",
              root + "/etc/privdns-gateway/ios-profile.json")]
    if with_cur:
        items.append(("var/lib/privdns-gateway/ios-profile/current.mobileconfig",
                      root + "/var/lib/privdns-gateway/ios-profile/current.mobileconfig"))
    if with_prev:
        items.append(("var/lib/privdns-gateway/ios-profile/previous.mobileconfig",
                      root + "/var/lib/privdns-gateway/ios-profile/previous.mobileconfig"))
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for arc, src in items:
            tar.add(src, arcname=arc)
    return buf.getvalue()


blob_full = make_backup(b.root)
blob_legacy = make_backup(b.root, with_cur=False, with_prev=False)
b.gen(host="dot.v3.example", ca=CA_C)       # 现网走到 rev3


def run_restore(root, blob):
    """在沙箱里真的跑 Bot 的 restore_from。只桩掉服务重启这类外部动作。"""
    code = r'''
import io, json, os, sys, types
sys.path.insert(0, %(botdir)r)
os.environ["PDG_TX_FSROOT"] = %(root)r
os.environ["PDG_LOCKFILE"] = %(root)r + "/run/privdns-gateway.lock"
os.environ.setdefault("PDG_BOT_TOKEN", "x")
import importlib.util
spec = importlib.util.spec_from_file_location("botmod", %(bot)r)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
import pdgtx
# 事务真的落盘、真的回滚; 只把"重启服务/校验器要跑的外部程序"换成桩。
pdgtx._run = lambda cmd, timeout=60, **kw: (0, "")
pdgtx._svc_prop = lambda u, prop: ("active" if prop == "ActiveState" else "running")
pdgtx._svc_prop_ex = lambda u, prop: (("active" if prop == "ActiveState" else "running"), True)
pdgtx._svc_active = lambda u: True
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS,
                        json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
m._mihomo_derive = lambda staged: b"# stub\n"
m._core_svc = lambda: "mihomo"
blob = open(%(blobfile)r, "rb").read()
okv, msg = m.restore_from(blob)
print(json.dumps({"ok": bool(okv), "msg": msg}, ensure_ascii=False))
''' % {"botdir": BOTDIR, "bot": os.path.join(BOTDIR, "pdg-bot.py"),
       "root": root, "blobfile": root + "/backup.tar.gz"}
    with open(root + "/backup.tar.gz", "wb") as f:
        f.write(blob)
    p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=600)
    for line in reversed((p.stdout or "").splitlines()):
        if line.startswith("{"):
            return json.loads(line)
    return {"ok": False, "msg": (p.stderr or "")[-400:]}


res = run_restore(b.root, blob_full)
if res["ok"]:
    ok("完整备份恢复成功: %s" % res["msg"].splitlines()[0][:70])
else:
    bad("完整备份恢复失败: %s" % res["msg"][:300])
if b.trio() == backup_trio:
    ok("恢复之后三件与备份**逐字节**一致")
else:
    bad("恢复后内容对不上备份")
m = b.read_meta()
if m["current"]["revision"] == 2 and m["previous"]["revision"] == 1 \
        and m["current"]["inputs"]["wloc_ca_sha256"] == hashlib.sha256(CA_B).hexdigest() \
        and m["previous"]["inputs"]["wloc_ca_sha256"] == hashlib.sha256(CA_A).hexdigest():
    ok("CA A→B→C 之后恢复: 拿回的是 rev2(CA=B)+ rev1(CA=A), 指纹逐个对得上")
else:
    bad("恢复出来的版本/指纹不对: %r" % m.get("current", {}).get("revision"))
for which in ("current", "previous"):
    st, detail = b.s.artifact_health(m, which, b.art)
    if st == "healthy":
        ok("恢复后 %s 健康, 可以发送(%s)" % (which, detail))
    else:
        bad("恢复后 %s 不健康: %s %s" % (which, st, detail))
try:
    blob_c = b.s.verified_artifact(m, "current", b.art)
    blob_p = b.s.verified_artifact(m, "previous", b.art)
    import plistlib
    ca_c = [x for x in plistlib.loads(blob_c)["PayloadContent"]
            if x.get("PayloadType") == "com.apple.security.root"][0]["PayloadContent"]
    ca_p = [x for x in plistlib.loads(blob_p)["PayloadContent"]
            if x.get("PayloadType") == "com.apple.security.root"][0]["PayloadContent"]
    if ca_c == CA_B and ca_p == CA_A:
        ok("发送 current / previous 都放行, 里面分别是 CA B 与 CA A 的 DER 原文")
    else:
        bad("恢复出来的产物里 CA 不对")
except Exception as e:  # noqa: BLE001
    bad("恢复后发送被拒: %s" % e)

print()
print("══ 三、旧格式备份(只有记录, 没有产物)══")
b2 = Box()
life(b2)
os.makedirs(b2.root + "/etc/sing-box", exist_ok=True)
os.makedirs(b2.root + "/etc/mosdns", exist_ok=True)
json.dump({"outbounds": [], "route": {"rules": []}},
          open(b2.root + "/etc/sing-box/config.json", "w"))
open(b2.root + "/etc/mosdns/config.yaml", "w").write("log:\n  level: info\n")
legacy = make_backup(b2.root, with_cur=False, with_prev=False)
b2.gen(host="dot.v3.example", ca=CA_C)
res = run_restore(b2.root, legacy)
msg = res.get("msg", "")
if res["ok"] and "旧格式" in msg:
    ok("旧格式备份被认出来并写进结果: %s" % [l for l in msg.splitlines() if "旧格式" in l][0][:80])
else:
    bad("旧格式备份没被识别: ok=%s msg=%r" % (res["ok"], msg[:200]))
m2 = b2.read_meta()
if m2.get("previous") is None:
    ok("上一版被标记为不可用(记录里清掉), 不留一个点开就报错的入口")
else:
    bad("旧格式恢复后仍声称有上一版: %r" % m2.get("previous"))
st, detail = b2.s.artifact_health(m2, "current", b2.art)
if st != "healthy":
    ok("当前版本的产物没跟着回来 → 如实标成 %s, 没有谎报完整成功" % st)
else:
    bad("当前版本竟然被判成健康")
# 这台机器现在手里只有 CA_C, 而记录说的那一版用的是 B → 不许"修复"
try:
    b2.s.repair_current(CA_C, TMPL, b2.meta, b2.art, True)
    bad("CA 对不上却仍然修复了")
except Exception as e:  # noqa: BLE001
    if "根证书指纹" in str(e):
        ok("按记录复原被指纹那道门拒掉(手上的 CA 不是那一版用的): %s" % str(e)[:52])
    else:
        bad("拒是拒了, 但不是指纹那道门: %s" % str(e)[:90])

print()
print("══ 四、恢复失败 → 三件全部回到操作前 ══")
b3 = Box()
life(b3)
os.makedirs(b3.root + "/etc/sing-box", exist_ok=True)
os.makedirs(b3.root + "/etc/mosdns", exist_ok=True)
json.dump({"outbounds": [], "route": {"rules": []}},
          open(b3.root + "/etc/sing-box/config.json", "w"))
open(b3.root + "/etc/mosdns/config.yaml", "w").write("log:\n  level: info\n")
good = make_backup(b3.root)
b3.gen(host="dot.v3.example", ca=CA_C)
before = b3.trio()
# 注入: 第二个 iOS 目标落盘时失败 —— 第一个已经写下去了, 必须整组退回去
fault = r'''
import io, json, os, sys
sys.path.insert(0, %(botdir)r)
os.environ["PDG_TX_FSROOT"] = %(root)r
os.environ["PDG_LOCKFILE"] = %(root)r + "/run/privdns-gateway.lock"
os.environ.setdefault("PDG_BOT_TOKEN", "x")
import importlib.util
spec = importlib.util.spec_from_file_location("botmod", %(bot)r)
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except SystemExit:
    pass
import pdgtx
pdgtx._run = lambda cmd, timeout=60, **kw: (0, "")
pdgtx._svc_prop = lambda u, prop: ("active" if prop == "ActiveState" else "running")
pdgtx._svc_prop_ex = lambda u, prop: (("active" if prop == "ActiveState" else "running"), True)
pdgtx._svc_active = lambda u: True
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS,
                        json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
m._mihomo_derive = lambda staged: b"# stub\n"
m._core_svc = lambda: "mihomo"
_orig = pdgtx.atomic_write
_hits = []
def boom(path, data, *a, **kw):
    # 记录先写下去, 轮到第二份产物时炸 —— 半成功正是这条要挡住的东西
    if path.endswith("previous.mobileconfig"):
        _hits.append(path)
        raise OSError(28, "No space left on device")
    return _orig(path, data, *a, **kw)
pdgtx.atomic_write = boom
okv, msg = m.restore_from(open(%(blobfile)r, "rb").read())
print(json.dumps({"ok": bool(okv), "msg": msg, "hit": len(_hits)}, ensure_ascii=False))
''' % {"botdir": BOTDIR, "bot": os.path.join(BOTDIR, "pdg-bot.py"),
       "root": b3.root, "blobfile": b3.root + "/backup.tar.gz"}
with open(b3.root + "/backup.tar.gz", "wb") as f:
    f.write(good)
p = subprocess.run([sys.executable, "-c", fault], capture_output=True, text=True, timeout=600)
out = {}
for line in reversed((p.stdout or "").splitlines()):
    if line.startswith("{"):
        out = json.loads(line)
        break
if out and not out.get("ok") and out.get("hit"):
    ok("注入命中且恢复整体失败: %s" % str(out.get("msg"))[:70])
else:
    bad("故障注入没生效: %r %s" % (out, (p.stderr or "")[-200:]))
if b3.trio() == before:
    ok("失败之后记录 + current + previous **三件全部**逐字节回到操作前")
else:
    now = b3.trio()
    bad("留下了半成功状态: meta同=%s cur同=%s prev同=%s"
        % (now[0] == before[0], now[1] == before[1], now[2] == before[2]))

print()
print("══ 五、软链/硬链/权限 ══")
b4 = Box()
b4.gen(ca=CA_A)
real = b4.cur() + ".real"
shutil.move(b4.cur(), real)
os.symlink(real, b4.cur())
st, detail = b4.s.artifact_health(b4.read_meta(), "current", b4.art)
if st == "corrupt" and "符号链接" in detail:
    ok("current 是软链 → corrupt(发出去的字节不该取决于链接指向哪儿)")
else:
    bad("软链没被挡住: %s %s" % (st, detail))
os.unlink(b4.cur())
os.link(real, b4.cur())
st, detail = b4.s.artifact_health(b4.read_meta(), "current", b4.art)
if st == "corrupt" and "硬链接" in detail:
    ok("current 有硬链接 → corrupt")
else:
    bad("硬链没被挡住: %s %s" % (st, detail))
os.unlink(b4.cur())
shutil.move(real, b4.cur())
st, _ = b4.s.artifact_health(b4.read_meta(), "current", b4.art)
if st == "healthy":
    ok("换回普通文件 → 恢复健康")
else:
    bad("普通文件却仍不健康: %s" % st)

b5 = Box()
b5.gen(ca=CA_A)
os.chmod(b5.cur(), 0o666)
b5.gen(ca=CA_A)                                  # 再生成一次 = 走复原路径
mode = oct(os.stat(b5.cur()).st_mode & 0o777)
if mode == "0o644":
    ok("产物 mode 由生产代码写定(0644), 被改宽之后复原会写回去")
else:
    bad("mode 没被纠正: %s" % mode)
tgt = subprocess.run([sys.executable, "-c",
                      "import sys; sys.path.insert(0, %r); import pdgtx;"
                      "print(oct(pdgtx.resolve_target('ios_profile_current')[1]),"
                      "oct(pdgtx.resolve_target('ios_profile_state')[1]))" % BOTDIR],
                     capture_output=True, text=True, timeout=120).stdout.split()
if tgt == ["0o644", "0o600"]:
    ok("pdgtx 目标固定 mode: 产物 0644 / 记录 0600")
else:
    bad("pdgtx 目标 mode 不对: %r" % tgt)

print()
print("══ 六、产物里不许有凭据 ══")
b6 = Box()
b6.gen(ca=CA_A)
b6.gen(host="dot.v2.example", ca=CA_B)
blob = open(b6.cur(), "rb").read() + open(b6.prev(), "rb").read() + open(b6.meta, "rb").read()
sentinels = [b"PRIVATE KEY", b"BEGIN RSA PRIVATE", b"vmess://", b"vless://", b"trojan://",
             b"hysteria2://", b"ss://", b"bot_token", b"PDG_BOT_TOKEN"]
hit = [x for x in sentinels if x in blob]
if not hit:
    ok("current / previous / 记录里都没有私钥、token 或代理链接哨兵")
else:
    bad("出现凭据哨兵: %r" % hit)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

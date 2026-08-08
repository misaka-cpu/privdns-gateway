#!/usr/bin/env python3
"""备份恢复时, iOS 描述文件的**三件套要当成一组来验**, 不是三个各自解析一下就完事。

恢复是这套生命周期里唯一一个"内容不是我们自己算出来的"入口: 记录、current、previous 三份
都来自包外。只验"记录能被 json 解析"等于把后面所有判定建立在一句一厢情愿上 —— 之后每一次
artifact_health、每一次发送, 前提都是"记录说的那一版就是盘上那一份", 而这个前提恰恰是这里
应该证明、却没有证明的东西。

这里要挡住两类东西, 它们的性质不一样, 别混着说:
  · **不自洽的一组**: 记录说第 2 版而盘上是第 3 版、current/previous 互换、记录里没有
    previous 却带着一份 previous 文件。它们不需要有人使坏就会出现(半程失败、旧快照回滚),
    危害是从此每一次判定都在一个不成立的前提上跑, 界面却一切正常。
  · **不是这个项目会生成的东西**: mobileconfig 能装的远不止 DNS —— VPN、代理、WebClip、
    MDM 注册都在里面。恢复一份"DNS 网关备份"之后, 「📱 iOS 描述文件」页面就成了一个可信
    入口, 用户点「发送」拿到什么就装什么。所以只放行本项目自己会写出来的那几种 payload,
    根证书那一格必须是真的 X.509 公钥证书。

说清楚这里**不**保证什么: 恢复的是用户自己给的配置, 我们不去审"这个 DoT 域名该不该信"
—— 那和"恢复备份"这件事本身矛盾。挡的是"这一组自相矛盾"和"这里面有描述文件不该有的东西"。
"""
import base64
import copy
import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
BOT = os.path.join(BOTDIR, "pdg-bot.py")
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
    d = tmpguard.mkdtemp(prefix="iostrust-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d


def der_private_key(kind):
    """一把**真的**私钥, 转成 DER。装进 PayloadContent 之后是 base64, 文件里连
    "PRIVATE KEY" 这几个字都不会出现 —— 靠扫字面量的那道门看不见它。"""
    d = tmpguard.mkdtemp(prefix="iostrust-key-")
    TMPS.append(d)
    if kind == "ec":
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey",
                        "-noout", "-out", d + "/k.pem"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "ec", "-in", d + "/k.pem", "-outform", "DER",
                        "-out", d + "/k.der"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif kind == "rsa":
        subprocess.run(["openssl", "genrsa", "-out", d + "/k.pem", "2048"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "rsa", "-in", d + "/k.pem", "-outform", "DER",
                        "-traditional", "-out", d + "/k.der"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:                                        # pkcs8
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-outform", "DER",
                        "-pkeyopt", "rsa_keygen_bits:2048", "-out", d + "/k.der"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(d + "/k.der", "rb") as f:
        return f.read()


class Box:
    """一个沙箱 root: 生命周期、事务、锁全在里面, 碰不到真机。"""

    def __init__(self):
        self.root = tmpguard.mkdtemp(prefix="iostrust-")
        TMPS.append(self.root)
        for d in ("etc/privdns-gateway", "etc/sing-box", "etc/mosdns", "run",
                  "var/lib/privdns-gateway"):
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
        with open(self.root + "/etc/sing-box/config.json", "w") as f:
            json.dump({"outbounds": [], "route": {"rules": []}}, f)
        with open(self.root + "/etc/mosdns/config.yaml", "w") as f:
            f.write("log:\n  level: info\n")

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

    def stats(self):
        out = []
        for p in (self.meta, self.cur(), self.prev()):
            try:
                st = os.stat(p)
                out.append((oct(st.st_mode & 0o7777), st.st_uid, st.st_gid))
            except OSError:
                out.append(None)
        return out

    def read_meta(self):
        with open(self.meta, encoding="utf-8") as f:
            return json.load(f)


sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402
import iosstate as _S0  # noqa: E402

CA_A_DIR, CA_B_DIR, CA_C_DIR = mkca("PDG CA A"), mkca("PDG CA B"), mkca("PDG CA C")
CA_A = iosprofile.ca_der_from_pem(open(CA_A_DIR + "/ca.crt", encoding="utf-8").read())
CA_B = iosprofile.ca_der_from_pem(open(CA_B_DIR + "/ca.crt", encoding="utf-8").read())
CA_C = iosprofile.ca_der_from_pem(open(CA_C_DIR + "/ca.crt", encoding="utf-8").read())

ARC_META = "etc/privdns-gateway/ios-profile.json"
ARC_CUR = "var/lib/privdns-gateway/ios-profile/current.mobileconfig"
ARC_PREV = "var/lib/privdns-gateway/ios-profile/previous.mobileconfig"


def pack(members):
    """members: {归档路径: 字节 or None}。None = 不放进包里。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for arc, data in members.items():
            if data is None:
                continue
            info = tarfile.TarInfo(arc)
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def source_backup():
    """一份**真的**备份: rev1(CA=A) → rev2(CA=B), 三件齐全。"""
    src = Box()
    src.gen(ca=CA_A)
    src.gen(host="dot.v2.example", ca=CA_B)
    meta, cur, prev = src.trio()
    with open(src.root + "/etc/sing-box/config.json", "rb") as f:
        sb = f.read()
    with open(src.root + "/etc/mosdns/config.yaml", "rb") as f:
        mos = f.read()
    return src, {"etc/sing-box/config.json": sb, "etc/mosdns/config.yaml": mos,
                 ARC_META: meta, ARC_CUR: cur, ARC_PREV: prev}


RUNNER = r'''
import json, os, sys
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
%(inject)s
okv, msg = m.restore_from(open(%(blobfile)r, "rb").read())
print("RESULT " + json.dumps({"ok": bool(okv), "msg": msg}, ensure_ascii=False))
'''


def run_restore(box, blob, inject="", env=None):
    with open(box.root + "/backup.tar.gz", "wb") as f:
        f.write(blob)
    code = RUNNER % {"botdir": BOTDIR, "bot": BOT, "root": box.root,
                     "blobfile": box.root + "/backup.tar.gz", "inject": inject}
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run([sys.executable, "-c", code], capture_output=True,
                       text=True, timeout=600, env=e)
    for line in reversed((p.stdout or "").splitlines()):
        if line.startswith("RESULT "):
            return json.loads(line[7:])
    return {"ok": False, "msg": "[runner crashed] " + (p.stderr or "")[-500:]}


def victim():
    """一台"现网"机器: 自己的身份, 走到 rev3(CA=C)。恢复要么整组换掉它, 要么一个字节不动。"""
    v = Box()
    v.gen(ca=CA_A)
    v.gen(host="dot.v2.example", ca=CA_B)
    v.gen(host="dot.v3.example", ca=CA_C)
    return v


def refuse_case(title, members, expect_words, expect_note=None, env=None):
    """恢复必须被拒, 现网三件套一个字节都不许动, 而且要点名是哪一道门。"""
    v = victim()
    before, before_st = v.trio(), v.stats()
    res = run_restore(v, pack(members), env=env)
    if res["ok"]:
        bad("%s: 竟然恢复成功了 —— %s" % (title, res["msg"].splitlines()[0][:90]))
    else:
        msg = res["msg"]
        hit = [w for w in expect_words if w in msg]
        if hit:
            ok("%s: 被拒, 命中「%s」(%s)" % (title, hit[0], msg.splitlines()[-1][:80]))
        else:
            bad("%s: 拒是拒了, 但不是这道门: %s" % (title, msg[:200]))
    if v.trio() == before and v.stats() == before_st:
        ok("%s: 现网记录/current/previous 逐字节未动, mode/uid/gid 不变" % title)
    else:
        now, now_st = v.trio(), v.stats()
        bad("%s: 现网被改了 meta同=%s cur同=%s prev同=%s 属性同=%s"
            % (title, now[0] == before[0], now[1] == before[1], now[2] == before[2],
               now_st == before_st))


def resha(meta_raw, which, data):
    """改完产物, 把记录里的 sha256 配平 —— 攻击者当然会这么干, 所以不能只靠 sha 这一道。"""
    meta = json.loads(meta_raw.decode("utf-8"))
    meta[which]["sha256"] = hashlib.sha256(data).hexdigest()
    return json.dumps(meta, ensure_ascii=False, indent=2,
                      sort_keys=True).encode("utf-8") + b"\n"


def rewrite_meta(meta_raw, fn):
    """改记录, 并把 digest 按新的 inputs 重算 —— 一个会做功课的攻击者当然会重算,
    所以后面的门不能靠"他忘了改 digest"来生效。"""
    meta = json.loads(meta_raw.decode("utf-8"))
    fn(meta)
    for w in ("current", "previous"):
        if meta.get(w) and meta[w].get("inputs"):
            meta[w]["digest"] = _S0.digest_of(meta[w]["inputs"])
    return json.dumps(meta, ensure_ascii=False, indent=2,
                      sort_keys=True).encode("utf-8") + b"\n"


print("══ 一、基线: 干净的备份必须照常恢复 ══")
src, good = source_backup()
good_meta = json.loads(good[ARC_META].decode("utf-8"))
v = victim()
res = run_restore(v, pack(good))
if res["ok"]:
    ok("完整备份恢复成功: %s" % res["msg"].splitlines()[0][:70])
else:
    bad("完整备份被误拒: %s" % res["msg"][:300])
if v.trio() == (good[ARC_META], good[ARC_CUR], good[ARC_PREV]):
    ok("恢复之后三件与备份逐字节一致")
else:
    bad("恢复后内容对不上备份")
for which in ("current", "previous"):
    st, detail = v.s.artifact_health(v.read_meta(), which, v.art)
    if st == "healthy":
        ok("恢复后 %s 健康(%s)" % (which, detail))
    else:
        bad("恢复后 %s 不健康: %s %s" % (which, st, detail))

print()
print("══ 二、旧格式备份(只带记录)仍按既有口径处理 ══")
v = victim()
legacy = dict(good)
legacy[ARC_CUR] = legacy[ARC_PREV] = None
res = run_restore(v, pack(legacy))
if res["ok"] and "旧格式" in res["msg"]:
    ok("旧格式备份被认出来: %s"
       % [l for l in res["msg"].splitlines() if "旧格式" in l][0][:80])
else:
    bad("旧格式备份没被按老口径处理: ok=%s msg=%r" % (res["ok"], res["msg"][:200]))
mv = v.read_meta()
if mv.get("previous") is None:
    ok("上一版标记为不可用(它的根证书正文只在产物里, 重建不出来)")
else:
    bad("旧格式恢复后仍声称有上一版")
st, _ = v.s.artifact_health(mv, "current", v.art)
if st != "healthy":
    ok("当前版本产物没跟回来 → 如实标成 %s, 没谎报完整成功" % st)
else:
    bad("当前版本竟被判成健康")
if mv.get("instance_id") == good_meta["instance_id"]:
    ok("身份照旧从备份恢复(没有顺手造第二个 instance_id)")
else:
    bad("身份没恢复: %r" % mv.get("instance_id"))

print()
print("══ 三、根证书那一格必须是真的公钥证书 ══")
ids = _S0.derive_ids(good_meta["instance_id"])
for kind in ("ec", "rsa", "pkcs8"):
    key_der = der_private_key(kind)
    doc = plistlib.loads(good[ARC_CUR])
    for x in doc["PayloadContent"]:
        if x.get("PayloadType") == "com.apple.security.root":
            x["PayloadContent"] = key_der
    forged = plistlib.dumps(doc)
    if b"PRIVATE KEY" in forged:
        bad("%s: 构造的样本里出现了 PRIVATE KEY 字面量, 这条用例就没意义了" % kind)
    def _fix(m):
        m["current"]["inputs"]["wloc_ca_sha256"] = hashlib.sha256(key_der).hexdigest()
        m["current"]["sha256"] = hashlib.sha256(forged).hexdigest()
    raw2 = rewrite_meta(good[ARC_META], _fix)     # digest 也一并重算, 直逼根证书那道门
    refuse_case("DER %s 私钥冒充根证书" % kind,
                dict(good, **{ARC_META: raw2, ARC_CUR: forged}),
                ["根证书", "私钥", "证书"])

print()
print("══ 四、只放行本项目会生成的 payload ══")
doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"].append({
    "PayloadType": "com.apple.webClip.managed", "PayloadVersion": 1,
    "PayloadIdentifier": "com.evil.clip",
    "PayloadUUID": "11111111-2222-3333-4444-555555555555",
    "URL": "https://evil.example/", "Label": "Bank"})
extra = plistlib.dumps(doc)
refuse_case("备份里多塞了一个 WebClip payload",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", extra),
                          ARC_CUR: extra}),
            ["payload", "Payload"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"].append({
    "PayloadType": "com.apple.mdm", "PayloadVersion": 1,
    "PayloadIdentifier": "com.evil.mdm",
    "PayloadUUID": "66666666-7777-8888-9999-aaaaaaaaaaaa",
    "ServerURL": "https://evil.example/mdm", "Topic": "com.apple.mgmt.evil",
    "AccessRights": 8191})
mdm = plistlib.dumps(doc)
refuse_case("备份里多塞了一个 MDM 注册 payload",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", mdm),
                          ARC_CUR: mdm}),
            ["payload", "Payload"])

print()
print("══ 五、一组必须自洽 ══")
refuse_case("current / previous 互换",
            dict(good, **{ARC_CUR: good[ARC_PREV], ARC_PREV: good[ARC_CUR]}),
            ["串位", "互换", "sha256", "对不上"])

tampered = bytearray(good[ARC_CUR])
i = tampered.index(b"dot.v2.example")
tampered[i:i + 3] = b"XXX"
refuse_case("current 被改了一个字节(记录里的 sha 不动)",
            dict(good, **{ARC_CUR: bytes(tampered)}),
            ["sha256", "对不上", "内容"])

other, other_pack = source_backup()          # 另一台机器, 另一个 instance_id
mixed = other_pack[ARC_CUR]
refuse_case("拿另一台机器的产物配本备份的记录",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", mixed),
                          ARC_CUR: mixed}),
            ["身份", "不是这台", "instance"])

doc = plistlib.loads(good[ARC_CUR])
for x in doc["PayloadContent"]:
    if x.get("PayloadType") == "com.apple.security.root":
        x["PayloadContent"] = CA_C          # 记录说这一版用 B, 文件里放 C
swapca = plistlib.dumps(doc)
refuse_case("产物里的根证书换成了另一张(指纹与记录不符)",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", swapca),
                          ARC_CUR: swapca}),
            ["根证书", "指纹"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"][0]["DNSSettings"]["ServerName"] = "evil.example"
elsewhere = plistlib.dumps(doc)
refuse_case("产物把 DoT 指到了别处(记录里的 dot_host 没变)",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", elsewhere),
                          ARC_CUR: elsewhere}),
            ["ServerName", "dot_host", "语义"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"][0]["OnDemandRules"].insert(0, {"Action": "Connect"})
alwayson = plistlib.dumps(doc)
refuse_case("产物的按需规则被改成无条件启用(记录里的骨架没变)",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", alwayson),
                          ARC_CUR: alwayson}),
            ["按需规则", "语义"])

noprev = json.loads(good[ARC_META].decode("utf-8"))
noprev["previous"] = None
refuse_case("记录里没有上一版, 包里却带着一份 previous",
            dict(good, **{ARC_META: json.dumps(noprev, ensure_ascii=False, indent=2,
                                               sort_keys=True).encode("utf-8") + b"\n"}),
            ["上一版", "previous", "多出"])

refuse_case("记录里有上一版, 包里只带了 current",
            dict(good, **{ARC_PREV: None}),
            ["上一版", "previous", "缺"])

badmeta = json.loads(good[ARC_META].decode("utf-8"))
badmeta["current"]["revision"] = "2"        # 字符串, 不是整数
refuse_case("记录里 revision 类型不对",
            dict(good, **{ARC_META: json.dumps(badmeta, ensure_ascii=False, indent=2,
                                               sort_keys=True).encode("utf-8") + b"\n"}),
            ["revision", "记录", "格式"])

print()
print("══ 五之二、伪造得「看起来自洽」的一组也不许放行 ══")
# 这几条的共同点: 攻击者同时改元数据与产物, 再把 sha256 配平。只比"两边一致"是拦不住的
# —— 一致的可以是**两边都错**。所以判据必须落在"这是不是本项目会写出来的那份东西"上。

# 1) 记录文件在, 但 JSON 坏了。以前这里返回"没有可用记录"→ 跳过 iOS 这一组、继续恢复其它
#    配置: 于是一份记录损坏的备份能把网关配置换掉, 而生命周期留在原地, 两边从此对不上。
#    只有"归档里根本没有这个文件"才解释得成"这份备份不含这一组"。
refuse_case("记录文件在但 JSON 坏了",
            dict(good, **{ARC_META: b'{"schema": 1, "instance_id": '}),
            ["解析", "损坏", "记录"])
refuse_case("记录文件在但不是 UTF-8",
            dict(good, **{ARC_META: b"\xff\xfe\x00{"}),
            ["解析", "损坏", "记录", "UTF-8"])
bad_schema = json.loads(good[ARC_META].decode("utf-8"))
bad_schema["schema"] = 99
refuse_case("记录的 schema 不认识",
            dict(good, **{ARC_META: json.dumps(bad_schema, ensure_ascii=False, indent=2,
                                               sort_keys=True).encode("utf-8") + b"\n"}),
            ["schema", "格式版本"])

# 2) digest 只被检查了"以 sha256: 开头"。它是判"配置有没有变"的唯一依据, 伪造它等于让
#    整套三档判定失效 —— 必须按 inputs 重新算一遍核对。
for label, forged in (("乱写一串", "sha256:" + "0" * 64),
                      ("长度不对", "sha256:" + "ab" * 20),
                      ("大写十六进制", "sha256:" + "A" * 64)):
    bd = json.loads(good[ARC_META].decode("utf-8"))
    bd["current"]["digest"] = forged
    refuse_case("digest 伪造(%s)" % label,
                dict(good, **{ARC_META: json.dumps(bd, ensure_ascii=False, indent=2,
                                                   sort_keys=True).encode("utf-8") + b"\n"}),
                ["digest"])

# 3) 顶层多一个本项目不会写的键。PayloadRemovalDisallowed=true 的后果很具体: 描述文件装到
#    手机上之后**用户自己删不掉**。
doc = plistlib.loads(good[ARC_CUR])
doc["PayloadRemovalDisallowed"] = True
locked = plistlib.dumps(doc)
refuse_case("顶层多了 PayloadRemovalDisallowed(装上就删不掉)",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", locked),
                          ARC_CUR: locked}),
            ["顶层", "字段", "PayloadRemovalDisallowed"])

doc = plistlib.loads(good[ARC_CUR])
del doc["PayloadDisplayName"]
missing = plistlib.dumps(doc)
refuse_case("顶层少了一个本项目一定会写的键",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", missing),
                          ARC_CUR: missing}),
            ["顶层", "字段", "PayloadDisplayName"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"][0]["PayloadOrganization"] = "Evil Inc"
dnsextra = plistlib.dumps(doc)
refuse_case("DNS payload 多了一个未知字段",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", dnsextra),
                          ARC_CUR: dnsextra}),
            ["DNS", "字段", "PayloadOrganization"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"][0]["DNSSettings"]["SupplementalMatchDomains"] = ["bank.example"]
dnssetextra = plistlib.dumps(doc)
refuse_case("DNSSettings 多了一个未知字段",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", dnssetextra),
                          ARC_CUR: dnssetextra}),
            ["DNSSettings", "字段", "SupplementalMatchDomains"])

doc = plistlib.loads(good[ARC_CUR])
doc["PayloadContent"][0]["OnDemandRules"][0]["DNSDomainMatch"] = ["x.example"]
ruleextra = plistlib.dumps(doc)
refuse_case("按需规则里多了一个未知字段",
            dict(good, **{ARC_META: resha(good[ARC_META], "current", ruleextra),
                          ARC_CUR: ruleextra}),
            ["按需规则", "字段", "DNSDomainMatch"])

# 4) 根证书 payload 的固定 identifier 被改掉。identifier + UUID 是 iOS 认这一格的依据,
#    改了它, 这一格在手机上就不再是"我们那一格"。
for key, val, words in (("PayloadIdentifier", "com.evil.ca", ["identifier", "Identifier", "根证书"]),
                        ("PayloadCertificateFileName", "evil.crt", ["证书文件名", "根证书"]),
                        ("PayloadVersion", 2, ["PayloadVersion", "根证书"]),
                        ("PayloadType", "com.apple.security.pkcs1", ["payload", "根证书"])):
    doc = plistlib.loads(good[ARC_CUR])
    for x in doc["PayloadContent"]:
        if x.get("PayloadType") == "com.apple.security.root":
            x[key] = val
    forged = plistlib.dumps(doc)
    refuse_case("根证书 payload 的 %s 被改成 %r" % (key, val),
                dict(good, **{ARC_META: resha(good[ARC_META], "current", forged),
                              ARC_CUR: forged}),
                words)

# 5) 没有 openssl / openssl 跑不起来: 不能把结构判据冒充完整 X.509 校验。安装本来就依赖它。
refuse_case("openssl 不可用时不许把结构判据当成强校验",
            dict(good),
            ["强校验", "openssl", "OpenSSL"],
            env={"PATH": "/nonexistent-for-openssl-probe"})

print()
print("══ 五之四、记录字段必须是精确的那一套 ══")
# 记录的字段集合以前只查 inputs 那一层, 记录本身多一个少一个都放行。少一个的代价很具体:
# generated_at 没了照样能"恢复成功", 然后状态页一读就 KeyError —— 用户看到的是一个打不开的
# 页面, 而机器上那份记录是恢复操作自己写进去的。


def rec_case(title, mutate, words):
    def _fix(m):
        mutate(m["current"])
    refuse_case(title, dict(good, **{ARC_META: rewrite_meta(good[ARC_META], _fix)}), words)


def _add_unknown(r):
    r["retired_at"] = "2026-01-01T00:00:00Z"


def _drop_generated(r):
    r.pop("generated_at", None)


def _drop_sent(r):
    r.pop("sent_at", None)


def _null_generated(r):
    r["generated_at"] = None


def _bad_type_generated(r):
    r["generated_at"] = 1735689600


def _empty_generated(r):
    r["generated_at"] = ""


def _bad_type_sent(r):
    r["sent_at"] = 0


rec_case("记录多了一个未知字段", _add_unknown, ["retired_at", "字段", "current"])
rec_case("记录少了 generated_at", _drop_generated, ["generated_at", "字段", "current"])
rec_case("记录少了 sent_at", _drop_sent, ["sent_at", "字段", "current"])
rec_case("generated_at 是 null", _null_generated, ["generated_at"])
rec_case("generated_at 是整数", _bad_type_generated, ["generated_at"])
rec_case("generated_at 是空串", _empty_generated, ["generated_at"])
rec_case("sent_at 是整数", _bad_type_sent, ["sent_at"])

# 缺 generated_at 必须在**恢复之前**被挡住, 而不是恢复完了让状态页去崩。
_v = victim()
_m = json.loads(good[ARC_META].decode("utf-8"))
del _m["current"]["generated_at"]
try:
    _v.s.status_lines(_m, None, _v.art)
    bad("缺 generated_at 的记录竟然能画出状态页 —— 那这条用例的前提不成立")
except KeyError as e:
    ok("缺 generated_at 的记录一进状态页就 KeyError(%s) —— 所以必须在恢复前拦下" % e)
except Exception as e:  # noqa: BLE001
    ok("缺 generated_at 的记录在状态页上直接出错(%s)" % type(e).__name__)

print()
print("══ 五之五、schema 1 的按需规则语义是固定的 ══")
# _RULE_KEYSETS 只管键名, ondemand_core 又取自备份自己 —— 于是"同时改产物和记录再配平摘要"
# 就能过。多一条 {"Action":"Connect"} 的后果是: 探测还没跑, DoT 就被无条件启用。
IDS = _S0.derive_ids(good_meta["instance_id"])


def rules_case(title, mutate, words):
    doc = plistlib.loads(good[ARC_CUR])
    dns = doc["PayloadContent"][0]
    mutate(dns["OnDemandRules"])
    data = plistlib.dumps(doc)

    def _fix(m):
        core = []
        for r in dns["OnDemandRules"]:
            r = dict(r)
            if "URLStringProbe" in r:
                r["URLStringProbe"] = "<probe>"
            core.append(r)
        m["current"]["inputs"]["ondemand_core"] = core     # 记录与产物完全配平
        m["current"]["sha256"] = hashlib.sha256(data).hexdigest()
    refuse_case(title, dict(good, **{ARC_META: rewrite_meta(good[ARC_META], _fix),
                                     ARC_CUR: data}), words)


rules_case("多插一条无条件 Connect(探测还没跑就启用 DoT)",
           lambda rs: rs.insert(0, {"Action": "Connect"}),
           ["按需规则", "schema", "骨架"])
rules_case("末尾多一条无条件 Connect",
           lambda rs: rs.append({"Action": "Connect"}),
           ["按需规则", "schema", "骨架"])


def _flip_action(rs):
    rs[1]["Action"] = "Connect"                     # WiFi 兜底从 Disconnect 变成 Connect


def _flip_iface(rs):
    rs[0]["InterfaceTypeMatch"] = "Cellular"        # 探测规则的网络类型被换掉


def _reorder(rs):
    rs[0], rs[1] = rs[1], rs[0]                     # 探测规则被排到兜底之后 → 永远轮不到


def _drop_probe(rs):
    rs[0].pop("URLStringProbe", None)
    rs[0]["Action"] = "Connect"                     # 去掉探测 = 无条件启用


rules_case("WiFi 兜底的 Action 被改成 Connect", _flip_action, ["按需规则", "schema", "骨架"])
rules_case("探测规则的 InterfaceTypeMatch 被换成 Cellular", _flip_iface,
           ["按需规则", "schema", "骨架"])
rules_case("schema 1 的固定顺序被调换", _reorder, ["按需规则", "schema", "骨架", "顺序"])
rules_case("探测 URL 被摘掉(等于无条件启用)", _drop_probe, ["按需规则", "schema", "骨架"])


# 记录里的 ondemand_core 本身就不符合 schema 1(产物老实, 记录说谎)
def _lie_core(m):
    m["current"]["inputs"]["ondemand_core"] = [{"Action": "Connect"}]


refuse_case("记录里的 ondemand_core 本身不符合 schema 1",
            dict(good, **{ARC_META: rewrite_meta(good[ARC_META], _lie_core)}),
            ["按需规则", "schema", "骨架"])

# SSID 名单为空时不许出现 SSIDMatch 规则(即便记录也配平)
def _sneak_ssid(rs):
    rs.insert(0, {"InterfaceTypeMatch": "WiFi", "SSIDMatch": ["Evil"],
                  "Action": "Disconnect"})


rules_case("SSID 名单为空却塞了一条 SSIDMatch 规则", _sneak_ssid,
           ["SSID", "按需规则", "schema"])

print()
print("══ 五之三、白名单必须跟得上渲染器(否则正常备份会被自己人挡住)══")
# 字段白名单是钉死在当前 schema 上的一张表。它和 iosprofile.render 是两处定义, 会漂移。
# 这条守卫拿**现渲染**的产物过一遍联合校验: 模板或渲染器改了字段而白名单没跟上, 这里先红,
# 而不是等某个用户恢复备份时才发现"自己生成的文件自己不认"。
for label, ca, ssids in (("带根证书", CA_A, []),
                         ("不带根证书", b"", []),
                         ("带 SSID 强制直连名单", b"", ["Home", "Office"]),
                         ("根证书 + SSID 都有", CA_B, ["Cafe"])):
    probe = Box()
    probe.s.generate("dot.probe.example", "203.0.113.10", ssids, ca, bool(ca), TMPL,
                     probe.meta, probe.art, True, False)
    p_meta, p_cur, _p_prev = probe.trio()
    try:
        probe.s.validate_restore_set(p_meta, p_cur, None)
        ok("现渲染的产物(%s)正好合规 —— 白名单与渲染器没有漂移" % label)
    except Exception as e:  # noqa: BLE001
        bad("自己生成的产物(%s)过不了自己的校验: %s" % (label, str(e)[:160]))

print()
print("══ 六、写到一半失败 → 三件套连权限一起回到操作前 ══")
v = victim()
before, before_st = v.trio(), v.stats()
inject = r'''
_orig = pdgtx.atomic_write
_hits = []
def boom(path, data, *a, **kw):
    if path.endswith("previous.mobileconfig"):
        _hits.append(path)
        raise OSError(28, "No space left on device")
    return _orig(path, data, *a, **kw)
pdgtx.atomic_write = boom
'''
res = run_restore(v, pack(good), inject)
if not res["ok"]:
    ok("第二份产物落盘失败 → 整笔恢复失败: %s" % res["msg"].splitlines()[0][:70])
else:
    bad("注入没生效或半成功被当成成功: %s" % res["msg"][:200])
if v.trio() == before:
    ok("记录 + current + previous 三件逐字节回到操作前")
else:
    now = v.trio()
    bad("留下半成功: meta同=%s cur同=%s prev同=%s"
        % (now[0] == before[0], now[1] == before[1], now[2] == before[2]))
if v.stats() == before_st:
    ok("三件的 mode/uid/gid 也回到操作前: %r" % (v.stats(),))
else:
    bad("属性没还原: %r → %r" % (before_st, v.stats()))

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

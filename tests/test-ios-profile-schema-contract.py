#!/usr/bin/env python3
"""schema 1 的**可信契约**: 记录里的输入必须是本项目生成器可能产出的规范形式。

前几轮把"字段集合"钉住了 —— 多一个少一个都拒。但字段**值**还没钉: 只要攻击者把
`inputs`、`digest`、产物字节、产物 `sha256` 一起配平, 下面这些都能过:

  · 两条 URLStringProbe 改成 https://attacker.invalid/beacon, 同时把 inputs.probe_url
    改成一样的值 —— 判据是"产物里的探测地址等于记录声称的那个", 两边一起改就自洽了。
    后果: 手机每次判断要不要启用 DoT 都会先去打攻击者的服务器;
  · ssids 改成 ["B", 7, "A", "A", ""] —— 规范化后本该是 ["7","A","B"], 但没人验;
  · server_addresses 改成 [123] —— 整数照样进 plist, 也照样"两边相等";
  · 顶层 / DNS payload 的 PayloadDisplayName 改成 "Trusted Corporate MDM" /
    "Install Security Update" —— 那是用户在 iPhone 上**唯一**看得见的东西。

元数据同样: instance_id 只要非空就行(uuid5 什么字符串都收), created_at 可以是 null,
generated_at 只要是字符串就行 —— "2026-02-30T99:99:99Z" 也算。

所以这一轮把判据从"两边自洽"改成"**符合本项目的规范形式**": 输入必须等于
iosprofile 的规范化函数作用在它自己身上的结果, probe_url 必须由第一个服务器地址推导,
固定显示名必须等于常量, instance_id 必须是规范小写的 UUID4, 时间必须是真实的 UTC 时刻。
"""
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
import uuid as _uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
BOT = os.path.join(BOTDIR, "pdg-bot.py")
PDG = os.path.join(BOTDIR, "pdg.sh")
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
SUB = "var/lib/privdns-gateway/ios-profile"
ARC_META = "etc/privdns-gateway/ios-profile.json"
ARC_CUR = SUB + "/current.mobileconfig"
ARC_PREV = SUB + "/previous.mobileconfig"

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def _tmp(prefix):
    d = tempfile.mkdtemp(prefix=prefix)
    TMPS.append(d)
    return d


def mkca(name):
    d = _tmp("iossc-ca-")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    """一个沙箱 root。生命周期、事务、锁全在里面。"""

    def __init__(self):
        self.root = _tmp("iossc-")
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
        self.meta = os.path.join(self.root, ARC_META)
        self.art = os.path.join(self.root, SUB)
        with open(os.path.join(self.root, "etc/sing-box/config.json"), "w") as f:
            json.dump({"outbounds": [], "route": {"rules": []}}, f)
        with open(os.path.join(self.root, "etc/mosdns/config.yaml"), "w") as f:
            f.write("log:\n  level: info\n")

    def gen(self, host="dot.example.com", addrs="203.0.113.10", ssids=(), ca=b""):
        return self.s.generate(host, addrs, ssids, ca, bool(ca), TMPL,
                               self.meta, self.art, True, False)

    def p(self, rel):
        return os.path.join(self.root, rel)

    def rd(self, rel):
        try:
            with open(self.p(rel), "rb") as f:
                return f.read()
        except OSError:
            return None

    def group(self):
        out = {ARC_META: self.rd(ARC_META)}
        for base, _d, files in os.walk(self.p(SUB)):
            for f in files:
                rel = SUB + "/" + os.path.relpath(os.path.join(base, f), self.p(SUB))
                out[rel] = self.rd(rel)
        return {k: v for k, v in out.items() if v is not None}

    def stats(self):
        out = {}
        for rel in self.group():
            st = os.stat(self.p(rel))
            out[rel] = (st.st_mode & 0o7777, st.st_uid, st.st_gid)
        return out


sys.path.insert(0, BOTDIR)
import iosprofile as IP  # noqa: E402

CA_A = IP.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())

# ── 造样本: 全部摘要一起重算, 于是失败不可能来自"忘了配平" ────────────────────
BASE = Box()
BASE.gen(ca=CA_A)
S = BASE.s
BASE_META = json.loads(BASE.rd(ARC_META).decode("utf-8"))
BASE_CUR = BASE.rd(ARC_CUR)

# 自证前提: plist 解析→重新 dumps 是稳定的, 于是"改一处再 dumps"造出来的差异只来自那一处
if plistlib.dumps(plistlib.loads(BASE_CUR)) == BASE_CUR:
    ok("前提: 产物 plist 解析→重新序列化逐字节不变(伪造样本的差异只来自被改的那一处)")
else:
    bad("plist 往返不稳定, 本文件造出来的样本无法归因")


def forge(mutate_meta=None, mutate_doc=None, ids=None, base_doc=None, base_meta=None):
    """返回 (记录字节, 产物字节)。inputs / digest / 产物 / sha256 **全部**重算。"""
    meta = json.loads(json.dumps(base_meta or BASE_META))
    doc = plistlib.loads(base_doc or BASE_CUR)
    if mutate_meta:
        mutate_meta(meta)
    if mutate_doc:
        mutate_doc(doc)
    data = plistlib.dumps(doc)
    if meta.get("current"):
        meta["current"]["sha256"] = hashlib.sha256(data).hexdigest()
        if meta["current"].get("inputs") is not None:
            meta["current"]["digest"] = S.digest_of(meta["current"]["inputs"])
    raw = json.dumps(meta, ensure_ascii=False, indent=2,
                     sort_keys=True).encode("utf-8") + b"\n"
    return raw, data


def probe(title, raw, data, want_words=()):
    """一份样本走三道判据: 恢复联合校验 / 落地后的健康状态 / 发送。

    这三处必须给出**同一个**结论 —— 恢复严一点、健康宽一点, 结果就是坏产物照样能发出去。
    """
    verdicts = {}
    try:
        S.validate_restore_set(raw, data, None)
        verdicts["RESTORE"] = "ACCEPT"
        why = ""
    except S.StateError as e:
        verdicts["RESTORE"] = "REJECT"
        why = str(e)
    b = Box()
    os.makedirs(b.art, mode=0o700, exist_ok=True)
    with open(b.meta, "wb") as f:
        f.write(raw)
    with open(b.p(ARC_CUR), "wb") as f:
        f.write(data)
    try:
        meta = json.loads(raw.decode("utf-8"))
    except ValueError:
        meta = None
    try:
        st, detail = b.s.artifact_health(meta, "current", b.art)
    except Exception as e:  # noqa: BLE001
        st, detail = "EXC:" + type(e).__name__, str(e)
    verdicts["HEALTH"] = st
    try:
        b.s.verified_artifact(meta, "current", b.art)
        verdicts["SEND"] = "YES"
    except Exception:  # noqa: BLE001
        verdicts["SEND"] = "NO"
    good = (verdicts["RESTORE"] == "REJECT" and verdicts["HEALTH"] != "healthy"
            and verdicts["SEND"] == "NO")
    if not good:
        bad("%s: 三道判据没有一致拒绝 → %r(%s)" % (title, verdicts, detail[:60]))
        return
    if st.startswith("EXC:"):
        bad("%s: artifact_health 抛了未处理异常 %s, 应当返回 corrupt/state_mismatch"
            % (title, st))
        return
    hit = [w for w in want_words if w in why] if want_words else ["-"]
    if hit:
        ok("%s: 恢复拒绝(命中「%s」)+ 健康判 %s + 拒绝发送" % (title, hit[0], st))
    else:
        bad("%s: 拒是拒了, 但不是这道门: %s" % (title, why[:140]))


print()
print("══ 一、输入必须是本项目的规范形式 ══")

ATTACK_URL = "https://attacker.invalid/beacon"


def _probe_url(meta):
    meta["current"]["inputs"]["probe_url"] = ATTACK_URL


def _probe_doc(doc):
    for r in doc["PayloadContent"][0]["OnDemandRules"]:
        if "URLStringProbe" in r:
            r["URLStringProbe"] = ATTACK_URL


probe("探测地址被换成攻击者的(记录与产物一起改)",
      *forge(_probe_url, _probe_doc), want_words=("探测地址", "probe_url", "推导"))

probe("ssids 里混进整数/空项/重复/未排序",
      *forge(lambda m: m["current"]["inputs"].__setitem__("ssids", ["B", 7, "A", "A", ""]),
             lambda d: d["PayloadContent"][0]["OnDemandRules"].insert(
                 0, {"InterfaceTypeMatch": "WiFi", "SSIDMatch": ["B", 7, "A", "A", ""],
                     "Action": "Disconnect"})),
      want_words=("ssids", "规范", "SSID"))

probe("server_addresses 是整数",
      *forge(lambda m: m["current"]["inputs"].__setitem__("server_addresses", [123]),
             lambda d: d["PayloadContent"][0]["DNSSettings"].__setitem__(
                 "ServerAddresses", [123])),
      want_words=("server_addresses", "规范", "地址"))

probe("server_addresses 有重复项",
      *forge(lambda m: m["current"]["inputs"].__setitem__(
          "server_addresses", ["203.0.113.10", "203.0.113.10"]),
             lambda d: d["PayloadContent"][0]["DNSSettings"].__setitem__(
                 "ServerAddresses", ["203.0.113.10", "203.0.113.10"])),
      want_words=("server_addresses", "规范", "地址"))

probe("dot_host 前后带空白",
      *forge(lambda m: m["current"]["inputs"].__setitem__("dot_host", " dot.example.com "),
             lambda d: d["PayloadContent"][0]["DNSSettings"].__setitem__(
                 "ServerName", " dot.example.com ")),
      want_words=("dot_host", "规范"))

probe("dns_protocol 不是 TLS",
      *forge(lambda m: m["current"]["inputs"].__setitem__("dns_protocol", "HTTPS"),
             lambda d: d["PayloadContent"][0]["DNSSettings"].__setitem__(
                 "DNSProtocol", "HTTPS")),
      want_words=("dns_protocol", "TLS"))

print()
print("══ 二、本项目固定写死的显示名 ══")
probe("顶层显示名被改成 Trusted Corporate MDM",
      *forge(None, lambda d: d.__setitem__("PayloadDisplayName", "Trusted Corporate MDM")),
      want_words=("显示名", "DisplayName"))
probe("DNS payload 显示名被改成 Install Security Update",
      *forge(None, lambda d: d["PayloadContent"][0].__setitem__(
          "PayloadDisplayName", "Install Security Update")),
      want_words=("显示名", "DisplayName"))

print()
print("══ 三、身份必须是规范小写的 UUID4 ══")


def ident_sample(instance_id):
    """整份记录 + 产物都按这个 instance_id 重造, 于是所有派生 UUID 都自洽。"""
    ids = S.derive_ids(instance_id)
    doc = plistlib.loads(BASE_CUR)
    doc["PayloadUUID"] = ids["root"]
    doc["PayloadIdentifier"] = IP.ID_ROOT + "." + ids["root"]
    doc["PayloadContent"][0]["PayloadUUID"] = ids["dns"]
    doc["PayloadContent"][0]["PayloadIdentifier"] = IP.ID_DNS + "." + ids["dns"]
    for x in doc["PayloadContent"]:
        if x.get("PayloadType") == "com.apple.security.root":
            x["PayloadUUID"] = ids["ca"]
    data = plistlib.dumps(doc)
    meta = json.loads(json.dumps(BASE_META))
    meta["instance_id"] = instance_id
    meta["current"]["sha256"] = hashlib.sha256(data).hexdigest()
    raw = json.dumps(meta, ensure_ascii=False, indent=2,
                     sort_keys=True).encode("utf-8") + b"\n"
    return raw, data


probe("instance_id 根本不是 UUID", *ident_sample("not-a-uuid-at-all"),
      want_words=("instance_id", "UUID", "身份"))
probe("instance_id 是大写形式的 UUID",
      *ident_sample(str(_uuid.uuid4()).upper()),
      want_words=("instance_id", "UUID", "小写"))
probe("instance_id 是带花括号的 UUID",
      *ident_sample("{" + str(_uuid.uuid4()) + "}"),
      want_words=("instance_id", "UUID"))
probe("instance_id 是 UUID1(不是 version 4)",
      *ident_sample(str(_uuid.uuid1())),
      want_words=("instance_id", "UUID", "version"))

print()
print("══ 四、时间必须是真实的 UTC 时刻 ══")
probe("created_at 是 null",
      *forge(lambda m: m.__setitem__("created_at", None)),
      want_words=("created_at", "时间"))
probe("created_at 是不存在的日期(2026-02-30)",
      *forge(lambda m: m.__setitem__("created_at", "2026-02-30T00:00:00Z")),
      want_words=("created_at", "时间"))
probe("generated_at 是不存在的时刻(99:99:99)",
      *forge(lambda m: m["current"].__setitem__("generated_at", "2026-01-01T99:99:99Z")),
      want_words=("generated_at", "时间"))
probe("generated_at 不是本项目的格式",
      *forge(lambda m: m["current"].__setitem__("generated_at", "2026/01/01 10:00:00")),
      want_words=("generated_at", "时间", "格式"))
probe("sent_at 是不存在的日期",
      *forge(lambda m: m["current"].__setitem__("sent_at", "2026-13-01T00:00:00Z")),
      want_words=("sent_at", "时间"))

print()
print("══ 五、本地 load() 也要 fail-closed, 不能让状态页去崩 ══")
for label, mutate in (("非 UUID 身份", lambda m: m.__setitem__("instance_id", "nope")),
                      ("created_at 为 null", lambda m: m.__setitem__("created_at", None)),
                      ("generated_at 非法",
                       lambda m: m["current"].__setitem__("generated_at", "x"))):
    b = Box()
    os.makedirs(b.art, mode=0o700, exist_ok=True)
    raw, data = forge(mutate)
    with open(b.meta, "wb") as f:
        f.write(raw)
    with open(b.p(ARC_CUR), "wb") as f:
        f.write(data)
    try:
        m = b.s.load(b.meta)
    except b.s.StateError as e:
        ok("%s: load() fail-closed 并给出 StateError(%s)" % (label, str(e)[:60]))
        continue
    except Exception as e:  # noqa: BLE001
        bad("%s: load() 抛的是 %s 而不是 StateError" % (label, type(e).__name__))
        continue
    try:
        b.s.status_lines(m, None, b.art)
        bad("%s: load() 放行了, 状态页也画出来了 —— 坏记录被当成好的" % label)
    except Exception as e:  # noqa: BLE001
        bad("%s: load() 放行了, 状态页随后崩在 %s —— 应该在 load 就拒"
            % (label, type(e).__name__))

print()
print("══ 六、正常样本一律不许误伤 ══")
for label, kw in (("无 CA、无 SSID", {}),
                  ("有 CA、无 SSID", {"ca": CA_A}),
                  ("无 CA、有 SSID", {"ssids": ["Home", "Office"]}),
                  ("有 CA、有 SSID", {"ca": CA_A, "ssids": ["Café ☕", "办公室"]})):
    nb = Box()
    nb.gen(host="dot.normal.example", **kw)
    raw, cur = nb.rd(ARC_META), nb.rd(ARC_CUR)
    try:
        nb.s.validate_restore_set(raw, cur, None)
        st, _d = nb.s.artifact_health(json.loads(raw.decode("utf-8")), "current", nb.art)
        nb.s.verified_artifact(json.loads(raw.decode("utf-8")), "current", nb.art)
        if st == "healthy":
            ok("现渲染的正常产物(%s): 恢复校验通过 + 健康 + 可发送" % label)
        else:
            bad("现渲染的正常产物(%s)健康判成 %s" % (label, st))
    except Exception as e:  # noqa: BLE001
        bad("现渲染的正常产物(%s)被自己人挡住: %s" % (label, str(e)[:140]))

mb = Box()
mb.gen(host="dot.multi.example", addrs=["203.0.113.10", "198.51.100.7"], ca=CA_A)
try:
    mb.s.validate_restore_set(mb.rd(ARC_META), mb.rd(ARC_CUR), None)
    ok("多个合法字符串服务器地址: 正常通过")
except Exception as e:  # noqa: BLE001
    bad("多地址被误伤: %s" % str(e)[:140])

print()
print("══ 七、三个生产入口对同一份坏样本的结论必须一致 ══")
# 选"任意探测地址"那一例: 它最能说明问题不是某个辅助函数的孤立缺陷。
EVIL_RAW, EVIL_CUR = forge(_probe_url, _probe_doc)
BASE_MEMBERS = ["etc/sing-box/config.json", "etc/mosdns/config.yaml"]

evil_dir = _tmp("iossc-evil-")
for rel in BASE_MEMBERS:
    os.makedirs(os.path.dirname(os.path.join(evil_dir, rel)), exist_ok=True)
    shutil.copy2(BASE.p(rel), os.path.join(evil_dir, rel))
with open(os.path.join(evil_dir, "etc/sing-box/config.json"), "w") as f:
    json.dump({"outbounds": [{"tag": "evil-marker"}], "route": {"rules": []}}, f)
for rel, blob in ((ARC_META, EVIL_RAW), (ARC_CUR, EVIL_CUR)):
    os.makedirs(os.path.dirname(os.path.join(evil_dir, rel)), exist_ok=True)
    with open(os.path.join(evil_dir, rel), "wb") as f:
        f.write(blob)


def pack(root, members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for arc in members:
            f = os.path.join(root, arc)
            if os.path.isfile(f):
                tar.add(f, arcname=arc)
    return buf.getvalue()


EVIL_BLOB = pack(evil_dir, BASE_MEMBERS + [ARC_META, ARC_CUR])

BOT_RUNNER = r'''
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
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS, json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
m._mihomo_derive = lambda staged: b"# stub\n"
m._core_svc = lambda: "mihomo"
okv, msg = m.restore_from(open(%(blob)r, "rb").read())
print("RESULT " + json.dumps({"ok": bool(okv), "msg": msg}, ensure_ascii=False))
'''

RESCUE_RUNNER = r'''
import json, os, sys
sys.path.insert(0, %(botdir)r)
os.environ["PDG_TX_FSROOT"] = %(root)r
os.environ["PDG_LOCKFILE"] = %(root)r + "/run/privdns-gateway.lock"
import pdgtx, cfgrestore
pdgtx._run = lambda cmd, timeout=60, **kw: (0, "")
pdgtx._svc_prop = lambda u, prop: ("active" if prop == "ActiveState" else "running")
pdgtx._svc_prop_ex = lambda u, prop: (("active" if prop == "ActiveState" else "running"), True)
pdgtx._svc_active = lambda u: True
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS, json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
cfgrestore.mihomorender.deriver_from_paths = lambda **kw: (lambda staged: b"# stub\n")
cfgrestore.snapshot_ids = lambda: ["snap"]
cfgrestore.snapshot_path = lambda i: %(snap)r if i == "snap" else ""
res = cfgrestore.restore_managed("snap", trigger_source="test")
print("RESULT " + json.dumps({"ok": bool(res.get("ok")), "msg": res.get("error") or ""},
                             ensure_ascii=False))
'''


def _run(code):
    p = subprocess.run([sys.executable, "-c", code], capture_output=True,
                       text=True, timeout=900)
    for line in reversed((p.stdout or "").splitlines()):
        if line.startswith("RESULT "):
            return json.loads(line[7:])
    return {"ok": False, "msg": "[runner crashed] " + (p.stderr or "")[-400:]}


CLI_FNS = ("_pdg_mktemp_dir", "_pdg_apply_snapshot_tree")


def _cli_harness():
    out = []
    for c in ("_PDG_IOS_STATE_REL", "_PDG_IOS_ART_REL"):
        out.append(subprocess.run(["sed", "-n", "/^%s=/p" % c, PDG],
                                  capture_output=True, text=True).stdout)
    names = subprocess.run(
        ["bash", "-c", "grep -oE '^_pdg_ios_[a-z_]+\\(\\)' %s | tr -d '()'" % PDG],
        capture_output=True, text=True).stdout.split()
    for fn in list(CLI_FNS) + names:
        out.append(subprocess.run(["sed", "-n", "/^%s(){/,/^}/p" % fn, PDG],
                                  capture_output=True, text=True).stdout)
    return "\n".join(out)


CLI = _cli_harness()
for fn in list(CLI_FNS) + ["_pdg_ios_verify_tree", "_pdg_ios_reconcile"]:
    if "%s(){" % fn not in CLI:
        bad("抽不到生产函数 %s —— 这个测试就没有在测生产代码" % fn)
CLI_GATE = r'''
_pdg_module(){ printf '%s\n' "$IOSSTATE"; }
cli_rollback(){
  _pdg_ios_verify_tree "$1" "$2" || return 1
  _pdg_apply_snapshot_tree "$1" "$2" "$3"
}
'''


def cli_rollback(box, blob):
    tmp = _tmp("iossc-tree-")
    tree = os.path.join(tmp, "tree")
    os.makedirs(tree)
    snap = os.path.join(tmp, "snap.tar.gz")
    with open(snap, "wb") as f:
        f.write(blob)
    members = os.path.join(tmp, "members")
    with open(members, "w") as f:
        f.write(subprocess.run(["tar", "tzf", snap], capture_output=True,
                               text=True).stdout)
    subprocess.run(["tar", "xzf", snap, "-C", tree], check=True, capture_output=True)
    env = dict(os.environ, IOSSTATE=os.path.join(BOTDIR, "iosstate.py"),
               PDG_TX_FSROOT=box.root,
               PDG_LOCKFILE=box.root + "/run/privdns-gateway.lock")
    return subprocess.run(["bash", "-c", CLI + "\n" + CLI_GATE
                           + '\ncli_rollback "$1" "$2" "$3"\n', "x", tree, members,
                           box.root], capture_output=True, text=True, env=env)


def victim():
    v = Box()
    v.gen(ca=CA_A)
    v.gen(host="dot.v2.example", ca=CA_A)
    return v


def _write(box, blob):
    f = box.root + "/in.tar.gz"
    with open(f, "wb") as fh:
        fh.write(blob)
    return f


for who, mk in (("Bot", lambda b: BOT_RUNNER % {"botdir": BOTDIR, "bot": BOT,
                                                "root": b.root,
                                                "blob": _write(b, EVIL_BLOB)}),
                ("救援平面", lambda b: RESCUE_RUNNER % {"botdir": BOTDIR, "root": b.root,
                                                        "snap": _write(b, EVIL_BLOB)})):
    v = victim()
    before, before_st = v.group(), v.stats()
    sb_before = v.rd("etc/sing-box/config.json")
    res = _run(mk(v))
    msg = res.get("msg") or ""
    if not res["ok"] and ("探测地址" in msg or "probe_url" in msg or "推导" in msg):
        ok("%s: 整笔拒绝并点名探测地址(%s)" % (who, msg.splitlines()[-1][:60]))
    else:
        bad("%s: 没被拒或不是这道门: ok=%s %r" % (who, res["ok"], msg[:160]))
    if v.group() == before and v.stats() == before_st:
        ok("%s: iOS 三件套内容与 mode/uid/gid 全部不变" % who)
    else:
        bad("%s: 现网这一组被改了" % who)
    if v.rd("etc/sing-box/config.json") == sb_before:
        ok("%s: 网关配置也没被恢复(整笔拒绝)" % who)
    else:
        bad("%s: 这一组被拒了, 网关配置却换掉了" % who)

v = victim()
before, before_st = v.group(), v.stats()
r = cli_rollback(v, EVIL_BLOB)
out = (r.stdout or "") + (r.stderr or "")
if r.returncode != 0 and ("探测地址" in out or "probe_url" in out or "推导" in out):
    ok("CLI: 覆盖生产文件之前就被拦下并点名探测地址")
else:
    bad("CLI 没拦住: rc=%d %r" % (r.returncode, out[-200:]))
if v.group() == before and v.stats() == before_st:
    ok("CLI: iOS 三件套内容与 mode/uid/gid 全部不变")
else:
    bad("CLI: 现网这一组被改了")

print()
print("══ 八、既有语义不许退化 ══")
none_blob = pack(evil_dir, BASE_MEMBERS)
v = victim()
before = v.group()
res = _run(BOT_RUNNER % {"botdir": BOTDIR, "bot": BOT, "root": v.root,
                         "blob": _write(v, none_blob)})
if res["ok"] and v.group() == before:
    ok("v1.7.8 那种不含生命周期组的旧备份: 照常恢复其它配置, 这一组一个字节不碰")
else:
    bad("旧备份语义变了: ok=%s 组同=%s" % (res["ok"], v.group() == before))

legacy_dir = _tmp("iossc-legacy-")
for rel in BASE_MEMBERS:
    os.makedirs(os.path.dirname(os.path.join(legacy_dir, rel)), exist_ok=True)
    shutil.copy2(BASE.p(rel), os.path.join(legacy_dir, rel))
os.makedirs(os.path.dirname(os.path.join(legacy_dir, ARC_META)), exist_ok=True)
shutil.copy2(BASE.meta, os.path.join(legacy_dir, ARC_META))
legacy_blob = pack(legacy_dir, BASE_MEMBERS + [ARC_META])
v = victim()
res = _run(BOT_RUNNER % {"botdir": BOTDIR, "bot": BOT, "root": v.root,
                         "blob": _write(v, legacy_blob)})
left = sorted(k for k in v.group() if k != ARC_META)
if res["ok"] and not left:
    ok("只有记录、没有产物的 legacy 备份: 语义不变(恢复成功, 产物被清空)")
else:
    bad("legacy 语义变了: ok=%s 残留=%r %s" % (res["ok"], left, (res.get("msg") or "")[:100]))

v = Box()
# 先做 % 替换再改写正文 —— 否则下面那段里的 %d 会被当成格式占位符。
android_code = (BOT_RUNNER % {"botdir": BOTDIR, "bot": BOT, "root": v.root,
                              "blob": _write(v, none_blob)}).replace(
    "okv, msg = m.restore_from",
    'm._platform = lambda: "android"\n'
    "sent = []\n"
    "m.send_document = lambda *a, **k: sent.append(a)\n"
    "m.edit = lambda chat, mid, text, kb=None: None\n"
    "m.send = lambda chat, text, kb=None: None\n"
    "m.send_plain = lambda chat, text: None\n"
    "m.answer_cb_async = lambda *a, **k: None\n"
    "m.state = {}\n"
    'for _d in ("ios", "ios_ssid", "iosgen", "iosgen:fresh", "iosgen:legacy"):\n'
    "    try:\n"
    "        m.handle_cb(1, 2, _d)\n"
    "    except Exception:\n"
    "        pass\n"
    'print("RESULT " + json.dumps({"ok": not sent, "msg": "sent=" + str(len(sent))}))\n'
    "raise SystemExit(0)\n"
    "okv, msg = m.restore_from", 1)
res = _run(android_code)
if res.get("ok"):
    ok("Android: 五个 iOS 回调全部走不通, 一个描述文件都没生成(%s)" % res.get("msg"))
else:
    bad("Android 隔离退化了: %r" % res)

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""根证书那一格必须**恰好**是一张 DER 证书 —— 不多一个字节。

`openssl x509 -inform DER -noout` 只证明"开头能解析出一张证书", 它会把后面剩下的字节直接
忽略掉。于是 `证书DER + 私钥DER` 拼在一起照样退出码 0。这不是理论问题:

  · 这一格的内容会原样落进 `.mobileconfig` 的 PayloadContent, 而那份文件是要发到用户
    iPhone 上安装的。多出来的那段是一把**完整可用的私钥**, 它跟着描述文件出了门;
  · 描述文件本身是公开内容(会被贴进工单、存进网盘), 私钥搭车出去之后收不回来;
  · 全程没有任何一处会报错: 生成通过、artifact_health 判 healthy、verified_artifact 放行、
    恢复的联合校验也放行。

所以判据要从"开头是不是一张证书"改成"**全部字节恰好组成这一张证书**": 让 openssl 把它
重新编码成规范 DER, 要求输出与输入逐字节相同。多一个字节就说明后面还有别的东西。

这里的用例一律用**真的**证书和**真的**私钥, 不拿随机尾随字节冒充 —— 随机字节多半会让
ASN.1 解析直接失败, 那样测出来的是另一件事。
"""
import os
import shutil
import subprocess
import sys
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


def _tmp(prefix):
    d = tmpguard.mkdtemp(prefix=prefix)
    TMPS.append(d)
    return d


def make_cert(name="PDG CA"):
    """一张真的自签 X.509, 返回 (DER, PEM 文本)。"""
    d = _tmp("iosder-ca-")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/k.pem", "-out", d + "/c.pem", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "x509", "-in", d + "/c.pem", "-outform", "DER",
                    "-out", d + "/c.der"], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(d + "/c.der", "rb") as f:
        der = f.read()
    with open(d + "/c.pem", encoding="utf-8") as f:
        pem = f.read()
    return der, pem


def make_key(kind):
    """一把真的私钥的 DER。三种格式都造 —— 它们的 ASN.1 头不一样。"""
    d = _tmp("iosder-key-")
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
    else:                                            # pkcs8
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-outform", "DER",
                        "-pkeyopt", "rsa_keygen_bits:2048", "-out", d + "/k.der"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(d + "/k.der", "rb") as f:
        return f.read()


def is_real_key(der, kind):
    """确认拼上去的那段真的是一把能用的私钥, 而不是随机字节。"""
    args = {"ec": ["openssl", "ec", "-inform", "DER", "-noout"],
            "rsa": ["openssl", "rsa", "-inform", "DER", "-noout"],
            "pkcs8": ["openssl", "pkey", "-inform", "DER", "-noout"]}[kind]
    return subprocess.run(args, input=der, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402

CERT_DER, CERT_PEM = make_cert("PDG CA exact")
KEYS = {k: make_key(k) for k in ("ec", "rsa", "pkcs8")}

print("══ 〇、样本自证: 拼上去的确实是真私钥, 不是随机字节 ══")
for kind, kd in sorted(KEYS.items()):
    if is_real_key(kd, kind):
        ok("%s 私钥样本是 openssl 认得出的真私钥(%d 字节)" % (kind, len(kd)))
    else:
        bad("%s 样本不是真私钥, 这组用例就没有意义" % kind)
if subprocess.run(["openssl", "x509", "-inform", "DER", "-noout"], input=CERT_DER,
                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
    ok("证书样本是一张真的 X.509(%d 字节)" % len(CERT_DER))
else:
    bad("证书样本不合法")
# 这条是本文件的**前提**: 旧判据(只看退出码)对拼接样本是放行的
_probe = subprocess.run(["openssl", "x509", "-inform", "DER", "-noout"],
                        input=CERT_DER + KEYS["pkcs8"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if _probe.returncode == 0:
    ok("前提成立: `openssl x509 -noout` 对「证书+私钥」拼接返回 0(它忽略尾随字节)")
else:
    bad("前提不成立: openssl 自己就拒了拼接样本, 这组用例测不到想测的东西")

print()
print("══ 一、assert_public_cert_der: 恰好一张证书才放行 ══")


def expect_ok(label, der):
    try:
        iosprofile.assert_public_cert_der(der, "样本")
        ok(label)
    except Exception as e:  # noqa: BLE001
        bad("%s: 竟被拒 —— %s" % (label, str(e)[:100]))


def expect_reject(label, der, words):
    try:
        iosprofile.assert_public_cert_der(der, "样本")
        bad("%s: 竟然放行了" % label)
        return
    except iosprofile.ProfileError as e:
        msg = str(e)
    except Exception as e:  # noqa: BLE001
        bad("%s: 抛的不是 ProfileError 而是 %s" % (label, type(e).__name__))
        return
    hit = [w for w in words if w in msg]
    if hit:
        ok("%s: 被拒, 命中「%s」" % (label, hit[0]))
    else:
        bad("%s: 拒是拒了, 但不是这道门: %s" % (label, msg[:120]))
    # 拒绝消息里不许出现待检内容(证书/私钥正文)。这段东西一旦进了日志或工单就收不回来。
    leak = []
    for probe in (CERT_DER[:16], KEYS["ec"][:16], KEYS["rsa"][:16], KEYS["pkcs8"][:16]):
        if probe.decode("latin-1") in msg:
            leak.append(probe.hex()[:12])
    import base64
    for probe in (CERT_DER, KEYS["pkcs8"]):
        if base64.b64encode(probe)[:24].decode() in msg:
            leak.append("base64")
    if leak:
        bad("%s: 拒绝消息里泄漏了待检字节(%r)" % (label, leak))


expect_ok("正常单张 DER 证书", CERT_DER)
for kind in ("ec", "rsa", "pkcs8"):
    expect_reject("纯 DER %s 私钥" % kind, KEYS[kind], ["私钥", "证书"])
    expect_reject("证书 + DER %s 私钥拼接" % kind, CERT_DER + KEYS[kind],
                  ["额外数据", "单一", "多余", "恰好"])
expect_reject("证书 + 一段随机尾随字节", CERT_DER + os.urandom(64),
              ["额外数据", "单一", "多余", "恰好"])
expect_reject("证书 + 第二张证书", CERT_DER + make_cert("second")[0],
              ["额外数据", "单一", "多余", "恰好"])
expect_reject("空输入", b"", ["空"])
expect_reject("根本不是 DER", b"hello world", ["DER", "结构"])

print()
print("══ 二、没有 openssl 就不许放行(结构判据不能冒充强校验)══")
code = (
    "import sys, os\n"
    "sys.path.insert(0, %r)\n"
    "os.environ['PATH'] = '/nonexistent-openssl'\n"
    "import iosprofile\n"
    "der = open(%r, 'rb').read()\n"
    "try:\n"
    "    iosprofile.assert_public_cert_der(der, '样本')\n"
    "    print('RESULT accepted')\n"
    "except iosprofile.ProfileError as e:\n"
    "    print('RESULT rejected ' + str(e).replace(chr(10), ' '))\n")
_cd = _tmp("iosder-nossl-")
with open(_cd + "/c.der", "wb") as f:
    f.write(CERT_DER)
_env = dict(os.environ, PATH="/nonexistent-openssl")
_p = subprocess.run([sys.executable, "-c", code % (BOTDIR, _cd + "/c.der")],
                    capture_output=True, text=True, env=_env, timeout=300)
_line = [l for l in (_p.stdout or "").splitlines() if l.startswith("RESULT ")]
if _line and _line[0].startswith("RESULT rejected") and "强校验" in _line[0]:
    ok("openssl 不可用 → 拒绝并点名「强校验不可用」")
else:
    bad("openssl 不可用时的行为不对: %r" % (_line or (_p.stderr or "")[-200:]))

print()
print("══ 三、强校验要覆盖每一条让产物进入可信状态的路 ══")
# 一份"CA 那一格是 证书+私钥"的描述文件, 必须在下面每一条路上都被挡住。
import hashlib  # noqa: E402
import json  # noqa: E402
import plistlib  # noqa: E402

ROOTFS = _tmp("iosder-box-")
for d in ("etc/privdns-gateway", "run", "var/lib/privdns-gateway"):
    os.makedirs(os.path.join(ROOTFS, d), exist_ok=True)
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = ROOTFS + "/run/privdns-gateway.lock"
for m in ("iosstate", "iosprofile", "pdgtx"):
    sys.modules.pop(m, None)
sys.path.insert(0, BOTDIR)
import iosprofile as IP  # noqa: E402
import iosstate as S  # noqa: E402

META = ROOTFS + "/etc/privdns-gateway/ios-profile.json"
ART = ROOTFS + "/var/lib/privdns-gateway/ios-profile"
GLUED = CERT_DER + KEYS["pkcs8"]

# 路径 1: PEM 入口(生成时读 /etc/privdns-gateway/ca/ca.crt 走的就是它)
import base64  # noqa: E402
glued_pem = ("-----BEGIN CERTIFICATE-----\n"
             + "\n".join(base64.b64encode(GLUED).decode()[i:i + 64]
                         for i in range(0, len(base64.b64encode(GLUED).decode()), 64))
             + "\n-----END CERTIFICATE-----\n")
try:
    IP.ca_der_from_pem(glued_pem)
    bad("路径1 ca_der_from_pem: 放行了「证书+私钥」的 PEM —— 生成路径就带着私钥出门了")
except IP.ProfileError as e:
    ok("路径1 ca_der_from_pem: 被拒(%s)" % str(e)[:60])

# 路径 2: render(最终字节的守门人 validate 就在它里面)
ids = S.derive_ids("11111111-2222-3333-4444-555555555555")
try:
    IP.render("dot.example.com", "203.0.113.10", (), GLUED, ids, TMPL)
    bad("路径2 render: 生成出了一份 CA 那一格夹着私钥的描述文件")
except IP.ProfileError as e:
    ok("路径2 render: 被拒(%s)" % str(e)[:60])

# 路径 3/4: 先造一份健康的产物, 再把 CA 那一格换成拼接体并把记录全部配平,
#           然后看 artifact_health / verified_artifact / 联合校验各自怎么说。
good = S.generate("dot.example.com", "203.0.113.10", (), CERT_DER, True, TMPL,
                  META, ART, True, False)[0]
doc = plistlib.loads(open(os.path.join(ART, "current.mobileconfig"), "rb").read())
for x in doc["PayloadContent"]:
    if x.get("PayloadType") == "com.apple.security.root":
        x["PayloadContent"] = GLUED
forged = plistlib.dumps(doc)
meta = json.load(open(META, encoding="utf-8"))
meta["current"]["inputs"]["wloc_ca_sha256"] = hashlib.sha256(GLUED).hexdigest()
meta["current"]["sha256"] = hashlib.sha256(forged).hexdigest()
meta["current"]["digest"] = S.digest_of(meta["current"]["inputs"])
raw = json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
with open(os.path.join(ART, "current.mobileconfig"), "wb") as f:
    f.write(forged)
with open(META, "wb") as f:
    f.write(raw)

st, detail = S.artifact_health(meta, "current", ART)
if st != S.HEALTHY:
    ok("路径3 artifact_health: 判成 %s(%s)" % (st, detail[:50]))
else:
    bad("路径3 artifact_health: 判成 healthy —— 这份夹着私钥的产物被当成可信的了")
try:
    S.verified_artifact(meta, "current", ART)
    bad("路径3 verified_artifact: 放行了, 它会被发到用户手机上")
except S.StateError as e:
    ok("路径3 verified_artifact: 拒绝发送(%s)" % str(e)[:50])
try:
    S.validate_restore_set(raw, forged, None)
    bad("路径4 validate_restore_set: 恢复的联合校验放行了")
except S.StateError as e:
    ok("路径4 validate_restore_set: 被拒(%s)" % str(e)[:60])

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

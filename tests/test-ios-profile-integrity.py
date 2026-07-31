#!/usr/bin/env python3
"""服务端产物完整性 —— **先复现, 再修**。

这个文件的第一版是在动代码之前写的, 用来证明两个缺口真实存在:

  问题 1: 记录与产物不一致(current 缺失/被改/hash 对不上/来自另一个 revision;
          previous 缺失/被改)全被当成"建议更新"。那是**手机要不要重装**的语气, 而实际发生
          的是**服务器上的文件不能用**。更糟的是发送路径不做校验, 于是"发送 current /
          发送 previous"可能把一份对不上记录的文件发出去。

  问题 2: 备份与快照只带 metadata, 不带产物。恢复之后 revision 说是 2、盘上的文件却是 3,
          而 previous 那一版的 CA 早就不在了(元数据里只有指纹, 没有证书正文)——
          **根本无法确定性重建**, 可当时的代码却对外声称"已按记录重建"。

修好之后这些断言全部保留, 语义翻转成"必须被检出并 fail-closed"。
"""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

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
    d = tempfile.mkdtemp(prefix="iosint-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    """独立 FSROOT 沙箱: 元数据、产物、锁全在里面。"""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="iosint-")
        TMPS.append(self.root)
        os.makedirs(self.root + "/etc/privdns-gateway", exist_ok=True)
        os.makedirs(self.root + "/run", exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = self.root
        os.environ["PDG_LOCKFILE"] = self.root + "/run/privdns-gateway.lock"
        for m in ("iosstate", "iosprofile", "pdgtx", "cfgrestore"):
            sys.modules.pop(m, None)
        sys.path.insert(0, BOTDIR)
        import iosstate
        self.s = iosstate
        self.meta = self.root + "/etc/privdns-gateway/ios-profile.json"
        self.art = self.root + "/var/lib/privdns-gateway/ios-profile"

    def gen(self, host="dot.example.com", ip="203.0.113.10", ssids=(), ca=b"", legacy=False):
        return self.s.generate(host, ip, ssids, ca, bool(ca), TMPL,
                               self.meta, self.art, True, legacy)

    def cur(self):
        return os.path.join(self.art, "current.mobileconfig")

    def prev(self):
        return os.path.join(self.art, "previous.mobileconfig")

    def read_meta(self):
        with open(self.meta, encoding="utf-8") as f:
            return json.load(f)


sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402

CA_A = iosprofile.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())
CA_B = iosprofile.ca_der_from_pem(open(mkca("PDG CA B"), encoding="utf-8").read())
CA_C = iosprofile.ca_der_from_pem(open(mkca("PDG CA C"), encoding="utf-8").read())


def health(box, which="current"):
    """产物健康状态。修复前 iosstate 没有这个概念 —— 那正是问题 1。"""
    fn = getattr(box.s, "artifact_health", None)
    if fn is None:
        return None, "iosstate 没有 artifact_health(还没有产物健康状态这个概念)"
    return fn(box.read_meta(), which, box.art)


def can_send(box, which="current"):
    """发送前校验。返回 (是否放行, 说明)。"""
    fn = getattr(box.s, "verified_artifact", None)
    if fn is None:
        return None, "iosstate 没有 verified_artifact(发送路径没有统一校验)"
    try:
        blob = fn(box.read_meta(), which, box.art)
        return True, "放行 %d 字节" % len(blob)
    except Exception as e:  # noqa: BLE001
        return False, str(e)


print("══ 一、产物完整性: 六种人为损坏 ══")

CASES = []


def case(label, setup, which="current"):
    CASES.append((label, setup, which))


def _drop_current(b):
    os.unlink(b.cur())


def _tamper_current(b):
    with open(b.cur(), "ab") as f:
        f.write(b"<!-- tampered -->")


def _hash_mismatch(b):
    """内容不动, 改记录里的 sha —— 单独验"以 metadata 为准"这条判据本身。"""
    m = b.read_meta()
    m["current"]["sha256"] = "0" * 64
    with open(b.meta, "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=2, sort_keys=True)


def _drop_previous(b):
    os.unlink(b.prev())


def _tamper_previous(b):
    with open(b.prev(), "ab") as f:
        f.write(b"<!-- tampered -->")


def _cross_revision(b):
    """metadata 说 current 是第 2 版, 盘上放的却是第 1 版的文件(串位)。"""
    shutil.copyfile(b.prev(), b.cur())


case("current 缺失", _drop_current)
case("current 内容被改", _tamper_current)
case("current 的 hash 与记录不符", _hash_mismatch)
case("previous 缺失", _drop_previous, "previous")
case("previous 内容被改", _tamper_previous, "previous")
case("current 其实是另一个 revision 的文件(串位)", _cross_revision)

for label, setup, which in CASES:
    b = Box()
    b.gen(ca=CA_A)                      # rev1
    b.gen(host="dot.v2.example", ca=CA_A)   # rev2, previous=rev1
    setup(b)
    st, detail = health(b, which)
    if st is None:
        bad("%s → %s" % (label, detail))
    elif st == "healthy":
        bad("%s → 竟然判成 healthy" % label)
    else:
        ok("%s → 产物健康状态 %s(%s)" % (label, st, detail[:48]))
    sendable, why = can_send(b, which)
    if sendable is None:
        bad("%s → %s" % (label, why))
    elif sendable:
        bad("%s → 发送路径**放行**了(会把对不上的文件发出去): %s" % (label, why))
    else:
        ok("%s → 发送被拒: %s" % (label, why[:60]))

print()
print("══ 二、等级与健康状态互不污染 ══")
b = Box()
b.gen(ca=CA_A)
_tamper_current(b)
lv, why = b.s.classify(b.read_meta(),
                       b.s.make_inputs("dot.example.com", "203.0.113.10", (), True, CA_A, TMPL))
if lv == b.s.NONE and not any("产物" in r or "重建" in r for r in why):
    ok("产物损坏**不影响**配置变化等级: 仍是「%s」" % b.s.LEVEL_LABEL[lv])
else:
    bad("产物损坏污染了配置变化等级: %s %s" % (lv, why))
st, detail = health(b)
if st not in (None, "healthy"):
    ok("同一时刻产物健康状态单独给出: %s" % st)
else:
    bad("产物健康状态没有单独表达: %r %s" % (st, detail))

b2 = Box()
b2.gen(ca=CA_A)
lv2, why2 = b2.s.classify(b2.read_meta(),
                          b2.s.make_inputs("dot.new.example", "203.0.113.10", (), True, CA_A, TMPL))
st2, _ = health(b2)
if lv2 == "required" and st2 == "healthy":
    ok("反过来: 配置真的变了 → 必须更新, 而产物健康状态仍是 healthy")
else:
    bad("反向污染: lv=%s health=%r" % (lv2, st2))

print()
print("══ 三、自动修复的边界 ══")
b = Box()
b.gen(ca=CA_A)
rev = b.read_meta()["current"]["revision"]
orig = open(b.cur(), "rb").read()
prev_before = os.path.exists(b.prev())
_drop_current(b)
m, lv, why, data, changed = b.gen(ca=CA_A)
after = open(b.cur(), "rb").read()
if after == orig and b.read_meta()["current"]["revision"] == rev and not changed:
    ok("输入与记录一致 + CA 指纹一致 → 逐字节复原, revision 不变")
else:
    bad("确定性修复不成立: 字节相同=%s rev=%s" % (after == orig, b.read_meta()["current"]["revision"]))
if os.path.exists(b.prev()) == prev_before:
    ok("修复不动 previous")
else:
    bad("修复过程改动了 previous")

# 无法精确重建: CA 换了(指纹对不上) → 不许"修复", 只能当成新版本
b = Box()
b.gen(ca=CA_A)
rev = b.read_meta()["current"]["revision"]
_drop_current(b)
repair = getattr(b.s, "repair_current", None)
if repair is None:
    bad("iosstate 没有 repair_current(自动修复没有独立入口, 边界无从表达)")
else:
    try:
        repair(CA_C, TMPL, b.meta, b.art, True)
        bad("CA 指纹对不上却仍然「修复」了")
    except Exception as e:  # noqa: BLE001
        # 判据要落在**是哪道门拦下的**上。渲染结果的 sha 也对不上, 所以只断言"被拒了"会让
        # 指纹这道门被删掉也照样绿 —— 而它正是那句能让用户看懂的话("你手上的不是那一版用的
        # 证书"), 少了它就退化成一句含糊的"结果对不上"。
        if "根证书指纹" in str(e):
            ok("CA 指纹对不上 → 由指纹这道门拒绝: %s" % str(e)[:56])
        else:
            bad("拒是拒了, 但不是指纹那道门(消息里没提指纹): %s" % str(e)[:90])
    if b.read_meta()["current"]["revision"] == rev:
        ok("拒绝修复之后 revision 没有被偷偷推进")
    else:
        bad("revision 被推进了")

# `pdg ios repair` 在文件本就正常时必须说"无需修复", 而不是"已复原" —— 后者会让用户以为
# 刚才真出过问题。文件坏了才动手, 且动手前先把坏在哪说出来。
ST = os.path.join(BOTDIR, "iosstate.py")
# 这一段不带 WLOC: repair 的 CA 参数由 --wloc-config/--ca-crt 决定, 不传就等于"手上没有证书"。
# 用一个本来就没有 CA 的版本, 才是在验"正常/缺失"这两种情形本身, 而不是又一次验指纹那道门。
b = Box()
b.gen()
env = dict(os.environ, PDG_TX_FSROOT=b.root, PDG_LOCKFILE=b.root + "/run/privdns-gateway.lock")
r = subprocess.run([sys.executable, ST, "repair", "--template", TMPL],
                   capture_output=True, text=True, timeout=180, env=env)
if r.returncode == 0 and "无需修复" in r.stdout and "已按记录" not in r.stdout:
    ok("产物正常时 `repair` 只报「无需修复」, 不谎称复原过")
else:
    bad("正常时的 repair 输出不对: rc=%d %r" % (r.returncode, r.stdout[:150]))
_drop_current(b)
r = subprocess.run([sys.executable, ST, "repair", "--template", TMPL],
                   capture_output=True, text=True, timeout=180, env=env)
if r.returncode == 0 and "已按记录" in r.stdout and "缺失" in r.stdout:
    ok("产物真的缺失时: 先说清坏在哪, 再复原")
else:
    bad("缺失时的 repair 输出不对: rc=%d %r %r" % (r.returncode, r.stdout[:150], r.stderr[-150:]))

print()
print("══ 四、previous 不许猜着重建 ══")
b = Box()
b.gen(ca=CA_A)                          # rev1, CA=A
b.gen(host="dot.v2.example", ca=CA_B)   # rev2, CA=B; previous=rev1(CA=A)
prev_bytes = open(b.prev(), "rb").read()
_drop_previous(b)
# 现在服务器手里只有 CA=B。rev1 用的 A 只剩指纹, 证书正文早就不在了。
st, detail = health(b, "previous")
if st in ("missing",):
    ok("previous 缺失被如实标成 missing")
elif st is None:
    bad(detail)
else:
    bad("previous 缺失被标成 %s" % st)
sendable, why = can_send(b, "previous")
if sendable is False and ("不可用" in why or "缺失" in why or "无法" in why):
    ok("previous 缺失 → 明说不可用, 不声称能重建: %s" % why[:60])
elif sendable is None:
    bad(why)
else:
    bad("previous 缺失却放行了")
# 关键: 绝不能拿当前的 CA(B)去"重建"出一个假的 rev1
b.gen(host="dot.v2.example", ca=CA_B)
if not os.path.exists(b.prev()):
    ok("再生成一次也不会凭空造出 previous(拿当前 CA 猜出来的不是那一版)")
elif open(b.prev(), "rb").read() == prev_bytes:
    bad("previous 竟然「重建」成功了 —— 那份的 CA 正文已经不在服务器上, 不可能")
else:
    bad("previous 被伪造成了另一份内容")

print()
print("══ 五、备份/快照必须带上产物 ══")
b = Box()
b.gen(ca=CA_A)                              # rev1 CA=A
b.gen(host="dot.v2.example", ca=CA_B)       # rev2 CA=B, previous=rev1
snap_cur = open(b.cur(), "rb").read()
snap_prev = open(b.prev(), "rb").read()
snap_meta = open(b.meta, "rb").read()

# CLI snapshot 的候选路径白名单
cand = subprocess.run(
    ["bash", "-c",
     r"""sed -n '/^cmd_snapshot()/,/^}/p' deploy/bot/pdg.sh """
     r"""| sed -n '/local cand=(/,/)$/p' | tr -d '\\' | tr ' ' '\n' """
     r"""| sed 's/local cand=(//;s/)$//' | grep -v '^$'"""],
    capture_output=True, text=True, cwd=ROOT, timeout=120).stdout.split()
if any(c == "var/lib/privdns-gateway/ios-profile" or c.startswith("var/lib/privdns-gateway/ios-profile")
       for c in cand):
    ok("CLI snapshot 候选里含产物目录")
else:
    bad("CLI snapshot **不含**产物目录(恢复回来只有记录没有文件): %r" % [c for c in cand if "var/lib" in c])

# Bot 备份清单
for m in ("cfgrestore", "pdgtx"):
    sys.modules.pop(m, None)
import importlib.util as _u  # noqa: E402
_spec = _u.spec_from_file_location("pdg_bot_int", os.path.join(BOTDIR, "pdg-bot.py"))
_bot = _u.module_from_spec(_spec)
_spec.loader.exec_module(_bot)
_prod = list(_bot.BACKUP_FILES)
want = ["/var/lib/privdns-gateway/ios-profile/current.mobileconfig",
        "/var/lib/privdns-gateway/ios-profile/previous.mobileconfig"]
missing = [w for w in want if w not in _prod]
if not missing:
    ok("Bot 备份清单含 current 与 previous 产物")
else:
    bad("Bot 备份清单缺产物: %s" % ", ".join(missing))

import cfgrestore  # noqa: E402
import pdgtx       # noqa: E402
for rel in ("var/lib/privdns-gateway/ios-profile/current.mobileconfig",
            "var/lib/privdns-gateway/ios-profile/previous.mobileconfig"):
    if cfgrestore.member_allowed(rel):
        ok("恢复白名单认 %s" % os.path.basename(rel))
    else:
        bad("恢复白名单不认 %s(恢复时被静默跳过)" % rel)

for t in ("ios_profile_state", "ios_profile_current", "ios_profile_previous"):
    try:
        path, mode, secret, _v = pdgtx.resolve_target(t)
        acts = pdgtx.actions_for_targets([t])
        ok("pdgtx 目标 %s → %s(mode %o, 动作 %r)" % (t, path, mode, list(acts)))
    except Exception as e:  # noqa: BLE001
        bad("pdgtx 没有目标 %s: %s" % (t, e))

print()
print("══ 六、CA A→B→C 之后的恢复 ══")
b = Box()
b.gen(ca=CA_A)                              # rev1 CA=A
b.gen(host="dot.v2.example", ca=CA_B)       # rev2 CA=B, previous=rev1
keep = {"meta": open(b.meta, "rb").read(),
        "cur": open(b.cur(), "rb").read(),
        "prev": open(b.prev(), "rb").read()}
b.gen(host="dot.v3.example", ca=CA_C)       # rev3 CA=C, previous=rev2
# 用"只恢复 metadata"模拟修复前的备份行为, 看它会不会被检出
with open(b.meta, "wb") as f:
    f.write(keep["meta"])
st_c, d_c = health(b, "current")
st_p, d_p = health(b, "previous")
if st_c not in (None, "healthy") and st_p not in (None, "healthy"):
    ok("只恢复 metadata → current(%s)与 previous(%s)都被判为不一致" % (st_c, st_p))
elif st_c is None:
    bad(d_c)
else:
    bad("只恢复 metadata 却判成健康: current=%s previous=%s" % (st_c, st_p))

# 完整恢复(三件一起回去)之后必须逐字节相等, 且 CA 指纹对得上
with open(b.cur(), "wb") as f:
    f.write(keep["cur"])
with open(b.prev(), "wb") as f:
    f.write(keep["prev"])
m = b.read_meta()
st_c, _ = health(b, "current")
st_p, _ = health(b, "previous")
if st_c == "healthy" and st_p == "healthy":
    ok("三件一起恢复 → 两份产物都健康")
else:
    bad("完整恢复后仍不健康: current=%s previous=%s" % (st_c, st_p))
if hashlib.sha256(keep["cur"]).hexdigest() == m["current"]["sha256"] \
        and m["current"]["inputs"]["wloc_ca_sha256"] == hashlib.sha256(CA_B).hexdigest() \
        and m["previous"]["inputs"]["wloc_ca_sha256"] == hashlib.sha256(CA_A).hexdigest():
    ok("恢复回来的是 rev2(CA=B)+ rev1(CA=A), 指纹逐个对得上")
else:
    bad("恢复后的版本/指纹不对")
try:
    pc = plistlib.loads(keep["cur"])
    pp = plistlib.loads(keep["prev"])
    ca_c = [x for x in pc["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
    ca_p = [x for x in pp["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
    if ca_c and ca_c[0]["PayloadContent"] == CA_B and ca_p and ca_p[0]["PayloadContent"] == CA_A:
        ok("产物里嵌的确实分别是 CA B 与 CA A 的 DER 原文")
    else:
        bad("产物里的 CA 不对")
except Exception as e:  # noqa: BLE001
    bad("解析恢复出来的产物失败: %s" % e)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

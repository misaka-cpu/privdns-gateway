#!/usr/bin/env python3
"""iOS 描述文件受管生命周期 —— 行为验证。

判据全部是"真的跑一遍再看盘上/返回值是什么", 不看源码。每个沙箱是独立的 FSROOT, 元数据、
产物、锁文件都在里面, 跑完即删 —— 不碰宿主机的 /etc 与 /var/lib。
"""
import hashlib
import json
import os
import plistlib
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
BOXES = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


class Box:
    """一个隔离沙箱: 自己的 FSROOT + 自己的锁文件 + 干净导入的 iosstate。"""

    def __init__(self):
        self.root = tmpguard.mkdtemp(prefix="iosstate-")
        BOXES.append(self.root)
        os.makedirs(self.root + "/etc/privdns-gateway", exist_ok=True)
        os.makedirs(self.root + "/run", exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = self.root
        os.environ["PDG_LOCKFILE"] = self.root + "/run/privdns-gateway.lock"
        for m in ("iosstate", "iosprofile", "pdgtx"):
            sys.modules.pop(m, None)
        sys.path.insert(0, BOTDIR)
        import iosstate
        self.s = iosstate
        self.meta = self.root + "/etc/privdns-gateway/ios-profile.json"
        self.art = self.root + "/var/lib/privdns-gateway/ios-profile"

    def gen(self, host="dot.example.com", ip="203.0.113.10", ssids=(),
            legacy=False, template=TMPL):
        # WLOC 退役: 生成路径不再有 ca / wloc 这两维(描述文件不再携带任何根证书)。
        return self.s.generate(host, ip, ssids, template,
                               self.meta, self.art, True, legacy)

    def read_meta(self):
        with open(self.meta, encoding="utf-8") as f:
            return json.load(f)


def expect_error(fn, want, label, exc=None):
    try:
        fn()
    except Exception as e:  # noqa: BLE001
        if exc and not isinstance(e, exc):
            bad("%s 抛的是 %s: %s" % (label, type(e).__name__, e))
            return
        if want in str(e):
            ok("%s → 拒绝: %s" % (label, str(e)[:70]))
        else:
            bad("%s 拒绝了但理由不对: %s" % (label, e))
        return
    bad("%s 竟然通过了" % label)


CA_DIR = tmpguard.mkdtemp(prefix="iosstate-ca-")
BOXES.append(CA_DIR)
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", CA_DIR + "/ca.key", "-out", CA_DIR + "/ca.crt", "-days", "1",
                "-subj", "/CN=PDG Test CA"], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402
CA_DER = iosprofile.ca_der_from_pem(open(CA_DIR + "/ca.crt", encoding="utf-8").read())

# ── 1. 稳定身份 ────────────────────────────────────────────────────────────
b = Box()
m1, lv1, why1, d1, ch1 = b.gen()
if ch1 and m1["current"]["revision"] == 1:
    ok("首次生成: revision=1")
else:
    bad("首次生成不对: changed=%s rev=%r" % (ch1, m1["current"].get("revision")))

p1 = plistlib.loads(d1)
m2, lv2, why2, d2, ch2 = b.gen()
p2 = plistlib.loads(d2)
if d1 == d2 and not ch2:
    ok("同样配置再生成一次: 逐字节相同, 且**没有**产生新版本")
else:
    bad("重复生成产生了变化: changed=%s 字节相同=%s" % (ch2, d1 == d2))
if p1["PayloadUUID"] == p2["PayloadUUID"] and p1["PayloadIdentifier"] == p2["PayloadIdentifier"]:
    ok("身份稳定: PayloadUUID / PayloadIdentifier 两次一致(iOS 视为同一份文件)")
else:
    bad("身份仍在漂移")
if lv2 == b.s.NONE:
    ok("判定为「%s」" % b.s.LEVEL_LABEL[lv2])
else:
    bad("配置没变却判成 %s: %s" % (lv2, why2))

inst = b.read_meta()["instance_id"]
ids = b.s.derive_ids(inst)
if (p1["PayloadUUID"] == ids["root"]
        and p1["PayloadContent"][0]["PayloadUUID"] == ids["dns"]
        and ids["root"] != ids["dns"]):
    ok("各 payload 的 UUID 都由 instance_id 派生, 且彼此不同")
else:
    bad("派生身份对不上")

# 不同网关 ⇒ 不同身份(否则两台网关的描述文件会互相顶掉)
b2 = Box()
b2.gen()
if b2.read_meta()["instance_id"] != inst:
    ok("另一台网关得到不同的 instance_id(两份描述文件不会互相替换)")
else:
    bad("两台网关拿到了同一个身份")

# 身份不从会变的字段推导
b3 = Box()
b3.gen(host="dot.other.example", ip="198.51.100.7")
if b3.s.derive_ids(b3.read_meta()["instance_id"]) != ids:
    ok("身份与 DoT 域名 / IP 无关(换了域名和 IP 也不共用身份)")
else:
    bad("身份是从域名/IP 推导出来的")

# PayloadVersion 恒为 1
if p1["PayloadVersion"] == 1 and p1["PayloadContent"][0]["PayloadVersion"] == 1:
    ok("PayloadVersion 恒为 Apple 规定的 1(业务修订号是独立的 revision)")
else:
    bad("PayloadVersion 被拿去当版本号了")

# ── 2. 三档判定 ────────────────────────────────────────────────────────────
cases = [
    ("必须更新: DoT 主机名", dict(host="dot.new.example"), "required", "DoT 主机名"),
    ("必须更新: 网关地址", dict(ip="198.51.100.9"), "required", "网关地址"),
    ("建议更新: 强制直连 Wi-Fi", dict(ssids=("Home",)), "recommended", "强制直连 Wi-Fi"),
    # ("必须更新: 启用 WLOC", …) 随 WLOC 退役一并去掉 —— 那个开关不存在了。
]
for label, kw, want_lv, want_field in cases:
    bx = Box()
    bx.gen()
    meta, lv, why, data, ch = bx.gen(**kw)
    if lv == want_lv and any(want_field in r for r in why):
        ok("%s → 判定 %s(%s)" % (label, bx.s.LEVEL_LABEL[lv], why[0]))
    else:
        bad("%s → 判成 %s: %s" % (label, lv, why))

# 改探测地址属于必须更新: server_addresses 变了会连带 probe_url 变
bx = Box()
bx.gen()
meta, lv, why, data, ch = bx.gen(ssids=("B", "A"))
meta2, lv2, why2, data2, ch2 = bx.gen(ssids=("A", "B"))
if not ch2 and lv2 == bx.s.NONE and data == data2:
    ok("同一组 SSID 顺序不同 → 无需更新, 不产生新 revision")
else:
    bad("SSID 顺序变化被当成了配置变化: changed=%s lv=%s" % (ch2, lv2))

# 这里原本验"换了根 CA → 必须更新, 且元数据里只有指纹"。WLOC 退役后描述文件不再携带根
# 证书, 这个场景不存在了。换成盯住退役这一侧: **任何**一次生成都产不出根证书那一格 ——
# 这比"换了要提示"更强, 因为它管住的是全部路径而不是某一次变化。
bx = Box()
meta, lv, why, data, ch = bx.gen()
_pl = plistlib.loads(data)
if not [x for x in _pl["PayloadContent"]
        if x.get("PayloadType") == "com.apple.security.root"] \
        and "wloc_ca_sha256" not in meta["current"]["inputs"] \
        and "wloc_enabled" not in meta["current"]["inputs"]:
    ok("生成出来的产物里没有根证书那一格, 记录里也没有 WLOC 那两个字段")
else:
    bad("产物里仍有根证书那一格, 或记录里仍有 WLOC 字段: %s %s" % (lv, why))
raw_meta = open(bx.meta, encoding="utf-8").read()
# 原判据是"元数据里只有 CA 指纹, 没有证书正文"。指纹那一维已随退役去掉 —— 剩下的这一半
# (证书正文与私钥都不许进元数据)仍然要守: 元数据是会被备份、被贴进工单的东西。
if "BEGIN CERTIFICATE" not in raw_meta and "PRIVATE" not in raw_meta \
        and "wloc" not in raw_meta:
    ok("元数据里没有证书正文、没有私钥, 也没有任何 WLOC 残留字段")
else:
    bad("元数据里出现了证书正文/私钥/WLOC 残留")

# ── 2b. SSID 是**配置**, 不是每次都要重报的参数 ────────────────────────────
# SSID 名单进了 digest, 就等于成了受管配置的一部分。那么"调用方没传"必须解释成"沿用",
# 不能解释成"用户要清空" —— 后者的下场是: 状态页永远挂着一条谁也没做过的「建议更新」,
# 而下一次普通生成会把用户配好的强制直连名单**悄悄抹掉**并推进一个版本。
bx = Box()
bx.gen()
bx.gen(ssids=("Home", "Office"))
rev_ssid = bx.read_meta()["current"]["revision"]
inputs_plain = bx.s.make_inputs("dot.example.com", "203.0.113.10", (), TMPL)
lv, why = bx.s.classify(bx.read_meta(), bx.s.effective_inputs(
    bx.read_meta(), "dot.example.com", "203.0.113.10", None, TMPL))
if lv == bx.s.NONE:
    ok("设过 SSID 之后, 不指定 SSID 的判定仍是「无需更新」(没有幻影提示)")
else:
    bad("冒出了谁也没做过的变化: %s %s" % (lv, why))
meta, lv, why, data, ch = bx.gen(ssids=None)
if not ch and meta["current"]["revision"] == rev_ssid \
        and meta["current"]["inputs"]["ssids"] == ["Home", "Office"]:
    ok("不指定 SSID 的再次生成 → 沿用记录里的名单, revision 不变")
else:
    bad("SSID 被悄悄清掉了: rev=%s ssids=%r changed=%s"
        % (meta["current"].get("revision"), meta["current"]["inputs"].get("ssids"), ch))
meta, lv, why, data, ch = bx.gen(ssids=())
if ch and meta["current"]["inputs"]["ssids"] == [] and lv == "recommended":
    ok("明确传空列表 → 确实清空, 判「建议更新」, revision 前进到 %d"
       % meta["current"]["revision"])
else:
    bad("明确清空没生效: ssids=%r lv=%s changed=%s"
        % (meta["current"]["inputs"].get("ssids"), lv, ch))

# ── 3. current / previous ─────────────────────────────────────────────────
bx = Box()
bx.gen()
first = bx.s.read_artifact("current", bx.art)
bx.gen(host="dot.v2.example")
meta = bx.read_meta()
if bx.s.read_artifact("previous", bx.art) == first and meta["previous"]["revision"] == 1:
    ok("产生新版本时旧 current 进入 previous(内容逐字节保留)")
else:
    bad("previous 没有正确保留")
if meta["current"]["revision"] == 2:
    ok("revision 递增到 2")
else:
    bad("revision 没递增: %r" % meta["current"].get("revision"))
bx.gen(host="dot.v2.example")
if bx.s.read_artifact("previous", bx.art) == first:
    ok("重复生成同一版本不会顶掉 previous")
else:
    bad("previous 被无谓地顶掉了")

d = bx.s.diff_fields(meta["previous"]["inputs"], meta["current"]["inputs"])
if [x[0] for x in d] == ["dot_host"] and d[0][1] == "required":
    ok("current↔previous 的差异是字段级的: %s: %r → %r" % (d[0][0], d[0][2], d[0][3]))
else:
    bad("差异输出不对: %r" % d)

# ── 4. 产物丢了 / 被改了 ──────────────────────────────────────────────────
bx = Box()
bx.gen()
rev = bx.read_meta()["current"]["revision"]
os.unlink(bx.s.art_path("current", bx.art))
meta, lv, why, data, ch = bx.gen()
if bx.s.read_artifact("current", bx.art) == data and meta["current"]["revision"] == rev:
    ok("产物文件被删 → 按记录**确定性重建**, revision 不变(不制造假的「要更新」)")
else:
    bad("重建后 revision 变了: %r" % meta["current"].get("revision"))

with open(bx.s.art_path("current", bx.art), "ab") as f:
    f.write(b"<!-- tampered -->")
inputs = bx.s.make_inputs("dot.example.com", "203.0.113.10", (), TMPL)
lv, why = bx.s.classify(bx.read_meta(), inputs)
# 产物坏了是**服务端**的事, 不是"手机该更新了"。配置变化等级必须一点都不受它影响 ——
# 两者混在一起时, 用户会去动手机, 而真正坏掉的服务端文件被一句温和提示盖了过去。
if lv == "none":
    ok("产物被改动过, 配置变化等级仍是「%s」(两件事互不污染)" % bx.s.LEVEL_LABEL[lv])
else:
    bad("产物损坏污染了配置变化等级: %s %s" % (lv, why))
st, detail = bx.s.artifact_health(bx.read_meta(), "current", bx.art)
if st == "state_mismatch":
    ok("同一时刻产物健康状态单独给出: %s(%s)" % (st, detail))
else:
    bad("产物健康状态不对: %s" % st)
fixed = bx.gen()
if bx.s.read_artifact("current", bx.art) == fixed[3] and \
        bx.read_meta()["current"]["revision"] == rev:
    ok("再生成一次即按记录复原产物, revision 仍然不变")
else:
    bad("复原失败或 revision 变了")

# ── 5. 迁移 ────────────────────────────────────────────────────────────────
bx = Box()
meta, lv, why, data, ch = bx.gen(legacy=True)
if meta["migration_pending"] and lv == "required" \
        and any("删掉手机上那份旧描述文件" in r for r in why):
    ok("老机器首次启用 → 必须更新, 且明确要求先手工删除旧描述文件")
else:
    bad("迁移提示不对: pending=%s lv=%s why=%s" % (meta.get("migration_pending"), lv, why))
if all(w not in " ".join(why) for w in ("已安装", "已是最新", "已替换", "已生效")):
    ok("迁移文案没有任何「设备上是什么状态」的断言")
else:
    bad("文案里出现了服务器无法知道的设备状态: %s" % why)

before_id = bx.read_meta()["instance_id"]
bx.s.ack_migration(bx.meta)
meta2 = bx.read_meta()
lv2, why2 = bx.s.classify(meta2, bx.s.make_inputs("dot.example.com", "203.0.113.10",
                                                  (), TMPL))
if not meta2["migration_pending"] and lv2 == "none" and meta2["instance_id"] == before_id:
    ok("用户确认已按说明处理 → 迁移提示关闭, 身份不变")
else:
    bad("确认迁移之后状态不对: %r" % meta2)

bx = Box()
meta, lv, why, data, ch = bx.gen(legacy=False)
if not meta["migration_pending"]:
    ok("全新机器不显示迁移提示")
else:
    bad("全新机器也在提示迁移")

# ── 6. 事务性 ─────────────────────────────────────────────────────────────
bx = Box()
bx.gen()
good_meta = open(bx.meta, "rb").read()
good_cur = bx.s.read_artifact("current", bx.art)

# 写元数据时炸 → 产物与元数据一起回到改动前
orig_write = bx.s.pdgtx.atomic_write
fired = []


def boom_once(path, data, **kw):
    """只在**第一次**写元数据时炸。回滚本身还要写盘, 一直炸就变成在测另一件事了。"""
    if path == bx.meta and not fired:
        fired.append(1)
        raise OSError(28, "No space left on device")
    return orig_write(path, data, **kw)


bx.s.pdgtx.atomic_write = boom_once
try:
    bx.gen(host="dot.boom.example")
    bad("写元数据失败却没有报错")
except Exception as e:  # noqa: BLE001
    if isinstance(e, OSError):
        ok("写元数据失败 → 整笔失败(%s)" % e.strerror)
    else:
        bad("抛的不是原始错误: %s" % type(e).__name__)
bx.s.pdgtx.atomic_write = orig_write
if open(bx.meta, "rb").read() == good_meta and bx.s.read_artifact("current", bx.art) == good_cur:
    ok("失败后元数据与产物都逐字节回到改动前(没有半成功)")
else:
    bad("留下了半成功状态")
if bx.read_meta()["current"]["inputs"]["dot_host"] == "dot.example.com":
    ok("失败之后记录里仍然是旧的那一版(revision 没有偷偷前进)")
else:
    bad("失败却改了记录")

# 回滚本身也失败 → 必须把两件事都说出来, 不许只报后一件
bx2 = Box()
bx2.gen()
orig2 = bx2.s.pdgtx.atomic_write


def always_boom(path, data, **kw):
    if path == bx2.meta:
        raise OSError(28, "No space left on device")
    return orig2(path, data, **kw)


bx2.s.pdgtx.atomic_write = always_boom
try:
    bx2.gen(host="dot.boom2.example")
    bad("写失败却没有报错")
except Exception as e:  # noqa: BLE001
    msg = str(e)
    if isinstance(e, bx2.s.StateError) and "回滚不完整" in msg and "原始错误" in msg:
        ok("回滚也失败时同时报出「回滚不完整」和原始错误")
    else:
        bad("回滚失败的报告不完整: %s: %s" % (type(e).__name__, msg))
bx2.s.pdgtx.atomic_write = orig2

# 锁被别人占着 → 拒绝, 且什么都不写
bx = Box()
bx.gen()
snap = (open(bx.meta, "rb").read(), bx.s.read_artifact("current", bx.art))
holder = subprocess.Popen(
    [sys.executable, "-c",
     "import fcntl,sys,time\n"
     "f=open(sys.argv[1],'w'); fcntl.flock(f, fcntl.LOCK_EX)\n"
     "sys.stdout.write('held\\n'); sys.stdout.flush(); time.sleep(30)\n",
     bx.root + "/run/privdns-gateway.lock"], stdout=subprocess.PIPE)
try:
    holder.stdout.readline()
    expect_error(lambda: bx.gen(host="dot.locked.example"), "已有配置操作正在执行",
                 "锁被别的操作占着", bx.s.StateError)
    if (open(bx.meta, "rb").read(), bx.s.read_artifact("current", bx.art)) == snap:
        ok("被锁拒绝时没有写入任何东西")
    else:
        bad("被锁拒绝了却还是改了盘上的文件")
finally:
    holder.kill()
    holder.wait()

# 锁文件根本打不开 → fail closed, 不是"没锁就继续写"
bx = Box()
bx.gen()
os.environ["PDG_LOCKFILE"] = bx.root + "/run/nodir/sub/x.lock"
os.makedirs(bx.root + "/run/nodir", exist_ok=True)
open(bx.root + "/run/nodir/sub", "w").close()      # 把父路径占成普通文件 → makedirs 失败
for m in ("iosstate", "pdgtx"):
    sys.modules.pop(m, None)
import iosstate as _fc  # noqa: E402
expect_error(lambda: _fc.generate("dot.x.example", "203.0.113.10", (), TMPL,
                                  bx.meta, bx.art, True, False),
             "锁文件不可用", "锁文件打不开", _fc.StateError)

# 崩溃残留的候选文件会被清掉, 且不会被当成第三个版本
bx = Box()
bx.gen()
open(os.path.join(bx.art, "current.mobileconfig.cand"), "w").write("junk")
msgs = bx.s.recover(bx.meta, bx.art)
if any("候选文件" in m for m in msgs) and \
        not os.path.exists(os.path.join(bx.art, "current.mobileconfig.cand")):
    ok("崩溃残留的候选文件被识别并清理: %s" % msgs[0])
else:
    bad("候选残留没被处理: %r" % msgs)

# ── 7. 元数据损坏 → fail closed, 绝不自动重建身份 ──────────────────────────
bx = Box()
bx.gen()
keep = bx.read_meta()["instance_id"]
open(bx.meta, "w").write("{ broken")
expect_error(lambda: bx.s.load(bx.meta), "不自动重建", "元数据损坏", bx.s.StateError)
expect_error(lambda: bx.gen(), "不自动重建", "元数据损坏时生成", bx.s.StateError)
if open(bx.meta, encoding="utf-8").read() == "{ broken":
    ok("元数据损坏时原文件原样保留(没有被「修好」成一个新身份)")
else:
    bad("损坏的元数据被覆盖了")

for broken, want in ((json.dumps({"schema": 99, "instance_id": keep}), "格式版本"),
                     (json.dumps({"schema": 1}), "没有身份标识"),
                     (json.dumps({"schema": 1, "instance_id": ""}), "没有身份标识"),
                     (json.dumps([1, 2]), "格式版本")):
    open(bx.meta, "w").write(broken)
    expect_error(lambda: bx.s.load(bx.meta), want, "元数据: %s" % want, bx.s.StateError)

# ── 8. 私钥绝不进产物 / 元数据 ────────────────────────────────────────────
# 原本这一节是"把私钥当 CA 传进生成器 → 被拒"。生成器已经**没有**传 CA 这条路了, 那一格
# 连同它的对象一起没了 —— 而这正是更强的形态: 拒绝依赖一道门, 没有入口则不依赖任何门。
# 保留的是另一半(它仍然成立, 而且是这一节真正要保证的事): 产物与元数据里不许出现私钥。
# "私钥冒充根证书"那道门本身仍被 test-ios-profile-backup-trust.py 用 schema 1 的样本逼着。
import inspect as _inspect
if "ca_der" not in _inspect.signature(iosprofile.render).parameters:
    ok("渲染器已经没有传根证书这条入口(不是靠一道门拦, 是根本进不来)")
else:
    bad("iosprofile.render 仍然接受 ca_der —— 传进来就生效的路还在")

bx = Box()
bx.gen()
blob = open(bx.s.art_path("current", bx.art), "rb").read() + open(bx.meta, "rb").read()
_pl2 = plistlib.loads(bx.s.read_artifact("current", bx.art))
if b"PRIVATE KEY" not in blob and not [
        x for x in _pl2["PayloadContent"]
        if x.get("PayloadType") == "com.apple.security.root"]:
    ok("产物与元数据里既没有私钥, 也没有根证书那一格")
else:
    bad("产物或元数据里出现私钥/根证书")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in BOXES:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

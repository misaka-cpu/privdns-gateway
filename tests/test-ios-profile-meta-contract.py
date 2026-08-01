#!/usr/bin/env python3
"""四个可信入口必须用**同一份**元数据契约, 而且校验过的字节就是发出去的字节。

两件事, 都属于"看起来已经收口、其实还差一截":

一、元数据契约分了三份, 各查各的一部分:
      · load()                 只查 schema、身份、时间和**单条** record;
      · _check_meta()          另外查了顶层精确字段、migration_pending 类型、
                               以及 current/previous 的关系;
      · strict_artifact_check() 只查被选中的那个槽位。
    于是"顶层多一个未知字段""缺 migration_pending""previous.revision == current.revision"
    这些样本, 恢复那边拒得干干净净, 本地却 load 成功、artifact_health 判 healthy、
    verified_artifact 照样把字节交出去。一份从恢复入口进不来的记录, 只要已经躺在盘上就
    全程畅通 —— 这正是前几轮反复要堵的那条缝, 只是这次露在元数据这一层。

二、verified_artifact() 校验的和返回的不是同一次读取:
      artifact_health() 打开文件读到字节 A、校验通过 → verified_artifact() **再打开一次**
      路径读到字节 B 并返回。两次打开之间把文件换掉, 发出去的就是没有被任何人看过的 B。
    这里用 os.replace 做确定性注入(已经打开的 fd 仍指向旧 inode), 不靠 sleep 抢时序。
"""
import builtins
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
SUB = "var/lib/privdns-gateway/ios-profile"
REL_META = "etc/privdns-gateway/ios-profile.json"
REL_CUR = SUB + "/current.mobileconfig"
REL_PREV = SUB + "/previous.mobileconfig"

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
    d = _tmp("iosmc-ca-")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    def __init__(self):
        self.root = _tmp("iosmc-")
        for d in ("etc/privdns-gateway", "run", "var/lib/privdns-gateway"):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = self.root
        os.environ["PDG_LOCKFILE"] = self.root + "/run/privdns-gateway.lock"
        for m in ("iosstate", "iosprofile", "pdgtx"):
            sys.modules.pop(m, None)
        sys.path.insert(0, BOTDIR)
        import iosstate
        self.s = iosstate
        self.meta = os.path.join(self.root, REL_META)
        self.art = os.path.join(self.root, SUB)

    def gen(self, host="dot.example.com", ca=b""):
        return self.s.generate(host, "203.0.113.10", (), ca, bool(ca), TMPL,
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
        out = {}
        for rel in (REL_META, REL_CUR, REL_PREV):
            v = self.rd(rel)
            if v is not None:
                out[rel] = v
        return out

    def write_meta(self, meta):
        raw = json.dumps(meta, ensure_ascii=False, indent=2,
                         sort_keys=True).encode("utf-8") + b"\n"
        with open(self.meta, "wb") as f:
            f.write(raw)
        return raw


sys.path.insert(0, BOTDIR)
import iosprofile as IP  # noqa: E402

CA_A = IP.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())


def fresh():
    """一台走到 rev2 的机器: 记录里有 current + previous, 盘上两份产物都在。

    两份都备齐是有意的 —— 否则 current/previous 关系那几条用例可能只是因为"文件缺失"
    才变红, 测不到关系判据本身。
    """
    b = Box()
    b.gen(ca=CA_A)
    b.gen(host="dot.v2.example", ca=CA_A)
    return b


BASE = fresh()
S = BASE.s

# 拒绝消息里绝不许出现的东西: 描述文件正文、证书 base64、私钥。
LEAK_PROBES = ("<?xml", "PayloadContent", "BEGIN CERTIFICATE", "PRIVATE KEY",
               "MIIB", "MIIC", "MIID")


def no_leak(label, *msgs):
    blob = "\n".join(m for m in msgs if m)
    hit = [w for w in LEAK_PROBES if w in blob]
    if hit:
        bad("%s: 错误信息里泄漏了内容(%s)" % (label, ", ".join(hit)))
        return False
    return True


def bad_sample(title, mutate, want_words, which="current"):
    """一份坏元数据必须在**四个**入口得到同一个结论。"""
    b = fresh()
    # 从**这台机器自己**的记录出发 —— 拿别的 box 的记录来改, 产物 sha 一开始就对不上,
    # 那样测出来的是"指纹不符", 不是想测的那条判据。
    meta = json.loads(b.rd(REL_META).decode("utf-8"))
    mutate(meta)
    raw = b.write_meta(meta)
    cur, prev = b.rd(REL_CUR), b.rd(REL_PREV)
    msgs = []

    # 1) 本地 load(): 面向用户的 StateError
    try:
        b.s.load(b.meta)
        bad("%s: load() 放行了坏记录" % title)
    except b.s.StateError as e:
        msgs.append(str(e))
    except Exception as e:  # noqa: BLE001
        bad("%s: load() 抛的是 %s 而不是 StateError" % (title, type(e).__name__))
        return

    # 2) 外部恢复: 拒绝, 且这是纯函数 —— 现网一个字节都不该动
    before = b.group()
    try:
        b.s.validate_restore_set(raw, cur, prev)
        bad("%s: validate_restore_set 放行了" % title)
        return
    except b.s.StateError as e:
        msgs.append(str(e))
    if b.group() != before:
        bad("%s: 校验过程动了现网文件" % title)
        return

    # 3) 健康检查: 不许 healthy, 也不许抛未处理异常
    try:
        st, detail = b.s.artifact_health(meta, which, b.art)
    except Exception as e:  # noqa: BLE001
        bad("%s: artifact_health 抛了未处理异常 %s" % (title, type(e).__name__))
        return
    msgs.append(detail)
    if st == "healthy":
        bad("%s: artifact_health 判成 healthy(%s)" % (title, detail[:70]))
        return

    # 4) 发送: 一个字节都不许交出去
    try:
        got = b.s.verified_artifact(meta, which, b.art)
        bad("%s: verified_artifact 交出了 %d 字节" % (title, len(got)))
        return
    except b.s.StateError as e:
        msgs.append(str(e))
    except Exception as e:  # noqa: BLE001
        bad("%s: verified_artifact 抛的是 %s" % (title, type(e).__name__))
        return

    blob = "\n".join(msgs)
    hit = [w for w in want_words if w in blob]
    if not hit:
        bad("%s: 四处都拒了, 但没点名是哪个字段/关系: %s" % (title, blob[:160]))
        return
    if not no_leak(title, *msgs):
        return
    ok("%s: load/恢复/健康(%s)/发送 四处一致拒绝, 命中「%s」" % (title, st, hit[0]))


def good_sample(title, mutate=None, which="current"):
    """正常元数据不许被误伤: 四处都要放行。"""
    b = fresh()
    meta = json.loads(b.rd(REL_META).decode("utf-8"))
    if mutate:
        mutate(meta)
    raw = b.write_meta(meta)
    cur, prev = b.rd(REL_CUR), b.rd(REL_PREV)
    try:
        b.s.load(b.meta)
        b.s.validate_restore_set(raw, cur, prev)
        st, detail = b.s.artifact_health(meta, which, b.art)
        data = b.s.verified_artifact(meta, which, b.art)
    except Exception as e:  # noqa: BLE001
        bad("%s: 正常元数据被挡住了: %s" % (title, str(e)[:140]))
        return
    want = cur if which == "current" else prev
    if st == "healthy" and data == want:
        ok("%s: 四处都放行, 交出来的就是盘上那一份" % title)
    else:
        bad("%s: 健康=%s 字节一致=%s" % (title, st, data == want))


print("══ 一、顶层字段集合与类型 ══")
bad_sample("顶层多了一个未知字段",
           lambda m: m.__setitem__("retired_at", "2026-01-01T00:00:00Z"),
           ["retired_at", "字段"])
bad_sample("顶层缺 migration_pending",
           lambda m: m.pop("migration_pending"),
           ["migration_pending", "字段"])
for v, label in (("yes", "字符串"), (1, "整数"), (None, "null")):
    bad_sample("migration_pending 是%s" % label,
               lambda m, v=v: m.__setitem__("migration_pending", v),
               ["migration_pending"])

print()
print("══ 二、current / previous 的关系 ══")
bad_sample("有 previous 却没有 current",
           lambda m: m.__setitem__("current", None),
           ["上一版", "当前版本", "previous", "current"])
bad_sample("previous.revision == current.revision",
           lambda m: m["previous"].__setitem__("revision", m["current"]["revision"]),
           ["revision", "上一版"])
bad_sample("previous.revision > current.revision",
           lambda m: m["previous"].__setitem__("revision",
                                               m["current"]["revision"] + 5),
           ["revision", "上一版"])

print()
print("══ 三、检查一个槽位时, 另一个槽位坏了也算整份记录坏了 ══")
bad_sample("查 current 时 previous 是字符串",
           lambda m: m.__setitem__("previous", "not-a-record"),
           ["previous", "记录"])
bad_sample("查 current 时 previous 缺字段",
           lambda m: m["previous"].pop("generated_at"),
           ["previous", "generated_at", "字段"])
bad_sample("查 current 时 previous 的 sha256 非法",
           lambda m: m["previous"].__setitem__("sha256", "zz"),
           ["previous", "sha256"])
bad_sample("查 previous 时 current 是非法记录",
           lambda m: m["current"].__setitem__("revision", "2"),
           ["current", "revision"], which="previous")

print()
print("══ 四、正常元数据不许误伤 ══")
good_sample("正常 current + previous")
good_sample("正常 current + previous(查 previous)", which="previous")
good_sample("migration_pending=True",
            lambda m: m.__setitem__("migration_pending", True))
good_sample("migration_pending=False",
            lambda m: m.__setitem__("migration_pending", False))


def _only_current(m):
    m["previous"] = None


b1 = Box()
b1.gen(ca=CA_A)                                  # 只有 current 的正常机器
raw1 = b1.rd(REL_META)
meta1 = json.loads(raw1.decode("utf-8"))
try:
    b1.s.load(b1.meta)
    b1.s.validate_restore_set(raw1, b1.rd(REL_CUR), None)
    st1, _d1 = b1.s.artifact_health(meta1, "current", b1.art)
    data1 = b1.s.verified_artifact(meta1, "current", b1.art)
    if st1 == "healthy" and data1 == b1.rd(REL_CUR):
        ok("正常 current-only 元数据: 四处都放行")
    else:
        bad("current-only 被误伤: 健康=%s" % st1)
except Exception as e:  # noqa: BLE001
    bad("current-only 被误伤: %s" % str(e)[:140])

print()
print("══ 五、校验的字节必须就是返回的字节 ══")
# 旧实现: artifact_health 打开读一次并校验, verified_artifact **再打开一次**返回。
# 这里在"第一次打开之后"立刻用 os.replace 把盘上的文件换掉 —— 已经打开的 fd 仍指向旧
# inode, 所以第一次读到的仍是好字节; 但第二次打开就会拿到换上去的那份。确定性, 不靠 sleep。
swap = fresh()
GOOD = swap.rd(REL_CUR)
other = Box()
other.gen(host="dot.evil.example", ca=CA_A)
EVIL = other.rd(REL_CUR)
if EVIL and EVIL != GOOD:
    ok("前提: 准备了一份与被校验字节不同的替换内容(%d vs %d 字节)" % (len(GOOD), len(EVIL)))
else:
    bad("替换样本准备失败, 这一节测不到东西")

TARGET = swap.p(REL_CUR)
_real_open = builtins.open
_real_os_open = os.open
_n = {"opens": 0, "swapped": False}


def _do_swap():
    """把路径换成另一份内容, 但**让旧 inode 完好地活着**。

    直接 os.replace 会让旧 inode 的 nlink 掉到 0, 于是"单次读取"的实现会在 fstat 那一步
    因为 nlink!=1 而拒绝 —— 那也是正确行为, 但它证明的是另一件事。这里先把旧文件改名挪走
    (nlink 仍是 1、已打开的 fd 照常读得到), 再把新内容放到路径上: 于是
      · 单次读取的实现: 从那个 fd 读到的仍是好字节, 校验通过, 交出来的就是它;
      · "先 health 再按路径重开"的实现: 第二次打开拿到的是换上去的那份。
    两者的差别只剩下"校验的是不是返回的", 正是这一节要测的。
    """
    os.rename(TARGET, TARGET + ".moved-away")
    with _real_open(TARGET, "wb") as f:
        f.write(EVIL)
    os.chmod(TARGET, 0o644)
    _n["swapped"] = True


def _hooked_open(file, *a, **kw):
    fh = _real_open(file, *a, **kw)
    if str(file) == TARGET:
        _n["opens"] += 1
        if _n["opens"] == 1:
            _do_swap()
    return fh


def _hooked_os_open(path, *a, **kw):
    fd = _real_os_open(path, *a, **kw)
    if str(path) == TARGET:
        _n["opens"] += 1
        if _n["opens"] == 1:
            _do_swap()
    return fd


meta_sw = json.loads(swap.rd(REL_META).decode("utf-8"))
builtins.open = _hooked_open
os.open = _hooked_os_open
try:
    try:
        got = swap.s.verified_artifact(meta_sw, "current", swap.art)
        outcome = ("BYTES", got)
    except swap.s.StateError as e:
        outcome = ("REJECT", str(e))
finally:
    builtins.open = _real_open
    os.open = _real_os_open

if not _n["swapped"]:
    bad("注入没生效: 校验期间没有替换到文件(opens=%d)" % _n["opens"])
elif outcome[0] == "BYTES" and outcome[1] == EVIL:
    bad("verified_artifact 交出了**没被校验过**的那一份字节 —— 校验和返回不是同一次读取"
        "(打开了 %d 次)" % _n["opens"])
elif outcome[0] == "BYTES" and outcome[1] == GOOD:
    ok("verified_artifact 交出的正是刚刚校验过的那份字节(全程只打开 %d 次)" % _n["opens"])
elif outcome[0] == "REJECT":
    ok("verified_artifact 发现文件在校验期间变了并拒绝(%s)" % outcome[1][:60])
else:
    bad("verified_artifact 交出了第三种字节: %r" % (outcome,))

# 正向: 正常路径下 current / previous 交出来的都必须与盘上逐字节一致
nb = fresh()
mnb = json.loads(nb.rd(REL_META).decode("utf-8"))
for which, rel in (("current", REL_CUR), ("previous", REL_PREV)):
    try:
        got = nb.s.verified_artifact(mnb, which, nb.art)
        if got == nb.rd(rel):
            ok("正常路径 %s: 交出来的与盘上逐字节一致(%d 字节)" % (which, len(got)))
        else:
            bad("正常路径 %s: 交出来的与盘上不一致" % which)
    except Exception as e:  # noqa: BLE001
        bad("正常路径 %s 被拒: %s" % (which, str(e)[:120]))

# 既有的磁盘层判据不许放宽
hb = fresh()
mhb = json.loads(hb.rd(REL_META).decode("utf-8"))
real = hb.p(REL_CUR) + ".real"
shutil.move(hb.p(REL_CUR), real)
os.symlink(real, hb.p(REL_CUR))
st, detail = hb.s.artifact_health(mhb, "current", hb.art)
if st == "corrupt" and "符号链接" in detail:
    ok("软链仍判 corrupt 并点名(单次读取没有放宽磁盘层判据)")
else:
    bad("软链没被挡住: %s %s" % (st, detail))
os.unlink(hb.p(REL_CUR))
os.link(real, hb.p(REL_CUR))
st, detail = hb.s.artifact_health(mhb, "current", hb.art)
if st == "corrupt" and "硬链接" in detail:
    ok("硬链接仍判 corrupt 并点名")
else:
    bad("硬链没被挡住: %s %s" % (st, detail))
os.unlink(hb.p(REL_CUR))
shutil.move(real, hb.p(REL_CUR))
os.chmod(hb.p(REL_CUR), 0o666)
st, detail = hb.s.artifact_health(mhb, "current", hb.art)
if st == "corrupt" and "写入" in detail:
    ok("组/其它可写仍判 corrupt 并点名")
else:
    bad("宽权限没被挡住: %s %s" % (st, detail))

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

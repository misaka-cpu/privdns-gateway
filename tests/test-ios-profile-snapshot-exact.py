#!/usr/bin/env python3
"""回滚到旧快照之后, iOS 产物目录必须**精确等于**快照那一刻, 不能留下孤儿。

快照落盘只做覆盖: 快照里有的写回去, 快照里没有的原样留在盘上。对绝大多数目标这是对的 ——
回滚不该顺手删掉用户后来加的东西。iOS 产物目录是例外, 因为那两份文件不是各自独立的配置,
而是与 ios-profile.json 里的记录**一一对应的一组**:

    rev1 时打快照(那时还没有 previous) → 生成 rev2(previous 出现) → 回滚到 rev1

记录回到了"没有上一版", 盘上却躺着一份 previous.mobileconfig。它属于一个已经不存在的版本,
没有任何记录能解释它是什么; 而备份会把它一起打包, 下一次恢复就把这份自相矛盾的东西搬到
另一台机器上。界面全程不会报任何错。

对账**只对这一棵子树**做。不放大到整个 /var/lib —— 那里还有事务记录、救援运行态、备份包,
它们跟快照没关系, 删它们是另一回事。
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

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
PDG = os.path.join(BOTDIR, "pdg.sh")
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
SUB = "var/lib/privdns-gateway/ios-profile"

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
    d = tempfile.mkdtemp(prefix="iossnap-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="iossnap-")
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
        self.art = os.path.join(self.root, SUB)
        with open(self.root + "/etc/sing-box/config.json", "w") as f:
            json.dump({"outbounds": [], "route": {"rules": []}}, f)
        with open(self.root + "/etc/mosdns/config.yaml", "w") as f:
            f.write("log:\n  level: info\n")

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


CA_A = None
sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402

CA_A = iosprofile.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())
CA_B = iosprofile.ca_der_from_pem(open(mkca("PDG CA B"), encoding="utf-8").read())

# 生产函数原样抽出来跑(与 test-core-swap.sh 同一手法): 测的是 pdg.sh 里那一份, 不是复制品。
FNS = ("_pdg_mktemp_dir", "_pdg_reconcile_ios_profile", "_pdg_apply_snapshot_tree")


def _harness():
    out = []
    for fn in FNS:
        p = subprocess.run(["sed", "-n", "/^%s(){/,/^}/p" % fn, PDG],
                           capture_output=True, text=True)
        out.append(p.stdout)
    return "\n".join(out)


HARNESS = _harness()
for fn in ("_pdg_mktemp_dir", "_pdg_apply_snapshot_tree"):
    if "%s(){" % fn not in HARNESS:
        bad("抽不到生产函数 %s —— 这个测试就没有在测生产代码" % fn)


def snapshot(box):
    """按 cmd_snapshot 的形态打一份快照(相对 / 打包, 只带存在的候选)。"""
    d = tempfile.mkdtemp(prefix="iossnap-snap-")
    TMPS.append(d)
    items = [x for x in ("etc/privdns-gateway", SUB) if os.path.exists(box.p(x))]
    subprocess.run(["tar", "czf", d + "/snap.tar.gz", "-C", box.root] + items,
                   check=True, capture_output=True)
    return d + "/snap.tar.gz"


def rollback(box, snap, extra=""):
    """按 cmd_rollback 的做法回滚: 解到临时树 → 取成员清单 → 调生产的落盘函数。"""
    tmp = tempfile.mkdtemp(prefix="iossnap-tree-")
    TMPS.append(tmp)
    tree = os.path.join(tmp, "tree")
    os.makedirs(tree)
    members = os.path.join(tmp, "members")
    with open(members, "w") as f:
        f.write(subprocess.run(["tar", "tzf", snap], capture_output=True,
                               text=True).stdout)
    subprocess.run(["tar", "xzf", snap, "-C", tree], check=True, capture_output=True)
    script = (HARNESS + "\n" + extra + "\n"
              + '_pdg_apply_snapshot_tree "$1" "$2" "$3"\n')
    return subprocess.run(["bash", "-c", script, "x", tree, members, box.root],
                          capture_output=True, text=True)


def listing(box, rel=SUB):
    d = box.p(rel)
    out = []
    for base, _dirs, files in os.walk(d):
        for f in files:
            out.append(os.path.relpath(os.path.join(base, f), d))
    return sorted(out)


print("══ 一、rev1 快照 → rev2 → 回滚 rev1: 目录必须精确回到 rev1 ══")
b = Box()
b.gen(ca=CA_A)                                   # rev1: 只有 current
snap1 = snapshot(b)
want_meta, want_cur = b.rd("etc/privdns-gateway/ios-profile.json"), b.rd(SUB + "/current.mobileconfig")
if not os.path.exists(b.p(SUB + "/previous.mobileconfig")):
    ok("rev1 那一刻盘上只有 current(快照里也就没有 previous)")
else:
    bad("rev1 就已经有 previous 了, 这条用例的前提不成立")
b.gen(host="dot.v2.example", ca=CA_B)            # rev2: previous 出现
if os.path.exists(b.p(SUB + "/previous.mobileconfig")):
    ok("rev2 之后盘上出现了 previous")
else:
    bad("rev2 没有产生 previous, 前提不成立")

r = rollback(b, snap1)
if r.returncode == 0:
    ok("回滚落盘返回成功")
else:
    bad("回滚落盘失败: rc=%d %s" % (r.returncode, (r.stderr or "")[-200:]))
if b.rd("etc/privdns-gateway/ios-profile.json") == want_meta \
        and b.rd(SUB + "/current.mobileconfig") == want_cur:
    ok("记录与 current 逐字节回到 rev1")
else:
    bad("记录/current 没回到 rev1")
if listing(b) == ["current.mobileconfig"]:
    ok("产物目录精确等于快照: 只有 current, 没有留下孤儿 previous")
else:
    bad("产物目录多出了快照里没有的东西: %r" % listing(b))
meta = json.load(open(b.meta, encoding="utf-8"))
if meta.get("previous") is None:
    ok("记录回到「没有上一版」")
else:
    bad("记录里还挂着上一版: %r" % meta.get("previous"))
st, detail = b.s.artifact_health(meta, "current", b.art)
if st == "healthy":
    ok("回滚后 current 健康(%s)" % detail)
else:
    bad("回滚后 current 不健康: %s %s" % (st, detail))

print()
print("══ 二、备份按记录决定打包内容, 不看盘上有什么 ══")


def backup_names(box, expect_ok=True):
    code = r'''
import io, json, os, sys, tarfile, traceback
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
# 沙箱化: 生产常量是绝对路径, 整体搬到沙箱 root 下(与 test-ios-profile-persist.py 同一手法)
root = %(root)r
m.BACKUP_FILES = [root + x for x in m.BACKUP_FILES]
m.SB = root + m.SB
m.RS_DIR = root + "/nonexistent-rs"
m.IOS_META = root + m.IOS_META
m.IOS_ART_DIR = root + m.IOS_ART_DIR
m.IOS_CURRENT = root + m.IOS_CURRENT
m.IOS_PREVIOUS = root + m.IOS_PREVIOUS
try:
    blob = m.backup_blob()
except Exception as e:
    print("RESULT " + json.dumps({"ok": False, "err": str(e)}, ensure_ascii=False)); raise SystemExit(0)
names = [x.name for x in tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") if x.isfile()]
print("RESULT " + json.dumps({"ok": True, "names": names}, ensure_ascii=False))
''' % {"botdir": BOTDIR, "bot": os.path.join(BOTDIR, "pdg-bot.py"), "root": box.root}
    p = subprocess.run([sys.executable, "-c", code], capture_output=True,
                       text=True, timeout=600)
    for line in reversed((p.stdout or "").splitlines()):
        if line.startswith("RESULT "):
            r = json.loads(line[7:])
            # 成员名带着沙箱 root 前缀(生产常量是绝对路径), 归一成生产形态再比
            pre = box.root.lstrip("/")
            r["names"] = [n[len(pre):].lstrip("/") for n in r.get("names") or []]
            return r
    return {"ok": False, "err": "[runner crashed] " + (p.stderr or "")[-400:]}


res = backup_names(b)
ios = [n for n in res.get("names", []) if "ios-profile" in n]
if res["ok"] and sorted(ios) == sorted(["etc/privdns-gateway/ios-profile.json",
                                        SUB + "/current.mobileconfig"]):
    ok("回滚之后备份只带记录 + current: %r" % sorted(ios))
else:
    bad("备份内容不对: ok=%s %r" % (res["ok"], res.get("names") or res.get("err")))

# 人为造一个孤儿(旧版本回滚就会留下这个): 记录里没有 previous, 盘上有一份
with open(b.p(SUB + "/previous.mobileconfig"), "wb") as f:
    f.write(want_cur)
res = backup_names(b)
if not res["ok"] and ("上一版" in res.get("err", "") or "孤儿" in res.get("err", "")):
    ok("盘上有记录之外的 previous → 备份 fail-closed 并说清是哪种状态: %s" % res["err"][:90])
elif res["ok"] and any(n.endswith("previous.mobileconfig") for n in res.get("names", [])):
    bad("孤儿被静默打进了备份包 —— 恢复到别的机器上就是一份自相矛盾的记录")
else:
    bad("既没打包也没说清楚: ok=%s %r" % (res["ok"], res.get("err") or res.get("names")))
os.unlink(b.p(SUB + "/previous.mobileconfig"))

# 记录说有 current, 但盘上那份被改坏了 → 不许当成"备份成功"
cur_backup = b.rd(SUB + "/current.mobileconfig")
with open(b.p(SUB + "/current.mobileconfig"), "ab") as f:
    f.write(b"\n<!-- tampered -->\n")
res = backup_names(b)
if not res["ok"] and ("当前版本" in res.get("err", "") or "sha256" in res.get("err", "")):
    ok("current 与记录对不上 → 备份 fail-closed: %s" % res["err"][:90])
else:
    bad("坏掉的 current 仍被打进备份: ok=%s %r" % (res["ok"], res.get("err") or res.get("names")))
with open(b.p(SUB + "/current.mobileconfig"), "wb") as f:
    f.write(cur_backup)
res = backup_names(b)
if res["ok"]:
    ok("修回去之后备份恢复正常(fail-closed 不是永久拒绝)")
else:
    bad("修回去了还是拒: %s" % res.get("err"))

print()
print("══ 三、对账只碰这一棵子树 ══")
b2 = Box()
b2.gen(ca=CA_A)
snap2 = snapshot(b2)
b2.gen(host="dot.v2.example", ca=CA_B)
# 快照之外的东西: 事务记录、救援运行态、备份包、以及 /etc 下用户后加的文件
others = {"var/lib/privdns-gateway/tx/0001/state.json": b"{}",
          "var/lib/privdns-gateway/rescue/state": b"on",
          "var/lib/privdns-gateway/backups/keep.tar.gz": b"zzz",
          "etc/privdns-gateway/mitm.json": b'{"a":{"enabled":true}}'}
for rel, data in others.items():
    os.makedirs(os.path.dirname(b2.p(rel)), exist_ok=True)
    with open(b2.p(rel), "wb") as f:
        f.write(data)
# 产物目录里另外塞一个快照里没有的文件: 它**属于**这棵子树, 必须被清掉
with open(b2.p(SUB + "/stray.mobileconfig"), "wb") as f:
    f.write(b"stray\n")
r = rollback(b2, snap2)
if r.returncode == 0:
    ok("回滚落盘返回成功")
else:
    bad("回滚落盘失败: %s" % (r.stderr or "")[-200:])
if listing(b2) == ["current.mobileconfig"]:
    ok("子树内快照没有的文件(previous + stray)都被清掉了")
else:
    bad("子树没有精确对齐: %r" % listing(b2))
kept = {rel: b2.rd(rel) for rel in others}
if kept == others:
    ok("子树之外一个字节没动: tx / 救援运行态 / 备份包 / /etc 下的文件都还在")
else:
    bad("动到了子树以外的东西: %r" % [k for k, v in kept.items() if v != others[k]])

print()
print("══ 四、快照里根本没有这棵子树时不许乱删 ══")
b3 = Box()
b3.gen(ca=CA_A)
d = tempfile.mkdtemp(prefix="iossnap-old-")
TMPS.append(d)
subprocess.run(["tar", "czf", d + "/snap.tar.gz", "-C", b3.root, "etc/privdns-gateway"],
               check=True, capture_output=True)      # 5.4 之前的快照: 只有 etc
before = listing(b3)
r = rollback(b3, d + "/snap.tar.gz")
if r.returncode == 0 and listing(b3) == before:
    ok("旧快照(不含 ios-profile)不对这棵子树发表意见, 产物原样保留: %r" % before)
else:
    bad("旧快照把产物删了或落盘失败: rc=%d %r" % (r.returncode, listing(b3)))

print()
print("══ 五、删不掉就整体退回去, 不留「删了一半」 ══")
b4 = Box()
b4.gen(ca=CA_A)
snap4 = snapshot(b4)
b4.gen(host="dot.v2.example", ca=CA_B)
with open(b4.p(SUB + "/stray.mobileconfig"), "wb") as f:
    f.write(b"stray\n")
prev_before = b4.rd(SUB + "/previous.mobileconfig")
stray_before = b4.rd(SUB + "/stray.mobileconfig")
st_before = {rel: os.stat(b4.p(rel)).st_mode & 0o7777
             for rel in (SUB + "/previous.mobileconfig", SUB + "/stray.mobileconfig")}
# 注入: 第二次 rm 失败(第一份已经删掉了) —— 必须把删掉的那份放回去并报失败
fault = r'''
_pdg_rm_calls=0
rm(){
  case "$*" in
    *ios-profile*)
      _pdg_rm_calls=$((_pdg_rm_calls+1))
      if [[ $_pdg_rm_calls -ge 2 ]]; then return 1; fi;;
  esac
  command rm "$@"
}
'''
r = rollback(b4, snap4, fault)
if r.returncode != 0:
    ok("删除失败 → 落盘整体报失败(rc=%d)" % r.returncode)
else:
    bad("删除失败却报成功")
if b4.rd(SUB + "/previous.mobileconfig") == prev_before \
        and b4.rd(SUB + "/stray.mobileconfig") == stray_before:
    ok("被删掉的那些逐字节放回去了(没有留下删了一半的目录)")
else:
    bad("留下了删一半的状态: %r" % listing(b4))
st_after = {}
for rel in st_before:
    try:
        st_after[rel] = os.stat(b4.p(rel)).st_mode & 0o7777
    except OSError:
        st_after[rel] = None
if st_after == st_before:
    ok("放回去的文件权限位不变: %r" % st_after)
else:
    bad("权限没还原: %r → %r" % (st_before, st_after))

print()
print("══ 六、rm 谎报成功也不许当成删掉了 ══")
b5 = Box()
b5.gen(ca=CA_A)
snap5 = snapshot(b5)
b5.gen(host="dot.v2.example", ca=CA_B)
prev5 = b5.rd(SUB + "/previous.mobileconfig")
# 注入: rm 对这棵子树里的文件一律返回成功却什么都不删(只读挂载、被别的进程持有、
# 被 LSM 拦下都长这样)。落盘不许因为"rm 说成功了"就认为目录已经对齐。
liar = r'''
rm(){
  case "$*" in
    *ios-profile/*) return 0;;
  esac
  command rm "$@"
}
'''
r = rollback(b5, snap5, liar)
if r.returncode != 0:
    ok("rm 报了成功但文件还在 → 落盘整体报失败(rc=%d)" % r.returncode)
else:
    bad("信了 rm 的话: 目录里还留着 %r 却报成功" % listing(b5))
if b5.rd(SUB + "/previous.mobileconfig") == prev5:
    ok("那份没删成的文件原样还在(没有被「当成删过」而丢失记录)")
else:
    bad("文件内容被动过: %r" % b5.rd(SUB + "/previous.mobileconfig"))

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

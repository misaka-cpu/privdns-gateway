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
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

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
    d = tmpguard.mkdtemp(prefix="iossnap-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    def __init__(self):
        self.root = tmpguard.mkdtemp(prefix="iossnap-")
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
# iOS 那一批按 `_pdg_ios_*` 前缀自动抽 —— 写死名字的话, 生产多加一个 helper 就变成
# command not found 的假红(这一轮已经踩过两次)。
FNS = ("_pdg_mktemp_dir", "_pdg_apply_snapshot_tree")
IOS_FNS = subprocess.run(
    ["bash", "-c", "grep -oE '^_pdg_ios_[a-z_]+\\(\\)' %s | tr -d '()'" % PDG],
    capture_output=True, text=True).stdout.split()
# 这两条相对路径也是生产定义的一部分, 一并抽 —— 少抽一个就是 "unbound variable" 的假红。
CONSTS = ("_PDG_IOS_STATE_REL", "_PDG_IOS_ART_REL")


def _harness():
    out = []
    for c in CONSTS:
        p = subprocess.run(["sed", "-n", "/^%s=/p" % c, PDG], capture_output=True, text=True)
        out.append(p.stdout)
    for fn in list(FNS) + IOS_FNS:
        p = subprocess.run(["sed", "-n", "/^%s(){/,/^}/p" % fn, PDG],
                           capture_output=True, text=True)
        out.append(p.stdout)
    return "\n".join(out)


HARNESS = _harness()
for fn in list(FNS) + ["_pdg_ios_capture", "_pdg_ios_rollback", "_pdg_ios_reconcile",
                       "_pdg_ios_group_in_members", "_pdg_ios_verify_tree"]:
    if "%s(){" % fn not in HARNESS:
        bad("抽不到生产函数 %s —— 这个测试就没有在测生产代码" % fn)
for c in CONSTS:
    if "%s=" % c not in HARNESS:
        bad("抽不到生产常量 %s" % c)


def snapshot(box):
    """按 cmd_snapshot 的形态打一份快照(相对 / 打包, 只带存在的候选)。"""
    d = tmpguard.mkdtemp(prefix="iossnap-snap-")
    TMPS.append(d)
    items = [x for x in ("etc/privdns-gateway", SUB) if os.path.exists(box.p(x))]
    subprocess.run(["tar", "czf", d + "/snap.tar.gz", "-C", box.root] + items,
                   check=True, capture_output=True)
    return d + "/snap.tar.gz"


def rollback(box, snap, extra=""):
    """按 cmd_rollback 的做法回滚: 解到临时树 → 取成员清单 → 调生产的落盘函数。"""
    tmp = tmpguard.mkdtemp(prefix="iossnap-tree-")
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
# 真正的 5.4 之前快照: 那时 ios-profile.json 这个文件还不存在, 产物目录也不存在。
old = tmpguard.mkdtemp(prefix="iossnap-old-")
TMPS.append(old)
os.makedirs(old + "/etc/privdns-gateway", exist_ok=True)
with open(old + "/etc/privdns-gateway/platform", "w") as f:
    f.write("ios\n")
subprocess.run(["tar", "czf", old + "/snap.tar.gz", "-C", old, "etc/privdns-gateway"],
               check=True, capture_output=True)
before = listing(b3)
meta_before = b3.rd("etc/privdns-gateway/ios-profile.json")
r = rollback(b3, old + "/snap.tar.gz")
if r.returncode == 0 and listing(b3) == before \
        and b3.rd("etc/privdns-gateway/ios-profile.json") == meta_before:
    ok("旧快照(整组成员一个都没有)不对这一组发表意见, 记录与产物原样保留: %r" % before)
else:
    bad("旧快照把这一组动了或落盘失败: rc=%d %r" % (r.returncode, listing(b3)))

# 反过来: 快照里有记录、没有产物 —— 那是"当时就没有产物", 整组替换就该把产物清掉,
# 而不是留下一份没有记录能解释的文件。这是有意选的语义, 钉在这里。
b3b = Box()
b3b.gen(ca=CA_A)
half = tmpguard.mkdtemp(prefix="iossnap-half-")
TMPS.append(half)
os.makedirs(half + "/etc/privdns-gateway", exist_ok=True)
shutil.copy2(b3b.meta, half + "/etc/privdns-gateway/ios-profile.json")
subprocess.run(["tar", "czf", half + "/snap.tar.gz", "-C", half,
                "etc/privdns-gateway/ios-profile.json"], check=True, capture_output=True)
r = rollback(b3b, half + "/snap.tar.gz")
if r.returncode == 0 and listing(b3b) == []:
    ok("快照里有记录、没有产物 → 整组替换, 产物被清空(不留没人解释得了的文件)")
else:
    bad("记录/产物半组快照处理不对: rc=%d %r" % (r.returncode, listing(b3b)))

print()
print("══ 五、任何一步失败, 整组(记录 + 产物子树)都要精确回到操作前 ══")
# 这一节盯的是**整组**, 不只是孤儿文件。tar 是先覆盖再对账的: 等对账失败时,
# ios-profile.json 和 current.mobileconfig 早就被旧快照盖掉了。只把删掉的孤儿放回去
# 等于留下"记录是旧快照的、产物是新旧混着的"这种半回滚状态 —— 比不回滚更难查。
STATE_REL = "etc/privdns-gateway/ios-profile.json"


def group_state(box):
    """这一组的完整状态: 记录 + 整棵产物子树, 内容 + 存在性 + mode + uid + gid。"""
    out = {}
    rels = [STATE_REL]
    art = box.p(SUB)
    for base, _d, files in os.walk(art):
        for f in files:
            rels.append(SUB + "/" + os.path.relpath(os.path.join(base, f), art))
    for rel in sorted(set(rels)):
        f = box.p(rel)
        try:
            st = os.stat(f)
            with open(f, "rb") as fh:
                out[rel] = (fh.read(), st.st_mode & 0o7777, st.st_uid, st.st_gid)
        except OSError:
            out[rel] = None
    return out


def diff_state(before, after):
    keys = sorted(set(before) | set(after))
    return [k for k in keys if before.get(k) != after.get(k)]


def fault_case(title, fault, expect_rollback=True, expect_words=()):
    """造 rev1 快照 → 走到 rev2 + 一个孤儿 → 注入故障回滚 → 整组必须回到操作前。"""
    box = Box()
    box.gen(ca=CA_A)
    snap = snapshot(box)
    box.gen(host="dot.v2.example", ca=CA_B)
    with open(box.p(SUB + "/stray.mobileconfig"), "wb") as f:
        f.write(b"stray\n")
    os.chmod(box.p(SUB + "/stray.mobileconfig"), 0o640)
    before = group_state(box)
    r = rollback(box, snap, fault)
    if r.returncode != 0:
        ok("%s: 落盘整体报失败(rc=%d)" % (title, r.returncode))
    else:
        bad("%s: 出了故障却报成功" % title)
    blob = (r.stdout or "") + (r.stderr or "")
    if expect_rollback:
        d = diff_state(before, group_state(box))
        if not d:
            ok("%s: 记录 + 整棵产物子树逐项回到操作前(内容/存在性/mode/uid/gid)" % title)
        else:
            bad("%s: 留下了半回滚状态, 这些项与操作前不一致: %r" % (title, d))
    else:
        # 退回本身被打断: 不要求盘面复原, 但必须**同时**报出原始错误与未恢复项
        hit = [w for w in expect_words if w in blob]
        if len(hit) == len(expect_words):
            ok("%s: 原始错误与未恢复项一起报了出来(%s)"
               % (title, " / ".join(w[:12] for w in expect_words)))
        else:
            bad("%s: 没有同时报出原始错误和未恢复项: %r" % (title, blob[-300:]))
    return box


# 1) 删除第二个孤儿失败(第一份已经删掉了)
fault_case("删第二个孤儿时 rm 失败", r'''
_pdg_rm_calls=0
rm(){
  case "$*" in
    */ios-profile/*)
      _pdg_rm_calls=$((_pdg_rm_calls+1))
      if [[ $_pdg_rm_calls -ge 2 ]]; then return 1; fi;;
  esac
  command rm "$@"
}
''')

# 2) rm 谎报成功(只读挂载 / 被 LSM 拦下都长这样)
fault_case("rm 报成功但文件仍在", r'''
rm(){
  case "$*" in
    */ios-profile/*.mobileconfig) return 0;;
  esac
  command rm "$@"
}
''')

# 3) tar 已经把 current 覆盖掉之后才失败
fault_case("tar 覆盖完 current 之后失败", r'''
tar(){
  case "$*" in
    *xpf*) command tar "$@"; return 1;;
  esac
  command tar "$@"
}
''')

# 4) 退回时写不回 metadata —— 不能假装回滚成功
fault_case("退回 metadata 时写回失败", r'''
rm(){ case "$*" in */ios-profile/*) return 1;; esac; command rm "$@"; }
cp(){
  local last="${!#}"
  case "$last" in
    */files/*) command cp "$@"; return;;          # 拍底片那一次照常
    *ios-profile.json) return 1;;                 # 往生产写回记录 → 失败
  esac
  command cp "$@"
}
''', expect_rollback=False,
    expect_words=("对账失败", "未恢复", "ios-profile.json"))

# 5) 退回时写不回 current
fault_case("退回 current 时写回失败", r'''
rm(){ case "$*" in */ios-profile/*) return 1;; esac; command rm "$@"; }
cp(){
  local last="${!#}"
  case "$last" in
    */files/*) command cp "$@"; return;;
    *current.mobileconfig) return 1;;
  esac
  command cp "$@"
}
''', expect_rollback=False,
    expect_words=("对账失败", "未恢复", "current.mobileconfig"))

# 6) 权限恢复失败 —— 内容对了不等于回到了操作前
fault_case("退回时 chmod 失败", r'''
rm(){ case "$*" in */ios-profile/*) return 1;; esac; command rm "$@"; }
chmod(){ case "$*" in *ios-profile*) return 1;; esac; command chmod "$@"; }
''', expect_rollback=False,
    expect_words=("对账失败", "未恢复"))

# 7) 属主复核对不上(非 root 改不动属主, 所以让 stat 谎报一个不同的 uid)
fault_case("属主对不上而 chown 改不动", r'''
rm(){ case "$*" in */ios-profile/*) return 1;; esac; command rm "$@"; }
stat(){
  case "$*" in
    *%a\ %u\ %g*) command stat "$@" | awk '{print $1, $2+1, $3}'; return 0;;
  esac
  command stat "$@"
}
''', expect_rollback=False,
    expect_words=("对账失败", "未恢复"))

print()
print("══ 六、拍不下完整底片就不许落盘 ══")
b6 = Box()
b6.gen(ca=CA_A)
snap6 = snapshot(b6)
b6.gen(host="dot.v2.example", ca=CA_B)
before6 = group_state(b6)
r = rollback(b6, snap6, r'''
_pdg_mktemp_dir(){ return 1; }
''')
if r.returncode != 0:
    ok("建不出底片目录 → 拒绝落盘(rc=%d)" % r.returncode)
else:
    bad("没有底片也照样落盘了")
if not diff_state(before6, group_state(b6)):
    ok("现网这一组一个字节都没动")
else:
    bad("没有底片却已经动了现网: %r" % diff_state(before6, group_state(b6)))

b7 = Box()
b7.gen(ca=CA_A)
snap7 = snapshot(b7)
b7.gen(host="dot.v2.example", ca=CA_B)
before7 = group_state(b7)
r = rollback(b7, snap7, r'''
cp(){ case "$*" in *ios-profile*) return 1;; esac; command cp "$@"; }
''')
if r.returncode != 0 and not diff_state(before7, group_state(b7)):
    ok("底片拍不全(cp 失败) → 拒绝落盘且现网未动")
else:
    bad("底片不全却落了盘: rc=%d 差异=%r"
        % (r.returncode, diff_state(before7, group_state(b7))))

print()
print("══ 七、底片不许留下描述文件副本 ══")
b8 = Box()
b8.gen(ca=CA_A)
snap8 = snapshot(b8)
b8.gen(host="dot.v2.example", ca=CA_B)
# 观察生产的 `mktemp -d` 落在哪 —— 它认 TMPDIR, 所以看的也得是 TMPDIR。写死 /tmp 的话:
# 在私有 TMPDIR 下跑就永远看不到底片(判据静默失效), 直接跑又会把并发进程新建的目录算进来。
TMPROOT = os.environ.get("TMPDIR") or "/tmp"
tmp_before = set(os.listdir(TMPROOT))
rollback(b8, snap8)
leaked = []
for name in sorted(set(os.listdir(TMPROOT)) - tmp_before):
    # 只看 `mktemp -d` 的默认形态(tmp.XXXXXXXX)—— 底片目录就是它建的。测试自己的 staging
    # 树(iossnap-*)不算, 那是本用例造出来喂给生产函数的输入, 由测试自己清理。
    if not name.startswith("tmp."):
        continue
    pth = os.path.join(TMPROOT, name)
    if not os.path.isdir(pth):
        continue
    for base, _d, files in os.walk(pth):
        leaked += [os.path.join(base, f) for f in files if f.endswith(".mobileconfig")
                   or f.endswith("ios-profile.json")]
if not leaked:
    ok("成功路径跑完, 临时区没有留下描述文件或记录的副本")
else:
    bad("底片没清干净, 留下了: %r" % leaked[:4])

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

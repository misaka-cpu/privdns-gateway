#!/usr/bin/env python3
"""三个恢复入口必须用**同一份**恢复计划: Bot 备份恢复、救援平面受管恢复、CLI 快照回滚。

以前它们各写各的, 于是同一份备份在三条路上恢复出三种结果, 而且都不报错:

  · Bot 只 stage "归档里存在的文件"。归档里没有 previous **不等于**"别动现网的 previous",
    恰恰等于"备份那一刻没有上一版"。于是一份 rev1 的备份恢复到 rev2 的机器上, 变成
    "记录说 rev1、盘上还躺着 rev2 的 previous" —— 恢复完就自相矛盾;
  · 救援平面把三个成员当成三份独立配置逐个映射, 联合校验根本没跑到过, 一份恶意三件套照收;
  · CLI 回滚干脆不校验, 直接覆盖生产文件。

所以判据与"要把这一组变成什么样子"都收进 iosstate(plan_restore / plan_from_tree /
stage_plan), 三个入口共用。"缺失"一律表达成**删除目标**, 并且删除也带 expect sha ——
从读到落盘之间被别人改过就整笔拒, 不会把并发写入悄悄抹掉。

这里的每一条都真的调那三个生产入口, 不用 grep 源码证明"函数被调用了"。
"""
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


def mkca(name):
    d = tmpguard.mkdtemp(prefix="iosplan-ca-")
    TMPS.append(d)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", d + "/ca.key", "-out", d + "/ca.crt", "-days", "1",
                    "-subj", "/CN=" + name], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d + "/ca.crt"


class Box:
    def __init__(self):
        self.root = tmpguard.mkdtemp(prefix="iosplan-")
        TMPS.append(self.root)
        for d in ("etc/privdns-gateway", "etc/sing-box", "etc/mosdns/rules", "run",
                  "var/lib/privdns-gateway", "opt/pdg-bot"):
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = self.root
        os.environ["PDG_LOCKFILE"] = self.root + "/run/privdns-gateway.lock"
        for m in ("iosstate", "iosprofile", "pdgtx", "cfgrestore"):
            sys.modules.pop(m, None)
        sys.path.insert(0, BOTDIR)
        import iosstate
        self.s = iosstate
        self.meta = self.root + "/" + ARC_META
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

    def group(self):
        """这一组现在的样子: 记录 + 整棵产物子树(不存在的记成 None)。"""
        out = {ARC_META: self.rd(ARC_META)}
        for base, _d, files in os.walk(self.p(SUB)):
            for f in files:
                rel = SUB + "/" + os.path.relpath(os.path.join(base, f), self.p(SUB))
                out[rel] = self.rd(rel)
        return {k: v for k, v in out.items() if v is not None}


sys.path.insert(0, BOTDIR)
import iosprofile  # noqa: E402

CA_A = iosprofile.ca_der_from_pem(open(mkca("PDG CA A"), encoding="utf-8").read())
CA_B = iosprofile.ca_der_from_pem(open(mkca("PDG CA B"), encoding="utf-8").read())
CA_C = iosprofile.ca_der_from_pem(open(mkca("PDG CA C"), encoding="utf-8").read())


def rev1_source():
    """一台只走到 rev1 的机器: 记录里没有 previous, 盘上也没有。"""
    src = Box()
    src.gen(ca=CA_A)
    return src


def victim_rev2(box=None):
    """一台已经走到 rev2 的机器: 记录里有 previous, 盘上也有。"""
    v = box or Box()
    v.gen(ca=CA_B)
    v.gen(host="dot.v2.example", ca=CA_C)
    return v


def pack(root, members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for arc in members:
            f = os.path.join(root, arc)
            if not os.path.isfile(f):
                continue
            tar.add(f, arcname=arc)
    return buf.getvalue()


BASE_MEMBERS = ["etc/sing-box/config.json", "etc/mosdns/config.yaml"]

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
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS,
                        json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
m._mihomo_derive = lambda staged: b"# stub\n"
m._core_svc = lambda: "mihomo"
%(inject)s
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
pdgtx.VALIDATORS = dict(pdgtx.VALIDATORS,
                        json_model=lambda p, d, c: (True, ""),
                        mihomo_check=lambda p, d, c: (True, ""),
                        mosdns_probe=lambda p, d, c: (True, ""))
cfgrestore.mihomorender.deriver_from_paths = lambda **kw: (lambda staged: b"# stub\n")
# 快照索引指到沙箱里的那一份(生产 SNAP_DIR 是绝对路径)
cfgrestore.snapshot_ids = lambda: ["snap"]
cfgrestore.snapshot_path = lambda i: %(snap)r if i == "snap" else ""
%(inject)s
res = cfgrestore.restore_managed("snap", trigger_source="test")
print("RESULT " + json.dumps({"ok": bool(res.get("ok")), "msg": res.get("error") or "",
                              "state": res.get("state", ""),
                              "restored": res.get("restored", [])}, ensure_ascii=False))
'''


def head(res):
    """给用户看的一行摘要: Bot 的在 msg 里, 救援平面的成功时 msg 为空、改看落盘目标。"""
    m = (res.get("msg") or "").strip()
    if m:
        return m.splitlines()[0][:70]
    return "restored=%r" % (res.get("restored") or res.get("state") or "")[:60]


def _run(code):
    p = subprocess.run([sys.executable, "-c", code], capture_output=True,
                       text=True, timeout=900)
    for line in reversed((p.stdout or "").splitlines()):
        if line.startswith("RESULT "):
            return json.loads(line[7:])
    return {"ok": False, "msg": "[runner crashed] " + (p.stderr or "")[-500:]}


def bot_restore(box, blob, inject=""):
    f = box.root + "/backup.tar.gz"
    with open(f, "wb") as fh:
        fh.write(blob)
    return _run(BOT_RUNNER % {"botdir": BOTDIR, "bot": BOT, "root": box.root,
                              "blob": f, "inject": inject})


def rescue_restore(box, blob, inject=""):
    f = box.root + "/snap.tar.gz"
    with open(f, "wb") as fh:
        fh.write(blob)
    return _run(RESCUE_RUNNER % {"botdir": BOTDIR, "root": box.root, "snap": f,
                                 "inject": inject})


# CLI 回滚: 抽 pdg.sh 里的真函数 + 真的 verify-restore 子命令
# 生产函数原样抽出来跑。iOS 那一批按前缀自动抽 —— 写死名字的话, 生产多加一个 helper 就
# 变成 command not found 的假红。
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
    return "\n".join(out), names


CLI, IOS_FNS = _cli_harness()
for fn in list(CLI_FNS) + ["_pdg_ios_verify_tree", "_pdg_ios_reconcile"]:
    if "%s(){" % fn not in CLI:
        bad("抽不到生产函数 %s —— 这个测试就没有在测生产代码" % fn)
# cmd_rollback 的两步: 先 _pdg_ios_verify_tree(覆盖之前的联合校验), 再
# _pdg_apply_snapshot_tree(整组落盘)。两个都是**生产函数**, 这里只负责按生产的顺序调它们
# —— 不在测试里抄一份判据, 否则改坏生产代码测试也不会红。
CLI_GATE = r'''
_pdg_module(){ printf '%s\n' "$IOSSTATE"; }
cli_rollback(){
  local tree="$1" members="$2" dest="$3"
  _pdg_ios_verify_tree "$tree" "$members" || return 1
  _pdg_apply_snapshot_tree "$tree" "$members" "$dest"
}
'''


def cli_rollback(box, blob):
    tmp = tmpguard.mkdtemp(prefix="iosplan-tree-")
    TMPS.append(tmp)
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
    script = CLI + "\n" + CLI_GATE + '\ncli_rollback "$1" "$2" "$3"\n'
    env = dict(os.environ, IOSSTATE=os.path.join(BOTDIR, "iosstate.py"),
               PDG_TX_FSROOT=box.root,
               PDG_LOCKFILE=box.root + "/run/privdns-gateway.lock")
    return subprocess.run(["bash", "-c", script, "x", tree, members, box.root],
                          capture_output=True, text=True, env=env)


print("══ 一、rev1 的备份恢复到 rev2 的机器: 现网 previous 必须被删掉 ══")
src = rev1_source()
want = src.group()
blob = pack(src.root, BASE_MEMBERS + [ARC_META, ARC_CUR, ARC_PREV])

for label, run in (("Bot 备份恢复", bot_restore),
                   ("救援平面受管恢复", rescue_restore)):
    v = victim_rev2()
    if ARC_PREV not in v.group():
        bad("%s: 前提不成立, 现网本来就没有 previous" % label)
    res = run(v, blob)
    if res["ok"]:
        ok("%s: 恢复成功(%s)" % (label, head(res)))
    else:
        bad("%s: 恢复失败 %s" % (label, res.get("msg", "")[:200]))
    got = v.group()
    if ARC_PREV not in got:
        ok("%s: 现网的 previous 被删掉了(备份那一刻没有上一版)" % label)
    else:
        bad("%s: 现网还留着 previous —— 恢复完就是自相矛盾的一组" % label)
    if got == want:
        ok("%s: 这一组逐字节等于备份那一刻" % label)
    else:
        bad("%s: 与备份对不上: %r" % (label, sorted(set(got) ^ set(want)) or "内容不同"))
    m = json.load(open(v.meta, encoding="utf-8"))
    if m.get("previous") is None and m["current"]["revision"] == 1:
        ok("%s: 记录也回到 rev1 且没有上一版" % label)
    else:
        bad("%s: 记录不对: rev=%s prev=%r" % (label, m["current"]["revision"],
                                             m.get("previous")))

v = victim_rev2()
r = cli_rollback(v, pack(src.root, [ARC_META, ARC_CUR]))
if r.returncode == 0:
    ok("CLI 快照回滚: 落盘成功")
else:
    bad("CLI 快照回滚失败: %s" % ((r.stdout or "") + (r.stderr or ""))[-300:])
if v.group() == want:
    ok("CLI 快照回滚: 这一组逐字节等于快照那一刻, previous 已清掉")
else:
    bad("CLI 快照回滚后对不上: %r" % sorted(v.group()))

print()
print("══ 二、记录里没有 current: 两份产物都要删掉 ══")
blank = Box()
blank.gen(ca=CA_A)
raw = json.load(open(blank.meta, encoding="utf-8"))
raw["current"] = None
raw["previous"] = None
with open(blank.meta, "w", encoding="utf-8") as f:
    json.dump(raw, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
os.unlink(blank.p(ARC_CUR))
blank_blob = pack(blank.root, BASE_MEMBERS + [ARC_META])
for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    res = run(v, blank_blob)
    if res["ok"]:
        ok("%s: 空记录的备份恢复成功" % label)
    else:
        bad("%s: 空记录的备份恢复失败: %s" % (label, res.get("msg", "")[:200]))
    left = sorted(k for k in v.group() if k != ARC_META)
    if not left:
        ok("%s: current / previous 都被删掉了(记录说这台机器没有产物)" % label)
    else:
        bad("%s: 还留着 %r —— 那是「碰巧存在的文件」, 没有任何记录能解释它" % (label, left))

print()
print("══ 三、旧格式备份(只有记录、没有产物)不许留下冒充产物 ══")
legacy_src = victim_rev2()
legacy_blob = pack(legacy_src.root, BASE_MEMBERS + [ARC_META])
for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    res = run(v, legacy_blob)
    if res["ok"]:
        ok("%s: 旧格式备份恢复成功" % label)
    else:
        bad("%s: 旧格式备份恢复失败: %s" % (label, res.get("msg", "")[:200]))
    m = json.load(open(v.meta, encoding="utf-8"))
    if m.get("previous") is None:
        ok("%s: 记录里的 previous 被清成不可用(它的根证书正文只在产物里)" % label)
    else:
        bad("%s: 旧格式恢复后仍声称有上一版" % label)
    left = sorted(k for k in v.group() if k != ARC_META)
    if not left:
        ok("%s: 现网 current / previous 没有作为「碰巧存在的文件」残留" % label)
    else:
        bad("%s: 残留了 %r, 它们会被当成备份带回来的产物" % (label, left))
    st, _d = v.s.artifact_health(m, "current", v.art)
    if st != "healthy":
        ok("%s: 当前版本如实标成 %s, 没谎报完整恢复" % (label, st))
    else:
        bad("%s: 当前版本竟被判成健康" % label)

print()
print("══ 四、恶意/损坏的一组: 三个入口都要在覆盖之前拒掉 ══")
evil = rev1_source()
doc = open(evil.p(ARC_CUR), "rb").read()
import plistlib  # noqa: E402
d = plistlib.loads(doc)
d["PayloadRemovalDisallowed"] = True             # 装上去就删不掉
forged = plistlib.dumps(d)
import hashlib  # noqa: E402
em = json.load(open(evil.meta, encoding="utf-8"))
em["current"]["sha256"] = hashlib.sha256(forged).hexdigest()
em["current"]["digest"] = evil.s.digest_of(em["current"]["inputs"])
evil_meta = (json.dumps(em, ensure_ascii=False, indent=2, sort_keys=True)
             .encode("utf-8") + b"\n")
evil_dir = tmpguard.mkdtemp(prefix="iosplan-evil-")
TMPS.append(evil_dir)
for rel, data in ((ARC_META, evil_meta), (ARC_CUR, forged)):
    os.makedirs(os.path.dirname(os.path.join(evil_dir, rel)), exist_ok=True)
    with open(os.path.join(evil_dir, rel), "wb") as f:
        f.write(data)
for rel in BASE_MEMBERS:
    os.makedirs(os.path.dirname(os.path.join(evil_dir, rel)), exist_ok=True)
    shutil.copy2(evil.p(rel), os.path.join(evil_dir, rel))
evil_blob = pack(evil_dir, BASE_MEMBERS + [ARC_META, ARC_CUR])
broken_blob = pack(evil_dir, BASE_MEMBERS)      # 稍后替换成损坏 JSON

for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    before = v.group()
    sb_before = v.rd("etc/sing-box/config.json")
    res = run(v, evil_blob)
    if not res["ok"] and ("PayloadRemovalDisallowed" in (res.get("msg") or "")
                          or "字段" in (res.get("msg") or "")):
        ok("%s: 恶意三件套被拒且点名了门(%s)"
           % (label, (res.get("msg") or "").splitlines()[-1][:70]))
    else:
        bad("%s: 没被拒或不是这道门: ok=%s %r" % (label, res["ok"],
                                                (res.get("msg") or "")[:200]))
    if v.group() == before:
        ok("%s: 现网这一组一个字节都没动" % label)
    else:
        bad("%s: 现网被改了" % label)
    if v.rd("etc/sing-box/config.json") == sb_before:
        ok("%s: 其它受管配置也没被恢复(整笔失败, 不是「跳过 iOS 继续」)" % label)
    else:
        bad("%s: iOS 那组被拒了, 网关配置却换了 —— 两边从此对不上" % label)

v = victim_rev2()
before = v.group()
r = cli_rollback(v, evil_blob)
blob_out = (r.stdout or "") + (r.stderr or "")
if r.returncode != 0 and "联合校验" in blob_out:
    ok("CLI 回滚: 覆盖之前就被联合校验拦下(%s)"
       % [l for l in blob_out.splitlines() if "门" in l or "字段" in l][:1])
else:
    bad("CLI 回滚没拦住: rc=%d %r" % (r.returncode, blob_out[-300:]))
if v.group() == before:
    ok("CLI 回滚: 现网这一组一个字节都没动")
else:
    bad("CLI 回滚: 现网被改了")

print()
print("══ 五、记录文件在但 JSON 坏了: 三个入口都整笔拒 ══")
bj_dir = tmpguard.mkdtemp(prefix="iosplan-bj-")
TMPS.append(bj_dir)
for rel in BASE_MEMBERS:
    os.makedirs(os.path.dirname(os.path.join(bj_dir, rel)), exist_ok=True)
    shutil.copy2(evil.p(rel), os.path.join(bj_dir, rel))
os.makedirs(os.path.dirname(os.path.join(bj_dir, ARC_META)), exist_ok=True)
with open(os.path.join(bj_dir, ARC_META), "wb") as f:
    f.write(b'{"schema": 1, "instance_id":')
bj_blob = pack(bj_dir, BASE_MEMBERS + [ARC_META])
for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    before, sb_before = v.group(), v.rd("etc/sing-box/config.json")
    res = run(v, bj_blob)
    if not res["ok"]:
        ok("%s: 记录损坏 → 整笔拒(%s)" % (label, ((res.get("msg") or "?").splitlines() or ["?"])[-1][:60]))
    else:
        bad("%s: 记录损坏却恢复成功了" % label)
    if v.group() == before and v.rd("etc/sing-box/config.json") == sb_before:
        ok("%s: 现网(含网关配置)一个字节都没动" % label)
    else:
        bad("%s: 现网被改了" % label)
v = victim_rev2()
before = v.group()
r = cli_rollback(v, bj_blob)
if r.returncode != 0 and v.group() == before:
    ok("CLI 回滚: 记录损坏 → 覆盖之前中止, 现网未动")
else:
    bad("CLI 回滚没拦住记录损坏: rc=%d" % r.returncode)

print()
print("══ 六、归档里根本没有这一组: 三个入口都不许碰现网 ══")
none_blob = pack(evil_dir, BASE_MEMBERS)
for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    before = v.group()
    res = run(v, none_blob)
    if res["ok"]:
        ok("%s: 不含这一组的备份照常恢复其它配置" % label)
    else:
        bad("%s: 不含这一组的备份恢复失败: %s" % (label, res.get("msg", "")[:200]))
    if v.group() == before:
        ok("%s: 生命周期这一组一个字节都没动" % label)
    else:
        bad("%s: 明明没带这一组却动了它: %r" % (label, sorted(v.group())))
v = victim_rev2()
before = v.group()
r = cli_rollback(v, none_blob)
if r.returncode == 0 and v.group() == before:
    ok("CLI 回滚: 不含这一组的快照不碰它")
else:
    bad("CLI 回滚碰了不该碰的: rc=%d" % r.returncode)

print()
print("══ 六之二、有产物却没有记录 = 这一组坏了, 不是「没带这一组」 ══")
# 判"这份包含不含生命周期组"以前只看 ios-profile.json 在不在。于是一份"只有产物、没有记录"
# 的归档被当成"不含这一组"放过去: 现网的旧记录原地不动, 归档里的孤立产物却被覆盖上去 ——
# 恢复完变成"记录说第 N 版、盘上是别人的第 M 版", 而且返回成功。
# 正确的语义是三选一: 三件全无 ⇒ no-op; 有记录 ⇒ 严格校验; 只有产物 ⇒ 这一组坏了, 整笔拒。
orphan_dir = tmpguard.mkdtemp(prefix="iosplan-orphan-")
TMPS.append(orphan_dir)
for rel in BASE_MEMBERS:
    os.makedirs(os.path.dirname(os.path.join(orphan_dir, rel)), exist_ok=True)
    shutil.copy2(src.p(rel), os.path.join(orphan_dir, rel))
# 网关配置写成**可分辨**的一份: "整笔拒绝"要连它一起不恢复, 内容一样的话这条断言测不出东西
with open(os.path.join(orphan_dir, "etc/sing-box/config.json"), "w") as _f:
    json.dump({"outbounds": [{"tag": "orphan-marker"}], "route": {"rules": []}}, _f)
_donor = victim_rev2()
for rel in (ARC_CUR, ARC_PREV):
    os.makedirs(os.path.dirname(os.path.join(orphan_dir, rel)), exist_ok=True)
    shutil.copy2(_donor.p(rel), os.path.join(orphan_dir, rel))

for combo, label in ((["current"], "只有 current"),
                     (["previous"], "只有 previous"),
                     (["current", "previous"], "两份产物都有")):
    members = list(BASE_MEMBERS)
    if "current" in combo:
        members.append(ARC_CUR)
    if "previous" in combo:
        members.append(ARC_PREV)
    ob = pack(orphan_dir, members)          # 注意: 没有 ARC_META
    for who, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
        v = victim_rev2()
        before, sb_before = v.group(), v.rd("etc/sing-box/config.json")
        st_before = {k: os.stat(v.p(k)).st_mode & 0o7777 for k in before}
        res = run(v, ob)
        msg = res.get("msg") or ""
        if not res["ok"] and ("没有记录" in msg or "生命周期" in msg or "配套" in msg):
            ok("%s / %s: 整笔拒且点名(%s)" % (label, who, msg.splitlines()[-1][:60]))
        else:
            bad("%s / %s: 没被拒或不是这道门: ok=%s %r" % (label, who, res["ok"], msg[:160]))
        if v.group() == before:
            ok("%s / %s: 这一组逐字节未动" % (label, who))
        else:
            now = v.group()
            diff = sorted(set(now) ^ set(before)) or \
                [k for k in before if now.get(k) != before.get(k)]
            bad("%s / %s: 这一组被改了(差异 %r)" % (label, who, diff))
        if v.rd("etc/sing-box/config.json") == sb_before:
            ok("%s / %s: 网关配置也没被恢复(整笔拒绝)" % (label, who))
        else:
            bad("%s / %s: 这一组被跳过了, 网关配置却换掉了 —— 一份坏掉的备份被放过去了"
                % (label, who))
        st_after = {k: (os.stat(v.p(k)).st_mode & 0o7777 if os.path.exists(v.p(k)) else None)
                    for k in before}
        if st_after == st_before:
            ok("%s / %s: mode 也没变" % (label, who))
        else:
            bad("%s / %s: mode 变了 %r → %r" % (label, who, st_before, st_after))
    v = victim_rev2()
    before = v.group()
    r = cli_rollback(v, ob)
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        ok("%s / CLI: 覆盖之前返回非 0(%s)" % (label, out.strip().splitlines()[-1][:60] if out.strip() else ""))
    else:
        bad("%s / CLI: 返回 0 —— 孤立产物被落到了盘上" % label)
    if v.group() == before:
        ok("%s / CLI: 现网这一组逐字节未动" % label)
    else:
        bad("%s / CLI: 现网被改了, 留下「旧记录 + 归档孤立产物」: %r"
            % (label, sorted(set(v.group()) ^ set(before))))

print()
print("══ 七、删除目标也要有并发前置条件 ══")
# 读到落盘之间有人改了现网的 previous → 这笔恢复必须拒, 而不是照删。
race = r'''
_orig_stage = pdgtx.Tx.stage
def racy(self, target, data, expect=pdgtx._UNSET):
    r = _orig_stage(self, target, data, expect=expect)
    if target == "ios_profile_previous" and data is None:
        # 事务已经记下前置 sha, 现在冒充"另一个进程"改掉这份文件
        path, _m, _s, _v = pdgtx.resolve_target(target)
        with open(path, "ab") as f:
            f.write(b"\n<!-- concurrent writer -->\n")
    return r
pdgtx.Tx.stage = racy
'''
for label, run in (("Bot", bot_restore), ("救援平面", rescue_restore)):
    v = victim_rev2()
    res = run(v, blob, race)
    if not res["ok"] and "PRECONDITION" in (res.get("msg") or ""):
        ok("%s: 删除目标在落盘前发现被别人改过 → 整笔拒(PRECONDITION_FAILED)" % label)
    elif not res["ok"]:
        ok("%s: 删除目标的并发冲突被拒: %s" % (label, (res.get("msg") or "")[:70]))
    else:
        bad("%s: 并发改动被这次恢复悄悄抹掉了" % label)
    if v.rd(ARC_PREV) and b"concurrent writer" in v.rd(ARC_PREV):
        ok("%s: 那份被并发写入的 previous 还在, 没被删" % label)
    else:
        bad("%s: 并发写入的内容没了" % label)

print()
print("══ 八、Android 平台隔离没有因为共享校验而松动 ══")
and_code = r'''
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
m._platform = lambda: "android"
sent = []
edits = []
m.send_document = lambda *a, **k: sent.append(a)
m.edit = lambda chat, mid, text, kb=None: edits.append((text, kb))
m.send = lambda chat, text, kb=None: edits.append((text, kb))
m.send_plain = lambda chat, text: edits.append((text, None))
m.answer_cb_async = lambda *a, **k: None
m.state = {}
kb = m.status_kb() if hasattr(m, "status_kb") else None
for data in ("ios", "ios_ssid", "iosgen", "iosgen:fresh", "iosgen:legacy"):
    try:
        m.handle_cb(1, 2, data)
    except Exception as e:
        edits.append(("EXC:" + type(e).__name__, None))
blob = "\n".join(t for t, _k in edits)
print("RESULT " + json.dumps({"sent": len(sent), "text": blob}, ensure_ascii=False))
''' % {"botdir": BOTDIR, "bot": BOT, "root": Box().root}
res = _run(and_code)
if res.get("sent") == 0:
    ok("Android: 五个 iOS 回调全部走不通, 一个描述文件都没生成")
else:
    bad("Android: 竟然生成了 %r" % res.get("sent"))
if "Android" in (res.get("text") or "") or "仅 iOS" in (res.get("text") or ""):
    ok("Android: 后端明说这是 Android 平台不可用")
else:
    bad("Android: 没有给出平台原因: %r" % (res.get("text") or "")[:200])

v = victim_rev2()
before = v.group()
res = bot_restore(v, blob, 'm.iosstate = None\n')
if not res["ok"] and ("Android" in (res.get("msg") or "")
                      or "模块" in (res.get("msg") or "")):
    ok("没有 iosstate 的平台上, 带这一组的备份被 fail-closed 而不是静默跳过")
else:
    bad("没有校验模块却照恢复了: ok=%s %r" % (res["ok"], (res.get("msg") or "")[:200]))
if v.group() == before:
    ok("现网这一组一个字节都没动")
else:
    bad("现网被改了")

print()
print("断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""安装清单第 2 步: 事前记录、回滚撤除、成功后收旧账、卸载清理、回滚后刷新清单, 以及接线。

为什么要有这支: 这几处都会**删文件**。删的条件只要松一条, 就会删掉用户改过的、别人链过来的、
还有服务在用的东西 —— 那比多留一个文件糟得多。所以每一条"不许删"都真造一遍, 看它留没留下、
报没报原因; 也真造一遍"该删的", 看它删没删。路径一律落在临时根里(--root), 不碰宿主。
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
import sys as _pdg_sys; _pdg_sys.path.insert(0, str(ROOT) + "/tests")  # noqa: E702
import pdg_source  # noqa: E402  共享 pdg.sh 源码入口(建议 4 第 0 步; 拆分后给出拼回的整份)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import tmpguard        # noqa: E402
import installset      # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def check(cond, m_ok, m_bad=None):
    (ok if cond else bad)(m_ok if cond else (m_bad or m_ok))


def sha_b(b):
    return hashlib.sha256(b).hexdigest()


def read(rel):
    return io.open(os.path.join(ROOT, rel), encoding="utf-8").read()


TMP = tmpguard.mkdtemp(prefix="pdg-installtxn.")


def ls(d):
    """列目录; 目录不在就当空的 —— 改坏之后记录目录可能根本没建, 那该判红, 不该崩。"""
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []
PY = os.path.join(ROOT, "deploy", "bot", "installset.py")
HOST_STATE = "/var/lib/privdns-gateway"
HOST_BEFORE = os.path.lexists(HOST_STATE)

# ── 1. 事前记录 ─────────────────────────────────────────────────────────────
print("== 1. 事前记录(lib/modules.sh 的 pdg_install_runtime_modules)==")
DEST = os.path.join(TMP, "r1", "opt-pdg-bot")
INST = os.path.join(TMP, "r1", "install")
os.makedirs(DEST)
with open(os.path.join(DEST, "checks.py"), "w") as f:
    f.write("# 旧的\n")


def run_install(env_extra, dest=DEST, runtime=None):
    env = dict(os.environ, PDG_RUNTIME_DIR=runtime or dest)
    env.update(env_extra)
    return subprocess.run(["bash", "-c", 'source lib/modules.sh && pdg_install_runtime_modules "$PWD" "$1" ios', "x", dest],
                          cwd=ROOT, capture_output=True, text=True, timeout=120, env=env)


p = run_install({"PDG_INSTALLSET_DIR": INST})
recs = ls(os.path.join(INST, "txn"))
check(p.returncode == 0 and p.stderr == "" and len(recs) == 1, "装一次: rc=0、没有告警、落了一份记录",
      "装一次不对: rc=%d recs=%s err=%r" % (p.returncode, recs, p.stderr[-200:]))
doc = json.load(open(os.path.join(INST, "txn", recs[0]))) if recs else {"entries": []}
ents = {e["path"]: e for e in doc["entries"]}
out, _ = subprocess.run(["bash", "-c", "source lib/modules.sh && pdg_platform_modules ios"], cwd=ROOT,
                        capture_output=True, text=True).stdout, None
mods = [ln.split() for ln in out.splitlines() if ln.strip()]
check(len(ents) == len(mods) and doc.get("schema") == 1 and doc.get("kind") == "install-txn",
      "记录覆盖本平台全部 %d 个运行模块, schema 1" % len(mods))
check(ents.get(os.path.join(DEST, "checks.py"), {}).get("before") == sha_b(b"# \xe6\x97\xa7\xe7\x9a\x84\n"),
      "装之前就在的文件: 记下了它原来的哈希")
newbefore = [e for pth, e in ents.items() if not pth.endswith("/checks.py")]
check(newbefore and all(e["before"] is None for e in newbefore),
      "其余 %d 个写之前不存在: 都记成 null —— 记录确实是在写文件之前落的" % len(newbefore))
wrong = [e["path"] for e in doc["entries"]
         if e["written"] != sha_b(open(os.path.join(ROOT, [m[0] for m in mods if DEST + "/" + m[1] == e["path"]][0]), "rb").read())]
check(not wrong, "每条记的写入哈希 = 仓库里那份源文件")
check(doc.get("pid", "").isdigit(), "记下了调用它的 shell 进程号(第 3 步认'这次升级'要用)")
p2 = run_install({"PDG_INSTALLSET_DIR": INST})
recs2 = ls(os.path.join(INST, "txn"))
doc2 = json.load(open(os.path.join(INST, "txn", [r for r in recs2 if r not in recs][0]))) if len(recs2) == 2 else {"entries": []}
check(len(recs2) == 2 and all(e["before"] is not None for e in doc2["entries"]),
      "再装一次: 又一份记录, 这次每个文件写之前都在(没有一个会被当成新放的)")
other = os.path.join(TMP, "r1", "elsewhere")
os.makedirs(other)
p3 = run_install({"PDG_INSTALLSET_DIR": INST}, dest=other, runtime=DEST)
check(p3.returncode == 0 and len(ls(os.path.join(INST, "txn"))) == 2,
      "装到 PDG_RUNTIME_DIR 以外的目录(测试与临时目录): 不记")
p4 = subprocess.run(["bash", "-c", 'source lib/modules.sh && pdg_install_runtime_modules "$PWD" "$1" ios', "x", other],
                    cwd=ROOT, capture_output=True, text=True, timeout=120,
                    env={k: v for k, v in dict(os.environ, PDG_RUNTIME_DIR=other).items() if k != "PDG_INSTALLSET_DIR"})
check(p4.returncode == 0 and p4.stderr == "" and os.path.lexists(HOST_STATE) == HOST_BEFORE,
      "目录不是 /opt/pdg-bot、又没给 PDG_INSTALLSET_DIR: 不记, 也不往宿主 /var/lib 写")
blocker = os.path.join(TMP, "r1", "not-a-dir")
open(blocker, "w").close()
dest5 = os.path.join(TMP, "r1", "d5")
os.makedirs(dest5)
p5 = run_install({"PDG_INSTALLSET_DIR": blocker}, dest=dest5)
check(p5.returncode == 0 and "没记下这次要装哪些运行模块" in p5.stderr and os.path.exists(os.path.join(dest5, "checks.py")),
      "记不下来(记录目录是个文件): 说一句, 照样装完(rc=0)", "记不下来时: rc=%d err=%r" % (p5.returncode, p5.stderr[-200:]))
for label, lines in (("目标重复", ["deploy/bot/checks.py /x/a 755", "deploy/bot/doctor.py /x/a 755"]),
                     ("源路径带 ..", ["../x /x/a 755"]), ("mode 非法", ["deploy/bot/checks.py /x/a 9"]),
                     ("目标是相对路径", ["deploy/bot/checks.py x/a 755"]), ("空", [])):
    try:
        installset.record(lines, ROOT, "1", os.path.join(TMP, "r1", "neg"))
        bad("记录 %s: 竟然写了" % label)
    except ValueError:
        ok("记录 %s: 整份不记" % label)
PR = os.path.join(TMP, "r1", "prune")
for i in range(installset.KEEP_RECORDS + 5):
    installset.record(["deploy/bot/checks.py /x/a.py 755"], ROOT, str(i), PR)
check(len(ls(os.path.join(PR, "txn"))) == installset.KEEP_RECORDS, "记录只留最近 %d 份" % installset.KEEP_RECORDS)

# ── 2. 回滚撤除 ─────────────────────────────────────────────────────────────
print("\n== 2. 回滚撤除(rollback-clean)==")
R = os.path.join(TMP, "r2", "root")
MD = os.path.join(R, "opt", "pdg-bot")
UD = os.path.join(R, "etc", "systemd", "system")
D2 = os.path.join(TMP, "r2", "install")


def put(name, data=b"x"):
    p = os.path.join(MD, name)
    with open(p, "wb") as f:
        f.write(data)
    return "/opt/pdg-bot/" + name, sha_b(data)


def scene():
    for d in (os.path.join(TMP, "r2"),):
        if os.path.exists(d):
            shutil.rmtree(d)
    os.makedirs(MD)
    os.makedirs(UD)
    files = {}
    for n in ("old.py", "new.py", "changed.py", "hard.py", "svc.py", "helper.py", "rescue.py", "dotwitness.py", "manifonly.py"):
        files[n] = put(n, ("# %s\n" % n).encode())
    os.link(os.path.join(MD, "hard.py"), os.path.join(TMP, "r2", "hard-link"))
    os.symlink(os.path.join(MD, "old.py"), os.path.join(MD, "link.py"))
    files["link.py"] = ("/opt/pdg-bot/link.py", files["old.py"][1])
    with open(os.path.join(MD, "svc.py"), "w") as f:
        f.write("import helper\n")
    files["svc.py"] = ("/opt/pdg-bot/svc.py", sha_b(b"import helper\n"))
    with open(os.path.join(UD, "pdg-new.service"), "w") as f:
        f.write("[Service]\nExecStart=/usr/bin/python3 /opt/pdg-bot/svc.py\n")
    rec = [("/opt/pdg-bot/%s" % n, files[n][1]) for n in
           ("new.py", "changed.py", "hard.py", "svc.py", "helper.py", "rescue.py", "dotwitness.py", "link.py")]
    os.makedirs(os.path.join(D2, "txn"))
    with open(os.path.join(D2, "txn", "20261119T000000Z-1.json"), "w") as f:
        json.dump({"schema": 1, "kind": "install-txn", "pid": "1", "entries":
                   [{"path": pth, "before": None, "written": h, "mode": "755"} for pth, h in rec]
                   + [{"path": "/opt/pdg-bot/old.py", "before": files["old.py"][1], "written": files["old.py"][1], "mode": "755"}]}, f)
    with open(os.path.join(MD, "changed.py"), "a") as f:
        f.write("# 用户改过\n")
    mf = {"schema": 1, "commit": "", "platform": "ios", "entries": [
        {"path": "/opt/pdg-bot/manifonly.py", "sha256": files["manifonly.py"][1], "mode": "755", "class": "module", "src": "x"},
        {"path": "/opt/pdg-bot/old.py", "sha256": files["old.py"][1], "mode": "755", "class": "module", "src": "x"}],
        "runtime": [], "legacy": []}
    with open(os.path.join(D2, "manifest.json"), "w") as f:
        json.dump(mf, f)
    return ["opt/", "opt/pdg-bot/", "opt/pdg-bot/old.py", "etc/nftables.conf"]


members = scene()
removed, kept = installset.rollback_clean(members, ["opt/pdg-bot/rescue.py"], D2, R)
kd = {pth: why for pth, why in kept}
present = set(os.listdir(MD))
check(set(removed) == {"/opt/pdg-bot/new.py", "/opt/pdg-bot/manifonly.py"} and "new.py" not in present and "manifonly.py" not in present,
      "只撤掉两个: 记录里新放的 new.py、清单里有而快照没有的 manifonly.py", "撤掉的是 %s" % removed)
check("old.py" in present, "快照里有的 old.py 不动(那是快照还原回来的)")
check(kd.get("/opt/pdg-bot/changed.py") == "内容与当时写进去的不同" and "changed.py" in present, "内容被改过 → 留着, 报原因")
check(kd.get("/opt/pdg-bot/hard.py") == "有多个硬链接" and "hard.py" in present, "有别的硬链接 → 留着")
check(kd.get("/opt/pdg-bot/link.py") == "不是普通文件" and os.path.islink(os.path.join(MD, "link.py")), "是符号链接 → 留着")
check(kd.get("/opt/pdg-bot/svc.py") == "还有服务在用" and kd.get("/opt/pdg-bot/helper.py") == "还有服务在用",
      "unit 里写着 svc.py, 它 import 的 helper.py 也算在用 → 两个都留着")
check("rescue.py" in present and "/opt/pdg-bot/rescue.py" not in kd, "受保护成员(救援完整恢复)不碰, 也不报")
check("dotwitness.py" in present and "/opt/pdg-bot/dotwitness.py" not in kd, "DoT 证据服务的模块交给它自己那套, 不碰也不重复报")
members = scene()
# R2 照旧顺着**所有**模块找(回滚落盘之后盘上就是要留下的那一版): 快照里有的 keeper.py 被 unit 用着、它 import 新放的 newlib.py
with open(os.path.join(MD, "keeper.py"), "w") as f:
    f.write("import newlib\n")
open(os.path.join(UD, "pdg-keeper.service"), "w").write("ExecStart=/usr/bin/python3 /opt/pdg-bot/keeper.py\n")
nl_path, nl_sha = put("newlib.py", b"# newlib\n")
rec_extra = os.path.join(D2, "txn", "20261119T000001Z-2.json")
json.dump({"schema": 1, "kind": "install-txn", "pid": "2", "entries": [{"path": nl_path, "before": None, "written": nl_sha, "mode": "755"}]},
          open(rec_extra, "w"))
removed, kept = installset.rollback_clean(members + ["opt/pdg-bot/keeper.py"], ["opt/pdg-bot/rescue.py"], D2, R)
check(dict(kept).get("/opt/pdg-bot/newlib.py") == "还有服务在用" and "newlib.py" in os.listdir(MD),
      "R2: 快照里本来就有、unit 在用的模块 import 了新放的模块 → 新放的那个留着(R2 不收窄在用的范围)")
members = scene()
removed, kept = installset.rollback_clean(["etc/", "etc/nftables.conf"], [], D2, R)
check(not removed and not kept and "new.py" in os.listdir(MD), "快照里根本没有运行模块目录: 什么都不做(判不出当时有没有)")
members = scene()
mfile = os.path.join(TMP, "r2-members.txt")
open(mfile, "w").write("\n".join(members) + "\n")
kfile = os.path.join(TMP, "r2-keep.txt")
open(kfile, "w").write("opt/pdg-bot/rescue.py\n")
cp = subprocess.run(["python3", "-I", PY, "rollback-clean", "--members", mfile, "--keep", kfile, "--dir", D2, "--root", R],
                    capture_output=True, text=True)
check(cp.returncode == 1 and "撤除快照之后才出现的运行模块: /opt/pdg-bot/manifonly.py、/opt/pdg-bot/new.py" in cp.stdout
      and "保留(还有服务在用): /opt/pdg-bot/svc.py" in cp.stdout,
      "命令行: 有留下的 → 退出码 1, 撤掉的与留下的都点名", "命令行: rc=%d out=%r" % (cp.returncode, cp.stdout))
check("# new.py" not in cp.stdout + cp.stderr, "只打路径与原因, 不打文件内容")
cp = subprocess.run(["python3", "-I", PY, "rollback-clean", "--members", os.path.join(TMP, "no-such"), "--dir", D2, "--root", R],
                    capture_output=True, text=True)
check(cp.returncode == 1 and "读不到快照成员清单" in cp.stdout, "成员清单读不到: 退出码 1, 一个都不撤")
E = os.path.join(TMP, "r2-empty")
os.makedirs(os.path.join(E, "opt", "pdg-bot"))
cp = subprocess.run(["python3", "-I", PY, "rollback-clean", "--members", mfile, "--dir", os.path.join(TMP, "nothing"), "--root", E],
                    capture_output=True, text=True)
check(cp.returncode == 0 and cp.stdout == "", "没有记录也没有清单(老机器、测试夹具): 安静地什么都不做")

# ── 3. 成功后收旧账 ─────────────────────────────────────────────────────────
print("\n== 3. 成功安装 / 升级之后收旧账(reconcile)==")
scene()
mf = json.load(open(os.path.join(D2, "manifest.json")))
mf["entries"].append({"path": "/opt/pdg-bot/helper.py", "sha256": sha_b(b"# helper.py\n"), "mode": "755", "class": "module", "src": "x"})
json.dump(mf, open(os.path.join(D2, "manifest.json"), "w"))
os.unlink(os.path.join(UD, "pdg-new.service"))
removed, kept, done = installset.reconcile(D2, R)
present = set(os.listdir(MD))
check(done and "helper.py" in present and "/opt/pdg-bot/helper.py" not in removed, "新清单里有的(这一版要的)不撤")
check("/opt/pdg-bot/new.py" in removed and "/opt/pdg-bot/svc.py" in removed and "new.py" not in present,
      "以前新放、这一版不要、没人在用的: 撤掉(new.py、svc.py)")
check(dict(kept).get("/opt/pdg-bot/changed.py") == "内容与当时写进去的不同", "被改过的照样留着、报原因")
check(os.listdir(os.path.join(D2, "txn")) == [], "收完清空事前记录")
scene()
os.unlink(os.path.join(D2, "manifest.json"))
removed, kept, done = installset.reconcile(D2, R)
check(not done and not removed and len(os.listdir(os.path.join(D2, "txn"))) == 1,
      "没有可用的新清单: 什么都不做, 记录也留着(判不出哪些是这一版的)")

# ── 4. 卸载与 forget ────────────────────────────────────────────────────────
print("\n== 4. 卸载(uninstall-clean)与 forget ==")
scene()
os.unlink(os.path.join(UD, "pdg-new.service"))
removed, kept = installset.uninstall_clean(D2, R)
check("/opt/pdg-bot/new.py" in removed and "/opt/pdg-bot/helper.py" in removed, "记录认得出来的残留模块删掉")
check(dict(kept).get("/opt/pdg-bot/changed.py") == "内容与当时写进去的不同", "被改过的留着")
check(not os.path.exists(D2), "清单、记录与目录都删掉了")
scene()
open(os.path.join(D2, "别人的.txt"), "w").close()
installset.uninstall_clean(D2, R)
check(os.path.isdir(D2) and os.listdir(D2) == ["别人的.txt"], "目录里还有别的东西: 只删自己的, 目录留着")
scene()
installset.forget(D2)
check(not os.path.exists(os.path.join(D2, "manifest.json")) and os.path.isdir(os.path.join(D2, "txn")),
      "forget 只删清单, 不动记录")

# ── 5. 接线 ─────────────────────────────────────────────────────────────────
print("\n== 5. 接线 ==")
mods_src = read("lib/modules.sh")
m = re.search(r"^pdg_install_runtime_modules\(\)\{\n(.*?)^\}\n", mods_src, re.S | re.M)
body = m.group(1) if m else ""
i_d, i_r, i_w = body.find('install -d -m755 "$dest"'), body.find("_pdg_modules_record"), body.find('install -m"$mode"')
check(body and 0 <= i_d < i_r < i_w, "事前记录排在建目录之后、写第一个文件之前")
check(re.search(r'_pdg_modules_record "\$repo" "\$dest" "\$plat" \\\n\s+\|\| echo "⚠️ 没记下', body) is not None,
      "记不下来只说一句, 不挡安装")
pdg = pdg_source.text(ROOT)
m = re.search(r"^cmd_rollback\(\)\{\n(.*?)^\}\n", pdg, re.S | re.M)
rb = m.group(1) if m else ""
idx = {k: rb.find(v) for k, v in (
    ("tzf", 'tar tzf "$f" > "$members"'), ("all", 'cp -f -- "$members" "$tmp/members.all"'),
    ("keep", 'pdg_rescue_protected > "$tmp/keep"'), ("apply", '_pdg_apply_snapshot_tree "$tree" "$members" /'),
    ("clean", '"${_rbc_args[@]}"'), ("rmtmp", 'rm -rf "$tmp"\n  (( panel_sanitized == 1 ))'),
    ("unres", '(( _rbc_rc == 0 )) || unrestored+=("快照之后新增的运行模块未能全部撤除")'),
    ("svc", '_pdg_restore_svcstate "$target" || true'), ("git", 'git -C "$REPO_DIR" reset --hard -q "$git_ref"'),
    ("man", '_ism_out="$(pdg_installset_write "$REPO_DIR" "$(_pdg_platform)" rollback 2>&1)"'),
    ("lan", "if ! _lan_rollback_converge; then"))}
check(rb and all(v >= 0 for v in idx.values()), "cmd_rollback 里各处都在(%s)" % ", ".join(k for k, v in idx.items() if v < 0))
check(idx["tzf"] < idx["all"] < idx["keep"] < idx["apply"] < idx["clean"] < idx["rmtmp"] < idx["unres"] < idx["svc"],
      "全量成员清单在保护过滤之前另存; 撤除在落盘之后、删临时目录之前、服务收敛之前; 留下的记进未能恢复项")
check(idx["git"] < idx["man"] < idx["lan"], "清单刷新在仓库复位之后(按复位后的那一版写)")
check("rollback-clean --members \"$tmp/members.all\"" in rb.replace("(rollback-clean --members", "rollback-clean --members"),
      "撤除拿的是全量成员清单, 不是保护过滤后的那份")
# 刷新清单那段是内联在 cmd_rollback 里的(不另起 shell 函数: 有测试把 cmd_rollback 按名抽出来跑)。
# 这里把那一段原文抽出来包成函数真跑: 从说明的第一行到配对的 fi。
m = re.search(r"^  # 安装清单跟着回到盘上这一版.*?\n  if \[\[ -f \"\$REPO_DIR/lib/installset.sh\" \]\]; then\n.*?\n  fi\n", rb, re.S | re.M)
blk = m.group(0) if m else ""
check("pdg_installset_write" in blk and "manifest.json" in blk, "抽到了 cmd_rollback 里刷新清单那一段(%d 行)" % blk.count("\n"))
fn = "_rb_manifest(){\n" + blk + "}\n" if blk else ""
harness = "\n".join(["set -uo pipefail", 'c_y(){ echo "Y:$*"; }', 'c_g(){ echo "G:$*"; }', "_pdg_platform(){ echo ios; }", fn])
V = os.path.join(TMP, "r5-install")
for label, repo, want in (("回到有清单的版本", ROOT, True), ("回到没有清单的版本", TMP, False)):
    p = subprocess.run(["bash", "-c", harness + '\nREPO_DIR="$1" _rb_manifest; echo "RC=$?"', "x", repo],
                       cwd=TMP, capture_output=True, text=True, timeout=120, env=dict(os.environ, PDG_INSTALLSET_DIR=V))
    exists = os.path.exists(os.path.join(V, "manifest.json"))
    by = json.load(open(os.path.join(V, "manifest.json"))).get("by") if exists else None
    check(fn and p.stdout.strip() == "RC=0" and exists == want and (by == "rollback" if want else True),
          "回滚刷新清单 %s: %s" % (label, "按复位后的仓库重写(写入者 rollback)" if want else "删掉旧清单"),
          "回滚刷新清单 %s 不对: out=%r exists=%s" % (label, p.stdout, exists))
# 调用方 shell 里已经有**别版**的运行模块清单时也得按复位后的仓库写: `pdg update` 失败、本版回滚就是这样 ——
# 更新早先在同一个 shell 里 source 过新版的 modules.sh, 回滚随后把仓库复位。别版多一项: 那个模块在复位后的
# 仓库里没有源文件, 整份写不成; 别版少一项: 会静默写出一份缺一项的清单。两种都造一遍。
MODS = read("lib/modules.sh")
IS_LINE = "deploy/bot/installset.py installset.py 755"
WANT_PATHS = sorted(ln.split()[1] for ln in subprocess.run(
    ["bash", "-c", "source lib/installset.sh && pdg_installset ios"], cwd=ROOT, capture_output=True, text=True,
    timeout=60).stdout.splitlines() if ln.strip())
check(len(WANT_PATHS) == 47 and "/opt/pdg-bot/installset.py" in WANT_PATHS, "复位后的仓库这一版 iOS 全集 %d 项" % len(WANT_PATHS))
for tag, label, stale in (("plus", "别版多一项", MODS.replace(IS_LINE, IS_LINE + "\ndeploy/bot/zz-stale-extra.py zz-stale-extra.py 755", 1)),
                          ("minus", "别版少一项", MODS.replace("\n" + IS_LINE, "", 1))):
    SD = os.path.join(TMP, "r5-stale-" + tag)
    os.makedirs(os.path.join(SD, "lib"))
    io.open(os.path.join(SD, "lib", "modules.sh"), "w", encoding="utf-8").write(stale)
    # 先核"别版"真的不同(空测条件): 只 source 那份时 iOS 模块数应是 37 / 35, 不是本版的 36。
    q = subprocess.run(["bash", "-c", 'source "$1/lib/modules.sh" && pdg_platform_modules ios | grep -c .', "x", SD],
                       capture_output=True, text=True, timeout=60)
    n_stale = int(q.stdout.strip() or 0)
    check(stale != MODS and n_stale == (37 if tag == "plus" else 35), "%s: 别版那份 iOS 模块 %d 个" % (label, n_stale))
    V3 = os.path.join(SD, "install")
    p = subprocess.run(["bash", "-c", harness + '\nsource "$2/lib/modules.sh" || exit 7\nREPO_DIR="$1" _rb_manifest; echo "RC=$?"',
                        "x", ROOT, SD], cwd=TMP, capture_output=True, text=True, timeout=120, env=dict(os.environ, PDG_INSTALLSET_DIR=V3))
    mf = os.path.join(V3, "manifest.json")
    doc = json.load(open(mf)) if os.path.exists(mf) else {}
    got = sorted(e.get("path") for e in doc.get("entries", []))
    check(fn and p.stdout.strip() == "RC=0" and doc.get("by") == "rollback" and got == WANT_PATHS,
          "回滚刷新清单时调用方 shell 里已有别版的运行模块清单(%s): 照样按复位后的仓库写出 %d 项" % (label, len(got)),
          "回滚刷新清单沿用了调用方 shell 里别版的运行模块清单(%s): out=%r 条目=%d 只在清单=%s 只在全集=%s" % (
              label, p.stdout.strip()[-200:], len(got), sorted(set(got) - set(WANT_PATHS)), sorted(set(WANT_PATHS) - set(got))))
m = re.search(r"^migrate_install_manifest\(\)\{\n.*?^\}\n", pdg, re.S | re.M)
mig = m.group(0) if m else ""
check(mig.find("pdg_installset_write") < mig.find("pdg_installset_reconcile") and "pdg_installset_reconcile" in mig,
      "迁移: 新清单写成之后才收旧账")
V2 = os.path.join(TMP, "r5-mig")
installset.record(["deploy/bot/checks.py /opt/pdg-bot/no-such-module.py 755"], ROOT, "9", V2)
harness = "\n".join(["set -uo pipefail", 'c_y(){ echo "Y:$*"; }', 'c_g(){ echo "G:$*"; }', "_pdg_platform(){ echo ios; }", mig])
p = subprocess.run(["bash", "-c", harness + '\nREPO_DIR="$1" migrate_install_manifest; echo "RC=$?"', "x", ROOT],
                   cwd=TMP, capture_output=True, text=True, timeout=120, env=dict(os.environ, PDG_INSTALLSET_DIR=V2))
check(p.stdout.strip().endswith("RC=0") and os.listdir(os.path.join(V2, "txn")) == [] and os.path.exists(os.path.join(V2, "manifest.json")),
      "迁移真跑: 写了清单、清空了旧记录", "迁移真跑不对: %r %r" % (p.stdout, p.stderr[-200:]))
ins = read("install.sh")
check(ins.find('pdg_installset_write "$REPO_DIR" "$PLATFORM" install') < ins.find('pdg_installset_reconcile "$REPO_DIR"') < ins.find("# ── 10. 自检 ──"),
      "install.sh: 写完清单再收旧账, 都在自检之前")
un = read("uninstall.sh")
check('installset.py" uninstall-clean' in un and '[[ -n "$_ISM_OUT" ]] && printf' in un, "uninstall.sh 删记录认得出来的残留, 并把结果说出来")
check(os.path.lexists(HOST_STATE) == HOST_BEFORE, "整支跑完, 宿主 %s 与开跑前一样(%s)" % (HOST_STATE, "在" if HOST_BEFORE else "不存在"))

# ── 6. R3: __migrate 失败时撤掉这次升级新放的模块(undo-txn)──────────────────
print("\n== 6. R3: undo-txn 只认这次升级的记录 ==")
import calendar  # noqa: E402
import time      # noqa: E402
FP = os.path.join(TMP, "r6", "proc")
os.makedirs(os.path.join(FP, "sys", "kernel", "random"))
open(os.path.join(FP, "sys", "kernel", "random", "boot_id"), "w").write("boot-aaa\n")
for pid, comm, ppid in (("300", "bash", "200"), ("200", "we ird) name", "100"), ("100", "pdg", "1")):
    os.makedirs(os.path.join(FP, pid))
    open(os.path.join(FP, pid, "stat"), "w").write("%s (%s) S %s 0 0 0\n" % (pid, comm, ppid))
check(installset._ancestors("300", FP) == ["300", "200", "100"], "顺着 /proc/<pid>/stat 找祖先, 进程名里有空格和右括号也认得对")
R6 = os.path.join(TMP, "r6", "root")
MD6 = os.path.join(R6, "opt", "pdg-bot")
UD6 = os.path.join(R6, "etc", "systemd", "system")
D6 = os.path.join(TMP, "r6", "install")
os.makedirs(MD6)
os.makedirs(UD6)
os.makedirs(os.path.join(D6, "txn"))
NOW = calendar.timegm(time.strptime("2026-11-19T12:00:00Z", "%Y-%m-%dT%H:%M:%SZ"))


def rec6(name, pid, boot, at, entries):
    with open(os.path.join(D6, "txn", name), "w") as f:
        json.dump({"schema": 1, "kind": "install-txn", "pid": pid, "boot_id": boot, "at": at, "entries": entries}, f)


def mod6(n, data=None):
    data = data if data is not None else ("# %s\n" % n).encode()
    open(os.path.join(MD6, n), "wb").write(data)
    return {"path": "/opt/pdg-bot/" + n, "before": None, "written": sha_b(data), "mode": "755"}


ea, eb, ec, ed, ee, eu = (mod6(n) for n in ("new_a.py", "new_b.py", "new_c.py", "new_d.py", "new_e.py", "svc_new.py"))
over = mod6("over.py")
over["before"] = sha_b(b"# old over\n")
open(os.path.join(UD6, "pdg-svcnew.service"), "w").write("ExecStart=/usr/bin/python3 /opt/pdg-bot/svc_new.py\n")
rec6("a.json", "100", "boot-aaa", "2026-11-19T11:59:00Z", [ea, over, eu])
rec6("b.json", "999", "boot-aaa", "2026-11-19T11:59:00Z", [eb])
rec6("c.json", "100", "boot-zzz", "2026-11-19T11:59:00Z", [ec])
rec6("d.json", "100", "boot-aaa", "2026-11-19T09:00:00Z", [ed])
rec6("e.json", "100", "boot-aaa", "2026-11-19T14:00:00Z", [ee])
removed, kept, n = installset.undo_txn("300", D6, R6, 3600, FP, NOW)
present = set(os.listdir(MD6))
check(n == 1 and removed == ["/opt/pdg-bot/new_a.py"] and "new_a.py" not in present,
      "只认祖先进程写的、同一次开机、一小时内的那一份, 撤掉它新放的 new_a.py", "认出 %d 份, 撤掉 %s" % (n, removed))
check({"new_b.py", "new_c.py", "new_d.py", "new_e.py"} <= present,
      "别的进程写的、别的开机、太老的、时刻在未来的记录都不认, 那些文件不动")
check("over.py" in present and "/opt/pdg-bot/over.py" not in dict(kept), "写之前就在的(被覆盖的)不动, 留给随后的回滚还原")
check(dict(kept).get("/opt/pdg-bot/svc_new.py") == "还有服务在用", "这次新放的、但已经有 unit 在用 → 留着、报原因")
check(installset.undo_txn("555", D6, R6, 3600, FP, NOW)[2] == 0, "进程链里没有记录的进程号(手动 pdg __migrate、pdg migrate): 一份都不认")
open(os.path.join(FP, "sys", "kernel", "random", "boot_id"), "w").write("")
check(installset.undo_txn("300", D6, R6, 3600, FP, NOW)[2] == 0, "读不到本次开机的 boot_id: 一份都不认")
# 真进程: 外层 shell 落记录(进程号 = 它的 $$), 子 shell 里调 undo-txn --ancestor-of 自己的 $$
RR = os.path.join(TMP, "r6-real")
os.makedirs(os.path.join(RR, "root", "opt", "pdg-bot"))
shutil.copyfile(os.path.join(ROOT, "deploy/bot/checks.py"), os.path.join(RR, "root", "opt", "pdg-bot", "zz-r3-probe.py"))
script = ("set -u\n"
          'printf "deploy/bot/checks.py /opt/pdg-bot/zz-r3-probe.py 755\\n" | python3 -I "$PY" record --repo "$REPO" --pid "$$" --dir "$D"\n'
          'bash -c \'python3 -I "$PY" undo-txn --ancestor-of "$$" --dir "$D" --root "$R"\'\n')
p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=120,
                   env=dict(os.environ, PY=PY, REPO=ROOT, D=os.path.join(RR, "inst"), R=os.path.join(RR, "root")))
check(p.returncode == 0 and "撤除这次升级新放的运行模块: /opt/pdg-bot/zz-r3-probe.py" in p.stdout
      and not os.path.exists(os.path.join(RR, "root", "opt", "pdg-bot", "zz-r3-probe.py")),
      "真进程: 父 shell 写的记录, 子进程里的 undo-txn 认得出来并撤掉", "真进程不对: rc=%d out=%r err=%r" % (p.returncode, p.stdout, p.stderr[-200:]))
# 真实布局(11-19 推演出的缺陷): R3 那一刻 /opt/pdg-bot 里是**新版**文件, 新版 checks.py import kernelfollow / installset,
# 而 checks.py 被 bot 与健康自检用着。顺着新版文件的 import 找"在用", 这两个就永远撤不掉 —— v1.11.15 直跳的 A2 照旧差两行。
R7 = os.path.join(TMP, "r7", "root")
MD7 = os.path.join(R7, "opt", "pdg-bot")
UD7 = os.path.join(R7, "etc", "systemd", "system")
D7 = os.path.join(TMP, "r7", "install")
os.makedirs(MD7)
os.makedirs(UD7)
os.makedirs(os.path.join(D7, "txn"))
out7 = subprocess.run(["bash", "-c", "source lib/modules.sh && pdg_platform_modules ios"], cwd=ROOT,
                      capture_output=True, text=True).stdout
ents7 = []
for ln in out7.splitlines():
    src, name, _m = ln.split()
    data = open(os.path.join(ROOT, src), "rb").read()
    open(os.path.join(MD7, name), "wb").write(data)
    new = name in ("kernelfollow.py", "installset.py")
    ents7.append({"path": "/opt/pdg-bot/" + name, "before": None if new else sha_b(b"old " + data),
                  "written": sha_b(data), "mode": "755"})
for u in ("pdg-bot.service", "pdg-health.service", "pdg-probe81.service", "pdg-dotwitness.service", "pdg-rules-update.service"):
    shutil.copyfile(os.path.join(ROOT, "deploy", "bot", u), os.path.join(UD7, u))
for name, data in (("svcnew.py", b"import helpnew\n"), ("helpnew.py", b"# helper\n")):
    open(os.path.join(MD7, name), "wb").write(data)
    ents7.append({"path": "/opt/pdg-bot/" + name, "before": None, "written": sha_b(data), "mode": "755"})
open(os.path.join(UD7, "pdg-svcnew.service"), "w").write("ExecStart=/usr/bin/python3 /opt/pdg-bot/svcnew.py\n")
open(os.path.join(FP, "sys", "kernel", "random", "boot_id"), "w").write("boot-aaa\n")
rec_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(NOW - 60))
with open(os.path.join(D7, "txn", "r7.json"), "w") as f:
    json.dump({"schema": 1, "kind": "install-txn", "pid": "100", "boot_id": "boot-aaa", "at": rec_at, "entries": ents7}, f)
full = installset._in_use(R7)
check({"kernelfollow.py", "installset.py"} <= full,
      "对照: 不加限制地顺着盘上新版文件找, kernelfollow.py 与 installset.py 都会被判在用(缺陷能在这个布局里复现)")
removed, kept, n = installset.undo_txn("300", D7, R7, 3600, FP, NOW)
present7 = set(os.listdir(MD7))
check(n == 1 and set(removed) == {"/opt/pdg-bot/kernelfollow.py", "/opt/pdg-bot/installset.py"}
      and "kernelfollow.py" not in present7 and "installset.py" not in present7,
      "真实布局: R3 撤掉这次新放的 kernelfollow.py 与 installset.py(新版 checks.py 里的 import 不算在用)",
      "真实布局: 撤掉的是 %s, 留下 %s" % (removed, kept))
kd7 = dict(kept)
check(kd7.get("/opt/pdg-bot/svcnew.py") == "还有服务在用" and kd7.get("/opt/pdg-bot/helpnew.py") == "还有服务在用",
      "真实布局: 新 unit 直接用的新模块、以及它 import 的另一个新模块, 都留着")
check(all(os.path.exists(os.path.join(MD7, os.path.basename(e["path"]))) for e in ents7 if e["before"] is not None),
      "真实布局: 写之前就在的 %d 个一个都没动" % sum(1 for e in ents7 if e["before"] is not None))

LINE = ('  __migrate)     need_root __migrate; _lock; run_all_migrations && _dw_settle --after-migrate || '
        '{ _mrc=$?; [[ -f /opt/pdg-bot/installset.py ]] && python3 -I /opt/pdg-bot/installset.py undo-txn --ancestor-of "$$"; exit "$_mrc"; };;')
check(pdg.splitlines().count(LINE) == 1, "派发行: 链失败时先 undo-txn 再原样带出退出码(第 342 条裁定的那一行原样)")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

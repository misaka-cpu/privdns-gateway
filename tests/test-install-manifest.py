#!/usr/bin/env python3
"""安装清单: lib/installset.sh 定的全集、installset.py 的写与核对、doctor 的「安装清单」一项、接线。

为什么要有这支: 清单是"盘上装了什么"的唯一记录, 以后回滚撤除、卸载都按它来。它记错一项,
后面就会删错或漏删; 它和 install.sh / cmd_update 的安装行对不上, 记的就不是真正装上去的东西。
所以这里不只看写出来的文件, 也逐条比对安装行, 并把每一种"不一致"都真造一遍看核对认不认得。
"""
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
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


def sh(script, env=None, inp=None):
    e = dict(os.environ)
    e.update(env or {})
    p = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, text=True,
                       timeout=120, env=e, input=inp)
    return p.returncode, p.stdout, p.stderr


def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def read(rel):
    return io.open(os.path.join(ROOT, rel), encoding="utf-8").read()


TMP = tmpguard.mkdtemp(prefix="pdg-installset.")
PY = os.path.join(ROOT, "deploy", "bot", "installset.py")

# ── 1. 全集 ─────────────────────────────────────────────────────────────────
print("== 1. lib/installset.sh 给出的全集 ==")
SETS = {}
for plat in ("ios", "android"):
    rc, out, err = sh('source lib/installset.sh && pdg_installset "$1"'.replace('"$1"', plat))
    lines = [ln for ln in out.splitlines() if ln.strip()]
    check(rc == 0 and lines, "%s: 取得到全集(%d 行)" % (plat, len(lines)), "%s: 取不到全集 rc=%d %s" % (plat, rc, err))
    SETS[plat] = [ln.split() for ln in lines]
for plat, rows in SETS.items():
    check(all(len(r) == 4 for r in rows), "%s: 每行恰好 4 个字段" % plat)
    check(all(r[3] in installset.CLASSES for r in rows), "%s: 类别都在 %s 里" % (plat, "/".join(installset.CLASSES)))
    dests = [r[1] for r in rows]
    check(len(dests) == len(set(dests)), "%s: 目标不重复" % plat)
    ghost = [r[0] for r in rows if not os.path.isfile(os.path.join(ROOT, r[0]))]
    check(not ghost, "%s: 每个源文件都在仓库里" % plat, "%s: 源文件不存在: %s" % (plat, ghost))
rc, out, _ = sh('source lib/modules.sh && pdg_platform_modules ios')
mods_ios = [ln.split() for ln in out.splitlines() if ln.strip()]
got_mods = [(r[0], r[1], r[2]) for r in SETS.get("ios", []) if r[3] == "module"]
want_mods = [(s, "/opt/pdg-bot/" + n, m) for s, n, m in mods_ios]
check(got_mods == want_mods and want_mods, "module 一类逐行等于 lib/modules.sh 的清单(iOS %d 项), 没有另抄一份" % len(want_mods),
      "module 一类与 lib/modules.sh 不一致")
ios_d = {r[1] for r in SETS.get("ios", [])}
and_d = {r[1] for r in SETS.get("android", [])}
rc, out, _ = sh('source lib/modules.sh && printf "%s\\n" "$PDG_IOS_MODULES"')
ios_only = {"/opt/pdg-bot/" + ln.split()[1] for ln in out.splitlines() if ln.strip()}
check(and_d < ios_d and ios_d - and_d == ios_only, "iOS 比 Android 只多 iOS 专属的 %d 个模块" % len(ios_only))
check("/opt/pdg-bot/installset.py" in and_d, "installset.py 自己在运行模块清单里(doctor 要 import 它)")
extra = [r for r in SETS.get("ios", []) if r[3] != "module"]
check({r[3] for r in extra} == {"bin", "hook", "unit"}, "模块以外有 bin / hook / unit 三类(%d 项)" % len(extra))

# ── 2. 与安装行一致 ─────────────────────────────────────────────────────────
print("\n== 2. 与 install.sh / cmd_update 的安装行逐条一致 ==")
INST_RE = re.compile(r'^\s*(?:if\s+!\s+|\|\|\s+!\s+)?install -m(\d{3,4}) "\$REPO_DIR"/(\S+)\s+([^\s;]+)')


def install_lines(text):
    out = {}
    for ln in text.splitlines():
        m = INST_RE.match(ln)
        if not m:
            continue
        mode, src, dst = m.group(1)[-3:], m.group(2), m.group(3)
        if dst.endswith("/"):
            dst = dst + os.path.basename(src)
        out[src] = (dst, mode)
    return out


INST = install_lines(read("install.sh"))
check(len(INST) >= 10, "install.sh 里抽到了 %d 条 `install -m… \"$REPO_DIR\"/…` 安装行" % len(INST),
      "install.sh 的安装行抽到太少(%d), 抽法坏了" % len(INST))
for src, dst, mode, cls in extra:
    got = INST.get(src)
    check(got == (dst, mode), "install.sh 装 %s → %s(%s)与清单相同" % (src, dst, mode),
          "install.sh 里 %s 的安装行与清单不同: 清单 %s/%s, install.sh %s" % (src, dst, mode, got))
EXTRA_SRC = {r[0] for r in extra}
watched = ("/usr/local/bin/", "/etc/systemd/system/", "/etc/letsencrypt/renewal-hooks/")
missed = [s for s, (d, _m) in INST.items() if d.startswith(watched) and s not in EXTRA_SRC]
check(not missed, "install.sh 往 /usr/local/bin、systemd、证书钩子目录照原样装的文件都登记了",
      "install.sh 装了却没进清单: %s" % missed)
pdg = read("deploy/bot/pdg.sh")
m = re.search(r"^cmd_update\(\)\{\n(.*?)^\}\n", pdg, re.S | re.M)
upd = install_lines(m.group(1)) if m else {}
check(len(upd) >= 4, "cmd_update 里抽到了 %d 条安装行" % len(upd), "cmd_update 的安装行抽不到(抽法坏了)")
for src, dst, mode, cls in extra:
    if cls not in ("bin", "hook"):
        continue
    check(upd.get(src) == (dst, mode), "cmd_update 每次都按清单重装 %s" % dst,
          "cmd_update 里 %s 的安装行与清单不同: %s" % (src, upd.get(src)))

# ── 3. 写 ───────────────────────────────────────────────────────────────────
print("\n== 3. 写清单 ==")
D = os.path.join(TMP, "install")
env = {"PDG_INSTALLSET_DIR": D}
rc, out, err = sh('source lib/installset.sh && pdg_installset_write "$PWD" ios t1', env)
check(rc == 0 and "安装清单已更新" in out, "第一次写: rc=0、说已更新", "第一次写失败 rc=%d %s %s" % (rc, out, err))
MF = os.path.join(D, "manifest.json")
doc = json.load(open(MF, encoding="utf-8")) if os.path.exists(MF) else {}
head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
check(doc.get("schema") == 1 and doc.get("platform") == "ios" and doc.get("by") == "t1",
      "记了 schema 1、平台、写入者")
check(doc.get("commit") == head and head, "记的提交 = 仓库 HEAD(%s)" % head[:12])
ents = doc.get("entries", [])
check(len(ents) == len(SETS.get("ios", [])), "条目数 = 全集行数(%d)" % len(ents))
check([e["path"] for e in ents] == sorted(e["path"] for e in ents), "条目按路径排好序")
wrong = [e["path"] for e in ents if e["sha256"] != sha(os.path.join(ROOT, e["src"]))]
check(not wrong and ents, "每条的 sha256 = 仓库里那份源文件", "sha256 与源文件不符: %s" % wrong[:3])
rc, rt, _ = sh('source lib/installset.sh && pdg_installset_runtime')
rc, lg, _ = sh('source lib/modules.sh && pdg_legacy_modules')
check(doc.get("runtime") == sorted(x for x in rt.splitlines() if x) and doc.get("legacy") == sorted(x for x in lg.splitlines() if x),
      "记下了运行时排除表与旧版遗留表(核对时不用再读仓库)")
check(os.path.exists(MF) and stat.S_IMODE(os.stat(MF).st_mode) == 0o644 and stat.S_IMODE(os.stat(D).st_mode) == 0o755,
      "清单 644、目录 755(内容只有路径与哈希)")
st1 = os.stat(MF)
rc, out, _ = sh('source lib/installset.sh && pdg_installset_write "$PWD" ios t2', env)
st2 = os.stat(MF)
check(rc == 0 and "无变化" in out and (st1.st_ino, st1.st_mtime_ns) == (st2.st_ino, st2.st_mtime_ns),
      "内容没变的第二次: 说无变化, 文件没被重写(写入者换了也一样)")
rc, out, _ = sh('source lib/installset.sh && pdg_installset_write "$PWD" android t3', env)
doc2 = json.load(open(MF, encoding="utf-8"))
check(rc == 0 and doc2.get("platform") == "android" and len(doc2["entries"]) == len(SETS.get("android", [])),
      "换平台就重写, 条目跟着平台变")
leftover = [n for n in os.listdir(D) if n != "manifest.json"]
check(not leftover, "目录里没留临时文件", "留下了: %s" % leftover)

before = sha(MF)
GOOD = "deploy/bot/checks.py /x/opt/pdg-bot/checks.py 755 module"
for label, lines in (
        ("目标重复", [GOOD, "deploy/bot/doctor.py /x/opt/pdg-bot/checks.py 755 module"]),
        ("mode 非法", ["deploy/bot/checks.py /x/a 7777 module"]),
        ("源路径带 ..", ["../etc/passwd /x/a 644 bin"]),
        ("源路径是绝对路径", ["/etc/passwd /x/a 644 bin"]),
        ("目标是相对路径", ["deploy/bot/checks.py opt/pdg-bot/checks.py 755 module"]),
        ("目标带 ..", ["deploy/bot/checks.py /x/../etc/a 755 module"]),
        ("类别不认识", ["deploy/bot/checks.py /x/a 755 data"]),
        ("源文件不存在", ["deploy/bot/no-such.py /x/a 755 module"]),
        ("字段数不对", ["deploy/bot/checks.py /x/a 755"]),
        ("空清单", [])):
    try:
        installset.write(lines, ROOT, "ios", "neg", D)
        bad("%s: 竟然写进去了" % label)
    except ValueError:
        check(sha(MF) == before, "%s: 整份拒绝, 原清单没动" % label, "%s: 拒绝了但原清单被改了" % label)
LD = os.path.join(TMP, "linkdir")
os.symlink(TMP, LD)
try:
    installset.write([GOOD], ROOT, "ios", "neg", LD)
    bad("清单目录是符号链接: 竟然写进去了")
except ValueError:
    ok("清单目录是符号链接: 拒绝")

# ── 4. 核对 ─────────────────────────────────────────────────────────────────
print("\n== 4. 核对: 每一种不一致都真造一遍 ==")
R = os.path.join(TMP, "root")
MD = os.path.join(R, "opt-pdg-bot")
for d in (MD, os.path.join(R, "bin"), os.path.join(R, "units")):
    os.makedirs(d)
V = os.path.join(TMP, "vdir")
CASE = [("deploy/bot/checks.py", os.path.join(MD, "checks.py"), "755", "module"),
        ("deploy/bot/doctor.py", os.path.join(MD, "doctor.py"), "755", "module"),
        ("deploy/bot/pdg.sh", os.path.join(R, "bin", "pdg"), "755", "bin"),
        ("deploy/bot/pdg-health.timer", os.path.join(R, "units", "pdg-health.timer"), "644", "unit")]


def lay():
    for src, dst, mode, _c in CASE:
        if os.path.lexists(dst) and not os.path.isdir(dst):
            os.unlink(dst)
        shutil.copyfile(os.path.join(ROOT, src), dst)
        os.chmod(dst, int(mode, 8))


lay()
installset.write([" ".join(c) for c in CASE], ROOT, "ios", "writer-x9", V,
                 runtime="health-state.json\npdg-report-*.txt\n__pycache__", legacy="nftpurge.py")
r = installset.verify(V, ROOT)
check(r["state"] == "ok" and r["counts"]["same"] == 4 and installset.verdict(r) == 0 and r["commit_match"] is True,
      "原样装好: 4 项相同、提交相同、判一致", "原样装好却没判一致: %s" % json.dumps(r.get("counts")))
txt = "\n".join(installset.render(r))
check("结论: 一致" in txt and r["written_at"] and r["written_at"] not in txt and "writer-x9" not in txt,
      "人看的输出: 结论一致, 不含写入时刻与写入者(回滚前后各核一次要能逐行比)")
for label, act, want in (
        ("内容改了一个字节", lambda p: open(p, "ab").write(b"#"), "content"),
        ("权限改了", lambda p: os.chmod(p, 0o600), "mode"),
        ("文件没了", lambda p: os.unlink(p), "missing"),
        ("换成了符号链接", lambda p: (os.unlink(p), os.symlink(os.path.join(ROOT, "deploy/bot/checks.py"), p)), "type")):
    lay()
    act(CASE[0][1])
    r = installset.verify(V, ROOT)
    st = {i["path"]: i["status"] for i in r["items"]}
    check(st.get(CASE[0][1]) == want and installset.verdict(r) == 1
          and sum(1 for v in st.values() if v != "same") == 1,
          "%s → 判 %s, 只这一项、结论不一致" % (label, want), "%s: 判成了 %s" % (label, st.get(CASE[0][1])))
lay()
MARK = "PDG-CONTENT-MARKER-7f3a"
with open(CASE[1][1], "a", encoding="utf-8") as f:
    f.write("# %s\n" % MARK)
cp = subprocess.run(["python3", "-I", PY, "verify", "--dir", V, "--repo", ROOT], capture_output=True, text=True)
cj = subprocess.run(["python3", "-I", PY, "verify", "--json", "--dir", V, "--repo", ROOT], capture_output=True, text=True)
check(cp.returncode == 1 and "内容不同(module): %s" % CASE[1][1] in cp.stdout, "命令行: 有不同时退出码 1, 点出那一项")
check(MARK not in cp.stdout + cp.stderr + cj.stdout + cj.stderr, "命令行与 --json 都不打印文件内容")
try:
    check(json.loads(cj.stdout)["counts"]["content"] == 1, "--json 可解析, 计数对")
except Exception:  # noqa: BLE001
    bad("--json 输出解析不了")
lay()
for n in ("kernelfollow.py", "nftpurge.py", "health-state.json", "pdg-report-20260101-000000.txt"):
    open(os.path.join(MD, n), "w").close()
os.makedirs(os.path.join(MD, "__pycache__"))
r = installset.verify(V, ROOT)
ex = {os.path.basename(x["path"]): x["kind"] for x in r["extra"]}
check(ex == {"kernelfollow.py": "unknown", "nftpurge.py": "legacy"},
      "清单外: 只报 kernelfollow.py(不认识)与 nftpurge.py(旧版遗留), 运行时状态与字节码不报", "清单外判成了 %s" % ex)
check(installset.verdict(r) == 0, "清单外的文件不影响结论(只提示)")
for n in ("kernelfollow.py", "nftpurge.py", "health-state.json", "pdg-report-20260101-000000.txt"):
    os.unlink(os.path.join(MD, n))
G = os.path.join(TMP, "other-git")
os.makedirs(G)
for a in (["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"]):
    subprocess.run(["git", "-C", G] + a, check=True, capture_output=True)
r = installset.verify(V, G)
check(r["commit_match"] is False and installset.verdict(r) == 1, "装着的仓库换了提交: 判提交不同、结论不一致")
r = installset.verify(V, os.path.join(TMP, "root"))
check(r["commit_match"] is None and installset.verdict(r) == 0, "装着的版本读不到: 不比提交, 文件都相同仍判一致")
shutil.copyfile(os.path.join(V, "manifest.json"), os.path.join(TMP, "good.json"))
for label, content in (("不是 JSON", "{"), ("schema 不认识", json.dumps({"schema": 2, "entries": []})),
                       ("没有条目", json.dumps({"schema": 1, "entries": []})),
                       ("条目哈希不像哈希", json.dumps({"schema": 1, "entries": [
                           {"path": "/x", "sha256": "abc", "mode": "755", "class": "module"}]}))):
    open(os.path.join(V, "manifest.json"), "w").write(content)
    r = installset.verify(V, ROOT)
    check(r["state"] == "invalid" and installset.verdict(r) == 2, "清单%s: 判读不了、退出码 2" % label)
os.unlink(os.path.join(V, "manifest.json"))
r = installset.verify(V, ROOT)
cp = subprocess.run(["python3", "-I", PY, "verify", "--dir", V], capture_output=True, text=True)
check(r["state"] == "absent" and cp.returncode == 2 and "没有清单" in cp.stdout, "没有清单: 判没有、退出码 2")
shutil.copyfile(os.path.join(TMP, "good.json"), os.path.join(V, "manifest.json"))

# ── 5. doctor 的一项 ────────────────────────────────────────────────────────
print("\n== 5. doctor 的「安装清单」一项 ==")
import checks  # noqa: E402
check(checks.check_install_manifest in checks.ALL, "check_install_manifest 在 checks.ALL 里(doctor 真的会跑)")
check(checks.check_install_manifest not in checks.ALERT, "不在健康自检的告警子集里(它不是运行期故障)")


def doc_check(vdir, repo):
    old = {k: os.environ.get(k) for k in ("PDG_INSTALLSET_DIR", "PDG_REPO_DIR")}
    os.environ["PDG_INSTALLSET_DIR"], os.environ["PDG_REPO_DIR"] = vdir, repo
    try:
        return checks.check_install_manifest()
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


LEVELS = []
lay()
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "ok" and "3 个程序文件与清单一致" in res[2], "全相同 → 🟢, 数的是运行模块与 bin 两类(%s)" % res[2])
lay()
open(CASE[0][1], "ab").write(b"#")
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "warn" and CASE[0][1] in res[2], "运行模块内容不同 → 🟡 并点名(%s)" % res[2])
lay()
os.chmod(CASE[2][1], 0o700)
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "warn" and CASE[2][1] in res[2], "/usr/local/bin 那类权限不同 → 🟡")
lay()
open(CASE[3][1], "ab").write(b"#")
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "ok" and "unit / 证书钩子有 1 项" in res[2], "只有 unit 不同 → 仍是 🟢, 说明里提一句")
lay()
res = doc_check(V, G)
LEVELS.append(res[0])
check(res[0] == "warn" and "清单不是这一版写的" in res[2], "提交对不上 → 🟡")
open(os.path.join(V, "manifest.json"), "w").write("{")
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "warn" and "清单读不了" in res[2], "清单坏了 → 🟡")
os.unlink(os.path.join(V, "manifest.json"))
res = doc_check(V, ROOT)
LEVELS.append(res[0])
check(res[0] == "info", "没有清单 → ℹ️(不算警告)")
check("fail" not in LEVELS, "七种情形里没有一种给 🔴(它不能把 pdg update 拖去回滚)")

# ── 6. 接线 ─────────────────────────────────────────────────────────────────
print("\n== 6. 接线 ==")
m = re.search(r"^run_all_migrations\(\)\{\n(.*?)^\}\n", pdg, re.S | re.M)
body = m.group(1) if m else ""
tail = [ln.strip() for ln in body.strip().splitlines()][-2:]
check(body and tail == ["(( rc == 0 )) && { migrate_install_manifest || true; }", "return $rc"],
      "run_all_migrations 最后一步写清单, 只在前面全部成功时写, 写不成不拖垮(%s)" % tail)
m = re.search(r"^migrate_install_manifest\(\)\{\n.*?^\}\n", pdg, re.S | re.M)
fn = m.group(0) if m else ""
check('pdg_installset_write "$REPO_DIR" "$(_pdg_platform)" migrate' in fn, "迁移按仓库这一版与本机平台写清单")
harness = "\n".join([
    "set -uo pipefail",
    'c_y(){ echo "Y:$*"; }', 'c_g(){ echo "G:$*"; }', "_pdg_platform(){ echo ios; }",
    fn])
for label, repo_dir, want_rc, want_out, want_file in (
        ("第一次", ROOT, 0, "G:  安装清单已更新", True),
        ("第二次", ROOT, 0, "", True),
        ("仓库停在没有清单的版本", TMP, 0, "", False)):
    vd = os.path.join(TMP, "mig-%s" % ("old" if repo_dir == TMP else "new"))
    p = subprocess.run(["bash", "-c", harness + "\nREPO_DIR=\"$1\" migrate_install_manifest", "x", repo_dir],
                       cwd=TMP, capture_output=True, text=True, timeout=120, env=dict(os.environ, PDG_INSTALLSET_DIR=vd))
    out = p.stdout.strip()
    good = (p.returncode == want_rc and (out.startswith(want_out) if want_out else out == "")
            and os.path.exists(os.path.join(vd, "manifest.json")) == want_file)
    check(fn and good, "migrate_install_manifest %s: rc=%d, 输出 %r" % (label, p.returncode, out[:40]),
          "migrate_install_manifest %s 不对: rc=%d out=%r err=%r" % (label, p.returncode, out, p.stderr[-200:]))
check(re.search(r'^  manifest\)\s+shift \|\| true; cmd_manifest "\$@";;$', pdg, re.M) is not None, "pdg manifest 接进了分发器")
m = re.search(r"^cmd_manifest\(\)\{\n.*?^\}\n", pdg, re.S | re.M)
check(m and "need_root manifest" in m.group(0) and 'verify --repo "$REPO_DIR"' in m.group(0),
      "pdg manifest verify 要 root, 把装着的仓库交给核对")
ins = read("install.sh")
i_ok = ins.find("INSTALL_OK=1")
i_w = ins.find('pdg_installset_write "$REPO_DIR" "$PLATFORM" install')
i_end = ins.find("# ── 10. 自检 ──")
check(0 < i_ok < i_w < i_end, "install.sh 在提交点之后、自检之前写清单(装机中途失败不留清单)")
check("deploy/bot/installset.py installset.py 755" in read("lib/modules.sh"), "lib/modules.sh 装 installset.py")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

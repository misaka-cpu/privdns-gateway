#!/usr/bin/env python3
"""安装清单: 负控。

每条: 精确改坏生产代码一处 → 事先登记的那一条测试判据由绿转红 → 逐字节还原并 sha256 校验。
判据纪律同 kernel-follow-negative-controls.py, 另加一条: 光"转红"不够, 红的那一行([FAIL])
必须含事先登记的字样 —— 只看退出码的负控会被"别的原因红了"空过。
锚点必须恰好命中一次; 改坏后的代码必须仍然合法(红灯得来自判据, 不是解析器)。

用法: python3 tests/negctl/install-manifest-negative-controls.py [起始编号-结束编号]
"""
import hashlib
import io
import os
import py_compile
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard  # noqa: E402

BAK = tmpguard.mkdtemp(prefix="negctl-installset.")
TOUCHED = ["deploy/bot/installset.py", "deploy/bot/checks.py", "deploy/bot/pdg.sh",
           "lib/installset.sh", "lib/modules.sh", "install.sh"]
SHA = {}
for f in TOUCHED:
    shutil.copyfile(os.path.join(ROOT, f), os.path.join(BAK, f.replace("/", "__")))
    SHA[f] = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()

T = "tests/test-install-manifest.py"
CLOSURE = "tests/test-install-closure.py"


def restore():
    for f in TOUCHED:
        shutil.copyfile(os.path.join(BAK, f.replace("/", "__")), os.path.join(ROOT, f))
        if hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest() != SHA[f]:
            print("!! 还原校验失败: %s" % f)
            sys.exit(9)


def read(f):
    return io.open(os.path.join(ROOT, f), encoding="utf-8").read()


def write(f, s):
    io.open(os.path.join(ROOT, f), "w", encoding="utf-8").write(s)


def patch(f, old, new, why):
    s = read(f)
    n = s.count(old)
    if n != 1:
        raise AssertionError("锚点命中 %d 次(应为 1): %s" % (n, why))
    write(f, s.replace(old, new, 1))


def run_test(rel, timeout=600):
    e = dict(os.environ)
    e["PYTHONDONTWRITEBYTECODE"] = ""
    # 每次跑都用一个全新的字节码缓存目录。改坏与还原常常同一秒内发生、长度又不变时
    # (比如 "warn" → "fail"), 按 mtime + 字节数判新旧的 .pyc 会被当成还新 —— 这一条跑的
    # 其实是上一条改坏的代码。第一轮的 NC11 就是这样红在了 NC10 的判据上。
    e["PYTHONPYCACHEPREFIX"] = tmpguard.mkdtemp(prefix="negctl-installset-pyc.")
    try:
        cmd = ["python3", rel] if rel.endswith(".py") else ["bash", rel]
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return [], "超时", 0
    out = p.stdout + p.stderr
    fails = [ln for ln in out.splitlines() if ln.startswith("[FAIL")]
    crashed = "抛异常" if ("Traceback" in out or "SyntaxError" in out) else ""
    return fails, crashed, p.returncode


def syntax_ok():
    bad = []
    for f in TOUCHED:
        p = os.path.join(ROOT, f)
        if f.endswith(".py"):
            try:
                py_compile.compile(p, doraise=True, cfile=os.path.join(BAK, "x.pyc"))
            except Exception:  # noqa: BLE001
                bad.append(f)
        elif subprocess.run(["bash", "-n", p], capture_output=True).returncode:
            bad.append(f)
    return bad


ONLY = set()
for _a in sys.argv[1:]:
    if "-" in _a:
        _x, _y = _a.split("-")
        ONLY |= set(range(int(_x), int(_y) + 1))
    else:
        ONLY.add(int(_a))
RESULTS = []


def nc(num, title, f, old, new, expect, gates=(T,)):
    """expect: 事先登记的字样, 必须出现在某条 [FAIL] 行里。"""
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    try:
        patch(f, old, new, title)
    except AssertionError as e:
        print("  [无效] %s" % e)
        RESULTS.append((num, title, False, "锚点没命中"))
        restore()
        return
    bad = syntax_ok()
    if bad:
        print("  [无效] 改坏后代码不合法(%s)" % ",".join(bad))
        RESULTS.append((num, title, False, "语法错"))
        restore()
        return
    hit, detail, crash = False, [], []
    for g in gates:
        fails, c, rc = run_test(g)
        detail.append("%s:%d红/rc=%d" % (os.path.basename(g), len(fails), rc))
        if c:
            crash.append("%s(%s)" % (os.path.basename(g), c))
        if rc != 0 and any(expect in ln for ln in fails):
            hit = True
        for ln in fails[:4]:
            print("    " + ln)
    valid = hit and not crash
    if crash:
        print("  ⚠️ 有测试崩溃: %s —— 崩溃不算有效红灯" % ", ".join(crash))
    print("  %s  登记字样「%s」  (%s)" % ("✅ 有效" if valid else "❌ 无效", expect, " ".join(detail)))
    RESULTS.append((num, title, valid, " ".join(detail)))
    restore()


I = "deploy/bot/installset.py"
C = "deploy/bot/checks.py"
P = "deploy/bot/pdg.sh"
L = "lib/installset.sh"
M = "lib/modules.sh"
S = "install.sh"

nc(1, "写入不再拒绝重复目标", I,
   "        if dest in seen:\n", "        if False and dest in seen:\n", "目标重复: 竟然写进去了")
nc(2, "写入放过目标里的 ..", I,
   'if not dest.startswith("/") or ".." in dest.split("/") or "//" in dest',
   'if not dest.startswith("/") or "//" in dest', "目标带 ..: 竟然写进去了")
nc(3, "核对不再比权限", I,
   '    if "%03o" % stat.S_IMODE(st.st_mode) != e["mode"]:\n',
   '    if False and "%03o" % stat.S_IMODE(st.st_mode) != e["mode"]:\n', "权限改了")
nc(4, "核对跟着符号链接走(stat 代替 lstat)", I,
   "    try:\n        st = os.lstat(p)\n    except FileNotFoundError:\n        return \"missing\"\n",
   "    try:\n        st = os.stat(p)\n    except FileNotFoundError:\n        return \"missing\"\n", "换成了符号链接")
nc(5, "清单外不再跳过运行时状态", I,
   "        if n in known or any(fnmatch.fnmatchcase(n, pat) for pat in runtime):\n",
   "        if n in known:\n", "清单外")
nc(6, "不再比提交", I,
   '"commit_match": (commit == head) if (_COMMIT.match(commit) and _COMMIT.match(head)) else None,',
   '"commit_match": None,', "装着的仓库换了提交")
nc(7, "内容比较只看 schema 与提交(换平台不重写)", I,
   'keys = ("schema", "commit", "platform", "entries", "runtime", "legacy")',
   'keys = ("schema", "commit")', "换平台就重写")
nc(8, "人看的输出带上写入时刻", I,
   'out.append("  记录的版本: %s(%s), 平台 %s" % (r["describe"] or "-", (r["commit"] or "-")[:12], r["platform"] or "-"))',
   'out.append("  记录的版本: %s(%s), 平台 %s, 写于 %s" % (r["describe"] or "-", (r["commit"] or "-")[:12], r["platform"] or "-", r["written_at"]))',
   "不含写入时刻")
nc(9, "doctor 对 unit 不同也给 🟡", C,
   'strong = [i for i in r["items"] if i["status"] != "same" and i["class"] in installset.STRONG]',
   'strong = [i for i in r["items"] if i["status"] != "same"]', "只有 unit 不同")
nc(10, "doctor 没有清单时给 🟡", C,
   'return ("info", NAME, "还没有安装清单(本版装机或更新完成时会写)")',
   'return ("warn", NAME, "还没有安装清单(本版装机或更新完成时会写)")', "没有清单 → ℹ️")
nc(11, "doctor 对程序文件不同给 🔴", C,
   'return ("warn", NAME, "%d 个程序文件与清单不一致: %s%s(sudo pdg manifest verify 看详情)"',
   'return ("fail", NAME, "%d 个程序文件与清单不一致: %s%s(sudo pdg manifest verify 看详情)"',
   "没有一种给 🔴")
nc(12, "doctor 这一项没接进 ALL", C,
   "       check_transactions, check_install_manifest]\n", "       check_transactions]\n",
   "check_install_manifest 在 checks.ALL 里")
nc(13, "迁移失败也照写清单", P,
   "  (( rc == 0 )) && { migrate_install_manifest || true; }\n", "  migrate_install_manifest || true\n",
   "run_all_migrations 最后一步写清单")
nc(14, "迁移每次都打印清单结果", P,
   '  [[ "$out" == 安装清单已更新* ]] && c_g "  $out"\n', '  c_g "  $out"\n', "第二次")
nc(15, "install.sh 不再写清单", S,
   '|| ! _ism_out="$(pdg_installset_write "$REPO_DIR" "$PLATFORM" install 2>&1)"; then',
   '|| ! _ism_out="$(true)"; then', "install.sh 在提交点之后")
nc(16, "清单里 pdg 的 mode 与安装行不符", L,
   "deploy/bot/pdg.sh /usr/local/bin/pdg 755 bin\n", "deploy/bot/pdg.sh /usr/local/bin/pdg 644 bin\n",
   "install.sh 里 deploy/bot/pdg.sh 的安装行与清单不同")
nc(17, "清单漏了一个照原样装的 unit", L,
   "deploy/bot/pdg-probe81.service /etc/systemd/system/pdg-probe81.service 644 unit\n", "",
   "install.sh 装了却没进清单")
nc(18, "运行模块清单漏了 installset.py", M,
   "\ndeploy/bot/installset.py installset.py 755\"", "\"",
   "installset.py 自己在运行模块清单里", gates=(T, CLOSURE))
nc(19, "cmd_update 的钩子安装行与清单漂开", P,
   'install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh     /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh 2>/dev/null || true',
   'install -m755 "$REPO_DIR"/deploy/cert/99-reload-cert.deploy-hook.sh     /etc/letsencrypt/renewal-hooks/deploy/99-pdg.sh 2>/dev/null || true',
   "cmd_update 里 deploy/cert/99-reload-cert.deploy-hook.sh 的安装行与清单不同")
nc(20, "pdg manifest 没接进分发器", P,
   '  manifest)      shift || true; cmd_manifest "$@";;\n', "",
   "pdg manifest 接进了分发器")

ENTRY = "tests/test-migrate-entry-contract.sh"
PROBE = "tests/test-probe81-migrate-failclosed.py"
nc(21, "写清单不再看迁移链的 rc", P,
   "  (( rc == 0 )) && { migrate_install_manifest || true; }\n", "  migrate_install_manifest || true\n",
   "H1b", gates=(ENTRY,))
nc(22, "写清单不再是迁移链的最后一步", P,
   "  migrate_lan_cert_timer || true      # 存量机器补上面板证书的续期定时器(失败不拖垮更新, doctor 会报)\n"
   "  # 安装清单排在最后",
   "  (( rc == 0 )) && { migrate_install_manifest || true; }\n"
   "  migrate_lan_cert_timer || true      # 存量机器补上面板证书的续期定时器(失败不拖垮更新, doctor 会报)\n"
   "  # 安装清单排在最后", "H2d", gates=(ENTRY,))
nc(23, "写清单不再看迁移链的 rc(probe81 那支的 10b)", P,
   "  (( rc == 0 )) && { migrate_install_manifest || true; }\n", "  migrate_install_manifest || true\n",
   "10b-失败格 执行有效", gates=(PROBE,))

print("\n" + "─" * 40)
for num, title, valid, d in RESULTS:
    print("NC%02d %s  %s  (%s)" % (num, "有效" if valid else "无效", title, d))
nv = sum(1 for r in RESULTS if r[2])
print("有效 %d / %d" % (nv, len(RESULTS)))
sys.exit(0 if RESULTS and nv == len(RESULTS) else 1)

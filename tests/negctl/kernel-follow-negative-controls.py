#!/usr/bin/env python3
"""内核跟随上游: 负控。

每条: 精确改坏生产代码一处 → 至少一条**针对性**测试由绿转红 → 逐字节还原并 sha256 校验。
判据纪律同 6.1c-final-negative-controls.py: 锚点必须恰好命中一次; 改坏后的代码必须仍然
合法(红灯得来自判据, 不是解析器); 0 条转红一律判无效; 还原走逐字节备份 + sha256。

用法: python3 tests/negctl/kernel-follow-negative-controls.py [起始编号-结束编号]
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

BAK = tmpguard.mkdtemp(prefix="negctl-kfollow.")
TOUCHED = ["deploy/bot/kernelfollow.py", "deploy/bot/pdg.sh", "deploy/bot/checks.py"]
SHA = {}
for f in TOUCHED:
    shutil.copyfile(os.path.join(ROOT, f), os.path.join(BAK, f.replace("/", "__")))
    SHA[f] = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()

PY = "tests/test-kernel-follow.py"
SH = "tests/test-kernel-follow-cli.sh"


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


def run_test(rel, timeout=900):
    e = dict(os.environ)
    e["PDG_TEST_STRICT"] = "1"
    cmd = ["python3", rel] if rel.endswith(".py") else ["bash", rel]
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return 0, "超时"
    out = p.stdout + p.stderr
    red = sum(1 for line in out.splitlines() if line.startswith("[FAIL"))
    crashed = "抛异常" if ("Traceback" in out or "SyntaxError" in out) else ""
    if red == 0 and p.returncode != 0 and not crashed:
        red = 1
    return red, crashed


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


def nc(num, title, f, old, new, gates):
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    try:
        patch(f, old, new, title)
    except AssertionError as e:
        print("  [无效] %s" % e)
        RESULTS.append((num, title, None, "锚点没命中"))
        restore()
        return
    bad = syntax_ok()
    if bad:
        print("  [无效] 改坏后代码不合法(%s)" % ",".join(bad))
        RESULTS.append((num, title, None, "语法错"))
        restore()
        return
    total, detail, crash = 0, [], []
    for g in gates:
        r, c = run_test(g)
        total += r
        detail.append("%s:%d" % (os.path.basename(g), r))
        if c:
            crash.append("%s(%s)" % (os.path.basename(g), c))
    if crash:
        print("  ⚠️ 有测试崩溃: %s —— 崩溃不算有效红灯" % ", ".join(crash))
    valid = total > 0 and not crash
    if valid:
        print("  ✅ 转红 %d 条  (%s)" % (total, " ".join(detail)))
    else:
        print("  ❌ 无效  (%s)" % " ".join(detail))
    RESULTS.append((num, title, total if valid else 0, " ".join(detail)))
    restore()


K = "deploy/bot/kernelfollow.py"
P = "deploy/bot/pdg.sh"
C = "deploy/bot/checks.py"

nc(1, "预发布不再被拒", K,
   'if data.get("prerelease") is not False or data.get("draft") is not False:',
   'if data.get("draft") is not False:', [PY, SH])
nc(2, "下载 URL 改用应答里的 browser_download_url", K,
   '"url": "https://github.com/%s/releases/download/%s/%s" % (UPSTREAM, t, name),',
   '"url": hits[0].get("browser_download_url") or "https://github.com/%s/releases/download/%s/%s" % (UPSTREAM, t, name),',
   [PY])
nc(3, "资产没有 digest 也放行", K,
   '    if not m:\n        raise KFError("%s 没有 sha256 asset digest',
   '    if not m:\n        m = DIGEST_RE.match("sha256:" + "0" * 64)\n    if not m:\n        raise KFError("%s 没有 sha256 asset digest',
   [PY])
nc(4, "认不认时不比内容摘要", K,
   "    if got != sha:\n        return False, \"\", \"内容与本机记录不一致",
   "    if False:\n        return False, \"\", \"内容与本机记录不一致",
   [PY, SH])
nc(5, "先执行再证内容", K,
   "    try:\n        got = _sha256(bin_path)\n",
   "    _self_version(bin_path)\n    try:\n        got = _sha256(bin_path)\n",
   [PY])
nc(6, "护栏放行低于钉值", K,
   "    if t < p:\n        return GUARD_REFUSE",
   "    if False:\n        return GUARD_REFUSE",
   [PY, SH])
nc(7, "体检对照永远无退步", K,
   'return sorted(k for k, v in before.items() if v == "ok" and after.get(k) != "ok")',
   'return []', [PY, SH])
nc(8, "换核前不核归档摘要", P,
   '  if ! pdg_verify_sha256 "$tmp/m.gz" "$asha" "mihomo $ver 归档 ($arch)"; then',
   '  if ! true; then', [SH])
nc(9, "体检变差也不换回", P,
   '  if (( regressed )); then\n    KF_WHY="换核后不如换核前',
   '  if (( 0 )); then\n    KF_WHY="换核后不如换核前', [SH])
nc(10, "pdg update 不再保留被认的上游内核", P,
   '  if [[ -f "$kf" ]] && kv="$(python3 "$kf" accept --pin "$ver" --bin "$bindir/mihomo" 2>/dev/null)"; then',
   '  if false && kv="$(python3 "$kf" accept --pin "$ver" --bin "$bindir/mihomo" 2>/dev/null)"; then', [SH])
nc(11, "自动不等发布满 3 天", P,
   '  if ! _kf due --published-at "$pub" >/dev/null; then',
   '  if false; then', [SH])
nc(12, "自动对失败过的版本照样重试", P,
   '  if _kf last-failed --version "$tag" >/dev/null; then',
   '  if false; then', [SH])
nc(13, "跟发布下 upgrade 照样去换", P,
   '  if [[ "$mode" != upstream ]]; then\n    echo "现在是「跟发布」',
   '  if false; then\n    echo "现在是「跟发布」', [SH])
nc(14, "doctor 内容判据在注入钉值时也走跟随分支", C,
   'fv, unreadable = _kernel_follow_version(b, _pinned_mihomo_ver() if _pin is None else "")',
   'fv, unreadable = _kernel_follow_version(b, _pinned_mihomo_ver())', [PY])
nc(15, "doctor 版本判据不核自报版本等于记录", C,
   "        if fv and fv == got:",
   "        if fv or got:", [PY])

nc(16, "下载失败也记成 fail(自动从此不再试这一版)", P,
   'arch="$(_kernel_arch)"; bindir="$(_core_bindir)"; KF_WHY=""; KF_KIND=error',
   'arch="$(_kernel_arch)"; bindir="$(_core_bindir)"; KF_WHY=""; KF_KIND=fail', [SH])
nc(17, "换核前一项 ok 都没有也照换", P,
   '  if ! out="$(_kf baseline "$tmp/h0.json")"; then',
   '  if false; then', [SH])
nc(18, "revert 留在跟上游(第二天被自动换回)", P,
   '  if [[ "$mode" == upstream ]]; then\n    if ! _kf set-mode pinned; then',
   '  if false; then\n    if ! _kf set-mode pinned; then', [SH])
nc(19, "后台任务拿不到锁时不补发通知", P,
   '[[ " $* " == *" --notify "* ]] && { KF_NOTIFY=1; trap _kernel_exit_notify EXIT; }',
   '[[ " $* " == *" --notify "* ]] && { KF_NOTIFY=1; }', [SH])
nc(20, "doctor 把读不到记录当成没有记录(报不符)", C,
   '    except kernelfollow.KFUnreadable:\n        return "", True',
   '    except kernelfollow.KFUnreadable:\n        return "", False', [PY])
nc(21, "error 也算失败过", K,
   'return last.get("result") == "fail" and last.get("version") == version',
   'return last.get("result") in ("fail", "error") and last.get("version") == version', [PY, SH])

print("\n" + "═" * 66)
for num, title, red, det in RESULTS:
    print("%s NC%02d %-36s %s  (%s)" % ("✅" if red else "❌", num, title[:36], red or 0, det))
bad = [r for r in RESULTS if not r[2]]
print("有效 %d / 无效 %d" % (len(RESULTS) - len(bad), len(bad)))
restore()
shutil.rmtree(BAK, ignore_errors=True)
sys.exit(1 if bad else 0)

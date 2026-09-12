#!/usr/bin/env python3
"""负控: 继承锁的**身份判据**有没有牙。

盯 `deploy/bot/pdgtx.py` 的 `inherited_lock_fd` / `_fd_holds_lock`。逐格把修复**撤回去**,
跑 `tests/test-inherited-lock-proof.py`, 比较**具名失败集合**。

撤回的是两条已实测的缺陷:
  ① 同 PID 直接放行 —— 同一个进程里任意一个 fd 都能冒充继承, 持锁方还在临界区里冒充者就
     被放进去了(互斥与锁生命周期一起失守);
  ② 二次凭据读取失败就 LOCK_UN —— 解掉的是**父进程**那把锁(同一个 OFD);
外加一条 ③ 读不到凭据就当继承(fail-open), 和一条 ④ 只加无关注释的空转对照。

每格五步: 锚点恰好命中 / 替换真的落进文件 / 语法门仍过 / 具名失败有新增 / finally 核对
正式树 sha256。0 条转红 = 这一格无效, 判 FAIL。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TX = "deploy/bot/pdgtx.py"
TOUCHED = [ROOT / TX]
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def failures(out):
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


SUITES = (["python3", "tests/test-inherited-lock-proof.py"],)


def run_suites(wd):
    out = ""
    for cmd in SUITES:
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


# 当前判据的尾巴: 唯一的放行点。
GATE = '''    if _fd_holds_lock(fd, want) is not True:                # ②
        return None                                         # False/None 都不足以证明
    return fd'''

# ① 撤回成"同 PID 直接放行"(v3 的 ③ 步)。/proc/locks 记的是**当初调用 flock 的进程**,
#    它与"这个 fd 持不持锁"是两码事 —— 这正是问题 A。
SAME_PID = '''    _me = os.getpid()
    _key = "%02x:%02x:%d" % (os.major(want.st_dev), os.minor(want.st_dev), want.st_ino)
    try:
        with open("/proc/locks", encoding="utf-8") as _f:
            for _ln in _f:
                _p = _ln.split()
                if (len(_p) >= 6 and _p[1] == "FLOCK" and _p[3] == "WRITE"
                        and _p[5] == _key and _p[4].isdigit() and int(_p[4]) == _me):
                    return fd
    except OSError:
        pass
''' + GATE

# ② 撤回成 v3 的 ④ 步: flock 一把, 再回读一次记录分辨新旧锁, 回读失败就 LOCK_UN。
#    `_flock_record` 要摆在模块层, 测试里的注入钩子才挂得上 —— 否则注入空转, 这一格会
#    得到一个误导性的"0 条转红"。
RECORD_FN = '''def _flock_record(st):
    want = "%02x:%02x:%d" % (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    try:
        with open("/proc/locks", encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 6 or parts[1] == "->":
                    continue
                if parts[1] != "FLOCK" or parts[3] != "WRITE" or parts[5] != want:
                    continue
                try:
                    return parts[0], int(parts[4])
                except ValueError:
                    return parts[0], -1
    except OSError:
        return "unknown"
    return None


def inherited_lock_fd(path=None):'''

RELOCK = '''    before = _flock_record(want)
    if before is None or before == "unknown":
        return None
    if before[1] == os.getpid():
        return fd
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    after = _flock_record(want)
    if after == "unknown" or after is None or after[1] == os.getpid():
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        return None
    return fd'''

# ③ 读不到凭据就当继承 —— 把 fail-closed 改成 fail-open。
FAIL_OPEN = GATE.replace("is not True", "is False")

MUT = [
    ("① 同 PID 直接放行", TX, [(GATE, SAME_PID, 1)],
     "A 还持着锁时"),
    ("② 回读失败就 LOCK_UN", TX,
     [("def inherited_lock_fd(path=None):", RECORD_FN, 1), (GATE, RELOCK, 1)],
     "没有**把父进程那把锁解掉"),
    ("③ 读不到凭据就当继承(fail-open)", TX, [(GATE, FAIL_OPEN, 1)],
     "不硬闯临界区"),
    ("④ 只加一行无关注释(反向对照)", TX,
     [("def _fd_holds_lock(fd, st):",
       "# (负控的空转对照, 不改变任何行为)\ndef _fd_holds_lock(fd, st):", 1)],
     None),
]

before_sha = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-lockid-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {TX: (Path(wd) / TX).read_text(encoding="utf-8")}
    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每格的'新增'都算不出来: %s"
            % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 继承锁证明支在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want in MUT:
        target = Path(wd) / rel
        text = pristine[rel]
        anchored = True
        for anchor, repl, hits in edits:
            n = text.count(anchor)
            if n != hits:
                bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, n, hits))
                anchored = False
                break
            text = text.replace(anchor, repl, 1)
        if not anchored:
            target.write_text(pristine[rel], encoding="utf-8")
            continue
        if text == pristine[rel]:
            bad("%s: 替换没有真的落进文件" % label)
            continue
        target.write_text(text, encoding="utf-8")
        syn = run(["python3", "-m", "py_compile", str(target)])
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)" % (label, (syn.stderr or "")[:80]))
            target.write_text(pristine[rel], encoding="utf-8")
            continue
        got = run_suites(wd)
        new = got - base
        target.write_text(pristine[rel], encoding="utf-8")
        if want is None:
            (ok if not new else bad)(
                "%s: 新增失败 0 条(判据没在看噪声)" % label if not new
                else "%s: 不该有新失败, 却新增 %d 条: %s" % (label, len(new), sorted(new)[:2]))
            continue
        if not new:
            bad("%s: **0 条转红** —— 这一格的判据没有牙" % label)
        elif not any(want in n for n in new):
            bad("%s: 转红了但没命中预期判据(%s): %s" % (label, want, sorted(new)[:2]))
        else:
            hit = sorted(n for n in new if want in n)[0]
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:74]))
finally:
    drift = [str(p) for p in TOUCHED if sha(p) != before_sha[p]]
    if drift:
        bad("正式树被改动了(负控只该改工作副本): %s" % drift)
    else:
        ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
    for p in TOUCHED:
        if os.stat(p).st_mode != modes[p]:
            bad("正式树文件 mode 变了: %s" % p)

print("-" * 62)
print("wloc-lock-identity-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

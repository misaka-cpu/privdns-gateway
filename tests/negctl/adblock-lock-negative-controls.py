#!/usr/bin/env python3
"""负控:并发锁闭包、锁忙结果与 status 只读性的判据有没有牙。

盯 `deploy/bot/pdg.sh`(五个写入口的取锁点、BUSY 结果、status 只读)与
`deploy/bot/pdg-bot.py`(锁忙文案)。逐格改坏工作副本, 跑两支聚焦测试, 比较**具名失败集合**。

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
PDG = "deploy/bot/pdg.sh"
BOT = "deploy/bot/pdg-bot.py"
TOUCHED = [ROOT / PDG, ROOT / BOT]
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


# enable-gate 也要跑: rule-add/rule-del 走的是自己内联的编译+重启, **不经过 _adblock_apply**,
# 而前两支里没有一处会成功执行 enable —— 少了它, "helper 自己去抢锁"那一格根本触及不到
# 被改坏的代码, 会得到一个误导性的"0 条转红"。
SUITES = (["bash", "tests/test-adblock-lock-closure.sh"],
          ["python3", "tests/test-bot-adblock-inline.py"],
          ["bash", "tests/test-adblock-enable-gate.sh"])


def run_suites(wd):
    out = ""
    for cmd in SUITES:
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


BUSY = '''      if ! { exec 9>"$LOCK"; } 2>/dev/null || ! flock -n 9; then
        _adb_emit ADBLOCK_BUSY none; return 1
      fi
      PDG_LOCKED=1'''

MUT = [
    ("① 摘掉 enable 的锁", PDG,
     [("    enable)\n      need_root adblock; _lock; _adblock_ensure_files",
       "    enable)\n      need_root adblock; _adblock_ensure_files", 1)],
     "[enable]"),
    ("② 摘掉 disable 的锁", PDG,
     [("    disable)\n      need_root adblock; _lock; _adblock_ensure_files",
       "    disable)\n      need_root adblock; _adblock_ensure_files", 1)],
     "[disable]"),
    ("③ 摘掉 update 的锁", PDG,
     [("    update)\n      need_root adblock; _lock; _adblock_ensure_files",
       "    update)\n      need_root adblock; _adblock_ensure_files", 1)],
     "[update]"),
    ("④ rule-add 在取锁前就 ensure_files", PDG,
     [(BUSY, '      _adblock_ensure_files >/dev/null 2>&1\n' + BUSY, 1)],
     "锁忙却建了状态目录"),
    ("⑤ 把 BUSY 换回「失败且已回滚」", PDG,
     [('        _adb_emit ADBLOCK_BUSY none; return 1',
       '        _adb_emit apply_failed_rolled_back none; return 1', 1)],
     "闭集"),
    ("⑥ status 恢复 ensure_files", PDG,
     [('    status|"") _adblock_status;;',
       '    status|"") _adblock_ensure_files >/dev/null 2>&1; _adblock_status;;', 1)],
     "status"),
    ("⑦ 让只读的 check 也去抢写锁", PDG,
     [("    check)\n      # **恰好一个参数。**",
       "    check)\n      _lock\n      # **恰好一个参数。**", 1)],
     "check"),
    ("⑧ 内部 helper 自己去抢锁(另一个 fd)", PDG,
     [('_adblock_apply(){\n  local want="$1" mod bak_b bak_l',
       '_adblock_apply(){\n  exec 8>"$LOCK"; flock -n 8 || return 1\n'
       '  local want="$1" mod bak_b bak_l', 1)],
     "["),
    ("⑨ 锁忙文案退回误导版", BOT,
     [('    "ADBLOCK_BUSY": "⏳ 另一个 PDG 操作正在进行，本次没有修改任何规则，请稍后重试。",',
       '    "ADBLOCK_BUSY": "❌ 应用失败，已回滚，规则未生效。",', 1)],
     "锁忙"),
    ("⑩ 只加一行无关注释(反向对照)", PDG,
     [("migrate_adblock(){", "# (负控的空转对照, 不改变任何行为)\nmigrate_adblock(){", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-adblock-lock-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (PDG, BOT)}
    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每格的'新增'都算不出来: %s" % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 两支聚焦测试在工作副本里全绿(具名失败 0 条)")

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
        syn = run(["bash", "-n", str(target)]) if rel.endswith(".sh") \
            else run(["python3", "-m", "py_compile", str(target)])
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
    drift = [str(p) for p in TOUCHED if sha(p) != before[p]]
    if drift:
        bad("正式树被改动了(负控只该改工作副本): %s" % drift)
    else:
        ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
    for p in TOUCHED:
        if os.stat(p).st_mode != modes[p]:
            bad("正式树文件 mode 变了: %s" % p)

print("-" * 62)
print("adblock-lock-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

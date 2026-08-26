#!/usr/bin/env python3
"""负控:基础设施闭包这道门有没有牙。

盯三个生产文件 —— `adblock.py` 的闭包判定、`pdg.sh` 的启用门、`checks.py` 的 doctor 分级。
问题只有一个:**如果这道门退化了,我们会不会知道?**

规矩同其它负控(HANDOFF §6):锚点恰好命中、替换真的落进文件、改坏后语法门仍过、
具名新增失败非空(0 条转红 = 这一格无效)、跑完正式树 sha256 逐字节还原。

五格:
  ① 闭包不完整从 fail 改回 warn 后继续 —— 正是本轮要挡的那件事
  ② 认不出的 provider 被当成"没配置"   —— 最危险的写法:门直接放行
  ③ enable 失败后仍写启用位             —— 意图与实际就此分叉
  ④ doctor 在 enabled+不完整时判 warn   —— 线上出了事只留一条黄灯
  ⑤ 只加无关注释                        —— 反向对照, 不该有任何新失败
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
MOD = "deploy/bot/adblock.py"
PDG = "deploy/bot/pdg.sh"
CHK = "deploy/bot/checks.py"
TOUCHED = [ROOT / MOD, ROOT / PDG, ROOT / CHK]

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


SUITES = (["python3", "tests/test-adblock-provider.py"],
          ["bash", "tests/test-adblock-enable-gate.sh"])


def run_suites(wd):
    out = ""
    for cmd in SUITES:
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


GATE = '''      if [[ "$_cok" != 1 ]]; then
        c_y "❌ 基础设施保护列表不完整 —— **去广告没有被启用**。"'''

MUTATIONS = [
    ("① 闭包不完整改成 warn 后继续", PDG,
     [(GATE, '''      if false; then
        c_y "⚠️ 基础设施保护列表不完整(仅提示, 继续启用)。"''', 1)],
     "无法枚举却启用成功"),
    ("② 认不出的 provider 被当成没配置", MOD,
     [("    hosts = PROVIDER_API_HOSTS.get(provider)\n    if not hosts:\n        return ((), \"UNSUPPORTED\")",
       "    hosts = PROVIDER_API_HOSTS.get(provider)\n    if not hosts:\n        return ((), \"NO_PROVIDER\")", 1),
      ('    if prov is None:\n        return {"complete": True, "provider": None',
       '    if prov is None or not PROVIDER_API_HOSTS.get(prov):\n        return {"complete": True, "provider": None', 1)],
     "无法枚举"),
    ("③ enable 失败后仍写启用位", PDG,
     [('        c_y "   注意: 自己往 allow 里加一条**不算**产品已经认全了该 provider 的 API 域名。"\n        return 1',
       '        c_y "   注意: 自己往 allow 里加一条**不算**产品已经认全了该 provider 的 API 域名。"\n'
       '        _profile_set PDG_ADBLOCK_ENABLED 1\n        return 1', 1)],
     "启用位"),
    ("④ doctor 在 enabled+不完整时判 warn", CHK,
     [('        return ("fail", name, "已启用, 但基础设施保护列表**不完整**(%s)',
       '        return ("warn", name, "已启用, 但基础设施保护列表**不完整**(%s)', 1)],
     "必须 FAIL"),
    ("⑤ 只加一行无关注释(反向对照)", MOD,
     [("def infra_closure(", "# (负控的空转对照, 不改变任何行为)\ndef infra_closure(", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-adbprov-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (MOD, PDG, CHK)}

    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每一格的'新增'都算不出来: %s"
            % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 两支聚焦测试在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want in MUTATIONS:
        target = Path(wd) / rel
        text = pristine[rel]
        anchored = True
        for anchor, repl, hits_want in edits:
            hits = text.count(anchor)
            if hits != hits_want:
                bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, hits, hits_want))
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
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:84]))
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
print("adblock-provider-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

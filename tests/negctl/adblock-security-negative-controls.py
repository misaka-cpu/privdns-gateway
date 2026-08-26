#!/usr/bin/env python3
"""负控:下载器与 CLI 的安全边界有没有牙。

盯 `adblock.py` 的安全下载器与域名契约、`pdg.sh` 的 shell/Python 边界。逐格把生产代码
改坏(只改工作副本),跑三支聚焦测试,看具名失败集合相对基线有没有新增。

十二格:
  ① 恢复自动跟随重定向        —— 本轮修的头一件事
  ② 放行明文 http://          —— scheme 白名单
  ③ 摘掉非公网地址拒绝        —— SSRF 的落点
  ④ 连接时再解析一次          —— DNS rebinding: 校验的与连上的不是同一个
  ⑤ 下载失败后覆盖 LKG        —— fail-open, 现网直接变全放行
  ⑥ 恢复 shell→Python 插值    —— 注入形状
  ⑦ 非法域名重新答"未阻断"    —— 诚实性缺口
  ⑨ 恢复"必须两个 label"      —— 单 label 又变成查不了
  ⑩ 删掉 label 语法校验        —— 为了接受单 label 而放行 `-bad` / 超长
  ⑪ allow 不再压过 block       —— 优先级
  ⑫ 第三方 _DOMAIN_RE 也放宽   —— 一行 `com` 拦掉整个 TLD
  ⑧ 只加无关注释              —— 反向对照, 不该有任何新失败
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
TOUCHED = [ROOT / MOD, ROOT / PDG]

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


SUITES = (["python3", "tests/test-adblock-fetch-security.py"],
          ["bash", "tests/test-adblock-cli-input.sh"],
          ["python3", "tests/test-adblock-rules.py"])


def run_suites(wd):
    out = ""
    for cmd in SUITES:
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


MUTATIONS = [
    ("① 恢复自动跟随重定向", MOD,
     [('        if status != 200:\n            # **重定向一律不跟随。**跟随是这一整段存在的理由。\n'
       '            raise FetchRefused("只接受 200, 实得 %d(重定向一律不跟随)" % status)',
       '        if status not in (200, 301, 302, 303, 307, 308):\n'
       '            raise FetchRefused("只接受 200, 实得 %d" % status)\n'
       '        if status != 200:\n'
       '            loc = resp.getheader("Location") or ""\n'
       '            resp.read()\n'
       '            return _safe_fetch(loc, max_bytes, resolve, connect, ssl_context)', 1)],
     "跟随了"),
    ("② 放行明文 http://", MOD,
     [('    if p.scheme != "https":', '    if p.scheme not in ("https", "http"):', 1)],
     "被接受了"),
    ("③ 摘掉非公网地址拒绝", MOD,
     [("    bad = [a for a in addrs if not _is_public_addr(a)]",
       "    bad = []", 1)],
     "却仍然连接了"),
    ("④ 连接时再解析一次(DNS rebinding)", MOD,
     [("    addr = addrs[0]\n    sock = (connect or _default_connect)(addr, 443, FETCH_TIMEOUT)",
       "    addr = ((resolve or _default_resolve)(host))[0]\n"
       "    sock = (connect or _default_connect)(addr, 443, FETCH_TIMEOUT)", 1)],
     "解析次数不是一次"),
    ("⑤ 下载失败后覆盖 LKG", MOD,
     [('    return {"ok": False, "reason": "ADBLOCK_UPDATE_FAILED",\n'
       '            "detail": "全部源都不可用: " + "; ".join(errs[:3]), "count": 0}',
       '    _atomic_write(lk, "")\n'
       '    return {"ok": False, "reason": "ADBLOCK_UPDATE_FAILED",\n'
       '            "detail": "全部源都不可用: " + "; ".join(errs[:3]), "count": 0}', 1)],
     "LKG"),
    ("⑥ 恢复 shell→Python 字面量插值", PDG,
     [('  count="$(python3 -c \'import json,sys\ntry: print(json.load(open(sys.argv[1] + "/meta.json")).get("count",0))\nexcept Exception: print(0)\' "$ADB_STATE_DIR" 2>/dev/null)"',
       '  count="$(python3 -c \'import json,sys\ntry: print(json.load(open("\'"$ADB_STATE_DIR"\'/meta.json")).get("count",0))\nexcept Exception: print(0)\' 2>/dev/null)"', 1)],
     "shell→Python 字面量插值"),
    ("⑦ 非法域名重新答'未阻断'", MOD,
     [("        good, norm, why = validate_domain(sys.argv[2])\n        if not good:",
       "        good, norm, why = validate_domain(sys.argv[2])\n"
       "        norm = norm or sys.argv[2]\n        if False:", 1)],
     "返回 0"),
    # ── 单 label 诊断一致性(v1.11.0 收口)────────────────────────────────────
    ("⑨ 恢复'必须至少两个 label'的旧判据", MOD,
     [("    for lb in labels:\n        if not lb:",
       "    if len(labels) < 2:\n        return (False, \"\", \"至少要有两个 label\")\n"
       "    for lb in labels:\n        if not lb:", 1)],
     "单 label"),
    ("⑩ 为接受单 label 而删掉 label 语法校验", MOD,
     [("        if not _LABEL_RE.match(lb):\n"
       "            return (False, \"\", \"label 只能是字母/数字/连字符, 且不能以连字符开头或结尾\")",
       "        if False:\n"
       "            return (False, \"\", \"label 只能是字母/数字/连字符, 且不能以连字符开头或结尾\")", 1)],
     "连字符"),
    ("⑪ 用户 allow 不再压过 user block", MOD,
     [('        ("ADBLOCK_USER_ALLOW", p(rbase, "adblock_allow.txt",\n'
       '                                 p(base, "adblock_allow.txt", USER_ALLOW)), False),\n'
       '        ("ADBLOCK_USER_BLOCK", p(base, "effective_block.txt",\n'
       '                                 p(base, "adblock_block.txt", EFF_BLOCK)), True),',
       '        ("ADBLOCK_USER_BLOCK", p(base, "effective_block.txt",\n'
       '                                 p(base, "adblock_block.txt", EFF_BLOCK)), True),\n'
       '        ("ADBLOCK_USER_ALLOW", p(rbase, "adblock_allow.txt",\n'
       '                                 p(base, "adblock_allow.txt", USER_ALLOW)), False),', 1)],
     "allow"),
    ("⑫ 把第三方 _DOMAIN_RE 也放宽到单 label", MOD,
     [('_DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"\n'
       '                        r"(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")',
       '_DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"\n'
       '                        r"(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$")', 1)],
     "第三方源"),
    ("⑧ 只加一行无关注释(反向对照)", MOD,
     [("def validate_domain(", "# (负控的空转对照, 不改变任何行为)\ndef validate_domain(", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-adbsec-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (MOD, PDG)}

    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每一格的'新增'都算不出来: %s"
            % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 三支聚焦测试在工作副本里全绿(具名失败 0 条)")

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
            bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)" % (label, (syn.stderr or "")[:90]))
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
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:82]))
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
print("adblock-security-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

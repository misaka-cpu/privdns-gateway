#!/usr/bin/env python3
"""负控:去广告这一套判据有没有牙。

被盯的是三个生产文件 —— mosdns 受管块(优先级与位置)、adblock.py(下载校验与 LKG)、
pdg.sh 的全局快照候选集。这一支回答的是另一个问题:**如果它们退化了,我们会不会知道?**

做法是逐格把生产代码改坏(只改工作副本,正式树一个字节不动),再跑那两支聚焦测试,
看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本,必须全绿 —— 基线不绿的话
后面每一格的"新增"都算不出来。

每格五步,缺一不算有效(规矩见 HANDOFF §6):
  · 锚点在整份文件里**恰好命中**预期次数;
  · 替换确实落进了文件;
  · 改坏后语法门仍过(bash -n / py_compile)—— 语法错造成的红不算"判据抓住了";
  · 失败集合有**具名新增**(0 条转红 = 这一格无效,判 FAIL);
  · 恢复后正式树 sha256 与 before-image 逐字节一致。

九格:
  ① 摘掉 infra allow 的优先级       —— 基础设施域名会被第三方表误杀
  ② 摘掉 user allow 的优先级        —— 用户放行不再压过 block
  ③ 让第三方表压过用户显式分流      —— 违反"用户点名 > 自动批量规则"
  ④ 把 adblock 挪到 cache 之后      —— 缓存命中绕过阻断
  ⑤ 接受 HTML 错页                  —— 会编译出一张假表
  ⑥ 更新失败切成空表                —— fail-open, 全部放行
  ⑦ 让 DoT 走另一条入口             —— 单协议绕过
  ⑧ 把第三方表塞进全局快照          —— 大表进十份轮转快照
  ⑨ 只加无关注释                    —— 反向对照, 不该有任何新失败
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
CFG = "deploy/mosdns/config.yaml"
MOD = "deploy/bot/adblock.py"
PDG = "deploy/bot/pdg.sh"
TOUCHED = [ROOT / CFG, ROOT / MOD, ROOT / PDG]

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
    """具名失败集合, 归一化掉临时目录/哈希/大数(§9.15)。"""
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


SH = "tests/test-adblock-contracts.sh"
PY_ = "tests/test-adblock-rules.py"


def run_suites(wd):
    out = ""
    for cmd in (["bash", SH], ["python3", PY_]):
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


# 每格 = (标签, 文件, [(锚点, 替换, 预期命中数)], 期望转红的关键词)
INFRA = '          - "!qname $adblock_infra_allow"\n        exec: reject 3\n      # ② 第三方广告表'
MUTATIONS = [
    ("① 摘掉 infra allow 的优先级", CFG,
     [('          - "!qname $adblock_infra_allow"\n', "", 2)], "不被第三方表阻断"),
    ("② 摘掉 user allow 的优先级", CFG,
     [('          - "!qname $adblock_user_allow"\n', "", 2)], "user allow"),
    ("③ 让第三方表压过用户显式分流", CFG,
     [('          - "!qname $explicit_proxy"\n', "", 1)], "显式分流"),
    ("④ 把 adblock 挪到 cache 之后", CFG, None, "lazy_cache"),
    # ⑤ "HTML 错页必须被拒"这条性质在 parse_source 里是**三重冗余**的: 内容嗅探
    #    (_REJECT_HINTS)、语法字符(_SYNTAX_CHARS)、以及"认不出的形态"那条 else。
    #    前两版负控分别摘掉一道、两道, **都是 0 条转红** —— 负控如实告诉我那些不是承重位。
    #    要证明的是性质本身有守卫, 所以直接把 parse_source 改成"来者不拒"。
    ("⑤ parse_source 来者不拒(HTML/IP/ABP 全放行)", MOD,
     [("    if not text or not text.strip():\n        return []",
       "    if not text or not text.strip():\n        return []\n    return normalize(text.split())", 1)],
     "接受了"),
    ("⑥ 更新失败切成空表", MOD,
     [('    return {"ok": False, "reason": "ADBLOCK_UPDATE_FAILED",\n'
       '            "detail": "全部源都不可用: " + "; ".join(errs[:3]), "count": 0}',
       '    _atomic_write(lk, "")\n'
       '    return {"ok": True, "reason": None, "detail": "切成空表", "count": 0}', 1)],
     "LKG"),
    ("⑦ 让 DoT 走另一条入口(单协议绕过)", CFG,
     [('args: {entry: main_sequence, listen: "0.0.0.0:853"', 'args: {entry: probe_seq, listen: "0.0.0.0:853"', 1)],
     "三协议"),
    ("⑧ 把第三方表塞进全局快照", PDG,
     [("var/lib/privdns-gateway/ios-profile\n", "var/lib/privdns-gateway/ios-profile var/lib/privdns-gateway/adblock\n", 1)],
     "快照"),
    ("⑨ 只加一行无关注释(反向对照)", CFG,
     [("  - tag: adblock_infra_allow", "  # (负控的空转对照, 不改变任何行为)\n  - tag: adblock_infra_allow", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-adblock-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (CFG, MOD, PDG)}

    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每一格的'新增'都算不出来: %s"
            % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 两支聚焦测试在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want in MUTATIONS:
        target = Path(wd) / rel
        text = pristine[rel]

        if edits is None:                      # ④ 需要整段搬家, 单独处理
            m = re.search(r"( *# >>> pdg-adblock managed block \(internal_sequence\).*?"
                          r"# <<< pdg-adblock managed block \(internal_sequence\)\n)", text, re.S)
            if not m:
                bad("%s: 抽不到 internal_sequence 受管块" % label)
                continue
            blk = m.group(1)
            moved = text.replace(blk, "", 1)
            anchor = "      # MITM 接管域名: 强制劫持"
            if anchor not in moved:
                bad("%s: 找不到搬家锚点" % label)
                continue
            text = moved.replace(anchor, blk + anchor, 1)   # 挪到 cache+has_resp 之后
        else:
            anchored = True
            for anchor, repl, hits_want in edits:
                hits = text.count(anchor)
                if hits != hits_want:
                    bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, hits, hits_want))
                    anchored = False
                    break
                text = text.replace(anchor, repl)
            if not anchored:
                target.write_text(pristine[rel], encoding="utf-8")
                continue

        if text == pristine[rel]:
            bad("%s: 替换没有真的落进文件" % label)
            continue
        target.write_text(text, encoding="utf-8")

        if rel.endswith(".sh"):
            syn = run(["bash", "-n", str(target)])
        elif rel.endswith(".py"):
            syn = run(["python3", "-m", "py_compile", str(target)])
        else:
            syn = subprocess.CompletedProcess([], 0, "", "")   # YAML 由 mosdns 自己判
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
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:86]))
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
print("adblock-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

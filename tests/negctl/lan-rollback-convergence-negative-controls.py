#!/usr/bin/env python3
"""负控: LAN 回滚收敛这一套判据有没有牙。

被盯的东西在两处 —— pdg.sh 的 `_lan_render` / `_lan_rollback_converge` / 三处 apply 调用点,
以及 checks.py 的门四。这一支回答的是另一个问题: **如果它们退化了, 我们会不会知道?**

做法是逐格把**生产代码**改坏(只改工作副本, 正式树一个字节不动), 再跑那两支聚焦测试,
看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本, 必须全绿 —— 基线不绿的话
后面每一格的"新增"都算不出来。

每格五步, 缺一不算有效(规矩见 HANDOFF §6):
  · 锚点在整份文件里**恰好命中**预期次数(多了少了都说明改坏器没打在预期位置);
  · 替换确实落进了文件, 且锚点恰好被消费掉;
  · 改坏后语法门仍过(`bash -n` / `py_compile`)—— 语法错造成的红不算"判据抓住了";
  · 失败集合有**具名新增**(0 条转红 = 这一格无效, 判 FAIL);
  · 恢复后正式树 sha256 与 before-image 逐字节一致。

九格:
  ① 摘掉 cmd_rollback 里的收敛调用      —— D 组(按执行顺序判的那条)该转红;
  ② 收敛函数改成空转 return 0           —— C 组该转红: 模型回去了产物没跟上;
  ③ _lan_render 落盘失败洗成 return 0   —— A 组该转红, 这正是修掉的那个假成功;
  ④ 摘掉失败时的前像退回                —— "半套状态"那两条该转红;
  ⑤ 恢复 `_lan_apply_proxy || true`     —— B 组该转红, 这是被吞掉的失败;
  ⑥ 摘掉停用方向的收敛分支              —— C3 该转红(只顾启用方向是最容易漏的那半);
  ⑦ 门四只报"缺少"不报"多出"            —— 漂移里最危险的那个方向该转红;
  ⑧ 门四把"读不到"判成 fail             —— 假红也是坏判据: 把"没跑成"说成"不一致";
  ⑨ 只加无关注释                        —— 反向对照, 不该有任何新失败。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402 - 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[2]
TOUCHED = [ROOT / "deploy/bot/pdg.sh", ROOT / "deploy/bot/checks.py"]

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
    """具名失败集合。归一化掉时间戳/随机临时目录/PID —— 否则同一条失败会因为
    `tmp.a9m4kpkt` vs `tmp.n17y1tpp` 被算成"一增一减"(§9.15)。"""
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


# ── 两支聚焦测试 ────────────────────────────────────────────────────────────
SH = "tests/test-lan-rollback-convergence.sh"
PY_ = "tests/test-lan-proxy-drift.py"


def run_suites(wd):
    """在工作副本里跑两支, 回显 (具名失败集合, 是否有崩溃迹象)。"""
    out = ""
    for cmd in (["bash", SH], ["python3", PY_]):
        r = run(cmd, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out), out


# 每格 = (标签, 文件, [(锚点, 替换, 预期命中数), …], 期望转红的关键词)
PDG = "deploy/bot/pdg.sh"
CHK = "deploy/bot/checks.py"

CONV_CALL = """  if ! _lan_rollback_converge; then
    unrestored+=("内网面板派生产物")
  fi
"""
CONV_BODY_ANCHOR = """_lan_rollback_converge(){
  local intent active=0"""
RENDER_FAIL = """    c_y "❌ 派生产物落盘失败 → 整笔退回本次调用前的状态。"
    _lan_restore_pre "$pre\""""
APPLY_SYNC = """  _lan_apply_proxy || return 1
  c_g "✅ 反代配置、出站白名单、DNS 劫持集与分流已同步。\""""
DISABLED_BRANCH = """  if (( active == 1 )) || [[ -e "$LAN_UNIT" || -s "$LAN_NFT_CONF" ]]; then
    if ! _lan_disable >/dev/null; then"""
EXTRA_DIR = """    if extra:
        parts.append("反代仍在服务面板表里没有的 %s"""
WARN_UNREADABLE = """        return ("warn", name, "读不到受管反代配置 %s(%s), 本项没跑成" % (LAN_CADDYFILE, e.__class__.__name__))"""

MUTATIONS = [
    ("① 摘掉 cmd_rollback 里的收敛调用", PDG, [(CONV_CALL, "", 1)], "D1"),
    ("② 收敛函数空转(什么都不做就说成功)", PDG,
     [(CONV_BODY_ANCHOR, "_lan_rollback_converge(){\n  return 0\n  local intent active=0", 1)], "C"),
    ("③ _lan_render 落盘失败洗成 return 0", PDG,
     [('    rm -rf "$stg"; return 1\n  fi\n  rm -rf "$stg"\n  return 0',
       '    rm -rf "$stg"; return 0\n  fi\n  rm -rf "$stg"\n  return 0', 1)], "A"),
    ("④ 摘掉失败时的前像退回", PDG,
     [(RENDER_FAIL, '    c_y "❌ 派生产物落盘失败 → 整笔退回本次调用前的状态。"', 1)], "半套状态"),
    ("⑤ 恢复 `_lan_apply_proxy || true`", PDG,
     [(APPLY_SYNC, '  _lan_apply_proxy || true\n  c_g "✅ 反代配置、出站白名单、DNS 劫持集与分流已同步。"', 1)], "B"),
    ("⑥ 摘掉停用方向的收敛分支", PDG,
     [(DISABLED_BRANCH, '  if false; then\n    if ! _lan_disable >/dev/null; then', 1)], "C3"),
    ("⑦ 门四只报缺少、不报多出", CHK,
     [(EXTRA_DIR, '    if False:\n        parts.append("反代仍在服务面板表里没有的 %s', 1)], "③"),
    ("⑧ 门四把读不到判成 fail(把没跑成说成不一致)", CHK,
     [(WARN_UNREADABLE, '        return ("fail", name, "读不到受管反代配置 %s(%s)" % (LAN_CADDYFILE, e.__class__.__name__))', 1)], "⑧"),
    ("⑨ 只加一行无关注释(反向对照)", PDG,
     [("_lan_rollback_converge(){", "# (负控的空转对照, 不改变任何行为)\n_lan_rollback_converge(){", 1)], None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-lanconv-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (PDG, CHK)}

    # ── 基线: 未改坏的同一份副本必须全绿 ────────────────────────────────────
    base_fails, base_out = run_suites(wd)
    if base_fails:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每一格的'新增'都算不出来: %s"
            % (len(base_fails), sorted(base_fails)[:2]))
        raise SystemExit(1)
    ok("基线: 两支聚焦测试在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want_kw in MUTATIONS:
        target = Path(wd) / rel
        text = pristine[rel]
        anchored = True
        for anchor, repl, want_hits in edits:
            hits = text.count(anchor)
            if hits != want_hits:
                bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, hits, want_hits))
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

        # 语法门: 语法错造成的红不算"判据抓住了"
        if rel.endswith(".sh"):
            syn = run(["bash", "-n", str(target)])
        else:
            syn = run(["python3", "-m", "py_compile", str(target)])
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)"
                % (label, (syn.stderr or "").strip()[:80]))
            target.write_text(pristine[rel], encoding="utf-8")
            continue

        got, out = run_suites(wd)
        new = got - base_fails
        target.write_text(pristine[rel], encoding="utf-8")

        if want_kw is None:                      # 反向对照
            if new:
                bad("%s: 不该有新失败, 却新增 %d 条 —— 判据在看噪声: %s"
                    % (label, len(new), sorted(new)[:2]))
            else:
                ok("%s: 新增失败 0 条(判据没在看噪声)" % label)
            continue

        if not new:
            bad("%s: **0 条转红** —— 这一格的判据没有牙" % label)
        elif not any(want_kw in n for n in new):
            bad("%s: 转红了但没命中预期判据(%s): %s" % (label, want_kw, sorted(new)[:2]))
        else:
            hit = sorted(n for n in new if want_kw in n)[0]
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:88]))
finally:
    # 正式树逐字节核对。不用 git reset/checkout 还原 —— 那会连带冲掉别的改动。
    drift = [str(p) for p in TOUCHED if sha(p) != before[p]]
    if drift:
        bad("正式树被改动了(负控只该改工作副本): %s" % drift)
    else:
        ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
    for p in TOUCHED:
        if os.stat(p).st_mode != modes[p]:
            bad("正式树文件 mode 变了: %s" % p)

print("-" * 62)
print("lan-rollback-convergence-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

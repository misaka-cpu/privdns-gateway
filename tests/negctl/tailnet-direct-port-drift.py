#!/usr/bin/env python3
"""负控: tailnet 直连端口对账的**证据等级与解析语义**有没有牙。

契约本身钉在 tests/test-tailnet-port-evidence.py 里 —— 那支说"判据应该说什么"。
这一支回答另一个问题: **如果判据退化了, 我们会不会知道?**

做法是逐格把生产代码改坏, 然后看契约测试是否**新增具名失败**。每格五步, 缺一不算有效:

  1. 锚点在整份文件里**恰好命中一次**(多了少了都说明改坏器没打在预期位置);
  2. 替换后原锚点消失、新内容恰好出现一次;
  3. 改坏后 `py_compile` 仍通过(语法错导致的红不算"测试抓住了");
  4. 契约测试的失败集合相对基线**有新增**, 并报出新增了哪几条;
  5. 恢复后 sha256 与 before-image 逐字节一致。

改坏落在**工作副本**里, 正式树一个字节都不动 —— 跑完会核对。

盯的六件事, 每一件都是真机上出过或差点出的:
  ① 读不到 defaults 判绿   —— "没证据"染成"没问题";
  ② 没有 PORT= 判绿        —— 同上, 另一条入口;
  ③ 多重赋值取第一个       —— 正好取到被覆盖掉的那个值, 而且错得很安静;
  ④ 注释里的 PORT= 算数    —— 把一行被注释掉的配置当成现行配置;
  ⑤ 误导文案回潮           —— 让用户以为跑个命令就能跟上自定义端口, 而那条命令做不到;
  ⑥ 只加无关注释           —— 反向对照: 不该产生任何新失败, 否则说明判据在看噪声。
"""
import hashlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOUCHED = ROOT / "deploy/bot/checks.py"
CONTRACT = "tests/test-tailnet-port-evidence.py"

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def failures(wd):
    """跑契约测试, 返回 (失败行集合, 退出码)。"""
    r = subprocess.run([sys.executable, CONTRACT], cwd=wd,
                       capture_output=True, text=True, timeout=180)
    fs = {l.strip() for l in r.stdout.splitlines() if l.startswith("[FAIL]")}
    return fs, r.returncode


def syntax_ok(wd):
    r = subprocess.run([sys.executable, "-m", "py_compile", "deploy/bot/checks.py"],
                       cwd=wd, capture_output=True, text=True, timeout=60)
    return r.returncode == 0


# 每格 = (标签, [(锚点, 替换, 预期命中数), …])。
# 多数格只需一条编辑; ④ 需要两条 —— 注释是**双层防御**: 先 startswith("#") 跳过,
# 再 re.match 行首锚定。两层互为冗余, 单摘一层行为不变(各自实测 0 条转红), 所以要证明
# "注释保护有牙", 必须两层一起摘。冗余本身是好事, 只是它让单锚点负控失效。
MUTATIONS = [
    ("① 读不到 defaults 改回判绿", [
        ('return ("warn", name, unresolved % ("读不到 %s(%s)"',
         'return ("ok", name, unresolved % ("读不到 %s(%s)"', 1)]),
    ("② 没有 PORT= 改回判绿", [
        ('if actual is None:\n        return ("warn", name, unresolved % why)',
         'if actual is None:\n        return ("ok", name, unresolved % why)', 1)]),
    ("③ 多重赋值改成取第一个", [
        ('        port, reason = n, ""',
         '        port, reason = n, ""\n        break', 1)]),
    ("④ 摘掉注释的两层防御(注释里的 PORT= 会被当赋值)", [
        ('if not line or line.startswith("#"):', 'if not line:', 1),
        ('m = re.match(r"^PORT\\s*=\\s*(.*)$", line)',
         'm = re.search(r"PORT\\s*=\\s*(.*)$", line)', 1)]),
    ("⑤ 误导文案回潮", [
        ('"**`pdg ssh-source tailnet` 目前只生成 41641, 跟不了自定义端口。**"',
         '"要么跑一次 `pdg ssh-source tailnet` 让放行跟上。"', 1)]),
    ("⑥ 只加一行无关注释(反向对照, 不该有新失败)", [
        ('def check_tailnet_direct_port():',
         '# (负控的空转对照, 不改变任何行为)\ndef check_tailnet_direct_port():', 1)]),
]

before = sha(TOUCHED)
wd = tempfile.mkdtemp(prefix="pdg-tnp-negctl.")
try:
    for sub in ("deploy/bot", "tests"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    pristine = (Path(wd) / "deploy/bot/checks.py").read_text(encoding="utf-8")

    base_fs, base_rc = failures(wd)
    if base_rc == 0 and not base_fs:
        ok("基线绿: 契约测试 0 失败")
    else:
        bad("基线就不绿(rc=%s, %d 条失败), 后面每一格都无从判断:" % (base_rc, len(base_fs)))
        for f in sorted(base_fs)[:5]:
            print("       " + f[:120])
        raise SystemExit(1)

    for label, edits in MUTATIONS:
        target = Path(wd) / "deploy/bot/checks.py"
        target.write_text(pristine, encoding="utf-8")
        mutated, aborted = pristine, False
        for old, new, want_hits in edits:
            hits = mutated.count(old)
            if hits != want_hits:
                bad("%s → 锚点 %r 命中 %d 次, 预期 %d(改坏器没打在预期位置)"
                    % (label, old[:34], hits, want_hits))
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
            if mutated.count(new) != 1:
                bad("%s → 替换后新内容出现 %d 处, 预期 1" % (label, mutated.count(new)))
                aborted = True
                break
        if aborted:
            continue
        target.write_text(mutated, encoding="utf-8")
        if not syntax_ok(wd):
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            continue
        fs, _rc = failures(wd)
        added = fs - base_fs
        noop = label.startswith("⑥")
        if noop:
            if added:
                bad("%s → 竟然新增了 %d 条失败, 判据在看噪声:" % (label, len(added)))
                for f in sorted(added)[:3]:
                    print("       " + f[:120])
            else:
                ok("%s → 0 条新增(判据不看噪声)" % label)
        elif added:
            ok("%s → 锚点 %d 条全命中, 新增 %d 条具名失败" % (label, len(edits), len(added)))
            for f in sorted(added)[:2]:
                print("       " + f[:118])
        else:
            bad("%s → 锚点命中但**0 条转红**, 负控无效" % label)
    Path(wd, "deploy/bot/checks.py").write_text(pristine, encoding="utf-8")
finally:
    shutil.rmtree(wd, ignore_errors=True)

after = sha(TOUCHED)
if before == after:
    ok("正式树未被污染: deploy/bot/checks.py sha256 一致 (%s…)" % before[:16])
else:
    bad("正式树被改动了! %s → %s" % (before[:16], after[:16]))

print("-" * 62)
print("tailnet-direct-port-drift.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

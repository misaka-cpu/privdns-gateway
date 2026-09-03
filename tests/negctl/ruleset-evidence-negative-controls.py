#!/usr/bin/env python3
"""负控: `check_rulesets` 的证据等级判据有没有牙。

正控在 tests/test-ruleset-evidence.py。这一支回答另一个问题: **如果那些判据退化了,
我们会不会知道?**

为什么需要它: 这条判据关掉的是一句**假绿文案** —— 静态元数据说不出"已被 mihomo 加载",
说了就是替运行期打包票。假绿最容易悄悄回来: 把 warn 改回 ok 只要一个词, 而所有测试如果
只看"有没有返回三元组"就照样绿。所以每一条都要有格盯着。

判据是**正控里新增的具名失败**, 不是退出码 —— 归因要用具名失败集合(HANDOFF §9.15)。

八格:
  ① supported 格式改回 ok        —— 假绿本体;
  ② 把"没读运行期"那句删掉        —— 等级还是 warn, 但读的人不知道它没验什么;
  ③ JSON 损坏改回 None           —— 把无结论说成"没配过";
  ④ .srs 从 fail 降成 warn       —— 明确不兼容降级, 会让 update 在更后面才被挡住;
  ⑤ 拿配置文件存在冒充已加载      —— 文件在 ≠ provider 被加载, 典型的证据替换;
  ⑥ 偷加一个对 9090 的 HTTP 请求  —— 本项不该碰运行期管理面;
  ⑦ 网络失败时回落成 ok          —— fail-open, 最坏的一种;
  ⑧ 只加无关注释(反向对照)       —— 不该产生任何新失败。
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
CHK = "deploy/bot/checks.py"
TOUCHED = [ROOT / CHK]

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=600)


def failures(out):
    """具名失败集合。正控用 '  ✗ ' 前缀, 完整性测试用 '[FAIL] '。"""
    s = set()
    for l in out.splitlines():
        t = l.strip()
        if t.startswith("✗ ") or t.startswith("[FAIL]"):
            s.add(re.sub(r"\s+", " ", t)[:150])
    return s


T_EV = ["python3", "tests/test-ruleset-evidence.py"]
T_IN = ["python3", "tests/test-ruleset-integrity.py"]

WARN_RET = '''    return ("warn", name, "%d 个: 静态元数据里未发现已知不兼容格式。"
                          "但本项**没有读取 mihomo 运行期 provider 状态**, 因此不能证明这些规则"
                          "已经被加载、下载成功或解析出条目 —— 只说明形态上没问题。" % len(meta))'''
JSON_FAIL = '''    except Exception:  # noqa: BLE001'''
SRS_FAIL = '''        return ("fail", name, "这些是 sing-box 二进制 .srs, mihomo 读不了 → 分流不会生效, "'''

MUT = [
    ("① supported 格式改回 ok(假绿本体)",
     [(WARN_RET, WARN_RET.replace('("warn", name,', '("ok", name,', 1), 1)], [T_EV, T_IN]),
    ("② 删掉「没读运行期」那句(等级还在, 读的人却不知道没验什么)",
     [('"但本项**没有读取 mihomo 运行期 provider 状态**, 因此不能证明这些规则"\n'
       '                          "已经被加载、下载成功或解析出条目 —— 只说明形态上没问题。" % len(meta))',
       '"" % len(meta))', 1)], [T_EV]),
    ("③ JSON 损坏改回 None(把无结论说成没配过)",
     [('        return ("fail", name, "%s 解析不了(不是合法 JSON)—— 规则集元数据损坏, "',
       '        return None  # 变异\n        return ("fail", name, "%s 解析不了(不是合法 JSON)—— 规则集元数据损坏, "',
       1)], [T_EV]),
    ("④ .srs 从 fail 降成 warn",
     [(SRS_FAIL, SRS_FAIL.replace('("fail", name,', '("warn", name,', 1), 1)], [T_EV, T_IN]),
    ("⑤ 拿配置文件存在冒充 provider 已加载",
     [(WARN_RET,
       '    import os as _os\n'
       '    if _os.path.exists("/etc/mihomo/config.yaml"):\n'
       '        return ("ok", name, "%d 个, 配置文件在 → 视为已加载" % len(meta))\n' + WARN_RET, 1)],
     [T_EV, T_IN]),
    ("⑥ 偷加一个对 9090 的 HTTP 请求",
     [(WARN_RET,
       '    import urllib.request as _u\n'
       '    try:\n'
       '        _u.urlopen("http://127.0.0.1:9090/providers/rules", timeout=1)\n'
       '    except Exception:\n'
       '        pass\n' + WARN_RET, 1)], [T_EV]),
    ("⑦ 网络失败时回落成 ok(fail-open)",
     [(WARN_RET,
       '    import urllib.request as _u\n'
       '    try:\n'
       '        _u.urlopen("http://127.0.0.1:9090/providers/rules", timeout=1)\n'
       '    except Exception:\n'
       '        return ("ok", name, "%d 个(探测失败, 按通过处理)" % len(meta))\n' + WARN_RET, 1)],
     [T_EV]),
    ("⑧ 只加一行无关注释(反向对照, 不该有新失败)",
     [("def check_rulesets():", "# (负控的空转对照, 不改变任何行为)\ndef check_rulesets():", 1)],
     [T_EV, T_IN]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-rsev-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    target = Path(wd) / CHK
    pristine = target.read_text(encoding="utf-8")

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd)
            out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_EV, T_IN])
    if not base:
        ok("基线绿: 两支正控在未改坏的副本上 0 条具名失败")
    else:
        bad("基线就不绿(%d 条), 后面每一格都无从判断:" % len(base))
        for f in sorted(base)[:4]:
            print("       " + f[:130])
        raise SystemExit(1)

    for label, edits, targets in MUT:
        mutated, aborted = pristine, False
        for old, new, want in edits:
            hits = mutated.count(old)
            if hits != want:
                bad("%s → 锚点命中 %d 次, 预期 %d(改坏器没打在预期位置)" % (label, hits, want))
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
            if new and new not in mutated:
                bad("%s → 替换内容没落进文件里" % label)
                aborted = True
                break
        if aborted:
            continue
        target.write_text(mutated, encoding="utf-8")
        syn = run(["python3", "-m", "py_compile", str(target)], cwd=wd)
        if syn.returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            target.write_text(pristine, encoding="utf-8")
            continue
        added = suite(targets) - base
        target.write_text(pristine, encoding="utf-8")

        if label.startswith("⑧"):
            (ok if not added else bad)(
                "%s → %d 条新增(应为 0)" % (label, len(added)))
            continue
        if added:
            ok("%s → 新增具名失败 %d 条" % (label, len(added)))
            print("       " + sorted(added)[0][:128])
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = True
for p in TOUCHED:
    if sha(p) != before[p]:
        bad("正式树被改动了! %s" % p.name); clean = False
    if os.stat(p).st_mode != modes[p]:
        bad("正式树权限位变了! %s" % p.name); clean = False
if clean:
    ok("正式树未被污染: checks.py sha256 与 mode 均一致")

print("-" * 62)
print("ruleset-evidence-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

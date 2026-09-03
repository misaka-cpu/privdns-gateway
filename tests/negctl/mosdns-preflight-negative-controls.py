#!/usr/bin/env python3
"""负控: mosdns 前置预检与 E2E 夹具契约这两组判据有没有牙。

被盯的是三个文件 —— pdg.sh 的更新前预检、checks.py 的 doctor 分级、lib/versions.sh 的
严格判据; 外加 tests/e2e-lib.sh 与 tests/e2e-install.sh 这两份夹具。这一支回答的是
另一个问题: **如果它们退化了, 我们会不会知道?**

做法与本目录其它负控一致: 逐格把代码改坏(只改沙箱副本, 正式树一个字节不动), 再跑对应的
聚焦测试, 看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本, 必须全绿。

每格五步, 缺一不算有效:
  · 锚点在整份文件里**恰好命中**预期次数;
  · 替换确实落进了文件;
  · 改坏后语法门仍过(bash -n / py_compile)—— 语法错造成的红不算"判据抓住了";
  · 失败集合有**具名新增**(0 条转红 = 这一格无效, 判 FAIL);
  · 恢复后正式树 sha256 与 mode 逐字节一致。

七格:
  ① 删掉更新前的完整性预检      —— 回到"做完一遍再回滚"的循环
  ② 把预检挪到快照之后          —— 位置错了等于没有(副作用已经发生)
  ③ 缺文件从 fail 降成 warn     —— doctor 不再把"核心文件不在"当故障
  ④ check_mosdns_binary 移出 ALL —— 判据还在, 但永远不会跑
  ⑤ shell 假桩重新被接受        —— 短路只比自报版本, 内容无人管
  ⑥ 摘掉 SHA256 那一步          —— 判据只剩版本
  ⑦ 更新后判红不再回滚          —— 那道安全门被放松
  ⑧ 只加一行无关注释            —— 反向对照, 不该有任何新失败
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
CHK = "deploy/bot/checks.py"
VER = "lib/versions.sh"
ELIB = "tests/e2e-lib.sh"
EINS = "tests/e2e-install.sh"
TOUCHED = [ROOT / f for f in (PDG, CHK, VER, ELIB, EINS)]

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
        t = re.sub(r"\b[0-9a-f]{7,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


T_PRE = ["bash", "tests/test-update-mosdns-preflight.sh"]
T_FIX = ["python3", "tests/test-e2e-mosdns-fixture.py"]
T_MOS = ["python3", "tests/test-mosdns-binary-evidence.py"]
T_REL = ["bash", "tests/test-update-release-relation.sh"]
T_NOX = ["bash", "tests/test-update-preflight-no-exec.sh"]


def suite(wd, cmds):
    out = ""
    for c in cmds:
        r = run(c, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


# 重排后诊断路径的两段: 先证内容, 再执行。⑨ 把它们对调, 于是又变成"先跑再说"。
SHA_GATE = '''    local got_sha
    got_sha="$(sha256sum "$bin" 2>/dev/null | awk '{print $1}')"
    [[ -n "$got_sha" ]]                 || exit 8   # 算不出摘要
    [[ "$got_sha" == "${PDG_SHA256[mosdns-bin-$march]}" ]] || exit 6   # 内容不是官方那一份
'''
EXEC_GATE = '''    # ── 内容已经证明过, 此时执行它是安全的 ────────────────────────────────
    # 能走到这里说明摘要相符而判据仍然失败, 所以问题一定出在 version 那一层。
    local got_ver
    got_ver="$("$bin" version 2>/dev/null)" || exit 3   # version 命令非零
    got_ver="${got_ver%%$'\\n'*}"
    [[ "$got_ver" =~ ([0-9]+\\.[0-9]+\\.[0-9]+) ]] || exit 4   # 输出里读不出版本
    [[ "${BASH_REMATCH[1]}" == "${MOSDNS_VER#v}" ]] || exit 5  # 钉值与资产自相矛盾
'''
PRE_CALL = '''      if [[ "$_rel" == behind ]] && ! _update_mosdns_preflight; then
        return 1
      fi
'''
MUT = [
    ("① 删掉更新前的完整性预检", PDG, [(PRE_CALL, "", 1)], [T_PRE]),
    # 位置错了等于没有: 副作用已经发生, 剩下的只是"做完再退回来"
    ("② 把预检挪到快照之后", PDG,
     [(PRE_CALL, "", 1),
      ('  c_g "更新前留快照…"\n',
       '  c_g "更新前留快照…"\n  _update_mosdns_preflight || return 1\n', 1)], [T_PRE]),
    ("③ 缺文件从 fail 降成 warn", CHK,
     [('        # mosdns 是必需运行组件: 它的二进制读不到不是"存疑", 是这台机器有问题。\n'
       '        return ("fail", name, "读不到 %s(%s)" % (b, e.strerror or e.errno))',
       '        return ("warn", name, "读不到 %s(%s)" % (b, e.strerror or e.errno))', 1)],
     [T_MOS]),
    ("④ check_mosdns_binary 移出 ALL", CHK,
     [("check_mosdns_version, check_mosdns_binary,", "check_mosdns_version,", 1)], [T_MOS]),
    # 锚点带上 mosdns 独有的 `"$bin" version`: 摘要段两个内核逐字相同, 只取它会命中 2 次。
    ("⑤ shell 假桩重新被接受(短路只比自报版本)", VER,
     [('  got="$(sha256sum "$bin" 2>/dev/null | awk \'{print $1}\')"\n'
       '  [[ -n "$got" && "$got" == "$exp" ]] || return 1\n'
       '  # 顺带补上一处一直没跟上的不对称: 原来这里是 `$("$bin" version | head -1)`, 退出码取的是\n'
       '  # head 的、永远为 0 —— 与 mihomo 那边 v1.11.7 已经修掉的形态一样。改成不经管道取首行。\n'
       '  got="$("$bin" version 2>/dev/null)" || return 1   # 退出码必须是 0',
       '  got="$("$bin" version 2>/dev/null)" || return 1', 1)], [T_MOS, T_FIX]),
    ("⑥ 摘掉预检里的 SHA256 裁决", PDG,
     [('    pdg_mosdns_binary_ok "$march" "$MOSDNS_VER" "$bin" && exit 0',
       '    [[ -x "$bin" ]] && exit 0', 1)], [T_PRE]),
    # 变异要真的把回滚拿掉。第一版只替换了那句提示文案, 而下一行的 cmd_rollback 照跑 ——
    # 于是"新增失败 0 条", 看着像判据没牙, 实际是变异没打中(负控自己空转了)。
    ("⑦ 更新后判红不再回滚", PDG,
     [('    c_y "自检发现 $nfail 项失败, 回滚到更新前快照:"\n'
       "    sed -n '2,/^@@WARN@@$/p' <<<\"$summary\" | sed '/^@@WARN@@$/d'\n"
       '    cmd_rollback --dir "$snap_dir" --git "$pre_sha"; return 1',
       '    c_y "自检发现 $nfail 项失败(变异: 不回滚)"\n'
       '    return 1', 1)],
     [T_PRE]),
    # ── 以下八格盯的是重排后的诊断顺序: 摘要没过之前一次都不执行候选文件 ──────────
    # 这一段过去为了分辨"版本漂移"又跑了两次 `"$bin" version`, 判据挡在门外的文件被诊断
    # 请了进来。判据是 marker(它真的被跑起来过没有), 不是源码形状 —— 换个写法照样能执行。
    ("⑨ 把 version 调用重新移到摘要之前", PDG,
     [(SHA_GATE + EXEC_GATE, EXEC_GATE + SHA_GATE, 1)], [T_NOX]),
    ("⑩ 摘要不符时再执行一次候选文件", PDG,
     [('    [[ "$got_sha" == "${PDG_SHA256[mosdns-bin-$march]}" ]] || exit 6',
       '    if [[ "$got_sha" != "${PDG_SHA256[mosdns-bin-$march]}" ]]; then\n'
       '      "$bin" version >/dev/null 2>&1; exit 6\n    fi', 1)], [T_NOX]),
    ("⑪ 摘要不符改成放行", PDG,
     [('    [[ "$got_sha" == "${PDG_SHA256[mosdns-bin-$march]}" ]] || exit 6',
       '    [[ "$got_sha" == "${PDG_SHA256[mosdns-bin-$march]}" ]] || exit 0', 1)], [T_NOX, T_PRE]),
    ("⑫ 恢复 rc=5 自动放行(自报版本不符就当版本漂移)", PDG,
     [('  [[ "$rc" == 0 ]] && return 0\n',
       '  [[ "$rc" == 0 ]] && return 0\n  [[ "$rc" == 5 ]] && { c_g "更新前自检: 本次更新会把它收敛到钉死版。"; return 0; }\n',
       1)], [T_NOX, T_PRE]),
    ("⑬ 忽略 version 命令的退出码", PDG,
     [('    got_ver="$("$bin" version 2>/dev/null)" || exit 3   # version 命令非零',
       '    got_ver="$("$bin" version 2>/dev/null)"   # 变异: 不看退出码', 1)], [T_NOX]),
    ("⑭ 只比版本字符串, 不比摘要", PDG,
     [(SHA_GATE, '    local got_sha=""\n', 1)], [T_NOX, T_PRE]),
    ("⑮ 摘要相符之后不再验证版本", PDG,
     [('    [[ "${BASH_REMATCH[1]}" == "${MOSDNS_VER#v}" ]] || exit 5  # 钉值与资产自相矛盾',
       '    :  # 变异: 摘要过了就不再看版本', 1)], [T_NOX]),
    ("⑯ 摘掉「没动任何文件」的副作用说明", PDG,
     [('  echo "  没动任何文件: 未建快照, 未 reset, 未装文件, 未迁移, 未重启服务。"\n', "", 1)],
     [T_NOX]),
    ("⑧ 只加一行无关注释(反向对照)", PDG,
     [("_update_mosdns_preflight(){",
       "# (负控的空转对照, 不改变任何行为)\n_update_mosdns_preflight(){", 1)],
     [T_PRE, T_FIX, T_MOS, T_REL]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-mospre-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT / "install.sh", Path(wd) / "install.sh")
    os.makedirs(Path(wd) / ".github/workflows", exist_ok=True)
    shutil.copy2(ROOT / ".github/workflows/ci.yml", Path(wd) / ".github/workflows/ci.yml")
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8")
                for rel in (PDG, CHK, VER, ELIB, EINS)}

    print("══ 基线(未改坏的同一份副本)══")
    base = {}
    for tag, cmds in (("pre", [T_PRE]), ("fix", [T_FIX]), ("mos", [T_MOS]), ("rel", [T_REL])):
        base[tag] = suite(wd, cmds)
        (ok if not base[tag] else bad)("基线 %s 全绿(失败 %d)" % (tag, len(base[tag])))
    base_all = set().union(*base.values())
    if base_all:
        bad("基线不绿 —— 后面每一格的「新增」都算不出来, 本轮负控结果不可信")
        for f in sorted(base_all)[:4]:
            print("       %s" % f[:150])

    for tag, rel, edits, cmds in MUT:
        print()
        print("── %s ──" % tag)
        text = pristine[rel]
        good = True
        for anchor, repl, want in edits:
            hits = text.count(anchor)
            print("   锚点命中 %d 次(期望 %d)" % (hits, want))
            if hits != want:
                bad("%s: 锚点命中 %d 次, 期望 %d —— 产品换写法了, 这一格没测到东西"
                    % (tag, hits, want))
                good = False
                break
            text = text.replace(anchor, repl, want)
        if not good:
            continue
        (Path(wd) / rel).write_text(text, encoding="utf-8")
        if (Path(wd) / rel).read_text(encoding="utf-8") == pristine[rel]:
            bad("%s: 替换没落进文件" % tag)
            (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
            continue
        syn = (run(["bash", "-n", rel], cwd=wd) if rel.endswith(".sh")
               else run(["python3", "-m", "py_compile", rel], cwd=wd))
        print("   语法门: %s" % ("过" if syn.returncode == 0 else "不过"))
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 语法错造成的红不算判据抓住了(%s)"
                % (tag, (syn.stderr or "").strip()[:120]))
            (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
            continue
        got = set()
        for c in cmds:
            got |= suite(wd, [c])
        newf = got - base_all
        if tag.startswith("⑧"):
            (ok if not newf else
             bad)("反向对照: 无关注释新增失败 %d 条(应为 0)%s"
                  % (len(newf), (" —— " + "; ".join(sorted(newf))[:160]) if newf else ""))
        else:
            (ok if newf else
             bad)("%s → 新增具名失败 %d 条%s"
                  % (tag, len(newf), (": " + sorted(newf)[0][:110]) if newf else " —— 0 条转红, 这一格无效"))
        (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
finally:
    shutil.rmtree(wd, ignore_errors=True)

print()
print("══ 正式树逐字节恢复 ══")
for p in TOUCHED:
    (ok if sha(p) == before[p] else bad)("%s sha256 未变" % Path(p).name)
    (ok if os.stat(p).st_mode == modes[p] else bad)("%s mode 未变" % Path(p).name)

print("-" * 62)
print("mosdns-preflight-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

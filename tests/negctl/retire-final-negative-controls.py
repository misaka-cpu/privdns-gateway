#!/usr/bin/env python3
"""退役最终候选(2026-10-24)四项修复的反向对照: S-1、S-2 两处、S-5、S-6。

每个变异只在 deploy/bot/pdg.sh 的副本上做一处替换(原文必须恰好出现一次, 否则该变异记 INVALID),
然后在副本树里跑登记的那一支测试, 按 "[FAIL] <名>:" 收集变红的格, 与登记的集合**逐个相等**才算
AS_EXPECTED —— 多红、少红都是 MISMATCH。先跑一次不变异的基线: 三支都必须全绿, 否则后面的结论无效。
测试自己没跑完(没有末尾的"通过 N, 失败 M", 或 M 与 [FAIL] 行数对不上, 或报了"未执行")记 INVALID,
不拿它的"表现"下结论。

不改仓库本身; 副本放在临时目录, 结束后删除。按项目惯例 tests/negctl/ 是本地手动门, 不进 CI。
用法: python3 -I -B tests/negctl/retire-final-negative-controls.py [--out <留证目录>] [--only <变异名>]...
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG_REL = os.path.join("deploy", "bot", "pdg.sh")
GATE = "tests/test-migrate-caller-gate.sh"
PLAT = "tests/test-platform-fail-restore.sh"
SETTLE = "tests/test-dotwitness-settle.sh"


def cut(s, start, end):
    """返回 s 里从 start 起、到 end(含)为止的那一段; start 必须恰好出现一次, end 取其后的第一处。"""
    if s.count(start) != 1:
        raise ValueError("起点出现 %d 次: %r" % (s.count(start), start[:60]))
    i = s.index(start)
    j = s.index(end, i) + len(end)
    return s[i:j]


S1_BLOCK = ("    inactive/4)\n", "      fi;;\n")
SW_BLOCK = ("      # 写回与重新应用各自看结果(原来 `|| true` 吞掉重新应用的失败", "      fi\n    fi\n")
PLAT_BLOCK = ("        nftables.conf)\n          # 写回与重新加载各自看结果", "          fi;;\n")


def m_s1_drop(s):
    return s.replace(cut(s, *S1_BLOCK), "", 1)


def m_s1_exit4_alone(s):
    return s.replace(cut(s, *S1_BLOCK), "    inactive/4) ;;\n", 1)


def m_plat_swallow(s):
    old = cut(s, *PLAT_BLOCK)
    new = ('        nftables.conf) [[ -e "$wd/$g" ]] && { cp -a "$wd/$g" /etc/nftables.conf; '
           '_nft_apply_main >/dev/null 2>&1 || true; };;\n')
    return s.replace(old, new, 1)


def m_sw_swallow(s):
    old = cut(s, *SW_BLOCK)
    new = ('      cp -a "$bak" /etc/nftables.conf 2>/dev/null\n'
           '      _nft_apply_main >/dev/null 2>&1 || true\n'
           '      echo "应用新防火墙失败 → 已还原并重新应用原配置"\n'
           '    fi\n')
    return s.replace(old, new, 1)


def exact(old, new):
    def f(s):
        if s.count(old) != 1:
            raise ValueError("原文出现 %d 次: %r" % (s.count(old), old[:60]))
        return s.replace(old, new, 1)
    return f


MUTATIONS = [
    # ── S-1: _retire_work_pending 的 inactive/4 ─────────────────────────────
    # 整段删掉之后 inactive/4 落进通配分支: 仍返回 2, 但理由变了 —— IA2 / IA3 / IA5 也核理由里只有新分支才写的字, 一并变红。
    ("s1_drop_inactive4", GATE, m_s1_drop, {"IA1", "IA2", "IA3", "IA4", "IA5"}),
    ("s1_exit4_alone", GATE, m_s1_exit4_alone, {"IA2", "IA3", "IA5"}),
    ("s1_failed4_too", GATE, exact("    inactive/4)\n", "    inactive/4|failed/4)\n"), {"IA6"}),
    # ── S-2: _plat_rollback 与 _switchcore_nft ───────────────────────────────
    ("plat_nft_swallow", PLAT, m_plat_swallow, {"NF4", "NF5", "NF6", "NF8"}),
    ("sw_nft_swallow", PLAT, m_sw_swallow, {"SW2", "SW3", "SW4"}),
    ("sw_restore_unchecked", PLAT,
     exact('      if ! cp -a "$bak" /etc/nftables.conf 2>/dev/null || ! cmp -s "$bak" /etc/nftables.conf; then\n',
           '      cp -a "$bak" /etc/nftables.conf 2>/dev/null; if false; then\n'), {"SW3"}),
    # ── S-5: dw-settle 的时限 ───────────────────────────────────────────────
    ("settle_show_direct", SETTLE,
     exact('  raw="$(_dws_t 10 systemctl show pdg-dotwitness -p LoadState',
           '  raw="$(systemctl show pdg-dotwitness -p LoadState'), {"TO1", "TO6", "TO6b", "TO7", "TO*"}),
    ("settle_no_budget", SETTLE,
     exact("  (( left > 0 )) || return 124\n  (( left < cap )) && cap=$left\n", "  :\n"), {"TO6", "TO6b"}),
    ("settle_no_kill_grace", SETTLE, exact('  timeout -k 2 "$cap" "$@"\n', '  timeout "$cap" "$@"\n'), {"TO8"}),
    ("settle_start_124_generic", SETTLE,
     exact('    if (( r == 124 )); then c_y "  ⚠️  DoT 证据端: $h; 定向恢复: reset-failed 退出 0, start 超出本步时限(退出 124), '
           '启动任务是否仍在进行未取得; 不再重试。"; return 0; fi\n', ""), {"TO3"}),
    ("settle_reset_rc_plain", SETTLE,
     exact('定向恢复的 reset-failed $(_dws_rcw "$r"), 未执行 start', '定向恢复的 reset-failed 退出 $r, 未执行 start'), {"TO2"}),
    # ── S-6: 混合监听 ───────────────────────────────────────────────────────
    ("settle_mixed_owned", SETTLE,
     exact('  if (( match )); then\n    [[ -z "$d_saw" ]] && return 0\n    return 3\n  fi\n', "  (( match )) && return 0\n"),
     {"O3", "O3m", "O3r", "O3t", "H*/O*"}),
    ("settle_mixed_as_foreign", SETTLE,
     exact('    [[ -z "$d_saw" ]] && return 0\n    return 3\n', '    [[ -z "$d_saw" ]] && return 0\n    return 2\n'),
     {"O3", "O3m", "O3r"}),
]

FAIL_RE = re.compile(r"^\[FAIL\] (.+?)[:：]")
SUM_RE = re.compile(r"^通过 (\d+), 失败 (\d+)")


def make_tree(base):
    tree = os.path.join(base, "tree")
    for d in ("deploy", "lib", "tests"):
        src = os.path.join(ROOT, d)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(tree, d), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    return tree


def run_test(tree, test, base, tag):
    tmp = os.path.join(base, "tmp-" + tag)
    home = os.path.join(base, "home-" + tag)
    os.mkdir(tmp)
    os.mkdir(home)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home, "TMPDIR": tmp, "LANG": "C.UTF-8",
           "PDG_TEST_STRICT": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    try:
        r = subprocess.run(["bash", test], cwd=tree, env=env, capture_output=True, text=True, timeout=900)
        out, rc = r.stdout + r.stderr, r.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = ((e.stdout or "") if isinstance(e.stdout, str) else "") + "\n[驱动] 超时 900 s", 124
    red = set()
    nfail_lines = 0
    summary = None
    for line in out.splitlines():
        m = FAIL_RE.match(line)
        if m:
            red.add(m.group(1).strip())
            nfail_lines += 1
        m = SUM_RE.match(line)
        if m:
            summary = (int(m.group(1)), int(m.group(2)))
    valid = summary is not None and summary[1] == nfail_lines and "[未执行]" not in out
    leftover = sorted(os.listdir(tmp))
    return {"rc": rc, "red": red, "summary": summary, "valid": valid, "out": out, "tmp_left": leftover}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="留证目录(必须不存在)")
    ap.add_argument("--only", action="append", default=[])
    a = ap.parse_args()
    if a.out:
        os.mkdir(a.out)
    base = tempfile.mkdtemp(prefix="pdg-negctl-retire-final.")
    lines = []

    def emit(s):
        print(s, flush=True)
        lines.append(s)

    def keep(name, res):
        if a.out:
            with open(os.path.join(a.out, name + ".out"), "w", encoding="utf-8") as f:
                f.write(res["out"])

    ok_all = True
    try:
        pristine = open(os.path.join(ROOT, PDG_REL), encoding="utf-8").read()
        # 基线
        tree = make_tree(os.path.join(base, "baseline"))
        for t in (GATE, PLAT, SETTLE):
            tag = "baseline-" + os.path.basename(t)
            res = run_test(tree, t, os.path.join(base, "baseline"), tag)
            keep(tag, res)
            good = res["valid"] and res["rc"] == 0 and not res["red"]
            emit("BASELINE %s rc=%s summary=%s red=%s tmp_left=%d %s" % (
                t, res["rc"], res["summary"], sorted(res["red"]), len(res["tmp_left"]), "GREEN" if good else "NOT_GREEN"))
            ok_all &= good
        if not ok_all:
            emit("NEGCTL_ALL INVALID baseline_not_green")
            return 2
        n = 0
        for name, test, fn, want in MUTATIONS:
            if a.only and name not in a.only:
                continue
            n += 1
            d = os.path.join(base, "m-" + name)
            os.mkdir(d)
            try:
                mutated = fn(pristine)
            except ValueError as e:
                emit("MUT %s INVALID 变异不适用: %s" % (name, e))
                ok_all = False
                continue
            if mutated == pristine:
                emit("MUT %s INVALID 变异后与原文相同" % name)
                ok_all = False
                continue
            tree = make_tree(d)
            with open(os.path.join(tree, PDG_REL), "w", encoding="utf-8") as f:
                f.write(mutated)
            if subprocess.run(["bash", "-n", os.path.join(tree, PDG_REL)]).returncode != 0:
                emit("MUT %s INVALID 变异后 bash -n 不过" % name)
                ok_all = False
                continue
            res = run_test(tree, test, d, name)
            keep("mut-" + name, res)
            if not res["valid"]:
                verdict = "INVALID"
            elif res["red"] == want:
                verdict = "AS_EXPECTED"
            else:
                verdict = "MISMATCH"
            ok_all &= verdict == "AS_EXPECTED"
            emit("MUT %s test=%s rc=%s summary=%s red=%s want=%s extra=%s missing=%s %s" % (
                name, test, res["rc"], res["summary"], sorted(res["red"]), sorted(want),
                sorted(res["red"] - want), sorted(want - res["red"]), verdict))
        emit("NEGCTL_ALL %s mutations=%d" % ("AS_EXPECTED" if ok_all else "NOT_AS_EXPECTED", n))
        return 0 if ok_all else 1
    finally:
        if a.out:
            with open(os.path.join(a.out, "VERDICTS.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""D5 四项修复(2026-10-25)的反向对照: .scbak 残留、pdg migrate 的审计标签与提示、三处快照失败原因、drop-singbox 门的措辞。

每个变异只在 deploy/bot/pdg.sh 的副本上做一处替换(原文必须恰好出现一次, 否则该变异记 INVALID),
然后在副本树里跑登记的那一支测试, 按 "[FAIL] <名>:" 收集变红的格, 与登记的集合**逐个相等**才算
AS_EXPECTED —— 多红、少红都是 MISMATCH。先跑一次不变异的基线: 四支都必须全绿, 否则后面的结论无效。
测试自己没跑完(没有末尾的"通过 N, 失败 M", 或 M 与 [FAIL] 行数对不上, 或报了"未执行")记 INVALID,
不拿它的"表现"下结论。

test-migrate-drop-singbox.sh 要钉死版 mihomo: 环境里有 PDG_TEST_MIHOMO 就原样传给它, 驱动自己不取件。
不改仓库本身; 副本放在 tmpguard 登记的临时目录, 结束后删除(PDG_KEEP_TMP=1 时按 tmpguard 的约定保留)。按项目惯例 tests/negctl/ 是本地手动门, 不进 CI。
用法: python3 -I -B tests/negctl/d5-negative-controls.py [--out <留证目录>] [--only <变异名>]...
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import tmpguard  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG_REL = os.path.join("deploy", "bot", "pdg.sh")
DROP = "tests/test-migrate-drop-singbox.sh"
TIMING = "tests/test-migration-timing.sh"
FAULTS = "tests/test-update-faults.sh"
PLAT = "tests/test-platform-fail-restore.sh"

NOTE = ('    c_y "  注意: 本次迁移链里排在这一步之前的迁移已经执行过, 不在上面这句话的范围内; '
        '经 pdg update 进来时, 随后会按更新前快照回滚。"\n')
GATE2_HOW = '    c_y "  怎么办: 用 root 重试 sudo pdg update; 若本机确无 nftables, 请先装好 nftables 再迁移。"\n'
GATE0_HOW = '    c_y "          再重试 sudo pdg update。这一步没有动内核、防火墙与 sing-box。"\n'


def exact(old, new):
    def f(s):
        if s.count(old) != 1:
            raise ValueError("原文出现 %d 次: %r" % (s.count(old), old[:60]))
        return s.replace(old, new, 1)
    return f


def quiet(op):
    return exact('cmd_snapshot --source cli --op %s >"${_snl:-/dev/null}" 2>&1' % op,
                 'cmd_snapshot --source cli --op %s >/dev/null 2>&1' % op)


MUTATIONS = [
    # ── 1 .scbak: 先删旧备份, 每条返回路径都删 ─────────────────────────────
    # 不先删: 本次 cp 失败时旧备份留着, nft 失败路径拿它写回 —— 只有 10 变红(10b 照旧由 nft 路径的删除保住)。
    ("scbak_no_prerm", DROP,
     exact("  rm -f /etc/nftables.conf.scbak\n  cp /etc/nftables.conf /etc/nftables.conf.scbak 2>/dev/null\n",
           "  cp /etc/nftables.conf /etc/nftables.conf.scbak 2>/dev/null\n"), {"10"}),
    ("scbak_keep_download", DROP,
     exact('then rm -rf "$t"; rm -f /etc/nftables.conf.scbak; echo "❌ mihomo 下载/校验失败',
           'then rm -rf "$t"; echo "❌ mihomo 下载/校验失败'), {"9b"}),
    # 渲染拒绝与渲染异常走同一条返回路径。
    ("scbak_keep_render", DROP,
     exact('/etc/privdns-gateway/backend; rm -f /etc/nftables.conf.scbak\n'
           '    echo "❌ 未迁移(已回滚标记): ${why:-',
           '/etc/privdns-gateway/backend\n'
           '    echo "❌ 未迁移(已回滚标记): ${why:-'), {"1d", "2d"}),
    ("scbak_keep_t", DROP,
     exact('/etc/privdns-gateway/backend; rm -f /etc/nftables.conf.scbak\n'
           '    echo "❌ 未迁移(已回滚标记): mihomo 配置校验失败:"',
           '/etc/privdns-gateway/backend\n'
           '    echo "❌ 未迁移(已回滚标记): mihomo 配置校验失败:"'), {"3b"}),
    ("scbak_keep_nft", DROP,
     exact('_nft_apply_main; }; rm -f /etc/nftables.conf.scbak; echo "❌ nft 应用失败',
           '_nft_apply_main; }; echo "❌ nft 应用失败'), {"4d"}),
    # ── 4 drop-singbox 门的措辞 ─────────────────────────────────────────────
    ("gate2_old_wording", DROP,
     exact("中止迁移到 mihomo(这一步还没有动内核、防火墙与 sing-box)。", "中止迁移(现场未做任何改动)。"), {"2c3"}),
    ("gate0_old_wording", DROP,
     exact("再重试 sudo pdg update。这一步没有动内核、防火墙与 sing-box。",
           "再重试 sudo pdg update。现场未做任何改动, sing-box 仍在正常运行。"), {"2b3"}),
    ("gate2_note_dropped", DROP, exact(GATE2_HOW + NOTE, GATE2_HOW), {"2c3"}),
    ("gate0_note_dropped", DROP, exact(GATE0_HOW + NOTE, GATE0_HOW), {"2b3"}),
    # ── 2 pdg migrate 的审计标签与提示 ──────────────────────────────────────
    ("migrate_label_old", TIMING,
     exact('_tx_audit cli migrate FAILED "snapshot=$snap rollback=not-attempted"',
           '_tx_audit cli migrate ROLLBACK_FAILED "snapshot=$snap"'), {"3d"}),
    ("migrate_msg_old", TIMING,
     exact('c_y "❌ 迁移失败, 本命令没有自动回滚。快照仍在: $snap"', 'c_y "❌ 迁移失败。快照仍在: $snap"'), {"3e"}),
    # ── 3 三处快照失败原因: 只把输出改回丢弃, 其余原样 ─────────────────────
    ("migrate_snap_quiet", TIMING, quiet("migrate"), {"3a2"}),
    ("update_snap_quiet", FAULTS, quiet("update"), {"S1"}),
    ("platform_snap_quiet", PLAT, quiet("platform"), {"PS2"}),
]

FAIL_RE = re.compile(r"^\[FAIL\] (.+?)[:：]")
SUM_RE = re.compile(r"^通过 (\d+), 失败 (\d+)")


def make_tree(base):
    tree = os.path.join(base, "tree")
    for d in ("deploy", "lib", "tests"):
        src = os.path.join(ROOT, d)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(tree, d), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".bin"))
    return tree


def run_test(tree, test, base, tag):
    tmp = os.path.join(base, "tmp-" + tag)
    home = os.path.join(base, "home-" + tag)
    os.mkdir(tmp)
    os.mkdir(home)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home, "TMPDIR": tmp, "LANG": "C.UTF-8",
           "PDG_TEST_STRICT": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    if os.environ.get("PDG_TEST_MIHOMO"):
        env["PDG_TEST_MIHOMO"] = os.environ["PDG_TEST_MIHOMO"]
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
    base = tmpguard.mkdtemp(prefix="pdg-negctl-d5.")
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
        for t in (DROP, TIMING, FAULTS, PLAT):
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
        tmpguard.cleanup(base)


if __name__ == "__main__":
    sys.exit(main())

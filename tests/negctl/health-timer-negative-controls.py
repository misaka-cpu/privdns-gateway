#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
# 健康自检定时器那组判据的负控: 每条**就地撤掉一处修复**, 跑对应判据, 要求它转红,
# 然后逐字节还原。0 条转红一律判无效 —— 那说明没有任何判据在盯着它。
#
# 规矩(踩出来的):
#   · 改哪个文件, 哪个文件就必须在 TOUCHED 里。不在名单 = 不备份 = 跑完不还原。
#   · 不用 git reset/checkout/clean 还原 —— 那会连带冲掉别的改动。备份 + sha256 核对。
#   · 语法错、测试崩溃不算红灯, harness 自己判掉。
#   · 真 systemd 那几条要 root + systemd; 环境不具备时**记为未验**, 不算有效负控。
# ─────────────────────────────────────────────────────────────────────────────
import hashlib
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清(PDG_KEEP_TMP=1 留现场)

BAK = tmpguard.mkdtemp(prefix="negctl-timer.")

TOUCHED = [
    "deploy/bot/pdg-health.timer",
    "deploy/bot/pdg.sh",
    "deploy/bot/checks.py",
]
SHA = {}
for f in TOUCHED:
    src = os.path.join(ROOT, f)
    shutil.copyfile(src, os.path.join(BAK, f.replace("/", "__")))
    SHA[f] = hashlib.sha256(open(src, "rb").read()).hexdigest()


def restore():
    for f in TOUCHED:
        shutil.copyfile(os.path.join(BAK, f.replace("/", "__")), os.path.join(ROOT, f))
        got = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()
        if got != SHA[f]:
            print("!! 还原校验失败: %s" % f)
            sys.exit(9)


def read(f):
    return io.open(os.path.join(ROOT, f), encoding="utf-8").read()


def write(f, s):
    io.open(os.path.join(ROOT, f), "w", encoding="utf-8").write(s)


def sub(s, old, new, why):
    n = s.count(old)
    if n != 1:
        raise AssertionError("锚点命中 %d 次(应为 1): %s" % (n, why))
    return s.replace(old, new, 1)


HAVE_SYSTEMD = (os.geteuid() == 0 and os.path.isdir("/run/systemd/system"))
RESULTS = []
ONLY = {int(a) for a in sys.argv[1:] if a.isdigit()}


def syntax_ok():
    bad = []
    for f in TOUCHED:
        p = os.path.join(ROOT, f)
        if f.endswith(".py"):
            r = subprocess.run([sys.executable, "-m", "py_compile", p],
                               capture_output=True)
            if r.returncode != 0:
                bad.append(f)
        elif f.endswith(".sh"):
            r = subprocess.run(["bash", "-n", p], capture_output=True)
            if r.returncode != 0:
                bad.append(f)
    return bad


def run_test(rel, needs_systemd=False, timeout=1200):
    if needs_systemd and not HAVE_SYSTEMD:
        return None, "需要 root + systemd"
    e = dict(os.environ); e["PDG_TEST_STRICT"] = "1"
    cmd = [sys.executable, rel] if rel.endswith(".py") else ["bash", rel]
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return 0, "超时"
    out = p.stdout + p.stderr
    red = sum(1 for l in out.splitlines() if l.startswith("[FAIL"))
    if "Traceback" in out or "SyntaxError" in out:
        return red, "抛异常"
    if red == 0 and p.returncode != 0:
        red = 1
    return red, ""


def nc(num, title, breaker, gates):
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    try:
        breaker()
    except AssertionError as e:
        print("  [无效] 改坏器锚点没命中: %s" % e)
        RESULTS.append((num, title, None, "锚点没命中")); restore(); return
    print("  锚点已命中并改写")
    bad = syntax_ok()
    if bad:
        print("  [无效] 改坏后代码不合法(%s)" % ",".join(bad))
        RESULTS.append((num, title, None, "改坏器把代码弄成语法错")); restore(); return
    total, detail, unver = 0, [], []
    for g, needs in gates:
        r, note = run_test(g, needs_systemd=needs)
        if r is None:
            unver.append("%s(%s)" % (os.path.basename(g), note)); continue
        total += r
        detail.append("%s:%d%s" % (os.path.basename(g), r, ("/" + note) if note else ""))
    if unver:
        print("  ⚠️ 未验: %s" % ", ".join(unver))
    if total > 0:
        print("  ✅ 转红 %d 条  (%s)" % (total, " ".join(detail)))
        RESULTS.append((num, title, total, " ".join(detail)))
    elif unver and not detail:
        print("  ⏭ 环境不具备, 本条未验 —— 不算有效负控")
        RESULTS.append((num, title, None, "环境不具备: " + ", ".join(unver)))
    else:
        print("  ❌ 0 条转红 —— 无效负控(没有判据盯着它)")
        RESULTS.append((num, title, 0, " ".join(detail)))
    restore()


DOCTOR = [("tests/test-health-timer-doctor.py", False)]
E2E = [("tests/e2e-health-timer.sh", True)]
BOTH = DOCTOR + E2E


# ══ 1. 新 unit 改回 OnBootSec ═══════════════════════════════════════════════
def b1():
    s = read("deploy/bot/pdg-health.timer")
    s = sub(s, "OnActiveSec=2min", "OnBootSec=2min", "unit 的首次触发条件")
    write("deploy/bot/pdg-health.timer", s)


nc(1, "新 unit 改回 OnBootSec(死角重现)", b1, E2E)


# ══ 2. 恢复无意义的 Persistent ══════════════════════════════════════════════
def b2():
    s = read("deploy/bot/pdg-health.timer")
    s = sub(s, "Unit=pdg-health.service",
            "Persistent=true\nUnit=pdg-health.service", "unit 的 [Timer] 段")
    write("deploy/bot/pdg-health.timer", s)


nc(2, "恢复无意义的 Persistent=true", b2, E2E)


# ══ 3. 内容变化后只 enable --now, 不 restart ════════════════════════════════
def b3():
    s = read("deploy/bot/pdg.sh")
    s = sub(s, '''  if ! systemctl restart "$T" >/dev/null 2>&1; then
    c_y "  重启 $T 失败"; _restore; return 1; fi''',
            '''  systemctl start "$T" >/dev/null 2>&1 || true   # 改坏器: 已 active 时什么都不做''',
            "内容变化路径里的明确 restart")
    write("deploy/bot/pdg.sh", s)


nc(3, "内容变化后只 enable --now, 不 restart", b3, E2E)


# ══ 4. install 失败被吞 ═════════════════════════════════════════════════════
def b4():
    s = read("deploy/bot/pdg.sh")
    s = sub(s, '''  if ! install -m644 "$src" "$cur" 2>/dev/null; then
    c_y "  安装 $T 失败"; _restore; return 1; fi''',
            '''  install -m644 "$src" "$cur" 2>/dev/null || true   # 改坏器: 吞掉安装失败''',
            "内容变化路径里的 install")
    write("deploy/bot/pdg.sh", s)


nc(4, "install 失败被吞", b4, E2E)


# ══ 5. daemon-reload 失败被吞 ═══════════════════════════════════════════════
def b5():
    s = read("deploy/bot/pdg.sh")
    s = sub(s, '''  if ! systemctl daemon-reload >/dev/null 2>&1; then
    c_y "  daemon-reload 失败"; _restore; return 1; fi''',
            '''  systemctl daemon-reload >/dev/null 2>&1 || true   # 改坏器: 吞掉 reload 失败''',
            "内容变化路径里的 daemon-reload")
    write("deploy/bot/pdg.sh", s)


nc(5, "daemon-reload 失败被吞", b5, E2E)


# ══ 6. restart 失败被吞 ═════════════════════════════════════════════════════
def b6():
    s = read("deploy/bot/pdg.sh")
    s = sub(s, '''  if ! _pdg_timer_next_ok "$T"; then
    c_y "  $T 换新 unit 后仍排不出下一次触发"; _restore; return 1; fi''',
            '''  _pdg_timer_next_ok "$T" || true   # 改坏器: 排不出下一次也当没事''',
            "内容变化路径末尾的下一次触发校验")
    write("deploy/bot/pdg.sh", s)


nc(6, "restart 后仍无下一次却当成功", b6, E2E)


# ══ 7. doctor 只看 active ═══════════════════════════════════════════════════
def b7():
    s = read("deploy/bot/checks.py")
    s = sub(s, '''    if sub == "elapsed" or not has_next:''',
            '''    if False:   # 改坏器: 只看三态, 不看下一次触发''',
            "doctor 的 elapsed / 无下一次分支")
    write("deploy/bot/checks.py", s)


nc(7, "doctor 只看 active, 不看 NextElapse", b7, DOCTOR)


# ══ 8. doctor 把 infinity 当合法 ════════════════════════════════════════════
def b8():
    s = read("deploy/bot/checks.py")
    s = sub(s, '''        return bool(v) and v not in ("infinity", "n/a")''',
            '''        return bool(v)   # 改坏器: infinity 也算数''',
            "doctor 的 _finite 判据")
    write("deploy/bot/checks.py", s)


nc(8, "doctor 把 infinity 当合法的下一次", b8, DOCTOR)


# ══ 9. 内容未变且状态健康时仍反复 restart ═══════════════════════════════════
def b9():
    s = read("deploy/bot/pdg.sh")
    s = sub(s, '''    if [[ "$ac0" != active ]] || ! _pdg_timer_next_ok "$T"; then''',
            '''    if true; then   # 改坏器: 每次迁移都重启''',
            "内容未变路径的状态判断")
    write("deploy/bot/pdg.sh", s)


nc(9, "内容未变且健康时仍每次重启", b9, E2E)


# ══ 10. 同时加入 OnCalendar 与 OnUnitActiveSec ══════════════════════════════
def b10():
    s = read("deploy/bot/pdg-health.timer")
    s = sub(s, "OnActiveSec=2min",
            "OnActiveSec=2min\nOnCalendar=*:0/3\nPersistent=true", "unit 的触发条件")
    write("deploy/bot/pdg-health.timer", s)


nc(10, "OnCalendar 与 OnUnitActiveSec 叠加(交错双触发)", b10, E2E)


print("\n" + "═" * 70)
eff = sum(1 for r in RESULTS if isinstance(r[2], int) and r[2] > 0)
inv = sum(1 for r in RESULTS if r[2] == 0)
unv = sum(1 for r in RESULTS if r[2] is None)
for num, title, red, note in RESULTS:
    mark = "✅" if isinstance(red, int) and red > 0 else ("❌" if red == 0 else "⏭")
    print("%s NC%02d %-46s %s  (%s)"
          % (mark, num, title, (str(red) + " 条") if isinstance(red, int) else "未验", note))
print("有效 %d / 无效 %d / 未验 %d" % (eff, inv, unv))
restore()
sys.exit(1 if inv else 0)

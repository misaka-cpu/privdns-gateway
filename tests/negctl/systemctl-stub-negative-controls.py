#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
# 共享 systemctl 桩的负控: 每条就地把桩改坏一处, 跑契约测试, 要求它转红, 再逐字节还原。
#
# 为什么单独一组: 这个桩是"测试基础设施", 它坏了不会有人报警 —— 只会让上层测试悄悄变成
# 恒绿。桩答不出属性时上层会因 fail-closed 判红(那还算好, 至少看得见); 真正危险的是桩
# **无条件回答健康值**, 那时 timer 死角那组测试永远是绿的, 而产品可能已经坏了。
#
# 契约测试需要 root + 一次性容器(桩会往 /usr/local/bin 写), 所以这组负控也一样:
# 环境不具备时记为"未验", 不算有效负控。
# ─────────────────────────────────────────────────────────────────────────────
import hashlib
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard          # noqa: E402  建即登记, 退出即清

BAK = tmpguard.mkdtemp(prefix="negctl-stub.")
TOUCHED = ["tests/e2e-lib.sh"]
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


GATE = "tests/test-systemctl-stub.sh"
HAVE = (os.geteuid() == 0 and os.environ.get("PDG_E2E_ISOLATED") == "1")
RESULTS = []
ONLY = {int(a) for a in sys.argv[1:] if a.isdigit()}


def run_gate():
    if not HAVE:
        return None, "需要 root + PDG_E2E_ISOLATED=1"
    e = dict(os.environ)
    e["PDG_TEST_STRICT"] = "1"
    e["PDG_E2E_ISOLATED"] = "1"
    try:
        p = subprocess.run(["bash", GATE], cwd=ROOT, capture_output=True,
                           text=True, timeout=600, env=e)
    except subprocess.TimeoutExpired:
        return 0, "超时"
    out = p.stdout + p.stderr
    red = sum(1 for l in out.splitlines() if l.startswith("[FAIL"))
    if "Traceback" in out or "syntax error" in out:
        return red, "崩溃"
    if red == 0 and p.returncode != 0:
        red = 1
    return red, ""


def nc(num, title, breaker):
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    try:
        breaker()
    except AssertionError as e:
        print("  [无效] 改坏器锚点没命中: %s" % e)
        RESULTS.append((num, title, None, "锚点没命中")); restore(); return
    print("  锚点已命中并改写")
    if subprocess.run(["bash", "-n", os.path.join(ROOT, "tests/e2e-lib.sh")],
                      capture_output=True).returncode != 0:
        print("  [无效] 改坏后语法错 —— 红灯会来自解析器")
        RESULTS.append((num, title, None, "语法错")); restore(); return
    red, note = run_gate()
    if red is None:
        print("  ⏭ 环境不具备(%s), 本条未验" % note)
        RESULTS.append((num, title, None, note))
    elif red > 0:
        print("  ✅ 转红 %d 条%s" % (red, ("/" + note) if note else ""))
        RESULTS.append((num, title, red, note))
    else:
        print("  ❌ 0 条转红 —— 无效负控")
        RESULTS.append((num, title, 0, note))
    restore()


# ══ 1. show 返回空输出 ══════════════════════════════════════════════════════
def b1():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''      for k in $(for x in $props; do echo "$x"; done | sort); do
        if [ "$want_value" = 1 ]; then _val "$k"; else echo "$k=$(_val "$k")"; fi
      done
      exit 0;;''',
            '''      exit 0;;   # 改坏器: 什么都不输出''',
            "桩 show 的输出循环")
    write("tests/e2e-lib.sh", s)


nc(1, "show 返回空输出", b1)


# ══ 2. 无论状态都硬编码 active/waiting/finite ═══════════════════════════════
def b2():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''      _val(){
        case "$1" in''',
            '''      _val(){
        # 改坏器: 无条件回答健康值
        case "$1" in
          ActiveState) echo active; return;;
          SubState) echo waiting; return;;
          NextElapseUSecMonotonic) echo "1w 2d"; return;;
        esac
        case "$1" in''',
            "桩的 _val 分派")
    write("tests/e2e-lib.sh", s)


nc(2, "无论状态都硬编码 active/waiting/finite", b2)


# ══ 3. 只支持一个 -p ════════════════════════════════════════════════════════
def b3():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''        if [ "$nextp" = 1 ]; then props="$props $a"; nextp=0; continue; fi''',
            '''        if [ "$nextp" = 1 ]; then props="$a"; nextp=0; continue; fi   # 改坏器: 只留最后一个''',
            "桩收集 -p 的那一行")
    write("tests/e2e-lib.sh", s)


nc(3, "只支持一个 -p", b3)


# ══ 4. elapsed 仍返回有限 NextElapse ════════════════════════════════════════
def b4():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''                if [ "$(_st)" = 1 ] && [ "$sub" != elapsed ] && [ "$sub" != failed ]; then''',
            '''                if [ "$(_st)" = 1 ]; then   # 改坏器: elapsed 也给有限值''',
            "桩里 NextElapse 的守卫条件")
    write("tests/e2e-lib.sh", s)


nc(4, "elapsed 仍返回有限 NextElapse", b4)


# ══ 5. restart 不更新状态、不重新排程 ═══════════════════════════════════════
def b5():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''  start|restart) for u in "$@"; do
                   [ -f "$D/${u}.fail" ] && echo 0 > "$D/${u}.ac" || echo 1 > "$D/${u}.ac"
                 done; exit 0;;''',
            '''  start|restart) exit 0;;   # 改坏器: 什么都不改''',
            "桩的 start/restart 分支")
    write("tests/e2e-lib.sh", s)


nc(5, "restart 不更新状态、不重新排程", b5)


# ══ 6. 去掉输出乱序 ═════════════════════════════════════════════════════════
# 顺序一旦跟随 -p, "按位解析"那类错误就重新失去暴露条件 —— 真机上正是它把一台好机器
# 判成了红的。
def b6():
    s = read("tests/e2e-lib.sh")
    s = sub(s, '''      for k in $(for x in $props; do echo "$x"; done | sort); do''',
            '''      for k in $props; do   # 改坏器: 跟随 -p 顺序''',
            "桩输出属性的排序")
    write("tests/e2e-lib.sh", s)


nc(6, "去掉输出乱序(按位解析的错误重新失去暴露条件)", b6)


print("\n" + "═" * 70)
eff = sum(1 for r in RESULTS if isinstance(r[2], int) and r[2] > 0)
inv = sum(1 for r in RESULTS if r[2] == 0)
unv = sum(1 for r in RESULTS if r[2] is None)
for num, title, red, note in RESULTS:
    mark = "✅" if isinstance(red, int) and red > 0 else ("❌" if red == 0 else "⏭")
    print("%s NC%02d %-52s %s" % (mark, num, title,
                                  ("%d 条" % red) if isinstance(red, int) else "未验"))
print("有效 %d / 无效 %d / 未验 %d" % (eff, inv, unv))
restore()
sys.exit(1 if inv else 0)

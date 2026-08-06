#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
# doctor 必须看得见「健康自检定时器排不出下一次」。
#
# jp2 上那台的真实状态: is-enabled=enabled、is-active=active、is-failed 不 failed、
# Result=success —— 常规三态全绿, 而 SubState=elapsed、NextElapse 两项都是空/infinity,
# 服务 8 天没跑过。doctor 那时**一条相关检查都没有**, 所以一路判绿。
#
# 这支测试不碰真 systemd: 把 `systemctl show` 换成受控替身, 逐格喂状态, 看 doctor 给什么。
# 真 systemd 那半边由 tests/e2e-health-timer.sh 负责。
# ─────────────────────────────────────────────────────────────────────────────
import io
import os
import sys
import tokenize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import checks  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m); PASS[0] += 1


def bad(m):
    print("[FAIL] " + m); FAIL[0] += 1


# ── systemctl 替身: 按用例给定的属性表回答 ───────────────────────────────────
def fake_systemctl(state):
    """state: dict, 键是 systemctl 属性名或 is-enabled/is-active/is-failed。

    `None` 表示"这条读不出来"(命令失败) —— 用来验 fail-closed。
    """
    def _run(cmd, **kw):
        if not cmd or cmd[0] != "systemctl":
            return (1, "", "")
        if cmd[1] in ("is-enabled", "is-active", "is-failed"):
            v = state.get(cmd[1])
            return (1, "", "") if v is None else (0, v + "\n", "")
        if cmd[1] == "show":
            # 真调用是 `systemctl show <unit> -p A -p B` —— `-p` 与属性名是两个独立参数。
            #
            # 两个关键的仿真点, 都是真机上栽过才补的:
            #   · 第一版按 `-pA` 解析, 于是一个属性都取不到, 全落进 fail-closed 分支 ——
            #     那时"判 fail"是蒙对的, 不是判据在起作用;
            #   · systemd **按它自己的规范顺序**打印, 不是按 -p 传入的顺序。替身这里
            #     **故意打乱顺序**: 谁要是回去按位取值, 立刻就会错位翻车。
            props = [cmd[i + 1] for i, a in enumerate(cmd)
                     if a == "-p" and i + 1 < len(cmd)]
            out = []
            for p in sorted(props):                  # 有意与请求顺序不同
                v = state.get(p)
                if v is None:
                    return (1, "", "")
                out.append("%s=%s" % (p, v))
            return (0, "\n".join(out) + "\n", "")
        return (1, "", "")
    return _run


def verdict(state):
    """跑 check_health_timer, 返回 (status, title, text)。不存在就返回 None。"""
    fn = getattr(checks, "check_health_timer", None)
    if fn is None:
        return None
    orig = checks._run
    checks._run = fake_systemctl(state)
    try:
        return fn()
    finally:
        checks._run = orig


HEALTHY = {
    "is-enabled": "enabled", "is-active": "active", "is-failed": "active",
    "ActiveState": "active", "SubState": "waiting",
    "NextElapseUSecMonotonic": "1d 2h 3min 4s", "NextElapseUSecRealtime": "",
}


def dead():                      # jp2 的真实状态
    d = dict(HEALTHY)
    d.update({"SubState": "elapsed",
              "NextElapseUSecMonotonic": "infinity", "NextElapseUSecRealtime": ""})
    return d


print("══ 1. 检查项本身必须存在 ══")
if getattr(checks, "check_health_timer", None) is None:
    bad("checks 里没有 check_health_timer —— 定时器停摆对 doctor 完全不可见"
        "(jp2 就是这样绿了 8 天)")
elif checks.check_health_timer not in checks.ALL:
    bad("check_health_timer 没有登记进 ALL, doctor 跑不到它")
else:
    ok("check_health_timer 存在且已登记进 ALL")

print()
print("══ 2. jp2 的真实状态必须判 FAIL ══")
v = verdict(dead())
if v is None:
    bad("检查项不存在, 无从判定")
else:
    st, title, text = v
    (ok if st == "fail" else bad)(
        "enabled+active+elapsed+infinity → 判 %s(应为 fail)" % st)
    (ok if "没有安排下一次运行" in text else bad)(
        "文案说清了是什么问题(实得: %s)" % text[:60])
    (ok if "健康检查定时器" in text or "健康自检" in title or "健康检查" in title else bad)(
        "文案指名是健康检查定时器")

print()
print("══ 3. 正常状态不许误报 ══")
v = verdict(HEALTHY)
if v is not None:
    st, _t, text = v
    (ok if st == "ok" else bad)("enabled+active+waiting+有限下一次 → 判 %s(应为 ok)" % st)
    # 只有 realtime 有值(OnCalendar 那种)也算正常
    d = dict(HEALTHY); d["NextElapseUSecMonotonic"] = "infinity"
    d["NextElapseUSecRealtime"] = "Thu 2026-08-06 01:00:00 UTC"
    st2 = verdict(d)[0]
    (ok if st2 == "ok" else bad)("只有 realtime 有下一次也算正常(实得 %s)" % st2)

print()
print("══ 4. 正在执行时不许误报 ══")
d = dict(HEALTHY); d["SubState"] = "running"
d["NextElapseUSecMonotonic"] = "infinity"; d["NextElapseUSecRealtime"] = ""
v = verdict(d)
if v is not None:
    st, _t, text = v
    (ok if st != "fail" else bad)("SubState=running 且此刻还没排出下一次 → 判 %s(不该 fail)" % st)
    (ok if "正在运行" in text else bad)("文案说明「健康检查正在运行」(实得: %s)" % text[:50])

print()
print("══ 5. 其余异常都要 FAIL ══")
cases = [
    ("enabled 但 inactive", {"is-active": "inactive", "ActiveState": "inactive",
                             "SubState": "dead"}),
    ("enabled 但 failed", {"is-active": "failed", "is-failed": "failed",
                           "ActiveState": "failed", "SubState": "failed"}),
    ("两项 NextElapse 都空", {"NextElapseUSecMonotonic": "",
                              "NextElapseUSecRealtime": ""}),
    ("两项都是 infinity", {"NextElapseUSecMonotonic": "infinity",
                           "NextElapseUSecRealtime": "infinity"}),
]
for name, patch in cases:
    d = dict(HEALTHY); d.update(patch)
    v = verdict(d)
    if v is None:
        bad("%s: 检查项不存在" % name); continue
    (ok if v[0] == "fail" else bad)("%s → 判 %s(应为 fail)" % (name, v[0]))

print()
print("══ 6. 读不到就 fail-closed, 不许当没事 ══")
for name, key in (("is-enabled 读不出", "is-enabled"),
                  ("is-active 读不出", "is-active"),
                  ("show 属性读不出", "SubState")):
    d = dict(HEALTHY); d[key] = None
    v = verdict(d)
    if v is None:
        bad("%s: 检查项不存在" % name); continue
    (ok if v[0] == "fail" else bad)("%s → 判 %s(应为 fail)" % (name, v[0]))

print()
print("══ 7. 只读: 不许 restart / enable / reset-failed / daemon-reload ══")
CALLS = []


def spy(cmd, **kw):
    CALLS.append(list(cmd))
    return fake_systemctl(dead())(cmd, **kw)


fn = getattr(checks, "check_health_timer", None)
if fn is None:
    bad("检查项不存在")
else:
    orig = checks._run
    checks._run = spy
    try:
        fn()
    finally:
        checks._run = orig
    verbs = {c[1] for c in CALLS if len(c) > 1 and c[0] == "systemctl"}
    forbidden = verbs & {"restart", "start", "enable", "disable",
                         "reset-failed", "daemon-reload", "try-restart"}
    (ok if not forbidden else bad)(
        "只用了只读子命令(实得 %s)" % sorted(verbs) if not forbidden
        else "动了这些写操作: %s" % sorted(forbidden))

print()
print("══ 8. 不许把未标时区的绝对时间摆给用户 ══")
d = dict(HEALTHY)
d["NextElapseUSecRealtime"] = "Thu 2026-08-06 01:00:00 UTC"
v = verdict(d)
if v is not None:
    text = v[2]
    import re
    naked = re.search(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?!.{0,12}(UTC|GMT|[+-]\d{2}))", text)
    (ok if not naked else bad)(
        "正文里没有裸的绝对时间" if not naked else "出现了未标时区的时间: %s" % naked.group(0))


def code_only(path):
    """剥掉注释与 docstring —— 否则删一句解释性注释就能让门变绿。"""
    out = []
    with open(path, "rb") as fh:
        prev = None
        for tok in tokenize.tokenize(fh.readline):
            if tok.type == tokenize.COMMENT:
                continue
            if tok.type == tokenize.STRING and prev in (
                    None, tokenize.INDENT, tokenize.NEWLINE, tokenize.NL):
                continue
            out.append(tok.string)
            if tok.type not in (tokenize.NL, tokenize.NEWLINE):
                prev = tok.type
    return " ".join(out)


print()
print("══ 9. 判据必须同时看 realtime 与 monotonic ══")
src = code_only(os.path.join(ROOT, "deploy", "bot", "checks.py"))
(ok if "NextElapseUSecMonotonic" in src and "NextElapseUSecRealtime" in src else bad)(
    "两个属性都在代码里被读取(不是只看一个)")

print("─" * 46)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

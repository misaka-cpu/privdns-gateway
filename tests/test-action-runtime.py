#!/usr/bin/env python3
"""CI 里的 action 不能跑在已弃用的 Node 运行时上。

为什么需要它: GitHub 2025-09-19 宣布弃用 runner 上的 Node 20。弃用期内 runner 会
**强行把 node20 的 action 拉到 node24 上跑**, 于是每个 job 都打一条 warning 而流程照常绿 ——
这正是最容易被放过的形态: 它不红, 只是每次都在提醒, 直到某天 runner 真的不再兜底。
v1.11.10 那次 run 里 31/32 个 job 都带着这条 warning。

判据只认一件事: `.github/workflows/*.yml` 里每个 `uses:` 钉的大版本, 是否 >= 该 action
**第一个默认跑 node24 的大版本**。阈值是实测出来的(逐版读上游 action.yml 的 runs.using),
不是照抄 release note 的措辞 —— 上游把 "支持 node24" 和 "默认用 node24" 分成了两个版本,
只看 release note 会早一版下结论:

    actions/upload-artifact     v4 node20 · v5 node20 · **v6 node24** · v7 node24
    actions/download-artifact   v4 node20 · v5 node20 · v6 node20 · **v7 node24** · v8 node24

这支**不联网**: 阈值钉在下面的表里。上游再出新版不影响判据 —— 判的是"有没有低于阈值",
不是"是不是最新"。跟不跟最新是人的决定, 不该由一支测试每天去问 GitHub。

不认识的 action **判失败, 不放过**: 判据无法对它下结论, 而"跳过"会以绿灯的样子出现。
新加 action 的人必须在这里登记它的运行时, 那一步正是本条守卫的目的。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WF = os.path.join(ROOT, ".github/workflows")

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


# action → 第一个 **默认** 跑 node24 的大版本(实测自上游 action.yml 的 runs.using)。
# 加新 action 时在这里登记; 查法: curl .../<action>/<vN>/action.yml | grep 'using:'
NODE24_MIN = {
    "actions/checkout": 5,
    "actions/upload-artifact": 6,
    "actions/download-artifact": 7,
}

# 这些 action 由 runner 内建实现, 不是 JS action, 没有 Node 运行时可言。
NOT_JS = set()

if not os.path.isdir(WF):
    bad("找不到 .github/workflows/")
    print("\n断言 1 项: 通过 0, 失败 1")
    sys.exit(1)

uses = []          # (文件, 行号, owner/repo, 大版本原文)
for fn in sorted(os.listdir(WF)):
    if not fn.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(WF, fn)
    for i, line in enumerate(open(path, encoding="utf-8"), 1):
        if line.lstrip().startswith("#"):      # 注释里提到的不算登记
            continue
        m = re.search(r"uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(\S+)", line)
        if m:
            uses.append((fn, i, m.group(1), m.group(2)))

print("== 1. 每个 action 都要能判定运行时 ==")
unknown = sorted({a for _f, _l, a, _v in uses if a not in NODE24_MIN and a not in NOT_JS})
if not unknown:
    ok("%d 处 uses、%d 个不同 action, 全部在运行时登记表里"
       % (len(uses), len({a for _f, _l, a, _v in uses})))
else:
    bad("这些 action 没登记运行时, 判不了(不放过: 跳过等于零覆盖): %s" % "、".join(unknown))

print("\n== 2. 没有 action 停在已弃用的 Node 20 上 ==")
stale = []
for fn, ln, act, ver in uses:
    if act not in NODE24_MIN:
        continue
    m = re.match(r"^v(\d+)", ver)
    if not m:
        # 钉 SHA 或钉具体小版本时读不出大版本 —— 判不了就判失败, 不猜。
        stale.append((fn, ln, act, ver, "读不出大版本"))
        continue
    major, need = int(m.group(1)), NODE24_MIN[act]
    if major < need:
        stale.append((fn, ln, act, ver, "需要 >= v%d 才默认跑 node24" % need))

if not stale:
    ok("%d 处 uses 全部 >= 各自的 node24 阈值" % len(uses))
else:
    for fn, ln, act, ver, why in stale:
        bad("%s:%d %s@%s —— %s" % (fn, ln, act, ver, why))

print("\n== 3. 同一个 action 在全仓只用一个版本 ==")
# 版本漂移会让"升级过了"变成半真半假: 一处升了、另一处没升, 而 CI 仍然全绿。
byact = {}
for _fn, _ln, act, ver in uses:
    byact.setdefault(act, set()).add(ver)
drift = {a: v for a, v in byact.items() if len(v) > 1}
if not drift:
    ok("%d 个 action 各自版本唯一" % len(byact))
else:
    for a, v in sorted(drift.items()):
        bad("%s 同时用了 %s —— 版本漂移" % (a, "、".join(sorted(v))))

n = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (n, PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

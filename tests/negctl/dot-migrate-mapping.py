#!/usr/bin/env python3
"""12 类状态机负控 → 最小节集合的映射, 以及它的静态自检。

为什么映射要单独成文件并自检: 上一轮按编号顺序猜过一次映射, 结果 NC-SM-10
(partial route 被当完整)被映到 F10 —— 而 F10 其实是"witness restart 失败"。
那样跑出来的绿是假的: 它验的是一个与该契约无关的节。所以映射必须**对着矩阵里
实际的节标题**自检, 不能靠人写表。

这支只读矩阵源码, 秒级, 不启动 systemd、不跑矩阵。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MATRIX = os.path.join(ROOT, "tests", "e2e-dot-migrate.sh")

# 非故障节: 它们不是 F 编号, 单独登记
NON_F = {
    "PREFLIGHT": "候选校验失败的阶段顺序",
    "IDEMPOTENCY": "幂等",
    "PROBE": "独立 E2E 验收",
    "GLOBAL": "健康基线",
}

# ── 映射 ───────────────────────────────────────────────────────────────────
# 每条: 类别 → (selector, 该节必须包含的标题片段, 这条契约是什么, 目标测试)
# 标题片段取自矩阵里**实际**的节标题, 自检会逐条核对它确实出现且恰好一次。
MAPPING = {
    "NC-SM-1": (["LIFECYCLE"], [r"migrate_dotwitness \|\| rc=1"],
                "失败必须以 || rc=1 传给既有 update rollback",
                "tests/test-dot-lifecycle.py"),
    "NC-SM-2": (["PREFLIGHT"], ["候选校验失败的阶段顺序"],
                "候选真 mosdns 校验失败后, 第一次持久写入与第一次状态改变之前必须返回非零",
                "matrix"),
    # 三个原子安装格都要跑 —— 吞掉安装失败会同时影响 env/unit/config 三条路径,
    # 只跑其中一个的话, 改坏器打在另外两条上时会静默漏过。
    "NC-SM-3": (["F04", "F05", "F06"],
                ["env 原子安装失败", "unit 原子安装失败", "mosdns config 原子安装失败"],
                "原子安装失败必须回滚并返回非零", "matrix"),
    "NC-SM-4": (["F07"], ["daemon-reload 失败"], "daemon-reload 失败必须回滚", "matrix"),
    "NC-SM-5": (["F08"], ["mosdns restart 失败"], "mosdns 重启失败必须回滚", "matrix"),
    # enable 与 restart 是同一条契约的两半, 两格都要 —— 只吞 enable 会被 5399 门兜住
    # (防御纵深), 单跑一格看不出退化。
    "NC-SM-6": (["F09", "F10"], ["witness enable 失败", "witness restart 失败"],
                "witness 启用/重启失败必须回滚", "matrix"),
    "NC-SM-7": (["F11"], ["5399 门失败"],
                "服务起来了但没在 127.0.0.1:5399 监听必须回滚", "matrix"),
    "NC-SM-8": (["F09"], ["witness enable 失败"],
                "内容相同但服务 disabled/inactive 时仍须修复", "matrix"),
    "NC-SM-9": (["IDEMPOTENCY"], ["幂等"],
                "无变化时零写盘、零 daemon-reload、零 restart", "matrix"),
    # partial route 不是矩阵里的独立故障格 —— 它由候选渲染那条路径覆盖。
    # 上一轮的示意表把它映到 F10(witness restart 失败), 那是错的。
    "NC-SM-10": (["PREFLIGHT", "F03"],
                 ["候选校验失败的阶段顺序", "候选未过真 mosdns 校验"],
                 "半安装的受管路由必须被认出并修复, 不能当成完整", "matrix"),
    "NC-SM-11a": (["F11"], ["5399 门失败"], "before-image 采集缺项必须失败", "matrix"),
    "NC-SM-11b": (["F11"], ["服务状态已改变之后"],
                  "回滚必须把服务恢复成 before-image 的 disabled/inactive", "matrix"),
    "NC-SM-12": (["F13"], ["回滚阶段失败"],
                 "回滚不完整必须明确报警且不得返回成功", "matrix"),
}

VALID = set(NON_F) | {"F%02d" % i for i in range(1, 14)} | {"LIFECYCLE"}

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def section_titles(src):
    """从矩阵源码读出每个节的实际标题。数据源是矩阵本身, 不是人写的表。"""
    t = {}
    for m in re.finditer(r'^cell(?:_dirty)?\s+(\d+)\s+"([^"]+)"', src, re.M):
        t["F%02d" % int(m.group(1))] = m.group(2)
    for m in re.finditer(r'^sect "(\d+)\. ([^"]+)"', src, re.M):
        n = int(m.group(1))
        if n:
            t["F%02d" % n] = m.group(2)
    # 顶层非 F 节
    if re.search(r'^sect "I\. ', src, re.M):
        t["IDEMPOTENCY"] = "幂等"
    if re.search(r'^\s*sect "3P\. ', src, re.M):
        t["PREFLIGHT"] = "候选校验失败的阶段顺序"
    if re.search(r'^sect "A\. ', src, re.M):
        t["PROBE"] = "独立 E2E 验收"
    return t


def check(mapping=None):
    """返回失败条数。mapping 可注入, 供反向自检用。"""
    global npass, nfail
    mp = MAPPING if mapping is None else mapping
    src = open(MATRIX, encoding="utf-8").read()
    titles = section_titles(src)

    want = {"NC-SM-%s" % x for x in
            ("1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11a", "11b", "12")}
    got = set(mp)
    (ok if got == want else bad)(
        "12 类齐全且无重复(缺 %s / 多 %s)" % (sorted(want - got) or "无", sorted(got - want) or "无"))

    for cls, (sels, marks, contract, target) in sorted(mp.items()):
        if not sels:
            bad("%s selector 为空" % cls); continue
        if "FULL" in sels:
            bad("%s 用了 FULL —— 禁止偷懒映射" % cls); continue
        unknown = [s for s in sels if s not in VALID]
        if unknown:
            bad("%s 指向不存在的节: %s" % (cls, unknown)); continue
        if not contract:
            bad("%s 没写清覆盖的契约" % cls); continue
        if target == "matrix":
            missing = []
            for sel, mark in zip(sels, marks):
                title = titles.get(sel, "")
                if mark not in title:
                    missing.append("%s 的标题是 %r, 不含标记 %r" % (sel, title, mark))
                elif sum(1 for v in titles.values() if mark in v) != 1:
                    n = sum(1 for v in titles.values() if mark in v)
                    missing.append("标记 %r 命中 %d 个节标题(应恰好 1 个)" % (mark, n))
            if missing:
                bad("%s 标题错配: %s" % (cls, missing[0])); continue
        else:
            if mark_missing := [m for m in marks if m not in
                                open(os.path.join(ROOT, target), encoding="utf-8").read()]:
                bad("%s 目标测试 %s 里找不到标记 %s" % (cls, target, mark_missing)); continue
        ok("%-11s → %-14s %s" % (cls, ",".join(sels), contract[:38]))
    return nfail


if __name__ == "__main__":
    print("── 映射静态自检 ──")
    check()
    print("\n── 反向自检: 把 NC-SM-10 改回旧错误 selector, 必须点名错配 ──")
    p0, f0 = npass, nfail
    wrong = dict(MAPPING)
    wrong["NC-SM-10"] = (["F10"], ["partial route"], "partial route 被当完整", "matrix")
    check(wrong)
    caught = nfail > f0
    npass, nfail = p0, f0
    (ok if caught else bad)("旧错配(NC-SM-10 → F10) 被自检抓住并点名")
    print("\n" + "─" * 62)
    print("通过 %d, 失败 %d" % (npass, nfail))
    sys.exit(1 if nfail else 0)

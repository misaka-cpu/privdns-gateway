#!/usr/bin/env python3
"""受管块标记的契约: 模板写出的标记、state() 判态、strip() 剥离必须共用同一套精确语义。

为什么要有这支 —— 真机上坐实过的一条死路:
  装机模板写出的 BEGIN 行带 `—— 不要手工编辑` 后缀, 而 dotwroute 的常量不带。
  state() 用 `text.count()` 子串匹配 → 判成 full(认为可以安全重写);
  strip() 用整行相等 → 一行也删不掉;
  render() 于是在原块之上**再追加一份** → mosdns 报
  `duplicated plugin tag dotwitness_fwd` → pdg __migrate 稳定非零。
  后果: 凡是用候选全新装机的机器, 以后 pdg update 都会因为这一步失败而回滚。
  它 fail-closed(配置不被改坏、普通 DNS 不受影响), 所以从"有没有出事"看不出来。

核心不变量只有一条: **只要 state() 说 full, strip() 就必须真能把受管内容删干净。**
两者用不同匹配方式, 迟早还会分叉; 这里把它钉死。

近似标记(带后缀/缩进不同/大小写不同)绝不能被当成 absent —— 那会让 render 追加第二份,
正是这次事故的形态。它必须 fail-closed。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import dotwroute as d  # noqa: E402

TPL = os.path.join(ROOT, "deploy", "mosdns", "config.yaml")
DOM = "dot.example.test"

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def sect(t):
    print("\n── %s ──" % t)


# 独立于 dotwroute 的参照剥离器: 造夹具不能用被测对象自己的 strip(), 否则是循环论证。
REF_BLOCK = re.compile(
    r"[ \t]*# >>> pdg-dotwitness managed block[^\n]*\n"
    r".*?"
    r"[ \t]*# <<< pdg-dotwitness managed block[^\n]*\n", re.S)


def ref_strip(text):
    return REF_BLOCK.sub("", text)


tpl_src = open(TPL, encoding="utf-8").read()

# ── ① 模板写出的标记必须与 canonical 常量逐字节一致 ────────────────────────
sect("① 模板标记 == dotwroute canonical 常量")
CANON = {"BEGIN_P": d.BEGIN_P, "END_P": d.END_P, "BEGIN_S": d.BEGIN_S, "END_S": d.END_S}
tpl_lines = tpl_src.splitlines()
for name, mk in CANON.items():
    exact = sum(1 for l in tpl_lines if l == mk)
    if exact == 1:
        ok("模板里 %s 有且只有一行逐字节相等" % name)
    else:
        near = [l for l in tpl_lines if mk.strip() in l.strip() and l != mk]
        bad("模板里 %s 逐字节相等的行有 %d 行(应为 1)%s"
            % (name, exact, ("; 近似行: %r" % near[0]) if near else ""))

# 反过来: 模板里凡是提到受管块标记的行, 必须都是 canonical 之一
sect("② 模板里没有「近似但不等」的标记行")
marker_lines = [l for l in tpl_lines if "pdg-dotwitness managed block" in l]
stray = [l for l in marker_lines if l not in CANON.values()]
(ok if not stray else bad)(
    "模板 %d 行标记全部是 canonical" % len(marker_lines) if not stray
    else "模板里有 %d 行近似标记(不等于任何 canonical 常量): %r" % (len(stray), stray[0]))

# ── 造夹具 ────────────────────────────────────────────────────────────────
BASE = ref_strip(tpl_src)                       # 干净底本(无任何受管块)
okr, FULL = d.render(BASE, DOM)                 # canonical 完整块(由 render 自己产出)
if not okr:
    print("[FAIL] 无法用干净底本渲出 canonical 全量块: %s" % FULL)
    sys.exit(1)


def only_plugins(text):
    """只留插件段那一对标记(丢掉 main_sequence 那一对)。"""
    lines, out, skip = text.splitlines(True), [], False
    for l in lines:
        s = l.rstrip("\n")
        if s == d.BEGIN_S:
            skip = True
            continue
        if s == d.END_S:
            skip = False
            continue
        if not skip:
            out.append(l)
    return "".join(out)


def only_seq(text):
    lines, out, skip = text.splitlines(True), [], False
    for l in lines:
        s = l.rstrip("\n")
        if s == d.BEGIN_P:
            skip = True
            continue
        if s == d.END_P:
            skip = False
            continue
        if not skip:
            out.append(l)
    return "".join(out)


SUFFIX = " —— 不要手工编辑"
VARIANTS = [
    ("V1 无标记(absent)",            BASE,                                   "absent"),
    ("V2 canonical 完整(full)",      FULL,                                   "full"),
    ("V3 只有插件段(partial)",       only_plugins(FULL),                     "partial"),
    ("V4 只有 sequence 段(partial)", only_seq(FULL),                         "partial"),
    ("V5 重复插件段(duplicate)",     FULL.replace(d.BEGIN_P, d.BEGIN_P + "\n" + d.BEGIN_P, 1)
                                          .replace(d.END_P, d.END_P + "\n" + d.END_P, 1), "malformed"),
    ("V6 BEGIN/END 乱序",            FULL.replace(d.BEGIN_P, "\x00TMP\x00", 1)
                                          .replace(d.END_P, d.BEGIN_P, 1)
                                          .replace("\x00TMP\x00", d.END_P, 1),            "malformed"),
    ("V7 近似标记(BEGIN 带后缀)",    FULL.replace(d.BEGIN_P, d.BEGIN_P + SUFFIX, 1)
                                          .replace(d.BEGIN_S, d.BEGIN_S + SUFFIX, 1),     "malformed"),
    ("V8 canonical 与近似混用",      FULL.replace(d.BEGIN_P, d.BEGIN_P + SUFFIX, 1),       "malformed"),
    ("V9 无标记但有 witness 插件",   BASE.replace("  - tag: main_sequence",
                                                 "  - tag: dotwitness_fwd\n"
                                                 "    type: forward\n"
                                                 "  - tag: main_sequence", 1),            "malformed"),
]

sect("③ 九种变体的判态")
for name, text, want in VARIANTS:
    got = d.state(text)
    (ok if got == want else bad)("%-28s state=%-9s (期望 %s)" % (name, got, want))

sect("④ 核心不变量: state 说 full, strip 就必须删得干净")
for name, text, _want in VARIANTS:
    if d.state(text) != "full":
        continue
    left = d.strip(text)
    n = left.count("dotwitness_fwd") + left.count("probe_seq")
    (ok if n == 0 else bad)(
        "%-28s 判 full 且 strip 后受管内容归零" % name if n == 0
        else "%-28s **判 full 却删不掉**(strip 后仍有 %d 处受管内容) —— "
             "render 会在原块之上再追加一份" % (name, n))

sect("⑤ malformed 必须 fail-closed 且原文一字不改")
# 注意 partial **不在**这一节: 它必须被**修复**而不是被拒绝。那是既有且已冻结的契约
# (状态机负控 NC-SM-10: "半安装的受管路由必须被认出并修复, 不能当成完整"), 迁移的自愈
# 正依赖它。把 partial 改成 fail-closed 会让冻结矩阵转红, 属于改状态机语义, 不在本轮范围。
for name, text, want in VARIANTS:
    if want != "malformed":
        continue
    okr, res = d.render(text, DOM)
    if okr:
        extra = res.count("tag: dotwitness_fwd")
        bad("%-28s render 竟然成功(产物里 dotwitness_fwd 有 %d 份)" % (name, extra))
    else:
        ok("%-28s render 拒绝并说明原因, 原文未改" % name)

sect("⑤b partial 必须被修复成恰好一对 canonical, 不能变成两份")
for name, text, want in VARIANTS:
    if want != "partial":
        continue
    okr, res = d.render(text, DOM)
    if not okr:
        bad("%-28s render 拒绝了半安装 —— 状态机就没法自愈了: %s" % (name, res))
        continue
    nfwd = res.count("tag: dotwitness_fwd")
    npair = sum(1 for l in res.splitlines() if l in (d.BEGIN_P, d.BEGIN_S))
    if nfwd == 1 and npair == 2 and d.state(res) == "full":
        ok("%-28s 修复成恰好一对 canonical(fwd 1 份, 判态 full)" % name)
    else:
        bad("%-28s 修复后 fwd=%d 份 / BEGIN 标记 %d 条 / 判态 %s"
            % (name, nfwd, npair, d.state(res)))

sect("⑥ 近似标记绝不能被当成 absent")
for name, text, _w in VARIANTS:
    if "近似" not in name and "混用" not in name:
        continue
    st = d.state(text)
    (ok if st != "absent" else bad)(
        "%-28s 判成 %s(不是 absent)" % (name, st) if st != "absent"
        else "%-28s **判成 absent** —— render 会当成没装过, 直接追加第二份块" % name)

sect("⑦ 二次 render 逐字节幂等")
for name, text, want in VARIANTS:
    if want not in ("absent", "full"):
        continue
    o1, r1 = d.render(text, DOM)
    if not o1:
        bad("%-28s 第一次 render 就失败: %s" % (name, r1))
        continue
    o2, r2 = d.render(r1, DOM)
    if not o2:
        bad("%-28s 第二次 render 失败: %s" % (name, r2))
    elif r1 != r2:
        bad("%-28s 二次 render 不幂等(第二次多了 %d 份 dotwitness_fwd)"
            % (name, r2.count("tag: dotwitness_fwd") - r1.count("tag: dotwitness_fwd")))
    else:
        ok("%-28s 二次 render 逐字节相同, 且 dotwitness_fwd 恰好 1 份"
           % name if r1.count("tag: dotwitness_fwd") == 1
           else "%-28s 二次幂等但份数 %d(应为 1)" % (name, r1.count("tag: dotwitness_fwd")))

sect("⑧ 用户配置不被动: strip 出来的部分逐字节等于干净底本")
o1, r1 = d.render(BASE, DOM)
(ok if o1 and d.user_part(r1) == BASE else bad)(
    "render 之后 user_part() 逐字节等于渲染前的底本"
    if o1 and d.user_part(r1) == BASE else "render 动了受管块之外的内容")

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

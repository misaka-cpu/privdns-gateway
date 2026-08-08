#!/usr/bin/env python3
"""6.1A 链路诊断的**状态模型**: 闭集、非法值拒绝、退出码、渲染纪律。

这里不碰真实环境, 只钉死模型本身的契约。为什么值得单独一支: 6.1A 最容易做坏的地方不是
采集, 而是"把不知道说成知道" —— NOT_OBSERVED 被当成 PASS、私网层的红拖着退出码非零、
文案里冒出"SIM 正常"。这些都是模型层面的事, 与环境无关, 所以在这里挡住。
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
import linkstat as L  # noqa: E402

PASS_N = [0]
FAIL_N = [0]


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def mk(**kw):
    base = dict(layer=2, code="L2_CIDR_READY", status=L.PASS, category=None,
                title="t", detail="d", evidence_source="e")
    base.update(kw)
    return L.Finding(**base)


print("── 1. 状态闭集 ──")
if set(L.STATUSES) == {"PASS", "WARN", "FAIL", "NOT_OBSERVED", "STALE", "SKIP"}:
    ok("六种状态构成闭集, 不多不少")
else:
    bad("状态闭集不对: %r" % (L.STATUSES,))

for bad_status in ("OK", "ok", "pass", "ERROR", "", None, "UNKNOWN"):
    try:
        mk(status=bad_status)
        bad("非法状态 %r 竟被接受" % (bad_status,))
    except ValueError:
        pass
ok("七种非法状态全部被拒(含大小写混淆与空值)")

print()
print("── 2. reason code 只登记 6.1A 真能产生的 ──")
# 服务器分不清的结论不许提前进闭集 —— 那会让人以为已经能观测到
for premature in ("L4_TCP853_TIMEOUT", "L6_DOT_QUERY_NOT_SEEN", "L1_OBSERVED",
                  "L2_SRC_OUT_OF_CIDR", "L3_PROBE_NOT_REACHED", "SESSION_EXPIRED"):
    if premature in L.CODES:
        bad("闭集里混进了 6.1A 观测不到的 code: %s" % premature)
        break
else:
    ok("闭集里没有 6.1A 观测不到的结论(TCP853_TIMEOUT / DOT_QUERY_NOT_SEEN 等)")
try:
    mk(code="L9_MADE_UP")
    bad("未登记的 code 竟被接受")
except ValueError:
    ok("未登记的 reason code 被拒")

print()
print("── 3. 字段完整 ──")
f = mk()
missing = [k for k in L.Finding.FIELDS if k not in f]
if not missing:
    ok("十二个字段齐全: %s" % ", ".join(L.Finding.FIELDS))
else:
    bad("缺字段: %s" % ", ".join(missing))
if isinstance(f["observed_at"], float) and f["observed_at"] > 0:
    ok("observed_at 自动填当前时间")
else:
    bad("observed_at 不对: %r" % (f["observed_at"],))

print()
print("── 4. 退出码规则 ──")
cases = [
    ("全 PASS", [mk()], 0),
    ("只有 WARN", [mk(status=L.WARN, code="L5_CERT_EXPIRING", category=L.SECURITY, layer=5)], 0),
    ("只有 SKIP", [mk(status=L.SKIP, code="L3_PLATFORM_NA", layer=3, platform="android")], 0),
    ("服务器层 FAIL", [mk(status=L.FAIL, code="L2_CIDR_DRIFT", category=L.DEPENDENCY)], 2),
]
for name, fs, want in cases:
    got = L.exit_code(fs)
    (ok if got == want else bad)("退出码 %s → %d(期望 %d)" % (name, got, want))

# NOT_OBSERVED 单独拎出来: 这是最容易做错的一条
nobs = [L.Finding(1, "L1_NOT_OBSERVED", L.NOT_OBSERVED, None, "私网流量到达", "d", "none"),
        L.Finding(6.5, "L6_PHONE_QUERY_NOT_OBSERVED", L.NOT_OBSERVED, None, "手机 DoT", "d", "none")]
if L.exit_code(nobs) == 0:
    ok("**NOT_OBSERVED 不导致非零退出**(没看到 ≠ 坏了)")
else:
    bad("NOT_OBSERVED 竟然让退出码非零 —— 会被脚本当成故障")
if L.exit_code(nobs + [mk()]) == 0:
    ok("NOT_OBSERVED 与 PASS 混合仍是 0")
else:
    bad("混合场景退出码不对")

# 模型损坏 → 3
class _Broken(dict):
    pass
if L.exit_code([_Broken(status="WAT", layer=2)]) == 3:
    ok("状态不在闭集内 → 退出码 3(模型损坏)")
else:
    bad("模型损坏没返回 3")

print()
print("── 5. NOT_OBSERVED 既不能升成 PASS 也不能降成 FAIL ──")
# 判据落在**渲染与退出码**上: 它必须自成一档, 而不是被归进任何一边
txt = L.render_text(nobs + [mk()])
if "⚪" in txt:
    ok("NOT_OBSERVED 有独立标记(⚪), 没有混用 PASS/FAIL 的标记")
else:
    bad("NOT_OBSERVED 没有独立标记")
if L._MARK[L.NOT_OBSERVED] not in (L._MARK[L.PASS], L._MARK[L.FAIL]):
    ok("NOT_OBSERVED 的标记与 PASS/FAIL 都不同")
else:
    bad("NOT_OBSERVED 与 PASS 或 FAIL 共用标记")

print()
print("── 6. 输出物理分成两段 ──")
srv_i = txt.find("服务器准备状态")
phone_i = txt.find("手机/SIM 实时证据")
if srv_i >= 0 and phone_i > srv_i:
    ok("两段都在, 且服务器段在前")
else:
    bad("两段没分开: srv=%d phone=%d" % (srv_i, phone_i))
if L._PHONE_NOTE in txt:
    ok("手机段带统一免责说明")
else:
    bad("缺少统一说明")
# 私网层的条目必须落在手机段里, 不能混进服务器段
tail = txt[phone_i:]
if "私网流量到达" in tail and "私网流量到达" not in txt[:phone_i]:
    ok("私网层条目只出现在手机段")
else:
    bad("私网层条目跑到服务器段去了")

print()
print("── 7. 文案红线: 不许声称服务器无法证明的事 ──")
FORBIDDEN = ("SIM 正常", "APN 正常", "手机已连通", "DoT 查询已从手机到达",
             "运营商私网正常", "已确认 APN")
src = (ROOT / "deploy/bot/linkstat.py").read_text(encoding="utf-8")
# 只看会输出给用户的字面量, 不看注释里为了说明"不许说"而引用的那几句。
#
# 原来这里用 re.findall(r'"([^"]{4,})"', src) 抽字面量 —— 那是错的: 正则按出现顺序
# 两两配对引号, 文件里的 """ 文档串会把整个配对**错位**, 于是真正的字面量被当成
# "两对之间的空隙"而漏掉。实测往 _l1 的 detail 里塞一句"已确认 SIM/APN 正常"这条
# 判据抓不到。改用 AST 取真正的字符串常量, 并跳过模块/函数的文档串(那里为了说明
# "不许说什么"必然会引用这些词)。
import ast as _ast
_tree = _ast.parse(src)
_docs = set()
for _n in _ast.walk(_tree):
    if isinstance(_n, (_ast.Module, _ast.FunctionDef, _ast.AsyncFunctionDef, _ast.ClassDef)):
        _d = _ast.get_docstring(_n, clean=False)
        if _d:
            _docs.add(_d)
out_text = "\n".join(
    n.value for n in _ast.walk(_tree)
    if isinstance(n, _ast.Constant) and isinstance(n.value, str)
    and n.value not in _docs)
# 判据不是"这几个字不许出现", 而是"不许**作为结论**出现" —— 6.1B 的免责声明里就有
# 「它不证明 SIM/APN 正常」这种合法的否定用法, 一刀切会把正确的话也判红。所以逐次
# 命中都要求紧邻一个否定词; "已确认 SIM/APN 正常" 照样会被抓住。
bare = []
for pat in FORBIDDEN:
    for m in re.finditer(re.escape(pat), out_text):
        lead = out_text[max(0, m.start() - 12):m.start()]
        if not re.search(r"[不没未][^。;；]{0,10}$", lead):
            bare.append("%s → …%s…" % (pat, out_text[max(0, m.start() - 10):m.end() + 4]))
if not bare:
    ok("这些说法都没有作为结论出现: %s" % "、".join(FORBIDDEN))
else:
    bad("出现了无法证明的说法: %s" % "; ".join(bare[:2]))
# 朴素子串匹配分不清"断言"与"否定": 任务书要求的免责声明本身就含"这不代表 SIM/APN 正常"。
# 所以判据是——**禁语只准出现在那句免责声明里**, 别处一个都不许。先把它整句摘掉再查。
rendered = L.render_text(nobs + [mk()])
outside = rendered.replace(L._PHONE_NOTE, "")
hit2 = [p for p in FORBIDDEN if p in outside]
if not hit2:
    ok("免责声明之外的渲染文本里没有禁语")
else:
    bad("免责声明之外出现: %s" % "、".join(hit2))
if "这不代表 SIM/APN 正常" in L._PHONE_NOTE and "也不代表发生故障" in L._PHONE_NOTE:
    ok("免责声明本身把两个方向都否掉了(既不说正常, 也不说故障)")
else:
    bad("免责声明没有同时否掉两个方向: %r" % (L._PHONE_NOTE,))

print()
print("── 8. 单项采集器抛异常不拖垮整份结果 ──")
_orig = L.COLLECTORS
def _boom(_ctx):
    raise RuntimeError("故意炸")
L.COLLECTORS = (("L2", _boom), ("L1", L._l1_private_traffic))
try:
    fs = L.collect(platform="android")
    codes = [x["code"] for x in fs]
    if "COLLECTOR_ERROR" in codes and "L1_NOT_OBSERVED" in codes:
        ok("一层抛异常 → 该层记 COLLECTOR_ERROR, 其余层照常输出")
    else:
        bad("异常处理不对: %r" % (codes,))
finally:
    L.COLLECTORS = _orig

print("─" * 40)
total = PASS_N[0] + FAIL_N[0]
print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL_N[0] else 0)

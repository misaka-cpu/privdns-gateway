#!/usr/bin/env python3
"""负控: `pdg link status` 结尾那段说明**不许和它上面刚列出的证据打架**。

v1.10.11 之前, 手机段结尾的固定文案里有一句"本版本无法观察手机是否真的发出了 DoT 查询"。
那句话在 pdg-dotwitness 落地(6.2)之前是对的。落地之后, 会话里真的观察到 DoT 查询时,
同一屏会先打出

    🟢 手机 DoT 查询证据   ...(L6_DOT_PROBE_WINDOW_OBSERVED)

再打出"本版本无法观察手机是否真的发出了 DoT 查询" —— 用户看到的是自相矛盾的两句话,
而且后一句会把前面那条**真证据**抹掉。

这支负控盯的是文案与证据的一致性, 而不是状态机本身:
  · 说明里的每一句都必须在本次证据里站得住;
  · 拿到 DoT 证据时不许说"观察不到";
  · 没拿到 DoT 证据时不许暗示拿到了;
  · 无论哪种组合, "能说的上限"那句都不能丢 —— 每条证据只证明它自己那一次到达,
    推不出 SIM/APN、别的 DNS 查询、或者手机整体联网正常。
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("linkstat", ROOT / "deploy/bot/linkstat.py")
L = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(L)

PASS_, FAIL_ = [0], [0]
def ok(m):  PASS_[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL_[0] += 1; print("  ✗ %s" % m)


def F(layer, code, status, title, detail):
    return L.Finding(layer, code, status, None, title, detail, "test")


SERVER = [F(8, "L8_SERVICES_READY", L.PASS, "服务运行", "都活着")]
HTTP_OK = [F(1, "L1_HTTP_PROBE_OBSERVED", L.PASS, "手机 HTTP 探测到达", "看到了"),
           F(2, "L2_SOURCE_INSIDE_CIDR", L.PASS, "手机来源网段", "在段里")]
HTTP_NONE = [F(1, "L1_NOT_OBSERVED", L.NOT_OBSERVED, "手机 HTTP 探测到达", "没看到")]

DOT = {
    "observed":   F(6.5, "L6_DOT_PROBE_WINDOW_OBSERVED", L.PASS,
                    "手机 DoT 查询证据", "窗口内观察到"),
    "pending":    F(6.5, "L6_DOT_PROBE_PENDING", L.NOT_OBSERVED,
                    "手机 DoT 查询证据", "窗口还开着"),
    "not_obs":    F(6.5, "L6_DOT_PROBE_NOT_OBSERVED", L.NOT_OBSERVED,
                    "手机 DoT 查询证据", "窗口关了, 没匹配"),
    "unavail":    F(6.5, "L6_DOT_METRICS_UNAVAILABLE", L.NOT_OBSERVED,
                    "手机 DoT 查询证据", "说不出结论"),
}

CONTRADICT = ("无法观察手机是否真的发出了 DoT",
              "本版本无法观察", "尚未观察手机的实时链路")


def note_of(findings):
    """取渲染结果里手机段的说明行(最后一段缩进文字)。"""
    txt = L.render_text(findings)
    tail = txt.split("━━ 手机/SIM 实时证据")[-1]
    return "\n".join(x.strip() for x in tail.splitlines() if x.startswith("     "))


# ── ① 拿到 DoT 证据时, 不许再说"观察不到 DoT" ───────────────────────────────
n = note_of(SERVER + HTTP_OK + [DOT["observed"]])
hit = [w for w in CONTRADICT if w in n]
if hit:
    bad("DoT 证据是 PASS, 说明里却还写着 %r —— 同一屏自相矛盾" % hit[0])
else:
    ok("DoT 证据 PASS 时, 说明里没有'观察不到 DoT'这类话")
if "DoT" in n:
    ok("DoT 证据 PASS 时, 说明里点了这条证据能说到哪儿")
else:
    bad("DoT 证据 PASS, 说明里却只字不提 DoT: %r" % n)

# ── ② 只有 HTTP 证据时, 不许暗示拿到了 DoT ──────────────────────────────────
for key in ("pending", "not_obs", "unavail"):
    n = note_of(SERVER + HTTP_OK + [DOT[key]])
    if "观察到" in n and "DoT 查询到达" in n:
        bad("DoT=%s(没有证据), 说明里却像是观察到了 DoT: %r" % (key, n))
    elif any(w in n for w in ("没有拿到 DoT", "没有 DoT 证据", "不知道手机是否")):
        ok("DoT=%s → 说明里如实写'这次没有 DoT 证据'" % key)
    else:
        bad("DoT=%s → 说明里没交代 DoT 这条的去向: %r" % (key, n))

# ── ③ 什么都没观察到时, 保持旧的"尚未观察"措辞 ──────────────────────────────
n = note_of(SERVER + HTTP_NONE + [DOT["unavail"]])
if "尚未观察" in n:
    ok("一条证据都没有 → 仍是'尚未观察手机的实时链路'")
else:
    bad("一条证据都没有, 措辞却变了: %r" % n)

# ── ④ 上限那句在任何组合下都不能丢 ──────────────────────────────────────────
for label, phone in (("HTTP+DoT观察到", HTTP_OK + [DOT["observed"]]),
                     ("HTTP+DoT待定",   HTTP_OK + [DOT["pending"]]),
                     ("HTTP+DoT无结论", HTTP_OK + [DOT["unavail"]]),
                     ("全无证据",       HTTP_NONE + [DOT["unavail"]])):
    n = note_of(SERVER + phone)
    if "SIM/APN" in n and ("整体联网" in n or "手机整体" in n):
        ok("%s → 保住了'推不出 SIM/APN 与整体联网'的上限" % label)
    else:
        bad("%s → 丢了上限声明, 用户会读成'链路全通': %r" % (label, n))

print("─" * 60)
print("通过 %d, 失败 %d" % (PASS_[0], FAIL_[0]))
sys.exit(1 if FAIL_[0] else 0)

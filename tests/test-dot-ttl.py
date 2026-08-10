#!/usr/bin/env python3
"""6.2B: evidence 留存期必须**严格覆盖**会话窗口, 外加一整段结算余量。

这支测试存在的理由是一条已经证实的 P1。原来两个 TTL 都是 300:

    会话窗口   [t0, t1] , t1 = t0 + SESSION_TTL(300)
    最早证据   t0 产生 → 到期 t0 + EVIDENCE_TTL(300) = t1

也就是说, 窗口最早那一刻写下的证据, **恰好在窗口关闭那一刻到期**。而要说出
NOT_OBSERVED("我全程盯着, 确实没来"), 前提是"假如它来过, 现在还看得见" ——
这要求 now <= t0 + EVIDENCE_TTL, 而那正好等于"窗口还开着"。于是:

    窗口开着 → 只能 PENDING(还有机会)
    窗口关了 → 留存保证同时失效 → 只能 UNAVAILABLE

**NOT_OBSERVED 在任何时刻都不可达**, 而"手机的 DoT 查询没到达"恰恰是这个功能
要给出的主要答案。功能不是错, 是根本给不出结论。

判据全部走注入时钟。拿 sleep 去碰边界既慢又不稳 —— 边界差一秒的红绿翻转, 用墙钟
测出来的是机器负载, 不是契约。
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))

import dotwitness as W        # noqa: E402
import linksess as S          # noqa: E402
import linkstat as T          # noqa: E402

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


# ── 固定时间夹具 ─────────────────────────────────────────────────────────
T0 = 1_000_000.0                       # 会话创建
LAB = "a1b2c3d4e5f6a7b8c9d0e1f2"
DIG = hashlib.sha256(LAB.encode()).hexdigest()
INV = "9768fa5bdca741ac959df5fd33d105ce"

# 结算余量: 窗口关闭后仍然能给出确定结论的那段时间。600-300=300 秒 —— 恰好一个
# 完整会话窗口, 也就是说用户在测试结束后再花同样长的时间来看结果都还来得及。
SETTLE_MARGIN = 300


def sess(t0=T0):
    return {"probe_label_sha256": DIG, "created_at": t0,
            "expires_at": t0 + S.TTL_SECS,
            "observer": {"invocation_id": INV, "active_state": "active"}}


def ev(at, ttl=None):
    """在 `at` 时刻由 witness 写下的一份证据(到期时间按 witness 的契约算)。"""
    return {"schema_version": 1, "probe_label_sha256": DIG, "observed_at": at,
            "expires_at": at + (ttl if ttl is not None else W.EVIDENCE_TTL_SECS),
            "transport": "dot", "qtype": 1}


def obs(**kw):
    r = {"invocation_id": INV, "active_state": "active", "installed": True}
    r.update(kw)
    return r


def state(s, st, e, o, now):
    r = T.dot_probe_state(s, st, e, o, now)
    return r[0] if isinstance(r, tuple) else r


# ═══ 1. 跨模块 TTL 关系 ═══════════════════════════════════════════════════
head("1. evidence 留存期与会话窗口的关系")

print("  linksess.TTL_SECS        = %s" % S.TTL_SECS)
print("  dotwitness.EVIDENCE_TTL  = %s" % W.EVIDENCE_TTL_SECS)
print("  结算余量                 = %s" % (W.EVIDENCE_TTL_SECS - S.TTL_SECS))

(ok if W.EVIDENCE_TTL_SECS >= S.TTL_SECS + SETTLE_MARGIN else bad)(
    "EVIDENCE_TTL_SECS(%s) >= SESSION_TTL(%s) + 结算余量(%s) —— 最早产生的证据在窗口"
    "关闭后还要留够一个完整会话窗口, 否则 NOT_OBSERVED 无从证明"
    % (W.EVIDENCE_TTL_SECS, S.TTL_SECS, SETTLE_MARGIN))
(ok if W.EVIDENCE_TTL_SECS > S.TTL_SECS else bad)(
    "留存期严格大于会话窗口(相等就意味着最早的证据恰在窗口关闭时到期)")

# TTL 不做成运行时环境变量: 它是判定语义的一部分, 让部署方能改等于让"什么算证据"
# 因机器而异。也不让 dotwitness 反过来 import linksess —— 那个进程要保持纯标准库、
# 依赖最小(它以 DynamicUser 直面网络输入)。
wsrc = open(os.path.join(ROOT, "deploy", "bot", "dotwitness.py"), encoding="utf-8").read()
(ok if "EVIDENCE_TTL" not in wsrc.split("def _port")[0].split("os.environ")[-1][:200]
    and "PDG_EVIDENCE_TTL" not in wsrc else bad)("留存期不是环境变量")
(ok if "import linksess" not in wsrc else bad)("dotwitness 运行时不 import linksess")


# ═══ 2. TTL 边界矩阵 ══════════════════════════════════════════════════════
head("2. TTL 边界矩阵(注入时钟)")

T1 = T0 + S.TTL_SECS                       # 窗口关闭
O, N, U, P = T.DOT_OBSERVED, T.DOT_NOT_OBSERVED, T.DOT_UNAVAILABLE, T.DOT_PENDING

CASES = [
    # 证据在窗口**最早**时刻产生 —— 这是留存期最吃紧的一格
    ("t0 产生 / t1 结算",            ev(T0), W.READ_OK, T1,                     O),
    ("t0 产生 / t1+299 结算",        ev(T0), W.READ_OK, T1 + 299,               O),
    ("t0 产生 / t1+300 边界",        ev(T0), W.READ_OK, T1 + SETTLE_MARGIN,     O),
    ("t0 产生 / 超过留存期",         ev(T0), W.READ_OK, T0 + W.EVIDENCE_TTL_SECS + 1, U),
    # 窗口最晚时刻产生的证据留得更久
    ("t1 产生 / t1+300 结算",        ev(T1), W.READ_OK, T1 + SETTLE_MARGIN,     O),
    # 没有证据
    ("无证据 / 窗口内",              None,   W.READ_ABSENT, T0 + 10,            P),
    ("无证据 / t1 结算",             None,   W.READ_ABSENT, T1,                 N),
    ("无证据 / t1+299 结算",         None,   W.READ_ABSENT, T1 + 299,           N),
    ("无证据 / 超过留存期",          None,   W.READ_ABSENT, T0 + W.EVIDENCE_TTL_SECS + 1, U),
    # 匹配但过期: 手里拿着"它来过"的记录, 不许说"没来过"
    ("匹配证据自身已过期",           ev(T0, ttl=10), W.READ_OK, T1,             U),
    # 不匹配的证据不得 OBSERVED
    ("hash 不匹配",                  dict(ev(T0), probe_label_sha256="f" * 64),
                                     W.READ_OK, T1,                            N),
    ("窗口外产生的证据",             ev(T1 + 1), W.READ_OK, T1 + 10,            N),
]
for name, e, st, now, want in CASES:
    got = state(sess(), st, e, obs(), now)
    (ok if got == want else bad)("%-24s → 期望 %-12s 实得 %s" % (name, want, got))

# observer 中途重启: 无论证据多完美
got = state(sess(), W.READ_OK, ev(T0), obs(invocation_id="0" * 32), T1)
(ok if got == U else bad)("observer 中途重启 → 期望 UNAVAILABLE, 实得 %s" % got)


# ═══ 3. NOT_OBSERVED 必须真的可达 ═════════════════════════════════════════
head("3. NOT_OBSERVED 可达性")

reach = [now for now in range(int(T1), int(T0 + W.EVIDENCE_TTL_SECS) + 1, 10)
         if state(sess(), W.READ_ABSENT, None, obs(), float(now)) == N]
(ok if reach else bad)(
    "窗口关闭后存在能给出 NOT_OBSERVED 的时刻(实得 %d 个采样点)" % len(reach))
if reach:
    span = max(reach) - min(reach)
    (ok if span >= SETTLE_MARGIN - 10 else bad)(
        "可达区间至少覆盖结算余量: 实得 %d 秒(要求 >= %d)" % (span, SETTLE_MARGIN - 10))


# ═══ 4. 6.2A 的严格 schema 不因放宽 TTL 而松动 ════════════════════════════
head("4. schema 上界仍然收着")

(ok if not W._valid(dict(ev(T0), expires_at=T0 + W.EVIDENCE_TTL_SECS + 1)) else bad)(
    "expires_at 超过 observed_at + EVIDENCE_TTL_SECS → 判无效(上界还在)")
(ok if W._valid(ev(T0)) else bad)("恰好等于上界 → 有效")
(ok if not W._valid(dict(ev(T0), expires_at=T0)) else bad)(
    "expires_at == observed_at → 判无效(必须严格大于)")
(ok if not W._valid(dict(ev(T0), expires_at=T0 - 1)) else bad)("expires_at 早于 observed_at → 判无效")
(ok if W.STATE_MODE == 0o600 else bad)("evidence 仍是 0600")
(ok if W.STATE_NAME == "evidence.json" else bad)("文件名仍固定(label 不进路径)")
(ok if len(W.STATE_FIELDS) == 6 else bad)("仍是严格六字段 schema(实得 %d)" % len(W.STATE_FIELDS))
(ok if not (set(W.STATE_FIELDS) & {"source", "client_addr", "ipv4_16"}) else bad)(
    "schema 里仍无任何来源字段")


print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

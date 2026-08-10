#!/usr/bin/env python3
"""6.2B 第一轮: 会话关联、证据读取通道与三态语义的**契约冻结**。

这支测试先于实现存在。它回答的不是"代码对不对", 而是"什么样才算对" —— 三态各自
成立的充要条件、哪些情形绝不允许降级成 NOT_OBSERVED、明文 label 能出现在哪里。

三条贯穿始终的纪律:

  · **只能有一个 evidence 校验器**。linkstat 不许自己再解析一遍 evidence.json ——
    两份校验器迟早会对"什么算有效"给出不同答案, 而其中一份必然更松。这里直接断言
    linkstat 源码里不出现独立的解析/校验痕迹。

  · **观察端不可用时绝不能给出 OBSERVED**(NC34)。这是整个 6.2B 唯一不能错的方向:
    宁可说"不知道", 也不能说"看见了"。取证类结论一旦有假阳性, 它的全部价值就没了。

  · **NOT_OBSERVED 是一个很强的断言**, 它等于"我全程盯着, 确实没来"。只有在能证明
    观察端覆盖了完整窗口时才允许说这句话; 证明不了就是 UNAVAILABLE。把"没看见"和
    "没在看"混成一件事, 正是这套证据最容易骗人的地方。
"""
import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT = os.path.join(ROOT, "deploy", "bot")
sys.path.insert(0, BOT)

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


def need(mod, name, what):
    """能力探测。缺了就记一条**功能缺失**的失败, 而不是让 AttributeError 把整支打崩 ——
    崩掉的红看不出是哪条契约没实现, 也没法逐条收敛。"""
    if hasattr(mod, name):
        return getattr(mod, name)
    bad("%s.%s 不存在 —— %s" % (mod.__name__, name, what))
    return None


import dotwitness as W        # noqa: E402
import linksess as S          # noqa: E402
import linkstat as T          # noqa: E402


# ═══ 1. probe 标识: 与 HTTP token 严格分离 ═════════════════════════════════
head("1. probe label 与 HTTP token 严格分离")

LABEL_RE = re.compile(r"\A[0-9a-f]{24}\Z")

new_label = need(S, "new_probe_label", "每次 session 要独立生成 12 随机字节的 probe 标识")
if new_label:
    labs = [new_label() for _ in range(64)]
    (ok if all(LABEL_RE.match(x) for x in labs) else bad)(
        "probe label 是 24 位小写 hex(12 随机字节)")
    (ok if len(set(labs)) == 64 else bad)("64 次生成互不相同(%d 个唯一)" % len(set(labs)))

mk = need(S, "new_session", "建会话")
if mk and new_label:
    tok, rec = S.new_session("10.0.0.0/24", probe_domain="p.test")
    lab = rec.get("probe_label") if isinstance(rec, dict) else None
    # 明文 label 的归宿: 只能随返回值交给调用方, **不能**留在持久记录里
    if "probe_label_sha256" not in (rec or {}):
        bad("会话记录里没有 probe_label_sha256 —— 无法把 evidence 关联回本次会话")
    else:
        ok("会话记录带 probe_label_sha256")
        d = rec["probe_label_sha256"]
        (ok if isinstance(d, str) and re.match(r"\A[0-9a-f]{64}\Z", d) else bad)(
            "probe_label_sha256 是 64 位小写 hex")
    (ok if lab is None else bad)(
        "持久记录里**没有**明文 probe_label(实得 %r)" % (lab,))
    # 明文只在建会话这一次返回
    got = None
    for v in (rec or {}).values():
        if isinstance(v, str) and LABEL_RE.match(v):
            got = v
    (ok if got is None else bad)("记录里任何字段都不是明文 label 形状(实得 %r)" % (got,))

    ret = need(S, "start_session", "CLI/Bot 的建会话入口")
    if ret:
        import inspect
        src = inspect.getsource(S.start_session)
        (ok if "probe_label" in src else bad)(
            "start_session 会把 probe label 交出去(否则调用方拿不到明文, 手机无从发起探测)")

    # token 与 label 不得相等, 也不得由同一份随机量派生
    if mk:
        t2, r2 = S.new_session("10.0.0.0/24")
        (ok if t2 != r2.get("probe_label_sha256") else bad)("HTTP token 不等于 label 摘要")
        (ok if hashlib.sha256(t2.encode()).hexdigest() != r2.get("probe_label_sha256")
         else bad)("label 摘要不是 HTTP token 的摘要(两者必须独立生成)")


# ═══ 2. evidence 读取通道: 唯一校验器 + 四种结果分得开 ════════════════════
head("2. evidence 读取通道")

READ = need(W, "read_evidence", "跨 UID 消费者的唯一只读入口(要能区分 缺失/无权/损坏/有效)")
for c in ("READ_OK", "READ_ABSENT", "READ_DENIED", "READ_CORRUPT"):
    if not hasattr(W, c):
        bad("dotwitness.%s 不存在 —— 四种读取结果分不开, 无权限就会被当成'没有证据'" % c)
if READ:
    import inspect
    sig = inspect.signature(W.read_evidence)
    (ok if "expect_uid" in sig.parameters else bad)(
        "read_evidence 接受 expect_uid —— 属主判据必须锚在**观察端**身份上, "
        "不能锚在读者的 geteuid()(root 读时那条判据正好是反的)")
    (ok if "runtime_dir" in sig.parameters else bad)("read_evidence 接受 runtime_dir")

# linkstat 绝不许自己再解析一遍 evidence。判据只认**evidence 专有**的痕迹 ——
# 像 expires_at 这种名字 linkstat 早就有(第 177/210 行是 link session 记录的到期),
# 拿它当证据会得到一条恒红的假判据, 那比没有判据更糟。
ls_src = open(os.path.join(BOT, "linkstat.py"), encoding="utf-8").read()
EV_ONLY = ("evidence.json", "STATE_FIELDS", "json.load", "_valid(",
           "/run/pdg-dotwitness")
leaks = [k for k in EV_ONLY if k in ls_src]
(ok if not leaks else bad)(
    "linkstat 没有自带 evidence 解析/校验(否则就是第二份校验器): 命中 %s" % (leaks or "无"))
# 反过来: 它必须**通过 dotwitness** 拿证据, 而不是自己开文件
(ok if "dotwitness" in ls_src or "read_evidence" in ls_src else bad)(
    "linkstat 经 dotwitness 的只读入口取证据(唯一校验器)")


# ═══ 3. 观察端连续可用性 ═══════════════════════════════════════════════════
head("3. observer 连续可用性证据")

OBS = need(S, "observer_identity", "读取观察端的启动身份(InvocationID 等)")
if OBS:
    import inspect
    osrc = inspect.getsource(S.observer_identity)
    (ok if "InvocationID" in osrc else bad)("用 InvocationID 当启动身份")
    # systemctl show 的输出顺序**不跟随**请求顺序(实测: 请求 SubState,ActiveState
    # 得到 ActiveState,SubState), 所以只能按 KEY 取值
    (ok if not re.search(r"splitlines\(\)\[\d+\]|\.split\(\"\\n\"\)\[\d+\]", osrc) else bad)(
        "按 KEY=VALUE 解析, 不按输出位置取值")


# ═══ 4. 三态真值表 ═════════════════════════════════════════════════════════
head("4. 三态真值表")

DECIDE = need(T, "dot_probe_state", "三态裁决(纯函数, 便于逐格钉死)")
for c in ("DOT_OBSERVED", "DOT_NOT_OBSERVED", "DOT_UNAVAILABLE", "DOT_PENDING"):
    if not hasattr(T, c):
        bad("linkstat.%s 不存在" % c)

NOW = 1_000_000.0
T_CLOSE = NOW + 300        # 窗口关闭那一刻: 窗口已结束, 但留存保证还成立
LAB = "a1b2c3d4e5f6a7b8c9d0e1f2"
DIG = hashlib.sha256(LAB.encode()).hexdigest()
INV = "9768fa5bdca741ac959df5fd33d105ce"


def sess(**kw):
    r = {"probe_label_sha256": DIG, "created_at": NOW, "expires_at": NOW + 300,
         "observer": {"invocation_id": INV, "active_state": "active"}}
    r.update(kw)
    return r


def ev(**kw):
    r = {"schema_version": 1, "probe_label_sha256": DIG, "observed_at": NOW + 10,
         "expires_at": NOW + 310, "transport": "dot", "qtype": 1}
    r.update(kw)
    return r


def obs(**kw):
    r = {"invocation_id": INV, "active_state": "active", "installed": True}
    r.update(kw)
    return r


if DECIDE and hasattr(T, "DOT_OBSERVED"):
    O, N, U, P = T.DOT_OBSERVED, T.DOT_NOT_OBSERVED, T.DOT_UNAVAILABLE, T.DOT_PENDING
    # (名字, session, 读取结果, evidence, 结算时 observer, 现在时刻, 期望)
    CASES = [
        # —— OBSERVED 只在全部条件成立时 ——
        ("全部条件成立", sess(), W.READ_OK, ev(), obs(), T_CLOSE, O),

        # —— 窗口未结束: 不是终态 ——
        ("窗口内还没证据", sess(), W.READ_ABSENT, None, obs(), NOW + 100, P),
        ("窗口内已有证据", sess(), W.READ_OK, ev(), obs(), NOW + 100, O),

        # —— NOT_OBSERVED: 窗口结束 + 全程可用 + 无匹配 ——
        ("窗口结束/全程可用/无证据", sess(), W.READ_ABSENT, None, obs(), T_CLOSE, N),
        ("窗口结束/证据 hash 不匹配", sess(), W.READ_OK,
         ev(probe_label_sha256="f" * 64), obs(), T_CLOSE, N),

        # —— 以下必须 UNAVAILABLE, 不许降成 NOT_OBSERVED ——
        ("unit 未安装", sess(), W.READ_ABSENT, None, obs(installed=False), T_CLOSE, U),
        ("结算时 inactive", sess(), W.READ_ABSENT, None,
         obs(active_state="inactive"), T_CLOSE, U),
        ("结算时 failed", sess(), W.READ_ABSENT, None,
         obs(active_state="failed"), T_CLOSE, U),
        ("建会话时 observer 就不可用", sess(observer=None), W.READ_ABSENT, None,
         obs(), T_CLOSE, U),
        ("建会话时 InvocationID 为空", sess(observer={"invocation_id": "",
                                                     "active_state": "inactive"}),
         W.READ_ABSENT, None, obs(), T_CLOSE, U),
        ("窗口中重启(InvocationID 变了)", sess(), W.READ_ABSENT, None,
         obs(invocation_id="530a39a5775049b6b1c2d3e4f5a6b7c8"), T_CLOSE, U),
        ("结算时读不到 InvocationID", sess(), W.READ_ABSENT, None,
         obs(invocation_id=""), T_CLOSE, U),
        ("evidence 无权限读取", sess(), W.READ_DENIED, None, obs(), T_CLOSE, U),
        ("evidence 损坏/对象不安全", sess(), W.READ_CORRUPT, None, obs(), T_CLOSE, U),

        # —— 时间边界 ——
        ("证据早于窗口起点", sess(), W.READ_OK, ev(observed_at=NOW - 1, expires_at=NOW + 299),
         obs(), T_CLOSE, N),
        ("证据晚于窗口终点", sess(), W.READ_OK, ev(observed_at=NOW + 301,
                                                  expires_at=NOW + 601), obs(), T_CLOSE, N),
        ("证据恰在窗口起点", sess(), W.READ_OK, ev(observed_at=NOW, expires_at=NOW + 300),
         obs(), T_CLOSE, O),
        ("证据恰在窗口终点", sess(), W.READ_OK, ev(observed_at=NOW + 300,
                                                  expires_at=NOW + 600), obs(), T_CLOSE, O),
        ("匹配但记录已过期", sess(), W.READ_OK,
         ev(observed_at=NOW + 10, expires_at=NOW + 20), obs(), T_CLOSE, U),
        # 结算太晚: 窗口最早那一刻的证据到 t0+TTL 就到期, 过了这个点"看不见"既可能是
        # 没来过也可能是过期了 —— 分不开就不许下负面结论
        ("结算晚于留存保证", sess(), W.READ_ABSENT, None, obs(), NOW + 400, U),
        ("transport 不是 dot", sess(), W.READ_OK, ev(transport="udp"), obs(), T_CLOSE, U),
    ]
    for name, s, st, e, o, now, want in CASES:
        try:
            got = T.dot_probe_state(s, st, e, o, now)
        except Exception as exc:  # noqa: BLE001
            bad("%-26s → 抛异常 %s: %s" % (name, exc.__class__.__name__, exc))
            continue
        got = got[0] if isinstance(got, tuple) else got
        (ok if got == want else bad)("%-26s → 期望 %s, 实得 %s" % (name, want, got))


# ═══ 5. NC34: 观察端不可用时绝不能生成 OBSERVED ════════════════════════════
head("5. NC34 观察端不可用 → 永不 OBSERVED")

if DECIDE and hasattr(T, "DOT_OBSERVED"):
    # 把"证据完美"这一半固定住, 只让观察端不可用。任何一格给出 OBSERVED 都是致命的:
    # 那等于在观察端根本没在看的时候, 向用户宣称"看见你手机的查询了"。
    BROKEN = [
        ("unit 未安装", obs(installed=False)),
        ("结算时 inactive", obs(active_state="inactive")),
        ("结算时 failed", obs(active_state="failed")),
        ("结算时 activating", obs(active_state="activating")),
        ("InvocationID 变了", obs(invocation_id="0" * 32)),
        ("InvocationID 读不到", obs(invocation_id="")),
        ("observer 整个缺失", None),
    ]
    for name, o in BROKEN:
        got = T.dot_probe_state(sess(), W.READ_OK, ev(), o, T_CLOSE)
        got = got[0] if isinstance(got, tuple) else got
        (ok if got == T.DOT_UNAVAILABLE else bad)(
            "NC34 %-20s + 完美证据 → 必须 UNAVAILABLE, 实得 %s" % (name, got))
    # 建会话时就没有 observer 的那一半
    for name, s in (("建会话时 observer 缺失", sess(observer=None)),
                    ("建会话时 InvocationID 空", sess(observer={"invocation_id": "",
                                                               "active_state": "active"}))):
        got = T.dot_probe_state(s, W.READ_OK, ev(), obs(), T_CLOSE)
        got = got[0] if isinstance(got, tuple) else got
        (ok if got == T.DOT_UNAVAILABLE else bad)(
            "NC34 %-20s + 完美证据 → 必须 UNAVAILABLE, 实得 %s" % (name, got))


# ═══ 6. 隐私: 结论里不得出现 label/qname/DoT 域名/来源 ═════════════════════
head("6. 隐私边界")

if DECIDE and hasattr(T, "DOT_OBSERVED"):
    blob = ""
    for s, st, e, o in ((sess(), W.READ_OK, ev(), obs()),
                        (sess(), W.READ_DENIED, None, obs()),
                        (sess(), W.READ_CORRUPT, None, obs(active_state="failed"))):
        r = T.dot_probe_state(s, st, e, o, T_CLOSE)
        blob += repr(r)
    for secret, why in ((LAB, "明文 probe label"), (DIG, "label 摘要"),
                        ("p.test", "探测域名")):
        (ok if secret not in blob else bad)("三态返回值里不出现%s" % why)
    (ok if not re.search(r"ipv4|source|client|10\.0\.0", blob, re.I) else bad)(
        "DoT evidence 不产生任何来源字段(转发后 witness 只能看见 127.0.0.1)")

# evidence schema 本身不许有来源字段 —— 6.2A 的冻结契约, 这里复核一次
(ok if not (set(W.STATE_FIELDS) & {"source", "client_addr", "source_ipv4_16", "ipv4_16"})
 else bad)("evidence schema 里没有任何来源字段(6.2A 冻结契约)")


print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

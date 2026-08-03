#!/usr/bin/env python3
"""6.1B 阶段 4: 会话证据接进 linkstat 之后的端到端语义。

这支测试真的跑一遍"建会话 → 手机访问 :81 → 看 linkstat"的流程, 盯的是**语义诚实**:

  · 没有会话 = NOT_OBSERVED, 不是 FAIL(没做诊断不等于坏了);
  · 观察到 = PASS, 但文案不许把它说成"SIM 正常/DNS 走通";
  · 会话过期 = STALE, 不是继续 PASS;
  · 手机层无论什么状态, 都不许影响 `pdg link status` 的服务器准备状态退出码;
  · DNS 那半边(第 6.5 层)当前只能是 NOT_OBSERVED —— 阶段 3 因安全原因停止, 不许
    拿别的东西冒充。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS_N = [0]
FAIL_N = [0]
TMPS = []


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def fresh(cidr="127.0.0.0/8"):
    d = tempfile.mkdtemp(prefix="linklive."); TMPS.append(d)
    os.environ["PDG_PROBE81_RUNTIME_DIR"] = d
    os.environ["PDG_PROFILE_ENV"] = os.path.join(d, "profile.env")
    open(os.environ["PDG_PROFILE_ENV"], "w").write("PDG_INTERNAL_CIDR=%s\n" % cidr)
    return d


def layer(fs, n):
    return [f for f in fs if f["layer"] == n]


def main():
    import linkstat as L
    import linksess as S
    import probe81

    print("── 1. 没有会话: NOT_OBSERVED, 不是 FAIL ──")
    fresh()
    fs = L.collect(platform="android")
    l1 = layer(fs, 1)
    (ok if l1 and l1[0]["status"] == L.NOT_OBSERVED else bad)(
        "第 1 层 NOT_OBSERVED(实得 %s)" % [(f["status"], f["code"]) for f in l1])
    (ok if not any(f["status"] == L.FAIL for f in fs if L.is_phone_evidence(f)) else bad)(
        "手机层没有任何 FAIL")
    (ok if not any(f["code"].startswith("L2_SOURCE") for f in fs) else bad)(
        "没有会话时不产出来源证据")

    print()
    print("── 1b. 会话建了但手机还没来: 仍是 NOT_OBSERVED ──")
    # 这一格原本没人覆盖 —— 负控"证据没变却返回 PASS"因此抓不住。会话存在只说明
    # 我们在等, 不说明观察到了任何东西。
    fresh()
    tok1b, rec1b = S.new_session(probe_domain="p.probe.example")
    S.write_state(rec1b)
    fs = L.collect(platform="android")
    l1 = layer(fs, 1)
    (ok if l1 and l1[0]["status"] == L.NOT_OBSERVED
        and l1[0]["code"] == "L1_NOT_OBSERVED" else bad)(
        "会话进行中但未消费 → NOT_OBSERVED(实得 %s)"
        % [(f["status"], f["code"]) for f in l1])
    # observed_at 在 6.1A 的语义里是**采集时刻**(Finding 构造时兜底成 now), 不是
    # "观察到手机的时刻", 所以它区分不了这两种情形。真正的判据是用户读到的那句话。
    (ok if l1 and "还没有观察到" in l1[0]["detail"] else bad)(
        "文案明说还没观察到(实得 %r)" % (l1[0]["detail"] if l1 else None))
    (ok if l1 and "观察到一次" not in l1[0]["detail"] else bad)(
        "没有声称观察到过任何一次探测")
    (ok if not any(f["code"].startswith("L2_SOURCE") for f in fs) else bad)(
        "也没有来源证据(手机还没来过)")
    # 过期但从未被消费 → STALE, 但绝不是 PASS
    rec1b["expires_at"] = rec1b["created_at"] - 1
    S.write_state(rec1b)
    l1 = layer(L.collect(platform="android"), 1)
    (ok if l1 and l1[0]["status"] == L.STALE else bad)(
        "会话过期且从未被消费 → STALE(实得 %s)"
        % [(f["status"], f["code"]) for f in l1])
    (ok if l1 and l1[0]["status"] != L.PASS else bad)(
        "**绝不是 PASS** —— 没观察到就是没观察到")

    print()
    print("── 2. 真跑一次会话: HTTP 证据出现 ──")
    fresh()
    tok, rec = S.new_session(probe_domain="abc.probe.dot.example")
    S.write_state(rec)
    srv = HTTPServer(("127.0.0.1", 0), probe81.H)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
    try:
        with urllib.request.urlopen(
                "http://127.0.0.1:%d/probe?t=%s" % (port, tok), timeout=5) as r:
            body = r.read()
        (ok if b"ok" in body else bad)("手机侧请求被接受: %r" % body)
    finally:
        srv.shutdown(); srv.server_close(); th.join(timeout=5)

    fs = L.collect(platform="android")
    l1 = layer(fs, 1)
    (ok if l1 and l1[0]["status"] == L.PASS
        and l1[0]["code"] == "L1_HTTP_PROBE_OBSERVED" else bad)(
        "第 1 层变成 PASS/L1_HTTP_PROBE_OBSERVED(实得 %s)"
        % [(f["status"], f["code"]) for f in l1])
    (ok if l1 and l1[0]["observed_at"] else bad)("带上了 observed_at")
    (ok if l1 and l1[0]["freshness_secs"] is not None else bad)("带上了 freshness_secs")
    src = [f for f in fs if f["code"].startswith("L2_SOURCE")]
    (ok if src and src[0]["code"] == "L2_SOURCE_INSIDE_CIDR" else bad)(
        "来源命中内网段(实得 %s)" % [(f["status"], f["code"]) for f in src])
    (ok if src and L.is_phone_evidence(src[0]) else bad)(
        "来源证据被归到手机段, 不混进服务器准备状态")

    print()
    print("── 3. 文案红线: 观察到 HTTP 不等于任何更强的结论 ──")
    txt = L.render_text(fs)
    phone_seg = txt.split("手机/SIM 实时证据")[1]
    # 判据要**逐次命中**都成立: "别处有免责句"不能给这一处开脱。允许的形态只有
    # 紧邻的否定 —— "不证明 SIM/APN 正常" 合法, "已确认 SIM/APN 正常" 不合法。
    import re as _re
    for banned in ("SIM 正常", "APN 正常", "手机已连通",
                   "DoT 查询已从手机到达", "运营商私网正常",
                   "已确认这个 token 到达 mosdns", "已确认 SIM/APN 正常",
                   "已确认手机采用了这次 DNS 响应", "已确认最终走了"):
        bare = []
        for m in _re.finditer(_re.escape(banned), phone_seg):
            lead = phone_seg[max(0, m.start() - 12):m.start()]
            if not _re.search(r"[不没未][^。;；]{0,10}$", lead):
                bare.append(phone_seg[max(0, m.start() - 12):m.end() + 4])
        (ok if not bare else bad)(
            "禁语「%s」每次出现都紧跟否定(裸用 %d 处: %s)"
            % (banned, len(bare), bare[:1]))
    # 免责句的**内容**要求: 必须同时点到 SIM/APN、DoT 与整体联网三者, 缺一就会被读者
    # 补成"那另外两个应该没问题"。只钉"不证明 SIM/APN"会放过"但 DoT 是通的"这种写法。
    disclaim = [ln for ln in phone_seg.splitlines() if "不能据此判断" in ln]
    (ok if disclaim and all(k in " ".join(disclaim) for k in ("SIM/APN", "DoT", "整体联网"))
     else bad)("免责句同时否掉 SIM/APN、DoT、整体联网(实得 %s)"
               % (" ".join(disclaim)[:60] or "无"))
    (ok if "尚未观察手机的实时链路" not in phone_seg else bad)(
        "观察到证据之后, 不再说「尚未观察」")

    print()
    print("── 4. 手机层不影响服务器准备状态的退出码 ──")
    base = [f for f in fs if not L.is_phone_evidence(f)]
    (ok if L.exit_code(fs) == L.exit_code(base) else bad)(
        "整份结果与只留服务器层的退出码一致(%d vs %d)"
        % (L.exit_code(fs), L.exit_code(base)))
    # 造一条手机层 FAIL, 退出码不许被它拉成 2
    fake = list(base)
    fake.append(L.Finding(1, "L1_NOT_OBSERVED", L.FAIL, None, "x", "y", evidence_source="t"))
    (ok if L.exit_code(fake) == L.exit_code(base) else bad)(
        "即使手机层出现 FAIL, 退出码也不变")
    fake2 = list(base)
    fake2.append(L.Finding(2, "L2_SOURCE_OUTSIDE_CIDR", L.FAIL, None, "x", "y", evidence_source="t"))
    (ok if L.exit_code(fake2) == L.exit_code(base) else bad)(
        "第 2 层的来源证据即使 FAIL 也不影响退出码(它按 code 归手机段)")
    # 反面: 服务器层的第 2 层 FAIL **必须**影响
    fake3 = [f for f in base if f["code"] != "L2_CIDR_DRIFT"]
    fake3.append(L.Finding(2, "L2_CIDR_DRIFT", L.FAIL, None, "x", "y", evidence_source="t"))
    (ok if L.exit_code(fake3) == 2 else bad)(
        "服务器侧的第 2 层 FAIL 仍然把退出码拉成 2(否则上一条是空转)")

    print()
    print("── 5. 会话过期 → STALE ──")
    fresh()
    tok5, rec5 = S.new_session()
    rec5["http_consumed_at"] = rec5["created_at"] + 1
    rec5["state"] = "http_seen"
    rec5["source"] = {"ipv4_16": "127.0.0.0/16", "inside_internal_cidr": True}
    rec5["expires_at"] = rec5["created_at"] - 1          # 已经过期
    S.write_state(rec5)
    fs = L.collect(platform="android")
    l1 = layer(fs, 1)
    (ok if l1 and l1[0]["status"] == L.STALE else bad)(
        "过期后第 1 层是 STALE(实得 %s)" % [(f["status"], f["code"]) for f in l1])
    src = [f for f in fs if f["code"].startswith("L2_SOURCE")]
    (ok if src and src[0]["status"] == L.STALE else bad)(
        "来源证据也转 STALE(实得 %s)" % [(f["status"], f["code"]) for f in src])
    (ok if L.exit_code(fs) != 3 else bad)("STALE 是闭集里的合法状态, 没把模型判损坏")

    print()
    print("── 6. 来源在内网段之外 → WARN, 不是 FAIL ──")
    fresh(cidr="10.99.0.0/16")          # 127.0.0.1 落在段外
    tok6, rec6 = S.new_session(); S.write_state(rec6)
    srv = HTTPServer(("127.0.0.1", 0), probe81.H)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
    try:
        urllib.request.urlopen("http://127.0.0.1:%d/probe?t=%s" % (port, tok6),
                               timeout=5).read()
    finally:
        srv.shutdown(); srv.server_close(); th.join(timeout=5)
    fs = L.collect(platform="android")
    src = [f for f in fs if f["code"] == "L2_SOURCE_OUTSIDE_CIDR"]
    (ok if src and src[0]["status"] == L.WARN else bad)(
        "段外来源是 WARN(实得 %s)" % [(f["status"], f["code"]) for f in src])
    # 这一条比原来更严: 不是"把断言改成推测", 而是**根本不推测 SIM**。来源段能证明的
    # 只有"这次请求是不是来自配置的那个段", 手机为什么不在段内(换了网、Wi-Fi 没关、
    # APN 不对…)服务器一概不知道。推测写进判据就会被当成结论。
    d6 = src[0]["detail"] if src else ""
    (ok if src and "内网卡来源段" in d6 else bad)(
        "段外文案陈述的是「不是来自配置的内网卡来源段」(实得 %s)" % d6[:48])
    (ok if src and not any(w in d6 for w in ("SIM", "APN", "很可能", "应该"))
     else bad)("段外文案不对 SIM/APN 做任何推测(实得 %s)" % d6[:48])
    (ok if src and src[0]["next_step"] and "SIM" in src[0]["next_step"] else bad)(
        "把「检查是不是那张 SIM」放在下一步建议里, 而不是写成判据")

    print()
    print("── 6b. 四类手机侧状态的文案各说各的, 不能混 ──")
    # 已观察 / 未观察 / 过期 / 段外: 用户看到的第一句话必须能区分这四种处境。
    # 之前只验了"已观察"那一类, 另外三类写成什么样都能通过。
    def _l1_detail(**kw):
        fresh(**kw)
        tok, rec = S.new_session()
        for k, v in _st.items():
            rec[k] = v
        S.write_state(rec)
        return (layer(L.collect(platform="android"), 1) or [{}])[0].get("detail", "")

    _st = {}
    d_pending = _l1_detail()
    (ok if "会话进行中" in d_pending and "还没有观察到" in d_pending else bad)(
        "未观察: 说「会话进行中, 服务器还没有观察到」(实得 %s)" % d_pending[:44])

    _st = {"expires_at": time.time() - 1}
    d_exp = _l1_detail()
    (ok if "已过期" in d_exp and "没有观察到" in d_exp else bad)(
        "过期: 说「会话已过期, 期间没有观察到」(实得 %s)" % d_exp[:44])

    for name, d in (("未观察", d_pending), ("过期", d_exp)):
        (ok if "服务器观察到本次会话的 HTTP 请求" not in d else bad)(
            "%s 的文案不能出现「服务器观察到本次会话的 HTTP 请求」" % name)

    print()
    print("── 7. 第 6.5 层: 阶段 3 停了, 只能 NOT_OBSERVED ──")
    l65 = layer(fs, 6.5)
    (ok if l65 and l65[0]["status"] == L.NOT_OBSERVED else bad)(
        "第 6.5 层 NOT_OBSERVED(实得 %s)" % [(f["status"], f["code"]) for f in l65])
    (ok if l65 and l65[0]["code"] == "L6_DOT_METRICS_UNAVAILABLE" else bad)(
        "code 是 L6_DOT_METRICS_UNAVAILABLE(说清为什么没有)")
    (ok if l65 and "6.2" in l65[0]["detail"] else bad)("文案里点明了延后到 6.2")
    d65 = l65[0]["detail"] if l65 else ""
    (ok if "无法安全取得" in d65 else bad)(
        "第 6.5 层明说「当前版本无法安全取得」, 不能读成通过(实得 %s)" % d65[:44])
    (ok if all(k in d65 for k in ("明文查询域名", "回环")) else bad)(
        "并给出拒绝的理由(同端口暴露明文域名 / 回环不构成缓解)")
    (ok if not any(w in d65 for w in ("正常", "已确认")) else bad)(
        "第 6.5 层不出现任何肯定性结论词")
    # HTTP 有证据而 DNS 没有 —— 不许因此断言 Private DNS 一定关着
    txt = L.render_text(fs)
    (ok if "一定" not in txt.split("手机/SIM")[1] else bad)(
        "没有断言「Private DNS 一定关着」")

    print()
    print("── 8. 新 reason code 都在闭集里, 且状态合法 ──")
    for c in ("L1_HTTP_PROBE_OBSERVED", "L1_HTTP_PROBE_STALE",
              "L2_SOURCE_INSIDE_CIDR", "L2_SOURCE_OUTSIDE_CIDR",
              "L6_DOT_PROBE_WINDOW_OBSERVED", "L6_DOT_PROBE_NOT_OBSERVED",
              "L6_DOT_METRICS_UNAVAILABLE"):
        (ok if c in L.CODES else bad)("%s 在 CODES 闭集里" % c)

    print()
    print("── 9. session status --json 的 schema 稳定 ──")
    fresh()
    tok9, rec9 = S.new_session(probe_domain="x.probe.example"); S.write_state(rec9)
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/linksess.py"),
                        "status", "--json"], capture_output=True, text=True, timeout=60,
                       env=dict(os.environ))
    try:
        j = json.loads(r.stdout)
    except ValueError:
        j = None
    (ok if j is not None else bad)("--json 输出可解析")
    if j:
        want_top = {"schema_version", "active", "reason", "session"}
        (ok if set(j) == want_top else bad)(
            "顶层字段固定为 %s(实得 %s)" % (sorted(want_top), sorted(j)))
        want_s = {"session_id", "state", "created_at", "expires_at", "remaining_secs",
                  "http_consumed", "http_consumed_at", "invalid_attempts",
                  "max_invalid_attempts", "probe_domain", "source", "metrics_baseline"}
        (ok if set(j["session"]) == want_s else bad)(
            "session 字段固定(缺 %s / 多 %s)"
            % (sorted(want_s - set(j["session"])), sorted(set(j["session"]) - want_s)))
        blob = json.dumps(j)
        (ok if "token" not in blob.replace("token_sha256", "") else bad)(
            "json 里没有 token 字段")

    print("─" * 46)
    print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
    for t in TMPS:
        shutil.rmtree(t, ignore_errors=True)
    if PASS_N[0] + FAIL_N[0] == 0:
        print("零断言 —— 判失败"); return 1
    return 1 if FAIL_N[0] else 0


if __name__ == "__main__":
    sys.exit(main())

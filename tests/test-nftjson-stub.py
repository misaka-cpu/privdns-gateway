#!/usr/bin/env python3
"""沙箱 nft 桩的**契约测试** —— 桩必须随现场变化, 不能是一份"永远健康"的常量。

为什么单独有这一支: 共享桩以前对 `nft -j list table inet pdg` 什么都不返回, nftlive 按设计
fail-closed, 于是 e2e-update / e2e-upgrade-from-release 在更新后自检阶段判红并回滚 ——
测出来的是桩的病, 而排查时最容易的"修法"恰恰是最坏的那个: 把 fail-closed 降成 WARN。
所以桩本身要有判据看着: 它必须是**转换器**(输入什么状态就输出什么 JSON), 不是常量。
"""
import io
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
sys.path.insert(0, str(ROOT / "tests"))

import nftjson       # noqa: E402
import nftlive       # noqa: E402
import rescue_const  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


CIDR = "127.0.0.0/8"


def render(**kw):
    """按生产模板渲染一份配置文本 —— 不手写夹具, 免得测的是我自己编的形态。"""
    t = (ROOT / "deploy/firewall/nftables-mihomo.conf").read_text(encoding="utf-8")
    # __SSH_MATCH__ 默认渲染成空(对全网放行) —— 与真机装出来的形态一致。
    # 收紧形态另有 tests/test-ssh-source-persist.sh 专门覆盖。
    t = (t.replace("__SSH_MATCH__", kw.get("ssh_match", ""))
          .replace("__SSH_PORT__", "22").replace("__INTERNAL_CIDR__", kw.get("cidr", CIDR))
          .replace("__SERVER_IP__", "203.0.113.1")
          .replace("__TAILNET_DIRECT__", "# (SSH 未收紧为 tailnet, 故不放行 Tailscale 直连端口)")
          .replace("__RESCUE_PORT__", str(rescue_const.port())))
    return t


def audit(text, platform="android", cidr=CIDR):
    obj = nftjson.to_json(text)
    return nftlive.audit_kernel(obj, cidr=cidr, platform=platform)


# ═══ 0. 夹具自证: 用的是生产模板本身 ════════════════════════════════════════
_t = render()
(ok if "table inet pdg" in _t and "__INTERNAL_CIDR__" not in _t else bad)(
    "夹具来自 deploy/firewall/nftables-mihomo.conf 的真实渲染(不是手写的)")

# ═══ 1. 健康 seed → JSON 可解析, audit_kernel 通过 ══════════════════════════
_j = nftjson.to_json(_t)
try:
    json.loads(json.dumps(_j))
    ok("健康 seed → 输出是可解析的 JSON")
except Exception as e:  # noqa: BLE001
    bad("JSON 不可解析: %s" % e)
_a = nftlive.audit_kernel(_j, cidr=CIDR, platform="android")
(ok if _a.ok else bad)("健康 seed → audit_kernel 通过(实得 problems=%s)"
                       % [str(x) for x in _a.problems])
(ok if not _a.doctor_issues else bad)(
    "健康 seed → 连 doctor 专项都没问题(实得 %s)" % [str(x) for x in _a.doctor_issues])
_ev = sorted(_a.evaluated)
(ok if {"input", "prerouting"} <= set(_ev) else bad)(
    "input 与 prerouting 都真的被判过(evaluated=%s)" % _ev)

# ═══ 2. 缺 TCP 81 → 审计失败 ════════════════════════════════════════════════
_bad81 = _t.replace("tcp dport { 53, 81, 853, 7893, 8445 }",
                    "tcp dport { 53, 853, 7893, 8445 }")
(ok if _bad81 != _t else bad)("夹具改动确实命中(TCP 81 已摘掉)")
_a2 = audit(_bad81)
(ok if not _a2.ok else bad)("缺 TCP 81 → 审计失败(实得 ok=%s)" % _a2.ok)
(ok if any("81" in str(p) for p in _a2.problems) else bad)(
    "失败原因点名 81(实得 %s)" % [str(p) for p in _a2.problems])

# ═══ 3. redirect 目标写错 → 审计失败 ════════════════════════════════════════
_badr = _t.replace("redirect to :7893", "redirect to :1080")
(ok if _badr != _t else bad)("夹具改动确实命中(redirect 目标改成 :1080)")
_a3 = audit(_badr)
(ok if not _a3.ok else bad)("redirect 目标错 → 审计失败(实得 ok=%s)" % _a3.ok)
(ok if any("1080" in str(p) or "7893" in str(p) for p in _a3.problems) else bad)(
    "失败原因说清了端口(实得 %s)" % [str(p) for p in _a3.problems])

# ═══ 4. 空输出 / 表不存在 → 仍然 fail-closed ════════════════════════════════
_empty = nftjson.to_json("")
(ok if not _empty["nftables"] else bad)("空输入 → 空 nftables(不编造内容)")
_a4 = nftlive.audit_kernel(_empty, cidr=CIDR, platform="android")
(ok if not _a4.ok else bad)("空内核 → audit 仍判失败(fail-closed 没被桩绕过)")
# CLI 形态: 表不在时必须非零退出 + 不输出"健康"的空壳
_p = subprocess.run([sys.executable, str(ROOT / "tests/nftjson.py"), "inet", "pdg"],
                    input="table inet other {\n  chain c {\n  }\n}\n",
                    capture_output=True, text=True)
(ok if _p.returncode != 0 else bad)("表不存在 → 桩以非零退出(实得 rc=%d)" % _p.returncode)
(ok if not _p.stdout.strip() else bad)("表不存在 → 不吐出任何 JSON(实得 %r)" % _p.stdout[:40])

# ═══ 5. 状态随 `nft -f` 变化, 不沿用上一格 ══════════════════════════════════
# 判据落在**同一个转换器对两份不同输入给出不同结论**上 —— 常量桩做不到这件事。
_s1 = audit(_t)
_s2 = audit(_bad81)
(ok if _s1.ok and not _s2.ok else bad)(
    "同一个桩对两份不同现场给出不同结论(健康=%s / 缺 81=%s)" % (_s1.ok, _s2.ok))
_j1, _j2 = nftjson.to_json(_t), nftjson.to_json(_bad81)
(ok if json.dumps(_j1) != json.dumps(_j2) else bad)("两份现场的 JSON 本身就不同(不是常量)")

# ═══ 6. Android 与 iOS seed 不串台 ══════════════════════════════════════════
# iOS 装机会把 GMS 5228-5230 从 prerouting 摘掉。同一份 iOS 配置:
#   · 按 iOS 判 → 完全正常(既不失败也不点名);
#   · 按 Android 判 → 核心仍 PASS, 但 doctor 专项要点名 GMS。
_ios = _t.replace("tcp dport { 80, 443, 5228-5230 }", "tcp dport { 80, 443 }")
(ok if _ios != _t else bad)("夹具改动确实命中(iOS 形态: GMS 已摘)")
_ai = audit(_ios, platform="ios")
(ok if _ai.ok and not _ai.doctor_issues else bad)(
    "iOS 配置按 iOS 判 → 全绿(ok=%s doctor=%s)" % (_ai.ok, [str(x) for x in _ai.doctor_issues]))
_aa = audit(_ios, platform="android")
(ok if _aa.ok else bad)("同一份配置按 Android 判 → 核心仍 PASS(GMS 不是硬门)")
(ok if _aa.doctor_issues else bad)("同一份配置按 Android 判 → doctor 专项点名 GMS")
(ok if "gms" not in _ai.evaluated and "gms" in _aa.evaluated else bad)(
    "GMS 只在 Android 上算判过(iOS evaluated=%s / Android=%s)"
    % (sorted(_ai.evaluated), sorted(_aa.evaluated)))

# ═══ 7. 那四种 nft 规范化写法不会被当成故障 ═════════════════════════════════
# 模板里本来就有 `udp dport { 53 }`(单元素集合)、`udp dport 443 reject`(默认类型)、
# `ip6 nexthdr icmpv6`(协议别名)。桩必须照 nft 的规范化形态输出, 否则沙箱里复现不出
# `.153` 那类假漂移, 也就守不住"规范化不算故障"这条。
_txt = json.dumps(_j)
(ok if '"port-unreachable"' in _txt else bad)("reject 按 nft 的默认类型展开")
(ok if '"ipv6-icmp"' in _txt else bad)("icmpv6 按 nft 归一成 ipv6-icmp")
(ok if _a.ok else bad)("含这些规范化写法的配置仍判健康(不制造假漂移)")

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""救援平面「启用与否」的判据 —— 完整状态矩阵。

`pdg rescue disable` 只做两件事: 撤掉 nft 放行 + 把 PDG_RESCUE_ENABLED 写成 0。
它**不清 PDG_RESCUE_BIND** —— 监听地址是配置, 不是开关, 留着才好下次直接开。

所以"有没有 bind"和"启没启用"是两件事。拿前者当后者用, 一台停用过救援平面的机器会被判成
"已启用却没放行", doctor 判 fail, 而 `pdg update` 的更新后自检门据此**整次回滚** —— 机器
完全正常, 用户却更新不了。这与 v1.8.1 刚修掉的那个锁 bug 同一族: 自检误判把更新拖下水。

矩阵按 (intent, bind, 防火墙规则) 三维铺开, 每格都写明**为什么**是这个预期:

  intent  bind      规则      预期
  1       有效      正确      PASS
  1       有效      缺失      FAIL —— 门开着却没放行, 救援页打不开
  1       缺失/非法 任意      FAIL —— 说要开, 却没有合法监听地址
  0       保留      无        PASS —— 这才是 disable 之后的正常样子
  0       保留      仍在      FAIL —— 说停用了, 端口却还开着, 这是暴露面
  键不存在 任意     无        None —— 从未部署, 交给首次迁移语义, 不在这里猜
  键不存在 任意     有残留    FAIL —— 没记录却有规则, 如实指出, 不静默放过
  非 0/1  任意      任意      FAIL —— 意图值损坏, fail-closed
"""
import io
import os
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


import checks         # noqa: E402
import rescue_const   # noqa: E402
import rescue_nft     # noqa: E402

CIDR = "172.22.0.0/16"
BIND = "172.22.0.9"
PORT = rescue_const.port()
BOX = tmpguard.mkdtemp(prefix="rintent.")

BASE = """table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        ip saddr %s tcp dport { 53, 81, 853, 7893, 8445 } accept
%%s    }
}
""" % CIDR


def run(intent, bind, rule):
    """摆好一格现场, 跑真的 check_rescue_firewall()。

    intent: "1" / "0" / None(键不存在) / 任意损坏值
    bind:   地址字符串 / None(不写这个键) / 非法值
    rule:   "ok"(带正确的救援放行) / None(没有)
    """
    prof = os.path.join(BOX, "profile.env")
    lines = ["PDG_INTERNAL_CIDR=%s" % CIDR]
    if bind is not None:
        lines.append("PDG_RESCUE_BIND=%s" % bind)
    if intent is not None:
        lines.append("PDG_RESCUE_ENABLED=%s" % intent)
    io.open(prof, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    nft = os.path.join(BOX, "nftables.conf")
    body = ""
    if rule == "ok":
        body = rescue_nft.rule_line(CIDR, bind or BIND, PORT) + "\n"
    io.open(nft, "w", encoding="utf-8").write(BASE % body)
    # rescue_const 自己去 lib/rescue.sh 里解析 PDG_PROFILE_ENV 的默认路径, 不看
    # checks.PROFILE_ENV —— 只改后者的话 bind 永远读不到, 整组 intent=1 会假绿成 None。
    _p, _n = checks.PROFILE_ENV, checks.NFT_CONF
    _rb, _rp = rescue_const.rescue_bind, rescue_const.profile_value
    checks.PROFILE_ENV, checks.NFT_CONF = prof, nft
    rescue_const.rescue_bind = lambda profile=None: rescue_const.profile_value(
        "PDG_RESCUE_BIND", prof)
    rescue_const.profile_value = lambda k, profile=None: _rp(k, prof)
    try:
        return checks.check_rescue_firewall()
    finally:
        checks.PROFILE_ENV, checks.NFT_CONF = _p, _n
        rescue_const.rescue_bind, rescue_const.profile_value = _rb, _rp


def expect(name, got, want_level, why):
    lvl = got[0] if got else None
    if lvl == want_level:
        ok("%s → %s(%s)" % (name, want_level or "不显示", why))
    else:
        bad("%s → 期望 %s, 实得 %r" % (name, want_level or "不显示", got))
    return got


# ═══ 0. 夹具自证 ════════════════════════════════════════════════════════════
_r = rescue_nft.rule_line(CIDR, BIND, PORT)
(ok if "pdg-rescue" in _r and str(PORT) in _r else bad)(
    "夹具的救援放行由 rescue_nft.rule_line() 生成(不是手抄的): %s" % _r.strip()[:60])
(ok if checks.check_rescue_firewall in checks.ALL else bad)("这一项确实在 doctor 的 ALL 列表里")

# ═══ 1. intent=1 ════════════════════════════════════════════════════════════
print()
print("── intent=1(用户要开) ──")
expect("1a intent=1 / bind 有效 / 规则正确", run("1", BIND, "ok"), "ok",
       "门开着、地址在、放行在")
g = expect("1b intent=1 / bind 有效 / 规则缺失", run("1", BIND, None), "fail",
           "门开着却没放行 —— 救援页打不开")
(ok if g and str(PORT) in g[2] else bad)("  失败文案点名了救援端口(实得: %s)" % (g[2][:70] if g else None))
expect("1c intent=1 / bind 缺失", run("1", None, None), "fail",
       "说要开却没有监听地址")
expect("1d intent=1 / bind 非法", run("1", "999.1.1.1", None), "fail",
       "地址非法, 开不起来")

# ═══ 2. intent=0 —— 这一组是本次的核心 ══════════════════════════════════════
print()
print("── intent=0(用户明确停用) ──")
expect("2a intent=0 / bind 保留 / 无规则", run("0", BIND, None), None,
       "disable 之后的正常样子: bind 是配置不是开关, 不许据此判成已启用")
g = expect("2b intent=0 / bind 保留 / 规则仍在", run("0", BIND, "ok"), "fail",
           "说停用了端口却还开着 —— 暴露面, 不能忽略")
(ok if g and ("停用" in g[2] or "残留" in g[2]) else bad)(
    "  失败文案说清是「停用却仍有放行」(实得: %s)" % (g[2][:70] if g else None))
expect("2c intent=0 / 无 bind / 无规则", run("0", None, None), None, "同 2a")

# ═══ 3. 键不存在(从未部署) ══════════════════════════════════════════════════
print()
print("── 键不存在(从未部署过) ──")
expect("3a 键不存在 / 有 bind / 无规则", run(None, BIND, None), None,
       "交给 migrate_rescue_plane 的首次启用语义, 这里不猜")
expect("3b 键不存在 / 无 bind / 无规则", run(None, None, None), None, "同上")
expect("3c 键不存在 / 有残留规则", run(None, BIND, "ok"), "fail",
       "没记录却有放行 —— 如实指出, 不静默 PASS")

# ═══ 4. 意图值损坏 → fail-closed ════════════════════════════════════════════
print()
print("── 意图值损坏 ──")
for v in ("yes", "2", "true", ""):
    g = expect("4 intent=%r" % v, run(v, BIND, None), "fail", "取值不是 0/1, fail-closed")
    if v and g:
        (ok if v in g[2] or "意图" in g[2] else bad)(
            "  文案点名了损坏的意图值(实得: %s)" % g[2][:60])

# ═══ 5. 端口来自常量, 不是字面量 ════════════════════════════════════════════
print()
print("── 端口单一事实源 ──")
_src = io.open(str(ROOT / "deploy/bot/checks.py"), encoding="utf-8").read()
import re  # noqa: E402
_fn = re.search(r"\ndef check_rescue_firewall\(\):.*?\n(?=def )", _src, re.S)
(ok if _fn else bad)("抽到了 check_rescue_firewall 函数体")
_body = _fn.group(0) if _fn else ""
(ok if "rescue_const.port()" in _body else bad)("端口读 rescue_const.port()")
import ast  # noqa: E402
_code = _body
_m = re.search(r'"""[\s\S]*?"""', _body)
if _m:
    _code = _body[:_m.start()] + _body[_m.end():]   # 说明文字不算第二份端口表
_lits = {int(x) for x in re.findall(r"\b(\d{3,5})\b", _code)}
(ok if not _lits else bad)("函数体里没有端口字面量(实得 %s)" % sorted(_lits))

# ═══ 6. 只有一份启用判据 ════════════════════════════════════════════════════
(ok if _body.count("PDG_RESCUE_ENABLED") + _body.count("rescue_intent") <= 2 else bad)(
    "启用判据只有一处, 没有第二份")

import shutil  # noqa: E402
shutil.rmtree(BOX, ignore_errors=True)
print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""WDA 在 mihomo 后端必须用可直接翻译的内联域名规则。

旧实现仍创建 sing-box 本地 rule_set=unlock；该临时规则集没有 rulesets.json
provider 元数据，mihomo 渲染器会正确拒绝它，导致 TG Bot 永远无法打开 WDA。
"""
import copy
import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

passed = 0


def ok(message):
    global passed
    passed += 1
    print("[OK]  " + message)


def base_model():
    return {
        "inbounds": [],
        "outbounds": [
            {"type": "direct", "tag": "direct"},
            # 必须是真代理类型: 写成 {"type": "direct"} 的话渲染出来是 DOMAIN-SUFFIX,...,DIRECT,
            # 那条断言就只能证明"域名进了规则", 证明不了它指向 jp。
            {"type": "shadowsocks", "tag": "jp", "server": "198.51.100.7",
             "server_port": 8388, "method": "aes-128-gcm", "password": "x"},
        ],
        "route": {
            "rules": [
                {"action": "reject", "ip_cidr": ["203.0.113.1/32"]},
                {"domain_suffix": ["keep.example"], "outbound": "jp"},
            ],
            "rule_set": [],
            "final": "direct",
        },
    }


state = {"model": base_model(), "files": {}, "mihomo": b""}
# 现网 unlock.txt 的镜像: 事务提交什么, 它就跟着变 —— _read_unlock_domains 读的就是这份,
# 写死成空列表的话"按旧 unlock.txt 删上一版规则"那条会退化成空跑。
unlock_domains = {"v": []}

bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda domains: (True, "")
bot._platform = lambda: "ios"
bot._mitm_domains = lambda: []
bot._mihomo_rulesets = lambda rs_meta=None: {}
# 交叉用例会走 add_rule / del_rule / deletable_domains, 它们直接读现网 —— 指到沙箱状态上。
bot.load = lambda: copy.deepcopy(state["model"])
bot._read_hijack = lambda: []
bot._read_direct = lambda: []
bot._read_unlock_domains = lambda: list(unlock_domains["v"])


def fake_tx_apply(op, model_mod=None, files=None, **_kwargs):
    candidate = copy.deepcopy(state["model"])
    if model_mod:
        model_mod(candidate)
    data, meta = bot._render_mihomo_bytes(candidate, rs_meta={})
    try:
        bot.mihomorender.check_meta(meta)
    except bot.mihomorender.RenderRefused as exc:
        return False, exc.detail()
    state["model"] = candidate
    state["files"] = dict(files or {})
    state["mihomo"] = data
    raw = state["files"].get("mosdns_rule:unlock.txt")
    if raw is not None:
        unlock_domains["v"] = [line[len("domain:"):] for line in raw.decode().splitlines()
                               if line.startswith("domain:")]
    return True, "committed"


bot.tx_apply = fake_tx_apply


def wda_inline_rules(model):
    return [
        rule
        for rule in model["route"]["rules"]
        if rule.get("outbound") == "jp"
        and set(rule.get("domain_suffix", [])) == set(bot.WDA_DOMAINS)
        and len(rule.get("domain_suffix", [])) == len(bot.WDA_DOMAINS)
    ]


# ── WDA 与其它 Bot 操作的交叉 ────────────────────────────────────────────────
# 上面那些用例都活在"只开关 WDA"的世界里。真正出问题的地方在交叉处: WDA 规则内联之后,
# 它在 model 里就是一条普通的 outbound=jp 规则, 于是
#   · add_rule(x, "jp") 会把 x 并进它(add_rule 找的正是"第一条 outbound 相同且无 rule_set");
#   · del_rule / 删规则键盘 会把 55 个 WDA 域名当成用户自己加的规则;
# 任何一次这样的改动都让它不再等于 WDA_DOMAINS, _is_wda_rule 就认不出它 —— 面板显示
# "落地出口", 而关 WDA 只清空 unlock.txt, 域名继续指向 jp。半套状态, 且没有一处会报错。


def _reset_with_wda_on():
    state["model"] = base_model()
    state["files"] = {}
    success, message = bot.set_wda_mode(True)
    assert success, message
    return state["model"]


def _jp_rules(model):
    return [r for r in model["route"]["rules"] if r.get("outbound") == "jp"]


def _is_wda(rule):
    return rule in wda_inline_rules({"route": {"rules": [rule]}})


def cross_checks():
    # ── 交叉 1: WDA 开着时加一条普通 jp 分流 ──
    _reset_with_wda_on()
    success, message = bot.add_rule("example.test", "jp")
    assert success, message
    model = state["model"]
    assert len(wda_inline_rules(model)) == 1, "WDA 规则被改动了(用户域名被并了进去)"
    # 夹具里本来就有一条 keep.example → jp 的普通规则, 所以 add_rule 应该并进**那一条**
    own = [r for r in _jp_rules(model)
           if not _is_wda(r) and "example.test" in r.get("domain_suffix", [])]
    assert len(own) == 1, "用户的 example.test 该落在普通 jp 规则上: %r" % (_jp_rules(model),)
    assert "keep.example" in own[0]["domain_suffix"], "应该并进已有的那条普通 jp 规则"
    assert "example.test" not in wda_inline_rules(model)[0]["domain_suffix"]
    assert bot._wda_on(model), "加完普通规则后 WDA 仍开着, 面板不能显示成落地出口"
    ok("WDA 开着时加普通 jp 分流：另起一条规则，WDA 规则与状态都不受影响")

    # 而且此时关 WDA 必须真的关掉, 同时留下用户那条
    success, message = bot.set_wda_mode(False)
    assert success, message
    model = state["model"]
    assert not bot._wda_on(model)
    assert not any("netflix.com" in r.get("domain_suffix", []) for r in _jp_rules(model)), \
        "WDA 域名仍指向 jp = 没关掉"
    assert any("example.test" in r.get("domain_suffix", []) for r in _jp_rules(model))
    ok("加过普通规则之后仍能干净关闭 WDA，用户自己的 jp 规则保留")

    # ── 交叉 2: 删规则键盘不把 WDA 域名列成用户可删项 ──
    _reset_with_wda_on()
    listed = [d for d, _ in bot.deletable_domains() if d in bot.WDA_DOMAINS]
    assert not listed, "删规则键盘列出了 WDA 域名: %s" % listed[:3]
    bot.add_rule("example.test", "jp")
    assert "example.test" in [d for d, _ in bot.deletable_domains()], \
        "用户自己加的域名仍要能删"
    ok("删规则键盘只列用户自己的域名，不列 WDA 的 %d 个" % len(bot.WDA_DOMAINS))

    # ── 交叉 3: 单删 / 批量删一个 WDA 域名, 不许把它从 WDA 规则里抠掉 ──
    _reset_with_wda_on()
    success, _ = bot.del_rule("netflix.com")
    model = state["model"]
    assert not success, "netflix.com 属于 WDA，不该被当成用户规则删掉"
    assert len(wda_inline_rules(model)) == 1
    assert bot._wda_on(model)
    ok("del_rule 碰 WDA 域名：报未找到，WDA 规则一个域名都没少")

    # 同一个域名既在 WDA 规则里、又在用户自己的另一条出口规则里 —— .200 现网就是这样
    # (netflix.com 同时出现在 WDA 的 jp 规则和用户的 hkt 规则里)。这时外层"有没有这个域名"
    # 的判断会成立、mod 会真的跑起来, 内层跳过 WDA 规则的守卫才是唯一拦得住它的东西。
    _reset_with_wda_on()
    state["model"]["route"]["rules"].append(
        {"domain_suffix": ["netflix.com", "own.example"], "outbound": "hkt"})
    state["model"]["outbounds"].append(
        {"type": "shadowsocks", "tag": "hkt", "server": "198.51.100.9",
         "server_port": 8388, "method": "aes-128-gcm", "password": "x"})
    success, message = bot.del_rule("netflix.com")
    assert success, message
    model = state["model"]
    assert len(wda_inline_rules(model)) == 1, "WDA 规则里的 netflix.com 被一起抠掉了"
    assert bot._wda_on(model)
    hkt = [r for r in model["route"]["rules"] if r.get("outbound") == "hkt"]
    assert hkt and "netflix.com" not in hkt[0]["domain_suffix"], "用户 hkt 规则里的该删掉"
    assert "own.example" in hkt[0]["domain_suffix"]
    ok("同名域名同时在 WDA 与用户规则里：只从用户规则删，WDA 规则不动")

    _reset_with_wda_on()
    bot.add_rule("example.test", "jp")
    success, message = bot.del_rules_bulk(["netflix.com", "example.test"])
    assert success, message
    model = state["model"]
    assert len(wda_inline_rules(model)) == 1, "批量删把 WDA 规则拆了"
    assert bot._wda_on(model)
    assert not any("example.test" in r.get("domain_suffix", []) for r in _jp_rules(model)), \
        "用户自己的域名该被删掉"
    ok("del_rules_bulk 同时勾了 WDA 域名和用户域名：只删用户那条")

    # ── 交叉 4: 反复开关幂等 ──
    _reset_with_wda_on()
    for _ in range(2):
        success, message = bot.set_wda_mode(True)
        assert success, message
    assert len(wda_inline_rules(state["model"])) == 1, "重复开启插入了重复规则"
    before = len(state["model"]["route"]["rules"])
    for _ in range(2):
        success, message = bot.set_wda_mode(False)
        assert success, message
    assert not bot._wda_on(state["model"])
    assert len(state["model"]["route"]["rules"]) == before - 1
    ok("重复开启 / 重复关闭都幂等，不留重复规则")


def main():
    success, message = bot.set_wda_mode(True)
    assert success, message
    ok("WDA 开启候选可被 mihomo 渲染器完整接受")

    model = state["model"]
    assert bot._wda_on(model)
    assert len(wda_inline_rules(model)) == 1
    assert not any(r.get("rule_set") == "unlock" for r in model["route"]["rules"])
    assert not any(r.get("tag") == "unlock" for r in model["route"]["rule_set"])
    ok("开启后使用 domain_suffix 内联规则，不再创建本地 unlock rule_set")

    assert state["files"].get("ruleset:unlock.json", "MISSING") is None, \
        "开启 WDA 要顺手删掉老装遗留的 unlock.json(None = 本次事务删它), 不能只是不再写它"
    assert state["files"]["mosdns_rule:unlock.txt"]
    rendered = state["mihomo"].decode("utf-8")
    assert "DOMAIN-SUFFIX,netflix.com,jp" in rendered
    assert "RULE-SET,unlock" not in rendered
    ok("mihomo 得到真实域名规则，mosdns 解锁清单仍与 model 同事务提交")

    success, message = bot.set_wda_mode(False)
    assert success, message
    model = state["model"]
    assert not bot._wda_on(model)
    assert not wda_inline_rules(model)
    assert state["files"]["mosdns_rule:unlock.txt"] == b""
    assert state["files"].get("ruleset:unlock.json", "MISSING") is None
    assert any("keep.example" in r.get("domain_suffix", []) for r in model["route"]["rules"])
    ok("关闭 WDA 只移除 WDA 内联规则并清空 unlock.txt，不误删普通 jp 规则")

    legacy = base_model()
    legacy["route"]["rule_set"].append(
        {"tag": "unlock", "type": "local", "format": "source", "path": "/tmp/unlock.json"}
    )
    legacy["route"]["rules"].insert(1, {"rule_set": "unlock", "outbound": "jp"})
    assert bot._wda_on(legacy)
    state["model"] = legacy
    success, message = bot.set_wda_mode(True)
    assert success, message
    model = state["model"]
    assert len(wda_inline_rules(model)) == 1
    assert not any(r.get("rule_set") == "unlock" for r in model["route"]["rules"])
    assert not any(r.get("tag") == "unlock" for r in model["route"]["rule_set"])
    ok("老装的 rule_set=unlock 状态可幂等迁移为内联规则")

    old_domains = list(bot.WDA_DOMAINS[:-1])
    evolved = base_model()
    evolved["route"]["rules"].insert(
        1, {"domain_suffix": old_domains, "outbound": "jp"})
    state["model"] = evolved
    original_reader = bot._read_unlock_domains
    bot._read_unlock_domains = lambda: old_domains
    try:
        success, message = bot.set_wda_mode(True)
    finally:
        bot._read_unlock_domains = original_reader
    assert success, message
    model = state["model"]
    assert len(wda_inline_rules(model)) == 1
    assert not any(
        r.get("outbound") == "jp"
        and set(r.get("domain_suffix", [])) == set(old_domains)
        and len(r.get("domain_suffix", [])) == len(old_domains)
        for r in model["route"]["rules"]
    )
    ok("WDA 域名清单跨版本变化时，按旧 unlock.txt 精确移除上一版内联规则")

    cross_checks()

    print("PASS=%d" % passed)


if __name__ == "__main__":
    main()

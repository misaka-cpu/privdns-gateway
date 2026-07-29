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
            {"type": "direct", "tag": "jp"},
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

bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda domains: (True, "")
bot._platform = lambda: "ios"
bot._mitm_domains = lambda: []
bot._mihomo_rulesets = lambda rs_meta=None: {}


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

    assert "ruleset:unlock.json" not in state["files"]
    assert state["files"]["mosdns_rule:unlock.txt"]
    rendered = state["mihomo"].decode("utf-8")
    assert "DOMAIN-SUFFIX,netflix.com,DIRECT" in rendered
    assert "RULE-SET,unlock" not in rendered
    ok("mihomo 得到真实域名规则，mosdns 解锁清单仍与 model 同事务提交")

    success, message = bot.set_wda_mode(False)
    assert success, message
    model = state["model"]
    assert not bot._wda_on(model)
    assert not wda_inline_rules(model)
    assert state["files"]["mosdns_rule:unlock.txt"] == b""
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

    print("PASS=%d" % passed)


if __name__ == "__main__":
    main()

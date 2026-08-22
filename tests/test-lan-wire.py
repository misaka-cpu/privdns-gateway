#!/usr/bin/env python3
"""内网面板(方案 B)的 mihomo 分流接线: 面板域名 → 本机反代。

本文件最要紧的是**规则顺序**那组断言, 而顺序这件事是实测定案的, 不是推理:

  · `no-resolve` 的含义是"不要为这条规则发起 DNS 查询", **不是**"目的是域名时不匹配"。
    面板域名在 hosts: 段里被映射到本机地址, 于是 IP 在规则匹配阶段就已知 ——
    `IP-CIDR,127.0.0.0/8,REJECT,no-resolve` 会命中并把连接拒掉。
  · 真机(mihomo v1.19.29, 两个容器走真 nft REDIRECT)上的正负控:
        面板规则在前 → HTTP 200, `match DomainSuffix using DIRECT`
        REJECT 在前  → HTTP 000, `match IPCIDR(127.0.0.0/8) using REJECT`

所以"面板规则排在 REJECT 之前"不是风格问题, 是这条链路成不成立的分界。任何一次把它
改回去的重构都必须先在真机上重做那组对照。
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy" / "bot"))
import sb2mihomo  # noqa: E402

SB = {
    "outbounds": [
        {"type": "shadowsocks", "tag": "ss1", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "sp"},
        {"type": "direct", "tag": "direct"},
    ],
    "route": {
        "rules": [
            # 生产模型用的是 action: reject(不是 outbound: reject) —— 夹具要跟真源同形,
            # 否则规则根本生成不出来, 而顺序断言会在一个空列表上"通过"。
            {"ip_cidr": ["177.0.142.153/32", "127.0.0.0/8"], "action": "reject"},
            {"domain_suffix": ["openai.com"], "outbound": "ss1"},
        ],
        "final": "direct",
    },
}
LAN = ["nas.home.example.com", "ups.home.example.com"]


def idx(rules, needle):
    for n, r in enumerate(rules):
        if needle in r:
            return n
    return -1


# ── ① 不给 lan_domains 时, 什么都不该变(向后兼容) ────────────────────────────
base, _ = sb2mihomo.singbox_to_mihomo(SB)
assert "hosts" not in base, "没有面板时不该凭空生成 hosts: 段"
assert not any("home.example.com" in r for r in base["rules"])

# ── ② 给了之后: hosts 段 + DOMAIN-SUFFIX 规则 ───────────────────────────────
cfg, _ = sb2mihomo.singbox_to_mihomo(SB, lan_domains=LAN)
assert cfg["hosts"] == {d: "127.0.0.1" for d in LAN}, cfg.get("hosts")
for d in LAN:
    assert "DOMAIN-SUFFIX,%s,DIRECT" % d in cfg["rules"]

# ── ③ **顺序**: 面板规则必须在反自环 REJECT 之前 ────────────────────────────
r = cfg["rules"]
i_panel = idx(r, "nas.home.example.com")
i_rej = idx(r, "IP-CIDR,127.0.0.0/8,REJECT")
assert i_panel >= 0 and i_rej >= 0, (i_panel, i_rej)
assert i_panel < i_rej, (
    "面板规则排到了 REJECT 之后 —— 真机上这会让面板全部打不开(match IPCIDR REJECT)。"
    "顺序: %r" % r[:6])
# 另一条反自环(劫持假 IP)同样要在面板规则之后
assert i_panel < idx(r, "IP-CIDR,177.0.142.153/32,REJECT")

# ── ④ 空测: 顺序断言得有牙 ─────────────────────────────────────────────────
# 把面板规则挪到 REJECT 之后, 上面那条断言必须失败 —— 否则它证明不了任何事。
shuffled = [x for x in r if "home.example.com" not in x]
shuffled = shuffled[:2] + [x for x in r if "home.example.com" in x] + shuffled[2:]
assert idx(shuffled, "nas.home.example.com") > idx(shuffled, "IP-CIDR,127.0.0.0/8,REJECT"), \
    "空测本身构造错了"

# ── ⑤ MITM 的位置不能被面板规则带偏 ────────────────────────────────────────
# MITM 必须仍排在 REJECT **之后**: 它的域名没有 hosts 条目, 匹配时 IP 未知, 所以那个
# 位置是对的; 而且 MITM-OUT 出站自己连本机是不过规则的。两者性质不同, 不能一起挪。
both, _ = sb2mihomo.singbox_to_mihomo(SB, lan_domains=LAN, mitm_domains=["gsp-ssl.ls.apple.com"])
b = both["rules"]
i_mitm = idx(b, "MITM-OUT")
i_rej2 = idx(b, "IP-CIDR,127.0.0.0/8,REJECT")
i_panel2 = idx(b, "nas.home.example.com")
assert i_panel2 < i_rej2 < i_mitm, ("面板 < REJECT < MITM 这个次序被破坏了: %r" % b[:8])

# ── ⑥ lan_addr 可配(将来若改成绑非环回地址, 不必动渲染逻辑) ────────────────
alt, _ = sb2mihomo.singbox_to_mihomo(SB, lan_domains=LAN, lan_addr="100.64.0.5")
assert alt["hosts"] == {d: "100.64.0.5" for d in LAN}

# ── ⑦ 产出仍是合法 JSON/YAML 可序列化 ──────────────────────────────────────
json.dumps(cfg)

# ── ⑧ 守卫: 两条渲染路径都必须传环境入参 ───────────────────────────────────
# bot.py 里有**两条**渲染路径:
#   · _render_mihomo_bytes → mihomorender.render_bytes(事务用)
#   · _render_mihomo_file  → **直接调** sb2mihomo.singbox_to_mihomo(CLI 用)
# 每加一个环境入参都要在两处各写一遍。漏了一处不会报错 —— 那条路渲染出来的配置会静默
# 少掉那块能力。本轮就踩了: 面板路由在事务那条路上好好的, 从 CLI 重渲出来的配置里一条
# 都没有, 而两边都"成功"。
#
# 这条守卫按**源码**判(AST), 不按运行结果: 运行结果要造齐整套环境才测得到, 而源码里
# "有没有把这个参数传下去"是确定的。
import ast

ENV_KWARGS = {"mitm_domains", "lan_domains"}
RENDER_CALLS = {"singbox_to_mihomo", "render_bytes"}

for src in ("deploy/bot/pdg-bot.py", "deploy/bot/mihomorender.py"):
    tree = ast.parse(open(Path(__file__).resolve().parents[1] / src, encoding="utf-8").read())
    seen = 0
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fname = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
        if fname not in RENDER_CALLS:
            continue
        # 定义处不算(那是 def, 不是 call); 只看真正的调用
        kw = {k.arg for k in node.keywords if k.arg}
        # **不能因为带了 `**kwargs` 就跳过**。第一版守卫就是这么写的, 结果它恰好放过了
        # 本轮那个 bug —— 出问题的那处调用正好带着 `**_panel_render_args(model)`。
        # 一个会跳过目标场景的守卫比没有守卫更糟: 它让人以为这一类问题已经被盯住了。
        # 环境入参一律要求**显式写出来**; 真有哪天要从 ** 里传, 那次改动本来就该看这条断言。
        missing = ENV_KWARGS - kw
        assert not missing, (
            "%s 第 %d 行调用 %s 时漏了环境入参 %s —— 这条渲染路径产出的配置会"
            "静默少掉那块能力, 而调用方拿到的是成功。"
            % (src, node.lineno, fname, sorted(missing)))
        seen += 1
    assert seen >= 1, "%s 里没找到任何渲染调用 —— 守卫本身失效了(重构改了函数名?)" % src

print("test-lan-wire.py: OK")

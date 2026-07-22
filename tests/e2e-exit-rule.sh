#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 加落地出口 + 加分流规则, 全程走 **bot 的真实代码**, 并用**真内核**与**真 mosdns**
# 验证最终效果。这条链正是 issue #1 用户踩的那条:
#
#   分享链接 → parse_link → apply_sb → sb2mihomo 渲染 → 真 mihomo -t
#                                    → custom_hijack 劫持表 → 真 mosdns 解析
#
# 两个此前漏掉的接缝都在这条链上:
#   · 指到出口的域名没进 mosdns 劫持表 → 手机拿到真实 IP 直连, 内核里的规则是死的;
#   · 某些协议 sb2mihomo 转不了 → switch-core 切过去会"出口凭空消失"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
printf 'mihomo\n'  > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform

e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制(无网络?)"
e2e_fetch_mosdns || e2e_skip "取不到 mosdns 二进制"
echo "内核: $(mihomo -v 2>&1 | head -1)"

# ══ 1. 协议矩阵: 每种协议都要能 parse_link → apply_sb → 真 mihomo -t 通过 ══════
# 覆盖面直接对应"switch-core 说某出口 mihomo 无法转换"那类报障。
echo; echo "── 1. 落地协议矩阵(真实 parse_link + apply_sb + 真 mihomo -t) ──"
python3 - > /tmp/e2e-add.out 2>&1 <<'PY'
import base64, sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
ssb = base64.b64encode(b"aes-128-gcm:secret123").decode().rstrip("=")
LINKS = [
    ("shadowsocks",  "ss://%s@5.6.7.8:8388#e-ss" % ssb),
    ("hysteria2",    "hysteria2://pw@h2.example.com:8443?sni=h2.example.com&insecure=1#e-hy2"),
    ("tuic",         "tuic://11111111-2222-3333-4444-555555555555:tp@tuic.example.com:443"
                     "?sni=tuic.example.com&congestion_control=bbr#e-tuic"),
    ("vless-reality","vless://11111111-2222-3333-4444-555555555555@r.example.com:443"
                     "?security=reality&pbk=aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkMDA&sid=ab12"
                     "&sni=www.microsoft.com&flow=xtls-rprx-vision#e-reality"),
    ("trojan",       "trojan://tjpass@t.example.com:443?sni=t.example.com#e-trojan"),
]
for name, link in LINKS:
    try:
        ob = bot.parse_link(link)
    except Exception as e:
        print("FAIL|%s|parse: %s" % (name, type(e).__name__)); continue
    def mod(c, ob=ob):
        c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
        c["outbounds"].append(ob)
    okr, msg = bot.apply_sb(mod)
    print(("OK|%s|%s" % (name, ob.get("tag"))) if okr
          else ("FAIL|%s|%s" % (name, msg[:140].replace("\n", " "))))
PY
while IFS='|' read -r st name detail; do
  [[ "$st" == OK ]] && ok "落地 $name: 加入成功且真 mihomo -t 通过($detail)" \
                    || bad "落地 $name: $detail"
done < /tmp/e2e-add.out

# ══ 2. 分流规则: 内核规则 + mosdns 劫持表必须同步 ═════════════════════════════
echo; echo "── 2. 加分流规则(真实 add_rule) ──"
python3 - > /tmp/e2e-rule.out 2>&1 <<'PY'
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
for dom, tgt in (("ip.skk.moe", "e-ss"), ("cdn.example.test", "e-hy2")):
    okr, msg = bot.add_rule(dom, tgt)
    print(("OK|%s|%s" % (dom, tgt)) if okr else ("FAIL|%s|%s" % (dom, msg[:120])))
PY
while IFS='|' read -r st dom tgt; do
  [[ "$st" == OK ]] && ok "分流 $dom → $tgt 写入成功" || bad "分流 $dom: $tgt"
done < /tmp/e2e-rule.out

python3 - <<'PY' > /tmp/e2e-state.out
import json
c = json.load(open("/etc/sing-box/config.json"))
rules = {d: r.get("outbound") for r in c["route"]["rules"] for d in r.get("domain_suffix", [])}
m = json.load(open("/etc/mihomo/config.yaml"))
print("KERNEL_RULE|%s" % rules.get("ip.skk.moe"))
print("MIHOMO_PROXIES|%s" % ",".join(p["name"] for p in m.get("proxies", []) if p["name"].startswith("e-")))
print("MIHOMO_RULE|%s" % ("yes" if any("ip.skk.moe" in r and "e-ss" in r for r in m.get("rules", [])) else "no"))
PY
grep -q 'KERNEL_RULE|e-ss' /tmp/e2e-state.out && ok "内核 route 规则: ip.skk.moe → e-ss" || bad "内核规则没写对"
grep -q 'MIHOMO_RULE|yes' /tmp/e2e-state.out && ok "渲染进 mihomo: DOMAIN-SUFFIX 规则指向该出口" || bad "mihomo 规则缺失"
n=$(grep -c '^domain:' /etc/mosdns/rules/custom_hijack.txt)
[[ "$n" == 2 ]] && ok "mosdns 劫持表同步收录 2 个域名" || bad "劫持表有 $n 条"

# ══ 3. 真 mosdns: 指到出口的域名必须解析到网关(否则规则是死的) ════════════════
echo; echo "── 3. 真 mosdns 验证解析结果 ──"
e2e_mosdns_start
[[ "$(e2e_q ip.skk.moe)" == "$E2E_SIP" ]] \
  && ok "ip.skk.moe → 网关 $E2E_SIP(分流真正生效; 修复前这里返真实 IP → 手机直连)" \
  || bad "ip.skk.moe → $(e2e_q ip.skk.moe)"
[[ "$(e2e_q cdn.example.test)" == "$E2E_SIP" ]] && ok "cdn.example.test → 网关" || bad "第二条规则未生效"
[[ "$(e2e_q baidu.com)" != "$E2E_SIP" ]] && ok "baidu.com(国内)不被劫持" || bad "国内域名被误劫持"
e2e_mosdns_stop

# ══ 4. 删规则: 内核与劫持表必须同步清理 ══════════════════════════════════════
echo; echo "── 4. 删规则 ──"
python3 - <<'PY' >/dev/null 2>&1
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot; bot.del_rule("ip.skk.moe")
PY
python3 - <<'PY' > /tmp/e2e-del.out
import json
c = json.load(open("/etc/sing-box/config.json"))
left = sorted({d for r in c["route"]["rules"] for d in r.get("domain_suffix", [])})
hij = sorted(l.strip().replace("domain:", "") for l in open("/etc/mosdns/rules/custom_hijack.txt")
             if l.startswith("domain:"))
print("LEFT|%s" % ",".join(left)); print("HIJ|%s" % ",".join(hij))
PY
grep -q 'LEFT|cdn.example.test$' /tmp/e2e-del.out && ok "内核规则只剩另一条(精确删除)" || bad "内核删除不对: $(grep LEFT /tmp/e2e-del.out)"
grep -q 'HIJ|cdn.example.test$'  /tmp/e2e-del.out && ok "劫持表同步只剩另一条(不残留死域名)" || bad "劫持表删除不对: $(grep HIJ /tmp/e2e-del.out)"

# ══ 5. 设直连: 必须写 custom_direct 且从劫持表移除 ═══════════════════════════
echo; echo "── 5. 改判直连 ──"
python3 - <<'PY' >/dev/null 2>&1
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot; bot.add_rule("cdn.example.test", "direct")
PY
{ grep -q 'cdn.example.test' /etc/mosdns/rules/custom_direct.txt \
  && ! grep -q 'cdn.example.test' /etc/mosdns/rules/custom_hijack.txt; } \
  && ok "改判直连: 进直连表并**移出**劫持表(直连意图不被劫持覆盖)" || bad "直连/劫持表状态不对"
e2e_mosdns_start
[[ "$(e2e_q cdn.example.test)" != "$E2E_SIP" ]] && ok "真 mosdns: 改判直连后不再劫持到网关" || bad "改直连后仍被劫持"
e2e_mosdns_stop

e2e_summary

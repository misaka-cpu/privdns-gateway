#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 真的切一次内核。两个内核二进制都取真的, 走真正的 cmd_switch_core,
# 用真 mihomo -t / sing-box check 校验渲染产物。
#
# 对应 issue #1 的"不能用命令切换 sing-box/mihomo, 会直接报错然后回退" —— 单测只能
# 打桩 activate/restore, 转换本身能不能过全靠真内核说了算。
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
e2e_seed_nft singbox
printf 'android\n' > /etc/privdns-gateway/platform
printf 'singbox\n' > /etc/privdns-gateway/backend

e2e_fetch_mihomo  || e2e_skip "取不到 mihomo 二进制"
e2e_fetch_singbox || e2e_skip "取不到 sing-box 二进制"
echo "内核: $(mihomo -v 2>&1|head -1) / $(sing-box version 2>&1|head -1)"

# 先加几个真实协议出口 —— 切核最容易翻车的正是"某协议转不过去"
python3 - >/dev/null 2>&1 <<'PY'
import base64, sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
ssb = base64.b64encode(b"aes-128-gcm:secret123").decode().rstrip("=")
for link in ("ss://%s@5.6.7.8:8388#e-ss" % ssb,
             "trojan://tjpass@t.example.com:443?sni=t.example.com#e-trojan",
             "hysteria2://pw@h2.example.com:8443?sni=h2.example.com&insecure=1#e-hy2"):
    ob = bot.parse_link(link)
    def mod(c, ob=ob):
        c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
        c["outbounds"].append(ob)
    bot.apply_sb(mod)
PY
n=$(python3 -c "import json;print(len([o for o in json.load(open('/etc/sing-box/config.json'))['outbounds'] if o.get('tag','').startswith('e-')]))")
[[ "$n" == 3 ]] && ok "前置: 3 个真实协议出口就位" || bad "前置只有 $n 个出口"

# ══ 1. singbox → mihomo ══════════════════════════════════════════════════════
echo; echo "── 1. 切到 mihomo ──"
out=$(bash /usr/local/bin/pdg switch-core mihomo 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已切换到 mihomo' <<<"$out"; } \
  && ok "switch-core mihomo 成功(3 个协议全部转换通过)" || bad "切换失败 rc=$rc: $(tail -4 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/backend)" == mihomo ]] && ok "backend 标记 → mihomo" || bad "标记未切"
mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1 \
  && ok "真 mihomo -t 接受切换后的配置" || bad "切完的 mihomo 配置校验不过"
python3 -c "
import json,sys
d=json.load(open('/etc/mihomo/config.yaml'))
names={p['name'] for p in d.get('proxies',[])}
sys.exit(0 if {'e-ss','e-trojan','e-hy2'} <= names else 1)" \
  && ok "三个出口都在 mihomo 配置里(没有凭空丢失)" || bad "切核后出口丢失"

# ══ 2. mihomo → singbox ══════════════════════════════════════════════════════
echo; echo "── 2. 切回 sing-box ──"
out=$(bash /usr/local/bin/pdg switch-core singbox 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已切换到 singbox' <<<"$out"; } \
  && ok "switch-core singbox 成功" || bad "切回失败 rc=$rc: $(tail -4 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] && ok "backend 标记 → singbox" || bad "标记未切回"
sing-box check -c /etc/sing-box/config.json >/dev/null 2>&1 \
  && ok "真 sing-box check 接受切回后的配置" || bad "切回的 sing-box 配置校验不过"

# ══ 3. 已是目标内核 → 幂等, 不做无谓动作 ═════════════════════════════════════
out=$(bash /usr/local/bin/pdg switch-core singbox 2>&1)
grep -q '已经是 singbox 内核' <<<"$out" && ok "已是目标内核 → 直接返回(不重复切)" || bad "幂等提示缺失: $out"

# ══ 4. 有出口转不过去 → 必须拒绝并**点名**是哪个 ══════════════════════════════
echo; echo "── 4. 注入一个 mihomo 转不了的出口 ──"
python3 - <<'PY' >/dev/null 2>&1
import json
f = "/etc/sing-box/config.json"; c = json.load(open(f))
c["outbounds"].append({"type": "wireguard", "tag": "e-wg-unsupported",
                       "server": "wg.example.com", "server_port": 51820,
                       "private_key": "aaaa", "peer_public_key": "bbbb", "local_address": ["10.0.0.2/32"]})
json.dump(c, open(f, "w"), ensure_ascii=False, indent=2)
PY
out=$(bash /usr/local/bin/pdg switch-core mihomo 2>&1); rc=$?
if [[ "$rc" != 0 ]]; then
  ok "转换不了 → 拒绝切换(返回非0)"
  grep -q 'e-wg-unsupported' <<<"$out" \
    && ok "并**点名**是哪个出口转不了(不再只说'渲染/校验失败')" \
    || bad "没点名具体出口: $(tail -3 <<<"$out")"
  [[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] && ok "拒绝后 backend 标记已回滚" || bad "标记没回滚"
else
  bad "wireguard 出口应被判为无法转换并拒绝切换, 实际却切成功了(它会被静默丢弃)"
fi

e2e_summary

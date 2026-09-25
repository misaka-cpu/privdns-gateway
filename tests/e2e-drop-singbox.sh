#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 真的把一台"仍在跑 sing-box 的老机器"迁到 mihomo(v1.6.0 移除 sing-box 运行时)。
# 取**真** mihomo 二进制、真实协议出口, 走真正的 migrate_drop_singbox / _activate_mihomo_core,
# 用真 `mihomo -t` 校验渲染产物。
#
# 单测只能打桩 activate/restore 与渲染, "这些出口到底转不转得过去"全靠真内核说了算 ——
# 而迁移一旦丢出口就是线上事故(用户的落地节点凭空少一个), 故必须端到端验一遍。
#
# 三次迁移都走公开入口 `pdg migrate`: 快照、服务前像、句柄与锁由产品自己建立。这台机器是确认的 android,
# 共享夹具按通配装进了 iOS 专属件, 无句柄的内部入口 `pdg __migrate` 会被退役前置整条拒掉(289 基线实测
# 三次都是), 目标迁移一步都到不了。每次调用当场接住真实退出码, 完整输出落 $E2E_TMP/ds<N>.log。
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
e2e_seed_nft
printf 'android\n' > /etc/privdns-gateway/platform
# 老机器现场: backend 仍是 singbox, sing-box 二进制 + unit 都在
printf 'singbox\n' > /etc/privdns-gateway/backend
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/sing-box; chmod 755 /usr/local/bin/sing-box
# 老版装机真正生成的 unit 形态 —— 归属判定据此认出"这是本项目装的"才会去清理它
# (随手写的 `[Unit]` 桩不具备该特征, 会被当成第三方 sing-box 保留, 那是另一条分支)
cat > /etc/systemd/system/sing-box.service <<'SBU'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SBU

e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"
echo "内核: $(mihomo -v 2>&1 | head -1)"

# 先加几个真实协议出口 —— 迁移最容易翻车的正是"某协议转不过去"
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

# ══ 1. 有出口转不过去 → 迁移必须拒绝、点名、且不动 sing-box 运行时 ════════════
# (先测失败路径: 此时机器还完整, 正好验"失败不留半迁移态")
echo; echo "── 1. 注入一个 mihomo 转不了的出口 → 迁移应拒绝 ──"
python3 - <<'PY' >/dev/null 2>&1
import json
f = "/etc/sing-box/config.json"; c = json.load(open(f))
c["outbounds"].append({"type": "wireguard", "tag": "e-wg-unsupported",
                       "server": "wg.example.com", "server_port": 51820,
                       "private_key": "aaaa", "peer_public_key": "bbbb", "local_address": ["10.0.0.2/32"]})
json.dump(c, open(f, "w"), ensure_ascii=False, indent=2)
PY
bash /usr/local/bin/pdg migrate > "$E2E_TMP/ds1.log" 2>&1; rc=$?
echo "   [记录] ds1: pdg migrate 退出码 = $rc(完整输出在 ds1.log)"
# 观测先于判定, 且独立结算: 日志读不全(cat 非零, 哪怕已经吐出一部分)或到达查询本身执行失败(grep ≥2),
# 都是观测无效 —— 不据此判到达 / 拒绝 / 成功, 也不进入下面按产品退出码的分支。产品退出码已在上一行单独记下。
out="$(cat "$E2E_TMP/ds1.log")"; lrc=$?
# 拒绝必须由**出口转换检查**做出: 那一步说"这些出口 mihomo 无法转换"; 链上 `migrate_drop_singbox || rc=1`,
# 整次命令于是返回 1。只看"非零"会把取锁 / 快照 / 退役前置 / 执行异常的提前停止都算成目标拒绝。
g=-; (( lrc == 0 )) && { grep -q '这些出口 mihomo 无法转换' <<<"$out"; g=$?; }   # 0 找到 / 1 确认没找到 / ≥2 查询执行失败
if (( lrc != 0 )); then
  bad "ds1 观测无效: 日志读取失败(cat 退出码 $lrc), 不据可能已吐出的半截内容判到达或拒绝(产品退出码 $rc 已单独记录)"
elif (( g >= 2 )); then
  bad "ds1 观测无效: 到达查询执行失败(grep 退出码 $g), 不归为'没到达出口转换检查'(产品退出码 $rc 已单独记录)"
elif [[ "$g" == 0 && "$rc" == 1 ]]; then
  ok "转换不了 → 到达出口转换检查并由它拒绝, 整次命令返回 1(据此让 pdg update 回滚到更新前快照)"
  grep -q 'e-wg-unsupported' <<<"$out" \
    && ok "并**点名**是哪个出口转不了(不再只说'渲染/校验失败')" \
    || bad "没点名具体出口: $(tail -3 <<<"$out")"
  # 转换检查之前产品已把标记切到 mihomo; "已回滚"要有产品自己报的回滚, 再加现场复原 —— 不拿"仍是原值"冒充。
  { grep -q '未迁移(已回滚标记)' <<<"$out" && [[ "$(cat /etc/privdns-gateway/backend)" == singbox ]]; } \
    && ok "拒绝后 backend 标记已回滚" || bad "标记没回滚: backend=$(cat /etc/privdns-gateway/backend 2>&1)"
  { [[ -e /usr/local/bin/sing-box ]] && [[ -e /etc/systemd/system/sing-box.service ]]; } \
    && ok "拒绝后 sing-box 运行时原样保留(用户仍能用旧版, 无半迁移态)" || bad "sing-box 被误删"
elif [[ "$rc" == 0 ]]; then
  bad "wireguard 出口应被判为无法转换并拒绝迁移, 实际却迁成功了(它会被静默丢弃)"
elif [[ "$g" == 0 ]]; then
  bad "到达了出口转换检查, 但整次命令退出码 $rc(应为 1)—— 执行异常, 不算目标拒绝已验证"
else
  bad "整次命令退出码 $rc, 但没到达出口转换检查 —— 上游提前停止不能顶替目标拒绝: $(grep -E '❌|⛔' <<<"$out" | head -2 | tr '\n' ' ')"
fi

# ══ 2. 去掉那个出口 → 迁移应成功, 3 个真实出口一个不少 ═══════════════════════
echo; echo "── 2. 移除不可转换出口 → 迁移应成功 ──"
python3 - <<'PY' >/dev/null 2>&1
import json
f = "/etc/sing-box/config.json"; c = json.load(open(f))
c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != "e-wg-unsupported"]
json.dump(c, open(f, "w"), ensure_ascii=False, indent=2)
PY
bash /usr/local/bin/pdg migrate > "$E2E_TMP/ds2.log" 2>&1; rc=$?
echo "   [记录] ds2: pdg migrate 退出码 = $rc(完整输出在 ds2.log)"
out="$(cat "$E2E_TMP/ds2.log")"; lrc=$?          # 读不全 = 观测无效: 不据半截内容判成功(产品退出码已在上一行单独记下)
if (( lrc != 0 )); then
  bad "ds2 观测无效: 日志读取失败(cat 退出码 $lrc), 不据可能已吐出的半截内容判迁移成功(产品退出码 $rc 已单独记录)"
elif [[ "$rc" == 0 ]] && grep -q 'sing-box 运行时已移除' <<<"$out"; then
  ok "迁移成功(3 个协议全部转换通过)"
else
  bad "迁移失败 rc=$rc: $(tail -4 <<<"$out")"
fi
[[ "$(cat /etc/privdns-gateway/backend)" == mihomo ]] && ok "backend 标记 → mihomo" || bad "标记未切"
mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1 \
  && ok "真 mihomo -t 接受迁移后的配置" || bad "迁移后的 mihomo 配置校验不过"
python3 -c "
import json,sys
d=json.load(open('/etc/mihomo/config.yaml'))
names={p['name'] for p in d.get('proxies',[])}
sys.exit(0 if {'e-ss','e-trojan','e-hy2'} <= names else 1)" \
  && ok "三个出口都在 mihomo 配置里(迁移没有凭空丢失)" || bad "迁移后出口丢失"
{ [[ ! -e /usr/local/bin/sing-box ]] && [[ ! -e /etc/systemd/system/sing-box.service ]]; } \
  && ok "sing-box 二进制与 unit 已彻底移除" || bad "sing-box 运行时仍有残留"
grep -q 'redirect' /etc/nftables.conf \
  && ok "防火墙已换成 mihomo 的 REDIRECT 入站模型" || bad "nft 未切到 mihomo 变体"

# ══ 3. 幂等: 已是纯 mihomo 再迁一次 → 直接过, 不重复动内核 ═══════════════════
echo; echo "── 3. 幂等 ──"
# 前提: 二那一格真的迁完了(backend=mihomo、sing-box 二进制与 unit 都已不在)。前提不成立时,
# "二跑没再动内核"证明不了幂等 —— 记失败, 不拿后续现场不变冒充; 二跑和"二跑后配置仍合法"都不执行。
# 闸是这个前提本身, 不看此前累计了几次失败。
if [[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == mihomo && ! -e /usr/local/bin/sing-box && ! -e /etc/systemd/system/sing-box.service ]]; then
  bash /usr/local/bin/pdg migrate > "$E2E_TMP/ds3.log" 2>&1; rc=$?
  echo "   [记录] ds3: pdg migrate 退出码 = $rc(完整输出在 ds3.log)"
  grep -q '检测到 sing-box 运行时' "$E2E_TMP/ds3.log"; g=$?          # 0 有 / 1 没有 / ≥2 查不了(不当"没有")
  { [[ "$rc" == 0 && "$g" == 1 ]]; } \
    && ok "已是纯 mihomo → 迁移短路(不重复迁)" || bad "二次迁移未短路 rc=$rc grep=$g: $(tail -3 "$E2E_TMP/ds3.log")"
  mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml >/dev/null 2>&1 \
    && ok "二跑后配置仍合法" || bad "二跑把配置搞坏了"
else
  bad "3 前置不成立: 二那一格没迁完(backend=$(cat /etc/privdns-gateway/backend 2>&1); sing-box 残留=$([[ -e /usr/local/bin/sing-box || -e /etc/systemd/system/sing-box.service ]] && echo 有 || echo 无))—— 二跑证明不了幂等; 二跑与'二跑后配置仍合法'校验都未执行, 本格未执行"
fi

e2e_summary

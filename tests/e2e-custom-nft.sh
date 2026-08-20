#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 迁移不得让**不属于本项目**的防火墙配置失效(P0)。
#
# 上一轮只做到"文本保留": 把用户的表原样留在 /etc/nftables.conf 里。但那不等于规则还有效 ——
# PDG 自己的 `table inet pdg` 带 `hook input priority 0; policy drop`, 而 nftables 里**同一
# hook 上的多个 base chain 都会执行**, 任何一条判 drop 包就没了。于是用户 chain 里对 9443 /
# WireGuard 的 accept 形同虚设: 配置看着还在, 端口实际已经不通, 而迁移还报"成功"。
#
# 保守方案: 除 pdg 外还存在挂 `hook input` 的 base chain(**配置文件或当前运行 ruleset 任一**)
# → 在动任何东西之前中止迁移, 让用户自己合并。没挂 input hook 的 NAT/forward/VPN 表不受影响,
# 照常保留。
#
# 本用例不靠 grep 断言: nft 桩维护**真的 ruleset 状态**, 前后比对配置哈希 + 运行规则 + 服务状态。
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
printf 'android\n' > /etc/privdns-gateway/platform
. "$E2E_ROOT/lib/versions.sh"
printf '#!/bin/sh\ncase "$1" in -v|version) echo "Mihomo Meta %s linux amd64";; -t) exit 0;; esac\nexit 0\n' \
  "$MIHOMO_VER" > /usr/local/bin/mihomo; chmod 755 /usr/local/bin/mihomo

# ── 带**真状态**的 nft 桩 ────────────────────────────────────────────────────
# 只记调用的桩证明不了"运行规则没变"。这里维护一份"已加载 ruleset":
#   nft -f FILE      → 把 FILE 内容装载为当前 ruleset(模拟真的生效)
#   nft -c -f FILE   → 只校验, 不改状态
#   nft list ruleset → 打印当前 ruleset
NFT_STATE=$E2E_TMP/e2e-nft-ruleset
# nft 桩走 e2e-lib.sh 的唯一实现。原来这里是一份私有的简化桩, **没有 `-j` 分支** ——
# 被测路径一旦走到 nftlive(它读的正是 `nft -j list table`), 桩会静默返回空, 于是断言
# 读到一个"看着健康"的空表。共享桩把 -j 接到 tests/nftjson.py 上, 表不在就非零退出。
e2e_write_nft_stub

seed_sb(){   # 造出"仍在跑 sing-box 的老机器"(unit 用老版真实形态 + 归属标记, 迁移才会走完整路径)
  printf 'singbox\n' > /etc/privdns-gateway/backend
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/sing-box; chmod 755 /usr/local/bin/sing-box
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
  : > /etc/privdns-gateway/singbox.pdg-owned      # 可信归属标记: 确属本项目所装
  echo 1 > $E2E_TMP/e2e-svc/sing-box.ac; echo 1 > $E2E_TMP/e2e-svc/sing-box.en
  rm -f $E2E_TMP/e2e-svc/mihomo.ac $E2E_TMP/e2e-svc/mihomo.en
}

svc_state(){ printf '%s/%s|%s/%s' \
  "$(systemctl is-active sing-box 2>/dev/null)" "$(systemctl is-enabled sing-box 2>/dev/null)" \
  "$(systemctl is-active mihomo 2>/dev/null)"   "$(systemctl is-enabled mihomo 2>/dev/null)"; }

# ══ 场景 1: 存在**外部 input base chain** → 迁移必须在动任何东西之前中止 ══════
echo "── 1. 用户有自己的 input base chain(与 PDG 的 policy drop 不兼容) ──"
seed_sb
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
# 用户自己的过滤表: 放行业务端口与 WireGuard
table inet myfilter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 9443, 9444 } accept
        udp dport 51820 accept
    }
}

table ip mynat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.66.0.0/24 oifname "eth0" masquerade
    }
}

table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
    }
}
NFT
nft -f /etc/nftables.conf                       # 让"当前运行 ruleset"= 这份配置
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(nft list ruleset | sha256sum | cut -d' ' -f1)"
SVC_BEFORE="$(svc_state)"

out=$(bash /usr/local/bin/pdg __migrate 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "迁移中止(返回非0), 未在不兼容现场硬切" || bad "1: 迁移居然成功了 rc=$rc"
grep -qE 'input.*base chain|自定义 input' <<<"$out" \
  && ok "说明了原因: 检测到自定义 input base chain" || bad "1b: 没说清原因: $(tail -4 <<<"$out")"
grep -q 'myfilter' <<<"$out" \
  && ok "点名了冲突的表(myfilter), 便于用户手工合并" || bad "1c: 没点名冲突表"

# 关键: 不是看文本, 而是看**配置哈希 / 运行规则 / 服务状态**三者都没动
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]] \
  && ok "中止后 /etc/nftables.conf 逐字节未变" || bad "1d: 配置被改写了"
[[ "$(nft list ruleset | sha256sum | cut -d' ' -f1)" == "$RULESET_SHA" ]] \
  && ok "中止后**运行中的 ruleset** 未变(没执行 nft -f)" || bad "1e: 运行规则被改了"
[[ "$(svc_state)" == "$SVC_BEFORE" ]] \
  && ok "中止后核心服务状态未变(sing-box 仍在跑, 没起 mihomo)" || bad "1f: 服务状态变了: $SVC_BEFORE → $(svc_state)"
[[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] \
  && ok "中止后 backend 标记仍是 singbox" || bad "1g: backend=$(cat /etc/privdns-gateway/backend)"
[[ -e /usr/local/bin/sing-box && -e /etc/systemd/system/sing-box.service ]] \
  && ok "中止后 sing-box 运行时原样保留" || bad "1h: sing-box 被动了"

# ══ 场景 2: 只有 NAT/forward(不挂 input hook)→ 迁移照常进行且原样保留 ════════
echo; echo "── 2. 用户只有 NAT/forward/VPN 表(不挂 input hook) ──"
seed_sb
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table ip mynat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.66.0.0/24 oifname "eth0" masquerade   # VPN 出网 NAT
    }
}

table inet myfwd {
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "wg0" oifname "eth0" accept
        oifname "wg0" iifname "eth0" ct state established,related accept
    }
}

table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
        ip saddr 127.0.0.0/8 tcp dport { 53, 80, 81, 443, 853, 8445 } accept
    }
}
NFT
nft -f /etc/nftables.conf
CUSTOM_BEFORE="$(awk '/table inet pdg/{exit} {print}' /etc/nftables.conf)"
CUSTOM_SHA="$(printf '%s' "$CUSTOM_BEFORE" | sha256sum | cut -d' ' -f1)"

out=$(bash /usr/local/bin/pdg __migrate 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "无 input hook 冲突 → 迁移正常完成" || bad "2: 迁移失败 rc=$rc: $(tail -5 <<<"$out")"
CUSTOM_AFTER="$(awk '/table inet pdg/{exit} {print}' /etc/nftables.conf)"
[[ "$(printf '%s' "$CUSTOM_AFTER" | sha256sum | cut -d' ' -f1)" == "$CUSTOM_SHA" ]] \
  && ok "项目管理区之外的内容逐字节未变" \
  || { bad "2b: 自定义区被改写"; diff <(printf '%s\n' "$CUSTOM_BEFORE") <(printf '%s\n' "$CUSTOM_AFTER") | head -8; }
# 运行 ruleset 里也要真的还有这些规则(而不是只留在文件里)
rs="$(nft list ruleset)"
for probe in 'table ip mynat' 'masquerade' 'table inet myfwd' 'wg0'; do
  grep -qF "$probe" <<<"$rs" && ok "运行 ruleset 仍含: $probe" || bad "2c: 运行规则里没了 $probe"
done
grep -q 'redirect to :7893' <<<"$rs" \
  && ok "运行 ruleset 已换成 mihomo REDIRECT 入站(迁移真做了事)" || bad "2d: pdg 区没生效"
[[ "$(grep -c '^table inet pdg {' /etc/nftables.conf)" == 1 ]] \
  && ok "pdg 表只有一份(没有重复拼接)" || bad "2e: pdg 表重复"
grep -q 'tcp dport { 22 } accept' /etc/nftables.conf \
  && ok "SSH 端口仍放行(没把自己锁在门外)" || bad "2f: SSH 放行没了"

# ══ 场景 3: `nft list ruleset` 读不到 → 不能当成"现场干净"就往下切 ═══════════
# 配置文件干净、但内存里可能还挂着 input 链(非 root / nft 不可用时根本看不到)。
# 旧实现把读失败静默当成没有冲突, 于是照常迁移 —— "配置保留、端口不通"换个入口又回来了。
echo; echo "── 3. 运行 ruleset 读不到(权限不足/nft 不可用) ──"
seed_sb
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg

table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        tcp dport { 22 } accept
    }
}
NFT
nft -f /etc/nftables.conf
CONF_SHA3="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA3="$(nft list ruleset | sha256sum | cut -d' ' -f1)"
SVC_BEFORE3="$(svc_state)"
# 只让 `list ruleset` 失败(真实形态: nft 在, 但读 ruleset 要 CAP_NET_ADMIN), 其余子命令照旧
cp /usr/local/bin/nft /usr/local/bin/nft.real
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
if [ "$1" = list ] && [ "$2" = ruleset ]; then
  echo "Error: Could not process rule: Operation not permitted" >&2; exit 1
fi
exec /usr/local/bin/nft.real "$@"
S
chmod 755 /usr/local/bin/nft

out=$(bash /usr/local/bin/pdg __migrate 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "读不到运行 ruleset → 迁移中止(不冒充现场干净)" || bad "3: 居然照常迁移了 rc=$rc"
grep -q '无法确认' <<<"$out" \
  && ok "说明了原因: 无法确认是否存在其它 input base chain" || bad "3b: 没说清原因: $(tail -4 <<<"$out")"
cp -f /usr/local/bin/nft.real /usr/local/bin/nft      # 还原后再验现场
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA3" ]] \
  && ok "中止后 /etc/nftables.conf 逐字节未变" || bad "3c: 配置被改写了"
[[ "$(nft list ruleset | sha256sum | cut -d' ' -f1)" == "$RULESET_SHA3" ]] \
  && ok "中止后运行中的 ruleset 未变" || bad "3d: 运行规则被改了"
[[ "$(svc_state)" == "$SVC_BEFORE3" ]] \
  && ok "中止后核心服务状态未变" || bad "3e: 服务状态变了: $SVC_BEFORE3 → $(svc_state)"
[[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] \
  && ok "中止后 backend 标记仍是 singbox" || bad "3f: backend=$(cat /etc/privdns-gateway/backend)"

# ══ 场景 4: 迁移**之后**用户再加 input 链 → doctor 要报出来 ═════════════════
# 前置门只管迁移当时; 之后现场变了没人再提醒, 端口看着开着实际不通。
echo; echo "── 4. 迁移后新增 input 链 → pdg doctor 报冲突 ──"
cat >> /etc/nftables.conf <<'NFT'

table inet lateradd {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 9443 accept
    }
}
NFT
nft -f /etc/nftables.conf
d_out=$(python3 -c "
import sys; sys.path.insert(0,'/opt/pdg-bot')
import checks
print(checks.check_nft_input_chains())" 2>&1)
grep -q "'fail'" <<<"$d_out" && grep -q 'lateradd' <<<"$d_out" \
  && ok "doctor 报出后加的 input 链(inet lateradd)" || bad "4: doctor 没报: $d_out"
# 去掉后应回到 ok(不是恒报警)
python3 - <<'PY'
txt = open("/etc/nftables.conf", encoding="utf-8").read()
open("/etc/nftables.conf", "w", encoding="utf-8").write(txt.split("table inet lateradd")[0])
PY
nft -f /etc/nftables.conf
d_out=$(python3 -c "
import sys; sys.path.insert(0,'/opt/pdg-bot')
import checks
print(checks.check_nft_input_chains())" 2>&1)
grep -q "'ok'" <<<"$d_out" && ok "冲突链移除后 doctor 回到 ok(不恒报警)" || bad "4b: $d_out"

rm -f "$NFT_STATE" /usr/local/bin/nft.real
e2e_summary

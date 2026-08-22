#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 主防火墙的重新加载必须只走 _nft_apply_main 这**一个入口**。
#
# 为什么: /etc/nftables.conf 开头是 `flush ruleset`, 它把**整个** ruleset 清掉 ——
# 内网面板的出站白名单(inet pdglan)一起没。而 pdg-lan 不会因此重启, 于是"反代在跑、
# 门三已经不存在"这个状态会在每次防火墙重建之后悄悄出现。那一刻反代能连到内网任意地址,
# 这是安全洞不是不便。真机复现过: pdg update 之后 doctor 立刻报"内核里没有 inet pdglan 表"。
#
# 入口函数在主规则加载完之后把白名单补回去。新写的裸调会绕过它, 而绕过的后果没有任何
# 提示 —— 所以这条守卫存在。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT/deploy/bot/pdg.sh"
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# 函数定义那一行自己不算
raw="$(grep -nE 'nft -f +"?/etc/nftables\.conf' "$F" | grep -v '_nft_apply_main()' || true)"
if [[ -z "$raw" ]]; then
  ok "pdg.sh 里没有绕过 _nft_apply_main 的裸调"
else
  bad "这些地方直接 nft -f /etc/nftables.conf, 会把内网面板的白名单冲掉而不补回来:"
  printf '%s\n' "$raw" | sed 's/^/    /'
fi

grep -q '^_nft_apply_main(){' "$F" \
  && ok "入口函数存在" || bad "找不到 _nft_apply_main —— 守卫失效(被重命名了?)"
grep -q '_lan_nft_reapply' "$F" \
  && ok "入口函数里会补白名单" || bad "_nft_apply_main 没有调 _lan_nft_reapply"

# 空测: 判据要真的认得出裸调, 否则它永远绿
if grep -qE 'nft -f +"?/etc/nftables\.conf' <<<'  nft -f /etc/nftables.conf'; then
  ok "反向对照: 判据认得出裸调这一形态"
else
  bad "判据本身失效 —— 连一行明显的裸调都匹配不到"
fi

echo "────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" -eq 0 ]]

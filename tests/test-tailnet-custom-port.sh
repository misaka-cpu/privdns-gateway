#!/usr/bin/env bash
# `pdg ssh-source tailnet` 放行的 UDP 端口必须**跟着 tailscaled 实际配置的端口走**。
#
# 41641 是 Tailscale 的官方默认值, 但它是可配的 —— Debian 12 上来自 /etc/default/tailscaled
# 的 `PORT=`, unit 经 EnvironmentFile 传给 `tailscaled --port=${PORT}`。项目里那个数字一直是
# 硬编码常量, 生成规则时从不读那份文件。
#
# 后果是**双向失效**, 而且从配置上完全看不出两者有关系:
#   · 41641 那条没有监听者, 成了永远不会有人应答的陈旧放行;
#   · 真正在用的端口被 input 链的 policy drop 挡掉。
# 于是 `pdg ssh-source tailnet` 当初要消除的冷启动窗口原样回来: 空闲几小时后出事想连进去,
# 第一次 SSH 必超时 —— 而这正是这条命令存在的全部理由。
#
# doctor 早就能看见这件事(check_tailnet_direct_port), 但它只会告诉你"本命令不会替你处理"。
# 这一支要的是让命令自己处理。
#
# 还有一处更隐蔽的: 切回 `any` 时删规则是**按端口号 41641 匹配**的。自定义端口下那条删不掉,
# 于是"已恢复对全网放行"说完, 机器上还留着一条没人知道的 UDP 放行。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }

# pdg.sh 的函数闭包。顶层常量整体注入(沙箱没给才用生产默认) —— 见 test-adblock-sources.sh
# 里那段说明: 只抽函数会漏掉顶层赋值, 而 pdg.sh 跑在 set -u 下, 漏一个就在某条分支上炸。
CLOSURE="$WORK/closure.sh"; : > "$CLOSURE"
extract(){
  local ln; ln="$(grep -n "^$1()" "$ROOT/deploy/bot/pdg.sh" | head -1 | cut -d: -f1)" || return 1
  [[ -n "$ln" ]] || return 1
  sed -n "${ln},/^}/p" "$ROOT/deploy/bot/pdg.sh"
}
for fn in _fw_tailnet_direct _ssh_source_rewrite _ssh_ts_port _ssh_ts_accept; do
  extract "$fn" >> "$CLOSURE" 2>/dev/null || true      # 后两个是本支要新增的, 现在抽不到
  echo >> "$CLOSURE"
done
# `=(` 开头的是**多行数组**赋值(_PLAT_IOS_REQUIRED), 逐行改写会把它切碎, 整个闭包从那里
# 语法错、后面的定义全部丢失 —— 而表现是"函数没定义、输出全空", 看不出根因在这里。跳过它们。
grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT/deploy/bot/pdg.sh" \
  | grep -vE '^[A-Z_][A-Z0-9_]*=\(' \
  | sed -E 's/^([A-Z_][A-Z0-9_]*)=(.*)$/\1="${\1:-}"; [[ -z "${\1}" ]] \&\& \1=\2/' >> "$CLOSURE"
# 闭包必须**能整份解析**。上面那类切碎一旦再发生, 这里立刻判死 —— 否则后面每一格都在
# 空输出上打转, 而空输出恰好能骗过"不含 41641"之类的否定断言。
bash -n "$CLOSURE" || { bad "闭包语法坏了 —— 后面所有断言都不作数"; echo "通过 $pass, 失败 $nfail"; exit 1; }

# tailscaled 配置的假根。TAILSCALED_DEFAULTS 指到这里, 生产代码必须读它而不是写死。
mkdefaults(){ mkdir -p "$WORK/etc/default"; printf '%s\n' "$1" > "$WORK/etc/default/tailscaled"; }

run(){    # $1=要跑的 body; 在闭包里跑, 假根经环境变量传入
  ( set +e
    TAILSCALED_DEFAULTS="$WORK/etc/default/tailscaled"; export TAILSCALED_DEFAULTS
    PDG_REPO_ROOT="$ROOT"; export PDG_REPO_ROOT
    REPO_DIR="$ROOT"; export REPO_DIR
    # shellcheck source=/dev/null
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$1" )
}

echo "══ 1. 默认端口(没有 PORT= 赋值)仍是 41641 ══"
mkdefaults '# 空配置'
out="$(run '_fw_tailnet_direct x')"
{ [[ -n "$out" ]] && [[ "$out" == *'udp dport 41641 accept'* ]]; } \
  && ok "没配 PORT 时沿用官方默认 41641(实得: $out)" || bad "默认端口不对: ${out:-<空>}"

echo
echo "══ 2. 自定义端口必须被跟上 ══"
mkdefaults 'PORT="51820"'
out="$(run '_fw_tailnet_direct x')"
[[ "$out" == *'udp dport 51820 accept'* ]] \
  && ok "PORT=51820 时放行 51820" || bad "没跟上自定义端口, 实得: $out"
# 空输出也"不含 41641" —— 所以必须先要求它确实生成了一条放行, 否则这条是空断言。
{ [[ "$out" == *'udp dport'* ]] && [[ "$out" != *41641* ]]; } \
  && ok "不再同时留着 41641 那条陈旧放行" || bad "还带着 41641 或压根没出规则: ${out:-<空>}"

echo
echo "══ 3. PORT= 后面的赋值覆盖前面的(EnvironmentFile 语义)══"
mkdefaults 'PORT=1111
# 注释里的 PORT=2222 不算
PORT=3333'
out="$(run '_fw_tailnet_direct x')"
[[ "$out" == *'udp dport 3333 accept'* ]] \
  && ok "取最后一条赋值(3333), 不是第一条" || bad "覆盖语义不对, 实得: $out"

echo
echo "══ 4. 取不到合法端口时退回默认, 不能生成坏规则 ══"
for bad_val in 'PORT=abc' 'PORT=99999' 'PORT='; do
  mkdefaults "$bad_val"
  out="$(run '_fw_tailnet_direct x')"
  [[ "$out" == *'udp dport 41641 accept'* ]] \
    && ok "[$bad_val] 退回 41641" || bad "[$bad_val] 生成了坏规则: $out"
done

echo
echo "══ 5. 未收紧为 tailnet 时不放行任何端口 ══"
mkdefaults 'PORT=51820'
out="$(run '_fw_tailnet_direct ""')"
[[ "$out" != *'udp dport'* && "$out" == *'#'* ]] \
  && ok "空匹配 → 渲染成注释, 不放行" || bad "不该放行却放行了: $out"

echo
echo "══ 6. 切回 any 时, 自定义端口那条也必须被删掉 ══"
mkdefaults 'PORT=51820'
cat > "$WORK/nft.in" <<'NFT'
table inet pdg {
  chain input {
    iifname "tailscale0" tcp dport { 22 } accept
    udp dport 51820 accept comment "pdg-tailnet-direct"
  }
}
NFT
run '_ssh_source_rewrite any "'"$WORK"'/nft.in" "'"$WORK"'/nft.out"' >/dev/null 2>&1
if [[ -f "$WORK/nft.out" ]]; then
  grep -q 'pdg-tailnet-direct' "$WORK/nft.out" \
    && bad "切回 any 后仍残留一条无人知晓的 UDP 放行: $(grep 'pdg-tailnet-direct' "$WORK/nft.out")" \
    || ok "切回 any 时按 comment 删除, 自定义端口那条也清掉了"
  grep -qE '^[[:space:]]*tcp dport \{ 22 \} accept$' "$WORK/nft.out" \
    && ok "SSH 放行同时恢复成对全网" || bad "SSH 那行没恢复"
else
  bad "_ssh_source_rewrite 没产出文件(函数抽不到?)"
fi

echo
echo "══ 7. 端口解析只有一份实现(不许 shell 里再造一个)══"
# checks.py 的 _tailscaled_port 是唯一真源: EnvironmentFile 的覆盖语义、引号、范围校验
# 都在那儿写好了。shell 里再写一遍正则, 两份迟早对不上 —— 而对不上的表现是防火墙放行了
# 一个没人监听的端口, 不会有任何报错。
if grep -qE '_tailscaled_port|checks\.py' <<<"$(sed -n "/^_ssh_ts_port()/,/^}/p" "$ROOT/deploy/bot/pdg.sh")"; then
  ok "_ssh_ts_port 复用 checks.py 的解析器"
else
  bad "_ssh_ts_port 没有复用 checks.py 的解析器(或函数不存在)"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))

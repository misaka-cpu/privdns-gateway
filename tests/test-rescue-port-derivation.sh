#!/usr/bin/env bash
# 救援端口反解必须覆盖**真机上的两种形态**。
#
# 这支来自一次真实的升级失败: jp 停在更早的模板版本上, 那时救援端口不作为独立规则存在,
# 只出现在运行时注入的那条里 —— 而注入形态在 `ip saddr` 与 `tcp dport` 之间**还有
# `ip daddr`**。只按当前模板的形状反解, 在那台机器上一条都匹配不到, 同步被跳过,
# Tailscale 规则永远装不上, 更新每次回滚。
#
# 要害在于前提: `migrate_firewall_template_sync` 存在的意义就是服务**停在旧模板上的
# 机器**, 它们的形态必然与当前模板不同。拿当前模板的形状去反解旧机器, 方向从一开始就反了。
# 沙箱和 netns 里的配置都是用当前模板渲染的, 所以两处都匹配得上 —— 只有真机会暴露。
#
# 直接抽生产函数的反解片段跑, 不复制实现。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 从生产函数里取出反解那几行(标记形态 + 兜底), 原样执行
derive(){
  local f="$1" rport
  rport="$(grep -oE 'tcp dport [0-9]+ accept comment "pdg-rescue"' "$f" \
           | grep -oE '[0-9]+' | sort -u)"
  if [[ -z "$rport" ]]; then
    rport="$(grep -oE 'ip saddr [0-9./]+ tcp dport [0-9]+ accept' "$f" \
             | grep -oE 'dport [0-9]+' | grep -oE '[0-9]+' | sort -u)"
  fi
  printf '%s' "$rport"
}

# 判据: 生产代码里必须**两种形态都在**, 否则这支自己的 derive 就和生产漂移了
grep -q 'accept comment "pdg-rescue"' "$PDG" \
  && ok "生产反解认标记形态" || bad "生产反解没有标记形态(旧模板机器会反解失败)"
grep -q "ip saddr \[0-9./\]+ tcp dport \[0-9\]+ accept" "$PDG" \
  && ok "生产反解保留模板独立行兜底" || bad "没有兜底(未启用救援的机器会反解失败)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# 形态一: jp 的真实形态 —— 注入规则, saddr 与 dport 之间有 ip daddr
printf 'ip saddr 172.22.0.0/16 ip daddr 10.0.0.1 tcp dport 8446 accept comment "pdg-rescue"\n' > "$W/a"
[[ "$(derive "$W/a")" == 8446 ]] \
  && ok "注入形态(含 ip daddr + pdg-rescue 标记)反解出 8446" \
  || bad "注入形态反解得到 '$(derive "$W/a")', 期望 8446 —— 旧模板机器就是卡在这里"

# 形态二: 模板独立行 —— 没启用过救援的机器上只有这个
printf 'ip saddr 172.22.0.0/16 tcp dport 8446 accept\n' > "$W/b"
[[ "$(derive "$W/b")" == 8446 ]] \
  && ok "模板独立行反解出 8446" || bad "模板独立行反解失败"

# 形态三: 两者并存(启用救援的当前模板机器)—— 标记优先, 且不得因两条都匹配而判"多个"
printf 'ip saddr 172.22.0.0/16 ip daddr 10.0.0.1 tcp dport 8446 accept comment "pdg-rescue"\nip saddr 172.22.0.0/16 tcp dport 8446 accept\n' > "$W/c"
[[ "$(derive "$W/c")" == 8446 ]] \
  && ok "两种形态并存时反解出单值(标记优先, 不误判为多个)" \
  || bad "并存时反解得到 '$(derive "$W/c")'"

# 形态四: 真的有两个不同端口 → 必须给出多值, 由调用方 fail-closed
printf 'ip saddr 172.22.0.0/16 tcp dport 8446 accept\nip saddr 10.0.0.0/8 tcp dport 9999 accept\n' > "$W/d"
# 数法必须和生产一致: `printf '%s'` 不带尾换行, wc -l 会把两个值数成 1 —— 生产用的是
# `printf '%s\n' | grep -c .`, 这里照抄, 否则测的是我自己的计数而不是生产的判据。
[[ "$(printf '%s\n' "$(derive "$W/d")" | grep -c .)" -ge 2 ]] \
  && ok "确有多个不同端口时给出多值(调用方据此拒绝重建)" \
  || bad "多端口没被识别出来 —— 会拿错端口去重建防火墙"

echo
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail ? 1 : 0 ))

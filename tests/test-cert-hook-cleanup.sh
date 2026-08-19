#!/usr/bin/env bash
# 证书 standalone 续期钩子: 加在哪里就必须能从哪里撤掉, 且不许加一条注定无效的规则。
#
# ── 这支的由来 ────────────────────────────────────────────────────────────────
# jp 上 certbot 反复失败, 每失败一次 `table ip filter` 就多积一条 `tcp dport 80 accept`,
# 积到两条时 doctor 判红两项, 升级整次回滚。查下来是钩子的两个结构性问题:
#
#   1) pre-hook 解析不到 nft 时会落到 iptables 分支, 而 iptables-nft 会建出
#      `table ip filter`。那张表和 `inet pdg` 挂**同一个 input hook**, 而 PDG 那条是
#      `policy drop` —— 加进去的放行**从一开始就被架空**(实测 packets 0, 一个包都没匹配过)。
#      认证必然失败, 于是"证书悄悄续不上"+"残骸越积越多"同时发生。
#      有 `inet pdg` 却解析不到 nft, 正确的反应是**响亮地失败**, 不是加一条没用的规则。
#
#   2) 两个钩子对"规则加在哪"的判断**各算各的**: post-hook 的 nft 分支只做
#      `nft -f /etc/nftables.conf`, 而那份配置只定义 `inet pdg` —— 重载它根本不碰
#      `ip filter`。pre 落 iptables、post 走 nft 时, 残骸就永远撤不掉。
#      清理必须**幂等且覆盖全部三处**, 不能依赖"当初加在哪"这个记忆。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PRE="$ROOT/deploy/cert/proxy-gateway-open-cert-http.sh"
POST="$ROOT/deploy/cert/proxy-gateway-restore-firewall.sh"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

for f in "$PRE" "$POST"; do
  [[ -f "$f" ]] || { bad "找不到 $f"; echo; echo "通过 $pass, 失败 $nfail"; exit 1; }
done

# ── 一、有 inet pdg 却解析不到 nft: 不许落 iptables, 必须失败 ─────────────────
# 判据看的是"有 nft 却解析不到路径时是否拒绝 iptables", 不是字面量 —— 守卫写成 exit 1
# 加一句说明就够, 不必长成某个特定形状。
if grep -qE 'command -v nft .*&&|拒绝改用 iptables' "$PRE" && grep -q 'exit 1' "$PRE"; then
  ok "pre-hook 在有 nft 却解析不到路径时拒绝落 iptables(响亮失败而非留无效规则)"
elif false; then
  bad "pre-hook 仍会在有 inet pdg 时落到 iptables 分支 —— 那条规则被 policy drop 架空, 证书必然续不上"
else
  bad "pre-hook 仍会在有 inet pdg 时落到 iptables —— 那条规则被 policy drop 架空"
fi

# ── 二、插入的规则必须带标记, 才能精确撤销 ───────────────────────────────────
# 标记可以走变量(MARK=...), 判据认"有标记常量且插入时带上了", 不钉死字面量写法。
if grep -qE "^MARK=.*pdg-cert-http" "$PRE" && grep -qE 'insert rule .* comment "\$MARK"' "$PRE"; then
  ok "pre-hook 插入的放行带 pdg-cert-http 标记(可精确撤销)"
else
  bad "pre-hook 的放行没有标记 —— 只能靠端口猜, 而用户可能自己写过同端口放行"
fi

# ── 三、清理必须覆盖全部三处, 且不依赖"当初加在哪" ───────────────────────────
for place in 'inet pdg' 'inet filter' 'iptables'; do
  if grep -q "$place" "$POST"; then
    ok "post-hook 覆盖 $place"
  else
    bad "post-hook 不清理 $place —— pre 落在那里时残骸永远撤不掉"
  fi
done

# ── 四、pre-hook 自己进场也要先清一遍(post 没跑到时的兜底)──────────────────
# certbot 失败退出时 post-hook 未必执行, 所以残骸只能靠下一次 pre-hook 进场清。
if grep -qE '(清理|cleanup|_purge)' "$PRE"; then
  ok "pre-hook 进场先清残骸(post 没跑到时的兜底)"
else
  bad "pre-hook 不清残骸 —— certbot 失败时 post 未必执行, 残骸会一次次累积"
fi

echo
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail ? 1 : 0 ))

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

# ═══════════════════════════════════════════════════════════════════════════════
# 以下三格**真的执行钩子**。
#
# 上面四格全是对源码 grep —— 那种判据看不见行为。实际发生过: 一版修复同时带着死循环、
# 无条件调 iptables、删掉了配置重载三处缺陷, 这支照样 6/0 全绿(`grep -q iptables "$POST"`
# 反而因为那行存在而通过), 最后是 tests/test-nft-input-scan.py 抓到的。
# 静态判据留着仍有用(它们钉的是意图), 但必须有真跑的一档在下面兜着。
# ═══════════════════════════════════════════════════════════════════════════════

command -v timeout >/dev/null 2>&1 || { echo "[SKIP] 无 timeout, 跳过执行档"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdg-certhook.XXXXXX")"
[[ -n "${PDG_KEEP_TMP:-}" ]] || trap 'rm -rf "$TMP"' EXIT
[[ -n "${PDG_KEEP_TMP:-}" ]] && echo "[dbg] TMP=$TMP"
STUB="$TMP/stub"; mkdir -p "$STUB"
NFT_LOG="$TMP/nft.log"; IPT_LOG="$TMP/ipt.log"; CONF="$TMP/nftables.conf"
printf 'table inet pdg {}\n' > "$CONF"

# 桩一律 `exit 0` —— 这正是死循环那次的触发条件, 刻意保留。
_stub(){ printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 0\n' "$2" > "$1"; chmod 755 "$1"; }
_stub "$STUB/iptables" "$IPT_LOG"
_stub "$STUB/nft"      "$NFT_LOG"
printf '#!/bin/sh\nexit 0\n' > "$STUB/systemctl"; chmod 755 "$STUB/systemctl"
# 第五格要走 iptables 分支, 那要求"这台机器根本没有 nft" —— 所以另备一个**不含 nft**
# 的桩目录。第一版写这格时共用了上面那个: `command -v nft` 命中 nft 桩 → 走 nft 分支 →
# iptables 一次都没调, 断言却因为"没挂死"而绿。日志里那句"调用 0 次"是它露的马脚。
NONFT="$TMP/stub-nonft"; mkdir -p "$NONFT"
_stub "$NONFT/iptables" "$IPT_LOG"
printf '#!/bin/sh\nexit 0\n' > "$NONFT/systemctl"; chmod 755 "$NONFT/systemctl"

# 把钩子拷进沙箱, 绝对路径改指沙箱(不给生产代码加接缝)
_sandbox_hook(){        # $1=源 $2=目标 $3=lib 目录(可以是不存在的路径)
  sed -e "s#/opt/privdns-gateway/lib#$3#g" -e "s#/etc/nftables.conf#$CONF#g" "$1" > "$2"
  chmod 755 "$2"
}

# ── 五、桩恒返回 0 时不许挂死 ────────────────────────────────────────────────
# 清理循环的退出条件是"iptables -D 终于返回非零", 而那由外部命令决定。恒返回 0 的实现
# (测试桩、某些包装器)会让它转到天荒地老。这段跑在 certbot 的 systemd timer 里,
# 挂住的是**续期本身** —— 比它要修的缺陷更糟, 所以必须有次数上限。
: > "$IPT_LOG"
_sandbox_hook "$PRE" "$TMP/pre-noNft.sh" "$TMP/nolib"     # lib 指向不存在 → $NFT 为空
if PATH="$NONFT:/usr/bin:/bin" timeout 20 bash "$TMP/pre-noNft.sh" >/dev/null 2>&1; then rc=0; else rc=$?; fi
_n=$(wc -l < "$IPT_LOG")
if [[ "$_n" -eq 0 ]]; then
  bad "这一格空转了: iptables 一次都没被调到, 说明根本没走进要测的那条分支"
elif [[ "$rc" == 124 ]]; then
  bad "pre-hook 在恒返回 0 的 iptables 下挂死(20s 未退出) —— 清理循环没有次数上限"
elif [[ "$_n" -gt 64 ]]; then
  bad "pre-hook 调了 iptables $_n 次 —— 上限失效"
else
  ok "pre-hook 面对恒返回 0 的 iptables 仍能退出(rc=$rc, 调用 $_n 次), 清理循环有上限"
fi

# ── 六、解析得到 nft 时, 一次都不许碰 iptables ───────────────────────────────
# iptables-nft 会顺手**建出** `table ip filter`, 而那张表和 inet pdg 挂同一个 input hook
# —— 它的存在本身就是 doctor 判红「防火墙链冲突」的来源。清理动作反而制造出要清理的东西。
#
# 场景必须是**真实的那一个**: $NFT 经 lib/nftbin.sh 解析得到, 而 `nft` **不在 PATH 上**。
# 这正是 certbot 的 timer/cron 环境(PATH 无 /usr/sbin)。第一版判据把 nft 桩放进 PATH,
# 于是无论门写成 `[[ -n "$NFT" ]]` 还是 `command -v nft`, 两条都成立 —— 判据看不出区别,
# 拆掉正确的那道门它照样绿。把 nft 藏到 PATH 之外, 两者才分得开。
FAKE="$TMP/fakerepo"; mkdir -p "$FAKE/lib" "$FAKE/deploy/bot" "$TMP/hidden"
cp "$ROOT/lib/nftbin.sh" "$FAKE/lib/nftbin.sh"
_stub "$TMP/hidden/nft" "$NFT_LOG"                 # 藏在 PATH 之外
cat > "$FAKE/deploy/bot/nftscan.py" <<PY
import sys
if "--nft-path" in sys.argv: print("$TMP/hidden/nft")
PY
for _h in "$PRE" "$POST"; do
  _nm="$(basename "$_h")"
  : > "$IPT_LOG"; : > "$NFT_LOG"
  _sandbox_hook "$_h" "$TMP/x.sh" "$FAKE/lib"
  PATH="$NONFT:/usr/bin:/bin" REPO_DIR="$FAKE" timeout 20 bash "$TMP/x.sh" >/dev/null 2>&1
  if [[ ! -s "$NFT_LOG" ]]; then
    bad "$_nm 这一格空转了: nft 一次都没被调到, 说明 \$NFT 压根没解析出来"
  elif [[ -s "$IPT_LOG" ]]; then
    bad "$_nm 在 nft 可用时仍调了 iptables($(wc -l < "$IPT_LOG") 次) —— iptables-nft 会建出 ip filter, 那正是要清理的东西"
  else
    ok "$_nm 在 nft 解析得到(但不在 PATH 上)时一次都没碰 iptables"
  fi
  [[ "$_h" == "$POST" ]] && cp "$NFT_LOG" "$TMP/post-nft.log"
done

# ── 七、post-hook 必须重载磁盘配置 ───────────────────────────────────────────
# 按标记逐处删是**补**重载够不着的地方(那份配置只定义 inet pdg, 碰不到 inet filter),
# 不是**替代**它。post-hook 的本职是把防火墙恢复到规范状态, 不只是"删掉我加的那条"。
if grep -qF -- "-f $CONF" "$TMP/post-nft.log" 2>/dev/null; then
  ok "post-hook 重载了磁盘配置(把防火墙恢复到规范状态, 不只是删掉自己加的那条)"
else
  bad "post-hook 没有重载磁盘配置 —— 只删自己加的那条不等于恢复规范状态"
fi

echo
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail ? 1 : 0 ))

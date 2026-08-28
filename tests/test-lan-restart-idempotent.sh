#!/usr/bin/env bash
# 产物没变就别重启 pdg-lan。
#
# 现状: `_lan_apply_proxy` 无条件 `systemctl restart pdg-lan`。而 LAN 的三个派生产物
# (caddy.conf / nftables-pdg-lan.conf / pdg-lan.service)在产物层**已经是逐字节幂等**的 ——
# 也就是说每一次 `pdg update`、每一次面板同步、每一次回滚收敛, 都会为了一份一个字节都没变的
# 配置去重启一次反代。
#
# 代价不是"多花两秒": 重启期间反代是断的, 手机上正开着的面板会掉一次; 而这类重启没有任何
# 事情能从中获益 —— 配置一样, 结果也一样。本项目在别处已经守着同一条规矩(去广告那边是
# "产物真变才重启", 恢复那边是"动作从**这次内容确实变了的**目标推出来")。这里是唯一的例外。
#
# 但**不能简单地不重启就完事**: 出站白名单是靠 unit 的 `ExecStartPre` 进内核的, 跳过重启
# 就跳过了那一步。所以跳过重启的那条路上必须仍然保证内核里那张表在位 —— 走已有的
# `_lan_nft_reapply`(它自己就是幂等的, 且只在反代确实在跑时动手)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }

PDG="$ROOT/deploy/bot/pdg.sh"

mkclosure(){   # 抽函数 + 打桩, 记录 systemctl 被怎么调的
  local c="$WORK/c.sh"
  {
    echo 'set -uo pipefail'
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "CY:$*"; }'
    echo 'CALLS="'"$WORK"'/calls.log"'
    # systemctl 桩: is-active 按 $LAN_ACTIVE 回答, 其余一律记账
    cat <<'STUB'
systemctl(){
  printf '%s\n' "$*" >> "$CALLS"
  case "$1" in
    is-active) [[ "${LAN_ACTIVE:-1}" == 1 ]] && return 0 || return 1;;
    *) return 0;;
  esac
}
nft(){ printf 'nft %s\n' "$*" >> "$CALLS"; return 0; }
STUB
    sed -n '/^_lan_artifacts_digest()/,/^}/p' "$PDG"
    sed -n '/^_lan_nft_reapply()/,/^}/p' "$PDG"
    sed -n '/^_lan_apply_proxy()/,/^}/p' "$PDG"
  } > "$c"
  bash -n "$c" || { bad "闭包语法坏了 —— 后面所有断言都不作数"; echo "通过 $pass, 失败 $nfail"; exit 1; }
  printf '%s' "$c"
}

seed(){   # 造出三个派生产物
  mkdir -p "$WORK/etc/pdg-lan" "$WORK/etc/systemd/system"
  printf 'caddy conf v1\n'  > "$WORK/etc/pdg-lan/caddy.conf"
  printf 'table inet pdglan {}\n' > "$WORK/etc/nftables-pdg-lan.conf"
  printf '[Service]\nExecStart=/x\n' > "$WORK/etc/systemd/system/pdg-lan.service"
}

run(){    # $1=body
  ( set +e
    LAN_CADDYFILE="$WORK/etc/pdg-lan/caddy.conf"
    LAN_NFT_CONF="$WORK/etc/nftables-pdg-lan.conf"
    LAN_UNIT="$WORK/etc/systemd/system/pdg-lan.service"
    LAN_ACTIVE="${LAN_ACTIVE:-1}"
    export LAN_CADDYFILE LAN_NFT_CONF LAN_UNIT LAN_ACTIVE
    # shellcheck source=/dev/null
    source "$C"
    eval "$1" )
}
# `grep -c` 无匹配时**既打印 0 又返回非零**, 写成 `grep -c … || echo 0` 会得到 "0\n0" ——
# 于是 `[[ "$(restarts)" == 0 ]]` 恒假, 每一格都红得莫名其妙。(这一版就先踩了一次。)
restarts(){ grep -c '^restart pdg-lan' "$WORK/calls.log" 2>/dev/null; true; }
nftloads(){ grep -c '^nft -f' "$WORK/calls.log" 2>/dev/null; true; }

C="$(mkclosure)"
seed

echo "══ 1. 产物没变 → 不重启 ══"
: > "$WORK/calls.log"
D="$(run '_lan_artifacts_digest')"
[[ -n "$D" ]] && ok "算得出产物指纹(实得 ${D:0:12}…)" || bad "指纹是空的 —— 后面几格不作数"
: > "$WORK/calls.log"
run "_lan_apply_proxy '$D'" >/dev/null
[[ "$(restarts)" == 0 ]] && ok "指纹相同时一次都没重启" || bad "还是重启了 $(restarts) 次"

echo
echo "══ 2. 跳过重启时, 内核白名单仍要补回去 ══"
# 白名单是靠 unit 的 ExecStartPre 进内核的。跳过重启 = 跳过那一步, 所以这条路上必须
# 自己把那张表加载回去 —— 否则"少一次重启"换来的是一个能连内网任意地址的窗口。
[[ "$(nftloads)" -ge 1 ]] && ok "跳过重启时调了 nft -f 补白名单" || bad "既没重启也没补白名单 —— 那是个安全窗口"

echo
echo "══ 3. 产物变了 → 照常重启 ══"
: > "$WORK/calls.log"
printf 'caddy conf v2\n' > "$WORK/etc/pdg-lan/caddy.conf"
run "_lan_apply_proxy '$D'" >/dev/null
[[ "$(restarts)" == 1 ]] && ok "指纹变了就重启(恰好一次)" || bad "该重启却重启了 $(restarts) 次"

echo
echo "══ 4. 不传指纹 → 保持原行为(无条件重启)══"
# 老调用点不传参数。它们的语义是"我不知道变没变", 那时**必须**重启 —— 默认值只能偏保守。
: > "$WORK/calls.log"
run '_lan_apply_proxy' >/dev/null
[[ "$(restarts)" == 1 ]] && ok "不传指纹时仍然重启" || bad "不传指纹时没重启 —— 老调用点会静默失效"

echo
echo "══ 5. 反代没在跑 → 什么都不做 ══"
: > "$WORK/calls.log"
LAN_ACTIVE=0 run '_lan_apply_proxy' >/dev/null
[[ "$(restarts)" == 0 ]] && ok "反代没在跑时不重启" || bad "反代没跑却重启了"
[[ "$(nftloads)" == 0 ]] && ok "反代没在跑时也不加载白名单(那张表本来就不该存在)" || bad "反代没跑却加载了白名单"

echo
echo "══ 6. 指纹必须覆盖全部三个派生产物 ══"
# 少算一个, 那个产物变了就不会重启 —— 而"配置变了进程没跟上"正是本项目反复出事的形态。
for f in "$WORK/etc/pdg-lan/caddy.conf" "$WORK/etc/nftables-pdg-lan.conf" "$WORK/etc/systemd/system/pdg-lan.service"; do
  before="$(run '_lan_artifacts_digest')"
  printf 'mutated %s\n' "$RANDOM" >> "$f"
  after="$(run '_lan_artifacts_digest')"
  [[ "$before" != "$after" ]] && ok "指纹跟着 $(basename "$f") 变" || bad "改了 $(basename "$f") 指纹却没变"
done

echo
echo "══ 7. 缺文件不能等于「没变」══"
# 产物被删掉时指纹若与"内容为空"或与上一次相同, 就会跳过重启 —— 而那时反代其实该被拉起来。
before="$(run '_lan_artifacts_digest')"
rm -f "$WORK/etc/pdg-lan/caddy.conf"
after="$(run '_lan_artifacts_digest')"
[[ "$before" != "$after" ]] && ok "产物被删之后指纹也变了" || bad "删掉产物指纹没变 —— 会被当成「没变」而跳过重启"

echo
echo "══ 8. 指纹算不出来时必须落到「重启」那一边 ══"
# 文件在但读不到时 sha256sum 只吐空串。若照单收下, 两份**内容不同**的产物会得到同一个
# 指纹 —— "没变"成立、重启被跳过, 而磁盘上其实已经换了一份。算不出来 = 不知道, 而不知道
# 只能落到重启那边。
printf 'caddy conf v3\n' > "$WORK/etc/pdg-lan/caddy.conf"
D8="$(run '_lan_artifacts_digest')"
[[ -n "$D8" ]] && ok "正常情况下算得出指纹" || bad "基线指纹就是空的, 这一格不作数"
chmod 000 "$WORK/etc/pdg-lan/caddy.conf"
if [[ -r "$WORK/etc/pdg-lan/caddy.conf" ]]; then
  ok "(跳过: 这个环境下 chmod 000 仍可读 —— 多半是 root, 无法构造不可读)"
  ok "(同上)"
else
  D8b="$(run '_lan_artifacts_digest')"
  [[ -z "$D8b" ]] && ok "读不到产物时指纹为空(= 不知道)" || bad "读不到却给出了指纹: $D8b"
  : > "$WORK/calls.log"
  run "_lan_apply_proxy '$D8'" >/dev/null
  [[ "$(restarts)" == 1 ]] && ok "指纹算不出来时照常重启" || bad "指纹算不出来却跳过了重启"
fi
chmod 644 "$WORK/etc/pdg-lan/caddy.conf"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))

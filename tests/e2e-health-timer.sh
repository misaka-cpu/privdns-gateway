#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 健康自检定时器必须**永远排得出下一次**。
#
# 真机上出过一次: jp2 的 pdg-health.timer 从 2026-07-28 起再也没跑过, 而所有信号都说
# 正常 —— is-enabled=enabled、is-active=active、is-failed 不 failed、Result=success。
# 只有 `SubState=elapsed` 与 `NextElapseUSecMonotonic=infinity` 露了馅。8 天无人知晓。
#
# 机制: 原来的 [Timer] 是纯单调的
#     OnBootSec=2min          ← 开机很久之后才启动 timer, 这个点早就过去了
#     OnUnitActiveSec=10min   ← 相对**被触发服务**上次活动; 服务没跑过就没有参照点
#     Persistent=true         ← 只对 OnCalendar 生效, 这里是空头承诺
# 两条都算不出 ⇒ NextElapse=infinity ⇒ 永久停在 elapsed。
#
# 判据落在**真 systemd** 上, 不 grep unit 文本 —— 文本对不对不重要, 排不排得出下一次
# 才重要。非 root / 无 systemd 时 [SKIP], 严格模式下判失败(CI 必须真跑)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
ok(){ echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
skipf(){                       # 环境不具备: 平时 SKIP, CI(严格模式)判失败
  if [[ "${PDG_TEST_STRICT:-}" == 1 ]]; then bad "$1 —— 严格模式下不接受丢覆盖"
  else echo "[SKIP] $1 —— 未验收, 不是通过"; SKIP=$((SKIP+1)); fi
}
fin(){ echo "────────────────────────────────────────"
       echo "通过 $PASS, 失败 $FAIL, 跳过 $SKIP"; [[ "$FAIL" == 0 ]]; }

[[ "$(id -u)" == 0 ]] || { skipf "需要 root(真 systemd 操作)"; fin; exit $?; }
systemctl is-system-running >/dev/null 2>&1 || [[ -d /run/systemd/system ]] \
  || { skipf "没有可用的 systemd"; fin; exit $?; }

SRC="$ROOT/deploy/bot/pdg-health.timer"
[[ -f "$SRC" ]] || { bad "找不到 $SRC"; fin; exit $?; }

HITS=/var/log/pdg-health-e2e.hits
UNIT=/etc/systemd/system/pdg-health.timer
SVC=/etc/systemd/system/pdg-health.service
SAVED=""
[[ -f "$UNIT" ]] && { SAVED="$(mktemp)"; cp -a "$UNIT" "$SAVED"; }
SAVED_SVC=""
[[ -f "$SVC" ]] && { SAVED_SVC="$(mktemp)"; cp -a "$SVC" "$SAVED_SVC"; }
WAS_ACTIVE="$(systemctl is-active pdg-health.timer 2>/dev/null)"

cleanup(){
  systemctl stop pdg-health.timer >/dev/null 2>&1
  systemctl reset-failed pdg-health.timer pdg-health.service >/dev/null 2>&1
  if [[ -n "$SAVED" ]]; then cp -a "$SAVED" "$UNIT"; rm -f "$SAVED"; else rm -f "$UNIT"; fi
  if [[ -n "$SAVED_SVC" ]]; then cp -a "$SAVED_SVC" "$SVC"; rm -f "$SAVED_SVC"; else rm -f "$SVC"; fi
  rm -f "$HITS"
  systemctl daemon-reload >/dev/null 2>&1
  [[ "$WAS_ACTIVE" == active ]] && systemctl start pdg-health.timer >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# 替身 service: 只记一次时间戳。**不改产品的 service 内容** —— 这支测的是调度, 不是自检本身。
mk_svc(){ cat > "$SVC" <<EOF
[Unit]
Description=健康自检(E2E 替身: 只记时间戳)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'date -u +%s >> $HITS'
EOF
}

nxt(){ systemctl show pdg-health.timer -p NextElapseUSecMonotonic --value 2>/dev/null; }
nxr(){ systemctl show pdg-health.timer -p NextElapseUSecRealtime  --value 2>/dev/null; }
sub(){ systemctl show pdg-health.timer -p SubState --value 2>/dev/null; }
finite(){  # 有限的下一次 = monotonic 或 realtime 至少一个既非空也非 infinity
  local m r; m="$(nxt)"; r="$(nxr)"
  [[ -n "$m" && "$m" != infinity ]] && return 0
  [[ -n "$r" && "$r" != infinity && "$r" != "n/a" ]] && return 0
  return 1
}

echo
echo "── 1. timer 被重启一次之后, 仍必须排得出下一次 ──"
# 真机上那个现场的确定性配方(容器里对照实验找出来的): **arm → stop → start**。
#   · 第一次 start: timer 武装起来, Persistent 还会让它立刻补跑一次;
#   · stop 之后再 start: OnBootSec 那个点此刻已在过去, 而 OnUnitActiveSec 不足以
#     重新武装 ⇒ NextElapse=infinity, 永久停在 elapsed。
# 注意**不要求 service 从未跑过** —— 对照实验里 service 已经跑过一次照样死。真机 jp2
# 正是如此: 服务 7/28 跑过, timer 7/29 被重启, 从此再没动过。
# 这也是为什么判据不能等价成"检查 unit 文本": 同一份文本, 冷启是好的、重启一次就死。
mk_svc; : > "$HITS"
install -m644 "$SRC" "$UNIT"
systemctl daemon-reload
systemctl stop pdg-health.timer >/dev/null 2>&1
systemctl reset-failed pdg-health.timer pdg-health.service >/dev/null 2>&1
rm -f /var/lib/systemd/timers/stamp-pdg-health.timer
systemctl daemon-reload
systemctl start pdg-health.timer >/dev/null 2>&1; sleep 2      # arm
ok "前提: timer 已武装过一次(SubState=$(sub))"
systemctl stop pdg-health.timer >/dev/null 2>&1; sleep 1
systemctl start pdg-health.timer >/dev/null 2>&1                # 重启 —— 死角就在这里
sleep 2
echo "  实测: SubState=$(sub) NextMono=[$(nxt)] NextRealtime=[$(nxr)]"
finite && ok "此时仍排得出下一次触发(核心判据)" \
       || bad "NextElapse 为空/infinity —— timer 永久死在 $(sub), 服务再也不会跑"
[[ "$(sub)" != elapsed ]] && ok "SubState 不是 elapsed(实得 $(sub))" \
                          || bad "SubState=elapsed —— 已进入死角"
systemctl list-timers --all pdg-health.timer --no-pager 2>/dev/null | sed -n 2p | grep -qv '^-' \
  && ok "list-timers 里有 NEXT" || bad "list-timers 的 NEXT 是空的"

echo
echo "── 2. 反复重启不许掉进 infinity ──"
allfin=1
for i in 1 2 3; do
  systemctl restart pdg-health.timer >/dev/null 2>&1
  sleep 3
  finite || { allfin=0; echo "    第 $i 次重启后: SubState=$(sub) NextMono=[$(nxt)]"; }
done
[[ "$allfin" == 1 ]] && ok "连续 3 次重启, 每次都排得出下一次" \
                     || bad "重启后掉进了 infinity"
[[ "$(systemctl is-failed pdg-health.timer)" != failed ]] \
  && ok "重启不会把 timer 打成 failed" || bad "timer 变成 failed(failed 同样是 infinity)"

echo
echo "── 3. 换 unit 之后新调度必须真的生效 ──"
# 装一份"旧式"的坏 unit(带 OnBootSec、无 OnActiveSec), 起起来, 再用产品的 unit 覆盖,
# 看调度有没有跟着换 —— 只 install 不重启的话, 跑着的 timer 仍按旧调度走。
cat > "$UNIT" <<'OLDU'
[Unit]
Description=旧式坏 unit(E2E)
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
OLDU
systemctl daemon-reload; systemctl restart pdg-health.timer >/dev/null 2>&1; sleep 2
OLD_FRAG_SHA="$(sha256sum "$UNIT" | cut -d' ' -f1)"
install -m644 "$SRC" "$UNIT"; systemctl daemon-reload
NEW_FRAG_SHA="$(sha256sum "$UNIT" | cut -d' ' -f1)"
if [[ "$OLD_FRAG_SHA" == "$NEW_FRAG_SHA" ]]; then
  bad "产品 unit 与旧式坏 unit 内容相同 —— 修复没落地"
else
  ok "盘上 unit 已更新(与旧式不同)"
  # 只 daemon-reload 不重启: systemd 不会把已 active 的 timer 重新按新调度排
  systemctl restart pdg-health.timer >/dev/null 2>&1; sleep 2
  finite && ok "重启后按新 unit 排出了下一次" || bad "换 unit 并重启后仍排不出下一次"
fi

echo
echo "── 4. 真的触发一次, 之后重新排下一次 ──"
: > "$HITS"
systemctl stop pdg-health.timer >/dev/null 2>&1
systemctl reset-failed pdg-health.timer pdg-health.service >/dev/null 2>&1
FIRST="$(sed -n 's/^OnActiveSec=\([0-9]*\)\(min\|s\)$/\1 \2/p' "$UNIT" | head -1)"
WAIT=0
if [[ -n "$FIRST" ]]; then
  fn="${FIRST% *}"; fu="${FIRST#* }"
  if [[ "$fu" == "min" ]]; then WAIT=$(( fn * 60 )); else WAIT="$fn"; fi
fi
if (( WAIT == 0 )); then
  skipf "unit 里没有 OnActiveSec, 无法在有界时间内观察首次触发"
elif (( WAIT > 300 )); then
  skipf "首次触发窗口 ${WAIT}s 过长, 本支不等"
else
  systemctl start pdg-health.timer >/dev/null 2>&1
  # 窗口要覆盖 systemd 的默认 AccuracySec=1min —— 它会把触发点最多推迟一分钟。
  # 第一版只等了 WAIT+20 秒, 于是在**修好的** unit 上也报"没触发", 那是测量窗口的错。
  WIN=$((WAIT + 100))
  echo "  (等 ${WIN} 秒观察首次触发: OnActiveSec=${WAIT}s + 默认 AccuracySec=1min 的余量)"
  sleep "$WIN"
  n="$(wc -l < "$HITS")"
  (( n >= 1 )) && ok "首次触发发生了(实得 $n 次)" || bad "等满 ${WIN} 秒仍未触发"
  finite && ok "触发之后重新排出了下一次" || bad "触发之后排不出下一次"
  # 不许重复触发: 首次之后不该在同一个窗口里连着跑
  (( n <= 2 )) && ok "没有重复触发(窗口内 $n 次, 阈值 2)" \
               || bad "窗口内触发 $n 次 —— 疑似交错双触发"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5-7 节: 部署状态机。判据落在**真跑 migrate_health_timer** 上, 用真 systemd 观察它
# 到底做了什么 —— 不是看它打印了什么。
# ═════════════════════════════════════════════════════════════════════════════
load_fn(){                     # 把真 CLI 的函数装进当前 shell(未知子命令 → 打用法后正常结束)
  # shellcheck disable=SC1090
  source "$ROOT/deploy/bot/pdg.sh" __e2e_noop >/dev/null 2>&1
  REPO_DIR="$ROOT"
  type migrate_health_timer >/dev/null 2>&1
}
inv(){ systemctl show pdg-health.timer -p InvocationID --value 2>/dev/null; }

echo
echo "── 5. 内容没变且一切正常 → 零写盘/零重启 ──"
mk_svc; install -m644 "$SRC" "$UNIT"; systemctl daemon-reload
systemctl enable pdg-health.timer >/dev/null 2>&1
systemctl restart pdg-health.timer >/dev/null 2>&1; sleep 2
if load_fn; then
  ok "真函数已载入(migrate_health_timer)"
  MT0="$(stat -c%Y "$UNIT")"; INV0="$(inv)"
  migrate_health_timer; rc=$?
  [[ "$rc" == 0 ]] && ok "返回 0" || bad "返回 $rc"
  [[ "$(stat -c%Y "$UNIT")" == "$MT0" ]] && ok "unit 没被重写(mtime 不变)" || bad "无谓重写了 unit"
  [[ "$(inv)" == "$INV0" ]] && ok "timer 没被重启(InvocationID 不变)" || bad "内容没变却重启了"
else
  bad "载入不了 migrate_health_timer —— 后面几节无从谈起"
fi

echo
echo "── 6. 内容没变但已 disabled/inactive → 必须修回来 ──"
systemctl stop pdg-health.timer >/dev/null 2>&1
systemctl disable pdg-health.timer >/dev/null 2>&1
migrate_health_timer >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "返回 0" || bad "返回 $rc"
[[ "$(systemctl is-enabled pdg-health.timer 2>/dev/null)" == enabled ]] \
  && ok "已修回 enabled" || bad "仍是 $(systemctl is-enabled pdg-health.timer 2>/dev/null)"
[[ "$(systemctl is-active pdg-health.timer 2>/dev/null)" == active ]] \
  && ok "已修回 active" || bad "仍是 $(systemctl is-active pdg-health.timer 2>/dev/null)"
finite && ok "并且排得出下一次" || bad "修回来了却排不出下一次"

echo
echo "── 7. 内容相同但 timer 已死 → 不许因为「内容没变」就放过 ──"
# 任务书原本要求的是"内容相同且已 elapsed 时能重新 arm"。真做下来发现**那个组合用修好的
# unit 不可达** —— OnActiveSec 让它任何时候都排得出下一次, 想死也死不了。内容相同还能死,
# 只可能是盘上那份内容本身就是坏的那一版(真机 jp2 就是这样: 仓库与盘上都是旧 unit)。
# 于是这一格验的是那个真正可达的契约: **重启后仍排不出下一次, 必须如实报失败**, 而不是
# 因为"内容没变"就返回 0 说一切正常 —— 后者正是这次 8 天无人知晓的成因。
#
# 死角要靠"被触发的服务从未被激活过"才构造得稳: 服务一旦跑过, OnUnitActiveSec 就有了
# 参照点。所以这里指向一个全新的、从没起过的服务名。
cat > /etc/systemd/system/pdg-health-virgin.service <<'VIRG'
[Unit]
Description=E2E: 从未被激活过的服务(用于构造死角)
[Service]
Type=oneshot
ExecStart=/bin/true
VIRG
cat > "$UNIT" <<'OLDU2'
[Unit]
Description=旧式坏 unit(E2E: 死角构造)
[Timer]
OnUnitActiveSec=10min
Unit=pdg-health-virgin.service
[Install]
WantedBy=timers.target
OLDU2
systemctl stop pdg-health.timer >/dev/null 2>&1
systemctl reset-failed pdg-health.timer >/dev/null 2>&1
rm -f /var/lib/systemd/timers/stamp-pdg-health.timer
systemctl daemon-reload
systemctl start pdg-health.timer >/dev/null 2>&1; sleep 2
if finite; then
  bad "前提不成立: 没能把 timer 推进死角(实得 SubState=$(sub))"
else
  ok "前提: timer 已死在 $(sub) + NextElapse=infinity"
  BADSRC="$(mktemp)"; cp -a "$UNIT" "$BADSRC"
  SAME="$(mktemp -d)"; mkdir -p "$SAME/deploy/bot"
  cp "$BADSRC" "$SAME/deploy/bot/pdg-health.timer"          # 仓库与盘上逐字节相同
  ( export REPO_DIR="$SAME"; migrate_health_timer >/dev/null 2>&1; echo $? > /tmp/e2e-ht-rc ) || true
  rc="$(cat /tmp/e2e-ht-rc 2>/dev/null || echo 9)"
  [[ "$rc" != 0 ]] && ok "内容相同但重新 arm 不成 → 返回非零($rc), 如实报失败" \
                   || bad "返回 0 —— 又把静默停摆当成正常放过去了"
  rm -f "$BADSRC" /tmp/e2e-ht-rc; rm -rf "$SAME"
  rm -f /etc/systemd/system/pdg-health-virgin.service; systemctl daemon-reload
fi

echo "── 8. 内容变化 → 装新的并重新 arm ──"
install -m644 "$SRC" "$UNIT"   # 先回到产品版, 再造一次"旧→新"
cat > "$UNIT" <<'OLDU3'
[Unit]
Description=旧式坏 unit(E2E)
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
Persistent=true
[Install]
WantedBy=timers.target
OLDU3
systemctl daemon-reload; systemctl restart pdg-health.timer >/dev/null 2>&1; sleep 2
migrate_health_timer >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] && ok "返回 0" || bad "返回 $rc"
cmp -s "$SRC" "$UNIT" && ok "盘上 unit 已换成产品版(逐字节相同)" || bad "unit 没换"
[[ "$(systemctl is-active pdg-health.timer)" == active ]] && ok "timer active" || bad "timer 不是 active"
finite && ok "新调度已 arm(有有限的下一次)" || bad "换了 unit 却没重新排程"

echo
echo "── 9. 故障注入: 每一步失败都要非零 + 回到原状 ──"
# root 下 chmod 000 挡不住 install(第一版就是这么假绿的), 改用**函数遮蔽**精准打到某一步。
install -m644 "$SRC" "$UNIT"; systemctl daemon-reload
systemctl enable --now pdg-health.timer >/dev/null 2>&1; sleep 1
BEFORE_SHA="$(sha256sum "$UNIT" | awk '{print $1}')"
BEFORE_EN="$(systemctl is-enabled pdg-health.timer 2>/dev/null)"
BEFORE_AC="$(systemctl is-active  pdg-health.timer 2>/dev/null)"
CHREPO="$(mktemp -d)"; mkdir -p "$CHREPO/deploy/bot"
sed 's/OnActiveSec=2min/OnActiveSec=3min/' "$SRC" > "$CHREPO/deploy/bot/pdg-health.timer"   # 制造内容变化

inject(){            # $1=场景名  $2=遮蔽定义
  local name="$1" shadow="$2" rc
  ( export REPO_DIR="$CHREPO"
    eval "$shadow"
    migrate_health_timer >/dev/null 2>&1; echo $? > /tmp/e2e-ht-rc ) || true
  rc="$(cat /tmp/e2e-ht-rc 2>/dev/null || echo 9)"
  [[ "$rc" != 0 ]] && ok "$name → 返回非零($rc)" || bad "$name 却返回 0"
  [[ "$(sha256sum "$UNIT" | awk '{print $1}')" == "$BEFORE_SHA" ]] \
    && ok "$name → unit 逐字节回到原样" || bad "$name → unit 没还原"
  [[ "$(systemctl is-enabled pdg-health.timer 2>/dev/null)" == "$BEFORE_EN" \
     && "$(systemctl is-active pdg-health.timer 2>/dev/null)" == "$BEFORE_AC" ]] \
    && ok "$name → enabled/active 状态还原" || bad "$name → 状态没还原"
  # 每一格之后回到基线, 免得上一格的残留影响下一格
  install -m644 "$SRC" "$UNIT"; systemctl daemon-reload
  systemctl enable --now pdg-health.timer >/dev/null 2>&1
  systemctl restart pdg-health.timer >/dev/null 2>&1; sleep 1
}

# 9a 候选不合法(真实场景: 仓库里那份文件被截断/写坏)
BADREPO="$(mktemp -d)"; mkdir -p "$BADREPO/deploy/bot"
printf '[Unit]\nDescription=坏候选\n' > "$BADREPO/deploy/bot/pdg-health.timer"
( export REPO_DIR="$BADREPO"; migrate_health_timer >/dev/null 2>&1; echo $? > /tmp/e2e-ht-rc ) || true
rc="$(cat /tmp/e2e-ht-rc 2>/dev/null || echo 9)"
[[ "$rc" != 0 ]] && ok "候选不合法 → 返回非零($rc)" || bad "候选不合法却返回 0"
[[ "$(sha256sum "$UNIT" | awk '{print $1}')" == "$BEFORE_SHA" ]] \
  && ok "坏候选没有落盘" || bad "坏候选被装上去了"

inject "install 失败"      'install(){ return 1; }'
inject "daemon-reload 失败" 'systemctl(){ [[ "$1" == daemon-reload ]] && return 1; command systemctl "$@"; }'
inject "enable 失败"        'systemctl(){ [[ "$1" == enable ]] && return 1; command systemctl "$@"; }'
inject "restart 失败"       'systemctl(){ [[ "$1" == restart ]] && return 1; command systemctl "$@"; }'
inject "restart 成功但仍无 NextElapse" '_pdg_timer_next_ok(){ return 1; }'

rm -rf "$BADREPO" "$CHREPO" /tmp/e2e-ht-rc

echo
echo "── 10. unit 形态门: 两种被实测否定的写法不许出现 ──"
# 这两条是形态判据而不是行为判据, 因为它们的危害要么无可观测(惰性指令), 要么只在长时间
# 窗口里才显形 —— 而两者都有实测依据, 不是凭感觉定的规矩。
BODY="$(grep -vE '^[[:space:]]*#' "$SRC")"       # 剥掉注释, 免得解释性文字被当成配置
if grep -q '^Persistent=' <<<"$BODY" && ! grep -q '^OnCalendar=' <<<"$BODY"; then
  bad "unit 里有 Persistent= 却没有 OnCalendar= —— 它只对 OnCalendar 生效, 留着是句空头承诺(这次就是它误导了排查)"
else
  ok "没有惰性的 Persistent=(要么不写, 要么配 OnCalendar 一起写)"
fi
if grep -q '^OnCalendar=' <<<"$BODY" && grep -q '^OnUnitActiveSec=' <<<"$BODY"; then
  bad "OnCalendar= 与 OnUnitActiveSec= 并存 —— 容器实测 systemd 取最早的那个, 墙钟槽与单调间隔交错, 间隔从 20/30 秒变成 20,10,21,9,21,9, 频率接近翻倍"
else
  ok "OnCalendar 与 OnUnitActiveSec 没有并存(实测叠加会交错双触发)"
fi

fin

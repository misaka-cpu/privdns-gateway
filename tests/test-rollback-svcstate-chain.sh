#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 走**真实 cmd_rollback** 的服务恢复接线。
#
# 为什么必须有这一支: 辅助函数自己"没有服务动作"证明不了整条回滚链没有先把服务启动过 ——
# 以前那句通用 `systemctl restart mosdns pdg-bot pdg-probe81` 就排在辅助函数**前面**。
# 所以判据要盯**整条链**: 最终返回码、最终那句报告、以及链上一共对服务做了什么。
#
# 沙箱化沿用 tests/test-update-rollback.sh 的做法: 覆写 _pdg_apply_snapshot_tree 落到沙箱
# (不碰真 /), 打桩 systemctl/nft/内核激活等**外部系统边界**。
# cmd_rollback 本体、_pdg_restore_svcstate、_pdg_svcstate_plan、_pdg_svcstate_valid、
# _pdg_svc_q 全部用产品原文, 一个都不打桩。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

# 这一支跑的是**真实** cmd_rollback, 而它里面有写死的生产路径(例如
# `printf 'mihomo\n' > /etc/privdns-gateway/backend`)。非 root 下那一句会被权限挡住,
# 对宿主机没有影响; 以 root 跑就会真的改宿主机。所以这里直接拒绝以 root 运行。
if [[ "$(id -u)" == 0 ]]; then
  echo "[SKIP] 拒绝以 root 运行: 真实 cmd_rollback 里有写死的生产路径, root 下会改到宿主机。"
  echo "       请用普通用户跑这一支(CI 的 lint job 本来就是普通用户)。"
  exit 0
fi

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
set_u(){ echo "$3" > "$1/$2.en"; echo "$4" > "$1/$2.ac"; echo running > "$1/$2.sub"; echo "INV-$2-orig" > "$1/$2.inv"; }

STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1"
  case "$act" in
    daemon-reload) return 0;;
    is-enabled) local v; v="$(cat "$SC_DIR/$u.en" 2>/dev/null)" || { echo not-found; return 1; }
                echo "$v"; case "$v" in enabled|enabled-runtime|static|indirect|generated|alias) return 0;; *) return 1;; esac;;
    is-active)  local a; a="$(cat "$SC_DIR/$u.ac" 2>/dev/null)" || { echo inactive; return 3; }
                echo "$a"; [[ "$a" == active ]] && return 0 || return 3;;
    show) case "$3" in
            LoadState)    [[ -e "$SC_DIR/$u.en" ]] && echo loaded || echo not-found;;
            SubState)     cat "$SC_DIR/$u.sub" 2>/dev/null || echo dead;;
            InvocationID) cat "$SC_DIR/$u.inv" 2>/dev/null || echo "";;
            *) echo "";;
          esac; return 0;;
    reset-failed) return 0;;
  esac
  [[ -e "$SC_DIR/$u.fail_$act" ]] && return 1
  case "$act" in
    enable)  [[ "$2" == --runtime ]] && echo enabled-runtime > "$SC_DIR/$u.en" || echo enabled > "$SC_DIR/$u.en";;
    disable) echo disabled > "$SC_DIR/$u.en";;
    start|restart) echo active > "$SC_DIR/$u.ac"; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv";;
    stop)    echo inactive > "$SC_DIR/$u.ac"; : > "$SC_DIR/$u.inv";;
  esac
  return 0
}'

# 造一份快照(含 snap.tar.gz), 并按 $2 决定要不要写前像
mksnap(){  # $1=场景目录 $2=with-preimage|no-preimage
  local d="$1" mode="$2"
  mkdir -p "$d/snap" "$d/sc" "$d/applied"
  local u; for u in $U_ALL; do set_u "$d/sc" "$u" enabled active; done
  case "$mode" in
    A) set_u "$d/sc" pdg-mitm enabled active; set_u "$d/sc" pdg-bot disabled inactive
       set_u "$d/sc" mosdns enabled-runtime active;;
  esac
  # 真的打一份 tar.gz —— cmd_rollback 会解包并读成员清单, 假文件走不到那一步
  mkdir -p "$d/tree/etc/privdns-gateway"
  printf 'mihomo\n' > "$d/tree/etc/privdns-gateway/backend"
  printf '%s\n' "$(basename "$d")" > "$d/tree/etc/privdns-gateway/snapid"
  tar czf "$d/snap/snap.tar.gz" -C "$d/tree" etc 2>/dev/null
  chmod 600 "$d/snap/snap.tar.gz"
  if [[ "$mode" != no-preimage ]]; then
    { echo 'set -uo pipefail'
      echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/save.log\"; : > \"\$SC_LOG\""
      echo "$STUB"
      _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
      _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
      _fnN "$PDG" _pdg_save_svcstate
      echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
    } > "$d/save.sh"
    bash "$d/save.sh"
  fi
}

# 跑**真实** cmd_rollback
run_chain(){  # $1=场景目录
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/chain.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    echo 'need_root(){ :; }; _lock(){ :; }'
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    echo "SNAP_DIR=\"$d\"; REPO_DIR=\"$d/norepo\""
    echo '_pdg_core(){ echo mihomo; }; _pdg_core_svc(){ echo mihomo; }'
    echo '_pdg_mktemp_dir(){ mktemp -d; }'
    echo '_sb_panel_managed_on(){ return 1; }'
    echo '_core_kernel_activate(){ return 0; }'
    echo 'pdg_write_unit(){ return 0; }; pdg_unit_mihomo(){ echo "[Unit]"; }'
    echo '_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }'
    echo 'nft(){ return 0; }'
    echo '_pdg_ios_verify_tree(){ return 0; }'
    echo '_lan_rollback_converge(){ return 0; }'
    echo '_nft_apply_main(){ return 0; }'
    echo '_snap_meta_commit(){ echo ""; }'
    # 覆写落盘: 不碰真 /, 只记"确实落过盘"
    echo "_pdg_apply_snapshot_tree(){ echo applied > \"$d/applied/ok\"; return 0; }"
    # 产品原文的前像那一组
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_save_svcstate; _fnN "$PDG" _pdg_svcstate_valid
    grep -m1 '^declare -A _PDG_WANT_EN' "$PDG"
    grep -m1 '^_PDG_SVC_MODE=' "$PDG"; grep -m1 '^_PDG_SVC_WHY=' "$PDG"; grep -m1 '^_PDG_SVC_SRC=' "$PDG"
    _fnN "$PDG" _pdg_svcstate_plan; _fn1 "$PDG" _pdg_now_ac; _fn1 "$PDG" _pdg_now_en
    _fnN "$PDG" _pdg_restore_svcstate
    _fnN "$PDG" cmd_rollback
    echo "cmd_rollback --dir \"$d/snap\" --no-git"
    echo 'echo "CHAIN_RC=$?"'
    local u
    for u in $U_ALL; do
      echo "printf 'FINAL\t$u\t%s\t%s\n' \"\$(cat \"$d/sc/$u.en\" 2>/dev/null)\" \"\$(cat \"$d/sc/$u.ac\" 2>/dev/null)\""
    done
  } > "$d/chain.sh"
  bash "$d/chain.sh" 2>&1
}
plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
fin(){ grep -P "^FINAL\t$2\t" <<<"$1" | cut -f3,4 | tr '\t' '/'; }

echo "══ 一. 有前像的整条回滚链 ══"
d="$WORK/A"; mksnap "$d" A
# 回滚落盘之后的现场: 自启链接没了、服务也没起
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
o="$(run_chain "$d")"; p="$(plain "$o")"
[[ -f "$d/applied/ok" ]] && ok "A0: 快照确实落过盘(整条链跑到了应用那一步)" || { bad "A0: 链没跑起来"; echo "$p" | sed 's/^/      /' | head -8; }
[[ "$(fin "$o" pdg-mitm)" == "enabled/active" ]] && ok "A1: 本来开着的回到 enabled/active" || bad "A1: 实得 $(fin "$o" pdg-mitm)"
[[ "$(fin "$o" pdg-bot)"  == "disabled/inactive" ]] && ok "A2: 本来停着的仍是 disabled/inactive" || bad "A2: 实得 $(fin "$o" pdg-bot)"
[[ "$(fin "$o" mosdns)"   == "enabled-runtime/active" ]] && ok "A3: enabled-runtime 没被提升" || bad "A3: 实得 $(fin "$o" mosdns)"
grep -qE '^(start|restart) ([^ ]+ )*pdg-bot( |$)' "$d/chain.log" \
  && bad "A4: **整条链**里 pdg-bot 被启动过 —— 通用重启那条老路还在" \
  || ok "A4: **整条链**里本来停着的 pdg-bot 一次都没被启动"
grep -q 'CHAIN_RC=0' <<<"$p" && ok "A5: 整条链返回 0" || bad "A5: $(grep -o 'CHAIN_RC=.*' <<<"$p")"
grep -q '✅ 已回滚并重启服务' <<<"$p" && ok "A6: 最终报告是「已回滚并重启服务」" || bad "A6: 报告不对"

echo
echo "══ 二. 没有前像(旧快照)的整条回滚链: 不许报完全回滚 ══"
d="$WORK/B"; mksnap "$d" no-preimage
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
o="$(run_chain "$d")"; p="$(plain "$o")"
grep -q 'CHAIN_RC=1' <<<"$p" && ok "B1: 整条链返回 1" || bad "B1: $(grep -o 'CHAIN_RC=.*' <<<"$p")"
grep -q '✅ 已回滚并重启服务' <<<"$p" && bad "B2: 仍然报了「已回滚并重启服务」" || ok "B2: **没有**报「已回滚并重启服务」"
grep -q '未能恢复(未完全回滚)' <<<"$p" && ok "B3: 报的是「未完全回滚」并列出了未恢复项" || bad "B3: 报告不对"
grep -q '服务前像缺失/不可用' <<<"$p" && ok "B4: 未恢复项里点名了服务前像这一格" || bad "B4"
grep -q '运行态与自启状态无法确认' <<<"$p" && ok "B5: 并明说无法确认、要人工复核哪些 unit" || bad "B5"
grep -q '^restart mosdns pdg-bot pdg-probe81' "$d/chain.log" && ok "B6: 保留了原来那句明确列名的通用重启(安全检查不丢)" || bad "B6"
[[ -f "$d/applied/ok" ]] && ok "B7: 文件恢复照常做(没有因为缺前像就不回滚)" || bad "B7"

echo
echo "══ 三. 恢复不完整时, 整条链如实报出来 ══"
d="$WORK/C"; mksnap "$d" A
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
: > "$d/sc/pdg-mitm.fail_enable"      # 自启恢复动作失败
o="$(run_chain "$d")"; p="$(plain "$o")"
grep -q 'CHAIN_RC=1' <<<"$p" && ok "C1: 整条链返回 1" || bad "C1: $(grep -o 'CHAIN_RC=.*' <<<"$p")"
grep -q '未能恢复(未完全回滚)' <<<"$p" && ok "C2: 报「未完全回滚」" || bad "C2"
grep -q 'pdg-mitm 自启恢复动作失败' <<<"$p" && ok "C3: 未恢复项里点名了是哪个服务的哪一格" || { bad "C3"; echo "$p" | grep '未能恢复' | sed 's/^/      /'; }

echo
echo "══ 四. 撤销对照: 把「先定策略」换回「先通用重启再纠正」 ══"
# 最小反向补丁: 在 _pdg_restore_svcstate 的第一句之前插回那句通用重启。
REV="$WORK/pdg-rev.sh"
awk '/^_pdg_restore_svcstate\(\)\{/{
       print; print "  systemctl restart mosdns pdg-bot pdg-probe81 >/dev/null 2>&1 || true"; next }
     {print}' "$PDG" > "$REV"
if cmp -s "$PDG" "$REV"; then
  bad "D0: 没造出反向副本 —— 本格记无效"
elif ! bash -n "$REV" 2>/dev/null; then
  bad "D0: 反向副本语法不通 —— 本格记无效"
else
  ok "D0: 反向副本就位(只在恢复函数开头插回那句通用重启)"
  d="$WORK/D"; mksnap "$d" A
  for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
  PDG="$REV" run_chain "$d" > "$d/out.txt" 2>&1
  o="$(cat "$d/out.txt")"
  grep -qE '^restart mosdns pdg-bot pdg-probe81' "$d/chain.log" \
    && ok "D1: 反向副本里本来停着的 pdg-bot **确实**被通用重启拉起来过" || bad "D1: 反向对照没触到那条路 —— 本格记无效"
  # 最终状态仍会被纠正回去 —— 正是"先启后停"这条老路的形态: 中间真的跑过一段
  [[ "$(fin "$o" pdg-bot)" == "disabled/inactive" ]] \
    && ok "D2: 而且最终状态看上去一样 —— 所以只看最终状态的判据抓不住这件事" || bad "D2: 实得 $(fin "$o" pdg-bot)"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

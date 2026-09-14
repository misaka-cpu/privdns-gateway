#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台切换: **退役件已经撤除之后**才失败, 善后到底把东西还回来了没有。
#
# 为什么单独一支: cmd_platform 现在会存快照与服务前像, 但"存下来"不等于"失败时会用"。
# 原来的 _plat_rollback 只认四个 iOS 文件, 名单里**没有** pdg-mitm.service、mitm_server.py、
# mitm_wloc.py —— 而那三样正是 _plat_purge_retired / migrate_android_cleanup 删掉的。
# 于是"有快照、有前像、门放行"三件事凑在一起, 也不等于这个调用方具备可靠恢复能力。
#
# 跑的是**真实** cmd_platform → 真实清理 → 真实失败善后 → 真实 cmd_rollback, 不是单独调清理。
# 隔离: unshare 私有挂载, /etc /opt /usr/local/bin 绑到一次性目录; 宿主一动不动。
# 建不出隔离就报"未执行"并非 0 退出, 不靠权限失败兜底。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

if [[ "${PDG_PLAT_NS:-}" != 1 ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)"
  mkdir -p "$FAKE/etc/privdns-gateway" "$FAKE/etc/systemd/system" "$FAKE/etc/mosdns/rules" \
           "$FAKE/etc/mihomo" "$FAKE/opt/pdg-bot" "$FAKE/usr/local/bin"
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  export FAKE PDG_PLAT_NS=1
  if unshare --map-root-user --mount --propagation private true 2>/dev/null; then
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  elif command -v bwrap >/dev/null 2>&1; then
    exec bwrap --dev-bind / / --bind "$FAKE/etc" /etc --bind "$FAKE/opt" /opt \
               --bind "$FAKE/usr/local/bin" /usr/local/bin \
               -- env PDG_PLAT_NS=2 FAKE="$FAKE" bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  else
    echo "[未执行] 建不出挂载隔离(没有可用的 unshare/bwrap)。这一支会让真实 cmd_platform 往 /etc /opt 落盘,"
    echo "         没有自有根就不能跑 —— 不靠权限失败兜底, 也不冒充通过。"
    exit 1
  fi
fi
if [[ "${PDG_PLAT_NS:-}" == 1 ]]; then
  mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
  mount --bind "$FAKE/opt" /opt || { echo "[未执行] 绑定 /opt 失败"; exit 1; }
  mount --bind "$FAKE/usr/local/bin" /usr/local/bin || { echo "[未执行] 绑定 /usr/local/bin 失败"; exit 1; }
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="${PDG_UNDER_TEST:-$ROOT/deploy/bot/pdg.sh}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" "$FAKE"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }
echo probe > /etc/pdg-plat-isolation-probe
[[ -f "$FAKE/etc/pdg-plat-isolation-probe" ]] || { echo "[未执行] 隔离自检失败"; exit 1; }
rm -f /etc/pdg-plat-isolation-probe

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }
_arr(){ sed -n "/^$2=(/,/^)/p" "$1"; }

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
SC="$WORK/sc"; mkdir -p "$SC"
set_u(){ echo "$2" > "$SC/$1.en"; echo "$3" > "$SC/$1.ac"; echo running > "$SC/$1.sub"; echo "INV-$1-orig" > "$SC/$1.inv"; }

STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1" now
  case "$act" in
    daemon-reload|reset-failed) return 0;;
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
  esac
  case "$act" in
    enable)  if [[ "$2" == --runtime ]]; then now=enabled-runtime; else now=enabled; fi
             _chg "$u" en "$now"
             if [[ "${2:-}" == --now || "${3:-}" == --now ]]; then _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv"; fi;;
    disable) _chg "$u" en disabled; [[ "${2:-}" == --now ]] && _chg "$u" ac inactive;;
    start|restart) _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv";;
    stop)    _chg "$u" ac inactive;;
  esac
  return 0
}
_chg(){ local cur; cur="$(cat "$SC_DIR/$1.$2" 2>/dev/null)"
  [[ "$cur" == "$3" ]] && return 0
  echo "$3" > "$SC_DIR/$1.$2"; echo "$1 $2 $cur -> $3" >> "$SC_CHG"; }
nft(){ return 0; }'

# 造一台"还留着退役件"的老机器
seed_machine(){   # $1=当前平台
  rm -rf /etc/privdns-gateway /etc/systemd/system /etc/mosdns /etc/mihomo /opt/pdg-bot
  mkdir -p /etc/privdns-gateway /etc/systemd/system /etc/mosdns/rules /etc/mihomo /opt/pdg-bot
  printf '%s\n' "$1" > /etc/privdns-gateway/platform
  printf 'PROFILE-ORIG\n' > /etc/privdns-gateway/profile.env; chmod 640 /etc/privdns-gateway/profile.env
  printf '{"wloc": {"enabled": true, "lat": 1}}\n' > /etc/privdns-gateway/mitm.json
  printf 'wloc.example\n' > /etc/mosdns/rules/mitm_hijack.txt
  printf 'MIHOMO-ORIG\n' > /etc/mihomo/config.yaml
  printf '[Unit]\nDescription=pdg-mitm ORIG\n' > /etc/systemd/system/pdg-mitm.service; chmod 644 /etc/systemd/system/pdg-mitm.service
  local f
  for f in mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl bot.py; do
    printf 'ORIG-%s\n' "$f" > "/opt/pdg-bot/$f"; chmod 755 "/opt/pdg-bot/$f"
  done
  rm -f "$SC"/*
  for f in $U_ALL; do set_u "$f" enabled active; done
}
mkrepo(){   # 造一个够用的 REPO_DIR(给 _plat_deploy_ios 装 iOS 件)
  local r="$WORK/repo"; mkdir -p "$r/deploy/ios" "$r/deploy/bot"
  printf 'NEW-TMPL\n'      > "$r/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl"
  printf 'NEW-iosprofile\n'> "$r/deploy/bot/iosprofile.py"
  printf 'NEW-iosstate\n'  > "$r/deploy/bot/iosstate.py"
  printf 'NEW-mitm_ca\n'   > "$r/deploy/bot/mitm_ca.py"
  echo "$r"
}

# 真实 cmd_platform 的运行壳。只对外部系统边界与本轮不涉及的编排打桩。
run_platform(){   # $1=目标平台 $2=fail|nofail $3=场景目录 [$4=被测 pdg.sh]
  local tgt="$1" mode="$2" d="$3" src="${4:-$PDG}"
  mkdir -p "$d/snaps"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$SC\"; SC_LOG=\"$d/sc.log\"; SC_CHG=\"$d/sc.chg\"; : > \"\$SC_LOG\"; : > \"\$SC_CHG\""
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
    echo 'need_root(){ :; }; _lock(){ :; }'
    echo "SNAP_DIR=\"$d/snaps\"; REPO_DIR=\"$(mkrepo)\"; LOCK=\"$d/lock\""
    echo '_pdg_core(){ echo mihomo; }; _pdg_core_svc(){ echo mihomo; }; _pdg_mktemp_dir(){ mktemp -d; }'
    echo '_sb_panel_managed_on(){ return 1; }'
    echo 'pdg_write_unit(){ printf "[Unit]\n" > "$2"; return 0; }; pdg_unit_mihomo(){ echo "[Unit]"; }'
    echo '_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }'
    echo '_lan_rollback_converge(){ return 0; }; _nft_apply_main(){ return 0; }; _snap_meta_commit(){ echo ""; }'
    echo '_pdg_ios_verify_tree(){ return 0; }'
    echo '_plat_write_profile(){ printf "PROFILE-%s\n" "$1" > /etc/privdns-gateway/profile.env; return 0; }'
    echo 'migrate_probe81_public(){ return 0; }'
    echo '_pdg_nft_bin(){ echo /bin/true; }; _pdg_required_svcs(){ echo mosdns; }'
    echo 'migrate_ios_gms_cleanup(){ return 0; }; _plat_verify(){ return 0; }'
    echo '_pdg_bot_cred(){ echo ready; }; _core_kernel_stable(){ return 0; }'
    echo '_pdg_svc_stable(){ return 0; }; _pdg_nft_ok(){ return 0; }'
    echo 'doctor(){ return 0; }'
    # cmd_snapshot: 本轮不涉及它的实现, 但**材料必须是真的** —— 真打一份 tar。
    echo "cmd_snapshot(){ local s=\"$d/snaps/\$(date +%s%N)\"; mkdir -p \"\$s\""
    echo '  tar czf "$s/snap.tar.gz" -C / etc/privdns-gateway etc/systemd/system etc/mosdns etc/mihomo opt/pdg-bot 2>/dev/null'
    echo '  chmod 600 "$s/snap.tar.gz"; _PDG_SNAP_CREATED="$s"; return 0; }'
    # 失败注入点: 退役件已经撤除之后、切换宣布成功之前的第一处可失败步骤。
    if [[ "$mode" == fail ]]; then
      echo "_switchcore_nft(){ printf 'unit=%s server=%s wloc=%s\n' \\"
      echo "  \"\$( [[ -e /etc/systemd/system/pdg-mitm.service ]] && echo present || echo gone )\" \\"
      echo "  \"\$( [[ -e /opt/pdg-bot/mitm_server.py ]] && echo present || echo gone )\" \\"
      echo "  \"\$( [[ -e /opt/pdg-bot/mitm_wloc.py ]] && echo present || echo gone )\" > \"$d/stage-proof\"; return 1; }"
    else
      echo '_switchcore_nft(){ return 0; }'
    fi
    echo 'python3(){ return 0; }; mihomo(){ return 0; }; command(){ builtin command "$@"; }'
    # 产品原文: 本轮涉及的全部编排
    grep -m1 '^_PDG_IOS_STATE_REL=' "$src"; grep -m1 '^_PDG_IOS_ART_REL=' "$src"
    grep -m1 '^_PDG_RETIRE_OK=' "$src"; grep -m1 '^_PDG_RETIRE_DONE=' "$src"
    _arr "$src" _PLAT_RETIRED; _arr "$src" _PLAT_IOS_REQUIRED
    _fnN "$src" _pdg_apply_snapshot_tree; _fnN "$src" _pdg_ios_group_in_members
    _fnN "$src" _core_kernel_activate
    grep -q '^_pdg_kernel_converge(){' "$src" && _fnN "$src" _pdg_kernel_converge
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_save_svcstate; _fnN "$src" _pdg_svcstate_valid
    grep -m1 '^declare -A _PDG_WANT_EN' "$src"
    grep -m1 '^_PDG_SVC_MODE=' "$src"; grep -m1 '^_PDG_SVC_WHY=' "$src"; grep -m1 '^_PDG_SVC_SRC=' "$src"
    _fnN "$src" _pdg_svcstate_plan; _fn1 "$src" _pdg_now_ac; _fn1 "$src" _pdg_now_en
    _fnN "$src" _pdg_restore_svcstate; _fnN "$src" cmd_rollback
    _fnN "$src" _retire_caller_gate; _fnN "$src" _retire_allowed
    _fnN "$src" _retire_android_pending; _fnN "$src" _retire_plat_pending
    _fnN "$src" _pdg_lock_proof
    echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
    echo '_pdg_platform(){ cat /etc/privdns-gateway/platform 2>/dev/null; }'
    _fnN "$src" _plat_purge_retired; _fnN "$src" _plat_deploy_ios; _fnN "$src" migrate_android_cleanup
    _fnN "$src" cmd_platform
    echo "exec 9>\"$d/lock\"; flock -n 9"
    echo "cmd_platform $tgt"
    echo 'echo "PLAT_RC=$?"'
    local u
    for u in $U_ALL; do
      echo "printf 'FINAL\t$u\t%s\t%s\n' \"\$(cat \"$SC/$u.en\" 2>/dev/null)\" \"\$(cat \"$SC/$u.ac\" 2>/dev/null)\""
    done
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1
}
plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
fin(){ grep -P "^FINAL\t$2\t" <<<"$1" | cut -f3,4 | tr '\t' '/'; }

check_dir(){   # 四维核验, $1=输出 $2=场景目录 $3=方向名
  local o="$1" d="$2" n="$3"
  [[ -f "$d/stage-proof" ]] && grep -q 'unit=gone' "$d/stage-proof" \
    && ok "$n: 失败确实注入在**退役件已经撤除之后**($(cat "$d/stage-proof"))" \
    || bad "$n: 没命中那个阶段($(cat "$d/stage-proof" 2>/dev/null || echo 未生成))"
  # ① 文件: 内容 + 存在性 + 属性
  [[ "$(cat /etc/systemd/system/pdg-mitm.service 2>/dev/null | tail -1)" == "Description=pdg-mitm ORIG" ]] \
    && ok "$n: pdg-mitm.service 回来了且内容是原来的" || bad "$n: unit 没回来/内容不对"
  [[ "$(stat -c %a /etc/systemd/system/pdg-mitm.service 2>/dev/null)" == 644 ]] \
    && ok "$n: 且权限位也是原来的 644" || bad "$n: 权限位 $(stat -c %a /etc/systemd/system/pdg-mitm.service 2>/dev/null)"
  [[ "$(cat /opt/pdg-bot/mitm_server.py 2>/dev/null)" == ORIG-mitm_server.py ]] \
    && ok "$n: mitm_server.py 回来了" || bad "$n: mitm_server.py 没回来"
  [[ "$(cat /opt/pdg-bot/mitm_wloc.py 2>/dev/null)" == ORIG-mitm_wloc.py ]] \
    && ok "$n: mitm_wloc.py 回来了" || bad "$n: mitm_wloc.py 没回来"
  [[ "$(cat /etc/privdns-gateway/platform)" == "$4" ]] && ok "$n: 平台标记回到 $4" || bad "$n: 平台标记是 $(cat /etc/privdns-gateway/platform)"
  # ② 运行态 ③ 自启态
  [[ "$(fin "$o" pdg-mitm)" == "enabled/active" ]] && ok "$n: pdg-mitm 的自启与运行态都回到切换前" || bad "$n: 实得 $(fin "$o" pdg-mitm)"
  # ④ 已加载配置: 配置消费者的进程被换过(InvocationID 变了)
  [[ "$(cat "$SC/mosdns.inv")" != "INV-mosdns-orig" ]] && ok "$n: mosdns 的进程被换过(恢复出来的配置有被重新读)" || bad "$n: mosdns 仍是原进程"
  # ⑤ 报告与退出码
  grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && bad "$n: 切换失败却返回 0" || ok "$n: 返回非 0"
  grep -q '按本次快照恢复到切换前' <<<"$(plain "$o")" && ok "$n: 报告说明了走的是快照整体恢复" || bad "$n: 报告没说清"
}

echo "══ 一. iOS ← Android 方向: 退役件撤除之后失败 ══"
seed_machine android; d="$WORK/ios"; mkdir -p "$d"
o="$(run_platform ios fail "$d")"
check_dir "$o" "$d" "A" android

echo
echo "══ 二. Android ← iOS 方向: 退役件撤除之后失败 ══"
seed_machine ios; d="$WORK/android"; mkdir -p "$d"
o="$(run_platform android fail "$d")"
check_dir "$o" "$d" "B" ios

echo
echo "══ 三. 正常切换 / 干净机器 / 幂等 ══"
seed_machine android; d="$WORK/okios"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; p="$(plain "$o")"
grep -q 'PLAT_RC=0' <<<"$p" && ok "C1: 正常切换仍然成功" || { bad "C1: $(grep -o 'PLAT_RC=.*' <<<"$p")"; grep -vE '^FINAL' <<<"$p" | head -20 | sed 's/^/      /'; }
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "C2: 平台标记确实切到了 ios" || bad "C2"
d="$WORK/okios2"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && ok "C3: 同方向再切一次(幂等)仍然成功" || bad "C3"
# 干净机器: 没有任何退役件
rm -f /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
printf '{"wloc": {"enabled": false}}\n' > /etc/privdns-gateway/mitm.json
d="$WORK/clean"; mkdir -p "$d"
o="$(run_platform android nofail "$d")"; grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && ok "C4: 已经清干净的机器切换照常成功" || bad "C4"

echo
echo "══ 四. 撤销对照: 失败善后退回只用局部还原 ══"
REV="$WORK/pdg-rev-plat.sh"
awk '/^  _plat_fail_restore\(\)\{/{print "  _plat_fail_restore(){ _plat_rollback; return; }"; skip=1; next}
     skip && /^  \}$/{skip=0; next} !skip{print}' "$PDG" > "$REV"
if cmp -s "$PDG" "$REV" || ! bash -n "$REV" 2>/dev/null; then
  bad "D0: 没造出反向副本 —— 本格记无效"
else
  ok "D0: 反向副本就位(失败善后只走 _plat_rollback)"
  seed_machine android; d="$WORK/rev"; mkdir -p "$d"
  o="$(run_platform ios fail "$d" "$REV")"
  [[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "D1: 局部还原补不回 pdg-mitm.service —— 这正是原来的现场" || bad "D1: 反向对照没体现差异"
  [[ ! -e /opt/pdg-bot/mitm_server.py ]] && ok "D2: 也补不回 mitm_server.py" || bad "D2: 反向对照没体现差异"
fi

echo
echo "──────── 本支仍被替换的产品函数, 以及因此未覆盖的性质 ────────"
cat <<'NOTE'
  cmd_snapshot            → 未覆盖: 快照清单裁剪与元数据写入(材料本身是真打的 tar)
  _plat_write_profile     → 未覆盖: profile.env 的真实渲染内容
  migrate_probe81_public / migrate_ios_gms_cleanup / _plat_verify → 未覆盖: 这三步自身的判据
  _switchcore_nft         → 被用作失败注入点; 未覆盖: 防火墙按平台重建
  python3 / mihomo / nft  → 未覆盖: 内核配置渲染与校验、真实 nft
  need_root / _lock       → 未覆盖: 真实取锁
  _pdg_bot_cred / _core_kernel_stable / _pdg_svc_stable / _pdg_nft_ok / doctor
                          → 未覆盖: 切换后的稳定性与自检判据(由 test-platform-install.sh 覆盖)
  systemctl               → 未覆盖: 真实 systemd 的状态机与时序
  ⇒ 这一支证明的是**失败善后把不把东西还回来**, 不是真实 systemd 行为。
NOTE
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

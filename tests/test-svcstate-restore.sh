#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 服务前像的**恢复**这一格(函数级)。整条回滚链的接线由
# tests/test-rollback-svcstate-chain.sh 跑真实 cmd_rollback 验, 两支不互相替代。
#
# 要补的洞: 快照只收文件。enable 的符号链接在 multi-user.target.wants/ 下, 全仓从不快照,
# 所以"文件都回来了"≠"服务回到了原来的运行态与自启态"。
#
# 本轮重做的几条纪律, 每条都在下面有具名判据:
#   · **先定策略再动手** —— 不再"先一律 restart 三个服务再纠正"; 本来停着的服务一次都不会被启动;
#   · 动作返回码与后置状态是**两个独立**的失败条件;
#   · 停必须停稳(过渡态/查询失败都不算), failed 与 inactive 的差别如实登记;
#   · 想要 active 的用 restart 并要求 InvocationID 变过 —— 光是 active 证明不了恢复出来的
#     配置被读进去了(已经在跑的服务 start 是空转);
#   · enabled-runtime 不提升成永久 enabled; static/masked/未知不先改再说不支持;
#   · 记录必须属于**实际选中的那份快照**(snap_dir + snap_id), 光结构合法不算;
#   · 没有可用前像时保留原来那套通用重启与安全检查, 但如实登记、不冒充完整恢复。
#
# 产品函数一个都没打桩; 打桩的只有外部系统边界 systemctl。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }

# systemctl 桩: 记账 + 回答状态。每次 start/restart 换一个 InvocationID(真 systemd 就是这样),
# 所以"进程有没有真的被换掉"这条判据在这里是可观测的。
#   .fail_<动作>  → 动作返回 1 且不改状态
#   .lie_<动作>   → 动作返回 0 但不改状态(验"返回成功≠真的恢复了")
#   .stale_start  → restart 返回 0、状态变 active, 但 InvocationID **不变**
#                   (对应真实世界里"服务其实没被换掉, 旧配置还在跑"的那一格)
STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1"
  case "$act" in
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
  [[ -e "$SC_DIR/$u.lie_$act"  ]] && return 0
  case "$act" in
    enable)  [[ "$2" == --runtime ]] && echo enabled-runtime > "$SC_DIR/$u.en" || echo enabled > "$SC_DIR/$u.en";;
    disable) echo disabled > "$SC_DIR/$u.en";;
    start|restart)
             echo active > "$SC_DIR/$u.ac"
             [[ -e "$SC_DIR/$u.stale_start" ]] || echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv";;
    stop)    echo inactive > "$SC_DIR/$u.ac"; : > "$SC_DIR/$u.inv";;
  esac
  return 0
}'

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
set_u(){ echo "$3" > "$1/$2.en"; echo "$4" > "$1/$2.ac"; echo running > "$1/$2.sub"; echo "INV-$2-orig" > "$1/$2.inv"; }
seed(){ local d="$1" u; mkdir -p "$d"; for u in $U_ALL; do set_u "$d" "$u" enabled active; done; }

# 产品原文的那一组(含本轮新增的 plan/now_* 与全局表)
prodfns(){ local src="$PDG"
  _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
  _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
  _fnN "$src" _pdg_save_svcstate; _fnN "$src" _pdg_svcstate_valid
  grep -m1 '^declare -A _PDG_WANT_EN' "$src"
  grep -m1 '^_PDG_SVC_MODE=' "$src"; grep -m1 '^_PDG_SVC_WHY=' "$src"; grep -m1 '^_PDG_SVC_SRC=' "$src"
  _fnN "$src" _pdg_svcstate_plan; _fn1 "$src" _pdg_now_ac; _fn1 "$src" _pdg_now_en
  # 自启恢复现在由 _pdg_set_enable_state 一处负责(持久/运行时两层要分别撤) —— 抽真身, 不补替代实现。
  _fnN "$src" _pdg_set_enable_state
  _fnN "$src" _pdg_restore_svcstate
}

save_preimage(){ # $1=场景目录: 用产品原文的保存函数造一份合法前像
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/save.log\"; : > \"\$SC_LOG\""
    echo "$STUB"; prodfns
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  } > "$d/save.sh"
  bash "$d/save.sh"
}

run_restore(){ # $1=场景目录 [$2=naive-restart|naive-norecheck]
  local d="$1" mode="${2:-}"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/restore.log\"; : > \"\$SC_LOG\""
    echo "$STUB"; prodfns
    case "$mode" in
      naive-restart)
        echo 'naive(){ local u; for u in '"$U_ALL"'; do systemctl restart "$u" >/dev/null 2>&1; systemctl start "$u" >/dev/null 2>&1; done; }';;
      naive-norecheck)
        echo 'naive(){ local u ufs asv
          while IFS=$'"'"'\t'"'"' read -r _k u ufs _urc asv _arc _sub _inv; do
            [[ "$_k" == unit && -n "$u" ]] || continue
            case "$ufs" in enabled) systemctl enable "$u" >/dev/null 2>&1 || unrestored+=("$u enable 失败");; esac
            case "$asv" in active)  systemctl restart "$u" >/dev/null 2>&1 || unrestored+=("$u restart 失败");; esac
          done < "$1/svcstate.tsv"; }';;
    esac
    echo 'unrestored=()'
    case "$mode" in
      naive-restart)   echo "naive; rc=0";;
      naive-norecheck) echo "naive \"$d/snap\"; rc=0";;
      *)               echo "_pdg_restore_svcstate \"$d/snap\"; rc=\$?";;
    esac
    echo 'printf "RC=%s\n" "$rc"'
    echo 'for x in "${unrestored[@]+"${unrestored[@]}"}"; do printf "UNRESTORED\t%s\n" "$x"; done'
    local u
    for u in $U_ALL; do
      echo "printf 'FINAL\t$u\t%s\t%s\n' \"\$(cat \"$d/sc/$u.en\" 2>/dev/null)\" \"\$(cat \"$d/sc/$u.ac\" 2>/dev/null)\""
    done
  } > "$d/restore-${mode:-real}.sh"
  bash "$d/restore-${mode:-real}.sh" 2>&1
}

fin(){ grep -P "^FINAL\t$2\t" <<<"$1" | cut -f3,4 | tr '\t' '/'; }
unl(){ grep -P '^UNRESTORED\t' <<<"$1" | cut -f2-; }
nun(){ unl "$1" | grep -c . ; }
mk(){ local d="$BOX/$1"; mkdir -p "$d/snap" "$d/sc"; seed "$d/sc"; echo "$d"; }

echo "══ 一. 三态恢复, 且本来停着的服务**一次都没被启动过** ══"
d="$(mk A)"
set_u "$d/sc" pdg-mitm enabled         active
set_u "$d/sc" pdg-bot  disabled        inactive
set_u "$d/sc" mosdns   enabled-runtime active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done   # 回滚刚落盘: 自启链接没了, 服务也没起
o="$(run_restore "$d")"
[[ "$(fin "$o" pdg-mitm)" == "enabled/active" ]] && ok "A1: active+enabled 恢复回 enabled/active" || bad "A1: 实得 $(fin "$o" pdg-mitm)"
[[ "$(fin "$o" pdg-bot)"  == "disabled/inactive" ]] && ok "A2: inactive+disabled 恢复回 disabled/inactive" || bad "A2: 实得 $(fin "$o" pdg-bot)"
[[ "$(fin "$o" mosdns)"   == "enabled-runtime/active" ]] && ok "A3: enabled-runtime **没有**被提升成永久 enabled" || bad "A3: 实得 $(fin "$o" mosdns)"
grep -qE '^(start|restart) ([^ ]+ )*pdg-bot( |$)' "$d/restore.log" \
  && bad "A4: 本来停着的 pdg-bot 被启动过(先启后停那条老路)" \
  || ok "A4: 本来停着的 pdg-bot **一次都没被启动**(先定策略再动手)"
[[ "$(nun "$o")" == 0 ]] && ok "A5: 全部恢复成功 ⇒ 未恢复项为空" || { bad "A5: 冒出了未恢复项"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 二. 撤销对照(三态): 换回「一律 restart」, 同一场景恢复不回来且一声不吭 ══"
d="$(mk B)"
set_u "$d/sc" pdg-mitm enabled active; set_u "$d/sc" pdg-bot disabled inactive; set_u "$d/sc" mosdns enabled-runtime active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
o="$(run_restore "$d" naive-restart)"
[[ "$(fin "$o" pdg-mitm)" == "disabled/active" ]] && ok "B1: 天真实现下 pdg-mitm 仍不自启 —— A1 确实是被测代码的功劳" || bad "B1: 实得 $(fin "$o" pdg-mitm)"
[[ "$(fin "$o" pdg-bot)"  == "disabled/active" ]] && ok "B2: 天真实现把本该停着的 pdg-bot 拉起来了" || bad "B2: 实得 $(fin "$o" pdg-bot)"
[[ "$(fin "$o" mosdns)"   == "disabled/active" ]] && ok "B3: 天真实现下 enabled-runtime 丢失" || bad "B3: 实得 $(fin "$o" mosdns)"
[[ "$(nun "$o")" == 0 ]] && ok "B4: 而且它一声不吭(未恢复项为空)—— 那句「✅ 已回滚并重启服务」就是这么来的" || bad "B4"

echo
echo "══ 三. 动作返回成功、后置状态却不符 → 计入未恢复 ══"
d="$(mk C)"; set_u "$d/sc" pdg-mitm enabled active; save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
: > "$d/sc/pdg-mitm.lie_enable"
o="$(run_restore "$d")"
unl "$o" | grep -q 'pdg-mitm 自启后置状态不符(目标 enabled, 实得 disabled)' \
  && ok "C1: 动作返回成功但状态没变 → 如实登记" || { bad "C1: 没登记"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-mitm 自启恢复动作失败' && bad "C2: 动作明明返回 0, 却报成了动作失败" || ok "C2: 没有把'状态不符'混成'动作失败'"

echo
echo "══ 四. 撤销对照(失败报告): 只看返回码不复核 → 同一现场被漏报 ══"
d="$(mk D)"; set_u "$d/sc" pdg-mitm enabled active; save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
: > "$d/sc/pdg-mitm.lie_enable"
o="$(run_restore "$d" naive-norecheck)"
[[ "$(nun "$o")" == 0 ]] && ok "D1: 天真实现(只看 rc)对同一现场零登记 —— C1 确实来自「动作之后复核状态」" || { bad "D1"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 五. 恢复动作失败 → 与后置状态分开各记一条 ══"
d="$(mk E)"; set_u "$d/sc" pdg-mitm enabled active; set_u "$d/sc" mihomo enabled active; save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
: > "$d/sc/pdg-mitm.fail_enable"; : > "$d/sc/mihomo.fail_restart"
o="$(run_restore "$d")"
unl "$o" | grep -q 'pdg-mitm 自启恢复动作失败(目标 enabled, rc=1)' && ok "E1: enable 返回非 0 → 独立登记一条「动作失败」" || { bad "E1"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-mitm 自启后置状态不符' && ok "E2: 同时还登记了「后置状态不符」—— 两个条件各记各的" || bad "E2"
unl "$o" | grep -q 'mihomo 启动动作失败(restart rc=1)' && ok "E3: restart 返回非 0 → 独立登记" || { bad "E3"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-bot' && bad "E4: 牵连了其它已恢复的服务" || ok "E4: 没有牵连其它已恢复的服务"

echo
echo "══ 六. start + active 不证明旧配置被加载: 进程没换要报出来 ══"
d="$(mk F)"; set_u "$d/sc" mosdns enabled active; save_preimage "$d"
: > "$d/sc/mosdns.stale_start"          # restart 返回 0、状态 active, 但 InvocationID 不变
o="$(run_restore "$d")"
[[ "$(fin "$o" mosdns)" == "enabled/active" ]] && ok "F1: 表面上看 enabled/active, 一切正常" || bad "F1: 实得 $(fin "$o" mosdns)"
unl "$o" | grep -q 'mosdns 仍是回滚前那个进程, 恢复出来的配置没有被重新加载' \
  && ok "F2: 但 InvocationID 没变 → 如实报「配置没有被重新加载」" || { bad "F2"; unl "$o" | sed 's/^/      /'; }
grep -q '^restart mosdns' "$d/restore.log" && ok "F3: 用的是 restart 而不是 start(已经在跑的服务 start 是空转)" || bad "F3: $(grep -c . "$d/restore.log") 行日志里没有 restart mosdns"

echo
echo "══ 七. 停必须停稳; failed 与 inactive 的差别如实登记 ══"
d="$(mk G)"; set_u "$d/sc" pdg-bot inactive_placeholder active
set_u "$d/sc" pdg-bot disabled inactive; set_u "$d/sc" pdg-probe81 disabled failed
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done   # 回滚后两者都在跑
: > "$d/sc/pdg-bot.fail_stop"                                   # 停不下来
o="$(run_restore "$d")"
unl "$o" | grep -q 'pdg-bot 停止动作失败(stop rc=1)' && ok "G1: 停止动作失败 → 独立登记" || { bad "G1"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-bot 前像是 inactive, 但现在是 active —— 没有停稳' && ok "G2: 并且后置状态不符也单独登记" || bad "G2"
unl "$o" | grep -q 'pdg-probe81 前像是 failed(启动失败态), 现为 inactive —— 未复现该状态' \
  && ok "G3: failed 停成 inactive 如实登记为「未复现」, 不当成已恢复" || { bad "G3"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 八. 旧快照没有前像: 保留原来那套通用重启与安全检查, 但不冒充完整恢复 ══"
d="$(mk H)"; rm -f "$d/snap/svcstate.tsv"; printf 'x' > "$d/snap/snap.tar.gz"
o="$(run_restore "$d")"
grep -q 'RC=1' <<<"$o" && ok "H1: 返回非 0(调用方据此不得报「完全回滚」)" || bad "H1: 返回了 0"
unl "$o" | grep -q '服务前像缺失/不可用' && ok "H2: 登记为「未确认」而不是「已恢复」" || { bad "H2"; unl "$o" | sed 's/^/      /'; }
grep -q '^restart mosdns pdg-bot pdg-probe81' "$d/restore.log" && ok "H3: 保留了原来那句明确列名的通用重启(没有 pdg-* 通配)" || bad "H3"
grep -qE '^(enable|disable) ' "$d/restore.log" && bad "H4: 没有前像却动了自启(等于凭空推断历史)" || ok "H4: 没有前像时不碰任何 enable/disable"

echo
echo "══ 九. 记录必须属于**实际选中的那份快照** ══"
d="$(mk I)"; save_preimage "$d"
printf 'DIFFERENT-BYTES' > "$d/snap/snap.tar.gz"        # 换了快照 ⇒ snap_id 对不上
o="$(run_restore "$d")"
grep -q 'RC=1' <<<"$o" && unl "$o" | grep -q '快照身份与这一份对不上' \
  && ok "I1: 结构合法但钉的不是这一份快照 → 按不可用处理" || { bad "I1"; unl "$o" | sed 's/^/      /'; }
d="$(mk I2)"; save_preimage "$d"
sed -i "s|^snap_dir\t.*|snap_dir\t/var/lib/pdg/snapshots/other|" "$d/snap/svcstate.tsv"
python3 - "$d/snap/svcstate.tsv" <<'PY'
import hashlib, sys
p=sys.argv[1]; L=[l for l in open(p,encoding="utf-8").read().split("\n") if not l.startswith("end\t")]
while L and L[-1]=="": L.pop()
b="\n".join(L)+"\n"; n=sum(1 for l in L if l.startswith("unit\t"))
open(p,"w",encoding="utf-8").write(b+"end\t%d\t%s\n"%(n,hashlib.sha256(b.encode()).hexdigest()))
PY
chmod 600 "$d/snap/svcstate.tsv"
o="$(run_restore "$d")"
unl "$o" | grep -q '记的是别的快照' && ok "I2: 记录指向别的快照目录(且已重新封口)→ 同样按不可用处理" || { bad "I2"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 十. 记录时就没查到 / enable-disable 表达不了 / 过渡态 ══"
d="$(mk J)"
set_u "$d/sc" pdg-probe81 static   active
set_u "$d/sc" pdg-dotwitness masked inactive
save_preimage "$d"
python3 - "$d/snap/svcstate.tsv" <<'PY'
import hashlib, sys
p=sys.argv[1]; out=[]
for l in open(p,encoding="utf-8").read().split("\n"):
    if l.startswith("end\t"): continue
    f=l.split("\t")
    if f[0]=="unit" and f[1]=="mihomo": f[2]="QUERY-FAILED"; f[3]="3"; l="\t".join(f)
    if f[0]=="unit" and f[1]=="pdg-health.timer": f[4]="activating"; l="\t".join(f)
    out.append(l)
while out and out[-1]=="": out.pop()
b="\n".join(out)+"\n"; n=sum(1 for l in out if l.startswith("unit\t"))
open(p,"w",encoding="utf-8").write(b+"end\t%d\t%s\n"%(n,hashlib.sha256(b.encode()).hexdigest()))
PY
chmod 600 "$d/snap/svcstate.tsv"
set_u "$d/sc" pdg-probe81 disabled active
o="$(run_restore "$d")"
unl "$o" | grep -q 'mihomo 自启前像无法确认(记录时查询 rc=3)' && ok "J1: 记录时查询失败 → 登记为无法确认" || { bad "J1"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-probe81 自启状态 static 无法用 enable/disable 恢复(现为 disabled)' && ok "J2: static 不先改再说不支持, 只如实登记" || bad "J2"
unl "$o" | grep -q 'pdg-health.timer 前像是过渡态 activating, 未恢复' && ok "J3: 过渡态不猜, 登记" || bad "J3"
grep -qE '^(enable|disable) pdg-probe81' "$d/restore.log" && bad "J4: 对 static 的 unit 动了 enable/disable" || ok "J4: 没对 static 的 unit 动 enable/disable"
grep -qE '^(enable|disable) mihomo' "$d/restore.log" && bad "J5: 对「记录时没查到」的 unit 擅自动手" || ok "J5: 没对无法确认的 unit 擅自动手"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

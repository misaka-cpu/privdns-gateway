#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 服务前像的**恢复**这一格。
#
# 要补的洞: 快照只收文件。`multi-user.target.wants/` 下那些 enable 符号链接全仓从不快照,
# 所以"文件都回来了"≠"服务回到了原来的运行态与自启态"。原来的回滚在这种现场会自报
# "✅ 已回滚并重启服务"。
#
# 这一支验的是恢复判定本身: 用**产品原文**的函数(sed 抽取), systemctl 是本用例自己的
# 可控桩 —— 只回答状态、记账、按指令改自己的假状态, **不管理任何真实服务**。
# 桩额外支持两种坏情况: 动作返回失败, 以及**动作返回成功但状态没真的变**。
# 真 systemd 那一格由 tests/e2e-real-migration.sh 负责, 这里不冒充。
#
# 三态恢复与失败报告各自带撤销对照: 把关键那几行换成"天真实现"跑同一场景, 证明结论
# 确实由被测代码得出, 而不是夹具初始状态凑出来的。
# 退出码 0=全过。
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

# ── 可控 systemctl 桩 ────────────────────────────────────────────────────────
# 每个 unit 一组小文件: .en 自启值 / .ac 运行值 / .sub / .inv
#   .fail_<动作>  → 那个动作返回 1 且不改状态
#   .lie_<动作>   → 那个动作返回 0 但**不改状态**(用来验"返回成功≠真的恢复了")
STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1"
  case "$act" in
    is-enabled) cat "$SC_DIR/$u.en" 2>/dev/null || { echo not-found; return 1; }; return 0;;
    is-active)  cat "$SC_DIR/$u.ac" 2>/dev/null || { echo inactive; return 3; }; return 0;;
    show) case "$3" in
            LoadState)    [[ -e "$SC_DIR/$u.en" ]] && echo loaded || echo not-found;;
            SubState)     cat "$SC_DIR/$u.sub" 2>/dev/null || echo dead;;
            InvocationID) cat "$SC_DIR/$u.inv" 2>/dev/null || echo "";;
            *) echo "";;
          esac; return 0;;
  esac
  [[ -e "$SC_DIR/$u.fail_$act" ]] && return 1
  [[ -e "$SC_DIR/$u.lie_$act"  ]] && return 0
  case "$act" in
    enable)  [[ "$2" == --runtime ]] && echo enabled-runtime > "$SC_DIR/$u.en" || echo enabled > "$SC_DIR/$u.en";;
    disable) echo disabled > "$SC_DIR/$u.en";;
    start)   echo active   > "$SC_DIR/$u.ac";;
    stop)    echo inactive > "$SC_DIR/$u.ac";;
  esac
  return 0
}'

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
set_u(){ # $1=SC_DIR $2=unit $3=enabled值 $4=active值
  echo "$3" > "$1/$2.en"; echo "$4" > "$1/$2.ac"
  echo running > "$1/$2.sub"; echo "INV-$2" > "$1/$2.inv"
}
seed(){  # $1=SC_DIR : 先把八个都摆成 enabled/active, 各用例再单独改
  local d="$1" u; mkdir -p "$d"; for u in $U_ALL; do set_u "$d" "$u" enabled active; done
}

# 造一份合法前像(用产品原文的保存函数, 不手搓格式)
save_preimage(){ # $1=场景目录
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/save.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  } > "$d/save.sh"
  bash "$d/save.sh"
}

# 跑恢复(可选: 用"天真实现"替换被测函数, 做撤销对照)
run_restore(){ # $1=场景目录 [$2=naive|"" ]
  local d="$1" mode="${2:-}"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/restore.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_svcstate_valid
    case "$mode" in
      naive-restart)
        # 撤销对照(三态): 换成回滚原来那套 —— 一律 restart, 不看前像
        echo 'naive(){ local u; for u in '"$U_ALL"'; do systemctl restart "$u" >/dev/null 2>&1; systemctl start "$u" >/dev/null 2>&1; done; }';;
      naive-norecheck)
        # 撤销对照(失败报告): 只看动作返回码, 不复核后置状态
        echo 'naive(){ local u ufs asv rc
          while IFS=$'"'"'\t'"'"' read -r _k u ufs _urc asv _arc _sub _inv; do
            [[ "$_k" == unit && -n "$u" ]] || continue
            case "$ufs" in enabled) systemctl enable "$u" >/dev/null 2>&1 || unrestored+=("$u enable 失败");; esac
            case "$asv" in active)  systemctl start  "$u" >/dev/null 2>&1 || unrestored+=("$u start 失败");;  esac
          done < "$1/svcstate.tsv"; }';;
      *) _fnN "$PDG" _pdg_restore_svcstate;;
    esac
    echo 'unrestored=()'
    case "$mode" in
      naive-restart)   echo "naive; rc=0";;
      naive-norecheck) echo "naive \"$d/snap\"; rc=0";;
      *)               echo "_pdg_restore_svcstate \"$d/snap\"; rc=\$?";;
    esac
    echo 'printf "RC=%s\n" "$rc"'
    echo 'for x in "${unrestored[@]+"${unrestored[@]}"}"; do printf "UNRESTORED\t%s\n" "$x"; done'
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

echo "══ 一. 三态恢复: active+enabled / inactive+disabled / enabled-runtime ══"
d="$(mk A)"
set_u "$d/sc" pdg-mitm enabled         active      # 原本: 开着且自启
set_u "$d/sc" pdg-bot  disabled        inactive    # 原本: 关着且不自启
set_u "$d/sc" mosdns   enabled-runtime active      # 原本: 只这次开机有效
save_preimage "$d"
# 把现场弄成"回滚之后的样子": 自启链接全没了(快照不收 wants/), 且通用 restart 把该关的也拉起来了
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
o="$(run_restore "$d")"
[[ "$(fin "$o" pdg-mitm)" == "enabled/active" ]] && ok "A1: active+enabled 恢复回 enabled/active" || bad "A1: 实得 $(fin "$o" pdg-mitm)"
[[ "$(fin "$o" pdg-bot)"  == "disabled/inactive" ]] && ok "A2: inactive+disabled 恢复回 disabled/inactive(通用 restart 拉起来的被停回去)" || bad "A2: 实得 $(fin "$o" pdg-bot)"
[[ "$(fin "$o" mosdns)"   == "enabled-runtime/active" ]] && ok "A3: enabled-runtime **没有**被提升成永久 enabled" || bad "A3: 实得 $(fin "$o" mosdns)"
[[ "$(nun "$o")" == 0 ]] && ok "A4: 全部恢复成功 ⇒ 未恢复项为空" || { bad "A4: 冒出了未恢复项"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 二. 撤销对照(三态): 换成原来那套「一律 restart」, 同一场景恢复不回来 ══"
d="$(mk B)"
set_u "$d/sc" pdg-mitm enabled active; set_u "$d/sc" pdg-bot disabled inactive; set_u "$d/sc" mosdns enabled-runtime active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
o="$(run_restore "$d" naive-restart)"
[[ "$(fin "$o" pdg-mitm)" == "disabled/active" ]] && ok "B1: 天真实现下 pdg-mitm 仍不自启(enabled 没回来)—— A1 确实是被测代码的功劳" || bad "B1: 对照没体现差异, 实得 $(fin "$o" pdg-mitm)"
[[ "$(fin "$o" pdg-bot)"  == "disabled/active" ]] && ok "B2: 天真实现下 pdg-bot 被留在 active(本该是 inactive)" || bad "B2: 实得 $(fin "$o" pdg-bot)"
[[ "$(fin "$o" mosdns)"   == "disabled/active" ]] && ok "B3: 天真实现下 enabled-runtime 丢失" || bad "B3: 实得 $(fin "$o" mosdns)"
[[ "$(nun "$o")" == 0 ]] && ok "B4: 而且它**一声不吭**(未恢复项为空)—— 这正是原来那句「✅ 已回滚并重启服务」的来历" || bad "B4: 对照意外报了未恢复项"

echo
echo "══ 三. 动作返回成功、后置状态却不符 → 计入未恢复 ══"
d="$(mk C)"
set_u "$d/sc" pdg-mitm enabled active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
: > "$d/sc/pdg-mitm.lie_enable"      # enable 返回 0, 状态纹丝不动
o="$(run_restore "$d")"
unl "$o" | grep -q 'pdg-mitm 自启未恢复(目标 enabled, 实得 disabled' \
  && ok "C1: 动作返回成功但状态没变 → 如实登记为未恢复" || { bad "C1: 没登记"; unl "$o" | sed 's/^/      /'; }
grep -q 'RC=0' <<<"$o" && ok "C2: 恢复函数本身仍走完(未恢复项由调用方汇总)" || bad "C2"

echo
echo "══ 四. 撤销对照(失败报告): 只看返回码不复核 → 同一现场被漏报 ══"
d="$(mk D)"
set_u "$d/sc" pdg-mitm enabled active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled active; done
: > "$d/sc/pdg-mitm.lie_enable"
o="$(run_restore "$d" naive-norecheck)"
[[ "$(nun "$o")" == 0 ]] && ok "D1: 天真实现(只看 rc)对同一现场零登记 —— C1 确实来自「动作之后复核状态」这一条" || { bad "D1: 对照没体现差异"; unl "$o" | sed 's/^/      /'; }
[[ "$(fin "$o" pdg-mitm)" == "disabled/active" ]] && ok "D2: 而状态确实没恢复" || bad "D2: 实得 $(fin "$o" pdg-mitm)"

echo
echo "══ 五. 恢复动作本身失败 → 计入未恢复 ══"
d="$(mk E)"
set_u "$d/sc" pdg-mitm enabled active; set_u "$d/sc" mihomo enabled active
save_preimage "$d"
for u in $U_ALL; do set_u "$d/sc" "$u" disabled inactive; done
: > "$d/sc/pdg-mitm.fail_enable"
: > "$d/sc/mihomo.fail_start"
o="$(run_restore "$d")"
unl "$o" | grep -q 'pdg-mitm 自启未恢复(目标 enabled, 实得 disabled, enable rc=1)' \
  && ok "E1: enable 失败 → 登记且带上 rc" || { bad "E1"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'mihomo 未回到运行态(目标 active, 实得 inactive, start rc=1)' \
  && ok "E2: start 失败 → 登记且带上 rc" || { bad "E2"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-bot' && bad "E3: 好的那些也被误报了" || ok "E3: 没有牵连其它已恢复的服务"

echo
echo "══ 六. 旧快照没有前像: 不冒充完整恢复 ══"
d="$(mk F)"; rm -f "$d/snap/svcstate.tsv"
o="$(run_restore "$d")"
grep -q 'RC=1' <<<"$o" && ok "F1: 返回非 0(调用方据此不得报「完全回滚」)" || bad "F1: 返回了 0"
unl "$o" | grep -q '服务前像缺失(旧快照; 运行态/自启未确认)' && ok "F2: 登记为「未确认」而不是「已恢复」" || { bad "F2"; unl "$o" | sed 's/^/      /'; }
grep -q '无法确认' <<<"$(sed 's/\x1b\[[0-9;]*m//g' <<<"$o")" && ok "F3: 明说无法确认, 并指出要人工复核哪些 unit" || bad "F3"
grep -qE '^(enable|disable|start|stop) ' "$d/restore.log" 2>/dev/null \
  && bad "F4: 没有前像却动了服务(等于凭空推断历史)" || ok "F4: 没有前像时**不推断、不乱动**(日志里没有 enable/disable/start/stop)"

echo
echo "══ 七. 前像损坏: 登记, 不假装恢复过 ══"
d="$(mk G)"; save_preimage "$d"
sed -i 's|^created_at\t.*|created_at\tTAMPERED|' "$d/snap/svcstate.tsv"
o="$(run_restore "$d")"
grep -q 'RC=1' <<<"$o" && ok "G1: 返回非 0" || bad "G1"
unl "$o" | grep -q '服务前像不可用(正文摘要对不上' && ok "G2: 说清了是哪一条不过" || { bad "G2"; unl "$o" | sed 's/^/      /'; }

echo
echo "══ 八. 记录时就没查到 / 不是 enable-disable 能表达的 / 过渡态 ══"
d="$(mk H)"
set_u "$d/sc" pdg-probe81 static   active
set_u "$d/sc" pdg-dotwitness masked inactive
save_preimage "$d"
# 手工把两格改成"记录时查询失败"与"过渡态"(桩造不出来这两种, 直接按格式写进记录再封口)
python3 - "$d/snap/svcstate.tsv" <<'PY'
import hashlib, sys
p = sys.argv[1]
out = []
for l in open(p, encoding="utf-8").read().split("\n"):
    if l.startswith("end\t"):
        continue
    f = l.split("\t")
    if f[0] == "unit" and f[1] == "mihomo":
        f[2] = "QUERY-FAILED"; f[3] = "3"; l = "\t".join(f)
    if f[0] == "unit" and f[1] == "pdg-health.timer":
        f[4] = "activating"; l = "\t".join(f)
    out.append(l)
while out and out[-1] == "":
    out.pop()
body = "\n".join(out) + "\n"
n = sum(1 for l in out if l.startswith("unit\t"))
open(p, "w", encoding="utf-8").write(body + "end\t%d\t%s\n" % (n, hashlib.sha256(body.encode()).hexdigest()))
PY
chmod 600 "$d/snap/svcstate.tsv"
set_u "$d/sc" pdg-probe81 disabled active      # 现状与 static 前像不符
o="$(run_restore "$d")"
unl "$o" | grep -q 'mihomo 自启前像无法确认(记录时查询 rc=3)' && ok "H1: 记录时查询失败 → 登记为无法确认(不是两个空串相等就算过)" || { bad "H1"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-probe81 自启状态 static 无法用 enable/disable 恢复(现为 disabled)' && ok "H2: static 不先改再说不支持, 只如实登记" || { bad "H2"; unl "$o" | sed 's/^/      /'; }
unl "$o" | grep -q 'pdg-health.timer 前像是过渡态 activating, 未恢复' && ok "H3: 过渡态不猜, 登记" || { bad "H3"; unl "$o" | sed 's/^/      /'; }
grep -qE '^(enable|disable) pdg-probe81' "$d/restore.log" && bad "H4: 对 static 的 unit 动了 enable/disable" || ok "H4: 没对 static 的 unit 动 enable/disable"
grep -qE '^(enable|disable) mihomo' "$d/restore.log" && bad "H5: 对「记录时没查到」的 unit 擅自动手" || ok "H5: 没对无法确认的 unit 擅自动手"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

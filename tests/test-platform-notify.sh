#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# `pdg platform <ios|android> --notify`(bot「📱 手机平台」点的后台任务)的结果通知。
#
# 切换本身是 cmd_platform, 别的测试按函数体钉着它, 这一支不碰; 这里只验包在外面的那一层:
#   · 每种结局都发且只发一条 Telegram: 成功 / 失败(已还原、没动过、还原没做完)/ 没做完
#     (cmd_platform 里 _lock 拿不到锁直接 exit —— 走不到函数末尾, 靠 EXIT trap 补发);
#   · 失败原因取 cmd_platform 自己打出的第一行 ❌, 去掉颜色码, 进 HTML 前转义;
#   · 不带 --notify 时派发行仍直接走 cmd_platform。
# 真的 _platform_* 函数从 pdg.sh 按名抽出来(先核抽到的非空), 打桩的是 cmd_platform(按场景
# 打出 cmd_platform 真会打的那几行)、_pdg_platform、_kernel_host 与 _kf(notify 记进文件)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-platnotify.XXXXXX")"
[[ -n "${PDG_KEEP_TMP:-}" ]] || trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
finish(){ echo "通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; exit $?; }

echo "══ 0. 抽取 ══"
LIB="$WORK/lib.sh"
grep -E '^PF_NOTIFIED=0; PF_LOG=""; PF_OUT=1$' "$PDG" > "$LIB"
fnlist=(_platform_name _platform_html _platform_note _platform_exit_notify _platform_notify_run)
for f in "${fnlist[@]}"; do
  body="$(sed -n "/^$f(){/,/^}/p" "$PDG")"
  # 单行函数(以 } 收尾的同一行)sed 区间会读穿到下一个顶格 } —— 单独处理
  one="$(grep -E "^$f\(\)\{.*\}$" "$PDG" || true)"
  [[ -n "$one" ]] && body="$one"
  if [[ -z "$body" ]]; then bad "抽不到 $f"; finish; fi
  printf '%s\n' "$body" >> "$LIB"
done
n_def="$(grep -cE "^(_platform_name|_platform_html|_platform_note|_platform_exit_notify|_platform_notify_run)\(\)\{" "$LIB")"
[[ "$(grep -c '^PF_NOTIFIED=0; PF_LOG=""; PF_OUT=1$' "$LIB")" == 1 && "$n_def" == 5 ]] \
  && ok "抽到全局初值一行与 5 个函数定义(各一次)" || { bad "抽取不完整(函数定义 $n_def 个)"; finish; }
bash -n "$LIB" && ok "抽出来的代码语法通过" || { bad "抽出来的代码语法不通"; finish; }

# 场景替身: cmd_platform 按 SCEN 打出它真会打的行(颜色码照真实 c_g / c_y / c_r 的写法)
cat > "$WORK/stubs.sh" <<'EOF'
_pdg_platform(){ echo "$CUR"; }
_kernel_host(){ echo gw; }
# 往下调用的函数给通用名赋值、不声明 local(动态作用域会改到调用链上最近的同名 local)
_leaky(){ rc=1; h=x; doc=y; why=z; cur=ios; p=android; plain=q; }
_kf(){ [[ "$1" == notify ]] && { printf '%s\n--END--\n' "$2" >> "$NOTES"; return 0; }; return 1; }
G=$'\033[1;32m'; Y=$'\033[1;33m'; Rr=$'\033[1;31m'; Z=$'\033[0m'
cmd_platform(){
  [[ $# -eq 0 ]] && { echo "用法: pdg platform <ios|android>"; return 1; }
  echo "CALLED $*" >> "$CALLS"
  case "$SCEN" in
    ok_green) echo "${G}[*]${Z} 切换平台: $CUR → $1"; echo "${G}[*]${Z} 平台已确认: $CUR → $1"
              printf '%s\n' "  🟢 平台: $1" "" "🟢 全部正常  (0 失败 / 0 警告)"; return 0;;
    ok_warn)  echo "${G}[*]${Z} 平台已确认: $CUR → $1"; printf '%s\n' "" "🟡 有警告  (0 失败 / 2 警告)"
              echo "${Y}[!]${Z} 自检有未通过项(见上), 平台切换本身已完成。"; return 0;;
    ok_nodoc) echo "${G}[*]${Z} 平台已确认: $CUR → $1"; return 0;;
    ok_clobber) _leaky; echo "${G}[*]${Z} 平台已确认: $CUR → $1"; printf '%s\n' "🟢 全部正常  (0 失败 / 0 警告)"; return 0;;
    fail_restored)
              echo "${G}[*]${Z} 切换平台: $CUR → $1"; echo "❌ 防火墙按新平台重建失败"
              echo "${Y}[!]${Z} 已恢复到原平台 $CUR 与原配置(平台专属文件与服务状态已逐项复核; 快照仍在, 必要时可 sudo pdg rollback)。"
              return 1;;
    fail_snap_restored)
              echo "❌ WLOC 退役迁移未完成(详见上方), 平台切换回退"
              echo "${Y}[!]${Z}   本次已经撤除过退役件/推进过记录格式 —— 那几样不在局部备份里, 改用本次快照做整体恢复。"
              echo "${G}[*]${Z}   已按本次快照恢复到切换前(文件/运行态/自启态已逐项核验)。"; return 1;;
    fail_incomplete)
              echo "❌ 新平台的 mihomo 配置校验(mihomo -t)未过"
              echo "${Rr}[x]${Z} ❌ 恢复未完成 —— 这与上面那次操作失败是两件事, 分开看:"; return 1;;
    fail_untouched)
              echo "${G}[*]${Z} 切换平台: $CUR → $1"; echo "❌ 快照失败 → 中止切换(未改动任何东西)"; return 1;;
    fail_html) echo "${Rr}❌ 切换后这些服务未稳定运行: <svc>&x${Z}"; return 1;;
    fail_noreason) echo "something odd"; return 3;;
    lock_busy) echo "⛔ 已有 pdg 操作在运行, 请稍后再试 (锁: /run/privdns-gateway.lock)"; exit 1;;
  esac
}
EOF

# 跑一格: run <场景> <当前平台> <参数...>  → 设 RC / NOTE / NCOUNT / OUT / CALL
run(){
  local scen="$1" cur="$2"; shift 2
  : > "$WORK/notes"; : > "$WORK/calls"; rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
  OUT="$(SCEN="$scen" CUR="$cur" NOTES="$WORK/notes" CALLS="$WORK/calls" TMPDIR="$WORK/tmp" \
         bash -c 'set -uo pipefail; source "$1"; source "$2"; shift 2; _platform_notify_run "$@"' _ \
         "$LIB" "$WORK/stubs.sh" "$@" 2>&1)"; RC=$?
  NCOUNT="$(grep -c '^--END--$' "$WORK/notes")"
  NOTE="$(sed '/^--END--$/d' "$WORK/notes")"
  CALL="$(cat "$WORK/calls")"
  LEFT="$(find "$WORK/tmp" -type f | wc -l)"
}

echo "══ 1. 成功 ══"
run ok_green android ios --notify
[[ "$RC" == 0 && "$NCOUNT" == 1 && "$CALL" == "CALLED ios" ]] && ok "切到 iOS 成功: rc 0、cmd_platform 收到 ios(不带 --notify)、恰发一条" \
  || bad "rc=$RC 通知数=$NCOUNT 调用=[$CALL]"
[[ "$NOTE" == "✅ <b>gw</b> 手机平台已切到 <b>iOS</b>(原 Android)。"* && "$NOTE" == *"iOS 描述文件"* \
   && "$NOTE" == *"sudo pdg detect-cidr"* && "$NOTE" == *"切换后自检全部正常。" ]] \
  && ok "成功文案: 目标 / 原平台 / 下一步(描述文件)/ detect-cidr / 自检全部正常" || bad "文案: $NOTE"
[[ "$OUT" == *"平台已确认"* ]] && ok "cmd_platform 的输出照样留在标准输出(进 journal)" || bad "输出没留下: $OUT"
[[ "$LEFT" == 0 ]] && ok "临时日志收尾删掉了" || bad "临时目录里留了 $LEFT 个文件"
run ok_warn ios android --notify
[[ "$RC" == 0 && "$NCOUNT" == 1 && "$NOTE" == *"Android"*"(原 iOS)"* && "$NOTE" == *"私密 DNS"* \
   && "$NOTE" == *"⚠️ 切换后自检 0 失败 / 2 警告, 点「🩺 自检」看。" ]] \
  && ok "切到 Android 成功但自检有警告: 文案带私密 DNS 与「0 失败 / 2 警告」" || bad "rc=$RC n=$NCOUNT: $NOTE"
run ok_nodoc android ios --notify
[[ "$RC" == 0 && "$NCOUNT" == 1 && "$NOTE" == *"内网卡段。" ]] && ok "没有自检输出时不编造自检结论" || bad "$NOTE"

run ok_clobber android ios --notify
[[ "$RC" == 0 && "$NCOUNT" == 1 && "$NOTE" == "✅ <b>gw</b> 手机平台已切到 <b>iOS</b>(原 Android)。"*"切换后自检全部正常。" ]] \
  && ok "cmd_platform 下游给 rc / h / doc 等通用名赋值(不声明 local): 成功仍报成功, 主机名与原平台不被改" || bad "rc=$RC: $NOTE"

echo "══ 2. 失败 ══"
run fail_restored android ios --notify
[[ "$RC" == 1 && "$NCOUNT" == 1 && "$NOTE" == "❌ <b>gw</b> 手机平台切到 iOS 没成: ❌ 防火墙按新平台重建失败 已恢复到原平台 Android。" ]] \
  && ok "失败且局部还原成功: 第一行 ❌ 作原因 + 已恢复到原平台" || bad "rc=$RC n=$NCOUNT: $NOTE"
run fail_snap_restored ios android --notify
[[ "$RC" == 1 && "$NCOUNT" == 1 && "$NOTE" == *"WLOC 退役迁移未完成"*"已恢复到原平台 iOS。" ]] \
  && ok "失败且按快照整体恢复: 也说已恢复" || bad "$NOTE"
run fail_incomplete android ios --notify
[[ "$RC" == 1 && "$NCOUNT" == 1 && "$NOTE" == *"mihomo -t"*"还原没做完"* && "$NOTE" != *"已恢复到原平台"* ]] \
  && ok "还原没做完: 说没做完、不说已恢复, 原因取第一行 ❌(不是「恢复未完成」那行)" || bad "$NOTE"
run fail_untouched android ios --notify
[[ "$RC" == 1 && "$NOTE" == *"快照失败"*"没有改动任何东西, 仍是 Android。" ]] && ok "动手前就停: 说没有改动" || bad "$NOTE"
run fail_html android ios --notify
[[ "$NOTE" == *"&lt;svc&gt;&amp;x"* && "$NOTE" != *"<svc>"* && "$NOTE" != *$'\033'* ]] \
  && ok "原因进 HTML 前转义, 颜色码去掉" || bad "$(printf '%q' "$NOTE")"
run fail_noreason android ios --notify
[[ "$RC" == 3 && "$NCOUNT" == 1 && "$NOTE" == *"没有打出原因"*"以 sudo pdg status 为准。" ]] \
  && ok "没打出原因: 照发一条, 退出码原样传出, 不猜现在是哪个平台" || bad "rc=$RC: $NOTE"

echo "══ 3. 走不到函数末尾的结局(EXIT trap 补发) ══"
run lock_busy android ios --notify
[[ "$RC" == 1 && "$NCOUNT" == 1 && "$NOTE" == "⚠️ <b>gw</b> 平台切换没有做完"* ]] \
  && ok "拿不到锁(_lock 直接 exit): 补发一条「没有做完」" || bad "rc=$RC n=$NCOUNT: $NOTE"
[[ "$OUT" == *"已有 pdg 操作在运行"* && "$LEFT" == 0 ]] && ok "那次的输出仍打到标准输出, 临时日志删掉" || bad "out=[$OUT] left=$LEFT"
run ok_green android --notify
[[ "$RC" == 2 && "$NCOUNT" == 1 && "$NOTE" == *"参数不对"* && -z "$CALL" ]] \
  && ok "没给目标平台: 不调 cmd_platform 动手, 发一条「参数不对」" || bad "rc=$RC n=$NCOUNT call=[$CALL]: $NOTE"
run ok_green android ios --notify bogus
[[ "$RC" == 2 && -z "$CALL" ]] && ok "多出未知参数: 同样不动手" || bad "rc=$RC call=[$CALL]"

echo "══ 4. 派发行 ══"
arm="$(grep -E '^  platform\)' "$PDG")"
[[ "$(grep -cE '^  platform\)' "$PDG")" == 1 ]] && ok "顶层派发里 platform 分支恰一条" || bad "platform 分支不唯一"
[[ "$arm" == *'if [[ " $* " == *" --notify "* ]]; then _platform_notify_run "$@"; else cmd_platform "$@"; fi;;' ]] \
  && ok "带 --notify 才走通知包装, 否则原样 cmd_platform" || bad "派发行: $arm"
finish

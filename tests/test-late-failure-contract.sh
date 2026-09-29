#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ④(退役成功后的晚期失败 → 产品自动回滚)的接线契约。不碰真实服务; 不需要 root / systemd。
#
# 验三件事, 各自具名:
#   一、workflow 接线: real_scope 多了 late-failure 这一个选项与 real-late-failure 这一个 job;
#       该 job 在同一 runner 上**先原样跑 ②**, ② 成功才进 ④(不先跑一次成功的 ③ 再从退役终态起跑),
#       不用 continue-on-error 掩盖失败。本节只看 real-late-failure 这一个 job(边界与 ③ 契约同款限定)。
#   二、④ 脚本的静态边界: 升级调用只有 ③ 原样的那一处(r3_invoke), 不手动 rollback, 不从测试链接恢复
#       任何产品文件, 不写现役仓库 / /usr/local/bin, 门的返回码与主流程分支齐全。
#   三、④ 自己的判据(按唯一成对标记抽出来, 受控输入驱动): 注入原语、运行中防火墙读取、有序标记、
#       回滚结局、本次快照绑定、文件清单比对, 以及**零调用矩阵** —— 任一门不成立时桩 CLI 必须 0 次。
#       330 补: 观测失败不消费(先输出合法值再失败 / 查询自身出错, 各自具名, 注入命中由替身自己记)、
#       退出码三样分开结算、身份 / 服务 / DNS 回滚检查的健康与反例(判据原文驱动, 只顶替最末端的外部观测)。
#   每一格都分开核三样: 子壳是否正常结束(收尾标记是最后一行)、被测函数的结果、桩自己的调用记录。
#   正常输出之后异常退出 = 这一格执行无效; 调用记录读不到 = 读不到, 不补 0。
#   331: 格的有效性把子壳退出码、退出码文件读取、末行读取、收尾标记分开核(读取失败 = 观测无效, 与子壳异常分开说);
#        第一、二节宣布"没有违规形态"的查询分清找到 / 确认没找到 / 查询出错, 计数的退出码与条数必须一致。
#   335(路径 A): 注入前提门改为核冻结退役提交里模板的有效规则(调用前现役文件不再要求含 5228)、救援自动选址的只读探测;
#        有序证据加 M0「模板重建」; 调用前补采磁盘防火墙原文与 .pre-tplsync; 回滚后核目标 / 链接的设备 / inode / nlink。
#
# 复用与替换: ④ 的判据执行**原文**; 只替换它的外部依赖 —— 文件类判据经 PDG_LATE_FAIL_ROOT 指到沙箱树
# (与产品 migrate_wloc_retire 的 PDG_RETIRE_ROOT 同款约定), nft / ③ 的各道门用格内函数顶替, 并逐项登记。
# ③ 的那几道门本身由 ③ 的契约负责, 这里只验 ④ 把它们串起来的顺序与"不成立就不调用"。
# 这仍是模型验证, 不冒充真实 systemd / journal / DNS / 防火墙验收。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R4="$ROOT/tests/e2e-real-late-failure.sh"; R3="$ROOT/tests/e2e-real-retire-hop.sh"
HOP2="$ROOT/tests/e2e-real-bridge-hop.sh"; WF="$ROOT/.github/workflows/ci.yml"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# 第一、二节里宣布"没有违规形态"的查询(331): 找到 / 确认没找到 / 查询出错分开 —— 只有确认没找到才支持"没有";
# 计数要求 grep -c 的退出码与条数一致(0 ⇔ 条数 > 0, 1 ⇔ 条数 0), 先输出数字再非零退出的不采信。
q3(){ grep -q "$@" 2>/dev/null; local r=$?; (( r <= 1 )) && return "$r"; QWHY="grep 出错(rc=$r, 模式 ${*: -2:1})"; return 2; }   # → 0 找到 / 1 确认没找到 / 2 查询出错
qcnt(){ local out r; QN=""; out="$(grep -c "$@" 2>/dev/null)"; r=$?   # → 0 取得(QN) / 2 不采信(QWHY)
  if (( r == 0 )) && [[ "$out" =~ ^[1-9][0-9]*$ ]]; then QN="$out"; return 0; fi
  if (( r == 1 )) && [[ "$out" == 0 ]]; then QN=0; return 0; fi
  QWHY="grep -c 退出 $r、输出 [${out:0:20}], 模式 ${*: -2:1}"; return 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/r4c.XXXXXX")" || { echo "[未执行] 建不出临时目录"; echo "通过 0, 失败 1"; exit 1; }
trap 'rm -rf -- "$T"' EXIT
for f in "$R4" "$R3" "$HOP2" "$WF" "$ROOT/tests/repoguard.sh"; do [[ -f "$f" ]] || { bad "找不到 $f"; echo "通过 $pass, 失败 $nfail"; exit 1; }; done
# 沙箱仓库的 ref 改动一律经 e2e_git(守卫与动作一次调用); repoguard.sh 只有函数, 没有顶层副作用
# shellcheck source=/dev/null
source "$ROOT/tests/repoguard.sh" || { bad "repoguard.sh 装载失败"; echo "通过 $pass, 失败 $nfail"; exit 1; }

echo "══ 一. workflow 接线(只看 real-late-failure 这一个 job) ══"
grep -qxF '        options: ["all", "platform", "retire", "bridge", "retire-hop", "late-failure"]' "$WF" \
  && ok "一-1 real_scope 选项整行逐字相符(late-failure 在末尾, 原有五项顺序不变)" || bad "一-1 real_scope 选项整行不对"
grep -qF 'late-failure = ②+④ 同一 job' "$WF" \
  && ok "一-1b real_scope 的说明里写明了 late-failure 是 ②+④ 同一 job" || bad "一-1b real_scope 说明没跟上"
job_block(){ awk -v h="  $1:" '$0==h{f=1} f && $0!=h && /^  [a-z][a-z0-9-]*:$/{exit} f' "$WF"; }
# job 块是一-3 / 一-4 / 一-11 否定结论的输入: 抽取没成功(包括先写出一截再非零退出)⇒ 那几条"没有"都不作
job_block real-late-failure > "$T/job.yml"; JRC=$?
h1="$(head -1 "$T/job.yml" 2>/dev/null)"; HRC=$?
if (( JRC != 0 )); then bad "一-2 job 块抽取失败(awk rc=$JRC)—— 已写出的部分不采信"
elif (( HRC != 0 )); then bad "一-2 job 块首行读不了(head rc=$HRC)"
elif ! qcnt -E '^  [a-z][a-z0-9-]*:$' "$T/job.yml"; then bad "一-2 job 头计数查询失败($QWHY)"
elif [[ -s "$T/job.yml" && "$h1" == "  real-late-failure:" && "$QN" == 1 ]]; then
  ok "一-2 取到的是 real-late-failure 自身($(grep -c '' "$T/job.yml") 行, 块内只有它一个 job 头)"
else bad "一-2 job 抽取边界不对(首行 [$h1])"; fi
q3 -F "github.event.inputs.real_scope == 'late-failure'" "$T/job.yml"; r13a=$?
q3 -E "real_scope == '(all|platform|retire|bridge|retire-hop|)'" "$T/job.yml"; r13b=$?
if (( JRC != 0 )); then bad "一-3 job 块没取得(awk rc=$JRC)—— 启动条件不判"
elif (( r13a == 2 || r13b == 2 )); then bad "一-3 启动条件查询出错($QWHY)—— 观测无效, 不说成不搭别的范围的车"
elif (( r13a == 0 && r13b == 1 )); then ok "一-3 real-late-failure 只在 real_scope=late-failure 时启动(不搭别的范围的车)"
else bad "一-3 ④ job 的启动条件不对"; fi
if (( JRC != 0 )); then bad "一-4 job 块没取得(awk rc=$JRC)—— 「没有 continue-on-error」不判"
else q3 'continue-on-error' "$T/job.yml"
  case $? in
    0) bad "一-4 ④ job 里有 continue-on-error";;
    1) ok "一-4 ④ job 里没有 continue-on-error";;
    *) bad "一-4 查询出错($QWHY)—— 观测无效, 不说成没有";;
  esac
fi
l2="$(grep -n '^        id: real2$' "$T/job.yml" | cut -d: -f1)"; l4="$(grep -n '^        id: real4$' "$T/job.yml" | cut -d: -f1)"
lc="$(grep -n 'run: bash tests/test-late-failure-contract.sh' "$T/job.yml" | cut -d: -f1)"
{ [[ -n "$l2" && -n "$l4" && -n "$lc" ]] && (( lc < l2 && l2 < l4 )); } \
  && ok "一-5 顺序: ④ 契约 → ② 原样(id real2) → ④(id real4)" || bad "一-5 步骤顺序不对(契约=$lc real2=$l2 real4=$l4)"
sed -n "${l2:-1},${l4:-1}p" "$T/job.yml" > "$T/real2.yml"
grep -qx '        shell: bash' "$T/real2.yml" && grep -qx '          set -o pipefail' "$T/real2.yml" \
  && ok "一-6 ② 步用 bash + pipefail(tee 不吞 ② 的退出码)" || bad "一-6 ② 步没有 pipefail 保护"
grep -qx '          sudo -E bash tests/e2e-real-bridge-hop.sh 2>&1 | tee /tmp/real2-stdout.log' "$T/real2.yml" \
  && ok "一-7 ② 步跑的就是原样的 tests/e2e-real-bridge-hop.sh" || bad "一-7 ② 步的调用不是原样脚本"
python3 - "$WF" > "$T/env.txt" 2>&1 <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
def env_of(block):
    m = re.search(r"\n        env:\n((?:          [A-Z0-9_]+: .*\n)+)", block)
    return m.group(1) if m else None
def job(name):
    return re.split(r"\n  [a-z][a-z0-9-]*:\n", s.split("\n  %s:\n" % name, 1)[1], maxsplit=1)[0]
a = env_of(job("real-bridge-hop").split("run: sudo -E bash tests/e2e-real-bridge-hop.sh", 1)[0].rsplit("      - name:", 1)[1])
b = env_of(job("real-late-failure").split("        id: real2\n", 1)[1].split("      - name:", 1)[0])
print(a); print("----"); print(b)
sys.exit(0 if a and a == b else 1)
PY
[[ $? == 0 ]] && ok "一-8 ④ job 里 ② 步的 env 与 real-bridge-hop 的 ② 步逐字相同" || bad "一-8 ② 步 env 不同($(head -c 200 "$T/env.txt" | tr '\n' ' '))"
sed -n "${l4:-1},\$p" "$T/job.yml" > "$T/real4.yml"
grep -qF "if: \${{ success() && steps.real2.outcome == 'success' }}" "$T/real4.yml" \
  && ok "一-9 ④ 步只在 ② 成功后启动" || bad "一-9 ④ 步没有以 ② 成功为条件"
grep -qx '        run: sudo -E bash tests/e2e-real-late-failure.sh' "$T/real4.yml" \
  && ok "一-10 ④ 步跑 tests/e2e-real-late-failure.sh" || bad "一-10 ④ 步的调用不对"
if (( JRC != 0 )); then bad "一-11 job 块没取得(awk rc=$JRC)—— 「不跑 ③」不判"
else q3 'e2e-real-retire-hop\.sh' "$T/job.yml"
  case $? in
    0) bad "一-11 ④ job 里跑了 ③ —— ④ 的起点必须是 ② 的桥接现场, 不是先成功一次 ③ 之后的退役终态";;
    1) ok "一-11 ④ job 里不跑 ③: 起点是 ② 的桥接现场, 不从退役终态起跑";;
    *) bad "一-11 查询出错($QWHY)—— 观测无效, 不说成不跑 ③";;
  esac
fi
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert "real-late-failure" in d["jobs"]' "$WF" \
    && ok "一-12 整份 workflow 能按 YAML 解析, real-late-failure 在里面" || bad "一-12 workflow 解析不过"
else
  echo "[NOTE] 一-12 本机没有 PyYAML, YAML 解析这一格未验(文本核对已覆盖接线; 不计入通过)"
fi

echo; echo "══ 二. ④ 脚本的静态边界 ══"
# 去注释的代码是二-1 / 二-2 / 二-3 / 二-4 / 二-8 的输入: 只有 grep -v 退出 0(确实选出了代码行)才可用; 先写出一截再非零退出不采信
grep -vE '^\s*#' "$R4" > "$T/code.txt"; CRC=$?
CIN=""; (( CRC == 0 )) || CIN="去注释的代码没取得(grep -v rc=$CRC)—— 不判"
if [[ -n "$CIN" ]]; then bad "二-1 $CIN"
elif ! qcnt -E '^ *r3_invoke( |$)' "$T/code.txt"; then bad "二-1 r3_invoke 计数查询失败($QWHY)"     # 只数调用点: 抽取清单里也有这个名字, 那不是调用
else n_inv="$QN"
  if ! qcnt -F 'bash "$R3_CLI"' "$T/code.txt"; then bad "二-1 直接调用计数查询失败($QWHY)"
  elif [[ "$n_inv" == 1 && "$QN" == 0 ]]; then ok "二-1 升级调用只有 ③ 原样的那一处(r3_invoke, 抽来用不改), ④ 自己不另写执行现役 CLI 的形态"
  else bad "二-1 r3_invoke $n_inv 处 / 直接调用 $QN 处"; fi
fi
if [[ -n "$CIN" ]]; then bad "二-2 $CIN"
elif ! qcnt -E '(^|[^a-z_-])(cmd_rollback|pdg +rollback|rollback +--dir)' "$T/code.txt"; then bad "二-2 回滚形态计数查询失败($QWHY)"
elif [[ "$QN" == 0 ]]; then ok "二-2 ④ 自己不调回滚: 恢复只能由产品在同一次 update 里自动做"
else bad "二-2 有 $QN 处自己发起回滚"; fi
M23="二-3 测试链接只被建立 / 核验 / 按登记删除, 没有任何从它恢复产品文件的形态"
if [[ -n "$CIN" ]]; then bad "二-3 $CIN"
else
  # 两级查询分开核(不靠管道的最终状态): 先找读链接的候选行, 再排除按登记删除的那几处; 每一级都分清找到 / 没找到 / 出错
  h23="$(grep -nE '(cp|mv|cat|install|tar|dd)[^|;&]*\$R4_LINK' "$T/code.txt" 2>/dev/null)"; r23=$?
  case "$r23" in
    1) ok "$M23";;
    0) grep -vqE 'r4_inject_remove|rm -f' <<<"$h23" 2>/dev/null; r23=$?
       case "$r23" in
         0) bad "二-3 有从测试链接读内容的形态 —— 那个链接不是备份, 不许用它恢复任何产品文件";;
         1) ok "$M23";;
         *) bad "二-3 第二级(排除按登记删除)查询出错(grep rc=$r23)—— 观测无效";;
       esac;;
    *) bad "二-3 第一级查询出错(grep rc=$r23)—— 已输出的部分不采信, 不说成没有";;
  esac
fi
if [[ -n "$CIN" ]]; then bad "二-4 $CIN"
elif ! qcnt -E '(^|[^a-z_])(install|cp|mv|tee|sed -i)[^|;&]*(\$R3_REPO|\$R3_CLI|\$R3_MODDIR|/usr/local/bin|/opt/privdns-gateway)' "$T/code.txt"; then bad "二-4 往现役目录写的计数查询失败($QWHY)"
elif [[ "$QN" == 0 ]]; then ok "二-4 ④ 不向现役仓库 / /usr/local/bin / 受管模块目录写文件"
else bad "二-4 有 $QN 处往现役目录写"; fi
for n in r4_seed r4_fs r4_fw r4_inject r4_pre r4_markers r4_rollback; do
  if ! qcnt "^# >>> PDG-EXTRACT-BEGIN $n\$" "$R4"; then bad "二-5 抽取标记 $n 的计数查询失败($QWHY)"; MARKBAD=1; continue; fi; b="$QN"
  if ! qcnt "^# <<< PDG-EXTRACT-END $n\$" "$R4"; then bad "二-5 抽取标记 $n 的计数查询失败($QWHY)"; MARKBAD=1; continue; fi; e="$QN"
  [[ "$b" == 1 && "$e" == 1 ]] || { bad "二-5 抽取标记 $n 不是唯一成对($b/$e)"; MARKBAD=1; }
done
[[ -z "${MARKBAD:-}" ]] && ok "二-5 ④ 的 7 段抽取标记都唯一成对"
n_case="$(awk '/^case "\$GRC" in$/{f=1} f; f&&/^esac$/{exit}' "$R4" | grep -cE '^  (10|11|12|13|14|15|16|17|18|\*)\) +bad ')"
[[ "$n_case" == 10 ]] && ok "二-6 主流程对 10–18 与未登记的门返回值都有具名分支(10 条), 全部停在调用之后的判据之前" \
  || bad "二-6 主流程的门返回值分支不全($n_case/10)"
gi="$(awk '/^r4_gated_invoke\(\)\{/{f=1} f; f&&/^}/{exit}' "$R4")"
o1="$(grep -nxF '  r3_dns_instrument || return 15' <<<"$gi" | cut -d: -f1)"
o2="$(grep -nxF '  r3_quiesce || return 16' <<<"$gi" | cut -d: -f1)"
o3="$(grep -nxF '  r3_runtime_gate || return 12' <<<"$gi" | cut -d: -f1)"
o4="$(grep -nxF '  r4_precapture || return 17' <<<"$gi" | cut -d: -f1)"
o5="$(grep -nxF '  r4_inject_stage || return 18' <<<"$gi" | cut -d: -f1)"
o6="$(grep -nxF '  r3_precapture || return 13' <<<"$gi" | cut -d: -f1)"
o7="$(grep -nE '^  r3_invoke \|\|' <<<"$gi" | cut -d: -f1)"
{ [[ -n "$o1$o2$o3$o4$o5$o6$o7" ]] && (( o1 < o2 && o2 < o3 && o3 < o4 && o4 < o5 && o5 < o6 && o6 < o7 )); } \
  && ok "二-7 门顺序: DNS 仪器 → 静置 → 运行态门 → ④ 前像采集 → 注入 → ③ 调用前观测 → 唯一调用(注入排在起界桩之前)" \
  || bad "二-7 门顺序不对(仪器=$o1 静置=$o2 运行态=$o3 采集=$o4 注入=$o5 采样=$o6 调用=$o7)"
if [[ -n "$CIN" ]]; then bad "二-8 $CIN"
elif ! qcnt -E '(^|[^a-z_])ln( |$)' "$T/code.txt"; then bad "二-8 ln 计数查询失败($QWHY)"
elif [[ "$QN" == 1 ]]; then ok "二-8 建硬链接的形态只有 1 处(在 r4_inject_create 里)"
else bad "二-8 ln 出现 $QN 处"; fi

echo; echo "══ 三. ④ 判据(受控输入) ══"
xfn(){ local n b e; for n in "$@"; do
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$R4" | cut -d: -f1)"; e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$R4" | cut -d: -f1)"
    [[ -n "$b" && -n "$e" ]] || return 1; sed -n "$((b+1)),$((e-1))p" "$R4"; done; }
xfn r4_fs r4_fw r4_inject r4_pre r4_markers r4_rollback > "$T/r4fns.sh" || { bad "三-0 抽取失败"; echo "通过 $pass, 失败 $nfail"; exit 1; }
# ③ 的读取器里 ④ 会用到的那几支, 按标记从 ③ 原样抽(不另写)
xr3(){ local n b e; for n in "$@"; do
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$R3" | cut -d: -f1)"; e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$R3" | cut -d: -f1)"
    [[ -n "$b" && -n "$e" ]] || return 1; sed -n "$((b+1)),$((e-1))p" "$R3"; done; }
xr3 r3_read > "$T/r3fns.sh" || { bad "三-0 ③ 读取器抽取失败"; echo "通过 $pass, 失败 $nfail"; exit 1; }
xr3 r3_dns > "$T/r3dns.sh" || { bad "三-0 ③ DNS 段抽取失败"; echo "通过 $pass, 失败 $nfail"; exit 1; }
bash -n "$T/r4fns.sh" && bash -n "$T/r3fns.sh" && bash -n "$T/r3dns.sh" && ok "三-0 按唯一成对标记抽出 ④ 的 6 段判据与 ③ 的读取器段、DNS 段(语法通过)" \
  || { bad "三-0 抽出的原文语法不过"; echo "通过 $pass, 失败 $nfail"; exit 1; }

mkroot(){   # $1=沙箱根 [$2=nftables.conf 内容]
  mkdir -p "$1/etc/mosdns/rules" "$1/etc/privdns-gateway" "$1/var/lib/pdg-accept4" "$1/opt/pdg-bot" "$1/usr/local/bin"
  # 335: 缺省按真实前像的形态 —— 已是 inet pdg、端口集里没有 5228(333: ② 已把它清掉)
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2"
  else printf 'table inet pdg {\n    chain input {\n        ip saddr 10.0.0.0/16 tcp dport { 53, 81, 853, 7893, 8445 } accept\n    }\n}\n'; fi > "$1/etc/nftables.conf"
  chmod 644 "$1/etc/nftables.conf"; printf 'ios\n' > "$1/etc/privdns-gateway/platform"
  printf 'x\n' > "$1/opt/pdg-bot/a.py"; printf 'y\n' > "$1/usr/local/bin/pdg"
  # 335: 冻结退役模板从受控替身仓库读(整支共用、各格只读); 格可以把 RETIRE_SHA / BRIDGE_SHA 换成别的形态
  # shellcheck disable=SC2034  # 由 source 进来的 ④ 原文按名字读取
  R3_OBJ="$T/robj" RETIRE_SHA="$TPL_GOOD" BRIDGE_SHA="$TPL_GOOD"
}
mktplrepo(){   # $1=目录 → 置 TPL_GOOD / TPL_COMMENT / TPL_NONE / TPL_MISSING(每种模板形态一个提交; 仓库改动一律经 e2e_git)
  local r="$1" f="$1/deploy/firewall/nftables-mihomo.conf"
  mkdir -p "$r/deploy/firewall" && git -C "$r" init -q || return 1
  _tc(){ e2e_git "$r" add -A && e2e_git "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1" >/dev/null && git -C "$r" rev-parse HEAD; }
  printf '%s\n' '# 80/443/5228-5230 在 prerouting 被改写为 7893(注释里的端口不算)' 'table inet pdg {' '    chain prerouting {' \
    '        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 } redirect to :7893' '    }' '}' > "$f" && TPL_GOOD="$(_tc good)" || return 1
  printf '%s\n' '# ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443, 5228-5230 } redirect to :7893' 'table inet pdg {' '    chain prerouting {' \
    '        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443 } redirect to :7893   # 以前是 tcp dport { 80, 443, 5228-5230 }' '    }' '}' > "$f" && TPL_COMMENT="$(_tc comment)" || return 1
  printf '%s\n' 'table inet pdg {' '    chain prerouting {' '        ip saddr __INTERNAL_CIDR__ tcp dport { 80, 443 } redirect to :7893' '    }' '}' > "$f" \
    && TPL_NONE="$(_tc none)" || return 1
  rm -f -- "$f" && TPL_MISSING="$(_tc missing)" || return 1
  [[ "$TPL_GOOD$TPL_COMMENT$TPL_NONE$TPL_MISSING" =~ ^([0-9a-f]{40}){4}$ ]]
}
E2E_ROOT="$ROOT" mktplrepo "$T/robj" || { bad "三-0 冻结退役模板的受控替身仓库建不出来"; echo "通过 $pass, 失败 $nfail"; exit 1; }
cell(){   # $1=格名 $2=代码 → 输出进 $T/out-$1(子壳里跑, 装载被测原文 + 受控依赖)
  ( set +u
    SB="$T/sb-$1"; mkdir -p "$SB"; mkroot "$SB"
    PDG_LATE_FAIL_ROOT="$SB"; export PDG_LATE_FAIL_ROOT
    R3_TMP="$T/tmp-$1"; mkdir -p "$R3_TMP"; EVID="$T/evid-$1"; mkdir -p "$EVID"
    # shellcheck disable=SC2034  # 由 source 进来的 ④ 原文按名字读取(脚本里 R4_TMP 与 R3_TMP 都设)
    R4_TMP="$R3_TMP"
    # 这几个由 source 进来的被测原文按名字读取(ShellCheck 静态看不到这种使用)
    # shellcheck disable=SC2034
    { R3_ETC="$SB/etc/privdns-gateway"; SNAPROOT="$SB/backups"; mkdir -p "$SNAPROOT"
      R3_LOG="$T/log-$1"; STUB_CALLS="$T/calls-$1"; : > "$STUB_CALLS"; HIT="$T/hit-$1"; }
    ok(){ echo "VOK $1"; }; bad(){ echo "VBAD $1"; }; note(){ echo "VNOTE $1"; }
    # shellcheck source=/dev/null
    source "$T/r3fns.sh"; source "$T/r4fns.sh"
    eval "$2" && echo "@@CELL_END" ) > "$T/out-$1" 2>&1; printf '%s\n' "$?" > "$T/rc-$1"
}
cell_rc(){   # $1=格名 → 0 取得(CELL_RC=子壳原始退出码) / 2 观测无效(CELL_WHY): 退出码文件读不了或内容不是退出码, 已输出的内容不采信
  local v r; CELL_RC=""
  v="$(cat -- "$T/rc-$1" 2>/dev/null)"; r=$?
  (( r == 0 )) || { CELL_WHY="退出码文件读不了(cat rc=$r)"; return 2; }
  [[ "$v" =~ ^[0-9]{1,3}$ ]] || { CELL_WHY="退出码文件内容不是退出码([${v:0:20}])"; return 2; }
  CELL_RC="$v"
}
cell_ok(){   # $1=格名 → 0 执行有效 / 1 子壳异常(CELL_WHY) / 2 观测无效(CELL_WHY)。子壳退出码、两次读取、收尾标记分别核, 不重跑格来补证
  local l r
  cell_rc "$1" || return 2
  [[ "$CELL_RC" == 0 ]] || { CELL_WHY="子壳返回 $CELL_RC"; return 1; }
  l="$(tail -n 1 -- "$T/out-$1" 2>/dev/null)"; r=$?
  (( r == 0 )) || { CELL_WHY="末行读不了(tail rc=$r)"; return 2; }
  [[ "$l" == "@@CELL_END" ]] || { CELL_WHY="子壳返回 0 但收尾标记不是末行(末行 [${l:0:40}])"; return 1; }
}
inval(){   # 有效 ⇒ 不打印; 子壳异常 ⇒「执行无效(…)」; 读取失败 ⇒「观测无效(…)」—— 两者分开说, 都算这一格不成立
  local r; cell_ok "$1"; r=$?
  case "$r" in 0) ;; 1) printf '执行无效(%s)' "$CELL_WHY";; *) printf '观测无效(%s)' "$CELL_WHY";; esac
}
calls(){ local n rc; [[ -f "$T/calls-$1" && -r "$T/calls-$1" ]] || { printf '读不到'; return 2; }; n="$(grep -c . "$T/calls-$1" 2>/dev/null)"; rc=$?; (( rc <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]] || { printf '读不到'; return 2; }; printf '%s' "$n"; }   # 桩自己的调用记录 → 0 取得(条数) / 2 读不到(不补 0)
absent(){ grep -qF -- "$1" "$2" 2>/dev/null; (( $? == 1 )); }   # 否定查询: 只有「确实没有」(rc 1)才算没有; grep 出错不当成没有
hit(){ [[ -s "$T/hit-$1" ]]; }                                    # 注入替身自己记的命中

# ── 三-A 注入原语(沙箱里驱动判据原文)──────────────────────────────────────────
inj(){   # $1=格名 $2=期望 create 返回码 $3=说明 $4=注入前的布置 $5=期望原因片段(可空)
  cell "$1" "$4"$'\n''r4_inject_create; echo "CRC=$?"; echo "WHY=$R3_WHY"; echo "INJ=[$R4_INJ]"; echo "NLINK=$(stat -c %h "$R4_TARGET" 2>/dev/null)"'
  local why; why="$(inval "$1")"
  grep -qx "CRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'CRC=[0-9]*' "$T/out-$1"), 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺原因「$5」"
  if [[ "$2" != 0 ]]; then grep -qxF 'INJ=[]' "$T/out-$1" || why="${why:+$why; }失败却留了登记"; fi
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(tr '\n' ' ' < "$T/out-$1" | head -c 220)"
}
inj a-ok  0 "三-A1 正常: 普通文件、nlink=1、同设备、位置空 ⇒ 建立成立并登记" ':' ''
cell_ok a-ok && grep -qx 'NLINK=2' "$T/out-a-ok" && ok "三-A1b 建立后目标 nlink=2(两名同 inode 由判据自己核过)" || bad "三-A1b 建立后 nlink 不是 2"
cell a-plat 'printf "android\n" > "$R3_ETC/platform"; r4_trigger_ready; echo "TRC=$?"; echo "TWHY=$R3_WHY"'
cell_ok a-plat && grep -qx 'TRC=1' "$T/out-a-plat" && grep -qF 'GMS 清理只在 ios 上动手' "$T/out-a-plat" \
  && ok "三-A2 平台不是 ios ⇒ 触发前提不成立(GMS 清理第一行就返回 0, 守卫轮不到)" \
  || bad "三-A2 触发前提的原因不对: $(inval a-plat) $(grep TWHY "$T/out-a-plat" | head -c 150)"
cell a-5228 '! grep -q 5228 "$R4_TARGET" || exit 7; r4_trigger_ready; echo "TRC=$?"; echo "TWHY=$R3_WHY"'
cell_ok a-5228 && grep -qx 'TRC=0' "$T/out-a-5228" \
  && ok "三-A3 调用前现役文件没有 5228(真实前像形态), 冻结退役模板的有效规则有 ⇒ 触发前提成立(5228 由更新中途的模板同步带回)" \
  || bad "三-A3 新前提有效却没进入: $(inval a-5228) $(tr '\n' ' ' < "$T/out-a-5228" | head -c 200)"
cell a-resc 'printf "PDG_RESCUE_BIND=10.1.0.5\n" > "$R3_ETC/profile.env"; r4_trigger_ready; echo "TRC=$?"; echo "TWHY=$R3_WHY"'
cell_ok a-resc && grep -qx 'TRC=1' "$T/out-a-resc" && grep -qF '救援平面' "$T/out-a-resc" \
  && ok "三-A4 救援平面会被启用 ⇒ 触发前提不成立(它的 mv -f 会换掉目标 inode)" || bad "三-A4 没被拒 $(inval a-resc)"
inj a-nlink 1 "三-A5 目标 nlink 已经不是 1 ⇒ 不在这种现场上注入" 'ln "$R4_TARGET" "$SB/other.link"' 'nlink 是 2'
inj a-busy  1 "三-A6 注入位置已被占 ⇒ 不建立" 'echo occupant > "$R4_LINK"' '已经被占'
inj a-insnap 1 "三-A7 注入位置落在快照候选路径里 ⇒ 不建立(否则会被打进快照又被还原回来)" 'R4_LINK="$SB/etc/privdns-gateway/x.link"' '落在快照候选路径'
cell a-rm-ok 'r4_inject_create; echo "CRC=$?"; r4_inject_remove; echo "RRC=$?"; echo "LEFT=$([[ -e "$R4_LINK" ]] && echo 在 || echo 没了)"; echo "NLINK=$(stat -c %h "$R4_TARGET" 2>/dev/null)"'
cell_ok a-rm-ok && grep -qx 'RRC=0' "$T/out-a-rm-ok" && grep -qx 'LEFT=没了' "$T/out-a-rm-ok" && grep -qx 'NLINK=1' "$T/out-a-rm-ok" \
  && ok "三-A8 按登记身份撤除 ⇒ 链接消失、目标 nlink 回到 1" || bad "三-A8 撤除不对: $(inval a-rm-ok) $(tr '\n' ' ' < "$T/out-a-rm-ok" | head -c 200)"
cell a-rm-id 'r4_inject_create; rm -f "$R4_LINK"; echo other > "$R4_LINK"; r4_inject_remove; echo "RRC=$?"; echo "LEFT=$(cat "$R4_LINK" 2>/dev/null)"'
cell_ok a-rm-id && grep -qx 'RRC=2' "$T/out-a-rm-id" && grep -qx 'LEFT=other' "$T/out-a-rm-id" && grep -qF '没有删' "$T/out-a-rm-id" \
  && ok "三-A9 链接身份变了 ⇒ **不误删**, 具名报告, 那个文件原样留着" || bad "三-A9 身份不符时的处置不对: $(inval a-rm-id) $(tr '\n' ' ' < "$T/out-a-rm-id" | head -c 220)"
cell a-rm-gone 'r4_inject_create; rm -f "$R4_LINK"; r4_inject_remove; echo "RRC=$?"'
cell_ok a-rm-gone && grep -qx 'RRC=1' "$T/out-a-rm-gone" && grep -qF '已经不在' "$T/out-a-rm-gone" \
  && ok "三-A10 链接被别的东西删掉 ⇒ 如实说「本来就不在」, 不谎报「已清理」" || bad "三-A10 处置不对 $(inval a-rm-gone)"
cell a-rm-none 'r4_inject_remove; echo "RRC=$?"'
cell_ok a-rm-none && grep -qx 'RRC=1' "$T/out-a-rm-none" && grep -qF '没有登记过注入' "$T/out-a-rm-none" \
  && ok "三-A11 从没建立过 ⇒ 善后不动任何东西" || bad "三-A11 处置不对 $(inval a-rm-none)"

# ── 三-B 运行中的防火墙 ───────────────────────────────────────────────────────
fw(){   # $1=格名 $2=nft 替身 $3=期望返回码 $4=说明 $5=期望原因片段(可空)
  cell "$1" "$2"$'\n''r4_fw_live; echo "FRC=$?"; echo "FWHY=$R3_WHY"; echo "LEN=${#R3_VAL}"'
  local why; why="$(inval "$1")"
  grep -qx "FRC=$3" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'FRC=[0-9]*' "$T/out-$1"), 期望 $3"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺原因「$5」"
  [[ "$3" == 0 ]] || grep -qx 'LEN=0' "$T/out-$1" || why="${why:+$why; }失败却留了值"
  [[ -z "$why" ]] && ok "$4" || bad "$4: $why"
}
fw b-ok   'nft(){ printf "table inet pdg {\n  chain input {\n  }\n}\n"; }' 0 "三-B1 正常: 连取两次逐字相同 ⇒ 取得原文" ''
fw b-rc   'nft(){ echo "部分输出"; return 1; }' 2 "三-B2 nft 退出非零 ⇒ 观测无效, 它打印的内容不采信" '退出 1'
fw b-empty 'nft(){ return 0; }' 2 "三-B3 退出 0 但输出为空 ⇒ 观测无效(不当成「表是空的」)" '输出为空'
fw b-flap 'nft(){ local c="$R3_TMP/nftn"; local n=0; [[ -f "$c" ]] && n="$(cat "$c")"; n=$((n+1)); echo "$n" > "$c"; echo "第 $n 次"; }' 2 "三-B4 连取两次不一致 ⇒ 判观测无效, 不去滤掉差异凑相等" '连取两次不一致'

# ── 三-C 有序标记(退役成功 → 命中 → 迁移失败 → 回滚本次快照)──────────────────
mklog(){   # $1=文件 $2..=按顺序写进去的行
  local f="$1"; shift; : > "$f"; printf '%s\n' "$@" >> "$f"
}
L_RET='  ✅ WLOC 位置改写及其专属 MITM 执行能力已退役(服务已停, 专属劫持与路由已撤)。'
L_MIG='迁移(__migrate)失败, 回滚到更新前快照…'
L_M0='防火墙按模板重建(同步模板改动; 你在 nft-input.d/ 里的规则不受影响)…'
mk(){   # $1=格名 $2=期望返回码 $3=说明 $4=日志模板(\n 分行, @GMS@ = 命中句) $5=期望片段
  # shellcheck disable=SC2034  # 经父壳变量传进格(格是子壳, 看得见), 在格代码里展开
  TPL="$4"
  cell "$1" 'R4_SNAP_NEW=20260101-000000
G="  iOS GMS 清理: $R4_TARGET 是硬链接(nlink=2), 改它会波及另一个名字 → 未改动任何文件"
printf "%b\n" "${TPL//@GMS@/$G}" > "$R3_LOG"'$'\n''r4_markers; echo "MRC=$?"'
  local why; why="$(inval "$1")"
  grep -qx "MRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'MRC=[0-9]*' "$T/out-$1"), 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^V(OK|BAD)' "$T/out-$1" | tr '\n' '|' | head -c 260)"
}
HEALTHY="$L_M0\n$L_RET\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …"
mk c-ok   0 "三-C1 健康: 五个标记(M0–M4)齐全且有序 ⇒ 成立" "$HEALTHY" '顺序成立'
mk c-noret 1 "三-C2 没有退役成功句 ⇒ 不成立(不拿'最后恢复了'倒推退役发生过)" "$L_M0\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …" 'M1 没有本次 WLOC 退役成功的直接证据'
mk c-nogms 1 "三-C3 没命中 GMS 形态守卫 ⇒ 不成立" "$L_M0\n$L_RET\n  某别的迁移炸了\n$L_MIG\n回滚到 20260101-000000 …" 'M2 故障没有命中'
mk c-order 1 "三-C4 顺序不对(命中排在退役成功之前)⇒ 不成立" "$L_M0\n@GMS@\n$L_RET\n$L_MIG\n回滚到 20260101-000000 …" '顺序不成立'
mk c-dup   1 "三-C5 退役成功句出现两次 ⇒ 不成立(应恰 1 次)" "$L_M0\n$L_RET\n$L_RET\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …" '应恰 1 次'
mk c-upd   1 "三-C6 产品自报「✅ 已更新。」⇒ 本次没有按预期失败, 不是有效 ④" "$HEALTHY\n    ✅ 已更新。" '没有**按预期失败'
mk c-other 1 "三-C7 还扫到别的迁移的具名失败文案 ⇒ 失败来源不止一处, 不是有效 ④" "$HEALTHY\n  ❌ pdg-probe81 未能启用 —— 链路诊断的 HTTP 会话入口不可用。" '还扫到别的迁移失败文案'
mk c-snap  1 "三-C8 回滚点名的不是本次新建的快照 ⇒ 不成立" "$L_M0\n$L_RET\n@GMS@\n$L_MIG\n回滚到 20251231-235959 …" 'M4 日志里没有'
# 335: M0「模板重建」只是写入前提示; 缺失 / 重复 / 乱序都不成立, 有 M0 没有 M2 也不能判故障命中
mk c-m0miss  1 "三-C10 没有 M0「模板重建」⇒ 不成立" "$L_RET\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …" 'M0 没有「模板重建」这一句'
mk c-m0dup   1 "三-C11 M0 出现两次 ⇒ 不成立(应恰 1 次)" "$L_M0\n$L_M0\n$L_RET\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …" '应恰 1 次'
mk c-m0order 1 "三-C12 M0 排在退役成功之后 ⇒ 顺序不成立" "$L_RET\n$L_M0\n@GMS@\n$L_MIG\n回滚到 20260101-000000 …" '顺序不成立'
mk c-m0only  1 "三-C13 有 M0 但没有 M2(模板同步写了, 守卫没拒)⇒ 不能判故障命中" "$L_M0\n$L_RET\n$L_MIG\n回滚到 20260101-000000 …" 'M2 故障没有命中'
cell c-read 'R4_SNAP_NEW=20260101-000000; R3_LOG="$T/没有这个文件"; r4_markers; echo "MRC=$?"'
cell_ok c-read && grep -qx 'MRC=1' "$T/out-c-read" && grep -qF '日志读不了' "$T/out-c-read" \
  && ok "三-C9 升级日志读不了 ⇒ 观测无效, 不消费半截结果" || bad "三-C9 读取失败没被具名: $(inval c-read) $(tr '\n' ' ' < "$T/out-c-read" | head -c 200)"

# ── 三-D 回滚结局(产品自述)──────────────────────────────────────────────────
rb(){   # $1=格名 $2=期望返回码 $3=说明 $4=日志内容 $5=期望片段
  # shellcheck disable=SC2034  # 同上: 在格代码里展开
  TPL="$4"
  cell "$1" 'printf "%b\n" "$TPL" > "$R3_LOG"'$'\n''r4_rollback_outcome; echo "RRC=$?"'
  local why; why="$(inval "$1")"
  grep -qx "RRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'RRC=[0-9]*' "$T/out-$1"), 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^V(OK|BAD)' "$T/out-$1" | head -c 200)"
}
rb d-ok  0 "三-D1 健康: 成功句恰 1 次、无未完全回滚、无 ❌" '✅ 已回滚并重启服务' '恰 1 次'
rb d-miss 1 "三-D2 update 非零但**没有**回滚成功句 ⇒ 不能通过(非零不代表回滚成功)" '迁移(__migrate)失败, 回滚到更新前快照…' '出现 0 次'
rb d-part 1 "三-D3 产品自报未完全回滚 ⇒ 不能通过" '⚠️ 已回滚配置/服务, 但以下项未能恢复(未完全回滚): 内核收敛' '产品自报未完全回滚'
rb d-err  1 "三-D4 回滚阶段有 ❌(落盘失败)⇒ 不能通过" '❌ 快照落盘失败, 系统可能已部分恢复, 请立即检查' '回滚阶段有 ❌'
rb d-dup  1 "三-D5 成功句出现两次 ⇒ 不能通过" '✅ 已回滚并重启服务\n✅ 已回滚并重启服务' '出现 2 次'

# ── 三-E 本次快照与 svcstate 绑定 ─────────────────────────────────────────────
sn(){   # $1=格名 $2=期望返回码 $3=说明 $4=布置 $5=期望片段
  cell "$1" 'R4_SNAP_BEFORE="old-1"; mkdir -p "$SNAPROOT/old-1"'$'\n'"$4"$'\n''r4_snapshot_verdict; echo "SRC=$?"; echo "NEW=[$R4_SNAP_NEW]"'
  local why; why="$(inval "$1")"
  grep -qx "SRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'SRC=[0-9]*' "$T/out-$1"), 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^V(OK|BAD)' "$T/out-$1" | head -c 220)"
}
svst(){   # $1=写进 snap_dir 的值 $2=写进 snap_id 的值 → 与产品 _pdg_save_svcstate 同形的头部 + 一行 unit + 尾行
  printf '#pdg-svcstate\t1\nboot_id\tb0\nholder_pid\t1\nholder_start\t1\nsnap_dir\t%s\nsnap_id\t%s\ncreated_at\t2026-01-01T00:00:00Z\nunit\tmosdns\tenabled\tactive\trunning\t\nend\t1\n' "$1" "$2"
}
SNAPD='d="$SNAPROOT/20260101-000000"; mkdir -p "$d"; echo z > "$d/snap.tar.gz"; sid="$(stat -c %d:%i:%s:%Y -- "$d/snap.tar.gz")"'
NEWSNAP="$SNAPD"'; svst "$d" "$sid" > "$d/svcstate.tsv"'
sn e-ok 0 "三-E1 健康: 新增恰 1 个, 含 snap.tar.gz 与 svcstate.tsv, 前像按产品格式指向这一份(snap_dir 与 snap_id 都对得上)" "$NEWSNAP" 'snap_id 与这份 snap.tar.gz 对得上'
sn e-none 1 "三-E2 没有新增快照 ⇒ 不成立(产品这次没建快照)" ':' '不是恰 1 个'
sn e-two 1 "三-E3 新增两个 ⇒ 不成立(说不清回滚用的是哪一份)" "$NEWSNAP"$'\n''mkdir -p "$SNAPROOT/20260102-000000"' '不是恰 1 个'
sn e-lack 1 "三-E4 新快照缺 svcstate.tsv ⇒ 不成立" 'd="$SNAPROOT/20260101-000000"; mkdir -p "$d"; echo z > "$d/snap.tar.gz"' '缺件'
sn e-bind 1 "三-E5 svcstate 记的 snap_dir 指向**别的**快照 ⇒ 不成立(错误快照)" "$SNAPD"'; svst "$SNAPROOT/old-1" "$sid" > "$d/svcstate.tsv"' 'snap_dir 应恰 1 行且就是这一份'
sn e-sid 1 "三-E6 snap_id 与这份 snap.tar.gz 对不上 ⇒ 不成立(记录没钉在这一份上)" "$SNAPD"'; svst "$d" 0:0:0:0 > "$d/svcstate.tsv"' 'snap_id 应恰 1 行且等于'
sn e-fmt 1 "三-E7 snap_dir 写成 key=value(产品不这么写)⇒ 不成立" "$SNAPD"'; printf "#pdg-svcstate\t1\nsnap_dir=%s\nsnap_id\t%s\n" "$d" "$sid" > "$d/svcstate.tsv"' '实得 0 行'
sn e-hdr 1 "三-E8 没有产品的格式标记首行 ⇒ 不成立" "$SNAPD"'; svst "$d" "$sid" | tail -n +2 > "$d/svcstate.tsv"' '首行不是产品的格式标记'
sn e-dup 1 "三-E9 snap_dir 出现两行 ⇒ 不成立(应恰 1 行)" "$SNAPD"'; { svst "$d" "$sid"; printf "snap_dir\t%s\n" "$d"; } > "$d/svcstate.tsv"' '实得 2 行'

# ── 三-F 文件清单比对 ─────────────────────────────────────────────────────────
fs(){   # $1=格名 $2=期望返回码 $3=说明 $4=两次采集之间做的事 $5=期望片段
  cell "$1" 'r4_fs_manifest "$R3_TMP/a" ; echo "A=$?"'$'\n'"$4"$'\n''r4_fs_manifest "$R3_TMP/b"; echo "B=$?"; r4_fs_diff "$R3_TMP/a" "$R3_TMP/b"; echo "DRC=$?"; echo "DWHY=$R3_WHY"'
  local why; why="$(inval "$1")"
  grep -qx "DRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'DRC=[0-9]*' "$T/out-$1"), 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(A|B|DRC|DWHY)=' "$T/out-$1" | tr '\n' ' ' | head -c 240)"
}
fs f-same 0 "三-F1 什么都没动 ⇒ 前后相同(只表述为前后相同, 不表述为全程未写)" ':' ''
fs f-chg  1 "三-F2 文件内容变了 ⇒ 点名报出来" 'echo changed > "$SB/opt/pdg-bot/a.py"' '内容或属性变了'
fs f-mode 1 "三-F3 只有 mode 变了 ⇒ 同样点名(属性也算没恢复)" 'chmod 600 "$SB/opt/pdg-bot/a.py"' '内容或属性变了'
fs f-gone 1 "三-F4 文件消失 ⇒ 点名报出来" 'rm -f "$SB/opt/pdg-bot/a.py"' '消失'
fs f-new  1 "三-F5 新增了清单之外的文件 ⇒ 不自动接受" 'echo n > "$SB/opt/pdg-bot/新来的.py"' '新增'
fs f-allow 0 "三-F6 新增的是事先登记的允许项(pre-tplsync 备份 / __pycache__)⇒ 放行" 'echo b > "$SB/etc/nftables.conf.pre-tplsync"; mkdir -p "$SB/opt/pdg-bot/__pycache__"; echo c > "$SB/opt/pdg-bot/__pycache__/a.pyc"' ''
cell f-read 'r4_fs_manifest "$R3_TMP/a"; chmod 000 "$SB/opt/pdg-bot/a.py"; r4_fs_manifest "$R3_TMP/b"; echo "B=$?"; echo "BWHY=$R3_WHY"'
if cell_ok f-read && grep -qx 'B=2' "$T/out-f-read" && grep -qF '摘要查询失败' "$T/out-f-read"; then
  ok "三-F7 某个文件的摘要读不了 ⇒ 整份清单判观测无效(不写半份, 也不把它当成「这个文件不在」)"
elif [[ "$(id -u)" == 0 ]] && cell_ok f-read; then
  echo "[NOTE] 三-F7 以 root 跑, chmod 000 挡不住读取 —— 这一格未验(不计入通过)"
else bad "三-F7 读取失败没被具名: $(inval f-read) $(tr '\n' ' ' < "$T/out-f-read" | head -c 200)"; fi

# ── 三-G 零调用矩阵: 任一门不成立, 桩 CLI 必须 0 次 ───────────────────────────
# ③ 的各道门在这里用受控替身顶替(它们自己由 ③ 的契约负责); 被测的是 ④ 把它们串起来的顺序,
# 以及"不成立就不调用"。桩 CLI 的调用由它**自己**记账, 不看 ④ 自报的计数。
GATES='r3_real2_gate(){ R3_WHY="② 汇总 68/0"; return ${G_R2:-0}; }
r3_bridge_identity_gate(){ return ${G_ID:-0}; }
r3_dns_instrument(){ return ${G_DNS:-0}; }
r3_quiesce(){ return ${G_Q:-0}; }
r3_runtime_gate(){ return ${G_RT:-0}; }
r3_precapture(){ echo "  E ③ 调用前观测"; return ${G_PRE:-0}; }
r3_lsdir(){ R3_VAL="old-1"; R3_NOTE=""; return ${G_LS:-0}; }
r3_copy_record(){ cp -- "$1" "$2" 2>/dev/null || { R3_WHY="复制失败"; return 2; }; }
nft(){ printf "table inet pdg {\n}\n"; }
r3_invoke(){ printf "update --to v9.9.9-retire-TEST\n" >> "$STUB_CALLS"; R3_WRAP_RC=0; return 0; }
'
g(){   # $1=格名 $2=期望 GRC $3=说明 $4=注入 $5=期望片段(可空) [$6=hit: 注入必须命中]
  cell "$1" "$GATES"$'\n'"$4"$'\n''r4_gated_invoke; echo "GRC=$?"'
  local why c crc; why="$(inval "$1")"; c="$(calls "$1")"; crc=$?
  grep -qx "GRC=$2" "$T/out-$1" || why="${why:+$why; }返回 $(grep -o 'GRC=[0-9]*' "$T/out-$1"), 期望 $2"
  if (( crc != 0 )); then why="${why:+$why; }桩的调用记录读不到(不补 0)"
  elif [[ "$2" == 0 ]]; then [[ "$c" == 1 ]] || why="${why:+$why; }桩 CLI 记录 $c 次(应 1)"
  else [[ "$c" == 0 ]] || why="${why:+$why; }桩记录 $c 次(应 0)"; fi
  [[ "${6:-}" != hit ]] || hit "$1" || why="${why:+$why; }注入没命中"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "$why" ]] && ok "$3 ⇒ GRC=$2, 桩 CLI $c 次" || bad "$3: $why"
}
g g-ok 0  "三-G1 健康: 门全过、前像采集与注入成立 ⇒ 调用恰 1 次" ':' '注入已建立并核过'
g g-r2 10 "三-G2 ② 结果门不成立 ⇒ 不调用" 'G_R2=1' ''
g g-id 11 "三-G3 桥接身份门不成立 ⇒ 不调用" 'G_ID=1' ''
g g-dns 15 "三-G4 DNS 仪器不成立 ⇒ 不调用" 'G_DNS=1' ''
g g-q  16 "三-G5 准备阶段静置不成立 ⇒ 不调用" 'G_Q=1' ''
g g-rt 12 "三-G6 运行态 / WLOC 前像门不成立 ⇒ 不调用" 'G_RT=1' ''
g g-fs 17 "三-G7 ④ 的前像清单取不到 ⇒ 不调用" 'r4_fs_manifest(){ R3_WHY="清单取不到"; return 2; }' '前像文件清单没取得'
g g-fw 17 "三-G8 运行中的防火墙读不到 ⇒ 不调用" 'nft(){ return 1; }' '运行中防火墙没取得'
g g-trig 0 "三-G9 调用前现役文件没有 5228、冻结退役模板有效 ⇒ 进入注入, 调用恰 1 次" '! grep -q 5228 "$SB/etc/nftables.conf" || exit 7' '注入已建立并核过'
g g-inj 18 "三-G10 注入建不起来(位置被占)⇒ 不调用" 'echo occupant > "$SB/var/lib/pdg-accept4/nftables.conf.link"' '注入未建立'
g g-pre 13 "三-G11 ③ 的调用前观测没取全 ⇒ 不调用" 'G_PRE=1' ''
g g-cnt 14 "三-G12 计数或退出码留档不可用 ⇒ 不调用" 'r3_invoke(){ R3_WHY="退出码留档准备不了"; return 2; }' '调用前停止'
# 注入排在 ③ 的调用前观测之前 —— 起界桩之后不再动现场
cell g-order2 "$GATES"$'\n''_seq="$T/seq-g-order2"; : > "$_seq"
eval "_orig_create$(declare -f r4_inject_create | tail -n +1 | sed "1s/^r4_inject_create//")"
r4_inject_create(){ echo inject >> "$_seq"; _orig_create; }
r3_precapture(){ echo precapture >> "$_seq"; return 0; }'$'\n''r4_gated_invoke >/dev/null 2>&1; echo "SEQ=$(tr "\n" "," < "$_seq")"'
cell_ok g-order2 && grep -qx 'SEQ=inject,precapture,' "$T/out-g-order2" \
  && ok "三-G13 注入排在 ③ 的调用前观测(以 journal 起界桩收尾)之前 —— 起界桩之后不再动现场" \
  || bad "三-G13 顺序不对: $(inval g-order2) $(grep '^SEQ=' "$T/out-g-order2")"

# ── 三-G 续(330): 调用前提的**观测**失败同样阻断 —— 桩自己记账, 0 次 ─────────────────────
# 替身只包在被测查询外面: 先照常给出真实结果, 再以非零退出(或查询自身出错); 命中由替身自己写进 $HIT。
GERR='grep(){ if [[ "$*" == *"$P"* ]]; then echo hit >> "$HIT"; return 2; fi; command grep "$@"; }'
LNREC='ln(){ echo "ln $*" >> "$STUB_CALLS"; command ln "$@"; }'
DEVFAIL='stat(){ if [[ "$*" == "-c %d -- "*pdg-accept4 ]]; then command stat -c %d -- "$R4_TARGET"; echo hit >> "$HIT"; return 1; fi; command stat "$@"; }'
VERFAIL='N="$R3_TMP/statn"; stat(){ if [[ "$*" == "-c %d:%i:%h -- $R4_TARGET" ]]; then local c=0; [[ -f "$N" ]] && c="$(cat "$N")"; c=$((c+1)); echo "$c" > "$N"; if (( c == 2 )); then command stat "$@"; echo hit >> "$HIT"; return 1; fi; fi; command stat "$@"; }'
g g-qtpl 18 "三-G14 模板触发条件(5228 端口集)的查询自身出错 ⇒ 前提观测无效, 不注入、不调用" "P='[^}]*5228'; $GERR" '模板触发条件查询失败' hit
g g-qresc 18 "三-G15 救援标记的查询自身出错 ⇒ 不当成「没有标记」, 不注入、不调用" "P=pdg-rescue; $GERR" '注入前提观测无效' hit
g g-qdev 18 "三-G16 注入目录设备号先输出「同设备」再失败 ⇒ 不建链接(ln 替身 0 次)、不调用" "$LNREC; $DEVFAIL" '注入目录设备号查询失败' hit
g g-qver 18 "三-G17 建完核验的查询先输出「nlink=2」再失败 ⇒ 按登记善后、不调用" "$VERFAIL" '建完核验不过或核验查询失败' hit
cell_ok g-qver && grep -qF '已按登记善后' "$T/out-g-qver" && [[ ! -e "$T/sb-g-qver/var/lib/pdg-accept4/nftables.conf.link" ]] \
  && ok "三-G17b 核验查询失败后链接已按登记删掉(不留在盘上)" || bad "三-G17b 核验查询失败后的善后不对"
if [[ "$(id -u)" == 0 ]]; then echo "[NOTE] 三-G18 以 root 跑, chmod 000 挡不住读取 —— 这一格未验(不计入通过)"
else g g-qpe 17 "三-G18 profile.env 在却读不了 ⇒ 调用前的前像清单先判观测无效(轮不到注入前提), 不注入、不调用" 'printf "PDG_RESCUE_BIND=10.1.0.5\n" > "$R3_ETC/profile.env"; chmod 000 "$R3_ETC/profile.env"; [[ -r "$R3_ETC/profile.env" ]] || echo hit >> "$HIT"' '前像文件清单没取得' hit; fi

# ── 三-H 观测失败不消费(330): 文件属性 / 摘要 / 链接身份 / 排序 / 否定查询 / 行号 / 快照绑定 ──────────
ob(){   # $1=格名 $2=期望 XRC $3=说明 $4=格代码(须打印 XRC=) $5=期望原因片段 [$6=不许出现的片段] —— 注入必须命中
  cell "$1" "$4"
  local why; why="$(inval "$1")"
  hit "$1" || why="${why:+$why; }注入没命中"
  grep -qx "XRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $2"
  grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺原因「$5」"
  [[ -z "${6:-}" ]] || absent "$6" "$T/out-$1" || why="${why:+$why; }出现了「$6」(或查不了)"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(XRC|XWHY|VBAD|LEFT|INJ)' "$T/out-$1" | tr '\n' ' ' | head -c 240)"
}
AFTER='stat(){ local o r; o="$(command stat "$@")"; r=$?; printf "%s\n" "$o"; if [[ "$*" == *"$K"* ]]; then echo hit >> "$HIT"; return 1; fi; return $r; }'
ONE='r4_fs_one "$SB/opt/pdg-bot/a.py" >/dev/null; echo "XRC=$?"; echo "XWHY=$R3_WHY"'
ob h-mode 2 "三-H1 mode 查询先输出合法值再退出 1 ⇒ 不消费, 这一行判观测无效" "K=%a; $AFTER"$'\n'"$ONE" 'mode 查询失败(stat rc=1'
ob h-own  2 "三-H2 属主查询先输出合法值再退出 1 ⇒ 不消费" "K=%u:%g; $AFTER"$'\n'"$ONE" '属主查询失败(stat rc=1'
ob h-sha  2 "三-H3 sha256sum 先输出合法摘要再退出 1 ⇒ 不消费" 'sha256sum(){ command sha256sum "$@"; echo hit >> "$HIT"; return 1; }'$'\n'"$ONE" '摘要查询失败(sha256sum rc=1)'
ob h-link 2 "三-H4 readlink 先输出链接目标再退出 1 ⇒ 不消费" 'ln -s a.py "$SB/opt/pdg-bot/l.py"; readlink(){ command readlink "$@"; echo hit >> "$HIT"; return 1; }'$'\n''r4_fs_one "$SB/opt/pdg-bot/l.py" >/dev/null; echo "XRC=$?"; echo "XWHY=$R3_WHY"' '链接目标查询失败(readlink rc=1)'
ob h-sort 2 "三-H5 调用后一侧按路径排序写出结果后失败(且内容确实变了)⇒ 比不了, 不是「没有差异」" 'r4_fs_manifest "$R3_TMP/a" >/dev/null; echo changed > "$SB/opt/pdg-bot/a.py"; r4_fs_manifest "$R3_TMP/b" >/dev/null
sort(){ local last="${!#}"; if [[ "$*" == *-k5* && "$last" == */b ]]; then command sort "$@"; echo hit >> "$HIT"; return 2; fi; command sort "$@"; }'$'\n''r4_fs_diff "$R3_TMP/a" "$R3_TMP/b"; echo "XRC=$?"; echo "XWHY=$R3_WHY"' '调用后清单按路径排序失败(sort rc=2)'
TRIG='r4_trigger_ready; echo "XRC=$?"; echo "XWHY=$R3_WHY"'
ob h-resc 2 "三-H6 救援标记的查询自身出错 ⇒ 前提观测无效(不当成「没有标记」)" "P=pdg-rescue; $GERR"$'\n'"$TRIG" '救援标记查询失败'
ob h-tplq 2 "三-H7 模板触发条件(5228 端口集)的查询自身出错 ⇒ 前提观测无效, 不说成「没有 5228 端口集」" "P='[^}]*5228'; $GERR"$'\n'"$TRIG" '模板触发条件查询失败' '没有 5228 端口集'
if [[ "$(id -u)" == 0 ]]; then echo "[NOTE] 三-H8 以 root 跑, chmod 000 挡不住读取 —— 这一格未验(不计入通过)"
else ob h-pe 2 "三-H8 profile.env 在却读不了 ⇒ 前提观测无效(不当成「没配 PDG_RESCUE_BIND」)" 'printf "PDG_RESCUE_BIND=10.1.0.5\n" > "$R3_ETC/profile.env"; chmod 000 "$R3_ETC/profile.env"; [[ -r "$R3_ETC/profile.env" ]] || echo hit >> "$HIT"'$'\n'"$TRIG" 'profile.env 在却查不了'; fi
cell h-pe-none "$TRIG"
cell h-pe-plain 'printf "PDG_OTHER=1\n" > "$R3_ETC/profile.env"'$'\n'"$TRIG"
cell_ok h-pe-none && grep -qx 'XRC=0' "$T/out-h-pe-none" && cell_ok h-pe-plain && grep -qx 'XRC=0' "$T/out-h-pe-plain" \
  && ok "三-H9 健康对照: profile.env 不存在(答案: 没配)或在而没有 PDG_RESCUE_BIND ⇒ 前提成立" \
  || bad "三-H9 健康对照被拒: $(inval h-pe-none) $(inval h-pe-plain) $(grep -h '^XWHY=' "$T/out-h-pe-none" "$T/out-h-pe-plain" | tr '\n' ' ')"
CREATE='r4_inject_create; echo "XRC=$?"; echo "XWHY=$R3_WHY"; echo "INJ=[$R4_INJ]"; echo "LEFT=$([[ -e "$R4_LINK" ]] && echo 在 || echo 没了)"'
ob h-dev 1 "三-H10 注入目录设备号先输出「同设备」再失败 ⇒ 不建立" "$LNREC; $DEVFAIL"$'\n'"$CREATE" '注入目录设备号查询失败(stat rc=1)'
cell_ok h-dev && [[ "$(calls h-dev)" == 0 ]] && grep -qx 'INJ=\[\]' "$T/out-h-dev" && grep -qx 'LEFT=没了' "$T/out-h-dev" \
  && ok "三-H10b 设备号查询失败 ⇒ ln 替身自己记 0 次, 没有登记, 盘上没有链接" || bad "三-H10b 阻断不完整: ln 记录 $(calls h-dev) 次 $(grep -E '^(INJ|LEFT)=' "$T/out-h-dev" | tr '\n' ' ')"
ob h-ver 3 "三-H11 建完核验的查询先输出「nlink=2」再失败 ⇒ 判核验不过并按登记善后" "$VERFAIL"$'\n'"$CREATE" '建完核验不过或核验查询失败(目标 stat rc=1'
cell_ok h-ver && grep -qx 'INJ=\[\]' "$T/out-h-ver" && grep -qx 'LEFT=没了' "$T/out-h-ver" \
  && ok "三-H11b 核验查询失败后链接已按登记删掉、登记清空" || bad "三-H11b 善后不对: $(grep -E '^(INJ|LEFT)=' "$T/out-h-ver" | tr '\n' ' ')"
ob h-rmid 3 "三-H12 清理前的身份查询先输出「对得上」再失败 ⇒ 身份判不了, **不删**" 'r4_inject_create >/dev/null; rm(){ echo "rm $*" >> "$STUB_CALLS"; command rm "$@"; }; stat(){ if [[ "$*" == "-c %d:%i -- $R4_LINK" ]]; then command stat "$@"; echo hit >> "$HIT"; return 1; fi; command stat "$@"; }'$'\n''r4_inject_remove; echo "XRC=$?"; echo "LEFT=$([[ -e "$R4_LINK" ]] && echo 在 || echo 没了)"' '身份判不了'
cell_ok h-rmid && [[ "$(calls h-rmid)" == 0 ]] && grep -qx 'LEFT=在' "$T/out-h-rmid" \
  && ok "三-H12b 身份查询失败 ⇒ rm 替身自己记 0 次, 链接留在盘上" || bad "三-H12b 阻断不完整: rm 记录 $(calls h-rmid) 次 $(grep '^LEFT=' "$T/out-h-rmid")"
RBO='printf "✅ 已回滚并重启服务\n" > "$R3_LOG"'
ob h-rbpart 1 "三-H13 「未完全回滚」的查询自身出错 ⇒ 不当成「没有」, 回滚结局不成立" "P=未能恢复; $GERR; $RBO"$'\n''r4_rollback_outcome; echo "XRC=$?"' '「未完全回滚」查询失败' '恰 1 次'
ob h-rberr 1 "三-H14 回滚阶段 ❌ 的查询自身出错 ⇒ 不当成「没有」" "P=❌; $GERR; $RBO"$'\n''r4_rollback_outcome; echo "XRC=$?"' '回滚阶段 ❌ 的查询失败' '恰 1 次'
ob h-scan 1 "三-H15 其它迁移失败文案的扫描查询出错 ⇒ 不说成「一条都没扫到」" "P='pdg-probe81 未能启用'; $GERR"$'\n''R4_SNAP_NEW=20260101-000000; G="  iOS GMS 清理: $R4_TARGET 是硬链接(nlink=2), 改它会波及另一个名字 → 未改动任何文件"
printf "%s\n" "$L_M0" "$L_RET" "$G" "$L_MIG" "回滚到 20260101-000000 …" > "$R3_LOG"; r4_markers; echo "XRC=$?"' '扫描查询失败' 'VNOTE ④-1 其它会传出失败的迁移'
ob h-lineno 2 "三-H16 取行号的 grep 先输出再失败 ⇒ 行号不采信" 'printf "a\n回滚到 s1 …\n" > "$R3_LOG"; grep(){ if [[ "$1" == -nF ]]; then command grep "$@"; echo hit >> "$HIT"; return 2; fi; command grep "$@"; }'$'\n''r4_mark_line "$R3_LOG" "回滚到 s1"; echo "XRC=$?"; echo "XWHY=$R3_WHY"; echo "VAL=[$R3_VAL]"' '取行号的查询失败'
SNV='R4_SNAP_BEFORE="old-1"; mkdir -p "$SNAPROOT/old-1"'$'\n'"$NEWSNAP"
if [[ "$(id -u)" == 0 ]]; then echo "[NOTE] 三-H17 以 root 跑, chmod 000 挡不住读取 —— 这一格未验(不计入通过)"
else ob h-svst 1 "三-H17 svcstate.tsv 读不了 ⇒ 绑定判不了(不说成「没有指向这一份」)" "$SNV"'; chmod 000 "$d/svcstate.tsv"; [[ -r "$d/svcstate.tsv" ]] || echo hit >> "$HIT"'$'\n''r4_snapshot_verdict; echo "XRC=$?"' 'svcstate.tsv 读不了' '没有指向这一份'; fi
ob h-sid 1 "三-H18 snap.tar.gz 的身份查询先输出再失败 ⇒ 绑定判不了" "$SNV; K=%d:%i:%s:%Y; $AFTER"$'\n''r4_snapshot_verdict; echo "XRC=$?"' 'snap.tar.gz 的身份查询失败(stat rc=1)'

# ── 三-I 退出码分开结算: 包装器 / 产品 / timeout ────────────────────────────────
ev(){   # $1=格名 $2=布置 $3=期望 XRC $4=说明 $5=期望片段(多个用 @@ 隔开) [$6=不许出现的片段]
  cell "$1" 'R3_RCFILE="$R3_TMP/rc"; R3_TOERR="$R3_TMP/toerr"'$'\n'"$2"$'\n''r4_exit_verdict; echo "XRC=$?"; echo "W=[$R4_WRAP_RC] P=[$R4_PROD_RC]"'
  local why f; why="$(inval "$1")"
  grep -qx "XRC=$3" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $3"
  while IFS= read -r f; do [[ -z "$f" ]] || grep -qF -- "$f" "$T/out-$1" || why="${why:+$why; }缺「$f」"; done <<<"${5//@@/$'\n'}"
  [[ -z "${6:-}" ]] || absent "$6" "$T/out-$1" || why="${why:+$why; }出现了「$6」(或查不了)"
  [[ -z "$why" ]] && ok "$4" || bad "$4: $why —— $(grep -E '^(XRC|W=|VBAD)' "$T/out-$1" | tr '\n' ' ' | head -c 240)"
}
ev i-ok 'R3_WRAP_RC=0; echo 1 > "$R3_RCFILE"; : > "$R3_TOERR"' 0 "三-I1 健康的预期失败: 包装器 0、产品 1、没有 timeout 发信号记录 ⇒ 成立" '包装器正常结束@@产品原始退出码 = 1@@没有 timeout 的发信号记录' 'VBAD'
ev i-137 'R3_WRAP_RC=137; echo 1 > "$R3_RCFILE"; : > "$R3_TOERR"' 1 "三-I2 包装器 137(被杀)而产品 1、没有 timeout 记录 ⇒ 不成立(包装器异常不被正确的产品码掩盖)" '包装器返回码 137@@日志与现场再像样也不算健康的预期失败'
ev i-124 'R3_WRAP_RC=124; echo 1 > "$R3_RCFILE"; printf "%s\n" "timeout: sending signal TERM to command bash" > "$R3_TOERR"' 1 "三-I3 超时: 包装器 124 且 timeout 有发信号记录 ⇒ 两条各自判不成立" '包装器返回码 124@@timeout 有发信号记录'
ev i-p0 'R3_WRAP_RC=0; echo 0 > "$R3_RCFILE"; : > "$R3_TOERR"' 1 "三-I4 产品退出 0 ⇒ 不是预期失败" '产品原始退出码 = 0(预期 1)'
ev i-norc 'R3_WRAP_RC=0; : > "$R3_TOERR"' 1 "三-I5 产品退出码没写出 ⇒ 不成立(内层没走到写退出码那一步)" '产品原始退出码 = 未写出'
ev i-toerr 'R3_WRAP_RC=0; echo 1 > "$R3_RCFILE"; mkdir -p "$R3_TOERR"' 1 "三-I6 timeout 留档读不了 ⇒ 观测无效, 不当成「没有发信号」" 'timeout 记录读不了'
ev i-nowrap 'unset R3_WRAP_RC; echo 1 > "$R3_RCFILE"; : > "$R3_TOERR"' 1 "三-I7 包装器返回码未取得 ⇒ 不成立" '包装器返回码未取得'

# ── 三-J 身份回到桥接(④ 判据原文 + ③ 读取器原文; 沙箱仓库) ─────────────────────
mkrepo(){   # $1=目录 → 只有一次提交的沙箱仓库(桥接树的最小形态: CLI + 受管模块清单 + 一个模块), 打印提交号
  local r="$1"
  mkdir -p "$r/deploy/bot" "$r/lib" || return 1
  printf 'cli\n' > "$r/deploy/bot/pdg.sh" && printf 'mod\n' > "$r/deploy/bot/a.py" || return 1
  cat > "$r/lib/modules.sh" <<'EOS' || return 1
pdg_platform_modules(){ [[ "$1" == ios ]] && printf '%s\n' 'deploy/bot/a.py a.py 644'; }
EOS
  git -C "$r" init -q && e2e_git "$r" add -A \
    && e2e_git "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm bridge \
    && git -C "$r" rev-parse HEAD
}
IDSET='E2E_ROOT="$ROOT"; BRIDGE_SHA="$(mkrepo "$SB/git")" || { echo "沙箱仓库布置失败"; exit 9; }
R3_REPO="$SB/git"; R3_OBJ="$SB/git"; R3_BRSRC="$SB/git"; R3_MODDIR="$SB/opt/pdg-bot"; R3_CLI="$SB/usr/local/bin/pdg"
cp -- "$SB/git/deploy/bot/pdg.sh" "$R3_CLI" && cp -- "$SB/git/deploy/bot/a.py" "$R3_MODDIR/a.py" || { echo "现役布置失败"; exit 9; }'
idb(){   # $1=格名 $2=期望 XRC $3=说明 $4=布置之后做的事 $5=期望片段 [$6=不许出现的片段]
  cell "$1" "$IDSET"$'\n'"$4"$'\n''r4_identity_back; echo "XRC=$?"'
  local why; why="$(inval "$1")"
  grep -qx "XRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $2"
  grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "${6:-}" ]] || absent "$6" "$T/out-$1" || why="${why:+$why; }出现了「$6」(或查不了)"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(XRC|V)' "$T/out-$1" | tr '\n' ' ' | head -c 260)"
}
idb j-ok 0 "三-J1 健康: HEAD / CLI / 受管模块都回到桥接 ⇒ 成立" ':' '受管模块 1 项逐字节 = 桥接树' 'VBAD'
idb j-head 1 "三-J2 现役 HEAD 不是桥接 ⇒ 不成立" 'echo later > "$SB/git/later"; e2e_git "$SB/git" add -A && e2e_git "$SB/git" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm later' '不是桥接'
idb j-cli 1 "三-J3 现役 CLI 不是桥接版 ⇒ 不成立" 'echo changed > "$R3_CLI"' '现役 CLI 不是桥接版'
idb j-mod 1 "三-J4 受管模块与桥接树不同 ⇒ 不成立" 'echo changed > "$R3_MODDIR/a.py"' '受管模块有 1 项与桥接树不同'
idb j-read 1 "三-J5 现役仓库读不了 ⇒ 观测无效, 不当成「回到桥接」" 'R3_REPO="$SB/没有这个仓库"' '④-3 观测无效'

# ── 三-K 服务终态回到前像(④ 判据原文 + ③ 集合核对原文; 只顶替 systemd 采样) ─────────
svrow(){   # $1=unit $2=active $3=sub $4=enabled $5=MainPID $6=InvocationID → 与 bridge_svc_sample 同形的 13 列
  printf '%s\t%s.service\tservice\tsimple\tloaded\t%s\t%s\t%s\t%s\t%s\t0\t-\tok\n' "$1" "$1" "$2" "$3" "$4" "$5" "$6"
}
# shellcheck disable=SC2034  # 这四个只在格代码(单引号串)里展开
I1=0123456789abcdef0123456789abcdef I2=fedcba9876543210fedcba9876543210 I3=00112233445566778899aabbccddeeff I4=ffeeddccbbaa99887766554433221100
SVSET='SVC_WATCH=(mosdns pdg-mitm); AFTER_ROWS="$R3_TMP/svc-after-fixture.tsv"
{ svrow mosdns active running enabled 100 "$I1"; svrow pdg-mitm active running enabled 101 "$I2"; } > "$R3_TMP/svc-before.tsv"
declare -A R4_ROWS_BEFORE=(); r3_set_check "$R3_TMP/svc-before.tsv" 调用前 R4_ROWS_BEFORE || { echo "前像布置失败: $R3_WHY"; exit 9; }
bridge_svc_sample(){ echo "sample $1" >> "$STUB_CALLS"; cp -- "$AFTER_ROWS" "$1"; }'
svb(){   # $1=格名 $2=期望 XRC $3=说明 $4=调用后那份采样的布置 $5=期望片段 [$6=不许出现的片段]
  cell "$1" "$SVSET"$'\n'"$4"$'\n''r4_svc_back; echo "XRC=$?"'
  local why c crc; why="$(inval "$1")"; c="$(calls "$1")"; crc=$?
  grep -qx "XRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $2"
  { (( crc == 0 )) && [[ "$c" == 1 ]]; } || why="${why:+$why; }采样替身记录 $c 次(应 1)"
  grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "${6:-}" ]] || absent "$6" "$T/out-$1" || why="${why:+$why; }出现了「$6」(或查不了)"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(XRC|V)' "$T/out-$1" | tr '\n' ' ' | head -c 260)"
}
svb k-ok 0 "三-K1 健康: 终态与前像一致, 只有 PID / InvocationID 变了 ⇒ 成立" '{ svrow mosdns active running enabled 200 "$I3"; svrow pdg-mitm active running enabled 201 "$I4"; } > "$AFTER_ROWS"' 'pdg-mitm 终态与前像一致' 'VBAD'
svb k-act 1 "三-K2 pdg-mitm 没回到 active ⇒ 不成立" '{ svrow mosdns active running enabled 200 "$I3"; svrow pdg-mitm inactive dead enabled - -; } > "$AFTER_ROWS"' 'pdg-mitm 终态与前像不同'
svb k-ena 1 "三-K3 pdg-mitm 的启用状态变了 ⇒ 不成立" '{ svrow mosdns active running enabled 200 "$I3"; svrow pdg-mitm active running disabled 201 "$I4"; } > "$AFTER_ROWS"' 'pdg-mitm 终态与前像不同'
svb k-miss 1 "三-K4 调用后采样缺一行 ⇒ 采样不可用, 不逐项放行" 'svrow mosdns active running enabled 200 "$I3" > "$AFTER_ROWS"' '缺服务 [pdg-mitm]'
svb k-fail 1 "三-K5 调用后采样写不出来 ⇒ 不成立" 'bridge_svc_sample(){ echo "sample $1" >> "$STUB_CALLS"; return 1; }' '调用后服务采样写不出来'

# ── 三-L 回滚后的 DNS(④ 判据原文 + ③ 的 r3_dns_path / r3_dns_say 原文; 只顶替最末端的仪器与探针) ──
DNSSET='source "$T/r3dns.sh"
R3_DNS_U=198.51.100.7; E2E_SIP=10.0.0.1; R3_DNS_W=gs-loc.apple.com; R3_DNS_CPOST=c-post.example; R3_DNS_PPOST=p-post.example
r3_dns_conditions(){ echo "conditions" >> "$STUB_CALLS"; R3_WHY="仪器替身: ${DC:-0}"; return "${DC:-0}"; }
r3_dns_rulematch(){ echo "rulematch $*" >> "$STUB_CALLS"; R3_VAL=""; (( ${RM:-0} == 0 )) || { R3_WHY="规则替身判不了"; return 2; }; printf -v R3_VAL "%s\t%s" "$1" "${RM_HIT:-}"; }
r3_dns_probe(){ echo "probe $1 $2" >> "$STUB_CALLS"; local k v
  case "$1" in "$R3_DNS_W") k=W;; "$R3_DNS_CPOST") k=C;; "$R3_DNS_PPOST") k=P;; *) R3_WHY="探针替身不认识 $1"; return 2;; esac
  v="PR_$k"; v="${!v:-}"; [[ -n "$v" ]] || { [[ "$k" == C ]] && v=U || v=H; }
  R3_DNS_ST=NOERROR; R3_DNS_ID=1
  case "$v" in
    U) R3_DNS_ANS="$R3_DNS_U"; R3_DNS_INC=1;;
    U0) R3_DNS_ANS="$R3_DNS_U"; R3_DNS_INC=0;;
    H) R3_DNS_ANS="$E2E_SIP"; R3_DNS_INC=0;;
    bad) R3_WHY="dig 替身失败"; return 2;;
  esac; }'
precs(){   # $1=格名 → 打印探针替身自己记下的调用(名字 阶段, 逗号连接); 记录读不到 ⇒ 2(不当成「没调用」)
  local raw rc l s=""
  raw="$(cat -- "$T/calls-$1" 2>/dev/null)"; rc=$?; (( rc == 0 )) || return 2
  while IFS= read -r l; do [[ "$l" == "probe "* ]] && s="$s${l#probe },"; done <<<"$raw"
  printf '%s' "$s"
}
dnb(){   # $1=格名 $2=期望 XRC $3=说明 $4=布置 $5=期望片段 $6=期望的探针调用序列 [$7=不许出现的片段]
  cell "$1" "$DNSSET"$'\n'"$4"$'\n''r4_dns_back; echo "XRC=$?"'
  local why sq sqrc; why="$(inval "$1")"; sq="$(precs "$1")"; sqrc=$?
  grep -qx "XRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $2"
  grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  if (( sqrc != 0 )); then why="${why:+$why; }探针调用记录读不到(不当成没调用)"
  elif [[ "$sq" != "$6" ]]; then why="${why:+$why; }探针调用 [$sq], 应 [$6]"; fi
  [[ -z "${7:-}" ]] || absent "$7" "$T/out-$1" || why="${why:+$why; }出现了「$7」(或查不了)"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(XRC|V)' "$T/out-$1" | tr '\n' ' ' | head -c 260)"
}
PWC='p-post.example post-p,gs-loc.apple.com post-w,c-post.example post-c,'
dnb l-ok 0 "三-L1 健康: 仪器条件在、P 不被规则匹配 ⇒ P 走 H、W 走接管 H、C 取得 U" ':' 'WLOC 接管已随回滚回来 —— 成立' "$PWC" 'VBAD'
dnb l-cond1 1 "三-L2 仪器条件被改动 ⇒ 结论未取得, 一次探针都不发" 'DC=1' 'DNS 仪器条件被改动' ''
dnb l-cond2 1 "三-L3 仪器条件观测失效 ⇒ 结论未取得, 一次探针都不发" 'DC=2' 'DNS 仪器条件观测失效' ''
dnb l-rmfail 1 "三-L4 P 的规则匹配判不了 ⇒ 不发 P 探针(W / C 照常)" 'RM=2' 'P 规则匹配判不了' 'gs-loc.apple.com post-w,c-post.example post-c,'
dnb l-rmhit 1 "三-L5 P 被规则匹配 ⇒ 它代表不了普通劫持路径, 不发 P 探针" 'RM_HIT=geosite_cn' '被规则匹配(geosite_cn)' 'gs-loc.apple.com post-w,c-post.example post-c,'
dnb l-wu 1 "三-L6 W 由自有上游答 U ⇒ WLOC 接管没随回滚回来" 'PR_W=U' 'WLOC 接管已随回滚回来 —— 不成立' "$PWC"
dnb l-ch 1 "三-L7 C 答成 H ⇒ 独立上游对照不成立" 'PR_C=H' 'C(独立上游对照 c-post.example)经 local_upstream 取得 U —— 不成立' "$PWC"
dnb l-cu0 1 "三-L8 C 答 U 但自有上游没收到 ⇒ 来源证据不成立(缓存或别的来源)" 'PR_C=U0' '来源证据不成立' "$PWC"
dnb l-pbad 1 "三-L9 P 的探针观测无效 ⇒ 不算成立" 'PR_P=bad' '观测无效' "$PWC"

# ── 三-N 注入前提门(335, 路径 A): 冻结退役模板的有效规则、inet pdg、救援自动选址 ─────────────
TRC_CODE='r4_trigger_ready; echo "TRC=$?"; echo "TWHY=$R3_WHY"'
tg(){   # $1=格名 $2=期望 TRC $3=说明 $4=布置 $5=期望原因片段(可空) [$6=hit: 注入必须命中]
  cell "$1" "$4"$'\n'"$TRC_CODE"
  local why; why="$(inval "$1")"
  grep -qx "TRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^TRC=' "$T/out-$1")], 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺原因「$5」"
  [[ "${6:-}" != hit ]] || hit "$1" || why="${why:+$why; }注入没命中"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(TRC|TWHY|VBAD)' "$T/out-$1" | tr '\n' ' ' | head -c 240)"
}
GSHOW='git(){ if [[ "$1" == -C && "$3" == show ]]; then command git "$@"; echo hit >> "$HIT"; return 1; fi; command git "$@"; }'
GLSTREE='git(){ if [[ "$1" == -C && "$3" == ls-tree ]]; then command git "$@"; echo hit >> "$HIT"; return 1; fi; command git "$@"; }'
AUTO='printf "PDG_INTERNAL_CIDR=10.9.0.0/16\n" > "$R3_ETC/profile.env"; ip(){ echo "ip $*" >> "$R3_TMP/ip.calls"; printf "%s\n" "2: eth0    inet 10.9.1.5/24 brd 10.9.1.255 scope global eth0" "3: eth1    inet 192.168.7.2/24 brd 192.168.7.255 scope global eth1"; }'
tg n-comment 1 "三-N1 冻结退役模板只在注释里有 5228(整行注释与行尾注释)⇒ 不成立(注释不算有效规则)" 'RETIRE_SHA="$TPL_COMMENT"' '注释里的不算'
tg n-none 1 "三-N2 冻结退役模板里没有 5228 端口集 ⇒ 不成立" 'RETIRE_SHA="$TPL_NONE"' '有效规则里没有 5228 端口集'
tg n-missing 1 "三-N3 冻结退役提交里没有模板文件 ⇒ 不成立" 'RETIRE_SHA="$TPL_MISSING"' '里没有 deploy/firewall/nftables-mihomo.conf'
tg n-bridge 1 "三-N4 现役桥接那份(提交与现役仓库)有 5228、冻结退役那份没有 ⇒ 不成立(只认冻结退役模板)" 'RETIRE_SHA="$TPL_NONE"; BRIDGE_SHA="$TPL_GOOD"; R3_REPO="$SB/live"; mkdir -p "$R3_REPO/deploy/firewall"; git -C "$T/robj" show "$TPL_GOOD:deploy/firewall/nftables-mihomo.conf" > "$R3_REPO/deploy/firewall/nftables-mihomo.conf" || exit 9' '有效规则里没有 5228 端口集'
tg n-show 2 "三-N5 模板读取先输出全文再失败 ⇒ 观测无效(已输出的不采信)" "$GSHOW" '冻结退役模板读取失败(git show rc=1)' hit
tg n-lstree 2 "三-N6 退役树查询先输出再失败 ⇒ 观测无效" "$GLSTREE" '树查询失败(git ls-tree rc=1)' hit
tg n-notpdg 1 "三-N7 现役文件还不是 inet pdg ⇒ 模板同步不会动手, 不成立" 'printf "ip saddr 10.0.0.0/16 tcp dport { 53 } accept\n" > "$R4_TARGET"' '还不是 inet pdg'
tg n-pdgq 2 "三-N8 inet pdg 的查询自身出错 ⇒ 观测无效" "P='table inet pdg'; $GERR" 'inet pdg 查询失败' hit
tg n-auto1 1 "三-N9 没配监听地址、来源段里恰有 1 个本机全局地址 ⇒ 救援平面会自动选址启用, 不成立" "$AUTO" '会自动选址启用'
tg n-auto2 0 "三-N10 来源段里有 2 个本机全局地址 ⇒ 不会自动选址(与产品同口径), 前提成立" 'printf "PDG_INTERNAL_CIDR=10.9.0.0/16\n" > "$R3_ETC/profile.env"; ip(){ printf "%s\n" "2: eth0    inet 10.9.1.5/24 scope global eth0" "3: eth1    inet 10.9.2.6/24 scope global eth1"; }' ''
tg n-auto0 0 "三-N11 救援意图明确为 0 ⇒ 来源段里恰有 1 个地址也不会自动启用, 前提成立" "$AUTO"'; printf "PDG_RESCUE_ENABLED=0\n" >> "$R3_ETC/profile.env"' ''
tg n-autoq 2 "三-N12 本机地址查询先输出再失败 ⇒ 自动选址判不了, 观测无效" 'printf "PDG_INTERNAL_CIDR=10.9.0.0/16\n" > "$R3_ETC/profile.env"; ip(){ printf "%s\n" "2: eth0    inet 10.9.1.5/24 scope global eth0"; echo hit >> "$HIT"; return 1; }' '本机地址查询失败(ip rc=1)' hit
tg n-autoquote 1 "三-N13 来源段最后一次赋值带引号(产品去掉一层引号)⇒ 同样判到自动选址" "$AUTO"'; printf "PDG_INTERNAL_CIDR=\"10.9.0.0/16\"\n" >> "$R3_ETC/profile.env"' '会自动选址启用'
tg n-autolast 0 "三-N14 来源段取最后一次赋值(与产品同口径): 后一次改成不含本机地址的段 ⇒ 不会自动选址" "$AUTO"'; printf "PDG_INTERNAL_CIDR=172.31.0.0/16\n" >> "$R3_ETC/profile.env"' ''
# 336: 救援意图 / 来源段取"最后一次赋值"时保留末条空值(与产品 `sed -n … | tail -1` 同义); 读取与选取两步的失败各自具名
tg n-lastintent 1 "三-N15 意图末两条为 0、空 ⇒ 末条空值 = 意图为空, 自动选址会启用, 不成立(不被上一条 0 放行)" "$AUTO"'; printf "PDG_RESCUE_ENABLED=0\nPDG_RESCUE_ENABLED=\n" >> "$R3_ETC/profile.env"' '会自动选址启用'
tg n-lastcidr 0 "三-N16 来源段末两条为有效、空 ⇒ 末条空值 = 没有来源段, 不会自动选址, 不多拦" "$AUTO"'; printf "PDG_INTERNAL_CIDR=\n" >> "$R3_ETC/profile.env"' ''
tg n-empintent 1 "三-N17 意图连续两条空 ⇒ 意图为空, 自动选址会启用(对照)" "$AUTO"'; printf "PDG_RESCUE_ENABLED=\nPDG_RESCUE_ENABLED=\n" >> "$R3_ETC/profile.env"' '会自动选址启用'
tg n-empcidr 0 "三-N18 来源段连续两条空 ⇒ 没有来源段(对照)" 'printf "PDG_INTERNAL_CIDR=\nPDG_INTERNAL_CIDR=\n" > "$R3_ETC/profile.env"; ip(){ echo "ip $*" >> "$R3_TMP/ip.calls"; printf "%s\n" "2: eth0    inet 10.9.1.5/24 scope global eth0"; }' ''
SEDI='sed(){ if [[ "$*" == *PDG_RESCUE_ENABLED* ]]; then command sed "$@"; echo hit >> "$HIT"; return 4; fi; command sed "$@"; }'
tg n-sedintent 2 "三-N19 救援意图读取先输出再失败 ⇒ 观测无效(已写出的不采信)" "$AUTO; $SEDI" '救援意图读取失败(sed rc=4)' hit
tg n-tailcidr 2 "三-N20 来源段取最后一次赋值先输出再失败 ⇒ 观测无效" "$AUTO"'; tail(){ if [[ "$*" == *rescue-cidr.all* ]]; then command tail "$@"; echo hit >> "$HIT"; return 1; fi; command tail "$@"; }' '来源段取最后一次赋值失败(tail rc=1)' hit
tg n-tailintent 2 "三-N21 救援意图取最后一次赋值失败 ⇒ 观测无效" "$AUTO"'; tail(){ if [[ "$*" == *rescue-intent.all* ]]; then command tail "$@"; echo hit >> "$HIT"; return 1; fi; command tail "$@"; }' '救援意图取最后一次赋值失败(tail rc=1)' hit
tg n-sedcidr 2 "三-N22 来源段读取先输出再失败 ⇒ 观测无效" "$AUTO"'; sed(){ if [[ "$*" == *PDG_INTERNAL_CIDR* ]]; then command sed "$@"; echo hit >> "$HIT"; return 4; fi; command sed "$@"; }' '来源段读取失败(sed rc=4)' hit
# 门不成立 / 观测无效 ⇒ 注入(ln 替身)与桩 CLI 都由替身自己记, 都必须 0 次
g g-nmissing 18 "三-G19 冻结退役提交里没有模板 ⇒ 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC"'; RETIRE_SHA="$TPL_MISSING"' '注入前提不成立'
g g-nshow 18 "三-G20 模板读取先输出再失败 ⇒ 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC; $GSHOW" '注入前提观测无效' hit
g g-nauto 18 "三-G21 救援会自动选址启用 ⇒ 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC; $AUTO" '注入前提不成立'
g g-ncomment 18 "三-G22 模板只在注释里有 5228 ⇒ 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC"'; RETIRE_SHA="$TPL_COMMENT"' '注入前提不成立'
# 336: 末条空值与读取失败的门控格 —— ln 写自己的记录文件(事先建空), 与桩 CLI 分开记; 读不到不补 0
LNSEP=': > "$R3_TMP/ln.calls"; ln(){ echo "ln $*" >> "$R3_TMP/ln.calls"; command ln "$@"; }'
lncnt(){ local f="$T/tmp-$1/ln.calls" n rc; [[ -f "$f" && -r "$f" ]] || { printf '读不到'; return 2; }; n="$(grep -c . "$f" 2>/dev/null)"; rc=$?; (( rc <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]] || { printf '读不到'; return 2; }; printf '%s' "$n"; }   # ln 替身自己的记录 → 条数 / 读不到
g g-lastintent 18 "三-G26 意图末两条为 0、空 ⇒ 自动选址会启用, 不注入、不调用(桩 CLI 0 次; ln 另见三-G29)" "$LNSEP; $AUTO"'; printf "PDG_RESCUE_ENABLED=0\nPDG_RESCUE_ENABLED=\n" >> "$R3_ETC/profile.env"' '注入前提不成立'
g g-lastcidr 0 "三-G27 来源段末两条为有效、空 ⇒ 不多拦, 照常注入并调用 1 次(ln 另见三-G29)" "$LNSEP; $AUTO"'; printf "PDG_INTERNAL_CIDR=\n" >> "$R3_ETC/profile.env"' '注入已建立并核过'
g g-sedintent 18 "三-G28 救援意图读取先输出再失败 ⇒ 前提观测无效, 不注入、不调用(桩 CLI 0 次; ln 另见三-G29)" "$LNSEP; $AUTO; $SEDI" '注入前提观测无效' hit
q1="$(lncnt g-lastintent)"; r1=$?; q2="$(lncnt g-sedintent)"; r2=$?; q3n="$(lncnt g-lastcidr)"; r3n=$?
if cell_ok g-lastintent && cell_ok g-sedintent && cell_ok g-lastcidr && (( r1 == 0 && r2 == 0 && r3n == 0 )) && [[ "$q1" == 0 && "$q2" == 0 && "$q3n" == 1 ]]; then
  ok "三-G29 ln 替身独立记账: 三-G26 0 次、三-G28 0 次(阻断格没建链接), 三-G27 1 次(健康格照常建链接)"
else bad "三-G29 ln 独立记账不对: G26 [$q1/$r1] G28 [$q2/$r2] G27 [$q3n/$r3n] $(inval g-lastintent) $(inval g-sedintent) $(inval g-lastcidr)"; fi

# ── 三-P 调用前补采: 磁盘防火墙原文 / 摘要 / 文件身份, .pre-tplsync 单独登记 ────────────────
if cell_ok g-ok && cmp -s "$T/evid-g-ok/07-nft-disk-before.conf" "$T/sb-g-ok/etc/nftables.conf" \
   && grep -qxE "sha256	$(sha256sum < "$T/sb-g-ok/etc/nftables.conf" | cut -c1-64)" "$T/evid-g-ok/07-nft-disk-before.id" \
   && grep -qE '^stat\(类型\|mode\|属主\|设备:inode:nlink\|字节\)	regular file\|644\|[0-9]+:[0-9]+\|[0-9]+:[0-9]+:1\|[0-9]+$' "$T/evid-g-ok/07-nft-disk-before.id" \
   && grep -qx '状态	不存在' "$T/evid-g-ok/08-pre-tplsync-before.txt"; then
  ok "三-P1 健康: 调用前磁盘原文逐字留存、摘要与文件身份(注入前 nlink=1)已记; .pre-tplsync 不存在也如实登记"
else bad "三-P1 调用前补采不完整: $(inval g-ok) $(ls "$T/evid-g-ok" 2>/dev/null | tr '\n' ' ')"; fi
g g-ptpl 0 "三-G23 .pre-tplsync 已存在(普通文件)⇒ 只登记, 不当前提, 照常进入注入" 'printf "old\n" > "$SB/etc/nftables.conf.pre-tplsync"' '注入已建立并核过'
cell_ok g-ptpl && grep -qx '状态	存在' "$T/evid-g-ptpl/08-pre-tplsync-before.txt" \
  && grep -qx "sha256	$(printf 'old\n' | sha256sum | cut -c1-64)" "$T/evid-g-ptpl/08-pre-tplsync-before.txt" \
  && [[ "$(cat "$T/sb-g-ptpl/etc/nftables.conf.pre-tplsync" 2>/dev/null)" == old ]] \
  && ok "三-P2 .pre-tplsync 存在: 类型 / mode / 属主 / 身份 / 摘要都登记, 文件原样未动(不删除、不修整)" \
  || bad "三-P2 .pre-tplsync 登记不对: $(inval g-ptpl) $(tr '\n' ' ' < "$T/evid-g-ptpl/08-pre-tplsync-before.txt" 2>/dev/null)"
g g-ptplq 17 "三-G24 .pre-tplsync 的身份查询先输出再失败 ⇒ 调用前观测不全, 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC"'; printf "old\n" > "$SB/etc/nftables.conf.pre-tplsync"; stat(){ if [[ "$*" == *pre-tplsync* ]]; then command stat "$@"; echo hit >> "$HIT"; return 1; fi; command stat "$@"; }' '.pre-tplsync 登记没取得' hit
g g-ndisk 17 "三-G25 调用前磁盘原文读取先输出再失败 ⇒ 调用前观测不全, 不注入、不调用(ln 与 CLI 都 0 次)" "$LNREC"'; cat(){ if [[ "$*" == "-- $R4_TARGET" ]]; then command cat "$@"; echo hit >> "$HIT"; return 1; fi; command cat "$@"; }' '原文读取失败(cat rc=1)' hit

# ── 三-T 回滚后目标与测试链接的文件身份(与登记的旧 inode 区分; 查询失败不当成恢复成立)──────────
TAPRE='r4_inject_create >/dev/null || exit 8'
REPLACE='cp -- "$R4_TARGET" "$R3_TMP/restore" && rm -f -- "$R4_TARGET" && cp -- "$R3_TMP/restore" "$R4_TARGET" || exit 9'
ta(){   # $1=格名 $2=期望 XRC $3=说明 $4=注入之后的布置 $5=期望原因片段(可空) [$6=hit]
  cell "$1" "$TAPRE"$'\n'"$4"$'\n''r4_target_after; echo "XRC=$?"; echo "XWHY=$R3_WHY"'
  local why; why="$(inval "$1")"
  grep -qx "XRC=$2" "$T/out-$1" || why="${why:+$why; }返回 [$(grep -m1 '^XRC=' "$T/out-$1")], 期望 $2"
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺原因「$5」"
  [[ "${6:-}" != hit ]] || hit "$1" || why="${why:+$why; }注入没命中"
  [[ -z "$why" ]] && ok "$3" || bad "$3: $why —— $(grep -E '^(XRC|XWHY)' "$T/out-$1" | tr '\n' ' ' | head -c 240)"
}
ta t-ok 0 "三-T1 回滚按产品方式换出新文件 ⇒ 目标新 inode、nlink=1, 旧 inode 只剩链接 ⇒ 成立" "$REPLACE" ''
ta t-inplace 1 "三-T2 目标被原地改回(仍是登记的旧 inode, 与链接同一个)⇒ 不是产品换出的新文件, 不成立" 'printf "restored\n" > "$R4_TARGET"' '仍是登记的旧 inode'
ta t-statt 2 "三-T3 目标身份查询先输出再失败 ⇒ 观测无效, 不当成恢复成立" "$REPLACE"'; stat(){ if [[ "$*" == "-c %d:%i:%h -- $R4_TARGET" ]]; then command stat "$@"; echo hit >> "$HIT"; return 1; fi; command stat "$@"; }' '目标身份查询失败(stat rc=1' hit
ta t-statl 2 "三-T4 链接身份查询先输出再失败 ⇒ 观测无效" "$REPLACE"'; stat(){ if [[ "$*" == "-c %d:%i:%h -- $R4_LINK" ]]; then command stat "$@"; echo hit >> "$HIT"; return 1; fi; command stat "$@"; }' '测试链接身份查询失败(stat rc=1' hit
ta t-nolink 1 "三-T5 测试链接已不在 ⇒ 旧 inode 的去向判不了, 不成立" "$REPLACE"'; rm -f -- "$R4_LINK"' '测试链接已不在'
ta t-other 1 "三-T7 测试链接被换成了别的文件(不再是登记的旧 inode)⇒ 不成立" "$REPLACE"'; printf "other\n" > "$R3_TMP/other" && mv -f -- "$R3_TMP/other" "$R4_LINK" || exit 9' '不再是登记的旧 inode'
cell t-noreg 'R4_INJ=""; r4_target_after; echo "XRC=$?"; echo "XWHY=$R3_WHY"'
cell_ok t-noreg && grep -qx 'XRC=2' "$T/out-t-noreg" && grep -qF '没有登记过注入身份' "$T/out-t-noreg" \
  && ok "三-T6 没有登记过注入身份 ⇒ 观测无效(不拿当前文件凑一个)" || bad "三-T6 没登记时的处置不对: $(inval t-noreg) $(tr '\n' ' ' < "$T/out-t-noreg" | head -c 160)"
ob h-m0q 1 "三-H19 M0 的查询自身出错 ⇒ 不成立(不当成有 M0)" "P='防火墙按模板重建'; $GERR"$'\n''R4_SNAP_NEW=20260101-000000; G="  iOS GMS 清理: $R4_TARGET 是硬链接(nlink=2), 改它会波及另一个名字 → 未改动任何文件"
printf "%s\n" "$L_M0" "$L_RET" "$G" "$L_MIG" "回滚到 20260101-000000 …" > "$R3_LOG"; r4_markers; echo "XRC=$?"' '计数查询失败(grep rc=2'

# ── 三-M 契约自身: 格的有效性与调用记录 ──────────────────────────────────────
cell m-crash 'echo "XRC=0"; exit 3'
cell m-kill 'echo "XRC=0"; kill -9 "$BASHPID"' 2>/dev/null     # 只压父壳的 "Killed" 作业通知
cell m-fine 'echo "XRC=0"'
cell_ok m-crash; x1=$?; cell_rc m-crash; y1=$?; v1="$CELL_RC"      # 要的是"子壳异常"(1), 不是"观测无效"(2)
cell_ok m-kill; x2=$?; cell_rc m-kill; y2=$?; v2="$CELL_RC"
if (( x1 == 1 && y1 == 0 )) && [[ "$v1" == 3 ]] && grep -qx 'XRC=0' "$T/out-m-crash" \
   && (( x2 == 1 && y2 == 0 )) && [[ "$v2" == 137 ]] && grep -qx 'XRC=0' "$T/out-m-kill"; then
  ok "三-M1 格先打印合法结果(XRC=0)再异常退出(exit 3 / 被 SIGKILL)⇒ 判执行无效, 那一行结果不采信"
else bad "三-M1 异常退出没被判执行无效(crash: 判定 $x1 / 退出码 ${v1:-未取得}; kill: 判定 $x2 / 退出码 ${v2:-未取得})"; fi
cell_ok m-fine && ok "三-M2 健康对照: 正常结束的格 ⇒ 有效" || bad "三-M2 正常结束的格被判无效: $(inval m-fine)"
mkdir -p "$T/calls-m-dir"; mc1="$(calls m-dir)"; mr1=$?; mc2="$(calls m-missing)"; mr2=$?
: > "$T/calls-m-empty"; mc3="$(calls m-empty)"; mr3=$?
if (( mr1 == 2 && mr2 == 2 )) && [[ "$mc1" == 读不到 && "$mc2" == 读不到 ]]; then
  ok "三-M3 调用记录读不了(是目录 / 不存在)⇒ 返回「读不到」, 不补成 0"
else bad "三-M3 调用记录读不了却给出了 [$mc1]/$mr1 [$mc2]/$mr2"; fi
(( mr3 == 0 )) && [[ "$mc3" == 0 ]] && ok "三-M4 健康对照: 空的调用记录 ⇒ 0 次(这才是真 0)" || bad "三-M4 空记录给出了 [$mc3]/$mr3"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

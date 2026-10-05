#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 格里赋值的变量由 source 进来的被测原文按名字读取(静态看不到)
# ──────────────────────────────────────────────────────────────────
# B / C2 两跳验收器(tests/e2e-real-retire-hop-bc.sh)的接线契约与本地模型格(不碰真实服务; 不需要 root / systemd; 本机与 CI 都能跑)。
#   一、workflow 接线: real_scope 多了 retire-hop-bc 这一个选项; 文件末尾追加的 real-retire-hop-bc job(b / c2 矩阵)先跑本契约、
#       再跑新验收器; 相对 3dcaee00 只有这两处改动。
#   二、静态: 共享输入(②③④⑤、e2e-lib、dns-stub、repoguard 等)相对 3dcaee00 逐字节不变; 新验收器**按它自己的抽法**抽到的共享块与
#       3dcaee00 的同名块逐字相同(两边各自非空); 不调用 359 复用表里"仅参考结构 / 不用"的函数; 静置计划秒数与限额前提不被覆盖。
#   三、模型格(登记见 360 证据 model/REGISTRY.txt): 被测函数一律按唯一成对标记从新验收器抽原文执行; 只替换外部命令与本格无关的叶子
#       (都在格里显式登记); 入口替身(第二跳入口流程 / 第三跳 CLI / 旧版 CLI)各自记调用, 调用次数以替身记录为准;
#       负控同时核注入命中、具体失败原因与调用次数。另在每个格里给"仅参考结构 / 不用"的函数装绊线, 被调用即记下。
#   这些都是模型验证, 不冒充真实 systemd、journal、DNS、防火墙或 root 环境的验收。
# 用法: bash tests/test-retire-hop-bc-contract.sh
#       PDG_BC_ONLY="F3 F4 …" 只跑点名的模型格(跳过一 / 二), 供撤销对照用; 不点名时全跑。
# ──────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDG_BC_BASE:-3dcaee00cd209728ed429ac967172ea9ce9839a6}"   # 验收冻结基线(共享输入以它为准)
BC="$ROOT/tests/e2e-real-retire-hop-bc.sh"; R3="$ROOT/tests/e2e-real-retire-hop.sh"; HOP2="$ROOT/tests/e2e-real-bridge-hop.sh"
PLAT="$ROOT/tests/e2e-real-platform-fail.sh"; WF="$ROOT/.github/workflows/ci.yml"
ONLY="${PDG_BC_ONLY:-}"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
fin(){ echo "────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"; (( nfail == 0 && pass > 0 )) || exit 1; exit 0; }
rdf(){   # $1=文件 → 0 整份读出(放在 RDV) / 1 不存在、读不了或读到一半失败(已输出的部分不采信)
  local v
  RDV=""
  [[ -f "$1" ]] || return 1
  v="$(cat -- "$1" 2>/dev/null)" || return 1
  RDV="$v"
}
qstate(){   # $@=一条 grep -q 形态的查询 → 打印 有 / 无 / 错(查询出错不当成"没有")
  "$@" > /dev/null 2>&1
  case $? in 0) echo 有;; 1) echo 无;; *) echo 错;; esac
}
JOB_OK=0; CODE_OK=0                         # 输入抽取成功才置 1; 依赖它们的"没有 …"核对在 0 时一律判未取得
jstate(){ (( JOB_OK == 1 )) || { echo 未取得; return; }; qstate grep -q "$@" "$T/job.yml"; }   # job 块没取得 ⇒ 未取得
jneg(){   # $1=格 $2=没有时的说明 $3=有时的说明 $4..=grep 参数 → 只有 job 块有效且查询明确"没有"才 OK
  local id="$1" okm="$2" badm="$3" s
  shift 3
  s="$(jstate "$@")"
  case "$s" in 无) ok "$id $okm";; 有) bad "$id $badm";; *) bad "$id 未取得($s): job 块没取得或查询出错 —— 不说成没有";; esac
}
cstate(){ (( CODE_OK == 1 )) || { echo 未取得; return; }; qstate grep -qE "$1" "$T/bccode.txt"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/bcc.XXXXXX")" || { echo "[未执行] 建不出临时目录"; echo "通过 0, 失败 1"; exit 1; }
reap_stubs(){ local p c; [[ -f "$T/stub-pids" ]] || return 0   # 受控上游进程只按登记 PID 且命令行相符时收
  while IFS= read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    c="$( { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null)"; [[ "$c" == *"$T/fake-stub.py"* ]] && kill "$p" 2>/dev/null
  done < "$T/stub-pids"; }
trap 'reap_stubs; chmod -R u+rwx -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
for f in "$BC" "$R3" "$HOP2" "$PLAT" "$WF"; do [[ -f "$f" ]] || { bad "找不到 $f"; fin; }; done
want(){ [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
job_block(){ awk -v h="  $1:" '$0==h{f=1} f && $0!=h && /^  [a-z][a-z0-9-]*:$/{exit} f' "$WF"; }

if [[ -z "$ONLY" ]]; then
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || { bad "取不到验收基线对象 $BASE —— 共享输入与接线核对无从谈起"; fin; }
echo "══ 一. workflow 接线 ══"
grep -qxF '        options: ["all", "platform", "retire", "bridge", "retire-hop", "late-failure", "retire-hop-bc", "first-upgrade"]' "$WF" \
  && ok "C4-1 real_scope 选项整行逐字相符(原有六项顺序不变, 其后依次追加 retire-hop-bc、first-upgrade)" || bad "C4-1 real_scope 选项整行不对"
grep -qF 'retire-hop-bc = B/C2 两跳' "$WF" && ok "C4-2 real_scope 的说明写明了 retire-hop-bc" || bad "C4-2 real_scope 说明没跟上"
job_block real-retire-hop-bc > "$T/job.yml"; JRC=$?; JOB_OK=0
if (( JRC == 0 )) && [[ -s "$T/job.yml" && "$(head -1 "$T/job.yml")" == "  real-retire-hop-bc:" ]] \
   && [[ "$(grep -cE '^  [a-z][a-z0-9-]*:$' "$T/job.yml")" == 1 ]]; then
  JOB_OK=1; ok "C4-3 取到的是 real-retire-hop-bc 自身($(grep -c '' "$T/job.yml") 行, 块内只有它一个 job 头)"
else bad "C4-3 job 抽取边界不对(awk rc=$JRC, 首行 [$(head -1 "$T/job.yml" 2>/dev/null)]) —— 依赖 job 块的'没有 …'核对一律判未取得"; fi
python3 - "$WF" > "$T/last.txt" 2>&1 <<'PY'
import re, sys
heads = re.findall(r"^  ([a-z][a-z0-9-]*):$", open(sys.argv[1], encoding="utf-8").read(), re.M)
print(" ".join(heads[-2:]) if heads else "<无>")
sys.exit(0 if len(heads) >= 2 and heads[-2] == "real-retire-hop-bc" and heads[-1] == "real-first-upgrade" else 1)
PY
[[ $? == 0 ]] && ok "C4-4 real-retire-hop-bc 是倒数第二个 job, 紧跟其后的最后一个 job 是 real-first-upgrade(末尾依次追加)" || bad "C4-4 最后两个 job 是 [$(cat "$T/last.txt")]"
if [[ "$(jstate -F "github.event.inputs.real_scope == 'retire-hop-bc'")" == 有 \
      && "$(jstate -E "real_scope == '(all|platform|retire|bridge|retire-hop|late-failure|)'")" == 无 ]]; then
  ok "C4-5 新 job 只在 real_scope=retire-hop-bc 时启动(不搭别的范围的车)"
else bad "C4-5 新 job 的启动条件不对或未取得"; fi
jneg C4-6 "新 job 里没有 continue-on-error" "新 job 里有 continue-on-error" 'continue-on-error'
grep -qx '      fail-fast: false' "$T/job.yml" && grep -qx '        preimage: \[b, c2\]' "$T/job.yml" \
  && ok "C4-7 矩阵: preimage = [b, c2], fail-fast: false(两格互不依赖)" || bad "C4-7 矩阵不对"
lc="$(grep -n '^        run: bash tests/test-retire-hop-bc-contract.sh$' "$T/job.yml" | cut -d: -f1)"
lr="$(grep -n '^        run: sudo -E bash tests/e2e-real-retire-hop-bc.sh$' "$T/job.yml" | cut -d: -f1)"
{ [[ "$lc" =~ ^[0-9]+$ && "$lr" =~ ^[0-9]+$ ]] && (( lc < lr )); } \
  && ok "C4-8 顺序: 新契约(第 $lc 行) → 新验收器(第 $lr 行), 各恰一处" || bad "C4-8 步骤不对(契约=[$lc] 验收器=[$lr])"
python3 - "$T/job.yml" > "$T/env.txt" 2>&1 <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
step = s.split("        run: sudo -E bash tests/e2e-real-retire-hop-bc.sh", 1)[0].rsplit("      - name:", 1)[1]
m = re.search(r"\n        env:\n((?:          [A-Z0-9_]+: .*\n)+)", step)
env = dict(re.findall(r"          ([A-Z0-9_]+): (.*)\n", m.group(1))) if m else {}
want = {"PDG_E2E_ISOLATED": '"1"', "PDG_REAL_MIGRATION_OK": '"1"', "PDG_BC_PREIMAGE": "${{ matrix.preimage }}",
        "PDG_BRIDGE_SHA": "${{ github.event.inputs.bridge_candidate }}", "PDG_RETIRE_SHA": "${{ github.event.inputs.product_candidate }}"}
ev = env.get("PDG_BC_EVID", "")
bad = [k for k in want if env.get(k) != want[k]]
extra = sorted(set(env) - set(want) - {"PDG_BC_EVID"})
okev = re.fullmatch(r'"(/[^"]*/real-acceptance-evidence-bc)"', ev)
d = re.search(r"\n          d=(\S+)\n", s)
same = bool(okev and d and d.group(1) == okev.group(1))
print("env=%r 缺 / 不符=%r 多出=%r 证据目录=%r 留证步读同一目录=%r" % (sorted(env), bad, extra, ev, same))
sys.exit(0 if (not bad and not extra and okev and same) else 1)
PY
[[ $? == 0 ]] && ok "C4-9 验收器步的 env 恰为登记的 6 项(不覆盖静置 / 超时 / 旧版 SHA; 留证步读同一证据目录)" \
  || bad "C4-9 验收器步的 env 不对: $(head -3 "$T/env.txt" | tr '\n' ' ')"
jneg C5-1 "新 job 不覆盖静置计划秒数、限额前提、超时与旧版 SHA" "新 job 里覆盖了静置 / 超时 / 旧版 SHA" -E 'R3_Q_|PDG_BC_[A-Z0-9_]*TIMEOUT|PDG_OLD_SHA'
jneg C4-10 "新 job 不跑 ② / ③ / ④(第二跳在新验收器里经桥接入口流程完成)" "新 job 里跑了 ② / ③ / ④ 的脚本" \
  -E 'e2e-real-bridge-hop\.sh|e2e-real-retire-hop\.sh|e2e-real-late-failure\.sh'
git -C "$ROOT" show "$BASE:.github/workflows/ci.yml" > "$T/base-ci.yml"; brc=$?
python3 - "$T/base-ci.yml" "$WF" "$T/job.yml" > "$T/wf.txt" 2>&1 <<'PY'
import difflib, re, sys
ctext = open(sys.argv[2], encoding="utf-8").read()
b = open(sys.argv[1], encoding="utf-8").read().split("\n"); c = ctext.split("\n")
job = open(sys.argv[3], encoding="utf-8").read()
def region(lines):
    i = lines.index("      real_scope:"); j = i
    while lines[j] != '        default: "all"':
        j += 1
    return i, j + 1
bi, bj = region(b); ci, cj = region(c)
bm = "\n".join(b[:bi] + ["<<REAL_SCOPE>>"] + b[bj:]); cm = "\n".join(c[:ci] + ["<<REAL_SCOPE>>"] + c[cj:])
d = [x for x in difflib.ndiff(b[bi:bj], c[ci:cj]) if x[:1] in "+-"]
print("real_scope 块变化: %r" % d)
# real_scope 块遮成一行哨兵之后, 现在的全文必须恰好等于"基线全文 + 一个空行 + real-retire-hop-bc 整块(含其后的一个空行)+ real-first-upgrade 整块";
# 382: real-first-upgrade 必须恰 1 处、从它的 job 头一直到文件末尾、块内只有它一个 job 头(内容由 S-1 契约核), 不接受任意附加 job。
S1H = "\n  real-first-upgrade:\n"
if ctext.count(S1H) != 1:
    print("UNEXPECTED real-first-upgrade 的 job 头不是恰 1 处"); sys.exit(1)
s1 = ctext[ctext.index(S1H) + 1:]
if re.findall(r"^  ([a-z][a-z0-9-]*):$", s1, re.M) != ["real-first-upgrade"]:
    print("UNEXPECTED real-first-upgrade 之后还有别的 job 头"); sys.exit(1)
if cm == bm + "\n" + job + s1:
    print("APPEND 1 个空行 + real-retire-hop-bc(%d 行)+ real-first-upgrade(%d 行)" % (job.count("\n"), s1.count("\n"))); sys.exit(0)
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, bm.split("\n"), cm.split("\n"), autojunk=False).get_opcodes():
    if tag != "equal":
        print("UNEXPECTED %s 基线 %d-%d → 现 %d-%d" % (tag, i1 + 1, i2, j1 + 1, j2))
sys.exit(1)
PY
wrc=$?
if (( brc != 0 )); then bad "C4-11 基线 ci.yml 取不到(git show rc=$brc)"
elif (( wrc == 0 )); then ok "C4-11 相对 3dcaee00: workflow 只改了 real_scope 输入块, 其余改动只有文件末尾依次追加的 real-retire-hop-bc 与 real-first-upgrade(后者内容由 S-1 契约核)"
else bad "C4-11 workflow 有登记之外的改动: $(grep UNEXPECTED "$T/wf.txt" | head -3 | tr '\n' ' ')"; fi
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert d["jobs"]["real-retire-hop-bc"]["strategy"]["matrix"]["preimage"] == ["b", "c2"]' "$WF" \
    && ok "C4-12 整份 workflow 能按 YAML 解析, 新 job 的矩阵是 [b, c2]" || bad "C4-12 workflow 解析不过或矩阵不对"
else echo "[NOTE] C4-12 本机没有 PyYAML, YAML 解析这一格未验(文本核对已覆盖接线; 不计入通过)"; fi

echo; echo "══ 二. 静态: 共享输入、抽取块、禁用函数、静置前提 ══"
# C3: 共享输入相对基线逐字节不变(两侧各自读成功才比)
n3=0; why3=""
for rel in tests/e2e-real-platform-fail.sh tests/e2e-real-bridge-hop.sh tests/e2e-real-retire-hop.sh tests/e2e-real-late-failure.sh \
           tests/e2e-lib.sh tests/helpers/dns-stub.py tests/repoguard.sh tests/test-bridge-observation-contract.sh tests/test-bridge-extract-contract.sh; do
  if ! git -C "$ROOT" show "$BASE:$rel" > "$T/base-one" 2>/dev/null; then why3="$why3 $rel(基线取不到)"; continue; fi
  cmp -s -- "$T/base-one" "$ROOT/$rel"; r=$?
  case "$r" in 0) n3=$((n3+1));; 1) why3="$why3 $rel(变了)";; *) why3="$why3 $rel(比较失败 rc=$r)";; esac
done
[[ -z "$why3" && "$n3" == 9 ]] && ok "C3-1 ②③④⑤、e2e-lib、dns-stub、repoguard 与两份观测 / 抽取契约相对 3dcaee00 逐字节不变($n3 个)" \
  || bad "C3-1 共享输入不成立:$why3"
git -C "$ROOT" diff --name-only "$BASE" -- > "$T/changed.txt" 2>/dev/null; drc=$?
if (( drc != 0 )); then bad "C3-2 相对基线的改动清单取不到(git diff rc=$drc)"
else
  extra="$(grep -vxE 'tests/e2e-real-retire-hop-bc\.sh|tests/test-retire-hop-bc-contract\.sh|\.github/workflows/ci\.yml|tests/test-retire-hop-contract\.sh|tests/test-late-failure-contract\.sh|tests/e2e-real-first-upgrade\.sh|tests/test-first-upgrade-contract\.sh' "$T/changed.txt")"; grc=$?
  if (( grc == 1 )); then ok "C3-2 相对 3dcaee00 的已跟踪改动只在登记的七个文件之内(B / C2 的五个 + S-1 的两个新文件; $(grep -c . "$T/changed.txt") 个: $(tr '\n' ' ' < "$T/changed.txt"))"
  elif (( grc == 0 )); then bad "C3-2 登记之外还有改动: $(tr '\n' ' ' <<<"$extra")"
  else bad "C3-2 未取得: 改动清单筛选出错(grep rc=$grc) —— 不说成没有登记外改动"; fi
fi
# C1: 按新验收器自己的抽法(bc_seed → ③ r3_bootstrap → ② extract_marked_fns / decls)从"现在"与"基线"两侧各取一次, 逐名逐字比
mkdir -p "$T/c1/now" "$T/c1/base"
cp "$PLAT" "$T/c1/now/plat.sh"; cp "$HOP2" "$T/c1/now/hop2.sh"; cp "$R3" "$T/c1/now/r3.sh"
g1=0
git -C "$ROOT" show "$BASE:tests/e2e-real-platform-fail.sh" > "$T/c1/base/plat.sh" 2>/dev/null || g1=1
git -C "$ROOT" show "$BASE:tests/e2e-real-bridge-hop.sh" > "$T/c1/base/hop2.sh" 2>/dev/null || g1=1
git -C "$ROOT" show "$BASE:tests/e2e-real-retire-hop.sh" > "$T/c1/base/r3.sh" 2>/dev/null || g1=1
xfn(){   # $1=来源 $2=名字 → 只用来从新验收器里取出它自己的引导函数 bc_seed(之后一律用 bc_seed 与它引导出的抽取器)
  local src="$1" n="$2" b e
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] || return 1
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"; e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || return 1
  sed -n "$((b+1)),$((e-1))p" "$src"
}
if (( g1 == 0 )) && xfn "$BC" bc_seed > "$T/c1/seed.sh" && bash -n "$T/c1/seed.sh"; then
  # shellcheck source=/dev/null
  source "$T/c1/seed.sh"
  if bc_seed bc_lists "$BC" > "$T/c1/lists.sh" && bash -n "$T/c1/lists.sh" \
     && bc_seed r3_bootstrap "$T/c1/now/r3.sh" > "$T/c1/boot.sh" && bash -n "$T/c1/boot.sh"; then
    # shellcheck source=/dev/null
    source "$T/c1/lists.sh"; source "$T/c1/boot.sh"
    if r3_bootstrap "$T/c1/now/hop2.sh" "$T/c1/extractor.sh" extract_marked_fns extract_marked_decls; then
      # shellcheck source=/dev/null
      source "$T/c1/extractor.sh"
      n1=0; why1=""
      c1_one(){   # $1=取法 $2=来源文件名 $3=名字 → 两侧各取一次再比
        local how="$1" f="$2" n="$3" s r
        for s in now base; do
          case "$how" in
            seed) bc_seed "$n" "$T/c1/$s/$f" > "$T/c1/$s/x-$n" 2>/dev/null; r=$?;;
            boot) r3_bootstrap "$T/c1/$s/$f" "$T/c1/$s/x-$n" "$n" > /dev/null 2>&1; r=$?;;
            fns)  extract_marked_fns "$T/c1/$s/$f" "$T/c1/$s/x-$n" "$n" > /dev/null 2>&1; r=$?;;
            decls) extract_marked_decls "$T/c1/$s/$f" "$T/c1/$s/x-$n" "$n" > /dev/null 2>&1; r=$?;;
          esac
          (( r == 0 )) && [[ -s "$T/c1/$s/x-$n" ]] || { why1="$why1 $n($s 侧没取得: rc=$r 或为空);"; return 1; }
        done
        cmp -s -- "$T/c1/now/x-$n" "$T/c1/base/x-$n" || { why1="$why1 $n(与基线不同);"; return 1; }
        n1=$((n1+1))
      }
      c1_one seed r3.sh r3_bootstrap
      c1_one boot hop2.sh extract_marked_fns; c1_one boot hop2.sh extract_marked_decls
      for n in "${BC_PLAT_FNS[@]}"; do c1_one fns plat.sh "$n"; done
      for n in "${BC_PLAT_DECLS[@]}"; do c1_one decls plat.sh "$n"; done
      for n in "${BC_HOP2_FNS[@]}"; do c1_one fns hop2.sh "$n"; done
      for n in "${BC_R3_BLOCKS[@]}"; do c1_one boot r3.sh "$n"; done
      tot=$(( 3 + ${#BC_PLAT_FNS[@]} + ${#BC_PLAT_DECLS[@]} + ${#BC_HOP2_FNS[@]} + ${#BC_R3_BLOCKS[@]} ))
      [[ -z "$why1" && "$n1" == "$tot" && "$tot" -gt 3 ]] \
        && ok "C1-1 新验收器按自己的抽法取的 $n1 个共享块(含两支抽取器与 r3_bootstrap)与 3dcaee00 的同名块逐字相同, 两侧各自非空" \
        || bad "C1-1 共享块比对不成立($n1 / $tot):$why1"
    else bad "C1-1 ② 的抽取器引导失败 —— 共享块比对没做"; fi
  else bad "C1-1 新验收器的抽取清单或 ③ 的 r3_bootstrap 取不到 —— 共享块比对没做"; fi
else bad "C1-1 基线三份取不全或新验收器的 bc_seed 取不到 —— 共享块比对没做"; fi
# C2: 去注释(引号外的 #)后, 禁用函数不出现在命令位置; 判据自己先用一段合成文本做正反自检
FORBID=(r3_gated_invoke r3_runtime_gate r3_dns_phase r3_dns_adjust r3_dns_instrument r3_precapture r3_svc_verdict r3_svc_class r3_win_policy
        r3_modules r3_q_rec r3_quiesce r3_real2_gate r3_bridge_identity_gate r3_post_w1 r3_post_runtime deps_selfcheck bridge_set_check
        ledger_build keep_fp keep_compare ios_slot_verdict bridge_svc_class bridge_svc_verdict)
cmdpos_scan(){   # $1=文件 $2..=名字 → 打印"行号: 名字"(去掉引号外的注释后, 出现在命令位置的); 0 扫完 / 非 0 扫描失败
  python3 - "$@" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n"); names = sys.argv[2:]
def code(l):
    out, q, i = [], None, 0
    while i < len(l):
        c = l[i]
        if q:
            out.append(c)
            if c == "\\" and q == '"' and i + 1 < len(l):
                out.append(l[i + 1]); i += 2; continue
            if c == q:
                q = None
        elif c in "'\"":
            q = c; out.append(c)
        elif c == "#" and (i == 0 or l[i - 1] in " \t;"):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)
pre = r"(?:^|[;&|({]|\$\(|\b(?:then|do|else|elif|if|while|until)\b|!)\s*"
pat = re.compile(pre + r"(%s)(?=$|[\s;)|&])" % "|".join(map(re.escape, names)))
for i, l in enumerate(lines, 1):
    if l.lstrip().startswith("#"):
        continue
    for m in pat.finditer(code(l)):
        print("%d: %s" % (i, m.group(1)))
PY
}
c2_scan(){ cmdpos_scan "$1" "${FORBID[@]}"; }
printf '%s\n' '  r3_quiesce || return 16' 'x="$(r3_modules a b)"' 'if ! r3_precapture; then :; fi' \
  '# r3_quiesce 只是注释' 'r3_bootstrap f out r3_quiesce r3_dns' 'echo "r3_quiesce 是字符串"' 'r3_quiesce_x(){ :; }' > "$T/c2-self.sh"
c2_scan "$T/c2-self.sh" > "$T/c2-self.out"; s2=$?
if (( s2 == 0 )) && [[ "$(grep -c . "$T/c2-self.out")" == 3 ]] \
   && grep -qx '1: r3_quiesce' "$T/c2-self.out" && grep -qx '2: r3_modules' "$T/c2-self.out" && grep -qx '3: r3_precapture' "$T/c2-self.out"; then
  ok "C2-0 禁用调用判据自检: 合成文本里 3 处真调用都抓到, 注释 / 抽取清单 / 字符串 / 同前缀的别名 4 处都不误报"
else bad "C2-0 禁用调用判据自检不过(rc=$s2): $(tr '\n' ' ' < "$T/c2-self.out")"; fi
c2_scan "$BC" > "$T/c2.out"; s2=$?
if (( s2 != 0 )); then bad "C2-1 禁用调用扫描失败(rc=$s2) —— 不说成没有"
elif [[ -s "$T/c2.out" ]]; then bad "C2-1 新验收器调用了仅参考结构 / 不用的函数: $(tr '\n' ' ' < "$T/c2.out")"
else ok "C2-1 新验收器的代码里不调用 ${#FORBID[@]} 个仅参考结构 / 不用的函数(命令位置逐行扫; 抽进来的块里有它们的定义也不调用)"; fi
# C5: 静置的计划秒数与限额前提取自 ③ 块原文, 新验收器不赋值覆盖
grep -vE '^\s*#' "$BC" > "$T/bccode.txt"; CRC=$?; CODE_OK=0
(( CRC == 0 )) && [[ -s "$T/bccode.txt" ]] && CODE_OK=1
if (( CODE_OK == 1 )); then ok "S-0 新验收器的去注释代码已取得($(grep -c '' "$T/bccode.txt") 行)"
else bad "S-0 新验收器的去注释代码没取得(grep rc=$CRC) —— 依赖它的'没有 …'核对一律判未取得"; fi
s5="$(cstate '(^|[^A-Za-z0-9_])R3_Q_(UNIT|INT|BURST|SECS|NEED_NS)=')"
if [[ "$s5" == 有 ]]; then bad "C5-2 新验收器自己给 R3_Q_* 赋值了"
elif [[ "$s5" != 无 ]]; then bad "C5-2 未取得($s5) —— 不说成没有赋值"
elif [[ -s "$T/c1/now/x-r3_quiesce" ]] && grep -qxF 'R3_Q_UNIT=pdg-dotwitness; R3_Q_INT=5min; R3_Q_BURST=5; R3_Q_SECS=303; R3_Q_NEED_NS=303000000000' "$T/c1/now/x-r3_quiesce"; then
  ok "C5-2 两段静置的计划秒数 303 与限额前提 5min / 5 取自 ③ r3_quiesce 块原文, 新验收器不赋值覆盖"
else bad "C5-2 ③ 块里的静置前提没取到或不是 303 / 5min / 5"; fi
# 其它静态边界
grep -qx 'set -uo pipefail' "$BC" && ok "S-1 新验收器以 set -uo pipefail 运行" || bad "S-1 新验收器没有 set -uo pipefail"
cmdpos_scan "$BC" r3_invoke > "$T/s2.out"; s2=$?
(( s2 == 0 )) && [[ "$(grep -c . "$T/s2.out")" == 1 ]] \
  && ok "S-2 第三跳升级入口只有一处: ③ 原样的 r3_invoke(在 bc_gated_invoke 的门之后)" || bad "S-2 r3_invoke 的调用点不是恰一处(扫描 rc=$s2: $(tr '\n' ' ' < "$T/s2.out"))"
s3="$(cstate '(^|[^-])PDG_UPDATE_SVCSTATE=|export +PDG_UPDATE_SVCSTATE')"
case "$s3" in
  无) ok "S-3 新验收器不预置能力句柄 PDG_UPDATE_SVCSTATE(只 env -u 清掉)";;
  有) bad "S-3 新验收器预置了 PDG_UPDATE_SVCSTATE";;
  *) bad "S-3 未取得($s3) —— 不说成不预置";;
esac
fi   # ONLY 为空时才跑一 / 二

echo; echo "══ 三. 模型格(按唯一成对标记抽原文, 受控输入驱动) ══"
xfn2(){ local src="$1" n b e; shift   # 引导 bc_seed 用(与二节同一取法)
  for n in "$@"; do
    [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] || return 1
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"; e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    sed -n "$((b+1)),$((e-1))p" "$src"
  done; }
BCB=(bc_fs bc_wrap bc_fp bc_build bc_gate bc_identity bc_svc bc_quiesce bc_dns bc_fw bc_hop2 bc_pre3 bc_gate3 bc_post bc_main)
mok=1
xfn2 "$BC" bc_seed bc_lists > "$T/m-seed.sh" && bash -n "$T/m-seed.sh" || mok=0
if (( mok )); then
  # shellcheck source=/dev/null
  source "$T/m-seed.sh"
  ( for n in "${BCB[@]}"; do bc_seed "$n" "$BC" || exit 1; done ) > "$T/bcfns.sh" && bash -n "$T/bcfns.sh" || mok=0
  bc_seed r3_bootstrap "$R3" > "$T/m-boot.sh" && bash -n "$T/m-boot.sh" || mok=0
fi
if (( mok )); then
  # shellcheck source=/dev/null
  source "$T/m-boot.sh"
  r3_bootstrap "$HOP2" "$T/m-extractor.sh" extract_marked_fns extract_marked_decls > /dev/null || mok=0
fi
if (( mok )); then
  # shellcheck source=/dev/null
  source "$T/m-extractor.sh"
  extract_marked_fns "$PLAT" "$T/plat-fns.sh" "${BC_PLAT_FNS[@]}" > /dev/null || mok=0
  extract_marked_decls "$PLAT" "$T/plat-deps.sh" "${BC_PLAT_DECLS[@]}" > /dev/null || mok=0
  extract_marked_fns "$HOP2" "$T/hop2-fns.sh" "${BC_HOP2_FNS[@]}" > /dev/null || mok=0
  r3_bootstrap "$R3" "$T/r3fns.sh" "${BC_R3_BLOCKS[@]}" > /dev/null || mok=0
fi
if (( mok )); then ok "M-0 按新验收器的抽法取出 ${#BCB[@]} 个被测块与它实际复用的共享块(语法通过)"
else bad "M-0 抽取失败 —— 模型格不执行"; fin; fi

# ── 受控夹具: 三棵假源码树(旧版 / 桥接 / 退役)、入口流程、替身命令 ──────────────────────
OLDSHA=1111111111111111111111111111111111111111; BRSHA=2222222222222222222222222222222222222222; RTSHA=3333333333333333333333333333333333333333
FX="$T/fx"; mkdir -p "$FX/old/deploy/bot" "$FX/old/lib" "$FX/br/deploy/bot" "$FX/br/lib" "$FX/br/docs" "$FX/rt/deploy/bot" "$FX/rt/lib" "$T/bin"
for t in old br rt; do
  printf 'pdg_platform_modules(){ printf "%%s\\n" "deploy/bot/a.py a.py 644"; [[ "${1:-}" == ios ]] && printf "%%s\\n" "deploy/bot/i.py i.py 644"; [[ "${1:-}" == android ]] && printf "%%s\\n" "deploy/bot/d.py d.py 644"; return 0; }\n' > "$FX/$t/lib/modules.sh"
  for m in a i d; do printf '%s-%s\n' "$t" "$m" > "$FX/$t/deploy/bot/$m.py"; done
done
# 入口替身: 各自把调用追加进自己的记录文件(与被测脚本无关的独立记录)
cat > "$FX/old/deploy/bot/pdg.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BC_STUB_OLD:?}"
[[ -z "${BC_OLD_OUT:-}" ]] || printf '%b\n' "$BC_OLD_OUT"
if [[ -n "${BC_OLD_EFFECT:-}" ]]; then bash -c "$BC_OLD_EFFECT" || exit 97; fi
exit "${BC_OLD_RC:-0}"
EOS
cat > "$FX/br/deploy/bot/pdg.sh" <<'EOS'
#!/usr/bin/env bash
_pdg_save_svcstate(){ :; }
printf '%s\n' "$*" >> "${BC_STUB_HOP3:?}"
exit "${BC_HOP3_RC:-0}"
EOS
cat > "$FX/rt/deploy/bot/pdg.sh" <<'EOS'
#!/usr/bin/env bash
migrate_wloc_retire(){ :; }
exit 0
EOS
cat > "$FX/br/docs/BRIDGE-ENTRY.md" <<'EOS'
# 桥接入口(契约夹具)
```bash
# --- pdg-bridge-entry-flow: BEGIN
printf 'hop2 TAG=%s WANT=%s ENTRY=%s SRC=%s\n' "$TAG" "$WANT" "$ENTRY" "$SRC" >> "${BC_STUB_HOP2:?}"
echo "✅ 身份核对通过"
if [[ -n "${BC_HOP2_EFFECT:-}" ]]; then bash -c "$BC_HOP2_EFFECT" || exit 97; fi
echo "钉版目标已贯穿到实际安装: $TAG → $WANT"
echo "✅ 已更新。"
: sudo bash "$ENTRY/deploy/bot/pdg.sh" update --to "$TAG"
exit "${BC_HOP2_RC:-0}"
# --- pdg-bridge-entry-flow: END
```
EOS
# systemctl 替身: 应答表每行「键|退出码|stdout(可含 \n)|stderr」, 键 = "<子命令> <unit>" 或 "show:<属性> <unit>"(无 unit 记 -);
# 查找顺序: 键#第N次 → 键 → "<子命令或属性> *"#第N次 → "<子命令或属性> *"; restart 成功换"实例"(InvocationID / MainPID 随之变),
# mosdns 换实例时按启动时加载的口径快照接管表 / geosite_cn / 明确代理集 / local_upstream 那一行。
cat > "$T/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
if [[ "${1:-}" == show ]]; then
  p=""; prev=""; for a in "$@"; do [[ "$prev" == -p ]] && p="$a"; prev="$a"; done
  verb="show:$p"; u="${!#}"
else
  verb="${1:-}"; u="-"; for a in "${@:2}"; do [[ "$a" == -* ]] || { u="$a"; break; }; done
fi
k="$verb $u"
echo "systemctl $*" >> "$FK"
cf="$FKDIR/n-${k//[^A-Za-z0-9._-]/_}"; n=0; [[ -f "$cf" ]] && n="$(<"$cf")"; n=$((n+1)); echo "$n" > "$cf"
wants=("$k#$n" "$k" "$verb *#$n" "$verb *"); best=4; hit=""
while IFS= read -r line; do
  l="${line%%|*}"
  for ((i = 0; i < best; i++)); do [[ "$l" == "${wants[i]}" ]] && { best=$i; hit="$line"; break; }; done
  (( best == 0 )) && break
done < "$SCFIX"
(( best < 4 )) || { echo "替身表里没有 [$k]" >&2; exit 99; }
r="${hit#*|}"; rc="${r%%|*}"; r="${r#*|}"; out="${r%%|*}"; err="${r#*|}"
echo "served ${wants[best]} -> rc=$rc" >> "$FK"
if [[ "$verb" == restart && "$rc" == 0 ]]; then
  rn=0; [[ -f "$FKDIR/restarts-$u" ]] && rn="$(<"$FKDIR/restarts-$u")"; rn=$((rn + 1)); echo "$rn" > "$FKDIR/restarts-$u"
  if [[ "$u" == mosdns && -n "${FAKE_RO_AT_RESTART:-}" && "$rn" == "$FAKE_RO_AT_RESTART" ]]; then
    chmod a-w -- "${HIJ_PATH:?}" && echo "served hij-readonly" >> "$FK"
  fi
  g=0; [[ -f "$FKDIR/gen-$u" ]] && g="$(<"$FKDIR/gen-$u")"; g=$((g + 1)); echo "$g" > "$FKDIR/gen-$u"
  [[ "$u" != mosdns ]] || "$(dirname "$0")/pdg-model-snap" "$FKDIR/snap-$g"
  echo "served model-gen $u=$g" >> "$FK"
fi
g=0; [[ -f "$FKDIR/gen-$u" ]] && g="$(<"$FKDIR/gen-$u")"
printf -v gid '%032x' $((0xabc000 + g))
out="${out//%u/$u}"; out="${out//%G/$gid}"; out="${out//%P/$((5000 + g))}"
printf '%b' "$out"; [[ -z "$err" ]] || printf '%s\n' "$err" >&2; exit "$rc"
EOS
cat > "$T/bin/pdg-model-snap" <<'EOS'
#!/usr/bin/env bash
d="$1"; m="${MODEL_DIR:?}"; mkdir -p "$d" || exit 1
cat "$m/rules/mitm_hijack.txt" > "$d/hij" 2>/dev/null || : > "$d/hij"
cat "$m/rules/geosite_cn.txt" > "$d/cn" 2>/dev/null || : > "$d/cn"
cat "$m/rules/custom_hijack.txt" "$m/rules/ruleset_hijack.txt" > "$d/xp" 2>/dev/null || : > "$d/xp"
awk '/^  - tag: local_upstream$/{f=1; next} f && /^    args:/{print; exit}' "$m/config.yaml" > "$d/upline"
EOS
cat > "$T/bin/git" <<'EOS'
#!/usr/bin/env bash
# 只读替身: 只认 r3_head 的形态(-C <目录> rev-parse …), 答 $BC_EFF_HEADF 里的提交; 其余一律拒绝
echo "git $*" >> "${FK:?}"
if [[ "${1:-}" == -C && "${3:-}" == rev-parse ]]; then echo "served git-head" >> "$FK"; cat -- "${BC_EFF_HEADF:?}" 2>/dev/null || exit 128; exit 0; fi
echo "git 替身不认识: $*" >&2; exit 99
EOS
cat > "$T/bin/fake-mono" <<'EOS'
#!/usr/bin/env bash
cf="$FKDIR/mono-n"; n=0; [[ -f "$cf" ]] && n="$(<"$cf")"; n=$((n + 1)); echo "$n" > "$cf"
v=$(( 1000000000000 + (n - 1) * ${FAKE_MONO_STEP:-303000000000} ))
printf '%s\n' "$v"; echo "served mono n=$n -> $v" >> "$FK"
EOS
chmod +x "$T/bin"/* "$FX"/*/deploy/bot/pdg.sh
cat > "$T/fake-stub.py" <<'EOS'
import os, sys, time
a = sys.argv[1:]
def arg(k):
    return a[a.index(k) + 1]
if os.environ.get("FAKE_STUB_PIDS"):
    with open(os.environ["FAKE_STUB_PIDS"], "a") as f:
        f.write("%d\n" % os.getpid())
open(arg("--count"), "a").close()
with open(arg("--log"), "a") as f:
    f.write("started mode=%s port=%s\n" % (arg("--mode"), arg("--port")))
print("stub ready 127.0.0.1:%s mode=%s" % (arg("--port"), arg("--mode")), flush=True)
time.sleep(float(os.environ.get("FAKE_STUB_LIFE", "120")))
EOS
printf '%s\n' 'show:Id *|0|%u.service\n|' 'show:LoadState *|0|loaded\n|' 'show:Type *|0|simple\n|' 'show:NRestarts *|0|0\n|' \
  'show:ActiveState *|0|active\n|' 'show:SubState *|0|running\n|' 'show:UnitFileState *|0|enabled\n|' 'show:MainPID *|0|%P\n|' \
  'show:InvocationID *|0|%G\n|' 'show:StartLimitIntervalUSec *|0|5min\n|' 'show:StartLimitBurst *|0|5\n|' \
  'is-active *|0|active\n|' 'is-enabled *|0|enabled\n|' 'restart *|0||' 'enable *|0||' 'daemon-reload *|0||' > "$T/sc-ok.tab"
mktab(){ local f="$T/sc-$1.tab"; shift; printf '%s\n' "$@" > "$f"; cat "$T/sc-ok.tab" >> "$f"; }   # 覆盖行在前, 其余照健康表
mktab mitm-gone 'show:LoadState pdg-mitm|0|not-found\n|' 'is-active pdg-mitm|3|inactive\n|' 'show:ActiveState pdg-mitm|0|inactive\n|'
# mosdns 夹具: 形状取自 v1.11.15 模板 all 形态(与 ③ 契约同一形状); 规则文件同 e2e_seed_mosdns, 接管表空(B / C2 第二跳后的形态)
mkmos(){   # $1=目录
  local d="$1"; mkdir -p "$d/rules"
  printf '%s\n' 'domain:baidu.com' > "$d/rules/geosite_cn.txt"
  : > "$d/rules/mitm_hijack.txt"; printf '%s\n' 'domain:blocked.test' > "$d/rules/geosite_gfw.txt"
  : > "$d/rules/geosite_apple.txt"; : > "$d/rules/custom_direct.txt"; : > "$d/rules/custom_hijack.txt"; : > "$d/rules/ruleset_hijack.txt"
  : > "$d/rules/geosite_geolocation-!cn.txt"
  sed "s#@D@#$d#g" > "$d/config.yaml" <<'EOS'
log:
  level: warn
plugins:
  - tag: remote_upstream
    type: forward
    args: { concurrent: 2, upstreams: [ {addr: "https://1.1.1.1/dns-query"}, {addr: "udp://8.8.8.8:53"} ] }
  - tag: local_upstream
    type: forward
    args: { concurrent: 2, upstreams: [ {addr: "https://223.5.5.5/dns-query"}, {addr: "udp://223.5.5.5:53"} ] }
  - tag: geosite_cn
    type: domain_set
    args: { files: ["@D@/rules/geosite_cn.txt","@D@/rules/geosite_apple.txt","@D@/rules/custom_direct.txt"] }
  - tag: hijack_set
    type: domain_set
    args: { files: ["@D@/rules/geosite_geolocation-!cn.txt","@D@/rules/custom_hijack.txt"] }
  - tag: force_hijack
    type: domain_set
    args: { files: ["@D@/rules/mitm_hijack.txt"] }
  - tag: explicit_proxy
    type: domain_set
    args: { files: ["@D@/rules/custom_hijack.txt","@D@/rules/ruleset_hijack.txt"] }
  - tag: internal_sequence
    type: sequence
    args:
      - exec: $lazy_cache
      - matches: qname $force_hijack
        exec: goto force_hijack_seq
      - matches: qname $explicit_proxy
        exec: goto explicit_proxy_seq
      - matches: qname $geosite_cn
        exec: $local_upstream
      - matches: qtype 1
        exec: black_hole 203.0.113.1
EOS
}
row(){ local u="$1"; shift; printf '%s\t%s.service\tservice\tsimple\t%s\t%s\t%s\t%s\t%s\t%s\t0\tprobe\t%s\n' "$u" "$u" "$@"; }   # u load act sub ufs pid inv valid
{ row pdg-mitm loaded active running enabled 100 0123456789abcdef0123456789abcdef ok
  row mosdns loaded active running enabled 200 fedcba9876543210fedcba9876543210 ok
  row sing-box not-found inactive dead "" 0 - ok; } > "$T/svc-fix-ok.tsv"
FORBID_M=(r3_gated_invoke r3_runtime_gate r3_dns_phase r3_dns_adjust r3_dns_instrument r3_precapture r3_svc_verdict r3_svc_class r3_win_policy
          r3_modules r3_q_rec r3_quiesce r3_real2_gate r3_bridge_identity_gate r3_post_w1 r3_post_runtime bridge_set_check ios_slot_verdict)
: > "$T/forbidden.log"

# 在子壳里跑一格: 装载被测原文 + 受控变量; $1=格名 $2=要执行的代码。格里显式登记的替身: 外部命令(systemctl / git / fake-mono 在 $T/bin;
# dig / ss / curl / sleep 是格内函数, 每次被调都记进 $FK)与叶子函数(各格自己替换, 写进 $C/leaf.log)。
cell(){ local C="$T/cell-$1" nonce="$RANDOM$RANDOM$RANDOM"
  printf '%s\n' "$nonce" > "$T/nonce-$1"   # 本格结束标记里的随机串: 子壳没走完 eval 就印不出这一行
  mkdir -p "$C/bin" "$C/evid" "$C/wk" "$C/etc" "$C/mod" "$C/fk" "$C/repo" "$C/art" "$C/backups" "$C/units"
  ( set +u
    source "$T/plat-fns.sh"; source "$T/plat-deps.sh"; source "$T/hop2-fns.sh"; source "$T/r3fns.sh"; source "$T/bcfns.sh"
    ok(){ echo "VOK $1"; }; bad(){ echo "VBAD $1"; }; note(){ echo "VNOTE $1"; }; nrun(){ echo "VNRUN $1"; E2E_NOTRUN=$((E2E_NOTRUN+1)); }
    SECT(){ echo "VSECT $*"; }; _evn(){ printf '%s\n' "$2" >> "$EVID/$1"; }; _ev(){ cat >> "$EVID/$1"; }
    for f in "${FORBID_M[@]}"; do eval "$f(){ echo \"$1 $f\" >> \"$T/forbidden.log\"; return 1; }"; done
    leaf(){ printf '%s\n' "$*" >> "$C/leaf.log"; }
    EVID="$C/evid"; BC_TMP="$C/wk"; R3_TMP="$C/wk"; E2E_TMP="$C/wk"; export E2E_TMP
    BC_PRE=b; BC_PLAT=ios; E2E_NOTRUN=0; JBOUND_TAG=pdg-e2e-jbound-bcc; J_ERR=""; E2E_SIP=203.0.113.1
    OLD_SHA="$OLDSHA"; BRIDGE_SHA="$BRSHA"; RETIRE_SHA="$RTSHA"; BRIDGE_TAG=v9.9.8-bridge-TEST; RETIRE_TAG=v9.9.9-retire-TEST
    OLDSRC="$FX/old"; BRSRC="$FX/br"; R3_RTSRC="$FX/rt"; ORIGIN="$C/origin.git"
    R3_REPO="$C/repo"; R3_CLI="$C/cli"; R3_MODDIR="$C/mod"; R3_ETC="$C/etc"; R3_OBJ="$C/obj"
    IOS_META="$C/etc/ios-profile.json"; IOS_ART="$C/art"; MJ="$C/etc/mitm.json"; CA_DIR="$C/etc/ca"; MC="$C/mc.yaml"
    SNAPROOT="$C/backups"; BC_MITM_UNIT="$C/units/pdg-mitm.service"
    BC_IOS_ONLY=(mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl)
    R3_LOG="$C/wk/hop3.log"; R3_RCFILE="$C/wk/hop3.rc"; R3_TOERR="$C/wk/hop3.toe"; R3_TIMEOUT=30; BC_HOP2_TIMEOUT=30; BC_OLD_TIMEOUT=30
    BC_CNT_HOP2="$EVID/00-hop2-invoke-count.txt"; BC_CNT_HOP3="$EVID/00-hop3-invoke-count.txt"; BC_CNT_OLD="$EVID/00-old-cli-invoke-count.txt"
    R3_COUNT="$BC_CNT_HOP3"; bc_count_init "$BC_CNT_HOP2"; bc_count_init "$BC_CNT_HOP3"; bc_count_init "$BC_CNT_OLD"
    declare -gA KFP=() BC_FP=() BC_SVC_ROWS=(); KREQ=(); KOPT=()
    SVC_WATCH=(pdg-mitm mosdns sing-box); SVC_FIX="$T/svc-fix-ok.tsv"
    mkmos "$C/mos"; R3_MOSCFG="$C/mos/config.yaml"; R3_GEOCN="$C/mos/rules/geosite_cn.txt"; HIJ="$C/mos/rules/mitm_hijack.txt"
    R3_STUB="$T/fake-stub.py"; R3_STUB_PID=""; R3_DNS_RESTARTS=0; R3_DNS_U=198.51.100.7; R3_DNS_PORT=15301; R3_DNS_W=gs-loc.apple.com
    R3_UPLOG="$C/wk/dns-up.log"; R3_UPCNT="$C/wk/dns-up.count"; R3_UPOUT="$C/wk/dns-up.out"; R3_MONO=("$T/bin/fake-mono")
    R3_DNS_K=bck-t.e2e.test; R3_DNS_CPRE=bcc-pre-t.e2e.test; R3_DNS_CPOST=bcc-post-t.e2e.test; R3_DNS_PPRE=bcp-pre-t.e2e.test; R3_DNS_PPOST=bcp-post-t.e2e.test
    export BC_STUB_HOP2="$C/calls-hop2" BC_STUB_HOP3="$C/calls-hop3" BC_STUB_OLD="$C/calls-old" BC_EFF_HEADF="$C/head"
    : > "$BC_STUB_HOP2"; : > "$BC_STUB_HOP3"; : > "$BC_STUB_OLD"; : > "$C/leaf.log"
    export PATH="$C/bin:$T/bin:$PATH" FK="$C/fk.log" FKDIR="$C/fk" SCFIX="$T/sc-ok.tab" MODEL_DIR="$C/mos" HIJ_PATH="$C/mos/rules/mitm_hijack.txt" FAKE_STUB_PIDS="$T/stub-pids"
    : > "$FK"
    # shellcheck disable=SC2064  # 有意此刻展开: 登记的是函数名本身
    e2e_add_exit_hook(){ echo "hook $1" >> "$FK"; trap "$1" EXIT; }
    sleep(){ echo "sleep $*" >> "$FK"; [[ "${1:-}" != 0.* ]] || command sleep 0.02; }
    curl(){ echo "curl $*" >> "$FK"; printf '%s' "${FAKE_CURL_OUT-200}"; return "${FAKE_CURL_RC:-0}"; }
    ss(){ echo "ss $*" >> "$FK"; printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
      [[ -z "${FAKE_SS_PORT:-}" ]] || printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*\n' "$FAKE_SS_PORT"; }
    bridge_svc_sample(){ echo "bridge_svc_sample $1" >> "$FK"; cp "$SVC_FIX" "$1"; }
    _j_mark(){ echo "j_mark $1" >> "$FK"; echo "cur-$1"; }
    model_in(){ local l v; [[ -f "$1" ]] || return 1
      while IFS= read -r l || [[ -n "$l" ]]; do l="${l%%#*}"; l="${l//[[:space:]]/}"; [[ -n "$l" ]] || continue
        case "$l" in full:*) [[ "$2" == "${l#full:}" ]] && return 0;; keyword:*) [[ "$2" == *"${l#keyword:}"* ]] && return 0;;
          *) v="${l#domain:}"; [[ "$2" == "$v" || "$2" == *".$v" ]] && return 0;; esac
      done < "$1"; return 1; }
    model_uplog(){ printf '1790000000.000 q=%s len=40\n' "$1" >> "$R3_UPLOG"; printf '1\n' >> "$R3_UPCNT"; echo "served model-uplog $1" >> "$FK"; }
    dig(){ echo "dig $*" >> "$FK"   # mosdns 行为模型: 接管 → H; 明确代理 → H; geosite_cn → local_upstream(指向自有上游且它在 ⇒ U 并代写上游记录); 其余 → all 劫持 H
      local q="${4,,}" g sn cd ans="" st=NOERROR n=0
      g=0; [[ -f "$FKDIR/gen-mosdns" ]] && g="$(<"$FKDIR/gen-mosdns")"
      sn="$FKDIR/snap-$g"; cd="$FKDIR/cache-$g"; [[ -d "$sn" ]] || pdg-model-snap "$sn"; mkdir -p "$cd"
      if [[ -f "$cd/$q" ]]; then ans="$(<"$cd/$q")"; echo "served model-cache $q" >> "$FK"
      elif model_in "$sn/hij" "$q" && [[ -z "${FAKE_MODEL_NOHIJ:-}" ]]; then ans=203.0.113.1
      elif model_in "$sn/xp" "$q"; then ans=203.0.113.1
      elif model_in "$sn/cn" "$q"; then
        model_in "$sn/hij" "$q" && echo "served model-nohij $q" >> "$FK"
        if [[ "$(<"$sn/upline")" != *'"udp://127.0.0.1:15301"'* ]]; then ans=17.253.0.1
        elif [[ -n "${R3_STUB_PID:-}" ]] && kill -0 "$R3_STUB_PID" 2>/dev/null; then
          ans=198.51.100.7
          if [[ "$q" == "${FAKE_NOLOG_ON:-}" ]]; then echo "served model-nolog $q" >> "$FK"; else model_uplog "$q"; fi
        else st=SERVFAIL; fi
      else ans=203.0.113.1; fi
      if [[ "$q" == "${FAKE_HLOG_ON:-}" && "$ans" == 203.0.113.1 ]]; then echo "served model-hlog $q" >> "$FK"; model_uplog "$q"; fi
      [[ -z "$ans" ]] || printf '%s' "$ans" > "$cd/$q"
      [[ -n "$ans" ]] && n=1
      printf '; <<>> DiG 9.18(契约模型) <<>> @127.0.0.1 %s A\n;; global options: +cmd\n;; Got answer:\n' "$q"
      printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 4242\n;; flags: qr rd ra; QUERY: 1, ANSWER: %s, AUTHORITY: 0, ADDITIONAL: 1\n\n' "$st" "$n"
      printf ';; QUESTION SECTION:\n;%s.\t\t\tIN\tA\n\n' "$q"
      if (( n > 0 )); then printf ';; ANSWER SECTION:\n%s.\t\t300\tIN\tA\t%s\n\n' "$q" "$ans"; fi
      printf ';; Query time: 0 msec\n;; SERVER: 127.0.0.1#53(127.0.0.1) (UDP)\n;; MSG SIZE  rcvd: 61\n'
      return 0; }
    eval "$2"
    printf '__BCC_END__ %s\n' "$nonce"
    exit 0 ) > "$T/out-$1" 2>&1
  printf '%s\n' "$?" > "$T/crc-$1"           # 子壳原始退出码(结束标记之后以 0 退出; 半途 exit / 崩掉都留在这里)
}
# 结算一律经 rdf 整份读出并核读取退出码; 读不了、读到一半失败的内容不采信。调用 / 记账记录不存在或读不了 ⇒ "?", 不是 0 次。
cellok(){   # $1=格 → 是 / 否: 子壳原始退出码 0, 且本格结束标记恰 1 行
  local nonce rc n=0 l
  rdf "$T/crc-$1" || { echo 否; return; }; rc="$RDV"
  rdf "$T/nonce-$1" || { echo 否; return; }; nonce="$RDV"
  rdf "$T/out-$1" || { echo 否; return; }
  while IFS= read -r l; do [[ "$l" == "__BCC_END__ $nonce" ]] && n=$((n+1)); done <<<"$RDV"
  if [[ "$rc" == 0 && -n "$nonce" && "$n" == 1 ]]; then echo 是; else echo 否; fi
}
O_(){ if rdf "$T/out-$1"; then printf '%s\n' "$RDV"; fi; }   # 一格的完整输出(读不了 ⇒ 空; 依赖它的条件因此不成立)
has(){ rdf "$T/out-$1" || return 2; [[ "$RDV" == *"$2"* ]]; }
lacks(){ rdf "$T/out-$1" || return 2; [[ "$RDV" != *"$2"* ]]; }        # 读得到且不含才算"没有"
nostart(){ local l; rdf "$T/out-$1" || return 2; while IFS= read -r l; do [[ "$l" == "$2"* ]] && return 1; done <<<"$RDV"; return 0; }
fhas(){ rdf "$1" || return 2; [[ "$RDV" == *"$2"* ]]; }
flacks(){ rdf "$1" || return 2; [[ "$RDV" != *"$2"* ]]; }
fline(){ local l; rdf "$1" || return 2; while IFS= read -r l; do [[ "$l" == "$2" ]] && return 0; done <<<"$RDV"; return 1; }
nofline(){ fline "$@"; [[ $? == 1 ]]; }
nlines(){   # $1=文件 → 非空行数; 不存在 / 读不了 / 读到一半失败 ⇒ ?
  local l n=0
  rdf "$1" || { echo '?'; return; }
  [[ -z "$RDV" ]] || while IFS= read -r l; do [[ -n "$l" ]] && n=$((n+1)); done <<<"$RDV"
  echo "$n"
}
fcnt(){   # $1=文件 $2=行首 $3=行内片段 → 同时满足的行数; 读不了 ⇒ ?
  local l n=0
  rdf "$1" || { echo '?'; return; }
  while IFS= read -r l; do [[ "$l" == "$2"* && "$l" == *"$3"* ]] && n=$((n+1)); done <<<"$RDV"
  echo "$n"
}
cnt(){ if rdf "$T/cell-$1/evid/00-$2-invoke-count.txt" && [[ "$RDV" =~ ^(0|[1-9][0-9]*)$ ]]; then echo "$RDV"; else echo '?'; fi; }   # 被测脚本自记的计数
calls(){ nlines "$T/cell-$1/calls-$2"; }                                                    # 入口替身的独立记录
served(){ local l n=0; rdf "$T/cell-$1/fk.log" || { echo '?'; return; }; while IFS= read -r l; do [[ "$l" == *"served $2"* ]] && n=$((n+1)); done <<<"$RDV"; echo "$n"; }
fkn(){ local l n=0; rdf "$T/cell-$1/fk.log" || { echo '?'; return; }; while IFS= read -r l; do [[ "$l" != "served "* && "$l" == "$2"* ]] && n=$((n+1)); done <<<"$RDV"; echo "$n"; }
rcof(){   # $1=格 → 结果有效(整份读出、RC 行恰 1 行、值是 0–255 的十进制退出码)时打印该值并返回 0; 否则打印 ? 并返回 1(缺失 / 重复 / 空 / 非法 / 读不了 ⇒ 结果未取得)
  local l v="" n=0
  rdf "$T/out-$1" || { echo '?'; return 1; }
  while IFS= read -r l; do [[ "$l" == RC=* ]] && { n=$((n+1)); v="${l#RC=}"; }; done <<<"$RDV"
  if (( n == 1 )) && [[ "$v" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( v <= 255 )); then printf '%s\n' "$v"; else echo '?'; return 1; fi
}
rcst(){   # $1=格 $2=比较(== / !=) $3=返回码 → 结果有效时 是 / 否; 结果未取得时打印"结果未取得", 不参与 0 / 非 0 或具体返回码的比较
  local v
  v="$(rcof "$1")" || { echo 结果未取得; return; }
  case "$2" in   # 比较符写死成两支; 两侧都加引号 = 字面比较(不当通配); 不认识的比较符不给"是"
    ==) if [[ "$v" == "$3" ]]; then echo 是; else echo 否; fi;;
    !=) if [[ "$v" != "$3" ]]; then echo 是; else echo 否; fi;;
    *) echo "期望写错(比较符 $2)";;
  esac
}
rc01(){ case "$2" in 0) rcst "$1" == 0;; 非0) rcst "$1" != 0;; *) echo "期望写错($2)";; esac; }   # $1=格 $2=期望(0 / 非0); hcase 用, 结果未取得不归入 0 或非 0
judge(){   # $1=格 $2=说明 $3..=条件名=是/否 → 全是"是"才 OK(第一项固定是本格执行有效); 失败时逐项列出(撤销对照据此区分"判定"与"原因")
  local id="$1" what="$2" c all=1 s=""; shift 2
  set -- "有效=$(cellok "$id")" "$@"
  for c in "$@"; do s="$s ${c%%=*}=${c#*=}"; [[ "${c#*=}" == 是 ]] || all=0; done
  if (( all )); then ok "$id $what($s )"; else bad "$id $what —— 不成立:$s; 输出(前 6 行; 按行取, 不按字节截): $(head -6 "$T/out-$id" | tr '\n' ' '); 格内失败行: $(grep -a '^VBAD' "$T/out-$id" | tr '\n' ' ')"; fi
}
yn(){ if "$@"; then echo 是; else echo 否; fi; }

# ── V: 契约自身的执行与读取有效性(元测试: 用合成格核上面的结算链本身; 不经 judge) ──
mt(){ if eval "$2"; then ok "$1"; else bad "$1 —— 不成立"; fi; }   # $1=格与说明 $2=在父壳里求值的条件
mkdir -p "$T/mbin"                                                  # 读取替身: 先打印像样的内容再以 1 退出(先输出后失败)
printf '#!/usr/bin/env bash\necho hit >> %q\nprintf "RC=0\\n__BCC_END__ x\\nupdate --to x\\n"\nexit 1\n' "$T/mbin.log" > "$T/mbin/cat"; chmod +x "$T/mbin/cat"; : > "$T/mbin.log"
want V1 && { cell V1 'echo RC=0'; mt "V1 正常格: 有效=是、RC=0" '[[ "$(cellok V1)" == 是 && "$(rcof V1)" == 0 ]]'; }
want V2 && { cell V2 'echo RC=0; exit 3'; mt "V2 打印 RC=0 后以 3 退出 ⇒ 有效=否(子壳退出码 3、没有结束标记)" '[[ "$(cellok V2)" == 否 ]] && rdf "$T/crc-V2" && [[ "$RDV" == 3 ]]'; }
want V3 && { cell V3 'echo RC=0; exit 0'; mt "V3 打印 RC=0 后提前以 0 退出 ⇒ 有效=否(没有结束标记)" '[[ "$(cellok V3)" == 否 ]] && rdf "$T/crc-V3" && [[ "$RDV" == 0 ]]'; }
want V4 && { cell V4 'echo RC=0; echo RC=1'; mt "V4 结果记录重复 ⇒ RC 判 ?(不取最后一行)" '[[ "$(cellok V4)" == 是 && "$(rcof V4)" == "?" ]]'; }
want V5 && { cell V5 'echo OTHER'; mt "V5 结果记录缺失 ⇒ RC 判 ?" '[[ "$(cellok V5)" == 是 && "$(rcof V5)" == "?" ]]'; }
want V6 && { cell V6 'echo RC=0'; n0="$(nlines "$T/mbin.log")"
  mt "V6 结果读取先输出后失败 ⇒ RC 判 ?、有效=否(替身确被调用)" '[[ "$(PATH="$T/mbin:$PATH" rcof V6)" == "?" && "$(PATH="$T/mbin:$PATH" cellok V6)" == 否 && "$(nlines "$T/mbin.log")" -gt "$n0" ]]'; }
if want V7; then mkdir -p "$T/cell-V7"; mt "V7 调用记录不存在 ⇒ calls=?(不是 0 次)" '[[ "$(calls V7 hop2)" == "?" ]]'; fi
if want V8; then mkdir -p "$T/cell-V8"; printf 'update --to x\n' > "$T/cell-V8/calls-hop2"; chmod 000 "$T/cell-V8/calls-hop2"
  if ( : < "$T/cell-V8/calls-hop2" ) 2>/dev/null; then bad "V8 注入未命中: 调用记录仍可读(以 root 运行?)"
  else mt "V8 调用记录读不了 ⇒ calls=?" '[[ "$(calls V8 hop2)" == "?" ]]'; fi
  chmod 600 "$T/cell-V8/calls-hop2"; fi
if want V9; then mkdir -p "$T/cell-V9"; printf 'update --to x\n' > "$T/cell-V9/calls-hop2"; n0="$(nlines "$T/mbin.log")"
  mt "V9 调用记录读取先输出后失败 ⇒ calls=?(替身确被调用)" '[[ "$(PATH="$T/mbin:$PATH" calls V9 hop2)" == "?" && "$(nlines "$T/mbin.log")" -gt "$n0" ]]'; fi
if want V10; then mkdir -p "$T/cell-V10"; : > "$T/cell-V10/calls-hop2"; mt "V10 调用记录可读且为空 ⇒ calls=0(真实零次对照)" '[[ "$(calls V10 hop2)" == 0 ]]'; fi
if want V11; then mkdir -p "$T/cell-V11"; mt "V11 记账 / 计数记录不存在 ⇒ served=? fkn=? cnt=?" '[[ "$(served V11 x)" == "?" && "$(fkn V11 x)" == "?" && "$(cnt V11 hop2)" == "?" ]]'; fi
if want V12; then printf 'continue-on-error: true\n' > "$T/v12.yml"; chmod 000 "$T/v12.yml"
  if ( : < "$T/v12.yml" ) 2>/dev/null; then bad "V12 注入未命中: 被查文件仍可读(以 root 运行?)"
  else mt "V12 '没有违规'的查询对象读不了 ⇒ 判错(不当成没有)" '[[ "$(qstate grep -q continue-on-error "$T/v12.yml")" == 错 ]]'; fi
  chmod 600 "$T/v12.yml"; fi
want V13 && mt "V13 输入抽取失败 ⇒ 依赖它的核对判未取得(job 块 / 去注释代码)" '[[ "$(JOB_OK=0 jstate -F x)" == 未取得 && "$(CODE_OK=0 cstate x)" == 未取得 ]]'
# 362: 结果记录有效性 —— 读取器(rcof)与消费端(rcst / rc01)分开核; 消费端对结果未取得一律不给"是"(hcase / T 组写法见 V18 / V19)
if want V14; then v14=""
  for kv in a: b:abc c:256 d:01 e:-1 "f: 0" "g:0 "; do id="V14${kv%%:*}"; cell "$id" "echo 'RC=${kv#*:}'"
    if [[ "$(cellok "$id")" == 是 ]] && ! rcof "$id" > /dev/null && [[ "$(rcof "$id")" == "?" ]]; then :; else v14="$v14 [RC=${kv#*:}]"; fi; done
  mt "V14 单条 RC 为空或不是 0–255 的十进制退出码(空 / abc / 256 / 01 / -1 / 前后带空格)⇒ rcof 返回 1 并打印 ?(结果未取得); 不成立的:${v14:- 无}" '[[ -z "$v14" ]]'; fi
if want V15; then cell V15a 'echo RC=255'; cell V15b 'echo RC=1'
  mt "V15 单条合法 RC(255 / 1)⇒ rcof 返回 0 并打印该值(合法非零对照)" 'rcof V15a > /dev/null && rcof V15b > /dev/null && [[ "$(rcof V15a)" == 255 && "$(rcof V15b)" == 1 && "$(cellok V15a)$(cellok V15b)" == 是是 ]]'; fi
if want V16; then v16=""; n0="$(nlines "$T/mbin.log")"
  cell V16m 'echo OTHER'; cell V16d 'echo RC=1; echo RC=1'; cell V16e 'echo RC='; cell V16x 'echo RC=abc'; cell V16o 'echo RC=256'; cell V16r 'echo RC=1'
  for id in V16m V16d V16e V16x V16o; do
    for r in "$(rcst "$id" != 0)" "$(rcst "$id" == 0)" "$(rcst "$id" == 1)" "$(rc01 "$id" 非0)" "$(rc01 "$id" 0)"; do [[ "$r" == 结果未取得 ]] || v16="$v16 [$id:$r]"; done; done
  for r in "$(PATH="$T/mbin:$PATH" rcst V16r != 0)" "$(PATH="$T/mbin:$PATH" rcst V16r == 1)" "$(PATH="$T/mbin:$PATH" rc01 V16r 非0)"; do [[ "$r" == 结果未取得 ]] || v16="$v16 [V16r 读取失败:$r]"; done
  [[ "$(nlines "$T/mbin.log")" -gt "$n0" ]] || v16="$v16 [读取替身未被调用]"
  [[ "$(cellok V16m)$(cellok V16d)$(cellok V16e)$(cellok V16x)$(cellok V16o)$(cellok V16r)" == 是是是是是是 ]] || v16="$v16 [执行有效性不成立]"
  mt "V16 消费端: 结果缺失 / 同值重复 / 空 / abc / 256 / 读取先输出后失败(执行有效=是)⇒ rcst 的 == / != 与 rc01 的 0 / 非0 一律'结果未取得', 不当成非 0 或任何返回码; 不成立的:${v16:- 无}" '[[ -z "$v16" ]]'; fi
if want V17; then v17=""; cell V17z 'echo RC=0'; cell V17n 'echo RC=3'
  for t in "$(rcst V17n != 0)=是" "$(rc01 V17n 非0)=是" "$(rcst V17n == 3)=是" "$(rcst V17z == 0)=是" "$(rc01 V17z 0)=是" \
           "$(rcst V17z != 0)=否" "$(rc01 V17z 非0)=否" "$(rc01 V17n 0)=否" "$(rcst V17n == 1)=否"; do [[ "${t%%=*}" == "${t#*=}" ]] || v17="$v17 [$t]"; done
  mt "V17 消费端健康 / 正常拒绝: 合法 3 ⇒ != 0、非0、== 3 为是; 合法 0 ⇒ == 0、0 为是; 合法但不符(0 判非0 / != 0、3 判 0 / == 1)⇒ 否, 不是结果未取得; 不成立的:${v17:- 无}" '[[ -z "$v17" ]]'; fi

# ── F: 文件查询(errno 三态) ──
want F1 && { cell F1 ': > "$C/f"; bc_fq "$C/f"; echo "RC=$?"'; judge F1 "普通文件 ⇒ 存在" 判定="$(rcst F1 == 0)"; }
want F2 && { cell F2 'bc_fq "$C/没有"; echo "RC=$?"'; judge F2 "路径不存在 ⇒ 确认不存在(ENOENT)" 判定="$(rcst F2 == 3)"; }
want F3 && { cell F3 'mkdir -p "$C/d"; : > "$C/d/f"; chmod 000 "$C/d"; if ( : < "$C/d/f" ) 2>/dev/null; then echo HIT=否; else echo HIT=是; fi
  bc_fq "$C/d/f"; echo "RC=$?"; echo "WHY=$BC_WHY"; chmod 700 "$C/d"'
  judge F3 "上级目录 mode 000(EACCES) ⇒ 未取得, 不当成不存在" 判定="$(rcst F3 == 2)" 原因="$(yn has F3 'errno 13')" 命中="$(yn has F3 HIT=是)"; }
want F4 && { cell F4 ': > "$C/plain"; bc_fq "$C/plain/x"; echo "RC=$?"; echo "WHY=$BC_WHY"'
  judge F4 "路径穿过普通文件(ENOTDIR) ⇒ 未取得" 判定="$(rcst F4 == 2)" 原因="$(yn has F4 'errno 20')"; }
want F5 && { cell F5 'ln -s "$C/没有的目标" "$C/dangling"; [[ ! -e "$C/dangling" ]] && echo HIT=是; bc_fq "$C/dangling"; echo "RC=$?"'
  judge F5 "悬空符号链接 ⇒ 存在" 判定="$(rcst F5 == 0)" 命中="$(yn has F5 HIT=是)"; }
want F6 && { cell F6 'python3(){ echo "python3 $*" >> "$FK"; echo "served py-present-rc1" >> "$FK"; echo PRESENT; return 1; }
  bc_fq "$C/whatever"; echo "RC=$?"; echo "WHY=$BC_WHY"'
  judge F6 "查询进程先打印 PRESENT 再退出 1 ⇒ 未取得(已打印的不采信)" 判定="$(rcst F6 == 2)" 原因="$(yn has F6 '退出 1')" 命中="$(yn [ "$(served F6 py-present-rc1)" == 1 ])"; }
want F7 && { cell F7 'python3(){ echo "served py-garbage" >> "$FK"; echo "WHAT"; return 0; }
  bc_fq "$C/whatever"; echo "RC=$?"; echo "WHY=$BC_WHY"'
  judge F7 "查询退出 0 但输出不认识 ⇒ 未取得" 判定="$(rcst F7 == 2)" 原因="$(yn has F7 '不认识')" 命中="$(yn [ "$(served F7 py-garbage)" == 1 ])"; }

# ── U: unit 确认不存在 ──
mktab u1 'show:LoadState pdg-mitm|0|not-found\n|'; mktab u2 'show:LoadState pdg-mitm|1||'; mktab u4 'show:LoadState pdg-mitm|0|loaded\n|'
want U1 && { cell U1 'SCFIX="$T/sc-u1.tab"; bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; echo "RC=$?"'
  judge U1 "unit 文件 ENOENT + LoadState=not-found ⇒ 确认不存在" 判定="$(rcst U1 == 0)" 命中="$(yn [ "$(served U1 'show:LoadState pdg-mitm ')" == 1 ])"; }
want U2 && { cell U2 'SCFIX="$T/sc-u2.tab"; bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; echo "RC=$?"; echo "WHY=$BC_WHY"'
  judge U2 "unit 文件不在 + LoadState 查询退出 1 ⇒ 未取得" 判定="$(rcst U2 == 2)" 原因="$(yn has U2 'LoadState 没取得')" 命中="$(yn [ "$(served U2 'show:LoadState pdg-mitm -> rc=1')" == 1 ])"; }
want U3 && { cell U3 ': > "$BC_MITM_UNIT"; bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; echo "RC=$?"'
  judge U3 "unit 文件在 ⇒ 存在" 判定="$(rcst U3 == 1)"; }
want U4 && { cell U4 'SCFIX="$T/sc-u4.tab"; bc_unit_absent pdg-mitm "$BC_MITM_UNIT"; echo "RC=$?"'
  judge U4 "unit 文件不在但 LoadState=loaded ⇒ 存在" 判定="$(rcst U4 == 1)" 命中="$(yn [ "$(served U4 'show:LoadState pdg-mitm ')" == 1 ])"; }

# ── R: iOS 记录三态 ──
want R1 && { cell R1 'printf "schema\t1\ncurrent\t有记录\t文件在\thealthy\tok\nprevious\t无记录\t文件不在\tmissing\t-\n" > "$C/rep"
  : > "$IOS_META"; bc_record_verdict "$(cat "$C/rep")" "$IOS_META" 1; echo "RC=$?"'
  judge R1 "schema 1、current 有记录且 healthy、previous 无记录 missing ⇒ 记录有效" 判定="$(rcst R1 == 0)"; }
want R2 && { cell R2 'bc_record_verdict "$(printf "NOMETA\t记录文件不存在")" "$IOS_META" 1; echo "RC=$?"; echo "WHY=$BC_WHY"'
  judge R2 "NOMETA 且记录路径 ENOENT ⇒ 确认没有记录" 判定="$(rcst R2 == 3)"; }
want R3 && { cell R3 'bc_record_verdict "$(printf "LOADFAIL\tValueError: x")" "$IOS_META" 1; echo "RC=$?"'
  judge R3 "LOADFAIL ⇒ 未取得" 判定="$(rcst R3 == 2)"; }
want R4 && { cell R4 'mkdir -p "$C/locked"; chmod 000 "$C/locked"; if ( : < "$C/locked/x" ) 2>/dev/null || [[ -x "$C/locked" ]]; then echo HIT=否; else echo HIT=是; fi
  bc_record_verdict "$(printf "NOMETA\t记录文件不存在")" "$C/locked/ios-profile.json" 1; echo "RC=$?"; echo "WHY=$BC_WHY"; chmod 700 "$C/locked"'
  judge R4 "NOMETA 但记录路径 EACCES ⇒ 未取得(不是缺记录)" 判定="$(rcst R4 == 2)" 原因="$(yn has R4 'errno 13')" 命中="$(yn has R4 HIT=是)"; }

# ── P: 前像构造的首次启动、旧版迁移、旧版切 Android ──
_jstub='_j_starts_after(){ echo "j_starts $1" >> "$FK"; echo "${FAKE_STARTS:-1}"; }'
mktab p1 'enable mihomo|1||'
want P1 && { cell P1 "$_jstub"$'\n''SCFIX="$T/sc-p1.tab"; bc_firststart "B 构造: 首次启动" mosdns mihomo pdg-probe81 pdg-mitm; echo "RC=$?"'
  judge P1 "mihomo 的 enable --now 退出 1 ⇒ 前像不成立并停止" 判定="$(rcst P1 == 1)" 原因="$(yn has P1 'enable --now mihomo 退出 1')" \
    命中="$(yn [ "$(served P1 'enable mihomo -> rc=1')" == 1 ])" 停止="$(yn [ "$(fkn P1 'systemctl enable --now pdg-probe81')" == 0 ])"; }
want P2 && { cell P2 "$_jstub"$'\n''bc_firststart "B 构造: 首次启动" mosdns mihomo pdg-probe81 pdg-mitm; echo "RC=$?"'
  judge P2 "四个 unit 首次启动退出 0, active / NRestarts=0 / 恰 1 次 Started" 判定="$(rcst P2 == 0)" 次数="$(yn [ "$(fkn P2 'systemctl enable --now')" == 4 ])"; }
_snapin='mkdir -p "$SNAPROOT/20260901-000000-old"; cp "$FX/old/deploy/bot/pdg.sh" "$R3_CLI"'
want P3 && { cell P3 "$_snapin"$'\n''export BC_OLD_RC=1 BC_OLD_OUT="❌ 迁移失败"; bc_old_migrate; echo "RC=$?"'
  judge P3 "旧版 pdg migrate 产品原始退出码 1 ⇒ 前像不成立" 判定="$(rcst P3 == 1)" 原因="$(yn has P3 '产品原始退出码 1')" \
    旧版调用="$(yn [ "$(calls P3 old)" == 1 ])" 计数="$(yn [ "$(cnt P3 old-cli)" == 1 ])"; }
want P4 && { cell P4 "$_snapin"$'\n''export BC_OLD_OUT="迁移中…" BC_OLD_EFFECT="mkdir -p \"$SNAPROOT/20260902-000000-new\""; bc_old_migrate; echo "RC=$?"'
  judge P4 "退出 0 但没有「✅ 迁移完成」⇒ 前像不成立" 判定="$(rcst P4 == 1)" 原因="$(yn has P4 '迁移完成')" 旧版调用="$(yn [ "$(calls P4 old)" == 1 ])"; }
want P5 && { cell P5 "$_snapin"$'\n''export BC_OLD_OUT="✅ 迁移完成(快照: x)"; bc_old_migrate; echo "RC=$?"'
  judge P5 "退出 0 + 完成文字, 但没有新快照 ⇒ 前像不成立" 判定="$(rcst P5 == 1)" 原因="$(yn has P5 '快照')" 旧版调用="$(yn [ "$(calls P5 old)" == 1 ])"; }
want P6 && { cell P6 "$_snapin"$'\n''export BC_OLD_OUT="✅ 迁移完成(快照: x)" BC_OLD_EFFECT="mkdir -p \"$SNAPROOT/20260902-000000-new\""; bc_old_migrate; echo "RC=$?"'
  judge P6 "退出 0 + 完成文字 + 恰新增 1 个快照 ⇒ 成立" 判定="$(rcst P6 == 0)" 旧版调用="$(yn [ "$(calls P6 old)" == 1 ])" 入参="$(yn grep -qx migrate "$T/cell-P6/calls-old")"; }
_c2out='平台已确认: ios → android\nAndroid: 已清理 iOS 专属残留(pdg-mitm 服务 + mitm 模块 + 描述文件模板; CA/地点数据保留为休眠)。'
want P7 && { cell P7 "$_snapin"$'\n''echo ios > "$R3_ETC/platform"; export BC_OLD_OUT="Android: 已清理 iOS 专属残留" BC_OLD_EFFECT="mkdir -p \"$SNAPROOT/n\"; echo android > \"$R3_ETC/platform\""; bc_c2_switch; echo "RC=$?"'
  judge P7 "退出 0 但缺「平台已确认: ios → android」⇒ 前像不成立" 判定="$(rcst P7 == 1)" 原因="$(yn has P7 '平台已确认')" 旧版调用="$(yn [ "$(calls P7 old)" == 1 ])"; }
want P8 && { cell P8 "$_snapin"$'\n''echo ios > "$R3_ETC/platform"; export BC_OLD_OUT="'"$_c2out"'" BC_OLD_EFFECT="mkdir -p \"$SNAPROOT/n\""; bc_c2_switch; echo "RC=$?"'
  judge P8 "文字齐、新快照恰 1 个, 但平台文件仍是 ios ⇒ 前像不成立" 判定="$(rcst P8 == 1)" 原因="$(yn has P8 '平台文件')" 旧版调用="$(yn [ "$(calls P8 old)" == 1 ])"; }
want P9 && { cell P9 "$_snapin"$'\n''echo ios > "$R3_ETC/platform"; export BC_OLD_OUT="'"$_c2out"'" BC_OLD_EFFECT="mkdir -p \"$SNAPROOT/n\"; echo android > \"$R3_ETC/platform\""; bc_c2_switch; echo "RC=$?"'
  judge P9 "旧版 pdg platform android 全部成立" 判定="$(rcst P9 == 0)" 旧版调用="$(yn [ "$(calls P9 old)" == 1 ])" 入参="$(yn grep -qx 'platform android' "$T/cell-P9/calls-old")"; }

# ── H / P10–P12: bc_main 的门控顺序(叶子替身见下; 第二跳入口流程、bc_identity、bc_gated_invoke、r3_invoke 都执行原文) ──
_leaves='bc_hardgate(){ leaf hardgate; }; bc_source_map(){ leaf source_map; }; bc_deps_selfcheck(){ leaf deps; }
bc_build_b(){ leaf build_b; BC_PRE_OK="${LEAF_PRE_OK:-1}"; }; bc_build_c2(){ leaf build_c2; BC_PRE_OK="${LEAF_PRE_OK:-1}"; }
bc_gate_b(){ leaf gate_b; }; bc_gate_c2(){ leaf gate_c2; }; snap_state(){ leaf "snap $1"; }
bc_quiesce(){ leaf "quiesce $1"; [[ "$1" != "${LEAF_Q_FAIL:-}" ]]; }
bc_post2_b(){ leaf post2_b; }; bc_post2_c2(){ leaf post2_c2; }; bc_hop_svc(){ leaf "svc $1"; }
bc_dns_instrument(){ leaf dns_instrument; }; bc_runtime_gate(){ leaf runtime; }; bc_dns_pre(){ leaf dns_pre; }
bc_precapture(){ leaf precapture; BC_H3_C0=cur-hop3-start; }; bc_hop3_verdict(){ leaf hop3_verdict; }
cp "$FX/old/deploy/bot/pdg.sh" "$R3_CLI"; printf "%s\n" "$OLDSHA" > "$BC_EFF_HEADF"
for m in a i d; do cp "$FX/br/deploy/bot/$m.py" "$R3_MODDIR/$m.py"; done
echo "$BC_PLAT" > "$R3_ETC/platform"
export BC_EFF_CLI="$R3_CLI" BC_EFF_BRCLI="$FX/br/deploy/bot/pdg.sh" BC_EFF_HEAD="$BRSHA"
export BC_HOP2_EFFECT="cp \"\$BC_EFF_BRCLI\" \"\$BC_EFF_CLI\" && printf \"%s\\n\" \"\$BC_EFF_HEAD\" > \"\$BC_EFF_HEADF\""'
hcase(){   # $1=格 $2=说明 $3=注入代码 $4=期望返回(0/非0) $5=期望第二跳次数 $6=期望第三跳次数 [$7=原因片段] [$8=命中核对(父壳 eval)]
  cell "$1" "$_leaves"$'\n'"$3"$'\n''bc_main; echo "RC=$?"'
  local r h=是; r="$(rc01 "$1" "$4")"
  [[ -z "${8:-}" ]] || { eval "$8" || h=否; }
  judge "$1" "$2" 返回="$r" \
    第二跳替身="$(yn [ "$(calls "$1" hop2)" == "$5" ])" 第三跳替身="$(yn [ "$(calls "$1" hop3)" == "$6" ])" \
    计数="$(yn [ "$(cnt "$1" hop2)/$(cnt "$1" hop3)" == "$5/$6" ])" 原因="$(yn has "$1" "${7:-VSECT}")" 命中="$h"
}
want P10 && hcase P10 "B 构造置 BC_PRE_OK=0 ⇒ 场景未执行, 两跳都不调用" 'LEAF_PRE_OK=0' 非0 0 0 "前像构造不成立" 'fline "$T/cell-P10/leaf.log" build_b && nofline "$T/cell-P10/leaf.log" gate_b'
want P11 && hcase P11 "C2 构造置 BC_PRE_OK=0 ⇒ 场景未执行, 两跳都不调用" 'BC_PRE=c2; BC_PLAT=android; LEAF_PRE_OK=0' 非0 0 0 "前像构造不成立" 'grep -qx build_c2 "$T/cell-P11/leaf.log"'
want P12 && hcase P12 "构造成立但第二跳前静置不成立 ⇒ 两跳都不调用" 'LEAF_Q_FAIL=pre-hop2' 非0 0 0 "第二跳前静置不成立" 'grep -qx "quiesce pre-hop2" "$T/cell-P12/leaf.log"'
want H1 && hcase H1 "B 健康路径 ⇒ 第二跳 1 次、第三跳 1 次, 返回 0" ':' 0 1 1 "第三跳前 身份: 现役 HEAD" 'grep -qx hop3_verdict "$T/cell-H1/leaf.log" && grep -qx "update --to v9.9.9-retire-TEST" "$T/cell-H1/calls-hop3"'
want H2 && hcase H2 "第二跳入口流程退出 1 ⇒ 第三跳不调用" 'export BC_HOP2_RC=1' 非0 1 0 "产品原始退出码 1"
want H3 && hcase H3 "第二跳退出 0 但 HEAD 不是桥接 ⇒ 第三跳不调用" 'export BC_EFF_HEAD="$OLDSHA"' 非0 1 0 "HEAD=$OLDSHA" '[[ "$(served H3 git-head)" -ge 1 ]]'
want H4 && hcase H4 "第二跳退出 0、HEAD 对, 但现役 CLI 不是桥接 pdg.sh ⇒ 第三跳不调用" 'export BC_HOP2_EFFECT="printf \"%s\\n\" \"\$BC_EFF_HEAD\" > \"\$BC_EFF_HEADF\""' 非0 1 0 "现役 CLI("
want H7 && hcase H7 "C2 健康路径 ⇒ 第二跳 1 次、第三跳 1 次, 返回 0" 'BC_PRE=c2; BC_PLAT=android; echo android > "$R3_ETC/platform"' 0 1 1 "按当前平台 android 的清单" 'grep -qx post2_c2 "$T/cell-H7/leaf.log" && grep -qx hop3_verdict "$T/cell-H7/leaf.log"'
_rcdrop='echo(){ if [[ $# == 1 && "$1" == RC=* ]]; then printf "%s\n" "$1" >> "$C/rc-dropped"; else builtin echo "$@"; fi; }'   # V18 / V19: 格内只吞掉结果记录那一行(记下原值), 子壳、结束标记与调用记录照常
if want V18; then   # 元测试: 在命令替换里跑 hcase 原文(计数不进总数), 只核它的结算行
  s18="$(hcase V18 "构造置 BC_PRE_OK=0, 结果记录被吞" 'LEAF_PRE_OK=0'$'\n'"$_rcdrop" 非0 0 0 "前像构造不成立" 'fline "$T/cell-V18/leaf.log" build_b && [[ "$(nlines "$T/cell-V18/rc-dropped")" == 1 ]]')"
  mt "V18 hcase 实际路径: 负控的结果记录缺失 ⇒ hcase 给 FAIL(有效=是、返回=结果未取得; 两跳替身 0 / 0、计数、原因、命中照常), 不当成检出非 0" \
    '[[ "$s18" == "[FAIL] V18 "* && "$s18" == *"不成立: 有效=是 返回=结果未取得 第二跳替身=是 第三跳替身=是 计数=是 原因=是 命中=是;"* ]]'; fi
_ident='cp "$FX/br/deploy/bot/pdg.sh" "$R3_CLI"; printf "%s\n" "$BRSHA" > "$BC_EFF_HEADF"; BC_PRE=c2; BC_PLAT=android; echo android > "$R3_ETC/platform"
cp "$FX/br/deploy/bot/a.py" "$R3_MODDIR/a.py"; cp "$FX/br/deploy/bot/d.py" "$R3_MODDIR/d.py"'
want H5 && { cell H5 "$_ident"$'\n''bc_identity 第二跳后 "$BRSRC" "$BRSHA"; echo "RC=$?"'
  judge H5 "平台 android: 已装模块 = android 清单(不含 iOS 专属件 i.py)⇒ 身份成立" 判定="$(rcst H5 == 0)" 原因="$(yn has H5 '按当前平台 android 的清单 2 项')"; }
want H6 && { cell H6 "$_ident"$'\n''rm -f "$R3_MODDIR/d.py"; bc_identity 第二跳后 "$BRSRC" "$BRSHA"; echo "RC=$?"'
  judge H6 "平台 android, 已装模块缺 android 清单里的 d.py ⇒ 身份不成立" 判定="$(rcst H6 == 1)" 原因="$(yn has H6 'd.py(不在)')"; }

# ── D: DNS 仪器、标定、前后阶段(bc_gated_invoke 里身份 / 静置 / 运行态 / 调用前观测是叶子替身; DNS 与 r3_invoke 执行原文) ──
_dleaves='bc_identity(){ leaf identity; }; bc_quiesce(){ leaf "quiesce $1"; }; bc_runtime_gate(){ leaf runtime; }
bc_precapture(){ leaf precapture; BC_H3_C0=cur-hop3-start; }
cp "$FX/br/deploy/bot/pdg.sh" "$R3_CLI"'
dcase(){   # $1=格 $2=说明 $3=注入代码 $4=期望 GRC $5=原因片段 $6=命中核对(父壳 eval) [$7=期望第三跳次数]
  cell "$1" "$_dleaves"$'\n'"$3"$'\n''bc_gated_invoke; echo "RC=$?"'
  local h=是; eval "$6" || h=否
  judge "$1" "$2" 返回="$(rcst "$1" == "$4")" 原因="$(yn has "$1" "$5")" 命中="$h" \
    第三跳替身="$(yn [ "$(calls "$1" hop3)" == "${7:-0}" ])" 计数="$(yn [ "$(cnt "$1" hop3)" == "${7:-0}" ])"
}
want D1 && dcase D1 "健康: 本 runner 上 K 的 U→H→U 标定、磁盘与运行还原、仪器重启 3 次; 前阶段 C=U、P=H ⇒ 调用" ':' 0 "磁盘 已核实; 运行 已核实" \
  '[[ "$(cat "$T/cell-D1/fk/restarts-mosdns")" == 3 ]] && grep -q "U→H 成立; 磁盘还原=已核实; 运行还原=已核实" "$T/cell-D1/evid/05-dns-calibration.txt" && has D1 "VOK 第三跳前 DNS C(独立上游对照" && has D1 "VOK 第三跳前 DNS P(普通劫持探针" && [[ "$(fcnt "$T/cell-D1/fk.log" "dig " gs-loc.apple.com)" == 0 ]]' 1
want D2 && dcase D2 "mosdns 替身无视接管表(K 临时接管后仍答 U)⇒ 仪器 / 标定不成立, 不调用" 'export FAKE_MODEL_NOHIJ=1' 22 "标定第二段(K 临时接管)不成立" '[[ "$(served D2 model-nohij)" -ge 1 ]]'
want D3 && dcase D3 "标定那次重启时接管表被改成只读 ⇒ 还原写不回, 不调用" 'export FAKE_RO_AT_RESTART=2' 22 "失败(写回原件失败)" '[[ "$(served D3 hij-readonly)" == 1 ]]'
want D4 && dcase D4 "C_pre 在缓存里(答 U, 窗口增量 0)⇒ 前阶段来源证据不成立, 不调用" 'export FAKE_NOLOG_ON=bcc-pre-t.e2e.test' 23 "来源证据不成立" '[[ "$(served D4 model-nolog)" == 1 ]]'
want D5 && dcase D5 "P_pre 答 H 但自有上游也收到了该名 ⇒ 前阶段来源证据不成立, 不调用" 'export FAKE_HLOG_ON=bcp-pre-t.e2e.test' 23 "来源证据不成立" '[[ "$(served D5 model-hlog)" == 1 ]]'
_dpre="$_dleaves"$'\n''bc_dns_instrument > "$C/pre.out" 2>&1 && bc_dns_pre >> "$C/pre.out" 2>&1; echo "PRE=$?"; g0="$(cat "$FKDIR/gen-mosdns")"; d0="$(grep -c "^dig " "$FK")"'
gen_same(){ local l; rdf "$T/out-$1" || return 2   # 输出里那一行 GEN=前/后 的两个实例代数相同
  while IFS= read -r l; do [[ "$l" =~ ^GEN=([0-9]+)/([0-9]+)\  ]] && [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] && return 0; done <<<"$RDV"; return 1; }
want D6 && { cell D6 "$_dpre"$'\n''bc_dns_post; echo "RC=$?"; echo "GEN=$g0/$(cat "$FKDIR/gen-mosdns") DIGW=$(grep -c "^dig .*gs-loc.apple.com" "$FK")"'
  judge D6 "升级前后 mosdns 实例没换; W 第一次被问 ⇒ W=U 且本次窗口上游增量 1, 后阶段成立" 前提="$(yn has D6 PRE=0)" 判定="$(rcst D6 == 0)" \
    实例不变="$(yn gen_same D6)" W只问一次="$(yn has D6 'DIGW=1')" 原因="$(yn has D6 '自有上游该名 +1')"; }
want D7 && { cell D7 "$_dpre"$'\n''export FAKE_NOLOG_ON=gs-loc.apple.com; bc_dns_post; echo "RC=$?"'
  judge D7 "W 在缓存里(答 U, 增量 0)⇒ W 来源证据不成立, 后阶段未取得" 前提="$(yn has D7 PRE=0)" 判定="$(rcst D7 == 1)" 原因="$(yn has D7 '来源证据不成立')" 命中="$(yn [ "$(served D7 model-nolog)" == 1 ])"; }
want D8 && { cell D8 "$_dpre"$'\n''printf "full:改动.e2e.test\n" >> "$R3_GEOCN"; bc_dns_post; echo "RC=$?"; echo "DIGPOST=$(( $(grep -c "^dig " "$FK") - d0 ))"'
  judge D8 "升级后 geosite_cn 被改动 ⇒ 仪器条件被改动, 后阶段未取得且不做查询" 前提="$(yn has D8 PRE=0)" 判定="$(rcst D8 == 1)" 原因="$(yn has D8 '仪器条件被改动')" 不查询="$(yn has D8 'DIGPOST=0')"; }
d9_clean(){ rdf "$1" && [[ -n "$RDV" && "$RDV" != *标定* && "$RDV" != *还原* ]]; }   # 读得到、非空、且没有"标定""还原"字样
want D9 && { cell D9 'bc_dns_adjust; echo "ADJ=$?"; [[ -e "$EVID/05-dns-calibration.txt" ]] && echo CAL_EARLY=有 || echo CAL_EARLY=无
  r3_dns_calibrate; echo "CAL=$?"'
  f="$T/cell-D9/evid/05-dns-instrument-adjustments.txt"
  judge D9 "调整留证只写已完成的调整(没有'标定''还原'字样); 标定记录只由标定函数事后写" 调整="$(yn has D9 ADJ=0)" \
    无预写="$(yn d9_clean "$f")" 事前无标定记录="$(yn has D9 CAL_EARLY=无)" \
    事后有="$(yn grep -q '^标定名 bck-t.e2e.test' "$T/cell-D9/evid/05-dns-calibration.txt")"; }

# ── Q: 分阶段静置 ──
_qstub='_j_interval(){ echo "j_interval $*" >> "$FK"; echo "${FAKE_QSTARTS:-0}"; }'
q1_sep(){ fhas "$1" quiesce-pre-hop2-start && fhas "$1" "结论(pre-hop2): 成立" && flacks "$1" pre-hop3 \
  && fhas "$2" quiesce-pre-hop3-end && fhas "$2" "结论(pre-hop3): 成立" && flacks "$2" pre-hop2; }
want Q1 && { cell Q1 "$_qstub"$'\n''bc_quiesce pre-hop2; echo "R2=$?"; bc_quiesce pre-hop3; echo "RC=$?"'
  a="$T/cell-Q1/evid/06-quiesce-pre-hop2.txt"; b="$T/cell-Q1/evid/06-quiesce-pre-hop3.txt"
  judge Q1 "两段静置各自一份记录、各自界桩与结论, 互不包含对方阶段名; 各睡一次" 判定="$(yn bash -c 'grep -q "^R2=0$" "$1" && grep -q "^RC=0$" "$1"' _ "$T/out-Q1")" \
    各自记录="$(yn q1_sep "$a" "$b")" \
    人为前提="$(yn grep -q '人为规定的验收时序前提' "$a")" 睡眠="$(yn [ "$(fkn Q1 'sleep 303')" == 2 ])"; }
want Q2 && { cell Q2 "$_qstub"$'\n''printf "旧记录\n" > "$EVID/06-quiesce-pre-hop2.txt"; s0="$(sha256sum < "$EVID/06-quiesce-pre-hop2.txt")"
  bc_quiesce pre-hop2; echo "RC=$?"; [[ "$(sha256sum < "$EVID/06-quiesce-pre-hop2.txt")" == "$s0" ]] && echo SAME=是'
  judge Q2 "该阶段记录已存在 ⇒ 拒绝, 不睡, 原记录不被改写" 判定="$(rcst Q2 == 1)" 原因="$(yn has Q2 '已存在')" 不睡="$(yn [ "$(fkn Q2 'sleep ')" == 0 ])" 原样="$(yn has Q2 SAME=是)"; }
want Q3 && { cell Q3 "$_qstub"$'\n''export FAKE_MONO_STEP=100000000000; bc_quiesce pre-hop3; echo "RC=$?"'
  judge Q3 "单调时钟实得 < 计划 ⇒ 不成立, 只睡一次不重新计时" 判定="$(rcst Q3 == 1)" 原因="$(yn has Q3 '实得')" 睡眠="$(yn [ "$(fkn Q3 'sleep ')" == 1 ])" 命中="$(yn [ "$(served Q3 'mono n=2 -> 1100000000000')" == 1 ])"; }
want Q4 && { cell Q4 "$_qstub"$'\n''export FAKE_QSTARTS=1; bc_quiesce pre-hop3; echo "RC=$?"'
  judge Q4 "界桩区间内 Started 1 次 ⇒ 不成立" 判定="$(rcst Q4 == 1)" 原因="$(yn has Q4 'Started')"; }

# ── S: 分阶段服务采样(bridge_svc_sample 执行 ② 原文, systemctl 是替身) ──
_real_sample='source "$T/hop2-fns.sh"'
mktab s4 'show:LoadState mosdns|0||'
want S1 && { cell S1 "$_real_sample"$'\n''bc_svc_phase hop3-before; echo "RC=$?"; [[ -s "$C/wk/svc-hop3-before.tsv" ]] && echo NEW=是'
  judge S1 "健康 ⇒ 本次新采样集合完整、逐行有效" 判定="$(rcst S1 == 0)" 新文件="$(yn has S1 NEW=是)" 留证="$(yn test -s "$T/cell-S1/evid/07-svc-hop3-before.tsv")"; }
want S2 && { cell S2 "$_real_sample"$'\n''printf "旧\n" > "$C/wk/svc-hop3-before.tsv"; s0="$(sha256sum < "$C/wk/svc-hop3-before.tsv")"
  bc_svc_phase hop3-before; echo "RC=$?"; echo "WHY=$R3_WHY"; [[ "$(sha256sum < "$C/wk/svc-hop3-before.tsv")" == "$s0" ]] && echo SAME=是'
  judge S2 "该阶段采样文件已存在 ⇒ 未取得, 旧文件不被采用也不被覆盖" 判定="$(rcst S2 == 2)" 原因="$(yn has S2 '已存在')" 原样="$(yn has S2 SAME=是)"; }
want S3 && { cell S3 "$_real_sample"$'\n''chmod 555 "$C/wk"; bc_svc_phase hop3-before; echo "RC=$?"; echo "WHY=$R3_WHY"; chmod 755 "$C/wk"'
  judge S3 "采样落点写不进(采样器返回非 0)⇒ 未取得" 判定="$(rcst S3 == 2)" 原因="$(yn has S3 '采样写不出来')"; }
want S4 && { cell S4 "$_real_sample"$'\n''SCFIX="$T/sc-s4.tab"; bc_svc_phase hop3-before; echo "RC=$?"; echo "WHY=$R3_WHY"'
  judge S4 "某 unit 的 LoadState 查询成功但为空 ⇒ 有无效行, 未取得" 判定="$(rcst S4 == 2)" 原因="$(yn has S4 '有无效行')" 命中="$(yn [ "$(served S4 'show:LoadState mosdns ')" -ge 1 ])"; }

# ── T: 第三跳后终态(B / C2 分别结算) ──
_tb='SCFIX="$T/sc-mitm-gone.tab"; echo ios > "$R3_ETC/platform"; : > "$HIJ"; printf "proxies: []\n" > "$MC"
printf "%s\n" "{\"schema\": 1, \"instance_id\": \"i1\", \"created_at\": \"t0\", \"current\": {\"revision\": 3, \"sha256\": \"s3\", \"inputs\": {\"wloc_enabled\": false}}, \"previous\": null}" > "$C/wk/ios-before-hop3.json"
printf "%s\n" "{\"schema\": 2, \"instance_id\": \"i1\", \"created_at\": \"t0\", \"current\": {\"revision\": 3, \"sha256\": \"s3\"}, \"previous\": null, \"retired_revision\": null}" > "$IOS_META"
printf "profile-no-root\n" > "$IOS_ART/current.mobileconfig"; cp "$IOS_ART/current.mobileconfig" "$C/wk/current-before-hop3.mobileconfig"
printf "%s\n" "✅ WLOC 位置改写及其专属 MITM 执行能力已退役" "✅ iOS 描述文件记录已迁移到新格式" "✅ 已更新。" > "$R3_LOG"'
_tc2='SCFIX="$T/sc-mitm-gone.tab"; BC_PRE=c2; BC_PLAT=android; echo android > "$R3_ETC/platform"; : > "$HIJ"; printf "proxies: []\n" > "$MC"
mkdir -p "$CA_DIR"; echo crt > "$CA_DIR/ca.crt"; echo key > "$CA_DIR/ca.key"; chmod 600 "$CA_DIR/ca.key"
printf "%s\n" "{\"wloc\": {\"enabled\": false, \"locations\": [{\"name\": \"osaka\"}]}}" > "$MJ"
printf "%s\n" "{\"schema\": 1, \"current\": {\"revision\": 1, \"inputs\": {\"wloc_enabled\": true}}}" > "$IOS_META"
printf "<plist>com.apple.security.root</plist>\n" > "$IOS_ART/current.mobileconfig"
bc_fp_take c2 "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$IOS_META" "$IOS_ART/current.mobileconfig" "$MJ" || echo FPTAKE=失败
printf "%s\n" "⚠️ 盘上仍有 WLOC 时期的 CA 材料(按保留策略未删)" "✅ 已更新。" > "$R3_LOG"'
want T1 && { cell T1 "$_tb"$'\n''bc_post_b; echo "RC=$?"'; judge T1 "B 健康终态 ⇒ 成立" 判定="$(rcst T1 == 0)" 无失败项="$(yn nostart T1 VBAD)"; }
want T2 && { cell T2 "$_tb"$'\n''rm -f "$IOS_ART/current.mobileconfig"; bc_post_b; echo "RC=$?"'
  judge T2 "B: current.mobileconfig 被删 ⇒ 不成立" 判定="$(rcst T2 != 0)" 原因="$(yn has T2 'VBAD B 终态: current.mobileconfig 仍在')"; }
want T3 && { cell T3 "$_tb"$'\n''printf "%s\n" "⚠️ 盘上仍有 WLOC 时期的 CA 材料" >> "$R3_LOG"; bc_post_b; echo "RC=$?"'
  judge T3 "B: 升级日志里有 CA 提示 ⇒ 不成立" 判定="$(rcst T3 != 0)" 原因="$(yn has T3 '不该有却有 —— 没有 CA 提示')"; }
want T4 && { cell T4 "$_tc2"$'\n''bc_post_c2; echo "RC=$?"'
  judge T4 "C2 健康终态(记录 / 产物 / CA / mitm.json 与 C2 前像一致)⇒ 成立, 保留维写明按 360 选择(甲)" 判定="$(rcst T4 == 0)" \
    选择甲="$(yn has T4 '按 360 选择(甲)')" 无失败项="$(yn nostart T4 VBAD)" 指纹="$(yn lacks T4 FPTAKE)"; }
want T5 && { cell T5 "$_tc2"$'\n''printf "%s\n" "{\"schema\": 1, \"current\": {\"revision\": 2, \"inputs\": {\"wloc_enabled\": true}}}" > "$IOS_META"; bc_post_c2; echo "RC=$?"'
  judge T5 "C2: 记录 ios-profile.json 被改 ⇒ 不成立" 判定="$(rcst T5 != 0)" 原因="$(yn has T5 'ios-profile.json 被改')"; }
want T6 && { cell T6 "$_tc2"$'\n''printf "%s\n" "✅ WLOC 位置改写及其专属 MITM 执行能力已退役" >> "$R3_LOG"; bc_post_c2; echo "RC=$?"'
  judge T6 "C2: 日志里有'执行能力已退役' ⇒ 不成立" 判定="$(rcst T6 != 0)" 原因="$(yn has T6 "不该有却有 —— 没有'执行能力已退役'")"; }
want T7 && { cell T7 "$_tc2"$'\n''bc_post_b; echo "RC=$?"'
  judge T7 "C2 的终态喂给 B 的判据 ⇒ 不成立(两者不互相代替)" 判定="$(rcst T7 != 0)"; }
if want V19; then cell V19 "$_tc2"$'\n'"$_rcdrop"$'\n''bc_post_b; echo "RC=$?"'   # 元测试: T 组写法(judge + rcst != 0)在命令替换里结算
  s19="$(judge V19 "C2 终态喂给 B, 结果记录被吞" 判定="$(rcst V19 != 0)")"
  mt "V19 T 组写法(judge + rcst != 0): 结果记录缺失 ⇒ FAIL(有效=是、判定=结果未取得), 不当成'不成立'已检出" \
    '[[ "$s19" == "[FAIL] V19 "* && "$s19" == *"不成立: 有效=是 判定=结果未取得;"* && "$(nlines "$T/cell-V19/rc-dropped")" == 1 ]]'; fi

# ── W: 防火墙规范化与比较 ──
python3 - "$T/fw" <<'PY'
import copy, json, os, sys
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
R = lambda ch, h, ex: {"rule": {"family": "inet", "table": "pdg", "chain": ch, "handle": h, "expr": ex}}
M = lambda left, right, op="==": {"match": {"op": op, "left": left, "right": right}}
base = {"nftables": [
    {"metainfo": {"version": "1.0.6", "release_name": "x", "json_schema_version": 1}},
    {"table": {"family": "inet", "name": "pdg", "handle": 5}},
    {"chain": {"family": "inet", "table": "pdg", "name": "prerouting", "handle": 1, "type": "nat", "hook": "prerouting", "prio": -100, "policy": "accept"}},
    {"chain": {"family": "inet", "table": "pdg", "name": "input", "handle": 2, "type": "filter", "hook": "input", "prio": 0, "policy": "drop"}},
    R("prerouting", 4, [M({"meta": {"key": "iifname"}}, "tailscale0"), {"return": None}]),
    R("prerouting", 5, [M({"payload": {"protocol": "ip", "field": "saddr"}}, {"prefix": {"addr": "127.0.0.0", "len": 8}}),
                        M({"payload": {"protocol": "tcp", "field": "dport"}}, {"set": [80, 443, {"range": [5228, 5230]}]}),
                        {"counter": {"packets": 0, "bytes": 0}}, {"redirect": {"port": 7893}}]),
    R("input", 6, [M({"meta": {"key": "iif"}}, "lo"), {"accept": None}]),
    R("input", 7, [M({"ct": {"key": "state"}}, ["established", "related"], "in"), {"accept": None}]),
]}
def save(name, doc):
    json.dump(doc, open(os.path.join(d, name + ".json"), "w"))
save("base", base)
w1 = copy.deepcopy(base)
for o in w1["nftables"]:
    for v in o.values():
        if isinstance(v, dict) and "handle" in v: v["handle"] += 100
w1["nftables"][0]["metainfo"]["version"] = "9.9"
w1["nftables"][5]["rule"]["expr"][2]["counter"] = {"packets": 42, "bytes": 4242}
save("w1", w1)
w2 = copy.deepcopy(base); w2["nftables"][5]["rule"]["expr"][3]["redirect"]["port"] = 7894; save("w2", w2)
w3 = copy.deepcopy(base); n = w3["nftables"]; n[6], n[7] = n[7], n[6]; save("w3", w3)
w4 = copy.deepcopy(base); w4["nftables"][3]["chain"]["prio"] = 10; save("w4", w4)
w5 = copy.deepcopy(base); w5["nftables"][5]["rule"]["expr"][0]["match"]["right"]["prefix"]["len"] = 16; save("w5", w5)
w6 = copy.deepcopy(base); w6["nftables"].append(R("input", 8, [{"log": {"prefix": "x"}}, {"accept": None}])); save("w6", w6)
w8 = copy.deepcopy(base); w8["nftables"][5]["rule"]["expr"][1]["match"]["right"]["set"] = [{"range": [5228, 5230]}, 443, 80]; save("w8", w8)
PY
wcase(){   # $1=格 $2=说明 $3=对照文件名 $4=期望返回 $5=输出片段
  cell "$1" 'bc_fw_norm "$T/fw/base.json" "$T/fw/'"$3"'.json"; echo "RC=$?"'
  judge "$1" "$2" 判定="$(rcst "$1" == "$4")" 原因="$(yn has "$1" "$5")"
}
want W1 && wcase W1 "两份只差 handle、metainfo 与 counter 的 packets / bytes ⇒ 一致(计数单列)" w1 0 "运行计数(不进一致性判断"
want W2 && wcase W2 "redirect 端口 7893 → 7894 ⇒ 不一致" w2 1 "不一致: 链 prerouting 第 2 条规则不同"
want W3 && wcase W3 "同一链里两条规则对调 ⇒ 不一致(规则顺序保留比较)" w3 1 "不一致: 链 input 第 1 条规则不同"
want W4 && wcase W4 "链优先级不同 ⇒ 不一致" w4 1 "不一致: 链 input 属性不同"
want W5 && wcase W5 "源地址前缀长度不同 ⇒ 不一致" w5 1 "不一致: 链 prerouting 第 2 条规则不同"
want W6 && wcase W6 "出现不支持的语句 ⇒ 未取得" w6 2 "不支持的语句 log"
want W8 && wcase W8 "匿名集合元素顺序不同 ⇒ 一致" w8 0 "一致: 表"
want W7 && { cell W7 'printf "#!/usr/bin/env bash\necho \"nft \$*\" >> \"\$FK\"; echo \"served nft-fail\" >> \"\$FK\"; exit 1\n" > "$C/bin/nft"; chmod +x "$C/bin/nft"
  bc_fw_compare gate-x; echo "RC=$?"'
  judge W7 "宿主 nft list 退出 1 ⇒ 未取得(不判一致也不判不一致)" 判定="$(rcst W7 == 2)" 原因="$(yn has W7 '一致性未取得')" 命中="$(yn [ "$(served W7 nft-fail)" == 1 ])" \
    留证="$(yn grep -q '^未取得' "$T/cell-W7/evid/03-fw-gate-x.txt")"; }

# ── G: B 前像门的 GMS 判据(bc_gate_b 执行原文; 持续运行 / ios_slots / 防火墙内核一致性比较是登记替身) ──
GMS_TPL_SHA=48ecd4ce035e2fc9aae9af29b1548b78248fe6a897c7ed5dd7902ad6797b2aae   # v1.11.15 deploy/firewall/nftables-mihomo.conf(与桥接 / 候选 / 验收 HEAD 的同名文件逐字节相同)
gsample(){   # $1=落点 $2=strip|nostrip|nostruct → 0 / 1(模板摘要不符或渲染失败)
  local tpl="$ROOT/deploy/firewall/nftables-mihomo.conf" rp
  if [[ "$2" == nostruct ]]; then printf '%s\n' '#!/usr/sbin/nft -f' '# 只有注释: 没有 table inet pdg, 也没有 redirect 规则' > "$1"; return; fi
  [[ "$(sha256sum < "$tpl" 2>/dev/null | cut -c1-64)" == "$GMS_TPL_SHA" ]] || return 1
  rp="$(python3 "$ROOT/deploy/bot/rescue_const.py" --port 2>/dev/null)" || return 1
  [[ "$rp" =~ ^[0-9]+$ ]] || return 1
  # e2e_seed_nft 的同一组替换(e2e-lib.sh)
  sed -e "s|__SSH_PORT__|22|g" -e "s|__SSH_MATCH__||g" -e "s|__TAILNET_DIRECT__|# (SSH 未收紧为 tailnet, 故不放行 Tailscale 直连端口)|g" \
      -e "s|__INTERNAL_CIDR__|127.0.0.0/8|g" -e "s|__RESCUE_PORT__|$rp|g" "$tpl" > "$1" || return 1
  [[ "$2" == strip ]] || return 0
  # v1.11.15 _pdg_nft_strip_gms 的两条 sed 原文: 只改有效规则, 注释原样
  sed -E -i 's#(tcp dport [{] 53, 80, 81, 443, 853), 5228-5230, 8445 [}] accept#\1, 8445 } accept#' "$1" || return 1
  sed -E -i 's#(tcp dport [{] 80, 443), 5228-5230 [}] redirect#\1 } redirect#' "$1"
}
_gb='r3_stable_assert(){ leaf "stable $1"; ok "$3"; return 0; }
ios_slots(){ leaf ios_slots; printf "schema\t1\ncurrent\t有记录\t文件在\thealthy\tok\nprevious\t无记录\t文件不在\tmissing\t-\n"; }
bc_fw_compare(){ leaf "fw $1"; return 0; }
echo ios > "$R3_ETC/platform"; printf "proxies: []\n" > "$MC"; export FAKE_SS_PORT=7894
printf "{}\n" > "$IOS_META"; printf "x\n" > "$IOS_ART/current.mobileconfig"
bc_fp_take b0 "$IOS_META" "$IOS_ART/current.mobileconfig" || echo FPTAKE=失败
BC_NFT_CONF="$C/nft.conf"'
_gs='echo "SAMPLE=$(sha256sum < "$C/nft.conf" | cut -c1-64) COMMENT5228=$(grep -c "^[[:space:]]*#.*5228" "$C/nft.conf") EFF5228=$(grep -v "^[[:space:]]*#" "$C/nft.conf" | grep -c 5228)"'
want G1 && { cell G1 "$_gb"$'\n''gsample "$C/nft.conf" strip || echo GSAMPLE=失败'$'\n'"$_gs"$'\n''bc_gate_b; echo "RC=$?"'
  judge G1 "健康样本(冻结旧模板渲染 + 旧版 GMS 清理, 注释里仍有 5228)⇒ 不因注释阻断" 判定="$(rcst G1 == 0)" \
    样本="$(yn bash -c '[[ "$1" =~ COMMENT5228=[1-9][0-9]*\ EFF5228=0 ]]' _ "$(O_ G1)")" 原因="$(yn has G1 'VOK B 前像: 磁盘防火墙的有效规则里已无 GMS 5228-5230')"; }
want G2 && { cell G2 "$_gb"$'\n''gsample "$C/nft.conf" nostrip || echo GSAMPLE=失败'$'\n'"$_gs"$'\n''bc_gate_b; echo "RC=$?"'
  judge G2 "渲染后没做 GMS 清理(有效规则含 5228-5230)⇒ 阻断" 判定="$(rcst G2 == 1)" \
    样本="$(yn bash -c '[[ "$1" =~ EFF5228=[1-9] ]]' _ "$(O_ G2)")" 原因="$(yn has G2 '有效规则仍含 5228')"; }
want G3 && { cell G3 "$_gb"$'\n''gsample "$C/nft.conf" strip || echo GSAMPLE=失败; chmod 000 "$C/nft.conf"; ( : < "$C/nft.conf" ) 2>/dev/null && echo HIT=否 || echo HIT=是'$'\n''bc_gate_b; echo "RC=$?"; chmod 644 "$C/nft.conf"'
  judge G3 "防火墙文件读不了 ⇒ 未取得并阻断" 判定="$(rcst G3 == 1)" 原因="$(yn has G3 '读不了')" 未取得="$(yn has G3 'GMS 清理未取得')" 命中="$(yn has G3 HIT=是)"; }
want G4 && { cell G4 "$_gb"$'\n''gsample "$C/nft.conf" nostruct'$'\n'"$_gs"$'\n''bc_gate_b; echo "RC=$?"'
  judge G4 "只有注释、认不出表与 redirect 规则(也不含 5228)⇒ 未取得并阻断" 判定="$(rcst G4 == 1)" 原因="$(yn has G4 '结构认不出')" 未取得="$(yn has G4 'GMS 清理未取得')"; }
_leaves_g="${_leaves/'bc_gate_b(){ leaf gate_b; }; '/}"            # 与 H 组同一套叶子替身, 只把 bc_gate_b 换回原文
[[ "$_leaves_g" != "$_leaves" ]] || bad "G5/G6 叶子替身里没找到 bc_gate_b 那一项 —— 下面两格不可信"
gmain(){   # $1=格 $2=样本形态 → bc_main(构造 / 静置 / 第二跳后判据 / 第三跳门的其余前提为叶子替身; bc_gate_b 执行原文)
  cell "$1" "$_leaves_g"$'\n'"$_gb"$'\n''gsample "$C/nft.conf" '"$2"' || echo GSAMPLE=失败'$'\n'"$_gs"$'\n''bc_main; echo "RC=$?"'; }
want G5 && { gmain G5 nostrip
  judge G5 "有效规则残留 5228 ⇒ 前像门阻断, 两跳都不调用" 返回="$(rcst G5 == 1)" 第二跳替身="$(yn [ "$(calls G5 hop2)" == 0 ])" \
    第三跳替身="$(yn [ "$(calls G5 hop3)" == 0 ])" 计数="$(yn [ "$(cnt G5 hop2)/$(cnt G5 hop3)" == 0/0 ])" 原因="$(yn has G5 '前像门不成立')"; }
want G6 && { gmain G6 strip
  judge G6 "健康样本 ⇒ 前像门放行, 第二跳 1 次、第三跳 1 次" 返回="$(rcst G6 == 0)" 第二跳替身="$(yn [ "$(calls G6 hop2)" == 1 ])" \
    第三跳替身="$(yn [ "$(calls G6 hop3)" == 1 ])" 计数="$(yn [ "$(cnt G6 hop2)/$(cnt G6 hop3)" == 1/1 ])" 门原文="$(yn has G6 'VOK B 前像: 磁盘防火墙的有效规则里已无 GMS 5228-5230')"; }

# ── K: 模块清单不能空过(bc_modules 执行原文; 清单是格里写的 lib/modules.sh) ──
_ksrc='mkdir -p "$C/src/lib" "$C/src/deploy/bot"; for m in a i d; do printf "k-%s\n" "$m" > "$C/src/deploy/bot/$m.py"; cp "$C/src/deploy/bot/$m.py" "$R3_MODDIR/$m.py"; done
cp "$FX/br/lib/modules.sh" "$C/src/lib/modules.sh"'
_krun='bc_modules "$C/src" "$R3_MODDIR" "$KPLAT"; r=$?; echo "RC=$r"; echo "VAL=[$R3_VAL]"; echo "WHY=[$R3_WHY]"'
kcase(){   # $1=格 $2=说明 $3=平台 $4=清单覆写(空 = 夹具原样) $5=期望返回 $6=期望 VAL(空 = 不核) $7=原因片段(空 = 不核)
  local ov=""
  [[ -z "$4" ]] || ov='cat > "$C/src/lib/modules.sh" <<"EOM"'$'\n'"$4"$'\n''EOM'
  cell "$1" "$_ksrc"$'\n'"$ov"$'\n''KPLAT='"$3"$'\n'"$_krun"
  judge "$1" "$2" 判定="$(rcst "$1" == "$5")" 值="$(yn bash -c '[[ -z "$1" ]] || [[ "$2" == *"VAL=[$1]"* ]]' _ "$6" "$(O_ "$1")")" \
    原因="$(yn bash -c '[[ -z "$1" ]] || [[ "$2" == *"$1"* ]]' _ "$7" "$(O_ "$1")")"
}
want K1 && kcase K1 "正常 iOS 清单(2 项)⇒ 2 项逐字节一致" ios "" 0 "2 0" ""
want K2 && kcase K2 "正常 Android 清单(2 项)⇒ 2 项逐字节一致" android "" 0 "2 0" ""
want K3 && kcase K3 "清单函数返回 1 ⇒ 未取得" ios 'pdg_platform_modules(){ return 1; }' 2 "" ""
want K4 && kcase K4 "非空但没有有效项(两行 junk)⇒ 未取得, 不是 0 项一致" ios 'pdg_platform_modules(){ printf "%s\n" junk morejunk; }' 2 "" "格式不对"
want K5 && kcase K5 "缺 mode 列 ⇒ 未取得" ios 'pdg_platform_modules(){ printf "%s\n" "deploy/bot/a.py a.py"; }' 2 "" "格式不对"
want K6 && kcase K6 "目标名重复 ⇒ 未取得" ios 'pdg_platform_modules(){ printf "%s\n" "deploy/bot/a.py a.py 644" "deploy/bot/a.py a.py 644"; }' 2 "" "重复"
want K7 && hcase K7 "桥接树清单是 junk ⇒ 身份门不放行第三跳" 'mkdir -p "$C/brj"; cp -a "$FX/br/." "$C/brj/"; BRSRC="$C/brj"
cat > "$C/brj/lib/modules.sh" <<"EOM"
pdg_platform_modules(){ printf "%s\n" junk morejunk; }
EOM' 非0 1 0 "身份观测无效(模块)"

# ── N: 服务字段与 C4 核同一次观测 ──
_n1='BC_PRE=c2; BC_PLAT=android; echo android > "$R3_ETC/platform"; mkdir -p "$CA_DIR"; echo crt > "$CA_DIR/ca.crt"; echo key > "$CA_DIR/ca.key"
printf "{}\n" > "$MJ"; printf "{}\n" > "$IOS_META"; printf "x\n" > "$IOS_ART/current.mobileconfig"'
_cutfail='printf "#!/usr/bin/env bash\necho \"cut \$*\" >> \"\$FK\"; echo \"served cut-fail\" >> \"\$FK\"; exit 1\n" > "$C/bin/cut"; chmod +x "$C/bin/cut"'
_cutf13='printf "#!/usr/bin/env bash\ncase \" \$* \" in *\" -f13 \"*) exec /usr/bin/cut \"\$@\";; esac\necho \"cut \$*\" >> \"\$FK\"; echo \"served cut-fail\" >> \"\$FK\"; exit 1\n" > "$C/bin/cut"; chmod +x "$C/bin/cut"'   # 收窄的 cut 替身: 共享 bridge_row_valid 的 -f13 照常, 其余失败(D361-1)
mktab n1 'show:LoadState pdg-mitm|0|not-found\n|' 'is-active pdg-mitm|4|inactive\n|'
mktab n2 'show:LoadState pdg-mitm|0|not-found\n|' 'is-active pdg-mitm#1|1|inactive\n|' 'is-active pdg-mitm|4|inactive\n|'
mktab n4 'show:ActiveState mosdns|0|failed\n|' 'show:SubState mosdns|0|failed\n|' 'is-active mosdns|3|failed\n|'
mktab n7 'show:LoadState pdg-mitm|0|not-found\n|' 'is-active pdg-mitm#1|1|inactive\n|' 'is-active pdg-mitm|3|inactive\n|' 'show:ActiveState pdg-mitm|0|inactive\n|'
want N1 && { cell N1 "$_n1"$'\n''SCFIX="$T/sc-n1.tab"; bc_precapture; echo "RC=$?"'
  judge N1 "C4 健康(inactive / 4 配 LoadState=not-found)⇒ 调用前观测取全" 判定="$(rcst N1 == 0)" \
    留证="$(yn fhas "$T/cell-N1/evid/08-c4-observation.txt" '原始退出码 4')"; }
want N2 && { cell N2 "$_n1"$'\n''SCFIX="$T/sc-n2.tab"; bc_identity(){ leaf identity; }; bc_dns_instrument(){ leaf dns; }; bc_quiesce(){ leaf "quiesce $1"; }
bc_runtime_gate(){ leaf runtime; }; bc_dns_pre(){ leaf dns_pre; }; cp "$FX/br/deploy/bot/pdg.sh" "$R3_CLI"; bc_gated_invoke; echo "RC=$?"'
  judge N2 "第一次 is-active 先打印 inactive 再以 1 退出、之后健康 ⇒ C4 无效, 第三跳不调用" 判定="$(rcst N2 == 26)" \
    第三跳替身="$(yn [ "$(calls N2 hop3)" == 0 ])" 计数="$(yn [ "$(cnt N2 hop3)" == 0 ])" 原因="$(yn has N2 'C4')" 命中="$(yn [ "$(served N2 'is-active pdg-mitm#1 -> rc=1')" == 1 ])"; }
want N3 && { cell N3 'n3(){ local esc="$1" rc="$2" ld="$3" cap a b
  printf "%s\n" "show:LoadState pdg-mitm|0|$ld\\n|" "is-active pdg-mitm|$rc|$esc|" > "$C/n3.tab"; SCFIX="$C/n3.tab"
  cap="$(printf "%b" "$esc")"
  if r3_unit_q active pdg-mitm "$ld"; then a=成立; else a=无效; fi
  if bc_isactive_pair "$cap" "$rc" "$ld"; then b=成立; else b=无效; fi
  echo "PAIR [$esc]/$rc/$ld 共享读取器=$a 新判定=$b"; [[ "$a" == "$b" ]] && echo AGREE; [[ "$b" == 成立 ]] && echo VALIDPAIR; return 0; }
n3 "active\n" 0 loaded; n3 "inactive\n" 3 loaded; n3 "inactive\n" 4 not-found; n3 "failed\n" 3 loaded
n3 "inactive\n" 4 loaded; n3 "active\n" 3 loaded; n3 "inactive\n" 0 loaded; n3 "junk\n" 0 loaded; n3 "active\nactive\n" 0 loaded; n3 "" 3 loaded
echo "RC=0"'
  judge N3 "C4 配对判定与共享读取器 r3_unit_q 同规则(10 组输入逐项一致; 4 组成立、6 组无效)" \
    一致="$(yn [ "$(fcnt "$T/out-N3" AGREE "")" == 10 ])" 成立数="$(yn [ "$(fcnt "$T/out-N3" VALIDPAIR "")" == 4 ])"; }
want N4 && { cell N4 "$_real_sample"$'\n'"$_cutf13"$'\n''SCFIX="$T/sc-n4.tab"; bc_svc_no_failed gate-n; echo "RC=$?"'
  judge N4 "mosdns 处于 failed、cut 替身失败 ⇒ 仍判出有 failed(不经 cut 取字段)" 判定="$(rcst N4 == 1)" 原因="$(yn has N4 '有 failed 的 unit: mosdns')" \
    不经cut="$(yn [ "$(served N4 cut-fail)" == 0 ])"; }
want N4c && { cell N4c "$_real_sample"$'\n''SCFIX="$T/sc-n4.tab"; bc_svc_no_failed gate-n; echo "RC=$?"'
  judge N4c "对照: 同一现场不装 cut 替身 ⇒ 判出有 failed" 判定="$(rcst N4c == 1)" 原因="$(yn has N4c '有 failed 的 unit: mosdns')"; }
want N4b && { cell N4b 'bc_svc_phase(){ declare -gA BC_SVC_ROWS=(); BC_SVC_ROWS[pdg-mitm]="$(row pdg-mitm loaded active running enabled 100 0123456789abcdef0123456789abcdef ok)"
  BC_SVC_ROWS[sing-box]="$(row sing-box not-found inactive dead "" 0 - ok)"
  BC_SVC_ROWS[mosdns]="$(printf "%s\t" mosdns mosdns.service service loaded failed dead enabled 0 - 0 probe)ok"; leaf "svc_phase $1"; return 0; }
bc_svc_no_failed gate-n; echo "RC=$?"'
  judge N4b "采样行只有 12 列(字段对不上位置)⇒ 观测无效" 判定="$(rcst N4b == 1)" 原因="$(yn has N4b '观测无效')"; }
_n5rows='b="$(row mosdns loaded active running enabled 200 fedcba9876543210fedcba9876543210 ok)"; a="$(row mosdns loaded inactive dead disabled 0 - ok)"'
want N5 && { cell N5 "$_cutfail"$'\n'"$_n5rows"$'\n''cls="$(bc_svc_class hop2 b mosdns "$b" "$a")"; echo "CLS=${cls%%|*}"; echo "RC=0"'
  judge N5 "mosdns 从 active / enabled 变成 inactive / disabled、cut 替身失败 ⇒ 仍归'意外'" 判定="$(yn has N5 'CLS=意外')" 不经cut="$(yn [ "$(fkn N5 'cut ')" == 0 ])"; }
want N5c && { cell N5c "$_n5rows"$'\n''cls="$(bc_svc_class hop2 b mosdns "$b" "$a")"; echo "CLS=${cls%%|*}"; echo "RC=0"'
  judge N5c "对照: 不装 cut 替身 ⇒ 归'意外'" 判定="$(yn has N5c 'CLS=意外')"; }
want N5b && { cell N5b "$_n5rows"$'\n''a="$(printf "%s\t" mosdns mosdns.service service loaded inactive dead disabled 0 - 0 probe)ok"; cls="$(bc_svc_class hop2 b mosdns "$b" "$a")"; echo "CLS=${cls%%|*}"; echo "RC=0"'
  judge N5b "后一行只有 12 列 ⇒ 归'观测无效'" 判定="$(yn has N5b 'CLS=观测无效')"; }
want N6 && { cell N6 "$_cutf13"$'\n''{ row pdg-mitm loaded active running enabled 100 0123456789abcdef0123456789abcdef ok; row mosdns loaded active running enabled 200 fedcba9876543210fedcba9876543210 ok
  row sing-box not-found inactive dead "" 0 - ok; } > "$C/wk/b.tsv"
{ row pdg-mitm loaded active running enabled 101 0123456789abcdef0123456789abcde0 ok; row mosdns loaded inactive dead enabled 0 - ok
  row sing-box not-found inactive dead "" 0 - ok; } > "$C/wk/a.tsv"
printf "%s\t%s\t-\n" pdg-mitm 1 mosdns 0 sing-box 0 > "$C/wk/w.tsv"
bc_svc_verdict "$C/wk/b.tsv" "$C/wk/a.tsv" hop2 "$C/wk/w.tsv"; echo "RC=$?"'
  judge N6 "调用后 mosdns 停了、cut 替身失败 ⇒ 不给通过, 意外列表含 mosdns" 判定="$(rcst N6 == 1)" 原因="$(yn has N6 '出现清单外的服务动作: mosdns')"; }
want N7 && { cell N7 "$_tb"$'\n''SCFIX="$T/sc-n7.tab"; bc_post_b; echo "RC=$?"'
  judge N7 "调用后 is-active 第一次先打印 inactive 再以 1 退出 ⇒ 不给总体通过" 判定="$(rcst N7 == 1)" 原因="$(yn has N7 'pdg-mitm is-active 观测无效')" \
    命中="$(yn [ "$(served N7 'is-active pdg-mitm#1 -> rc=1')" == 1 ])"; }

# ── E: B 终态记录核对的执行、输出与结论一致(bc_post_b 执行原文; 只对它那一次 python 调用套包装) ──
_pyw='python3(){ if [[ "${2:-}" == "$BC_TMP/ios-before-hop3.json" && -n "${PYW_MODE:-}" ]]; then
    echo "pyw $PYW_MODE" >> "$FK"; echo "served pyw-$PYW_MODE" >> "$FK"
    local tf r
    case "$PYW_MODE" in
      trunc) tf="$(mktemp "$BC_TMP/pyw.XXXXXX")"; command python3 "$@" > "$tf"; r=$?; head -5 "$tf"; rm -f "$tf"; return "$r";;
      unread) command python3 "$@"; r=$?; chmod 000 "$BC_TMP/post-b-record.txt"; return "$r";;
      rc3) command python3 "$@"; return 3;;
      rc0) command python3 "$@"; return 0;;
    esac
  fi
  command python3 "$@"; }'
ecase(){   # $1=格 $2=说明 $3=注入(包装模式 / 现场改动) $4=期望返回 $5=原因片段 $6=命中片段(空 = 不核) $7=包装自己的记录次数(served pyw-*)
  cell "$1" "$_tb"$'\n'"$_pyw"$'\n'"$3"$'\n''bc_post_b; echo "RC=$?"; ( : < "$BC_TMP/post-b-record.txt" ) 2>/dev/null || echo UNREAD=是; chmod 600 "$BC_TMP/post-b-record.txt" 2>/dev/null'
  judge "$1" "$2" 判定="$(rcst "$1" == "$4")" 原因="$(yn has "$1" "$5")" 命中="$(yn bash -c '[[ -z "$1" ]] || [[ "$2" == *"$1"* ]]' _ "${6:-}" "$(O_ "$1")")" \
    包装="$(yn [ "$(served "$1" pyw-)" == "$7" ])"
}
want E1 && ecase E1 "健康终态 ⇒ 成立" ':' 0 "VOK B 终态: 记录 schema 1 → 2" "" 0
want E2 && ecase E2 "真实业务差异(current.mobileconfig 被删)⇒ 不成立, 失败行就是业务差异" 'rm -f "$IOS_ART/current.mobileconfig"' 1 "VBAD B 终态: current.mobileconfig 仍在" "" 0
want E3 && ecase E3 "核对输出被截成前 5 行(退出码照旧 0)⇒ 观测无效" 'export PYW_MODE=trunc' 1 "记录核对观测无效" "" 1
want E4 && ecase E4 "核对写完后结果文件读不了 ⇒ 观测无效" 'export PYW_MODE=unread' 1 "读不了" "UNREAD=是" 1
want E5 && ecase E5 "返回 3 却没有任何失败记录 ⇒ 观测无效" 'export PYW_MODE=rc3' 1 "记录核对观测无效" "" 1
want E6 && ecase E6 "返回 0 却有失败记录(矛盾)⇒ 观测无效, 不当成已证实的业务差异" 'rm -f "$IOS_ART/current.mobileconfig"; export PYW_MODE=rc0' 1 "记录核对观测无效" "" 1

# ── 绊线: 所有格里"仅参考结构 / 不用"的函数一次都没被调用 ──
if ! rdf "$T/forbidden.log"; then bad "M-9 绊线记录读不了 —— 不说成调用 0 次"
elif [[ -n "$RDV" ]]; then bad "M-9 有格调用了仅参考结构 / 不用的函数: $(sort -u "$T/forbidden.log" | head -5 | tr '\n' ' ')"
else ok "M-9 各格里 ${#FORBID_M[@]} 个仅参考结构 / 不用的函数都装了绊线, 调用 0 次"; fi
fin

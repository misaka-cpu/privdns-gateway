#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ③ 的接线契约(不碰真实服务; 不需要 root / systemd; 本机与 CI 都能跑)。
#
# 验三件事, 各自具名:
#   一、workflow 接线: 相对验收基线**只**多了 retire-hop 这一个范围选项与 real-retire-hop 这一个 job;
#       real-bridge-hop 与其它 job 逐字不变; 新 job 里 ② 原样跑且 pipefail 不吞退出码, ③ 只在 ② 成功后启动。
#   二、③ 脚本的静态边界: 升级调用只有一处(timeout 包装的现役 CLI update --to), 不预置能力句柄,
#       不向现役目录拷候选文件; 观测读取走核过退出码的读取器; ② 脚本与共享夹具相对基线逐字不变。
#   三、③ 的判据函数(按唯一成对标记抽出来, 受控输入驱动):
#       ② 失败 / 未执行 / 截断 / 查询出错、桥接身份不符或观测无效、调用前观测没取全、调用计数不可用
#       ⇒ 不调用(桩 CLI 自己的调用记录为 0 次, 不只看脚本自记的计数);
#       读取器: 摘要 / 元数据 / ss / comm / tag 查询失败都是"观测无效", 不当成"原样""零监听""不存在";
#       退出码按来源命名: 包装器(timeout)返回码、timeout 的发信号记录、产品原始退出码分开结算;
#       服务对账: 窗口内启动事件计数按 unit 参与判定(不因前后状态相同而跳过), 窗口值非法 / 重复 / 缺行 / 读不了都不产出通过。
#   每个负控同时核: 注入是否命中、具体失败原因、调用次数(桩的独立记录)、被测函数的返回值。
#
# 运行态门(r3_runtime_gate)、持续运行判据(r3_stable_assert → 共享 svc_stable_window 全链, 含 journal 界桩与启动事件)
# 与调用后的 W1 / ③-4(r3_post_w1 / r3_post_runtime)都执行**判断原文**; 只替换外部命令与本格无关的依赖, 全部显式登记,
# 路径都落在本支临时目录:
#   外部命令替身: systemctl / journalctl / logger 是 $T/bin 下的可执行脚本(只在格的子壳里放到 PATH 最前 —— ③ 的查询记账
#     包装与真实运行一样经 PATH 截到它们): systemctl 按表作答(状态词 / 退出码 / stderr, 可指定"第 N 次调用"的应答),
#     journalctl / logger 模拟界桩与启动事件记录; curl、dig、ss、sleep(空转)是格内函数 —— 每次被调都记进 $T/fk-<格名>;
#   本格无关依赖: bridge_svc_sample(按夹具文件落盘)。
# 这些仍是模型验证, 不冒充真实 systemd、journal、DNS、HTTP 验收。
# ③ 主流程在调用之后的其余接线(W2–W7、K、A4、A6 的调用点)只做静态核对(二-9 起), 读取器本身在三 / 四里受控驱动。
# 临时仓库的写操作(add / commit / tag / checkout / config / remote)逐调用点走 e2e_git 并显式指定目标仓库。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDG_ACCEPT_BASE:-97b1d01c16539b185f96f036d6373779783f0f76}"   # 验收基线(accept/wloc-real-1)
R3="$ROOT/tests/e2e-real-retire-hop.sh"; HOP2="$ROOT/tests/e2e-real-bridge-hop.sh"; WF="$ROOT/.github/workflows/ci.yml"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/r3c.XXXXXX")" || { echo "[未执行] 建不出临时目录"; echo "通过 0, 失败 1"; exit 1; }
trap 'rm -rf -- "$T"' EXIT
for f in "$R3" "$HOP2" "$WF" "$ROOT/tests/repoguard.sh"; do [[ -f "$f" ]] || { bad "找不到 $f"; echo "通过 $pass, 失败 $nfail"; exit 1; }; done
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null \
  || { bad "取不到验收基线对象 $BASE —— 接线核对无从谈起"; echo "通过 $pass, 失败 $nfail"; exit 1; }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"          # e2e_git: 守卫与写操作绑成一件事
E2E_ROOT="$ROOT"                            # 守卫据此拒绝任何与源码仓库共用 ref 库的目标

echo "══ 一. workflow 接线 ══"
git -C "$ROOT" show "$BASE:.github/workflows/ci.yml" > "$T/base-ci.yml" || bad "基线 ci.yml 取不到"
python3 - "$T/base-ci.yml" "$WF" > "$T/wf.txt" 2>&1 <<'PY'
import difflib, sys
b = open(sys.argv[1], encoding="utf-8").read().split("\n"); c = open(sys.argv[2], encoding="utf-8").read().split("\n")
expect_repl = {   # 基线旧行 → 唯一允许的新行
    '        description: "真实验收的范围(默认 all; platform = 只跑⑤a/⑤b; retire = 只跑④; bridge = 只跑② v1.11.15→桥接)"':
    '        description: "真实验收的范围(默认 all; platform = 只跑⑤a/⑤b; retire = 只跑④; bridge = 只跑② v1.11.15→桥接; retire-hop = ②+③ 同一 job)"',
    '        options: ["all", "platform", "retire", "bridge"]':
    '        options: ["all", "platform", "retire", "bridge", "retire-hop"]',
}
bad = []
for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, b, c, autojunk=False).get_opcodes():
    if tag == "equal":
        continue
    old, new = b[i1:i2], c[j1:j2]
    if tag == "insert" and i1 >= len(b) - 1 and b[-1] == "":
        print("APPEND %d 行" % len(new)); continue            # 文件末尾追加的 job 块(内容另行核)
    if tag == "insert" and new == ["        # 选 retire-hop 就只跑③(已安装桥接 → 退役候选; 同一 job 里先原样跑 ② 取得真实桥接前像)。"]:
        print("INSERT 注释 1 行"); continue
    if tag == "replace" and len(old) == len(new) and all(o in expect_repl and expect_repl[o] == n for o, n in zip(old, new)):
        print("REPLACE %d 行(real_scope 的说明与选项)" % len(old)); continue
    bad.append("%s 基线 %d-%d → 现 %d-%d: %r → %r" % (tag, i1 + 1, i2, j1 + 1, j2, old[:2], new[:2]))
for x in bad:
    print("UNEXPECTED " + x)
sys.exit(1 if bad else 0)
PY
case $? in
  0) ok "一-1 相对基线的改动只有: real_scope 注释 1 行 + 说明/选项 2 行 + 末尾追加的 job 块 ($(tr '\n' ';' < "$T/wf.txt"))";;
  *) bad "一-1 workflow 有基线之外的改动: $(grep UNEXPECTED "$T/wf.txt" | head -3 | tr '\n' ' ')";;
esac
grep -q 'options: \["all", "platform", "retire", "bridge", "retire-hop"\]' "$WF" \
  && ok "一-2 real_scope 选项里有 retire-hop(原有四项顺序不变)" || bad "一-2 real_scope 选项不对"
# 新 job 块: 从 "  real-retire-hop:" 到文件末尾
awk '/^  real-retire-hop:$/{f=1} f' "$WF" > "$T/job.yml"
[[ -s "$T/job.yml" ]] && ok "一-3 找到 job real-retire-hop" || bad "一-3 没有 job real-retire-hop"
grep -qF "github.event.inputs.real_scope == 'retire-hop'" "$T/job.yml" && ! grep -qE "real_scope == '(all|)'" "$T/job.yml" \
  && ok "一-4 real-retire-hop 只在 real_scope=retire-hop 时启动" || bad "一-4 real-retire-hop 的启动条件不对"
grep -q 'continue-on-error' "$T/job.yml" && bad "一-5 新 job 里有 continue-on-error" || ok "一-5 新 job 里没有 continue-on-error"
l2="$(grep -n '^        id: real2$' "$T/job.yml" | cut -d: -f1)"; l3="$(grep -n '^        id: real3$' "$T/job.yml" | cut -d: -f1)"
lc="$(grep -n 'run: bash tests/test-retire-hop-contract.sh' "$T/job.yml" | cut -d: -f1)"
{ [[ -n "$l2" && -n "$l3" && -n "$lc" ]] && (( lc < l2 && l2 < l3 )); } \
  && ok "一-6 顺序: ③ 契约 → ② 原样(id real2) → ③(id real3)" || bad "一-6 步骤顺序不对(契约=$lc real2=$l2 real3=$l3)"
sed -n "${l2:-1},${l3:-1}p" "$T/job.yml" > "$T/real2.yml"
grep -qx '        shell: bash' "$T/real2.yml" && grep -qx '          set -o pipefail' "$T/real2.yml" \
  && ok "一-7 ② 步用 bash + pipefail(tee 不吞 ② 的退出码)" || bad "一-7 ② 步没有 pipefail 保护"
grep -qx '          sudo -E bash tests/e2e-real-bridge-hop.sh 2>&1 | tee /tmp/real2-stdout.log' "$T/real2.yml" \
  && ok "一-8 ② 步跑的就是原样的 tests/e2e-real-bridge-hop.sh" || bad "一-8 ② 步的调用不是原样脚本"
# ② 步的 env 与 real-bridge-hop 的 ② 步逐项相同(键与值)
python3 - "$WF" > "$T/env.txt" 2>&1 <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
def env_of(block):
    m = re.search(r"\n        env:\n((?:          [A-Z0-9_]+: .*\n)+)", block)
    return m.group(1) if m else None
jb = s.split("\n  real-bridge-hop:\n", 1)[1].split("\n  real-retire-hop:\n", 1)[0]
jr = s.split("\n  real-retire-hop:\n", 1)[1]
a = env_of(jb.split("run: sudo -E bash tests/e2e-real-bridge-hop.sh", 1)[0].rsplit("      - name:", 1)[1])
b = env_of(jr.split("        id: real2\n", 1)[1].split("      - name:", 1)[0])
print(a); print("----"); print(b)
sys.exit(0 if a and a == b else 1)
PY
[[ $? == 0 ]] && ok "一-9 ② 步的 env 与 real-bridge-hop 的 ② 步逐字相同" || bad "一-9 ② 步的 env 与 real-bridge-hop 不同($(head -c 200 "$T/env.txt" | tr '\n' ' '))"
sed -n "${l3:-1},\$p" "$T/job.yml" > "$T/real3.yml"
grep -qF "if: \${{ success() && steps.real2.outcome == 'success' }}" "$T/real3.yml" \
  && ok "一-10 ③ 步只在 ② 成功后启动" || bad "一-10 ③ 步没有以 ② 成功为条件"
grep -qx '        run: sudo -E bash tests/e2e-real-retire-hop.sh' "$T/real3.yml" && ok "一-11 ③ 步跑 tests/e2e-real-retire-hop.sh" || bad "一-11 ③ 步的调用不对"
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert "real-retire-hop" in d["jobs"] and "real-bridge-hop" in d["jobs"]' "$WF" \
    && ok "一-12 整份 workflow 能按 YAML 解析, 两个真实 job 都在" || bad "一-12 workflow 解析不过"
else
  echo "[NOTE] 一-12 本机没有 PyYAML, YAML 解析这一格未验(文本核对已覆盖接线; 不计入通过)"
fi

echo; echo "══ 二. ③ 脚本的静态边界 ══"
grep -vE '^\s*#' "$R3" > "$T/r3code.txt"     # 去注释的代码先落文件: pipefail 下 grep -q 提前退出会让上游写管道失败
sed 's/^[[:space:]]*//' "$T/r3code.txt" > "$T/r3trim.txt"
IFS= read -r INV <<'EOF'
env -u PDG_UPDATE_SVCSTATE -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM timeout --verbose "$R3_TIMEOUT" bash -c 'bash "$1" update --to "$2" </dev/null >"$3" 2>&1; printf "%s\n" "$?" >"$4"' r3wrap "$R3_CLI" "$RETIRE_TAG" "$R3_LOG" "$R3_RCFILE" 2>"$R3_TOERR" || R3_WRAP_RC=$?
EOF
n_direct="$(grep -cF 'bash "$R3_CLI"' "$T/r3code.txt")"; n_wrap="$(grep -cF 'r3wrap "$R3_CLI"' "$T/r3code.txt")"
[[ "$n_direct" == 0 && "$n_wrap" == 1 ]] && ok "二-1 执行现役 CLI 的调用只有 1 处(经包装器), 没有直接调用的形态" \
  || bad "二-1 执行现役 CLI 的调用: 经包装器 $n_wrap 处, 直接 $n_direct 处"
n_inv="$(grep -cxF -- "$INV" "$T/r3trim.txt")"
[[ "$n_inv" == 1 ]] && ok "二-2 那一处就是 timeout --verbose 包装的现役 CLI update --to 退役 tag; 产品退出码由内层单独写进 R3_RCFILE, timeout 的 stderr 进 R3_TOERR" \
  || bad "二-2 调用行不是预期形态(逐字匹配 $n_inv 处)"
n_pdg="$(grep -cE '(^|[;&|(]\s*)(sudo\s+)?(bash\s+)?(/usr/local/bin/)?pdg\s+(update|__migrate|platform|rollback)' "$T/r3code.txt")"
[[ "$n_pdg" == 0 ]] && ok "二-2b 没有别的途径直接跑 pdg update / __migrate / rollback" || bad "二-2b 另有 $n_pdg 处直接跑 pdg"
grep -qx 'R3_REPO=/opt/privdns-gateway; R3_CLI=/usr/local/bin/pdg; R3_MODDIR=/opt/pdg-bot; R3_ETC=/etc/privdns-gateway' "$R3" \
  && ok "二-3 现役 CLI = /usr/local/bin/pdg(② 装上的那一份)" || bad "二-3 R3_CLI 不是 /usr/local/bin/pdg"
n_call="$(grep -cE '^\s*r3_invoke(\s|$)' "$T/r3code.txt")"
if [[ "$n_call" == 1 ]] && [[ "$(awk '/^r3_gated_invoke\(\)\{/{f=1} f&&/^\s*r3_invoke( |$)/{print "IN"; exit} f&&/^}/{exit}' "$R3")" == IN ]]; then
  ok "二-4 r3_invoke 只在 r3_gated_invoke 里被调用 1 次(门与调用前观测之后)"
else bad "二-4 r3_invoke 的调用点不对($n_call 处)"; fi
n_gi="$(grep -cE '^r3_gated_invoke; GRC=\$\?$' "$T/r3code.txt")"
[[ "$n_gi" == 1 ]] && ok "二-5 主流程只经 r3_gated_invoke 进入调用" || bad "二-5 主流程进入调用的方式不对($n_gi)"
if grep -qE 'PDG_UPDATE_SVCSTATE=' "$T/r3code.txt"; then bad "二-6 ③ 脚本给 PDG_UPDATE_SVCSTATE 赋了值"
elif grep -qF 'env -u PDG_UPDATE_SVCSTATE' "$T/r3code.txt"; then ok "二-6 不预置能力句柄(调用时 env -u PDG_UPDATE_SVCSTATE)"
else bad "二-6 没有显式清掉 PDG_UPDATE_SVCSTATE"; fi
grep -E '\b(cp|install|rsync|mv|ln)\b' "$T/r3code.txt" > "$T/r3write.txt"
if grep -qE '(/usr/local/bin|/opt/|R3_CLI|R3_MODDIR|R3_REPO)' "$T/r3write.txt"; then bad "二-7 ③ 脚本在往现役目录写文件(拷候选冒充升级)"
else ok "二-7 ③ 脚本不向 /usr/local/bin、/opt 或现役仓库拷文件"; fi
for f in tests/e2e-real-bridge-hop.sh tests/e2e-lib.sh tests/e2e-real-platform-fail.sh tests/repoguard.sh deploy/bot/pdg.sh; do
  if git -C "$ROOT" diff --quiet "$BASE" -- "$f" 2>/dev/null && git -C "$ROOT" diff --quiet -- "$f" 2>/dev/null; then ok "二-8 $f 相对基线逐字不变"
  else bad "二-8 $f 相对基线有改动"; fi
done
only_in(){   # $1=说明 $2=ERE $3=应在的函数名 → 去注释代码里恰 1 处匹配, 且那一行落在该函数体内
  local n ln; n="$(grep -cE -- "$2" "$T/r3code.txt")"
  ln="$(FN="$3" RE="$2" awk '$0 ~ ("^" ENVIRON["FN"] "\\(\\)\\{") {f=1} f && !/^[[:space:]]*#/ && $0 ~ ENVIRON["RE"] {print "IN"; exit} f&&/^}/{exit}' "$R3")"   # 走 ENVIRON: -v 会处理反斜杠转义
  [[ "$n" == 1 && "$ln" == IN ]] && ok "二-9 $1: 只在 $3 里出现 1 处" || bad "二-9 $1: 去注释代码里 $n 处, 在 $3 里=[${ln:-否}]"
}
only_in "ss 监听查询"        '\$\(ss -lnt'                   r3_listen_count
only_in "comm 快照差集"      '(^|[^a-z_])comm[[:space:]]+-'   r3_snapdiff
only_in "保留项元数据 stat"  "stat -c '%a %u:%g'"             r3_keepfp
only_in "tag 查询"           'refs/tags/'                     r3_tagsha
only_in "curl 状态码查询"    'curl -s -o'                     r3_http_code
only_in "dig 查询"           'dig \+time'                     r3_dns_a
only_in "is-active 查询"     'systemctl is-active'            r3_unit_q
only_in "is-enabled 查询"    'systemctl is-enabled'           r3_unit_q
only_in "LoadState 查询"     'show -p LoadState'              r3_unit_q
n_sc="$(grep -cE 'sc_(state|get) is-|bridge_set_check' "$T/r3code.txt")"
[[ "$n_sc" == 0 ]] && ok "二-13 ③ 不再经 sc_state / sc_get 取状态, 也不再调 ② 的 bridge_set_check" || bad "二-13 仍有 $n_sc 处"
body="$(awk '/^r3_set_check\(\)\{/{f=1} f && !/^[[:space:]]*#/ {sub(/[[:space:]]#.*/, ""); print} f&&/^}/{exit}' "$R3")"; body="${body//||/}"
[[ -n "$body" && "$body" != *'|'* ]] && ok "二-14 r3_set_check 里没有管道(整份读出核退出码后在 bash 里解析)" || bad "二-14 r3_set_check 里有管道或抽不到"
grep -qx 'R3_MITM_UNIT=/etc/systemd/system/pdg-mitm.service' "$R3" && [[ "$(grep -cxE 'r3_post_(w1|runtime)' "$T/r3code.txt")" == 2 ]] \
  && ok "二-15 调用后 W1 / ③-4 由主流程各调 1 次 r3_post_w1 / r3_post_runtime; unit 文件路径真实值不变" || bad "二-15 调用后接线不对"
n_ssa="$(grep -cE '^\s*svc_stable_assert\s' "$T/r3code.txt")"; n_rsa="$(grep -cE '^\s*r3_stable_assert\s' "$T/r3code.txt")"
n_win="$(awk '/^r3_stable_assert\(\)\{/{f=1} f && /^  PATH="\$wd:\$PATH" svc_stable_window "\$u" "\$want" "\$secs"; rc=\$\?$/{c++} f&&/^}/{exit} END{print c+0}' "$R3")"
n_exp="$(grep -cE 'export\s+(-f\s+)?systemctl|declare\s+-[a-z]*x[a-z]*\s+-?f?\s*systemctl|^\s*export\s+PATH|^\s*systemctl\s*\(\)' "$T/r3code.txt")"
[[ "$n_ssa" == 0 && "$n_rsa" == 7 && "$n_win" == 1 && "$n_exp" == 0 ]] \
  && ok "二-16 持续运行 7 处都经 r3_stable_assert; 它只以 PATH 前缀调一次共享窗口; ③ 里没有 systemctl 同名函数、没有 export PATH / 导出函数" \
  || bad "二-16 持续运行接线不对(直接调共享 $n_ssa / 经 ③ $n_rsa / 窗口调用 $n_win / 导出或同名 $n_exp)"
grep -qF '运行态 / WLOC 前像门: 调用前逐项现查。契约测试在受控外部命令下执行它的判断原文' "$R3" && ! grep -qF '只能在真机上看' "$R3" \
  && ok "二-17 ③ 里'运行态门只能在真机上看, 所以不进契约'的过时注释已更正" || bad "二-17 过时注释还在"
n_old="$(grep -cE 'keep_fp|124=超时|\|\| *c=0' "$T/r3code.txt")"
[[ "$n_old" == 0 ]] && ok "二-9 旧形态(② 的 keep_fp、「124=超时」、计数 0 兜底)已不在" || bad "二-9 旧形态仍有 $n_old 处"
grep -qxF 'KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform")' "$R3" && grep -qxF 'KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")' "$R3" \
  && ok "二-10 保留项: 必需 = CA 两件 + 平台标记, 可选 = bot.env / dot-domain(309 plan K1/K2)" || bad "二-10 保留项集合不是 309 plan 的 K1/K2"
grep -qxF 'r3_count_init || { echo "[HARD-STOP] 调用计数初始化失败: $R3_WHY —— 不调用" >&2; exit 1; }   # 任何门之前先落 0 并读回' "$R3" \
  && ok "二-11 调用计数初始化失败即具名硬停" || bad "二-11 调用计数初始化没有具名硬停"
n_case="$(grep -cE '^  (13|14|\*)\) +bad ' "$T/r3code.txt")"
[[ "$n_case" == 3 ]] && ok "二-12 主流程对 13 / 14 与未登记的门返回值都停在调用之后的判据之前" || bad "二-12 主流程的门返回值分支不全($n_case/3)"

echo; echo "══ 三. ③ 判据函数(受控输入) ══"
xfn(){   # $1=来源 $2..=名字 → 打印唯一成对标记之间的原文; 标记不唯一成对即失败
  local src="$1" n b e; shift
  for n in "$@"; do
    [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] || { echo "标记不唯一成对: $n" >&2; return 1; }
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"; e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    sed -n "$((b+1)),$((e-1))p" "$src"
  done
}
R3_BLOCKS=(r3_count r3_read r3_real2_gate r3_bridge_identity_gate r3_keep r3_precapture r3_invoke r3_gated_invoke r3_arrival_verdict r3_svc_class r3_svc_verdict r3_stable r3_runtime_gate r3_post)
if xfn "$R3" "${R3_BLOCKS[@]}" > "$T/r3fns.sh" \
   && xfn "$HOP2" bridge_row_valid > "$T/hop2fns.sh" && bash -n "$T/r3fns.sh" && bash -n "$T/hop2fns.sh" \
   && xfn "$ROOT/tests/e2e-real-platform-fail.sh" svc_stable_window unit_identify wait_stable _unit_wants_mainpid \
        _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval > "$T/pffns.sh" \
   && bash -n "$T/pffns.sh"; then
  ok "三-0 按唯一成对标记抽出 ③ 的 ${#R3_BLOCKS[@]} 段判据(含运行态门、持续运行、调用后检查)、② 的 1 段与共享持续运行全链 15 段原文(语法通过)"
else
  bad "三-0 抽取失败 —— 以下受控输入不执行"; echo "────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"; exit 1
fi
# ── 受控现场: 一次性对象库 + 裸库 + 现役仓库; 写操作逐个走 e2e_git ─────────────────
export GIT_CEILING_DIRECTORIES="$T"         # 受控现场里"不是仓库"的目录不许向上找到别的仓库
BRT="v9.9.8-bridge-TEST"; RTT="v9.9.9-retire-TEST"
G="$T/obj"; mkdir -p "$G/deploy/bot" "$G/lib"
git init -q "$G"
e2e_git "$G" config user.name t && e2e_git "$G" config user.email t@t && e2e_git "$G" config commit.gpgsign false \
  || { bad "三-0 夹具对象库配置失败(e2e_git 拒绝或 git 失败)"; echo "通过 $pass, 失败 $nfail"; exit 1; }
# 桩 CLI 自己记调用(STUB_CALLS): 这是与被测脚本无关的独立调用记录
stub_tail(){ cat <<'EOS'
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
printf '%s\n' "${STUB_OUT:-}"
sleep "${STUB_SLEEP:-0}"
exit "${STUB_RC:-0}"
EOS
}
{ printf '#!/usr/bin/env bash\n_pdg_save_svcstate(){ :; }\n_pdg_restore_svcstate(){ :; }\n'; stub_tail; } > "$G/deploy/bot/pdg.sh"
printf 'pdg_platform_modules(){ [[ "$1" == ios ]] && printf "%%s\\n" "deploy/bot/a.py a.py 644"; }\n' > "$G/lib/modules.sh"
echo bridge-a > "$G/deploy/bot/a.py"
e2e_git "$G" add -A && e2e_git "$G" commit -qm bridge; BR="$(git -C "$G" rev-parse HEAD)"
{ printf '#!/usr/bin/env bash\nmigrate_wloc_retire(){ :; }\n_pdg_save_svcstate(){ :; }\n'; stub_tail; } > "$G/deploy/bot/pdg.sh"; echo retire-a > "$G/deploy/bot/a.py"
e2e_git "$G" add -A && e2e_git "$G" commit -qm retire; RT="$(git -C "$G" rev-parse HEAD)"
git clone -q --bare "$G" "$T/origin.git"
e2e_git "$T/origin.git" tag "$BRT" "$BR"; e2e_git "$T/origin.git" tag "$RTT" "$RT"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
e2e_git "$T/repo" checkout -q --detach "$BR"
git clone -q "$T/origin.git" "$T/repo-nr" 2>/dev/null                 # 取件源不是仓库的那一格专用
e2e_git "$T/repo-nr" checkout -q --detach "$BR"; mkdir -p "$T/notrepo"; e2e_git "$T/repo-nr" remote set-url origin "$T/notrepo"
mkdir -p "$T/brsrc" "$T/mod" "$T/etc" "$T/evid"; git -C "$G" archive "$BR" | tar -x -C "$T/brsrc"
cp "$T/brsrc/deploy/bot/a.py" "$T/mod/a.py"; echo ios > "$T/etc/platform"; echo 'TOKEN=x' > "$T/etc/bot.env"
git -C "$G" show "$BR:deploy/bot/pdg.sh" > "$T/cli-bridge"; git -C "$G" show "$RT:deploy/bot/pdg.sh" > "$T/cli-retire"
printf '%s\n' "……" "未执行(前像/前置不成立而跳过)的场景数: 0" "────────────────────────────────────────" "通过 68, 失败 0" > "$T/r2-ok.log"
L="$T/live"; mkdir -p "$L/ca" "$L/ca-nokey" "$L/backups/20260901-000000-old"
printf '{"schema": 1, "current": {"revision": 1, "inputs": {"wloc_enabled": true}}}\n' > "$L/ios-profile.json"; printf '{"wloc": {"enabled": true}}\n' > "$L/mitm.json"
mkdir -p "$L/art"; : > "$L/art/current.mobileconfig"; printf 'domain:gs-loc.apple.com\n' > "$L/hij.txt"; printf 'proxies:\n  - name: MITM-OUT\n' > "$L/mc.yaml"
# systemctl 替身的应答表: 每行「键|退出码|stdout(可含 \n)|stderr」, 键 = "<子命令> <unit>" 或 "show:<属性> <unit>";
# 查找顺序: 键#第N次 → 键 → "show:<属性> *"#第N次 → "show:<属性> *"(stdout 里 %u 换成 unit)。健康表 = 各服务持续运行 + 调用后自启 / 运行态
printf '%s\n' 'show:Id *|0|%u.service\n|' 'show:LoadState *|0|loaded\n|' 'show:Type *|0|simple\n|' 'show:NRestarts *|0|0\n|' \
  'show:ActiveState *|0|active\n|' 'show:SubState *|0|running\n|' 'show:MainPID *|0|4242\n|' 'show:InvocationID *|0|0123456789abcdef0123456789abcdef\n|' \
  'is-enabled pdg-mitm|0|enabled\n|' 'is-active pdg-mitm|3|inactive\n|' \
  'is-enabled mosdns|0|enabled\n|' 'is-enabled mihomo|0|enabled\n|' 'is-enabled pdg-probe81|0|enabled\n|' \
  'is-active pdg-dotwitness|0|active\n|' 'is-active pdg-health.timer|0|active\n|' > "$T/sc-ok.tab"
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == show ]]; then k="show:$3 ${5:-}"; else k="$1 ${2:-}"; fi
echo "systemctl $*" >> "$FK"
cf="$FKDIR/n-${k//[^A-Za-z0-9._-]/_}"; n=0; [[ -f "$cf" ]] && n="$(<"$cf")"; n=$((n+1)); echo "$n" > "$cf"
u="${k#* }"; p="${k%% *}"
for want in "$k#$n" "$k" "$p *#$n" "$p *"; do
  while IFS='|' read -r l rc out err; do
    [[ "$l" == "$want" ]] || continue
    echo "served $want -> rc=$rc" >> "$FK"
    # FAKE_REC_RO=1: 应答非零查询之前把本 unit 本次调用的记账文件设只读(初始化早已成功、文件仍可读), 只让随后那次追加失败;
    # 同一身份立即试探一次追加并记下结果(以 root 跑时只读挡不住, 试探会报 still-writable, 格判注入未命中)
    if [[ -n "${FAKE_REC_RO:-}" && "$rc" != 0 ]]; then
      for f in "${FAKE_REC_DIR:?}"/stableq-"$u"-*.rec; do
        [[ -f "$f" ]] || continue
        chmod a-w -- "$f" && echo "served rec-readonly $f" >> "$FK"
        if ( : >> "$f" ) 2>/dev/null; then echo "served rec-append-probe still-writable" >> "$FK"; else echo "served rec-append-probe denied" >> "$FK"; fi
      done
    fi
    out="${out//%u/$u}"; printf '%b' "$out"; [[ -z "$err" ]] || printf '%s\n' "$err" >&2; exit "$rc"
  done < "$SCFIX"
done
echo "替身表里没有 [$k]" >&2; exit 99
EOS
cat > "$T/bin/journalctl" <<'EOS'
#!/usr/bin/env bash
# 模拟 journal: $JFILE 每行「标签<TAB>消息」, 游标 = c-<行号>; 只认持续运行判据与界桩用到的形态
echo "journalctl $*" >> "$FK"
if [[ -n "${FAKE_JC_FAIL:-}" && "$*" == *"$FAKE_JC_FAIL"* ]]; then echo "served journalctl-fail" >> "$FK"; echo "journalctl: 模拟失败" >&2; exit 1; fi
touch "$JFILE"
case "$1" in
  --sync) exit 0;;
  -t) if [[ "${3:-}" == --after-cursor ]]; then awk -F'\t' -v t="$2" -v c="${4#c-}" 'NR>c+0 && $1==t {print $2}' "$JFILE"
      else awk -F'\t' -v t="$2" '$1==t {printf "{\"MESSAGE\": \"%s\", \"__CURSOR\": \"c-%d\"}\n", $2, NR}' "$JFILE"; fi;;
  -u) awk -F'\t' -v u="$2" -v c="${4#c-}" 'NR>c+0 && $1=="systemd" && index($2, "Started " u ".service") == 1 {print "2026-09-27T00:00:00+0000 host systemd[1]: " $2}' "$JFILE";;
  *) echo "替身不认识的 journalctl 形态: $*" >&2; exit 98;;
esac
EOS
cat > "$T/bin/logger" <<'EOS'
#!/usr/bin/env bash
# logger -t 标签 消息 → 追加一条; FAKE_LOGGER_FAIL 命中消息时退出 1; FAKE_START_IN=<unit> 时在该 unit 的止界桩前先写一条 Started
echo "logger $*" >> "$FK"
[[ "$1" == -t && $# -eq 3 ]] || { echo "替身不认识的 logger 形态: $*" >&2; exit 98; }
if [[ -n "${FAKE_LOGGER_FAIL:-}" && "$3" == *"$FAKE_LOGGER_FAIL"* ]]; then echo "served logger-fail" >> "$FK"; exit 1; fi
if [[ -n "${FAKE_START_IN:-}" && "$3" == *"stable-$FAKE_START_IN-end"* ]]; then
  printf 'systemd\tStarted %s.service - 模拟\n' "$FAKE_START_IN" >> "$JFILE"; echo "served start-in-window $FAKE_START_IN" >> "$FK"
fi
printf '%s\t%s\n' "$2" "$3" >> "$JFILE"
EOS
chmod +x "$T/bin/systemctl" "$T/bin/journalctl" "$T/bin/logger"
# 观测钩子(只在六节的格里经 BASH_ENV 载入): 只对 ③ 的记账包装生效, 把它自己的 stderr 另记一份 —— 共享窗口把查询 stderr
# 丢进 /dev/null, 否则看不到包装里追加失败的报错。不改变任何输出或退出码。
printf '%s\n' 'case "$0" in */stableq-*/systemctl|*/stableq-*/journalctl) exec 2>>"${R3Q_OBS:?}";; esac' > "$T/obs-bashenv.sh"
mktab(){ local f="$T/sc-$1.tab"; shift; printf '%s\n' "$@" > "$f"; cat "$T/sc-ok.tab" >> "$f"; }   # 覆盖行在前, 其余照健康表
echo crt > "$L/ca/ca.crt"; echo key > "$L/ca/ca.key"; chmod 600 "$L/ca/ca.key"; echo crt > "$L/ca-nokey/ca.crt"; : > "$L/snapfile"
row(){ local u="$1"; shift; printf '%s\t%s.service\tservice\tsimple\t%s\t%s\t%s\t%s\t%s\t%s\t0\tprobe\t%s\n' "$u" "$u" "$@"; }   # u load act sub ufs pid inv valid
{ row pdg-mitm loaded active running enabled 100 inv-a ok; row mosdns loaded active running enabled 200 inv-b ok
  row sing-box not-found inactive dead "" 0 - ok; } > "$T/svc-before.tsv"
cp "$T/svc-before.tsv" "$T/svc-fix-ok.tsv"
head -2 "$T/svc-before.tsv" > "$T/svc-fix-missing.tsv"
{ row pdg-mitm loaded active running enabled 100 inv-a ok; row mosdns loaded active running enabled 200 inv-b "bad:ActiveState 查询失败"
  row sing-box not-found inactive dead "" 0 - ok; } > "$T/svc-fix-badrow.tsv"
if [[ "$BR" =~ ^[0-9a-f]{40}$ && "$RT" =~ ^[0-9a-f]{40}$ && "$BR" != "$RT" ]] \
   && [[ "$(git -C "$T/origin.git" rev-parse -q --verify "refs/tags/$RTT^{commit}")" == "$RT" ]] \
   && [[ "$(git -C "$T/repo" rev-parse HEAD)" == "$BR" && "$(git -C "$T/repo-nr" remote get-url origin)" == "$T/notrepo" ]]; then
  ok "三-0b 受控现场就位(对象库两提交、裸库两 tag、现役仓库在桥接; 写操作全部经 e2e_git)"
else bad "三-0b 受控现场没就位 —— 以下各格的结论不可信"; fi

# 在子壳里跑一格: 装载被测原文 + 受控变量; $1=格名 $2=要执行的代码
# 格里赋值的 R3_* / *_SHA / *_TAG 等都由 source 进来的被测原文按名字读取(ShellCheck 看不到这种使用)
# shellcheck disable=SC2034
cell(){ ( set +u
  EVID="$T/evid"; R3_COUNT="$T/count-$1"; printf '0\n' > "$R3_COUNT"; STUB_CALLS="$T/calls-$1"; : > "$STUB_CALLS"; export STUB_CALLS
  R3_REPO="$T/repo"; R3_CLI="$T/cli-$1"; cp "$T/cli-bridge" "$R3_CLI"; R3_OBJ="$G"; R3_BRSRC="$T/brsrc"; R3_MODDIR="$T/mod"; R3_ETC="$T/etc"
  BRIDGE_SHA="$BR"; RETIRE_SHA="$RT"; BRIDGE_TAG="$BRT"; RETIRE_TAG="$RTT"; R3_REAL2_LOG="$T/r2-ok.log"; R3_LOG="$T/log-$1"; R3_TIMEOUT=30
  R3_RCFILE="$T/rc-$1"; R3_TOERR="$T/toerr-$1"; R3_TMP="$T/r3tmp-$1"; mkdir -p "$R3_TMP"
  IOS_META="$L/ios-profile.json"; MJ="$L/mitm.json"; CA_DIR="$L/ca"; SNAPROOT="$L/backups"
  KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform"); KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")
  SVC_WATCH=(pdg-mitm mosdns sing-box); SVC_FIX="$T/svc-fix-ok.tsv"; HIT="$T/hit-$1"
  IOS_ART="$L/art"; HIJ="$L/hij.txt"; MC="$L/mc.yaml"; E2E_SIP=203.0.113.1; R3_MITM_UNIT="$T/无此目录/pdg-mitm.service"
  E2E_TMP="$R3_TMP"; JBOUND_TAG=pdg-e2e-jbound-r3
  export PATH="$T/bin:$PATH" FK="$T/fk-$1" FKDIR="$T/fkd-$1" SCFIX="$T/sc-ok.tab" JFILE="$T/j-$1"; mkdir -p "$FKDIR"; : > "$JFILE"
  ok(){ echo "VOK $1"; }; bad(){ echo "VBAD $1"; }; note(){ echo "VNOTE $1"; }; _evn(){ printf '%s\n' "$2" >> "$EVID/$1"; }
  source "$T/pffns.sh"; source "$T/hop2fns.sh"; source "$T/r3fns.sh"
  # 显式登记的替身: systemctl / journalctl / logger 在 $T/bin(见上); 下面是格内函数形式的外部命令替身与本格无关依赖。
  # 运行态门、持续运行判据(共享窗口全链)、调用后检查都不替换。
  sleep(){ echo "sleep $*" >> "$FK"; }
  curl(){ echo "curl $*" >> "$FK"; printf '%s' "${FAKE_CURL_OUT-200}"; return "${FAKE_CURL_RC:-0}"; }
  dig(){ echo "dig $*" >> "$FK"; printf '%b' "${FAKE_DIG_OUT-203.0.113.1\n}"; return "${FAKE_DIG_RC:-0}"; }
  ss(){ echo "ss $*" >> "$FK"; printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    [[ -z "${FAKE_SS_PORT-7894}" ]] || printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n' "${FAKE_SS_PORT-7894}"; }
  bridge_svc_sample(){ cp "$SVC_FIX" "$1"; }
  eval "$2" ) > "$T/out-$1" 2>&1; }
cnt(){ cat "$T/count-$1" 2>/dev/null; }
calls(){ grep -c . "$T/calls-$1" 2>/dev/null; }
hit(){ [[ -s "$T/hit-$1" ]]; }
fk(){ awk -v p="$2" 'index($0, "served ") != 1 && index($0, p) {c++} END {print c+0}' "$T/fk-$1" 2>/dev/null || echo 0; }   # 外部命令替身被调次数(按片段; 不数 served 应答行)
served(){ local n; n="$(grep -c -- "served $2" "$T/fk-$1" 2>/dev/null)"; echo "${n:-0}"; }   # 替身按表 / 注入应答的次数(注入命中的证据)

cell g-ok 'r3_gated_invoke; echo "GRC=$? W=$R3_WRAP_RC"'
{ grep -qx 'GRC=0 W=0' "$T/out-g-ok" && [[ "$(cnt g-ok)" == 1 && "$(calls g-ok)" == 1 ]] && grep -qx "update --to $RTT" "$T/calls-g-ok" \
  && [[ "$(grep -cE '^  B[0-9]' "$T/out-g-ok")" == 9 && "$(grep -cE '^  E ' "$T/out-g-ok")" == 10 ]] \
  && [[ "$(grep -c '^VOK ③-0 前像' "$T/out-g-ok")" == 11 ]] && ! grep -q '^VBAD' "$T/out-g-ok" \
  && (( $(fk g-ok curl) == 1 && $(fk g-ok dig) == 1 && $(fk g-ok 'systemctl is-enabled pdg-mitm') == 1 )) \
  && [[ "$(cat "$T/rc-g-ok")" == 0 && ! -s "$T/toerr-g-ok" ]] \
  && ! grep -qE '不是|≠|不干净|没有前像|已含退役|观测无效|没取得|就不存在|写不出来|没建成|不全|无效行|调用前停止' "$T/out-g-ok"; } \
  && ok "三-1 健康: 门全过(运行态门判断原文真跑, 11 条前像成立)、调用前观测 10 项取全, 调用恰 1 次(桩独立记录 1 次), 桩收到 update --to $RTT; 包装器返回码 0、产品退出码 0 分别取得" \
  || bad "三-1 健康格: $(tr '\n' ' ' < "$T/out-g-ok" | head -c 400) 计数=$(cnt g-ok) 桩=$(calls g-ok)"
gcase(){   # $1=格名 $2=期望 GRC $3=说明 $4=注入代码 $5=输出里必须出现的原因片段 $6=注入命中核对(父壳里 eval) $7=计数文件应有内容(默认 0)
  cell "$1" "$4"$'\n''r3_gated_invoke; echo "GRC=$?"'
  local h=是 c k; eval "$6" || h=否
  c="$(calls "$1")"; k="$(cnt "$1")"
  if grep -qx "GRC=$2" "$T/out-$1" && [[ "$c" == 0 && "$k" == "${7:-0}" && "$h" == 是 ]] && grep -qF -- "$5" "$T/out-$1"; then
    ok "$3 ⇒ GRC=$2; 注入命中; 桩 CLI 独立记录 0 次, 计数文件 [$k]; 原因含「$5」"
  else bad "$3: 实得 $(grep -o 'GRC=[0-9]*' "$T/out-$1") 注入命中=$h 桩记录=[$c] 计数=[$k] —— $(tr '\n' ' ' < "$T/out-$1" | head -c 260)"; fi
}
# ── ② 结果门 ──
gcase g-r2-missing 10 "三-2 ② 输出留档不存在"            'R3_REAL2_LOG="$T/没有这个文件"' "读不了" '[[ ! -e "$T/没有这个文件" ]]'
printf '%s\n' "未执行(前像/前置不成立而跳过)的场景数: 0" "通过 67, 失败 1" > "$T/r2-fail.log"
gcase g-r2-fail    10 "三-3 ② 汇总失败 1"                'R3_REAL2_LOG="$T/r2-fail.log"' "汇总失败 1" 'grep -qx "通过 67, 失败 1" "$T/r2-fail.log"'
printf '%s\n' "未执行(前像/前置不成立而跳过)的场景数: 1" "通过 20, 失败 0" > "$T/r2-notrun.log"
gcase g-r2-notrun  10 "三-4 ② 有未执行场景(退出码 0 也不算 ② 成立)" 'R3_REAL2_LOG="$T/r2-notrun.log"' "有未执行场景" 'grep -q "场景数: 1" "$T/r2-notrun.log"'
printf '%s\n' "未执行(前像/前置不成立而跳过)的场景数: 0" "通过 68, 失败 0" "[OK]   半截之后还有输出" > "$T/r2-trunc.log"
gcase g-r2-trunc   10 "三-5 ② 汇总不是最后一行(输出不完整)" 'R3_REAL2_LOG="$T/r2-trunc.log"' "不是最后一行" 'tail -1 "$T/r2-trunc.log" | grep -q 半截'
printf '%s\n' "通过 68, 失败 0" > "$T/r2-noline.log"
gcase g-r2-noline  10 "三-6 ② 没有'未执行场景数'行(没跑到收尾)" 'R3_REAL2_LOG="$T/r2-noline.log"' "应恰 1 行" '! grep -q 未执行 "$T/r2-noline.log"'
gcase g-r2-grepq   10 "三-6b ② 结果查询自身出错(grep 退出 2)不当成答案" \
  'grep(){ if [[ "$*" == *未执行* ]]; then echo hit >> "$HIT"; return 2; fi; command grep "$@"; }' "查询失败" 'hit g-r2-grepq'
# ── 桥接身份门 ──
gcase g-head       11 "三-7 现役 HEAD 不是桥接(已是退役)"   'e2e_git "$R3_REPO" checkout -q --detach "$RT"' ", 不是桥接" '[[ "$(git -C "$T/repo" rev-parse HEAD)" == "$RT" ]]'
e2e_git "$T/repo" checkout -q --detach "$BR"
gcase g-cli        11 "三-8 现役 CLI 与桥接 pdg.sh 不一致"   'echo "# 改过" >> "$R3_CLI"' "≠ 桥接 pdg.sh" 'grep -q "改过" "$T/cli-g-cli"'
gcase g-repo-gone  11 "三-9 现役仓库读不了(观测无效也不调用; 原因不丢)" 'R3_REPO="$T/没有这个仓库"' "B1 观测无效: 读不出 $T/没有这个仓库 的 HEAD" '[[ ! -e "$T/没有这个仓库" ]]'
gcase g-plat       11 "三-10 平台标记不是 ios"              'echo android > "$R3_ETC/platform"' "[android], 不是 ios" 'grep -qx android "$T/etc/platform"'
echo ios > "$T/etc/platform"
gcase g-b3-grep    11 "三-10b CLI 能力查询自身出错(grep 退出 2)⇒ 观测无效, 不说成'不是桥接版'" \
  'grep(){ if [[ "$*" == *_pdg_save_svcstate* ]]; then echo hit >> "$HIT"; return 2; fi; command grep "$@"; }' "B3 观测无效" 'hit g-b3-grep'
gcase g-origin     11 "三-11 取件源里退役 tag 指错对象"       'e2e_git "$T/origin.git" tag -f "$RTT" "$BR" >/dev/null 2>&1' ", 不是退役" \
  '[[ "$(git -C "$T/origin.git" rev-parse -q --verify "refs/tags/$RTT^{commit}")" == "$BR" ]]'
e2e_git "$T/origin.git" tag -f "$RTT" "$RT" >/dev/null 2>&1
gcase g-tag-absent 11 "三-11b 取件源里没有退役 tag(查询成功, 答案是不存在)" 'e2e_git "$T/origin.git" tag -d "$RTT" >/dev/null 2>&1' "里没有 $RTT(查询成功, 答案是不存在)" \
  '! git -C "$T/origin.git" rev-parse -q --verify "refs/tags/$RTT" >/dev/null'
e2e_git "$T/origin.git" tag "$RTT" "$RT"
gcase g-tag-nr     11 "三-11c 取件源不是仓库(tag 查询本身失败)⇒ 观测无效, 不说成'指错'" 'R3_REPO="$T/repo-nr"' "B8 观测无效" \
  '! git -C "$T/notrepo" rev-parse --git-dir >/dev/null 2>&1'
gcase g-runtime    12 "三-12 运行态 / WLOC 前像门不过(门原文真跑; :81 的 curl 退出 7)" 'FAKE_CURL_OUT=000; FAKE_CURL_RC=7' "前像观测无效(:81): 命令失败: curl 退出 7" '(( $(fk g-runtime curl) >= 1 ))'
# ── 调用前观测(13): 任一没取到就不调用 ──
# 运行态门判断原文真跑后, "iOS 记录不在"会先被运行态门的 schema 核对挡下(GRC=12); 这里要验的是调用前**复制**失败, 所以替身只让复制失败
gcase p-ios        13 "三-12a 调用前 iOS 记录复制失败"        'cp(){ if [[ "$*" == *ios-before* ]]; then echo hit >> "$HIT"; return 1; fi; command cp "$@"; }' "复制失败" 'hit p-ios'
gcase p-cmp        13 "三-12b 调用前记录副本与原件不一致"     'cmp(){ if [[ "$*" == *ios-before* ]]; then echo hit >> "$HIT"; return 1; fi; command cmp "$@"; }' "副本与原件不一致" 'hit p-cmp'
gcase p-keep-sha   13 "三-12c 必需保留项摘要取不到"           'sha256sum(){ if [[ "$*" == *ca.key* ]]; then echo hit >> "$HIT"; return 1; fi; command sha256sum "$@"; }' "保留项摘要没取得" 'hit p-keep-sha'
gcase p-keep-stat  13 "三-12d 必需保留项元数据取不到"         'stat(){ if [[ "$*" == *ca.crt* ]]; then echo hit >> "$HIT"; return 1; fi; command stat "$@"; }' "保留项元数据没取得" 'hit p-keep-stat'
gcase p-keep-miss  13 "三-12e 必需保留项进场就缺(不许静默移出比较集合)" 'CA_DIR="$L/ca-nokey"; KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform")' "调用前就不存在" '[[ ! -e "$L/ca-nokey/ca.key" ]]'
gcase p-snap-file  13 "三-12f 快照根在但不是目录"             'SNAPROOT="$L/snapfile"' "不是目录" '[[ -f "$L/snapfile" ]]'
gcase p-snap-ls    13 "三-12g 快照目录列不出(ls 退出 2)"      'ls(){ echo hit >> "$HIT"; return 2; }' "列不出" 'hit p-snap-ls'
gcase p-sample     13 "三-12h 调用前服务采样写不出来"         'bridge_svc_sample(){ echo hit >> "$HIT"; return 1; }' "写不出来" 'hit p-sample'
gcase p-set        13 "三-12i 调用前服务采样缺 unit"          'SVC_FIX="$T/svc-fix-missing.tsv"' "缺服务 [sing-box]" '[[ "$(wc -l < "$T/svc-fix-missing.tsv")" == 2 ]]'
gcase p-row        13 "三-12j 调用前服务采样有无效行"         'SVC_FIX="$T/svc-fix-badrow.tsv"' "有无效行" 'grep -q "bad:ActiveState" "$T/svc-fix-badrow.tsv"'
gcase p-jmark      13 "三-12k journal 起界桩没建成(logger 只在写 retire-start 界桩时失败)" 'export FAKE_LOGGER_FAIL=retire-start' "起界桩没建成(写不进 journal 界桩(logger 失败))" '(( $(served p-jmark "logger-fail") == 1 ))'
# ── 调用计数 / 退出码留档(14): 读取或写入失败即具名停止, 不用 0 兜底 ──
# 注入命中与结果分开核: 命中看注入代码自己留的记号; 计数文件内容(第 7 参数)是结果, 另行核
gcase c-garbage    14 "三-12l 调用计数内容不是数(不拿 0 兜底)" 'printf "xyz\n" > "$R3_COUNT" && grep -qx xyz "$R3_COUNT" && echo hit >> "$HIT"' "不是非负整数" 'hit c-garbage' xyz
gcase c-unread     14 "三-12m 调用计数读不了"                  'R3_COUNT="$T/countdir"; mkdir -p "$R3_COUNT"' "调用计数读不了" '[[ -d "$T/countdir" ]]'
# noclobber 只从 r3_invoke 起生效: 共享持续运行全链会反复重写它自己的 j-err.txt, 早开会让运行态门先失败
gcase c-write      14 "三-12n 调用计数写不进(noclobber 拒绝覆写)" 'eval "$(declare -f r3_invoke | sed "1s/^r3_invoke/r3__orig_invoke/")"; r3_invoke(){ set -C; [[ -o noclobber ]] && echo hit >> "$HIT"; r3__orig_invoke "$@"; }' "调用计数写不进" 'hit c-write'
gcase c-rcprep     14 "三-12o 退出码留档准备不了"              'R3_RCFILE="$T/无此目录/rc"' "退出码留档准备不了" '[[ ! -e "$T/无此目录" ]]'
cell c-init 'R3_COUNT="$T/无此目录/count"; r3_count_init; echo "CI=$?"'
grep -qx 'CI=2' "$T/out-c-init" && [[ ! -e "$T/无此目录" ]] \
  && ok "三-12p 调用计数初始化写不进 ⇒ r3_count_init 返回 2(主流程据此具名硬停, 见二-11)" || bad "三-12p 计数初始化失败没被发现: $(tr '\n' ' ' < "$T/out-c-init")"

# ── 观测读取器: 失败不当成答案 ──
rd(){   # $1=格名 $2=代码(末尾须 echo "R=$? V=[...]") $3=期望 R= 行 $4=说明 $5=输出里必须出现的片段(可空) $6=注入命中核对(可空)
  cell "$1" "$2"; local h=是; [[ -z "${6:-}" ]] || eval "$6" || h=否
  if grep -qxF -- "$3" "$T/out-$1" && [[ "$h" == 是 ]] && { [[ -z "${5:-}" ]] || grep -qF -- "$5" "$T/out-$1"; }; then ok "$4 ⇒ $3${5:+(含「$5」)}"
  else bad "$4: 注入命中=$h —— $(tr '\n' ' ' < "$T/out-$1" | head -c 260)"; fi
}
# shellcheck disable=SC2034  # 在格里的受控 ss 替身中使用(单引号代码串, ShellCheck 看不到)
SSHDR='State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process'
rd o-ss-fail   'ss(){ echo hit >> "$HIT"; echo "ss: 模拟失败" >&2; return 1; }; r3_listen_count 7894; echo "R=$? V=[$R3_VAL] W=$R3_WHY"' \
   "R=2 V=[] W=ss -lnt 失败(rc=1) —— 不当成零监听" "三-13 ss 查询失败 ⇒ 观测无效, 不当成零监听" "" 'hit o-ss-fail'
rd o-ss-nohdr  'ss(){ echo hit >> "$HIT"; echo "垃圾"; }; r3_listen_count 7894; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "三-14 ss 退出 0 但输出不像 ss ⇒ 观测无效" "没有表头" 'hit o-ss-nohdr'
rd o-ss-zero   'ss(){ printf "%s\n" "$SSHDR" "LISTEN 0 4096 127.0.0.1:53 0.0.0.0:*" "LISTEN 0 4096 [::]:17894 [::]:*"; }; r3_listen_count 7894; echo "R=$? V=[$R3_VAL]"' \
   "R=0 V=[0]" "三-15 健康: ss 成功且没有 :7894 ⇒ 真的零监听(:17894 不算)"
rd o-ss-one    'ss(){ printf "%s\n" "$SSHDR" "LISTEN 0 4096 0.0.0.0:7894 0.0.0.0:*" "LISTEN 0 4096 [::]:17894 [::]:*"; }; r3_listen_count 7894; echo "R=$? V=[$R3_VAL]"' \
   "R=0 V=[1]" "三-16 健康: ss 成功且有 :7894 ⇒ 1 条"
rd o-comm-fail 'comm(){ echo hit >> "$HIT"; echo 伪造的一行; return 2; }; r3_snapdiff "a" "$(printf "a\nb")"; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' \
   "R=2 V=[]" "三-17 comm 失败 ⇒ 它的输出不消费" "comm 失败" 'hit o-comm-fail'
rd o-comm-sort 'r3_snapdiff "$(printf "b\na")" "$(printf "b\na\nc")"; echo "R=$? V=[$R3_VAL]"' \
   "R=2 V=[]" "三-18 前清单未排序(真 comm --check-order 报错)⇒ 观测无效"
rd o-comm-ok   'r3_snapdiff "$(printf "a\nc")" "$(printf "a\nb\nc")"; echo "R=$? V=[$R3_VAL]"' "R=0 V=[b]" "三-19 健康: 快照差集取到新增 1 项"
rd o-tag       'r3_tagsha "$T/origin.git" "$RTT"; a=$?; r3_tagsha "$T/origin.git" v0-nope; b=$?; r3_tagsha "$T/notrepo" "$RTT"; echo "R=$a/$b/$? V=[$R3_VAL]"' \
   "R=0/1/2 V=[]" "三-20 tag 查询三态: 存在 0 / 不存在 1(答案) / 查询失败 2(观测无效)"
# 保留项: 调用前取得、调用后逐项比; 读失败不当成原样
KP='cp -a "$L/ca" "$R3_TMP/ca"; CA_DIR="$R3_TMP/ca"; KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform"); '
rd k-ok        "$KP"'r3_keep_capture >/dev/null; r3_keep_verdict; echo "R=$? V=[]"' "R=0 V=[]" "三-21 健康: 保留项调用前后原样, 可选项调用前不在的显式登记" "调用前后都不在"
rd k-2fail     "$KP"'sha256sum(){ if [[ "$*" == *ca.key* ]]; then echo hit >> "$HIT"; return 1; fi; command sha256sum "$@"; }; r3_keep_capture; c=$?; r3_keep_verdict; echo "R=$c/$? V=[]"' \
   "R=1/2 V=[]" "三-22 同一保留项调用前后两次都读失败 ⇒ 调用前就阻断, 调用后判观测无效(不判原样)" "没有调用前指纹记录" 'hit k-2fail'
rd k-after     "$KP"'r3_keep_capture >/dev/null; sha256sum(){ if [[ "$*" == *ca.key* ]]; then echo hit >> "$HIT"; return 1; fi; command sha256sum "$@"; }; r3_keep_verdict; echo "R=$? V=[]"' \
   "R=2 V=[]" "三-23 调用后摘要读失败 ⇒ 观测无效(不判原样)" "不当成原样" 'hit k-after'
rd k-stat      "$KP"'r3_keep_capture >/dev/null; stat(){ if [[ "$*" == *ca.crt* ]]; then echo hit >> "$HIT"; echo "0 0:0"; return 1; fi; command stat "$@"; }; r3_keep_verdict; echo "R=$? V=[]"' \
   "R=2 V=[]" "三-24 调用后元数据查询失败(即使吐了像样的输出)⇒ 观测无效" "保留项元数据没取得" 'hit k-stat'
rd k-changed   "$KP"'r3_keep_capture >/dev/null; echo changed >> "$CA_DIR/ca.crt"; r3_keep_verdict; echo "R=$? V=[]"' "R=1 V=[]" "三-25 保留项内容被改" "保留项被改: $T/r3tmp-k-changed/ca/ca.crt"
rd k-mode      "$KP"'r3_keep_capture >/dev/null; chmod 644 "$CA_DIR/ca.key"; r3_keep_verdict; echo "R=$? V=[]"' "R=1 V=[]" "三-26 保留项 mode 被改(内容不变)" "保留项被改: $T/r3tmp-k-mode/ca/ca.key"
rd k-gone      "$KP"'r3_keep_capture >/dev/null; rm -f "$CA_DIR/ca.key"; r3_keep_verdict; echo "R=$? V=[]"' "R=1 V=[]" "三-27 保留项被删" "保留项被删"
rd k-appear    "$KP"'r3_keep_capture >/dev/null; echo d > "$R3_MODDIR/dot-domain"; r3_keep_verdict; r=$?; rm -f "$R3_MODDIR/dot-domain"; echo "R=$r V=[]"' \
   "R=0 V=[]" "三-28 可选项调用前不在、调用后出现 ⇒ 只登记, 不作原样判定(309 plan K2)" "调用后出现"

# ── 目标到达 / 进程状态 / 观测有效性 分别结算; 退出码按来源命名 ─────────────────
printf '%s\n' "钉版目标已贯穿到实际安装: $RTT → $RT" "→ 已切到发布 $RTT($RT)" "  ✅ WLOC 位置改写及其专属 MITM 执行能力已退役" "✅ 已更新。" > "$T/upd-ok.log"
arr(){   # $1=格名 $2=期望(PASS/FAIL) $3=期望 P/A/O $4=说明 $5=额外代码 $6=输出须含(可空) $7=输出不许含(可空)
  cell "$1" 'e2e_git "$R3_REPO" checkout -q --detach "$RT"; cp "$T/cli-retire" "$R3_CLI"; R3_LOG="$T/upd-ok.log"; printf "0\n" > "$R3_RCFILE"; : > "$R3_TOERR"; R3_WRAP_RC=0; '"$5"'; r3_arrival_verdict; echo "V=$? P=$R3_PROC A=$R3_ARRIVE O=$R3_OBS"'
  local got v=FAIL why=""; got="$(grep -oE 'V=[0-9]+ P=[A-Z]+ A=[A-Z]+ O=[A-Z]+' "$T/out-$1")"
  [[ "$got" == V=0* ]] && v=PASS
  [[ -z "${6:-}" ]] || grep -qF -- "$6" "$T/out-$1" || why="缺「$6」"
  [[ -z "${7:-}" ]] || ! grep -qF -- "$7" "$T/out-$1" || why="${why:+$why; }不该出现「$7」"
  if [[ "$v" == "$2" && "${got#* }" == "$3" && -z "$why" ]]; then ok "$4 ⇒ $v($3)${6:+; 含「$6」}${7:+; 无「$7」}"
  else bad "$4: 实得 [$got] $why, 期望 $2 / $3 —— $(grep -E '^  P[01]' "$T/out-$1" | tr '\n' ' ' | head -c 200)"; fi
  e2e_git "$T/repo" checkout -q --detach "$BR"
}
arr a-ok       PASS "P=OK A=OK O=VALID"      "三-29 健康: 产品退出 0 + HEAD = 退役 + CLI = 退役 + 日志正向证据齐"   ':' "产品原始退出码 0(内层单独写出)"
arr a-rc       FAIL "P=FAIL A=OK O=VALID"    "三-30 产品退出 1 但日志说「✅ 已更新」"                               'printf "1\n" > "$R3_RCFILE"' "产品原始退出码 1"
E2E='STUB_OUT="$(cat "$T/upd-ok.log")"; export STUB_OUT; R3_LOG="$T/log-$1"; '
arr a-e2e-ok   PASS "P=OK A=OK O=VALID"      "三-31 健康(经真实 r3_invoke 与 timeout 包装): 桩退出 0"                "$E2E"'export STUB_RC=0; r3_invoke' "包装器(timeout)返回码 0"
[[ "$(calls a-e2e-ok)" == 1 ]] && ok "三-31b 上一格桩 CLI 独立记录恰 1 次" || bad "三-31b 上一格桩 CLI 记录 $(calls a-e2e-ok) 次"
arr a-e2e-124  FAIL "P=FAIL A=OK O=VALID"    "三-32 产品**自己**以 124 退出(没有超时)⇒ 按产品退出码失败, 不冒称超时" "$E2E"'export STUB_RC=124; r3_invoke' "产品原始退出码 124" "超时"
arr a-e2e-to   FAIL "P=FAIL A=OK O=VALID"    "三-33 真超时(桩睡 5 s, 额度 1 s)⇒ 以 timeout 自己的发信号记录认定, 产品退出码不冒称" \
   "$E2E"'export STUB_SLEEP=5; R3_TIMEOUT=1; r3_invoke; echo "W=$R3_WRAP_RC"' "超时终止有直接记录"
grep -qx 'W=124' "$T/out-a-e2e-to" && grep -qF '产品原始退出码未取得' "$T/out-a-e2e-to" \
  && ok "三-33b 上一格: 包装器返回码 124 与发信号记录都在, 产品原始退出码记为未取得" || bad "三-33b 上一格的包装器返回码 / 产品退出码命名不对"
arr a-w124     FAIL "P=FAIL A=OK O=INVALID"  "三-34 只有包装器返回码 124、没有发信号记录 ⇒ 称包装器返回码, 不认定超时" \
   'R3_WRAP_RC=124; : > "$R3_RCFILE"' "包装器(timeout)返回码 124 非零 —— 没有 timeout 的发信号记录, 不据此认定超时" "超时终止有直接记录"
arr a-norc     FAIL "P=UNKNOWN A=OK O=INVALID" "三-35 产品退出码文件不在 ⇒ 进程状态不明, 不拿包装器返回码冒充" 'rm -f "$R3_RCFILE"' "不拿包装器返回码冒充"
arr a-rcjunk   FAIL "P=UNKNOWN A=OK O=INVALID" "三-36 产品退出码文件内容不是退出码"        'printf "abc\n" > "$R3_RCFILE"' "不是退出码"
arr a-nowrap   FAIL "P=OK A=OK O=INVALID"    "三-37 没取到包装器返回码"                                  'R3_WRAP_RC=""' "没取到包装器(timeout)返回码"
arr a-toerr    FAIL "P=OK A=OK O=INVALID"    "三-38 timeout 的 stderr 留档读不了"                        'rm -f "$R3_TOERR"' "stderr 留档读不了"
arr a-head     FAIL "P=OK A=FAIL O=VALID"    "三-39 HEAD 停在桥接(目标没到达), CLI 与日志都像成功"     'e2e_git "$R3_REPO" checkout -q --detach "$BR"'
arr a-nolog    FAIL "P=OK A=UNKNOWN O=INVALID" "三-40 升级日志读不了 ⇒ A2 / A5 未取得(不当成没到达)"  'R3_LOG="$T/没有日志"' "A2 / A5 未取得"
arr a-repo     FAIL "P=OK A=UNKNOWN O=INVALID" "三-41 现役仓库 HEAD 读不了"                             'R3_REPO="$T/没有这个仓库"' "A1 观测无效: 读不出"
arr a-halfsha  FAIL "P=OK A=UNKNOWN O=INVALID" "三-42 摘要只读到半截"                                   'sha256sum(){ echo "3f1a2b  $1"; }' "A3 观测无效"

# ── 服务对账: 退役链分类 + pdg-mitm 必需动作 + 窗口内启动事件 ─────────────────────────
mkafter(){ { row pdg-mitm "$1" "$2" dead "" 0 - ok; row mosdns loaded "$3" running enabled 300 inv-c "$4"; row sing-box "$5" "$6" dead "" 0 - ok; } > "$T/svc-after.tsv"; }
printf 'pdg-mitm\t0\t-\nmosdns\t1\t-\nsing-box\t0\t-\n' > "$T/win-ok.tsv"
svc(){   # $1=格名 $2=期望(PASS/FAIL) $3=说明 $4..$9=mkafter 参数 $10=窗口文件 $11=失败时 VBAD 必须含 / 通过时 VOK 必须含的片段
  mkafter "$4" "$5" "$6" "$7" "$8" "$9"
  cell "$1" 'SVC_WATCH=(pdg-mitm mosdns sing-box); r3_svc_verdict "$T/svc-before.tsv" "$T/svc-after.tsv" retire "'"${10}"'"; echo "SV=$?"'
  local v=FAIL why=""; grep -qx 'SV=0' "$T/out-$1" && grep -q '^VOK ' "$T/out-$1" && v=PASS
  if [[ "$v" == FAIL ]]; then grep '^VBAD ' "$T/out-$1" | grep -qF -- "${11}" && why="原因含「${11}」" || why="原因不对"
  elif [[ -n "${11}" ]]; then grep '^VOK ' "$T/out-$1" | grep -qF -- "${11}" && why="判词含「${11}」" || why="判词不对"; fi
  if [[ "$v" == "$2" && "$why" != 原因不对 && "$why" != 判词不对 ]]; then ok "$3 ⇒ $v${why:+($why)}"
  else bad "$3: 实得 $v ${why} —— $(grep -E '^VBAD|^VOK' "$T/out-$1" | head -2 | tr '\n' ' ')"; fi
}
H='not-found inactive active ok not-found inactive'   # 健康的调用后形态: pdg-mitm 停删、mosdns 换实例、sing-box 不动
# shellcheck disable=SC2086
svc v-ok       PASS "三-43 健康: pdg-mitm 停禁删(必需)、mosdns 换实例、sing-box 不动; 判词按实际观测口径" $H "$T/win-ok.tsv" "不是完整的服务动作审计"
printf 'pdg-mitm\t1\t-\nmosdns\t2\t-\nsing-box\t0\t-\n' > "$T/win-restart.tsv"
# shellcheck disable=SC2086
svc v-restart  PASS "三-44 健康对照: 合法重启(mosdns 窗口内 2 条, pdg-mitm 退役前被 try-restart 1 条)" $H "$T/win-restart.tsv" "允许启动且出现启动事件的 2 个单列"
svc v-mitm     FAIL "三-45 pdg-mitm 退役后仍 loaded/active(必需动作缺失)"         loaded active active ok not-found inactive "$T/win-ok.tsv" "pdg-mitm"
svc v-mosdns   FAIL "三-46 mosdns 被停(清单外的反向动作)"                           not-found inactive inactive ok not-found inactive "$T/win-ok.tsv" "清单外的服务动作: mosdns"
svc v-singbox  FAIL "三-47 sing-box 被拉起(本现场不该动它)"                         not-found inactive active ok loaded active "$T/win-ok.tsv" "清单外的服务动作: sing-box"
svc v-rowbad   FAIL "三-48 mosdns 调用后采样行无效(查询失败)"                       not-found inactive active "bad:ActiveState 查询失败" not-found inactive "$T/win-ok.tsv" "观测无效: mosdns(后"
printf 'pdg-mitm\t0\t-\nmosdns\tINVALID\tjournalctl 退出码 1\nsing-box\t0\t-\n' > "$T/win-bad.tsv"
# shellcheck disable=SC2086
svc v-winbad   FAIL "三-49 窗口观测无效(journal 读不出来)"                          $H "$T/win-bad.tsv" "窗口观测无效: mosdns(journalctl 退出码 1)"
# shellcheck disable=SC2086
svc v-nowin    FAIL "三-50 窗口结果文件读不了"                                     $H "$T/没有窗口" "窗口结果读不了"
printf 'pdg-mitm\t0\t-\nmosdns\t1\t-\nsing-box\t1\t-\n' > "$T/win-sb.tsv"
# shellcheck disable=SC2086
svc v-win-sb   FAIL "三-51 sing-box 前后状态相同, 但窗口内有 1 条启动事件(不允许启动)" $H "$T/win-sb.tsv" "不允许启动的服务在窗口内有启动事件: sing-box(1 条)"
printf 'pdg-mitm\t0\t-\nmosdns\tabc\t-\nsing-box\t0\t-\n' > "$T/win-abc.tsv"
# shellcheck disable=SC2086
svc v-win-abc  FAIL "三-52 窗口值非法(abc)"                                        $H "$T/win-abc.tsv" "[mosdns] 的窗口值非法 [abc]"
printf 'pdg-mitm\t0\t-\nmosdns\t-1\t-\nsing-box\t0\t-\n' > "$T/win-neg.tsv"
# shellcheck disable=SC2086
svc v-win-neg  FAIL "三-53 窗口值为负(-1)"                                         $H "$T/win-neg.tsv" "[mosdns] 的窗口值非法 [-1]"
printf 'pdg-mitm\t0\t-\nmosdns\t1\t-\nsing-box\t0\t-\nsing-box\t3\t-\n' > "$T/win-dup.tsv"
# shellcheck disable=SC2086
svc v-win-dup  FAIL "三-54 窗口行重复(sing-box 0 与 3)"                            $H "$T/win-dup.tsv" "窗口里重复出现 [sing-box]"
printf 'pdg-mitm\t0\t-\nmosdns\t1\t-\n' > "$T/win-miss.tsv"
# shellcheck disable=SC2086
svc v-win-miss FAIL "三-55 窗口缺 sing-box 这一行"                                 $H "$T/win-miss.tsv" "缺 [sing-box] 这一行"
printf 'pdg-mitm\t0\t-\nmosdns\t1\t-\nsing-box\t0\t-\nssh\t0\t-\n' > "$T/win-extra.tsv"
# shellcheck disable=SC2086
svc v-win-xtra FAIL "三-56 窗口里有清单外的 unit"                                  $H "$T/win-extra.tsv" "清单外的 unit [ssh]"
printf 'pdg-mitm\t0\t-\nmosdns\t1\nsing-box\t0\t-\n' > "$T/win-cols.tsv"
# shellcheck disable=SC2086
svc v-win-cols FAIL "三-57 窗口行列数不对"                                         $H "$T/win-cols.tsv" "行不是 3 列"


echo; echo "══ 四. 集合检查与实际观测接线(判断原文受控驱动) ══"
pc(){   # $1=格名 $2=说明 $3=注入代码 $4=被测调用 $5=输出须含 $6=输出不许含(可空) $7=注入命中核对(可空; 父壳里 eval)
  cell "$1" "$3"$'\n'"$4"
  local h=是 why=""
  [[ -z "${7:-}" ]] || eval "$7" || h=否
  grep -qF -- "$5" "$T/out-$1" || why="缺「$5」"
  [[ -z "${6:-}" ]] || ! grep -qF -- "$6" "$T/out-$1" || why="${why:+$why; }不该出现「$6」"
  if [[ -z "$why" && "$h" == 是 ]]; then ok "$2 ⇒ 含「$5」${6:+; 无「$6」}${7:+; 注入命中}"
  else bad "$2: 注入命中=$h $why —— $(grep -E '^V(OK|BAD)' "$T/out-$1" | tr '\n' ' ' | head -c 300)"; fi
}
# ── 集合检查(③ 本地, 调用前与调用后两侧) ──
{ cat "$T/svc-before.tsv"; row mosdns loaded active running enabled 201 inv-x ok; } > "$T/svc-fix-dup.tsv"
{ cat "$T/svc-before.tsv"; row ssh loaded active running enabled 9 inv-s ok; } > "$T/svc-fix-extra.tsv"
CATX='cat(){ if [[ "$*" == *"$CATPAT"* ]]; then echo hit >> "$HIT"; command cat "$@"; return 1; fi; command cat "$@"; }; '
rd s-ok   'declare -A X=(); r3_set_check "$T/svc-before.tsv" 前 X; echo "R=$? V=[${#X[@]}]"' "R=0 V=[3]" "四-S1 健康: 名称齐全、唯一、无清单外"
rd s-miss 'declare -A X=(); r3_set_check "$T/svc-fix-missing.tsv" 前 X; echo "R=$? V=[]"; echo "WHY=$R3_WHY"' "R=1 V=[]" "四-S2 缺项" "缺服务 [sing-box]"
rd s-dup  'declare -A X=(); r3_set_check "$T/svc-fix-dup.tsv" 前 X; echo "R=$? V=[]"; echo "WHY=$R3_WHY"' "R=1 V=[]" "四-S3 重复" "重复的服务行 [mosdns]"
rd s-xtra 'declare -A X=(); r3_set_check "$T/svc-fix-extra.tsv" 前 X; echo "R=$? V=[]"; echo "WHY=$R3_WHY"' "R=1 V=[]" "四-S4 额外项" "清单外的服务 [ssh]"
rd s-read "CATPAT=svc-before; $CATX"'declare -A X=(); r3_set_check "$T/svc-before.tsv" 前 X; echo "R=$? V=[${#X[@]}]"; echo "WHY=$R3_WHY"' \
   "R=2 V=[0]" "四-S5 读取先输出完整内容后以 1 退出 ⇒ 读取失败, 已输出的不当集合" "采样文件读取失败" 'hit s-read'
rd s-gone 'declare -A X=(); r3_set_check "$T/没有采样" 前 X; echo "R=$? V=[${#X[@]}]"; echo "WHY=$R3_WHY"' "R=2 V=[0]" "四-S6 采样文件不在 ⇒ 读取失败" "采样文件读取失败"
gcase p-set-read   13 "四-S7 调用前集合读取先输出后失败 ⇒ 不调用" "CATPAT=svc-retire-before; $CATX" "服务观测无效: 调用前: 采样文件读取失败" 'hit p-set-read'
gcase p-set-dup    13 "四-S8 调用前集合有重复 ⇒ 不调用"       'SVC_FIX="$T/svc-fix-dup.tsv"' "重复的服务行 [mosdns]" '[[ "$(grep -c "^mosdns" "$T/svc-fix-dup.tsv")" == 2 ]]'
gcase p-set-xtra   13 "四-S9 调用前集合有清单外 ⇒ 不调用"     'SVC_FIX="$T/svc-fix-extra.tsv"' "清单外的服务 [ssh]" 'grep -q "^ssh" "$T/svc-fix-extra.tsv"'
# shellcheck disable=SC2086
mkafter $H; cp "$T/svc-after.tsv" "$T/svc-after-ok.tsv"; { cat "$T/svc-after-ok.tsv"; row mosdns loaded active running enabled 301 inv-y ok; } > "$T/svc-after-dup.tsv"
VERD='SVC_WATCH=(pdg-mitm mosdns sing-box); r3_svc_verdict "$T/svc-before.tsv" "$AFTER" retire "$T/win-ok.tsv"; echo "SV=$?"'
pc v-after-ok  "四-S10 健康: 调用后集合有效, 对账通过"              'AFTER="$T/svc-after-ok.tsv"' "$VERD" "VOK retire:" "VBAD"
pc v-after-dup "四-S11 调用后集合有重复 ⇒ 对账不通过"              'AFTER="$T/svc-after-dup.tsv"' "$VERD" "重复的服务行 [mosdns]; —— 集合不全" "VOK retire:"
pc v-after-rd  "四-S12 调用后集合读取先输出后失败 ⇒ 集合观测无效" "AFTER=\"\$T/svc-after-ok.tsv\"; CATPAT=svc-after-ok; $CATX" "$VERD" "集合观测无效" "VOK retire:" 'hit v-after-rd'

# ── HTTP ──
rd h-ok   'r3_http_code http://127.0.0.1:81/; echo "R=$? V=[$R3_VAL]"' "R=0 V=[200]" "四-H1 健康: curl 退出 0、状态码 200"
rd h-rc   'FAKE_CURL_RC=28; r3_http_code http://127.0.0.1:81/; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "四-H2 打印 200 但退出 28 ⇒ 命令失败, 输出不采信" "命令失败: curl 退出 28" '(( $(fk h-rc curl) == 1 ))'
rd h-junk 'FAKE_CURL_OUT=OK; r3_http_code http://127.0.0.1:81/; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "四-H3 退出 0 但输出不是状态码 ⇒ 输出无效" "输出无效"
rd h-503  'FAKE_CURL_OUT=503; r3_http_code http://127.0.0.1:81/; echo "R=$? V=[$R3_VAL]"' "R=0 V=[503]" "四-H4 查询成功、状态码 503(业务条件由调用方判)"
gcase p-http-rc    12 "四-H5 调用前 :81 打印 200 但 curl 退出 28 ⇒ 不调用" 'FAKE_CURL_RC=28' "前像观测无效(:81): 命令失败: curl 退出 28" '(( $(fk p-http-rc curl) >= 1 ))'
gcase p-http-503   12 "四-H6 调用前 :81 查询成功但 503 ⇒ 不调用(业务不满足, 与观测无效分开说)" 'FAKE_CURL_OUT=503' ":81 查询成功但状态码是 503(要 200)" '(( $(fk p-http-503 curl) >= 1 ))'
POK='FAKE_DIG_OUT="17.253.0.1\n"; '
pc f1-rc   "四-H7 调用后 F1 打印 200 但 curl 退出 28 ⇒ 功能未取得"   "${POK}FAKE_CURL_RC=28" r3_post_runtime "VBAD ③-4 F1 功能观测未取得: 命令失败: curl 退出 28" "VOK ③-4 F1" '(( $(fk f1-rc curl) == 1 ))'
pc f1-503  "四-H8 调用后 F1 查询成功但 503 ⇒ 功能不成立"            "${POK}FAKE_CURL_OUT=503" r3_post_runtime "VBAD ③-4 F1 :81 查询成功但状态码是 503" "VOK ③-4 F1"
pc f1-junk "四-H9 调用后 F1 输出无效 ⇒ 功能未取得"                  "${POK}FAKE_CURL_OUT=OK" r3_post_runtime "VBAD ③-4 F1 功能观测未取得: 输出无效" "VOK ③-4 F1"

# ── DNS ──
rd d-ok    'r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"' "R=0 V=[203.0.113.1]" "四-D1 健康: dig 退出 0、一条 A"
rd d-rc    'FAKE_DIG_RC=9; r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "四-D2 打印地址但 dig 退出 9 ⇒ 命令失败, 输出不采信" "命令失败: dig 退出 9" '(( $(fk d-rc dig) == 1 ))'
rd d-junk  'FAKE_DIG_OUT=";; connection timed out; no servers could be reached\n"; r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "四-D3 退出 0 但输出不是地址 ⇒ 输出无效" "输出无效"
rd d-cname 'FAKE_DIG_OUT="gs-loc.g.aaplimg.com.\n17.253.0.1\n"; r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"' "R=0 V=[17.253.0.1]" "四-D4 健康: CNAME 链只取地址"
rd d-empty 'FAKE_DIG_OUT=""; r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"' "R=0 V=[]" "四-D5 查询成功、没有 A 应答(答案, 由调用方判)"
rd d-oct   'FAKE_DIG_OUT="300.1.1.1\n"; r3_dns_a gs-loc.apple.com; echo "R=$? V=[$R3_VAL]"; echo "WHY=$R3_WHY"' "R=2 V=[]" "四-D6 地址越界 ⇒ 输出无效" "越界"
gcase p-dns-rc     12 "四-D7 调用前 :53 打印接管地址但 dig 退出 9 ⇒ 不调用" 'FAKE_DIG_RC=9' "前像观测无效(:53): 命令失败: dig 退出 9" '(( $(fk p-dns-rc dig) >= 1 ))'
gcase p-dns-nohij  12 "四-D8 调用前 :53 查询成功但没有接管 ⇒ 不调用(业务不满足)" 'FAKE_DIG_OUT="17.253.0.1\n"' ":53 查询成功但没有接管 gs-loc(实得 [17.253.0.1])" '(( $(fk p-dns-nohij dig) >= 1 ))'
pc f2-ok    "四-D9 健康: 调用后 ③-4 全部成立(F2 不再接管)"          "$POK" r3_post_runtime "VOK ③-4 F2 实际功能: :53 正常应答 gs-loc.apple.com(17.253.0.1), 不再接管到 203.0.113.1" "VBAD"
pc f2-rc    "四-D10 调用后 F2 打印正常地址但 dig 退出 9 ⇒ 功能未取得" "${POK}FAKE_DIG_RC=9" r3_post_runtime "VBAD ③-4 F2 功能观测未取得: 命令失败: dig 退出 9" "VOK ③-4 F2" '(( $(fk f2-rc dig) == 1 ))'
pc f2-hij   "四-D11 调用后 F2 仍接管"                                ':' r3_post_runtime "VBAD ③-4 F2 :53 仍把 gs-loc.apple.com 接管到 203.0.113.1" "VOK ③-4 F2"
pc f2-empty "四-D12 调用后 F2 没有 A 应答 ⇒ 功能未取得"             'FAKE_DIG_OUT=""' r3_post_runtime "VBAD ③-4 F2 功能观测未取得: :53 查询成功但对 gs-loc.apple.com 没有 A 应答" "VOK ③-4 F2"
pc f2-junk  "四-D13 调用后 F2 输出无效 ⇒ 功能未取得"                'FAKE_DIG_OUT=";; communications error\n"' r3_post_runtime "VBAD ③-4 F2 功能观测未取得: 输出无效" "VOK ③-4 F2"
cell f2-grep 'grep(){ if [[ "$1" == -qw ]]; then echo hit >> "$HIT"; return 2; fi; command grep "$@"; }'$'\n''r3_post_runtime'
if grep -qF 'VBAD ③-4 F2 :53 仍把' "$T/out-f2-grep" && ! grep -q 'VOK ③-4 F2' "$T/out-f2-grep" && ! hit f2-grep; then
  ok "四-D14 310 的失效形态(匹配那一步 grep 出错)不再可能: 答出接管地址时判「仍接管」; grep 替身没被调(修后匹配不经 grep, 注入如期未命中)"
else bad "四-D14 匹配形态: $(grep -E '^V(OK|BAD) ③-4 F2' "$T/out-f2-grep" | head -c 200) grep 替身被调=$(hit f2-grep && echo 是 || echo 否)"; fi

# ── systemctl 状态词 × 退出码 ──
mktab uq 'is-active u-a1|0|active\n|' 'is-active u-a2|3|inactive\n|' 'is-active u-a3|3|failed\n|' 'is-active u-a4|3|active\n|' \
  'is-active u-a5|1|inactive\n|' 'is-active u-a6|3|inactive\nactive\n|' 'is-active u-a7|0||' 'is-active u-a8|0|running\n|' \
  'is-enabled u-e1|0|enabled\n|' 'is-enabled u-e2|1|enabled\n|' 'is-enabled u-e3|1|disabled\n|' 'is-enabled u-e4|0|disabled\n|' \
  'is-enabled u-e5|0|static\n|' 'is-enabled u-e6|1|masked\n|' 'is-enabled u-e7|1||Failed to get unit file state for u-e7.service: No such file or directory' \
  'is-enabled u-e8|4|not-found\n|' 'is-enabled u-e9|1||Access denied' 'is-enabled u-e10|0|yes\n|' \
  'show:LoadState u-l1|0|not-found\n|' 'show:LoadState u-l2|0|loaded\n|' 'show:LoadState u-l3|1|not-found\n|' 'show:LoadState u-l4|0|not-found\nx\n|' 'show:LoadState u-l5|0|gone\n|'
UQ_EXP="u-a1=0:active u-a2=0:inactive u-a3=0:failed u-a4=2: u-a5=2: u-a6=2: u-a7=2: u-a8=2: u-e1=0:enabled u-e2=2: u-e3=0:disabled u-e4=2: u-e5=0:static u-e6=0:masked u-e7=0:not-found u-e8=0:not-found u-e9=2: u-e10=2: u-l1=0:not-found u-l2=0:loaded u-l3=2: u-l4=2: u-l5=2:"
rd u-table 'SCFIX="$T/sc-uq.tab"; r=""; for q in "active u-a1" "active u-a2" "active u-a3" "active u-a4" "active u-a5" "active u-a6" "active u-a7" "active u-a8" "enabled u-e1" "enabled u-e2" "enabled u-e3" "enabled u-e4" "enabled u-e5" "enabled u-e6" "enabled u-e7" "enabled u-e8" "enabled u-e9" "enabled u-e10" "load u-l1" "load u-l2" "load u-l3" "load u-l4" "load u-l5"; do read -r k u <<<"$q"; r3_unit_q "$k" "$u"; r="$r $u=$?:$R3_VAL"; done; echo "R=${r# } V=[]"' \
   "R=$UQ_EXP V=[]" "四-U1 状态词与原始退出码成对才采信(23 种组合: 正常的非零答案照收, 词表外 / 多行 / 无值 / 不成对 / 查询失败判无效)" "" '(( $(fk u-table systemctl) == 23 ))'
mktab en-rc  'is-enabled pdg-mitm|1|enabled\n|'
mktab en-dis 'is-enabled pdg-mitm|1|disabled\n|'
gcase p-en-rc      12 "四-U2 调用前 is-enabled 打印 enabled 却退出 1 ⇒ 观测无效, 不调用" 'SCFIX="$T/sc-en-rc.tab"' "前像观测无效: pdg-mitm is-enabled 打印 enabled 却退出 1(应为 0)" '(( $(fk p-en-rc "is-enabled pdg-mitm") == 1 ))'
gcase p-en-dis     12 "四-U3 调用前 pdg-mitm 自启是 disabled(有效答案)⇒ 不调用"    'SCFIX="$T/sc-en-dis.tab"' "自启是 disabled(不是 enabled)" '(( $(fk p-en-dis "is-enabled pdg-mitm") == 1 ))'
mktab w1ok 'show:LoadState pdg-mitm|0|not-found\n|'
W1OK='FAKE_SS_PORT=""; SCFIX="$T/sc-w1ok.tab"; '
pc w1-ok    "四-U4 健康: 调用后 W1 三项成立"                          "$W1OK" r3_post_w1 "VOK ③-3 W1 pdg-mitm LoadState=not-found, is-active=inactive" "VBAD"
mktab w1-rc  'is-active pdg-mitm|1|inactive\n|' 'show:LoadState pdg-mitm|0|not-found\n|'
mktab w1-two 'is-active pdg-mitm|3|inactive\nactive\n|' 'show:LoadState pdg-mitm|0|not-found\n|'
mktab w1-ld  'show:LoadState pdg-mitm|1|not-found\n|'
mktab w1-on  'show:LoadState pdg-mitm|0|loaded\n|' 'is-active pdg-mitm|0|active\n|'
pc w1-rc    "四-U5 W1 is-active 打印 inactive 却退出 1 ⇒ 观测无效, 不输出撤除成功" "${W1OK}SCFIX=\"\$T/sc-w1-rc.tab\"" r3_post_w1 "VBAD ③-3 W1 观测无效: pdg-mitm is-active 打印 inactive 却退出 1(应为 3)" "VOK ③-3 W1 pdg-mitm LoadState" '(( $(fk w1-rc "is-active pdg-mitm") == 1 ))'
pc w1-two   "四-U6 W1 is-active 输出两行 ⇒ 观测无效(不只取第一行)"  "${W1OK}SCFIX=\"\$T/sc-w1-two.tab\"" r3_post_w1 "VBAD ③-3 W1 观测无效: pdg-mitm 的 active 查询输出不止一行" "VOK ③-3 W1 pdg-mitm LoadState" '(( $(fk w1-two "is-active pdg-mitm") == 1 ))'
pc w1-ld    "四-U7 W1 LoadState 查询退出 1 ⇒ 观测无效, 输出不采信"  "${W1OK}SCFIX=\"\$T/sc-w1-ld.tab\"" r3_post_w1 "VBAD ③-3 W1 观测无效: pdg-mitm 的 LoadState 查询退出 1" "VOK ③-3 W1 pdg-mitm LoadState" '(( $(fk w1-ld "LoadState") == 1 ))'
pc w1-on    "四-U8 W1 pdg-mitm 仍 loaded/active(有效答案)⇒ 撤除不成立" "${W1OK}SCFIX=\"\$T/sc-w1-on.tab\"" r3_post_w1 "VBAD ③-3 W1 pdg-mitm LoadState=[loaded] is-active=[active]" "VOK ③-3 W1 pdg-mitm LoadState"
mkdir -p "$T/mitm-unit"; : > "$T/mitm-unit/pdg-mitm.service"
pc w1-file  "四-U9 W1 unit 文件还在"                                  "${W1OK}R3_MITM_UNIT=\"\$T/mitm-unit/pdg-mitm.service\"" r3_post_w1 "VBAD ③-3 W1 pdg-mitm unit 文件还在" "VOK ③-3 W1 pdg-mitm unit 文件已删"
mktab s4-en  'is-enabled mosdns|1|enabled\n|'
mktab s4-ac  'is-active pdg-dotwitness|3|active\n|'
mktab s4-dis 'is-enabled mosdns|1|disabled\n|'
pc s4-en    "四-U10 ③-4 mosdns is-enabled 打印 enabled 却退出 1 ⇒ 观测无效" "${POK}SCFIX=\"\$T/sc-s4-en.tab\"" r3_post_runtime "VBAD ③-4 自启态观测无效: mosdns is-enabled 打印 enabled 却退出 1(应为 0)" "VOK ③-4 自启态: mosdns" '(( $(fk s4-en "is-enabled mosdns") == 1 ))'
pc s4-ac    "四-U11 ③-4 pdg-dotwitness is-active 打印 active 却退出 3 ⇒ 观测无效" "${POK}SCFIX=\"\$T/sc-s4-ac.tab\"" r3_post_runtime "VBAD ③-4 运行态观测无效: pdg-dotwitness is-active 打印 active 却退出 3(应为 0)" "VOK ③-4 pdg-dotwitness" '(( $(fk s4-ac "is-active pdg-dotwitness") == 1 ))'
pc s4-dis   "四-U12 ③-4 mosdns 自启是 disabled(有效答案)⇒ 不成立"     "${POK}SCFIX=\"\$T/sc-s4-dis.tab\"" r3_post_runtime "VBAD ③-4 自启态: mosdns = disabled" "VOK ③-4 自启态: mosdns"


echo; echo "══ 五. 持续运行观测(③ 查询记账 + 共享窗口原文) ══"
st(){   # $1=格名 $2=说明 $3=注入代码 $4=期望返回码 $5=判词须含 $6=判词不许含(可空) $7=注入命中 / 覆盖核对(父壳里 eval; 可空)
  cell "$1" "$3"$'\n''r3_stable_assert mosdns running "五: mosdns 持续运行" 5; echo "SR=$?"; n=0; for d in "$R3_TMP"/stableq-*; do [[ -d "$d" ]] && n=$((n+1)); done; echo "LEFT=$n"; [[ "$(type -P systemctl)" == "$T/bin/systemctl" ]] && echo PATHOK; declare -F systemctl >/dev/null && echo "FN=有" || echo "FN=无"; echo "USR1=[$(trap -p USR1)]"'
  local h=是 why=""
  [[ -z "${7:-}" ]] || eval "$7" || h=否
  grep -qx "SR=$4" "$T/out-$1" || why="返回 $(grep -o 'SR=[0-9]*' "$T/out-$1"), 期望 $4"
  grep -qF -- "$5" "$T/out-$1" || why="${why:+$why; }缺「$5」"
  [[ -z "${6:-}" ]] || ! grep -qF -- "$6" "$T/out-$1" || why="${why:+$why; }不该出现「$6」"
  grep -qx 'LEFT=0' "$T/out-$1" && grep -qx PATHOK "$T/out-$1" && grep -qx 'FN=无' "$T/out-$1" || why="${why:+$why; }包装有遗留(目录 / PATH / 同名函数)"
  grep -qxF 'USR1=[]' "$T/out-$1" || why="${why:+$why; }USR1 处置没复原"
  if [[ -z "$why" && "$h" == 是 ]]; then ok "$2 ⇒ 返回 $4, 判词含「$5」${6:+; 无「$6」}${7:+; 注入命中}; 调用后不留包装、PATH 复原、无同名函数、USR1 处置复原"
  else bad "$2: 注入命中=$h $why —— $(grep -E '^V(OK|BAD)|^SR=' "$T/out-$1" | tr '\n' ' ' | head -c 320)"; fi
}
# shellcheck disable=SC2034  # 在父壳 eval 的命中核对串里使用(单引号, ShellCheck 看不到)
AQ='systemctl show -p ActiveState --value mosdns'
st st-ok    "五-1 健康: 全窗口 5 s 持续运行(窗口原样: ActiveState 查 6 次、journal 启动事件查 2 次)" ':' 0 "VOK 五: mosdns 持续运行: 窗口 5s 内持续 running" "VBAD" \
   '(( $(fk st-ok "$AQ") == 6 && $(fk st-ok "journalctl -u mosdns") == 2 && $(fk st-ok "systemctl show -p NRestarts --value mosdns") == 2 ))'
mktab st-id  'show:Id mosdns|1|mosdns.service\n|'
mktab st-as  'show:ActiveState mosdns#3|1|active\n|'
mktab st-nr  'show:NRestarts mosdns#2|1|0\n|'
mktab st-rt  'show:ActiveState mosdns#1|1|\n|'
mktab st-inv 'show:InvocationID mosdns#4|1|0123456789abcdef0123456789abcdef\n|'
mktab st-sub 'show:SubState mosdns#2|1|running\n|'
mktab st-down 'show:ActiveState mosdns#3|0|failed\n|'
mktab st-nr1 'show:NRestarts mosdns#2|0|1\n|'
mktab st-new 'show:InvocationID mosdns#4|0|fedcba9876543210fedcba9876543210\n|'
st st-id    "五-2 身份查询输出合法值后退出 1 ⇒ 观测无效(共享判据本会判持续)" 'SCFIX="$T/sc-st-id.tab"' 2 "窗口里有 1 次查询非零退出(首条: systemctl" "VOK 五" \
   '(( $(served st-id "show:Id mosdns -> rc=1") == 1 )) && grep -qF "show -p Id --value mosdns); 共享判据给的是 rc=0" "$T/out-st-id"'
st st-as    "五-3 窗口第 2 秒 ActiveState 输出 active 后退出 1 ⇒ 观测无效" 'SCFIX="$T/sc-st-as.tab"' 2 "show -p ActiveState --value mosdns); 共享判据给的是 rc=0" "VOK 五" '(( $(served st-as "show:ActiveState mosdns#3 -> rc=1") == 1 ))'
st st-nr    "五-4 窗口后 NRestarts 输出 0 后退出 1 ⇒ 观测无效" 'SCFIX="$T/sc-st-nr.tab"' 2 "show -p NRestarts --value mosdns); 共享判据给的是 rc=0" "VOK 五" '(( $(served st-nr "show:NRestarts mosdns#2 -> rc=1") == 1 ))'
st st-rt    "五-5 wait_stable 第一次查询失败、随后重试成功 ⇒ 仍判观测无效(失败不被覆盖)" 'SCFIX="$T/sc-st-rt.tab"' 2 "show -p ActiveState --value mosdns); 共享判据给的是 rc=0" "VOK 五" '(( $(served st-rt "show:ActiveState mosdns#1 -> rc=1") == 1 && $(fk st-rt "$AQ") == 7 ))'
st st-inv   "五-6 窗口中 InvocationID 输出合法值后退出 1 ⇒ 观测无效" 'SCFIX="$T/sc-st-inv.tab"' 2 "show -p InvocationID --value mosdns); 共享判据给的是 rc=0" "VOK 五" '(( $(served st-inv "show:InvocationID mosdns#4 -> rc=1") == 1 ))'
st st-sub   "五-7 窗口中 SubState 输出合法值后退出 1 ⇒ 观测无效" 'SCFIX="$T/sc-st-sub.tab"' 2 "show -p SubState --value mosdns); 共享判据给的是 rc=0" "VOK 五" '(( $(served st-sub "show:SubState mosdns#2 -> rc=1") == 1 ))'
st st-jc    "五-8 journal 启动事件查询失败 ⇒ 观测无效(记账里是 journalctl)" 'export FAKE_JC_FAIL="-u mosdns"' 2 "窗口里有 1 次查询非零退出(首条: journalctl" "VOK 五" '(( $(served st-jc "journalctl-fail") == 1 ))'
st st-sync  "五-9 journalctl --sync 失败不记账(共享的尽力刷盘, 输出不被判据消费)⇒ 仍按窗口结论" 'export FAKE_JC_FAIL="--sync"' 0 "VOK 五: mosdns 持续运行: 窗口 5s 内持续 running" "观测无效" '(( $(served st-sync "journalctl-fail") >= 1 ))'
st st-down  "五-10 有效但不稳定: 第 2 秒 ActiveState=failed(退出 0)⇒ 不稳定, 不混成读取失败" 'SCFIX="$T/sc-st-down.tab"' 1 "VBAD 五: mosdns 持续运行: 不是持续稳定 —— 窗口内掉出 active" "观测无效" '(( $(served st-down "show:ActiveState mosdns#3 -> rc=0") == 1 ))'
st st-nr1   "五-11 有效但不稳定: 窗口内 NRestarts 0 → 1" 'SCFIX="$T/sc-st-nr1.tab"' 1 "不是持续稳定 —— 窗口内发生了自动重启(NRestarts 0 → 1)" "观测无效" '(( $(served st-nr1 "show:NRestarts mosdns#2 -> rc=0") == 1 ))'
st st-new   "五-12 有效但不稳定: 窗口内 InvocationID 换了" 'SCFIX="$T/sc-st-new.tab"' 1 "不是持续稳定 —— 窗口内实例换过(InvocationID" "观测无效" '(( $(served st-new "show:InvocationID mosdns#4 -> rc=0") == 1 ))'
st st-start "五-13 有效但不稳定: journal 里窗口内有一次 Started" 'export FAKE_START_IN=mosdns' 1 "不是持续稳定 —— 窗口内有 1 次启动事件" "观测无效" '(( $(served st-start "start-in-window mosdns") == 1 ))'
st st-setup "五-14 查询记账建不出来 ⇒ 观测无效, 不跑窗口" 'R3_TMP="$L/snapfile"' 2 "**观测无效** —— 查询记账建不出来" "VOK 五" '[[ -f "$L/snapfile" ]] && (( $(fk st-setup "$AQ") == 0 ))'
# 调用前: 实际门拒绝, 桩 CLI 0 次
gcase st-g-id  12 "五-G1 调用前 mosdns 身份查询合法值 + 非零 ⇒ 门拒绝" 'SCFIX="$T/sc-st-id.tab"' "③-0 前像: mosdns 持续运行: **观测无效** —— 窗口里有 1 次查询非零退出" '(( $(served st-g-id "show:Id mosdns -> rc=1") >= 1 ))'
gcase st-g-as  12 "五-G2 调用前窗口中 ActiveState 合法值 + 非零 ⇒ 门拒绝" 'SCFIX="$T/sc-st-as.tab"' "③-0 前像: mosdns 持续运行: **观测无效**" '(( $(served st-g-as "show:ActiveState mosdns#3 -> rc=1") == 1 ))'
gcase st-g-rt  12 "五-G3 调用前先失败后成功 ⇒ 门拒绝" 'SCFIX="$T/sc-st-rt.tab"' "③-0 前像: mosdns 持续运行: **观测无效**" '(( $(served st-g-rt "show:ActiveState mosdns#1 -> rc=1") == 1 ))'
gcase st-g-dn  12 "五-G4 调用前有效但不稳定 ⇒ 门拒绝(按不稳定)" 'SCFIX="$T/sc-st-down.tab"' "③-0 前像: mosdns 持续运行: 不是持续稳定 —— 窗口内掉出 active" '(( $(served st-g-dn "show:ActiveState mosdns#3 -> rc=0") == 1 ))'
# 调用后: 本项判失败, 不输出"持续运行"成功
pc st-p-as "五-P1 调用后 mosdns 窗口中 ActiveState 合法值 + 非零 ⇒ 不输出持续运行" "${POK}SCFIX=\"\$T/sc-st-as.tab\"" r3_post_runtime "VBAD ③-4 运行态: mosdns 持续运行: **观测无效**" "VOK ③-4 运行态: mosdns 持续运行" '(( $(served st-p-as "show:ActiveState mosdns#3 -> rc=1") == 1 ))'
pc st-p-id "五-P2 调用后 mosdns 身份查询合法值 + 非零 ⇒ 不输出持续运行" "${POK}SCFIX=\"\$T/sc-st-id.tab\"" r3_post_runtime "VBAD ③-4 运行态: mosdns 持续运行: **观测无效**" "VOK ③-4 运行态: mosdns 持续运行" '(( $(served st-p-id "show:Id mosdns -> rc=1") >= 1 ))'
pc st-p-dn "五-P3 调用后有效但不稳定 ⇒ 按不稳定判失败" "${POK}SCFIX=\"\$T/sc-st-down.tab\"" r3_post_runtime "VBAD ③-4 运行态: mosdns 持续运行: 不是持续稳定" "VOK ③-4 运行态: mosdns 持续运行"
pc st-p-ok "五-P4 健康: 调用后三个服务都持续运行(共享窗口真跑)" "$POK" r3_post_runtime "VOK ③-4 运行态: pdg-probe81 持续运行: 窗口 5s 内持续 running" "VBAD" '(( $(fk st-p-ok "journalctl -u mosdns") == 2 && $(fk st-p-ok "journalctl -u pdg-probe81") == 2 ))'


echo; echo "══ 六. 记账通道写入失败(追加失败 ⇒ 观测无效) ══"
RO='export FAKE_REC_RO=1 FAKE_REC_DIR="$R3_TMP" BASH_ENV="$T/obs-bashenv.sh" R3Q_OBS="$T/obs-$1"; : > "$R3Q_OBS"; '
recev(){   # $1=格名 → 注入命中与追加失败的直接证据: 替身把记账设只读、同身份追加被拒、包装自己的 stderr 里有对记账文件的 Permission denied
  [[ "$(served "$1" rec-readonly)" == 1 ]] && grep -q 'served rec-append-probe denied' "$T/fk-$1" && grep -qF '.rec: Permission denied' "$T/obs-$1"
}
TAIL='n=0; for d in "$R3_TMP"/stableq-*; do [[ -d "$d" ]] && n=$((n+1)); done; echo "LEFT=$n"; [[ "$(type -P systemctl)" == "$T/bin/systemctl" ]] && echo PATHOK; declare -F systemctl >/dev/null && echo "FN=有" || echo "FN=无"'
cell rc-ro "${RO}"'SCFIX="$T/sc-st-as.tab"'$'\n''r3_stable_assert mosdns running "六: mosdns 持续运行" 5; echo "SR=$?"; for f in "$R3_TMP"/stableq-mosdns-*.rec; do c="$(cat -- "$f")"; crc=$?; echo "REC mode=$(stat -c %a "$f") size=$(stat -c %s "$f") cat_rc=$crc lines=$(grep -c . <<<"$c")"; done; '"$TAIL"'; echo "USR1=[$(trap -p USR1)]"'
if grep -qx 'SR=2' "$T/out-rc-ro" && grep -qF 'VBAD 六: mosdns 持续运行: **观测无效** —— 记账通道失效: 有失败查询的记录没写进去' "$T/out-rc-ro" && ! grep -q '^VOK 六' "$T/out-rc-ro" \
   && recev rc-ro && grep -qx 'REC mode=444 size=0 cat_rc=0 lines=0' "$T/out-rc-ro" \
   && grep -qx 'LEFT=0' "$T/out-rc-ro" && grep -qx PATHOK "$T/out-rc-ro" && grep -qx 'FN=无' "$T/out-rc-ro" && grep -qxF 'USR1=[]' "$T/out-rc-ro"; then
  ok "六-1 查询输出合法值后退出 1、记账的那次追加失败(文件仍可读、0 字节)⇒ 观测无效; 追加失败有直接证据(包装自己的 Permission denied); 不留包装、USR1 复原"
else bad "六-1 记账追加失败: $(grep -E '^V(OK|BAD)|^SR=|^REC|^USR1' "$T/out-rc-ro" | tr '\n' ' ' | head -c 320) 证据=$(recev rc-ro && echo 齐 || echo 不齐)"; fi
st rc-rt "六-2 追加失败发生在窗口前段(随后查询全部成功)⇒ 失效不被清" "${RO}"'SCFIX="$T/sc-st-rt.tab"' 2 "记账通道失效: 有失败查询的记录没写进去" "VOK 五" 'recev rc-rt && (( $(fk rc-rt "$AQ") == 7 ))'
cell rc-trap 'trap "echo 旧处置被执行" USR1; before="$(trap -p USR1)"'$'\n''r3_stable_assert mosdns running "六: mosdns 持续运行" 5; echo "SR=$?"; after="$(trap -p USR1)"; [[ -n "$after" && "$before" == "$after" ]] && echo TRAPOK'
grep -qx 'SR=0' "$T/out-rc-trap" && grep -qx TRAPOK "$T/out-rc-trap" && grep -q '^VOK 六: mosdns 持续运行' "$T/out-rc-trap" \
  && ok "六-3 健康记账通道: 原有的 USR1 处置在调用后原样复原, 窗口照常通过" || bad "六-3 原有 USR1 处置: $(tr '\n' ' ' < "$T/out-rc-trap" | head -c 240)"
cell rc-trap2 "${RO}"'SCFIX="$T/sc-st-as.tab"; trap "echo 旧处置被执行" USR1; before="$(trap -p USR1)"'$'\n''r3_stable_assert mosdns running "六: mosdns 持续运行" 5; echo "SR=$?"; after="$(trap -p USR1)"; [[ -n "$after" && "$before" == "$after" ]] && echo TRAPOK'
grep -qx 'SR=2' "$T/out-rc-trap2" && grep -qx TRAPOK "$T/out-rc-trap2" && ! grep -q '旧处置被执行' "$T/out-rc-trap2" && grep -qF '记账通道失效' "$T/out-rc-trap2" && recev rc-trap2 \
  && ok "六-4 追加失败 + 原有 USR1 处置: 仍判观测无效, 窗口期间信号只落在本次标志上(原处置没被执行), 调用后原样复原" \
  || bad "六-4 追加失败 + 原有 USR1 处置: $(tr '\n' ' ' < "$T/out-rc-trap2" | head -c 240)"
st rc-ok "六-0 健康: 观测钩子在场、记账通道正常 ⇒ 照常通过, 钩子没记到任何报错" 'export BASH_ENV="$T/obs-bashenv.sh" R3Q_OBS="$T/obs-$1"; : > "$R3Q_OBS"' 0 "VOK 五: mosdns 持续运行: 窗口 5s 内持续 running" "VBAD" '[[ -f "$T/obs-rc-ok" && ! -s "$T/obs-rc-ok" ]]'
gcase rc-g 12 "六-G 调用前记账追加失败 ⇒ 实际门拒绝" "${RO}"'SCFIX="$T/sc-st-as.tab"' "③-0 前像: mosdns 持续运行: **观测无效** —— 记账通道失效" 'recev rc-g'
pc rc-p "六-P 调用后记账追加失败 ⇒ 本项失败, 不输出持续运行" "${POK}${RO}"'SCFIX="$T/sc-st-as.tab"' r3_post_runtime "VBAD ③-4 运行态: mosdns 持续运行: **观测无效** —— 记账通道失效" "VOK ③-4 运行态: mosdns 持续运行" 'recev rc-p'

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

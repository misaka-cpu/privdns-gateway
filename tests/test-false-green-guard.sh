#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 测试自身不许假绿 —— 盯的是"用例通过"这件事本身可不可信。
#
# 起因: test-platform-install.sh 调的 migrate_singbox_gms 随 sing-box 一起退役后, 抽函数的
# sed 只输出空串, `eval ""` 成功, 调用它得到 127(command not found), 而断言写成
#   `migrate_singbox_gms f; grep -q 5228 f && bad ... || ok ...`
# —— 文件里当然没有 5228, 于是稳稳打了个 [OK]。一整段用例什么都没验, 却绿了一整轮。
#
# 所以这里不验业务, 只验护栏: 把"函数不存在""命令不存在"注入真实用例文件, 它必须记 FAIL
# 并以非 0 退出; 顺带确认现行用例跑起来一条 command not found 都没有。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TARGET="$HERE/test-platform-install.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

[[ -f "$TARGET" ]] || { bad "找不到被测用例文件: $TARGET"; echo "通过 $pass, 失败 $nfail"; exit 1; }

# 影子仓库: 用例靠 $HERE/.. 定位 deploy/bot/pdg.sh, 所以副本也得躺在一个 tests/ 里,
# 再把 deploy 软链回真仓库 —— 注入的只有那一行, 被测代码仍是真的。
mkdir -p "$WORK/tests"
ln -s "$ROOT/deploy" "$WORK/deploy"

# 在 A 段之前插一行注入代码, 生成一个"被破坏"的用例副本
mk_variant(){ # $1=输出文件 $2=注入行
  awk -v inj="$2" '
    /^# ── A\. migrate_platform_marker/ && !done { print inj; done=1 }
    { print }
  ' "$TARGET" > "$1"
  grep -qF "$2" "$1"
}

run_variant(){ # $1=注入行 → 打印 "rc|输出"
  local f="$WORK/tests/variant.sh"
  mk_variant "$f" "$1" || { echo "9|注入失败"; return; }
  local out rc
  out="$(bash "$f" 2>&1)"; rc=$?
  printf '%s|%s' "$rc" "$out"
}

# ── 1. 函数不存在(正是 migrate_singbox_gms 那一类)必须记 FAIL ──
r="$(run_variant 'use_fn migrate_singbox_gms_does_not_exist')"
rc="${r%%|*}"; out="${r#*|}"
if [[ "$rc" == 0 ]]; then
  bad "抽不到函数, 用例竟然还是 0 退出(假绿没被堵住)"
elif grep -q '抽取失败' <<<"$out"; then
  ok "抽不到函数 → 记 FAIL 且非 0 退出(rc=$rc)"
else
  bad "抽不到函数虽然非 0, 但没报出原因: $(head -c 200 <<<"$out")"
fi

# ── 2. 调用不存在的命令(127)必须记 FAIL, 不许被后续 grep 掩盖 ──
r="$(run_variant 'run_ok "缺命令" pdg_no_such_command_zz')"
rc="${r%%|*}"; out="${r#*|}"
if [[ "$rc" != 0 ]] && grep -q '退出码 127' <<<"$out"; then
  ok "命令不存在(127) → 记 FAIL 且非 0 退出"
else
  bad "命令不存在没被记 FAIL: rc=$rc $(head -c 200 <<<"$out")"
fi

# ── 3. 被测函数返回非 0 也要记 FAIL(不只是 127) ──
r="$(run_variant 'boom(){ return 3; }; run_ok "非零返回" boom')"
rc="${r%%|*}"; out="${r#*|}"
if [[ "$rc" != 0 ]] && grep -q '退出码 3' <<<"$out"; then
  ok "被测函数返回 3 → 记 FAIL 且非 0 退出"
else
  bad "非 0 返回被吞掉: rc=$rc $(head -c 200 <<<"$out")"
fi

# ── 4. 未注入时: 现行用例必须全绿, 且一条 command not found 都不能有 ──
out="$(bash "$TARGET" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "现行 test-platform-install.sh 全绿(rc=0)" || bad "现行用例未通过: rc=$rc"
grep -qi 'command not found\|未找到命令' <<<"$out" \
  && bad "现行用例里仍有 command not found: $(grep -i 'command not found\|未找到命令' <<<"$out" | head -2)" \
  || ok "现行用例执行期间没有 command not found"
grep -q '^\[FAIL\]' <<<"$out" && bad "现行用例有 FAIL 行" || ok "现行用例没有 FAIL 行"
n="$(grep -c '^\[OK\]' <<<"$out")"
[[ "$n" -ge 30 ]] && ok "现行用例断言数 $n 条(不是零断言绿)" || bad "断言数只有 $n 条, 疑似整段被跳过"

# ── 5. 用例里的 grep 模式必须按 POSIX 写 ──
# 起因: e2e-config-transaction.sh 用 `grep -o 'PROBE|[^\n]*'` 取探针结论。开发机的 grep 是
# ugrep, 把 \n 当换行; CI 容器里是 GNU grep 3.8, 按 POSIX 把方括号里的 \n 当成"反斜杠或字母 n",
# 于是 "PROBE|fail|netns 不可用…" 被截成 "PROBE|fail|" —— 断言拿不到原因那一半, 本地长绿、CI 长红,
# 而且方向反过来(本地严格、CI 宽松)时就是**假绿**。所以这条护栏两头都要盯:
STRICT=""
if command -v busybox >/dev/null 2>&1 && printf 'a\n' | busybox grep -q a 2>/dev/null; then
  STRICT="busybox grep"
elif grep --version 2>/dev/null | head -1 | grep -q 'GNU grep'; then
  STRICT="grep"
fi
LINE='PROBE|fail|netns 不可用(x)'
printf '%s\n' "$LINE" > "$WORK/gl"
if [[ -n "$STRICT" ]]; then
  got="$($STRICT -o 'PROBE|.*' "$WORK/gl")"
  [[ "$got" == "$LINE" ]] \
    && ok "POSIX grep($STRICT)下 'PROBE|.*' 取到完整结论" \
    || bad "POSIX grep($STRICT)下取到的是截断结果: [$got]"
  cut="$($STRICT -o 'PROBE|[^\n]*' "$WORK/gl")"   # posix-grep-ok: 这里就是要那个坏写法当负控
  [[ "$cut" != "$LINE" ]] \
    && ok "反向对照: 同一行用 [^\\n] 在 POSIX grep 下确实被截成 [$cut]" \
    || ok "本机 $STRICT 对 [^\\n] 宽松(不截断)—— 静态扫描仍然拦这类写法"
fi
# 静态扫描: 谁再在 shell 的 grep/sed 里写方括号反斜杠转义, 这里就红(内嵌 python 正则不算,
# 那里 \n 本来就是换行)。
RISK="$(grep -rnE '(grep|sed|egrep|fgrep|awk)[^#]*\[\^?\\[ndtswb]' \
          "$ROOT"/tests/*.sh "$ROOT"/deploy/bot/*.sh "$ROOT"/deploy/cert/*.sh \
          "$ROOT"/lib/*.sh "$ROOT"/install.sh "$ROOT"/uninstall.sh 2>/dev/null \
        | grep -v 're\.\(sub\|search\|match\|findall\|compile\)' \
        | grep -v ':[0-9]*:[[:space:]]*#' \
        | grep -v 'posix-grep-ok' || true)"
[[ -z "$RISK" ]] \
  && ok "shell 的 grep/sed 模式里没有方括号反斜杠转义(不依赖 ugrep 的宽松解释)" \
  || bad "有 POSIX 下会被截断的 grep/sed 模式: $(head -2 <<<"$RISK")"
# 探测器自身的负控: 用出问题那一版的真实文件喂它, 必须报出来(不然这条扫描是摆设)
OLDF="$WORK/old-e2e.sh"
if git -C "$ROOT" show HEAD~0:tests/e2e-config-transaction.sh > "$OLDF" 2>/dev/null; then
  printf "%s\n" "  python3 - \"\$TX\" \"\$2\" 2>&1 <<'PY' | grep -o 'PROBE|[^\\n]*' | tail -1" >> "$OLDF"
  grep -qE '(grep|sed|egrep|fgrep|awk)[^#]*\[\^?\\[ndtswb]' "$OLDF" \
    && ok "负控: 把出问题那行塞回文件, 扫描确实报警" \
    || bad "负控失败: 扫描连已知有问题的写法都认不出来"
fi

# ── 故障注入必须真命中, 且遍历必须真的覆盖 manifest 全集 ────────────────────
# 上一轮的教训: test-update-faults.sh 的注入按 `install … /opt/pdg-bot/` 这种**命令行字面
# 形态**匹配。生产侧改成显式目标名之后注入全部打空, 而测试照样全绿 —— 五条"iOS 组件装失败
# 必须回滚"一条都没真跑过。所以守卫要盯两件事: 注入命中要有记录, 命中数要覆盖 manifest 全集。
echo; echo "── 故障注入命中率 ──"
_u="$ROOT/tests/test-update-faults.sh"
grep -q 'e2e-inject-hit' "$_u" \
  && ok "update 故障注入会记录「已命中」" || bad "注入没有命中记录 —— 打空了也看不出来"
grep -q '故障注入\*\*未命中\*\*' "$_u" \
  && ok "未命中时判测试自己失败(不是判产品通过)" || bad "未命中没有守卫"
grep -qE 'FAIL_TARGET|FAIL_NTH' "$_u" \
  && ok "注入按受管目标名/序号命中, 不按命令行字面形态" || bad "注入仍按命令行字符串匹配"
# manifest 全集必须被真的走过一遍: 头、中、尾三个序号都要有对应用例。
_n=$(bash -c 'source "'"$ROOT"'/lib/modules.sh"; pdg_platform_modules ios | grep -c .')
grep -qE "FAIL_NTH=1\"" "$_u" && grep -qE "FAIL_NTH=$_n\"" "$_u" \
  && ok "遍历的头(#1)与尾(#$_n)都有注入用例, 覆盖 manifest 全集" \
  || bad "没有覆盖 manifest 首尾(全集 $_n 项)"
# 平台桩必须与真实 manifest 同构, 否则 iOS 那批永远不进 install
grep -q 'PDG_IOS_MODULES' "$_u" \
  && ok "故障注入的平台桩按平台展开(与 pdg_platform_modules 同构)" \
  || bad "平台桩只展开通用清单 —— iOS 注入必然打空"

echo; echo "── 部署断言必须是行为而非源码字面 ──"
_pi="$ROOT/tests/test-platform-install.sh"
grep -qE "grep -q 'mitm_ca\.py\|" "$_pi" \
  && bad "test-platform-install 仍靠 grep 某一行安装源码证明部署" \
  || ok "test-platform-install 不再用源码字面证明部署"
grep -q 'pdg_install_runtime_modules "\$ROOT"' "$_pi" \
  && ok "改为真跑部署函数并核对内容/mode/幂等" || bad "没有真跑部署"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

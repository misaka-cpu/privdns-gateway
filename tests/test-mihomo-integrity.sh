#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mihomo 完整性闭包 —— 与 mosdns 那套**同一种语义**, 不另立宽松版本。
#
# 修之前这里是四个连着的假绿(每一条都在本轮 POC 里实测复现过):
#   ① pdg_mihomo_version 问的是 **PATH** 上的 mihomo, 而 systemd 执行的是
#      /usr/local/bin/mihomo。PATH 上放一个自报 v1.19.30 的壳, 判据就答"已是钉死版";
#   ② 判据只比**自报版本**。版本是二进制自己说的 —— 换掉内容、留住版本串, install.sh 与
#      _update_core_binary 都会跳过下载, 而日志上连"下载 mihomo"这行都不会出现;
#   ③ lib/versions.sh 只钉了**压缩包**摘要。而压缩包摘要只在"真的下载了"那条路上起作用,
#      被 ① ② 一短路就永远用不上 —— 落盘的那个文件本身, 项目从来没钉过;
#   ④ 顶层「已是最新」短路只比仓库文件, 不看内核二进制。于是"仓库最新 + 项目文件一致 +
#      内核内容漂移"这个现场里, pdg update 直接返回 0, 把唯一的修复路径堵死。
#
# 判据必须是: **绝对路径 + 退出码 + 自报版本 + 内容摘要**, 四者全中才算数。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-mihint.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
command -v git >/dev/null 2>&1 || { echo "[SKIP] 无 git"; exit 0; }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

xtv(){ sed -n "/^$1(){/,/^}/p" "$ROOT/lib/versions.sh"; }
xtp(){ sed -n "/^$1(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"; }
PIN_VER="$(grep -oE 'MIHOMO_VER="[^"]+"' "$ROOT/lib/versions.sh" | cut -d'"' -f2)"

echo "══ 1. lib/versions.sh 钉了**解压后二进制**的摘要 ══"
for a in amd64 arm64; do
  v="$(grep -oE "\[mihomo-bin-$a\]=\"[0-9a-f]{64}\"" "$ROOT/lib/versions.sh" | grep -oE '[0-9a-f]{64}')"
  [[ -n "$v" ]] && ok "[mihomo-bin-$a] 已钉(${v:0:12}…)" \
    || bad "[mihomo-bin-$a] 缺失 —— 只钉压缩包的话, 一旦短路就永远用不上那个钉值"
done
grep -q 'pdg_mihomo_binary_ok' "$ROOT/lib/versions.sh" \
  && ok "有统一判据 pdg_mihomo_binary_ok" || bad "没有 pdg_mihomo_binary_ok —— 判据没收口"

echo
echo "══ 2. 判据本体: 绝对路径 + 退出码 + 自报版本 + 内容摘要, 四者全中 ══"
BIN="$WORK/bin"; mkdir -p "$BIN" "$WORK/shadow"
mk(){ # $1=自报版本 $2=内容标记 $3=落点 [$4=退出码]
  printf '#!/bin/sh\n# %s\ncase "$1" in -v) echo "Mihomo Meta %s linux amd64 with go1.26";; esac\nexit %s\n' \
    "$2" "$1" "${4:-0}" > "$3"; chmod 755 "$3"; }
mk "$PIN_VER" OFFICIAL "$WORK/official"
GOOD_SHA="$(sha256sum "$WORK/official" | cut -d' ' -f1)"

mkvers(){ # 造一份只认 GOOD_SHA 的 versions.sh(结构与生产同形); 判据本体从真文件抽
  mkdir -p "$1"
  { echo "MIHOMO_VER=\"$PIN_VER\""
    echo "declare -A PDG_SHA256=( [mihomo-bin-amd64]=\"$GOOD_SHA\" [mihomo-bin-arm64]=\"$GOOD_SHA\" )"
    xtv pdg_mihomo_version; xtv pdg_mihomo_is_version; xtv pdg_mihomo_binary_ok
  } > "$1/versions.sh"
}
mkvers "$WORK/v"
# rc 约定: 0=放行  127=**判据本身不存在**(不是拒绝!)  其它非 0=拒绝
# 这一层必须分开: 第一版把 127 也算成"拒绝", 于是在 pdg_mihomo_binary_ok 还没写出来的时候
# 五格全绿 —— 那是"函数不存在"冒充"判据有牙齿", 正是本轮要清的那类假绿。
ask(){ # $1=二进制路径; PATH 上永远有一个自报正确版本的影子
  PATH="$WORK/shadow:$PATH" bash -c "
    source '$WORK/v/versions.sh' 2>/dev/null || exit 99
    command -v pdg_mihomo_binary_ok >/dev/null 2>&1 || exit 127
    pdg_mihomo_binary_ok amd64 '$PIN_VER' '$1'" >/dev/null 2>&1; echo $?
}
mk "$PIN_VER" PATH-SHADOW "$WORK/shadow/mihomo"     # PATH 影子: 自报版本正确, 内容是别的

cp "$WORK/official" "$BIN/mihomo"; chmod 755 "$BIN/mihomo"
[[ "$(ask "$BIN/mihomo")" == 0 ]] && ok "版本对 + 摘要对 → 放行" || bad "合法却被拒"

declare -a CASES=(
  "同版本错误摘要|mk \"\$PIN_VER\" TAMPERED \"\$BIN/mihomo\""
  "绝对路径旧版|mk v1.19.29 OLD \"\$BIN/mihomo\""
  "绝对路径缺失|rm -f \"\$BIN/mihomo\""
  "不可执行|cp \"\$WORK/official\" \"\$BIN/mihomo\"; chmod 644 \"\$BIN/mihomo\""
)
for c in "${CASES[@]}"; do
  nm="${c%%|*}"; eval "${c#*|}"
  r="$(ask "$BIN/mihomo")"
  if [[ "$r" == 127 ]]; then
    bad "[$nm] 判据 pdg_mihomo_binary_ok 不存在 —— 这一格**未验**, 不是通过"
  elif [[ "$r" != 0 ]]; then ok "[$nm] 拒绝(rc=$r)"
  else bad "[$nm] 竟然放行 —— PATH 上那个自报 $PIN_VER 的壳把判据骗过去了"; fi
done
# 「退出码非零」必须**单独**隔离出来测。放在上面那个循环里是测不出来的: 那些用例的内容
# 与钉值本来就不同, 摘要那一关先把它挡了 —— 于是把"要求 rc=0"整条删掉, 用例照样绿
# (负控当场揭穿过这一点)。这里给 rc=3 的那个壳**配它自己的钉值**, 让版本与摘要都对上,
# 唯一不对的就是退出码。
mk "$PIN_VER" RC3 "$WORK/rc3" 3
RC3_SHA="$(sha256sum "$WORK/rc3" | cut -d' ' -f1)"
mkdir -p "$WORK/v3"
{ echo "MIHOMO_VER=\"$PIN_VER\""
  echo "declare -A PDG_SHA256=( [mihomo-bin-amd64]=\"$RC3_SHA\" [mihomo-bin-arm64]=\"$RC3_SHA\" )"
  xtv pdg_mihomo_version; xtv pdg_mihomo_is_version; xtv pdg_mihomo_binary_ok
} > "$WORK/v3/versions.sh"
r=$(PATH="$WORK/shadow:$PATH" bash -c "
  source '$WORK/v3/versions.sh' 2>/dev/null || exit 99
  command -v pdg_mihomo_binary_ok >/dev/null 2>&1 || exit 127
  pdg_mihomo_binary_ok amd64 '$PIN_VER' '$WORK/rc3'" >/dev/null 2>&1; echo $?)
case "$r" in
  127) bad "[命令非零但版本与摘要都对] 判据不存在 —— 未验";;
  0)   bad "[命令非零但版本与摘要都对] 放行了 —— 退出码没被当成证据的一部分";;
  *)   ok  "[命令非零但版本与摘要都对] 拒绝(rc=$r) —— 退出码是证据的一部分";;
esac

# 未知架构 / 缺钉值 一律拒绝(fail-closed)
cp "$WORK/official" "$BIN/mihomo"; chmod 755 "$BIN/mihomo"
# 这两格同样要把 127 与"拒绝"分开 —— 否则判据不存在时它们也报绿。
judge(){ # $1=标签 $2=rc
  case "$2" in
    127) bad "[$1] 判据不存在 —— 这一格**未验**, 不是通过";;
    0)   bad "[$1] 放行了 —— 无从对照时必须拒绝(fail-closed)";;
    *)   ok  "[$1] 拒绝(无从对照, rc=$2)";;
  esac
}
r=$(PATH="$WORK/shadow:$PATH" bash -c "
  source '$WORK/v/versions.sh' 2>/dev/null || exit 99
  command -v pdg_mihomo_binary_ok >/dev/null 2>&1 || exit 127
  pdg_mihomo_binary_ok riscv64 '$PIN_VER' '$BIN/mihomo'" >/dev/null 2>&1; echo $?)
judge "未知架构" "$r"
r=$(bash -c "MIHOMO_VER='$PIN_VER'; declare -A PDG_SHA256=()
  $(xtv pdg_mihomo_version)
  $(xtv pdg_mihomo_is_version)
  $(xtv pdg_mihomo_binary_ok)
  command -v pdg_mihomo_binary_ok >/dev/null 2>&1 || exit 127
  pdg_mihomo_binary_ok amd64 '$PIN_VER' '$BIN/mihomo'" >/dev/null 2>&1; echo $?)
judge "缺钉值" "$r"

echo
echo "══ 3. 判据问的是**绝对路径**, 不是 PATH ══"
[[ "$(grep -c '/usr/local/bin/mihomo' "$ROOT/lib/versions.sh" || true)" != 0 ]] \
  && ok "versions.sh 里出现了 systemd 执行的那个绝对路径" \
  || bad "判据里没有绝对路径 —— 那它问的还是 PATH"
# 生产源码(去注释后)不得再用只比版本的老判据决定装不装
# ⚠️ 这里**不能**用 `… | grep -q …` 作条件: 本文件开头有 set -o pipefail, 而 grep -q
# 一命中就关掉管道 → 上游 sed 收到 SIGPIPE 退 141 → pipefail 把整条管道判成失败 →
# 条件**整个反转**。第一版就是这么写的, 结果两条断言在生产代码明明没改的情况下报绿。
# 改用计数: 先把结果收进变量, 管道跑完再判。
cnt(){ sed 's/#.*//' "$1" | grep -c "$2" || true; }   # 去注释后的命中数
[[ "$(cnt "$ROOT/install.sh" 'pdg_mihomo_is_version')" == 0 ]] \
  && ok "install.sh 的跳过判据已换成内容级判据" \
  || bad "install.sh 仍用 pdg_mihomo_is_version 决定跳过下载(只比自报版本)"
[[ "$(cnt "$ROOT/deploy/bot/pdg.sh" 'pdg_mihomo_is_version')" == 0 ]] \
  && ok "_update_core_binary 的跳过判据已换成内容级判据" \
  || bad "_update_core_binary 仍用 pdg_mihomo_is_version 决定跳过换核"
[[ "$(cnt "$ROOT/install.sh" 'mihomo-bin-')" != 0 ]] \
  && ok "install.sh 落盘后按 mihomo-bin-* 二次核验" || bad "install.sh 落盘后没有二次核验"

echo
echo "══ 4. 顶层「已是最新」短路不得堵死修复路径 ══"
# 现场: 仓库精确在最新 tag、工作树干净、已装项目文件逐个一致, 但内核二进制内容漂移。
# 这一格必须跑**完整 cmd_update**, 只测 helper 证明不了短路会不会先答话。
sed -n '/^cmd_update(){/,/^}/p'               "$ROOT/deploy/bot/pdg.sh" >  "$WORK/upd.sh"
for f in _update_release_relation _update_in_sync _pdg_same_file _core_bindir _update_mosdns_preflight; do
  sed -n "/^$f(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh" >> "$WORK/upd.sh"
done
RT="$WORK/rt"; REPO="$WORK/repo"; mkdir -p "$RT" "$REPO/lib" "$REPO/deploy/bot" "$REPO/deploy/cert"
cp "$ROOT/lib/versions.sh" "$REPO/lib/versions.sh"
printf 'pdg_install_runtime_modules(){ return 0; }\npdg_platform_modules(){ echo "deploy/bot/x.py x.py 644"; }\nPDG_RUNTIME_DIR="%s"\n' "$RT" > "$REPO/lib/modules.sh"
echo xpy > "$REPO/deploy/bot/x.py"; cp "$REPO/deploy/bot/x.py" "$RT/x.py"
for f in deploy/cert/proxy-gateway-open-cert-http.sh deploy/cert/proxy-gateway-restore-firewall.sh deploy/bot/pdg-set-token.sh deploy/bot/pdg.sh; do
  mkdir -p "$REPO/$(dirname "$f")"; echo "$f" > "$REPO/$f"; done
cp "$REPO/deploy/cert/proxy-gateway-open-cert-http.sh"   "$BIN/proxy-gateway-open-cert-http.sh"
cp "$REPO/deploy/cert/proxy-gateway-restore-firewall.sh" "$BIN/proxy-gateway-restore-firewall.sh"
cp "$REPO/deploy/bot/pdg-set-token.sh" "$BIN/pdg-set-token"; cp "$REPO/deploy/bot/pdg.sh" "$BIN/pdg"
# 会写 ref/config 的 git 一律走 e2e_git(见 test-e2e-repo-guard.py 与 07-31 那次事故)。
git init -qb main "$REPO" >/dev/null 2>&1
e2e_git "$REPO" config user.email t@t        >/dev/null 2>&1
e2e_git "$REPO" config user.name t           >/dev/null 2>&1
e2e_git "$REPO" config commit.gpgsign false  >/dev/null 2>&1
e2e_git "$REPO" add -A                       >/dev/null 2>&1
e2e_git "$REPO" commit -qm v1                >/dev/null 2>&1
e2e_git "$REPO" tag -a v9.9.9 -m v9.9.9      >/dev/null 2>&1
mk "$PIN_VER" DRIFTED-CONTENT "$BIN/mihomo"        # 自报版本正确, 内容不是官方那份
# _update_in_sync 现在同时问 mihomo 与 mosdns 两条。要让这一格**只**说明 mihomo 那条,
# 就得先把 mosdns 那条弄成通过 —— 否则把 mihomo 判据整个删掉, 短路照样不成立(mosdns
# 先失败了), 这一格就永远绿。负控揭穿过这一点。
if [[ -x /usr/local/bin/mosdns ]]; then
  cp /usr/local/bin/mosdns "$BIN/mosdns" 2>/dev/null && chmod 755 "$BIN/mosdns"
fi
if bash -c "source '$ROOT/lib/versions.sh'; m=\$(dpkg --print-architecture 2>/dev/null || echo amd64)
            pdg_mosdns_binary_ok \"\$m\" \"\$MOSDNS_VER\" '$BIN/mosdns'" 2>/dev/null; then
  ok "前提: 沙箱里的 mosdns 已是钉死版(这一格才只反映 mihomo 那一条)"
else
  bad "前提不成立: 沙箱 mosdns 不是钉死版 —— 这一格的结论会被 mosdns 判据混淆, 判为未验"
fi
cat > "$WORK/h.sh" <<EOF
REPO_DIR="$REPO"; REPO_URL="file:///dev/null"; ENVF="$WORK/none.env"
PDG_CORE_BINDIR="$BIN"; PDG_RUNTIME_DIR="$RT"
need_root(){ :; }; _lock(){ :; }; c_g(){ echo "\$*"; }; c_y(){ echo "\$*"; }; sleep(){ :; }
_pdg_platform(){ echo android; }; _pdg_core(){ echo mihomo; }; _pdg_bot_cred(){ echo unset; }
pdg_fetch_release_tags(){ return 0; }
# ── 快照产出与前像确认: **可控替身**, 两个都是模型 ──────────────────────────
# 本分支的契约: 服务前像由 cmd_snapshot 保存并校验, cmd_update 只**确认**它可用 ——
# 缺 svcstate.tsv 或 _pdg_svcstate_plan 不过, 就在动第一样东西之前中止(见 pdg.sh)。
# 原来这个壳只造 snap.tar.gz、也没有 _pdg_svcstate_plan 的定义, 于是 cmd_update 卡在那道
# 门上, 根本走不到换核 —— 第 4 节测的东西整个落空。
#
# 这两个替身**明确是模型**: 它们不读 systemctl、不代表真实服务前像已验收(那属于真实
# systemd 验收与 test-update-rollback / bridge-scope 那几支)。这里只是把"快照产出"和
# "前像确认"这两个前置条件接上, 让第 4 节能问它真正要问的那个问题。
# 也**不能**写成恒真: 那等于把生产的两道门从壳里抹掉。沿用 relation/preflight 两支已有
# 的做法 —— 默认成功且留痕, SVCSTATE_RC / PLAN_RC 两个旋钮可以按码喂失败;
# PLAN_ALWAYS_OK 只给"定向撤销对照"那一格用, 用来证明这个替身本身不是恒真。
_pdg_save_svcstate(){
  printf 'SVCSTATE_SAVE %s rc=%s\n' "\${1:-<无参>}" "\${SVCSTATE_RC:-0}" >> "$WORK/side.log"
  [[ -n "\${1:-}" && -d "\${1:-}" ]] && printf 'modeled-svcstate\n' > "\$1/svcstate.tsv"
  return "\${SVCSTATE_RC:-0}"
}
_pdg_svcstate_plan(){
  if [[ "\${PLAN_ALWAYS_OK:-0}" == 1 ]]; then echo "PLAN always-ok" >> "$WORK/side.log"; return 0; fi
  printf 'PLAN %s rc=%s\n' "\${1:-<无参>}" "\${PLAN_RC:-0}" >> "$WORK/side.log"
  if [[ ! -f "\$1/svcstate.tsv" ]]; then _PDG_SVC_WHY="svcstate.tsv 不存在(模型)"; return 1; fi
  _PDG_SVC_WHY="前像确认不通过(模型注入)"
  return "\${PLAN_RC:-0}"
}
cmd_snapshot(){ echo SNAPSHOT >> "$WORK/side.log"
  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "\$_PDG_SNAP_CREATED"
  : | gzip > "\$_PDG_SNAP_CREATED/snap.tar.gz"
  # 前像存不下 ⇒ 这次快照就不算成功(与生产同形: 前像是快照的一部分)
  _pdg_save_svcstate "\$_PDG_SNAP_CREATED" || { _PDG_SNAP_CREATED=""; return 1; }
  return 0; }
cmd_rollback(){ echo ROLLBACK >> "$WORK/side.log"; return 0; }
# 动没动现役仓库要看得见: reset 是"已经开始动手"的分界线。
git(){ printf 'git %s\n' "\$*" >> "$WORK/git.log"; command git "\$@"; }
_update_core_binary(){ echo CORE_STEP >> "$WORK/side.log"; return 0; }
_update_mosdns_binary(){ return 0; }
install(){ echo "install \$*" >> "$WORK/side.log"; return 0; }
systemctl(){ echo "systemctl \$*" >> "$WORK/side.log"; return 0; }
python3(){ case "\$*" in *py_compile*) return 0;; *doctor.py*) echo '[{"level":"ok","check":"x","detail":"y"}]';; *) command python3 "\$@";; esac; }
mihomo(){ return 0; }; nft(){ return 0; }
bash(){ [[ "\$*" == *__migrate* ]] && { echo migrate >> "$WORK/side.log"; return 0; }; command bash "\$@"; }
_pdg_bot_cred(){ echo unset; }
EOF
# ── 执行有效性先于结论 ────────────────────────────────────────────────────────
# 抽出来的产品片段与壳都得先过 bash -n。语法不过、函数没定义、变量没绑定, 这些都会让
# cmd_update 在半路非零退出 —— 那时"没到换核"是壳坏了, 不是产品短路, 两者处置完全不同。
bash -n "$WORK/upd.sh" 2>"$WORK/n-upd.err" \
  && ok "4-0a: 抽出的 cmd_update 片段语法通过" \
  || bad "4-0a: 抽出的片段语法不过 —— 本节结论无效: $(head -2 "$WORK/n-upd.err" | tr '\n' ' ')"
bash -n "$WORK/h.sh" 2>"$WORK/n-h.err" \
  && ok "4-0b: 壳语法通过" \
  || bad "4-0b: 壳语法不过 —— 本节结论无效: $(head -2 "$WORK/n-h.err" | tr '\n' ' ')"

C4_OUT=""; C4_RC=0
_c4(){   # $@ = 形如 VAR=值 的旋钮; 结果落在 C4_OUT / C4_RC 与 side.log / git.log
  : > "$WORK/side.log"; : > "$WORK/git.log"
  C4_RC=0
  C4_OUT=$(env "$@" PATH="$WORK/shadow:$PATH" \
           bash -c "source '$WORK/h.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1) || C4_RC=$?
  printf '%s\n' "$C4_OUT" > "$WORK/upd.out"
}
# 诊断干净 = 没有"壳坏了"的三种症状。它们一旦出现, 本格无论走没走到 CORE_STEP 都不算数。
_c4_clean(){ ! grep -qE 'command not found|未找到命令|unbound variable|syntax error' <<<"$C4_OUT"; }
# 还一样东西都没动: 没换核、没装文件、没动现役仓库的 ref
_c4_untouched(){
  ! grep -q CORE_STEP "$WORK/side.log" \
  && ! grep -q '^install ' "$WORK/side.log" \
  && ! grep -qE '(^| )reset ' "$WORK/git.log"
}
_c4_tail(){ tail -3 "$WORK/upd.out" | tr '\n' ' '; }

# ── 4a 健康前提: same 但内核内容漂移 ⇒ 必须走到换核 ──────────────────────────
# 这一格只证明**更新编排能够到达换核这一步**。它不是"update 全流程成功"的验收:
# 快照、前像、迁移、三道校验门、doctor 自检门在这个壳里都是替身或模型。
_c4
if ! _c4_clean; then
  bad "4a: 壳自身出错(command not found / unbound variable / syntax error), 结论无效: $(_c4_tail)"
elif grep -q CORE_STEP "$WORK/side.log"; then
  ok "4a: 内核内容漂移时 update 不再被「已是最新」短路挡住(走到了换核这一步; cmd_update rc=$C4_RC)"
  # 退出码单独核对: 到达换核之后要么一路走完(rc=0), 要么停在**点得出名字**的那一处。
  # 不把任意非零当预期 —— 那会把"壳半路炸了"读成"受控终止"。
  if [[ "$C4_RC" == 0 ]]; then
    ok "4a-rc: cmd_update 在本壳里一路返回 0(替身齐备时没有受控终止)"
  elif grep -qE '回滚到更新前快照|中止更新' <<<"$C4_OUT"; then
    ok "4a-rc: cmd_update 以**点了名的**受控终止收场(rc=$C4_RC): $(grep -m1 -E '回滚到更新前快照|中止更新' <<<"$C4_OUT")"
  else
    bad "4a-rc: rc=$C4_RC 但输出里没有任何点得出名字的终止 —— 不按预期失败记: $(_c4_tail)"
  fi
else
  bad "4a: 内核内容漂移时没走到换核这一步(rc=$C4_RC)。链路末尾: $(_c4_tail)"
fi

# ── 4b 快照/前像产出失败 ⇒ 在安装与换核之前就停 ──────────────────────────────
_c4 SVCSTATE_RC=1
{ [[ "$C4_RC" != 0 ]] && grep -q '快照失败' <<<"$C4_OUT" && _c4_clean; } \
  && ok "4b: 前像存不下 ⇒ 快照不算成功 ⇒ 中止更新(rc=$C4_RC)" \
  || bad "4b: 没按'快照失败'挡住(rc=$C4_RC): $(_c4_tail)"
_c4_untouched \
  && ok "4b-2: 且此时**没有**换核、没有装文件、没有动现役仓库 ref" \
  || bad "4b-2: 已经动手了 —— side.log: $(tr '\n' ' ' < "$WORK/side.log") git.log: $(tr '\n' ' ' < "$WORK/git.log")"

# ── 4c 文件在、但前像**确认**不过 ⇒ 同样提前停, 且点明原因 ────────────────────
_c4 PLAN_RC=1
{ [[ "$C4_RC" != 0 ]] && grep -q '服务前像不可用' <<<"$C4_OUT" && _c4_clean; } \
  && ok "4c: 前像确认不过 ⇒ 动手之前中止(rc=$C4_RC)" \
  || bad "4c: 没按'服务前像不可用'挡住(rc=$C4_RC): $(_c4_tail)"
grep -q '前像确认不通过(模型注入)' <<<"$C4_OUT" \
  && ok "4c-2: 中止文案点明了原因(带出 _PDG_SVC_WHY, 不是一句笼统的失败)" \
  || bad "4c-2: 中止文案没带出原因: $(grep -m1 '服务前像不可用' <<<"$C4_OUT" || echo 无)"
grep -q "^PLAN $WORK/snap " "$WORK/side.log" \
  && ok "4c-3: 确认这一步确实被调到, 且参数是本次那份快照目录" \
  || bad "4c-3: 没有 PLAN 留痕(替身没被调到?): $(tr '\n' ' ' < "$WORK/side.log")"
_c4_untouched \
  && ok "4c-4: 且此时**没有**换核、没有装文件、没有动现役仓库 ref" \
  || bad "4c-4: 已经动手了 —— side.log: $(tr '\n' ' ' < "$WORK/side.log") git.log: $(tr '\n' ' ' < "$WORK/git.log")"

# ── 4d 定向撤销对照: 把前像确认的替身改成恒真, 4c 的拦截必须随之消失 ──────────
# 撤的是**替身的可控性**(产品一个字节不动)。4c 的红要是与这道门无关, 这里就不会有变化 ——
# 那说明上面拦住更新的是别的东西, 4c 的区分力是假的。
_c4 PLAN_RC=1 PLAN_ALWAYS_OK=1
{ ! grep -q '服务前像不可用' <<<"$C4_OUT" && grep -q CORE_STEP "$WORK/side.log" && _c4_clean; } \
  && ok "4d: 替身恒真后同一次运行不再被前像门拦住, 并走到了换核 ⇒ 4c 拦的确实是那道门" \
  || bad "4d: 撤销对照没生效(rc=$C4_RC) —— 4c 的区分力未验: $(_c4_tail)"

echo "────────────────────────────────────────"
echo "$(basename "$0"): 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

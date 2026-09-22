#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mosdns 二进制不合法时, `pdg update` 必须在**第一次副作用之前**具名停下。
#
# 由来是 exact-head CI 33235374627: doctor 新增的 check_mosdns_binary 会在
# /usr/local/bin/mosdns 缺失时判 fail, 而 cmd_update 的自检门在**更新做完之后**才跑
# doctor —— 于是一次普通 update 先建快照、reset、装文件、跑迁移、重启服务, 走完全程,
# 最后被自检判红, 再整个回滚。机器动了一遍又退回来, 结果只是回到起点; 而每跑一次都
# 重复一遍。五支 E2E 就是这么红的。
#
# doctor 那条判据是对的(mosdns 是核心运行文件, 缺失或摘要不符是确定性故障, 不是"无结论"),
# 该改的是**问的时机**: 更新前就问一次, 不合法就停在动手之前。
#
# 判据用生产共用的那一份 —— lib/versions.sh 的 pdg_mosdns_binary_ok, 与 install.sh
# 的严格短路同一个函数。不在这里另立一套。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-mospre.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
command -v git >/dev/null 2>&1 || { echo "[SKIP] 无 git"; exit 0; }
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"

sed -n '/^cmd_update(){/,/^}/p'                   "$ROOT/deploy/bot/pdg.sh" >  "$WORK/upd.sh"
sed -n '/^_update_release_relation(){/,/^}/p'     "$ROOT/deploy/bot/pdg.sh" >> "$WORK/upd.sh"
# 预检的依赖来源现在由 _pdg_entry_libdir 回答(它又用 _pdg_entry_src)。两个都要抽**产品原文**
# 进来 —— 不给的话它们在这个外壳里是 command not found, 预检会一律走"入口副本核不过"那条
# 退出码 12, 每一格都变成红的, 而红的原因与被测判据无关。
# 这个外壳是 `source "$WORK/pre.sh"` 跑的, BASH_SOURCE 不是 <root>/deploy/bot/pdg.sh,
# 所以 _pdg_entry_libdir 会如实答"这不是入口副本" ⇒ 照旧用 $REPO_DIR —— 下面这些既有
# 场景验的正是**现役已安装 CLI** 那条路径。入口副本那条路径由第九节单独驱动。
grep -m1 '^_PDG_INSTALLED_CLI=' "$ROOT/deploy/bot/pdg.sh"                          >  "$WORK/pre.sh"
sed -n '/^_pdg_entry_src(){/,/^}/p'               "$ROOT/deploy/bot/pdg.sh" >> "$WORK/pre.sh"
sed -n '/^_pdg_entry_libdir(){/,/^}/p'            "$ROOT/deploy/bot/pdg.sh" >> "$WORK/pre.sh"
sed -n '/^_update_mosdns_preflight(){/,/^}/p'     "$ROOT/deploy/bot/pdg.sh" >> "$WORK/pre.sh"
# 〔模型〕下面 1–8 节验的是**现役已安装 CLI** 那条路径。这个外壳是 `source "$WORK/pre.sh"`
# 跑的, 脚本落点既不是 <root>/deploy/bot/pdg.sh 也不是装机那个路径, 按产品的分类就是
# "说不清" —— 那是对的, 不能靠"反正不在 deploy/bot 里"去冒充已安装 CLI。
# 所以这里**显式**给一个来源查询替身, 并如实登记它是模型: 它只替换"我是谁"这一问,
# _pdg_entry_libdir 的分类逻辑与预检本体仍是产品原文。真实来源分类由第九节 E8a/E8b
# (源码级直证)与 E11(无替身的未知来源)负责, 不靠这个替身。
printf '_pdg_entry_src(){ echo "%s"; }\n' \
  "$(grep -m1 '^_PDG_INSTALLED_CLI=' "$ROOT/deploy/bot/pdg.sh" | cut -d'"' -f2)" >> "$WORK/pre.sh"

echo "══ 1. 预检函数存在, 且用的是生产共用判据 ══"
if [[ -s "$WORK/pre.sh" ]]; then ok "pdg.sh 里有 _update_mosdns_preflight"; else
  bad "pdg.sh 里没有 _update_mosdns_preflight —— 更新前没有这一问"; fi
# 必须是**真调用**, 不能是注释里提一句。裸 grep 在这里是假绿: 本轮重排预检时我在注释里
# 写了 "判据本体(pdg_mosdns_binary_ok)…", 裸 grep 照样变绿, 而那一版实际上把判据内联了 ——
# 单一真源已经断了, 断言却没说话。判据不该看注释。
grep -qE '^[^#]*pdg_mosdns_binary_ok ' "$WORK/pre.sh" 2>/dev/null \
  && ok "预检的裁决**真的调用**了 pdg_mosdns_binary_ok(与 install.sh 同一份判据)" \
  || bad "预检没走生产共用判据(注释里提到不算)—— 另立一套迟早与安装器/doctor 漂开"
# 注释里提一句不算 —— 要的是**真的 source 语句**。
grep -qE '^[^#]*source "\$_libdir/versions\.sh"' "$WORK/pre.sh" 2>/dev/null \
  && ok "钉值从配套的 lib/versions.sh 读(单一真源; 来源由 _pdg_entry_libdir 回答)" \
  || bad "预检没读配套的 lib/versions.sh"

echo
echo "══ 2. 预检在**真实调用顺序**里位于第一次副作用之前 ══"
# 只测一个孤立 helper 是不够的 —— 要证明的是它在 cmd_update 里被调用的位置。
posn(){ grep -n "$1" "$WORK/upd.sh" 2>/dev/null | head -1 | cut -d: -f1; }
P_PRE="$(posn '_update_mosdns_preflight')"
P_SNAP="$(posn '更新前留快照')"
P_RESET="$(posn 'reset --hard -q')"
P_INST="$(posn 'pdg_install_runtime_modules')"
P_MIG="$(posn 'bash /usr/local/bin/pdg __migrate')"
P_SVC="$(posn 'systemctl daemon-reload')"
if [[ -n "$P_PRE" ]]; then
  ok "cmd_update 里调用了预检(第 $P_PRE 行)"
  for pair in "快照:$P_SNAP" "reset:$P_RESET" "装文件:$P_INST" "迁移:$P_MIG" "服务:$P_SVC"; do
    nm="${pair%%:*}"; ln="${pair#*:}"
    if [[ -n "$ln" && "$P_PRE" -lt "$ln" ]]; then ok "预检在「$nm」之前($P_PRE < $ln)"
    else bad "预检不在「$nm」之前(预检 $P_PRE, $nm $ln)"; fi
  done
else
  bad "cmd_update 里根本没调用预检 —— 位置无从谈起"
fi

echo
echo "══ 3A. 四类不合法状态: 直接问预检(路径由参数注入, 生产调用点不传参)══"
# 沙箱里改不动 /usr/local/bin/mosdns(要 root), 所以四种形态用参数注入。
# **裁决逻辑一个字没变** —— 变的只是被问的是哪个文件。
BIN="$WORK/bin"; mkdir -p "$BIN"
mkmosdns(){ printf '#!/bin/sh\ncase "$1" in version) echo "mosdns %s-0-gabc";; esac\nexit 0\n' "$1" > "$2"; chmod 755 "$2"; }
mkmosdns v9.9.9 "$WORK/mosdns.good"
GOOD_SHA="$(sha256sum "$WORK/mosdns.good" | cut -d' ' -f1)"

mkvers(){        # $1=目标目录; 造一份只认 $GOOD_SHA 的 versions.sh(结构与生产同形)
  mkdir -p "$1/lib"
  cat > "$1/lib/versions.sh" <<V
MOSDNS_VER="v9.9.9"
declare -A PDG_SHA256=( [mosdns-bin-amd64]="$GOOD_SHA" [mosdns-bin-arm64]="$GOOD_SHA" )
V
  # 判据本体从**真的那份**取, 不在测试里另写一遍 —— 否则测的是我抄得对不对
  sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p' "$ROOT/lib/versions.sh" >> "$1/lib/versions.sh"
}
mkvers "$WORK/vrepo"

ask(){           # $1=二进制路径 → "rc|输出"
  local rc=0 out
  out=$(REPO_DIR="$WORK/vrepo" bash -c "
    c_y(){ echo \"\$*\"; }
    c_g(){ echo \"\$*\"; }
    REPO_DIR='$WORK/vrepo'
    source '$WORK/pre.sh'
    _update_mosdns_preflight '$1'" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}
cp "$WORK/mosdns.good" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); [[ "${r%%|*}" == 0 ]] \
  && ok "合法(版本对 + 摘要对)→ 预检放行" || bad "合法却被拒: ${r#*|}"

declare -A CASE=(
  ["文件不存在"]='rm -f "$BIN/mosdns"'
  ["执行不了"]='cp "$WORK/mosdns.good" "$BIN/mosdns"; chmod 644 "$BIN/mosdns"'
  ["摘要不符"]='mkmosdns v9.9.9 "$BIN/mosdns"; printf "\n# tampered\n" >> "$BIN/mosdns"'
)
declare -A WANT=(
  ["文件不存在"]='不存在'  ["执行不了"]='执行不了'  ["摘要不符"]='摘要不符'
)
for k in "文件不存在" "执行不了" "摘要不符"; do
  eval "${CASE[$k]}"
  r=$(ask "$BIN/mosdns"); rc="${r%%|*}"; out="${r#*|}"
  [[ "$rc" != 0 ]] && ok "[$k] 预检拒绝(rc=$rc)" || bad "[$k] 预检竟然放行"
  grep -q "${WANT[$k]}" <<<"$out" && ok "[$k] 原因具名: ${WANT[$k]}" \
    || bad "[$k] 原因不具名(期望含 ${WANT[$k]}): $(tr '\n' ' ' <<<"$out" | cut -c1-120)"
  grep -q 'mosdns' <<<"$out" && ok "[$k] 点名了是 mosdns" || bad "[$k] 没点名组件"
done
echo
echo "══ 3A-bis. 摘要没过就不执行, 也不靠自报版本洗白 ══"
# **契约本轮反转了。** v1.11.9 那版是: 自报版本与钉值不符 → 当成"这次更新会顺手修好的版本
# 漂移", 放行。撤掉它的两个理由:
#   ① 要读到自报版本, 就得先**执行**那个文件 —— 而"要不要信这个文件"正是当时还没回答的问题;
#   ② 自报版本是文件自己说的。被替换过的二进制想说什么版本就说什么版本, 于是这条放行通道
#      对真正需要拦住的那类文件恰好是敞开的。
# 代价有意接受: 手工换过内核的机器不再被例行 update 自动抹平, 用户要先恢复可信内核。
# 行为层面的证据(marker 证明它真的没被执行)在 tests/test-update-preflight-no-exec.sh。
mkmosdns v1.2.3 "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "[摘要不符 + 自报别的版本] 拒绝(rc=$rc) —— 未知内容不靠自报版本洗白" \
  || bad "[摘要不符 + 自报别的版本] 竟然放行(rc=0)"
grep -q '摘要不符' <<<"$out" && ok "[摘要不符 + 自报别的版本] 原因归到摘要, 不是版本" \
  || bad "[摘要不符 + 自报别的版本] 原因不具名: $(tr '\n' ' ' <<<"$out" | cut -c1-120)"
grep -q '收敛' <<<"$out" && bad "[摘要不符 + 自报别的版本] 仍在说「会收敛到钉死版」—— 那是旧放行的措辞" \
  || ok "[摘要不符 + 自报别的版本] 不再把不可信内容说成版本漂移"
grep -qE '恢复可信内核|rollback' <<<"$out" && ok "[摘要不符] 给了出路(先恢复可信内核)" \
  || bad "[摘要不符] 只说不行, 没说怎么办: $(tr '\n' ' ' <<<"$out" | cut -c1-120)"
# 版本对得上、内容不符 —— 同样拒绝(这一格从来就该拒绝, 反转前后都是)
mkmosdns v9.9.9 "$BIN/mosdns"; printf "\n# tampered\n" >> "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); rc="${r%%|*}"
[[ "$rc" != 0 ]] && ok "[摘要不符 + 自报正确版本] 仍然拒绝(rc=$rc)" \
  || bad "[摘要不符 + 自报正确版本] 竟然放行 —— 篡改形态不该被例行更新覆盖"

echo
echo "══ 3A-ter. 摘要对得上之后, version 那一层照常判 ══"
# 这几格必须**先把钉值对上**才走得到 —— 新顺序下内容不符会在更早一步就停。
{ echo '#!/bin/sh'; echo 'exit 3'; } > "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
mkdir -p "$WORK/v_rc3/lib"
{ printf 'MOSDNS_VER="v9.9.9"\n'
  printf 'declare -A PDG_SHA256=( [mosdns-bin-amd64]="%s" [mosdns-bin-arm64]="%s" )\n' \
    "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)" "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)"
  sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p' "$ROOT/lib/versions.sh"; } > "$WORK/v_rc3/lib/versions.sh"
r=$(REPO_DIR="$WORK/v_rc3" bash -c "c_y(){ echo \"\$*\"; }; c_g(){ echo \"\$*\"; }; REPO_DIR='$WORK/v_rc3'; source '$WORK/pre.sh'; _update_mosdns_preflight '$BIN/mosdns'" 2>&1; echo "rc=$?")
grep -q 'rc=1' <<<"$r" && ok "[摘要对 + version 非零] 拒绝" || bad "[摘要对 + version 非零] 放行了: $r"
grep -qE '命令非零' <<<"$r" && ok "[摘要对 + version 非零] 原因具名到 version 命令" \
  || bad "[摘要对 + version 非零] 原因不具名: $(tr '\n' ' ' <<<"$r" | cut -c1-120)"

echo
# 读不到 versions.sh / 架构无钉值 → 一样拒绝(fail-closed)
cp "$WORK/mosdns.good" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(REPO_DIR="$WORK/nosuch" bash -c "c_y(){ echo \"\$*\"; }; c_g(){ echo \"\$*\"; }; REPO_DIR='$WORK/nosuch'; source '$WORK/pre.sh'; _update_mosdns_preflight '$BIN/mosdns'" 2>&1; echo "rc=$?")
grep -q 'rc=1' <<<"$r" && ok "读不到 versions.sh → 拒绝(fail-closed, 不在存疑时动手)" \
  || bad "读不到 versions.sh 却放行了: $r"

echo
echo "══ 3B. 真跑 cmd_update: 预检不合法时零副作用 ══"
# 这一层不注入路径 —— 走的是生产那条写死的 /usr/local/bin/mosdns。
# 让它"不合法"的办法不是动那个文件(沙箱里动不了), 而是让仓库的钉值与它对不上:
# 判据两边都要对得上才算合法, 改哪一边效果一样, 而改钉值不需要 root。
REALBIN=/usr/local/bin/mosdns
if [[ ! -x "$REALBIN" ]]; then
  bash "$ROOT/tests/prepare-mosdns.sh" >/dev/null 2>&1 || true
fi
if [[ -x "$REALBIN" ]]; then ok "本机有 $REALBIN, 可以跑真实调用链那一层"
else bad "拿不到钉死版 mosdns —— 真实调用链那一层未验(不是通过)。备一份: bash tests/prepare-mosdns.sh"; fi

cat > "$WORK/harness.sh" <<'EOF'
REPO_DIR="$WORK/repo"; REPO_URL="file:///dev/null"; ENVF="$WORK/none.env"
need_root(){ :; }
_lock(){ :; }
c_g(){ echo "$*"; }
c_y(){ echo "$*"; }
sleep(){ :; }
_pdg_platform(){ echo android; }
_pdg_core(){ echo mihomo; }
_pdg_bot_cred(){ echo unset; }
pdg_fetch_release_tags(){ return 0; }
_update_in_sync(){ return 1; }
# ── 服务前像保存: **可控替身**, 不是恒真 ────────────────────────────────────
# 本壳的被测对象是更新编排/方向/预检/故障传播, 不是前像本身 —— 真实前像(systemctl show
# 那一套)属于真实 systemd 验收, 这里不冒充。
# 但**不能**拿 `return 0` 把这道门抹掉: cmd_update 的契约是"前像保存失败就中止更新",
# 那条判据必须还能被测到。所以替身做成: 默认成功, 写一份自有留痕文件(证明确实被调到、
# 参数是哪个快照目录); SVCSTATE_RC 非 0 时按该码失败。
_pdg_save_svcstate(){
  printf "SVCSTATE_SAVE %s rc=%s\\n" "${1:-<无参>}" "${SVCSTATE_RC:-0}" >> "$WORK/side.log"
  [[ -n "${1:-}" && -d "${1:-}" ]] && printf "modeled-svcstate\\n" > "$1/svcstate.tsv"
  return "${SVCSTATE_RC:-0}"
}
git(){ printf '%s
' "$*" >> "$WORK/git.log"; command git "$@"; }
install(){ printf 'install %s
' "$*" >> "$WORK/side.log"; return 0; }
bash(){ [[ "$*" == *__migrate* ]] && { echo migrate >> "$WORK/side.log"; return 0; }; command bash "$@"; }
_update_core_binary(){ echo core >> "$WORK/side.log"; return 0; }
_update_mosdns_binary(){ echo mosbin >> "$WORK/side.log"; return 0; }
systemctl(){ printf 'systemctl %s
' "$*" >> "$WORK/side.log"; return 0; }
python3(){ case "$*" in *py_compile*) return 0;;
  *doctor.py*) cat "$WORK/doctor.json";; *) command python3 "$@";; esac; }
mihomo(){ return 0; }
nft(){ return 0; }
# 本轮契约变化: 服务前像由 **cmd_snapshot** 保存并校验, cmd_update 只**确认**它可用。
# 所以这里的 cmd_snapshot 桩也得按新契约产出前像 —— 不产出的话 cmd_update 会在动手之前就中止,
# 后面所有断言都测不到。SVCSTATE_RC 非 0 时**桩自己也失败**(对应"前像存不下 ⇒ 快照失败")。
# _pdg_svcstate_plan 是 cmd_update 用来确认的那一步: 文件在且 PLAN_RC=0 才算可用。
_pdg_svcstate_plan(){ _PDG_SVC_WHY="注入: 前像不可用"; [[ -f "$1/svcstate.tsv" ]] && return "${PLAN_RC:-0}"; return 1; }
cmd_snapshot(){ echo SNAPSHOT >> "$WORK/side.log"
  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$_PDG_SNAP_CREATED"; : | gzip > "$_PDG_SNAP_CREATED/snap.tar.gz"
  _pdg_save_svcstate "$_PDG_SNAP_CREATED" || { _PDG_SNAP_CREATED=""; return 1; }
  return 0; }
cmd_rollback(){ echo "ROLLBACK $*" >> "$WORK/side.log"; return 0; }
EOF
export WORK
echo '[{"level":"ok","check":"服务","detail":"都在"}]' > "$WORK/doctor.json"

g(){ e2e_git "$1" "${@:2}"; }
mkrepo(){                       # HEAD 落后一个 tag → behind → 走真实更新
  local r="$1" pin="$2"         # pin=real → 用仓库真钉值; pin=bogus → 故意对不上
  rm -rf "$r"; mkdir -p "$r/lib"
  command git -C "$r" init -q -b main
  g "$r" config user.email t@t; g "$r" config user.name t; g "$r" config commit.gpgsign false
  printf 'pdg_install_runtime_modules(){ return 0; }\n' > "$r/lib/modules.sh"
  cp "$ROOT/lib/versions.sh" "$r/lib/versions.sh"
  if [[ "$pin" == bogus ]]; then
    sed -i 's/\[mosdns-bin-amd64\]="./[mosdns-bin-amd64]="0/; s/\[mosdns-bin-arm64\]="./[mosdns-bin-arm64]="0/' "$r/lib/versions.sh"
  fi
  echo A > "$r/f"; g "$r" add -A; g "$r" commit -qm A
  g "$r" tag -a v1.0.0 -m v1.0.0
  echo B > "$r/f"; g "$r" add -A; g "$r" commit -qm B
  g "$r" tag -a v2.0.0 -m v2.0.0
  g "$r" checkout -q -b side v1.0.0
  echo D > "$r/f"; g "$r" add -A; g "$r" commit -qm D
  g "$r" checkout -q v1.0.0
}
side(){ grep -qF "$1" "$WORK/side.log" 2>/dev/null; }
did_reset(){ grep -qE '(^| )reset ' "$WORK/git.log" 2>/dev/null; }
HEAD_OF(){ command git -C "$WORK/repo" rev-parse HEAD 2>/dev/null; }
run(){                          # $1=real|bogus [$2=--dry-run] → "rc|输出"; h0 存进 $H0
  mkrepo "$WORK/repo" "$1" >/dev/null 2>&1
  HEAD_OF > "$WORK/head0"          # $(run …) 是子 shell, 变量回不来, 前像只能落盘
  : > "$WORK/side.log"; : > "$WORK/git.log"
  local rc=0 out
  out=$(bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update ${2:-}" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}
nofx(){
  local tag="$1"
  side SNAPSHOT   && bad "$tag: 建了快照" || ok "$tag: 快照数不变"
  did_reset       && bad "$tag: 执行了 reset" || ok "$tag: 未 reset"
  [[ "$(HEAD_OF)" == "$(cat "$WORK/head0" 2>/dev/null)" ]] \
    && ok "$tag: git HEAD 与工作区逐字节不变" || bad "$tag: HEAD 变了"
  side "install " && bad "$tag: 装了文件" || ok "$tag: 已装文件摘要不变"
  side migrate    && bad "$tag: 调了 __migrate" || ok "$tag: __migrate 未调用"
  side systemctl  && bad "$tag: 碰了 systemctl" || ok "$tag: 服务未动(InvocationID 不变)"
  side ROLLBACK   && bad "$tag: 进了 rollback" || ok "$tag: rollback 计数 0"
}

if [[ -x "$REALBIN" ]]; then
  r=$(run real); rc="${r%%|*}"; out="${r#*|}"
  did_reset && ok "钉值与真实二进制相符 → 预检放行, 正常进入更新" \
    || bad "合法却被挡住: $(tail -3 <<<"$out")"
  [[ "$rc" == 0 ]] && ok "合法路径 rc=0" || bad "合法路径 rc=$rc: $(tail -3 <<<"$out")"
fi
r=$(run bogus); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "钉值对不上 → rc 非 0(实得 $rc)" || bad "钉值对不上却 rc=0"
grep -q 'mosdns' <<<"$out" && ok "具名指出是 mosdns" || bad "没点名: $(tail -2 <<<"$out")"
grep -q '✅ 已更新' <<<"$out" && bad "冒充已更新" || ok "没冒充已更新"
nofx "预检拒绝"

echo "══ 4. 关系门优先于预检: ahead/diverged 仍由关系门拒绝 ══"
for spec in "ahead:main:领先" "diverged:side:分叉"; do
  IFS=: read -r nm ref kw <<<"$spec"
  mkrepo "$WORK/repo" bogus >/dev/null 2>&1
  g "$WORK/repo" tag -d v2.0.0 >/dev/null 2>&1
  g "$WORK/repo" checkout -q "$ref" 2>/dev/null
  [[ "$nm" == diverged ]] && g "$WORK/repo" tag -a v2.0.0 -m x main >/dev/null 2>&1
  # 仓库钉值同时也是坏的 → mosdns 预检也过不了。看谁先说话。
  : > "$WORK/side.log"; : > "$WORK/git.log"
  out=$(bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1); rc=$?
  { [[ "$rc" != 0 ]] && grep -q "$kw" <<<"$out"; } \
    && ok "$nm: 仍由关系门先拒绝(不是被预检抢答)" \
    || bad "$nm: 关系门没有优先(rc=$rc): $(tail -2 <<<"$out")"
done

echo
echo "══ 5. dry-run 契约不变: 零副作用, 不受预检影响 ══"
r=$(run bogus --dry-run); rc="${r%%|*}"; out="${r#*|}"
grep -q '待更新提交' <<<"$out" && ok "dry-run 照旧列出待更新提交(不被预检打断)" \
  || bad "dry-run 被预检改了行为: $out"
nofx "dry-run"

echo
echo "══ 6. 更新前合法、更新过程把它破坏 → 更新后 doctor 仍判红并回滚 ══"
# 这条安全门不得因为加了前置预检就放松。
echo '[{"level":"fail","check":"mosdns 二进制","detail":"内容与官方钉值不一致"}]' > "$WORK/doctor.json"
if [[ -x "$REALBIN" ]]; then
r=$(run real); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "更新后自检判红 → rc 非 0" || bad "更新后判红却 rc=0"
side ROLLBACK && ok "触发了既有回滚(安全门没被放松)" || bad "没回滚: $(tail -3 <<<"$out")"
grep -q '✅ 已更新' <<<"$out" && bad "谎报成功" || ok "没谎报成功"
fi
echo '[{"level":"ok","check":"服务","detail":"都在"}]' > "$WORK/doctor.json"

echo
echo "══ N. 接线自检: 前像保存这道门没有被替身抹掉 ══"
# 同 test-update-release-relation.sh 的 N 节: 本轮补的 _pdg_save_svcstate 是**可控**替身,
# 这里把它喂失败, 确认 cmd_update 仍会中止 —— 替身不是恒真。
mkrepo "$WORK/repo" real >/dev/null 2>&1
: > "$WORK/side.log"; : > "$WORK/git.log"
_nrc=0
_nout=$(SVCSTATE_RC=1 bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1) || _nrc=$?
{ [[ "$_nrc" != 0 ]] && grep -q '快照失败' <<<"$_nout"; } \
  && ok "N1: 前像存不下 ⇒ 快照创建失败 ⇒ 中止更新(rc=$_nrc)" || bad "N1: 没挡住(rc=$_nrc): $(tail -2 <<<"$_nout")"
grep -qE '(^| )reset ' "$WORK/git.log" && bad "N2: 前像存不下却仍然 reset 了" || ok "N2: 且**没有** reset"
: > "$WORK/git.log"; _n2rc=0
_n2out=$(PLAN_RC=1 bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1) || _n2rc=$?
{ [[ "$_n2rc" != 0 ]] && grep -q '服务前像不可用' <<<"$_n2out"; } \
  && ok "N3: 前像**校验**不过 ⇒ 动手之前中止(rc=$_n2rc)" || bad "N3: 没挡住(rc=$_n2rc): $(tail -2 <<<"$_n2out")"
grep -qE '(^| )reset ' "$WORK/git.log" && bad "N4: 校验不过却仍然 reset 了" || ok "N4: 且**没有** reset"


echo
echo "══ 九. 入口副本: 预检用**与自己同源**的依赖, 不拿受管库里那份旧的凑合 ══"
# 跨版本升级时(docs/BRIDGE-ENTRY.md)入口副本是新的、现役受管仓库还是旧的。这一节把这两棵
# 树分开摆, 逐条验"依赖到底从哪来"。被更新的对象**始终**是 REPO_DIR —— 这里只换判据自己的库。
mkentry(){   # $1=副本根; 造一份完整入口副本(deploy/bot/pdg.sh + 只认 GOOD_SHA 的 lib)
  local e="$1"; mkdir -p "$e/deploy/bot"
  cp "$ROOT/deploy/bot/pdg.sh" "$e/deploy/bot/pdg.sh"
  mkvers "$e"
  # 这里建的是**本支自有的新目录**里的一个独立仓库。`git init` 留在守卫之外是有理由的:
  # e2e_guard_repo 第一句就要求"这个目录已经是 git 仓库", 把 init 塞进去等于要求它先有再建
  # (扫描器自己也把 init/clone 列为不受限, 见 tests/test-e2e-repo-guard.py 的说明)。
  # init 之后每一次会动 ref/config 的调用都**显式传目标目录**走 e2e_git —— 守卫与动作绑成
  # 一件事, 这正是 2026-07-31 丢 56 个 tag 之后立的那道门。提交身份参数原样保留。
  git -C "$e" init -q || return 1
  e2e_git "$e" add -A >/dev/null || return 1
  e2e_git "$e" -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
          commit -qm entry >/dev/null || return 1
}
mkold(){     # $1=受管库根; 造一份**旧**库: 没有 pdg_mosdns_binary_ok, 键名也是旧的
  mkdir -p "$1/lib"
  { echo 'MOSDNS_VER="v5.3.4"'
    echo 'declare -A PDG_SHA256=( [mosdns-amd64]="deadbeef" [mosdns-arm64]="deadbeef" )'; } > "$1/lib/versions.sh"
}
# 从入口副本里**按它自己的路径**跑预检, 这样 BASH_SOURCE 才指向 <root>/deploy/bot/
runentry(){  # $1=副本根 $2=受管库根 $3=二进制 [$4=来源查询替身(模型)] → 打印输出与 rc
  local e="$1" r="$2" b="$3"
  { echo 'set -uo pipefail'
    echo "REPO_DIR=\"$r\""
    echo 'c_y(){ echo "$*"; }; c_g(){ echo "$*"; }; c_r(){ echo "$*"; }'
    grep -m1 '^_PDG_INSTALLED_CLI=' "$e/deploy/bot/pdg.sh"
    sed -n '/^_pdg_entry_src(){/,/^}/p'           "$e/deploy/bot/pdg.sh"
    sed -n '/^_pdg_entry_libdir(){/,/^}/p'        "$e/deploy/bot/pdg.sh"
    sed -n '/^_update_mosdns_preflight(){/,/^}/p' "$e/deploy/bot/pdg.sh"
    [[ -n "${4:-}" ]] && echo "$4"          # 可选: 来源查询**替身**(模型), 排在真函数之后
    echo 'L="$(_pdg_entry_libdir)"; echo "helper_rc=$?  libdir=${L:-<无>}"'
    echo "_update_mosdns_preflight '$b'; echo \"rc=\$?\""
  } > "$e/deploy/bot/probe.sh"
  bash "$e/deploy/bot/probe.sh" 2>&1
}
E1="$WORK/e1"; mkentry "$E1"; OLD1="$WORK/old1"; mkold "$OLD1"
r="$(runentry "$E1" "$OLD1" "$WORK/mosdns.good")"
grep -q '^rc=0' <<<"$r" \
  && ok "E1: 入口副本 + **旧受管库** ⇒ 合法二进制通过(用的是副本自己的钉值表与判据)" \
  || bad "E1: 合法二进制没通过 —— $(grep -v '^$' <<<"$r" | head -3 | tr '\n' ' ')"
grep -qE 'command not found|钉值表里没有条目' <<<"$r" \
  && bad "E1: 旧库还是被拿去当依赖了(缺符号/旧键名的迹象还在)" \
  || ok "E1: 旧库**没有**提前覆盖 —— 没有出现缺符号或旧键名那两种迹象"
# 反向对照: 同一副本, 把它自己的 lib 挪走 ⇒ 必须具名拒绝, **不**回退到受管库
E2="$WORK/e2"; mkentry "$E2"; OK2="$WORK/ok2"; mkvers "$OK2"   # 受管库这次是"能用"的
mv "$E2/lib/versions.sh" "$E2/lib/versions.sh.bak"
r="$(runentry "$E2" "$OK2" "$WORK/mosdns.good")"
{ ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E2: 副本自己的 lib 取不到 ⇒ 拒绝, **没有**改用受管库里那份能用的(不做隐式兜底)" \
  || bad "E2: 回退到受管库并放行了 —— 这正是要消除的隐式兜底"
grep -q '入口副本' <<<"$r" && ok "E2: 拒绝理由具名(点明是入口副本的库出了问题)" || bad "E2: 理由没具名: $(head -3 <<<"$r" | tr '\n' ' ')"
# 身份核不过(文件被改动过)⇒ 同样拒绝
E3="$WORK/e3"; mkentry "$E3"; printf '\n# tampered\n' >> "$E3/lib/versions.sh"
r="$(runentry "$E3" "$OK2" "$WORK/mosdns.good")"
{ ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E3: 副本的 lib 被改动过(身份核不过)⇒ 拒绝, 不放行" || bad "E3: 改动过的库照样放行了"
# 二进制侧的三类: 缺失 / 损坏 / 来源不可确认 —— 都要具名拒绝
E4="$WORK/e4"; mkentry "$E4"
r="$(runentry "$E4" "$OLD1" "$WORK/nosuch-mosdns")"
grep -q '不存在' <<<"$r" && ok "E4: 二进制缺失 ⇒ 具名拒绝" || bad "E4: 缺失没具名: $(head -3 <<<"$r" | tr '\n' ' ')"
cp "$WORK/mosdns.good" "$WORK/mosdns.bad"; printf '# tampered\n' >> "$WORK/mosdns.bad"; chmod 755 "$WORK/mosdns.bad"
r="$(runentry "$E4" "$OLD1" "$WORK/mosdns.bad")"
grep -q 'SHA256 摘要不符' <<<"$r" && ok "E5: 二进制内容不符 ⇒ 具名拒绝(按不可信内容处理)" || bad "E5: 损坏没具名"
mkdir -p "$WORK/asdir"
r="$(runentry "$E4" "$OLD1" "$WORK/asdir")"
grep -q '不是普通文件' <<<"$r" && ok "E6: 来源形态不可确认(目录/设备)⇒ 具名拒绝" || bad "E6: 形态异常没具名"
# 顺序契约: 摘要没过之前**一次都不执行**那个二进制
MARK="$WORK/exec.mark"; rm -f "$MARK"
printf '#!/bin/sh\ntouch "%s"\ncase "$1" in version) echo "mosdns v9.9.9-0-gabc";; esac\nexit 0\n' "$MARK" > "$WORK/mosdns.trap"
chmod 755 "$WORK/mosdns.trap"
r="$(runentry "$E4" "$OLD1" "$WORK/mosdns.trap")"
{ ! grep -q '^rc=0' <<<"$r" && [[ ! -e "$MARK" ]]; } \
  && ok "E7: 摘要不符时**一次都没执行**那个二进制(先验摘要再读版本的顺序没被动)" \
  || bad "E7: 摘要没过却执行了它(标记文件: $([[ -e "$MARK" ]] && echo 出现 || echo 没有))"
# ── 已安装 CLI 这一格: 分两半验 ──────────────────────────────────────────
# (a) **真实来源分类**, 不打任何替身: 常量必须就是装机真正放 CLI 的那个路径。
#     沙箱里写不了 /usr/local/bin, 所以这一半是**源码级**直证, 与下面那半互补。
_inst="$(grep -m1 '^_PDG_INSTALLED_CLI=' "$ROOT/deploy/bot/pdg.sh" | cut -d'"' -f2)"
_real="$(grep -oE 'install -m755 "\$REPO_DIR"/deploy/bot/pdg\.sh +[^ ]+' "$ROOT/deploy/bot/pdg.sh" | awk '{print $NF}' | head -1 | tr -d ';\\')"
{ [[ -n "$_inst" && "$_inst" == "$_real" ]]; } \
  && ok "E8a: 「算已安装 CLI」的那个常量($_inst)就是装机真正装到的路径 —— 分类不是凭空定的" \
  || bad "E8a: 常量「${_inst:-<没取到>}」与装机路径「${_real:-<没取到>}」对不上"
grep -qE '^_PDG_INSTALLED_CLI="[^$]*"$' "$ROOT/deploy/bot/pdg.sh" \
  && ok "E8b: 它是常量, **不接受环境覆盖**(不给依赖来源开后门)" \
  || bad "E8b: 这个路径可被环境改写"
# (b) 行为那一半用**来源查询替身**驱动 —— 这是**模型**, 明确登记: 它只替换"我是谁"这一问,
#     _pdg_entry_libdir 的分类逻辑与预检本体都是产品原文。
E9="$WORK/e9"; mkentry "$E9"
r="$(runentry "$E9" "$OK2" "$WORK/mosdns.good" '_pdg_entry_src(){ echo "/usr/local/bin/pdg"; }')"
{ grep -q 'helper_rc=1' <<<"$r" && grep -q '^rc=0' <<<"$r"; } \
  && ok "E8c〔模型: 来源查询替身〕已安装 CLI 形态 ⇒ 助手返回 1, 用 REPO_DIR, 正常预检不回归" \
  || bad "E8c: 已安装 CLI 这条路径回归了 —— $(head -4 <<<"$r" | tr '\n' ' ')"

# ── 说不清的来源一律不放行, 也不隐式回退 ──────────────────────────────────
# 受管库这次是**能用**的, 所以"回退了"会表现为 rc=0 —— 拒绝才是对的。
E10="$WORK/e10"; mkentry "$E10"
r="$(runentry "$E10" "$OK2" "$WORK/mosdns.good" '_pdg_entry_src(){ echo "(未知)"; }')"
{ grep -q 'helper_rc=2' <<<"$r" && ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E9〔模型: 来源查询替身〕来源答不出绝对路径 ⇒ 助手 2, 拒绝, **没有**回退到受管库" \
  || bad "E9: 来源说不清却放行了 —— $(head -4 <<<"$r" | tr '\n' ' ')"
r="$(runentry "$E10" "$OK2" "$WORK/mosdns.good" '_pdg_entry_src(){ return 3; }')"
{ grep -q 'helper_rc=2' <<<"$r" && ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E10〔模型: 来源查询替身〕来源**查询本身失败** ⇒ 助手 2, 拒绝, 不回退" \
  || bad "E10: 查询失败却放行了 —— $(head -4 <<<"$r" | tr '\n' ' ')"
# 未知来源: 不打替身, 真的把脚本放在一个既不是入口副本、也不是已安装 CLI 的地方
ODD="$WORK/odd/place"; mkdir -p "$ODD"; cp "$ROOT/deploy/bot/pdg.sh" "$ODD/pdg.sh"
{ echo 'set -uo pipefail'; echo "REPO_DIR=\"$OK2\""
  echo 'c_y(){ echo "$*"; }; c_g(){ echo "$*"; }; c_r(){ echo "$*"; }'
  grep -m1 '^_PDG_INSTALLED_CLI=' "$ODD/pdg.sh"
  sed -n '/^_pdg_entry_src(){/,/^}/p'           "$ODD/pdg.sh"
  sed -n '/^_pdg_entry_libdir(){/,/^}/p'        "$ODD/pdg.sh"
  sed -n '/^_update_mosdns_preflight(){/,/^}/p' "$ODD/pdg.sh"
  echo 'L="$(_pdg_entry_libdir)"; echo "helper_rc=$?"'
  echo "_update_mosdns_preflight '$WORK/mosdns.good'; echo \"rc=\$?\""; } > "$ODD/probe.sh"
r="$(bash "$ODD/probe.sh" 2>&1)"
{ grep -q 'helper_rc=2' <<<"$r" && ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E11: 未知来源(既不是入口副本也不是已安装 CLI, **无替身**)⇒ 助手 2, 拒绝, 不回退" \
  || bad "E11: 未知来源被当成已安装 CLI 放行了 —— $(head -4 <<<"$r" | tr '\n' ' ')"
# ── 身份查询本身失败: 输出为空 ≠ 没改过 ──────────────────────────────────
E12="$WORK/e12"; mkentry "$E12"; printf '\n# tampered\n' >> "$E12/lib/versions.sh"
GB="$WORK/gitbad"; mkdir -p "$GB"
printf '#!/bin/sh\ncase " $* " in *" status "*) exit 128;; esac\nexec /usr/bin/git "$@"\n' > "$GB/git"; chmod 755 "$GB/git"
r="$(PATH="$GB:$PATH" runentry "$E12" "$OK2" "$WORK/mosdns.good")"
{ grep -q 'helper_rc=2' <<<"$r" && ! grep -q '^rc=0' <<<"$r"; } \
  && ok "E12: git status **返回 128 且无输出** ⇒ 判为核不过(不拿「空输出」当「没改过」), 两份库都不加载" \
  || bad "E12: 查询失败却加载并放行了 —— $(head -4 <<<"$r" | tr '\n' ' ')"


echo "────────────────────────────────────────"
echo "test-update-mosdns-preflight.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

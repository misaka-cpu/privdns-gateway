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
sed -n '/^_update_mosdns_preflight(){/,/^}/p'     "$ROOT/deploy/bot/pdg.sh" >  "$WORK/pre.sh"

echo "══ 1. 预检函数存在, 且用的是生产共用判据 ══"
if [[ -s "$WORK/pre.sh" ]]; then ok "pdg.sh 里有 _update_mosdns_preflight"; else
  bad "pdg.sh 里没有 _update_mosdns_preflight —— 更新前没有这一问"; fi
# 必须是**真调用**, 不能是注释里提一句。裸 grep 在这里是假绿: 本轮重排预检时我在注释里
# 写了 "判据本体(pdg_mosdns_binary_ok)…", 裸 grep 照样变绿, 而那一版实际上把判据内联了 ——
# 单一真源已经断了, 断言却没说话。判据不该看注释。
grep -qE '^[^#]*pdg_mosdns_binary_ok ' "$WORK/pre.sh" 2>/dev/null \
  && ok "预检的裁决**真的调用**了 pdg_mosdns_binary_ok(与 install.sh 同一份判据)" \
  || bad "预检没走生产共用判据(注释里提到不算)—— 另立一套迟早与安装器/doctor 漂开"
grep -q 'lib/versions.sh' "$WORK/pre.sh" 2>/dev/null \
  && ok "钉值从 lib/versions.sh 读(单一真源)" || bad "预检没读 lib/versions.sh"

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
cmd_snapshot(){ echo SNAPSHOT >> "$WORK/side.log"
  _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$_PDG_SNAP_CREATED"; : | gzip > "$_PDG_SNAP_CREATED/snap.tar.gz"; return 0; }
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

echo "────────────────────────────────────────"
echo "test-update-mosdns-preflight.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

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
grep -q 'pdg_mosdns_binary_ok' "$WORK/pre.sh" 2>/dev/null \
  && ok "预检的裁决走 pdg_mosdns_binary_ok(与 install.sh 同一份判据)" \
  || bad "预检没走生产共用判据 —— 另立一套迟早与安装器/doctor 漂开"
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
echo "══ 3. 四类状态 × 真跑 cmd_update ══"
g(){ e2e_git "$1" "${@:2}"; }
mkrepo(){                       # HEAD 落后一个 tag → 关系判定为 behind, 走真实更新
  local r="$1"; rm -rf "$r"; mkdir -p "$r/lib"
  command git -C "$r" init -q -b main
  g "$r" config user.email t@t; g "$r" config user.name t; g "$r" config commit.gpgsign false
  printf 'pdg_install_runtime_modules(){ return 0; }\n' > "$r/lib/modules.sh"
  # 仓库自带一份 versions.sh: 预检要从它读钉值, 与 install.sh 同一个来源
  cat > "$r/lib/versions.sh" <<'V'
MOSDNS_VER="v9.9.9"
declare -A PDG_SHA256=( [mosdns-bin-amd64]="__SHA__" [mosdns-bin-arm64]="__SHA__" )
pdg_mosdns_binary_ok(){
  local arch="${1:-}" want="${2:-${MOSDNS_VER:-}}" bin="${3:-/usr/local/bin/mosdns}" got exp
  [[ -n "$arch" && -n "$want" && -x "$bin" ]] || return 1
  exp="${PDG_SHA256[mosdns-bin-$arch]:-}"; [[ -n "$exp" ]] || return 1
  got="$("$bin" version 2>/dev/null | head -1)" || return 1
  [[ "$got" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "${want#v}" ]] || return 1
  got="$(sha256sum "$bin" 2>/dev/null | awk '{print $1}')"
  [[ -n "$got" && "$got" == "$exp" ]]
}
V
  echo A > "$r/f"; g "$r" add -A; g "$r" commit -qm A
  g "$r" tag -a v1.0.0 -m v1.0.0
  echo B > "$r/f"; g "$r" add -A; g "$r" commit -qm B
  g "$r" tag -a v2.0.0 -m v2.0.0
  g "$r" checkout -q -b side v1.0.0
  echo D > "$r/f"; g "$r" add -A; g "$r" commit -qm D
  g "$r" checkout -q v1.0.0            # HEAD = v1.0.0, 最新 tag = v2.0.0 → behind
}

# 造一个"合法 mosdns": 自报 v9.9.9 的可执行文件, 钉值就取它自己的 sha256
BIN="$WORK/bin"; mkdir -p "$BIN"
mkmosdns(){                      # $1=version 串; 打印文件路径
  printf '#!/bin/sh\ncase "$1" in version) echo "mosdns %s-0-gabc";; esac\nexit 0\n' "$1" > "$BIN/mosdns"
  chmod 755 "$BIN/mosdns"; echo "$BIN/mosdns"
}
# 原件另存一份: $BIN/mosdns 每一格都会被改坏或删掉, 拿它当"合法原件"的话,
# 第二格之后就 cp 不出东西来了(第一版就是这么把 ①⑥ 两格测空的)。
mkmosdns v9.9.9 >/dev/null
GOOD="$WORK/mosdns.pristine"; cp "$BIN/mosdns" "$GOOD"; chmod 755 "$GOOD"
GOOD_SHA="$(sha256sum "$GOOD" | cut -d' ' -f1)"

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
dpkg(){ echo amd64; }
git(){ printf '%s\n' "$*" >> "$WORK/git.log"; command git "$@"; }
install(){ printf 'install %s\n' "$*" >> "$WORK/side.log"; return 0; }
bash(){ [[ "$*" == *__migrate* ]] && { echo migrate >> "$WORK/side.log"; return 0; }; command bash "$@"; }
_update_core_binary(){ echo core >> "$WORK/side.log"; return 0; }
systemctl(){ printf 'systemctl %s\n' "$*" >> "$WORK/side.log"; return 0; }
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

run(){                          # $1=mosdns 现场造法; 打印 "rc|输出"
  mkrepo "$WORK/repo" >/dev/null 2>&1
  sed -i "s/__SHA__/$GOOD_SHA/g" "$WORK/repo/lib/versions.sh"
  : > "$WORK/side.log"; : > "$WORK/git.log"
  eval "$1"
  local rc=0 out
  out=$(PATH="$BIN:$PATH" bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}
side(){ grep -qF "$1" "$WORK/side.log" 2>/dev/null; }
did_reset(){ grep -qE '(^| )reset ' "$WORK/git.log" 2>/dev/null; }
HEAD_OF(){ command git -C "$WORK/repo" rev-parse HEAD 2>/dev/null; }

nofx(){                          # 逐项零副作用
  local tag="$1" h0="$2"
  side SNAPSHOT   && bad "$tag: 建了快照" || ok "$tag: 快照数不变"
  did_reset       && bad "$tag: 执行了 reset" || ok "$tag: HEAD 未被 reset"
  [[ "$(HEAD_OF)" == "$h0" ]] && ok "$tag: git HEAD 逐字节不变" || bad "$tag: HEAD 变了"
  side "install " && bad "$tag: 装了文件" || ok "$tag: 已装文件未被触碰"
  side migrate    && bad "$tag: 调了 __migrate" || ok "$tag: __migrate 未调用"
  side systemctl  && bad "$tag: 碰了 systemctl" || ok "$tag: 服务未被动过(InvocationID 不变)"
  side ROLLBACK   && bad "$tag: 进了 rollback" || ok "$tag: rollback 计数 0"
}

# ① 合法 → 允许进入更新
r=$(run 'install -m755 "$GOOD" "$BIN/mosdns"'); rc="${r%%|*}"; out="${r#*|}"
did_reset && ok "① 合法 mosdns → 放行, 正常进入更新" || bad "① 合法却被挡住了: $(tail -3 <<<"$out")"
[[ "$rc" == 0 ]] && ok "① rc=0" || bad "① rc=$rc: $(tail -3 <<<"$out")"

# ②③④⑤ 四类不合法
for cell in \
  "② 文件不存在|rm -f \"\$BIN/mosdns\"|不存在|缺失" \
  "③ 版本命令非零|printf '#!/bin/sh\\nexit 3\\n' > \"\$BIN/mosdns\"; chmod 755 \"\$BIN/mosdns\"|执行不了|version 命令" \
  "④ 自报版本不符|mkmosdns v1.2.3 >/dev/null|版本|不符" \
  "⑤ SHA256 不符|mkmosdns v9.9.9 >/dev/null; printf '\\n# tampered\\n' >> \"\$BIN/mosdns\"|摘要|内容" \
; do
  IFS='|' read -r tag setup kw1 kw2 <<<"$cell"
  mkrepo "$WORK/repo" >/dev/null 2>&1
  h0="$(HEAD_OF)"
  r=$(run "$setup"); rc="${r%%|*}"; out="${r#*|}"
  echo "── $tag ──"
  [[ "$rc" != 0 ]] && ok "$tag: rc 非 0(实得 $rc)" || bad "$tag: 竟然 rc=0"
  grep -q 'mosdns' <<<"$out" && ok "$tag: 具名指出是 mosdns 的问题" || bad "$tag: 没说是 mosdns: $(tail -2 <<<"$out")"
  # 关键词必须出现在**提到 mosdns 的那一行**上。否则 "校验新版本…" 里的「版本」二字
  # 就能让 ③ 假绿 —— 那句话跟 mosdns 毫无关系(第一版就是这么绿的)。
  grep 'mosdns' <<<"$out" | grep -qE "$kw1|$kw2" && ok "$tag: 说清了是哪一类不合法" \
    || bad "$tag: 原因不具名(期望 mosdns 那一行含 $kw1/$kw2): $(tail -2 <<<"$out")"
  grep -q '✅ 已更新' <<<"$out" && bad "$tag: 冒充已更新" || ok "$tag: 没冒充已更新"
  nofx "$tag" "$h0"
done

echo
echo "══ 4. 关系门优先于预检: ahead/diverged 仍由关系门拒绝 ══"
for spec in "ahead:main:领先" "diverged:side:分叉"; do
  IFS=: read -r nm ref kw <<<"$spec"
  mkrepo "$WORK/repo" >/dev/null 2>&1
  command git -C "$WORK/repo" tag -d v2.0.0 >/dev/null 2>&1
  g "$WORK/repo" checkout -q "$ref" 2>/dev/null
  [[ "$nm" == diverged ]] && g "$WORK/repo" tag -a v2.0.0 -m x main >/dev/null 2>&1
  rm -f "$BIN/mosdns"                       # mosdns 同时也不合法 —— 看谁先说话
  : > "$WORK/side.log"; : > "$WORK/git.log"
  out=$(PATH="$BIN:$PATH" bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1); rc=$?
  { [[ "$rc" != 0 ]] && grep -q "$kw" <<<"$out"; } \
    && ok "$nm: 仍由关系门先拒绝(不是被预检抢答)" \
    || bad "$nm: 关系门没有优先(rc=$rc): $(tail -2 <<<"$out")"
done

echo
echo "══ 5. dry-run 契约不变: 零副作用, 不受预检影响 ══"
mkrepo "$WORK/repo" >/dev/null 2>&1
sed -i "s/__SHA__/$GOOD_SHA/g" "$WORK/repo/lib/versions.sh"
rm -f "$BIN/mosdns"                          # 故意不合法
h0="$(HEAD_OF)"; : > "$WORK/side.log"; : > "$WORK/git.log"
out=$(PATH="$BIN:$PATH" bash -c "source '$WORK/harness.sh'; source '$WORK/pre.sh'; source '$WORK/upd.sh'; cmd_update --dry-run" 2>&1); rc=$?
grep -q '待更新提交' <<<"$out" && ok "dry-run 照旧列出待更新提交(不被预检打断)" \
  || bad "dry-run 被预检改了行为: $out"
nofx "dry-run" "$h0"

echo
echo "══ 6. 更新前合法、更新过程把它破坏 → 更新后 doctor 仍判红并回滚 ══"
# 这条安全门不得因为加了前置预检就放松。
echo '[{"level":"fail","check":"mosdns 二进制","detail":"内容与官方钉值不一致"}]' > "$WORK/doctor.json"
r=$(run 'install -m755 "$GOOD" "$BIN/mosdns"'); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "更新后自检判红 → rc 非 0" || bad "更新后判红却 rc=0"
side ROLLBACK && ok "触发了既有回滚(安全门没被放松)" || bad "没回滚: $(tail -3 <<<"$out")"
grep -q '✅ 已更新' <<<"$out" && bad "谎报成功" || ok "没谎报成功"
echo '[{"level":"ok","check":"服务","detail":"都在"}]' > "$WORK/doctor.json"

echo "────────────────────────────────────────"
echo "test-update-mosdns-preflight.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

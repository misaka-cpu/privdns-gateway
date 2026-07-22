#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh 二进制安装事务回归(问题一/二/三/七)。
#
# 一、_stash_bin 备份失败被误判成功: cp -a 失败也 return 0, 调用方不检查 → 在没有
#     可回退原件的前提下继续覆盖别人的二进制。
# 二、install 半途失败时 *_INSTALLED 仍是 0 → rollback 跳过恢复, 留下半截二进制。
#     "装成功了吗"不能用来表示"这次碰过目标没有"。
# 三、PDG_FORCE_REINSTALL 分支直接 return, 本次生成的备份无人处理; 快照失败还继续覆盖。
# 七、rollback 的清理步骤失败未计入 failed, 仍显示"已回滚到安装前状态"。
#
# 手法: 抽出真实函数, 只把绝对路径字面量重定向到沙箱; 用真实 _stash_bin + 真实
# rollback 跑完整条路径, 中间用文件操作模拟 install 的各种结局(成功/截断/失败),
# 不碰测试机的 systemd / nftables / /usr/local/bin。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

xfn(){
  awk -v fn="$1" '
    index($0, fn "(){") == 1 { inf = 1 }
    inf { print; n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m; if (depth <= 0) exit }
  ' "$ROOT/install.sh"
}
: > "$WORK/fn.sh"
for f in _sha _stash_bin _restore_bin _rollback_bins _commit_bins rollback on_exit; do
  xfn "$f" >> "$WORK/fn.sh"
done
grep -q '^rollback(){' "$WORK/fn.sh" || { echo "抽取 rollback 失败"; exit 1; }
grep -qE 'apt-get|curl -fsSL' "$WORK/fn.sh" && { echo "抽取越界: 含安装流程指令"; exit 1; }
sed -i -e 's#/etc/#$SB/etc/#g' -e 's#/usr/local/bin/#$SB/usr/local/bin/#g' \
       -e 's#/opt/#$SB/opt/#g' "$WORK/fn.sh"

mk_sandbox(){
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/systemd/system" "$SB/usr/local/bin" "$SB/opt/pdg-bot" \
           "$SB/etc/mosdns" "$SB/etc/privdns-gateway"
  printf 'PDG-NEW\n'  > "$SB/etc/nftables.conf"
  printf 'ORIG-NFT\n' > "$SB/etc/nftables.conf.pdg-orig"
  printf 'PDG-NEW\n'  > "$SB/etc/resolv.conf"
  printf 'ORIG-RESOLV\n' > "$SB/etc/resolv.conf.pdg-orig"
  export SB
}
sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 桩: 无 systemd/netlink; cp/mktemp 可注入失败以模拟备份写不下去
harness(){ cat <<'EOF'
BIN_TXN=()
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
systemctl(){ echo "systemctl $*" >> "$SB/../calls.log"; return "${SYSTEMCTL_RC:-0}"; }
nft(){ echo "nft $*" >> "$SB/../calls.log"
       [[ "${1:-}" == list ]] && return "${NFT_LIST_RC:-0}"; return "${NFT_RC:-0}"; }
cp(){
  [[ -n "${CP_FAIL:-}" ]] && return 1
  if [[ -n "${CP_PARTIAL:-}" ]]; then printf 'PARTIAL' > "${@: -1}"; return 0; fi
  command cp "$@"
}
mktemp(){ [[ -n "${MKTEMP_FAIL:-}" ]] && return 1; command mktemp "$@"; }
mv(){ [[ -n "${MV_FAIL:-}" ]] && return 1; command mv "$@"; }
rm(){ [[ -n "${RM_FAIL:-}" ]] && return 1; command rm "$@"; }
EOF
}

# 在真实 set -u 下跑一段脚本(自带全部真身函数)
sh_run(){ # $1=env赋值串 $2=脚本体
  : > "$WORK/calls.log"
  # shellcheck disable=SC2086
  env SB="$SB" $1 bash -c "set -uo pipefail
$(harness)
source '$WORK/fn.sh'
$2" 2>&1
}

BIN="usr/local/bin/mosdns"     # 用 mosdns 做主用例, 后面三内核对称覆盖

# ══ 一、_stash_bin 备份失败必须非 0 且不得继续 ══════════════════════════════
# 1a. 原件存在 + cp 失败 → 非 0, 不留备份, 原件不动
mk_sandbox; printf 'OLD\n' > "$SB/$BIN"; OLD=$(sha "$SB/$BIN")
out=$(sh_run "CP_FAIL=1" "_stash_bin '$SB/$BIN'; echo rc=\$?")
{ grep -q 'rc=1' <<<"$out" && [[ ! -e "$SB/$BIN.pdg-preinstall" ]] && [[ "$(sha "$SB/$BIN")" == "$OLD" ]]; } \
  && ok "1a: 原件存在但 cp 失败 → _stash_bin 非0 + 不留备份 + 原件未动" \
  || bad "1a: out=$out backup=$([[ -e "$SB/$BIN.pdg-preinstall" ]] && echo yes || echo no)"

# 1b. 拷贝出半截文件(sha 对不上) → 非 0, 不得把半截当成完整原件落位
mk_sandbox; printf 'OLD-COMPLETE-CONTENT\n' > "$SB/$BIN"; OLD=$(sha "$SB/$BIN")
out=$(sh_run "CP_PARTIAL=1" "_stash_bin '$SB/$BIN'; echo rc=\$?")
{ grep -q 'rc=1' <<<"$out" && [[ ! -e "$SB/$BIN.pdg-preinstall" ]] && [[ "$(sha "$SB/$BIN")" == "$OLD" ]]; } \
  && ok "1b: 备份拷贝不完整(sha 不符) → 非0 + 不落位半截备份 + 原件未动" \
  || bad "1b: out=$out"

# 1c. 临时文件创建失败 → 非 0, 原件与已有备份均不变
mk_sandbox; printf 'OLD\n' > "$SB/$BIN"; OLD=$(sha "$SB/$BIN")
out=$(sh_run "MKTEMP_FAIL=1" "_stash_bin '$SB/$BIN'; echo rc=\$?")
{ grep -q 'rc=1' <<<"$out" && [[ "$(sha "$SB/$BIN")" == "$OLD" ]] && [[ ! -e "$SB/$BIN.pdg-preinstall" ]]; } \
  && ok "1c: 临时文件创建失败 → 非0 + 原件和备份均不变" || bad "1c: out=$out"

# 1d. 已存在来源不明的残留备份 → 拒绝覆盖它
mk_sandbox; printf 'CURRENT\n' > "$SB/$BIN"; printf 'STALE-FROM-LAST-RUN\n' > "$SB/$BIN.pdg-preinstall"
STALE=$(sha "$SB/$BIN.pdg-preinstall")
out=$(sh_run "" "_stash_bin '$SB/$BIN'; echo rc=\$?")
{ grep -q 'rc=1' <<<"$out" && [[ "$(sha "$SB/$BIN.pdg-preinstall")" == "$STALE" ]]; } \
  && ok "1d: 已有残留 .pdg-preinstall → 非0 且不被当前文件覆盖" || bad "1d: out=$out"

# 1g. 残留备份与当前文件**内容一致** → 认定是上次装成功后没清掉的, 自动清理并继续
mk_sandbox; printf 'SAME\n' > "$SB/$BIN"; printf 'SAME\n' > "$SB/$BIN.pdg-preinstall"
OLD=$(sha "$SB/$BIN")
out=$(sh_run "" "_stash_bin '$SB/$BIN'; echo rc=\$?")
{ grep -q 'rc=0' <<<"$out" && [[ "$(sha "$SB/$BIN")" == "$OLD" ]] && [[ -e "$SB/$BIN.pdg-preinstall" ]]; } \
  && ok "1g: 残留备份与当前文件一致 → 视为上次遗留, 清理后正常建账继续" \
  || bad "1g: out=$out"

# 1e. 目标不存在 → 返回 0 且不生成备份
mk_sandbox
out=$(sh_run "" "_stash_bin '$SB/usr/local/bin/absent'; echo rc=\$?")
{ grep -q 'rc=0' <<<"$out" && [[ ! -e "$SB/usr/local/bin/absent.pdg-preinstall" ]]; } \
  && ok "1e: 目标不存在 → 返回0 且不生成备份" || bad "1e: out=$out"

# 1f. 静态守卫: 三个安装点都必须 `_stash_bin ... ||` 中止(不能忽略返回值)
for b in mosdns sing-box mihomo; do
  if grep -qE "_stash_bin /usr/local/bin/$b( |\$).*\|\|" "$ROOT/install.sh" \
     || grep -A0 -E "_stash_bin /usr/local/bin/$b\b" "$ROOT/install.sh" | grep -q '||'; then
    ok "1f: $b 安装点检查了 _stash_bin 返回值"
  else bad "1f: $b 安装点未检查 _stash_bin 返回值(备份失败仍会覆盖)"; fi
done

# ══ 二、install 半途失败(状态未置1)也必须恢复 ══════════════════════════════
RB_STATE='INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0
SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0'

# 2a. 原件存在 → 备份成功 → install 把目标写成半截后失败 → 按 SHA 还原原件
for b in mosdns sing-box mihomo; do
  mk_sandbox; printf 'ORIGINAL-%s-v1\n' "$b" > "$SB/usr/local/bin/$b"
  OLD=$(sha "$SB/usr/local/bin/$b")
  out=$(sh_run "" "$RB_STATE
_stash_bin '$SB/usr/local/bin/$b' || exit 9
printf 'TRUNCA' > '$SB/usr/local/bin/$b'      # install 写了一半就失败
rollback")
  { [[ "$(sha "$SB/usr/local/bin/$b")" == "$OLD" ]] && [[ ! -e "$SB/usr/local/bin/$b.pdg-preinstall" ]]; } \
    && ok "2a($b): install 截断且状态未置1 → 旧二进制按 SHA 还原 + 无备份残留" \
    || bad "2a($b): 内容=$(cat "$SB/usr/local/bin/$b" 2>/dev/null) out=$out"
done

# 2b. 全新安装(装前不存在) → install 写半截后失败 → 半成品被删除
mk_sandbox
out=$(sh_run "" "$RB_STATE
_stash_bin '$SB/$BIN' || exit 9
printf 'HALF' > '$SB/$BIN'
rollback")
[[ ! -e "$SB/$BIN" ]] && ok "2b: 全新安装写半截后失败 → 半成品被删除" || bad "2b: 半成品残留=$(cat "$SB/$BIN")"

# 2c. 还原时 mv 失败 → 必须报未完全回滚, 不得假报成功
mk_sandbox; printf 'ORIGINAL\n' > "$SB/$BIN"
out=$(sh_run "" "$RB_STATE
_stash_bin '$SB/$BIN' || exit 9
printf 'NEW\n' > '$SB/$BIN'
MV_FAIL=1                                      # 只让还原那一步的 mv 失败
rollback; echo rb_rc=\$?")
{ grep -q '未能恢复' <<<"$out" && ! grep -q '已回滚到安装前状态' <<<"$out" && grep -q 'rb_rc=1' <<<"$out"; } \
  && ok "2c: 还原 mv 失败 → 报未完全回滚 + 非0(不假报成功)" || bad "2c: out=$out"

# ══ 三、PDG_FORCE_REINSTALL 也要恢复本次覆盖的二进制 ════════════════════════
# 3a. 强制重装分支: 三个二进制都按 SHA 还原, 且不残留备份
mk_sandbox
declare -A OLDS=()
for b in mosdns sing-box mihomo; do
  printf 'PREEXISTING-%s\n' "$b" > "$SB/usr/local/bin/$b"; OLDS[$b]=$(sha "$SB/usr/local/bin/$b")
done
out=$(sh_run "" "INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=1
for b in mosdns sing-box mihomo; do
  _stash_bin \"\$SB/usr/local/bin/\$b\" || exit 9
  printf 'OVERWRITTEN\n' > \"\$SB/usr/local/bin/\$b\"
done
rollback; echo rb_rc=\$?")
allok=1; leftover=0
for b in mosdns sing-box mihomo; do
  [[ "$(sha "$SB/usr/local/bin/$b")" == "${OLDS[$b]}" ]] || allok=0
  [[ -e "$SB/usr/local/bin/$b.pdg-preinstall" ]] && leftover=1
done
[[ "$allok" == 1 ]] && ok "3a: 强制重装失败 → 三个二进制均按 SHA 还原" || bad "3a: 未全部还原 out=$out"
[[ "$leftover" == 0 ]] && ok "3a: 强制重装失败后不残留 .pdg-preinstall" || bad "3a: 有备份残留"
grep -q 'pdg rollback' <<<"$out" && ok "3a: 二进制恢复后仍提示用 pdg rollback 恢复配置" || bad "3a: 缺配置恢复提示"

# 3b. 强制重装分支里配置回滚提示与二进制恢复互不阻断: mv 失败也要报出来
mk_sandbox; printf 'PRE\n' > "$SB/$BIN"
out=$(sh_run "" "INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=1
_stash_bin '$SB/$BIN' || exit 9
printf 'NEW\n' > '$SB/$BIN'
MV_FAIL=1
rollback; echo rb_rc=\$?")
{ grep -q 'rb_rc=1' <<<"$out" && grep -q 'pdg rollback' <<<"$out"; } \
  && ok "3b: 强制重装下二进制恢复失败 → 非0, 但配置恢复提示照给" || bad "3b: out=$out"

# 3c. 静态: 快照失败/pdg 不可用必须在覆盖任何文件前中止
# 先把反斜杠续行拼成一行再断言(install.sh 里 `|| die` 常写在下一行)
NORM="$(sed -e ':a' -e 'N;$!ba' -e 's/\\\n[[:space:]]*/ /g' "$ROOT/install.sh")"
grep -qE 'pdg snapshot[^|]*\|\|[[:space:]]*die' <<<"$NORM" \
  && ok "3c: 覆盖重装前快照失败 → die 中止(不再仅警告后继续)" || bad "3c: 快照失败仍继续覆盖"
grep -qE 'command -v pdg [^|]*\|\|[[:space:]]*die' <<<"$NORM" \
  && ok "3c: pdg 命令不可用 → 覆盖前中止" || bad "3c: 未检查 pdg 可用性"

# ══ 七、rollback 清理步骤失败必须计入 failed ════════════════════════════════
seed_units(){ for u in pdg-bot mosdns sing-box; do printf 'unit\n' > "$SB/etc/systemd/system/$u.service"; done; }

# 7a. systemctl disable 失败 → 计入 failed, 但后续系统级还原仍完成
mk_sandbox; seed_units
out=$(sh_run "SYSTEMCTL_RC=1" "$RB_STATE
rollback; echo rb_rc=\$?")
{ grep -q '未能恢复' <<<"$out" && grep -q 'rb_rc=1' <<<"$out"; } \
  && ok "7a: systemctl 失败 → 计入未恢复项 + 非0" || bad "7a: out=$out"
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] \
  && ok "7a: 但后续 resolv.conf 还原仍完成(单项失败不阻断)" || bad "7a: 后续还原被挡住"

# 7b. unit / 配置目录删除失败 → 计入 failed
mk_sandbox; seed_units
out=$(sh_run "RM_FAIL=1" "$RB_STATE
rollback; echo rb_rc=\$?")
{ grep -q '未能恢复' <<<"$out" && grep -q 'rb_rc=1' <<<"$out"; } \
  && ok "7b: 删除 unit/配置目录失败 → 计入未恢复项 + 非0" || bad "7b: out=$out"

# 7c. nft 表存在但删除失败 → 计入 failed
mk_sandbox; seed_units
out=$(sh_run "NFT_RC=1 NFT_LIST_RC=0" "$RB_STATE
rollback; echo rb_rc=\$?")
{ grep -q '未能恢复' <<<"$out" && grep -q 'rb_rc=1' <<<"$out"; } \
  && ok "7c: nft 表存在但删除失败 → 计入未恢复项" || bad "7c: out=$out"

# 7d. 全部顺利 → 才可以显示"已回滚到安装前状态"且返回 0
mk_sandbox; seed_units
out=$(sh_run "" "$RB_STATE
rollback; echo rb_rc=\$?")
{ grep -q '已回滚到安装前状态' <<<"$out" && grep -q 'rb_rc=0' <<<"$out" && ! grep -q '未能恢复' <<<"$out"; } \
  && ok "7d: 全部清理成功 → 显示已回滚到安装前状态 + 返回0" || bad "7d: out=$out"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# P0 回归: install.sh 的 rollback 不得因未初始化变量在 set -u 下二次崩溃。
#
# 现场: `MIHOMO_INSTALLED: unbound variable` —— rollback 里 set +e 只关了 errexit,
# nounset 仍然生效, 读到未赋值的 MIHOMO_INSTALLED 直接中断, 于是它后面的
# nftables.conf / systemd-resolved / resolv.conf 三项系统级还原全部没跑, 而且
# 原始安装错误被这个二次错误盖掉。
#
# 覆盖:
#   A. set -u 且 MIHOMO_INSTALLED 从未赋值 → 无 unbound variable, 跑到末尾
#   B. sing-box 本次新装, 后续步骤失败 → rollback 完整执行, 删本次装的 sing-box
#   C. mihomo 装前已存在(未重新下载) → rollback 完整执行, **不删** mihomo
#   D. mihomo 本次新装 → 删 mihomo; 同时装前已有的 mosdns 不被删
#   E. 单个清理命令失败(nft 返回非0) 不阻断后续 → 三项系统级还原仍完成
#   F. 原始安装错误可见 + 退出码保持非 0, 不被 rollback 的二次错误替代
#
# 沙箱化: 抽出真实的 rollback/on_exit, 只把**绝对路径字面量**重定向到临时根目录
# (变量引用、控制流、set +e/nounset 行为一字未改 —— 正是本用例要验的部分),
# 再打桩 systemctl/nft(测试环境无 systemd/netlink)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 抽出真身。按花括号配平抽取: on_exit 可能是单行定义, 用 /^}/ 收尾会把 install.sh
# 后半截(apt-get 等)一起吞进来并真的执行 —— 必须按 depth 精确切。
xfn(){
  awk -v fn="$1" '
    index($0, fn "(){") == 1 { inf = 1 }
    inf {
      print
      n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m
      if (depth <= 0) exit
    }' "$ROOT/install.sh"
}
: > "$WORK/fn.sh"
for _f in _sha _stash_bin _rollback_bins _commit_bins rollback on_exit; do
  xfn "$_f" >> "$WORK/fn.sh"
done
grep -q '^rollback(){' "$WORK/fn.sh" && grep -q '^on_exit(){' "$WORK/fn.sh" \
  || { echo "抽取 rollback/on_exit 失败"; exit 1; }
# 防呆: 抽出来的东西不该含安装流程的指令(抽多了会真的去跑 apt-get)
grep -qE 'apt-get|curl -fsSL' "$WORK/fn.sh" && { echo "抽取越界: 含安装流程指令"; exit 1; }

# 只重定向绝对路径字面量到沙箱根
sed -i -e 's#/etc/#$SB/etc/#g' -e 's#/usr/local/bin/#$SB/usr/local/bin/#g' \
       -e 's#/opt/#$SB/opt/#g' "$WORK/fn.sh"

mk_sandbox(){   # 造一个"安装到一半"的现场
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/systemd/system" "$SB/etc/systemd/journald.conf.d" "$SB/usr/local/bin" \
           "$SB/opt/pdg-bot" "$SB/etc/mosdns" "$SB/etc/privdns-gateway"
  printf 'PDG-NEW\n'  > "$SB/etc/nftables.conf"
  printf 'ORIG-NFT\n' > "$SB/etc/nftables.conf.pdg-orig"
  printf 'PDG-NEW\n'  > "$SB/etc/resolv.conf"
  printf 'ORIG-RESOLV\n' > "$SB/etc/resolv.conf.pdg-orig"
  for b in mosdns sing-box mihomo pdg pdg-set-token; do printf '%s\n' "$b" > "$SB/usr/local/bin/$b"; done
  export SB
}

# 桩: 测试环境没有 systemd / netlink
harness(){ cat <<'EOF'
BIN_TXN=()
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
systemctl(){ echo "systemctl $* | resolv.conf=$(cat "$SB/etc/resolv.conf" 2>/dev/null)" >> "$SB/../calls.log"; return "${SYSTEMCTL_RC:-0}"; }
nft(){ echo "nft $*" >> "$SB/../calls.log"; return "${NFT_RC:-0}"; }
EOF
}

# 在 set -u 下跑 rollback; $1=额外的前置赋值(模拟安装进行到哪一步)
run_rb(){   # $1=前置变量赋值; $2=(可选) source 真身之后、rollback 之前跑的脚本
  : > "$WORK/calls.log"
  env SB="$SB" NFT_RC="${NFT_RC:-0}" SYSTEMCTL_RC="${SYSTEMCTL_RC:-0}" \
    bash -c "set -uo pipefail
$(harness)
$1
source '$WORK/fn.sh'
${2:-}
rollback" 2>&1
}

# ── A. MIHOMO_INSTALLED 从未赋值 ────────────────────────────────────────────
mk_sandbox
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0')
grep -q 'unbound variable' <<<"$out" && bad "A: rollback 仍报 unbound variable" || ok "A: set -u 下 MIHOMO_INSTALLED 未赋值也不报 unbound variable"
grep -qE '已回滚到安装前状态|回滚已尽力执行完' <<<"$out" && ok "A: rollback 跑到了末尾(没有中途夭折)" || bad "A: 未跑到末尾 out=$out"
[[ "$(cat "$SB/etc/nftables.conf")" == "ORIG-NFT" ]] && ok "A: nftables.conf 已从 .pdg-orig 还原" || bad "A: nftables.conf 未还原"
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] && ok "A: resolv.conf 已从 .pdg-orig 还原" || bad "A: resolv.conf 未还原"

# ── B. sing-box 本次新装 → 删掉本次装的 ─────────────────────────────────────
mk_sandbox
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0' \
  "command rm -f \"\$SB/usr/local/bin/sing-box\"
_stash_bin \"\$SB/usr/local/bin/sing-box\" || exit 9
printf 'NEW\n' > \"\$SB/usr/local/bin/sing-box\"")
grep -q 'unbound variable' <<<"$out" && bad "B: unbound variable" || {
  [[ ! -e "$SB/usr/local/bin/sing-box" ]] && ok "B: sing-box 全新安装后失败 → 本次装的 sing-box 被删" || bad "B: sing-box 未删"; }
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] && ok "B: 后续系统级还原仍完整执行" || bad "B: 系统级还原未执行"

# ── C. mihomo 装前已存在(未重新下载) → 不删 ─────────────────────────────────
mk_sandbox
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0')
[[ -e "$SB/usr/local/bin/mihomo" ]] && ok "C: mihomo 装前已存在且未重装 → 不被删除" || bad "C: 误删了装前已存在的 mihomo"
[[ "$(cat "$SB/etc/nftables.conf")" == "ORIG-NFT" ]] && ok "C: rollback 完整执行" || bad "C: rollback 未完整执行"

# ── D. mihomo 本次新装 → 只删本次新增的 ─────────────────────────────────────
mk_sandbox
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0' \
  "command rm -f \"\$SB/usr/local/bin/mihomo\"
_stash_bin \"\$SB/usr/local/bin/mihomo\" || exit 9
printf 'NEW\n' > \"\$SB/usr/local/bin/mihomo\"")
[[ ! -e "$SB/usr/local/bin/mihomo" ]] && ok "D: mihomo 本次新装 → 被删" || bad "D: 本次新装的 mihomo 未删"
[[ -e "$SB/usr/local/bin/mosdns" ]] && ok "D: 装前已有的 mosdns(未标记本次安装) 不被删" || bad "D: 误删了装前已有的 mosdns"

# ── E. 单个清理失败不阻断后续 ───────────────────────────────────────────────
mk_sandbox; NFT_RC=1
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=1')
NFT_RC=0
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] && ok "E: nft 失败不阻断 → resolv.conf 仍还原" || bad "E: nft 失败挡住了后续还原"
grep -q 'systemctl enable --now systemd-resolved' "$WORK/calls.log" && ok "E: systemd-resolved 恢复仍被执行" || bad "E: systemd-resolved 未恢复"

# ── F. 原始退出码与原始错误不被 rollback 掩盖 ───────────────────────────────
mk_sandbox
cat > "$WORK/prog.sh" <<EOF
set -euo pipefail
$(harness)
INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0
MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0
source '$WORK/fn.sh'
trap 'on_exit \$?' EXIT
echo "原始安装错误: mosdns 配置校验失败" >&2
exit 42
EOF
out=$(SB="$SB" bash "$WORK/prog.sh" 2>&1); rc=$?
[[ "$rc" == 42 ]] && ok "F: 保留原始退出码 42(不被回滚二次错误改写)" || bad "F: 退出码变成 $rc"
grep -q '原始安装错误' <<<"$out" && ok "F: 原始安装错误仍可见" || bad "F: 原始错误被掩盖"
grep -q 'unbound variable' <<<"$out" && bad "F: 回滚过程报 unbound variable" || ok "F: 回滚过程无 unbound variable"
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] && ok "F: 走 EXIT trap 时系统级还原完整" || bad "F: EXIT trap 下还原不完整"

# ── H. 装前已存在(本次被覆盖) → 回滚还原**原件**, 不是删掉 ────────────────
# 别人装的 mosdns/sing-box/mihomo(哪怕版本不同)不算"本次新增"。走真实 _stash_bin 建账,
# 与线上流程一致(旧写法手工摆 .pdg-preinstall + *_INSTALLED=1, 已不是现在的机制)。
mk_sandbox
printf 'OLD-SINGBOX-v1.9\n' > "$SB/usr/local/bin/sing-box"
OLDSHA=$(sha256sum "$SB/usr/local/bin/sing-box" | cut -d' ' -f1)
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; RESOLVED_DISABLED=0' \
  "_stash_bin \"\$SB/usr/local/bin/sing-box\" || exit 9
printf 'NEW-SINGBOX-v1.12\n' > \"\$SB/usr/local/bin/sing-box\"")
if [[ -e "$SB/usr/local/bin/sing-box" ]] \
   && [[ "$(sha256sum "$SB/usr/local/bin/sing-box" | cut -d' ' -f1)" == "$OLDSHA" ]]; then
  ok "H: 覆盖了装前已有的 sing-box → 回滚按 sha 还原原件(不误删别人的)"
else bad "H: 未还原原件 (内容=$(cat "$SB/usr/local/bin/sing-box" 2>/dev/null || echo 已删))"; fi
[[ ! -e "$SB/usr/local/bin/sing-box.pdg-preinstall" ]] && ok "H: 还原后 .pdg-preinstall 备份已清理" || bad "H: 备份残留"
[[ "$(cat "$SB/etc/resolv.conf")" == "ORIG-RESOLV" ]] && ok "H: 系统级还原仍完整" || bad "H: 系统级还原不完整"

# ── I. 装前不存在(纯新增) → 仍然删掉 ─────────────────────────────────────
mk_sandbox
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0' \
  "command rm -f \"\$SB/usr/local/bin/mihomo\"
_stash_bin \"\$SB/usr/local/bin/mihomo\" || exit 9
printf 'NEW\n' > \"\$SB/usr/local/bin/mihomo\"")
[[ ! -e "$SB/usr/local/bin/mihomo" ]] && ok "I: 装前不存在的 mihomo(无备份) → 仍按新增删除" || bad "I: 本次新增的 mihomo 未删"

# ── J. _stash_bin 语义 + 成功路径按事务台账清理备份 ───────────────────────
mk_sandbox
out=$(env SB="$SB" bash -c "set -uo pipefail
$(harness)
source '$WORK/fn.sh'
_stash_bin '$SB/usr/local/bin/mihomo'          # 存在 → 应留备份
_stash_bin '$SB/usr/local/bin/nonexistent'     # 不存在 → 不留备份且返回0
echo rc=\$?" 2>&1)
[[ -e "$SB/usr/local/bin/mihomo.pdg-preinstall" ]] && ok "J: _stash_bin 对已存在的二进制留了原件备份" || bad "J: 未留备份"
[[ ! -e "$SB/usr/local/bin/nonexistent.pdg-preinstall" ]] && grep -q 'rc=0' <<<"$out" \
  && ok "J: _stash_bin 对不存在的二进制不留备份且返回 0(装前没有不算异常)" || bad "J: 空 stash 行为不对 out=$out"

# 成功安装(INSTALL_OK=1) → on_exit 按台账清掉备份, 且不动二进制本身
mk_sandbox
out=$(env SB="$SB" bash -c "set -uo pipefail
$(harness)
INSTALL_OK=1
source '$WORK/fn.sh'
_stash_bin '$SB/usr/local/bin/mihomo'  || exit 9
_stash_bin '$SB/usr/local/bin/sing-box' || exit 9
on_exit 0" 2>&1)
if [[ ! -e "$SB/usr/local/bin/mihomo.pdg-preinstall" && ! -e "$SB/usr/local/bin/sing-box.pdg-preinstall" ]]; then
  ok "J: 安装成功 → .pdg-preinstall 备份被清理干净"
else bad "J: 成功后备份残留"; fi
[[ -e "$SB/usr/local/bin/mihomo" && -e "$SB/usr/local/bin/sing-box" ]] \
  && ok "J: 成功路径不动二进制本身(只清备份)" || bad "J: 成功路径误删了二进制"

# ── L. resolved: 换回 resolv.conf 之后再重启一次; 装机记录跟着备份删 ──────────
# 装机停过 resolved 时回滚先 enable --now(那一刻读到的是装机写的 resolv.conf, 第 8 步之后含
# 127.0.0.1), 换回原文件之后必须再 restart, 否则装机的 127.0.0.1 留在它的全局 DNS 里。
mk_sandbox; printf 'disabled\n' > "$SB/etc/resolv.conf.pdg-resolved"
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=1')
en=$(grep -n 'systemctl enable --now systemd-resolved' "$WORK/calls.log" | head -1 | cut -d: -f1)
rs=$(grep -n 'systemctl restart systemd-resolved' "$WORK/calls.log" | head -1 | cut -d: -f1)
if [[ -n "$en" && -n "$rs" && "$rs" -gt "$en" ]] \
   && grep -q 'systemctl restart systemd-resolved | resolv.conf=ORIG-RESOLV' "$WORK/calls.log"; then
  ok "L: 装机停过 resolved → 先 enable, 换回 resolv.conf 之后再 restart"
else bad "L: resolved 没有在换回 resolv.conf 之后重启: $(cat "$WORK/calls.log")"; fi
[[ ! -e "$SB/etc/resolv.conf.pdg-resolved" ]] && ok "L: 备份用掉了 → 装机记录一并删" || bad "L: 装机记录残留"
mk_sandbox; printf 'untouched\n' > "$SB/etc/resolv.conf.pdg-resolved"
out=$(run_rb 'INSTALL_OK=0; ROLLBACK_DONE=0; FORCED_REINSTALL=0; MOSDNS_INSTALLED=0; SINGBOX_INSTALLED=0; MIHOMO_INSTALLED=0; RESOLVED_DISABLED=0')
grep -qE 'systemctl (enable|restart|start) .*systemd-resolved' "$WORK/calls.log" \
  && bad "L: 装机没停过 resolved, 回滚却去启用/重启它: $(cat "$WORK/calls.log")" \
  || ok "L: 装机没停过 resolved → 回滚不碰它"
[[ ! -e "$SB/etc/resolv.conf.pdg-resolved" ]] && ok "L: 装机记录一并删(没停过的也删)" || bad "L: 装机记录残留"

# ── K. 静态守卫: 三个二进制的安装点前必须先 _stash_bin(将来新增安装路径不能漏留原件) ──
for b in mosdns sing-box mihomo; do
  if awk -v b="$b" '
      { buf[NR] = $0 }
      $0 ~ ("install -m755 .*/usr/local/bin/" b "([^-a-zA-Z0-9_.]|$)") {
        found = 0
        for (i = NR - 3; i < NR; i++)
          if (i > 0 && buf[i] ~ ("_stash_bin /usr/local/bin/" b "([^-a-zA-Z0-9_.]|$)")) found = 1
        if (!found) bad = 1
      }
      END { exit bad ? 1 : 0 }' "$ROOT/install.sh"; then
    ok "K: $b 安装点之前已调用 _stash_bin"
  else
    bad "K: $b 的安装点未先 _stash_bin → 回滚会误删装前已有的 $b"
  fi
done

# ── G. 静态守卫: trap 路径读到的每个变量, 要么在 trap 注册前初始化, 要么引用处一律带 :- 默认值 ──
trapline=$(grep -n "^trap 'on_exit" "$ROOT/install.sh" | cut -d: -f1)
[[ -n "$trapline" ]] && ok "定位到 EXIT trap 注册行($trapline)" || bad "G: 找不到 trap 注册行"
{ xfn rollback; xfn on_exit; } > "$WORK/trapbody.sh"
miss=""
for v in $(grep -oE '\$\{?[A-Z_][A-Z0-9_]*' "$WORK/trapbody.sh" | tr -d '${' | sort -u); do
  # 该变量在 trap 体内的所有引用是否都带 :- 兜底
  safe=1
  while read -r r; do
    [[ -z "$r" ]] && continue
    [[ "$r" == *':-'* ]] || safe=0
  done < <(grep -oE "\\\$\{${v}[^}]*\}|\\\$${v}([^A-Z0-9_]|\$)" "$WORK/trapbody.sh" | sort -u)
  # 或者在 trap 注册前就已初始化
  init=$(head -n "$trapline" "$ROOT/install.sh" | grep -cE "(^|[; ])$v=")
  [[ "$safe" == 1 || "$init" -gt 0 ]] || miss="$miss $v"
done
[[ -z "$miss" ]] && ok "G: trap/rollback 路径无未初始化且无默认值的变量(set -u 安全)" \
  || bad "G: 这些变量既未在 trap 前初始化, 引用处也没有 :- 兜底 →$miss"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

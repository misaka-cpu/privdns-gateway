#!/usr/bin/env bash
# 影子桩(shadow stub)的生命周期契约 —— 直接调 tests/e2e-lib.sh 里那一份实现, 不自带副本。
#
# 为什么需要这支测试:
#   e2e-rescue-migration-lock.sh 会在 /usr/local/bin 造一个假 `ip`(伪造 `ip -4` 的地址
#   列表), 而 /usr/local/bin 排在 PATH 前面。那个桩残留下来之后, 下一支脚本装机时会把
#   本机地址看成落在 PDG_INTERNAL_CIDR(127.0.0.0/8)里 → 救援平面被自动启用并写下
#   PDG_RESCUE_BIND → 沙箱 nft 里没有对应的救援端口放行 → 再下一支 e2e-update.sh 的自检
#   正确判红并整次回滚。整条因果链上没有任何一环指向"上一支留了个假 ip", 所以必须有
#   判据钉着。e2e-install-nft.sh 的 python3 桩是同一类(它只在正常路径上还原)。
#
# 判据全部作用在 $E2E_SHADOW_BIN 上(测试里指向临时目录)。参数化只是为了能在宿主机上跑,
# 被测的仍是生产那一份 e2e_purge_shadow_stub —— 换成复制一份实现来测就毫无意义了。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 名字全部加 t_ 前缀: e2e-lib.sh 自己也定义 ok/bad/pass/nfail, source 之后会把我的顶掉,
# 于是断言照常打印、计数却永远是 0 —— 一个不会报错的假绿。
t_pass=0; t_fail=0
t_ok(){ echo "[OK]   $1"; t_pass=$((t_pass+1)); }
t_bad(){ echo "[FAIL] $1"; t_fail=$((t_fail+1)); }

BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
export E2E_SHADOW_BIN="$BOX/bin"; mkdir -p "$E2E_SHADOW_BIN"

# shellcheck source=tests/e2e-lib.sh
source "$ROOT/tests/e2e-lib.sh" 2>/dev/null || { echo "[FAIL] source e2e-lib.sh 失败"; exit 1; }
# **在 source 之后**再设: lib 顶层会把 E2E_TMP 初始化成空, 先设会被抹掉, 而
# e2e_stub_uninstall 头一句就是 `[[ -n "$E2E_TMP" ]] || return 0` —— 空了就直接不干活。
export E2E_TMP="$BOX/tmp"; mkdir -p "$E2E_TMP"

# 与 e2e-rescue-migration-lock.sh 的 _stub_ip 同形态(含归属标记)
mk_ip_stub(){
  { echo '#!/bin/sh'
    echo "$E2E_STUB_MARK"
    echo 'if [ "$1" = "-4" ]; then'
    echo "  echo '1: eth0    inet 127.0.0.9/16 brd 127.255.255.255 scope global eth0'"
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } > "$E2E_SHADOW_BIN/ip"
  chmod 755 "$E2E_SHADOW_BIN/ip"
}

echo "── 1. 普通文件桩: 清掉之后 PATH 回到系统命令 ──"
mk_ip_stub
grep -qF -- "$E2E_STUB_MARK" "$E2E_SHADOW_BIN/ip" && t_ok "桩带归属标记(与真实生成物同形态)" \
  || t_bad "1a: 桩没有标记"
PATH="$E2E_SHADOW_BIN:$PATH" hash -r 2>/dev/null || true
[[ "$(PATH="$E2E_SHADOW_BIN:$PATH" command -v ip)" == "$E2E_SHADOW_BIN/ip" ]] \
  && t_ok "清理前 command -v ip 指向桩" || t_bad "1b: 桩没有遮住系统命令"
e2e_purge_shadow_stub ip && t_ok "清理返回 0" || t_bad "1c: 清理返回非零"
[[ -e "$E2E_SHADOW_BIN/ip" ]] && t_bad "1d: 桩还在" || t_ok "桩已清除"
_real_ip="$(PATH="$E2E_SHADOW_BIN:$PATH" command -v ip 2>/dev/null)"
[[ -n "$_real_ip" && "$_real_ip" != "$E2E_SHADOW_BIN/ip" ]] \
  && t_ok "command -v ip 回到系统命令($_real_ip)" || t_bad "1e: 找不到系统 ip"
# 系统 ip 必须是真程序, 不是另一个脚本 —— 否则"回到系统命令"这句话不成立
if [[ -n "$_real_ip" ]]; then
  head -c 4 "$_real_ip" 2>/dev/null | grep -q $'\x7fELF' \
    && t_ok "系统 ip 是 ELF 可执行文件" \
    || { dpkg -S "$_real_ip" >/dev/null 2>&1 \
         && t_ok "系统 ip 由系统包提供($(dpkg -S "$_real_ip" 2>/dev/null | cut -d: -f1))" \
         || t_bad "1f: 系统 ip 既不是 ELF 也不属于任何系统包: $_real_ip"; }
fi

echo
echo "── 2. 符号链接桩: 只 unlink 链接, 不碰目标 ──"
: > "$E2E_SHADOW_BIN/py3-real"; chmod 755 "$E2E_SHADOW_BIN/py3-real"
ln -sf "$E2E_SHADOW_BIN/py3-real" "$E2E_SHADOW_BIN/python3"
e2e_purge_shadow_stub python3 >/dev/null 2>&1
[[ -L "$E2E_SHADOW_BIN/python3" ]] && t_bad "2a: 链接还在" || t_ok "目标存在时: 链接已 unlink"
[[ -f "$E2E_SHADOW_BIN/py3-real" ]] && t_ok "**链接目标没有被跟随删除**" || t_bad "2b: 目标被误删"
rm -f "$E2E_SHADOW_BIN/py3-real"
ln -sf "$E2E_SHADOW_BIN/py3-real" "$E2E_SHADOW_BIN/python3"      # 悬空链接
e2e_purge_shadow_stub python3 >/dev/null 2>&1
[[ -L "$E2E_SHADOW_BIN/python3" ]] && t_bad "2c: 悬空链接还在" || t_ok "目标已消失时: 悬空链接也清掉"
_real_py="$(PATH="$E2E_SHADOW_BIN:$PATH" command -v python3 2>/dev/null)"
[[ -n "$_real_py" ]] && "$_real_py" -c 'print(1)' >/dev/null 2>&1 \
  && t_ok "系统 Python 恢复可解析($_real_py)" || t_bad "2d: python3 解析不了"
# 指向 $E2E_SHADOW_BIN 之外的链接是用户自己的安装, 不许碰
ln -sf /usr/bin/env "$E2E_SHADOW_BIN/ip"
e2e_purge_shadow_stub ip >/dev/null 2>&1
[[ -L "$E2E_SHADOW_BIN/ip" ]] && t_ok "指向外部的链接不动(那可能是用户的安装)" \
  || t_bad "2e: 误删了指向外部的链接"
rm -f "$E2E_SHADOW_BIN/ip"

echo
echo "── 3. 同名但不是受管桩: fail-closed, 不删也不静默 ──"
printf '#!/bin/sh\necho 我是用户自己的 ip 包装脚本\n' > "$E2E_SHADOW_BIN/ip"
chmod 755 "$E2E_SHADOW_BIN/ip"
_out="$(e2e_purge_shadow_stub ip 2>&1)"; _rc=$?
[[ "$_rc" != 0 ]] && t_ok "返回非零($_rc) —— 让调用方停下来" || t_bad "3a: 返回 0, 静默放过了"
[[ -f "$E2E_SHADOW_BIN/ip" ]] && t_ok "**未受管的文件没有被删除**" || t_bad "3b: 把用户的文件删了"
grep -q "不是受管测试桩" <<<"$_out" && t_ok "明说了「不是受管测试桩」" || t_bad "3c: 没有说清原因: $_out"
rm -f "$E2E_SHADOW_BIN/ip"
# 目录/设备之类的异常类型同样 fail-closed
mkdir -p "$E2E_SHADOW_BIN/ip"
_out2="$(e2e_purge_shadow_stub ip 2>&1)"; _rc2=$?
[[ "$_rc2" != 0 ]] && t_ok "路径类型异常(目录) → fail-closed" || t_bad "3d: 目录也放过了"
rmdir "$E2E_SHADOW_BIN/ip"

echo
echo "── 4. 不误删无关 fixture ──"
printf '#!/bin/sh\n%s\necho x\n' "$E2E_STUB_MARK" > "$E2E_SHADOW_BIN/some-other-fixture"
printf '#!/bin/sh\necho y\n' > "$E2E_SHADOW_BIN/unrelated"
mkdir -p "$E2E_TMP/other-test-tmp"; : > "$E2E_TMP/other-test-tmp/keep"
mk_ip_stub
e2e_purge_shadow_stub ip >/dev/null 2>&1
[[ -f "$E2E_SHADOW_BIN/some-other-fixture" ]] \
  && t_ok "带标记但不在 allowlist 里的文件保留(只处理显式传入的名字)" \
  || t_bad "4a: 误删了 allowlist 外的带标记文件"
[[ -f "$E2E_SHADOW_BIN/unrelated" ]] && t_ok "无关文件保留" || t_bad "4b: 误删无关文件"
[[ -f "$E2E_TMP/other-test-tmp/keep" ]] && t_ok "别的测试的临时目录保留" || t_bad "4c: 动了别人的临时目录"

echo
echo "── 5. 幂等 ──"
mk_ip_stub
e2e_purge_shadow_stub ip >/dev/null 2>&1; _r1=$?
e2e_purge_shadow_stub ip >/dev/null 2>&1; _r2=$?
[[ "$_r1" == 0 && "$_r2" == 0 ]] && t_ok "连清两次都返回 0(第二次目标已不存在也不报错)" \
  || t_bad "5a: 幂等性不成立(第一次=$_r1 第二次=$_r2)"

echo
echo "── 6. 正常退出主动清场(不靠下一支进场兜底) ──"
# 真的走一遍退出钩子机制: 子脚本 source 同一份 lib, 造桩, 注册钩子, 正常退出。
cat > "$BOX/exit-normal.sh" <<EOF
set -uo pipefail
export E2E_SHADOW_BIN="$E2E_SHADOW_BIN"
source "$ROOT/tests/e2e-lib.sh"
export E2E_TMP="$E2E_TMP"
{ echo '#!/bin/sh'; echo "\$E2E_STUB_MARK"; echo 'exit 0'; } > "\$E2E_SHADOW_BIN/ip"
chmod 755 "\$E2E_SHADOW_BIN/ip"
e2e_add_exit_hook e2e_stub_uninstall
exit 0
EOF
bash "$BOX/exit-normal.sh" >/dev/null 2>&1
[[ -e "$E2E_SHADOW_BIN/ip" ]] && t_bad "6a: 正常退出后桩仍在(serial 最后一支后面没有下一支)" \
  || t_ok "正常退出后影子桩为 0"

echo
echo "── 7. 异常退出: 下一次进场兜底 ──"
cat > "$BOX/exit-crash.sh" <<EOF
set -uo pipefail
export E2E_SHADOW_BIN="$E2E_SHADOW_BIN"
source "$ROOT/tests/e2e-lib.sh"
export E2E_TMP="$E2E_TMP"
{ echo '#!/bin/sh'; echo "\$E2E_STUB_MARK"; echo 'exit 0'; } > "\$E2E_SHADOW_BIN/ip"
chmod 755 "\$E2E_SHADOW_BIN/ip"
kill -9 \$\$        # 连 EXIT 陷阱都不给跑
EOF
bash "$BOX/exit-crash.sh" >/dev/null 2>&1
[[ -e "$E2E_SHADOW_BIN/ip" ]] && t_ok "前提成立: 异常退出确实留下了桩" \
  || t_bad "7a: 前提不成立, 后面那条是空转"
e2e_purge_shadow_stub ip >/dev/null 2>&1
[[ -e "$E2E_SHADOW_BIN/ip" ]] && t_bad "7b: 进场兜底没清掉" || t_ok "下一次进场清掉了它"

echo
echo "── 8. 顺序: 进场清理必须排在任何 PATH 命令之前 ──"
# 这一条只能看结构: e2e_reset_box 头一句就是 `systemctl disable --now …`, 而那正是会被
# 桩劫持的调用。行为上验它需要一整个容器, 所以在源码层面钉死顺序。
_body="$(awk '/^e2e_reset_box\(\)\{/,/^\}/' "$ROOT/tests/e2e-lib.sh")"
_first="$(sed -n '2,$p' <<<"$_body" | grep -vE '^\s*#|^\s*$' | head -1)"
grep -q "e2e_purge_shadow_stub" <<<"$_first" \
  && t_ok "e2e_reset_box 的第一条实语句就是影子桩清理" \
  || t_bad "8a: 第一条实语句是: $_first"
grep -q "e2e_purge_shadow_stub" <<<"$(awk '/^e2e_stub_uninstall\(\)\{/,/^\}/' "$ROOT/tests/e2e-lib.sh")" \
  && t_ok "退出路径(e2e_stub_uninstall)里也调了清理" || t_bad "8b: 退出路径没清影子桩"
# 两个真实的桩生成器都必须打归属标记, 否则清理认不出来
for f in tests/e2e-rescue-migration-lock.sh tests/e2e-install-nft.sh; do
  grep -q 'E2E_STUB_MARK' "$ROOT/$f" && t_ok "$(basename "$f") 给它造的桩打了归属标记" \
    || t_bad "8c: $f 的桩没有标记 —— 清理会把它当成用户的真程序而拒删"
done

echo "────────────────────────────────────────"
echo "通过 $t_pass, 失败 $t_fail"
[[ $((t_pass+t_fail)) -gt 0 ]] || { echo "零断言 —— 判失败"; exit 1; }
exit $(( t_fail > 0 ? 1 : 0 ))

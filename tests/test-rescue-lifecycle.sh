#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 救援平面的生命周期回归: enable / disable / status / 老机迁移 / 卸载清理。
#
# 这些动作里有几条纪律, 错了都是"用户在最需要救援的时候进不去"或"把恢复按钮开给了公网":
#   · 只绑内网卡段内的本机地址, **绝不 0.0.0.0/::** —— 绑通配等于把"换默认出口""完整恢复"
#     这些按钮开给任何人;
#   · 救援端口的放行必须带 `ip saddr <内网段>` 约束, 且**幂等** —— 重复 enable 不许堆出第二条;
#   · disable 之后不许再有可用入口, 但**凭据要留着**(再开时指纹不变, 用户不用重新核对);
#   · 用户主动 disable 过, 升级迁移就**不许**把它开回来 —— 升级把用户关掉的东西又打开,
#     是最招人恨的一类行为;
#   · enable 中途失败要回到操作前(unit / 启用状态 / 标记), 不留半启用状态。
#
# 沙盒里没有真 systemd/nft, 所以这里打桩 —— 但桩是**有状态**的(记录 enable/disable/active),
# 于是"是不是真的停用了""规则是不是真的撤了"是可观测的, 而不是我们自己断言自己。
# 真 socket activation 与硬化策略留到 10b/10c。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
skip(){ echo "[SKIP] $1"; }

command -v nft >/dev/null 2>&1 || true    # 真 nft 不是必需: 下面用桩
# 端口只从常量单一事实源取 —— 测试里写字面量会被 test-rescue-constants 的守卫抓到, 而且
# 改端口时这里就会说谎。
# shellcheck source=lib/rescue.sh
source "$ROOT/lib/rescue.sh"
RP="$PDG_RESCUE_PORT"

# ── 沙盒 ────────────────────────────────────────────────────────────────────
BOX="$WORK/box"; BIN="$WORK/bin"; STATE="$WORK/state"
mkdir -p "$BIN" "$STATE" "$BOX/etc/privdns-gateway/rescue" "$BOX/etc/systemd/system" \
         "$BOX/opt/pdg-bot" "$BOX/run"
export PATH="$BIN:$PATH"

# 有状态的假 systemd: 记录每个 unit 的 enabled/active
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
D="$PDG_TEST_STATE"; mkdir -p "$D"
v="$1"; shift; now=0; [[ "${1:-}" == "--now" ]] && { now=1; shift; }
case "$v" in
  daemon-reload|reset-failed|preset) exit 0;;
  enable)  for u in "$@"; do echo 1 > "$D/$u.en"; [[ "$now" == 1 ]] && echo 1 > "$D/$u.ac"; done; exit 0;;
  disable) for u in "$@"; do echo 0 > "$D/$u.en"; [[ "$now" == 1 ]] && echo 0 > "$D/$u.ac"; done; exit 0;;
  start|restart) for u in "$@"; do echo 1 > "$D/$u.ac"; done; exit 0;;
  stop) for u in "$@"; do echo 0 > "$D/$u.ac"; done; exit 0;;
  is-active)  [[ "$(cat "$D/$1.ac" 2>/dev/null)" == 1 ]] && { echo active; exit 0; }; echo inactive; exit 3;;
  is-enabled) [[ "$(cat "$D/$1.en" 2>/dev/null)" == 1 ]] && { echo enabled; exit 0; }; echo disabled; exit 1;;
esac
exit 0
S
# 假 nft: -c 校验永远通过(语法由真 nft 在 10b/10c 验), list 回放当前 conf 的放行行
cat > "$BIN/nft" <<'S'
#!/bin/bash
case "$1" in
  -c) exit 0;;
  -f) cp -f "$2" "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
  list) grep -E 'accept|redirect' "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
esac
exit 0
S
cat > "$BIN/ip" <<'S'
#!/bin/bash
# 只回一个落在测试网段内的地址
[[ "$*" == *"addr show"* ]] && echo "2: eth0    inet 10.7.0.5/16 brd 10.7.255.255 scope global eth0"
exit 0
S
chmod 755 "$BIN"/systemctl "$BIN"/nft "$BIN"/ip
export PDG_TEST_STATE="$STATE"

# 生产文件就位
install -m755 "$ROOT/deploy/rescue/rescue.py" "$BOX/opt/pdg-bot/rescue.py"
install -m755 "$ROOT/deploy/rescue/rescue_cred.py" "$BOX/opt/pdg-bot/rescue_cred.py"
install -m755 "$ROOT/deploy/bot/rescue_const.py" "$BOX/opt/pdg-bot/rescue_const.py"
install -m755 "$ROOT/deploy/bot/rescue_nft.py" "$BOX/opt/pdg-bot/rescue_nft.py"
install -m644 "$ROOT/lib/rescue.sh" "$BOX/opt/pdg-bot/rescue.sh"
printf 'PDG_INTERNAL_CIDR=10.7.0.0/16\n' > "$BOX/etc/privdns-gateway/profile.env"
cat > "$BOX/etc/nftables.conf" <<'N'
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ip saddr 10.7.0.0/16 tcp dport { 53, 81, 853, 7893, 8445 } accept
    }
}
N

# ── 把被测函数抽出来(不 source 整个 pdg.sh: 它底部有命令分发)────────────────
{
  echo 'REPO_DIR="'"$ROOT"'"'
  echo 'UNIT_DIR="'"$BOX"'/etc/systemd/system"'
  # 必须 export: rescue_cred.py / rescue_const.py 是**子进程**, 只看得到环境变量
  echo 'export PDG_RESCUE_DIR="'"$BOX"'/etc/privdns-gateway/rescue"'
  echo 'export PDG_RESCUE_CERT="$PDG_RESCUE_DIR/cert.pem"'
  echo 'export PDG_RESCUE_KEY="$PDG_RESCUE_DIR/key.pem"'
  echo 'export PDG_RESCUE_TOKEN="$PDG_RESCUE_DIR/token"'
  echo 'export PDG_PROFILE_ENV="'"$BOX"'/etc/privdns-gateway/profile.env"'
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; need_root(){ :; }; _lock(){ :; }'
  echo '_pdg_mktemp_dir(){ mktemp -d; }'
  for fn in _rescue_load _rescue_bind_addr _rescue_optout _rescue_socket_present \
            _rescue_write_units _rescue_nft_has _rescue_nft_open _rescue_nft_close \
            cmd_rescue _rescue_enable _rescue_disable _rescue_status migrate_rescue_plane; do
    sed -n "/^${fn}(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"
  done
} > "$WORK/fns.sh"

# 生产代码读死 /etc/nftables.conf 与 /opt/pdg-bot —— 沙盒里把它们指到 BOX
sed -i "s#/etc/nftables.conf#$BOX/etc/nftables.conf#g; s#/opt/pdg-bot#$BOX/opt/pdg-bot#g" "$WORK/fns.sh"

run(){ bash -c "source '$WORK/fns.sh' 2>/dev/null; $1" 2>&1; }

# ══ 1. enable ═══════════════════════════════════════════════════════════════
echo "── 1. enable ──"
out="$(run 'cmd_rescue enable')"
if grep -q '已启用' <<<"$out"; then ok "enable 成功"; else bad "enable 失败: $out"; fi
sock="$BOX/etc/systemd/system/pdg-rescue.socket"
if [[ -f "$sock" ]]; then ok "socket unit 已安装"; else bad "unit 没装"; fi
if grep -qE "ListenStream=10\.7\.0\.5:$RP" "$sock" 2>/dev/null; then
  ok "监听地址是内网地址 + 救援端口(不是通配)"
else bad "监听地址不对: $(grep ListenStream "$sock" 2>/dev/null)"; fi
if ! grep -qE 'ListenStream=(0\.0\.0\.0|::|\[::\]):' "$sock" 2>/dev/null; then
  ok "**没有**绑 0.0.0.0/:: 通配地址"
else bad "绑了通配地址"; fi
if [[ "$(cat "$STATE/pdg-rescue.socket.en" 2>/dev/null)" == 1 ]]; then
  ok "socket 已 enable"; else bad "socket 没 enable"; fi
n=$(grep -cE "dport $RP accept" "$BOX/etc/nftables.conf")
if [[ "$n" == 1 ]]; then ok "救援端口放行恰好一条"; else bad "救援端口规则 $n 条"; fi
if grep -qE "ip saddr 10\.7\.0\.0/16.*dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "救援端口放行带内网来源约束"; else bad "救援端口放行没有来源约束: $(grep "$RP" "$BOX/etc/nftables.conf")"; fi
miss=""
for f in token cert.pem key.pem; do
  [[ -s "$BOX/etc/privdns-gateway/rescue/$f" ]] || miss="$miss $f"
done
if [[ -z "$miss" ]]; then ok "token / 证书 / 私钥齐全"; else bad "凭据缺失:$miss"; fi
m_key=$(stat -c %a "$BOX/etc/privdns-gateway/rescue/key.pem")
m_tok=$(stat -c %a "$BOX/etc/privdns-gateway/rescue/token")
if [[ "$m_key" == 600 && "$m_tok" == 600 ]]; then
  ok "私钥与 token 为 root 专属读取(600)"; else bad "权限不对 key=$m_key token=$m_tok"; fi

# 记下凭据指纹, 后面比对"更新前后不变"
sha_before="$(sha256sum 2>/dev/null "$BOX/etc/privdns-gateway/rescue/token" "$BOX/etc/privdns-gateway/rescue/cert.pem" \
              "$BOX/etc/privdns-gateway/rescue/key.pem" | awk '{print $1}' | tr '\n' ' ')"
fp_before="$(run 'cmd_rescue fingerprint' | tail -1)"

# ══ 2. 重复 enable 幂等 ═════════════════════════════════════════════════════
echo; echo "── 2. 重复 enable ──"
run 'cmd_rescue enable' >/dev/null
n=$(grep -cE "dport $RP accept" "$BOX/etc/nftables.conf")
if [[ "$n" == 1 ]]; then ok "重复 enable 不产生第二条救援端口规则"; else bad "重复后 $n 条"; fi
sha_now="$(sha256sum 2>/dev/null "$BOX/etc/privdns-gateway/rescue/token" "$BOX/etc/privdns-gateway/rescue/cert.pem" \
           "$BOX/etc/privdns-gateway/rescue/key.pem" | awk '{print $1}' | tr '\n' ' ')"
if [[ -n "${sha_before// /}" && "$sha_now" == "$sha_before" ]]; then
  ok "重复 enable 不重生成 token/证书/私钥(SHA256 逐个一致)"
else bad "凭据比对不成立(before=$sha_before now=$sha_now)"; fi

# ══ 3. status ═══════════════════════════════════════════════════════════════
echo; echo "── 3. status ──"
st="$(run 'cmd_rescue status')"
for kw in "socket unit" "socket 状态" "service 状态" "监听地址" "防火墙放行" "证书指纹"; do
  grep -q "$kw" <<<"$st" || { bad "status 缺少: $kw"; break; }
done
grep -q "证书指纹" <<<"$st" && ok "status 分项报告 unit/socket/监听/防火墙/凭据(不只看 is-active)"
if ! grep -qE '[A-Za-z0-9+/]{40,}' <<<"$(grep -v 指纹 <<<"$st")"; then
  ok "status 不打印 token 或私钥内容"; else bad "status 疑似打印了秘密"; fi

# ══ 4. disable ══════════════════════════════════════════════════════════════
echo; echo "── 4. disable ──"
out="$(run 'cmd_rescue disable')"
if grep -q '已停用' <<<"$out"; then ok "disable 成功"; else bad "disable 失败: $out"; fi
if [[ "$(cat "$STATE/pdg-rescue.socket.en" 2>/dev/null)" == 0 ]]; then
  ok "socket 已 disable"; else bad "socket 仍 enabled"; fi
if [[ "$(cat "$STATE/pdg-rescue.socket.ac" 2>/dev/null)" == 0 ]]; then
  ok "socket 已停止(不再监听)"; else bad "socket 仍 active"; fi
if ! grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "disable 后救援端口放行已撤销"; else bad "放行仍在"; fi
if [[ -s "$BOX/etc/privdns-gateway/rescue/token" ]]; then
  ok "凭据保留(再开时指纹不变, 用户不用重新核对)"; else bad "凭据被删了"; fi
if [[ -e "$BOX/etc/privdns-gateway/rescue/disabled" ]]; then
  ok "记下了「这是用户的选择」"; else bad "没记 opt-out 标记"; fi

# ══ 5. 用户停用后, 升级迁移不许开回来 ═══════════════════════════════════════
echo; echo "── 5. 停用后再更新 ──"
run 'migrate_rescue_plane' >/dev/null
if [[ "$(cat "$STATE/pdg-rescue.socket.en" 2>/dev/null)" == 0 ]]; then
  ok "**用户停用过 → 迁移一个字都不改**(升级不把它开回来)"; else bad "迁移把用户关掉的服务开回来了"; fi
if ! grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "迁移也没把救援端口放行加回来"; else bad "迁移加回了放行"; fi

# ══ 6. 再次 enable: 指纹不变 ════════════════════════════════════════════════
echo; echo "── 6. 再 enable ──"
out="$(run 'cmd_rescue enable')"
if grep -q '已启用' <<<"$out"; then ok "disable 之后可以再 enable"; else bad "再 enable 失败: $out"; fi
fp_after="$(run 'cmd_rescue fingerprint' | tail -1)"
if [[ -n "$fp_before" && "$fp_after" == "$fp_before" ]]; then
  ok "证书指纹前后一致(只比对哈希, 不输出秘密)"; else bad "指纹变了: $fp_before → $fp_after"; fi
if [[ ! -e "$BOX/etc/privdns-gateway/rescue/disabled" ]]; then
  ok "用户明确再开 → opt-out 标记清除"; else bad "标记没清"; fi
n=$(grep -cE "dport $RP accept" "$BOX/etc/nftables.conf")
if [[ "$n" == 1 ]]; then ok "再 enable 后救援端口仍恰好一条"; else bad "$n 条"; fi

# ══ 7. 迁移幂等 ═════════════════════════════════════════════════════════════
echo; echo "── 7. 迁移幂等 ──"
before="$(sha256sum "$BOX/etc/nftables.conf" "$BOX/etc/systemd/system/pdg-rescue.socket" | awk '{print $1}')"
run 'migrate_rescue_plane' >/dev/null
after="$(sha256sum "$BOX/etc/nftables.conf" "$BOX/etc/systemd/system/pdg-rescue.socket" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  ok "已启用的机器上再迁移: 防火墙与 unit 逐字节不变"; else bad "迁移动了东西"; fi

# ══ 8. 拿不到内网地址时拒绝启用 ═════════════════════════════════════════════
echo; echo "── 8. 没有内网地址 ──"
cat > "$BIN/ip" <<'S'
#!/bin/bash
exit 0
S
chmod 755 "$BIN/ip"
out="$(run 'cmd_rescue enable')"
if grep -q '拒绝启用' <<<"$out" && grep -q '0.0.0.0' <<<"$out"; then
  ok "找不到内网地址 → 拒绝启用并说明为什么不退回通配"; else bad "没有正确拒绝: $out"; fi

# ══ 9. 卸载清理 ═════════════════════════════════════════════════════════════
echo; echo "── 9. 卸载 ──"
un="$(sed -n '1,60p' "$ROOT/uninstall.sh")"
if grep -q 'pdg-rescue.socket pdg-rescue.service' <<<"$un" \
   && grep -q 'rm -f /etc/systemd/system/pdg-rescue.socket' <<<"$un"; then
  ok "uninstall 停用并删除 pdg-rescue socket 与 service"
else bad "uninstall 没清理救援 unit"; fi
if grep -q 'reset-failed pdg-rescue' <<<"$un"; then
  ok "uninstall 执行 reset-failed(不留 failed 残留)"; else bad "缺 reset-failed"; fi
if grep -qE 'delete table inet pdg|nftables.conf.pdg-orig' "$ROOT/uninstall.sh"; then
  ok "救援端口随本项目 nft 表一并移除(卸载删表 + 还原备份)"; else bad "nft 清理缺失"; fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
if (( pass + nfail == 0 )); then echo "零断言 —— 判失败"; exit 1; fi
[[ "$nfail" == 0 ]]

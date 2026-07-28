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
# 秘密哨兵: 凭据文件里塞一段独一无二的字符串, 于是"有没有泄漏"是可搜索的事实, 而不是
# 靠肉眼看输出。任何 status/fingerprint/日志/残留报告里出现它 → 直接判失败。
SECRET_SENTINEL="PDGTESTSECRET-a7f3c1e9b2d84056-DO-NOT-LEAK"

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
# 用 10a-1 的**安装真源**把运行模块装齐 —— enable 会检查完整性, 而这份清单本来就是那一份。
# 这样清单一变, 这个测试自动跟着走, 不会两处漂移。
( source "$ROOT/lib/modules.sh"; pdg_install_runtime_modules "$ROOT" "$BOX/opt/pdg-bot" ) \
  || { echo "[FAIL] 运行模块装不上, 无法继续"; exit 1; }
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
  echo 'PROFILE_ENV="'"$BOX"'/etc/privdns-gateway/profile.env"'
  echo 'RESCUE_INTENT_KEY="PDG_RESCUE_ENABLED"'
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; need_root(){ :; }; _lock(){ :; }'
  echo '_pdg_mktemp_dir(){ mktemp -d; }'
  for fn in _profile_set _rescue_load _rescue_bind_addr _rescue_intent _rescue_intent_set \
            _rescue_optout _rescue_intent_migrate _rescue_socket_present \
            _rescue_write_units _rescue_nft_has _rescue_nft_open _rescue_nft_close \
            _rescue_rotate cmd_rescue _rescue_enable _rescue_disable _rescue_status \
            migrate_rescue_plane; do
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
# 我们的放行有**两处形态**, 都是有意的(10b 在真 nft 上验出来的):
#   · 独立表 inet pdgrescue —— 让恢复旧防火墙时它不被顺手删掉;
#   · 每条 policy drop 的 input 基链里补一行带标记的放行 —— 因为独立表的 accept **盖不过**
#     另一张表的 policy drop(同一 hook 上多条基链会挨个走, accept 只终止本链)。
# 所以这里分别数, 而不是笼统数"含 dport 的行": 后者既分不清两种形态, 也会把用户自己写的
# 同端口规则算进来。
blk=$(grep -c '^# ==== PrivDNS Gateway 救援入口' "$BOX/etc/nftables.conf")
inl=$(grep -c 'pdg-rescue(自动补入' "$BOX/etc/nftables.conf")
if [[ "$blk" == 1 && "$inl" == 1 ]]; then ok "独立表 1 块 + drop 链里补入 1 行(各自恰好一份)"
else bad "形态不对: 独立表 $blk 块 / 补入 $inl 行"; fi
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
blk=$(grep -c '^# ==== PrivDNS Gateway 救援入口' "$BOX/etc/nftables.conf")
inl=$(grep -c 'pdg-rescue(自动补入' "$BOX/etc/nftables.conf")
if [[ "$blk" == 1 && "$inl" == 1 ]]; then ok "重复 enable 不堆: 仍是 1 块 + 1 行"
else bad "重复后成了 $blk 块 / $inl 行"; fi
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
# 秘密泄漏用哨兵判, 不用"看起来像 base64"这种启发式: 把哨兵塞进 token 与私钥, 再看它有没有
# 从任何一个出口漏出来 —— status、fingerprint、以及审计/事务日志。
tok_bak="$(cat "$BOX/etc/privdns-gateway/rescue/token")"
key_bak="$(cat "$BOX/etc/privdns-gateway/rescue/key.pem")"
printf '%s' "$SECRET_SENTINEL" > "$BOX/etc/privdns-gateway/rescue/token"
printf '%s' "-----BEGIN PRIVATE KEY-----
$SECRET_SENTINEL
-----END PRIVATE KEY-----" > "$BOX/etc/privdns-gateway/rescue/key.pem"
leak=""
for sub in status fingerprint; do
  grep -qF "$SECRET_SENTINEL" <<<"$(run "cmd_rescue $sub" 2>&1)" && leak="$leak $sub"
done
if [[ -z "$leak" ]]; then ok "status / fingerprint 都不带出 token 或私钥的任何字节"
else bad "这些子命令泄漏了凭据:$leak"; fi
if ! grep -rqF "$SECRET_SENTINEL" "$BOX/var" "$BOX/run" 2>/dev/null; then
  ok "审计与事务日志里搜不到凭据内容"; else bad "日志里落下了凭据"; fi
printf '%s' "$tok_bak" > "$BOX/etc/privdns-gateway/rescue/token"
printf '%s' "$key_bak" > "$BOX/etc/privdns-gateway/rescue/key.pem"

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
if grep -q '^PDG_RESCUE_ENABLED=0$' "$BOX/etc/privdns-gateway/profile.env"; then
  ok "意图真源记下 disabled(profile.env, 原子 upsert)"; else bad "意图没写进 profile.env"; fi

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
if grep -q '^PDG_RESCUE_ENABLED=1$' "$BOX/etc/privdns-gateway/profile.env"; then
  ok "用户明确再开 → 意图回到 enabled"; else bad "意图没更新"; fi
n=$(grep -cE "dport $RP accept" "$BOX/etc/nftables.conf")
if [[ "$(grep -c '^# ==== PrivDNS Gateway 救援入口' "$BOX/etc/nftables.conf")" == 1 \
   && "$(grep -c 'pdg-rescue(自动补入' "$BOX/etc/nftables.conf")" == 1 ]]; then
  ok "再 enable 后仍是 1 块 + 1 行"; else bad "$n 条"; fi

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
# 复原地址桩 —— 后面的用例还要用它(不复原的话它们全会被"没有内网地址"挡掉, 变成假红)
cat > "$BIN/ip" <<'S'
#!/bin/bash
[[ "$*" == *"addr show"* ]] && echo "2: eth0    inet 10.7.0.5/16 brd 10.7.255.255 scope global eth0"
exit 0
S
chmod 755 "$BIN/ip"

# ══ 9. 卸载清理 ═════════════════════════════════════════════════════════════
echo; echo "── 9. 卸载 ──"
# 不 grep 源码, **真跑一遍** pdg_rescue_cleanup: 它就是卸载删救援平面的那段本体。
# 卸载后残留的不是无害垃圾 —— 是一把仍然有效的 token 与 TLS 私钥, 外加一条内网放行规则。
un="$(sed -n '1,80p' "$ROOT/uninstall.sh")"
if grep -q 'pdg-rescue.socket pdg-rescue.service' <<<"$un" && grep -q 'pdg_rescue_cleanup' <<<"$un"; then
  ok "uninstall 停用 socket/service 并调用救援清理"
else bad "uninstall 没接上救援清理"; fi
if grep -q 'reset-failed pdg-rescue' <<<"$un"; then
  ok "uninstall 执行 reset-failed(不留 failed 残留)"; else bad "缺 reset-failed"; fi

# 造一个"装好且启用过"的盘面, 再让清理跑过去
run 'cmd_rescue enable' >/dev/null
UBOX="$WORK/unbox"; rm -rf "$UBOX"
mkdir -p "$UBOX/etc/systemd/system" "$UBOX/opt/pdg-bot" "$UBOX/etc/privdns-gateway/rescue" \
         "$UBOX/var/lib/privdns-gateway"
cp -a "$BOX/etc/systemd/system/pdg-rescue.socket" "$BOX/etc/systemd/system/pdg-rescue.service" \
      "$UBOX/etc/systemd/system/" 2>/dev/null
cp -a "$BOX/opt/pdg-bot/." "$UBOX/opt/pdg-bot/" 2>/dev/null
printf 'USERFILE' > "$UBOX/opt/pdg-bot/my-hook.sh"      # 用户自己放的东西, 卸载不许碰
printf '%s' "$SECRET_SENTINEL" > "$UBOX/etc/privdns-gateway/rescue/token"
printf 'KEYMATERIAL-%s' "$SECRET_SENTINEL" > "$UBOX/etc/privdns-gateway/rescue/key.pem"
printf 'CERT' > "$UBOX/etc/privdns-gateway/rescue/cert.pem"
printf '{}' > "$UBOX/var/lib/privdns-gateway/rescue-state.json"
# 现网配置 = 用户自己写的同端口规则 + 我们注入的独立表
{ printf 'table inet mine {\n    chain input {\n        tcp dport %s accept\n    }\n}\n' "$RP"
  python3 "$ROOT/deploy/bot/rescue_nft.py" 10.7.0.0/16 "$RP" </dev/null; } > "$UBOX/etc/nftables.conf"

TBL="$(bash -c "source '$ROOT/lib/rescue.sh'; printf %s \"\$PDG_RESCUE_TABLE\"")"
if resid="$(bash -c "source '$ROOT/lib/rescue.sh'; pdg_rescue_cleanup '$UBOX' ''")"; then rc=0; else rc=1; fi
if [[ "$rc" == 0 && -z "$resid" ]]; then ok "清理成功时不报残留"; else bad "清理报了残留(rc=$rc): $resid"; fi

left=()
for f in etc/systemd/system/pdg-rescue.socket etc/systemd/system/pdg-rescue.service \
         etc/privdns-gateway/rescue/token etc/privdns-gateway/rescue/key.pem \
         etc/privdns-gateway/rescue/cert.pem var/lib/privdns-gateway/rescue-state.json \
         opt/pdg-bot/rescue.py opt/pdg-bot/rescue_cred.py opt/pdg-bot/breakglass.py \
         opt/pdg-bot/rescue_nft.py opt/pdg-bot/rescue_const.py opt/pdg-bot/rescue.sh; do
  [[ -e "$UBOX/$f" ]] && left+=("$f")
done
if ((${#left[@]}==0)); then ok "unit / 凭据 / 私钥 / 状态 / 救援运行文件全部删除"
else bad "卸载后仍残留: ${left[*]}"; fi
if ! grep -rqF "$SECRET_SENTINEL" "$UBOX" 2>/dev/null; then
  ok "盘上再也搜不到 token/私钥的任何字节"; else bad "卸载后仍能搜到凭据内容"; fi
if ! grep -q "table inet $TBL" "$UBOX/etc/nftables.conf"; then
  ok "我们注入的独立表已从 nftables.conf 摘除"; else bad "救援表仍在配置里"; fi
if grep -q 'table inet mine' "$UBOX/etc/nftables.conf" \
   && grep -qE "tcp dport $RP accept" "$UBOX/etc/nftables.conf"; then
  ok "用户自己写的同端口规则**原样保留**(靠 BANNER 定界, 不按端口删行)"
else bad "卸载把用户自己的同端口规则删掉了"; fi
# 装的模块要一个不剩地收走 —— 清单读 10a-1 真源, 不在测试里另抄一份
gone_miss=()
while read -r _ name _; do
  [[ -n "$name" ]] || continue
  [[ -e "$UBOX/opt/pdg-bot/$name" ]] && gone_miss+=("$name")
done < <(bash -c "source '$ROOT/lib/modules.sh'; pdg_runtime_modules")
if ((${#gone_miss[@]}==0)); then
  ok "真源里的运行模块**逐项**删净(含 pdgtx/checks 等业务模块, 不只救援那几个)"
else bad "这些模块没删掉: ${gone_miss[*]}"; fi
# 但用户自己放进来的东西一个字节都不许动
if [[ -e "$UBOX/opt/pdg-bot/my-hook.sh" && "$(cat "$UBOX/opt/pdg-bot/my-hook.sh")" == "USERFILE" ]]; then
  ok "用户自己放在 /opt/pdg-bot 的文件原样保留(只删我们装的那些)"
else bad "把用户自己的文件删了"; fi

# 删不掉时必须**逐条报出来**而不是假装完成
rm -rf "$UBOX"; mkdir -p "$UBOX/etc/privdns-gateway/rescue"
printf '%s' "$SECRET_SENTINEL" > "$UBOX/etc/privdns-gateway/rescue/token"
# 让删除真的失败: 非 root 时把父目录设成不可写即可; root 无视目录权限, 那就用不可变位。
undo=""
if [[ "$(id -u)" != 0 ]]; then
  chmod 500 "$UBOX/etc/privdns-gateway/rescue" && undo="chmod 700 '$UBOX/etc/privdns-gateway/rescue'"
elif command -v chattr >/dev/null 2>&1 && chattr +i "$UBOX/etc/privdns-gateway/rescue/token" 2>/dev/null; then
  undo="chattr -i '$UBOX/etc/privdns-gateway/rescue/token'"
fi
if [[ -n "$undo" ]]; then
  if resid="$(bash -c "source '$ROOT/lib/rescue.sh'; pdg_rescue_cleanup '$UBOX' ''")"; then rc2=0; else rc2=1; fi
  eval "$undo" 2>/dev/null
  if [[ "$rc2" == 1 ]] && grep -q 'token' <<<"$resid"; then
    ok "删不掉的凭据被报为残留且返回非 0(不假装完成)"
  else bad "删不掉却报成功: rc=$rc2 resid=$resid"; fi
  if ! grep -qF "$SECRET_SENTINEL" <<<"$resid"; then
    ok "残留报告只给路径, 不带出凭据内容"; else bad "残留报告泄漏了凭据内容"; fi
else
  skip "无法制造删除失败(既非 root 又改不了目录权限) → 残留上报路径未验"
fi
rm -rf "$UBOX"

# 常量漂移: bash 侧表名与 rescue_nft.py 的 TABLE 必须逐字一致
p_tbl="$(sed -n 's/^TABLE = "\(.*\)"/\1/p' "$ROOT/deploy/bot/rescue_nft.py")"
if [[ -n "$TBL" && "$TBL" == "$p_tbl" ]]; then
  ok "表名单一形态: lib/rescue.sh 与 rescue_nft.py 一致($TBL)"
else bad "表名漂移: bash=$TBL python=$p_tbl"; fi

# ══ 10. unit 双路径渲染: install.sh 与 pdg rescue enable 必须逐字节一致 ═════
echo; echo "── 10. unit 渲染双路径 ──"
# install.sh 与 pdg.sh 各有一份占位符替换(本轮不强制抽共享库)。两处漂移的后果是"装机装出来的
# unit 和 enable 出来的不一样" —— 于是同一台机器上重跑一次 enable 就把监听改了, 而没人知道。
# 这里用**同一组输入**分别跑两条真实渲染路径, 比对字节。
render_via_pdg(){   # 走 pdg.sh 的 _rescue_write_units
  local bind="$1" out="$2"
  rm -rf "$out"; mkdir -p "$out"
  bash -c "source '$WORK/fns.sh' 2>/dev/null; source '$ROOT/lib/rescue.sh'; UNIT_DIR='$out'; PDG_RESCUE_PORT='$3'; _rescue_write_units '$bind'"
}
render_via_install(){   # 走 install.sh 里那条 render() 的**真实定义**(从源码摘出来, 不是另写一份)
  local bind="$1" out="$2" port="$3" f
  rm -rf "$out"; mkdir -p "$out"
  {
    echo 'SERVER_IP=x; INTERNAL_CIDR=x; CERT_DIR=x; SSH_PORT=x; MOSDNS_CACHE=x'
    echo 'JOURNALD_MAXUSE=x; HIJACK_SET_FILE=x'
    echo "PDG_RESCUE_PORT='$port'; RESCUE_BIND='$bind'"
    sed -n '/^render(){ sed/,/"\$1"; }/p' "$ROOT/install.sh"
    for f in pdg-rescue.socket pdg-rescue.service; do
      echo "render '$ROOT/deploy/rescue/$f' > '$out/$f'"
    done
  } > "$WORK/rin.sh"
  bash "$WORK/rin.sh"
}

A="$WORK/renderA"; B="$WORK/renderB"
for pair in "10.7.0.5 $RP" "192.168.9.9 $RP"; do
  set -- $pair
  render_via_pdg "$1" "$A" "$2" && render_via_install "$1" "$B" "$2" || { bad "渲染路径跑不通($1)"; continue; }
  if diff -q "$A/pdg-rescue.socket" "$B/pdg-rescue.socket" >/dev/null \
     && diff -q "$A/pdg-rescue.service" "$B/pdg-rescue.service" >/dev/null; then
    ok "两条渲染路径逐字节一致(bind=$1)"
  else
    bad "渲染漂移(bind=$1): $(diff "$A/pdg-rescue.socket" "$B/pdg-rescue.socket" | head -4)"
  fi
done
# 先确认两边真的产出了文件 —— 否则"没有占位符"是在空目录上假绿
if [[ -s "$A/pdg-rescue.socket" && -s "$B/pdg-rescue.socket" \
      && -s "$A/pdg-rescue.service" && -s "$B/pdg-rescue.service" ]]; then
  if ! grep -rqE '__[A-Z_]+__' "$A" "$B" 2>/dev/null; then
    ok "两条路径都产出了 unit 且没留下未替换的占位符"
  else bad "有占位符残留: $(grep -rhoE '__[A-Z_]+__' "$A" "$B" | sort -u | tr '\n' ' ')"; fi
else bad "渲染产物缺失, 占位符检查不成立"; fi

# ══ 11. 用户自定义的同端口规则必须逐字节保留 ═══════════════════════════════
echo; echo "── 11. 用户自定义规则 ──"
run 'cmd_rescue enable' >/dev/null
USERRULE='        ip saddr 172.31.0.0/16 tcp dport '"$RP"' accept   # 我自己加的, 别动'
python3 - "$BOX/etc/nftables.conf" "$USERRULE" <<'PYU'
import sys
p, rule = sys.argv[1], sys.argv[2]
lines = open(p, encoding="utf-8").read().splitlines()
out = []
for ln in lines:
    out.append(ln)
    if 'iif "lo" accept' in ln:
        out.append(rule)
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYU
run 'cmd_rescue disable' >/dev/null
if grep -qF "$USERRULE" "$BOX/etc/nftables.conf"; then
  ok "disable 只删项目固定形态的规则, **用户自己写的同端口规则逐字节保留**"
else
  bad "用户自定义规则被误删了"
fi
if ! grep -qE "ip saddr 10\.7\.0\.0/16.*dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "项目自己那条确实删掉了"; else bad "项目规则没删"; fi

# ══ 12. 意图四态 ════════════════════════════════════════════════════════════
echo; echo "── 12. 意图四态 ──"
grep -v '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env" > "$WORK/pe" && mv "$WORK/pe" "$BOX/etc/privdns-gateway/profile.env"
st="$(run 'cmd_rescue status')"
grep -q '未记录' <<<"$st" && ok "键不存在 → status 报「未记录(从未部署)」" || bad "四态: 未记录判不出"
run 'cmd_rescue enable' >/dev/null
st="$(run 'cmd_rescue status')"
grep -qE '用户意图 *enabled' <<<"$st" && ok "enable 后 status 报 enabled" || bad "四态: enabled 判不出"
# 服务崩了 ≠ 用户关了: 手动把 socket 置为 inactive, 意图应仍是 enabled
echo 0 > "$STATE/pdg-rescue.socket.ac"
st="$(run 'cmd_rescue status')"
if grep -qE '用户意图 *enabled' <<<"$st" && grep -q 'inactive' <<<"$st"; then
  ok "服务 inactive 但意图仍是 enabled(两者分开报, 不靠 is-active 推意图)"
else bad "四态: 崩溃态与用户禁用混淆了"; fi
# 这种情况下迁移应当把它救回来(而不是当成"用户关的"不管)
run 'migrate_rescue_plane' >/dev/null
if [[ "$(cat "$STATE/pdg-rescue.socket.ac" 2>/dev/null)" == 1 ]]; then
  ok "意图 enabled 但服务掉线 → 迁移把它恢复起来"; else bad "掉线的服务没被救回来"; fi
run 'cmd_rescue disable' >/dev/null
st="$(run 'cmd_rescue status')"
grep -q 'disabled' <<<"$st" && ok "disable 后 status 报 disabled" || bad "四态: disabled 判不出"

# ══ 13. rotate ══════════════════════════════════════════════════════════════
echo; echo "── 13. rotate ──"
run 'cmd_rescue enable' >/dev/null
t0="$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')"
c0="$(sha256sum "$BOX/etc/privdns-gateway/rescue/cert.pem" | awk '{print $1}')"
f0="$(run 'cmd_rescue fingerprint' | tail -1)"
out="$(run 'cmd_rescue rotate token')"
t1="$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')"
c1="$(sha256sum "$BOX/etc/privdns-gateway/rescue/cert.pem" | awk '{print $1}')"
f1="$(run 'cmd_rescue fingerprint' | tail -1)"
if [[ "$t1" != "$t0" && "$c1" == "$c0" && "$f1" == "$f0" ]]; then
  ok "rotate token: 只换 token, 证书与指纹不动(沿用 rescue_cred 既定范围)"
else bad "rotate token 范围不对"; fi
grep -q '会话立即失效' <<<"$out" && ok "rotate token 明确提示已登录会话失效" || bad "缺会话失效提示"
out="$(run 'cmd_rescue rotate cert')"
f2="$(run 'cmd_rescue fingerprint' | tail -1)"
if [[ -n "$f2" && "$f2" != "$f1" ]]; then ok "rotate cert: 指纹确实变了"; else bad "证书没换"; fi
grep -q '指纹已改变' <<<"$out" && ok "rotate cert **明确提示指纹已改变**(否则用户会以为被中间人)" \
  || bad "没提示指纹变化"
if ! grep -qE '[A-Za-z0-9_-]{30,}' <<<"$(grep -v 指纹 <<<"$out")"; then
  ok "rotate 输出不含 token 或私钥内容"; else bad "rotate 疑似输出了秘密"; fi
# 失败回滚: 让 rescue_cred 必失败
t_before="$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')"
f_before="$(run 'cmd_rescue fingerprint' | tail -1)"
cat > "$BOX/opt/pdg-bot/rescue_cred.py.bak" < "$BOX/opt/pdg-bot/rescue_cred.py"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(0 if sys.argv[1:2]==["fingerprint"] else 1)\n' \
  > "$BOX/opt/pdg-bot/rescue_cred.py"
out="$(run 'cmd_rescue rotate token')"
mv -f "$BOX/opt/pdg-bot/rescue_cred.py.bak" "$BOX/opt/pdg-bot/rescue_cred.py"
t_after="$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')"
if grep -q '已恢复原凭据' <<<"$out" && [[ "$t_after" == "$t_before" ]]; then
  ok "rotate 失败 → 原凭据逐字节恢复(SHA256 一致), 明确说明未改变"
else bad "rotate 失败没回滚: $out"; fi
# 证书那一侧同样不许被顺手动过: token 轮换失败不该改变指纹, 否则用户会以为遭了中间人。
f_after="$(run 'cmd_rescue fingerprint' | tail -1)"
if [[ -n "$f_before" && "$f_after" == "$f_before" ]]; then
  ok "rotate token 失败后证书指纹一字未变(用户不用重新核对)"
else bad "指纹被动了: $f_before → $f_after"; fi


# ══ 14. 失败路径: 校验不过 / 启动失败 都必须回到操作前 ═════════════════════
echo; echo "── 14. 失败回滚 ──"
run 'cmd_rescue disable' >/dev/null
conf0="$(sha256sum "$BOX/etc/nftables.conf" | awk '{print $1}')"
int0="$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env" || echo none)"
# (a) nft -c 判定失败 → 候选绝不能被应用
cat > "$BIN/nft" <<'S'
#!/bin/bash
case "$1" in
  -c) exit 1;;                 # 校验不过
  -f) cp -f "$2" "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
  list) grep -E 'accept|redirect' "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
esac
exit 0
S
chmod 755 "$BIN/nft"
out="$(run 'cmd_rescue enable')"
if [[ "$(sha256sum "$BOX/etc/nftables.conf" | awk '{print $1}')" == "$conf0" ]]; then
  ok "nft 校验不过 → 候选**没有**被应用, 现网配置逐字节未变"
else bad "校验失败却把候选写进去了"; fi
if grep -q '回滚\|失败' <<<"$out"; then ok "校验失败时明确报错而不是静默成功"; else bad "没报错: $out"; fi
if [[ "$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env" || echo none)" == "$int0" ]]; then
  ok "校验失败后意图保持操作前的值"; else bad "意图被改了"; fi
# 复原 nft 桩
cat > "$BIN/nft" <<'S'
#!/bin/bash
case "$1" in
  -c) exit 0;;
  -f) cp -f "$2" "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
  list) grep -E 'accept|redirect' "$PDG_TEST_STATE/applied.conf" 2>/dev/null; exit 0;;
esac
exit 0
S
chmod 755 "$BIN/nft"

# (b) socket 起不来 → unit / 启用状态 / 意图 / 防火墙全部回到操作前
had_unit=0; [[ -f "$BOX/etc/systemd/system/pdg-rescue.socket" ]] && had_unit=1
conf1="$(sha256sum "$BOX/etc/nftables.conf" | awk '{print $1}')"
int1="$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env" || echo none)"
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
D="$PDG_TEST_STATE"; mkdir -p "$D"
v="$1"; shift; now=0; [[ "${1:-}" == "--now" ]] && { now=1; shift; }
case "$v" in
  daemon-reload|reset-failed|preset) exit 0;;
  enable)  [[ "$*" == *pdg-rescue.socket* ]] && exit 1     # 注入: socket 起不来
           for u in "$@"; do echo 1 > "$D/$u.en"; [[ "$now" == 1 ]] && echo 1 > "$D/$u.ac"; done; exit 0;;
  disable) for u in "$@"; do echo 0 > "$D/$u.en"; [[ "$now" == 1 ]] && echo 0 > "$D/$u.ac"; done; exit 0;;
  start|restart) for u in "$@"; do echo 1 > "$D/$u.ac"; done; exit 0;;
  stop) for u in "$@"; do echo 0 > "$D/$u.ac"; done; exit 0;;
  is-active)  [[ "$(cat "$D/$1.ac" 2>/dev/null)" == 1 ]] && { echo active; exit 0; }; echo inactive; exit 3;;
  is-enabled) [[ "$(cat "$D/$1.en" 2>/dev/null)" == 1 ]] && { echo enabled; exit 0; }; echo disabled; exit 1;;
esac
exit 0
S
chmod 755 "$BIN/systemctl"
out="$(run 'cmd_rescue enable')"
if grep -q '回滚' <<<"$out"; then ok "socket 起不来 → 明确说明回滚"; else bad "没回滚: $out"; fi
now_unit=0; [[ -f "$BOX/etc/systemd/system/pdg-rescue.socket" ]] && now_unit=1
if [[ "$now_unit" == "$had_unit" ]]; then
  ok "回滚后 unit 存在与否回到操作前"; else bad "unit 状态没恢复($had_unit → $now_unit)"; fi
if [[ "$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env" || echo none)" == "$int1" ]]; then
  ok "回滚后**意图**回到操作前(没被写成 enabled)"; else bad "意图没恢复"; fi
if [[ "$(cat "$STATE/pdg-rescue.socket.en" 2>/dev/null)" != 1 ]]; then
  ok "回滚后 socket 未处于 enabled"; else bad "socket 仍 enabled"; fi
if [[ "$(sha256sum "$BOX/etc/nftables.conf" | awk '{print $1}')" == "$conf1" ]]; then
  ok "回滚后防火墙配置逐字节回到操作前(没留下孤儿放行)"
else bad "启动失败却把放行规则留在了配置里"; fi
# 复原 systemd 桩
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
chmod 755 "$BIN/systemctl"

# ══ 16. socket activation 状态模型 ═════════════════════════════════════════
echo; echo "── 16. socket activation 状态 ──"
# Accept=no 的 socket activation 下, "socket 在监听 + service inactive" 是**健康**状态:
# 已布防, 等着请求。把它判成"服务挂了"的后果是每次 update 都重跑一遍 enable —— 凭据被重新
# 生成、证书指纹变掉, 用户下次访问看到指纹不一致, 只能怀疑自己遇上了中间人。
run 'cmd_rescue enable' >/dev/null
echo 0 > "$STATE/pdg-rescue.service.ac"        # service 闲着(正常)
echo 1 > "$STATE/pdg-rescue.socket.ac"; echo 1 > "$STATE/pdg-rescue.socket.en"

snap_all(){ find "$BOX" -type f -printf '%p %s %T@\n' 2>/dev/null | sort; }
before="$(snap_all)"; tok0="$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')"
fp0="$(run 'cmd_rescue fingerprint' | tail -1)"
run 'migrate_rescue_plane' >/dev/null
if [[ "$(snap_all)" == "$before" ]]; then
  ok "socket active + service inactive → 迁移**零改动**(没有一个文件被动过)"
else
  bad "迁移动了文件: $(diff <(echo "$before") <(snap_all) | head -3 | tr '\n' ' ')"; fi
if [[ "$(sha256sum "$BOX/etc/privdns-gateway/rescue/token" | awk '{print $1}')" == "$tok0" \
   && "$(run 'cmd_rescue fingerprint' | tail -1)" == "$fp0" ]]; then
  ok "凭据与证书指纹一字未变(否则用户下次访问会以为遇上中间人)"
else bad "迁移把凭据/指纹换了"; fi
st="$(run 'cmd_rescue status')"
if grep -q '待按需拉起' <<<"$st"; then
  ok "status 把正常 inactive 说成「待按需拉起」, 不是「服务挂了」"
else bad "status 文案把闲置说成故障: $(grep 'service' <<<"$st")"; fi

# service 正在服务 → 同样健康
echo 1 > "$STATE/pdg-rescue.service.ac"
st="$(run 'cmd_rescue status')"
if grep -q '正在服务请求' <<<"$st"; then ok "service active → 显示正在服务请求"
else bad "service active 文案不对"; fi
before="$(snap_all)"; run 'migrate_rescue_plane' >/dev/null
if [[ "$(snap_all)" == "$before" ]]; then ok "socket + service 都 active → 迁移仍零改动"
else bad "迁移动了文件"; fi

# service failed → 必须单独点名, 且 status 本身只读
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
  is-active)  s="$(cat "$D/$1.ac" 2>/dev/null)"
              case "$s" in 1) echo active; exit 0;; failed) echo failed; exit 3;; *) echo inactive; exit 3;; esac;;
  is-enabled) [[ "$(cat "$D/$1.en" 2>/dev/null)" == 1 ]] && { echo enabled; exit 0; }; echo disabled; exit 1;;
esac
exit 0
S
chmod 755 "$BIN/systemctl"
echo failed > "$STATE/pdg-rescue.service.ac"
before="$(snap_all)"
st="$(run 'cmd_rescue status')"
if grep -q 'failed' <<<"$st" && grep -q '需要处理' <<<"$st"; then
  ok "service failed → status 点名异常(与正常 inactive 分开说)"
else bad "failed 没被单独点名: $(grep 'service' <<<"$st")"; fi
if ! grep -q '待按需拉起' <<<"$st"; then
  ok "failed 时不再显示「待按需拉起」(两种状态不混为一谈)"; else bad "failed 被说成待拉起"; fi
if [[ "$(snap_all)" == "$before" ]]; then ok "status 只读: 看一眼状态不写任何文件"
else bad "status 动了文件"; fi

# socket inactive(真挂了)→ enable 能修回来
echo 0 > "$STATE/pdg-rescue.socket.ac"; echo 1 > "$STATE/pdg-rescue.service.ac"
run 'cmd_rescue enable' >/dev/null
if [[ "$(cat "$STATE/pdg-rescue.socket.ac" 2>/dev/null)" == 1 ]]; then
  ok "socket inactive(异常)→ enable 修复回 active"; else bad "enable 没修回来"; fi

# 放行被别人清掉 → 迁移要察觉并修回来(不是只看 unit 就宣布幂等)。
# 现场必须自己搭干净: 前面小节留下的 conf 里有**用户自己写的**同端口放行, 拿它当底噪的话
# 下面两条断言量到的都是用户那一行, 与我们的规则在不在毫无关系 —— 那种绿是假的。
cat > "$BOX/etc/nftables.conf" <<'C'
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
    }
}
C
run 'cmd_rescue enable' >/dev/null
# 这份现场是 policy drop 的 input 链, 所以 enable 会产出两处形态: 独立表 + 链内补入行。
if [[ "$(grep -c '^# ==== PrivDNS Gateway 救援入口' "$BOX/etc/nftables.conf")" == 1 \
   && "$(grep -c 'pdg-rescue(自动补入' "$BOX/etc/nftables.conf")" == 1 ]]; then
  ok "(前提)干净现场上 enable 出 1 块独立表 + 1 行链内放行"; else bad "(前提)现场没搭好"; fi
python3 "$ROOT/deploy/bot/rescue_nft.py" --strip < "$BOX/etc/nftables.conf" > "$BOX/etc/nftables.conf.t" \
  && mv -f "$BOX/etc/nftables.conf.t" "$BOX/etc/nftables.conf"
if ! grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "(前提)放行已被外力清掉"; else bad "(前提)没能清掉放行, 下条断言无意义"; fi
run 'migrate_rescue_plane' >/dev/null
if grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "放行被清掉 → 迁移察觉不一致并修回来(判据含 nft, 不只看 unit)"
else bad "迁移没把放行修回来"; fi

# ══ 17. 沙盒边界声明(10b 硬门)═══════════════════════════════════════════════
echo; echo "── 17. 沙盒边界 ──"
DOC="docs/rescue-plane-acceptance.md"     # 硬门的正式登记在文档里, 这里只是引用
# 10b 那批已经在真 systemd/nft 上验过了(tests/e2e-rescue-10b.sh, 需 root)。这里仍标 SKIP:
# 本文件跑在桩上, 不能把别处的验收算成自己的绿。
skip "真 systemd socket activation / FreeBind / 崩溃后仍可拉起 → 见 tests/e2e-rescue-10b.sh(已验收)"
skip "ProtectSystem / ReadWritePaths / RestrictAddressFamilies 硬化 → 见 tests/e2e-rescue-10b.sh(已验收)"
skip "真实 nft 校验/应用/来源约束/旧快照恢复后仍可达 → 见 tests/e2e-rescue-10b.sh(已验收)"
skip "大快照耗时 / MemoryMax=64M / 浏览器断线 / TimeoutStopSec / 跨版本矩阵 → $DOC 第三节(10c)"
if [[ -f "$ROOT/$DOC" ]] && grep -q "AF_NETLINK" "$ROOT/$DOC" && grep -q "MemoryMax" "$ROOT/$DOC"; then
  ok "10b/10c 硬门登记在 $DOC(测试只引用它, 不作为唯一记录)"
else bad "找不到正式验收文档或它缺硬门条目"; fi
echo "  (以上为**桩行为验证**, 不能记作真 systemd/nft 已验收)"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
if (( pass + nfail == 0 )); then echo "零断言 —— 判失败"; exit 1; fi
[[ "$nfail" == 0 ]]

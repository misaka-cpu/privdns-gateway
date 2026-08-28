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
echo "$*" >> "$D/systemctl.log"
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
  echo 'RESCUE_BIND_KEY="PDG_RESCUE_BIND"'
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; need_root(){ :; }; _lock(){ :; }'
  # 落在 $WORK 里面: 沙箱一清, 它们跟着走。写成裸 `mktemp -d` 的话每调一次留一个目录
  # (实测一趟 33 个), 而这个函数在 rollback/snapshot 路径上被反复调。
  echo '_pdg_mktemp_dir(){ mktemp -d "'"$WORK"'/pdgmk.XXXXXX"; }'
  for fn in _profile_set _rescue_load _rescue_bind_addr _rescue_bind_candidates \
            _rescue_bind_from_cidr _rescue_set_bind _rescue_listen_addr \
            _rescue_refresh_units _rescue_intent _rescue_intent_set \
            _rescue_optout _rescue_intent_migrate _rescue_socket_present \
            _rescue_write_units _rescue_nft_has _rescue_nft_has_kernel \
            _rescue_nft_count_disk _rescue_nft_count_kernel _rescue_nft_drop_legacy \
            _rescue_nft_open _rescue_nft_close \
            _rescue_rotate cmd_rescue _rescue_enable _rescue_disable _rescue_status \
            _nft_apply_main _lan_nft_reapply \
            migrate_rescue_plane; do
    sed -n "/^${fn}(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh"
  done
  # 常量也要跟着抽: _lan_nft_reapply 现在从 $LAN_NFT_CONF 读路径(以前写死在函数体里, 被
  # 下面那条 sed 顺手改掉了)。`set -u` 下漏一个就是 unbound variable, 而它半途死掉的表现
  # 与"漏抽函数"一模一样 —— 报出来的是"防火墙放行失败", 看起来像救援平面自己的缺陷。
  grep -E '^LAN_NFT_CONF=' "$ROOT/deploy/bot/pdg.sh"
} > "$WORK/fns.sh"

  # _nft_apply_main / _lan_nft_reapply: 救援平面的放行走它们(主规则加载完顺带把内网面板的
  # 白名单补回内核)。**抽取清单要跟着依赖走** —— 漏了的话 _rescue_nft_open 里那次加载调到
  # 一个未定义的名字, 报出来的是"防火墙放行失败(候选未通过 nft -c 或应用失败)", 看起来像
  # 救援平面自己的缺陷。下面那条 sed 会一并把这两个函数里的默认路径也指到沙盒。

# 生产代码读死 /etc/nftables.conf 与 /opt/pdg-bot —— 沙盒里把它们指到 BOX
sed -i "s#/etc/nftables-pdg-lan.conf#$BOX/etc/nftables-pdg-lan.conf#g; s#/etc/nftables.conf#$BOX/etc/nftables.conf#g; s#/opt/pdg-bot#$BOX/opt/pdg-bot#g" "$WORK/fns.sh"

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
# 形态: **项目自己 inet pdg 链内**一条带标记的规则。独立表设计已废弃 —— 它的 accept 盖不过
# 同 hook 上另一条链的 policy drop(10b 真 nft 实测), 而且会被 doctor 判成 input 链冲突,
# 导致启用救援平面的机器每次 update 自检失败并整次回滚。
inl=$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf")
tbl=$(grep -c 'table inet pdgrescue' "$BOX/etc/nftables.conf")
if [[ "$inl" == 1 && "$tbl" == 0 ]]; then ok "链内恰好 1 条带标记规则, 且**不再**创建独立表"
else bad "形态不对: 链内 $inl 条 / 独立表 $tbl 处"; fi
if grep -q 'ip saddr 10\.7\.0\.0/16 ip daddr 10\.7\.0\.5 tcp dport '"$RP"' accept comment "pdg-rescue"' "$BOX/etc/nftables.conf"; then
  ok "规则四要素齐全: 来源段 + 目的地址 + 端口 + 标记"
else bad "规则形态不对: $(grep pdg-rescue "$BOX/etc/nftables.conf" | head -1)"; fi
if [[ "$(grep -n 'comment "pdg-rescue"' "$BOX/etc/nftables.conf" | cut -d: -f1)" -lt \
      "$(grep -n 'policy drop' "$BOX/etc/nftables.conf" | head -1 | cut -d: -f1)" ]] \
   || [[ "$(awk '/comment "pdg-rescue"/{print NR; exit}' "$BOX/etc/nftables.conf")" -gt \
         "$(awk '/policy drop/{print NR; exit}' "$BOX/etc/nftables.conf")" ]]; then
  ok "规则落在 input 链首(在链尾的 drop 之前 —— 位置错了等于没放行)"
else bad "规则位置不对"; fi
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
inl=$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf")
if [[ "$inl" == 1 ]]; then ok "重复 enable 不堆: 链内仍恰好 1 条"
else bad "重复后成了 $inl 条"; fi
sha_now="$(sha256sum 2>/dev/null "$BOX/etc/privdns-gateway/rescue/token" "$BOX/etc/privdns-gateway/rescue/cert.pem" \
           "$BOX/etc/privdns-gateway/rescue/key.pem" | awk '{print $1}' | tr '\n' ' ')"
if [[ -n "${sha_before// /}" && "$sha_now" == "$sha_before" ]]; then
  ok "重复 enable 不重生成 token/证书/私钥(SHA256 逐个一致)"
else bad "凭据比对不成立(before=$sha_before now=$sha_now)"; fi

# ══ 3. status ═══════════════════════════════════════════════════════════════
echo; echo "── 3. status ──"
st="$(run 'cmd_rescue status')"
for kw in "socket unit" "socket 状态" "service 状态" "监听地址" "来源段" "nft 磁盘规则" "nft 内核规则" "应用层来源校验" "遗留独立表" "证书指纹"; do
  grep -q "$kw" <<<"$st" || { bad "status 缺少: $kw"; break; }
done
grep -q "证书指纹" <<<"$st" && ok "status 分项报告 unit/socket/监听/防火墙/凭据(不只看 is-active)"
# 每行都必须是 "  <项目>  <值>" 的形状: 命令替换把多行结果带进 printf 会凭空多出孤行
# (实机上就出现过多打一行 disabled、内核规则数后面跟个 "?"), 事故现场读到这种输出只会更慌。
stray="$(grep -vE '^(==|  \S)' <<<"$st" | grep -v '^$' | head -3)"
if [[ -z "$stray" ]]; then ok "status 没有孤行/游离字符(每行都是「项目 值」)"
else bad "status 出现孤行: $(tr '\n' '|' <<<"$stray")"; fi
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
# **内核侧**也必须干净。只删磁盘不管内核, 是这个平面上出现过的真实缺陷: 增量 nft -f 删不掉
# 已经不在文件里的对象, 于是配置上看不出放行、规则却还在跑。桩把"应用过的配置"记在
# applied.conf 里, 它就是这里的内核视图。
kern="$(cat "$STATE/applied.conf" 2>/dev/null || echo)"
if [[ "$(grep -c 'comment "pdg-rescue"' <<<"$kern")" == 0 ]]; then
  ok "disable 后**内核侧**也没有项目规则(不是只把磁盘擦干净)"
else bad "内核里仍有 $(grep -c 'comment "pdg-rescue"' <<<"$kern") 条项目规则"; fi
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
if [[ "$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf")" == 1 ]]; then
  ok "再 enable 后链内仍恰好 1 条"; else bad "$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf") 条"; fi

# ══ 7. 迁移幂等 ═════════════════════════════════════════════════════════════
echo; echo "── 7. 迁移幂等 ──"
before="$(sha256sum "$BOX/etc/nftables.conf" "$BOX/etc/systemd/system/pdg-rescue.socket" | awk '{print $1}')"
run 'migrate_rescue_plane' >/dev/null
after="$(sha256sum "$BOX/etc/nftables.conf" "$BOX/etc/systemd/system/pdg-rescue.socket" | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  ok "已启用的机器上再迁移: 防火墙与 unit 逐字节不变"; else bad "迁移动了东西"; fi

# ══ 8. 没配监听地址 → 拒绝启用(绝不回落通配)═══════════════════════════════
echo; echo "── 8. 没配 bind ──"
run 'cmd_rescue disable' >/dev/null
cp "$BOX/etc/privdns-gateway/profile.env" "$WORK/profile.bak"
sed -i '/^PDG_RESCUE_BIND=/d' "$BOX/etc/privdns-gateway/profile.env"
# 同时让"来源段内唯一本机地址"这条老路径也走不通(否则它会自动补一个, 那是另一条用例)
cat > "$BIN/ip" <<'S'
#!/bin/bash
[[ "$*" == *"addr show"* ]] && { echo "2: eth0    inet 192.0.2.7/24 brd 192.0.2.255 scope global eth0"
                                 echo "3: eth1    inet 198.51.100.9/24 brd 198.51.100.255 scope global eth1"; }
exit 0
S
chmod 755 "$BIN/ip"
out="$(run 'cmd_rescue enable')"
if grep -q '没有配置监听地址' <<<"$out"; then ok "没配 bind → 明确拒绝启用并说明来源段与监听地址是两件事"
else bad "没有正确拒绝: $(head -2 <<<"$out")"; fi
if grep -q 'sudo pdg rescue bind' <<<"$out"; then ok "拒绝时给出具体怎么配"; else bad "没给指引"; fi
if grep -qE '本机可选地址' <<<"$out" && grep -q '192.0.2.7' <<<"$out"; then
  ok "列出本机候选地址供人选(**不替人选**, 尤其不默认挑全局地址)"; else bad "没列候选"; fi
# disable 不删 unit(凭据与 unit 都留着, 再开即用), 所以这里看的是**内容**: 不许出现通配监听
# 只看**盘上与运行态**, 不 grep 提示文案 —— 拒绝信息里本来就写着"绝不回落 0.0.0.0",
# 拿文案当证据会把正确的解释判成违规(第一版就这么假红了一次)。
if ! grep -qE 'ListenStream=(0\.0\.0\.0|\[?::\]?):' "$BOX/etc/systemd/system/pdg-rescue.socket" 2>/dev/null \
   && [[ "$(cat "$STATE/pdg-rescue.socket.en" 2>/dev/null)" != 1 ]]; then
  ok "绝不回落通配地址, 也没有把 socket 悄悄开起来"; else bad "出现了通配或半启用"; fi

# 多个候选时不猜: 来源段内有两个本机地址 → 老路径也必须放弃自动决定
cat > "$BIN/ip" <<'S'
#!/bin/bash
[[ "$*" == *"addr show"* ]] && { echo "2: eth0    inet 10.7.0.5/16 brd 10.7.255.255 scope global eth0"
                                 echo "3: eth1    inet 10.7.9.9/16 brd 10.7.255.255 scope global eth1"; }
exit 0
S
chmod 755 "$BIN/ip"
out="$(run 'cmd_rescue enable')"
if grep -q '没有配置监听地址' <<<"$out"; then
  ok "来源段内有多个本机地址 → **不猜**, 仍然要求显式配置"; else bad "多候选时自动挑了一个"; fi

# 恢复现场: 唯一地址 + 显式 bind
cat > "$BIN/ip" <<'S'
#!/bin/bash
[[ "$*" == *"addr show"* ]] && echo "2: eth0    inet 10.7.0.5/16 brd 10.7.255.255 scope global eth0"
exit 0
S
chmod 755 "$BIN/ip"
out="$(run 'cmd_rescue enable')"
if grep -q '已启用' <<<"$out" && grep -q '^PDG_RESCUE_BIND=10.7.0.5$' "$BOX/etc/privdns-gateway/profile.env"; then
  ok "来源段内**恰好一个**本机地址 → 沿用旧安全路径并持久化(老机器平滑迁移)"
else bad "唯一地址迁移失败: $(head -2 <<<"$out")"; fi

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
# 现网配置 = 项目表(policy drop, 内含我们注入的链内规则) + 用户自己写的同端口规则。
# 注意注入要传**三个**参数(来源段/端口/监听地址): 旧的两参数调用现在会失败, 于是配置里
# 根本没有我们的规则 —— 那样"卸载后无残留"这条断言就变成了假绿(它其实什么都没验)。
cat > "$UBOX/etc/nftables.conf.base" <<C
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
    }
}
table inet mine {
    chain input {
        type filter hook input priority 10; policy accept;
        tcp dport $RP accept comment "my own"
    }
}
C
python3 "$ROOT/deploy/bot/rescue_nft.py" 10.7.0.0/16 "$RP" 10.7.0.5 \
  < "$UBOX/etc/nftables.conf.base" > "$UBOX/etc/nftables.conf"
if [[ "$(grep -c 'comment "pdg-rescue"' "$UBOX/etc/nftables.conf")" == 1 ]]; then
  ok "(前提)卸载现场里确实有一条我们的链内规则"; else bad "(前提)现场没造出救援规则"; fi

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
if [[ "$(grep -c 'comment "pdg-rescue"' "$UBOX/etc/nftables.conf")" == 0 ]]; then
  ok "卸载后磁盘上没有项目链内规则"; else bad "链内规则还留在 nftables.conf 里"; fi
if ! grep -q "table inet $TBL" "$UBOX/etc/nftables.conf"; then
  ok "配置里也没有旧独立表"; else bad "旧独立表仍在配置里"; fi
if grep -q 'table inet mine' "$UBOX/etc/nftables.conf" \
   && grep -q 'comment "my own"' "$UBOX/etc/nftables.conf"; then
  ok "用户自己写的同端口规则**原样保留**(按标记精确删, 不按端口删行)"
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
# 独立表已废弃: 生产路径不许再生成它, 只保留识别/清理用的常量
if ! grep -q "def rule_block" "$ROOT/deploy/bot/rescue_nft.py" \
   && grep -q "LEGACY_TABLE" "$ROOT/deploy/bot/rescue_nft.py"; then
  ok "生产路径不再创建独立表(只保留旧表的识别与清理)"
else bad "rescue_nft.py 里还留着生成独立表的代码"; fi

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
    # DOT_DOMAIN 也是 render() 的必需输入: 6.2A 起它在函数入口做 fail-closed 校验
    # (缺值或非法就 return 1, 不静默留占位符)。救援模板本身不含该占位符, 但共享渲染器
    # 的输入集合是统一的 —— 少一项就渲染不出来, 这正是那道校验该有的行为。
    echo 'DOT_DOMAIN=dot.rescue.test'
    echo "PDG_RESCUE_PORT='$port'; RESCUE_BIND='$bind'"
    # 从顶层 `render(){` 抽到它真正的收尾 `"$1"; }` —— 不假设第一条命令是 sed
    # (6.2A 起 render 先做 DoT 域名校验), 也不依赖固定行号或缩进。
    sed -n '/^render(){/,/"\$1"; }/p' "$ROOT/install.sh"
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
echo "$*" >> "$D/systemctl.log"
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
echo "$*" >> "$D/systemctl.log"
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
if [[ "$(grep -c 'comment \"pdg-rescue\"' "$BOX/etc/nftables.conf")" == 1 ]]; then
  ok "(前提)干净现场上 enable 出链内恰好 1 条放行"; else bad "(前提)现场没搭好"; fi
python3 "$ROOT/deploy/bot/rescue_nft.py" --strip < "$BOX/etc/nftables.conf" > "$BOX/etc/nftables.conf.t" \
  && mv -f "$BOX/etc/nftables.conf.t" "$BOX/etc/nftables.conf"
if ! grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "(前提)放行已被外力清掉"; else bad "(前提)没能清掉放行, 下条断言无意义"; fi
run 'migrate_rescue_plane' >/dev/null
if grep -qE "dport $RP accept" "$BOX/etc/nftables.conf"; then
  ok "放行被清掉 → 迁移察觉不一致并修回来(判据含 nft, 不只看 unit)"
else bad "迁移没把放行修回来"; fi

# ══ 16b. pdg rescue bind: 幂等、校验与失败回滚 ═════════════════════════════
echo; echo "── 16b. bind 修改 ──"
run 'cmd_rescue enable' >/dev/null
b0="$(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)"
u0="$(sha256sum "$BOX/etc/systemd/system/pdg-rescue.socket" | cut -d' ' -f1)"
n0="$(sha256sum "$BOX/etc/nftables.conf" | cut -d' ' -f1)"
out="$(run 'cmd_rescue bind '"$b0")"
if grep -q '无变化' <<<"$out" \
   && [[ "$(sha256sum "$BOX/etc/systemd/system/pdg-rescue.socket" | cut -d' ' -f1)" == "$u0" ]] \
   && [[ "$(sha256sum "$BOX/etc/nftables.conf" | cut -d' ' -f1)" == "$n0" ]]; then
  ok "重复设置同一地址 → 幂等(unit 与防火墙逐字节未动)"
else bad "同址重设不幂等: $(head -1 <<<"$out")"; fi
for badip in 0.0.0.0 255.255.255.255 224.0.0.1 gateway.local 999.1.1.1 ""; do
  out="$(run "cmd_rescue bind $badip")"
  if grep -qE '不是合法的 IPv4 监听地址|用法' <<<"$out" \
     && [[ "$(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)" == "$b0" ]]; then
    :
  else bad "非法地址 ${badip:-(空)} 被接受了: $(head -1 <<<"$out")"; break; fi
done
[[ "$(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)" == "$b0" ]] \
  && ok "0.0.0.0 / 广播 / 组播 / 主机名 / 非法八位组 / 空值全部拒绝, 且旧值未被改动"

# 切到另一个地址(沙盒里让它成为本机地址)
cat > "$BIN/ip" <<'S'
#!/bin/bash
[[ "$*" == *"addr show"* ]] && { echo "2: eth0    inet 10.7.0.5/16 brd 10.7.255.255 scope global eth0"
                                 echo "3: eth1    inet 10.7.0.6/16 brd 10.7.255.255 scope global eth1"; }
exit 0
S
chmod 755 "$BIN/ip"
out="$(run 'cmd_rescue bind 10.7.0.6')"
if grep -q '已切到 10.7.0.6' <<<"$out" \
   && grep -q 'ListenStream=10.7.0.6:'"$RP" "$BOX/etc/systemd/system/pdg-rescue.socket" \
   && grep -q 'ip daddr 10.7.0.6 ' "$BOX/etc/nftables.conf"; then
  ok "切换成功: unit 监听与 nft 规则的目的地址一起换到新值"
else bad "切换没生效: $(head -2 <<<"$out")"; fi
# 换地址**必须真的重启 socket**: unit 改了但 socket 不重启, systemd 仍监听旧地址, 而 nft
# 已经只放行新地址 —— 门在实机上就此不可达, 命令却报成功(.200 上正是这么翻的车)。
: > "$STATE/systemctl.log"
run 'cmd_rescue bind 10.7.0.5' >/dev/null
if grep -qE '^(restart|stop) .*pdg-rescue\.socket' "$STATE/systemctl.log"; then
  ok "换 bind 时真的重启了 socket(不是只改 unit 文件)"
else bad "没有重启 socket: $(tr '\n' '|' < "$STATE/systemctl.log" | cut -c1-90)"; fi
run 'cmd_rescue bind 10.7.0.6' >/dev/null
if [[ "$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf")" == 1 ]]; then
  ok "切换后旧规则被撤、新规则恰好一条(不是新旧并存)"
else bad "切换后有 $(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf") 条规则"; fi

# 失败回滚: 让 socket 起不来, bind / profile / unit / nft / 意图都要回到操作前
b1="$(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)"
u1="$(sha256sum "$BOX/etc/systemd/system/pdg-rescue.socket" | cut -d' ' -f1)"
n1="$(sha256sum "$BOX/etc/nftables.conf" | cut -d' ' -f1)"
i1="$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env")"
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
D="$PDG_TEST_STATE"; mkdir -p "$D"
v="$1"; shift; now=0; [[ "${1:-}" == "--now" ]] && { now=1; shift; }
case "$v" in
  daemon-reload|reset-failed|preset) exit 0;;
  enable)  [[ "$*" == *pdg-rescue.socket* ]] && exit 1
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
out="$(run 'cmd_rescue bind 10.7.0.5')"
if grep -q '回退' <<<"$out"; then ok "切换失败 → 明确说明回退"; else bad "失败没说回退: $(head -2 <<<"$out")"; fi
if [[ "$(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)" == "$b1" ]]; then
  ok "回退后 profile 里的 bind 是操作前的值"; else bad "bind 没退回: 现为 $(sed -n 's/^PDG_RESCUE_BIND=//p' "$BOX/etc/privdns-gateway/profile.env" | tail -1)"; fi
if [[ "$(grep '^PDG_RESCUE_ENABLED=' "$BOX/etc/privdns-gateway/profile.env")" == "$i1" ]]; then
  ok "回退后意图状态未变"; else bad "意图被改了"; fi
if [[ "$(grep -c 'comment "pdg-rescue"' "$BOX/etc/nftables.conf")" == 1 ]] \
   && grep -q "ip daddr $b1 " "$BOX/etc/nftables.conf"; then
  ok "回退后 nft 规则仍指向旧地址且恰好一条"; else bad "nft 没退回"; fi
if [[ "$(sha256sum "$BOX/etc/systemd/system/pdg-rescue.socket" | cut -d' ' -f1)" == "$u1" ]]; then
  ok "回退后 unit 逐字节回到操作前(监听地址没停在切换目标上)"
else bad "unit 没退回: $(grep ListenStream "$BOX/etc/systemd/system/pdg-rescue.socket")"; fi
if [[ "$(sha256sum "$BOX/etc/nftables.conf" | cut -d' ' -f1)" == "$n1" ]]; then
  ok "回退后 nftables.conf 逐字节回到操作前"; else bad "nftables.conf 没退回"; fi
# 复原桩
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
D="$PDG_TEST_STATE"; mkdir -p "$D"
echo "$*" >> "$D/systemctl.log"
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
run 'cmd_rescue enable' >/dev/null

# ══ 16c. CLI 分发把参数原样交给 cmd_rescue ═════════════════════════════════
echo; echo "── 16c. CLI 参数传递 ──"
# 前面所有小节都是直接调 cmd_rescue, **绕过了命令行分发那一行**。实机上就在这里翻了车:
# 分发写成 `cmd_rescue "$2"` 只传子命令, 于是 `pdg rescue bind 1.2.3.4` 拿不到地址,
# 而 `pdg rescue rotate cert` 更糟 —— 参数丢了以后默认成 token, 用户要求换证书, 实际换的
# 是 token(会话全断、指纹却没变)。这里跑**真正的 pdg.sh 分发行**, 只把 cmd_rescue 换成回显。
DISP="$WORK/disp.sh"
python3 - "$ROOT/deploy/bot/pdg.sh" "$DISP" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
i = t.rindex("\ncase ")            # 文件末尾的命令分发
stub = ('\nneed_root(){ :; }\n_rescue_load(){ :; }\n'
        'cmd_rescue(){ echo "RESCUE-ARGS:$*"; exit 0; }\n')
open(dst, "w", encoding="utf-8").write(t[:i] + stub + t[i:])
PY
for probe in "bind 10.9.8.7" "rotate cert" "rotate token" "status"; do
  got="$(bash "$DISP" rescue $probe 2>&1 | grep '^RESCUE-ARGS:' | head -1)"
  want="RESCUE-ARGS:$probe"
  if [[ "$got" == "$want" ]]; then ok "pdg rescue $probe → 参数原样送达($got)"
  else bad "pdg rescue $probe 参数丢了: 期望 '$want' 实得 '$got'"; fi
done

# ══ 16d. unit 模板改了, 迁移要把它刷到盘上 ═════════════════════════════════
echo; echo "── 16d. unit 刷新 ──"
# pdg update 只装运行模块, 不重渲染已安装的 unit —— 于是 unit 模板里的修复(硬化项、
# TimeoutStopSec、监听形态)永远到不了已经装好的机器: 改了等于没改。.200 实机上就是这样,
# TimeoutStopSec 一直是 systemd 默认的 90 秒。
run 'cmd_rescue enable' >/dev/null
U="$BOX/etc/systemd/system/pdg-rescue.socket"
# 把盘上的 unit 改旧(模拟"机器上装的是旧模板")
sed -i '/^FreeBind=/d' "$U"
if ! grep -q "^FreeBind=true" "$U"; then ok "(前提)盘上的 unit 已被改成缺少 FreeBind 的旧形态"
else bad "(前提)没造出旧 unit"; fi
run 'migrate_rescue_plane' >/dev/null
if grep -q "^FreeBind=true" "$U"; then
  ok "迁移把 unit 重新渲染到最新模板(否则 unit 层面的修复永远到不了已装机器)"
else bad "迁移没有刷新 unit: $(grep -c . "$U") 行, 仍缺 FreeBind"; fi
# 内容没变时不许瞎重启 —— 每次 update 都重启 socket 会平白打断可能正在服务的连接
: > "$STATE/systemctl.log"
run 'migrate_rescue_plane' >/dev/null
if ! grep -qE '^restart .*pdg-rescue\.socket' "$STATE/systemctl.log"; then
  ok "unit 没变化时迁移不重启 socket(不平白打断在用的连接)"
else bad "内容没变也重启了: $(tr '\n' '|' < "$STATE/systemctl.log" | cut -c1-80)"; fi

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

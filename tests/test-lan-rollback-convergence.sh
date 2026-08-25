#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 内网面板: 回滚后派生产物必须向已恢复的模型收敛, 且 render/apply 不许假成功。
#
# 背景(为什么这支测试存在):
#   /etc/privdns-gateway/{lan-panels.json, profile.env} 是**权威模型**, 两者都在全局
#   快照内, 回滚会把它们一起带回去。而三个**派生产物** —— /etc/pdg-lan/caddy.conf、
#   /etc/nftables-pdg-lan.conf、pdg-lan.service —— 都在快照之外, 回滚一个字节都不碰。
#   于是回滚之后模型是旧的、产物是新的, 两边各说各的:
#     · 白名单那半有人看着(check_lan_whitelist 逐条对账, 会判红);
#     · **反代那半没人看** —— Caddy 继续按旧配置服务着模型里已经不存在的面板, 全程零告警。
#
#   删面板方向尤其危险: 模型里没有了, 反代还在转发, 而出站白名单会被 doctor 判红 ——
#   现场看到的是"白名单多出一条", 真正的原因却在反代配置上。
#
# 这支测试**跑真的生产函数**(tests/lan-fixture.sh 从 pdg.sh 原样抽取), 不复制实现。
# 在 v1.10.15 基线上它必须红, 且每条失败都指向单一归因。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LAN_FX_SRC="$ROOT/deploy/bot/pdg.sh"
# shellcheck source=tests/lan-fixture.sh
source "$ROOT/tests/lan-fixture.sh"

PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)" || exit 1
cleanup(){ [[ -n "${PDG_KEEP_TMP:-}" ]] && { echo "现场保留: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

# 本轮新增的收敛入口: 基线上还不存在, 缺席要能被具名报出来而不是变成 127。
LAN_FX_OPTIONAL=(_lan_rollback_converge)

# 真 PEM: 生成物要交给**真 Caddy** 校验, 假证书会让校验在到达注入点前就失败(第一版栽过)。
export LAN_FX_PEM_DIR="$WORK/pem"
if ! lan_fx_make_pem "$LAN_FX_PEM_DIR"; then
  echo "[FAIL] 生成测试用 PEM 失败(缺 openssl?) —— 真 Caddy 校验这一条测不了, 不跳过"; exit 1
fi
CADDY_BIN="$(lan_fx_caddy "$ROOT" "$WORK")" || CADDY_BIN=""
if [[ -z "$CADDY_BIN" ]]; then
  echo "[FAIL] 拿不到 caddy(本地/PATH/按钉死 SHA 下载都不成) —— 这支要验真 Caddy 的行为, 不能跳过"; exit 1
fi

CLOSURE="$WORK/closure.sh"
if ! lan_fx_emit "$CLOSURE"; then
  echo "[FAIL] 生产函数闭包抽取失败 —— 后面的断言全部无效"; exit 1
fi

# ── 每格一个独立沙箱 ────────────────────────────────────────────────────────
# 共用现场的顺序测试迟早互相下毒(§8), 所以一格一个假根, 不复用。
new_box(){
  local w="$WORK/$1"; mkdir -p "$w"
  lan_fx_sandbox "$w"; lan_fx_stubs "$w"
  # 生产函数要 source 真仓库的 lib/units.sh 与 deploy/bot/lanpanel.py —— 用**影子仓库**:
  # 目录结构照搬, 内容软链到真仓库, 于是故障注入只需要替换其中一个文件。
  mkdir -p "$w/repo/deploy" "$w/repo/lib"
  ln -sfn "$ROOT/deploy/bot" "$w/repo/deploy/bot"
  cp "$ROOT/lib/units.sh" "$w/repo/lib/units.sh"
  echo "$w"
}

# 在沙箱里跑一段脚本, 回显退出码; 输出落到 $w/out.log。
run_box(){
  local w="$1" body="$2"
  ( set +e
    lan_fx_bind "$w" "$w/repo"
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$body"
  ) > "$w/out.log" 2>&1
  echo $?
}

# 三个派生产物的指纹(不存在记为 "-")
fp(){ [[ -e "$1" ]] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "-"; }
snap3(){ echo "$(fp "$1/etc/pdg-lan/caddy.conf") $(fp "$1/etc/nftables-pdg-lan.conf") $(fp "$1/etc/systemd/system/pdg-lan.service")"; }
# 凭据保全: 内容 + mode + uid:gid
credfp(){ local f="$1"; [[ -e "$f" ]] || { echo "-"; return; }; echo "$(sha256sum "$f" | cut -c1-16) $(stat -c '%a %u:%g' "$f")"; }
creds(){ echo "$(credfp "$1/etc/pdg-lan/dns.env") $(credfp "$1/etc/pdg-lan/certs/panel.crt") $(credfp "$1/etc/pdg-lan/certs/panel.key")"; }

echo "══ A. _lan_render: 三个产物要么一起换, 要么一个都不动 ══"

# ── A1/A2: unit 生成失败 ────────────────────────────────────────────────────
# 注入: 影子仓库的 units.sh 末尾追加一个恒失败的 pdg_unit_lan_caddy(后定义者胜)。
# 基线机制: `pdg_unit_lan_caddy … > "$LAN_UNIT" && chmod 644`, 重定向**先截断**再执行,
# 失败被 && 短路; 而函数最后一条是 `systemctl daemon-reload … || true` —— 恒为真。
W="$(new_box a1)"
echo 'pdg_unit_lan_caddy(){ return 1; }' >> "$W/repo/lib/units.sh"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
echo "OLDUNIT" > "$W/etc/systemd/system/pdg-lan.service"
before="$(fp "$W/etc/systemd/system/pdg-lan.service")"
rc="$(run_box "$W" '_lan_render')"
lan_fx_guard127 "$W/out.log" || bad "A 组: $(lan_fx_guard127 "$W/out.log")"
[[ "$rc" != 0 ]] && ok "A1 unit 生成失败 → _lan_render 返回非零($rc)" \
                 || bad "A1 unit 生成失败, _lan_render 仍返回 0 —— 假成功"
[[ "$(fp "$W/etc/systemd/system/pdg-lan.service")" == "$before" ]] \
  && ok "A2 unit 生成失败 → live unit 未被截断" \
  || bad "A2 live unit 被截断/改写(重定向直接打在正式文件上)"

# ── A3: nft 配置落盘失败 → 三文件回到前像 ───────────────────────────────────
W="$(new_box a3)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
echo "OLDCADDY" > "$W/etc/pdg-lan/caddy.conf"
echo "OLDNFT"   > "$W/etc/nftables-pdg-lan.conf"
echo "OLDUNIT"  > "$W/etc/systemd/system/pdg-lan.service"
before="$(snap3 "$W")"
chmod 444 "$W/etc/nftables-pdg-lan.conf"; chmod 555 "$W/etc"      # 只堵这一个落点
rc="$(run_box "$W" '_lan_render')"
chmod 755 "$W/etc"; chmod 644 "$W/etc/nftables-pdg-lan.conf"
if [[ "$rc" == 0 ]]; then
  bad "A3 nft 配置落盘失败, _lan_render 仍返回 0 —— 假成功"
else
  ok "A3 nft 配置落盘失败 → 返回非零($rc)"
fi
[[ "$(snap3 "$W")" == "$before" ]] \
  && ok "A3b 落盘失败后三个产物都回到前像" \
  || bad "A3b 落盘失败后留下半套状态: 前=[$before] 后=[$(snap3 "$W")]"

# ── A4: 候选校验失败 → 正式文件零改动 ───────────────────────────────────────
# 注入走 **nft 校验**而不是 caddy: _lan_render 里的 caddy 路径是写死的
# /usr/local/bin/caddy, PATH 桩拦不住它, 于是"有没有装 caddy"会让这一格的判据在
# 本机与 CI 上给出不同结果 —— 那正是 §9.10 那类环境依赖红。nft 走 PATH, 两边一致。
W="$(new_box a4)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
echo "OLDCADDY" > "$W/etc/pdg-lan/caddy.conf"; echo "OLDNFT" > "$W/etc/nftables-pdg-lan.conf"
echo "OLDUNIT" > "$W/etc/systemd/system/pdg-lan.service"
before="$(snap3 "$W")"; touch "$W/state/nft-check-fails"
rc="$(run_box "$W" '_lan_render')"
[[ "$rc" != 0 && "$(snap3 "$W")" == "$before" ]] \
  && ok "A4 候选校验失败 → 返回非零且正式文件零改动" \
  || bad "A4 候选(nft -c)校验失败后仍落了盘或返回 0(rc=$rc) —— 未做落盘前校验"

# ── A8: 生成物必须能过**真 Caddy** ──────────────────────────────────────────
W="$(new_box a8)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" \
  a:a.lan.test:192.168.100.10:80 b:b.lan.test:192.168.100.11:8080
rc="$(run_box "$W" '_lan_render')"
if [[ "$rc" == 0 ]] && "$CADDY_BIN" validate --config "$W/etc/pdg-lan/caddy.conf" --adapter caddyfile >"$W/caddyval.log" 2>&1; then
  ok "A8 生成的 caddy.conf 过真 Caddy 校验($("$CADDY_BIN" version 2>/dev/null | head -1))"
else
  bad "A8 生成物没过真 Caddy 校验(rc=$rc): $(tail -2 "$W/caddyval.log" 2>/dev/null | tr '\n' ' ')"
fi

# ── A5: 属组装不上不得静默降级 ──────────────────────────────────────────────
# 基线机制: `install -m640 -o root -g "$LAN_USER" … || install -m644 …`
# —— 属组装不上就悄悄换成 644 root:root, 而那份配置里有面板拓扑。
W="$(new_box a5)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
rc="$(run_box "$W" 'LAN_USER=pdg-nonexistent-user-for-test; _lan_render')"
if [[ "$rc" == 0 && -s "$W/etc/pdg-lan/caddy.conf" ]]; then
  mode="$(stat -c '%a' "$W/etc/pdg-lan/caddy.conf")"
  bad "A5 属组装不上仍报成功并落盘(mode=$mode) —— 静默降级"
else
  ok "A5 属组装不上 → 不静默降级(rc=$rc)"
fi

# ── A6: daemon-reload 失败必须传播 ──────────────────────────────────────────
W="$(new_box a6)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
touch "$W/state/reload-fails"
rc="$(run_box "$W" '_lan_render')"
[[ "$rc" != 0 ]] && ok "A6 daemon-reload 失败 → 返回非零" \
                 || bad "A6 daemon-reload 失败被 '|| true' 吞掉, 返回 0"

# ── A7: 失败路径不得留临时物 ────────────────────────────────────────────────
# 基线机制: 裸 mktemp 造的 $tmpc/$tmpn 与**派生的 $tmpc.err**, 没有 trap 兜底。
W="$(new_box a7)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
mytmp="$W/tmp"; mkdir -p "$mytmp"
touch "$W/state/nft-check-fails"
rc="$(run_box "$W" "export TMPDIR='$mytmp'; _lan_render")"
left="$(find "$mytmp" -mindepth 1 2>/dev/null | wc -l)"
# rc 必须非零 —— 否则这一格根本没走到失败路径, "零残留"是空测(§17.2 的空测判定)。
[[ "$rc" != 0 && "$left" == 0 ]] && ok "A7 失败路径(rc=$rc)临时物零残留" \
                   || bad "A7 失败路径未成立或有残留(rc=$rc, 残留 $left): $(find "$mytmp" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')"

echo "══ B. 应用层诚实性: 只生成不重启 = 磁盘对了进程没跟上 ══"

W="$(new_box b1)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" p1:p1.lan.test:192.168.100.10:80
echo "PDG_LAN_ENABLED=1" > "$W/etc/privdns-gateway/profile.env"
touch "$W/state/active" "$W/state/restart-fails"           # 反代在跑, 但重启会失败
rc="$(run_box "$W" '_lan_wire(){ return 0; }; _lan_sync_after_change')"
lan_fx_guard127 "$W/out.log" || bad "B 组: $(lan_fx_guard127 "$W/out.log")"
[[ "$rc" != 0 ]] && ok "B1 反代重启失败 → _lan_sync_after_change 返回非零" \
                 || bad "B1 反代重启失败被 '_lan_apply_proxy || true' 吞掉, 返回 0"
if grep -qE '✅.*(已同步|已生效)' "$W/out.log"; then
  bad "B2 反代重启失败却仍打印成功文案: $(grep -oE '✅[^"]*' "$W/out.log" | head -1)"
else
  ok "B2 反代重启失败时不打印成功文案"
fi

echo "══ C. 回滚后收敛 ══"

# 收敛入口在基线上不存在 —— 用包装器把"缺席"变成一条具名失败, 而不是 127。
CONV='converge(){ declare -F _lan_rollback_converge >/dev/null || { echo "缺少收敛入口 _lan_rollback_converge"; return 1; }; _lan_rollback_converge; }'

# ── C1: 删面板方向 ──────────────────────────────────────────────────────────
# 现场: 模型已被回滚成"两个面板", 而产物还是"三个面板"那一版。
W="$(new_box c1)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" \
  a:a.lan.test:192.168.100.10:80 b:b.lan.test:192.168.100.11:80
echo "PDG_LAN_ENABLED=1" > "$W/etc/privdns-gateway/profile.env"
touch "$W/state/active"
# 产物按"三面板"渲染(模型多一条 c), 渲完把模型换回两条 —— 这就是回滚后的现场
lan_fx_model "$W/stale.json" a:a.lan.test:192.168.100.10:80 b:b.lan.test:192.168.100.11:80 \
  c:c.lan.test:192.168.100.12:80
run_box "$W" "LAN_TABLE_PATH='$W/stale.json'; _lan_render" >/dev/null
before_creds="$(creds "$W")"
rc="$(run_box "$W" "$CONV; converge")"
routes="$(lan_fx_routes "$W/etc/pdg-lan/caddy.conf" | sort | tr '\n' ' ')"
# "应有"的路由用**同一个渲染器 + 同一个抽取器**现算, 不写死格式:
# 写死的话渲染器一改这条断言就悄悄失去意义, 而它看起来仍然是绿的。
WX="$(new_box c1want)"
lan_fx_model "$WX/etc/privdns-gateway/lan-panels.json" \
  a:a.lan.test:192.168.100.10:80 b:b.lan.test:192.168.100.11:80
run_box "$WX" '_lan_render' >/dev/null
want="$(lan_fx_routes "$WX/etc/pdg-lan/caddy.conf" | sort | tr '\n' ' ')"
[[ -n "$want" && "$routes" == "$want" ]] \
  && ok "C1 删面板后 caddy 路由收敛到已恢复的模型($routes)" \
  || bad "C1 caddy 路由未收敛: 现有=[$routes] 应为=[$want] (rc=$rc)"
if grep -q 'c.lan.test' "$W/etc/nftables-pdg-lan.conf" 2>/dev/null || grep -q '192.168.100.12' "$W/etc/nftables-pdg-lan.conf" 2>/dev/null; then
  bad "C1b 出站白名单仍留着已删面板的上游 —— 反代还能连到它"
else
  ok "C1b 出站白名单不再含已删面板的上游"
fi
[[ "$(creds "$W")" == "$before_creds" ]] \
  && ok "C1c 收敛全程未碰凭据(dns.env/证书: 内容+mode+属主逐项相同)" \
  || bad "C1c 凭据被改动: 前=[$before_creds] 后=[$(creds "$W")]"

# ── C2: 改上游方向 ──────────────────────────────────────────────────────────
W="$(new_box c2)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" a:a.lan.test:192.168.100.10:80
echo "PDG_LAN_ENABLED=1" > "$W/etc/privdns-gateway/profile.env"
touch "$W/state/active"
lan_fx_model "$W/stale.json" a:a.lan.test:192.168.100.99:8080
run_box "$W" "LAN_TABLE_PATH='$W/stale.json'; _lan_render" >/dev/null
rc="$(run_box "$W" "$CONV; converge")"
routes="$(lan_fx_routes "$W/etc/pdg-lan/caddy.conf" | tr '\n' ' ')"
[[ "$routes" == *"192.168.100.10:80"* && "$routes" != *"192.168.100.99"* ]] \
  && ok "C2 改上游后三产物回到已恢复的模型" \
  || bad "C2 上游未收敛: [$routes] (rc=$rc)"

# ── C3: enabled → disabled ──────────────────────────────────────────────────
W="$(new_box c3)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" a:a.lan.test:192.168.100.10:80
echo "PDG_LAN_ENABLED=0" > "$W/etc/privdns-gateway/profile.env"   # 回滚回到"停用"那一版
touch "$W/state/active" "$W/state/pdglan-table"
run_box "$W" "_lan_render" >/dev/null                              # 产物是启用态留下的
rc="$(run_box "$W" "$CONV; converge")"
if [[ -e "$W/state/active" ]]; then
  bad "C3 模型已回到停用态, 反代仍在跑 —— 未走正式停用路径"
else
  ok "C3 模型停用 → 反代已停(走既有 _lan_disable 语义)"
fi
[[ -e "$W/state/pdglan-table" ]] \
  && bad "C3b 停用后内核里仍留着 pdglan 表(残留)" \
  || ok "C3b 停用后 pdglan 表已撤"

# ── C4: disabled → enabled ──────────────────────────────────────────────────
W="$(new_box c4)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" a:a.lan.test:192.168.100.10:80
echo "PDG_LAN_ENABLED=1" > "$W/etc/privdns-gateway/profile.env"    # 回滚回到"启用"那一版
rm -f "$W/state/active"                                            # 但此刻反代没在跑
rc="$(run_box "$W" "$CONV; converge")"
if [[ -s "$W/etc/pdg-lan/caddy.conf" ]] && lan_fx_routes "$W/etc/pdg-lan/caddy.conf" | grep -q 'a.lan.test'; then
  ok "C4 模型启用 → 派生产物已按模型生成"
else
  bad "C4 模型启用, 但派生产物没生成(rc=$rc)"
fi

# ── C5: 从未启用过 → 必须 no-op, 且不得往 profile.env 写新键 ────────────────
W="$(new_box c5)"
echo "PDG_INTERNAL_CIDR=172.22.0.0/16" > "$W/etc/privdns-gateway/profile.env"
before="$(sha256sum "$W/etc/privdns-gateway/profile.env" | cut -c1-16)"
rc="$(run_box "$W" "$CONV; converge")"
after="$(sha256sum "$W/etc/privdns-gateway/profile.env" | cut -c1-16)"
if [[ "$rc" == 0 && "$before" == "$after" && ! -e "$W/etc/pdg-lan/caddy.conf" ]]; then
  ok "C5 从未启用过 → no-op, profile.env 一个字节没改"
else
  bad "C5 从未启用过却动了现场(rc=$rc, profile 变了=$([[ "$before" != "$after" ]] && echo 是 || echo 否))"
fi

# ── C6: 收敛失败必须说"不完整"并返回非零 ────────────────────────────────────
W="$(new_box c6)"
lan_fx_model "$W/etc/privdns-gateway/lan-panels.json" a:a.lan.test:192.168.100.10:80
echo "PDG_LAN_ENABLED=1" > "$W/etc/privdns-gateway/profile.env"
touch "$W/state/active"
run_box "$W" "_lan_render" >/dev/null
before="$(snap3 "$W")"
touch "$W/state/nft-check-fails"                                   # 让 render 必败
rc="$(run_box "$W" "$CONV; converge")"
[[ "$rc" != 0 ]] && ok "C6 收敛失败 → 返回非零" || bad "C6 收敛失败仍返回 0"
grep -qE 'LAN 回滚不完整|回滚不完整' "$W/out.log" \
  && ok "C6b 收敛失败明确报告「LAN 回滚不完整」" \
  || bad "C6b 收敛失败没有报出「LAN 回滚不完整」(现场只能靠猜)"
[[ "$(snap3 "$W")" == "$before" ]] \
  && ok "C6c 收敛失败后恢复本次调用前像" \
  || bad "C6c 收敛失败后留下半套状态"

echo "══ D. 调用点: 收敛必须在仓库复位之后跑 ══"

# 为什么按**执行顺序**判而不是 grep 一行: _lan_render 会 source "$REPO_DIR/lib/units.sh"
# 并经 _pdg_module 取 lanpanel.py, 而 REPO_DIR 在 cmd_rollback 的最后一步才被 git reset
# 复位。收敛若排在复位之前, 拿到的是**新版**生成器 + **旧版**模型 —— 半新半旧, 正是这一轮
# 要消除的东西, 而它在任何静态检查里都看不出来。
W="$(new_box d1)"
sed -n '/^cmd_rollback(){/,/^}/p' "$LAN_FX_SRC" > "$W/rollback.sh"
SNAP="$W/snapdir/20260101-000000"; mkdir -p "$SNAP/etc/privdns-gateway"
( cd "$W" && mkdir -p snaproot/etc/privdns-gateway && echo x > snaproot/etc/privdns-gateway/keep \
  && tar czf "$SNAP/snap.tar.gz" -C snaproot etc ) 2>/dev/null
cat > "$W/d.sh" <<EOF
SNAP_DIR="$W/snapdir"; REPO_DIR="$W/repo"; ORDER="$W/order.txt"; : > "\$ORDER"
LAN_UNIT="$W/etc/systemd/system/pdg-lan.service"; LAN_NFT_CONF="$W/etc/nftables-pdg-lan.conf"
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "\$*"; }; c_y(){ echo "\$*"; }
_pdg_mktemp_dir(){ mktemp -d; }
_snap_meta_commit(){ echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef; }
_snap_meta_label(){ echo l; }
_sb_panel_managed_on(){ return 1; }
_pdg_ios_verify_tree(){ return 0; }
_pdg_apply_snapshot_tree(){ echo MODEL >> "\$ORDER"; return 0; }
_nft_apply_main(){ return 0; }
_core_kernel_activate(){ return 0; }
pdg_write_unit(){ return 0; }; pdg_unit_mihomo(){ echo x; }
_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }
systemctl(){ return 0; }; nft(){ return 0; }
git(){ [[ "\$*" == *"reset --hard"* ]] && echo GITRESET >> "\$ORDER"; return 0; }
_lan_rollback_converge(){ echo CONVERGE >> "\$ORDER"; return 0; }
EOF
mkdir -p "$W/repo/.git" "$W/etc/privdns-gateway"
( set +e; source "$W/d.sh"; source "$W/rollback.sh"; cmd_rollback --dir "$SNAP" --git deadbeef ) \
  > "$W/d.log" 2>&1
order="$(tr '\n' ' ' < "$W/order.txt")"
if [[ "$order" != *CONVERGE* ]]; then
  bad "D1 回滚全程没有调用 LAN 收敛(顺序=[$order])"
elif [[ "$order" == *GITRESET*CONVERGE* ]]; then
  ok "D1 收敛排在仓库复位之后(顺序=[$order])"
else
  bad "D1 收敛跑在仓库复位**之前** —— 会拿新版生成器渲旧版模型(顺序=[$order])"
fi
if [[ "$order" == *MODEL*CONVERGE* ]]; then
  ok "D2 收敛排在模型恢复之后"
else
  bad "D2 收敛没排在模型恢复之后(顺序=[$order])"
fi
grep -q '内网面板派生产物' "$W/rollback.sh" \
  && ok "D3 收敛失败会计入未恢复项(不谎报完全回滚)" \
  || bad "D3 收敛失败没有计入 unrestored —— 会报成'✅ 已回滚'"

echo "─────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

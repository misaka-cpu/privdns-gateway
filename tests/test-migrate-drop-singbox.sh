#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# v1.6.0 回归: 旧 sing-box 机器迁到 mihomo(migrate_drop_singbox / _activate_mihomo_core)。
#
# 两件事必须成立:
#   ① 失败时说清**为什么**(承自 issue #1: 旧 switch-core 把三种完全不同的失败挤成一句
#      "渲染/校验失败", python 的 stderr 还被 2>/dev/null 丢掉 —— 用户拿不到任何线索);
#   ② 失败必须**返回非 0 且回滚 backend 标记**, 好让 run_all_migrations 把非 0 传给
#      cmd_update → 回滚到更新前快照(绝不把机器留在半迁移态, 也绝不静默丢出口)。
#   成功路径则要真把 sing-box 运行时清干净(unit + 二进制)并落定 backend=mihomo。
#
# 沙箱化: 抽出真实函数, 只把绝对路径字面量重定向到临时根, 其余打桩。
#
# 夹具的两条硬约束(都是踩出来的, 不是原则):
#   ① **不许联网**。v1.11.7 把 _activate_mihomo_core 的跳过判据从 pdg_mihomo_is_version
#      (只问自报版本、走 PATH)换成 pdg_mihomo_binary_ok(问绝对路径上的真文件 + 内容摘要)。
#      生产侧这是对的, 但本文件的 mihomo() 只是个 shell 函数桩、沙箱根里从来没有那个文件
#      —— 判据于是恒假, 这支测试从那时起**每跑一次就真去 GitHub 下 8 次 mihomo**。它不报错,
#      只是从"确定性测试"退化成"网络运气的函数", 直到 run 33455929038 撞上 connection reset
#      才红。现在沙箱根里播真的钉死版, 且 harness 里的 curl 是禁令桩: 谁再让它联网, 末尾
#      那条断言点名 URL。
#   ② **闭包不许漏桩**。漏掉的函数返回 127, 而 127 会被下游判据当成一个普通返回值吞掉——
#      _pdg_nft_foreign_input_chains 缺桩时正是如此: 它的契约是 0=有外来链、2=判不了、
#      其余=干净, 127 从 ==2 和 ==0 两个分支之间穿过去, 于是"迁移前发现别的 input base
#      chain 就必须中止"这道 P0 门在全部用例里都是空操作, 而测试照样 18/0。现在任何一次
#      command not found 都记硬失败, 这道门本身也有了正反用例。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
: > "$WORK/net.log"; : > "$WORK/notfound.log"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

sed -n '/^_pdg_singbox_is_ours(){/,/^}/p'   "$ROOT/deploy/bot/pdg.sh"  > "$WORK/fn.sh"
sed -n '/^_pdg_drop_singbox_files(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" >> "$WORK/fn.sh"
sed -n '/^_activate_mihomo_core(){/,/^}/p'   "$ROOT/deploy/bot/pdg.sh" >> "$WORK/fn.sh"
sed -n '/^migrate_drop_singbox(){/,/^}/p'    "$ROOT/deploy/bot/pdg.sh" >> "$WORK/fn.sh"
grep -q '^_activate_mihomo_core(){' "$WORK/fn.sh" || { echo "抽取 _activate_mihomo_core 失败"; exit 1; }
grep -q '^migrate_drop_singbox(){'  "$WORK/fn.sh" || { echo "抽取 migrate_drop_singbox 失败"; exit 1; }
grep -q '^_pdg_singbox_is_ours(){' "$WORK/fn.sh" || { echo "抽取归属助手失败"; exit 1; }
# 绝对路径 → 沙箱(控制流与变量引用一字未改)
sed -i -e 's#/etc/#$SB/etc/#g' -e 's#/opt/pdg-bot#$SB/opt/pdg-bot#g' \
       -e 's#/usr/local/bin/#$SB/usr/local/bin/#g' "$WORK/fn.sh"
# 归属判据里的 ExecStart 特征行是**目标机上的真实路径**, 不能被上面的沙箱重写改掉
sed -i -e 's#\$SB/usr/local/bin/sing-box run -c \$SB/etc/sing-box/config#/usr/local/bin/sing-box run -c /etc/sing-box/config#' "$WORK/fn.sh"
# 已经自己认 PDG_ROOT_PREFIX 的路径不要再叠一层沙箱前缀(叠了会变成 $SB$SB/… 而永远不存在,
# 断言就成了空转 —— 文件"没被删"只是因为函数压根没找到它)
sed -i -e 's#\$pfx\$SB/#$pfx/#g' -e 's#\${PDG_ROOT_PREFIX:-}\$SB/#${PDG_ROOT_PREFIX:-}/#g' "$WORK/fn.sh"

# ── 钉死版 mihomo 的来源(只找, 不取件) ───────────────────────────────────────
# 判据用生产那一个(pdg_mihomo_binary_ok), 不是"能跑就行": 自报版本对、内容不对的桩必须被拒。
MARCH="$(dpkg --print-architecture 2>/dev/null)"; [[ "$MARCH" == arm64 ]] || MARCH=amd64
_mihomo_ok(){   # $1=路径
  # shellcheck source=/dev/null
  ( . "$ROOT/lib/versions.sh" 2>/dev/null \
    && pdg_mihomo_binary_ok "$MARCH" "$MIHOMO_VER" "$1" ) >/dev/null 2>&1
}
MIHOMO_SRC=""
_find_mihomo(){
  local c
  for c in "${PDG_TEST_MIHOMO:-}" "$ROOT/tests/.bin/mihomo" /usr/local/bin/mihomo /opt/pdg-e2e-bin/mihomo; do
    [[ -n "$c" && -f "$c" ]] || continue
    _mihomo_ok "$c" && { MIHOMO_SRC="$c"; return 0; }   # 先验源: 只在装完验挡不住"装了个坏的"
  done
  return 1
}
if ! _find_mihomo; then
  # CI(PDG_TEST_STRICT=1)一律不取件: 件由 job 的「校验并安装钉定 mihomo」从本次 run 的
  # artifact 装好。在这里放一条"找不到就 curl 一把"的回退, 等于把每 run 一次取件的约束
  # 又放开成每 job 一次 —— 这支测试变回网络运气的函数, 正是这次要修掉的东西。
  if [[ -n "${PDG_TEST_STRICT:-}" ]]; then
    echo "[FAIL] 拿不到钉死版 mihomo($MARCH), 且严格模式下夹具不许自己取件。" >&2
    echo "       CI 应由「校验并安装钉定 mihomo」步骤备好; 本机跑: bash tests/prepare-mihomo.sh" >&2
    echo "通过 0, 失败 1"; exit 1
  fi
  # 开发者本机: 备一次件(走仓库既有的校验流程), 之后所有用例共用 tests/.bin/mihomo。
  bash "$ROOT/tests/prepare-mihomo.sh" >/dev/null 2>&1 || true
  _find_mihomo || { echo "[FAIL] 备件后仍拿不到钉死版 mihomo($MARCH)"; echo "通过 0, 失败 1"; exit 1; }
fi

mk(){   # $1=当前 backend 标记; 造出"仍是 sing-box 的老机器"现场
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/privdns-gateway" "$SB/etc/mihomo" "$SB/etc/sing-box" \
           "$SB/etc/systemd/system" "$SB/opt/pdg-bot" "$SB/usr/local/bin"
  printf '%s\n' "$1" > "$SB/etc/privdns-gateway/backend"
  printf '{}\n' > "$SB/etc/privdns-gateway/mitm.json"
  printf 'x\n'  > "$SB/etc/nftables.conf"
  printf 'y\n'  > "$SB/etc/mihomo/config.yaml"
  printf '%s\n' '{"inbounds":[{"type":"direct","tag":"in-https"},{"type":"direct","tag":"in-http"},{"type":"mixed","tag":"tg-proxy"}]}' \
    > "$SB/etc/sing-box/config.json"
  printf '#!/bin/sh\nexit 0\n' > "$SB/usr/local/bin/sing-box"; chmod 755 "$SB/usr/local/bin/sing-box"
  # 用**老版装机真正生成的** unit 形态(lib/units.sh 历史模板 pdg_unit_singbox), 否则归属
  # 判定认不出它是本项目的东西 —— 那正是第三方 sing-box 该走的分支, 不能拿它冒充自家的。
  cat > "$SB/etc/systemd/system/sing-box.service" <<'U'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
U
  # 沙箱根里放一份**真的**钉死版 mihomo。少了它, _activate_mihomo_core 的 pdg_mihomo_binary_ok
  # 判据恒假 → 每格用例都会真去 GitHub 下载(见文件头 ①)。装完再验一次: 只验源挡不住装坏。
  install -m755 "$MIHOMO_SRC" "$SB/usr/local/bin/mihomo" \
    || { echo "[FAIL] 播种 mihomo 到沙箱失败"; exit 1; }
  _mihomo_ok "$SB/usr/local/bin/mihomo" \
    || { echo "[FAIL] 播种后的 mihomo 过不了生产判据 pdg_mihomo_binary_ok"; exit 1; }
  export SB
}

harness(){ cat <<'EOF'
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
cmd_snapshot(){ :; }
dpkg(){ echo amd64; }
pdg_write_unit(){ :; }
systemctl(){ :; }
journalctl(){ echo "(stub journal)"; }
_switchcore_nft(){ return "${NFT_RC:-0}"; }
_core_kernel_activate(){ return "${ACTIVATE_RC:-0}"; }
_core_kernel_restore(){ :; }
_pdg_platform(){ echo android; }
pdg_verify_sha256(){ return 0; }
cp(){ command cp "$@" 2>/dev/null || true; }
# 迁移前那道 P0 硬门槛的判据源。它定义在 pdg.sh 里、却没被抽进 fn.sh —— 缺桩就是 127, 而
# 127 从 ==2 和 ==0 两个分支之间穿过去被当成"现场干净", 这道门就成了空操作(见文件头 ②)。
# 契约: 0=发现别的 input base chain, 2=读不到运行中 ruleset(判不了), 其余=干净。
# 默认给 1(干净), 好让既有用例的语义一字不变。
_pdg_nft_foreign_input_chains(){
  case "${FOREIGN_RC:-1}" in
    0) echo "table inet myfw (chain input, hook input priority filter 0)"; return 0;;
    2) echo "找不到 nftscan.py(判据脚本缺失), 无法确认防火墙链冲突"; return 2;;
    *) return 1;;
  esac
}
# 夹具不许联网(见文件头 ①)。这不是"挡一下", 是**记账 + 失败**: 谁让沙箱里的生产代码去取件,
# 末尾那条断言就把 URL 点出来。
curl(){ echo "curl $*" >> "$NETLOG"; echo "curl: 夹具禁止联网" >&2; return 7; }
# 回滚时把恢复出来的 nftables.conf 真正应用回内核。同样是 pdg.sh 里有、fn.sh 里没有的函数:
# 缺桩 = 127, 于是"回滚"只把文件拷回去、从没应用过, 而只看 backend 标记的断言照样绿。
_nft_apply_main(){ echo applied >> "$SB/nft-applied"; return "${NFT_APPLY_RC:-0}"; }
mihomo(){
  case "${1:-}" in
    -v) echo "Mihomo Meta $MIHOMO_VER";;   # 只服务按名字调的 -v; 跳过下载靠的是 mk() 播下的真二进制
    -t) [[ -n "${MIHOMO_T_FAIL:-}" ]] && { echo "$MIHOMO_T_ERR" >&2; return 1; }; return 0;;
  esac
  return 0
}
# 渲染预检: 由 RENDER_MODE 决定 python 的行为
python3(){
  case "${RENDER_MODE:-ok}" in
    ok)      return 0;;
    raise)   echo "渲染 mihomo 配置失败: ValueError: 出口 xyz 缺 server 字段" >&2; return 1;;
    unknown) echo "这些出口 mihomo 无法转换(迁移会凭空丢失): hy1-jp, ssr-tw" >&2; return 1;;
  esac
}
EOF
}

run(){  # $1=env $2=要调的函数
  local _o
  # shellcheck disable=SC2086
  _o=$(env SB="$SB" PDG_ROOT_PREFIX="$SB" NETLOG="$WORK/net.log" $1 bash -c "set -uo pipefail
REPO_DIR='$ROOT'
$(harness)
source '$ROOT/lib/versions.sh' 2>/dev/null
source '$WORK/fn.sh'
$2; echo \"RC=\$?\"" 2>&1)
  # 闭包漏桩 → 127, 会被下游判据当成普通返回值吞掉(见文件头 ②)。不管当格断言碰巧过不过,
  # 一律记账、末尾统一点名 —— 这条比任何单格断言都重要: 它盯的是"用例还在验东西"本身。
  grep -F 'command not found' <<<"$_o" >> "$WORK/notfound.log" 2>/dev/null || true
  printf '%s\n' "$_o"
}

# ── 1. 有出口无法转换 → 列出是哪几个出口 + 非0 + 回滚标记(绝不静默丢出口) ──
mk singbox
out=$(run "RENDER_MODE=unknown" migrate_drop_singbox)
{ grep -q 'hy1-jp' <<<"$out" && grep -q 'ssr-tw' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "转换失败: 逐个列出无法转换的出口名 + 返回非0(触发 update 回滚)" || bad "1: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == singbox ]] \
  && ok "转换失败: backend 标记已回滚(不留半迁移态)" || bad "1b: backend=$(cat "$SB/etc/privdns-gateway/backend")"
[[ -e "$SB/usr/local/bin/sing-box" && -e "$SB/etc/systemd/system/sing-box.service" ]] \
  && ok "转换失败: sing-box 运行时原样保留(用户仍可用旧版)" || bad "1c: sing-box 被误删"

# ── 2. 渲染抛异常 → 带出异常类型与信息 ──
mk singbox
out=$(run "RENDER_MODE=raise" migrate_drop_singbox)
{ grep -q 'ValueError' <<<"$out" && grep -q '缺 server 字段' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "渲染异常: 带出异常类型与原始信息 + 非0" || bad "2: out=$out"

# ── 2b/2c. 迁移前的 P0 硬门槛: 现场还有别的 input base chain → 动任何东西之前中止 ──
# (921e961) PDG 的 input chain 是 policy drop; 同一个 hook 上并存的别家 base chain 都会执行,
# 任一条 drop 包就没了 —— 用户的放行看着还在, 端口实际不通。这种失效比直接报错更难查, 所以
# 判据判不出干净就不许往下走。这道门在本文件里曾经是**空操作**: 判据函数既没抽也没打桩,
# 返回 127 穿过两个分支被当成"干净"(见文件头 ②), 全部用例照样绿。
mk singbox
out=$(run "RENDER_MODE=ok FOREIGN_RC=0" migrate_drop_singbox)
{ grep -q '检测到自定义 input base chain' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "有其它 input base chain: 中止迁移 + 非0" || bad "2b: out=$out"
{ [[ "$(cat "$SB/etc/privdns-gateway/backend")" == singbox ]] \
  && [[ -e "$SB/usr/local/bin/sing-box" && -e "$SB/etc/systemd/system/sing-box.service" ]] \
  && ! grep -q 'RC=0' <<<"$out"; } \
  && ok "有其它 input base chain: 现场未被改动(标记未翻, sing-box 运行时原样)" || bad "2b2: out=$out"

# 判不了 ≠ 干净: 读不到运行中的 ruleset(非 root / nft 不可用)时, 内存里的冲突链没进视野。
mk singbox
out=$(run "RENDER_MODE=ok FOREIGN_RC=2" migrate_drop_singbox)
{ grep -q '无法确认现场是否存在其它 input base chain' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "读不到运行中 ruleset: 按「无法确认」中止, 不当成干净" || bad "2c: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == singbox ]] \
  && ok "读不到运行中 ruleset: backend 未翻(现场未被改动)" || bad "2c2: backend=$(cat "$SB/etc/privdns-gateway/backend")"

# ── 3. mihomo -t 不过 → 带出 mihomo 自己的报错 ──
mk singbox
out=$(run "RENDER_MODE=ok MIHOMO_T_FAIL=1 MIHOMO_T_ERR=rule_9_is_invalid_xyz" migrate_drop_singbox)
{ grep -q 'rule_9_is_invalid_xyz' <<<"$out" && grep -q 'mihomo 配置校验失败' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "mihomo -t 失败: 带出内核真实报错 + 非0" || bad "3: out=$out"

# ── 4. nft 应用失败 → 回滚标记 + 非0 ──
mk singbox
out=$(run "RENDER_MODE=ok NFT_RC=1" migrate_drop_singbox)
{ grep -q 'nft 应用失败' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "nft 失败: 报明原因 + 非0" || bad "4: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == singbox ]] \
  && ok "nft 失败: backend 标记已回滚" || bad "4b"
[[ -s "$SB/nft-applied" ]] \
  && ok "nft 失败: 回滚把 nftables 真正应用回去了(不只是把文件拷回来)" || bad "4c: _nft_apply_main 没被调到"

# ── 5. 内核起不来 → 回滚并附上日志线索 ──
mk singbox
out=$(run "RENDER_MODE=ok ACTIVATE_RC=1" migrate_drop_singbox)
{ grep -q '已回滚' <<<"$out" && grep -q '最近日志' <<<"$out" && grep -q 'RC=1' <<<"$out"; } \
  && ok "内核起不来: 回滚 + 附内核日志线索 + 非0" || bad "5: out=$out"
[[ -e "$SB/usr/local/bin/sing-box" ]] \
  && ok "内核起不来: sing-box 二进制未删(还能退回去)" || bad "5b: sing-box 被误删"
[[ -s "$SB/nft-applied" ]] \
  && ok "内核起不来: 回滚把 nftables 真正应用回去了" || bad "5c: _nft_apply_main 没被调到"

# ── 6. 一切正常 → 迁移成功, sing-box 运行时清干净, backend 落定 mihomo ──
mk singbox
out=$(run "RENDER_MODE=ok" migrate_drop_singbox)
{ grep -q 'RC=0' <<<"$out" && grep -q 'sing-box 运行时已移除' <<<"$out"; } \
  && ok "正常路径: 迁移成功并明确告知已移除 sing-box" || bad "6: out=$out"
[[ "$(cat "$SB/etc/privdns-gateway/backend")" == mihomo ]] \
  && ok "正常路径: backend 落定 mihomo" || bad "6b: backend=$(cat "$SB/etc/privdns-gateway/backend")"
[[ ! -e "$SB/usr/local/bin/sing-box" ]] \
  && ok "正常路径: sing-box 二进制已删" || bad "6c: sing-box 二进制仍在"
[[ ! -e "$SB/etc/systemd/system/sing-box.service" ]] \
  && ok "正常路径: sing-box.service 已删" || bad "6d: unit 仍在"

# ── 7. 幂等: 已是纯 mihomo 的机器再跑一次 → 直接短路返回 0, 不重复迁移 ──
mk mihomo
rm -f "$SB/usr/local/bin/sing-box" "$SB/etc/systemd/system/sing-box.service"
out=$(run "RENDER_MODE=raise" migrate_drop_singbox)   # 渲染故意会炸: 短路了就压根不会调到
{ grep -q 'RC=0' <<<"$out" && ! grep -q 'ValueError' <<<"$out"; } \
  && ok "幂等: 已是纯 mihomo → 短路返回0(不重复迁移)" || bad "7: out=$out"

# ── 8. 归属保护: 机器上是**第三方**的 sing-box(不是本项目装的)→ 一律不删 ──
# 用户完全可能自己在跑一个 sing-box 干别的; 删掉别人的东西不可逆。
tp_unit(){ cat > "$SB/etc/systemd/system/sing-box.service" <<'U'
[Unit]
Description=sing-box service (third party, hand rolled)
[Service]
ExecStart=/opt/mysingbox/sing-box run -c /opt/mysingbox/my.json
U
}
mk singbox; tp_unit
out=$(run "RENDER_MODE=ok" migrate_drop_singbox)
{ [[ -e "$SB/etc/systemd/system/sing-box.service" ]] && [[ -e "$SB/usr/local/bin/sing-box" ]]; } \
  && ok "第三方 sing-box: 迁移完成后文件原样保留(不删别人的东西)" || bad "8: 第三方 sing-box 被删了"
grep -q '无法确认是本项目安装的' <<<"$out" \
  && ok "第三方 sing-box: 明确告知已保留 + 给出手工清理指引" || bad "8b: 没有保留提示: $out"

# backend 已是 mihomo 且只剩第三方 sing-box → 不该每次更新都去动它(也不重复迁移)
mk mihomo; tp_unit
out=$(run "RENDER_MODE=raise" migrate_drop_singbox)   # 渲染会炸: 真去迁移就会暴露
{ grep -q 'RC=0' <<<"$out" && ! grep -q 'ValueError' <<<"$out" \
  && [[ -e "$SB/etc/systemd/system/sing-box.service" ]]; } \
  && ok "已是 mihomo + 第三方 sing-box: 不重复迁移也不删它" || bad "8c: out=$out"

# 带归属标记的(本项目装的)→ 即便 unit 形态不匹配也认得出来, 该删就删
mk singbox; tp_unit; printf 'PDG-SINGBOX-OWNED v1\ncreated=2026-01-01T00:00:00Z\n' > "$SB/etc/privdns-gateway/singbox.pdg-owned"
out=$(run "RENDER_MODE=ok" migrate_drop_singbox)
[[ ! -e "$SB/etc/systemd/system/sing-box.service" ]] \
  && ok "带归属标记: 认定为本项目安装 → 正常清理" || bad "8d: 归属标记未生效"

# ── 夹具自证: 这支用例还是不是"确定性测试" ───────────────────────────────────
# 这两条不验业务, 只验前提。前提塌了的时候上面每一格都还能绿 —— 那正是要防的形态。
[[ ! -s "$WORK/net.log" ]] \
  && ok "全程零联网(沙箱里的 curl 一次都没被调到)" \
  || bad "夹具联网了, 用例已退化成网络运气的函数: $(sort -u "$WORK/net.log" | head -2 | tr '\n' ' ')"
[[ ! -s "$WORK/notfound.log" ]] \
  && ok "闭包完整: 一条 command not found 都没有(没有 127 被判据当普通返回值吞掉)" \
  || bad "闭包漏桩: $(grep -oE '[A-Za-z0-9_]+: command not found' "$WORK/notfound.log" | sort -u | tr '\n' ' ')"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

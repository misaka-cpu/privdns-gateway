#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役 · 老装升级迁移回归。
#
# 这一支管的是**已经装着 WLOC 的那台机器**。新装不装是一回事(那由清单决定), 老机器上服务
# 正跑着、劫持表里躺着 gs-loc、内核配置里有 MITM-OUT、盘上还有 CA —— 退役必须把这些真的
# 撤下来, 而不是只让新版本"不再提供功能"。
#
# 覆盖:
#   A. 全开现场: 停服务 → 撤劫持 → 撤路由 → 关配置 → 删模块与 unit; CA 按保留策略**不删**。
#   B. 幂等: 再跑一遍不动任何东西, 也不重启任何服务。
#   C. 从未配过 WLOC 的机器: 什么都不做, 返回 0(不是"没找到所以失败")。
#   D. 停不掉服务 → 具名非 0, 且**不删**模块文件(代码删了进程还在 = 一个没有源码可查的 MITM)。
#   E. 归属不清: 劫持表里有非 gs-loc 的域名(有人手工写过)→ 具名非 0, 一个字节都不改。
#   F. 渲染/校验失败 → 还原劫持表, 具名非 0。
#
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

c_g(){ :; }; c_y(){ :; }; c_r(){ :; }

# ── systemctl 打桩: 记账 + 可控的"停不下来" ──────────────────────────────────
SC_LOG="$WORK/systemctl.log"
systemctl(){
  echo "$*" >> "$SC_LOG"
  case "$1" in
    is-active) [[ -e "$WORK/state/$2.active" ]] && { echo active; return 0; }; echo inactive; return 3;;
    disable|stop) local svc="${*: -1}"
        [[ "$STUBBORN" == "$svc" ]] && return 0          # 假装停了, 其实没停(状态文件还在)
        rm -f "$WORK/state/$svc.active"; return 0;;
    *) return 0;;
  esac
}
export -f systemctl 2>/dev/null || true

# ── 重渲内核这一步打桩: 它在生产里要 /opt/pdg-bot, 测试只关心"调了没、失败怎么办" ──
RENDER_RC=0
_retire_rerender_core(){ echo "rerender" >> "$SC_LOG"; return "$RENDER_RC"; }

# 抽出被测函数与它的两个产品侧辅助。**不**抽 _retire_rerender_core: 那一个在生产里要
# /opt/pdg-bot 下的 bot 模块, 上面已经用打桩替代了它(本支关心的是"调了没、失败怎么办")。
for _fn in migrate_wloc_retire _retire_disable_wloc_json _retire_ca_report; do
  eval "$(sed -n "/^$_fn(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh")"
  declare -F "$_fn" >/dev/null || bad "pdg.sh 里抽不出 $_fn"
done
if ! declare -F migrate_wloc_retire >/dev/null; then
  bad "pdg.sh 里没有 migrate_wloc_retire —— 老装升级没有退役迁移可跑"
  echo; echo "[SUM] OK=$pass FAIL=$nfail"; exit 1
fi

# ── 现场构造 ────────────────────────────────────────────────────────────────
scene(){   # $1=名字  $2=enabled/disabled/never
  local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"/{etc/systemd/system,etc/mosdns/rules,etc/privdns-gateway/ca,opt/pdg-bot}
  mkdir -p "$WORK/state"; rm -f "$WORK/state"/*.active
  : > "$SC_LOG"
  export PDG_RETIRE_ROOT="$d"
  STUBBORN=""; RENDER_RC=0
  [[ "$2" == never ]] && return 0
  echo "[Unit]" > "$d/etc/systemd/system/pdg-mitm.service"
  : > "$d/opt/pdg-bot/mitm_server.py"; : > "$d/opt/pdg-bot/mitm_wloc.py"
  printf 'x' > "$d/etc/privdns-gateway/ca/ca.crt"; printf 'y' > "$d/etc/privdns-gateway/ca/ca.key"
  if [[ "$2" == enabled ]]; then
    touch "$WORK/state/pdg-mitm.active"
    printf 'domain:gs-loc.apple.com\ndomain:gs-loc-cn.apple.com\n' > "$d/etc/mosdns/rules/mitm_hijack.txt"
    printf '{"wloc":{"enabled":true,"active":"东京","locations":[{"name":"东京","lat":35.6,"lon":139.7}]}}\n' \
      > "$d/etc/privdns-gateway/mitm.json"
  else
    : > "$d/etc/mosdns/rules/mitm_hijack.txt"
    printf '{"wloc":{"enabled":false,"locations":[{"name":"东京","lat":35.6,"lon":139.7}]}}\n' \
      > "$d/etc/privdns-gateway/mitm.json"
  fi
}
D(){ echo "$WORK/$1"; }
jget(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('wloc',{}).get(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

# ══ A. 全开现场 ═════════════════════════════════════════════════════════════
echo "══ A. 全开现场 ══"
scene A enabled
migrate_wloc_retire; rcA=$?
d="$(D A)"
[[ $rcA -eq 0 ]] && ok "全开现场迁移成功(rc=0)" || bad "A: rc=$rcA"
grep -q 'disable --now pdg-mitm\|stop pdg-mitm' "$SC_LOG" && ok "停掉了 pdg-mitm 服务" || bad "A: 没停服务"
[[ ! -s "$d/etc/mosdns/rules/mitm_hijack.txt" ]] && ok "专属劫持表已清空" || bad "A: 劫持表还有内容"
[[ -e "$d/etc/mosdns/rules/mitm_hijack.txt" ]] && ok "劫持表文件本身仍在(mosdns 的 domain_set 指着它, 删了起不来)" \
  || bad "A: 劫持表文件被删了 —— mosdns 会因为 domain_set 找不到文件而起不来"
grep -q rerender "$SC_LOG" && ok "重渲了内核配置(撤 MITM 路由)" || bad "A: 没重渲内核"
[[ "$(jget "$d/etc/privdns-gateway/mitm.json" enabled)" == "False" ]] && ok "mitm.json 里 enabled 已置 false" \
  || bad "A: enabled 仍为 $(jget "$d/etc/privdns-gateway/mitm.json" enabled)"
python3 -c "
import json,sys
w=json.load(open(sys.argv[1]))['wloc']
sys.exit(0 if w.get('locations') else 1)" "$d/etc/privdns-gateway/mitm.json" \
  && ok "用户自己存的地点仍在(保留策略: 不清除历史数据)" || bad "A: 地点被删了 —— 那是用户数据"
[[ ! -e "$d/opt/pdg-bot/mitm_server.py" && ! -e "$d/opt/pdg-bot/mitm_wloc.py" ]] \
  && ok "退役模块已删除" || bad "A: 模块还在"
[[ ! -e "$d/etc/systemd/system/pdg-mitm.service" ]] && ok "pdg-mitm unit 已删除" || bad "A: unit 还在"
[[ -e "$d/etc/privdns-gateway/ca/ca.key" ]] \
  && ok "盘上的 CA 材料按保留策略留着(迁移只报告, 不替用户永久销毁)" || bad "A: CA 私钥被迁移删了"

# ══ B. 幂等 ═════════════════════════════════════════════════════════════════
echo; echo "══ B. 幂等 ══"
before="$(find "$d" -type f -printf '%P %s\n' | sort)"
: > "$SC_LOG"
migrate_wloc_retire; rcB=$?
after="$(find "$d" -type f -printf '%P %s\n' | sort)"
[[ $rcB -eq 0 ]] && ok "二次运行 rc=0" || bad "B: rc=$rcB"
[[ "$before" == "$after" ]] && ok "二次运行没有再改动任何文件" || bad "B: 文件又被改了"
# 幂等不只是"结果一样": 已经退役干净的机器上再跑一次不该重启 mosdns/mihomo ——
# 每台老机器升级都会跑到迁移, 白断一次 DNS 是真实代价。
grep -qE 'restart|rerender' "$SC_LOG" && bad "B: 无事可做却仍重启/重渲了服务" \
  || ok "无事可做 → 不重启也不重渲(不白断一次 DNS)"

# ══ C. 从未配过 ═════════════════════════════════════════════════════════════
echo; echo "══ C. 从未配过 WLOC ══"
scene C never
migrate_wloc_retire; rcC=$?
[[ $rcC -eq 0 ]] && ok "从未配过的机器 rc=0(不是「没找到所以失败」)" || bad "C: rc=$rcC"
grep -qE 'restart|rerender' "$SC_LOG" && bad "C: 没装过也重启了服务" || ok "没装过 → 零动作"

# ══ D. 停不掉服务 ═══════════════════════════════════════════════════════════
echo; echo "══ D. 服务停不掉 ══"
scene D enabled
STUBBORN=pdg-mitm
migrate_wloc_retire; rcD=$?
d="$(D D)"
[[ $rcD -ne 0 ]] && ok "停不掉服务 → 非 0(rc=$rcD)" || bad "D: 服务还在跑却报成功"
[[ -e "$d/opt/pdg-bot/mitm_server.py" ]] \
  && ok "停不掉就不删模块(代码删了进程还在 = 一个没有源码可查的 MITM 还在转发流量)" \
  || bad "D: 服务没停下来却把模块删了"

# ══ E. 归属不清 ═════════════════════════════════════════════════════════════
echo; echo "══ E. 劫持表里有非 gs-loc 的域名 ══"
scene E enabled
d="$(D E)"
printf 'domain:gs-loc.apple.com\ndomain:my-own-thing.example.com\n' > "$d/etc/mosdns/rules/mitm_hijack.txt"
sha_before="$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)"
migrate_wloc_retire; rcE=$?
[[ $rcE -ne 0 ]] && ok "归属不清 → 非 0(rc=$rcE)" || bad "E: 把不认识的域名一起清了却报成功"
[[ "$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)" == "$sha_before" ]] \
  && ok "归属不清时劫持表一个字节都没动" || bad "E: 劫持表被改了"

# ══ F. 重渲失败 ═════════════════════════════════════════════════════════════
echo; echo "══ F. 重渲内核失败 ══"
scene F enabled
d="$(D F)"
sha_before="$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)"
RENDER_RC=1
migrate_wloc_retire; rcF=$?
[[ $rcF -ne 0 ]] && ok "重渲失败 → 非 0(rc=$rcF)" || bad "F: 重渲失败却报成功"
[[ "$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)" == "$sha_before" ]] \
  && ok "重渲失败后劫持表已还原(不留「表清了但路由还在」的半截现场)" \
  || bad "F: 劫持表没还原 —— 现场是「DNS 不再劫持、内核路由还指着一个已停的服务」"

echo
echo "[SUM] OK=$pass FAIL=$nfail"
[[ $nfail -eq 0 ]]

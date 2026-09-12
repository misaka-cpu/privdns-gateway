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
# 回滚账本是个数组, 按函数抽取拿不到 —— 显式声明一份(与 pdg.sh 同名同义)。
_RETIRE_UNDO=()
_RETIRE_TMP=""

# ── systemctl 打桩 ──────────────────────────────────────────────────────────
# 三个可控旋钮, 各自对应一类真实故障:
#   STUBBORN     停不下来(被别的 unit 拉着 / 不是这个 unit 起的)
#   STOP_LEAVES  stop 之后落在某个**不是 inactive** 的状态 —— unknown / deactivating /
#                activating / failed。这几个都**不等于已停**: 进程可能还在, 端口可能还开着。
#   RESTART_FAIL 指名的服务重启失败
SC_LOG="$WORK/systemctl.log"
systemctl(){
  echo "$*" >> "$SC_LOG"
  local svc="${*: -1}"
  case "$1" in
    is-active)
        if [[ -n "$STOP_LEAVES" && -e "$WORK/state/$2.stopped" ]]; then
          echo "$STOP_LEAVES"; return 3
        fi
        [[ -e "$WORK/state/$2.active" ]] && { echo active; return 0; }
        echo inactive; return 3;;
    disable|stop)
        [[ "$STUBBORN" == "$svc" ]] && return 0          # 假装停了, 其实没停(状态文件还在)
        rm -f "$WORK/state/$svc.active"
        : > "$WORK/state/$svc.stopped"                   # 供 STOP_LEAVES 判定
        return 0;;
    start)
        rm -f "$WORK/state/$svc.stopped"; : > "$WORK/state/$svc.active"; return 0;;
    restart)
        [[ "$RESTART_FAIL" == "$svc" ]] && return 1
        : > "$WORK/state/$svc.active"; return 0;;
    *) return 0;;
  esac
}
export -f systemctl 2>/dev/null || true

# ── 重渲内核这一步打桩 ──────────────────────────────────────────────────────
# **只替换渲染那一次子进程调用**, 不替换被测逻辑。真模块参与的那一半由
# tests/test-wloc-retire-lock-handoff.sh 与 tests/test-wloc-retire-realrun.sh 负责 ——
# 本支要控制的是"调没调、失败怎么办", 那需要一个能按需失败的旋钮。
RENDER_RC=0
_retire_rerender_core(){ echo "rerender" >> "$SC_LOG"; return "$RENDER_RC"; }

# schema 迁移这一步也给一个旋钮: 它是整条链最靠后的一步, 拿它验"最后一步失败时前面
# 改过的每一样都要回去"。
SCHEMA_FAIL=""
_retire_ios_schema(){ echo "iosschema" >> "$SC_LOG"; [[ -n "$SCHEMA_FAIL" ]] && return 1; return 0; }

# 抽出被测函数与它的两个产品侧辅助。**不**抽 _retire_rerender_core / _retire_ios_schema:
# 它们在生产里都要起 /opt/pdg-bot 下的真模块, 上面用可控旋钮替代(本支关心的是编排:
# 顺序、判据、失败怎么恢复)。它们各自的真实行为由 lock-handoff 与 realrun 两支负责。
for _fn in _retire_svc_stopped _retire_core_has_mitm _retire_undo_push _retire_undo_run \
           _retire_track_file _retire_restore_file _retire_reload_svc _retire_track_svc \
           _retire_restore_svc _retire_cleanup _retire_fail _retire_report_ca \
           migrate_wloc_retire _retire_disable_wloc_json _retire_ca_report; do
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
  mkdir -p "$WORK/state"; rm -f "$WORK/state"/*.active "$WORK/state"/*.stopped
  : > "$SC_LOG"
  export PDG_RETIRE_ROOT="$d"
  STUBBORN=""; RENDER_RC=0; STOP_LEAVES=""; RESTART_FAIL=""; SCHEMA_FAIL=""
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

# ══ G. 归属与输入检查必须排在**动运行态之前** ═══════════════════════════════
echo; echo "══ G. 先检查, 再动手 ══"
# 现在的顺序是"先停服务, 再查劫持表归属"。于是一台劫持表被手工写过别的域名的机器, 会先被
# 停掉 pdg-mitm、再被告知"归属不清, 本次未做任何改动" —— 后半句是假话: 服务已经停了。
# 用户看到"未做任何改动"就不会去把它起回来, 而那台机器的 WLOC 从此半死不活。
scene G enabled
d="$(D G)"
printf 'domain:gs-loc.apple.com\ndomain:my-own-thing.example.com\n' > "$d/etc/mosdns/rules/mitm_hijack.txt"
: > "$SC_LOG"
migrate_wloc_retire; rcG=$?
[[ $rcG -ne 0 ]] && ok "归属不清 → 非 0" || bad "G: 归属不清却成功了"
grep -qE 'disable|stop' "$SC_LOG" \
  && bad "G: 说「未做任何改动」之前已经把服务停了 —— 检查没有排在动手之前" \
  || ok "归属不清时**一个 systemctl 都没调**(检查排在动运行态之前)"
[[ -e "$WORK/state/pdg-mitm.active" ]] && ok "G: 服务仍在跑(现场确实没被动过)" \
  || bad "G: 服务被停了, 而返回值说的是「未做任何改动」"

# ══ H. unknown / deactivating 不等于已停 ═══════════════════════════════════
echo; echo "══ H. 停止判据 ══"
# failed **不在**这份名单里: systemd 已经把进程收掉了, 那是它自己的语义; 而且一台
# pdg-mitm 早就崩着的机器如果因此永远升不上去, 才是真的把用户卡死。下面单独验它。
for st in unknown deactivating activating; do
  scene H enabled
  d="$(D H)"
  STOP_LEAVES="$st"          # stop 之后 is-active 落到这个状态
  migrate_wloc_retire; rcH=$?
  if [[ $rcH -ne 0 ]]; then
    ok "stop 之后 is-active=$st → 不当成已停(非 0)"
  else
    bad "H: is-active=$st 被当成停成功了"
  fi
  [[ -e "$d/opt/pdg-bot/mitm_server.py" ]] \
    && ok "stop 之后 is-active=$st → 没有继续删执行文件" \
    || bad "H: 没停稳却把执行文件删了 —— 一个没有源码可查的 MITM 还在转发"
  STOP_LEAVES=""
done
# failed = 已停(进程已被收掉)。这一格与上面三格相反, 必须放行 —— 否则崩着的机器升不上去。
scene H2 enabled
d="$(D H2)"
STOP_LEAVES="failed"
migrate_wloc_retire >/dev/null 2>&1; rcH2=$?
STOP_LEAVES=""
[[ $rcH2 -eq 0 ]] && ok "stop 之后 is-active=failed → 算已停(systemd 已收掉进程), 迁移照走" \
  || bad "H2: failed 被当成没停稳, 崩着的机器就永远升不上去了"

# ══ I. 空/缺失的劫持表不是"不必查旧路由"的理由 ═════════════════════════════
echo; echo "══ I. 空劫持表 + 内核里还留着 MITM 路由 ══"
# 一台机器可能劫持表已经空了(被手工清过、或上一次迁移清到一半), 而 mihomo 配置里那条
# MITM-OUT 还在。现在的实现只有"劫持表非空"才重渲 —— 于是这台机器的内核路由永远撤不掉,
# 而迁移每次都报成功。
scene I enabled
d="$(D I)"
: > "$d/etc/mosdns/rules/mitm_hijack.txt"                  # 表已经是空的
mkdir -p "$d/etc/mihomo"
printf '{"proxies":[{"name":"MITM-OUT","type":"socks5","server":"127.0.0.1","port":7894}],\n "rules":["DOMAIN-SUFFIX,gs-loc.apple.com,MITM-OUT","MATCH,DIRECT"]}\n' \
  > "$d/etc/mihomo/config.yaml"
: > "$SC_LOG"
migrate_wloc_retire; rcI=$?
[[ $rcI -eq 0 ]] && ok "I: 迁移完成(rc=0)" || bad "I: rc=$rcI"
grep -q rerender "$SC_LOG" \
  && ok "劫持表虽空, 仍然检查并重渲了内核(MITM 路由还在那儿)" \
  || bad "I: 劫持表为空就跳过了内核 —— 那条 MITM-OUT 路由永远撤不掉"

# 缺失(文件根本不在)同理
scene I2 enabled
d="$(D I2)"
rm -f "$d/etc/mosdns/rules/mitm_hijack.txt"
mkdir -p "$d/etc/mihomo"
printf '{"proxies":[{"name":"MITM-OUT"}],"rules":["DOMAIN-SUFFIX,gs-loc.apple.com,MITM-OUT"]}\n' \
  > "$d/etc/mihomo/config.yaml"
: > "$SC_LOG"
migrate_wloc_retire >/dev/null 2>&1
grep -q rerender "$SC_LOG" \
  && ok "劫持表文件缺失时同样去查内核路由" || bad "I2: 表缺失就跳过了内核"

# 反面: 内核里本来就没有 MITM 路由、劫持表也空 → 不该白重渲一次(白断 DNS)
scene I3 disabled
d="$(D I3)"
mkdir -p "$d/etc/mihomo"
printf '{"proxies":[],"rules":["MATCH,DIRECT"]}\n' > "$d/etc/mihomo/config.yaml"
: > "$SC_LOG"
migrate_wloc_retire >/dev/null 2>&1
grep -q rerender "$SC_LOG" \
  && bad "I3: 内核里本来就没有 MITM 路由却仍然重渲(白断一次 DNS)" \
  || ok "内核里没有 MITM 路由 → 不重渲(不白断 DNS)"

# ══ J. 重启失败不许被 || true 吞掉 ═════════════════════════════════════════
echo; echo "══ J. 重启 mosdns 失败 ══"
scene J enabled
d="$(D J)"
sha_before="$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)"
RESTART_FAIL="mosdns"
migrate_wloc_retire; rcJ=$?
RESTART_FAIL=""
[[ $rcJ -ne 0 ]] && ok "重启 mosdns 失败 → 非 0(没有被 || true 吞掉)" \
  || bad "J: 重启失败却报成功"
[[ "$(sha256sum "$d/etc/mosdns/rules/mitm_hijack.txt" | cut -d' ' -f1)" == "$sha_before" ]] \
  && ok "重启失败后劫持表已还原" || bad "J: 劫持表没还原"

# ══ K. 失败恢复要覆盖**实际被改过**的每一样 ════════════════════════════════
echo; echo "══ K. 失败时不留半截现场 ══"
# 失败点放在最靠后的那一步(schema 迁移), 此时服务已停、劫持已撤、路由已重渲、mitm.json 已改。
# "只把劫持表放回去就宣称零半状态"是不成立的 —— 那几样都被动过。
scene K enabled
d="$(D K)"
before_all="$(cd "$d" && find . -type f -exec sha256sum {} + | sort -k2)"
SCHEMA_FAIL=1
migrate_wloc_retire; rcK=$?
SCHEMA_FAIL=""
[[ $rcK -ne 0 ]] && ok "最后一步失败 → 非 0" || bad "K: 最后一步失败却报成功"
after_all="$(cd "$d" && find . -type f -exec sha256sum {} + | sort -k2)"
if [[ "$before_all" == "$after_all" ]]; then
  ok "失败恢复覆盖了**全部**被改过的东西(文件集与大小逐项相等)"
else
  bad "K: 留下了半截现场 —— $(diff <(echo "$before_all") <(echo "$after_all") | tr '\n' ' ' | cut -c1-160)"
fi
[[ -e "$WORK/state/pdg-mitm.active" ]] \
  && ok "失败恢复把服务也起回去了(它被这次迁移停过)" \
  || bad "K: 服务被停掉之后没恢复 —— 只恢复文件不算零半状态"

echo
echo "[SUM] OK=$pass FAIL=$nfail"
[[ $nfail -eq 0 ]]

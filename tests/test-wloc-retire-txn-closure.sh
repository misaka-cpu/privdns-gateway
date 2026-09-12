#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役迁移 · **事务闭环**。
#
# 前面几支管的是"该不该做"与"顺序对不对"。这一支只管一件事: **任一步失败之后, 现场要么原样,
# 要么完整恢复。** 不许留下 schema、文件、服务状态、运行态互相矛盾的现场。
#
# 判据刻意不看 systemctl 的调用记录, 也不只比磁盘文件 —— 那两样都证明不了"跑着的东西是哪一
# 份"。打桩的 systemctl 在每次 start/restart 时把当时的配置**快照**下来当作"已加载的运行配置",
# 于是"还原了文件但没让服务重新加载"这种半截现场会被逮住: 盘上是旧的, 跑着的还是新的。
#
# 用**真渲染器**(sandbox 里的真 bot.py)把 live mihomo 配置真的换掉, 再在后面的步骤注入失败。
# 全用桩的话, "新配置装上去了、旧配置回不来"这一类根本演不出来。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/helpers/wloc-retire-sandbox.sh
source "$HERE/helpers/wloc-retire-sandbox.sh"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# c_* 要**真的输出**: 有几格判的就是"有没有把话说出来"(CA 残留、撤信任提示)。
# 打成空操作的话那几格永远看不见文本, 于是它们既不会红也证明不了任何事。
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; c_r(){ echo "$*"; }

# ── systemctl 打桩: enabled 与 active **分开**建模, 并记录"已加载的运行配置" ──
# 沙箱里没有真 systemd。这里如实建模三件事, 其余一概不装:
#   · enabled / disabled               —— 开机自启, 与是否在跑无关
#   · active / inactive / failed / …   —— 运行状态
#   · 每次 start|restart 时把该服务读的那份配置**快照**下来 = "跑着的是哪一份"
# 真机上的停止、enabled 与恢复语义**不在本地验证范围**, 留给灰度清单。
SC_LOG=""
DAEMON_RELOAD_FAIL=""
RESTART_FAIL=""
STOP_LEAVES=""

_svc_conf(){   # 某个服务"读的那份配置"
  case "$1" in
    mihomo) echo "$SBOX/etc/mihomo/config.yaml";;
    mosdns) echo "$SBOX/etc/mosdns/rules/mitm_hijack.txt";;
    *)      echo "";;
  esac
}
_svc_snapshot(){   # 把当前配置快照成"已加载"
  local c; c="$(_svc_conf "$1")"
  [[ -n "$c" && -f "$c" ]] && sha256sum "$c" | cut -d' ' -f1 > "$SBOX/state/$1.loaded" \
    || : > "$SBOX/state/$1.loaded"
}
svc_loaded(){ cat "$SBOX/state/$1.loaded" 2>/dev/null; }
svc_enabled(){ cat "$SBOX/state/$1.enabled" 2>/dev/null || echo disabled; }
svc_active(){ cat "$SBOX/state/$1.state" 2>/dev/null || echo inactive; }
svc_set(){ echo "$2" > "$SBOX/state/$1.enabled"; echo "$3" > "$SBOX/state/$1.state"; _svc_snapshot "$1"; }

systemctl(){
  echo "$*" >> "$SC_LOG"
  local svc="${*: -1}"
  case "$1" in
    daemon-reload) [[ -n "$DAEMON_RELOAD_FAIL" ]] && return 1; return 0;;
    is-enabled) svc_enabled "$2"; [[ "$(svc_enabled "$2")" == enabled ]] && return 0; return 1;;
    is-active)  svc_active  "$2"; [[ "$(svc_active  "$2")" == active   ]] && return 0; return 3;;
    enable)  echo enabled  > "$SBOX/state/$svc.enabled"
             [[ "$2" == "--now" ]] && { echo active > "$SBOX/state/$svc.state"; _svc_snapshot "$svc"; }
             return 0;;
    disable) echo disabled > "$SBOX/state/$svc.enabled"
             [[ "$2" == "--now" ]] && echo "${STOP_LEAVES:-inactive}" > "$SBOX/state/$svc.state"
             return 0;;
    stop) echo "${STOP_LEAVES:-inactive}" > "$SBOX/state/$svc.state"; return 0;;
    start|restart)
      [[ "$RESTART_FAIL" == "$svc" ]] && { echo failed > "$SBOX/state/$svc.state"; return 1; }
      echo active > "$SBOX/state/$svc.state"; _svc_snapshot "$svc"; return 0;;
    reset-failed) return 0;;
    *) return 0;;
  esac
}
export -f systemctl 2>/dev/null || true
_pdg_core_svc(){ echo mihomo; }

# 被测的全是真的(systemctl 与 schema 子进程除外, 见各处说明)。
SCHEMA_FAIL=""
for _fn in _retire_svc_stopped _retire_core_has_mitm _retire_undo_push _retire_undo_run \
           _retire_track_file _retire_restore_file _retire_reload_svc _retire_track_svc \
           _retire_restore_svc _retire_cleanup _retire_fail _retire_report_ca \
           _retire_rerender_core _retire_ios_schema _retire_disable_wloc_json \
           _retire_ca_report migrate_wloc_retire; do
  eval "$(sed -n "/^$_fn(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh")"
  declare -F "$_fn" >/dev/null || bad "pdg.sh 里抽不出 $_fn"
done
_RETIRE_UNDO=()
# 真的那一份改名留着: schema 迁移本身是真跑的(它有自己的原子性), 这里只在需要时让它失败。
# `declare -f f` 打印的是 `f () \n{ … }`, 去掉函数名再拼上新名字就是一份同体的副本。
_REAL_IOS_SCHEMA_DEF="$(declare -f _retire_ios_schema)"
eval "_real_ios_schema${_REAL_IOS_SCHEMA_DEF#_retire_ios_schema}"
declare -F _real_ios_schema >/dev/null || bad "夹具: _retire_ios_schema 改名失败"
_retire_ios_schema(){
  echo "iosschema" >> "$SC_LOG"
  [[ -n "$SCHEMA_FAIL" ]] && return 1
  _real_ios_schema
}

machine(){   # $1 = pdg-mitm 的 enabled 状态, $2 = 运行状态
  sbox_new || return 1
  SC_LOG="$SBOX/systemctl.log"; : > "$SC_LOG"
  DAEMON_RELOAD_FAIL=""; RESTART_FAIL=""; STOP_LEAVES=""; SCHEMA_FAIL=""
  sbox_legacy_ios on Home >/dev/null || return 1
  echo ios > "$SBOX/etc/privdns-gateway/platform"
  printf 'domain:gs-loc.apple.com\ndomain:gs-loc-cn.apple.com\n' > "$SBOX/etc/mosdns/rules/mitm_hijack.txt"
  printf '{"wloc":{"enabled":true,"locations":[{"name":"东京","lat":35.6,"lon":139.7}]}}\n' \
    > "$SBOX/etc/privdns-gateway/mitm.json"
  : > "$SBOX/opt/pdg-bot/mitm_server.py"; : > "$SBOX/opt/pdg-bot/mitm_wloc.py"
  echo "[Unit]" > "$SBOX/etc/systemd/system/pdg-mitm.service"
  cat > "$SBOX/etc/sing-box/config.json" <<'JSON'
{"log":{"level":"warn"},"inbounds":[],
 "outbounds":[{"type":"direct","tag":"direct"},
              {"type":"shadowsocks","tag":"hkt","server":"1.2.3.4","server_port":8388,
               "method":"aes-128-gcm","password":"PW"}],
 "route":{"rules":[{"domain_suffix":["ex.test"],"outbound":"hkt"}],"final":"direct"}}
JSON
  cat > "$SBOX/etc/mihomo/config.yaml" <<'YAML'
{"proxies":[{"name":"MITM-OUT","type":"socks5","server":"127.0.0.1","port":7894,"udp":false}],
 "rules":["DOMAIN-SUFFIX,gs-loc.apple.com,MITM-OUT","MATCH,DIRECT"]}
YAML
  chmod 600 "$SBOX/etc/mihomo/config.yaml"
  svc_set pdg-mitm "$1" "$2"
  svc_set mihomo enabled active
  svc_set mosdns enabled active
  return 0
}

fid(){ stat -c '%a %u %g' "$1" 2>/dev/null; }
fsha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
run(){ ( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) >/dev/null 2>&1; }

# ══ 1. 晚期失败: 新 core 已经装上去了, 后面才炸 ═════════════════════════════
echo "══ 1. 真渲染器换掉 live core 之后注入晚期失败 ══"
for stage in daemon-reload schema; do
  machine enabled active || { bad "沙箱构造失败"; continue; }
  core_sha="$(fsha "$SBOX/etc/mihomo/config.yaml")"
  core_id="$(fid "$SBOX/etc/mihomo/config.yaml")"
  hij_sha="$(fsha "$SBOX/etc/mosdns/rules/mitm_hijack.txt")"
  mj_sha="$(fsha "$SBOX/etc/privdns-gateway/mitm.json")"
  meta_sha="$(fsha "$SBOX/etc/privdns-gateway/ios-profile.json")"
  cur_sha="$(fsha "$SBOX/var/lib/privdns-gateway/ios-profile/current.mobileconfig")"
  case "$stage" in
    daemon-reload) DAEMON_RELOAD_FAIL=1;;
    schema)        SCHEMA_FAIL=1;;
  esac
  run; rc=$?
  DAEMON_RELOAD_FAIL=""; SCHEMA_FAIL=""
  [[ $rc -ne 0 ]] && ok "[$stage] 注入失败 → 非 0" || bad "[$stage] 失败却报成功"
  # 磁盘
  [[ "$(fsha "$SBOX/etc/mihomo/config.yaml")" == "$core_sha" ]] \
    && ok "[$stage] 旧 mihomo 配置内容已恢复" || bad "[$stage] 旧 mihomo 配置没恢复"
  [[ "$(fid "$SBOX/etc/mihomo/config.yaml")" == "$core_id" ]] \
    && ok "[$stage] 旧 mihomo 配置的 mode/uid/gid 也恢复了" \
    || bad "[$stage] 权限没恢复: $(fid "$SBOX/etc/mihomo/config.yaml") ≠ $core_id"
  [[ "$(fsha "$SBOX/etc/mosdns/rules/mitm_hijack.txt")" == "$hij_sha" ]] \
    && ok "[$stage] 劫持表已恢复" || bad "[$stage] 劫持表没恢复"
  [[ "$(fsha "$SBOX/etc/privdns-gateway/mitm.json")" == "$mj_sha" ]] \
    && ok "[$stage] mitm.json 已恢复" || bad "[$stage] mitm.json 没恢复"
  [[ "$(fsha "$SBOX/etc/privdns-gateway/ios-profile.json")" == "$meta_sha" ]] \
    && ok "[$stage] iOS 记录未被改动" || bad "[$stage] iOS 记录被改了"
  [[ "$(fsha "$SBOX/var/lib/privdns-gateway/ios-profile/current.mobileconfig")" == "$cur_sha" ]] \
    && ok "[$stage] 带 CA 的产物还在(没被删掉)" || bad "[$stage] 产物被删了却没回来"
  # **运行态**: 不只看文件, 看跑着的是哪一份
  [[ "$(svc_loaded mihomo)" == "$core_sha" ]] \
    && ok "[$stage] mihomo **重新加载了旧配置**(跑着的与盘上一致)" \
    || bad "[$stage] 盘上是旧的而跑着的还是新的: loaded=$(svc_loaded mihomo)"
  [[ "$(svc_active mihomo)" == active ]] && ok "[$stage] mihomo 仍 active" \
    || bad "[$stage] mihomo 状态 $(svc_active mihomo)"
  [[ "$(svc_loaded mosdns)" == "$hij_sha" ]] \
    && ok "[$stage] 劫持表恢复后 mosdns **重新加载了**(跑着的是恢复后那份)" \
    || bad "[$stage] mosdns 仍跑着空表: loaded=$(svc_loaded mosdns)"
  [[ "$(svc_active mosdns)" == active ]] && ok "[$stage] mosdns 仍 active" \
    || bad "[$stage] mosdns 状态 $(svc_active mosdns)"
  [[ -e "$SBOX/opt/pdg-bot/mitm_server.py" ]] && ok "[$stage] 退役模块已恢复" \
    || bad "[$stage] 模块被删了没回来"
  sbox_rm
done

# ══ 2. 服务状态: enabled 与运行状态**分别**恢复 ═════════════════════════════
echo
echo "══ 2. enabled 与运行状态分别恢复 ══"
for combo in "enabled active" "enabled inactive" "enabled failed" "disabled inactive" "disabled active"; do
  # shellcheck disable=SC2086
  set -- $combo
  machine "$1" "$2" || { bad "沙箱构造失败"; continue; }
  SCHEMA_FAIL=1
  runout="$( ( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) 2>&1 )"
  SCHEMA_FAIL=""
  if [[ "$2" != active && "$2" != inactive ]]; then
    grep -q '复现不了' <<<"$runout" \
      && ok "原状态 $2: 输出里如实说明了复现不了" \
      || bad "原状态 $2 复现不了却没说: ${runout:0:120}"
  fi
  [[ "$(svc_enabled pdg-mitm)" == "$1" ]] \
    && ok "回滚后 enabled 状态恢复成 $1" \
    || bad "enabled 没恢复: 期望 $1 实得 $(svc_enabled pdg-mitm)"
  case "$2" in
    active|inactive)
      [[ "$(svc_active pdg-mitm)" == "$2" ]] \
        && ok "回滚后运行状态恢复成 $2(不是拿 start 冒充 enabled)" \
        || bad "运行状态没恢复: 期望 $2 实得 $(svc_active pdg-mitm)";;
    *)
      # failed **复现不出来**: 没有哪条 systemctl 能把服务变成 failed。要求"恢复成 failed"
      # 等于要求撒谎。判据改成两条真能成立的: 保持停止(这几种状态的共同事实), 且**如实说明**
      # 原状态复现不了 —— 假装还原了才是这一格真正要防的。
      [[ "$(svc_active pdg-mitm)" != active ]] \
        && ok "原状态 $2 复现不了 → 保持停止(没有假装起回来)" \
        || bad "原状态 $2 却把服务起起来了";;
  esac
  sbox_rm
done

# 停不稳的三种状态: 不得绕过判断继续删模块
echo
for st in deactivating activating unknown; do
  machine enabled active || { bad "沙箱构造失败"; continue; }
  STOP_LEAVES="$st"
  run; rc=$?
  STOP_LEAVES=""
  [[ $rc -ne 0 ]] && ok "stop 之后落到 $st → 非 0" || bad "$st 被当成停成功"
  [[ -e "$SBOX/opt/pdg-bot/mitm_server.py" ]] \
    && ok "落到 $st 时没有删模块" || bad "$st 却把模块删了"
  sbox_rm
done

# unit 文件缺失但模块残留、服务状态未知 → 仍要走归属判断, 不许直接删
echo
machine enabled active || bad "沙箱构造失败"
rm -f "$SBOX/etc/systemd/system/pdg-mitm.service"
STOP_LEAVES="unknown"
printf 'domain:gs-loc.apple.com\ndomain:someone-elses.example.com\n' \
  > "$SBOX/etc/mosdns/rules/mitm_hijack.txt"
run; rc=$?
STOP_LEAVES=""
[[ $rc -ne 0 ]] && ok "unit 缺失 + 状态未知 + 归属不清 → 拒绝" || bad "这种现场却成功了"
[[ -e "$SBOX/opt/pdg-bot/mitm_server.py" ]] \
  && ok "没有绕过归属判断去删模块" || bad "绕过归属判断删了模块"
sbox_rm

# ══ 3. schema 提交之后不许还有可失败的破坏性步骤 ═══════════════════════════
echo
echo "══ 3. schema 是最后一个提交点 ══"
machine enabled active || bad "沙箱构造失败"
DAEMON_RELOAD_FAIL=1
run >/dev/null 2>&1
DAEMON_RELOAD_FAIL=""
sc="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schema"])' \
      "$SBOX/etc/privdns-gateway/ios-profile.json" 2>/dev/null)"
[[ "$sc" == 1 ]] \
  && ok "daemon-reload 失败时 schema 尚未提交(它排在所有可失败的破坏性步骤之后)" \
  || bad "schema 已经提交(=$sc)而后面的步骤还会失败 —— 混合现场"
sbox_rm
# 成功路径上顺序自证: schema 必须是最后一条变更
machine enabled active || bad "沙箱构造失败"
run; rc=$?
[[ $rc -eq 0 ]] && ok "正常路径成功" || bad "正常路径失败"
last_mut="$(grep -nE 'iosschema|daemon-reload' "$SC_LOG" | tail -1)"
[[ "$last_mut" == *iosschema* ]] \
  && ok "调用序列里 schema 排在 daemon-reload **之后**(实得: ${last_mut#*:})" \
  || bad "schema 不是最后一步: ${last_mut:-无}"
sbox_rm

# ══ 4. 成功与失败两条路径都不留备份/候选/工作目录 ═══════════════════════════
echo
echo "══ 4. 清理 ══"
machine enabled active || bad "沙箱构造失败"
run
leftovers="$(find "$SBOX" -name '*.preretire.*' -o -name '*.cand' -o -name '*.tmp.retire*' 2>/dev/null)"
[[ -z "$leftovers" ]] && ok "成功路径: 没留下备份/候选文件" \
  || bad "成功路径残留: $(echo "$leftovers" | tr '\n' ' ')"
sbox_rm

machine enabled active || bad "沙箱构造失败"
SCHEMA_FAIL=1; run; SCHEMA_FAIL=""
leftovers="$(find "$SBOX" -name '*.preretire.*' -o -name '*.cand' -o -name '*.tmp.retire*' 2>/dev/null)"
[[ -z "$leftovers" ]] && ok "失败路径: 回滚之后也没留下备份/候选文件" \
  || bad "失败路径残留: $(echo "$leftovers" | tr '\n' ' ')"
sbox_rm

# 旧 live 配置**本来不存在**时, 切换失败不得留下新配置
machine enabled active || bad "沙箱构造失败"
rm -f "$SBOX/etc/mihomo/config.yaml"
RESTART_FAIL=mihomo
run; rc=$?
RESTART_FAIL=""
[[ $rc -ne 0 ]] && ok "旧 core 配置不存在 + 重启失败 → 非 0" || bad "该失败却成功"
[[ ! -e "$SBOX/etc/mihomo/config.yaml" ]] \
  && ok "本来没有的 live 配置, 切换失败后也没留下" \
  || bad "留下了一份本来不存在的 live 配置"
sbox_rm

# ══ 5. CA-only 残留: 其它都干净时仍要报告 ══════════════════════════════════
echo
echo "══ 5. 只剩 CA 材料 ══"
sbox_new || bad "沙箱构造失败"
SC_LOG="$SBOX/systemctl.log"; : > "$SC_LOG"
mkdir -p "$SBOX/state"; svc_set mihomo enabled active; svc_set mosdns enabled active
echo ios > "$SBOX/etc/privdns-gateway/platform"
: > "$SBOX/etc/mosdns/rules/mitm_hijack.txt"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$SBOX/etc/privdns-gateway/ca/ca.key" -out "$SBOX/etc/privdns-gateway/ca/ca.crt" \
  -days 30 -subj "/CN=PDG CA-only" >/dev/null 2>&1
out="$( ( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "只剩 CA 材料: rc=0" || bad "rc=$rc"
grep -q 'CA' <<<"$out" && ok "仍然报告了盘上还有 CA 材料" || bad "没报告 CA 残留: ${out:0:120}"
grep -qE '信任|证书信任设置' <<<"$out" \
  && ok "仍然提示到手机上手工撤销信任(网关做不到那一步)" || bad "没给撤信任提示"
[[ -e "$SBOX/etc/privdns-gateway/ca/ca.key" ]] && ok "私钥未被销毁(保留策略)" || bad "私钥被删了"
sbox_rm

echo
echo "[SUM] OK=$pass FAIL=$nfail"
[[ $nfail -eq 0 ]]

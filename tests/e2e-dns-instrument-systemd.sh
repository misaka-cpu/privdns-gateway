#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 仪器的**真 systemd 定点验收**。只验仪器与它的收尾 ——
# 不装退役候选、不跑 update、不跑迁移、不跑平台切换。
#
# 为什么还要这一支: 本地那支真二进制验证(tests/test-dns-instrument-real.sh)把 mosdns 当普通
# 进程起, 而 _dns_reload / dns_fix_conditions / dns_instrument_calibrate 里那几句
# `systemctl restart mosdns` + InvocationID 更替**从来没在真 systemd 上跑过**。这一支补的就是它。
#
# 被测的是验收脚本里那几个函数的**原文**(按名抽取, 不抄一份):
#   dns_probe / dns_probe_ok / dns_answer_of / _dns_reload / dns_expect /
#   dns_fix_conditions / dns_instrument_calibrate / dns_feature_probe / dns_verdict
# mosdns、配置加载、systemd、真实 DNS 查询都是真的; 只有**外围 DNS 上游**是自有可控端。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }
_hard(){ echo "[HARD-STOP] $1" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_ROOT="${E2E_ROOT:-$(cd "$HERE/.." && pwd)}"
ACC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
[[ -f "$ACC" ]] || _hard "找不到 $ACC"

# ── 硬门: 真 systemd / root / 真 systemctl / 钉死版 mosdns。任一条不成立就硬停, 不退回桩。──
[[ "$(cat /proc/1/comm)" == systemd ]] || _hard "PID 1 不是 systemd"
[[ "$(id -u)" == 0 ]] || _hard "要 root(要起 unit、改 /etc)"
SCTL="$(command -v systemctl)"; [[ -x "$SCTL" ]] || _hard "没有 systemctl"
[[ -x /usr/local/bin/mosdns ]] || _hard "没装 mosdns"
WANT_VER="$(grep -m1 '^MOSDNS_VER=' "$E2E_ROOT/lib/versions.sh" | cut -d'"' -f2)"
GOT_VER="$(/usr/local/bin/mosdns version 2>&1 | head -1)"
case "$GOT_VER" in "$WANT_VER"*) ok "硬门: mosdns 是钉死的那一版($GOT_VER)";; *) _hard "mosdns 版本 $GOT_VER ≠ 钉死的 $WANT_VER";; esac
command -v dig >/dev/null 2>&1 || _hard "没有 dig"
ok "硬门: PID1=systemd / root / 真 systemctl / 钉死版 mosdns 全部成立"

E2E_TMP="$(mktemp -d /tmp/dnsinst.XXXXXX)"
EVID="${PDG_REAL_MIG_EVID:-/tmp/dns-instrument-evidence}"; mkdir -p "$EVID"; chmod 700 "$EVID"
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }
DNS_STUB_PID=""
cleanup(){
  [[ -n "$DNS_STUB_PID" ]] && { kill "$DNS_STUB_PID" 2>/dev/null; wait "$DNS_STUB_PID" 2>/dev/null; }
  rm -rf "$E2E_TMP"
}
trap cleanup EXIT

# ── 夹具: 与两支验收脚本同一套播种 + 同一份 mosdns unit ──────────────────────
# shellcheck source=/dev/null
. "$E2E_ROOT/tests/e2e-lib.sh" || _hard "读不到 e2e-lib.sh"
e2e_seed_install    >/dev/null 2>&1 || _hard "e2e_seed_install 失败"
e2e_seed_mosdns all >/dev/null 2>&1 || _hard "e2e_seed_mosdns 失败"
cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now mosdns >/dev/null 2>&1
wait_stable(){   # $1=unit [$2=秒] —— 轮询到不是过渡态
  local u="$1" lim="${2:-25}" i=0 st
  while (( i < lim )); do
    st="$(systemctl is-active "$u" 2>/dev/null)"
    case "$st" in activating|deactivating|reloading) ;; *) printf '%s' "$st"; return 0;; esac
    sleep 1; i=$((i+1))
  done
  printf '%s' "$(systemctl is-active "$u" 2>/dev/null)"
}
[[ "$(wait_stable mosdns)" == active ]] || _hard "mosdns 没在真 systemd 下起来: $(journalctl -u mosdns -n 20 --no-pager 2>&1 | tail -10)"
ok "夹具: mosdns 以真 unit 起来了(all 形态, 与两支验收脚本同一套播种)"

# ── 抽验收脚本里那几个函数的原文 ────────────────────────────────────────────
_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in dns_probe dns_probe_ok dns_answer_of _dns_reload dns_expect \
         dns_fix_conditions dns_instrument_calibrate dns_feature_probe dns_verdict; do
  b="$(_fn "$ACC" "$f")"; [[ -n "$b" ]] || _hard "抽不到 $f"
  eval "$b"
done
eval "$(grep -E '^DNS_(U|H|UP_PORT|WITNESS|CONTROL)=' "$ACC")"
DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_CALIB_NAME=""
DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
c_keep_note(){ note "  自有恢复材料保留在 $E2E_TMP/hijack-calib.bak"; }
ok "前提: 九个函数都从验收脚本原文抽到(不是本支自己写的一份)"

HIJ=/etc/mosdns/rules/mitm_hijack.txt
SUM_BEFORE="$(sha256sum "$HIJ" | awk '{print $1}')"
MODE_BEFORE="$(stat -c %a "$HIJ")"; OWN_BEFORE="$(stat -c %u:%g "$HIJ")"

echo; echo "══ 一. 标定: 在真 systemd 上走一遍 ══"
INV0="$(systemctl show -p InvocationID --value mosdns)"
if dns_instrument_calibrate; then
  ok "1a: 标定通过(DNS_INSTRUMENT_OK=$DNS_INSTRUMENT_OK)"
else
  bad "1a: 标定没过 —— $DNS_CALIB_WHY"
fi
INV1="$(systemctl show -p InvocationID --value mosdns)"
[[ -n "$INV1" && "$INV1" != "$INV0" ]] \
  && ok "1b: 真 systemd 下 mosdns 实例确实更替过($INV0 → $INV1)" || bad "1b: 实例没换"
note "1b 说明: InvocationID 只证明**实例换了**; 加载的是不是预期配置由下面的真实查询回答。"
[[ "$DNS_INSTRUMENT_OK" == 1 ]] \
  && ok "1c: 同一查询名在真 systemd 上精确走出 U=$DNS_U → H=$DNS_H" || bad "1c: 没走出 U→H"

echo; echo "══ 二. 收尾: 磁盘与运行配置分别判定 ══"
{ [[ "$(sha256sum "$HIJ" | awk '{print $1}')" == "$SUM_BEFORE" \
   && "$(stat -c %a "$HIJ")" == "$MODE_BEFORE" && "$(stat -c %u:%g "$HIJ")" == "$OWN_BEFORE" ]]; } \
  && ok "2a: 接管表按内容 + mode + uid:gid 逐项还原" \
  || bad "2a: 没还原(sha/mode/owner: $(sha256sum "$HIJ"|awk '{print $1}') / $(stat -c '%a %u:%g' "$HIJ"))"
[[ "$DNS_RESTORE_DISK" == 1 && "$DNS_RESTORE_RUN" == 1 ]] \
  && ok "2b: 磁盘还原与**运行配置**还原都已确认(DISK=$DNS_RESTORE_DISK RUN=$DNS_RESTORE_RUN)" \
  || bad "2b: DISK=$DNS_RESTORE_DISK RUN=$DNS_RESTORE_RUN"
if dns_expect "$DNS_CALIB_NAME" "$DNS_U"; then
  ok "2c: 还原之后用**真实查询**确认运行配置回到未接管($DNS_U)"
else
  bad "2c: $DNS_CALIB_WHY"
fi

echo; echo "══ 三. 正式取证: 见证=H / 对照=U, 且前后一致 ══"
BEF="$(dns_feature_probe systemd-before)"
[[ "$BEF" == VALID* ]] && ok "3a: 前像观测有效" || bad "3a: 前像观测无效 —— $BEF"
systemctl restart mosdns >/dev/null 2>&1; wait_stable mosdns >/dev/null
AFT="$(dns_feature_probe systemd-after)"
_P="$P"; _F="$F"; dns_verdict "3" "$BEF" "$AFT"
[[ "$F" == "$_F" ]] && ok "3b: 重启之后前后像判据全绿(见证与对照都回到前像且符合 U/H)" \
                    || note "3b: 上面已按具名项报出, 不重复计数"

echo; echo "══ 四. 负控: 解析器停掉之后, 正式取证必须判无效而不是'文本相等所以通过' ══"
systemctl stop mosdns >/dev/null 2>&1
BAD1="$(dns_feature_probe systemd-dead-1)"; BAD2="$(dns_feature_probe systemd-dead-2)"
systemctl start mosdns >/dev/null 2>&1; wait_stable mosdns >/dev/null
[[ "$BAD1" == INVALID* && "$BAD2" == INVALID* ]] \
  && ok "4a: 解析器停掉时两次取证都判 INVALID" || bad "4a: 实得 $BAD1 / $BAD2"
_P="$P"; _F="$F"; dns_verdict "4" "$BAD1" "$BAD2" >"$E2E_TMP/v.out" 2>&1; P="$_P"; F="$_F"
grep -q '观测\*\*无效\*\*' "$E2E_TMP/v.out" \
  && ok "4b: 两份无效观测即使**逐字相等**也判红, 理由就是'观测无效'" \
  || { bad "4b: 没有以观测无效为由判红"; sed 's/^/      /' "$E2E_TMP/v.out"; }

echo; echo "══ 五. 本轮自有资源清理 ══"
[[ -n "$DNS_STUB_PID" ]] && kill -0 "$DNS_STUB_PID" 2>/dev/null \
  && ok "5a: 自有 DNS 上游按登记的 PID 在管(退出时按 PID 收, 不按名字宽杀)" \
  || note "5a: 自有上游已不在(可能已退出)"

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]

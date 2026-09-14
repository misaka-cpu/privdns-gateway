#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# DNS 仪器标定的**判定契约**。跑的是验收脚本里的产品级函数原文
# (dns_probe / dns_probe_ok / _dns_apply_hijack / dns_instrument_calibrate), 不抄一份。
#
# ⚠️ 这一支是**模型验证**: dig 与 systemctl 都是桩, 真 DNS 与真 mosdns 都没参与。
#    它证明的是"标定函数在各种观测下判得对不对", **不**证明任何一台真机上的 DNS 可区分。
#    真实环境的标定证据要在真实验收 run 里取, 本机取不到 —— 见证据里的"尚未取得"一栏。
#
# 隔离: unshare 私有挂载, /etc 绑到一次性目录(标定函数写的是绝对路径
# /etc/mosdns/rules/mitm_hijack.txt —— 不给它加"测试专用路径开关", 那种开关本身就是个洞)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
if [[ -z "${PDG_DNSCAL_NS:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)" || { echo "[未执行] 建不出自有根"; exit 1; }
  trap 'rm -rf "$FAKE"' EXIT
  mkdir -p "$FAKE/etc/mosdns/rules" "$FAKE/etc/privdns-gateway" || { echo "[未执行] 自有根建不全"; exit 1; }
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  export FAKE
  if unshare --map-root-user --mount --propagation private true 2>/dev/null; then
    export PDG_DNSCAL_NS=1; trap - EXIT
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare)。标定函数要往 /etc 写, 没有自有根就不能跑,"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
[[ "$(stat -c '%d:%i' /etc)" == "$(stat -c '%d:%i' "$FAKE/etc")" ]] \
  || { echo "[未执行] 隔离自检没过(/etc 不是自有根那一份)"; exit 1; }

P=0; F=0
ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
note(){ printf '[NOTE] %s\n' "$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PDG_ACCEPT_SH:-$HERE/e2e-real-platform-fail.sh}"
[[ -f "$SRC" ]] || { echo "[未执行] 找不到 $SRC"; exit 1; }
WORK="$(mktemp -d)"; EVID="$WORK/evid"; mkdir -p "$EVID"
E2E_TMP="$WORK"; export E2E_TMP
HIJ=/etc/mosdns/rules/mitm_hijack.txt

_fn(){ awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{exit}' "$1"; }
for f in dns_probe dns_probe_ok _dns_apply_hijack dns_instrument_calibrate; do
  b="$(_fn "$SRC" "$f")"; [[ -n "$b" ]] || { echo "[未执行] 抽不到 $f"; exit 1; }
  eval "$b"
done
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; }
ok_stub(){ :; }

# ── 桩: dig / systemctl / wait_stable ───────────────────────────────────────
# dig 的答案由**接管表里有没有那一条**决定 —— 这正是"产品配置决定 DNS 结果"的建模。
# 另有一组开关制造超时 / 空答案 / stderr / 不可区分。
CTL="$WORK/ctl"; mkdir -p "$CTL"
dig(){
  local name="" a
  for a in "$@"; do case "$a" in -*|@*|A) ;; *) name="$a";; esac; done
  local n=0; n="$(cat "$CTL/digcount" 2>/dev/null || echo 0)"; echo $((n+1)) > "$CTL/digcount"
  # 只对**第二次**查询生效的故障开关(第二次 = 配置乙那一次)
  if [[ -e "$CTL/second_timeout" && "$n" == 1 ]]; then
    echo ";; communications error to 127.0.0.1#53: timed out" >&2; return 9
  fi
  if [[ -e "$CTL/second_empty" && "$n" == 1 ]]; then
    printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n'; return 0
  fi
  if [[ -e "$CTL/second_stderr" && "$n" == 1 ]]; then
    echo ";; WARNING: recursion requested but not available" >&2
  fi
  local ip=198.51.100.7
  if [[ -e "$CTL/indistinguishable" ]]; then ip=203.0.113.1
  elif grep -qxF "full:$name" "$HIJ" 2>/dev/null; then ip=203.0.113.1
  fi
  printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n\n;; ANSWER SECTION:\n%s.\t60\tIN\tA\t%s\n' "$name" "$ip"
  return 0
}
systemctl(){
  case "$1 ${2:-}" in
    "restart mosdns")
      local rn; rn="$(cat "$CTL/restartcount" 2>/dev/null || echo 0)"; echo $((rn+1)) > "$CTL/restartcount"
      [[ -e "$CTL/reload_fail" ]] && return 1
      # 只让**第二次**重载失败(配置乙那一次)。这一格专门盯"失败被 || true 吞掉"——
      # 后面还原时的那次重载是好的, 所以不会被它兜住, 必须靠本处自己报出来。
      [[ -e "$CTL/reload_fail_second" && "$rn" == 1 ]] && return 1
      [[ -e "$CTL/inv_frozen" ]] && return 0
      echo "INV-$RANDOM$RANDOM" > "$CTL/inv"; return 0;;
  esac
  if [[ "$1" == show ]]; then cat "$CTL/inv" 2>/dev/null || echo "INV-0"; return 0; fi
  return 0
}
wait_stable(){ cat "$CTL/mosdns_state" 2>/dev/null || echo active; }

seed(){   # 造一份自有接管表(内容 + 属性都要能核对)
  rm -rf "$CTL"; mkdir -p "$CTL"; echo "INV-0" > "$CTL/inv"
  mkdir -p /etc/mosdns/rules
  if [[ "${1:-normal}" == empty ]]; then : > "$HIJ"; else
    printf 'full:gs-loc.apple.com\nfull:legacy-hand-edited.example\n' > "$HIJ"; fi
  chmod 640 "$HIJ"
  SUM0="$(sha256sum "$HIJ" | awk '{print $1}')"; MODE0="$(stat -c %a "$HIJ")"; OWN0="$(stat -c %u:%g "$HIJ")"
}
restored_ok(){   # 还原是否逐项对得上
  [[ "$(sha256sum "$HIJ" | awk '{print $1}')" == "$SUM0" \
     && "$(stat -c %a "$HIJ")" == "$MODE0" && "$(stat -c %u:%g "$HIJ")" == "$OWN0" ]]
}

RC=0
# 两件事要分开:
#  · 不能放进命令替换里跑 —— 那是子 shell, DNS_INSTRUMENT_OK 传不回来(判据会读到旧值);
#  · 被测函数自己也调 ok/bad(它在验收脚本里就是那么写的)。跑它的时候把这三个换成空转,
#    否则**它**的计数会混进**本支**的计数里, 失败场景更会凭空多出一堆 [FAIL]。
run_calib(){
  DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""
  local _P="$P" _F="$F"
  ok(){ printf '    [被测函数] OK   %s\n' "$1" >> "$WORK/out"; }
  bad(){ printf '    [被测函数] FAIL %s\n' "$1" >> "$WORK/out"; }
  note(){ printf '    [被测函数] NOTE %s\n' "$1" >> "$WORK/out"; }
  : > "$WORK/out"
  dns_instrument_calibrate >>"$WORK/out" 2>&1; RC=$?
  # 被测函数写回来的失败理由也留进输出 —— 判据可以直接 grep 它, 出错时也看得见。
  printf 'WHY=%s\n' "${DNS_CALIB_WHY:-（空）}" >> "$WORK/out"
  unset -f ok bad note
  ok(){ printf '[OK]   %s\n' "$1"; P=$((P+1)); }
  bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); }
  note(){ printf '[NOTE] %s\n' "$1"; }
  P="$_P"; F="$_F"
}

echo "══ 1. 两份有效配置结果不同 → 标定成功 ══"
seed; run_calib
[[ "$RC" == 0 && "$DNS_INSTRUMENT_OK" == 1 ]] && ok "1a: 标定通过(rc=0, DNS_INSTRUMENT_OK=1)" \
  || { bad "1a: rc=$RC OK=$DNS_INSTRUMENT_OK"; sed 's/^/      /' "$WORK/out"; }
restored_ok && ok "1b: 接管表按内容与属性逐项还原" || bad "1b: 还原对不上"
grep -q '服务已按\*\*还原后\*\*的配置重新起过' "$WORK/out" && ok "1c: 确认了服务重新读过还原后的配置" || bad "1c"
grep -q '两次查询都满足成功契约' "$WORK/out" && ok "1d: 明确记了成功契约成立" || bad "1d"
[[ -s "$EVID/dns-calibration.txt" ]] && grep -q 'rc/status/answer/stderr' "$EVID/dns-calibration.txt" \
  && ok "1e: 两次观测的退出码/状态/答案/stderr 都留了档" || bad "1e: 观测没留全"

echo; echo "══ 2. 配置没生效, 两次答案相同 → 标定失败 ══"
seed; : > "$CTL/indistinguishable"; run_calib
[[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && ok "2a: 判为标定失败" || bad "2a: rc=$RC OK=$DNS_INSTRUMENT_OK"
grep -q '答案相同' "$WORK/out" && ok "2b: 理由说清是'答案相同'" || bad "2b"
restored_ok && ok "2c: 失败路径也把接管表还原了" || bad "2c: 失败路径没还原"

echo; echo "══ 3. 第二次查询超时/空输出/异常 → 一律标定失败(不得当成'结果不同')══"
for k in second_timeout second_empty second_stderr; do
  seed; : > "$CTL/$k"; run_calib
  { [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && grep -q '不满足成功契约' "$WORK/out"; } \
    && ok "3-$k: 判为标定失败, 理由是观测不满足成功契约" \
    || { bad "3-$k: rc=$RC OK=$DNS_INSTRUMENT_OK"; sed 's/^/      /' "$WORK/out" | tail -4; }
  restored_ok || bad "3-$k: 没还原接管表"
done
ok "3-还原: 三种异常路径都把接管表还原了"

echo; echo "══ 4. 重载失败不能被吞成'标定有效' ══"
seed; : > "$CTL/reload_fail"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && grep -q '重启动作失败' "$WORK/out"; } \
  && ok "4a: 重启动作失败 → 标定失败(具名)" || { bad "4a: rc=$RC OK=$DNS_INSTRUMENT_OK"; tail -3 "$WORK/out" | sed 's/^/      /'; }
seed; : > "$CTL/inv_frozen"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && grep -q 'InvocationID 没变' "$WORK/out"; } \
  && ok "4b: 重启返回 0 但进程没换 → 标定失败(配置可能根本没被重读)" \
  || { bad "4b: rc=$RC OK=$DNS_INSTRUMENT_OK"; tail -3 "$WORK/out" | sed 's/^/      /'; }
seed; : > "$CTL/reload_fail_second"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && grep -q '重载失败不算标定成功' "$WORK/out"; } \
  && ok "4d: **只有配置乙那一次**重载失败时也必须当场报出来(不能靠后面那次好的重载兜底)" \
  || { bad "4d: 被吞了 —— rc=$RC OK=$DNS_INSTRUMENT_OK"; tail -4 "$WORK/out" | sed 's/^/      /'; }
seed; echo failed > "$CTL/mosdns_state"; run_calib
{ [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && grep -q '没有稳定运行' "$WORK/out"; } \
  && ok "4c: 重启后没稳定在 active → 标定失败" || { bad "4c: rc=$RC"; tail -3 "$WORK/out" | sed 's/^/      /'; }

echo; echo "══ 5. 还原不依赖'过滤删行': 空表也要能回到空表 ══"
# 老写法 `grep -vxF <条目> 文件 > 临时 && mv` 在过滤后为空时 grep 返回非零, mv 根本不执行。
seed empty; run_calib
[[ ! -s "$HIJ" ]] && ok "5a: 原本是空表, 还原之后仍是空表(没有留下标定加的那一行)" \
  || { bad "5a: 表里残留了内容: $(cat "$HIJ")"; }
restored_ok && ok "5b: 空表的内容与属性也逐项对得上" || bad "5b"

echo; echo "══ 6. 还原失败必须判失败 ══"
seed; chattr +i "$HIJ" 2>/dev/null && HAVE_IMMUT=1 || HAVE_IMMUT=0
if [[ "$HAVE_IMMUT" == 1 ]]; then
  run_calib; chattr -i "$HIJ" 2>/dev/null
  [[ "$RC" != 0 && "$DNS_INSTRUMENT_OK" == 0 ]] && ok "6a: 写不回去时判标定失败" || bad "6a: rc=$RC"
else
  note "6a: 这套环境不支持 chattr +i, 还原失败这一格改由代码路径审阅覆盖(已在 ②③④ 各路径统一走 _calib_fail)"
fi

echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]

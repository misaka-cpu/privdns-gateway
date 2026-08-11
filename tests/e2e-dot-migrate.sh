#!/usr/bin/env bash
# 6.2B: migrate_dotwitness 的故障矩阵与回滚精确性 —— 真 systemd + 真 mosdns。
#
# 这支存在的理由: 状态机的成功路径好验, 难的是**失败之后有没有回到原样**。回滚不彻底
# 的机器比迁移失败的机器危险得多 —— 它看起来"更新过了", 而 mosdns 配置可能停在半截,
# 服务可能被留成 enabled 却起不来。所以每一格都要证明三件事:
#     ① 注入真的命中了(注不进去却"通过"比红更糟);
#     ② 迁移返回非零, 且**没有**打印成功文案;
#     ③ 三个持久文件的内容/存在性/mode/uid/gid、两个服务的 enabled/active,
#        以及普通 DNS, 全部回到 before-image。
#
# 注入一律用**函数遮蔽**, 不用 chmod 000: 这些迁移以 root 跑, root 绕得过权限位,
# 那种注入根本不会命中(6.2A 的故障矩阵已经栽过一次)。遮蔽是确定性的, 也容易验命中。
#
# 每格跑完清掉遮蔽、重跑一次健康迁移, 证明状态机能自愈, 也保证不污染下一格。
set -uo pipefail

E2E_ROOT="${PDG_DOTW_REPO:-/repo}"
DW_UNIT=/etc/systemd/system/pdg-dotwitness.service
DW_ENV=/etc/privdns-gateway/dotwitness.env
DW_MOS=/etc/mosdns/config.yaml

p=0; f=0; s=0
ok(){ p=$((p+1)); echo "[OK]   $*"; }
bad(){ f=$((f+1)); echo "[FAIL] $*"; }
skip(){ s=$((s+1)); echo "[SKIP] $*"; }
sect(){ echo; echo "── $* ──"; }   # 不叫 head: 被测代码里有 `| head -1`

# ── 测试专用的子集执行(fail-closed) ────────────────────────────────────────
# 为什么需要: 负控要给 12 类各跑一遍矩阵, 而完整矩阵约 10 分钟(F11 光是等 5399 门走满
# 21 次轮询就要 5 秒), 25 次运行超过 4 小时。让每类只跑与它相关的节, 总时长降一个量级。
#
# **不削弱任何判据**: 被选节的断言一条不减, 只是不跑无关的节。全局准备(健康基线)、
# 每节自己的 before-image、每节收尾的复跑自愈、以及最终污染检查一律照跑。
#
# fail-closed 的理由: 这个开关只该出现在负控里。要是它在 CI 或普通运行里被误设,
# 矩阵会静默地只跑一小部分却照样打印"通过" —— 那正是这套东西最怕的假绿。所以未经
# 授权就设它 = 立即非零退出, 而不是忽略。
SECTIONS_ALL=(PREFLIGHT IDEMPOTENCY PROBE F01 F02 F03 F04 F05 F06 F07 F08 F09 F10 F11 F12 F13)
SEL=""
if [[ -n "${PDG_MIGRATE_SECTIONS+x}" ]]; then
  if [[ "${PDG_NEGCTL:-}" != 1 ]]; then
    echo "PDG_MIGRATE_SECTIONS 只允许负控使用(需同时 PDG_NEGCTL=1)。普通运行/CI 里设它" >&2
    echo "会让矩阵静默地只跑一部分却照样报通过 —— 拒绝执行。" >&2
    exit 2
  fi
  raw="$PDG_MIGRATE_SECTIONS"
  [[ -n "$raw" ]] || { echo "PDG_MIGRATE_SECTIONS 为空" >&2; exit 2; }
  [[ "$raw" =~ ^[A-Z0-9]+(,[A-Z0-9]+)*$ ]] || { echo "PDG_MIGRATE_SECTIONS 格式非法: [$raw]" >&2; exit 2; }
  declare -A seen=()
  for x in ${raw//,/ }; do
    [[ " ${SECTIONS_ALL[*]} " == *" $x "* ]] || { echo "未知节标识: $x" >&2; exit 2; }
    [[ -z "${seen[$x]:-}" ]] || { echo "重复节标识: $x" >&2; exit 2; }
    seen[$x]=1
  done
  # 规范化成 SECTIONS_ALL 的顺序 —— 乱序输入照样按固定顺序执行, 结果与顺序无关
  for x in "${SECTIONS_ALL[@]}"; do [[ -n "${seen[$x]:-}" ]] && SEL="$SEL $x"; done
  SEL="${SEL# }"
  echo "SECTIONS: $SEL"
else
  echo "SECTIONS: FULL"
fi
want(){ [[ -z "$SEL" ]] && return 0; [[ " $SEL " == *" $1 "* ]]; }
# 每个被选节至少要产生一条断言, 否则说明它没真跑起来
SEL_SEEN=""
mark(){ SEL_SEEN="$SEL_SEEN $1"; }


if [[ "${PDG_E2E_ISOLATED:-}" != 1 || "$(id -u)" != 0 ]]; then
  echo "需要 PDG_E2E_ISOLATED=1 且 root(它会真装 unit、真改 /etc/mosdns)"; exit 1
fi

# ── 载入被测函数。只取状态机那一段, 不 source 整个 pdg.sh(它有 main 分派) ──
REPO_DIR="$E2E_ROOT"
c_g(){ echo "$@"; }
c_y(){ echo "$@"; }
_fn="$(python3 - "$E2E_ROOT" <<'PY'
import sys
s = open(sys.argv[1] + "/deploy/bot/pdg.sh").read()
a = s.index("# ── 6.2B: DoT 证据端(observer)的生命周期状态机")
b = s.index("migrate_probe81_public(){")
sys.stdout.write(s[a:b])
PY
)"
eval "$_fn"
[[ "$(type -t migrate_dotwitness)" == function ]] || { echo "载入 migrate_dotwitness 失败"; exit 1; }


# ── before-image 采集与比对 ────────────────────────────────────────────────
# is-enabled/is-active/is-failed 都是"打印结果 + 非零退出"的形态, 直接用命令替换会把
# 退出码路径上的东西也带进来。统一取第一行、去掉换行。
_st(){ command systemctl "$1" "$2" 2>/dev/null | command head -1 | tr -d '\n'; }
snap(){   # 输出一行可比较的完整身份
  local out=""
  local pth
  for pth in "$DW_UNIT" "$DW_ENV" "$DW_MOS"; do
    if [[ -e "$pth" ]]; then
      out+="$(basename "$pth"):$(sha256sum "$pth" | cut -c1-16):$(stat -c '%a:%u:%g' "$pth") "
    else
      out+="$(basename "$pth"):ABSENT "
    fi
  done
  out+="witEnabled=$(_st is-enabled pdg-dotwitness) "
  out+="witActive=$(_st is-active pdg-dotwitness) "
  out+="mosActive=$(_st is-active mosdns)"
  echo "$out"
}
# systemctl 留痕: 状态机**主动发出**的调用会经过这个包装, 而 PartOf=mosdns.service
# 的依赖传播是 systemd 内部行为, 不会经过这里。所以"谁重启了 witness"这个问题, 靠
# 留痕 + InvocationID 两份证据回答, 不靠 PID 变化去猜。
SCTL_LOG=/tmp/sctl.log
SCTL_FAIL_PAT=""
systemctl(){
  printf '%s\n' "$*" >> "$SCTL_LOG"
  if [[ -n "$SCTL_FAIL_PAT" && "$*" == *"$SCTL_FAIL_PAT"* ]]; then return 5; fi
  command systemctl "$@"
}
sctl_reset(){ : > "$SCTL_LOG"; }
sctl_count(){ local n; n="$(grep -cE "$1" "$SCTL_LOG" 2>/dev/null)" || n=0; echo "${n:-0}"; }

mos_pid(){ command systemctl show mosdns -p MainPID --value 2>/dev/null; }
wit_inv(){ command systemctl show pdg-dotwitness -p InvocationID --value 2>/dev/null; }
wit_pid(){ command systemctl show pdg-dotwitness -p MainPID --value 2>/dev/null; }
mos_inv(){ command systemctl show mosdns -p InvocationID --value 2>/dev/null; }
mtimes(){ stat -c %Y "$DW_UNIT" "$DW_ENV" "$DW_MOS" 2>/dev/null | tr '\n' ':'; }
port5399(){ command ss -lun 2>/dev/null | grep -c '127\.0\.0\.1:5399'; }
# 一格自己的 before-image: 文件三件套 + 两个服务的完整身份 + 5399 占用
bimg(){
  local o=""; local pth
  for pth in "$DW_UNIT" "$DW_ENV" "$DW_MOS"; do
    if [[ -e "$pth" ]]; then o+="$(basename "$pth"):$(sha256sum "$pth"|cut -c1-16):$(stat -c '%a:%u:%g' "$pth") "
    else o+="$(basename "$pth"):ABSENT "; fi
  done
  o+="witEn=$(_st is-enabled pdg-dotwitness) "
  o+="witAct=$(_st is-active pdg-dotwitness) "
  o+="witFail=$(_st is-failed pdg-dotwitness) "
  o+="mosAct=$(_st is-active mosdns) "
  o+="p5399=$(port5399)"
  echo "$o"
}
dns_udp(){ dig +short +time=2 +tries=1 @127.0.0.1 example.com A 2>/dev/null | head -1; }
dns_tcp(){ dig +short +tcp +time=2 +tries=1 @127.0.0.1 example.com A 2>/dev/null | head -1; }
dns_dot(){ python3 "$E2E_ROOT/tests/dotquery.py" example.com 2>/dev/null; }
ev_count(){ ls /run/pdg-dotwitness/ 2>/dev/null | wc -l; }
tmpset(){ ls -d /tmp/tmp.* 2>/dev/null | sort | tr '\n' ' '; }
TMP0="$(tmpset)"

# ── 健康基线 ───────────────────────────────────────────────────────────────
sect "0. 健康基线"
migrate_dotwitness >/tmp/base.log 2>&1
rc=$?
[[ $rc == 0 ]] && ok "首次迁移 rc=0" || bad "首次迁移 rc=$rc: $(tail -1 /tmp/base.log)"
BASE="$(snap)"
echo "  before-image: $BASE"
[[ -n "$(dns_udp)" ]] && ok "基线普通 DNS 可用" || bad "基线普通 DNS 不可用"

# ═══ 幂等三件套: 无变化时零写盘、零重启、零 systemctl 变更调用 ═════════════
if want IDEMPOTENCY; then
mark IDEMPOTENCY
sect "I. 幂等(第二次迁移必须什么都不做)"
sctl_reset
M0="$(mtimes)"; WP0="$(wit_pid)"; WI0="$(wit_inv)"; MP0="$(mos_pid)"; MI0="$(mos_inv)"
S0="$(snap)"; EV0="$(ev_count)"
out_i="$(migrate_dotwitness 2>&1)"; rc_i=$?
[[ $rc_i == 0 ]] && ok "I rc=0" || bad "I rc=$rc_i"
[[ "$(snap)" == "$S0" ]] && ok "I 三文件摘要与服务状态未变" || bad "I 状态变了: $(snap)"
[[ "$(mtimes)" == "$M0" ]] && ok "I 三文件 mtime 未变($M0)" || bad "I mtime 变了: $M0 → $(mtimes)"
[[ "$(wit_pid)" == "$WP0" && "$(wit_inv)" == "$WI0" ]] \
  && ok "I witness PID/InvocationID 均未变" || bad "I witness 重启过"
[[ "$(mos_pid)" == "$MP0" && "$(mos_inv)" == "$MI0" ]] \
  && ok "I mosdns PID/InvocationID 均未变" || bad "I mosdns 重启过"
# 调用留痕: 这是区分"状态机主动 restart"与"PartOf 依赖传播"的唯一硬证据
n_reload="$(sctl_count 'daemon-reload')"
n_change="$(sctl_count '^(enable|restart|start|try-restart|stop|disable)')"
[[ "$n_reload" == 0 ]] && ok "I daemon-reload 调用 0 次" || bad "I daemon-reload 调用了 $n_reload 次"
[[ "$n_change" == 0 ]] && ok "I enable/restart/start/try-restart 调用 0 次" \
  || bad "I 发出了 $n_change 次变更调用: $(grep -E '^(enable|restart|start|try-restart|stop|disable)' "$SCTL_LOG" | tr '\n' ' ')"
grep -qE "已就绪|已安装|已更新|已重新排程" <<< "$out_i" && bad "I 输出了变化文案" || ok "I 无变化文案"
[[ "$(ev_count)" == "$EV0" ]] && ok "I evidence 未被迁移自检改写" || bad "I evidence 变了"

# 对照: 单独手工 restart mosdns(不经状态机)也会改 witness 身份 —— 那是 PartOf 传播。
# 有了留痕就不必拿 PID 变化去猜是谁干的。
sctl_reset
command systemctl restart mosdns; sleep 2
[[ "$(wit_inv)" != "$WI0" ]] && ok "I 对照: 手工 restart mosdns → witness 身份也变(PartOf 传播)" \
  || ok "I 对照: 手工 restart mosdns 未波及 witness"
[[ "$(sctl_count '.')" == 0 ]] && ok "I 对照: 传播不经过状态机的 systemctl 包装(留痕 0 条)" \
  || bad "I 对照: 留痕里出现了 $(sctl_count '.') 条"
migrate_dotwitness >/dev/null 2>&1   # 回到健康基线
fi

# ── 一格的通用外壳 ─────────────────────────────────────────────────────────
# $1=编号 $2=名字 $3=注入函数名 $4=撤销函数名 $5=命中验证函数名
cell(){
  local n="$1" name="$2" inject="$3" undo="$4" hit="$5"
  local sid; sid="$(printf 'F%02d' "$n")"
  want "$sid" || return 0
  mark "$sid"
  sect "$n. $name"
  local before; before="$(snap)"
  if [[ "$before" != "$BASE" ]]; then
    bad "$n 进场时状态就不是健康基线, 这一格无从判断"; return
  fi
  "$inject"
  if ! "$hit"; then
    bad "$n 注入未命中 —— 这一格无效(注不进去却'通过'比红更糟)"
    "$undo"; return
  fi
  ok "$n 注入命中"
  local out rc2
  out="$(migrate_dotwitness 2>&1)"; rc2=$?
  [[ $rc2 != 0 ]] && ok "$n migrate 返回非零($rc2)" || bad "$n migrate 返回 0, 但这一格该失败"
  if grep -q "已就绪" <<< "$out"; then bad "$n 打印了成功文案"; else ok "$n 没有成功文案"; fi
  "$undo"
  local after; after="$(snap)"
  if [[ "$after" == "$BASE" ]]; then
    ok "$n 三文件(内容/存在性/mode/uid/gid)与两服务状态逐项回到 before-image"
  else
    bad "$n 恢复不一致"$'\n'"      前: $BASE"$'\n'"      后: $after"
  fi
  [[ -n "$(dns_udp)" ]] && ok "$n 普通 DNS 仍可用" || bad "$n 普通 DNS 挂了"
  if [[ "$(tmpset)" == "$TMP0" ]]; then ok "$n 无**新增**临时候选残留"
  else bad "$n 新增了临时目录: 前[$TMP0] 后[$(tmpset)]"; fi
  # 复原到健康基线, 不让这一格污染下一格
  migrate_dotwitness >/dev/null 2>&1
  [[ "$(snap)" == "$BASE" ]] && ok "$n 复跑一次正常迁移 → 回到健康基线(状态机能自愈)" \
    || bad "$n 复跑后仍未回到基线"
}

# ═══ 1. 域名缺失/非法 ══════════════════════════════════════════════════════
i_dom(){ cp /opt/pdg-bot/dot-domain /tmp/dom.bak; echo 'not a domain!' > /opt/pdg-bot/dot-domain; }
u_dom(){ cp /tmp/dom.bak /opt/pdg-bot/dot-domain; }
h_dom(){ grep -q 'not a domain' /opt/pdg-bot/dot-domain; }
cell 1 "域名非法 → 写盘前失败" i_dom u_dom h_dom

# ═══ 2. dotwroute.py 非零 ══════════════════════════════════════════════════
# 遮蔽 python3: 只对"跑 dotwroute render"这一次返回非零, 其它调用照常
i_route(){ python3(){ if [[ "$*" == *dotwroute.py*render* ]]; then return 3; fi; command python3 "$@"; }; }
u_route(){ unset -f python3; }
h_route(){ python3 "$E2E_ROOT/deploy/bot/dotwroute.py" render "$DW_MOS" a.b >/dev/null 2>&1; [[ $? == 3 ]]; }
cell 2 "dotwroute.py 非零 → 写盘前失败" i_route u_route h_route

# ═══ 3. 候选 mosdns 配置非法 ═══════════════════════════════════════════════
i_cand(){ cp "$E2E_ROOT/deploy/bot/dotwroute.py" /tmp/dw.bak
          python3 - "$E2E_ROOT" <<'PY'
import sys, os
p = sys.argv[1] + "/deploy/bot/dotwroute.py"
os.chmod(p, 0o644)
t = open(p).read()
old = '        "      - exec: $dotwitness_fwd",'
assert t.count(old) == 1
open(p, "w").write(t.replace(old, '        "      - exec: $no_such_plugin",'))
PY
}
u_cand(){ cp /tmp/dw.bak "$E2E_ROOT/deploy/bot/dotwroute.py"; }
h_cand(){ grep -q no_such_plugin "$E2E_ROOT/deploy/bot/dotwroute.py"; }
# 这一格不能只看最终状态。实测(三次一致): 把预校验那条 `return 1` 吞掉之后, 坏配置会
# **确定性地**落进 /etc/mosdns/config.yaml、迁移返回 0、且不进回滚 —— 而最终 image 有时
# 因为后置门和 PartOf 传播看起来"没坏透", 于是只比最终状态的判据会时红时绿。
# 生产契约本身是顺序的: 候选校验失败后, 必须在**第一次持久写入**和**第一次状态改变调用**
# 之前返回非零。所以这里直接断言那个顺序, 与 restart 是否报错无关。
cell3_phase(){
  want PREFLIGHT || return 0
  mark PREFLIGHT
  sect "3P. 候选校验失败的阶段顺序(不看最终状态)"
  local mos0; mos0="$(sha256sum "$DW_MOS" | cut -c1-16)"
  i_cand
  if ! h_cand; then bad "3P 注入未命中"; u_cand; return; fi
  ok "3P 注入命中"
  # 制造必须写盘的差异, 否则 cmp -s 相同就不进写盘分支, 这一格测不到东西
  python3 -c "
p='$DW_MOS'; t=open(p).read()
open(p,'w').write(t.replace('qname suffix probe.','qname suffix probeZ.',1))"
  local dirty; dirty="$(sha256sum "$DW_MOS" | cut -c1-16)"
  sctl_reset
  local out rc3; out="$(migrate_dotwitness 2>&1)"; rc3=$?
  [[ $rc3 != 0 ]] && ok "3P 校验失败 → 返回非零($rc3)" || bad "3P 返回 0, 但候选是非法的"
  [[ "$(sha256sum "$DW_MOS" | cut -c1-16)" == "$dirty" ]] \
    && ok "3P 校验失败后**没有**发生持久写入(mosdns 配置未被换掉)" \
    || bad "3P 校验失败后仍写了 mosdns 配置: $dirty → $(sha256sum "$DW_MOS"|cut -c1-16)"
  local nchg; nchg="$(sctl_count '^(daemon-reload|restart|enable|start|stop|disable|reset-failed)')"
  [[ "$nchg" == 0 ]] && ok "3P 校验失败后**没有**任何状态改变调用" \
    || bad "3P 校验失败后发出了 $nchg 次状态改变调用: $(grep -E '^(daemon-reload|restart|enable|start|stop|disable|reset-failed)' "$SCTL_LOG"|tr '\n' ' ')"
  grep -q "no_such_plugin" "$DW_MOS" && bad "3P 坏配置进了正式路径" || ok "3P 坏配置没进正式路径"
  u_cand
  cp -f /root/v19.pristine "$DW_MOS" 2>/dev/null || true
  migrate_dotwitness >/dev/null 2>&1
  [[ "$(snap)" == "$BASE" ]] && ok "3P 复跑正常迁移 → 回到健康基线" || bad "3P 复跑后未回基线"
}
cell 3 "候选未过真 mosdns 校验" i_cand u_cand h_cand
cell3_phase

# ═══ 4/5/6. 三个原子安装分别失败 ═══════════════════════════════════════════
_mk_install_fail(){   # $1=只对这个目标失败
  local target="$1"
  eval "install(){ local a; for a in \"\$@\"; do [[ \"\$a\" == \"$target\" ]] && return 7; done; command install \"\$@\"; }"
}
h_inst(){ [[ "$(type -t install)" == function ]]; }
# 7/8 需要"确有变化"才会走到 reload/restart, 所以先把盘上的东西弄脏一点点
_dirty_unit(){ printf '\n# dirty\n' >> "$DW_UNIT"; }
_dirty_mos(){  sed -i 's|qname suffix probe\.|qname suffix probeX.|' "$DW_MOS"; }
i_reload2(){ _dirty_unit; i_reload; }
i_mosr2(){   _dirty_mos;  i_mosr; }
# 这两格改脏了盘, before-image 比对会不同 —— 用专门的外壳: 只验 rc/文案/DNS/自愈
# 4-11 格必须先构造**自己那一格的**脏 before-image(不弄脏就到不了目标分支), 然后在
# 移除注入、复跑正常迁移**之前**就把回滚验干净。正常迁移的自愈能力会掩盖回滚缺陷 ——
# "最后回到健康"和"失败当下已经精确回滚"是两件事, 后者才是这套东西的价值所在。
cell_dirty(){
  local n="$1" name="$2" inject="$3" undo="$4"
  local sid; sid="$(printf 'F%02d' "$n")"
  want "$sid" || return 0
  mark "$sid"
  sect "$n. $name"
  "$inject"                       # 弄脏 + 注入
  local B; B="$(bimg)"            # 这一格自己的 before-image(脏状态)
  sctl_reset
  local out rc2; out="$(migrate_dotwitness 2>&1)"; rc2=$?
  [[ $rc2 != 0 ]] && ok "$n migrate 返回非零($rc2)" || bad "$n migrate 返回 0"
  grep -q "已就绪" <<< "$out" && bad "$n 打印了成功文案" || ok "$n 没有成功文案"
  grep -qE "回滚|失败" <<< "$out" && ok "$n 明确报告了失败/回滚" || bad "$n 没说清发生了什么"
  # ── 即时回滚核对: 就在这里, 复跑之前 ──
  local A; A="$(bimg)"
  # 5399 单独看: bind 是异步的, 用有界等待而不是瞬时采样(生产代码自己也是轮询的)
  local wantp; wantp="${B##*p5399=}"
  local i=0
  while [[ $i -lt 20 && "$(port5399)" != "$wantp" ]]; do sleep 0.25; i=$((i+1)); done
  if [[ "$(port5399)" == "$wantp" ]]; then
    [[ "${A##*p5399=}" == "$wantp" ]] && ok "$n 回滚后 5399 立即与 before-image 一致" \
      || ok "$n 回滚后 5399 在 $((i*250))ms 内自行收敛到 before-image(未跑任何迁移; bind 异步)"
  else
    bad "$n 回滚后 5399 状态在 5 秒内未回到 before-image($wantp) —— 只能靠复跑迁移才恢复"
  fi
  A="$(bimg)"
  if [[ "$A" == "$B" ]]; then
    ok "$n **即时**回滚: 三文件(内容/存在性/mode/uid/gid)+enabled/active/failed+5399 精确回到本格 before-image"
  else
    bad "$n **即时**回滚不精确"$'\n'"      前: $B"$'\n'"      后: $A"
  fi
  [[ -n "$(dns_udp)" ]] && ok "$n 回滚后普通 DNS 可用" || bad "$n 普通 DNS 挂了"
  [[ "$(tmpset)" == "$TMP0" ]] && ok "$n 无新增临时候选" || bad "$n 新增临时目录"
  # 到这里才允许移除注入并复跑
  "$undo"
  migrate_dotwitness >/dev/null 2>&1
  [[ "$(snap)" == "$BASE" ]] && ok "$n 复跑正常迁移 → 回到健康基线" || bad "$n 复跑后未回基线: $(snap)"
}
u_inst(){ unset -f install; }
_dirty_env(){ echo 'PDG_DOTWITNESS_SUFFIX=probe.stale.test' > "$DW_ENV"; }
i_env(){  _dirty_env; _mk_install_fail "$DW_ENV"; }
i_unit(){ _dirty_unit; _mk_install_fail "$DW_UNIT"; }
i_mos(){  _dirty_mos;  _mk_install_fail "$DW_MOS"; }

cell_dirty 4 "env 原子安装失败" i_env u_inst
cell_dirty 5 "unit 原子安装失败" i_unit u_inst
cell_dirty 6 "mosdns config 原子安装失败" i_mos u_inst

# ═══ 7-10. systemctl 各动作失败 ════════════════════════════════════════════
_mk_sysctl_fail(){ SCTL_FAIL_PAT="$1"; }
h_sys(){ [[ -n "$SCTL_FAIL_PAT" ]]; }
u_sys(){ SCTL_FAIL_PAT=""; }
i_reload(){ _mk_sysctl_fail "daemon-reload"; }
i_mosr(){   _mk_sysctl_fail "restart mosdns"; }
i_wen(){    _mk_sysctl_fail "enable --now pdg-dotwitness"; }
i_wre(){    _mk_sysctl_fail "restart pdg-dotwitness"; }

cell_dirty 7 "daemon-reload 失败" i_reload2 u_sys
cell_dirty 8 "mosdns restart 失败" i_mosr2 u_sys

# 9/10: 把服务弄成 disabled/inactive 触发 enable/restart 分支
i_wen2(){ command systemctl disable --now pdg-dotwitness >/dev/null 2>&1; sleep 1; i_wen; }
i_wre2(){ _dirty_unit; i_wre; }
cell_dirty 9  "witness enable 失败" i_wen2 u_sys
cell_dirty 10 "witness restart 失败" i_wre2 u_sys

# ═══ 11. 服务状态已改变之后, 5399 门失败 ═══════════════════════════════════
# 原来这一格只 _dirty_unit 就注入, 迁移前后 witness 都是 enabled+active —— 回滚里
# "把服务恢复成原来的 enabled/active"那段从来没被执行过, 摘掉它测试也不会红。
# 现在 before-image 设成 **disabled + inactive + 无监听**, 三文件保持与目标一致, 于是
# 迁移会真的走 enable --now 把服务改成 enabled+active, 然后才在 5399 门失败。
#
# 插桩必须写**文件**不能写 shell 变量: 生产那行是 `ss -lun | grep -q ...`, 管道两端都在
# 子 shell 里跑, 变量赋值出不来。第一版就是这么栽的 —— POLLS 恒为 0, 看起来像"门没触发",
# 其实门触发了, 丢的是我的计数。
SS_TRACE=/tmp/ss-probe.log
i_state(){
  migrate_dotwitness >/dev/null 2>&1              # 三文件先到目标态
  command systemctl disable --now pdg-dotwitness >/dev/null 2>&1
  command systemctl reset-failed pdg-dotwitness >/dev/null 2>&1
  sleep 1
  : > "$SS_TRACE"
  ss(){
    if [[ "$*" == *-lun* ]]; then
      # 用绝对路径工具采真实证据, 不受本测试任何包装影响; 写文件因为这里是子 shell
      printf 'poll en=%s act=%s sub=%s pid=%s listen=%s\n' \
        "$(/usr/bin/systemctl is-enabled pdg-dotwitness 2>/dev/null)" \
        "$(/usr/bin/systemctl is-active pdg-dotwitness 2>/dev/null)" \
        "$(/usr/bin/systemctl show pdg-dotwitness -p SubState --value 2>/dev/null)" \
        "$(/usr/bin/systemctl show pdg-dotwitness -p MainPID --value 2>/dev/null)" \
        "$(/usr/bin/ss -lun 2>/dev/null | grep -c '127\.0\.0\.1:5399')" >> "$SS_TRACE"
      return 0                       # 输出空 → grep -q 失败 → 判"没在监听"
    fi
    command ss "$@"
  }
}
u_state(){ unset -f ss; }

if want F11; then
mark F11
sect "11. 服务状态已改变之后 5399 门失败"
i_state
B11="$(bimg)"
W11_RESULT="$(command systemctl show pdg-dotwitness -p Result --value)"
M11_ACT="$(_st is-active mosdns)"
echo "  before-image: $B11"
[[ "$B11" == *"witEn=disabled"* && "$B11" == *"witAct=inactive"* && "$B11" == *"p5399=0"* ]] \
  && ok "11 before-image 确为 disabled + inactive + 无监听" || bad "11 before-image 不符: $B11"
out11="$(migrate_dotwitness 2>&1)"; rc11=$?
POLLS="$(wc -l < "$SS_TRACE")"
SAW_LISTEN="$(grep -c 'listen=1' "$SS_TRACE" || true)"
SAW_EN="$(grep -c 'en=enabled' "$SS_TRACE" || true)"
SAW_ACT="$(grep -c 'act=active' "$SS_TRACE" || true)"
SAW_PID="$(grep -o 'pid=[0-9]*' "$SS_TRACE" | grep -v 'pid=0' | head -1)"
echo "  轮询留痕 $POLLS 行(生产上限 20 次循环 + 1 次最终判定 = 21); 首条: $(head -1 "$SS_TRACE")"
[[ "$POLLS" -ge 1 ]] && ok "11 5399 门确实被触发(轮询 $POLLS 次)" || bad "11 门没触发, 插桩 0 行"
[[ "$SAW_LISTEN" -ge 1 ]] && ok "11 失败前 5399 **曾真实监听**($SAW_LISTEN/$POLLS 次采样命中)" \
  || bad "11 没能证明 5399 曾监听 —— 这一格没覆盖'状态已改变后回滚'"
[[ "$SAW_EN" -ge 1 ]] && ok "11 失败前 witness 曾为 enabled" || bad "11 失败前不是 enabled"
[[ "$SAW_ACT" -ge 1 ]] && ok "11 失败前 witness 曾为 active" || bad "11 失败前不是 active"
[[ -n "$SAW_PID" ]] && ok "11 失败前存在真实 witness 进程($SAW_PID)" || bad "11 失败前无真实进程"
[[ $rc11 != 0 ]] && ok "11 migrate 返回非零($rc11)" || bad "11 migrate 返回 0"
grep -q "已就绪" <<< "$out11" && bad "11 打印了成功文案" || ok "11 没有成功文案"
grep -q "没有在 127.0.0.1:5399 监听" <<< "$out11" && ok "11 失败原因是 5399 门, 不是更早的步骤" \
  || bad "11 失败在别处: $(head -1 <<< "$out11")"
u_state
k=0; while [[ $k -lt 20 && "$(bimg)" != "$B11" ]]; do sleep 0.25; k=$((k+1)); done
A11="$(bimg)"
[[ "$A11" == "$B11" ]] \
  && ok "11 **即时**回滚: 三文件 + enabled/active/failed + 5399 精确回到 before-image($((k*250))ms)" \
  || bad "11 即时回滚不精确"$'\n'"      前: $B11"$'\n'"      后: $A11"
[[ "$(command systemctl show pdg-dotwitness -p Result --value)" == "$W11_RESULT" ]] \
  && ok "11 Result 与 before-image 一致($W11_RESULT)" || bad "11 Result 变了"
[[ "$(command systemctl show pdg-dotwitness -p MainPID --value)" == 0 ]] \
  && ok "11 witness 已无进程" || bad "11 仍有 witness 进程"
# mosdns: 回滚会无条件 restart 它(即使这一格根本没碰过 mosdns 配置), 所以只能断言它仍
# active, 不能断言 PID 不变。这条多余的重启已登记为 P2, 不在本轮修生产代码。
[[ "$(_st is-active mosdns)" == "$M11_ACT" ]] && ok "11 mosdns 仍为 $M11_ACT" || bad "11 mosdns 状态变了"
[[ -n "$(dns_udp)" ]] && ok "11 普通 DNS 正常" || bad "11 普通 DNS 挂了"
[[ "$(tmpset)" == "$TMP0" ]] && ok "11 无新增临时/候选文件" || bad "11 有临时残留"
migrate_dotwitness >/dev/null 2>&1
[[ "$(snap)" == "$BASE" ]] && ok "11 撤障后正常迁移 → 重新进入健康态" || bad "11 复跑后未回健康态"

# ═══ 12. 模块缺失 → 早退, 一个字节都不动 ═══════════════════════════════════
i_nomod(){ mv /opt/pdg-bot/dotwitness.py /tmp/dw.py.bak; }
u_nomod(){ mv /tmp/dw.py.bak /opt/pdg-bot/dotwitness.py; }
h_nomod(){ [[ ! -f /opt/pdg-bot/dotwitness.py ]]; }
cell 12 "witness 模块缺失 → 不启用空壳" i_nomod u_nomod h_nomod

# ═══ 13. 回滚阶段自己失败 → 必须明说"回滚不完整" ═══════════════════════════
fi

if want F13; then
mark F13
sect "13. 回滚阶段失败 → 明确报告不完整"
_dirty_mos
# 让 mosdns restart 失败进入回滚, 同时让回滚里的 cp 也失败
# 用统一的 SCTL_FAIL_PAT, 不要另起一个 systemctl —— 那会盖掉留痕包装, 后面 unset -f
# 还会把包装整个删掉, 之后所有格子的调用留痕就都空了(而它们照样"通过")。
SCTL_FAIL_PAT="restart mosdns"
# cp 只打**恢复方向**: _dw_snap_file 采集 before-image 时也用 cp 写 .body, 一并打掉的话
# 迁移在采集阶段就早退, 验的是早退而不是回滚不完整。
cp(){ if [[ "${2:-}" == *.body ]]; then return 9; fi; command cp "$@"; }
out13="$(migrate_dotwitness 2>&1)"; rc13=$?
SCTL_FAIL_PAT=""; unset -f cp
[[ $rc13 != 0 ]] && ok "13 主迁移 rc 非零($rc13)" || bad "13 主迁移返回 0"
grep -q "回滚不完整" <<< "$out13" && ok "13 明确打印「回滚不完整」" || bad "13 没有明说回滚不完整"
grep -q "请人工核对" <<< "$out13" && ok "13 指出了要人工核对的具体对象" || bad "13 没指出核对对象"
grep -q "已就绪" <<< "$out13" && bad "13 仍打印了成功文案" || ok "13 没有成功文案"
echo "  这一格**不要求**完整恢复 —— 环境随后整体销毁, 不带入下一格。"
migrate_dotwitness >/dev/null 2>&1
[[ "$(snap)" == "$BASE" ]] && ok "13 之后复跑正常迁移仍能回到健康基线" || bad "13 之后无法自愈: $(snap)"

# ═══ 独立验收门: 真 probe(不在生产迁移里, 只在这里) ════════════════════════
fi

if want PROBE; then
mark PROBE
sect "A. 独立 E2E 验收: 迁移完成后真 probe 必须产生 evidence"
rm -f /run/pdg-dotwitness/evidence.json 2>/dev/null
before_ev="$(ev_count)"
python3 "$E2E_ROOT/tests/dotprobe.py" >/tmp/probe.log 2>&1
after_ev="$(ev_count)"
[[ "$before_ev" == 0 && "$after_ev" == 1 ]] && ok "真 DoT probe → evidence 从 0 变 1" \
  || bad "probe 后 evidence: $before_ev → $after_ev ($(head -1 /tmp/probe.log))"
[[ -n "$(dns_udp)" ]] && ok "普通 UDP53 不产生 evidence 且仍可用" || bad "普通 DNS 挂了"

fi

# 被选节必须都真的跑过, 且都产生了断言 —— 选了却没跑等于静默漏测
if [[ -n "$SEL" ]]; then
  for x in $SEL; do
    [[ " $SEL_SEEN " == *" $x "* ]] || bad "选了节 $x 却没有执行到"
  done
  [[ $((p+f)) -gt 0 ]] || bad "被选节一条断言都没产生"
fi
echo
echo "──────────────────────────────────────────────────────────────"
echo "通过 $p, 失败 $f, 跳过 $s"
exit $(( f ? 1 : 0 ))

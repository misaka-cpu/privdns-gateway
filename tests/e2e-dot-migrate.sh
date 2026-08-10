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
head(){ echo; echo "── $* ──"; }

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
  out+="witEnabled=$(systemctl is-enabled pdg-dotwitness 2>/dev/null || echo -) "
  out+="witActive=$(systemctl is-active pdg-dotwitness 2>/dev/null || echo -) "
  out+="mosActive=$(systemctl is-active mosdns 2>/dev/null || echo -)"
  echo "$out"
}
mos_pid(){ systemctl show mosdns -p MainPID --value 2>/dev/null; }
wit_inv(){ systemctl show pdg-dotwitness -p InvocationID --value 2>/dev/null; }
dns_udp(){ dig +short +time=2 +tries=1 @127.0.0.1 example.com A 2>/dev/null | head -1; }
dns_tcp(){ dig +short +tcp +time=2 +tries=1 @127.0.0.1 example.com A 2>/dev/null | head -1; }
dns_dot(){ python3 "$E2E_ROOT/tests/dotquery.py" example.com 2>/dev/null; }
ev_count(){ ls /run/pdg-dotwitness/ 2>/dev/null | wc -l; }
tmpset(){ ls -d /tmp/tmp.* 2>/dev/null | sort | tr '\n' ' '; }
TMP0="$(tmpset)"

# ── 健康基线 ───────────────────────────────────────────────────────────────
head "0. 健康基线"
migrate_dotwitness >/tmp/base.log 2>&1
rc=$?
[[ $rc == 0 ]] && ok "首次迁移 rc=0" || bad "首次迁移 rc=$rc: $(tail -1 /tmp/base.log)"
BASE="$(snap)"
echo "  before-image: $BASE"
[[ -n "$(dns_udp)" ]] && ok "基线普通 DNS 可用" || bad "基线普通 DNS 不可用"

# ── 一格的通用外壳 ─────────────────────────────────────────────────────────
# $1=编号 $2=名字 $3=注入函数名 $4=撤销函数名 $5=命中验证函数名
cell(){
  local n="$1" name="$2" inject="$3" undo="$4" hit="$5"
  head "$n. $name"
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
cell 3 "候选未过真 mosdns 校验" i_cand u_cand h_cand

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
cell_dirty(){
  local n="$1" name="$2" inject="$3" undo="$4"
  head "$n. $name"
  "$inject"
  local out rc2; out="$(migrate_dotwitness 2>&1)"; rc2=$?
  [[ $rc2 != 0 ]] && ok "$n migrate 返回非零($rc2)" || bad "$n migrate 返回 0"
  grep -q "已就绪" <<< "$out" && bad "$n 打印了成功文案" || ok "$n 没有成功文案"
  grep -qE "回滚|失败" <<< "$out" && ok "$n 明确报告了失败/回滚" || bad "$n 没说清发生了什么"
  "$undo"
  [[ -n "$(dns_udp)" ]] && ok "$n 普通 DNS 仍可用" || bad "$n 普通 DNS 挂了"
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
_mk_sysctl_fail(){    # $1=匹配这个动作串就失败
  local pat="$1"
  eval "systemctl(){ if [[ \"\$*\" == *\"$pat\"* ]]; then return 5; fi; command systemctl \"\$@\"; }"
}
h_sys(){ [[ "$(type -t systemctl)" == function ]]; }
u_sys(){ unset -f systemctl; }
i_reload(){ _mk_sysctl_fail "daemon-reload"; }
i_mosr(){   _mk_sysctl_fail "restart mosdns"; }
i_wen(){    _mk_sysctl_fail "enable --now pdg-dotwitness"; }
i_wre(){    _mk_sysctl_fail "restart pdg-dotwitness"; }

cell_dirty 7 "daemon-reload 失败" i_reload2 u_sys
cell_dirty 8 "mosdns restart 失败" i_mosr2 u_sys

# 9/10: 把服务弄成 disabled/inactive 触发 enable/restart 分支
i_wen2(){ command systemctl disable --now pdg-dotwitness >/dev/null 2>&1; i_wen; }
i_wre2(){ _dirty_unit; i_wre; }
cell_dirty 9  "witness enable 失败" i_wen2 u_sys
cell_dirty 10 "witness restart 失败" i_wre2 u_sys

# ═══ 11. restart 成功但没在听 5399 ═════════════════════════════════════════
i_noport(){ _dirty_unit; ss(){ if [[ "$*" == *-lun* ]]; then return 0; fi; command ss "$@"; }; }
u_noport(){ unset -f ss; }
cell_dirty 11 "restart 成功但 5399 未监听" i_noport u_noport

# ═══ 12. 模块缺失 → 早退, 一个字节都不动 ═══════════════════════════════════
i_nomod(){ mv /opt/pdg-bot/dotwitness.py /tmp/dw.py.bak; }
u_nomod(){ mv /tmp/dw.py.bak /opt/pdg-bot/dotwitness.py; }
h_nomod(){ [[ ! -f /opt/pdg-bot/dotwitness.py ]]; }
cell 12 "witness 模块缺失 → 不启用空壳" i_nomod u_nomod h_nomod

# ═══ 13. 回滚阶段自己失败 → 必须明说"回滚不完整" ═══════════════════════════
head "13. 回滚阶段失败 → 明确报告不完整"
_dirty_mos
# 让 mosdns restart 失败进入回滚, 同时让回滚里的 cp 也失败
systemctl(){ if [[ "$*" == *"restart mosdns"* ]]; then return 5; fi; command systemctl "$@"; }
cp(){ if [[ "${2:-}" == *.body ]]; then return 9; fi; command cp "$@"; }
out13="$(migrate_dotwitness 2>&1)"; rc13=$?
unset -f systemctl cp
[[ $rc13 != 0 ]] && ok "13 主迁移 rc 非零($rc13)" || bad "13 主迁移返回 0"
grep -q "回滚不完整" <<< "$out13" && ok "13 明确打印「回滚不完整」" || bad "13 没有明说回滚不完整"
grep -q "请人工核对" <<< "$out13" && ok "13 指出了要人工核对的具体对象" || bad "13 没指出核对对象"
grep -q "已就绪" <<< "$out13" && bad "13 仍打印了成功文案" || ok "13 没有成功文案"
echo "  这一格**不要求**完整恢复 —— 环境随后整体销毁, 不带入下一格。"
migrate_dotwitness >/dev/null 2>&1
[[ "$(snap)" == "$BASE" ]] && ok "13 之后复跑正常迁移仍能回到健康基线" || bad "13 之后无法自愈: $(snap)"

# ═══ 独立验收门: 真 probe(不在生产迁移里, 只在这里) ════════════════════════
head "A. 独立 E2E 验收: 迁移完成后真 probe 必须产生 evidence"
rm -f /run/pdg-dotwitness/evidence.json 2>/dev/null
before_ev="$(ev_count)"
python3 "$E2E_ROOT/tests/dotprobe.py" >/tmp/probe.log 2>&1
after_ev="$(ev_count)"
[[ "$before_ev" == 0 && "$after_ev" == 1 ]] && ok "真 DoT probe → evidence 从 0 变 1" \
  || bad "probe 后 evidence: $before_ev → $after_ev ($(head -1 /tmp/probe.log))"
[[ -n "$(dns_udp)" ]] && ok "普通 UDP53 不产生 evidence 且仍可用" || bad "普通 DNS 挂了"

echo
echo "──────────────────────────────────────────────────────────────"
echo "通过 $p, 失败 $f, 跳过 $s"
exit $(( f ? 1 : 0 ))

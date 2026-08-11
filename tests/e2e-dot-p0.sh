#!/usr/bin/env bash
# 6.2B P0 基础隔离门: witness 坏掉时, 普通 DNS 必须**一条都不受影响**。
#
# 这条和迁移回滚矩阵分开统计, 不能拿"迁移后普通 DNS 能用"代替 —— 那验的是迁移没搞坏
# 配置; 这里验的是 witness 在**运行期**出问题时, mosdns 的普通链路不被拖累。两件事的
# 失效方式完全不同: 前者是配置写错, 后者是 witness 那条 forward 阻塞/超时反压到主链。
set -uo pipefail
E2E_ROOT="${PDG_DOTW_REPO:-/repo}"
p=0; f=0
ok(){ p=$((p+1)); echo "[OK]   $*"; }
bad(){ f=$((f+1)); echo "[FAIL] $*"; }
head(){ echo; echo "── $* ──"; }
[[ "${PDG_E2E_ISOLATED:-}" == 1 && "$(id -u)" == 0 ]] || { echo "需要 PDG_E2E_ISOLATED=1 且 root"; exit 1; }

mos_pid(){ systemctl show mosdns -p MainPID --value; }
mos_inv(){ systemctl show mosdns -p InvocationID --value; }
ev_n(){ ls /run/pdg-dotwitness/ 2>/dev/null | wc -l; }

# 三种传输各 3 次, 记录耗时上限
run9(){
  local okc=0 t0 t1 ms worst=0 i
  for i in 1 2 3; do
    t0=$(date +%s%N); dig +short +time=2 +tries=1 @127.0.0.1 example.com A >/dev/null 2>&1 && okc=$((okc+1))
    t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); [ $ms -gt $worst ] && worst=$ms
  done
  for i in 1 2 3; do
    t0=$(date +%s%N); dig +short +tcp +time=2 +tries=1 @127.0.0.1 example.com A >/dev/null 2>&1 && okc=$((okc+1))
    t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); [ $ms -gt $worst ] && worst=$ms
  done
  for i in 1 2 3; do
    t0=$(date +%s%N); python3 "$E2E_ROOT/tests/dotquery.py" example.com >/dev/null 2>&1 && okc=$((okc+1))
    t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); [ $ms -gt $worst ] && worst=$ms
  done
  echo "$okc $worst"
}

head "0. 健康基线(witness 正常)"
read -r n0 w0 <<< "$(run9)"
[[ "$n0" == 9 ]] && ok "基线 9/9 成功(UDP53×3 + TCP53×3 + DoT×3)" || bad "基线只有 $n0/9"
echo "  基线最慢一次 ${w0}ms"
P0=$(mos_pid); I0=$(mos_inv)

for mode in stop reject; do
  head "故障: witness $mode"
  if [[ "$mode" == stop ]]; then
    systemctl stop pdg-dotwitness; sleep 1
    ok "witness 已停(is-active=$(systemctl is-active pdg-dotwitness))"
  else
    systemctl start pdg-dotwitness; sleep 1
    # 让 5399 拒绝: 停掉服务后端口无人监听, ICMP port unreachable
    systemctl stop pdg-dotwitness; sleep 1
    ok "5399 无人监听(拒绝): $(ss -lun | grep -c 5399) 个监听"
  fi
  ev_before=$(ev_n)
  read -r n1 w1 <<< "$(run9)"
  [[ "$n1" == 9 ]] && ok "$mode: 普通查询 9/9 成功" || bad "$mode: 只有 $n1/9 成功"
  # 上限: 与健康基线同量级。放宽到基线+2000ms 或 3000ms 取大者 —— 再宽就说明真被拖累了
  lim=$(( w0 + 2000 )); [ $lim -lt 3000 ] && lim=3000
  [[ "$w1" -le "$lim" ]] && ok "$mode: 最慢 ${w1}ms <= 上限 ${lim}ms(基线 ${w0}ms)" \
    || bad "$mode: 最慢 ${w1}ms 超过上限 ${lim}ms —— 普通链路被 witness 拖累了"
  [[ "$(mos_pid)" == "$P0" ]] && ok "$mode: mosdns PID 未变($P0)" || bad "$mode: mosdns PID 变了"
  [[ "$(mos_inv)" == "$I0" ]] && ok "$mode: mosdns InvocationID 未变" || bad "$mode: mosdns 重启过"
  [[ "$(ev_n)" == "$ev_before" ]] && ok "$mode: 没有产生假 evidence" || bad "$mode: 冒出了 evidence"
done

head "恢复后真 probe 必须再次成功"
# probe 的域名必须取自**这台机器实际部署的**那个, 不能用 dotprobe.py 的缺省值:
# 进探测命名空间要同时满足 qname 后缀与 SNI 两个判据, 域名对不上就一个都不满足,
# 于是"没出 evidence" —— 看起来像产品坏了, 实际是探针打偏了。这一格在真装机上第一次
# 跑就是这么红的(机器是 dot.and.test, 缺省值是 dot.example.test)。
# 单一可信源: dotwitness.env 的后缀按契约恒为 `probe.<DoT域名>`, 与 mosdns 受管块同源。
DW_SUFFIX="$(sed -n 's/^PDG_DOTWITNESS_SUFFIX=//p' /etc/privdns-gateway/dotwitness.env 2>/dev/null | tail -1)"
DOT_DOM="${DW_SUFFIX#probe.}"
if [[ -z "$DOT_DOM" || "$DOT_DOM" == "$DW_SUFFIX" ]]; then
  bad "取不到本机 DoT 域名(dotwitness.env 后缀 = ${DW_SUFFIX:-<空>}) —— 不拿缺省值蒙混"
else
  systemctl start pdg-dotwitness; sleep 2
  rm -f /run/pdg-dotwitness/evidence.json 2>/dev/null
  python3 "$E2E_ROOT/tests/dotprobe.py" "$DOT_DOM" >/dev/null 2>&1; sleep 1
  [[ "$(ev_n)" == 1 ]] && ok "witness 恢复后真 probe($DOT_DOM) → evidence 生成" \
    || bad "恢复后 probe($DOT_DOM) 没出 evidence"
fi
read -r n2 _ <<< "$(run9)"
[[ "$n2" == 9 ]] && ok "恢复后普通查询仍 9/9" || bad "恢复后只有 $n2/9"

echo
echo "──────────────────────────────────────────────────────────────"
echo "通过 $p, 失败 $f"
exit $(( f ? 1 : 0 ))

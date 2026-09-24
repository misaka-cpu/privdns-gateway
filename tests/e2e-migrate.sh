#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 把一台"v1.4.x 时代的老机器"升到当前版本, 跑**真正的** pdg __migrate。
#
# 这条路线单测覆盖不到 —— 它是十几个迁移按顺序作用在同一份真实现场上的**累积结果**,
# 接缝正是出 bug 的地方(实践中查出的 GMS 重复插入、backend 标记从不落地, 都是这么发现的)。
#
# 老机器的特征: 无平台标记 / 无内核标记 / mosdns 是排除式老形态(无 hijack_set) /
# sing-box model 带 GMS 入站 / 用户加过显式出口规则 / iOS 组件装给了所有机器
# (v1.4.x 无平台概念, 所以它们的存在**证明不了**平台)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install

seed_old_box(){   # $1=平台标记(留空=老机器原样, 无标记)
  rm -f /etc/privdns-gateway/platform /etc/privdns-gateway/platform.guessed /etc/privdns-gateway/backend
  e2e_seed_mosdns all
  # 退回"老形态": 去掉 hijack_set 插件(那时还没有这机制)
  python3 - /etc/mosdns/config.yaml <<'PY'
import re, sys
f = sys.argv[1]; s = open(f, encoding="utf-8").read()
s = re.sub(r"  # custom_hijack[\s\S]*?(?=  - tag: force_hijack)", "", s)
s = re.sub(r"  - tag: hijack_set\n    type: domain_set\n    args: \{[^\n]*\n", "", s)
open(f, "w", encoding="utf-8").write(s)
PY
  # v1.4.x 的 model: GMS 入站 + 用户加过的显式出口规则
  cat > /etc/sing-box/config.json <<'J'
{"log":{"level":"warn"},
 "inbounds":[{"type":"direct","tag":"in-http","listen":"0.0.0.0","listen_port":80,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-https","listen":"0.0.0.0","listen_port":443,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5228","listen":"0.0.0.0","listen_port":5228,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5229","listen":"0.0.0.0","listen_port":5229,"sniff":true,"sniff_override_destination":true},
             {"type":"direct","tag":"in-gms-5230","listen":"0.0.0.0","listen_port":5230,"sniff":true,"sniff_override_destination":true}],
 "outbounds":[{"type":"direct","tag":"direct"},
              {"type":"shadowsocks","tag":"jp","server":"198.51.100.7","server_port":8388,"method":"aes-128-gcm","password":"x"}],
 "route":{"rules":[{"action":"reject","ip_cidr":["203.0.113.1/32"]},
                   {"domain_suffix":["ip.skk.moe","example.test"],"outbound":"jp"}],
          "final":"direct"}}
J
  # v1.4.x 把 iOS 组件装给所有机器 → 它们证明不了平台
  install -m644 "$E2E_ROOT/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl" /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  install -m755 "$E2E_ROOT/deploy/bot/probe81.py" /opt/pdg-bot/probe81.py
  : > /etc/systemd/system/pdg-probe81.service
  [[ -n "${1:-}" ]] && printf '%s\n' "$1" > /etc/privdns-gateway/platform
  return 0
}
gms(){ grep -c 'in-gms-52' /etc/sing-box/config.json; }
plug(){ grep -c 'tag: hijack_set' /etc/mosdns/config.yaml; }
gate(){ grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml; }

# ══ 场景一: 老机器原样(无任何平台证据) ══════════════════════════════════════
echo "── 场景一: v1.4.x 老机器, 无平台/内核标记 ──"
seed_old_box
[[ "$(plug)" == 0 && "$(gms)" == 3 ]] || bad "前置: 老形态没造对"
bash /usr/local/bin/pdg __migrate >$E2E_TMP/mig1.log 2>&1
rc=$?
[[ "$rc" == 0 ]] && ok "迁移整体成功(exit 0)" || bad "迁移退出码 $rc: $(tail -3 $E2E_TMP/mig1.log)"

# 平台: 无证据 → 推测 android, 且**不做破坏性清理**
{ [[ "$(cat /etc/privdns-gateway/platform)" == android ]] && [[ -e /etc/privdns-gateway/platform.guessed ]]; } \
  && ok "无证据 → 平台回退 android 且标记为推测" || bad "平台推测标记缺失"
{ [[ -e /opt/pdg-bot/probe81.py ]] && [[ -e /etc/systemd/system/pdg-probe81.service ]] \
  && [[ -e /opt/pdg-bot/pdg-dot.mobileconfig.tmpl ]]; } \
  && ok "推测态: iOS 组件一个没删(万一这台其实服务 iPhone)" || bad "推测态下 iOS 组件被删了"
grep -q '跳过 iOS 组件清理' $E2E_TMP/mig1.log && ok "推测态: 明确说明跳过了清理" || bad "未提示跳过清理"

# v1.6.0: 老装(sing-box)迁移后内核标记必须落定 mihomo, 且 sing-box 运行时被清干净
[[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == mihomo ]] \
  && ok "老装迁移: 内核标记落定 mihomo" || bad "backend=$(cat /etc/privdns-gateway/backend 2>/dev/null)"
{ [[ ! -e /etc/systemd/system/sing-box.service ]] && [[ ! -e /usr/local/bin/sing-box ]]; } \
  && ok "老装迁移: sing-box unit 与二进制已移除" || bad "sing-box 运行时仍有残留"
grep -q 'sing-box 运行时已移除' $E2E_TMP/mig1.log \
  && ok "老装迁移: 迁移过程有明确告知" || bad "迁移日志未提到移除 sing-box"

# mosdns: 补 hijack_set 插件, all 模式不装劫持门
{ [[ "$(plug)" == 1 ]] && [[ "$(gate)" == 0 ]]; } \
  && ok "mosdns: 补上 hijack_set 插件, all 仍是排除式(不装劫持门)" || bad "劫持形态错: 插件=$(plug) 门=$(gate)"

# 用户此前加过的显式出口域名必须被回填进劫持表(否则那些规则一直是死的)
hj=$(grep -c '^domain:' /etc/mosdns/rules/custom_hijack.txt 2>/dev/null || echo 0)
{ [[ "$hj" == 2 ]] && grep -q 'ip.skk.moe' /etc/mosdns/rules/custom_hijack.txt; } \
  && ok "回填: 已有的显式出口域名进了劫持表(用户无需重加)" || bad "回填数=$hj"

# GMS: android 平台该保留, 且不得重复插入
[[ "$(gms)" == 3 ]] && ok "GMS 入站保持 3 条(android 需要, 且未重复插入)" || bad "GMS 入站变成 $(gms) 条"

# 幂等
cp /etc/mosdns/config.yaml $E2E_TMP/m1; cp /etc/sing-box/config.json $E2E_TMP/s1
bash /usr/local/bin/pdg __migrate >$E2E_TMP/mig2.log 2>&1
{ cmp -s $E2E_TMP/m1 /etc/mosdns/config.yaml && cmp -s $E2E_TMP/s1 /etc/sing-box/config.json; } \
  && ok "二跑幂等(mosdns 与 model 均无变化)" || bad "二跑改动了配置"

# ══ 场景二: 平台已确认 ios, 且盘上还有老版 WLOC 的执行面 ════════════════════
echo; echo "── 场景二: 同样的老机器, 但平台已确认 ios(带 WLOC 残留) ──"
# 老版开过 WLOC 的机器: MITM 宿主、两个模块、服务在跑, 还有一张 CA 和用户填过的地点。
# 只写制品本身(与 tests/test-wloc-retire-migration.sh 造旧态的做法一致) —— 不调用新版
# 已删除的开启入口, 也不恢复任何签发能力。造完先自检, 否则"已撤除"什么都证明不了。
#
# CA 得是**真的一张 X.509 公钥证书**: 产品那边的 CA 报告走 mitm_ca 的只读探测, 正文认不出
# 就判 damaged, 走的是另一条措辞。拿占位文本造出来的现场, 验的根本不是"盘上还留着一张手机
# 可能仍在信任的根证书"那一格 —— 而那一格正是下面几条保留判据要看的。自签一张放到盘上,
# 与造 unit / 模块前像同理: 只是把老现场摆出来, 不恢复任何签发能力。
#
# 这一段造两次(二-0 反例一次、二-1 正常退役一次), 所以收成函数; 两次的自检各报各的,
# 否则"前像就位"是哪一次造的分不出来。
seed_wloc_residue(){   # $1=这一格的名字(前像自检用)
  local tag="$1" _pre=1 f
  install -d -m755 /opt/pdg-bot /etc/privdns-gateway/ca
  printf '[Unit]\nDescription=PDG MITM (retired)\n[Service]\nExecStart=/usr/bin/false\n' \
    > /etc/systemd/system/pdg-mitm.service
  printf '# retired module (pre-image only)\n' > /opt/pdg-bot/mitm_server.py
  printf '# retired module (pre-image only)\n' > /opt/pdg-bot/mitm_wloc.py
  printf '%s\n' '{"wloc":{"enabled":true,"accuracy":50,"active":"大阪","generation":1,"locations":[{"name":"大阪","lat":34.6937,"lon":135.5023}]}}' \
    > /etc/privdns-gateway/mitm.json
  rm -f /etc/privdns-gateway/ca/ca.crt /etc/privdns-gateway/ca/ca.key
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
      -subj '/CN=PrivDNS Gateway MITM CA (retired pre-image)' \
      -keyout /etc/privdns-gateway/ca/ca.key -out /etc/privdns-gateway/ca/ca.crt \
      >/dev/null 2>&1 \
    || bad "$tag 造不出 WLOC 时期的 CA(openssl 不可用?) —— CA 保留判据不作数"
  mkdir -p "$E2E_TMP/e2e-svc"; echo 1 > "$E2E_TMP/e2e-svc/pdg-mitm.ac"; echo 1 > "$E2E_TMP/e2e-svc/pdg-mitm.en"
  for f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
    [[ -e "$f" ]] || _pre=0
  done
  [[ -s /etc/privdns-gateway/ca/ca.crt ]] || _pre=0
  [[ "$(systemctl is-active pdg-mitm)" == active ]] || _pre=0
  [[ "$_pre" == 1 ]] && ok "$tag 残留前像就位(三件制品 + 一张真 CA 在盘上, pdg-mitm 报 active)" \
    || bad "$tag WLOC 残留前像没造出来, 撤除相关判据不作数"
}

# ── 二-0(反例): 内部入口交不出本次操作的服务前像句柄 → 退役一件都不许做 ──────
# 这一格与二-1 是同一台机器的两种调用形态, 必须分开留着。门放行的判据是"调用方能在动手
# 之前保存服务前像、并据此恢复", **不是**"这台机器需不需要退役"。手打 `pdg __migrate`
# 没有句柄, 于是受保护的退役对象一个不许撤、服务一个不许停 —— 半截现场比不动更糟。
# 这里不设任何环境变量、不造任何凭据: 要验的正是"补不出来就得被拒"。
seed_old_box ios
seed_wloc_residue "iOS 二-0:"
: > "$E2E_TMP/e2e-calls.log"
bash /usr/local/bin/pdg __migrate >$E2E_TMP/mig2n.log 2>&1
RC2N=$?
[[ "$RC2N" != 0 ]] \
  && ok "iOS 二-0: 无句柄的 __migrate 返回非零(rc=$RC2N)" \
  || bad "iOS 二-0: 无句柄却整体报成功(rc=$RC2N)"
grep -q '不执行 WLOC 退役迁移' $E2E_TMP/mig2n.log \
  && ok "iOS 二-0: 明确拒绝执行 WLOC 退役迁移" \
  || bad "iOS 二-0: 没说明为什么不退役: $(tail -3 $E2E_TMP/mig2n.log)"
grep -q 'PDG_UPDATE_SVCSTATE 未设' $E2E_TMP/mig2n.log \
  && ok "iOS 二-0: 点名缺的就是本次操作的服务前像句柄" \
  || bad "iOS 二-0: 没点名缺的是什么"
for f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
  [[ -e "$f" ]] && ok "iOS 二-0: 受保护的 $(basename "$f") 没被撤除" \
    || bad "iOS 二-0: 被拒的这一次却撤掉了 $f"
done
[[ "$(systemctl is-active pdg-mitm)" == active ]] \
  && ok "iOS 二-0: pdg-mitm 仍在运行(没被停)" || bad "iOS 二-0: pdg-mitm 被停了"
grep -qE 'disable --now pdg-mitm|stop pdg-mitm' "$E2E_TMP/e2e-calls.log" \
  && bad "iOS 二-0: 竟然对 pdg-mitm 发过 stop/disable" \
  || ok "iOS 二-0: 一条停/禁用 pdg-mitm 的调用都没有"
grep -q '"enabled": *true' /etc/privdns-gateway/mitm.json \
  && ok "iOS 二-0: mitm.json 的 wloc.enabled 原样未动" || bad "iOS 二-0: mitm.json 被改了"
[[ -s /etc/privdns-gateway/ca/ca.crt ]] \
  && ok "iOS 二-0: 旧 CA 材料仍在" || bad "iOS 二-0: 旧 CA 被删了"

# ── 二-1: 走公开入口 `pdg migrate` —— 快照、服务前像、句柄三样都由真实产品自己做 ──
# 产品被拒时指的就是这条路(见 _retire_caller_gate 的提示 ③)。这里**不手工补造凭据、
# 不设 PDG_UPDATE_SVCSTATE、也不动门的任何判据**: cmd_migrate 先 _lock、再 cmd_snapshot
# (前像在打包之后一并存好并校验)、然后把那份记录的路径交给 run_all_migrations。门验的是
# "这份记录属于本次操作"(boot_id / 调用方 pid+启动时刻 / 快照绑定), 所以退役真的做成了
# 这件事本身, 就是句柄确实被产品自己生成并传下去了的证据。
seed_old_box ios
seed_wloc_residue "iOS 二-1:"
: > "$E2E_TMP/e2e-calls.log"
# 本次到底产出了哪一份快照, 要拿**盘上的目录**说话, 不拿日志里的预告说话: 跑之前记下
# 已有哪些, 跑完做差集。
#
# 观测本身也会坏, 而坏掉的观测**看起来和正常结果一模一样**: 操作前那次 ls 失败会留下一份
# 空清单, 差集于是把盘上原有的旧快照算成"本次新增", "本次真的建出快照了"这条判据就被一份
# 2020 年的旧目录顶了上去。同理, 后一次 ls 先吐完内容再以非零退出, 半截输出照样被消费。
# 所以建目录 / 采清单 / 算差集三步, 每一步都要看**它自己的实际退出码**; 失败命令留下的空
# 清单或半截输出一律不消费, 一律具名报"观测无效"并进失败结算 —— 观测坏了就说观测坏了,
# 不把它冒称成关于产品的结论。
SNAPD=/var/lib/privdns-gateway/backups
snap_list(){   # $1=清单落点 $2=具名前缀 → 0=采到了; 非0=观测无效(已经具名报过红)
  local out="$1" tag="$2" raw="$1.raw" err="$1.err" rc=0 n=0
  rm -f "$out" "$raw" "$err"
  ls -1 "$SNAPD/" > "$raw" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    n="$(grep -c '' "$raw" 2>/dev/null || true)"
    bad "$tag **观测无效** —— 列快照目录失败(ls 退出 $rc); 它已经吐出的 ${n:-0} 行一律不采信: $(head -1 "$err" 2>/dev/null)"
    rm -f "$raw" "$err"; return 1
  fi
  # `if ! sort …; then rc=$?` 记下来的是 `!` 取反之后的 0, 不是 sort 自己的码。
  # 阻断不变, 但记账要记原始码 —— 事后查"到底怎么失败的"全靠这个数。
  sort "$raw" > "$out" 2>>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 清单排序失败(sort 退出 $rc)"
    rm -f "$raw" "$err" "$out"; return 1
  fi
  rm -f "$raw" "$err"; return 0
}
SNAPOBS=1
mkdir -p "$SNAPD" || { bad "iOS 二-1: **观测无效** —— 建不出快照目录 $SNAPD(mkdir 退出 $?)"; SNAPOBS=0; }
(( SNAPOBS == 1 )) && { snap_list "$E2E_TMP/snapdirs.before" "iOS 二-1(操作前):" || SNAPOBS=0; }
if (( SNAPOBS == 0 )); then
  # 操作前的清单是差集的**被减数**: 它没采到, 这一格再跑迁移也解释不了结果, 所以不跑。
  bad "iOS 二-1: 操作前的快照观测没成立 → **本格迁移不执行**(本格的退出码 / 现场 / 幂等判据本轮都不产出)"
else
  bash /usr/local/bin/pdg migrate >$E2E_TMP/mig3.log 2>&1
  RC3=$?
  SNAPNEW=""; SNAPOK=0; SNAPN=0; SNAPTXT=""; SNAPARR=()
  if snap_list "$E2E_TMP/snapdirs.after" "iOS 二-1(操作后):"; then
    comm -13 "$E2E_TMP/snapdirs.before" "$E2E_TMP/snapdirs.after" \
      > "$E2E_TMP/snapdirs.new" 2> "$E2E_TMP/snapdirs.new.err"
    RCCOMM=$?
    if (( RCCOMM != 0 )); then
      bad "iOS 二-1: **观测无效** —— 差集计算失败(comm 退出 $RCCOMM), 它的输出一律不采信: $(head -1 "$E2E_TMP/snapdirs.new.err" 2>/dev/null)"
      rm -f "$E2E_TMP/snapdirs.new"
    else
      # 份数与目录名出自**同一次受检读取**。以前这里是 `grep -c` 数一遍、后面再 `cat` 读一遍:
      # 两次都没看退出码, 于是读失败留下的空输出被当成"零份"(→ 误报"产品没建快照"), 半截
      # 输出被当成路径(→ 误报"产物成立")。换成一次 cat: 它对空文件就是退出 0、输出为空,
      # 所以"正常的零份"与"读取错误"天然分得开(不像 grep -c 空集合也返回 1)。
      SNAPRD=0
      SNAPTXT="$(cat "$E2E_TMP/snapdirs.new")" || SNAPRD=$?
      if (( SNAPRD != 0 )); then
        bad "iOS 二-1: **观测无效** —— 读本次新增清单失败(cat 退出 $SNAPRD), 它已经吐出的内容一律不采信"
      else
        SNAPOK=1
        if [[ -n "$SNAPTXT" ]]; then
          mapfile -t SNAPARR <<< "$SNAPTXT"
          SNAPN="${#SNAPARR[@]}"; SNAPNEW="${SNAPARR[0]}"
        fi
      fi
    fi
  fi
  echo "   [记录] iOS 二-1: pdg migrate 退出码 = $RC3(阶段证据在 mig3.log)"
  # 正常调用的**真实退出码**自成一条判据。"退役那几样撤干净了"是**局部**证据, 可以单列,
  # 但顶替不了"这一次整体跑成功了" —— 半截成功不许按通过记。本机取不到 mihomo 时这一条
  # 会真红: 那就是真红, 不放宽、不特判。
  [[ "$RC3" == 0 ]] \
    && ok "iOS 二-1: 公开入口整体成功(实际退出码 0)" \
    || bad "iOS 二-1: **正常调用没跑成功**(实际退出码 $RC3) —— 下面的现场判据即使全绿, 也只是局部证据, 不算这一次通过: $(tail -3 $E2E_TMP/mig3.log)"
  # 「迁移前留快照…」是**动手之前打的预告**, 只证明它先说了这件事。
  grep -q '迁移前留快照' $E2E_TMP/mig3.log \
    && ok "iOS 二-1: 动手之前先打了留快照的准备提示(仅准备阶段提示)" \
    || bad "iOS 二-1: 连留快照的准备提示都没有: $(head -3 $E2E_TMP/mig3.log)"
  # 观测健康正控 —— 与"真实迁移成功"那条正控**分开**: 这一条只说这次观测本身站不站得住。
  (( SNAPOK == 1 )) \
    && ok "iOS 二-1: 快照观测三步(建目录 / 前后清单 / 差集)都成立, 本次新增 $SNAPN 份" \
    || bad "iOS 二-1: 快照观测没有成立(具体哪一步见上面的「观测无效」)"
  # 「快照确实建出来了」必须核**本次的实际产物**: 恰好新出现一份目录, 且归档与服务前像都在。
  if (( SNAPOK == 0 )); then
    : # 观测无效已经各自报过红了 —— 不再拿一个"产品没建快照"的结论去盖观测自己的毛病
  elif (( SNAPN == 0 )); then
    bad "iOS 二-1: 本次没有新增任何快照目录 —— 没有本次的实际快照产物, 预告文字不算数"
  elif (( SNAPN > 1 )); then
    bad "iOS 二-1: **观测无效** —— 本次新增了 $SNAPN 个目录(${SNAPARR[*]}), 认不出哪一份是这次的, 不猜选"
  else
    # 目录名就是上面那一次受检读取里的第一项, 不再另读一遍。
    { [[ -s "$SNAPD/$SNAPNEW/snap.tar.gz" ]] && [[ -s "$SNAPD/$SNAPNEW/svcstate.tsv" ]]; } \
      && ok "iOS 二-1: 本次实际产出了快照 $SNAPNEW(归档 + 服务前像都在盘上)" \
      || bad "iOS 二-1: 本次新增目录 $SNAPNEW 里缺归档或服务前像"
  fi
  grep -q '不具备可靠回滚能力' $E2E_TMP/mig3.log \
    && bad "iOS 二-1: 合法调用方仍被门拒(产品侧问题, 本轮不改产品): $(grep -A2 '不具备可靠回滚能力' $E2E_TMP/mig3.log | head -3)" \
    || ok "iOS 二-1: 带句柄的公开入口没有被退役门拦下"
  [[ "$(gms)" == 0 ]] && ok "iOS: GMS 入站被清理干净(iOS 走 APNs 用不到)" || bad "iOS 仍有 $(gms) 条 GMS 入站"
  { [[ -e /opt/pdg-bot/probe81.py ]] && [[ -e /etc/systemd/system/pdg-probe81.service ]]; } \
    && ok "iOS: iOS 组件保留" || bad "iOS 组件被误删"
  [[ ! -e /etc/privdns-gateway/platform.guessed ]] && ok "iOS: 已确认平台不打推测标记" || bad "已确认平台仍被当成推测"
  # ── 退役契约: 迁移必须**撤除**执行面, 而不是补上 ──
  for f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
    [[ -e "$f" ]] && bad "iOS: 迁移后仍残留已退役的 $f" || ok "iOS: 已撤除 $(basename "$f")"
  done
  # "文件不在"不够: 服务必须真的停过, 且现在确实不在跑。
  grep -qE 'disable --now pdg-mitm|stop pdg-mitm' "$E2E_TMP/e2e-calls.log" \
    && ok "iOS: 确实对 pdg-mitm 发过 stop/disable(有调用记录)" || bad "iOS: 没看到停服务的调用"
  [[ "$(systemctl is-active pdg-mitm)" != active ]] \
    && ok "iOS: pdg-mitm 现在确实不在运行" || bad "iOS: pdg-mitm 还活着"
  # 保留策略: 旧 CA 不销毁, 而且必须给出手机端撤信任的提示。
  [[ -s /etc/privdns-gateway/ca/ca.crt ]] \
    && ok "iOS: 旧 CA 材料按保留策略未删" || bad "iOS: 旧 CA 被迁移删掉了"
  grep -q '按保留策略未删' $E2E_TMP/mig3.log && ok "iOS: 迁移点名了盘上仍有 CA 材料" \
    || bad "iOS: 没提示 CA 残留: $(tail -3 $E2E_TMP/mig3.log)"
  grep -q '取消对 PrivDNS Gateway' $E2E_TMP/mig3.log \
    && ok "iOS: 给出了手机端撤销信任的指引(退役不会自动取消已给出的信任)" \
    || bad "iOS: 缺撤信任提示"
  # 共享劫持锚点保留且休眠 —— 撤的是 WLOC 专属面, 不是 force_hijack 结构。
  [[ -e /etc/mosdns/rules/mitm_hijack.txt && ! -s /etc/mosdns/rules/mitm_hijack.txt ]] \
    && ok "iOS: 共享劫持锚点仍在且为空(休眠, 没被一并删掉)" \
    || bad "iOS: mitm_hijack.txt 状态不对"
  cp /etc/sing-box/config.json $E2E_TMP/s2
  # 二跑同样走公开入口(退役已经做完, 这里验的是它自己幂等)。
  bash /usr/local/bin/pdg migrate >$E2E_TMP/mig3b.log 2>&1
  RC3B=$?
  echo "   [记录] iOS 二-2: 二跑 pdg migrate 退出码 = $RC3B(阶段证据在 mig3b.log)"
  # 同上: 二跑的真实退出码也自成一条判据。"配置没变、制品没回来"在**根本没执行产品**的时候
  # 一样成立 —— 那正是它顶替不了退出码的原因。
  [[ "$RC3B" == 0 ]] \
    && ok "iOS 二-2: 二跑整体成功(实际退出码 0)" \
    || bad "iOS 二-2: **二跑没跑成功**(实际退出码 $RC3B) —— 下面的幂等判据即使全绿, 也不算这一次通过: $(tail -3 $E2E_TMP/mig3b.log)"
  cmp -s $E2E_TMP/s2 /etc/sing-box/config.json && ok "iOS: 二跑幂等" || bad "iOS 二跑改动了 model"
  # 退役迁移自己也要幂等: 没有残留时二跑不该报错, 也不该把制品弄回来。
  _again=0
  for f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py; do
    [[ -e "$f" ]] && _again=1
  done
  [[ "$_again" == 0 ]] && ok "iOS: 二跑后退役制品仍然不在(退役迁移幂等)" || bad "iOS: 二跑把退役制品弄回来了"
fi

# ══ 场景三起: 正常迁移走公开入口 `pdg migrate` ═══════════════════════════════
# 277 基线查明: 场景三到九原先用无句柄的内部入口 `pdg __migrate`。这些格的机器都是**确认的**
# android, 身上又有 iOS 专属件(共享夹具按通配装进来的), 于是退役前置整条拒掉, 目标迁移一个
# 都没到达 —— 其中几条 OK 是"链根本没动"时的空转通过。公开入口 `pdg migrate` 由真实产品自己
# 建快照、服务前像与句柄, 正是用户手打迁移的那条路。无句柄入口的拒绝由场景二-0 专门验,
# 父子继承锁的内部入口由场景七a 专门验, 这里不混用。
# 每次调用都把真实退出码和完整输出落到 $E2E_TMP/<名>.log, 不再丢弃 —— 否则判据会在调用
# 根本没跑成的时候照样成立。$1 = 日志名; 退出码原样交回。
pmig(){
  bash /usr/local/bin/pdg migrate >"$E2E_TMP/$1.log" 2>&1
  local rc=$?
  echo "   [记录] $1: pdg migrate 退出码 = $rc(完整输出在 $1.log)"
  return "$rc"
}
# 到达证据: 在日志里找**目标迁移自己**说的那句话(固定字符串, 取自产品源码, 归属唯一)。
# "日志里没有报错文案"证明不了到达 —— 一次根本没执行的调用, 日志同样是空的。三态结算:
# 找到 = OK; 确认没有 = FAIL; grep 自己出错 = 观测无效(单列, 既不当"没有"也不当"有")。
# $1=日志名 $2=产品原句 $3=判据说明
reach(){
  [[ -n "$2" ]] || { bad "$3 —— 判据原句为空, 无从核对(不按\"找到\"算)"; return 0; }
  grep -qF -- "$2" "$E2E_TMP/$1.log"
  case $? in
    0) ok "$3" ;;
    1) bad "$3 —— $1.log 里没有目标迁移的这句输出: 「$2」" ;;
    *) bad "**观测无效** —— 查 $1.log 失败(grep 出错), 不判定到达与否: $3" ;;
  esac
}

# ══ 场景三: 已是新形态 + gfw 模式 → 劫持门必须保留 ═══════════════════════════
echo; echo "── 场景三: 新形态 + gfw 模式 ──"
rm -f /etc/privdns-gateway/platform.guessed
printf 'android\n' > /etc/privdns-gateway/platform
e2e_seed_mosdns gfw
pmig mig3g; rc=$?
[[ "$rc" == 0 ]] && ok "gfw 模式: 迁移整体成功(实际退出码 0)" || bad "gfw 模式: 迁移退出码 $rc: $(tail -3 $E2E_TMP/mig3g.log)"
{ [[ "$(gate)" == 2 ]] && grep -q 'geosite_gfw.txt' /etc/mosdns/config.yaml; } \
  && ok "gfw 模式: 劫持门保留且指向 gfw 劫持集(迁移不把它当 all 拆掉)" || bad "gfw 门=$(gate)"


# ══ 场景四: v1.7.0 机器 → 明确代理必须先于 geosite_cn 判断 ═══════════════════
# v1.7.0 及更早, 用户在 bot 里点名指到出口的域名只在 hijack_set 那道门被查, 而那道门排在
# geosite_cn **之后**。上游 geosite 一旦把某域名归进 CN, DNS 就先返真实地址, 流量根本不进
# 内核 —— 规则在、doctor 绿、就是不生效。这里跑真的 `pdg migrate`, 验的是"老机器升上来
# 之后这件事被修好了, 而用户自己的东西一样没动"。
echo; echo "── 场景四: v1.7.0 机器升级(指定域名优先级)──"
# 迁移走 pdgtx: 候选要过 mosdns 强校验(**真启动 mosdns**)。拿不到二进制这条就没得验。
e2e_fetch_mosdns || e2e_skip "取不到 mosdns 二进制(明确代理迁移的候选校验要真启动它)"

seed_v170_box(){
  e2e_seed_mosdns all
  # 退回 v1.7.0 形态: 摘掉本次新增的域名集 / 序列 / 判断
  python3 "$E2E_ROOT/tests/helpers/strip-explicit-proxy.py" /etc/mosdns/config.yaml \
    || bad "退回 v1.7.0 形态失败"
  # 用户自己改过的 DNS 上游(bot『🌐 DNS 上游』写的)—— 迁移必须原样保留
  sed -i 's#udp://223.5.5.5:53#udp://180.76.76.76:53#' /etc/mosdns/config.yaml
  # 用户自己的规则/劫持表; 老机器上**没有** ruleset_hijack.txt(迁移要负责补出来)
  printf '# pdg-bot 显式出口域名劫持表\ndomain:perfops2.byte-test.example\n' > /etc/mosdns/rules/custom_hijack.txt
  printf 'domain:direct.example\n' > /etc/mosdns/rules/custom_direct.txt
  rm -f /etc/mosdns/rules/ruleset_hijack.txt
  # 另一台机器上管理员自己往 ruleset_hijack.txt 里写了 174 条 —— 迁移只该在它**不存在**时
  # 建空文件。第一版写成了无条件 `: > file`, 于是 .200 更新时那 174 条被清成 0 字节
  # (而且是在事务失败回滚**之前**清的, 回滚也救不回来)。ADMIN_RS 用例覆盖这条。
  printf 'android\n' > /etc/privdns-gateway/platform
  printf 'mihomo\n'  > /etc/privdns-gateway/backend
  rm -f /etc/privdns-gateway/platform.guessed
  # 真机上 mosdns 是有 unit 的 —— 迁移正是靠它决定"要不要真起一遍校验新配置"。沙箱缺了这个
  # 文件, 迁移就走"本机无 mosdns 服务"那条分支, 于是校验那段代码在 e2e 里从没被跑到过。
  [[ -e /etc/systemd/system/mosdns.service ]] || \
    printf '[Unit]\nDescription=mosdns (e2e)\n[Service]\nExecStart=/usr/local/bin/mosdns start\n' \
      > /etc/systemd/system/mosdns.service
}
# 这三个探针量的是"判据在 internal_sequence 里的先后", 所以要认**判据那一行的形态**
# (`- matches: qname $X`), 不能只认裸的 tag 名。v1.11.0 的去广告受管块里有一行
# `- "!qname $explicit_proxy"`(第三方表不得压过用户显式分流那条合取), 它排在真判据之前 ——
# 裸 tag 加 head -1 会抓到它, 于是"顺序不对"报的是探针自己的位置, 与被测顺序无关。
epline(){ grep -n -- '- matches: qname \$explicit_proxy' /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }
# "明确代理这条判据装上了没有" —— 与 epline 同一个理由: 认判据那一行的形态。裸 tag 会被
# 去广告受管块里的 `- "!qname $explicit_proxy"` 满足, 那几处 `&& ok` 就会在真判据缺失时**假绿**
# (比假红更难发现)。这里只留一个真源, 四处调用都走它。
ep_installed(){ grep -q -- '- matches: qname \$explicit_proxy' /etc/mosdns/config.yaml; }
cnline(){ grep -n 'qname \$geosite_cn'     /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }
fhline(){ grep -n 'qname \$force_hijack'   /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }

seed_v170_box
grep -q explicit_proxy /etc/mosdns/config.yaml && bad "前置: 没退回 v1.7.0 形态"
pmig mig4
rc=$?
[[ "$rc" == 0 ]] && ok "v1.7.0 迁移整体成功(exit 0)" || bad "迁移退出码 $rc: $(tail -5 $E2E_TMP/mig4.log)"

{ grep -q '^  - tag: explicit_proxy$' /etc/mosdns/config.yaml \
  && grep -q '^  - tag: explicit_proxy_seq$' /etc/mosdns/config.yaml \
  && [[ -n "$(epline)" ]]; } \
  && ok "补齐: 明确代理域名集 + 劫持序列 + internal_sequence 判断" \
  || bad "补齐失败: $(tail -5 $E2E_TMP/mig4.log)"
EP="$(epline)"; CN="$(cnline)"; FH="$(fhline)"
{ [[ -n "$EP" && -n "$CN" && -n "$FH" ]] && [[ "$FH" -lt "$EP" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "执行顺序: force_hijack($FH) → explicit_proxy($EP) → geosite_cn($CN)" \
  || bad "顺序不对: force_hijack=$FH explicit_proxy=$EP geosite_cn=$CN"
[[ -f /etc/mosdns/rules/ruleset_hijack.txt ]] \
  && ok "补出 ruleset_hijack.txt(域名集要求文件存在, 缺了 mosdns 起不来)" \
  || bad "没补 ruleset_hijack.txt"
# 机器上装着 mosdns 服务时, 迁移必须**真起一遍**确认新配置能加载 —— 不能只写文件就报成功。
# v1.7.2 在 .200 上正是打出"未起 mosdns 校验: 本机无 mosdns 服务"然后直接报成功的: 判据
# 写成了 `systemctl list-units --all | grep -q`, 在 set -o pipefail 下是个按 unit 数量
# 决定成败的竞态。
grep -q '未起 mosdns 校验' $E2E_TMP/mig4.log \
  && bad "装着 mosdns 服务却跳过了校验(判据又变成竞态了?)" \
  || ok "有 mosdns 服务时确实做了启动校验, 没走「本机无 mosdns 服务」那条"
# 管理员已经写过内容的机器: 迁移一个字节都不许动
seed_v170_box
printf 'domain:admin-kept.example\ndomain:admin-kept2.example\n' > /etc/mosdns/rules/ruleset_hijack.txt
RSH_BEFORE="$(sha256sum /etc/mosdns/rules/ruleset_hijack.txt | cut -d" " -f1)"
pmig mig4b; rc=$?
[[ "$rc" == 0 ]] && ok "保留管理员内容的这一次迁移整体成功(实际退出码 0)" \
  || bad "保留管理员内容的这一次迁移退出码 $rc —— 下面「逐字节保留」在链没跑时也成立, 不算通过: $(tail -3 $E2E_TMP/mig4b.log)"
[[ "$(sha256sum /etc/mosdns/rules/ruleset_hijack.txt | cut -d" " -f1)" == "$RSH_BEFORE" ]] \
  && ok "已有内容的 ruleset_hijack.txt 逐字节保留(不许无条件清空)" \
  || bad "管理员写的 ruleset_hijack.txt 被迁移清掉了($(wc -l < /etc/mosdns/rules/ruleset_hijack.txt) 行)"
ep_installed \
  && ok "保留内容的同时迁移照常完成" || bad "这次迁移没完成"
sed -n '/- tag: explicit_proxy$/,/^  - tag: /p' /etc/mosdns/config.yaml > $E2E_TMP/ep_set.txt
{ grep -q 'custom_hijack.txt' $E2E_TMP/ep_set.txt && grep -q 'ruleset_hijack.txt' $E2E_TMP/ep_set.txt; } \
  && ok "明确代理集含 custom_hijack.txt + ruleset_hijack.txt" || bad "明确代理集文件不全"
sed -n '/- tag: explicit_proxy_seq$/,/^  - tag: /p' /etc/mosdns/config.yaml > $E2E_TMP/ep_seq.txt
grep -q "black_hole $E2E_SIP" $E2E_TMP/ep_seq.txt \
  && ok "A 记录劫持到本机网关地址 $E2E_SIP" || bad "劫持目标不是 $E2E_SIP"
{ grep -q 'qtype 28' $E2E_TMP/ep_seq.txt && grep -q 'qtype 65' $E2E_TMP/ep_seq.txt; } \
  && ok "AAAA / HTTPS(65) 抑制就位" || bad "序列缺 AAAA/HTTPS 抑制"
# 普通代理域名不得被送进 MITM: 两条劫持序列必须分开, 且 mitm_hijack.txt 仍是空的
{ grep -q 'goto force_hijack_seq' /etc/mosdns/config.yaml && ! grep -q 'mitm_hijack' $E2E_TMP/ep_set.txt; } \
  && ok "明确代理集不含 mitm_hijack.txt(不会误送 pdg-mitm)" || bad "明确代理与 MITM 接管混在一起了"
[[ ! -s /etc/mosdns/rules/mitm_hijack.txt ]] \
  && ok "mitm_hijack.txt 仍为空(迁移没往里写普通代理域名)" || bad "mitm_hijack.txt 被写入了内容"

# 用户自己的东西一样都不能动
grep -q 'udp://180.76.76.76:53' /etc/mosdns/config.yaml \
  && ok "保留: 用户自己改过的 DNS 上游" || bad "用户 DNS 上游被覆盖了"
grep -q 'perfops2.byte-test.example' /etc/mosdns/rules/custom_hijack.txt \
  && ok "保留: 用户的出口劫持表" || bad "custom_hijack.txt 被动了"
grep -q 'direct.example' /etc/mosdns/rules/custom_direct.txt \
  && ok "保留: 用户的直连表" || bad "custom_direct.txt 被动了"
{ grep -q 'client_limiter' /etc/mosdns/config.yaml && grep -q 'unlock.txt' /etc/mosdns/config.yaml \
  && grep -q 'geosite_geolocation-!cn.txt' /etc/mosdns/config.yaml; } \
  && ok "保留: 限流 / 解锁支 / 劫持集(all 模式形态未退化)" || bad "既有形态被改坏"
[[ "$(grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml)" == 0 ]] \
  && ok "all 模式仍是排除式(没有被顺手装上劫持门)" || bad "all 模式被装了劫持门"

# 幂等 + 没有留下未完事务
cp /etc/mosdns/config.yaml $E2E_TMP/m4
pmig mig5; rc=$?
[[ "$rc" == 0 ]] && ok "二跑整体成功(实际退出码 0)" \
  || bad "二跑退出码 $rc —— 下面的幂等判据即使成立也不算这一次通过: $(tail -3 $E2E_TMP/mig5.log)"
cmp -s $E2E_TMP/m4 /etc/mosdns/config.yaml && ok "二跑幂等(mosdns 配置逐字节不变)" || bad "二跑改动了 mosdns 配置"
[[ -z "$(python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null)" ]] \
  && ok "没有遗留未完成事务" || bad "留下了 pending 事务"

# doctor 要认这台机器已经修好了
python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc4.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" $E2E_TMP/doc4.json ok \
  && ok "doctor: 指定域名优先级判 ok" || bad "doctor 没判 ok: $(cat $E2E_TMP/doc4.json 2>/dev/null | head -c 200)"

# ══ 场景五: 自定义形态 → fail-closed, 现网不动, doctor 点名 ═══════════════════
echo; echo "── 场景五: 认不出的自定义 mosdns 形态 ──"
seed_v170_box
# 把迁移赖以定位的锚点拆掉 = "高度自定义、无法安全识别"
python3 "$E2E_ROOT/tests/helpers/break-mosdns-anchor.py" /etc/mosdns/config.yaml || bad "构造自定义形态失败"
# 先跑一遍让**与本次无关**的迁移(如内存模式决定的 cache size)各自落定 —— 否则"配置有没有
# 被改"会被别人的正常改动淹掉, 断言就成了对整条迁移链的模糊判断。
pmig mig6a; rc=$?
# 两件事分开判: 明确代理那一步在认不出的形态上局部拒绝(fail-closed, 它自己 return 0, 链上是
# `|| true`), 与整次命令成功(正常契约返回 0)。局部拒绝不会让整次命令非零 —— 任何非零都记失败,
# 不当成"预期拒绝"。
[[ "$rc" == 0 ]] && ok "自定义形态首跑: 整次命令成功(实际退出码 0)" \
  || bad "自定义形态首跑: 整次命令异常退出(实际退出码 $rc) —— 预期拒绝时整次仍返回 0, 这不是预期拒绝: $(tail -3 $E2E_TMP/mig6a.log)"
# 产品里好几处迁移都会说"自定义形态"; 这里认的是明确代理那一步自己的那句。
reach mig6a '自定义形态, 指定域名优先级未迁移' "自定义形态: 首跑就到达了明确代理迁移的形态判断, 由它 fail-closed"
grep -q explicit_proxy /etc/mosdns/config.yaml \
  && bad "自定义形态: 竟然把明确代理插进去了(该 fail-closed)" \
  || ok "自定义形态: 一次都没往认不出的配置里插东西(fail-closed)"
cp /etc/mosdns/config.yaml $E2E_TMP/m5
pmig mig6; rc=$?
[[ "$rc" == 0 ]] && ok "自定义形态二跑: 整次命令成功(实际退出码 0)" \
  || bad "自定义形态二跑: 整次命令异常退出(实际退出码 $rc) —— 预期拒绝时整次仍返回 0, 这不是预期拒绝: $(tail -3 $E2E_TMP/mig6.log)"
cmp -s $E2E_TMP/m5 /etc/mosdns/config.yaml \
  && ok "自定义形态: 现网配置逐字节未被改(不猜着改)" \
  || bad "自定义形态下配置被改了: $(diff -u $E2E_TMP/m5 /etc/mosdns/config.yaml | head -20 | tr '\n' '|')"
# 二跑同样只认明确代理那一步自己的那句 —— 泛化的"自定义形态"别的迁移(防火墙 include 点、
# 用户劫持表)也会说, 不能拿来证明这一步到达。
reach mig6 '自定义形态, 指定域名优先级未迁移' "自定义形态: 迁移明确说明未迁移"
[[ -z "$(python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null)" ]] \
  && ok "自定义形态: 没开事务, 也没留 pending" || bad "自定义形态下留了 pending 事务"
python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc5.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" $E2E_TMP/doc5.json warn \
  && ok "doctor: 点名这台机器未迁移(warn)" || bad "doctor 没点名: $(cat $E2E_TMP/doc5.json 2>/dev/null | head -c 200)"


# ══ 场景六: 未完成事务 —— 该挡的挡, 不该挡的不许挡 ══════════════════════════
# 线上两台机器上都躺着几笔定时 geosite 更新留下的 PREPARING(开了但从没应用过)。它们不改现网、
# 也不挡任何写入, 但 `pdgtx pending` 会把它们打印出来。迁移若拿"输出非空"当判据, 就会在**恰恰
# 最需要修的那些机器上**静默跳过: update 照样报成功, 分流照样不生效, 没有任何一处会报错。
echo; echo "── 场景六: 陈旧 PREPARING 不挡迁移 / 真需收尾的事务要挡 ──"
TXROOT=/var/lib/privdns-gateway/tx

# 6a. 陈旧 PREPARING(3 天前, 从没应用过)→ 迁移照常进行
seed_v170_box
rm -rf "$TXROOT"; mkdir -p "$TXROOT"
stale="$(python3 "$E2E_ROOT/tests/helpers/seed-stale-tx.py" "$TXROOT" PREPARING 3)"
python3 /opt/pdg-bot/pdgtx.py pending 2>/dev/null | grep -q "$stale" \
  && ok "前置: 陈旧 PREPARING 确实会出现在 pending 输出里(判据不能只看输出)" \
  || bad "前置: 没造出陈旧 PREPARING"
pmig mig7; rc=$?
[[ "$rc" == 0 ]] && ok "陈旧 PREPARING 在场: 迁移整体成功(实际退出码 0)" \
  || bad "陈旧 PREPARING 在场: 迁移退出码 $rc: $(tail -3 $E2E_TMP/mig7.log)"
ep_installed \
  && ok "陈旧 PREPARING 在场: 迁移照常完成(没被无关事务挡住)" \
  || bad "陈旧 PREPARING 在场时明确代理没装上 —— 不预设是谁挡的, 日志里的拒绝/事务提示: $(grep -E '❌|事务' $E2E_TMP/mig7.log | head -2 | tr '\n' ' ')"

# 6b. 真正需要收尾的事务(APPLYING)→ 必须挡住, 且现网一个字节不动
seed_v170_box
rm -rf "$TXROOT"; mkdir -p "$TXROOT"
pmig mig8a; rc=$?   # 先让无关迁移落定
[[ "$rc" == 0 ]] && ok "6b 前置: 先让无关迁移落定的那一次整体成功(实际退出码 0)" \
  || bad "6b 前置: 落定那一次退出码 $rc: $(tail -3 $E2E_TMP/mig8a.log)"
python3 "$E2E_ROOT/tests/helpers/strip-explicit-proxy.py" /etc/mosdns/config.yaml || bad "6b 前置失败"
applying="$(python3 "$E2E_ROOT/tests/helpers/seed-stale-tx.py" "$TXROOT" APPLYING 0)"
cp /etc/mosdns/config.yaml $E2E_TMP/m6b
pmig mig8; rc=$?
# 拒绝必须由**事务检查那一层**做出: 到达明确代理迁移里的事务判断、点名本格那笔事务、配置未动。
# 那一层拒绝后自己 return 0, 链上其余迁移照常, 整次命令正常返回 0 —— 两件事分开判: 任何非零
# 都记失败, 不许拿退役门、缺依赖或别的提前失败顶替事务检查的拒绝。
[[ "$rc" == 0 ]] && ok "APPLYING: 整次命令成功(实际退出码 0)" \
  || bad "APPLYING: 整次命令异常退出(实际退出码 $rc) —— 预期拒绝时整次仍返回 0, 这不是预期拒绝: $(tail -3 $E2E_TMP/mig8.log)"
reach mig8 '有需要收尾的配置事务' "APPLYING: 到达了明确代理迁移里的事务检查, 由它拒绝"
ep_installed \
  && bad "APPLYING 事务在场却照样迁移了(该挡没挡)" \
  || ok "APPLYING 事务在场: 迁移拒绝执行"
cmp -s $E2E_TMP/m6b /etc/mosdns/config.yaml && ok "拒绝时现网配置逐字节未动" || bad "拒绝了却改了配置"
# 事务 id 为空时 `grep ""` 会匹配任何日志 —— reach 对空原句直接判失败。
reach mig8 "$applying" "迁移日志点名了挡路的事务 id"
rm -rf "$TXROOT"; mkdir -p "$TXROOT"


# ══ 场景七: 迁移在**持锁的父进程**下完成; 与旁人持锁时被挡住 ═════════════════
# 真实调用链是 cmd_update(持着 /run/privdns-gateway.lock)→ 子进程 `pdg __migrate` → 各迁移。
# 迁移里若去开 Python pdgtx 事务, 抢的是**同一把 flock**, 必然拿到 "BUSY: 已有配置操作正在
# 执行" —— 事务回滚, update 照样报成功, 只有 doctor 那条告警露馅。v1.7.1 发布当天 .200 就是
# 这么被挡掉的。
#
# 这个场景原来用"另起一个进程按住锁"来近似 cmd_update 的处境。那时 `__migrate` 自己完全
# 不取锁, 两者看起来等价 —— 但它们从来就不是一回事:
#   · cmd_update 的子进程**继承**父进程那个已经持锁的 fd, 用的是同一把锁;
#   · 旁人按住锁时, `__migrate` 是个**毫无关系的第三方**, 它去改 unit/nft/mosdns/profile
#     恰恰是全局锁要拦的那种并发写。
# v1.8.1 把这件事分清楚了(_lock 认继承来的 fd, 认不出就老实去抢), 所以这里也分成两格:
# 7a 按真实形态构造(父进程持锁并把 fd 传下去), 7b 验反面。
#
# ── 这是**并发保护收紧, 不是放宽**(契约变更备案, 勿再改回去)────────────────────
# 旧断言"第三方持锁时迁移仍必须完成"已被**正式废弃**, 不得恢复。它当年成立只是因为
# `__migrate` 一把锁都不取 —— 那不是设计, 是漏洞的副作用: 迁移会改 unit / nft / mosdns /
# profile.env, 在别人持着全局写锁时照跑, 正是这把锁存在的理由所要禁止的事。
# 变更后允许的集合**只减不增**:
#   · 原本能跑的(cmd_update 的子迁移)→ 现在照样能跑, 而且是名正言顺地复用同一把锁;
#   · 原本不该跑却能跑的(第三方持锁时的独立迁移)→ 现在被挡住, 且现网零改动。
# 顺带修掉的另一半: 旧实现下这条路径一旦真的去取锁(如首次启用救援平面调 _rescue_enable),
# `_lock` 是 `exit 1` 而不是 `return`, 整个 __migrate 进程当场消失, cmd_update 据此回滚 ——
# v1.7.8 → v1.8.0 的用户就卡在这里。
echo; echo "── 场景七a: cmd_update 那样持锁并传下 fd 时, 迁移照常完成 ──"
seed_v170_box
# 本格自己播出**具名**的待退役对象: 确认 android 机上的一件 iOS 专属模块, 取自仓库源码(与
# v1.4.x "iOS 组件装给所有机器"同形)。前面各格走公开入口, Android 清理会合法地删掉这类件,
# 所以不能指望它还在 —— 这里自己放一件并先确认。它在场, 退役前置就必须去问调用方能力。
RETIRE_OBJ=/opt/pdg-bot/iosprofile.py
install -m755 "$E2E_ROOT/deploy/bot/iosprofile.py" "$RETIRE_OBJ"
{ [[ -f "$RETIRE_OBJ" && "$(cat /etc/privdns-gateway/platform)" == android && ! -e /etc/privdns-gateway/platform.guessed ]] \
  && ! ep_installed; } \
  && ok "七a 前置: 确认 android + 具名待退役件 $(basename "$RETIRE_OBJ") 在场 + 明确代理尚未迁移" \
  || bad "七a 前置: 现场没播对(待退役件/平台/目标迁移状态不符), 本格结论不成立"
LOCKF="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
mkdir -p "$(dirname "$LOCKF")"
cat > $E2E_TMP/mig9-parent.sh <<'MP'
# 与 cmd_update 同形: 持锁 → 在**自己进程里**调真实 cmd_snapshot(快照与服务前像由它一次存好
# 并校验)→ 核同一份前像 → 起继承 fd 9 的子进程 `PDG_UPDATE_SVCSTATE=… pdg __migrate`。
# cmd_snapshot 与它的依赖按名取自**当前已安装**的 /usr/local/bin/pdg(那个文件末尾是主分派,
# 不能整份 source)。缺任何一件就停: 不补替身、不手写记录、不二次采样。cmd_snapshot 不放进
# 命令替换或另一个进程 —— 那样写前像的就不是这个持锁父进程了。
# 每一步的返回码都看: 快照返回非零、子进程接手前的任何观测取不到, 都**不启动**子迁移 ——
# 不因为产物恰好在盘上就往下走, 也不重采样、不改写前像。
set -uo pipefail
exec 9>"${LOCKF}"
flock -n 9 || { echo "PARENT-LOCK-FAILED"; exit 9; }
PDG_BIN=/usr/local/bin/pdg
for v in 'REPO_DIR=' 'LOCK=' 'PDG_LOCKED=' 'SNAP_DIR=' '_PDG_SNAP_CREATED=' '_SNAP_SOURCES=' \
         '_SNAP_OPS=' '_SNAP_META_SCHEMA=' 'declare -A _PDG_WANT_EN=' '_PDG_SVC_MODE=' \
         '_PDG_SVC_WHY=' '_PDG_SVC_SRC='; do
  l="$(grep -m1 -e "^$v" "$PDG_BIN")" && eval "$l" || { echo "PARENT-MISSING=var:$v"; exit 8; }
done
for f in c_g c_y need_root _lock_inherited _lock _pdg_mktemp_dir _pdg_svc_known _pdg_svc_q \
         _pdg_svcstate_units _pdg_svcstate_valid _pdg_svcstate_plan _pdg_save_svcstate \
         _sb_panel_managed_on _sb_write_sanitized _snap_meta_write cmd_snapshot; do
  b="$(grep -m1 -E "^${f}\(\)\{.*\}[[:space:]]*\$" "$PDG_BIN")" || b="$(sed -n "/^${f}(){/,/^}/p" "$PDG_BIN")"
  { [[ -n "$b" ]] && eval "$b" && declare -F "$f" >/dev/null; } || { echo "PARENT-MISSING=fn:$f"; exit 8; }
done
echo "PARENT-PID=$$"
PSTART="$(awk '{print $22}' "/proc/$$/stat")" && [[ "$PSTART" =~ ^[0-9]+$ ]] \
  || { echo "PARENT-OBS-INVALID=parent-start"; exit 6; }
echo "PARENT-START=$PSTART"
cmd_snapshot --source cli --op update >"$E2E_TMP/mig9-snap.log" 2>&1
SRC=$?
echo "SNAP-RC=$SRC"
(( SRC == 0 )) || { echo "PARENT-SNAP-FAILED=rc"; exit 7; }
SNAP="$_PDG_SNAP_CREATED"
echo "SNAP-CREATED=$SNAP"
[[ -n "$SNAP" && -f "$SNAP/snap.tar.gz" && -f "$SNAP/svcstate.tsv" ]] || { echo "PARENT-SNAP-FAILED=artifacts"; exit 7; }
_pdg_svcstate_plan "$SNAP" || { echo "PARENT-PLAN-FAILED=${_PDG_SVC_WHY:-}"; exit 7; }
_PDG_SVC_SRC=""; _PDG_SVC_MODE=blind
HP="$(awk -F'\t' '$1=="holder_pid"{print $2; exit}' "$SNAP/svcstate.tsv")" && [[ "$HP" =~ ^[0-9]+$ ]] \
  || { echo "PARENT-OBS-INVALID=holder_pid"; exit 6; }
HS="$(awk -F'\t' '$1=="holder_start"{print $2; exit}' "$SNAP/svcstate.tsv")" && [[ "$HS" =~ ^[0-9]+$ ]] \
  || { echo "PARENT-OBS-INVALID=holder_start"; exit 6; }
echo "HOLDER-PID=$HP"
echo "HOLDER-START=$HS"
# 前像指纹: 摘要与两次 stat **各自**核退出码与输出格式, 三样都取得才输出; 任何一样失败就什么都
# 不输出并返回非零 —— 不拼空白串, 两份无效结果也就不可能被比成"相等"。
fp(){
  local h s1 s2
  h="$(sha256sum < "$SNAP/svcstate.tsv")" || return 1
  h="${h%% *}"; [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
  s1="$(stat -c '%d:%i:%s:%Y' "$SNAP/svcstate.tsv")" || return 1
  [[ "$s1" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  s2="$(stat -c '%d:%i:%s:%Y' "$SNAP/snap.tar.gz")" || return 1
  [[ "$s2" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
  printf '%s %s %s' "$h" "$s1" "$s2"
}
PRE="$(fp)" || { echo "PRE-CHILD-OBS=INVALID"; exit 6; }
echo "PRE-CHILD=$PRE"
PDG_UPDATE_SVCSTATE="$SNAP/svcstate.tsv" bash /usr/local/bin/pdg __migrate; echo "CHILD-RC=$?"
if POST="$(fp)"; then echo "POST-CHILD=$POST"; else echo "POST-CHILD-OBS=INVALID"; fi
if nw="$(find "$SNAP_DIR" -name svcstate.tsv -newer "$SNAP/svcstate.tsv")"; then
  n="$(printf '%s' "$nw" | grep -c .)"
  if (( $? <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]]; then echo "NEWER-SVCSTATE=$n"; else echo "NEWER-SVCSTATE=INVALID"; fi
else
  echo "NEWER-SVCSTATE=INVALID"
fi
MP
LOCKF="$LOCKF" bash $E2E_TMP/mig9-parent.sh >$E2E_TMP/mig9.log 2>&1
RC9P=$?
echo "   [记录] 七a: 父进程退出码 = $RC9P(完整输出在 mig9.log; 父进程内 cmd_snapshot 的输出在 mig9-snap.log)"
# 父进程的标记行一次读进来: 读失败就整体观测无效, 不消费半截内容; 只认"大写键=值"的第一次出现。
M9OBS=0; declare -A M9=()
if m9txt="$(cat "$E2E_TMP/mig9.log")"; then
  while IFS= read -r m9ln; do
    [[ "$m9ln" =~ ^([A-Z0-9-]+)=(.*)$ ]] || continue
    [[ -n "${M9[${BASH_REMATCH[1]}]+x}" ]] || M9[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
  done <<< "$m9txt"
else
  M9OBS=1
  bad "**观测无效** —— 读不了 mig9.log(cat 失败), 七a 依赖父进程标记的判据一律不下结论"
fi
m9(){ printf '%s' "${M9[$1]-}"; }
grep -q 'PARENT-LOCK-FAILED' $E2E_TMP/mig9.log \
  && bad "场景七a 前置: 父进程没拿到锁, 用例失去意义" \
  || ok "前置: 父进程持锁并把 fd 9 传给了子迁移(与 cmd_update 同形)"
# 父外壳自己的退出码单独进结算 —— 与快照返回码、子迁移返回码分开记, 谁也不顶替谁。
[[ "$RC9P" == 0 ]] && ok "七a: 父进程整体走完(父外壳退出码 0)" \
  || bad "七a: 父外壳退出码 $RC9P —— 父进程没有正常走完(停止标记: [$(for k in "${!M9[@]}"; do [[ "$k" =~ ^PARENT-(MISSING|SNAP-FAILED|PLAN-FAILED|OBS-INVALID)$ || "$k" == *-OBS ]] && printf '%s=%s ' "$k" "${M9[$k]}"; done)] —— 为空表示父进程自己没留下停止标记)"
# 以下各条都读父进程的标记; mig9.log 读不了时整段不下结论(上面已单列观测无效)。
if (( M9OBS == 0 )); then
  [[ -z "${M9[PARENT-MISSING]+x}" ]] \
    && ok "七a: cmd_snapshot 及其依赖全部按名取自当前已安装的 pdg" \
    || bad "七a: 从已安装的 pdg 按名取不到 $(m9 PARENT-MISSING) —— 缺件即停, 不补替身(本格以下结论都不成立)"
  { [[ "$(m9 SNAP-RC)" == 0 && -n "$(m9 SNAP-CREATED)" ]] \
    && [[ -z "${M9[PARENT-SNAP-FAILED]+x}" && -z "${M9[PARENT-PLAN-FAILED]+x}" ]]; } \
    && ok "七a: 持锁父进程在自己进程里调真实 cmd_snapshot, 快照与前像建成并校验通过(目录取自它置的 _PDG_SNAP_CREATED)" \
    || bad "七a: 父进程没建成快照/前像(SNAP-RC=$(m9 SNAP-RC); 快照停在=$(m9 PARENT-SNAP-FAILED); 前像校验=$(m9 PARENT-PLAN-FAILED)) —— 返回非零即停, 子迁移不启动: $(tail -2 $E2E_TMP/mig9-snap.log 2>/dev/null | tr '\n' ' ')"
  if [[ -n "${M9[PARENT-OBS-INVALID]+x}" ]]; then
    bad "**观测无效** —— 父进程读不到 $(m9 PARENT-OBS-INVALID), 不判定 holder, 子迁移未启动"
  elif [[ -z "${M9[HOLDER-PID]+x}" ]]; then
    bad "七a: 没取到前像 holder(父进程在读 holder 之前已停), 不判定 holder 是谁"
  elif [[ "$(m9 HOLDER-PID)" =~ ^[0-9]+$ && "$(m9 HOLDER-PID)" == "$(m9 PARENT-PID)" \
          && "$(m9 HOLDER-START)" =~ ^[0-9]+$ && "$(m9 HOLDER-START)" == "$(m9 PARENT-START)" ]]; then
    ok "七a: 前像的 holder 就是持锁父进程(pid $(m9 HOLDER-PID), 启动时刻 $(m9 HOLDER-START))"
  else
    bad "七a: 前像 holder 不是持锁父进程(记录 $(m9 HOLDER-PID)/$(m9 HOLDER-START), 父进程 $(m9 PARENT-PID)/$(m9 PARENT-START))"
  fi
  S9P="$(grep -c '已保存服务前像' $E2E_TMP/mig9-snap.log)"; S9PR=$?
  S9C="$(grep -c '已保存服务前像' $E2E_TMP/mig9.log)"; S9CR=$?
  if (( S9PR >= 2 || S9CR >= 2 )); then
    bad "**观测无效** —— 数前像保存次数失败(grep rc=$S9PR/$S9CR), 不判定保存了几次"
  elif [[ "$S9P" == 1 && "$S9C" == 0 ]]; then
    ok "七a: 前像只由这一次 cmd_snapshot 保存了 1 次, 子迁移没有再存"
  else
    bad "七a: 前像保存次数不对(父进程内 $S9P 次, 子迁移 $S9C 次)"
  fi
  # 指纹三态: 前置观测失败 = 子迁移不启动; 后置观测失败 = 不宣布前像未变; 都取得才比。
  if [[ -n "${M9[PRE-CHILD-OBS]+x}" ]]; then
    bad "**观测无效** —— 子进程接手前的前像指纹没取得, 子迁移未启动"
  elif [[ -n "${M9[POST-CHILD-OBS]+x}" ]]; then
    bad "**观测无效** —— 子迁移之后的前像指纹没取得, 不宣布前像未变"
  elif [[ -z "$(m9 PRE-CHILD)" || -z "$(m9 POST-CHILD)" ]]; then
    bad "七a: 前像指纹缺一份(前[$(m9 PRE-CHILD)] 后[$(m9 POST-CHILD)]) —— 父进程在取指纹之前已停"
  elif [[ "$(m9 NEWER-SVCSTATE)" == INVALID ]]; then
    bad "**观测无效** —— 查\"有没有更晚写出的前像\"失败, 不判定是否被重采样"
  elif [[ "$(m9 PRE-CHILD)" == "$(m9 POST-CHILD)" && "$(m9 NEWER-SVCSTATE)" == 0 ]]; then
    ok "七a: 子进程接手前后, 前像的摘要/inode/mtime 与快照身份都没变, 也没有更晚写出的前像(没有重采样覆盖)"
  else
    bad "七a: 前像在子进程接手后变了, 或有更晚的前像: 前[$(m9 PRE-CHILD)] 后[$(m9 POST-CHILD)] 更晚=$(m9 NEWER-SVCSTATE)"
  fi
fi
grep -q 'CHILD-RC=0' $E2E_TMP/mig9.log \
  && ok "子迁移复用了继承来的那把锁, 返回 0" \
  || bad "子迁移没跑通: $(grep -iE 'BUSY|锁|CHILD-RC' $E2E_TMP/mig9.log | head -2)"
# 父进程已经退出: 锁应能被别人重新取得。-E 把"锁被占着"与"试取本身出错"分开。
flock -n -E 200 "$LOCKF" -c true 2>/dev/null; LKR=$?
case "$LKR" in
  0)   ok "七a: 父进程退出后锁可以重新取得(没有遗留的持锁者)" ;;
  200) bad "七a: 父进程退出后锁仍被占着" ;;
  *)   bad "**观测无效** —— 试取锁本身失败(flock rc=$LKR), 不判定锁是否已释放" ;;
esac
# 具名待退役件只有在能力门放行之后才会被 Android 清理撤除; 门里含 fd 9 的只读持锁证明。
grep -qE '本次不执行迁移|不执行 WLOC 退役迁移|调用方不具备可靠回滚能力' $E2E_TMP/mig9.log; RF=$?
grep -qF 'Android: 已清理 iOS 专属残留' $E2E_TMP/mig9.log; AC=$?
if (( RF >= 2 || AC >= 2 )); then
  bad "**观测无效** —— 查 mig9.log 失败(grep rc=$RF/$AC), 不判定能力门是否放行"
elif [[ ! -e "$RETIRE_OBJ" ]] && (( AC == 0 && RF == 1 )); then
  ok "七a: 退役能力门实际核验后放行 —— 具名待退役件已由 Android 清理合法撤除, 日志无拒绝"
else
  bad "七a: 能力门没放行或没走到 Android 清理(待退役件$([[ -e "$RETIRE_OBJ" ]] && echo 仍在 || echo 已不在); 清理句 grep=$AC; 拒绝句 grep=$RF)"
fi

ep_installed \
  && ok "持锁时迁移照样完成(复用同一把锁, 没有去抢第二把)" \
  || bad "持锁时明确代理没装上 —— 不预设是谁挡的, 日志里的拒绝/锁/事务提示: $(grep -E '❌|BUSY|事务|锁' $E2E_TMP/mig9.log | head -2 | tr '\n' ' ')"
grep -qi 'BUSY' $E2E_TMP/mig9.log && bad "迁移日志里出现了 BUSY(说明还在走 pdgtx 事务)" \
  || ok "迁移日志里没有 BUSY"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "持锁时迁出来的顺序同样正确(explicit_proxy $EP < geosite_cn $CN)" \
  || bad "顺序不对: explicit_proxy=$EP geosite_cn=$CN"
cp /etc/mosdns/config.yaml $E2E_TMP/m7
pmig mig9c; rc=$?
[[ "$rc" == 0 ]] && ok "持锁迁移后的二跑整体成功(实际退出码 0)" \
  || bad "持锁迁移后的二跑退出码 $rc —— 下面的幂等判据即使成立也不算这一次通过: $(tail -3 $E2E_TMP/mig9c.log)"
cmp -s $E2E_TMP/m7 /etc/mosdns/config.yaml && ok "持锁迁移后仍然幂等" || bad "二跑又改了配置"
ls /etc/mosdns/config.yaml.preexplicit.* >/dev/null 2>&1 \
  && bad "成功后没清掉迁移备份: $(ls /etc/mosdns/config.yaml.preexplicit.* | head -1)" \
  || ok "成功后迁移备份已清理"

echo; echo "── 场景七b: 与迁移毫无关系的第三方按着锁时, 迁移必须被挡住且一字未改 ──"
# 这一格是七a 的反面, 也是全局锁存在的理由: 别人正在写配置时, 迁移去改 unit/nft/mosdns/
# profile 就是并发写。它必须报 BUSY 并**一个字节都不动**, 而不是"反正我是迁移我先上"。
seed_v170_box
cp /etc/mosdns/config.yaml $E2E_TMP/m7b
: > "$LOCKF"
( exec 9>"$LOCKF"; flock -n 9 || exit 1; : > $E2E_TMP/mig9b.held
  while [[ -e $E2E_TMP/mig9b.holding ]]; do sleep 0.05; done ) &
HOLDER=$!
: > $E2E_TMP/mig9b.holding
# 上面两句顺序反了会立刻松手 —— 先建标记再起后台会有竞态, 所以这里等它报到
for _i in $(seq 1 60); do [[ -e $E2E_TMP/mig9b.held ]] && break; sleep 0.05; done
if [[ -e $E2E_TMP/mig9b.held ]] && ! flock -n "$LOCKF" -c true 2>/dev/null; then
  ok "前置: 第三方确实按住了锁"
else
  bad "场景七b 前置: 锁没被按住, 用例失去意义"
fi
setsid bash -c 'exec 9<&-; bash /usr/local/bin/pdg __migrate' >$E2E_TMP/mig9b.log 2>&1; RC9B=$?
rm -f $E2E_TMP/mig9b.holding; wait "$HOLDER" 2>/dev/null || true; rm -f $E2E_TMP/mig9b.held
[[ "$RC9B" != 0 ]] && ok "第三方持锁时独立迁移返回非零(rc=$RC9B)" \
  || bad "竟然拿到了锁并跑完了(rc=$RC9B)"
grep -q '已有 pdg 操作在运行' $E2E_TMP/mig9b.log \
  && ok "明确告知有别的 pdg 操作在跑" || bad "没说清为什么退出: $(head -2 $E2E_TMP/mig9b.log)"
cmp -s $E2E_TMP/m7b /etc/mosdns/config.yaml \
  && ok "被挡住时现网配置逐字节未动" || bad "挡住了却还是改了配置"


# ══ 场景八: 老机器上按现有规则集补出派生劫持表 ═════════════════════════════════
# 规则集此前只写 mihomo 那一侧。all 模式下"不是国内就劫持"顺带兜住了, gfw 模式下劫持集只有
# 被墙域名 —— 规则集里的域名拿真实 IP、手机直连, 那条 RULE-SET 规则永远匹配不到。老机器上
# ruleset_hijack.txt 是空的, 更新时要按现有规则集重算一次。
echo; echo "── 场景八: 规则集派生劫持表 ──"
seed_v170_box
mkdir -p /etc/sing-box/rs
cat > /etc/sing-box/rs/rs_demo.json <<'RSJSON'
{"version": 1, "rules": [{"domain_suffix": ["derived.example", "derived2.example"],
                          "domain": ["exact.example"], "ip_cidr": ["203.0.113.0/24"]}]}
RSJSON
cat > /opt/pdg-bot/rulesets.json <<'RSMETA'
{"rs_demo": {"url": "http://example.invalid/demo.list", "outbound": "jp",
             "format": "source", "path": "/etc/sing-box/rs/rs_demo.json", "label": "演示集"}}
RSMETA
: > /etc/mosdns/rules/ruleset_hijack.txt
pmig mig10; rc=$?
[[ "$rc" == 0 ]] && ok "场景八: 迁移整体成功(实际退出码 0)" || bad "场景八: 迁移退出码 $rc: $(tail -3 $E2E_TMP/mig10.log)"

grep -q '^domain:derived.example$'  /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "按规则集派生: domain_suffix → domain:" || bad "缺 domain:derived.example"
grep -q '^domain:derived2.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "同一规则集的多个域名都派生了" || bad "缺第二个域名"
grep -q '^full:exact.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "domain → full:(精确匹配)" || bad "缺 full:exact.example"
grep -q '203.0.113' /etc/mosdns/rules/ruleset_hijack.txt \
  && bad "IP 段被写进了域名表(DNS 这一层劫不了 IP)" || ok "ip_cidr 被正确跳过"
grep -q '规则集派生劫持表' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "带表头说明(手改会被覆盖)" || bad "没有表头"

# 幂等: 二跑内容一字不变
cp /etc/mosdns/rules/ruleset_hijack.txt $E2E_TMP/rsh1
pmig mig10b; rc=$?
[[ "$rc" == 0 ]] && ok "场景八: 二跑整体成功(实际退出码 0)" \
  || bad "场景八: 二跑退出码 $rc —— 下面的幂等判据即使成立也不算这一次通过: $(tail -3 $E2E_TMP/mig10b.log)"
cmp -s $E2E_TMP/rsh1 /etc/mosdns/rules/ruleset_hijack.txt && ok "二跑幂等(派生表逐字节不变)" || bad "二跑改了派生表"

# 管理员手填过的不许覆盖 —— 那是他自己维护的数据
printf 'domain:handwritten.example\n' > /etc/mosdns/rules/ruleset_hijack.txt
pmig mig11; rc=$?
[[ "$rc" == 0 ]] && ok "手填表那一次迁移整体成功(实际退出码 0)" || bad "手填表那一次迁移退出码 $rc: $(tail -3 $E2E_TMP/mig11.log)"
grep -q '^domain:handwritten.example$' /etc/mosdns/rules/ruleset_hijack.txt \
  && ok "手填的内容没被覆盖" || bad "把管理员手填的内容冲掉了"
grep -q '手填的, 未覆盖' $E2E_TMP/mig11.log && ok "并且明确告诉了用户为什么没动" || bad "没说明"

# .mrs: 用内核自己反向导出域名清单 —— 造一份**真的** .mrs(由 mihomo 从文本转出来)
printf 'mrsdomain.example\n+.mrssuffix.example\n' > $E2E_TMP/mrssrc.txt
if mihomo convert-ruleset domain text $E2E_TMP/mrssrc.txt /etc/sing-box/rs/rs_bin.mrs >/dev/null 2>&1 \
   && [[ -s /etc/sing-box/rs/rs_bin.mrs ]]; then
  ok "造出一份真 .mrs(内核 convert-ruleset 生成)"
  cat > /opt/pdg-bot/rulesets.json <<'RSMETA2'
{"rs_bin": {"url": "http://example.invalid/geo.mrs", "outbound": "jp",
            "format": "mrs", "behavior": "domain",
            "path": "/etc/sing-box/rs/rs_bin.mrs", "label": "二进制集"}}
RSMETA2
  : > /etc/mosdns/rules/ruleset_hijack.txt
  pmig mig12; rc=$?
  [[ "$rc" == 0 ]] && ok ".mrs: 迁移整体成功(实际退出码 0)" || bad ".mrs: 迁移退出码 $rc: $(tail -3 $E2E_TMP/mig12.log)"
  grep -q '^full:mrsdomain.example$' /etc/mosdns/rules/ruleset_hijack.txt \
    && ok ".mrs: 精确域名派生成 full:" || bad ".mrs 没派生出 full:mrsdomain.example"
  grep -q '^domain:mrssuffix.example$' /etc/mosdns/rules/ruleset_hijack.txt \
    && ok ".mrs: +. 后缀域名派生成 domain:" || bad ".mrs 没派生出 domain:mrssuffix.example"
  python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc8.json 2>/dev/null
  python3 - <<'PY' && ok "doctor: .mrs 也判已同步" || bad "doctor: $(head -c 200 $E2E_TMP/doc8.json)"
import json, os, sys
d = json.load(open(os.environ["E2E_TMP"] + "/doc8.json"))
hit = [x for x in d if x.get("check") == "规则集生效状态"]
sys.exit(0 if hit and hit[0]["level"] == "ok" else 1)
PY
else
  bad "造不出 .mrs(内核不支持 convert-ruleset?), .mrs 派生这条没验到"
fi
# 坏档 / 类型认不出的 .mrs → 必须点名, 不能装作派生成功
printf 'not an mrs at all\n' > /etc/sing-box/rs/rs_bin.mrs
python3 - <<'PY' > $E2E_TMP/rsmeta-bad.json
import json, os
json.dump({"rs_bin": {"url": "http://example.invalid/geo.mrs", "outbound": "jp",
                      "format": "mrs", "path": "/etc/sing-box/rs/rs_bin.mrs",
                      "label": "坏档"}}, open(os.environ["E2E_TMP"] + "/rsmeta-bad.json", "w"))
PY
cp $E2E_TMP/rsmeta-bad.json /opt/pdg-bot/rulesets.json
: > /etc/mosdns/rules/ruleset_hijack.txt
pmig mig12b; rc=$?
# 派生那一步对坏档是 best-effort(读不出的规则集派生 0 条, 它自己 return 0, 链上是 `|| true`),
# 整次命令正常返回 0 —— 两件事分开判。doctor 那一项在全部规则集都读不出时根本不看劫持表文件
# (checks.py check_ruleset_hijack: 可派生数为 0 就跳过同步比对), 迁移没跑它照样告警, 所以替代不了
# "派生那一步真的处理过这一份"; 这里要派生那一步写出新表之后自己说的那句。
[[ "$rc" == 0 ]] && ok "坏 .mrs: 整次命令成功(实际退出码 0)" \
  || bad "坏 .mrs: 整次命令异常退出(实际退出码 $rc) —— 坏档的预期是派生 0 条、整次仍返回 0, 这不是预期结果: $(tail -3 $E2E_TMP/mig12b.log)"
reach mig12b '已按现有规则集生成劫持表' "坏 .mrs: 派生那一步实际处理了这份规则集并写出新表"
python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc8b.json 2>/dev/null
python3 - <<'PY' && ok "坏 .mrs → doctor 点名读不出域名" || bad "坏 .mrs 没被点名: $(head -c 200 $E2E_TMP/doc8b.json)"
import json, os, sys
d = json.load(open(os.environ["E2E_TMP"] + "/doc8b.json"))
hit = [x for x in d if x.get("check") == "规则集生效状态"]
sys.exit(0 if hit and hit[0]["level"] == "warn" and "读不出域名" in hit[0]["detail"] else 1)
PY
rm -f /opt/pdg-bot/rulesets.json /etc/sing-box/rs/rs_demo.json /etc/sing-box/rs/rs_bin.mrs \
      $E2E_TMP/rsh1 $E2E_TMP/mrssrc.txt $E2E_TMP/rsmeta-bad.json


# ══ 场景九: 老机器补上自定义放行的 include 点 ═════════════════════════════════
# v1.7.6 及更早的 table inet pdg 里没有 include 点。以前 nftscan 撞冲突时让人"并入
# table inet pdg 的 input chain" —— 那张表每次装机/迁移都按模板重建, 手加进去的规则下次就
# 没了, 等于建议本身行不通。迁移要给老机器补上这个不受更新影响的落点。
echo; echo "── 场景九: 自定义放行 include 点 ──"
seed_v170_box
cat > /etc/nftables.conf <<'NFTC'
#!/usr/sbin/nft -f
table inet pdg
delete table inet pdg
table inet pdg {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 22 } accept
        ip protocol icmp accept
    }
}
NFTC
rm -rf /etc/privdns-gateway/nft-input.d
pmig mig13; rc=$?
[[ "$rc" == 0 ]] && ok "场景九: 迁移整体成功(实际退出码 0)" || bad "场景九: 迁移退出码 $rc: $(tail -3 $E2E_TMP/mig13.log)"
[[ -d /etc/privdns-gateway/nft-input.d ]] \
  && ok "补出自定义放行目录" || bad "没建目录"
grep -qF 'include "/etc/privdns-gateway/nft-input.d/*.conf"' /etc/nftables.conf \
  && ok "补上 include 点" || bad "没补 include: $(grep -i include $E2E_TMP/mig13.log | head -1)"
python3 - <<'PY' && ok "include 点插在 pdg 的 input chain 内、policy drop 之后的末尾" || bad "位置不对"
import re, sys
lines = open("/etc/nftables.conf", encoding="utf-8").read().split("\n")
i = next((k for k, l in enumerate(lines) if re.match(r"^table\s+inet\s+pdg\s*\{", l)), None)
depth, cs, ce = 0, None, None
for k in range(i, len(lines)):
    depth += lines[k].count("{") - lines[k].count("}")
    if cs is None and re.search(r"^\s*chain\s+input\s*\{", lines[k]): cs, cd = k, depth
    elif cs is not None and depth < cd: ce = k; break
body = lines[cs:ce]
sys.exit(0 if any("nft-input.d" in l for l in body) and "nft-input.d" in body[-1] else 1)
PY
# 幂等
cp /etc/nftables.conf $E2E_TMP/nft1
pmig mig13b; rc=$?
[[ "$rc" == 0 ]] && ok "场景九: 二跑整体成功(实际退出码 0)" \
  || bad "场景九: 二跑退出码 $rc —— 下面的幂等判据即使成立也不算这一次通过: $(tail -3 $E2E_TMP/mig13b.log)"
cmp -s $E2E_TMP/nft1 /etc/nftables.conf && ok "二跑幂等(不重复插入)" || bad "二跑又插了一遍"
[[ "$(grep -c 'nft-input\.d' /etc/nftables.conf)" == 1 ]] \
  && ok "include 只有一份" || bad "include 重复了 $(grep -c 'nft-input\.d' /etc/nftables.conf) 次"

# 认不出的自定义防火墙形态 → 不猜着改
seed_v170_box
printf '#!/usr/sbin/nft -f\ntable inet pdg {\n  chain weird {\n    type filter hook forward priority 0;\n  }\n}\n' > /etc/nftables.conf
cp /etc/nftables.conf $E2E_TMP/nft2
pmig mig14; rc=$?
# include 点那一步在认不出的形态上局部拒绝(不猜着改, 它自己 return 0, 链上是 `|| true`), 整次命令
# 正常返回 0 —— 两件事分开判。"防火墙文件没变"在迁移根本没执行时也成立, 替代不了"那一步判断过";
# 这里要它自己说的那句。
[[ "$rc" == 0 ]] && ok "认不出的防火墙: 整次命令成功(实际退出码 0)" \
  || bad "认不出的防火墙: 整次命令异常退出(实际退出码 $rc) —— 预期拒绝时整次仍返回 0, 这不是预期拒绝: $(tail -3 $E2E_TMP/mig14.log)"
reach mig14 '防火墙是自定义形态, 未加自定义放行 include 点' "认不出的防火墙: 到达了 include 点那一步, 由它判定不猜着改"
cmp -s $E2E_TMP/nft2 /etc/nftables.conf \
  && ok "pdg 表里没有 input chain → 不动防火墙(不猜着改)" || bad "改了认不出的配置"
rm -f $E2E_TMP/nft1 $E2E_TMP/nft2

e2e_summary

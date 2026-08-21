#!/usr/bin/env bash
# SSH 放行的**来源匹配**必须活过 `pdg update` 的防火墙模板重建。
#
# 为什么这支必须存在: 收紧 SSH(只允许经 tailnet 登录)如果活不过更新, 后果不是"设置丢了"
# 那么简单 —— 用户以为公网上看不到 22 端口, 而下一次 `pdg update` 悄悄把它重建成对全网
# 开放。**没有任何提示, doctor 也全绿**, 因为对 doctor 来说那本来就是合法形态。
# 一个会自己失效的安全设置, 比没有这个设置更危险。
#
# 所以判据不是"配置项读得出来", 而是**真跑一遍 migrate_firewall_template_sync, 看重建
# 出来的那份配置里 SSH 规则还是不是收紧的**。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TPL="$ROOT/deploy/firewall/nftables-mihomo.conf"
# 救援端口从真源读, 不敲字面量(pre-commit 有守卫)
RPORT="$(python3 "$ROOT/deploy/bot/rescue_const.py" --port 2>/dev/null)"
[[ -n "$RPORT" ]] || { echo "[FAIL] 读不到救援端口常量"; exit 1; }

pass=0; nfail=0
ok(){  pass=$((pass+1)); echo "[OK]   $1"; }
bad(){ nfail=$((nfail+1)); echo "[FAIL] $1"; }
ctl(){ if [[ "$1" == "$2" ]]; then bad "反向对照: $3 —— 改坏版行为与正式版相同, 这格没有判别力"; else ok "反向对照: $3"; fi; }

# 按指定的来源匹配渲染一份"机器上正在用的配置"
render(){ # $1=SSH_MATCH $2=TAILNET_DIRECT $3=输出路径
  sed -e "s|__SSH_PORT__|22|g" -e "s|__INTERNAL_CIDR__|172.22.0.0/16|g" \
      -e "s|__SSH_MATCH__|$1|g" -e "s|__TAILNET_DIRECT__|$2|g" \
      -e "s|__RESCUE_PORT__|$RPORT|g" "$TPL" > "$3"
}

# 抽出被测函数并真跑。nft 打桩: 校验与加载都放行 —— 这一节验的是**重建出的文本**,
# 不是内核行为; 桩返回失败的话函数会提前退出, 那就什么都没测到。
run_sync(){ # $1=配置路径 $2=pdg.sh 路径
  { echo 'REPO_DIR="'"$ROOT"'"'
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "CY:$*"; }'
    echo 'nft(){ return 0; }'
    # 内核不变量检查也要打桩: 它内部起 python 读 checks 模块, 沙箱里读不到就返回非 0,
    # 于是同步走进"重新加载后仍未收敛"的早退分支 —— 那条路径根本走不到重建。
    echo '_fw_live_has_template_invariants(){ return 0; }'
    # 判据本体在 _fw_ssh_match(三处渲染共用), 必须一并抽出来 —— 少了它函数未定义,
    # 返回 127, sync 判成"形态认不出"而跳过, 于是这支测试测的是漏抽而不是产品。
    sed -n '/^_fw_tailnet_direct(){/,/^}/p' "$2"
    sed -n '/^_fw_ssh_match(){/,/^}/p' "$2"
    sed -n '/^migrate_firewall_template_sync(){/,/^}/p' "$2"
    echo 'migrate_firewall_template_sync "'"$1"'"; echo "RC=$?"'
  } > "$WORK/drv.sh"
  bash "$WORK/drv.sh" 2>&1
}

ssh_form(){ # 打印配置里 SSH 那条规则的形态
  if grep -qE '^[[:space:]]*iifname "tailscale0" tcp dport [{] ?22 ?[}] accept[[:space:]]*$' "$1"; then echo tailnet
  elif grep -qE '^[[:space:]]*tcp dport [{] ?22 ?[}] accept[[:space:]]*$' "$1"; then echo any
  else echo 认不出; fi
}

echo "── 一、对全网开放的形态: 重建后仍是对全网开放 ──"
render "" "# (SSH 未收紧为 tailnet, 故不放行 Tailscale 直连端口)" "$WORK/a.conf"
[[ "$(ssh_form "$WORK/a.conf")" == any ]] && ok "夹具就位: 初始为 any" || bad "夹具没造对"
run_sync "$WORK/a.conf" "$ROOT/deploy/bot/pdg.sh" >/dev/null
[[ "$(ssh_form "$WORK/a.conf")" == any ]] \
  && ok "重建后仍是 any(没把历史默认改掉)" || bad "any 被改成了 $(ssh_form "$WORK/a.conf")"

echo
echo "── 二、★ 收紧过的形态: 重建后必须仍然收紧 ──"
# 这一格是本文件存在的全部理由。
render 'iifname "tailscale0" ' 'udp dport 41641 accept comment "pdg-tailnet-direct"' "$WORK/b.conf"
# **必须制造与模板的差异**, 否则候选与磁盘逐字节相同, 同步会正确地什么都不写 ——
# 那样这一格测的是"没被破坏", 而不是"重建时被保住", 二者差得远。
# 删掉一行模板注释即可: 内容上无害, 但足以让候选 != 磁盘, 逼出真正的重建路径。
sed -i '0,/^# 只用独立表 inet pdg/{/^# 只用独立表 inet pdg/d}' "$WORK/b.conf"
[[ "$(ssh_form "$WORK/b.conf")" == tailnet ]] && ok "夹具就位: 初始为 tailnet 且与模板有差异" || bad "夹具没造对"
out="$(run_sync "$WORK/b.conf" "$ROOT/deploy/bot/pdg.sh")"
form="$(ssh_form "$WORK/b.conf")"
if [[ "$form" == tailnet ]]; then
  ok "重建后仍只允许经 tailnet —— 设置活过了 pdg update"
else
  bad "重建后变成 [$form] —— 用户以为 22 关着, 实际已对全网开放(而且无任何提示)"
fi
grep -q "防火墙按模板重建" <<<"$out" \
  && ok "而且确实**跑了**重建(不是因为跳过才没变)" \
  || bad "这次根本没重建, 上一条断言是空的: $(tr '\n' ' ' <<<"$out" | cut -c1-120)"

echo
echo "── 三、形态认不出时必须整体跳过(不猜) ──"
render "" "# (SSH 未收紧为 tailnet, 故不放行 Tailscale 直连端口)" "$WORK/c.conf"
sed -i 's/^\([[:space:]]*\)tcp dport { 22 } accept$/\1ip saddr 10.1.2.3 tcp dport { 22 } accept/' "$WORK/c.conf"
before="$(sha256sum "$WORK/c.conf" | cut -d' ' -f1)"
out="$(run_sync "$WORK/c.conf" "$ROOT/deploy/bot/pdg.sh")"
{ grep -q "CY:.*形态认不出" <<<"$out" \
  && [[ "$(sha256sum "$WORK/c.conf" | cut -d' ' -f1)" == "$before" ]]; } \
  && ok "第三种来源匹配 → 说明原因并跳过, 配置逐字节未动" \
  || bad "认不出却动了配置: $(tr '\n' ' ' <<<"$out" | cut -c1-140)"

echo
echo "── 四、两种形态同时存在 → 也要跳过(配置被手改过的信号) ──"
render "" "# (SSH 未收紧为 tailnet, 故不放行 Tailscale 直连端口)" "$WORK/d.conf"
sed -i 's|^\([[:space:]]*\)tcp dport { 22 } accept$|\1tcp dport { 22 } accept\n\1iifname "tailscale0" tcp dport { 22 } accept|' "$WORK/d.conf"
before="$(sha256sum "$WORK/d.conf" | cut -d' ' -f1)"
out="$(run_sync "$WORK/d.conf" "$ROOT/deploy/bot/pdg.sh")"
{ grep -q "CY:.*命中多条" <<<"$out" \
  && [[ "$(sha256sum "$WORK/d.conf" | cut -d' ' -f1)" == "$before" ]]; } \
  && ok "两条并存 → 说明原因并跳过(不替用户挑一条)" \
  || bad "并存时没跳过: $(tr '\n' ' ' <<<"$out" | cut -c1-140)"

echo
echo "── 五、反向对照: 去掉 __SSH_MATCH__ 支持, 第二格必须转红 ──"
# 反向补丁在**当前源码**上做, 不从 git 历史取 —— 锚在历史上的负控一提交就会静默失效。
OLDSH="$WORK/pdg-old.sh"
sed -e 's|^\([[:space:]]*\)-e "s|__SSH_MATCH__|\$sshm|g" \\\\$||' "$ROOT/deploy/bot/pdg.sh" > "$OLDSH" 2>/dev/null
python3 - "$ROOT/deploy/bot/pdg.sh" "$OLDSH" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding="utf-8").read()
# 把渲染时的 __SSH_MATCH__ 替换整行删掉 = 回到"模板里那个占位符永远留在原地"的状态,
# 也就是本改动之前的行为(它会让规则渲染成字面量 __SSH_MATCH__tcp ..., 形态判定为认不出)。
tgt = [l for l in s.split("\n") if "__SSH_MATCH__" in l and "$sshm" in l]
if len(tgt) != 1:
    raise SystemExit("反向补丁打空: __SSH_MATCH__ 渲染行找不到唯一一处 —— 产品换写法了")
io.open(sys.argv[2], "w", encoding="utf-8").write(s.replace(tgt[0] + "\n", ""))
PY
render 'iifname "tailscale0" ' 'udp dport 41641 accept comment "pdg-tailnet-direct"' "$WORK/e.conf"
run_sync "$WORK/e.conf" "$OLDSH" >/dev/null
ctl "$(ssh_form "$WORK/b.conf")" "$(ssh_form "$WORK/e.conf")" \
    "去掉渲染支持后, 同样的收紧配置重建成了 [$(ssh_form "$WORK/e.conf")]"

echo
echo "── 六、★ 联动: 41641 放行必须与 SSH 收紧同进同退 ──"
# 选项 A 的核心保证。拆成两个独立开关的话, 迟早出现"收紧了但没放行"的组合 —— 那正是
# 冷启动连不上的形态(入站打洞包被 policy drop 丢掉), 而且从配置上完全看不出两者有关系。
has41641(){ grep -qE '^[[:space:]]*udp dport 41641 accept' "$1" && echo 有 || echo 无; }
[[ "$(has41641 "$WORK/a.conf")" == 无 ]] \
  && ok "any 模式(未收紧)→ 不放行 41641(不平白多开一个对公网可见的 UDP 口)" \
  || bad "未收紧却放行了 41641"
[[ "$(has41641 "$WORK/b.conf")" == 有 ]] \
  && ok "tailnet 模式(已收紧)→ 放行 41641(直连随时可用, 没有冷启动窗口)" \
  || bad "收紧了却没放行 41641 —— 空闲后第一次 SSH 会超时, 而那时公网 22 已经关了"
# 注: 上面两条判的是 a.conf / b.conf 在**第一、二格同步之后**的内容 —— b.conf 在第二格里
# 已被证实真正走过重建路径, 所以这里的 41641 是重建时派生出来的, 不是夹具写死的。
# (不再单独加一格去复验"是否重建过": 那条写成 `... || ok` 就永远不会红, 是假绿。)

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: `pdg hijack-mode` 必须整笔走配置事务。
#
# 为什么要单独一支: 它改的两个文件 —— /etc/mosdns/config.yaml(mosdns_conf)与
# /etc/privdns-gateway/profile.env(profile_env)—— 都在 pdgtx 白名单里, 却曾经是就地
# 改写 + 局部 .hjbak 还原:
#   · 全局锁被别人持有时照写不误(`pdg snapshot` 同一时刻是被拦下的);
#   · 一次改写不产生任何事务记录 → 没有 before-image、没有审计、事后 recover 不到;
#   · mosdns 先覆盖现网再重启检查, profile.env 用 sed -i/>> 且完全没有回滚 ——
#     于是"mosdns 成了、profile 没成"这种半状态没有任何东西兜得住。
#
# 给将来做负控的人留一句: pdg.sh 里 `_pdg_cidr_transact` 与 `_pdg_hijack_transact` 的
# apply 收尾**逐字节相同**。想改坏 hijack 这一条来验负控时, 锚点必须带上它独有的上下文
# (如 `mos_changed` 那一行), 否则一次性替换会命中前者 —— 被测函数根本没被改坏, 测试照绿,
# 看起来像"判据抓不住", 其实是负控空转。这个坑本轮真踩过一次。
#
# 锁的用法有个坑值得写下来: 本命令**不能**调 pdg.sh 自己的 `_lock`。那个锁与 pdgtx 的
# 是同一个文件(都是 $PDG_LOCKFILE), shell 先 flock 住再让子进程 python 去 flock 同一个
# 文件, 子进程必然拿不到 → 每次都 TxBusy。cmd_detect_cidr 就是因此刻意不上 shell 锁, 只
# 靠事务核心那把。本用例的"锁被占用/锁文件不可用"两条验的正是事务核心那把锁。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v flock >/dev/null 2>&1 || e2e_skip "无 flock, 锁用例无法构造"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft mihomo
e2e_seed_cert || e2e_skip "无 openssl, 造不出占位证书"
# mosdns_conf 的候选校验器(mosdns_probe)会**真启动 mosdns** 解析候选配置 —— 拿不到二进制
# 整笔事务就 REFUSED。开发机上往往有早前 E2E 留下的一份, 于是本地全绿而 CI 全红(v1.7.0
# 就栽过同一个坑, CHANGELOG 里记着)。这里显式取, 取不到就明说跳过, 不假装通过。
e2e_fetch_mosdns || true
# 取完还要**确认真的能用**: helper 返回 0 只说明它没报错, 而 pdgtx 的 _mosdns_bin() 是
# `shutil.which("mosdns") or <FSROOT>/usr/local/bin/mosdns` —— 两条路都摸不到就直接跳过,
# 不要让"候选校验一律 REFUSED"以一堆看不懂的红出现。
command -v mosdns >/dev/null 2>&1 || [[ -x /usr/local/bin/mosdns ]] \
  || e2e_skip "拿不到可用的 mosdns 二进制(本用例的候选校验要真启动它解析配置)"
printf 'android\n' > /etc/privdns-gateway/platform
printf 'mihomo\n'  > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway /run

MC=/etc/mosdns/config.yaml
PE=/etc/privdns-gateway/profile.env
TXR=/var/lib/privdns-gateway/tx
LOCK="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"

# 凭据哨兵: 形如 TG bot token, 放进 profile.env(它是本次事务的目标之一)。
# 全程 stdout/stderr/meta/diff/审计里都不许出现它。
SENTINEL='123456789:AAHsentinelTOKENvalue000000000000000'
printf 'PDG_SENTINEL_TOKEN=%s\n' "$SENTINEL" >> "$PE"

# 两个生产文件的完整指纹: 内容 + mode + uid:gid。回滚要验的就是这三样都回去了。
fp(){ printf '%s|%s|%s||%s|%s|%s' \
        "$(sha256sum "$MC" 2>/dev/null | cut -d' ' -f1)" "$(stat -c '%a' "$MC" 2>/dev/null)" \
        "$(stat -c '%u:%g' "$MC" 2>/dev/null)" \
        "$(sha256sum "$PE" 2>/dev/null | cut -d' ' -f1)" "$(stat -c '%a' "$PE" 2>/dev/null)" \
        "$(stat -c '%u:%g' "$PE" 2>/dev/null)"; }
ntx(){ find "$TXR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l; }
# 事务目录名是 `%Y%m%dT%H%M%SZ-<uuid4 前 8 位>`(见 pdgtx.py 的 _new_txid)—— 时间戳只到秒,
# 同秒的两笔靠随机后缀区分。所以**不能**按名字排序去猜"最新的那笔": 上一个小节的事务与本次
# 的落在同一秒时, 谁排在后面纯看随机数。实测过一次: 第 10 节自己那笔是 ROLLBACK_FAILED(正确),
# 而 `sort | tail -1` 选中了第 8/9 节留下的 ABORTED, 断言于是把别人的状态读成了本次的结果 ——
# CI 上表现为约 6% 的随机红, 独立 job 与串行 job 都会中。
#
# 改成记差集: 被测命令调用前后各取一次目录集合, 新增的那一笔才是本次要断言的对象。
# 顺带把"一次操作只应产生一笔事务"变成硬门 —— 0 笔或多笔都判红, 而不是默默挑一个。
_tx_list(){ find "$TXR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort; }
tx_mark(){ _TX_BEFORE="$(_tx_list)"; }         # 在被测 CLI 调用**之前**打点
tx_created(){                                  # $1=场景名; 打印本次新增的那一笔事务目录
  local now new n
  now="$(_tx_list)"
  new="$(comm -13 <(printf '%s\n' "$_TX_BEFORE") <(printf '%s\n' "$now"))"
  n="$(grep -c . <<<"$new")"
  if [[ "$n" == 1 ]]; then printf '%s\n' "$new"; return 0; fi
  if [[ "$n" == 0 ]]; then bad "$1: 本次操作没有产生任何事务(应恰好 1 笔)"; return 1; fi
  bad "$1: 本次操作产生了 $n 笔事务(应恰好 1 笔): $(xargs -r -n1 basename <<<"$new" | tr '\n' ' ')"
  return 1
}
tx_is_ours(){                                  # $1=事务目录 $2=场景名; 核对确实是本次 CLI 操作
  local d="$1" nm="$2" src op tg
  [[ -n "$d" ]] || return 1
  src="$(tx_get "$d" source)"; op="$(tx_get "$d" op)"; tg="$(tx_get "$d" targets)"
  [[ "$src" == cli ]]           || { bad "$nm: 新增事务 source=$src(应为 cli)"; return 1; }
  [[ "$op" == hijack-mode ]]    || { bad "$nm: 新增事务 op=$op(应为 hijack-mode)"; return 1; }
  grep -q mosdns_conf <<<"$tg"  || { bad "$nm: 新增事务 targets 不含 mosdns_conf: $tg"; return 1; }
  return 0
}
tx_state(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]+'/meta.json')).get('state'))" "$1" 2>/dev/null; }
tx_get(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]+'/meta.json')).get(sys.argv[2]))" "$1" "$2" 2>/dev/null; }
cur_mode(){ sed -n 's/^PDG_HIJACK_MODE=//p' "$PE" 2>/dev/null | tail -1; }
# 故障注入场景前把起点复位到 all: 否则上一条留下的 gfw 会让"切 gfw"走幂等短路,
# 于是 rc=0、什么都没发生, 而断言会把它读成"故障没被拦住"——假绿加误判两头占。
reset_all(){ pdg hijack-mode all >/dev/null 2>&1
  [[ "$(cur_mode)" == all ]] || bad "前提复位失败: 起点是 $(cur_mode)"; }
# `grep -c` 没匹配时**既打印 0 又返回 1** —— 写成 `grep -c … || echo 0` 会打出两行 "0",
# 后面的数值比较就永远不成立(这条判据会假绿)。用 awk 数, 一行一个数。
note_skip(){ echo "[SKIP] $1"; }   # 只打印, 不计入通过
restarts(){ awk '/systemctl restart mosdns/{n++} END{print n+0}' $E2E_TMP/e2e-calls.log 2>/dev/null || echo 0; }
has_preparing(){ local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ "$(tx_state "$d")" == PREPARING ]] && { echo 1; return; }
  done < <(find "$TXR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  echo 0; }

echo "── 0. 前提 ──"
[[ "$(cur_mode)" == all ]] && ok "起点是 all 模式" || bad "起点不对: $(cur_mode)"

# ══ 1. all → gfw: 一笔事务, 两个目标, 带 restart:mosdns ═════════════════════
echo; echo "── 1. all → gfw 走事务 ──"
_n0=$(ntx); _r0=$(restarts)
tx_mark; out=$(pdg hijack-mode gfw 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "切到 gfw 返回 0" || bad "1: rc=$rc: $(tail -3 <<<"$out")"
[[ "$(cur_mode)" == gfw ]] && ok "profile.env 记为 gfw" || bad "1b: 模式是 $(cur_mode)"
# 判据要落在**劫持门**上, 不是 hijack_set 插件 —— 那个插件种子配置里本来就有(e2e_seed_mosdns
# 跑过一次 _mosdns_hijack_shape), 查它等于什么都没查, 候选被拒时照样绿。
grep -q '!qname \$hijack_set' "$MC" && ok "mosdns 装上了劫持门(gfw 形态真的落盘了)" \
  || bad "1c: 劫持门没落盘(形态没变)"
_n1=$(ntx)
if [[ "$((_n1-_n0))" == 1 ]]; then ok "正好产生 1 笔事务"; else bad "1d: 事务数 $_n0→$_n1"; fi
_TXN1="$(tx_created "1")" || _TXN1=""
tx_is_ours "$_TXN1" "1" || true
TX1="$_TXN1"
[[ "$(tx_state "$TX1")" == COMMITTED ]] && ok "事务状态 COMMITTED" || bad "1e: $(tx_state "$TX1")"
[[ "$(tx_get "$TX1" source)" == cli ]] && ok "审计 source=cli" || bad "1f: source=$(tx_get "$TX1" source)"
[[ "$(tx_get "$TX1" op)" == hijack-mode ]] && ok "审计 op=hijack-mode" || bad "1g: op=$(tx_get "$TX1" op)"
_tg=$(tx_get "$TX1" targets)
{ grep -q mosdns_conf <<<"$_tg" && grep -q profile_env <<<"$_tg"; } \
  && ok "两个目标在同一笔事务里: $_tg" || bad "1h: targets=$_tg"
grep -q 'restart:mosdns' <<<"$(tx_get "$TX1" actions)$(tx_get "$TX1" staged_actions)" \
  && ok "登记了 restart:mosdns" || bad "1i: actions=$(tx_get "$TX1" actions)"
[[ "$(restarts)" -gt "$_r0" ]] && ok "mosdns 真的被重启了" || bad "1j: 没重启"
[[ ! -e "$MC.hjbak" ]] && ok "没有留下旧式 .hjbak 备份" || bad "1k: .hjbak 还在"

# ══ 2. 重复同一模式: 幂等 ══════════════════════════════════════════════════
echo; echo "── 2. 重复 gfw 幂等 ──"
_f=$(fp); _n0=$(ntx); _r0=$(restarts)
out=$(pdg hijack-mode gfw 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "重复执行返回 0" || bad "2: rc=$rc: $(tail -2 <<<"$out")"
[[ "$(fp)" == "$_f" ]] && ok "两个文件内容/mode/owner 逐字节不变" || bad "2b: 文件变了"
[[ "$(restarts)" == "$_r0" ]] && ok "没有多余的 mosdns 重启" || bad "2c: 重启了 $((`restarts`-_r0)) 次"
[[ "$(has_preparing)" == 0 ]] && ok "没有留下 PREPARING 事务" || bad "2d: 有 PREPARING 残留"
[[ ! -e "$MC.hjbak" ]] && ok "幂等路径也没有 .hjbak" || bad "2e: .hjbak 出现了"

# ══ 3. gfw → all ═══════════════════════════════════════════════════════════
echo; echo "── 3. gfw → all ──"
tx_mark; out=$(pdg hijack-mode all 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "切回 all 返回 0" || bad "3: rc=$rc: $(tail -3 <<<"$out")"
[[ "$(cur_mode)" == all ]] && ok "profile.env 记为 all" || bad "3b: $(cur_mode)"
_TXN3="$(tx_created "3")" || _TXN3=""
tx_is_ours "$_TXN3" "3" || true
[[ "$(tx_state "$_TXN3")" == COMMITTED ]] && ok "切回也是 COMMITTED" || bad "3c"

# ══ 4. 全局锁被占用 ════════════════════════════════════════════════════════
echo; echo "── 4. 全局锁被占用 ──"
_f=$(fp)
exec 8>"$LOCK"; flock -n 8 || bad "4-前提: 拿不到锁"
out=$(pdg hijack-mode gfw 2>&1); rc=$?
exec 8>&-
[[ "$rc" != 0 ]] && ok "锁被占用 → 返回非 0(rc=$rc)" || bad "4: 竟然成功了"
[[ "$(fp)" == "$_f" ]] && ok "两个生产文件内容/mode/owner 一个字节没动" || bad "4b: 文件被改了"
grep -qiE '锁|占用|正在执行|忙' <<<"$out" && ok "说明了是锁的原因" || bad "4c: $(tail -2 <<<"$out")"

# ══ 5. 锁文件不可用 ════════════════════════════════════════════════════════
echo; echo "── 5. 锁文件不可用 ──"
# 沙箱里我们是(命名空间的)root, 只读目录挡不住 root —— 用 chmod 500 造"打不开"会假通过。
# 改成父路径是一个**普通文件**: makedirs/open 必然 ENOTDIR, 对 root 同样成立。
_f=$(fp); : > /run/notadir
out=$(PDG_LOCKFILE=/run/notadir/pdg.lock pdg hijack-mode gfw 2>&1); rc=$?
rm -f /run/notadir
[[ "$rc" != 0 ]] && ok "锁文件打不开 → 返回非 0(rc=$rc)" || bad "5: 竟然成功了"
[[ "$(fp)" == "$_f" ]] && ok "现网零改动" || bad "5b: 文件被改了"

# ══ 6. 自定义 mosdns 形态 → 拒绝, 不猜着改 ═════════════════════════════════
echo; echo "── 6. 自定义 mosdns 形态 ──"
cp "$MC" $E2E_TMP/hm-good.yaml
# 造一个归一化器**认不出**的形态: 删掉 hijack_set 插件, 再把它用来定位的 force_hijack 改名。
# 于是 gfw 既装不了插件也找不到锚点 → 判为自定义形态。比随手加一行注释可靠 —— 加注释
# 归一化器照样能改, 那样测的就不是"拒绝", 而是"它没注意到"。
sed -i '/^  - tag: hijack_set$/,+2d' "$MC"
sed -i 's/^  - tag: force_hijack$/  - tag: force_hijack_CUSTOM/' "$MC"
_f=$(fp); _n0=$(ntx)
out=$(pdg hijack-mode gfw 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "自定义形态 → 返回非 0" || bad "6: rc=$rc"
[[ "$(fp)" == "$_f" ]] && ok "两个文件都没动(不猜着改)" || bad "6b: 文件被改了"
[[ "$(ntx)" == "$_n0" ]] && ok "没有留下事务残留" || bad "6c: 多了 $(( $(ntx)-_n0 )) 笔"
cp $E2E_TMP/hm-good.yaml "$MC"

# ══ 7. mosdns 候选校验失败 → 拒绝, 现网不动 ════════════════════════════════
echo; echo "── 7. 候选校验失败 ──"
reset_all
_f=$(fp); _n0=$(ntx)
# 让事务的 mosdns 候选校验器判失败(桩 mosdns 返回非 0), 而不是伪造一个坏候选 ——
# 验的是"校验失败时现网不动", 判据本身没被绕过。
# 桩要放进 PATH 前置的新目录: /usr/local/bin/mosdns 若已被宿主机真 root 装过, 在
# 用户命名空间里属 nobody, 覆盖不了。_mosdns_bin() 先 which 再回落固定路径, 所以 PATH 有效。
mkdir -p $E2E_TMP/hm-bin
cat > $E2E_TMP/hm-bin/mosdns <<'STUB'
#!/bin/sh
echo "stub mosdns: refuse" >&2
exit 1
STUB
chmod 755 $E2E_TMP/hm-bin/mosdns
tx_mark; out=$(PATH="$E2E_TMP/hm-bin:$PATH" pdg hijack-mode gfw 2>&1); rc=$?
rm -rf $E2E_TMP/hm-bin
if [[ "$rc" != 0 ]]; then ok "候选校验失败 → 返回非 0"; else bad "7: rc=0, 校验没拦住"; fi
[[ "$(fp)" == "$_f" ]] && ok "现网两个文件逐字节未变" || bad "7b: 现网被改了"
_TXN7="$(tx_created "7")" || _TXN7=""
tx_is_ours "$_TXN7" "7" || true
_st=$(tx_state "$_TXN7")
[[ "$_st" == ABORTED || "$_st" == COMMITTED || "$(ntx)" == "$_n0" ]] \
  && ok "没有停在中间态(最新事务: ${_st:-无新事务})" || bad "7c: 停在 $_st"

# ══ 8. expect_sha256 并发漂移 ══════════════════════════════════════════════
echo; echo "── 8. 前置 SHA 漂移 ──"
reset_all
# 在 read 与 stage 之间插一个"别人改了同一个文件": 用 PATH 上的 python3 包装, 第一次看到
# `stage` 子命令时先动一下现网, 再 exec 真 python3。这样漂移的时机是确定的, 不靠抢跑。
_realpy="$(command -v python3)"
mkdir -p $E2E_TMP/hm-stub
cat > $E2E_TMP/hm-stub/python3 <<STUB
#!/bin/bash
if [[ "\$*" == *" stage "* && ! -e $E2E_TMP/hm-drift-done ]]; then
  : > $E2E_TMP/hm-drift-done
  printf '\n# concurrent writer landed here\n' >> "$MC"
fi
exec "$_realpy" "\$@"
STUB
chmod 755 $E2E_TMP/hm-stub/python3
rm -f $E2E_TMP/hm-drift-done
_before_drift=$(sha256sum "$PE" | cut -d' ' -f1)
out=$(PATH="$E2E_TMP/hm-stub:$PATH" pdg hijack-mode gfw 2>&1); rc=$?
rm -rf $E2E_TMP/hm-stub $E2E_TMP/hm-drift-done
[[ "$rc" != 0 ]] && ok "前置 SHA 漂移 → 返回非 0(rc=$rc)" || bad "8: 竟然覆盖了别人的修改"
grep -q 'concurrent writer landed here' "$MC" \
  && ok "并发写入者的内容还在(没被我们的候选盖掉)" || bad "8b: 别人的修改被覆盖了"
[[ "$(sha256sum "$PE" | cut -d' ' -f1)" == "$_before_drift" ]] \
  && ok "profile.env 也没被单独写进去(没有半状态)" || bad "8c: profile.env 被改了"
cp $E2E_TMP/hm-good.yaml "$MC"

# ══ 10/11. 重启后不稳定 → 回滚; 回滚里也失败 → ROLLBACK_FAILED ════════════
# 同一个注入验两个性质: 10 看文件有没有按 before-image 复原, 11 看状态说得实不实。
# 只设 .fail 而**不动** .ac 是关键: e2e_svc_crash 会顺手把服务立刻置成 inactive, 那样事务
# 在"操作前硬门"就被拒(那本身没错), 观察期与回滚这两段根本走不到, 这两条就成了空转。
echo; echo "── 10. mosdns 重启后不稳定 ──"
reset_all
_f=$(fp)
mkdir -p $E2E_TMP/e2e-svc; : > $E2E_TMP/e2e-svc/mosdns.fail
tx_mark; out=$(pdg hijack-mode gfw 2>&1); rc=$?
_TXN10="$(tx_created "10")" || _TXN10=""
tx_is_ours "$_TXN10" "10" || true
_TXB="$_TXN10"; _st=$(tx_state "$_TXB")
e2e_svc_heal mosdns
[[ "$rc" != 0 ]] && ok "服务重启后不稳定 → 返回非 0" || bad "10: 谎报成功"
if [[ "$(fp)" == "$_f" ]]; then
  ok "两个文件按 before-image 复原"
elif [[ "$_st" == ROLLBACK_FAILED ]]; then
  ok "文件未全复原, 但状态如实为 ROLLBACK_FAILED"
else
  bad "10b: 半状态且状态为 $_st"
fi

echo; echo "── 11. 回滚不完整必须如实说 ──"
if [[ "$_st" == ROLLBACK_FAILED ]]; then
  ok "回滚有一项没回去 → 状态 ROLLBACK_FAILED(不是 ROLLED_BACK)"
  [[ "$(tx_get "$_TXB" rollback_complete)" == False ]] \
    && ok "rollback_complete=False" || bad "11b: $(tx_get "$_TXB" rollback_complete)"
  grep -qi 'mosdns' <<<"$(tx_get "$_TXB" rollback_failed_items)$out" \
    && ok "点名了没恢复的那一项(mosdns)" || bad "11c: 没点名: $(tx_get "$_TXB" rollback_failed_items)"
elif [[ "$_st" == ROLLED_BACK ]]; then
  ok "回滚完整 → 状态 ROLLED_BACK(与文件已复原一致, 两者不矛盾)"
  [[ "$(tx_get "$_TXB" rollback_complete)" == True ]] \
    && ok "rollback_complete=True 且文件确实回去了" || bad "11b: 说完整但字段是 $(tx_get "$_TXB" rollback_complete)"
else
  bad "11: 状态 $_st —— 既不是 ROLLED_BACK 也不是 ROLLBACK_FAILED"
fi
[[ "$(cur_mode)" == all ]] && ok "profile.env 仍是操作前的 all" || bad "11d: $(cur_mode)"

# ══ 12. gfw 缺 geosite_gfw.txt: 语义保留, 失败则两者都不变 ═════════════════
echo; echo "── 12. gfw 缺劫持集文件 ──"
reset_all
cp /etc/mosdns/rules/geosite_gfw.txt $E2E_TMP/hm-gfw.bak
: > /etc/mosdns/rules/geosite_gfw.txt
cat > /opt/pdg-bot/update-rules.sh <<'STUB'
#!/bin/sh
exit 1
STUB
chmod 755 /opt/pdg-bot/update-rules.sh
_f=$(fp)
out=$(pdg hijack-mode gfw 2>&1); rc=$?
cp $E2E_TMP/hm-gfw.bak /etc/mosdns/rules/geosite_gfw.txt
[[ "$rc" != 0 ]] && ok "劫持集生成失败 → 返回非 0" || bad "12: rc=0"
[[ "$(fp)" == "$_f" ]] && ok "劫持模式与 profile 均未改变" || bad "12b: 文件被改了"

# ══ 13. 凭据哨兵全程不外泄 ═════════════════════════════════════════════════
echo; echo "── 13. 凭据哨兵 ──"
grep -q "$SENTINEL" "$PE" && ok "前提: 哨兵确实在 profile.env 里" || bad "13-前提: 哨兵不见了"
# candidate/ 与 before/ 里**必须**是文件真实字节 —— 否则回滚无从恢复。脱敏契约管的是
# 元数据/差异/审计, 不是这两处; 它们靠 0700 目录 + 0600 文件保护。所以分开验:
#   · meta.json / diff.txt / 审计索引: 一个哨兵都不许有;
#   · candidate/ before/: 允许有正文, 但权限必须是收紧的。
_leak=""; _perm=""
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  for f in meta.json diff.txt; do
    [[ -e "$d/$f" ]] && grep -qF "$SENTINEL" "$d/$f" 2>/dev/null && _leak="$_leak $(basename "$d")/$f"
  done
  for sub in candidate before; do
    [[ -d "$d/$sub" ]] || continue
    [[ "$(stat -c '%a' "$d/$sub")" == 700 ]] || _perm="$_perm $(basename "$d")/$sub=$(stat -c '%a' "$d/$sub")"
  done
done < <(find "$TXR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
[[ -z "$_leak" ]] && ok "事务 meta.json / diff.txt 里没有哨兵(脱敏生效)" || bad "13b: 泄漏于$_leak"
[[ -z "$_perm" ]] && ok "candidate/ 与 before/ 均为 0700(正文有, 但外人读不到)" || bad "13b2: 权限松$_perm"
if [[ -f "$TXR/index.jsonl" ]]; then
  grep -qF "$SENTINEL" "$TXR/index.jsonl" && bad "13c: 审计索引里出现了哨兵" \
    || ok "审计索引 index.jsonl 无哨兵"
fi
# 最后一次完整成功路径的 stdout/stderr
out=$(pdg hijack-mode all 2>&1)
grep -qF "$SENTINEL" <<<"$out" && bad "13d: 命令输出里出现了哨兵" || ok "命令 stdout/stderr 无哨兵"

# ══ 14. 第一个目标已落盘后失败 → 不许留半状态(放在最后跑) ═════════════════
# 为什么排在最后: 这条要用只读绑定挂载才能对 root 也成立, 而 overlay + 用户命名空间下
# 那个挂载**卸不干净**(umount -l 也不行), 残留会把后面的用例一起带偏 —— 实测会让场景
# 10/11 的 rollback_failed_items 变成 profile_env(OSError), 看着像产品在别处出错。
# 每条用例证明什么与执行顺序无关, 所以把它放到最后, 比跟卸载收尾较劲可靠。
echo; echo "── 14. 第一目标落盘后失败(最后跑) ──"
reset_all
# 目标按名字排序落盘: mosdns_conf 先于 profile_env。要让第二个写不下去且**对 root 也成立**,
# 只能用只读绑定挂载 —— chmod 500 挡不住命名空间里的 root, 那样这条会假通过。
# 注入时机卡在 `apply` 之前(用 PATH 上的 python3 包装): 此前的 read/校验仍要能正常读到它。
if mount --bind /etc/privdns-gateway /etc/privdns-gateway 2>/dev/null; then
  umount /etc/privdns-gateway 2>/dev/null
  _realpy="$(command -v python3)"; mkdir -p $E2E_TMP/hm-stub2; rm -f $E2E_TMP/hm-ro-done
  {
    echo '#!/bin/bash'
    echo "if [[ \"\$*\" == *\" apply \"* && ! -e $E2E_TMP/hm-ro-done ]]; then"
    echo "  : > $E2E_TMP/hm-ro-done"
    echo '  mount --bind /etc/privdns-gateway /etc/privdns-gateway 2>/dev/null'
    echo '  mount -o remount,ro,bind /etc/privdns-gateway 2>/dev/null'
    echo 'fi'
    echo "exec $_realpy \"\$@\""
  } > $E2E_TMP/hm-stub2/python3
  chmod 755 $E2E_TMP/hm-stub2/python3
  _f=$(fp)
tx_mark;   out=$(PATH="$E2E_TMP/hm-stub2:$PATH" pdg hijack-mode gfw 2>&1); rc=$?
  # bind + remount,ro 会叠成两层, 单次 umount 清不掉 —— 残留的只读挂载会把**后面**的用例
  # 一起带偏(实测: 场景 10/11 的 rollback_failed_items 变成 profile_env(OSError), 看起来
  # 像产品在别处出错, 其实是这里没卸干净)。卸到不再是挂载点为止, 并复验可写。
  _u=0; while mountpoint -q /etc/privdns-gateway 2>/dev/null && [[ "$_u" -lt 8 ]]; do
    umount /etc/privdns-gateway 2>/dev/null || umount -l /etc/privdns-gateway 2>/dev/null || break
    _u=$((_u+1))
  done
  rm -rf $E2E_TMP/hm-stub2 $E2E_TMP/hm-ro-done
  if ( : > /etc/privdns-gateway/.wtest ) 2>/dev/null; then
    rm -f /etc/privdns-gateway/.wtest
  else
    bad "14-收尾: /etc/privdns-gateway 仍不可写, 后续用例会被污染"
  fi
  [[ "$rc" != 0 ]] && ok "第二个目标写不下去 → 返回非 0(不谎报成功)" || bad "14: rc=0: $(tail -2 <<<"$out")"
_TXN14="$(tx_created "14")" || _TXN14=""
tx_is_ours "$_TXN14" "14" || true
  _st=$(tx_state "$_TXN14")
  # 判据落在**不许留半状态**上: 要么两个文件都回到操作前, 要么如实报 ROLLBACK_FAILED。
  # 没有第三种可接受的结果 —— "文件是半的、状态却说完整"正是这条要挡的。
  if [[ "$(fp)" == "$_f" ]]; then
    ok "两个文件都回到操作前(内容/mode/owner), 状态 $_st"
  elif [[ "$_st" == ROLLBACK_FAILED ]]; then
    ok "没能完全回滚, 但如实记为 ROLLBACK_FAILED(未谎称已恢复)"
  else
    bad "14b: 留下半状态而状态却是 $_st"
  fi
else
  note_skip "本环境不允许 bind mount(需 CAP_SYS_ADMIN), 「第一目标落盘后失败」未注入"
fi

rm -f $E2E_TMP/hm-good.yaml $E2E_TMP/hm-gfw.bak
e2e_summary

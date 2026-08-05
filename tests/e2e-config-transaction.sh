#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 统一配置事务在**真实装机现场**上的行为(真 root 沙箱, 真文件, 真服务桩)。
#   1. CLI / Bot / 定时任务三方并发: 只有一个拿到写锁, 其余立即 BUSY;
#   2. 锁不可用 → 三侧都 fail-closed(现网零改动);
#   3. mosdns 强校验的三条路径: netns / 高端口 / 两者都不可用时**拒绝应用**;
#   4. 一笔跨组件事务(model + mosdns 规则)提交后, 两边都真的落盘且服务真的重启;
#   5. 观察期失败(服务起来即崩)→ 现网逐字节回到操作前, 基础 DNS 仍可用。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
# 事务目录与本用例的临时产物不在 e2e 沙箱的 overlay 里(它们在 /var/lib 与 /tmp), 上一次
# 跑剩的"未完成事务"会正确地挡住这一次 —— 那是产品行为, 但会让用例测不到自己想测的东西。
rm -rf /var/lib/privdns-gateway/tx $E2E_TMP/tx-crash.out $E2E_TMP/tx-crash2.out $E2E_TMP/tx-race.out $E2E_TMP/tx-winner.txt
printf 'mihomo\n' > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform

TX=/opt/privdns-gateway/deploy/bot/pdgtx.py
[[ -f "$TX" ]] || TX="$E2E_ROOT/deploy/bot/pdgtx.py"
export PDG_STABLE_SAMPLES=1

# 硬门探针由 e2e_stub_system 统一起(见 e2e-lib.sh 的 e2e_tx_probes)

# ══ 1. 三方并发: 只有一个拿到写锁 ═══════════════════════════════════════════
echo "── 1. CLI / Bot / scheduler 并发抢锁 ──"
rm -f $E2E_TMP/tx-winner.txt
RACE_PIDS=()
for who in cli bot scheduler; do
  ( python3 - "$TX" "$who" <<'PY' >>$E2E_TMP/tx-race.out 2>&1
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    with m._Lock():
        open(os.environ["E2E_TMP"] + "/tx-winner.txt", "a").write(sys.argv[2] + "\n")
        time.sleep(1.5)
    print("WON " + sys.argv[2])
except m.TxBusy:
    print("BUSY " + sys.argv[2])
PY
  ) &
  RACE_PIDS+=("$!")
  sleep 0.1
done
wait "${RACE_PIDS[@]}"      # 只等这三个 —— 裸 wait 会连上面那个常驻探针一起等(永远不回来)
won=$(grep -c '^WON' $E2E_TMP/tx-race.out); busy=$(grep -c '^BUSY' $E2E_TMP/tx-race.out)
lines=$(wc -l < $E2E_TMP/tx-winner.txt)
{ [[ "$won" == 1 && "$busy" == 2 && "$lines" == 1 ]]; } \
  && ok "三方并发: 1 个取得写锁, 2 个立即 BUSY(临界区只进去了一个)" \
  || bad "并发结果不对: won=$won busy=$busy 写入者=$lines"
rm -f $E2E_TMP/tx-race.out

# ══ 2. 锁不可用 → fail-closed ══════════════════════════════════════════════
echo; echo "── 2. 锁不可用(fail-closed) ──"
# root 会无视目录权限位, 所以不能用"只读目录"造不可用; 用**父路径是个普通文件**(ENOTDIR),
# 这对 root 一样打不开 —— 与现实里 /run 挂坏、被文件占位的形态一致。
printf 'x' > $E2E_TMP/lockblocker
BADLOCK=$E2E_TMP/lockblocker/sub/pdg.lock
BEFORE_SHA="$(sha256sum /etc/mosdns/rules/custom_direct.txt 2>/dev/null | cut -d' ' -f1)"
out=$(PDG_LOCKFILE="$BADLOCK" python3 - "$TX" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = m.Tx("test", "nolock")
t.stage("mosdns_rule:custom_direct.txt", b"domain:evil.com\n")
try:
    t.commit(); print("COMMITTED")
except m.TxRefused as e:
    print("REFUSED:", e)
PY
)
AFTER_SHA="$(sha256sum /etc/mosdns/rules/custom_direct.txt 2>/dev/null | cut -d' ' -f1)"
{ grep -q '^REFUSED' <<<"$out" && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; } \
  && ok "核心: 锁文件不可用 → 拒绝执行且现网逐字节没变" || bad "fail-closed 失效: $out"
out=$(PDG_LOCKFILE="$BADLOCK" pdg snapshot 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '锁文件不可用' <<<"$out"; } \
  && ok "CLI: 锁文件不可用 → 非 0 退出并说明原因" || bad "CLI 未 fail-closed: rc=$rc $out"

# ══ 3. mosdns 强校验的三条路径 ═════════════════════════════════════════════
echo; echo "── 3. mosdns 候选强校验(netns / 高端口 / 都不可用) ──"
BAD_CONF=$E2E_TMP/bad-mosdns.yaml
printf 'log:\n  level: info\nplugins:\n  - tag: x\n    type: no_such_plugin_type\n' > "$BAD_CONF"
GOOD_CONF=$E2E_TMP/good-mosdns.yaml
# 好配置必须**带监听项**: 高端口探针要把监听地址改写到随机端口才能在不碰生产端口的前提下起来。
# 用 plugins: [] 这种无监听夹具, 高端口那条路径永远走不通(改写 0 处 → 拒绝), 等于给自己
# 造了一个在无 netns 环境里必红的假用例。
cat > "$GOOD_CONF" <<'YAML'
log:
  level: info
plugins:
  - tag: fwd
    type: forward
    args:
      concurrent: 1
      upstreams:
        - addr: "udp://127.0.0.1:65353"
  - tag: entry
    type: sequence
    args:
      - exec: $fwd
  - tag: srv
    type: udp_server
    args:
      entry: entry
      listen: "127.0.0.1:53"
YAML
probe(){ # $1=mode $2=conf → 打印 ok/fail
  # 注意: 这里必须用 `.*` 而不是 `[^\n]*`——grep 的方括号表达式里 \n 不是换行转义, 而是
  # "反斜杠或字母 n"。用后者会把 "PROBE|fail|netns 不可用…" 在第一个 n 前截断成 "PROBE|fail|",
  # 于是"错误原因"这一半断言永远看不到内容(本地 netns 可用时走不到这条分支, 只有 CI 会红)。
  python3 - "$TX" "$2" 2>&1 <<'PY' | grep -o 'PROBE|.*' | tail -1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
data = open(sys.argv[2], "rb").read()
okr, err = m.VALIDATORS["mosdns_probe"]("/etc/mosdns/config.yaml", data, None)
print("PROBE|" + ("ok" if okr else "fail") + "|" + (err or "")[:100].replace("\n", " "))
PY
}
# CI 的容器里没有 mosdns —— 强校验这三条路径必须真跑, 所以按钉死版本取一份真二进制,
# 取不到就如实判失败(不 SKIP 冒充通过)。
e2e_fetch_mosdns || true
if command -v mosdns >/dev/null 2>&1; then
  # netns 要 CAP_SYS_ADMIN: CI 的非特权容器里用不了。用不了不是"跳过", 而是**换一条断言**——
  # 强制 netns 模式必须如实报"不可用"(不能悄悄降级放行), 且 auto 模式要能退到高端口探针。
  # 判据要和产品实际用的命令一致: pdgtx 跑的是 `unshare -n -r`(先建用户命名空间再拿
  # CAP_SYS_ADMIN)。只试 `unshare -n` 会在"没 CAP_SYS_ADMIN 但允许非特权 userns"的机器上
  # 选错分支 —— 产品明明能建 netns, 用例却去断言"netns 不可用"。
  if unshare -n -r true 2>/dev/null; then
    r="$(PDG_TX_MOSDNS_PROBE_MODE=netns probe netns "$BAD_CONF")"
    grep -q '^PROBE|fail' <<<"$r" && ok "netns 探针: 坏配置被判失败($(cut -d'|' -f3 <<<"$r" | head -c 40))" \
      || bad "netns 探针没判出坏配置: $r"
    r="$(PDG_TX_MOSDNS_PROBE_MODE=netns probe netns "$GOOD_CONF")"
    grep -q '^PROBE|ok' <<<"$r" && ok "netns 探针: 好配置判通过(不误杀)" || bad "netns 误判好配置: $r"
  else
    r="$(PDG_TX_MOSDNS_PROBE_MODE=netns probe netns "$GOOD_CONF")"
    { grep -q '^PROBE|fail' <<<"$r" && grep -q 'netns 不可用' <<<"$r"; } \
      && ok "本环境没有 netns 能力: 强制 netns 模式如实报 netns 不可用(不冒充候选有错)" \
      || bad "netns 不可用时的行为不对: $r"
    r="$(PDG_TX_MOSDNS_PROBE_MODE=auto probe auto "$GOOD_CONF")"
    grep -q '^PROBE|ok' <<<"$r" && ok "auto 模式退到高端口探针并判好配置通过" \
      || bad "auto 没能退到高端口探针: $r"
    r="$(PDG_TX_MOSDNS_PROBE_MODE=auto probe auto "$BAD_CONF")"
    grep -q '^PROBE|fail' <<<"$r" && ok "auto 降级后仍判出坏配置(降级不等于放宽)" \
      || bad "降级后放行了坏配置: $r"
  fi
  r="$(PDG_TX_MOSDNS_PROBE_MODE=port probe port "$BAD_CONF")"
  grep -q '^PROBE|fail' <<<"$r" && ok "高端口探针: 坏配置被判失败" || bad "高端口探针没判出坏配置: $r"
  # 两条都不可用: 直接把 mosdns 二进制藏起来(裁剪 PATH 会把 tail 之类也弄丢, 反而测不出东西)
  # 让探针**真的找不到 mosdns**: PATH 里放一个空目录在最前, 且把 FSROOT 指到没有
  # /usr/local/bin/mosdns 的空树(核心是 shutil.which + FSROOT 两条兜底, 两条都断才算没有)。
  EMPTYBIN=$E2E_TMP/nomos-bin; rm -rf "$EMPTYBIN"; mkdir -p "$EMPTYBIN"
  for c in python3 bash sh grep sed cut head tail cat env; do
    src="$(command -v "$c" 2>/dev/null)"; [[ -n "$src" ]] && ln -sf "$src" "$EMPTYBIN/$c"
  done
  r="$(PATH="$EMPTYBIN" PDG_TX_FSROOT=$E2E_TMP/nomos-root PDG_TX_MOSDNS_PROBE_MODE=auto \
        probe none "$GOOD_CONF")"
  grep -q '^PROBE|fail' <<<"$r" && ok "两种强校验都不可用 → 拒绝应用 mosdns 配置(不拿结构检查冒充)" \
    || bad "没有 mosdns 时竟然放行了: $r"
else
  bad "沙箱里没有 mosdns 二进制, mosdns 强校验三条路径无法验证(不当作通过)"
fi

# ══ 4. 跨组件事务: model + mosdns 规则一起落盘 ═════════════════════════════
echo; echo "── 4. 跨组件事务 ──"
: > $E2E_TMP/e2e-calls.log
out=$(python3 - "$TX" <<'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
model = json.load(open("/etc/sing-box/config.json"))
model.setdefault("route", {}).setdefault("rules", []).insert(
    0, {"domain_suffix": ["tx.example"], "outbound": model.get("route", {}).get("final", "direct")})
t = m.Tx("cli", "e2e_cross")
t.stage("model", json.dumps(model).encode())
t.stage("mosdns_rule:custom_hijack.txt", b"domain:tx.example\n")
t.service("restart:mosdns")
print(json.dumps(t.commit(), ensure_ascii=False))
PY
)
grep -q '"state": "COMMITTED"' <<<"$out" && ok "跨组件事务提交成功" || bad "提交失败: $(tail -2 <<<"$out")"
grep -q 'tx.example' /etc/sing-box/config.json && ok "model 真的落盘" || bad "model 没落盘"
grep -q 'tx.example' /etc/mosdns/rules/custom_hijack.txt && ok "mosdns 劫持表真的落盘" || bad "劫持表没落盘"
grep -q 'restart mosdns' $E2E_TMP/e2e-calls.log && ok "声明的服务动作真的执行(mosdns 被重启)" || bad "服务没重启"

# ══ 5. 观察期失败 → 逐字节回滚, 基础链路仍可用 ════════════════════════════
echo; echo "── 5. 观察期失败回滚 ──"
MODEL_SHA="$(sha256sum /etc/sing-box/config.json | cut -d' ' -f1)"
HIJ_SHA="$(sha256sum /etc/mosdns/rules/custom_hijack.txt | cut -d' ' -f1)"
e2e_svc_crash mosdns
out=$(python3 - "$TX" <<'PY' 2>&1
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = m.Tx("cli", "e2e_rollback", mode="repair")   # 服务已崩: 用修复模式才允许开始
t.stage("mosdns_rule:custom_hijack.txt", b"domain:should-not-stay.example\n")
t.service("restart:mosdns")
print(json.dumps(t.commit(), ensure_ascii=False))
PY
)
e2e_svc_heal mosdns
grep -qE '"state": "(ROLLED_BACK|ROLLBACK_FAILED)"' <<<"$out" \
  && ok "服务起不来 → 事务判失败并回滚" || bad "崩溃没被判失败: $(tail -2 <<<"$out")"
[[ "$(sha256sum /etc/mosdns/rules/custom_hijack.txt | cut -d' ' -f1)" == "$HIJ_SHA" ]] \
  && ok "劫持表逐字节回到操作前" || bad "回滚后内容不一致"
[[ "$(sha256sum /etc/sing-box/config.json | cut -d' ' -f1)" == "$MODEL_SHA" ]] \
  && ok "未参与本次事务的 model 完全没被碰" || bad "model 被动了"

e2e_summary

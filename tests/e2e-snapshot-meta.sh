#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 快照必须能回答"这是谁拍的"。
#
# 以前一份快照只有时间戳目录名和 snap.tar.gz。手动拍的、更新前自动拍的、平台切换前拍的、
# 迁移前拍的、救援完整恢复前拍的 —— 全都长一个样。出事时想回到"那次操作之前", 却分不出
# 是哪一次; 路线图 5.5 硬门③ 的"并能查看变更来源"就卡在这里。
#
# 这里验的都是**真跑 pdg** 的结果, 不读源码字符串。
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
e2e_seed_nft mihomo
printf 'android\n' > /etc/privdns-gateway/platform
printf 'mihomo\n'  > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway

SNAP=/var/lib/privdns-gateway/backups
SENTINEL='987654321:AAHsnapSENTINELtoken00000000000000000'
printf 'PDG_SENTINEL_TOKEN=%s\n' "$SENTINEL" >> /etc/privdns-gateway/profile.env

nsnap(){ find "$SNAP" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l; }
# newest() 只用在"随便拿一份现成快照来当夹具"的地方。**判定本次操作产生了哪一份**一律走
# e2e-lib.sh 的差集助手 —— 按名字排序去猜"最新的那份", 在同秒撞名时挑中谁纯看运气。
newest(){ find "$SNAP" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1; }
meta_get(){ python3 -c "import json,sys;print(json.load(open(sys.argv[1]+'/snapshot.json')).get(sys.argv[2],''))" "$1" "$2" 2>/dev/null; }

rm -rf "$SNAP"; mkdir -p "$SNAP"

# ══ 1. 手动快照: 字段齐全, 权限 0600 ═══════════════════════════════════════
echo "── 1. 手动快照的元数据 ──"
e2e_dirset_mark "$SNAP"
out=$(pdg snapshot 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "pdg snapshot 成功" || bad "1: rc=$rc: $(tail -2 <<<"$out")"
D="$(e2e_dirset_created 1)"
[[ -f "$D/snapshot.json" ]] && ok "生成了 snapshot.json" || bad "1b: 没有元数据文件"
[[ "$(stat -c '%a' "$D/snapshot.json" 2>/dev/null)" == 600 ]] \
  && ok "元数据 mode 0600" || bad "1c: mode=$(stat -c '%a' "$D/snapshot.json" 2>/dev/null)"
_miss=""
for f in schema_version snapshot_id created_at source op git_commit git_describe; do
  [[ -n "$(meta_get "$D" "$f")" ]] || _miss="$_miss $f"
done
[[ -z "$_miss" ]] && ok "七个字段齐全" || bad "1d: 缺字段$_miss"
[[ "$(meta_get "$D" snapshot_id)" == "$(basename "$D")" ]] \
  && ok "snapshot_id 与目录名一致" || bad "1e: $(meta_get "$D" snapshot_id)"
[[ "$(meta_get "$D" created_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "created_at 是 UTC ISO8601" || bad "1f: $(meta_get "$D" created_at)"
[[ "$(meta_get "$D" source)" == cli && "$(meta_get "$D" op)" == snapshot ]] \
  && ok "手动快照 source=cli op=snapshot" || bad "1g: $(meta_get "$D" source)/$(meta_get "$D" op)"
# 元数据里不许出现任何凭据/正文/参数
grep -qF "$SENTINEL" "$D/snapshot.json" && bad "1h: 元数据里出现了凭据哨兵" || ok "元数据无凭据哨兵"
grep -qE '"(source|op)": *"[^"]*[;&|$`]' "$D/snapshot.json" \
  && bad "1i: 枚举值里混进了 shell 元字符" || ok "枚举值干净"

# ══ 2. 五种来源都准确 ══════════════════════════════════════════════════════
echo; echo "── 2. 五种调用来源 ──"
check_src(){ # $1=期望 source $2=期望 op $3..=命令
  local esrc="$1" eop="$2"; shift 2
  e2e_dirset_mark "$SNAP"
  "$@" >/dev/null 2>&1
  local d; d="$(e2e_dirset_created "2-$eop")" || return
  if [[ "$(meta_get "$d" source)" == "$esrc" && "$(meta_get "$d" op)" == "$eop" ]]; then
    ok "$eop 前的快照标为 $esrc/$eop"
  else
    bad "2-$eop: 实得 $(meta_get "$d" source)/$(meta_get "$d" op)"
  fi
}
# 五种枚举都过**真实 CLI 面**(pdg snapshot --source/--op), 不是内部函数调用。
# 目录名是秒级的, 每次之间必须隔开一秒, 否则第二次撞名(现在会被拒, 以前会覆盖前一份)。
check_src cli    snapshot          pdg snapshot;                                        sleep 1.05
check_src cli    update            pdg snapshot --source cli --op update;               sleep 1.05
check_src cli    platform          pdg snapshot --source cli --op platform;             sleep 1.05
check_src cli    migrate           pdg snapshot --source cli --op migrate;              sleep 1.05
check_src rescue pre-full-restore  pdg snapshot --source rescue --op pre-full-restore;  sleep 1.05
# 再用一条**真实调用路径**证明接线没错(不是只有 CLI 参数能传): pdg migrate 会先拍快照。
e2e_dirset_mark "$SNAP"
pdg migrate >/dev/null 2>&1
_d="$(e2e_dirset_created 2-wire)" || _d=""
if [[ -n "$_d" ]]; then
  [[ "$(meta_get "$_d" source)" == cli && "$(meta_get "$_d" op)" == migrate ]] \
    && ok "真跑 pdg migrate: 它拍的快照确实标成 cli/migrate(接线成立)" \
    || bad "2-wire: 实得 $(meta_get "$_d" source)/$(meta_get "$_d" op)"
else
  echo "[SKIP] pdg migrate 在本沙箱没拍出新快照, 接线未由真实路径覆盖"
fi
sleep 1.05
# 未知枚举必须被拒(而不是原样写进去)
_n=$(nsnap)
out=$(pdg snapshot --source evil --op "x; rm -rf /" 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && [[ "$(nsnap)" == "$_n" ]]; } \
  && ok "未知来源/操作 → 拒绝且不留半份快照" || bad "2z: rc=$rc 快照数 $_n→$(nsnap)"

# ══ 3. 保留最近 10 份 ══════════════════════════════════════════════════════
echo; echo "── 3. 12 份 → 只留最新 10 份 ──"
rm -rf "$SNAP"; mkdir -p "$SNAP"
_made=0
for _i in $(seq 1 12); do pdg snapshot >/dev/null 2>&1 && _made=$((_made+1)); sleep 1.05; done
[[ "$_made" == 12 ]] && ok "12 份全部生成" || bad "3: 只成了 $_made 份"
[[ "$(nsnap)" == 10 ]] && ok "正好保留 10 份" || bad "3b: 剩 $(nsnap) 份"
_bad=0
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  [[ -f "$d/snapshot.json" && -s "$d/snap.tar.gz" ]] || _bad=$((_bad+1))
done < <(find "$SNAP" -maxdepth 1 -mindepth 1 -type d)
[[ "$_bad" == 0 ]] && ok "留下的 10 份都既有归档也有元数据" || bad "3c: $_bad 份不完整"

# ══ 4. 元数据写失败 → 不留可用快照 ═════════════════════════════════════════
echo; echo "── 4. 元数据写不成时整份作废 ──"
_n=$(nsnap)
# 让 mktemp 在快照目录里失败: 把 SNAP 换成一个只读绑定挂载(对 root 也成立)。
# 归档能不能写下去不重要 —— 要验的是"绝不留下有归档没元数据的新快照"。
if mount --bind "$SNAP" "$SNAP" 2>/dev/null && mount -o remount,ro,bind "$SNAP" 2>/dev/null; then
  out=$(pdg snapshot 2>&1); rc=$?
  while mountpoint -q "$SNAP" 2>/dev/null; do umount "$SNAP" 2>/dev/null || umount -l "$SNAP" 2>/dev/null || break; done
  [[ "$rc" != 0 ]] && ok "写不下去 → 返回非 0" || bad "4: rc=0"
  _orphan=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    [[ -s "$d/snap.tar.gz" && ! -f "$d/snapshot.json" ]] && _orphan=$((_orphan+1))
  done < <(find "$SNAP" -maxdepth 1 -mindepth 1 -type d)
  [[ "$_orphan" == 0 ]] && ok "没有留下「有归档、没元数据」的新快照" || bad "4b: $_orphan 份孤儿"
else
  echo "[SKIP] 本环境不允许 bind mount(需 CAP_SYS_ADMIN), 元数据写失败一条未注入"
fi

# ══ 5. 旧快照(无元数据)仍可查看、可回滚 ════════════════════════════════════
echo; echo "── 5. 跨版本兼容: 老快照 ──"
OLD="$SNAP/20200101-000000"
mkdir -p "$OLD"
cp "$(newest)/snap.tar.gz" "$OLD/snap.tar.gz" 2>/dev/null || tar czf "$OLD/snap.tar.gz" -C / etc/privdns-gateway 2>/dev/null
chmod 600 "$OLD/snap.tar.gz"
[[ ! -f "$OLD/snapshot.json" ]] && ok "构造出一份没有元数据的老快照" || bad "5-前提"
out=$(printf 'n\n' | pdg rollback 2>&1)
grep -q '20200101-000000' <<<"$out" && ok "列表里能看到老快照" || bad "5b: 列表没列出来"
grep -q '来源未知' <<<"$out" && ok "老快照显示「来源未知(旧快照)」" || bad "5c: $(grep 20200101 <<<"$out")"
grep -qE 'cli/snapshot' <<<"$out" && ok "新快照显示来源/操作" || bad "5d: 新快照没显示来源"
# 真回滚到老快照: 不能因为缺元数据就被拒
out=$(pdg rollback --dir "$OLD" 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "老快照可以真回滚(缺元数据不挡)" || bad "5e: rc=$rc: $(tail -3 <<<"$out")"

# ══ 6. 元数据损坏: 只显示未知, 不扩权、不执行 ══════════════════════════════
echo; echo "── 6. 损坏的元数据 ──"
BADD="$(newest)"
# 载荷里的路径必须与下面的断言是同一个 —— 用 %s 注入(单引号格式串保证 $( ) 原样落盘,
# printf 自己不求值)。两边写成不同路径的话, 断言就永远成立, 等于没验。
printf 'not json at all $(touch %s) `id`\n' "$E2E_TMP/pwned" > "$BADD/snapshot.json"
chmod 644 "$BADD/snapshot.json"
rm -f $E2E_TMP/pwned
out=$(printf 'n\n' | pdg rollback 2>&1)
[[ ! -e $E2E_TMP/pwned ]] && ok "坏元数据里的命令没有被执行" || bad "6: 元数据被当成代码跑了"
grep -q '来源未知' <<<"$out" && ok "坏元数据显示为「来源未知」" || bad "6b: $(tail -3 <<<"$out")"
[[ "$(stat -c '%a' "$BADD/snapshot.json")" == 644 ]] \
  && ok "读它不会顺手改权限(没有扩权)" || bad "6c: 权限被改成 $(stat -c '%a' "$BADD/snapshot.json")"
out=$(pdg rollback --dir "$BADD" 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "坏元数据不挡回滚" || bad "6d: rc=$rc"

e2e_summary

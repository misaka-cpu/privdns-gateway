#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: HEAD **领先**最新发布时, `pdg update` 必须拒绝, 且一个字节都不动。
#
# 单测(test-update-release-relation.sh)是把 cmd_update 抽出来打桩跑的 —— 它能证明"没调
# reset、没调 cmd_snapshot", 但证明不了"盘上真的没变"。快照目录、已装文件的 mode/owner、
# 受管配置、服务的 InvocationID 这几样, 只有拿装在机器上的那份脚本对着真仓库跑才看得出来。
#
# 造的现场就是线上那个: 两台生产机跑着 v1.11.4-7-g86aac93c, 即最新 Release 之后又有 7 笔
# 已合并但未发布的提交。以前一次普通的 `pdg update` 会把它们静默退回 v1.11.4。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v git >/dev/null 2>&1 || e2e_skip "无 git"
e2e_stub_system
e2e_seed_install
printf 'android\n' > /etc/privdns-gateway/platform
printf 'mihomo\n'  > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway

REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-ahead-origin.git
rm -rf "$REPO/.git" "$ORIGIN"
git -C "$REPO" init -q -b main
e2e_guard_repo "$REPO" || exit 1
e2e_git "$REPO" config user.email t@t; e2e_git "$REPO" config user.name t
e2e_git "$REPO" config commit.gpgsign false
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm base >/dev/null 2>&1
# **附注** tag: 轻量 tag 的对象哈希就是提交, 少写 `^{commit}` 也能碰巧相等 —— 那样这一支
# 就测不出真正的错误形态了。
e2e_git "$REPO" tag -a v9.9.8 -m v9.9.8 >/dev/null 2>&1
# 已合并但**尚未发布**的两笔 —— 线上那 7 笔的同构最小版
for n in 1 2; do
  echo "# UNRELEASED-$n" >> "$REPO/deploy/bot/checks.py"
  e2e_git "$REPO" add -A >/dev/null 2>&1
  e2e_git "$REPO" commit -qm "unreleased-$n" >/dev/null 2>&1
done
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"

HEAD0="$(git -C "$REPO" rev-parse HEAD)"
{ [[ "$(git -C "$REPO" tag -l 'v*' --sort=-v:refname | head -1)" == v9.9.8 ]] \
  && [[ "$(git -C "$REPO" rev-list --count v9.9.8..HEAD)" == 2 ]]; } \
  && ok "现场就位: 最新发布 v9.9.8, HEAD 领先它 2 笔(未发布提交)" \
  || bad "现场没造对: tag=$(git -C "$REPO" tag -l), 领先 $(git -C "$REPO" rev-list --count v9.9.8..HEAD) 笔"

# ── 前像 ────────────────────────────────────────────────────────────────────
digest_bot(){ find /opt/pdg-bot -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum; }
modes_bot(){ find /opt/pdg-bot -type f -printf '%p %m %u:%g\n' 2>/dev/null | sort | sha256sum; }
snap_count(){ find /var/lib/privdns-gateway/backups -name snap.tar.gz 2>/dev/null | wc -l; }
inv_of(){ systemctl show -p InvocationID --value "$1" 2>/dev/null; }

# 给两个受管服务一个可辨识的 InvocationID, 重启才会变
printf 'INV-MOSDNS-0\n' > "$E2E_TMP/e2e-svc/mosdns.inv"
printf 'INV-BOT-0\n'    > "$E2E_TMP/e2e-svc/pdg-bot.inv"

B_BOT="$(digest_bot)"; B_MODE="$(modes_bot)"; B_SNAP="$(snap_count)"
B_CFG="$(sha256sum /etc/mosdns/config.yaml 2>/dev/null | cut -d' ' -f1)"
B_INV_M="$(inv_of mosdns)"; B_INV_B="$(inv_of pdg-bot)"
# 只数**会改变系统状态**的那些 verb。show / is-active / is-enabled 是只读查询, 而这一支
# 自己就要靠 `systemctl show -p InvocationID` 取前像 —— 把它们也数进去, 判据会被自己的
# 测量动作污染(第一版就是这么红的)。
mut_calls(){ grep -cE '^systemctl (daemon-reload|restart|start|stop|enable|disable|reset-failed)'                "$E2E_TMP/e2e-calls.log" 2>/dev/null || true; }
B_CALLS="$(mut_calls)"; B_CALLS="${B_CALLS:-0}"

# ── 正式 update: 必须拒绝 ───────────────────────────────────────────────────
echo; echo "── 正式 update ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "rc 非 0(实得 $rc)" \
  || bad "领先最新发布却 rc=0 —— 静默降级: $(tail -3 <<<"$out")"
grep -qE '未发布|领先' <<<"$out" && ok "说清了当前跑的是未发布提交" \
  || bad "没说原因: $(tail -3 <<<"$out")"
grep -q '✅ 已更新' <<<"$out" && bad "谎报成功" || ok "没谎报成功"

echo; echo "── 零副作用逐项 ──"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$HEAD0" ]] \
  && ok "git HEAD 未动(仍是 ${HEAD0:0:12})" \
  || bad "HEAD 变成了 $(git -C "$REPO" rev-parse HEAD) —— 未发布提交被退回了"
[[ "$(digest_bot)" == "$B_BOT" ]] && ok "/opt/pdg-bot 内容逐字节不变" || bad "已装文件被改了"
[[ "$(modes_bot)" == "$B_MODE" ]] && ok "/opt/pdg-bot 的 mode/属主不变" || bad "mode/属主被改了"
[[ "$(sha256sum /etc/mosdns/config.yaml 2>/dev/null | cut -d' ' -f1)" == "$B_CFG" ]] \
  && ok "受管配置 /etc/mosdns/config.yaml 不变" || bad "配置被改了"
[[ "$(snap_count)" == "$B_SNAP" ]] \
  && ok "快照份数不变(仍 $B_SNAP 份 —— 拒绝路径不该留快照)" \
  || bad "快照从 $B_SNAP 变成 $(snap_count) —— 拒绝路径不该建快照"
[[ "$(inv_of mosdns)" == "$B_INV_M" ]] && ok "mosdns InvocationID 不变(没被重启)" \
  || bad "mosdns 被重启了: $B_INV_M → $(inv_of mosdns)"
[[ "$(inv_of pdg-bot)" == "$B_INV_B" ]] && ok "pdg-bot InvocationID 不变(没被重启)" \
  || bad "pdg-bot 被重启了: $B_INV_B → $(inv_of pdg-bot)"
# systemctl 一次都不该被调到(daemon-reload / restart / enable 全在拒绝之后)
A_CALLS="$(mut_calls)"; A_CALLS="${A_CALLS:-0}"
[[ "$A_CALLS" == "$B_CALLS" ]] \
  && ok "整次拒绝没有调过任何会改状态的 systemctl(仍 $B_CALLS 次)" \
  || bad "调了 $((A_CALLS - B_CALLS)) 次会改状态的 systemctl: $(grep -E '^systemctl (daemon-reload|restart|start|stop|enable|disable|reset-failed)' "$E2E_TMP/e2e-calls.log" | tail -3 | tr '\n' ' ')"

# ── dry-run 也要说清, 且同样零副作用 ────────────────────────────────────────
echo; echo "── dry-run ──"
B2="$(digest_bot)"; S2="$(snap_count)"
out2=$(bash /usr/local/bin/pdg update --dry-run 2>&1)
grep -qE '未发布|领先' <<<"$out2" && ok "dry-run 说清当前是未发布提交" || bad "dry-run 没说: $out2"
grep -qE '拒绝|不会自动降级' <<<"$out2" && ok "dry-run 说清正式 update 会拒绝" || bad "dry-run 没说会拒绝"
grep -q 'HEAD\.\.' <<<"$out2" && bad "dry-run 仍显示空的 HEAD..tag 区间" || ok "不再显示会被误读的空区间"
{ [[ "$(digest_bot)" == "$B2" ]] && [[ "$(snap_count)" == "$S2" ]]; } \
  && ok "dry-run 零副作用" || bad "dry-run 改了东西"

# ── 反向对照: 退回 v9.9.8 之后, 同一条命令必须能正常升级 ────────────────────
# 少了这一格, 把判据写成"永远拒绝"也能全绿, 而那会让 pdg update 彻底失效。
echo; echo "── 反向对照: 落后时照常升级 ──"
e2e_git "$REPO" checkout -q v9.9.8
e2e_git "$REPO" tag -a v9.9.9 -m v9.9.9 main >/dev/null 2>&1
out3=$(bash /usr/local/bin/pdg update 2>&1); rc3=$?
grep -qE '未发布|领先|分叉' <<<"$out3" \
  && bad "落后时也被当成领先/分叉挡住了 —— 判据误伤了正常升级: $(tail -3 <<<"$out3")" \
  || ok "落后时没有被方向判据挡住"
# 判据的位置也要对: 它在快照**之前**, 所以"过了这道门"的可观测证据就是这次真的去建快照了。
# 这一步之后 update 可能因为别的原因失败(沙箱里 mosdns 绑不了 :53), 那与本支无关 ——
# 本支只负责证明方向判据没有误伤正常升级。
grep -q '更新前留快照' <<<"$out3" \
  && ok "落后时真的走进了快照阶段(证明确实越过了方向判据这道门, 而不是恰好也失败了)" \
  || bad "落后时没走到快照阶段(rc=$rc3): $(tail -3 <<<"$out3")"

e2e_summary

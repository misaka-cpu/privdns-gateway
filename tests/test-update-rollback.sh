#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 更新快照 + 精确回滚回归(Item 10)。
#   A. cmd_rollback --dir 精确指定快照: 即使有更新的快照(index 0)也回滚到**指定**那份;
#      不带 --dir 时仍按 index 0(最近)。
#   B. cmd_rollback --git <ref>: 回滚后把 REPO_DIR 复位到该提交(还原仓库版本)。
#   C. 部分恢复失败(git ref 不存在)→ 不谎报"完全回滚", 打印"未完全回滚"并返回 1。
#   D. 静态: cmd_update 快照失败即中止; 用 --dir "$snap_dir" --git "$pre_sha"(非 cmd_rollback 0);
#      快照 cand 覆盖已装脚本 + 全部 unit; 越界守卫放行 usr/local/bin。
# 沙箱化: 覆写 _pdg_apply_snapshot_tree 落到沙箱(不碰真 /), 打桩 systemctl/nft/内核 check。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 造两份快照(旧 A=OLD / 新 B=NEW), 各含 backend + 判别标记 ──────────────────
SNAP="$WORK/snaps"; mkdir -p "$SNAP"
mksnap(){ # $1=目录名 $2=标记
  local d="$SNAP/$1"; mkdir -p "$d/tree/etc/privdns-gateway"
  printf 'singbox\n' > "$d/tree/etc/privdns-gateway/backend"
  printf '%s\n' "$2" > "$d/tree/etc/privdns-gateway/snapid"
  tar czf "$d/snap.tar.gz" -C "$d/tree" etc 2>/dev/null; rm -rf "$d/tree"
}
mksnap A OLD; sleep 1; mksnap B NEW    # B 更新(mtime 更晚 → ls -t 里 index 0)

# ── 沙箱 REPO_DIR: 两提交的 git 仓库 ─────────────────────────────────────────
REPO="$WORK/repo"; mkdir -p "$REPO"
# 这里的 `&&` 链本身是安全的(cd 失败会短路), 但守卫盯的是另一件事: $WORK 将来被改成别的
# 地方时, "在一次性库里动 ref"这个前提必须仍然成立, 而不是靠读代码去确认。
# shellcheck source=tests/repoguard.sh
source "$(dirname "${BASH_SOURCE[0]}")/repoguard.sh"
( cd "$REPO" && git init -q && E2E_ROOT="$ROOT" e2e_guard_repo . \
  && git config user.email t@t && git config user.name t \
  && echo v1 > f && git add f && git commit -qm c1 && echo v2 > f && git add f && git commit -qm c2 )
GOOD_REF=$(git -C "$REPO" rev-parse HEAD~1)   # 第一提交
HEAD_REF=$(git -C "$REPO" rev-parse HEAD)

# ── 抽取 cmd_rollback + 打桩 ──────────────────────────────────────────────────
sed -n '/^cmd_rollback(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" > "$WORK/rollback.sh"
# 快照里不含 etc/sing-box/config.json 与 etc/nftables.conf → 内核/nft 校验分支被跳过,
# 无需真 sing-box/mihomo/nft 二进制(也就不必打桩带连字符的函数名)。
cat > "$WORK/harness.sh" <<EOF
SNAP_DIR="$SNAP"
REPO_DIR="$REPO"
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "\$*"; }; c_y(){ echo "\$*"; }
_pdg_core(){ echo singbox; }
_pdg_core_svc(){ echo sing-box; }
_pdg_mktemp_dir(){ mktemp -d; }
_sb_panel_managed_on(){ return 1; }
_core_kernel_activate(){ return 0; }
# cmd_rollback 会用到的 units.sh / 归属助手: 沙箱里没有真 /etc, 一并打桩(与 systemctl/nft 同理)
pdg_write_unit(){ return 0; }
pdg_unit_mihomo(){ echo "[Unit]"; }
_pdg_drop_singbox_files(){ :; }
_pdg_singbox_is_ours(){ return 1; }
systemctl(){ return 0; }
nft(){ return 0; }
# 覆写落盘: 不碰真 /, 把被应用快照的判别标记抄到沙箱, 供断言"回滚到了哪份"
APPLIED="$WORK/applied_snapid"
_pdg_apply_snapshot_tree(){ cat "\$1/etc/privdns-gateway/snapid" > "\$APPLIED" 2>/dev/null; return 0; }
EOF

run(){ bash -c "source '$WORK/harness.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }

# ── A. --dir 精确回滚(指到旧的 A, 而非 index0 的 B) ─────────────────────────
rm -f "$WORK/applied_snapid"; out=$(run "--dir '$SNAP/A'")
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == OLD ]] \
  && ok "--dir 指定旧快照 A → 精确回滚到 A(未被 index0 的 B 顶掉)" || bad "A: applied=$(cat "$WORK/applied_snapid" 2>/dev/null) out=$out"

# 不带 --dir → index 0(最近 = B)
rm -f "$WORK/applied_snapid"; out=$(run "0")
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == NEW ]] \
  && ok "无 --dir → 默认 index0 仍回滚到最近 B" || bad "A2: applied=$(cat "$WORK/applied_snapid" 2>/dev/null) out=$out"

# ── B. --git 复位仓库 ────────────────────────────────────────────────────────
git -C "$REPO" reset --hard -q "$HEAD_REF"
out=$(run "--dir '$SNAP/A' --git '$GOOD_REF'")
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$GOOD_REF" ]] \
  && echo "$out" | grep -q '已回滚并重启服务' && ok "--git: REPO_DIR 复位到指定提交 + 报完全回滚" || bad "B: HEAD=$(git -C "$REPO" rev-parse HEAD) out=$out"

# ── C. git ref 不存在 → 不谎报完全回滚, 返回 1 ───────────────────────────────
rc=0; out=$(run "--dir '$SNAP/A' --git 'deadbeefdeadbeef'") || rc=$?
{ echo "$out" | grep -q '未完全回滚' && [[ "$rc" == 1 ]]; } \
  && ok "git ref 失效 → 打印'未完全回滚'并返回 1(不谎报成功)" || bad "C: rc=$rc out=$out"
# 但快照本身仍已恢复(apply 成功)
[[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == OLD ]] && ok "  部分失败下配置快照仍已落盘(只是 git 未复位)" || bad "C2"

# ── C3. 跨内核回滚: _core_kernel_activate 失败 → 计入 unrestored, 非0 + "未完全回滚" ──
# 造"回滚前是 mihomo, 快照是 singbox"的跨内核场景: _pdg_core 首调(pre_core)返 mihomo, 之后返 singbox。
cat > "$WORK/xcore.sh" <<EOF
PRE="$WORK/precore"; : > "\$PRE"
_pdg_core(){ if [[ -s "\$PRE" ]]; then echo singbox; else echo mihomo; printf x > "\$PRE"; fi; }
pdg_write_unit(){ return 0; }
_core_kernel_activate(){ return 1; }        # 注入: 快照核激活失败
EOF
runx(){ bash -c "source '$WORK/harness.sh'; source '$WORK/xcore.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }
rc=0; out=$(runx "--dir '$SNAP/A'") || rc=$?
{ [[ "$rc" != 0 ]] && grep -q '未完全回滚' <<<"$out" && ! grep -q '✅ 已回滚并重启服务' <<<"$out"; } \
  && ok "跨内核回滚: 内核激活失败 → 非0 + '未完全回滚' + 不报'✅ 已回滚'" || bad "C3: rc=$rc out=$out"
grep -q '内核激活' <<<"$out" && ok "  未恢复项明确列出'内核激活'" || bad "C3b: 未列出失败项 out=$out"

# ── C4. 校验快照旧配置要用**快照自带的内核**, 不能用当前(新)内核 ──────────────
# 场景: 新内核拒绝旧配置(正是要回滚的原因)。若拿当前新内核去校验快照里的旧配置, 它当然
# 说"不合法", 回滚就被自己挡住了 —— 旧内核和旧配置本该一起回去。
mkmihomo_snap(){  # $1=目录名 $2=快照内核的 check 退出码
  local d="$SNAP/$1"; rm -rf "$d"; mkdir -p "$d/tree/etc/privdns-gateway" "$d/tree/etc/mihomo" "$d/tree/usr/local/bin"
  printf 'mihomo\n' > "$d/tree/etc/privdns-gateway/backend"
  printf 'SNAP-M\n'  > "$d/tree/etc/privdns-gateway/snapid"
  printf 'mixed-port: 7890\n' > "$d/tree/etc/mihomo/config.yaml"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$d/tree/usr/local/bin/mihomo"; chmod 755 "$d/tree/usr/local/bin/mihomo"
  # 按 cmd_snapshot 的方式打**显式成员路径**: 递归打 usr 会带出 usr/ 目录项, 触发越界守卫
  tar czf "$d/snap.tar.gz" -C "$d/tree" etc/privdns-gateway etc/mihomo usr/local/bin/mihomo 2>/dev/null
  rm -rf "$d/tree"
}
# 当前内核一律拒绝旧配置(模拟"新内核不认旧配置")
cat > "$WORK/curkernel.sh" <<'EOF'
mihomo(){ return 1; }
_pdg_core(){ echo mihomo; }
_pdg_core_svc(){ echo mihomo; }
EOF
runm(){ bash -c "source '$WORK/harness.sh'; source '$WORK/curkernel.sh'; source '$WORK/rollback.sh'; cmd_rollback $1" 2>&1; }

mkmihomo_snap M_OK 0            # 快照自带的 mihomo 接受旧配置
rm -f "$WORK/applied_snapid"; rc=0; out=$(runm "--dir '$SNAP/M_OK'") || rc=$?
{ [[ "$rc" == 0 ]] && [[ "$(cat "$WORK/applied_snapid" 2>/dev/null)" == SNAP-M ]]; } \
  && ok "快照内核接受旧配置 → 回滚成功落盘(不被当前新内核挡住)" || bad "C4a: rc=$rc out=$out"

mkmihomo_snap M_BAD 1           # 快照自带的 mihomo 也拒绝 → 这份快照真的不可用
rm -f "$WORK/applied_snapid"; rc=0; out=$(runm "--dir '$SNAP/M_BAD'") || rc=$?
{ [[ "$rc" != 0 ]] && [[ ! -e "$WORK/applied_snapid" ]]; } \
  && ok "快照内核也拒绝旧配置 → 落盘前中止(不写坏现网)" || bad "C4b: rc=$rc applied=$(cat "$WORK/applied_snapid" 2>/dev/null)"

# ── D. 静态断言: cmd_update / cmd_snapshot / 越界守卫 ─────────────────────────
u="$ROOT/deploy/bot/pdg.sh"
grep -q '更新前快照失败, 中止更新' "$u" && ok "cmd_update: 快照失败即中止(不在无法回滚下继续)" || bad "D1: 缺快照失败中止"
grep -q 'cmd_rollback --dir "\$snap_dir" --git "\$pre_sha"' "$u" && ok "cmd_update: 回滚用精确 --dir+--git(非 cmd_rollback 0)" || bad "D2"
grep -q "pre_sha=.*git -C .*rev-parse HEAD" "$u" && ok "cmd_update: 记录升级前 Git SHA" || bad "D3"
for p in 'usr/local/bin/pdg' 'usr/local/bin/pdg-set-token' 'etc/systemd/system/mihomo.service' 'etc/systemd/system/pdg-mitm.service' '99-pdg-cert.sh'; do
  grep -q "$p" "$u" || bad "D4: 快照 cand 缺 $p"
done
grep -q "etc/systemd/system/mihomo.service etc/systemd/system/sing-box.service" "$u" && ok "cmd_snapshot cand: 覆盖已装脚本 + 内核/mitm/probe/health 全部 unit + cert hook" || bad "D4 汇总"
# D5 越界守卫: 拿真实的那条正则去跑样本, 而不是 grep 一段字面量 —— 字面量只能证明"那行字
# 还在", 证明不了它放行/拦住的到底是什么。守卫的前缀集必须与 cmd_snapshot 的候选集对齐:
# 装的脚本(usr/local/bin)、iOS 描述文件产物(var/lib 下那一个子树)要能进快照; 别的一律不行。
_guard="$(sed -n "s/.*grep -Evq '\(\^([^']*)\)'.*/\1/p" "$u" | head -1)"
[[ -n "$_guard" ]] || _guard="$(grep -oE "\^\(etc\|[^']*\)\(/\|\\$\)" "$u" | head -1)"
_chk(){ printf '%s\n' "$1" | grep -Evq "$_guard"; }   # 返回 0 = 会被守卫判越界
for _good in 'etc/mosdns/config.yaml' 'opt/pdg-bot/bot.py' 'usr/local/bin/pdg' \
             'var/lib/privdns-gateway/ios-profile/current.mobileconfig' \
             'var/lib/privdns-gateway/ios-profile/previous.mobileconfig'; do
  _chk "$_good" && bad "D5: 守卫误拦了应进快照的 $_good"
done
ok "回滚越界守卫放行 etc/opt/usr-local-bin 与 iOS 描述文件产物(真跑正则, 非字面量)"
for _bad in 'var/lib/privdns-gateway/tx/abc/before' 'var/lib/privdns-gateway/backups/x.tar.gz' \
            'var/lib/other/thing' 'var/log/syslog' 'root/.ssh/authorized_keys'; do
  _chk "$_bad" || bad "D5: 守卫放行了不该进快照的 $_bad"
done
ok "守卫仍然拦住 tx 记录/备份包/其它 var 路径(没有放宽成整个 var/lib)"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

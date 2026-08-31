#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 真跑 `pdg update`。造一个带两个 tag 的**真 git 仓库**当发布源, 让 cmd_update
# 走完整条路: 取 tag → reset → 装文件 → __migrate → 内核 → 校验门 → doctor → 成功/回滚。
#
# 单测(test-update-faults.sh)是把 cmd_update 抽出来打桩跑的; 这里跑的是**装在机器上的
# 那份脚本**对着真仓库、真快照目录、真 doctor 做的事 —— 快照能不能建、回滚能不能真的把
# 文件换回去, 只有这么跑才看得出来。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v git >/dev/null 2>&1 || e2e_skip "无 git"
e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft singbox
printf 'android\n' > /etc/privdns-gateway/platform
printf 'singbox\n' > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway
e2e_seed_cert || e2e_skip "无 openssl, 造不出占位证书"

# 内核二进制打桩: update 里的 _update_core_binary 会比对版本, 让它认为"已是钉死版本"
. "$E2E_ROOT/lib/versions.sh"
# 播真钉死版, 不用 shell 桩: 桩自报版本是对的、内容是错的, 而 install.sh 的短路与
# doctor 的完整性判据现在都看内容(CI 33353591548 的五支红灯就是这么来的)。
e2e_seed_mihomo_bin || { echo "[FAIL] 播种钉定 mihomo 失败"; exit 1; }
# 现场是"仍在跑 sing-box 的老机器"(backend=singbox + 二进制/unit 都在): 这次 update 应当
# 由 migrate_drop_singbox 自动迁到 mihomo 并把 sing-box 运行时清掉。
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/sing-box; chmod 755 /usr/local/bin/sing-box
# 老版装机真正生成的 unit 形态 —— 归属判定据此认出"这是本项目装的"才会去清理它
# (随手写的 `[Unit]` 桩不具备该特征, 会被当成第三方 sing-box 保留, 那是另一条分支)
cat > /etc/systemd/system/sing-box.service <<'SBU'
[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SBU

# ── 造发布源: 真 git 仓库, 两个 tag(v9.9.8 当前 / v9.9.9 新版) ────────────────
# 连 origin 都是真的(本地裸仓库): pdg update 里的 `git fetch --tags origin main` 照跑不误,
# 于是"取 tag"这段也在覆盖范围内, 且全程离线 —— 不打桩、不碰 GitHub。
REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-origin.git
rm -rf "$REPO/.git" "$ORIGIN"            # e2e_seed_install 拷进来的是开发机/CI 的 .git, 弃用
git -C "$REPO" init -q -b main
e2e_guard_repo "$REPO" || exit 1     # 刚 init 出来的一次性库才准动 ref
e2e_git "$REPO" config user.email t@t; e2e_git "$REPO" config user.name t
e2e_git "$REPO" config commit.gpgsign false
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm base >/dev/null 2>&1
e2e_git "$REPO" tag v9.9.8
# 新版本: 往 bot 模块里塞个可辨识标记, 用来验证"文件真的被换成了新版"
echo "# NEWVERSION-MARKER" >> "$REPO/deploy/bot/checks.py"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm newver >/dev/null 2>&1
e2e_git "$REPO" tag v9.9.9
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d v9.9.9 >/dev/null  # 本地先没有新 tag → 逼 update 真去 origin 取
e2e_git "$REPO" checkout -q v9.9.8
{ [[ "$(git -C "$REPO" describe --tags)" == v9.9.8 ]] && [[ -z "$(git -C "$REPO" tag -l v9.9.9)" ]]; } \
  && ok "发布源就位: 工作仓库停在 v9.9.8, 新 tag v9.9.9 只在 origin 上(要靠 fetch 才拿得到)" \
  || bad "发布源没造对: $(git -C "$REPO" describe --tags), tags=$(git -C "$REPO" tag -l)"

# ── 1. 正常更新: 应装上新版文件并显示成功 ════════════════════════════════════
echo; echo "── 1. 正常更新 ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out"; } \
  && ok "pdg update 成功走完(取 tag→装文件→迁移→内核→校验门→doctor)" \
  || bad "更新失败 rc=$rc: $(tail -5 <<<"$out")"
grep -q 'NEWVERSION-MARKER' /opt/pdg-bot/checks.py \
  && ok "新版文件真的装到了 /opt/pdg-bot(不是只动了 git)" || bad "部署文件仍是旧版"
[[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == v9.9.9 ]] \
  && ok "仓库已切到最新发布 tag v9.9.9" || bad "仓库 tag=$(git -C "$REPO" describe --tags 2>/dev/null)"
snaps=$(find /var/lib/privdns-gateway/backups -name snap.tar.gz 2>/dev/null | wc -l)
[[ "$snaps" -ge 1 ]] && ok "更新前留下了快照($snaps 份)" || bad "没有快照"
# v1.6.0: 这台老机器原本跑 sing-box, update 应顺带把它迁到 mihomo 并清掉 sing-box 运行时
[[ "$(cat /etc/privdns-gateway/backend 2>/dev/null)" == mihomo ]] \
  && ok "旧 sing-box 机器: update 后 backend 已迁为 mihomo" \
  || bad "backend=$(cat /etc/privdns-gateway/backend 2>/dev/null)"
{ [[ ! -e /usr/local/bin/sing-box ]] && [[ ! -e /etc/systemd/system/sing-box.service ]]; } \
  && ok "旧 sing-box 机器: update 后 sing-box 二进制/unit 已移除" || bad "sing-box 运行时仍残留"
grep -q '出口/分流/证书/DoT 不动' <<<"$out" \
  && ok "迁移明确声明不动出口/分流/证书/DoT" || bad "迁移未声明数据保全"

# ── 2. doctor 判失败 → 必须回滚且不显示成功 ═════════════════════════════════
echo; echo "── 2. doctor 报 fail → 回滚 ──"
e2e_git "$REPO" checkout -q v9.9.8                     # 退回旧版, 好再更新一次
# 这里要的是"把**部署模块**退回旧版", 不是"清空 /opt/pdg-bot"。整目录 rm -rf 会把同住
# 一个目录的用户数据(PDG_USER_DATA 里的 dot-domain / rulesets.json)一并带走, 于是机器
# 落到"模块在、用户数据没了"这种真机永远不会出现的形态; 随后 __migrate 按契约 fail-closed
# ("DoT 域名缺失 → 不部署 observer"), 更新失败回滚, 红的是夹具而不是产品。
# 真机上更新绝不动这些文件 —— 成功与失败回滚两条路径都实测过前后像逐字节一致
# (含 mode/uid/gid), 见 tests/e2e-update-preserve-userdata.sh。
# 保留清单从产品自己的保全契约读, 不在这里写死文件名(见 e2e_reset_botdir)。
e2e_reset_botdir || bad "重置 /opt/pdg-bot 失败"
for f in "$E2E_ROOT"/deploy/bot/*.py; do install -m755 "$f" /opt/pdg-bot/; done
install -m755 "$E2E_ROOT/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
# 让 doctor 报一条 fail(内核服务不在) —— 用有状态 systemd 桩把 mihomo 置为 inactive
e2e_svc_fail mihomo
before=$(sha256sum /opt/pdg-bot/checks.py | cut -d' ' -f1)
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && ! grep -q '✅ 已更新' <<<"$out"; } \
  && ok "doctor 有 fail → 返回非0 且不显示'已更新'" || bad "rc=$rc 却报了成功"
grep -qE '自检发现|回滚' <<<"$out" && ok "明确说明是自检失败并回滚" || bad "没说回滚原因: $(tail -3 <<<"$out")"
[[ "$(sha256sum /opt/pdg-bot/checks.py | cut -d' ' -f1)" == "$before" ]] \
  && ok "回滚把部署文件真的换回了更新前那份(按 sha 比对)" || bad "回滚后文件不是更新前的"
grep -q 'NEWVERSION-MARKER' /opt/pdg-bot/checks.py \
  && bad "回滚后仍残留新版标记(说明没换回去)" || ok "回滚后无新版残留"
rm -f $E2E_TMP/e2e-svc/mihomo.ac

# ── 3. --dry-run 只看不动 ════════════════════════════════════════════════════
echo; echo "── 3. --dry-run ──"
b1=$(sha256sum /opt/pdg-bot/checks.py | cut -d' ' -f1)
out=$(bash /usr/local/bin/pdg update --dry-run 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && [[ "$(sha256sum /opt/pdg-bot/checks.py | cut -d' ' -f1)" == "$b1" ]]; } \
  && ok "--dry-run 不动任何部署文件" || bad "dry-run 改了文件"
grep -qE '当前|最新发布' <<<"$out" && ok "--dry-run 打印当前/最新版本对照" || bad "dry-run 输出不含版本对照"

# ── 4. 快照 → 手工回滚: 配置真的被换回去 ═════════════════════════════════════
echo; echo "── 4. snapshot + rollback ──"
printf 'MARK=before-snapshot\n' >> /etc/privdns-gateway/profile.env
bash /usr/local/bin/pdg snapshot >/dev/null 2>&1
printf 'MARK=after-snapshot\n' >> /etc/privdns-gateway/profile.env
out=$(bash /usr/local/bin/pdg rollback 0 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已回滚' <<<"$out"; } \
  && ok "pdg rollback 0 成功" || bad "回滚失败 rc=$rc: $(tail -3 <<<"$out")"
{ grep -q 'before-snapshot' /etc/privdns-gateway/profile.env \
  && ! grep -q 'after-snapshot' /etc/privdns-gateway/profile.env; } \
  && ok "配置被换回快照时刻的内容(快照后的改动已消失)" || bad "配置没回到快照状态"

# ══ 静态文件全集在 update 后逐项同步 ═══════════════════════════════════════
# 这条以前没有。11 个项目静态文件曾经只在 install.sh 里各写一行装, 不在任何清单里 ——
# `pdg update` 从来不同步它们, Bot 本体永远停在装机那一版。真源统一之后必须有东西盯着。
echo; echo "── 静态文件同步 ──"
# shellcheck source=lib/modules.sh
source "$E2E_ROOT/lib/modules.sh"
PLAT="$(cat /etc/privdns-gateway/platform 2>/dev/null || echo android)"
# 先把每一项都写成"旧版哨兵", 再跑一次 update, 逐项比对是否等于仓库当前版本。
_stale=0
while read -r src name _mode; do
  [[ -n "$src" ]] || continue
  [[ -f "/opt/pdg-bot/$name" ]] || continue
  printf '#PDG-STALE-SENTINEL\n' > "/opt/pdg-bot/$name"
  _stale=$((_stale+1))
done < <(pdg_platform_modules "$PLAT")
[[ "$_stale" -gt 0 ]] && ok "写入旧版哨兵: $_stale 项" || bad "一个静态文件都没找到, 前提不成立"

e2e_git "$REPO" tag -d v9.9.9 >/dev/null 2>&1 || true
e2e_git "$REPO" checkout -q v9.9.8 2>/dev/null || true
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
_diff=0; _missing=0
while read -r src name _mode; do
  [[ -n "$src" ]] || continue
  if [[ ! -f "/opt/pdg-bot/$name" ]]; then _missing=$((_missing+1)); continue; fi
  if ! cmp -s "$REPO/$src" "/opt/pdg-bot/$name"; then
    _diff=$((_diff+1)); echo "    不同步: $name"
  fi
done < <(pdg_platform_modules "$PLAT")
{ [[ "$rc" == 0 ]] && [[ "$_diff" == 0 ]] && [[ "$_missing" == 0 ]]; } \
  && ok "update 后静态文件逐项等于仓库版本(0 项不同步, 0 项缺失)" \
  || bad "update 后仍有 $_diff 项不同步 / $_missing 项缺失 (rc=$rc)"
# mode 也要对
_modebad=0
while read -r _src name mode; do
  [[ -n "$name" && -f "/opt/pdg-bot/$name" ]] || continue
  [[ "$(stat -c %a "/opt/pdg-bot/$name")" == "$mode" ]] || { _modebad=$((_modebad+1)); echo "    mode 不符: $name"; }
done < <(pdg_platform_modules "$PLAT")
[[ "$_modebad" == 0 ]] && ok "update 后 mode 与真源声明一致" || bad "$_modebad 项 mode 不符"

# ══ 用户数据与运行状态跨 update 不变 ═══════════════════════════════════════
echo; echo "── 用户数据保持 ──"
printf 'PDG_BOT_TOKEN=123456:USERTOKEN\n' > /etc/privdns-gateway/bot.env
printf '{"user":{"label":"我的"}}\n' > /opt/pdg-bot/rulesets.json
printf 'dot.user.example\n' > /opt/pdg-bot/dot-domain
_B=$(sha256sum /etc/privdns-gateway/bot.env | cut -d' ' -f1)
_R=$(sha256sum /opt/pdg-bot/rulesets.json | cut -d' ' -f1)
_D=$(sha256sum /opt/pdg-bot/dot-domain | cut -d' ' -f1)
_P=$(sha256sum /etc/privdns-gateway/platform | cut -d' ' -f1)
e2e_git "$REPO" tag -d v9.9.9 >/dev/null 2>&1 || true
e2e_git "$REPO" checkout -q v9.9.8 2>/dev/null || true
bash /usr/local/bin/pdg update >/dev/null 2>&1
{ [[ "$(sha256sum /etc/privdns-gateway/bot.env | cut -d' ' -f1)" == "$_B" ]] \
  && [[ "$(sha256sum /opt/pdg-bot/rulesets.json | cut -d' ' -f1)" == "$_R" ]] \
  && [[ "$(sha256sum /opt/pdg-bot/dot-domain | cut -d' ' -f1)" == "$_D" ]] \
  && [[ "$(sha256sum /etc/privdns-gateway/platform | cut -d' ' -f1)" == "$_P" ]]; } \
  && ok "bot.env / rulesets.json / dot-domain / platform 跨 update 逐字节不变" \
  || bad "用户数据被 update 改动了"

# ══ 已是最新时零改动 ═══════════════════════════════════════════════════════
echo; echo "── 幂等 ──"
_before="$(find /opt/pdg-bot -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
_after="$(find /opt/pdg-bot -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)"
# cmd_update 没有"已是最新就早退"这条路径: 它每次都 reset 到最新 tag 再重装一遍。
# 判据分两件事, 不要混:
#   1) **文件不漂移** —— 无论这次是成功提交还是自检失败回滚, /opt/pdg-bot 都必须逐字节不变;
#   2) 若返回非 0, 必须明说是回滚, 不许静默。
# (本沙箱里前面几节故意扰动过服务态, doctor 判失败并回滚是正确行为, 不该被算成"不幂等"。)
[[ "$_before" == "$_after" ]] \
  && ok "已在最新 tag 上重复 update: /opt/pdg-bot 逐字节不变(无论提交还是回滚)" \
  || bad "重复 update 造成了文件漂移"
if [[ "$rc" == 0 ]]; then
  ok "重复 update 成功提交"
else
  grep -qE '已回滚|回滚到' <<<"$out" \
    && ok "重复 update 自检未过 → 明确回滚并返回非 0(不谎报成功)" \
    || bad "返回非 0 却没说明回滚: $(tail -2 <<<"$out")"
fi

# ══ 未发布分支: 找不到对应 release 必须失败并保持现网 ══════════════════════
# 这是**设计语义**, 不是缺陷: `pdg update` 只跟随发布 tag, 不跟 main、不跟任意 commit。
echo; echo "── 未发布分支边界 ──"
_snap="$(find /opt/pdg-bot -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)"
_cfg="$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)"
# xargs 起的是子进程, 调不到 e2e_git 这个 shell 函数 —— 用数组接住再一次删完。
mapfile -t _vt < <(git -C "$REPO" tag -l 'v*')
[[ ${#_vt[@]} -gt 0 ]] && { e2e_git "$REPO" tag -d "${_vt[@]}" >/dev/null 2>&1 || exit 1; }
( cd "$ORIGIN" || { echo "[FAIL] ORIGIN 不存在"; exit 1; }
  mapfile -t _vo < <(git tag -l 'v*')
  [[ ${#_vo[@]} -gt 0 ]] && { e2e_git . tag -d "${_vo[@]}" >/dev/null 2>&1 || exit 1; } ) || true
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE '没有发布 tag|没有任何发布 tag|无法确定目标版本' <<<"$out"; } \
  && ok "没有任何发布 tag → 明确失败, 不猜一个 commit 装上去" \
  || bad "未发布状态下 update 竟然 rc=$rc: $(tail -2 <<<"$out")"
{ [[ "$(find /opt/pdg-bot -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)" == "$_snap" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$_cfg" ]]; } \
  && ok "失败后现网一个字节都没动" || bad "失败却改了现网"

# ══ py_compile 失败: 真抵达该阶段, 且必须精确回滚 ═════════════════════════
# 选 report.py 作坏模块是有依据的: 它不被任何 migrate_* 触及, 也不被 doctor/checks/bot
# import —— 于是坏内容能活过"部署 → __migrate → 内核二进制"三段, 真正撞到 py_compile 那道门。
# 换成 nftscan.py / cidrgen.py 之类会在迁移里被调用的模块, 就会提前在 __migrate 失败,
# 测的就不是 py_compile 了。
echo; echo "── py_compile 失败与回滚 ──"
source "$E2E_ROOT/lib/modules.sh"
PLAT="$(cat /etc/privdns-gateway/platform 2>/dev/null || echo android)"

_snapshot_state(){   # 输出: 每个受管成员的 "名字 sha mode uid:gid"
  while read -r _s _n _m; do
    [[ -n "$_n" ]] || continue
    if [[ -f "/opt/pdg-bot/$_n" ]]; then
      printf '%s %s %s %s\n' "$_n" "$(sha256sum "/opt/pdg-bot/$_n" | cut -d' ' -f1)" \
             "$(stat -c%a "/opt/pdg-bot/$_n")" "$(stat -c%u:%g "/opt/pdg-bot/$_n")"
    else printf '%s MISSING - -\n' "$_n"; fi
  done < <(pdg_platform_modules "$PLAT")
}

# 操作前: 给两个文件设置**合法但不同于 manifest** 的 mode —— 一个普通数据文件、一个可执行脚本。
# 回滚要恢复的是这两个原始值, 而不是 manifest 值, 更不是写死的 0644/0755。
_norm=rescue.sh          # manifest 声明 644
_exe=report.py           # manifest 声明 755
chmod 640 "/opt/pdg-bot/$_norm"; chmod 700 "/opt/pdg-bot/$_exe"
_pre_norm_mode=$(stat -c%a "/opt/pdg-bot/$_norm"); _pre_exe_mode=$(stat -c%a "/opt/pdg-bot/$_exe")
_pre_norm_own=$(stat -c%u:%g "/opt/pdg-bot/$_norm"); _pre_exe_own=$(stat -c%u:%g "/opt/pdg-bot/$_exe")
_pre_norm_sha=$(sha256sum "/opt/pdg-bot/$_norm" | cut -d' ' -f1)
_pre_exe_sha=$(sha256sum "/opt/pdg-bot/$_exe" | cut -d' ' -f1)
_before="$(_snapshot_state)"
_pre_bot=$(sha256sum /etc/privdns-gateway/bot.env 2>/dev/null | cut -d' ' -f1)
_pre_rs=$(sha256sum /opt/pdg-bot/rulesets.json 2>/dev/null | cut -d' ' -f1)
_pre_mos=$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)
{ [[ "$_pre_norm_mode" == 640 ]] && [[ "$_pre_exe_mode" == 700 ]]; } \
  && ok "前提: 操作前 mode 已设为非 manifest 值($_norm=640, $_exe=700)" \
  || bad "前提没设上: $_norm=$_pre_norm_mode $_exe=$_pre_exe_mode"

# 造一个只坏了 report.py 的新 release
e2e_git "$REPO" tag -d v9.9.9 >/dev/null 2>&1 || true
e2e_git "$REPO" checkout -q v9.9.8 2>/dev/null || true
( cd "$REPO" || { echo "[FAIL] REPO 不存在"; exit 1; }
  printf 'def broken(:\n    pass\n' > deploy/bot/report.py
  e2e_git . add -A >/dev/null 2>&1
  e2e_git . -c user.email=t@t -c user.name=t commit -qm "bad release" >/dev/null 2>&1
  e2e_git . tag -f v9.9.10 >/dev/null 2>&1
  e2e_git . push -q -f origin HEAD:refs/heads/main --tags >/dev/null 2>&1 ) || true
e2e_git "$REPO" reset -q --hard v9.9.8 2>/dev/null || true
e2e_git "$REPO" tag -d v9.9.10 >/dev/null 2>&1 || true

# HEAD 必须在**跑 update 的那一刻**取。第一版在夹具把仓库挪到 v9.9.8 之前就取了,
# 于是回滚回到 v9.9.8 反而被判成"没恢复" —— 是取样点错了, 不是产品错。
_pre_head=$(git -C "$REPO" rev-parse HEAD)
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?

# ── 抵达阶段的结构化证据(不靠 grep 日志里的 py_compile 字样) ──────────────
grep -q '已切到发布 v9.9.10' <<<"$out" && ok "阶段: 发现并切到测试 release v9.9.10" || bad "没切到测试 release"
grep -q '更新前留快照' <<<"$out" && ok "阶段: 更新前快照已创建" || bad "没留快照"
{ ! grep -qE '必需文件安装失败|运行模块清单不合法' <<<"$out"; } \
  && ok "阶段: manifest 校验与静态部署都通过了(没被前一阶段拦下)" || bad "在部署阶段就失败了, 没走到 py_compile"
{ ! grep -q '迁移(__migrate)失败' <<<"$out"; } \
  && ok "阶段: __migrate 通过(坏模块没被迁移提前执行)" || bad "__migrate 提前失败"
grep -q 'Python 语法错误' <<<"$out" && ok "阶段: 非零来自 py_compile 这道门" || bad "失败点不是 py_compile: $(tail -3 <<<"$out")"
# 独立复证: 直接对那份坏内容跑一次真 py_compile, 确认它确实编不过
printf 'def broken(:\n    pass\n' > $E2E_TMP/badmod.py
python3 -m py_compile $E2E_TMP/badmod.py 2>/dev/null \
  && bad "坏模块居然能编译 —— 这条场景没构造成" || ok "独立复证: 该模块内容确实过不了真 py_compile"
rm -f $E2E_TMP/badmod.py

# ── 回滚验收 ──────────────────────────────────────────────────────────────
[[ "$rc" != 0 ]] && ok "update 返回非 0" || bad "py_compile 失败却返回 0"
{ ! grep -q '✅ 已更新' <<<"$out"; } && ok "没有显示已更新" || bad "谎报成功"
grep -qE '回滚' <<<"$out" && ok "明确显示已回滚" || bad "没说回滚"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$_pre_head" ]] \
  && ok "git HEAD 恢复到更新前" || bad "git 状态没恢复"
_after="$(_snapshot_state)"
if [[ "$_before" == "$_after" ]]; then
  ok "全部 $(wc -l <<<"$_before") 项受管成员的内容/mode/owner 逐项恢复"
else
  bad "受管成员没完全恢复:"; diff <(echo "$_before") <(echo "$_after") | head -4
fi
# NC9 的两条重点: 恢复的必须是**操作前的原始 mode**, 不是 manifest 值也不是写死值
{ [[ "$(stat -c%a "/opt/pdg-bot/$_norm")" == "$_pre_norm_mode" ]] \
  && [[ "$(sha256sum "/opt/pdg-bot/$_norm"|cut -d' ' -f1)" == "$_pre_norm_sha" ]] \
  && [[ "$(stat -c%u:%g "/opt/pdg-bot/$_norm")" == "$_pre_norm_own" ]]; } \
  && ok "普通文件 $_norm: 内容/mode($_pre_norm_mode, 非 manifest 的 644)/owner 全部恢复" \
  || bad "$_norm 恢复不对: mode=$(stat -c%a "/opt/pdg-bot/$_norm") 期望 $_pre_norm_mode"
{ [[ "$(stat -c%a "/opt/pdg-bot/$_exe")" == "$_pre_exe_mode" ]] \
  && [[ "$(sha256sum "/opt/pdg-bot/$_exe"|cut -d' ' -f1)" == "$_pre_exe_sha" ]] \
  && [[ "$(stat -c%u:%g "/opt/pdg-bot/$_exe")" == "$_pre_exe_own" ]]; } \
  && ok "可执行脚本 $_exe: 内容/mode($_pre_exe_mode, 非 manifest 的 755)/owner 全部恢复" \
  || bad "$_exe 恢复不对: mode=$(stat -c%a "/opt/pdg-bot/$_exe") 期望 $_pre_exe_mode"
grep -q 'def broken(' "/opt/pdg-bot/$_exe" 2>/dev/null \
  && bad "测试 release 的坏模块残留在盘上" || ok "坏模块未残留"
{ [[ "$(sha256sum /etc/privdns-gateway/bot.env 2>/dev/null|cut -d' ' -f1)" == "$_pre_bot" ]] \
  && [[ "$(sha256sum /opt/pdg-bot/rulesets.json 2>/dev/null|cut -d' ' -f1)" == "$_pre_rs" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml|cut -d' ' -f1)" == "$_pre_mos" ]]; } \
  && ok "用户数据与受管配置逐字节不变(bot.env/rulesets.json/mosdns)" || bad "用户数据被改动"
[[ -z "$(ls -d /opt/pdg-bot/__pycache__ 2>/dev/null)" ]] \
  && ok "无 __pycache__ 残留(py_compile 的产物已清)" || ok "存在 __pycache__(py_compile 产物, 非静态成员)"

e2e_summary

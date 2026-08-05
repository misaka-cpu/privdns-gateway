#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: **从上一个发布 tag 升到本版**(RELEASE-CHECKLIST 场景 ②)。
#
# 与 e2e-update.sh 的区别在"更新器是谁":
#   · e2e-update.sh 用**当前代码**造两个合成 tag(v9.9.8/v9.9.9), 验的是 update 机制本身;
#   · 这里机器上跑的是**真实上一个发布 tag 的那份 pdg**, 目标是当前工作树。存量用户升级
#     时执行的就是这一份旧脚本 —— "旧脚本装新版"的时序滞后(新模块要靠 migrate 自愈、
#     旧 cmd_rollback source 到新版 lib)只有这么跑才复现得出来。
#
# 与 e2e-cross-version-rollback.sh 的区别在"走哪条路": 那个专治 v1.5.x 时代
# sing-box→mihomo 的**失败回滚**(它的 sing-box 断言对迁移之后的 tag 不适用); 这里走
# **成功升级**那条, 断言升完之后现场是对的。
#
# 上一个 tag 默认取本地最大的 v* tag, 可用 PDG_PREV_TAG 覆盖。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v git >/dev/null 2>&1 || e2e_skip "无 git"

# "上一个发布" = 最新的 v* tag, 但**跳过指向 HEAD 自己的那个**。
# 发布当天 HEAD 上会打上本版的 tag, 直接取最大值就变成"从本版升到本版" —— 一个恒过的空测试,
# 而且恰恰是最需要它的那一天失效。
PREV="${PDG_PREV_TAG:-}"
if [[ -z "$PREV" ]]; then
  _head_tags="$(git -C "$E2E_ROOT" tag --points-at HEAD 2>/dev/null)"
  while read -r _t; do
    [[ -n "$_t" ]] || continue
    grep -qxF "$_t" <<<"$_head_tags" && continue
    PREV="$_t"; break
  done < <(git -C "$E2E_ROOT" tag -l 'v*' --sort=-v:refname)
fi
[[ -n "$PREV" ]] || e2e_skip "本地没有 HEAD 之外的 v* tag(浅克隆? 首次发布?), 升级用例跳过"
git -C "$E2E_ROOT" rev-parse -q --verify "$PREV^{commit}" >/dev/null \
  || e2e_skip "取不到 $PREV 的对象(浅克隆?), 升级用例跳过"
NEW_TAG="${PDG_NEW_TAG:-v9.9.9}"
PLAT="${PDG_E2E_PLATFORM:-ios}"
echo "══════════ 上一个发布: $PREV → 本版($NEW_TAG, 平台 $PLAT) ══════════"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft mihomo
printf '%s\n' "$PLAT" > /etc/privdns-gateway/platform
printf 'mihomo\n'     > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway
e2e_seed_cert || e2e_skip "无 openssl, 造不出占位证书"

. "$E2E_ROOT/lib/versions.sh"
cat > /usr/local/bin/mihomo <<S
#!/bin/sh
case "\$1" in -v|version) echo "Mihomo Meta $MIHOMO_VER linux amd64";; -t) exit 0;; esac
exit 0
S
chmod 755 /usr/local/bin/mihomo

# ── 发布源: 上一个 tag 的**真代码** + 当前工作树 ──────────────────────────────
REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-upg-origin.git
rm -rf "$REPO/.git" "$ORIGIN"
git -C "$REPO" init -q -b main
e2e_guard_repo "$REPO" || exit 1
e2e_git "$REPO" config user.email t@t; e2e_git "$REPO" config user.name t
e2e_git "$REPO" config commit.gpgsign false

rm -rf "${REPO:?}"/* 2>/dev/null || true
git -C "$E2E_ROOT" archive "$PREV" | tar -x -C "$REPO"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm "$PREV" >/dev/null 2>&1
e2e_git "$REPO" tag "$PREV"

rm -rf "${REPO:?}"/* 2>/dev/null || true
tar -C "$E2E_ROOT" --exclude=.git -cf - . | tar -x -C "$REPO"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm "$NEW_TAG(current)" >/dev/null 2>&1
e2e_git "$REPO" tag "$NEW_TAG"
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d "$NEW_TAG" >/dev/null      # 新 tag 只在 origin 上, 逼 update 真去 fetch
e2e_git "$REPO" checkout -q "$PREV"

# 机器上装的是**上一个发布**的那份脚本与模块 —— 这才是存量用户的现场
install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
rm -rf /opt/pdg-bot; mkdir -p /opt/pdg-bot
for f in "$REPO"/deploy/bot/*.py; do install -m755 "$f" /opt/pdg-bot/; done
install -m755 "$REPO/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
{ [[ "$(git -C "$REPO" describe --tags)" == "$PREV" ]] && [[ -z "$(git -C "$REPO" tag -l "$NEW_TAG")" ]]; } \
  && ok "现场就位: 机器停在 $PREV, 更新器来自该版本, 新 tag 只在 origin 上" \
  || bad "发布源没造对: $(git -C "$REPO" describe --tags 2>/dev/null)"

# 升级前记下**用户数据与凭据** —— 这些升完必须逐字节不变。
# /etc/mosdns/config.yaml **不在**这一组: 它是受管渲染文件, 迁移本来就该归一其中的受管旋钮
# (如 cache size: install 按内存模式渲染 8192/2048, pdg 更新按 profile 迁移)。把它算成
# "用户数据"会把一次正常迁移误判成数据损失。用户自己写的东西在 rules/*.txt 与 profile.env 里,
# 那几份在下面按逐字节验。
_ud(){ sha256sum /etc/privdns-gateway/bot.env /etc/privdns-gateway/profile.env \
        /opt/pdg-bot/rulesets.json /etc/privdns-gateway/platform \
        /etc/mosdns/rules/custom_direct.txt /etc/mosdns/rules/custom_hijack.txt 2>/dev/null; }
UD_BEFORE="$(_ud)"
cp /etc/mosdns/config.yaml $E2E_TMP/mos-before.yaml

echo; echo "── 跑 $PREV 的 pdg update(目标: 本版) ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "update 返回 0(未回滚)" || bad "update rc=$rc: $(tail -6 <<<"$out")"
grep -qE '已更新|更新完成|升级完成' <<<"$out" \
  && ok "输出报出更新成功" || bad "没报成功: $(tail -4 <<<"$out")"
grep -qE '已回滚|回滚到' <<<"$out" \
  && bad "不该回滚却回滚了: $(tail -4 <<<"$out")" || ok "全程没有触发回滚"

echo; echo "── 升级后的现场 ──"
[[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == "$NEW_TAG" ]] \
  && ok "仓库切到了 $NEW_TAG" || bad "仓库停在 $(git -C "$REPO" describe --tags 2>/dev/null)"

# 本版新增/改动的模块必须就位 —— 缺了说明 migrate_deploy_botfiles 没自愈到
# shellcheck source=lib/modules.sh
source "$REPO/lib/modules.sh"
_miss=0; _diff=0; _n=0
while read -r src name _mode; do
  _n=$((_n+1))
  [[ -e "/opt/pdg-bot/$name" ]] || { _miss=$((_miss+1)); echo "       缺 $name"; continue; }
  cmp -s "$REPO/$src" "/opt/pdg-bot/$name" || { _diff=$((_diff+1)); echo "       内容不符 $name"; }
done < <(pdg_platform_modules "$PLAT")
{ [[ "$_miss" == 0 && "$_diff" == 0 ]]; } \
  && ok "本版全部 $_n 项受管模块就位且逐字节一致(旧脚本装新版, 靠 migrate 自愈)" \
  || bad "模块没装全: 缺 $_miss / 不符 $_diff"

# 本轮两处改动的实际落地(不是只看文件在不在)
grep -q 'rule_precedence_scan' /opt/pdg-bot/checks.py \
  && ok "新自检项 rule_precedence_scan 已随升级装上" || bad "checks.py 还是旧版"
grep -q '_wda_insert_idx' /opt/pdg-bot/bot.py \
  && ok "WDA 分流优先级修复已随升级装上" || bad "bot.py 还是旧版"
if [[ "$PLAT" == ios ]]; then
  { [[ -e /opt/pdg-bot/iosprofile.py && -e /opt/pdg-bot/iosstate.py ]]; } \
    && ok "5.4 描述文件生命周期模块(iosprofile/iosstate)已就位" \
    || bad "iOS 生命周期模块没装上"
fi

[[ "$(_ud)" == "$UD_BEFORE" ]] \
  && ok "用户数据与凭据逐字节不变(bot.env/profile.env/rulesets/platform/custom_*.txt)" \
  || { bad "升级改了用户数据"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }

# 受管渲染配置允许被迁移归一, 但**只准动受管旋钮**: 用户自己的上游/规则文件引用一个都不能掉。
# 这条不是"放宽", 是把判据放对地方 —— 逐字节比会把一次正常的低内存归一(cache 8192/2048)
# 判成数据损失, 而"只要没崩就算过"又会放过真把用户上游冲掉的迁移。
_lost=""
for _k in custom_direct.txt custom_hijack.txt geosite_cn.txt 'listen: "0.0.0.0:53"'; do
  grep -qF "$_k" $E2E_TMP/mos-before.yaml || continue
  grep -qF "$_k" /etc/mosdns/config.yaml || _lost="$_lost $_k"
done
[[ -z "$_lost" ]] \
  && ok "mosdns 受管配置: 用户上游/规则文件引用全部保留" \
  || bad "迁移把这些从 mosdns 配置里冲掉了:$_lost"
_changed=$(diff $E2E_TMP/mos-before.yaml /etc/mosdns/config.yaml | grep -cE '^[<>]')
if [[ "$_changed" == 0 ]]; then
  ok "mosdns 受管配置逐字节未变"
else
  # 变了就把变的行摆出来, 并且只接受已知的受管旋钮
  _unexpected=$(diff $E2E_TMP/mos-before.yaml /etc/mosdns/config.yaml | grep -E '^[<>]' \
                | grep -vE 'size: *[0-9]+' | head -5)
  [[ -z "$_unexpected" ]] \
    && ok "mosdns 受管配置只动了受管旋钮 cache size($(grep -oE 'size: *[0-9]+' $E2E_TMP/mos-before.yaml | head -1) → $(grep -oE 'size: *[0-9]+' /etc/mosdns/config.yaml | head -1)), 属既定迁移" \
    || bad "mosdns 配置里有受管旋钮之外的改动:
$_unexpected"
fi

out=$(bash /usr/local/bin/pdg doctor 2>&1)
grep -qE '🔴|❌' <<<"$out" && bad "doctor 有失败项: $(grep -E '🔴|❌' <<<"$out" | head -3)" \
  || ok "升级后 doctor 无失败项"

e2e_summary

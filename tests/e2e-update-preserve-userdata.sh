#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 更新对用户数据的保全: 成功路径不许动, 失败自动回滚必须原样还回来。
#
# 为什么要有这支: 6.2B 之后 __migrate 硬依赖 /opt/pdg-bot/dot-domain —— 它缺失时
# migrate_dotwitness 按契约 fail-closed(拼进配置的值不能靠猜), 于是**任何**丢了这个
# 文件的机器都会更新失败, 而失败又触发回滚。要是回滚也还不回来, 那台机器就再也更新
# 不了了。这条链上任何一环松掉都是 P0, 而它平时完全无声: 更新成功时看不见, 更新失败
# 时又被"失败"本身盖住。所以单独钉一支, 量的是**完整前后像**而不是"文件还在不在":
# 内容字节 + mode + uid + gid 全要对上 —— 权限被顺手改成 0644 一样是保全失败。
#
# 判据覆盖 PDG_USER_DATA 里所有登记项, 清单从产品自己的保全契约读, 不写死。
# 契约里新增一项而更新路径没跟上时, 这支会自己发现。
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
printf 'mihomo\n'  > /etc/privdns-gateway/backend
mkdir -p /var/lib/privdns-gateway
e2e_seed_cert || e2e_skip "无 openssl, 造不出占位证书"

. "$E2E_ROOT/lib/versions.sh"
# 播真钉死版, 不用 shell 桩: 桩自报版本是对的、内容是错的, 而 install.sh 的短路与
# doctor 的完整性判据现在都看内容(CI 33353591548 的五支红灯就是这么来的)。
e2e_seed_mihomo_bin || { echo "[FAIL] 播种钉定 mihomo 失败"; exit 1; }

# ── 真发布源(本地裸仓库), 与 e2e-update.sh 同形态 ────────────────────────────
REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-origin.git
rm -rf "$REPO/.git" "$ORIGIN"
git -C "$REPO" init -q -b main
e2e_guard_repo "$REPO" || exit 1
e2e_git "$REPO" config user.email t@t; e2e_git "$REPO" config user.name t
e2e_git "$REPO" config commit.gpgsign false
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm base >/dev/null 2>&1
e2e_git "$REPO" tag v9.9.8
echo "# NEWVERSION-MARKER" >> "$REPO/deploy/bot/checks.py"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm newver >/dev/null 2>&1
e2e_git "$REPO" tag v9.9.9
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d v9.9.9 >/dev/null
e2e_git "$REPO" checkout -q v9.9.8

# ── 前像: 逐项打上可辨识内容与**非默认 mode** ────────────────────────────────
# 非默认 mode 是故意的: 只比内容的话, "删掉再按默认权限重建"也能蒙混过关。
source "$E2E_ROOT/lib/preserve.sh"
declare -a ITEMS=()
while read -r p; do [[ -n "$p" ]] && ITEMS+=("$p"); done < <(pdg_user_data)
[[ ${#ITEMS[@]} -gt 0 ]] && ok "从保全契约读到 ${#ITEMS[@]} 项用户数据(未写死)" \
  || { bad "读不出 PDG_USER_DATA —— 判据失效"; e2e_summary; exit 1; }

declare -A WANT=()
seeded=0
for p in "${ITEMS[@]}"; do
  [[ -e "/$p" ]] || continue          # 本机形态下不存在的项不造, 只保全"真的在"的
  [[ -d "/$p" ]] && continue          # 目录项(nft-input.d)另论, 这支只管文件
  chmod 0640 "/$p" 2>/dev/null
  WANT["$p"]="$(sha256sum "/$p" | cut -d' ' -f1) $(stat -c '%a %u %g' "/$p")"
  seeded=$((seeded+1))
done
[[ "$seeded" -ge 3 ]] && ok "本机形态下有 $seeded 项用户数据在场, 全部记下前像(含 mode/uid/gid)" \
  || bad "只有 $seeded 项在场, 样本太小, 这支没有代表性"

# dot-domain 是 6.2B 的硬依赖, 单独确认它在样本里 —— 它不在就等于没测到要点
[[ -n "${WANT[opt/pdg-bot/dot-domain]:-}" ]] \
  && ok "dot-domain 在样本内(6.2B __migrate 的硬依赖)" \
  || bad "dot-domain 不在样本内 —— 夹具没造出已装好的机器, 这支测不到要点"

# 前后像逐项比对; 差异要点得出是哪一项、差在哪。
# 内容与属主要求**逐字节一致**; 权限只许收紧不许放宽 —— profile.env 存 PDG_RESCUE_BIND,
# install.sh 一贯按 0600 落盘, 更新时重写成 0600 是产品在收紧, 不是保全失败。反过来
# 把 0600 放成 0644 才是事故(密钥类文件权限被顺手放宽), 那必须红。收紧也要报出来,
# 不许无声发生。
verify(){
  local phase="$1" p want got broken=() tightened=()
  for p in "${!WANT[@]}"; do
    if [[ ! -e "/$p" ]]; then broken+=("$p:文件没了"); continue; fi
    got="$(sha256sum "/$p" | cut -d' ' -f1) $(stat -c '%a %u %g' "/$p")"
    want="${WANT[$p]}"
    [[ "$got" == "$want" ]] && continue
    local ws wm wu wg gs gm gu gg
    read -r ws wm wu wg <<<"$want"
    read -r gs gm gu gg <<<"$got"
    # 内容/属主任一不同 → 直接判死, 不给权限规则兜底的机会
    if [[ "$ws|$wu|$wg" != "$gs|$gu|$gg" ]]; then
      broken+=("$p:内容或属主变了 want=[$want] got=[$got]"); continue
    fi
    if (( (8#$gm & ~8#$wm) != 0 )); then
      broken+=("$p:权限被放宽 $wm → $gm")
    else
      tightened+=("$p:$wm→$gm")
    fi
  done
  if [[ ${#broken[@]} -eq 0 ]]; then
    ok "$phase: ${#WANT[@]} 项用户数据内容/属主逐字节一致, 权限无放宽"
    [[ ${#tightened[@]} -gt 0 ]] && printf '       (权限收紧: %s)\n' "${tightened[*]}"
  else
    bad "$phase: ${#broken[@]} 项未保全 → ${broken[0]}"
    [[ ${#broken[@]} -gt 1 ]] && printf '       还有: %s\n' "${broken[@]:1:2}"
  fi
  return 0
}

echo; echo "── 正对照: 更新成功也不许动用户数据 ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out"; } \
  && ok "update 走完成功路径(rc=0)" || bad "update 没成功 rc=$rc: $(tail -4 <<<"$out")"
grep -q 'NEWVERSION-MARKER' /opt/pdg-bot/checks.py \
  && ok "新版模块真的装上了(说明这次更新确实动了 /opt/pdg-bot)" \
  || bad "模块没换成新版, 那这次'没动用户数据'不算数"
verify "成功路径"

echo; echo "── 主判: 自检失败 → 自动回滚, 用户数据必须完好 ──"
e2e_git "$REPO" checkout -q v9.9.8
e2e_svc_fail mihomo                  # doctor 报 fail, 逼 cmd_update 走 cmd_rollback
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && ! grep -q '✅ 已更新' <<<"$out"; } \
  && ok "失败路径: 返回非 0 且不报成功" || bad "rc=$rc 却报了成功"
grep -qE '自检发现|回滚' <<<"$out" \
  && ok "输出说明了失败原因并声明回滚" || bad "没说回滚: $(tail -3 <<<"$out")"
verify "失败回滚后"
rm -f "$E2E_TMP/e2e-svc/mihomo.ac"

echo; echo "── 收口: 回滚后机器必须还能再更新一次 ──"
# 这条是本支存在的理由: 用户数据要是没还回来, __migrate 会因"域名缺失"再次 fail-closed,
# 机器从此卡死在"每次更新都失败"。所以光比前后像不够, 得真再走一次成功路径。
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out"; } \
  && ok "回滚后再次 update 仍能成功 —— 没有卡进'永远更新不了'" \
  || bad "回滚后再也更新不了 rc=$rc: $(grep -E '❌|失败' <<<"$out" | head -2)"

e2e_summary

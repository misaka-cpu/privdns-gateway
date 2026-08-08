#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: **v1.7.8 的更新器持着全局锁, 新版迁移在首次启用救援平面时被自己的锁挡死**。
#
# 真实用户现场(v1.7.8 → v1.8.0):
#     sudo pdg update
#     → 已切到发布 v1.8.0
#     刷新代码...
#       首次启用救援平面(默认开; 之后可 pdg rescue disable)…
#     迁移(__migrate)失败, 回滚到更新前快照…
#
# 调用链:
#   1. 旧版 cmd_update 里 `_lock` 做了 `exec 9>"$LOCK"` 并 `flock -n 9` —— 锁握在**这个**
#      open file description 上, 整个更新期间不放;
#   2. 装好新脚本后它跑 `bash /usr/local/bin/pdg __migrate`(子进程);
#   3. 新版 migrate_rescue_plane 走到首次启用/故障恢复 → _rescue_enable → _lock;
#   4. 子进程的 _lock 又做了一次 `exec 9>"$LOCK"` —— 这是**重新 open**, 得到一个新的 open
#      file description, 它并不持有那把锁;
#   5. `flock -n 9` 于是撞上父进程的锁, `_lock` 直接 `exit 1`(不是 return —— 所以
#      run_all_migrations 里的 `|| true` 一个字都拦不住, 整个 __migrate 进程当场没了);
#   6. cmd_update 收到非零, 回滚到更新前快照。用户看到的就是上面那五行。
#
# 为什么 `--dry-run` 复现不了: 它在取锁与迁移之前就 return 了, 根本不跑 __migrate。
#
# 这支测试必须用**真东西**, 否则它证明不了上面任何一步:
#   · 更新器是 v1.7.8 的真实代码(不是当前工作树 —— 那是"本版升本版"的空测试);
#   · 目标是当前工作树, 新 tag **只存在于合成 origin**, 逼 update 真去 fetch;
#   · 锁是真的 flock 与真的 /run 文件, 不打桩 —— 打了桩这条 bug 就消失了。
#
# 用法: PDG_RESCUE_CASE=<case> bash tests/e2e-rescue-migration-lock.sh
#       不给 case 就把五种救援状态逐个跑一遍(每个 case 一个干净沙箱)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

CASES="bind-set bind-auto enabled-broken disabled no-bind post-fault"

# ── 没指定 case: 逐个跑, 每个都是全新沙箱(状态绝不串场) ──────────────────────
if [[ -z "${PDG_RESCUE_CASE:-}" ]]; then
  _rc=0
  for _c in $CASES; do
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo "  救援状态: $_c   平台: ${PDG_E2E_PLATFORM:-android}"
    echo "════════════════════════════════════════════════════════════════"
    PDG_RESCUE_CASE="$_c" bash "${BASH_SOURCE[0]}" "$@" || _rc=1
  done
  echo
  [[ "$_rc" == 0 ]] && echo "══ 五种救援状态全部通过 ══" || echo "══ 有救援状态未通过 ══"
  exit "$_rc"
fi

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v git >/dev/null 2>&1 || e2e_skip "无 git"

CASE="${PDG_RESCUE_CASE}"
PREV="${PDG_PREV_TAG:-v1.7.8}"
NEW_TAG="${PDG_NEW_TAG:-v9.9.9}"
PLAT="${PDG_E2E_PLATFORM:-android}"
# 沙箱的来源段是 e2e-lib 的 E2E_CIDR(127.0.0.0/8) —— profile.env / mosdns / nft 三处都按它
# 渲染。这里**必须沿用它**: 自己另塞一个网段会让更新后的"内网卡段真源三处一致"自检当场判红,
# 于是每一格都因为夹具不一致而回滚, 看起来像产品坏了。
CIDR="127.0.0.0/8"
BINDADDR="127.0.0.9"

git -C "$E2E_ROOT" rev-parse -q --verify "$PREV^{commit}" >/dev/null \
  || e2e_skip "取不到 $PREV 的对象(浅克隆?), 本用例跳过"
# "本版升本版"是恒过的空测试, 而且恰恰在最需要它的那天失效。
_head_sha="$(git -C "$E2E_ROOT" rev-parse HEAD)"
_prev_sha="$(git -C "$E2E_ROOT" rev-parse "$PREV^{commit}")"
[[ "$_head_sha" != "$_prev_sha" ]] \
  || e2e_skip "$PREV 就指着 HEAD —— 那是从本版升到本版, 拒绝当成有效用例"

# /tmp **不在** overlay 里 —— 上一轮留下的假 systemd 状态($E2E_TMP/e2e-svc/*.fail 之类)会原样
# 带进这一轮: post-fault 那格把 pdg-bot 标成"起来就崩", 下一格就会莫名其妙地更新失败, 而
# 失败原因与被测对象毫无关系。每格进场先把这些清干净。
rm -rf $E2E_TMP/e2e-svc $E2E_TMP/e2e-nft-ruleset $E2E_TMP/e2e-calls.log $E2E_TMP/rml-*.log $E2E_TMP/mig9* 2>/dev/null || true
e2e_stub_system
# 共享桩(e2e-lib.sh)现在是**状态派生**的: -f 装载、list 回放、-j 由当前状态转成 JSON。
# 这里原本自带一份私有桩, 理由是共享桩没状态 —— 那个理由已经不成立了, 而且它不认 `-j`,
# 留着反而会盖住共享桩, 让更新后自检读不到内核。删掉, 只用共享的那一份。
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

# `ip -4 -o addr show scope global` 的桩: 救援平面靠它挑监听地址候选。沙箱里没有真网卡,
# 不桩的话"来源段内恰好一个本机地址"这条路径根本走不到, bind-auto 那格就成了空测试。
# 自己造的桩自己撤 —— 下一支进场那道兜底是保险, 不是分工(它连异常退出都要兜)。
_rml_drop_ip_stub(){ e2e_purge_shadow_stub ip || true; }
e2e_add_exit_hook _rml_drop_ip_stub

_stub_ip(){                      # $@ = 要出现在 scope global 里的地址(可为空)
  { echo '#!/bin/sh'
  echo "$E2E_STUB_MARK"   # 归属标记: 只有带这行的才会被 e2e_purge_shadow_stub 清掉
    echo 'if [ "$1" = "-4" ]; then'
    for a in "$@"; do echo "  echo '1: eth0    inet $a/16 brd 127.255.255.255 scope global eth0\\       valid_lft forever'"; done
    echo '  exit 0'
    echo 'fi'
    echo 'exit 0'
  } > /usr/local/bin/ip
  chmod 755 /usr/local/bin/ip
}

# ── 发布源: v1.7.8 的真代码 + 当前工作树 ────────────────────────────────────
REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-rml-origin.git
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
e2e_git "$REPO" commit -qm "$NEW_TAG(hotfix worktree)" >/dev/null 2>&1
e2e_git "$REPO" tag "$NEW_TAG"
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d "$NEW_TAG" >/dev/null      # 新 tag 只在 origin 上, 逼 update 真去 fetch
e2e_git "$REPO" checkout -q "$PREV"

# 机器上装的是 **v1.7.8** 的脚本与模块 —— 这才是存量用户的现场。
# 模块按 **v1.7.8 自己的清单**装, 不是 `deploy/bot/*.py` 一把梭: 救援平面的模块散在
# deploy/bot 与 deploy/rescue 两个目录(rescue.py / rescue_cred.py / breakglass.py 在后者),
# 只拷 deploy/bot 会得到一台"救援模块半残"的机器 —— 而 _rescue_enable 的第一道门就是
# 模块闭包完整性, 于是首次启用必然失败, 测出来的是夹具的病不是产品的病。
install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
rm -rf /opt/pdg-bot; mkdir -p /opt/pdg-bot
# lib/modules.sh 是 v1.7.x 才有的东西。更老的版本(v1.6.3 / v1.5.9)按目录铺文件, 这里就
# 照它们当年的做法铺 —— 硬要用新清单去装老版本, 得到的是一台现实中不存在的机器。
if [[ -f "$REPO/lib/modules.sh" ]] && grep -q 'pdg_platform_modules' "$REPO/lib/modules.sh"; then
  # shellcheck source=/dev/null
  . "$REPO/lib/modules.sh"
  while read -r _src _name _mode; do
    [[ -n "$_src" ]] || continue
    install -m"${_mode:-755}" "$REPO/$_src" "/opt/pdg-bot/$_name" 2>/dev/null || true
  done < <(pdg_platform_modules "$PLAT")
  _seed_how="按 $PREV 自己的模块清单"
else
  for _f in "$REPO"/deploy/bot/*.py "$REPO"/deploy/rescue/*.py; do
    [[ -e "$_f" ]] && install -m755 "$_f" /opt/pdg-bot/ 2>/dev/null || true
  done
  _seed_how="按 $PREV 当年的目录铺法(那时还没有模块清单)"
fi
[[ -f "$REPO/lib/rescue.sh" ]] && install -m644 "$REPO/lib/rescue.sh" /opt/pdg-bot/rescue.sh
install -m755 "$REPO/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py

# 救援平面是 v1.7.0 才有的。更老的机器上 /opt/pdg-bot/rescue.py 不存在, 而
# migrate_rescue_plane 的第一道守卫就是"运行模块还没装到位就下轮再说" —— 它排在
# migrate_deploy_botfiles **之前**, 所以这一轮更新只把模块补齐, 救援平面要等下一次更新才启用。
# 这是既定行为, 不是本次修复的回归; 夹具据此调整预期, 而不是假装它会启用。
RESCUE_CAPABLE=0
[[ -f /opt/pdg-bot/rescue.py ]] && RESCUE_CAPABLE=1
if (( RESCUE_CAPABLE == 1 )); then
  . "$REPO/lib/rescue.sh" 2>/dev/null || true
  _rmiss=""
  for _m in ${PDG_RESCUE_CLOSURE:-}; do [[ -f "/opt/pdg-bot/$_m" ]] || _rmiss="$_rmiss $_m"; done
  [[ -z "$_rmiss" ]] && ok "$PREV 的救援模块闭包已装齐($_seed_how, 现场与真机同形)" \
    || bad "救援模块缺:$_rmiss —— 夹具不真实, 后面的启用断言无效"
else
  ok "$PREV 早于救援平面(v1.7.0), 机器上没有 rescue.py —— 本轮只补模块, 启用留到下次更新"
fi

# 现场自证 —— 这四条不成立的话, 后面所有断言都在测别的东西
{ [[ "$(git -C "$REPO" describe --tags)" == "$PREV" ]]; } \
  && ok "机器停在 $PREV" || bad "机器停在 $(git -C "$REPO" describe --tags 2>/dev/null)"
[[ -z "$(git -C "$REPO" tag -l "$NEW_TAG")" ]] \
  && ok "新 tag $NEW_TAG 只在合成 origin 上(本地没有, update 必须真 fetch)" \
  || bad "$NEW_TAG 在本地仓库里, update 不用 fetch 就能拿到"
grep -q "^# PrivDNS Gateway" /usr/local/bin/pdg 2>/dev/null || true
cmp -s "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg \
  && ok "更新器就是 $PREV 那一份真脚本(逐字节)" || bad "/usr/local/bin/pdg 不是 $PREV 的脚本"
_upd_sha="$(git -C "$E2E_ROOT" rev-parse "$PREV^{commit}")"
[[ "$_upd_sha" != "$_head_sha" ]] \
  && ok "更新器($PREV=${_upd_sha:0:8})与目标(${_head_sha:0:8})不是同一提交" \
  || bad "本版升本版"

# ── 按 case 摆好救援平面的初始状态 ──────────────────────────────────────────
PROF=/etc/privdns-gateway/profile.env
_prof_set(){ grep -v "^$1=" "$PROF" > "$PROF.t" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >> "$PROF.t"; mv "$PROF.t" "$PROF"; }
_prof_del(){ grep -v "^$1=" "$PROF" > "$PROF.t" 2>/dev/null; mv "$PROF.t" "$PROF"; }
touch "$PROF"
_prof_set PDG_INTERNAL_CIDR "$CIDR"
_prof_del PDG_RESCUE_ENABLED
_prof_del PDG_RESCUE_BIND

EXPECT_ENABLE=0     # 本 case 是否应当走到"启用/恢复救援平面"
EXPECT_ON=0         # 升完之后救援平面是否应当处于启用态
# 老于 v1.7.0 的来源: 这一轮到不了启用那一步(见上), 预期整体降为"不启用"
case "$CASE" in
  bind-set)
    # 最贴近用户报障的那一格: 有合法 bind, 从未记录过启用意图 → 首次启用
    _stub_ip "$BINDADDR"
    _prof_set PDG_RESCUE_BIND "$BINDADDR"
    EXPECT_ENABLE=1; EXPECT_ON=1;;
  bind-auto)
    # 没写 bind, 但来源段内**恰好一个**本机地址 → 自动认定并落盘, 然后首次启用
    _stub_ip "$BINDADDR"
    EXPECT_ENABLE=1; EXPECT_ON=1;;
  enabled-broken)
    # 意图=启用, 但 socket 没起来 / 放行也没了 → 属于"服务崩了, 要救回来", 不是用户关的
    _stub_ip "$BINDADDR"
    _prof_set PDG_RESCUE_BIND "$BINDADDR"
    _prof_set PDG_RESCUE_ENABLED 1
    EXPECT_ENABLE=1; EXPECT_ON=1;;
  disabled)
    # 用户明确关过 —— 升级一个字都不许改
    _stub_ip "$BINDADDR"
    _prof_set PDG_RESCUE_BIND "$BINDADDR"
    _prof_set PDG_RESCUE_ENABLED 0
    EXPECT_ENABLE=0; EXPECT_ON=0;;
  no-bind)
    # 没有可用监听地址 —— 保守保持停用, 并说清怎么配
    _stub_ip
    EXPECT_ENABLE=0; EXPECT_ON=0;;
  post-fault)
    # 迁移**成功之后**才出故障 —— 更新必须精确回滚到更新前那个提交与那份快照, 而不是
    # 停在"迁移已经跑过、代码却是旧的"这种半路状态。
    #
    # 故障点必须挑一个**只在迁移之后**才被触碰的东西。`mihomo -t` 看着合适, 其实不行:
    # iOS 上 migrate_ios_gms_cleanup / migrate_drop_singbox 自己也会跑 `mihomo -t`, 桩一失败
    # 就在迁移当中先炸, 于是测出来的是"迁移失败回滚"而不是"更新后校验失败回滚" —— 两件事,
    # 断言会错档(这一版就是这么先红的)。改用 pdg-bot 起不来: 它在校验门的最后一段, 迁移
    # 全程不依赖它, 两个平台行为一致。
    _stub_ip "$BINDADDR"
    _prof_set PDG_RESCUE_BIND "$BINDADDR"
    printf 'PDG_BOT_TOKEN=x\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
    e2e_svc_crash pdg-bot          # restart 返回 0, 服务随即又变回 inactive
    EXPECT_ENABLE=0; EXPECT_ON=0;;
  *) echo "未知 case: $CASE"; exit 2;;
esac
if (( RESCUE_CAPABLE == 0 )); then EXPECT_ENABLE=0; EXPECT_ON=0; fi

# ── 升级前的现场底片 ────────────────────────────────────────────────────────
# 升级**前**的救援意图。判"有没有被升级重新开启"必须与它比 —— 拿一个常量比的话,
# enabled-broken 这种"进场就已经是 1"的格子会被误判成"升级把它打开了"。
INTENT_BEFORE="$(sed -n 's/^[[:space:]]*PDG_RESCUE_ENABLED=//p' "$PROF" | tail -1)"
_ud(){ sha256sum /etc/privdns-gateway/bot.env /etc/privdns-gateway/profile.env \
        /opt/pdg-bot/rulesets.json /etc/privdns-gateway/platform \
        /etc/mosdns/rules/custom_direct.txt /etc/mosdns/rules/custom_hijack.txt 2>/dev/null; }
UD_BEFORE="$(_ud)"
_rescue_fp(){ python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || echo "(无)"; }
# 三份凭据各自的摘要 —— 只看指纹不够: 换 token 不改指纹, 而 token 一换所有已登录会话立即失效。
# 路径从 lib/rescue.sh 读, 不在这里再写一遍。
. "$E2E_ROOT/lib/rescue.sh" 2>/dev/null || true
_rescue_dig(){ sha256sum "${PDG_RESCUE_TOKEN:-/nonexistent}" "${PDG_RESCUE_CERT:-/nonexistent}" \
                 "${PDG_RESCUE_KEY:-/nonexistent}" 2>/dev/null; }
_rescue_tok(){ sha256sum "${PDG_RESCUE_TOKEN:-/nonexistent}" 2>/dev/null | awk '{print $1}'; }
FP_BEFORE="$(_rescue_fp)"; TOK_BEFORE="$(_rescue_tok)"; DIG_BEFORE="$(_rescue_dig)"
NR_BEFORE="$(systemctl show -p NRestarts --value mosdns 2>/dev/null || echo 0)"
cp /etc/nftables.conf $E2E_TMP/nft-before.conf 2>/dev/null || true
# /tmp 不在 overlay 里, 宿主上本来就可能有别人留下的 pdg-* —— 残留判据只看**本轮新增的**,
# 否则这条恒红, 而恒红与恒绿一样没有信息量。
TMP_BEFORE="$(ls -d $E2E_TMP/pdg-* $E2E_TMP/pdgtx-* 2>/dev/null | sort)"
_pre_sha="$(git -C "$REPO" rev-parse HEAD)"     # 精确回滚目标: 更新前那个提交

echo
echo "── 跑 $PREV 的 pdg update(目标: 当前工作树) ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
printf '%s\n' "$out" > $E2E_TMP/rml-out.txt

_intent(){ sed -n 's/^[[:space:]]*PDG_RESCUE_ENABLED=//p' "$PROF" | tail -1; }

# ═══ 0f. post-fault: 迁移成功之后出故障 → 精确回滚 ══════════════════════════
if [[ "$CASE" == post-fault ]]; then
  [[ "$rc" != 0 ]] && ok "更新后校验失败 → update 返回非零(rc=$rc)" \
    || bad "校验失败却报成功(rc=0)"
  grep -q 'pdg-bot 更新后起不来' <<<"$out" \
    && ok "故障点如实点名(pdg-bot 更新后起不来)" || bad "没说清失败在哪: $(tail -4 <<<"$out")"
  grep -q '迁移(__migrate)失败' <<<"$out" \
    && bad "失败发生在迁移阶段, 这一格要验的是**迁移之后**的故障" \
    || ok "迁移这一步是过了的(故障确实发生在它之后)"
  grep -qE '✅ 已更新' <<<"$out" && bad "回滚了却打印了「✅ 已更新」" || ok "没有谎报更新成功"
  grep -qE '回滚到更新前快照|失败, 回滚|已回滚' <<<"$out" \
    && ok "触发了回滚(文案: $(grep -oE '[^ ]*回滚[^,。]*' <<<"$out" | head -1))" || bad "没有回滚"
  _now="$(git -C "$REPO" rev-parse HEAD)"
  [[ "$_now" == "$_pre_sha" ]] \
    && ok "仓库精确复位到更新前那个提交(${_now:0:8}), 而不是只回到旧 tag 附近" \
    || bad "复位到了 ${_now:0:8}, 期望 ${_pre_sha:0:8}"
  [[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == "$PREV" ]] \
    && ok "describe 回到 $PREV" || bad "describe=$(git -C "$REPO" describe --tags 2>/dev/null)"
  [[ "$(_intent)" == "$INTENT_BEFORE" ]] \
    && ok "回滚后救援意图与更新前一致('$INTENT_BEFORE')" \
    || bad "回滚后意图变了: '$INTENT_BEFORE' → '$(_intent)'"
  [[ "$(_ud)" == "$UD_BEFORE" ]] && ok "回滚后用户数据逐字节回到更新前" \
    || { bad "回滚后用户数据与更新前不一致"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }
  if [[ "$FP_BEFORE" != "(无)" ]]; then
    [[ "$(_rescue_fp)" == "$FP_BEFORE" ]] && ok "回滚后救援证书指纹不变" || bad "指纹变了"
  fi
  _held="$(fuser /run/privdns-gateway.lock 2>/dev/null | tr -d ' ')"
  [[ -z "$_held" ]] && ok "回滚后锁文件上没有残留持有者" || bad "还有进程持着锁: $_held"
  _new_tmp="$(comm -13 <(printf '%s\n' "$TMP_BEFORE") \
                       <(ls -d $E2E_TMP/pdg-* $E2E_TMP/pdgtx-* 2>/dev/null | sort) | grep -c . || true)"
  [[ "${_new_tmp:-0}" == 0 ]] && ok "回滚后没有新增临时目录残留" || bad "新增 $_new_tmp 个残留"
  e2e_summary
  exit $?
fi

# ═══ 1. 更新本身 ════════════════════════════════════════════════════════════
[[ "$rc" == 0 ]] && ok "update 返回 0" || bad "update rc=$rc: $(tail -8 <<<"$out")"
grep -qE '已回滚|回滚到更新前快照' <<<"$out" \
  && bad "触发了回滚: $(grep -nE '回滚' <<<"$out" | head -2)" \
  || ok "全程没有触发回滚"
grep -q '迁移(__migrate)失败' <<<"$out" \
  && bad "__migrate 失败(这正是要修的那条)" || ok "__migrate 没有失败"
# 注意: 不能靠 grep "已有 pdg 操作在运行" 来判锁冲突 —— migrate_rescue_plane 里那句
# `_rescue_enable >/dev/null 2>&1` 把它整个吞掉了, 那样写出来的断言恒绿, 等于没写。
# 真正的判据在下面"锁继承直证"一节: 现场造一个持锁的父进程, 让新脚本的 __migrate 真跑一次。
# "成功回滚"不算升级成功 —— 这条单独钉死, 免得哪天有人把回滚路径也算进绿色
{ [[ "$rc" == 0 ]] && ! grep -qE '回滚到更新前快照' <<<"$out"; } \
  && ok "没有把「成功回滚」当成升级成功" || bad "回滚了却被当成通过"

# ═══ 2. 最终 git 状态 ═══════════════════════════════════════════════════════
_desc="$(git -C "$REPO" describe --tags 2>/dev/null)"
_sha="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
[[ "$_desc" == "$NEW_TAG" ]] \
  && ok "仓库切到了 $NEW_TAG(${_sha:0:8})" || bad "仓库停在 $_desc(${_sha:0:8}) —— 说明回滚了"

# ═══ 3. 救援平面的最终状态 ══════════════════════════════════════════════════
_sock_unit=/etc/systemd/system/pdg-rescue.socket
if (( EXPECT_ENABLE == 1 )); then
  grep -qE '首次启用救援平面|救援平面意图为启用但当前没起来' <<<"$out" \
    && ok "确实走到了救援平面的启用/恢复分支(不是被跳过才变绿的)" \
    || bad "没走到启用/恢复分支: $(grep -n '救援' <<<"$out" | head -3)"
fi
if (( EXPECT_ON == 1 )); then
  [[ "$(_intent)" == 1 ]] && ok "profile.env 记下启用意图 PDG_RESCUE_ENABLED=1" \
    || bad "意图是 '$(_intent)', 期望 1"
  [[ -f "$_sock_unit" ]] && ok "pdg-rescue.socket unit 已落盘" || bad "socket unit 不在"
  systemctl is-enabled pdg-rescue.socket >/dev/null 2>&1 \
    && ok "pdg-rescue.socket 已 enable" || bad "socket 没 enable"
  grep -q "ListenStream=" "$_sock_unit" 2>/dev/null \
    && ok "监听配置已写入 unit($(sed -n 's/^ListenStream=//p' "$_sock_unit" | head -1))" \
    || bad "unit 里没有 ListenStream"
else
  [[ "$(_intent)" == "$INTENT_BEFORE" ]] \
    && ok "救援意图未被升级改动(升级前 '$INTENT_BEFORE' → 升级后 '$(_intent)')" \
    || bad "升级动了救援意图: '$INTENT_BEFORE' → '$(_intent)'"
  { [[ "$INTENT_BEFORE" == 1 ]] || [[ "$(_intent)" != 1 ]]; } \
    && ok "升级没有把停用的救援平面重新打开" \
    || bad "被升级重新开启了 —— 用户的停用意图被覆盖"
  [[ ! -f "$_sock_unit" ]] && ok "没有落下 socket unit" || bad "不该启用却装了 socket unit"
fi
case "$CASE" in
  bind-auto)
    # 只有救援迁移真的跑过, 才谈得上"自动认定并落盘"。老于 v1.7.0 的来源这一轮根本到不了
    # 那一步(见上), 这时去要求落盘就是在要求一件既定行为之外的事。
    if (( RESCUE_CAPABLE == 1 )); then
      grep -q "^PDG_RESCUE_BIND=$BINDADDR" "$PROF" \
        && ok "来源段内唯一本机地址被认定并落盘($BINDADDR)" \
        || bad "没有落盘 bind: $(grep PDG_RESCUE_BIND "$PROF" || echo 无)"
    else
      grep -q "^PDG_RESCUE_BIND=" "$PROF" \
        && bad "救援迁移这轮没跑, 却凭空写了 bind" \
        || ok "救援迁移这轮不跑, 也就没有去猜监听地址(留给下次更新)"
    fi;;
  disabled)
    grep -qE '首次启用救援平面' <<<"$out" \
      && bad "用户已明确停用, 却仍走了首次启用" || ok "尊重停用意图, 没走首次启用";;
  no-bind)
    if (( RESCUE_CAPABLE == 1 )); then
      grep -q '未配置监听地址' <<<"$out" \
        && ok "明确提示未配置监听地址" || bad "没给出原因: $(grep -n '救援' <<<"$out" | head -3)"
      grep -q 'pdg rescue bind' <<<"$out" \
        && ok "提示了怎么配(pdg rescue bind <IPv4>)" || bad "没告诉用户怎么配"
    else
      grep -q '未配置监听地址' <<<"$out" \
        && bad "救援迁移这轮不该跑, 却打印了监听地址提示" \
        || ok "救援迁移这轮不跑, 也就没有那条监听地址提示(留给下次更新)"
    fi;;
esac
# 老于 v1.7.0 的来源: 本轮的正事是**把救援模块补齐**, 好让下一次更新能启用。
# 这条要正着断言, 不能只靠"没报错"就当过 —— 模块没补上的话下次更新照样启用不了。
if (( RESCUE_CAPABLE == 0 )); then
  [[ -f /opt/pdg-bot/rescue.py ]] \
    && ok "本轮把 rescue.py 补到位了(下次更新即可启用救援平面)" \
    || bad "救援模块没补上 —— 下次更新照样启不了"
  [[ ! -f "$_sock_unit" ]] \
    && ok "本轮没有启用救援平面(既定行为: 模块刚补齐, 留到下轮)" \
    || bad "模块这轮才补齐, 却已经把救援平面开起来了"
fi

# ═══ 4. 用户数据与凭据 ══════════════════════════════════════════════════════
[[ "$(_ud)" == "$UD_BEFORE" ]] \
  && ok "用户数据逐字节不变(bot.env/rulesets/platform/custom_*.txt; profile.env 见下)" \
  || {
    # profile.env 会被救援迁移合法地写入 intent/bind, 其余项一个都不许动
    _diff="$(diff <(printf '%s\n' "$UD_BEFORE") <(_ud) | grep -c '^[<>]')"
    _only_prof="$(diff <(printf '%s\n' "$UD_BEFORE") <(_ud) | grep '^[<>]' \
                  | grep -vc 'profile.env')"
    [[ "$_only_prof" == 0 ]] \
      && ok "只有 profile.env 变了(救援意图/bind 落盘, 属既定迁移), 其余逐字节不变" \
      || { bad "升级改了用户数据"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }
  }
if [[ "$FP_BEFORE" != "(无)" ]]; then
  [[ "$(_rescue_fp)" == "$FP_BEFORE" ]] \
    && ok "救援证书指纹未被意外轮换" || bad "证书指纹变了: $FP_BEFORE → $(_rescue_fp)"
fi
if [[ -n "$TOK_BEFORE" ]]; then
  [[ "$(_rescue_tok)" == "$TOK_BEFORE" ]] \
    && ok "救援 token 未被意外轮换" || bad "token 被换了"
fi
if [[ -n "$DIG_BEFORE" ]]; then
  [[ "$(_rescue_dig)" == "$DIG_BEFORE" ]] \
    && ok "救援 token / 证书 / 私钥三份摘要全部不变" \
    || { bad "救援凭据被动了"; diff <(printf '%s\n' "$DIG_BEFORE") <(_rescue_dig); }
fi
# 残留: netns / veth / 后台探针 —— 这几样一旦漏掉, 下一次跑会拿到上一次的现场
_ns="$(ip netns list 2>/dev/null | grep -c 'pdg' || true)"
[[ "${_ns:-0}" == 0 ]] && ok "没有 pdg 相关 netns 残留" || bad "残留 netns: $(ip netns list|grep pdg|head -2)"
_veth="$(ip -o link show 2>/dev/null | grep -c 'pdg.*@' || true)"
[[ "${_veth:-0}" == 0 ]] && ok "没有 veth 残留" || bad "残留 veth $_veth 个"
# 用完整路径匹配 —— 只写 "rescue.py" 会把本脚本自己的命令行也算进去(它的路径里就有 rescue)
_probe="$(pgrep -fc '/opt/pdg-bot/(probe81|rescue)\.py' 2>/dev/null || true)"
[[ "${_probe:-0}" == 0 ]] && ok "没有后台探针进程残留" || bad "残留探针进程 $_probe 个"

# ═══ 5. 服务 / 防火墙 / 事务 / 残留 ═════════════════════════════════════════
for u in mosdns mihomo; do
  systemctl is-active "$u" >/dev/null 2>&1 && ok "$u active" || bad "$u 不是 active"
done
_nr="$(systemctl show -p NRestarts --value mosdns 2>/dev/null || echo 0)"
[[ "$_nr" == "$NR_BEFORE" || "$_nr" -le $((NR_BEFORE + 2)) ]] \
  && ok "mosdns NRestarts 无异常增长($NR_BEFORE → $_nr)" || bad "NRestarts 暴涨: $NR_BEFORE → $_nr"
nft -c -f /etc/nftables.conf >/dev/null 2>&1 \
  && ok "nft 磁盘配置通过 nft -c 校验" || bad "nft 磁盘配置不合法"
if (( EXPECT_ON == 1 )); then
  python3 - <<PY && ok "磁盘上的防火墙确实带着救援放行(与内核形态一致)" \
                 || bad "救援启用了但磁盘 nft 里没有放行"
import sys
sys.path.insert(0, "/opt/pdg-bot")
import rescue_const, rescue_nft
# 端口读常量, 不写字面量 —— lib/rescue.sh 是唯一事实源, 测试里再抄一份就是第二份
# (tests/test-rescue-constants.sh 专门盯这条, 抄了会当场红)。
txt = open("/etc/nftables.conf", encoding="utf-8", errors="surrogateescape").read()
sys.exit(0 if rescue_nft.has_rescue_rule(txt, rescue_const.port(), "$BINDADDR") else 1)
PY
else
  python3 - <<PY && bad "没启用救援却在防火墙里留了放行" \
                 || ok "没启用救援, 防火墙里也没有孤儿放行"
import sys
sys.path.insert(0, "/opt/pdg-bot")
import rescue_nft
txt = open("/etc/nftables.conf", encoding="utf-8", errors="surrogateescape").read()
sys.exit(0 if rescue_nft.count_rules(txt) else 1)
PY
fi
_pend="$(python3 /opt/pdg-bot/pdgtx.py list 2>/dev/null | grep -cE 'APPLYING|OBSERVING|ROLLING_BACK|ROLLBACK_FAILED' || true)"
[[ "${_pend:-0}" == 0 ]] && ok "没有未完成的配置事务" || bad "留下 $_pend 笔未完成事务"
_new_tmp="$(comm -13 <(printf '%s\n' "$TMP_BEFORE") \
                     <(ls -d $E2E_TMP/pdg-* $E2E_TMP/pdgtx-* 2>/dev/null | sort) | grep -c . || true)"
[[ "${_new_tmp:-0}" == 0 ]] && ok "本轮没有新增临时目录残留" \
  || bad "新增 $_new_tmp 个临时目录残留"
_held="$(fuser /run/privdns-gateway.lock 2>/dev/null | tr -d ' ')"
[[ -z "$_held" ]] && ok "锁文件上没有残留的持有进程" || bad "还有进程持着锁: $_held"

# ═══ 6. 锁继承直证 ══════════════════════════════════════════════════════════
# 上面那些断言看的是"结果对不对"。这一节直接把机制摆出来: 造一个真持锁的父进程, 让它像
# cmd_update 那样把 fd 9 传给子进程, 子进程跑**新脚本**的 __migrate。
#   · 修好之前: 子进程重新 open 锁文件 → 撞上父锁 → _lock exit 1 → rc 非 0;
#   · 修好之后: 子进程认出继承来的那把锁 → rc 0。
# 同时验反面: **没有**继承 fd 的第三方进程仍然必须被挡住(BUSY), 否则就是把并发保护拆了。
if [[ "$rc" == 0 ]]; then      # 只有升级成功时机器上才是新脚本, 否则这一节测的是旧脚本
  { printf 'CHILDLOG=%s/rml-child.log\n' "$E2E_TMP"    # 引号 heredoc 不展开, 路径走头行
    cat <<'PS'
set -u
exec 9>"${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
flock -n 9 || { echo "PARENT-LOCK-FAILED"; exit 9; }
bash /usr/local/bin/pdg __migrate >"$CHILDLOG" 2>&1
echo "CHILD-RC=$?"
PS
  } > $E2E_TMP/rml-parent.sh
  _p="$(bash $E2E_TMP/rml-parent.sh 2>&1)"
  _crc="${_p##*CHILD-RC=}"
  [[ "$_crc" == 0 ]] \
    && ok "父进程持锁时, 继承同一 fd 的 __migrate 跑通(rc=0)" \
    || bad "继承锁没被复用: __migrate rc=$_crc / $(tail -3 $E2E_TMP/rml-child.log)"
  grep -q '已有 pdg 操作在运行' $E2E_TMP/rml-child.log \
    && bad "子迁移仍报 BUSY —— 锁继承没生效" || ok "子迁移没有报 BUSY"

  # 反面: 另一个进程持锁, 独立跑 __migrate(不继承 fd)必须 BUSY。
  #
  # 持锁进程必须**能确定地松手**。原来写的是 `( … && sleep 6 ) & … kill $!`: kill 打在子 shell
  # 上, 那个 sleep 会活下来继续攥着 fd 9。本地跑不出问题 —— namespace 模式每个 case 都有一份
  # 新的 /run tmpfs; 但 CI 走容器模式, 六个 case **共用同一个 /run**, 于是这条泄漏的 sleep 把
  # 锁一直按到下一个 case, 下一格的 `pdg update` 当场 BUSY。改成盯标记文件: 删掉标记 = 松手,
  # wait 回来就一定放干净了(与 tests/test-lock-inherit.sh 同一套写法)。
  _LK="${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
  : > $E2E_TMP/rml-holding
  ( exec 9>"$_LK"; flock -n 9 || exit 1; : > $E2E_TMP/rml-held
    while [[ -e $E2E_TMP/rml-holding ]]; do sleep 0.05; done ) &
  _holder=$!
  for _i in $(seq 1 60); do [[ -e $E2E_TMP/rml-held ]] && break; sleep 0.05; done
  [[ -e $E2E_TMP/rml-held ]] && ok "前置: 第三方确实按住了锁" || bad "造不出'第三方持锁'的现场"
  _o=$(setsid bash -c 'exec 9<&-; bash /usr/local/bin/pdg __migrate' 2>&1); _orc=$?
  rm -f $E2E_TMP/rml-holding; wait "$_holder" 2>/dev/null; rm -f $E2E_TMP/rml-held
  # 松手之后锁必须真的可再取 —— 这一条就是上面那个泄漏的直接探针
  ( exec 9>"$_LK"; flock -n 9 ) \
    && ok "探针收尾后锁已彻底释放(没有留下攥着 fd 的后台进程)" \
    || bad "锁没被放干净 —— 下一个用例会被它挡住"
  { [[ "$_orc" != 0 ]] && grep -q '已有 pdg 操作在运行' <<<"$_o"; } \
    && ok "别的进程持锁时, 独立 __migrate 仍被挡住并报 BUSY(并发保护没被拆掉)" \
    || bad "独立 __migrate 竟然拿到了锁(rc=$_orc): $(tail -3 <<<"$_o")"
fi

e2e_summary

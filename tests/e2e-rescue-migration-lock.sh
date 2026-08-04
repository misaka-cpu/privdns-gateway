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

CASES="bind-set bind-auto enabled-broken disabled no-bind"

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

e2e_stub_system
# e2e_stub_system 的 nft 桩对什么都回 0 且不留状态 —— 而救援放行的收尾判据是"磁盘与内核都
# **恰好一条**", 无状态的桩会让内核侧永远数出 0, 于是启用必然自我回滚, 测出来的是桩的病。
# 换成有状态的那一版(与 e2e-custom-nft.sh 同形): -f 装载写进状态文件, list 读回来。
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
STATE=/tmp/e2e-nft-ruleset
echo "nft $*" >> /tmp/e2e-calls.log
case "$1" in
  -c) exit 0 ;;
  -f) [ -f "$2" ] && cat "$2" > "$STATE"; exit 0 ;;
  # 真 nft 打印的是**内核里的规则**, 不会把配置文件里的注释原样吐回来。桩必须照做:
  # 生产模板里有一行 `# 你自己的放行规则放这里(… 如 \`tcp dport 80 accept\`)`, 原样回显
  # 会让 doctor 的文本判据把这句说明当成"80 对全网开放"而判红 —— 那是桩不像真的, 不是
  # 防火墙有问题。(顺带记一笔: 这也说明按文本认规则本身就脆, 见报告 P2。)
  list) sed -e 's/#.*$//' "$STATE" 2>/dev/null | grep -v '^[[:space:]]*$'; exit 0 ;;
  delete) exit 0 ;;
esac
exit 0
S
chmod 755 /usr/local/bin/nft
: > /tmp/e2e-nft-ruleset
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft mihomo
cp /etc/nftables.conf /tmp/e2e-nft-ruleset      # 磁盘与"内核"起点一致
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
_stub_ip(){                      # $@ = 要出现在 scope global 里的地址(可为空)
  { echo '#!/bin/sh'
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
ORIGIN=/tmp/e2e-rml-origin.git
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
# shellcheck source=/dev/null
. "$REPO/lib/modules.sh"
while read -r _src _name _mode; do
  [[ -n "$_src" ]] || continue
  install -m"${_mode:-755}" "$REPO/$_src" "/opt/pdg-bot/$_name" 2>/dev/null || true
done < <(pdg_platform_modules "$PLAT")
[[ -f "$REPO/lib/rescue.sh" ]] && install -m644 "$REPO/lib/rescue.sh" /opt/pdg-bot/rescue.sh
install -m755 "$REPO/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
# 夹具自证: 救援闭包真的齐了。缺一个的话下面"首次启用"那格测的就不是锁, 而是缺模块。
. "$REPO/lib/rescue.sh" 2>/dev/null || true
_rmiss=""
for _m in ${PDG_RESCUE_CLOSURE:-}; do [[ -f "/opt/pdg-bot/$_m" ]] || _rmiss="$_rmiss $_m"; done
[[ -z "$_rmiss" ]] && ok "$PREV 的救援模块闭包已按其清单装齐(现场与真机同形)" \
  || bad "救援模块缺:$_rmiss —— 夹具不真实, 后面的启用断言无效"

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
  *) echo "未知 case: $CASE"; exit 2;;
esac

# ── 升级前的现场底片 ────────────────────────────────────────────────────────
_ud(){ sha256sum /etc/privdns-gateway/bot.env /etc/privdns-gateway/profile.env \
        /opt/pdg-bot/rulesets.json /etc/privdns-gateway/platform \
        /etc/mosdns/rules/custom_direct.txt /etc/mosdns/rules/custom_hijack.txt 2>/dev/null; }
UD_BEFORE="$(_ud)"
_rescue_fp(){ python3 /opt/pdg-bot/rescue_cred.py fingerprint 2>/dev/null || echo "(无)"; }
_rescue_tok(){ sha256sum /etc/privdns-gateway/rescue/token 2>/dev/null | awk '{print $1}'; }
FP_BEFORE="$(_rescue_fp)"; TOK_BEFORE="$(_rescue_tok)"
NR_BEFORE="$(systemctl show -p NRestarts --value mosdns 2>/dev/null || echo 0)"
cp /etc/nftables.conf /tmp/nft-before.conf 2>/dev/null || true
# /tmp 不在 overlay 里, 宿主上本来就可能有别人留下的 pdg-* —— 残留判据只看**本轮新增的**,
# 否则这条恒红, 而恒红与恒绿一样没有信息量。
TMP_BEFORE="$(ls -d /tmp/pdg-* /tmp/pdgtx-* 2>/dev/null | sort)"

echo
echo "── 跑 $PREV 的 pdg update(目标: 当前工作树) ──"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
printf '%s\n' "$out" > /tmp/rml-out.txt

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
_intent(){ sed -n 's/^[[:space:]]*PDG_RESCUE_ENABLED=//p' "$PROF" | tail -1; }
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
  [[ "$(_intent)" != 1 ]] && ok "救援平面保持停用(意图 '$(_intent)')" \
    || bad "被升级重新开启了 —— 用户的停用意图被覆盖"
  [[ ! -f "$_sock_unit" ]] && ok "没有落下 socket unit" || bad "不该启用却装了 socket unit"
fi
case "$CASE" in
  bind-auto)
    grep -q "^PDG_RESCUE_BIND=$BINDADDR" "$PROF" \
      && ok "来源段内唯一本机地址被认定并落盘($BINDADDR)" \
      || bad "没有落盘 bind: $(grep PDG_RESCUE_BIND "$PROF" || echo 无)";;
  disabled)
    grep -qE '首次启用救援平面' <<<"$out" \
      && bad "用户已明确停用, 却仍走了首次启用" || ok "尊重停用意图, 没走首次启用";;
  no-bind)
    grep -q '未配置监听地址' <<<"$out" \
      && ok "明确提示未配置监听地址" || bad "没给出原因: $(grep -n '救援' <<<"$out" | head -3)"
    grep -q 'pdg rescue bind' <<<"$out" \
      && ok "提示了怎么配(pdg rescue bind <IPv4>)" || bad "没告诉用户怎么配";;
esac

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
import rescue_nft
txt = open("/etc/nftables.conf", encoding="utf-8", errors="surrogateescape").read()
sys.exit(0 if rescue_nft.has_rescue_rule(txt, 8446, "$BINDADDR") else 1)
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
                     <(ls -d /tmp/pdg-* /tmp/pdgtx-* 2>/dev/null | sort) | grep -c . || true)"
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
  cat > /tmp/rml-parent.sh <<'PS'
set -u
exec 9>"${PDG_LOCKFILE:-/run/privdns-gateway.lock}"
flock -n 9 || { echo "PARENT-LOCK-FAILED"; exit 9; }
bash /usr/local/bin/pdg __migrate >/tmp/rml-child.log 2>&1
echo "CHILD-RC=$?"
PS
  _p="$(bash /tmp/rml-parent.sh 2>&1)"
  _crc="${_p##*CHILD-RC=}"
  [[ "$_crc" == 0 ]] \
    && ok "父进程持锁时, 继承同一 fd 的 __migrate 跑通(rc=0)" \
    || bad "继承锁没被复用: __migrate rc=$_crc / $(tail -3 /tmp/rml-child.log)"
  grep -q '已有 pdg 操作在运行' /tmp/rml-child.log \
    && bad "子迁移仍报 BUSY —— 锁继承没生效" || ok "子迁移没有报 BUSY"

  # 反面: 另一个进程持锁, 独立跑 __migrate(不继承 fd)必须 BUSY
  ( exec 9>"${PDG_LOCKFILE:-/run/privdns-gateway.lock}"; flock -n 9 && sleep 6 ) &
  _holder=$!; sleep 0.5
  _o=$(setsid bash -c 'exec 9<&-; bash /usr/local/bin/pdg __migrate' 2>&1); _orc=$?
  kill "$_holder" 2>/dev/null; wait "$_holder" 2>/dev/null
  { [[ "$_orc" != 0 ]] && grep -q '已有 pdg 操作在运行' <<<"$_o"; } \
    && ok "别的进程持锁时, 独立 __migrate 仍被挡住并报 BUSY(并发保护没被拆掉)" \
    || bad "独立 __migrate 竟然拿到了锁(rc=$_orc): $(tail -3 <<<"$_o")"
fi

e2e_summary

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

# ── 三个对象的身份基准 ───────────────────────────────────────────────────────
# 版本身份一律以**真实文件的内容摘要**为准, 符号计数只作辅助说明。
# 这几份基准在**任何沙箱重置之前**从 $E2E_ROOT(只读)取出来, 放在 $E2E_TMP 里,
# e2e_reset_box 不碰 $E2E_TMP 里这几个名字, 所以两条路径用的是同一批基准。
BRIDGE_SHA="${PDG_BRIDGE_SHA:-9c9b2681f3ada2155b32ebe372cbc2a154792079}"
BRIDGE_TAG="${PDG_BRIDGE_TAG:-v9.9.8}"
CAND_SHA="$(git -C "$E2E_ROOT" rev-parse -q --verify 'HEAD^{commit}')" || CAND_SHA=""
PREV_SHA="$(git -C "$E2E_ROOT" rev-parse -q --verify "$PREV^{commit}")" || PREV_SHA=""
[[ -n "$CAND_SHA" && -n "$PREV_SHA" ]] || e2e_skip "读不回 HEAD / $PREV 的提交对象"
git -C "$E2E_ROOT" cat-file -e "$BRIDGE_SHA^{commit}" 2>/dev/null \
  || e2e_skip "取不到冻结桥接对象 $BRIDGE_SHA(浅克隆?) —— 不换对象冒充, 本用例停在这里"
{ git -C "$E2E_ROOT" merge-base --is-ancestor "$PREV_SHA" "$BRIDGE_SHA" \
  && git -C "$E2E_ROOT" merge-base --is-ancestor "$BRIDGE_SHA" "$CAND_SHA"; } \
  && ok "祖先关系成立: $PREV(${PREV_SHA:0:12}) → 桥接(${BRIDGE_SHA:0:12}) → 本版(${CAND_SHA:0:12})" \
  || { bad "祖先关系不成立: 桥接对象不在 $PREV 与本版之间, 两跳升级没有可验的基础"; e2e_summary; exit 1; }

REF=$E2E_TMP/ref
rm -rf "$REF"; mkdir -p "$REF"
_refdump(){   # $1=提交 $2=落点名 → 取出 pdg.sh 与模块清单
  local c="$1" n="$2"
  mkdir -p "$REF/$n"
  git -C "$E2E_ROOT" show "$c:deploy/bot/pdg.sh" > "$REF/$n/pdg.sh" 2>/dev/null || return 1
  [[ -s "$REF/$n/pdg.sh" ]] || return 1
  # 模块清单用**那一个对象自己的** lib/modules.sh 现算, 不拿本版的清单去量旧对象。
  git -C "$E2E_ROOT" show "$c:lib/modules.sh" > "$REF/$n/modules.sh" 2>/dev/null || return 1
  ( set -u
    # shellcheck source=/dev/null
    . "$REF/$n/modules.sh" 2>/dev/null || exit 1
    pdg_platform_modules "$PLAT" ) > "$REF/$n/modlist.txt" 2>/dev/null || return 1
  [[ -s "$REF/$n/modlist.txt" ]] || return 1
  return 0
}
for _p in "$PREV_SHA:prev" "$BRIDGE_SHA:bridge" "$CAND_SHA:cand"; do
  _refdump "${_p%%:*}" "${_p##*:}" \
    || { bad "取不到 ${_p##*:} 对象的 pdg.sh / 模块清单 —— 身份基准立不住"; e2e_summary; exit 1; }
done
ok "身份基准就位: prev/bridge/cand 三份 pdg.sh 与模块清单都取到了(分别 $(wc -l < "$REF/prev/modlist.txt")/$(wc -l < "$REF/bridge/modlist.txt")/$(wc -l < "$REF/cand/modlist.txt") 项)"
REF_PREV_SHA256="$(sha256sum "$REF/prev/pdg.sh"   | cut -d' ' -f1)"
REF_BRDG_SHA256="$(sha256sum "$REF/bridge/pdg.sh" | cut -d' ' -f1)"
REF_CAND_SHA256="$(sha256sum "$REF/cand/pdg.sh"   | cut -d' ' -f1)"

# 受管仓库的"母版": 只从 $E2E_ROOT 拷一次, 之后每条路径都从它克隆 —— $E2E_ROOT 始终只读。
PRISTINE=$E2E_TMP/pristine.git
rm -rf "$PRISTINE"
git clone -q --bare --no-hardlinks "$E2E_ROOT" "$PRISTINE" \
  || { bad "做不出受管仓库母版"; e2e_summary; exit 1; }

# profile.env 的受管键白名单: **从产品源码现查**, 不手写。
# 产品只经 _profile_set 这一个原子 upsert 写 profile.env(它自己会把重复同名键规范成一个),
# 所以"本版可能新增哪些键"就等于源码里 _profile_set 的键集合。
mapfile -t _PROF_OK < <(grep -oE '_profile_set +[A-Z_][A-Z0-9_]*' "$REF/cand/pdg.sh" \
                        | awk '{print $2}' | sort -u)
(( ${#_PROF_OK[@]} > 0 )) \
  && ok "profile.env 受管键白名单从本版源码现查到 ${#_PROF_OK[@]} 个: ${_PROF_OK[*]}" \
  || { bad "从源码查不到任何 _profile_set 键 —— 白名单立不住, 不手写补"; e2e_summary; exit 1; }

REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-upg-origin.git
UD_BEFORE=""; PROFILE_BEFORE=""

# 身份查询就地做退出码检查: `grep -c` 的 0 / 1(**正常零匹配**) / >=2(读取或执行错误)要分开。
# 出错那一档它照样会先打印一个 "0" —— 消费它就等于把"查不了"读成"查到了 0 个"。
u_count(){   # $1=具名前缀 $2=正则 $3=文件 → 设 U_CNT; 0=查得成
  local tag="$1" re="$2" f="$3" v rc=0
  U_CNT=""
  v="$(grep -c "$re" "$f" 2>/dev/null)" || rc=$?
  if (( rc >= 2 )); then
    bad "$tag **观测无效** —— 查 $f 失败(grep 退出 $rc), 它已经吐出的「$v」一律不采信"
    return 1
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || { bad "$tag **观测无效** —— 查询结果不是数字($(printf '%q' "$v"))"; return 1; }
  U_CNT="$v"; return 0
}

# 现役 CLI 的**精确身份**: 与基准文件逐字节比, 不看符号数。
u_cli_is(){   # $1=具名前缀 $2=基准名(prev/bridge/cand) $3=该基准的 sha256 → 0=就是它
  local tag="$1" who="$2" want="$3" got rc=0
  [[ -f /usr/local/bin/pdg ]] || { bad "$tag **身份不明** —— /usr/local/bin/pdg 不是普通文件"; return 1; }
  got="$(sha256sum /usr/local/bin/pdg 2>/dev/null | cut -d' ' -f1)" || rc=$?
  if (( rc != 0 )) || [[ ! "$got" =~ ^[0-9a-f]{64}$ ]]; then
    bad "$tag **观测无效** —— 读不出现役 CLI 的摘要(rc=$rc, 得到 $(printf '%q' "${got:-空}"))"
    return 1
  fi
  U_CLI_SHA="$got"
  [[ "$got" == "$want" ]] && return 0
  bad "$tag CLI 身份不符: 现役 ${got:0:16}… ≠ $who 基准 ${want:0:16}…"
  return 1
}

# 受管模块的**完整身份**: 按某个对象自己的清单逐项比。清单读不出来或是空集合,
# 一律算**观测无效**, 不许当成"全部一致"。
u_mods_are(){   # $1=具名前缀 $2=基准名 → 0=清单里每一项都在且逐字节一致
  local tag="$1" who="$2" lst="$REF/$2/modlist.txt" n=0 miss=0 diff=0 src name mode rc=0
  local -a rows=()
  [[ -s "$lst" ]] || { bad "$tag **观测无效** —— $who 的模块清单读不出或是空的"; return 1; }
  mapfile -t rows < "$lst" || { bad "$tag **观测无效** —— 读 $who 模块清单失败"; return 1; }
  (( ${#rows[@]} > 0 )) || { bad "$tag **观测无效** —— $who 模块清单是空集合"; return 1; }
  for _r in "${rows[@]}"; do
    [[ -n "$_r" ]] || continue
    read -r src name mode <<< "$_r"; : "$mode"
    [[ -n "$src" && -n "$name" ]] || continue
    n=$((n+1))
    if [[ ! -e "/opt/pdg-bot/$name" ]]; then miss=$((miss+1)); continue; fi
    git -C "$E2E_ROOT" show "$(_refcommit "$who"):$src" > "$E2E_TMP/.modref" 2>/dev/null || { rc=1; continue; }
    cmp -s "$E2E_TMP/.modref" "/opt/pdg-bot/$name" || diff=$((diff+1))
  done
  rm -f "$E2E_TMP/.modref"
  (( n > 0 )) || { bad "$tag **观测无效** —— $who 清单里一条可用记录都没有"; return 1; }
  (( rc == 0 )) || { bad "$tag **观测无效** —— 从 $who 对象取模块原文失败, 本次比对不作数"; return 1; }
  U_MOD_N="$n"; U_MOD_MISS="$miss"; U_MOD_DIFF="$diff"
  (( miss == 0 && diff == 0 ))
}
_refcommit(){ case "$1" in prev) echo "$PREV_SHA";; bridge) echo "$BRIDGE_SHA";; cand) echo "$CAND_SHA";; *) echo "";; esac; }

# profile.env: 允许**有源码依据**的受管新增键, 但
#   · 升级前就有的键, 有效值必须不变(有效值 = 去前导空白后第一条 key= 行, 与 _profile_set 同语义);
#   · 不许出现重复同名键(产品的 upsert 会把重复规范成一个, 出现重复说明有人用别的方式追加);
#   · 新增键必须落在从源码现查出来的白名单里。
# 三条里任何一条不成立都是**失败**, 不降级成记录。
u_profile_ok(){   # $1=具名前缀 → 0=通过
  local tag="$1" f=/etc/privdns-gateway/profile.env now rc=0 k v0 v1 bad_list="" add_list="" dup_list="" gone_list=""
  now="$(cat "$f")" || rc=$?
  (( rc == 0 )) || { bad "$tag **观测无效** —— 读不出 profile.env(cat 退出 $rc)"; return 1; }
  _eff(){ sed -n "s/^[[:space:]]*$1=//p" <<<"$2" | head -1; }
  _keys(){ sed -n 's/^[[:space:]]*\([A-Z_][A-Z0-9_]*\)=.*/\1/p' <<<"$1"; }
  # ① 重复同名键
  while read -r k; do
    [[ -n "$k" ]] || continue
    (( $(grep -c "^[[:space:]]*$k=" <<<"$now") > 1 )) && dup_list="$dup_list $k"
  done < <(_keys "$now" | sort -u)
  # ② 原有键: **先判还在不在, 再判值**。
  #    合在一起判会漏掉一种: 原来就是空值的键被整条删掉时, 两边取出来都是空串,
  #    "值没变"于是成立 —— 而那个键其实已经没了。
  local gone_list=""
  while read -r k; do
    [[ -n "$k" ]] || continue
    if ! grep -q "^[[:space:]]*$k=" <<<"$now"; then
      gone_list="$gone_list $k"; continue
    fi
    v0="$(_eff "$k" "$PROFILE_BEFORE")"; v1="$(_eff "$k" "$now")"
    [[ "$v0" == "$v1" ]] || bad_list="$bad_list $k(${v0:-<空>}→${v1:-<空>})"
  done < <(_keys "$PROFILE_BEFORE" | sort -u)
  # ③ 新增键必须在源码白名单里
  while read -r k; do
    [[ -n "$k" ]] || continue
    grep -qx "$k" <<<"$(_keys "$PROFILE_BEFORE")" && continue
    printf '%s\n' "${_PROF_OK[@]}" | grep -qx "$k" || add_list="$add_list $k"
  done < <(_keys "$now" | sort -u)
  local why=""
  [[ -n "$dup_list" ]] && why="$why 重复同名键:$dup_list;"
  [[ -n "$gone_list" ]] && why="$why 原有键被删掉:$gone_list;"
  [[ -n "$bad_list" ]] && why="$why 原有键的有效值被改:$bad_list;"
  [[ -n "$add_list" ]] && why="$why 新增了源码里没有依据的键:$add_list;"
  if [[ -z "$why" ]]; then
    ok "$tag profile.env: 原有键有效值全不变、无重复同名键、新增键都有源码依据$(
        diff <(printf '%s\n' "$PROFILE_BEFORE") "$f" | grep '^>' | tr '\n' ' ' | sed 's/^/ (本次新增:/; s/ $/)/')"
    return 0
  fi
  bad "$tag profile.env 判为不合格:$why"
  return 1
}

# ── 每条路径各自从**同一旧版基线**出发 ───────────────────────────────────────
# 只重置仓库/CLI/Bot 目录是不够的: A 跑完之后 /etc/privdns-gateway、/etc/mosdns、服务状态
# 都已经被一次真实的 update→rollback 动过。这里直接用夹具既有的**整箱重置** e2e_reset_box,
# 把 /etc/privdns-gateway、/etc/mosdns、/etc/mihomo、/etc/sing-box、/opt/pdg-bot、
# /opt/privdns-gateway、/var/lib/privdns-gateway、各 unit 与桩状态**整套**清掉, 再重新播一遍。
_ud(){ sha256sum /etc/privdns-gateway/bot.env \
        /opt/pdg-bot/rulesets.json /etc/privdns-gateway/platform \
        /etc/mosdns/rules/custom_direct.txt /etc/mosdns/rules/custom_hijack.txt 2>/dev/null; }
# 一次服务状态查询: **不走管道**, stdout / stderr / rc 各自留下。
#
# 为什么不走管道: 本脚本开头是 `set -uo pipefail`, 所以 `a | head -1` 之后的 $? **会**是
# 上游那个非零码(pipefail 就是干这个的) —— 早先说它"恒为 head 的 0"是错的。真正的毛病是
# 那个码取到了却被 `: "$_rc"` 丢掉, 而 is-enabled 连取都没取。不走管道只是把"取码"这件事
# 变得不依赖 pipefail 是否开着, 顺手也能把 stderr 单独留下来。
#
# 配对表按**本项目支持的系统**(README: Debian 12+ / Ubuntu 22+)上的 systemd 现读核定,
# 取值集来自 `systemctl --state=help`, 退出码来自 systemctl(1) 的 is-enabled 表与实测:
#   is-active  取值: active reloading inactive failed activating deactivating maintenance
#              退出码: 属于 ACTIVE 一族(active / reloading)→ 0; 其余 → 非零(实测 inactive=3)
#   is-enabled 取值: enabled enabled-runtime linked linked-runtime alias masked
#              masked-runtime static disabled indirect generated transient bad
#              退出码按**这台机器上的 systemctl 二进制实测**核定(离线 --root 查询, 没碰活的
#              systemd): enabled / enabled-runtime / alias / static / indirect / generated → 0;
#              linked / linked-runtime / masked / masked-runtime / disabled / transient → **1**。
#              is-active 那边实测: 不活动一族(failed / inactive, 含查不到的 unit)一律 → **3**。
#              两边都按**各自的正常码**判, 不用"任意非零" —— inactive/7、disabled/7 这种
#              组合说明这次查询另有岔子, 半截输出一样不采信。
#              本机没有处于 activating / deactivating / reloading / maintenance 的 unit,
#              这四个词按同一条规则归类(活动一族→0, 其余→3), 未能逐个直接实测, 如实登记。
#              注意 transient: systemctl(1) 的表把它写成 0, 而**二进制实测是 1** ——
#              以实测为准(证据见 241/242 号的离线探针输出)。bad 这一格 man 自己说明
#              is-enabled 不会返回它(改为直接报错), 所以它只可能配非零。
#   "不存在"与"查询失败"按真实语义各自成立, 不另加模糊兜底:
#     · is-active  查不存在的 unit → 打印 inactive、退出 3(systemd 自己就把它当 inactive);
#     · is-enabled 查不存在的 unit → **stdout 是空的**、退出非零、stderr 说 Failed to get
#       unit file state —— 空输出不是状态词, 这一格如实判"没采到"。
_svc_sample(){   # $1=具名前缀 $2=is-active|is-enabled $3=unit → 设 Q_OUT/Q_RC; 0=合法
  local tag="$1" sub="$2" u="$3" errf="$E2E_TMP/.svcq.err" rc=0 raw
  Q_OUT=""; Q_RC=""
  : > "$errf"
  raw="$(systemctl "$sub" "$u" 2>"$errf")" || rc=$?
  Q_RC="$rc"; Q_OUT="${raw%%$'\n'*}"
  local okpair=0
  case "$sub" in
    is-active)
      # 否定一族只认该子命令**自己的正常码 3** —— 不是"任意非零"。
      # 词表里有这个词, 不等于它配任何退出码都算正常答案: inactive/7 说明这次查询出了别的岔子,
      # 那半截输出不能采信。
      if   [[ "$Q_OUT" =~ ^(active|reloading)$ ]] && (( rc == 0 )); then okpair=1
      elif [[ "$Q_OUT" =~ ^(inactive|failed|activating|deactivating|maintenance)$ ]] && (( rc == 3 )); then okpair=1
      fi;;
    is-enabled)
      # 同理, 否定一族只认 1(实测: disabled / linked / linked-runtime / masked /
      # masked-runtime / transient 全是 1), disabled/7 一样要拒。
      if   [[ "$Q_OUT" =~ ^(enabled|enabled-runtime|alias|static|indirect|generated)$ ]] && (( rc == 0 )); then okpair=1
      elif [[ "$Q_OUT" =~ ^(linked|linked-runtime|masked|masked-runtime|disabled|transient|bad)$ ]] && (( rc == 1 )); then okpair=1
      fi;;
  esac
  (( okpair == 1 )) && return 0
  bad "$tag **观测无效** —— $u 的 $sub 回答不成对(状态词 $(printf '%q' "${Q_OUT:-空}") / 退出码 $rc; stderr: $(head -1 "$errf")) —— 已经打出来的那半截一律不采信"
  Q_OUT=""; return 1
}

seed_release_box(){   # $1=具名前缀 → 0=前像成立; 设 UD_BEFORE / PROFILE_BEFORE
  local tag="$1" f
  e2e_reset_box
  e2e_stub_system
  e2e_seed_install    >/dev/null 2>&1 || { bad "$tag 装机失败"; return 1; }
  e2e_seed_mosdns all
  e2e_seed_singbox_model
  e2e_seed_nft mihomo
  printf '%s\n' "$PLAT" > /etc/privdns-gateway/platform
  printf 'mihomo\n'     > /etc/privdns-gateway/backend
  mkdir -p /var/lib/privdns-gateway
  e2e_seed_cert || { bad "$tag 造不出占位证书"; return 1; }
  e2e_seed_mihomo_bin || { bad "$tag 播种钉定 mihomo 失败"; return 1; }

  rm -rf "$REPO" "$ORIGIN"
  git clone -q "$PRISTINE" "$REPO" || { bad "$tag 克隆受管仓库失败"; return 1; }
  e2e_guard_repo "$REPO" || { bad "$tag 受管仓库过不了守卫"; return 1; }
  e2e_git "$REPO" config user.email t@t >/dev/null || { bad "$tag 配 user.email 失败"; return 1; }
  e2e_git "$REPO" config user.name t    >/dev/null || { bad "$tag 配 user.name 失败"; return 1; }
  e2e_git "$REPO" config commit.gpgsign false >/dev/null || { bad "$tag 配 gpgsign 失败"; return 1; }
  e2e_git "$REPO" remote remove origin >/dev/null 2>&1
  e2e_git "$REPO" branch -f main "$CAND_SHA" >/dev/null 2>&1 \
    || { bad "$tag 建不出 main(更新器取件走 fetch origin main)"; return 1; }
  # 隔离环境里的自建 tag —— docs/BRIDGE-ENTRY.md 第六节明说这是**模型**, 不是官方发布路径。
  e2e_git "$REPO" tag -f "$BRIDGE_TAG" "$BRIDGE_SHA" >/dev/null || { bad "$tag 打不上 $BRIDGE_TAG"; return 1; }
  e2e_git "$REPO" tag -f "$NEW_TAG"    "$CAND_SHA"   >/dev/null || { bad "$tag 打不上 $NEW_TAG"; return 1; }
  rm -rf "$ORIGIN"
  git clone -q --bare "$REPO" "$ORIGIN" || { bad "$tag 做不出自有 origin"; return 1; }
  e2e_git "$REPO" remote add origin "$ORIGIN" >/dev/null || { bad "$tag 加 origin 失败"; return 1; }
  # 两个新 tag 只留在 origin 上, 逼更新器真去取件
  e2e_git "$REPO" tag -d "$BRIDGE_TAG" "$NEW_TAG" >/dev/null || { bad "$tag 删本地新 tag 失败"; return 1; }
  e2e_git "$REPO" checkout -q "$PREV" >/dev/null || { bad "$tag 检出 $PREV 失败"; return 1; }

  install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg || { bad "$tag 装不上旧版 CLI"; return 1; }
  e2e_reset_botdir || { bad "$tag 重置 /opt/pdg-bot 失败"; return 1; }
  for f in "$REPO"/deploy/bot/*.py; do install -m755 "$f" /opt/pdg-bot/; done
  install -m755 "$REPO/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
  printf '%s\n' '{"user_demo": {"url": "http://example.invalid/u.list", "outbound": "jp", "format": "source", "path": "/etc/sing-box/rs/user_demo.json", "label": "用户自建集"}}' \
    > /opt/pdg-bot/rulesets.json
  # 前像自检: 仓库停在 $PREV、新 tag 只在 origin 上、装上的 CLI 与 $PREV 的**真实文件**逐字节相同
  local desc newt
  # 仓库身份核**实际 HEAD 与预先固定的 PREV_SHA**, 不看 describe —— tag 名只作说明:
  # describe 认的是"最近的 tag", 同一个 tag 名在自有源上被挪走也照样描述成它。
  local head_sha
  if ! head_sha="$(git -C "$REPO" rev-parse -q --verify 'HEAD^{commit}')"; then
    bad "$tag **观测无效** —— 读不回受管仓库的实际 HEAD"; return 1
  fi
  desc="$(git -C "$REPO" describe --tags 2>/dev/null)"
  newt="$(git -C "$REPO" tag -l "$NEW_TAG")"
  { [[ "$head_sha" == "$PREV_SHA" ]] && [[ -z "$newt" ]]; } \
    || { bad "$tag 前像没造对(实际 HEAD=$head_sha 应为 $PREV_SHA; 新tag=${newt:-无}; 说明: describe=$desc)"; return 1; }
  u_cli_is "$tag" prev "$REF_PREV_SHA256" || return 1
  u_count "$tag" '_retire_caller_gate' /usr/local/bin/pdg || return 1
  ok "$tag 前像就位: 仓库停在 $PREV, 新 tag 只在 origin 上, 现役 CLI = $PREV 的真实 pdg.sh(${U_CLI_SHA:0:16}…; 辅助: 退役门符号 $U_CNT 处)"
  UD_BEFORE="$(_ud)" || { bad "$tag 用户数据前像读取失败"; return 1; }
  PROFILE_BEFORE="$(cat /etc/privdns-gateway/profile.env)" \
    || { bad "$tag profile.env 前像读取失败"; return 1; }
  cp /etc/mosdns/config.yaml $E2E_TMP/mos-before.yaml
  # 出发点指纹: profile.env 内容 + mosdns 配置摘要 + 四个服务的 active/enabled。
  # 两条路径的这三样必须一模一样 —— 否则第二条是在第一条的残留上起跑。
  # 每一格**先验有效性再拼**: 失败或空输出不许被拼成一个看着正常的指纹 ——
  # 否则两条路径各自拼出一串空值, 一比还"相等", 隔离判据就成了摆设。
  local _s _mos _fp _pro _rc _errf="$E2E_TMP/.fp.err"
  # ① 两份摘要一视同仁: 先确认**生成成功且格式有效**, 再拼。
  #    profile 这一格原来是直接 `$( … | sha256sum | cut …)` 塞进去的 —— 算不出来时它是空串,
  #    两条路径各拼一个空串, 一比还"相等", 隔离判据就成了摆设。
  : > "$_errf"
  _rc=0; _mos="$(sha256sum /etc/mosdns/config.yaml 2>"$_errf")" || _rc=$?
  _mos="${_mos%% *}"
  if (( _rc != 0 )) || [[ ! "$_mos" =~ ^[0-9a-f]{64}$ ]]; then
    bad "$tag **观测无效** —— mosdns 配置摘要没取到(rc=$_rc, 得到 $(printf '%q' "${_mos:-空}"); $(head -1 "$_errf")), 出发点指纹立不住"
    BASE_FP=""; return 1
  fi
  : > "$_errf"
  _rc=0; _pro="$(printf '%s' "$PROFILE_BEFORE" | sha256sum 2>"$_errf")" || _rc=$?
  _pro="${_pro%% *}"
  if (( _rc != 0 )) || [[ ! "$_pro" =~ ^[0-9a-f]{64}$ ]]; then
    bad "$tag **观测无效** —— profile 摘要没取到(rc=$_rc, 得到 $(printf '%q' "${_pro:-空}"); $(head -1 "$_errf")), 出发点指纹立不住"
    BASE_FP=""; return 1
  fi
  _fp="profile=$_pro mosdns=$_mos"
  # ② 服务状态按**各自查询的合法返回语义**判: 状态词与退出码要**成对**说得通。
  #    systemctl is-active : active → 0; inactive/failed/… → 非零(systemd 用 3)
  #    systemctl is-enabled: enabled 一族 → 0; disabled/masked/… → 非零(systemd 用 1)
  #    所以既不能统一要求 rc=0(那会把合法的 inactive/disabled 判成坏), 也不能一概不看
  #    退出码(那会把"先打印 active 再异常退出"的半截输出当成正常回答)。
  for _s in mosdns mihomo pdg-bot pdg-probe81; do
    # 退出码本身也是观测的一部分, 一并进指纹并留在记录里 —— 状态词相同而退出码不同,
    # 说明两次查询的答法不一样, 那同样不该被当作"出发点一致"。
    _svc_sample "$tag" is-active  "$_s" || { BASE_FP=""; return 1; }
    _fp="$_fp $_s.active=$Q_OUT/rc$Q_RC"
    _svc_sample "$tag" is-enabled "$_s" || { BASE_FP=""; return 1; }
    _fp="$_fp $_s.enabled=$Q_OUT/rc$Q_RC"
  done
  BASE_FP="$_fp"
  echo "   [记录] $tag 出发点采样: $(printf '%s' "$_fp" | sed 's/^profile=[0-9a-f]\{8\}[0-9a-f]*/profile=…/; s/mosdns=[0-9a-f]\{8\}[0-9a-f]*/mosdns=…/')"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# A. 旧 CLI 直接升到退役候选 —— 必须被**调用方门**具名拒绝并回滚
# ════════════════════════════════════════════════════════════════════════════
# 旧版 cmd_update 调的是 `bash /usr/local/bin/pdg __migrate`(见 v1.11.15 的 pdg.sh),
# **没有**任何环境变量前缀; 新版的退役调用方门要的正是"本次操作的服务前像句柄"。
# 这里不补造句柄、不补造前像、不动门 —— 要验的就是"补不出来就得被拒"。
echo; echo "── A. 旧 CLI($PREV)直升退役候选 ──"
A_SEED=1; seed_release_box "A:" || A_SEED=0
A_BASE_FP="${BASE_FP:-}"
if (( A_SEED == 0 )); then
  bad "A-场景未执行: 前像不成立, 本段不执行升级(下面的判据本轮不产出)"
else
  out=$(bash /usr/local/bin/pdg update 2>&1); RC_A=$?
  A_PLAIN="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
  echo "   [记录] A: 旧 CLI update 原始退出码 = $RC_A"
  # ① 产品原始退出码
  [[ "$RC_A" != 0 ]] && ok "A-rc: 旧调用方升级返回非 0(rc=$RC_A)" \
    || bad "A-rc: 竟然返回 0 —— 旧调用方不该被放行(rc=$RC_A)"
  # ② 拒绝必须**来自调用方门**, 不能拿提前失败顶替
  A_EARLY=""
  for _p in '取件失败' '取件不通' 'command not found' 'No such file or directory' \
            '快照失败' '方向' '已有 pdg 操作在运行'; do
    grep -qF "$_p" <<<"$A_PLAIN" && A_EARLY="$A_EARLY $_p"
  done
  { grep -qF '不执行 WLOC 退役迁移' <<<"$A_PLAIN" \
    && grep -qF 'PDG_UPDATE_SVCSTATE 未设' <<<"$A_PLAIN"; } \
    && ok "A-具名: 拒绝理由具名到退役调用方门(未交出本次操作的服务前像句柄)" \
    || bad "A-具名: 没看到调用方门的具名拒绝: $(tail -4 <<<"$A_PLAIN")"
  [[ -z "$A_EARLY" ]] \
    && ok "A-归因: 没有取件/命令缺失/快照/方向/锁这类**提前失败**顶替门的拒绝" \
    || bad "A-归因: 输出里出现了提前失败, 拒绝理由存疑:$A_EARLY"
  grep -qF '迁移(__migrate)失败, 回滚到更新前快照' <<<"$A_PLAIN" \
    && ok "A-阶段: 拒绝发生在迁移阶段, 旧 cmd_update 据此回滚" \
    || bad "A-阶段: 没看到「迁移失败→回滚」这一步: $(tail -4 <<<"$A_PLAIN")"
  # ③ 实际回滚结果 —— **文件恢复与服务恢复分开报**, 不承诺旧回滚具备它没有的能力
  if A_HEAD="$(git -C "$REPO" rev-parse -q --verify 'HEAD^{commit}')"; then
    A_DESC="$(git -C "$REPO" describe --tags 2>/dev/null)"
    [[ "$A_HEAD" == "$PREV_SHA" ]] \
      && ok "A-回滚·仓库: 实际 HEAD 回到预先固定的 $PREV_SHA(说明: describe=$A_DESC)" \
      || bad "A-回滚·仓库: 实际 HEAD = $A_HEAD, 不是 $PREV_SHA(说明: describe=$A_DESC)"
  else
    bad "A-回滚·仓库: **观测无效** —— 读不回实际 HEAD, 这一条没有结论"
  fi
  if u_cli_is "A:" prev "$REF_PREV_SHA256"; then
    u_count "A:" '_retire_caller_gate' /usr/local/bin/pdg || true
    ok "A-回滚·CLI: 现役 CLI 逐字节回到 $PREV 的真实 pdg.sh(${U_CLI_SHA:0:16}…; 辅助: 退役门符号 ${U_CNT:-?} 处)"
  else
    bad "A-回滚·CLI: 见上一条 —— 现役 CLI 不是 $PREV 那一份"
  fi
  # 模块级恢复: 旧版 cmd_rollback 复位仓库与快照文件树, **不保证** /opt/pdg-bot 里
  # 本次新装的模块被撤回。这里如实登记差异, 不把它算成"必须为零"。
  A_MODDIFF=""
  for f in "$REPO"/deploy/bot/*.py; do
    _n="$(basename "$f")"; [[ "$_n" == pdg-bot.py ]] && continue
    cmp -s "$f" "/opt/pdg-bot/$_n" || A_MODDIFF="$A_MODDIFF $_n"
  done
  echo "   [记录] A-回滚·模块: /opt/pdg-bot 里与 $PREV 仓库不一致的:${A_MODDIFF:- 无}"
  echo "   [记录] A-回滚·模块: 这一项**不作为通过条件** —— 旧版回滚只复位仓库与快照文件树,"
  echo "                        没有承诺撤回本次新装进 /opt/pdg-bot 的模块。"
  # 服务恢复: 只要求必需服务仍在运行。**不要求整个更新—回滚过程零服务动作**:
  # 旧版回滚自己会重启服务, 那是它的既定行为, 不是缺陷。
  A_SVCBAD=""
  for _s in mosdns mihomo; do
    [[ "$(systemctl is-active "$_s" 2>/dev/null)" == active ]] || A_SVCBAD="$A_SVCBAD $_s"
  done
  [[ -z "$A_SVCBAD" ]] \
    && ok "A-回滚·服务: 回滚之后核心服务仍在运行(不要求过程中零服务动作)" \
    || bad "A-回滚·服务: 这些没在运行:$A_SVCBAD"
  # 用户数据: 这一组必须逐字节不变
  [[ "$(_ud)" == "$UD_BEFORE" ]] \
    && ok "A-用户数据: bot.env/rulesets/platform/custom_*.txt 逐字节不变" \
    || { bad "A-用户数据被改了"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }
  # profile.env 单列, 但**是判据**: 旧回滚没还原本版写进去的受管键(有源码依据)可以放行,
  # 原有键的有效值被改、出现重复同名键、或新增了源码里没有依据的键 —— 一律判红, 不降级成记录。
  u_profile_ok "A:" || true
fi

# ════════════════════════════════════════════════════════════════════════════
# B. 合法正常升级: $PREV →(BRIDGE-ENTRY 文档原文)→ 桥接 →(已装桥接 CLI)→ 本版
# ════════════════════════════════════════════════════════════════════════════
# 每一跳各自检查: 原始退出码 / 受管仓库实际 HEAD / 现役 CLI 身份 / 模块身份。
# 上一跳不成立就**不执行也不判定**下一跳 —— 不预装桥接或候选去替代升级。
echo; echo "── B. 合法两跳升级 ──"
B_SEED=1; seed_release_box "B:" || B_SEED=0

# 入口**实际调用记录**: 文档原文里那两句提权执行走的是 sudo, 沙箱里用一个透传壳兜住它,
# 顺手把每一次调用记下来。前置失败时这份记录必须是**空的** —— 只记一句 bad、或者只改
# "未执行"的文案, 都不算阻断。
ENTRY_CALLS="$E2E_TMP/entry-calls.log"; : > "$ENTRY_CALLS"
mkdir -p "$E2E_TMP/bin"
{ printf '#!/bin/sh\n'
  printf 'printf "ENTRY\\t%%s\\n" "$*" >> "%s"\n' "$ENTRY_CALLS"
  printf 'exec "$@"\n'; } > "$E2E_TMP/bin/sudo"
chmod 755 "$E2E_TMP/bin/sudo"

# 前置门: 任何一条不成立, **两跳都不执行, 入口一次都不调**。
B_GO=1
(( B_SEED == 1 )) || { bad "B-场景未执行: 前像不成立, 两跳都不执行"; B_GO=0; }
# A 跑完之后现场已经被一次真实的 update→rollback 动过(profile.env 多了受管键、mosdns 被归一、
# 服务被重启)。B 必须从**同一个旧版基线**出发, 所以这里拿出发点指纹当场对一次。
if (( A_SEED == 1 && B_SEED == 1 )); then
  if [[ -n "${BASE_FP:-}" && -n "$A_BASE_FP" && "${BASE_FP:-}" == "$A_BASE_FP" ]]; then
    ok "A/B 前像隔离: 两条路径的出发点指纹完全相同(profile + mosdns + 四个服务的 active/enabled)"
  else
    bad "A/B 前像隔离失败: B 的出发点与 A 不同(或有一侧没取到) —— **不继续执行 B**
    A: ${A_BASE_FP:-<没取到>}
    B: ${BASE_FP:-<没取到>}"
    B_GO=0
  fi
elif (( A_SEED != 1 )); then
  bad "B-场景未执行: A 的出发点指纹没取到, 没有可对照的基线 —— 不继续执行 B"
  B_GO=0
fi

FLOW="$E2E_TMP/bridge-flow.sh"
ENTRY_SRC="$E2E_TMP/bridge-src.git"
if (( B_GO == 1 )); then
  rm -rf "$ENTRY_SRC" "$E2E_TMP/pdg-entry"
  git clone -q --bare "$REPO" "$ENTRY_SRC" >/dev/null 2>&1
  # 写 ref 的动作一律走 e2e_git(它先过 e2e_guard_repo), 并且**处理失败**。
  # 原来虽然置了 B_SEED=0, 但那时已经在外层分支里, 抽流程与调入口照跑 —— 那不叫阻断。
  if ! e2e_git "$ENTRY_SRC" tag -f "$BRIDGE_TAG" "$BRIDGE_SHA" >/dev/null; then
    bad "B-场景未执行: 在入口源上打 $BRIDGE_TAG 失败(守卫拒绝或 git 出错) —— 不抽流程、不调入口"
    B_GO=0
  fi
fi

B_HOP1=0; B_DONE=0
if (( B_GO == 0 )); then
  :   # 上面已经具名报过为什么不执行了
else
  if ! git -C "$REPO" show "$BRIDGE_SHA:docs/BRIDGE-ENTRY.md" > "$E2E_TMP/BRIDGE-ENTRY.md" 2>/dev/null; then
    bad "B-hop1-场景未执行: 取不到桥接对象里的 docs/BRIDGE-ENTRY.md"
  else
    sed -n '/pdg-bridge-entry-flow: BEGIN/,/pdg-bridge-entry-flow: END/p' \
      "$E2E_TMP/BRIDGE-ENTRY.md" > "$FLOW"
    _nflow=$(grep -c . "$FLOW")
    if { (( _nflow > 20 )) && bash -n "$FLOW"; }; then
      ok "B-hop1-流程: 从桥接对象的文档抽到完整流程($_nflow 行)且语法通过"
      printf 'FLOW-RUN\t%s\n' "$FLOW" >> "$ENTRY_CALLS"
      out=$(PATH="$E2E_TMP/bin:$PATH" TAG="$BRIDGE_TAG" WANT="$BRIDGE_SHA" \
            ENTRY="$E2E_TMP/pdg-entry" SRC="$ENTRY_SRC" bash "$FLOW" 2>&1); RC_B1=$?
      B1_PLAIN="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
      echo "   [记录] B-hop1: BRIDGE-ENTRY 流程原始退出码 = $RC_B1"
      if [[ "$RC_B1" != 0 ]]; then
        bad "B-hop1-rc: 旧版→桥接这一跳失败(rc=$RC_B1): $(tail -5 <<<"$B1_PLAIN")"
      else
        ok "B-hop1-rc: 旧版→桥接返回 0"
        # 这一跳要**三项全成立**才算走通: 仓库落点、CLI 身份、CLI 与仓库一致。
        # 少任何一项都不许进下一跳 —— 尤其是"落点不对但文件自洽"那种: 入口副本的身份核对
        # 与受管仓库解析出来的目标是**两个身份**(见 BRIDGE-ENTRY.md 第四节), 前者过了不代表后者对。
        _h_ok=0; _t_ok=0; _m_ok=0
        if _h="$(git -C "$REPO" rev-parse -q --verify 'HEAD^{commit}')"; then
          [[ "$_h" == "$BRIDGE_SHA" ]] \
            && { ok "B-hop1-仓库: 受管仓库实际 HEAD = 冻结桥接对象 ${BRIDGE_SHA:0:12}"; _h_ok=1; } \
            || bad "B-hop1-仓库: 实际 HEAD = $_h, 不是桥接对象 $BRIDGE_SHA"
        else
          bad "B-hop1-场景未执行: 读不回受管仓库实际 HEAD ⇒ 这一跳的仓库身份没有结论"
        fi
        if u_cli_is "B-hop1:" bridge "$REF_BRDG_SHA256"; then
          u_count "B-hop1:" '\-\-to' /usr/local/bin/pdg || true
          ok "B-hop1-CLI: 现役 CLI 逐字节等于冻结桥接对象的 pdg.sh(${U_CLI_SHA:0:16}…; 辅助: --to 出现 ${U_CNT:-?} 次)"; _t_ok=1
        fi
        # 模块完整性按**桥接对象自己的清单**逐项核 —— "pdg.sh 一致"不等于模块装齐了。
        if u_mods_are "B-hop1:" bridge; then
          ok "B-hop1-模块: 桥接清单 $U_MOD_N 项受管模块全部就位且逐字节一致"; _m_ok=1
        else
          [[ -n "${U_MOD_N:-}" ]] && bad "B-hop1-模块: 桥接清单 $U_MOD_N 项里 缺 $U_MOD_MISS / 不符 $U_MOD_DIFF"
        fi
        (( _h_ok == 1 && _t_ok == 1 && _m_ok == 1 )) && B_HOP1=1
      fi
    else
      bad "B-hop1-场景未执行: 抽不到文档流程或语法不过($_nflow 行)"
    fi
  fi
fi

if (( B_HOP1 == 0 )); then
  bad "B-hop2-场景未执行: 上一跳未成立, 这一跳不执行也不判定(不预装候选替代升级)"
  RC_B2=""
else
  echo; echo "── B-hop2: 由**实际已装的桥接 CLI** 升到本版($NEW_TAG) ──"
  out=$(bash /usr/local/bin/pdg update 2>&1); RC_B2=$?
  B2_PLAIN="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
  echo "   [记录] B-hop2: 桥接 CLI update 原始退出码 = $RC_B2"
  [[ "$RC_B2" == 0 ]] && ok "B-hop2-rc: 桥接→本版返回 0(未回滚)" \
    || bad "B-hop2-rc: rc=$RC_B2: $(tail -6 <<<"$B2_PLAIN")"
  grep -qE '已更新|更新完成|升级完成' <<<"$B2_PLAIN" \
    && ok "B-hop2: 输出报出更新成功" || bad "B-hop2: 没报成功: $(tail -4 <<<"$B2_PLAIN")"
  grep -qE '已回滚|回滚到' <<<"$B2_PLAIN" \
    && bad "B-hop2: 不该回滚却回滚了: $(tail -4 <<<"$B2_PLAIN")" || ok "B-hop2: 全程没有触发回滚"
  _h2="$(git -C "$REPO" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
  [[ "$_h2" == "$CAND_SHA" ]] \
    && ok "B-hop2-仓库: 受管仓库实际 HEAD = 本版 ${CAND_SHA:0:12}" \
    || bad "B-hop2-仓库: 实际 HEAD = ${_h2:-读不到}"
  _h2_ok=0; _c2_ok=0; _m2_ok=0
  [[ "$_h2" == "$CAND_SHA" ]] && _h2_ok=1
  if u_cli_is "B-hop2:" cand "$REF_CAND_SHA256"; then
    u_count "B-hop2:" '_retire_caller_gate' /usr/local/bin/pdg || true
    ok "B-hop2-CLI: 现役 CLI 逐字节等于本版的 pdg.sh(${U_CLI_SHA:0:16}…; 辅助: 退役门符号 ${U_CNT:-?} 处)"; _c2_ok=1
  fi
  if u_mods_are "B-hop2:" cand; then
    ok "B-hop2-模块: 本版清单 $U_MOD_N 项受管模块全部就位且逐字节一致"; _m2_ok=1
  else
    [[ -n "${U_MOD_N:-}" ]] && bad "B-hop2-模块: 本版清单 $U_MOD_N 项里 缺 $U_MOD_MISS / 不符 $U_MOD_DIFF"
  fi
  # 四项(退出码/仓库落点/CLI/模块)全成立才算这一跳走完
  (( _h2_ok == 1 && _c2_ok == 1 && _m2_ok == 1 )) && [[ "$RC_B2" == 0 ]] && B_DONE=1
fi

# ── 入口实际调用记账 ────────────────────────────────────────────────────────
# 阻断成不成立, 看的是**入口到底被调了几次**, 不是有没有打出一行"未执行"。
# 数行数用 u_count: `grep -c` 对**空文件**返回 1 并打印 0 —— 那是"一条都没有"这个
# 正常答案, 不是读取错误。拿 `|| _ec=""` 兜住它, 等于把"真的没调过"读成"读不出来"。
_ec=""
if [[ -r "$ENTRY_CALLS" ]] && u_count "B-入口记账:" . "$ENTRY_CALLS"; then _ec="$U_CNT"; fi
if [[ ! "$_ec" =~ ^[0-9]+$ ]]; then
  bad "B-入口记账: **观测无效** —— 读不出入口调用记录, 阻断成不成立无从判断"
elif (( B_GO == 0 )); then
  (( _ec == 0 )) \
    && ok "B-入口记账: 前置未通过 ⇒ 入口调用数为 0(真的没跑, 不是只打了一行「未执行」)" \
    || bad "B-入口记账: 前置未通过却仍调了入口 $_ec 次 —— 阻断没生效:
    $(head -4 "$ENTRY_CALLS" | tr '\n' ';')"
else
  (( _ec > 0 )) \
    && ok "B-入口记账: 健康路径下入口确实被调到($_ec 条记录)" \
    || bad "B-入口记账: 健康路径下入口一次都没被调 —— 这一档什么都没验到"
fi
(( B_GO == 0 )) && { (( B_HOP1 == 0 && B_DONE == 0 )) \
  && ok "B-阻断: 前置未通过时两跳的完成标志都不成立(hop1=$B_HOP1 done=$B_DONE)" \
  || bad "B-阻断: 前置未通过, 完成标志却成立了(hop1=$B_HOP1 done=$B_DONE)"; }

# 下面这批"升级后的现场"判据全部属于 B: 两跳都走完才有现场可判。
# hop2 没成立就**不产出结论** —— 否则回滚后残留的新版模块会让它们假绿
#(原脚本正是这么绿的: 升级失败回滚之后 /opt/pdg-bot 里还留着新版 checks.py/bot.py)。
if (( B_DONE == 0 )); then
  bad "B-现场-场景未执行: 两跳升级没走完, 升级后的现场判据本轮不产出(不拿回滚残留冒充升级成功)"
else
  echo; echo "── 升级后的现场 ──"
  [[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == "$NEW_TAG" ]] \
    && ok "B: 受管仓库切到了 $NEW_TAG" || bad "B: 仓库停在 $(git -C "$REPO" describe --tags 2>/dev/null)"

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
    && ok "B: 用户数据与凭据逐字节不变(bot.env/rulesets/platform/custom_*.txt)" \
    || { bad "B: 升级改了用户数据"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }
  # profile.env 从"逐字节不变"那一组里单拎出来: 它与 mosdns 配置同理, 是**受管**文件 ——
  # 本版会往里加 PDG_LAN_ENABLED 这类受管旋钮, 逐字节比会把一次正常迁移判成数据损失。
  # 判据放对地方: 用户原有的每一行都必须还在(一行都不许掉), 新增的行如实列出来。
  u_profile_ok "B:" || true

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
  # 6.2B 起 migrate_dotwitness 会往 mosdns 配置里插一段**标记界定**的受管块(observer 路由)。
  # 那是这次升级的既定产物, 不是漂移。但也不能就此在行级白名单里加几条 grep -v ——
  # 那会把受管块**之外**长得像的改动一并放过。改用产品自己的 dotwroute.py userpart 把
  # 受管块整段剥掉, 再比剩下的用户部分: 受管块内部随版本怎么变都不算漂移, 块外多一个
  # 字节都算。这比原来的行级白名单更严, 不是更松。
  _userpart(){ python3 "$E2E_ROOT/deploy/bot/dotwroute.py" userpart "$1" 2>/dev/null || cat "$1"; }
  _userpart $E2E_TMP/mos-before.yaml   > $E2E_TMP/mos-before.user.yaml
  _userpart /etc/mosdns/config.yaml    > $E2E_TMP/mos-after.user.yaml
  _changed=$(diff $E2E_TMP/mos-before.user.yaml $E2E_TMP/mos-after.user.yaml | grep -cE '^[<>]')
  if [[ "$_changed" == 0 ]]; then
    ok "mosdns 受管配置(剥掉 witness 受管块后)逐字节未变"
  else
    # 变了就把变的行摆出来, 并且只接受已知的受管旋钮
    _unexpected=$(diff $E2E_TMP/mos-before.user.yaml $E2E_TMP/mos-after.user.yaml | grep -E '^[<>]' \
                  | grep -vE 'size: *[0-9]+' | head -5)
    [[ -z "$_unexpected" ]] \
      && ok "mosdns 受管配置只动了受管旋钮 cache size($(grep -oE 'size: *[0-9]+' $E2E_TMP/mos-before.yaml | head -1) → $(grep -oE 'size: *[0-9]+' /etc/mosdns/config.yaml | head -1)), 属既定迁移" \
      || bad "mosdns 配置里有受管旋钮之外的改动:
  $_unexpected"
  fi

  out=$(bash /usr/local/bin/pdg doctor 2>&1)
  grep -qE '🔴|❌' <<<"$out" && bad "doctor 有失败项: $(grep -E '🔴|❌' <<<"$out" | head -3)" \
    || ok "升级后 doctor 无失败项"

fi

e2e_summary

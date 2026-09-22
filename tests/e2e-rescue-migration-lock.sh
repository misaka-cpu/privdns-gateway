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
# 冻结桥接对象 —— 这支测试里它是"旧调用方撞上退役门之后, 唯一一条合法的升级路线"的起点。
# 它在本仓库里确实是 $PREV 的后代、本版的祖先; 合成链照抄这个先后, 不制造假祖先关系。
BRIDGE_SHA="${PDG_BRIDGE_SHA:-9c9b2681f3ada2155b32ebe372cbc2a154792079}"
BRIDGE_TAG="${PDG_BRIDGE_TAG:-v9.9.8}"     # 排在 $NEW_TAG(v9.9.9) 之前, 语义化顺序与真实顺序一致
EXPECT_DESC="$PREV"                        # 回滚判据里"应当回到哪个 describe"; 桥接跳之后会改写

SNAPD=/var/lib/privdns-gateway/backups
rml_snap_list(){   # $1=清单落点 $2=具名前缀 → 0=采到了(目录不存在 = 合法的空集)
  local out="$1" tag="$2" raw="$1.raw" err="$1.err" rc=0
  rm -f "$out" "$raw" "$err"
  if [[ ! -d "$SNAPD" ]]; then : > "$out"; return 0; fi
  ls -1 "$SNAPD/" > "$raw" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 列快照目录失败(rc=$rc; stderr: $(head -1 "$err" 2>/dev/null))"
    rm -f "$raw" "$err"; return 1
  fi
  rc=0; sort "$raw" > "$out" 2>>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 快照清单排序失败(原始退出码 $rc)"
    rm -f "$out" "$raw" "$err"; return 1
  fi
  rm -f "$raw" "$err"; return 0
}

# 差集: comm 与读回各自检查真实退出码。原来一路 `comm … | grep -c . || true`, 把
# "comm 失败"、"读到 0 行"、"grep 自己出错"三件事压成同一个数字, 失败时还照样消费它。
# 身份读取只有一个入口。以前是 `X="$(git rev-parse …)"` 直接赋值 —— rev-parse 完全可以
# **先往 stdout 吐一行、再以非零收场**, 那一行会被原样当成身份用下去。这里退出码与格式
# 分别判, 任一不过都判「观测无效」, 并且**不消费**已经吐出来的那一行。结果只经 RML_SHA 传出。
# 模块清单: 先把生成器**单独**跑一遍并拿到它自己的退出码, 成功且非空才允许逐项比。
# 原来一律写成 `done < <(pdg_platform_modules "$PLAT")` —— 进程替换的退出码是拿不到的,
# 生成器吐了半截再失败也看不出来, 于是"读到几项就按几项算", 再靠 (( n > 0 )) 宣称完整。
RML_MODS=""; RML_MODN=0
rml_mod_list(){   # $1=仓库 $2=平台 $3=具名前缀 → 0=拿到一份完整清单(内容在 RML_MODS)
  local repo="$1" plat="$2" tag="$3" out="$E2E_TMP/.mods" err="$E2E_TMP/.mods.err" rc=0 txt
  RML_MODS=""; RML_MODN=0
  rm -f "$out" "$err"
  if [[ ! -f "$repo/lib/modules.sh" ]] || ! grep -q 'pdg_platform_modules' "$repo/lib/modules.sh"; then
    bad "$tag **观测无效** —— $repo 里没有模块清单(lib/modules.sh 缺失或不含 pdg_platform_modules)"
    return 1
  fi
  # shellcheck source=/dev/null
  . "$repo/lib/modules.sh" 2>"$err" || { bad "$tag **观测无效** —— 载入 lib/modules.sh 失败: $(head -1 "$err" 2>/dev/null)"; rm -f "$err"; return 1; }
  pdg_platform_modules "$plat" > "$out" 2>>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 生成模块清单失败(原始退出码 $rc; stderr: $(head -1 "$err" 2>/dev/null)) —— 它已经吐出来的那 $(wc -l < "$out" 2>/dev/null) 行一律不消费"
    rm -f "$out" "$err"; return 1
  fi
  rc=0; txt="$(cat "$out")" || rc=$?
  rm -f "$out" "$err"
  (( rc == 0 )) || { bad "$tag **观测无效** —— 清单读回失败(原始退出码 $rc)"; return 1; }
  if [[ -z "$txt" ]]; then
    bad "$tag 模块清单是**空的** —— 一项都没有就谈不上「全部就位」, 拒绝按空集判通过"
    return 1
  fi
  RML_MODS="$txt"; mapfile -t _ml <<< "$txt"; RML_MODN="${#_ml[@]}"
  return 0
}

# 升级入口的调用记录。阻断到底有没有生效, 只看"下一步调用数是不是 0"这一个事实 ——
# 只改一句文案、或者只记一条 bad, 都不算阻断。每个阶段自己清零、自己数。
UPD_CALLS=""
rml_upd_n(){   # → 打印本阶段至今的升级调用笔数; 数不出来打 ERR(不冒充 0)
  local n rc=0
  n="$(wc -l < "$UPD_CALLS" 2>/dev/null)" || rc=$?
  (( rc == 0 )) && printf '%s' "${n//[[:space:]]/}" || printf 'ERR'
}

RML_SHA=""
rml_sha(){   # $1=仓库 $2=revision $3=具名前缀 → 0=读到了(完整 40 位在 RML_SHA)
  local repo="$1" rev="$2" tag="$3" raw="" rc=0 err="$E2E_TMP/.sha.err"
  RML_SHA=""
  : > "$err"
  raw="$(git -C "$repo" rev-parse -q --verify "$rev" 2>"$err")" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 解析 $rev 失败(原始退出码 $rc; stderr: $(head -1 "$err" 2>/dev/null)) —— 它已经吐出来的那 ${#raw} 个字符一律不消费"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  # 成功也要看格式: 少一位、带前后空白、或者多行, 都不是能拿去逐字比对的身份。
  if [[ ! "$raw" =~ ^[0-9a-f]{40}$ ]]; then
    bad "$tag **观测无效** —— $rev 解析出来的不是完整 40 位提交哈希(拿到 ${#raw} 个字符: $(printf '%.50s' "$raw"))"
    return 1
  fi
  RML_SHA="$raw"; return 0
}

SNAP_NEW=""; SNAP_NEWN=0
rml_snap_diff(){   # $1=前清单 $2=后清单 $3=具名前缀 → 0=算出来了(结果在 SNAP_NEW/SNAP_NEWN)
  local bf="$1" af="$2" tag="$3" out="$E2E_TMP/.snapdiff" err="$E2E_TMP/.snapdiff.err" rc=0 txt
  SNAP_NEW=""; SNAP_NEWN=0
  rm -f "$out" "$err"
  comm -13 "$bf" "$af" > "$out" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 差集计算失败(原始退出码 $rc; stderr: $(head -1 "$err" 2>/dev/null)) —— 已经落到 $out 的那半截一律不消费"
    rm -f "$out" "$err"; return 1
  fi
  rc=0; txt="$(cat "$out")" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 差集结果读回失败(原始退出码 $rc)"
    rm -f "$out" "$err"; return 1
  fi
  rm -f "$out" "$err"
  if [[ -n "$txt" ]]; then
    mapfile -t _sn <<< "$txt"; SNAP_NEWN="${#_sn[@]}"
    # 只有**恰好一份**时才给出归属。多于一份就不挑 —— 按最早/最新猜一个, 等于替产品
    # 认领了一份不知道谁建的归档, 后面"归档是实的"就可能落在别人的产物上。
    (( SNAP_NEWN == 1 )) && SNAP_NEW="${_sn[0]}"
  fi
  return 0
}

# 归档产物: 目录出现**不等于**快照做成了。按调用方那一版**自己真支持**的格式核 ——
# v1.7.8 的 cmd_update 认的是 "$d/snap.tar.gz"(见它自己第 989 行), 它那一版压根没有
# svcstate.tsv(桥接才引入), 所以不能拿候选的格式去要求它。
rml_snap_archive(){   # $1=新增目录名 $2=具名前缀 $3=1 表示这一版应当产出 svcstate.tsv
  local d="$SNAPD/$1" tag="$2" want_svc="$3" rc=0 lst="$E2E_TMP/.snapmem" err="$E2E_TMP/.snapmem.err" txt
  local tgz="$d/snap.tar.gz"
  [[ -d "$d" ]] || { bad "$tag 新增的 $1 不是目录 —— 拿不到归档"; return 1; }
  if [[ ! -f "$tgz" ]]; then
    bad "$tag 新增了目录 $1, 里面却没有 snap.tar.gz —— 「新增一份目录」不能替代实际归档"
    return 1
  fi
  gzip -t "$tgz" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag $1/snap.tar.gz 不是完好的 gzip(原始退出码 $rc; $(head -1 "$err" 2>/dev/null))"
    rm -f "$err"; return 1
  fi
  rc=0; tar tzf "$tgz" > "$lst" 2>"$err" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— 列归档成员失败(原始退出码 $rc; $(head -1 "$err" 2>/dev/null)) —— 不消费已经列出来的那半截"
    rm -f "$lst" "$err"; return 1
  fi
  rc=0; txt="$(cat "$lst")" || rc=$?
  rm -f "$lst" "$err"
  (( rc == 0 )) || { bad "$tag **观测无效** —— 成员清单读回失败(原始退出码 $rc)"; return 1; }
  [[ -n "$txt" ]] || { bad "$tag $1/snap.tar.gz 是个**空归档** —— 回滚时无物可回"; return 1; }
  local n; mapfile -t _sm <<< "$txt"; n="${#_sm[@]}"
  grep -q '^etc/privdns-gateway' <<<"$txt" \
    || { bad "$tag 归档里没有 etc/privdns-gateway(共 $n 个成员) —— 这台机器的配置没被收进去"; return 1; }
  ok "$tag 归档是实的: $1/snap.tar.gz 通过 gzip -t, $n 个成员, 含 etc/privdns-gateway"
  if (( want_svc == 1 )); then
    [[ -f "$d/svcstate.tsv" ]] && ok "$tag 这一版的调用方会交服务前像, 目录里确实有 svcstate.tsv" \
      || bad "$tag 这一版的调用方本该产出 svcstate.tsv, 目录里没有"
  else
    echo "   [记录] $tag 调用方那一版($PREV)没有 svcstate.tsv 这个概念(桥接才引入), 按它自己支持的格式核, 不强求"
  fi
  return 0
}

# ── 播种一台"$PREV 的存量机器" ──────────────────────────────────────────────
# 包成函数只为一件事: 退役门那条路径要从**独立重建的前像**再走一次合法升级, 而不是在
# 一次 update→回滚动过的现场上接着跑。函数体是原来的那段, 一行没挪位。
#   $1 = 合成源里要不要插入桥接提交   $2 = 要不要播 post-fault 的故障   $3 = 要不要先重置整台机器
rml_seed_box(){
local _WITH_BRIDGE="${1:-0}" _SEED_FAULT="${2:-1}" _DO_RESET="${3:-0}" _seed_ok=1
if (( _DO_RESET == 1 )); then
  e2e_reset_box || { bad "重置沙箱失败, 独立前像建不起来"; return 1; }
fi
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
# 播真钉死版, 不用 shell 桩: 桩自报版本是对的、内容是错的, 而 install.sh 的短路与
# doctor 的完整性判据现在都看内容(CI 33353591548 的五支红灯就是这么来的)。
e2e_seed_mihomo_bin || { echo "[FAIL] 播种钉定 mihomo 失败"; exit 1; }

# `ip -4 -o addr show scope global` 的桩: 救援平面靠它挑监听地址候选。沙箱里没有真网卡,
# 不桩的话"来源段内恰好一个本机地址"这条路径根本走不到, bind-auto 那格就成了空测试。
# 自己造的桩自己撤 —— 下一支进场那道兜底是保险, 不是分工(它连异常退出都要兜)。
_rml_drop_ip_stub(){ e2e_purge_shadow_stub ip || true; }
if [[ -z "${_RML_HOOKED:-}" ]]; then e2e_add_exit_hook _rml_drop_ip_stub; _RML_HOOKED=1; fi

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

# 桥接跳需要一个真实存在的中间落点。顺序照抄真实祖先关系($PREV → 桥接 → 本版),
# 树取自冻结桥接对象本身 —— 不是拿本版改个 tag 冒充入口。
BRIDGE_SYN_SHA=""
if (( _WITH_BRIDGE == 1 )); then
  if git -C "$E2E_ROOT" rev-parse -q --verify "$BRIDGE_SHA^{commit}" >/dev/null; then
    rm -rf "${REPO:?}"/* 2>/dev/null || true
    git -C "$E2E_ROOT" archive "$BRIDGE_SHA" | tar -x -C "$REPO"
    e2e_git "$REPO" add -A >/dev/null 2>&1
    e2e_git "$REPO" commit -qm "$BRIDGE_TAG(bridge ${BRIDGE_SHA:0:12})" >/dev/null 2>&1
    e2e_git "$REPO" tag "$BRIDGE_TAG"
    # 要桥接跳就必须有这个落点身份; 取不到这一次播种就是不成立的。
    rml_sha "$REPO" 'HEAD^{commit}' "桥接提交:" && BRIDGE_SYN_SHA="$RML_SHA" || _seed_ok=0
  else
    bad "取不到冻结桥接对象 ${BRIDGE_SHA:0:12} —— 桥接跳建不起来"
  fi
fi
rm -rf "${REPO:?}"/* 2>/dev/null || true
tar -C "$E2E_ROOT" --exclude=.git -cf - . | tar -x -C "$REPO"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm "$NEW_TAG(hotfix worktree)" >/dev/null 2>&1
e2e_git "$REPO" tag "$NEW_TAG"
# 目标身份**在动手之前就固定**, 事后不再从现场反推。两个身份分开登记, 不混为一谈:
#   · 合成目标身份 TARGET_SYN_SHA —— 隔离 origin 里那个提交(本次 update 该落到的点);
#   · 冻结源码身份 _head_sha      —— 这棵树取自哪份源码(工作树 HEAD), 两者不是同一个哈希。
TARGET_SYN_SHA=""
rml_sha "$REPO" 'HEAD^{commit}' "目标提交:" && TARGET_SYN_SHA="$RML_SHA" || _seed_ok=0
cp "$E2E_ROOT/deploy/bot/pdg.sh" "$E2E_TMP/cli-cand.bin"
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d "$NEW_TAG" >/dev/null      # 新 tag 只在 origin 上, 逼 update 真去 fetch
(( _WITH_BRIDGE == 1 )) && e2e_git "$REPO" tag -d "$BRIDGE_TAG" >/dev/null   # 桥接 tag 同理
e2e_git "$REPO" checkout -q "$PREV"

# 机器上装的是 **v1.7.8** 的脚本与模块 —— 这才是存量用户的现场。
# 模块按 **v1.7.8 自己的清单**装, 不是 `deploy/bot/*.py` 一把梭: 救援平面的模块散在
# deploy/bot 与 deploy/rescue 两个目录(rescue.py / rescue_cred.py / breakglass.py 在后者),
# 只拷 deploy/bot 会得到一台"救援模块半残"的机器 —— 而 _rescue_enable 的第一道门就是
# 模块闭包完整性, 于是首次启用必然失败, 测出来的是夹具的病不是产品的病。
install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
cp "$REPO/deploy/bot/pdg.sh" "$E2E_TMP/cli-prev.bin"   # 判回滚/判预装都要拿它逐字节比
e2e_reset_botdir || bad "重置 /opt/pdg-bot 失败"
# lib/modules.sh 是 v1.7.x 才有的东西。更老的版本(v1.6.3 / v1.5.9)按目录铺文件, 这里就
# 照它们当年的做法铺 —— 硬要用新清单去装老版本, 得到的是一台现实中不存在的机器。
if [[ -f "$REPO/lib/modules.sh" ]] && grep -q 'pdg_platform_modules' "$REPO/lib/modules.sh"; then
  # 播种也走同一套读法 —— 清单生成失败时不能"铺了半截当铺好了", 那样后面每一条断言
  # 都建在一台残缺的机器上。
  if rml_mod_list "$REPO" "$PLAT" "播种清单:"; then
    while read -r _src _name _mode; do
      [[ -n "$_src" ]] || continue
      install -m"${_mode:-755}" "$REPO/$_src" "/opt/pdg-bot/$_name" 2>/dev/null || true
    done <<< "$RML_MODS"
    _seed_how="按 $PREV 自己的模块清单($RML_MODN 项)"
  else
    # 这一版是按清单铺模块的, 清单没取到就铺不全 —— 不能"铺了半截当铺好了"往下走。
    _seed_how="清单没取到(上面已具名), 这台机器不完整"; _seed_ok=0
  fi
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
    # 故障什么时候播由调用方决定: 一跳直达时进场就播; 两跳时要等桥接跳**健康走完**
    # 再播, 否则"迁移成功之后才出故障"这个前提就是假设出来的, 不是这一跳挣来的。
    (( _SEED_FAULT == 1 )) && e2e_svc_crash pdg-bot   # restart 返回 0, 服务随即又变回 inactive
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
# 救援 socket unit 的**独立**前像: 调用之前自己看一眼文件在不在、是什么内容。
# 原来是拿 PDG_RESCUE_ENABLED 反推"这份 unit 本来就该在", 那是用意图替代观测 ——
# 意图为 1 的机器上 unit 也可能根本没落过盘, 反推会把本次新增的残留一并豁免掉。
RML_SOCK=/etc/systemd/system/pdg-rescue.socket
SOCK_BEFORE=""; SOCK_BEFORE_OK=1
if [[ -e "$RML_SOCK" ]]; then
  _sb_rc=0; SOCK_BEFORE="$(sha256sum "$RML_SOCK" 2>/dev/null | awk '{print $1}')" || _sb_rc=$?
  if (( _sb_rc != 0 )) || [[ -z "$SOCK_BEFORE" ]]; then SOCK_BEFORE_OK=0; SOCK_BEFORE=""; fi
else
  SOCK_BEFORE="(不存在)"
fi
# 这台机器上有没有 WLOC 退役要干 —— 按**现场材料**判, 不按平台名判(平台名是夹具的旋钮,
# 材料才是产品看的东西)。必须在更新**之前**采: 退役一旦成功就会把这些材料删掉, 事后再读
# 会把"有材料而且退役成功了"读成"本来就没有材料", 于是错判成"与预期一致"。
RETIRE_MAT=""
for _f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py \
          /opt/pdg-bot/mitm_wloc.py /etc/privdns-gateway/mitm.json; do
  [[ -e "$_f" ]] && RETIRE_MAT="$RETIRE_MAT $_f"
done
EXPECT_GATE=0; [[ -n "$RETIRE_MAT" ]] && EXPECT_GATE=1
# 这一版的调用方会不会产出服务前像 —— 从**它自己的脚本**判, 不按版本号猜, 也不拿候选的
# 格式去要求旧版。v1.7.8 的 pdg.sh 里一次 svcstate 都没有, 桥接起才有。
SNAP_WANT_SVCSTATE=0
grep -q 'svcstate\.tsv' "$E2E_TMP/cli-prev.bin" 2>/dev/null && SNAP_WANT_SVCSTATE=1
SNAP_BEFORE_F="$E2E_TMP/snap-before.txt"
rml_snap_list "$SNAP_BEFORE_F" "前像快照:" || true
_pre_sha=""                                     # 精确回滚目标: 更新前那个提交
rml_sha "$REPO" 'HEAD^{commit}' "前像提交:" && _pre_sha="$RML_SHA" || _seed_ok=0
(( _seed_ok == 1 )) || return 1
return 0
}

UPD_CALLS="$E2E_TMP/rml-upd-calls.log"
if ! rml_seed_box 0 1 0; then
  : > "$UPD_CALLS"
  bad "A-场景未执行: 播种这一台机器时, 必需的模块清单或固定身份没取到(上面已具名) —— **不执行**这次升级"
  echo "   [记录] 阻断之后的升级调用笔数 = $(rml_upd_n)(0 才算真的没调)"
  e2e_summary
  exit $?
fi
: > "$UPD_CALLS"

echo
echo "── 跑 $PREV 的 pdg update(目标: 当前工作树) ──"
printf 'UPDATE-A\n' >> "$UPD_CALLS"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
printf '%s\n' "$out" > $E2E_TMP/rml-out.txt
echo "   [记录] A 段升级调用笔数 = $(rml_upd_n)"

_intent(){ sed -n 's/^[[:space:]]*PDG_RESCUE_ENABLED=//p' "$PROF" | tail -1; }

# ── 退役门到底有没有触发? ──────────────────────────────────────────────────
# 预期(EXPECT_GATE)是进场前按现场材料算好的, 见上。两者不符就具名报红: 那说明这份材料
# 模型与产品判据漂开了, 不能让它悄悄变成"发生什么都对"。
GATE_HIT=0; grep -q '不执行 WLOC 退役迁移' <<<"$out" && GATE_HIT=1
if (( GATE_HIT == EXPECT_GATE )); then
  (( EXPECT_GATE == 1 )) \
    && ok "退役门: 现场有退役材料($(printf '%s' "$RETIRE_MAT" | wc -w) 件), 旧调用方确实被拦下 —— 与预期一致" \
    || ok "退役门: 现场没有退役材料, 旧调用方这条路本来就走得通 —— 与预期一致"
else
  bad "退役门: 预期触发=$EXPECT_GATE, 实际触发=$GATE_HIT(现场材料:${RETIRE_MAT:- 无}) —— 材料模型与产品判据对不上, 后面按哪条路径走都没有依据"
fi

# ═══ G. 旧调用方撞上退役调用方门 ═══════════════════════════════════════════
# 这条路径**不是** Android 那条。Android 现场没有 WLOC 退役材料, 门根本不触发, 旧调用方
# 一跳直达本版 —— 那是既有可行路径, 原样保留在下面。这里处理的是**真的撞上门**的现场:
#   ① 拒绝必须是退役门给的具名拒绝, 且能核到本次操作真正的回滚目标;
#   ② 这台机器要升上来, 正路是经**桥接入口**两跳 —— 从独立重建的前像出发, 逐跳核身份;
#   ③ 救援首次启用发生在哪一跳就在哪一跳验;
#   ④ post-fault 先把桥接跳健康走完, 再给目标跳设故障。
if (( GATE_HIT == 1 )); then
echo; echo "── G. 旧调用方($PREV)直升本版: 退役调用方门 ──"

# ── G-1. 拒绝是不是**门**给的, 而不是别的提前失败顶替 ──────────────────────
[[ "$rc" != 0 ]] && ok "G-rc: 旧调用方直升被拒 → update 返回非零(rc=$rc)" \
  || bad "G-rc: 撞上退役门却报成功(rc=$rc)"
grep -q '不执行 WLOC 退役迁移' <<<"$out" \
  && ok "G-门: 拒绝文案点名了 WLOC 退役迁移" \
  || bad "G-门: 没点名退役迁移: $(tail -4 <<<"$out")"
grep -qE '调用方不具备可靠回滚能力|调用者不具备可靠回滚能力' <<<"$out" \
  && ok "G-门: 点名了拒绝理由(调用方不具备可靠回滚能力)" \
  || bad "G-门: 没给出调用方能力这个理由"
grep -q 'PDG_UPDATE_SVCSTATE' <<<"$out" \
  && ok "G-因: 点名缺的是本次操作的服务前像句柄(PDG_UPDATE_SVCSTATE)" \
  || bad "G-因: 没说清缺的是什么"
# 「取件失败 / 命令不存在 / 磁盘」这类提前失败也会让 rc 非零。它们一旦出现, 上面那几条
# 文案判据就可能是上一段残留的输出, 拒绝的归属就不干净 —— 单独钉死。
grep -qE 'fetch 失败|取件失败|command not found|No such file or directory|no space left' <<<"$out" \
  && bad "G-归属: 输出里有提前失败迹象, 拒绝不能归给调用方门: $(grep -nE 'fetch 失败|取件失败|command not found|No such file or directory|no space left' <<<"$out" | head -2)" \
  || ok "G-归属: 没有取件/命令缺失一类提前失败, 拒绝确实来自调用方门"
grep -q '迁移(__migrate)失败' <<<"$out" \
  && ok "G-阶段: 失败发生在迁移(__migrate)这一步, 与门的位置一致" \
  || bad "G-阶段: 输出里没有迁移失败, 门的位置对不上: $(tail -4 <<<"$out")"

# ── G-2. 「没执行退役副作用」≠「整条更新什么都没干」 ────────────────────────
# 产品自述的是"本次尚未执行任何**退役**副作用"。这一轮 update 本身是**动过**机器的:
# 取件、切版本、建快照都发生了, 然后才整体回滚。把这两件事混成一件, 下面的回滚判据就失去
# 了意义(什么都没发生的话, "回滚正确"是恒真的)。所以先正着证明这一轮确实动过。
_g_moved=0
grep -qE '已切到发布|切到发布|刷新代码' <<<"$out" \
  && { ok "G-动作: 本轮确实切过版本/刷过代码(不是一步没走)"; _g_moved=1; } \
  || bad "G-动作: 输出里看不到取件与切版本, 这一轮可能根本没开始 —— 回滚判据会变成恒真"
if rml_snap_list "$E2E_TMP/snap-after-A.txt" "G-快照:" \
   && rml_snap_diff "$SNAP_BEFORE_F" "$E2E_TMP/snap-after-A.txt" "G-快照:"; then
  if (( SNAP_NEWN == 1 )); then
    ok "G-快照: 本场景新增**恰好一份**快照目录($SNAP_NEW), 归属唯一"
    # 目录出现只是"开始做了"。回滚要有物可回, 得看归档本身。
    rml_snap_archive "$SNAP_NEW" "G-快照:" "$SNAP_WANT_SVCSTATE" && _g_moved=1
  elif (( SNAP_NEWN > 1 )); then
    # 本场景一次 update 只该建一份。多出来的可能来自并发、上一格的残留、或者产品建了
    # 不止一份 —— 在没有独立办法把"哪一份是本次的"定下来之前, 归属不明, 不挑不核。
    bad "G-快照-归属不明: 新增了 $SNAP_NEWN 份($(printf '%s ' "${_sn[@]}" 2>/dev/null))
    本场景一次 update 只该建一份; 没有独立依据能定位本次那一份, 因此**不按最早或最新猜选**,
    「归档是实的」这条本格未取得"
  else
    bad "G-快照: 本轮没有新增快照目录, 「回滚到更新前快照」这句没有对应产物"
  fi
fi
(( _g_moved == 1 )) \
  && ok "G-口径: 「未执行退役副作用」只覆盖退役那一段, 本轮更新**动过**机器" \
  || bad "G-口径: 拿不到本轮动过机器的证据, 不能把它写成一次完整的更新尝试"

# ── G-3. 本次操作的实际回滚目标 ────────────────────────────────────────────
if ! rml_sha "$REPO" 'HEAD^{commit}' "G-回滚:"; then
  :   # 观测无效已具名, 不再拿半截结果下结论
elif [[ -z "$_pre_sha" ]]; then
  bad "G-回滚 **观测无效** —— 本次操作的前像提交当初就没读到, 没有可比对象"
else
  [[ "$RML_SHA" == "$_pre_sha" ]] \
    && ok "G-回滚: 受管仓库精确复位到本次更新前那个提交($_pre_sha)" \
    || bad "G-回滚: 复位到 $RML_SHA, 本次操作的前像是 $_pre_sha"
fi
[[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == "$PREV" ]] \
  && ok "G-回滚: describe 回到 $PREV" \
  || bad "G-回滚: describe=$(git -C "$REPO" describe --tags 2>/dev/null)"
# 「回滚残留」不是「升级成功」: 现役 CLI 必须逐字节回到 $PREV 那一份。
cmp -s "$E2E_TMP/cli-prev.bin" /usr/local/bin/pdg \
  && ok "G-回滚: 现役 CLI 逐字节回到 $PREV 那一份(旧回滚残留没有被当成升级结果)" \
  || bad "G-回滚: 现役 CLI 不是 $PREV 的那一份 —— 回滚没把脚本换回去"
grep -qE '✅ 已更新|更新完成|升级完成' <<<"$out" \
  && bad "G-回滚: 回滚了却打印了更新成功" || ok "G-回滚: 没有谎报更新成功"

# ── G-4. 救援动作与回滚后现场 ──────────────────────────────────────────────
# 整条更新都回滚了, 所以这一格**不该**留下任何救援侧的动作痕迹; 本格原有的"首次启用/
# 自动认定 bind/停用提示"这些判据在这条路径上根本没机会执行, 移交下面的 B-hop1 去验,
# 这里明说, 不冒称覆盖过。
[[ "$(_intent)" == "$INTENT_BEFORE" ]] \
  && ok "G-救援: 救援意图与本次更新前一致('$INTENT_BEFORE')" \
  || bad "G-救援: 回滚了意图却变了: '$INTENT_BEFORE' → '$(_intent)'"
# ── socket unit: 先报**事实**, 再判**契约**, 两件事分开 ────────────────────
if (( SOCK_BEFORE_OK == 0 )); then
  bad "G-socket **观测无效** —— 调用前那份 unit 的指纹没取到, 本次有没有动它无从判定"
else
  _sock_now="(不存在)"; _sn_ok=1
  if [[ -e "$RML_SOCK" ]]; then
    _sn_rc=0; _sock_now="$(sha256sum "$RML_SOCK" 2>/dev/null | awk '{print $1}')" || _sn_rc=$?
    if (( _sn_rc != 0 )) || [[ -z "$_sock_now" ]]; then _sn_ok=0; fi
  fi
  if (( _sn_ok == 0 )); then
    bad "G-socket **观测无效** —— 调用后那份 unit 的指纹没取到"
  else
    # (事实) 这次操作到底对这个文件做了什么 —— 中性陈述, 与"该不该"分开
    # 措辞只说**净效果**: 前后两次取到的指纹一样, 不等于过程中没动过 —— 一次更新完全
    # 可以先改写、再回滚成原样。要说"全程没发生", 这两次快照给不出这个结论。
    if   [[ "$SOCK_BEFORE" == "(不存在)" && "$_sock_now" == "(不存在)" ]]; then _sock_act="净效果为零: 调用前后都不存在(不排除过程中建了又删)"
    elif [[ "$SOCK_BEFORE" == "(不存在)" ]];                            then _sock_act="**本次新装**(调用前不存在 → 现在 ${_sock_now:0:12}…)"
    elif [[ "$_sock_now"   == "(不存在)" ]];                            then _sock_act="**本次删除**(调用前 ${SOCK_BEFORE:0:12}… → 现在没了)"
    elif [[ "$SOCK_BEFORE" != "$_sock_now" ]];                          then _sock_act="**本次改写**(${SOCK_BEFORE:0:12}… → ${_sock_now:0:12}…)"
    else                                                                     _sock_act="净效果为零: 前后指纹相同(${SOCK_BEFORE:0:12}…)(不排除过程中改过又改回)"
    fi
    ok "G-socket-观测: 调用前后各自独立取到了 unit 的存在性与指纹(不靠启用意图推断)"
    echo "   [记录] G-socket-事实: 本次操作对 $RML_SOCK 的实际影响 = $_sock_act"
    # (契约) 旧调用方自报"失败并回滚到更新前快照" ⇒ 现场必须回到调用前那一版。
    # 这条只看事实, 不看意图: 意图为 1 也不能豁免"本次新装的残留"。
    [[ "$SOCK_BEFORE" == "$_sock_now" ]] \
      && ok "G-socket-契约: 旧调用方失败回滚后, 这份 unit 与调用前逐字节一致" \
      || bad "G-socket-契约: 旧调用方自报已回滚到更新前快照, 这份 unit 却 $_sock_act"
  fi
fi
# 整体回滚**不等于**救援动作没发生过 —— 这次更新里救援迁移排在退役之前, 它做没做、做了
# 什么, 上面那条"事实"已经如实记下了。回滚只是宣告这次更新作废, 并不追认"什么都没干"。
if (( EXPECT_ENABLE == 1 )); then
  echo "   [记录] G-救援: 本格($CASE)的「首次启用/恢复」判据**未取得**(本次更新以回滚收场), 移交 B-hop1;"
  echo "   [记录] G-救援: 但救援动作发生过没有, **以上面那条 socket 事实为准** —— 回滚不把它改写成「没发生」"
else
  echo "   [记录] G-救援: 本格($CASE)预期本就不启用; 保持关闭的正面判据移交 B-hop1"
fi
[[ "$(_ud)" == "$UD_BEFORE" ]] && ok "G-数据: 用户数据逐字节回到更新前" \
  || { bad "G-数据: 回滚后用户数据与更新前不一致"; diff <(printf '%s\n' "$UD_BEFORE") <(_ud); }
if [[ -n "$DIG_BEFORE" ]]; then
  [[ "$(_rescue_dig)" == "$DIG_BEFORE" ]] \
    && ok "G-数据: 救援 token / 证书 / 私钥三份摘要全部不变" || bad "G-数据: 救援凭据被动了"
fi
_g_held="$(fuser /run/privdns-gateway.lock 2>/dev/null | tr -d ' ')"
[[ -z "$_g_held" ]] && ok "G-残留: 锁文件上没有残留持有者" || bad "G-残留: 还有进程持着锁: $_g_held"
_g_tmp="$(comm -13 <(printf '%s\n' "$TMP_BEFORE") \
                   <(ls -d $E2E_TMP/pdg-* $E2E_TMP/pdgtx-* 2>/dev/null | sort) | grep -c . || true)"
[[ "${_g_tmp:-0}" == 0 ]] && ok "G-残留: 没有新增临时目录残留" || bad "G-残留: 新增 $_g_tmp 个"

# ════════════════════════════════════════════════════════════════════════════
# B. 合法升级: $PREV →(BRIDGE-ENTRY 文档原文)→ 桥接 →(已装桥接 CLI)→ 本版
# ════════════════════════════════════════════════════════════════════════════
# 前像**独立重建**: 上面那次 update→回滚已经动过现场(快照目录、服务重启、profile 受管键),
# 在那之上接着跑, 量到的就不是"旧版机器升级"了。
echo; echo "── B. 从独立重建的前像出发, 经桥接入口两跳 ──"
# B 段**只看本阶段**: 重建成不成立、身份取没取到。上面 G 段那些红是产品侧的既有问题,
# 不是这一段的前提 —— 拿累计失败数当总闸会把独立重建的合法路径一并掐掉。
echo "   [记录] B 段的放行只取决于本阶段的重建与固定身份, 与 G 段已有的判定结果无关"
B_GO=1
if ! rml_seed_box 1 0 1; then
  bad "B-场景未执行: 独立重建前像时, 必需的模块清单或固定身份没取到(上面已具名) —— 两跳都不执行, 入口一次都不调"
  B_GO=0
fi
EXPECT_DESC="$BRIDGE_TAG"

(( B_GO == 0 )) || [[ -n "$BRIDGE_SYN_SHA" ]] \
  || { bad "B-场景未执行: 重建后的桥接提交 SHA 没取到"; B_GO=0; }
# 不预装桥接: 入口跑之前, 机器上装的必须还是 $PREV 那一份。
# 重建没成立时这台机器是半成品, 在它上面比现役 CLI 没有意义, 跳过不下结论。
if (( B_GO == 1 )); then
  if cmp -s "$E2E_TMP/cli-prev.bin" /usr/local/bin/pdg; then
    ok "B-前置: 入口执行前机器上仍是 $PREV 的 CLI(没有预装桥接或候选去替代升级)"
  else
    bad "B-场景未执行: 入口还没跑, 现役 CLI 已经不是 $PREV 的了"; B_GO=0
  fi
fi

# 入口的**实际调用记录**。前置不成立时这份记录必须是空的 —— 只记一句 bad 不算阻断。
ENTRY_CALLS="$E2E_TMP/rml-entry-calls.log"; : > "$ENTRY_CALLS"
mkdir -p "$E2E_TMP/bin"
{ printf '#!/bin/sh\n'
  printf 'printf "ENTRY\\t%%s\\n" "$*" >> "%s"\n' "$ENTRY_CALLS"
  printf 'exec "$@"\n'; } > "$E2E_TMP/bin/sudo"
chmod 755 "$E2E_TMP/bin/sudo"

FLOW="$E2E_TMP/rml-bridge-flow.sh"
B_HOP1=0
if (( B_GO == 1 )); then
  if ! git -C "$E2E_ROOT" show "$BRIDGE_SHA:docs/BRIDGE-ENTRY.md" > "$E2E_TMP/BRIDGE-ENTRY.md" 2>/dev/null; then
    bad "B-hop1-场景未执行: 取不到冻结桥接对象里的 docs/BRIDGE-ENTRY.md"
  else
    sed -n '/pdg-bridge-entry-flow: BEGIN/,/pdg-bridge-entry-flow: END/p' \
      "$E2E_TMP/BRIDGE-ENTRY.md" > "$FLOW"
    _nflow=$(grep -c . "$FLOW" || true)
    if { (( ${_nflow:-0} > 20 )) && bash -n "$FLOW"; }; then
      ok "B-hop1-流程: 从桥接对象的文档抽到完整流程(${_nflow} 行)且语法通过"
      rm -rf "$E2E_TMP/pdg-entry"
      out=$(PATH="$E2E_TMP/bin:$PATH" TAG="$BRIDGE_TAG" WANT="$BRIDGE_SYN_SHA" \
            ENTRY="$E2E_TMP/pdg-entry" SRC="$ORIGIN" bash "$FLOW" 2>&1); RC_B1=$?
      B1_OUT="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
      printf '%s\n' "$B1_OUT" > "$E2E_TMP/rml-hop1.txt"
      echo "   [记录] B-hop1: BRIDGE-ENTRY 流程原始退出码 = $RC_B1"
      _ec="$(grep -c . "$ENTRY_CALLS" || true)"
      (( ${_ec:-0} >= 1 )) && ok "B-hop1-入口: 文档原文里的提权入口确实被调到了($_ec 次)" \
        || bad "B-hop1-入口: 入口一次都没被调用, 这一跳不是走文档流程完成的"
      if [[ "$RC_B1" != 0 ]]; then
        bad "B-hop1-rc: $PREV→桥接这一跳失败(rc=$RC_B1): $(tail -5 <<<"$B1_OUT")"
        # 失败在**哪一道门**必须分清, 否则下一个人只会看到"桥接跳红了"。
        # 文档流程第 ⑧ 步预览非零就 stop, 根本不会走到第 ⑨ 步 —— 所以入口被调到两次,
        # 本身就是"预览返回 0"的直证, 拒绝出在正式执行那一步。
        if (( ${_ec:-0} >= 2 )); then
          bad "B-hop1-归属: 预览(第⑧步)放行了, 正式执行(第⑨步)才被拒 —— 预览没能替用户挡住这次失败"
        else
          bad "B-hop1-归属: 预览(第⑧步)就没过, 入口只被调 ${_ec:-0} 次"
        fi
        grep -q '身份核对通过' <<<"$B1_OUT" \
          && ok "B-hop1-身份: 入口副本的身份核对(①–⑦)是过了的, 失败不在取件/检出这一段" \
          || bad "B-hop1-身份: 入口副本的身份核对就没过, 失败在取件/检出这一段"
        # 产品那句「没动任何文件」只覆盖**受管机器**。这次拒绝之前, 文档流程第②③步已经
        # 把一整份副本取件到盘上了 —— 笼统说成"未动任何文件"会把这部分抹掉。
        if [[ -d "$E2E_TMP/pdg-entry/.git" ]]; then
          ok "B-hop1-取件: 拒绝之前取件**已经发生**($E2E_TMP/pdg-entry 里有一份完整副本) —— 「没动任何文件」只对受管机器成立"
        else
          bad "B-hop1-取件: 入口副本不在, 取件这一步的实际发生情况无从核对"
        fi
      else
        ok "B-hop1-rc: $PREV→桥接返回 0"
        _h1_ok=0; _c1_ok=0; _m1_ok=0
        if ! rml_sha "$REPO" 'HEAD^{commit}' "B-hop1-仓库:"; then
          :   # 观测无效已具名 ⇒ 这一跳的仓库身份没有结论
        elif [[ -z "$BRIDGE_SYN_SHA" ]]; then
          bad "B-hop1-仓库 **观测无效** —— 预先固定的桥接提交当初没读到, 没有可比对象"
        else
          [[ "$RML_SHA" == "$BRIDGE_SYN_SHA" ]] \
            && { ok "B-hop1-仓库: 受管仓库实际 HEAD = 预先固定的桥接提交 $BRIDGE_SYN_SHA"; _h1_ok=1; } \
            || bad "B-hop1-仓库: 实际 HEAD = $RML_SHA, 预先固定的桥接提交是 $BRIDGE_SYN_SHA"
        fi
        # 身份按**冻结桥接对象的树**核, 不按"跟仓库里那份一样"核 —— 后者是自证。
        _b_ref="$E2E_TMP/bridge-pdg.sh"
        if git -C "$E2E_ROOT" show "$BRIDGE_SHA:deploy/bot/pdg.sh" > "$_b_ref" 2>/dev/null; then
          cmp -s "$_b_ref" /usr/local/bin/pdg \
            && { ok "B-hop1-CLI: 现役 CLI 逐字节等于冻结桥接对象 ${BRIDGE_SHA:0:12} 的 pdg.sh"; _c1_ok=1; } \
            || bad "B-hop1-CLI: 现役 CLI 与冻结桥接对象的 pdg.sh 不一致"
        else
          bad "B-hop1-场景未执行: 取不到冻结桥接对象的 deploy/bot/pdg.sh ⇒ CLI 身份没有结论"
        fi
        # 模块按**桥接自己的清单**逐项核 —— "pdg.sh 一致"不等于模块装齐了。
        _mmiss=""; _mdiff=""; _mn=0
        if rml_mod_list "$REPO" "$PLAT" "B-hop1-模块:"; then
          while read -r _src _name _mode; do
            [[ -n "$_src" ]] || continue
            _mn=$((_mn+1))
            if [[ ! -f "/opt/pdg-bot/$_name" ]]; then _mmiss="$_mmiss $_name"
            elif ! cmp -s "$REPO/$_src" "/opt/pdg-bot/$_name"; then _mdiff="$_mdiff $_name"; fi
          done <<< "$RML_MODS"
          # 逐项数必须与清单条数对上 —— 对不上说明这一遍读漏了, 不能拿"漏读的那部分都对"
          # 冒充完整。项数本身不写死, 以清单当场给出的为准。
          if (( _mn != RML_MODN )); then
            bad "B-hop1-模块 **观测无效** —— 清单 $RML_MODN 条, 只比到 $_mn 项, 逐项遍历没走完"
          elif [[ -z "$_mmiss$_mdiff" ]]; then
            ok "B-hop1-模块: 桥接清单 $RML_MODN 项(生成器退出码 0)全部就位且逐字节一致"; _m1_ok=1
          else
            bad "B-hop1-模块: 桥接清单 $RML_MODN 项里 缺[$_mmiss] 不符[$_mdiff]"
          fi
        fi
        (( _h1_ok == 1 && _c1_ok == 1 && _m1_ok == 1 )) && B_HOP1=1
      fi
    else
      bad "B-hop1-场景未执行: 抽不到文档流程或语法不过(${_nflow:-0} 行)"
    fi
  fi
fi

# ── B-hop1 的救援判据: 首次启用**实际发生在这一跳**, 就在这一跳验 ───────────
# post-fault 的 EXPECT_* 说的是"那次**失败**的更新之后该是什么样", 不是"救援平面该不该
# 启用"。B 的 hop1 是一次**健康**的桥接升级, 而这一格进场就摆好了合法 bind、没记过停用
# 意图 —— 与 bind-set 同形, 首次启用在这一跳发生才是对的。拿失败那次的预期来量健康这一跳,
# 量到的是夹具的错位, 不是产品的错。
if [[ "$CASE" == post-fault ]]; then
  EXPECT_ENABLE=1; EXPECT_ON=1
  echo "   [记录] B-hop1: 本跳是健康的桥接升级, 按「有合法 bind + 无停用意图」预期首次启用"
fi
# 这一跳"完成"的条件里必须**包含救援判据**。原来只要仓库/CLI/模块三项成立就放行 hop2,
# 于是"桥接装上了但救援平面没按本格该有的样子落地"也会被当成走通 —— 下一跳的终态判据
# 就建在一个没验过的现场上。_r1 记录救援这一组有没有全成立。
_r1=1
_r1bad(){ bad "$1"; _r1=0; }
if (( B_HOP1 == 1 )); then
  _sock_unit=/etc/systemd/system/pdg-rescue.socket
  if (( EXPECT_ENABLE == 1 )); then
    grep -qE '首次启用救援平面|救援平面意图为启用但当前没起来' <<<"$B1_OUT" \
      && ok "B-hop1-救援: 这一跳确实走到了启用/恢复分支(首次启用发生在 hop1)" \
      || _r1bad "B-hop1-救援: 没走到启用/恢复分支: $(grep -n '救援' <<<"$B1_OUT" | head -3)"
  fi
  if (( EXPECT_ON == 1 )); then
    [[ "$(_intent)" == 1 ]] && ok "B-hop1-救援: profile.env 记下启用意图 PDG_RESCUE_ENABLED=1" \
      || _r1bad "B-hop1-救援: 意图是 '$(_intent)', 期望 1"
    [[ -f "$_sock_unit" ]] && ok "B-hop1-救援: pdg-rescue.socket unit 已落盘" || _r1bad "B-hop1-救援: socket unit 不在"
    systemctl is-enabled pdg-rescue.socket >/dev/null 2>&1 \
      && ok "B-hop1-救援: pdg-rescue.socket 已 enable" || _r1bad "B-hop1-救援: socket 没 enable"
  else
    [[ "$(_intent)" == "$INTENT_BEFORE" ]] \
      && ok "B-hop1-救援: 救援意图未被这一跳改动('$INTENT_BEFORE')" \
      || _r1bad "B-hop1-救援: 这一跳动了救援意图: '$INTENT_BEFORE' → '$(_intent)'"
    [[ ! -f "$_sock_unit" ]] && ok "B-hop1-救援: 没有落下 socket unit" || _r1bad "B-hop1-救援: 不该启用却装了 socket unit"
  fi
  case "$CASE" in
    bind-auto)
      grep -q "^PDG_RESCUE_BIND=$BINDADDR" "$PROF" \
        && ok "B-hop1-救援: 来源段内唯一本机地址被认定并落盘($BINDADDR)" \
        || _r1bad "B-hop1-救援: 没有落盘 bind: $(grep PDG_RESCUE_BIND "$PROF" || echo 无)";;
    disabled)
      grep -qE '首次启用救援平面' <<<"$B1_OUT" \
        && _r1bad "B-hop1-救援: 用户已明确停用, 却仍走了首次启用" \
        || ok "B-hop1-救援: 尊重停用意图, 没走首次启用";;
    no-bind)
      grep -q '未配置监听地址' <<<"$B1_OUT" \
        && ok "B-hop1-救援: 明确提示未配置监听地址" \
        || _r1bad "B-hop1-救援: 没给出原因: $(grep -n '救援' <<<"$B1_OUT" | head -3)"
      grep -q 'pdg rescue bind' <<<"$B1_OUT" \
        && ok "B-hop1-救援: 提示了怎么配(pdg rescue bind <IPv4>)" || _r1bad "B-hop1-救援: 没告诉用户怎么配";;
  esac
else
  _r1=0
fi
B_HOP1_DONE=0
(( B_HOP1 == 1 && _r1 == 1 )) && B_HOP1_DONE=1
(( B_HOP1_DONE == 1 )) \
  && ok "B-hop1-完成: 仓库落点 / CLI 身份 / 模块清单 / 本格救援判据**四组全部成立**, 这一跳才算走通" \
  || bad "B-hop1-完成: 四组里有未成立的(身份组=$B_HOP1, 救援组=$_r1) —— 这一跳不算走通"

# ── B-hop2: 由**实际已装的桥接 CLI** 升到本版 ──────────────────────────────
if (( B_HOP1_DONE == 0 )); then
  bad "B-hop2-场景未执行: 上一跳未走通, 这一跳不执行也不判定(不预装候选替代升级)"
  _ec0="$(grep -c . "$ENTRY_CALLS" 2>/dev/null)"; _ecrc=$?
  (( _ecrc <= 1 )) && echo "   [记录] 阻断之后的入口调用笔数 = ${_ec0:-0}(B 段被拦在重建/前置时应当是 0)" \
                   || echo "   [记录] 入口调用笔数读不出来(grep 退出码 $_ecrc), 不冒充 0"
  echo "   [记录] post-fault 的故障**未武装** —— 不在一个没验过的现场上制造故障再去谈回滚"
  echo "   [记录] 本格的 §1–§6(含锁继承直证)因 hop2 未执行而**未取得**"
  e2e_summary
  exit $?
fi

# post-fault: 桥接跳到这里已经**健康完成且验过**了。故障现在才给目标跳设, 于是"迁移成功
# 之后才出故障"这个前提是这一跳自己挣来的, 不是假设出来的。
# 这一跳自己的回滚目标先读 —— 读不到就整跳不执行, 连故障都不武装(不在一个说不清
# 出发点的现场上制造故障再去谈回滚)。
: > "$UPD_CALLS"
_pre_sha=""
rml_sha "$REPO" 'HEAD^{commit}' "B-hop2-前像:" && _pre_sha="$RML_SHA"
if [[ -z "$_pre_sha" ]]; then
  bad "B-hop2-场景未执行: 这一跳的前像身份没读到(上面已具名) —— **不调用**目标升级"
  echo "   [记录] 阻断之后的升级调用笔数 = $(rml_upd_n)(0 才算真的没调)"
  echo "   [记录] post-fault 的故障**未武装**; 本格的 §1–§6(含锁继承直证)**未取得**"
  e2e_summary
  exit $?
fi

if [[ "$CASE" == post-fault ]]; then
  e2e_svc_crash pdg-bot
  ok "B-hop2-前置: 桥接跳已健康完成并验过, 现在才给目标跳设置故障(pdg-bot 起不来)"
fi

# 这一跳自己的前像 —— 用户数据、指纹、残留基线全部**重新取**。
# 拿 hop1 之前那份去比, 比的是两跳的合计, 不是这一次操作。
INTENT_BEFORE="$(_intent)"
UD_BEFORE="$(_ud)"
FP_BEFORE="$(_rescue_fp)"; TOK_BEFORE="$(_rescue_tok)"; DIG_BEFORE="$(_rescue_dig)"
NR_BEFORE="$(systemctl show -p NRestarts --value mosdns 2>/dev/null || echo 0)"
TMP_BEFORE="$(ls -d $E2E_TMP/pdg-* $E2E_TMP/pdgtx-* 2>/dev/null | sort)"

echo; echo "── B-hop2: 桥接 CLI → 本版($NEW_TAG) ──"
printf 'UPDATE-B2\n' >> "$UPD_CALLS"
out=$(bash /usr/local/bin/pdg update 2>&1); rc=$?
echo "   [记录] B-hop2 升级调用笔数 = $(rml_upd_n)"
printf '%s\n' "$out" > $E2E_TMP/rml-out.txt
echo "   [记录] B-hop2: 桥接 CLI update 原始退出码 = $rc"
grep -q '不执行 WLOC 退役迁移' <<<"$out" \
  && bad "B-hop2-门: 桥接调用方交了句柄, 却仍被退役门拒绝: $(grep -n '退役' <<<"$out" | head -2)" \
  || ok "B-hop2-门: 桥接这个合法调用方没有被退役门拦住"

echo "   [记录] B-hop2-身份登记: 合成目标提交 = ${TARGET_SYN_SHA:-<没取到>}(隔离 origin 里的落点)"
echo "   [记录] B-hop2-身份登记: 冻结源码提交 = $_head_sha(这棵树取自的工作树 HEAD) —— 与上一行是两个身份"
if [[ "$rc" == 0 ]]; then
  # ── 正常成功路径: 落点 / 现役 CLI / 完整模块清单, 三项都按**预先固定**的目标核 ──
  # 不用 describe: tag 是本夹具自己打的, 拿它当身份等于自证。这里比的是完整 40 位提交。
  if ! rml_sha "$REPO" 'HEAD^{commit}' "B-hop2-仓库:"; then
    :   # 观测无效已具名
  elif [[ -z "$TARGET_SYN_SHA" ]]; then
    bad "B-hop2-仓库 **观测无效** —— 预先固定的合成目标当初没读到, 没有可比对象"
  else
    [[ "$RML_SHA" == "$TARGET_SYN_SHA" ]] \
      && ok "B-hop2-仓库: 实际 HEAD = 预先固定的合成目标 $TARGET_SYN_SHA(完整 40 位, 非 describe)" \
      || bad "B-hop2-仓库: 实际 HEAD = $RML_SHA, 预先固定的目标是 $TARGET_SYN_SHA"
  fi
  cmp -s "$E2E_TMP/cli-cand.bin" /usr/local/bin/pdg \
    && ok "B-hop2-CLI: 现役 CLI 逐字节等于**冻结源码**那一份 deploy/bot/pdg.sh" \
    || bad "B-hop2-CLI: 现役 CLI 与冻结源码那一份 pdg.sh 不一致"
  # 模块按候选**自己的完整清单**逐项核 —— 少一项、内容差一个字节都不算装齐。
  _m2miss=""; _m2diff=""; _m2n=0
  if rml_mod_list "$REPO" "$PLAT" "B-hop2-模块:"; then
    while read -r _src _name _mode; do
      [[ -n "$_src" ]] || continue
      _m2n=$((_m2n+1))
      if [[ ! -f "/opt/pdg-bot/$_name" ]]; then _m2miss="$_m2miss $_name"
      elif ! cmp -s "$REPO/$_src" "/opt/pdg-bot/$_name"; then _m2diff="$_m2diff $_name"; fi
    done <<< "$RML_MODS"
    if (( _m2n != RML_MODN )); then
      bad "B-hop2-模块 **观测无效** —— 清单 $RML_MODN 条, 只比到 $_m2n 项, 逐项遍历没走完"
    elif [[ -z "$_m2miss$_m2diff" ]]; then
      ok "B-hop2-模块: 本版清单 $RML_MODN 项(生成器退出码 0)全部就位且逐字节一致"
    else
      bad "B-hop2-模块: 本版清单 $RML_MODN 项里 缺[$_m2miss] 不符[$_m2diff]"
    fi
  fi
else
  # ── post-fault: 这一跳自己的回滚目标是**桥接**, 不是候选 ──────────────────
  # 不能拿"成功路径的目标身份"去要求它 —— 那等于要求一次回滚之后还停在候选。
  if ! rml_sha "$REPO" 'HEAD^{commit}' "B-hop2-回滚:"; then
    :   # 观测无效已具名
  else
    _t_now="$RML_SHA"
    if [[ -z "$BRIDGE_SYN_SHA" ]]; then
      bad "B-hop2-回滚 **观测无效** —— 这一跳的出发点(桥接提交)当初没读到, 没有可比对象"
    else
      [[ "$_t_now" == "$BRIDGE_SYN_SHA" ]] \
        && ok "B-hop2-回滚: 本次操作的回滚目标是**这一跳的出发点(桥接 $BRIDGE_SYN_SHA)**, 实际 HEAD 与之相符" \
        || bad "B-hop2-回滚: 实际 HEAD = $_t_now, 本次操作的出发点是 $BRIDGE_SYN_SHA"
    fi
    if [[ -z "$TARGET_SYN_SHA" ]]; then
      bad "B-hop2-回滚 **观测无效** —— 候选目标当初没读到, 「有没有停在候选」这条没有可比对象"
    else
      [[ "$_t_now" != "$TARGET_SYN_SHA" ]] \
        && ok "B-hop2-回滚: 回滚之后**没有**停在候选 —— 这正是回滚该有的样子, 不按成功路径的目标去要求它" \
        || bad "B-hop2-回滚: 自报回滚, 却仍停在候选目标 $TARGET_SYN_SHA"
    fi
  fi
fi

# 首次启用已经在 hop1 具名验过了 —— 这里**不**再要求 hop2 打印一次"首次启用",
# 更不拿 hop2 的输出去冒称覆盖了首次启用。终态判据(EXPECT_ON 那一组)照常全验。
EXPECT_ENABLE=0
fi

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
  [[ "$(git -C "$REPO" describe --tags 2>/dev/null)" == "$EXPECT_DESC" ]] \
    && ok "describe 回到 $EXPECT_DESC(本次操作的出发点)" \
    || bad "describe=$(git -C "$REPO" describe --tags 2>/dev/null), 期望 $EXPECT_DESC"
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
      # 这一格在**每一跳**都该给出这条提示, 两跳都验不算重复: 没有可用监听地址时救援迁移
      # 什么也没完成, 下一次更新照样要从头判一遍。真正只属于"首次"的那条(走没走启用分支)
      # 由 B-hop1 具名验, 这里不碰。
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

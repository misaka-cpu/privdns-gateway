#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ④: **退役成功之后的晚期失败 → 产品自己回滚到本次快照**。
#
# 前像从哪来: **同一 job、同一 runner** 上, 上一步原样跑完的 tests/e2e-real-bridge-hop.sh(②)。
# 本支不自己造桥接现场、不预先跑一次成功的 ③ 再从退役终态起跑; 起跑前把桥接前像逐项现查一遍。
#
# 故障点(328 选定, 源码依据写在判据旁): 退役版 migrate_ios_gms_cleanup 在动手之前对事务目标做形态守卫,
# 目标是硬链接(nlink≠1)时具名拒绝并返回 1。它排在 migrate_wloc_retire **之后**, 于是:
#   WLOC 退役已经成功提交 → GMS 清理被拒 → run_all_migrations 返回非 0 → __migrate 非 0
#   → 桥接版 cmd_update 自己调 cmd_rollback --dir <本次快照> --git <升级前 HEAD>。
# 测试动作只有一件: 调用前给 /etc/nftables.conf 建**一个**受登记的硬链接(同设备、在全部快照候选路径之外)。
# 不改产品源码、不伪造句柄或 svcstate、不把迁移换成恒失败函数、不手动 rollback、不在判定前修补失败现场。
# 那个链接**不是备份**: 本支绝不从它恢复任何文件; 产品原地写会穿透到它, 它里面是迁移后的内容。
#
# 三段结算(判据全部事先从冻结源码推导; 不看结果再补允许清单):
#   A 调用前: 桥接身份、WLOC 开着、前像文件清单(摘要/属性, 不打印私钥与 token 正文)、服务与自启、
#            真实功能、运行中的防火墙、快照目录集合、注入登记、GMS 触发前提。
#   B 退役成功与故障命中: 有序且具名的四个标记(退役成功 → 硬链接拒绝 → 迁移失败触发回滚 → 回滚到本次快照),
#            配 pdg-mitm 的停止与恢复启动记录。没命中、提前失败、超时、观测失败、意外升级成功都不算有效 ④。
#   C 自动回滚后: 本次新建快照与它自己的 svcstate 绑定、HEAD/CLI/受管模块回到桥接、WLOC 组件与 iOS 记录/产物、
#            保留数据、服务与真实功能、**独立**核运行中的防火墙(回滚吞掉了 nft 失败, 不能只信文案)。
#            产品返回 1 与包装器状态单独登记 —— 它们都不能代替"回滚成功"。
#
# 观测有效性: 每一次读取都先看它自己的退出码与格式, 读失败 / 半截输出**不消费**, 也不当成"零"或"原样"。
# 不覆盖: v1.7.8、完整旧安装器、官方分发来源、发布。前提缺一即硬停, 不 SKIP; 只许在一次性 GitHub runner 上跑。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

EVID="${PDG_LATE_FAIL_EVID:-/tmp/real-acceptance-evidence-late}"
# shellcheck disable=SC2034  # 由运行时 source 进来的 ③ r3_count 段消费(静态看不到)
R3_COUNT="$EVID/00-late-invoke-count.txt"        # 复用 ③ 的 r3_count 段(同一变量名), 计数落在 ④ 自己的证据目录

_hard(){ echo "[HARD-STOP] $1" >&2
  if declare -F r3_count_read >/dev/null && r3_count_read; then echo "升级调用次数(计数文件) = $R3_VAL" >&2
  else echo "升级调用次数: 计数读不出来(${R3_WHY:-计数读取器还没装好})" >&2; fi
  exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
R4_TMP="$(mktemp -d "${TMPDIR:-/tmp}/r4.XXXXXX")" || _hard "建不出本支临时目录"
R3_TMP="$R4_TMP"                            # 被抽取的 ③ 段按 $R3_TMP 落临时物
E2E_TMP="$R4_TMP"; export E2E_TMP

# ── 复用: 只按唯一成对标记抽, 不 source 整支, 不复制函数正文 ────────────────────
HOP2_SRC="$E2E_ROOT/tests/e2e-real-bridge-hop.sh"
PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
R3_SRC="$E2E_ROOT/tests/e2e-real-retire-hop.sh"
# >>> PDG-EXTRACT-BEGIN r4_seed
# 引导的引导: 先把 ③ 的抽取器原文(r3_bootstrap)取出来, 之后一律用它按标记抽。
# 这一段是本支唯一手写的取原文代码, 判据与 r3_bootstrap 相同: 标记唯一成对、之间非空。
r4_seed(){   # $1=名字 $2=来源 → 打印标记之间的原文
  local n="$1" src="$2" b e
  [[ -f "$src" ]] || { echo "引导: 找不到 $src" >&2; return 2; }
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] \
    || { echo "引导: $n 的标记不是唯一成对" >&2; return 1; }
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || { echo "引导: $n 的标记之间是空的" >&2; return 1; }
  sed -n "$((b+1)),$((e-1))p" "$src"
}
# <<< PDG-EXTRACT-END r4_seed
r4_seed r3_bootstrap "$R3_SRC" > "$R4_TMP/boot.sh" && bash -n "$R4_TMP/boot.sh" \
  || _hard "抽取器引导失败 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$R4_TMP/boot.sh"
r3_bootstrap "$HOP2_SRC" "$R4_TMP/extractor.sh" extract_marked_fns extract_marked_decls \
  || _hard "② 的抽取器没通过 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$R4_TMP/extractor.sh"
extract_marked_fns "$PLAT_SRC" "$R4_TMP/plat-fns.sh" _ev _evn SECT note sc_get sc_state nrun snap_state \
    wait_stable unit_identify _unit_wants_mainpid svc_stable_window svc_stable_assert mitm_listen_verdict \
    _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after _j_tag_after _j_interval \
  || _hard "platform-fail 函数抽取没通过 —— 还没碰任何服务"
extract_marked_decls "$PLAT_SRC" "$R4_TMP/plat-deps.sh" E2E_OWNED_UNITS SVC_WATCH \
  || _hard "platform-fail 依赖抽取没通过"
extract_marked_fns "$HOP2_SRC" "$R4_TMP/hop2-fns.sh" bridge_svc_sample bridge_row_valid \
  || _hard "② 函数抽取没通过"
# ③ 的判据段: 按标记原样抽来用(不改一个字)。④ 不抽 ③ 的 r3_arrival_verdict / r3_post / r3_svc_* /
# r3_gated_invoke —— 那几段说的是"到达退役终态", 与 ④ 期望的"回到桥接前像"相反, 本支另写。
r3_bootstrap "$R3_SRC" "$R4_TMP/r3fns.sh" \
    r3_count r3_read r3_real2_gate r3_bridge_identity_gate r3_keep r3_precapture r3_invoke \
    r3_stable r3_dns r3_quiesce r3_runtime_gate \
  || _hard "③ 判据段抽取没通过 —— 还没碰任何服务"
# shellcheck source=/dev/null
source "$R4_TMP/plat-fns.sh"; source "$R4_TMP/plat-deps.sh"; source "$R4_TMP/hop2-fns.sh"; source "$R4_TMP/r3fns.sh"
# shellcheck disable=SC2034
JBOUND_TAG="pdg-e2e-jbound-r4"
# shellcheck disable=SC2034
J_ERR=""
E2E_NOTRUN=0

{ mkdir -p "$EVID" && chmod 700 "$EVID"; } 2>/dev/null \
  || _hard "证据目录 $EVID 建不出来 —— 调用计数无处可落, 不调用"
r3_count_init || _hard "调用计数初始化失败: $R3_WHY —— 不调用"   # 任何门之前先落 0 并读回

# ── 输入 ────────────────────────────────────────────────────────────────────
# 下面这一组里有不少是给**抽取进来的 ③ 判据段**用的: 它们在运行时 source, ShellCheck 静态看不到使用点,
# 所以整组关掉 SC2034。**绝不 export** —— 一旦导出就会进到产品子进程的环境里, 那等于改了被测对象。
# shellcheck disable=SC2034
{
BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"
[[ "$BRIDGE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位桥接 SHA(PDG_BRIDGE_SHA)"
[[ "$RETIRE_SHA" =~ ^[0-9a-f]{40}$ ]] || _hard "必须显式给出 40 位退役候选 SHA(PDG_RETIRE_SHA)"
BRIDGE_TAG="v9.9.8-bridge-TEST"; RETIRE_TAG="v9.9.9-retire-TEST"   # 与 ② 的合成 tag 同名; 身份由 B8 现查
R3_REAL2_LOG="${PDG_REAL2_LOG:-}"
R3_REPO=/opt/privdns-gateway; R3_CLI=/usr/local/bin/pdg; R3_MODDIR=/opt/pdg-bot; R3_ETC=/etc/privdns-gateway
R3_OBJ="$E2E_ROOT"
R3_LOG="$R4_TMP/late-update.log"; R3_TIMEOUT="${PDG_LATE_FAIL_TIMEOUT:-900}"
R3_RCFILE="$R4_TMP/late-update.rc"; R3_TOERR="$R4_TMP/late-update.timeout-stderr"
R3_BRSRC="$R4_TMP/brsrc"; R3_RTSRC="$R4_TMP/rtsrc"
SNAPROOT=/var/lib/privdns-gateway/backups
IOS_META=/etc/privdns-gateway/ios-profile.json; IOS_ART=/var/lib/privdns-gateway/ios-profile
MJ=/etc/privdns-gateway/mitm.json; HIJ=/etc/mosdns/rules/mitm_hijack.txt; MC=/etc/mihomo/config.yaml
CA_DIR=/etc/privdns-gateway/ca
R3_MITM_UNIT=/etc/systemd/system/pdg-mitm.service
KREQ=("$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$R3_ETC/platform")
KOPT=("$R3_ETC/bot.env" "$R3_MODDIR/dot-domain")
declare -A KFP=()
R3_DNS_U=198.51.100.7; R3_DNS_PORT=15301; R3_DNS_W=gs-loc.apple.com
R3_STUB="$E2E_ROOT/tests/helpers/dns-stub.py"; R3_STUB_PID=""; R3_DNS_RESTARTS=0
R3_UPLOG="$R4_TMP/dns-up.log"; R3_UPCNT="$R4_TMP/dns-up.count"; R3_UPOUT="$R4_TMP/dns-up.out"
R3_MONO=(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
R3_MOSCFG=/etc/mosdns/config.yaml; R3_GEOCN=/etc/mosdns/rules/geosite_cn.txt
_sfx="$$-$RANDOM"
R3_DNS_K="r4k-$_sfx.e2e.test"; R3_DNS_CPRE="r4c-pre-$_sfx.e2e.test"; R3_DNS_CPOST="r4c-post-$_sfx.e2e.test"
R3_DNS_PPRE="r4p-pre-$_sfx.e2e.test"; R3_DNS_PPOST="r4p-post-$_sfx.e2e.test"
}

# ── ④ 自己的判据 ──────────────────────────────────────────────────────────────
# >>> PDG-EXTRACT-BEGIN r4_fs
# 前像文件清单。覆盖范围 = 桥接版 cmd_snapshot 的候选集合(那是"回滚能还原的全部路径"), 逐条抄自
# 冻结桥接 pdg.sh 的 `local cand=(…)`; 不多收也不少收 —— 少收就会漏掉"该还原却没还原"的东西。
# 只记类型 / mode / 属主 / sha256(与链接目标), **不记内容** —— 里面有 CA 私钥与 bot token。
R4_SNAP_PATHS=(etc/mosdns etc/sing-box etc/mihomo opt/pdg-bot etc/privdns-gateway etc/nftables.conf
               var/lib/privdns-gateway/ios-profile
               etc/systemd/system/pdg-bot.service etc/systemd/journald.conf.d/50-pdg.conf
               etc/systemd/system/journald.conf.d/50-pdg.conf
               etc/systemd/system/mihomo.service etc/systemd/system/sing-box.service
               etc/systemd/system/pdg-mitm.service etc/systemd/system/pdg-probe81.service
               etc/systemd/system/pdg-dotwitness.service
               etc/systemd/system/pdg-rules-update.service etc/systemd/system/pdg-rules-update.timer
               etc/systemd/system/pdg-health.service etc/systemd/system/pdg-health.timer
               etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh
               usr/local/bin/pdg usr/local/bin/pdg-set-token
               usr/local/bin/mosdns usr/local/bin/mihomo usr/local/bin/sing-box
               usr/local/bin/proxy-gateway-open-cert-http.sh usr/local/bin/proxy-gateway-restore-firewall.sh)
r4_fs_one(){   # $1=路径 → 打印一行 "<类型> <mode> <uid:gid> <sha256|link:目标|-> <路径>"; 任一项查询失败 ⇒ 2
  # 330: 类型 / mode / 属主 / 摘要 / 链接目标**各自**核退出码 —— 先输出合法值再失败的那一次不消费。
  #      摘要不再走 `sha256sum | cut` 管道(管道里前一段的失败会被后一段的成功盖住)。
  local ty mode own sha rc
  ty="$(stat -c %F -- "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ -n "$ty" && "$ty" != *$'\n'* ]] || { R3_WHY="$1 的类型查询失败(stat rc=$rc, 实得 [${ty:0:30}])"; return 2; }
  # mode 000 的 stat -c %a 就是 "0"(合法取值), 所以是 {1,4} 不是 {3,4}
  mode="$(stat -c %a -- "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$mode" =~ ^[0-7]{1,4}$ ]] || { R3_WHY="$1 的 mode 查询失败(stat rc=$rc, 实得 [${mode:0:10}])"; return 2; }
  own="$(stat -c '%u:%g' -- "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$own" =~ ^[0-9]+:[0-9]+$ ]] || { R3_WHY="$1 的属主查询失败(stat rc=$rc, 实得 [${own:0:20}])"; return 2; }
  case "$ty" in
    "symbolic link")
      sha="$(readlink -- "$1" 2>/dev/null)"; rc=$?
      (( rc == 0 )) && [[ -n "$sha" ]] || { R3_WHY="$1 的链接目标查询失败(readlink rc=$rc)"; return 2; }
      sha="link:$sha";;
    "regular file"|"regular empty file")
      sha="$(sha256sum -- "$1" 2>/dev/null)"; rc=$?; sha="${sha%% *}"
      (( rc == 0 )) && [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { R3_WHY="$1 的摘要查询失败(sha256sum rc=$rc)"; return 2; };;
    *) sha="-";;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "${ty// /_}" "$mode" "$own" "$sha" "$1"
}
r4_fs_manifest(){   # $1=落点 → 0 全部取得 / 2 任一读不了(不写半份清单; 读失败不当成"这个文件不在")
  local p list f tmp; tmp="$R3_TMP/fs.$$.$RANDOM"
  : > "$tmp" || { R3_WHY="清单临时文件写不出来"; return 2; }
  for p in "${R4_SNAP_PATHS[@]}"; do
    [[ -e "$R4_ROOT/$p" || -L "$R4_ROOT/$p" ]] || continue
    list="$(find "$R4_ROOT/$p" 2>/dev/null)" || { R3_WHY="find 失败: $R4_ROOT/$p"; return 2; }
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      r4_fs_one "$f" >> "$tmp" || return 2
    done <<<"$list"
  done
  [[ -s "$tmp" ]] || { R3_WHY="前像清单是空的(候选路径一个都不在?)"; return 2; }
  LC_ALL=C sort -t$'\t' -k5 "$tmp" > "$1" || { R3_WHY="清单排序写出失败"; return 2; }
}
# 允许差异清单(**运行前**由冻结源码推出; 运行后不得往里加)。每条都要有依据:
#   · /etc/nftables.conf.pre-tplsync —— 退役版 migrate_firewall_template_sync 的备份(T:874 `local bak="$f.pre-tplsync"`),
#     它不是快照成员, 而快照落盘只覆盖成员、不删非成员(桥接 B:1859 `tar xpf -`), 所以回滚后会留下。
#   · /opt/pdg-bot/__pycache__/** —— 迁移期间 python 导入 /opt/pdg-bot 下模块时生成; 同样不是快照成员。
# 其余任何新增 / 消失 / 内容或属性变化都判不成立, 并把路径点名报出来(不自动接受)。
# 匹配的是**去掉 R4_ROOT 前缀之后**的路径(生产前缀是空串, 于是就是绝对路径本身)。
R4_ALLOW_NEW=('^/etc/nftables\.conf\.pre-tplsync$' '^/opt/pdg-bot/__pycache__(/|$)')
r4_fs_diff(){   # $1=前像清单 $2=调用后清单 → 0 只有允许差异 / 1 有清单外差异(R3_WHY 点名) / 2 比不了
  # 330: 两侧排序各自落文件并核退出码, 再 join 两个文件 —— 以前排序写在进程替换里, 它的失败看不见,
  #      一侧排序失败时 join 拿到空输入, "内容变了"就漏掉了。每一步都不依赖调用方开没开 pipefail。
  local a b sa sb raw j only_a only_b chg pat p keep why="" rc
  [[ -s "$1" && -s "$2" ]] || { R3_WHY="清单缺失或为空"; return 2; }
  a="$R3_TMP/fs.a.$$"; b="$R3_TMP/fs.b.$$"; sa="$R3_TMP/fs.sa.$$"; sb="$R3_TMP/fs.sb.$$"; raw="$R3_TMP/fs.raw.$$"; j="$R3_TMP/fs.j.$$"
  cut -f5 "$1" > "$raw"; rc=$?; (( rc == 0 )) || { R3_WHY="前像路径列取不出来(cut rc=$rc)"; return 2; }
  LC_ALL=C sort "$raw" > "$a"; rc=$?; (( rc == 0 )) || { R3_WHY="前像路径列排序失败(sort rc=$rc)"; return 2; }
  cut -f5 "$2" > "$raw"; rc=$?; (( rc == 0 )) || { R3_WHY="调用后路径列取不出来(cut rc=$rc)"; return 2; }
  LC_ALL=C sort "$raw" > "$b"; rc=$?; (( rc == 0 )) || { R3_WHY="调用后路径列排序失败(sort rc=$rc)"; return 2; }
  only_b="$(LC_ALL=C comm -13 "$a" "$b")"; rc=$?; (( rc == 0 )) || { R3_WHY="comm(新增)失败(rc=$rc)"; return 2; }
  only_a="$(LC_ALL=C comm -23 "$a" "$b")"; rc=$?; (( rc == 0 )) || { R3_WHY="comm(消失)失败(rc=$rc)"; return 2; }
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    keep=0; for pat in "${R4_ALLOW_NEW[@]}"; do [[ "${p#"$R4_ROOT"}" =~ $pat ]] && { keep=1; break; }; done
    (( keep )) || why="$why 新增 [$p];"
  done <<<"$only_b"
  while IFS= read -r p; do [[ -n "$p" ]] && why="$why 消失 [$p];"; done <<<"$only_a"
  LC_ALL=C sort -t$'\t' -k5 "$1" > "$sa"; rc=$?; (( rc == 0 )) || { R3_WHY="前像清单按路径排序失败(sort rc=$rc)"; return 2; }
  LC_ALL=C sort -t$'\t' -k5 "$2" > "$sb"; rc=$?; (( rc == 0 )) || { R3_WHY="调用后清单按路径排序失败(sort rc=$rc)"; return 2; }
  LC_ALL=C join -t$'\t' -j 5 -o 0,1.1,1.2,1.3,1.4,2.1,2.2,2.3,2.4 "$sa" "$sb" > "$j" 2>/dev/null; rc=$?
  (( rc == 0 )) || { R3_WHY="逐项配对失败(join rc=$rc)"; return 2; }
  chg="$(awk -F'\t' '$2!=$6 || $3!=$7 || $4!=$8 || $5!=$9 {print $1}' "$j")"; rc=$?
  (( rc == 0 )) || { R3_WHY="逐项比对失败(awk rc=$rc)"; return 2; }
  while IFS= read -r p; do [[ -n "$p" ]] && why="$why 内容或属性变了 [$p];"; done <<<"$chg"
  [[ -z "$why" ]] || { R3_WHY="${why# }"; return 1; }
}
# <<< PDG-EXTRACT-END r4_fs
# >>> PDG-EXTRACT-BEGIN r4_fw
# 运行中的防火墙必须**独立**核: 桥接版 cmd_rollback 对 `_nft_apply_main` 是 `|| true`(B:1876), 失败不进
# "未完成项", 所以"✅ 已回滚"这句话本身证明不了内核里的规则回来了。
# 不做任何字段过滤: 本项目模板里没有 counter / quota(冻结退役 deploy/firewall/nftables-mihomo.conf 里
# `counter` 出现 0 次), 也不加 `-a`(不取 handle), 所以原文可以直接逐字比。真要出现不稳定字段, 由下面这条
# "连取两次必须逐字相同"先判观测无效, 而不是滤掉差异去凑相等。
r4_fw_live(){   # → 0 取得(R3_VAL=运行中 inet pdg 表原文) / 2 观测无效
  local a b rc
  R3_VAL=""
  a="$(nft list table inet pdg 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="nft list table inet pdg 退出 $rc(它打印的内容不采信)"; return 2; }
  [[ -n "$a" ]] || { R3_WHY="nft list table inet pdg 退出 0 但输出为空"; return 2; }
  b="$(nft list table inet pdg 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="nft 第二次读取退出 $rc"; return 2; }
  [[ "$a" == "$b" ]] || { R3_WHY="同一配置连取两次不一致 —— 运行态文本不稳定, 不作逐字比对依据"; return 2; }
  R3_VAL="$a"
}
# <<< PDG-EXTRACT-END r4_fw
# >>> PDG-EXTRACT-BEGIN r4_inject
# 注入: 给 /etc/nftables.conf 建**一个**硬链接。它是本支唯一的测试动作, 也是产品自己定义为
# "不安全的事务目标"并具名拒绝的现场条件(退役版 migrate_ios_gms_cleanup: `stat -c '%h'` ≠ 1 ⇒
# 打印"是硬链接(nlink=N), 改它会波及另一个名字 → 未改动任何文件"并 return 1)。
R4_ROOT="${PDG_LATE_FAIL_ROOT:-}"      # 测试用的整体前缀; 生产为空串(与产品 PDG_RETIRE_ROOT 同款约定, 行为不变)
R4_TARGET="$R4_ROOT/etc/nftables.conf"
R4_LINK_DIR="$R4_ROOT/var/lib/pdg-accept4"
R4_LINK="$R4_LINK_DIR/nftables.conf.link"
R4_INJ=""                      # 登记的 设备:inode; 空 = 没有建立(善后据此不动任何东西)
r4_trigger_ready(){   # GMS 清理的触发前提(见 T:5890/T:5902)→ 0 成立 / 1 有效答案: 不成立 / 2 观测无效(前提判不了, 同样不注入)
  # 330: 否定查询分清"没匹配"(答案)与"查询失败"(观测无效)。以前 `grep … && 拒绝` 把 grep 出错当成
  #      "没有救援标记 / 没配监听地址"放行, 5228 查询出错则被说成"没有 5228 端口集"。
  local plat rc pe
  plat="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="平台标记读不了(cat rc=$rc)"; return 2; }
  [[ "$plat" == ios ]] || { R3_WHY="平台是 [$plat], GMS 清理只在 ios 上动手"; return 1; }
  [[ -f "$R4_TARGET" ]] || { R3_WHY="$R4_TARGET 不在"; return 1; }
  r3_grepq -E 'tcp dport [{][^}]*5228' "$R4_TARGET"; rc=$?
  case "$rc" in
    0) ;;
    1) R3_WHY="$R4_TARGET 里没有 5228 端口集 —— 本次不会走到 GMS 清理"; return 1;;
    *) R3_WHY="5228 端口集查询失败($R3_WHY) —— 触发前提判不了"; return 2;;
  esac
  # 救援平面若被启用, 它的放行/摘除走 `mv -f`(T:7023 / T:7042), 会换掉目标 inode, 链接就活不到 GMS 那一步。
  r3_grepq -F 'comment "pdg-rescue"' "$R4_TARGET"; rc=$?
  case "$rc" in
    0) R3_WHY="防火墙里有 pdg-rescue 标记规则 —— 救援平面已启用, 目标 inode 可能被换掉"; return 1;;
    1) ;;
    *) R3_WHY="救援标记查询失败($R3_WHY) —— 不能当成「没有标记」"; return 2;;
  esac
  pe="$R3_ETC/profile.env"
  if [[ -e "$pe" || -L "$pe" ]]; then
    r3_grepq -E '^[[:space:]]*PDG_RESCUE_BIND=[^[:space:]]' "$pe"; rc=$?
    case "$rc" in
      0) R3_WHY="profile.env 里配了 PDG_RESCUE_BIND —— 救援平面会被启用"; return 1;;
      1) ;;
      *) R3_WHY="profile.env 在却查不了($R3_WHY) —— 不能当成「没配监听地址」"; return 2;;
    esac
  fi                                  # 文件不存在 = 没配(答案), 与产品读 profile.env 的语义一致
  return 0
}
r4_inject_create(){   # → 0 已建立并核过(R4_INJ=设备:inode) / 1 前提不成立或观测失败, 未建立 / 3 建了但核验不过或核验查询失败(已按登记善后)
  # 330: 每一次 stat 都核退出码与格式 —— 设备号或 nlink 先输出合法值再失败, 以前会被当成"同设备""nlink=2"。
  local i0 dt dl a b ra rb rc p
  R4_INJ=""
  [[ -f "$R4_TARGET" && ! -L "$R4_TARGET" ]] || { R3_WHY="$R4_TARGET 不是普通文件"; return 1; }
  i0="$(stat -c '%d:%i:%h' -- "$R4_TARGET" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$i0" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || { R3_WHY="$R4_TARGET 的身份查询失败(stat rc=$rc, 实得 [${i0:0:40}]) —— 不注入"; return 1; }
  [[ "${i0##*:}" == 1 ]] || { R3_WHY="$R4_TARGET 的 nlink 是 ${i0##*:}(不是 1)—— 现场本来就有别的名字指着它, 不在这种现场上注入"; return 1; }
  { mkdir -p "$R4_LINK_DIR" && chmod 700 "$R4_LINK_DIR"; } 2>/dev/null || { R3_WHY="建不出注入目录 $R4_LINK_DIR"; return 1; }
  # 注入位置必须在**全部快照候选路径之外**: 在里面的话它会被打进快照, 回滚时又被原样还原回来。
  for p in "${R4_SNAP_PATHS[@]}"; do
    [[ "$R4_LINK" == "$R4_ROOT/$p" || "$R4_LINK" == "$R4_ROOT/$p/"* ]] && { R3_WHY="注入位置 $R4_LINK 落在快照候选路径 $R4_ROOT/$p 里"; return 1; }
  done
  dt="$(stat -c %d -- "$R4_TARGET" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$dt" =~ ^[0-9]+$ ]] || { R3_WHY="目标设备号查询失败(stat rc=$rc) —— 不注入"; return 1; }
  dl="$(stat -c %d -- "$R4_LINK_DIR" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$dl" =~ ^[0-9]+$ ]] || { R3_WHY="注入目录设备号查询失败(stat rc=$rc) —— 同设备判不了, 不注入"; return 1; }
  [[ "$dt" == "$dl" ]] || { R3_WHY="注入目录与目标不同设备(目标 $dt, 目录 $dl) —— 硬链接建不了"; return 1; }
  [[ ! -e "$R4_LINK" && ! -L "$R4_LINK" ]] || { R3_WHY="注入位置 $R4_LINK 已经被占"; return 1; }
  ln -- "$R4_TARGET" "$R4_LINK" 2>/dev/null || { R3_WHY="ln 失败"; return 1; }
  R4_INJ="${i0%:*}"
  a="$(stat -c '%d:%i:%h' -- "$R4_TARGET" 2>/dev/null)"; ra=$?
  b="$(stat -c '%d:%i' -- "$R4_LINK" 2>/dev/null)"; rb=$?
  if (( ra != 0 || rb != 0 )) || [[ "$a" != "$R4_INJ:2" || "$b" != "$R4_INJ" ]]; then
    R3_WHY="建完核验不过或核验查询失败(目标 stat rc=$ra [$a], 链接 stat rc=$rb [$b])"
    r4_inject_remove >/dev/null; return 3
  fi
}
r4_inject_remove(){   # 只按登记身份删自己那一个 → 0 已删 / 1 本来就没建立或已不在 / 2 身份不符或删不掉, 没删 / 3 身份查询失败, 没删
  # 330: 身份查询先输出"对得上"再失败时, 以前照样删; 现在身份判不了就不删, 具名留给人看。
  local id rc
  [[ -n "$R4_INJ" ]] || { echo "没有登记过注入, 不动任何东西"; return 1; }
  [[ -e "$R4_LINK" || -L "$R4_LINK" ]] || { echo "登记的链接 $R4_LINK 已经不在(不是本支删的)"; R4_INJ=""; return 1; }
  [[ ! -L "$R4_LINK" ]] || { echo "链接路径现在是符号链接 —— 与登记不符, **没有删**, 留给人看"; return 2; }
  id="$(stat -c '%d:%i' -- "$R4_LINK" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$id" =~ ^[0-9]+:[0-9]+$ ]] || { echo "链接身份查询失败(stat rc=$rc, 实得 [${id:0:30}]) —— 身份判不了, **没有删**, 留给人看"; return 3; }
  [[ "$id" == "$R4_INJ" ]] || { echo "链接身份与登记不符(现为 $id, 登记 $R4_INJ)—— **没有删**, 留给人看"; return 2; }
  rm -f -- "$R4_LINK" 2>/dev/null || { echo "删除 $R4_LINK 失败"; return 2; }
  [[ ! -e "$R4_LINK" && ! -L "$R4_LINK" ]] || { echo "删除之后 $R4_LINK 还在"; return 2; }
  R4_INJ=""; echo "已按登记删除 $R4_LINK"
}
# <<< PDG-EXTRACT-END r4_inject
# >>> PDG-EXTRACT-BEGIN r4_pre
r4_precapture(){   # ④ 自己的调用前观测(在 ③ 的 r3_precapture 之前跑)→ 0 全取得 / 1 有没取到的
  local st=0
  if r4_fs_manifest "$R4_TMP/fs-before.tsv"; then
    echo "  E 前像文件清单已取得($(grep -c . "$R4_TMP/fs-before.tsv") 条; 只记类型/mode/属主/摘要, 不记内容)"
    r3_copy_record "$R4_TMP/fs-before.tsv" "$EVID/01-fs-before.tsv" || { echo "  E 前像清单留证失败: $R3_WHY"; st=1; }
  else echo "  E 前像文件清单没取得: $R3_WHY"; st=1; fi
  if r4_fw_live; then
    R4_FW_BEFORE="$R3_VAL"
    printf '%s\n' "$R4_FW_BEFORE" > "$EVID/02-fw-before.txt" 2>/dev/null \
      && echo "  E 运行中防火墙原文已取得($(grep -c . <<<"$R4_FW_BEFORE") 行, 连取两次逐字相同)" \
      || { echo "  E 运行中防火墙留证写不出来"; st=1; }
  else echo "  E 运行中防火墙没取得: $R3_WHY"; st=1; fi
  if r3_lsdir "$SNAPROOT"; then R4_SNAP_BEFORE="$R3_VAL"; echo "  E 快照目录清单已取得(${R3_NOTE:-$(grep -c . <<<"$R4_SNAP_BEFORE") 项})"
  else echo "  E 快照目录清单没取得: $R3_WHY"; st=1; fi
  return "$st"
}
r4_inject_stage(){   # 触发前提 + 建立注入 + 登记 → 0 成立 / 1 不成立(已按登记善后)
  local rc
  r4_trigger_ready; rc=$?
  case "$rc" in
    0) ;;
    1) bad "④-0 注入前提不成立: $R3_WHY —— 不注入、不调用"; return 1;;
    *) bad "④-0 注入前提观测无效: $R3_WHY —— 不注入、不调用"; return 1;;
  esac
  ok "④-0 GMS 清理的触发前提成立(平台 ios; $R4_TARGET 里有 5228 端口集; 救援平面未启用 ⇒ 没有已知路径会换掉目标 inode)"
  r4_inject_create; rc=$?
  case "$rc" in
    0) ;;
    3) bad "④-0 注入建立后核验不过: $R3_WHY —— 已按登记善后, 不调用"; return 1;;
    *) bad "④-0 注入未建立: $R3_WHY —— 不调用"; return 1;;
  esac
  { echo "# ④ 的唯一测试动作: 给 $R4_TARGET 建一个硬链接, 让退役版 migrate_ios_gms_cleanup 的形态守卫真实拒绝"
    echo "目标 = $R4_TARGET; 链接 = $R4_LINK; 登记身份(设备:inode) = $R4_INJ; 建立后核验 nlink = 2"
    echo "链接**不是备份**: 产品原地写会穿透到它, 本支绝不从它恢复任何文件; 撤除只按登记身份删这一个"
  } > "$EVID/03-injection.txt" 2>/dev/null || { bad "④-0 注入登记写不进证据目录"; r4_inject_remove >/dev/null; return 1; }
  ok "④-0 注入已建立并核过: $R4_TARGET 与 $R4_LINK 同 inode($R4_INJ), nlink=2(登记见 03-injection.txt)"
}
r4_gated_invoke(){   # 门全过、注入成立、调用前观测取全才调用。返回(10–18 都**没有**调用):
                     #   10=② 结果门 11=桥接身份门 15=DNS 仪器 16=准备阶段静置 12=运行态 / WLOC 前像门
                     #   17=④ 调用前观测 18=注入前提或建立不成立 13=③ 的调用前观测 14=计数或退出码留档; 0=已调用
  local g
  r3_real2_gate "$R3_REAL2_LOG"; g=$?
  echo "  R2 $R3_WHY"
  (( g == 0 )) || return 10
  r3_bridge_identity_gate; g=$?
  (( g == 0 )) || return 11
  r3_dns_instrument || return 15
  r3_quiesce || return 16
  r3_runtime_gate || return 12
  r4_precapture || return 17
  r4_inject_stage || return 18
  r3_precapture || return 13
  r3_invoke || { echo "  调用前停止: $R3_WHY"; return 14; }
  return 0
}
# <<< PDG-EXTRACT-END r4_pre
# >>> PDG-EXTRACT-BEGIN r4_markers
# B 段: 有序且具名的四个标记。每一条都只认产品自己的原句(冻结源码里的出处写在旁边),
# 不拿"最后恢复了"倒推中间退役发生过, 也不拿 update 的非零退出码代替其中任何一条。
r4_mark_line(){   # $1=日志 $2=固定串 → 0 恰 1 处(R3_VAL=行号) / 1 没有 / 3 不止一处 / 2 查询失败
  # 330: 取行号那一次 grep 也核退出码(以前先输出再失败的行号照样被用)。
  local n rc out; R3_VAL=""
  [[ -f "$1" ]] || { R3_WHY="日志不在: $1"; return 2; }
  n="$(grep -cF -- "$2" "$1" 2>/dev/null)"; rc=$?
  (( rc <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]] || { R3_WHY="计数查询失败(grep rc=$rc, 找「$2」)"; return 2; }
  (( n == 0 )) && { R3_WHY="日志里没有「$2」"; return 1; }
  (( n > 1 )) && { R3_WHY="「$2」出现 $n 次(应恰 1 次)"; return 3; }
  out="$(grep -nF -- "$2" "$1" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R3_WHY="取行号的查询失败(grep rc=$rc, 找「$2」)"; return 2; }
  R3_VAL="${out%%:*}"
  [[ "$R3_VAL" =~ ^[0-9]+$ ]] || { R3_VAL=""; R3_WHY="行号取不到"; return 2; }
}
# 其它会把失败传出 run_all_migrations 的迁移, 各自的具名失败文案(冻结退役 pdg.sh)。
# 扫到任何一条 = 本次的失败来源不止 GMS 这一处, 本次 ④ 无效; 但**扫不到不等于**其它迁移都成功 ——
# 它们大多是 `|| true`, 失败也不出声(见 T:6484 起 run_all_migrations 的逐条注释)。
R4_OTHER_FAIL=('缺 unit 模板' '当前部署源缺少 pdg-probe81 unit 模板' 'pdg-probe81 未能启用'
               '去广告受管块' '未迁移(已回滚标记)' '迁移失败, 已回滚' '内核未稳定运行'
               '加 include 点后 nft -c 未过' 'daemon-reload 失败, pdg-probe81 可能未生效')
r4_markers(){   # → 0 四个标记有序且各恰 1 次、其它失败文案扫描有效且全未出现 / 1 不成立或观测无效(逐项已打印)
  local st=0 rc p hit="" scanbad="" l_ret="" l_gms="" l_mig="" l_rb=""
  r3_grepq -F '✅ 已更新。' "$R3_LOG"; rc=$?
  case "$rc" in
    0) bad "④-1 产品自报「✅ 已更新。」—— 本次升级**没有**按预期失败, 不是有效 ④"; st=1;;
    1) ;;
    *) bad "④-1 升级日志读不了($R3_WHY)"; st=1;;
  esac
  r4_mark_line "$R3_LOG" '✅ WLOC 位置改写及其专属 MITM 执行能力已退役'; rc=$?
  if (( rc == 0 )); then l_ret="$R3_VAL"; ok "④-1 M1 本次 WLOC 退役**成功**(产品原句, 只在退役各步含最后一个提交点 _retire_ios_schema 全过之后才打印): 第 $l_ret 行"
  else bad "④-1 M1 没有本次 WLOC 退役成功的直接证据: $R3_WHY"; st=1; fi
  r4_mark_line "$R3_LOG" '是硬链接(nlink='; rc=$?
  if (( rc == 0 )) && grep -qF "iOS GMS 清理: $R4_TARGET 是硬链接(nlink=" "$R3_LOG" && grep -qF '未改动任何文件' "$R3_LOG"; then
    l_gms="$R3_VAL"; ok "④-1 M2 故障命中指定环节: GMS 清理对 $R4_TARGET 的形态守卫具名拒绝且未改动任何文件: 第 $l_gms 行"
  else bad "④-1 M2 故障没有命中 GMS 形态守卫: ${R3_WHY:-点名的不是 $R4_TARGET, 或没有「未改动任何文件」}"; st=1; fi
  r4_mark_line "$R3_LOG" '迁移(__migrate)失败, 回滚到更新前快照'; rc=$?
  if (( rc == 0 )); then l_mig="$R3_VAL"; ok "④-1 M3 迁移非零已传到桥接版 cmd_update, 由它触发自动回滚: 第 $l_mig 行"
  else bad "④-1 M3 没有「迁移(__migrate)失败 → 回滚」这一句: $R3_WHY"; st=1; fi
  if [[ -n "${R4_SNAP_NEW:-}" ]]; then
    r4_mark_line "$R3_LOG" "回滚到 $R4_SNAP_NEW"; rc=$?
    if (( rc == 0 )); then l_rb="$R3_VAL"; ok "④-1 M4 回滚点名的就是本次新建的快照 $R4_SNAP_NEW: 第 $l_rb 行"
    else bad "④-1 M4 日志里没有「回滚到 $R4_SNAP_NEW」: $R3_WHY"; st=1; fi
  else bad "④-1 M4 本次新建快照还没确定, 无法核对回滚点名的是哪一份"; st=1; fi
  if [[ -n "$l_ret" && -n "$l_gms" && -n "$l_mig" && -n "$l_rb" ]] \
     && (( l_ret < l_gms && l_gms < l_mig && l_mig < l_rb )); then
    ok "④-1 顺序成立: 退役成功($l_ret) → 硬链接拒绝($l_gms) → 迁移失败触发回滚($l_mig) → 回滚到本次快照($l_rb)"
  else bad "④-1 顺序不成立(退役 ${l_ret:-无} / 拒绝 ${l_gms:-无} / 迁移失败 ${l_mig:-无} / 回滚 ${l_rb:-无})"; st=1; fi
  # 其它迁移的具名失败文案: 每一条都分清"没出现"与"查询失败"(330)。
  for p in "${R4_OTHER_FAIL[@]}"; do
    r3_grepq -F -- "$p" "$R3_LOG"; rc=$?
    case "$rc" in 0) hit="$hit [$p]";; 1) ;; *) scanbad="$scanbad [$p]";; esac
  done
  if [[ -n "$scanbad" ]]; then bad "④-1 其它迁移失败文案的扫描查询失败:$scanbad —— 不当成「一条都没扫到」"; st=1
  elif [[ -n "$hit" ]]; then bad "④-1 还扫到别的迁移失败文案:$hit —— 本次失败来源不止一处, 不是有效 ④"; st=1
  else note "④-1 其它会传出失败的迁移, 它们的具名失败文案一条都没扫到 —— 这只用于发现异常, **不证明**其它迁移都成功(多数是 || true, 失败不出声)"; fi
  return "$st"
}
r4_exit_verdict(){   # 读 R3_WRAP_RC / R3_RCFILE / R3_TOERR → 0 健康的预期失败 / 1 不成立或观测无效(逐项已打印); 置 R4_WRAP_RC / R4_PROD_RC
  # 330: 三样分开结算, 缺一样都不算健康的预期失败 ——
  #   包装器(timeout)返回 0: r3_invoke 的内层 bash 跑完产品、写出退出码之后才会以 0 结束;
  #   产品原始退出码 = 1: update 失败(它只说明 update 没成功, **不**说明回滚成功);
  #   timeout 没有发信号记录。
  # 包装器异常(被杀 / 超时 / 内层没写完)不能被"日志像样""现场恢复了"掩盖。
  local st=0 rc
  R4_WRAP_RC="${R3_WRAP_RC:-}"; R4_PROD_RC=""
  echo "  P0 包装器(timeout)返回码 = ${R4_WRAP_RC:-未取得}"
  if [[ "$R4_WRAP_RC" == 0 ]]; then ok "④-1 包装器正常结束(返回 0: 内层跑完产品并写出了退出码)"
  elif [[ -z "$R4_WRAP_RC" ]]; then bad "④-1 包装器返回码未取得"; st=1
  else bad "④-1 包装器返回码 $R4_WRAP_RC —— 包装器没有正常结束, 日志与现场再像样也不算健康的预期失败"; st=1; fi
  r3_prod_rc; rc=$?
  case "$rc" in
    0) R4_PROD_RC="$R3_VAL";;
    3) R4_PROD_RC="未写出($R3_WHY)";;
    *) R4_PROD_RC="读不了($R3_WHY)";;
  esac
  echo "  P1 产品原始退出码 = $R4_PROD_RC(内层单独写出)"
  if [[ "$R4_PROD_RC" == 1 ]]; then ok "④-1 产品原始退出码 = 1(预期失败; 它只说明 update 没成功, **不**说明回滚成功)"
  else bad "④-1 产品原始退出码 = $R4_PROD_RC(预期 1)"; st=1; fi
  r3_timeout_sig; rc=$?
  case "$rc" in
    0) bad "④-1 timeout 有发信号记录($R3_VAL) —— 本次是被打断, 不是预期失败"; st=1;;
    1) ok "④-1 没有 timeout 的发信号记录(不是超时打断)";;
    *) bad "④-1 timeout 记录读不了: $R3_WHY"; st=1;;
  esac
  return "$st"
}
# <<< PDG-EXTRACT-END r4_markers
# >>> PDG-EXTRACT-BEGIN r4_rollback
r4_rollback_outcome(){   # 回滚结局: 只认产品自己的成功句, 且不许有"未完全回滚"或回滚阶段的 ❌ → 0 / 1
  # 具名的失败形态先认, 再看成功句计数。330: 两个否定查询都分清"没有"与"查询失败" ——
  # 查询失败当成"没有"的话, 一次读不了的日志就能让"未完全回滚"被放行。
  local nok rc
  r3_grepq -F '未能恢复(未完全回滚)' "$R3_LOG"; rc=$?
  case "$rc" in
    0) bad "④-2 产品自报未完全回滚: $(grep -F '未能恢复(未完全回滚)' "$R3_LOG" 2>/dev/null | head -1 | sed 's/\x1b\[[0-9;]*m//g')"; return 1;;
    1) ;;
    *) bad "④-2 「未完全回滚」查询失败($R3_WHY) —— 不当成「没有」"; return 1;;
  esac
  r3_grepq -E '❌ (快照落盘失败|快照.*中止|建不出|拍不下)' "$R3_LOG"; rc=$?
  case "$rc" in
    0) bad "④-2 回滚阶段有 ❌: $(grep -m1 -E '❌ (快照落盘失败|快照.*中止|建不出|拍不下)' "$R3_LOG" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"; return 1;;
    1) ;;
    *) bad "④-2 回滚阶段 ❌ 的查询失败($R3_WHY) —— 不当成「没有」"; return 1;;
  esac
  nok="$(grep -cF '✅ 已回滚并重启服务' "$R3_LOG" 2>/dev/null)"; rc=$?
  (( rc <= 1 )) && [[ "$nok" =~ ^[0-9]+$ ]] || { bad "④-2 回滚成功句的计数查询失败(grep rc=$rc)"; return 1; }
  if [[ "$nok" != 1 ]]; then bad "④-2 回滚成功句出现 $nok 次(应恰 1 次)"; return 1; fi
  ok "④-2 产品自报「✅ 已回滚并重启服务」恰 1 次, 没有「未完全回滚」, 回滚阶段没有 ❌(这只是产品自述, 下面各项独立核)"
}
r4_snapshot_verdict(){   # 本次新建快照 + svcstate 绑定 → 0 / 1; 置 R4_SNAP_NEW
  # 330: 绑定按**产品自己的格式**核(桥接 _pdg_save_svcstate: 首行 `#pdg-svcstate<TAB>1`, 头部
  #      `snap_dir<TAB><快照目录>` 与 `snap_id<TAB><snap.tar.gz 的 设备:inode:字节数:mtime>`)。
  #      以前另外接受 `snap_dir=` 这种产品不写的形态, 也不核 snap_id; svcstate 读不了时还被说成"没有指向这一份"。
  local after new sd raw rc l tab=$'\t' n_sd=0 n_si=0 v_sd="" v_si="" want
  R4_SNAP_NEW=""
  if ! r3_lsdir "$SNAPROOT"; then bad "④-2 调用后快照目录清单没取得: $R3_WHY"; return 1; fi
  after="$R3_VAL"
  if ! r3_snapdiff "${R4_SNAP_BEFORE:-}" "$after"; then bad "④-2 快照差集算不出来: $R3_WHY"; return 1; fi
  new="$R3_VAL"
  if [[ "$(grep -c . <<<"$new")" != 1 ]]; then bad "④-2 本次新增快照不是恰 1 个(新增: [$(tr '\n' ' ' <<<"$new")])"; return 1; fi
  R4_SNAP_NEW="$new"
  sd="$SNAPROOT/$new"
  [[ -s "$sd/snap.tar.gz" && -s "$sd/svcstate.tsv" ]] || { bad "④-2 本次快照缺件($sd)"; return 1; }
  raw="$(cat -- "$sd/svcstate.tsv" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { bad "④-2 本次快照的 svcstate.tsv 读不了(cat rc=$rc) —— 绑定判不了"; return 1; }
  [[ "${raw%%$'\n'*}" == "#pdg-svcstate${tab}1" ]] || { bad "④-2 svcstate.tsv 首行不是产品的格式标记(实得 [${raw%%$'\n'*}])"; return 1; }
  while IFS= read -r l; do
    case "$l" in
      "snap_dir${tab}"*) n_sd=$((n_sd + 1)); v_sd="${l#"snap_dir${tab}"}";;
      "snap_id${tab}"*)  n_si=$((n_si + 1)); v_si="${l#"snap_id${tab}"}";;
    esac
  done <<<"$raw"
  [[ "$n_sd" == 1 && "$v_sd" == "$sd" ]] \
    || { bad "④-2 svcstate 的 snap_dir 应恰 1 行且就是这一份(实得 $n_sd 行 [$v_sd], 应 [$sd])"; return 1; }
  want="$(stat -c '%d:%i:%s:%Y' -- "$sd/snap.tar.gz" 2>/dev/null)"; rc=$?
  (( rc == 0 )) && [[ "$want" =~ ^[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]] || { bad "④-2 snap.tar.gz 的身份查询失败(stat rc=$rc) —— 绑定判不了"; return 1; }
  [[ "$n_si" == 1 && "$v_si" == "$want" ]] \
    || { bad "④-2 svcstate 的 snap_id 应恰 1 行且等于这份 snap.tar.gz 的 设备:inode:字节数:mtime(实得 $n_si 行 [$v_si], 应 [$want])"; return 1; }
  ok "④-2 本次由产品新建快照恰 1 个($new), 它的服务前像按产品格式指向这一份: snap_dir 就是它, snap_id 与这份 snap.tar.gz 对得上"
}
r4_identity_back(){   # HEAD / CLI / 受管模块回到桥接 → 0 / 1
  local st=0 h
  if r3_head "$R3_REPO"; then h="$R3_VAL"
    [[ "$h" == "$BRIDGE_SHA" ]] && ok "④-3 现役 HEAD 回到桥接 ${BRIDGE_SHA:0:12}" || { bad "④-3 现役 HEAD 是 ${h:0:12}, 不是桥接 ${BRIDGE_SHA:0:12}"; st=1; }
  else bad "④-3 观测无效: $R3_WHY"; st=1; fi
  if r3_objsha "$R3_OBJ" "$BRIDGE_SHA" deploy/bot/pdg.sh; then
    local want="$R3_VAL"
    if r3_fsha "$R3_CLI"; then
      [[ "$R3_VAL" == "$want" ]] && ok "④-3 现役 CLI 逐字节 = 桥接 pdg.sh(${want:0:12})" || { bad "④-3 现役 CLI 不是桥接版(实得 ${R3_VAL:0:12}, 应 ${want:0:12})"; st=1; }
    else bad "④-3 观测无效: $R3_WHY"; st=1; fi
  else bad "④-3 观测无效: $R3_WHY"; st=1; fi
  if r3_modules "$R3_BRSRC" "$R3_MODDIR"; then
    local m="$R3_VAL"
    [[ "${m#* }" == 0 ]] && ok "④-3 受管模块 ${m% *} 项逐字节 = 桥接树" || { bad "④-3 受管模块有 ${m#* } 项与桥接树不同(共 ${m% *})"; st=1; }
  else bad "④-3 观测无效: $R3_WHY"; st=1; fi
  return "$st"
}
r4_svc_back(){   # 服务终态回到前像(允许新 PID / InvocationID)→ 0 / 1
  local st=0 u a b
  if ! bridge_svc_sample "$R4_TMP/svc-after.tsv"; then bad "④-4 调用后服务采样写不出来"; return 1; fi
  # shellcheck disable=SC2034
  declare -gA R4_ROWS_AFTER=()
  r3_set_check "$R4_TMP/svc-after.tsv" 调用后 R4_ROWS_AFTER; local rc=$?
  (( rc == 0 )) || { bad "④-4 调用后服务采样${rc:+(rc=$rc)}不可用: $R3_WHY"; return 1; }
  for u in "${SVC_WATCH[@]}"; do
    a="$(cut -f1-8,13 <<<"${R4_ROWS_BEFORE[$u]:-}")"; b="$(cut -f1-8,13 <<<"${R4_ROWS_AFTER[$u]:-}")"
    [[ -n "$a" && -n "$b" ]] || { bad "④-4 $u 的前像或调用后采样行取不到(前 [${a:-空}] 后 [${b:-空}])"; st=1; continue; }
    if [[ "$a" == "$b" ]]; then ok "④-4 $u 终态与前像一致($(cut -f5-8 <<<"$b" | tr '\t' ' '); PID / InvocationID 允许不同)"
    else bad "④-4 $u 终态与前像不同: 前 [$(tr '\t' ' ' <<<"$a")] 后 [$(tr '\t' ' ' <<<"$b")]"; st=1; fi
  done
  return "$st"
}
r4_dns_back(){   # 回滚后的 DNS: W=H(接管回来) / C=U / P=H; 用**调用后**那组名字, 它们在前像与快照里就已经配好
  local st=0
  r3_dns_conditions; local r=$?
  if (( r == 1 )); then bad "④-4 DNS 仪器条件被改动: $R3_WHY —— 该功能结论未取得"; return 1
  elif (( r != 0 )); then bad "④-4 DNS 仪器条件观测失效: $R3_WHY —— 该功能结论未取得"; return 1; fi
  ok "④-4 DNS 仪器条件仍成立(自有上游同一进程; local_upstream 那一行与 geosite_cn 都是调整后的原样 —— 它们是在建快照**之前**调整的, 所以回滚目标就是调整后的那一份)"
  if ! r3_dns_rulematch "$R3_DNS_PPOST"; then bad "④-4 P 规则匹配判不了: $R3_WHY —— 该功能结论未取得"; st=1
  elif [[ -n "${R3_VAL#*$'\t'}" ]]; then bad "④-4 P 探针 $R3_DNS_PPOST 被规则匹配(${R3_VAL#*$'\t'}) —— 不能代表普通劫持路径"; st=1
  else
    ok "④-4 P 探针 $R3_DNS_PPOST 不被任何 domain_set 规则或内联 qname 匹配(按 mosdns 语义求值)"
    r3_dns_path "$R3_DNS_PPOST" post-p H; r3_dns_say "④-4" "P(普通劫持探针 $R3_DNS_PPOST)走 H、自有上游未收到: 普通 DNS 代理劫持路径保留" $? || st=1
  fi
  r3_dns_path "$R3_DNS_W" post-w H; r3_dns_say "④-4" "W($R3_DNS_W)走接管 H、自有上游未收到: WLOC 接管已随回滚回来" $? || st=1
  r3_dns_path "$R3_DNS_CPOST" post-c U; r3_dns_say "④-4" "C(独立上游对照 $R3_DNS_CPOST)经 local_upstream 取得 U" $? || st=1
  return "$st"
}
# <<< PDG-EXTRACT-END r4_rollback

snap_state "late-before"      # 仅留档, 不参与任何判据

SECT "④-0 前置: ② 的结果、桥接前像、DNS 仪器、静置、运行态门、前像采集与注入"
for c in git python3 ss dig curl sha256sum timeout comm cmp stat diff nft find join; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
for s in "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$R3_OBJ" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "本 job 的检出里取不到对象 $s"
done
mkdir -p "$R3_BRSRC" "$R3_RTSRC"
git -C "$R3_OBJ" archive "$BRIDGE_SHA" | tar -x -C "$R3_BRSRC" || _hard "展开桥接树失败"
git -C "$R3_OBJ" archive "$RETIRE_SHA" | tar -x -C "$R3_RTSRC" || _hard "展开退役树失败"
# 调用前的服务采样(④ 自己留一份, 供调用后逐字段比对; ③ 的 r3_precapture 另有一份自用)
declare -A R4_ROWS_BEFORE=()
_cnt_say(){ if r3_count_read; then printf '%s' "$R3_VAL"; else printf '读不出(%s)' "$R3_WHY"; fi; }

r4_gated_invoke; GRC=$?
case "$GRC" in
  0) ;;
  10) bad "④-0 ② 的结果门不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: ② 不成立";;
  11) bad "④-0 桥接身份门不成立(见上面逐项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 桥接前像不成立";;
  15) bad "④-0 DNS 仪器条件 / 标定 / 还原核验不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: DNS 仪器不成立";;
  16) bad "④-0 准备阶段静置不成立(见上面 Q 项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 准备阶段静置不成立";;
  12) bad "④-0 运行态 / WLOC 前像门不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 桥接前像不成立";;
  17) bad "④-0 ④ 的调用前观测没取全(见上面 E 项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 调用前观测不全";;
  18) bad "④-0 注入前提或建立不成立 —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 注入不成立";;
  13) bad "④-0 ③ 的调用前观测没取全(见上面 E 项) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 调用前观测不全";;
  14) bad "④-0 调用计数或退出码留档不可用(见上) —— 本场景未执行, 调用计数 $(_cnt_say)"; nrun "场景 ④: 计数不可用";;
  *)  bad "④-0 门返回了未登记的值 $GRC —— 按未执行处理"; nrun "场景 ④: 门状态不明";;
esac
if (( GRC != 0 )); then
  r4_inject_remove | sed 's/^/  X /'
  e2e_summary; exit 1
fi
ok "④-0 ② 结果门、桥接身份门、DNS 仪器、准备阶段静置、运行态 / WLOC 前像门、④ 前像采集与注入全部成立后才调用(调用计数 $(_cnt_say))"
# 调用前那一份服务采样(④ 自用): r3_precapture 已经写过 svc-retire-before.tsv, 这里按同一份文件读进来
r3_set_check "$R3_TMP/svc-retire-before.tsv" 调用前 R4_ROWS_BEFORE \
  || note "④-0 调用前服务采样读进 ④ 自己的表失败($R3_WHY) —— ④-4 的逐字段比对会因此判不成立"
C3_1="$(_j_mark late-end)" || { C3_1=""; note "阶段记账: 止界桩没建成($(_j_why))"; }
cp "$R3_LOG" "$EVID/04-late-update.log" 2>/dev/null && chmod 600 "$EVID/04-late-update.log" 2>/dev/null \
  || note "升级日志没能复制进证据目录"
cp "$R3_RCFILE" "$EVID/04-late-update.rc" 2>/dev/null; cp "$R3_TOERR" "$EVID/04-late-update.timeout-stderr" 2>/dev/null
tail -60 "$R3_LOG" 2>/dev/null | sed 's/^/    /'

SECT "④-1 退役成功与故障命中(有序且具名; 不拿'最后恢复了'倒推)"
# 退出码分开结算: 包装器、产品、timeout 三样缺一不是健康的预期失败; 它们都**不能**代替"回滚成功"。
r4_exit_verdict || true
r4_snapshot_verdict || true       # 先定出本次快照, M4 要用它的名字
r4_markers || true
# journal: 窗口口径只计 "Started <unit>" 条数(与 ③ 同)。330 更正: 这个**计数**只说明区间里 pdg-mitm 被启动过,
# 与"回滚会按前像重启它"一致; 它证明不了"先被退役停掉、后被回滚拉起"的先后 —— 先后只由上面产品原句的顺序(M1→M4)给出。
if [[ -n "${C3_0:-}" && -n "${C3_1:-}" ]]; then
  if _n="$(_j_interval pdg-mitm "$C3_0" "$C3_1")" && [[ "$_n" =~ ^[0-9]+$ ]]; then
    (( _n >= 1 )) && ok "④-1 journal 界桩区间里 pdg-mitm 被启动过 $_n 次(与回滚按前像重启它一致; 只是计数, 不证明停与起的先后)" \
                  || bad "④-1 journal 界桩区间里 pdg-mitm 的 Started 是 0 —— 回滚没有重启它的记录"
  else bad "④-1 pdg-mitm 的窗口启动事件查不清($(_j_why))"; fi
else bad "④-1 界桩不全(起 [${C3_0:-无}] 止 [${C3_1:-无}]) —— 窗口无从谈起"; fi

SECT "④-2 自动回滚的结局(产品自述)与本次快照绑定"
r4_rollback_outcome || true

SECT "④-3 身份、文件与保留数据回到调用前"
r4_identity_back || true
if r4_fs_manifest "$R4_TMP/fs-after.tsv"; then
  r3_copy_record "$R4_TMP/fs-after.tsv" "$EVID/05-fs-after.tsv" || note "调用后清单留证失败: $R3_WHY"
  r4_fs_diff "$R4_TMP/fs-before.tsv" "$R4_TMP/fs-after.tsv"; _d=$?
  case "$_d" in
    0) ok "④-3 快照候选路径下的文件全部回到调用前(逐条比类型 / mode / 属主 / 摘要; 只有事先登记的允许差异: $(printf '%s ' "${R4_ALLOW_NEW[@]}"))";;
    1) bad "④-3 有事先清单之外的差异: $R3_WHY";;
    *) bad "④-3 文件清单比不了: $R3_WHY";;
  esac
else bad "④-3 调用后文件清单没取得: $R3_WHY"; fi
r3_keep_verdict
if _p="$(cat -- "$R3_ETC/platform" 2>/dev/null)"; then
  [[ "$_p" == ios ]] && ok "④-3 平台标记仍是 ios" || bad "④-3 平台标记变了([$_p])"
else bad "④-3 观测无效: 平台标记读不了"; fi
if [[ -e "$R3_MITM_UNIT" ]]; then ok "④-3 pdg-mitm unit 文件已随回滚回来"; else bad "④-3 pdg-mitm unit 文件不在 —— 退役的撤除没有被回滚"; fi
if r3_listen_count 7894; then
  (( R3_VAL > 0 )) && ok "④-3 7894 恢复监听($R3_VAL)" || bad "④-3 7894 没有监听 —— pdg-mitm 没真正回来"
else bad "④-3 观测无效: $R3_WHY"; fi
r3_grepq 'MITM-OUT' "$MC"; _g=$?
case "$_g" in 0) ok "④-3 内核配置里 MITM-OUT 已随回滚回来";; 1) bad "④-3 内核配置里没有 MITM-OUT";; *) bad "④-3 观测无效: 内核配置读不了($R3_WHY)";; esac

SECT "④-4 服务、真实功能与运行中的防火墙"
r4_svc_back || true
r3_stable_assert mosdns      running "④-4 运行态: mosdns 持续运行" 5
r3_stable_assert mihomo      running "④-4 运行态: mihomo 持续运行" 5
r3_stable_assert pdg-mitm    running "④-4 运行态: pdg-mitm 持续运行(WLOC 回来了)" 5
r3_stable_assert pdg-probe81 running "④-4 运行态: pdg-probe81 持续运行" 5
if r3_http_code http://127.0.0.1:81/; then
  [[ "$R3_VAL" == 200 ]] && ok "④-4 F1 实际功能: :81 HTTP 200" || bad "④-4 F1 :81 查询成功但状态码是 $R3_VAL(要 200)"
else bad "④-4 F1 功能观测未取得: $R3_WHY —— 不算通过"; fi
if r4_fw_live; then
  printf '%s\n' "$R3_VAL" > "$EVID/06-fw-after.txt" 2>/dev/null || note "调用后防火墙留证写不出来"
  if [[ "$R3_VAL" == "${R4_FW_BEFORE:-}" ]]; then
    ok "④-4 运行中的防火墙(inet pdg 表原文)与调用前逐字相同 —— 这是独立核对, 不靠回滚的成功文案(回滚对 nft 应用是 || true)"
  else
    bad "④-4 运行中的防火墙与调用前不同(前后原文都在 02-fw-before.txt / 06-fw-after.txt; 不做任何字段过滤)"
    diff <(printf '%s\n' "${R4_FW_BEFORE:-}") <(printf '%s\n' "$R3_VAL") 2>/dev/null | head -10 | sed 's/^/      /'
  fi
else bad "④-4 运行中的防火墙没取得: $R3_WHY"; fi
r4_dns_back || true

SECT "④-5 撤除注入与收尾"
# 撤除只在判定之后, 且只按登记身份删自己那一个。链接里此刻是迁移后的内容(产品原地写穿透), 不是备份。
r4_inject_remove | sed 's/^/  X /'
_irc="${PIPESTATUS[0]}"
case "$_irc" in
  0) ok "④-5 测试链接已按登记身份撤除($R4_LINK)";;
  1) note "④-5 测试链接本来就不在(未建立或已被别的东西删掉)";;
  3) bad "④-5 测试链接的身份查询失败 —— 没有删, 留在盘上, 不谎报已清理";;
  *) bad "④-5 测试链接没能按登记撤除 —— 留在盘上, 不谎报已清理";;
esac
_nl="$(stat -c %h -- "$R4_TARGET" 2>/dev/null)"; _nlrc=$?
if (( _nlrc != 0 )) || [[ ! "$_nl" =~ ^[0-9]+$ ]]; then note "④-5 $R4_TARGET 的 nlink 查询失败(stat rc=$_nlrc)—— 未取得(登记实测项, 不据此判成败)"
elif [[ "$_nl" == 1 ]]; then ok "④-5 $R4_TARGET 的 nlink 回到 1"
else note "④-5 $R4_TARGET 的 nlink 现为 $_nl(登记实测, 不据此判成败)"; fi
snap_state "late-after"
{
  echo "# 本支在这台一次性 runner 上的动作: 一次 bash $R3_CLI update --to $RETIRE_TAG(调用计数 $(_cnt_say)), 以及建 / 删一个硬链接"
  echo "# 前像来源: 同一 job 上一步 ② 的真实现场; 调用前经 DNS 仪器调整与一次 ${R3_Q_SECS:-303} s 静置"
  echo "# 故障点: 退役版 migrate_ios_gms_cleanup 的事务目标形态守卫(硬链接 ⇒ 具名拒绝, 未改动任何文件)"
  echo "# 退出码: 包装器(timeout)返回码 ${R4_WRAP_RC:-未取得}; 产品原始退出码 ${R4_PROD_RC:-未取得} —— 都不代替'回滚成功'"
  echo "# 本次快照: ${R4_SNAP_NEW:-未取得}; 注入登记见 03-injection.txt; 前后清单见 01/05; 前后防火墙原文见 02/06"
  echo "# 不覆盖: v1.7.8、完整旧安装器、官方分发来源、发布"
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-late-summary.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary

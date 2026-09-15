#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ②: **v1.11.15 → 桥接版, 走公开的显式目标入口 `install.sh --ref <版本 tag>`**。
#
# 这一跳只验这一跳: 装上去的必须是**指定的桥接版**(不是版本号更高的退役目标), 桥接该带的
# 前像保存/恢复能力确实到位, 而 WLOC 退役、iOS 记录格式推进、旧产物/CA 删除 **一件都不许发生**。
# 不接着跑 ③(桥接→退役)或 ④, 也不做发布或生产部署。
#
# 关键: 这一跳由**真实公开入口**完成 —— 取一份新版 install.sh(相当于 curl 官方 raw),
# 带 `--ref` 跑, 让它自己走两段自举、自己 fetch/checkout。**不允许**直接把新版 pdg.sh
# 复制过去然后说"安装通过", 也不向旧调用方伪造任何服务前像凭据。
#
# 前提(缺一即硬停, 不 SKIP、不退回桩): 真 systemd / 真 systemctl / 真 nft /
# 钉死版 mosdns+mihomo 已就位 / git python3 openssl ss 齐备; 只许在一次性 runner 上跑。
#
# 源映射(测试专用, 可审计): 自有一次性裸库, 里面放三个**真实对象**:
#   v1.11.15(官方真 tag 对象) / v9.9.8-bridge-TEST(桥接候选) / v9.9.9-retire-TEST(退役候选)。
#   后两个 tag 名是"仅测试"的合成名, 只存在于这个裸库; 官方仓库一个字节不动, 不推 tag、不发 Release。
#   裸库 refs/heads/main → 桥接候选(相当于"官方 main 上的最新入口脚本")。
#   **本支通过 ≠ 正式发布来源已验证。**
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
E2E_ROOT_REAL="$E2E_ROOT"

_hard(){ echo "[HARD-STOP] $1" >&2; exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支会真的改本机 systemd 与 /etc。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || _hard "不在 GitHub Actions 里 —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
EVID="${PDG_REAL_MIG_EVID:-${TMPDIR:-/tmp}/real-migration-evidence}"
mkdir -p "$EVID" && chmod 700 "$EVID"

PLAT_SRC="$E2E_ROOT/tests/e2e-real-platform-fail.sh"
[[ -f "$PLAT_SRC" ]] || _hard "找不到 $PLAT_SRC(要从它原文取前像与状态采集那几支)"
# ── 按**唯一成对标记**定点抽函数原文 ────────────────────────────────────────
# 上一次(run 34976950055)栽在这: 抽法是"从 name(){ 读到第一行顶格 }", 而 build_preimage
# 里写 mitm.json 的那段 heredoc 正文就有一行顶格 } —— 抽取在那里提前收尾, 把 EOF 和后面的
# 代码全切了, eval 当场语法错, 前像根本没开始建。
# 现在改成: 只认来源脚本里那对 `# >>> PDG-EXTRACT-BEGIN <名字>` / `# <<< PDG-EXTRACT-END <名字>`
# 注释标记(它们只是注释, 不改被抽函数的任何行为)。规矩:
#   · 标记必须唯一、成对、BEGIN 在 END 之前 —— 缺失/重复/倒置一律当场拒绝;
#   · 片段必须以 `<名字>(){` 开头、以顶格 `}` 结尾(heredoc、闭合符、函数尾一个都不少);
#   · 每个片段先**单独** bash -n, 全部拼成一个加载单元后**再** bash -n;
#   · 只有都过了才 source; 任何一步失败就 _hard —— 不进前像构造、不动任何服务;
#   · 绝不 source 整支来源脚本(它有运行副作用)。
EXTRACT_NAMES=(_ev _evn SECT note sc_get sc_state nrun snap_state reset_units_strict reset_proof
               build_preimage svc_class svc_snapshot svc_verdict wait_stable unit_identify
               _unit_wants_mainpid svc_stable_window svc_stable_assert mitm_listen_verdict
               _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_mark _j_starts_after
               _j_tag_after _j_interval)
# >>> PDG-EXTRACT-BEGIN extract_marked_fns
extract_marked_fns(){   # $1=来源脚本 $2=落点(加载单元) $3..=函数名 → 0 成功 / 非 0 并具名说明
  local src="$1" out="$2"; shift 2
  local n b e nb ne frag tmp rc=0
  [[ -f "$src" ]] || { echo "抽取: 找不到来源 $src" >&2; return 2; }
  : > "$out" || { echo "抽取: 写不了落点 $out" >&2; return 2; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/frag.XXXXXX")" || { echo "抽取: 建不出临时文件" >&2; return 2; }
  for n in "$@"; do
    nb="$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")"
    ne="$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")"
    if [[ "$nb" != 1 || "$ne" != 1 ]]; then
      echo "抽取: $n 的标记不是唯一成对(BEGIN $nb 个 / END $ne 个)" >&2; rc=1; break
    fi
    b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
    e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
    if (( b >= e )); then echo "抽取: $n 的标记顺序不对(BEGIN 在第 $b 行, END 在第 $e 行)" >&2; rc=1; break; fi
    # 相邻两行 = 标记之间根本没有内容。必须显式判: sed 的倒置范围会**只打一行**, 靠 -z 兜不住。
    if (( e - b < 2 )); then echo "抽取: $n 的标记之间是空的(BEGIN 第 $b 行, END 第 $e 行)" >&2; rc=1; break; fi
    frag="$(sed -n "$((b+1)),$((e-1))p" "$src")"
    if [[ -z "$frag" ]]; then echo "抽取: $n 的标记之间是空的" >&2; rc=1; break; fi
    if ! grep -q "^$n(){" <<<"$frag"; then echo "抽取: $n 的片段不是以 $n(){ 开头" >&2; rc=1; break; fi
    if ! { [[ "$(tail -1 <<<"$frag")" == "}" ]] || [[ "$(tail -1 <<<"$frag")" =~ \}[[:space:]]*(#.*)?$ ]]; }; then
      echo "抽取: $n 的片段结尾不是函数闭合(实得: $(tail -1 <<<"$frag"))" >&2; rc=1; break
    fi
    printf '%s\n' "$frag" > "$tmp"
    if ! bash -n "$tmp" 2>"$tmp.err"; then
      echo "抽取: $n 的片段单独语法检查不过: $(head -2 "$tmp.err" | tr '\n' ' ')" >&2; rc=1; break
    fi
    printf '%s\n' "$frag" >> "$out"
  done
  rm -f "$tmp" "$tmp.err"
  (( rc == 0 )) || return "$rc"
  if ! bash -n "$out" 2>"$out.err"; then
    echo "抽取: 组合后的加载单元语法检查不过: $(head -2 "$out.err" | tr '\n' ' ')" >&2; return 1
  fi
  rm -f "$out.err"
  return 0
}
# <<< PDG-EXTRACT-END extract_marked_fns
EXTRACT_UNIT="${E2E_TMP:-${TMPDIR:-/tmp}}/plat-fns.sh"
extract_marked_fns "$PLAT_SRC" "$EXTRACT_UNIT" "${EXTRACT_NAMES[@]}" \
  || _hard "函数抽取没通过(见上一行) —— 前像构造与任何服务动作都还没开始, 就停在这里。"
# shellcheck source=/dev/null
source "$EXTRACT_UNIT" || _hard "加载抽取单元失败 —— 同样停在前像之前。"
for _f in "${EXTRACT_NAMES[@]}"; do
  declare -F "$_f" >/dev/null || _hard "抽取单元里少了 $_f"
done
# 这几个是给上面 eval 进来的那些原文函数读的(界桩/前像/状态采集), 本文件自己不直接引用
# shellcheck disable=SC2034
JBOUND_TAG="pdg-e2e-jbound"
# shellcheck disable=SC2034
J_ERR=""
E2E_NOTRUN=0; PREIMAGE_OK=1
OLD_SHA="${PDG_OLD_SHA:-242602c17bd92900df81f468aae8c66e18c7a4ff}"     # v1.11.15 peeled
BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"
[[ -n "$BRIDGE_SHA" ]] || _hard "必须显式给出桥接候选 SHA(PDG_BRIDGE_SHA)"
[[ -n "$RETIRE_SHA" ]] || _hard "必须显式给出退役候选 SHA(PDG_RETIRE_SHA; 只用来证明它**没**被误装)"
OLD_TAG="v1.11.15"; BRIDGE_TAG="v9.9.8-bridge-TEST"; RETIRE_TAG="v9.9.9-retire-TEST"
ORIGIN="$E2E_TMP/origin.git"; OLDSRC="$E2E_TMP/oldsrc"; BRSRC="$E2E_TMP/brsrc"; REPO=/opt/privdns-gateway
# shellcheck disable=SC2034
TEST_TAG="$BRIDGE_TAG"   # build_preimage 会用它把新 tag 从工作副本里删掉, 逼取件真去 fetch

SECT "① 真实环境硬门"
[[ "$(cat /proc/1/comm)" == systemd ]] || _hard "PID 1 不是 systemd"
SCBIN="$(command -v systemctl || true)"; [[ -x "$SCBIN" ]] || _hard "没有 systemctl"
case "$SCBIN" in /usr/local/bin/*) _hard "systemctl 解析到 $SCBIN(本仓桩的落点), 拒绝";; esac
head -c2 "$SCBIN" | grep -q '#!' && _hard "systemctl 是脚本, 不是真二进制"
NFTBIN="$(command -v nft || true)"; [[ -x "$NFTBIN" ]] || _hard "没有 nft"
nft list ruleset >/dev/null 2>&1 || _hard "nft 读不到内核规则"
[[ -f /usr/local/bin/mosdns && "$(stat -c %s /usr/local/bin/mosdns)" -gt 1000000 ]] || _hard "mosdns 不是真二进制"
e2e_mihomo_is_real 2>/dev/null || _hard "mihomo 不是真钉死版"
for c in git python3 openssl ss curl sha256sum; do command -v "$c" >/dev/null || _hard "缺命令: $c"; done
ok "硬门: 真 systemd / 真 systemctl / 真 nft / 钉死版 mosdns+mihomo / 基础命令齐备"
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1
  note "已停用 runner 自带的 systemd-resolved(释放 :53; 一次性 runner 专属改动)"
fi
rm -f /etc/resolv.conf 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

SECT "② 自有测试源(三个真实对象; 官方仓库不动)"
for s in "$OLD_SHA" "$BRIDGE_SHA" "$RETIRE_SHA"; do
  [[ "$(git -C "$E2E_ROOT_REAL" cat-file -t "$s" 2>/dev/null)" == commit ]] || _hard "工作区里取不到对象 $s"
done
rm -rf "$ORIGIN"; git clone --bare -q "$E2E_ROOT_REAL" "$ORIGIN" || _hard "建裸库失败"
e2e_guard_repo "$ORIGIN" || _hard "裸库没通过 ref 库守卫"
e2e_git "$ORIGIN" fetch -q "$E2E_ROOT_REAL" "+refs/tags/*:refs/tags/*" 2>/dev/null || true
if [[ "$(git -C "$ORIGIN" rev-parse -q --verify "$OLD_TAG^{commit}" 2>/dev/null)" == "$OLD_SHA" ]]; then
  OLD_TAG_KIND="$(git -C "$ORIGIN" cat-file -t "$OLD_TAG" 2>/dev/null)"
  ok "裸库里的 $OLD_TAG 指向真实对象 $OLD_SHA(tag 对象类型=$OLD_TAG_KIND)"
else
  e2e_git "$ORIGIN" tag -f "$OLD_TAG" "$OLD_SHA" >/dev/null 2>&1; OLD_TAG_KIND="lightweight(本轮补建)"
  note "工作区没带来官方 $OLD_TAG 的 tag 对象, 已按真实提交补一个轻量 tag"
fi
e2e_git "$ORIGIN" tag -f "$BRIDGE_TAG" "$BRIDGE_SHA" >/dev/null 2>&1 || _hard "建桥接测试 tag 失败"
e2e_git "$ORIGIN" tag -f "$RETIRE_TAG" "$RETIRE_SHA" >/dev/null 2>&1 || _hard "建退役测试 tag 失败"
e2e_git "$ORIGIN" update-ref refs/heads/main "$BRIDGE_SHA" || _hard "裸库 main 指不过去"
for _br in $(git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/main$'); do
  e2e_git "$ORIGIN" update-ref -d "$_br" >/dev/null 2>&1 || true
done
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
SEL="$(git -C "$ORIGIN" tag -l 'v*' --sort=-v:refname | head -1)"
[[ "$SEL" == "$RETIRE_TAG" ]] \
  && ok "排序最高的是**退役目标** $RETIRE_TAG → ${RETIRE_SHA:0:12} —— 指定桥接时它就是最容易被误装的那个" \
  || _hard "最高版本不是退役目标而是 $SEL, 源映射无效"
rm -rf "$OLDSRC" "$BRSRC"; mkdir -p "$OLDSRC" "$BRSRC"
git -C "$ORIGIN" archive "$OLD_SHA" | tar -x -C "$OLDSRC" || _hard "展开 v1.11.15 源码失败"
git -C "$ORIGIN" archive "$BRIDGE_SHA" | tar -x -C "$BRSRC" || _hard "展开桥接源码失败"
{
  echo "# 测试源映射(与正式发布路径的差异, 逐条)"
  echo "裸库              : $ORIGIN (本机自有, 一次性)"
  echo "$OLD_TAG          → $OLD_SHA (类型: $OLD_TAG_KIND)"
  echo "$BRIDGE_TAG       → $BRIDGE_SHA  (**仅测试**的合成 tag 名; 对象是真实桥接候选)"
  echo "$RETIRE_TAG       → $RETIRE_SHA  (**仅测试**; 版本号更高, 用来证明它没被误装)"
  echo "裸库 refs/heads/main → $BRIDGE_SHA (相当于官方 main 上的最新入口脚本)"
  echo "差异: 正式路径取件自 https://github.com/misaka-cpu/privdns-gateway.git 与官方 v* tag;"
  echo "      本轮取件自本机裸库与合成 tag。官方仓库不打 tag、不发 Release。"
  echo "      因此本支通过**不**等于「正式发布来源已验证」。"
} | _ev 02-source-map.txt
ok "源映射已留档(02-source-map.txt)"

SECT "③ 旧版前像(v1.11.15; **夹具组装**, 不是完整旧安装器跑出来的)"
note "如实登记: 前像由 tests/e2e-lib.sh 的播种函数 + 旧版自己的模板/模块清单组装,"
note "  **没有**跑 v1.11.15 的 install.sh。所以本支不是「完整旧安装器升级验收」——"
note "  它验的是**这一跳的公开入口与版本身份**, 前像只需合法稳定。"
build_preimage ios on || _hard "旧版前像没建起来"
install -m755 "$OLDSRC/deploy/bot/pdg.sh" /usr/local/bin/pdg
OLD_CLI_SHA="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
[[ "$OLD_CLI_SHA" == "$(sha256sum "$OLDSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
  && ok "前像: /usr/local/bin/pdg 逐字节等于 v1.11.15 的那一份($(cut -c1-12 <<<"$OLD_CLI_SHA"))" \
  || bad "前像: CLI 不是 v1.11.15 的"
for _f in _pdg_save_svcstate _pdg_restore_svcstate; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && { bad "前像: 旧版 CLI 里竟然已经有 $_f —— 那就没有可验的跳了"; } \
    || ok "前像: 旧版 CLI **没有** $_f(桥接要带来的能力, 现在确实还不在)"
done
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$OLD_SHA" ]] \
  && ok "前像: $REPO 停在 v1.11.15($OLD_SHA)" || bad "前像: $REPO HEAD=$(git -C "$REPO" rev-parse HEAD)"
[[ "$(git -C "$REPO" remote get-url origin)" == "$ORIGIN" ]] \
  && ok "前像: $REPO 的 origin 指向自有裸库(公开入口就从这里取件)" || bad "前像: origin 不对"
systemctl daemon-reload
svc_stable_assert mosdns      running "前像: mosdns 持续运行" 5
svc_stable_assert mihomo      running "前像: mihomo 持续运行" 5
svc_stable_assert pdg-mitm    running "前像: pdg-mitm 持续运行(WLOC 开着)" 5
svc_stable_assert pdg-probe81 running "前像: pdg-probe81 持续运行" 5
MITM_LISTEN_BEFORE="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
mitm_listen_verdict "$(sc_state is-active pdg-mitm)" "$MITM_LISTEN_BEFORE" \
  && ok "前像自洽: $MITM_VERDICT_WHY" || { bad "前像不自洽: $MITM_VERDICT_WHY"; PREIMAGE_OK=0; }
# 这一跳**不该动**的东西, 先按内容+属性记指纹
KEEP=(/etc/privdns-gateway/platform /etc/privdns-gateway/mitm.json /etc/privdns-gateway/bot.env
      /etc/mosdns/rules/mitm_hijack.txt /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
      /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py
      /opt/pdg-bot/dot-domain /etc/systemd/system/pdg-mitm.service)
for _f in /etc/privdns-gateway/mitm-ca.pem /etc/privdns-gateway/mitm-ca.key \
          /var/lib/privdns-gateway/ios-state.json; do [[ -e "$_f" ]] && KEEP+=("$_f"); done
declare -A KEEP_FP=()
for _f in "${KEEP[@]}"; do
  [[ -e "$_f" ]] && KEEP_FP["$_f"]="$(sha256sum "$_f" | awk '{print $1}') $(stat -c '%a %u:%g' "$_f")"
done
ok "前像: 这一跳不该动的 ${#KEEP_FP[@]} 项已记指纹(内容 + mode + uid:gid)"
IOS_SCHEMA_BEFORE="$(python3 - <<'PY' 2>/dev/null || true
import json,glob
for p in glob.glob("/var/lib/privdns-gateway/ios*state*.json")+glob.glob("/var/lib/privdns-gateway/ios/*.json"):
    try: print(json.load(open(p)).get("schema","?")); break
    except Exception: pass
PY
)"
note "前像: iOS 记录 schema = ${IOS_SCHEMA_BEFORE:-<没有记录文件>}"
snap_state "hop-before"; svc_snapshot "$E2E_TMP/svc-hop-before.tsv"
[[ "$PREIMAGE_OK" == 1 ]] || { nrun "场景 ②: 前像不成立, 本场景未执行"; e2e_summary; exit $?; }

SECT "④ 真跑公开入口: 取新版 install.sh, 带 --ref 指定桥接版"
NEWENTRY="$E2E_TMP/new-install.sh"
git -C "$ORIGIN" show "main:install.sh" > "$NEWENTRY" || _hard "从裸库 main 取新版入口失败"
ENTRY_SHA="$(sha256sum "$NEWENTRY" | awk '{print $1}')"
[[ "$ENTRY_SHA" == "$(sha256sum "$BRSRC/install.sh" | awk '{print $1}')" ]] \
  && ok "新入口来源: 取自裸库 main(=桥接候选)的 install.sh, 逐字节一致($(cut -c1-12 <<<"$ENTRY_SHA"))" \
  || bad "新入口不是 main 上那一份"
grep -q -- '--ref' "$NEWENTRY" && ok "新入口确实带公开的 --ref 参数" || bad "新入口没有 --ref"
_evn 03-hop-identity.txt "workflow checkout = ${GITHUB_SHA:-<非 CI>}"
_evn 03-hop-identity.txt "旧版 CLI sha256 = $OLD_CLI_SHA (来源: $OLD_TAG → $OLD_SHA, 夹具组装)"
_evn 03-hop-identity.txt "新入口 sha256   = $ENTRY_SHA (来源: 裸库 main → $BRIDGE_SHA)"
_evn 03-hop-identity.txt "显式目标        = $BRIDGE_TAG → $BRIDGE_SHA (tag 对象类型=$(git -C "$ORIGIN" cat-file -t "$BRIDGE_TAG"))"
C_PROD0="$(_j_mark hop-start)" || note "阶段记账: 起界桩没建成($(_j_why))"
HOP_OUT="$E2E_TMP/hop.log"
set +e
env -u PDG_TAG_BOOTSTRAPPED -u PDG_PLATFORM \
    PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 \
    PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
    PDG_DOT_DOMAIN=dot.e2e.test \
    bash "$NEWENTRY" --ref "$BRIDGE_TAG" > "$HOP_OUT" 2>&1
HOP_RC=$?
set -e
C_PROD1="$(_j_mark hop-end)" || note "阶段记账: 止界桩没建成($(_j_why))"
cp "$HOP_OUT" "$EVID/04-hop-install.log" 2>/dev/null; chmod 600 "$EVID/04-hop-install.log" 2>/dev/null || true
tail -40 "$HOP_OUT" | sed 's/^/    /'
_evn 03-hop-identity.txt "公开入口退出码 = $HOP_RC"

SECT "⑤ 逐维验收"
[[ "$HOP_RC" == 0 ]] && ok "⑤-0 返回码: 公开入口以 0 退出" || bad "⑤-0 返回码: rc=$HOP_RC(见 04-hop-install.log)"
grep -q '使用\*\*指定\*\*发布 '"$BRIDGE_TAG" "$HOP_OUT" \
  && ok "⑤-0 报告: 日志写明了使用**指定**发布 $BRIDGE_TAG" || bad "⑤-0 报告: 没有指定版本的输出"
grep -q '指定版本已贯穿到实际安装' "$HOP_OUT" \
  && ok "⑤-0 报告: 安装前的身份门通过并留痕" || bad "⑤-0 报告: 没有身份门输出"
HEAD_AFTER="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 读不到)"
[[ "$HEAD_AFTER" == "$BRIDGE_SHA" ]] \
  && ok "⑤-1 版本身份: $REPO 的 HEAD = 桥接 ${BRIDGE_SHA:0:12}" || bad "⑤-1 版本身份: HEAD=$HEAD_AFTER"
[[ "$HEAD_AFTER" != "$RETIRE_SHA" ]] \
  && ok "⑤-1 版本身份: **没有**误入版本号更高的退役目标 ${RETIRE_SHA:0:12}" || bad "⑤-1 竟然装成了退役目标"
CLI_SHA_AFTER="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
[[ "$CLI_SHA_AFTER" == "$(sha256sum "$BRSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
  && ok "⑤-1 已安装 CLI 逐字节等于桥接版($(cut -c1-12 <<<"$CLI_SHA_AFTER"))" \
  || bad "⑤-1 已安装 CLI 不是桥接版(实得 $(cut -c1-12 <<<"$CLI_SHA_AFTER"))"
[[ "$CLI_SHA_AFTER" != "$OLD_CLI_SHA" ]] && ok "⑤-1 CLI 确实换掉了(不是原地没动)" || bad "⑤-1 CLI 还是旧版"
_MODBAD=0; _MODN=0
while read -r _src _name _mode; do
  [[ -n "$_name" ]] || continue; _MODN=$((_MODN+1))
  cmp -s "$BRSRC/$_src" "/opt/pdg-bot/$_name" || { _MODBAD=$((_MODBAD+1)); echo "       不符: $_name"; }
done < <( ( source "$BRSRC/lib/modules.sh" && pdg_platform_modules ios ) 2>/dev/null )
{ [[ "$_MODN" -gt 0 && "$_MODBAD" == 0 ]]; } \
  && ok "⑤-1 已安装模块: ios 清单 $_MODN 项全部逐字节等于桥接版" || bad "⑤-1 模块有 $_MODBAD 项不符(共 $_MODN)"
_evn 03-hop-identity.txt "安装后: $REPO HEAD=$HEAD_AFTER; CLI sha256=$CLI_SHA_AFTER; ios 模块 $_MODN 项"
for _f in _pdg_save_svcstate _pdg_restore_svcstate _pdg_svcstate_valid _pdg_set_enable_state; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && ok "⑤-2 桥接能力已安装: $_f" || bad "⑤-2 桥接能力缺失: $_f"
done
for _f in migrate_wloc_retire _retire_caller_gate _plat_purge_retired; do
  grep -q "^$_f(){" /usr/local/bin/pdg \
    && bad "⑤-2 装进来了**退役专属**实现 $_f —— 这一跳不该有它" \
    || ok "⑤-2 没有退役专属实现 $_f(这一跳本来就不该带)"
done
_KEEPBAD=0
for _f in "${!KEEP_FP[@]}"; do
  if [[ ! -e "$_f" ]]; then echo "       没了: $_f"; _KEEPBAD=$((_KEEPBAD+1)); continue; fi
  _now="$(sha256sum "$_f" | awk '{print $1}') $(stat -c '%a %u:%g' "$_f")"
  [[ "$_now" == "${KEEP_FP[$_f]}" ]] || { echo "       变了: $_f"; _KEEPBAD=$((_KEEPBAD+1)); }
done
[[ "$_KEEPBAD" == 0 ]] \
  && ok "⑤-3 应保留文件 ${#KEEP_FP[@]} 项的存在性/内容/mode/uid:gid 全部原样(平台标记、WLOC 配置与接管表、MITM 模块与 CA、iOS 记录与产物、bot.env、dot-domain、pdg-mitm unit)" \
  || bad "⑤-3 有 $_KEEPBAD 项被动了(上面逐项列出)"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] \
  && ok "⑤-3 平台标记仍是 ios(公开入口沿用了已有标记, 没把 iOS 改成 Android)" || bad "⑤-3 平台标记变成了 $(cat /etc/privdns-gateway/platform)"
IOS_SCHEMA_AFTER="$(python3 - <<'PY' 2>/dev/null || true
import json,glob
for p in glob.glob("/var/lib/privdns-gateway/ios*state*.json")+glob.glob("/var/lib/privdns-gateway/ios/*.json"):
    try: print(json.load(open(p)).get("schema","?")); break
    except Exception: pass
PY
)"
[[ "$IOS_SCHEMA_AFTER" == "$IOS_SCHEMA_BEFORE" ]] \
  && ok "⑤-3 iOS 记录格式**没有**被推进(schema ${IOS_SCHEMA_BEFORE:-无} → ${IOS_SCHEMA_AFTER:-无})" \
  || bad "⑤-3 iOS schema 被改了: ${IOS_SCHEMA_BEFORE:-无} → ${IOS_SCHEMA_AFTER:-无}"
grep -qE 'WLOC 退役|migrate_wloc_retire|已清理 iOS 专属残留' "$HOP_OUT" \
  && bad "⑤-3 安装日志里出现了退役动作的痕迹" || ok "⑤-3 安装日志里**没有**任何 WLOC 退役/iOS 专属件清理的痕迹"
svc_stable_assert mosdns      running "⑤-4 运行态: mosdns 持续运行" 5
svc_stable_assert mihomo      running "⑤-4 运行态: mihomo 持续运行" 5
svc_stable_assert pdg-mitm    running "⑤-4 运行态: pdg-mitm 仍持续运行(退役没发生)" 5
svc_stable_assert pdg-probe81 running "⑤-4 运行态: pdg-probe81 持续运行" 5
for _u in mosdns mihomo pdg-mitm pdg-probe81; do
  _en="$(sc_state is-enabled "$_u")"
  [[ "$_en" == enabled ]] && ok "⑤-4 自启态: $_u = enabled" || bad "⑤-4 自启态: $_u = $_en"
done
L7894_AFTER="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
mitm_listen_verdict "$(sc_state is-active pdg-mitm)" "$L7894_AFTER" \
  && ok "⑤-4 已加载配置: $MITM_VERDICT_WHY(前像监听数 $MITM_LISTEN_BEFORE → $L7894_AFTER)" \
  || bad "⑤-4 已加载配置不自洽: $MITM_VERDICT_WHY"
_DNSA="$(dig +time=3 +tries=1 @127.0.0.1 gs-loc.apple.com A +short 2>/dev/null | head -1)"
[[ -n "$_DNSA" ]] \
  && ok "⑤-4 实际功能: 本机 :53 真的答得出接管域名(gs-loc.apple.com → $_DNSA) —— 不是只看安装返回 0" \
  || bad "⑤-4 实际功能: :53 答不出接管域名(实得 '${_DNSA:-空}')"
_PDGV="$(pdg version 2>&1 | head -1 || true)"
note "⑤-4 已安装 CLI 自报: ${_PDGV:-<无输出>}"
snap_state "hop-after"; svc_snapshot "$E2E_TMP/svc-hop-after.tsv"
svc_verdict "$E2E_TMP/svc-hop-before.tsv" "$E2E_TMP/svc-hop-after.tsv" "hop"
if [[ -n "${C_PROD0:-}" && -n "${C_PROD1:-}" ]]; then
  for _u in mosdns mihomo pdg-mitm; do
    _n="$(_j_interval "$_u" "$C_PROD0" "$C_PROD1")"
    note "⑤-4 动作窗口: 公开入口这一跳里 $_u 被启动 ${_n:-观测无效} 次(界桩裁决)"
  done
fi

SECT "⑥ 收尾"
{
  echo "# 本轮在这台一次性 runner 上创建/改动的东西"
  echo "  · /etc/{mosdns,mihomo,sing-box,privdns-gateway}/, /opt/{pdg-bot,privdns-gateway}, /var/lib/privdns-gateway"
  echo "  · /etc/systemd/system/{mosdns,mihomo,pdg-bot,pdg-probe81,pdg-mitm}.service"
  echo "  · 自有裸库 $ORIGIN, 旧版源码树 $OLDSRC, 桥接源码树 $BRSRC(都在本轮 \$E2E_TMP 里)"
  echo "  · 停用了 runner 自带的 systemd-resolved(为释放 :53)"
  echo "  全部落在这台一次性 runner 上; runner 随 job 结束销毁。"
  echo
  echo "# 身份"
  echo "  workflow checkout = ${GITHUB_SHA:-<非 CI>}"
  echo "  旧版  = $OLD_TAG → $OLD_SHA (CLI sha256 $OLD_CLI_SHA)"
  echo "  新入口 = 裸库 main → $BRIDGE_SHA (install.sh sha256 $ENTRY_SHA)"
  echo "  显式目标 = $BRIDGE_TAG → $BRIDGE_SHA; 安装后 HEAD=$HEAD_AFTER, CLI sha256=$CLI_SHA_AFTER"
  echo "  未被误装的更高版本 = $RETIRE_TAG → $RETIRE_SHA"
  echo
  echo "# 本支**没有**覆盖的(如实登记)"
  echo "  · 前像是夹具组装的, 不是 v1.11.15 完整安装器跑出来的;"
  echo "  · 取件源是本机裸库与合成 tag, 不是官方 Release —— 正式发布来源仍未验证;"
  echo "  · ③桥接→退役正常升级、④晚期失败恢复都不在本支范围内。"
  echo
  echo "# 证据文件"; ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-cleanup-hop.txt
chmod 600 "$EVID"/* 2>/dev/null || true
echo; echo "未执行(前像/前置不成立而跳过)的场景数: $E2E_NOTRUN"
e2e_summary

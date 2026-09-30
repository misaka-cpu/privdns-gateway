#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真实验收 ①: **原版旧 CLI 直接跳退役版 → 被门拒绝 → 由原版自己回滚**。
#
# 为什么需要这一支: 本地所有判据在 systemd 这一层都是桩。这一支专门补"真 systemd 上到底发生了什么"。
#   tests/test-wloc-retire-{migration,realrun,txn-closure}.sh 各自定义 shell 函数 systemctl;
#   tests/e2e-{migrate,platform-switch}.sh 用 e2e_stub_system 的 systemctl/nft 桩。
# 它们能证明"被测函数发出了哪些调用与自己的文件事务", 证明不了"systemd 真的把服务停了"。
# 这一支专门补那一格, 因此它**绝不打 systemctl / nft 桩**: 环境不满足就硬停, 不退化。
#
# 运行前提(缺一即硬失败, 不 SKIP、不退回桩):
#   · PID 1 是真 systemd, systemctl 是真实可执行文件;
#   · 能真正 enable/start/stop 一个自有 unit, 且能读到 MainPID / InvocationID;
#   · nft 是真实可执行文件, 能建/删自有 table;
#   · 真钉死版 mosdns / mihomo 已就位; git / python3 / openssl / ss 齐备。
#
# **只允许在一次性 CI runner 上跑。** 本脚本会真的写 /etc/systemd/system、真的
# daemon-reload、真的停服务、真的清 /etc/{mosdns,mihomo,sing-box,privdns-gateway}。
# 所以进场第一件事是安全闸: 不是 GitHub Actions 的一次性 runner 就拒绝执行。
#
# 源映射(测试专用, 全部可审计):
#   · /opt/privdns-gateway 的 origin 指向**本机自有裸库**(旧 CLI 的 pdg_fetch_release_tags
#     用的就是这个 remote, 不是硬编码的 REPO_URL) —— 这是 git 原生配置, 不改产品代码;
#   · 裸库里 v1.11.15 与候选都是**真实对象**(SHA 与官方一致), 只有候选那个 tag 名是
#     "仅测试"的合成名; 官方仓库一个字节都不动;
#   · 不使用 PDG_UPDATE_FORCE, 不绕版本关系 / 锁 / 完整性 / 安全校验。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
# ─────────────────────────────────────────────────────────────────────────────
# 关于下面成对出现的抽取标记(每支函数各一对, 名字写在标记行尾):
# 它们**只是注释**, 对本脚本的行为没有任何影响。加它们是因为 tests/e2e-real-bridge-hop.sh
# 要复用这里几支函数的原文, 而"从 name(){ 读到第一行顶格 }"那种抽法会被函数里的 heredoc
# 正文骗到(build_preimage 里写 mitm.json 的那段 JSON 就有一行顶格 })——
# run 34976950055 正是这么截断的。改成按这对唯一标记定点取, 抽出来的片段还要逐个 bash -n。
# 标记必须唯一、成对、BEGIN 在前; 缺失/重复/倒置都由抽取方当场拒绝。
# ─────────────────────────────────────────────────────────────────────────────

E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
E2E_ROOT_REAL="$E2E_ROOT"

# ── 安全闸: 先于 source, 先于任何写操作 ──────────────────────────────────────
_hard(){ echo "[HARD-STOP] $1" >&2; exit 1; }
[[ "${PDG_REAL_MIGRATION_OK:-}" == 1 ]] \
  || _hard "缺 PDG_REAL_MIGRATION_OK=1 —— 这支测试会真的改本机 systemd 与 /etc, 只许在一次性 runner 上跑。"
[[ "${GITHUB_ACTIONS:-}" == "true" ]] \
  || _hard "不在 GitHub Actions 里(GITHUB_ACTIONS=${GITHUB_ACTIONS:-<空>}) —— 拒绝在开发机/生产机上执行。"
[[ "${RUNNER_OS:-}" == "Linux" ]] || _hard "RUNNER_OS=${RUNNER_OS:-<空>}, 只支持 Linux runner。"
[[ "$(id -u)" == 0 ]] || _hard "需要 root(unit 与 nft 都要真的写)。"
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || _hard "需要 PDG_E2E_ISOLATED=1。"

# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"

EVID="${PDG_REAL_MIG_EVID:-${TMPDIR:-/tmp}/real-migration-evidence}"
mkdir -p "$EVID" && chmod 700 "$EVID"
# >>> PDG-EXTRACT-BEGIN _ev
_ev(){ cat >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }
# <<< PDG-EXTRACT-END _ev
# >>> PDG-EXTRACT-BEGIN _evn
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }
# <<< PDG-EXTRACT-END _evn

# >>> PDG-EXTRACT-BEGIN SECT
SECT(){ echo; echo "══════════════════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════════════════"; }
# <<< PDG-EXTRACT-END SECT
# >>> PDG-EXTRACT-BEGIN note
note(){ echo "[NOTE] $1"; }
# <<< PDG-EXTRACT-END note
# ── systemctl 状态的读法(夹具②)────────────────────────────────────────────
# 原来写的是 `V="$(systemctl is-enabled X 2>/dev/null || echo not-found)"`。
# systemd 255 对**已删除的 unit** 会 stdout 打一行 not-found **并且**返回非 0,
# 于是 `|| echo` 再追一行, V 变成两行 "not-found\nnot-found", 等值比较必然失败 ——
# 上一轮那条 [FAIL] pdg-mitm 自启=not-found 就是这么来的, 产品侧其实是对的。
# 现在 stdout / stderr / 退出码**分开收**, 不拼串; 也不用 tail -1 去藏第一行。
SC_VAL=""; SC_RC=0; SC_ERR=""
# shellcheck disable=SC2034  # 保留共享接口 SC_RC(sc_get 的抽取原文不动); ⑤ 自 353 起的新判据不再消费 SC_RC
# >>> PDG-EXTRACT-BEGIN sc_get
sc_get(){   # $1=子命令(is-active|is-enabled|...)  $2=unit
  local errf="${E2E_TMP:-/tmp}/sc.err"
  SC_VAL="$(systemctl "$1" "$2" 2>"$errf")"; SC_RC=$?
  SC_ERR="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
  rm -f "$errf" 2>/dev/null || true
}
# <<< PDG-EXTRACT-END sc_get
# 把"这个 unit 现在到底算什么状态"归一成一个词, 并把判定依据保留下来:
#   active / inactive / failed / activating / …  或  not-found(unit 压根不在)
# >>> PDG-EXTRACT-BEGIN sc_state
sc_state(){  # $1=子命令 $2=unit → 打印归一后的词; 依据留在 SC_VAL/SC_RC/SC_ERR
  sc_get "$1" "$2"
  if [[ -z "${SC_VAL//[[:space:]]/}" ]]; then
    case "$SC_ERR" in *"No such file"*|*"not-found"*|*"could not be found"*) printf 'not-found\n';;
                      *) printf '<空>\n';; esac
  else
    printf '%s\n' "${SC_VAL%%$'\n'*}"
  fi
}
# <<< PDG-EXTRACT-END sc_state

# 未执行 ≠ 失败 ≠ 通过。前像不成立时该场景**不执行**, 单独计一格, 绝不混进通过或失败。
E2E_NOTRUN=0
# >>> PDG-EXTRACT-BEGIN nrun
nrun(){ echo "[未执行] $1"; E2E_NOTRUN=$((E2E_NOTRUN+1)); }
# <<< PDG-EXTRACT-END nrun

# ── 自检: 脚本里不许再出现"把 ca_der_from_pem 当成 mitm_ca 的成员"这种调用 ──────────
# 上一轮只改对了两处里的一处, 另一处照旧 AttributeError, 场景 A 与晚期恢复整场未执行。
# 判据只看**可执行行**(注释里的来龙去脉不必清零); 模式是拼出来的, 免得这条自检自己命中。
_selfcheck_badcall(){
  local pat n
  pat="mitm_ca"".""ca_der_from_pem"
  n="$(grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" | grep -cF -- "$pat" || true)"
  if [[ "$n" == 0 ]]; then
    ok "自检: 可执行行里没有 ${pat} 这种调用(它定义在 iosprofile, 不在 mitm_ca)"
  else
    bad "自检: 可执行行里还有 $n 处 ${pat} —— 上一轮就是漏了第二处"
  fi
}

e2e_enter "$@"

# 两个提交分工明确, 报告里也分开记:
#   · CAND_SHA(候选 X)= **产品**候选。装到机器上的每一个受管文件都只能来自它。
#   · 本脚本所在的验收分支(Y)只提供**验收脚本**; 它的工作区**不是**产品来源。
OLD_SHA="${PDG_OLD_SHA:-242602c17bd92900df81f468aae8c66e18c7a4ff}"   # v1.11.15 peeled
CAND_SHA="${PDG_CAND_SHA:-}"        # 产品候选(冻结退役候选); 必须由派发显式给出
CAND_BASE="${PDG_CAND_BASE:-95caf26f108a7740fc6fbacb7181f775b6f41971}"  # X 与 Y 共同的 base
OLD_TAG="v1.11.15"
TEST_TAG="v9.9.9-wloc-platform-fail-TEST-ONLY"

[[ -n "$CAND_SHA" ]] || _hard "必须显式给出 PDG_CAND_SHA(冻结退役候选) —— 不接受默认值。"

REPO=/opt/privdns-gateway
ORIGIN="$E2E_TMP/real-mig-origin.git"
OLDSRC="$E2E_TMP/oldsrc"          # v1.11.15 的源码树(造前像用的模板都从这里取)
CANDSRC="$E2E_TMP/candsrc"        # **冻结候选**的源码树(装候选产品文件只从这里取)

# ═════════════════════════════════════════════════════════════════════════════
SECT "① 真实环境硬门(任一条不成立即硬停, 不退回桩)"
# ═════════════════════════════════════════════════════════════════════════════
{
  echo "# 一次性 runner 的真实环境证明"
  echo "时间: $(date -u +%FT%TZ)"
  echo "runner: ${RUNNER_NAME:-?} / ${RUNNER_OS:-?} / ${RUNNER_ARCH:-?}  image=${ImageOS:-?} ${ImageVersion:-?}"
  echo "内核: $(uname -srm)"
  echo "发行版: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
} | _ev 01-env.txt

PID1_COMM="$(cat /proc/1/comm 2>/dev/null || echo '?')"
PID1_EXE="$(readlink -f /proc/1/exe 2>/dev/null || echo '?')"
_evn 01-env.txt "PID 1: comm=$PID1_COMM exe=$PID1_EXE"
[[ "$PID1_COMM" == systemd ]] || _hard "PID 1 不是 systemd(comm=$PID1_COMM) —— 这支测试的全部意义就是真 systemd。"
ok "PID 1 是真 systemd(exe=$PID1_EXE)"

SCBIN="$(command -v systemctl || true)"
[[ -n "$SCBIN" ]] || _hard "没有 systemctl。"
case "$SCBIN" in /usr/local/bin/*) _hard "systemctl 解析到 $SCBIN —— 那是本仓桩的落点, 拒绝。";; esac
head -c2 "$SCBIN" 2>/dev/null | grep -q '#!' && _hard "systemctl($SCBIN)是脚本, 不是真实二进制。"
[[ "$(type -t systemctl)" == "file" ]] || _hard "systemctl 被 shell 函数/别名遮蔽(type=$(type -t systemctl))。"
SC_VER="$(systemctl --version 2>/dev/null | head -1)"
SYS_RUNNING="$(systemctl is-system-running 2>&1 | head -1)"
_evn 01-env.txt "systemctl: $SCBIN  ($SC_VER)  is-system-running=$SYS_RUNNING"
ok "systemctl 是真实二进制: $SCBIN ($SC_VER); is-system-running=$SYS_RUNNING"

# 真正的判据不是"命令在", 而是"systemd 真的在管服务": 建一个自有 unit 走一遍全流程。
PROBE=pdg-e2e-realsysd-probe
cat > "/etc/systemd/system/$PROBE.service" <<'EOF'
[Unit]
Description=pdg e2e real-systemd probe (disposable)
[Service]
Type=simple
ExecStart=/bin/sleep 3600
Restart=no
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload || _hard "daemon-reload 失败。"
systemctl enable --now "$PROBE" >/dev/null 2>&1
P_AC="$(systemctl is-active "$PROBE" 2>/dev/null)"
P_EN="$(systemctl is-enabled "$PROBE" 2>/dev/null)"
P_PID="$(systemctl show -p MainPID --value "$PROBE" 2>/dev/null)"
P_INV="$(systemctl show -p InvocationID --value "$PROBE" 2>/dev/null)"
_evn 01-env.txt "探针 unit: is-active=$P_AC is-enabled=$P_EN MainPID=$P_PID InvocationID=$P_INV"
[[ "$P_AC" == active && "$P_EN" == enabled ]] || _hard "自有探针 unit 没被 systemd 真正管起来(active=$P_AC enabled=$P_EN)。"
[[ -n "$P_PID" && "$P_PID" != 0 ]] || _hard "探针 unit 没有真实 MainPID。"
[[ -n "$P_INV" ]] || _hard "探针 unit 没有 InvocationID —— 不是真 systemd 的运行实例。"
kill -0 "$P_PID" 2>/dev/null || _hard "MainPID=$P_PID 不是活着的进程。"
ok "systemd 真的在管服务: 自有探针 active/enabled, MainPID=$P_PID, InvocationID 非空"
systemctl disable --now "$PROBE" >/dev/null 2>&1
rm -f "/etc/systemd/system/$PROBE.service"; systemctl daemon-reload
[[ "$(systemctl is-active "$PROBE" 2>/dev/null)" != active ]] \
  && ok "探针 unit 已真实停止并移除(本轮自建资源, 具名清理)" || bad "探针 unit 没停干净"

NFTBIN="$(command -v nft || true)"
[[ -n "$NFTBIN" ]] || _hard "没有 nft。"
case "$NFTBIN" in /usr/local/bin/*) _hard "nft 解析到 $NFTBIN —— 那是本仓桩的落点, 拒绝。";; esac
head -c2 "$NFTBIN" 2>/dev/null | grep -q '#!' && _hard "nft($NFTBIN)是脚本, 不是真实二进制。"
nft list ruleset >/dev/null 2>&1 || _hard "nft list ruleset 失败 —— 拿不到真实内核规则。"
nft add table inet pdg_e2e_probe 2>/dev/null && nft delete table inet pdg_e2e_probe 2>/dev/null \
  && ok "nft 能对内核真实生效(自有 table 建/删成功)" || _hard "nft 不能建自有 table —— 没有真实 netfilter 能力。"
_evn 01-env.txt "nft: $NFTBIN  ($(nft --version 2>/dev/null))"

for c in git python3 openssl ss curl sha256sum; do
  command -v "$c" >/dev/null 2>&1 || _hard "缺命令: $c"
done
ok "基础命令齐备(git/python3/openssl/ss/curl/sha256sum)"
_selfcheck_badcall

e2e_mihomo_is_real 2>/dev/null && ok "mihomo 是真钉死版二进制" || _hard "mihomo 不是真二进制(夹具没装上?)"
[[ -f /usr/local/bin/mosdns && "$(stat -c %s /usr/local/bin/mosdns)" -gt 1000000 ]] \
  && ok "mosdns 是真二进制($(stat -c %s /usr/local/bin/mosdns) 字节)" || _hard "mosdns 不是真二进制。"
_evn 01-env.txt "mosdns sha256: $(sha256sum /usr/local/bin/mosdns | awk '{print $1}')"
_evn 01-env.txt "mihomo sha256: $(sha256sum "$(command -v mihomo)" | awk '{print $1}')"

GH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://github.com/ 2>/dev/null || echo 000)"
_evn 01-env.txt "github.com HTTP=$GH_CODE"
[[ "$GH_CODE" != 000 ]] && ok "github.com 可达(HTTP $GH_CODE)" || bad "github.com 不可达 —— 真实取件路径受限"

# 53 端口: runner 上的 systemd-resolved 会占着, 真起 mosdns 必须先让开。这是对**本轮被测机**
# 的改动, 不是对开发宿主的改动。
if systemctl is-active systemd-resolved >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1
  _evn 01-env.txt "已停用 runner 自带的 systemd-resolved(为释放 :53; 一次性 runner 专属改动)"
  note "已停用 systemd-resolved 以释放 :53"
fi
rm -f /etc/resolv.conf 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

# ═════════════════════════════════════════════════════════════════════════════
SECT "② 测试源映射(真实对象 + 仅测试的候选 tag; 不动官方仓库)"
# ═════════════════════════════════════════════════════════════════════════════
# safe.directory 由 e2e_enter 的 _e2e_git_safe 处理(写 /etc/gitconfig), 这里不再另设全局配置。

for s in "$OLD_SHA" "$CAND_SHA"; do
  [[ "$(git -C "$E2E_ROOT_REAL" cat-file -t "$s" 2>/dev/null)" == commit ]] \
    || _hard "工作区里取不到对象 $s(checkout 深度不够?)"
done
ok "冻结旧版与冻结候选的**真实对象**都在工作区里"

# 裸库: 只有它是旧 CLI 的取件目标。先拿工作区的对象做种, 再补 tag。
rm -rf "$ORIGIN"
git clone --bare -q "$E2E_ROOT_REAL" "$ORIGIN" || _hard "建裸库失败"
e2e_guard_repo "$ORIGIN" || _hard "裸库没通过 ref 库守卫"
e2e_git "$ORIGIN" fetch -q "$E2E_ROOT_REAL" "+refs/tags/*:refs/tags/*" 2>/dev/null || true
# 旧版 tag: 官方那一个是附注 tag。工作区取得到就原样搬过来, 取不到就按真实对象补一个
# 轻量 tag —— 两种情形分开记, 不混报。
if [[ "$(git -C "$ORIGIN" rev-parse -q --verify "$OLD_TAG^{commit}" 2>/dev/null)" == "$OLD_SHA" ]]; then
  OLD_TAG_KIND="$(git -C "$ORIGIN" cat-file -t "$OLD_TAG" 2>/dev/null)"
  ok "裸库里的 $OLD_TAG 指向真实对象 $OLD_SHA(tag 对象类型=$OLD_TAG_KIND)"
else
  e2e_git "$ORIGIN" tag -f "$OLD_TAG" "$OLD_SHA" >/dev/null 2>&1
  OLD_TAG_KIND="lightweight(本轮补建)"
  note "工作区没带来官方 $OLD_TAG 的 tag 对象, 已按真实提交 $OLD_SHA 补一个轻量 tag; 与真实发布的差异已记录"
fi
# 候选 tag: 名字是"仅测试"的合成名, 对象是**真实候选**。
e2e_git "$ORIGIN" tag -f "$TEST_TAG" "$CAND_SHA" >/dev/null 2>&1 || _hard "建测试候选 tag 失败"
T_PEEL="$(git -C "$ORIGIN" rev-parse "$TEST_TAG^{commit}" 2>/dev/null)"
[[ "$T_PEEL" == "$CAND_SHA" ]] || _hard "测试 tag 没指向冻结候选($T_PEEL)"
# **裸库必须真的有 refs/heads/main**: 旧 CLI 的 pdg_fetch_release_tags 跑的是
# `git fetch --tags origin main` —— 上一轮就栽在这里(裸库是从只有验收分支的工作区 clone 的,
# 远端没有 main, 于是整条升级链停在取件)。它指向**产品候选 X**, 不是验收分支。
e2e_git "$ORIGIN" update-ref refs/heads/main "$CAND_SHA" || _hard "裸库建 refs/heads/main 失败"
[[ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" == "$CAND_SHA" ]] \
  && ok "裸库 refs/heads/main → 产品候选 X($CAND_SHA)" || _hard "裸库 main 指错了"
# 顺手把验收分支自己的 ref 从裸库里去掉 —— 产品来源只能是 X, 不留第二条可能被选中的分支。
for _br in $(git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads | grep -v '^refs/heads/main$'); do
  e2e_git "$ORIGIN" update-ref -d "$_br" >/dev/null 2>&1 || true
done
# 裸库的 HEAD 也指过去 —— 否则它还指着被删掉的那条分支, clone 出来没有工作树(只是个
# warning, 但后面"装的是旧版"这件事就没有干净的起点了)。
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
BRLIST="$(git -C "$ORIGIN" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')"
[[ "$BRLIST" == "refs/heads/main " ]] \
  && ok "裸库里只剩 refs/heads/main 一条分支(产品来源唯一)" || bad "裸库里还有别的分支: $BRLIST"

SEL="$(git -C "$ORIGIN" tag -l 'v*' --sort=-v:refname | head -1)"
[[ "$SEL" == "$TEST_TAG" ]] || _hard "旧 CLI 会选中的 tag 是 $SEL, 不是本轮的测试 tag —— 源映射无效, 停。"
ok "旧 CLI 的选择逻辑(tag -l 'v*' --sort=-v:refname | head -1)选中 $TEST_TAG → $CAND_SHA"

# ── 用**旧 CLI 实际使用的那两条查询**证明映射可用, 不是"对象存在就算数" ──────
# 一次性探针 clone: 不碰后面真正要被升级的 /opt/privdns-gateway。
PROBE="$E2E_TMP/mapping-probe"
rm -rf "$PROBE"
if git clone -q "$ORIGIN" "$PROBE" 2>/dev/null; then
  e2e_guard_repo "$PROBE" || _hard "探针 clone 没通过 ref 库守卫"
  # 产品里那一句原样搬过来: git -C "$dir" fetch -q --tags origin main
  # 与产品 pdg_fetch_release_tags 里那一句逐字相同, 只是外面多一层 ref 库守卫。
  if e2e_git "$PROBE" fetch -q --tags origin main 2>"$E2E_TMP/probe.err"; then
    ok "旧 CLI 的取件查询可用(fetch --tags origin main)rc=0"
  else
    _hard "旧 CLI 的取件查询失败(这正是上一轮的 H1): $(head -2 "$E2E_TMP/probe.err" | tr '\n' ' ')"
  fi
  PFH="$(git -C "$PROBE" rev-parse FETCH_HEAD 2>/dev/null)"
  [[ "$PFH" == "$CAND_SHA" ]] && ok "FETCH_HEAD == 产品候选 X" || bad "FETCH_HEAD=$PFH"
  PSEL="$(git -C "$PROBE" tag -l 'v*' --sort=-v:refname | head -1)"
  PPEEL="$(git -C "$PROBE" rev-parse "$PSEL^{commit}" 2>/dev/null)"
  { [[ "$PSEL" == "$TEST_TAG" && "$PPEEL" == "$CAND_SHA" ]]; } \
    && ok "取件之后再查一次: 最新 v* tag = $PSEL → X(与产品的选择逻辑逐字一致)" \
    || _hard "取件后选出的是 $PSEL → $PPEEL"
  POLD="$(git -C "$PROBE" rev-parse "$OLD_TAG^{commit}" 2>/dev/null)"
  [[ "$POLD" == "$OLD_SHA" ]] && ok "真实 v1.11.15 tag 对象与旧提交在裸库里保持正确" \
                              || bad "v1.11.15 peel 成了 $POLD"
  rm -rf "$PROBE"
else
  _hard "建映射探针 clone 失败"
fi
{
  echo "# 测试源映射"
  echo "裸库: $ORIGIN (本机自有, 一次性)"
  echo "映射方式: /opt/privdns-gateway 的 git remote origin 指向该裸库"
  echo "  —— 旧 CLI 的 pdg_fetch_release_tags 用的是 \$REPO_DIR 的 origin remote,"
  echo "     不是硬编码的 REPO_URL; 因此这是 git 原生配置, 未改任何产品代码。"
  echo "旧版 tag : $OLD_TAG → $OLD_SHA  (类型: $OLD_TAG_KIND)"
  echo "候选 tag : $TEST_TAG → $CAND_SHA  (**仅测试**的合成 tag 名; 对象是真实候选)"
  echo "旧 CLI 选中的目标: $SEL"
  echo "裸库全部 v* tag:"; git -C "$ORIGIN" tag -l 'v*' --sort=-v:refname | sed 's/^/  /'
  echo
  echo "与正式发布路径的差异(逐条):"
  echo "  1. 正式路径取件自 https://github.com/misaka-cpu/privdns-gateway.git; 本轮取件自本机裸库。"
  echo "  2. 正式路径的目标是官方 v* tag; 本轮是仅存在于该裸库的合成 tag $TEST_TAG。"
  echo "  3. 候选提交 $CAND_SHA 在官方仓库里**没有 tag、没有 Release** —— 本轮不打、不发。"
  echo "  4. 其余全部一致: 真实对象、真实 git 取件、真实锁、真实完整性与版本关系判定。"
} | _ev 02-source-map.txt

# v1.11.15 的源码树: 造前像用的模板/模块都从这里取, 不用候选的
rm -rf "$OLDSRC"; mkdir -p "$OLDSRC"
git -C "$ORIGIN" archive "$OLD_SHA" | tar -x -C "$OLDSRC" || _hard "展开 v1.11.15 源码失败"
[[ -f "$OLDSRC/deploy/bot/mitm_wloc.py" && -f "$OLDSRC/deploy/bot/mitm_server.py" ]] \
  && ok "旧版源码树含 WLOC 执行模块(mitm_server.py / mitm_wloc.py) —— 前像的真实来源" \
  || _hard "旧版源码树不对: 没有 WLOC 模块"

# 冻结候选的源码树: 装候选产品文件只从这里取, 不从测试分支工作区取。
rm -rf "$CANDSRC"; mkdir -p "$CANDSRC"
git -C "$ORIGIN" archive "$CAND_SHA" | tar -x -C "$CANDSRC" || _hard "展开冻结候选源码失败"
[[ ! -e "$CANDSRC/deploy/bot/mitm_wloc.py" && ! -e "$CANDSRC/deploy/bot/mitm_server.py" ]] \
  && ok "候选源码树里 WLOC 执行模块已不存在(退役后的形态)" || _hard "候选源码树不对: 还有 WLOC 模块"

# **验收分支(Y)不是产品候选**。两条各自对账, 不混:
#   · Y 相对共同 base 的产品面必须零差异 —— 验收脚本不许夹带产品改动;
#   · X 相对同一个 base 的产品面差异, 逐文件列出来 —— 那才是本轮要验的产品改动。
# 验收分支建在**冻结候选之上**, 所以这里比的是"验收分支相对候选有没有动产品面" ——
# 它只该多出 tests/ 与 workflow。比 base 没有意义(那会把候选自己的产品改动算到验收分支头上)。
# 两种"验收分支产品面与候选不同"要分开判, 不能混成一条:
#   (a) 验收分支**自己改了**产品面 —— 验收脚本夹带产品改动, 判红;
#   (b) 验收分支只是停在**更旧的对象**上(候选后来又往前走了) —— 如实报告, 不判红:
#       装到这台机器上的每一个产品文件都只来自候选($CANDSRC / 裸库 main), 下面逐项断言过。
# 判别方式: 拿两者的共同祖先当基准, 看**验收分支这一侧**有没有动过产品面。
YMB="$(git -C "$E2E_ROOT_REAL" merge-base "$CAND_SHA" HEAD 2>/dev/null)"
YPROD="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_SHA" -- deploy lib install.sh uninstall.sh tools 2>/dev/null)"
YOWN="$(git -C "$E2E_ROOT_REAL" diff --name-only "$YMB" HEAD -- deploy lib install.sh uninstall.sh tools 2>/dev/null)"
_evn 02-source-map.txt "验收分支 HEAD=${GITHUB_SHA:-$(git -C "$E2E_ROOT_REAL" rev-parse HEAD 2>/dev/null)}; 与候选的共同祖先=$YMB"
_evn 02-source-map.txt "验收分支自己动过的产品面: ${YOWN:-<无>}; 相对候选的产品面差异: $(tr '\n' ' ' <<<"$YPROD")"
if [[ -n "$YOWN" ]]; then
  bad "验收分支**自己改了**产品面(相对共同祖先 $YMB): $(tr '\n' ' ' <<<"$YOWN")"
elif [[ -n "$YPROD" ]]; then
  ok "验收分支自己没动过产品面(相对共同祖先 ${YMB:0:12} 零差异)"
  note "验收分支的产品树仍是**旧对象**: 相对候选差这几个文件 —— $(tr '\n' ' ' <<<"$YPROD")"
  note "  原因: 验收线建在共同祖先 ${YMB:0:12} 上, 候选 ${CAND_SHA:0:12} 之后又往前走了。"
  note "  被测产品**不取自验收分支**: /usr/local/bin/pdg 与 /opt/pdg-bot 全部来自候选源码树,"
  note "  裸库 refs/heads/main 也指向候选 —— 下面逐项断言(部署身份/受管清单/回滚实现)。"
else
  ok "验收分支相对**冻结候选**的产品面**零差异**(它只提供验收脚本与 workflow)"
fi
YEXTRA="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_SHA" 2>/dev/null | tr '\n' ' ')"
_evn 02-source-map.txt "验收分支相对候选的全部改动: ${YEXTRA:-<无>}"
ok "验收分支相对候选只多出: ${YEXTRA:-<无>}"
XPROD="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_BASE" "$CAND_SHA" -- deploy lib install.sh uninstall.sh tools 2>/dev/null | tr '\n' ' ')"
_evn 02-source-map.txt "产品候选 X 相对 base 的产品面改动: ${XPROD:-<无>}"
ok "产品候选 X 相对 base 的产品面改动: ${XPROD:-<无>}"
YALL="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_BASE" 2>/dev/null | tr '\n' ' ')"
_evn 02-source-map.txt "验收分支 Y 相对 base 的全部改动: ${YALL:-<无>}"

# ═════════════════════════════════════════════════════════════════════════════
# 状态采集器: 每个场景操作前后都跑一次, 结果写进证据目录
# ═════════════════════════════════════════════════════════════════════════════
# >>> PDG-EXTRACT-BEGIN snap_state
snap_state(){   # $1 = 标签
  local tag="$1" f="$EVID/state-$1.txt" s q
  {
    echo "################ 状态快照: $tag   @ $(date -u +%FT%TZ)"
    echo "── 服务(真 systemd) ──"
    for s in pdg-mitm mosdns mihomo pdg-bot pdg-probe81; do
      printf '  %-13s active=%-10s sub=%-12s enabled=%-14s MainPID=%-8s NRestarts=%-3s Invocation=%s\n' \
        "$s" \
        "$(systemctl is-active "$s" 2>/dev/null || echo -)" \
        "$(systemctl show -p SubState --value "$s" 2>/dev/null)" \
        "$(systemctl is-enabled "$s" 2>/dev/null || echo -)" \
        "$(systemctl show -p MainPID --value "$s" 2>/dev/null)" \
        "$(systemctl show -p NRestarts --value "$s" 2>/dev/null)" \
        "$(systemctl show -p InvocationID --value "$s" 2>/dev/null)"
    done
    echo "  failed units: $(systemctl list-units --failed --no-legend 2>/dev/null | wc -l)"
    echo "── 文件(存在性 / mode / uid:gid / sha256) ──"
    for q in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py \
             /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py \
             /etc/mosdns/rules/mitm_hijack.txt /etc/privdns-gateway/mitm.json \
             /etc/privdns-gateway/ca/ca.crt /etc/privdns-gateway/ca/ca.key \
             /etc/privdns-gateway/ios-profile.json \
             /var/lib/privdns-gateway/ios-profile/current.mobileconfig \
             /etc/mihomo/config.yaml /usr/local/bin/pdg; do
      if [[ -e "$q" ]]; then
        printf '  有 %-62s %s %s:%s %s\n' "$q" "$(stat -c %a "$q")" "$(stat -c %U "$q")" "$(stat -c %G "$q")" \
          "$(sha256sum "$q" 2>/dev/null | cut -c1-16)"
      else
        printf '  无 %s\n' "$q"
      fi
    done
    echo "── mitm_hijack.txt 内容(逐行) ──"; sed 's/^/    /' /etc/mosdns/rules/mitm_hijack.txt 2>/dev/null || echo "    (不存在)"
    echo "── mitm.json ──"; sed 's/^/    /' /etc/privdns-gateway/mitm.json 2>/dev/null || echo "    (不存在)"
    echo "── mihomo 配置里的 MITM 痕迹 ──"
    echo "    MITM-OUT 出现次数: $(grep -c 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null || echo 0)"
    echo "    gs-loc 规则次数  : $(grep -c 'gs-loc' /etc/mihomo/config.yaml 2>/dev/null || echo 0)"
    echo "── iOS 记录 schema / 身份 ──"
    python3 - <<'PY' 2>/dev/null || echo "    (读不到)"
import json
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
    cur = m.get("current") or {}
    # **输入在 current.inputs**(schema 1 与 2 都是); 顶层从来没有 inputs 这个字段。
    # 退役之后 current 会是 None, 用户意图改由 retired_inputs 兜住 —— 两处都打出来, 不猜。
    inp = cur.get("inputs") or {}
    ri  = m.get("retired_inputs") or {}
    print("    schema=%r instance_id=%r current.revision=%r 顶层有 inputs=%r"
          % (m.get("schema"), m.get("instance_id"), cur.get("revision"), "inputs" in m))
    print("    current.inputs: schema=%r wloc_enabled=%r wloc_ca_sha256=%r ssids=%r"
          % (inp.get("schema"), inp.get("wloc_enabled"), (inp.get("wloc_ca_sha256") or "")[:12], inp.get("ssids")))
    print("    retired_revision=%r retired_inputs.ssids=%r" % (m.get("retired_revision"), ri.get("ssids")))
except Exception as e:
    print("    (无记录: %s)" % e)
PY
    echo "── 监听端口 ──"; ss -lntup 2>/dev/null | awk 'NR==1||/:(53|443|81|853|7893|7894|9090)\b/' | sed 's/^/    /'
    echo "── nft 规则语义(表/链/计数) ──"
    nft -a list ruleset 2>/dev/null | grep -E '^(table|\s+chain|\s+type)' | sed 's/^/    /' | head -40
    echo "    规则总条数: $(nft -a list ruleset 2>/dev/null | grep -cE '# handle [0-9]+')"
    echo "    含 7894 的规则: $(nft list ruleset 2>/dev/null | grep -c 7894)"
    echo "── force_hijack 的其它消费者 ──"
    echo "    mosdns 配置里引用 mitm_hijack.txt 次数: $(grep -c 'mitm_hijack' /etc/mosdns/config.yaml 2>/dev/null || echo 0)"
    echo "    force_hijack 出现次数: $(grep -c 'force_hijack' /etc/mosdns/config.yaml 2>/dev/null || echo 0)"
    echo "── 仓库版本 ──"
    echo "    $(git -C "$REPO" describe --tags --always 2>/dev/null || echo '(无仓库)')  HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo -)"
  } > "$f" 2>&1
  chmod 600 "$f"
  echo "  [状态已采集] $f"
}
# <<< PDG-EXTRACT-END snap_state

state_diff(){   # $1=before 标签  $2=after 标签  $3=场景名
  local d="$EVID/diff-$3.txt"
  diff "$EVID/state-$1.txt" "$EVID/state-$2.txt" > "$d" 2>&1
  chmod 600 "$d"
  echo "  [差分] $d  ($(grep -cE '^[<>]' "$d") 行变化)"
}

# ═════════════════════════════════════════════════════════════════════════════
# 前像构造: 用**旧版自己的代码与模板**造。明确记账 ——
#   这是"建立了真实运行前像", **不是**"完整执行过旧安装器"。两者不互相冒充。
# ═════════════════════════════════════════════════════════════════════════════
# ── 本轮测试**明确创建或安装**的 unit 白名单 ────────────────────────────────
# 只复位这几个。**绝不**泛扫宿主服务, 也绝不出现 sing-box / pdg-rescue.* 这类本测试
# 从不安装的名字 —— 上一轮 e2e_reset_box 的合并命令里恰好有它们, 在真 systemd 下
# "列表里有不存在的 unit" 会让整条 `disable --now` 返回非 0, 既有 unit 未必真被停,
# 而那条命令的返回值被 `|| true` 吞掉 ⇒ 进入下一场景时 pdg-mitm 还在跑(H6)。
# >>> PDG-EXTRACT-BEGIN E2E_OWNED_UNITS
E2E_OWNED_UNITS=(pdg-mitm.service pdg-bot.service pdg-probe81.service
                 mosdns.service mihomo.service pdg-dotwitness.service
                 pdg-health.service pdg-health.timer
                 pdg-rules-update.service pdg-rules-update.timer)
# <<< PDG-EXTRACT-END E2E_OWNED_UNITS

# 逐个 unit 复位, 每个动作留自己的退出码并**立刻复核真实状态**。不吞失败。
# >>> PDG-EXTRACT-BEGIN reset_units_strict
reset_units_strict(){
  local u ls as ufs rc acted=0 notthere=0 fail=0
  echo "── 逐项复位(白名单 ${#E2E_OWNED_UNITS[@]} 个 unit; 不泛扫宿主服务)──"
  for u in "${E2E_OWNED_UNITS[@]}"; do
    ls="$(systemctl show -p LoadState --value "$u" 2>/dev/null)"
    as="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
    ufs="$(systemctl show -p UnitFileState --value "$u" 2>/dev/null)"
    if [[ "$ls" == not-found && ! -e "/etc/systemd/system/$u" ]]; then
      printf '    %-26s 本来不存在(LoadState=not-found, 无 unit 文件)\n' "$u"
      notthere=$((notthere+1)); continue
    fi
    printf '    %-26s LoadState=%s ActiveState=%s UnitFileState=%s\n' "$u" "${ls:-?}" "${as:-?}" "${ufs:-<空>}"
    if [[ "$as" == active || "$as" == activating || "$as" == reloading ]]; then
      systemctl stop "$u"; rc=$?
      as="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
      printf '      stop rc=%s → ActiveState=%s\n' "$rc" "$as"
      { [[ "$as" == inactive || "$as" == failed ]]; } || { bad "复位: $u 停止后仍是 $as(stop rc=$rc)"; fail=1; }
      acted=1
    fi
    if [[ "$ufs" == enabled || "$ufs" == enabled-runtime ]]; then
      systemctl disable "$u" >/dev/null 2>&1; rc=$?
      ufs="$(systemctl show -p UnitFileState --value "$u" 2>/dev/null)"
      printf '      disable rc=%s → UnitFileState=%s\n' "$rc" "${ufs:-<空>}"
      { [[ "$ufs" == enabled || "$ufs" == enabled-runtime ]]; } && { bad "复位: $u 禁用后仍是 $ufs(disable rc=$rc)"; fail=1; }
      acted=1
    fi
    if [[ -e "/etc/systemd/system/$u" ]]; then
      rm -f "/etc/systemd/system/$u"; rc=$?
      printf '      rm unit rc=%s → 文件仍在? %s\n' "$rc" "$([[ -e "/etc/systemd/system/$u" ]] && echo 是 || echo 否)"
      [[ -e "/etc/systemd/system/$u" ]] && { bad "复位: $u 的 unit 文件没删掉(rm rc=$rc)"; fail=1; }
      acted=1
    fi
  done
  if [[ "$acted" == 1 ]]; then
    systemctl daemon-reload; rc=$?
    printf '    daemon-reload rc=%s\n' "$rc"
    [[ "$rc" == 0 ]] || { bad "复位: daemon-reload 失败(rc=$rc)"; fail=1; }
  else
    printf '    本轮无需 daemon-reload(%d 个 unit 本来就不存在)\n' "$notthere"
  fi
  return "$fail"
}
# <<< PDG-EXTRACT-END reset_units_strict

# 复位之后必须**证明**现场干净: 服务、监听、配置、本轮网络资源各查一遍。
# 证明不了就停 —— 不让下一场景在污染状态下继续。
# >>> PDG-EXTRACT-BEGIN reset_proof
reset_proof(){   # $1 = 场景名
  local u as bad_list="" n
  for u in "${E2E_OWNED_UNITS[@]}"; do
    as="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
    [[ "$as" == active || "$as" == activating ]] && bad_list="$bad_list $u($as)"
  done
  n="$(ss -lnt 2>/dev/null | grep -c ':7894' || true)"
  [[ "$n" != 0 ]] && bad_list="$bad_list 7894仍有监听"
  [[ -e /etc/privdns-gateway/ca/ca.key ]] && bad_list="$bad_list 残留CA私钥"
  [[ -e /opt/pdg-bot/mitm_wloc.py ]] && bad_list="$bad_list 残留mitm_wloc.py"
  nft list table inet pdg_e2e_probe >/dev/null 2>&1 && bad_list="$bad_list 本轮nft表未清"
  if [[ -z "$bad_list" ]]; then
    ok "场景隔离($1): 白名单 unit 全部非活跃, 7894 无监听, 配置与本轮网络资源已复位"
    return 0
  fi
  bad "场景隔离($1): 收尾无法确认, 残留:$bad_list"
  _hard "上一场景收尾无法确认, 停止 —— 不让下一场景在污染状态下继续。"
}
# <<< PDG-EXTRACT-END reset_proof

PREIMAGE_OK=1     # 每次 build_preimage 复位; 任一前像判据不成立即置 0
# >>> PDG-EXTRACT-BEGIN build_preimage
build_preimage(){   # $1 = ios|android   $2 = wloc on|off|caonly
  local plat="$1" wloc="$2"
  PREIMAGE_OK=1
  reset_units_strict || bad "逐项复位过程中有动作未达预期(详见上面的逐条记录)"
  e2e_reset_box
  reset_proof "进入 $plat/$wloc 之前"
  local SAVE="$E2E_ROOT"; E2E_ROOT="$OLDSRC"
  e2e_seed_install    >/dev/null 2>&1 || { bad "e2e_seed_install 失败"; E2E_ROOT="$SAVE"; return 1; }
  e2e_seed_mosdns all >/dev/null 2>&1 || { bad "e2e_seed_mosdns 失败"; E2E_ROOT="$SAVE"; return 1; }
  e2e_seed_singbox_model
  e2e_seed_nft mihomo >/dev/null 2>&1 || { bad "e2e_seed_nft 失败"; E2E_ROOT="$SAVE"; return 1; }
  e2e_seed_cert       >/dev/null 2>&1 || { bad "e2e_seed_cert 失败"; E2E_ROOT="$SAVE"; return 1; }
  printf '%s\n' "$plat"  > /etc/privdns-gateway/platform
  printf 'mihomo\n'      > /etc/privdns-gateway/backend
  # Telegram 凭据留空 = 合法禁用态: pdg-bot 不进 expected_services, doctor 不据此判红。
  printf 'PDG_BOT_TOKEN=\nPDG_BOT_ALLOWED=\n' > /etc/privdns-gateway/bot.env
  chmod 600 /etc/privdns-gateway/bot.env
  mkdir -p /var/lib/privdns-gateway

  # /opt/privdns-gateway 换成指向自有裸库的真 clone, 并停在 v1.11.15
  rm -rf "$REPO"
  git clone -q "$ORIGIN" "$REPO" || { bad "clone 裸库到 $REPO 失败"; E2E_ROOT="$SAVE"; return 1; }
  e2e_guard_repo "$REPO" || { bad "$REPO 没通过 ref 库守卫"; E2E_ROOT="$SAVE"; return 1; }
  e2e_git "$REPO" checkout -q "$OLD_SHA" 2>/dev/null || e2e_git "$REPO" checkout -q "$OLD_TAG"
  # 新 tag 只留在 origin 上, 逼 update 真的去 fetch
  e2e_git "$REPO" tag -d "$TEST_TAG" >/dev/null 2>&1 || true

  # 机器上装的是**旧版**的脚本与模块 —— 这才是存量用户的现场。
  # 清单**从旧版自己的 lib/modules.sh 推导**, 不再手写 `deploy/bot/*.py` 循环:
  # 那个循环漏掉了跨目录的一项 —— deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl
  # → /opt/pdg-bot/pdg-dot.mobileconfig.tmpl, 而 iosprofile.TEMPLATE 正指着它。
  # 上一轮 iosstate.generate() 因此必然抛错, schema-1 记录与产物一个都没造出来(H2)。
  install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
  e2e_reset_botdir >/dev/null 2>&1
  # shellcheck source=/dev/null
  source "$REPO/lib/modules.sh" || { bad "读不到旧版 lib/modules.sh"; E2E_ROOT="$SAVE"; return 1; }
  # CA-only 场景(android + caonly)要先有 iOS 那几件才造得出 CA —— 按 iOS 清单先装齐,
  # 造完 CA 再按 android 形态收走执行件(H3: 顺序反了就 import 不到 mitm_ca)。
  local inst_plat="$plat"
  [[ "$wloc" == caonly ]] && inst_plat=ios
  pdg_install_runtime_modules "$REPO" /opt/pdg-bot "$inst_plat" \
    || { bad "按旧版清单装运行模块失败(平台 $inst_plat)"; E2E_ROOT="$SAVE"; return 1; }
  echo dot.e2e.test > /opt/pdg-bot/dot-domain
  if [[ "$inst_plat" == ios ]]; then
    [[ -f /opt/pdg-bot/pdg-dot.mobileconfig.tmpl ]] \
      && ok "前像: iOS 描述文件模板已按旧版清单就位(跨目录那一项没漏)" \
      || bad "前像: 缺 /opt/pdg-bot/pdg-dot.mobileconfig.tmpl"
  fi

  # 真 unit(照旧版 install.sh 的写法), 然后真的起起来
  cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  # shellcheck source=/dev/null
  source "$OLDSRC/lib/units.sh"
  pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service
  install -m644 "$OLDSRC/deploy/bot/pdg-probe81.service" /etc/systemd/system/ 2>/dev/null || true
  install -m644 "$OLDSRC/deploy/bot/pdg-health.service"  /etc/systemd/system/ 2>/dev/null || true
  install -m644 "$OLDSRC/deploy/bot/pdg-health.timer"    /etc/systemd/system/ 2>/dev/null || true
  sed -e 's|__DOT_DOMAIN__|dot.e2e.test|g' -e "s|__SERVER_IP__|203.0.113.1|g" \
      -e 's|__INTERNAL_CIDR__|127.0.0.0/8|g' -e 's|__CERT_DIR__|/etc/mosdns/certs|g' \
      "$OLDSRC/deploy/bot/pdg-bot.service" > /etc/systemd/system/pdg-bot.service 2>/dev/null || true
  chmod 644 /etc/systemd/system/pdg-bot.service 2>/dev/null || true

  if [[ "$plat" == ios ]]; then
    pdg_write_unit pdg_unit_pdg_mitm /etc/systemd/system/pdg-mitm.service
  fi
  E2E_ROOT="$SAVE"

  # 真 CA: 用**旧版自己的 mitm_ca** 现签一份自造根证书。必须在收走执行件**之前**做 ——
  # 上一轮正是先 rm 了 mitm_ca.py 再去 import 它(H3), CA-only 前像根本没造出来。
  if [[ "$wloc" == on || "$wloc" == caonly ]]; then
    if ( cd /opt/pdg-bot && python3 -c 'import mitm_ca; mitm_ca.ensure_ca()' ) >"$E2E_TMP/ca.log" 2>&1; then
      ok "前像: 用旧版 mitm_ca 真实签出自造 CA"
    else
      bad "前像: ensure_ca 失败: $(tail -2 "$E2E_TMP/ca.log" | tr '\n' ' ')"; PREIMAGE_OK=0
    fi
  fi

  # CA-only: 现在才把执行能力收走, 并先确认没有进程还在用它们。
  if [[ "$wloc" == caonly ]]; then
    local st7894 stmitm
    st7894="$(ss -lnt 2>/dev/null | grep -c ':7894' || true)"
    stmitm="$(sc_state is-active pdg-mitm)"
    { [[ "$st7894" == 0 && "$stmitm" != active ]]; } \
      && ok "CA-only: 收走执行件之前确认无人在用(7894 无监听, pdg-mitm=$stmitm)" \
      || { bad "CA-only: 还有进程在用执行件(7894 计数=$st7894, pdg-mitm=$stmitm), 不删"; PREIMAGE_OK=0; }
    if [[ "$st7894" == 0 && "$stmitm" != active ]]; then
      # 逐个具名删除, 不按前缀扫。删的是**本场景刚刚自己装上去的**那几件。
      local m
      for m in iosprofile.py iosstate.py mitm_ca.py mitm_server.py mitm_wloc.py pdg-dot.mobileconfig.tmpl; do
        rm -f "/opt/pdg-bot/$m"
      done
      rm -f /etc/systemd/system/pdg-mitm.service
      systemctl daemon-reload
    fi
  fi

  # iOS 未启用 WLOC 的真机形态: mitm.json 在, 但 enabled=false; 没有 CA, 劫持表空
  if [[ "$plat" == ios && "$wloc" == off ]]; then
    printf '{\n  "wloc": { "enabled": false, "accuracy": 50, "locations": [] }\n}\n' > /etc/privdns-gateway/mitm.json
    chmod 600 /etc/privdns-gateway/mitm.json
  fi

  # WLOC 开着的现场: mitm.json + 劫持表 + 内核里的 MITM 路由 + schema-1 记录与产物
  if [[ "$wloc" == on ]]; then
    cat > /etc/privdns-gateway/mitm.json <<'EOF'
{
  "wloc": {
    "enabled": true,
    "accuracy": 50,
    "active": "osaka",
    "locations": [ { "name": "osaka", "lat": 34.6937, "lon": 135.5023 } ]
  }
}
EOF
    chmod 600 /etc/privdns-gateway/mitm.json
    printf 'gs-loc.apple.com\ngs-loc-cn.apple.com\n' > /etc/mosdns/rules/mitm_hijack.txt
    # 用旧版自己的渲染器把 MITM 路由渲进内核配置(不手写 YAML)
    ( cd /opt/pdg-bot && python3 - <<'PY' ) >/dev/null 2>&1 || note "渲染带 MITM 的 mihomo 配置失败"
import json, os, sys
sys.path.insert(0, "/opt/pdg-bot")
import sb2mihomo
model = json.load(open("/etc/sing-box/config.json", encoding="utf-8"))
cfg, _ = sb2mihomo.singbox_to_mihomo(model, redir_port=7893,
                                     mitm_domains=["gs-loc.apple.com", "gs-loc-cn.apple.com"])
with open("/etc/mihomo/config.yaml", "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
os.chmod("/etc/mihomo/config.yaml", 0o600)
PY
  fi

  # iOS 描述文件记录与产物: 用**旧版自己的 iosstate.generate** 造, 不手写 JSON。
  # 失败不再吞: 前像不成立就把 PREIMAGE_OK 置 0, 该场景后面的判据按"未执行"报, 不冒充有效前像。
  if [[ "$plat" == ios ]]; then
    local wl=False; [[ "$wloc" == on ]] && wl=True
    # ① 先证明"加载的确实是旧版真实模块": 打印实际模块路径, 并与 $OLDSRC 的源逐字节对账。
    #    ca_der_from_pem 属于 **iosprofile**, 不是 mitm_ca —— 上一轮调错了模块(H2b),
    #    于是凡是启用 WLOC 的前像都必然 AttributeError。这里按 v1.11.15 源码核实过的归属调用:
    #      mitm_ca.ca_cert_pem() → PEM 文本;  iosprofile.ca_der_from_pem(pem) → DER bytes(带私钥白名单校验)
    if ( cd /opt/pdg-bot && python3 - <<'PY'
import hashlib, sys
sys.path.insert(0, "/opt/pdg-bot")
import iosstate, iosprofile, mitm_ca
for m in (iosstate, iosprofile, mitm_ca):
    print("  模块 %-11s → %s  sha256=%s" % (
        m.__name__, m.__file__,
        hashlib.sha256(open(m.__file__, "rb").read()).hexdigest()[:16]))
print("  iosstate.SCHEMA = %r (旧版应为 1)" % iosstate.SCHEMA)
print("  iosprofile.TEMPLATE = %s" % iosprofile.TEMPLATE)
assert iosstate.SCHEMA == 1, "加载的不是旧版 iosstate(SCHEMA=%r)" % iosstate.SCHEMA
assert hasattr(iosprofile, "ca_der_from_pem"), "iosprofile 没有 ca_der_from_pem"
assert not hasattr(mitm_ca, "ca_der_from_pem"), "mitm_ca 不该有 ca_der_from_pem"
PY
       ) >"$E2E_TMP/modid.log" 2>&1; then
      sed 's/^/    /' "$E2E_TMP/modid.log"
      ok "前像: 加载的是**旧版真实模块**(路径与 SCHEMA=1 已记录; ca_der_from_pem 归属 iosprofile)"
    else
      bad "前像: 旧版模块身份不成立: $(tail -3 "$E2E_TMP/modid.log" | tr '\n' ' ')"; PREIMAGE_OK=0
    fi
    for _m in iosstate.py iosprofile.py mitm_ca.py; do
      cmp -s "/opt/pdg-bot/$_m" "$OLDSRC/deploy/bot/$_m" \
        || { bad "前像: /opt/pdg-bot/$_m 与 v1.11.15 源不一致"; PREIMAGE_OK=0; }
    done
    if ( cd /opt/pdg-bot && PDG_WL="$wl" python3 - <<'PY'
import os, sys
sys.path.insert(0, "/opt/pdg-bot")
import iosstate, iosprofile, mitm_ca
ca_der = b""
wl = os.environ.get("PDG_WL") == "True"
if wl:
    ca_der = iosprofile.ca_der_from_pem(mitm_ca.ca_cert_pem())
    assert ca_der and ca_der[0] == 0x30, "CA DER 不是合法结构"
iosstate.generate("dot.e2e.test", ["203.0.113.1"], ssids=["HomeWiFi"],
                  ca_der=ca_der, wloc_enabled=wl)
PY
       ) >"$E2E_TMP/gen.log" 2>&1; then
      ok "前像: iosstate.generate 成功(旧版自己的生成器)"
    else
      bad "前像: iosstate.generate 失败 —— 前像不成立: $(tail -3 "$E2E_TMP/gen.log" | tr '\n' ' ')"
      PREIMAGE_OK=0
    fi
    # 逐项自证: 记录 / 产物 / 摘要 / 身份 / CA 内容。任何一项不成立 ⇒ 前像不成立。
    if ! ( cd /opt/pdg-bot && PDG_WL="$wl" python3 - <<'PY'
import hashlib, json, os, sys
sys.path.insert(0, "/opt/pdg-bot")
wl = os.environ.get("PDG_WL") == "True"
m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
cur = m.get("current") or {}
# **字段位置按真实 schema 取**: schema 1 的输入在 current.inputs, 顶层根本没有 inputs。
# 上一轮那条"SSID 丢了"就是读了顶层 m["inputs"](迁移前后都是 None), 拿 None==None 当结论。
inp = cur.get("inputs")
if inp is None:
    sys.stderr.write("current.inputs 不存在 —— 记录形态不对\n"); sys.exit(1)
if "inputs" in m:
    sys.stderr.write("顶层出现了 inputs 字段, 与 schema 1 契约不符\n"); sys.exit(1)
art = "/var/lib/privdns-gateway/ios-profile/current.mobileconfig"
data = open(art, "rb").read()
fail = []
if m.get("schema") != 1:                 fail.append("schema=%r(应为 1)" % m.get("schema"))
if not m.get("instance_id"):             fail.append("instance_id 为空")
if not cur.get("revision"):              fail.append("revision 为空")
if cur.get("sha256") != hashlib.sha256(data).hexdigest():
    fail.append("记录里的 sha256 与盘上产物对不上")
if inp.get("wloc_enabled") is not wl:    fail.append("inputs.wloc_enabled=%r(应为 %r)" % (inp.get("wloc_enabled"), wl))
if inp.get("ssids") != ["HomeWiFi"]:     fail.append("SSID 意图没写进 current.inputs.ssids(实得 %r)" % (inp.get("ssids"),))
if b"HomeWiFi" not in data:              fail.append("产物里没有预置的 SSID")
if wl:
    # ca_der_from_pem 定义在 **iosprofile**(v1.11.15 与候选都一样), mitm_ca 里没有这个名字。
    import iosprofile, mitm_ca
    der = iosprofile.ca_der_from_pem(mitm_ca.ca_cert_pem())
    if inp.get("wloc_ca_sha256") != hashlib.sha256(der).hexdigest():
        fail.append("记录里的 CA 指纹与盘上 CA 对不上")
    if b"com.apple.security.root" not in data:
        fail.append("产物里没有根证书 payload")
    import base64, re
    if base64.b64encode(der)[:32] not in re.sub(rb"\s", b"", data):
        fail.append("产物里嵌的不是盘上那张 CA")
else:
    if b"com.apple.security.root" in data:
        fail.append("未启用 WLOC 却嵌了根证书 payload")
if fail:
    sys.stderr.write("; ".join(fail) + "\n"); sys.exit(1)
print("schema=%s revision=%s instance_id=%s" % (m.get("schema"), cur.get("revision"), m.get("instance_id")[:12]))
PY
         ) >"$E2E_TMP/gencheck.log" 2>&1; then
      bad "前像: iOS 记录/产物自证不通过 —— 前像不成立: $(tail -2 "$E2E_TMP/gencheck.log" | tr '\n' ' ')"
      PREIMAGE_OK=0
    else
      ok "前像: iOS 记录/产物逐项自证通过($(cat "$E2E_TMP/gencheck.log"))"
    fi
  fi

  systemctl daemon-reload
  systemctl enable --now mosdns mihomo >/dev/null 2>&1 || true
  systemctl enable --now pdg-probe81 >/dev/null 2>&1 || true
  # 旧版 install.sh 对 **所有** iOS 机器无条件 enable --now pdg-mitm(WLOC 开不开只决定加载哪些插件),
  # 所以"iOS 且未启用 WLOC"的真实前像同样有一个在跑的 pdg-mitm —— 这里照着真机形态造。
  [[ "$plat" == ios ]] && { systemctl enable --now pdg-mitm >/dev/null 2>&1 || true; }
  sleep 2
  return 0
}
# <<< PDG-EXTRACT-END build_preimage

assert_preimage_A(){
  echo "── 前像自证(必须先证明"确实有一台开着 WLOC 的旧机器") ──"
  [[ -f /opt/pdg-bot/mitm_server.py && -f /opt/pdg-bot/mitm_wloc.py ]] \
    && ok "前像: WLOC 执行模块在盘上" || bad "前像: WLOC 模块不在"
  [[ -f /etc/systemd/system/pdg-mitm.service ]] \
    && ok "前像: pdg-mitm unit 存在" || bad "前像: pdg-mitm unit 不存在"
  local ac en pid inv
  ac="$(systemctl is-active pdg-mitm 2>/dev/null)"; en="$(systemctl is-enabled pdg-mitm 2>/dev/null)"
  pid="$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)"
  inv="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
  [[ "$ac" == active ]] && ok "前像: pdg-mitm **真的在跑**(active, MainPID=$pid, InvocationID=$inv)" \
                        || bad "前像: pdg-mitm 没起来(active=$ac; journal: $(journalctl -u pdg-mitm -n3 --no-pager 2>/dev/null | tail -2 | tr '\n' ' '))"
  [[ "$en" == enabled ]] && ok "前像: pdg-mitm 自启=enabled" || bad "前像: pdg-mitm 自启=$en"
  ss -lnt 2>/dev/null | grep -q ':7894' && ok "前像: 7894 有真实监听" || bad "前像: 7894 没有监听"
  [[ -s /etc/privdns-gateway/ca/ca.crt && -s /etc/privdns-gateway/ca/ca.key ]] \
    && ok "前像: CA 证书与私钥都在(自造, 权限 $(stat -c %a /etc/privdns-gateway/ca/ca.key))" \
    || bad "前像: CA 材料不全"
  grep -q 'gs-loc.apple.com' /etc/mosdns/rules/mitm_hijack.txt 2>/dev/null \
    && ok "前像: 劫持表里有 WLOC 接管域名" || bad "前像: 劫持表不对"
  grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null \
    && ok "前像: 内核配置里有 MITM-OUT 路由" || bad "前像: 内核配置里没有 MITM 路由"
  grep -q '"enabled": *true' /etc/privdns-gateway/mitm.json 2>/dev/null \
    && ok "前像: mitm.json 的 wloc.enabled=true" || bad "前像: mitm.json 不对"
  # 前像判据按**真实 schema** 取位置: 输入在 current.inputs, 顶层根本没有 inputs。
  # 而且要求 SSID 意图**确实非空**才算前像成立 —— 空名单与"字段不存在"都不算。
  # 不允许出现 None == None 那种"两边都读不到所以相等"的通过方式。
  python3 - <<'PY'
import json, sys
def ok(t):  print("[OK]   " + t)
def bad(t): print("[FAIL] " + t)
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
except Exception as e:
    bad("前像: 读不到 iOS 记录: %s" % e); sys.exit(0)
if "inputs" in m:
    bad("前像: 顶层出现了 inputs 字段, 与 schema 1 契约不符"); sys.exit(0)
cur = m.get("current")
if not isinstance(cur, dict):
    bad("前像: current 不是记录对象(实得 %s) —— 前像不成立" % type(cur).__name__); sys.exit(0)
inp = cur.get("inputs")
if not isinstance(inp, dict):
    bad("前像: current.inputs 不存在 —— 前像不成立"); sys.exit(0)
fail = []
if m.get("schema") != 1:               fail.append("schema=%r(应为 1)" % m.get("schema"))
if inp.get("wloc_enabled") is not True: fail.append("current.inputs.wloc_enabled=%r(应为 True)" % inp.get("wloc_enabled"))
if not inp.get("wloc_ca_sha256"):       fail.append("current.inputs.wloc_ca_sha256 为空")
ss = inp.get("ssids")
if not (isinstance(ss, list) and len(ss) > 0):
    fail.append("SSID 意图不是非空列表(实得 %r)" % (ss,))
if fail:
    bad("前像: iOS 记录形态不对 —— " + "; ".join(fail))
else:
    ok("前像: iOS 记录是 schema 1, current.inputs 带 WLOC 字段与 CA 指纹, 且 SSID 意图非空(%r)" % (ss,))
PY
  local art=/var/lib/privdns-gateway/ios-profile/current.mobileconfig
  if [[ -s "$art" ]]; then
    grep -q 'com.apple.security.root' "$art" \
      && ok "前像: 描述文件产物里**确实嵌着**根证书 payload" \
      || bad "前像: 产物里没有根证书 payload(前像不真实)"
  else
    bad "前像: 没有描述文件产物"
  fi
}



# ── 服务动作的**执行前**允许清单 ────────────────────────────────────────────
# 清单在这里(源码里)就定死, 不是跑完看到哪个变了再补进来; 也不是"X 源码里可能出现的
# 服务动作一律准许" —— 下面每一条都写明来自 run_all_migrations 的哪一支、为什么会动。
# 依据: 冻结候选 X 的 run_all_migrations 调用链 + 本场景的输入条件
# (一台按 v1.11.15 形态播种、从未跑过新迁移的老机器)。
# >>> PDG-EXTRACT-BEGIN svc_class
svc_class(){   # $1=unit → 打印 "<类别>|<原因>"
  case "$1" in
    mosdns)
      printf '正常首次迁移|migrate_lowmem 归一 cache size / migrate_mosdns_{concurrent,unlock,ratelimit,hijack_shape,explicit_proxy} / migrate_dotwitness 受管路由 / migrate_adblock 受管块 —— 这些都要让解析器带新配置起来';;
    mihomo)
      printf '正常首次迁移|migrate_mosdns_mitm 与 migrate_wloc_retire 撤掉 MITM 路由后重渲内核; migrate_ios_gms_cleanup 同步内核配置';;
    pdg-bot|pdg-probe81)
      printf '正常首次迁移|migrate_deploy_botfiles 更新运行模块后重启(probe81 另有 migrate_probe81_public 补公共件 unit)';;
    pdg-dotwitness)
      printf '正常首次迁移|migrate_dotwitness 首次就位并启用';;
    pdg-health.timer|pdg-health.service)
      printf '正常首次迁移|migrate_health_timer 重新排程';;
    pdg-mitm)
      printf 'WLOC 退役专属|migrate_wloc_retire: 停止 + 禁用 + 删除 unit';;
    *)
      printf '意外|不在执行前确定的允许清单里';;
  esac
}
# <<< PDG-EXTRACT-END svc_class
# 被观察的服务集合: 允许清单里的 + 几个**本轮从不安装、因此绝不该变**的见证者。
# >>> PDG-EXTRACT-BEGIN SVC_WATCH
SVC_WATCH=(mosdns mihomo pdg-bot pdg-probe81 pdg-dotwitness pdg-health.timer pdg-mitm
           sing-box pdg-rescue.socket ssh cron)
# <<< PDG-EXTRACT-END SVC_WATCH
# >>> PDG-EXTRACT-BEGIN svc_snapshot
svc_snapshot(){   # $1=落点文件
  local u
  : > "$1"
  for u in "${SVC_WATCH[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" \
      "$(systemctl show -p ActiveState  --value "$u" 2>/dev/null)" \
      "$(systemctl show -p SubState     --value "$u" 2>/dev/null)" \
      "$(systemctl show -p UnitFileState --value "$u" 2>/dev/null)" \
      "$(systemctl show -p MainPID      --value "$u" 2>/dev/null)" \
      "$(systemctl show -p InvocationID --value "$u" 2>/dev/null)" \
      "$(systemctl show -p NRestarts    --value "$u" 2>/dev/null)" >> "$1"
  done
}
# <<< PDG-EXTRACT-END svc_snapshot
# >>> PDG-EXTRACT-BEGIN svc_verdict
svc_verdict(){   # $1=before  $2=after  $3=场景名
  # 用 awk 按**字段**取行, 不用 grep -P: PCRE 不是哪儿都有, 而它一旦不可用, 这里会静默
  # 变成"两边都取不到 ⇒ 没有变化", 那正是最难发现的一种假绿。
  local u b a cls reason n_norm=0 n_wloc=0 n_un=0 unexpected="" TAB
  TAB="$(printf '\t')"
  echo "── 服务动作对账($3): 逐项前后证据 ──"
  while IFS="$TAB" read -r u _ _ _ _ _ _; do
    b="$(awk -F"$TAB" -v u="$u" '$1==u' "$1" | head -1)"
    a="$(awk -F"$TAB" -v u="$u" '$1==u' "$2" | head -1)"
    [[ -n "$b" && -n "$a" ]] || { bad "$3: 取不到 $u 的前后快照行(对账失效)"; continue; }
    [[ "$b" == "$a" ]] && continue
    cls="$(svc_class "$u")"; reason="${cls#*|}"; cls="${cls%%|*}"
    printf '    %-20s %s\n      前: %s\n      后: %s\n      原因: %s\n' \
      "$u" "[$cls]" "${b#*"$TAB"}" "${a#*"$TAB"}" "$reason"
    case "$cls" in
      正常首次迁移) n_norm=$((n_norm+1));;
      "WLOC 退役专属") n_wloc=$((n_wloc+1));;
      *) n_un=$((n_un+1)); unexpected="$unexpected $u";;
    esac
  done < "$1"
  printf '    小计: 正常首次迁移 %d / WLOC 退役专属 %d / **意外 %d**\n' "$n_norm" "$n_wloc" "$n_un"
  _evn "07-service-actions-$3.txt" "正常=$n_norm WLOC=$n_wloc 意外=$n_un;$unexpected"
  cp "$1" "$EVID/svc-$3-before.tsv" 2>/dev/null; cp "$2" "$EVID/svc-$3-after.tsv" 2>/dev/null
  chmod 600 "$EVID/svc-$3-before.tsv" "$EVID/svc-$3-after.tsv" 2>/dev/null || true
  [[ "$n_un" == 0 ]] && ok "$3: 服务动作全部落在执行前确定的允许清单内(意外 0)" \
                     || bad "$3: 出现清单外的服务动作:$unexpected"
  [[ "$n_wloc" -ge 1 ]] && ok "$3: WLOC 退役专属动作确实发生(pdg-mitm)" \
                        || note "$3: 本场景没有 WLOC 退役专属动作(与前像条件是否一致, 见上文)"
}
# <<< PDG-EXTRACT-END svc_verdict

# ── 直接迁移的部署源身份(H5)─────────────────────────────────────────────────
# 上一轮栽在这: 只把候选模块 install 到 /opt/pdg-bot, 却没动 $REPO_DIR。候选 pdg.sh 的
# __migrate 第一步就是 migrate_deploy_botfiles —— 它按 **$REPO_DIR** 重装 /opt/pdg-bot,
# 而那个仓库还停在 v1.11.15, 于是刚装上去的候选模块被换回旧版, 随后
# _retire_ios_schema 调 iosstate.migrate_schema() 得到 AttributeError。
# 所以每次进入"直接迁移"之前, 都要把 REPO_DIR 真的切到 X, 并逐项核对身份。
switch_repo_to_candidate(){
  e2e_git "$REPO" checkout -q "$CAND_SHA" 2>/dev/null \
    || { bad "把 $REPO 切到候选 X 失败"; return 1; }
  # 353: HEAD 的读取核原始退出码 —— 先打印出正确 SHA 再以非零退出, 同样不采信
  local head hrc; head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"; hrc=$?
  { (( hrc == 0 )) && [[ "$head" == "$CAND_SHA" ]]; } && ok "部署源身份: $REPO 的 HEAD == 候选 X" \
                              || { bad "部署源 HEAD=${head:-读不到}(rc=$hrc, 应为 X)"; return 1; }
  # 关键源文件逐字节等于 X 的那一份(拿独立展开的 $CANDSRC 当权威, 不自证)
  local miss=0 f
  for f in deploy/bot/pdg.sh deploy/bot/iosstate.py deploy/bot/pdg-bot.py lib/modules.sh; do
    cmp -s "$REPO/$f" "$CANDSRC/$f" || { miss=$((miss+1)); echo "       不符: $f"; }
  done
  [[ "$miss" == 0 ]] && ok "部署源身份: 关键源文件($REPO)逐字节等于候选 X" \
                     || { bad "部署源里有 $miss 个关键文件不是 X 的"; return 1; }
  # 按候选自己的清单装 —— 与 __migrate 里的 migrate_deploy_botfiles 同一份真源, 不会再被换回去
  install -m755 "$REPO/deploy/bot/pdg.sh" "$P5_CLI" || { bad "装 $P5_CLI 失败"; return 1; }
  ( # shellcheck source=/dev/null
    source "$REPO/lib/modules.sh" && pdg_install_runtime_modules "$REPO" "$P5_MODDIR" "$1" ) \
    || { bad "按候选清单装模块失败"; return 1; }
  # 353: 两边摘要都要有效取得且相等; 不符或取不到都返回非 0(以前只记一条 FAIL, 照样放行)
  p5_same_file "$P5_CLI" "$CANDSRC/deploy/bot/pdg.sh" \
    && ok "部署源身份: $P5_CLI 就是候选 X 的那一份" || { bad "装上去的 pdg 不是 X 的或摘要取不到: $P5_WHY"; return 1; }
  # ── 按**平台契约**核对装机身份 ────────────────────────────────────────────
  # 上一轮这里写死了"iosstate 必须有 migrate_schema" —— 而 iosstate.py 属于 PDG_IOS_MODULES,
  # **Android 本来就不装它**(平台契约, 不是装机失败)。判据换成: 该平台**实际应装**的每个
  # 文件都在, 且逐字节等于候选 X 的那一份; 再加三条反面契约。
  # 353: 清单先整份生成并核退出码与结构(先输出后失败、为空都不采信), 再逐项比。
  local plat="$1" nmod=0 nbad=0 src name _mode lst
  lst="${E2E_TMP:?}/p5-modlist-$plat.txt"
  p5_modlist "$CANDSRC" "$plat" "$lst" || { bad "部署源身份: $P5_WHY"; return 1; }
  while read -r src name _mode; do
    [[ -n "$src" ]] || continue
    nmod=$((nmod+1))
    if [[ ! -e "$P5_MODDIR/$name" ]]; then
      nbad=$((nbad+1)); echo "       缺 $name"; continue
    fi
    cmp -s "$CANDSRC/$src" "$P5_MODDIR/$name" || { nbad=$((nbad+1)); echo "       指纹不符 $name"; }
  done < "$lst"
  { [[ "$nmod" -gt 0 && "$nbad" == 0 ]]; } \
    && ok "部署源身份: $plat 平台应装的 $nmod 个文件全部就位且逐字节等于候选 X" \
    || { bad "部署源身份: $plat 平台清单 $nmod 项里有 $nbad 项缺失或指纹不符"; return 1; }
  if [[ "$plat" == android ]]; then
    # 反面契约 ①: iOS 专属那几件不该由**候选的 Android 安装**带上来。
    # 但"盘上有"不等于"候选装的" —— 本轮的前像里它们是**预先构造的历史残留**, 已经逐项
    # 记进了残留清单(来源 + sha256 + mode + uid:gid)。所以判据是**对账**, 不是看名字:
    #   · 在清单里且指纹对得上 → 已记账的历史残留, 不算异常(但要列出来, 不笼统豁免);
    #   · 不在清单里, 或指纹与清单里记的不一样(包括盘上指纹取不到)→ 就是**没记账的额外文件**, 当场判红并阻断调用。
    # 这样既不因为平台标记是 android 就一律拒绝, 也不给任何文件开白名单。
    local ios_unaccounted="" ios_accounted="" fsum msum
    for f in iosprofile.py iosstate.py mitm_ca.py pdg-dot.mobileconfig.tmpl; do
      [[ -e "$P5_MODDIR/$f" ]] || continue
      if p5_digest "$P5_MODDIR/$f"; then fsum="$P5_VAL"; else fsum=""; fi
      msum="$(awk -F"$(printf '\t')" -v k="$P5_MODDIR/$f" '$1==k{print $3; exit}' "$RESIDUE_MANIFEST" 2>/dev/null)"
      if [[ -n "$fsum" && -n "$msum" && "$msum" == "$fsum" ]]; then ios_accounted="$ios_accounted $f"
      else ios_unaccounted="$ios_unaccounted $f(盘上 ${fsum:0:12} / 清单 ${msum:-无记录})"; fi
    done
    [[ -n "$ios_accounted" ]] && note "部署源身份: 这几件 iOS 专属件是**已记账的历史残留**, 指纹与清单一致:$ios_accounted"
    [[ -z "$ios_unaccounted" ]] \
      && ok "部署源身份: Android 上没有**未记账**的 iOS 专属件(候选安装没有多带东西)" \
      || { bad "部署源身份: Android 上有未记账的 iOS 专属件:$ios_unaccounted"; return 1; }
  else
    # 反面契约 ②: iOS 上装的 iosstate 必须是候选形态(行为身份, 不只是文件名)
    ( cd "$P5_MODDIR" && python3 -c 'import iosstate,sys; sys.exit(0 if hasattr(iosstate,"migrate_schema") else 1)' ) 2>/dev/null \
      && ok "部署源身份: iOS 上装的 iosstate 具备 migrate_schema(候选形态)" \
      || { bad "部署源身份: iOS 上的 iosstate 没有 migrate_schema —— 部署源仍是旧版"; return 1; }
  fi
  # 反面契约 ③: 两平台均应退役的三件, 迁移之后一件都不许在(此刻迁移还没跑, 只记录现状)
  local retired="" r
  for r in "$P5_MODDIR/mitm_server.py" "$P5_MODDIR/mitm_wloc.py" /etc/systemd/system/pdg-mitm.service; do
    [[ -e "$r" ]] && retired="$retired $r"
  done
  [[ -z "$retired" ]] && ok "部署源身份: 两平台均应退役的三件在候选装机后已不存在" \
                      || note "部署源身份: 退役件此刻仍在(迁移尚未执行, 属预期):$retired"
  return 0
}


# ═════════════════════════════════════════════════════════════════════════════
# 本轮按审查意见补的几件夹具
# ═════════════════════════════════════════════════════════════════════════════

# ── 前像必须先达到**合法稳定状态**再采样 ────────────────────────────────────
# activating / deactivating 是过渡态: 在那一刻采前像, 产品会按"过渡态不猜"如实登记为
# 未恢复, 而测试自己晚一拍采到的却是 active —— 两边对不上, 判据就失去意义。
# >>> PDG-EXTRACT-BEGIN wait_stable
wait_stable(){   # $1=unit  [$2=最多等几秒, 默认 25]
  local u="$1" n="${2:-25}" st i
  for ((i=0; i<n; i++)); do
    st="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
    case "$st" in activating|deactivating|reloading|"") sleep 1;; *) printf '%s\n' "$st"; return 0;; esac
  done
  printf '%s\n' "${st:-<读不到>}"; return 1
}
# <<< PDG-EXTRACT-END wait_stable

# ── 启动频率预算: 只**读**产品自己的设置, 不改它 ────────────────────────────
# 为什么要管这个: 本支在正式操作之前会为了标定 DNS 仪器连着重启 mosdns 四次
# (固定实验条件 / 配置甲 / 配置乙 / 还原甲)。产品自己的 mosdns unit 写的是
# Restart=on-failure + RestartSec=3, **没有**设 StartLimit*, 所以吃系统默认 10s/5。
# 准备阶段把额度用掉, 随后 `pdg platform` 自己的 `systemctl restart mosdns` 就可能撞上
# "Start request repeated too quickly" —— 那是**测试准备污染了被测过程**, 不是产品缺陷。
# 处理办法只有一个方向: 在准备与被测操作之间**等**。
#   · 不改产品 unit(独立定点那支的 300s/8 是它自己的测试条件, 不往这里套);
#   · 不用 reset-failed, 不把窗口设成 0/infinity, 不延长产品操作的任何期限;
#   · 等待长度由**实际生效的有限窗口**推出来, 并且有上限 —— 不做无界等待;
#   · 静置是**测试前置**: 期间只要出现自动重启、状态不稳, 就判前置不成立, 不重试到绿。
STARTLIMIT_CAP=60          # 静置上限(秒): 生效窗口超过它就判前置不成立, 不无界等
# ── 事件边界: 用**自有标记自身的 journal 游标**当界桩 ────────────────────────
# 上一次(run 34960827400)栽在这: 边界取 `date +秒`, 而 `journalctl --since` 是秒级且**含边界**,
# 标定末尾那几次重启正好落在同一秒里, 被重复算进了静置窗口。
# 现在: 秒级时刻**只留给人读**, 不再裁决任何事件的归属。归属一律由界桩决定 ——
#   · 往 journal 写一条自有标记, 取**它自己的 __CURSOR** 当界桩(本机实测: 同一秒内
#     写在界桩之前的记录不会被算进 --after-cursor, 之后的一条不漏);
#   · 游标是不透明串: 只拿去 --after-cursor, 绝不比较大小来判先后;
#   · 界桩必须**自证落地**: 写完 sync 后要能按标记内容把它自己的游标读回来, 读不到 = 观测无效;
#   · 相邻阶段**共享同一个界桩** ⇒ 每条记录只归一个区间。区间 (A,B] 的条数 =
#     after(A) − after(B), 两次查询都在 B 落地之后做, 其后新到的事件对两边等量影响。
PH_T0=""; T_CAL0=""; T_CAL1=""; T_PROD0=""; T_PROD1=""      # 仅供阅读的秒级时刻
C_PREP0=""; C_CAL0=""; C_CAL1=""; C_PROD0=""; C_PROD1=""    # 裁决归属的界桩游标
J_ERR=""
JBOUND_TAG="pdg-e2e-jbound"
# 这几个函数多数在 $( ) 里被调用 —— 子壳里给变量赋的值回不到调用方, 上一版的"原因"
# 因此总是空的。改成写文件: 写在子壳里, 调用方读得到。stdout(计数) / stderr(原始报错) /
# 退出码三者分开留证, 不混成一句。
# >>> PDG-EXTRACT-BEGIN _j_why_file
_j_why_file(){ printf '%s\n' "${E2E_TMP:-${TMPDIR:-/tmp}}/j-why.txt"; }
# <<< PDG-EXTRACT-END _j_why_file
# >>> PDG-EXTRACT-BEGIN _j_err_file
_j_err_file(){ printf '%s\n' "${E2E_TMP:-${TMPDIR:-/tmp}}/j-err.txt"; }
# <<< PDG-EXTRACT-END _j_err_file
# >>> PDG-EXTRACT-BEGIN _j_fail
_j_fail(){ printf '%s\n' "$1" > "$(_j_why_file)" 2>/dev/null; }   # 原因只走文件, 子壳里也回得来
# <<< PDG-EXTRACT-END _j_fail
# >>> PDG-EXTRACT-BEGIN _j_why
_j_why(){  cat "$(_j_why_file)" 2>/dev/null; }
# <<< PDG-EXTRACT-END _j_why
# >>> PDG-EXTRACT-BEGIN _j_err
_j_err(){  cat "$(_j_err_file)" 2>/dev/null; }
# <<< PDG-EXTRACT-END _j_err
_now_j(){ date +'%Y-%m-%d %H:%M:%S'; }        # **只**用于人读的时刻, 不做事件归属
# >>> PDG-EXTRACT-BEGIN _j_sync
_j_sync(){ journalctl --sync >/dev/null 2>&1; }   # 尽力刷盘; 真正的可见性由界桩自证
# <<< PDG-EXTRACT-END _j_sync
# >>> PDG-EXTRACT-BEGIN _j_mark
_j_mark(){   # $1=界桩名 → 打印该界桩自己的游标; 取不到回空(观测无效, 由调用方判前置)
  local id="$1-$$-${RANDOM}" i cur
  if command -v logger >/dev/null 2>&1; then
    logger -t "$JBOUND_TAG" "BOUNDARY $id" 2>/dev/null || { _j_fail "写不进 journal 界桩(logger 失败)"; return 1; }
  elif command -v systemd-cat >/dev/null 2>&1; then
    printf 'BOUNDARY %s\n' "$id" | systemd-cat -t "$JBOUND_TAG" 2>/dev/null \
      || { _j_fail "写不进 journal 界桩(systemd-cat 失败)"; return 1; }
  else
    _j_fail "这台机器上没有 logger / systemd-cat, 建不出界桩"; return 1
  fi
  # journald 是异步的: sync 之后按标记内容**读回它自己的游标**, 读不到就重试, 超时判无效。
  for ((i=0; i<20; i++)); do
    _j_sync
    cur="$(journalctl -t "$JBOUND_TAG" --no-pager -o json --output-fields=MESSAGE 2>/dev/null \
           | python3 -c '
import sys, json
want = "BOUNDARY " + sys.argv[1]
out = ""
for line in sys.stdin:
    try: d = json.loads(line)
    except Exception: continue
    if d.get("MESSAGE") == want and d.get("__CURSOR"): out = d["__CURSOR"]
print(out)' "$id" 2>/dev/null)"
    [[ -n "$cur" ]] && { printf '%s\n' "$cur"; return 0; }
    sleep 0.3
  done
  _j_fail "界桩写进去了却读不回来(journal 可见性未确认, 等了 6s)"; return 1
}
# <<< PDG-EXTRACT-END _j_mark
# >>> PDG-EXTRACT-BEGIN _j_starts_after
_j_starts_after(){   # $1=unit $2=界桩游标 → 打印该界桩之后的启动条数; 观测无效回空并置 J_WHY
  local u="$1" cur="$2" errf raw rc n grc
  J_ERR=""; : > "$(_j_why_file)" 2>/dev/null
  [[ -n "$cur" ]] || { _j_fail "没有界桩游标(边界缺失)"; echo ""; return 1; }
  errf="$(_j_err_file)"
  raw="$(journalctl -u "$u" --after-cursor "$cur" --no-pager -o short-iso 2>"$errf")"; rc=$?
  J_ERR="$(head -3 "$errf" 2>/dev/null | tr '\n' ' ')"
  # 查询失败与"查询成功但零匹配"是两件事: 前者观测无效, 后者是合法的 0。
  if [[ "$rc" != 0 ]]; then
    _j_fail "journalctl 退出码 $rc: ${J_ERR:-（无 stderr）}"; echo ""; return 1
  fi
  n="$(grep -cE "Started ${u}(\.service)?[ .]" <<<"$raw")"; grc=$?
  if [[ "$grc" -gt 1 ]]; then _j_fail "解析失败(grep 退出码 $grc; stderr: ${J_ERR:-无})"; echo ""; return 1; fi
  [[ "$n" =~ ^[0-9]+$ ]] || { _j_fail "解析结果不是数字: [$n]"; echo ""; return 1; }
  printf '%s\n' "$n"; return 0
}
# <<< PDG-EXTRACT-END _j_starts_after
# >>> PDG-EXTRACT-BEGIN _j_tag_after
_j_tag_after(){   # $1=界桩游标 → 该游标之后**界桩自己**那条 tag 的记录数(用来验边界有效与先后)
  local cur="$1" errf raw rc n grc
  [[ -n "$cur" ]] || { _j_fail "没有界桩游标(边界缺失)"; echo ""; return 1; }
  errf="$(_j_err_file)"
  raw="$(journalctl -t "$JBOUND_TAG" --after-cursor "$cur" --no-pager -o cat 2>"$errf")"; rc=$?
  [[ "$rc" == 0 ]] || { _j_fail "界桩查询失败(journalctl 退出码 $rc: $(head -1 "$errf" 2>/dev/null))"; echo ""; return 1; }
  n="$(grep -c '^BOUNDARY ' <<<"$raw")"; grc=$?
  [[ "$grc" -gt 1 ]] && { _j_fail "界桩解析失败(grep 退出码 $grc)"; echo ""; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] || { _j_fail "界桩计数不是数字: [$n]"; echo ""; return 1; }
  printf '%s\n' "$n"; return 0
}
# <<< PDG-EXTRACT-END _j_tag_after
# >>> PDG-EXTRACT-BEGIN _j_interval
_j_interval(){   # $1=unit $2=起界桩 $3=止界桩 → (起,止] 的启动条数; 观测无效回空
  local a b ta tb
  a="$(_j_starts_after "$1" "$2")" || { echo ""; return 1; }
  b="$(_j_starts_after "$1" "$3")" || { echo ""; return 1; }
  if [[ "$a" -lt "$b" ]]; then _j_fail "区间条数为负(起=$a 止=$b) —— 界桩顺序不对"; echo ""; return 1; fi
  # 边界有效性与先后, 不靠比较游标字符串: 界桩自己也在 journal 里, 止界桩那条记录必然
  # 落在 (起,止] 内 ⇒ 起界桩之后的界桩条数至少要比止界桩之后的多一条。
  ta="$(_j_tag_after "$2")" || { echo ""; return 1; }
  tb="$(_j_tag_after "$3")" || { echo ""; return 1; }
  if (( ta - tb < 1 )); then
    _j_fail "界桩自证不成立(起界桩之后的界桩数 $ta, 止界桩之后 $tb) —— 边界无效或顺序不对"
    echo ""; return 1
  fi
  printf '%s\n' "$(( a - b ))"; return 0
}
# <<< PDG-EXTRACT-END _j_interval
_dur2s_real(){   # systemd 的人类可读时长 → 秒; infinity/0 原样回显
  local in="$1" tot=0 t n un seen=0
  [[ -n "$in" ]] || { echo ""; return 1; }
  case "$in" in infinity|0) echo "$in"; return 0;; esac
  for t in $in; do
    n="${t%%[a-z]*}"; un="${t#"$n"}"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo ""; return 1; }
    case "$un" in
      h)    tot=$((tot+n*3600));;
      min)  tot=$((tot+n*60));;
      s|"") tot=$((tot+n));;
      ms)   tot=$((tot+n/1000));;
      us)   tot=$((tot+n/1000000));;
      *)    echo ""; return 1;;
    esac
    seen=1
  done
  (( seen )) || { echo ""; return 1; }
  echo "$tot"
}
startlimit_inventory(){   # 清点: 产品这份 unit 实际生效的限制 + 计划内的准备重启次数
  local u=mosdns int burst ints
  int="$(systemctl show -p StartLimitIntervalUSec --value "$u" 2>/dev/null)"
  burst="$(systemctl show -p StartLimitBurst --value "$u" 2>/dev/null)"
  ints="$(_dur2s_real "$int")"
  SL_INT="$int"; SL_INT_S="$ints"
  note "启动预算清点($u, **产品自己的 unit, 只读不改**):"
  note "  实际生效: StartLimitIntervalUSec=$int(=${ints:-读不懂}s)  StartLimitBurst=$burst  Restart=$(systemctl show -p Restart --value "$u" 2>/dev/null)"
  note "  本支准备阶段计划内的主动重启: 标定 4 次(固定实验条件/配置甲/配置乙/还原甲)"
  note "  被测的产品动作自己还要重启 mosdns —— 所以两段之间必须静置, 让额度窗口过去"
  _evn "06-$DIR-phases.txt" "启动预算: $u 生效 Interval=$int(=${ints:-?}s) Burst=$burst"
}
quiesce_startlimit(){   # $1=阶段说明 —— 依生效窗口做**有界**静置, 并证明静置期间什么都没起
  local u=mosdns wait_s nr0 nr1 st during q0 q1 t0
  [[ -n "${SL_INT_S:-}" ]] || { bad "静置($1): 还没清点生效窗口"; PREIMAGE_OK=0; return 1; }
  case "$SL_INT_S" in
    ""|infinity|0)
      bad "静置($1): $u 的启动频率窗口实际生效值是 '$SL_INT' —— 读不懂/等于没有限制, 前置不成立"
      PREIMAGE_OK=0; return 1;;
  esac
  [[ "$SL_INT_S" -le "$STARTLIMIT_CAP" ]] \
    || { bad "静置($1): 生效窗口 ${SL_INT_S}s 超过上限 ${STARTLIMIT_CAP}s —— 不做无界等待, 前置不成立"; PREIMAGE_OK=0; return 1; }
  wait_s=$(( SL_INT_S + 3 ))     # 窗口 + 3s 余量: 让窗口内的计数确实滑出去(不是保险时间)
  # 起界桩: 取不到就是**观测无效**, 不生成"0 次启动"的结论。
  q0="$(_j_mark "quiesce-$1-start")" \
    || { bad "静置($1): 观测无效 —— 起界桩没建成: $(_j_why)"; PREIMAGE_OK=0; return 1; }
  nr0="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
  [[ "$nr0" =~ ^[0-9]+$ ]] \
    || { bad "静置($1): 观测无效 —— NRestarts 读不到合法数值(实得 '''${nr0:-空}''')"; PREIMAGE_OK=0; return 1; }
  t0="$(_now_j)"                 # 仅供阅读
  sleep "$wait_s"
  nr1="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
  [[ "$nr1" =~ ^[0-9]+$ ]] \
    || { bad "静置($1): 观测无效 —— 静置后 NRestarts 读不到合法数值(实得 '''${nr1:-空}''')"; PREIMAGE_OK=0; return 1; }
  q1="$(_j_mark "quiesce-$1-end")" \
    || { bad "静置($1): 观测无效 —— 止界桩没建成: $(_j_why)"; PREIMAGE_OK=0; return 1; }
  during="$(_j_interval "$u" "$q0" "$q1")" \
    || { bad "静置($1): 观测无效 —— $(_j_why)(stderr: $(_j_err | head -1))"; PREIMAGE_OK=0; return 1; }
  st="$(wait_stable "$u")"
  _evn "06-$DIR-phases.txt" "静置($1): $t0 起 ${wait_s}s(窗口 ${SL_INT_S}s+3s; 归属由界桩裁决, 时刻仅供阅读); 区间内启动 $during 次; NRestarts $nr0→$nr1; 稳定后 $st"
  { [[ "$during" == 0 ]] && [[ "$nr1" == "$nr0" ]] && [[ "$st" == active ]]; } \
    && ok "静置($1): 按实际生效窗口 $SL_INT 静置 ${wait_s}s —— 界桩区间内 0 次启动, 没有自动重启(NRestarts=$nr0), $u 稳定在 $st" \
    || { bad "静置($1): 区间内启动 $during 次 / NRestarts $nr0→$nr1 / 稳定后 $st —— 前置不成立(不重试到绿)"; PREIMAGE_OK=0; return 1; }
  return 0
}
phase_report(){   # 把"准备动作"与"产品动作"的边界连同实际启动记录一起留证
  local u=mosdns a b c d
  a="$(_j_interval "$u" "$C_PREP0" "$C_CAL0")";  a="${a:-观测无效}"
  b="$(_j_interval "$u" "$C_CAL0"  "$C_CAL1")";  b="${b:-观测无效}"
  c="$(_j_interval "$u" "$C_CAL1"  "$C_PROD0")"; c="${c:-观测无效}"
  d="$(_j_interval "$u" "$C_PROD0" "$C_PROD1")"; d="${d:-观测无效}"
  echo "── 阶段边界与 $u 的实际启动记录(界桩裁决归属; 时刻仅供阅读, 原始日志一行不删)──"
  printf '    %-28s %s\n' "准备阶段(造前像/装候选)"   "$PH_T0 → $T_CAL0    启动 $a 次"
  printf '    %-28s %s\n' "标定阶段(仪器自己的重启)"   "$T_CAL0 → $T_CAL1   启动 $b 次"
  printf '    %-28s %s\n' "静置#2 + 正式前像采集"      "$T_CAL1 → $T_PROD0  启动 $c 次"
  printf '    %-28s %s\n' "**产品动作** pdg platform"  "$T_PROD0 → $T_PROD1 启动 $d 次"
  {
    echo "# 阶段边界与 $u 启动次数(归属由 journal 界桩裁决; 下面的时刻只是给人读的)"
    echo "准备阶段    $PH_T0 → $T_CAL0    $a"
    echo "标定阶段    $T_CAL0 → $T_CAL1   $b"
    echo "静置+采前像 $T_CAL1 → $T_PROD0  $c"
    echo "产品动作    $T_PROD0 → $T_PROD1 $d   ← 窗口只围住 pdg platform 这一次调用"
    echo "界桩(不透明, 只用于 --after-cursor, 不比大小):"
    echo "  C_PREP0=$C_PREP0"; echo "  C_CAL0 =$C_CAL0"; echo "  C_CAL1 =$C_CAL1"
    echo "  C_PROD0=$C_PROD0"; echo "  C_PROD1=$C_PROD1"
    echo "相邻阶段共享同一个界桩 ⇒ 每条记录只归一个区间, 合计不重不漏。"
    echo "说明: 准备阶段的重启计在准备阶段, **不**计成产品动作; 前像采集也不算产品动作。"
    echo "      产品 unit 的 StartLimit 一个字没改, 也没有 reset-failed。"
  } | _ev "06-$DIR-phases.txt"
}

# ── 持续稳定 vs 瞬时 active: 在**有界观测窗口**里判, 不靠某一次 systemctl 返回 ────
# 上一次(run 34966909411 的 ⑤b)栽在这: pdg-mitm 其实在崩溃循环(每 3s 被 Restart=on-failure
# 拉起来一次), 而前像判据只取了一瞬的 is-active=active, 就报了"处在稳定运行态"。
# 这里把两件事分开:
#   · wait_stable  : 等它**进入**非过渡态(activating/deactivating/reloading 不算数);
#   · svc_stable_window: 进入之后在窗口内**持续**符合目标, 而且没有悄悄换过实例。
# 判据(窗口内逐次采样 + journal 界桩裁决的启动事件):
#   预期运行: ActiveState 一直是 active; MainPID 有效且不变; InvocationID 有效且不变;
#             NRestarts 两端都能解析且不增长; 窗口内没有新的 "Started <unit>" 事件。
#   预期停止: ActiveState 一直不是 active/activating; 没有 MainPID; 窗口内没有启动事件。
#   任何一次状态查询失败 / 字段缺不出来 / journal 观测无效 ⇒ 记**观测无效**(既不算稳定,
#   也不算零事件), 由调用方判前置不成立 —— 不靠"多等一会儿碰巧 active"蒙混过去。
SVC_STABLE_WHY=""
# ── 先认身份与类型, 再决定该读哪些字段 ──────────────────────────────────────
# 上一次(run 34972537688)栽在这: 判据无条件要求 NRestarts 能解析成数字, 而
# **NRestarts 是 Service 的属性** —— .timer / .socket 根本没有这一项, 于是
# pdg-health.timer 被判成"观测无效", 两个方向都停在前置门。
# 本机真 systemd 实测(只读, 没动任何生产服务):
#   .service(simple, active) : Type=simple  MainPID=693 InvocationID=有 NRestarts=0
#   .service(oneshot, active): Type=oneshot MainPID=**0**(RemainAfterExit 的正常形态) NRestarts=0
#   .timer(active)           : Type=空 MainPID=**空** InvocationID=有 NRestarts=**空** SubState=elapsed/waiting
#   .socket(active)          : 同上(Type/MainPID/NRestarts 皆空)
#   **不存在**的 unit        : LoadState=not-found, 而 MainPID=**0**、NRestarts=**0**(不是空!)
# 所以三件事必须分开: 数字 0 / 空字符串 / 类型上就不适用。
#   · 不适用要有**类型依据**(按 Id 的后缀定), 不能因为"读出来是空"就自动算不适用;
#   · 适用却缺失、查询失败、格式非法 ⇒ 仍记观测无效;
#   · service 要不要求非零 MainPID, 取决于它的 Type(oneshot 正常就是 0)。
UNIT_ID=""; UNIT_LOAD=""; UNIT_KIND=""; UNIT_TYPE=""; UNIT_WHY=""
# >>> PDG-EXTRACT-BEGIN unit_identify
unit_identify(){   # $1=unit → 0 可观测 / 1 加载状态不可用 / 2 身份读不出来
  UNIT_ID=""; UNIT_LOAD=""; UNIT_KIND=""; UNIT_TYPE=""; UNIT_WHY=""
  local id load
  id="$(systemctl show -p Id --value "$1" 2>/dev/null)"
  load="$(systemctl show -p LoadState --value "$1" 2>/dev/null)"
  { [[ -n "$id" ]] && [[ -n "$load" ]]; } || { UNIT_WHY="读不出 Id/LoadState(Id=[$id] LoadState=[$load])"; return 2; }
  UNIT_ID="$id"; UNIT_LOAD="$load"
  case "$id" in
    *.timer)   UNIT_KIND=timer;;
    *.socket)  UNIT_KIND=socket;;
    *.service) UNIT_KIND=service;;
    *)         UNIT_WHY="不认识的 unit 类型: $id"; return 2;;
  esac
  [[ "$load" == loaded ]] || { UNIT_WHY="$id 的 LoadState=$load(不是 loaded) —— 这是具名结果, 不是'不适用'"; return 1; }
  if [[ "$UNIT_KIND" == service ]]; then
    UNIT_TYPE="$(systemctl show -p Type --value "$1" 2>/dev/null)"
    [[ -n "$UNIT_TYPE" ]] || { UNIT_WHY="$id 是 service 却读不到 Type"; return 2; }
  fi
  return 0
}
# <<< PDG-EXTRACT-END unit_identify
# >>> PDG-EXTRACT-BEGIN _unit_wants_mainpid
_unit_wants_mainpid(){   # service 的 Type 决定"活着时该不该有非零 MainPID"
  case "$1" in simple|exec|notify|notify-reload|forking|idle) return 0;; *) return 1;; esac
}
# <<< PDG-EXTRACT-END _unit_wants_mainpid
# >>> PDG-EXTRACT-BEGIN svc_stable_window
svc_stable_window(){   # $1=unit $2=running|stopped [$3=窗口秒数, 默认 8] → 0 成立 / 1 不成立 / 2 观测无效
  local u="$1" want="$2" secs="${3:-8}" i st sub pid inv nr0 nr1 pid0 inv0 c0 c1 evs
  local has_nr=0 has_pid=0 wants_pid=0
  SVC_STABLE_WHY=""
  unit_identify "$u"; local idrc=$?
  case "$idrc" in
    2) SVC_STABLE_WHY="观测无效: $UNIT_WHY"; return 2;;
    1) SVC_STABLE_WHY="$UNIT_WHY"; return 1;;
  esac
  if [[ "$UNIT_KIND" == service ]]; then
    has_nr=1; has_pid=1
    _unit_wants_mainpid "$UNIT_TYPE" && wants_pid=1
  fi
  c0="$(_j_mark "stable-$u-start")" || { SVC_STABLE_WHY="观测无效: 起界桩没建成($(_j_why))"; return 2; }
  if (( has_nr )); then
    nr0="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
    [[ "$nr0" =~ ^[0-9]+$ ]] || { SVC_STABLE_WHY="观测无效: $UNIT_ID 是 service, NRestarts 适用却读不到合法数值(实得 [${nr0}])"; return 2; }
  else
    nr0="不适用"
  fi
  st="$(wait_stable "$u" "$secs")"          # 先等它进入非过渡态
  case "$st" in
    activating|deactivating|reloading|""|"<读不到>")
      SVC_STABLE_WHY="窗口内没能进入非过渡态(停在 ${st:-读不到})"; return 1;;
  esac
  pid0="$(systemctl show -p MainPID --value "$u" 2>/dev/null)"
  inv0="$(systemctl show -p InvocationID --value "$u" 2>/dev/null)"
  if (( has_pid )) && [[ ! "$pid0" =~ ^[0-9]+$ ]]; then
    SVC_STABLE_WHY="观测无效: $UNIT_ID 是 service, MainPID 适用却读不到合法数值(实得 [${pid0}])"; return 2
  fi
  for ((i=0; i<secs; i++)); do
    sleep 1
    st="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
    sub="$(systemctl show -p SubState --value "$u" 2>/dev/null)"
    { [[ -n "$st" ]] && [[ -n "$sub" ]]; } \
      || { SVC_STABLE_WHY="观测无效: 第 ${i}s 取不到 ActiveState/SubState(实得 [$st]/[$sub])"; return 2; }
    pid="$(systemctl show -p MainPID --value "$u" 2>/dev/null)"
    inv="$(systemctl show -p InvocationID --value "$u" 2>/dev/null)"
    if [[ "$want" == running ]]; then
      [[ "$st" == active ]] || { SVC_STABLE_WHY="窗口内掉出 active(第 ${i}s 是 $st/$sub)"; return 1; }
      if (( wants_pid )); then
        { [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != 0 ]]; } \
          || { SVC_STABLE_WHY="Type=$UNIT_TYPE 的 service 活着时该有非零 MainPID, 第 ${i}s 实得 [${pid}]"; return 1; }
        [[ "$pid" == "$pid0" ]] || { SVC_STABLE_WHY="窗口内实例换过(MainPID $pid0 → $pid)"; return 1; }
      fi
      [[ -n "$inv" && "$inv" == "$inv0" ]] || { SVC_STABLE_WHY="窗口内实例换过(InvocationID $inv0 → ${inv:-读不到})"; return 1; }
    else
      case "$st" in
        active|activating) SVC_STABLE_WHY="期望停止, 窗口内却是 $st/$sub(第 ${i}s)"; return 1;;
        failed)            SVC_STABLE_WHY="期望停止, 实得 failed/$sub —— 那是崩溃之后的停, 不是合法停止态"; return 1;;
      esac
      if (( has_pid )); then
        [[ "$pid" =~ ^[0-9]+$ ]] || { SVC_STABLE_WHY="观测无效: service 停着时 MainPID 仍适用, 却读不到数值(实得 [${pid}])"; return 2; }
        [[ "$pid" == 0 ]] || { SVC_STABLE_WHY="期望停止, 却还有 MainPID=$pid"; return 1; }
      fi
    fi
  done
  if (( has_nr )); then
    nr1="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
    [[ "$nr1" =~ ^[0-9]+$ ]] || { SVC_STABLE_WHY="观测无效: 窗口后 NRestarts 读不到合法数值(实得 [${nr1}])"; return 2; }
    [[ "$nr1" == "$nr0" ]] || { SVC_STABLE_WHY="窗口内发生了自动重启(NRestarts $nr0 → $nr1)"; return 1; }
  fi
  # 动作窗口证据对所有类型都保留: timer 省掉的是 NRestarts, **不是**"有没有被启动"这一问。
  # (本机实测: 启动 timer 时 journal 写的是 "Started <unit>.timer - …", 同一条匹配式认得出来。)
  c1="$(_j_mark "stable-$u-end")" || { SVC_STABLE_WHY="观测无效: 止界桩没建成($(_j_why))"; return 2; }
  evs="$(_j_interval "$u" "$c0" "$c1")" || { SVC_STABLE_WHY="观测无效: 启动事件查不清($(_j_why))"; return 2; }
  [[ "$evs" == 0 ]] || { SVC_STABLE_WHY="窗口内有 $evs 次启动事件(界桩裁决) —— 不是持续 $want"; return 1; }
  SVC_STABLE_WHY="窗口 ${secs}s 内持续 ${want}: $UNIT_ID($UNIT_KIND${UNIT_TYPE:+/$UNIT_TYPE}, LoadState=$UNIT_LOAD) ActiveState=$st SubState=$sub MainPID=$( ((has_pid)) && echo "${pid0}" || echo 不适用) Invocation=${inv0:-无} NRestarts=$nr0 启动事件 0 次"
  return 0
}
# <<< PDG-EXTRACT-END svc_stable_window

# 进程在不在 ↔ 7894 有没有监听。判据来自 v1.11.15 的 mitm_server.serve():
# 它**无条件** bind 127.0.0.1:7894, 与 wloc.enabled 无关 —— enabled 决定的是
# load_from_config 登不登记接管插件。所以: 活着就该有监听; 停了就不该有。
MITM_VERDICT_WHY=""
# >>> PDG-EXTRACT-BEGIN mitm_listen_verdict
mitm_listen_verdict(){   # $1=ActiveState $2=7894 监听数 → 0 自洽 / 1 不自洽
  local ac="$1" n="${2:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || { MITM_VERDICT_WHY="监听数读不出来([$2])"; return 1; }
  if [[ "$ac" == active ]]; then
    (( n >= 1 )) && { MITM_VERDICT_WHY="pdg-mitm 活着, 7894 有监听($n)(serve() 无条件 bind, 与 enabled 无关)"; return 0; }
    MITM_VERDICT_WHY="pdg-mitm 说是 active, 7894 却没有监听 —— 进程没真正起来"; return 1
  fi
  (( n == 0 )) && { MITM_VERDICT_WHY="pdg-mitm 是 $ac, 7894 也没有监听"; return 0; }
  MITM_VERDICT_WHY="pdg-mitm 是 $ac, 7894 却还有 $n 个监听 —— 有进程没被停干净"; return 1
}
# <<< PDG-EXTRACT-END mitm_listen_verdict
# >>> PDG-EXTRACT-BEGIN svc_stable_assert
svc_stable_assert(){   # $1=unit $2=running|stopped $3=标签 → 顺带把前置置红
  local rc
  svc_stable_window "$1" "$2" "${4:-8}"; rc=$?
  case "$rc" in
    0) ok "$3: $SVC_STABLE_WHY";;
    1) bad "$3: 不是持续稳定 —— $SVC_STABLE_WHY"; PREIMAGE_OK=0;;
    *) bad "$3: **观测无效** —— $SVC_STABLE_WHY"; PREIMAGE_OK=0;;
  esac
  return "$rc"
}
# <<< PDG-EXTRACT-END svc_stable_assert

# ── 测试指纹 vs 产品自己写的 svcstate.tsv ──────────────────────────────────────
# 353: svcstate_cross_check 改为"产品记录的操作前像 vs 调用前的独立采样"(A5 的第一件), 定义挪到下面「p5段 公共函数」里。
#      以前拿**恢复后的现场**去比产品前像 —— 那说明不了产品前像记对没有, 还能零项通过。

# ── 历史残留: 每一项写明来源与指纹, 不笼统豁免也不一律拒绝 ──────────────────
RESIDUE_MANIFEST="$EVID/residue-manifest.tsv"
residue_record(){   # $1=路径 $2=来源说明
  [[ -e "$1" ]] || { printf '%s\t%s\t<不存在>\n' "$1" "$2" >> "$RESIDUE_MANIFEST"; return 1; }
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(sha256sum "$1" 2>/dev/null | awk '{print $1}')" \
    "$(stat -c '%a %u:%g' "$1")" >> "$RESIDUE_MANIFEST"
}
residue_report(){   # 打印清单并逐项确认
  local n; n="$(grep -c . "$RESIDUE_MANIFEST" 2>/dev/null || echo 0)"
  echo "── 预先构造的历史残留(逐项来源 + 指纹) ──"
  sed 's/^/    /' "$RESIDUE_MANIFEST" 2>/dev/null
  [[ "$n" -ge 1 ]] && ok "残留清单已逐项记账($n 项, 见 $RESIDUE_MANIFEST)" || bad "残留清单是空的"
  chmod 600 "$RESIDUE_MANIFEST" 2>/dev/null || true
}

# ── 候选部署身份: 与历史残留**分开**核验 ────────────────────────────────────
assert_candidate_identity(){   # $1=平台 → 0 身份成立 / 1 不成立或未取得(调用方据此置前提不成立)
  local plat="$1" mis=0 dif=0 n=0 src name _mode lst fn a b rc=0 _rbok=1
  if p5_same_file "$P5_CLI" "$CANDSRC/deploy/bot/pdg.sh"; then ok "部署身份: $P5_CLI 逐字节等于冻结候选"
  else bad "部署身份: pdg 不是候选那一份或摘要取不到 —— $P5_WHY"; rc=1; fi
  lst="${E2E_TMP:?}/p5-ident-$plat.txt"
  if p5_modlist "$CANDSRC" "$plat" "$lst"; then
    while read -r src name _mode; do
      [[ -n "$name" ]] || continue
      n=$((n+1))
      [[ -e "$P5_MODDIR/$name" ]] || { mis=$((mis+1)); continue; }
      cmp -s "$CANDSRC/$src" "$P5_MODDIR/$name" || dif=$((dif+1))
    done < "$lst"
    { (( n > 0 )) && [[ "$mis" == 0 && "$dif" == 0 ]]; } \
      && ok "部署身份: $n 项受管模块与冻结候选逐字节一致(缺 $mis / 不符 $dif)" \
      || { bad "部署身份: 受管模块与候选不一致(清单 $n 项, 缺 $mis / 不符 $dif)"; rc=1; }
  else bad "部署身份: $P5_WHY"; rc=1; fi
  # 本轮真正要看的两段代码就在这个文件里: 被调用的 CLI 与失败善后用的恢复实现。
  # 353: 逐段核对改为"有源码依据的有效范围"。候选里 _plat_fail_restore / _plat_rollback 是 cmd_platform 里的
  #      **嵌套**函数(候选 deploy/bot/pdg.sh 7639 / 7558 行, 行首缩进两格), 按"顶格 名(){"去抽只会得到空串 ——
  #      以前两边空串相等就打了通过。现在: cmd_platform 按顶格起止取整段, 这一段里必须真的含那两处嵌套定义;
  #      其余三支按顶格取, 取不到完整函数体就判不成立。
  for fn in cmd_platform _pdg_restore_svcstate migrate_wloc_retire cmd_rollback; do
    if ! a="$(p5_fnrange "$P5_CLI" "$fn")" || ! b="$(p5_fnrange "$CANDSRC/deploy/bot/pdg.sh" "$fn")"; then
      _rbok=0; echo "       $fn 在已装或候选的 pdg 里取不到完整函数体"; continue
    fi
    [[ "$a" == "$b" ]] || { _rbok=0; echo "       $fn 不是候选那一份"; continue; }
    if [[ "$fn" == cmd_platform ]]; then
      { grep -qx '  _plat_rollback(){' <<<"$a" && grep -qx '  _plat_fail_restore(){' <<<"$a"; } \
        || { _rbok=0; echo "       cmd_platform 里找不到嵌套的 _plat_rollback / _plat_fail_restore 定义"; }
    fi
  done
  (( _rbok )) \
    && ok "部署身份: 本轮要调用的 CLI 与恢复实现(cmd_platform 整段含嵌套的 _plat_rollback / _plat_fail_restore, _pdg_restore_svcstate, migrate_wloc_retire, cmd_rollback)逐段等于候选" \
    || { bad "部署身份: 回滚实现或 CLI 不是候选那一份, 或取不到有效范围"; rc=1; }
  _evn 00-identity.txt "候选部署身份: pdg+${n} 模块; 缺 $mis 不符 $dif; 恢复实现逐段一致=$_rbok; 结论 rc=$rc"
  return "$rc"
}

# ── DNS 仪器: 固定实验条件 → 标定 → 正式取证, 三处用**同一套**有效性要求 ────────
#
# 为什么要先固定实验条件(这一段是实测出来的, 不是推的; 证据见 22-correction-dns-attribution):
#   · 夹具用的是 `all` 形态 —— _mosdns_hijack_shape 会把 `!qname $hijack_set → 上游` 那道门
#     **整段移除**, 于是任何没被前面分支处理掉的名字都落到 internal_sequence 末尾那条
#     `qtype 1 → black_hole __SERVER_IP__`。把名字从 mitm_hijack 里删掉**不会**让它走上游。
#   · force_hijack_seq 与末尾那条普通劫持对 A 记录**是同一个动作**(都 black_hole 到同一个
#     地址)。所以"加一条 mitm_hijack 条目看答案变不变"在 all 形态下先天测不出东西。
#   · 真钉版 mosdns 实测: 上一轮那种同答, 两个自有上游**一次都没收到过查询** ——
#     不是"上游对谁都答同一个地址", 是压根没问上游。
# 固定条件因此是两件事, 都用**既有合法输入**, 不改产品规则/优先级/劫持模式:
#   ① 只把**外围上游**指到自有可控端(mosdns、配置加载、真实查询都不打桩);
#   ② 把待测名/见证名/对照名写进 geosite_cn.txt —— internal_sequence 里
#      `qname $force_hijack` 排在 `qname $geosite_cn` **之前**, 于是
#         不在 mitm_hijack → geosite_cn 分支 → $local_upstream → 自有上游 → **U**
#         在   mitm_hijack → force_hijack_seq → black_hole        → **H**
# 这两件事在**标定之前**做一次, 之后甲乙两次测量之间一个字都不动。
DNS_INSTRUMENT_OK=0
DNS_CALIB_WHY=""
DNS_U="198.51.100.7"                 # 自有上游固定给的 A —— 未接管时的期望答案
DNS_H="${E2E_SIP:-203.0.113.1}"      # 产品配置规定的劫持地址 —— 接管时的期望答案
DNS_UP_PORT=15301
DNS_WITNESS="gs-loc.apple.com"                    # 业务见证名(前像里真的在接管表里)
DNS_CONTROL="control-not-hijacked.e2e.test"       # 对照名(两种配置下都该是 U)
DNS_CALIB_NAME=""
DNS_STUB_PID=""
DNS_RESTORE_DISK=0
DNS_RESTORE_RUN=0

# 一次查询的**完整**观测: 退出码 / DNS 状态 / 规范化答案 / stderr 首行。四样一起记一起判。
dns_probe(){   # $1=域名 → "rc<TAB>status<TAB>answer<TAB>stderr首行"
  local out err rc st ans
  err="$(mktemp "${TMPDIR:-/tmp}/dnsprobe.XXXXXX")"
  out="$(dig +time=3 +tries=1 +retry=0 @127.0.0.1 "$1" A 2>"$err")"; rc=$?
  st="$(grep -o 'status: [A-Z]*' <<<"$out" | head -1 | awk '{print $2}')"
  ans="$(awk '/^;; ANSWER SECTION/{f=1;next} f&&/^[^;]/{print $NF; exit}' <<<"$out")"
  printf '%s\t%s\t%s\t%s\n' "$rc" "${st:-NO-STATUS}" "${ans:-NO-ANSWER}" "$(head -1 "$err" | tr -d '\t')"
  rm -f "$err"
}
# **预先写死的成功契约**: 退出码 0 + 状态 NOERROR + 有真答案 + stderr 空。
# 超时 / SERVFAIL / 空答案 / 任何异常都不是一次有效观测, 不得充当"两份配置结果不同"的证据,
# 也不得在正式取证里因为"两份错误文本恰好相等"就判恢复通过。
dns_probe_ok(){   # $1=dns_probe 的一行
  local rc st ans er; IFS=$'\t' read -r rc st ans er <<<"$1"
  [[ "$rc" == 0 && "$st" == NOERROR && -n "$ans" && "$ans" != NO-ANSWER && -z "$er" ]]
}
dns_answer_of(){ cut -f3 <<<"$1"; }

# 让 mosdns 重新起来。InvocationID 变过**只证明实例换了** —— 它不证明加载的是哪一份配置;
# "预期配置有没有生效"一律由随后的真实 DNS 行为回答(见 dns_expect)。
_dns_reload(){
  local inv0 inv1 ac
  inv0="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)"
  systemctl restart mosdns >/dev/null 2>&1 || { DNS_CALIB_WHY="mosdns 重启动作失败"; return 1; }
  ac="$(wait_stable mosdns)"
  [[ "$ac" == active ]] || { DNS_CALIB_WHY="mosdns 重启后停在 $ac, 没有稳定运行"; return 1; }
  inv1="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)"
  [[ -n "$inv1" && "$inv1" != "$inv0" ]] \
    || { DNS_CALIB_WHY="mosdns 实例没有更替(InvocationID $inv0 → ${inv1:-读不到})"; return 1; }
  return 0
}
# 用**真实 DNS 行为**确认某个名字此刻拿到的就是期望答案。
dns_expect(){   # $1=域名 $2=期望答案 → 0/1, 失败时把原因写进 DNS_CALIB_WHY
  local p a
  p="$(dns_probe "$1")"
  if ! dns_probe_ok "$p"; then DNS_CALIB_WHY="查询 $1 无效($p)"; return 1; fi
  a="$(dns_answer_of "$p")"
  [[ "$a" == "$2" ]] || { DNS_CALIB_WHY="查询 $1 得到 $a, 期望 $2"; return 1; }
  return 0
}

# 固定实验条件。只做一次; 做完之后甲乙两次测量之间上游、域名归属、监听地址都不再动。
dns_fix_conditions(){
  local hij=/etc/mosdns/rules/mitm_hijack.txt cn=/etc/mosdns/rules/geosite_cn.txt
  local mc=/etc/mosdns/config.yaml
  command -v dig >/dev/null 2>&1 || { DNS_CALIB_WHY="机器上没有 dig"; return 1; }
  [[ -f "$mc" && -f "$hij" && -f "$cn" ]] || { DNS_CALIB_WHY="mosdns 配置或规则文件不齐"; return 1; }
  DNS_CALIB_NAME="dns-calib-$$-${RANDOM}.e2e.test"   # 每次新名字, 排除缓存带来的假差异
  # ① 自有上游(本轮事先登记归属的资源: 退出时按 PID 清理, 不按名字宽杀)
  "$E2E_ROOT/tests/helpers/dns-stub.py" --port "$DNS_UP_PORT" \
      --count "$E2E_TMP/dns-up.count" --log "$E2E_TMP/dns-up.log" \
      --mode answer-a --answer "$DNS_U" > "$E2E_TMP/dns-up.out" 2>&1 &
  DNS_STUB_PID=$!
  sleep 1
  kill -0 "$DNS_STUB_PID" 2>/dev/null || { DNS_CALIB_WHY="自有 DNS 上游没起来: $(tail -2 "$E2E_TMP/dns-up.out" 2>/dev/null)"; return 1; }
  # ② local_upstream 整行换成自有可控端(上游列表里本来就有 {}, 用 [^}]* 会在第一个右括号停住)
  python3 - "$mc" "$DNS_UP_PORT" <<'PYUP'
import re, sys
p, port = sys.argv[1], sys.argv[2]
lines = open(p, encoding="utf-8").read().split("\n")
tag = None; done = False
for i, ln in enumerate(lines):
    if re.match(r'  - tag: local_upstream$', ln): tag = 1; continue
    if tag and ln.startswith("    args: "):
        lines[i] = '    args: { concurrent: 1, upstreams: [ {addr: "udp://127.0.0.1:%s"} ] }' % port
        tag = None; done = True
open(p, "w", encoding="utf-8").write("\n".join(lines))
raise SystemExit(0 if done else 1)
PYUP
  [[ $? == 0 ]] || { DNS_CALIB_WHY="没能把 local_upstream 指到自有上游"; return 1; }
  # ③ 三个名字都进 geosite_cn(既有合法输入): 未接管时它们才会真的走正常解析路径
  printf 'full:%s\nfull:%s\nfull:%s\n' "$DNS_CALIB_NAME" "$DNS_WITNESS" "$DNS_CONTROL" >> "$cn"
  _dns_reload || return 1
  # 自证: 此刻对照名确实从自有上游拿到 U, 且上游日志里按名记到了它
  dns_expect "$DNS_CONTROL" "$DNS_U" || return 1
  grep -q " q=$DNS_CONTROL " "$E2E_TMP/dns-up.log" \
    || { DNS_CALIB_WHY="对照名答对了, 但自有上游日志里没有它 —— 答案不是上游给的"; return 1; }
  ok "仪器条件: 自有上游已就位, 对照名 $DNS_CONTROL 经 local_upstream 取得 U=$DNS_U(上游日志按名可核)"
  return 0
}

# 标定: 同一个查询名, **只**让 mitm_hijack 里那一条变。U→H→U 三段都要有效且等于预期。
dns_instrument_calibrate(){
  local hij=/etc/mosdns/rules/mitm_hijack.txt
  local bak sum0 mode0 own0 sum1 mode1 own1 entry
  DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
  dns_fix_conditions || { bad "仪器标定: 固定实验条件失败 —— $DNS_CALIB_WHY"; return 1; }
  [[ "$DNS_U" != "$DNS_H" ]] || { bad "仪器标定: U 与 H 相同($DNS_U), 这组预期本身没有区分力"; return 1; }
  entry="full:$DNS_CALIB_NAME"
  bak="${E2E_TMP:-${TMPDIR:-/tmp}}/hijack-calib.bak"
  cat "$hij" > "$bak" || { bad "仪器标定: 存不下接管表副本"; return 1; }
  sum0="$(sha256sum "$hij" | awk '{print $1}')"
  mode0="$(stat -c %a "$hij")"; own0="$(stat -c %u:%g "$hij")"
  # 还原分成**磁盘**与**运行配置**两件事, 分别判定 —— 只写回磁盘不算已恢复。
  _dns_calib_restore(){
    DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
    cat "$bak" > "$hij" 2>/dev/null || return 1
    chmod "$mode0" "$hij" 2>/dev/null || true
    chown "$own0"  "$hij" 2>/dev/null || true
    sum1="$(sha256sum "$hij" | awk '{print $1}')"
    mode1="$(stat -c %a "$hij")"; own1="$(stat -c %u:%g "$hij")"
    [[ -f "$hij" && "$sum1" == "$sum0" && "$mode1" == "$mode0" && "$own1" == "$own0" ]] || return 1
    DNS_RESTORE_DISK=1
    _dns_reload || return 1
    dns_expect "$DNS_CALIB_NAME" "$DNS_U" || return 1      # 运行配置真的回到"未接管"
    DNS_RESTORE_RUN=1
    return 0
  }
  _calib_fail(){   # 失败收尾: 先还原, 再把两件事分别报清楚
    if _dns_calib_restore; then
      bad "仪器标定: $DNS_CALIB_WHY(磁盘与运行配置都已还原并核对)"
    else
      bad "仪器标定: $DNS_CALIB_WHY"
      bad "仪器标定: 收尾未完成 —— 磁盘还原=$( ((DNS_RESTORE_DISK)) && echo 已完成 || echo 未完成), 运行配置还原=$( ((DNS_RESTORE_RUN)) && echo 已确认 || echo 未确认)"
      c_keep_note
    fi
    return 1
  }
  c_keep_note(){
    note "  本轮自有恢复材料保留在: $bak(接管表原件, sha256=$sum0 mode=$mode0 owner=$own0)"
    note "  环境可能已被污染, 后续场景不再继续 —— 不拿一个说不清的现场做验收。"
  }

  # ── 配置甲: 待测名**不在** mitm_hijack ──
  _dns_reload || { _calib_fail; return 1; }
  local p_off p_on a_off a_on
  p_off="$(dns_probe "$DNS_CALIB_NAME")"
  local up_off; up_off="$(grep -c " q=$DNS_CALIB_NAME " "$E2E_TMP/dns-up.log" 2>/dev/null | tr -d '\n')"
  # ── 配置乙: **只**多这一条条目, 其余一个字不动 ──
  printf '%s\n' "$entry" >> "$hij"
  _dns_reload || { _calib_fail; return 1; }
  p_on="$(dns_probe "$DNS_CALIB_NAME")"
  local up_on; up_on="$(grep -c " q=$DNS_CALIB_NAME " "$E2E_TMP/dns-up.log" 2>/dev/null | tr -d '\n')"
  _evn dns-calibration.txt "查询名 $DNS_CALIB_NAME(每次新造; 两次测量之间重启 mosdns 清缓存)"
  _evn dns-calibration.txt "配置甲(不在接管表) rc/status/answer/stderr = $p_off  自有上游累计收到=$up_off"
  _evn dns-calibration.txt "配置乙(在接管表)   rc/status/answer/stderr = $p_on   自有上游累计收到=$up_on"

  # ── 还原甲, 并确认**运行配置**也回到未接管 ──
  if ! _dns_calib_restore; then
    DNS_CALIB_WHY="${DNS_CALIB_WHY:-还原失败}"; _calib_fail; return 1
  fi
  ok "仪器标定: 接管表按内容与属性逐项还原, 且**运行配置**经真实查询确认回到未接管($DNS_U)"

  # ── 判定 ──
  if ! dns_probe_ok "$p_off" || ! dns_probe_ok "$p_on"; then
    DNS_CALIB_WHY="两次测量里有观测不满足成功契约(甲=$p_off ; 乙=$p_on)"
    bad "仪器标定: $DNS_CALIB_WHY —— 超时/SERVFAIL/空答案不得充当'结果不同'"
    return 1
  fi
  a_off="$(dns_answer_of "$p_off")"; a_on="$(dns_answer_of "$p_on")"
  if [[ "$a_off" != "$DNS_U" || "$a_on" != "$DNS_H" ]]; then
    DNS_CALIB_WHY="答案不符合预先固定的 U/H(甲=$a_off 期望 $DNS_U; 乙=$a_on 期望 $DNS_H)"
    bad "仪器标定: $DNS_CALIB_WHY —— 只要求'两个非空串不同'是不够的"
    return 1
  fi
  [[ "$up_on" == "$up_off" ]] \
    && ok "仪器标定: 配置乙那次**没有**问上游(累计仍是 $up_on) —— 答案确实来自接管分支" \
    || bad "仪器标定: 配置乙那次仍然问了上游($up_off → $up_on), 与'接管优先'不符"
  DNS_INSTRUMENT_OK=1
  ok "仪器标定: 同一查询名 U→H 精确命中($DNS_U → $DNS_H), 两次观测都满足成功契约"
  return 0
}

# 正式取证: 与标定**同一套**有效性要求。
# 输出 "VALID<TAB>见证答案<TAB>对照答案" 或 "INVALID<TAB>原因"。
dns_feature_probe(){   # $1=标签
  local ph pc
  ph="$(dns_probe "$DNS_WITNESS")"; pc="$(dns_probe "$DNS_CONTROL")"
  _evn "dns-probe-$1.txt" "见证 $DNS_WITNESS  rc/status/answer/stderr = $ph"
  _evn "dns-probe-$1.txt" "对照 $DNS_CONTROL rc/status/answer/stderr = $pc"
  if ! dns_probe_ok "$ph" || ! dns_probe_ok "$pc"; then
    printf 'INVALID\t观测不满足成功契约(见证=%s ; 对照=%s)\n' "$ph" "$pc"; return 1
  fi
  printf 'VALID\t%s\t%s\n' "$(dns_answer_of "$ph")" "$(dns_answer_of "$pc")"
}
# 判一次"前后像 DNS 行为"。两边都必须是**有效观测**, 且见证=H、对照=U。
dns_verdict(){   # $1=标签 $2=before $3=after
  local bs bw bc as aw ac
  IFS=$'\t' read -r bs bw bc <<<"$2"; IFS=$'\t' read -r as aw ac <<<"$3"
  if [[ "$bs" != VALID || "$as" != VALID ]]; then
    bad "$1 已加载配置: 前像或恢复后的观测**无效**, 不能因为两边文本相等就判恢复通过"
    note "  前像: $2"; note "  恢复后: $3"
    return 1
  fi
  { [[ "$bw" == "$aw" && "$bc" == "$ac" ]]; } \
    && ok "$1 已加载配置(可区分行为): 见证与对照都回到前像(见证 $aw / 对照 $ac)" \
    || bad "$1 已加载配置: DNS 行为变了(见证 $bw→$aw, 对照 $bc→$ac)"
  { [[ "$aw" == "$DNS_H" && "$ac" == "$DNS_U" ]]; } \
    && ok "$1 已加载配置(对预期): 见证=H($DNS_H) 对照=U($DNS_U) —— 差异确实来自接管规则" \
    || bad "$1 已加载配置: 不符合预先固定的 U/H(见证=$aw 期望 $DNS_H; 对照=$ac 期望 $DNS_U)"
}

# 本轮自有资源的清理: **只**按事先登记的 PID 收自己起的那个上游, 不按名字宽杀。
_dns_cleanup(){
  [[ -n "${DNS_STUB_PID:-}" ]] || return 0
  kill "$DNS_STUB_PID" 2>/dev/null || true
  wait "$DNS_STUB_PID" 2>/dev/null || true
  DNS_STUB_PID=""
}
trap '_dns_cleanup' EXIT

# ═════════════════════════════════════════════════════════════════════════════
# 四维指纹: 文件(存在性/内容/mode/uid:gid) / 运行态 / 自启态 / 已加载配置的独立依据
# ═════════════════════════════════════════════════════════════════════════════
FP_FILES=(/etc/systemd/system/pdg-mitm.service
          /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
          /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py
          /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
          /etc/mosdns/rules/mitm_hijack.txt /etc/privdns-gateway/mitm.json
          /etc/privdns-gateway/platform /etc/privdns-gateway/profile.env
          /etc/privdns-gateway/ca/ca.crt /etc/privdns-gateway/ca/ca.key
          /etc/privdns-gateway/ios-profile.json
          /var/lib/privdns-gateway/ios-profile/current.mobileconfig
          /var/lib/privdns-gateway/ios-profile/previous.mobileconfig
          /etc/nftables.conf
          /etc/mihomo/config.yaml)
FP_SVCS=(pdg-mitm mosdns mihomo pdg-bot pdg-probe81)
# ── p5段 公共函数 起 ──
# ═════════════════════════════════════════════════════════════════════════════
# 353: ⑤ 专有的读取与判定(A1–A9)。不带抽取标记; 被 ②③④、DNS 仪器与各契约抽取的共享原文一字不动。
# 规矩: 每一次读取分别核原始退出码、输出结构与业务条件; 先输出后失败的内容不采信;
#       读不到 / 缺记录 / 旧记录 / 空对空 = 观测无效(未取得), 不当成零、空状态或"相等"。
# 命名: 一律 p5 前缀, 且不以任何被按名 / 按子串定位的共享函数名结尾(见 352 的共享影响表)。
# ═════════════════════════════════════════════════════════════════════════════
P5_WHY=""; P5_VAL=""; P5_RC=""; P5_LN=""; P5_ROW=""
P5_CLI=/usr/local/bin/pdg; P5_MODDIR=/opt/pdg-bot; P5_HIJACK=/etc/mosdns/rules/mitm_hijack.txt
P5_SNAPDIR="${SNAP_DIR:-/var/lib/privdns-gateway/backups}"
# 候选 _pdg_svcstate_units(候选 deploy/bot/pdg.sh 1365)写进服务前像的 8 个 unit
P5_SVC8=(pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer)
# A7 依据(353 证据目录 basis/A7-basis.tsv): 失败路径 + 整体恢复里会 restart 的 unit; pdg-mitm 只在 a2i 方向另加
P5_START_OK=(mosdns mihomo pdg-probe81)
declare -A P5_RES=()      # 恢复结果: 键 = 项名, 值 = ok(已恢复) / diff(未恢复) / na(未取得)
declare -A P5_FPN=()      # 四维采样: 标签 → 本次采样的 nonce(防旧记录冒充)
declare -A P5_MAT=()      # 产品自报的三处材料路径
P5_OKDEF="$(declare -f ok)"; P5_BADDEF="$(declare -f bad)"
p5_tally(){ P5_RES["$2"]="$1"; }

# 单元查询: 状态词与**原始退出码**配对(与 ① r1_unit_q、③ r3_unit_q 同一规则); 在本壳里调用, 结果留在 P5_VAL / P5_RC / P5_WHY
p5_uq(){   # $1=active|enabled|load $2=unit [$3=已有效取得的 LoadState] → 0 取得 / 2 观测无效
  local k="$1" u="$2" out rc err ef="${E2E_TMP:-/tmp}/p5uq.err"
  P5_VAL=""; P5_RC=""; P5_WHY=""
  case "$k" in
    active)  out="$(systemctl is-active "$u" 2>"$ef")"; rc=$?;;
    enabled) out="$(systemctl is-enabled "$u" 2>"$ef")"; rc=$?;;
    load)    out="$(systemctl show -p LoadState --value "$u" 2>"$ef")"; rc=$?;;
    *) P5_WHY="p5_uq 不认识的查询 [$k]"; return 2;;
  esac
  P5_RC="$rc"
  err="$(tr '\n' ' ' < "$ef" 2>/dev/null)"; rm -f "$ef" 2>/dev/null
  [[ "$out" != *$'\n'* ]] || { P5_WHY="$u 的 $k 查询输出不止一行(rc=$rc)"; return 2; }
  case "$k" in
    active)
      case "$out" in
        active|reloading|refreshing) (( rc == 0 )) || { P5_WHY="$u is-active 打印 $out 却退出 $rc"; return 2; };;
        inactive) { (( rc == 3 )) || { (( rc == 4 )) && [[ "${3:-}" == not-found ]]; }; } \
                    || { P5_WHY="$u is-active 打印 inactive 却退出 $rc(LoadState=${3:-未提供})"; return 2; };;
        failed|activating|deactivating|maintenance) (( rc == 3 )) || { P5_WHY="$u is-active 打印 $out 却退出 $rc"; return 2; };;
        *) P5_WHY="$u is-active 输出不是状态词([${out:0:30}], rc=$rc, stderr: ${err:-无})"; return 2;;
      esac;;
    enabled)
      case "$out" in
        enabled|enabled-runtime|alias|static|indirect|generated|transient) (( rc == 0 )) || { P5_WHY="$u is-enabled 打印 $out 却退出 $rc"; return 2; };;
        linked|linked-runtime|masked|masked-runtime|disabled|not-found) (( rc != 0 )) || { P5_WHY="$u is-enabled 打印 $out 却退出 0"; return 2; };;
        "") if (( rc != 0 )) && [[ "$err" == *"No such file or directory"* ]]; then out=not-found
            else P5_WHY="$u is-enabled 没有输出(rc=$rc, stderr: ${err:-无})"; return 2; fi;;
        *) P5_WHY="$u is-enabled 输出不是状态词([${out:0:30}], rc=$rc)"; return 2;;
      esac;;
    load)
      (( rc == 0 )) || { P5_WHY="$u 的 LoadState 查询退出 $rc(输出不采信)"; return 2; }
      case "$out" in loaded|not-found|bad-setting|error|masked|merged|stub) ;;
        *) P5_WHY="$u 的 LoadState 不是状态词([${out:0:30}])"; return 2;; esac;;
  esac
  P5_VAL="$out"
}
p5_show(){   # $1=属性 $2=unit → 0 取得(P5_VAL, 可为空) / 2 观测无效(退出非零或多行)
  local out rc; P5_VAL=""; P5_WHY=""
  out="$(systemctl show -p "$1" --value "$2" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { P5_WHY="$2 的 $1 查询退出 $rc(输出不采信)"; return 2; }
  [[ "$out" != *$'\n'* ]] || { P5_WHY="$2 的 $1 输出不止一行"; return 2; }
  P5_VAL="$out"
}
p5_digest(){   # $1=文件 → 0 取得(P5_VAL = 64 位十六进制) / 2 取不到
  local out rc; P5_VAL=""; P5_WHY=""
  out="$(sha256sum -- "$1" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ "${out:0:64}" =~ ^[0-9a-f]{64}$ ]]; } || { P5_WHY="$1 的 sha256 取不到(rc=$rc)"; return 2; }
  P5_VAL="${out:0:64}"
}
p5_meta(){   # $1=文件 → 0 取得(P5_VAL = mode<TAB>uid<TAB>gid) / 2 取不到
  local out rc; P5_VAL=""; P5_WHY=""
  out="$(stat -c '%a %u %g' -- "$1" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ "$out" =~ ^[0-7]{1,4}\ [0-9]+\ [0-9]+$ ]]; } || { P5_WHY="$1 的属性取不到(rc=$rc)"; return 2; }
  P5_VAL="${out// /$'\t'}"
}
p5_same_file(){   # $1 $2 → 0 两边摘要都有效且相等 / 1 都有效但不同 / 2 有一边取不到
  local a b
  p5_digest "$1" || return 2; a="$P5_VAL"
  p5_digest "$2" || return 2; b="$P5_VAL"
  [[ "$a" == "$b" ]] || { P5_WHY="$1 与 $2 摘要不同(${a:0:12} / ${b:0:12})"; return 1; }
}
p5_listen(){   # $1=端口 $2=tcp|udp → 0 取得(P5_LN = 监听条数, 0 是有效的"确认没有") / 2 观测无效
  local out rc lrc opt=-lnt; P5_LN=""; P5_WHY=""
  [[ "$2" == udp ]] && opt=-lnu
  out="$(ss "$opt" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { P5_WHY="ss $opt 退出 $rc(输出不采信)"; return 2; }
  [[ "${out%%$'\n'*}" == *"Local Address:Port"* ]] || { P5_WHY="ss $opt 的输出没有表头"; return 2; }
  # 354: 计数本身的退出码也核 —— 解析失败时哪怕已经打出一个合法数字也不采信
  P5_LN="$(awk -v p=":$1" 'NR>1 && length($4) >= length(p) && substr($4, length($4)-length(p)+1) == p {n++} END{print n+0}' <<<"$out")"; lrc=$?
  { (( lrc == 0 )) && [[ "$P5_LN" =~ ^[0-9]+$ ]]; } || { P5_WHY="监听计数解析失败(awk rc=$lrc, 输出不采信)"; P5_LN=""; return 2; }
}
p5_modlist(){   # $1=源码根 $2=平台 $3=落点 → 0 清单有效(非空行 ≥ 1, 每行三段) / 2 无效(生成失败、先输出后失败、为空、结构不对、计数读不了)
  local rc n grc; P5_WHY=""
  ( # shellcheck source=/dev/null
    source "$1/lib/modules.sh" && pdg_platform_modules "$2" ) > "$3" 2>/dev/null; rc=$?
  (( rc == 0 )) || { P5_WHY="$2 平台清单生成失败(rc=$rc, 已输出的内容不采信)"; return 2; }
  # 354: 条数查询的退出码分开认 —— 0 = 有、1 = 确实一行都没有(合法的空)、其余 = 查询出错(输出不采信)
  n="$(grep -c . "$3")"; grc=$?
  { (( grc <= 1 )) && [[ "$n" =~ ^[0-9]+$ ]]; } || { P5_WHY="$2 平台清单的条数计数读不了(grep rc=$grc, 输出不采信)"; return 2; }
  (( n >= 1 )) || { P5_WHY="$2 平台清单是空的"; return 2; }
  awk 'NF > 0 && NF != 3 {bad=1} END{exit bad}' "$3" || { P5_WHY="$2 平台清单有行不是「源 目标名 mode」三段(或结构检查本身失败)"; return 2; }
}
p5_fnrange(){   # $1=文件 $2=函数名 → 打印"名(){"顶格起、到第一个顶格 } 止的原文; 找不到开头或结尾 ⇒ 2
  local out rc
  out="$(awk -v f="$2" 'index($0,f"(){")==1{p=1} p{print} p&&/^}$/{c=1; exit} END{exit (p&&c)?0:3}' "$1" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ -n "$out" ]]; } || return 2
  printf '%s\n' "$out"
}

# ── A9: 记账包装 —— 共享函数原样执行, 只给这一次调用在 PATH 最前放 systemctl / journalctl 记账 ──
# 任何一次非零退出都记下 ⇒ 整次观测无效(一次失败不会被随后的成功覆盖); 例外只有 `journalctl --sync`(共享的尽力刷盘, 输出不被任何判据消费)。
# 记账追加失败 ⇒ 包装向本壳发 USR1 ⇒ 粘性标志; 记账读不回来 ⇒ 观测无效。被测函数自己打的 ok / bad 先进缓冲,
# 外层核完有效性再由 p5_acct_flush 采信或作废(包装里提前打印的 OK 不会在外层判无效之后仍算成立)。
# 调用一返回就复原 PATH(只在那次调用的前缀里)、ok / bad 的定义与 USR1 处置; 不定义同名函数、不导出 —— 产品进程继承不到。
P5_ACCT_FAULT=0; P5_ACCT_RC=""; P5_ACCT_BUFFILE=""; P5_ACCT_PID=""
p5_acct(){   # $1=标签 $2=stdout 落点 $3..=命令(在本壳里执行) → 0 有效 / 2 观测无效(P5_WHY); 命令返回码在 P5_ACCT_RC
  local lbl="$1" out="$2"; shift 2
  local wd rec c real rc raw n prev_usr1 ex
  P5_ACCT_RC=""; P5_WHY=""; P5_ACCT_BUFFILE=""
  wd="${E2E_TMP:?}/p5acct-$BASHPID-$RANDOM"; rec="$wd.rec"
  if ! { mkdir -p -- "$wd" && : > "$rec" && : > "$wd.buf"; } 2>/dev/null; then P5_WHY="$lbl: 查询记账建不出来"; return 2; fi
  for c in systemctl journalctl; do
    real="$(type -P "$c")"
    [[ -n "$real" && "$real" != "$wd/$c" ]] || { P5_WHY="$lbl: 找不到真实的 $c"; rm -rf -- "$wd" "$rec" "$wd.buf"; return 2; }
    # 354: journalctl --sync 的例外只给 journalctl(共享的尽力刷盘), 不扩大到 systemctl 或别的命令
    ex=""; [[ "$c" == journalctl ]] && ex=' && [[ "$*" != --sync ]]'
    if ! printf '#!/usr/bin/env bash\n%q "$@"; rc=$?\nif (( rc != 0 ))%s; then printf "%%s\\t%%s\\t%%s\\n" %q "$rc" "$*" >> %q || kill -USR1 %q; fi\nexit "$rc"\n' \
         "$real" "$ex" "$c" "$rec" "$BASHPID" > "$wd/$c" 2>/dev/null || ! chmod +x "$wd/$c" 2>/dev/null; then
      P5_WHY="$lbl: $c 的记账包装写不出来"; rm -rf -- "$wd" "$rec" "$wd.buf"; return 2
    fi
  done
  mv -f -- "$wd.buf" "$rec.buf" 2>/dev/null || { P5_WHY="$lbl: 原判缓冲建不出来"; rm -rf -- "$wd" "$rec" "$wd.buf"; return 2; }
  P5_ACCT_BUFFILE="$rec.buf"; P5_ACCT_PID="$BASHPID"
  ok(){ printf 'OK\t%s\n' "$1" >> "$P5_ACCT_BUFFILE" 2>/dev/null || kill -USR1 "$P5_ACCT_PID"; }
  bad(){ printf 'FAIL\t%s\n' "$1" >> "$P5_ACCT_BUFFILE" 2>/dev/null || kill -USR1 "$P5_ACCT_PID"; }
  prev_usr1="$(trap -p USR1)"; P5_ACCT_FAULT=0; trap 'P5_ACCT_FAULT=1' USR1
  PATH="$wd:$PATH" "$@" > "$out"; rc=$?
  if [[ -n "$prev_usr1" ]]; then eval "$prev_usr1"; else trap - USR1; fi
  eval "$P5_OKDEF"; eval "$P5_BADDEF"
  rm -rf -- "$wd"
  P5_ACCT_RC="$rc"
  if (( P5_ACCT_FAULT )); then P5_WHY="$lbl: 记账通道失效(有记录没写进去)"; rm -f -- "$rec"; return 2; fi
  raw="$(cat -- "$rec" 2>/dev/null)" || { P5_WHY="$lbl: 查询记账读不了"; return 2; }
  rm -f -- "$rec"
  if [[ -n "$raw" ]]; then n="$(grep -c . <<<"$raw")"; P5_WHY="$lbl: 有 $n 次查询非零退出(首条: ${raw%%$'\n'*})"; return 2; fi
  return 0
}
p5_acct_flush(){   # $1=外层结论(0 有效 / 非 0 无效) $2=标签 → 按结论采信或作废缓冲里的 ok / bad
  local raw r k m
  [[ -n "$P5_ACCT_BUFFILE" ]] || return 0
  raw="$(cat -- "$P5_ACCT_BUFFILE" 2>/dev/null)"; r=$?
  rm -f -- "$P5_ACCT_BUFFILE" 2>/dev/null; P5_ACCT_BUFFILE=""
  (( r == 0 )) || { bad "$2: 被测判据的原判读不回来 —— 不采信"; PREIMAGE_OK=0; return 2; }
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r k m; do
    [[ -n "$k" ]] || continue
    if [[ "$1" == 0 ]]; then case "$k" in OK) ok "$m";; *) bad "$m";; esac
    else note "  (外层判观测无效, 这条原判不采信) [$k] $m"; fi
  done <<<"$raw"
}
p5_stable_assert(){   # 参数同共享 svc_stable_assert → 0 持续 / 1 不稳定 / 2 观测无效(1、2 都置 PREIMAGE_OK=0)
  local u="$1" want="$2" lbl="$3" secs="${4:-8}" arc frc
  p5_acct "$lbl" "${E2E_TMP:?}/p5sw.out" svc_stable_window "$u" "$want" "$secs"; arc=$?
  p5_acct_flush "$arc" "$lbl"; frc=$?
  if (( arc != 0 )); then
    bad "$lbl: **观测无效** —— $P5_WHY; 共享窗口给的 rc=${P5_ACCT_RC:-无}(${SVC_STABLE_WHY:-无}) 不采信"; PREIMAGE_OK=0; return 2
  fi
  # 354: 缓冲读不回 ⇒ 本项无效, 不再给成立的 OK(缓冲读取失败本身已由 p5_acct_flush 记 FAIL 并置 PREIMAGE_OK=0)
  (( frc == 0 )) || { bad "$lbl: **观测无效** —— 被测判据的原判读不回来; 共享窗口给的 rc=${P5_ACCT_RC:-无} 不采信"; PREIMAGE_OK=0; return 2; }
  case "$P5_ACCT_RC" in
    0) ok "$lbl: $SVC_STABLE_WHY"; return 0;;
    1) bad "$lbl: 不是持续稳定 —— $SVC_STABLE_WHY"; PREIMAGE_OK=0; return 1;;
    *) bad "$lbl: **观测无效** —— $SVC_STABLE_WHY"; PREIMAGE_OK=0; return 2;;
  esac
}
p5_wait_active(){   # $1=unit $2=标签 → 0 查询全部有效且稳定在 active / 1 不是 active / 2 观测无效(1、2 都置 PREIMAGE_OK=0)
  local f="${E2E_TMP:?}/p5wait.out" arc frc v
  p5_acct "$2" "$f" wait_stable "$1"; arc=$?
  p5_acct_flush "$arc" "$2"; frc=$?
  (( arc == 0 )) || { bad "$2: **观测无效** —— $P5_WHY"; PREIMAGE_OK=0; return 2; }
  # 354: 缓冲读不回 ⇒ 本项无效, 不再给成立的 OK
  (( frc == 0 )) || { bad "$2: **观测无效** —— 被测判据的原判读不回来"; PREIMAGE_OK=0; return 2; }
  v="$(cat -- "$f" 2>/dev/null)" || { bad "$2: 结果读不了"; PREIMAGE_OK=0; return 2; }
  { [[ "$P5_ACCT_RC" == 0 ]] && [[ "$v" == active ]]; } && { ok "$2: $1 稳定在 active(查询全部 0 退出)"; return 0; }
  bad "$2: $1 没有稳定在 active(实得 [$v], rc=$P5_ACCT_RC)"; PREIMAGE_OK=0; return 1
}

# ── A8: 静置只量那一次目标 sleep ─────────────────────────────────────────────
# 共享 quiesce_startlimit 原样执行(经 p5_acct 记账); 只在这一次调用期间以同名函数截下参数恰为「窗口 + 3」的那一次 sleep:
# 取它的原始退出码, 前后各读一次 CLOCK_MONOTONIC(只括住那一觉, 不含界桩重试与稳定窗口的耗时)。
# 那一觉在共享函数里位于起止两个界桩之间(1200-1211 行的代码顺序), 界桩区间内 0 次启动由共享判据判 ——
# 两者合起来才是"界桩区间里至少有「窗口 + 3」秒没有启动"。不加重试、不改限额、不 reset-failed。
P5_MONO=(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
P5_MV=""; P5_MRC=""
p5_mono(){ local out; P5_MV=""; out="$("${P5_MONO[@]}" 2>/dev/null)"; P5_MRC=$?; { (( P5_MRC == 0 )) && [[ "$out" =~ ^[0-9]+$ ]]; } || return 2; P5_MV="$out"; }
P5Q_WANT=""; P5Q_N=0; P5Q_SRC=""; P5Q_FAULT=0; P5Q_T0=""; P5Q_T1=""; P5Q_M0RC=""; P5Q_M1RC=""; P5Q_REC=""
p5q_sleep(){
  if [[ "$#" == 1 && "$1" == "$P5Q_WANT" ]]; then
    P5Q_N=$((P5Q_N+1))
    p5_mono; P5Q_M0RC="$P5_MRC"; P5Q_T0="$P5_MV"
    command sleep "$1"; P5Q_SRC=$?
    p5_mono; P5Q_M1RC="$P5_MRC"; P5Q_T1="$P5_MV"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$P5Q_SRC" "$P5Q_M0RC" "$P5Q_T0" "$P5Q_M1RC" "$P5Q_T1" >> "$P5Q_REC" 2>/dev/null || P5Q_FAULT=1
    return "$P5Q_SRC"
  fi
  command sleep "$@"
}
p5_quiesce(){   # $1=阶段 → 0 成立 / 1 不成立(已置 PREIMAGE_OK=0)
  local arc qrc want why="" out="${E2E_TMP:?}/p5q.out"
  if ! [[ "${SL_INT_S:-}" =~ ^[0-9]+$ ]]; then quiesce_startlimit "$1"; PREIMAGE_OK=0; return 1; fi
  want=$(( SL_INT_S + 3 ))
  P5Q_WANT="$want"; P5Q_N=0; P5Q_SRC=""; P5Q_FAULT=0; P5Q_T0=""; P5Q_T1=""; P5Q_M0RC=""; P5Q_M1RC=""
  P5Q_REC="${E2E_TMP:?}/p5q-$BASHPID-$RANDOM.rec"
  : > "$P5Q_REC" 2>/dev/null || { bad "静置($1): 等待记录建不出来"; PREIMAGE_OK=0; return 1; }
  sleep(){ p5q_sleep "$@"; }
  p5_acct "静置($1)" "$out" quiesce_startlimit "$1"; arc=$?; qrc="$P5_ACCT_RC"
  unset -f sleep
  cat -- "$out" 2>/dev/null
  (( arc == 0 )) || why="$why; 查询记账: $P5_WHY"
  [[ "$(type -t sleep)" == file ]] || why="$why; sleep 的截取没撤掉"
  (( P5Q_FAULT == 0 )) || why="$why; 等待记录写不进去"
  if [[ "$P5Q_N" != 1 ]]; then why="$why; 截到目标 sleep $P5Q_N 次(应恰 1 次)"
  else
    [[ "$P5Q_SRC" == 0 ]] || why="$why; 那一次 sleep 退出 $P5Q_SRC"
    if [[ "$P5Q_M0RC" == 0 && "$P5Q_M1RC" == 0 && "$P5Q_T0" =~ ^[0-9]+$ && "$P5Q_T1" =~ ^[0-9]+$ ]] && (( P5Q_T1 >= P5Q_T0 )); then
      (( P5Q_T1 - P5Q_T0 >= want * 1000000000 )) || why="$why; 那一次 sleep 实得 $(( (P5Q_T1 - P5Q_T0) / 1000000 )) ms, 不足 ${want} s"
    else why="$why; 单调时钟读数无效(读取码 ${P5Q_M0RC:-无} / ${P5Q_M1RC:-无})"; fi
  fi
  # 354: 缓冲读不回 ⇒ 静置不成立, 外层不再打成立的 OK
  if [[ -z "$why" ]]; then p5_acct_flush 0 "静置($1)" || why="被测判据的原判读不回来"; else p5_acct_flush 2 "静置($1)"; fi
  if [[ -n "$why" ]]; then bad "静置($1): **不成立** —— ${why#; }"; PREIMAGE_OK=0; return 1; fi
  (( qrc == 0 )) || { PREIMAGE_OK=0; return 1; }
  ok "静置($1): 那一次 sleep 退出 0, 实得 $(( (P5Q_T1 - P5Q_T0) / 1000000 )) ms ≥ ${want} s(读数只括住那一觉)"
  return 0
}
p5_nowrap_check(){   # 产品调用前: 没有残留的包装目录、同名函数截取与信号处置, ok / bad 是原定义 → 0 干净 / 2 有残留
  local c; P5_WHY=""
  [[ ":$PATH:" != *"/p5acct-"* ]] || { P5_WHY="PATH 里还有记账包装目录"; return 2; }
  for c in sleep systemctl journalctl; do
    [[ "$(type -t "$c")" == file ]] || { P5_WHY="$c 不是外部命令(type=$(type -t "$c"))"; return 2; }
  done
  [[ -z "$(trap -p USR1)" ]] || { P5_WHY="USR1 处置没复原"; return 2; }
  { [[ "$(declare -f ok)" == "$P5_OKDEF" ]] && [[ "$(declare -f bad)" == "$P5_BADDEF" ]]; } || { P5_WHY="ok / bad 不是原定义"; return 2; }
}
p5_dns_ready(){   # $1=dns_feature_probe 的输出 → 0 查询有效且见证 = H、对照 = U / 2 不成立(P5_WHY)
  local st w c extra
  IFS=$'\t' read -r st w c extra <<<"$1"
  { [[ "$st" == VALID ]] && [[ -z "${extra:-}" ]]; } || { P5_WHY="前像的 DNS 观测无效($1)"; return 2; }
  { [[ "$w" == "$DNS_H" ]] && [[ "$c" == "$DNS_U" ]]; } \
    || { P5_WHY="前像的 DNS 不是本方向要求的条件(见证=$w 期望 H=$DNS_H; 对照=$c 期望 U=$DNS_U)"; return 2; }
}

# ── A1: 四维指纹(文件 / 运行态 / 自启态 / 监听)——每项三态, 带本次 nonce 与 END 行 ─────────────
fp_capture(){   # $1=标签 → 写 $EVID/fp-$1.tsv; 0 完整且每项有效 / 2 有观测无效(照样写出, 无效项标 INVALID; P5_WHY 列出)
  local tag="$1" f="$EVID/fp-$1.tsv" q u d ld av ev ar er pid inv nr n why="" nonce
  nonce="$$-$BASHPID-$RANDOM-$(date +%s%N)"
  if ! {
    printf 'H\t%s\t%s\n' "$tag" "$nonce"
    for q in "${FP_FILES[@]}"; do
      if [[ -e "$q" ]]; then
        if p5_digest "$q" && d="$P5_VAL" && p5_meta "$q"; then printf 'F\t%s\t有\t%s\t%s\n' "$q" "$d" "$P5_VAL"
        else printf 'F\t%s\tINVALID\t-\t-\t-\t-\n' "$q"; why="$why 文件 $q"; fi
      elif [[ -L "$q" ]]; then printf 'F\t%s\tINVALID\t-\t-\t-\t-\n' "$q"; why="$why 文件 $q(悬空链接)"
      else printf 'F\t%s\t无\t-\t-\t-\t-\n' "$q"; fi
    done
    for u in "${FP_SVCS[@]}"; do
      ld=INVALID; av=INVALID; ev=INVALID; pid=INVALID; inv=INVALID; nr=INVALID
      if p5_uq load "$u"; then ld="$P5_VAL"; else why="$why $u(LoadState)"; fi
      if p5_uq active "$u" "$ld"; then av="$P5_VAL"; else why="$why $u(运行态: $P5_WHY)"; fi; ar="$P5_RC"
      if p5_uq enabled "$u"; then ev="$P5_VAL"; else why="$why $u(自启态: $P5_WHY)"; fi; er="$P5_RC"
      p5_show MainPID "$u" && pid="$P5_VAL"
      p5_show InvocationID "$u" && inv="$P5_VAL"
      p5_show NRestarts "$u" && nr="$P5_VAL"
      printf 'R\t%s\tis-active rc=%s\tis-enabled rc=%s\n' "$u" "${ar:-?}" "${er:-?}"
      printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$av" "$ev" "$pid" "$inv" "$nr"
    done
    if p5_listen 7894 tcp; then printf 'L\t7894\t%s\n' "$P5_LN"; else printf 'L\t7894\tINVALID\n'; why="$why 7894"; fi
    if p5_listen 53 udp; then printf 'L\t53\t%s\n' "$P5_LN"; else printf 'L\t53\tINVALID\n'; why="$why 53"; fi
  } > "$f.tmp" 2>/dev/null; then P5_WHY="四维采样写不出来($f)"; return 2; fi
  n="$(wc -l < "$f.tmp")" || { P5_WHY="四维采样读不回来"; return 2; }
  { printf 'END\t%s\n' "$n" >> "$f.tmp" && mv -f -- "$f.tmp" "$f"; } 2>/dev/null || { P5_WHY="四维采样收尾写不出来"; return 2; }
  chmod 600 "$f" 2>/dev/null
  P5_FPN["$tag"]="$nonce"
  fp_get "$tag" H "$tag" >/dev/null || { P5_WHY="四维采样读回不通过(头行 / 本次 nonce / END 条数)"; return 2; }
  [[ -z "$why" ]] || { P5_WHY="有观测无效:$why"; return 2; }
  return 0
}
fp_get(){   # $1=标签 $2=类型 $3=键 → 0 恰一条且字段数与必要字段格式合规(打印其余字段) / 1 确认没有 / 2 读不了、不完整、不是本次采样、有重复或那一条残缺
  local f="$EVID/fp-$1.tsv" raw rc TAB out
  TAB="$(printf '\t')"
  raw="$(cat -- "$f" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return 2
  # 354: 除头尾、nonce、条数外, 再核被取那一条的字段数与必要字段格式(F 行 mode 是 1–4 位八进制; S 行实例标识可以是合法的空, 但列不能少)
  out="$(awk -F"$TAB" -v t="$2" -v k="$3" -v nonce="${P5_FPN[$1]:-}" -v tag="$1" '
    function num(x) { return x ~ /^[0-9]+$/ }
    function word(x) { return x ~ /^[a-z][a-z-]*$/ || x == "INVALID" }
    function okrow() {
      if (t == "H") return NF == 3
      if (t == "F") {
        if (NF != 7) return 0
        if ($3 == "有") return length($4) == 64 && $4 ~ /^[0-9a-f]+$/ && length($5) >= 1 && length($5) <= 4 && $5 ~ /^[0-7]+$/ && num($6) && num($7)
        return ($3 == "无" || $3 == "INVALID") && $4 == "-" && $5 == "-" && $6 == "-" && $7 == "-" }
      if (t == "S") return NF == 7 && word($3) && word($4) && ($5 == "" || num($5) || $5 == "INVALID") && ($7 == "" || num($7) || $7 == "INVALID")
      if (t == "R") return NF == 4 && $3 ~ /^is-active rc=/ && $4 ~ /^is-enabled rc=/
      if (t == "L") return NF == 3 && (num($3) || $3 == "INVALID")
      return 0 }
    NR==1 { if ($1!="H" || $2!=tag || nonce=="" || $3!=nonce) bad=1 }
    $1=="END" { endn++; endcnt=$2; endat=NR }
    $1==t && $2==k { hits++; if (!okrow()) broken=1; out=$3; for (i=4; i<=NF; i++) out=out FS $i }
    END { if (bad || endn!=1 || endat!=NR || endcnt+0 != NR-1) exit 2
          if (hits==0) exit 1
          if (hits>1 || broken) exit 2
          print out; exit 0 }' <<<"$raw")"; rc=$?
  (( rc == 0 )) || return "$(( rc == 1 ? 1 : 2 ))"
  printf '%s\n' "$out"
}
fp_cmp_files(){   # $1=前 $2=后 $3=标签 —— 文件维: 两边都有效 ⇒ 相同 = 已恢复 / 不同 = 未恢复; 任一边无效或缺记录 ⇒ 未取得
  local q b a rb ra n_ok=0 n_diff=0 n_na=0
  for q in "${FP_FILES[@]}"; do
    b="$(fp_get "$1" F "$q")"; rb=$?; a="$(fp_get "$2" F "$q")"; ra=$?
    if (( rb != 0 || ra != 0 )) || [[ "$b" == INVALID* || "$a" == INVALID* ]]; then
      n_na=$((n_na+1)); p5_tally na "文件 $q"
      printf '    %-58s 未取得(前 rc=%s [%s] / 后 rc=%s [%s])\n' "$q" "$rb" "${b:-无}" "$ra" "${a:-无}"; continue
    fi
    if [[ "$b" == "$a" ]]; then n_ok=$((n_ok+1)); p5_tally ok "文件 $q"; continue; fi
    n_diff=$((n_diff+1)); p5_tally diff "文件 $q"
    printf '    %-58s\n      前: %s\n      后: %s\n' "$q" "$b" "$a"
  done
  if (( n_diff == 0 && n_na == 0 )); then
    ok "$3: ${#FP_FILES[@]} 个受关注文件的**存在性/内容/mode/uid/gid** 四项全部回到前像"; return 0
  fi
  (( n_diff == 0 )) || bad "$3: 有 $n_diff 个文件没回到前像(上面逐项列出), 一致 $n_ok"
  (( n_na == 0 )) || bad "$3: 有 $n_na 个文件前后读取无效或缺记录 —— 未取得(不算恢复, 也不算未恢复)"
  return 1
}
p5_cmp3(){   # $1 $2=前后读取码 $3 $4=前后值 $5=结果键 $6=标签
  if [[ "$1" != 0 || "$2" != 0 || -z "$3" || -z "$4" || "$3" == INVALID || "$4" == INVALID ]]; then
    p5_tally na "$5"; bad "$6 未取得(前 [${3:-无}] rc=$1 / 后 [${4:-无}] rc=$2)"; return 2
  fi
  if [[ "$3" == "$4" ]]; then p5_tally ok "$5"; ok "$6 回到前像($4)"; return 0; fi
  p5_tally diff "$5"; bad "$6 前像=$3 现在=$4"; return 1
}
p5_cut(){   # 354: $1=一行(制表符分隔) $2=字段号 → 0 取得(P5_VAL, 可为空) / 2 提取失败(退出非零或多行; 输出不采信)
  local out rc; P5_VAL=""
  out="$(cut -f"$2" <<<"$1")"; rc=$?
  { (( rc == 0 )) && [[ "$out" != *$'\n'* ]]; } || return 2
  P5_VAL="$out"
}
p5_count(){   # 354: $1=基本正则 $2=文本 → 0 取得(P5_VAL = 匹配行数; 0 是有效的"没有") / 2 查询出错(退出码 ≥ 2 或输出不是数字; 输出不采信)
  local out rc; P5_VAL=""
  out="$(grep -c -- "$1" <<<"$2")"; rc=$?
  { (( rc <= 1 )) && [[ "$out" =~ ^[0-9]+$ ]]; } || return 2
  P5_VAL="$out"
}
p5_fp_svc(){   # $1=前 $2=后 $3=标签 → FP_SVCS 每个 unit 的运行态 / 自启态逐项三态
  local u b a rb ra ba bn aa an
  for u in "${FP_SVCS[@]}"; do
    b="$(fp_get "$1" S "$u")"; rb=$?; a="$(fp_get "$2" S "$u")"; ra=$?
    # 354: 字段提取核自己的退出码(不沿用 fp_get 的); 取不到的一侧按读取无效算
    ba=""; bn=""; aa=""; an=""
    if (( rb == 0 )); then { p5_cut "$b" 1 && ba="$P5_VAL" && p5_cut "$b" 2 && bn="$P5_VAL"; } || rb=2; fi
    if (( ra == 0 )); then { p5_cut "$a" 1 && aa="$P5_VAL" && p5_cut "$a" 2 && an="$P5_VAL"; } || ra=2; fi
    p5_cmp3 "$rb" "$ra" "$ba" "$aa" "运行态 $u" "$3 运行态: $u"
    p5_cmp3 "$rb" "$ra" "$bn" "$an" "自启态 $u" "$3 自启态: $u"
  done
}

# ── A5 / A7: 服务快照(每个观察 unit 一行, 无效字段标 INVALID, 末尾 END)────────────────────────
p5_svc_snap(){   # $1=落点 → 0 全部有效 / 2 有无效(照样写出)
  local u ld av ev sub pid inv nr why="" n
  if ! {
    for u in "${SVC_WATCH[@]}"; do
      ld=INVALID; av=INVALID; ev=INVALID; sub=INVALID; pid=INVALID; inv=INVALID; nr=INVALID
      if p5_uq load "$u"; then ld="$P5_VAL"; else why="$why $u(LoadState)"; fi
      if p5_uq active "$u" "$ld"; then av="$P5_VAL"; else why="$why $u(运行态)"; fi
      if p5_uq enabled "$u"; then ev="$P5_VAL"; else why="$why $u(自启态)"; fi
      if p5_show SubState "$u"; then sub="$P5_VAL"; else why="$why $u(SubState)"; fi
      if p5_show MainPID "$u"; then pid="$P5_VAL"; else why="$why $u(MainPID)"; fi
      if p5_show InvocationID "$u"; then inv="$P5_VAL"; else why="$why $u(InvocationID)"; fi
      if p5_show NRestarts "$u"; then nr="$P5_VAL"; else why="$why $u(NRestarts)"; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$ld" "$av" "$ev" "$sub" "$pid" "$inv" "$nr"
    done
  } > "$1.tmp" 2>/dev/null; then P5_WHY="服务快照写不出来"; return 2; fi
  n="$(wc -l < "$1.tmp")" || { P5_WHY="服务快照读不回来"; return 2; }
  { printf 'END\t%s\n' "$n" >> "$1.tmp" && mv -f -- "$1.tmp" "$1"; } 2>/dev/null || { P5_WHY="服务快照收尾写不出来"; return 2; }
  chmod 600 "$1" 2>/dev/null
  [[ -z "$why" ]] || { P5_WHY="有观测无效:$why"; return 2; }
}
p5_svc_get(){   # $1=快照 $2=unit → 0 恰一行、8 列且各列格式合规(P5_ROW) / 2 读不了、不完整、行数不对、残缺或提取失败
  local raw out rc; P5_ROW=""
  raw="$(cat -- "$1" 2>/dev/null)" || return 2
  # 354: 一次核完结构(END 条数与位置、该 unit 恰一行、8 列、状态词 / 数字格式), 提取核自己的退出码
  out="$(awk -F'\t' -v u="$2" '
      function word(x) { return x ~ /^[a-z][a-z-]*$/ || x == "INVALID" }
      $1=="END" { endn++; endcnt=$2; endat=NR; next }
      $1==u { hits++; row=$0
              if (NF != 8 || !word($2) || !word($3) || !word($4) || ($5 != "" && !word($5)) || ($6 != "" && $6 !~ /^[0-9]+$/ && $6 != "INVALID") || ($8 != "" && $8 !~ /^[0-9]+$/ && $8 != "INVALID")) broken=1 }
      END { if (endn != 1 || endat != NR || endcnt+0 != NR-1 || hits != 1 || broken) exit 2; print row }' <<<"$raw")"; rc=$?
  { (( rc == 0 )) && [[ -n "$out" ]]; } || return 2
  P5_ROW="$out"
}
p5_win_starts(){   # $1=unit → 0 取得(P5_VAL = 产品调用窗口 (C_PROD0, C_PROD1] 内的 Started 条数) / 2 未取得
  local n; P5_VAL=""; P5_WHY=""
  { [[ -n "${C_PROD0:-}" ]] && [[ -n "${C_PROD1:-}" ]]; } || { P5_WHY="产品调用窗口的界桩缺失"; return 2; }
  n="$(_j_interval "$1" "$C_PROD0" "$C_PROD1")" || { P5_WHY="窗口计数无效: $(_j_why)"; return 2; }
  [[ "$n" =~ ^[0-9]+$ ]] || { P5_WHY="窗口计数不是数字"; return 2; }
  P5_VAL="$n"
}
p5_svc_settle(){   # $1=调用前快照 $2=调用后快照 $3=标签 → 0 窗口记录都在依据之内且全部取得 / 1 有超出依据 / 2 有未取得
  local u x allowed b a bterm aterm binv ainv inst n cls n_over=0 n_na=0 b3 b4 a3 a4
  for u in "${SVC_WATCH[@]}"; do
    allowed=0; for x in "${P5_START_OK[@]}"; do [[ "$x" == "$u" ]] && allowed=1; done
    [[ "$u" == pdg-mitm && "$DIR" == a2i ]] && allowed=1
    b=""; a=""
    p5_svc_get "$1" "$u" && b="$P5_ROW"
    p5_svc_get "$2" "$u" && a="$P5_ROW"
    # 354: 每一列的提取都核退出码; 终态(运行 / 自启)读不到的 unit 单独记未取得, 不被实例与窗口的正常结果盖掉
    bterm=未取得; aterm=未取得
    if [[ -n "$b" && -n "$a" ]] && p5_cut "$b" 3 && b3="$P5_VAL" && p5_cut "$b" 4 && b4="$P5_VAL" \
       && p5_cut "$a" 3 && a3="$P5_VAL" && p5_cut "$a" 4 && a4="$P5_VAL" \
       && [[ "$b3" != INVALID && "$b4" != INVALID && "$a3" != INVALID && "$a4" != INVALID ]]; then
      bterm="$b3/$b4"; aterm="$a3/$a4"
    fi
    inst=未取得
    if [[ -n "$b" && -n "$a" ]] && p5_cut "$b" 7 && binv="$P5_VAL" && p5_cut "$a" 7 && ainv="$P5_VAL" \
       && [[ "$binv" != INVALID && "$ainv" != INVALID ]]; then
      if [[ -z "$binv" && -z "$ainv" ]]; then inst=前后都没有
      elif [[ "$binv" == "$ainv" ]]; then inst=未换
      elif [[ -z "$binv" ]]; then inst=出现
      elif [[ -z "$ainv" ]]; then inst=消失
      else inst=换了; fi
    fi
    if p5_win_starts "$u"; then n="$P5_VAL"; else n=""; fi
    if [[ -z "$n" ]]; then cls="未取得(窗口: $P5_WHY)"; n_na=$((n_na+1))
    elif (( n > 0 )) && (( ! allowed )); then cls="超出依据(窗口内 $n 次启动)"; n_over=$((n_over+1))
    elif [[ "$inst" == 未取得 ]]; then cls="未取得(实例标识读不到)"; n_na=$((n_na+1))
    elif [[ "$inst" == 换了 || "$inst" == 出现 ]] && (( n == 0 )); then cls="未取得(实例$inst 却没有启动记录)"; n_na=$((n_na+1))
    elif [[ "$inst" == 消失 && "$u" != pdg-mitm ]]; then cls="未取得(实例标识消失, 没有依据)"; n_na=$((n_na+1))
    elif [[ "$bterm" == 未取得 ]]; then cls="未取得(终态读不到)"; n_na=$((n_na+1))
    else cls="符合依据"; fi
    printf '    %-20s 终态 %s → %s   实例 %s   窗口内启动 %s   %s\n' "$u" "$bterm" "$aterm" "$inst" "${n:-未取得}" "$cls"
  done
  _evn "07-service-actions-$3.txt" "超出依据=$n_over 未取得=$n_na(依据: 353 basis/A7-basis.tsv)"
  (( n_over == 0 )) || bad "$3: 有 $n_over 个 unit 在调用窗口内出现了依据之外的启动"
  (( n_na == 0 )) || bad "$3: 有 $n_na 个 unit 的终态、实例对照或窗口记录未取得 —— 不给总体通过"
  if (( n_over == 0 && n_na == 0 )); then
    ok "$3: 调用窗口内记录到的启动都在依据之内(${#SVC_WATCH[@]} 个 unit 逐项见上; 只覆盖 journal 记到的启动, 不宣称全程没有别的服务动作)"; return 0
  fi
  (( n_over == 0 )) || return 1
  return 2
}
p5_quiet_unit(){   # $1=unit $2=标签 $3=前像自启(可空) → 终态与调用窗口内的启动记录分开判
  local u="$1" lbl="$2" ld ac en n
  if p5_uq load "$u" && ld="$P5_VAL" && p5_uq active "$u" "$ld" && ac="$P5_VAL" && p5_uq enabled "$u" && en="$P5_VAL"; then
    if [[ "$ac" != active && "$ac" != activating && "$en" != enabled ]]; then
      p5_tally ok "$u 终态停用"; ok "$lbl: 终态仍是停用(运行=$ac 自启=$en; 前像自启=${3:-未单列})"
    else p5_tally diff "$u 终态停用"; bad "$lbl: 终态被改了(运行=$ac 自启=$en)"; fi
  else p5_tally na "$u 终态停用"; bad "$lbl: 终态读数无效 —— 未取得($P5_WHY)"; fi
  if p5_win_starts "$u"; then
    n="$P5_VAL"
    if (( n == 0 )); then ok "$lbl: 调用窗口内没有它的启动记录(界桩裁决; 只说明窗口内 journal 没记到启动)"
    else bad "$lbl: 调用窗口内有 $n 次启动记录 —— 被拉起过(终态相同也不能写成没动过)"; fi
  else bad "$lbl: 调用窗口内的启动记录未取得 —— $P5_WHY"; fi
}

# ── A5: 本次快照绑定与产品前像的独立核对 ──────────────────────────────────────
p5_presample(){   # $1=落点 → 调用前对 8 个 unit 独立采样(自启态与运行态) → 0 全部有效 / 2 有无效
  local u ld ev av why=""
  if ! {
    for u in "${P5_SVC8[@]}"; do
      ev=INVALID; av=INVALID
      if p5_uq load "$u"; then ld="$P5_VAL"
        if p5_uq enabled "$u"; then ev="$P5_VAL"; else why="$why $u(自启)"; fi
        if p5_uq active "$u" "$ld"; then av="$P5_VAL"; else why="$why $u(运行)"; fi
      else why="$why $u(LoadState)"; fi
      printf '%s\t%s\t%s\n' "$u" "$ev" "$av"
    done
  } > "$1" 2>/dev/null; then P5_WHY="独立采样写不出来"; return 2; fi
  [[ -z "$why" ]] || { P5_WHY="独立采样有无效读取:$why"; return 2; }
}
p5_snap_list(){   # $1=落点 → 0 取得(首行 ABSENT = 目录不存在 / PRESENT = 存在, 其后逐条「名<TAB>类型」; 空目录也有首行) / 2 取不到
  P5_WHY=""
  if [[ ! -e "$P5_SNAPDIR" && ! -L "$P5_SNAPDIR" ]]; then
    printf 'ABSENT\n' > "$1" 2>/dev/null || { P5_WHY="清单落点写不出来"; return 2; }
    return 0
  fi
  { [[ -d "$P5_SNAPDIR" ]] && [[ ! -L "$P5_SNAPDIR" ]]; } || { P5_WHY="$P5_SNAPDIR 不是普通目录"; return 2; }
  { printf 'PRESENT\n' && find "$P5_SNAPDIR" -mindepth 1 -maxdepth 1 -printf '%f\t%y\n'; } > "$1" 2>/dev/null || { P5_WHY="列 $P5_SNAPDIR 失败"; return 2; }
}
P5_SNAP=""; P5_BIND_DONE=""
p5_snap_bind(){   # $1=调用前清单 $2=去掉颜色的产品输出 → 0 绑定成立(P5_SNAP) / 2 未取得(P5_WHY; 已核的步骤在 P5_BIND_DONE)
  local after new n nm rb rs ref dd raw hdr sd sid bid cur got want cnt dig units last lst d2 drc rc
  P5_SNAP=""; P5_WHY=""; P5_BIND_DONE=""
  after="${E2E_TMP:?}/p5-snap-after.txt"
  { [[ -s "$1" ]] && read -r hdr < "$1" && [[ "$hdr" == PRESENT || "$hdr" == ABSENT ]]; } 2>/dev/null \
    || { P5_WHY="调用前的快照目录清单缺失或没有首行"; return 2; }
  p5_snap_list "$after" || return 2
  new="$(awk -F'\t' 'NR==FNR { if (FNR > 1) seen[$1]=1; next } FNR > 1 && !($1 in seen) { print $1 "\t" $2 }' "$1" "$after")" \
    || { P5_WHY="调用前后清单比较失败"; return 2; }
  # 354: 下面每一步的计数 / 提取 / 摘要 / 排序先核执行有效再用内容; grep 的"没匹配"(退出 1)是合法的 0, 退出 ≥ 2 才是查询出错
  p5_count . "$new" || { P5_WHY="新出现条目的计数查询失败(输出不采信)"; return 2; }
  n="$P5_VAL"
  [[ "$n" == 1 ]] || { P5_WHY="调用前后新出现的快照目录不是恰好一个(实得 $n)"; return 2; }
  p5_cut "$new" 2 || { P5_WHY="新出现条目的类型提取失败"; return 2; }
  [[ "$P5_VAL" == d ]] || { P5_WHY="新出现的条目不是目录"; return 2; }
  { p5_cut "$new" 1 && [[ -n "$P5_VAL" ]]; } || { P5_WHY="新出现条目的名字提取失败"; return 2; }
  nm="$P5_VAL"; dd="$P5_SNAPDIR/$nm"; P5_BIND_DONE="新目录唯一($nm)"
  p5_count '^回滚到 .* …$' "$2" || { P5_WHY="产品输出里'回滚到'行的计数查询失败(输出不采信)"; return 2; }
  rb="$P5_VAL"
  p5_count '^ *本次快照    : ' "$2" || { P5_WHY="产品输出里'本次快照'行的计数查询失败(输出不采信)"; return 2; }
  rs="$P5_VAL"
  { (( rb <= 1 )) && (( rs <= 1 )) && (( rb + rs >= 1 )); } \
    || { P5_WHY="产品输出里指向快照的行数不对(回滚到 $rb 行 / 本次快照 $rs 行)"; return 2; }
  if (( rb == 1 )); then ref="$(sed -n 's/^回滚到 \(.*\) …$/\1/p' <<<"$2")" || { P5_WHY="'回滚到'行的快照名提取失败"; return 2; }
    [[ "$ref" == "$nm" ]] || { P5_WHY="产品输出的快照名 [$ref] 与新目录 [$nm] 不符"; return 2; }; fi
  if (( rs == 1 )); then ref="$(sed -n 's/^ *本次快照    : //p' <<<"$2")" || { P5_WHY="'本次快照'行的路径提取失败"; return 2; }
    [[ "${ref%/}" == "$dd" ]] || { P5_WHY="产品输出的快照路径 [$ref] 与新目录 [$dd] 不符"; return 2; }; fi
  P5_BIND_DONE="$P5_BIND_DONE, 与产品输出同名"
  { [[ -d "$dd" ]] && [[ ! -L "$dd" ]] && [[ -f "$dd/snap.tar.gz" ]] && [[ -f "$dd/svcstate.tsv" ]]; } \
    || { P5_WHY="$dd 不是含 snap.tar.gz 与 svcstate.tsv 的普通目录"; return 2; }
  raw="$(cat -- "$dd/svcstate.tsv" 2>/dev/null)" || { P5_WHY="svcstate.tsv 读不了"; return 2; }
  [[ "${raw%%$'\n'*}" == "#pdg-svcstate"$'\t'"1" ]] || { P5_WHY="svcstate.tsv 的头行不对"; return 2; }
  hdr="$(awk -F'\t' '$1=="snap_dir" || $1=="snap_id" || $1=="boot_id" { c[$1]++; v[$1]=$2 }
         END { if (c["snap_dir"]!=1 || c["snap_id"]!=1 || c["boot_id"]!=1) exit 3; printf "%s\t%s\t%s\n", v["snap_dir"], v["snap_id"], v["boot_id"] }' <<<"$raw")" \
    || { P5_WHY="svcstate 的 snap_dir / snap_id / boot_id 缺失或重复"; return 2; }
  { p5_cut "$hdr" 1 && sd="$P5_VAL" && p5_cut "$hdr" 2 && sid="$P5_VAL" && p5_cut "$hdr" 3 && bid="$P5_VAL"; } \
    || { P5_WHY="svcstate 头部三个字段的提取失败"; return 2; }
  [[ "${sd%/}" == "${dd%/}" ]] || { P5_WHY="svcstate 的 snap_dir [$sd] 不是这个目录"; return 2; }
  cur="$(stat -c '%d:%i:%s:%Y' -- "$dd/snap.tar.gz" 2>/dev/null)" && [[ -n "$cur" ]] || { P5_WHY="snap.tar.gz 的身份读不了"; return 2; }
  [[ "$sid" == "$cur" ]] || { P5_WHY="svcstate 的 snap_id [$sid] 与这份 snap.tar.gz [$cur] 不符"; return 2; }
  got="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" && [[ -n "$got" ]] || { P5_WHY="本机 boot_id 读不了"; return 2; }
  [[ "$bid" == "$got" ]] || { P5_WHY="svcstate 的 boot_id 不是本次开机"; return 2; }
  P5_BIND_DONE="$P5_BIND_DONE, snap_dir / snap_id / boot_id"
  awk -F'\t' '$1=="end" { n++; ln=NR } END { exit (n==1 && ln==NR) ? 0 : 3 }' <<<"$raw" \
    || { P5_WHY="end 行不是恰好一行且在末尾"; return 2; }
  last="${raw##*$'\n'}"
  { p5_cut "$last" 2 && cnt="$P5_VAL" && p5_cut "$last" 3 && dig="$P5_VAL"; } || { P5_WHY="end 行的条数 / 摘要提取失败"; return 2; }
  { units="$(awk -F'\t' '$1=="unit" {n++} END{print n+0}' <<<"$raw")" && [[ "$units" =~ ^[0-9]+$ ]]; } || { P5_WHY="unit 行计数失败"; return 2; }
  [[ "$cnt" == "$units" ]] || { P5_WHY="end 行记 $cnt 条, 实有 unit 行 $units 条"; return 2; }
  d2="$(printf '%s\n' "${raw%$'\n'*}" | sha256sum)"; drc=$?
  { (( drc == 0 )) && (( ${#d2} >= 64 )) && [[ "${d2:0:64}" =~ ^[0-9a-f]+$ ]]; } || { P5_WHY="正文摘要计算失败(rc=$drc, 输出不采信)"; return 2; }
  [[ "${d2:0:64}" == "$dig" ]] || { P5_WHY="end 行的正文摘要与正文对不上"; return 2; }
  P5_BIND_DONE="$P5_BIND_DONE, end 条数与正文摘要"
  lst="$(awk -F'\t' '$1=="unit" { if (NF != 8) bad=1; print $2 } END { exit bad ? 3 : 0 }' <<<"$raw")"; rc=$?
  (( rc != 3 )) || { P5_WHY="有 unit 行字段数不对"; return 2; }
  (( rc == 0 )) || { P5_WHY="unit 名的提取失败(rc=$rc)"; return 2; }
  got="$(LC_ALL=C sort <<<"$lst")" || { P5_WHY="unit 名的排序失败"; return 2; }
  want="$(printf '%s\n' "${P5_SVC8[@]}" | LC_ALL=C sort)" || { P5_WHY="候选 unit 集合的排序失败"; return 2; }
  [[ "$got" == "$want" ]] || { P5_WHY="svcstate 的 unit 集合不是候选那 8 个(缺、多或重复)"; return 2; }
  P5_BIND_DONE="$P5_BIND_DONE, 8 个 unit 完整且唯一"
  P5_SNAP="$dd"
}

# ── A6: 产品自报的解析与报告诚实性 ────────────────────────────────────────────
P5_CLAIM=""; P5_RESTAT=""; P5_LEFTBAD=""; P5_LEFTN=0; P5_LEFTQ=""; P5_WHYQ=""; P5_PLXQ=""
p5_report_parse(){   # $1=去掉颜色的产品输出 → P5_CLAIM(complete / incomplete / none / both / unknown = 查询失败)、P5_RESTAT、P5_MAT[newfiles|localbak|snap]、未删文件核对
  local t="$1" nc="" ni="" cnt i path lst r qf=""
  local -a keys=(newfiles localbak snap) pfx=('新增文件清单: ' '局部备份    : ' '本次快照    : ')
  P5_WHYQ=""
  # 354: 每一次查询先核执行有效; grep 的"没匹配"是合法的 0, 查询出错不当成 0、缺失或空清单
  if p5_count '已按本次快照恢复到切换前' "$t"; then nc="$P5_VAL"; else qf="$qf 完成"; fi
  if p5_count '恢复未完成' "$t"; then ni="$P5_VAL"; else qf="$qf 未完成"; fi
  if [[ -n "$qf" ]]; then P5_CLAIM=unknown; P5_WHYQ="自报的计数查询失败:$qf"
  elif (( nc >= 1 && ni >= 1 )) || (( nc > 1 || ni > 1 )); then P5_CLAIM=both
  elif (( nc == 1 )); then P5_CLAIM=complete
  elif (( ni == 1 )); then P5_CLAIM=incomplete
  else P5_CLAIM=none; fi
  if ! p5_count '快照恢复: ' "$t"; then P5_RESTAT=未取得
  else
    cnt="$P5_VAL"
    if (( cnt == 1 )); then
      grep -q '快照恢复: 已完成' <<<"$t"; r=$?
      if (( r == 0 )); then P5_RESTAT=已完成
      elif (( r == 1 )); then
        grep -q '快照恢复: \*\*未完成\*\*' <<<"$t"; r=$?
        if (( r == 0 )); then P5_RESTAT=未完成; elif (( r == 1 )); then P5_RESTAT=认不出; else P5_RESTAT=未取得; fi
      else P5_RESTAT=未取得; fi
    elif (( cnt > 1 )); then P5_RESTAT=重复; else P5_RESTAT=缺失; fi
  fi
  P5_MAT=()
  for i in 0 1 2; do
    if ! p5_count "^ *${pfx[$i]}" "$t"; then P5_MAT[${keys[$i]}]="未取得(查询失败)"; continue; fi
    cnt="$P5_VAL"
    if (( cnt == 0 )); then P5_MAT[${keys[$i]}]=缺失
    elif (( cnt > 1 )); then P5_MAT[${keys[$i]}]=多处
    elif ! path="$(sed -n "s/^ *${pfx[$i]}//p" <<<"$t")"; then P5_MAT[${keys[$i]}]="未取得(路径提取失败)"
    elif [[ -e "$path" || -L "$path" ]]; then P5_MAT[${keys[$i]}]="在盘上 $path"
    else P5_MAT[${keys[$i]}]="不在盘上 $path"; fi
  done
  P5_LEFTBAD=""; P5_LEFTN=0; P5_LEFTQ=ok
  if ! lst="$(awk '/本次新增、\*\*没能删掉\*\*的文件/ {f=1; next} f && /^     [^ ]/ {sub(/^     /, ""); print; next} f {f=0}' <<<"$t")"; then P5_LEFTQ=未取得; lst=""; fi
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    P5_LEFTN=$((P5_LEFTN+1))
    [[ -e "$path" || -L "$path" ]] || P5_LEFTBAD="$P5_LEFTBAD $path"
  done <<<"$lst"
}
p5_honesty(){   # 报告诚实性, 与恢复结果分开结算(352 settlement-A5-A6 的 A6): 互不抵消
  local k n_ok=0 n_diff=0 n_na=0 matbad=0 matna="" diffs="" nas=""
  for k in "${!P5_RES[@]}"; do
    case "${P5_RES[$k]}" in
      ok) n_ok=$((n_ok+1));;
      diff) n_diff=$((n_diff+1)); diffs="$diffs [$k]";;
      *) n_na=$((n_na+1)); nas="$nas [$k]";;
    esac
  done
  note "恢复结果(已检查范围): 已恢复 $n_ok / 未恢复 $n_diff / 未取得 $n_na${diffs:+; 未恢复:$diffs}${nas:+; 未取得:$nas}"
  case "$P5_CLAIM" in
    unknown) bad "报告诚实性: 未取得 —— ${P5_WHYQ:-自报的查询失败}(不当成没有自报, 也不据此判报告不实)"; return 2;;
    none) bad "报告诚实性: 产品既没报恢复完成也没报恢复未完成 —— 没有自报"; return 1;;
    both) bad "报告诚实性: 产品的自报自相矛盾(完成与未完成同时出现或重复)"; return 1;;
    complete)
      if (( n_diff > 0 )); then bad "报告诚实性: 自报恢复完成, 现场有 $n_diff 项未恢复 —— 报告与现场不符"; return 1; fi
      if (( n_na > 0 )); then bad "报告诚实性: 未取得 —— 自报恢复完成, 已核部分一致, 但有 $n_na 项观测无效(不背书)"; return 2; fi
      ok "报告诚实性: 自报恢复完成, 与已检查范围($n_ok 项)一致"; return 0;;
    incomplete) ;;
    *) bad "报告诚实性: 产品自报没有解析出来($P5_CLAIM)"; return 1;;
  esac
  note "报告诚实性: 自报恢复未完成; 报告点名没能删掉的文件 $P5_LEFTN 个"
  # 354: 报告自己的材料有缺失 / 矛盾(matbad)与"材料的查询失败"(matna)分开; 后者记未取得, 不冒充报告缺材料
  for k in newfiles localbak snap; do
    case "${P5_MAT[$k]:-缺失}" in
      在盘上*) ;;
      未取得*) note "报告诚实性: 材料路径 $k: ${P5_MAT[$k]}"; matna="$matna 材料路径 $k";;
      *) bad "报告诚实性: 材料路径 $k: ${P5_MAT[$k]:-缺失}"; matbad=1;;
    esac
  done
  case "$P5_RESTAT" in 已完成|未完成) ;; 未取得) matna="$matna '快照恢复'那一行";; *) bad "报告诚实性: '快照恢复: …'那一行 $P5_RESTAT"; matbad=1;; esac
  [[ "$P5_LEFTQ" == ok ]] || matna="$matna 没能删掉的文件清单"
  [[ -z "$P5_LEFTBAD" ]] || { bad "报告诚实性: 报告说没能删掉、却不在盘上的文件:$P5_LEFTBAD"; matbad=1; }
  if (( n_diff > 0 )); then
    if (( matbad )); then bad "报告诚实性: 自报恢复未完成, 但报告自身的收尾材料有缺失 / 矛盾 / 读不了(上面逐项)"; return 1; fi
    if [[ -n "$matna" ]]; then bad "报告诚实性: 未取得 —— 自报恢复未完成, 但这些报告材料的查询失败:$matna(不据此判报告不实, 也不背书)"; return 2; fi
    ok "报告诚实性: 自报恢复未完成, 与现场 $n_diff 项真实未恢复一致(只核总述与材料; 报告里点名的内容没有逐项核对, 不背书)"; return 0
  fi
  if (( n_na > 0 )); then bad "报告诚实性: 未取得 —— 自报恢复未完成, 现场没有核实的未恢复项, 只有 $n_na 项观测无效(不据此背书)"; return 2; fi
  bad "报告诚实性: 自报恢复未完成而已检查范围全部已恢复 —— 单列(不是产品失败的证据, 但本项不能给通过)"; return 2
}

# ── A5(a): 产品记录的操作前像 vs 调用前的独立采样 ──────────────────────────────
svcstate_cross_check(){   # $1=已绑定的 svcstate.tsv $2=调用前独立采样 $3=标签 → 0 一致 / 1 有不一致 / 2 未取得
  local raw praw u pen pac men mac n_ok=0 n_bad=0 n_na=0
  raw="$(cat -- "$1" 2>/dev/null)" || { bad "$3: 产品前像读不了 —— 未取得"; return 2; }
  praw="$(cat -- "$2" 2>/dev/null)" || { bad "$3: 调用前的独立采样读不了 —— 未取得"; return 2; }
  for u in "${P5_SVC8[@]}"; do
    # 354: 四个字段的提取各核退出码且只许恰好一行; 提取失败不能当"一致"
    if ! pen="$(awk -F'\t' -v u="$u" '$1=="unit" && $2==u {print $3}' <<<"$raw")" || ! pac="$(awk -F'\t' -v u="$u" '$1=="unit" && $2==u {print $5}' <<<"$raw")" \
       || [[ "$pen" == *$'\n'* || "$pac" == *$'\n'* ]]; then
      n_na=$((n_na+1)); printf '    %-24s 产品前像字段提取失败\n' "$u"; continue; fi
    if ! men="$(awk -F'\t' -v u="$u" '$1==u {print $2}' <<<"$praw")" || ! mac="$(awk -F'\t' -v u="$u" '$1==u {print $3}' <<<"$praw")" \
       || [[ "$men" == *$'\n'* || "$mac" == *$'\n'* ]]; then
      n_na=$((n_na+1)); printf '    %-24s 调用前独立采样字段提取失败\n' "$u"; continue; fi
    if [[ -z "$men" || -z "$mac" || "$men" == INVALID || "$mac" == INVALID ]]; then
      n_na=$((n_na+1)); printf '    %-24s 调用前独立采样无效\n' "$u"; continue; fi
    if [[ -z "$pen" || -z "$pac" || "$pen" == QUERY-FAILED || "$pac" == QUERY-FAILED ]]; then
      n_na=$((n_na+1)); printf '    %-24s 产品记的是观测失败或缺项(%s / %s)\n' "$u" "${pen:-无}" "${pac:-无}"; continue; fi
    if [[ "$pen" == "$men" && "$pac" == "$mac" ]]; then n_ok=$((n_ok+1)); continue; fi
    n_bad=$((n_bad+1)); printf '    %-24s 产品记: %s/%s   调用前独立采样: %s/%s\n' "$u" "$pen" "$pac" "$men" "$mac"
  done
  (( n_bad == 0 )) || { bad "$3: 产品记录的操作前像与调用前独立采样有 $n_bad 项不一致(上面逐项)"; return 1; }
  (( n_na == 0 )) || { bad "$3: 有 $n_na 项未取得 —— 产品前像的独立核对不成立"; return 2; }
  ok "$3: 产品记录的操作前像与调用前独立采样逐项一致(${#P5_SVC8[@]} 个 unit; 比的是调用前, 不是恢复后的现场)"
}
# ── p5段 公共函数 止 ──


DIR="${PDG_PLAT_DIR:-a2i}"        # a2i = Android→iOS, i2a = iOS→Android
case "$DIR" in a2i) FROM=android; TO=ios;; i2a) FROM=ios; TO=android;; *) _hard "PDG_PLAT_DIR 只能是 a2i 或 i2a";; esac

# ═════════════════════════════════════════════════════════════════════════════
SECT "③ 场景 ⑤ —— 平台切换 $FROM → $TO: 退役件撤除之后失败, 看善后的真实服务结果"
# ═════════════════════════════════════════════════════════════════════════════
note "前像构造方式: 旧版(v1.11.15)自己的模块、unit 模板与渲染器 + 自造证书/配置, 再把"
note "  冻结退役候选**安装**上去。安装候选**只是测试前置**, 不代表「旧版经合法路径升到候选」。"
note "失败点: **可达的产品路径** —— 合法历史残留(有人手工往接管表里加过一个非 WLOC 域名)"
note "  会让 migrate_wloc_retire 按「归属不清就不能一把清空」合法拒绝。那一步排在平台组件"
note "  清理**之后**、切换提交**之前**。不是桩, 也没有替换任何清理/回滚/systemctl/nft/渲染。"

PH_T0="$(_now_j)"        # 仅供阅读
C_PREP0="$(_j_mark prep-start)" || note "阶段记账: 准备阶段起界桩没建成($(_j_why)) —— 该段记账将报观测无效"
build_preimage ios on || { bad "前像构造返回非 0 —— 前像不成立(353: 以前不看这个返回值, 照样往下走到调用)"; PREIMAGE_OK=0; }
# ── 合法历史残留: 每一项写明来源, 并在下面逐项记指纹 ────────────────────────
# ① 接管表里有一条**非 WLOC** 的域名(有人手工改过的痕迹)
STRAY_DOMAIN="full:legacy-hand-edited.example"
printf '%s\n' "$STRAY_DOMAIN" >> /etc/mosdns/rules/mitm_hijack.txt
# ② 这台机器当前的平台标记
printf '%s\n' "$FROM" > /etc/privdns-gateway/platform
rm -f /etc/privdns-gateway/platform.guessed
# ③ iOS→Android 方向: WLOC 关闭态。
#    为什么必须关: 候选的 migrate_android_cleanup 只在 `"enabled": true` 时把接管表整表截断,
#    截断之后那条手工历史条目就没了, migrate_wloc_retire 的归属拒绝(本方向的失败点)也就到不了。
#    **合法的关闭态长什么样, 按 v1.11.15 的原文推**:
#      · mitm_server.load_from_config 先算 _wloc_active(w) 再看 enabled —— 它要求
#        wloc.locations 是**列表**(里面是 {name,lat,lon})。上一轮这里写成了字典
#        {"osaka": [34.7,135.5]}, 于是旧版遍历到的是字符串键, 抛
#        AttributeError: 'str' object has no attribute 'get' ⇒ 进程起来就退, 被
#        Restart=on-failure 拉成崩溃循环(run 34966909411 的 ⑤b 现场, 重启计数到 10)。
#        那是**本测试写坏了配置**, 不是旧版在关闭态下站不住。
#      · 旧版真正的"关 WLOC"路径是 pdg-bot 的 _mitm_transact: 动作顺序固定 ——
#        关闭: 落盘 → stop:pdg-mitm → restart:mihomo → restart:mosdns。
#        所以合法的关闭态是 **pdg-mitm 停着(inactive)**、7894 没有监听, 而 unit 与模块
#        仍在盘上(待退役的残留), UnitFileState 仍是 enabled(stop 不等于 disable)。
#    下面就按这条真实路径建立, 不关 Restart、不忽略退出码、不清重启计数、不改旧版代码。
if [[ "$DIR" == i2a ]]; then
  cat > /etc/privdns-gateway/mitm.json <<'EOF'
{
  "wloc": {
    "enabled": false,
    "accuracy": 50,
    "locations": [ { "name": "osaka", "lat": 34.6937, "lon": 135.5023 } ]
  }
}
EOF
  chmod 600 /etc/privdns-gateway/mitm.json
  # 与 _mitm_transact 的关闭顺序一致(stop:pdg-mitm → restart:mihomo → restart:mosdns)
  systemctl stop pdg-mitm >/dev/null 2>&1 || true
  systemctl restart mihomo >/dev/null 2>&1 || true
  systemctl restart mosdns >/dev/null 2>&1 || true
else
  # a2i: WLOC 开着 —— 让盘上那份配置成为进程正在跑的那一份(开启顺序里就有 start:pdg-mitm)
  systemctl restart pdg-mitm >/dev/null 2>&1 || true
fi
# ④ 一个**本来就停着且不自启**的服务(全程不该被启动)
systemctl disable pdg-health.timer >/dev/null 2>&1 || true
systemctl stop    pdg-health.timer >/dev/null 2>&1 || true
# ⑤ 一个 **enabled-runtime** 的服务。选 pdg-probe81 —— 它是能稳定运行的真实受管服务;
#    pdg-bot 没有凭据, 本来就该是停用态, 不拿它凑 active, 也不造假凭据。
systemctl disable pdg-probe81 >/dev/null 2>&1 || true
systemctl enable --runtime pdg-probe81 >/dev/null 2>&1 || true
systemctl start pdg-probe81 >/dev/null 2>&1 || true
# ⑥ pdg-bot: 产品支持的停用态(没配凭据)
systemctl disable pdg-bot >/dev/null 2>&1 || true
systemctl stop    pdg-bot >/dev/null 2>&1 || true
# ── 前像先稳下来再采样 ──────────────────────────────────────────────────────
# ── p5段 前像判据 起 ──
for _u in pdg-mitm mosdns mihomo pdg-probe81 pdg-bot pdg-health.timer; do
  printf '    %-18s 稳定后 ActiveState=%s UnitFileState=%s\n' "$_u" "$(wait_stable "$_u")" \
    "$(systemctl show -p UnitFileState --value "$_u" 2>/dev/null)"
done
# 353: 上面那段只作展示。下面的判据: 自启态按「状态词 + 原始退出码」配对读取(合法非零照收, 查询失败不当成任何状态);
#      持续运行 / 停止经 ⑤ 的记账包装跑共享窗口(窗口里任何一次查询非零退出 ⇒ 观测无效, 后续成功不能清掉)。
if p5_uq enabled pdg-probe81 && [[ "$P5_VAL" == enabled-runtime ]]; then ok "前像: pdg-probe81 的自启是 enabled-runtime(真 systemd 实测, 读数有效)"
else bad "前像: pdg-probe81 自启读数无效或不是 enabled-runtime(${P5_WHY:-实得 $P5_VAL})"; PREIMAGE_OK=0; fi
# 运行/停止都在**有界窗口**里判(瞬时 active、崩溃循环、实例更替都过不去)
p5_stable_assert pdg-probe81    running "前像: pdg-probe81 持续运行" 5
if p5_uq enabled pdg-bot && [[ "$P5_VAL" != enabled ]]; then ok "前像: pdg-bot 的自启是产品支持的停用态($P5_VAL, 没配凭据; 读数有效)"
else bad "前像: pdg-bot 自启读数无效或是 enabled(${P5_WHY:-实得 $P5_VAL})"; PREIMAGE_OK=0; fi
p5_stable_assert pdg-bot        stopped "前像: pdg-bot 持续停止(没配凭据)" 5
p5_stable_assert pdg-health.timer stopped "前像: pdg-health.timer 持续停止(全程不该被启动)" 5
grep -q "$STRAY_DOMAIN" /etc/mosdns/rules/mitm_hijack.txt \
  && ok "前像: 接管表里有一条非 WLOC 的历史条目($STRAY_DOMAIN)" || { bad "前像: 残留条目没写进去"; PREIMAGE_OK=0; }
[[ -e /etc/systemd/system/pdg-mitm.service && -e /opt/pdg-bot/mitm_server.py && -e /opt/pdg-bot/mitm_wloc.py ]] \
  && ok "前像: 退役件(unit + 两个 MITM 模块)确实在盘上" || { bad "前像: 退役件不全"; PREIMAGE_OK=0; }
# ── 前像自洽核验: 盘上的配置与进程的实际行为必须对得上 ──────────────────────
# 不再硬性要求"WLOC 关着而旧监听还在"。判据是**一致性**: 盘上 wloc.enabled 说什么,
# 7894 上就该是什么。测出来是什么就记什么, 后面的恢复判据拿这个测量值作参照。
# ── 前像必须**持续稳定**, 而不是某一瞬 is-active=active ────────────────────
# 本方向的目标态由 v1.11.15 的原文决定(见上面那段推导):
#   a2i(WLOC 开): pdg-mitm 持续 active, 7894 有监听;
#   i2a(WLOC 关): 走完真实关闭路径后 pdg-mitm 持续 inactive, 7894 没有监听。
if [[ "$DIR" == i2a ]]; then MITM_WANT=stopped; else MITM_WANT=running; fi
p5_stable_assert pdg-mitm "$MITM_WANT" "前像: pdg-mitm 在有界窗口内持续 $MITM_WANT(不是瞬时取样)"
MITM_AC_BEFORE=""
if p5_uq load pdg-mitm && P5_LD="$P5_VAL" && p5_uq active pdg-mitm "$P5_LD"; then MITM_AC_BEFORE="$P5_VAL"
else bad "前像: pdg-mitm 运行态读数无效 —— $P5_WHY"; PREIMAGE_OK=0; fi
MITM_WLOC_ON="$(python3 -c 'import json,sys
try: print("1" if json.load(open("/etc/privdns-gateway/mitm.json",encoding="utf-8")).get("wloc",{}).get("enabled") else "0")
except Exception: print("?")' 2>/dev/null)"
# 旧版的形状自证: locations 必须是**列表**, 否则 mitm_server._wloc_active 会抛
# AttributeError 而崩溃循环 —— 上一轮 ⑤b 的现场就是这么来的。
MITM_LOC_SHAPE="$(python3 -c 'import json,sys
try:
    w=json.load(open("/etc/privdns-gateway/mitm.json",encoding="utf-8")).get("wloc",{})
    l=w.get("locations")
    print("list" if isinstance(l,list) else type(l).__name__)
except Exception: print("?")' 2>/dev/null)"
[[ "$MITM_LOC_SHAPE" == list ]] \
  && ok "前像: mitm.json 的 wloc.locations 是旧版解析得了的**列表**形状(不会把它拖进崩溃循环)" \
  || { bad "前像: wloc.locations 形状是 $MITM_LOC_SHAPE, 旧版 _wloc_active 会抛 AttributeError"; PREIMAGE_OK=0; }
# 353: 7894 的监听数分"确认没有(0)"与"观测无效"; ss 失败不再当成 0。
MITM_LISTEN_BEFORE=""
if p5_listen 7894 tcp; then MITM_LISTEN_BEFORE="$P5_LN"
else bad "前像: 7894 监听查询无效 —— $P5_WHY"; PREIMAGE_OK=0; fi
note "前像: 盘上 wloc.enabled=$MITM_WLOC_ON, pdg-mitm=${MITM_AC_BEFORE:-读不到}, 7894 监听数=${MITM_LISTEN_BEFORE:-读不到}, locations 形状=$MITM_LOC_SHAPE"
# 语义按旧版原文对: **监听跟着进程在不在**, enabled 决定的是有没有接管插件。
#   serve() 无条件 bind 7894 ⇒ 进程活着就该有监听, 停了就不该有。
if [[ -n "$MITM_AC_BEFORE" && -n "$MITM_LISTEN_BEFORE" ]]; then
mitm_listen_verdict "$MITM_AC_BEFORE" "$MITM_LISTEN_BEFORE"
case "$?" in
  0) ok "前像自洽: $MITM_VERDICT_WHY";;
  *) bad "前像不自洽: $MITM_VERDICT_WHY"; PREIMAGE_OK=0;;
esac
# 关闭态还要多一条: 盘上说关, 就不该再有接管插件在跑(7894 没有监听已经说明了这一点)。
if [[ "$DIR" == i2a ]]; then
  { [[ "$MITM_WLOC_ON" == 0 ]] && [[ "$MITM_LISTEN_BEFORE" == 0 ]]; } \
    && ok "前像: 本方向的 WLOC 是**按旧版真实关闭路径**关掉的(enabled=false + pdg-mitm 已停 + 7894 无监听)" \
    || { bad "前像: WLOC 关闭态没建立起来(enabled=$MITM_WLOC_ON 监听=$MITM_LISTEN_BEFORE)"; PREIMAGE_OK=0; }
  note "说明: 这一格证明的是「**关闭态** iOS→Android 的失败恢复」; 它不证明「活跃 WLOC 的 iOS→Android 恢复」。"
else
  { [[ "$MITM_WLOC_ON" == 1 ]] && [[ "$MITM_LISTEN_BEFORE" -ge 1 ]]; } \
    && ok "前像: 本方向 WLOC 开着且 7894 在监听(接管链路真的在)" \
    || { bad "前像: WLOC 开启态没建立起来(enabled=$MITM_WLOC_ON 监听=$MITM_LISTEN_BEFORE)"; PREIMAGE_OK=0; }
fi
else
  bad "前像: pdg-mitm 运行态或 7894 监听数没有有效读数 —— 自洽与方向条件无从判定"; PREIMAGE_OK=0
fi
note "前像: pdg-mitm 的合法目标态 = $MITM_WANT, 实测 ${MITM_AC_BEFORE:-读不到} —— 恢复判据按它比"
# ── p5段 前像判据 止 ──
: > "$RESIDUE_MANIFEST"
residue_record /etc/systemd/system/pdg-mitm.service "v1.11.15 的 unit 模板(pdg_write_unit pdg_unit_pdg_mitm)"
residue_record /opt/pdg-bot/mitm_server.py         "v1.11.15 源码树 deploy/bot/mitm_server.py"
residue_record /opt/pdg-bot/mitm_wloc.py           "v1.11.15 源码树 deploy/bot/mitm_wloc.py"
residue_record /opt/pdg-bot/mitm_ca.py             "v1.11.15 源码树 deploy/bot/mitm_ca.py(iOS 专属件)"
residue_record /opt/pdg-bot/iosprofile.py          "v1.11.15 源码树 deploy/bot/iosprofile.py(iOS 专属件)"
residue_record /opt/pdg-bot/iosstate.py            "v1.11.15 源码树 deploy/bot/iosstate.py(iOS 专属件)"
# 这一件上一轮**漏记**了, 于是身份判据把它判成异常。追清之后: 它由本脚本自己的
# build_preimage ios → pdg_install_runtime_modules(…, ios) 按**旧版 lib/modules.sh 的
# PDG_IOS_MODULES** 装上, 源文件是 v1.11.15 的 deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl
# (清单里写着改名 → /opt/pdg-bot/pdg-dot.mobileconfig.tmpl)。
# 候选的 **android** 受管清单里没有它 —— 上一轮"android 应装的 30 个文件逐字节一致"那条
# 也通过了, 所以**不是产品异常新增**。这里补记来源与指纹, 不是给它开白名单。
residue_record /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
  "v1.11.15 源码树 deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl → 由 build_preimage ios 按旧版 PDG_IOS_MODULES 装上(iOS 专属件)"
residue_record /etc/mosdns/rules/mitm_hijack.txt   "旧版接管表 + 一条手工加的非 WLOC 条目"
residue_record /etc/privdns-gateway/mitm.json      "旧版 WLOC 配置(本方向 enabled=$( [[ "$DIR" == i2a ]] && echo false || echo true ))"
residue_record /etc/privdns-gateway/platform       "把平台标记置成 $FROM(本方向的起点)"
residue_report
note "说明: 这台机器的平台标记是 $FROM, 但盘上带着 iOS 专属件 —— 那是**预先构造的历史残留**,"
note "  与「候选部署身份」是两回事, 下面分开核验; 既不因为标记是 android 就一律判为异常,"
note "  也不笼统豁免任何额外文件(上面清单逐项记了来源与指纹)。"

# ── 测试前置: 把冻结退役候选安装上去(只是前置, 不是合法升级路径)──────────────
# ── p5段 候选安装 起 ──
install_candidate(){   # $1=平台(默认取 $FROM) → 打印装上的项数; 清单无效 / 为空 / 任一件装不上 ⇒ 非 0
  local n=0 name src mode plat="${1:-${FROM:-ios}}" lst
  lst="${E2E_TMP:?}/p5-install-$plat.txt"
  install -m755 "$CANDSRC/deploy/bot/pdg.sh" "$P5_CLI" || return 1
  p5_modlist "$CANDSRC" "$plat" "$lst" || return 1
  while read -r src name mode; do
    [[ -n "$name" ]] || continue
    install -m"${mode:-644}" "$CANDSRC/$src" "$P5_MODDIR/$name" 2>/dev/null || return 1
    n=$((n+1))
  done < "$lst"
  (( n > 0 )) || return 1
  printf '%s\n' "$n"
}
CN="$(install_candidate "$FROM")" || { bad "测试前置: 安装冻结候选失败(清单无效、为空或有件装不上)"; PREIMAGE_OK=0; }
note "测试前置: 已装候选(${CN:-0} 项受管模块)。下面单独核验部署身份 —— 与上面的历史残留分开看。"
assert_candidate_identity "$FROM" || { bad "测试前置: 候选部署身份不成立 —— 不调用产品"; PREIMAGE_OK=0; }
switch_repo_to_candidate "$FROM" || PREIMAGE_OK=0
systemctl daemon-reload
# ── p5段 候选安装 止 ──

# ── 准备与被测操作之间的启动额度: 先清点, 再有界静置 ────────────────────────
# ── p5段 准备与标定 起 ──
# 353: 清点、静置、标定用到的共享函数原文一字不动; 它们内部的 systemctl / journalctl 查询经 ⑤ 的记账包装执行,
#      任何一次非零退出 ⇒ 整项观测无效(不能被随后的成功覆盖); 静置只量那一次目标 sleep(p5_quiesce)。
p5_acct "启动额度清点" "${E2E_TMP:?}/p5-inv.out" startlimit_inventory; P5_ARC=$?
cat -- "$E2E_TMP/p5-inv.out" 2>/dev/null
p5_acct_flush "$P5_ARC" "启动额度清点" || { P5_ARC=2; P5_WHY="${P5_WHY:+$P5_WHY; }被测判据的原判读不回来"; }   # 354: 缓冲读不回 ⇒ 本项无效
(( P5_ARC == 0 )) || { bad "启动额度清点: **观测无效** —— $P5_WHY"; PREIMAGE_OK=0; SL_INT_S=""; }
p5_quiesce "标定前" || true    # 失败已置 PREIMAGE_OK=0, 下面的前置门会报未执行

# 先标定再用。**标定不过 = 验收前置不成立** —— 不是"把 DNS 那一项降成 note 然后照常跑完",
# 那样等于拿一个证明不了东西的仪器走完四维验收再说一句"这项没取到"。
# 所以它直接置 PREIMAGE_OK=0, 由下面的前置门把整个场景报成**未执行**(诊断数据仍然留档)。
T_CAL0="$(_now_j)"
C_CAL0="$(_j_mark cal-start)" || note "阶段记账: 标定起界桩没建成($(_j_why))"
p5_acct "仪器标定" "${E2E_TMP:?}/p5-cal.out" dns_instrument_calibrate; P5_ARC=$?
cat -- "$E2E_TMP/p5-cal.out" 2>/dev/null
p5_acct_flush "$P5_ARC" "仪器标定" || { P5_ARC=2; P5_WHY="${P5_WHY:+$P5_WHY; }被测判据的原判读不回来"; }   # 354: 缓冲读不回 ⇒ 标定无效
if (( P5_ARC != 0 )); then PREIMAGE_OK=0; DNS_INSTRUMENT_OK=0; bad "验收前置未成立: DNS 标定期间有查询无效 —— $P5_WHY"
elif [[ "$P5_ACCT_RC" != 0 ]]; then PREIMAGE_OK=0; bad "验收前置未成立: DNS 仪器没有通过标定(${DNS_CALIB_WHY:-未知})"; fi
T_CAL1="$(_now_j)"
C_CAL1="$(_j_mark cal-end)" || note "阶段记账: 标定止界桩没建成($(_j_why))"
# 标定把配置还原了、服务也该稳住了 —— 再静置一次, 让**产品动作**拿到完整的启动额度,
# 然后才统一采集正式前像(准备阶段的那些重启因此落在前像之前, 不会算进产品动作)。
p5_quiesce "正式取证与平台操作前" || true
p5_wait_active mosdns "正式前像之前: mosdns 已回到稳定运行态(标定的配置还原已生效)" || true
# ── p5段 准备与标定 止 ──
# ── p5段 正式采样 起 ──
snap_state "B-$DIR-before"
fp_capture "B-$DIR-before" || { bad "正式前像: 四维采样有观测无效 —— $P5_WHY; 恢复无从比对, 不调用产品"; PREIMAGE_OK=0; }
p5_svc_snap "$EVID/svc-B-$DIR-before.tsv" || { bad "正式前像: 服务快照有观测无效 —— $P5_WHY"; PREIMAGE_OK=0; }
p5_presample "$EVID/p5-presample-$DIR.tsv" || { bad "正式前像: 8 个 unit 的调用前独立采样无效 —— $P5_WHY"; PREIMAGE_OK=0; }
PROBE_EN_BEFORE=""; BOT_EN_BEFORE=""
if p5_uq enabled pdg-probe81; then PROBE_EN_BEFORE="$P5_VAL"; else bad "正式前像: pdg-probe81 自启读数无效 —— $P5_WHY"; PREIMAGE_OK=0; fi
if p5_uq enabled pdg-bot; then BOT_EN_BEFORE="$P5_VAL"; else bad "正式前像: pdg-bot 自启读数无效 —— $P5_WHY"; PREIMAGE_OK=0; fi
B_DNS_BEFORE="$(dns_feature_probe "$DIR-before")"
note "前像的 DNS 观测 = $B_DNS_BEFORE"
# 353: 前像的 DNS 不只看 VALID 前缀 —— 本场景要求见证 = H、对照 = U(两个方向的接管表里都有 gs-loc)
p5_dns_ready "$B_DNS_BEFORE" || { bad "验收前置未成立: $P5_WHY"; PREIMAGE_OK=0; }
P5_SNAPLIST_BEFORE="${E2E_TMP:?}/p5-snap-before.txt"
p5_snap_list "$P5_SNAPLIST_BEFORE" || { bad "正式前像: 调用前列不出快照目录 —— $P5_WHY; 本次快照无从绑定"; PREIMAGE_OK=0; }
p5_nowrap_check || { bad "产品调用前: 包装没撤干净 —— $P5_WHY"; PREIMAGE_OK=0; }
# ── p5段 正式采样 止 ──

# ── p5段 调用 起 ──
if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 ⑤($DIR): 前像/前置不成立, 本场景未执行(既不算通过也不算产品失败)"
else

echo; echo "── 真正跑候选的 pdg platform $TO ──"
T_PROD0="$(_now_j)"
C_PROD0="$(_j_mark prod-start)" || note "阶段记账: 产品动作起界桩没建成($(_j_why)) —— 调用窗口内的启动记录将记未取得"
PL="$(bash "$P5_CLI" platform "$TO" 2>&1)"; PRC=$?
T_PROD1="$(_now_j)"
C_PROD1="$(_j_mark prod-end)" || note "阶段记账: 产品动作止界桩没建成($(_j_why)) —— 调用窗口内的启动记录将记未取得"
# ── p5段 调用 止 ──
printf '%s\n' "$PL" | _ev "05-$DIR-platform.log"
phase_report
_evn "05-$DIR-platform.log" "### 平台切换退出码 rc=$PRC"
echo "$PL" | tail -60 | sed 's/^/    /'
# ── p5段 调用后采样 起 ──
if P5_PLX="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$PL")"; then P5_PLXQ=ok; else P5_PLX=""; P5_PLXQ=失败; fi    # 去掉颜色码后才按行解析产品自报(c_r / c_y / c_g 会包一层颜色); 354: 去色失败不采信
p5_svc_snap "$EVID/svc-B-$DIR-after.tsv" || note "调用后的服务快照有观测无效项(逐行标 INVALID): $P5_WHY"
snap_state "B-$DIR-after"
fp_capture "B-$DIR-after" || note "调用后的四维采样有观测无效项: $P5_WHY —— 相应项记未取得"
state_diff "B-$DIR-before" "B-$DIR-after" "B-$DIR"
# ── p5段 调用后采样 止 ──

# ── p5段 阶段 起 ──
echo
echo "── ⑤-1. 阶段证据: 真的走到了「退役件已撤除、切换尚未提交」那一段吗 ──"
STAGE_OK=1
if [[ "$TO" == ios ]]; then
  grep -qE '组件部署失败' <<<"$PL" && { bad "⑤-1: 卡在 iOS 组件部署(在撤除之前)"; STAGE_OK=0; }
else
  grep -qE 'Android 组件清理未完成' <<<"$PL" && { bad "⑤-1: 卡在 Android 清理(被门拒或失败)"; STAGE_OK=0; }
fi
grep -q '本次已经撤除过退役件/推进过记录格式' <<<"$PL" \
  && ok "⑤-1: 善后走的是「撤除过退役件」那一支 —— 证明清理**确实动过手**(_PDG_RETIRE_DONE=1)" \
  || { bad "⑤-1: 善后没走「撤除过」那一支 —— 说明这一轮根本没撤除, 阶段不成立"; STAGE_OK=0; }
grep -q '归属不清就不能一把清空' <<<"$PL" \
  && ok "⑤-1: 失败来自 migrate_wloc_retire 的**真实拒绝**(接管表里有非 WLOC 条目)" \
  || { bad "⑤-1: 失败不是预先说明的那一个"; STAGE_OK=0; }
grep -q '平台已确认' <<<"$PL" && { bad "⑤-1: 居然打印了「平台已确认」—— 失败被当成成功"; STAGE_OK=0; } \
                              || ok "⑤-1: 没有打印「平台已确认」"
[[ "$PRC" != 0 ]] && ok "⑤-1: 平台切换退出码非 0(实得 $PRC)" || { bad "⑤-1: 返回 0"; STAGE_OK=0; }

if [[ "$STAGE_OK" != 1 ]]; then
  nrun "场景 ⑤($DIR): **未到达注入点** —— 恢复判据不执行(前后相同不算恢复通过)"
else
# ── p5段 阶段 止 ──

# ── p5段 自报 起 ──
echo
echo "── ⑤-2. 恢复选的是哪条路, 产品自报了什么(这里只登记; 报告是否属实在 ⑤-5 与恢复结果分开结算) ──"
# 354: 去色失败或查询出错不当成"没走整体恢复"或"没有自报"
if [[ "$P5_PLXQ" != ok ]]; then
  bad "⑤-2: 未取得 —— 产品输出去颜色失败, 恢复路径与自报都无从解析"; P5_CLAIM=unknown; P5_WHYQ="产品输出去颜色失败"
else
  grep -q '改用本次快照做整体恢复' <<<"$P5_PLX"; P5_GRC=$?
  case "$P5_GRC" in
    0) ok "⑤-2: 选的是**整体快照恢复**(局部备份里没有 unit 与 MITM 模块)";;
    1) bad "⑤-2: 没走整体恢复";;
    *) bad "⑤-2: 未取得 —— 恢复路径的查询失败(grep rc=$P5_GRC)";;
  esac
  p5_report_parse "$P5_PLX"
fi
case "$P5_CLAIM" in
  complete)   note "⑤-2: 候选自报**恢复完成**(下面逐项核对它说的对不对)";;
  incomplete) note "⑤-2: 候选自报**恢复未完成**; '快照恢复'那一行=$P5_RESTAT; 材料: 新增文件清单=${P5_MAT[newfiles]:-} / 局部备份=${P5_MAT[localbak]:-} / 本次快照=${P5_MAT[snap]:-}";;
  both)       note "⑤-2: 候选的自报自相矛盾(完成与未完成同时出现或重复)";;
  unknown)    note "⑤-2: 候选的自报未取得 —— $P5_WHYQ";;
  *)          note "⑤-2: 候选既没报完成也没报未完成";;
esac
_evn "05-$DIR-platform.log" "### 恢复自报: $P5_CLAIM"
# ── p5段 自报 止 ──

# ── p5段 四维 起 ──
echo
echo "── ⑤-3. 四维核对(文件 / 运行态 / 自启态 / 已加载配置): 两边读取都有效才判已恢复 / 未恢复, 其余记未取得 ──"
fp_cmp_files "B-$DIR-before" "B-$DIR-after" "⑤-3 文件"
p5_fp_svc "B-$DIR-before" "B-$DIR-after" "⑤-3"
if p5_uq enabled pdg-probe81; then
  if [[ "$P5_VAL" == enabled-runtime ]]; then
    p5_tally ok "pdg-probe81 自启未被提升"; ok "⑤-3 enabled-runtime **没有**被提升成永久 enabled(pdg-probe81: 前像=$PROBE_EN_BEFORE 现在=$P5_VAL)"
  else p5_tally diff "pdg-probe81 自启未被提升"; bad "⑤-3 enabled-runtime 被改成了 $P5_VAL(前像=$PROBE_EN_BEFORE)"; fi
else p5_tally na "pdg-probe81 自启未被提升"; bad "⑤-3 pdg-probe81 自启读数无效 —— 未取得($P5_WHY)"; fi
p5_quiet_unit pdg-bot "⑤-3 没配凭据的 pdg-bot" "$BOT_EN_BEFORE"
p5_quiet_unit pdg-health.timer "⑤-3 本来停着的 pdg-health.timer" ""
# A5: 本次快照的绑定; 绑定成立之后, 才拿产品记录的操作前像与**调用前**的独立采样比(不拿恢复后的现场替它)
if [[ "$P5_PLXQ" != ok ]]; then
  bad "⑤-3 本次快照绑定: 未取得 —— 产品输出去颜色失败; 产品前像的独立核对也未取得"
elif p5_snap_bind "$P5_SNAPLIST_BEFORE" "$P5_PLX"; then
  ok "⑤-3 本次快照绑定成立: $P5_SNAP($P5_BIND_DONE)"
  svcstate_cross_check "$P5_SNAP/svcstate.tsv" "$EVID/p5-presample-$DIR.tsv" "⑤-3 产品前像(调用前的独立核对)" || true
else
  bad "⑤-3 本次快照绑定: 未取得 —— $P5_WHY(已核: ${P5_BIND_DONE:-无}); 产品前像的独立核对也未取得"
fi
echo "── 已加载配置的**独立依据**(不靠磁盘 hash, 也不靠 InvocationID) ──"
# 判据是"回到前像", 不是"一定要有监听": 前像 WLOC 关着的方向本来就不该监听。两边都要有效读数。
if [[ -n "$MITM_LISTEN_BEFORE" ]] && p5_listen 7894 tcp; then
  if [[ "$P5_LN" == "$MITM_LISTEN_BEFORE" ]]; then
    p5_tally ok "7894 监听数"; ok "⑤-3 已加载配置: 7894 的监听数回到前像($MITM_LISTEN_BEFORE) —— 与盘上 wloc.enabled=$MITM_WLOC_ON 一致"
  else p5_tally diff "7894 监听数"; bad "⑤-3 已加载配置: 7894 监听数 $MITM_LISTEN_BEFORE → $P5_LN, 与前像不符"; fi
else p5_tally na "7894 监听数"; bad "⑤-3 已加载配置: 7894 监听数未取得(前像=${MITM_LISTEN_BEFORE:-读不到}; ${P5_WHY:-})"; fi
grep -qF -- "$STRAY_DOMAIN" "$P5_HIJACK" 2>/dev/null; P5_GRC=$?
case "$P5_GRC" in
  0) p5_tally ok "接管表历史条目"; ok "⑤-3 已加载配置: 接管表里那条历史条目仍在(与前像相同; 失败路径没有改动接管表)";;
  1) p5_tally diff "接管表历史条目"; bad "⑤-3 已加载配置: 接管表里的历史条目不在了";;
  *) p5_tally na "接管表历史条目"; bad "⑤-3 已加载配置: 接管表读不了 —— 未取得";;
esac
B_DNS_AFTER="$(dns_feature_probe "$DIR-after")"
if [[ "$DNS_INSTRUMENT_OK" == 1 ]]; then
  dns_verdict "⑤-3" "$B_DNS_BEFORE" "$B_DNS_AFTER"
  if [[ "$B_DNS_BEFORE" == VALID* && "$B_DNS_AFTER" == VALID* ]]; then
    if [[ "$B_DNS_BEFORE" == "$B_DNS_AFTER" ]]; then p5_tally ok "DNS 见证/对照"; else p5_tally diff "DNS 见证/对照"; fi
  else p5_tally na "DNS 见证/对照"; fi
else
  p5_tally na "DNS 见证/对照"
  note "⑤-3 已加载配置: 仪器没有通过标定, 本场景本不该走到这里(前置门应已拦下)。实测留档:"
  note "  前像 $B_DNS_BEFORE"; note "  恢复后 $B_DNS_AFTER"
fi
note "⑤-3: 端口监听 / 磁盘 hash 只作辅助。InvocationID 只证明**实例换了**, 不证明加载的是"
note "  哪一份配置 —— 那一条由上面的真实 DNS 行为(见证=H / 对照=U)回答。"
journalctl -u mosdns -u mihomo -u pdg-mitm --since "$(date -u -d '10 min ago' +%FT%T)" --no-pager 2>/dev/null \
  | tail -120 | _ev "05-$DIR-journal.txt"
# ── p5段 四维 止 ──

# ── p5段 服务过程 起 ──
echo
echo "── ⑤-4. 服务过程: 终态 / 实例变化 / 调用窗口内的启动记录 分开判(依据 = 冻结候选 cmd_platform 失败路径 + 整体恢复; 不用未执行的 run_all_migrations) ──"
p5_svc_settle "$EVID/svc-B-$DIR-before.tsv" "$EVID/svc-B-$DIR-after.tsv" "B-$DIR" || true
# ── p5段 服务过程 止 ──

# ── p5段 报告诚实性 起 ──
echo
echo "── ⑤-5. 恢复结果与报告诚实性分开结算(原始退出码与目标到达见 ⑤-1; 两项互不抵消) ──"
p5_honesty || true
# ── p5段 报告诚实性 止 ──

fi
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "④ 收尾"
# ═════════════════════════════════════════════════════════════════════════════
{
  echo "# 本轮在这台一次性 runner 上创建/改动的东西(具名, 便于核对)"
  echo "  · /etc/systemd/system/{mosdns,mihomo,pdg-bot,pdg-probe81,pdg-mitm,pdg-health}.{service,timer}"
  echo "  · /etc/{mosdns,mihomo,sing-box,privdns-gateway}/, /opt/{pdg-bot,privdns-gateway}, /var/lib/privdns-gateway"
  echo "  · 自有裸库 $ORIGIN, 旧版源码树 $OLDSRC, 候选源码树 $CANDSRC(都在本轮 \$E2E_TMP 里)"
  echo "  · 停用了 runner 自带的 systemd-resolved(为释放 :53)"
  echo "  全部落在这台一次性 runner 上; runner 随 job 结束销毁。只清本轮自有资源, 不按前缀宽删。"
  echo
  echo "# 身份"
  echo "  方向          = $DIR ($FROM → $TO)"
  echo "  旧版 OLD_SHA  = $OLD_SHA"
  echo "  候选 CAND_SHA = $CAND_SHA"
  echo "  验收 checkout = ${GITHUB_SHA:-<非 CI>}"
  echo
  echo "# 未在真机上覆盖的一格(如实登记)"
  echo "  「恢复本身失败(某件新增文件删不掉)时保留材料并具名报告」这一格需要在恢复过程中途"
  echo "  制造删除失败, 本轮不在真机上构造(会引入产品流程之外的步骤)。它由本地"
  echo "  tests/test-platform-fail-restore.sh 覆盖; 本报告不拿这里的结果替它。"
  echo
  echo "# 证据文件"
  ls -1 "$EVID" | sed 's/^/  /'
} | _ev "99-cleanup-$DIR.txt"
chmod 600 "$EVID"/* 2>/dev/null || true

echo
echo "未执行(前像/阶段不成立而跳过)的场景数: $E2E_NOTRUN"
_evn "99-cleanup-$DIR.txt" "未执行场景数: $E2E_NOTRUN"
e2e_summary

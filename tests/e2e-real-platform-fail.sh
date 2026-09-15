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
_ev(){ cat >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }
_evn(){ printf '%s\n' "$2" >> "$EVID/$1"; chmod 600 "$EVID/$1" 2>/dev/null || true; }

SECT(){ echo; echo "══════════════════════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════════════════════"; }
note(){ echo "[NOTE] $1"; }
# ── systemctl 状态的读法(夹具②)────────────────────────────────────────────
# 原来写的是 `V="$(systemctl is-enabled X 2>/dev/null || echo not-found)"`。
# systemd 255 对**已删除的 unit** 会 stdout 打一行 not-found **并且**返回非 0,
# 于是 `|| echo` 再追一行, V 变成两行 "not-found\nnot-found", 等值比较必然失败 ——
# 上一轮那条 [FAIL] pdg-mitm 自启=not-found 就是这么来的, 产品侧其实是对的。
# 现在 stdout / stderr / 退出码**分开收**, 不拼串; 也不用 tail -1 去藏第一行。
SC_VAL=""; SC_RC=0; SC_ERR=""
sc_get(){   # $1=子命令(is-active|is-enabled|...)  $2=unit
  local errf="${E2E_TMP:-/tmp}/sc.err"
  SC_VAL="$(systemctl "$1" "$2" 2>"$errf")"; SC_RC=$?
  SC_ERR="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
  rm -f "$errf" 2>/dev/null || true
}
# 把"这个 unit 现在到底算什么状态"归一成一个词, 并把判定依据保留下来:
#   active / inactive / failed / activating / …  或  not-found(unit 压根不在)
sc_state(){  # $1=子命令 $2=unit → 打印归一后的词; 依据留在 SC_VAL/SC_RC/SC_ERR
  sc_get "$1" "$2"
  if [[ -z "${SC_VAL//[[:space:]]/}" ]]; then
    case "$SC_ERR" in *"No such file"*|*"not-found"*|*"could not be found"*) printf 'not-found\n';;
                      *) printf '<空>\n';; esac
  else
    printf '%s\n' "${SC_VAL%%$'\n'*}"
  fi
}

# 未执行 ≠ 失败 ≠ 通过。前像不成立时该场景**不执行**, 单独计一格, 绝不混进通过或失败。
E2E_NOTRUN=0
nrun(){ echo "[未执行] $1"; E2E_NOTRUN=$((E2E_NOTRUN+1)); }

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
YPROD="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_SHA" -- deploy lib install.sh uninstall.sh tools 2>/dev/null)"
[[ -z "$YPROD" ]] \
  && ok "验收分支相对**冻结候选**的产品面**零差异**(它只提供验收脚本与 workflow)" \
  || bad "验收分支改了产品面: $YPROD"
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
E2E_OWNED_UNITS=(pdg-mitm.service pdg-bot.service pdg-probe81.service
                 mosdns.service mihomo.service pdg-dotwitness.service
                 pdg-health.service pdg-health.timer
                 pdg-rules-update.service pdg-rules-update.timer)

# 逐个 unit 复位, 每个动作留自己的退出码并**立刻复核真实状态**。不吞失败。
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

# 复位之后必须**证明**现场干净: 服务、监听、配置、本轮网络资源各查一遍。
# 证明不了就停 —— 不让下一场景在污染状态下继续。
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

PREIMAGE_OK=1     # 每次 build_preimage 复位; 任一前像判据不成立即置 0
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
# 被观察的服务集合: 允许清单里的 + 几个**本轮从不安装、因此绝不该变**的见证者。
SVC_WATCH=(mosdns mihomo pdg-bot pdg-probe81 pdg-dotwitness pdg-health.timer pdg-mitm
           sing-box pdg-rescue.socket ssh cron)
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

# ── 直接迁移的部署源身份(H5)─────────────────────────────────────────────────
# 上一轮栽在这: 只把候选模块 install 到 /opt/pdg-bot, 却没动 $REPO_DIR。候选 pdg.sh 的
# __migrate 第一步就是 migrate_deploy_botfiles —— 它按 **$REPO_DIR** 重装 /opt/pdg-bot,
# 而那个仓库还停在 v1.11.15, 于是刚装上去的候选模块被换回旧版, 随后
# _retire_ios_schema 调 iosstate.migrate_schema() 得到 AttributeError。
# 所以每次进入"直接迁移"之前, 都要把 REPO_DIR 真的切到 X, 并逐项核对身份。
switch_repo_to_candidate(){
  e2e_git "$REPO" checkout -q "$CAND_SHA" 2>/dev/null \
    || { bad "把 $REPO 切到候选 X 失败"; return 1; }
  local head; head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
  [[ "$head" == "$CAND_SHA" ]] && ok "部署源身份: $REPO 的 HEAD == 候选 X" \
                              || { bad "部署源 HEAD=$head(应为 X)"; return 1; }
  # 关键源文件逐字节等于 X 的那一份(拿独立展开的 $CANDSRC 当权威, 不自证)
  local miss=0 f
  for f in deploy/bot/pdg.sh deploy/bot/iosstate.py deploy/bot/pdg-bot.py lib/modules.sh; do
    cmp -s "$REPO/$f" "$CANDSRC/$f" || { miss=$((miss+1)); echo "       不符: $f"; }
  done
  [[ "$miss" == 0 ]] && ok "部署源身份: 关键源文件($REPO)逐字节等于候选 X" \
                     || { bad "部署源里有 $miss 个关键文件不是 X 的"; return 1; }
  # 按候选自己的清单装 —— 与 __migrate 里的 migrate_deploy_botfiles 同一份真源, 不会再被换回去
  install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
  ( # shellcheck source=/dev/null
    source "$REPO/lib/modules.sh" && pdg_install_runtime_modules "$REPO" /opt/pdg-bot "$1" ) \
    || { bad "按候选清单装模块失败"; return 1; }
  [[ "$(sha256sum /usr/local/bin/pdg | awk '{print $1}')" == "$(sha256sum "$CANDSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
    && ok "部署源身份: /usr/local/bin/pdg 就是候选 X 的那一份" || bad "装上去的 pdg 不是 X 的"
  # ── 按**平台契约**核对装机身份 ────────────────────────────────────────────
  # 上一轮这里写死了"iosstate 必须有 migrate_schema" —— 而 iosstate.py 属于 PDG_IOS_MODULES,
  # **Android 本来就不装它**(平台契约, 不是装机失败)。判据换成: 该平台**实际应装**的每个
  # 文件都在, 且逐字节等于候选 X 的那一份; 再加三条反面契约。
  local plat="$1" nmod=0 nbad=0 src name _mode
  while read -r src name _mode; do
    [[ -n "$src" ]] || continue
    nmod=$((nmod+1))
    if [[ ! -e "/opt/pdg-bot/$name" ]]; then
      nbad=$((nbad+1)); echo "       缺 $name"; continue
    fi
    cmp -s "$CANDSRC/$src" "/opt/pdg-bot/$name" || { nbad=$((nbad+1)); echo "       指纹不符 $name"; }
  done < <( ( source "$CANDSRC/lib/modules.sh" && pdg_platform_modules "$plat" ) 2>/dev/null )
  { [[ "$nmod" -gt 0 && "$nbad" == 0 ]]; } \
    && ok "部署源身份: $plat 平台应装的 $nmod 个文件全部就位且逐字节等于候选 X" \
    || { bad "部署源身份: $plat 平台清单 $nmod 项里有 $nbad 项缺失或指纹不符"; return 1; }
  if [[ "$plat" == android ]]; then
    # 反面契约 ①: iOS 专属那几件不该由**候选的 Android 安装**带上来。
    # 但"盘上有"不等于"候选装的" —— 本轮的前像里它们是**预先构造的历史残留**, 已经逐项
    # 记进了残留清单(来源 + sha256 + mode + uid:gid)。所以判据是**对账**, 不是看名字:
    #   · 在清单里且指纹对得上 → 已记账的历史残留, 不算异常(但要列出来, 不笼统豁免);
    #   · 不在清单里, 或指纹与清单里记的不一样 → 就是**没记账的额外文件**, 当场判红。
    # 这样既不因为平台标记是 android 就一律拒绝, 也不给任何文件开白名单。
    local ios_unaccounted="" ios_accounted="" f fsum msum
    for f in iosprofile.py iosstate.py mitm_ca.py pdg-dot.mobileconfig.tmpl; do
      [[ -e "/opt/pdg-bot/$f" ]] || continue
      fsum="$(sha256sum "/opt/pdg-bot/$f" 2>/dev/null | awk '{print $1}')"
      msum="$(awk -F"$(printf '\t')" -v k="/opt/pdg-bot/$f" '$1==k{print $3; exit}' "$RESIDUE_MANIFEST" 2>/dev/null)"
      if [[ -n "$msum" && "$msum" == "$fsum" ]]; then ios_accounted="$ios_accounted $f"
      else ios_unaccounted="$ios_unaccounted $f(盘上 ${fsum:0:12} / 清单 ${msum:-无记录})"; fi
    done
    [[ -n "$ios_accounted" ]] && note "部署源身份: 这几件 iOS 专属件是**已记账的历史残留**, 指纹与清单一致:$ios_accounted"
    [[ -z "$ios_unaccounted" ]] \
      && ok "部署源身份: Android 上没有**未记账**的 iOS 专属件(候选安装没有多带东西)" \
      || bad "部署源身份: Android 上有未记账的 iOS 专属件:$ios_unaccounted"
  else
    # 反面契约 ②: iOS 上装的 iosstate 必须是候选形态(行为身份, 不只是文件名)
    ( cd /opt/pdg-bot && python3 -c 'import iosstate,sys; sys.exit(0 if hasattr(iosstate,"migrate_schema") else 1)' ) 2>/dev/null \
      && ok "部署源身份: iOS 上装的 iosstate 具备 migrate_schema(候选形态)" \
      || { bad "部署源身份: iOS 上的 iosstate 没有 migrate_schema —— 部署源仍是旧版"; return 1; }
  fi
  # 反面契约 ③: 两平台均应退役的三件, 迁移之后一件都不许在(此刻迁移还没跑, 只记录现状)
  local retired="" r
  for r in /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py /etc/systemd/system/pdg-mitm.service; do
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
wait_stable(){   # $1=unit  [$2=最多等几秒, 默认 25]
  local u="$1" n="${2:-25}" st i
  for ((i=0; i<n; i++)); do
    st="$(systemctl show -p ActiveState --value "$u" 2>/dev/null)"
    case "$st" in activating|deactivating|reloading|"") sleep 1;; *) printf '%s\n' "$st"; return 0;; esac
  done
  printf '%s\n' "${st:-<读不到>}"; return 1
}

# ── 测试指纹 vs 产品自己写的 svcstate.tsv, 逐项对账 ──────────────────────────
# 两边在**不同时刻**采样就会对不上。这里直接比同一批 unit 的自启/运行值。
svcstate_cross_check(){   # $1=svcstate.tsv 路径  $2=标签
  local f="$1" tag="$2" u pen pac men mac n_ok=0 n_bad=0
  [[ -s "$f" ]] || { bad "$tag: 产品没写出 svcstate.tsv($f)"; return 1; }
  while IFS=$'\t' read -r k u pen _urc pac _arc _sub _inv; do
    [[ "$k" == unit && -n "$u" ]] || continue
    men="$(sc_state is-enabled "$u")"; mac="$(sc_state is-active "$u")"
    if [[ "$pen" == "$men" && "$pac" == "$mac" ]]; then n_ok=$((n_ok+1)); continue; fi
    n_bad=$((n_bad+1))
    printf '    %-22s 产品记: %s/%s   测试此刻看到: %s/%s\n' "$u" "$pen" "$pac" "$men" "$mac"
  done < "$f"
  [[ "$n_bad" == 0 ]] \
    && ok "$tag: 产品的 svcstate.tsv 与测试指纹逐项一致($n_ok 个 unit)" \
    || bad "$tag: 有 $n_bad 个 unit 两边对不上(上面逐项列出), 一致 $n_ok"
}

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
assert_candidate_identity(){   # $1=平台
  local plat="$1" mis=0 dif=0 n=0 src name mode
  [[ "$(sha256sum /usr/local/bin/pdg | awk '{print $1}')" == "$(sha256sum "$CANDSRC/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
    && ok "部署身份: /usr/local/bin/pdg 逐字节等于冻结候选" || bad "部署身份: pdg 不是候选那一份"
  # shellcheck source=/dev/null
  source "$CANDSRC/lib/modules.sh" 2>/dev/null || { bad "部署身份: 读不到候选的 modules.sh"; return 1; }
  while read -r src name mode; do
    [[ -n "$name" ]] || continue
    n=$((n+1))
    [[ -e "/opt/pdg-bot/$name" ]] || { mis=$((mis+1)); continue; }
    cmp -s "$CANDSRC/$src" "/opt/pdg-bot/$name" || dif=$((dif+1))
  done < <(pdg_platform_modules "$plat")
  { [[ "$mis" == 0 && "$dif" == 0 ]]; } \
    && ok "部署身份: $n 项受管模块与冻结候选逐字节一致(缺 $mis / 不符 $dif)" \
    || bad "部署身份: 受管模块与候选不一致(缺 $mis / 不符 $dif)"
  _evn 00-identity.txt "候选部署身份: pdg+${n} 模块; 缺 $mis 不符 $dif"
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
fp_capture(){   # $1=标签 → 写 $EVID/fp-$1.tsv
  local tag="$1" q u
  local f="$EVID/fp-$tag.tsv"
  : > "$f"
  for q in "${FP_FILES[@]}"; do
    if [[ -e "$q" ]]; then
      printf 'F\t%s\t有\t%s\t%s\t%s\t%s\n' "$q" \
        "$(sha256sum "$q" 2>/dev/null | awk '{print $1}')" \
        "$(stat -c %a "$q")" "$(stat -c %u "$q")" "$(stat -c %g "$q")" >> "$f"
    else
      printf 'F\t%s\t无\t-\t-\t-\t-\n' "$q" >> "$f"
    fi
  done
  local av ar ev er
  for u in "${FP_SVCS[@]}"; do
    # 状态与**退出码**分开记: systemd 对已删除的 unit 会既打印 not-found 又返回非 0,
    # 只看 stdout 或只看 rc 都会误判。
    av="$(sc_state is-active  "$u")"; ar="$SC_RC"
    ev="$(sc_state is-enabled "$u")"; er="$SC_RC"
    printf 'R\t%s\tis-active rc=%s\tis-enabled rc=%s\n' "$u" "$ar" "$er" >> "$f"
    printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" \
      "$av" "$ev" \
      "$(systemctl show -p MainPID --value "$u" 2>/dev/null)" \
      "$(systemctl show -p InvocationID --value "$u" 2>/dev/null)" \
      "$(systemctl show -p NRestarts --value "$u" 2>/dev/null)" >> "$f"
  done
  # 已加载配置的独立依据: 真实监听(不是磁盘 hash)
  printf 'L\t7894\t%s\n' "$(ss -lnt 2>/dev/null | grep -c ':7894 ')" >> "$f"
  printf 'L\t53\t%s\n'   "$(ss -lnu 2>/dev/null | grep -c ':53 ')" >> "$f"
  chmod 600 "$f"
}
fp_get(){   # $1=标签 $2=类型 $3=键 → 打印那一行的其余字段
  # 按**字段**拼回去, 不用 [^\t] 这类方括号反斜杠转义 —— 那种写法在 POSIX grep/awk 下会被
  # 截断解释(仓库的 test-false-green-guard.sh 专门盯这一条)。分隔符用真正的制表符。
  local TAB; TAB="$(printf '\t')"
  awk -F"$TAB" -v t="$2" -v k="$3" \
      '$1==t && $2==k {out=$3; for(i=4;i<=NF;i++) out=out FS $i; print out; exit}' "$EVID/fp-$1.tsv"
}
fp_cmp_files(){   # $1=before $2=after $3=场景名 —— 四维逐项比对
  local q b a n_ok=0 n_bad=0
  for q in "${FP_FILES[@]}"; do
    b="$(fp_get "$1" F "$q")"; a="$(fp_get "$2" F "$q")"
    if [[ "$b" == "$a" ]]; then n_ok=$((n_ok+1)); continue; fi
    n_bad=$((n_bad+1))
    printf '    %-58s\n      前: %s\n      后: %s\n' "$q" "${b:-<无记录>}" "${a:-<无记录>}"
  done
  [[ "$n_bad" == 0 ]] \
    && ok "$3: ${#FP_FILES[@]} 个受关注文件的**存在性/内容/mode/uid/gid** 四项全部回到前像" \
    || bad "$3: 有 $n_bad 个文件没回到前像(上面逐项列出), 一致 $n_ok"
}


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

build_preimage ios on
# ── 合法历史残留: 每一项写明来源, 并在下面逐项记指纹 ────────────────────────
# ① 接管表里有一条**非 WLOC** 的域名(有人手工改过的痕迹)
STRAY_DOMAIN="full:legacy-hand-edited.example"
printf '%s\n' "$STRAY_DOMAIN" >> /etc/mosdns/rules/mitm_hijack.txt
# ② 这台机器当前的平台标记
printf '%s\n' "$FROM" > /etc/privdns-gateway/platform
rm -f /etc/privdns-gateway/platform.guessed
# ③ iOS→Android 方向: mitm.json 置成 enabled=false。
#    理由仍然是可达性 —— migrate_android_cleanup 只在 `"enabled": true` 时才把接管表整表
#    截断, 截断之后那条历史条目就没了, 失败点也就到不了。
#    **但光改盘是不够的**: 上一轮只写了文件没让服务重读, 于是前像变成"进程在内存里跑着一份
#    盘上已经不存在的配置"(7894 还监听着, 而盘上说 WLOC 是关的)。那是个自相矛盾的现场,
#    据它做的恢复验收不作数。这里改完配置就用**合法操作**(restart)让 pdg-mitm 真的去读它,
#    然后**测量**结果, 不预设"一定还监听"。
if [[ "$DIR" == i2a ]]; then
  printf '{"wloc": {"enabled": false, "locations": {"osaka": [34.7, 135.5]}}}\n' > /etc/privdns-gateway/mitm.json
fi
# 两个方向都走一遍: 让盘上那份配置成为**进程正在跑的**那一份。
systemctl restart pdg-mitm >/dev/null 2>&1 || true
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
for _u in pdg-mitm mosdns mihomo pdg-probe81 pdg-bot pdg-health.timer; do
  printf '    %-18s 稳定后 ActiveState=%s UnitFileState=%s\n' "$_u" "$(wait_stable "$_u")" \
    "$(systemctl show -p UnitFileState --value "$_u" 2>/dev/null)"
done
[[ "$(sc_state is-enabled pdg-probe81)" == enabled-runtime ]] \
  && ok "前像: pdg-probe81 的自启是 enabled-runtime(真 systemd 实测)" \
  || { bad "前像: pdg-probe81 自启=$(sc_state is-enabled pdg-probe81)"; PREIMAGE_OK=0; }
[[ "$(sc_state is-active pdg-probe81)" == active ]] \
  && ok "前像: pdg-probe81 稳定运行中" || { bad "前像: pdg-probe81 没稳定起来"; PREIMAGE_OK=0; }
{ [[ "$(sc_state is-active pdg-bot)" != active && "$(sc_state is-enabled pdg-bot)" != enabled ]]; } \
  && ok "前像: pdg-bot 是产品支持的停用态(没配凭据)" \
  || { bad "前像: pdg-bot 不是停用态"; PREIMAGE_OK=0; }
[[ "$(sc_state is-active pdg-health.timer)" != active ]] \
  && ok "前像: pdg-health.timer 本来就停着" || { bad "前像: pdg-health.timer 还在跑"; PREIMAGE_OK=0; }
grep -q "$STRAY_DOMAIN" /etc/mosdns/rules/mitm_hijack.txt \
  && ok "前像: 接管表里有一条非 WLOC 的历史条目($STRAY_DOMAIN)" || { bad "前像: 残留条目没写进去"; PREIMAGE_OK=0; }
[[ -e /etc/systemd/system/pdg-mitm.service && -e /opt/pdg-bot/mitm_server.py && -e /opt/pdg-bot/mitm_wloc.py ]] \
  && ok "前像: 退役件(unit + 两个 MITM 模块)确实在盘上" || { bad "前像: 退役件不全"; PREIMAGE_OK=0; }
# ── 前像自洽核验: 盘上的配置与进程的实际行为必须对得上 ──────────────────────
# 不再硬性要求"WLOC 关着而旧监听还在"。判据是**一致性**: 盘上 wloc.enabled 说什么,
# 7894 上就该是什么。测出来是什么就记什么, 后面的恢复判据拿这个测量值作参照。
MITM_AC_BEFORE="$(wait_stable pdg-mitm)"
MITM_WLOC_ON="$(python3 -c 'import json,sys
try: print("1" if json.load(open("/etc/privdns-gateway/mitm.json",encoding="utf-8")).get("wloc",{}).get("enabled") else "0")
except Exception: print("?")' 2>/dev/null)"
MITM_LISTEN_BEFORE="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
note "前像: 盘上 wloc.enabled=$MITM_WLOC_ON, pdg-mitm=$MITM_AC_BEFORE, 7894 监听数=$MITM_LISTEN_BEFORE"
case "$MITM_WLOC_ON:$([[ "$MITM_LISTEN_BEFORE" -ge 1 ]] && echo L || echo N)" in
  1:L) ok "前像自洽: WLOC 开着, 7894 确实在监听(盘上配置就是进程正在跑的那一份)";;
  0:N) ok "前像自洽: WLOC 关着, 7894 确实没有监听(盘上配置就是进程正在跑的那一份)";;
  1:N) bad "前像不自洽: 盘上 WLOC 开着, 7894 却没有监听"; PREIMAGE_OK=0;;
  0:L) bad "前像不自洽: 盘上 WLOC 关着, 7894 却还在监听 —— 进程没有读盘上那份配置"; PREIMAGE_OK=0;;
  *)   bad "前像: 读不出 mitm.json 的 wloc.enabled"; PREIMAGE_OK=0;;
esac
[[ "$MITM_AC_BEFORE" == active ]] \
  && ok "前像: pdg-mitm 处在稳定运行态(active)" \
  || note "前像: pdg-mitm 稳定后是 $MITM_AC_BEFORE —— 这就是本方向的合法前像, 恢复判据按它比"
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
install_candidate(){   # $1=平台(默认取 $FROM)
  local n=0 name src mode plat="${1:-${FROM:-ios}}"
  install -m755 "$CANDSRC/deploy/bot/pdg.sh" /usr/local/bin/pdg || return 1
  # shellcheck source=/dev/null
  source "$CANDSRC/lib/modules.sh" || return 1
  while read -r src name mode; do
    [[ -n "$name" ]] || continue
    install -m"${mode:-644}" "$CANDSRC/$src" "/opt/pdg-bot/$name" 2>/dev/null || return 1
    n=$((n+1))
  done < <(pdg_platform_modules "$plat")
  printf '%s\n' "$n"
}
CN="$(install_candidate "$FROM")" || { bad "测试前置: 安装冻结候选失败"; PREIMAGE_OK=0; }
note "测试前置: 已装候选($CN 项受管模块)。下面单独核验部署身份 —— 与上面的历史残留分开看。"
assert_candidate_identity "$FROM"
switch_repo_to_candidate "$FROM" || PREIMAGE_OK=0
systemctl daemon-reload

# 先标定再用。**标定不过 = 验收前置不成立** —— 不是"把 DNS 那一项降成 note 然后照常跑完",
# 那样等于拿一个证明不了东西的仪器走完四维验收再说一句"这项没取到"。
# 所以它直接置 PREIMAGE_OK=0, 由下面的前置门把整个场景报成**未执行**(诊断数据仍然留档)。
dns_instrument_calibrate || { PREIMAGE_OK=0; bad "验收前置未成立: DNS 仪器没有通过标定(${DNS_CALIB_WHY:-未知})"; }
snap_state "B-$DIR-before"
fp_capture "B-$DIR-before"
svc_snapshot "$E2E_TMP/svc-B-$DIR-before.tsv"
PROBE_EN_BEFORE="$(sc_state is-enabled pdg-probe81)"
BOT_EN_BEFORE="$(sc_state is-enabled pdg-bot)"
B_DNS_BEFORE="$(dns_feature_probe "$DIR-before")"
note "前像的 DNS 观测 = $B_DNS_BEFORE"
[[ "$B_DNS_BEFORE" == VALID* ]] || { bad "验收前置未成立: 前像的 DNS 观测本身就无效 —— $B_DNS_BEFORE"; PREIMAGE_OK=0; }
HT_INV_BEFORE="$(systemctl show -p InvocationID --value pdg-health.timer 2>/dev/null)"
HT_AC_BEFORE="$(sc_state is-active pdg-health.timer)"

if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 ⑤($DIR): 前像/前置不成立, 本场景未执行(既不算通过也不算产品失败)"
else

echo; echo "── 真正跑候选的 pdg platform $TO ──"
PL="$(bash /usr/local/bin/pdg platform "$TO" 2>&1)"; PRC=$?
printf '%s\n' "$PL" | _ev "05-$DIR-platform.log"
_evn "05-$DIR-platform.log" "### 平台切换退出码 rc=$PRC"
echo "$PL" | tail -60 | sed 's/^/    /'
svc_snapshot "$E2E_TMP/svc-B-$DIR-after.tsv"
snap_state "B-$DIR-after"
fp_capture "B-$DIR-after"
state_diff "B-$DIR-before" "B-$DIR-after" "B-$DIR"

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

echo
echo "── ⑤-2. 恢复选的是哪条路 ──"
grep -q '改用本次快照做整体恢复' <<<"$PL" \
  && ok "⑤-2: 选的是**整体快照恢复**(局部备份里没有 unit 与 MITM 模块)" || bad "⑤-2: 没走整体恢复"
if grep -q '已按本次快照恢复到切换前' <<<"$PL"; then
  RESTORE_CLAIM=complete; ok "⑤-2: 候选自报**恢复完成**(下面逐项核对它说的对不对)"
elif grep -q '恢复未完成' <<<"$PL"; then
  RESTORE_CLAIM=incomplete
  ok "⑤-2: 候选自报**恢复未完成**并给出材料路径"
  grep -qE '新增文件清单: |局部备份    : |本次快照    : ' <<<"$PL" && ok "⑤-2: 三处材料路径都打出来了" || bad "⑤-2: 材料路径不全"
else
  RESTORE_CLAIM=none; bad "⑤-2: 既没报完成也没报未完成"
fi
_evn "05-$DIR-platform.log" "### 恢复自报: $RESTORE_CLAIM"

echo
echo "── ⑤-3. 四维核对(文件 / 运行态 / 自启态 / 已加载配置) ──"
fp_cmp_files "B-$DIR-before" "B-$DIR-after" "⑤-3 文件"
for u in "${FP_SVCS[@]}"; do
  b="$(fp_get "B-$DIR-before" S "$u" | cut -f1)"; a="$(fp_get "B-$DIR-after" S "$u" | cut -f1)"
  eb="$(fp_get "B-$DIR-before" S "$u" | cut -f2)"; ea="$(fp_get "B-$DIR-after" S "$u" | cut -f2)"
  [[ "$b" == "$a" ]]   && ok "⑤-3 运行态: $u 回到前像($a)"   || bad "⑤-3 运行态: $u 前像=$b 现在=$a"
  [[ "$eb" == "$ea" ]] && ok "⑤-3 自启态: $u 回到前像($ea)" || bad "⑤-3 自启态: $u 前像=$eb 现在=$ea"
done
PROBE_EN_AFTER="$(sc_state is-enabled pdg-probe81)"
[[ "$PROBE_EN_AFTER" == enabled-runtime ]] \
  && ok "⑤-3 enabled-runtime **没有**被提升成永久 enabled(pdg-probe81: 前像=$PROBE_EN_BEFORE 现在=$PROBE_EN_AFTER)" \
  || bad "⑤-3 enabled-runtime 被改成了 $PROBE_EN_AFTER(前像=$PROBE_EN_BEFORE)"
BOT_EN_AFTER="$(sc_state is-enabled pdg-bot)"
{ [[ "$BOT_EN_AFTER" != enabled && "$(sc_state is-active pdg-bot)" != active ]]; } \
  && ok "⑤-3 没配凭据的 pdg-bot 仍是停用态(前像=$BOT_EN_BEFORE 现在=$BOT_EN_AFTER)" \
  || bad "⑤-3 pdg-bot 被拉起来了(enabled=$BOT_EN_AFTER active=$(sc_state is-active pdg-bot))"
# 产品自己写下的前像与测试指纹逐项对账
B_SNAP="$(ls -1dt "${SNAP_DIR:-/var/lib/privdns-gateway/backups}"/* 2>/dev/null | head -1)"
if [[ -n "$B_SNAP" && -s "$B_SNAP/svcstate.tsv" ]]; then
  note "⑤-3: 产品写的前像 = $B_SNAP/svcstate.tsv"
  svcstate_cross_check "$B_SNAP/svcstate.tsv" "⑤-3"
else
  bad "⑤-3: 找不到产品写的 svcstate.tsv(cmd_platform 应当在建完快照后就写)"
fi
HT_INV_AFTER="$(systemctl show -p InvocationID --value pdg-health.timer 2>/dev/null)"
HT_AC_AFTER="$(sc_state is-active pdg-health.timer)"
{ [[ "$HT_AC_AFTER" != active ]] && [[ "$HT_INV_AFTER" == "$HT_INV_BEFORE" ]]; } \
  && ok "⑤-3 本来停着的 pdg-health.timer 全程没被启动过(is-active=$HT_AC_AFTER, InvocationID 未变)" \
  || bad "⑤-3 pdg-health.timer 被动过(active=$HT_AC_BEFORE→$HT_AC_AFTER, Invocation=$HT_INV_BEFORE→$HT_INV_AFTER)"

echo "── 已加载配置的**独立依据**(不靠磁盘 hash, 也不靠 InvocationID) ──"
L7894="$(ss -lnt 2>/dev/null | grep -c ':7894 ')"
# 判据是"回到前像", 不是"一定要有监听": 前像 WLOC 关着的方向本来就不该监听。
[[ "$L7894" == "$MITM_LISTEN_BEFORE" ]] \
  && ok "⑤-3 已加载配置: 7894 的监听数回到前像($MITM_LISTEN_BEFORE) —— 与盘上 wloc.enabled=$MITM_WLOC_ON 一致" \
  || bad "⑤-3 已加载配置: 7894 监听数 $MITM_LISTEN_BEFORE → $L7894, 与前像不符"
if grep -q "$STRAY_DOMAIN" /etc/mosdns/rules/mitm_hijack.txt 2>/dev/null; then
  ok "⑤-3 已加载配置: 接管表里那条历史条目也回来了(内容层面的独立特征)"
else
  bad "⑤-3 已加载配置: 接管表里的历史条目没回来"
fi
B_DNS_AFTER="$(dns_feature_probe "$DIR-after")"
if [[ "$DNS_INSTRUMENT_OK" == 1 ]]; then
  dns_verdict "⑤-3" "$B_DNS_BEFORE" "$B_DNS_AFTER"
else
  note "⑤-3 已加载配置: 仪器没有通过标定, 本场景本不该走到这里(前置门应已拦下)。实测留档:"
  note "  前像 $B_DNS_BEFORE"; note "  恢复后 $B_DNS_AFTER"
fi
note "⑤-3: 端口监听 / 磁盘 hash 只作辅助。InvocationID 只证明**实例换了**, 不证明加载的是"
note "  哪一份配置 —— 那一条由上面的真实 DNS 行为(见证=H / 对照=U)回答。"
journalctl -u mosdns -u mihomo -u pdg-mitm --since "$(date -u -d '10 min ago' +%FT%T)" --no-pager 2>/dev/null \
  | tail -120 | _ev "05-$DIR-journal.txt"

echo
echo "── ⑤-4. 不相关服务有没有清单外动作 ──"
svc_verdict "$E2E_TMP/svc-B-$DIR-before.tsv" "$E2E_TMP/svc-B-$DIR-after.tsv" "B-$DIR"

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

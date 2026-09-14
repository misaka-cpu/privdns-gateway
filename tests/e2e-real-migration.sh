#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役的**真实**迁移验收: 真 systemd + 真 nft + 旧版 CLI 升级链。
#
# 为什么需要这一支: 仓库里所有 WLOC 退役相关的测试, 在 systemd 这一层都是桩 ——
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
# 未执行 ≠ 失败 ≠ 通过。前像不成立时该场景**不执行**, 单独计一格, 绝不混进通过或失败。
E2E_NOTRUN=0
nrun(){ echo "[未执行] $1"; E2E_NOTRUN=$((E2E_NOTRUN+1)); }

e2e_enter "$@"

# 两个提交分工明确, 报告里也分开记:
#   · CAND_SHA(候选 X)= **产品**候选。装到机器上的每一个受管文件都只能来自它。
#   · 本脚本所在的验收分支(Y)只提供**验收脚本**; 它的工作区**不是**产品来源。
OLD_SHA="${PDG_OLD_SHA:-242602c17bd92900df81f468aae8c66e18c7a4ff}"   # v1.11.15 peeled
CAND_SHA="${PDG_CAND_SHA:-ab4882c2f6aba0a44e174e5230ddc4feb29584b7}" # 产品候选 X
CAND_BASE="${PDG_CAND_BASE:-95caf26f108a7740fc6fbacb7181f775b6f41971}"  # X 与 Y 共同的 base
OLD_TAG="v1.11.15"
TEST_TAG="v9.9.9-wloc-real-migration-TEST-ONLY"

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
YPROD="$(git -C "$E2E_ROOT_REAL" diff --name-only "$CAND_BASE" -- deploy lib install.sh uninstall.sh tools 2>/dev/null)"
[[ -z "$YPROD" ]] \
  && ok "验收分支 Y 相对 base 的产品面**零差异**(它只提供验收脚本)" \
  || bad "验收分支改了产品面: $YPROD"
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
    print("    schema=%r instance_id=%r revision=%r" % (m.get("schema"), m.get("instance_id"), m.get("revision")))
    inp = m.get("inputs") or {}
    print("    inputs.schema=%r wloc_enabled=%r wloc_ca_sha256=%r ssids=%r"
          % (inp.get("schema"), inp.get("wloc_enabled"), (inp.get("wloc_ca_sha256") or "")[:12], inp.get("ssids")))
    print("    retired_revision=%r" % m.get("retired_revision"))
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
    stmitm="$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found)"
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
    import mitm_ca
    der = mitm_ca.ca_der_from_pem(mitm_ca.ca_cert_pem())
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
  python3 - <<'PY'
import json, sys
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
except Exception as e:
    print("[FAIL] 前像: 读不到 iOS 记录: %s" % e); sys.exit(0)
inp = m.get("inputs") or {}
if m.get("schema") == 1 and inp.get("wloc_enabled") is True and inp.get("wloc_ca_sha256"):
    print("[OK]   前像: iOS 记录是 schema 1 且带 WLOC 字段(wloc_enabled=True, 有 CA 指纹)")
else:
    print("[FAIL] 前像: iOS 记录形态不对 schema=%r wloc_enabled=%r" % (m.get("schema"), inp.get("wloc_enabled")))
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
    # 反面契约 ①: iOS 专属那四件不该出现在 Android 上
    local ios_only="" f
    for f in iosprofile.py iosstate.py mitm_ca.py pdg-dot.mobileconfig.tmpl; do
      [[ -e "/opt/pdg-bot/$f" ]] && ios_only="$ios_only $f"
    done
    [[ -z "$ios_only" ]] && ok "部署源身份: Android 上没有 iOS 专属件(平台契约成立)" \
                         || bad "部署源身份: Android 上出现了 iOS 专属件:$ios_only"
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
SECT "③ 场景 A —— iOS + WLOC 已启用: 旧版 CLI 完整升级链"
# ═════════════════════════════════════════════════════════════════════════════
note "前像构造方式: 旧版(v1.11.15)自己的模块、unit 模板与渲染器 + 自造证书/配置。"
note "**这是「建立了真实运行前像」, 不是「完整执行过旧安装器 install.sh」。** 两者本报告分开记。"
build_preimage ios on
assert_preimage_A
snap_state A-before
if [[ "$PREIMAGE_OK" == 1 ]]; then

IID_A_BEFORE="$(python3 -c 'import json;print((json.load(open("/etc/privdns-gateway/ios-profile.json")) or {}).get("instance_id",""))' 2>/dev/null || echo "")"
PDG_SHA_BEFORE="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
OLD_PDG_SHA="$(sha256sum "$OLDSRC/deploy/bot/pdg.sh" | awk '{print $1}')"
[[ "$PDG_SHA_BEFORE" == "$OLD_PDG_SHA" ]] \
  && ok "升级前 /usr/local/bin/pdg 逐字节等于 v1.11.15 的 deploy/bot/pdg.sh(更新器确实是旧版)" \
  || bad "更新器不是旧版(装的 $PDG_SHA_BEFORE vs 旧版 $OLD_PDG_SHA)"

echo "── 旧 CLI 的 dry-run(先看它怎么判关系) ──"
DRY="$(bash /usr/local/bin/pdg update --dry-run 2>&1)"; DRC=$?
printf '%s\n' "$DRY" | _ev 03-A-dryrun.txt
echo "$DRY" | sed 's/^/    /' | head -20
[[ "$DRC" == 0 ]] && ok "dry-run rc=0" || bad "dry-run rc=$DRC"
grep -q "$TEST_TAG" <<<"$DRY" && ok "dry-run 认出目标是本轮的测试候选 tag" || bad "dry-run 没认出目标 tag"

svc_snapshot "$E2E_TMP/svc-A-before.tsv"
echo; echo "── 真正跑旧 CLI 的 pdg update(完整升级链) ──"
UP="$(bash /usr/local/bin/pdg update 2>&1)"; URC=$?
svc_snapshot "$E2E_TMP/svc-A-after.tsv"
printf '%s\n' "$UP" | _ev 03-A-update.log
echo "$UP" | tail -40 | sed 's/^/    /'
_evn 03-A-update.log "### rc=$URC"
snap_state A-after
state_diff A-before A-after A

echo
echo "── 升级链到底走到哪一步(逐段判读, 不按 rc 一言以蔽之) ──"
CHAIN=""
grep -q '更新前留快照' <<<"$UP"   && { ok "① 取更新锁并建升级前快照"; CHAIN="$CHAIN 锁+快照"; } || bad "① 没到快照这一步"
grep -q '拉取最新发布 tag' <<<"$UP" && { ok "② 从自有裸库真实取件"; CHAIN="$CHAIN 取件"; }     || bad "② 没到取件这一步"
grep -q '已切到发布' <<<"$UP"      && { ok "③ 仓库切到候选"; CHAIN="$CHAIN 切版本"; }          || bad "③ 没切到候选"
grep -q '刷新代码' <<<"$UP"        && { ok "④ 安装受管文件"; CHAIN="$CHAIN 装文件"; }          || bad "④ 没到装文件"
grep -qE 'WLOC 退役|退役' <<<"$UP" && { ok "⑤ 迁移入口跑到了 WLOC 退役"; CHAIN="$CHAIN 迁移"; } || note "⑤ 输出里没有 WLOC 退役字样(可能这台机器无事可做, 见下面的实际状态)"
grep -q '✅ 已更新' <<<"$UP"       && { ok "⑦ 整条 update 报成功"; CHAIN="$CHAIN 成功"; }      || note "⑦ update 没有报成功(rc=$URC) —— 下面逐项说明停在哪"
grep -qE '回滚到更新前快照|已回滚' <<<"$UP" && { note "⑧ **触发了回滚** —— 后像是回滚后的现场, 不是迁移后的现场"; CHAIN="$CHAIN 回滚"; }
_evn 03-A-update.log "### 链路判读: $CHAIN"

ROLLED=0; grep -qE '回滚到更新前快照|已回滚' <<<"$UP" && ROLLED=1

if [[ "$URC" == 0 && "$ROLLED" == 0 ]]; then
  ok "**完整升级链通过**: 旧版 CLI 从 $OLD_TAG 升到冻结候选(测试源映射下)"
  echo
  echo "── 升级后的真实现场(A) ──"
  RD="$(git -C "$REPO" describe --tags --always 2>/dev/null)"
  [[ "$(git -C "$REPO" rev-parse HEAD)" == "$CAND_SHA" ]] \
    && ok "仓库 HEAD == 冻结候选 $CAND_SHA(describe=$RD)" || bad "仓库 HEAD=$(git -C "$REPO" rev-parse HEAD)"
  # 受管产品文件必须等于冻结候选里的同名文件
  MIS=0; DIF=0; N=0
  # shellcheck source=/dev/null
  source "$REPO/lib/modules.sh"
  while read -r src name _mode; do
    N=$((N+1))
    [[ -e "/opt/pdg-bot/$name" ]] || { MIS=$((MIS+1)); continue; }
    cmp -s "$REPO/$src" "/opt/pdg-bot/$name" || DIF=$((DIF+1))
  done < <(pdg_platform_modules ios)
  { [[ "$MIS" == 0 && "$DIF" == 0 ]]; } \
    && ok "安装后的 $N 项受管模块与冻结候选逐字节一致(缺 $MIS / 不符 $DIF)" \
    || bad "受管模块与候选不一致: 缺 $MIS / 不符 $DIF"
  [[ "$(sha256sum /usr/local/bin/pdg | awk '{print $1}')" == "$(sha256sum "$REPO/deploy/bot/pdg.sh" | awk '{print $1}')" ]] \
    && ok "/usr/local/bin/pdg 已换成候选那一份" || bad "/usr/local/bin/pdg 没换"
else
  bad "完整升级链未走完(rc=$URC, 回滚=$ROLLED) —— 后面按**实际现场**继续取证, 不按假设"
fi

echo
echo "── WLOC 退役的真实结果(真 systemd 判定, 不看调用记录) ──"
MAC="$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found)"
MEN="$(systemctl is-enabled pdg-mitm 2>/dev/null || echo not-found)"
MSUB="$(systemctl show -p SubState --value pdg-mitm 2>/dev/null)"
[[ "$MAC" != active ]] && ok "pdg-mitm 真的不在跑了(is-active=$MAC, SubState=$MSUB)" || bad "pdg-mitm 仍然 active"
[[ "$MEN" == not-found || "$MEN" == disabled ]] && ok "pdg-mitm 自启已撤(is-enabled=$MEN)" || bad "pdg-mitm 自启=$MEN"
ss -lnt 2>/dev/null | grep -q ':7894' && bad "7894 仍有监听(服务没真停)" || ok "7894 已无监听 —— 由真实运行状态证明, 不是靠 unit 文件消失"
[[ -e /etc/systemd/system/pdg-mitm.service ]] && bad "pdg-mitm unit 仍在盘上" || ok "pdg-mitm unit 已删除"
[[ -e /opt/pdg-bot/mitm_server.py || -e /opt/pdg-bot/mitm_wloc.py ]] \
  && bad "WLOC 执行模块仍在 /opt/pdg-bot" || ok "WLOC 执行模块已移除"
if [[ -f /etc/mosdns/rules/mitm_hijack.txt ]]; then
  [[ -s /etc/mosdns/rules/mitm_hijack.txt ]] && bad "劫持表非空: $(tr '\n' ' ' < /etc/mosdns/rules/mitm_hijack.txt)" \
                                             || ok "劫持表存在且为空(休眠锚点; 文件不能删 —— mosdns 的 force_hijack 指着它)"
else
  bad "劫持表文件被删了 —— mosdns 的 force_hijack domain_set 会失去输入"
fi
grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null && bad "内核配置里仍有 MITM-OUT" || ok "内核配置里的 MITM 路由已撤"
grep -q 'gs-loc' /etc/mihomo/config.yaml 2>/dev/null && bad "内核配置里仍有 gs-loc 规则" || ok "内核配置里的 gs-loc 规则已撤"
grep -q '"enabled": *false' /etc/privdns-gateway/mitm.json 2>/dev/null && ok "mitm.json 的 wloc.enabled 置 false" || bad "mitm.json 的 enabled 没置 false"
grep -q 'osaka' /etc/privdns-gateway/mitm.json 2>/dev/null && ok "用户存的地点(locations)保留 —— 那是用户数据" || bad "地点数据丢了"
[[ -s /etc/privdns-gateway/ca/ca.crt && -s /etc/privdns-gateway/ca/ca.key ]] \
  && ok "CA 证书与私钥按保留策略仍在(mode=$(stat -c %a /etc/privdns-gateway/ca/ca.key))" || bad "CA 材料被删了"
grep -qE '证书信任设置|取消对|撤销|信任' <<<"$UP" && ok "升级输出里给出了手机端撤信任的指引" || bad "输出里没有撤信任指引"
# schema 与 SSID 按**真实契约**核对: 启用过 WLOC 的那一版会被退役(current → None),
# 用户的非 WLOC 意图由 retired_inputs 兜住(见 X 的 _migrate_1_to_2 注释)。
( cd /opt/pdg-bot && python3 - <<'PY'
import json, os, sys
sys.path.insert(0, "/opt/pdg-bot")
m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
def ok(t):  print("[OK]   " + t)
def bad(t): print("[FAIL] " + t)
(ok if m.get("schema") == 2 else bad)("A: iOS 记录迁到 schema 2(实得 %r)" % m.get("schema"))
(ok if m.get("current") is None else bad)("A: 带根证书的那一版已退役(current 应为 None, 实得 %r)"
                                          % (type(m.get("current")).__name__,))
(ok if m.get("retired_revision") else bad)("A: 记下了被退役的版本号(retired_revision=%r)" % m.get("retired_revision"))
ri = m.get("retired_inputs") or {}
(ok if ri.get("ssids") == ["HomeWiFi"] else bad)(
    "A: 用户 SSID 意图由 retired_inputs 兜住(实得 %r)" % (ri.get("ssids"),))
wl = [k for k in ri if k.startswith("wloc")]
(ok if not wl else bad)("A: retired_inputs 里已无 WLOC 字段(实得 %r)" % wl)
(ok if not os.path.exists("/var/lib/privdns-gateway/ios-profile/current.mobileconfig") else bad)(
    "A: 嵌着根证书的旧产物已从盘上删除")
# **后续普通生成**才算真的"沿用用户意图" —— 只看元数据里留了一份副本不算。
try:
    import iosstate
    eff = iosstate.effective_ssids(m, None)
    (ok if eff == ["HomeWiFi"] else bad)("A: effective_ssids(沿用语义)算出 %r" % (eff,))
    meta2, _lv, _rs, data2, changed = iosstate.generate("dot.e2e.test", ["203.0.113.1"], ssids=None)
    (ok if changed else bad)("A: 重新生成了一份描述文件(changed=%r)" % changed)
    (ok if meta2.get("instance_id") == m.get("instance_id") else bad)("A: 重新生成没有换身份")
    n2 = ((meta2.get("current") or {}).get("inputs") or {}).get("ssids")
    (ok if n2 == ["HomeWiFi"] else bad)("A: 新记录的 current.inputs.ssids=%r" % (n2,))
    (ok if b"HomeWiFi" in data2 else bad)("A: **新产物里真的带着用户的 SSID**(不是只有元数据留了副本)")
    (ok if b"com.apple.security.root" not in data2 else bad)("A: 新产物不含根证书 payload")
except Exception as e:
    bad("A: 后续普通生成失败: %r" % (e,))
PY
) || true
# 稳定身份: 前后 instance_id 必须一致(直接从记录里读, 不从快照文本里抠)
IID_A_AFTER="$(python3 -c 'import json;print((json.load(open("/etc/privdns-gateway/ios-profile.json")) or {}).get("instance_id",""))' 2>/dev/null || echo "")"
_evn 03-A-update.log "instance_id before/after: ${IID_A_BEFORE:-<空>} / ${IID_A_AFTER:-<空>}"
[[ -n "$IID_A_BEFORE" && "$IID_A_BEFORE" == "$IID_A_AFTER" ]] \
  && ok "A: 稳定身份跨 schema 未变(instance_id 前后一致)" \
  || bad "A: instance_id 变了或读不到(${IID_A_BEFORE:-<空>} → ${IID_A_AFTER:-<空>})"

svc_verdict "$E2E_TMP/svc-A-before.tsv" "$E2E_TMP/svc-A-after.tsv" A
echo
echo "── 不该被牵连的东西 ──"
for s in mosdns mihomo; do
  a="$(systemctl is-active $s 2>/dev/null)"
  [[ "$a" == active ]] && ok "$s 仍在跑(active)" || bad "$s 被牵连了(is-active=$a)"
done
MOSH="$(grep -c 'force_hijack' /etc/mosdns/config.yaml 2>/dev/null || echo 0)"
[[ "$MOSH" -gt 0 ]] && ok "mosdns 的 force_hijack 结构仍在(共享消费者未受损, 出现 $MOSH 次)" || bad "force_hijack 结构没了"
FAILED_N="$(systemctl list-units --failed --no-legend 2>/dev/null | wc -l)"
_evn 03-A-update.log "failed units after A: $FAILED_N"
systemctl list-units --failed --no-legend 2>/dev/null | _ev 03-A-update.log

echo
echo "── 幂等: 再跑一次迁移, 不该动文件也不该重启服务 ──"
INV_1="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)$(systemctl show -p InvocationID --value mihomo 2>/dev/null)"
H1="$(find /etc/privdns-gateway /etc/mosdns/rules /etc/mihomo -type f -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum)"
IDEM="$(bash /usr/local/bin/pdg __migrate 2>&1)"; IRC=$?
printf '%s\n' "$IDEM" | _ev 03-A-idempotent.txt
H2="$(find /etc/privdns-gateway /etc/mosdns/rules /etc/mihomo -type f -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum)"
INV_2="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)$(systemctl show -p InvocationID --value mihomo 2>/dev/null)"
[[ "$IRC" == 0 ]] && ok "第二次 __migrate rc=0" || bad "第二次 __migrate rc=$IRC"
[[ "$H1" == "$H2" ]] && ok "第二次运行没有改动任何文件(内容/大小/mtime 全一致)" || bad "第二次运行动了文件"
[[ "$INV_1" == "$INV_2" ]] && ok "第二次运行没有重启 mosdns / mihomo(InvocationID 未变)" || bad "第二次运行重启了服务"

else
  nrun "场景 A(旧 CLI 完整升级链): 前像不成立, 本场景未执行 —— 不拿不成立的前像冒充有效验收"
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "④ 场景 B —— iOS + WLOC 未启用"
# ═════════════════════════════════════════════════════════════════════════════
build_preimage ios off
[[ ! -e /etc/privdns-gateway/ca/ca.crt ]] && ok "前像 B: 没有 CA 材料(合法的无 CA 产物)" || bad "前像 B: 不该有 CA"
python3 - <<'PY'
import json
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
    print("[OK]   前像 B: 有合法 schema-%s 记录, instance_id=%s" % (m.get("schema"), (m.get("instance_id") or "")[:12]))
except Exception as e:
    print("[FAIL] 前像 B: 没有 iOS 记录: %s" % e)
PY
[[ -e /etc/systemd/system/pdg-mitm.service ]] \
  && ok "前像 B: iOS 机器上 pdg-mitm unit 存在(旧版 install.sh 对 iOS 无条件装)" || bad "前像 B: 缺 pdg-mitm unit"
[[ "$(systemctl is-active pdg-mitm 2>/dev/null)" == active ]] \
  && ok "前像 B: pdg-mitm 真的在跑(未启用 WLOC 只是没加载插件)" || bad "前像 B: pdg-mitm 没起来"
IID_B_BEFORE="$(python3 -c 'import json;print((json.load(open("/etc/privdns-gateway/ios-profile.json")) or {}).get("instance_id",""))' 2>/dev/null)"
snap_state B-before
if [[ "$PREIMAGE_OK" == 1 ]]; then
svc_snapshot "$E2E_TMP/svc-B-before.tsv"
# 直接装候选的 pdg 再跑迁移 —— 这是**补充测试**, 不当作完整升级证据
note "场景 B/C 用的是**直接迁移**(把部署源切到候选后跑 __migrate), 明确不等于完整升级链。"
if switch_repo_to_candidate ios; then
  MB="$(bash /usr/local/bin/pdg __migrate 2>&1)"; MBRC=$?
else
  MB="(部署源身份不成立, 本场景未执行迁移)"; MBRC=127
fi
printf '%s\n' "$MB" | _ev 04-B-migrate.txt
snap_state B-after; state_diff B-before B-after B
[[ "$MBRC" == 0 ]] && ok "B: 迁移 rc=0" || bad "B: 迁移 rc=$MBRC"
svc_snapshot "$E2E_TMP/svc-B-after.tsv"
svc_verdict "$E2E_TMP/svc-B-before.tsv" "$E2E_TMP/svc-B-after.tsv" B
IID_B_AFTER="$(python3 -c 'import json;print((json.load(open("/etc/privdns-gateway/ios-profile.json")) or {}).get("instance_id",""))' 2>/dev/null)"
[[ -n "$IID_B_BEFORE" && "$IID_B_BEFORE" == "$IID_B_AFTER" ]] \
  && ok "B: 稳定身份未变(instance_id 前后一致)" || bad "B: instance_id 变了($IID_B_BEFORE → $IID_B_AFTER)"
# SSID 按**真实 schema 契约**核对(位置不是猜的, 是从 X 的 _migrate_1_to_2 读出来的):
#   未启用 WLOC ⇒ current 这一栏**被保留**, 输入随之迁到 schema 2 形态
#   ⇒ 意图仍在 current.inputs.ssids; retired_inputs / retired_revision 应为 None。
python3 - <<'PY'
import json, os
m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
def ok(t):  print("[OK]   " + t)
def bad(t): print("[FAIL] " + t)
(ok if m.get("schema") == 2 else bad)("B: 记录迁到 schema 2(实得 %r)" % m.get("schema"))
cur = m.get("current")
if cur is None:
    bad("B: current 被退役了 —— 未启用 WLOC 的记录不该被退役")
else:
    inp = cur.get("inputs") or {}
    (ok if inp.get("ssids") == ["HomeWiFi"] else bad)(
        "B: 用户 SSID 意图保留在 current.inputs.ssids(实得 %r)" % (inp.get("ssids"),))
    wl = [k for k in inp if k.startswith("wloc")]
    (ok if not wl else bad)("B: current.inputs 里已无 WLOC 字段(实得 %r)" % wl)
(ok if m.get("retired_inputs") is None else bad)(
    "B: retired_inputs 为 None(没有东西被退役; 实得 %r)" % (m.get("retired_inputs"),))
(ok if m.get("retired_revision") is None else bad)(
    "B: retired_revision 为 None(实得 %r)" % m.get("retired_revision"))
art = "/var/lib/privdns-gateway/ios-profile/current.mobileconfig"
if os.path.exists(art):
    data = open(art, "rb").read()
    (ok if b"HomeWiFi" in data else bad)("B: 产物里仍带着用户的 SSID")
    (ok if b"com.apple.security.root" not in data else bad)("B: 产物里没有根证书 payload")
else:
    bad("B: 产物不见了 —— 未启用 WLOC 的那一版不该被删")
PY
[[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "B: pdg-mitm unit 已撤除" || bad "B: pdg-mitm unit 还在"
[[ "$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found)" != active ]] \
  && ok "B: pdg-mitm 真的停了(is-active=$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found))" || bad "B: pdg-mitm 还在跑"
[[ ! -e /etc/privdns-gateway/ca/ca.crt ]] && ok "B: 迁移没有凭空造出 CA" || bad "B: 冒出了 CA 材料"
MB2="$(bash /usr/local/bin/pdg __migrate 2>&1)"; MB2RC=$?
printf '%s\n' "$MB2" | _ev 04-B-migrate.txt
[[ "$MB2RC" == 0 ]] && ok "B: 二次执行幂等(rc=0)" || bad "B: 二次执行非 0(rc=$MB2RC)"

else
  nrun "场景 B(iOS 未启用 WLOC 的直接迁移): 前像不成立, 本场景未执行"
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "⑤ 场景 C —— Android / 仅 CA 残留"
# ═════════════════════════════════════════════════════════════════════════════
build_preimage android caonly
[[ ! -e /opt/pdg-bot/iosprofile.py ]] && ok "前像 C: Android 上没有 iOS 专属模块" || bad "前像 C: 不该有 iOS 模块"
[[ -s /etc/privdns-gateway/ca/ca.crt ]] && ok "前像 C: 盘上确有 CA 残留(切过平台的机器形态)" || bad "前像 C: 没造出 CA 残留"
[[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "前像 C: 没有 pdg-mitm unit" || bad "前像 C: 不该有 unit"
snap_state C-before
if [[ "$PREIMAGE_OK" == 1 ]]; then
svc_snapshot "$E2E_TMP/svc-C-before.tsv"
if switch_repo_to_candidate android; then
  MC="$(bash /usr/local/bin/pdg __migrate 2>&1)"; MCRC=$?
else
  MC="(部署源身份不成立, 本场景未执行迁移)"; MCRC=127
fi
printf '%s\n' "$MC" | _ev 05-C-migrate.txt
snap_state C-after; state_diff C-before C-after C
[[ "$MCRC" == 0 ]] && ok "C: 迁移 rc=0" || bad "C: 迁移 rc=$MCRC"
[[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "C: 没有凭空造出任何旧服务的 unit" || bad "C: 冒出了 unit"
[[ "$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found)" != active ]] && ok "C: 没有凭空启动旧服务" || bad "C: 启动了旧服务"
[[ -s /etc/privdns-gateway/ca/ca.crt && -s /etc/privdns-gateway/ca/ca.key ]] \
  && ok "C: CA-only 残留被保留(未删除)" || bad "C: CA 残留被删了"
grep -qE '证书信任设置|CA 材料|取消对' <<<"$MC" \
  && ok "C: CA-only 机器仍被识别并报告(输出里点名了 CA 与撤信任)" || bad "C: 没有报告 CA 残留"
svc_snapshot "$E2E_TMP/svc-C-after.tsv"
svc_verdict "$E2E_TMP/svc-C-before.tsv" "$E2E_TMP/svc-C-after.tsv" C
bash /usr/local/bin/pdg __migrate >/dev/null 2>&1 && ok "C: 二次执行幂等(rc=0)" || bad "C: 二次执行非 0"

else
  nrun "场景 C(Android / 仅 CA 残留): 前像不成立, 本场景未执行"
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "⑥ 晚期失败恢复 —— 新配置已进运行态之后才失败"
# ═════════════════════════════════════════════════════════════════════════════
# 注入点(明确记录, 只此一处): 在 /opt/pdg-bot 里放一个**语法错误的额外 .py 文件**。
# cmd_update 的顺序是: 装文件 → __migrate(WLOC 退役 + schema 提交) → 内核二进制 →
# **py_compile 校验门** → daemon-reload → 重启 → doctor 门。
# 于是这个文件只会在「迁移已经提交、新配置已经进运行态」之后才把 update 打掉 ——
# 正是要验的那一类晚期失败。systemd 仍然是真的, 一个桩都没有。
build_preimage ios on
assert_preimage_A >/dev/null 2>&1
snap_state D-before
if [[ "$PREIMAGE_OK" == 1 ]]; then
# 前像的运行实例身份: 恢复之后这几个要能证明"服务真的下去过又回来了"。
D_INV_MITM="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
D_NR_MITM="$(systemctl show -p NRestarts --value pdg-mitm 2>/dev/null)"
D_T0="$(date -u +%Y-%m-%d\ %H:%M:%S)"
INJ=/opt/pdg-bot/zz_e2e_late_failure_inject.py
printf 'def broken(:\n' > "$INJ"
note "故障注入点: $INJ(语法错误的额外模块) —— 只影响 update 的 py_compile 校验门, 不改产品实现"
_evn 06-late-failure.txt "注入点: $INJ, 内容: 'def broken(:'  —— 触发 cmd_update 的 py_compile 校验门"
_evn 06-late-failure.txt "注入副本与候选 X 的差异: 仅多出这一个文件; 产品文件一个字节未改"
_evn 06-late-failure.txt "前像运行实例: pdg-mitm InvocationID=$D_INV_MITM NRestarts=$D_NR_MITM"
UPD="$(bash /usr/local/bin/pdg update 2>&1)"; UDRC=$?
printf '%s\n' "$UPD" | _ev 06-late-failure.txt
_evn 06-late-failure.txt "### rc=$UDRC"
echo "$UPD" | tail -25 | sed 's/^/    /'
rm -f "$INJ"
snap_state D-after; state_diff D-before D-after D

# ── 先判"到没到晚期"。没到就如实说未验证, 不拿别的失败冒充 ────────────────────
_line_of(){ grep -n -- "$1" <<<"$UPD" | head -1 | cut -d: -f1; }
L_INSTALL="$(_line_of '刷新代码')"
# 迁移这一段只认 **WLOC 退役自己的成功文案**, 不拿泛泛的"迁移"二字凑数。
L_MIG="$(grep -nE '已退役\(服务已停|iOS 描述文件记录已迁移' <<<"$UPD" | head -1 | cut -d: -f1)"
L_INJ="$(_line_of 'Python 语法错误')"
L_RB="$(_line_of '回滚到更新前快照')"
_evn 06-late-failure.txt "阶段行号: 装文件=$L_INSTALL 迁移=$L_MIG 注入命中=$L_INJ 回滚=$L_RB"
# **"坏语法文件被检测到"本身不等于晚期失败。** 要同时满足:
#   受管文件已安装 → WLOC 退役迁移已经成功落地(新配置进了运行态) → 注入才命中。
# 任何一环不成立, 就如实判"未覆盖晚期恢复", 不改名包装成通过。
LATE_REACHED=0
if [[ -n "$L_INSTALL" && -n "$L_INJ" && -n "$L_MIG" \
      && "$L_INSTALL" -lt "$L_INJ" && "$L_MIG" -lt "$L_INJ" ]]; then LATE_REACHED=1; fi

if [[ "$LATE_REACHED" == 0 ]]; then
  if [[ -z "$L_INJ" ]]; then
    nrun "晚期失败恢复: 注入**没有命中**(update 在 py_compile 校验门之前就结束了), 未覆盖晚期恢复"
  elif [[ -z "$L_MIG" ]]; then
    nrun "晚期失败恢复: 注入命中时**新配置尚未加载**(没有 WLOC 退役的落地输出), 未覆盖晚期恢复"
  else
    nrun "晚期失败恢复: 阶段顺序不成立(装文件=$L_INSTALL 迁移=$L_MIG 注入=$L_INJ), 未覆盖晚期恢复"
  fi
  note "不把取件失败、前像构造失败或安装前的检查失败称为晚期失败。"
else
  ok "① 到达晚期: 受管文件已安装(第 $L_INSTALL 行)且注入在其之后命中(第 $L_INJ 行)"
  ok "① 新配置已进运行态: WLOC 退役的落地输出(第 $L_MIG 行)排在注入命中之前"
  # 运行态真的被改过: pdg-mitm 的运行实例身份必须变过(停过又起来)
  R_INV="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
  [[ -n "$D_INV_MITM" && -n "$R_INV" && "$D_INV_MITM" != "$R_INV" ]] \
    && ok "① 运行态确实被动过: pdg-mitm 的 InvocationID 变了($D_INV_MITM → $R_INV) —— 它真的下去过又回来了" \
    || bad "① pdg-mitm 的 InvocationID 没变($D_INV_MITM → $R_INV): 拿不出「下去过」的证据"
  journalctl -u pdg-mitm --since "$D_T0" --no-pager 2>/dev/null | grep -qiE 'Stopped|Deactivated' \
    && ok "① journal 里有 pdg-mitm 被停的记录(真 systemd 的现场证据)" \
    || note "① journal 里没抓到 pdg-mitm 的停止记录(记下来, 不据此下结论)"
  grep -qE 'Python 语法错误' <<<"$UPD" && ok "② 注入确实发生: 命中 py_compile 校验门(不是别的地方)" \
                                       || bad "② 没命中预期的注入点: $(tail -3 <<<"$UPD")"
  grep -qE '回滚到更新前快照' <<<"$UPD" && ok "③ 随后走了恢复: 产品自己的回滚路径" || bad "③ 没有触发回滚"
  [[ -n "$L_RB" && -n "$L_INJ" && "$L_RB" -gt "$L_INJ" ]] \
    && ok "③ 顺序正确: 回滚发生在注入命中之后" || bad "③ 回滚与注入的先后对不上"
  [[ "$UDRC" != 0 ]] && ok "update 返回非 0(rc=$UDRC), 没有谎报成功" || bad "失败却返回 0"
fi

if [[ "$LATE_REACHED" != 1 ]]; then
  nrun "④ 四维恢复核对: 晚期没到达, 这一组判据**不执行** —— 现场没被动过时它们会假绿"
else
echo "── ④ 恢复是否真的回到前像(四个维度都要对) ──"
RAC="$(systemctl is-active pdg-mitm 2>/dev/null || echo not-found)"
REN="$(systemctl is-enabled pdg-mitm 2>/dev/null || echo not-found)"
[[ "$RAC" == active ]] && ok "恢复: pdg-mitm **真的又在跑**(is-active=active, MainPID=$(systemctl show -p MainPID --value pdg-mitm))" \
                       || bad "恢复: pdg-mitm 没回到运行态(is-active=$RAC)"
[[ "$REN" == enabled ]] && ok "恢复: pdg-mitm 自启回到 enabled" || bad "恢复: 自启=$REN(前像是 enabled)"
ss -lnt 2>/dev/null | grep -q ':7894' && ok "恢复: 7894 又有监听 —— 运行配置真的回来了, 不是只有文件回来了" || bad "恢复: 7894 没有监听"
[[ -e /etc/systemd/system/pdg-mitm.service ]] && ok "恢复: unit 文件回来了" || bad "恢复: unit 文件没回来"
[[ -e /opt/pdg-bot/mitm_server.py && -e /opt/pdg-bot/mitm_wloc.py ]] && ok "恢复: WLOC 模块文件回来了" || bad "恢复: 模块没回来"
grep -q 'gs-loc' /etc/mosdns/rules/mitm_hijack.txt 2>/dev/null && ok "恢复: 劫持表内容回到前像" || bad "恢复: 劫持表没回来"
grep -q '"enabled": *true' /etc/privdns-gateway/mitm.json 2>/dev/null && ok "恢复: mitm.json 回到 enabled=true" || bad "恢复: mitm.json 没回来"
grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null && ok "恢复: 内核配置里的 MITM 路由回来了" || bad "恢复: 内核配置没回来"
python3 - <<'PY'
import json
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
    print("[OK]   恢复: iOS 记录回到 schema 1" if m.get("schema") == 1 else "[FAIL] 恢复: schema=%r(前像是 1)" % m.get("schema"))
except Exception as e:
    print("[FAIL] 恢复: 读不到 iOS 记录 %s" % e)
PY
for f in /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_wloc.py /etc/privdns-gateway/mitm.json /etc/privdns-gateway/ca/ca.key; do
  if [[ -e "$f" ]]; then
    B="$(grep -F " $f " "$EVID/state-D-before.txt" | head -1 | awk '{print $3, $4, $5}')"
    A="$(printf '%s %s:%s %s' "$(stat -c %a "$f")" "$(stat -c %U "$f")" "$(stat -c %G "$f")" "$(sha256sum "$f" | cut -c1-16)")"
    [[ "$B" == "$A" ]] && ok "恢复: $f 的 mode/属主/内容与前像一致" || bad "恢复: $f 与前像不同(前 [$B] 后 [$A])"
  else
    bad "恢复: $f 不存在"
  fi
done
# 回滚不完整时: 恢复材料必须留着
if grep -qE '恢复材料|已保留' <<<"$UPD"; then
  # _RETIRE_TMP 来自 mktemp -d, 落在 TMPDIR 下; 这里按 TMPDIR 取路径, 不写死目录字面量。
  MATP="$(grep -oE "${TMPDIR:-/tmp}/[A-Za-z0-9._-]+" <<<"$UPD" | tail -1)"
  [[ -n "$MATP" && -d "$MATP" ]] && ok "回滚不完整, 但恢复材料目录仍在且可读: $MATP($(ls -1 "$MATP" | wc -l) 项)" \
                                 || bad "输出提到恢复材料, 但目录不可用: ${MATP:-<未打印路径>}"
fi
fi
ls -la /var/lib/privdns-gateway/backups 2>/dev/null | _ev 06-late-failure.txt

else
  nrun "晚期失败恢复: 前像不成立, 本项未执行"
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "⑦ 收尾"
# ═════════════════════════════════════════════════════════════════════════════
{
  echo "# 本轮在这台一次性 runner 上创建/改动的东西(具名, 便于核对)"
  echo "  · /etc/systemd/system/{mosdns,mihomo,pdg-bot,pdg-probe81,pdg-mitm,pdg-health}.{service,timer}"
  echo "  · /etc/{mosdns,mihomo,sing-box,privdns-gateway}/, /opt/{pdg-bot,privdns-gateway}, /var/lib/privdns-gateway"
  echo "  · 自有探针 unit $PROBE(已具名删除), 自有 nft table pdg_e2e_probe(已具名删除)"
  echo "  · 自有裸库 $ORIGIN, 旧版源码树 $OLDSRC(都在本轮 \$E2E_TMP 里, 退出钩子清理)"
  echo "  · 停用了 runner 自带的 systemd-resolved(为释放 :53)"
  echo "  全部落在这台一次性 runner 上; runner 随 job 结束销毁。"
  echo
  echo "# 证据文件"
  ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-cleanup.txt
chmod 600 "$EVID"/* 2>/dev/null || true

echo
echo "未执行(前像不成立而跳过)的场景数: $E2E_NOTRUN"
_evn 99-cleanup.txt "未执行场景数: $E2E_NOTRUN"
e2e_summary

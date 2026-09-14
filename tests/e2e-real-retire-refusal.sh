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
TEST_TAG="v9.9.9-wloc-retire-refusal-TEST-ONLY"

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

# ── 已加载配置: 用**可区分的真实 DNS 行为**验, 并带对照 ─────────────────────
# 自有配置特征: WLOC 时期的接管表把 gs-loc.apple.com 劫持到本机网关地址。
# 只有恢复出来的那份 mosdns 配置真的被加载, 这个域名才会拿到劫持答案;
# 对照域名不在接管集里, 结果必然不同。端口/hash/InvocationID 只作辅助。
dns_answer(){   # $1=域名 → 打印 "rcode|answer"
  local out
  out="$(dig +time=3 +tries=1 @127.0.0.1 "$1" A 2>&1)"
  printf '%s|%s\n' "$(grep -o 'status: [A-Z]*' <<<"$out" | head -1 | awk '{print $2}')" \
                   "$(awk '/^;; ANSWER SECTION/{f=1;next} f&&/^[^;]/{print $NF; exit}' <<<"$out")"
}
dns_feature_probe(){   # $1=标签 → 打印 "劫持域答案 :: 对照域答案"
  local hij ctl
  hij="$(dns_answer gs-loc.apple.com)"
  ctl="$(dns_answer control-not-hijacked.e2e.test)"
  printf '%s :: %s\n' "$hij" "$ctl"
  _evn "dns-probe-$1.txt" "hijacked=gs-loc.apple.com -> $hij"
  _evn "dns-probe-$1.txt" "control =control-not-hijacked.e2e.test -> $ctl"
}

# ── DNS 仪器: 先标定成**有效仪器**, 再允许进入验收 ──────────────────────────
# 上一轮两支都栽在这里: 接管域与对照域拿到**同一个**答案(NOERROR|203.0.113.1) —— E2E 夹具
# 的上游对任何域名都返回同一个地址。那种环境里 "NOERROR" 什么也不证明。
# 上一版的标定条件只看 "a_off 非空且 a_off != a_on", 于是**查询超时、空输出、错误结果**
# 都可能被当成"两份配置结果不同"而判成标定成功。这一版把成功契约写死在前面。
DNS_INSTRUMENT_OK=0
DNS_CALIB_WHY=""

# 一次查询的**完整**观测: 退出码 / DNS 状态 / 规范化答案 / stderr 首行。四样一起记, 一起判。
dns_probe(){   # $1=域名 → 打印 "rc<TAB>status<TAB>answer<TAB>stderr首行"
  local out err rc st ans
  err="$(mktemp "${TMPDIR:-/tmp}/dnsprobe.XXXXXX")"
  out="$(dig +time=3 +tries=1 +retry=0 @127.0.0.1 "$1" A 2>"$err")"; rc=$?
  st="$(grep -o 'status: [A-Z]*' <<<"$out" | head -1 | awk '{print $2}')"
  ans="$(awk '/^;; ANSWER SECTION/{f=1;next} f&&/^[^;]/{print $NF; exit}' <<<"$out")"
  printf '%s\t%s\t%s\t%s\n' "$rc" "${st:-NO-STATUS}" "${ans:-NO-ANSWER}" "$(head -1 "$err" | tr -d '\t')"
  rm -f "$err"
}
# **预先写死的成功契约**: 退出码 0 + 状态 NOERROR + 有真答案 + stderr 空。
# 差一样就不是"一次有效观测" —— 超时/空输出/异常一律不得充当"两份配置结果不同"的证据。
dns_probe_ok(){   # $1=dns_probe 的一行
  local rc st ans er; IFS=$'\t' read -r rc st ans er <<<"$1"
  [[ "$rc" == 0 && "$st" == NOERROR && -n "$ans" && "$ans" != NO-ANSWER && -z "$er" ]]
}

# 让 mosdns 真的重读接管表。**失败必须传出去** —— 不能 `|| true` 吞成"标定有效"。
# 用 restart 而不是 reload: InvocationID 换没换是"配置确实被重新读过"的独立依据。
_dns_apply_hijack(){
  local inv0 inv1 ac
  inv0="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)"
  systemctl restart mosdns >/dev/null 2>&1 || { DNS_CALIB_WHY="mosdns 重启动作失败"; return 1; }
  ac="$(wait_stable mosdns)"
  [[ "$ac" == active ]] || { DNS_CALIB_WHY="mosdns 重启后停在 $ac, 没有稳定运行"; return 1; }
  inv1="$(systemctl show -p InvocationID --value mosdns 2>/dev/null)"
  [[ -n "$inv1" && "$inv1" != "$inv0" ]] \
    || { DNS_CALIB_WHY="mosdns 的 InvocationID 没变($inv0 → ${inv1:-读不到}), 无法确认配置被重读"; return 1; }
  return 0
}

# 标定: **同一个查询名**, 只差接管表里的一条条目, 两份配置都要给出**有效**观测, 且结果不同。
# 全程只动本轮自造的那一条域名; 自有配置先整份存下来, 退出时按内容 + 属性可靠还原并核对。
# 不用 `grep -v` 删行: 过滤后为空时 grep 返回非零, 那种写法可能根本没把文件换回去。
dns_instrument_calibrate(){
  local hij=/etc/mosdns/rules/mitm_hijack.txt
  local name entry bak sum0 mode0 own0 sum1 mode1 own1 p_off p_on
  DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""
  command -v dig >/dev/null 2>&1 || { DNS_CALIB_WHY="机器上没有 dig, 无法标定"; bad "仪器标定: $DNS_CALIB_WHY"; return 1; }
  [[ -f "$hij" ]] || { DNS_CALIB_WHY="找不到接管表 $hij"; bad "仪器标定: $DNS_CALIB_WHY"; return 1; }
  # 每次用一个**没被任何缓存见过**的新名字, 排除缓存造成的假差异。
  name="dns-calib-$$-${RANDOM}.e2e.test"; entry="full:$name"

  # ① 整份保存自有配置(内容 + 属性), 并立刻挂上退出兜底
  bak="${E2E_TMP:-${TMPDIR:-/tmp}}/hijack-calib.bak"
  cat "$hij" > "$bak" || { DNS_CALIB_WHY="存不下接管表副本"; bad "仪器标定: $DNS_CALIB_WHY"; return 1; }
  sum0="$(sha256sum "$hij" | awk '{print $1}')"
  mode0="$(stat -c %a "$hij")"; own0="$(stat -c %u:%g "$hij")"
  _dns_calib_restore(){   # 按内容整份写回, 再补回属性。不依赖过滤删行。
    cat "$bak" > "$hij" 2>/dev/null || return 1
    chmod "$mode0" "$hij" 2>/dev/null || true
    chown "$own0"  "$hij" 2>/dev/null || true
  }
  # 失败也要走还原 —— 用显式收尾, 不靠 RETURN trap(它会留在全局上,
  # 而这一段后面还要继续用这份文件)。
  _calib_fail(){ _dns_calib_restore || DNS_CALIB_WHY="$DNS_CALIB_WHY(而且还原也失败了)"
                 bad "仪器标定: $DNS_CALIB_WHY"; return 1; }

  # ② 配置甲: 这个名字**不在**接管表里
  _dns_apply_hijack || { DNS_CALIB_WHY="$DNS_CALIB_WHY —— 重载失败不算标定成功"; _calib_fail; return 1; }
  p_off="$(dns_probe "$name")"
  # ③ 配置乙: **只**多这一条条目, 别的一个字不动
  printf '%s\n' "$entry" >> "$hij"
  _dns_apply_hijack || { DNS_CALIB_WHY="$DNS_CALIB_WHY —— 重载失败不算标定成功"; _calib_fail; return 1; }
  p_on="$(dns_probe "$name")"
  _evn dns-calibration.txt "查询名 $name(每次新造, 排除缓存)"
  _evn dns-calibration.txt "配置甲(不在接管表) rc/status/answer/stderr = $p_off"
  _evn dns-calibration.txt "配置乙(在接管表)   rc/status/answer/stderr = $p_on"

  # ④ 还原并核对: 内容 + 权限 + 属主, 再确认服务**重新读过**还原后的配置
  _dns_calib_restore || { DNS_CALIB_WHY="接管表还原失败"; bad "仪器标定: $DNS_CALIB_WHY"; return 1; }
  sum1="$(sha256sum "$hij" | awk '{print $1}')"
  mode1="$(stat -c %a "$hij")"; own1="$(stat -c %u:%g "$hij")"
  if [[ "$sum0" != "$sum1" || "$mode0" != "$mode1" || "$own0" != "$own1" ]]; then
    DNS_CALIB_WHY="接管表没有原样还原(sha $sum0→$sum1, mode $mode0→$mode1, owner $own0→$own1)"
    bad "仪器标定: $DNS_CALIB_WHY"; return 1
  fi
  ok "仪器标定: 接管表按内容与属性逐项还原(sha256/mode/uid:gid 都对得上)"
  _dns_apply_hijack || { bad "仪器标定: 还原后 $DNS_CALIB_WHY"; return 1; }
  ok "仪器标定: 服务已按**还原后**的配置重新起过(InvocationID 变过)"

  # ⑤ 判定 —— 三种失败分别说清, 不混成一句
  if ! dns_probe_ok "$p_off" || ! dns_probe_ok "$p_on"; then
    DNS_CALIB_WHY="两次查询里有观测不满足成功契约(甲=$p_off ; 乙=$p_on)"
    bad "仪器标定: $DNS_CALIB_WHY —— 超时/空输出/异常不得充当'结果不同'"
    return 1
  fi
  ok "仪器标定: 两次查询都满足成功契约(rc=0 + NOERROR + 有答案 + stderr 空)"
  local a_off a_on; a_off="$(cut -f3 <<<"$p_off")"; a_on="$(cut -f3 <<<"$p_on")"
  if [[ "$a_off" == "$a_on" ]]; then
    DNS_CALIB_WHY="同一查询在两份产品配置下答案相同($a_off) —— 这台机器上 DNS 结果不由产品配置决定"
    bad "仪器标定: $DNS_CALIB_WHY"
    note "  停用该仪器: 后面不拿 DNS 结果当「配置已加载」的证据, 也不把 NOERROR 当恢复成功。"
    return 1
  fi
  DNS_INSTRUMENT_OK=1
  ok "仪器标定: 同一查询在两份产品配置下结果**不同**($a_off vs $a_on) —— DNS 特征可作判据"
  return 0
}

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

# ── 测试前置: 把冻结退役候选安装上去(只用于 A0 的阶段观测, 不是合法升级路径)──────
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

# ═════════════════════════════════════════════════════════════════════════════
SECT "③ 场景 A0 —— **阶段观测**: 只看「新版迁移跑到门拒绝」这一段, 不含任何回滚"
# ═════════════════════════════════════════════════════════════════════════════
note "为什么要单独这一段: 完整链路里, 原版回滚**允许**重启 pdg-mitm, 于是「整段前后」的"
note "  PID / InvocationID / journal 停止记录分不出「退役停的」还是「回滚重启的」。"
note "  这一段把候选装上之后**只跑 __migrate**(旧 CLI 的子进程形态), 观测落在拒绝的那一刻,"
note "  后面没有任何回滚来覆盖现场。它与下面的完整链路各自成立, 不互相替代。"
build_preimage ios on
# 前像先稳下来再采样: activating/deactivating 时采到的东西两边对不上(见 helpers 里的说明)。
for _u in pdg-mitm mosdns mihomo pdg-probe81; do
  printf '    %-14s 稳定后 ActiveState=%s\n' "$_u" "$(wait_stable "$_u")"
done
assert_preimage_A
: > "$RESIDUE_MANIFEST"
residue_record /etc/systemd/system/pdg-mitm.service "v1.11.15 的 unit 模板(pdg_write_unit pdg_unit_pdg_mitm)"
residue_record /opt/pdg-bot/mitm_server.py         "v1.11.15 源码树 deploy/bot/mitm_server.py"
residue_record /opt/pdg-bot/mitm_wloc.py           "v1.11.15 源码树 deploy/bot/mitm_wloc.py"
residue_record /etc/mosdns/rules/mitm_hijack.txt   "旧版接管表(WLOC 自有域名)"
residue_record /etc/privdns-gateway/mitm.json      "旧版 WLOC 配置(enabled=true + 用户地点)"
residue_record /etc/privdns-gateway/ios-profile.json "旧版 schema-1 记录"
residue_report

# 先标定再用。**标定不过 = 验收前置不成立** —— 不是"把 DNS 那一项降成 note 然后照常跑完",
# 那样等于拿一个证明不了东西的仪器走完四维验收再说一句"这项没取到"。
# 所以它直接置 PREIMAGE_OK=0, 由下面的前置门把整个场景报成**未执行**(诊断数据仍然留档)。
dns_instrument_calibrate || { PREIMAGE_OK=0; bad "验收前置未成立: DNS 仪器没有通过标定(${DNS_CALIB_WHY:-未知})"; }

if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 A0: 前像/前置不成立(含 DNS 仪器未通过标定), 本段未执行"
else
A0_INV="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
A0_PID="$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)"
A0_UNIT="$(sha256sum /etc/systemd/system/pdg-mitm.service | awk '{print $1}')"
A0_SCHEMA="$(python3 -c 'import json;print(json.load(open("/etc/privdns-gateway/ios-profile.json")).get("schema"))' 2>/dev/null)"
A0_HIJ="$(sha256sum /etc/mosdns/rules/mitm_hijack.txt | awk '{print $1}')"
A0_DNS="$(dns_feature_probe A0-before)"
note "A0: 前像的 DNS 行为特征 = $A0_DNS"
# 装候选(测试前置), 并把部署身份与历史残留**分开**核验
install_candidate ios >/dev/null || bad "A0: 装候选失败"
switch_repo_to_candidate ios >/dev/null 2>&1 || true
systemctl daemon-reload
assert_candidate_identity ios
echo
echo "── 只跑新版 __migrate(不带前像句柄, 正是旧 CLI 子进程的形态) ──"
MG="$(bash /usr/local/bin/pdg __migrate 2>&1)"; MGRC=$?
printf '%s\n' "$MG" | _ev 03-A0-migrate.log
_evn 03-A0-migrate.log "### rc=$MGRC"
echo "$MG" | tail -30 | sed 's/^/    /'
grep -q '不执行 WLOC 退役迁移: 调用方不具备可靠回滚能力' <<<"$MG" \
  && ok "A0-1: 门在这一刻**拒绝**了(无句柄调用)" || bad "A0-1: 没看到拒绝"
[[ "$MGRC" != 0 ]] && ok "A0-1: __migrate 返回非 0(实得 $MGRC)" || bad "A0-1: 返回 0"
echo "── 拒绝这一刻的现场(**没有任何回滚覆盖过**) ──"
[[ "$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)" == "$A0_INV" ]] \
  && ok "A0-2: pdg-mitm 的 InvocationID 未变($A0_INV) —— 它没有被停过" || bad "A0-2: InvocationID 变了"
[[ "$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)" == "$A0_PID" ]] \
  && ok "A0-2: MainPID 未变($A0_PID) —— 还是同一个进程" || bad "A0-2: MainPID 变了"
[[ "$(sc_state is-active pdg-mitm)" == active ]] && ok "A0-2: pdg-mitm 仍在运行" || bad "A0-2: pdg-mitm 不在运行"
[[ "$(sc_state is-enabled pdg-mitm)" == enabled ]] && ok "A0-2: 自启仍是 enabled(没有被 disable 过)" || bad "A0-2: 自启=$(sc_state is-enabled pdg-mitm)"
[[ "$(sha256sum /etc/systemd/system/pdg-mitm.service 2>/dev/null | awk '{print $1}')" == "$A0_UNIT" ]] \
  && ok "A0-2: pdg-mitm unit 还在盘上且逐字节未变" || bad "A0-2: unit 被动过"
[[ -e /opt/pdg-bot/mitm_server.py && -e /opt/pdg-bot/mitm_wloc.py ]] \
  && ok "A0-2: 两个 WLOC 执行件都还在" || bad "A0-2: 执行件被删了"
[[ "$(python3 -c 'import json;print(json.load(open("/etc/privdns-gateway/ios-profile.json")).get("schema"))' 2>/dev/null)" == "$A0_SCHEMA" ]] \
  && ok "A0-2: iOS 记录仍是 schema $A0_SCHEMA(格式没有被推进)" || bad "A0-2: schema 被推进了"
[[ "$(sha256sum /etc/mosdns/rules/mitm_hijack.txt | awk '{print $1}')" == "$A0_HIJ" ]] \
  && ok "A0-2: 接管表逐字节未变" || bad "A0-2: 接管表被动过"
A0_DNS_AFTER="$(dns_feature_probe A0-after)"
if [[ "$DNS_INSTRUMENT_OK" == 1 ]]; then
  [[ "$A0_DNS_AFTER" == "$A0_DNS" ]] \
    && ok "A0-3: 已加载配置: 拒绝前后 DNS 行为特征一致($A0_DNS_AFTER) —— 解析器没有被改过" \
    || bad "A0-3: DNS 行为变了($A0_DNS → $A0_DNS_AFTER)"
else
  note "A0-3: DNS 仪器未通过标定 —— 「前后一致」在一个对任何域名都同答案的环境里说明不了问题, 只留档($A0_DNS → $A0_DNS_AFTER)。"
  note "  「解析器没有被改过」这一条改由上面的接管表逐字节比对承担。"
fi
ss -lnt 2>/dev/null | grep -q ':7894 ' && ok "A0-3: 7894 仍有监听" || bad "A0-3: 7894 没有监听"
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "③ 场景 A —— 原版旧 CLI 直接跳退役候选: 被门拒绝, 再由原版自己回滚"
# ═════════════════════════════════════════════════════════════════════════════
note "前像构造方式: 旧版(v1.11.15)自己的模块、unit 模板与渲染器 + 自造证书/配置。"
note "**这是「旧版文件与服务构造的前像」, 不是「完整执行过旧安装器 install.sh」。** 两者本报告分开记。"
build_preimage ios on
# 前像先达到合法稳定状态再采样。pdg-bot 没有凭据 —— 用**产品支持的停用态**, 不造假凭据、
# 不为了凑 active 起一个起不来的服务。
systemctl disable pdg-bot >/dev/null 2>&1 || true
systemctl stop    pdg-bot >/dev/null 2>&1 || true
# enabled-runtime 选一个**能稳定运行的真实受管服务**: pdg-probe81。
systemctl disable pdg-probe81 >/dev/null 2>&1 || true
systemctl enable --runtime pdg-probe81 >/dev/null 2>&1 || true
systemctl start pdg-probe81 >/dev/null 2>&1 || true
for _u in pdg-mitm mosdns mihomo pdg-probe81 pdg-bot; do
  printf '    %-14s 稳定后 ActiveState=%s UnitFileState=%s\n' "$_u" "$(wait_stable "$_u")" \
    "$(systemctl show -p UnitFileState --value "$_u" 2>/dev/null)"
done
[[ "$(sc_state is-enabled pdg-probe81)" == enabled-runtime ]] \
  && ok "A: 前像里 pdg-probe81 的自启是 enabled-runtime(真 systemd 实测)" \
  || bad "A: pdg-probe81 自启=$(sc_state is-enabled pdg-probe81), 不是 enabled-runtime"
{ [[ "$(sc_state is-active pdg-bot)" != active && "$(sc_state is-enabled pdg-bot)" != enabled ]]; } \
  && ok "A: 前像里 pdg-bot 是产品支持的停用态(没配凭据; 不造假凭据)" \
  || bad "A: pdg-bot 不是停用态(active=$(sc_state is-active pdg-bot) enabled=$(sc_state is-enabled pdg-bot))"
assert_preimage_A
: > "$RESIDUE_MANIFEST"
residue_record /etc/systemd/system/pdg-mitm.service "v1.11.15 的 unit 模板(pdg_write_unit pdg_unit_pdg_mitm)"
residue_record /opt/pdg-bot/mitm_server.py         "v1.11.15 源码树 deploy/bot/mitm_server.py"
residue_record /opt/pdg-bot/mitm_wloc.py           "v1.11.15 源码树 deploy/bot/mitm_wloc.py"
residue_record /etc/mosdns/rules/mitm_hijack.txt   "旧版接管表(WLOC 自有域名)"
residue_record /etc/privdns-gateway/mitm.json      "旧版 WLOC 配置(enabled=true + 用户地点)"
residue_record /etc/privdns-gateway/ios-profile.json "旧版 schema-1 记录"
residue_report
snap_state A-before
fp_capture A-before
svc_snapshot "$E2E_TMP/svc-A-before.tsv"
A_DNS_BEFORE="$(dns_feature_probe A-before)"
note "A: 前像的 DNS 行为特征 = $A_DNS_BEFORE"

if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 A: 前像不成立, 本场景未执行(既不算通过也不算产品失败)"
else

PDG_SHA_BEFORE="$(sha256sum /usr/local/bin/pdg | awk '{print $1}')"
OLD_PDG_SHA="$(sha256sum "$OLDSRC/deploy/bot/pdg.sh" | awk '{print $1}')"
[[ "$PDG_SHA_BEFORE" == "$OLD_PDG_SHA" ]] \
  && ok "A: 升级前 /usr/local/bin/pdg 逐字节等于 v1.11.15 的 deploy/bot/pdg.sh(更新器确实是原版)" \
  || bad "A: 更新器不是原版(装的 $PDG_SHA_BEFORE vs 旧版 $OLD_PDG_SHA)"
MITM_INV_BEFORE="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
MITM_PID_BEFORE="$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)"
MITM_NR_BEFORE="$(systemctl show -p NRestarts --value pdg-mitm 2>/dev/null)"
note "A: 前像里 pdg-mitm  MainPID=$MITM_PID_BEFORE  InvocationID=$MITM_INV_BEFORE  NRestarts=$MITM_NR_BEFORE"
JSTART="$(date -u +%FT%T)"

echo "── 旧 CLI 的 dry-run(先看它怎么判关系) ──"
DRY="$(bash /usr/local/bin/pdg update --dry-run 2>&1)"; DRC=$?
printf '%s\n' "$DRY" | _ev 03-A-dryrun.txt
echo "$DRY" | sed 's/^/    /' | head -20
[[ "$DRC" == 0 ]] && ok "A: dry-run rc=0" || bad "A: dry-run rc=$DRC"
grep -q "$TEST_TAG" <<<"$DRY" && ok "A: dry-run 认出目标是本轮的测试候选 tag" || bad "A: dry-run 没认出目标 tag"

echo; echo "── 真正跑**原版** pdg update(它会取件、装候选、调新版 __migrate, 被拒后调自己的 cmd_rollback) ──"
UP="$(bash /usr/local/bin/pdg update 2>&1)"; URC=$?
svc_snapshot "$E2E_TMP/svc-A-after.tsv"
printf '%s\n' "$UP" | _ev 03-A-update.log
_evn 03-A-update.log "### 原始升级退出码 rc=$URC"
echo "$UP" | tail -60 | sed 's/^/    /'
snap_state A-after
fp_capture A-after
state_diff A-before A-after A

echo
echo "── A-1. 退役门的拒绝是否成立 ──"
grep -q '不执行 WLOC 退役迁移: 调用方不具备可靠回滚能力' <<<"$UP" \
  && ok "A-1: 退役门**拒绝成立**(候选打出了拒绝抬头)" || bad "A-1: 没有看到门的拒绝抬头"
grep -q '没有交出本次操作的服务前像句柄' <<<"$UP" \
  && ok "A-1: 拒绝理由是「调用方没有交出本次操作的服务前像句柄」—— 正是旧 CLI 的形态" \
  || bad "A-1: 拒绝理由不是预期的那一条: $(grep -o '原因: .*' <<<"$UP" | head -1)"
grep -q '尚未执行任何退役副作用' <<<"$UP" && ok "A-1: 拒绝文案说明了此刻尚未执行退役副作用" || bad "A-1: 文案缺现场说明"
grep -q '新版文件已经装上了' <<<"$UP" && ok "A-1: 文案**没有**谎称整机未改动(点明新版文件已装)" || bad "A-1: 文案不准"
grep -q '已可完整回滚' <<<"$UP" && bad "A-1: 未经实测就承诺已可完整回滚" || ok "A-1: 没有未经实测地承诺完整回滚"

echo
echo "── A-2. 阶段关系: 拒绝在前, 回滚在后(整段判据只作辅助) ──"
note "本段**不再**要求「整个过程 pdg-mitm 的 PID / InvocationID 不变」或「journal 里没有停止记录」——"
note "  原版回滚里那句 `systemctl is-enabled pdg-mitm && { reset-failed; restart pdg-mitm; }`"
note "  在自启仍是 enabled 时**会触发**, 于是它自己就会重启一次。那属于「允许旧回滚执行其既有"
note "  重启动作」, 必须列明(见 A-5), 不能当成「被退役停过」。"
note "  「拒绝前没有撤除」这件事由上面的**场景 A0 阶段观测**单独给出; 这里只核对先后顺序。"
LN_REFUSE="$(grep -n '不执行 WLOC 退役迁移' <<<"$UP" | head -1 | cut -d: -f1)"
LN_ROLL="$(grep -n '回滚到更新前快照' <<<"$UP" | head -1 | cut -d: -f1)"
{ [[ -n "$LN_REFUSE" && -n "$LN_ROLL" && "$LN_REFUSE" -lt "$LN_ROLL" ]]; } \
  && ok "A-2: 同一条输出流里, 拒绝(第 $LN_REFUSE 行)排在回滚(第 $LN_ROLL 行)**之前**" \
  || bad "A-2: 先后关系取不到或反了(拒绝=$LN_REFUSE, 回滚=$LN_ROLL)"
grep -q 'iOS 描述文件记录已迁移到新格式' <<<"$UP" \
  && bad "A-2: 日志里出现了「记录已迁移到新格式」—— schema 被推进过" \
  || ok "A-2: 日志里没有「记录已迁移到新格式」—— schema 没有被推进"
grep -qE '已清理 iOS 专属残留|WLOC 退役: 已' <<<"$UP" \
  && bad "A-2: 日志里出现了退役完成类输出" || ok "A-2: 日志里没有退役完成类输出"
# 辅助(不单独作证): 自启仍是 enabled ⇒ 从没被 disable 过 —— 快照不收 wants/, disable 补不回来。
[[ "$(sc_state is-enabled pdg-mitm)" == enabled ]] \
  && ok "A-2(辅助): 回滚后自启仍是 enabled —— 退役那一步的 disable 从未发生(快照不收 wants/, 补不回来)" \
  || note "A-2(辅助): 回滚后自启=$(sc_state is-enabled pdg-mitm)"
journalctl -u pdg-mitm --since "$JSTART" --no-pager 2>/dev/null | _ev 03-A-journal-pdg-mitm.txt
note "A-2: pdg-mitm 的 journal 已留证(03-A-journal-pdg-mitm.txt), 作为回滚重启动作的记录, 不作判据。"

echo "── A-3. 随后的**原版**回滚是否实际执行 ──"
grep -q '回滚到更新前快照' <<<"$UP" && ok "A-3: 升级失败后触发了回滚" || bad "A-3: 没有触发回滚"
grep -qE '✅ 已回滚并重启服务|已回滚配置/服务' <<<"$UP" && ok "A-3: 回滚跑到了它自己的收尾输出" || bad "A-3: 回滚没有收尾输出"
# 执行的是**原版**回滚: 候选那一版会打出"内核收敛:"与"服务前像"字样, 原版没有这些。
if grep -qE '内核收敛:|服务前像缺失/不可用|这份快照没有服务前像' <<<"$UP"; then
  bad "A-3: 日志里出现了**候选版**回滚特有的字样 —— 执行的不是原版 cmd_rollback"
else
  ok "A-3: 日志里没有候选版回滚特有的字样(内核收敛/服务前像) —— 执行的是原版 cmd_rollback"
fi
note "A-3: 原版回滚跑在**同一个旧 bash 进程**里(函数体在定义时就已解析进内存), 这一条由构造保证;"
note "     上面那条判据是它在真机上的独立佐证。"

echo
echo "── A-4. 原版回滚的四维结果(逐项比对前像) ──"
fp_cmp_files A-before A-after "A-4 文件"
for u in "${FP_SVCS[@]}"; do
  b="$(fp_get A-before S "$u" | cut -f1)"; a="$(fp_get A-after S "$u" | cut -f1)"
  eb="$(fp_get A-before S "$u" | cut -f2)"; ea="$(fp_get A-after S "$u" | cut -f2)"
  if [[ "$b" == "$a" ]]; then ok "A-4 运行态: $u 回到前像($a)"; else bad "A-4 运行态: $u 前像=$b 现在=$a"; fi
  if [[ "$eb" == "$ea" ]]; then ok "A-4 自启态: $u 回到前像($ea)"; else bad "A-4 自启态: $u 前像=$eb 现在=$ea"; fi
done
L7894_B="$(fp_get A-before L 7894)"; L7894_A="$(fp_get A-after L 7894)"
[[ "$L7894_B" == "$L7894_A" ]] \
  && ok "A-4 已加载配置(独立依据): 7894 的真实监听数与前像一致($L7894_A) —— 服务确实在按恢复出来的配置提供服务" \
  || bad "A-4 已加载配置: 7894 监听数 前像=$L7894_B 现在=$L7894_A"
# 产品自己写下的前像与测试指纹逐项对账(两边必须看到同一件事)
A_SNAP="$(ls -1dt "${SNAP_DIR:-/var/lib/privdns-gateway/backups}"/* 2>/dev/null | head -1)"
if [[ -n "$A_SNAP" && -s "$A_SNAP/svcstate.tsv" ]]; then
  note "A-4: 产品写的前像 = $A_SNAP/svcstate.tsv"
  svcstate_cross_check "$A_SNAP/svcstate.tsv" "A-4"
else
  note "A-4: 这一轮没找到产品写的 svcstate.tsv(旧 CLI 的快照本来就没有这一份, 属预期)"
fi
A_DNS_AFTER="$(dns_feature_probe A-after)"
if [[ "$DNS_INSTRUMENT_OK" == 1 ]]; then
  [[ "$A_DNS_AFTER" == "$A_DNS_BEFORE" ]] \
    && ok "A-4 已加载配置(可区分行为): 恢复后 DNS 特征与前像一致($A_DNS_AFTER)" \
    || bad "A-4 已加载配置: DNS 特征变了($A_DNS_BEFORE → $A_DNS_AFTER)"
  A_HIJ_ANS="${A_DNS_AFTER%% ::*}"; A_CTL_ANS="${A_DNS_AFTER##*:: }"
  [[ -n "$A_HIJ_ANS" && "$A_HIJ_ANS" != "$A_CTL_ANS" ]] \
    && ok "A-4 已加载配置(对照): 被接管的域名与对照域名结果**不同**($A_HIJ_ANS vs $A_CTL_ANS) —— 特征确实在起作用" \
    || bad "A-4 已加载配置: 接管域与对照域结果相同($A_HIJ_ANS vs $A_CTL_ANS), 这条特征证明不了配置被加载"
else
  note "A-4 已加载配置: DNS 仪器**未通过标定**, 本轮不拿它作证据(实测 $A_DNS_BEFORE → $A_DNS_AFTER, 仅留档)。"
  note "  「配置已加载」这一维在场景① 因此**仍未取得**证据 —— 不用 NOERROR 顶替。"
fi
L53_B="$(fp_get A-before L 53)"; L53_A="$(fp_get A-after L 53)"
[[ "$L53_B" == "$L53_A" ]] && ok "A-4(辅助) 53/udp 监听数与前像一致($L53_A)" || bad "A-4(辅助) 53 监听 $L53_B → $L53_A"
if command -v dig >/dev/null 2>&1; then
  DR="$(dig +time=3 +tries=1 @127.0.0.1 example.com A 2>&1 | head -20)"
  printf '%s\n' "$DR" | _ev 03-A-dig.txt
  grep -qE 'status: (NOERROR|NXDOMAIN)' <<<"$DR" \
    && ok "A-4(辅助) 本机 53 真的能应答(status=$(grep -o 'status: [A-Z]*' <<<"$DR" | head -1)) —— 只说明解析器活着, **不**说明加载的是哪一份配置" \
    || note "A-4(辅助) 本机 53 未能应答(runner 出网受限时属预期, 已留证不作判据)"
fi

echo
echo "── A-5. 服务动作对账(原版回滚允许它重启服务, 这里逐项列明) ──"
svc_verdict "$E2E_TMP/svc-A-before.tsv" "$E2E_TMP/svc-A-after.tsv" A
note "A-5: 「门前零退役动作」与「整个拒绝—回滚过程零服务动作」是两件事 —— 上面列出的就是"
note "     整个过程里实际发生的服务动作; 本报告不把前者写成后者。"

echo
echo "── A-6. 退出码与用户看到的文字 ──"
_evn 03-A-update.log "### 原始升级 rc=$URC"
[[ "$URC" != 0 ]] && ok "A-6: 原始升级退出码非 0(实得 $URC) —— 失败没有被报成成功" || bad "A-6: 升级返回 0"
RB_LINE="$(grep -E '✅ 已回滚并重启服务|已回滚配置/服务.*未完全回滚' <<<"$UP" | head -1)"
note "A-6: 回滚收尾文字: ${RB_LINE:-<没有>}"
_evn 03-A-update.log "### 回滚收尾文字: ${RB_LINE:-<没有>}"
if grep -q '✅ 已回滚并重启服务' <<<"$UP"; then
  # 原版回滚自报完全成功 —— 那么上面四维必须真的全回来; 若没有, 那是**产品缺陷**, 如实留证。
  note "A-6: 原版回滚自报「已回滚并重启服务」。四维结果以上面 A-4 的逐项判据为准。"
fi
fi

# ═════════════════════════════════════════════════════════════════════════════
SECT "④ 收尾"
# ═════════════════════════════════════════════════════════════════════════════
{
  echo "# 本轮在这台一次性 runner 上创建/改动的东西(具名, 便于核对)"
  echo "  · /etc/systemd/system/{mosdns,mihomo,pdg-bot,pdg-probe81,pdg-mitm,pdg-health}.{service,timer}"
  echo "  · /etc/{mosdns,mihomo,sing-box,privdns-gateway}/, /opt/{pdg-bot,privdns-gateway}, /var/lib/privdns-gateway"
  echo "  · 自有探针 unit(已具名删除), 自有 nft table pdg_e2e_probe(已具名删除)"
  echo "  · 自有裸库 $ORIGIN, 旧版源码树 $OLDSRC(都在本轮 \$E2E_TMP 里, 退出钩子清理)"
  echo "  · 停用了 runner 自带的 systemd-resolved(为释放 :53)"
  echo "  全部落在这台一次性 runner 上; runner 随 job 结束销毁。只清本轮自有资源, 不按前缀宽删。"
  echo
  echo "# 身份"
  echo "  旧版 OLD_SHA   = $OLD_SHA"
  echo "  候选 CAND_SHA  = $CAND_SHA"
  echo "  验收 checkout  = ${GITHUB_SHA:-<非 CI>}"
  echo
  echo "# 证据文件"
  ls -1 "$EVID" | sed 's/^/  /'
} | _ev 99-cleanup.txt
chmod 600 "$EVID"/* 2>/dev/null || true

echo
echo "未执行(前像不成立而跳过)的场景数: $E2E_NOTRUN"
_evn 99-cleanup.txt "未执行场景数: $E2E_NOTRUN"
e2e_summary

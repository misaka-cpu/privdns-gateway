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
SC_VAL=""; SC_ERR=""
sc_get(){   # $1=子命令(is-active|is-enabled|...)  $2=unit
  local errf="${E2E_TMP:-/tmp}/sc.err"
  SC_VAL="$(systemctl "$1" "$2" 2>"$errf")"
  SC_ERR="$(tr '\n' ' ' < "$errf" 2>/dev/null)"
  rm -f "$errf" 2>/dev/null || true
}
# 把"这个 unit 现在到底算什么状态"归一成一个词, 并把判定依据保留下来:
#   active / inactive / failed / activating / …  或  not-found(unit 压根不在)
sc_state(){  # $1=子命令 $2=unit → 打印归一后的词; 依据留在 SC_VAL/SC_ERR(不看退出码; 四维取证改用下面的 r1_unit_q, 见 341)
  sc_get "$1" "$2"
  if [[ -z "${SC_VAL//[[:space:]]/}" ]]; then
    case "$SC_ERR" in *"No such file"*|*"not-found"*|*"could not be found"*) printf 'not-found\n';;
                      *) printf '<空>\n';; esac
  else
    printf '%s\n' "${SC_VAL%%$'\n'*}"
  fi
}
# 341: 四维取证用的单元查询。与 ③ 的 r3_unit_q(tests/e2e-real-retire-hop.sh)同一套配对规则 —— 状态词与**原始退出码**必须成对:
#   合法的非零码照收(不在运行 3; 未启用 / 不存在 非零; systemd 255 对 LoadState=not-found 的 is-active 用 4);
#   先打印一个词再以不合规的码退出 = 观测无效, 那个词不采信; 输出必须恰一行。
#   在**本壳**里调用(不放进命令替换), 结果留在 R1_VAL / R1_RC / R1_WHY —— sc_state 放在 $(…) 里时 SC_RC 回不到调用方(341 复现 R1)。
R1_VAL=""; R1_RC=""; R1_WHY=""
r1_unit_q(){   # $1=active|enabled|load $2=unit [$3=同一 unit 已有效取得的 LoadState] → 0 取得(R1_VAL) / 2 观测无效(R1_WHY)
  local k="$1" u="$2" out rc err ef="${E2E_TMP:-/tmp}/r1unitq.err"; R1_VAL=""; R1_RC=""
  case "$k" in
    active)  out="$(systemctl is-active "$u" 2>"$ef")"; rc=$?;;
    enabled) out="$(systemctl is-enabled "$u" 2>"$ef")"; rc=$?;;
    load)    out="$(systemctl show -p LoadState --value "$u" 2>"$ef")"; rc=$?;;
    *) R1_WHY="r1_unit_q 不认识的查询 [$k]"; return 2;;
  esac
  R1_RC="$rc"
  err="$(tr '\n' ' ' < "$ef" 2>/dev/null)"; rm -f "$ef" 2>/dev/null || true
  [[ "$out" != *$'\n'* ]] || { R1_WHY="$u 的 $k 查询输出不止一行([${out//$'\n'/|}], rc=$rc)"; return 2; }
  case "$k" in
    active)
      case "$out" in
        active|reloading|refreshing) (( rc == 0 )) || { R1_WHY="$u is-active 打印 $out 却退出 $rc(应为 0)"; return 2; };;
        inactive) (( rc == 3 )) || { (( rc == 4 )) && [[ "${3:-}" == not-found ]]; } \
            || { R1_WHY="$u is-active 打印 inactive 却退出 $rc(应为 3; 只有已取得 LoadState=not-found 时才可为 4, 实得 LoadState=[${3:-未提供}])"; return 2; };;
        failed|activating|deactivating|maintenance) (( rc == 3 )) || { R1_WHY="$u is-active 打印 $out 却退出 $rc(应为 3)"; return 2; };;
        *) R1_WHY="$u is-active 输出不是状态词([${out:0:30}], rc=$rc, stderr: ${err:-无})"; return 2;;
      esac;;
    enabled)
      case "$out" in
        enabled|enabled-runtime|alias|static|indirect|generated|transient) (( rc == 0 )) || { R1_WHY="$u is-enabled 打印 $out 却退出 $rc(应为 0)"; return 2; };;
        linked|linked-runtime|masked|masked-runtime|disabled|not-found) (( rc != 0 )) || { R1_WHY="$u is-enabled 打印 $out 却退出 0(应非零)"; return 2; };;
        "") if (( rc != 0 )) && [[ "$err" == *"No such file or directory"* ]]; then out=not-found     # systemd 252 对不存在的 unit 只在 stderr 报这句
            else R1_WHY="$u is-enabled 没有输出(rc=$rc, stderr: ${err:-无})"; return 2; fi;;
        *) R1_WHY="$u is-enabled 输出不是状态词([${out:0:30}], rc=$rc, stderr: ${err:-无})"; return 2;;
      esac;;
    load)
      (( rc == 0 )) || { R1_WHY="$u 的 LoadState 查询退出 $rc(输出 [${out:0:30}] 不采信)"; return 2; }
      case "$out" in loaded|not-found|bad-setting|error|masked|merged|stub) ;;
        *) R1_WHY="$u 的 LoadState 不是状态词([${out:0:30}])"; return 2;; esac;;
  esac
  R1_VAL="$out"
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
R1_BOTDIR=/opt/pdg-bot             # 342: A0 装候选与身份核对用的模块目录(值不变; 只是不再散写字面量)
R1_CLI=/usr/local/bin/pdg          # 341: 场景 A / A0 的产品调用与旧版身份核对都指这一个入口(值不变, 只是不再散写字面量)
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

# 341(M1): 撤掉"验收分支产品面必须等于候选"这条前提 —— 本验收分支建在更早的候选之上, 产品面与 CAND_SHA 本来就不同;
#   而 ① 里验收分支的产品文件**从不上机**: 前像与旧 CLI 取自 OLDSRC / 裸库里的 OLD_SHA, A0 的候选取自 CANDSRC,
#   A 的候选由旧 CLI 从裸库测试 tag 取件(tag → CAND_SHA 上面已硬核)。所以差异只**如实登记**(连同查询退出码), 不作判据;
#   真正的来源判据是下面 r1_src_check 的两条逐文件对象身份 —— 不成立就阻断用到它的那一次产品调用(r1_a0_invoke / r1_a_invoke)。
r1_diff_note(){   # $1=说明 $2..=git diff 的参数 → 只登记
  local what="$1" out rc; shift
  out="$(git -C "$E2E_ROOT_REAL" diff --name-only "$@" 2>/dev/null)"; rc=$?
  if (( rc == 0 )); then
    out="$(tr '\n' ' ' <<<"$out")"; _evn 02-source-map.txt "$what: ${out:-<无>}"; note "$what(只登记): ${out:-<无>}"
  else
    _evn 02-source-map.txt "$what: 查询失败(git diff rc=$rc)"; note "$what: 查询失败(git diff rc=$rc) —— 没登记到"
  fi
}
r1_diff_note "验收分支相对候选的产品面差异(这些文件在 ① 里不上机)" "$CAND_SHA" -- deploy lib install.sh uninstall.sh tools
r1_diff_note "验收分支相对候选的全部改动" "$CAND_SHA"
r1_diff_note "产品候选 X 相对 base 的产品面改动" "$CAND_BASE" "$CAND_SHA" -- deploy lib install.sh uninstall.sh tools
r1_diff_note "验收分支 Y 相对 base 的全部改动" "$CAND_BASE"
# 源码树 ⇔ 提交: 产品面(deploy lib install.sh uninstall.sh tools)每个文件与该提交里的对象逐一相同。
# 0 一致 / 1 有文件缺失或不同 / 2 读取失败(清单、摘要或条数任一取不到 —— 失败前输出的内容不采信)
r1_src_identity(){   # $1=源码树 $2=提交 → R1_WHY
  local dir="$1" sha="$2" ls rc l meta path m t o n i
  local -a paths=() objs=() got=()
  ls="$(git -C "$ORIGIN" ls-tree -r "$sha" -- deploy lib install.sh uninstall.sh tools 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ -n "$ls" ]]; } || { R1_WHY="读不到 ${sha:0:12} 的产品面文件清单(ls-tree rc=$rc)"; return 2; }
  while IFS= read -r l; do
    meta="${l%%$'\t'*}"; path="${l#*$'\t'}"
    read -r m t o <<<"$meta"
    { [[ "$t" == blob && "$m" != 120000 && "$o" =~ ^[0-9a-f]{40}$ ]]; } || { R1_WHY="清单里有本判据不覆盖的项([$l])"; return 2; }
    { [[ -f "$dir/$path" && ! -L "$dir/$path" ]]; } || { R1_WHY="源码树里缺 $path"; return 1; }
    paths+=("$dir/$path"); objs+=("$o")
  done <<<"$ls"
  n=${#paths[@]}
  printf '%s\n' "${paths[@]}" > "$E2E_TMP/r1src.paths" || { R1_WHY="写不下路径清单"; return 2; }
  git hash-object --no-filters --stdin-paths < "$E2E_TMP/r1src.paths" > "$E2E_TMP/r1src.objs" 2>/dev/null; rc=$?
  (( rc == 0 )) || { R1_WHY="计算源码树的对象摘要失败(hash-object rc=$rc)"; return 2; }
  mapfile -t got < "$E2E_TMP/r1src.objs" || { R1_WHY="读不回对象摘要"; return 2; }
  (( ${#got[@]} == n )) || { R1_WHY="对象摘要条数 ${#got[@]} ≠ 文件数 $n"; return 2; }
  for ((i=0; i<n; i++)); do
    [[ "${got[$i]}" == "${objs[$i]}" ]] \
      || { R1_WHY="${paths[$i]#"$dir"/} 与提交里的对象不同(实得 ${got[$i]:0:12}, 应为 ${objs[$i]:0:12})"; return 1; }
  done
  R1_WHY="$n 个文件逐个与 ${sha:0:12} 的对象相同"
  return 0
}
R1_SRC_OLD=0; R1_SRC_CAND=0
r1_src_check(){   # 核两棵源码树, 置 R1_SRC_OLD / R1_SRC_CAND(1 成立 / 0 不成立或未核实), 逐条打 ok / bad
  local r
  r1_src_identity "$OLDSRC" "$OLD_SHA"; r=$?
  case "$r" in
    0) R1_SRC_OLD=1; ok "来源: 旧版源码树(前像与旧 CLI 取自这里)与 OLD_SHA 逐文件对象相同 —— $R1_WHY";;
    1) R1_SRC_OLD=0; bad "来源: 旧版源码树与 OLD_SHA 不符 —— $R1_WHY; 用到它的产品调用(A0 / A)一律不执行";;
    *) R1_SRC_OLD=0; bad "来源: 旧版源码树的身份读取失败 —— $R1_WHY; 未核实, 用到它的产品调用(A0 / A)一律不执行";;
  esac
  r1_src_identity "$CANDSRC" "$CAND_SHA"; r=$?
  case "$r" in
    0) R1_SRC_CAND=1; ok "来源: 冻结候选源码树(A0 装候选取自这里)与 CAND_SHA 逐文件对象相同 —— $R1_WHY";;
    1) R1_SRC_CAND=0; bad "来源: 冻结候选源码树与 CAND_SHA 不符 —— $R1_WHY; A0 的 __migrate 不执行";;
    *) R1_SRC_CAND=0; bad "来源: 冻结候选源码树的身份读取失败 —— $R1_WHY; 未核实, A0 的 __migrate 不执行";;
  esac
  _evn 02-source-map.txt "来源核对: 旧版源码树=$R1_SRC_OLD 候选源码树=$R1_SRC_CAND(1 成立 / 0 不成立或未核实)"
}
r1_src_check

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
  # 346: 重建前像会重新播种 mosdns(下面的 e2e_seed_mosdns all), 之前任何场景建立的 DNS 条件与标定随之失效 ——
  #      先作废, 由本场景自己重新建立(r1_dns_premise); 不继承上一场景的成功标志(345: A0 的标定放行了 A)。
  r1_dns_invalidate
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
  # 346: 这段 python 以前自己定义 ok()/bad(), 只打印、不进计数, 判 FAIL 也不让前像不成立(345: [OK] 行 121 条对"通过 119")。
  #      现在它只输出**一行**结构化结论(R1PY<TAB>种类<TAB>说明), 由外层按"退出码 + 结论行"一起结算:
  #      业务相符 = 0 + OK; 业务不符 = 10 + FAIL; 读不到记录 = 11 + READFAIL。其它退出码(未捕获的异常、被杀)、
  #      结论行缺失 / 不止一行 / 与退出码对不上, 一律按"自检异常"判失败。三种失败都让前像不成立(随后的产品调用不执行)。
  local pyf="${E2E_TMP:-/tmp}/r1-preimage-py.out" pyrc pyn pyl pyk pyt grc
  python3 - > "$pyf" 2>&1 <<'PY'
import json, sys
def emit(kind, text, code):
    sys.stdout.write("R1PY\t%s\t%s\n" % (kind, str(text).replace("\t", " ").replace("\n", " ")))
    sys.stdout.flush()
    sys.exit(code)
try:
    m = json.load(open("/etc/privdns-gateway/ios-profile.json", encoding="utf-8"))
except Exception as e:
    emit("READFAIL", "读不到 iOS 记录: %s" % e, 11)
if "inputs" in m:
    emit("FAIL", "顶层出现了 inputs 字段, 与 schema 1 契约不符", 10)
cur = m.get("current")
if not isinstance(cur, dict):
    emit("FAIL", "current 不是记录对象(实得 %s)" % type(cur).__name__, 10)
inp = cur.get("inputs")
if not isinstance(inp, dict):
    emit("FAIL", "current.inputs 不存在", 10)
fail = []
if m.get("schema") != 1:               fail.append("schema=%r(应为 1)" % m.get("schema"))
if inp.get("wloc_enabled") is not True: fail.append("current.inputs.wloc_enabled=%r(应为 True)" % inp.get("wloc_enabled"))
if not inp.get("wloc_ca_sha256"):       fail.append("current.inputs.wloc_ca_sha256 为空")
ss = inp.get("ssids")
if not (isinstance(ss, list) and len(ss) > 0):
    fail.append("SSID 意图不是非空列表(实得 %r)" % (ss,))
if fail:
    emit("FAIL", "; ".join(fail), 10)
emit("OK", "iOS 记录是 schema 1, current.inputs 带 WLOC 字段与 CA 指纹, 且 SSID 意图非空(%r)" % (ss,), 0)
PY
  pyrc=$?
  pyn="$(grep -c '^R1PY' "$pyf" 2>/dev/null)"; grc=$?
  if (( grc > 1 )) || [[ ! "$pyn" =~ ^[0-9]+$ ]]; then
    bad "前像: iOS 记录自检的输出读不回(grep 退出 $grc) —— 前像不成立"; PREIMAGE_OK=0
  elif (( pyn != 1 )); then
    bad "前像: iOS 记录自检异常(退出 $pyrc, 结论行 $pyn 条; 末尾输出: $(tail -2 "$pyf" 2>/dev/null | tr '\n' ' ')) —— 前像不成立"; PREIMAGE_OK=0
  else
    pyl="$(grep '^R1PY' "$pyf" 2>/dev/null)"; grc=$?
    IFS=$'\t' read -r _ pyk pyt <<<"$pyl"
    case "$grc:$pyrc:$pyk" in
      0:0:OK)        ok "前像: $pyt";;
      0:10:FAIL)     bad "前像: iOS 记录形态不对 —— $pyt; 前像不成立"; PREIMAGE_OK=0;;
      0:11:READFAIL) bad "前像: $pyt —— 观测无效, 前像不成立"; PREIMAGE_OK=0;;
      *)             bad "前像: iOS 记录自检异常(退出 $pyrc, 结论 [${pyk:-无}], 读取 $grc) —— 前像不成立"; PREIMAGE_OK=0;;
    esac
  fi
  local art=/var/lib/privdns-gateway/ios-profile/current.mobileconfig
  if [[ -s "$art" ]]; then
    grep -q 'com.apple.security.root' "$art" \
      && ok "前像: 描述文件产物里**确实嵌着**根证书 payload" \
      || bad "前像: 产物里没有根证书 payload(前像不真实)"
  else
    bad "前像: 没有描述文件产物"
  fi
}



# ── ① 专用的服务动作依据(346)─────────────────────────────────────────────
# 以前这里沿用正常迁移链(run_all_migrations)的分类与理由: 于是 ① 里旧回滚对 pdg-mitm 的那次重启被记成
# 「WLOC 退役专属」并打了"确实发生"的 OK; 而前后快照相同的短暂启动(345: pdg-bot 被旧回滚拉起后自行退出)根本看不见。
# 现在的依据是**冻结旧版 cmd_update / cmd_rollback 在本场景条件下的执行路径**(行号是 v1.11.15 的 deploy/bot/pdg.sh):
#   · 旧 update 在调 __migrate(2167)之前不启停任何服务; 候选 __migrate 在迁移链之前就拒绝, 路径上只有只读查询;
#   · 随后的旧 cmd_rollback: 1487 enable --now mihomo(已 active 不重启)、1492 restart mosdns pdg-bot pdg-probe81、
#     1493 自启为 enabled 时 reset-failed + restart pdg-mitm、1494 restart systemd-journald(不在观测集合内);
#   · 2195–2197 的 enable / restart 在 __migrate 失败后到不了, 不计入。
# 写法: [unit]="Started 上限 Stopped 上限|出处与说明"。不是按 345 实际看到的变化倒补的。
declare -A R1_SVC_BASIS=(
  [mosdns]="1 1|旧回滚 1492 行 restart mosdns"
  [pdg-bot]="1 1|旧回滚 1492 行 restart pdg-bot(前像停用 ⇒ 表现为一次启动; 凭据为空时进程自行退出属其后果)"
  [pdg-probe81]="1 1|旧回滚 1492 行 restart pdg-probe81"
  [pdg-mitm]="1 1|旧回滚 1493 行: 自启为 enabled 时 reset-failed + restart —— 旧回滚的既有重启, 不是退役动作"
  [mihomo]="0 0|旧回滚 1487 行 enable --now mihomo: 前像已 active, 不重启"
  [pdg-dotwitness]="0 0|执行路径上没有它的启停"
  [pdg-health.timer]="0 0|旧 update 只装了 unit 文件; enable 那一步(2195)在 __migrate 失败后到不了"
  [sing-box]="0 0|disable --now sing-box 对不存在的 unit 没有启停"
  [pdg-rescue.socket]="0 0|本测试从不安装"
  [ssh]="0 0|本测试从不触碰"
  [cron]="0 0|本测试从不触碰"
)
# 被观察的服务集合: 依据里的 + 几个**本轮从不安装、因此绝不该变**的见证者。
SVC_WATCH=(mosdns mihomo pdg-bot pdg-probe81 pdg-dotwitness pdg-health.timer pdg-mitm
           sing-box pdg-rescue.socket ssh cron)
# 347: A-5 的实例交叉核对直接读这份快照, 所以每个属性查询都核退出码(失败 / 输出不止一行 ⇒ 该字段记 FP_BAD, 失败前的输出不采信);
#      先在内存里拼好, 删旧件后一次写出、读回核行数, 三步都成才记 SVC_SNAP_DONE[文件]=1(与 342 的 FP_DONE 同一做法)。
#      合法的空值照原样记(不存在 / 未运行的 unit 没有 InvocationID), 不与查询失败混在一起。
declare -A SVC_SNAP_DONE=()
svc_snapshot(){   # $1=落点文件 → 0 写出并读回完成 / 2 未完成
  local u p v rc line buf="" nl=0 got TAB=$'\t'
  SVC_SNAP_DONE[$1]=0
  for u in "${SVC_WATCH[@]}"; do
    line="$u"
    for p in ActiveState SubState UnitFileState MainPID InvocationID NRestarts; do
      v="$(systemctl show -p "$p" --value "$u" 2>/dev/null)"; rc=$?
      { (( rc == 0 )) && [[ "$v" != *$'\n'* && "$v" != *"$TAB"* ]]; } || v="$FP_BAD"
      line+="$TAB$v"
    done
    buf+="$line"$'\n'; nl=$((nl+1))
  done
  rm -f -- "$1" 2>/dev/null
  [[ ! -e "$1" && ! -L "$1" ]] || return 2
  printf '%s' "$buf" > "$1" 2>/dev/null || return 2
  got="$(wc -l < "$1" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ "$got" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && (( got == nl )); } || return 2
  SVC_SNAP_DONE[$1]=1
  return 0
}
# 347: 从快照里取某个 unit 的 InvocationID —— 0 取得(R1_SV, 可以是合法的空) / 2 取不到(R1_WHY: 快照未完成 / 读不回 / 缺行或重复 / 结构不完整 / 查询失败)
R1_SV=""
r1_svc_inv(){   # $1=快照文件 $2=unit
  local out rc n nf v TAB=$'\t'
  R1_SV=""
  [[ "${SVC_SNAP_DONE[$1]:-0}" == 1 ]] || { R1_WHY="快照没有在本次运行里写出完成"; return 2; }
  out="$(awk -F"$TAB" -v u="$2" '$1==u {n++; nf=NF; v=$6} END {printf "R1SV%s%d%s%d%s%s\n", FS, n, FS, nf, FS, v}' "$1" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ "$out" == "R1SV$TAB"* ]]; } || { R1_WHY="快照读不回(awk 退出 $rc)"; return 2; }
  out="${out#"R1SV$TAB"}"; n="${out%%"$TAB"*}"; out="${out#*"$TAB"}"; nf="${out%%"$TAB"*}"; v="${out#*"$TAB"}"
  [[ "$n" == 1 ]] || { R1_WHY="快照里 $2 有 ${n:-?} 行(应恰 1 行)"; return 2; }
  [[ "$nf" == 7 ]] || { R1_WHY="快照里 $2 那一行结构不完整(${nf:-?} 个字段, 应为 7)"; return 2; }
  [[ "$v" != "$FP_BAD" ]] || { R1_WHY="$2 的 InvocationID 查询失败"; return 2; }
  R1_SV="$v"
}
# 346: 窗口 = 调用前取得的 journal 游标之后(r1_a_invoke 里, 所有前置门都过了之后才取), 到调用一返回就逐 unit 查询的那一刻。
#      游标取不到 / 查询失败 ⇒ 该窗口记录未取得, 不当成"没有动作"。
R1_JCUR=""; R1_JCUR_WHY=""
r1_jcursor(){   # → 0 取得(R1_JCUR) / 2 未取得(R1_JCUR_WHY)
  local out rc c re='^[A-Za-z0-9=;_-]+$'
  R1_JCUR=""; R1_JCUR_WHY=""
  out="$(journalctl -q -n 1 --show-cursor --no-pager -o short-iso 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { R1_JCUR_WHY="取窗口起点的 journal 查询退出 $rc"; return 2; }
  c="$(sed -n 's/^-- cursor: //p' <<<"$out")"; rc=$?
  (( rc == 0 )) || { R1_JCUR_WHY="提取游标的 sed 退出 $rc(已输出的内容不采信)"; return 2; }   # 347
  c="${c##*$'\n'}"
  [[ "$c" =~ $re ]] || { R1_JCUR_WHY="取不到窗口起点的游标(输出里没有有效的 cursor 行)"; return 2; }
  R1_JCUR="$c"
}
# 347: 查询的原始退出码、证据写出是否完成、证据读取是否有效分开核: 先删旧件(删不掉就不写), 查询结果落内存再写文件, 退出码另写一份;
#      都成才记 R1WIN_W[场景/unit]=1。A-5 只读本次运行里写出完成的那几份 —— 上一次留下的旧件不采信。
declare -A R1WIN_W=()
r1_svc_collect(){   # $1=场景名 —— 调用一返回就逐 unit 取窗口内的 journal, 原样落到 $E2E_TMP(判定在 A-5)
  local u o f out qrc
  [[ -n "$R1_JCUR" ]] || return 0
  for u in "${SVC_WATCH[@]}"; do
    R1WIN_W[$1/$u]=0; o="$E2E_TMP/r1win-$1-$u.out"; f="$E2E_TMP/r1win-$1-$u.rc"
    rm -f -- "$o" "$f" 2>/dev/null
    { [[ ! -e "$o" && ! -e "$f" ]]; } || continue
    out="$(journalctl -q --no-pager -o short-iso --after-cursor="$R1_JCUR" -u "$u" 2>/dev/null)"; qrc=$?
    { [[ -z "$out" ]] || printf '%s\n' "$out"; } > "$o" 2>/dev/null || continue
    printf '%s\n' "$qrc" > "$f" 2>/dev/null || continue
    R1WIN_W[$1/$u]=1
  done
}
# 346: 服务动作分三件事表述 —— 终态(A-4 已逐项判)、实例变化(前后 MainPID / InvocationID, 只作描述与交叉核对)、
#      窗口内实际记录到的启停(判据, 对照上面的依据)。逐 unit 结算: 符合依据 / 超出依据(意外) / 未取得:
#   · 只认 PID 1(systemd[1])的记录; 单元自己进程的输出不算动作; 认不出的 PID 1 记录 ⇒ 该 unit 未取得(不猜);
#   · Started / Stopped 按依据的上限; 停了没再起、失败、自动重启、重载都不在依据内; Deactivated 必须对应本窗口记录到的一次启或停;
#   · 前后实例换了(InvocationID 都非空且不同)却没有记录到 Started ⇒ 记录不完整, 该 unit 未取得;
#   · 348: 两次读取都有效之后, 前空后有 = "实例标识出现", 没有 Started 记录 ⇒ 未取得; 前有后空 = "实例标识消失", 没有同 unit 的结束记录
#     (Stopped 或 Deactivated; 自行退出只记 Deactivated, 不要求 Stopped)⇒ 未取得。前后都合法为空只按窗口记录判, 不据此断言没有启动。
#     有记录不等于获准: 上面的上限 / 失败 / 自动重启 / 重载判据照旧先判; 不从实例标识推断顺序、调用者或 enable / disable。
#   · journal 不按 unit 记 enable / disable / reset-failed / daemon-reload, 所以结论只到"记录到的启停", 不宣称整个过程零意外。
r1_svc_window(){   # $1=前快照 $2=后快照 $3=场景名 → 0 记录到的全部符合 / 1 有超出依据的 / 2 有未取得(且没有超出的)
  local u rc crc out line msg ns nst nd nf nr nre no odd basis maxs maxt reason b a ib ia wb wa wi inst viol TAB f
  local re_pid1='^[^ ]+ [^ ]+ systemd\[1\]: (.*)$' n_bad=0 n_na=0 bads="" nas="" chg="" same="" unk="" appear="" gone=""
  TAB="$(printf '\t')"; f="07-service-window-$3.txt"
  echo "── 服务动作($3): 窗口内实际记录到的启停(依据 = 冻结旧版在本场景条件下的执行路径, 不是正常迁移链) ──"
  cp "$1" "$EVID/svc-$3-before.tsv" 2>/dev/null; cp "$2" "$EVID/svc-$3-after.tsv" 2>/dev/null
  chmod 600 "$EVID/svc-$3-before.tsv" "$EVID/svc-$3-after.tsv" 2>/dev/null || true
  if [[ -z "$R1_JCUR" ]]; then
    _evn "$f" "窗口起点未取得: $R1_JCUR_WHY"
    bad "$3 服务动作: 窗口起点未取得($R1_JCUR_WHY) —— 窗口内的启停记录全部未取得, 过程动作结论未取得"
    return 2
  fi
  _evn "$f" "窗口起点游标: $R1_JCUR"
  for u in "${SVC_WATCH[@]}"; do
    basis="${R1_SVC_BASIS[$u]:-}"
    if [[ -z "$basis" ]]; then n_na=$((n_na+1)); nas="$nas $u(没有写定的依据)"; printf '    %-18s 未取得: 没有写定的依据\n' "$u"; continue; fi
    read -r maxs maxt <<<"${basis%%|*}"; reason="${basis#*|}"
    if [[ "${R1WIN_W[$3/$u]:-0}" != 1 ]]; then   # 347: 只认本次运行里写出完成的窗口记录
      _evn "$f" "## $u  窗口记录没有在本次运行里写出完成(旧件不采信)"
      n_na=$((n_na+1)); nas="$nas $u(窗口记录没有写出完成)"; printf '    %-18s 未取得: 窗口记录没有在本次运行里写出完成(旧件不采信)\n' "$u"; continue
    fi
    rc="$(cat "$E2E_TMP/r1win-$3-$u.rc" 2>/dev/null)"; crc=$?
    if (( crc != 0 )); then   # 347: 读退出码记录失败 ⇒ 已输出的内容不采信
      _evn "$f" "## $u  退出码记录读不回(cat 退出 $crc)"
      n_na=$((n_na+1)); nas="$nas $u(退出码记录读不回)"; printf '    %-18s 未取得: 退出码记录读不回(cat 退出 %s; 已输出的内容不采信)\n' "$u" "$crc"; continue
    fi
    if [[ ! "$rc" =~ ^[0-9]+$ ]] || (( rc != 0 )) || [[ ! -f "$E2E_TMP/r1win-$3-$u.out" ]]; then
      _evn "$f" "## $u  journal 查询未取得(退出码记录=[${rc:-无}])"
      n_na=$((n_na+1)); nas="$nas $u(journal 查询退出 ${rc:-未记录})"; printf '    %-18s 未取得: journal 查询退出 %s\n' "$u" "${rc:-未记录}"; continue
    fi
    out="$(cat "$E2E_TMP/r1win-$3-$u.out" 2>/dev/null)" || { n_na=$((n_na+1)); nas="$nas $u(窗口记录读不回)"; printf '    %-18s 未取得: 窗口记录读不回\n' "$u"; continue; }
    { printf '## %s  journal 退出 0\n' "$u"; [[ -n "$out" ]] && printf '%s\n' "$out"; } | _ev "$f"
    ns=0; nst=0; nd=0; nf=0; nr=0; nre=0; no=0; odd=""
    while IFS= read -r line; do
      [[ "$line" =~ $re_pid1 ]] || continue
      msg="${BASH_REMATCH[1]}"
      case "$msg" in
        "Starting "*|"Stopping "*) ;;
        "Started "*) ns=$((ns+1));;
        "Stopped "*) nst=$((nst+1));;
        *": Deactivated successfully.") nd=$((nd+1));;
        *": Failed with result "*|"Failed to start "*) nf=$((nf+1));;
        *": Scheduled restart job"*) nr=$((nr+1));;
        "Reloading "*|"Reloaded "*) nre=$((nre+1));;
        *": Consumed "*" CPU time"*) ;;
        *) no=$((no+1)); odd="$odd [${msg:0:60}]";;
      esac
    done <<<"$out"
    r1_svc_inv "$1" "$u"; ib=$?; b="$R1_SV"; wb="$R1_WHY"   # 347: 缺行 / 结构不完整 / 查询失败 / 快照未完成 ⇒ 取不到(不再降成"无从比较")
    r1_svc_inv "$2" "$u"; ia=$?; a="$R1_SV"; wa="$R1_WHY"
    if (( ib != 0 || ia != 0 )); then inst="取不到"; wi="$( ((ib)) && printf '前: %s; ' "$wb")$( ((ia)) && printf '后: %s' "$wa")"
    elif [[ -n "$b" && -n "$a" && "$b" != "$a" ]]; then inst="换了"; chg="$chg $u"
    elif [[ -n "$b" && "$b" == "$a" ]]; then inst="未换"; same="$same $u"
    elif [[ -z "$b" && -n "$a" ]]; then inst="实例标识出现"; appear="$appear $u"   # 348
    elif [[ -n "$b" && -z "$a" ]]; then inst="实例标识消失"; gone="$gone $u"     # 348
    else inst="无从比较(前后都没有实例标识)"; unk="$unk $u"; fi
    printf '    %-18s 记录: Started %s / Stopped %s / Deactivated %s / 失败 %s / 自动重启 %s / 重载 %s / 未识别 %s;  实例: %s\n' \
      "$u" "$ns" "$nst" "$nd" "$nf" "$nr" "$nre" "$no" "$inst"
    if (( no > 0 )); then n_na=$((n_na+1)); nas="$nas $u(有未识别的 PID 1 记录:$odd)"; printf '      → 未取得: 有未识别的 PID 1 记录%s\n' "$odd"; continue; fi
    if [[ "$inst" == 取不到 ]]; then n_na=$((n_na+1)); nas="$nas $u(实例对照取不到: $wi)"; printf '      → 未取得: 前后快照的实例记录取不到(%s), 记录完整性无从交叉核对\n' "$wi"; continue; fi
    viol=""
    (( ns > maxs )) && viol="$viol Started $ns 次(依据至多 $maxs)"
    (( nst > maxt )) && viol="$viol Stopped $nst 次(依据至多 $maxt)"
    (( nst > ns )) && viol="$viol 停了 $nst 次却只起了 $ns 次"
    (( nf > 0 )) && viol="$viol 失败 $nf 次"
    (( nr > 0 )) && viol="$viol 自动重启 $nr 次"
    (( nre > 0 )) && viol="$viol 重载 $nre 次"
    (( nd > ns + nst )) && viol="$viol Deactivated $nd 次多于记录到的启停"
    if [[ -n "$viol" ]]; then n_bad=$((n_bad+1)); bads="$bads $u:$viol"; printf '      → 超出依据:%s(依据: %s)\n' "$viol" "$reason"; continue; fi
    if [[ "$inst" == 换了 ]] && (( ns == 0 )); then
      n_na=$((n_na+1)); nas="$nas $u(实例换了却没有 Started 记录)"; printf '      → 未取得: 实例换了却没有记录到 Started —— 窗口记录不完整\n'; continue
    fi
    if [[ "$inst" == 实例标识出现 ]] && (( ns == 0 )); then   # 348
      n_na=$((n_na+1)); nas="$nas $u(实例标识出现却没有 Started 记录)"; printf '      → 未取得: 实例标识出现, 窗口里却没有这个 unit 的 Started 记录 —— 过程证据不完整\n'; continue
    fi
    if [[ "$inst" == 实例标识消失 ]] && (( nst + nd == 0 )); then   # 348: 失败记录已在上面按超出依据判过
      n_na=$((n_na+1)); nas="$nas $u(实例标识消失却没有结束记录)"; printf '      → 未取得: 实例标识消失, 窗口里却没有这个 unit 的结束记录(Stopped / Deactivated) —— 过程证据不完整\n'; continue
    fi
    if (( ns + nst + nd == 0 )); then printf '      → 符合依据: 窗口内没有记录到启停\n'
    else printf '      → 符合依据: %s\n' "$reason"; fi
  done
  note "$3 实例变化(前后 InvocationID; 只作描述与交叉核对): 换了:${chg:- 无}; 未换:${same:- 无}; 出现:${appear:- 无}; 消失:${gone:- 无}; 前后都没有:${unk:- 无}"
  (( n_bad > 0 )) && bad "$3 服务动作: 窗口内记录到依据之外的动作:$bads"
  (( n_na > 0 )) && bad "$3 服务动作: 有 $n_na 个 unit 的窗口记录未取得:$nas —— 这些 unit 的过程动作结论未取得"
  (( n_bad == 0 && n_na == 0 )) && ok "$3 服务动作: 窗口内 journal 记录到的启停都在 ① 依据之内(${#SVC_WATCH[@]} 个 unit 逐项见上)"
  note "$3 服务动作: 结论只覆盖 journal 记录到的启停。enable / disable / reset-failed / daemon-reload 不按 unit 记录, 过程中是否发生取不到"
  note "  (自启态只由 A-4 的终态比对覆盖); systemd-journald 在窗口内被旧回滚重启过(1494)。不宣称整个过程零意外。"
  (( n_bad > 0 )) && return 1
  (( n_na > 0 )) && return 2
  return 0
}

# 342: A0 身份核对的直接依赖 —— 摘要、模块清单、逐文件比较都要"读取有效"才参与判定; 读不到 ≠ 不符 ≠ 相符。
R1_DG=""
r1_digest(){   # $1=文件 → 0 取得(R1_DG=64 位十六进制) / 2 读取失败(失败前打印的内容不采信; 342 复现 XA1 / XA2)
  local out rc; R1_DG=""
  out="$(sha256sum -- "$1" 2>/dev/null)"; rc=$?
  out="${out%% *}"
  { (( rc == 0 )) && [[ "$out" =~ ^[0-9a-f]{64}$ ]]; } || { R1_WHY="读不到 $1 的摘要(sha256sum 退出 $rc)"; return 2; }
  R1_DG="$out"
}
r1_same_file(){   # $1=实际 $2=权威 → 0 相同 / 1 不同 / 2 读取失败(R1_WHY)
  local a b
  r1_digest "$1" || return 2; a="$R1_DG"
  r1_digest "$2" || return 2; b="$R1_DG"
  [[ "$a" == "$b" ]] && return 0
  R1_WHY="$1(${a:0:12}) 与 $2(${b:0:12}) 不同"; return 1
}
R1_MANIFEST=()
r1_manifest(){   # $1=平台 → 0 取得(R1_MANIFEST 每项 "src name mode") / 2 生成失败或内容无效(342 复现 XA3)
  local out rc l src name mode extra
  R1_MANIFEST=()
  out="$( ( source "$CANDSRC/lib/modules.sh" && pdg_platform_modules "$1" ) 2>/dev/null )"; rc=$?
  (( rc == 0 )) || { R1_WHY="候选模块清单生成失败(退出 $rc; 已输出的部分不采信)"; return 2; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    read -r src name mode extra <<<"$l"
    { [[ -n "$src" && -n "$name" && -z "$extra" && "$name" != */* && "$mode" =~ ^[0-7]{3}$ ]]; } \
      || { R1_WHY="候选模块清单有无法解析的行([$l])"; return 2; }
    R1_MANIFEST+=("$src $name $mode")
  done <<<"$out"
  (( ${#R1_MANIFEST[@]} > 0 )) || { R1_WHY="候选模块清单为空"; return 2; }
  return 0
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
  # 343: HEAD 查询接上原始退出码与输出形态 —— 先打印正确 SHA 再以非零退出的那次查询不采信(343 复现 H2)
  local head hrc; head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"; hrc=$?
  if (( hrc != 0 )) || [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
    bad "部署源身份: 读不到 $REPO 的 HEAD(git 退出 $hrc; 已输出的 [${head:0:12}] 不采信) —— 未取得"; return 1
  fi
  [[ "$head" == "$CAND_SHA" ]] && ok "部署源身份: $REPO 的 HEAD == 候选 X" \
                              || { bad "部署源 HEAD=$head(应为 X)"; return 1; }
  # 关键源文件逐字节等于 X 的那一份(拿独立展开的 $CANDSRC 当权威, 不自证)
  local miss=0 f r
  for f in deploy/bot/pdg.sh deploy/bot/iosstate.py deploy/bot/pdg-bot.py lib/modules.sh; do
    cmp -s "$REPO/$f" "$CANDSRC/$f"; r=$?
    case "$r" in 0) ;; 1) miss=$((miss+1)); echo "       不符: $f";; *) miss=$((miss+1)); echo "       比较失败(cmp 退出 $r): $f";; esac
  done
  [[ "$miss" == 0 ]] && ok "部署源身份: 关键源文件($REPO)逐字节等于候选 X" \
                     || { bad "部署源里有 $miss 个关键文件不是 X 的或比较失败"; return 1; }
  # 按候选自己的清单装 —— 与 __migrate 里的 migrate_deploy_botfiles 同一份真源, 不会再被换回去
  install -m755 "$REPO/deploy/bot/pdg.sh" "$R1_CLI"
  ( # shellcheck source=/dev/null
    source "$REPO/lib/modules.sh" && pdg_install_runtime_modules "$REPO" "$R1_BOTDIR" "$1" ) \
    || { bad "按候选清单装模块失败"; return 1; }
  # 342: 读取失败不再当成"两边相等"; 不符或读不到都不往下走(由 r1_a0_invoke 阻断 __migrate)
  r1_same_file "$R1_CLI" "$CANDSRC/deploy/bot/pdg.sh"; r=$?
  case "$r" in
    0) ok "部署源身份: $R1_CLI 就是候选 X 的那一份";;
    1) bad "装上去的 pdg 不是 X 的($R1_WHY)"; return 1;;
    *) bad "部署源身份: 装上去的 pdg 身份读取失败 —— $R1_WHY; 未取得"; return 1;;
  esac
  # ── 按**平台契约**核对装机身份 ────────────────────────────────────────────
  # 上一轮这里写死了"iosstate 必须有 migrate_schema" —— 而 iosstate.py 属于 PDG_IOS_MODULES,
  # **Android 本来就不装它**(平台契约, 不是装机失败)。判据换成: 该平台**实际应装**的每个
  # 文件都在, 且逐字节等于候选 X 的那一份; 再加三条反面契约。
  local plat="$1" nmod=0 nbad=0 nerr=0 src name _mode l
  # 342: 清单生成失败 / 为空 / 有解析不了的行 ⇒ 装机身份未取得(不再按已输出的半截清单判)
  if ! r1_manifest "$plat"; then bad "部署源身份: $plat 平台$R1_WHY —— 装机身份未取得"; return 1; fi
  for l in "${R1_MANIFEST[@]}"; do
    read -r src name _mode <<<"$l"
    nmod=$((nmod+1))
    if [[ ! -e "$R1_BOTDIR/$name" ]]; then
      nbad=$((nbad+1)); echo "       缺 $name"; continue
    fi
    cmp -s "$CANDSRC/$src" "$R1_BOTDIR/$name"; r=$?
    case "$r" in 0) ;; 1) nbad=$((nbad+1)); echo "       指纹不符 $name";; *) nerr=$((nerr+1)); echo "       比较失败(cmp 退出 $r) $name";; esac
  done
  { [[ "$nmod" -gt 0 && "$nbad" == 0 && "$nerr" == 0 ]]; } \
    && ok "部署源身份: $plat 平台应装的 $nmod 个文件全部就位且逐字节等于候选 X" \
    || { bad "部署源身份: $plat 平台清单 $nmod 项里有 $nbad 项缺失或指纹不符、$nerr 项比较失败"; return 1; }
  if [[ "$plat" == android ]]; then
    # 反面契约 ①: iOS 专属那四件不该出现在 Android 上
    local ios_only="" f
    for f in iosprofile.py iosstate.py mitm_ca.py pdg-dot.mobileconfig.tmpl; do
      [[ -e "$R1_BOTDIR/$f" ]] && ios_only="$ios_only $f"
    done
    [[ -z "$ios_only" ]] && ok "部署源身份: Android 上没有 iOS 专属件(平台契约成立)" \
                         || bad "部署源身份: Android 上出现了 iOS 专属件:$ios_only"
  else
    # 反面契约 ②: iOS 上装的 iosstate 必须是候选形态(行为身份, 不只是文件名)
    ( cd "$R1_BOTDIR" && python3 -c 'import iosstate,sys; sys.exit(0 if hasattr(iosstate,"migrate_schema") else 1)' ) 2>/dev/null \
      && ok "部署源身份: iOS 上装的 iosstate 具备 migrate_schema(候选形态)" \
      || { bad "部署源身份: iOS 上的 iosstate 没有 migrate_schema —— 部署源仍是旧版"; return 1; }
  fi
  # 反面契约 ③: 两平台均应退役的三件, 迁移之后一件都不许在(此刻迁移还没跑, 只记录现状)
  local retired="" r
  for r in "$R1_BOTDIR/mitm_server.py" "$R1_BOTDIR/mitm_wloc.py" /etc/systemd/system/pdg-mitm.service; do
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
assert_candidate_identity(){   # $1=平台 → 0 成立 / 1 不成立或未取得(341: 由 r1_a0_invoke 阻断 __migrate; 342: 读不到 ≠ 相符)
  local plat="$1" mis=0 dif=0 err=0 n=0 src name mode st=0 r l
  r1_same_file "$R1_CLI" "$CANDSRC/deploy/bot/pdg.sh"; r=$?
  case "$r" in
    0) ok "部署身份: $R1_CLI 逐字节等于冻结候选";;
    1) bad "部署身份: pdg 不是候选那一份($R1_WHY)"; st=1;;
    *) bad "部署身份: pdg 的身份读取失败 —— $R1_WHY; 未取得"; st=1;;
  esac
  if ! r1_manifest "$plat"; then
    bad "部署身份: $R1_WHY —— 受管模块的身份未取得"
    _evn 00-identity.txt "候选部署身份: 模块清单未取得($R1_WHY)"
    return 1
  fi
  for l in "${R1_MANIFEST[@]}"; do
    read -r src name mode <<<"$l"
    n=$((n+1))
    [[ -e "$R1_BOTDIR/$name" ]] || { mis=$((mis+1)); continue; }
    cmp -s "$CANDSRC/$src" "$R1_BOTDIR/$name"; r=$?
    case "$r" in 0) ;; 1) dif=$((dif+1));; *) err=$((err+1));; esac
  done
  { [[ "$mis" == 0 && "$dif" == 0 && "$err" == 0 ]]; } \
    && ok "部署身份: $n 项受管模块与冻结候选逐字节一致(缺 $mis / 不符 $dif)" \
    || { bad "部署身份: 受管模块与候选不一致(缺 $mis / 不符 $dif / 比较失败 $err)"; st=1; }
  _evn 00-identity.txt "候选部署身份: pdg+${n} 模块; 缺 $mis 不符 $dif 比较失败 $err"
  return "$st"
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
DNS_PREMISE_SCENE=""   # 346: 当前 DNS 条件与标定属于哪个场景; 重建前像时清空(r1_dns_invalidate)
DNS_PRE_WHY=""
DNS_STUB_ID=""         # 346: 自有上游的登记身份(/proc/<pid>/cmdline, NUL 换成空格), 撤除前逐字核对
DNS_STUB_LOG=""        # 346: 当前场景那一份上游日志(dns-up-<场景>.log); 上一场景的日志原样保留, 不覆盖

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

# 346: 自有上游按场景**撤除后重起**, 不复用上一场景的进程, 也不在同一端口上直接再起一个:
#   · 起新的之前先撤旧的。撤除只按登记的 PID, 且 /proc/<pid>/cmdline 必须与起的时候登记的逐字相同 —— 对不上就不杀, 判"未撤除";
#   · 撤除后核端口已释放; 起之前端口仍有监听或查不了, 就不起(条件不成立);
#   · 每个场景一份自己的日志与计数(dns-up-<场景>.*), 上一场景那份原样保留; 同名日志已存在就不起(不覆盖)。
# 347: 读进程命令行要核退出码 —— 先输出(哪怕是相符的内容)再失败的那一次不采信; 空命令行也不算取得。
DNS_STUB_CUR=""
_dns_stub_cmdline(){   # $1=pid → 0 取得(DNS_STUB_CUR) / 2 读取失败
  local out rc
  DNS_STUB_CUR=""
  out="$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ -n "$out" ]]; } || return 2
  DNS_STUB_CUR="$out"
}
# 347: 端口查询三态 —— grep 出错(退出 ≥2)以前会落进"没有监听", 现在与 ss 失败一样记"查询失败"。
_dns_port_busy(){   # → 0 端口有监听 / 1 确认无监听 / 2 查询失败
  local out rc
  out="$(ss -lnu 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return 2
  grep -qE "[:.]${DNS_UP_PORT}[[:space:]]" <<<"$out"; rc=$?
  case "$rc" in 0) return 0;; 1) return 1;; *) return 2;; esac
}
_dns_port_word(){ case "$1" in 0) printf '有监听';; 1) printf '确认无监听';; *) printf '查询失败';; esac; }
dns_stub_stop(){   # → 0 已撤除(或本来就没有) / 1 未能确认撤除(DNS_CALIB_WHY)
  local pid="$DNS_STUB_PID" cur i r=2
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    if ! _dns_stub_cmdline "$pid"; then
      DNS_CALIB_WHY="登记的自有上游 PID $pid 的命令行读取失败(已输出的内容不采信) —— 身份未取得, 不杀, 未撤除"; return 1
    fi
    cur="$DNS_STUB_CUR"
    [[ -n "$DNS_STUB_ID" && "$cur" == "$DNS_STUB_ID" ]] \
      || { DNS_CALIB_WHY="登记的自有上游 PID $pid 身份对不上(登记 [${DNS_STUB_ID:0:100}] / 现在 [${cur:0:100}]) —— 不杀, 未撤除"; return 1; }
    kill "$pid" 2>/dev/null || { DNS_CALIB_WHY="向自有上游 PID $pid 发信号失败"; return 1; }
  fi
  wait "$pid" 2>/dev/null
  for ((i=0; i<25; i++)); do
    _dns_port_busy; r=$?
    (( r == 1 )) && break
    sleep 0.2
  done
  (( r == 1 )) || { DNS_CALIB_WHY="撤除自有上游后端口 $DNS_UP_PORT 仍有监听或查不了(结果 $r) —— 端口查询: $(_dns_port_word "$r")"; return 1; }
  DNS_STUB_PID=""; DNS_STUB_ID=""
  return 0
}
dns_stub_start(){   # $1=场景 → 0 已起且身份已登记 / 1 不成立(DNS_CALIB_WHY)
  local sc="$1" r
  dns_stub_stop || return 1
  _dns_port_busy; r=$?
  (( r == 1 )) || { DNS_CALIB_WHY="起自有上游之前端口 $DNS_UP_PORT 已有监听或查不了(结果 $r) —— 不在同一端口上再起一个(端口查询: $(_dns_port_word "$r"))"; return 1; }
  DNS_STUB_LOG="$E2E_TMP/dns-up-$sc.log"
  [[ ! -e "$DNS_STUB_LOG" ]] || { DNS_CALIB_WHY="本场景的上游日志 $DNS_STUB_LOG 已经存在 —— 不覆盖, 不起"; return 1; }
  "$E2E_ROOT/tests/helpers/dns-stub.py" --port "$DNS_UP_PORT" \
      --count "$E2E_TMP/dns-up-$sc.count" --log "$DNS_STUB_LOG" \
      --mode answer-a --answer "$DNS_U" > "$E2E_TMP/dns-up-$sc.out" 2>&1 &
  DNS_STUB_PID=$!
  sleep 1
  kill -0 "$DNS_STUB_PID" 2>/dev/null \
    || { DNS_CALIB_WHY="自有 DNS 上游没起来: $(tail -2 "$E2E_TMP/dns-up-$sc.out" 2>/dev/null)"; DNS_STUB_PID=""; return 1; }
  if ! _dns_stub_cmdline "$DNS_STUB_PID"; then
    DNS_STUB_ID=""; DNS_CALIB_WHY="自有上游 PID $DNS_STUB_PID 的命令行读取失败(已输出的内容不采信) —— 身份未取得, 不登记; 进程留在现场, 不按名字清理"; return 1
  fi
  DNS_STUB_ID="$DNS_STUB_CUR"
  [[ "$DNS_STUB_ID" == *"dns-stub.py --port $DNS_UP_PORT "*"--log $DNS_STUB_LOG "* ]] \
    || { DNS_CALIB_WHY="自有上游 PID $DNS_STUB_PID 的命令行不是本场景起的那一个([${DNS_STUB_ID:0:120}]) —— 不登记"; DNS_STUB_ID=""; return 1; }
  _evn dns-calibration.txt "[$sc] 自有上游 PID $DNS_STUB_PID 已登记(日志 ${DNS_STUB_LOG##*/})"
  return 0
}

# 固定实验条件。每个场景在自己的前像上做一次; 做完之后甲乙两次测量之间上游、域名归属、监听地址都不再动。
dns_fix_conditions(){   # $1=场景
  local hij=/etc/mosdns/rules/mitm_hijack.txt cn=/etc/mosdns/rules/geosite_cn.txt
  local mc=/etc/mosdns/config.yaml
  command -v dig >/dev/null 2>&1 || { DNS_CALIB_WHY="机器上没有 dig"; return 1; }
  [[ -f "$mc" && -f "$hij" && -f "$cn" ]] || { DNS_CALIB_WHY="mosdns 配置或规则文件不齐"; return 1; }
  DNS_CALIB_NAME="dns-calib-$$-${RANDOM}.e2e.test"   # 每次新名字, 排除缓存带来的假差异
  # ① 自有上游(本轮事先登记归属的资源; 346: 按场景撤除后重起, 身份核对后才动, 不按名字宽杀)
  dns_stub_start "$1" || return 1
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
  grep -q " q=$DNS_CONTROL " "$DNS_STUB_LOG" \
    || { DNS_CALIB_WHY="对照名答对了, 但本场景的自有上游日志里没有它 —— 答案不是上游给的"; return 1; }
  ok "仪器条件($1): 自有上游已就位, 对照名 $DNS_CONTROL 经 local_upstream 取得 U=$DNS_U(本场景上游日志按名可核)"
  return 0
}

# 标定: 同一个查询名, **只**让 mitm_hijack 里那一条变。U→H→U 三段都要有效且等于预期。
dns_instrument_calibrate(){   # $1=场景(346: 条件、上游、日志、副本与证据都按场景分开)
  local sc="$1" hij=/etc/mosdns/rules/mitm_hijack.txt
  local bak sum0 mode0 own0 sum1 mode1 own1 entry
  DNS_INSTRUMENT_OK=0; DNS_CALIB_WHY=""; DNS_RESTORE_DISK=0; DNS_RESTORE_RUN=0
  dns_fix_conditions "$sc" || { bad "仪器标定($sc): 固定实验条件失败 —— $DNS_CALIB_WHY"; return 1; }
  [[ "$DNS_U" != "$DNS_H" ]] || { bad "仪器标定: U 与 H 相同($DNS_U), 这组预期本身没有区分力"; return 1; }
  entry="full:$DNS_CALIB_NAME"
  bak="${E2E_TMP:-${TMPDIR:-/tmp}}/hijack-calib-$sc.bak"
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
  local up_off; up_off="$(grep -c " q=$DNS_CALIB_NAME " "$DNS_STUB_LOG" 2>/dev/null | tr -d '\n')"
  # ── 配置乙: **只**多这一条条目, 其余一个字不动 ──
  printf '%s\n' "$entry" >> "$hij"
  _dns_reload || { _calib_fail; return 1; }
  p_on="$(dns_probe "$DNS_CALIB_NAME")"
  local up_on; up_on="$(grep -c " q=$DNS_CALIB_NAME " "$DNS_STUB_LOG" 2>/dev/null | tr -d '\n')"
  _evn dns-calibration.txt "[$sc] 查询名 $DNS_CALIB_NAME(每次新造; 两次测量之间重启 mosdns 清缓存)"
  _evn dns-calibration.txt "[$sc] 配置甲(不在接管表) rc/status/answer/stderr = $p_off  自有上游累计收到=$up_off"
  _evn dns-calibration.txt "[$sc] 配置乙(在接管表)   rc/status/answer/stderr = $p_on   自有上游累计收到=$up_on"

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
# 346: DNS 前提**按场景**建立, 不继承上一场景的成功标志。
#   345 实跑: A0 标定成功后, 场景 A 重建前像(e2e_seed_mosdns all)使条件失效, 对照名在调用前就答 H;
#   而旧的 DNS_INSTRUMENT_OK=1 仍在, 于是 A 照样调用了产品, 事后又把"前像 H/H"记成"未恢复"。
#   现在: 重建前像即作废(build_preimage → r1_dns_invalidate); 每个场景自己固定条件、标定(含磁盘与运行配置的还原核验),
#   结果绑在场景名上; 调用前再用本场景的正式观测核"查询有效 + 见证=H + 对照=U"。任一不成立或未取得, 对应产品调用一次都不做。
#   不为了满足前提去改产品的劫持契约: 条件只动外围上游与 geosite_cn 两件既有合法输入(见上面 dns_fix_conditions 的说明)。
r1_dns_invalidate(){ DNS_INSTRUMENT_OK=0; DNS_PREMISE_SCENE=""; DNS_PRE_WHY=""; }
r1_dns_premise(){   # $1=场景 → 0 本场景的条件与标定(含还原核验)成立 / 1 不成立(DNS_PRE_WHY)
  r1_dns_invalidate
  dns_instrument_calibrate "$1" || { DNS_PRE_WHY="条件建立或标定未通过(${DNS_CALIB_WHY:-未知})"; return 1; }
  DNS_PREMISE_SCENE="$1"
  return 0
}
# 346 / 347: 场景 A 的标定在调用前要连着重启 mosdns 四次, 加上前像那一次启动共五次。按 systemd 的默认启动限额(5 次 / 10 s)与这段流程的
#      启动次数**推断**, 旧回滚那一次 restart mosdns(1492)有可能落进同一个限额窗口而被拒, 被误读成"产品没恢复"(③ 324 的 dotwitness 是同一机理)。
#      这是有源码依据的风险推断, 没有真实 runner 的实测证据。所以标定之后、采前像之前, 按 mosdns 自己的限额窗口**一次**有界等待:
#      不 reset-failed、不改限额、不重试; 读不到窗口或窗口超过 60 s ⇒ 前提不成立。
#      347: sleep 退出 0 不等于已经等够 —— 前后各读一次 CLOCK_MONOTONIC(读取失败 / 格式不对 / 倒退 / 实得不足 都阻断调用),
#      只报请求时长、sleep 退出码、两次读数的退出码与实得时长; 不声称 systemd 的内部计数已归零, 也不声称等待期间没有启动。
R1_MONO=(python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))')
R1_MV=""; R1_MRC=""
r1_mono(){   # → 0 取得(R1_MV = CLOCK_MONOTONIC 纳秒) / 2 读取失败或输出不是正整数(已输出的内容不采信); 原始退出码留在 R1_MRC
  local out
  R1_MV=""
  out="$("${R1_MONO[@]}" 2>/dev/null)"; R1_MRC=$?
  { (( R1_MRC == 0 )) && [[ "$out" =~ ^[0-9]+$ ]]; } || return 2
  R1_MV="$out"
}
r1_mosdns_quiesce(){   # → 0 已静置 / 1 不成立(DNS_PRE_WHY)
  local iv rc sec re_s='^([0-9]+)s$' re_m='^([0-9]+)min$' re_ms='^([0-9]+)min ([0-9]+)s$'
  iv="$(systemctl show -p StartLimitIntervalUSec --value mosdns 2>/dev/null)"; rc=$?
  (( rc == 0 )) || { DNS_PRE_WHY="读不到 mosdns 的启动限额窗口(systemctl 退出 $rc)"; return 1; }
  if [[ "$iv" == 0 ]]; then sec=0
  elif [[ "$iv" =~ $re_s ]]; then sec=$((10#${BASH_REMATCH[1]}))
  elif [[ "$iv" =~ $re_m ]]; then sec=$((10#${BASH_REMATCH[1]} * 60))
  elif [[ "$iv" =~ $re_ms ]]; then sec=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
  else DNS_PRE_WHY="mosdns 的启动限额窗口认不出([$iv])"; return 1; fi
  (( sec <= 60 )) || { DNS_PRE_WHY="mosdns 的启动限额窗口 ${sec} s 超过静置上限 60 s"; return 1; }
  local req=$((sec + 1)) t0 t1 r0 r1 sr el els
  r1_mono; r0="$R1_MRC"
  [[ -n "$R1_MV" ]] || { DNS_PRE_WHY="等待前读单调时钟失败(退出 $r0; 输出不是正整数则不采信) —— 不等待"; return 1; }
  t0="$R1_MV"
  sleep "$req"; sr=$?
  (( sr == 0 )) || { DNS_PRE_WHY="等待 $req s 没有完成(sleep 退出 $sr)"; return 1; }
  r1_mono; r1="$R1_MRC"
  [[ -n "$R1_MV" ]] || { DNS_PRE_WHY="等待后读单调时钟失败(退出 $r1; 输出不是正整数则不采信) —— 实得时长未取得"; return 1; }
  t1="$R1_MV"
  (( t1 >= t0 )) || { DNS_PRE_WHY="单调时钟读数倒退($t0 → $t1) —— 实得时长无效"; return 1; }
  el=$(( t1 - t0 )); els="$(( el / 1000000000 )).$(printf '%03d' $(( (el % 1000000000) / 1000000 )))"
  _evn dns-calibration.txt "[A] 等待: 请求 $req s; sleep 退出 $sr; 单调时钟读数退出 $r0 / $r1; 实得 $els s"
  (( el >= req * 1000000000 )) || { DNS_PRE_WHY="等待实得 $els s, 不足请求的 $req s(sleep 退出 0 不算已经等够)"; return 1; }
  note "A: 标定之后按 mosdns 的启动限额窗口($iv)请求等待 $req s: sleep 退出 $sr, 单调时钟读数退出 $r0 / $r1, 实得 $els s(不代表 systemd 内部计数已归零)"
  return 0
}
r1_dns_ready(){   # $1=场景 $2=本场景调用前的 dns_feature_probe 输出 → 0 前提成立 / 1 不成立(DNS_PRE_WHY)
  local st w c
  { [[ "$DNS_INSTRUMENT_OK" == 1 && "$DNS_PREMISE_SCENE" == "$1" ]]; } \
    || { DNS_PRE_WHY="DNS 条件与标定不属于本场景(标定成立=$DNS_INSTRUMENT_OK, 所属场景=${DNS_PREMISE_SCENE:-无}, 本场景=$1)"; return 1; }
  IFS=$'\t' read -r st w c <<<"$2"
  [[ "$st" == VALID ]] || { DNS_PRE_WHY="调用前的 DNS 观测无效(${2//$'\t'/ })"; return 1; }
  { [[ "$w" == "$DNS_H" && "$c" == "$DNS_U" ]]; } \
    || { DNS_PRE_WHY="调用前的 DNS 查询有效, 但不是 见证=H、对照=U(见证=$w 对照=$c) —— 实验前提不成立"; return 1; }
  return 0
}
# 346: DNS 这一维的结算, 四种情形分开(345: 前像 H/H、回滚后 H/H 被同时打成"可区分行为回到前像"的 OK 和"未恢复"):
#   查询失败 ⇒ 观测无效; 前像有效但不是 H/U ⇒ 实验前提不成立, 恢复结论未取得;
#   前像 H/U 有效、之后有效但不是 H/U ⇒ 恢复失败; 前后都有效且都是 H/U ⇒ 恢复成立。本场景没有自己的有效标定 ⇒ 未取得。
#   $5=1 时把结论记进本场景的恢复账(A-4); A0-3 是阶段观测, 不记账。
r1_dns_settle(){   # $1=标签 $2=场景 $3=前像 $4=之后 $5=是否记账(1/0) → 0 成立 / 1 恢复失败 / 2 未取得
  local lb="$1" sc="$2" bs bw bc as aw ac item="DNS 见证/对照"
  IFS=$'\t' read -r bs bw bc <<<"$3"; IFS=$'\t' read -r as aw ac <<<"$4"
  if [[ "$DNS_INSTRUMENT_OK" != 1 || "$DNS_PREMISE_SCENE" != "$sc" ]]; then
    bad "$lb 已加载配置(DNS): 本场景没有自己的有效标定(标定成立=$DNS_INSTRUMENT_OK, 所属场景=${DNS_PREMISE_SCENE:-无}) —— 结论未取得"
    [[ "$5" == 1 ]] && r1_tally na "$item(本场景未标定)"
    return 2
  fi
  if [[ "$bs" != VALID ]]; then
    bad "$lb 已加载配置(DNS): 前像的观测无效(${3//$'\t'/ }) —— 结论未取得"
    [[ "$5" == 1 ]] && r1_tally na "$item(前像观测无效)"
    return 2
  fi
  if [[ "$bw" != "$DNS_H" || "$bc" != "$DNS_U" ]]; then
    bad "$lb 已加载配置(DNS): 前像查询有效但不是 见证=H、对照=U(见证=$bw 对照=$bc) —— 实验前提不成立, 恢复结论未取得"
    [[ "$5" == 1 ]] && r1_tally na "$item(前提不成立: 前像 见证=$bw 对照=$bc)"
    return 2
  fi
  if [[ "$as" != VALID ]]; then
    bad "$lb 已加载配置(DNS): 之后的观测无效(${4//$'\t'/ }) —— 结论未取得"
    [[ "$5" == 1 ]] && r1_tally na "$item(之后观测无效)"
    return 2
  fi
  if [[ "$aw" == "$DNS_H" && "$ac" == "$DNS_U" ]]; then
    ok "$lb 已加载配置(DNS): 前后都是 见证=H($DNS_H)、对照=U($DNS_U) —— 可区分行为与前像一致"
    [[ "$5" == 1 ]] && r1_tally ok "$item"
    return 0
  fi
  bad "$lb 已加载配置(DNS): 前像 H/U 有效, 之后有效但不符(见证 $bw→$aw, 对照 $bc→$ac) —— 与前像不一致"
  [[ "$5" == 1 ]] && r1_tally diff "$item"
  return 1
}

# 本轮自有资源的清理: **只**按事先登记的 PID 收自己起的那个上游, 不按名字宽杀(346: 身份对不上就不杀)。
_dns_cleanup(){ dns_stub_stop >/dev/null 2>&1 || true; }
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
# 341: 取证与读取链 —— 查询失败、记录缺失与真实状态不同分开记:
#   F 行: 有 / 无 / 查询失败(摘要或属性读不到; 失败前打印的内容不采信)
#   S 行: 运行态 / 自启态各是状态词, 或 FP_BAD(原因记在同一文件的 Q 行); R 行记**本次**查询的真实退出码
#   L 行: 监听数, 或 FP_BAD(ss 失败时它打印的内容不采信)
FP_BAD='!无效'
# 342: 采样完成度 —— 先在内存里拼好, 删掉旧文件后一次写出, 再读回核对行数; 三步都成才记 FP_DONE[标签]=1。
#      删不掉旧文件 / 写失败 / 行数对不上 ⇒ 未完成, 之后的读取一律拒绝(342 复现 XB4 / XB5: 以前会读到上一次留下的旧文件)。
declare -A FP_DONE=()
fp_capture(){   # $1=标签 → 0 已完成 / 2 未完成(R1_WHY); 写 $EVID/fp-$1.tsv
  local q u f="$EVID/fp-$1.tsv" dg st rc ld lrc av arc ev erc out n pt fm fu fg buf="" line nl=0 got
  FP_DONE[$1]=0
  for q in "${FP_FILES[@]}"; do
    if [[ -e "$q" || -L "$q" ]]; then
      dg="$(sha256sum -- "$q" 2>/dev/null)"; rc=$?; dg="${dg%% *}"
      if (( rc != 0 )) || [[ ! "$dg" =~ ^[0-9a-f]{64}$ ]]; then
        printf -v line 'F\t%s\t查询失败\tsha256sum 退出 %s\n' "$q" "$rc"; buf+="$line"; nl=$((nl+1)); continue
      fi
      st="$(stat -c '%a %u %g' -- "$q" 2>/dev/null)"; rc=$?
      if (( rc != 0 )) || [[ ! "$st" =~ ^[0-7]+\ [0-9]+\ [0-9]+$ ]]; then
        printf -v line 'F\t%s\t查询失败\tstat 退出 %s\n' "$q" "$rc"; buf+="$line"; nl=$((nl+1)); continue
      fi
      read -r fm fu fg <<<"$st"
      printf -v line 'F\t%s\t有\t%s\t%s\t%s\t%s\n' "$q" "$dg" "$fm" "$fu" "$fg"; buf+="$line"; nl=$((nl+1))
    else
      printf -v line 'F\t%s\t无\t-\t-\t-\t-\n' "$q"; buf+="$line"; nl=$((nl+1))
    fi
  done
  for u in "${FP_SVCS[@]}"; do
    ld=""; av="$FP_BAD"; ev="$FP_BAD"
    if r1_unit_q load "$u"; then ld="$R1_VAL"; else printf -v line 'Q\t%s\tload\t%s\n' "$u" "$R1_WHY"; buf+="$line"; nl=$((nl+1)); fi; lrc="$R1_RC"
    if r1_unit_q active "$u" "$ld"; then av="$R1_VAL"; else printf -v line 'Q\t%s\tactive\t%s\n' "$u" "$R1_WHY"; buf+="$line"; nl=$((nl+1)); fi; arc="$R1_RC"
    if r1_unit_q enabled "$u"; then ev="$R1_VAL"; else printf -v line 'Q\t%s\tenabled\t%s\n' "$u" "$R1_WHY"; buf+="$line"; nl=$((nl+1)); fi; erc="$R1_RC"
    printf -v line 'R\t%s\tis-active rc=%s\tis-enabled rc=%s\tLoadState rc=%s\n' "$u" "${arc:-?}" "${erc:-?}" "${lrc:-?}"; buf+="$line"; nl=$((nl+1))
    printf -v line 'S\t%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$av" "$ev" \
      "$(systemctl show -p MainPID --value "$u" 2>/dev/null)" \
      "$(systemctl show -p InvocationID --value "$u" 2>/dev/null)" \
      "$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"; buf+="$line"; nl=$((nl+1))
  done
  # 已加载配置的独立依据: 真实监听(不是磁盘 hash)。7894 看 TCP、53 看 UDP, 与冻结版同口径
  for pt in 7894 53; do
    if [[ "$pt" == 7894 ]]; then out="$(ss -lnt 2>/dev/null)"; rc=$?; else out="$(ss -lnu 2>/dev/null)"; rc=$?; fi
    if (( rc != 0 )); then
      printf -v line 'L\t%s\t%s\nQ\tL%s\tss\tss 退出 %s(它打印的内容不采信)\n' "$pt" "$FP_BAD" "$pt" "$rc"; buf+="$line"; nl=$((nl+2)); continue
    fi
    n="$(grep -c ":$pt " <<<"$out")"; rc=$?
    if (( rc > 1 )) || [[ ! "$n" =~ ^[0-9]+$ ]]; then
      printf -v line 'L\t%s\t%s\nQ\tL%s\tgrep\t计数失败(grep 退出 %s)\n' "$pt" "$FP_BAD" "$pt" "$rc"; buf+="$line"; nl=$((nl+2)); continue
    fi
    printf -v line 'L\t%s\t%s\n' "$pt" "$n"; buf+="$line"; nl=$((nl+1))
  done
  rm -f -- "$f" 2>/dev/null
  [[ ! -e "$f" && ! -L "$f" ]] || { R1_WHY="删不掉旧的 $f"; return 2; }
  printf '%s' "$buf" > "$f" 2>/dev/null || { R1_WHY="写 $f 失败"; return 2; }
  got="$(wc -l < "$f" 2>/dev/null)"; rc=$?
  { (( rc == 0 )) && [[ "$got" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && (( got == nl )); } \
    || { R1_WHY="$f 读回行数 [$got] 与写入的 $nl 行对不上(wc 退出 $rc)"; return 2; }
  chmod 600 "$f" 2>/dev/null || true
  FP_DONE[$1]=1
  return 0
}
# 341: 读指纹 —— 0 取到恰一条(FP_REC=其余字段) / 1 该标签里确实没有这条记录 / 2 指纹文件读不了或同键重复。
#   在本壳里调用; 两边都读不到时不再因为"两个空串相等"而判恢复(341 复现 R2)。
#   按**字段**拼回去, 不用 [^\t] 这类方括号反斜杠转义 —— 那种写法在 POSIX grep/awk 下会被
#   截断解释(仓库的 test-false-green-guard.sh 专门盯这一条)。分隔符用真正的制表符。
FP_REC=""
fp_get(){   # $1=标签 $2=类型 $3=键 → 0 取到恰一条(FP_REC) / 1 确认没有 / 2 采样未完成、读不了、读取不完整或同键重复
  local f="$EVID/fp-$1.tsv" TAB out rc rest n; FP_REC=""
  [[ "${FP_DONE[$1]:-0}" == 1 ]] || return 2      # 342: 只读本进程里写成功并核过行数的那一份
  [[ -f "$f" && -r "$f" ]] || return 2      # gawk 读目录只告警、仍退出 0, 所以先核文件本身(341 复现 R2b)
  TAB="$(printf '\t')"
  out="$(awk -F"$TAB" -v t="$2" -v k="$3" \
      '$1==t && $2==k {n++; o=$3; for(i=4;i<=NF;i++) o=o FS $i} END {printf "R1FP%s%d%s%s\n", FS, n, FS, o}' "$f" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return 2                      # 先输出后失败: 输出不采信
  [[ "$out" == "R1FP$TAB"* ]] || return 2        # 没有完整的结尾行 = 输出不完整
  rest="${out#"R1FP$TAB"}"; n="${rest%%"$TAB"*}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  (( n == 0 )) && return 1
  (( n == 1 )) || return 2
  FP_REC="${rest#*"$TAB"}"
  return 0
}
# 341: 一项的前后对照 —— 0 两边都有效且相等 / 1 两边都有效但不同 / 2 任一边缺记录、读不了或观测无效(FP_WHY)。
FP_B=""; FP_A=""; FP_WHY=""
# 342: 记录结构(与 fp_capture 写出的形态一一对应)——
#   F = 有<TAB>64 位十六进制<TAB>一至四位八进制 mode(stat %a 不补前导零: 0 / 7 / 44 / 644 / 4755 都是它的真实输出)<TAB>uid<TAB>gid | 无<TAB>-<TAB>-<TAB>-<TAB>- | 查询失败<TAB>原因
#   S = 运行态<TAB>自启态<TAB>MainPID<TAB>InvocationID<TAB>NRestarts(前两个非空)    L = 数字或 FP_BAD
#   结构不完整 = 观测无效, 不算真实差异(342 复现 XB2 / XB3)。
r1_fp_rec_ok(){   # $1=类型 $2=记录 → 0 结构完整 / 2 不完整
  local T=$'\t' re
  case "$1" in
    F) re="^(有${T}[0-9a-f]{64}${T}[0-7]{1,4}${T}[0-9]+${T}[0-9]+|无${T}-${T}-${T}-${T}-|查询失败${T}[^${T}]+)$";;
    S) re="^[^${T}]+${T}[^${T}]+${T}[^${T}]*${T}[^${T}]*${T}[^${T}]*$";;
    L) re="^([0-9]+|${FP_BAD})$";;
    *) return 2;;
  esac
  [[ "$2" =~ $re ]] && return 0
  return 2
}
R1_FV=""
r1_fp_field(){   # $1=记录 $2=第几个字段 → 0 取得(R1_FV) / 2 提取失败(cut 先输出后失败不采信; 342 复现 XB1)
  local out rc; R1_FV=""
  out="$(cut -f"$2" <<<"$1")"; rc=$?
  (( rc == 0 )) || { R1_WHY="取第 $2 个字段失败(cut 退出 $rc)"; return 2; }
  R1_FV="$out"
}
# 342: 一项读取 = 采样已完成 + 恰一条记录 + 结构完整 + 字段提取有效 + 不是"查询失败 / 无效"标记; 缺一样都不参与比较。
r1_fp_read(){   # $1=标签 $2=类型 $3=键 [$4=S 行的第几个字段] → 0 有效值(R1_FV) / 1 确认没有这条 / 2 观测无效(R1_WHY)
  local r
  R1_FV=""
  fp_get "$1" "$2" "$3"; r=$?
  case "$r" in
    0) ;;
    1) R1_WHY="$1 缺记录"; return 1;;
    *) if [[ "${FP_DONE[$1]:-0}" == 1 ]]; then R1_WHY="$1 读不了或同键重复"; else R1_WHY="$1 采样未完成"; fi; return 2;;
  esac
  r1_fp_rec_ok "$2" "$FP_REC" || { R1_WHY="$1 记录结构不完整([${FP_REC//$'\t'/|}])"; return 2; }
  if [[ -n "${4:-}" ]]; then
    r1_fp_field "$FP_REC" "$4" || { R1_WHY="$1 $R1_WHY"; return 2; }
  else
    R1_FV="$FP_REC"
  fi
  if [[ "$2" == F ]]; then
    [[ "${R1_FV%%$'\t'*}" != 查询失败 ]] || { R1_WHY="$1 查询失败(${R1_FV#*$'\t'})"; return 2; }
  else
    { [[ -n "$R1_FV" && "$R1_FV" != "$FP_BAD" ]]; } || { R1_WHY="$1 观测无效"; return 2; }
  fi
  return 0
}
r1_fp_item(){   # $1=before $2=after $3=类型(F|S|L) $4=键 [$5=S 行的第几个字段: 1 运行态 / 2 自启态] → 0 相等 / 1 不同 / 2 未取得(FP_WHY)
  local rb ra wb="" wa=""
  FP_B=""; FP_A=""; FP_WHY=""
  r1_fp_read "$1" "$3" "$4" "${5:-}"; rb=$?; FP_B="$R1_FV"; (( rb == 0 )) || wb="$R1_WHY"
  r1_fp_read "$2" "$3" "$4" "${5:-}"; ra=$?; FP_A="$R1_FV"; (( ra == 0 )) || wa="$R1_WHY"
  FP_WHY="$wb${wb:+${wa:+; }}$wa"
  [[ -z "$FP_WHY" ]] || return 2
  [[ "$FP_B" == "$FP_A" ]] && return 0
  return 1
}
# 341: 本场景的恢复账 —— 只由 A-4 / A-4b 在各项判定处记; A-7 只读这里(不看全局失败计数, 也不看有没有 FAIL 字样)。
A4_RESTORED=(); A4_DIFFER=(); A4_NOTOBT=()
r1_tally(){   # $1=ok|diff|na $2=项名
  case "$1" in ok) A4_RESTORED+=("$2");; diff) A4_DIFFER+=("$2");; *) A4_NOTOBT+=("$2");; esac
}
fp_cmp_files(){   # $1=before $2=after $3=场景名 —— 文件维逐项比对; 真实不同与观测无效 / 缺记录分开计
  local q n_ok=0 n_bad=0 n_na=0 r
  for q in "${FP_FILES[@]}"; do
    r1_fp_item "$1" "$2" F "$q"; r=$?
    case "$r" in
      0) n_ok=$((n_ok+1)); r1_tally ok "文件 $q";;
      1) n_bad=$((n_bad+1)); r1_tally diff "文件 $q"
         printf '    %-58s\n      前: %s\n      后: %s\n' "$q" "$FP_B" "$FP_A";;
      *) n_na=$((n_na+1)); r1_tally na "文件 $q"
         printf '    %-58s\n      未取得: %s\n' "$q" "$FP_WHY";;
    esac
  done
  (( n_bad == 0 && n_na == 0 )) && ok "$3: ${#FP_FILES[@]} 个受关注文件的**存在性/内容/mode/uid/gid** 四项全部回到前像"
  (( n_bad > 0 )) && bad "$3: 有 $n_bad 个文件没回到前像(上面逐项列出), 一致 $n_ok"
  (( n_na > 0 )) && bad "$3: 有 $n_na 个文件的前后观测无效或缺记录(上面逐项列出) —— 这些项的恢复结论未取得"
  return 0
}
# 341: 调用前必需观测是否齐且有效: 每个受关注文件恰一条且不是"查询失败"; 每个 unit 的运行态与自启态都取得; 两个监听数都取得。
r1_fp_valid(){   # $1=标签 → 0 齐且有效 / 2 不成立(R1_WHY 列出)
  local tag="$1" q u pt why=""
  [[ "${FP_DONE[$tag]:-0}" == 1 ]] || { R1_WHY="$tag 的采样没有完成(写入或读回核对失败)"; return 2; }
  for q in "${FP_FILES[@]}"; do r1_fp_read "$tag" F "$q" || why="$why 文件 $q: $R1_WHY;"; done
  for u in "${FP_SVCS[@]}"; do
    r1_fp_read "$tag" S "$u" 1 || why="$why $u 运行态: $R1_WHY;"
    r1_fp_read "$tag" S "$u" 2 || why="$why $u 自启态: $R1_WHY;"
  done
  for pt in 7894 53; do r1_fp_read "$tag" L "$pt" || why="$why 监听 $pt: $R1_WHY;"; done
  R1_WHY="${why# }"
  [[ -z "$why" ]] || return 2
  return 0
}
# 341: 旧版身份 —— $R1_CLI 与 OLD_SHA 里的 deploy/bot/pdg.sh 是同一对象; $REPO 的 HEAD == OLD_SHA。
#   每一步查询各自核退出码与输出形态; 读不到 ≠ 不符 ≠ 相符。A0 不用它(A0 按候选身份单独判)。
R1_ID_CLI=na; R1_ID_HEAD=na
r1_old_identity(){   # $1=标签 → 0 两项都成立 / 1 有效观测确认有不符 / 2 有观测无效(且没有确认的不符); R1_ID_CLI / R1_ID_HEAD = ok|diff|na
  local tag="$1" want got head rc
  R1_ID_CLI=na; R1_ID_HEAD=na
  want="$(git -C "$ORIGIN" rev-parse -q --verify "$OLD_SHA:deploy/bot/pdg.sh" 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ ! "$want" =~ ^[0-9a-f]{40}$ ]]; then
    bad "$tag 身份: 取不到 OLD_SHA 里 deploy/bot/pdg.sh 的对象(rc=$rc) —— $R1_CLI 的身份未取得"
  else
    got="$(git hash-object --no-filters -- "$R1_CLI" 2>/dev/null)"; rc=$?
    if (( rc != 0 )) || [[ ! "$got" =~ ^[0-9a-f]{40}$ ]]; then
      bad "$tag 身份: 读不到 $R1_CLI 的对象摘要(rc=$rc) —— 未取得"
    elif [[ "$got" == "$want" ]]; then
      R1_ID_CLI=ok; ok "$tag 身份: $R1_CLI 与 OLD_SHA 的 deploy/bot/pdg.sh 是同一对象(${got:0:12})"
    else
      R1_ID_CLI="diff"; bad "$tag 身份: $R1_CLI 不是 OLD_SHA 那一份(实得 ${got:0:12}, 应为 ${want:0:12})"
    fi
  fi
  head="$(git -C "$REPO" rev-parse -q --verify HEAD 2>/dev/null)"; rc=$?
  if (( rc != 0 )) || [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
    bad "$tag 身份: 读不到 $REPO 的 HEAD(rc=$rc) —— 未取得"
  elif [[ "$head" == "$OLD_SHA" ]]; then
    R1_ID_HEAD=ok; ok "$tag 身份: $REPO 的 HEAD == OLD_SHA(${OLD_SHA:0:12})"
  else
    R1_ID_HEAD="diff"; bad "$tag 身份: $REPO 的 HEAD 是 ${head:0:12}, 不是 OLD_SHA(${OLD_SHA:0:12})"
  fi
  [[ "$R1_ID_CLI" == diff || "$R1_ID_HEAD" == diff ]] && return 1
  [[ "$R1_ID_CLI" == ok && "$R1_ID_HEAD" == ok ]] && return 0
  return 2
}
# 341: 产品调用只在下面两个函数里发生; 调用前条件任一不成立就不调用, 原因留在 R1_GATE_WHY(由调用处记"未执行")。
R1_GATE_WHY=""
r1_a0_invoke(){   # A0 唯一的产品调用点 → 0 已调用(MG / MGRC) / 1 未调用
  MG=""; MGRC=""; R1_GATE_WHY=""
  if [[ "$R1_SRC_OLD" != 1 || "$R1_SRC_CAND" != 1 ]]; then R1_GATE_WHY="来源未核实成立(旧版=$R1_SRC_OLD 候选=$R1_SRC_CAND)"; return 1; fi
  # 346: 前像与本场景的 DNS 前提也在这里再核一次(装候选之前) —— 不只靠调用处的分支
  [[ "$PREIMAGE_OK" == 1 ]] || { R1_GATE_WHY="前像不成立"; return 1; }
  r1_dns_ready A0 "${A0_DNS:-}" || { R1_GATE_WHY="DNS 前提不成立: $DNS_PRE_WHY"; return 1; }
  install_candidate ios >/dev/null || { bad "A0: 装候选失败"; R1_GATE_WHY="装候选失败"; return 1; }
  switch_repo_to_candidate ios || { R1_GATE_WHY="部署源没有切到候选(见上)"; return 1; }
  systemctl daemon-reload
  assert_candidate_identity ios || { R1_GATE_WHY="候选部署身份不成立(见上)"; return 1; }
  echo
  echo "── 只跑新版 __migrate(不带前像句柄, 正是旧 CLI 子进程的形态) ──"
  MG="$(bash "$R1_CLI" __migrate 2>&1)"; MGRC=$?
  return 0
}
r1_a_invoke(){   # 场景 A 唯一的产品调用点(旧 CLI 的 dry-run 与正式 update) → 0 已调用(DRY / DRC / UP / URC) / 1 未调用
  DRY=""; DRC=""; UP=""; URC=""; R1_GATE_WHY=""
  if [[ "$R1_SRC_OLD" != 1 ]]; then R1_GATE_WHY="旧版来源(OLDSRC ⇔ OLD_SHA)未核实成立"; return 1; fi
  # 346: 前像与本场景的 DNS 前提在调用点再核一次 —— dry-run 与 update 都在它之后
  [[ "$PREIMAGE_OK" == 1 ]] || { R1_GATE_WHY="前像不成立"; return 1; }
  r1_dns_ready A "${A_DNS_BEFORE:-}" || { R1_GATE_WHY="DNS 前提不成立: $DNS_PRE_WHY"; return 1; }
  if ! r1_fp_valid A-before; then bad "A: 调用前必需观测无效 —— $R1_WHY"; R1_GATE_WHY="调用前必需观测无效"; return 1; fi
  r1_old_identity "A 升级前" || { R1_GATE_WHY="升级前旧版身份未成立(见上)"; return 1; }
  # 346: 服务动作窗口的起点 —— 所有前置门都过了才取; 取不到只让 A-5 的窗口记录记"未取得", 不阻断调用
  r1_jcursor || note "A: 服务动作窗口的起点未取得($R1_JCUR_WHY) —— A-5 的窗口记录将记未取得"
  DRY="$(bash "$R1_CLI" update --dry-run 2>&1)"; DRC=$?
  UP="$(bash "$R1_CLI" update 2>&1)"; URC=$?
  return 0
}
# 341(M2): 报告与恢复分账。只用 A-4 / A-4b 记下的本场景观测; 措辞只覆盖已检查范围; 旧版能力之外不为完整成功声明免责。
# 342: 固定串查询 —— 0 有 / 1 没有 / 2 查询失败(以前把查询失败当成"没有"; 342 复现 XC1 / XC2)
r1_text_has(){   # $1=固定串 $2=文本
  local r
  grep -qF -- "$1" <<<"$2"; r=$?
  (( r <= 1 )) && return "$r"
  return 2
}
r1_report_verdict(){
  local claim_ok=0 claim_part=0 named="" nd=${#A4_DIFFER[@]} nn=${#A4_NOTOBT[@]} nr=${#A4_RESTORED[@]} scope r_ok r_part rc
  scope="${#FP_FILES[@]} 个受关注文件的存在/内容/mode/属主、${#FP_SVCS[@]} 个 unit 的运行态与自启态、7894 与 53 的监听数、DNS 见证/对照、回滚后 CLI 与仓库 HEAD 的身份"
  r1_text_has '✅ 已回滚并重启服务' "$UP"; r_ok=$?
  r1_text_has '已回滚配置/服务, 但以下项未能恢复(未完全回滚)' "$UP"; r_part=$?
  if (( r_ok == 2 || r_part == 2 )); then
    bad "A-7 报告: 回滚收尾文字的查询失败(「✅ 已回滚并重启服务」=$r_ok /「未完全回滚」=$r_part; 0 有 / 1 没有 / 2 查询失败) —— 观测无效, 报告结论未取得"
    return 1
  fi
  (( r_ok == 0 )) && claim_ok=1
  if (( r_part == 0 )); then
    claim_part=1
    # 点名内容只作原文留存, 不参与判定、不作背书; 取不到就如实写"读取失败", 不写成"没点名"(342 复现 XC4)
    named="$(sed -n 's/.*已回滚配置\/服务, 但以下项未能恢复(未完全回滚): *//p' <<<"$UP")"; rc=$?
    if (( rc == 0 )); then named="${named%%$'\n'*}"; named="${named%%$'\e'*}"; else named="<读取失败(sed 退出 $rc)>"; fi
  fi
  if (( nr + nd + nn == 0 )); then bad "A-7 报告: 本场景没有记下任何恢复观测 —— 报告结论未取得"; return 1; fi
  if (( claim_ok && claim_part )); then bad "A-7 报告: 结局矛盾 —— 同一次输出里既有「✅ 已回滚并重启服务」又有「未完全回滚」"; return 1; fi
  if (( ! claim_ok && ! claim_part )); then bad "A-7 报告: 没有回滚收尾文字(报告缺失) —— 报告结论未取得"; return 1; fi
  if (( nd > 0 )); then
    if (( claim_ok )); then
      bad "A-7 报告与现场不符: 产品宣告「✅ 已回滚并重启服务」, 但有效观测确认 $nd 项未恢复: ${A4_DIFFER[*]}"
    else
      ok "A-7 报告项成立(只到「不完整」这一层): 产品没有宣告完整成功、报了未完全回滚, 与有效观测确认的 $nd 项未恢复一致($(printf '%s; ' "${A4_DIFFER[@]}")); 它点名的内容未经核验、不作背书(原文: ${named:-<空>}); 恢复项仍失败(见 A-4 / A-4b)"
    fi
    (( nn > 0 )) && note "A-7: 另有 $nn 项观测无效或缺记录(${A4_NOTOBT[*]}), 不进上面的结论"
    return 0
  fi
  if (( nn > 0 )); then bad "A-7 报告: 有 $nn 项观测无效或缺记录(${A4_NOTOBT[*]}) —— 报告是否与现场一致未取得"; return 1; fi
  if (( claim_ok )); then
    ok "A-7 报告: 已检查范围内恢复成立($nr 项), 成功声明与这些观测一致 —— 只覆盖 $scope, 不代表整个系统逐项恢复"
  else
    bad "A-7 报告: 产品报了未完全回滚(点名原文, 未核验: ${named:-<空>}), 而已检查的 $nr 项全部恢复 —— 它说的未恢复项是否在已检查范围之外未经核验, 报告是否属实未取得"
  fi
}

# ── 测试前置: 把冻结退役候选安装上去(只用于 A0 的阶段观测, 不是合法升级路径)──────
install_candidate(){   # $1=平台(默认取 $FROM)
  local n=0 name src mode plat="${1:-${FROM:-ios}}"
  install -m755 "$CANDSRC/deploy/bot/pdg.sh" "$R1_CLI" || return 1
  # shellcheck source=/dev/null
  source "$CANDSRC/lib/modules.sh" || return 1
  while read -r src name mode; do
    [[ -n "$name" ]] || continue
    install -m"${mode:-644}" "$CANDSRC/$src" "$R1_BOTDIR/$name" 2>/dev/null || return 1
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
# 346: 条件与标定由**本场景**自己建立(r1_dns_premise A0), 结果绑在场景名上; 前像已不成立时不再标定。
if [[ "$PREIMAGE_OK" == 1 ]]; then
  r1_dns_premise A0 || { PREIMAGE_OK=0; bad "验收前置未成立(A0): DNS $DNS_PRE_WHY"; }
fi

if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 A0: 前像/前置不成立(含 DNS 条件未建立或未通过标定), 本段未执行"
else
A0_INV="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
A0_PID="$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)"
A0_UNIT="$(sha256sum /etc/systemd/system/pdg-mitm.service | awk '{print $1}')"
A0_SCHEMA="$(python3 -c 'import json;print(json.load(open("/etc/privdns-gateway/ios-profile.json")).get("schema"))' 2>/dev/null)"
A0_HIJ="$(sha256sum /etc/mosdns/rules/mitm_hijack.txt | awk '{print $1}')"
A0_DNS="$(dns_feature_probe A0-before)"
note "A0: 前像的 DNS 观测 = $A0_DNS"
# 346: 调用前必须"查询有效 + 见证=H + 对照=U"(以前只在观测无效时打一条 FAIL, 仍然照常调用)
r1_dns_ready A0 "$A0_DNS" || bad "验收前置未成立(A0): $DNS_PRE_WHY —— __migrate 不调用"
# 装候选(测试前置), 并把部署身份与历史残留**分开**核验 —— 341: 连同 __migrate 一起收进 r1_a0_invoke, 任一前置不成立就不调用
if ! r1_a0_invoke; then
  nrun "场景 A0: 未调用 __migrate —— $R1_GATE_WHY"
else
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
r1_dns_settle "A0-3" A0 "$A0_DNS" "$A0_DNS_AFTER" 0
ss -lnt 2>/dev/null | grep -q ':7894 ' && ok "A0-3: 7894 仍有监听" || bad "A0-3: 7894 没有监听"
fi
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
# 346: 上面的 build_preimage 已让 A0 的 DNS 条件与标定失效(345 就栽在这: 对照名在调用前已答 H)。
#      场景 A 自己固定条件、标定并核还原, 再按 mosdns 的启动限额静置 —— 都在采前像与调用之前完成; 前像已不成立时不再做。
if [[ "$PREIMAGE_OK" == 1 ]]; then
  if ! r1_dns_premise A; then PREIMAGE_OK=0; bad "验收前置未成立(A): DNS $DNS_PRE_WHY"
  elif ! r1_mosdns_quiesce; then PREIMAGE_OK=0; bad "验收前置未成立(A): $DNS_PRE_WHY"
  fi
fi
snap_state A-before
fp_capture A-before || note "A: 调用前采样没有完成 —— $R1_WHY(随后的前置门据此不调用)"
svc_snapshot "$E2E_TMP/svc-A-before.tsv"
A_DNS_BEFORE="$(dns_feature_probe A-before)"
note "A: 前像的 DNS 观测 = $A_DNS_BEFORE"
# 346: 查询有效之外还必须真的是 见证=H、对照=U; 不成立 ⇒ dry-run 与 update 都不调用
if [[ "$PREIMAGE_OK" == 1 ]] && ! r1_dns_ready A "$A_DNS_BEFORE"; then bad "验收前置未成立(A): $DNS_PRE_WHY"; PREIMAGE_OK=0; fi

if [[ "$PREIMAGE_OK" != 1 ]]; then
  nrun "场景 A: 前像不成立, 本场景未执行(既不算通过也不算产品失败)"
else

# 341: 原来这里按 OLDSRC 的 sha256 核"更新器是原版", 不成立只打 FAIL 仍照常升级; 现并入 r1_a_invoke 的旧版身份门
#      (CLI 与 OLD_SHA 同一对象 + 仓库 HEAD == OLD_SHA), 连同来源与调用前必需观测, 任一不成立就不调用。
MITM_INV_BEFORE="$(systemctl show -p InvocationID --value pdg-mitm 2>/dev/null)"
MITM_PID_BEFORE="$(systemctl show -p MainPID --value pdg-mitm 2>/dev/null)"
MITM_NR_BEFORE="$(systemctl show -p NRestarts --value pdg-mitm 2>/dev/null)"
note "A: 前像里 pdg-mitm  MainPID=$MITM_PID_BEFORE  InvocationID=$MITM_INV_BEFORE  NRestarts=$MITM_NR_BEFORE"
JSTART="$(date -u +%FT%T)"

if ! r1_a_invoke; then
  nrun "场景 A: 未执行正式升级 —— $R1_GATE_WHY(dry-run 与 update 都没有调用)"
else
svc_snapshot "$E2E_TMP/svc-A-after.tsv"
r1_svc_collect A     # 346: 调用一返回就取窗口内的 journal(判定在 A-5)
echo "── 旧 CLI 的 dry-run(先看它怎么判关系) ──"
printf '%s\n' "$DRY" | _ev 03-A-dryrun.txt
echo "$DRY" | sed 's/^/    /' | head -20
[[ "$DRC" == 0 ]] && ok "A: dry-run rc=0" || bad "A: dry-run rc=$DRC"
grep -q "$TEST_TAG" <<<"$DRY" && ok "A: dry-run 认出目标是本轮的测试候选 tag" || bad "A: dry-run 没认出目标 tag"

echo; echo "── 真正跑**原版** pdg update(它会取件、装候选、调新版 __migrate, 被拒后调自己的 cmd_rollback) ──"
printf '%s\n' "$UP" | _ev 03-A-update.log
_evn 03-A-update.log "### 原始升级退出码 rc=$URC"
echo "$UP" | tail -60 | sed 's/^/    /'
snap_state A-after
fp_capture A-after || note "A: 回滚后采样没有完成 —— $R1_WHY(A-4 各项因此未取得)"
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
note '  原版回滚里那句 `systemctl is-enabled pdg-mitm && { reset-failed; restart pdg-mitm; }`'   # 346: 单引号 —— 以前双引号里的反引号在 runner 上被当命令执行了
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
echo "── A-4. 原版回滚的四维结果(逐项比对前像; 真实不同与观测无效 / 缺记录分开记) ──"
A4_RESTORED=(); A4_DIFFER=(); A4_NOTOBT=()
fp_cmp_files A-before A-after "A-4 文件"
for u in "${FP_SVCS[@]}"; do
  r1_fp_item A-before A-after S "$u" 1
  case $? in
    0) ok "A-4 运行态: $u 回到前像($FP_A)"; r1_tally ok "运行态 $u";;
    1) bad "A-4 运行态: $u 前像=$FP_B 现在=$FP_A"; r1_tally diff "运行态 $u";;
    *) bad "A-4 运行态: $u 前后观测无效或缺记录($FP_WHY) —— 未取得"; r1_tally na "运行态 $u";;
  esac
  r1_fp_item A-before A-after S "$u" 2
  case $? in
    0) ok "A-4 自启态: $u 回到前像($FP_A)"; r1_tally ok "自启态 $u";;
    1) bad "A-4 自启态: $u 前像=$FP_B 现在=$FP_A"; r1_tally diff "自启态 $u";;
    *) bad "A-4 自启态: $u 前后观测无效或缺记录($FP_WHY) —— 未取得"; r1_tally na "自启态 $u";;
  esac
done
r1_fp_item A-before A-after L 7894
case $? in
  0) ok "A-4 已加载配置(独立依据): 7894 的真实监听数与前像一致($FP_A) —— 服务确实在按恢复出来的配置提供服务"; r1_tally ok "7894 监听";;
  1) bad "A-4 已加载配置: 7894 监听数 前像=$FP_B 现在=$FP_A"; r1_tally diff "7894 监听";;
  *) bad "A-4 已加载配置: 7894 监听数观测无效或缺记录($FP_WHY) —— 未取得"; r1_tally na "7894 监听";;
esac
# 产品自己写下的前像与测试指纹逐项对账(两边必须看到同一件事)
A_SNAP="$(ls -1dt "${SNAP_DIR:-/var/lib/privdns-gateway/backups}"/* 2>/dev/null | head -1)"
if [[ -n "$A_SNAP" && -s "$A_SNAP/svcstate.tsv" ]]; then
  note "A-4: 产品写的前像 = $A_SNAP/svcstate.tsv"
  svcstate_cross_check "$A_SNAP/svcstate.tsv" "A-4"
else
  note "A-4: 这一轮没找到产品写的 svcstate.tsv(旧 CLI 的快照本来就没有这一份, 属预期)"
fi
A_DNS_AFTER="$(dns_feature_probe A-after)"
r1_dns_settle "A-4" A "$A_DNS_BEFORE" "$A_DNS_AFTER" 1   # 346: 判词与记账同一处给出; 前提不成立 / 观测无效 ⇒ 未取得, 不进"未恢复"
r1_fp_item A-before A-after L 53
case $? in
  0) ok "A-4(辅助) 53/udp 监听数与前像一致($FP_A)"; r1_tally ok "53 监听";;
  1) bad "A-4(辅助) 53 监听 $FP_B → $FP_A"; r1_tally diff "53 监听";;
  *) bad "A-4(辅助) 53 监听数观测无效或缺记录($FP_WHY) —— 未取得"; r1_tally na "53 监听";;
esac
if command -v dig >/dev/null 2>&1; then
  DR="$(dig +time=3 +tries=1 @127.0.0.1 example.com A 2>&1 | head -20)"
  printf '%s\n' "$DR" | _ev 03-A-dig.txt
  grep -qE 'status: (NOERROR|NXDOMAIN)' <<<"$DR" \
    && ok "A-4(辅助) 本机 53 真的能应答(status=$(grep -o 'status: [A-Z]*' <<<"$DR" | head -1)) —— 只说明解析器活着, **不**说明加载的是哪一份配置" \
    || note "A-4(辅助) 本机 53 未能应答(runner 出网受限时属预期, 已留证不作判据)"
fi

echo
echo "── A-4b. 回滚后的旧版身份(独立结算; 不以产品「仓库已复位」的文案代替) ──"
r1_old_identity "A-4b 回滚后"
r1_tally "$R1_ID_CLI" "身份 $R1_CLI"; r1_tally "$R1_ID_HEAD" "身份 $REPO HEAD"
note "A-4 / A-4b 小计(本场景已检查范围): 已恢复 ${#A4_RESTORED[@]} / 未恢复 ${#A4_DIFFER[@]} / 未取得 ${#A4_NOTOBT[@]}"

echo
echo "── A-5. 服务动作(终态 / 实例变化 / 窗口内记录到的启停 分开表述; 依据是冻结旧版的执行路径) ──"
note "A-5 终态: 各 unit 的运行态 / 自启态是否回到前像, 见上面 A-4 的逐项结论(这里不重复判)。"
r1_svc_window "$E2E_TMP/svc-A-before.tsv" "$E2E_TMP/svc-A-after.tsv" A
note "A-5: 「门前零退役动作」由场景 A0 的阶段观测给出; 这里列的是整个拒绝—回滚过程里记录到的启停, 不把前者写成后者。"

echo
echo "── A-6. 退出码与用户看到的文字 ──"
_evn 03-A-update.log "### 原始升级 rc=$URC"
[[ "$URC" != 0 ]] && ok "A-6: 原始升级退出码非 0(实得 $URC) —— 失败没有被报成成功" || bad "A-6: 升级返回 0"
RB_LINE="$(grep -E '✅ 已回滚并重启服务|已回滚配置/服务.*未完全回滚' <<<"$UP" | head -1)"
note "A-6: 回滚收尾文字: ${RB_LINE:-<没有>}"
_evn 03-A-update.log "### 回滚收尾文字: ${RB_LINE:-<没有>}"

echo
echo "── A-7. 回滚报告与现场(与 A-4 的恢复结论分开结算; 只用本场景的有效观测) ──"
r1_report_verdict
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

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 每个 E2E 都必须**自带完整前提**(hermetic): 在同一个环境里按任意顺序连着跑, 结果要和各自
# 单独跑一模一样。
#
# 这条纪律被破过一次, 而且是在 CI 上: e2e-cross-version-rollback 会在 /usr/local/bin 留下
# 一个 sing-box 二进制, 而 e2e-install 的 reset_box 不清它 —— 下一个脚本的装机路径于是判成
# "机器上已有来源不明的 sing-box"直接中止。CI 里 e2e 是同一个 Debian 容器里顺序跑的, 所以
# 单独跑 23/23 的用例在 CI 上只有 11/34, 而失败原因跟被测代码毫无关系。
#
# 本用例把 CI 的串行条件原样搭出来: 一个沙箱(= 一个容器)里, 用 PDG_E2E_ISOLATED=1 依次跑
# 多个脚本, 断言每个都全绿。CI 侧另外改成了 matrix(每个脚本独立 job/独立容器), 两道保险。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 串行跑哪些脚本: 默认取"曾经互相踩过"的那一组(跨版本回滚留 sing-box → 装机 → 更新)。
SCRIPTS="${PDG_SERIAL_SCRIPTS:-e2e-cross-version-rollback.sh e2e-install.sh e2e-update.sh}"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# 缺必需前提时的出口。语义与 e2e-lib 的 e2e_skip 一致(本文件不加载共享库, 只取这段判定):
# 严格模式(CI=true, 或 PDG_TEST_STRICT 非空且不为 0)判失败返回非零; 否则明确跳过返回 0 ——
# 跳过不算通过。先前这里是裸 `exit 0`, CI 里前提缺失也会被记成绿。
_serial_skip(){
  echo "[SKIP] $1"
  echo "────────────────────────────────────────"
  if [[ -n "${PDG_TEST_STRICT:-}" && "${PDG_TEST_STRICT}" != "0" ]] || [[ "${CI:-}" == "true" ]]; then
    echo "严格模式(PDG_TEST_STRICT/CI): 缺必需前提 → 判失败, 不拿 SKIP 冒充通过"
    echo "通过 0, 失败 1(前提缺失)"
    exit 1
  fi
  echo "通过 0, 失败 0(已跳过)"
  exit 0
}

# ── 外层: 造一个沙箱(等价于 CI 的一次性容器), 内层在里面串行跑 ────────────────
if [[ "${PDG_SERIAL_INNER:-}" != 1 ]]; then
  if [[ "${PDG_E2E_ISOLATED:-}" == 1 && "$(id -u)" == 0 ]]; then
    PDG_SERIAL_INNER=1 exec bash "$0" "$@"       # CI: 本来就在一次性容器里
  fi
  unshare -rm true 2>/dev/null || _serial_skip "本环境不支持 unshare -rm"
  OVL="$(mktemp -d)"
  mkdir -p "$OVL"/{eu,ew,bu,bw,ou,ow,vu,vw}
  mkdir -p "$OVL"/eu/{mosdns/rules,sing-box,mihomo,privdns-gateway,systemd/system,systemd/journald.conf.d}
  : > "$OVL"/eu/nftables.conf
  rc=0
  PDG_SERIAL_INNER=1 OVL="$OVL" E2E_ROOT="$E2E_ROOT" unshare -rm bash "$0" "$@" || rc=$?
  unshare -rm bash -c 'rm -rf "$1"' _ "$OVL" 2>/dev/null || rm -rf "$OVL" 2>/dev/null
  exit "$rc"
fi

# ── 内层: 挂上和单脚本沙箱同样的 overlay, 然后串行跑 ─────────────────────────
if [[ -n "${OVL:-}" ]]; then
  mount -t overlay overlay -o "lowerdir=/etc,upperdir=$OVL/eu,workdir=$OVL/ew" /etc \
    || _serial_skip "overlay /etc 挂不上"
  mount -t overlay overlay -o "lowerdir=/usr/local/bin,upperdir=$OVL/bu,workdir=$OVL/bw" /usr/local/bin
  mount -t overlay overlay -o "lowerdir=/opt,upperdir=$OVL/ou,workdir=$OVL/ow" /opt
  mount -t tmpfs tmpfs /run 2>/dev/null || true
  mount -t overlay overlay -o "lowerdir=/var/lib,upperdir=$OVL/vu,workdir=$OVL/vw" /var/lib \
    2>/dev/null || mount -t tmpfs tmpfs /var/lib 2>/dev/null || true
  mkdir -p /var/lib/privdns-gateway 2>/dev/null || true
  grep -q 'directory = \*' /etc/gitconfig 2>/dev/null \
    || printf '[safe]\n\tdirectory = *\n' >> /etc/gitconfig 2>/dev/null || true
fi

echo "串行顺序: $SCRIPTS"
echo "(每个脚本都以 PDG_E2E_ISOLATED=1 跑在同一个沙箱里 —— 与 CI 的容器 job 同条件)"

# ── 串行专属: 每支跑完清点"有没有把自己的后台进程留给下一支" ────────────────
# 沙箱是 `unshare -rm`(用户+挂载), **没有** PID namespace —— 后台进程不随沙箱拆除而消失。
# 单独跑时留下的进程随 job 结束一起没了, 看不出来; 串行里它会攥着端口与内存活到后面几支,
# 于是下一支的失败原因跟被测代码无关。所以清点放在**每支之后**, 不是最后统一看。
#
# 认的是本项目自己起的那几类(按 cmdline 特征), 不拿"任何新进程"当残留 —— 那会把
# runner 自己的东西也算进来。
#
# 先排掉"自己人": pgrep 认的是 cmdline, 而 runner 自己(或手工跑它的那条命令)的 cmdline
# 里完全可能原样带着这些路径 —— 实测踩过一次, 一条内联命令把自身匹成了"残留"。
# 排的是本进程及其祖先, 外加 cmdline 与本进程逐字节相同的那些(fork 出来的副本)。
# 这不会漏掉真残留: mosdns/dotwitness/tx-probe 的 cmdline 与 runner 的不可能相同。
_self_pids(){
  local p=$$ ppid me
  while [[ -n "$p" && "$p" != 0 && -r "/proc/$p/status" ]]; do
    printf '%s\n' "$p"
    ppid="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)"
    [[ -z "$ppid" || "$ppid" == "$p" ]] && break
    p="$ppid"
  done
  me="$(tr '\0' ' ' </proc/$$/cmdline 2>/dev/null)"
  # /proc 是会跑的: 进程可能在 glob 之后、读之前就没了。整块压掉 stderr, 否则这个
  # 竞态会把 "No such file" 混进串行 runner 的正文输出里。
  { [[ -n "$me" ]] && for d in /proc/[0-9]*; do
      [[ "$(tr '\0' ' ' <"$d/cmdline")" == "$me" ]] && printf '%s\n' "${d#/proc/}"
    done; } 2>/dev/null
  return 0
}
# 三态, 用退出码区分 —— 原先末尾一个 `|| true` 把所有错误都抹成"输出为空",
# 调用处又只看 stdout 空不空, 于是**查询失败会被念成「没有留下后台进程」**:
# 最需要它说话的时候(环境坏了)它最安静。
#   0 = 观测成功, 零残留
#   1 = 观测成功, 发现残留(已打印)
#   2 = 观测失败, 本次结论无效(既不能说有, 也不能说没有)
_serial_leftovers(){
  local raw rc self skip out
  raw="$(pgrep -a -f 'e2e-mos\.yaml|/opt/pdg-bot/dotwitness\.py|e2e-tx-probe|pdg-e2e-dw' 2>/dev/null)"
  rc=$?
  # pgrep 的退出码有约定: 0=有匹配, 1=**一个都没匹配到**(正常结果, 不是错误),
  # 2=用法/语法错, 3=致命错。所以只有 >=2 才是"没问过成功"。
  (( rc >= 2 )) && return 2
  (( rc == 1 )) && return 0
  # 命令失败前吐的半截输出不能拿来下结论 —— 上面已按 rc 分流, 走到这里 raw 才是完整的。
  self="$(_self_pids | sort -u)" || return 2
  # 连自己都认不出来, 说明 /proc 读不到: 这时候排除名单是空的, 会把 runner 自己
  # 报成残留。那是观测不可信, 不是"发现了残留"。
  [[ -n "$self" ]] || return 2
  skip="|$(printf '%s\n' "$self" | tr '\n' '|')"
  out="$(printf '%s\n' "$raw" | awk -v skip="$skip" 'index(skip, "|" $1 "|")==0')" || return 2
  [[ -z "$out" ]] && return 0
  printf '%s\n' "$out"
  return 1
}
# 内存只**记录**, 不在这里定上限: "多少算超"是环境策略(容器/runner 各不相同), 由
# 跑批的人定; 这里把数据留下来, 让那个决定有依据, 而不是现在拍一个数字。
_memfree(){ awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo ""; }
_MEM0="$(_memfree)"; _MEM_TRACE=""
[[ -n "$_MEM0" ]] && echo "串行开始: MemAvailable ${_MEM0} kB"

for s in $SCRIPTS; do
  [[ -f "$HERE/$s" ]] || { bad "找不到 $s"; continue; }
  out="$(PDG_E2E_ISOLATED=1 E2E_ROOT="$E2E_ROOT" bash "$HERE/$s" 2>&1)"; rc=$?
  _left="$(_serial_leftovers)"; _lrc=$?
  _m="$(_memfree)"; _MEM_TRACE="${_MEM_TRACE}${s}=${_m:-?} "
  # 接的是**状态**, 不只是 stdout —— 空输出有两种截然不同的来源(真干净 / 没问成)。
  # 三态各自的去向。**1 和 2 都停**, 但理由不同, 分开具名, 不混成同一种失败:
  #   1 = 确认有残留 —— 下一支的前提已经被破坏了(它会跟这个泄漏体抢端口/锁),
  #       继续跑出来的红绿都不作数。
  #   2 = 没问成    —— 前提**未知**。未知不等于干净, 也不等于有残留。
  # 两种情况都**不**动那些进程: 停在这里, 把现场留给人看。身份不明的东西不由
  # 测试脚本去杀 —— 宽匹配杀进程正是先前踩过的坑。
  case "$_lrc" in
    0) ok "$s 跑完没有留下本项目的后台进程" ;;
    1) bad "$s 跑完**确认留下了**本项目的后台进程(沙箱没有 PID namespace, 它会活到下一支):"
       printf '%s\n' "$_left" | head -5 | sed 's/^/       /'
       echo "       串行前提已被破坏, 就此停止 —— 不在前提已坏的情况下继续跑下一支。"
       echo "       上列进程**原样保留**, 本脚本不代为终止(身份要由人确认)。"
       break ;;
    *) bad "$s 跑完**残留观测失败**(_serial_leftovers rc=$_lrc) —— 不知道有没有残留"
       echo "       串行的前提(上一支没把东西留给下一支)本轮无法证实, 后面几支的结论"
       echo "       都会建立在一个没验过的前提上。就此停止 —— 不拿「查询失败」当「干净」放行。"
       echo "       也不据此判定有残留: 未知就是未知, 不代为终止任何进程。"
       break ;;
  esac
  line="$(grep -oE '通过 [0-9]+, 失败 [0-9]+' <<<"$out" | tail -1)"
  npass="$(grep -oE '通过 [0-9]+' <<<"$line" | grep -oE '[0-9]+')"
  if [[ "$rc" != 0 ]] || grep -q '失败 [1-9]' <<<"${line:-失败 0}"; then
    bad "$s 串行跑失败 rc=$rc  ($line)"
    grep -E '^\[FAIL\]' <<<"$out" | head -5 | sed 's/^/       /'
  elif [[ -z "$npass" || "$npass" == 0 ]]; then
    # 断言数为 0 = 这个脚本被 skip 了。串行场景下最常见的原因正是"上一个脚本留下/清掉了
    # 什么, 让这个脚本的前提不成立" —— 当成绿的就是假绿, 必须点出来。
    bad "$s 串行跑时被跳过(零断言) —— 前提在串行环境里不成立:"
    grep -E '^\[SKIP\]|SKIP' <<<"$out" | head -3 | sed 's/^/       /'
  else
    ok "$s 串行跑仍全绿  ($line)"
  fi
done

# 内存轨迹只作记录, 不参与判定 —— 上限该取多少由跑批环境决定, 这里只提供依据。
if [[ -n "$_MEM0" ]]; then
  echo "MemAvailable 轨迹(kB): 起点=$_MEM0  $_MEM_TRACE"
  _mend="$(_memfree)"
  [[ -n "$_mend" ]] && echo "  全程净变化: $(( _mend - _MEM0 )) kB(仅记录, 不判定)"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

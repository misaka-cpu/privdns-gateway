#!/usr/bin/env bash
# shellcheck disable=SC2034  # EV_RC / EV_LINES / EV_ERR / EV_GUARD_EXIT 是留给调用方读的
# ─────────────────────────────────────────────────────────────────────────────
# tools/evidence/evlib.sh —— 发版验收「远端取证」脚本的共用函数(只读: 不改远端任何东西)。
#
# 远端脚本一般经 ssh 以 `bash -s` 喂进去, 这个库就拼在它前面一起喂:
#     cat tools/evidence/evlib.sh check.sh | ssh … bash -s
# 本机脚本里直接 `source tools/evidence/evlib.sh`。
#
# 每个函数都对着一次踩过的坑写的(tools/evidence/README.md 逐条列了出处)。几条通则:
#   · 不用 awk、不用 grep: 远端是 mawk(不认正则里的 {n} 区间), 本机交互壳里的 grep 是包装函数;
#     计数与查找一律用 bash 自己做, 两边行为一样;
#   · 不经管道判断"有没有": `上游 | grep -q` 在 pipefail 下会因 SIGPIPE 把"有"判成"没有";
#   · 采不到 ≠ 0 条: journalctl 出错时返回非 0 并把它的错误原样打出来, 绝不当成"这段时间没有日志";
#   · 守卫失败就退出整个脚本(退出码 EV_GUARD_EXIT), 不靠调用方记得写 `|| exit`; 通过时也打一行,
#     "绿的时候什么都不打印"等于没有观测。
# 需要 bash 4.4+(Debian 12 / Ubuntu 24.04 都满足)。
# ─────────────────────────────────────────────────────────────────────────────

EV_GUARD_EXIT=86
EV_RC=""; EV_LINES=""; EV_ERR=""

# ev_init: 固定区域与时区。C.UTF-8 下 bash 按字符处理字符串(C 区域下按字节, 会截出半个汉字);
# TZ=UTC 让 journalctl -o short-iso 打 UTC 时间, 按日分组才对得上。C.UTF-8 不可用时返回 1。
ev_init(){
  export LC_ALL=C.UTF-8 TZ=UTC
  local s='汉字'
  if (( ${#s} != 2 )); then
    echo "[ev] 本机没有可用的 C.UTF-8: 按字符处理会退化成按字节" >&2
    return 1
  fi
  return 0
}

# ev_ts_ok <时刻>: 是不是 journalctl 认的 'YYYY-MM-DD HH:MM:SS UTC'。
# systemd 252 的 journalctl 不认 ISO 的 T / Z 写法(Failed to parse timestamp), 所以只放这一种。
ev_ts_ok(){
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ UTC$ ]]
}

# ev_ts_from_iso <时刻>: 把 `date -u +%FT%TZ` 那种 ISO 写法转成 ev_ts_ok 的写法并打印; 本来就合格的原样打印。
# 别的写法返回 2, 什么都不打印 —— 不去猜。
ev_ts_from_iso(){
  local t="${1:-}"
  if ev_ts_ok "$t"; then printf '%s\n' "$t"; return 0; fi
  if [[ "$t" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})(Z|\+00:00)$ ]]; then
    printf '%s %s UTC\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0
  fi
  return 2
}

_ev_name_ok(){ [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# ev_journal <变量名> <起> <止> [journalctl 的选择参数 …]
#   取 [起, 止) 这一段日志(-q -a -o short-iso, TZ=UTC), 原样存进 <变量名>; 起止必须是 ev_ts_ok 的写法。
#   打一行抬头 `[ev journal rc=… 行数=… 起=… 止=… 选择=…]`, 并设 EV_RC / EV_LINES / EV_ERR。
#   返回: 0 = 采到了(行数可以是 0); 2 = 参数不对, 没有调 journalctl; 3 = journalctl 出错(stderr 逐行打出)。
#   -a: 带颜色转义的行不加 -a 会显示成 [N B blob data], 按字串就找不到。
ev_journal(){
  local _ev_var="${1:-}" _ev_from="${2:-}" _ev_until="${3:-}" _ev_out _ev_errf _ev_l
  EV_RC=""; EV_LINES=""; EV_ERR=""
  # 变量名不能以 _ev_ 开头: printf -v 会写进本函数同名的局部变量, 调用方那边什么都拿不到
  if ! _ev_name_ok "$_ev_var" || [[ "$_ev_var" == _ev_* ]]; then
    echo "[ev journal] 第一个参数要是变量名(不能以 _ev_ 开头), 收到: [$_ev_var]"; return 2
  fi
  if ! ev_ts_ok "$_ev_from" || ! ev_ts_ok "$_ev_until"; then
    echo "[ev journal] 起止时刻要写成 'YYYY-MM-DD HH:MM:SS UTC'(systemd 252 不认 ISO 的 T/Z), 收到: [$_ev_from] [$_ev_until]"
    return 2
  fi
  shift 3
  _ev_errf="$(mktemp)" || { echo "[ev journal] 建不出临时文件"; return 3; }
  _ev_out="$(TZ=UTC LC_ALL=C.UTF-8 journalctl --since "$_ev_from" --until "$_ev_until" --no-pager -q -a -o short-iso "$@" 2>"$_ev_errf")"  # ev-lint: ignore=E11
  EV_RC=$?
  EV_ERR="$(<"$_ev_errf")"; rm -f "$_ev_errf"
  printf -v "$_ev_var" '%s' "$_ev_out"
  EV_LINES="$(ev_lines "$_ev_out")"
  echo "[ev journal rc=$EV_RC 行数=$EV_LINES 起=$_ev_from 止=$_ev_until 选择=$*]"
  if [[ "$EV_RC" != 0 || -n "$EV_ERR" ]]; then
    while IFS= read -r _ev_l; do echo "[ev journal stderr] $_ev_l"; done <<<"${EV_ERR:-(没有 stderr, 只有非 0 退出码)}"
    return 3
  fi
  return 0
}

# ev_events <变量名> <起> <止>: 取这一段的机读事件(docs/events.md, SYSLOG_IDENTIFIER=pdg-event)。返回值同 ev_journal。
ev_events(){ ev_journal "${1:-}" "${2:-}" "${3:-}" -t pdg-event; }

# ev_lines <文本>: 非空行数。
ev_lines(){
  local n=0 l
  [[ -n "${1:-}" ]] || { echo 0; return 0; }
  while IFS= read -r l; do [[ -n "$l" ]] && n=$((n + 1)); done <<<"$1"
  echo "$n"
}

# ev_has <文本> <字串>: 有没有一行**按字面**含这个字串(不当正则)。只返回 0 / 1, 不打印。
ev_has(){
  local l
  [[ -n "${2:-}" ]] || return 1
  while IFS= read -r l; do [[ "$l" == *"$2"* ]] && return 0; done <<<"${1:-}"
  return 1
}

# ev_count_fixed <文本> <字串>: 按字面含这个字串的行数(字串里的 [ ] . * 都不是元字符)。
ev_count_fixed(){
  local n=0 l
  [[ -n "${2:-}" ]] || { echo 0; return 0; }
  while IFS= read -r l; do [[ "$l" == *"$2"* ]] && n=$((n + 1)); done <<<"${1:-}"
  echo "$n"
}

# ev_count_tokens <文本> <词> [<词> …]: 同时含这些**整词**(两侧是空格或行首尾)的行数。
# 给机读事件用: to=v1.19.3 不算 to=v1.19.34。
ev_count_tokens(){
  local text="${1:-}" n=0 l t hit
  shift || true
  (( $# > 0 )) || { echo 0; return 0; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    hit=1
    for t in "$@"; do [[ " $l " == *" $t "* ]] || { hit=0; break; }; done
    (( hit )) && n=$((n + 1))
  done <<<"$text"
  echo "$n"
}

# ev_count_by_day <文本> <字串>: 按字面含这个字串的行, 按行首的日期(short-iso 的前 10 个字符)分组计数。
# 打印 `  <日期> <数>` 若干行(按日期排序) 和 `  合计 <数>`; 行首不是日期的归到「其它」。日期按 UTC 才准 —— 先 ev_init。
ev_count_by_day(){
  local l d total=0 k
  local -A by=()
  if [[ -n "${2:-}" ]]; then
    while IFS= read -r l; do
      [[ "$l" == *"$2"* ]] || continue
      d="${l:0:10}"
      [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || d=其它
      by[$d]=$(( ${by[$d]:-0} + 1 )); total=$((total + 1))
    done <<<"${1:-}"
  fi
  if (( total > 0 )); then
    while IFS= read -r k; do printf '  %s %s\n' "$k" "${by[$k]}"; done < <(printf '%s\n' "${!by[@]}" | LC_ALL=C sort)
  fi
  printf '  合计 %s\n' "$total"
}

# ev_cut_chars <字串> <N>: 前 N 个**字符**(不是字节; tr / cut -c 按字节切, 会切出半个汉字)。
ev_cut_chars(){
  local LC_ALL=C.UTF-8 s="${1:-}" n="${2:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "[ev] ev_cut_chars 的 N 要是非负整数: [$n]" >&2; return 2; }
  printf '%s\n' "${s:0:n}"
}

# ev_run <标签> <命令> [参数 …]: 打 `== <标签>`, 跑命令(stdin 接 /dev/null, stdout / stderr 原样合并),
# 再打 `[<标签> rc=N]`, 返回命令的退出码。
# 远端脚本是从 stdin 喂进 `bash -s` 的: 中间哪条命令读了 stdin, 就把后面的脚本当输入吃掉了 ——
# 后面的段落全部没跑, 输出里看着只是"到这里就结束了"。
ev_run(){
  local label="${1:-}" rc
  shift || true
  echo "== $label"
  (( $# > 0 )) || { echo "[$label rc=2] (没有给命令)"; return 2; }
  "$@" < /dev/null 2>&1
  rc=$?
  echo "[$label rc=$rc]"
  return "$rc"
}

# ── 守卫: 不通过就打一行 `[ev 守卫失败] …` 并以 EV_GUARD_EXIT 退出整个脚本; 通过打 `[ev 守卫通过] …`。
# 只能在脚本的主流程里调: 放进 $(…)、管道或 ( … ) 里, exit 只退出那个子 shell, 后面照样往下跑。
# 所以在子 shell 里被调到时先大声说出来(ev-lint 的 E9 也会在静态检查时拦下)。
_ev_guard_fail(){
  echo "[ev 守卫失败] $*"
  (( BASH_SUBSHELL > 0 )) && echo "[ev 守卫失败] ⚠️ 这是在子 shell 里调的守卫: exit 只退出子 shell, 外面的脚本还会往下跑" >&2
  exit "$EV_GUARD_EXIT"
}

# ev_guard_eq <标签> <实际> <期望>
ev_guard_eq(){
  if [[ "${2-}" == "${3-}" ]]; then echo "[ev 守卫通过] ${1:-} = [${3-}]"; return 0; fi
  _ev_guard_fail "${1:-} 不符: 实际=[${2-}] 期望=[${3-}]"
}

# ev_guard_nonempty <标签> <值>: 抽取结果不能是空的 —— 两边都抽成空串时"相等"比对照样通过。
ev_guard_nonempty(){
  if [[ -n "${2-}" ]]; then echo "[ev 守卫通过] ${1:-} 非空(${#2} 个字符)"; return 0; fi
  _ev_guard_fail "${1:-} 是空的(抽取 / 采集什么都没拿到)"
}

# ev_guard_rc <标签> <退出码> [<允许的退出码> …]: 不给允许值时只允许 0。
ev_guard_rc(){
  local label="${1:-}" rc="${2-}" a
  shift 2 || true
  (( $# > 0 )) || set -- 0
  for a in "$@"; do [[ "$rc" == "$a" ]] && { echo "[ev 守卫通过] $label rc=$rc"; return 0; }; done
  _ev_guard_fail "$label rc=$rc, 允许的是: $*"
}

# ev_guard_sha256 <文件> <期望的 sha256>: 文件要在、非空、摘要相等。
ev_guard_sha256(){
  local f="${1:-}" want="${2:-}" got
  [[ -s "$f" ]] || _ev_guard_fail "$f 不存在或是空文件"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || _ev_guard_fail "给 $f 的期望摘要不是 64 位十六进制: [$want]"
  got="$(sha256sum < "$f")" || _ev_guard_fail "$f 算不出 sha256"
  got="${got%% *}"
  [[ "$got" == "$want" ]] || _ev_guard_fail "$f 的 sha256 不符: 实际=$got 期望=$want"
  echo "[ev 守卫通过] $f sha256=$got"
}

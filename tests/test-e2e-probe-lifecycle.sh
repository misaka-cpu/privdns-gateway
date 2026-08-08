#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# E2E 事务探针的**生命周期**回归(测试框架自身的可靠性)。
#
# 起因: e2e-lib.sh 的 e2e_tx_probes() 曾用 `setsid python3 /tmp/e2e-tx-probe.py … &` 起探针,
# 既不记 PID 也不清理 —— 每跑一个 E2E 就留一个 PPID=1 的孤儿(e2e-install.sh 在同一进程里多次
# e2e_stub_system, 一个脚本就留好几个)。它们还持有已删除的 overlay 文件: 现场累积到 215 个、
# 占掉约 4GB, 磁盘打满后全量测试只能人工 kill 才能继续。
#
# 这里验的是"进程与临时文件到底有没有被收干净", 全部按**真实行为**判:
#   · 只数精确匹配本测试临时路径的进程(绝不 pkill python3, 也不靠"跑完杀光"掩盖泄漏);
#   · 每条断言都能因实现退回旧样子而变红。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
skip(){ echo "[SKIP] $1"; }          # 不计入 pass

# 本测试专属的探针标记: 让 e2e-lib 把临时文件建在这个目录下, 于是"数进程"可以精确到本实例
WORK="$(mktemp -d "${TMPDIR:-/tmp}/e2e-probe-life.XXXXXX")"
export TMPDIR="$WORK"                       # e2e-lib 的 mktemp 会落在这里
# 这里**不能**直接 `trap ... EXIT`: source e2e-lib.sh 之后第一次 e2e_tx_probes 会通过
# e2e_add_exit_hook 重设统一的 EXIT trap, 把这条顶掉 —— 于是每跑一次就留一个空的
# /tmp/e2e-probe-life.*。改为在 source 之后注册具名清理函数(见 _life_cleanup)。

# 只数"命令行里带本测试 WORK 前缀"的探针进程 —— 与并发跑的其它 E2E、其它 python3 完全隔离
probe_count(){ pgrep -f -- "$WORK/e2e-tx-probe\." 2>/dev/null | wc -l | tr -d ' '; }
orphan_count(){
  local n=0 p
  for p in $(pgrep -f -- "$WORK/e2e-tx-probe\." 2>/dev/null || true); do
    [[ "$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 0)" == 1 ]] && n=$((n+1))
  done
  echo "$n"
}
tmpfile_count(){ find "$WORK" -maxdepth 1 -name 'e2e-tx-probe.*' 2>/dev/null | wc -l | tr -d ' '; }

[[ "$(probe_count)" == 0 ]] && ok "开跑前本实例探针数为 0(计数口径只认本测试的临时路径)" \
  || bad "开跑前就有 $(probe_count) 个本实例探针?"

# shellcheck source=tests/e2e-lib.sh
source "$HERE/e2e-lib.sh"
# e2e-lib.sh 自己也定义 ok()/bad()(记到 E2E_PASS/E2E_FAIL)—— source 之后会盖掉上面那两个,
# 于是本测试的计数只会停在 1。把本测试的计数函数重新定义回来。
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 本测试的夹具清理: **先收探针再删目录** —— 反过来会把探针脚本先删掉, 那时 _e2e_probe_is_mine
# 靠 cmdline 认身份还认得出, 但材料已经没了; 顺序固定更稳。只删本实例精确持有的 $WORK,
# 不碰并发实例的目录; 重复调用安全; 不改变退出码。
_life_cleanup(){
  e2e_tx_probe_stop || true
  [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
  return 0
}
e2e_add_exit_hook _life_cleanup             # 异常中断时的兜底(正常流程末尾会显式再调一次)

# ── 1. 单次启动: 就绪成功 / PID 活着 / ports 三个合法端口 / 文件属于本实例 ──
if e2e_tx_probes; then
  ok "单次启动: e2e_tx_probes 返回 0"
else
  bad "单次启动失败"
fi
if [[ -n "${E2E_TX_PROBE_PID:-}" ]] && kill -0 "$E2E_TX_PROBE_PID" 2>/dev/null; then
  ok "单次启动: 探针 PID($E2E_TX_PROBE_PID)活着且被父脚本记着"
else
  bad "没有可用的探针 PID"
fi
_ports="$(cat "$E2E_TX_PROBE_PORTS" 2>/dev/null || echo)"
if [[ "$_ports" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]]; then
  ok "单次启动: ports 文件是三个合法端口($_ports)"
else
  bad "ports 文件内容不合法: [$_ports]"
fi
if [[ "$E2E_TX_PROBE_SCRIPT" == "$WORK/"* && "$E2E_TX_PROBE_PORTS" == "$WORK/"* ]]; then
  ok "单次启动: script/ports 是本实例独有的临时文件(不再是固定共享路径)"
else
  bad "临时文件不在本实例目录: $E2E_TX_PROBE_SCRIPT / $E2E_TX_PROBE_PORTS"
fi
if [[ "$E2E_TX_PROBE_SCRIPT" != "/tmp/e2e-tx-probe.py" ]]; then
  ok "单次启动: 不再使用固定共享文件 /tmp/e2e-tx-probe.py"
else
  bad "仍在用固定共享文件"
fi
_env_ok=1
[[ "${PDG_TX_DNS_PROBE:-}" == "127.0.0.1:"* ]] || _env_ok=0
[[ -n "${PDG_TX_REDIR_PORT:-}" && -n "${PDG_TX_DOT_PORT:-}" ]] || _env_ok=0
[[ "$_env_ok" == 1 ]] && ok "单次启动: 三个探针端点已导出给事务核心" || bad "探针端点没导出"

# ── 2. 重复启动 10 次: 任意时刻最多一个, 不累计 ──
_prev="$E2E_TX_PROBE_PID"; _leak=0; _stale=0
for _i in $(seq 1 10); do
  e2e_tx_probes || bad "第 $_i 次重复启动失败"
  kill -0 "$_prev" 2>/dev/null && _stale=$((_stale+1))       # 上一个还活着 = 累计泄漏
  [[ "$(probe_count)" -gt 1 ]] && _leak=$((_leak+1))
  _prev="$E2E_TX_PROBE_PID"
done
[[ "$_stale" == 0 ]] && ok "重复启动 10 次: 每次启动前都把上一个 PID 收掉了" \
  || bad "有 $_stale 次上一个探针仍在跑(累计泄漏)"
[[ "$_leak" == 0 && "$(probe_count)" == 1 ]] \
  && ok "重复启动 10 次: 任意时刻本实例只有 1 个探针(不是 10 个)" \
  || bad "探针累计了: 当前 $(probe_count) 个, 期间超标 $_leak 次"

# ── 3. 显式 stop: 进程退出 / 临时文件删掉 / 幂等 ──
_pid="$E2E_TX_PROBE_PID"; _sc="$E2E_TX_PROBE_SCRIPT"; _pf="$E2E_TX_PROBE_PORTS"
e2e_tx_probe_stop
if ! kill -0 "$_pid" 2>/dev/null; then ok "显式 stop: 探针进程已退出"; else bad "stop 之后进程还在"; fi
if [[ ! -e "$_sc" && ! -e "$_pf" ]]; then ok "显式 stop: script/ports 临时文件已删除"; else bad "临时文件还在"; fi
if [[ -z "${E2E_TX_PROBE_PID:-}" ]]; then ok "显式 stop: 全局 PID 变量已清空"; else bad "PID 变量没清"; fi
if e2e_tx_probe_stop; then ok "显式 stop: 重复调用幂等(返回 0, 不报错)"; else bad "二次 stop 报错了"; fi
[[ "$(probe_count)" == 0 && "$(tmpfile_count)" == 0 ]] \
  && ok "显式 stop 之后: 本实例探针 0 个、临时文件 0 个" || bad "stop 后仍有残留"

# 子 shell 场景统一用它: 在子 shell 里起探针并把 PID/文件报给父测试
_probe_in_subshell(){   # $1=子 shell 退出方式: exit0 / exit17 / signal:<sig>
  local mode="$1" out
  out="$(
    set +e
    # shellcheck source=tests/e2e-lib.sh
    source "$HERE/e2e-lib.sh" >/dev/null 2>&1
    e2e_tx_probes >/dev/null 2>&1 || { echo "START-FAILED"; exit 9; }
    echo "PID=$E2E_TX_PROBE_PID SC=$E2E_TX_PROBE_SCRIPT"
    case "$mode" in
      exit0)   exit 0;;
      exit17)  exit 17;;
      # 注意用 $BASHPID 而不是 $$: 命令替换的子 shell 里 $$ 仍是**父脚本**的 PID,
      # 拿它当目标就把测试自己打死了(第一版就踩了这个坑)。
      signal:*) kill -"${mode#signal:}" "$BASHPID"; sleep 5;;
    esac
  )"; echo "rc=$?"; echo "$out"
}

# ── 4. 子 shell 正常 exit 0 ──
_o="$(_probe_in_subshell exit0)"; _rc="${_o#rc=}"; _rc="${_rc%%$'\n'*}"
_pid="$(sed -n 's/.*PID=\([0-9]*\).*/\1/p' <<<"$_o")"
[[ "$_rc" == 0 ]] && ok "子 shell 正常退出: 退出码仍是 0" || bad "退出码变成了 $_rc"
if [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
  ok "子 shell 正常退出: EXIT hook 把探针($_pid)清掉了"
else
  bad "正常退出后探针仍在: $_pid"
fi

# ── 5. 子 shell exit 17: 原退出码保持, 探针照样清 ──
_o="$(_probe_in_subshell exit17)"; _rc="${_o#rc=}"; _rc="${_rc%%$'\n'*}"
_pid="$(sed -n 's/.*PID=\([0-9]*\).*/\1/p' <<<"$_o")"
[[ "$_rc" == 17 ]] && ok "子 shell exit 17: 原退出码被保留(清理没吞掉失败)" || bad "退出码变成了 $_rc"
if [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
  ok "子 shell exit 17: 探针($_pid)已被清理"
else
  bad "失败退出后探针仍在: $_pid"
fi

# ── 6. 信号退出: TERM / INT / HUP 各一条 ──
for _sig in TERM INT HUP; do
  _o="$(_probe_in_subshell "signal:$_sig")"
  _pid="$(sed -n 's/.*PID=\([0-9]*\).*/\1/p' <<<"$_o")"
  if [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
    ok "$_sig: 探针被清掉, 没留下 PPID=1 的孤儿"
  else
    bad "$_sig 之后探针仍在: $_pid"
  fi
done
[[ "$(orphan_count)" == 0 ]] && ok "信号路径跑完: 本实例 PPID=1 的孤儿数为 0" \
  || bad "有 $(orphan_count) 个孤儿"

# ── 7. hook 共存: 模拟 restore_resolv 的 sentinel 与探针清理都要执行 ──
_sent="$WORK/sentinel-hook"
rm -f "$_sent"
_o="$(
  set +e
  # shellcheck source=tests/e2e-lib.sh
  source "$HERE/e2e-lib.sh" >/dev/null 2>&1
  my_restore(){ echo hook-ran > "$_sent"; }    # 冒充 e2e-install.sh 的 restore_resolv
  e2e_add_exit_hook my_restore
  e2e_tx_probes >/dev/null 2>&1 || exit 9
  echo "PID=$E2E_TX_PROBE_PID"
  exit 0
)"
_pid="$(sed -n 's/.*PID=\([0-9]*\).*/\1/p' <<<"$_o")"
if [[ -f "$_sent" ]] && [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
  ok "hook 共存: sentinel hook 与探针清理都执行了(后注册的没顶掉前一个)"
else
  bad "hook 共存失败: sentinel=$([[ -f "$_sent" ]] && echo yes || echo no) 探针=$_pid"
fi

# ── 8. 就绪失败: 返回非 0, 进程被停+wait, 临时文件清掉 ──
_before_files="$(tmpfile_count)"
_o="$(
  set +e
  # shellcheck source=tests/e2e-lib.sh
  source "$HERE/e2e-lib.sh" >/dev/null 2>&1
  python3(){ return 1; }                       # 探针根本起不来 → 就绪必然失败
  e2e_tx_probes; rc=$?
  echo "rc=$rc PID=[${E2E_TX_PROBE_PID:-}] SC=[${E2E_TX_PROBE_SCRIPT:-}]"
  exit 0
)"
if grep -q "rc=[^0]" <<<"$_o"; then ok "就绪失败: e2e_tx_probes 返回非 0"; else bad "就绪失败却返回 0: $_o"; fi
if grep -q "PID=\[\] SC=\[\]" <<<"$_o"; then
  ok "就绪失败: PID 与临时文件路径都已清空(不留半个状态)"
else
  bad "就绪失败后仍留着状态: $_o"
fi
[[ "$(tmpfile_count)" == "$_before_files" ]] \
  && ok "就绪失败: 没有新增残留的 script/ports 文件" || bad "留下了临时文件"

# ── 9. 并发两个实例: 各自只停自己的探针 ──
_fifoA="$WORK/a.pid"; _fifoB="$WORK/b.pid"
(
  set +e
  # shellcheck source=tests/e2e-lib.sh
  source "$HERE/e2e-lib.sh" >/dev/null 2>&1
  e2e_tx_probes >/dev/null 2>&1 && echo "$E2E_TX_PROBE_PID" > "$_fifoA"
  sleep 6                                       # 活着等 B 退出
  exit 0
) & _bgA=$!
for _ in $(seq 1 50); do [[ -s "$_fifoA" ]] && break; sleep 0.1; done
_pidA="$(cat "$_fifoA" 2>/dev/null || echo)"
(
  set +e
  # shellcheck source=tests/e2e-lib.sh
  source "$HERE/e2e-lib.sh" >/dev/null 2>&1
  e2e_tx_probes >/dev/null 2>&1 && echo "$E2E_TX_PROBE_PID" > "$_fifoB"
  exit 0
)
_pidB="$(cat "$_fifoB" 2>/dev/null || echo)"
if [[ -n "$_pidA" && -n "$_pidB" && "$_pidA" != "$_pidB" ]]; then
  if kill -0 "$_pidA" 2>/dev/null && ! kill -0 "$_pidB" 2>/dev/null; then
    ok "并发两个实例: B 退出只清掉自己的探针, A 的探针($_pidA)不受影响"
  else
    bad "并发隔离失败: A 活=$(kill -0 "$_pidA" 2>/dev/null && echo y || echo n) B 活=$(kill -0 "$_pidB" 2>/dev/null && echo y || echo n)"
  fi
else
  bad "并发场景没拿到两个不同的探针 PID: A=$_pidA B=$_pidB"
fi
wait "$_bgA" 2>/dev/null
if [[ -n "$_pidA" ]] && ! kill -0 "$_pidA" 2>/dev/null; then
  ok "并发两个实例: A 自己退出时也把探针收干净了"
else
  bad "A 退出后探针仍在: $_pidA"
fi

# ── 10. 收尾: 本实例探针数、孤儿数、临时文件数都必须是 0 ──
sleep 0.5
_pc="$(probe_count)"; _oc="$(orphan_count)"; _tc="$(tmpfile_count)"
[[ "$_pc" == 0 && "$_oc" == 0 ]] \
  && ok "测试结束: 本实例探针 0 个、PPID=1 孤儿 0 个" \
  || bad "结束时仍有 probe=$_pc orphan=$_oc"
[[ "$_tc" == 0 ]] && ok "测试结束: 本实例 script/ports 临时文件 0 个" || bad "残留 $_tc 个临时文件"
# 旧的固定共享路径也不该被谁再创建出来
[[ ! -e /tmp/e2e-tx-probe.py && ! -e /tmp/e2e-tx-probe.ports ]] \
  && ok "旧的固定共享路径没有被重新创建" \
  || skip "机器上仍有旧路径残留(可能来自本次修复之前的历史进程, 与本实现无关)"

# ── 11. 夹具清理: 显式跑一次并验证结果(EXIT hook 只作异常兜底) ──
_life_cleanup
if [[ ! -d "$WORK" ]]; then ok "夹具清理: 本实例 WORK 目录已删除(不再每跑一次留一个空目录)"
else bad "WORK 目录还在: $WORK"; fi
_pc="$(probe_count)"; _tc="$(tmpfile_count)"
if [[ "$_pc" == 0 ]]; then ok "夹具清理后: 本实例探针 0 个"; else bad "清理后仍有 $_pc 个探针"; fi
if [[ "$_tc" == 0 ]]; then ok "夹具清理后: 本实例 script/ports 临时文件 0 个"; else bad "仍有 $_tc 个临时文件"; fi
if _life_cleanup; then ok "夹具清理: 重复调用安全(不报错)"; else bad "重复清理报错了"; fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

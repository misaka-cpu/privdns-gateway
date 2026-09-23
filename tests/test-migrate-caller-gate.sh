#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 退役版「调用方能力门」的定向测试。
#
# 门要挡的是这一版特有的**不可逆**动作: 停并禁用 pdg-mitm、删 WLOC 执行件与 unit、
# 推进 iOS 记录格式。挡法不是"看某个环境变量设没设""某个文件在不在", 而是要求调用方交出
# 一份**属于这一次操作**、结构完整、且钉在**回滚真正会用到的那份快照**上的服务前像。
#
# 这一支验的是判定本身。用的是产品原文的函数(sed 抽取, 不 source 整个 pdg.sh —— 那会跑主入口),
# 锁用的是真 flock + 真 fd 9 继承(跑的是产品的 _lock_inherited)。
# systemctl 是本用例自己的可控桩: 只回答状态、记账被调用过什么, **不管理任何真实服务**。
# 真 systemd 那一格由 tests/e2e-real-migration.sh 负责, 这里不冒充。
#
# 每一格都断言**拒绝理由**, 不只断言"拒了" —— 否则一个共同的假失败会让整张表假绿。
# 需要走到深层判据的场景, 篡改之后按格式重新封口(重算条数与摘要), 免得全被摘要那一关拦掉;
# 另有单独一格验"改了不封口会被摘要抓住"。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }

# 篡改之后按格式重新封口: 重算 unit 条数与正文摘要。
# 有了它, "少一个必需服务""有重复""只有头没有内容"这些**格式合法但内容不完整**的记录
# 才能真的走到各自那条判据上去。
cat > "$BOX/reseal.py" <<'PY'
import hashlib, sys
p = sys.argv[1]
lines = [l for l in open(p, encoding="utf-8").read().split("\n") if not l.startswith("end\t")]
while lines and lines[-1] == "":
    lines.pop()
body = "\n".join(lines) + "\n"
n = sum(1 for l in lines if l.startswith("unit\t"))
open(p, "w", encoding="utf-8").write(body + "end\t%d\t%s\n" % (n, hashlib.sha256(body.encode()).hexdigest()))
PY
reseal(){ python3 "$BOX/reseal.py" "$1"; chmod 600 "$1"; }

# ── 可控 systemctl 桩(只回答状态 + 记账; 不碰任何真实服务)────────────────────
STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}"
  case "$1" in
    is-enabled) [[ -e "$SC_DIR/$u.broken" ]] && { echo; return 1; }
                local v; v="$(cat "$SC_DIR/$u.en" 2>/dev/null)" || { echo not-found; return 1; }
                echo "$v"; case "$v" in enabled|enabled-runtime|static|indirect|generated|alias) return 0;; *) return 1;; esac;;
    is-active)  [[ -e "$SC_DIR/$u.abroken" ]] && { echo; return 1; }
                local a; a="$(cat "$SC_DIR/$u.ac" 2>/dev/null)" || { echo inactive; return 3; }
                echo "$a"; [[ "$a" == active ]] && return 0 || return 3;;
    show) case "$3" in
            LoadState)    [[ -e "$SC_DIR/$u.en" || -e "$SC_DIR/$u.broken" || -e "$SC_DIR/$u.abroken" ]] && echo loaded || echo not-found;;
            SubState)     cat "$SC_DIR/$u.sub" 2>/dev/null || echo dead;;
            InvocationID) cat "$SC_DIR/$u.inv" 2>/dev/null || echo "";;
            *) echo "";;
          esac; return 0;;
    enable)  [[ "$2" == --runtime ]] && echo enabled-runtime > "$SC_DIR/$u.en" || echo enabled > "$SC_DIR/$u.en"; return 0;;
    disable) echo disabled > "$SC_DIR/$u.en"; return 0;;
    start)   echo active > "$SC_DIR/$u.ac"; return 0;;
    stop)    echo inactive > "$SC_DIR/$u.ac"; return 0;;
  esac
  return 0
}'

seed_units(){   # $1=SC_DIR ; 造一台"开着 WLOC 的 iOS 机器"的服务现状
  local d="$1" u
  mkdir -p "$d"
  for u in pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer; do
    echo enabled > "$d/$u.en"; echo active > "$d/$u.ac"; echo running > "$d/$u.sub"; echo "INV-$u" > "$d/$u.inv"
  done
}

mk_child(){     # $1=场景目录 ; 子进程 = 扮演 `pdg __migrate`, 跑**产品原文**的门
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; LOCK=\"$d/lock\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
    _fnN "$PDG" _pdg_lock_proof          # 真家伙(只读 OFD 证明), 不是桩
    _fnN "$PDG" _pdg_svcstate_units
    _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_svcstate_valid
    _fnN "$PDG" _retire_caller_gate
    echo '_retire_caller_gate'
  } > "$d/child.sh"
}

# run_case 场景 [篡改脚本] [句柄: real|none|missing] [锁: yes|no] [快照时刻: now|old]
run_case(){
  local name="$1" tweak="${2:-}" hmode="${3:-real}" lockm="${4:-yes}" snapt="${5:-now}"
  local d="$BOX/$name"; mkdir -p "$d/snap" "$d/sc"
  seed_units "$d/sc"
  mk_child "$d"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
    _fnN "$PDG" _pdg_svcstate_units
    _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_save_svcstate
    echo "exec 9>\"$d/lock\"; flock -n 9 || { echo LOCK_FAILED; exit 1; }"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    [[ "$snapt" == old ]] && echo "touch -d '10 minutes ago' \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null || { echo SAVE_FAILED; exit 1; }"
    # 篡改脚本可用: $F=记录 $SNAP=快照目录 $D=场景目录 reseal=按格式重新封口
    echo "D=\"$d\"; SNAP=\"$d/snap\"; F=\"$d/snap/svcstate.tsv\""
    echo "reseal(){ python3 \"$BOX/reseal.py\" \"\$1\"; chmod 600 \"\$1\"; }"
    echo "$tweak"
    case "$hmode" in
      real)    echo "H=\"$d/snap/svcstate.tsv\"";;
      none)    echo 'H=""';;
      missing) echo "H=\"$d/snap/gone.tsv\"";;
    esac
    if [[ "$lockm" == no ]]; then
      echo "PDG_UPDATE_SVCSTATE=\"\$H\" bash \"$d/child.sh\" 9>&-"
    else
      echo "PDG_UPDATE_SVCSTATE=\"\$H\" bash \"$d/child.sh\""
    fi
    echo 'echo "GATE_RC=$?"'
  } > "$d/parent.sh"
  bash "$d/parent.sh" 2>&1
}

plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
why(){ plain "$1" | grep -o '原因: .*' | head -1; }

# 断言: 放行
expect_pass(){ # $1=名 $2=输出
  if grep -q 'GATE_RC=0' <<<"$2"; then ok "$1: 放行"
  else bad "$1: 合法调用被拒 —— $(why "$2")"; fi
}
# 断言: 拒绝, **且理由必须是指定那一条**
expect_refuse(){ # $1=名 $2=输出 $3=理由关键字
  local w; w="$(why "$2")"
  if grep -q 'GATE_RC=0' <<<"$2"; then bad "$1: 放行了(本该拒绝)"
  elif [[ "$w" == *"$3"* ]]; then ok "$1: 拒绝 —— $w"
  else bad "$1: 拒了, 但理由不是预期的「$3」, 实际是: ${w:-（没给理由）}"; fi
}

echo "══ 一. 合法的本次记录必须放行 ══"
expect_pass A1 "$(run_case A1)"

echo
echo "══ 二. 调用方交不出能力证明 ══"
o="$(run_case B1 "" none)"
expect_refuse B1 "$o" "没有交出本次操作的服务前像句柄"
op="$(plain "$o")"
grep -q '尚未执行任何退役副作用' <<<"$op" && ok "B1: 说明了此刻尚未执行退役副作用" || bad "B1: 没说清现场"
grep -q '新版文件已经装上了' <<<"$op" && ok "B1: **没有**谎称整机未改动(点明新版文件已装)" || bad "B1: 措辞不准"
grep -q '已可完整回滚' <<<"$op" && bad "B1: 未经实测就承诺已可完整回滚" || ok "B1: 没有未经实测地承诺完整回滚"
expect_refuse B2 "$(run_case B2 "" missing)" "记录不存在"
expect_refuse B3 "$(run_case B3 'chmod 644 "$F"')" "属主/权限不对"
expect_refuse B4 "$(run_case B4 "" real no)" "没有持有 pdg 操作锁"

echo
echo "══ 三. 旧记录重放(这一次到底是谁写的)══"
# C1: 上一个父进程写好记录后**退出**, 记录与快照原封不动留在那里, 由另一个进程端过来用
d="$BOX/C1"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"; mk_child "$d"
{ echo 'set -uo pipefail'
  echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
  echo "$STUB"
  _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
  echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
  echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
} > "$d/old-parent.sh"
bash "$d/old-parent.sh"        # 这个"上一次的进程"到此结束
o="$(bash -c "exec 9>\"$d/lock\"; flock -n 9; PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\"; echo GATE_RC=\$?" 2>&1)"
expect_refuse C1 "$o" "不是我、也不是我的调用方写的"
# C2: pid 对上了(复用/伪填), 但那个进程的启动时刻对不上 → 仍然出局
o="$(run_case C2 'sed -i -e "s|^holder_pid\t.*|holder_pid\t$BASHPID|" -e "s|^holder_start\t.*|holder_start\t1|" "$F"; reseal "$F"')"
expect_refuse C2 "$o" "已经结束的旧进程"
# C3: 跨重启残留
o="$(run_case C3 'sed -i "s|^boot_id\t.*|boot_id\t00000000-0000-0000-0000-000000000000|" "$F"; reseal "$F"')"
expect_refuse C3 "$o" "上一次开机"

# C4: `pdg migrate` 在**同一个进程里**直接调 run_all_migrations —— 写记录的就是跑门的这个进程。
# 只认父进程会把这条正常入口误判成"别人的记录"。
d="$BOX/C4"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"
{ echo 'set -uo pipefail'
  echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\"; LOCK=\"$d/lock\""
  echo "$STUB"
  _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
  echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
  _fnN "$PDG" _pdg_lock_proof
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
  _fnN "$PDG" _pdg_save_svcstate; _fnN "$PDG" _pdg_svcstate_valid
  _fnN "$PDG" _retire_caller_gate
  echo "exec 9>\"$d/lock\"; flock -n 9"
  echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
  echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  # 同一个进程里直接跑门(不 fork), 正是 cmd_migrate → run_all_migrations 的形态
  echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" _retire_caller_gate"
  echo 'echo "GATE_RC=$?"'
} > "$d/run.sh"
expect_pass C4 "$(bash "$d/run.sh" 2>&1)"

echo
echo "══ 四. 记录与「回滚真正会用到的那份快照」绑没绑上 ══"
# D1: 记录写完之后快照被换掉了(inode/大小/时刻都变) → 记录钉的不是这一份
o="$(run_case D1 'printf "OTHER-BYTES-ENTIRELY" > "$SNAP/new"; mv "$SNAP/new" "$SNAP/snap.tar.gz"')"
expect_refuse D1 "$o" "记录钉的不是现在这份快照"
# D2: 记录是本次写的, 但指向的是别处的目录
o="$(run_case D2 'sed -i "s|^snap_dir\t.*|snap_dir\t/var/lib/pdg/snapshots/2024-01-01|" "$F"; reseal "$F"')"
expect_refuse D2 "$o" "不自洽"
# D3: 记录是本次写的, 快照却是十分钟前那一份 → 旧快照被端过来了
o="$(run_case D3 "" real yes old)"
expect_refuse D3 "$o" "比写它的那个进程还早"
# D4: 快照文件被删
o="$(run_case D4 'rm -f "$SNAP/snap.tar.gz"')"
expect_refuse D4 "$o" "没有本次快照"

echo
echo "══ 五. 记录不完整 / 被改坏 ══"
expect_refuse E1 "$(run_case E1 'head -n -1 "$F" > "$D/t"; mv "$D/t" "$F"; chmod 600 "$F"')" "没有结尾行"
expect_refuse E2 "$(run_case E2 'awk -F"\t" "\$1!=\"unit\"" "$F" > "$D/t"; mv "$D/t" "$F"; reseal "$F"')" "一条服务记录都没有"
expect_refuse E3 "$(run_case E3 'awk -F"\t" "!(\$1==\"unit\" && \$2==\"pdg-mitm\")" "$F" > "$D/t"; mv "$D/t" "$F"; reseal "$F"')" "缺少必需服务"
expect_refuse E4 "$(run_case E4 'awk "/^unit\tmosdns\t/{print} {print}" "$F" > "$D/t"; mv "$D/t" "$F"; reseal "$F"')" "有重复的 unit 记录"
expect_refuse E5 "$(run_case E5 'awk -F"\t" "\$1!=\"snap_id\"" "$F" > "$D/t"; mv "$D/t" "$F"; reseal "$F"')" "缺头部字段 snap_id"
expect_refuse E6 "$(run_case E6 'sed -i "s|^created_at\t.*|created_at\t1999-01-01T00:00:00Z|" "$F"')" "摘要对不上"
expect_refuse E7 "$(run_case E7 'sed -i "1s|.*|#pdg-svcstate\t99|" "$F"')" "不是认识的前像格式"

echo
echo "══ 六. 观测失败不能当成一种状态 ══"
# 让 systemctl 对 mihomo 的 is-enabled 查询失败(空输出), 但 LoadState 说 loaded
# ⇒ 产品的 _pdg_svc_q 应当记成 QUERY-FAILED, 门应当据此拒绝 —— 而不是记成空串蒙混过去。
d="$BOX/F2"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"; : > "$d/sc/mihomo.broken"
mk_child "$d"
{ echo 'set -uo pipefail'
  echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
  echo "$STUB"
  _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
  echo "exec 9>\"$d/lock\"; flock -n 9"
  echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
  echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\""
  echo 'echo "GATE_RC=$?"'
} > "$d/parent.sh"
o="$(bash "$d/parent.sh" 2>&1)"
grep -q $'^unit\tmihomo\tQUERY-FAILED' "$d/snap/svcstate.tsv" \
  && ok "F2: 查询失败被记成 QUERY-FAILED(不是空串)" || bad "F2: 观测失败被写成了别的东西"
expect_refuse F2 "$o" "观测失败"

echo
echo "══ 七. 前像与现状不一致**不是**拒绝理由 ══"
# 这一格以前是反的(现状与前像不符就拒)。真实链路里门执行时, 同一次操作里排在前面的迁移
# 早就合法地改过服务状态了 —— 那样判会把每一次合法的完整调用都误拒。
# 归属由 pid+starttime / snap_id / boot_id 判定; 具体断言见下面第十二节。
echo
echo "══ 八. 前置判据: 没有不可逆的事要做时, 不要求能力证明 ══"
s1(){   # $1=场景 $2=need 五元组 $3=iOS 记录里的 schema(空=没有记录)
  local d="$BOX/$1"; mkdir -p "$d/etc/privdns-gateway" "$d/opt/pdg-bot"
  [[ -n "$3" ]] && printf '{"schema": %s}\n' "$3" > "$d/etc/privdns-gateway/ios-profile.json"
  { echo 'set -uo pipefail'
    _fnN "$PDG" _retire_has_irreversible_work
    echo "PDG_RETIRE_ROOT=\"$d\" _retire_has_irreversible_work $2"
    echo 'echo "IRR=$?"'
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1
}
grep -q 'IRR=0' <<<"$(s1 H1 '1 0 0 0 0' '')"  && ok "H1: 有服务待停 ⇒ 判为有不可逆的事(要门)" || bad "H1"
grep -q 'IRR=0' <<<"$(s1 H2 '0 0 0 1 0' '')"  && ok "H2: 有 JSON 待改 ⇒ 要门" || bad "H2"
grep -q 'IRR=1' <<<"$(s1 H3 '0 0 0 0 0' '')"  && ok "H3: 全干净且没有 iOS 记录 ⇒ 不要求能力证明(新装机/已退役机器照常)" || bad "H3"
grep -q 'IRR=1' <<<"$(s1 H4 '0 0 0 0 0' '2')" && ok "H4: 记录已是新 schema ⇒ 幂等复跑照常" || bad "H4"

echo
echo "══ 九. 撤销对照 ══"
echo "  (撤掉门之后真实迁移代码会不会动手, 由 tests/test-retire-sideeffect-barrier.sh 第五节"
echo "   验 —— 那里跑的是**产品原文**的 migrate_android_cleanup / _plat_purge_retired。"
echo "   本支只验判定本身, 不在这里重复一个较弱的版本。)"

echo
echo "══ 十. 运行态查询失败必须**单独**被抓住 ══"
# 自启查得好好的, 只有 is-active 查不出来。门原来用 `read … ufs rest` 之后判
# `case "$rest" in QUERY-FAILED*)`, 而 rest 的第一段是**自启查询的 rc**, 不是运行值 ——
# 于是这一格永远检测不到。判据必须逐字段解析。
parent_run(){   # $1=场景目录; 用真实 flock + 真实 fd 9 继承跑一次门
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
    echo "exec 9>\"$d/lock\"; flock -n 9 || { echo LOCK_FAILED; exit 1; }"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null || { echo SAVE_FAILED; exit 1; }"
    echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\""
    echo 'rc=$?'
    echo "printf 'LOCKS_AFTER=%s\n' \"\$(grep -c \":\$(stat -c %i \"$d/lock\") \" /proc/locks 2>/dev/null || echo 0)\""
    echo 'echo "GATE_RC=$rc"'
  } > "$d/parent.sh"
  bash "$d/parent.sh" 2>&1
}
d="$BOX/J1"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"; : > "$d/sc/mosdns.abroken"
mk_child "$d"; o="$(parent_run "$d")"
awk -F'\t' '$1=="unit" && $2=="mosdns"{ok=($3!="QUERY-FAILED" && $5=="QUERY-FAILED")} END{exit !ok}' "$d/snap/svcstate.tsv" \
  && ok "J1a: 自启记成正常值、运行态记成 QUERY-FAILED(两件事分开记)" \
  || bad "J1a: 记录形态不对: $(grep -P '^unit\tmosdns\t' "$d/snap/svcstate.tsv" | tr '\t' '|')"
expect_refuse J1 "$o" "运行态是观测失败"

echo
echo "══ 十一. 正常 disabled / inactive / not-found 不是查询异常 ══"
d="$BOX/J2"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"
echo disabled > "$d/sc/pdg-mitm.en"; echo inactive > "$d/sc/pdg-mitm.ac"
rm -f "$d/sc/mihomo.en" "$d/sc/mihomo.ac"
mk_child "$d"; o="$(parent_run "$d")"
grep -qP '^unit\tpdg-mitm\tdisabled\t1\tinactive\t3\t' "$d/snap/svcstate.tsv" \
  && ok "J2a: disabled(rc=1)/inactive(rc=3) 原样记下 —— 非零返回码不等于查询异常" \
  || bad "J2a: $(grep -P '^unit\tpdg-mitm\t' "$d/snap/svcstate.tsv" | tr '\t' '|')"
grep -qP '^unit\tmihomo\tnot-found\t' "$d/snap/svcstate.tsv" \
  && ok "J2b: unit 不存在记成 not-found, 不是 QUERY-FAILED" \
  || bad "J2b: $(grep -P '^unit\tmihomo\t' "$d/snap/svcstate.tsv" | tr '\t' '|')"
expect_pass J2 "$o"

echo
echo "══ 十二. 合法调用不因「较早的迁移改过服务状态」被误拒 ══"
# 真实链路里, 门执行时排在前面的迁移早就动过服务了(dotwitness/health_timer/deploy_units/
# drop_singbox…), 平台切换更是先切完平台。拿现状比前像, 每一次合法调用都会被误拒。
o="$(run_case J3 'echo disabled > "$D/sc/pdg-mitm.en"; echo inactive > "$D/sc/pdg-mitm.ac"
echo enabled-runtime > "$D/sc/pdg-dotwitness.en"; echo failed > "$D/sc/mosdns.ac"')"
expect_pass J3 "$o"

echo
echo "══ 十三. 持锁证明必须是只读的 ══"
lockcnt(){ grep -c ":$(stat -c %i "$1") " /proc/locks 2>/dev/null || true; }
# (a) fd 9 打开了但**没人持锁** → 拒绝; 且判定不许顺手锁上一把
d="$BOX/J4"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"; : > "$d/lock"
mk_child "$d"
{ echo 'set -uo pipefail'
  echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
  echo "$STUB"
  _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
  echo "exec 9>\"$d/lock\""        # 只 open, **不** flock
  echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
  echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\""
  echo 'rc=$?'
  echo "printf 'LOCKS_AFTER=%s\n' \"\$(grep -c \":\$(stat -c %i \"$d/lock\") \" /proc/locks 2>/dev/null || echo 0)\""
  echo 'echo "GATE_RC=$rc"'
} > "$d/parent.sh"
before="$(lockcnt "$d/lock")"; o="$(bash "$d/parent.sh" 2>&1)"
expect_refuse J4 "$o" "没有持有 pdg 操作锁"
after="$(grep -o 'LOCKS_AFTER=[0-9]*' <<<"$o" | cut -d= -f2)"
[[ "${before:-0}" == 0 && "${after:-9}" == 0 ]] \
  && ok "J4b: 判定前后这把锁上都没有持有者 —— 判定**没有**顺手取到一把新锁" \
  || bad "J4b: 判定前 ${before:-?} 把, 判定后 ${after:-?} 把 —— 证明变成了制造"
# (b) 父进程真持锁 → 子进程继承 → 放行, 且判定后那把锁还在(没被解掉)
d="$BOX/J5"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"
mk_child "$d"; o="$(parent_run "$d")"
expect_pass J5 "$o"
[[ "$(grep -o 'LOCKS_AFTER=[0-9]*' <<<"$o" | cut -d= -f2)" == 1 ]] \
  && ok "J5b: 判定之后父进程那把锁**还在**(没有被解掉)" \
  || bad "J5b: 判定后锁数 $(grep -o 'LOCKS_AFTER=[0-9]*' <<<"$o" | cut -d= -f2), 期望 1"

echo
echo "══ 十四. 撤销对照: 把本轮三处修复分别撤回, 对应判据必须转红 ══"
# 撤的是**修复本身**(最小反向补丁), 不是把整支测试指到旧提交 —— 那样只会同源码跑两遍。
mk_child_src(){   # 与 mk_child 同构, 但用指定的 pdg.sh
  local d="$1" src="$2"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; LOCK=\"$d/lock\""
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
    echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
    _fnN "$src" _pdg_lock_proof
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_svcstate_valid
    _fnN "$src" _retire_caller_gate
    echo '_retire_caller_gate'
  } > "$d/child.sh"
}
run_with(){   # $1=场景目录 $2=src $3=场景布置脚本(可空) ; 真 flock + 真 fd 9 继承
  local d="$1" src="$2" setup="${3:-}"
  mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"
  eval "$setup"
  mk_child_src "$d" "$src"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_save_svcstate
    echo "${LOCKLINE:-exec 9>\"$d/lock\"; flock -n 9}"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
    echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\""
    echo 'rc=$?'
    echo "printf 'LOCKS_AFTER=%s\n' \"\$(grep -c \":\$(stat -c %i \"$d/lock\") \" /proc/locks 2>/dev/null || echo 0)\""
    echo 'echo "GATE_RC=$rc"'
  } > "$d/parent.sh"
  bash "$d/parent.sh" 2>&1
}

# ① 逐字段解析 → 撤回成"看错字段"(原来 rest 的第一段是自启 rc, 不是运行值)
REV1="$BOX/rev-fields.sh"
sed 's/if \[\[ "\$asv" == QUERY-FAILED \]\]; then/if [[ "$urc" == QUERY-FAILED ]]; then/' "$PDG" > "$REV1"
if cmp -s "$PDG" "$REV1" || ! bash -n "$REV1" 2>/dev/null; then
  bad "K1: 没造出「看错字段」的反向副本 —— 本格记无效"
else
  o="$(run_with "$BOX/K1" "$REV1" ': > "$d/sc/mosdns.abroken"')"
  grep -q 'GATE_RC=0' <<<"$o" \
    && ok "K1: 撤回逐字段解析后, 「运行态查询失败」这一格**放行**了 —— J1 确实由这处修复保住" \
    || bad "K1: 反向对照没体现差异(仍然拒绝: $(why "$o"))"
fi

# ② 只读持锁证明 → 撤回成原来那套"能不能 flock 上"
REV2="$BOX/rev-lock.sh"
awk '/^_pdg_lock_proof\(\)\{/{print "_pdg_lock_proof(){ [[ -e \"/proc/$$/fd/9\" ]] || return 1; flock -n 9 2>/dev/null || return 1; return 0; }"; skip=1; next}
     skip && /^\}/{skip=0; next}
     !skip{print}' "$PDG" > "$REV2"
if cmp -s "$PDG" "$REV2" || ! bash -n "$REV2" 2>/dev/null; then
  bad "K2: 没造出「靠 flock 探锁」的反向副本 —— 本格记无效"
else
  LOCKLINE="exec 9>\"$BOX/K2/lock\"" o="$(run_with "$BOX/K2" "$REV2")"
  after="$(grep -o 'LOCKS_AFTER=[0-9]*' <<<"$o" | cut -d= -f2)"
  if grep -q 'GATE_RC=0' <<<"$o" && [[ "${after:-0}" -ge 1 ]]; then
    ok "K2: 撤回只读证明后, 「fd 9 打开但没人持锁」被放行, 而且判定**自己锁上了一把**(锁数 $after) —— J4/J4b 确实由这处修复保住"
  else
    bad "K2: 反向对照没体现差异(rc=$(grep -o 'GATE_RC=.*' <<<"$o"), 判定后锁数 ${after:-?})"
  fi
fi

# ③ 去掉"前像与现状一致"这条判据 → 撤回成把它加回去
REV3="$BOX/rev-statematch.sh"
awk '/^  # 必要条件\(\*\*不是\*\*归属证明\)/{
       print "  if [[ -z \"$why\" ]]; then"
       print "    while IFS=$'"'"'\\t'"'"' read -r _k u ufs _urc _asv _arc _sub _inv; do"
       print "      [[ \"$_k\" == unit && -n \"$u\" ]] || continue"
       print "      now=\"$(_pdg_svc_q is-enabled \"$u\" | cut -f1)\""
       print "      [[ \"$now\" == \"$ufs\" ]] || { why=\"前像与现状对不上($u)\"; break; }"
       print "    done < \"$f\""
       print "  fi"
     } {print}' "$PDG" > "$REV3"
if cmp -s "$PDG" "$REV3" || ! bash -n "$REV3" 2>/dev/null; then
  bad "K3: 没造出「拿现状比前像」的反向副本 —— 本格记无效"
else
  o="$(run_with "$BOX/K3" "$REV3" 'true')"
  # 布置一次"较早迁移改过服务状态"的合法现场: 存完前像之后再改
  d="$BOX/K3b"; mkdir -p "$d/snap" "$d/sc"; seed_units "$d/sc"
  mk_child_src "$d" "$REV3"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$REV3" c_g; _fn1 "$REV3" c_y
    _fnN "$REV3" _pdg_svcstate_units; _fnN "$REV3" _pdg_svc_known; _fnN "$REV3" _pdg_svc_q
    _fnN "$REV3" _pdg_save_svcstate
    echo "exec 9>\"$d/lock\"; flock -n 9"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
    echo "echo disabled > \"$d/sc/pdg-mitm.en\""      # 模拟"排在前面的迁移动过服务"
    echo "PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\" bash \"$d/child.sh\""
    echo 'echo "GATE_RC=$?"'
  } > "$d/parent.sh"
  o="$(bash "$d/parent.sh" 2>&1)"
  grep -q 'GATE_RC=0' <<<"$o" \
    && bad "K3: 反向对照没体现差异(加回那条判据后仍然放行)" \
    || ok "K3: 加回「拿现状比前像」之后, 一次**合法完整调用**被误拒 —— J3 确实由去掉这条保住"
fi


echo
echo "══ 十五. 只读扫描器: 这台机器上到底有没有退役工作 ══"
# 判据来源必须是**既有定义** —— 扫描器把五个 need_* 现场扫一遍, 裁决交给
# _retire_has_irreversible_work(它自己还管 iOS 记录格式那一维)。这里逐面摆场景验它。
# $3 形如 "词/码": 状态词与退出码**分开给**, 这样才摆得出"答了词却以别的码收场"。
# gone = systemctl 整个问不出来。$4 = 平台(默认 ios, 走不到 Android 清理那一支)。
wp(){   # $1=场景名 $2=摆场景片段(在场景根下执行) $3=is-active 的「词/码」
        # $4=平台(ios|android|none=不打标, 默认 ios) $5=可选: 在调用前注入的代码(造读失败用)
  local d="$BOX/wp-$1" ans="${3:-inactive/3}" plat="${4:-ios}" pre="${5:-}"
  mkdir -p "$d/etc/privdns-gateway" "$d/opt/pdg-bot" "$d/etc/systemd/system" \
           "$d/etc/mosdns/rules" "$d/etc/mihomo"
  printf 'SCHEMA = 2\n' > "$d/opt/pdg-bot/iosstate.py"
  [[ "$plat" == none ]] || printf '%s\n' "$plat" > "$d/etc/privdns-gateway/platform"
  ( cd "$d" && eval "${2:-:}" )
  { echo 'set -uo pipefail'
    echo '_RETIRE_WHY=""'
    # 平台判定的四条输入一律指向场景根(否则助手会去读宿主 /etc)。扫描器现在经
    # _pdg_platform_plan 判平台, **不再**读 _pdg_platform —— 所以这里故意不给它桩:
    # 谁退回旧形态, 这一节就会 127 判红, 而不是悄悄读到一个默认 android。
    echo "export PDG_PLATFORM_FILE=\"$d/etc/privdns-gateway/platform\" PROFILE_ENV=\"$d/etc/privdns-gateway/profile.env\""
    echo "export PDG_MITM_JSON=\"$d/etc/privdns-gateway/mitm.json\" PDG_MITM_UNIT=\"$d/etc/systemd/system/pdg-mitm.service\""
    if [[ "$ans" == gone ]]; then echo 'systemctl(){ return 127; }'
    else echo "systemctl(){ [ \"\$1\" = is-active ] && { echo ${ans%%/*}; return ${ans##*/}; }; return 0; }"; fi
    _fnN "$PDG" _retire_core_has_mitm
    _fnN "$PDG" _retire_android_pending
    _fnN "$PDG" _retire_has_irreversible_work
    _fnN "$PDG" _pdg_platform_plan
    _fnN "$PDG" _retire_work_pending
    [[ -n "$pre" ]] && echo "$pre"
    echo "PDG_RETIRE_ROOT=\"$d\" _retire_work_pending"
    echo 'echo "WORK=$?  WHY=$_RETIRE_WHY"'
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1 | tail -1
}
_w(){ grep -q "WORK=$2" <<<"$3" && ok "$1 —— $(sed 's/.*WHY=//' <<<"$3")" || bad "$1: 实得 $3"; }
_w "W1: 盘上还有 pdg-mitm.service ⇒ 有活"            0 "$(wp W1 'touch etc/systemd/system/pdg-mitm.service')"
_w "W2: 劫持表非空 ⇒ 有活"                           0 "$(wp W2 'echo full:gs-loc.apple.com > etc/mosdns/rules/mitm_hijack.txt')"
_w "W3: mitm.json 还开着 ⇒ 有活"                     0 "$(wp W3 'printf "{\"enabled\": true}" > etc/privdns-gateway/mitm.json')"
_w "W4: 内核配置里还留着 MITM 出站 ⇒ 有活"           0 "$(wp W4 'printf "proxies:\n  - MITM-OUT\n" > etc/mihomo/config.yaml')"
_w "W5: 执行件还在 /opt ⇒ 有活"                      0 "$(wp W5 'touch opt/pdg-bot/mitm_wloc.py')"
_w "W6: pdg-mitm 还在跑 ⇒ 有活"                      0 "$(wp W6 '' active/0)"
_w "W7: iOS 记录还停在旧 schema ⇒ 有活(记录格式那一维)" 0 "$(wp W7 'printf "{\"schema\": 1}" > etc/privdns-gateway/ios-profile.json')"
_w "W8: 全干净、没有 iOS 记录 ⇒ **没有**活(新装机不被误拒)" 1 "$(wp W8 '')"
_w "W9: 已退役幂等(记录已是新 schema)⇒ **没有**活"   1 "$(wp W9 'printf "{\"schema\": 2}" > etc/privdns-gateway/ios-profile.json')"
_w "W10: 运行态整个问不出来 ⇒ **无法确认**(不冒充没有退役工作)" 2 "$(wp W10 '' gone)"

# ── 观测失败三条: 答了一半再失败, 一律落「无法确认」, 不许混进「确认没有」 ──
_wwhy(){ # $1=名 $2=期望码 $3=输出 $4=理由关键字
  if grep -q "WORK=$2" <<<"$3" && grep -q "$4" <<<"$3"; then ok "$1 —— $(sed 's/.*WHY=//' <<<"$3")"
  else bad "$1: 实得 $3"; fi
}
_wwhy "N1: is-active 答了 inactive 却以 7 收场 ⇒ 无法确认(保留原始退出码 7)" 2       "$(wp N1 '' inactive/7)" '退出码 7'
_wwhy "N2: iOS 记录解析失败 ⇒ 无法确认(保留 python 退出码)" 2       "$(wp N2 'printf "{ not json" > etc/privdns-gateway/ios-profile.json')" 'iOS 记录读不出来'
_wwhy "N3: MITM-OUT 配置查询出错(rc=2) ⇒ 无法确认" 2       "$(wp N3 'mkdir -p etc/mihomo/config.yaml')" '核心配置查不出来'
_w "N0: 同一套现场但三项观测都正常 ⇒ **确认**没有活(三条反例不是靠恒红取胜)" 1 "$(wp N0 '')"

# ── 与后续保护点的适用范围对齐 ──────────────────────────────────────────────
o="$(wp W11 'touch opt/pdg-bot/iosprofile.py' inactive/3 android)"
_wwhy "W11: Android 现场只剩 iosprofile.py ⇒ 有活(与 migrate_android_cleanup 用的同一个判据)" 0       "$o" '_retire_android_pending'
_w "W12: 同样只剩 iosprofile.py, 但平台是 iOS ⇒ 不走 Android 那一支(不无条件合并各平台文件集)" 1    "$(wp W12 'touch opt/pdg-bot/iosprofile.py' inactive/3 ios)"
# 只读必须包含**传递调用**: W7 那一格真的跑过 `import iosstate`(schema 那一维), 所以拿它
# 的场景目录看有没有留下 __pycache__/.pyc —— 查的是**目录前后的实际差异**, 不是源码里
# 有没有写 -B。
find "$BOX/wp-W7" \( -name '__pycache__' -o -name '*.pyc' \) 2>/dev/null > "$BOX/pyc.txt"
[[ ! -s "$BOX/pyc.txt" ]] \
  && ok "W13: 只读判定跑完(含 import iosstate 那一步), 场景目录里**没有** __pycache__/.pyc" \
  || { bad "W13: 只读判定留下了现场产物"; sed 's/^/      /' "$BOX/pyc.txt"; }

# ── 平台判定按标记迁移**将会**定出的状态(扫描器层) ─────────────────────────
# 前置排在标记迁移之前: 此刻盘上的 platform / platform.guessed 可能还没写出来。扫描器要问的是
# _pdg_platform_plan(标记迁移与前置共用的那一份判定), 不是此刻的盘面。
IOSKIT='touch opt/pdg-bot/iosprofile.py opt/pdg-bot/mitm_ca.py opt/pdg-bot/pdg-dot.mobileconfig.tmpl'
_w    "W14: 无标记、无明确平台证据, 只有 v1.4.x 普装的 iOS 组件 ⇒ **确认没有**(将被推测为 android, 清理那一支不适用)" \
      1 "$(wp W14 "$IOSKIT" inactive/3 none)"
[[ -z "$(find "$BOX/wp-W14/etc/privdns-gateway" -mindepth 1 2>/dev/null)" ]] \
  && ok "W14b: 扫描器判完之后, 场景里**没有**生成 platform / platform.guessed / 临时标记文件" \
  || { bad "W14b: 扫描器在现场留下了平台标记"; find "$BOX/wp-W14/etc/privdns-gateway" -mindepth 1 | sed 's/^/      /'; }
_wwhy "W15: 无标记但 profile.env 明确 android + 同样的 iOS 组件 ⇒ 有活(Android 那一支适用)" \
      0 "$(wp W15 "$IOSKIT; printf 'PDG_PLATFORM=android\n' > etc/privdns-gateway/profile.env" inactive/3 none)" '平台据 profile 确认为 android'
_wwhy "W15b: 已有确认 android(无 .guessed)+ iOS 组件 ⇒ 有活" \
      0 "$(wp W15b "$IOSKIT" inactive/3 android)" '平台据 existing 确认为 android'
_w    "W16: 已有**推测** android(带 .guessed)+ iOS 组件 ⇒ 确认没有(推测态语义不变)" \
      1 "$(wp W16 "$IOSKIT; : > etc/privdns-gateway/platform.guessed" inactive/3 android)"
o="$(wp W17 "$IOSKIT; touch etc/systemd/system/pdg-mitm.service" inactive/3 none)"
if grep -q 'WORK=0' <<<"$o" && ! grep -q 'Android 清理那一支' <<<"$o"; then
  ok "W17: 无标记但有 pdg-mitm unit(明确 iOS 证据)⇒ 不走 Android 那一支, 但 WLOC 待办照样判有活 —— $(sed 's/.*WHY=//' <<<"$o")"
else bad "W17: 实得 $o"; fi
# 读失败 / 读到一半再失败: 无法确认, 不消费半截结论
_wwhy "R1: 无标记, profile.env 不是普通文件 ⇒ 无法确认" 2 \
      "$(wp R1 "$IOSKIT; mkdir -p etc/privdns-gateway/profile.env" inactive/3 none)" '平台判定所需的证据读不出来'
_wwhy "R2: 无标记, mitm.json 查不出来(grep rc=2)⇒ 无法确认" 2 \
      "$(wp R2 "$IOSKIT; mkdir -p etc/privdns-gateway/mitm.json" inactive/3 none)" 'mitm.json 查不出来'
_wwhy "R3: 平台标记本身读不出来 ⇒ 无法确认" 2 \
      "$(wp R3 "$IOSKIT; rm -f etc/privdns-gateway/platform; mkdir -p etc/privdns-gateway/platform" inactive/3 none)" '平台标记读不出来'
# 半截输出: profile.env 里写的是 ios; 注入的读取先吐出 "android" 再以非 0 收场。
# 若采信半截输出, 会判成"确认 android"并因 iOS 组件判有活(0); 正确结论是无法确认(2)。
HALF='sed(){ if [[ "$*" == *PDG_PLATFORM=* ]]; then echo android; return 1; fi; command sed "$@"; }'
_wwhy "R4: profile.env 读到一半(先输出 android)再失败 ⇒ 无法确认, 不采信那半截" 2 \
      "$(wp R4 "$IOSKIT; printf 'PDG_PLATFORM=ios\n' > etc/privdns-gateway/profile.env" inactive/3 none "$HALF")" 'profile.env 读不出来'
_w    "R4h: 同一现场不注入(完整读到 ios)⇒ 确认没有(R4 不是靠恒红取胜)" \
      1 "$(wp R4h "$IOSKIT; printf 'PDG_PLATFORM=ios\n' > etc/privdns-gateway/profile.env" inactive/3 none)"

echo
echo "══ 十六. 有条件前置: 拒在迁移链动第一样东西之前 ══"
# 这一节跑**产品原文的 run_all_migrations**。除 migrate_rescue_plane 之外的 migrate_* 一律
# 打桩返回 0; migrate_rescue_plane 的桩做一件事 —— 把 socket unit 落到场景根上, 用它当
# "迁移链已经产生持久化副作用"的实物证据。门与扫描器都是产品原文。
chain(){   # $1=场景名 $2=句柄 real|none $3=前置 keep|drop|ia0keep
           #   ia0keep = 保留前置, 但把产品里那个 inactive/0 例外**加回去**(单处撤销对照)
  local name="$1" hmode="$2" keep="$3"
  local d="$BOX/ch-$name"
  mkdir -p "$d/etc/privdns-gateway" "$d/opt/pdg-bot" "$d/etc/systemd/system" \
           "$d/etc/mosdns/rules" "$d/etc/mihomo" "$d/snap" "$d/sc"
  printf 'SCHEMA = 2\n' > "$d/opt/pdg-bot/iosstate.py"
  seed_units "$d/sc"
  if [[ "$name" == *nowork* ]]; then
    # 真正"没有退役工作"的机器: 盘上没有退役件, pdg-mitm 也**明确**不在跑。
    # seed_units 造的是"开着 WLOC 的 iOS 机器"(pdg-mitm=active), 那一格本来就有活要干。
    echo inactive > "$d/sc/pdg-mitm.ac"; echo dead > "$d/sc/pdg-mitm.sub"; rm -f "$d/sc/pdg-mitm.inv"
  elif [[ "$name" == *ia0* ]]; then
    # 盘上没有任何退役材料; 唯一的异常就是 is-active 答了 inactive 却以 0 收场。
    echo inactive > "$d/sc/pdg-mitm.ac"; echo dead > "$d/sc/pdg-mitm.sub"; rm -f "$d/sc/pdg-mitm.inv"
  elif [[ "$name" == *unsure* ]]; then
    # 没有任何退役材料, 但内核配置查不出来(是目录, 不是普通文件)⇒ 观测存疑
    echo inactive > "$d/sc/pdg-mitm.ac"; echo dead > "$d/sc/pdg-mitm.sub"; rm -f "$d/sc/pdg-mitm.inv"
    mkdir -p "$d/etc/mihomo/config.yaml"
  else
    touch "$d/etc/systemd/system/pdg-mitm.service"   # 退役材料
  fi
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\"; LOCK=\"$d/lock\""
    echo "CALLS=\"$d/calls.log\"; : > \"\$CALLS\""
    echo "$STUB"
    # 只给 pdg-mitm 换一张嘴: 状态词 inactive, 退出码 0(真 systemd 不会这么答)。
    # 其余 unit 仍走上面那份共享桩, 免得连带影响 _pdg_save_svcstate 的采样。
    if [[ "$name" == *ia0* ]]; then
      echo 'eval "_sc_orig() $(declare -f systemctl | tail -n +2)"'
      echo 'systemctl(){ if [ "$1" = is-active ] && [ "${*: -1}" = pdg-mitm ]; then echo inactive; return 0; fi; _sc_orig "$@"; }'
    fi
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    echo "_pdg_module(){ printf '%s\n' \"$ROOT/deploy/bot/\$1\"; }"
    _fnN "$PDG" _pdg_lock_proof
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_svcstate_valid; _fnN "$PDG" _pdg_save_svcstate
    echo '_PDG_RETIRE_OK=""; _PDG_RETIRE_DONE=0; _RETIRE_WHY=""'
    _fnN "$PDG" _retire_caller_gate; _fnN "$PDG" _retire_allowed
    _fnN "$PDG" _retire_rerun_hint
    _fnN "$PDG" _retire_core_has_mitm; _fnN "$PDG" _retire_has_irreversible_work
    # 扫描器的 Android 那一支经 _pdg_platform_plan 判平台, 连同它要问的 _retire_android_pending
    # 一并抽真身; 平台四条输入指向场景根。(先前这里两者都没抽: 旧判定里 $(_pdg_platform) 127
    # 成空串, 那一支在本节**从未被执行过**。)
    _fnN "$PDG" _retire_android_pending; _fnN "$PDG" _pdg_platform_plan
    echo "export PDG_PLATFORM_FILE=\"$d/etc/privdns-gateway/platform\" PROFILE_ENV=\"$d/etc/privdns-gateway/profile.env\""
    echo "export PDG_MITM_JSON=\"$d/etc/privdns-gateway/mitm.json\" PDG_MITM_UNIT=\"$d/etc/systemd/system/pdg-mitm.service\""
    if [[ "$keep" == ia0keep ]]; then
      # 单处撤销: 只把 `inactive/3|failed/3` 改回 `inactive/3|failed/3|inactive/0`,
      # 其余一个字不动 —— 用来证明同一输入会重新被放行。
      _fnN "$PDG" _retire_work_pending | sed 's#inactive/3|failed/3)#inactive/3|failed/3|inactive/0)#'
    else
      _fnN "$PDG" _retire_work_pending
    fi
    _fnN "$PDG" _retire_precheck
    echo 'for f in $(grep -oE "migrate_[a-z0-9_]+" "'"$PDG"'" | sort -u); do'
    echo '  eval "$f(){ echo \"$f\" >> \"$CALLS\"; return 0; }"'
    echo 'done'
    echo "migrate_rescue_plane(){ echo migrate_rescue_plane >> \"\$CALLS\"; : > \"$d/etc/systemd/system/pdg-rescue.socket\"; return 0; }"
    # 退役那一支不全打桩: 保留它**真实的第一道拦截**(`_retire_allowed || return 1`),
    # 否则撤销对照量不到"把门搬早之后后面的保护还在不在"。
    # 形状照抄真函数: **有活才问能力**(真函数的只读段算出 need_* 全 0 时根本不问门),
    # 否则干净机器上这一支会凭空返回 1, 把"没有退役工作也不误拒"那一格量成红的。
    echo "migrate_wloc_retire(){ echo migrate_wloc_retire >> \"\$CALLS\"; _retire_work_pending || return 0; _retire_allowed || return 1; return 0; }"
    if [[ "$keep" == keep ]]; then sed -n "/^run_all_migrations(){/,/^}/p" "$PDG"
    else sed -n "/^run_all_migrations(){/,/^}/p" "$PDG" | grep -v '_retire_precheck || return 1'; fi
    echo "exec 9>\"$d/lock\"; flock -n 9 || { echo LOCK_FAILED; exit 1; }"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null || { echo SAVE_FAILED; exit 1; }"
    [[ "$hmode" == real ]] && echo "export PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\""
    echo "PDG_RETIRE_ROOT=\"$d\" run_all_migrations; echo \"CHAIN_RC=\$?\""
    echo "echo \"RESCUE_CALLED=\$(grep -c migrate_rescue_plane \"\$CALLS\" || true)\""
    echo "[ -e \"$d/etc/systemd/system/pdg-rescue.socket\" ] && echo SOCKET=yes || echo SOCKET=no"
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1
}
o="$(chain refuse none keep)"; op="$(plain "$o")"
grep -q 'CHAIN_RC=1'     <<<"$op" && ok "L1: 有退役工作 + 调用方拿不出能力 ⇒ 迁移链返回非 0" || bad "L1: $(grep CHAIN_RC <<<"$op")"
grep -q 'RESCUE_CALLED=0'<<<"$op" && ok "L1: 救援迁移**一次都没被调用**" || bad "L1: 救援迁移仍被调用"
grep -q 'SOCKET=no'      <<<"$op" && ok "L1: 原本不存在的 pdg-rescue.socket **没有**被生成" || bad "L1: socket 还是落盘了"
grep -q '不执行迁移' <<<"$op" && ok "L1: 拒绝具名(点名本次不执行迁移)" || bad "L1: 没有具名拒绝"
grep -q '迁移链动第一样东西' <<<"$op" && ok "L1: 只承诺「迁移链」未动手" || bad "L1: 承诺范围不清"
grep -q '取件、切版本与装文件' <<<"$op" \
  && ok "L1: 明确把此前的取件/切版本/装文件排除在外(不宣称整次 update 零写入)" || bad "L1: 措辞越界"

# 观测存疑那一格: 没有待办材料, 但有一项查不出来 —— 也必须走同一条拒绝路径
o="$(chain unsure none keep)"; op="$(plain "$o")"
grep -q 'CHAIN_RC=1'      <<<"$op" && ok "L4: **观测存疑** + 无句柄 ⇒ 迁移链同样返回非 0(不当成没有待办放行)" || bad "L4: $(grep CHAIN_RC <<<"$op")"
grep -q 'RESCUE_CALLED=0' <<<"$op" && ok "L4: 救援迁移调用数 0" || bad "L4: 救援迁移仍被调用"
grep -q 'SOCKET=no'       <<<"$op" && ok "L4: socket 未生成" || bad "L4: socket 落盘了"
grep -q '无法确认' <<<"$op" && ok "L4: 拒绝文案点名是**无法确认**, 与「确有待办」分开说" || bad "L4: 没区分两种理由"

o="$(chain nowork none keep)"; op="$(plain "$o")"
grep -q 'CHAIN_RC=0'      <<<"$op" && ok "L2: 没有退役工作时, 旧调用方**不被误拒**" || bad "L2: $(grep CHAIN_RC <<<"$op")"
grep -q 'RESCUE_CALLED=1' <<<"$op" && ok "L2: 且迁移链照常走(救援迁移被调用)" || bad "L2: 迁移链被挡住了"

o="$(chain legit real keep)"; op="$(plain "$o")"
grep -q 'CHAIN_RC=0'      <<<"$op" && ok "L3: 有退役工作但调用方合法(真锁 + 本次句柄 + 快照绑定)⇒ 正常继续" || bad "L3: 合法调用被拦 —— $(why "$o")"
grep -q 'RESCUE_CALLED=1' <<<"$op" && ok "L3: 迁移链照常执行" || bad "L3: 迁移链没跑"

# ── inactive/0: 状态词与退出码不成对, 不是一种"没在跑"的状态 ──────────────
_w "P1: is-active 答 inactive 却 return 0 ⇒ 扫描器判**无法确认**(不是确认没有)" 2 "$(wp P1 '' inactive/0)"
_w "P1b: 健康对照 inactive/3 仍判**确认没有**" 1 "$(wp P1b '' inactive/3)"
_w "P1c: 健康对照 failed/3 仍判**确认没有**"   1 "$(wp P1c '' failed/3)"
o="$(chain ia0 none keep)"; op="$(plain "$o")"
grep -q 'CHAIN_RC=1'      <<<"$op" && ok "P2: 同一现场驱动**真实迁移链** ⇒ 返回非 0" || bad "P2: $(grep CHAIN_RC <<<"$op")"
grep -q 'RESCUE_CALLED=0' <<<"$op" && ok "P2: 救援迁移调用数 0" || bad "P2: 救援迁移仍被调用"
grep -q 'SOCKET=no'       <<<"$op" && ok "P2: 救援 socket 未生成" || bad "P2: socket 落盘了"
grep -q '无法确认' <<<"$op" && ok "P2: 拒绝理由归入「无法确认」" || bad "P2: 理由没归对"

echo
echo "══ 十七. 撤销对照: 只撤掉这一处前置, 同一反例重新到达救援副作用 ══"
o="$(chain refuse-drop none drop)"; op="$(plain "$o")"; op2="$op"
if grep -q 'RESCUE_CALLED=1' <<<"$op" && grep -q 'SOCKET=yes' <<<"$op"; then
  ok "M1: 撤掉 \`_retire_precheck || return 1\` 之后, **同一个**反例重新跑到救援迁移并落下 socket —— L1 那三条确实由这一处保住"
else
  bad "M1: 撤销对照没体现差异($(grep -E 'RESCUE_CALLED|SOCKET' <<<"$op" | tr '\n' ' '))"
fi
o="$(chain ia0-drop none ia0keep)"; op="$(plain "$o")"
if grep -q 'CHAIN_RC=0' <<<"$op" && grep -q 'SOCKET=yes' <<<"$op"; then
  ok "M3: **单处**把 inactive/0 例外加回去(其余一字不动), 同一输入重新被放行 —— 链子跑完并落下 socket"
else
  bad "M3: 撤销对照没体现差异($(grep -E 'CHAIN_RC|RESCUE_CALLED|SOCKET' <<<"$op" | tr '\n' ' '))"
fi

grep -q 'CHAIN_RC=1' <<<"$op2" \
  && ok "M2: 撤销之后链子仍以非 0 收场(退役那一步照旧被三个拦截点挡住)—— 差别只在**副作用有没有发生**" \
  || bad "M2: 撤销之后链子返回 0, 说明后面的拦截点被动过"


echo
echo "══ 十八. 平台判定时序: 前置按标记迁移**将会**定出的状态判(真实标记迁移 + 真实 Android 清理) ══"
# 在 chain() 的基础上, 把 migrate_platform_marker 与 migrate_android_cleanup 换回**产品原文**,
# 其余 migrate_* 仍打桩。平台四条输入与 $R 一律指向场景根; _pdg_platform 由产品原文那一行
# 派生(只把写死的路径换成 $PDG_PLATFORM_FILE), migrate_android_cleanup 用的就是它。
# 场景统一放 v1.4.x 普装的 iOS 组件: iosprofile.py / mitm_ca.py / pdg-dot 模板 / iosstate.py。
cat > "$BOX/revert-timing.py" <<'REVERTPY'
# 单处撤销: 只把扫描器里 Android 那一支换回旧形态(读此刻盘面的 _pdg_platform 与 platform.guessed),
# 助手、标记迁移与其余一字不动。
import sys
t = sys.stdin.read()
head = "  # Android 清理那一支只对**确认的** android 适用。"
tail = '平台据 ${_PDG_PLAN_SRC} 确认为 android)"; return 0\n  fi\n'
a = t.find(head); k = t.find(tail)
if a < 0 or k < 0:
    sys.stdout.write(t + '\necho REVERT_FAILED\n'); sys.exit(0)
old = ('  if [[ "$(_pdg_platform)" == android ]] \\\n'
       '     && [[ ! -e "$(dirname "${PDG_PLATFORM_FILE:-/etc/privdns-gateway/platform}")/platform.guessed" ]] \\\n'
       '     && _retire_android_pending "$R"; then\n'
       '    _RETIRE_WHY="Android 清理那一支还有退役件要删(_retire_android_pending 判有活)"; return 0\n'
       '  fi\n')
sys.stdout.write(t[:a] + old + t[k + len(tail):])
REVERTPY
cat > "$BOX/revert-marker.py" <<'REVMARKERPY'
# 单处撤销: 只把标记迁移"证据读不出来"那一支改回 274 的写法(推测 android 并落盘), 其余一字不动。
import sys
t = sys.stdin.read()
new = '    c_r "❌ 平台判定所需的证据读不出来(${_PDG_PLAN_WHY:-未知}): 本次不补、不改平台标记。"\n    return 2\n'
old = '    c_y "平台证据读不出来(${_PDG_PLAN_WHY:-未知}), 按推测处理。"\n    plat=android; guessed=1\n'
sys.stdout.write(t.replace(new, old) if new in t else t + '\necho REVERT_FAILED\n')
REVMARKERPY
cat > "$BOX/revert-chain.py" <<'REVCHAINPY'
# 单处撤销: 只把迁移链里标记迁移那一句改回 `|| true`(吞掉平台观测失败), 其余一字不动。
import sys
t = sys.stdin.read()
new = '  migrate_platform_marker || { [[ $? == 2 ]] && { c_r "❌ 平台判不出来, 迁移链停在这里(后续迁移一个都没跑)。"; return 1; }; }\n'
old = '  migrate_platform_marker || true\n'
sys.stdout.write(t.replace(new, old) if new in t else t + '\necho REVERT_FAILED\n')
REVCHAINPY
KIT4='iosprofile.py mitm_ca.py pdg-dot.mobileconfig.tmpl iosstate.py'
treesnap(){ ( cd "$1" && find etc opt \( -type f -o -type d \) | sort | while read -r x; do
    if [[ -f "$x" ]]; then printf 'f %s %s\n' "$(sha256sum < "$x" | cut -c1-16)" "$x"; else printf 'd %s\n' "$x"; fi
  done ); }
chainp(){  # $1=场景名 $2=句柄 real|none $3=平台布置 $4=变体 cur|revert|pre-only|rev-marker|rev-chain
           # 平台布置: none | profile-android | profile-dir | profile-dir-unit | android | android-guessed
           #           | ios | ios-readfail | mitm-unit
  local name="$1" hmode="$2" pmode="$3" var="${4:-cur}"
  local d="$BOX/cp-$name" f
  mkdir -p "$d/etc/privdns-gateway" "$d/opt/pdg-bot" "$d/etc/systemd/system" \
           "$d/etc/mosdns/rules" "$d/etc/mihomo" "$d/snap" "$d/sc"
  printf 'SCHEMA = 2\n' > "$d/opt/pdg-bot/iosstate.py"
  for f in iosprofile.py mitm_ca.py pdg-dot.mobileconfig.tmpl; do : > "$d/opt/pdg-bot/$f"; done
  seed_units "$d/sc"
  echo inactive > "$d/sc/pdg-mitm.ac"; echo dead > "$d/sc/pdg-mitm.sub"; rm -f "$d/sc/pdg-mitm.inv"
  case "$pmode" in
    none) ;;
    profile-android) printf 'PDG_PLATFORM=android\n' > "$d/etc/privdns-gateway/profile.env" ;;
    profile-dir)     mkdir -p "$d/etc/privdns-gateway/profile.env" ;;
    android)         printf 'android\n' > "$d/etc/privdns-gateway/platform" ;;
    android-guessed) printf 'android\n' > "$d/etc/privdns-gateway/platform"; : > "$d/etc/privdns-gateway/platform.guessed" ;;
    ios)             printf 'ios\n' > "$d/etc/privdns-gateway/platform" ;;
    mitm-unit)       : > "$d/etc/systemd/system/pdg-mitm.service" ;;
    profile-dir-unit) mkdir -p "$d/etc/privdns-gateway/profile.env"; : > "$d/etc/systemd/system/pdg-mitm.service" ;;
    ios-readfail)    printf 'ios\n' > "$d/etc/privdns-gateway/platform" ;;   # 读取失败在运行时注入
  esac
  treesnap "$d" > "$d.before"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\"; LOCK=\"$d/lock\""
    echo "CALLS=\"$d/calls.log\"; : > \"\$CALLS\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    echo "_pdg_module(){ printf '%s\n' \"$ROOT/deploy/bot/\$1\"; }"
    _fnN "$PDG" _pdg_lock_proof
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_svcstate_valid; _fnN "$PDG" _pdg_save_svcstate
    echo '_PDG_RETIRE_OK=""; _PDG_RETIRE_DONE=0; _RETIRE_WHY=""'
    _fnN "$PDG" _retire_caller_gate; _fnN "$PDG" _retire_allowed
    _fnN "$PDG" _retire_rerun_hint
    _fnN "$PDG" _retire_core_has_mitm; _fnN "$PDG" _retire_has_irreversible_work
    _fnN "$PDG" _retire_android_pending; _fnN "$PDG" _pdg_platform_plan
    if [[ "$var" == revert ]]; then _fnN "$PDG" _retire_work_pending | python3 "$BOX/revert-timing.py"
    else _fnN "$PDG" _retire_work_pending; fi
    _fnN "$PDG" _retire_precheck
    echo "export PDG_PLATFORM_FILE=\"$d/etc/privdns-gateway/platform\" PROFILE_ENV=\"$d/etc/privdns-gateway/profile.env\""
    echo "export PDG_MITM_JSON=\"$d/etc/privdns-gateway/mitm.json\" PDG_MITM_UNIT=\"$d/etc/systemd/system/pdg-mitm.service\""
    _fn1 "$PDG" _pdg_platform | sed 's#/etc/privdns-gateway/platform#${PDG_PLATFORM_FILE}#'
    echo 'for f in $(grep -oE "migrate_[a-z0-9_]+" "'"$PDG"'" | sort -u); do'
    echo '  eval "$f(){ echo \"$f\" >> \"$CALLS\"; return 0; }"'
    echo 'done'
    # 这两条换回产品原文(定义在桩循环之后, 覆盖桩)
    if [[ "$var" == rev-marker ]]; then _fnN "$PDG" migrate_platform_marker | python3 "$BOX/revert-marker.py"
    else _fnN "$PDG" migrate_platform_marker; fi
    _fnN "$PDG" migrate_android_cleanup
    echo "migrate_rescue_plane(){ echo migrate_rescue_plane >> \"\$CALLS\"; : > \"$d/etc/systemd/system/pdg-rescue.socket\"; return 0; }"
    echo "migrate_wloc_retire(){ echo migrate_wloc_retire >> \"\$CALLS\"; _retire_work_pending || return 0; _retire_allowed || return 1; return 0; }"
    if [[ "$var" == rev-chain ]]; then sed -n "/^run_all_migrations(){/,/^}/p" "$PDG" | python3 "$BOX/revert-chain.py"
    else sed -n "/^run_all_migrations(){/,/^}/p" "$PDG"; fi
    echo "exec 9>\"$d/lock\"; flock -n 9 || { echo LOCK_FAILED; exit 1; }"
    echo "printf 'snapshot-bytes' > \"$d/snap/snap.tar.gz\""
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null || { echo SAVE_FAILED; exit 1; }"
    [[ "$hmode" == real ]] && echo "export PDG_UPDATE_SVCSTATE=\"$d/snap/svcstate.tsv\""
    # 已有 ios 标记但读取失败: 只对平台标记这一个路径, 先吐 ios 再以非 0 收场(root 下同样生效)
    [[ "$pmode" == ios-readfail ]] && echo "cat(){ if [[ \"\${*: -1}\" == \"$d/etc/privdns-gateway/platform\" ]]; then echo ios; return 1; fi; command cat \"\$@\"; }"
    if [[ "$var" == pre-only ]]; then
      echo "PDG_RETIRE_ROOT=\"$d\" _retire_precheck; echo \"PRE_RC=\$?\""
    else
      echo "PDG_RETIRE_ROOT=\"$d\" run_all_migrations; echo \"CHAIN_RC=\$?\""
    fi
    echo "echo \"RESCUE_CALLED=\$(grep -c migrate_rescue_plane \"\$CALLS\" || true)\""
    echo "[ -e \"$d/etc/systemd/system/pdg-rescue.socket\" ] && echo SOCKET=yes || echo SOCKET=no"
    echo "echo \"CALLS_N=\$(grep -c . \"\$CALLS\" || true)\""
    echo "echo \"PLATFORM=[\$(command cat \"$d/etc/privdns-gateway/platform\" 2>/dev/null)]\""
    echo "[ -e \"$d/etc/privdns-gateway/platform.guessed\" ] && echo GUESSED=yes || echo GUESSED=no"
    echo "n=0; for f in $KIT4; do [ -f \"$d/opt/pdg-bot/\$f\" ] && n=\$((n+1)); done; echo \"KIT=\$n/4\""
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1
}
has(){ grep -q -- "$2" <<<"$1"; }
cp_check(){ # $1=格名 $2=输出 $3...=必须出现的片段
  local nm="$1" o="$2" x miss=""; shift 2
  for x in "$@"; do has "$o" "$x" || miss="$miss [$x]"; done
  if [[ -z "$miss" ]]; then ok "$nm"
  else bad "$nm —— 缺:$miss | $(grep -E 'CHAIN_RC|PRE_RC|RESCUE|SOCKET|PLATFORM|GUESSED|KIT|REVERT|判定依据' <<<"$o" | tr '\n' ' ')"; fi
}

# 1) 无标记、无明确平台证据, 只有普装的 iOS 组件: 不误拒; 标记迁移落为推测 android; 清理跳过; 组件保留
o="$(plain "$(chainp PL1 none none)")"
cp_check "PL1: 无标记 + 仅普装 iOS 组件 + 无句柄 ⇒ 前置**不误拒**, 迁移链照常走" "$o" 'CHAIN_RC=0' 'RESCUE_CALLED=1'
cp_check "PL1: 实际标记迁移落为**推测** android(platform=android + .guessed)" "$o" 'PLATFORM=\[android\]' 'GUESSED=yes'
cp_check "PL1: 后续真实 Android 清理见推测态而跳过, 四件 iOS 组件全部保留" "$o" '跳过 iOS 组件清理' 'KIT=4/4'
# 2) 无标记但 profile.env 明确 android / 已有确认 android: 有清理待办、无句柄 ⇒ 链首拒绝
o="$(plain "$(chainp PL2 none profile-android)")"
cp_check "PL2: 无标记但 profile.env=android + iOS 组件 + 无句柄 ⇒ 链首拒绝, 救援迁移 0 次, socket 未生成" "$o" \
  'CHAIN_RC=1' 'RESCUE_CALLED=0' 'SOCKET=no' 'Android 清理那一支' '平台据 profile 确认为 android'
cp_check "PL2: 拒绝发生在标记迁移之前 —— 前置没有写平台标记, 组件原样" "$o" 'PLATFORM=\[\]' 'GUESSED=no' 'KIT=4/4'
o="$(plain "$(chainp PL3 none android)")"
cp_check "PL3: 已有确认 android + iOS 组件 + 无句柄 ⇒ 链首拒绝, 救援迁移 0 次" "$o" \
  'CHAIN_RC=1' 'RESCUE_CALLED=0' 'SOCKET=no' '平台据 existing 确认为 android'
# 3) 已有推测 android、明确 ios: 平台语义不变; ios 不走 Android 清理, 但真正 WLOC 待办不漏
o="$(plain "$(chainp PL4 none android-guessed)")"
cp_check "PL4: 已有推测 android ⇒ 不拒, .guessed 保留, 清理跳过, 组件保留" "$o" 'CHAIN_RC=0' 'GUESSED=yes' '跳过 iOS 组件清理' 'KIT=4/4'
o="$(plain "$(chainp PL5 none ios)")"
cp_check "PL5: 已有 ios + 普装组件(无 WLOC 待办)⇒ 不拒, 平台仍是 ios, 组件保留" "$o" 'CHAIN_RC=0' 'PLATFORM=\[ios\]' 'KIT=4/4'
o="$(plain "$(chainp PL6 none mitm-unit)")"
if has "$o" 'CHAIN_RC=1' && has "$o" 'RESCUE_CALLED=0' && has "$o" '待办: svc=1' && ! has "$o" 'Android 清理那一支'; then
  ok "PL6: 无标记但有 pdg-mitm unit(将定为 ios)+ 无句柄 ⇒ 仍在链首拒绝, 依据是 WLOC 待办而不是 Android 那一支"
else bad "PL6: $(grep -E 'CHAIN_RC|RESCUE|判定依据' <<<"$o" | tr '\n' ' ')"; fi
# 4) 调用处: 助手读失败 ⇒ 无法确认, 走能力门(不当成缺失、不当成确认无待办)
o="$(plain "$(chainp PL7 none profile-dir)")"
cp_check "PL7: 平台证据读不出来 + 无句柄 ⇒ 链首拒绝, 理由是**无法确认**" "$o" 'CHAIN_RC=1' 'RESCUE_CALLED=0' '无法确认' '平台判定所需的证据读不出来'
# 合法调用方对照: 确认 android + 本次句柄 ⇒ 正常继续, 且真实 Android 清理确实动手
o="$(plain "$(chainp PL8 real profile-android)")"
cp_check "PL8: profile.env=android + 合法调用方(真锁 + 本次句柄 + 快照绑定)⇒ 正常继续, 标记落为确认 android" "$o" \
  'CHAIN_RC=0' 'RESCUE_CALLED=1' 'PLATFORM=\[android\]' 'GUESSED=no'
cp_check "PL8: 合法调用方下真实 Android 清理照常动手(iOS 专属件已清)" "$o" 'KIT=0/4'
# 5) 前置本身不写平台标记、不留下其它现场产物(只跑 _retire_precheck, 前后比对 etc/ 与 opt/)
o="$(plain "$(chainp PL9 none none pre-only)")"
treesnap "$BOX/cp-PL9" > "$BOX/cp-PL9.after"
if has "$o" 'PRE_RC=0' && cmp -s "$BOX/cp-PL9.before" "$BOX/cp-PL9.after"; then
  ok "PL9: 只跑前置(无标记现场)⇒ 放行, 且 etc/ 与 opt/ 前后逐项相同(没写平台标记、没留临时文件)"
else bad "PL9: $(grep PRE_RC <<<"$o") | 差异: $(diff "$BOX/cp-PL9.before" "$BOX/cp-PL9.after" | head -3 | tr '\n' ' ')"; fi
# 6) 单处撤销: 只把扫描器 Android 那一支换回旧形态 ⇒ 同一无标记反例重新被误拒; 健康与合法对照仍成立
o="$(plain "$(chainp PR1 none none revert)")"
if ! has "$o" 'REVERT_FAILED' && has "$o" 'CHAIN_RC=1' && has "$o" 'RESCUE_CALLED=0' && has "$o" 'Android 清理那一支'; then
  ok "PR1: **单处**撤回时序修复 ⇒ PL1 同一输入重新在链首被误拒(依据回到旧的 Android 那一支)"
else bad "PR1: 撤销对照没体现差异 —— $(grep -E 'REVERT|CHAIN_RC|RESCUE|判定依据' <<<"$o" | tr '\n' ' ')"; fi
o="$(plain "$(chainp PR3 none android revert)")"
cp_check "PR3: 撤销下健康对照不变 —— 确认 android + 无句柄仍被拒" "$o" 'CHAIN_RC=1' 'RESCUE_CALLED=0'
o="$(plain "$(chainp PR8 real profile-android revert)")"
cp_check "PR8: 撤销下合法调用方对照不变 —— 仍正常继续" "$o" 'CHAIN_RC=0' 'RESCUE_CALLED=1'

# ── 平台观测失败: 迁移链不吞, 依赖平台的迁移一个都不跑 ──────────────────────────────
# 用**合法句柄**驱动, 并确认输出里没有前置拒绝文案 —— 证明挡住链条的不是能力门, 而是标记迁移
# 的观测失败。CALLS_N = 被打桩的其余 migrate_* 实际被调用的笔数(标记迁移本身是原文, 不计)。
cg_stop(){ # $1=格名 $2=输出 $3=期望平台行
  local o="$2"
  if ! has "$o" '本次不执行迁移' && has "$o" '平台判定所需的证据读不出来' && has "$o" '迁移链停在这里' \
     && has "$o" 'CHAIN_RC=1' && has "$o" 'CALLS_N=0' && has "$o" 'RESCUE_CALLED=0' && has "$o" "$3"; then ok "$1"
  else bad "$1 —— $(grep -E 'CHAIN_RC|CALLS_N|RESCUE|PLATFORM|GUESSED|本次不执行迁移|迁移链停在这里|REVERT' <<<"$o" | tr '\n' ' ' | cut -c1-260)"; fi
}
o="$(plain "$(chainp PL10 real profile-dir-unit)")"
cg_stop "PL10: 无标记 + profile 读不出来 + 有 MITM unit + **合法句柄** ⇒ 过了能力门; 标记迁移判无法确认, 链返回 1、其后迁移 0 笔、不落平台标记" "$o" 'PLATFORM=\[\]'
has "$o" 'GUESSED=no' && ok "PL10b: .guessed 未生成(没有落推测 android)" || bad "PL10b: .guessed 被生成"
o="$(plain "$(chainp PL11 real ios-readfail)")"
cg_stop "PL11: 已有 ios 标记但读取失败 + 合法句柄 ⇒ 链返回 1、其后迁移 0 笔, 原标记仍是 ios" "$o" 'PLATFORM=\[ios\]'
has "$o" 'GUESSED=no' && ok "PL11b: .guessed 状态不变(仍无)" || bad "PL11b: .guessed 被改"
o="$(plain "$(chainp PL12 real none)")"
cp_check "PL12: 健康对照 —— 正常读完、确无证据 + 合法句柄 ⇒ 推测 android, 链照走" "$o" \
  'CHAIN_RC=0' 'RESCUE_CALLED=1' 'PLATFORM=\[android\]' 'GUESSED=yes'
# 撤销对照(只在副本里改, 各撤一处)
o="$(plain "$(chainp PR10c real profile-dir-unit rev-chain)")"
if ! has "$o" 'REVERT_FAILED' && ! has "$o" 'CALLS_N=0' && has "$o" 'RESCUE_CALLED=1'; then
  ok "PR10c: 只把链里那一句改回 \`|| true\` ⇒ 同一输入下后续迁移重新被执行(PL10 的判据有牙)"
else bad "PR10c: $(grep -E 'REVERT|CHAIN_RC|CALLS_N|RESCUE' <<<"$o" | tr '\n' ' ')"; fi
o="$(plain "$(chainp PR10m real profile-dir-unit rev-marker)")"
if ! has "$o" 'REVERT_FAILED' && has "$o" 'PLATFORM=\[android\]' && has "$o" 'GUESSED=yes'; then
  ok "PR10m: 只把标记迁移那一支改回「读不出来就推测」⇒ 同一输入重新落盘推测 android(PL10b 的判据有牙)"
else bad "PR10m: $(grep -E 'REVERT|CHAIN_RC|PLATFORM|GUESSED' <<<"$o" | tr '\n' ' ')"; fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

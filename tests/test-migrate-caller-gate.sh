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
                cat "$SC_DIR/$u.en" 2>/dev/null || { echo not-found; return 1; }; return 0;;
    is-active)  cat "$SC_DIR/$u.ac" 2>/dev/null || { echo inactive; return 3; }; return 0;;
    show) case "$3" in
            LoadState)    [[ -e "$SC_DIR/$u.en" || -e "$SC_DIR/$u.broken" ]] && echo loaded || echo not-found;;
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
    _fnN "$PDG" _lock_inherited          # 真家伙, 不是桩
    _fnN "$PDG" _pdg_svcstate_units
    _fnN "$PDG" _pdg_svc_q
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
    _fnN "$PDG" _pdg_svc_q
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
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
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
  _fnN "$PDG" _lock_inherited
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q
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
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_save_svcstate
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
echo "══ 七. 前像与此刻现状对不上 ══"
o="$(run_case G1 'echo disabled > "$D/sc/pdg-mitm.en"')"
expect_refuse G1 "$o" "前像与现状对不上"

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
echo "══ 九. 撤销对照: 把门去掉, 旧调用方会**真的**走进副作用路径 ══"
NOGATE="$BOX/pdg-nogate.sh"
grep -v '_retire_caller_gate || return 1' "$PDG" > "$NOGATE"
if cmp -s "$PDG" "$NOGATE"; then
  bad "I1: 没造出反向副本(锚点漂了), 对照失效"
else
  ok "I1: 反向副本就位(只删掉调用门那一行, 其余逐字节相同)"
  d="$BOX/I2"; mkdir -p "$d/sc"; seed_units "$d/sc"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$d/sc\"; SC_LOG=\"$d/sc.log\"; : > \"\$SC_LOG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_q; _fnN "$PDG" _pdg_svcstate_valid
    _fnN "$NOGATE" _retire_has_irreversible_work
    # 把"门之后紧接着会做的第一件不可逆的事"原样搬来: 停 + 禁用 pdg-mitm
    echo 'if _retire_has_irreversible_work 1 0 0 0 0; then systemctl disable --now pdg-mitm >/dev/null 2>&1; fi'
  } > "$d/run.sh"
  bash "$d/run.sh" >/dev/null 2>&1
  grep -q 'disable --now pdg-mitm' "$d/sc.log" \
    && ok "I2: 撤掉门之后**真的执行了** disable --now pdg-mitm(不是少一行提示)" \
    || bad "I2: 反向对照没有触到副作用路径"
  [[ "$(cat "$d/sc/pdg-mitm.en" 2>/dev/null)" == disabled ]] \
    && ok "I3: 且服务状态真的被改了(enabled → disabled)" || bad "I3: 状态没变, 对照无效"
  # 反过来: 门在的时候, 同一条路上**一个服务动作都没有**
  d2="$BOX/B1"
  if [[ -f "$d2/sc.log" ]]; then
    if grep -qE '^(stop|disable|start|enable|mask) ' "$d2/sc.log"; then
      bad "I4: 拒绝之前动了服务: $(grep -E '^(stop|disable|start|enable|mask) ' "$d2/sc.log" | head -3 | tr '\n' ';')"
    else ok "I4: 拒绝之前没有任何 stop/disable/start/enable/mask 动作(只有查询)"; fi
  else bad "I4: 拿不到 systemctl 记账"; fi
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

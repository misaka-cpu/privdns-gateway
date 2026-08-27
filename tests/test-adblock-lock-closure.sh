#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 去广告写入口的并发闭包。
#
# `pdg adblock` 下面有五个会改状态的命令 —— enable / disable / update / rule-add / rule-del。
# 它们都会动用户源、编译产物、LKG、启用位或 mosdns 运行配置, 因此必须**共用同一把全局锁**,
# 与 `pdg update` 互斥。只有 rule-add/rule-del 取锁而其余三个不取, 等于留了三扇没关的门。
#
# 判据全部是**行为级**的: 真占住锁, 再看命令有没有越过第一个副作用点(建状态目录、写启用位、
# 改编译产物、调 systemctl、留临时文件), 而不是 grep 源码里有没有 `_lock` 这五个字。
# 占锁用 flock + FIFO barrier, 确定性握手, 不靠 sleep 碰运气。
#
# 另外两条:
#   · 锁忙时 rule-add/rule-del 必须给出**闭集机器结果**(ADBLOCK_BUSY), 否则 Bot 只能瞎猜,
#     现状是被兜底成 apply_failed_rolled_back —— 那是在说"改了又回滚了", 与事实不符;
#   · status 必须**严格只读**: 缺文件就当空集报告, 不许先建再读。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
WORK="$(mktemp -d)" || exit 1
cleanup(){ [[ -n "${HOLDER_PID:-}" ]] && kill "$HOLDER_PID" 2>/dev/null
           [[ -n "${PDG_KEEP_TMP:-}" ]] && { echo "现场保留: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

extract(){
  local fn="$1" ln
  ln="$(grep -n "^${fn}()" "$ROOT/deploy/bot/pdg.sh" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || { echo "抽不到 $fn" >&2; return 1; }
  if sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)\{.*\}[[:space:]]*$'; then
    sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh"
  else
    sed -n "${ln},/^}/p" "$ROOT/deploy/bot/pdg.sh"
  fi
}
CLOSURE="$WORK/closure.sh"; : > "$CLOSURE"
# **真的 _lock**(连同 _lock_inherited)—— 这一支验的就是锁本身, 不能桩掉。
for fn in c_g c_y _profile_set _pdg_module _lock_inherited _lock _adblock_intent \
          _adblock_ensure_files _adblock_gen_infra _adblock_apply _adblock_status cmd_adblock; do
  extract "$fn" >> "$CLOSURE" || { bad "生产函数闭包抽取失败: $fn"; echo "通过 $pass, 失败 $nfail"; exit 1; }
  echo >> "$CLOSURE"
done
cat >> "$CLOSURE" <<'STUB'
need_root(){ :; }
# pdg.sh 第 95 行的顶层赋值。只抽函数会漏掉它, 而 pdg.sh 跑在 `set -u` 下 ——
# 漏了的话 _lock 第一句就 unbound variable 把子 shell 打死, 于是每个命令看起来都"没有
# 副作用", 全部假绿。生产里它是空串, 这里照抄。
PDG_LOCKED=""
STUB

new_box(){
  local w="$WORK/$1"; mkdir -p "$w/etc/mosdns/rules" "$w/bin" "$w/state" "$w/run" "$w/repo/deploy"
  ln -sfn "$ROOT/deploy/bot" "$w/repo/deploy/bot"
  printf 'PDG_INTERNAL_CIDR=172.22.0.0/16\n' > "$w/etc/privdns-gateway.profile"
  : > "$w/etc/mosdns/rules/adblock_allow.txt"
  printf 'domain:already.invalid\n' > "$w/etc/mosdns/rules/adblock_block.txt"
  # **状态目录刻意不建** —— _adblock_ensure_files 一旦被调到, 它的出现就是铁证。
  cat > "$w/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_ROOT/state/systemctl"
case "$1" in is-active) exit 0;; esac
exit 0
S
  chmod 755 "$w/bin/systemctl"
  echo "$w"
}

run_box(){   # $1=box $2=命令  [$3=1 表示复用已存在的 state]
  local w="$1" body="$2"
  ( set +e
    export FX_ROOT="$w"
    PATH="$w/bin:$PATH"; export PATH
    REPO_DIR="$w/repo"; export REPO_DIR
    PROFILE_ENV="$w/etc/privdns-gateway.profile"
    ADB_STATE_DIR="$w/var/adblock"
    ADB_USER_ALLOW="$w/etc/mosdns/rules/adblock_allow.txt"
    ADB_USER_BLOCK="$w/etc/mosdns/rules/adblock_block.txt"
    LOCK="$LOCKFILE"
    export PROFILE_ENV ADB_STATE_DIR ADB_USER_ALLOW ADB_USER_BLOCK LOCK
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$body"
  ) > "$w/out.log" 2>&1
  echo $?
}

# ── 确定性占锁器: flock 拿到锁后经 FIFO 通知, 收到第二个信号才释放 ──────────
LOCKFILE="$WORK/pdg.lock"; : > "$LOCKFILE"
HELD="$WORK/held.fifo"; REL="$WORK/rel.fifo"; mkfifo "$HELD" "$REL"
hold_lock(){
  ( exec 9>"$LOCKFILE"
    flock -n 9 || { echo nolock > "$HELD"; exit 1; }
    echo held > "$HELD"
    read -r _ < "$REL" ) &
  HOLDER_PID=$!
  local sig; read -r sig < "$HELD"
  [[ "$sig" == held ]]
}
release_lock(){ echo go > "$REL" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""; }

# ── 副作用探针 ───────────────────────────────────────────────────────────────
statedir(){ [[ -d "$1/var/adblock" ]] && echo yes || echo no; }
sysctl_calls(){ [[ -e "$1/state/systemctl" ]] && wc -l < "$1/state/systemctl" | tr -d ' ' || echo 0; }
intent_of(){ sed -n 's/^[[:space:]]*PDG_ADBLOCK_ENABLED=//p' "$1/etc/privdns-gateway.profile" 2>/dev/null | tail -1; }
srcfp(){ sha256sum "$1/etc/mosdns/rules/adblock_block.txt" 2>/dev/null | cut -c1-16; }
jf(){ python3 -c 'import json,sys
try:
    for ln in open(sys.argv[1], encoding="utf-8"):
        ln=ln.strip()
        if ln.startswith("{"):
            print(json.loads(ln).get(sys.argv[2], "")); break
    else: print("")
except Exception: print("")' "$1/out.log" "$2"; }

echo "══ ① 锁被占住时, 五个写入口都不许越过第一个副作用点 ══"
hold_lock || { bad "占锁器没拿到锁 —— 前提不成立"; echo "通过 $pass, 失败 $nfail"; exit 1; }
ok "前提: 全局锁已被另一进程持有"
for cmd in "cmd_adblock enable" "cmd_adblock disable" "cmd_adblock update" \
           "cmd_adblock rule-add newly.invalid" "cmd_adblock rule-del already.invalid"; do
  name="${cmd#cmd_adblock }"
  W="$(new_box "lk-${name%% *}")"
  before_src="$(srcfp "$W")"; before_intent="$(intent_of "$W")"
  rc="$(run_box "$W" "$cmd")"
  sd="$(statedir "$W")"; sc="$(sysctl_calls "$W")"
  [[ "$sd" == no ]] && ok "[$name] 没有建出状态目录(未越过 ensure_files)" \
                    || bad "[$name] 锁忙却建了状态目录 —— 已经进了写路径"
  [[ "$sc" == 0 ]] && ok "[$name] 未调用 systemctl" || bad "[$name] 锁忙却调了 systemctl $sc 次"
  [[ "$(srcfp "$W")" == "$before_src" ]] && ok "[$name] 用户源逐字节未动" || bad "[$name] 锁忙却改了用户源"
  [[ "$(intent_of "$W")" == "$before_intent" ]] && ok "[$name] 启用位未变" || bad "[$name] 锁忙却写了启用位"
  [[ "$rc" != 0 ]] && ok "[$name] 返回非零(rc=$rc)" || bad "[$name] 锁忙却返回 0"
done

echo
echo "══ ② 锁忙时 rule-add/rule-del 必须给闭集机器结果 ══"
for act in rule-add rule-del; do
  W="$(new_box "busy-$act")"
  run_box "$W" "cmd_adblock $act probe.invalid" >/dev/null
  r="$(jf "$W" result)"
  [[ "$r" == "ADBLOCK_BUSY" || "$r" == "busy" ]] \
    && ok "[$act] 锁忙 result=$r(闭集)" \
    || bad "[$act] 锁忙没有闭集结果(实得 '${r:-<无 JSON>}')"
  grep -qE '回滚|已保存|已生效|应用失败' "$W/out.log" \
    && bad "[$act] 锁忙输出里出现了「回滚/已保存/已生效/应用失败」字样" \
    || ok "[$act] 锁忙输出没有误导性字样"
done

echo
echo "══ ③ 锁被占住时 check/status 仍可只读运行 ══"
W="$(new_box ro1)"
rc="$(run_box "$W" 'cmd_adblock status')"
[[ "$rc" == 0 ]] && ok "status 在锁忙时仍返回 0" || bad "status 被锁挡住了(rc=$rc)"
rc="$(run_box "$W" 'cmd_adblock check example.invalid')"
[[ "$rc" == 0 || "$rc" == 2 ]] && ok "check 在锁忙时仍能运行(rc=$rc)" || bad "check 被锁挡住了(rc=$rc)"
release_lock
ok "占锁器已释放"

echo
echo "══ ④ 锁释放后命令可以正常重试 ══"
W="$(new_box retry)"
rc="$(run_box "$W" 'cmd_adblock rule-add retried.invalid')"
[[ "$rc" == 0 ]] && ok "释放后 rule-add 成功(rc=0)" || bad "释放后仍失败: rc=$rc $(tail -2 "$W/out.log"|tr '\n' ' ')"
grep -qx 'domain:retried.invalid' "$W/etc/mosdns/rules/adblock_block.txt" \
  && ok "规则真的写进去了" || bad "规则没写进去"

echo
echo "══ ⑤ status 必须严格只读(五个现场)══"
# 现场 1: 状态目录完全不存在
W="$(new_box ro-a)"
run_box "$W" 'cmd_adblock status' >/dev/null
[[ "$(statedir "$W")" == no ]] && ok "[目录不存在] status 没有建出目录" || bad "[目录不存在] status 建了目录"
# 现场 2: 目录在, 受管文件不在
W="$(new_box ro-b)"; mkdir -p "$W/var/adblock"
before="$(ls -A "$W/var/adblock" | wc -l)"
run_box "$W" 'cmd_adblock status' >/dev/null
[[ "$(ls -A "$W/var/adblock" | wc -l)" == "$before" ]] \
  && ok "[缺文件] status 没有建出文件" || bad "[缺文件] status 建了 $(ls -A "$W/var/adblock"|tr '\n' ' ')"
# 现场 3: 文件已存在 → mtime/mode 不许变
W="$(new_box ro-c)"; mkdir -p "$W/var/adblock"
for f in infra_allow effective_block effective_list; do : > "$W/var/adblock/$f.txt"; chmod 644 "$W/var/adblock/$f.txt"; done
touch -d '2020-01-01 00:00:00' "$W/var/adblock/effective_block.txt"
m0="$(stat -c '%Y %a' "$W/var/adblock/effective_block.txt")"
run_box "$W" 'cmd_adblock status' >/dev/null
[[ "$(stat -c '%Y %a' "$W/var/adblock/effective_block.txt")" == "$m0" ]] \
  && ok "[文件已存在] mtime/mode 未变" || bad "[文件已存在] mtime/mode 被动了"
# 现场 4/5: 启用 / 停用 两种意图下都只读, 且文案仍然诚实
for st in 1 0; do
  W="$(new_box "ro-en$st")"; printf 'PDG_ADBLOCK_ENABLED=%s\n' "$st" >> "$W/etc/privdns-gateway.profile"
  rc="$(run_box "$W" 'cmd_adblock status')"
  [[ "$(statedir "$W")" == no ]] && ok "[启用位=$st] status 未建目录" || bad "[启用位=$st] status 建了目录"
  want=$([[ "$st" == 1 ]] && echo 已启用 || echo 未启用)
  grep -q "$want" "$W/out.log" && ok "[启用位=$st] 仍如实报告「$want」" || bad "[启用位=$st] 没报告出「$want」"
  [[ "$(sysctl_calls "$W")" == 0 ]] && ok "[启用位=$st] status 未调 systemctl" || bad "[启用位=$st] status 调了 systemctl"
done

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

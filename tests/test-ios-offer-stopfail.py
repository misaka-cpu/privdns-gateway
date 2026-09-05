#!/usr/bin/env python3
"""iOS 临时下载通道: **停不掉要有界返回, 状态读不到不算已退出** —— 行为验证。

两个入口都在停止判据这一层:

  ① `_ios_offer_stop_child` 走完 TERM → 轮询 → KILL → 轮询 之后, **无条件** `wait "$pid"`。
     若被停的直接子进程在预算耗尽后仍然存活, 这一句就是无界阻塞: 收尾停在半路,
     会话锁一直被占, 调用方永远拿不到"停不掉"这个返回值 —— 上层为此写好的
     `gen_unsafe`(保留现场并返回非零)分支根本走不到。

  ② `_ios_offer_proc_dead` 里 `cat /proc/<pid>/stat` 读失败时 `return 0` —— 把
     "读不到"当成"已经退出"。进程其实还在跑, 调用方却据此认定可以 `wait`、可以删目录。
     这与本项目既有的"未知不得冒充确定"(见 `_ios_offer_proc_state`)自相矛盾。

注入点全在测试这一侧, 产品代码不留测试钩子:
  * `kill` 用 **shell 函数**覆盖(函数优先于同名 builtin) —— 每次调用都记账, 名单里的
    pid 只记账不投递, 于是 TERM/KILL "发出了但没效果", 与真实的停不掉同形。
  * `/proc/<pid>/stat` 读失败用 PATH 上的 `cat` 桩注入, 只对指定 pid、只在布防后失败。

判据用**调用记录 + 屏障 + 行为**, 不用"超过几秒"当唯一断言: 挂死那一格先等 killlog
出现 KILL 尝试(事件), 再看停止预算走完后是否返回 —— 时限只用来把挂死的进程收回来,
不作为判定依据。故障释放与手工清理一律在断言之后。
"""
import os, re, socket, subprocess, sys, time
from pathlib import Path
import tmpguard

ROOT = Path(__file__).resolve().parents[1]
PORT = 8443
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   " + m)
def bad(m): FAIL[0] += 1; print("[FAIL] " + m)

NFT_STUB = r'''#!/bin/bash
st="$PDG_TEST_CHAIN"
if [ ! -s "$st" ]; then printf '1|iif "lo" accept\n4|iifname "tailscale0" return\n' > "$st"; fi
echo "nft $*" >> "$PDG_TEST_LOG"
render(){ local a out="" q=0
  for a in "$@"; do
    if [ "$q" = 1 ]; then out="$out \"$a\""; q=0
    else out="$out $a"; [ "$a" = comment ] && q=1; fi
  done; echo "${out# }"; }
next_handle(){ echo $(( $(cut -d'|' -f1 "$st" | sort -n | tail -1) + 1 )); }
if [ "$1" = -j ] && [ "$2" = --echo ]; then
  shift 3; shift 5; nh=$(next_handle); echo "$nh|$(render "$@")" >> "$st"
  printf "{\"nftables\":[{\"add\":{\"rule\":{\"handle\":%s}}}]}\n" "$nh"; exit 0
fi
case "$1" in
  -a) echo "table inet pdg {"; echo "	chain input {"
      while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$st"
      echo "	}"; echo "}" ;;
  delete) shift $(($# - 1)); grep -v "^$1|" "$st" > "$st.n" 2>/dev/null; mv "$st.n" "$st" ;;
esac
exit 0
'''

# 生成器桩: 亮相并登记 → 等测试放行 → 才落盘。停不掉的那几格永远不放行。
PY_STUB = r'''#!/bin/bash
real=/usr/bin/python3
if [ "${1:-}" = "$CH_DIR/iosstate.py" ]; then
  out=""; prev=""
  for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
  [ "$(dirname "$out")" = "/" ] && { echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1; }
  if [ "${PDG_TEST_BARRIER:-}" = gen ]; then
    echo "$$" > "$CH_DIR/genpid"; : > "$CH_DIR/gen-started"
    n=0
    while [ ! -e "$CH_DIR/gen-release" ] && [ "$n" -lt 3000 ]; do sleep 0.1; n=$((n+1)); done
    mkdir -p "$(dirname "$out")"
    printf '%s' "$PDG_TEST_BODY" > "$out"
    : > "$CH_DIR/gen-wrote"
    exit 0
  fi
  printf '%s' "$PDG_TEST_BODY" > "$out"
  exit 0
fi
if [ "${1:-}" = -c ] && case "${2:-}" in *serve_forever*) true;; *) false;; esac; then
  echo "srv-invoked" >> "$PDG_TEST_SRVLOG"; echo "$$" >> "$PDG_TEST_SRVPID"
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

# /proc/<pid>/stat 读失败注入: 只对 $CH_DIR/target 里那个 pid、只在 $CH_DIR/stat-fail 布防后失败。
# 自己不用 cat, 免得递归回到本桩。
CAT_STUB = r'''#!/bin/bash
if [ -e "$CH_DIR/stat-fail" ] && [ -r "$CH_DIR/target" ]; then
  t=""; read -r t < "$CH_DIR/target"
  if [ -n "$t" ] && [ "${1:-}" = "/proc/$t/stat" ]; then
    echo "stat-read-denied $t" >> "$CH_DIR/catlog"
    exit 1
  fi
fi
exec /bin/cat "$@"
'''

OPENSSL_STUB = ('#!/bin/sh\nn=6\nfor a in "$@"; do n="$a"; done\n'
                'od -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\necho\n')

HARNESS = r'''
set -uo pipefail
cd "$CH_ROOT"
echo $$ > "$CH_DIR/pid"
: > "$CH_DIR/fn.sh"
for fn in cmd_ios cmd_ios_previous _ios_offer_download _ios_offer_teardown _ios_offer_abort \
          _ios_offer_nft_close _ios_offer_chain _ios_offer_marks _ios_offer_rule_ok \
          _ios_offer_ready _ios_offer_lock_acquire _ios_offer_lock_release \
          _ios_offer_on_signal _ios_offer_srv_alive _ios_offer_reap_orphan \
          _ios_offer_starttime _ios_offer_state_write _ios_offer_session_begin \
          _ios_offer_dir_ok _ios_offer_root_ok _ios_offer_reap_dir _ios_offer_dir_pid \
          _ios_offer_proc_state _ios_offer_stop_pid _ios_offer_list _ios_offer_gen_run \
          _nft_apply_main _lan_nft_reapply \
          _ios_offer_stop_child _ios_offer_proc_dead; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE|IOS_OFFER_GENFILE)=' \
  deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
for v in IOS_OFFER_PROBE IOS_OFFER_SERVER; do
  sed -n "/^$v='/,/^'\$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
missing=""
for fn in $(grep -oE '_ios_offer_[a-z_]+' "$CH_DIR/fn.sh" | sort -u); do
  grep -q "^$fn()" "$CH_DIR/fn.sh" || missing="$missing $fn"
done
for k in $(grep -oE '\bIOS_OFFER_[A-Z_]+' "$CH_DIR/fn.sh" | sort -u); do
  grep -qE "^$k=" "$CH_DIR/fn.sh" || missing="$missing \$$k"
done
[ -z "$missing" ] || { echo "EXTRACT-MISSING:$missing"; exit 9; }
need_root(){ :; }
ic_gate(){ return 0; }
cmd_ios_state(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
_ios_dot_host(){ echo dot.example.invalid; }
_ios_server_ip(){ echo 203.0.113.10; }
_ios_internal_cidr(){ echo 172.22.0.0/16; }
_pdg_module(){ echo "$CH_DIR/iosstate.py"; }
IOS_TMPL="$CH_DIR/tmpl.mobileconfig"
export PDG_IOS_LEGACY=n
# shellcheck source=/dev/null
. "$CH_DIR/fn.sh"

# ── 注入: 记账并可吞掉投递的 kill ─────────────────────────────────────────
# shell 函数优先于同名 builtin, 所以产品代码里原样的 `kill` 会走到这里。名单里的 pid
# 只记账不投递 —— 于是"信号发出去了却没效果", 与被停进程赖着不走同形。
kill(){
  local a last="" sw=""
  for a in "$@"; do last="$a"; done
  printf '%s\n' "$*" >> "$CH_DIR/killlog"
  if [ -r "$CH_DIR/swallow" ]; then read -r sw < "$CH_DIR/swallow"; fi
  case " $sw " in *" $last "*) return 0 ;; esac
  builtin kill "$@"
}

# ── 单元格用的受控直接子进程 ────────────────────────────────────────────
_UP=""
_u_spawn(){   # $1 = TERM 的 trap 表达式(''=忽略); 结果放进 _UP, 必须是本 shell 的直接子进程
  ( trap "${1-}" TERM; exec 6>&-; while :; do sleep 0.2; done ) &
  _UP=$!
}
_u_state(){ local l; read -r l < "/proc/$1/stat" 2>/dev/null || return 1; l="${l##*) }"; echo "${l%% *}"; }
_u_wait_state(){ local n=0; while [ "$n" -lt 200 ]; do [ "$(_u_state "$1")" = "$2" ] && return 0; sleep 0.05; n=$((n+1)); done; return 1; }
_u_alive(){ [ -d "/proc/$1" ] && echo 1 || echo 0; }

# ① TERM 就能停: 应当返回成功, 并且已经回收(不留僵尸)
_u_term_exit(){
  _u_spawn "-"
  echo "U:pid=$_UP"; echo "$_UP" > "$CH_DIR/target"
  _ios_offer_stop_child "$_UP"; echo "U:rc=$?"
  echo "U:alive=$(_u_alive "$_UP")"
}
# ② TERM 无效, 升级到 KILL 才停: 调用记录里应当先 TERM 后 KILL, 结果仍是成功
_u_term_kill(){
  _u_spawn ""
  echo "U:pid=$_UP"; echo "$_UP" > "$CH_DIR/target"
  _ios_offer_stop_child "$_UP"; echo "U:rc=$?"
  echo "U:alive=$(_u_alive "$_UP")"
}
# ③ TERM 与 KILL 都发了却都没效果: 预算走完仍存活, 必须有界地返回失败(而不是卡在 wait)
_u_unstoppable(){
  _u_spawn ""
  echo "U:pid=$_UP"; echo "$_UP" > "$CH_DIR/swallow"
  : > "$CH_DIR/armed"
  _ios_offer_stop_child "$_UP"; echo "U:rc=$?"
  echo "U:alive=$(_u_alive "$_UP")"
}
# ④ 进程还在, 但 /proc/<pid>/stat 读不到: 不得判成"已退出"
_u_unreadable(){
  _u_spawn "-"
  echo "U:pid=$_UP"; echo "$_UP" > "$CH_DIR/target"; : > "$CH_DIR/stat-fail"
  _ios_offer_proc_dead "$_UP"; echo "U:rc=$?"
  echo "U:alive=$(_u_alive "$_UP")"
  echo "U:catlog=$( [ -s "$CH_DIR/catlog" ] && echo 1 || echo 0 )"
}
# ⑤ 与④的对照: 进程真的消失了(已回收, /proc 不在)。读失败注入照样布防着,
#    但这一格必须判成"已退出" —— 证明④不是把所有读不到都拦下来。
_u_reallygone(){
  _u_spawn "-"
  echo "U:pid=$_UP"; echo "$_UP" > "$CH_DIR/target"; : > "$CH_DIR/stat-fail"
  builtin kill -KILL "$_UP" 2>/dev/null
  wait "$_UP" 2>/dev/null
  echo "U:alive=$(_u_alive "$_UP")"
  _ios_offer_proc_dead "$_UP"; echo "U:rc=$?"
}
# ⑥ 真僵尸(别人的子进程, 没人回收)上的判据: 必须说"已退出" —— kill -0 在僵尸上是成功的,
#    所以这一格同时记下 kill -0 的观测, 证明 Z 分支不是可有可无。
#    (bash 会在下一个安全点自行回收自己的后台子进程, 所以"直接子进程的僵尸"不可稳定构造;
#     僵尸判据用别人的孤儿来验, 直接子进程的回收另开一格 —— 见 ⑦。)
_u_zombie_pred(){
  local helper zp n=0
  /usr/bin/python3 -c 'import os,sys,time
p=os.fork()
if p==0: os._exit(7)
sys.stdout.write("%d\n"%p); sys.stdout.flush()
time.sleep(90)' > "$CH_DIR/zpid" &
  helper=$!
  while [ "$n" -lt 200 ] && [ ! -s "$CH_DIR/zpid" ]; do sleep 0.05; n=$((n+1)); done
  zp=""; [ -s "$CH_DIR/zpid" ] && read -r zp < "$CH_DIR/zpid"
  echo "U:pid=$helper"; echo "U:zpid=$zp"
  if [ -n "$zp" ]; then
    _u_wait_state "$zp" Z && echo "U:zombie=1" || echo "U:zombie=0"
    builtin kill -0 "$zp" 2>/dev/null && echo "U:kill0=1" || echo "U:kill0=0"
    # 再确认一次: 观测之间僵尸若被回收走了, 那是夹具没保持住, 不是判据的问题
    [ "$(_u_state "$zp")" = Z ] && echo "U:held=1" || echo "U:held=0"
    _ios_offer_proc_dead "$zp"; echo "U:dead=$?"
  fi
}
# ⑦ 已退出、待回收的直接子进程: 判据说已退出, 停止流程应当 wait 掉它并成功返回
_u_exited_child(){
  ( exec 6>&-; exit 7 ) &
  _UP=$!
  local n=0
  while [ "$n" -lt 200 ] && [ -d "/proc/$_UP" ] && [ "$(_u_state "$_UP")" != Z ]; do sleep 0.05; n=$((n+1)); done
  echo "U:pid=$_UP"
  _ios_offer_proc_dead "$_UP"; echo "U:dead=$?"
  _ios_offer_stop_child "$_UP"; echo "U:rc=$?"
  echo "U:alive=$(_u_alive "$_UP")"
  case " $(jobs -p | tr '\n' ' ') " in *" $_UP "*) echo "U:jobs=1";; *) echo "U:jobs=0";; esac
}


"$CH_FN" < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>stopfail</key></dict></plist>\n'


def mkcase(tag, fn="cmd_ios", **extra):
    d = tmpguard.mkdtemp(prefix="iossf-%s-" % tag)
    b = os.path.join(d, "bin"); os.makedirs(b); os.makedirs(os.path.join(d, "st"))
    for n, c in (("tmpl.mobileconfig", "<plist/>\n"), ("iosstate.py", "# stub\n")):
        with open(os.path.join(d, n), "w", encoding="utf-8") as f:
            f.write(c)
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB), ("cat", CAT_STUB),
                    ("openssl", OPENSSL_STUB), ("qrencode", "#!/bin/sh\nexit 0\n")):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(s)
        os.chmod(p, 0o755)
    env = dict(os.environ, PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_SRVLOG=os.path.join(d, "srvlog"),
               PDG_TEST_SRVPID=os.path.join(d, "srvpid"),
               PDG_TEST_CHAIN=os.path.join(d, "chain"),
               PDG_TEST_BODY=BODY.decode(),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "st", "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d, CH_DIR=d, CH_ROOT=str(ROOT), CH_FN=fn)
    env.update({k: str(v) for k, v in extra.items()})
    return d, env


def launch(d, env):
    hp = os.path.join(d, "h.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    o = open(os.path.join(d, "out"), "w", encoding="utf-8")
    return subprocess.Popen(["bash", hp], env=env, cwd=str(ROOT), stdout=o,
                            stderr=subprocess.STDOUT, text=True)


def read(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def alive(p):
    return os.path.exists("/proc/%d" % p)


def children_of(pid):
    out = []
    for e in os.listdir("/proc"):
        if not e.isdigit():
            continue
        try:
            with open("/proc/%s/status" % e, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("PPid:"):
                        if int(line.split()[1]) == pid:
                            out.append(int(e))
                        break
        except OSError:
            pass
    return out


def reap_tree(pid):
    """按精确 pid 收回残留(逐个 SIGKILL), 不用宽模式匹配。"""
    kids = children_of(pid)
    for p in [pid] + kids:
        try:
            os.kill(p, 9)
        except OSError:
            pass
    for p in kids:
        for g in children_of(p):
            try:
                os.kill(g, 9)
            except OSError:
                pass


def wait_for(fn, limit=30.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.03)
    return False


def connectable(t=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=t); s.close(); return True
    except OSError:
        return False


def marks(d):
    """U: 行解析成字典(同名取最后一次)。"""
    got = {}
    for m in re.finditer(r"^U:([a-z0-9_]+)=(.*)$", read(os.path.join(d, "out")), re.M):
        got[m.group(1)] = m.group(2).strip()
    return got


def killcalls(d, pid):
    """针对某 pid 的调用记录, 归一成信号名序列。"""
    seq = []
    for line in read(os.path.join(d, "killlog")).splitlines():
        f = line.split()
        if not f or f[-1] != str(pid):
            continue
        sig = f[0][1:] if len(f) > 1 and f[0].startswith("-") else "TERM"
        seq.append(sig)
    return seq


def run_unit(tag, fn, hang_note, limit=60):
    """跑一格单元。返回 (marks, killlog序列源, hung)。挂死只用来把进程收回来, 不作判据。"""
    d, env = mkcase(tag, fn=fn, CH_STDIN_HOLD=1)
    p = launch(d, env)
    hung = False
    try:
        p.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        hung = True
        reap_tree(p.pid)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    time.sleep(0.2)
    g = marks(d)
    pid = int(g["pid"]) if g.get("pid", "").isdigit() else None
    if pid:                       # 断言之后再做手工清理
        try:
            os.remove(os.path.join(d, "swallow"))
        except OSError:
            pass
        if alive(pid):
            reap_tree(pid)
    return d, g, pid, hung


print("### 一、停止判据(单元) ###")

# ① TERM 就能停
d, g, pid, hung = run_unit("termexit", "_u_term_exit", "")
seq = killcalls(d, pid) if pid else []
if hung:
    bad("① TERM 后正常退出: 驱动挂死了, 这一格没测到东西")
elif g.get("rc") == "0" and g.get("alive") == "0" and seq[:1] == ["TERM"] and "KILL" not in seq:
    ok("① TERM 后正常退出 → 返回 0, 进程已回收, 调用记录只有 TERM(%s)" % ",".join(seq))
else:
    bad("① TERM 后正常退出: rc=%s alive=%s 调用记录=%s" % (g.get("rc"), g.get("alive"), ",".join(seq) or "空"))

# ② TERM 无效 → KILL
d, g, pid, hung = run_unit("termkill", "_u_term_kill", "")
seq = killcalls(d, pid) if pid else []
if hung:
    bad("② TERM 无效后升级 KILL: 驱动挂死了, 这一格没测到东西")
elif g.get("rc") == "0" and g.get("alive") == "0" and seq[:2] == ["TERM", "KILL"]:
    ok("② TERM 无效 → KILL 才停 → 返回 0, 调用记录 %s" % ",".join(seq))
else:
    bad("② TERM 无效后升级 KILL: rc=%s alive=%s 调用记录=%s" % (g.get("rc"), g.get("alive"), ",".join(seq) or "空"))

# ③ 停不掉: 必须有界返回失败
d, g, pid, hung = run_unit("unstop", "_u_unstoppable", "", limit=45)
seq = killcalls(d, pid) if pid else []
armed = os.path.exists(os.path.join(d, "armed"))
if not armed or seq[:2] != ["TERM", "KILL"]:
    bad("③ 停止失败: 注入没生效(布防=%s 调用记录=%s), 这一格没测到东西" % (armed, ",".join(seq) or "空"))
elif hung:
    bad("③ 停止失败仍存活: 调用记录已走完 %s, 停止预算(3s+2s)之后仍未返回 —— 无条件 wait 卡死, "
        "调用方永远拿不到失败, 会话锁一直被占" % ",".join(seq))
elif g.get("rc") == "0":
    bad("③ 停止失败仍存活: 返回了 0(alive=%s) —— 把停不掉报成停掉了" % g.get("alive"))
elif g.get("alive") != "1":
    bad("③ 停止失败仍存活: 进程没保住(alive=%s), 夹具没构造出目标场景" % g.get("alive"))
else:
    ok("③ TERM/KILL 都无效 → 有界返回 rc=%s, 进程仍在(现场保留), 调用记录 %s"
       % (g.get("rc"), ",".join(seq)))

# ④ 状态读不到
d, g, pid, hung = run_unit("unread", "_u_unreadable", "")
if hung:
    bad("④ 状态读取失败: 驱动挂死了, 这一格没测到东西")
elif g.get("catlog") != "1" or g.get("alive") != "1":
    bad("④ 状态读取失败: 注入没生效(catlog=%s alive=%s), 这一格没测到东西"
        % (g.get("catlog"), g.get("alive")))
elif g.get("rc") == "0":
    bad("④ 进程仍在、/proc/<pid>/stat 读不到 → _ios_offer_proc_dead 返回 0, "
        "把\"读不到\"判成\"已退出\"; 调用方据此 wait/删目录")
else:
    ok("④ 进程仍在但状态读不到 → 不判为已退出(rc=%s)" % g.get("rc"))

# ⑤ 与④的对照: 真的消失
d, g, pid, hung = run_unit("gone", "_u_reallygone", "")
if hung:
    bad("⑤ 进程真的消失: 驱动挂死了, 这一格没测到东西")
elif g.get("alive") != "0":
    bad("⑤ 进程真的消失: 夹具没让它消失(alive=%s)" % g.get("alive"))
elif g.get("rc") == "0":
    ok("⑤ 对照: /proc 不在(读失败注入仍布防着) → 判为已退出(rc=0), 与④可区分")
else:
    bad("⑤ 进程真的消失却没判成已退出(rc=%s) —— 把④做过头了" % g.get("rc"))

# ⑥ 僵尸上的判据
d, g, pid, hung = run_unit("zombie", "_u_zombie_pred", "")
if hung:
    bad("⑥ 僵尸判据: 驱动挂死了, 这一格没测到东西")
elif g.get("zombie") != "1":
    bad("⑥ 僵尸判据: 夹具没造出僵尸(zpid=%s zombie=%s), 这一格没测到东西"
        % (g.get("zpid"), g.get("zombie")))
elif g.get("held") != "1":
    bad("⑥ 僵尸判据: 观测期间僵尸被回收走了(held=0), 夹具没保持住, 这一格没测到东西")
elif g.get("kill0") != "1":
    bad("⑥ 僵尸判据: kill -0 在这个僵尸上竟然失败, 夹具前提不成立")
elif g.get("dead") == "0":
    ok("⑥ 僵尸(kill -0 仍成功) → 判为已退出, 不会被当成还活着")
else:
    bad("⑥ 僵尸没被判成已退出(dead=%s) —— kill -0 能过, 只看它会一直等下去" % g.get("dead"))

# ⑦ 已退出待回收的直接子进程
d, g, pid, hung = run_unit("exited", "_u_exited_child", "")
if hung:
    bad("⑦ 已退出待回收: 驱动挂死了, 这一格没测到东西")
elif g.get("dead") == "0" and g.get("rc") == "0" and g.get("alive") == "0" and g.get("jobs") == "0":
    ok("⑦ 已退出的直接子进程 → 判为已退出, wait 回收成功(rc=0), 无残留作业")
else:
    bad("⑦ 已退出待回收: dead=%s rc=%s alive=%s 残留作业=%s"
        % (g.get("dead"), g.get("rc"), g.get("alive"), g.get("jobs")))

print("### 二、收尾整体(端到端) ###")


def run_e2e(tag, swallow_gen, stat_fail, limit=60):
    d, env = mkcase(tag, fn="cmd_ios", PDG_TEST_BARRIER="gen", CH_STDIN_HOLD=60)
    p = launch(d, env)
    started = wait_for(lambda: os.path.exists(os.path.join(d, "gen-started")), 40)
    gp = None
    if started:
        wait_for(lambda: read(os.path.join(d, "genpid")).strip().isdigit(), 10)
        t = read(os.path.join(d, "genpid")).strip()
        gp = int(t) if t.isdigit() else None
    if gp:
        if swallow_gen:
            with open(os.path.join(d, "swallow"), "w", encoding="utf-8") as f:
                f.write("%d\n" % gp)
        if stat_fail:
            with open(os.path.join(d, "target"), "w", encoding="utf-8") as f:
                f.write("%d\n" % gp)
            open(os.path.join(d, "stat-fail"), "w").close()
    hung = False
    if gp:
        os.kill(p.pid, 15)
    try:
        p.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        hung = True
        reap_tree(p.pid)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    time.sleep(0.4)
    root = os.path.join(d, "offerroot")
    dirs = sorted(os.listdir(root)) if os.path.isdir(root) else []
    info = {
        "dir": d, "out": read(os.path.join(d, "out")), "status": p.returncode,
        "gp": gp, "started": started, "hung": hung, "dirs": dirs,
        "state": os.path.exists(os.path.join(d, "st", "offer.state")),
        "chain": read(os.path.join(d, "chain")),
        "srvpids": [int(x) for x in read(os.path.join(d, "srvpid")).split() if x.isdigit()],
        "gen_alive": bool(gp) and alive(gp),
        "port": connectable(0.5),
    }
    info["sentinel"] = any(
        os.path.exists(os.path.join(root, x, ".pdg-offer-session")) for x in dirs)
    return info


def cleanup_e2e(info):
    """断言之后才释放故障并手工清理。"""
    d = info["dir"]
    for f in ("swallow", "stat-fail"):
        try:
            os.remove(os.path.join(d, f))
        except OSError:
            pass
    for p in ([info["gp"]] if info["gp"] else []) + info["srvpids"]:
        if p and alive(p):
            reap_tree(p)
    open(os.path.join(d, "gen-release"), "w").close()
    time.sleep(0.3)


# ⑧ 生成器停不掉 → 保留现场、其余收尾照做、有界退出
i = run_e2e("e2e-unstop", swallow_gen=True, stat_fail=False)
seq = killcalls(i["dir"], i["gp"]) if i["gp"] else []
if not i["started"] or not i["gp"]:
    bad("⑧ 生成器停不掉: 夹具没跑起来(生成器未登记), 这一格没测到东西")
elif seq[:2] != ["TERM", "KILL"]:
    bad("⑧ 生成器停不掉: 收尾没走完停止预算(调用记录=%s), 这一格没测到东西" % (",".join(seq) or "空"))
elif i["hung"]:
    bad("⑧ 生成器停不掉: 收尾对 pid %s 已 TERM→KILL(%s), 之后进程一直没退出 —— "
        "无条件 wait 把收尾卡死, 锁与目录都收不回来" % (i["gp"], ",".join(seq)))
else:
    prob = []
    if i["status"] != 143:
        prob.append("退出码 %s(应 143)" % i["status"])
    if not i["dirs"] or not i["sentinel"]:
        prob.append("会话目录/凭据没保留(dirs=%s sentinel=%s)" % (i["dirs"], i["sentinel"]))
    if not i["state"]:
        prob.append("运行期所有权记录被删了")
    if "停不掉" not in i["out"]:
        prob.append("没有具名报出停止失败")
    if i["port"]:
        prob.append("8443 仍可连")
    if any(alive(p) for p in i["srvpids"]):
        prob.append("HTTP 进程仍在")
    if "pdg-ios-offer" in i["chain"]:
        prob.append("nft 放行没撤")
    if not i["gen_alive"]:
        prob.append("生成器其实已经死了, 夹具没构造出目标场景")
    if prob:
        bad("⑧ 生成器停不掉: " + "; ".join(prob))
    else:
        ok("⑧ 生成器停不掉 → 退出码 143, 保留目录+凭据+state 并具名报出, "
           "HTTP/端口/nft 都已收干净, 调用记录 %s" % ",".join(seq))
cleanup_e2e(i)

# ⑨ 生成器状态读不到 → 身份无法确认, 同样保留现场
i = run_e2e("e2e-unread", swallow_gen=True, stat_fail=True)
if not i["started"] or not i["gp"]:
    bad("⑨ 生成器状态读不到: 夹具没跑起来, 这一格没测到东西")
elif not os.path.exists(os.path.join(i["dir"], "catlog")):
    bad("⑨ 生成器状态读不到: 读失败注入没被触发, 这一格没测到东西")
elif i["hung"]:
    bad("⑨ 生成器状态读不到: 收尾卡死")
else:
    prob = []
    if i["status"] != 143:
        prob.append("退出码 %s(应 143)" % i["status"])
    if not i["dirs"] or not i["sentinel"]:
        prob.append("会话目录/凭据没保留(dirs=%s)" % i["dirs"])
    if not i["state"]:
        prob.append("运行期所有权记录被删了")
    if not i["gen_alive"]:
        prob.append("生成器其实已经死了, 夹具没构造出目标场景")
    if "pdg-ios-offer" in i["chain"]:
        prob.append("nft 放行没撤")
    if prob:
        bad("⑨ 生成器状态读不到: " + "; ".join(prob))
    else:
        ok("⑨ 生成器仍在但状态读不到 → 不当成已退出, 保留目录+凭据+state, "
           "nft 与端口照常收干净, 退出码 143")
cleanup_e2e(i)

# ⑩ 成功路径不得回退
i = run_e2e("e2e-ok", swallow_gen=False, stat_fail=False)
if not i["started"] or not i["gp"]:
    bad("⑩ 正常停止路径: 夹具没跑起来, 这一格没测到东西")
elif i["hung"]:
    bad("⑩ 正常停止路径: 收尾卡死")
else:
    prob = []
    if i["status"] != 143:
        prob.append("退出码 %s(应 143)" % i["status"])
    if i["dirs"]:
        prob.append("会话目录没删干净: %s" % i["dirs"])
    if i["state"]:
        prob.append("运行期所有权记录没删")
    if i["gen_alive"]:
        prob.append("生成器没停住")
    if "停不掉" in i["out"] or "无法确认" in i["out"]:
        prob.append("正常路径报了停止失败")
    if "pdg-ios-offer" in i["chain"]:
        prob.append("nft 放行没撤")
    if prob:
        bad("⑩ 正常停止路径(不得回退): " + "; ".join(prob))
    else:
        ok("⑩ 生成器能停住时照旧: 停住、删目录、删 state、退出码 143, 不报失败")
cleanup_e2e(i)

print("-" * 62)
print("%s: 通过 %d, 失败 %d" % (os.path.basename(__file__), PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

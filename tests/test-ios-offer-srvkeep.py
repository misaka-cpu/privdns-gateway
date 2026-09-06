#!/usr/bin/env python3
"""iOS 临时下载通道: **HTTP 停不掉时也要保住恢复线索** —— 行为验证。

生成者那一侧已经会保留现场了(`gen_unsafe`): 停不住就不删目录、不删运行期记录, 把线索
留给下一次会话。HTTP 这一侧没有 —— 收尾里它只把 `rc=1` 记上, 随后照样

    rm -rf 会话目录   → 连同 .pdg-offer-pid(pid+starttime)一起没了
    rm -f  运行期记录 → 连同 pid/start/www 一起没了

于是端口还开着、服务还在发同一份描述文件, 而**下一次会话再也定位不到它**: 根目录扫不到
目录, 记录也不在, `_ios_offer_reap_orphan` 一路返回 0 —— "回收成功", 实际上什么也没收。

这一支用**真的产品 HTTP handler**(`IOS_OFFER_SERVER` 原文)验: 只绑回环、端口由测试选一个
空闲的随机口, 发的是本测试自己造的隔离文件; pid/starttime 凭据由服务进程自己写进会话目录,
cwd 就是那个目录 —— 归属判据(`_ios_offer_proc_state … "$dir"`)用的正是这三样。

**防火墙是夹具。** nft 用桩, 所以这里只能证明"收尾确实按本轮 handle 发起了精确删除、并复核
到链上不再有标记", **不能**据此声称真实规则已撤除, 也不能声称公网不可达 —— 那要在真机上验。

注入点全在测试这一侧: `kill` 用 shell 函数覆盖(函数优先于同名 builtin), 逐次记账、名单里的
"信号:pid" 只记账不投递; `/proc/<pid>/stat` 读失败用 PATH 上的 `cat` 桩注入。断言之前不人工
停旧 HTTP、不清目录、不重建凭据; 超时只用于兜底清场, 不作为判定依据。
"""
import os, re, socket, subprocess, sys, time
from pathlib import Path
import tmpguard

ROOT = Path(__file__).resolve().parents[1]
PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   " + m)
def bad(m): FAIL[0] += 1; print("[FAIL] " + m)

PAYLOAD = (b'<?xml version="1.0"?><plist version="1.0"><dict>'
           b'<key>pdg-srvkeep-isolated-payload</key><string>'
           + b"0123456789abcdef" * 8 + b'</string></dict></plist>\n')

NFT_STUB = r'''#!/bin/bash
st="$PDG_TEST_CHAIN"
if [ ! -s "$st" ]; then printf '1|iif "lo" accept\n4|iifname "tailscale0" return\n' > "$st"; fi
echo "nft $*" >> "$PDG_TEST_LOG"
case "$1" in
  -a) echo "table inet pdg {"; echo "	chain input {"
      while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$st"
      echo "	}"; echo "}" ;;
  delete) shift $(($# - 1)); grep -v "^$1|" "$st" > "$st.n" 2>/dev/null; mv "$st.n" "$st" ;;
esac
exit 0
'''

# /proc/<pid>/stat 读失败注入: 只对 $CH_DIR/target 里那个 pid、只在 $CH_DIR/stat-fail 布防后失败。
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

HARNESS = r'''
set -uo pipefail
cd "$CH_ROOT"
echo $$ > "$CH_DIR/pid"
: > "$CH_DIR/fn.sh"
for fn in _ios_offer_teardown _ios_offer_nft_close _ios_offer_chain _ios_offer_marks \
          _ios_offer_lock_acquire _ios_offer_lock_release _ios_offer_on_signal \
          _ios_offer_srv_alive _ios_offer_reap_orphan _ios_offer_starttime \
          _ios_offer_state_write _ios_offer_dir_ok _ios_offer_root_ok _ios_offer_reap_dir \
          _ios_offer_dir_pid _ios_offer_proc_state _ios_offer_stop_pid _ios_offer_list \
          _ios_offer_stop_child _ios_offer_proc_dead; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE|IOS_OFFER_GENFILE)=' \
  deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
for v in IOS_OFFER_SERVER; do
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
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
# shellcheck source=/dev/null
. "$CH_DIR/fn.sh"

# ── 注入: 记账并可吞掉投递的 kill(名单格式 "信号:pid", 一行一条) ─────────────
kill(){
  local a last="" sig="TERM"
  case "${1-}" in -*) sig="${1#-}" ;; esac
  for a in "$@"; do last="$a"; done
  printf '%s\n' "$*" >> "$CH_DIR/killlog"
  if [ -r "$CH_DIR/swallow" ] && grep -qx "$sig:$last" "$CH_DIR/swallow" 2>/dev/null; then
    return 0
  fi
  builtin kill "$@"
}

# ── 造一个真的现场: 真 handler + 真凭据 + 真运行期记录 + 会话锁 ───────────────
SID=""; WWW=""; TOK=""
_scene(){
  SID="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  TOK="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  mkdir -p "$IOS_OFFER_ROOT" && chmod 0700 "$IOS_OFFER_ROOT" || return 1
  WWW="$IOS_OFFER_ROOT/s.$SID"
  mkdir "$WWW" && chmod 0700 "$WWW" || return 1
  (umask 077 && printf '%s\n' "$SID" > "$WWW/$IOS_OFFER_SENTINEL") || return 1
  cp "$CH_DIR/payload" "$WWW/$TOK.mobileconfig" && chmod 0644 "$WWW/$TOK.mobileconfig" || return 1
  _ios_offer_lock_acquire || return 1
  # 子 shell 里 cd 进会话目录再 exec, 于是 $! 就是持有端口的那个进程, 它的 cwd 正是会话
  # 目录 —— 归属判据(_ios_offer_proc_state … "$dir")要看的就是这个。
  # 与产品调用点逐字同形, 包括 6>&-: 子进程不许继承会话锁, 否则它活着就攥着锁。
  ( cd "$WWW" && exec python3 -c "$IOS_OFFER_SERVER" \
      "$CH_PORT" "/$TOK.mobileconfig" "$WWW/$TOK.mobileconfig" 127.0.0.1 \
      "$WWW/$IOS_OFFER_PIDFILE" >/dev/null 2>&1 ) 6>&- &
  _IOS_OFFER_SRV=$!
  local n=0
  while [ "$n" -lt 200 ] && [ ! -s "$WWW/$IOS_OFFER_PIDFILE" ]; do sleep 0.05; n=$((n+1)); done
  [ -s "$WWW/$IOS_OFFER_PIDFILE" ] || { echo "U:scene=0"; return 1; }
  local start; start="$(_ios_offer_starttime "$_IOS_OFFER_SRV")"
  _ios_offer_state_write serving "$SID" "$_IOS_OFFER_SRV" "$start" "$WWW" || { echo "U:scene=0"; return 1; }
  printf '9|tcp dport %s accept comment "%s"\n' "$CH_PORT" "$IOS_OFFER_MARK" >> "$PDG_TEST_CHAIN"
  _IOS_OFFER_HANDLE=9
  _IOS_OFFER_WWW="$WWW"; _IOS_OFFER_SID="$SID"; _IOS_OFFER_ACTIVE=1
  echo "U:scene=1"; echo "U:srv=$_IOS_OFFER_SRV"; echo "U:www=$WWW"; echo "U:sid=$SID"
  echo "U:tok=$TOK"
  echo "$_IOS_OFFER_SRV" > "$CH_DIR/srvpid"
  return 0
}
_swallow(){ printf '%s\n' "$@" > "$CH_DIR/swallow"; }
_obs(){   # 现场观测: 目录/凭据/sentinel/state 还在不在
  echo "U:dir=$( [ -d "$WWW" ] && echo 1 || echo 0 )"
  echo "U:pidfile=$( [ -s "$WWW/$IOS_OFFER_PIDFILE" ] && echo 1 || echo 0 )"
  echo "U:sentinel=$( [ -s "$WWW/$IOS_OFFER_SENTINEL" ] && echo 1 || echo 0 )"
  echo "U:state=$( [ -s "$IOS_OFFER_STATE" ] && echo 1 || echo 0 )"
  echo "U:srvalive=$( [ -d "/proc/$(cat "$CH_DIR/srvpid")" ] && echo 1 || echo 0 )"
  echo "U:lockheld=$( [ -e "/proc/$$/fd/6" ] && echo 1 || echo 0 )"
  echo "U:marks=$(grep -c "$IOS_OFFER_MARK" "$PDG_TEST_CHAIN" 2>/dev/null || echo 0)"
}

# ① TERM 就能停 —— 正常路径, 资源应清净
_c_term_exit(){ _scene || return 1; _ios_offer_teardown; echo "U:rc=$?"; _obs; }
# ② TERM 无效、KILL 后退出 —— 仍是成功路径
_c_term_kill(){ _scene || return 1; _swallow "TERM:$_IOS_OFFER_SRV"; _ios_offer_teardown; echo "U:rc=$?"; _obs; }
# ③ 停止预算耗尽仍存活 —— 必须保住现场
_c_unstoppable(){
  _scene || return 1
  _swallow "TERM:$_IOS_OFFER_SRV" "KILL:$_IOS_OFFER_SRV"
  _ios_offer_teardown; echo "U:rc=$?"; _obs
}
# ④ 停不掉且状态不可读 —— 同样必须保住现场
_c_unreadable(){
  _scene || return 1
  _swallow "TERM:$_IOS_OFFER_SRV" "KILL:$_IOS_OFFER_SRV"
  echo "$_IOS_OFFER_SRV" > "$CH_DIR/target"; : > "$CH_DIR/stat-fail"
  _ios_offer_teardown; echo "U:rc=$?"; _obs
  echo "U:catlog=$( [ -s "$CH_DIR/catlog" ] && echo 1 || echo 0 )"
}
# ⑤ 首次失败保留现场 → 故障解除 → 后继凭原有记录精确回收
_c_recover(){
  _scene || return 1
  _swallow "TERM:$_IOS_OFFER_SRV" "KILL:$_IOS_OFFER_SRV"
  _ios_offer_teardown; echo "U:rc=$?"; _obs
  # —— 观测已经落盘, 现在才解除注入。不人工停旧 HTTP、不动目录、不重建凭据。
  rm -f "$CH_DIR/swallow"
  echo "U:released=1"
  _ios_offer_lock_acquire || { echo "U:relock=0"; return 1; }
  echo "U:relock=1"
  _ios_offer_reap_orphan; echo "U:reap=$?"
  echo "U:dir2=$( [ -d "$WWW" ] && echo 1 || echo 0 )"
  echo "U:state2=$( [ -s "$IOS_OFFER_STATE" ] && echo 1 || echo 0 )"
  echo "U:srvalive2=$( [ -d "/proc/$(cat "$CH_DIR/srvpid")" ] && echo 1 || echo 0 )"
  _ios_offer_lock_release
}
# ⑥ 生成者的保留条件不得被削弱: 生成者停不掉、HTTP 正常, 现场照样要留住
_c_gen_only(){
  _scene || return 1
  ( exec 6>&-; trap "" TERM; while :; do sleep 0.2; done ) &
  _IOS_OFFER_GEN=$!
  (umask 077 && printf 'pid=%s\nstart=%s\n' "$_IOS_OFFER_GEN" "$(_ios_offer_starttime "$_IOS_OFFER_GEN")" \
     > "$WWW/$IOS_OFFER_GENFILE")
  echo "U:gen=$_IOS_OFFER_GEN"; echo "$_IOS_OFFER_GEN" > "$CH_DIR/genpid"
  _swallow "TERM:$_IOS_OFFER_GEN" "KILL:$_IOS_OFFER_GEN"
  _ios_offer_teardown; echo "U:rc=$?"; _obs
}
# ⑦ 信号路径: 首次 TERM 仍是 143, 且报告收尾未完成, 现场保留
_c_signal(){
  _scene || return 1
  _swallow "TERM:$_IOS_OFFER_SRV" "KILL:$_IOS_OFFER_SRV"
  trap '_ios_offer_teardown' EXIT
  trap '_ios_offer_on_signal TERM 15' TERM
  : > "$CH_DIR/armed"
  local n=0
  while [ "$n" -lt 600 ]; do sleep 0.1; n=$((n+1)); done
}

"$CH_FN"
rc=$?
echo "RC=$rc"
echo "REACHED-END"
'''


def mkcase(tag, fn, port, **extra):
    d = tmpguard.mkdtemp(prefix="iossk-%s-" % tag)
    b = os.path.join(d, "bin"); os.makedirs(b); os.makedirs(os.path.join(d, "st"))
    with open(os.path.join(d, "payload"), "wb") as f:
        f.write(PAYLOAD)
    for name, s in (("nft", NFT_STUB), ("cat", CAT_STUB), ("qrencode", "#!/bin/sh\nexit 0\n")):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(s)
        os.chmod(p, 0o755)
    env = dict(os.environ, PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_CHAIN=os.path.join(d, "chain"),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "st", "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d, CH_DIR=d, CH_ROOT=str(ROOT), CH_FN=fn, CH_PORT=str(port))
    env.update({k: str(v) for k, v in extra.items()})
    return d, env


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]; s.close(); return p


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
    """兜底清场: 逐个精确 pid SIGKILL, 不用宽模式匹配。"""
    kids = children_of(pid)
    for p in [pid] + kids:
        try:
            os.kill(p, 9)
        except OSError:
            pass


def marks(d):
    got = {}
    for m in re.finditer(r"^U:([a-z0-9_]+)=(.*)$", read(os.path.join(d, "out")), re.M):
        got[m.group(1)] = m.group(2).strip()
    return got


def fetch(port, path, timeout=2.0):
    """裸 socket 说 HTTP/1.0 —— 结构上没有代理和重定向可言。"""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except OSError as e:
        return None, str(e)
    try:
        s.sendall(("GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" % path).encode())
        buf = b""
        while len(buf) < 1 << 20:
            c = s.recv(65536)
            if not c:
                break
            buf += c
    except OSError as e:
        return None, str(e)
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    return (head.split(b"\r\n")[0].decode("latin1"), body)


def killcalls(d, pid):
    seq = []
    for line in read(os.path.join(d, "killlog")).splitlines():
        f = line.split()
        if not f or f[-1] != str(pid):
            continue
        seq.append(f[0][1:] if len(f) > 1 and f[0].startswith("-") else "TERM")
    return seq


def run_case(tag, fn, limit=90, signal_after=None):
    port = free_port()
    d, env = mkcase(tag, fn, port)
    p = launch(d, env)
    hung = False
    if signal_after:
        end = time.time() + 60
        while time.time() < end and not os.path.exists(os.path.join(d, "armed")):
            time.sleep(0.05)
        time.sleep(0.3)
        try:
            os.kill(p.pid, signal_after)
        except OSError:
            pass
    try:
        p.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        hung = True
        reap_tree(p.pid)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
    time.sleep(0.3)
    g = marks(d)
    return {"dir": d, "g": g, "port": port, "out": read(os.path.join(d, "out")),
            "status": p.returncode, "hung": hung,
            "srv": int(g["srv"]) if g.get("srv", "").isdigit() else None,
            "gen": int(g["gen"]) if g.get("gen", "").isdigit() else None}


def cleanup(r):
    """断言之后才兜底清场。"""
    try:
        os.remove(os.path.join(r["dir"], "swallow"))
    except OSError:
        pass
    for p in (r["srv"], r["gen"]):
        if p and alive(p):
            reap_tree(p)


def scene_ok(r, cell):
    if r["g"].get("scene") != "1":
        bad("%s: 现场没搭起来(真 handler 未登记凭据), 这一格没测到东西" % cell); return False
    return True


print("### 一、HTTP 能停住时(不得回退) ###")

# ① TERM 就能停
r = run_case("termexit", "_c_term_exit")
g = r["g"]
if scene_ok(r, "①"):
    seq = killcalls(r["dir"], r["srv"])
    prob = []
    if g.get("rc") != "0": prob.append("teardown rc=%s(应 0)" % g.get("rc"))
    if g.get("dir") != "0": prob.append("会话目录没删")
    if g.get("state") != "0": prob.append("运行期记录没删")
    if g.get("srvalive") != "0": prob.append("服务没退出")
    if g.get("marks") != "0": prob.append("nft 标记还剩 %s 条" % g.get("marks"))
    if g.get("lockheld") != "0": prob.append("会话锁没释放")
    if "KILL" in seq: prob.append("对能停的服务也升级到了 KILL")
    if prob: bad("① TERM 即停: " + "; ".join(prob))
    else: ok("① TERM 即停 → rc=0, 目录/记录/服务/放行/锁全清, 调用记录 %s" % ",".join(seq))
cleanup(r)

# ② TERM 无效、KILL 后退出
r = run_case("termkill", "_c_term_kill")
g = r["g"]
if scene_ok(r, "②"):
    seq = killcalls(r["dir"], r["srv"])
    prob = []
    if seq[:2] != ["TERM", "KILL"]: prob.append("调用记录=%s(应 TERM 再 KILL)" % (",".join(seq) or "空"))
    if g.get("rc") != "0": prob.append("teardown rc=%s(应 0)" % g.get("rc"))
    if g.get("dir") != "0": prob.append("会话目录没删")
    if g.get("state") != "0": prob.append("运行期记录没删")
    if g.get("srvalive") != "0": prob.append("服务没退出")
    if prob: bad("② TERM 无效后升级 KILL: " + "; ".join(prob))
    else: ok("② TERM 无效 → KILL 才停 → rc=0, 资源仍清净, 调用记录 %s" % ",".join(seq))
cleanup(r)


print("### 二、HTTP 停不掉时(本轮缺陷) ###")

def keep_checks(g, r, cell, want_serving=True):
    prob = []
    if g.get("rc") == "0": prob.append("teardown 返回 0(把停不掉报成停掉了)")
    if g.get("dir") != "1": prob.append("会话目录被删了 —— 后继再也定位不到旧服务")
    if g.get("pidfile") != "1": prob.append("pid/starttime 凭据被删了")
    if g.get("sentinel") != "1": prob.append("sentinel 被删了")
    if g.get("state") != "1": prob.append("运行期所有权记录被删了")
    if g.get("srvalive") != "1": prob.append("服务其实已经死了, 夹具没构造出目标场景")
    if g.get("lockheld") != "0": prob.append("会话锁没释放")
    if "已关闭临时下载服务" in r["out"]: prob.append("打印了「已关闭临时下载服务」")
    if "临时 HTTP 进程没能退出" not in r["out"]: prob.append("没有具名报出 HTTP 停止失败")
    if g.get("marks") != "0": prob.append("没有按 handle 精确撤除临时放行(链上仍有 %s 条标记)" % g.get("marks"))
    if want_serving:
        line, body = fetch(r["port"], "/%s.mobileconfig" % g.get("tok", ""))
        if line is None or "200" not in line or body != PAYLOAD:
            prob.append("旧服务没在发同一份文件(状态行=%r 长度=%s)"
                        % (line, len(body) if isinstance(body, bytes) else body))
    return prob

# ③ 停止预算耗尽仍存活
r = run_case("unstop", "_c_unstoppable")
g = r["g"]
if scene_ok(r, "③"):
    seq = killcalls(r["dir"], r["srv"])
    if seq[:2] != ["TERM", "KILL"]:
        bad("③ 停不掉: 注入没生效(调用记录=%s), 这一格没测到东西" % (",".join(seq) or "空"))
    elif r["hung"]:
        bad("③ 停不掉: 收尾卡死, 没有有界返回")
    else:
        prob = keep_checks(g, r, "③")
        if prob: bad("③ HTTP 停不掉却没保住现场: " + "; ".join(prob))
        else: ok("③ HTTP 停不掉 → rc=%s, 目录/pid 凭据/sentinel/state 全保留, 旧服务仍在发同一份文件, "
                 "放行已按 handle 撤除, 锁已释放" % g.get("rc"))
cleanup(r)

# ④ 停不掉且状态不可读
r = run_case("unread", "_c_unreadable")
g = r["g"]
if scene_ok(r, "④"):
    if g.get("catlog") != "1":
        bad("④ 状态不可读: 读失败注入没被触发, 这一格没测到东西")
    elif r["hung"]:
        bad("④ 状态不可读: 收尾卡死")
    else:
        prob = keep_checks(g, r, "④")
        if prob: bad("④ HTTP 停不掉且状态不可读却没保住现场: " + "; ".join(prob))
        else: ok("④ HTTP 停不掉且 /proc/<pid>/stat 读不到 → rc=%s, 现场全保留, 旧服务仍在发同一份文件"
                 % g.get("rc"))
cleanup(r)


print("### 三、保留现场 → 故障解除 → 后继回收 ###")

# ⑤ 第一步: 首次失败必须保留现场
r = run_case("recover", "_c_recover", limit=180)
g = r["g"]
if scene_ok(r, "⑤"):
    prob = keep_checks(g, r, "⑤", want_serving=False)
    if prob: bad("⑤ 首次失败保留现场: " + "; ".join(prob))
    else: ok("⑤ 首次失败 → 目录/pid 凭据/sentinel/state 全保留, 锁已释放, 放行已撤")

    # ⑥ 第二步: 解除注入之后, 后继必须凭保留下来的记录真的把旧服务收掉
    if g.get("released") != "1" or g.get("relock") != "1":
        bad("⑥ 后继回收: 故障解除/重新取锁没走到(released=%s relock=%s)"
            % (g.get("released"), g.get("relock")))
    else:
        p2 = []
        if g.get("srvalive2") != "0":
            p2.append("旧服务没被停掉(回收返回 %s)" % g.get("reap"))
        if g.get("reap") != "0": p2.append("回收返回 %s(应 0)" % g.get("reap"))
        if g.get("dir2") != "0": p2.append("会话目录没清")
        if g.get("state2") != "0": p2.append("运行期记录没清")
        if "回收了上一轮留下的临时下载服务" not in r["out"]:
            p2.append("没有具名报出回收了旧服务 —— 记录已丢, 回收无从下手")
        if p2: bad("⑥ 故障解除后后继回收: " + "; ".join(p2))
        else: ok("⑥ 解除注入后, 后继凭 pid/starttime/cwd 与目录归属精确停掉旧服务并清场(reap=0)")
cleanup(r)


print("### 四、两侧保留条件互不削弱 / 信号路径 ###")

# ⑦ 生成者停不掉、HTTP 正常
r = run_case("genonly", "_c_gen_only")
g = r["g"]
if scene_ok(r, "⑦"):
    seq = killcalls(r["dir"], r["gen"]) if r["gen"] else []
    if seq[:2] != ["TERM", "KILL"]:
        bad("⑦ 生成者停不掉: 注入没生效(调用记录=%s), 这一格没测到东西" % (",".join(seq) or "空"))
    else:
        prob = []
        if g.get("rc") == "0": prob.append("teardown 返回 0")
        if g.get("dir") != "1": prob.append("会话目录被删了")
        if g.get("state") != "1": prob.append("运行期记录被删了")
        if g.get("srvalive") != "0": prob.append("HTTP 没停住(这一格 HTTP 是正常的)")
        if "描述文件生成器停不掉" not in r["out"]: prob.append("没有具名报出生成者停止失败")
        if prob: bad("⑦ 生成者停不掉(HTTP 正常): " + "; ".join(prob))
        else: ok("⑦ 生成者停不掉、HTTP 正常停住 → 现场照样保留, 生成者一侧的保护没被削弱")
cleanup(r)

# ⑧ 信号路径
r = run_case("signal", "_c_signal", limit=120, signal_after=15)
g = r["g"]
if scene_ok(r, "⑧"):
    if r["hung"]:
        bad("⑧ 信号路径: 收尾卡死")
    else:
        prob = []
        if r["status"] != -15 and r["status"] != 143:
            prob.append("退出状态 %s(应 143/-15)" % r["status"])
        if "收尾未完成" not in r["out"]: prob.append("没有报告收尾未完成")
        if "已关闭临时下载服务" in r["out"]: prob.append("打印了「已关闭临时下载服务」")
        if not os.path.isdir(g.get("www", "/nonexistent")): prob.append("会话目录被删了")
        if not os.path.exists(os.path.join(r["dir"], "st", "offer.state")):
            prob.append("运行期记录被删了")
        if r["srv"] and not alive(r["srv"]): prob.append("服务其实已经死了, 夹具没构造出目标场景")
        if prob: bad("⑧ SIGTERM 路径: " + "; ".join(prob))
        else: ok("⑧ 首次 SIGTERM → 退出状态 143, 报告收尾未完成, 现场保留")
cleanup(r)

print("-" * 62)
print("%s: 通过 %d, 失败 %d" % (os.path.basename(__file__), PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

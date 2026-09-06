#!/usr/bin/env python3
"""iOS 临时下载通道: **存活的生成者 / 回收身份判定 / 枚举失败** —— 行为验证。

上一轮把"目录已建、记录尚无"那段真空补上了。这一支盯剩下的三处:

  A. **生成子进程可能活得比回收更久。** 父 shell 持锁启动生成器, 子进程不继承 fd6; 父被强杀
     之后, 后继会话删掉会话目录并**报成功**, 而旧生成器随后才落笔 —— atomic_write 连父目录
     一起重建, 于是盘上多出一个**没有 sentinel** 的目录, 下一次会话据此拒绝启动。
     "关掉锁 fd" 只解决了锁, 没解决"还有人在往那个目录写"。
  B. **把"没认出来"当成"已经退出"。** `_ios_offer_dir_pid` 对记录损坏、读不出、PID 不存在、
     starttime 不符、cwd 不符统统 `return 1`; `_ios_offer_reap_dir` 只区分"认出来了"和
     "其它", 后者一律照删。单一非零状态推断不出"进程已退出"。
  C. **枚举失败被当成空集合。** 会话根目录扫描与目录内容扫描都是
     `find … 2>/dev/null` 灌进 while —— find 的退出码被丢掉, 循环跑完就当扫描成功。
     "不曾看到"不能当成"不存在", 尤其是在据此删东西的时候。

屏障用文件标记, 不用 sleep 猜时序; 断言之前不清场、不杀别人的进程。

A 组另有一条时序前提: **"生成者已启动"不等于"生成者身份已登记"**。`_ios_offer_gen_run`
先写 `pending`, fork 之后才取 starttime 回填 `pid=`/`start=`; 生成器一 exec 就能写下
gen-started, 那一刻凭据可能还是 pending。只等 gen-started 就发信号, 打中的往往是 pending
窗口 —— 后继按"身份尚不能确认"拒绝, 那是产品的安全契约, 不是这一组要测的东西。
所以 A 组改用**登记门**(pid= 与 start= 齐备、pid 等于夹具实际启动的生成器、start 与该进程
的真实 starttime 一致、进程仍存活且停在屏障上), 并用 PATH 上的 `cat` 桩给取 starttime
那一次读加**受控延迟**, 让这道门确定性地被考到。产品里不加任何注入开关。
A 组的语义不变: 旧生成器**仍然活着**, 后继必须先停住写入方再删目录 —— 不等它自己退出。
"""
import hashlib, os, re, signal, socket, subprocess, sys, time
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

# python3 桩。`gen` 屏障放在**实际写出之前**: 生成器先亮相并挂住, 醒来之后才落笔 —— 而且像
# atomic_write 那样连父目录一起重建。这正是复现出来的时序。
PY_STUB = r'''#!/bin/bash
real=/usr/bin/python3
if [ "${1:-}" = "$CH_DIR/iosstate.py" ]; then
  echo "iosstate $*" >> "$PDG_TEST_LOG"
  out=""; prev=""
  for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
  [ "$(dirname "$out")" = "/" ] && { echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1; }
  if [ "${PDG_TEST_BARRIER:-}" = gen ]; then
    echo "$$" > "$CH_DIR/genpid"
    : > "$CH_DIR/gen-started"
    # 等测试放行, **不用固定 sleep**: 负控里并发跑多套件时机器会变慢, 固定时长会漂 ——
    # 反向对照因此出现过一条"新增失败", 而那与被改的代码毫无关系。
    n=0
    while [ ! -e "$CH_DIR/gen-release" ] && [ "$n" -lt 900 ]; do sleep 0.1; n=$((n+1)); done
    mkdir -p "$(dirname "$out")"            # ← atomic_write 会把父目录一起建回来
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

# find 桩: 按被扫描的路径注入枚举失败。
FIND_STUB = r'''#!/bin/bash
# 被扫描的路径是**第一个**参数(`find <path> -mindepth 1 -maxdepth 1`)。取 $2 的话拿到的是
# `-mindepth`, 注入永远不生效 —— 那样 C 组三格会因为别的原因判红, 看起来像产品坏了。
tgt="${1:-}"
mode="${PDG_TEST_FIND_FAIL:-}"
case "$tgt" in
  */offerroot) which=root ;;
  */s.*)       which=dir ;;
  *)           which=other ;;
esac
case "$mode:$which" in
  root-none:root)    exit 1 ;;
  root-partial:root) /usr/bin/find "$@" 2>/dev/null | head -1; exit 1 ;;
  dir-none:dir)      exit 1 ;;
  dir-partial:dir)   /usr/bin/find "$@" 2>/dev/null | head -1; exit 1 ;;
esac
exec /usr/bin/find "$@"
'''

# 受控登记延迟: 延迟**本次会话第一次** /proc/<pid>/stat 读取。会话根目录是空的, 回收流程
# 一次 proc_state 也不会做, 所以那一次就是 _ios_offer_gen_run 里的
# `_ios_offer_starttime "$gpid"` —— 登记窗口的正中央。纯测试侧, 产品不动。
CAT_STUB = r'''#!/bin/bash
if [ -n "${PDG_TEST_REG_DELAY:-}" ] && [ ! -e "$CH_DIR/reg-delayed" ]; then
  case "${1:-}" in
    /proc/[0-9]*/stat)
      : > "$CH_DIR/reg-delayed"
      echo "${1}" >> "$CH_DIR/catlog"
      sleep "$PDG_TEST_REG_DELAY" ;;
  esac
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
          _ios_offer_proc_state _ios_offer_gen_run _ios_offer_list \
          _nft_apply_main _lan_nft_reapply \
          _ios_offer_proc_state _ios_offer_stop_pid _ios_offer_list _ios_offer_gen_run \
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
"$CH_FN" ${CH_ARG:+"$CH_ARG"} < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>reaper</key></dict></plist>\n'


def mkcase(tag, fn="cmd_ios", **extra):
    d = tmpguard.mkdtemp(prefix="iosrp-%s-" % tag)
    b = os.path.join(d, "bin"); os.makedirs(b); os.makedirs(os.path.join(d, "st"))
    for n, c in (("tmpl.mobileconfig", "<plist/>\n"), ("iosstate.py", "# stub\n")):
        with open(os.path.join(d, n), "w", encoding="utf-8") as f:
            f.write(c)
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB), ("find", FIND_STUB),
                    ("cat", CAT_STUB),
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


def finish(proc, d, limit=90):
    try:
        proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=10)
    time.sleep(0.2)
    out = read(os.path.join(d, "out"))
    m = re.search(r"^RC=(\d+)$", out, re.M)
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None,
            "log": read(os.path.join(d, "log")),
            "marks": read(os.path.join(d, "chain")).count('comment "pdg-ios-offer"')}


def wait_file(p, limit=30.0):
    end = time.time() + limit
    while time.time() < end:
        if os.path.exists(p):
            return True
        time.sleep(0.03)
    return False


def wait_for(fn, limit=30.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False


def connectable(t=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=t); s.close(); return True
    except OSError:
        return False


def sess_dirs(env):
    r = env["PDG_IOS_OFFER_ROOT"]
    return [os.path.join(r, n) for n in sorted(os.listdir(r))] if os.path.isdir(r) else []


def alive(p):
    return os.path.exists("/proc/%d" % p)


def starttime_of(pid):
    with open("/proc/%d/stat" % pid, "rb") as f:
        return f.read().rsplit(b") ", 1)[1].split()[19].decode()


def starttime_or_none(pid):
    try:
        return starttime_of(pid)
    except (OSError, IndexError):
        return None


def lock_free(env):
    import fcntl
    try:
        fh = open(env["PDG_IOS_OFFER_LOCKFILE"], "a")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN); fh.close(); return True
    except OSError:
        return False


def wait_registered(env, d, genpid, limit=30.0):
    """等到**本次会话的生成者身份确实登记完成**, 而不是等它"启动了"。

    缺一不可: 凭据 pid= 与 start= 同时齐备且可解析; pid 等于夹具实际启动的那个生成器;
    start 与该进程 /proc 里的真实 starttime 一致; 进程仍存活且停在本场景要求的屏障上。
    只匹配 pid= 是弱判据 —— 半截记录、旧会话遗留的凭据都能蒙混过去。
    返回 (是否满足, 最后一个未满足的具体条件)。
    """
    last = "会话目录还没出现"
    end = time.time() + limit
    while time.time() < end:
        dirs = sess_dirs(env)
        if len(dirs) != 1:
            last = "会话目录 %d 个(期望 1)" % len(dirs)
        elif not os.path.exists(os.path.join(d, "gen-started")):
            last = "生成器还没到达屏障(gen-started 未出现)"
        elif not alive(genpid):
            last = "生成器 %d 已经不在了" % genpid
        else:
            txt = read(os.path.join(dirs[0], ".pdg-offer-gen"))
            m_pid = re.search(r"^pid=(\d+)$", txt, re.M)
            m_st = re.search(r"^start=(\d+)$", txt, re.M)
            if not txt:
                last = "生成者凭据还没落盘"
            elif txt.strip() == "pending":
                last = "凭据仍是 pending(登记未完成)"
            elif not m_pid or not m_st:
                last = "凭据不完整(缺 pid= 或 start=): %r" % txt.strip().replace("\n", "|")[:60]
            elif int(m_pid.group(1)) != genpid:
                last = ("凭据里的 pid=%s 不是本次夹具启动的生成器 %d"
                        % (m_pid.group(1), genpid))
            elif starttime_or_none(genpid) != m_st.group(1):
                last = ("凭据 start=%s 与进程真实 starttime=%s 不符"
                        % (m_st.group(1), starttime_or_none(genpid)))
            else:
                return True, ""
        time.sleep(0.01)
    return False, last


def successor(env0, tag, fn="cmd_ios", **kw):
    d, e = mkcase(tag, fn=fn, CH_STDIN_HOLD=1, **kw)
    for k in ("PDG_TEST_CHAIN", "PDG_IOS_OFFER_LOCKFILE",
              "PDG_IOS_OFFER_STATEFILE", "PDG_IOS_OFFER_ROOT"):
        e[k] = env0[k]
    return finish(launch(d, e), d, limit=90), e


if connectable():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0])); sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)



# 登记门超时的两种成因必须分开: 凭据一直不完整/不一致, 说明**产品没有登记生成者身份**
# —— 那是契约失败, 要具名报红; 而目录没出现、生成器提前没了、没到屏障, 才是夹具问题。
# 混在一起写成"这一格没测到东西", 会把真的产品退化悄悄吞掉。
GATE_PRODUCT_REASONS = ("凭据仍是 pending", "凭据不完整", "生成者凭据还没落盘",
                        "不是本次夹具启动的生成器", "与进程真实 starttime")


def gate_is_product_fault(why_not):
    return any(k in why_not for k in GATE_PRODUCT_REASONS)

# ── A: 生成子进程活得比回收更久 ─────────────────────────────────────────
for fn, why in (("cmd_ios", "pdg ios"), ("cmd_ios_previous", "pdg ios previous")):
    d, env = mkcase("A-" + fn, fn=fn, CH_STDIN_HOLD=60,
                    PDG_TEST_BARRIER="gen", PDG_TEST_REG_DELAY=3)
    p = launch(d, env)
    if not wait_file(os.path.join(d, "gen-started")):
        bad("%s: 生成屏障没命中, 这一组没测到东西" % why)
        p.kill(); p.wait(timeout=10); continue
    wait_for(lambda: read(os.path.join(d, "genpid")).strip().isdigit(), limit=15)
    genpid = int(read(os.path.join(d, "genpid")).strip() or 0)
    # **登记门**: 只等 gen-started 会打中 pending 窗口, 那时后继按"身份尚不能确认"拒绝 ——
    # 那是产品的安全契约, 不是这一组要测的东西。等到身份真的登记完再发信号。
    gated, why_not = wait_registered(env, d, genpid, limit=30)
    # 顺序要紧: **先判登记门**。门没过而且原因出在凭据上, 那就是产品没登记身份 —— 此时
    # 受控延迟可能根本没机会触发(取 starttime 那一步整个不见了), 若先要求"延迟必须打过",
    # 真的产品退化会被写成"这一组没测到东西"而悄悄吞掉。
    if not gated:
        if gate_is_product_fault(why_not):
            bad("%s: 生成者已启动, 却始终没有登记出可用的身份凭据 —— %s" % (why, why_not))
        else:
            bad("%s: 登记门超时(夹具原因), 未满足的条件: %s —— 这一组没测到东西"
                % (why, why_not))
        p.kill(); p.wait(timeout=10)
        try: os.kill(genpid, signal.SIGKILL)
        except OSError: pass
        continue
    delayed = read(os.path.join(d, "catlog")).strip()
    if not delayed:
        bad("%s: 受控登记延迟没生效(cat 桩未被调用), 这一组没测到东西" % why)
        p.kill(); p.wait(timeout=10)
        try: os.kill(genpid, signal.SIGKILL)
        except OSError: pass
        continue
    if delayed.splitlines()[0] != "/proc/%d/stat" % genpid:
        bad("%s: 延迟打在了 %s, 不是生成器 %d 的 starttime 读取, 这一组没测到东西"
            % (why, delayed.splitlines()[0], genpid))
        p.kill(); p.wait(timeout=10)
        try: os.kill(genpid, signal.SIGKILL)
        except OSError: pass
        continue
    gen_txt = read(os.path.join(sess_dirs(env)[0], ".pdg-offer-gen")).strip().replace("\n", "|")
    try:
        os.kill(int(read(os.path.join(d, "pid")).strip()), signal.SIGKILL)
    except (OSError, ValueError):
        pass
    p.wait(timeout=20); time.sleep(0.2)
    pre_dirs = sess_dirs(env)
    gen_alive = alive(genpid)
    # 有界等待, 不做瞬时快照: 受控延迟期间 `_ios_offer_starttime` 跑在 `$( )` 里, 那个
    # 命令替换子 shell 也持有 fd 6, 父 shell 被强杀后它还要把 sleep 走完才退出。
    lk = wait_for(lambda: lock_free(env), limit=15)
    print("       %s 前像: 会话目录=%s | 生成器 %d 仍存活=%s | 凭据=%s | 锁可取=%s"
          % (why, [os.path.basename(x) for x in pre_dirs] or "无", genpid, gen_alive,
             gen_txt, lk))
    if not pre_dirs or not gen_alive:
        bad("%s: 前像不成立(目录 %d 个, 生成器存活=%s)" % (why, len(pre_dirs), gen_alive))
        try:
            os.kill(genpid, signal.SIGKILL)
        except OSError:
            pass
        continue
    # 锁必须真的可取: 否则后继的 BUSY 会冒充"按身份拒绝", 把这一组测成别的东西。
    if not lk:
        bad("%s: 父 shell 被强杀后会话锁仍被占(屏障子进程继承了 fd6?) —— 夹具问题, "
            "这一组没测到东西" % why)
        try:
            os.kill(genpid, signal.SIGKILL)
        except OSError:
            pass
        continue
    r, env_s = successor(env, "As-" + fn)
    still = alive(genpid)
    probs = []
    if r["rc"] == 0 and still:
        probs.append("后继报成功(rc=0), 而旧生成器 %d 还活着" % genpid)
    if r["rc"] not in (0,) and still:
        # 拒绝也是可接受的收口方式, 但必须点名
        if not re.search(r"生成|writer|gen", r["out"]):
            probs.append("拒绝了却没点名仍在写入的生成器")
    # 放行生成器让它落笔(醒来会 mkdir -p 重建目录), 再看盘上留下了什么。
    # 修好之后后继会**先停住它**, 那时放行也不会有人醒来 —— 所以只在它仍存活时才等,
    # 免得白等一轮超时。
    open(os.path.join(d, "gen-release"), "w").close()
    if alive(genpid):
        wait_file(os.path.join(d, "gen-wrote"), limit=25)
    wait_for(lambda: not alive(genpid), limit=15)
    after = sess_dirs(env)
    orphan = [x for x in after
              if not os.path.exists(os.path.join(x, ".pdg-offer-session"))]
    if orphan:
        probs.append("旧生成器落笔后重建出无 sentinel 的目录: %s"
                     % [os.path.basename(x) for x in orphan])
    r3, _ = successor(env, "A3-" + fn)
    if r3["rc"] != 0:
        probs.append("再下一次会话被那个残缺目录挡住(rc=%s)" % r3["rc"])
    if probs:
        bad("%s 生成中被强杀: %s" % (why, "; ".join(probs)))
    else:
        ok("%s 生成中被强杀 → 后继在删目录前先确认旧生成器不再写入, 盘上不留残缺目录" % why)
    try:
        os.kill(genpid, signal.SIGKILL)
    except OSError:
        pass
    wait_for(lambda: not connectable(), limit=10)


# ── B: 身份未知 ≠ 已退出 ────────────────────────────────────────────────
def make_dir(env, sid, pidline=None, mode=0o600):
    root = env["PDG_IOS_OFFER_ROOT"]
    os.makedirs(root, mode=0o700, exist_ok=True)
    d = os.path.join(root, "s." + sid)
    os.makedirs(d, mode=0o700)
    with open(os.path.join(d, ".pdg-offer-session"), "w", encoding="utf-8") as f:
        f.write(sid)
    os.chmod(os.path.join(d, ".pdg-offer-session"), 0o600)
    with open(os.path.join(d, "aaaaaaaaaaaa.mobileconfig"), "w", encoding="utf-8") as f:
        f.write("<plist/>\n")
    if pidline is not None:
        pf = os.path.join(d, ".pdg-offer-pid")
        with open(pf, "w", encoding="utf-8") as f:
            f.write(pidline)
        os.chmod(pf, mode)
    return d


def spawn_helper(cwd):
    return subprocess.Popen(["/usr/bin/sleep", "120"], cwd=cwd)




B_CASES = []
# ① 活进程, starttime 不符
dB1, eB1 = mkcase("B1", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
hd1 = os.path.join(eB1["PDG_IOS_OFFER_ROOT"], "s." + "1" * 16)
os.makedirs(eB1["PDG_IOS_OFFER_ROOT"], mode=0o700, exist_ok=True)
d1 = make_dir(eB1, "1" * 16, pidline="pid=0\nstart=0\n")
h1 = spawn_helper(d1)
with open(os.path.join(d1, ".pdg-offer-pid"), "w", encoding="utf-8") as f:
    f.write("pid=%d\nstart=999999999\n" % h1.pid)
os.chmod(os.path.join(d1, ".pdg-offer-pid"), 0o600)
B_CASES.append(("活进程 starttime 不符", dB1, eB1, d1, h1))
# ② 活进程, cwd 不符
dB2, eB2 = mkcase("B2", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
d2 = make_dir(eB2, "2" * 16, pidline="pid=0\nstart=0\n")
h2 = spawn_helper(dB2)                      # cwd 故意指向别处
with open(os.path.join(d2, ".pdg-offer-pid"), "w", encoding="utf-8") as f:
    f.write("pid=%d\nstart=%s\n" % (h2.pid, starttime_of(h2.pid)))
os.chmod(os.path.join(d2, ".pdg-offer-pid"), 0o600)
B_CASES.append(("活进程 cwd 不符", dB2, eB2, d2, h2))
# ③ 凭据损坏
dB3, eB3 = mkcase("B3", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
d3 = make_dir(eB3, "3" * 16, pidline="garbage-not-a-record\n")
B_CASES.append(("凭据损坏读不出", dB3, eB3, d3, None))

for why, dc, ec, target, helper in B_CASES:
    r = finish(launch(dc, ec), dc, limit=60)
    probs = []
    if r["rc"] in (None, 0):
        probs.append("返回 %s(身份未知就该拒绝)" % r["rc"])
    if not os.path.isdir(target):
        probs.append("目录被删了")
    if helper is not None and helper.poll() is not None:
        probs.append("进程被杀了")
    if not re.search(r"身份|无法确认|证不明|unknown", r["out"]):
        probs.append("没点名原因")
    if probs:
        bad("%s: %s" % (why, "; ".join(probs)))
    else:
        ok("%s → 非零退出并点名, 不杀进程、不删目录" % why)
    if helper is not None:
        helper.kill(); helper.wait(timeout=10)

# ④ 真正已退出 + 归属完整 → 正常回收
dB4, eB4 = mkcase("B4", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
h4 = spawn_helper(eB4["PDG_IOS_OFFER_ROOT"] if os.path.isdir(eB4["PDG_IOS_OFFER_ROOT"]) else "/tmp")
h4pid, h4start = h4.pid, starttime_of(h4.pid)
h4.kill(); h4.wait(timeout=10)
wait_for(lambda: not alive(h4pid), limit=10)
d4 = make_dir(eB4, "4" * 16, pidline="pid=%d\nstart=%s\n" % (h4pid, h4start))
r4 = finish(launch(dB4, eB4), dB4, limit=60)
if r4["rc"] == 0 and not os.path.isdir(d4):
    ok("确认已退出 + 归属完整 → 正常回收(目录已删, rc=0)")
else:
    bad("已退出的合法现场没被正常回收: rc=%s 目录仍在=%s" % (r4["rc"], os.path.isdir(d4)))

# ⑤ staging 现场(根本没有 HTTP pid 凭据)仍应可回收
dB5, eB5 = mkcase("B5", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
d5 = make_dir(eB5, "5" * 16, pidline=None)
r5 = finish(launch(dB5, eB5), dB5, limit=60)
if r5["rc"] == 0 and not os.path.isdir(d5):
    ok("staging 现场(无 HTTP pid 凭据)→ 仍可正常回收")
else:
    bad("staging 现场没被回收: rc=%s 目录仍在=%s" % (r5["rc"], os.path.isdir(d5)))


# ── C: 枚举失败不得当成空集合 ───────────────────────────────────────────
for mode, why in (("root-none", "根目录枚举无输出且非零"),
                  ("root-partial", "根目录枚举输出部分条目后非零"),
                  ("dir-none", "目录内容枚举失败")):
    dC, eC = mkcase("C-" + mode, fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1,
                    PDG_TEST_FIND_FAIL=mode)
    tgt = make_dir(eC, "c" * 16, pidline=None)
    with open(eC["PDG_IOS_OFFER_STATEFILE"], "w", encoding="utf-8") as f:
        f.write("phase=staging\nsid=%s\npid=\nstart=\nwww=%s\n" % ("c" * 16, tgt))
    r = finish(launch(dC, eC), dC, limit=60)
    probs = []
    if r["rc"] in (None, 0):
        probs.append("返回 %s(枚举失败不能当成扫描成功)" % r["rc"])
    if not os.path.isdir(tgt):
        probs.append("凭'不曾看到'把目录删了")
    if not os.path.exists(eC["PDG_IOS_OFFER_STATEFILE"]):
        probs.append("把恢复用的记录也清掉了")
    if not re.search(r"枚举|列不全|扫描", r["out"]):
        probs.append("没点名枚举失败")
    if probs:
        bad("%s: %s" % (why, "; ".join(probs)))
    else:
        ok("%s → 非零退出并点名, 不删未知对象、不清记录" % why)

# 正常空根目录与正常完整扫描仍要工作
dC4, eC4 = mkcase("C-empty", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
os.makedirs(eC4["PDG_IOS_OFFER_ROOT"], mode=0o700, exist_ok=True)
r = finish(launch(dC4, eC4), dC4, limit=60)
(ok if r["rc"] == 0 else bad)("正常空根目录 → rc=%s(应 0)" % r["rc"])
dC5, eC5 = mkcase("C-full", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
t5 = make_dir(eC5, "d" * 16, pidline=None)
r = finish(launch(dC5, eC5), dC5, limit=60)
if r["rc"] == 0 and not os.path.isdir(t5):
    ok("正常完整扫描 → 合法残留被回收, rc=0")
else:
    bad("正常完整扫描不对: rc=%s 目录仍在=%s" % (r["rc"], os.path.isdir(t5)))

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

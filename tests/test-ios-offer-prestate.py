#!/usr/bin/env python3
"""iOS 临时下载通道: **state 建立之前的 SIGKILL** 与 **父目录先验后改** —— 行为验证。

上一轮把所有权收敛成"一轮一个会话目录 + 一份运行期记录"。它闭合的是**完整就绪之后**被强杀
的情形。这一支盯的是那之前的两段真空, 以及建根目录时的一处顺序错误:

  A. **记录是 HTTP 起来之后才写的**, 而目录在那之前很久就已经落盘了。于是有两个窗口:
     · 目录已建、描述文件还在生成中 —— 盘上有一个带凭据的会话目录, 却**没有任何记录**;
       回收流程第一行就是 `[[ -s "$IOS_OFFER_STATE" ]] || return 0`, 直接放过。而且生成
       子进程**继承了会话锁的 fd 6**, 父 shell 死后锁还被它攥着。
     · HTTP 已经起来、运行期记录还没落盘 —— 端口被占、目录在盘上, 同样没有记录可依。
       后继会话既收不掉那个 HTTP, 也开不了自己的通道。
  B. 建根目录时是 `mkdir -p` → `chmod 0700` → **再**校验。`IOS_OFFER_ROOT` 若是一条指向
     别处的符号链接, `chmod` 先跟着它把**目标目录**的权限改掉, 校验才在后面说"不可信"。
     退出码是对的, 副作用已经造成了。

屏障用文件标记, 不用 sleep 猜时序。
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
  shift 3; verb="$1"; shift 5; nh=$(next_handle)
  echo "$nh|$(render "$@")" >> "$st"
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

# python3 桩: 按用途分派。`gen` 屏障让**生成子进程**先写好产物再挂住 —— 父 shell 就停在
# "目录已建、记录尚无"这一刻, 而这个子进程正好也是继承了 fd 6 的那个。
PY_STUB = r'''#!/bin/bash
real=/usr/bin/python3
if [ "${1:-}" = "$CH_DIR/iosstate.py" ]; then
  echo "iosstate $*" >> "$PDG_TEST_LOG"
  out=""; prev=""
  for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
  [ "$(dirname "$out")" = "/" ] && { echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1; }
  printf '%s' "$PDG_TEST_BODY" > "$out"
  if [ "${PDG_TEST_BARRIER:-}" = gen ]; then
    echo "$$" > "$CH_DIR/genpid"; : > "$CH_DIR/gen-started"
    sleep "${PDG_TEST_GEN_HOLD:-8}"
  fi
  exit 0
fi
if [ "${1:-}" = -c ] && case "${2:-}" in *serve_forever*) true;; *) false;; esac; then
  echo "srv-invoked" >> "$PDG_TEST_SRVLOG"; echo "$$" >> "$PDG_TEST_SRVPID"
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

# chmod 桩: `state` 屏障卡在**运行期(serving)记录**落盘之前 —— 那一刻 HTTP 已经在跑。
# 为什么不用 mktemp: 它跑在 `tmp="$(mktemp …)"` 这个**命令替换**里, 外层那个子 shell 同样
# 继承了会话锁的 fd 6, 而它在等桩返回 —— 桩里关自己的 fd 也没用, 锁仍被外层攥着, 后继会话
# 被夹具挡成 BUSY。chmod 是直接命令: bash fork 之后立刻 exec 成这个桩, 桩里 `exec 6>&-`
# 关掉的就是唯一那一份。
# 会话开场也写一次 state(staging), 所以要数次数, 卡第二次。
MKTEMP_STUB = r'''#!/bin/bash
exec /usr/bin/mktemp "$@"
'''

CHMOD_STUB = r'''#!/bin/bash
case "${*}" in
  *offer.state*)
    n=$(( $(cat "$CH_DIR/stn" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CH_DIR/stn"
    if [ "${PDG_TEST_BARRIER:-}" = state ] && [ "$n" = "${PDG_TEST_STATE_NTH:-2}" ]; then
      exec 6>&-
      : > "$CH_DIR/state-barrier"
      sleep "${PDG_TEST_STATE_HOLD:-8}"
    fi ;;
esac
exec /usr/bin/chmod "$@"
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
          _nft_apply_main _lan_nft_reapply; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE)=' \
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
"$CH_FN" < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>prestate</key></dict></plist>\n'


def mkcase(tag, fn="cmd_ios", **extra):
    d = tmpguard.mkdtemp(prefix="iosps-%s-" % tag)
    b = os.path.join(d, "bin"); os.makedirs(b); os.makedirs(os.path.join(d, "st"))
    for n, c in (("tmpl.mobileconfig", "<plist/>\n"), ("iosstate.py", "# stub\n")):
        with open(os.path.join(d, n), "w", encoding="utf-8") as f:
            f.write(c)
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB),
                    ("mktemp", MKTEMP_STUB), ("chmod", CHMOD_STUB), ("openssl", OPENSSL_STUB),
                    ("qrencode", "#!/bin/sh\nexit 0\n")):
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


def finish(proc, d, limit=60):
    try:
        proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=10)
    time.sleep(0.3)
    out = read(os.path.join(d, "out"))
    m = re.search(r"^RC=(\d+)$", out, re.M)
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None,
            "status": proc.returncode, "log": read(os.path.join(d, "log")),
            "marks": read(os.path.join(d, "chain")).count('comment "pdg-ios-offer"')}


def wait_file(p, limit=25.0):
    end = time.time() + limit
    while time.time() < end:
        if os.path.exists(p):
            return True
        time.sleep(0.03)
    return False


def wait_for(fn, limit=25.0):
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


def lock_free(env):
    import fcntl
    try:
        fh = open(env["PDG_IOS_OFFER_LOCKFILE"], "a")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN); fh.close(); return True
    except OSError:
        return False


def alive(p):
    return os.path.exists("/proc/%d" % p)


def successor(env0, tag, **kw):
    d, e = mkcase(tag, CH_STDIN_HOLD=1, **kw)
    for k in ("PDG_TEST_CHAIN", "PDG_IOS_OFFER_LOCKFILE",
              "PDG_IOS_OFFER_STATEFILE", "PDG_IOS_OFFER_ROOT"):
        e[k] = env0[k]
    return finish(launch(d, e), d, limit=60)


if connectable():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0])); sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)


# ── 窗口 1: 目录已建、描述文件生成中 ─────────────────────────────────────
for fn, why in (("cmd_ios", "pdg ios"), ("cmd_ios_previous", "pdg ios previous")):
    d, env = mkcase("w1-" + fn, fn=fn, CH_STDIN_HOLD=40,
                    PDG_TEST_BARRIER="gen", PDG_TEST_GEN_HOLD=8)
    p = launch(d, env)
    hit = wait_file(os.path.join(d, "gen-started"))
    if not hit:
        bad("%s 窗口1: 生成屏障没命中, 这一格没测到东西" % why)
        p.kill(); p.wait(timeout=10); continue
    genpid = int(read(os.path.join(d, "genpid")).strip() or 0)
    try:
        os.kill(int(read(os.path.join(d, "pid")).strip()), signal.SIGKILL)
    except (OSError, ValueError):
        pass
    p.wait(timeout=20); time.sleep(0.3)
    dirs = sess_dirs(env)
    has_state = os.path.exists(env["PDG_IOS_OFFER_STATEFILE"])
    gen_holds_fd6 = os.path.exists("/proc/%d/fd/6" % genpid) if genpid else False
    lk_during = lock_free(env)
    print("       %s 窗口1 前像: 会话目录=%s | state=%s | 生成子进程 %s 持 fd6=%s | 锁可取=%s"
          % (why, [os.path.basename(x) for x in dirs] or "无", has_state,
             genpid, gen_holds_fd6, lk_during))
    probs = []
    if len(dirs) != 1:
        probs.append("会话目录 %d 个(期望 1)" % len(dirs))
    # 目录一落盘就该有记录, 而且是 staging(只说"这个目录归本轮所有", 不含 pid)。
    # 不能等 HTTP 起来才第一次记录所有权 —— 那正是这个窗口原本的真空。
    st_txt = read(env["PDG_IOS_OFFER_STATEFILE"])
    if not has_state:
        probs.append("目录已落盘却没有任何所有权记录")
    elif not re.search(r"^phase=staging$", st_txt, re.M):
        probs.append("记录不是 staging 相: %r" % st_txt.replace("\n", "|")[:60])
    elif re.search(r"^pid=[0-9]", st_txt, re.M):
        probs.append("staging 记录里居然带了 pid —— 不完整的记录不该冒充运行期记录")
    if gen_holds_fd6 or not lk_during:
        probs.append("生成子进程继承了会话锁 fd 6, 父 shell 死后锁仍被占")
    # 等生成子进程自己结束(不杀它), 再让后继会话跑
    wait_for(lambda: not (genpid and alive(genpid)), limit=25)
    r = successor(env, "w1s-" + fn)
    left = [x for x in dirs if os.path.isdir(x)]
    if left:
        probs.append("后继会话跑完后旧目录仍在: %s" % [os.path.basename(x) for x in left])
    if r["rc"] != 0:
        probs.append("后继会话没能开通(rc=%s)" % r["rc"])
    if probs:
        bad("%s 在生成中被 SIGKILL: %s" % (why, "; ".join(probs)))
    else:
        ok("%s 在生成中被 SIGKILL → 生成子进程不持锁, 后继会话收走旧目录并正常开通" % why)
    wait_for(lambda: not connectable(), limit=10)


# ── 窗口 2: HTTP 已起、运行期记录尚未落盘 ────────────────────────────────
d2, env2 = mkcase("w2", CH_STDIN_HOLD=40, PDG_TEST_BARRIER="state", PDG_TEST_STATE_HOLD=8)
p2 = launch(d2, env2)
hit2 = wait_file(os.path.join(d2, "state-barrier"))
try:
    if not hit2:
        bad("窗口2: state 屏障没命中, 这一格没测到东西")
    else:
        srv = [int(x) for x in read(os.path.join(d2, "srvpid")).split() if x.isdigit()]
        try:
            os.kill(int(read(os.path.join(d2, "pid")).strip()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
        p2.wait(timeout=20); time.sleep(0.3)
        pre = {"dirs": sess_dirs(env2), "srv": [x for x in srv if alive(x)],
               "port": connectable(),
               "state": os.path.exists(env2["PDG_IOS_OFFER_STATEFILE"]),
               "marks": read(os.path.join(d2, "chain")).count('comment "pdg-ios-offer"')}
        print("       窗口2 前像: 会话目录=%s | HTTP=%s | 8443=%s | state=%s | 标记=%d"
              % ([os.path.basename(x) for x in pre["dirs"]] or "无", pre["srv"] or "无",
                 pre["port"], pre["state"], pre["marks"]))
        if not pre["dirs"] or not pre["srv"] or not pre["port"]:
            bad("窗口2 前像不成立(目录=%d HTTP=%s 端口=%s)"
                % (len(pre["dirs"]), pre["srv"], pre["port"]))
        else:
            r2 = successor(env2, "w2s")
            probs = []
            if [x for x in pre["srv"] if alive(x)]:
                probs.append("旧 HTTP 仍在跑 %s" % [x for x in pre["srv"] if alive(x)])
            if connectable():
                probs.append("8443 仍被占")
            if [x for x in pre["dirs"] if os.path.isdir(x)]:
                probs.append("旧会话目录仍在")
            if r2["marks"]:
                probs.append("链里仍有 %d 条本功能标记" % r2["marks"])
            if r2["rc"] != 0:
                probs.append("后继会话没能开通并收尾(rc=%s)" % r2["rc"])
            if probs:
                bad("HTTP 已起、记录未落盘时被 SIGKILL: " + "; ".join(probs)
                    + "\n       后继输出: " + r2["out"].strip().replace("\n", " | ")[:320])
            else:
                ok("HTTP 已起、记录未落盘时被 SIGKILL → 后继会话停掉旧 HTTP、释放端口、"
                   "删旧目录、清标记, 并正常开通收尾")
finally:
    for x in [int(y) for y in read(os.path.join(d2, "srvpid")).split() if y.isdigit()]:
        try:
            os.kill(x, signal.SIGKILL)
        except OSError:
            pass
    wait_for(lambda: not connectable(), limit=10)


# ── 会话根目录里的外来目录: 一律不碰, 也不因此拒绝开通道 ──────────────────
# 回收只处理**严格匹配** `s.<16位十六进制>` 且通过完整所有权判据的目录。名字对不上的东西
# 不该出现在这个父目录里, 但"不该有"不是动手的理由 —— 既不删它, 也不拿它当拒绝服务的借口。
d7, env7 = mkcase("foreign", CH_STDIN_HOLD=1)
os.makedirs(env7["PDG_IOS_OFFER_ROOT"], mode=0o700, exist_ok=True)
foreign = os.path.join(env7["PDG_IOS_OFFER_ROOT"], "not-a-session")
os.makedirs(foreign, mode=0o700)
with open(os.path.join(foreign, "keep.txt"), "w", encoding="utf-8") as f:
    f.write("someone else\n")
r7 = finish(launch(d7, env7), d7)
probs = []
if not os.path.isdir(foreign) or sorted(os.listdir(foreign)) != ["keep.txt"]:
    probs.append("外来目录被动过了")
if r7["rc"] != 0:
    probs.append("会话被它挡住了(rc=%s)" % r7["rc"])
if probs:
    bad("根目录里的外来目录: " + "; ".join(probs))
else:
    ok("根目录里的外来目录 → 原样不动, 也不阻塞本次会话")
wait_for(lambda: not connectable(), limit=10)

# ── B: 父目录必须先验后改 ────────────────────────────────────────────────
d3, env3 = mkcase("rootlink", CH_STDIN_HOLD=1)
victim = os.path.join(d3, "victim"); os.makedirs(victim, mode=0o755)
os.chmod(victim, 0o755)
with open(os.path.join(victim, "keep.txt"), "w", encoding="utf-8") as f:
    f.write("not ours\n")
before_mode = oct(os.stat(victim).st_mode & 0o777)
before_mtime = os.stat(victim).st_mtime
link = os.path.join(d3, "rootlink"); os.symlink(victim, link)
env3["PDG_IOS_OFFER_ROOT"] = link
r3 = finish(launch(d3, env3), d3)
after_mode = oct(os.stat(victim).st_mode & 0o777)
probs = []
if r3["rc"] in (None, 0):
    probs.append("返回 %s" % r3["rc"])
if after_mode != before_mode:
    probs.append("victim 的 mode 被改了 %s → %s(chmod 跟着符号链接先动了手)" % (before_mode, after_mode))
if os.stat(victim).st_mtime != before_mtime:
    probs.append("victim 的 mtime 变了")
if not os.path.exists(os.path.join(victim, "keep.txt")):
    probs.append("victim 里的文件没了")
if os.listdir(victim) != ["keep.txt"]:
    probs.append("victim 里多出了东西: %s" % sorted(os.listdir(victim)))
if probs:
    bad("IOS_OFFER_ROOT 是符号链接: %s" % "; ".join(probs))
else:
    ok("IOS_OFFER_ROOT 是符号链接 → 非零退出, 目标目录 mode/mtime/内容一律未动")

# 自有真实目录 0755: 确认归属之后允许收紧成 0700
d4, env4 = mkcase("root755", CH_STDIN_HOLD=1)
os.makedirs(env4["PDG_IOS_OFFER_ROOT"], mode=0o755); os.chmod(env4["PDG_IOS_OFFER_ROOT"], 0o755)
r4 = finish(launch(d4, env4), d4)
m4 = oct(os.stat(env4["PDG_IOS_OFFER_ROOT"]).st_mode & 0o777)
if m4 == "0o700" and r4["rc"] == 0:
    ok("自有真实目录 0755 → 确认归属后收紧为 0700, 会话正常")
else:
    bad("自有 0755 根目录处理不对: mode=%s rc=%s" % (m4, r4["rc"]))
wait_for(lambda: not connectable(), limit=10)

# 路径不存在: 应创建为自有 0700
d5, env5 = mkcase("rootnew", CH_STDIN_HOLD=1)
r5 = finish(launch(d5, env5), d5)
m5 = oct(os.stat(env5["PDG_IOS_OFFER_ROOT"]).st_mode & 0o777) \
    if os.path.isdir(env5["PDG_IOS_OFFER_ROOT"]) else "缺失"
if m5 == "0o700" and r5["rc"] == 0:
    ok("父目录不存在 → 创建为自有 0700, 会话正常")
else:
    bad("首次创建父目录不对: mode=%s rc=%s" % (m5, r5["rc"]))
wait_for(lambda: not connectable(), limit=10)

# 类型错误(是个普通文件): 非零且零副作用
d6, env6 = mkcase("rootfile", CH_STDIN_HOLD=1)
with open(env6["PDG_IOS_OFFER_ROOT"], "w", encoding="utf-8") as f:
    f.write("i am a file\n")
before6 = open(env6["PDG_IOS_OFFER_ROOT"], encoding="utf-8").read()
r6 = finish(launch(d6, env6), d6)
if r6["rc"] not in (None, 0) and open(env6["PDG_IOS_OFFER_ROOT"], encoding="utf-8").read() == before6:
    ok("父目录路径是普通文件 → 非零退出, 内容未动")
else:
    bad("类型错误的父目录处理不对: rc=%s" % r6["rc"])
wait_for(lambda: not connectable(), limit=10)

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

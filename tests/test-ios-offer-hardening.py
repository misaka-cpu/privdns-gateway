#!/usr/bin/env python3
"""iOS 临时下载通道: **不可枚举 / state 可信落盘 / 孤儿回收所有权 / 收尾再入** —— 行为验证。

前几轮把"收得回来""不认别人的服务""被打断就终止"钉住了。这一支盯四个仍然敞着的边界:

  1. **一次性 token 挡不住目录索引。** 服务用的是 `python3 -m http.server`, 它对 `/` 返回
     **目录清单**。同一网段的设备不需要猜 token —— 请求一次根路径就把文件名拿走了。
     "文件名带一次性随机串, 同网段猜不到"这句话, 在有目录索引的前提下是不成立的。
  2. **state 是 best-effort 写的。** `printf … > "$IOS_OFFER_STATE" 2>/dev/null || true`:
     写不进去照样继续开通道。而 SIGKILL 之后的自愈**完全依赖**这份记录 —— 记录没落盘,
     下一次会话就既不知道该收谁, 也不知道该删哪个目录, 端口白占十分钟。
  3. **孤儿回收挂在 nft 之后, 目录删除挂在身份校验之外。** 入场清理(读 nft 链)一失败就
     abort, 回收根本不会执行, 旧 HTTP 继续占着 8443; 而另一头, 身份对不上时代码仍然会走到
     那段 `rm -rf "$www"` —— 一份内容对得上的 state 就能让它删掉一个不属于它的目录。
  4. **收尾期间的第二个信号会把收尾打断。** 信号处理器第一件事是 `trap - EXIT HUP INT TERM`,
     此后再来一个 HUP/INT/TERM 走默认处置 = 直接杀掉 shell, 收尾停在半路。

判据全是行为的: 真起服务真发请求、真让 state 写失败、真造孤儿与不匹配的 state、真在收尾
的各个屏障上补第二个信号。
"""
import hashlib
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]
PORT = 8443

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


NFT_STUB = r'''#!/bin/bash
st="$PDG_TEST_STATE"; cnt="$st.listn"
if [ ! -s "$st" ]; then cat > "$st" <<'BASE'
1|iif "lo" accept
2|ct state established,related accept
3|tcp dport 22 accept
4|iifname "tailscale0" return
5|ip saddr 172.22.0.0/16 tcp dport { 53, 853 } accept
BASE
fi
echo "nft $*" >> "$PDG_TEST_LOG"
render(){ local a out="" q=0
  for a in "$@"; do
    if [ "$q" = 1 ]; then out="$out \"$a\""; q=0
    else out="$out $a"; [ "$a" = comment ] && q=1; fi
  done; echo "${out# }"; }
next_handle(){ echo $(( $(cut -d'|' -f1 "$st" | sort -n | tail -1) + 1 )); }
sig2(){ [ -n "${PDG_TEST_SIG2:-}" ] && kill "-${PDG_TEST_SIG2}" "$(cat "$PDG_TEST_PIDFILE")" 2>/dev/null; }
if [ "$1" = -j ] && [ "$2" = --echo ]; then
  shift 3; verb="$1"; shift 5
  nh=$(next_handle)
  if [ "$verb" = insert ]; then { echo "$nh|$(render "$@")"; cat "$st"; } > "$st.new"; mv "$st.new" "$st"
  else echo "$nh|$(render "$@")" >> "$st"; fi
  printf "{\"nftables\":[{\"add\":{\"rule\":{\"handle\":%s}}}]}\n" "$nh"
  exit 0
fi
case "$1" in
  -a)
    n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
    [ "${PDG_TEST_SIG2_AT:-}" = "list$n" ] && sig2
    if [ -n "${PDG_TEST_LIST_FAIL_FROM:-}" ] && [ "$n" -ge "$PDG_TEST_LIST_FAIL_FROM" ]; then
      echo "Error: No such file or directory" >&2; exit 1; fi
    echo "table inet pdg {"; echo "	chain input {"
    while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$st"
    echo "	}"; echo "}" ;;
  delete)
    [ "${PDG_TEST_SIG2_AT:-}" = delete ] && sig2
    shift $(($# - 1)); grep -v "^$1|" "$st" > "$st.new" 2>/dev/null; mv "$st.new" "$st" ;;
esac
exit 0
'''

PY_STUB = r'''#!/bin/bash
# 产品已去掉外层 `timeout 600`(只保留服务脚本自带的 Timer), 所以桩从 `timeout` 挪到
# `python3`, 按被要求跑的东西分派: 服务这一路才改写(把 0.0.0.0 换成回环, 免得跑一次测试
# 对外开端口), 其余(就绪探针、handle 解析)一律 exec 真 python3。
real=/usr/bin/python3
if [ "${1:-}" = -c ] && case "${2:-}" in *serve_forever*) true;; *) false;; esac; then
  echo "srv-invoked $*" >> "$PDG_TEST_SRVLOG"
  echo "$$" >> "$PDG_TEST_SRVPID"
  [ "${PDG_TEST_SRV_MODE:-serve}" = instant ] && exit 1
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

OPENSSL_STUB = ('#!/bin/sh\n# 按请求长度出: `rand -hex N` 要 2N 位十六进制。写死 12 位的话, 会话标识(-hex 8)\n# 会被产品判成非法, 现场长得像"openssl 坏了"。\nn=$(eval echo \\$$#)\ncase "$n" in ""|*[!0-9]*) n=6 ;; esac\nod -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\necho\n')

INSTALL_STUB = r'''#!/bin/bash
tgt="${!#}"
echo "install-target $tgt" >> "$PDG_TEST_LOG"
[ "$(dirname "$tgt")" = "/" ] && { echo "REFUSED-ROOT $tgt" >> "$PDG_TEST_LOG"; exit 1; }
exec /usr/bin/install "$@"
'''

HARNESS = r'''
set -uo pipefail
cd "$CH_ROOT"
echo $$ > "$CH_DIR/pid"
: > "$CH_DIR/fn.sh"
for fn in _ios_offer_download _ios_offer_teardown _ios_offer_abort _ios_offer_nft_close \
          _ios_offer_chain _ios_offer_marks _ios_offer_rule_ok _ios_offer_ready \
          _ios_offer_lock_acquire _ios_offer_lock_release _ios_offer_on_signal \
          _ios_offer_srv_alive _ios_offer_reap_orphan _ios_offer_starttime \
          _ios_offer_state_write _ios_offer_serve _ios_offer_session_begin \
          _ios_offer_dir_ok \
          _ios_offer_root_ok _ios_offer_reap_dir _ios_offer_dir_pid \
          _nft_apply_main _lan_nft_reapply \
          _ios_offer_proc_state _ios_offer_stop_pid _ios_offer_list _ios_offer_gen_run; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE|IOS_OFFER_GENFILE)=' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
for v in IOS_OFFER_PROBE IOS_OFFER_SERVER; do
  sed -n "/^$v='/,/^'\$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -q 'IOS_OFFER_PROBE=' "$CH_DIR/fn.sh" || { echo "EXTRACT-MISSING:IOS_OFFER_PROBE"; exit 9; }
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
# 通道现在要求先开会话: 取锁、收残留、建本轮**唯一**目录都在 _ios_offer_session_begin 里,
# 生成物直接落在那个目录 —— 所以夹具也必须照这个次序来, 否则测的就不是产品的真实调用形态。
# `if ! cmd; then echo "$?"` 里的 $? 是**取反之后**的状态(恒为 0)—— 会把开场失败报成 RC=0。
_ios_offer_session_begin; _sb=$?
if [ "$_sb" -ne 0 ]; then echo "RC=$_sb"; echo "REACHED-END"; exit "$_sb"; fi
cp "$CH_SRC" "$_IOS_OFFER_WWW/gen.mobileconfig"
# `exec 6>&-`: 这个 stdin 占位子进程是在会话锁的 fd 打开**之后**才 fork 的, 不关掉的话
# 它会一直攥着 flock —— 父 shell 被 SIGKILL 之后它还活着, 后继会话就被自己的夹具挡成
# BUSY。生产里 stdin 是 tty, 没有这种长命子进程。
_ios_offer_download "$_IOS_OFFER_WWW/gen.mobileconfig" 203.0.113.10 172.22.0.0/16 < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>hardening</key></dict></plist>\n'
BSHA = hashlib.sha256(BODY).hexdigest()


def mkcase(tag, **env_extra):
    d = tmpguard.mkdtemp(prefix="ioshd-%s-" % tag)
    b = os.path.join(d, "bin")
    os.makedirs(b)
    src = os.path.join(d, "cur.mobileconfig")
    with open(src, "wb") as f:
        f.write(BODY)
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB), ("openssl", OPENSSL_STUB),
                    ("install", INSTALL_STUB), ("qrencode", '#!/bin/sh\nexit 0\n')):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(s)
        os.chmod(p, 0o755)
    env = dict(os.environ,
               PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_SRVLOG=os.path.join(d, "srvlog"),
               PDG_TEST_SRVPID=os.path.join(d, "srvpid"),
               PDG_TEST_STATE=os.path.join(d, "chain"),
               PDG_TEST_PIDFILE=os.path.join(d, "pid"),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d, CH_DIR=d, CH_SRC=src, CH_ROOT=str(ROOT))
    env.update({k: str(v) for k, v in env_extra.items()})
    return d, env


def launch(d, env):
    hp = os.path.join(d, "harness.sh")
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


def finish(proc, d, limit=45):
    try:
        proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    time.sleep(0.3)
    out = read(os.path.join(d, "out"))
    m = re.search(r"^RC=(\d+)$", out, re.M)
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None,
            "status": proc.returncode, "log": read(os.path.join(d, "log")),
            "srvlog": read(os.path.join(d, "srvlog")),
            "reached_end": "REACHED-END" in out,
            "marks": [l for l in read(os.path.join(d, "chain")).splitlines()
                      if 'comment "pdg-ios-offer"' in l]}


def run_case(tag, stdin_hold=1, **env_extra):
    d, env = mkcase(tag, CH_STDIN_HOLD=stdin_hold, **env_extra)
    return finish(launch(d, env), d), env


def http_get(path, timeout=3.0):
    """裸 socket 说 HTTP/1.0 —— 不经代理、不跟随重定向, 问什么就是什么。"""
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    except OSError:
        return (None, b"")
    try:
        s.settimeout(timeout)
        s.sendall(("GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                   % path).encode())
        buf = b""
        while len(buf) < 1 << 20:
            c = s.recv(65536)
            if not c:
                break
            buf += c
    except OSError:
        return (None, b"")
    finally:
        s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    first = head.split(b"\r\n", 1)[0].split()
    code = int(first[1]) if len(first) > 1 and first[1].isdigit() else None
    return (code, body)


def wait_for(fn, limit=25.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False


def shows_link(o):
    return "  链接: http://" in o


def has_listener(t=1.0):
    return http_get("/", t)[0] is not None or _connectable(t)


def _connectable(t=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=t)
        s.close()
        return True
    except OSError:
        return False


if _connectable():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)


# ── 组 1: 不可枚举性 ──────────────────────────────────────────────────────
# 一次性 token 的全部价值在于"别人不知道路径"。只要根路径会列目录, 这个前提就没了 ——
# 同网段的设备(nft 放行的正是这个段)请求一次 `/` 就把文件名拿走, 猜都不用猜。
d1, env1 = mkcase("enum", CH_STDIN_HOLD=40)
p1 = launch(d1, env1)
ready1 = wait_for(lambda: shows_link(read(os.path.join(d1, "out"))))
probes = {}
tok = None
if ready1:
    m = re.search(r"链接: http://[^/]+/([0-9a-f]{12})\.mobileconfig", read(os.path.join(d1, "out")))
    tok = m.group(1) if m else None
    if tok:
        probes["exact"] = http_get("/%s.mobileconfig" % tok)
        for label, path in (("root", "/"), ("root_q", "/?x=1"), ("dot", "/."),
                            ("dotdot", "/.."), ("dslash", "//"),
                            ("pct", "/%2e"), ("trail", "/%s.mobileconfig/" % tok)):
            probes[label] = http_get(path)
        probes["exact2"] = http_get("/%s.mobileconfig" % tok)
try:
    os.kill(int(read(os.path.join(d1, "pid")).strip()), signal.SIGTERM)
except (OSError, ValueError):
    pass
r1 = finish(p1, d1)

if not ready1 or not tok:
    bad("不可枚举: 通道没就绪或取不到 token, 这一组没测到东西")
else:
    code, body = probes["exact"]
    if code == 200 and body == BODY:
        ok("精确 token 路径返回 200 且内容逐字节正确")
    else:
        bad("精确 token 路径不对: code=%s len=%d" % (code, len(body)))
    if probes["exact2"][0] == 200 and probes["exact2"][1] == BODY:
        ok("精确路径可重复下载(手机重试不会被一次性消耗掉)")
    else:
        bad("精确路径第二次取不到: code=%s" % (probes["exact2"][0],))
    leaks = []
    for label in ("root", "root_q", "dot", "dotdot", "dslash", "pct", "trail"):
        code, body = probes[label]
        if code not in (403, 404):
            leaks.append("%s→%s" % (label, code))
        elif tok.encode() in body or b".mobileconfig" in body:
            leaks.append("%s 响应体里出现了文件名" % label)
    if leaks:
        bad("根路径/变体可以枚举出这一次的文件: %s —— 一次性 token 形同虚设" % "; ".join(leaks))
    else:
        ok("根路径与六种变体全部 403/404 且响应体不含 token 或 .mobileconfig")


# ── 组 2: state 必须可信落盘 ──────────────────────────────────────────────
# SIGKILL 之后的自愈**完全依赖**这份记录。写不进去还继续开通道, 等于把"能自愈"建立在一个
# 没发生的写入上 —— 而现场看不出任何异常。
r2a, env2a = run_case("stateunwritable",
                      PDG_IOS_OFFER_STATEFILE="/nonexistent-dir-for-pdg-test/offer.state")
probs = []
if r2a["rc"] in (None, 0):
    probs.append("返回 %s" % r2a["rc"])
if shows_link(r2a["out"]):
    probs.append("展示了链接")
if re.search(r"^nft .*add rule", r2a["log"], re.M):
    probs.append("加了 nft 放行")
if r2a["marks"]:
    probs.append("链里残留 %d 条标记" % len(r2a["marks"]))
if _connectable():
    probs.append("HTTP 仍在监听")
w = re.search(r"install-target (\S+)", r2a["log"])
if w and os.path.isdir(os.path.dirname(w.group(1))):
    probs.append("临时目录没删: %s" % os.path.dirname(w.group(1)))
if probs:
    bad("state 路径不可写: %s —— best-effort 写入之后照样开了通道" % "; ".join(probs))
else:
    ok("state 路径不可写 → fail-closed: 非零退出, 不展示链接、不加放行, HTTP 与临时目录都收净")
wait_for(lambda: not _connectable(), limit=10)

r2b, env2b = run_case("nostarttime", PDG_TEST_SRV_MODE="instant")
sf = read(env2b["PDG_IOS_OFFER_STATEFILE"])
probs = []
if r2b["rc"] in (None, 0):
    probs.append("返回 %s" % r2b["rc"])
if shows_link(r2b["out"]):
    probs.append("展示了链接")
if os.path.exists(env2b["PDG_IOS_OFFER_STATEFILE"]):
    probs.append("留下了 state 文件")
if re.search(r"^start=\s*$", sf, re.M):
    probs.append("state 里写进了空的 start=(下一次会话会拿它当依据)")
if probs:
    bad("服务起来就退(starttime 取不到): %s" % "; ".join(probs))
else:
    ok("starttime 取不到 → 不落 state、非零退出、不展示链接")
wait_for(lambda: not _connectable(), limit=10)

d2c, env2c = mkcase("statemode", CH_STDIN_HOLD=40)
p2c = launch(d2c, env2c)
ready2c = wait_for(lambda: shows_link(read(os.path.join(d2c, "out"))))
smode, stray = None, []
if ready2c:
    sp = env2c["PDG_IOS_OFFER_STATEFILE"]
    if os.path.exists(sp):
        smode = oct(os.stat(sp).st_mode & 0o777)
    stray = [f for f in os.listdir(d2c) if f.startswith("offer.state") and f != "offer.state"]
try:
    os.kill(int(read(os.path.join(d2c, "pid")).strip()), signal.SIGTERM)
except (OSError, ValueError):
    pass
r2c = finish(p2c, d2c)
if not ready2c:
    bad("state mode: 通道没就绪, 这一格没测到东西")
elif smode != "0o600":
    bad("state 文件权限是 %s, 不是 0600 —— 里面是 pid 与本机路径, 不该让别人读" % smode)
elif stray:
    bad("state 落盘不是原子的: 目录里留下了候选文件 %s" % stray)
else:
    ok("state mode=0600 且原子落盘(没有残留候选文件)")
wait_for(lambda: not _connectable(), limit=10)


# ── 组 3: 孤儿回收的所有权 ────────────────────────────────────────────────
# 3a. 真实前像 + 后继会话读不到 nft 链。回收不能挂在 nft 后面 —— 数据面(还在服务的 HTTP)
#     是更紧的那一头, nft 读不到不是跳过它的理由。
dK, envK = mkcase("orphan", CH_STDIN_HOLD=60)
pK = launch(dK, envK)
readyK = wait_for(lambda: shows_link(read(os.path.join(dK, "out"))))
try:
    if not readyK:
        bad("孤儿回收: 前像没建立起来, 这一组没测到东西")
    else:
        os.kill(int(read(os.path.join(dK, "pid")).strip()), signal.SIGKILL)
        pK.wait(timeout=15)
        time.sleep(0.5)
        spids = [int(x) for x in read(os.path.join(dK, "srvpid")).split() if x.isdigit()]
        alive = [x for x in spids if os.path.exists("/proc/%d" % x)]
        statefile = envK["PDG_IOS_OFFER_STATEFILE"]
        pre_state = os.path.exists(statefile)
        nmark = read(os.path.join(dK, "chain")).count('comment "pdg-ios-offer"')
        print("       前像: 孤儿=%s 8443=%s 标记=%d state=%s"
              % (alive or "无", _connectable(), nmark, pre_state))
        if not alive or not _connectable() or not pre_state:
            bad("孤儿回收前像不成立(孤儿=%s 端口=%s state=%s)" % (alive, _connectable(), pre_state))
        else:
            dH, envH = mkcase("succ-nftfail", CH_STDIN_HOLD=1, PDG_TEST_LIST_FAIL_FROM=1)
            envH["PDG_TEST_STATE"] = envK["PDG_TEST_STATE"]
            envH["PDG_IOS_OFFER_LOCKFILE"] = envK["PDG_IOS_OFFER_LOCKFILE"]
            envH["PDG_IOS_OFFER_STATEFILE"] = statefile
            # 会话目录的固定安全父目录也必须共享 —— 后继会话拿自己的根去校验别人的目录,
            # 判据当然不通过, 而那不是产品的问题。
            envH["PDG_IOS_OFFER_ROOT"] = envK["PDG_IOS_OFFER_ROOT"]
            rH = finish(launch(dH, envH), dH, limit=40)
            still = [x for x in alive if os.path.exists("/proc/%d" % x)]
            probs = []
            if still:
                probs.append("旧 HTTP 仍在跑 %s —— nft 读失败被当成了跳过回收的理由" % still)
            if rH["rc"] in (None, 0):
                probs.append("后继会话返回 %s(nft 读不到, 不该算成功)" % rH["rc"])
            if shows_link(rH["out"]):
                probs.append("后继会话仍打出了链接")
            if probs:
                bad("后继会话 nft 读失败: " + "; ".join(probs) + "\n       后继输出: "
                    + rH["out"].strip().replace("\n", " | ")[:300])
            else:
                ok("后继会话即使 nft 读失败, 也先停掉并确认了旧 HTTP, 自身非零退出不开通道")
finally:
    for x in [int(y) for y in read(os.path.join(dK, "srvpid")).split() if y.isdigit()]:
        try:
            os.kill(x, signal.SIGKILL)
        except OSError:
            pass
    wait_for(lambda: not _connectable(), limit=10)

# 3b. state 身份对不上, 且 www 指向一个与本功能无关的空目录 —— 不许杀、不许删。
d3b, env3b = mkcase("mismatch", CH_STDIN_HOLD=1)
victim = os.path.join(d3b, "not-ours")
os.makedirs(victim)
with open(env3b["PDG_IOS_OFFER_STATEFILE"], "w", encoding="utf-8") as f:
    f.write("pid=%d\nstart=999999999\nwww=%s\n" % (os.getpid(), victim))
r3b = finish(launch(d3b, env3b), d3b)
if os.path.isdir(victim):
    ok("state 身份不匹配 → 不杀进程、也不删它指向的目录")
else:
    bad("state 身份不匹配, 却把它指向的目录删了(%s) —— 目录删除不受身份校验约束" % victim)
if os.path.exists("/proc/%d" % os.getpid()):
    ok("state 身份不匹配 → 记录里的 PID(本测试进程)没有被杀")
else:
    bad("测试进程被杀了 —— 这一格已经不可能走到这里")
wait_for(lambda: not _connectable(), limit=10)


# ── 组 4: 收尾期间再次收到信号 ────────────────────────────────────────────
# 信号处理器第一件事是摘 trap, 此后第二个 HUP/INT/TERM 走默认处置 = 直接杀掉 shell,
# 收尾停在半路。收尾一旦开始就必须跑完; 退出语义仍归第一次信号。
# 屏障要落在**收尾**里, 不是入场。`-a list` 的调用序号: 入场清理 #1 #2, 加完放行复查 #3,
# 收尾里 _ios_offer_nft_close 删除前 #4、删除后复核 #5。用 1/2 会在通道开起来之前就发信号,
# 那测的是"setup 期间的第二个信号", 不是本组要问的东西 —— 第一版就是这么把两格测空的。
for at, why in (("list4", "收尾撤 nft、读链的那一刻"),
                ("delete", "收尾正在删除 nft 规则时"),
                ("list5", "nft 已撤、正要删临时目录时")):
    d4, env4 = mkcase("sig2-" + at, CH_STDIN_HOLD=40,
                      PDG_TEST_SIG2_AT=at, PDG_TEST_SIG2="TERM")
    p4 = launch(d4, env4)
    ready4 = wait_for(lambda: shows_link(read(os.path.join(d4, "out"))))
    if ready4:
        try:
            os.kill(int(read(os.path.join(d4, "pid")).strip()), signal.SIGINT)
        except (OSError, ValueError):
            pass
    r4 = finish(p4, d4, limit=40)
    probs = []
    if not ready4:
        probs.append("通道没就绪, 这一格没测到东西")
    if r4["marks"]:
        probs.append("链里残留 %d 条标记放行" % len(r4["marks"]))
    if _connectable():
        probs.append("8443 仍有监听")
    w = re.search(r"install-target (\S+)", r4["log"])
    if w and os.path.isdir(os.path.dirname(w.group(1))):
        probs.append("临时目录没删")
    if os.path.exists(env4["PDG_IOS_OFFER_STATEFILE"]):
        probs.append("state 没删")
    if r4["status"] != 128 + int(signal.SIGINT):
        probs.append("退出状态 %s, 不是第一次信号(SIGINT=%d)的语义"
                     % (r4["status"], 128 + int(signal.SIGINT)))
    if probs:
        bad("%s 又来一个 SIGTERM: %s" % (why, "; ".join(probs)))
    else:
        ok("%s 又来一个 SIGTERM → 收尾跑完、资源归零, 退出状态仍是第一次信号的 %d"
           % (why, r4["status"]))
    wait_for(lambda: not _connectable(), limit=10)

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

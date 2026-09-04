#!/usr/bin/env python3
"""iOS 临时下载通道: **setup 中途被信号打断** 与 **就绪判据认错服务** —— 行为验证。

上一轮把收尾做成了幂等且可证明的。它没解决的是另外两件, 都属于"看起来成功"那一类:

  1. **trap 只收尾, 不终止控制流。** bash 的 trap 处理器跑完之后会**回到被打断的地方继续
     执行**。于是 setup 中途收到 HUP/TERM/INT, 通道先被收干净, 然后剩下的 setup 接着跑 ——
     再开一个 HTTP、再加一条 nft 放行、再把二维码打出来。用户按了 Ctrl-C, 屏幕上却出现了
     一个可用的下载链接, 而收尾已经过去了, 不会再有第二次。
  2. **就绪判据只问"能不能读到一个字节"。** `urlopen(url).read(1)` 会跟随重定向、会读
     HTTP_PROXY/http_proxy/ALL_PROXY、对返回什么内容毫不关心。8443 上只要有**任何**东西
     应答, 判据就说"服务好了", 于是 nft 放行照开、二维码照打 —— 而手机扫到的是别人的服务。

判据都是行为的: 真发信号、真起外来 HTTP、真设代理环境, 然后看产品做了什么。
"""
import hashlib
import http.server
import os
import re
import signal
import socket
import subprocess
import sys
import threading
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


# ── 桩 ───────────────────────────────────────────────────────────────────
# nft: 有状态的假链 + 两类注入 —— 失败注入(哪一次读/写失败)与信号注入(在哪一步发信号)。
# `-a list` 带计数: "入场读链成功、add 成功、add 之后读链失败"这种时序只能靠计数造出来。
NFT_STUB = r'''#!/bin/bash
st="$PDG_TEST_STATE"; cnt="$PDG_TEST_STATE.listn"
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
sig(){ [ -n "${PDG_TEST_SIG:-}" ] && kill "-${PDG_TEST_SIG}" "$(cat "$PDG_TEST_PIDFILE")" 2>/dev/null; }
next_handle(){ echo $(( $(cut -d'|' -f1 "$st" | sort -n | tail -1) + 1 )); }
# 产品现在用 `nft -j --echo --handle add rule …` 取回本轮规则的 handle。
# 形态取自 nftables v1.0.6 实测: {"nftables":[{"add":{"rule":{... "handle": N ...}}}]}
if [ "$1" = -j ] && [ "$2" = --echo ]; then
  [ "${PDG_TEST_NFT_FAIL:-}" = add ] && { echo "Error: could not add" >&2; exit 1; }
  # add 追加到链尾, insert 插到链首 —— 桩必须区分, 否则"改回 insert"这个变异
  # 在桩上看起来和 add 一模一样, 位置判据就成了摆设。
  shift 3; verb="$1"; shift 5
  nh=$(next_handle)
  if [ "$verb" = insert ]; then
    { echo "$nh|$(render "$@")"; cat "$st"; } > "$st.new"; mv "$st.new" "$st"
  else
    echo "$nh|$(render "$@")" >> "$st"
  fi
  if [ "${PDG_TEST_NO_HANDLE:-}" = 1 ]; then echo "{\"nftables\":[{\"add\":{\"rule\":{}}}]}"
  else printf "{\"nftables\":[{\"add\":{\"rule\":{\"handle\":%s}}}]}\n" "$nh"; fi
  [ "${PDG_TEST_SIG_AT:-}" = add ] && sig
  exit 0
fi
case "$1" in
  -a|-j)
    n=$(( $(cat "$cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$cnt"
    if [ -n "${PDG_TEST_LIST_FAIL_FROM:-}" ] && [ "$n" -ge "$PDG_TEST_LIST_FAIL_FROM" ]; then
      echo "Error: No such file or directory" >&2; exit 1; fi
    if [ "$1" = -j ] && [ "$2" != list ]; then :; fi
    echo "table inet pdg {"; echo "	chain input {"
    while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$st"
    echo "	}"; echo "}" ;;
  add)
    [ "${PDG_TEST_NFT_FAIL:-}" = add ] && { echo "Error: could not add" >&2; exit 1; }
    shift 5; nh=$(( $(cut -d'|' -f1 "$st" | sort -n | tail -1) + 1 ))
    echo "$nh|$(render "$@")" >> "$st"
    [ "${PDG_TEST_SIG_AT:-}" = add ] && sig
    exit 0 ;;
  delete)
    [ "${PDG_TEST_NFT_FAIL:-}" = delete ] && { echo "Error: could not delete" >&2; exit 1; }
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
  if [ "${PDG_TEST_SIG_AT:-}" = serve ]; then
    kill "-${PDG_TEST_SIG}" "$(cat "$PDG_TEST_PIDFILE")" 2>/dev/null
  fi
  [ "${PDG_TEST_SRV_MODE:-serve}" = none ] && exec sleep 30
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

OPENSSL_STUB = ('#!/bin/sh\n'
                '[ "${PDG_TEST_SIG_AT:-}" = token ] && '
                'kill "-${PDG_TEST_SIG}" "$(cat "$PDG_TEST_PIDFILE")" 2>/dev/null\n'
                'n=6\n'
                'for a in "$@"; do n="$a"; done\n'
                'case "$n" in ""|*[!0-9]*) n=6 ;; esac\n'
                'od -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\n'
                'echo\n')

INSTALL_STUB = r'''#!/bin/bash
tgt="${!#}"
echo "install-target $tgt" >> "$PDG_TEST_LOG"
if [ "$(dirname "$tgt")" = "/" ]; then
  echo "REFUSED-ROOT $tgt" >> "$PDG_TEST_LOG"; exit 1
fi
exec /usr/bin/install "$@"
'''

HARNESS = r'''
set -uo pipefail
cd "$CH_ROOT"
echo $$ > "$CH_DIR/pid"
: > "$CH_DIR/fn.sh"
for fn in _ios_offer_download _ios_offer_teardown _ios_offer_abort _ios_offer_nft_close \
          _ios_offer_chain _ios_offer_marks _ios_offer_rule_ok _ios_offer_ready \
          _ios_offer_lock_acquire _ios_offer_lock_release \
          _ios_offer_reap_orphan _ios_offer_starttime _ios_offer_state_write \
          _ios_offer_session_begin _ios_offer_dir_ok _ios_offer_on_signal \
          _ios_offer_srv_alive \
          _ios_offer_reap_orphan _ios_offer_root_ok _ios_offer_reap_dir _ios_offer_dir_pid \
          _nft_apply_main _lan_nft_reapply; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE)=' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
# IOS_OFFER_PROBE 是**多行**单引号常量, `grep '^…='` 只会抓到第一行 —— 那样 set -u 下
# 就绪判据当场炸掉, 现场看起来像"服务永远不就绪"。按范围抽。
sed -n "/^IOS_OFFER_PROBE='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
sed -n "/^IOS_OFFER_SERVER='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
grep -q "^IOS_OFFER_PROBE=" "$CH_DIR/fn.sh" || { echo "EXTRACT-MISSING:IOS_OFFER_PROBE"; exit 9; }
missing=""
for fn in $(grep -oE '_ios_offer_[a-z_]+' "$CH_DIR/fn.sh" | sort -u); do
  grep -q "^$fn()" "$CH_DIR/fn.sh" || missing="$missing $fn"
done
# **常量也要自证。** 只查函数名的话, 漏抽一个 IOS_OFFER_* 常量会变成 set -u 的运行期报错,
# 现场长得像"服务永远不就绪"——本轮实测漏过一次(IOS_OFFER_STATE)。
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


def mkcase(tag, **env_extra):
    d = tmpguard.mkdtemp(prefix="iosint-%s-" % tag)
    b = os.path.join(d, "bin")
    os.makedirs(b)
    src = os.path.join(d, "cur.mobileconfig")
    body = b'<?xml version="1.0"?><plist><dict><key>k</key></dict></plist>\n'
    with open(src, "wb") as f:
        f.write(body)
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
    return d, env, hashlib.sha256(body).hexdigest(), len(body)


def run(d, env, limit=45):
    hp = os.path.join(d, "harness.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    with open(os.path.join(d, "out"), "w", encoding="utf-8") as o:
        p = subprocess.Popen(["bash", hp], env=env, cwd=str(ROOT), stdout=o,
                             stderr=subprocess.STDOUT, text=True)
        try:
            p.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=10)
    time.sleep(0.3)

    def rd(n):
        try:
            with open(os.path.join(d, n), encoding="utf-8") as f:
                return f.read()
        except OSError:
            return ""
    out = rd("out")
    m = re.search(r"^RC=(\d+)$", out, re.M)
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None,
            "status": p.returncode,
            "log": rd("log"), "srvlog": rd("srvlog"), "chain": rd("chain"),
            "reached_end": "REACHED-END" in out,
            "marks": [l for l in rd("chain").splitlines() if 'comment "pdg-ios-offer"' in l]}


def shows_link(o):
    return "  链接: http://" in o


def claims_closed(o):
    return "已关闭临时下载服务。" in o


def wait_port_free(limit=15.0):
    end = time.time() + limit
    while time.time() < end:
        if not has_listener(0.4):
            return True
        time.sleep(0.1)
    return False


def has_listener(timeout=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
        s.close()
        return True
    except OSError:
        return False


# ── 环境前提 ──────────────────────────────────────────────────────────────
if has_listener():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用, 本文件所有真起 HTTP 的格子无法测量" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)


# ── 组 1: setup 三个屏障 × 三种信号 ───────────────────────────────────────
# 判据不是"收尾跑没跑"(上一轮已经证过了), 而是**信号之后还有没有继续往下做事**:
# 再起 HTTP、再加 nft、把链接打出来、说一句"已关闭" —— 任何一样都说明 trap 只是收了尾,
# 控制流原样回到了被打断的地方。
BARRIERS = (("token", "取到会话锁之后、生成 token 时"),
            ("serve", "HTTP 已启动、还没加 nft 放行时"),
            ("add", "nft 放行已加、还没展示链接时"))
for at, why in BARRIERS:
    for signame in ("HUP", "TERM", "INT"):
        d, env, _, _ = mkcase("sig-%s-%s" % (at, signame), CH_STDIN_HOLD=25,
                              PDG_TEST_SIG_AT=at, PDG_TEST_SIG=signame,
                              PDG_TEST_SRV_MODE=("none" if at == "token" else "serve"))
        r = run(d, env)
        probs = []
        # **核心判据**: 进程必须就地终止。bash 的 trap 处理器跑完会回到被打断的地方继续
        # 往下走 —— 收尾已经过去了, 后面每一步都在一个"已经收干净"的通道上重做一遍。
        # 只看下游症状(有没有链接)分辨不出来: 那些症状此刻恰好被后续校验挡住了, 而
        # "恰好挡住"不是设计, 换个屏障就漏。
        if r["reached_end"]:
            probs.append("信号后继续执行到了函数返回(trap 只收尾, 没终止控制流)")
        if r["status"] not in (128 + int(getattr(signal, "SIG" + signame)),
                               -int(getattr(signal, "SIG" + signame))):
            probs.append("退出状态 %s, 不是 SIG%s 的终止状态" % (r["status"], signame))
        # 信号之后不许再做**任何**新的开通动作。每个屏障各自的"已发生"基线不同。
        nsrv = len(re.findall(r"^srv-invoked", r["srvlog"], re.M))
        nadd = len(re.findall(r"^nft .*add rule", r["log"], re.M))
        exp_srv, exp_add = {"token": (0, 0), "serve": (1, 0), "add": (1, 1)}[at]
        if nsrv > exp_srv:
            probs.append("信号后又起了 HTTP(%d 个, 基线 %d)" % (nsrv, exp_srv))
        if nadd > exp_add:
            probs.append("信号后又加了 nft 放行(%d 条, 基线 %d)" % (nadd, exp_add))
        if shows_link(r["out"]):
            probs.append("展示了下载链接")
        if claims_closed(r["out"]):
            probs.append("打印了「已关闭临时下载服务」")
        if r["marks"]:
            probs.append("链里残留 %d 条标记放行" % len(r["marks"]))
        if not wait_port_free():
            probs.append("8443 一直没释放")
        if probs:
            bad("%s 收到 SIG%s: %s" % (why, signame, "; ".join(probs)))
        else:
            ok("%s 收到 SIG%s → 就地终止(退出状态 %s), 无新 HTTP/放行/链接/成功文案"
               % (why, signame, r["status"]))


# ── 组 2: 8443 上是别人的服务 ─────────────────────────────────────────────
class Foreign(http.server.BaseHTTPRequestHandler):
    mode = "200"
    alt = 0
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        Foreign.hits.append(self.path)
        if Foreign.mode == "302":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:%d/moved" % Foreign.alt)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", "1")
        self.end_headers()
        self.wfile.write(b"x")


class Alt(http.server.BaseHTTPRequestHandler):
    """302 的落点。**必须固定返回 200** —— 如果它和 Foreign 共用一个类, `mode` 是类属性,
    落点也会 302, 于是变成重定向循环, urllib 自己就放弃了。那样这一格会"通过", 而它证明的
    不是产品不跟随重定向, 只是我的夹具造了个死循环。"""
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        Alt.hits.append(self.path)
        self.send_response(200)
        self.send_header("Content-Length", "1")
        self.end_headers()
        self.wfile.write(b"x")


class Proxy(http.server.BaseHTTPRequestHandler):
    hits = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        Proxy.hits.append(self.path)
        self.send_response(200)
        self.send_header("Content-Length", "1")
        self.end_headers()
        self.wfile.write(b"x")


def serve_bg(handler, port, tries=40):
    """起一个后台 HTTP。收尾必须 shutdown() **加** server_close():
    只 shutdown 停的是 serve_forever 循环, 监听套接字还开着, 下一格再绑同一端口就
    EADDRINUSE —— 那不是被测代码留下的残留, 是夹具自己没关门。"""
    last = None
    for _ in range(tries):
        try:
            srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
        except OSError as e:
            last = e
            time.sleep(0.25)
            continue
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        return srv
    raise last


def stop_bg(srv):
    srv.shutdown()
    srv.server_close()


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


foreign_cases = []
alt_port = free_port()
alt = serve_bg(Alt, alt_port)              # 302 的落点(本地另一个地址, 固定 200)
Foreign.alt = alt_port
for tag, mode, why, proxy in (("f200", "200", "8443 上是别人的服务, 返回 200 + 一个字节", False),
                              ("f302", "302", "8443 上的服务 302 跳到另一个本地地址", False),
                              ("fproxy", "200", "设置了 HTTP_PROXY/http_proxy/ALL_PROXY", True)):
    Foreign.mode = mode
    Foreign.hits = []
    Proxy.hits = []
    Alt.hits = []
    if not wait_port_free():
        bad("%s: 8443 被上一格的残留占着, 这一格无法测量" % tag)
        continue
    fsrv = serve_bg(Foreign, PORT)
    pport = free_port()
    psrv = serve_bg(Proxy, pport)
    extra = {}
    if proxy:
        purl = "http://127.0.0.1:%d" % pport
        extra = {"HTTP_PROXY": purl, "http_proxy": purl, "ALL_PROXY": purl}
    try:
        d, env, _, _ = mkcase(tag, CH_STDIN_HOLD=1, **extra)
        r = run(d, env)
    finally:
        stop_bg(fsrv)
        stop_bg(psrv)
    foreign_cases.append((tag, why, r, list(Proxy.hits), list(Alt.hits)))
stop_bg(alt)

for tag, why, r, phits, ahits in foreign_cases:
    probs = []
    if shows_link(r["out"]):
        probs.append("展示了下载链接")
    if re.search(r"^nft .*add rule", r["log"], re.M):
        probs.append("加了 nft 放行")
    if r["rc"] is None:
        probs.append("夹具没跑到函数返回(可能是 EXTRACT-MISSING): %s" % r["out"][:80])
    elif r["rc"] == 0:
        probs.append("返回 0")
    if tag == "fproxy" and phits:
        probs.append("走了代理(代理收到 %d 次请求)" % len(phits))
    if tag == "f302" and ahits:
        probs.append("跟随了重定向(落点收到 %d 次请求)" % len(ahits))
    if r["marks"]:
        probs.append("链里残留 %d 条标记放行" % len(r["marks"]))
    if probs:
        bad("%s: %s —— 就绪判据把别人的服务当成了自己的" % (why, "; ".join(probs)))
    else:
        ok("%s → 不认账: 非零退出, 不加放行、不展示链接" % why)


# ── 组 3: nft add 成功, 之后每一次读链都失败 ───────────────────────────────
# 时序: 入场读链成功 → add 成功 → add 后第一次读链失败 → teardown 读链仍失败。
# 这一格问的是**规则去哪了**。"返回非零"是诚实的, 但它不等于"放行已经撤回" —— 撤除的
# 凭据(handle)在 add 那一刻就拿得到, 丢了它就只剩"读链找 handle"这一条路, 而链正好读不了。
if not wait_port_free():
    bad("组 3: 8443 被上一格残留占着, 无法测量")
else:
    d, env, _, _ = mkcase("readback", CH_STDIN_HOLD=1, PDG_TEST_LIST_FAIL_FROM=3)
    r = run(d, env)
    nadd = len(re.findall(r"^nft .*add rule", r["log"], re.M))
    ndel = len(re.findall(r"^nft delete rule", r["log"], re.M))
    probs = []
    if nadd != 1:
        probs.append("add 没发生或发生了 %d 次, 时序没造出来" % nadd)
    if r["marks"]:
        probs.append("放行仍留在链里(%d 条) —— 丢了 handle 就再也删不掉了" % len(r["marks"]))
    if ndel == 0:
        probs.append("一次精确删除都没尝试(没有保存 add 时拿到的 handle)")
    if claims_closed(r["out"]):
        probs.append("声称已关闭")
    if r["rc"] in (None, 0):
        probs.append("返回 0(读不到链就无法证明已撤回, 不能算成功)")
    if probs:
        bad("add 后复读失败: " + "; ".join(probs))
    else:
        ok("add 后复读失败 → 用 add 时保存的 handle 精确删除, 链里归零, 但仍非零退出(无法复核)")

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

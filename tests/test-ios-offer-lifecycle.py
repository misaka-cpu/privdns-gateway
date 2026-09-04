#!/usr/bin/env python3
"""iOS 临时下载通道的**失败路径与会话所有权** —— 行为验证。

上一轮(947c664)修的是"收不回来"。这一支盯的是另外两类, 它们比泄漏更难看出来:

  1. **假成功**。撤除函数把 `nft` 的读取失败 `2>/dev/null` 吞成空集合, 于是"没有残留"
     这个结论建立在一次**根本没发生的读取**上; 删除失败 `|| true`, 整表兜底再 `|| true`,
     最后无条件 `return 0`。setup 一侧同样: token、临时目录、入场清理、`nft add`、HTTP
     是否真的起来 —— 一个都没查, 二维码照打。用户看到的是成功, 机器上是半开的通道。
  2. **两条会话互相拆台**。标记是固定的、端口是固定的、没有任何锁。第二次调用的入场清理
     会把第一条**正在服务**的规则删掉, 而第一条毫不知情, 继续对着一个已经不通的链接等回车。

判据全是行为的: 真跑函数、真发信号、真起 HTTP(桩把 `--bind 0.0.0.0` 改写成 127.0.0.1,
只在回环上开, 不对外暴露)、真读链。词面断言只用来兜住夹具失效, 不代替行为判断。

`_ios_offer_download` 的调用方只有 CLI 两处(`pdg ios` / `pdg ios previous`)。
**Telegram Bot 不走这条通道** —— 它用 `send_document` 直接把字节发出去(见末格)。
"""
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
PDG = (ROOT / "deploy" / "bot" / "pdg.sh").read_text(encoding="utf-8")
BOT = (ROOT / "deploy" / "bot" / "pdg-bot.py").read_text(encoding="utf-8")
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
# nft: 一张**有状态**的假链, 失败模式由环境变量注入。只记命令是不够的 —— "读不到链"和
# "链是空的"必须能分开, 而那正是假成功的藏身处。
NFT_STUB = r'''#!/bin/bash
log(){ echo "$*" >> "$PDG_TEST_LOG"; }
state="$PDG_TEST_STATE"
reset_state(){ cat > "$state" <<'BASE'
1|iif "lo" accept
2|ct state established,related accept
3|tcp dport 22 accept
4|iifname "tailscale0" return
5|ip saddr 172.22.0.0/16 tcp dport { 53, 853 } accept
BASE
}
next_handle(){ echo $(( $(cut -d'|' -f1 "$state" | sort -n | tail -1) + 1 )); }
# 真 nft 打印 comment 时带引号(线上实测 `comment "pdg-rescue"`), shell 传参时那对引号
# 早被剥掉了 —— 桩必须补回来, 否则产品按标记找不到自己刚加的规则, 看起来像产品的错。
render(){
  local a out="" q=0
  for a in "$@"; do
    if [ "$q" = 1 ]; then out="$out \"$a\""; q=0
    else out="$out $a"; [ "$a" = comment ] && q=1; fi
  done
  echo "${out# }"
}
[ -s "$state" ] || reset_state
log "nft $*"
# 产品现在用 `nft -j --echo --handle add rule …` 取回本轮规则的 handle。
# 形态取自 nftables v1.0.6 实测: {"nftables":[{"add":{"rule":{... "handle": N ...}}}]}
if [ "$1" = -j ] && [ "$2" = --echo ]; then
  [ "${PDG_TEST_NFT_FAIL:-}" = add ] && { echo "Error: could not add" >&2; exit 1; }
  # add 追加到链尾, insert 插到链首 —— 桩必须区分, 否则"改回 insert"这个变异
  # 在桩上看起来和 add 一模一样, 位置判据就成了摆设。
  shift 3; verb="$1"; shift 5
  nh=$(next_handle)
  if [ "$verb" = insert ]; then
    { echo "$nh|$(render "$@")"; cat "$state"; } > "$state.new"; mv "$state.new" "$state"
  else
    echo "$nh|$(render "$@")" >> "$state"
  fi
  if [ "${PDG_TEST_NO_HANDLE:-}" = 1 ]; then echo "{\"nftables\":[{\"add\":{\"rule\":{}}}]}"
  else printf "{\"nftables\":[{\"add\":{\"rule\":{\"handle\":%s}}}]}\n" "$nh"; fi
    exit 0
fi
case "$1" in
  -a)
    if [ "${PDG_TEST_NFT_FAIL:-}" = list ]; then
      echo "Error: No such file or directory" >&2; exit 1; fi
    echo "table inet pdg {"; echo "	chain input {"
    while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$state"
    echo "	}"; echo "}" ;;
  -f) reset_state ;;
  add)
    [ "${PDG_TEST_NFT_FAIL:-}" = add ] && { echo "Error: could not add rule" >&2; exit 1; }
    shift 5; nh=$(next_handle); echo "$nh|$(render "$@")" >> "$state" ;;
  insert)
    shift 5; nh=$(next_handle)
    { echo "$nh|$(render "$@")"; cat "$state"; } > "$state.new"; mv "$state.new" "$state" ;;
  delete)
    [ "${PDG_TEST_NFT_FAIL:-}" = delete ] && { echo "Error: could not delete" >&2; exit 1; }
    shift $(($# - 1)); tgt="$1"
    grep -v "^$tgt|" "$state" > "$state.new" 2>/dev/null; mv "$state.new" "$state" ;;
esac
exit 0
'''

# timeout: 产品写的是 `exec timeout 600 python3 -m http.server 8443 --bind 0.0.0.0`。
# 桩把时长吃掉、把 0.0.0.0 改写成 127.0.0.1, 然后 **exec 真的 python3** —— 于是"就绪"
# 是真绑定真能取到文件, 而不是"进程还没死"这种看起来一样的东西。三种模式:
#   serve    正常起
#   instant  起来就退(端口被占 / 解释器炸了的等价形态)
#   bindfail 去绑一个已经被占住的端口, 让 python 自己失败
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

# token 必须**每次不同**, 和生产里的 `openssl rand -hex 6` 一样。固定 token 会造出一个
# 假象: SIGKILL 留下的孤儿服务的正是同一路径同一内容, 于是后继会话的就绪判据在孤儿身上
# 通过, 看起来"自愈成功"了 —— 真机上 token 随机, 后继只会拿到 404。
OPENSSL_STUB = ('#!/bin/sh\n'
                '[ "${PDG_TEST_TOKEN_FAIL:-}" = 1 ] && { echo "err" >&2; exit 1; }\n'
                '[ "${PDG_TEST_TOKEN_FAIL:-}" = junk ] && { echo "NOT-HEX!!"; exit 0; }\n'
                'n=6\n'
                'for a in "$@"; do n="$a"; done\n'
                'case "$n" in ""|*[!0-9]*) n=6 ;; esac\n'
                'od -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\n'
                'echo\n')

MKTEMP_STUB = ('#!/bin/sh\n'
               '[ "${PDG_TEST_MKTEMP_FAIL:-}" = 1 ] && { echo "mktemp: failed" >&2; exit 1; }\n'
               'exec /usr/bin/mktemp "$@"\n')

# install: 夹具的安全网。产品一旦把目标算成沙箱外的路径(mktemp 失败时 WWW 为空,
# 目标就成了 `/<token>.mobileconfig`), 这里**拒绝真的写**, 只记一笔 —— 测试机的 / 不该
# 因为跑一次测试而多出文件。
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
# 抽取清单必须跟着依赖走(HANDOFF §10.7)。**漏一个的代价是假绿, 不是报错**: 早先这里
# 漏了 _ios_offer_abort, 于是每条失败路径都撞 `command not found` 退出 —— 退出码同样非零、
# 同样不打链接, 几格"fail-closed 通过"其实一次都没跑到产品的收尾代码。
# 所以下面加一道自证: 抽完之后, 通道函数里调用到的 _ios_offer_* 必须**全部**已经定义。
for fn in _ios_offer_download _ios_offer_teardown _ios_offer_abort _ios_offer_nft_close \
          _ios_offer_chain _ios_offer_marks _ios_offer_rule_ok _ios_offer_ready \
          _ios_offer_lock_acquire _ios_offer_lock_release \
          _ios_offer_srv_alive _ios_offer_on_signal _ios_offer_reap_orphan _ios_offer_starttime _ios_offer_state_write \
          _ios_offer_session_begin _ios_offer_dir_ok \
          _nft_apply_main _lan_nft_reapply; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL)=' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
# IOS_OFFER_PROBE 是**多行**单引号常量, `grep '^…='` 只会抓到第一行 —— 那样 set -u 下
# 就绪判据当场炸掉, 现场看起来像"服务永远不就绪"。按范围抽。
sed -n "/^IOS_OFFER_PROBE='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
sed -n "/^IOS_OFFER_SERVER='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
grep -q "^IOS_OFFER_PROBE=" "$CH_DIR/fn.sh" || { echo "EXTRACT-MISSING:IOS_OFFER_PROBE"; exit 9; }
grep -q 'IOS_OFFER_SERVER=' "$CH_DIR/fn.sh" || { echo "EXTRACT-FAIL-server"; exit 9; }
# 抽取自证必须排在**所有**抽取之后 —— 排在前面的话它检查的是一个还没装满的 fn.sh。
# 函数和常量都要查: 只查函数时, 漏抽一个 IOS_OFFER_* 常量会变成 set -u 的运行期报错,
# 现场长得像"服务永远不就绪"。
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
'''


def port_free(port=PORT, host="127.0.0.1"):
    """能不能绑上 —— **必须带 SO_REUSEADDR**, 否则判据比真实情况严。

    python 的 http.server 自己就设了 allow_reuse_address, 所以上一轮连接遗留的 TIME_WAIT
    并不妨碍它绑定; 而不带 REUSEADDR 的探测会在同样的现场报"端口被占", 于是整支测试因为
    一个**并不存在的**前提失败而一格都跑不了。
    """
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def has_listener():
    """8443 上此刻有没有人在听。直连被拒 = 没有 —— 比"绑得上吗"更贴近要问的问题,
    也不会把 TIME_WAIT 误读成"还在监听"。"""
    return fetch(timeout=1.0)[0]


def fetch(path_ok=True, timeout=2.0):
    """真去 127.0.0.1:8443 取一次。返回 (连得上?, 拿到字节?)"""
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
    except OSError:
        return (False, False)
    try:
        s.sendall(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n")
        return (True, bool(s.recv(64)))
    except OSError:
        return (True, False)
    finally:
        s.close()


def mkcase(tag, **env_extra):
    d = tmpguard.mkdtemp(prefix="ioslc-%s-" % tag)
    b = os.path.join(d, "bin")
    os.makedirs(b)
    src = os.path.join(d, "cur.mobileconfig")
    with open(src, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0"?><plist><dict/></plist>\n')
    for name, body in (("nft", NFT_STUB), ("python3", PY_STUB), ("openssl", OPENSSL_STUB),
                       ("mktemp", MKTEMP_STUB), ("install", INSTALL_STUB),
                       ("qrencode", '#!/bin/sh\nexit 0\n')):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(p, 0o755)
    env = dict(os.environ,
               PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_SRVLOG=os.path.join(d, "srvlog"),
               PDG_TEST_SRVPID=os.path.join(d, "srvpid"),
               PDG_TEST_STATE=os.path.join(d, "chain"),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d,
               CH_DIR=d, CH_SRC=src, CH_ROOT=str(ROOT))
    env.update({k: str(v) for k, v in env_extra.items()})
    return d, env


def launch(d, env):
    hp = os.path.join(d, "harness.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    out = open(os.path.join(d, "out"), "w", encoding="utf-8")
    return subprocess.Popen(["bash", hp], env=env, cwd=str(ROOT),
                            stdout=out, stderr=subprocess.STDOUT, text=True)


def read(p):
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def marks(d):
    return [l for l in read(os.path.join(d, "chain")).splitlines()
            if 'comment "pdg-ios-offer"' in l]


def wait_for(fn, limit=20.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False


def finish(proc, d, limit=45):
    try:
        proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)
    time.sleep(0.2)
    o = read(os.path.join(d, "out"))
    m = re.search(r"^RC=(\d+)$", o, re.M)
    return {"out": o, "rc": int(m.group(1)) if m else None,
            "log": read(os.path.join(d, "log")),
            "srvlog": read(os.path.join(d, "srvlog")),
            "marks": marks(d), "dir": d}


def run_case(tag, stdin_hold=1, **env_extra):
    d, env = mkcase(tag, CH_STDIN_HOLD=stdin_hold, **env_extra)
    p = launch(d, env)
    return finish(p, d)


def session_dirs(env):
    """本轮会话目录 —— 从固定安全父目录里取。以前是从 `install-target` 日志里推的, 而通道
    现在用 mv(生成物本来就在会话目录里), 那条日志不再产生, 判据会静默变成"没有目录"。"""
    root = env.get("PDG_IOS_OFFER_ROOT", "")
    if not root or not os.path.isdir(root):
        return []
    return [os.path.join(root, n) for n in sorted(os.listdir(root))
            if os.path.isdir(os.path.join(root, n))]


def shows_link(out):
    return "  链接: http://" in out


def claims_closed(out):
    return "已关闭临时下载服务。" in out


# ── 环境前提: 8443 必须空闲, 否则本轮所有真起 HTTP 的格子都测不了 ────────────
# 这不是 SKIP —— 测不了就是没测到, 必须是一条具名失败, 否则"没测"会伪装成"通过"。
if not port_free():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用, 真起 HTTP 的格子无法测量" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)


# ── 1. nft 链读不到时, 绝不能当成"没有规则" ──────────────────────────────
r = run_case("nftlist", PDG_TEST_NFT_FAIL="list")
probs = []
if r["rc"] == 0:
    probs.append("返回 0(应非零)")
if shows_link(r["out"]):
    probs.append("展示了下载链接")
if claims_closed(r["out"]):
    probs.append("声称已关闭")
if "srv-invoked" in r["srvlog"]:
    probs.append("仍然起了 HTTP")
if re.search(r"^nft .*add rule", r["log"], re.M):
    probs.append("仍然加了放行规则")
if probs:
    bad("nft 链读取失败时: " + "; ".join(probs) + " —— 读不到被当成了没有规则")
else:
    ok("nft 链读取失败 → 非零退出, 不起 HTTP、不加规则、不展示链接、不声称成功")

# ── 2. 删除失败且标记仍在 → 必须非零, 不得声称已关闭 ─────────────────────
r = run_case("nftdel", stdin_hold=1, PDG_TEST_NFT_FAIL="delete")
if r["rc"] not in (None, 0) and not claims_closed(r["out"]):
    ok("nft 删除失败且标记仍在 → 非零退出且不声称已关闭")
else:
    bad("nft 删除失败时仍报成功: rc=%s 声称已关闭=%s 残留标记=%d"
        % (r["rc"], claims_closed(r["out"]), len(r["marks"])))

# ── 3. 任何失败路径都不许整表重载 ────────────────────────────────────────
fell_back = [t for t, rr in (("链读取失败", run_case("nb1", PDG_TEST_NFT_FAIL="list")),
                             ("删除失败", run_case("nb2", PDG_TEST_NFT_FAIL="delete")),
                             ("add 失败", run_case("nb3", PDG_TEST_NFT_FAIL="add")))
             if re.search(r"^nft -f ", rr["log"], re.M)]
if fell_back:
    bad("这些失败路径退回了整表重载(会冲掉救援平面和别人的运行期规则): %s" % "、".join(fell_back))
else:
    ok("三条失败路径都没有整表重载(nft -f 零次)")

# ── 4. nft add 失败 → HTTP / 目录 / 锁全部收净, 不展示链接 ────────────────
r = run_case("nftadd", PDG_TEST_NFT_FAIL="add")
leftovers = []
if r["rc"] in (None, 0):
    leftovers.append("返回 0")
if shows_link(r["out"]):
    leftovers.append("展示了链接")
if has_listener():
    leftovers.append("8443 仍有监听")
# 诊断要点名**是哪一步**失败。这不是文案洁癖: 加规则失败之后, 下一道"复查规则在不在、
# 位置对不对"照样会把它拦下来 —— 结果同样是 fail-closed, 但操作员看到的会是"位置不对",
# 于是去查一个根本不存在的顺序问题。判据只看结果的话, 这层退化一个字都不会说。
if "nft add" not in r["out"]:
    leftovers.append("诊断没点名 nft add —— 操作员看不出是哪一步失败")
# 锁必须已经放掉: 这一格失败发生在拿到锁**之后**, 收尾漏放锁的话下一次调用会被自己
# 十分钟前的一次失败挡在门外, 而现场看不出任何原因。
import fcntl as _fcntl
_lk = os.path.join(r["dir"], "offer.lock")
if os.path.exists(_lk):
    try:
        _fh = open(_lk, "a")
        _fcntl.flock(_fh.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
        _fh.close()
    except OSError:
        leftovers.append("会话锁没释放")
if leftovers:
    bad("nft add 失败后没收净: " + "; ".join(leftovers))
else:
    ok("nft add 失败 → 非零退出, 不展示链接, HTTP/端口已收净")

# ── 5. HTTP 起来就退 / 绑不上 → 不得加规则, 或必须立刻撤回; 不展示链接 ─────
class hold_port:
    """真占住 127.0.0.1:8443, 让被测进程去撞 EADDRINUSE。

    产品的就绪探针会先连上这个 socket 再超时(2 秒), 然后发现服务进程已经死了就立刻返回 ——
    所以这一格慢的那两秒是判据的一部分, 不是等待。
    """

    def __enter__(self):
        self.s = socket.socket()
        self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("127.0.0.1", PORT))
        self.s.listen(1)
        return self

    def __exit__(self, *a):
        self.s.close()


for tag, mode, why in (("instant", "instant", "HTTP 进程起来就退"),
                       ("bindfail", "serve", "8443 已被别人占住(绑定失败)")):
    if tag == "bindfail":
        with hold_port():
            r = run_case(tag, PDG_TEST_SRV_MODE=mode)
    else:
        r = run_case(tag, PDG_TEST_SRV_MODE=mode)
    probs = []
    if r["rc"] in (None, 0):
        probs.append("返回 0")
    if shows_link(r["out"]):
        probs.append("展示了链接")
    if r["marks"]:
        probs.append("放行规则留在链里(%d 条)" % len(r["marks"]))
    if probs:
        bad("%s: %s —— 通道其实不通, 却当成开好了" % (why, "; ".join(probs)))
    else:
        ok("%s → 非零退出, 不展示链接, 链里无残留放行" % why)

# ── 6. 两条并发会话: 后来者必须 BUSY, 且不许动前一条的规则 ────────────────
dA, envA = mkcase("concA", CH_STDIN_HOLD=30)
dB, envB = mkcase("concB", CH_STDIN_HOLD=2)
# B 共用 A 的锁文件与链: 模拟同一台机器上的第二次调用。
envB["PDG_IOS_OFFER_LOCKFILE"] = envA["PDG_IOS_OFFER_LOCKFILE"]
envB["PDG_TEST_STATE"] = envA["PDG_TEST_STATE"]
pA = launch(dA, envA)
readyA = wait_for(lambda: shows_link(read(os.path.join(dA, "out"))))
marksA = marks(dA)
servedA = fetch()
pB = launch(dB, envB)
rB = finish(pB, dB, limit=30)
marksAfterB = marks(dA)
servedA2 = fetch()
try:
    os.kill(int(read(os.path.join(dA, "pid")).strip()), signal.SIGTERM)
except (OSError, ValueError):
    pass
rA = finish(pA, dA, limit=30)

if not readyA or not marksA:
    bad("并发: A 没能就绪(readyA=%s 规则=%d), 这一格没测到东西\n%s"
        % (readyA, len(marksA), read(os.path.join(dA, "out"))[:400]))
else:
    probs = []
    if "BUSY" not in rB["out"]:
        probs.append("B 没有明确 BUSY")
    if rB["rc"] in (None, 0):
        probs.append("B 返回 0")
    if len(marksAfterB) != len(marksA):
        probs.append("B 动了 A 的规则(%d → %d 条)" % (len(marksA), len(marksAfterB)))
    if "srv-invoked" in rB["srvlog"]:
        probs.append("B 起了第二个服务器")
    if not servedA2[1]:
        probs.append("B 之后 A 的文件取不到了")
    if probs:
        bad("并发所有权: " + "; ".join(probs))
    else:
        ok("并发: B 明确 BUSY 且零副作用, A 的规则与服务不受影响(A 全程可取件: %s)"
           % (servedA[1] and servedA2[1]))
    zero = []
    if rA["marks"]:
        zero.append("标记规则 %d 条" % len(rA["marks"]))
    if has_listener():
        zero.append("8443 仍有监听")
    if zero:
        bad("A 结束后没归零: " + "; ".join(zero))
    else:
        ok("A 结束后规则/端口全部归零")

# ── 7. 四条退出路径的终态: 规则 / 进程 / 端口 / 目录 / 锁 五项全零 ─────────
for tag, sig, why in (("hup", signal.SIGHUP, "SIGHUP"),
                      ("term", signal.SIGTERM, "SIGTERM"),
                      ("int", signal.SIGINT, "SIGINT"),
                      ("eof", None, "正常 EOF(按回车)")):
    d, env = mkcase("exit-" + tag, CH_STDIN_HOLD=(30 if sig else 1))
    p = launch(d, env)
    ready = wait_for(lambda: shows_link(read(os.path.join(d, "out"))))
    if sig is not None and ready:
        try:
            os.kill(int(read(os.path.join(d, "pid")).strip()), sig)
        except (OSError, ValueError):
            pass
    r = finish(p, d, limit=40)
    srvpid = re.search(r"serve-pid=(\d+)", r["srvlog"])
    probs = []
    if not ready:
        probs.append("通道没就绪, 这一格没测到东西")
    if r["marks"]:
        probs.append("标记规则残留 %d 条" % len(r["marks"]))
    if has_listener():
        probs.append("8443 仍有监听")
    _sd = session_dirs(env)
    if _sd:
        probs.append("会话目录还在: %s" % [os.path.basename(x) for x in _sd])
    # 锁文件不存在 = 这条通道**根本没有会话锁**, 那是缺陷本体, 不是"无需检查"。
    # 写成"存在才查"的话, 负控里"删掉会话锁"这一格会静默变成空转。
    lk = os.path.join(d, "offer.lock")
    if not os.path.exists(lk):
        probs.append("会话锁文件不存在 —— 通道没有会话锁")
    else:
        try:
            import fcntl
            fh = open(lk, "a")
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fh.close()
        except OSError:
            probs.append("会话锁没释放")
    if probs:
        bad("%s 之后: %s" % (why, "; ".join(probs)))
    else:
        ok("%s 之后: 规则 0 / 端口 0 / 临时目录 0 / 会话锁已释放" % why)

# ── 7b. SIGKILL: 断言之前**不做任何人工干预** ─────────────────────────────
# 上一版在这里先按 pid 把孤儿 HTTP 杀掉、再去看后继会话"自愈"得怎么样, 然后把结果写成了
# "SIGKILL 之后下一次会话拿到锁、带走残留、自己也收干净"。那句话是**测试清理**换来的,
# 不是产品行为 —— 端口一直被孤儿占着的话, 后继会话根本起不来。
# 这一格改成: 打死父 shell 之后原样启动后继会话, 记录五项前像, 断言全部做完了再清场。
import fcntl

dK, envK = mkcase("sigkill", CH_STDIN_HOLD=60)
pK = launch(dK, envK)
readyK = wait_for(lambda: shows_link(read(os.path.join(dK, "out"))))
pre = {}
try:
    if not readyK or not marks(dK):
        bad("SIGKILL: 通道没就绪(ready=%s), 这一格没测到东西" % readyK)
    else:
        try:
            os.kill(int(read(os.path.join(dK, "pid")).strip()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
        pK.wait(timeout=15)
        time.sleep(0.5)
        srvpids = [int(x) for x in read(os.path.join(dK, "srvpid")).split() if x.isdigit()]
        alive = []
        for sp in srvpids:
            try:
                os.kill(sp, 0)
                alive.append(sp)
            except OSError:
                pass
        _sd = session_dirs(envK)
        wwwdir = _sd[0] if _sd else ""
        lockfree = True
        try:
            fh = open(envK["PDG_IOS_OFFER_LOCKFILE"], "a")
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            fh.close()
        except OSError:
            lockfree = False
        pre = {"orphan": alive, "port": has_listener(), "marks": len(marks(dK)),
               "www": wwwdir if wwwdir and os.path.isdir(wwwdir) else "",
               "lockfree": lockfree}
        print("       SIGKILL 前像: 孤儿 HTTP=%s, 8443 有监听=%s, nft 标记=%d, 旧 WWW=%s, 锁可取=%s"
              % (pre["orphan"] or "无", pre["port"], pre["marks"],
                 pre["www"] or "已不在", pre["lockfree"]))
        if not lockfree:
            bad("SIGKILL 之后会话锁仍被占着 —— HTTP 子进程继承了锁 fd")
        else:
            ok("SIGKILL 之后会话锁可以再取(子进程没有继承锁 fd)")
        # **前像必须成立**, 而且要单独判。孤儿不在了 / 端口空着 / 标记没了, 说明有人在断言
        # 之前替产品把场清了 —— 后面那格"自愈"就成了测试清理的功劳。上一轮正是这么把
        # "后继会话拿到锁、带走残留、自己也收干净"写进报告的。
        if not pre["orphan"] or not pre["port"] or pre["marks"] != 1 or not pre["www"]:
            bad("SIGKILL 前像不成立(孤儿=%s 端口=%s 标记=%d 旧目录=%s)—— "
                "有人在断言前替产品清了场, 后面的自愈判据不作数"
                % (pre["orphan"] or "无", pre["port"], pre["marks"], pre["www"] or "无"))
        else:
            ok("SIGKILL 前像成立: 孤儿仍在跑、8443 仍被占、标记 1 条、旧目录仍在")

        # 后继会话: 共用同一条链、同一把锁、同一份运行期记录。不预先杀孤儿, 不预先删目录。
        dH, envH = mkcase("selfheal", CH_STDIN_HOLD=1)
        # **后继会话启动的那一刻**孤儿必须还活着。前像是更早采的, 只看前像的话, 有人在
        # 两者之间替产品清了场同样看不出来 —— 而那正是把测试清理冒充成产品自愈的做法,
        # 上一轮就是这么得出"后继全零"这个不实结论的。判据必须钉在这一刻。
        still = []
        for _sp in pre["orphan"]:
            try:
                os.kill(_sp, 0)
                still.append(_sp)
            except OSError:
                pass
        if not still or not has_listener():
            bad("后继会话启动前孤儿已经不在了(存活=%s, 8443 有监听=%s) —— "
                "有人在断言前替产品清了场, 下面的自愈判据不作数"
                % (still or "无", has_listener()))
        else:
            ok("后继会话启动时孤儿仍在跑 %s 且仍占着 8443(自愈判据的前提成立)" % still)
        envH["PDG_TEST_STATE"] = envK["PDG_TEST_STATE"]
        envH["PDG_IOS_OFFER_LOCKFILE"] = envK["PDG_IOS_OFFER_LOCKFILE"]
        envH["PDG_IOS_OFFER_STATEFILE"] = envK["PDG_IOS_OFFER_STATEFILE"]
        envH["PDG_IOS_OFFER_ROOT"] = envK["PDG_IOS_OFFER_ROOT"]
        rH = finish(launch(dH, envH), dH, limit=60)
        post_orphan = []
        for sp in pre["orphan"]:
            try:
                os.kill(sp, 0)
                post_orphan.append(sp)
            except OSError:
                pass
        probs = []
        if "BUSY" in rH["out"]:
            probs.append("被自己的孤儿挡成 BUSY")
        if rH["rc"] not in (0,):
            probs.append("后继会话没能开通(rc=%s)" % rH["rc"])
        if not shows_link(rH["out"]):
            probs.append("后继会话没打出链接")
        if post_orphan:
            probs.append("孤儿 HTTP 仍在跑 %s" % post_orphan)
        if pre["www"] and os.path.isdir(pre["www"]):
            probs.append("上一轮的临时目录仍在 %s" % pre["www"])
        if rH["marks"]:
            probs.append("链里仍有 %d 条标记放行" % len(rH["marks"]))
        if probs:
            bad("SIGKILL 后继会话未能自愈: " + "; ".join(probs))
        else:
            ok("SIGKILL 后继会话自愈: 收掉孤儿、删掉旧目录、开通并收干净(全程无人工干预)")
finally:
    # 清场只放在断言之后, 且只按记录到的确切 pid / 路径来收 —— 不是产品证据的一部分。
    for sp in [int(x) for x in read(os.path.join(dK, "srvpid")).split() if x.isdigit()]:
        try:
            os.kill(sp, signal.SIGKILL)
        except OSError:
            pass
    wait_for(lambda: not has_listener(), limit=10)

# ── 8. token 与 mktemp 必须 fail-closed, 尤其不许往 / 写 .mobileconfig ────
for tag, why, extra in (("tokfail", "openssl 失败", {"PDG_TEST_TOKEN_FAIL": "1"}),
                        ("tokjunk", "token 不是 12 位十六进制", {"PDG_TEST_TOKEN_FAIL": "junk"}),
                        ("mktmp", "mktemp -d 失败", {"PDG_TEST_MKTEMP_FAIL": "1"})):
    r = run_case(tag, **extra)
    probs = []
    if r["rc"] in (None, 0):
        probs.append("返回 0")
    if shows_link(r["out"]):
        probs.append("展示了链接")
    if "REFUSED-ROOT" in r["log"]:
        probs.append("试图把 .mobileconfig 写到沙箱外(真机上就是写到 / )")
    if r["marks"]:
        probs.append("仍加了放行规则")
    if probs:
        bad("%s: %s" % (why, "; ".join(probs)))
    else:
        ok("%s → fail-closed: 非零退出, 不写盘、不加规则、不展示链接" % why)

# ── 8b. nft 不回报 handle → 必须 fail-closed ──────────────────────────────
# handle 是**撤除凭据**: 拿不到它, 一旦之后读不了链, 自己刚加的规则就再也删不掉。
# 所以"加成功了但没回报 handle"不能当成功 —— 那是一条撤不掉的放行。
r = run_case("nohandle", PDG_TEST_NO_HANDLE=1)
probs = []
if r["rc"] in (None, 0):
    probs.append("返回 0")
if shows_link(r["out"]):
    probs.append("展示了链接")
if r["marks"]:
    probs.append("链里残留 %d 条标记放行" % len(r["marks"]))
if "handle" not in r["out"]:
    probs.append("诊断没点名 handle —— 操作员看不出缺的是撤除凭据")
if probs:
    bad("nft 没回报 handle: %s" % "; ".join(probs))
else:
    ok("nft 没回报 handle → fail-closed: 非零退出, 不展示链接, 链里无残留")

# ── 9. 只删自己的; 用户不带标记的同端口放行必须原样保留 ────────────────────
d, env = mkcase("own")
with open(env["PDG_TEST_STATE"], "w", encoding="utf-8") as f:
    f.write('1|iif "lo" accept\n'
            '4|iifname "tailscale0" return\n'
            '5|ip saddr 172.22.0.0/16 tcp dport 8443 accept comment "pdg-ios-offer"\n'
            '6|ip saddr 10.9.9.0/24 tcp dport 8443 accept\n')
env["CH_STDIN_HOLD"] = "1"
r = finish(launch(d, env), d)
chain = read(os.path.join(d, "chain"))
users = [l for l in chain.splitlines() if "10.9.9.0/24" in l]
if len(users) == 1 and not r["marks"]:
    ok("只删带标记的那条: 用户自己的同端口放行原样保留, 本功能的规则清零")
else:
    bad("所有权判据不对: 用户规则剩 %d 条(应 1), 标记规则剩 %d 条(应 0)"
        % (len(users), len(r["marks"])))

# ── 10. 事实钉子: Bot 不走这条 HTTP 通道 ─────────────────────────────────
# 立这一格是因为**归因错过一次**: 947c664 的提交信息把"非交互调用"记在了 Bot 头上, 而
# Bot 用 send_document 直接把字节发出去, 从不开 8443。写死在测试里, 下次再有人这么写就红。
bot_hits = {p: len(re.findall(p, BOT)) for p in
            (r"_ios_offer_download", r"http\.server", r"8443", r"qrencode")}
callers = re.findall(r"^\s*_ios_offer_download ", PDG, re.M)
if any(bot_hits.values()):
    bad("Bot 里出现了临时下载通道的痕迹(应全为 0): %r" % bot_hits)
elif "send_document(chat, \"PrivDNS-Gateway.mobileconfig\"" not in BOT:
    bad("Bot 不再用 send_document 直接下发描述文件 —— 这一格的前提变了, 判据要重写")
elif len(callers) != 2:
    bad("_ios_offer_download 的调用方有 %d 处(应为 2: pdg ios / pdg ios previous)" % len(callers))
else:
    ok("Bot 用 send_document 直接下发, 不碰 8443; 通道调用方只有 CLI 两处")

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

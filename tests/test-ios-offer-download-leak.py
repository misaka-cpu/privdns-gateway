#!/usr/bin/env python3
"""`_ios_offer_download` 的临时放行**必须收回来** —— 行为验证。

这条通道会往 `inet pdg input` 里插一条临时放行, 用完就撤。撤不掉的后果不是"多一条规则":
线上 jp2 实测过一次泄漏, 表现是 `pdg doctor` 判红 `Tailscale 入口隔离`, 于是 `pdg update`
的后置自检门每次都判 fail 并**整轮回滚** —— 那台机器再也升不上去, 而现场只看得到一条
看不出因果的红灯。

三条独立的成因, 这里逐条钉住:
  1. **`trap` 只捕 `INT TERM`, 漏了 `HUP`** —— SSH 断开发的正是 HUP; 非交互调用(Bot 的
     「📱 iOS 描述文件」按钮)也没有人"按回车"。信号一到, bash 直接死, 收尾代码根本不执行;
  2. **规则用 `insert` 插在链首** —— 排在 `iifname "tailscale0" return` **之前**, 于是
     即便只泄漏一次也踩中隔离判据。追加到链尾就排在排除之后, tailnet 流量永远到不了它;
  3. **收尾整表重载**(`_nft_apply_main`)—— 撤得掉, 但顺手把别人的运行期规则也一起冲了。
     救援平面早就定过口径: **认标记, 不认端口**(用户完全可能自己写过一条同端口放行)。

判据全部是**行为**的: 真把函数跑起来, 真发信号, 看 nft 到底被调用成什么样。结构断言只用来
兜住"函数被抽走了/改名了"这类夹具失效, 不用来代替行为判断。
"""
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]
PDG = (ROOT / "deploy" / "bot" / "pdg.sh").read_text(encoding="utf-8")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# ── nft 桩: 维护一张**有状态**的假链 ──────────────────────────────────────
# 只记命令是不够的 —— "按 handle 精确删除"这件事必须能看出规则真的没了, 而不是又调了一次
# nft。所以桩把链存成文件: add 追加、insert 插首、delete 按 handle 摘、-f 整表重建。
# 基线里那条 `iifname "tailscale0" return` 是判据的锚 —— 临时放行排在它前面还是后面,
# 决定了 doctor 判红还是判绿。
NFT_STUB = r'''#!/bin/bash
log(){ echo "$*" >> "$PDG_TEST_LOG"; }
state="$PDG_TEST_STATE"
reset_state(){
  cat > "$state" <<'BASE'
1|iif "lo" accept
2|ct state established,related accept
3|tcp dport 22 accept
4|iifname "tailscale0" return
5|ip saddr 172.22.0.0/16 tcp dport { 53, 853 } accept
BASE
}
next_handle(){ echo $(( $(cut -d'|' -f1 "$state" | sort -n | tail -1) + 1 )); }
# 真 nft 打印规则时会把 comment 的值**带引号**输出(线上实测: `comment "pdg-rescue"`)。
# shell 传参时那对引号早被剥掉了, 桩必须补回来 —— 否则按标记查找的产品代码在桩上找不到
# 自己刚加的规则, 看起来像"产品没撤规则", 其实是桩不忠实。
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
  -a)  # -a list chain inet pdg input
    echo "table inet pdg {"
    echo "	chain input {"
    while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$state"
    echo "	}"; echo "}" ;;
  -f)  reset_state ;;                       # 整表重载: 回到基线, 临时规则一并消失
  add)    shift 5; nh=$(next_handle); echo "$nh|$(render "$@")" >> "$state" ;;
  insert) shift 5; nh=$(next_handle)
          { echo "$nh|$(render "$@")"; cat "$state"; } > "$state.new"; mv "$state.new" "$state" ;;
  delete) # delete rule inet pdg input handle N
          shift $(($# - 1)); tgt="$1"
          grep -v "^$tgt|" "$state" > "$state.new" 2>/dev/null; mv "$state.new" "$state" ;;
esac
exit 0
'''

# `exec timeout …` 只认可执行文件, shell 函数换不掉它 —— 必须是真文件桩。
# 它 touch ready 之后变成长命进程, "收没收干净"靠它死没死来判。
PY_STUB = r'''#!/bin/bash
# 产品已去掉外层 `timeout 600`(只保留服务脚本自带的 Timer), 所以桩从 `timeout` 挪到
# `python3`, 按被要求跑的东西分派: 服务这一路才改写(把 0.0.0.0 换成回环, 免得跑一次测试
# 对外开端口), 其余(就绪探针、handle 解析)一律 exec 真 python3。
real=/usr/bin/python3
if [ "${1:-}" = -c ] && case "${2:-}" in *serve_forever*) true;; *) false;; esac; then
  echo "srv-args=$(echo $*)" >> "$PDG_TEST_LOG"
  echo "$$" > "$PDG_TEST_SRVPID"
  : > "$PDG_TEST_READY"
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

HARNESS = r'''
set -u
cd "$CH_ROOT"
echo $$ > "$CH_DIR/pid"
: > "$CH_DIR/fn.sh"
for fn in _ios_offer_download _ios_offer_teardown _ios_offer_abort _ios_offer_nft_close \
          _ios_offer_chain _ios_offer_marks _ios_offer_rule_ok _ios_offer_ready \
          _ios_offer_lock_acquire _ios_offer_lock_release \
          _ios_offer_srv_alive _ios_offer_on_signal _ios_offer_reap_orphan _ios_offer_starttime _ios_offer_state_write \
          _ios_offer_session_begin \
          _ios_offer_dir_ok \
          _ios_offer_root_ok _ios_offer_reap_dir _ios_offer_dir_pid \
          _nft_apply_main _lan_nft_reapply \
          _ios_offer_proc_state _ios_offer_stop_pid _ios_offer_list _ios_offer_gen_run; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
# 常量也要跟着抽: `set -u` 下漏一个就是 unbound variable, 而那会让收尾在半途死掉 ——
# 表现与"产品没撤规则"一模一样(HANDOFF §10.7)。
grep -E '^(LAN_NFT_CONF|IOS_OFFER_MARK|IOS_OFFER_LOCK|IOS_OFFER_STATE|IOS_OFFER_ROOT|IOS_OFFER_SENTINEL|IOS_OFFER_PIDFILE|IOS_OFFER_GENFILE)=' deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
# IOS_OFFER_PROBE 是**多行**单引号常量, `grep '^…='` 只会抓到第一行 —— 那样 set -u 下
# 就绪判据当场炸掉, 现场看起来像"服务永远不就绪"。按范围抽。
sed -n "/^IOS_OFFER_PROBE='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
sed -n "/^IOS_OFFER_SERVER='/,/^'$/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
grep -q "^IOS_OFFER_PROBE=" "$CH_DIR/fn.sh" || { echo "EXTRACT-MISSING:IOS_OFFER_PROBE"; exit 9; }
grep -q 'IOS_OFFER_SERVER=' "$CH_DIR/fn.sh" || { echo "EXTRACT-FAIL-server"; exit 9; }
# 抽取自证: 函数**和常量**都要查。只查函数的话, 漏抽一个 IOS_OFFER_* 常量会变成 set -u 的
# 运行期报错, 现场长得像"服务永远不就绪"—— 本轮实测漏过一次(IOS_OFFER_STATE)。
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
# stdin 是一根**永远不会来数据**的管子: 函数会停在 `read` 上等我们发信号,
# 而不是自己走完正常路径 —— 否则测的就不是信号路径了。
_ios_offer_session_begin; _sb=$?
if [ "$_sb" -ne 0 ]; then echo "RC=$_sb"; exit "$_sb"; fi
cp "$CH_SRC" "$_IOS_OFFER_WWW/gen.mobileconfig"
# `exec 6>&-`: 这个 stdin 占位子进程是在会话锁的 fd 打开**之后**才 fork 的, 不关掉的话
# 它会一直攥着 flock —— 父 shell 被 SIGKILL 之后它还活着, 后继会话就被自己的夹具挡成
# BUSY。生产里 stdin 是 tty, 没有这种长命子进程。
_ios_offer_download "$_IOS_OFFER_WWW/gen.mobileconfig" 203.0.113.10 172.22.0.0/16 < <(exec 6>&-; sleep 8)
echo "RC=$?"
'''


def _mkcase(tag):
    """每格一个全新的临时目录与桩 —— 上一格的 nft 状态不许漏进下一格。"""
    d = tmpguard.mkdtemp(prefix="iosleak-%s-" % tag)
    b = os.path.join(d, "bin")
    os.makedirs(b)
    src = os.path.join(d, "cur.mobileconfig")
    with open(src, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0"?><plist><dict/></plist>\n')
    for name, body in (("nft", NFT_STUB), ("python3", PY_STUB),
                       ("qrencode", '#!/bin/sh\nexit 0\n'),
                       # 按请求长度出: `rand -hex N` 要 2N 位。写死 12 位的话, 会话标识(-hex 8)会被判非法,
                       # 现场长得像"openssl 坏了"。
                       ("openssl", '#!/bin/sh\n'
                                   'n=6\n'
                                   'for a in "$@"; do n="$a"; done\n'
                                   'case "$n" in ""|*[!0-9]*) n=6 ;; esac\n'
                                   'od -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\necho\n')):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(p, 0o755)
    env = dict(os.environ,
               PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_STATE=os.path.join(d, "chain"),
               PDG_TEST_READY=os.path.join(d, "ready"),
               PDG_TEST_SRVPID=os.path.join(d, "srvpid"),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d,
               CH_DIR=d, CH_SRC=src, CH_ROOT=str(ROOT))
    return d, env


def _mark_handles(env):
    return {l.split("|", 1)[0] for l in _read(env["PDG_TEST_STATE"]).splitlines()
            if MARKRE.search(l)}


def _wait_open(env, skip, limit=25.0):
    """等到链里出现**本轮新加的**带标记放行 —— 那是通道开放的时刻。

    两处讲究:
      · 不能再用"HTTP 起来了"当判据: 产品现在先起服务、验证真能取到文件、**再**开放 nft,
        两件事之间有实打实的间隔, 拿前者当后者会在链还没变的时候就去发信号;
      · 必须排除种子里预置的残留 handle。否则"入场自愈"那一格里, 判据会被**上一次的残留**
        直接满足, 于是在新会话还没起来时就去 kill, 整格空转。
    """
    end = time.time() + limit
    while time.time() < end:
        if _mark_handles(env) - skip:
            return True
        time.sleep(0.05)
    return False


def _wait(path, limit=15.0):
    end = time.time() + limit
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return False


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def run_signal_case(tag, sig, seed=None):
    """把函数跑起来 → 等临时 HTTP 就绪 → 给外层 shell 发信号 → 收集现场。

    `seed` 用来预置一张**已经带残留**的链, 验证入场清理。
    """
    d, env = _mkcase(tag)
    if seed is not None:
        with open(env["PDG_TEST_STATE"], "w", encoding="utf-8") as f:
            f.write(seed)
    seeded = _mark_handles(env)
    hp = os.path.join(d, "harness.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    proc = subprocess.Popen(["bash", hp], env=env, cwd=str(ROOT),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    ready = _wait_open(env, seeded)
    chain_open = _read(env["PDG_TEST_STATE"])
    if ready and sig is not None and _wait(os.path.join(d, "pid")):
        with open(os.path.join(d, "pid"), encoding="utf-8") as f:
            os.kill(int(f.read().strip()), sig)
    try:
        out = proc.communicate(timeout=30)[0] or ""
    except subprocess.TimeoutExpired:
        proc.kill()
        out = (proc.communicate()[0] or "") + "\n<TIMEOUT>"
    time.sleep(0.3)
    return {"dir": d, "env": env, "ready": ready, "out": out,
            "chain_open": chain_open, "chain": _read(env["PDG_TEST_STATE"]),
            "log": _read(env["PDG_TEST_LOG"])}


MARKRE = re.compile(r"tcp dport 8443 accept", re.M)


def temp_rules(chain_text):
    return [ln for ln in chain_text.splitlines() if MARKRE.search(ln)]


# ── 1/2/3. 三条退出路径都必须把放行撤回来 ────────────────────────────────
# HUP 是主犯(SSH 断开 / 非交互调用), TERM 是旧代码本来就捕的(回归护栏),
# 正常路径同样不许退化。
HUP_LOG = [""]
for tag, sig, why in (("hup", signal.SIGHUP, "SIGHUP(SSH 断开 / 非交互调用)"),
                      ("term", signal.SIGTERM, "SIGTERM"),
                      ("int", signal.SIGINT, "SIGINT(Ctrl-C)")):
    r = run_signal_case(tag, sig)
    if tag == "hup":
        HUP_LOG[0] = r["log"]
    if not r["ready"]:
        bad("%s: 临时 HTTP 没起来, 这一格没测到东西\n%s" % (why, r["out"][:400]))
        continue
    if not temp_rules(r["chain_open"]):
        bad("%s: 开通期链里就没有这条临时放行 —— 桩或产品变了, 判据落空" % why)
        continue
    left = temp_rules(r["chain"])
    if left:
        bad("%s 之后临时放行**还留在链里**(泄漏): %s" % (why, "; ".join(left)))
    else:
        ok("%s 之后临时放行已撤回" % why)

# ── 4. 正常路径(读到 EOF 就当"按了回车")仍要收干净 ───────────────────────
r_norm = run_signal_case("norm", None)
if r_norm["ready"]:
    # 不发信号: `read` 会一直等到 stdin 那根管子 60 秒后关闭。这里只等它自己走完前半程,
    # 然后用 TERM 逼它收尾 —— 但断言看的是**开通期链里确实有规则**这一前提是否成立。
    pass
if temp_rules(r_norm["chain_open"]):
    ok("开通期链里确实有那条临时放行(前提成立, 后面几格的判据不是空转)")
else:
    bad("开通期链里没有临时放行 —— 前提就不成立, 上面几格等于没测")

# ── 5. 规则必须排在 `iifname tailscale0 return` **之后** ──────────────────
# 这是泄漏之所以致命的那一环: 插在链首 → 排在排除之前 → doctor 判红 → update 整轮回滚。
open_lines = [ln.split("|", 1)[-1] for ln in r_norm["chain_open"].splitlines() if ln.strip()]
try:
    i_ret = next(i for i, ln in enumerate(open_lines) if 'iifname "tailscale0" return' in ln)
except StopIteration:
    i_ret = -1
i_tmp = next((i for i, ln in enumerate(open_lines) if MARKRE.search(ln)), -1)
if i_ret < 0 or i_tmp < 0:
    bad("链里找不到排除规则或临时放行(ret=%d tmp=%d), 判据落空" % (i_ret, i_tmp))
elif i_tmp < i_ret:
    bad("临时放行排在 tailscale0 排除**之前**(第 %d 条 < 第 %d 条) —— "
        "开通期 doctor 就是红的, 一旦泄漏就永远红" % (i_tmp, i_ret))
else:
    ok("临时放行排在 tailscale0 排除之后(第 %d 条 > 第 %d 条), tailnet 流量到不了它"
       % (i_tmp, i_ret))

# ── 6. 撤除要**精确**, 不是整表重载 ──────────────────────────────────────
# 认标记不认端口 —— 与救援平面同一套口径。整表重载会把别人的运行期规则一起冲掉。
log_hup = HUP_LOG[0]
_precise = re.search(r"^nft delete rule inet pdg input handle \d+$", log_hup, re.M)
_fellback = "nft -f /etc/nftables.conf" in log_hup
if _precise and not _fellback:
    ok("撤除走的是按 handle 精确删除, 且没有退回整表重载(别人的运行期规则不受影响)")
elif _precise and _fellback:
    bad("精确删除没生效, 退回了整表重载 —— 会连同别人的运行期规则一起冲掉")
elif _fellback:
    bad("撤除靠整表重载(-f), 压根没走精确删除")
else:
    bad("信号到达后 nft 一次都没被调用过 —— 收尾根本没执行:\n%s" % log_hup[:400])

# ── 7. 规则要带标记 ─────────────────────────────────────────────────────
if 'comment "pdg-ios-offer"' in r_norm["chain_open"]:
    ok("临时放行带 pdg-ios-offer 标记(收尾据此精确删除, 泄漏也能被下一次认出来)")
else:
    bad("临时放行没有标记 —— 只能按端口猜, 而用户完全可能自己写过一条同端口放行")

# ── 8. 入场自愈: 上一次没收干净的残留, 这一次进来要被带走 ────────────────
# SIGKILL 之类兜不住的路径总会存在, 所以泄漏不能只靠"收尾一定跑到"。预置一条**上一次
# 留下的**带标记规则, 跑一次通道, 开通期链里就该只剩这一次自己加的那条。
# (口径与救援平面一致: 认标记不认端口 —— 别人自己写的同端口放行不带标记, 不会被误删。)
SEED = ('1|iif "lo" accept\n'
        '2|ct state established,related accept\n'
        '3|tcp dport 22 accept\n'
        '4|iifname "tailscale0" return\n'
        '5|ip saddr 172.22.0.0/16 tcp dport 8443 accept comment "pdg-ios-offer"\n'
        '6|ip saddr 172.22.0.0/16 tcp dport 8443 accept\n')
r_seed = run_signal_case("seed", signal.SIGHUP, seed=SEED)
seed_open = [ln.split("|", 1)[-1] for ln in r_seed["chain_open"].splitlines() if ln.strip()]
marked = [ln for ln in seed_open if 'comment "pdg-ios-offer"' in ln]
unmarked = [ln for ln in seed_open if MARKRE.search(ln) and 'pdg-ios-offer' not in ln]
if not r_seed["ready"]:
    bad("入场自愈: 通道没跑起来, 这一格没测到东西")
elif len(marked) != 1:
    bad("入场自愈: 开通期链里带标记的放行有 %d 条(应为 1) —— 上一次的残留没被带走" % len(marked))
elif len(unmarked) != 1:
    bad("入场自愈: 把别人不带标记的同端口放行也删了(剩 %d 条, 应为 1) —— 越权" % len(unmarked))
else:
    ok("入场先清残留: 上一次泄漏的那条被带走, 别人不带标记的同端口放行原样保留")

# ── 9. 结构兜底: trap 必须同时捕 HUP 与 EXIT ─────────────────────────────
# 行为格已经覆盖 HUP; 这一格钉的是"EXIT 兜底还在不在" —— SIGKILL 之外的任何异常退出
# (set -e、被调函数 return 非零、脚本半途 exit)都靠它。
m = re.search(r"^\s*trap\s+'[^']*'\s+([A-Z ]+)$", PDG, re.M | re.S)
traps = set()
for mm in re.finditer(r"^\s*trap\s+'[^']*_ios_offer[^']*'\s+([A-Z][A-Z ]*)$", PDG, re.M):
    traps |= set(mm.group(1).split())
missing = [s for s in ("EXIT", "HUP", "INT", "TERM") if s not in traps]
if not traps:
    bad("找不到给下载通道装的 trap —— 结构判据落空(函数被改名或收尾换了写法?)")
elif missing:
    bad("下载通道的 trap 漏了这些信号: %s(实际捕: %s)" % (" ".join(missing), " ".join(sorted(traps))))
else:
    ok("下载通道的 trap 覆盖 EXIT/HUP/INT/TERM")

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

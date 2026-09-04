#!/usr/bin/env python3
"""iOS 临时下载通道: **会话目录所有权** —— 经由真实调用方的行为验证。

前几轮把通道函数本身收干净了。这一支从**调用方**进去(`cmd_ios` / `cmd_ios_previous`),
因为只有走真实入口才会出现第二个目录: 调用方自己的 staging。三个缺口:

  1. **staging 不在所有权记录里。** state 只记 www。父 shell 被 SIGKILL 之后, 后继会话按
     记录收掉了 www, 而 staging 里那份**同样是描述文件**的产物没人认领 —— 每被强杀一次
     就在盘上多留一份带 DoT 主机名与根证书的文件, 而后继会话报告 rc=0。
  2. **PID 一消失, 线索就被删掉。** HTTP 自己的 600 秒超时到了之后, state 里的 PID 已经
     不存在。当前回收流程在这种情形下把 state 删了却不动目录 —— 于是目录永远留着, 而唯一
     能证明它属于本功能的记录已经没了。
  3. **state 删不掉被 `|| true` 吞掉。** 收尾与回收两条路径都是如此: 记录还在盘上, 返回码
     却是 0, 下一次会话会拿着一份过期记录去做身份核对。

判据全是行为的: 真起服务、真 SIGKILL、真造过期现场、真让 unlink 失败。
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
st="$PDG_TEST_CHAIN"
if [ ! -s "$st" ]; then cat > "$st" <<'BASE'
1|iif "lo" accept
4|iifname "tailscale0" return
BASE
fi
echo "nft $*" >> "$PDG_TEST_LOG"
render(){ local a out="" q=0
  for a in "$@"; do
    if [ "$q" = 1 ]; then out="$out \"$a\""; q=0
    else out="$out $a"; [ "$a" = comment ] && q=1; fi
  done; echo "${out# }"; }
next_handle(){ echo $(( $(cut -d'|' -f1 "$st" | sort -n | tail -1) + 1 )); }
if [ "$1" = -j ] && [ "$2" = --echo ]; then
  shift 3; verb="$1"; shift 5
  nh=$(next_handle)
  if [ "$verb" = insert ]; then { echo "$nh|$(render "$@")"; cat "$st"; } > "$st.n"; mv "$st.n" "$st"
  else echo "$nh|$(render "$@")" >> "$st"; fi
  printf "{\"nftables\":[{\"add\":{\"rule\":{\"handle\":%s}}}]}\n" "$nh"
  exit 0
fi
case "$1" in
  -a) echo "table inet pdg {"; echo "	chain input {"
      while IFS='|' read -r h r; do [ -n "$h" ] && echo "		$r # handle $h"; done < "$st"
      echo "	}"; echo "}" ;;
  delete) shift $(($# - 1)); grep -v "^$1|" "$st" > "$st.n" 2>/dev/null; mv "$st.n" "$st" ;;
esac
exit 0
'''

# python3 桩: 按用途分派。产品用它跑三样东西 —— iosstate 生成、临时 HTTP 服务、就绪探针
# 与 handle 解析。只有"服务"这一路需要改写(把 0.0.0.0 换成回环, 免得跑一次测试对外开端口),
# 其余一律 exec 真 python3。**不再桩 timeout**: 真实 GNU timeout 在场, 父子进程拓扑才是真的。
PY_STUB = r'''#!/bin/bash
real=/usr/bin/python3
if [ "${1:-}" = "$CH_DIR/iosstate.py" ]; then
  echo "iosstate $*" >> "$PDG_TEST_LOG"
  out=""; prev=""
  for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
  echo "out-target $out" >> "$PDG_TEST_LOG"
  [ "$(dirname "$out")" = "/" ] && { echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1; }
  printf '%s' "$PDG_TEST_BODY" > "$out"
  exit 0
fi
if [ "${1:-}" = -c ] && case "${2:-}" in *serve_forever*) true;; *) false;; esac; then
  echo "srv-invoked" >> "$PDG_TEST_SRVLOG"
  echo "$$" >> "$PDG_TEST_SRVPID"
  [ "${PDG_TEST_SRV_MODE:-serve}" = instant ] && exit 1
  args=(); for a in "$@"; do [ "$a" = 0.0.0.0 ] && a=127.0.0.1; args+=("$a"); done
  exec "$real" "${args[@]}"
fi
exec "$real" "$@"
'''

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
"$CH_FN" ${CH_ARG:+"$CH_ARG"} < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>session</key></dict></plist>\n'


def mkcase(tag, fn="cmd_ios", **env_extra):
    d = tmpguard.mkdtemp(prefix="iossess-%s-" % tag)
    b = os.path.join(d, "bin")
    os.makedirs(b)
    os.makedirs(os.path.join(d, "st"))
    with open(os.path.join(d, "tmpl.mobileconfig"), "w", encoding="utf-8") as f:
        f.write("<plist/>\n")
    with open(os.path.join(d, "iosstate.py"), "w", encoding="utf-8") as f:
        f.write("# stub\n")
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB),
                    ("openssl", '#!/bin/sh\n# 按请求长度出: `rand -hex N` 要 2N 位十六进制。写死 12 位的话, 会话标识(-hex 8)\n# 会被产品判成非法, 现场长得像"openssl 坏了"。\nn=$(eval echo \\$$#)\ncase "$n" in ""|*[!0-9]*) n=6 ;; esac\nod -An -N"$n" -tx1 /dev/urandom | tr -d " \\n"\necho\n'),
                    ("qrencode", '#!/bin/sh\nexit 0\n')):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(s)
        os.chmod(p, 0o755)
    env = dict(os.environ,
               PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"),
               PDG_TEST_SRVLOG=os.path.join(d, "srvlog"),
               PDG_TEST_SRVPID=os.path.join(d, "srvpid"),
               PDG_TEST_CHAIN=os.path.join(d, "chain"),
               PDG_TEST_BODY=BODY.decode(),
               PDG_IOS_OFFER_LOCKFILE=os.path.join(d, "offer.lock"),
               PDG_IOS_OFFER_STATEFILE=os.path.join(d, "st", "offer.state"),
               PDG_IOS_OFFER_ROOT=os.path.join(d, "offerroot"),
               TMPDIR=d, CH_DIR=d, CH_ROOT=str(ROOT), CH_FN=fn)
    env.update({k: str(v) for k, v in env_extra.items()})
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
        proc.kill()
        proc.wait(timeout=10)
    time.sleep(0.3)
    out = read(os.path.join(d, "out"))
    m = re.search(r"^RC=(\d+)$", out, re.M)
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None,
            "status": proc.returncode, "log": read(os.path.join(d, "log")),
            "marks": read(os.path.join(d, "chain")).count('comment "pdg-ios-offer"')}


def shows_link(o):
    return "  链接: http://" in o


def connectable(t=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=t)
        s.close()
        return True
    except OSError:
        return False


def wait_for(fn, limit=30.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False


def session_dirs(d):
    """固定安全父目录下的会话目录 —— 一轮应当**恰好一个**。"""
    root = os.path.join(d, "offerroot")
    if not os.path.isdir(root):
        return []
    return [os.path.join(root, n) for n in sorted(os.listdir(root))
            if os.path.isdir(os.path.join(root, n))]


def stray_dirs(d):
    """沙箱里 mktemp 风格的散装目录。调用方一旦另建 staging 就会出现在这里 ——
    合并成一个会话目录之后, 它必须是空的: 那正是"第二个没人认领的目录"消失的证据。"""
    return [os.path.join(d, n) for n in sorted(os.listdir(d))
            if n.startswith("tmp.") and os.path.isdir(os.path.join(d, n))]


def tmpdirs(d):
    return session_dirs(d) + stray_dirs(d)


def alive(pids):
    return [p for p in pids if os.path.exists("/proc/%d" % p)]


def srvpids(d):
    return [int(x) for x in read(os.path.join(d, "srvpid")).split() if x.isdigit()]


def kill_all(pids, sig=signal.SIGKILL):
    for p in pids:
        try:
            os.kill(p, sig)
        except OSError:
            pass


if connectable():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)


def sigkill_preimage(tag, fn, arg=None):
    """经真实调用方开通道 → 采前像 → SIGKILL 父 shell。返回前像。"""
    kw = {"CH_STDIN_HOLD": 60}
    if arg:
        kw["CH_ARG"] = arg
    d, env = mkcase(tag, fn=fn, **kw)
    p = launch(d, env)
    ready = wait_for(lambda: shows_link(read(os.path.join(d, "out"))))
    pre = {"dir": d, "env": env, "ready": ready, "proc": p}
    if ready:
        pre["dirs"] = tmpdirs(d)
        pre["srv"] = alive(srvpids(d))
        pre["port"] = connectable()
        pre["marks"] = read(os.path.join(d, "chain")).count('comment "pdg-ios-offer"')
        pre["state"] = os.path.exists(env["PDG_IOS_OFFER_STATEFILE"])
        try:
            os.kill(int(read(os.path.join(d, "pid")).strip()), signal.SIGKILL)
        except (OSError, ValueError):
            pass
        p.wait(timeout=20)
        time.sleep(0.4)
    return pre


def successor(pre, tag, **kw):
    d, env = mkcase(tag, CH_STDIN_HOLD=1, **kw)
    for k in ("PDG_TEST_CHAIN", "PDG_IOS_OFFER_LOCKFILE",
              "PDG_IOS_OFFER_STATEFILE", "PDG_IOS_OFFER_ROOT"):
        env[k] = pre["env"][k]
    return finish(launch(d, env), d, limit=60)


# ── 组 1: 真实调用方的 staging 也必须被后继会话收走 ───────────────────────
for fn, arg, why in (("cmd_ios", None, "pdg ios"),
                     ("cmd_ios_previous", None, "pdg ios previous")):
    pre = sigkill_preimage("g1-" + fn, fn, arg)
    try:
        if not pre["ready"]:
            bad("%s: 通道没就绪, 这一组没测到东西\n%s"
                % (why, read(os.path.join(pre["dir"], "out"))[:400]))
            continue
        sess = [x for x in pre["dirs"] if os.sep + "offerroot" + os.sep in x]
        stray = [x for x in pre["dirs"] if x not in sess]
        print("       %s 前像: 会话目录=%s | 散装 staging=%s | HTTP=%s | 8443=%s | 标记=%d | state=%s"
              % (why, [os.path.basename(x) for x in sess] or "无",
                 [os.path.basename(x) for x in stray] or "无",
                 pre["srv"] or "无", pre["port"], pre["marks"], pre["state"]))
        if len(sess) != 1 or not pre["srv"] or not pre["port"] \
                or pre["marks"] != 1 or not pre["state"]:
            bad("%s 前像不成立(会话目录 %d 个, 期望恰好 1; HTTP=%s 端口=%s 标记=%d state=%s)"
                % (why, len(sess), pre["srv"], pre["port"], pre["marks"], pre["state"]))
            continue
        if stray:
            bad("%s: 调用方另建了 staging(%s) —— 一轮应当只有一个会话目录"
                % (why, [os.path.basename(x) for x in stray]))
            continue
        r = successor(pre, "g1s-" + fn)
        left = [x for x in pre["dirs"] if os.path.isdir(x)]
        probs = []
        if left:
            probs.append("旧目录仍在: %s" % [os.path.basename(x) for x in left])
        if r["rc"] != 0:
            probs.append("后继会话没能开通(rc=%s)" % r["rc"])
        if probs:
            bad("%s 被 SIGKILL 之后: %s" % (why, "; ".join(probs)))
        else:
            ok("%s 被 SIGKILL 之后: 后继会话把 WWW 与 staging 一并收走, 自己也开通并收干净" % why)
    finally:
        kill_all(srvpids(pre["dir"]))
        wait_for(lambda: not connectable(), limit=10)


# ── 组 1b: 进程拓扑 —— 记录里的 PID 就是真正听端口的那一个, 且没有子进程 ────────
# 外层套 `timeout 600` 的话, 记录下来的是 timeout 的 PID、真正听端口的是它的子进程:
# 身份核对与"停没停干净"就分在两层, 而遗留子进程正是 SIGKILL 之后收不干净的来源。
d1b, env1b = mkcase("topo", CH_STDIN_HOLD=40)
p1b = launch(d1b, env1b)
ready1b = wait_for(lambda: shows_link(read(os.path.join(d1b, "out"))))
try:
    if not ready1b:
        bad("进程拓扑: 通道没就绪, 这一格没测到东西")
    else:
        rec = re.search(r"^pid=(\d+)$", read(env1b["PDG_IOS_OFFER_STATEFILE"]), re.M)
        rec_pid = int(rec.group(1)) if rec else 0
        stub_pids = srvpids(d1b)
        kids = []
        if rec_pid:
            try:
                kids = [x for x in read("/proc/%d/task/%d/children" % (rec_pid, rec_pid)).split()]
            except Exception:
                kids = []
        probs = []
        if rec_pid not in stub_pids:
            probs.append("记录里的 PID %s 不是真正起服务的那个 %s" % (rec_pid, stub_pids))
        if kids:
            probs.append("它还有子进程 %s —— 收尾要跨两层" % kids)
        if probs:
            bad("进程拓扑: " + "; ".join(probs))
        else:
            ok("进程拓扑: 记录里的 PID(%d)就是真正听端口的那个, 且没有子进程" % rec_pid)
finally:
    try:
        os.kill(int(read(os.path.join(d1b, "pid")).strip()), signal.SIGTERM)
    except (OSError, ValueError):
        pass
    finish(p1b, d1b, limit=40)
    kill_all(srvpids(d1b))
    wait_for(lambda: not connectable(), limit=10)

# ── 组 2: PID 已经不在的过期孤儿 ──────────────────────────────────────────
# 模拟 HTTP 自己的 600 秒超时到点退出: state 里的 PID 已经不存在。这时不能再靠"进程还活着"
# 去证明目录属于本功能 —— 需要目录自身带得走的凭据。
pre = sigkill_preimage("g2", "cmd_ios")
try:
    if not pre["ready"]:
        bad("过期孤儿: 前像没建立起来, 这一组没测到东西")
    else:
        kill_all(pre["srv"])                      # ← 模拟 600 秒超时自退, 不是替产品清场
        wait_for(lambda: not alive(pre["srv"]), limit=10)
        wait_for(lambda: not connectable(), limit=10)
        print("       过期前像: 目录=%d 个 | HTTP 存活=%s | state=%s"
              % (len(pre["dirs"]), alive(pre["srv"]) or "无",
                 os.path.exists(pre["env"]["PDG_IOS_OFFER_STATEFILE"])))
        r = successor(pre, "g2s")
        left = [x for x in pre["dirs"] if os.path.isdir(x)]
        probs = []
        if left:
            probs.append("旧目录仍在: %s" % [os.path.basename(x) for x in left])
        if os.path.exists(pre["env"]["PDG_IOS_OFFER_STATEFILE"]):
            probs.append("state 没清")
        if r["marks"]:
            probs.append("链里仍有 %d 条标记" % r["marks"])
        if r["rc"] != 0:
            probs.append("后继会话没能开通(rc=%s)" % r["rc"])
        if probs:
            bad("PID 已消失的过期孤儿: " + "; ".join(probs))
        else:
            ok("PID 已消失的过期孤儿 → 目录与 state 全部清零, 后继会话正常开通并收尾")
finally:
    kill_all(srvpids(pre["dir"]))
    wait_for(lambda: not connectable(), limit=10)


# ── 组 2b: 会话凭据对不上的目录, 一律不动 ────────────────────────────────
# 造一个**形态完全合规**的目录: 就在固定安全父目录之下、0700、带 0600 的凭据、里面只有
# 描述文件 —— 只有凭据内容与记录里的 session id 不一致。这一格问的就是那一条: 归属靠凭据
# 证明, 不靠"看起来像我们建的"。
d2b, env2b = mkcase("sentinel", CH_STDIN_HOLD=1)
root2b = env2b["PDG_IOS_OFFER_ROOT"]
os.makedirs(root2b, mode=0o700, exist_ok=True)
victim = os.path.join(root2b, "s.deadbeefdeadbeef")
os.makedirs(victim, mode=0o700)
with open(os.path.join(victim, ".pdg-offer-session"), "w", encoding="utf-8") as f:
    f.write("ffffffffffffffff")          # ← 与记录里的 sid 不同
os.chmod(os.path.join(victim, ".pdg-offer-session"), 0o600)
with open(os.path.join(victim, "aaaaaaaaaaaa.mobileconfig"), "w", encoding="utf-8") as f:
    f.write("<plist/>\n")
with open(env2b["PDG_IOS_OFFER_STATEFILE"], "w", encoding="utf-8") as f:
    f.write("sid=deadbeefdeadbeef\npid=999999\nstart=1\nwww=%s\n" % victim)
r2b = finish(launch(d2b, env2b), d2b)
probs = []
if not os.path.isdir(victim):
    probs.append("目录被删了")
if r2b["rc"] in (None, 0):
    probs.append("返回 %s(证不明归属就该 fail-closed)" % r2b["rc"])
if not os.path.exists(env2b["PDG_IOS_OFFER_STATEFILE"]):
    probs.append("记录被覆盖/删除了")
if probs:
    bad("会话凭据不一致: " + "; ".join(probs))
else:
    ok("会话凭据不一致 → 目录不动、记录不动、本次会话 fail-closed")
wait_for(lambda: not connectable(), limit=10)

# ── 组 3: state 删不掉必须计入返回码 ──────────────────────────────────────
# 3a 正常收尾路径
d3, env3 = mkcase("g3-teardown", CH_STDIN_HOLD=40)
p3 = launch(d3, env3)
ready3 = wait_for(lambda: shows_link(read(os.path.join(d3, "out"))))
stdir = os.path.dirname(env3["PDG_IOS_OFFER_STATEFILE"])
try:
    if not ready3:
        bad("state 删除失败(收尾路径): 通道没就绪, 这一格没测到东西")
    else:
        os.chmod(stdir, 0o500)                    # 目录只读 → unlink 必失败
        try:
            os.kill(int(read(os.path.join(d3, "pid")).strip()), signal.SIGTERM)
        except (OSError, ValueError):
            pass
        r3 = finish(p3, d3)
        os.chmod(stdir, 0o700)
        probs = []
        if "已关闭临时下载服务" in r3["out"]:
            probs.append("仍打印「已关闭临时下载服务」")
        if not re.search(r"state|所有权记录", r3["out"]):
            probs.append("没点名 state 未清除")
        if r3["marks"]:
            probs.append("nft 标记没收(%d 条)" % r3["marks"])
        if connectable():
            probs.append("HTTP 没收")
        if probs:
            bad("收尾时 state 删不掉: %s" % "; ".join(probs))
        else:
            ok("收尾时 state 删不掉 → 不声称已关闭、点名 state 未清除, HTTP 与 nft 仍尽力收净")
finally:
    try:
        os.chmod(stdir, 0o700)
    except OSError:
        pass
    kill_all(srvpids(d3))
    wait_for(lambda: not connectable(), limit=10)

# 3b 孤儿回收路径。
# **直接单独调用回收函数**, 不跑整条会话: 只读目录同时挡住 state 的写入, 整条会话会在
# `_ios_offer_state_write` 就 abort, 那条文案里也带着 state 路径 —— 判据会被它命中, 于是
# "删除失败"这一格实际上测的是"写入失败"。隔离出来才问得准。
d3b, env3b = mkcase("g3-reap", fn="_ios_offer_reap_orphan", CH_STDIN_HOLD=1)
stdir_b = os.path.dirname(env3b["PDG_IOS_OFFER_STATEFILE"])
with open(env3b["PDG_IOS_OFFER_STATEFILE"], "w", encoding="utf-8") as f:
    f.write("pid=999999\nstart=1\nwww=%s\n" % os.path.join(d3b, "gone"))
os.chmod(stdir_b, 0o500)
r3b = finish(launch(d3b, env3b), d3b)
os.chmod(stdir_b, 0o700)
probs = []
if r3b["rc"] in (None, 0):
    probs.append("返回 %s" % r3b["rc"])
if not re.search(r"state|所有权记录", r3b["out"]):
    probs.append("没点名 state 未清除")
if os.path.exists(env3b["PDG_IOS_OFFER_STATEFILE"]):
    pass          # 删不掉本来就是这一格构造的前提, 不算问题
else:
    probs.append("state 居然被删掉了 —— 这一格的前提没造出来")
if probs:
    bad("回收时 state 删不掉: %s" % "; ".join(probs))
else:
    ok("回收时 state 删不掉 → 非零退出并点名 state 未清除")
wait_for(lambda: not connectable(), limit=10)

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

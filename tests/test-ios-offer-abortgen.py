#!/usr/bin/env python3
"""iOS 临时下载通道: **本轮收尾必须停住自己的描述文件生成器** —— 行为验证。

孤儿回收那一侧已经会处理生成者了(认身份、停住、再删目录)。缺的是**当前会话自己的收尾**:
普通信号进来时, teardown 只停 HTTP、撤 nft、删目录, 从不碰仍在跑的生成器。于是

    收到 HUP/INT/TERM → shell 以 129/130/143 退出, 目录与 state 都删了
    → 生成器随后才落笔 → atomic_write 把父目录一起重建
    → 盘上留下一个**没有 sentinel** 的壳 → 下一次回收据此拒绝启动

退出码是对的, 现场却是脏的 —— 只验退出码看不出任何问题。

屏障放在**生成者已登记、实际输出尚未写入**那一刻(等目录里的凭据出现 `pid=` 才算登记完成),
断言之前不人工结束生成器、不等它自然跑完、不清理目录。写出路径保留真实的
"mkdir -p 父目录 + 落盘", 只是产物与元数据都在隔离沙箱里。
"""
import os, re, signal, socket, subprocess, sys, time
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

# 生成器桩: 亮相 → 等测试放行 → 才真正落盘(连父目录一起建回来, 与 atomic_write 同形)。
PY_STUB = r'''#!/bin/bash
real=/usr/bin/python3
if [ "${1:-}" = "$CH_DIR/iosstate.py" ]; then
  out=""; prev=""
  for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
  [ "$(dirname "$out")" = "/" ] && { echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1; }
  if [ "${PDG_TEST_BARRIER:-}" = gen ]; then
    echo "$$" > "$CH_DIR/genpid"; : > "$CH_DIR/gen-started"
    n=0
    while [ ! -e "$CH_DIR/gen-release" ] && [ "$n" -lt 900 ]; do sleep 0.1; n=$((n+1)); done
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
          _nft_apply_main _lan_nft_reapply; do
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
"$CH_FN" < <(exec 6>&-; sleep "${CH_STDIN_HOLD:-8}")
echo "RC=$?"
echo "REACHED-END"
'''

BODY = b'<?xml version="1.0"?><plist><dict><key>abortgen</key></dict></plist>\n'


def mkcase(tag, fn="cmd_ios", **extra):
    d = tmpguard.mkdtemp(prefix="iosag-%s-" % tag)
    b = os.path.join(d, "bin"); os.makedirs(b); os.makedirs(os.path.join(d, "st"))
    for n, c in (("tmpl.mobileconfig", "<plist/>\n"), ("iosstate.py", "# stub\n")):
        with open(os.path.join(d, n), "w", encoding="utf-8") as f:
            f.write(c)
    for name, s in (("nft", NFT_STUB), ("python3", PY_STUB),
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


def launch(d, env, own_group=False):
    hp = os.path.join(d, "h.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    o = open(os.path.join(d, "out"), "w", encoding="utf-8")
    return subprocess.Popen(["bash", hp], env=env, cwd=str(ROOT), stdout=o,
                            stderr=subprocess.STDOUT, text=True,
                            start_new_session=own_group)


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
            "status": proc.returncode, "reached_end": "REACHED-END" in out}


def wait_for(fn, limit=30.0):
    end = time.time() + limit
    while time.time() < end:
        if fn():
            return True
        time.sleep(0.03)
    return False


def alive(p):
    return os.path.exists("/proc/%d" % p)


def connectable(t=1.0):
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=t); s.close(); return True
    except OSError:
        return False


def sess_dirs(env):
    r = env["PDG_IOS_OFFER_ROOT"]
    return [os.path.join(r, n) for n in sorted(os.listdir(r))] if os.path.isdir(r) else []


def gen_registered(env):
    """生成者已登记 = 会话目录里的凭据已经从 pending 变成了带 pid 的形态。"""
    for d in sess_dirs(env):
        if re.search(r"^pid=[0-9]+$", read(os.path.join(d, ".pdg-offer-gen")), re.M):
            return True
    return False


if connectable():
    bad("环境前提不成立: 127.0.0.1:%d 已被占用" % PORT)
    print("\n%d passed, %d failed" % (PASS[0], FAIL[0])); sys.exit(1)
ok("环境前提: 127.0.0.1:%d 空闲" % PORT)

SIGS = (("HUP", signal.SIGHUP, 129), ("INT", signal.SIGINT, 130), ("TERM", signal.SIGTERM, 143))

for fn, why in (("cmd_ios", "pdg ios"), ("cmd_ios_previous", "pdg ios previous")):
    for signame, signum, want_status in SIGS:
        for group in (False, True) if signame == "INT" else (False,):
            label = "%s / SIG%s%s" % (why, signame, "(整个进程组)" if group else "")
            d, env = mkcase("%s-%s%s" % (fn, signame, "g" if group else ""),
                            fn=fn, CH_STDIN_HOLD=60, PDG_TEST_BARRIER="gen")
            p = launch(d, env, own_group=group)
            if not (wait_for(lambda: os.path.exists(os.path.join(d, "gen-started")))
                    and wait_for(lambda: gen_registered(env))):
                bad("%s: 屏障没到达「生成者已登记」这一刻, 这一格没测到东西" % label)
                p.kill(); p.wait(timeout=10); continue
            genpid = int(read(os.path.join(d, "genpid")).strip() or 0)
            pre_dirs = sess_dirs(env)
            try:
                if group:
                    os.killpg(os.getpgid(p.pid), signum)
                else:
                    os.kill(int(read(os.path.join(d, "pid")).strip()), signum)
            except (OSError, ValueError):
                pass
            r = finish(p, d, limit=40)
            gen_still = alive(genpid)
            probs = []
            if r["status"] != want_status:
                probs.append("退出状态 %s(应 %d)" % (r["status"], want_status))
            if gen_still:
                probs.append("生成器 %d 仍在跑 —— 收尾没管它" % genpid)
            # 放开屏障, 看它会不会把目录重建回来
            open(os.path.join(d, "gen-release"), "w").close()
            if gen_still:
                wait_for(lambda: os.path.exists(os.path.join(d, "gen-wrote")), limit=25)
            wait_for(lambda: not alive(genpid), limit=15)
            time.sleep(0.3)
            after = sess_dirs(env)
            if after:
                shells = [x for x in after
                          if not os.path.exists(os.path.join(x, ".pdg-offer-session"))]
                probs.append("解除屏障后盘上又出现目录 %s(其中无 sentinel: %s)"
                             % ([os.path.basename(x) for x in after],
                                [os.path.basename(x) for x in shells] or "无"))
            if os.path.exists(env["PDG_IOS_OFFER_STATEFILE"]) and not gen_still:
                probs.append("state 未清")
            # 下一次会话必须能正常开始与结束
            d2, e2 = mkcase("next-%s-%s%s" % (fn, signame, "g" if group else ""),
                            CH_STDIN_HOLD=1)
            for k in ("PDG_TEST_CHAIN", "PDG_IOS_OFFER_LOCKFILE",
                      "PDG_IOS_OFFER_STATEFILE", "PDG_IOS_OFFER_ROOT"):
                e2[k] = env[k]
            r2 = finish(launch(d2, e2), d2, limit=60)
            if r2["rc"] != 0:
                probs.append("下一次会话开不起来(rc=%s)" % r2["rc"])
            if probs:
                bad("%s: %s" % (label, "; ".join(probs)))
            else:
                ok("%s → 退出状态 %d, 生成器已停, 解除屏障后不再出现目录, 下一次会话正常"
                   % (label, r["status"]))
            try:
                os.kill(genpid, signal.SIGKILL)
            except OSError:
                pass
            wait_for(lambda: not connectable(), limit=10)

# 正常生成成功 / 生成失败两条路径不得退化
d3, e3 = mkcase("normal", CH_STDIN_HOLD=1)
r3 = finish(launch(d3, e3), d3, limit=60)
if r3["rc"] == 0 and not sess_dirs(e3):
    ok("生成正常 → 会话开通并收干净(rc=0, 无残留目录)")
else:
    bad("正常路径退化: rc=%s 残留目录=%s" % (r3["rc"], [os.path.basename(x) for x in sess_dirs(e3)]))

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""`pdg ios` / `pdg ios previous` 的会话开场 —— fail-closed 行为验证。

两个调用方以前各自 `STAGE=$(mktemp -d)` 且不看返回码: 失败时 OUT 会算成
`/PrivDNS-Gateway.mobileconfig`, 描述文件(带着这台网关的 DoT 主机名与根证书)被生成到
**文件系统根目录**, 而 `rm -rf ""` 什么也不删。

现在它们改成先调 `_ios_offer_session_begin` —— 取锁、收上一轮残留、在固定安全父目录下建出
本轮**唯一**的会话目录, 生成物直接落进去。于是"第二个没人认领的目录"不再存在, 而这一支
要钉的是新契约: **会话开不起来时必须立刻停**, 不生成、不交出任何路径、不去开通道。

判据是行为的: 真跑两个调用方(依赖用桩顶掉), 让会话开场失败, 看它们有没有继续往下走。
夹具里的 python3 桩拒绝真写沙箱外的路径 —— 跑一次测试不该让这台机器的 / 多出文件。
"""
import os
import re
import subprocess
import sys
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


MKTEMP_STUB = ('#!/bin/sh\n'
               '[ "${PDG_TEST_MKTEMP_FAIL:-}" = 1 ] && { echo "mktemp: failed" >&2; exit 1; }\n'
               'exec /usr/bin/mktemp "$@"\n')

# python3 桩: 记录 iosstate 的调用与 --out 目标; 目标目录是 / 就拒绝真写。
PY_STUB = r'''#!/bin/bash
echo "iosstate $*" >> "$PDG_TEST_LOG"
out=""
prev=""
for a in "$@"; do [ "$prev" = --out ] && out="$a"; prev="$a"; done
if [ -n "$out" ]; then
  echo "out-target $out" >> "$PDG_TEST_LOG"
  if [ "$(dirname "$out")" = "/" ]; then
    echo "REFUSED-ROOT $out" >> "$PDG_TEST_LOG"; exit 1
  fi
  : > "$out"
fi
exit 0
'''

HARNESS = r'''
set -uo pipefail
cd "$CH_ROOT"
: > "$CH_DIR/fn.sh"
for fn in cmd_ios cmd_ios_previous; do
  sed -n "/^$fn()/,/^}/p" deploy/bot/pdg.sh >> "$CH_DIR/fn.sh"
done
grep -q '_ios_offer_session_begin' "$CH_DIR/fn.sh" || { echo "EXTRACT-FAIL-session"; exit 9; }
# 会话内部不是这一支要测的东西, 顶掉它: 成功时给一个本轮目录, 失败注入时直接返回非零。
_ios_offer_session_begin(){
  if [ "${PDG_TEST_SESSION_FAIL:-}" = 1 ]; then
    echo "❌ 会话开场失败(注入)"; return 1
  fi
  _IOS_OFFER_WWW="$(mktemp -d)"; _IOS_OFFER_ACTIVE=1; return 0
}
_ios_offer_teardown(){ rm -rf "${_IOS_OFFER_WWW:-}"; return 0; }
# 调用方现在经 _ios_offer_gen_run 启动生成器(它关锁 fd 并在会话目录里留下生成者身份)。
# 这一格只问调用方的控制流, 所以顶掉它、直接跑命令 —— 不顶的话它是未定义命令,
# 现场长得像"调用方分发错了"。
_ios_offer_gen_run(){ "$@"; }

# 依赖全部顶掉: 这一支只问"staging 失败之后调用方做了什么", 不牵扯真实平台门控与真实生成。
need_root(){ :; }
ic_gate(){ return 0; }
cmd_ios_state(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
_ios_dot_host(){ echo dot.example.invalid; }
_ios_server_ip(){ echo 203.0.113.10; }
_ios_internal_cidr(){ echo 172.22.0.0/16; }
_pdg_module(){ echo "$CH_DIR/iosstate.py"; }
_ios_offer_download(){ echo "OFFER-CALLED $*" >> "$PDG_TEST_LOG"; return 0; }
IOS_TMPL="$CH_DIR/tmpl.mobileconfig"
export PDG_IOS_LEGACY=n
# shellcheck source=/dev/null
. "$CH_DIR/fn.sh"
"$CH_FN"
echo "RC=$?"
'''


def run_caller(fn, **env_extra):
    d = tmpguard.mkdtemp(prefix="iosstage-")
    b = os.path.join(d, "bin")
    os.makedirs(b)
    with open(os.path.join(d, "tmpl.mobileconfig"), "w", encoding="utf-8") as f:
        f.write("<plist/>\n")
    with open(os.path.join(d, "iosstate.py"), "w", encoding="utf-8") as f:
        f.write("# stub\n")
    for name, body in (("mktemp", MKTEMP_STUB), ("python3", PY_STUB)):
        p = os.path.join(b, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        os.chmod(p, 0o755)
    env = dict(os.environ, PATH=b + os.pathsep + os.environ.get("PATH", ""),
               PDG_TEST_LOG=os.path.join(d, "log"), TMPDIR=d,
               CH_DIR=d, CH_ROOT=str(ROOT), CH_FN=fn)
    env.update({k: str(v) for k, v in env_extra.items()})
    hp = os.path.join(d, "h.sh")
    with open(hp, "w", encoding="utf-8") as f:
        f.write(HARNESS)
    r = subprocess.run(["bash", hp], env=env, cwd=str(ROOT), capture_output=True,
                       text=True, timeout=120)
    out = (r.stdout or "") + (r.stderr or "")
    m = re.search(r"^RC=(\d+)$", out, re.M)
    try:
        with open(env["PDG_TEST_LOG"], encoding="utf-8") as f:
            log = f.read()
    except OSError:
        log = ""
    return {"dir": d, "out": out, "rc": int(m.group(1)) if m else None, "log": log}


# ── 前提: 未注入失败时两个调用方都能跑通(否则下面每一格都是空转) ────────────
for fn in ("cmd_ios", "cmd_ios_previous"):
    r = run_caller(fn)
    if r["rc"] == 0 and "OFFER-CALLED" in r["log"]:
        ok("前提成立: %s 在 mktemp 正常时会走到开通道那一步" % fn)
    else:
        bad("前提不成立: %s rc=%s, 没走到开通道 —— 下面几格无从判断\n%s"
            % (fn, r["rc"], r["out"][:300]))

# ── 会话开不起来 → 必须立刻停, 不生成、不给根目录路径、不开通道 ─────────────
for fn, why in (("cmd_ios", "pdg ios"), ("cmd_ios_previous", "pdg ios previous")):
    r = run_caller(fn, PDG_TEST_SESSION_FAIL=1)
    probs = []
    if r["rc"] in (None, 0):
        probs.append("返回 0")
    if re.search(r"^iosstate ", r["log"], re.M):
        probs.append("仍然调用了 iosstate 去生成/取件")
    if "REFUSED-ROOT" in r["log"]:
        tgt = re.search(r"REFUSED-ROOT (\S+)", r["log"])
        probs.append("把根目录路径交了出去: %s(真机上就会写进 /)" % (tgt.group(1) if tgt else "?"))
    if "OFFER-CALLED" in r["log"]:
        probs.append("仍然去开临时下载通道")
    if probs:
        bad("%s 的会话开场失败: %s" % (why, "; ".join(probs)))
    else:
        ok("%s 的会话开场失败 → 立即非零退出, 不生成、不给根目录路径、不开通道" % why)

print("\n%d passed, %d failed" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

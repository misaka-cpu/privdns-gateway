#!/usr/bin/env python3
"""负控: **信号中止** 与 **服务所有权** 的判据有没有牙。

正控:
  · tests/test-ios-offer-interrupt.py   —— setup 三屏障 × 三信号、外来 200/302/代理、add 后复读失败
  · tests/test-ios-offer-lifecycle.py   —— 并发所有权、四条退出路径、SIGKILL 现场
  · tests/test-ios-caller-staging.py    —— 两个调用方的 staging fail-closed

这一支回答另一个问题: **如果这些判据退化了, 我们会不会知道?**

这一类退化的共同点是"看起来更成功": 信号处理器少一个 exit, 通道照样打出二维码;
就绪判据换回 urlopen, 8443 上任何东西应答都算数; 摘要不核, 别人的 200 就通过。
所以每一格的判据都必须**直指目标行为**, 而不是等着某个下游症状碰巧冒出来。

八格(第 ⑦ 格改的是**测试**, 不是产品):
  ① 信号处理器不 exit         —— trap 收完尾回到断点继续跑;
  ② 就绪换回默认 urllib opener —— 读代理环境;
  ③ 就绪跟随重定向            —— 302 把判据引到别处;
  ④ 不核对响应体摘要          —— 别人的 200 + 一个字节就算就绪;
  ⑤ 收尾不使用保存的 handle    —— 链读不了时规则再也删不掉;
  ⑥ 外层 STAGE 不检查         —— 描述文件写进文件系统根目录;
  ⑦ SIGKILL 测试在断言前手工杀孤儿 —— 把测试清理冒充成产品自愈;
  ⑧ 只加无关注释(反向对照)     —— 不该产生任何新失败。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
LIFE = "tests/test-ios-offer-lifecycle.py"
TOUCHED = [ROOT / PDG, ROOT / LIFE]

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=2400)


def failures(out):
    s = set()
    for l in out.splitlines():
        t = l.strip()
        if t.startswith("[FAIL]"):
            s.add(re.sub(r"\s+", " ", t)[:150])
    return s


T_INT = ["python3", "tests/test-ios-offer-interrupt.py"]
T_LIFE = ["python3", LIFE]
T_STAGE = ["python3", "tests/test-ios-caller-staging.py"]

EXITLINE = "  exit $((128 + num))"
SOCKBLOCK = '''    s = socket.create_connection(("127.0.0.1", int(os.environ["PDG_PORT"])), timeout=2)
    s.settimeout(2)
    s.sendall(("GET " + os.environ["PDG_PATH"] +
               " HTTP/1.0\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n").encode())
    buf = b""
    while len(buf) <= CAP:
        c = s.recv(65536)
        if not c:
            break
        buf += c
    s.close()'''
URLOPEN_DEFAULT = '''    import urllib.request
    buf = b"HTTP/1.0 200 OK\\r\\n\\r\\n" + urllib.request.urlopen(
        "http://127.0.0.1:" + os.environ["PDG_PORT"] + os.environ["PDG_PATH"],
        timeout=2).read(CAP)'''
URLOPEN_NOPROXY = '''    import urllib.request
    _o = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    buf = b"HTTP/1.0 200 OK\\r\\n\\r\\n" + _o.open(
        "http://127.0.0.1:" + os.environ["PDG_PORT"] + os.environ["PDG_PATH"],
        timeout=2).read(CAP)'''
DIGEST = '''if len(body) != int(os.environ["PDG_W_LEN"]):
    sys.exit(1)
if hashlib.sha256(body).hexdigest() != os.environ["PDG_W_SHA"]:
    sys.exit(1)'''
HANDLE_FIRST = '''  if [[ -n "${_IOS_OFFER_HANDLE:-}" ]]; then
    nft delete rule inet pdg input handle "$_IOS_OFFER_HANDLE" >/dev/null 2>&1 || true
  fi'''
# 调用方已不再有独立 staging(生成物直接落在会话目录里), 这一格改打新的等价约束:
# **会话开不起来必须立刻停**。
STAGE_OK = ('  _ios_offer_session_begin || return 1\n'
            '  OUT="$_IOS_OFFER_WWW/gen.mobileconfig"')
SUCCESSOR = '        dH, envH = mkcase("selfheal", CH_STDIN_HOLD=1)'

MUT = [
    ("① 信号处理器不 exit(收完尾回到断点继续跑)", PDG,
     [(EXITLINE, "  return $((128 + num))  # 变异", 1)], [T_INT]),
    ("② 就绪换回默认 urllib opener(读代理环境)", PDG,
     [(SOCKBLOCK, URLOPEN_DEFAULT, 1)], [T_INT]),
    ("③ 就绪跟随重定向(302 把判据引到别处)", PDG,
     [(SOCKBLOCK, URLOPEN_NOPROXY, 1)], [T_INT]),
    ("④ 不核对响应体摘要(别人的 200 就算就绪)", PDG,
     [(DIGEST, "pass  # 变异", 1)], [T_INT]),
    ("⑤ 收尾不使用保存的 handle", PDG,
     [(HANDLE_FIRST, "  :  # 变异: 不用本轮 handle", 1)], [T_INT]),
    ("⑥ 会话开场失败不检查(继续往下生成并开通道)", PDG,
     [(STAGE_OK, '  _ios_offer_session_begin || true  # 变异\n'
                 '  OUT="$_IOS_OFFER_WWW/gen.mobileconfig"', 1)], [T_STAGE]),
    ("⑦ SIGKILL 测试在断言前手工杀孤儿(把测试清理冒充产品自愈)", LIFE,
     [(SUCCESSOR,
       '        for _sp in pre["orphan"]:\n'
       '            try:\n'
       '                os.kill(_sp, signal.SIGKILL)\n'
       '            except OSError:\n'
       '                pass\n'
       '        wait_for(lambda: not has_listener(), limit=10)  # 变异: 替产品清场\n'
       + SUCCESSOR, 1)], [T_LIFE]),
    ("⑧ 只加无关注释(反向对照)", PDG,
     [(EXITLINE, "  # 变异: 一条无关注释\n" + EXITLINE, 1)], [T_INT]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-iossig-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    pristine = {f: (Path(wd) / f).read_text(encoding="utf-8") for f in (PDG, LIFE)}

    def suite(cmds):
        out = ""
        for c in cmds:
            r = run(c, cwd=wd)
            out += r.stdout + r.stderr
        return failures(out)

    base = suite([T_INT, T_LIFE, T_STAGE])
    if base:
        bad("基线就不绿(%d 条), 后面每一格都无从判断:" % len(base))
        for f in sorted(base)[:4]:
            print("       " + f[:130])
        raise SystemExit(1)
    ok("基线绿: 三支正控在未改坏的副本上 0 条具名失败")

    for label, target_f, edits, targets in MUT:
        target = Path(wd) / target_f
        mutated, aborted = pristine[target_f], False
        for old, new, want in edits:
            hits = mutated.count(old)
            if hits != want:
                bad("%s → 锚点命中 %d 次, 预期 %d(改坏器没打在预期位置)" % (label, hits, want))
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
        if aborted:
            continue
        target.write_text(mutated, encoding="utf-8")
        chk = (["bash", "-n", str(target)] if target_f.endswith(".sh")
               else ["python3", "-m", "py_compile", str(target)])
        if run(chk, cwd=wd).returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            target.write_text(pristine[target_f], encoding="utf-8")
            continue
        added = suite(targets) - base
        target.write_text(pristine[target_f], encoding="utf-8")

        if label.startswith("⑧"):
            (ok if not added else bad)("%s → %d 条新增(应为 0)" % (label, len(added)))
            continue
        # "这一格没测到东西"/"夹具没跑起来"只说明夹具塌了, 不说明判据有牙 —— 不计入。
        real = [a for a in added if "没测到东西" not in a and "夹具没跑" not in a
                and "EXTRACT-MISSING" not in a]
        if real:
            ok("%s → 新增具名失败 %d 条(其中直指目标 %d 条)" % (label, len(added), len(real)))
            print("       " + sorted(real)[0][:130])
        elif added:
            bad("%s → 只让夹具塌了(%d 条), 没有直指目标行为的具名失败" % (label, len(added)))
        else:
            bad("%s → 锚点命中但 0 条转红, 这一格无效" % label)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = True
for p in TOUCHED:
    if sha(p) != before[p]:
        bad("正式树被改动了! %s" % p.name); clean = False
    if os.stat(p).st_mode != modes[p]:
        bad("正式树权限位变了! %s" % p.name); clean = False
if clean:
    ok("正式树未被污染: pdg.sh 与 lifecycle 正控的 sha256 与 mode 均一致")

print("-" * 62)
print("ios-offer-signal-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

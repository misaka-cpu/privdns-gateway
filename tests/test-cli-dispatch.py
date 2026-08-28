#!/usr/bin/env python3
"""pdg 顶层分发器的参数传递 —— 行为验证(真的把那段 case 抽出来跑一遍)。

起因: 实机验收(2026-07-31, jp2)上
    sudo pdg rollback --dir /var/lib/privdns-gateway/backups/2026...
报 "--dir 缺参数"。分发器那条写的是 `cmd_rollback "${1:-0}"` —— 只把第一个参数递进去,
目录被丢在半路。cmd_rollback 自己的帮助里写着 `--dir <快照目录>` 与 `--git <ref>`, 所以这是
用户可见的入口, 不只是 cmd_update 的内部调用(内部是直接调函数, 不过分发器, 一直是好的)。

同一个坑 `rescue)` 那条已经踩过一次(`pdg rescue bind 1.2.3.4` 拿不到地址,
`pdg rescue rotate cert` 退化成轮换 token), 修完在那里留了注释。会踩第二次说明"记得写
$@"这种约束靠注释守不住, 所以这里不写死某几条子命令:

  · 分支清单**从 pdg.sh 的 case 块里解析出来**, 新增子命令自动进名单;
  · 凡是 `shift` 之后再调 cmd_* 的分支, 都必须把剩下的参数原样交出去(含带空格的参数);
  · 不 shift 的分支(status/token/restart…)本来就不收参数, 单独核对它们确实什么都没收到。

除了桩断言, 还真跑一遍 cmd_rollback 与 cmd_doctor 的参数解析: 桩只能证明"参数递到了函数
门口", 递进去之后是否被正确解读得由函数自己回答。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
PDG = ROOT / "deploy" / "bot" / "pdg.sh"

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


SRC = PDG.read_text(encoding="utf-8")


def bash_func(name):
    """按语法边界取一个顶层 bash 函数(单行写法也认), 不用定长窗口。"""
    m = re.search(r"^%s\(\)\{.*?\}[ \t]*$" % re.escape(name), SRC, re.M)
    if m:
        return m.group(0)
    m = re.search(r"^%s\(\)\{$.*?^\}$" % re.escape(name), SRC, re.M | re.S)
    if not m:
        raise SystemExit("取不到函数 %s" % name)
    return m.group(0)


# ── 1. 解析分发器: 分支清单必须来自源码本身 ────────────────────────────────
_m = re.search(r'^case "\$\{1:-menu\}" in$.*?^esac$', SRC, re.M | re.S)
if not _m:
    bad("找不到顶层分发器 case 块")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
DISPATCH = _m.group(0)

ARM = re.compile(r"^\s*(?P<pat>[^)]*?)\)\s*(?P<body>.*?);;")
# 命令位上出现但不是"被分发的目标"的东西。
# _lock 与 need_root 同类: 都是执行前的门(权限 / 全局互斥), 不是这条命令要干的事。
# __migrate 从 v1.8.1 起显式上锁 —— 更新子进程复用父进程继承来的那把, 用户手打时自己去取。
NOT_A_TARGET = {"shift", "true", "false", "echo", "need_root", "_lock", "return", "exit", ":"}

arms = []          # [(names, body, primary, shifts)]
unparsed = []
for line in DISPATCH.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or s.startswith("case ") or s == "esac":
        continue
    m = ARM.match(line)
    if not m:
        unparsed.append(s[:70])
        continue
    pat, body = m.group("pat").strip(), m.group("body")
    names = [p.strip().strip('"') for p in pat.split("|")]
    calls = []
    for seg in body.split(";"):
        tok = seg.strip().split(" ")[0].strip()
        if tok and tok not in NOT_A_TARGET:
            calls.append(tok)
    arms.append((names, body, calls[-1] if calls else None, "shift" in body))

if unparsed:
    bad("分发器里有本测试看不懂的分支(不能当成没有): %s" % "; ".join(unparsed))
elif len(arms) >= 15:
    ok("从分发器解析出 %d 条分支, 每一行都认得" % len(arms))
else:
    bad("只解析出 %d 条分支, 分发器结构可能变了" % len(arms))

# ── 2. 结构守卫: shift 之后就必须交 "$@" ───────────────────────────────────
# 行为断言之外再加这一条, 是因为行为断言只覆盖"现在有的"分支; 这条覆盖"以后写的"。
_trunc = []
for names, body, primary, shifts in arms:
    if not shifts or primary is None:
        continue
    if '"$@"' not in body:
        _trunc.append("%s → %s" % (names[0], body.strip()))
if not _trunc:
    ok("所有 shift 过的分支都用 \"$@\" 转交参数")
else:
    bad("这些分支 shift 之后没交 \"$@\", 子命令后面的参数会被丢掉: %s" % "; ".join(_trunc))

# ── 3. 行为: 把 case 块抽出来, 用可识别的桩跑每一条分支 ────────────────────
STUBS = sorted({p for _, _, p, _ in arms if p})
HARNESS = [
    "set -uo pipefail",
    "_recv(){ local n=\"$1\"; shift; printf 'CALL %s' \"$n\"; "
    "local a; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; printf '\\n'; }",
    "need_root(){ :; }",
    "_lock(){ :; }",          # 门, 不是分发目标 —— 与 need_root 同样桩掉
]
HARNESS += ["%s(){ _recv %s \"$@\"; }" % (s, s) for s in STUBS]
HARNESS.append(DISPATCH)
_h = tmpguard.mkdtemp(prefix="pdgdisp-")
TMPS.append(_h)
HPATH = os.path.join(_h, "dispatch.sh")
open(HPATH, "w", encoding="utf-8").write("\n".join(HARNESS) + "\n")


def dispatch(*argv):
    r = subprocess.run(["bash", HPATH, *argv], capture_output=True, text=True, timeout=120)
    return ((r.stdout or "") + (r.stderr or "")).strip()


def call(name, *args):
    return " ".join(["CALL " + name] + ["[%s]" % a for a in args])


# 带空格的那个参数不是凑数: `"$*"` / 忘了引号这类写法在它上面才会露馅。
PROBE = ("--probe-a", "值 带空格", "--probe-b")

_lost = []
_checked = 0
for names, body, primary, shifts in arms:
    if primary is None:          # `*)` 兜底分支只打印用法
        continue
    for name in names:
        if not name or name == "*":
            continue
        _checked += 1
        out = dispatch(name, *PROBE)
        want = call(primary, *PROBE) if shifts else call(primary)
        if out != want:
            _lost.append("pdg %s … → %r(应为 %r)" % (name, out, want))
if not _lost:
    ok("%d 个子命令(含别名)都把参数原样交给了后端, 一个字节没丢" % _checked)
else:
    bad("这些子命令丢了参数: %s" % "; ".join(_lost))

# 报障原样复现: 目录 + git ref 两对参数都得到。
_want = call("cmd_rollback", "--dir", "/var/lib/privdns-gateway/backups/2026-07-31-070000",
             "--git", "v1.7.3")
_got = dispatch("rollback", "--dir", "/var/lib/privdns-gateway/backups/2026-07-31-070000",
                "--git", "v1.7.3")
if _got == _want:
    ok("pdg rollback --dir <目录> --git <ref>: 四个参数完整到达 cmd_rollback")
else:
    bad("pdg rollback --dir <目录> --git <ref> 丢参数: %r" % _got)

# doctor 的两个开关是**可以同时给**的(doctor.py 各自独立地看 sys.argv)。
if dispatch("doctor", "--json", "--deep") == call("cmd_doctor", "--json", "--deep"):
    ok("pdg doctor --json --deep: 两个开关都到达 cmd_doctor")
else:
    bad("pdg doctor --json --deep 丢了开关: %r" % dispatch("doctor", "--json", "--deep"))

# 既有形式不许变。注意 `rollback` / `log` 无参数时分发器不再替它们塞 "0" / "40" ——
# 默认值下放给函数自己(cmd_rollback 的 idx:-0、cmd_log 的 ${1:-40}), 下面第 4、6 节真跑一遍
# 确认默认值没在这次改动里丢掉。
for argv, want, label in (
        ([], call("menu"), "pdg(无参数)进菜单"),
        (["rollback"], call("cmd_rollback"), "pdg rollback(无参数)不再由分发器塞 0"),
        (["rollback", "2"], call("cmd_rollback", "2"), "pdg rollback 2"),
        (["log"], call("cmd_log"), "pdg log(无参数)不再由分发器塞 40"),
        (["log", "100"], call("cmd_log", "100"), "pdg log 100"),
        (["uninstall", "--purge"], call("cmd_uninstall", "--purge"), "pdg uninstall --purge"),
        (["status", "多余的参数"], call("cmd_status"), "pdg status 不收参数"),
):
    got = dispatch(*argv)
    if got == want:
        ok("%s: 转交形态符合预期" % label)
    else:
        bad("%s 不对: %r(应为 %r)" % (label, got, want))

# ── 4. 真跑 cmd_rollback 的参数解析 ────────────────────────────────────────
# 桩只证明参数递到了门口。这一段用真的 cmd_rollback: 造几个空快照目录, 让它走到
# "快照文件缺失: <目录>/snap.tar.gz" 就返回 —— 那行输出正好把**它选中的目标**说出来了,
# 于是"序号选的哪个""--dir 指的哪个"都是可观察的, 且全程不碰真实文件系统。
SNAPS = tmpguard.mkdtemp(prefix="pdgsnap-")
TMPS.append(SNAPS)
DIRS = []
for i in range(4):                       # 0 最新 → 3 最旧(mtime 显式拉开, 不靠创建顺序)
    d = os.path.join(SNAPS, "2026-07-%02d-070000" % (31 - i))
    os.makedirs(d)
    DIRS.append(d)
for i, d in enumerate(DIRS):
    os.utime(d, (1_800_000_000 - i * 3600, 1_800_000_000 - i * 3600))

RB = "\n".join([
    "set -uo pipefail",
    "SNAP_DIR=%s" % SNAPS,
    "need_root(){ :; }",
    "_lock(){ :; }",
    # cmd_rollback 列快照时会调它读来源(老快照没有元数据 → 显示"来源未知")。
    # 夹具必须把真实依赖一起带上, 否则这里只会得到一串 command not found。
    bash_func("_snap_meta_label"),
    # 手动回滚现在还会读快照记下的 git_commit(决定要不要一并复位仓库), 所以这里也得带上 ——
    # 少了它, 报出来的是 "_snap_meta_commit: command not found", 与被测的参数解析毫无关系。
    bash_func("_snap_meta_commit"),
    bash_func("cmd_rollback"),
    DISPATCH,
]) + "\n"
RBPATH = os.path.join(_h, "rollback.sh")
open(RBPATH, "w", encoding="utf-8").write(RB)


def rollback(*argv):
    r = subprocess.run(["bash", RBPATH, "rollback", *argv],
                       capture_output=True, text=True, timeout=120)
    return ((r.stdout or "") + (r.stderr or "")).strip()


def slash(s):
    # `ls -1dt .../*/` 出来的路径自带尾斜杠, 于是按序号选中时消息里是 `目录//snap.tar.gz`。
    # 这里要断言的是**选中了哪个目录**, 不是斜杠写法, 所以两边都归一化。
    return re.sub(r"/+", "/", s)


for argv, want, label in (
        ([], "快照文件缺失: %s/snap.tar.gz" % DIRS[0], "无参数 = 最近一份(序号 0)"),
        (["0"], "快照文件缺失: %s/snap.tar.gz" % DIRS[0], "序号 0"),
        (["2"], "快照文件缺失: %s/snap.tar.gz" % DIRS[2], "序号 2"),
        (["--dir", DIRS[1]], "快照文件缺失: %s/snap.tar.gz" % DIRS[1], "--dir 精确指定"),
        (["--dir", DIRS[3], "--git", "v1.7.3"],
         "快照文件缺失: %s/snap.tar.gz" % DIRS[3], "--dir 与 --git 同时给"),
        (["--dir", os.path.join(SNAPS, "不存在")],
         "指定快照目录不存在: %s/不存在" % SNAPS, "--dir 指到不存在的目录"),
        (["99"], "无效序号 99", "越界序号仍然被拒"),
        (["abc"], "无效序号 abc", "非数字序号仍然被拒"),
):
    out = rollback(*argv)
    last = out.splitlines()[-1] if out.splitlines() else ""
    if slash(last) == slash(want):
        ok("cmd_rollback %s: %s" % (" ".join(argv) or "(无参数)", label))
    else:
        bad("cmd_rollback %s 结果不对: %r(应以 %r 收尾)"
            % (" ".join(argv) or "(无参数)", out[-160:], want))

# ── 5. 真跑 cmd_doctor: 两个开关都要出现在 doctor.py 的 argv 里 ────────────
# 丢掉 --deep 不会报错, 只会**静默跳过**慢速端到端检查(DoT 握手 / :81 / 解析 / clash_api),
# 而 --json 照常输出 —— 用户拿到一份看起来完整、实际没做深检的报告。
DOC = "\n".join([
    "set -uo pipefail",
    "python3(){ printf 'PY'; local a; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; printf '\\n'; }",
    "need_root(){ :; }",
    bash_func("cmd_doctor"),
    DISPATCH,
]) + "\n"
DPATH = os.path.join(_h, "doctor.sh")
open(DPATH, "w", encoding="utf-8").write(DOC)

_d = subprocess.run(["bash", DPATH, "doctor", "--json", "--deep"],
                    capture_output=True, text=True, timeout=120)
_dout = ((_d.stdout or "") + (_d.stderr or "")).strip()
if _dout == "PY [/opt/pdg-bot/doctor.py] [--json] [--deep]":
    ok("pdg doctor --json --deep: 两个开关都进了 doctor.py 的 argv")
else:
    bad("doctor.py 收到的 argv 不全: %r" % _dout)

# doctor.py 确实是各自独立地读这两个开关 —— 上一条断言才有意义。
_doc = (ROOT / "deploy/bot/doctor.py").read_text(encoding="utf-8")
if '"--deep" in sys.argv' in _doc and '"--json" in sys.argv' in _doc:
    ok("doctor.py 独立地读 --deep 与 --json(所以两个开关可以同时给)")
else:
    bad("doctor.py 的开关读法变了, 上面那条断言要重估")

# ── 6. 真跑 cmd_log: 默认行数从分发器挪到函数里之后, `pdg log` 仍然是 40 行 ──
LOG = "\n".join([
    "set -uo pipefail",
    "_pdg_core_svc(){ echo mihomo; }",
    "journalctl(){ printf 'J'; local a; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; printf '\\n'; }",
    "need_root(){ :; }",
    bash_func("cmd_log"),
    DISPATCH,
]) + "\n"
LPATH = os.path.join(_h, "log.sh")
open(LPATH, "w", encoding="utf-8").write(LOG)

for argv, want_n, label in (([], "40", "pdg log 默认 40 行"),
                            (["100"], "100", "pdg log 100 取 100 行")):
    r = subprocess.run(["bash", LPATH, "log", *argv], capture_output=True, text=True, timeout=120)
    out = ((r.stdout or "") + (r.stderr or "")).strip()
    if ("[-n] [%s]" % want_n) in out:
        ok("%s(journalctl 收到 -n %s)" % (label, want_n))
    else:
        bad("%s 不对: %r" % (label, out))

# ── 用法串必须覆盖 dispatcher 的每一条分支 ────────────────────────────────
# `pdg` 打错子命令时唯一的自助线索就是这一行用法串。它是**手写**的, 而 dispatcher 是另一处
# 手写的 —— 两处手写就会漂移: 加了子命令、忘了改用法, 于是那条命令**存在但没人知道**。
# 实测漂了两条(lan 在 v1.9 加的、adblock 在 v1.11 加的), 一直没人发现, 因为没有一格在看。
import re as _re                                                # noqa: E402

_src = open(PDG, encoding="utf-8").read().splitlines()
_ui = [i for i, l in enumerate(_src) if "用法: pdg [" in l]
(ok if len(_ui) == 1 else bad)("顶层用法串恰好一处(实得 %d)" % len(_ui))
if len(_ui) == 1:
    _u = _ui[0]
    _arms = []
    for _l in _src[max(0, _u - 70):_u]:
        _m = _re.match(r"^  ([a-z][a-z0-9|_-]*)\)", _l)
        if _m:
            _arms.append(_m.group(1))
    (ok if len(_arms) >= 20 else bad)("抽到了 dispatcher 的分支(实得 %d, 少于 20 说明抽法坏了)" % len(_arms))
    _inside = _re.search(r"用法: pdg \[(.*)\]", _src[_u])
    _listed = _inside.group(1) if _inside else ""
    (ok if _listed else bad)("用法串里抽得出方括号内容")
    _missing = [a for a in _arms
                if not any(_re.search(r"(?<![a-z-])%s(?![a-z-])" % _re.escape(n), _listed)
                           for n in a.split("|"))]
    (ok if not _missing else
     bad)("这些子命令**存在但用法串没列**, 用户无从知道: %s" % ", ".join(_missing))

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)

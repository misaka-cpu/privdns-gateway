#!/usr/bin/env python3
"""去广告的只读状态必须是**三态**, 不能把"读不到"说成"关闭"。

实测的缺陷(线上 profile.env 是 0600 root:root, 同一台**已启用**的机器):

    root   → 已启用(第三方表 214982 条 / 自定义 0 条)
    nobody → 未启用

根因: _adblock_intent 把四件不同的事折成同一个空值 —— 文件不存在、文件不可读、值非法、
真的没启用。空值再被 `!= 1` 一判, 全都变成"未启用"。于是一个**权限问题**在屏幕上长得
和"这台机器没开去广告"一模一样, 而后者是会让人去点"启用"的。

第二个形态: 启用位是 1、但规则文件缺失或读不到时, 当前显示

    已启用(第三方表 0 条 / 自定义 0 条)

那不是"0 条", 那是**证据缺失**。0 条是一个具体的事实(表在, 里面没东西), 缺文件是另一回事
(表根本不在, mosdns 起不来)——两者显示成同一句话, 现场就没法区分。

契约(只给**只读**状态用, 不动写路径依赖的 _adblock_intent 语义):
    profile 可读 + 最后一次赋值是 1            → enabled
    profile 可读 + 键不存在 / 最后一次赋值是 0 → disabled
    文件不存在 / 读不出来 / 值不是 0 或 1      → unknown

"最后一次赋值不是 0/1 就 unknown"是有意的: 有人往启用位里写了看不懂的东西时, 说"未启用"
是在替他下结论, 而我们并不知道他要什么。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard                                              # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


PDGSH = os.path.join(ROOT, "deploy/bot/pdg.sh")
SRC = open(PDGSH, encoding="utf-8").read()
W = tmpguard.mkdtemp(prefix="pdg-adbtri.")

# 抽出只读状态那条链。整个 cmd_adblock 跑不动(要 systemctl / 锁 / root), 而这几个函数
# 恰好就是"只读"的全部 —— 抽得出来本身也是契约的一部分。
NEED = ["_adblock_read_state", "_adb_count_rules", "_adb_rules_readable",
        "_adblock_intent", "_adblock_status_line"]
missing = [f for f in NEED if ("\n%s()" % f) not in SRC]
print("══ 0. 三态读取器存在 ══")
(ok if "_adblock_read_state" not in missing else
 bad)("pdg.sh 里有 _adblock_read_state(窄的只读三态读取器)")
(ok if "_adb_rules_readable" not in missing else
 bad)("pdg.sh 里有 _adb_rules_readable(区分「读不到」与「0 条」)")
# 写路径的既有语义不该被这次改动带走
(ok if "_adblock_intent" not in missing else
 bad)("_adblock_intent 仍在(写操作依赖它, 不扩大行为面)")

CHUNK = os.path.join(W, "chunk.sh")
with open(CHUNK, "w", encoding="utf-8") as f:
    f.write("set -uo pipefail\n")
    # 只读态里不该出现的副作用: 全部拦下来并留痕, 而不是让它们真的发生。
    f.write('install(){ echo "SIDE install $*" >&2; command install "$@"; }\n')
    f.write('mkdir(){ echo "SIDE mkdir $*" >&2; command mkdir "$@"; }\n')
    f.write('touch(){ echo "SIDE touch $*" >&2; command touch "$@"; }\n')
    f.write('chmod(){ echo "SIDE chmod $*" >&2; command chmod "$@"; }\n')
    f.write('chown(){ echo "SIDE chown $*" >&2; command chown "$@"; }\n')
    f.write('systemctl(){ echo "SIDE systemctl $*" >&2; return 0; }\n')
    f.write('flock(){ echo "SIDE flock $*" >&2; return 0; }\n')
    f.write('_lock(){ echo "SIDE _lock" >&2; }\n')
    for fn in NEED:
        if fn in missing:
            continue
        f.write(subprocess.run(["sed", "-n", "/^%s()/,/^}/p" % fn, PDGSH],
                               capture_output=True, text=True).stdout + "\n")


def snap(root):
    """整棵沙箱的形态指纹: 路径 + mode + size + mtime_ns。只读态必须一字不改。"""
    out = []
    for dp, dns, fns in os.walk(root):
        for n in sorted(dns) + sorted(fns):
            p = os.path.join(dp, n)
            try:
                st = os.lstat(p)
                out.append("%s %o %d %d" % (p, st.st_mode, st.st_size, st.st_mtime_ns))
            except OSError as e:
                out.append("%s ERR %s" % (p, e.errno))
    return "\n".join(sorted(out))


def run(fn, case, env_extra=None):
    """在 case 目录上跑一个函数; 返回 (stdout, stderr, rc, 沙箱是否被改动)"""
    d = os.path.join(W, case)
    env = dict(os.environ,
               PROFILE_ENV=os.path.join(d, "profile.env"),
               ADB_STATE_DIR=os.path.join(d, "state"),
               ADB_USER_ALLOW=os.path.join(d, "allow.txt"),
               ADB_USER_BLOCK=os.path.join(d, "block.txt"))
    env.update(env_extra or {})
    before = snap(d)
    r = subprocess.run(["bash", "-c", "source %s; %s" % (CHUNK, fn)],
                       capture_output=True, text=True, env=env)
    return r.stdout.strip(), r.stderr.strip(), r.returncode, (snap(d) != before)


def mkcase(name, profile=None, list_n=1234, block_lines="a.example\nb.example\n",
           drop_list=False, drop_block=False):
    d = os.path.join(W, name)
    os.makedirs(os.path.join(d, "state"), exist_ok=True)
    if profile is not None:
        open(os.path.join(d, "profile.env"), "w").write(profile)
    open(os.path.join(d, "allow.txt"), "w").close()
    if not drop_block:
        open(os.path.join(d, "block.txt"), "w").write(block_lines)
    if not drop_list:
        open(os.path.join(d, "state", "effective_list.txt"), "w").write(
            "".join("x%d.example\n" % i for i in range(list_n)))
    open(os.path.join(d, "state", "effective_block.txt"), "w").close()
    return d


print()
print("══ 1. 三态矩阵 ══")
CASES = [
    ("enabled",      "PDG_ADBLOCK_ENABLED=1\n",                        "enabled",  "真的开着"),
    ("disabled",     "PDG_ADBLOCK_ENABLED=0\n",                        "disabled", "真的关着"),
    ("nokey",        "PDG_OTHER=1\n",                                  "disabled", "键不存在(从没开过)"),
    ("override",     "PDG_ADBLOCK_ENABLED=1\nPDG_ADBLOCK_ENABLED=0\n", "disabled", "后一条赋值覆盖前一条"),
    ("override2",    "PDG_ADBLOCK_ENABLED=0\nPDG_ADBLOCK_ENABLED=1\n", "enabled",  "后一条赋值覆盖前一条(反向)"),
    ("badval",       "PDG_ADBLOCK_ENABLED=yes\n",                      "unknown",  "值不是 0/1"),
    ("badval2",      "PDG_ADBLOCK_ENABLED=1\nPDG_ADBLOCK_ENABLED=x\n", "unknown",  "最后一条是非法值"),
    ("nofile",       None,                                             "unknown",  "profile 不存在"),
]
for name, prof, want, desc in CASES:
    mkcase(name, prof)
    got, err, rc, changed = run("_adblock_read_state", name)
    (ok if got == want else
     bad)("%-28s → %s(实得 %r)" % (desc, want, got))
    (ok if not changed else bad)("%-28s: 沙箱零改动" % desc)
    (ok if "SIDE " not in err else
     bad)("%-28s: 没有副作用调用(实得 %r)" % (desc, err))

# 不可读: 两种都造。chmod 000 对 root 无效, 所以额外造一个"路径是目录"的 —— open 那一步
# 连 root 也会拿到 EISDIR。夹具没生效时判**测试自己**失败, 不许当成产品通过。
mkcase("unreadable", "PDG_ADBLOCK_ENABLED=1\n")
os.chmod(os.path.join(W, "unreadable", "profile.env"), 0)
really_unreadable = not os.access(os.path.join(W, "unreadable", "profile.env"), os.R_OK)
if really_unreadable:
    got, err, rc, changed = run("_adblock_read_state", "unreadable")
    (ok if got == "unknown" else bad)("profile 存在但 mode 000 → unknown(实得 %r)" % got)
    (ok if not changed else bad)("mode 000: 沙箱零改动")
else:
    print("[NOTE] 以 root 跑, chmod 000 拦不住 —— 该形态改由下面的 EISDIR 夹具覆盖")
mkcase("isdir")
os.remove(os.path.join(W, "isdir", "profile.env")) if os.path.exists(
    os.path.join(W, "isdir", "profile.env")) else None
os.makedirs(os.path.join(W, "isdir", "profile.env"), exist_ok=True)
got, err, rc, changed = run("_adblock_read_state", "isdir")
(ok if got == "unknown" else
 bad)("profile 路径读不出内容(EISDIR)→ unknown, 不许说成未启用(实得 %r)" % got)
(ok if not changed else bad)("EISDIR: 沙箱零改动")

print()
print("══ 2. status-line 的措辞 ══")
mkcase("L_on", "PDG_ADBLOCK_ENABLED=1\n")
out, err, rc, changed = run("_adblock_status_line", "L_on")
# 严格结构匹配, 不用子串: "1234" 里就含着 "2", 于是 `"2" in out` 这种写法在
# "自定义 0 条"的产品缺陷下照样绿(上一轮 23/23 全绿就是这么来的)。
m = re.search(r"第三方表\s*(\d+)\s*条\s*/\s*自定义\s*(\d+)\s*条", out)
(ok if m else bad)("已启用那行结构可解析(实得 %r)" % out)
if m:
    (ok if m.group(1) == "1234" else bad)("具名字段 第三方表 = 1234(实得 %s)" % m.group(1))
    (ok if m.group(2) == "2" else bad)("具名字段 自定义 = 2(实得 %s)" % m.group(2))
(ok if "\n" not in out else bad)("单行")
(ok if not changed else bad)("status-line 已启用: 沙箱零改动")

mkcase("L_off", "PDG_ADBLOCK_ENABLED=0\n")
out, err, rc, changed = run("_adblock_status_line", "L_off")
(ok if "未启用" in out else bad)("disabled → 未启用(实得 %r)" % out)

for case, prof, desc in (("L_unk", None, "profile 不存在"),
                         ("L_unk2", "PDG_ADBLOCK_ENABLED=zzz\n", "值非法")):
    mkcase(case, prof)
    out, err, rc, changed = run("_adblock_status_line", case)
    (ok if "状态未知" in out else
     bad)("%s → 明说「状态未知」(实得 %r)" % (desc, out))
    (ok if "未启用" not in out else
     bad)("%s → **不许**出现「未启用」, 那是另一件事(实得 %r)" % (desc, out))
    (ok if not re.search(r"\d+\s*条", out) else
     bad)("%s → 不许报条数(读不到启用位时那些数字没有意义)(实得 %r)" % (desc, out))
    (ok if not changed else bad)("%s: 沙箱零改动" % desc)

print()
print("══ 3. 已启用但规则文件缺失/不可读 → 不许显示成 0 条 ══")
for case, kw, desc in (("M_list",  dict(drop_list=True),  "生效表缺失"),
                       ("M_block", dict(drop_block=True), "用户 block 缺失")):
    mkcase(case, "PDG_ADBLOCK_ENABLED=1\n", **kw)
    out, err, rc, changed = run("_adblock_status_line", case)
    (ok if "0 条" not in out else
     bad)("%s → 不许显示成「0 条」, 那是证据缺失不是事实(实得 %r)" % (desc, out))
    (ok if "规则文件" in out else
     bad)("%s → 明说是规则文件的问题(实得 %r)" % (desc, out))
    (ok if "doctor" in out else
     bad)("%s → 指向 sudo pdg doctor(实得 %r)" % (desc, out))
    (ok if "已启用" in out else
     bad)("%s → 仍然说清启用位是开着的(实得 %r)" % (desc, out))
    (ok if not changed else bad)("%s: 沙箱零改动" % desc)

# 文件在但读不出来(mode 000): 与"缺失"同一处置, 且**不能**掉回 0 条
mkcase("M_perm", "PDG_ADBLOCK_ENABLED=1\n")
os.chmod(os.path.join(W, "M_perm", "state", "effective_list.txt"), 0)
if not os.access(os.path.join(W, "M_perm", "state", "effective_list.txt"), os.R_OK):
    out, err, rc, changed = run("_adblock_status_line", "M_perm")
    (ok if "0 条" not in out and "规则文件" in out else
     bad)("生效表存在但不可读 → 与缺失同样处置, 不许显示 0 条(实得 %r)" % out)
    (ok if not changed else bad)("不可读: 沙箱零改动")
else:
    print("[NOTE] 以 root 跑, mode 000 拦不住 —— 该形态由上面的「缺失」两格覆盖")

print()
print("══ 4. status 与 status-line 对启用状态的结论必须一致 ══")
# 两处各读各的话, 迟早会一个说开着一个说关着 —— 而用户看到的是哪一个取决于他敲了哪条命令。
body = re.search(r"\n_adblock_status\(\)\{(.*?)\n\}", SRC, re.S)
(ok if body else bad)("抽得到 _adblock_status")
if body:
    b = body.group(1)
    (ok if "_adblock_read_state" in b else
     bad)("_adblock_status 也走三态读取器(否则两条命令会给出不同结论)")

print()
print("══ 5. 只读契约: 源码里不许出现写操作 ══")
for fn in ("_adblock_read_state", "_adb_rules_readable", "_adblock_status_line"):
    mm = re.search(r"\n%s\(\)\{(.*?)\n\}" % fn, SRC, re.S)
    if not mm:
        bad("抽得到 %s" % fn)
        continue
    b = mm.group(1)
    hits = [w for w in ("install -d", "mkdir", "touch", ": >", "systemctl", "flock",
                        "chmod", "chown", "_lock") if w in b]
    (ok if not hits else bad)("%s 里没有写操作(实得 %r)" % (fn, hits))

print("-" * 62)
print("test-adblock-status-tristate.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""负控的字节码缓存隔离回归(测试框架自身的可靠性)。

隐患是真的, 本项目踩过一次: 负控在同一秒内把源码改坏、跑一遍、再恢复, 而 CPython 的
__pycache__ 用**秒级 mtime + 文件长度**判定源码是否变过 —— 同一秒内改成等长内容, 判据完全
命中旧记录, 于是跑的是上一版字节码。表现是"改坏了却没变红"或"恢复了却仍然红", 两种都会让人
对着一个假结果做判断。

这里不靠 sleep 去躲开那一秒(那只是把问题藏起来, 换台快机器又会撞上), 而是**主动构造**最坏
情况: 把改坏前后的文件长度写成一样、mtime 用 os.utime 设成同一个值, 让时间戳判据无法区分。
然后分别验证:
  · 共用缓存 → 复现假结果(证明隐患存在, 不是杞人忧天);
  · 每次一个独有且为空的缓存 → 负控真的变红、恢复后真的变绿。
"""
import os
import subprocess
import sys
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from txbox import PycacheIsolation  # noqa: E402

PASS = [0]
FAIL = [0]
FIXED_MTIME = 1_700_000_000.0          # 固定 mtime: 让"同一秒"变成确定性条件, 不依赖机器快慢


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def write_mod(path, value):
    """写一个模块并把 mtime 钉死。value 必须等长 —— 长度也是缓存判据的一部分。"""
    src = 'VALUE = "%s"\n' % value
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    os.utime(path, (FIXED_MTIME, FIXED_MTIME))
    return len(src)


def run_child(work, env):
    p = subprocess.run([sys.executable, "-c", "import m; print(m.VALUE)"],
                       cwd=work, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, timeout=60)
    return p.stdout.strip()


work = tmpguard.mkdtemp(prefix="pycache-iso.")
mod = os.path.join(work, "m.py")

# ── 0. 前提: 改坏前后必须等长且 mtime 相同, 否则这条回归验的不是最坏情况 ──
n_good = write_mod(mod, "good")
st_good = os.stat(mod)
n_bad = write_mod(mod, "bad!")           # 4 个字符, 与 good 等长
st_bad = os.stat(mod)
if n_good == n_bad and int(st_good.st_mtime) == int(st_bad.st_mtime):
    ok("前提成立: 改坏前后文件长度相同(%d)且 mtime 相同 → 时间戳判据无法区分" % n_good)
else:
    bad("前提不成立: len %d/%d mtime %s/%s" % (n_good, n_bad, st_good.st_mtime, st_bad.st_mtime))

# ── 1. 复现隐患: 共用一个缓存目录时, 改坏的源码跑出来仍是旧值 ──
shared = tempfile.mkdtemp(prefix="pycache-shared.", dir=work)
env_shared = dict(os.environ, PYTHONPYCACHEPREFIX=shared)
write_mod(mod, "good")
first = run_child(work, env_shared)          # 建立缓存
write_mod(mod, "bad!")                       # 同长度、同 mtime 地改坏
stale = run_child(work, env_shared)
if first == "good":
    ok("共用缓存: 首次执行读到正常源码")
else:
    bad("首次执行就不对: %r" % first)
if stale == "good":
    ok("隐患复现: 共用缓存时改坏源码仍跑出旧值 'good'(负控会假通过)")
elif stale == "bad!":
    # 某些环境(如缓存被别的因素判失效)不会复现 —— 如实说明, 不当成通过
    print("[INFO] 本环境未复现共用缓存的陈旧读取(stale=%r); 下面的隔离验证仍然有效" % stale)
else:
    bad("共用缓存执行异常: %r" % stale)

# ── 2. 隔离生效: 每次一个独有且为空的缓存 → 改坏必须真的变红 ──
with PycacheIsolation(work) as pc:
    write_mod(mod, "good")
    pc.reset()
    a = run_child(work, pc.env())
    if a == "good":
        ok("隔离: 正常源码跑出 'good'")
    else:
        bad("隔离下正常源码跑错: %r" % a)
    if pc.files():
        ok("隔离: 字节码确实落在本实例的缓存目录里(%d 个文件)" % len(pc.files()))
    else:
        bad("隔离目录里没有字节码, PYTHONPYCACHEPREFIX 可能没生效")

    write_mod(mod, "bad!")                   # 同长度、同 mtime
    pc.reset()                               # 每次负控前清空
    b = run_child(work, pc.env())
    if b == "bad!":
        ok("隔离: 同一秒内改坏源码 → 真的读到坏版本(负控不会假通过)")
    else:
        bad("隔离下改坏却仍读到 %r —— 缓存隔离没生效" % b)

    write_mod(mod, "good")                   # 同一秒恢复
    pc.reset()
    c = run_child(work, pc.env())
    if c == "good":
        ok("隔离: 同一秒恢复源码 → 立刻读到恢复后的版本(不会假失败)")
    else:
        bad("恢复后仍读到 %r" % c)

    # 3. 缓存目录必须在本测试的 work 下(不污染仓库, 也便于精确清理)
    if os.path.realpath(pc.dir).startswith(os.path.realpath(work)):
        ok("隔离: 缓存目录位于本测试实例的工作目录内")
    else:
        bad("缓存目录跑到外面去了: %s" % pc.dir)
    saved_dir = pc.dir

# ── 4. 退出即清理, 且没碰仓库 ──
if not os.path.exists(saved_dir):
    ok("退出后本实例缓存目录已删除")
else:
    bad("缓存目录残留: %s" % saved_dir)

repo_pyc = os.path.join(os.path.dirname(HERE), "deploy", "bot", "__pycache__")
before = set(os.listdir(repo_pyc)) if os.path.isdir(repo_pyc) else set()
with PycacheIsolation(work) as pc:
    write_mod(mod, "good")
    run_child(work, pc.env())
after = set(os.listdir(repo_pyc)) if os.path.isdir(repo_pyc) else set()
if before == after:
    ok("隔离期间没有向仓库的 __pycache__ 写入任何东西")
else:
    bad("污染了仓库缓存: 新增 %s" % (after - before))

# ── 5. shell 侧 harness 的同一能力(真的 source e2e-lib.sh 跑一遍) ──
sh = r'''
set -uo pipefail
export TMPDIR="%s"
source "%s/e2e-lib.sh"
e2e_pycache_isolate || { echo "ISOLATE-FAILED"; exit 1; }
echo "DIR=$E2E_PYCACHE_DIR"
echo "ENV=$PYTHONPYCACHEPREFIX"
[[ "$E2E_PYCACHE_DIR" == "$TMPDIR"/* ]] && echo "UNDER-TMPDIR=yes" || echo "UNDER-TMPDIR=no"
cd "$TMPDIR" && python3 -c "import m" >/dev/null 2>&1
[[ -n "$(find "$E2E_PYCACHE_DIR" -type f -name '*.pyc' 2>/dev/null)" ]] && echo "CACHED=yes" || echo "CACHED=no"
e2e_pycache_reset
[[ -z "$(find "$E2E_PYCACHE_DIR" -type f 2>/dev/null)" ]] && echo "RESET=empty" || echo "RESET=dirty"
e2e_pycache_isolate; echo "IDEMPOTENT=$E2E_PYCACHE_DIR"
exit 0
''' % (work, HERE)
p = subprocess.run(["bash", "-c", sh], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                   universal_newlines=True, timeout=120)
out = p.stdout
shdir = ""
for line in out.splitlines():
    if line.startswith("DIR="):
        shdir = line[4:]
if "UNDER-TMPDIR=yes" in out:
    ok("shell 侧: 缓存目录建在测试自己的 TMPDIR 下")
else:
    bad("shell 侧缓存目录位置不对: %r" % out)
if "CACHED=yes" in out:
    ok("shell 侧: PYTHONPYCACHEPREFIX 真的把字节码引导过去了")
else:
    bad("shell 侧缓存没生效: %r" % out)
if "RESET=empty" in out:
    ok("shell 侧: e2e_pycache_reset 之后目录为空")
else:
    bad("reset 没清干净: %r" % out)
if out.count("IDEMPOTENT=" + shdir) == 1 and shdir:
    ok("shell 侧: e2e_pycache_isolate 重复调用幂等(仍是同一个目录)")
else:
    bad("重复调用不幂等: %r" % out)
if shdir and not os.path.exists(shdir):
    ok("shell 侧: 退出 hook 已把缓存目录清掉")
else:
    bad("shell 侧缓存目录残留: %s" % shdir)

# ── 6. 收尾: 本测试的临时目录与子进程都不残留 ──
import shutil  # noqa: E402

shutil.rmtree(work, ignore_errors=True)
if not os.path.exists(work):
    ok("测试结束: 本实例临时目录已清理")
else:
    bad("临时目录残留: %s" % work)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

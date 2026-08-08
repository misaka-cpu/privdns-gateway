#!/usr/bin/env python3
"""临时物卫生的负控: 每条就地撤掉一处清理, 要求 tests/test-tmp-hygiene.py 由绿转红。

为什么要有这一组: "跑完 /tmp 干净了"这个结论太容易假绿 —— 只要用例根本没建过目录, 或者
判据看的是别的路径, 它照样通过。所以逐条把清理拆掉, 看那道门认不认得出来。

纪律沿用 6.1c 那一组(都是踩出来的):
  · 改坏器必须先证明**锚点真实命中**, 锚点没命中 = 什么都没改, 后面的结论无意义;
  · **0 条转红一律判无效** —— 那说明根本没有判据盯着这件事;
  · 语法错 / 测试崩溃不算红灯, 每条跑完顺带核对 py_compile 与 bash -n;
  · 还原走逐字节备份 + sha256 核对, 不用 git reset --hard / checkout -- / clean -fd;
  · 改哪个文件, 哪个文件就必须在 TOUCHED 里 —— 不在名单里 = 不备份 = 跑完不还原。

用法: python3 tests/negctl/tmp-hygiene-negative-controls.py [编号...] / [起-止]
"""
import hashlib
import io
import os
import py_compile
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tests"))     # negctl 跑起来时 sys.path[0] 是 negctl/
import tmpguard  # noqa: E402

BAK = tmpguard.mkdtemp(prefix="negctl-tmphyg.")

TOUCHED = [
    "tests/tmpguard.py",
    "tests/txbox.py",
    "tests/e2e-lib.sh",
    "tests/test-report-backend.py",
]
SHA = {}
for _f in TOUCHED:
    shutil.copyfile(os.path.join(ROOT, _f), os.path.join(BAK, _f.replace("/", "__")))
    SHA[_f] = hashlib.sha256(open(os.path.join(ROOT, _f), "rb").read()).hexdigest()

GATE = "tests/test-tmp-hygiene.py"


def restore():
    for f in TOUCHED:
        shutil.copyfile(os.path.join(BAK, f.replace("/", "__")), os.path.join(ROOT, f))
        got = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()
        if got != SHA[f]:
            print("!! 还原校验失败: %s" % f)
            sys.exit(9)


def read(f):
    return io.open(os.path.join(ROOT, f), encoding="utf-8").read()


def write(f, s):
    io.open(os.path.join(ROOT, f), "w", encoding="utf-8").write(s)


def sub(s, old, new, why):
    n = s.count(old)
    if n != 1:
        raise AssertionError("锚点命中 %d 次(应为 1): %s" % (n, why))
    return s.replace(old, new, 1)


def syntax_ok():
    bad = []
    for f in TOUCHED:
        p = os.path.join(ROOT, f)
        if f.endswith(".py"):
            try:
                py_compile.compile(p, doraise=True, cfile=os.path.join(BAK, "x.pyc"))
            except Exception:  # noqa: BLE001
                bad.append(f)
        elif f.endswith(".sh"):
            if subprocess.run(["bash", "-n", p], capture_output=True).returncode:
                bad.append(f)
    return bad


def run_gate(timeout=1800):
    """跑判据, 返回 (转红条数, 崩溃原因)。崩溃不算有效红灯。"""
    e = dict(os.environ)
    e["PDG_TEST_STRICT"] = "1"
    e.pop("PDG_KEEP_TMP", None)
    try:
        p = subprocess.run(["python3", GATE], cwd=ROOT, capture_output=True, text=True,
                           timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return 0, "超时"
    out = p.stdout + p.stderr
    red = sum(1 for l in out.splitlines() if l.startswith("[FAIL"))
    crashed = "抛异常" if ("Traceback" in out or "SyntaxError" in out) else ""
    return red, crashed


RESULTS = []
ONLY = set()
for _a in sys.argv[1:]:
    if "-" in _a:
        _x, _y = _a.split("-")
        ONLY |= set(range(int(_x), int(_y) + 1))
    else:
        ONLY.add(int(_a))


def nc(num, title, breaker, expect):
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    print("  期望转红: %s" % expect)
    try:
        breaker()
    except AssertionError as e:
        print("  [无效] 改坏器锚点没命中: %s" % e)
        RESULTS.append((num, title, None, "锚点没命中"))
        restore()
        return
    bad = syntax_ok()
    if bad:
        print("  [无效] 改坏后代码不合法(%s) —— 红灯来自解析器, 不算判据" % ",".join(bad))
        RESULTS.append((num, title, None, "改坏器把代码弄成语法错"))
        restore()
        return
    red, crash = run_gate()
    if crash:
        print("  ⚠️ 判据崩溃(%s) —— 崩溃不算有效红灯" % crash)
    if red > 0:
        print("  ✅ 转红 %d 条" % red)
        RESULTS.append((num, title, red, "%d 条" % red))
    else:
        print("  ❌ 0 条转红 —— 无效负控(没有判据盯着它)")
        RESULTS.append((num, title, 0, "0"))
    restore()


# ══ 1. 退出时根本不清 ═══════════════════════════════════════════════════════
# 最朴素的那种退化: 登记表还在, 但谁也不去消费它。跑完目录原样留着。
def b1():
    s = read("tests/tmpguard.py")
    s = sub(s, "    atexit.register(_cleanup_all)",
            "    pass  # 改坏器: 不注册退出清理", "tmpguard 注册 atexit")
    write("tests/tmpguard.py", s)


nc(1, "tmpguard 不再注册 atexit(跑完谁也不清)", b1, "第 1 节: 私有 TMPDIR 里留下目录")


# ══ 2. 清理函数被架空 ═══════════════════════════════════════════════════════
# 比 NC1 更隐蔽: atexit 照常注册、日志照常没有异常, 只是那个函数什么也不做。
def b2():
    s = read("tests/tmpguard.py")
    s = sub(s, "def _cleanup_all():\n    me = os.getpid()",
            "def _cleanup_all():\n    return  # 改坏器: 清理被架空\n    me = os.getpid()",
            "_cleanup_all 主体")
    write("tests/tmpguard.py", s)


nc(2, "_cleanup_all 被架空(注册了但什么都不做)", b2, "第 1 节: 私有 TMPDIR 里留下目录")


# ══ 3. 留现场开关失效 ═══════════════════════════════════════════════════════
# 清理做得干干净净, 代价是失败时没有现场可看 —— 这正是"清理"最容易伤到的东西, 得有人盯。
def b3():
    s = read("tests/tmpguard.py")
    s = sub(s, '    return os.environ.get(KEEP_ENV, "") not in ("", "0")',
            "    return False  # 改坏器: PDG_KEEP_TMP 失效, 永远清",
            "keeping() 主体")
    write("tests/tmpguard.py", s)


nc(3, "PDG_KEEP_TMP 失效(想留现场也留不住)", b3, "第 3 节: 留现场那两条")


# ══ 4. 反过来: 默认就留 ═════════════════════════════════════════════════════
# "默认留着, 想清再说" —— /tmp 里一天堆几十个目录的由来就是这个默认值。
def b4():
    s = read("tests/tmpguard.py")
    s = sub(s, '    return os.environ.get(KEEP_ENV, "") not in ("", "0")',
            "    return True  # 改坏器: 默认就留现场",
            "keeping() 主体")
    write("tests/tmpguard.py", s)


nc(4, "默认变成留现场(不设开关也不清)", b4, "第 1 节全红 + 第 3 节「默认就是清」")


# ══ 5. SIGTERM 这条路不管 ═══════════════════════════════════════════════════
# CI 的 `timeout` 走的正是 SIGTERM。默认处置直接死, atexit 一行都不跑 —— 而"跑超时了"
# 恰恰是最容易反复发生、最容易堆残骸的场景。
def b5():
    s = read("tests/tmpguard.py")
    s = sub(s, "    try:\n"
               "        if signal.getsignal(signal.SIGTERM) is signal.SIG_DFL:\n"
               "            signal.signal(signal.SIGTERM, _on_sigterm)\n"
               "    except ValueError:",
            "    try:\n"
            "        pass  # 改坏器: 不接管 SIGTERM\n"
            "    except ValueError:", "SIGTERM 处理器安装")
    write("tests/tmpguard.py", s)


nc(5, "不接管 SIGTERM(被 timeout 杀掉就漏)", b5, "第 2 节: SIGTERM 那条")


# ══ 6. txbox 退回裸 tempfile ════════════════════════════════════════════════
# 这就是 pdgtx-box.* 一趟漏五十个的原写法: 用例忘了 clean() 或中途抛异常, 目录就留下了。
def b6():
    s = read("tests/txbox.py")
    s = sub(s, '        self.root = tmpguard.mkdtemp(prefix="pdgtx-box.")',
            '        self.root = tempfile.mkdtemp(prefix="pdgtx-box.")',
            "Box 的沙箱根")
    s = sub(s, "            tmpguard.cleanup(self.root)      # 同时销号, 循环里建几十个也不会攒着",
            "            shutil.rmtree(self.root, ignore_errors=True)",
            "Box.clean 的目录清理")
    write("tests/txbox.py", s)


nc(6, "txbox 退回裸 tempfile.mkdtemp(忘了 clean 就漏)", b6,
   "第 4a 节静态门 + 第 1 节 txbox 那两支")


# ══ 7. 写死 /tmp 路径又回来了 ═══════════════════════════════════════════════
# TMPDIR 管不到它, 所以私有 TMPDIR 那一节看不见 —— 但并发跑必然互相踩, 跑完还留在宿主
# 的 /tmp 里。静态那一节就是专为这一类留的。
def b7():
    s = read("tests/test-report-backend.py")
    s = sub(s, "TMP = tmpguard.mkdtemp()",
            'TMP = "/tmp/pdg-report-fixed"\nos.makedirs(TMP, exist_ok=True)',
            "report-backend 的沙箱")
    write("tests/test-report-backend.py", s)


nc(7, "用例里又写死 /tmp 路径(TMPDIR 管不到的那一类)", b7, "第 4b 节静态门")


# ══ 8. e2e 的本轮临时目录不清 ═══════════════════════════════════════════════
# E2E 侧对应的退化: $E2E_TMP 照建, 退出钩子照注册, 但清理函数直接返回。
def b8():
    s = read("tests/e2e-lib.sh")
    s = sub(s, 'e2e_tmp_cleanup(){\n  [[ -n "$E2E_TMP" ]] || return 0',
            'e2e_tmp_cleanup(){\n  return 0  # 改坏器: e2e 的临时目录不清\n'
            '  [[ -n "$E2E_TMP" ]] || return 0',
            "e2e_tmp_cleanup 主体")
    write("tests/e2e-lib.sh", s)


nc(8, "e2e_tmp_cleanup 被架空(E2E 跑完留一坨)", b8, "第 1 节: e2e 那支")


# ══ 9. e2e 退回写死 /tmp ════════════════════════════════════════════════════
# 桩的状态目录写死 /tmp/e2e-svc 是原来的样子: 跑完没人清, 而且两个并发的脚本共用同一份
# svcstate —— 后者更毒, 症状是"另一支 E2E 莫名其妙红了"。
def b9():
    s = read("tests/e2e-lib.sh")
    s = sub(s, 'e2e_svc_fail(){ mkdir -p "$E2E_TMP/e2e-svc"; echo 0 > "$E2E_TMP/e2e-svc/$1.ac"; }',
            'e2e_svc_fail(){ mkdir -p /tmp/e2e-svc; echo 0 > "/tmp/e2e-svc/$1.ac"; }',
            "e2e_svc_fail 的状态目录")
    write("tests/e2e-lib.sh", s)


nc(9, "e2e 的桩状态目录退回写死 /tmp/e2e-svc", b9, "第 4b 节静态门")


print("\n" + "═" * 70)
for num, title, red, det in RESULTS:
    print("%s NC%02d %-46s %s" % ("✅" if red else "❌", num, title[:46], det))
invalid = [r for r in RESULTS if not r[2]]
print("有效 %d / 无效 %d" % (len(RESULTS) - len(invalid), len(invalid)))
restore()
sys.exit(1 if invalid else 0)

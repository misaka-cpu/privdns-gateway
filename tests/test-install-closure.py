#!/usr/bin/env python3
"""运行模块安装闭包: 装机清单必须**覆盖真实入口的传递依赖**。

为什么要单独验这个: 少装一个模块的后果不是报错 —— 是**整块能力静默降级**。救援页会把
「恢复受管配置」「紧急默认出口」标成"旧核心不支持"(那是产品有意的优雅降级), 而用户此刻正
指望它们把机器捞回来。没有这道守卫, 缺口只会在真机出事那天暴露。

这里**重新算一遍闭包**再与 lib/modules.sh 比对, 而不是照抄清单 —— 照抄的话清单漏了什么,
测试就跟着漏什么。算的时候必须带上**动态导入点**: rescue.py 经 `_mod("cfgrestore", API)`
这种形式导入, 纯静态 import 扫描看不见(emergency 当初就是这么漏掉的)。
"""
import ast
import os
import re
import shutil
import subprocess
import tempfile
import sys
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def skip(m):
    print("[SKIP] " + m)


# ── 本地模块索引 ────────────────────────────────────────────────────────────
LOCAL = {}
for d in ("deploy/bot", "deploy/rescue"):
    for f in sorted(os.listdir(os.path.join(ROOT, d))):
        if f.endswith(".py"):
            LOCAL[f[:-3]] = os.path.join(ROOT, d, f)


def imports_of(path):
    """一个文件引用到的**本地**模块: 静态 import + 动态导入点。

    动态点是关键: `_mod("x", API)` / `__import__("x")` 里的名字是字符串常量, 只有把 Call
    也走一遍才看得见。漏掉它就会得出"rescue.py 只依赖 rescue_const"这种明显不对的结论。"""
    out = set()
    tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            out |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom) and n.module:
            out.add(n.module.split(".")[0])
        elif isinstance(n, ast.Call):
            fn = getattr(n.func, "id", "") or getattr(n.func, "attr", "")
            if fn in ("__import__", "_mod") and n.args and isinstance(n.args[0], ast.Constant):
                out.add(str(n.args[0].value))
    return {m for m in out if m in LOCAL}


def closure(entries):
    seen, stack = set(), list(entries)
    while stack:
        m = stack.pop()
        if m in seen:
            continue
        seen.add(m)
        stack += list(imports_of(LOCAL[m]) - seen)
    return seen


# 真实入口: 救援服务本体 + 另两个可执行入口 + pdg.sh 用 _pdg_module 拉起来的模块
CLI_REFS = set(re.findall(r"_pdg_module ([a-z_0-9]+)\.py",
                          open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()))
ENTRIES = sorted({"rescue", "breakglass", "rescue_cred"} | (CLI_REFS & set(LOCAL)))
NEED = closure(ENTRIES)

print("── 1. 闭包 vs 安装清单 ──")
print("       入口: %s" % ", ".join(ENTRIES))

# ── 安装清单真源 ────────────────────────────────────────────────────────────
MANIFEST = os.path.join(ROOT, "lib/modules.sh")
man_txt = open(MANIFEST, encoding="utf-8").read()
m = re.search(r'PDG_RUNTIME_MODULES="([^"]*)"', man_txt, re.S)
if not m:
    bad("lib/modules.sh 里找不到 PDG_RUNTIME_MODULES")
    entries = []
else:
    entries = [ln.split() for ln in m.group(1).splitlines() if ln.strip()]
    ok("运行模块真源可解析(%d 项)" % len(entries))

INSTALLED = {e[1][:-3] for e in entries if e[1].endswith(".py")}

# iOS 专属清单也算"装了" —— 但只在 iOS 机器上。这两份不能合并: 合了之后 Android 会装上
# 一批它永远用不到的 iOS 组件, 卸载又要去删一堆本就不存在的文件。
mi = re.search(r'PDG_IOS_MODULES="([^"]*)"', man_txt, re.S)
ios_entries = [ln.split() for ln in mi.group(1).splitlines() if ln.strip()] if mi else []
IOS_INSTALLED = {e[1][:-3] for e in ios_entries if e[1].endswith(".py")}
if mi:
    ok("iOS 专属真源可解析(%d 项)" % len(ios_entries))
else:
    bad("lib/modules.sh 里找不到 PDG_IOS_MODULES")

missing = sorted(NEED - INSTALLED - IOS_INSTALLED)
if not missing:
    ok("清单覆盖全部 %d 个入口依赖(逐个算传递闭包比对)" % len(NEED))
else:
    bad("清单漏装: %s —— 少一个就是整块能力静默降级" % ", ".join(missing))

# 平台无关的模块**不许**依赖 iOS 专属模块: 那种依赖在 Android 机器上是 ImportError,
# 而且只在真正走到那条路径时才炸 —— 装机、update、doctor 全看不出来。
#
# 比对必须按**仓库里的模块名**来。清单里存的是安装后的名字, 而 pdg-bot.py 装成 bot.py ——
# 拿安装名去 LOCAL 里找会直接找不到, 于是 bot 本体被静默跳过。第一版就是这么漏的:
# pdg-bot.py 在顶层 import 了 iosprofile, Android 机器上的 bot 根本起不来, 而这条守卫全绿。
SRC_OF = {e[1][:-3]: os.path.basename(e[0])[:-3] for e in entries if e[1].endswith(".py")}
_common_src = sorted({SRC_OF.get(m, m) for m in INSTALLED} & set(LOCAL))
if len(_common_src) == len([e for e in entries if e[1].endswith(".py")]):
    ok("清单里每个 .py 都能对回仓库源文件(改名项也算得上, 共 %d 个)" % len(_common_src))
else:
    bad("有清单项对不回仓库源文件: %r"
        % sorted({SRC_OF.get(m, m) for m in INSTALLED} - set(LOCAL)))
# 判据是**真的在一台 Android 形态的机器上把每个模块 import 一遍**, 不是看源码里有没有那行
# import。二者会给出不同答案: 用 try/except ImportError 包起来的可选依赖, 静态看是"依赖了",
# 运行起来却完全正常。而我们真正在乎的只有一件事 —— Android 机器上这些模块 import 得起来。
_and_root = tmpguard.mkdtemp(prefix="closure-android-")
try:
    _r = subprocess.run(
        ["bash", "-c", 'set -eu; source "%s/lib/modules.sh"; '
                       'pdg_install_runtime_modules "%s" "%s" android' % (ROOT, ROOT, _and_root)],
        capture_output=True, text=True, timeout=300)
    if _r.returncode != 0:
        bad("装不出 Android 形态的运行目录: %s" % (_r.stderr or "")[-200:])
    else:
        _mods = sorted(f[:-3] for f in os.listdir(_and_root) if f.endswith(".py"))
        # 结论必须带标记再取: 有些模块 import 时自己会往 stdout 打东西(用法说明之类),
        # 直接读 stdout 会把那些行当成"import 失败"。
        # 每个模块单独 try, 且连 SystemExit 一起接住 —— 我们只关心 ImportError 这一类。
        _code = ("import sys\n"
                 "sys.path.insert(0, %r)\n"
                 "bad=[]\n"
                 "for m in %r:\n"
                 "    try:\n"
                 "        __import__(m)\n"
                 "    except ImportError as e:\n"
                 "        bad.append('%%s: %%s' %% (m, e))\n"
                 "    except BaseException:\n"
                 "        pass\n"
                 "sys.stderr.write('__RESULT__' + '|'.join(bad) + '\\n')\n" % (_and_root, _mods))
        _p = subprocess.run([sys.executable, "-I", "-c", _code], capture_output=True,
                            text=True, timeout=300, cwd=_and_root,
                            env={"PATH": os.environ.get("PATH", ""), "HOME": _and_root,
                                 "PDG_BOT_TOKEN": "x"})
        _marks = [l[len("__RESULT__"):] for l in (_p.stderr or "").splitlines()
                  if l.startswith("__RESULT__")]
        _broken = _marks[-1] if _marks else "(没拿到结论标记)"
        if _p.returncode == 0 and _marks and not _broken:
            ok("Android 形态下 %d 个运行模块逐个 import 全部成功(含 bot 本体)" % len(_mods))
        else:
            bad("Android 上这些模块 import 不起来: %s%s"
                % (_broken, (_p.stderr or "")[-300:] if _p.returncode else ""))
finally:
    shutil.rmtree(_and_root, ignore_errors=True)

# 反向: 清单里不该有仓库里根本不存在的东西
ghost = [e for e in entries if not os.path.exists(os.path.join(ROOT, e[0]))]
if not ghost:
    ok("清单里每一项在仓库里都存在")
else:
    bad("清单指向不存在的文件: %r" % ghost)

# 动态导入点必须被算进来 —— 这条直接盯住"当初 emergency 是怎么漏的"
if "emergency" in NEED and "emergency" in imports_of(LOCAL["rescue"]):
    ok("动态导入点(_mod(\"emergency\"))被算进闭包")
else:
    bad("闭包没算到动态导入的 emergency —— 静态扫描又漏了")

# ── 2. 两条安装路径读同一份真源 ────────────────────────────────────────────
print()
print("── 2. 装机与升级共用同一份清单 ──")
inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
pdg = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
if "pdg_install_runtime_modules" in inst and "lib/modules.sh" in inst:
    ok("install.sh 走真源")
else:
    bad("install.sh 没走真源")
if pdg.count("pdg_install_runtime_modules") >= 2 and "lib/modules.sh" in pdg:
    ok("pdg update 与老装迁移都走真源")
else:
    bad("pdg.sh 没走真源(出现 %d 次)" % pdg.count("pdg_install_runtime_modules"))
# 逐条 install 的老写法不该再覆盖清单里的模块 —— 否则两处口径会漂移
stale = [n for n in sorted(INSTALLED)
         if re.search(r'install -m755 "\$REPO_DIR"/deploy/bot/%s\.py' % re.escape(n), inst)]
if not stale:
    ok("install.sh 里没有绕开真源的逐条安装")
else:
    bad("这些模块仍被逐条安装, 与真源会漂移: %s" % ", ".join(stale))

# ── 3. tests/rescuebox.py 只作镜像守卫 ─────────────────────────────────────
print()
print("── 3. 测试夹具只是镜像 ──")
rb = open(os.path.join(ROOT, "tests/rescuebox.py"), encoding="utf-8").read()
mirror = set(re.findall(r'"([a-z_0-9]+)\.py"', rb.split("PDG_BOT_MODULES")[1].split(")")[0])) \
    if "PDG_BOT_MODULES" in rb else set()
gap = sorted(mirror - INSTALLED)
if not gap:
    ok("夹具清单是安装真源的子集(它是镜像, 不是真源)")
else:
    bad("夹具里有真源没有的模块: %s" % ", ".join(gap))

# ── 4. 装的是普通文件, 不是指向仓库的软链 ──────────────────────────────────
print()
print("── 4. 安装形态 ──")
man_fn = re.search(r"pdg_install_runtime_modules\(\)\{.*?\n\}", man_txt, re.S)
body = man_fn.group(0) if man_fn else ""
if body and " -s" not in body and "ln " not in body:
    ok("安装函数用 install(1) 落普通文件, 没有 ln -s")
else:
    bad("安装函数疑似创建了软链: %r" % body[:200])
if "755" in man_txt and "644" in man_txt:
    ok("清单逐项声明了 mode(Python 755 / 常量源 644)")
else:
    bad("清单没有声明 mode")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

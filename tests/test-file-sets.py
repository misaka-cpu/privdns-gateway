#!/usr/bin/env python3
"""项目静态文件的三集合必须相等: install 装的 = update 同步的 = uninstall 删的。

为什么要有这条: 本轮之前有 11 个文件(Bot 本体、MITM 组件、:81 探测、健康检查、规则更新
脚本、iOS 描述文件模板)是在 install.sh 里各写一行 `install -m755 …` 装的, 不在任何清单里。
后果不是报错, 是静默的:
  · `pdg update` 从来不同步它们 —— Bot 本体永远停在装机那一版, 修好的 bug 升级也带不过来;
  · uninstall 也不删 —— `.200` 上卸完还剩十来个项目程序文件, 而收尾文案说"已删除全部运行模块"。

三方现在共用 lib/modules.sh 的 `源路径 目标名 mode` 三元组。本用例盯的就是"没人再手写第二份
名单"以及"三个集合逐项相等"。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


def sh(script):
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                       cwd=ROOT, timeout=120)
    return r.stdout.strip().splitlines()


SRC = "source lib/modules.sh; "

print("== 1. 真源能表达源路径、目标名与 mode ==")
rows = [l.split() for l in sh(SRC + "pdg_platform_modules ios") if l.strip()]
bad_rows = [r for r in rows if len(r) != 3 or not re.match(r"^[0-7]{3}$", r[2])]
if rows and not bad_rows:
    ok("%d 项全部是 `源路径 目标名 mode` 三元组" % len(rows))
else:
    bad("清单里有 %d 行不是三元组: %r" % (len(bad_rows), bad_rows[:3]))

renamed = [(r[0], r[1]) for r in rows if os.path.basename(r[0]) != r[1]]
if len(renamed) >= 2:
    ok("能表达改名(%s)" % "、".join("%s→%s" % (os.path.basename(a), b) for a, b in renamed))
else:
    bad("改名项没被表达出来: %r" % renamed)

dirs = {os.path.dirname(r[0]) for r in rows}
if len(dirs) >= 3:
    ok("能表达跨源目录(%s)" % "、".join(sorted(dirs)))
else:
    bad("源目录只有 %r —— 靠 basename 猜目录是不行的" % dirs)

# mode 不是随便填的: 被当程序跑的 755, 只被读/source/import 的 644。
# 下面这两项是**数据**, 不该有执行位:
#   · rescue.sh —— 被 source 的常量单一事实源, 从不执行;
#   · pdg-dot.mobileconfig.tmpl —— 发给手机的描述文件模板。
# 这是测试里的期望表, 不是第二份部署清单 —— 部署仍然只有 lib/modules.sh 一处。
# 仓库里所有文件的 git mode 都是 100644, 所以拿 git 的可执行位当判据是行不通的。
_DATA_FILES = {"rescue.sh", "pdg-dot.mobileconfig.tmpl"}
_want = {r[1]: ("644" if r[1] in _DATA_FILES else "755") for r in rows}
_mode_bad = [(r[1], r[2], _want[r[1]]) for r in rows if r[2] != _want[r[1]]]
if not _mode_bad:
    ok("mode 与文件类型一致(.py/.sh=755, 数据文件=644)")
else:
    bad("mode 不对: %s" % "、".join("%s 是 %s 应为 %s" % t for t in _mode_bad))

missing_src = [r[0] for r in rows if not os.path.exists(os.path.join(ROOT, r[0]))]
if not missing_src:
    ok("每一项的仓库源路径都真实存在")
else:
    bad("这些源路径不存在: %s" % "、".join(missing_src))

print("\n== 2. 平台切分 ==")
common = [l.split()[1] for l in sh(SRC + "pdg_platform_modules") if l.strip()]
ios = [l.split()[1] for l in sh(SRC + "pdg_platform_modules ios") if l.strip()]
android = [l.split()[1] for l in sh(SRC + "pdg_platform_modules android") if l.strip()]
ios_only = sorted(set(ios) - set(common))
if android == common and len(ios_only) == 6:
    ok("Android = 通用集(%d 项); iOS 另加 %d 项: %s"
       % (len(common), len(ios_only), "、".join(ios_only)))
else:
    bad("平台切分不对: android=%d common=%d ios_only=%r" % (len(android), len(common), ios_only))

print("\n== 3. install / update / uninstall 三方都读同一份真源 ==")
inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
pdg = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
resc = open(os.path.join(ROOT, "lib/rescue.sh"), encoding="utf-8").read()

# install.sh 里不许再出现"手写一行装进 /opt/pdg-bot"。注释行不算 —— 说明问题时会引用旧写法。
# install.sh **和** pdg.sh(update 路径)两边都要查。第一版只扫了 install.sh, 结果 cmd_update
# 里那份一模一样的手写清单原封不动地留着 —— 两份名单只要有一处忘了改就是新旧混装。
# install.sh **和** pdg.sh(cmd_update / migrate_deploy_botfiles)都要扫。
# 上一轮只扫 install.sh, 于是 cmd_update 里那份一模一样的手写清单原封不动地留着 ——
# 两份名单只要有一处忘了改就是新旧混装, 而那不报错, 只静默降级。
# glob 同样算第二名单: `deploy/bot/*.py` 会把仓库里任何新加的 .py 装进 /opt/pdg-bot,
# 而那些文件不在 manifest 里, 卸载不会删、mode 也无从对齐。
_hand = []
for _name, _txt in (("install.sh", inst), ("deploy/bot/pdg.sh", pdg)):
    _code = "\n".join(l for l in _txt.split("\n") if not l.lstrip().startswith("#"))
    for _m in re.findall(r"install -m\d+ [^\n]*?/opt/pdg-bot[^\n]*", _code):
        _hand.append("%s: %s" % (_name, _m.strip()[:80]))
if not _hand:
    ok("install.sh 与 pdg.sh 都不再手写 /opt/pdg-bot 的部署行")
else:
    bad("仍有 %d 行手写部署: %s" % (len(_hand), _hand[0]))

_globs = []
for _name, _txt in (("install.sh", inst), ("deploy/bot/pdg.sh", pdg)):
    _code = "\n".join(l for l in _txt.split("\n") if not l.lstrip().startswith("#"))
    for _m in re.findall(r"for \S+ in [^\n]*deploy/bot/\*\.(?:py|sh)[^\n]*", _code):
        _globs.append("%s: %s" % (_name, _m.strip()[:70]))
if not _globs:
    ok("没有用 glob 代表静态全集")
else:
    bad("仍有 glob 兜底(隐式的第二名单): %s" % _globs[0])

if "pdg_install_runtime_modules" in inst and "pdg_install_runtime_modules" in pdg:
    ok("install 与 update 走同一个安装函数")
else:
    bad("install/update 没走同一个函数")
if "pdg_platform_modules" in resc:
    ok("uninstall 的成员枚举也从同一份真源取")
else:
    bad("uninstall 另有一份名单")

print("\n== 4. 三集合逐项相等 ==")
members = sh("source lib/rescue.sh; PDG_MODULES_LIB=lib/modules.sh pdg_project_members")
un_set = {m.split("/", 2)[-1] for m in members if m.startswith("opt/pdg-bot/")}
legacy = set(sh(SRC + "pdg_legacy_modules"))
static = set(ios)
if un_set == static | legacy:
    ok("uninstall 删除集 = 静态全集(%d) + 旧版遗留(%d)" % (len(static), len(legacy)))
else:
    bad("卸载集与静态集对不上 少=%s 多=%s"
        % (sorted(static - un_set), sorted(un_set - static - legacy)))

print("\n== 5. 用户数据/运行状态/缓存不得混进静态集 ==")
NOT_STATIC = {"rulesets.json": "用户持久数据", "dot-domain": "用户持久数据",
              "health-state.json": "运行时生成", "__pycache__": "缓存"}
leaked = [f for f in NOT_STATIC if f in static]
if not leaked:
    ok("用户数据、运行状态与缓存都不在静态清单里(%s)"
       % "、".join("%s=%s" % (k, v) for k, v in NOT_STATIC.items()))
else:
    bad("这些不该进静态集: %s" % "、".join(leaked))
# 只看 `--purge` 块**之外**的代码 —— 整目录删除在 --purge 里是它的既定语义, 不该判红。
# 第一版拿"同一行里有没有 --purge"来判, 而那个判断写在外层 if 上, 于是误报。
_un = open(os.path.join(ROOT, "uninstall.sh"), encoding="utf-8").read()
_i = _un.find('== "--purge"')
_outside = _un if _i < 0 else _un[:_i]
_hits = [l for l in _outside.split("\n")
         if "rm -rf" in l and "/opt/pdg-bot" in l and not l.lstrip().startswith("#")
         and "__pycache__" not in l]
if not _hits:
    ok("非 --purge 路径不整目录删除 /opt/pdg-bot")
else:
    bad("非 --purge 路径上整目录删除了 /opt/pdg-bot: %s" % _hits[0].strip()[:80])

print("\n== 6. rescue 保护集仍是最小子集 ==")
prot = [x.strip() for x in re.search(r'PDG_RESCUE_PROTECTED_MEMBERS="(.*?)"', resc, re.S)
        .group(1).splitlines() if x.strip()]
prot_bot = {os.path.basename(p) for p in prot if p.startswith("opt/pdg-bot/")}
if prot_bot < static and len(prot_bot) == 6:
    ok("保护集 %d 项 ⊊ 静态全集 %d 项(仍是最小 breakglass 子集)" % (len(prot_bot), len(static)))
else:
    bad("保护集不是最小子集: %d 项 %r" % (len(prot_bot), sorted(prot_bot)))

print("\n== 7. update 必须覆盖而不是跳过 ==")
mods = open(os.path.join(ROOT, "lib/modules.sh"), encoding="utf-8").read()
fn = mods[mods.index("pdg_install_runtime_modules()"):]
fn = fn[:fn.index("\n}\n") + 1]
if "install -m" in fn and not re.search(r"\[\[ -f .*dest.*\]\] \|\| ", fn):
    ok("安装函数是无条件覆盖写, 不存在「文件已在就跳过」")
else:
    bad("安装函数里有跳过分支 —— 升级会留下旧版文件")
if "__pycache__" in fn:
    ok("换过 .py 之后清掉旧字节码")
else:
    bad("不清 __pycache__ —— 新源码可能被陈旧 .pyc 顶掉")

print("\n== 8. systemd 引用的脚本都在清单里 ==")
units = []
for d in ("deploy/bot", "deploy/ios"):
    p = os.path.join(ROOT, d)
    for f in os.listdir(p):
        if f.endswith((".service", ".timer")):
            units.append(os.path.join(p, f))
refs = set()
for u in units:
    for m in re.finditer(r"/opt/pdg-bot/([A-Za-z0-9_.-]+)", open(u, encoding="utf-8").read()):
        refs.add(m.group(1))
# 6.2A staged: 源码与 unit 已进仓库, **生命周期尚未接线**(不进安装清单、不迁移、
# 不 enable/start)。这是一个显式且受限的中间状态, 不是通用白名单 —— 只允许下面这两个
# 精确文件名, 多一个未归属的 deploy 文件就判红。接线属于 6.2B。
STAGED_6_2A = frozenset()   # 6.2B: dotwitness.py 已进运行模块清单, 不再 staged

gone = sorted(refs - static - STAGED_6_2A)
if not gone:
    ok("unit 引用的 %d 个 /opt/pdg-bot 文件都在静态清单或 6.2A staged 集里" % len(refs))
else:
    bad("unit 引用了既不在清单、也不在 staged 集里的文件: %s" % "、".join(gone))

# staged 集自身的两道门, 防它变成"多塞什么都行"的口子。
# 判据是**集合相等**而不是"实际引用里有它": 后者放得过一个挂在集合里却没人用的名字,
# 那正是白名单腐化的第一步。
if set(STAGED_6_2A) == (refs & STAGED_6_2A):
    ok("staged 集与实际 unit 引用精确相等(%s), 没有空挂的条目"
       % "、".join(sorted(STAGED_6_2A)))
else:
    bad("staged 集有空挂条目: 集合=%s 实际被引用=%s"
        % (sorted(STAGED_6_2A), sorted(refs & STAGED_6_2A)))

# staged 的东西**必须还没接线** —— 一旦被装进安装清单, 说明 6.2B 已经开始,
# 那时这条 staged 例外就该删掉, 而不是继续挂着掩盖真实状态。
wired = sorted(STAGED_6_2A & static)
if not wired:
    ok("staged 文件确实尚未接入安装清单(6.2A 边界成立)")
else:
    bad("staged 文件已进安装清单, staged 例外应当删除: %s" % "、".join(wired))

total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

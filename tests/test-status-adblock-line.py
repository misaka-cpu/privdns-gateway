#!/usr/bin/env python3
"""去广告的状态要出现在**主状态页**上, 不用点进二级菜单。

现状: `pdg status` 与 Telegram 主状态页都不提去广告 —— 一台开着去广告的机器和一台没开的,
主状态页上看起来一模一样。而这是个会改变解析行为的开关。

这一支同时钉住措辞: 那几个数字是**表的大小**, 不是命中次数。本项目没有命中统计(四条实现
路径都调查过并否决, 见 HANDOFF), 主状态页更不该造出一个看着像命中数的数字。

**未启用时也要出现。** 只在启用时才显示的话, 一台"以为开着其实没开"的机器在主状态页上
仍然看不出区别 —— 那正是最需要它说话的情形。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


PDGSH = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
BOT = open(os.path.join(ROOT, "deploy/bot/pdg-bot.py"), encoding="utf-8").read()

print("══ 1. CLI 的 pdg status 里有去广告一行 ══")
m = re.search(r"\ncmd_status\(\)\{(.*?)\n\}", PDGSH, re.S)
(ok if m else bad)("抽得到 cmd_status")
if m:
    body = m.group(1)
    (ok if "去广告" in body else bad)("cmd_status 里提到去广告")
    # 判的是性质不是实现方式: cmd_status 里**不许自己数规则**(那会变成第二份计数逻辑),
    # 它只能调那个唯一的渲染函数。第一版断言写成"函数体里要出现 _adb_count_rules",
    # 而实际是经 _adblock_status_line 间接调的 —— 那是把断言写死在某一种实现上。
    (ok if "_adblock_status_line" in body else
     bad)("cmd_status 调唯一的渲染函数")
    (ok if "grep -c" not in body and "grep -vc" not in body else
     bad)("cmd_status 里没有自己数规则的 grep")

print()
print("══ 2. Telegram 主状态页里也有 ══")
m2 = re.search(r"\ndef status_text\(\):(.*?)\n\ndef ", BOT, re.S)
(ok if m2 else bad)("抽得到 status_text")
if m2:
    b2 = m2.group(1)
    (ok if "去广告" in b2 else bad)("status_text 里提到去广告")

print()
print("══ 3. 措辞: 不许把表的大小说成命中次数 ══")
for src, name in ((m.group(1) if m else "", "cmd_status"),
                  (m2.group(1) if m2 else "", "status_text")):
    hits = [w for w in ("命中", "拦截次数", "已拦", "阻断次数") if w in src]
    (ok if not hits else bad)("%s 的文案里没有「%s」" % (name, "/".join(hits)))
    # 也不许出现「N 次」这种形状
    nums = re.findall(r"\d+\s*次", src)
    (ok if not nums else bad)("%s 里没有「N 次」这种像命中数的写法(实得 %r)" % (name, nums))

print()
print("══ 4. 真跑 CLI: 启用与未启用都要说话 ══")
import shutil                                                # noqa: E402
import subprocess                                            # noqa: E402
import tempfile                                              # noqa: E402
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard                                              # noqa: E402

W = tmpguard.mkdtemp(prefix="pdg-statusline.")
os.makedirs(os.path.join(W, "state"), exist_ok=True)
open(os.path.join(W, "allow.txt"), "w").close()
open(os.path.join(W, "block.txt"), "w").write("a.example\nb.example\n")
open(os.path.join(W, "state", "effective_block.txt"), "w").close()
open(os.path.join(W, "state", "effective_list.txt"), "w").write(
    "".join("x%d.example\n" % i for i in range(1234)))

# 只抽那一行所依赖的函数, 单独跑 —— 整个 cmd_status 要 systemctl, 跑不动
need = ["_adb_count_rules", "_adblock_intent", "_adblock_status_line"]
missing = [f for f in need if ("\n%s()" % f) not in PDGSH]
(ok if not missing else bad)("依赖的函数都在(缺: %r)" % missing)
if not missing:
    cl = os.path.join(W, "c.sh")
    with open(cl, "w", encoding="utf-8") as f:
        f.write("set -uo pipefail\n")
        for fn in need:
            f.write(subprocess.run(["sed", "-n", "/^%s()/,/^}/p" % fn,
                                    os.path.join(ROOT, "deploy/bot/pdg.sh")],
                                   capture_output=True, text=True).stdout + "\n")
    env = dict(os.environ,
               ADB_STATE_DIR=os.path.join(W, "state"),
               ADB_USER_ALLOW=os.path.join(W, "allow.txt"),
               ADB_USER_BLOCK=os.path.join(W, "block.txt"),
               PROFILE_ENV=os.path.join(W, "profile.env"))
    # 未启用
    open(env["PROFILE_ENV"], "w").write("PDG_ADBLOCK_ENABLED=0\n")
    r = subprocess.run(["bash", "-c", "source %s; _adblock_status_line" % cl],
                       capture_output=True, text=True, env=env)
    out_off = (r.stdout or "").strip()
    (ok if out_off else bad)("未启用时也输出一行(实得 %r)" % out_off)
    (ok if "未启用" in out_off or "关闭" in out_off else
     bad)("未启用时说清楚是关着的(实得 %r)" % out_off)
    (ok if "\n" not in out_off else bad)("未启用那行是单行(实得 %r)" % out_off)
    # 已启用
    open(env["PROFILE_ENV"], "w").write("PDG_ADBLOCK_ENABLED=1\n")
    r2 = subprocess.run(["bash", "-c", "source %s; _adblock_status_line" % cl],
                        capture_output=True, text=True, env=env)
    out_on = (r2.stdout or "").strip()
    # 两个数字必须**分别具名断言**, 不能用子串包含。`"2" in out_on` 看着像在验"自定义 2 条",
    # 实际同一行里的 1234 就含着字符 2 —— 把产品改成恒定输出"自定义 0 条", 这一格照样绿
    # (实测: 改坏之后 23/23 全通过)。一个永远不会红的断言比没有断言更糟, 它还在冒充证据。
    mline = re.search(r"第三方表\s*(\d+)\s*条\s*/\s*自定义\s*(\d+)\s*条", out_on)
    (ok if mline else
     bad)("已启用那行能按结构解析出两个具名字段(实得 %r)" % out_on)
    if mline:
        (ok if mline.group(1) == "1234" else
         bad)("第三方表 = 1234(实得 %s, 整行 %r)" % (mline.group(1), out_on))
        (ok if mline.group(2) == "2" else
         bad)("自定义 = 2(实得 %s, 整行 %r)" % (mline.group(2), out_on))
    (ok if "\n" not in out_on else bad)("已启用那行是单行(实得 %r)" % out_on)
    (ok if not re.findall(r"\d+\s*次", out_on) else
     bad)("那一行里没有「N 次」(实得 %r)" % out_on)

print()
print("══ 5. Bot 调的那个子命令必须真的存在 ══")
# 上一轮 `source list --json` 就是这么假绿的: 测试里 sh 是打桩的, 无论传什么都回结果,
# 于是从没验过 CLI 认不认这个参数(而当时它不认)。这一格拿 Bot 真正会发的 argv 去对
# pdg.sh 的 case 分支。
m3 = re.search(r"def _adblock_line\(\):(.*?)\n\ndef ", BOT, re.S)
(ok if m3 else bad)("抽得到 _adblock_line")
if m3:
    sub = re.findall(r'"adblock",\s*"([a-z-]+)"', m3.group(1))
    (ok if sub else bad)("抽得到它调的子命令(实得 %r)" % sub)
    for name in sub:
        (ok if re.search(r"\n    %s\)" % re.escape(name), PDGSH) else
         bad)("pdg.sh 的 cmd_adblock 里有 `%s)` 分支 —— 没有的话 Bot 拿到的是用法串" % name)
    # 用法串也要列出来(加了子命令忘了写用法, 那条命令就存在但没人知道)。
    # 注意有**多处** "用法: pdg adblock" —— 子命令各有各的。要找的是那条列着 status/enable
    # 的**主**用法串, 不是第一处(第一处是 `source` 的, 第一版就取错了)。
    usages = re.findall(r'用法: pdg adblock <[^"]*', PDGSH)
    main = [u for u in usages if "status|" in u]
    (ok if main else bad)("找得到 adblock 的主用法串(实得 %d 条候选)" % len(usages))
    for name in sub:
        (ok if main and name in main[0] else
         bad)("主用法串里列了 %s(实得 %r)" % (name, main[0][:80] if main else None))

print("-" * 62)
print("test-status-adblock-line.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

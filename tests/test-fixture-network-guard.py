#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""沙箱夹具不得偷偷联网。

起因(v1.11.9): tests/test-migrate-drop-singbox.sh 把生产的 _activate_mihomo_core 抽进沙箱跑。
v1.11.7 把那里的跳过判据从 pdg_mihomo_is_version(只问自报版本、走 PATH)收紧成
pdg_mihomo_binary_ok(问绝对路径上的真文件 + 内容摘要)之后, 夹具里的 shell 桩不再满足判据 ——
于是这支 lint 测试**每跑一次就真去 GitHub 下 8 次 mihomo**。它不报错、断言数不变、照样 18/0,
只是从"确定性测试"变成了"网络运气的函数"。直到 main 的 run 33455929038 撞上一次
`curl: (35) Recv failure: Connection reset by peer` 才红。

生产侧那个改动是对的(它堵的是供应链后门), 坏掉的是夹具。这类退化没有报错、没有信号,
唯一能防的办法是把约束写成规则:

  **凡是把「函数体里有 curl」的生产函数抽进沙箱执行的 lint 用例, 必须自带 curl 禁令桩。**

禁令桩让"沙箱联网"从一件静悄悄的事变成一条点名 URL 的断言。规则只覆盖真正有联网能力的
闭包 —— 抽了别的函数的用例不受影响, 免得变成一条人人都要绕的形式主义。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")
TESTS_DIR = os.path.join(ROOT, "tests")

npass = nfail = 0


def ok(m):
    global npass
    print("[OK]   " + m)
    npass += 1


def bad(m):
    global nfail
    print("[FAIL] " + m)
    nfail += 1


def fn_bodies(path):
    """pdg.sh 里 `name(){` 到下一个顶格 `}` 之间的函数体。"""
    lines = io.open(path, encoding="utf-8").read().splitlines()
    out, i = {}, 0
    while i < len(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\{\s*$", lines[i])
        if m:
            j = i + 1
            while j < len(lines) and lines[j] != "}":
                j += 1
            out[m.group(1)] = "\n".join(lines[i:j + 1])
            i = j
        i += 1
    return out


EXTRACT = re.compile(r"sed -n '/\^([A-Za-z_][A-Za-z0-9_]*)\(\)\{/,/\^\}/p'")
# 命令位上的 curl —— `# curl …` 这种注释不算, `curl_foo` 这种别的名字也不算
CURL = re.compile(r"(?:^|[\s;(`]|\$\(|&&|\|\|)curl\s", re.M)
STUB = re.compile(r"^\s*curl\(\)\{", re.M)

bodies = fn_bodies(PDG)
if len(bodies) < 50:
    bad("从 pdg.sh 只解析出 %d 个函数 —— 解析器坏了, 这条守卫等于没跑" % len(bodies))
else:
    ok("从 pdg.sh 解析出 %d 个函数体" % len(bodies))

# 判据源自己得有牙齿: 已知含 curl 的那个函数必须被认出来
if "_activate_mihomo_core" in bodies and CURL.search(bodies["_activate_mihomo_core"]):
    ok("判据源自检: _activate_mihomo_core 被认出含 curl(联网能力可判)")
else:
    bad("判据源自检失败: _activate_mihomo_core 没被认成含 curl —— 规则会全体放行")

offenders, checked = [], []
for name in sorted(os.listdir(TESTS_DIR)):
    if not name.startswith("test-") or not name.endswith(".sh"):
        continue
    p = os.path.join(TESTS_DIR, name)
    src = io.open(p, encoding="utf-8").read()
    risky = [n for n in EXTRACT.findall(src) if n in bodies and CURL.search(bodies[n])]
    if not risky:
        continue
    checked.append((name, risky))
    if not STUB.search(src):
        offenders.append((name, risky))

if not checked:
    bad("一支「抽了含 curl 的生产函数」的用例都没找到 —— 抽取写法变了, 守卫已失效")
else:
    ok("扫到 %d 支把含 curl 的生产函数抽进沙箱的用例: %s"
       % (len(checked), ", ".join("%s(%s)" % (n, ",".join(r)) for n, r in checked)))

if offenders:
    bad("这些用例把含 curl 的生产函数抽进沙箱却没有 curl 禁令桩(会静默联网): "
        + "; ".join("%s → %s" % (n, ",".join(r)) for n, r in offenders))
else:
    ok("它们都带了 curl 禁令桩")

print("─" * 40)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

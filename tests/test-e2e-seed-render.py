#!/usr/bin/env python3
"""E2E 夹具必须把防火墙模板**渲染完整**。

── 这条缺口值多少 ─────────────────────────────────────────────────────────────
`e2e_seed_nft()` 造的是"一台已装好的机器"。它渲染模板时漏了 `__RESCUE_PORT__`,
于是沙箱里的 /etc/nftables.conf 带着未替换的字面量。

平时无害 —— 没有判据去读那个位置。直到 `migrate_firewall_template_sync` 开始从
**机器现行规则**反解渲染参数: 救援端口那一行长成 `tcp dport __RESCUE_PORT__ accept`,
数字反解不出来, 函数按设计 fail-closed 跳过同步, 防火墙保持旧规则, doctor 判
「缺少 tailscale0 排除规则」, cmd_update 整次回滚。CI 六个升级类 job 同时红,
报的都是这一条。

**产品函数没有错** —— 它就该在参数反解不出来时拒绝重建一台机器的防火墙。错的是夹具
造出来的那台"机器"根本不像真机: 真机装机流程会把三个占位符全部渲染掉。

所以这支盯的是"渲染闭包": 模板有几个占位符, 夹具就得替换几个, 一个都不能漏。
判据不写死占位符清单 —— 从模板和夹具源码两边各自读出来再比, 将来模板新增占位符而
夹具忘了跟进, 这里会立刻红。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TPL = os.path.join(ROOT, "deploy", "firewall", "nftables-mihomo.conf")
LIB = os.path.join(HERE, "e2e-lib.sh")

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


print("══ E2E 夹具的模板渲染闭包 ══\n")

with open(TPL, encoding="utf-8") as f:
    tpl = f.read()
with open(LIB, encoding="utf-8") as f:
    lib = f.read()

TOKEN_RE = r"__[A-Z][A-Z0-9_]*__"
tpl_tokens = set(re.findall(TOKEN_RE, tpl))
print("── 一、模板与夹具各自的占位符集合 ──")
ok("模板占位符: %s" % ", ".join(sorted(tpl_tokens)))

m = re.search(r"^e2e_seed_nft\(\)\{(.*?)^\}", lib, re.M | re.S)
if not m:
    bad("找不到 e2e_seed_nft")
    print("\n通过 %d, 失败 %d" % (npass, nfail))
    sys.exit(1)
seed = m.group(1)
seed_tokens = set(re.findall(TOKEN_RE, seed))
ok("夹具替换的占位符: %s" % ", ".join(sorted(seed_tokens)))

print("\n── 二、闭包判据 ──")
missing = tpl_tokens - seed_tokens
if missing:
    bad("夹具漏渲染 %s —— 沙箱造出来的机器不像真机, 参数反解会失败"
        % ", ".join(sorted(missing)))
else:
    ok("模板的每个占位符夹具都替换了(闭包完整)")

stale = seed_tokens - tpl_tokens
if stale:
    ok("夹具里有模板已不用的替换 %s(无害, 但该清)" % ", ".join(sorted(stale)))
else:
    ok("夹具没有失效的替换项")

print("\n── 三、后果: 拿夹具那套替换去渲染, 残留什么 ──")
rendered = tpl
for t in seed_tokens & tpl_tokens:
    rendered = rendered.replace(t, "X")
residue = re.findall(TOKEN_RE, rendered)
if residue:
    from collections import Counter
    c = Counter(residue)
    bad("渲染产物仍残留 %s —— 真机上不会出现未替换的占位符"
        % ", ".join("%s×%d" % (k, v) for k, v in sorted(c.items())))
else:
    ok("渲染产物无残留占位符")

print("\n── 四、救援端口必须能被反解成数字 ──")
# 这正是 migrate_firewall_template_sync 用的那条反解, 不另写一套
rp = re.findall(r"ip saddr \S+ tcp dport (\d+) accept", rendered)
if rp:
    ok("救援端口可反解为数字: 共 %d 处" % len(rp))
else:
    bad("救援端口反解不出数字 —— 生产函数会据此安全跳过同步, 防火墙停在旧规则")

print("\n── 五、fail-closed 守卫: 渲染后残留任何 token 都必须让夹具失败 ──")
if re.search(r"__\[A-Z\]\[A-Z0-9_\]\*__|残留.*占位符|未替换的占位符", seed):
    ok("夹具带残留占位符守卫")
else:
    bad("夹具没有残留占位符守卫 —— 将来模板新增 token 又会静默漏渲染")

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

#!/usr/bin/env python3
"""migrate_dotwitness 的每一条失败出口都必须说清"卡在哪", 而且不许回显私有内容。

为什么要有这支: 这个函数是 `run_all_migrations` 里仅有的两个 `|| rc=1` 之一 —— 它返回
非 0, 整次 `pdg update` 就回滚。上层能打印的只有一句"迁移(__migrate)失败"; 到底是文件
没落地、域名不合法、候选没过 mosdns 校验, 还是起来了却没在 5399 上监听, 全靠这个函数
自己讲。少一条理由, 运维就得靠猜。

真出过的两件事都钉在这里:
  · `mktemp -d || return 1` 一个字都不说就返回 —— 那条路径上层无从定位;
  · 域名不合法时把读到的内容原样打进日志(`(​$dom)`)。那个值就是本机 DoT 的域名, 会
    进更新日志、doctor 输出和用户贴出来的排障截图。报类别足够定位, 回显只是摊开私有信息。

判据是静态的: 解析函数体, 逐条 `return 1` 往回找它的理由。刻意**不锚在具体文案上**
(那种锚点一改就断), 只要求"有、唯一、不含敏感值"。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PDG = os.path.join(ROOT, "deploy", "bot", "pdg.sh")

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def body(src, name):
    """取顶层函数体: 从 `name(){` 到第一条顶格 `}`。"""
    m = re.search(r"^%s\(\)\{$" % re.escape(name), src, re.M)
    if not m:
        raise SystemExit("找不到 %s() —— 判据失效" % name)
    start = src[:m.start()].count("\n")
    lines = src.splitlines()
    for i in range(start + 1, len(lines)):
        if lines[i] == "}":
            return start + 1, lines[start:i + 1]
    raise SystemExit("%s() 没有收口 —— 判据失效" % name)


src = open(PDG, encoding="utf-8").read()
base, lines = body(src, "migrate_dotwitness")
print("── migrate_dotwitness: 第 %d 行起, 共 %d 行 ──" % (base, len(lines)))

PRINT = re.compile(r"\b(c_y|c_r|c_g|echo|printf)\b")
# 一条 return 1 的"理由"= 它自己那行, 或紧邻其上的连续若干行里最近的一条打印。
# 允许往回找几行: 真实写法里 c_y 与 return 1 之间常隔着一行 grep/sed 补充细节。
LOOKBACK = 4

exits, silent = [], []
for i, ln in enumerate(lines):
    if not re.search(r"\breturn 1\b", ln):
        continue
    reason = None
    for j in range(i, max(-1, i - LOOKBACK) - 1, -1):
        if PRINT.search(lines[j]):
            reason = lines[j].strip()
            break
    if reason is None:
        silent.append((base + i, ln.strip()))
    else:
        exits.append((base + i, reason))

print("   失败出口 %d 条" % (len(exits) + len(silent)))
if silent:
    bad("有 %d 条失败出口一个字都不说 —— 上层只剩'迁移失败', 定位不了" % len(silent))
    for lineno, ln in silent[:3]:
        print("       pdg.sh:%d  %s" % (lineno, ln[:70]))
else:
    ok("全部 %d 条失败出口都给了理由(没有静默 return 1)" % len(exits))

# ── 理由必须能互相区分 ────────────────────────────────────────────────────────
# 两条不同的失败印出同一句话, 等于没分。取每条理由里的文本字面量做比较。
def literal(reason):
    m = re.search(r'"([^"]*)"', reason)
    return (m.group(1) if m else reason).strip()


seen = {}
dup = []
for lineno, reason in exits:
    key = literal(reason)
    if key in seen:
        dup.append((seen[key], lineno, key))
    else:
        seen[key] = lineno
if dup:
    bad("有 %d 组失败出口共用同一句理由, 区分不开" % len(dup))
    for a, b, key in dup[:3]:
        print("       pdg.sh:%d 与 :%d 都说 %r" % (a, b, key[:50]))
else:
    ok("%d 条理由两两不同, 每个失败阶段可唯一定位" % len(seen))

# ── 候选校验失败 与 5399 未监听 必须是两句话 ──────────────────────────────────
# 这两个是最容易被混成一句的: 都表现为"witness 没起来"。但处置完全不同 ——
# 前者是配置写错(改配置), 后者是进程起来了却没绑上(查权限/端口占用)。
val = [l for _, l in exits if "校验" in l]
lis = [l for _, l in exits if "5399" in l]
if val and lis and literal(val[0]) != literal(lis[0]):
    ok("候选校验失败 与 5399 未监听 是两条独立理由, 不会混为一谈")
else:
    bad("候选校验失败(%d 条) 与 5399 未监听(%d 条) 没能各自成句" % (len(val), len(lis)))

# ── 隐私门: 理由里不许出现读到的域名/证书/token ───────────────────────────────
SECRET = re.compile(r"\$dom\b|\$\{dom\}|\$_?tok|\$token|\$qname|\$saddr|"
                    r"cat +/opt/pdg-bot/dot-domain|\$cert")
leak = [(n, r) for n, r in exits if SECRET.search(r)]
if leak:
    bad("有 %d 条理由把私有值回显进日志(域名/token/证书/查询名)" % len(leak))
    for lineno, r in leak[:3]:
        print("       pdg.sh:%d  %s" % (lineno, r[:70]))
else:
    ok("没有任何理由回显 dot-domain / token / 证书 / 查询名")

# 缺失 与 非法 要分开报 —— 合成一句的话, 运维不知道该去建文件还是去改内容
dom_reasons = [l for _, l in exits if "DoT 域名" in l]
if len(dom_reasons) >= 2:
    ok("域名问题分成 %d 类分别报(缺失 / 非法), 不是笼统一句" % len(dom_reasons))
else:
    bad("域名问题只有 %d 条理由 —— 缺失与非法没分开, 处置动作不同却给同一句话"
        % len(dom_reasons))

# ── rollback 失败不能被原始错误盖住 ───────────────────────────────────────────
# _dw_rollback 里那句"回滚不完整"是独立告警: 原始故障已经报过一次, 回滚又没收拾干净
# 是**第二件事**, 必须自己出声, 否则现场看起来像"失败了但已经还原"。
rb_start, rb_lines = body(src, "migrate_dotwitness")
rb = "\n".join(rb_lines)
if re.search(r"回滚不完整", rb) and re.search(r"人工核对", rb):
    ok("回滚不完整时单独告警并给出人工核对清单, 不被原始错误覆盖")
else:
    bad("找不到'回滚不完整'的独立告警 —— 回滚没收拾干净会被原始错误盖过去")

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

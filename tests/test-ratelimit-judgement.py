#!/usr/bin/env python3
"""限流判据必须认得**两个生产者写出来的两种形态**。

线上实测(jp2, v1.11.1)doctor 报:

    🟡 限流: mosdns 单客户端 QPS 兜底(rate_limiter)缺失或参数/动作异常

而那台机器的限流器完全正确 —— 插件在位、qps200/burst400/mask4-32/mask6-128 逐个对、
`!$client_limiter → reject 5` 也确实排在缓存之前。假警告。

根因: `!$client_limiter` 这一行有**两个生产者**, 写出来的形态不同 ——

    模板 deploy/mosdns/config.yaml:133
        - matches: "!$client_limiter"     # 单客户端超 QPS → REFUSED, 抢在缓存/上游之前拦掉
    migrate_mosdns_ratelimit 写出来的
        - matches: "!$client_limiter"

判据原本用 `(?:#[^\n]*)?` 容忍行尾注释, 两种都认。去广告那一轮为了不让新加的受管块注释骗过
`$lazy_cache` 的位置判断, 把判据改成在**剥过注释**的文本上匹配, 顺手把那段容忍去掉了 ——
可是剥注释用的是 `^\s*#.*$`, 只剥**整行**注释, 行尾注释原样留着。于是模板形态不再命中。

影响面: 全新装机走的就是模板渲染, **每一台新装的机器都会看到这条假警告**, 还被建议去跑
`pdg restart` 触发迁移 —— 追一个不存在的问题。功能没坏(限流由 mosdns 执行, doctor 只是
旁观者), 坏的是诚实性。

这一支把两种形态都钉死, 并且**保住当初那次修复要护的性质**: 受管块的注释不许骗过位置判断。
"""
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
TMPL = (ROOT / "deploy/mosdns/config.yaml").read_text(encoding="utf-8")

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


import checks          # noqa: E402


def verdict(conf_text):
    """真跑生产判据 check_mosdns_ratelimit, 返回 (等级, 文案)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8") as f:
        f.write(conf_text)
        path = f.name
    old = checks.MOSDNS_CONF
    try:
        checks.MOSDNS_CONF = path
        r = checks.check_mosdns_ratelimit()
    finally:
        checks.MOSDNS_CONF = old
        Path(path).unlink(missing_ok=True)
    return (r[0], r[2]) if r else ("none", "")


LINE_RE = re.compile(r'^(\s*- matches: "!\$client_limiter")(.*)$', re.M)

print("══ 0. 前提: 模板与迁移确实写出两种形态 ══")
m = LINE_RE.search(TMPL)
(ok if m else bad)("模板里找得到 `!$client_limiter` 那一行")
(ok if m and m.group(2).strip().startswith("#") else bad)(
    "模板那一行**带行尾注释**(实得 %r)" % (m.group(2).strip()[:40] if m else None))
mig = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
mm = re.search(r"step='''(.*?)'''", mig, re.S)
(ok if mm and "#" not in mm.group(1) else bad)(
    "migrate_mosdns_ratelimit 写出来的**不带**行尾注释")

# 两种形态: 模板原样 / 把行尾注释去掉(= 迁移写出来的样子)
TEMPLATE_SHAPE = TMPL
MIGRATED_SHAPE = LINE_RE.sub(lambda x: x.group(1), TMPL)

print()
print("══ 1. 两种形态都必须判绿 ══")
for label, conf in (("模板形态(带行尾注释, 全新装机)", TEMPLATE_SHAPE),
                    ("迁移形态(不带注释)", MIGRATED_SHAPE)):
    lvl, msg = verdict(conf)
    (ok if lvl == "ok" else bad)("%s → %s(%s)" % (label, lvl, msg[:52]))

print()
print("══ 2. 真有问题时仍要报 ══")
cases = [
    ("整段 limiter 缺失", re.sub(r"  - tag: client_limiter\n.*?\n.*?\n", "", TMPL, count=1, flags=re.S)),
    ("qps 被改坏", TMPL.replace("qps: 200", "qps: 20", 1)),
    ("burst 被改坏", TMPL.replace("burst: 400", "burst: 40", 1)),
    ("动作不是 reject 5", TMPL.replace("exec: reject 5", "exec: accept", 1)),
    ("判据整行被删", LINE_RE.sub("", TMPL)),
]
for label, conf in cases:
    lvl, _ = verdict(conf)
    (ok if lvl == "warn" else bad)("%s → 应 warn, 实得 %s" % (label, lvl))

print()
print("══ 3. 位置: 限流必须在缓存之前 ══")
# 把限流那两行搬到 $lazy_cache 之后
mv = LINE_RE.search(TMPL)
if mv:
    two = TMPL[mv.start():TMPL.index("\n", TMPL.index("exec: reject 5", mv.start())) + 1]
    moved = TMPL.replace(two, "", 1).replace("      - exec: $lazy_cache\n",
                                             "      - exec: $lazy_cache\n" + two, 1)
    lvl, _ = verdict(moved)
    (ok if lvl == "warn" else bad)("限流搬到缓存之后 → 应 warn, 实得 %s" % lvl)
else:
    bad("抽不出限流那两行, 位置这一格无从谈起")

print()
print("══ 4. 受管块的注释不许骗过位置判断(当初那次修复要护的性质)══")
# 去广告受管块里含 `$lazy_cache` 字样的注释, 曾让位置判断把注释当成真的 cache 位置。
poisoned = TMPL.replace("      - exec: $lazy_cache\n",
                        "      # 这一段排在 $lazy_cache 之前(注释里也提到了 $lazy_cache)\n"
                        "      - exec: $lazy_cache\n", 1)
lvl, _ = verdict(poisoned)
(ok if lvl == "ok" else bad)("注释里提到 $lazy_cache 不影响判绿(实得 %s)" % lvl)
# 反面: 真把限流搬到 cache 之后, 即使注释里怎么写也要报
poisoned_bad = LINE_RE.sub("", poisoned)
lvl2, _ = verdict(poisoned_bad)
(ok if lvl2 == "warn" else bad)("同样有注释但判据真缺失时仍然 warn(实得 %s)" % lvl2)

print()
print("══ 5. 判据的期望值必须挨着用它的那个函数 ══")
# `_RL_WARN` / `_RL_WANT` 的唯一消费者就是 check_mosdns_ratelimit。它们曾经被隔在 200 行
# 开外(v1.10.16 把 check_lan_proxy_routes 插在了中间)—— 行为没受影响, 但改判据的人得先
# 找到它们, 而"找不到就照着记忆改"正是判据悄悄漂掉的起点(这一版修的那条假警告就是这么来的)。
_src = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8").splitlines()
_pos = {}
for _i, _l in enumerate(_src, 1):
    if _l.startswith("_RL_WARN =") and "warn" not in _pos:
        _pos["warn"] = _i
    if _l.startswith("_RL_WANT =") and "want" not in _pos:
        _pos["want"] = _i
    if _l.startswith("def check_mosdns_ratelimit(") and "fn" not in _pos:
        _pos["fn"] = _i
(ok if len(_pos) == 3 else bad)("三处都找得到(实得 %r)" % _pos)
if len(_pos) == 3:
    _gap = max(_pos["fn"] - _pos["warn"], _pos["fn"] - _pos["want"])
    (ok if 0 < _gap <= 20 else
     bad)("常量就在函数上方 20 行内(实得相隔 %d 行 —— 中间又被插进别的东西了)" % _gap)
    # 反面: 它们**必须**在函数之前(不能被挪到后面, 那样 import 时就 NameError)
    (ok if _pos["warn"] < _pos["fn"] and _pos["want"] < _pos["fn"] else
     bad)("常量定义在函数之前")
# 还有一条更要紧的: 别处不许再出现第二份同名期望值
_dups = [i for i, l in enumerate(_src, 1) if l.startswith("_RL_WANT =")]
(ok if len(_dups) == 1 else bad)("_RL_WANT 只有一处定义(实得 %r)" % _dups)

print("-" * 62)
print("test-ratelimit-judgement.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

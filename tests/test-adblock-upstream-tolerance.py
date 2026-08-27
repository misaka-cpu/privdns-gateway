#!/usr/bin/env python3
"""第三方表的容错边界: 下划线主机名, 与"一行坏不该废掉整张表"。

线上实测(从 jp 取真实的 adblockfilters mosdns 表, 215320 行)——

    _REJECT_HINTS 命中: 无
    含语法字符的行: 0
    形态认不出的行: 0
    不匹配 _DOMAIN_RE 的行: 1
       L68711: 'fb_servpub-a.akamaihd.net'

**21.5 万条因为一个下划线全废。** 两个原因叠在一起:

  ① `_DOMAIN_RE` 按 RFC 1123 的 hostname 规矩不放行下划线。但 DNS 协议本身是允许的
     (`_dmarc` / `_acme-challenge` 就是), 而作为**阻断规则的模式串**, 下划线不造成任何
     歧义或注入 —— 拒掉它等于对一类真实存在、也确实该拦的名字视而不见。
  ② parse_source 是"一行坏、整份废"。那条规矩的核心担忧是对的(注释里写着: 部分解析出来的
     表少了多少条没人知道), 但对**第三方表**有个副作用: 用户对上游没有控制权, 上游一行手滑
     就整张表用不了, 代价不成比例。

修法要同时保住两边:
  · 下划线放行, **且只放行下划线** —— 通配符 / 路径 / ABP / 正则 / IP 字面量一条不松;
  · 逐行域名校验失败改成**跳过并计数**, 但跳过比例超阈值仍然整份拒(fail-closed);
  · **结构性**不对(HTML 错页 / ABP 语法 / 认不出的形态)仍然整份拒 —— 那不是"有几行坏",
    是"这压根不是我们要的文件"。
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
import adblock          # noqa: E402

# 红灯阶段这些还不存在。缺了就让对应判据红, 而不是让整支测试崩在 AttributeError 上 ——
# 崩掉的话后面每一格都跑不到, 红灯就看不出覆盖面。
if not hasattr(adblock, "parse_source_ex"):
    adblock.parse_source_ex = lambda t: (adblock.parse_source(t), -1, "<parse_source_ex 尚不存在>")
adblock.LIMITS.setdefault("max_skip_ratio", None)

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def body(n, extra=()):
    """造一份 n 条合法域名 + extra 若干行的表。"""
    lines = ["# header"] + ["a%d.invalid" % i for i in range(n)] + list(extra)
    return "\n".join(lines) + "\n"


print("══ 1. 下划线主机名必须被接受 ══")
for name in ("fb_servpub-a.akamaihd.net", "_dmarc.example.com", "a_b.example.com"):
    got = adblock.parse_source(body(1200, [name]))
    (ok if name in got else bad)("接受 %s(实得 %d 条)" % (name, len(got)))

print()
print("══ 2. 只放行下划线, 其余照拒(整份)══")
for label, line in (("通配符", "*.evil.invalid"), ("路径", "evil.invalid/ads"),
                    ("ABP", "||evil.invalid^"), ("正则", "/ads?/"),
                    ("IP 字面量", "1.2.3.4"), ("localhost", "localhost"),
                    ("空格分三段", "a b c")):
    got = adblock.parse_source(body(1200, [line]))
    (ok if not got else bad)("%s(%s)仍然整份拒(实得 %d 条)" % (label, line, len(got)))

print()
print("══ 3. 少量坏行: 跳过并计数, 不废掉整张表 ══")
mixed = body(2000, ["bad..double.dot", "-leading-hyphen.invalid", "trailing-.invalid"])
names, skipped, why = adblock.parse_source_ex(mixed)
(ok if len(names) == 2000 else bad)("合法行全部保留(实得 %d, 应 2000)" % len(names))
(ok if skipped == 3 else bad)("坏行被跳过且计数正确(实得 %d, 应 3)" % skipped)
(ok if not why else bad)("没有整份拒的理由(实得 %r)" % why)
(ok if len(adblock.parse_source(mixed)) == 2000 else bad)("parse_source 薄封装仍返回合法行")

print()
print("══ 4. 坏行比例超阈值 → 整份拒(fail-closed)══")
n_good = 1000
n_bad = int(n_good * ((adblock.LIMITS["max_skip_ratio"] or 0.01) * 4)) + 50
heavy = body(n_good, ["bad..%d" % i for i in range(n_bad)])
names, skipped, why = adblock.parse_source_ex(heavy)
(ok if not names else bad)("坏行过多时整份拒(实得 %d 条)" % len(names))
(ok if skipped >= 0 else bad)("skipped 是真实计数, 不是兜底(实得 %r)" % skipped)
(ok if why and "尚不存在" not in why else bad)("给出了整份拒的理由(实得 %r)" % why)
(ok if not adblock.parse_source(heavy) else bad)("parse_source 薄封装同样返回空")

print()
print("══ 5. 阈值本身要在 LIMITS 里具名 ══")
r = adblock.LIMITS.get("max_skip_ratio")
(ok if r is not None else bad)("LIMITS 里有 max_skip_ratio(实得 %r)" % r)
(ok if isinstance(r, float) and 0 < r <= 0.05 else bad)(
    "阈值取值在合理区间(实得 %r)" % r)

print()
print("══ 6. 条数上限按 512M 实测重定为 500000 ══")
(ok if adblock.LIMITS["max_entries"] == 500000 else bad)(
    "max_entries = 500000(实得 %s)" % adblock.LIMITS["max_entries"])
src = (ROOT / "deploy/bot/adblock.py").read_text(encoding="utf-8")
seg = src.split('"max_entries"')[0][-1200:]
(ok if "512M" in seg else bad)("注释引用了 512M 整机实测")
(ok if "108.6" in seg or "166.7" in seg else bad)("注释里有这次实测的具体 RSS 数字, 不是空口")
(ok if '"max_entries": 150000' not in src else bad)("旧值 150000 已不再是上限")

print()
print("══ 7. 真实上游那一行(线上实测到的那个)必须能过 ══")
real = body(1200, ["fb_servpub-a.akamaihd.net"])
got = adblock.parse_source(real)
(ok if len(got) == 1201 else bad)("21.5 万条那张表不再因一行下划线全废(实得 %d)" % len(got))

print("-" * 62)
print("test-adblock-upstream-tolerance.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

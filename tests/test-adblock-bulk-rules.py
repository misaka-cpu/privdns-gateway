#!/usr/bin/env python3
"""一次加多个阻断规则必须是**一笔事务**。

Telegram 里一次只能加一个域名。想加十个就得点十次按钮、发十条消息 —— 而每一次都是
一整套: 抢全局锁 → 改源 → 重编译 → **重启 mosdns**。十条规则 = 十次 DNS 中断, 而且中间
任何一次撞上 `pdg update` 就卡在那儿。

所以批量不能靠"在 Bot 里循环调十次 CLI"。那只是把十次中断从用户手里搬到代码里, 一次都没少。
必须在 CLI 层做成一笔: 一次锁、一次编译、一次重启。

契约上有一条硬约束: **单域名的输出必须一个字节都不变。** 那份闭集 JSON 是 Bot 的可信接口,
test-adblock-rule-cli.sh 的 60 格钉着它。批量是新增形态, 不是把旧形态改掉。
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "deploy/bot/adblock.py")
sys.path.insert(0, os.path.join(ROOT, "deploy/bot"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmpguard                                             # noqa: E402
import adblock                                              # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def run_many(domains, path):
    """rule-add-many: 域名走 **stdin**, 一行一个。

    不走 argv 是有理由的: 域名条数由用户决定, argv 有长度上限, 而超限的表现是 E2BIG ——
    一个跟"域名对不对"毫无关系的报错。stdin 没有这个问题。
    """
    r = subprocess.run([sys.executable, MOD, "rule-add-many", path],
                       input="\n".join(domains), capture_output=True, text=True)
    try:
        return r.returncode, json.loads((r.stdout or "").strip().splitlines()[-1])
    except Exception:                                        # noqa: BLE001
        return r.returncode, {}


d = tmpguard.mkdtemp(prefix="pdg-bulk.")
ub = os.path.join(d, "block.txt")

print("══ 1. 一次写入多个, 逐条给结果 ══")
open(ub, "w", encoding="utf-8").write("")
rc, j = run_many(["a.example", "b.example", "c.example"], ub)
(ok if rc == 0 else bad)("rc=0(实得 %d)" % rc)
res = j.get("results") or []
(ok if len(res) == 3 else bad)("逐条都有结果(实得 %d 条)" % len(res))
(ok if all(x.get("change") == "added" for x in res) else
 bad)("三条都是 added(实得 %r)" % [x.get("change") for x in res])
body = open(ub, encoding="utf-8").read()
(ok if all(("domain:%s" % n) in body for n in ("a.example", "b.example", "c.example")) else
 bad)("三条都真的落盘了")

print()
print("══ 2. 混合输入: 好的照收, 坏的逐条点名, 不整批拒 ══")
# 整批拒的话, 用户粘贴 20 个域名、其中一个打错, 就得自己去找是哪一个 —— 那正是他想让机器做的事。
open(ub, "w", encoding="utf-8").write("")
rc2, j2 = run_many(["good1.example", "not a domain", "good2.example", "http://x.example"], ub)
res2 = {x.get("domain"): x for x in (j2.get("results") or [])}
(ok if len(res2) == 4 else bad)("四条输入都有回执(实得 %d)" % len(res2))
(ok if res2.get("good1.example", {}).get("change") == "added"
    and res2.get("good2.example", {}).get("change") == "added" else
 bad)("合法的两条照常加进去了")
_badones = [k for k, v in res2.items() if v.get("error")]
(ok if len(_badones) == 2 else bad)("两条非法各自带 error(实得 %r)" % _badones)
(ok if all(v.get("error") == "INVALID_DOMAIN" for k, v in res2.items() if v.get("error")) else
 bad)("非法的错误码是 INVALID_DOMAIN")
body2 = open(ub, encoding="utf-8").read()
(ok if "not a domain" not in body2 and "http" not in body2 else
 bad)("非法输入一个字节都没进文件")

print()
print("══ 3. 重复与幂等 ══")
open(ub, "w", encoding="utf-8").write("")
run_many(["dup.example"], ub)
rc3, j3 = run_many(["dup.example", "dup.example", "new.example"], ub)
r3 = j3.get("results") or []
(ok if [x.get("change") for x in r3] == ["none", "none", "added"] else
 bad)("重复的报 none, 新的报 added(实得 %r)" % [x.get("change") for x in r3])
(ok if open(ub, encoding="utf-8").read().count("domain:dup.example") == 1 else
 bad)("重复域名在文件里只有一条")

print()
print("══ 4. 到上限时: 收到能收的, 之后逐条说满了 ══")
# 不是"整批拒" —— 那会让已经能加进去的那几条也白丢; 也不是"静默截断" —— 用户得知道谁没进去。
open(ub, "w", encoding="utf-8").write(
    "".join("domain:x%d.example\n" % i
            for i in range(adblock.LIMITS["max_user_entries"] - 2)))
rc4, j4 = run_many(["f1.example", "f2.example", "f3.example", "f4.example"], ub)
r4 = j4.get("results") or []
_added = [x for x in r4 if x.get("change") == "added"]
_full = [x for x in r4 if x.get("error") == "BLOCKLIST_FULL"]
(ok if len(_added) == 2 else bad)("能收的两条收下了(实得 %d)" % len(_added))
(ok if len(_full) == 2 else bad)("剩下两条报 BLOCKLIST_FULL(实得 %d)" % len(_full))
(ok if rc4 != 0 else bad)("有条目没进去时退出码非零(实得 %d)" % rc4)

print()
print("══ 5. 空输入不写文件 ══")
open(ub, "w", encoding="utf-8").write("domain:keep.example\n")
_b = open(ub, encoding="utf-8").read()
rc5, j5 = run_many([], ub)
(ok if rc5 != 0 else bad)("空输入退出码非零(实得 %d)" % rc5)
(ok if open(ub, encoding="utf-8").read() == _b else bad)("空输入时文件逐字节未动")

print()
print("══ 6. 条数上限: 一次能贴多少要有个数, 且超了要说 ══")
_cap = adblock.LIMITS.get("max_bulk_domains")
(ok if isinstance(_cap, int) and 0 < _cap <= 1000 else
 bad)("LIMITS 里有 max_bulk_domains 且是个合理的数(实得 %r)" % _cap)
if isinstance(_cap, int) and _cap > 0:
    open(ub, "w", encoding="utf-8").write("")
    rc6, j6 = run_many(["z%d.example" % i for i in range(_cap + 5)], ub)
    (ok if rc6 != 0 else bad)("超过一次上限时整批拒(实得 rc=%d)" % rc6)
    (ok if j6.get("error") == "TOO_MANY" else
     bad)("给的是 TOO_MANY 而不是含混的失败(实得 %r)" % j6.get("error"))
    (ok if open(ub, encoding="utf-8").read() == "" else
     bad)("整批拒时文件逐字节未动")

print()
print("══ 7. 单域名的旧契约一个字节不变 ══")
# 批量是**新增形态**。旧形态是 Bot 的可信接口, test-adblock-rule-cli.sh 的 60 格钉着它。
open(ub, "w", encoding="utf-8").write("")
r7 = subprocess.run([sys.executable, MOD, "rule-add", "single.example", ub],
                    capture_output=True, text=True)
try:
    j7 = json.loads((r7.stdout or "").strip().splitlines()[-1])
except Exception:                                            # noqa: BLE001
    j7 = {}
(ok if set(j7.keys()) == {"change", "normalized"} else
 bad)("单域名输出仍是 {change, normalized} 两个字段(实得 %r)" % sorted(j7.keys()))
(ok if j7.get("change") == "added" and j7.get("normalized") == "single.example" else
 bad)("单域名结果不变(实得 %r)" % j7)

print()
print("══ 8. Bot 侧: 多个域名必须走一笔事务, 不是循环调 N 次 ══")
_botsrc = open(os.path.join(ROOT, "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
(ok if "rule-add-many" in _botsrc else bad)("Bot 会调 rule-add-many")
_seg = _botsrc[_botsrc.index("def _adblock_bulk("):_botsrc.index("def _adblock_bulk_reply(")]
# 要抓的性质是"**对 CLI 只调一次**"。这条**静态查不出来**: 前两版分别按 `for` 和按
# `PDG_CLI` 出现次数判, 都被同一个负控绕过去了 ——
# `[sh([PDG_CLI, "adblock", "rule-add", n]) for n in names]` 里 PDG_CLI 也只出现一次。
# 所以只能真跑: 把 sh 打桩, 数它被调了几次。
_ROOTFS = tmpguard.mkdtemp(prefix="pdg-bulk-bot.")
os.makedirs(os.path.join(_ROOTFS, "etc", "privdns-gateway"), exist_ok=True)
os.makedirs(os.path.join(_ROOTFS, "run"), exist_ok=True)
_PROF = os.path.join(_ROOTFS, "etc", "privdns-gateway", "profile.env")
open(_PROF, "w", encoding="utf-8").write("PDG_INTERNAL_CIDR=127.0.0.0/8\nPDG_SERVER_IP=127.0.0.1\n")
os.environ["PDG_PROFILE_ENV"] = _PROF
os.environ["PDG_TX_FSROOT"] = _ROOTFS
os.environ["PDG_LOCKFILE"] = os.path.join(_ROOTFS, "run", "privdns-gateway.lock")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")

import importlib.util as _u                                  # noqa: E402
_spec = _u.spec_from_file_location("pdg_bot_bulk", os.path.join(ROOT, "deploy/bot/pdg-bot.py"))
_bot = _u.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_bot)
    _loaded = True
except Exception as _e:                                      # noqa: BLE001
    _loaded = False
    bad("载入不了 pdg-bot.py(%s) —— 后面几格不作数" % type(_e).__name__)

if _loaded:
    _CALLS = []

    class _R:
        returncode = 0
        stdout = '{"results":[{"domain":"a.example","change":"added"},'\
                 '{"domain":"b.example","change":"added"}],"changed":2}'
        stderr = ""

    _bot.sh = lambda cmd, input=None: (_CALLS.append((list(cmd), input)) or _R())
    _out = _bot._adblock_bulk(["a.example", "b.example", "c.example"])
    (ok if len(_CALLS) == 1 else
     bad)("三个域名只调一次 CLI(实得 %d 次 = 又回到循环调 N 次)" % len(_CALLS))
    if _CALLS:
        _cmd, _stdin = _CALLS[0]
        (ok if "rule-add-many" in _cmd else bad)("调的是 rule-add-many(实得 %r)" % (_cmd,))
        (ok if _stdin and _stdin.count("\n") == 2 else
         bad)("三个域名经 stdin 一次交过去(实得 %r)" % (_stdin,))
    (ok if _out.get("changed") == 2 else bad)("解析得出 changed(实得 %r)" % _out.get("changed"))

    # 回执: 没进去的必须逐条点名
    _say = _bot._adblock_bulk_reply({"results": [
        {"domain": "ok1.example", "change": "added"},
        {"domain": "dup.example", "change": "none"},
        {"domain": "bad one", "error": "INVALID_DOMAIN"},
        {"domain": "full.example", "error": "BLOCKLIST_FULL"},
    ], "changed": 1})
    (ok if "bad one" in _say and "full.example" in _say else
     bad)("回执里没进去的两条被点名(实得 %r)" % _say[:120])
    (ok if "已添加 1 个" in _say else bad)("回执报了成功条数(实得 %r)" % _say[:120])
    _say2 = _bot._adblock_bulk_reply({"error": "TOO_MANY"})
    (ok if "最多" in _say2 else bad)("超上限的回执说清了上限(实得 %r)" % _say2[:80])
(ok if "input=" in _seg else bad)("域名走 stdin(不走 argv, 免得撞 E2BIG)")
(ok if "_adblock_mod.LIMITS" in _botsrc else
 bad)("Bot 的批量上限从 adblock.py 读, 不是另写一个数")
(ok if "一次可以发多个" in _botsrc else bad)("加规则的提示里说明了可以一次多个")
_seg2 = _botsrc[_botsrc.index("def _adblock_bulk_reply("):_botsrc.index("def _adblock_pending(")]
(ok if "BLOCKLIST_FULL" in _seg2 and "domain" in _seg2 else
 bad)("回执把没进去的逐条点名(只报个成功数等于让用户自己去数)")

# 这一支自己栽过一次: `(ok if C else bad("msg"))` —— C 为真时整个表达式只是求值出 `ok`
# 这个函数对象, **根本没调用**, 于是那几格静默空转、一次都没跑过, 而计分看着还很正常。
# 正确写法是 `(ok if C else bad)("msg")`。这一格扫本文件, 让它不会再溜过去。
import re as _re2                                            # noqa: E402

_lines = open(__file__, encoding="utf-8").read().splitlines()
# 只看**真代码**: 注释行、以及这一格自己的说明文字里都写着这个坏形态当例子, 全文扫会把
# 例子也算成违规 —— 那种红灯除了教人忽略它以外没有别的作用。
# `_noop` / `_probe` 那两行是这一格**自己的**判据与负控探针, 它们必然含有坏形态的样子;
# 不排除的话这一格永远红着自己 —— 而永远红的判据等于没有判据。
_code = "\n".join(l for l in _lines
                  if not l.lstrip().startswith("#") and "_noop" not in l and "_probe" not in l)
_noop = _re2.findall(r"\(ok if [^\n]*else\s*\n?\s*bad\(", _code)
(ok if not _noop else bad)("本文件里没有 `(ok if … else bad(…))` 这种静默空转的写法(实得 %d 处)"
                           % len(_noop))
# 负控: 这一格自己得能红。构造一段带坏形态的代码文本, 走同一条判据。
_probe = 'x = (ok if 1 == 1 else bad("会静默空转"))'
(ok if _re2.findall(r"\(ok if [^\n]*else\s*\n?\s*bad\(", _probe) else
 bad)("负控: 这条判据确实认得出坏形态(不是一句空话)")

print("-" * 62)
print("test-adblock-bulk-rules.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

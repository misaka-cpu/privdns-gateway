#!/usr/bin/env python3
"""用户自己的 block 文件必须有体积上限。

第三方表有两道硬顶(8 MiB 体积、50 万条), 因为那两个数字是按"整机 512 MiB 可用"实测定出来
的 —— mosdns 把 domain_set 全量装进内存, 超了就是 OOM, 而 OOM 的表现是**整台机器的 DNS 没了**。

用户 block 一道都没有。而 `compile_effective` 把它**逐字节**拷进 mosdns 要加载的
effective_block.txt —— 也就是说那个内存预算可以从这条路完整绕过去。

不是假想: 规则是可以脚本化追加的(`pdg adblock rule-add` 就是给 Bot 用的), 一个循环写岔了、
或者有人把一份下载来的表直接 `cat >>` 进去, 就到了。触发之后不会有任何提示, 只会在下一次
`pdg adblock enable` 或 mosdns 重启时把 DNS 打没。

上限取 50000 条 / 2 MiB, 依据是同一次 512 MiB 实测: 15 万条 61.6 MiB → 50 万条 108.6 MiB,
边际约 0.134 KiB/条, 50000 条 ≈ 6.7 MiB —— 相对那次测出来的 186 MiB 余量不到 4%, 而手工
维护的名单从来到不了这个量级(到得了的那都不是手工维护的)。

两处都要拦, 缺一不可:
  · rule-add 时拦 —— 让用户在**加的那一刻**撞墙, 而不是几天后 enable 时才发现;
  · compile 时拦 —— rule-add 不是唯一入口(文件是用户数据, 可以直接编辑), 这里才是真正的门。
"""
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy/bot"))
import adblock                                              # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


print("══ 1. 上限本身要具名, 且能解释 ══")
for key in ("max_user_entries", "max_user_bytes"):
    v = adblock.LIMITS.get(key)
    (ok if isinstance(v, int) and v > 0 else bad)("LIMITS 里有 %s(实得 %r)" % (key, v))
src = open(os.path.join(ROOT, "deploy/bot/adblock.py"), encoding="utf-8").read()
seg = src[src.index("LIMITS = {"):src.index("}", src.index("LIMITS = {"))]
(ok if "512" in seg else bad)("注释把上限挂回 512 MiB 那次实测, 不是拍脑袋")

print()
print("══ 2. compile: 超限整笔拒, 且**不动**现网产物 ══")
d = tempfile.mkdtemp()
eff = os.path.join(d, "effective_block.txt")
open(eff, "w", encoding="utf-8").write("domain:old.example\n")
before = open(eff, encoding="utf-8").read()
ub = os.path.join(d, "user_block.txt")
n = adblock.LIMITS["max_user_entries"] + 10
open(ub, "w", encoding="utf-8").write("".join("domain:x%d.example\n" % i for i in range(n)))
try:
    r = adblock.compile_effective(1, state_dir=d, user_block=ub, lkg=os.path.join(d, "nope"))
except Exception as e:                                      # noqa: BLE001
    r = "raised:%s" % type(e).__name__
(ok if r is not True else bad)("超条数上限时 compile 不返回成功(实得 %r)" % (r,))
(ok if open(eff, encoding="utf-8").read() == before else
 bad)("被拒时现网的 effective_block.txt 逐字节未动")

print()
print("══ 3. compile: 体积上限同样拦得住 ══")
d2 = tempfile.mkdtemp()
ub2 = os.path.join(d2, "user_block.txt")
# 条数远低于上限, 但单行极长 → 只有体积这道能拦住
big = "domain:" + ("a" * 200) + ".example\n"
cnt = adblock.LIMITS["max_user_bytes"] // len(big) + 10
open(ub2, "w", encoding="utf-8").write(big * cnt)
lines = cnt
(ok if lines < adblock.LIMITS["max_user_entries"] else
 bad)("这份夹具的条数(%d)确实低于条数上限 —— 否则测的是另一道门" % lines)
r2 = adblock.compile_effective(1, state_dir=d2, user_block=ub2, lkg=os.path.join(d2, "nope"))
(ok if r2 is not True else bad)("超体积上限时 compile 不返回成功(实得 %r)" % (r2,))

print()
print("══ 4. 正常大小照常编译 ══")
d3 = tempfile.mkdtemp()
ub3 = os.path.join(d3, "user_block.txt")
open(ub3, "w", encoding="utf-8").write("domain:a.example\ndomain:b.example\n")
open(os.path.join(d3, "list.lkg"), "w", encoding="utf-8").write("c.example\n")
r3 = adblock.compile_effective(1, state_dir=d3, user_block=ub3,
                               lkg=os.path.join(d3, "list.lkg"))
(ok if r3 is True else bad)("正常大小仍然编译成功(实得 %r)" % (r3,))
got = open(os.path.join(d3, "effective_block.txt"), encoding="utf-8").read()
(ok if "a.example" in got and "b.example" in got else bad)("用户规则逐条进了编译产物")

print()
print("══ 5. 关闭态不受上限影响(产物为空, 用户源一个字节不动)══")
d4 = tempfile.mkdtemp()
ub4 = os.path.join(d4, "user_block.txt")
huge = "".join("domain:x%d.example\n" % i
               for i in range(adblock.LIMITS["max_user_entries"] + 10))
open(ub4, "w", encoding="utf-8").write(huge)
r4 = adblock.compile_effective(0, state_dir=d4, user_block=ub4,
                               lkg=os.path.join(d4, "nope"))
(ok if r4 is True else bad)("关闭态编译不因用户文件超限而失败(实得 %r)" % (r4,))
(ok if open(os.path.join(d4, "effective_block.txt"), encoding="utf-8").read() == "" else
 bad)("关闭态产物为空")
(ok if open(ub4, encoding="utf-8").read() == huge else
 bad)("用户源文件一个字节没被改(关闭不是靠清空用户规则实现的)")

print()
print("══ 6. rule-add: 到顶时当场拒, 且不写坏文件 ══")
d5 = tempfile.mkdtemp()
ub5 = os.path.join(d5, "user_block.txt")
full = "".join("domain:x%d.example\n" % i for i in range(adblock.LIMITS["max_user_entries"]))
open(ub5, "w", encoding="utf-8").write(full)
# rule_add 返回 (change, normalized), 超限时抛 ValueError —— 两种都算"没加进去",
# 但**必须说清是哪一种**: 静默返回 none 会让 Bot 以为"已存在", 那是另一回事。
try:
    res = adblock.rule_add("newone.example", ub5)
    change, why = res[0], ""
except ValueError as e:
    change, why = "refused", str(e)
(ok if change == "refused" else
 bad)("到顶之后 rule-add 明确拒绝(实得 change=%r)" % (change,))
(ok if "上限" in why else bad)("拒绝理由说明了是撞了上限(实得 %r)" % why[:60])
(ok if open(ub5, encoding="utf-8").read() == full else
 bad)("被拒时用户文件逐字节未动")

print()
print("══ 7. 到顶时删规则仍然可用(否则用户被锁死)══")
# 拦住"加"却连"删"也拦住的话, 用户就没有任何办法把文件降下来了 —— 那是把人锁在门外。
res7 = adblock.rule_del("x0.example", ub5)
(ok if res7[0] == "removed" else bad)("到顶时仍然删得掉(实得 %r)" % (res7[0],))

print()
print("══ 8. 到顶不等于「域名不合法」—— 闭集里必须是两件不同的事 ══")
# rule-add 是 Telegram Bot 的可信入口, 吐的是闭集 JSON, Bot 认字段不认措辞。超限抛的是
# ValueError, 而 __main__ 把 ValueError 一律报成 INVALID_DOMAIN —— 于是 Bot 会对一个
# **完全合法**的域名说"这个域名不合法"。用户照着这句去改域名, 改多少次都没用。
import json as _json                                        # noqa: E402
import subprocess as _sp                                     # noqa: E402

_mod = os.path.join(ROOT, "deploy/bot/adblock.py")
# **不能复用 ub5** —— §7 从它里面删掉了一条, 现在是 49999, 再加一条正好压线不超。
# (第一版就是这么写的, 于是这一格拿到 rc=0 而红得莫名其妙。)前一格改过的夹具不能当后一格
# 的前提, 每格自备。
_d8 = tempfile.mkdtemp()
_ub8 = os.path.join(_d8, "b.txt")
open(_ub8, "w", encoding="utf-8").write(full)
_r = _sp.run([sys.executable, _mod, "rule-add", "newone.example", _ub8],
             capture_output=True, text=True)
try:
    _j = _json.loads((_r.stdout or "{}").strip().splitlines()[-1])
except Exception:                                            # noqa: BLE001
    _j = {}
(ok if _j.get("error") and _j.get("error") != "INVALID_DOMAIN" else
 bad)("超限有自己的 error 码, 不冒充 INVALID_DOMAIN(实得 %r)" % (_j.get("error"),))
(ok if _r.returncode not in (0, 2) else
 bad)("超限的退出码与「域名不合法」(2)区分得开(实得 %d)" % _r.returncode)

# 合法域名 + 未满的文件 → 照常加得进去(证明上面那条不是把所有 rule-add 都拦了)
_d9 = tempfile.mkdtemp()
_ub9 = os.path.join(_d9, "b.txt")
open(_ub9, "w", encoding="utf-8").write("")
_r9 = _sp.run([sys.executable, _mod, "rule-add", "fine.example", _ub9],
              capture_output=True, text=True)
(ok if _r9.returncode == 0 else bad)("未满时 rule-add 照常成功(rc=%d)" % _r9.returncode)

print()
print("══ 9. 新的闭集成员必须一路认得 ══")
# 闭集是三处手写: pdg.sh 的注释、pdg.sh 真正 emit 的值、Bot 的文案表。少一处, Bot 拿到一个
# 它不认识的 result —— 那时它要么显示原始英文码, 要么什么都不说, 两种都是把内部状态漏给用户。
_pdgsh = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
_bot = open(os.path.join(ROOT, "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
(ok if "_adb_emit blocklist_full" in _pdgsh else bad)("pdg.sh 真的会 emit blocklist_full")
(ok if "blocklist_full" in _pdgsh[_pdgsh.index("result ∈"):_pdgsh.index("result ∈") + 300] else
 bad)("pdg.sh 的闭集注释里列了 blocklist_full")
(ok if '"blocklist_full"' in _bot else bad)("Bot 的文案表里有 blocklist_full")
# 反面: Bot 那张表里每一个 result, pdg.sh 都得真的会 emit(反向漂移同样是错)
import re as _re                                             # noqa: E402
_say = _re.search(r"ADBLOCK_SAY = \{(.*?)\n\}", _bot, _re.S).group(1)
_keys = _re.findall(r'^\s*"([a-zA-Z_]+)":', _say, _re.M)
_orphan = [k for k in _keys if k not in ("added", "removed") and
           ("_adb_emit %s" % k) not in _pdgsh and ('"%s"' % k) not in _pdgsh]
(ok if not _orphan else bad)("Bot 文案表里没有 pdg.sh 不会产生的孤儿码(实得 %r)" % _orphan)

print("-" * 62)
print("test-user-block-ceiling.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

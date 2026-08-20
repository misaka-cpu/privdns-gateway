#!/usr/bin/env python3
"""事务 id 必须**按名字排序就等于按时间排序**。

为什么这条值得一支测试: 目录名是运维和测试查"最新那笔事务"的唯一入口。原来的
`%Y%m%dT%H%M%SZ-<uuid4 前 8 位>` 时间戳只到秒, 同秒的两笔完全靠随机后缀区分 ——
`sort | tail -1` 选中谁纯看运气。e2e-hijack-mode-tx.sh 因此间歇性红了一个多星期
(约 6%, 最早可追到 2026-08-02): 断言读到的是上一小节留下的 ABORTED, 而本次那笔
其实是 ROLLBACK_FAILED。表面上像产品有随机故障, 实际是判据在掷硬币。

调用方改用差集是治本(见 e2e-lib.sh 的 e2e_dirset_*), 但目录名本身可排序也得成立 ——
否则下一个写查询的人还会踩同一个坑, 而且照样是低频随机红, 最难查的那一类。

反向对照直接把旧格式的生成函数写在这里跑: 它必须在同一组样本上失败。
"""
import os
import re
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
import pdgtx                                                     # noqa: E402

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def old_txid():
    """修复前那一版, 逐字照抄 —— 作为反向对照。"""
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8]


def gen(fn, n=25, gap=0.004):
    """连续生成 n 个 id, 每个之间隔一点点 —— 模拟"同一秒内接连开了几笔事务"。"""
    out = []
    for _ in range(n):
        out.append(fn())
        time.sleep(gap)
    return out


# ── 一、形态 ─────────────────────────────────────────────────────────────────
tid = pdgtx.new_txid()
if re.match(r"^\d{8}T\d{6}\.\d{3}Z-[0-9a-f]{8}$", tid):
    ok("形态是 <UTC 时间>.mmmZ-<uuid4 前 8 位>, 例: " + tid[:23] + "…")
else:
    bad("形态不对: %r" % tid)

# ── 二、字符集必须过救援平面的校验 ───────────────────────────────────────────
# rescue.py 用 _TXID_RE 校验 txid 才肯受理。换个分隔符(比如 ISO 里常见的 `:`)会让救援
# 平面直接拒收本项目自己生成的事务 —— 而那要等到真出事、真去用救援时才会发现。
try:
    import rescue                                                # noqa: E402
    rx = rescue._TXID_RE
except Exception as e:                                           # noqa: BLE001
    rx = None
    print("[SKIP] 读不到 rescue._TXID_RE(%s) —— 字符集这一格没验" % type(e).__name__)
if rx is not None:
    ids = [pdgtx.new_txid() for _ in range(20)]
    if all(rx.match(i) for i in ids):
        ok("20 个样本全部通过 rescue._TXID_RE(救援平面会受理)")
    else:
        bad("有 id 过不了 rescue._TXID_RE: %r" % [i for i in ids if not rx.match(i)][:2])

# ── 三、核心性质: 按名字排序 == 按生成顺序 ───────────────────────────────────
new_ids = gen(pdgtx.new_txid)
if new_ids == sorted(new_ids):
    ok("新格式: %d 个同秒样本, 字典序与生成顺序完全一致" % len(new_ids))
else:
    firstbad = next(i for i, (a, b) in enumerate(zip(new_ids, sorted(new_ids))) if a != b)
    bad("新格式排序仍然错位, 第 %d 个就对不上" % firstbad)

# ── 四、反向对照: 旧格式在同一组样本上必须失败 ───────────────────────────────
# 少了这一格, 只要机器快到每个 id 都落在不同秒, 上面那条也会绿 —— 那就什么都没测到。
old_ids = gen(old_txid)
same_second = len({i.split("-")[0] for i in old_ids}) < len(old_ids)
if not same_second:
    bad("反向对照没构造成: %d 个样本竟然分属不同秒, 换更小的 gap 再试" % len(old_ids))
elif old_ids == sorted(old_ids):
    bad("反向对照失效: 旧格式这次碰巧也有序 —— 这支测试对本次样本没有判别力")
else:
    ok("反向对照: 旧格式在同一组样本上排序错位(随机后缀决定顺序)")

# ── 五、唯一性仍由随机后缀兜底 ───────────────────────────────────────────────
# 毫秒只负责排序, 不负责唯一 —— 同一毫秒内并发开两笔仍然可能。
burst = [pdgtx.new_txid() for _ in range(500)]
if len(set(burst)) == len(burst):
    ok("500 个连续生成的 id 无重复(毫秒撞了也有随机后缀兜底)")
else:
    bad("出现重复 id: %d/%d 唯一" % (len(set(burst)), len(burst)))

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

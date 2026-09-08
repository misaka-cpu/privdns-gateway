#!/usr/bin/env python3
"""artifact 负控自身的**收口契约**: 消费者数量现推、零命中不放行、拓扑不一致不合理化、
子测试没跑起来不算绿。

为什么要有这一支: tests/negctl/mosdns-artifact-negative-controls.py 是**本地手动门**,
CI 不跑它。它一旦悄悄退化(数量写死、零命中当成"改 0 处"、执行链坏了却提取不到 [FAIL]),
没有任何信号 —— PR #56 那次三格同时哑火整整一个版本没人知道(HANDOFF §9.18)。
这一支只验那几条判定**本身有没有牙**, 用合成输入直接喂纯函数:

  · 不递归跑整支负控(那要十几秒、还要真夹具), 只测判定逻辑;
  · 不联网、不取件、不需要 mosdns 制品;
  · 负控模块有 `if __name__ == "__main__"` 守卫, import 只做只读解析, 无副作用。
"""
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEG = os.path.join(ROOT, "tests/negctl/mosdns-artifact-negative-controls.py")

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


spec = importlib.util.spec_from_file_location("artifact_negctl", NEG)
N = importlib.util.module_from_spec(spec)
spec.loader.exec_module(N)

SRC = open(NEG, encoding="utf-8").read()
# 取件落点从负控的锚点常量里取, 不在本文件里再写一遍固定路径。
ART_PATH = N.CONSUMER_DL.rstrip("\n").rsplit("path: ", 1)[1].strip()


def ci(consumers, needs=None, dl=None):
    """合成一份最小 workflow: consumers 个消费者, 可单独控制谁有 needs / 谁有取件块。"""
    needs = consumers if needs is None else needs
    dl = consumers if dl is None else dl
    out = ["on: [push]", "jobs:", "  prepare-mosdns-fixture:", "    runs-on: ubuntu-latest",
           "    steps:", "      - run: bash tests/prepare-mosdns.sh"]
    for j in consumers:
        out.append("  %s:" % j)
        if j in needs:
            out.append("    needs: prepare-mosdns-fixture")
        out.append("    runs-on: ubuntu-latest")
        out.append("    steps:")
        if j in dl:
            # 直接拼负控自己的锚点常量: 既不与它重复维护一份字面量, 也不会在这里出现
            # 写死的临时路径(那是 workflow 里的固定文本, 不是本测试要用的目录)。
            out += N.CONSUMER_DL.rstrip("\n").split("\n")
        out.append("      - run: bash tests/install-mosdns-artifact.sh " + ART_PATH)
    return "\n".join(out) + "\n"


print("══ 1. 消费者个数现推(不写死) ══")
for names in (["a"], ["a", "b", "c"], ["a", "b", "c", "d", "e", "f", "g", "h", "i"]):
    got = N.derive_consumers(ci(names))
    (ok if got == sorted(names) else
     bad)("%d 个消费者 → 现推得到 %d 个 %s" % (len(names), len(got), got))
(ok if N.derive_consumers(ci([])) == [] else bad)("0 个消费者 → 现推得到空集")

print()
print("══ 2. 增/删消费者后仍可测(数量随拓扑走) ══")
for names in (["a", "b", "c"], ["a", "b", "c", "d"]):
    t = ci(names)
    c = N.anchor_counts(t)
    n = len(N.derive_consumers(t))
    same = set(c.values()) == {n}
    (ok if same else bad)("%d 个消费者 → 三个锚点处数均为 %d(实得 %s)" % (n, n, c))
    try:
        N.preflight_verdict(N.derive_consumers(t), c, N.consumer_gaps(t))
        ok("  合法拓扑(%d 个)放行" % n)
    except N.Halt as e:
        bad("  合法拓扑(%d 个)被误拦: %s" % (n, str(e)[:90]))

print()
print("══ 3. 零命中必须拦住, 不能当成「改 0 处」 ══")
try:
    N.preflight_verdict([], {"消费者取件块": 0, "download-artifact 引用行": 0, "needs: 生产者": 0}, {})
    bad("消费者数 0 被放行 —— 零命中冒充通过")
except N.Halt as e:
    (ok if "P1" in str(e) else bad)("消费者数 0 → 具名拦下: %s" % str(e)[:80])
try:
    N.preflight_verdict(["a", "b"], {"消费者取件块": 0, "download-artifact 引用行": 2, "needs: 生产者": 2}, {})
    bad("某个锚点 0 命中被放行 —— 锚点失效冒充通过")
except N.Halt as e:
    (ok if "P2" in str(e) and "取件块=0" in str(e) else
     bad)("锚点 0 命中 → 具名拦下: %s" % str(e)[:110])

print()
print("══ 4. 拓扑不一致不得被「动态计数」合理化 ══")
t = ci(["a", "b", "c"], needs=["a", "b"])          # c 有取件块却没 needs
gaps = N.consumer_gaps(t)
(ok if "c" in gaps and any("needs" in m for m in gaps["c"]) else
 bad)("逐 job 诊断点名缺 needs 的消费者(实得 %r)" % gaps)
try:
    N.preflight_verdict(N.derive_consumers(t), N.anchor_counts(t), gaps)
    bad("拓扑不一致被放行 —— 数量相等就当关系正确")
except N.Halt as e:
    (ok if "P2" in str(e) and "c:" in str(e) else
     bad)("拓扑不一致 → 具名拦下并点名 job: %s" % str(e)[:130])

print()
print("══ 5. 子测试没跑起来 ≠ 全绿 ══")
CASES = [
    ("崩溃(Traceback)", 1, "Traceback (most recent call last):\n  File x\nRuntimeError: boom"),
    ("导入失败", 1, "ModuleNotFoundError: No module named 'yaml'"),
    ("零断言", 0, "什么都没打印\n"),
    ("命令不存在", 127, "bash: line 1: nope: command not found"),
    ("非零退出但无具名失败", 3, "[OK]   一条断言\n"),
    ("正常", 0, "[OK]   一条\n[OK]   两条\n"),
    ("正常", 1, "[OK]   一条\n[FAIL] 真的红了\n"),
]
for want, rc, out in CASES:
    got = N.classify_run(rc, out)[0]
    (ok if got == want else bad)("rc=%s 的输出归类为「%s」(期望「%s」)" % (rc, got, want))
broken = N.chain_broken([("t", "崩溃(Traceback)", 0, 0, 1)])
(ok if broken else bad)("chain_broken 认出执行链异常: %s" % broken)
(ok if not N.chain_broken([("t", "正常", 5, 0, 0)]) else bad)("正常执行不被误报为异常")

print()
print("══ 6. 静态: 三格的处数不得回退成写死字面量 ══")
pinned = re.findall(r"^\s+\[\(.*?,\s*(\d+)\)\],\s*\[T_TOPO\]\),?$", SRC, re.M)
dyn = SRC.count("N_CONSUMER)]")
(ok if dyn == 3 else bad)("①⑤⑨ 三格都用现推的 N_CONSUMER(实得 %d 处)" % dyn)
(ok if "left != expect_left" in SRC else bad)("替换范围有独立核对(命中/替换/自含 三者对账)")
(ok if "chain_broken" in SRC and "raise Halt" in SRC else
 bad)("基线执行链异常会中止, 而不是继续算「新增」")

print()
print("-" * 62)
print("test-negctl-artifact-closure.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

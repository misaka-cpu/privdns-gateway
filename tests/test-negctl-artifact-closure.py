#!/usr/bin/env python3
"""artifact 负控自身的**收口契约**: 消费者数量现推、零命中不放行、拓扑不一致不合理化、
子测试没跑起来不算绿。

为什么要有这一支: tests/negctl/mosdns-artifact-negative-controls.py 是**本地手动门**,
CI 不跑它。它一旦悄悄退化(数量写死、零命中当成"改 0 处"、执行链坏了却提取不到 [FAIL]),
没有任何信号 —— PR #56 那次三格同时哑火整整一个版本没人知道(HANDOFF §9.18)。
这一支只验那几条判定**本身有没有牙**, 分三层, 一层比一层贴近真实调用:

  1-6 节 纯函数: 合成 workflow / 合成输出直接喂 derive_consumers / preflight_verdict /
         classify_run, 外加三条静态护栏(不得回退成写死字面量等);
  7 节   **实际调用链**: 起真子进程跑本轮自造的 stub, 走 run_suite / suite → chain_broken,
         证明判读规则确实落在链路上, 而不是只对字符串成立;
  8 节   **最终裁决**: 端到端跑一次负控 main(), 但把它调用的两支子测试换成自造 stub
         (ci.yml 与安装脚本原样保留, 锚点与消费者拓扑都是真的), 对"基线异常必停 /
         变异期异常不算有牙 / 反向对照期异常不算通过"做行为断言。

所有输出都由本轮自造的 stub 产生: 不联网、不取件、不需要 mosdns 制品、不执行任何被变异
出来的下载命令, 也不碰宿主服务或生产资源。负控模块有 `if __name__ == "__main__"` 守卫,
import 只做只读解析, 无副作用。
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

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
# 两支子测试的约定: 断言打在行首, 退出码只有 0(无失败) / 1(有失败)。
# 判读必须与 failures() 用同一条行级规则 —— 文案里引用的标记不算断言。
CASES = [
    ("崩溃(Traceback)", 1, "Traceback (most recent call last):\n  File x\nRuntimeError: boom"),
    ("导入失败", 1, "ModuleNotFoundError: No module named 'yaml'"),
    ("零有效断言", 0, "什么都没打印\n"),
    ("命令不存在(rc=127)", 127, "bash: line 1: nope: command not found"),
    # 文案里引用标记, 不是断言行 —— 以前用全文 count 时这两条都被判「正常」
    ("退出码超出约定(rc=3, 约定只有 0/1)", 3,
     "[OK]   某判据通过, 提示: 失败时会打印 [FAIL] 开头的行\n"),
    ("零有效断言", 0, "说明: 通过时会打印 [OK] 开头的行\n"),
    # 已经打印过一条真失败, 也不能把异常退出当成正常的断言失败
    ("退出码超出约定(rc=3, 约定只有 0/1)", 3, "[OK]   一条\n[FAIL] 真的红了\n"),
    ("被信号终止(rc=-9)", -9, "[OK]   一条\n[FAIL] 真的红了\n"),
    ("退出码与失败数矛盾(rc=0 却有 1 条具名失败)", 0, "[FAIL] 红了却退 0\n"),
    ("退出码与失败数矛盾(rc=1 却没有具名失败)", 1, "[OK]   一条\n"),
    # 正向对照: 非零退出不能一律判异常
    ("正常", 0, "[OK]   一条\n[OK]   两条\n"),
    ("正常", 1, "[OK]   一条\n[FAIL] 真的红了\n"),
]
for want, rc, out in CASES:
    got = N.classify_run(rc, out)[0]
    (ok if got == want else bad)("rc=%s 归类为「%s」(期望「%s」)" % (rc, got, want))

n_ok, n_fail = N.assert_counts("[OK]   真断言\n提示: 出错会打印 [FAIL] 与 [OK] 字样\n")
(ok if (n_ok, n_fail) == (1, 0) else
 bad)("断言只按行首计数, 文案里的引用不算(实得 [OK]=%d [FAIL]=%d, 期望 1/0)" % (n_ok, n_fail))
(ok if len(N.failures("[FAIL] 真失败\n[OK]   提到 [FAIL] 三个字\n")) == 1 else
 bad)("failures() 与 assert_counts 用同一条行级规则")
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
print("══ 7. 实际调用链: run_suite / suite → chain_broken(自造子测试, 真起子进程) ══")
# 输出全部由本轮自造的 stub 产生 —— 不跑真实夹具、不联网、不碰宿主服务, 也不执行任何
# 被变异出来的下载命令。这一节验的是"判读规则确实走到了调用链上", 不是只喂字符串。
import tmpguard                                        # noqa: E402

WD = tmpguard.mkdtemp(prefix="pdg-negctl-closure.")
try:
    def stub(name, rc, body):
        f = Path(WD) / name
        f.write_text("#!/bin/sh\n%s\nexit %d\n" % (body, rc), encoding="utf-8")
        f.chmod(0o755)
        return ["sh", name]

    CHAIN = [
        ("引用标记 + 异常退出", stub("s1.sh", 3,
            'echo "[OK]   一条真断言"\necho "提示: 失败时会打印 [FAIL] 开头的行"'), False),
        ("只有说明文字里的标记", stub("s2.sh", 0, 'echo "说明: 通过会打印 [OK] 开头的行"'), False),
        ("有真失败但异常退出", stub("s3.sh", 3, 'echo "[OK]   一条"\necho "[FAIL] 真的红了"'), False),
        ("正常成功", stub("s4.sh", 0, 'echo "[OK]   一条"\necho "[OK]   两条"'), True),
        ("按约定以 1 返回且有具名失败", stub("s5.sh", 1,
            'echo "[OK]   一条"\necho "[FAIL] 具名失败"'), True),
    ]
    for label, cmd, want_ok in CHAIN:
        f, kind, n_ok, n_fail, rc = N.run_suite(WD, cmd)
        broken = N.chain_broken([(cmd[-1], kind, n_ok, n_fail, rc)])
        good = (not broken) if want_ok else bool(broken)
        (ok if good else bad)(
            "run_suite→chain_broken: %-22s rc=%s 断言%d/%d → 「%s」%s"
            % (label, rc, n_ok, n_fail, kind, "放行" if not broken else "判执行异常"))

    # suite() 合并两支时, 一支异常不能被另一支的正常结果遮住
    got, kinds = N.suite(WD, [CHAIN[3][1], CHAIN[0][1]])
    (ok if N.chain_broken(kinds) else
     bad)("一支正常 + 一支异常 → 仍判执行异常(不被正常结果遮住)")
    (ok if len(N.suite(WD, [CHAIN[4][1]])[0]) == 1 else
     bad)("按约定失败的子测试, 其具名失败进入比较集合(1 条)")
finally:
    shutil.rmtree(WD, ignore_errors=True)

print()
print("══ 8. 最终裁决: 基线异常必停 / 变异异常不算有牙 / 反向对照异常不算通过 ══")
# 端到端跑一次负控 main(), 但把它调用的两支子测试换成本轮自造的 stub:
# 副本里的 ci.yml / 安装脚本原样保留(锚点、消费者拓扑都真), 只有"子测试"是我们控制的。
def e2e(tag, topo_body, want):
    wd = tmpguard.mkdtemp(prefix="pdg-negctl-e2e.")
    try:
        for sub in ("tests", "lib", "deploy"):
            shutil.copytree(os.path.join(ROOT, sub), os.path.join(wd, sub), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__", ".bin"))
        os.makedirs(os.path.join(wd, ".github/workflows"), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, ".github/workflows/ci.yml"),
                     os.path.join(wd, ".github/workflows/ci.yml"))
        Path(wd, "tests/test-ci-mosdns-topology.py").write_text(topo_body, encoding="utf-8")
        Path(wd, "tests/test-mosdns-artifact-roundtrip.sh").write_text(
            '#!/bin/sh\necho "[OK]   桩: roundtrip 正常"\nexit 0\n', encoding="utf-8")
        r = subprocess.run([sys.executable, "tests/negctl/mosdns-artifact-negative-controls.py"],
                           cwd=wd, capture_output=True, text=True, timeout=900, errors="replace")
        out = r.stdout + r.stderr
        hit = want in out
        (ok if hit else bad)("%s → 裁决文案含「%s」(rc=%s)%s"
                             % (tag, want, r.returncode,
                                "" if hit else "; 实得尾部: " + out.strip().splitlines()[-1][:90]))
        return out
    finally:
        shutil.rmtree(wd, ignore_errors=True)


# (a) 基线就异常(引用标记 + rc=3): 必须停在改坏之前, 且不得声称基线全绿
o = e2e("基线异常", 'print("[OK]   一条真断言")\nprint("提示: 失败会打印 [FAIL] 开头的行")\n'
        'import sys; sys.exit(3)\n', "基线 topo 的子测试没有正常运行")
(ok if "基线 topo 全绿" not in o else bad)("基线异常时不再打印「基线 topo 全绿」")
(ok if "已在改坏之前停下" in o else bad)("基线异常时停在任何一格改坏之前")

# (b) 基线正常, 但一进变异就异常退出(且已打印一条真失败): 不得算「有牙」
o = e2e("变异期异常", 'import sys\n'
        'ci = open(".github/workflows/ci.yml", encoding="utf-8").read()\n'
        'if "直接下载" in ci:\n'
        '    print("[OK]   桩: 变异被观察到")\n'
        '    print("[FAIL] 桩: 一条真失败")\n'
        '    sys.exit(3)\n'
        'print("[OK]   桩: 基线正常")\nsys.exit(0)\n',
        "① consumer 恢复直接官方下载: 子测试没有正常运行")
(ok if "① consumer 恢复直接官方下载 → 新增具名失败" not in o else
 bad)("变异期异常退出不被算成「有牙」")

# (c) 反向对照 ⑩ 期间执行链异常: 不得报通过
o = e2e("反向对照期异常", 'import sys\n'
        'ins = open("tests/install-mosdns-artifact.sh", encoding="utf-8").read()\n'
        'if "负控的空转对照" in ins:\n'
        '    print("[OK]   桩: 反向对照被观察到")\n    sys.exit(3)\n'
        'print("[OK]   桩: 基线正常")\nsys.exit(0)\n',
        "⑩ 只加一行无关注释(反向对照): 子测试没有正常运行")
(ok if "反向对照: 无关注释新增失败 0 条" not in o else
 bad)("反向对照期执行链异常不被算成通过")

print()
print("-" * 62)
print("test-negctl-artifact-closure.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

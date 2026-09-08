#!/usr/bin/env python3
"""负控: mosdns 单次取件 + artifact 扇出这套判据有没有牙。

被盯的是三个文件 —— .github/workflows/ci.yml 的 producer/consumer 拓扑、
tests/install-mosdns-artifact.sh 的消费者四层复核、tests/mosdns-artifact-name.sh 的
名字生成。这一支回答: **如果它们退化了, 我们会不会知道?**

做法与本目录其它负控一致: 逐格把代码改坏(只改沙箱副本, 正式树一个字节不动), 再跑两支
聚焦测试, 看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本, 必须全绿。

每格五步, 缺一不算有效: 锚点恰好命中 / YAML 真解析仍过 / 失败集合有具名新增 /
反向对照零新增 / 正式树 sha256 与 mode 逐字节恢复。

三条前置门(在任何一格改坏之前跑, 不过就**停**, 不进变异):

  P1 消费者个数**现推**(真解析 workflow), 不写死。数出来是 0 → 具名失败并停 —— 那正是
     锚点失配的样子。写死过一次: v1.11.10 合并 PR #56 多了 core-startlimit, 三格命中数
     一起从 7 变 8, 改坏器数不对就 abort, **三格同时哑火**, 而 negctl 是本地手动门、CI 不跑,
     三支 CI 照样全绿, 整整一个版本没有信号(HANDOFF §9.18)。
  P2 三个文本锚点的处数必须**都等于消费者个数**, 对不上就点名是哪个消费者缺哪一样 ——
     数量相等不等于关系正确, 逐 job 的 needs/download 对应关系由
     tests/test-ci-mosdns-topology.py 验证(见 P3), 这里只做数量闸门与命名, 不重造解析器。
  P3 基线两支子测试必须**真的跑起来且全绿**: 分类 rc / Traceback / 导入失败 / 命令不存在 /
     零断言。以前 suite() 只提取 `[FAIL]` 文本, 子测试在 import 期崩掉时一条都提不到,
     基线于是打印"全绿" —— 那是假绿, 而后面每一格的「新增」都建立在它上面。

十格:
  ① 给一个 E2E consumer 恢复直接官方下载
  ② 消费者加回"下不到就 curl"的联网回退
  ③ 摘掉消费者的 SHA 校验
  ④ 摘掉消费者的版本校验
  ⑤ 摘掉 needs
  ⑥ artifact 名去掉摘要段
  ⑦ producer 不再调生产判据
  ⑧ 改用 actions/cache
  ⑨ action 改成浮动引用 @main
  ⑩ 只加无关注释(反向对照)
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CI = ".github/workflows/ci.yml"
INS = "tests/install-mosdns-artifact.sh"
NAM = "tests/mosdns-artifact-name.sh"
TOUCHED = [ROOT / f for f in (CI, INS, NAM)]

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900):
    # errors="replace": 被测脚本可能吐出非 UTF-8 字节(比如 `cut -c` 把一个中文字符切成半个),
    # 而负控在这里崩掉的话, 后面每一格都不会跑 —— 那是最难查的一种"负控自己坏了"。
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, errors="replace")


def failures(out):
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{7,64}\b", "H", t)
        s.add(t)
    return s


class Halt(Exception):
    """前置门不过 —— 停在任何一格改坏之前, 不进变异, 不打印通过。"""


def classify_run(rc, out):
    """把"子测试到底跑没跑起来"与"跑起来了但判据没红"分开。

    只看 `[FAIL]` 文本是不够的: 子测试在 import 期崩掉时一条 `[FAIL]` 也不会打印, 于是
    "提取到 0 条失败"与"全绿"长得一模一样。这里按可判别的形态归类, 归类结果决定这一次
    执行**算不算数**, 而不是直接拿它当判据。
    """
    n_ok, n_fail = out.count("[OK]"), out.count("[FAIL]")
    if "Traceback (most recent call last)" in out:
        return "崩溃(Traceback)", n_ok, n_fail
    if "ModuleNotFoundError" in out or "ImportError" in out:
        return "导入失败", n_ok, n_fail
    if rc == 127 or "command not found" in out or "No such file or directory" in out and n_ok + n_fail == 0:
        return "命令不存在", n_ok, n_fail
    if n_ok + n_fail == 0:
        return "零断言", n_ok, n_fail
    if rc != 0 and n_fail == 0:
        return "非零退出但无具名失败", n_ok, n_fail
    return "正常", n_ok, n_fail


def run_suite(wd, cmd):
    """跑一支子测试, 返回 (具名失败集合, 分类, [OK]数, [FAIL]数, rc)。"""
    r = run(cmd, cwd=wd)
    out = r.stdout + r.stderr
    kind, n_ok, n_fail = classify_run(r.returncode, out)
    return failures(out), kind, n_ok, n_fail, r.returncode


T_TOPO = [sys.executable, "tests/test-ci-mosdns-topology.py"]
T_TRIP = ["bash", "tests/test-mosdns-artifact-roundtrip.sh"]

PRODUCER = "prepare-mosdns-fixture"

CONSUMER_DL = '''      - uses: actions/download-artifact@v8
        with:
          name: ${{ env.MOSDNS_ARTIFACT }}
          path: /tmp/mosdns-fixture
'''
DL_USES = "      - uses: actions/download-artifact@v8\n"
NEEDS_PRODUCER = "    needs: prepare-mosdns-fixture\n"
ANCHORS = (("消费者取件块", CONSUMER_DL),
           ("download-artifact 引用行", DL_USES),
           ("needs: 生产者", NEEDS_PRODUCER))


def derive_consumers(ci_text):
    """现推消费者 job 名 —— 与 tests/test-ci-mosdns-topology.py 同口径。

    只回答"是谁", 不回答"关系对不对": 逐 job 的 needs / download-artifact 对应关系由那支
    正控验证(它是本支的基线), 这里不重造解析器。
    """
    import yaml
    jobs = (yaml.safe_load(ci_text) or {}).get("jobs") or {}

    def sig(j):
        return [(s.get("name") or "", str(s.get("run") or "")) for s in (jobs[j].get("steps") or [])]

    return sorted(j for j in jobs if j != PRODUCER
                  and any("mosdns" in r or "mosdns" in n for n, r in sig(j)))


def anchor_counts(ci_text):
    return {label: ci_text.count(text) for label, text in ANCHORS}


def consumer_gaps(ci_text):
    """诊断用: 逐消费者说清缺哪一样。只为把失败信息定位到具体 job, 判定权仍在拓扑正控。"""
    import yaml
    jobs = (yaml.safe_load(ci_text) or {}).get("jobs") or {}
    gaps = {}
    for j in derive_consumers(ci_text):
        nd = jobs[j].get("needs")
        nd = [nd] if isinstance(nd, str) else (nd or [])
        miss = []
        if PRODUCER not in nd:
            miss.append("没有 needs: %s" % PRODUCER)
        dl = [st for st in (jobs[j].get("steps") or [])
              if "download-artifact" in str(st.get("uses") or "")]
        if not dl:
            miss.append("没有 download-artifact 步骤")
        elif len(dl) > 1:
            miss.append("有 %d 个 download-artifact 步骤" % len(dl))
        if miss:
            gaps[j] = miss
    return gaps


def suite(wd, cmds):
    """跑若干子测试并合并具名失败; **执行链异常一律抬到调用方**, 不吞进空集合。"""
    got, kinds = set(), []
    for c in cmds:
        f, kind, n_ok, n_fail, rc = run_suite(wd, c)
        got |= f
        kinds.append((" ".join(str(x) for x in c[-1:]) or str(c), kind, n_ok, n_fail, rc))
    return got, kinds


def chain_broken(kinds):
    """返回执行链异常的描述列表(空 = 两支都真的跑起来了)。"""
    return ["%s → %s(rc=%s, [OK]%d/[FAIL]%d)" % (n, k, rc, o, f)
            for n, k, o, f, rc in kinds if k != "正常"]


# ── 前置门 P1/P2: 消费者个数现推, 三个锚点处数必须都等于它 ────────────────────
CI_TEXT = (ROOT / CI).read_text(encoding="utf-8")
CONSUMERS = derive_consumers(CI_TEXT)
N_CONSUMER = len(CONSUMERS)
COUNTS = anchor_counts(CI_TEXT)


def preflight_verdict(consumers, counts, gaps):
    """P1/P2 的**纯判定**: 只吃数据、只出结论, 便于用合成输入直接验它自己有没有牙。

    返回 (P1 说明, P2 说明) 或抛 Halt。放行的两条说明各算一条断言。
    """
    n = len(consumers)
    if n == 0:
        raise Halt("P1: 从 ci.yml 现推出的消费者个数是 0 —— 要么 workflow 真没有消费者, "
                   "要么推导口径与产品脱节。这正是锚点失配的样子, 不能当成「改 0 处」放过。")
    p1 = "P1 消费者个数现推 = %d(不写死): %s" % (n, ", ".join(consumers))

    wrong = {lab: c for lab, c in counts.items() if c != n}
    if wrong:
        detail = "; ".join("%s=%d" % (k, v) for k, v in sorted(counts.items()))
        named = ("; ".join("%s: %s" % (j, "、".join(m)) for j, m in sorted(gaps.items()))
                 or "逐 job 结构看不出缺口 —— 多半是换了写法(缩进/字段顺序), 锚点字面量已失效")
        raise Halt("P2: 锚点处数与消费者个数(%d)对不上 —— %s。具体到 job: %s"
                   % (n, detail, named))
    return p1, "P2 三个锚点处数均 = 消费者个数 %d(取件块 / download 引用 / needs 生产者)" % n


def preflight():
    """任何一格改坏之前先过闸。不过就 raise Halt —— 不进变异, 不打印通过。"""
    p1, p2 = preflight_verdict(CONSUMERS, COUNTS, consumer_gaps(CI_TEXT))
    ok(p1)
    ok(p2)


MUT = [
    ("① consumer 恢复直接官方下载", CI,
     [(CONSUMER_DL,
       '      - name: "直接下载"\n        run: |\n'
       '          curl -fsSL -o /tmp/m.zip '
       '"https://github.com/IrineSistiana/mosdns/releases/download/v5.3.4/mosdns-linux-amd64.zip"\n', N_CONSUMER)],
     [T_TOPO]),
    ("② 消费者加回联网 fallback", INS,
     [('[[ -f "$BIN" ]] || die "artifact 里没有 mosdns($BIN)"',
       '[[ -f "$BIN" ]] || curl -fsSL -o "$BIN" '
       '"https://github.com/IrineSistiana/mosdns/releases/download/$MOSDNS_VER/x.zip"', 1)],
     [T_TOPO, T_TRIP]),
    ("③ 摘掉消费者 SHA 校验", INS,
     [('[[ "$got_sha" == "$want_sha" ]] \\\n  || die', 'true \\\n  || die', 1)], [T_TRIP]),
    ("④ 摘掉消费者版本校验", INS,
     [('[[ "v${got_ver:-}" == "$MOSDNS_VER" ]] \\\n  || die', 'true \\\n  || die', 1)],
     [T_TOPO, T_TRIP]),
    ("⑤ 摘掉 needs", CI,
     [(NEEDS_PRODUCER, "", N_CONSUMER)], [T_TOPO]),
    ("⑥ artifact 名去掉摘要段", NAM,
     [("printf 'mosdns-%s-%s-%s\\n' \"$MOSDNS_VER\" \"$arch\" \"${sha:0:12}\"",
       "printf 'mosdns-%s-%s\\n' \"$MOSDNS_VER\" \"$arch\"", 1)], [T_TRIP]),
    ("⑦ producer 不再调生产判据", CI,
     [('          pdg_mosdns_binary_ok "$ARCH" "$MOSDNS_VER" "$PWD/artifact/mosdns"\n', "", 1)],
     [T_TOPO]),
    ("⑧ 改用 actions/cache", CI,
     [("      - uses: actions/upload-artifact@v7\n",
       "      - uses: actions/cache@v4\n", 1)], [T_TOPO]),
    ("⑨ action 改成浮动引用", CI,
     [(DL_USES,
       "      - uses: actions/download-artifact@main\n", N_CONSUMER)], [T_TOPO]),
    ("⑩ 只加一行无关注释(反向对照)", INS,
     [("die(){ echo", "# (负控的空转对照, 不改变任何行为)\ndie(){ echo", 1)], [T_TOPO, T_TRIP]),
]

def main():
    before = {q: sha(q) for q in TOUCHED}
    modes = {q: os.stat(q).st_mode for q in TOUCHED}
    halted = None

    wd = tmpguard.mkdtemp(prefix="pdg-artifact-negctl.")
    try:
        print("══ 前置门(改坏之前)══")
        try:
            preflight()
        except Halt as e:
            bad(str(e))
            raise

        for sub in ("tests", "lib", "deploy"):
            shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                            symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
        os.makedirs(Path(wd) / ".github/workflows", exist_ok=True)
        shutil.copy2(ROOT / CI, Path(wd) / CI)
        pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (CI, INS, NAM)}

        print()
        print("══ P3 基线(未改坏的同一份副本): 必须真的跑起来且全绿 ══")
        base = set()
        for tag, cmds in (("topo", [T_TOPO]), ("trip", [T_TRIP])):
            f, kinds = suite(wd, cmds)
            broken = chain_broken(kinds)
            if broken:
                bad("基线 %s 的子测试没有正常运行: %s" % (tag, "; ".join(broken)))
                raise Halt("P3: 基线执行链坏了 —— 提取到 0 条 [FAIL] 不等于全绿, "
                           "后面每一格的「新增」都无从算起。")
            n_ok = sum(k[2] for k in kinds)
            (ok if not f else bad)("基线 %s 全绿(断言 %d 条, 具名失败 %d)" % (tag, n_ok, len(f)))
            base |= f
        if base:
            for x in sorted(base)[:6]:
                print("       %s" % x[:150])
            raise Halt("P3: 基线不绿(%d 条具名失败) —— 拓扑/夹具本身已经有问题, "
                       "先修那个; 在红基线上算「新增」得到的每一格结论都不成立。" % len(base))

        for tag, rel, edits, cmds in MUT:
            print()
            print("── %s ──" % tag)
            text = pristine[rel]
            good = True
            for anchor, repl, want in edits:
                hits = text.count(anchor)
                print("   锚点命中 %d 次(期望 %d)" % (hits, want))
                if hits != want:
                    bad("%s: 锚点命中 %d 次, 期望 %d —— 锚点与产品写法脱节, 这一格没测到东西"
                        % (tag, hits, want))
                    good = False
                    break
                if want <= 0:
                    bad("%s: 期望替换处数为 %d —— 不允许「替换 0 处然后当成通过」" % (tag, want))
                    good = False
                    break
                after = text.replace(anchor, repl, want)
                # 替换必须**真的发生**, 且范围恰好是本格预期的那几处
                if after == text:
                    bad("%s: 替换后文本与替换前一字不差 —— 改坏器空转" % tag)
                    good = False
                    break
                # 范围核对: 恰好换掉 want 处。替换文本本身可能**按设计**再含锚点
                # (⑩ 就是在原行前面加一行注释、原行照留), 所以要把它自带的那几处算进去。
                left = after.count(anchor)
                expect_left = (hits - want) + want * repl.count(anchor)
                if left != expect_left:
                    bad("%s: 替换范围不对 —— 改完剩 %d 处锚点, 按「命中 %d / 换 %d / 替换文本自含 %d」应剩 %d"
                        % (tag, left, hits, want, repl.count(anchor), expect_left))
                    good = False
                    break
                text = after
            if not good:
                continue
            (Path(wd) / rel).write_text(text, encoding="utf-8")
            if rel.endswith(".yml"):
                try:
                    import yaml
                    yaml.safe_load((Path(wd) / rel).read_text(encoding="utf-8"))
                    print("   YAML 真解析: 过")
                except Exception as e:                                   # noqa: BLE001
                    bad("%s: 改坏后 YAML 解析不了(%s)" % (tag, str(e)[:80]))
                    (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
                    continue
            else:
                r = run(["bash", "-n", rel], cwd=wd)
                print("   bash -n: %s" % ("过" if r.returncode == 0 else "不过"))
                if r.returncode != 0:
                    bad("%s: 改坏后 bash -n 不过" % tag)
                    (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
                    continue
            got, kinds = suite(wd, cmds)
            broken = chain_broken(kinds)
            (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
            if broken:
                # 崩溃/夹具失败**不算检出**: 非零退出只有命中预期行为断言才算有牙。
                bad("%s: 子测试没有正常运行(%s) —— 这一格既不能算有牙, 也不能算无牙"
                    % (tag, "; ".join(broken)))
                continue
            newf = got - base
            if tag.startswith("⑩"):
                (ok if not newf else
                 bad)("反向对照: 无关注释新增失败 %d 条(应为 0; 两支子测试均正常运行)%s"
                      % (len(newf), (" —— " + "; ".join(sorted(newf))[:150]) if newf else ""))
            else:
                (ok if newf else
                 bad)("%s → 新增具名失败 %d 条%s"
                      % (tag, len(newf),
                         (": " + sorted(newf)[0][:105]) if newf
                         else " —— 子测试正常运行但 0 条转红, 这一格无效"))
    except Halt as e:
        halted = str(e)
    finally:
        shutil.rmtree(wd, ignore_errors=True)

    if halted:
        print()
        print("══ 已在改坏之前停下 ══")
        print("   %s" % halted)

    print()
    print("══ 正式树逐字节恢复 ══")
    for q in TOUCHED:
        (ok if sha(q) == before[q] else bad)("%s sha256 未变" % Path(q).name)
        (ok if os.stat(q).st_mode == modes[q] else bad)("%s mode 未变" % Path(q).name)

    print("-" * 62)
    print("mosdns-artifact-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

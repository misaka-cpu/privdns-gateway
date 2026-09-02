#!/usr/bin/env python3
"""正控: functional 的 conntrack 前提, 到底是**本轮自己持有**的, 还是白捡外部环境的。

上一轮(v1.10.15 / PR #27)给 tests/functional-test.sh 加了前置 ORIGDST 探针, 结论写成了
"确定性修复"。它其实只修了一半: 探针返回 ok 时夹具**直接 no-op**, 一张属于自己的表都不建,
整轮测试就架在一份自己不拥有、也无法保证会一直在的外部 conntrack 状态上。

PR #56 的 functional 红(run 33585584528)正是这个形态: 首探 `ORIGDST=ok`, 夹具走 no-op,
0.9 秒后 mihomo 真实 redir 流仍然拿不到 SO_ORIGINAL_DST —— 三个出口日志全空。mihomo 的
listener/redir/tcp.go 里 `parserPacket` 一失败就 `conn.Close(); return`, **任何日志级别都
不打一个字**, 所以从外面看只剩 "A='' B='' D=''" 这种要靠猜的症状。

本轮要闭合的不是"Azure 内核为什么偶发丢 ORIGDST"(那没有证据, 也不在本轮范围), 而是
**夹具不拥有前提**这一已被证明的事实: 只要拿得到免密 sudo + nft, 无论首探是 ok 还是
ENOENT, 都必须建立本轮独占的表, 并靠二次探针确认它真的生效。

判据不是源码字符串: 每一格都在一个**专属的 named netns** 里真跑 functional-test.sh,
按四个时刻的 `nft list tables` 快照区分五种状态 ——

    S0 只有外部表 → S1 外部+自有并存 → (删掉外部) → S2 只剩自有 → S3 两者都回到前像

用 named netns 而不是 `unshare -n`: 残留要在脚本退出**之后**看, 匿名 netns 随进程消失,
"跑完还剩什么"会被环境自动抹掉。

九格:
  ① 首探 ok  + 有 sudo      → 仍建自有表, 二次探针成功, functional 全绿
  ② 首探 ENOENT + 有 sudo   → 建自有表, 二次探针成功, functional 全绿
  ③ 首探 ok, 外部表随后被删 → 自有表仍在, functional 继续全绿(**红灯先行那一格**)
  ④ 首探 ENOENT + 建表成功但不生效 → 二次探针具名失败, 不进入实际用例
  ⑤ 无 sudo + 首探 ok       → 非 root 本地路径仍可跑, 但必须明说依赖外部状态
  ⑥ 无 sudo + 首探 ENOENT   → 具名硬失败, SKIP 0
  ⑦ cleanup 注入失败        → 残留守卫转红
  ⑧ functional 原四格       → A / B / default / GMS 全命中
  ⑨ 失败诊断                → 不重试, 且再探针/自有表/mock PID/测试端口都出现
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402 - 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[2]
TOUCHED = [ROOT / "tests/functional-test.sh", ROOT / "tests/origdst_probe.py"]

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ── 干净 netns: 名字唯一, 建了就一定删 ────────────────────────────────────────
class Netns:
    def __init__(self, name):
        self.name = name

    def __enter__(self):
        run(["sudo", "-n", "ip", "netns", "add", self.name])
        run(["sudo", "-n", "ip", "netns", "exec", self.name, "ip", "link", "set", "lo", "up"])
        return self

    def __exit__(self, *a):
        run(["sudo", "-n", "ip", "netns", "del", self.name])
        return False

    def nft(self, *argv):
        return run(["sudo", "-n", "ip", "netns", "exec", self.name, "nft"] + list(argv))

    def tables(self):
        """本 netns 里现有的表 —— 五状态快照就靠它。"""
        r = self.nft("list", "tables")
        return sorted(l.strip() for l in r.stdout.splitlines() if l.strip())

    def add_external_ct(self, name):
        """摆一张**外部**的 conntrack 激活表: 模拟 runner 上碰巧存在的宿主状态。

        它扮演的是"夹具不拥有、也管不着"的那一份前提 —— 名字刻意不带 pdgfunc,
        这样自有表与外部表在快照里一眼可分。"""
        self.nft("add", "table", "inet", name)
        self.nft("add", "chain", "inet", name, "input",
                 "{ type filter hook input priority 0; policy accept; }")
        self.nft("add", "rule", "inet", name, "input", "ct", "state",
                 "established,related", "accept")

    def del_table(self, name):
        return self.nft("delete", "table", "inet", name)


def has_own(tabs):
    return [t for t in tabs if "pdgfunc" in t]


def has_ext(tabs):
    return [t for t in tabs if "pdgext" in t]


def failures(out):
    return {l.strip() for l in out.splitlines() if l.startswith("[FAIL]")}


# 夹具在做完 conntrack 决策后一定会打的那一行 —— 三条分支各有各的措辞, 都认。
NOTE_RE = re.compile(r"自有 conntrack 表 inet |临时 conntrack 表 inet |"
                     r"conntrack 前提已满足|ORIGDST 前提来自外部环境")


def run_in_ns(ns, script, path, ext_table=None, drop_ext=False, timeout=420):
    """在 netns 里真跑一遍 functional-test.sh, 并在**夹具做完 conntrack 决策的那一刻**
    取快照 —— 那是唯一能把"自己建了表"和"白捡外部状态"分开的时刻。

    drop_ext=True 时, 就在那一刻把外部表撤走: 之后还能不能跑, 完全取决于夹具有没有
    自己的那一张。这就是本轮要闭合的那件事, 且它是**行为判据**, 不是源码字符串。

    返回 (rc, 全部输出, S0, S1, S2, S3)。
    """
    S0 = ns.tables()
    proc = subprocess.Popen(
        ["sudo", "-n", "ip", "netns", "exec", ns.name, "env", "PATH=%s" % path,
         "bash", str(script)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines, snaps = [], {}

    def pump():
        for line in proc.stdout:
            lines.append(line)
            if "S1" not in snaps and NOTE_RE.search(line):
                snaps["S1"] = ns.tables()
                if drop_ext and ext_table:
                    ns.del_table(ext_table)
                    snaps["S2"] = ns.tables()

    t = threading.Thread(target=pump)
    t.start()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    t.join(60)
    return proc.returncode, "".join(lines), S0, snaps.get("S1"), snaps.get("S2"), ns.tables()


def hits(out):
    """四个用例的命中行 —— 断言的是"到了哪个出口", 不是"跑完了"。"""
    return sorted(re.findall(r"→ (exit[A-Za-z]+)\(", out))


def head(out, n=6):
    keep = [l for l in out.splitlines()
            if l.startswith("[FAIL]") or "ORIGDST" in l or "conntrack" in l]
    return "\n".join("       " + l[:132] for l in keep[:n])


# ── 前提: 这支要真建 netns、真加载 nft, 没有权限就等于没跑 ────────────────────
if run(["sudo", "-n", "true"]).returncode != 0:
    bad("需要免密 sudo —— 这支要真建 netns 才有判据, 没有就等于没跑")
    print("-" * 62)
    print("functional-conntrack-ownership.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
if run(["sudo", "-n", "nft", "--version"]).returncode != 0:
    bad("sudo 下调不到 nft —— 这支要真加载 nft 才有判据, 没有就等于没跑")
    print("-" * 62)
    print("functional-conntrack-ownership.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-fnct-own.")
try:
    for sub in ("tests", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    script = Path(wd) / "tests/functional-test.sh"
    pristine = script.read_text(encoding="utf-8")

    # 钉死版 mihomo 备到工作副本(不落正式树)。干净 netns 里只有 lo, 下不了东西 ——
    # 必须在进 netns **之前**备好并放上 PATH, 让 mihomo_usable() 走"用现有 mihomo"。
    bindir = Path(wd) / "bin"
    prep = subprocess.run(["bash", str(ROOT / "tests/prepare-mihomo.sh")],
                          cwd=str(ROOT), capture_output=True, text=True, timeout=600,
                          env={**os.environ, "PDG_TEST_BIN_DIR": str(bindir)})
    if not (bindir / "mihomo").exists():
        bad("备不出钉死版 mihomo, 后面每一格都无从判断: %s"
            % (prep.stderr.strip()[-200:] or prep.stdout.strip()[-200:]))
        raise SystemExit(1)
    SYS = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    PATH_OK = "%s:%s" % (bindir, SYS)

    # "没有免密 sudo"那两格: 拿一个恒失败的 sudo 桩顶在 PATH 最前面。
    # 不是把测试跑成非 root(netns exec 本来就是 root), 而是让夹具**问不到**建表的权限 ——
    # 要判的正是"权限拿不到时它怎么办", 那就把权限这一问的答案定死。
    nosudo = Path(wd) / "nosudo"
    nosudo.mkdir()
    (nosudo / "sudo").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    (nosudo / "sudo").chmod(0o755)
    PATH_NOSUDO = "%s:%s:%s" % (nosudo, bindir, SYS)

    EXT = "pdgext%d" % os.getpid()

    def cell(tag, *, external, path, drop_ext=False, mutate=None):
        """跑一格。external=True 先摆一张外部 conntrack 表(于是首探必然 ok)。"""
        try:
            script.write_text(mutate(pristine) if mutate else pristine, encoding="utf-8")
        except AssertionError as e:
            bad("%s → 改坏器没打在预期位置: %s" % (tag, e))
            script.write_text(pristine, encoding="utf-8")
            return None
        if run(["bash", "-n", str(script)]).returncode != 0:
            bad("%s → 改坏后语法不合法, 这格不作数" % tag)
            script.write_text(pristine, encoding="utf-8")
            return None
        ns_name = "pdgown%d%s" % (os.getpid(), tag)
        try:
            with Netns(ns_name) as n:
                if external:
                    n.add_external_ct(EXT)
                r = run_in_ns(n, script, path, ext_table=EXT, drop_ext=drop_ext)
        finally:
            script.write_text(pristine, encoding="utf-8")
        return r

    # 两处改坏用的锚点 —— 都取自夹具里语义唯一的那一行。
    CT_RULE = ('  sudo -n nft add rule inet "$t" input ct state established,related accept \\\n'
               '    || fail "加 ct 规则失败: inet $t"')
    CT_NOOP = ('  sudo -n nft list table inet "$t" >/dev/null \\\n'
               '    || fail "加 ct 规则失败: inet $t"')
    CLEANUP = "\n  drop_conntrack_table\n"

    def mut(old, new):
        def f(text):
            assert text.count(old) == 1, "锚点 %r 命中 %d 次" % (old[:40], text.count(old))
            return text.replace(old, new, 1)
        return f

    # ── ① 首探 ok + 有 sudo: 仍然要建自己的表 ────────────────────────────────
    r1 = cell("1", external=True, path=PATH_OK)
    if r1:
        rc, out, S0, S1, S2, S3 = r1
        if not has_ext(S0) or has_own(S0):
            bad("① 起点不对: S0=%s(应当只有外部表)" % S0)
        elif S1 is None:
            bad("① 没等到夹具的决策行, 取不到 S1:\n%s" % head(out))
        elif not has_own(S1):
            bad("① 首探 ok 时夹具**没有建自己的表** —— 整轮架在外部状态上(S1=%s)\n%s"
                % (S1, head(out)))
        elif not has_ext(S1):
            bad("① 夹具动了外部表: S1=%s(外部那张不见了)" % S1)
        elif rc != 0:
            bad("① 建了自有表却没跑绿(rc=%s)\n%s" % (rc, head(out)))
        elif "自有 conntrack 表 inet " not in out:
            bad("① 建了表却没说清是本轮自有的(措辞看不出所有权)")
        elif S3 != S0:
            bad("① 跑完现场没回到前像: S0=%s S3=%s" % (S0, S3))
        else:
            ok("① 首探 ok + 有 sudo → 仍建自有表(%s), 二次探针通过, functional 全绿, 现场归零"
               % has_own(S1)[0][:34])

        # ── ⑧ 原四格: A / B / default / GMS 全命中 ───────────────────────────
        got = hits(out)
        want = ["exitA", "exitB", "exitB", "exitDefault"]
        if got == want:
            ok("⑧ 原四格全命中: alpha→exitA, beta→exitB, mtalk→exitB, gamma→exitDefault")
        else:
            bad("⑧ 四格没有全命中: 实得 %s, 预期 %s\n%s" % (got, want, head(out)))

    # ── ② 首探 ENOENT + 有 sudo ──────────────────────────────────────────────
    r2 = cell("2", external=False, path=PATH_OK)
    if r2:
        rc, out, S0, S1, S2, S3 = r2
        if S0:
            bad("② 起点不干净: S0=%s(应当一张表都没有)" % S0)
        elif S1 is None or not has_own(S1):
            bad("② 干净 netns 里没建起自有表(S1=%s)\n%s" % (S1, head(out)))
        elif rc != 0:
            bad("② 建了自有表却没跑绿(rc=%s)\n%s" % (rc, head(out)))
        elif S3:
            bad("② 跑完有残留: S3=%s" % S3)
        else:
            ok("② 首探 ENOENT + 有 sudo → 自建表并通过二次探针, functional 全绿, 零残留")

    # ── ③ 首探 ok, 决策做完就把外部表撤走(红灯先行那一格)──────────────────────
    r3 = cell("3", external=True, path=PATH_OK, drop_ext=True)
    if r3:
        rc, out, S0, S1, S2, S3 = r3
        if S1 is None or S2 is None:
            bad("③ 没取到决策时刻的快照(S1=%s S2=%s)\n%s" % (S1, S2, head(out)))
        elif not (has_ext(S1) and has_own(S1)):
            bad("③ 撤走外部表之前, 外部与自有并没有并存(S1=%s) —— 夹具没有持有自己的 "
                "conntrack 激活状态\n%s" % (S1, head(out)))
        elif has_ext(S2):
            bad("③ 外部表没被撤走, 这格什么都没验到(S2=%s)" % S2)
        elif not has_own(S2):
            bad("③ 外部表撤走后自有表也不在了(S2=%s)" % S2)
        elif rc != 0:
            bad("③ 外部 conntrack 撤走后 functional 转红(rc=%s) —— 前提仍然来自外部, "
                "不是本轮自己持有的\n%s" % (rc, head(out)))
        elif hits(out) != ["exitA", "exitB", "exitB", "exitDefault"]:
            bad("③ 撤走外部表后四格没有全命中: %s" % hits(out))
        elif S3:
            bad("③ 跑完有残留: S3=%s" % S3)
        else:
            ok("③ 外部 conntrack 撤走后 functional 仍全绿 —— 前提由本轮自有表持有(S2=%s)"
               % has_own(S2)[0][:34])

    # ── ④ 建表成功但不生效: 二次探针必须具名拦住 ──────────────────────────────
    r4 = cell("4", external=False, path=PATH_OK, mutate=mut(CT_RULE, CT_NOOP))
    if r4:
        rc, out, S0, S1, S2, S3 = r4
        named = [l for l in out.splitlines() if "SO_ORIGINAL_DST 仍拿不到" in l]
        if rc == 0:
            bad("④ 表建起来了但 conntrack 没激活, 竟然还跑绿了")
        elif not named:
            bad("④ 转红了但没有具名诊断(读的人只看得到三格空)\n%s" % head(out))
        elif hits(out):
            bad("④ 前提没成立却仍然进了实际用例: %s" % hits(out))
        elif S3:
            bad("④ 前提失败路径上留下了残留: S3=%s" % S3)
        else:
            ok("④ 建表成功但不生效 → 二次探针具名拦住, 未进入实际用例, 无残留")

    # ── ⑤ 无 sudo + 首探 ok: 本地非 root 路径仍可跑, 但必须明说 ────────────────
    r5 = cell("5", external=True, path=PATH_NOSUDO)
    if r5:
        rc, out, S0, S1, S2, S3 = r5
        marked = "ORIGDST 前提来自外部环境" in out
        if rc != 0:
            bad("⑤ 无 sudo + 首探 ok 时不该硬失败(rc=%s) —— 非 root 本地能力丢了\n%s"
                % (rc, head(out)))
        elif not marked:
            bad("⑤ 跑是跑了, 但没标记「前提来自外部环境」—— 读的人会以为夹具持有它")
        elif S1 and has_own(S1):
            bad("⑤ 没有 sudo 却建出了自有表(S1=%s), 说明权限判断是假的" % S1)
        elif S3 != S0:
            bad("⑤ 跑完现场没回到前像: S0=%s S3=%s" % (S0, S3))
        else:
            ok("⑤ 无 sudo + 首探 ok → 仍可运行, 且明确标记前提来自外部环境")

    # ── ⑥ 无 sudo + 首探 ENOENT: 具名硬失败, 不许跳过 ─────────────────────────
    r6 = cell("6", external=False, path=PATH_NOSUDO)
    if r6:
        rc, out, S0, S1, S2, S3 = r6
        named = [l for l in out.splitlines() if "建不起前提" in l]
        skips = [l for l in out.splitlines() if "[SKIP]" in l]
        if rc == 0:
            bad("⑥ 缺 conntrack 又没权限, 竟然返回 0(零覆盖披着绿灯出场)")
        elif not named:
            bad("⑥ 转红了但没具名说是建不起前提\n%s" % head(out))
        elif skips:
            bad("⑥ 出现了 %d 条 SKIP —— 跳过等于零覆盖" % len(skips))
        elif hits(out):
            bad("⑥ 前提失败却仍进了实际用例: %s" % hits(out))
        else:
            ok("⑥ 无 sudo + 首探 ENOENT → 具名硬失败, SKIP 0, 未进入实际用例")

    # ── ⑦ 摘掉清理: 残留守卫必须转红 ─────────────────────────────────────────
    r7 = cell("7", external=False, path=PATH_OK, mutate=mut(CLEANUP, "\n"))
    if r7:
        rc, out, S0, S1, S2, S3 = r7
        if has_own(S3):
            ok("⑦ 摘掉清理 → 残留守卫具名报出自有表: %s" % has_own(S3)[0][:44])
            # 自己造的残留自己收拾: 这张表在本进程的 netns 里, 跟着 netns 一起被删掉。
        else:
            bad("⑦ 清理都摘了却没留下残留(S3=%s), 残留守卫无效" % S3)

    # ── ⑨ 失败诊断: 不重试, 但必须把该问的都问一遍 ───────────────────────────
    r9 = cell("9", external=True, path=PATH_NOSUDO, drop_ext=True)
    if r9:
        rc, out, S0, S1, S2, S3 = r9
        want_fields = [
            ("再探 ORIGDST", "失败时刻的 SO_ORIGINAL_DST"),
            ("自有 nft 表", "自有表当时在不在"),
            ("mock exitA pid=", "三个出口进程存活"),
            ("本测试端口监听", "本测试用的四个端口"),
            ("conntrack:", "conntrack 模块/条目计数"),
        ]
        missing = [d for k, d in want_fields if k not in out]
        nfail = len([l for l in out.splitlines() if l.startswith("[FAIL]")])
        if rc == 0:
            bad("⑨ 外部前提被撤走、又没有自有表, 竟然还跑绿了 —— 这格没造出失败现场")
        elif missing:
            bad("⑨ 失败取证缺了这些字段: %s\n%s" % ("、".join(missing), head(out)))
        elif hits(out):
            bad("⑨ 第一个用例失败后还命中了出口(%s) —— 像是重试过" % hits(out))
        elif nfail != 1:
            bad("⑨ 失败行有 %d 条, 预期恰好 1 条(第一次失败不许被洗掉或重复)" % nfail)
        else:
            ok("⑨ 失败取证五项齐全, 且没有重试: 一条具名失败, 0 个用例命中")
        # 取证只读: 不许在失败路径上重启 mock 或重建表
        if re.search(r"重启|restart|nft add table", out):
            bad("⑨ 失败路径上出现了重启/建表动作 —— 取证必须只读")
        else:
            ok("⑨ 失败取证是只读的: 没有重启 mock, 也没有补建任何表")
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = True
for p in TOUCHED:
    if sha(p) != before[p]:
        bad("正式树被改动了! %s: %s → %s" % (p.name, before[p][:16], sha(p)[:16]))
        clean = False
    if os.stat(p).st_mode != modes[p]:
        bad("正式树权限位变了! %s" % p.name)
        clean = False
if clean:
    ok("正式树未被污染: functional-test.sh / origdst_probe.py sha256 与 mode 均一致")

print("-" * 62)
print("functional-conntrack-ownership.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

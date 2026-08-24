#!/usr/bin/env python3
"""负控: functional 测试的 conntrack 前提夹具有没有牙。

夹具本身在 tests/functional-test.sh 的第 0 节 —— 那段说"跑之前要先把前提摆好"。
这一支回答另一个问题: **如果那段退化了, 我们会不会知道?**

为什么需要它: mihomo 的 redir 入站靠 getsockopt(SOL_IP, SO_ORIGINAL_DST) 取原始目的地,
那个 sockopt 由 conntrack 提供。本 netns 没启用 conntrack hook 时它返回 ENOENT, mihomo
**静默丢掉**连接 —— 三个出口日志全空, 而 mihomo 一个字都不打。main 的 32722985743 与
32579827324 就是这么红的, 同一份代码在别的 run 上全绿。这种"看不出真因的偶发红"最容易被
一句"重跑一下就好了"糊过去, 所以夹具的每一环都要有负控盯着。

做法是逐格把夹具改坏, 然后在一个**干净 netns**(名字唯一的 named netns, 里面没有任何
conntrack hook)里跑 functional 测试, 看两件事有没有变化:

  1. 具名失败集合相对基线有没有**新增**(基线 = 官方夹具在同样的干净 netns 里跑, 必须全绿);
  2. 跑完那个 netns 里有没有**残留**的临时表。

每格五步, 缺一不算有效:
  · 锚点在整份文件里**恰好命中**预期次数(多了少了都说明改坏器没打在预期位置);
  · 替换后锚点恰好被消费掉一次, 且替换内容确实落进了文件;
  · 改坏后 `bash -n` 仍通过(语法错造成的红不算"判据抓住了");
  · 失败集合有具名新增, 或残留守卫报出残留;
  · 恢复后正式树 sha256 与 before-image 逐字节一致。

改坏落在**工作副本**里, 正式树一个字节都不动 —— 跑完会核对。

盯的六件事:
  ① 摘掉前提建立     —— 回到偶发红那天的状态, 三格全空;
  ② setup 成功但不生效 —— nft 三条命令都返回 0, conntrack 却没被激活;
  ③ 摘掉二次探针     —— 让 ② 那种无效 setup 冒充"已准备好", 精确诊断消失、只剩三格空;
  ④ 摘掉清理         —— 临时表留在 netns 里, 下一个用它的人接手一个脏现场;
  ⑤ 建不起来就 return 0 —— 把"建不起前提"悄悄降级成跳过, 零覆盖披着绿灯出场;
  ⑥ 只加无关注释     —— 反向对照: 不该产生任何新失败, 否则说明判据在看噪声。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
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


def sudo_ok():
    return subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0


def run(cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ── 干净 netns: 名字唯一, 建了就一定删 ────────────────────────────────────────
# 用 named netns 而不是 `unshare -n`: 残留判据要在**脚本退出之后**看那个 netns 里还剩什么,
# unshare 的匿名 netns 随进程一起消失, 残留会被环境自动抹掉 —— 那样 ④ 就永远抓不到东西。
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

    def exec(self, argv, env_path=None, timeout=300):
        pre = ["sudo", "-n", "ip", "netns", "exec", self.name]
        if env_path:
            pre += ["env", "PATH=%s" % env_path]
        return run(pre + argv, timeout=timeout)

    def stray_tables(self):
        """本 netns 里还剩几张 pdgfunc* 表 —— 夹具清理干净的话应当一张都没有。"""
        r = self.exec(["nft", "list", "tables"])
        return [l.strip() for l in r.stdout.splitlines() if "pdgfunc" in l]


def failures(out):
    return {l.strip() for l in out.splitlines() if l.startswith("[FAIL]")}


# 每格 = (标签, [(锚点, 替换, 预期命中数), …])。
# ③ 和 ⑤ 各带两条编辑: 它们盯的那一环, 只有先让 setup 变成"成功但不生效"才走得到。
CALL = "\nensure_conntrack\n"
CT_RULE = ('  sudo -n nft add rule inet "$t" input ct state established,related accept \\\n'
           '    || fail "加 ct 规则失败: inet $t"')
CT_NOOP = ('  sudo -n nft list table inet "$t" >/dev/null \\\n'
           '    || fail "加 ct 规则失败: inet $t"')
REPROBE = ('  out="$(probe_origdst)"; rc=$?\n'
           '  [[ "$rc" == 0 ]] \\\n'
           '    || fail "临时表建好了但 SO_ORIGINAL_DST 仍拿不到($out) —— 前提不成立, 不继续碰运气"')

MUTATIONS = [
    ("① 摘掉前提建立(回到偶发红那天)", [(CALL, "\n", 1)]),
    ("② setup 成功但不生效(nft 全返回 0, conntrack 没激活)", [(CT_RULE, CT_NOOP, 1)]),
    ("③ ② 之上再摘掉二次探针(让无效 setup 冒充已准备好)",
     [(CT_RULE, CT_NOOP, 1), (REPROBE, '  rc=0', 1)]),
    ("④ 摘掉清理(临时表留在 netns 里)", [("\n  drop_conntrack_table\n", "\n", 1)]),
    ("⑤ 建不起来就 return 0(把前提失败降级成跳过)",
     [("    3) : ;;", '    3) note "conntrack 未激活, 那就算了"; return 0 ;;', 1)]),
    ("⑥ 只加一行无关注释(反向对照, 不该有新失败)",
     [("ensure_conntrack(){", "# (负控的空转对照, 不改变任何行为)\nensure_conntrack(){", 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

if not sudo_ok():
    bad("需要免密 sudo —— 这支要真建 netns、真加载 nft 才有判据, 没有就等于没跑")
    print("-" * 62)
    print("functional-conntrack-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
if run(["sudo", "-n", "nft", "--version"]).returncode != 0:
    bad("sudo 下调不到 nft —— 这支要真加载 nft 才有判据, 没有就等于没跑")
    print("-" * 62)
    print("functional-conntrack-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

wd = tmpguard.mkdtemp(prefix="pdg-fnct-negctl.")
try:
    for sub in ("tests", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    script = Path(wd) / "tests/functional-test.sh"
    pristine = script.read_text(encoding="utf-8")

    # 钉死版 mihomo 备到工作副本里(不落正式树: prepare-mihomo.sh 认 PDG_TEST_BIN_DIR)。
    # 干净 netns 里只有 lo, 下不了东西 —— 必须在进 netns **之前**备好, 并放到 PATH 上,
    # 让 functional-test.sh 的 mihomo_usable() 认出它, 走"用现有 mihomo"那条路。
    bindir = Path(wd) / "bin"
    prep = subprocess.run(["bash", str(ROOT / "tests/prepare-mihomo.sh")],
                          cwd=str(ROOT), capture_output=True, text=True, timeout=600,
                          env={**os.environ, "PDG_TEST_BIN_DIR": str(bindir)})
    if not (bindir / "mihomo").exists():
        bad("备不出钉死版 mihomo, 后面每一格都无从判断: %s"
            % (prep.stderr.strip()[-200:] or prep.stdout.strip()[-200:]))
        raise SystemExit(1)
    path = "%s:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" % bindir

    def one(tag):
        """在一个专属的干净 netns 里跑一遍, 返回 (失败集合, 残留表, 退出码)。"""
        ns = "pdgfnct%d%s" % (os.getpid(), tag)
        with Netns(ns) as n:
            r = n.exec(["bash", str(script)], env_path=path)
            return failures(r.stdout + r.stderr), n.stray_tables(), r.returncode

    base_fs, base_stray, base_rc = one("b")
    if base_rc == 0 and not base_fs and not base_stray:
        ok("基线绿: 官方夹具在干净 netns 里自建前提并通过, 且没留下临时表")
    else:
        bad("基线就不绿(rc=%s, %d 条失败, %d 张残留表), 后面每一格都无从判断:"
            % (base_rc, len(base_fs), len(base_stray)))
        for f in sorted(base_fs)[:5]:
            print("       " + f[:130])
        for s in base_stray[:3]:
            print("       残留: " + s[:110])
        raise SystemExit(1)

    for i, (label, edits) in enumerate(MUTATIONS):
        mutated, aborted = pristine, False
        for old, new, want_hits in edits:
            hits = mutated.count(old)
            if hits != want_hits:
                bad("%s → 锚点 %r 命中 %d 次, 预期 %d(改坏器没打在预期位置)"
                    % (label, re.sub(r"\s+", " ", old)[:40], hits, want_hits))
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
            # 校验"锚点被恰好消费掉一次", 不去数新内容出现几次: 删除型的改坏(① ④)替换成的
            # 就是一个换行符, 全文有两百多个 —— 按新内容计数会把有效负控判成改坏器打偏。
            # ⑥ 那种前缀插入, 替换内容里本来就含着锚点, 所以要把它带回来一起算。
            want_left = want_hits - 1 + new.count(old)
            left = mutated.count(old)
            if left != want_left:
                bad("%s → 替换后锚点还剩 %d 处, 预期 %d(没被吃掉或吃多了)"
                    % (label, left, want_left))
                aborted = True
                break
            if new and new not in mutated:
                bad("%s → 替换内容没落进文件里" % label)
                aborted = True
                break
        if aborted:
            continue
        script.write_text(mutated, encoding="utf-8")
        if run(["bash", "-n", str(script)]).returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            script.write_text(pristine, encoding="utf-8")
            continue
        fs, stray, _rc = one(str(i))
        script.write_text(pristine, encoding="utf-8")
        added = fs - base_fs

        if label.startswith("⑥"):
            if added or stray:
                bad("%s → 竟然新增了 %d 条失败 / %d 张残留表, 判据在看噪声"
                    % (label, len(added), len(stray)))
            else:
                ok("%s → 0 条新增(判据不看噪声)" % label)
            continue

        if label.startswith("④"):
            # 这一格的牙不在失败集合上: 摘掉清理并不影响用例通过, 变化只体现在现场。
            if stray:
                ok("%s → 残留守卫具名报出 %d 张表: %s" % (label, len(stray), stray[0][:60]))
            else:
                bad("%s → 清理都摘了却**没留下残留**, 残留守卫无效" % label)
            continue

        if not added:
            bad("%s → 锚点命中但**0 条转红**, 负控无效" % label)
            continue
        ok("%s → 锚点 %d 条全命中, 新增 %d 条具名失败" % (label, len(edits), len(added)))
        for f in sorted(added)[:2]:
            print("       " + f[:128])
        if label.startswith("③"):
            # ③ 的重点不只是"红了", 而是**红的理由退化了**: 精确的前提诊断消失,
            # 只剩下"三个格子都是空的"这种要靠猜的症状 —— 正是二次探针在挡的那件事。
            precise = [f for f in added if "SO_ORIGINAL_DST 仍拿不到" in f]
            if precise:
                bad("③ → 摘了二次探针却仍报出精确诊断, 说明这格没打中那一环")
            else:
                ok("③ → 精确前提诊断消失, 只剩三格空的模糊症状(正是二次探针在挡的)")
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
print("functional-conntrack-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""负控: functional 的 conntrack 夹具与失败取证有没有牙。

夹具本身在 tests/functional-test.sh 的第 0 节, 正控在 functional-conntrack-ownership.py。
这一支回答另一个问题: **如果那些环退化了, 我们会不会知道?**

为什么需要它: mihomo 的 redir 入站靠 getsockopt(SOL_IP, SO_ORIGINAL_DST) 取原始目的地,
拿不到时 handleRedir 里 `conn.Close(); return` —— 任何日志级别都不打一个字, 外面只剩
"A='' B='' D=''"。这种看不出真因的偶发红最容易被一句"重跑一下就好了"糊过去:
main 的 32722985743、32579827324 和 PR #56 的 33585584528 都是这个形态。所以夹具的每一环
都要有负控盯着, 尤其是**所有权**这一环 —— v1.10.15 修的是"探得到就 no-op", 那等于把整轮
架在一份自己不拥有的外部状态上, 而它以"确定性修复"的名义过了一轮评审。

两种判据, 按每格盯的那一环选:
  · **正控驱动(own)**: 把改坏过的夹具喂给 functional-conntrack-ownership.py, 看**指定的
    那几格**转红。所有权、撤走外部状态、失败取证这些, 判据本来就在正控里, 这里只验它有牙。
  · **直跑(plain)**: 在干净 netns 里直接跑 functional-test.sh, 看具名失败集合与残留表。
    清理、CI 收紧这类不经过正控的环用它。

每格五步, 缺一不算有效:
  · 锚点在整份文件里**恰好命中**预期次数(多了少了都说明改坏器没打在预期位置);
  · 替换后锚点恰好被消费掉一次, 且替换内容确实落进了文件;
  · 改坏后 `bash -n` 仍通过(语法错造成的红不算"判据抓住了");
  · 出现**预期的那几条**具名新增失败(不是随便红一条就算);
  · 恢复后正式树 sha256 与 mode 逐字节一致。

改坏落在**工作副本**里, 正式树一个字节都不动 —— 跑完会核对。

盯的十二件事:
  ① 恢复"首探 ok 就 no-op"      —— 正是 PR #56 那次红的形态, 所有权格必须转红;
  ② 摘掉自有表创建              —— 权限拿得到却不建, 前提又变成白捡的;
  ③ 摘掉二次探针                —— 让"建了但没生效"的 setup 冒充已准备好;
  ④ 提前删掉自有表              —— 建了又不留住, 外部状态一撤走就塌;
  ⑤ 摘掉清理                    —— 临时表留在 netns 里, 下一个人接手脏现场;
  ⑥ CI 建表失败后退回 no-op     —— 把权威环境的硬门降级成"算了";
  ⑦ 无 sudo+ENOENT 改成 return 0 —— 零覆盖披着绿灯出场;
  ⑧ 失败后自动重试用例          —— 把第一次失败洗掉, 偶发红从此看不见;
  ⑨ 摘掉失败时的二次 ORIGDST 探针 —— 取证少了最能定性的那一问;
  ⑩ 摘掉 mock PID 存活          —— 取证少了"出口还在不在"这一问;
  ⑪ 清理改成 flush ruleset      —— 越过自己那张表, 动别人的规则;
  ⑫ 只加无关注释                —— 反向对照: 不该产生任何新失败。
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
TOUCHED = [ROOT / "tests/functional-test.sh", ROOT / "tests/origdst_probe.py",
           ROOT / "tests/negctl/functional-conntrack-ownership.py"]

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, timeout=900, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)


class Netns:
    """干净 netns: 名字唯一, 建了就一定删。

    用 named netns 而不是 `unshare -n`: 残留判据要在脚本退出**之后**看那个 netns 里还剩
    什么, 匿名 netns 随进程一起消失 —— 那样"摘掉清理"那一格就永远抓不到东西。"""

    def __init__(self, name):
        self.name = name

    def __enter__(self):
        run(["sudo", "-n", "ip", "netns", "add", self.name], timeout=120)
        run(["sudo", "-n", "ip", "netns", "exec", self.name, "ip", "link", "set", "lo", "up"],
            timeout=120)
        return self

    def __exit__(self, *a):
        run(["sudo", "-n", "ip", "netns", "del", self.name], timeout=120)
        return False

    def exec(self, argv, env_kv=None, timeout=600):
        pre = ["sudo", "-n", "ip", "netns", "exec", self.name, "env"]
        for k, v in (env_kv or {}).items():
            pre.append("%s=%s" % (k, v))
        return run(pre + argv, timeout=timeout)

    def stray_tables(self):
        r = self.exec(["nft", "list", "tables"])
        return [l.strip() for l in r.stdout.splitlines() if "pdgfunc" in l]

    def add_external_ct(self, name):
        self.exec(["nft", "add", "table", "inet", name])
        self.exec(["nft", "add", "chain", "inet", name, "input",
                   "{ type filter hook input priority 0; policy accept; }"])
        self.exec(["nft", "add", "rule", "inet", name, "input", "ct", "state",
                   "established,related", "accept"])


def failures(out):
    return {l.strip() for l in out.splitlines() if l.startswith("[FAIL]")}


def cells(out):
    """正控输出里转红的是哪几格 —— 取 [FAIL] 后面那个格号。"""
    return {l[7:8] for l in out.splitlines() if l.startswith("[FAIL] ")}


# ── 锚点: 每条都取自夹具里语义唯一的那一行 ────────────────────────────────────
CASE_BOTH = ('    0|3) : ;;                     '
             '# ok 与 ENOENT 都往下走: 有没有外部状态, 都要自己建')
CASE_NOOP = ('    0) note "conntrack 前提已满足($CT_FIRST), 不建任何临时规则"; return 0 ;;\n'
             '    3) : ;;')
HAVE_SUDO = '  if sudo -n true 2>/dev/null && sudo -n nft --version >/dev/null 2>&1; then'
REPROBE = ('    out="$(probe_origdst)"; rc=$?\n'
           '    [[ "$rc" == 0 ]] \\\n'
           '      || fail "自有表建好了但 SO_ORIGINAL_DST 仍拿不到($out) —— 前提不成立, 不继续碰运气"')
OWNED = '    CT_OWNED=1'
NOSUDO_FAIL = ('  fail "本 netns 缺 conntrack, 且没有免密 sudo/nft, 建不起前提'
               '(不跳过: 跳过等于零覆盖)"')
CI_GATE = ('if [[ "${GITHUB_ACTIONS:-}" == "true" && "$CT_OWNED" != 1 ]]; then\n'
           '  fail "CI 上没能建立本轮自有 conntrack 表(首探 $CT_FIRST) '
           '—— 不接受退回依赖外部状态的 no-op"\nfi')
CLEANUP_CALL = "\n  drop_conntrack_table\n"
DEL_OWN = '  sudo -n nft delete table inet "$NFT_TABLE" 2>/dev/null'
REPROBE_DIAG = '  echo "  再探 ORIGDST: rc=$rc $out" >&2'
MOCK_ALIVE = ('    if kill -0 "$p" 2>/dev/null; then echo "  mock ${names[$i]} pid=$p 存活" >&2\n'
              '    else                              echo "  mock ${names[$i]} pid=$p **已退出**" >&2; fi')
DIAG_CALL = '  if [[ ! -s "$LOGA" || ! -s "$LOGB" || ! -s "$LOGD" ]]; then diag_empty_exits; fi'
RETRY = ('  python3 "$HERE/sni_client.py" 127.0.0.1 18443 "$sni"\n'
         '  for _ in $(seq 1 30); do grep -q "^${sni}:" "$log" 2>/dev/null '
         '&& { note "  $sni → $name ✓"; return 0; }; sleep 0.1; done\n'
         '  if [[ ! -s "$LOGA" || ! -s "$LOGB" || ! -s "$LOGD" ]]; then diag_empty_exits; fi')

# (标签, 编辑列表, 模式, 期望)
#   own  → 期望是"正控里必须转红的那几格"
#   ci   → 期望是"该硬失败的那一条不见了"
#   stray→ 期望是"跑完 netns 里留下了残留表"
MUTATIONS = [
    ("① 恢复「首探 ok 就 no-op」(PR #56 那次红的形态)",
     [(CASE_BOTH, CASE_NOOP, 1)], "own", {"①", "③"}),
    ("② 摘掉自有表创建(权限拿得到却不建)",
     [(HAVE_SUDO, "  if false; then", 1)], "own", {"①", "②"}),
    ("③ 摘掉二次探针(让「建了没生效」冒充已准备好)",
     [(REPROBE, '    out="(未探)"; rc=0', 1)], "own", {"④"}),
    ("④ 提前删掉自有表(建了又不留住)",
     [(OWNED, '    sudo -n nft delete table inet "$t" 2>/dev/null\n    CT_OWNED=1', 1)],
     "own", {"③"}),
    ("⑤ 摘掉清理(临时表留在 netns 里)",
     [(CLEANUP_CALL, "\n", 1)], "stray", None),
    ("⑥ CI 建表失败后退回 no-op(把权威环境的硬门降级)",
     [(CI_GATE, ":", 1)], "ci", None),
    ("⑦ 无 sudo+ENOENT 改成 return 0(零覆盖披着绿灯出场)",
     [(NOSUDO_FAIL, '  note "缺 conntrack 又没权限, 那就算了"; return 0', 1)], "own", {"⑥"}),
    ("⑧ 失败后自动重试用例(把第一次失败洗掉)",
     [(DIAG_CALL, RETRY, 1)], "own", {"⑨"}),
    ("⑨ 摘掉失败时的二次 ORIGDST 探针",
     [(REPROBE_DIAG, "  :", 1)], "own", {"⑨"}),
    ("⑩ 摘掉 mock PID 存活",
     [(MOCK_ALIVE, "    :", 1)], "own", {"⑨"}),
    ("⑪ 清理改成 flush ruleset(越过自己那张表去动别人的)",
     [(DEL_OWN, "  sudo -n nft flush ruleset 2>/dev/null", 1)], "own", {"①"}),
    ("⑫ 只加一行无关注释(反向对照, 不该有新失败)",
     [("ensure_conntrack(){", "# (负控的空转对照, 不改变任何行为)\nensure_conntrack(){", 1)],
     "own", set()),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

if run(["sudo", "-n", "true"], timeout=120).returncode != 0:
    bad("需要免密 sudo —— 这支要真建 netns、真加载 nft 才有判据, 没有就等于没跑")
elif run(["sudo", "-n", "nft", "--version"], timeout=120).returncode != 0:
    bad("sudo 下调不到 nft —— 这支要真加载 nft 才有判据, 没有就等于没跑")
if FAIL[0]:
    print("-" * 62)
    print("functional-conntrack-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

wd = tmpguard.mkdtemp(prefix="pdg-fnct-negctl.")
try:
    # tests/.bin 里的钉死版 mihomo 跟着一起复制过去 —— 干净 netns 里只有 lo, 下不了东西,
    # 而每格都要真起一次 mihomo。先在正式树上备一次(gitignore 里的共享缓存), 之后零下载。
    run(["bash", str(ROOT / "tests/prepare-mihomo.sh")], timeout=600)
    for sub in ("tests", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True)
    script = Path(wd) / "tests/functional-test.sh"
    owner = Path(wd) / "tests/negctl/functional-conntrack-ownership.py"
    pristine = script.read_text(encoding="utf-8")
    if not (Path(wd) / "tests/.bin/mihomo").exists():
        bad("副本里没有钉死版 mihomo, 后面每一格都无从判断")
        raise SystemExit(1)
    SYS = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    PATH_BIN = "%s:%s" % (Path(wd) / "tests/.bin", SYS)
    nosudo = Path(wd) / "nosudo"
    nosudo.mkdir()
    (nosudo / "sudo").write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    (nosudo / "sudo").chmod(0o755)
    PATH_NOSUDO = "%s:%s" % (nosudo, PATH_BIN)
    EXT = "pdgext%d" % os.getpid()

    def own_cells():
        """把当前(可能已改坏的)夹具喂给正控, 返回转红的格号集合。"""
        r = run(["python3", str(owner)], timeout=900)
        return cells(r.stdout + r.stderr), (r.stdout + r.stderr)

    def plain(tag, *, external, path, ga=False):
        ns = "pdgneg%d%s" % (os.getpid(), tag)
        with Netns(ns) as n:
            if external:
                n.add_external_ct(EXT)
            env = {"PATH": path}
            if ga:
                env["GITHUB_ACTIONS"] = "true"
            r = n.exec(["bash", str(script)], env_kv=env)
            return failures(r.stdout + r.stderr), n.stray_tables(), r.returncode

    # ── 基线: 官方夹具喂给正控必须全绿; 直跑也必须绿且零残留 ────────────────
    base_cells, base_out = own_cells()
    if not base_cells:
        ok("基线绿(正控驱动): 官方夹具喂给 ownership 正控, 12 格无一转红")
    else:
        bad("基线就不绿(正控 %s 转红), 后面每一格都无从判断:" % sorted(base_cells))
        for l in base_out.splitlines():
            if l.startswith("[FAIL]"):
                print("       " + l[:132])
        raise SystemExit(1)

    base_fs, base_stray, base_rc = plain("b", external=False, path=PATH_BIN)
    if base_rc == 0 and not base_fs and not base_stray:
        ok("基线绿(直跑): 官方夹具在干净 netns 里自建前提并通过, 且没留下自有表")
    else:
        bad("直跑基线不绿(rc=%s, %d 条失败, %d 张残留), 后面每一格都无从判断"
            % (base_rc, len(base_fs), len(base_stray)))
        for f in sorted(base_fs)[:4]:
            print("       " + f[:132])
        raise SystemExit(1)

    # CI 硬门的基线: 权威环境 + 拿不到权限 → 必须具名硬失败
    ci_fs, _s, ci_rc = plain("c", external=True, path=PATH_NOSUDO, ga=True)
    ci_named = [f for f in ci_fs if "CI 上没能建立本轮自有 conntrack 表" in f]
    if ci_rc != 0 and ci_named:
        ok("基线绿(CI 硬门): GITHUB_ACTIONS=true 且建不成自有表 → 具名硬失败, 不退回 no-op")
    else:
        bad("CI 硬门基线不成立(rc=%s, 具名 %d 条) —— ⑥ 无从判断" % (ci_rc, len(ci_named)))
        raise SystemExit(1)

    # ── 逐格改坏 ────────────────────────────────────────────────────────────
    for idx, (label, edits, mode, want) in enumerate(MUTATIONS):
        mutated, aborted = pristine, False
        for old, new, want_hits in edits:
            hits = mutated.count(old)
            if hits != want_hits:
                bad("%s → 锚点 %r 命中 %d 次, 预期 %d(改坏器没打在预期位置)"
                    % (label, re.sub(r"\s+", " ", old)[:44], hits, want_hits))
                aborted = True
                break
            mutated = mutated.replace(old, new, 1)
            # 校验"锚点被恰好消费掉一次", 不去数新内容出现几次: 删除型的改坏替换成的就是
            # 一个换行符, 全文有两百多个 —— 按新内容计数会把有效负控判成改坏器打偏。
            # 前缀插入型(⑫)的替换内容里本来就含着锚点, 所以要把它带回来一起算。
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
        if run(["bash", "-n", str(script)], timeout=120).returncode != 0:
            bad("%s → 改坏后语法不合法, 这条不算有效负控" % label)
            script.write_text(pristine, encoding="utf-8")
            continue

        try:
            if mode == "own":
                got, out = own_cells()
                added = got - base_cells
                if want == set():
                    # 反向对照: 什么都不该红
                    if added:
                        bad("%s → 竟然让正控 %s 转红, 判据在看噪声" % (label, sorted(added)))
                    else:
                        ok("%s → 正控 0 格转红(判据不看噪声)" % label)
                elif not added:
                    bad("%s → 锚点命中但正控**0 格转红**, 负控无效" % label)
                elif not want.issubset(got):
                    bad("%s → 转红的是 %s, 但预期的 %s 没红(红在别处不算抓住)"
                        % (label, sorted(got), sorted(want - got)))
                else:
                    ok("%s → 正控 %s 转红(预期 %s)" % (label, sorted(got), sorted(want)))
                    for l in out.splitlines():
                        if l.startswith("[FAIL] ") and l[7:8] in want:
                            print("       " + l[:132])
                            break

            elif mode == "stray":
                _fs, stray, _rc = plain(str(idx), external=False, path=PATH_BIN)
                # 这一格的牙不在失败集合上: 摘掉清理并不影响用例通过, 变化只体现在现场。
                if stray:
                    ok("%s → 残留守卫具名报出 %d 张自有表: %s" % (label, len(stray), stray[0][:56]))
                else:
                    bad("%s → 清理都摘了却**没留下残留**, 残留守卫无效" % label)

            elif mode == "ci":
                fs, _s, rc = plain(str(idx), external=True, path=PATH_NOSUDO, ga=True)
                named = [f for f in fs if "CI 上没能建立本轮自有 conntrack 表" in f]
                # 这一格是反过来的: 基线**必须红**, 改坏后那条硬门消失就绿了。
                if rc == 0 and not named:
                    ok("%s → 硬门一摘, 权威环境下的 no-op 就悄悄放行了(基线红/改坏后绿)"
                       % label)
                else:
                    bad("%s → 摘了 CI 硬门却仍然红(rc=%s, 具名 %d 条), 这条硬门不是它在挡"
                        % (label, rc, len(named)))
        finally:
            script.write_text(pristine, encoding="utf-8")
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
    ok("正式树未被污染: functional-test.sh / origdst_probe.py / ownership 正控 三者 "
       "sha256 与 mode 均一致")

print("-" * 62)
print("functional-conntrack-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""CI 里 mosdns 官方二进制**每 run 每架构只准取件一次**, 之后靠本次 workflow 的 artifact 扇出。

由来是 exact-head run 33244114858: 它 30/30 全绿, 但「准备钉死版 mosdns」这一步在日志里
写着 `[*] 下载钉死版 mosdns v5.3.4 (amd64)…` —— 真的去 GitHub Release 拉了。而 e2e 是
**matrix**, 每格一个独立容器, 于是「备在 job 层」恰恰就是「每个用例一次」: 21 格 = 21 次。
连同 e2e-rescue-lock-ios, 官方下载从 5 次涨到 27 次。把下载从夹具挪到 job 步骤, 一次都没减少。

这一支按 job / step / needs / uses / 命令内容建立结构判据, 不数字符串:

  ① 官方取件入口每架构只有一个 producer;
  ② matrix 消费者不许自己调 prepare-mosdns.sh;
  ③ 消费者里不许有 curl/wget/Release URL 这类公网回退;
  ④ 每个消费者都要 needs 到 producer, 并 download-artifact;
  ⑤ 消费者拿到 artifact 后要按 lib/versions.sh **自己重算**摘要与版本, 不认服务端摘要;
  ⑥ artifact 名字要绑版本 + 架构 + 摘要前缀, 且由钉值生成而不是再写死一份;
  ⑦ 保留期取平台允许的最短值(1 天);
  ⑧ action 按仓库既有惯例钉定, 不许浮动引用;
  ⑨ producer 取件后要走生产判据 pdg_mosdns_binary_ok 复核;
  ⑩ caddy 与升级类 E2E 的离线镜像(mihomo 官方归档: 现钉值 + 冻结桥接钉的那份)走同一个 producer:
     producer 取件并写进 manifest, 要它们的 job 在用例之前用各自的消费者脚本复核, 消费者脚本
     不联网、不 SKIP、自己按仓库钉值重算; 测试侧的解析器在严格模式下不现场下载。
     由来: 2026-11-08 run 42482967890 —— lint 的 LAN 回滚负控每格现场 curl caddy, 三格没拿到就断了
     整条串行链; 升级类 E2E 的「旧版→桥接」一跳每次现场 curl 桥接钉的 mihomo, 下载失败就回滚。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CI = os.path.join(ROOT, ".github/workflows/ci.yml")
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


try:
    import yaml
except ImportError:
    print("[FAIL] 缺 pyyaml —— 这一支必须真解析 workflow, 不做退化的字符串计数。"
          "装一份: sudo apt-get install -y python3-yaml")
    sys.exit(1)

D = yaml.safe_load(open(CI, encoding="utf-8"))
JOBS = D["jobs"]
TEXT = open(CI, encoding="utf-8").read()
PRODUCER = "prepare-mosdns-fixture"
# 官方 Release 的取件动作长什么样: 仓库里的取件入口脚本, 或直接拉 Release 资产。
# 以前只认 mosdns 那两种形态 —— mihomo / 旧版 mosdns / caddy / 桥接 mihomo 的取件哪怕
# 挪进了消费者 job, 这一格也看不见。
FETCH = re.compile(r"\bprepare-(?:mosdns|mihomo|mosdns-legacy|mihomo-bridge|caddy)\.sh\b"
                   r"|releases/download|mosdns-linux-\w+\.zip")
NET = re.compile(r"\bcurl\b|\bwget\b|releases/download")


def code(text):
    """去掉 shell / YAML 的整行与行尾注释。

    这几格判的是"代码里有没有做某件事", 而注释里恰恰会**写明不做那件事**
    (「不用 actions/cache」「没有 curl 回退」「无 token」)。不去注释就会把说明文字
    当成违规 —— 第一版这一支自己踩了五次。
    """
    out = []
    for ln in text.splitlines():
        t = ln.split("#", 1)[0] if ln.lstrip().startswith("#") else \
            (ln.split(" #", 1)[0] if " #" in ln else ln)
        out.append(t)
    return "\n".join(out)


def steps(j):
    return JOBS[j].get("steps") or []


def inst(j):
    mx = ((JOBS[j].get("strategy") or {}).get("matrix") or {})
    if not mx:
        return 1
    if "include" in mx:
        return len(mx["include"])
    n = 1
    for k, v in mx.items():
        if isinstance(v, list):
            n *= len(v)
    return n


def runs(j):
    return [(i, s.get("name") or "", str(s.get("run") or ""))
            for i, s in enumerate(steps(j), 1)]


print("══ 1. 官方取件入口: 每架构恰好一个 producer ══")
fetchers = {}
for j in JOBS:
    hit = [(i, n) for i, n, r in runs(j) if FETCH.search(r)]
    if hit:
        fetchers[j] = (hit, inst(j))
for j, (hit, n) in sorted(fetchers.items()):
    print("       %-24s ×%-2d  step %s" % (j, n, [h[0] for h in hit]))
total = sum(n * len(h) for j, (h, n) in fetchers.items())
(ok if list(fetchers) == [PRODUCER] else
 bad)("只有 %s 一个 job 去官方取件(实得 %r)" % (PRODUCER, sorted(fetchers)))
(ok if total <= 2 else
 bad)("整个 run 的官方取件次数 ≤ 每架构一次(实得 %d 次)" % total)
if PRODUCER in JOBS:
    mx = ((JOBS[PRODUCER].get("strategy") or {}).get("matrix") or {})
    arches = mx.get("arch") or []
    (ok if arches else bad)("producer 按架构建 matrix(实得 %r)" % (arches,))
    (ok if len(arches) == len(set(arches)) else bad)("每种架构只有一格, 没有重复 producer")
else:
    bad("workflow 里没有 %s 这个 job" % PRODUCER)

print()
print("══ 2/3. 消费者: 不自己取件, 也没有公网回退 ══")
consumers = [j for j in JOBS if j != PRODUCER and
             any("mosdns" in r or "mosdns" in n for _, n, r in runs(j))]
for j in sorted(consumers):
    self_fetch = [i for i, n, r in runs(j) if FETCH.search(r)]
    (ok if not self_fetch else
     bad)("%s 不自己调 prepare-mosdns.sh / 拉 Release(实得 step %r)" % (j, self_fetch))
    netty = [(i, n) for i, n, r in runs(j)
             if NET.search(r) and re.search(r"mosdns", r, re.I)]
    (ok if not netty else
     bad)("%s 的 mosdns 相关步骤里没有 curl/wget/Release 回退(实得 %r)" % (j, netty))

print()
print("══ 4. 消费者依赖 producer 并下载 artifact ══")
for j in sorted(consumers):
    need = JOBS[j].get("needs")
    need = [need] if isinstance(need, str) else (need or [])
    (ok if PRODUCER in need else bad)("%s 的 needs 含 %s(实得 %r)" % (j, PRODUCER, need))
    dl = [s for s in steps(j) if "download-artifact" in str(s.get("uses") or "")]
    (ok if dl else bad)("%s 有 download-artifact 步骤" % j)

print()
print("══ 5. 消费者自己重算摘要与版本, 不认服务端摘要 ══")
INSTALLER = "tests/install-mosdns-artifact.sh"
(ok if os.path.exists(os.path.join(ROOT, INSTALLER)) else
 bad)("有 %s(消费者侧统一校验入口)" % INSTALLER)
if os.path.exists(os.path.join(ROOT, INSTALLER)):
    src = open(os.path.join(ROOT, INSTALLER), encoding="utf-8").read()
    (ok if "sha256sum" in src else bad)("消费者自己算 sha256(不认 artifact 服务端摘要)")
    (ok if "lib/versions.sh" in src else bad)("期望值从当前 checkout 的 lib/versions.sh 读")
    (ok if "pdg_mosdns_binary_ok" in src else bad)("消费者也走生产判据复核")
    (ok if re.search(r"install\s+-m\s*755", src) else bad)("以 mode 755 安装")
    # 版本这一层用真二进制造不出反例(SHA 对得上的文件不可能自报别的版本), 所以它的守卫
    # 只能是结构判据 —— 少了这条, 把版本比对整段摘掉不会有任何一格转红(负控④量到 0 条)。
    cmp_line = [ln for ln in code(src).splitlines()
                if "==" in ln and "got_ver" in ln and "MOSDNS_VER" in ln]
    (ok if cmp_line else
     bad)("消费者**比较**自报版本与钉值(不是只在失败提示里提到这两个名字)")
    (ok if re.search(r'want_sha|PDG_SHA256\[mosdns-bin-', src) else
     bad)("消费者拿 lib/versions.sh 的钉值当权威(而不是 manifest)")
    (ok if not NET.search(code(src)) else bad)("消费者安装脚本里没有任何联网动作")
    (ok if "SKIP" not in code(src) else bad)("不合格时硬失败, 不 SKIP")
for j in sorted(consumers):
    uses_installer = any(INSTALLER in r for _, _, r in runs(j))
    (ok if uses_installer else bad)("%s 用统一的 %s 做二次校验" % (j, INSTALLER))

print()
print("══ 6/7. artifact 名字与保留期 ══")
NAMER = "tests/mosdns-artifact-name.sh"
(ok if os.path.exists(os.path.join(ROOT, NAMER)) else
 bad)("有 %s —— 名字由钉值生成, 不再维护第二份硬编码" % NAMER)
if os.path.exists(os.path.join(ROOT, NAMER)):
    ns = open(os.path.join(ROOT, NAMER), encoding="utf-8").read()
    (ok if "lib/versions.sh" in ns else bad)("名字生成器读 lib/versions.sh")
    for part, why in (("MOSDNS_VER", "版本"), ("arch", "架构"), ("sha", "摘要前缀")):
        (ok if re.search(part, ns, re.I) else bad)("名字含%s" % why)
    (ok if not re.search(r'v[0-9]+\.[0-9]+\.[0-9]+', code(ns)) else
     bad)("名字生成器里没有硬编码的版本号")
up = [(j, s) for j in JOBS for s in steps(j) if "upload-artifact" in str(s.get("uses") or "")]
(ok if len(up) == 1 else bad)("只有一处 upload-artifact(实得 %d)" % len(up))
for j, s in up:
    w = s.get("with") or {}
    (ok if str(w.get("retention-days")) == "1" else
     bad)("保留期为最短的 1 天(实得 %r)" % w.get("retention-days"))
    (ok if "${{" in str(w.get("name") or "") else
     bad)("artifact 名字是求值出来的而不是写死(实得 %r)" % w.get("name"))

print()
print("══ 8. action 供应链: 按仓库惯例钉定, 不许浮动 ══")
uses = sorted({str(s.get("uses")) for j in JOBS for s in steps(j) if s.get("uses")})
conv = re.compile(r"^actions/[\w-]+@(v\d+|[0-9a-f]{40})$")
for u in uses:
    print("       %s" % u)
    (ok if conv.match(u) else bad)("%s 钉定合规(不许 @main/@master/无 ref)" % u)
(ok if not any(re.search(r"@(main|master|latest)$", u) for u in uses) else
 bad)("没有浮动引用 @main/@master/@latest")
(ok if not any("actions/cache" in u for u in uses) else
 bad)("没有任何 uses: actions/cache(跨 run 缓存被禁)")

print()
print("══ 9. producer 的四层校验 ══")
if PRODUCER in JOBS:
    body = "\n".join(r for _, _, r in runs(PRODUCER))
    for pat, why in ((r"prepare-mosdns\.sh", "调既有取件流程(它自己核归档 SHA 与自报版本)"),
                     (r"sha256sum", "校验最终二进制 SHA"),
                     (r"pdg_mosdns_binary_ok", "走生产判据再核一次"),
                     (r"manifest", "生成 manifest")):
        (ok if re.search(pat, body, re.I) else bad)("producer %s" % why)
    (ok if re.search(r"rm -f .*mosdns|隔离", body) else
     bad)("producer 先移除 runner 上偶然存在的 mosdns(不把已有状态当隐式输入)")
    (ok if not re.search(r"token|secrets\.", code(body), re.I) else
     bad)("manifest / producer 步骤里不出现 token 或 secrets")

print()
print("══ 10. caddy 与升级类 E2E 离线镜像: 同一个 producer, 消费者自己复核 ══")


def src_of(rel):
    p = os.path.join(ROOT, rel)
    return open(p, encoding="utf-8").read() if os.path.exists(p) else ""


def job_text(j):
    return yaml.safe_dump(JOBS[j], allow_unicode=True)


if PRODUCER in JOBS:
    fetch_body = "\n".join(r for _, _, r in runs(PRODUCER) if FETCH.search(r))
    all_body = "\n".join(r for _, _, r in runs(PRODUCER))
    for pat, why in (
            (r"prepare-caddy\.sh", "取 caddy 官方归档(PDG_TEST_CADDY_ARCHIVE_DIR 原样留给消费者)"),
            (r"PDG_TEST_CADDY_ARCHIVE_DIR=", "caddy 归档原样进 artifact(消费者要自己核归档 SHA)"),
            (r"prepare-mihomo-bridge\.sh", "取冻结桥接钉的 mihomo 归档"),
            (r"PDG_TEST_MIRROR_DIR=\S*\s*\\?\s*\n?\s*bash tests/prepare-mihomo\.sh|"
             r"PDG_TEST_MIRROR_DIR=[^\n]*\n[^\n]*prepare-mihomo\.sh",
             "现钉值 mihomo 的官方归档由**同一次**取件原样留下(不为它再取一次)")):
        (ok if re.search(pat, fetch_body) else bad)("producer %s" % why)
    for pat, why in ((r"PDG_SHA256\[caddy-", "按 lib/versions.sh 核 caddy 归档"),
                     (r"caddy_archive_sha256", "manifest 记 caddy 归档摘要"),
                     (r"caddy_binary_sha256", "manifest 记 caddy 解包产物摘要(供消费者对账)"),
                     (r"mihomo-bridge-bin-", "按 tests/legacy-pins.sh 核桥接归档的解压产物"),
                     (r"release_mirror", "manifest 记离线镜像的每一份归档")):
        (ok if re.search(pat, all_body) else bad)("producer %s" % why)

# 要 caddy 的用例 / 要离线镜像的用例。前者只按 run 判(lint 里逐支调用); 后者还要看 matrix
# 与串行清单(env) —— 用例名不一定出现在 run 里。
CADDY_TESTS = ("test-lan-location-live.sh", "test-lan-rollback-convergence.sh",
               "lan-rollback-convergence-negative-controls.py")
MIRROR_TESTS = ("e2e-upgrade-from-release.sh", "e2e-rescue-migration-lock.sh")
SIDE = (("caddy", "tests/install-caddy-artifact.sh", CADDY_TESTS),
        ("离线镜像", "tests/install-release-mirror-artifact.sh", MIRROR_TESTS))

for what, installer, tests_ in SIDE:
    if what == "caddy":
        users = [j for j in JOBS if any(t in r for _, _, r in runs(j) for t in tests_)]
    else:
        users = [j for j in JOBS if j != PRODUCER and any(t in job_text(j) for t in tests_)]
    (ok if users else bad)("%s: 现推出要它的 job(实得 %r)" % (what, sorted(users)))
    for j in sorted(users):
        need = JOBS[j].get("needs")
        need = [need] if isinstance(need, str) else (need or [])
        (ok if PRODUCER in need else bad)("%s: %s 的 needs 含 %s" % (what, j, PRODUCER))
        dl = [i for i, s in enumerate(steps(j), 1) if "download-artifact" in str(s.get("uses") or "")]
        ins = [i for i, n, r in runs(j) if installer in r]
        if what == "caddy":
            use = [i for i, n, r in runs(j) if any(t in r for t in tests_)]
        else:
            use = [i for i, s in enumerate(steps(j), 1)
                   if re.search(r"bash tests/|e2e-serial-hermetic", str(s.get("run") or ""))
                   and (any(t in yaml.safe_dump(s, allow_unicode=True) for t in tests_)
                        or "matrix.script" in str(s.get("run") or "")
                        or "e2e-serial-hermetic" in str(s.get("run") or ""))]
        if not (dl and ins and use):
            bad("%s: %s 缺 download-artifact(%r) / %s(%r) / 用例步骤(%r)"
                % (what, j, dl, installer, ins, use))
            continue
        (ok if dl[0] < ins[0] < min(use) else
         bad)("%s: %s 的顺序是 下载 artifact(step %d) → %s(step %d) → 用例(step %d)"
              % (what, j, dl[0], installer.split("/")[-1], ins[0], min(use)))
        netty = [i for i, n, r in runs(j) if i in ins and NET.search(code(r))]
        (ok if not netty else bad)("%s: %s 的复核步骤里没有 curl/wget/Release 回退" % (what, j))

INST_RULES = {
    "tests/install-caddy-artifact.sh": (
        (r"sha256sum", "自己算摘要(不认 artifact 服务端摘要)"),
        (r"lib/versions\.sh", "期望值从当前 checkout 的 lib/versions.sh 读"),
        (r"PDG_SHA256\[caddy-", "拿仓库钉值当权威(而不是 manifest)"),
        (r"manifest\.json", "manifest 交叉核对"),
        (r"==\s*\"\$CADDY_VER\"", "**比较**自报版本与钉值"),
        (r"install\s+-m\s*755", "以 mode 755 安装")),
    "tests/install-release-mirror-artifact.sh": (
        (r"sha256sum", "自己算摘要(不认 artifact 服务端摘要)"),
        (r"lib/versions\.sh", "现钉值从当前 checkout 的 lib/versions.sh 读"),
        (r"legacy-pins\.sh", "桥接钉值从 tests/legacy-pins.sh 读"),
        (r"mihomo-bin-\$arch", "核现钉值归档的解压产物"),
        (r"mihomo-bridge-bin-\$arch", "核桥接归档的解压产物"),
        (r"manifest\.json", "manifest 交叉核对"),
        (r"==\s*\"\$ver\"", "**比较**自报版本与钉的版本")),
}
for rel, rules in INST_RULES.items():
    src = src_of(rel)
    if not src:
        bad("缺 %s" % rel)
        continue
    for pat, why in rules:
        (ok if re.search(pat, code(src)) else bad)("%s: %s" % (rel.split("/")[-1], why))
    (ok if not NET.search(code(src)) else bad)("%s: 没有任何联网动作" % rel.split("/")[-1])
    (ok if "SKIP" not in code(src) else bad)("%s: 不合格时硬失败, 不 SKIP" % rel.split("/")[-1])

# 测试侧: caddy 解析器在严格模式下先停, 再谈取件; LAN 那几支不再自己 curl。
cf = code(src_of("tests/caddy-fixture.sh"))
i_strict = cf.find("_pdg_test_caddy_strict; then")
i_fetch = cf.find("prepare-caddy.sh")
(ok if 0 <= i_strict < i_fetch else
 bad)("tests/caddy-fixture.sh: 严格模式的出口排在唯一取件入口之前(strict=%d fetch=%d)" % (i_strict, i_fetch))
(ok if not NET.search(cf) else bad)("tests/caddy-fixture.sh 自己不联网(取件只走 prepare-caddy.sh)")
for rel in ("tests/lan-fixture.sh", "tests/test-lan-location-live.sh"):
    c = code(src_of(rel))
    (ok if c and "pdg_test_caddy" in c else bad)("%s 经 tests/caddy-fixture.sh 取 caddy" % rel)
    (ok if c and not re.search(r"\bcurl\b[^\n]*caddy|caddyserver/caddy/releases", c) else
     bad)("%s 不再自己现场下载 caddy" % rel)
# 测试侧: 两支升级类 E2E 在第一次调入口之前把离线镜像立起来。
for rel in ("tests/e2e-upgrade-from-release.sh", "tests/e2e-rescue-migration-lock.sh"):
    c = code(src_of(rel))
    i_m = c.find('e2e_release_mirror "$BRIDGE_SHA"')
    i_u = min([x for x in (c.find('bash "$FLOW"'), c.find("pdg update")) if x >= 0] or [-1])
    (ok if 0 <= i_m < i_u else
     bad)("%s: 离线镜像在第一次调入口/更新器之前就位(mirror=%d first=%d)" % (rel, i_m, i_u))

print("-" * 62)
print("test-ci-mosdns-topology.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

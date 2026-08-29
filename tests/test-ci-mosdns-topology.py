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
  ⑨ producer 取件后要走生产判据 pdg_mosdns_binary_ok 复核。
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
# 官方 Release 的取件动作长什么样(两种既有形态)
FETCH = re.compile(r"prepare-mosdns\.sh|mosdns-linux-\w+\.zip")
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

print("-" * 62)
print("test-ci-mosdns-topology.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

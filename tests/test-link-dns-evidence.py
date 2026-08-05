#!/usr/bin/env python3
"""6.1B 阶段 3(**已按任务书第五节停止**): mosdns 的 DNS 证据与 API 暴露面。

停止的原因不是"做不出来", 而是**做出来会把用户的浏览域名摊开**。在钉定的官方
mosdns v5.3.4 上实测:

    $ curl http://127.0.0.1:19099/
    Available api urls:
      GET  /debug/pprof/cmdline      ← 泄露完整命令行
      GET  /debug/pprof/profile|trace|*
      GET  /metrics                  ← 我们要的只有这一条
      GET  /plugins/lazy_cache/dump  ← **导出整个 DNS 缓存**
      GET  /plugins/lazy_cache/flush ← GET 带副作用, 清空缓存
      POST /plugins/lazy_cache/load_dump ← **无认证地投喂缓存内容**

`dump` 拿到的 gzip 解开就是明文域名(实测 secret-bank-login.example、
private-medical-site.example 各出现 3 次)。也就是说, 一旦开了 `api.http`,
任何能连上那个端口的本地进程都能:
  · 读走网关上所有人最近解析过的域名 —— 正是 6.1B 承诺绝不记录的东西;
  · 用 load_dump 往解析器里灌任意应答, 等于无认证的 DNS 缓存投毒。

而 `api:` 段**只接受 `http` 一个键**(metrics_only / plugins_api / auth 之类
一律 unmarshal 失败), 没有任何办法只开 /metrics 而关掉插件端点; 不配 api.http
则一个端口都不监听。所以"绑定回环"不构成缓解 —— 网关上跑着 mihomo 透明代理和
Bot, 任何一个本地 SSRF 都够得着。

这支测试因此是一道**闸门**, 不是永久禁令:
  · 只要生产配置里没开 api.http, 它就确认现状安全;
  · 一旦有人开了, 它会去真的问那个二进制"你都挂了哪些路径", 只有在危险端点确实
    消失(比如换了修好这个问题的 mosdns 版本)之后才放行。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS_N = [0]
FAIL_N = [0]

DANGEROUS = ("/plugins/", "load_dump", "/dump", "/flush")


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def skip(m):
    print("[SKIP] %s" % m)


cfg = (ROOT / "deploy/mosdns/config.yaml").read_text(encoding="utf-8")
api_on = re.search(r"^api:", cfg, re.M) is not None

print("── 1. 生产 mosdns 配置当前的 API 暴露面 ──")
(ok if not api_on else bad)(
    "config.yaml 里没有开 api.http(阶段 3 已停止, 见文件头说明)"
    if not api_on else "config.yaml 开了 api —— 必须先证明危险端点已消失")
(ok if "19099" not in cfg else bad)("配置里没有 19099")

print()
print("── 2. 防火墙没有为 19099 开口 ──")
nft = (ROOT / "deploy/firewall/nftables-mihomo.conf").read_text(encoding="utf-8")
(ok if "19099" not in nft else bad)("nft 模板里没有 19099")

print()
print("── 3. log level 仍是 warn, 没有启用 query_summary ──")
m = re.search(r"^\s*level:\s*(\w+)", cfg, re.M)
(ok if m and m.group(1) == "warn" else bad)(
    "mosdns log.level = %s(必须是 warn)" % (m.group(1) if m else "?"))
(ok if "query_summary" not in cfg else bad)(
    "配置里没有 query_summary(它会把完整客户端 IP 与 token 写进日志)")

print()
print("── 4. 第 6.5 层仍是 NOT_OBSERVED, 没有伪造 DNS 证据 ──")
import linkstat as L  # noqa: E402
fs = L.collect(platform="android")
l65 = [f for f in fs if f["layer"] == 6.5]
(ok if l65 and all(f["status"] == L.NOT_OBSERVED for f in l65) else bad)(
    "第 6.5 层是 NOT_OBSERVED(实得 %s)" % [(f["status"], f["code"]) for f in l65])
(ok if not any("PASS" == f["status"] for f in fs if f["layer"] == 6.5) else bad)(
    "没有把「没观察到」说成 PASS")

print()
print("── 5. 闸门: 真去问二进制它挂了哪些路径 ──")
mosdns = os.environ.get("PDG_TEST_MOSDNS", "/usr/local/bin/mosdns")
if not api_on:
    if not (os.path.exists(mosdns) and os.access(mosdns, os.X_OK)):
        skip("没装钉定版 mosdns —— 端点清单未复核(现状安全由第 1 节保证)")
    else:
        # 现状虽然安全, 仍然把"为什么停"这件事复核一遍: 端点清单必须与文件头一致。
        box = tmpguard.mkdtemp(prefix="mosapi.")
        try:
            y = os.path.join(box, "c.yaml")
            open(y, "w").write(
                'log:\n  level: warn\napi:\n  http: "127.0.0.1:19099"\n'
                'plugins:\n'
                '  - tag: lazy_cache\n    type: cache\n    args: {size: 128}\n'
                '  - tag: entry\n    type: sequence\n'
                '    args:\n      - exec: $lazy_cache\n'
                '      - exec: black_hole 203.0.113.9\n'
                '  - tag: udp\n    type: udp_server\n'
                '    args: {entry: entry, listen: "127.0.0.1:15355"}\n')
            pr = subprocess.Popen([mosdns, "start", "-c", y],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(2.5)
            try:
                import urllib.request
                with urllib.request.urlopen("http://127.0.0.1:19099/", timeout=5) as r:
                    listing = r.read().decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                listing = ""
                skip("拿不到端点清单(%s)" % type(e).__name__)
            finally:
                pr.terminate(); pr.wait(timeout=10)
            if listing:
                hits = [d for d in DANGEROUS if d in listing]
                (ok if hits else bad)(
                    "复核: 钉定版确实暴露了危险端点 %s —— 这就是停止阶段 3 的依据"
                    % hits)
                (ok if "/metrics" in listing else bad)(
                    "同一个 API 上才有我们要的 /metrics(所以无法二选一)")
        finally:
            shutil.rmtree(box, ignore_errors=True)
else:
    # 有人开了 api —— 那就必须证明危险端点没了, 否则判红。
    if not (os.path.exists(mosdns) and os.access(mosdns, os.X_OK)):
        bad("配置开了 api 但拿不到 mosdns 二进制核实端点 —— 不能放行")
    else:
        bad("配置开了 api: 请先用本文件头描述的方法复核 /plugins/*/dump|flush|"
            "load_dump 是否已消失, 并把这段判据改成对应的新形态")

print()
print("── 6. CLI 的两步说明不许承诺收集不到的证据 ──")
sess = (ROOT / "deploy/bot/linksess.py").read_text(encoding="utf-8")
two = sess.split("_TWO_STEP = ")[1].split('"""')[1] if "_TWO_STEP = " in sess else ""
if not api_on:
    (ok if "暂不采集第 2 步的证据" in two else bad)(
        "阶段 3 未实施时, 两步说明必须明说第 2 步的证据当前暂不采集")
    (ok if "不代表正常" in two and "不代表故障" in two else bad)(
        "并明说这既不代表正常也不代表故障(否则用户会去修一个不存在的问题)")
    # 技术论证移到 README / ROADMAP: 用户面前摆一串内部名词, 既看不懂也无从处置。
    (ok if "路线图" in two or "ROADMAP" in two else bad)(
        "指向项目路线图, 让想深究的人找得到理由")
    (ok if "诊断依据是 DNS 查询计数" not in two else bad)(
        "不许说「诊断依据是 DNS 查询计数」—— 那个计数根本没启用")
    # 版本号从用户文案里撤到 docs/ROADMAP.md: CLI 只说"后续版本"并指路。事实本身仍要
    # 有人钉着 —— 钉在文档上, 而不是逼着每处文案都写版本号。
    (ok if "后续版本" in two and ("路线图" in two or "ROADMAP" in two) else bad)(
        "指明这一半留到后续版本, 并指向项目路线图")
    _rm = (ROOT / "docs/ROADMAP.md").read_text(encoding="utf-8")
    (ok if "6.2" in _rm else bad)("ROADMAP 里写明了移交 6.2")
else:
    (ok if "还收集不到第 2 步的证据" not in two else bad)(
        "阶段 3 若已实施, 反过来要把这句免责删掉")

print("─" * 46)
print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
if PASS_N[0] + FAIL_N[0] == 0:
    print("零断言 —— 判失败"); sys.exit(1)
sys.exit(1 if FAIL_N[0] else 0)

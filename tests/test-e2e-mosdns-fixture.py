#!/usr/bin/env python3
"""E2E 的"健康机器"夹具必须播种**真实钉定**的 mosdns 二进制, 不是只会打印版本号的 shell 桩。

exact-head CI 33235374627 里六支 E2E 红, 两条根因都落在这里:

  · e2e-install.sh 在 /usr/local/bin/mosdns 写了个 shell 桩(`case $1 in version) echo …`)。
    安装器旧短路只比自报版本, 桩就够用; 现在还要求 SHA256 等于官方钉值, 桩当然不符 →
    安装器进入下载分支 → 而这支同时把 curl 也打了桩 → ZIP 校验失败 → 整次装机 die。
  · 另外五支的夹具**根本不播种** mosdns(e2e-lib 还会主动删掉小于 1MB 的桩)。doctor 的
    check_mosdns_binary 于是判 fail, cmd_update 的自检门看到 1 项失败就整个回滚。

修的方向已经定了: **不放宽判据, 改夹具**。一台"装好的网关"按定义就有那个二进制;
夹具里没有它, 那份夹具本身就是假的 —— 它正是把这两个洞藏了这么久的原因。

这一支钉住夹具契约, 不碰生产判据。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


LIB = open(os.path.join(ROOT, "tests/e2e-lib.sh"), encoding="utf-8").read()
INST = open(os.path.join(ROOT, "tests/e2e-install.sh"), encoding="utf-8").read()
VERS = open(os.path.join(ROOT, "lib/versions.sh"), encoding="utf-8").read()
CI = open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8").read()


def body(src, name):
    m = re.search(r"\n%s\(\)\{(.*?)\n\}" % re.escape(name), src, re.S)
    return m.group(1) if m else ""


print("══ 1. 播种函数存在, 且播完要用生产判据复核 ══")
seed = body(LIB, "e2e_seed_mosdns_bin")
(ok if seed else bad)("e2e-lib.sh 里有 e2e_seed_mosdns_bin")
(ok if "pdg_mosdns_binary_ok" in seed else
 bad)("播种后用生产判据 pdg_mosdns_binary_ok 复核(版本与摘要同时命中)")
(ok if "prepare-mosdns.sh" in seed else
 bad)("取件走既有准备流程 tests/prepare-mosdns.sh(SHA256 已在那边校验, 不另立一套)")
# 夹具自己不许去改判据、不许绕过摘要
for wforb in ("PDG_TEST_MODE", "PDG_SKIP_SHA", "--no-verify", "sha256sum -c -"):
    (ok if wforb not in seed else bad)("播种函数里没有 %s 这类绕过" % wforb)

print()
print("══ 2. 健康夹具真的会调它 ══")
si = body(LIB, "e2e_seed_install")
(ok if "e2e_seed_mosdns_bin" in si else
 bad)("e2e_seed_install 播种 mosdns 二进制(一台装好的网关按定义就有它)")

print()
print("══ 3. e2e-install.sh 不再写 shell 假桩 ══")
stub = re.search(r"cat > /usr/local/bin/mosdns <<", INST)
(ok if not stub else
 bad)("e2e-install.sh 里没有 `cat > /usr/local/bin/mosdns` 这样的假桩")
(ok if "e2e_seed_mosdns_bin" in INST else
 bad)("e2e-install.sh 改用真实钉定二进制播种")
# 它仍然可以测"已有合法二进制时严格短路", 但不许重新教安装器接受假桩
(ok if "pdg_mosdns_is_version" not in INST else
 bad)("没有把安装器的判据换回只看自报版本")

print()
print("══ 4. 夹具不访问生产机、不改生产判据 ══")
for f in ("tests/e2e-lib.sh", "tests/e2e-install.sh", "tests/prepare-mosdns.sh"):
    txt = open(os.path.join(ROOT, f), encoding="utf-8").read()
    hits = [w for w in ("ts.net", "tailscale", "jp2", "@jp", "ssh ") if w in txt]
    (ok if not hits else bad)("%s 不碰生产机 / tailnet(实得 %r)" % (f, hits))
# 判据本体在 lib/versions.sh, 测试目录里不许出现第二份实现
impl = [f for f in os.listdir(os.path.join(ROOT, "tests"))
        if f.endswith((".sh", ".py")) and
        re.search(r"^pdg_mosdns_binary_ok\(\)\{", open(os.path.join(ROOT, "tests", f),
                  encoding="utf-8", errors="replace").read(), re.M)]
(ok if not impl else
 bad)("tests/ 下没有第二份 pdg_mosdns_binary_ok 实现(实得 %r)" % impl)

print()
print("══ 5. CI: 夹具靠 producer 的 artifact, 自己不取件 ══")
# 上一版这里要求"e2e job 里有 prepare-mosdns.sh 这一步" —— 那正是把官方下载放大到 28 次的
# 形态(e2e 是 matrix, 每格一个容器, "备在 job 层"就是"每个用例一次")。现在改成单次取件 +
# artifact 扇出, 判据跟着换: e2e job **不许**自己取件, 只许 needs 到 producer 并下载。
# 取件次数与 DAG 的完整守卫在 tests/test-ci-mosdns-topology.py, 这里只钉与夹具直接相关的两条。
m = re.search(r"\n  e2e:\n(.*?)\n  [a-z-]+:\n", CI, re.S)
(ok if m else bad)("抽得到 e2e job")
if m:
    (ok if "prepare-mosdns.sh" not in m.group(1) else
     bad)("e2e job **不再**自己调 prepare-mosdns.sh(那会按 matrix 格数放大官方下载)")
    (ok if "prepare-mosdns-fixture" in m.group(1) else
     bad)("e2e job needs 到 producer")
    (ok if "download-artifact" in m.group(1) else
     bad)("e2e job 用 download-artifact 取本次 run 的钉定二进制")
(ok if CI.count("prepare-mosdns.sh") == 1 else
 bad)("整份 workflow 里 prepare-mosdns.sh 只出现 1 次(唯一的取件入口)(实得 %d)"
      % CI.count("prepare-mosdns.sh"))

print()
print("══ 6. 真跑一次: 桩被拒, 真二进制被接受 ══")
import hashlib                                               # noqa: E402
import shutil                                                # noqa: E402
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard                                              # noqa: E402
W = tmpguard.mkdtemp(prefix="pdg-e2emos.")
pin = dict(re.findall(r'\[mosdns-bin-(\w+)\]="([0-9a-f]{64})"', VERS))
arch = subprocess.run(["dpkg", "--print-architecture"], capture_output=True,
                      text=True).stdout.strip() or "amd64"
mver = (re.search(r'^MOSDNS_VER="([^"]+)"', VERS, re.M) or [None, "v5.3.4"])[1]


def ask(path):
    """真调生产判据。"""
    sc = ('source "%s/lib/versions.sh"\n'
          'pdg_mosdns_binary_ok %s %s "%s"; echo "rc=$?"\n' % (ROOT, arch, mver, path))
    return subprocess.run(["bash", "-c", sc], capture_output=True, text=True).stdout.strip()


# ① 老的 shell 假桩
fake = os.path.join(W, "mosdns")
open(fake, "w").write('#!/bin/sh\ncase "$1" in version) echo "mosdns %s-0-gb732318";; esac\nexit 0\n' % mver)
os.chmod(fake, 0o755)
(ok if ask(fake).endswith("rc=1") else
 bad)("老的 shell 假桩被生产判据**拒绝**(实得 %r)" % ask(fake))
# 它确实"自报版本对得上" —— 证明拒绝的理由是内容而不是版本
v = subprocess.run([fake, "version"], capture_output=True, text=True).stdout
(ok if mver in v else bad)("假桩确实自报了正确版本(所以旧短路才会接受它)")

# ② 真实钉定二进制
real = "/usr/local/bin/mosdns"
if os.path.exists(real) and hashlib.sha256(open(real, "rb").read()).hexdigest() == pin.get(arch):
    (ok if ask(real).endswith("rc=0") else
     bad)("真实钉定二进制被生产判据**接受**(实得 %r)" % ask(real))
    ok("本机 %s 的 sha256 与 lib/versions.sh 的 %s 钉值相符" % (real, arch))
else:
    bad("本机没有钉死版 mosdns —— 「真二进制被接受」那一格未验(不是通过)。"
        "备一份: sudo bash tests/prepare-mosdns.sh")

print()
print("══ 7. 无残留 ══")
shutil.rmtree(W, ignore_errors=True)
(ok if not os.path.exists(W) else bad)("测试自建的临时目录已清")
import tempfile                                              # noqa: E402
_tmp = tempfile.gettempdir()          # 不写死 /tmp: 临时物卫生守卫按这条判
left = [d for d in os.listdir(_tmp) if d.startswith("pdg-e2emos.")]
(ok if not left else bad)("没有同前缀的临时残留(实得 %r)" % left)

print("-" * 62)
print("test-e2e-mosdns-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

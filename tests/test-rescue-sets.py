#!/usr/bin/env python3
"""两组清单的边界, 以及测试内核定位的唯一性。

一、恢复保护集 vs 安装/卸载全集
这两份清单长得像, 语义完全相反, 合成一份的话必然把一方拖坏:

  · `PDG_RESCUE_PROTECTED_MEMBERS` = 完整恢复旧快照时必须**保住**的最小救援通道。它刻意
    不含 pdgtx.py / cfgrestore.py 这些业务模块 —— 旧快照本来就该把业务核心换成旧的, 救援页
    随后按能力检测优雅降级("旧核心不支持")。往里加业务模块, "完整恢复"就恢复不了业务代码,
    而那正是用户按这个按钮的目的。
  · 安装/卸载全集 = 我们往机器上放过的一切, 卸载要一个不剩地收走。漏一项留下的是仍然有效的
    token 与 TLS 私钥。

关系: 保护集 ⊂ 安装全集; 安装全集**不**反过来决定保护范围。

二、钉死版 mihomo 的定位逻辑只能有一处(tests/mihomobin.py)。
各写一份的后果不是麻烦, 是**版本没人管**: `shutil.which("mihomo")` 捡到机器上任意一版就用,
而那些断言的全部意义就是"钉死版认不认这份配置"。
"""
import ast
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def sh(script):
    """在真实 lib/*.sh 上跑一段 bash, 拿到函数的真实输出(不解析源码猜)。"""
    return subprocess.run(
        ["bash", "-c", "source %s/lib/rescue.sh\n%s" % (ROOT, script)],
        capture_output=True, text=True, cwd=ROOT).stdout


# ── 1. 保护集: 仍是此前验收过的最小集合 ────────────────────────────────────
print("── 1. 恢复保护集 ──")
protected = [l for l in sh("pdg_rescue_protected").splitlines() if l.strip()]
EXPECT_PROTECTED = [
    "etc/privdns-gateway/rescue/token",
    "etc/privdns-gateway/rescue/cert.pem",
    "etc/privdns-gateway/rescue/key.pem",
    "opt/pdg-bot/rescue.py",
    "opt/pdg-bot/rescue_const.py",
    "opt/pdg-bot/rescue_cred.py",
    "opt/pdg-bot/breakglass.py",
    "opt/pdg-bot/rescue_nft.py",
    "opt/pdg-bot/rescue.sh",
    "etc/systemd/system/pdg-rescue.service",
    "etc/systemd/system/pdg-rescue.socket",
    "var/lib/privdns-gateway/rescue-state.json",
]
if sorted(protected) == sorted(EXPECT_PROTECTED):
    ok("保护集仍是此前验收的 %d 项最小集合(逐项比对, 不是数个数)" % len(EXPECT_PROTECTED))
else:
    bad("保护集变了: 多出 %r / 少了 %r"
        % (sorted(set(protected) - set(EXPECT_PROTECTED)),
           sorted(set(EXPECT_PROTECTED) - set(protected))))

# 业务模块**不许**因为卸载需要而混进保护集 —— 那会让完整恢复换不掉业务核心
BUSINESS = ["pdgtx.py", "cfgrestore.py", "emergency.py", "mihomorender.py", "sb2mihomo.py",
            "checks.py", "doctor.py", "report.py", "nftmerge.py", "nftscan.py", "cidrgen.py"]
leaked = [b for b in BUSINESS if any(p.endswith("/" + b) for p in protected)]
if not leaked:
    ok("业务模块一个都不在保护集里(旧快照仍能整体换掉业务核心, 随后按能力降级)")
else:
    bad("业务模块混进了保护集 → 完整恢复将换不掉它们: %s" % ", ".join(leaked))

# ── 2. 安装/卸载全集 ───────────────────────────────────────────────────────
print()
print("── 2. 安装/卸载全集 ──")
members = [l for l in sh("pdg_project_members").splitlines() if l.strip()]
if members:
    ok("安装全集可枚举(%d 项)" % len(members))
else:
    bad("pdg_project_members 没输出 —— 卸载将什么都删不掉")

# 模块部分必须**逐项**来自 10a-1 的运行模块真源, 不是第二份手写名单
man = open(os.path.join(ROOT, "lib/modules.sh"), encoding="utf-8").read()
m = re.search(r'PDG_RUNTIME_MODULES="([^"]*)"', man, re.S)
manifest = [ln.split()[1] for ln in m.group(1).splitlines() if ln.strip()] if m else []
missing = [n for n in manifest if ("opt/pdg-bot/" + n) not in members]
if manifest and not missing:
    ok("真源里 %d 个运行模块**逐项**都在卸载全集内" % len(manifest))
else:
    bad("卸载全集漏了运行模块: %s" % ", ".join(missing))

for need in ("etc/systemd/system/pdg-rescue.socket", "etc/systemd/system/pdg-rescue.service",
             "etc/privdns-gateway/rescue/token", "etc/privdns-gateway/rescue/key.pem",
             "etc/privdns-gateway/rescue/cert.pem",
             "var/lib/privdns-gateway/rescue-state.json"):
    if need not in members:
        bad("卸载全集缺: %s" % need)
        break
else:
    ok("unit / token / 私钥 / 证书 / 状态文件都在卸载全集内")

# ── 3. 两集合的关系 ────────────────────────────────────────────────────────
print()
print("── 3. 关系 ──")
if set(protected) <= set(members):
    ok("保护集 ⊂ 安装全集(保护的东西也是我们装的, 卸载时同样要收走)")
else:
    bad("保护集里有安装全集之外的项: %r" % sorted(set(protected) - set(members)))
if set(protected) != set(members):
    extra = sorted(set(members) - set(protected))
    ok("保护集 ≠ 卸载全集, 差 %d 项(卸载还要收走 %s 等业务模块)"
       % (len(extra), ", ".join(os.path.basename(x) for x in extra[:3])))
else:
    bad("两份清单被合成了一份 —— 语义不成立(见本文件开头)")

# 卸载清理必须走全集, 不是保护集
res = open(os.path.join(ROOT, "lib/rescue.sh"), encoding="utf-8").read()
body = res[res.index("pdg_rescue_cleanup(){"):]
if "pdg_project_members" in body and "pdg_rescue_protected" not in body:
    ok("卸载清理读的是安装全集(不是保护集)")
else:
    bad("卸载清理仍在用保护集当清单")

# ── 4. 救援闭包 = 真实入口算出来的那一份 ───────────────────────────────────
print()
print("── 4. 救援模块闭包 ──")
LOCAL = {}
for d in ("deploy/bot", "deploy/rescue"):
    for f in sorted(os.listdir(os.path.join(ROOT, d))):
        if f.endswith(".py"):
            LOCAL[f[:-3]] = os.path.join(ROOT, d, f)


def imports_of(path):
    out = set()
    for n in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if isinstance(n, ast.Import):
            out |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom) and n.module:
            out.add(n.module.split(".")[0])
        elif isinstance(n, ast.Call):
            fn = getattr(n.func, "id", "") or getattr(n.func, "attr", "")
            if fn in ("__import__", "_mod") and n.args and isinstance(n.args[0], ast.Constant):
                out.add(str(n.args[0].value))
    return {x for x in out if x in LOCAL}


seen, stack = set(), ["rescue", "breakglass", "rescue_cred"]
while stack:
    cur = stack.pop()
    if cur in seen:
        continue
    seen.add(cur)
    stack += list(imports_of(LOCAL[cur]) - seen)
# rescue_nft 不在 python 闭包里(它是 pdg.sh 开关防火墙用的注入器), 但少了它 enable/disable
# 就动不了放行 —— 所以闭包按"救援平面跑得起来"算, 要把它算进去。
want_closure = sorted(m + ".py" for m in seen) + ["rescue_nft.py"]
got_closure = sh('printf "%s\\n" $PDG_RESCUE_CLOSURE').split()
if sorted(got_closure) == sorted(want_closure):
    ok("PDG_RESCUE_CLOSURE 与真实入口算出的闭包逐项一致(%d 项)" % len(want_closure))
else:
    bad("闭包对不上: 名单多 %r / 少 %r"
        % (sorted(set(got_closure) - set(want_closure)),
           sorted(set(want_closure) - set(got_closure))))
if "nftscan.py" in got_closure:
    ok("nftscan.py 在闭包里(breakglass/pdgtx 靠它找 nft —— 少了它防火墙自救会断在最后一步)")
else:
    bad("闭包漏了 nftscan.py")

pdg = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
hand = re.findall(r"for \w+ in rescue\.py[^;]*;", pdg)
if not hand:
    ok("pdg.sh 里没有手写的第二份模块名单(enable 与 status 都读闭包真源)")
else:
    bad("pdg.sh 又出现手写名单: %r" % hand[:1])
if pdg.count("$PDG_RESCUE_CLOSURE") >= 2:
    ok("enable 与 status 两处都读同一份闭包")
else:
    bad("闭包真源只被用了 %d 次" % pdg.count("$PDG_RESCUE_CLOSURE"))

# ── 5. 测试内核定位只有一处 ────────────────────────────────────────────────
print()
print("── 5. mihomo 定位唯一性 ──")
def rogue_locator(path):
    """AST 层面找"自己定位内核"的代码: which("mihomo") 调用, 或读 MIHOMO_BIN 这类私有变量。

    用 AST 不用 grep, 是因为注释与文档字符串里必然会提到这些名字 —— 本文件和被改造过的
    测试都要说清"以前是怎么错的"。按文本扫会把讲解当成违规, 那种守卫只会教人删注释。"""
    hits = []
    for n in ast.walk(ast.parse(open(path, encoding="utf-8").read())):
        if not isinstance(n, ast.Call):
            continue
        fn = getattr(n.func, "attr", "") or getattr(n.func, "id", "")
        args = [a.value for a in n.args if isinstance(a, ast.Constant)]
        if fn == "which" and "mihomo" in args:
            hits.append('which("mihomo")')
        if fn == "get" and any(isinstance(a, str) and "MIHOMO" in a and a != "PDG_TEST_MIHOMO"
                               for a in args):
            hits.append("os.environ.get(%r)" % args[0])
    return hits


users, rogue = [], []
for f in sorted(os.listdir(os.path.join(ROOT, "tests"))):
    if not f.endswith(".py") or f in ("mihomobin.py", os.path.basename(__file__)):
        continue
    path = os.path.join(ROOT, "tests", f)
    hits = rogue_locator(path)
    if hits:
        rogue.append("%s(%s)" % (f, hits[0]))
    if "mihomobin" in open(path, encoding="utf-8").read():
        users.append(f)
if not rogue:
    ok("没有测试自己 which(\"mihomo\") 或认私有环境变量(否则会捡到任意版本)")
else:
    bad("这些测试仍各写一份定位: %s" % ", ".join(rogue))
if len(users) >= 3:
    ok("需要真内核的测试(%s)共用 tests/mihomobin.py" % ", ".join(users))
else:
    bad("只有 %d 个测试接上共享 helper: %r" % (len(users), users))

sys.path.insert(0, os.path.join(ROOT, "tests"))
import mihomobin  # noqa: E402

if mihomobin.pinned_version() == re.search(
        r'^MIHOMO_VER="([^"]+)"',
        open(os.path.join(ROOT, "lib/versions.sh"), encoding="utf-8").read(), re.M).group(1):
    ok("钉死版本读的是 lib/versions.sh(测试里没有第二份字面量)")
else:
    bad("版本号来源不一致")

# 定位顺序: 显式 > 项目备好的 > PATH
env = dict(os.environ, PDG_TEST_MIHOMO="/nonexistent/explicit")
r = subprocess.run([sys.executable, "-c",
                    "import sys; sys.path.insert(0,%r); import mihomobin;"
                    "print([s for _,s in mihomobin.candidates()])" % os.path.join(ROOT, "tests")],
                   capture_output=True, text=True, env=env)
order = r.stdout.strip()
if order.startswith("['PDG_TEST_MIHOMO'"):
    ok("定位顺序: 显式 PDG_TEST_MIHOMO 排第一 → %s" % order)
else:
    bad("顺序不对: %s" % order)

# 版本不符必须失败, 不能静默使用
import tempfile  # noqa: E402

with tempfile.TemporaryDirectory() as d:
    fake = os.path.join(d, "mihomo")
    with open(fake, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\necho 'Mihomo Meta v1.18.0 linux amd64'\n")
    os.chmod(fake, 0o755)
    try:
        mihomobin.find.__globals__["os"].environ["PDG_TEST_MIHOMO"] = fake
        mihomobin.find()
        bad("错版本被静默接受了")
    except mihomobin.MihomoWrongVersion:
        ok("显式指到错版本 → 抛 MihomoWrongVersion(不静默使用)")
    except mihomobin.MihomoMissing:
        bad("错版本被降级成「没找到」—— 严格模式下会被当成环境问题放过")
    finally:
        os.environ.pop("PDG_TEST_MIHOMO", None)

# ── 6. 缺二进制的三种处置: standalone / 严格模式 / CI ─────────────────────
print()
print("── 6. 缺二进制时的行为 ──")
PROBE = """
import sys
sys.path.insert(0, %r)
import mihomobin
n = {"ok": 0, "bad": 0, "skip": 0}
mihomobin.PREPARED = "/nonexistent/prepared"
print(mihomobin.require(lambda m: n.__setitem__("ok", 1),
                        lambda m: n.__setitem__("bad", 1),
                        lambda m: n.__setitem__("skip", 1)))
print(n)
""" % os.path.join(ROOT, "tests")


def probe(**env):
    """在一个**没有任何 mihomo 可见**的子进程里跑 require(), 看它落到哪个计数。"""
    e = {k: v for k, v in os.environ.items()
         if k not in ("PDG_TEST_MIHOMO", "PDG_TEST_STRICT", "CI")}
    e["PATH"] = "/nonexistent-bin"          # PATH 上也没有
    e.update(env)
    r = subprocess.run([sys.executable, "-c", PROBE], capture_output=True, text=True, env=e)
    return r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-200:]


got = probe()
if "'skip': 1" in got and "'bad': 0" in got:
    ok("单跑缺二进制 → [SKIP](明确写出真内核校验未执行, 不冒充通过)")
else:
    bad("单跑缺二进制没走 SKIP: %s" % got)
got = probe(PDG_TEST_STRICT="1")
if "'bad': 1" in got:
    ok("严格模式缺二进制 → 判失败(关键校验不许悄悄变绿灯)")
else:
    bad("严格模式缺二进制没判失败: %s" % got)
got = probe(CI="true")
if "'bad': 1" in got:
    ok("CI 环境缺二进制 → 判失败(不必再手工设 PDG_TEST_STRICT)")
else:
    bad("CI 下缺二进制没判失败: %s" % got)

# PATH 上只有错版本 → 必须失败, 不能当成"没找到"而被 SKIP 放过
with tempfile.TemporaryDirectory() as d:
    fake = os.path.join(d, "mihomo")
    with open(fake, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\necho 'Mihomo Meta v1.18.0 linux amd64'\n")
    os.chmod(fake, 0o755)
    got = probe(PATH=d)
    if "'bad': 1" in got:
        ok("PATH 上只有错版本 → 判失败(不是 SKIP —— 那是台装错版本的机器, 必须拦下)")
    else:
        bad("PATH 上的错版本被放过了: %s" % got)

# CI 真的准备了二进制并交给 helper
ci = open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8").read()
if "tests/prepare-mihomo.sh" in ci and "PDG_TEST_STRICT" in ci:
    ok("CI 备好钉死版并开严格模式(prepare-mihomo.sh + PDG_TEST_STRICT)")
else:
    bad("CI 没准备二进制或没开严格模式")
i_prep = ci.find("tests/prepare-mihomo.sh")
if i_prep < 0:
    bad("CI 里根本没有准备步骤 —— 顺序与去重都无从谈起")
elif all(i_prep < ci.index("tests/%s" % t)
         for t in ("test-rule-mixed.py", "test-emergency-exit.py")):
    ok("准备步骤排在需要真内核的测试之前")
else:
    bad("准备步骤排在了测试后面")
if ci.count("prepare-mihomo.sh") == 1:
    ok("只准备一次, 不在每个测试里重复下载")
else:
    bad("CI 里准备了 %d 次" % ci.count("prepare-mihomo.sh"))

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

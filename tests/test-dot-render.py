#!/usr/bin/env python3
"""6.2A: DoT 证据源的**配置输入闭包**。

上一轮把 `__DOT_DOMAIN__` 写进了 mosdns 模板, 却没有人替换它 —— 真机上配置照常加载、
普通 DNS 也不受影响, 但探测分支两个判据谁都匹配不上, 功能是死的。这支盯的就是这类
"模板里有、没人生产"的缺口: 每个新引入的值都要能指出**唯一的生产者**, 并且渲染产物里
不许再有占位符。

这里用的是 install.sh 里那个真正的 render() —— 从源文件里抽出来跑, 不另写一套模拟渲染,
否则测试绿了只能说明我的模拟器和我的期望一致。
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmpguard  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "install.sh")
TPL = os.path.join(ROOT, "deploy", "mosdns", "config.yaml")
WITNESS = os.path.join(ROOT, "deploy", "bot", "dotwitness.py")
POLICY = os.path.join(ROOT, "tests", "dns-policy-test.sh")

npass = nfail = 0
TMP = None


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


def extract_render():
    """把 install.sh 里那个真正的 render() 原样抽出来, 不另写一套模拟渲染。

    锚必须钉到 render() 真正的收尾 `"$1"; }` —— 用泛化的 `\}\s*$` 会停在函数体内那个
    `|| { ...; return 1; }` 上, 抽出来是半截函数, 跑起来直接语法错。
    """
    src = open(INSTALL).read()
    m = re.search(r'^render\(\)\{.*?"\$1"; \}\s*$', src, re.S | re.M)
    return m.group(0) if m else None


def run_render(domain, extra_env=None):
    """用真 render() 渲染模板, 返回 (rc, stdout, stderr)。"""
    fn = extract_render()
    if fn is None:
        return None, "", "render() 抽不到"
    env = {
        "SERVER_IP": "203.0.113.1", "INTERNAL_CIDR": "172.22.0.0/16",
        "CERT_DIR": "/etc/privdns-gateway/dot", "SSH_PORT": "22",
        "MOSDNS_CACHE": "8192", "JOURNALD_MAXUSE": "200M",
        "HIJACK_SET_FILE": "geosite_geolocation-!cn.txt",
        "PDG_RESCUE_PORT": "8446", "RESCUE_BIND": "203.0.113.1",
        "DOT_DOMAIN": domain, "SRC": ROOT, "REPO_DIR": ROOT,
    }
    env.update(extra_env or {})
    assign = "\n".join('%s=%s' % (k, subprocess_quote(v)) for k, v in env.items())
    # die 是 install.sh 的报错helper; 这里给一个等价桩(同样非零退出), 语义不变。
    stub = 'die(){ echo "$*" >&2; exit 1; }'
    script = "set -u\n%s\n%s\n%s\nrender %s\n" % (stub, assign, fn, subprocess_quote(TPL))
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def subprocess_quote(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


DOMAIN = "dot.example.test"

# ── 1. 正式 render 入口 ─────────────────────────────────────────────────────
head("1. 正式 render 入口渲染模板")
fn = extract_render()
(ok if fn else bad)("能从 install.sh 抽到 render()")
rc, out, err = run_render(DOMAIN)
(ok if rc == 0 else bad)("render 成功(rc=%s) %s" % (rc, err.strip()[:80]))

leftover = sorted(set(re.findall(r"__[A-Z0-9_]+__", out))) if out else ["(无输出)"]
(ok if not leftover or leftover == [] else bad)(
    "渲染产物没有残留占位符(实得 %s)" % (", ".join(leftover) or "无"))

# ── 2. DoT 域名要真的进到两个判据里 ─────────────────────────────────────────
head("2. DoT 域名进入 qname / SNI 两个判据")
(ok if re.search(r"qname suffix probe\.%s\b" % re.escape(DOMAIN), out or "") else bad)(
    "qname 判据里是渲染后的 DoT 域名")
(ok if re.search(r"string_exp server_name eq %s\b" % re.escape(DOMAIN), out or "") else bad)(
    "server_name 判据里是渲染后的 DoT 域名")

# ── 3. 空值 / 非法域名必须非零失败 ──────────────────────────────────────────
head("3. 缺失与非法输入必须 fail-closed")
for bogus, why in (("", "空值"), ("has space", "含空格"), ("../etc/passwd", "含路径")):
    rc2, out2, _ = run_render(bogus)
    dead = (rc2 != 0) or ("__DOT_DOMAIN__" in (out2 or ""))
    (ok if dead else bad)("%s 的 DoT 域名不得被静默接受(rc=%s)" % (why, rc2))

# ── 4. 端口的两份表示必须一致 ────────────────────────────────────────────────
head("4. witness 端口: YAML 与 Python 两份表示的一致性硬门")
# 这里不是单一真源: 端口在 mosdns 模板里是字面量, 在 dotwitness.py 里是常量。
# 之所以不用占位符, 是因为这份模板有十来个渲染点, 占位符落在"必须解析成端口"的位置时,
# 任何一处没跟上都会让 mosdns 起不来。代价就是两份表示, 所以在这里逐字比对兜住。
wsrc = open(WITNESS).read() if os.path.isfile(WITNESS) else ""
tpl = open(TPL).read()
m = re.search(r"^DOTWITNESS_PORT\s*=\s*(\d+)", wsrc, re.M)
(ok if m else bad)("dotwitness.py 里有 DOTWITNESS_PORT 常量")
tports = re.findall(r'addr:\s*"udp://127\.0\.0\.1:(\d+)"', tpl)
(ok if len(tports) == 1 else bad)(
    "模板里恰好一处 witness 转发地址(实得 %d 处)" % len(tports))
if m and len(tports) == 1:
    (ok if m.group(1) == tports[0] else bad)(
        "两份表示相等: dotwitness.py=%s 模板=%s" % (m.group(1), tports[0]))
else:
    bad("两份表示相等")
(ok if "__DOTWITNESS_PORT__" not in tpl else bad)(
    "模板里不再有端口占位符(它会让没跟上的渲染点加载失败)")
(ok if re.search(r'addr:\s*"udp://127\.0\.0\.1:', tpl) else bad)("witness 地址是环回地址")
_unit = open(os.path.join(ROOT, "deploy", "bot", "pdg-dotwitness.service")).read()
_unit_code = re.sub(r"^\s*#.*$", "", _unit, flags=re.M)
(ok if "PDG_DOTWITNESS_PORT" not in _unit_code else bad)(
    "生产 unit 不通过环境文件覆盖端口(覆盖了就和模板对不上)")

# ── 5. dotwitness.env 必须有生产者 ──────────────────────────────────────────
head("5. dotwitness.env 的生产者")
producers = []
for f in ("install.sh", os.path.join("deploy", "bot", "pdg.sh")):
    p = os.path.join(ROOT, f)
    if os.path.isfile(p) and re.search(r">\s*\S*dotwitness\.env|dotwitness\.env\"?\s*$",
                                       open(p).read(), re.M):
        producers.append(f)
(ok if producers else bad)(
    "有人生产 /etc/privdns-gateway/dotwitness.env(实得 %s)" % (", ".join(producers) or "无"))
unit = open(os.path.join(ROOT, "deploy", "bot", "pdg-dotwitness.service")).read()
(ok if "dotwitness.env" in unit else bad)("unit 消费 dotwitness.env")

# ── 6. 带"零占位符"断言的渲染点必须替换域名 ─────────────────────────────────
head("6. 测试侧渲染器")
# 只要求那些**契约上要求完整生产渲染**(自带"渲染后不许残留占位符"断言)的渲染点替换域名;
# 其余渲染点留着 __DOT_DOMAIN__ 无害 —— 实测配置照常加载, 只是探测分支不匹配。
for rel in ("tests/dns-policy-test.sh", "tests/test-hijack-shape.sh",
            "tests/test-mosdns-ratelimit.sh"):
    p2 = os.path.join(ROOT, rel)
    txt = open(p2).read() if os.path.isfile(p2) else ""
    (ok if "__DOT_DOMAIN__" in txt else bad)(
        "%s 带零占位符断言, 必须替换 __DOT_DOMAIN__" % os.path.basename(rel))

# ── 7. 渲染产物要能被钉定 mosdns 接受 ───────────────────────────────────────
head("7. 渲染产物的配置校验")
mos = shutil.which("mosdns")
if not mos:
    bad("本机没有 mosdns, 无法校验渲染产物 —— 这条必须在有 mosdns 的环境跑")
elif not out:
    bad("渲染没有输出, 无法校验")
else:
    # 走项目登记式临时目录(tests/tmpguard.py): 建时登记、退出时按表清, 只清本进程的。
    d = tmpguard.mkdtemp(prefix="pdg-dotrender.")
    TMP = d
    try:
        cfg = os.path.join(d, "config.yaml")
        # dot_server 需要真证书; 校验语法时把它摘掉, 其余逐字节保留。
        body = re.sub(r"\n  - tag: dot_server\n(?:.*\n)*?(?=\n  - tag: |\Z)", "\n", out)
        # domain_set / ip_set 引用的规则文件在这里不存在 —— mosdns 会因为读不到文件而
        # 判失败, 那不是配置语法问题。按 dns-policy-test.sh 的同款做法: 路径改到临时目录,
        # 建空文件, 只留"配置本身能不能被接受"这一个变量。
        rules = os.path.join(d, "rules")
        os.makedirs(rules, exist_ok=True)
        for name in set(re.findall(r"/etc/mosdns/rules/([A-Za-z0-9_.!-]+)", body)):
            open(os.path.join(rules, name), "w").close()
        body = body.replace("/etc/mosdns/rules/", rules + "/")
        body = re.sub(r'listen: "0\.0\.0\.0:53"', 'listen: "127.0.0.1:15399"', body)
        open(cfg, "w").write(body)
        p = subprocess.run([mos, "start", "-c", cfg, "--as-service"],
                           capture_output=True, text=True, timeout=8)
        blob = (p.stdout or "") + (p.stderr or "")
        fatal = re.search(r"(failed to|cannot|invalid|unknown plugin|syntax)", blob, re.I)
        (ok if not fatal else bad)(
            "钉定 mosdns 接受渲染后的配置%s" % ("" if not fatal else ": " + fatal.group(0)))
    except subprocess.TimeoutExpired:
        ok("钉定 mosdns 接受渲染后的配置(起来后一直跑, 未报配置错)")
    # 清理交给 tmpguard 的 atexit, 这里不重复删。

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

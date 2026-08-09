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
import tempfile

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
    """把 install.sh 的渲染闭包原样抽出来 —— 包括 render() 依赖的那些推导(比如
    DOTWITNESS_PORT 从 dotwitness.py 取值)。只抽函数体的话, 测试等于自己补了一份
    输入, 单一事实源那条就白测了。抽不到就判红, 不退回自己拼一个。"""
    src = open(INSTALL).read()
    # 锚到 render() 真正的收尾 `"$1"; }` —— 用泛化的 `\}\s*$` 会停在函数体内那个
    # `|| { ...; return 1; }` 上, 抽出来的是半截函数, 跑起来直接语法错。
    m = re.search(r'^DOTWITNESS_PORT=.*?^render\(\)\{.*?"\$1"; \}\s*$', src, re.S | re.M)
    if m:
        return m.group(0)
    m = re.search(r"^render\(\)\{.*?\}\s*$", src, re.S | re.M)
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

# ── 4. witness 端口只能有一个事实源 ─────────────────────────────────────────
head("4. witness 端口的单一事实源")
wsrc = open(WITNESS).read() if os.path.isfile(WITNESS) else ""
m = re.search(r"^DOTWITNESS_PORT\s*=\s*(\d+)", wsrc, re.M)
(ok if m else bad)("dotwitness.py 里有 DOTWITNESS_PORT 常量")
tpl = open(TPL).read()
hard = re.findall(r"udp://127\.0\.0\.1:(\d+)", tpl)
(ok if not hard else bad)(
    "mosdns 模板里不再硬编码 witness 端口(实得 %s)" % (", ".join(hard) or "无"))
(ok if "__DOTWITNESS_PORT__" in tpl else bad)("mosdns 模板用占位符引用 witness 端口")
if m and out:
    (ok if ("udp://127.0.0.1:%s" % m.group(1)) in out else bad)(
        "渲染后端口与 dotwitness.py 常量一致(%s)" % (m.group(1) if m else "?"))
else:
    bad("渲染后端口与 dotwitness.py 常量一致")

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

# ── 6. 测试侧那套渲染器也要跟上 ─────────────────────────────────────────────
head("6. 测试侧渲染器")
pol = open(POLICY).read() if os.path.isfile(POLICY) else ""
(ok if "__DOT_DOMAIN__" in pol else bad)(
    "dns-policy-test.sh 的渲染器也替换 __DOT_DOMAIN__(它自带残留占位符断言)")
(ok if "__DOTWITNESS_PORT__" in pol else bad)(
    "dns-policy-test.sh 的渲染器也替换 __DOTWITNESS_PORT__")

# ── 7. 渲染产物要能被钉定 mosdns 接受 ───────────────────────────────────────
head("7. 渲染产物的配置校验")
mos = shutil.which("mosdns")
if not mos:
    bad("本机没有 mosdns, 无法校验渲染产物 —— 这条必须在有 mosdns 的环境跑")
elif not out:
    bad("渲染没有输出, 无法校验")
else:
    d = tempfile.mkdtemp(prefix="pdg-dotrender-")
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
    finally:
        shutil.rmtree(d, ignore_errors=True)

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

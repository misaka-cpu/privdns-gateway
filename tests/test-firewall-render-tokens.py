#!/usr/bin/env python3
"""nft 模板的渲染点必须替换掉模板里的**每一个**占位符。

为什么要有这支: `pdg platform <ios|android>` 与 `pdg migrate-fw` 渲染
deploy/firewall/nftables-mihomo.conf 时只替换了 __SSH_PORT__ 与 __INTERNAL_CIDR__,
把 __RESCUE_PORT__ 原样留在产物里 —— nft 报 `Could not resolve service`, 于是这两条
命令在**任何机器上**都必然失败。它 fail-closed(回滚, 不损坏现网), 所以从"有没有出事"
看不出来; 只有真去渲一遍才看得见。v1.9.0 上就是这样, 至少烂了一个发布。

判据刻意**不锚在那两行 sed 的文本形状上**(那种锚点一改就断, 本项目已栽过多次), 而是:
  · 需要替换的 token 集合从**模板自己**读出来, 不写死;
  · 渲染点用"同一条语句里既提到 sed 又提到模板文件"识别, 行号漂移不影响;
  · 每个渲染点实际替换的 token 集合必须**覆盖**模板集合;
  · 用到 $PDG_RESCUE_PORT 的地方必须真的能取到它 —— pdg.sh 是 `set -u`, 而
    lib/rescue.sh 只在 _rescue_load() 里 source。所在函数不先加载就写 $PDG_RESCUE_PORT,
    换来的是 "unbound variable" 当场崩掉, 比留个占位符更糟。这条单独钉。
  · 最后真拿 nft -c 校验渲染产物 —— 静态判据再全, 也不如让 nft 自己说一句。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TPL = os.path.join(ROOT, "deploy", "firewall", "nftables-mihomo.conf")
PROD = ["install.sh", os.path.join("deploy", "bot", "pdg.sh")]

npass = nfail = nskip = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def skip(m):
    global nskip
    nskip += 1
    print("[SKIP] %s" % m)


def logical_lines(src):
    """把续行(行尾反斜杠)拼成一条逻辑语句, 返回 (起始行号, 语句文本)。"""
    out, buf, start = [], "", 0
    for i, line in enumerate(src.splitlines(), 1):
        if not buf:
            start = i
        buf += line
        if line.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1] + " "
            continue
        out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def enclosing_func(src, lineno):
    """lineno 所在的最近一个顶层函数定义 (名字, 起始行, 结束行)。"""
    lines = src.splitlines()
    name = None
    start = 0
    for i, l in enumerate(lines[:lineno], 1):
        m = re.match(r"^(_?[A-Za-z0-9_]+)\(\)\s*\{", l)
        if m:
            name, start = m.group(1), i
    if name is None:
        return None, 0, 0
    end = len(lines)
    for i in range(start, len(lines)):
        if lines[i] == "}":
            end = i + 1
            break
    return name, start, end


# ── 模板需要哪些 token(唯一可信源就是模板自己) ────────────────────────────
tpl_src = open(TPL, encoding="utf-8").read()
NEED = sorted(set(re.findall(r"__[A-Z_]+__", tpl_src)))
print("── 模板占位符(从模板读出, 未写死) ──")
print("  %s" % " ".join(NEED))
(ok if NEED else bad)("模板里解析出 %d 个占位符" % len(NEED))

# ── 找出全部生产渲染点 ─────────────────────────────────────────────────────
TPLBASE = "nftables-mihomo.conf"
sites = []
for rel in PROD:
    src = open(os.path.join(ROOT, rel), encoding="utf-8").read()
    for lineno, stmt in logical_lines(src):
        s = stmt.strip()
        if s.startswith("#"):
            continue
        if TPLBASE not in stmt or "sed" not in stmt:
            continue
        subs = sorted(set(re.findall(r"__[A-Z_]+__", stmt)))
        sites.append((rel, lineno, subs, stmt, src))

print("\n── 生产渲染点 ──")
(ok if sites else bad)("找到 %d 个渲染点(0 个说明识别方式失效了, 不是真没有)" % len(sites))
for rel, lineno, subs, _stmt, _src in sites:
    print("  %s:%d → %s" % (rel, lineno, " ".join(subs) or "(一个都没替换)"))

# install.sh 走的是 render() 函数, 模板名与 sed 不在同一条语句里 —— 单独认。
inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
m = re.search(r"^render\(\)\s*\{.*?\n(?=[a-zA-Z_#])", inst, re.M | re.S)
if m:
    rsubs = sorted(set(re.findall(r"__[A-Z_]+__", m.group(0))))
    missing = [t for t in NEED if t not in rsubs]
    (ok if not missing else bad)(
        "install.sh render() 覆盖模板全部占位符" if not missing
        else "install.sh render() 漏了 %s" % missing)
else:
    bad("找不到 install.sh 的 render() —— 判据失效")

# ── 每个渲染点必须覆盖模板的全部 token ────────────────────────────────────
print("\n── 覆盖判据 ──")
for rel, lineno, subs, _stmt, _src in sites:
    missing = [t for t in NEED if t not in subs]
    if missing:
        bad("%s:%d 渲染 nft 模板时漏替换 %s —— 产物里会留着字面 token, nft 认不出来"
            % (rel, lineno, ",".join(missing)))
    else:
        ok("%s:%d 覆盖模板全部 %d 个占位符" % (rel, lineno, len(NEED)))

# ── 用的必须是现有常量, 且所在函数能真的取到它 ────────────────────────────
print("\n── $PDG_RESCUE_PORT 取值与作用域 ──")
for rel, lineno, subs, stmt, src in sites:
    if "__RESCUE_PORT__" not in subs:
        continue
    if "$PDG_RESCUE_PORT" not in stmt:
        bad("%s:%d 替换 __RESCUE_PORT__ 用的不是现有常量 $PDG_RESCUE_PORT" % (rel, lineno))
        continue
    ok("%s:%d 用现有常量 $PDG_RESCUE_PORT(不另立默认值)" % (rel, lineno))
    if not rel.endswith("pdg.sh"):
        continue
    fn, fstart, fend = enclosing_func(src, lineno)
    body = "\n".join(src.splitlines()[fstart - 1:fend])
    before = "\n".join(src.splitlines()[fstart - 1:lineno])
    if "_rescue_load" in before:
        ok("%s:%d 所在函数 %s() 在渲染前先 _rescue_load(set -u 下才取得到)" % (rel, lineno, fn))
    else:
        bad("%s:%d 所在函数 %s() 没先 _rescue_load —— pdg.sh 是 set -u, "
            "lib/rescue.sh 只在 _rescue_load 里 source, 这里会 unbound variable 崩掉"
            % (rel, lineno, fn))

# ── 真 nft -c: 静态判据说得再全, 也让 nft 自己表态 ────────────────────────
print("\n── 真 nft -c 校验渲染产物 ──")
nft = shutil.which("nft") or "/usr/sbin/nft"


def nft_usable():
    """先证明 nft 在本环境真能当裁判 —— 否则它报的红与占位符无关。

    非 root 下 `nft -c` 会以 "cache initialization failed: Operation not permitted"
    失败, 那是权限, 不是配置错。拿它当判据就是假红: 修好了也照样红, 而且红的理由
    与被测的东西完全无关。所以先用一份**全部替换到位**的产物探一次能力。
    """
    if not os.path.exists(nft):
        return False, "本机没有 nft"
    wd = tempfile.mkdtemp(prefix="pdg-fwprobe-")
    try:
        good = os.path.join(wd, "all.nft")
        t = tpl_src
        for tok, v in (("__SSH_PORT__", "22"), ("__INTERNAL_CIDR__", "172.22.0.0/16"),
                       ("__RESCUE_PORT__", "8446"), ("__SERVER_IP__", "203.0.113.10"),
                       ("__CERT_DIR__", "/etc/mosdns/certs")):
            t = t.replace(tok, v)
        open(good, "w", encoding="utf-8").write(t)
        p = subprocess.run([nft, "-c", "-f", good], capture_output=True, text=True)
        if p.returncode == 0:
            return True, ""
        return False, ((p.stderr or p.stdout).strip().splitlines() or ["(无输出)"])[0]
    finally:
        shutil.rmtree(wd, ignore_errors=True)


usable, why = nft_usable()
if not usable:
    skip("nft 在本环境当不了裁判(%s) —— 动态判据没跑, root/容器里必须跑到" % why)
else:
    ok("能力对照: 全部替换到位的产物通过 nft -c(下面的红才归因于占位符)")
    for rel, lineno, subs, _stmt, _src in sites:
        wd = tempfile.mkdtemp(prefix="pdg-fwrender-")
        try:
            out = os.path.join(wd, "rendered.nft")
            t = tpl_src
            # 只替换该渲染点声称会替换的那些 —— 漏掉的就让它留在产物里, 由 nft 判死
            vals = {"__SSH_PORT__": "22", "__INTERNAL_CIDR__": "172.22.0.0/16",
                    "__RESCUE_PORT__": "8446", "__SERVER_IP__": "203.0.113.10",
                    "__CERT_DIR__": "/etc/mosdns/certs"}
            for tok in subs:
                t = t.replace(tok, vals.get(tok, "PLACEHOLDER"))
            open(out, "w", encoding="utf-8").write(t)
            p = subprocess.run([nft, "-c", "-f", out], capture_output=True, text=True)
            if p.returncode == 0:
                ok("%s:%d 的替换集合渲出的产物通过真 nft -c" % (rel, lineno))
            else:
                err = (p.stderr or p.stdout).strip().splitlines()
                bad("%s:%d 的替换集合渲出的产物 nft -c 不过: %s"
                    % (rel, lineno, err[0] if err else "(无输出)"))
        finally:
            shutil.rmtree(wd, ignore_errors=True)

print("\n" + "─" * 66)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)

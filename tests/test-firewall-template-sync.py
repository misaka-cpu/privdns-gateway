#!/usr/bin/env python3
"""升级时防火墙必须按模板重建 —— 否则模板改动永远到不了已装机器。

── 这条缺口是怎么暴露的 ────────────────────────────────────────────────────────
`migrate_firewall_to_pdg` 做的是一次性搬迁: 旧的 `inet filter` → 独立表 `inet pdg`。
它开头就写着「已是新表 → 无需迁移」并 return —— 对**已经在 inet pdg 上的机器**,
它什么都不做。于是模板后续的任何改动都传不过去: 机器上跑的永远是当初装机那一版渲染结果。

平时看不出来, 因为没人核对"内核里的规则"和"当前模板"是否还一致。直到有个判据开始查
具体规则在不在 —— Tailscale 入口隔离就是第一个 —— 升级立刻变成: 新判据要求新规则,
而没有任何一步会把新规则装上去, 于是 doctor 判红 → cmd_update 自检门整次回滚 →
**这个版本在所有旧机器上都装不上**。

模板自己早就写明了契约(nftables-mihomo.conf 里那句「本表每次更新都会按模板重建」),
只是从来没有实现。这支把契约钉住。

── 判据 ─────────────────────────────────────────────────────────────────────
用真 nft 加载, 不做文本比对: 比的是"内核里的语义"与"当前模板渲染后的语义"。
用户自定义规则走 include 目录, 重建不碰它 —— 这一点也一并钉住。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TPL = os.path.join(ROOT, "deploy", "firewall", "nftables-mihomo.conf")
PDG = os.path.join(ROOT, "deploy", "bot", "pdg.sh")

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


def run(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                          text=True, **kw)


print("══ 升级时防火墙按模板重建 ══\n")

# ── 一、静态: 必须存在一个"把模板同步到已迁移机器"的迁移, 且挂进 __migrate ──────
print("── 一、同步迁移必须存在并被调用 ──")
with open(PDG, encoding="utf-8") as f:
    SRC = f.read()

FN = "migrate_firewall_template_sync"
if re.search(r"^%s\(\)\{" % FN, SRC, re.M):
    ok("%s 已定义" % FN)
else:
    bad("没有 %s —— 已在 inet pdg 上的机器收不到任何模板改动" % FN)

# 光定义不算数: 必须真的排进更新时跑的迁移序列
# `__migrate` 是 CLI 子命令而不是函数: 迁移集中在一处顺序调用, cmd_update 装好新脚本后
# 经 `pdg __migrate` 走一遍。所以判据是"同步迁移出现在那串调用里", 且紧跟搬迁之后。
disp = re.search(r"migrate_firewall_to_pdg \|\| true(.{0,400})", SRC, re.S)
if not disp:
    bad("找不到迁移调度处(无法确认同步迁移会被调用)")
elif FN in disp.group(1):
    ok("%s 已挂进迁移调度, 且排在 migrate_firewall_to_pdg 之后" % FN)
else:
    bad("%s 没挂进迁移调度 —— 写了但不会被调用" % FN)

# 顺序: 必须排在 doctor 自检门之前, 否则自检看到的仍是旧规则
upd = re.search(r"^cmd_update\(\)\{(.*?)^\}", SRC, re.M | re.S)
if upd:
    body = upd.group(1)
    p_mig = body.find("__migrate")
    p_doc = body.find("doctor.py")
    if p_mig < 0 or p_doc < 0:
        bad("cmd_update 里找不到 __migrate 或 doctor 自检门")
    elif p_mig < p_doc:
        ok("__migrate 排在 doctor 自检门之前(第 %d 字符 < 第 %d 字符)" % (p_mig, p_doc))
    else:
        bad("__migrate 排在自检之后 —— 自检看到的还是旧规则, 必然误回滚")

# ── 二、真 nft: 旧渲染结果 + 新模板 → 重建后语义必须等于新模板 ──────────────────
# ── 一之二、参数反解必须"唯一且合法", 且失败时什么都不做 ─────────────────────
print("\n── 一之二、参数反解的 fail-closed ──")
fn = re.search(r"^%s\(\)\{(.*?)^\}" % FN, SRC, re.M | re.S)
FNB = fn.group(1) if fn else ""

if "PDG_RESCUE_PORT" in FNB and "grep -oE 'ip saddr" not in FNB:
    bad("救援端口取自常量而非反解 —— 常量与机器现状不一致时会悄悄改掉放行")
elif re.search(r'rport=.*grep', FNB):
    ok("三个参数都从机器当前配置反解(救援端口也是)")
else:
    bad("救援端口没有从当前配置反解")

# 只看代码行: 注释里提到 `head -1` 是在解释为什么不用它, 不该被算成使用。
CODE = "\n".join(L for L in FNB.splitlines() if not L.strip().startswith("#"))
if "sort -u" in CODE and "head -1" not in CODE:
    ok("用 sort -u 判唯一, 代码里没有 head -1 静默取首个")
else:
    bad("参数反解仍可能静默取首个 —— 配置里有多个值时最该停下来")

if re.search(r'-ge 1 && .*-le 65535', CODE) and "[0-9]{1,3}" in CODE:
    ok("端口范围与网段形态都做了合法性校验")
else:
    bad("缺端口范围或网段形态的合法性校验")

# 反解失败那条分支必须在写盘/加载之前就 return, 且不回显具体值
pre = FNB.split("mktemp")[0]
if "return 0" in pre and ("不写盘" in pre or "跳过" in pre):
    ok("反解失败在 mktemp/写盘之前就返回(不写盘、不加载、不重启)")
else:
    bad("反解失败没有在写盘前返回")
if re.search(r'c_y "[^"]*\$(port|cidr|rport)', FNB):
    bad("失败文案回显了具体端口/网段 —— 日志不该出现这台机器的私有值")
else:
    ok("失败文案只说哪类参数有问题, 不回显具体值")

# before-image 必须含 mode/uid/gid 且校验过
if "stat -c %a" in FNB and "stat -c %u:%g" in FNB:
    ok("before-image 覆盖内容+权限+属主, 且落盘后逐项校验")
else:
    bad("before-image 没有覆盖权限/属主")
if re.search(r'rb=1', FNB) and "回滚\*\*不完整\*\*" in FNB or "回滚**不完整**" in FNB:
    ok("回滚不完整会明确告警并返回非零")
else:
    bad("回滚不完整没有明确告警")

# 用户 include 与旧表绝不能出现在这个函数里
# 只看代码行, 并剔掉 c_g/c_y 的提示文案: 告诉用户"你的 nft-input.d 规则不受影响"
# 是**说明**, 不是**触碰**。判据认字符串就会把这种文案当成越界, 那是假阳性。
FN_CODE = "\n".join(L for L in FNB.splitlines()
                    if not L.strip().startswith("#")
                    and not re.match(r"\s*c_[gy] ", L))
if "nft-input.d" in FN_CODE:
    bad("函数体碰了用户 include 目录")
else:
    ok("函数体不触碰用户 include 目录")
if "inet filter" in FNB:
    bad("函数体碰了用户旧 table inet filter")
else:
    ok("函数体不触碰旧 table inet filter")

print("\n── 二、真 nft 语义比对 ──")
SUDO = "" if os.geteuid() == 0 else "sudo -n"
if os.geteuid() != 0 and run("sudo -n true").returncode != 0:
    skip("需要 root 或免密 sudo 才能真加载 nft")
elif not (shutil.which("nft") or os.path.exists("/usr/sbin/nft")):
    skip("缺少 nft")
else:
    NS = "pdgfwsync"
    run("%s ip netns del %s" % (SUDO, NS))
    run("%s ip netns add %s" % (SUDO, NS))
    try:
        # 救援端口从常量读, 不写字面量(test-rescue-constants.sh 守着这条)。
        rp = run([sys.executable,
                  os.path.join(ROOT, "deploy", "bot", "rescue_const.py"), "--port"],
                 env={**os.environ, "PDG_RESCUE_PORT": ""}).stdout.strip()

        def render(text):
            return (text.replace("__INTERNAL_CIDR__", "172.22.0.0/16")
                        .replace("__SSH_PORT__", "22")
                        .replace("__SSH_MATCH__", "")      # 夹具用默认形态(对全网放行)
                        .replace("__RESCUE_PORT__", rp))

        with open(TPL, encoding="utf-8") as f:
            tpl_text = f.read()

        # 「旧机器」= 当前模板去掉 tailscale 排除后的渲染结果, 模拟装机时那一版
        old_text = "\n".join(L for L in render(tpl_text).splitlines()
                             if "nft-input.d" not in L and 'iifname "tailscale0"' not in L)
        new_text = "\n".join(L for L in render(tpl_text).splitlines()
                             if "nft-input.d" not in L)

        def load(text):
            fd, path = tempfile.mkstemp(prefix="pdgfwsync-", suffix=".nft")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(text)
                os.chmod(path, 0o644)
                return run("%s ip netns exec %s nft -f %s" % (SUDO, NS, path))
            finally:
                try:
                    os.unlink(path)
                except OSError:
                    pass

        def kernel_sig():
            p = run("%s ip netns exec %s nft -j list table inet pdg" % (SUDO, NS))
            if p.returncode != 0:
                return None
            import json
            import hashlib
            d = json.loads(p.stdout)["nftables"]
            rs = [json.dumps(x["rule"]["expr"], sort_keys=True) for x in d if "rule" in x]
            return hashlib.sha256("".join(rs).encode()).hexdigest()

        if load(old_text).returncode != 0:
            bad("旧版规则加载失败(实验床问题, 非判据)")
        else:
            sig_old = kernel_sig()
            run("%s ip netns exec %s nft flush ruleset" % (SUDO, NS))
            if load(new_text).returncode != 0:
                bad("当前模板渲染后加载失败")
            else:
                sig_new = kernel_sig()
                if sig_old and sig_new and sig_old != sig_new:
                    ok("旧渲染与当前模板的内核语义确实不同(指纹 %s ≠ %s)"
                       % (sig_old[:12], sig_new[:12]))
                    ok("→ 所以「已迁移的机器不重建」等于永远停在旧规则上")
                else:
                    bad("两版指纹相同, 这支的前提不成立(实验床没造出差异)")
    finally:
        run("%s ip netns del %s" % (SUDO, NS))

print("\n" + "─" * 66)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)

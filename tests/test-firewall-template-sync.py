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
        def render(text):
            return (text.replace("__INTERNAL_CIDR__", "172.22.0.0/16")
                        .replace("__SSH_PORT__", "22")
                        .replace("__RESCUE_PORT__", "8446"))

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

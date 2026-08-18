#!/usr/bin/env python3
"""磁盘已是新版、内核仍跑旧规则时, 模板同步必须收敛内核。

── 缺口 ─────────────────────────────────────────────────────────────────────
`migrate_firewall_template_sync` 判"要不要重建"只看**磁盘**: 候选与 /etc/nftables.conf
逐字节相同就 return 0。磁盘已经是新版而内核还跑着旧规则时(装机中断、配置写了没 load、
快照只还原了文件), 它认为无事可做, 而防火墙实际上仍在按旧规则放行。

这不是假想: e2e-update 的取证显示函数每次都走 `noop-identical`, 磁盘是新的, 内核是旧的,
doctor 读内核判"缺 tailscale0 排除规则", 更新整次回滚 —— 六个升级类 job 就红在这里。

── 判据取哪一侧 ─────────────────────────────────────────────────────────────
不做"磁盘逐条 vs 内核逐条": nftables v1.0.6 下 `nft -c -j -f` 输出 0 字节, 候选的规范化
形态**拿不到, 除非真加载**(nftlive.py 开头已记录过这条实验)。所以判据放在内核一侧 ——
问"模板承诺的关键不变量在内核里成立吗", 用的是 doctor 那条读取链, 而不是文本比对。
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
NS = "pdgdrift"

npass = nfail = nskip = 0
ok = lambda m: (globals().__setitem__("npass", npass + 1), print("[OK]   %s" % m))
bad = lambda m: (globals().__setitem__("nfail", nfail + 1), print("[FAIL] %s" % m))


def run(c, **k):
    return subprocess.run(c, shell=isinstance(c, str), capture_output=True, text=True, **k)


SUDO = "" if os.geteuid() == 0 else "sudo -n"
print("══ 磁盘/内核漂移时的模板同步 ══\n")

if os.geteuid() != 0 and run("sudo -n true").returncode != 0:
    print("[SKIP] 需要 root 或免密 sudo"); print("\n通过 0, 失败 0, 跳过 1"); sys.exit(0)
if not (shutil.which("nft") or os.path.exists("/usr/sbin/nft")):
    print("[SKIP] 缺 nft"); print("\n通过 0, 失败 0, 跳过 1"); sys.exit(0)

rp = run([sys.executable, os.path.join(ROOT, "deploy", "bot", "rescue_const.py"), "--port"],
         env={**os.environ, "PDG_RESCUE_PORT": ""}).stdout.strip()
with open(TPL, encoding="utf-8") as f:
    tpl = f.read()


def render(text):
    return (text.replace("__INTERNAL_CIDR__", "172.22.0.0/16")
                .replace("__SSH_PORT__", "22").replace("__RESCUE_PORT__", rp))


# C 态的要害: 磁盘必须与函数渲染的候选**逐字节相同**, 否则它走的是 A 态(重建), 测不到
# 这个缺口。所以磁盘写完整渲染(含 include 行); 内核那份为了能在 netns 里加载才剔掉 include。
NEW_FULL = render(tpl)
NEW = "\n".join(L for L in NEW_FULL.splitlines() if "nft-input.d" not in L)
OLD = "\n".join(L for L in NEW.splitlines() if 'iifname "tailscale0"' not in L)

run("%s ip netns del %s" % (SUDO, NS))
run("%s ip netns add %s" % (SUDO, NS))
work = tempfile.mkdtemp(prefix="pdgdrift-")
conf = os.path.join(work, "nftables.conf")


# nftlive 的 NFT_BIN 是裸 "nft"(走 PATH), 所以把一个转发到 netns 的垫片放在 PATH 最前,
# 生产判据就会在这个实验床的内核上取数 —— 不需要给产品加环境变量后门或测试特判。
SHIM = None


def make_shim(d):
    global SHIM
    SHIM = os.path.join(d, "bin")
    os.makedirs(SHIM, exist_ok=True)
    p = os.path.join(SHIM, "nft")
    with open(p, "w", encoding="utf-8") as f:
        # 垫片本身不再套 sudo: 这段判据已在 root 下跑, 再套一层会撞上 sudo 的 secure_path,
        # 表现成 "nft 返回非零" —— 看着像内核读不到, 其实是垫片没被执行。
        f.write('#!/bin/sh\nexec ip netns exec %s /usr/sbin/nft "$@"\n' % NS)
    os.chmod(p, 0o755)
    return SHIM


def nft(args):
    return run("%s ip netns exec %s nft %s" % (SUDO, NS, args))


def load(text):
    fd, p = tempfile.mkstemp(prefix="drift-", suffix=".nft", dir=work)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(p, 0o644)
    return nft("-f %s" % p)


def kernel_has_ts():
    p = nft("list table inet pdg")
    return p.returncode == 0 and "tailscale0" in p.stdout


try:
    print("── 一、造 C 态: 内核 OLD, 磁盘 NEW ──")
    if load(OLD).returncode != 0:
        bad("OLD 加载失败(夹具问题)"); raise SystemExit
    with open(conf, "w", encoding="utf-8") as f:
        f.write(NEW_FULL)
    os.chmod(conf, 0o644)
    if not kernel_has_ts():
        ok("内核是 OLD(无 tailscale0 排除规则)")
    else:
        bad("内核不是 OLD, 现场没造对")
    with open(conf, encoding="utf-8") as f:
        ok("磁盘是 NEW(含 tailscale0 %d 处)" % f.read().count('iifname "tailscale0"'))
    disk_sha0 = run("sha256sum %s" % conf).stdout.split()[0]
    disk_mt0 = os.stat(conf).st_mtime_ns

    print("\n── 二、调生产函数 ──")
    shim = make_shim(work)
    # PATH 要**整个换掉**而不是前置: sudo 的 secure_path 会把继承来的 PATH 覆盖,
    # 于是垫片明明在也用不上, 表现成"nft 返回非零" —— 看着像内核读不到。
    env = {**os.environ, "PATH": shim + ":/usr/sbin:/usr/bin:/sbin:/bin",
           "REPO_DIR": ROOT}
    fn = subprocess.run(
        'export REPO_DIR=%s; nft(){ %s ip netns exec %s /usr/sbin/nft "$@"; }; '
        'c_g(){ echo "    [prod] $*"; }; c_y(){ echo "    [prod] $*"; }; '
        'eval "$(sed -n "/^_rescue_load()/,/^}/p" %s/deploy/bot/pdg.sh)" 2>/dev/null; '
        # 判据 helper 必须一并抽出 —— 漏了它, 生产函数调到一个未定义的名字, shell 返回
        # command-not-found 的非零, 而那会被当成"内核未收敛"。前一轮就栽在这里:
        # 同一判据单独跑是 ok, 放进测试就红, 差的不是环境, 是这一行。
        'eval "$(sed -n "/^_fw_live_has_template_invariants()/,/^}/p" %s/deploy/bot/pdg.sh)"; '
        'eval "$(sed -n "/^migrate_firewall_template_sync()/,/^}/p" %s/deploy/bot/pdg.sh)"; '
        'migrate_firewall_template_sync %s; echo "rc=$?"'
        % (ROOT, SUDO, NS, ROOT, ROOT, ROOT, conf),
        shell=True, capture_output=True, text=True, executable="/bin/bash", env=env)
    rc = re.search(r"rc=(\d+)", fn.stdout or "")
    rc = int(rc.group(1)) if rc else -1
    print("       生产函数 rc=%d" % rc)
    for L in (fn.stdout or "").splitlines():
        if "[prod]" in L: print(L)

    print("\n── 三、内核必须收敛到 NEW ──")
    if kernel_has_ts():
        ok("内核已收敛: tailscale0 排除规则出现")
    else:
        bad("内核**仍是 OLD** —— 磁盘已新, 同步据磁盘判 no-op, 防火墙实际跑旧规则")
    if rc == 0:
        ok("返回 0")
    else:
        bad("返回 %d(收敛成功时应为 0)" % rc)

    print("\n── 四、C 态不得重写磁盘 ──")
    if run("sha256sum %s" % conf).stdout.split()[0] == disk_sha0:
        ok("磁盘内容未被改写")
    else:
        bad("磁盘被重写了 —— C 态只该 reload, 不该写盘")
    if os.stat(conf).st_mtime_ns == disk_mt0:
        ok("磁盘 mtime 未变")
    else:
        bad("磁盘 mtime 变了")
finally:
    run("%s ip netns del %s" % (SUDO, NS))
    shutil.rmtree(work, ignore_errors=True)

print("\n" + "─" * 62)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)

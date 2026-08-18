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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmpguard

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
work = tmpguard.mkdtemp(prefix="pdgdrift-")
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
        f.write('#!/bin/sh\nexec %s ip netns exec %s /usr/sbin/nft "$@"\n' % (SUDO, NS))
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

    def call_sync(count_calls=False, fail_load=False, fake_ok_load=False):
        """调生产函数一次, 返回 rc。count_calls=True 时把 nft 调用记进 calls.log,
        用来证明 B 态确实**没有**执行 nft -f —— 只看返回码分不出 no-op 和"重载了但结果一样"。"""
        log = os.path.join(work, "calls.log")
        open(log, "w").close()
        # 记账必须做在**那个 bash 函数里面**: 同名函数会遮蔽 PATH 上的垫片, 靠垫片记账
        # 日志恒空, "零 nft -f"就成了永远成立的空判据 —— 上一版正是这么假绿的。
        # 故障注入放在**那个 bash 函数**里(生产函数看到的就是它):
        #   fail_load    → `nft -f` 返回非零, 内核不动 —— 验"失败不冒充成功"
        #   fake_ok_load → `nft -f` 返回 0 但**什么都不加载** —— 验 reload 后的复核
        #                  真的在读内核, 而不是拿 nft 的返回码当结论
        inj = ""
        if fail_load:
            inj = 'if [ "$1" = "-f" ]; then return 1; fi; '
        elif fake_ok_load:
            inj = 'if [ "$1" = "-f" ]; then return 0; fi; '
        cmd = SYNC_CMD.replace('nft(){ printf', 'nft(){ ' + inj + 'printf', 1)
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           executable="/bin/bash", env={**env, "PDG_NFT_CALLS": log})
        m = re.search(r"rc=(\d+)", p.stdout or "")
        return int(m.group(1)) if m else -1

    # PATH 要**整个换掉**而不是前置: sudo 的 secure_path 会把继承来的 PATH 覆盖,
    # 于是垫片明明在也用不上, 表现成"nft 返回非零" —— 看着像内核读不到。
    env = {**os.environ, "PATH": shim + ":/usr/sbin:/usr/bin:/sbin:/bin",
           "REPO_DIR": ROOT}
    SYNC_CMD = (
        'export REPO_DIR=%s; nft(){ printf "%%s\\n" "$*" >> "$PDG_NFT_CALLS"; %s ip netns exec %s /usr/sbin/nft "$@"; }; '
        'c_g(){ echo "    [prod] $*"; }; c_y(){ echo "    [prod] $*"; }; '
        'eval "$(sed -n "/^_rescue_load()/,/^}/p" %s/deploy/bot/pdg.sh)" 2>/dev/null; '
        # 判据 helper 必须一并抽出 —— 漏了它, 生产函数调到一个未定义的名字, shell 返回
        # command-not-found 的非零, 而那会被当成"内核未收敛"。前一轮就栽在这里:
        # 同一判据单独跑是 ok, 放进测试就红, 差的不是环境, 是这一行。
        'eval "$(sed -n "/^_fw_live_has_template_invariants()/,/^}/p" %s/deploy/bot/pdg.sh)"; '
        'eval "$(sed -n "/^migrate_firewall_template_sync()/,/^}/p" %s/deploy/bot/pdg.sh)"; '
        'migrate_firewall_template_sync %s; echo "rc=$?"'
        % (ROOT, SUDO, NS, ROOT, ROOT, ROOT, conf))
    fn = subprocess.run(SYNC_CMD, shell=True, capture_output=True, text=True, executable="/bin/bash", env=env)
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
    # ── 五、B 态: 磁盘新、内核新 → 必须是真 no-op ────────────────────────────
    print("\n── 五、B 态必须零写盘零加载 ──")
    b_sha = run("sha256sum %s" % conf).stdout.split()[0]
    b_mt = os.stat(conf).st_mtime_ns
    calls0 = len(open(os.path.join(work, "calls.log"), encoding="utf-8").read().splitlines()) \
        if os.path.exists(os.path.join(work, "calls.log")) else 0
    rc_b = call_sync(count_calls=True)
    calls1 = len(open(os.path.join(work, "calls.log"), encoding="utf-8").read().splitlines())
    loads = sum(1 for L in open(os.path.join(work, "calls.log"), encoding="utf-8")
                if L.startswith("-f "))
    if rc_b == 0:
        ok("B 态返回 0")
    else:
        bad("B 态返回 %d(内核已满足不变量时应为 0)" % rc_b)
    if run("sha256sum %s" % conf).stdout.split()[0] == b_sha and os.stat(conf).st_mtime_ns == b_mt:
        ok("B 态零写盘(摘要与 mtime 均不变)")
    else:
        bad("B 态写盘了 —— 内核已是新版, 不该动磁盘")
    if loads == 0:
        ok("B 态零 nft -f(没有多余 reload)")
    else:
        bad("B 态执行了 %d 次 nft -f —— 应当完全 no-op" % loads)

    # ── 六、reload 失败必须返回非零, 且内核保持 before-image ──────────────────
    print("\n── 六、reload 失败注入 ──")
    load(OLD)
    rc_f = call_sync(fail_load=True)
    if rc_f != 0:
        ok("reload 失败 → 返回非零(%d), 不冒充成功" % rc_f)
    else:
        bad("reload 失败仍返回 0 —— 更新会据此当成已收敛")
    if not kernel_has_ts():
        ok("内核保持 before-image(仍是 OLD)")
    else:
        bad("内核被污染了")

    # ── 七、reload 成功但内核仍未收敛 → 复核必须抓住 ─────────────────────────
    print("\n── 七、注入'加载成功但没收敛' ──")
    load(OLD)
    rc_n = call_sync(fake_ok_load=True)
    if rc_n != 0:
        ok("加载返回 0 但内核未收敛 → 仍返回非零(%d)" % rc_n)
    else:
        bad("内核没收敛却返回 0 —— reload 后的复核形同虚设")

    # 八、reload 前那道 nft -c 守的是**不可达状态**, 故不设用例。
    #     C 态成立的前提是"磁盘 == 候选", 而候选是模板渲染的产物, 必然通过 nft -c。
    #     往磁盘写非法内容会让它不再等于候选, 函数就走 A 态(重建)去了 —— 那测的是别的分支。
    #     保留那道检查是纵深防御(有人手工改过盘上文件又恰好改回同样字节数?), 但诚实地说:
    #     它在当前调用路径下不可能被触发, 所以这里不假装验过它。

finally:
    run("%s ip netns del %s" % (SUDO, NS))
    shutil.rmtree(work, ignore_errors=True)

print("\n" + "─" * 62)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)

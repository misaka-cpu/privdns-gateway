#!/usr/bin/env python3
"""`detect-internal-range.sh` 不得把 tailnet 地址推成内网卡网段。

── 这支为什么存在 ──────────────────────────────────────────────────────────────
Tailscale 给节点分的地址在 `100.64.0.0/10` —— 与运营商 CGNAT(RFC 6598)**完全同段**。
本项目把 CGNAT 当合法内网来源(真有用户的 SIM/APN 就在这个段里), 于是探测器只看源地址
根本分不开"手机经内网卡来的包"和"tailnet 管理流量"。

后果不是探测器报错, 而是它**安静地选中一个 tailnet 地址**并推成 /16 写进
`PDG_INTERNAL_CIDR`。nft 的 REDIRECT 随即改挂到 tailnet 段上 —— 管理流量被送进透明代理。
触发只需要有人跑一次 `pdg detect-cidr`(公开的用户命令), 且 tailnet 上恰好有 peer 对本机
发过 ICMP 或 53/80/443/853。

`e759d0d` 的修法是**按入口接口排除, 不按地址段排除** —— 后者会连真实运营商 CGNAT 用户
一起误伤, 是本项目明确不接受的做法。防火墙那一半有 test-tailscale-ingress-isolation.py
盯着(13 格, 真 netns); 探测器这一半在本支之前**一条判据都没有**。

── 判据怎么造 ──────────────────────────────────────────────────────────────────
不需要真 Tailscale: 在 PATH 前面放 `tcpdump` 与 `ip` 的桩, 由桩决定
  ① 抓到的样本长什么样(接口名 + 源地址);
  ② 机器上有没有 tailscale0。
这样每一格都能精确构造, 且**两类样本的源地址都在 100.64.0.0/16 里** —— 只看源地址的
实现对它们无从区分, 必须真的用上入口接口才可能过关。
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "lib", "detect-internal-range.sh")

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


# ── 样本 ──────────────────────────────────────────────────────────────────────
# 两个源都在 100.64.0.0/10(所以只看"是不是 CGNAT"分不开), 但**第二段不同**——
# 推成 /16 之后一个是 100.100.0.0/16、一个是 100.64.0.0/16, 于是"到底选中了谁"看得出来。
# 第一版把两者都放在 100.64.x, 推完同值, 判据根本分不开谁被选中 —— 那样第 1 格是碰巧绿的。
TAILNET_SRC = "100.100.9.9"      # tailnet peer(Tailscale 实际用 100.64–127)
TAILNET_CIDR = "100.100.0.0/16"
PHONE_SRC = "100.64.7.7"         # 运营商 CGNAT 下的手机
PHONE_CIDR = "100.64.0.0/16"
PHYS_IF = "eth0"

# 目的地址必须是**公网**: 脚本用 `grep -oE` 把一行里所有 IP 都抽出来, 源和目的一视同仁。
# 第一版写了 10.0.0.1 当目的, 它落在私网段里, 于是每行都白送一个 10.0.0.x 样本 ——
# 样本量一多就盖过真正要比的东西(实测改坏后选出的是 10.0.0.0/16, 与 tailnet 无关)。
DST = "203.0.113.9"

def line(iface, src):
    """tcpdump -i any 的一行(4.99+ 把接口名放在第二个字段)。"""
    return ("12:00:00.000000 %s In IP %s.12345 > %s.853: "
            "Flags [P.], seq 1:2, length 1" % (iface, src, DST))


def stub_env(tcpdump_lines, has_ts, with_ifname=True):
    """造一套桩: tcpdump 吐指定样本, ip 决定 tailscale0 在不在。"""
    d = tmpguard.mkdtemp(prefix="pdg-detectns-")
    stub = os.path.join(d, "stub")
    os.makedirs(stub)
    body = "\n".join(tcpdump_lines)
    if not with_ifname:
        # 老 tcpdump: -i any 不打接口名。把第二个字段抹掉, 模拟那种输出形态。
        body = "\n".join(re.sub(r"^(\S+) \S+ (In|Out) ", r"\1 \2 ", l) for l in tcpdump_lines)
    with open(os.path.join(stub, "tcpdump"), "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\ncat <<'PDGEOF'\n%s\nPDGEOF\n" % body)
    with open(os.path.join(stub, "ip"), "w", encoding="utf-8") as fh:
        # `ip -o link show tailscale0` 的退出码就是"有没有这个接口"
        fh.write("#!/bin/sh\n"
                 'case "$*" in *tailscale0*) exit %d;; esac\nexit 0\n'
                 % (0 if has_ts else 1))
    for f in ("tcpdump", "ip"):
        os.chmod(os.path.join(stub, f), 0o755)
    env = dict(os.environ, PATH=stub + os.pathsep + os.environ["PATH"])
    return env


def run_detect(env, script=None):
    p = subprocess.run(["bash", script or SCRIPT, "1"],
                       capture_output=True, text=True, env=env, timeout=60)
    return p.returncode, (p.stdout or "").strip(), (p.stderr or "")


# ── 一、tailnet 样本占多数时, 绝不能选中它 ────────────────────────────────────
env = stub_env([line("tailscale0", TAILNET_SRC)] * 5 + [line(PHYS_IF, PHONE_SRC)], has_ts=True)
rc, out, _ = run_detect(env)
if out == TAILNET_CIDR:
    bad("tailnet 样本被选中并推成 %s —— 这正是 P0 的原始形态" % out)
elif out == PHONE_CIDR:
    ok("tailnet 样本(5 条)被排除, 选中的是物理口那条 → %s" % out)
else:
    bad("既没选中 tailnet 也没选中物理口: rc=%s out=%r" % (rc, out))

# ── 二、反向格: 同样的 CGNAT 地址走物理口时必须正常选出 ──────────────────────
# 证明判据认的是**入口接口**, 不是"见 100.64 就拒" —— 后者会误伤真实运营商用户。
env = stub_env([line(PHYS_IF, PHONE_SRC)] * 4, has_ts=True)
rc, out, _ = run_detect(env)
if rc == 0 and out == PHONE_CIDR:
    ok("同段地址走物理口 → 正常推出 %s(没有误伤真实运营商 CGNAT)" % out)
else:
    bad("物理口的 CGNAT 样本被拒了: rc=%s out=%r —— 那会误伤运营商用户" % (rc, out))

# ── 三、有 tailscale0 但拿不到接口名 → 必须 fail-closed ──────────────────────
# 老 tcpdump 的 -i any 不打接口名, 于是"入口接口"这个事实拿不到, 无从排除。
# 此时唯一安全的动作是拒绝猜, 而不是赌一把。
env = stub_env([line("tailscale0", TAILNET_SRC)] * 3, has_ts=True, with_ifname=False)
rc, out, err = run_detect(env)
if rc != 0 and out == "":
    ok("有 tailscale0 且拿不到接口名 → 拒绝猜(rc=%s, 空输出)" % rc)
else:
    bad("拿不到接口名却仍然给出了结果: rc=%s out=%r —— 那是在赌" % (rc, out))
if "不猜" in err or "无法把 tailnet" in err:
    ok("拒绝时说清了原因并给出手输路径")
else:
    bad("拒绝了却没说为什么, 运维无从处置")

# ── 四、没有 tailscale0 时行为与改动前等价 ───────────────────────────────────
# 不能因为"装没装 Tailscale"改变没装那批机器的行为。
env = stub_env([line(PHYS_IF, PHONE_SRC)] * 4, has_ts=False, with_ifname=False)
rc, out, _ = run_detect(env)
if rc == 0 and out == PHONE_CIDR:
    ok("没有 tailscale0 + 老 tcpdump → 照常工作(未因本修复改变行为)")
else:
    bad("没装 Tailscale 的机器被连累了: rc=%s out=%r" % (rc, out))

# ── 五、私网段照常 ───────────────────────────────────────────────────────────
env = stub_env([line(PHYS_IF, "172.22.5.5")] * 4, has_ts=True)
rc, out, _ = run_detect(env)
(ok if (rc == 0 and out == "172.22.0.0/16") else bad)(
    "普通私网段不受影响 → %s" % out if rc == 0 else "私网段探测被破坏: rc=%s out=%r" % (rc, out))

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

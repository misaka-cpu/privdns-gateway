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

# ── 六、DERP 流量不得把结果拽向本机所在段 ────────────────────────────────────
# Tailscale 的 DERP 中继走 TCP 443, 正好落在脚本的 BPF 端口集里。公网对端会被私网/CGNAT
# 分类挡掉, 但**本机自己的 tailnet 地址每个包都要记一次** —— 它在入站包里是目的、在出站包
# 里是源, 老写法把整行的地址一视同仁地捞出来, 两头都算。实测 40 秒本机拿 324 票、tailnet
# 只有 176 票, 结果被拽向"本机所在段"。
#
# 注意这跟前五格测的**不是同一件事**: 接口排除挡的是"选中 tailnet 段", 这里的偏置来自
# eth0 上的流量, 接口排除完全挡不住。
LOCAL_TS = "100.98.1.1"          # 本机自己的 tailnet 地址(DERP 会话的本地端)
DERP_PUB = "203.0.113.77"        # DERP 中继, 公网


def derp_pair(local, peer):
    """一来一回两行 DERP 流量。两行里本机地址各出现一次 —— 老写法就是这么被灌票的。"""
    return [
        "12:00:00.000000 %s In IP %s.443 > %s.44444: Flags [P.], seq 1:2, length 1"
        % (PHYS_IF, peer, local),
        "12:00:00.000001 %s Out IP %s.44444 > %s.443: Flags [P.], seq 1:2, length 1"
        % (PHYS_IF, local, peer),
    ]


derp_lines = []
for _ in range(20):
    derp_lines += derp_pair(LOCAL_TS, DERP_PUB)
# 手机样本刻意只给 3 条: 真实现场就是这个比例 —— 探测窗口里 DERP 的心跳远多于手机的查询。
sample = derp_lines + [line(PHYS_IF, PHONE_SRC)] * 3

env = stub_env(sample, has_ts=True)
rc, out, _ = run_detect(env)
if out == PHONE_CIDR:
    ok("DERP 灌了 %d 票、手机只有 3 票, 仍选中手机那段 → %s" % (len(derp_lines), out))
elif out == "100.98.0.0/16":
    bad("被 DERP 拽到本机所在段 100.98.0.0/16 —— 偏置仍在")
else:
    bad("既没选中手机段也没选中本机段: rc=%s out=%r" % (rc, out))

# 反向对照: 修复前那一版必须在同一组样本上被拽偏。不然这一格没有判别力 ——
# 样本比例只要构造得不够狠, 新旧两版都会给出正确答案, 而它看起来照样是绿的。
# 对照版由**当前源码做最小反向补丁**得到, 不用 `git show HEAD:` —— 那只在修复尚未提交时
# 成立, 提交之后拿到的就是修好的版本, 这一格会安静地失去判别力却照样显示绿。
# 反向补丁只改一行: 把"只数入站包的源地址"退回"整行地址一视同仁", 那正是偏置的来源。
_cur = open(SCRIPT, encoding="utf-8").read()
_Q = chr(39)                     # 单引号: 直接写会和外层引号打架
_NEWX = "EXTRACT=" + _Q + '$2 != ts && $3 == "In" { print $5 }' + _Q
_OLDX = "EXTRACT=" + _Q + '$2 != ts { print }' + _Q
if _cur.count(_NEWX) != 1:
    bad("反向补丁打空: 找不到唯一的入站源地址提取式 —— 产品换写法了, 这格必须跟着改")
else:
    OLD_SCRIPT = os.path.join(tmpguard.mkdtemp(prefix="pdg-detectold-"), "old.sh")
    with open(OLD_SCRIPT, "w", encoding="utf-8") as fh:
        fh.write(_cur.replace(_NEWX, _OLDX))
    rc_o, out_o, _ = run_detect(stub_env(sample, has_ts=True), script=OLD_SCRIPT)
    if out_o == out:
        bad("反向对照: 旧写法在同一组样本上给出同样的 %r —— 这一格没有判别力" % out_o)
    else:
        ok("反向对照: 旧写法被同一组样本拽到 %s(证明这格真在测偏置)" % (out_o or "空"))

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

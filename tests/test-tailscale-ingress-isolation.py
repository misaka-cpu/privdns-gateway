#!/usr/bin/env python3
"""Tailscale 入口隔离: PDG 数据面必须同时看「来源网段」和「入口接口」。

── 为什么需要这支 ────────────────────────────────────────────────────────────
Tailscale 给节点分配 100.64.0.0/10 的地址, 而**运营商 SIM/APN 也合法使用同一个段**
(RFC 6598 CGNAT)。项目原本只按 `ip saddr $PDG_INTERNAL_CIDR` 判断要不要接管, 不看包
从哪个接口进来 —— 于是这两类来源在规则眼里长得一模一样。

后果不是理论问题: Tailscale 起来之后跑一次 `pdg detect-cidr`(公开的用户命令), 探测器
在 `any` 接口上抓到 tailnet 的包, 就可能把 100.64.x.x 推成 /16 写进 PDG_INTERNAL_CIDR。
此后 nft 的 REDIRECT 规则改挂到 tailnet 段上, **tailnet 管理流量被送进 mihomo 透明代理**。

**不能靠全局禁掉 100.64/10 来修** —— 那会打断真实运营商 CGNAT 用户的支持。正确的不变量是:

    是否进入 PDG 数据面 = 来源网段 **且** 入口接口;
    任何从 tailscale0 进来的流量都不得进入 SIM/APN 的接管链。

── 这支怎么证 ───────────────────────────────────────────────────────────────
关键是**证明判据认的是接口这个事实, 而不是换了个源 IP**。所以两侧客户端的源地址
**都落在同一个配置好的 CIDR 内**(100.64.0.0/16), 唯一的差别是从哪个接口进来:

    tsclient  100.64.1.2  ──veth──>  box:tailscale0   ← 必须**不**被接管
    phyclient 100.64.2.2  ──veth──>  box:wan0         ← 必须**照旧**被接管(合法运营商 CGNAT)

两个地址都在 100.64.0.0/16 里, 所以只看源地址的判据对它们无从区分。

用真 netns + 真 veth + 真 nft 加载 + 真流量。纯字符串比对冒充不了这个事实。

不复制真机的完整防火墙、真实 IP 或用户自定义内容; 全部在一次性 netns 里跑完就拆。
"""
import os
import re
import shutil
import subprocess
import tempfile
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TPL = os.path.join(ROOT, "deploy", "firewall", "nftables-mihomo.conf")

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


# ── 环境门 ────────────────────────────────────────────────────────────────────
# 这支必须有真内核才有意义。环境不足就 SKIP 并说明白为什么, 不假装验过。
def have_env():
    if os.geteuid() != 0 and run("sudo -n true").returncode != 0:
        return False, "需要 root 或免密 sudo 才能建 netns / 加载 nft"
    # nft/ip 通常装在 /usr/sbin, 非 root 的 PATH 里没有 —— 只用 which 会把"权限不足"
    # 误报成"没装", 于是这支在本可以跑的机器上静默跳过。两处都找。
    for tool in ("ip", "nft"):
        if not (shutil.which(tool) or any(
                os.path.exists(os.path.join(d, tool))
                for d in ("/usr/sbin", "/sbin", "/usr/local/sbin"))):
            return False, "缺少 %s" % tool
    p = run("%s ip netns add pdgts_probe" % SUDO)
    if p.returncode != 0:
        return False, "内核不允许建 netns: %s" % (p.stderr or "").strip()[:60]
    run("%s ip netns del pdgts_probe" % SUDO)
    return True, ""


SUDO = "" if os.geteuid() == 0 else "sudo -n"

BOX, TSC, PHY = "pdgts_box", "pdgts_tsc", "pdgts_phy"
# 配置给 PDG 的内网段。**两个客户端地址都落在它里面** —— 这是这支测试的全部要害:
# 判据若只看源地址, 两侧完全不可区分, 必须靠入口接口才能分开。
CIDR = "100.64.0.0/16"
# 两条链路用各自的 /30: box 上两个接口若同网段, 回包该走哪个接口是歧义的(实测会让
# 物理侧假红)。/30 让路由确定, 而地址仍在上面那个 /16 内, 要害不受影响。
TS_ADDR, BOX_TS = "100.64.1.2", "100.64.1.1"
PHY_ADDR, BOX_PHY = "100.64.2.2", "100.64.2.1"
# ULA, 只用于验证模板里那条 `ip6 nexthdr icmpv6 accept` 的契约; 不涉及任何真实地址。
TS_ADDR6, BOX_TS6 = "fd00:64::2", "fd00:64::1"


def cleanup():
    for ns in (BOX, TSC, PHY):
        run("%s ip netns del %s" % (SUDO, ns))


def build_lab():
    """三个 netns: box(网关) + tsclient(经 tailscale0) + phyclient(经 wan0)。"""
    cleanup()
    cmds = [
        # netns
        "ip netns add %s" % BOX, "ip netns add %s" % TSC, "ip netns add %s" % PHY,
        # veth: box.tailscale0 <-> tsclient.eth0
        "ip link add tailscale0 netns %s type veth peer name eth0 netns %s" % (BOX, TSC),
        # veth: box.wan0 <-> phyclient.eth0
        "ip link add wan0 netns %s type veth peer name eth0 netns %s" % (BOX, PHY),
        # 地址与启用
        "ip -n %s addr add %s/30 dev tailscale0" % (BOX, BOX_TS),
        "ip -n %s addr add %s/30 dev wan0" % (BOX, BOX_PHY),
        "ip -n %s link set tailscale0 up" % BOX,
        "ip -n %s link set wan0 up" % BOX,
        "ip -n %s link set lo up" % BOX,
        "ip -n %s addr add %s/30 dev eth0" % (TSC, TS_ADDR),
        "ip -n %s link set eth0 up" % TSC,
        "ip -n %s link set lo up" % TSC,
        "ip -n %s addr add %s/30 dev eth0" % (PHY, PHY_ADDR),
        "ip -n %s link set eth0 up" % PHY,
        "ip -n %s link set lo up" % PHY,
        # IPv6: 模板有 `ip6 nexthdr icmpv6 accept`, 契约要求它照旧, 所以实验床也得能发 v6。
        # 用 ULA, 不碰任何真实地址。
        "ip -n %s addr add %s/64 dev tailscale0 nodad" % (BOX, BOX_TS6),
        "ip -n %s addr add %s/64 dev eth0 nodad" % (TSC, TS_ADDR6),
    ]
    for c in cmds:
        p = run("%s %s" % (SUDO, c))
        if p.returncode != 0:
            return "建实验床失败: %s → %s" % (c, (p.stderr or "").strip()[:80])
    return ""


def render(tpl_text):
    """用测试值渲染真实模板。不使用任何生产配置。"""
    return (tpl_text
            .replace("__INTERNAL_CIDR__", CIDR)
            .replace("__SSH_PORT__", "22")
            .replace("__RESCUE_PORT__", "8446"))


def load_nft(text):
    """把渲染后的规则加载进 box netns。include 那行在实验床里没有对应目录, 剔掉。

    临时文件必须唯一: 用固定名字(如 /tmp/pdgts-rules.nft)时, 上一轮非 root 跑留下的
    文件会让这一轮的 root 写不进去 —— fs.protected_regular 不许 root 打开粘滞目录里
    别人拥有的文件。表现是 PermissionError, 看着像权限不够, 其实是没清理干净。
    """
    text = "\n".join(L for L in text.splitlines() if "nft-input.d" not in L)
    fd, path = tempfile.mkstemp(prefix="pdgts-rules-", suffix=".nft")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(path, 0o644)          # netns exec 下的 nft 要读得到
        p = run("%s ip netns exec %s nft -f %s" % (SUDO, BOX, path))
        return p.returncode == 0, (p.stderr or "").strip()
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def probe_tcp(ns, dst, port, timeout=3):
    """从 ns 发起一次 TCP 连接, 返回是否连上。"""
    p = run("%s ip netns exec %s timeout %d bash -c "
            "'</dev/tcp/%s/%d' 2>/dev/null" % (SUDO, ns, timeout, dst, port))
    return p.returncode == 0


def probe_icmp(ns, dst, timeout=3):
    """从 ns ping 一次。走真实 ICMP echo, 不是端口探测。"""
    p = run("%s ip netns exec %s ping -c 1 -W %d -n %s" % (SUDO, ns, timeout, dst))
    return p.returncode == 0


def probe_icmp6(ns, dst, timeout=3):
    """ICMPv6 echo。模板里有 `ip6 nexthdr icmpv6 accept`, 契约要求它照旧。"""
    p = run("%s ip netns exec %s ping -6 -c 1 -W %d -n %s" % (SUDO, ns, timeout, dst))
    return p.returncode == 0


def listener_start(port):
    """在 box 里起一个 TCP 监听, 返回 Popen。"""
    cmd = "%s ip netns exec %s python3 -c \"" % (SUDO, BOX) + (
        "import socket;s=socket.socket();s.setsockopt(1,2,1);"
        "s.bind(('0.0.0.0',%d));s.listen(16);" % port +
        "__import__('time').sleep(3600)\"")
    return subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)


print("══ Tailscale 入口隔离(真 netns + 真 veth + 真 nft)══\n")

envok, why = have_env()
if not envok:
    skip("整支跳过 —— %s" % why)
    print("\n" + "─" * 66)
    print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
    print("SKIP 归因: 本支必须在真内核里跑; 上面这条说明了缺什么。")
    sys.exit(0)

with open(TPL, encoding="utf-8") as f:
    TPL_TEXT = f.read()

# ── 静态门: 规则必须存在, 且必须排在来源匹配之前 ──────────────────────────────
print("── 一、模板静态判据(顺序是安全属性, 不只是风格)──")

lines = [L.rstrip() for L in TPL_TEXT.splitlines()]


def chain_body(name):
    out, inside, depth = [], False, 0
    for L in lines:
        if re.match(r"^\s*chain\s+%s\s*\{" % re.escape(name), L):
            inside, depth = True, 1
            continue
        if inside:
            depth += L.count("{") - L.count("}")
            if depth <= 0:
                break
            out.append(L)
    return out


for chain in ("prerouting", "input"):
    body = chain_body(chain)
    if not body:
        bad("%s: 模板里找不到这条链" % chain)
        continue
    ex = [i for i, L in enumerate(body) if 'iifname "tailscale0"' in L]
    src = [i for i, L in enumerate(body) if "ip saddr __INTERNAL_CIDR__" in L]
    if not ex:
        bad("%s: 没有 iifname \"tailscale0\" 的排除规则 —— tailnet 会被当成内网来源" % chain)
    elif not src:
        ok("%s: 有排除规则(该链无来源匹配)" % chain)
    elif min(ex) < min(src):
        ok("%s: 排除规则排在来源匹配之前(第 %d 行 < 第 %d 行)" % (chain, min(ex), min(src)))
    else:
        bad("%s: 排除规则排在来源匹配**之后**(第 %d 行 > 第 %d 行) —— "
            "先匹配再排除等于没排除" % (chain, min(ex), min(src)))

# iif 与 iifname 不是一回事: iif 在加载时解析成接口索引, 接口不存在会导致整份规则加载失败。
# 生产机在装 Tailscale **之前**就必须能加载这份规则, 所以只能用 iifname(运行时按名字匹配)。
if re.search(r'^\s*iif\s+"tailscale0"', TPL_TEXT, re.M):
    bad("用了 iif \"tailscale0\" —— 接口不存在时整份规则加载失败, 必须用 iifname")
else:
    ok("用 iifname 而非 iif(Tailscale 未安装时规则仍可加载)")

# ── 动态门: 真流量 ────────────────────────────────────────────────────────────
print("\n── 二、真 netns 流量(两侧源地址都在 %s 内, 只差接口)──" % CIDR)

err = build_lab()
if err:
    bad(err)
    cleanup()
    print("\n" + "─" * 66)
    print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
    sys.exit(1)

loaded, lerr = load_nft(render(TPL_TEXT))
if not loaded:
    bad("规则加载失败(接口不存在时也必须能加载): %s" % lerr[:120])
    cleanup()
    print("\n" + "─" * 66)
    print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
    sys.exit(1)
ok("渲染后的真实模板在 box netns 里加载成功")

lis = listener_start(7893)          # REDIRECT 的落点
lis53 = listener_start(53)          # 接管链的 DNS 口
time.sleep(1.0)

try:
    # 2a. 物理接口上的合法运营商 CGNAT: 必须照旧被接管(REDIRECT 到 7893)
    if probe_tcp(PHY, BOX_PHY, 80):
        ok("物理接口 %s(合法运营商 CGNAT)→ tcp/80 被 REDIRECT 接管" % PHY_ADDR)
    else:
        bad("物理接口 %s 的 tcp/80 没有被接管 —— 破坏了既有运营商支持" % PHY_ADDR)

    # 2b. 同一个段, 但从 tailscale0 进来: 绝不能被接管
    if probe_tcp(TSC, BOX_TS, 80):
        bad("tailscale0 上的 %s → tcp/80 **被 REDIRECT 送进了透明代理**(P0 未修复)"
            % TS_ADDR)
    else:
        ok("tailscale0 上的 %s → tcp/80 未进入 REDIRECT" % TS_ADDR)

    # 2c. 接管链的 DNS 口: 物理侧通
    if probe_tcp(PHY, BOX_PHY, 53):
        ok("物理接口 → tcp/53 放行(SIM/APN DNS 接管照旧)")
    else:
        bad("物理接口 → tcp/53 不通 —— 破坏了既有 DNS 接管")

    # 2d. 接管链的 DNS 口: tailnet 侧必须不通
    if probe_tcp(TSC, BOX_TS, 53):
        bad("tailscale0 → tcp/53 **进入了 SIM/APN DNS 接管链**(P0 未修复)")
    else:
        ok("tailscale0 → tcp/53 未进入 DNS 接管链")

    # 2e. SSH 总闸不受影响: 两侧都应放行(规则不带 saddr, 排在排除规则之前)
    ssh = listener_start(22)
    time.sleep(0.8)
    a, b = probe_tcp(PHY, BOX_PHY, 22), probe_tcp(TSC, BOX_TS, 22)
    ssh.kill()
    if a and b:
        ok("SSH 总闸未被改动: 物理侧与 tailnet 侧都放行")
    else:
        bad("SSH 放行被改坏(物理=%s tailnet=%s) —— 本轮明确不得动它" % (a, b))

    # 2f. **ICMP 契约**: 模板本来就有 `ip protocol icmp accept`, 隔离不得把它吃掉。
    #     tailnet 是管理通道, ping 是最基本的可达性手段 —— 这条不是"顺便还能用",
    #     而是冻结下来的验收项。排除规则必须排在 ICMP 放行**之后**才能同时满足两边。
    if probe_icmp(TSC, BOX_TS):
        ok("tailnet ICMP 可达(管理通道的既有契约保持)")
    else:
        bad("tailnet ICMP **不通** —— 隔离规则排在 ICMP 放行之前, 把它一起吃掉了")
    if probe_icmp(PHY, BOX_PHY):
        ok("物理接口 ICMP 可达(既有行为不变)")
    else:
        bad("物理接口 ICMP 不通 —— 改坏了既有 ICMP 放行")

    # 2g. ICMPv6 同一份契约(模板有 `ip6 nexthdr icmpv6 accept`)
    if probe_icmp6(TSC, BOX_TS6):
        ok("tailnet ICMPv6 可达(ip6 nexthdr icmpv6 契约保持)")
    else:
        bad("tailnet ICMPv6 **不通** —— ICMPv6 放行被隔离规则吃掉了")

    # 2h. 受保护端口全集: tailnet 一律进不去。上面单验了 53, 这里把其余几个补齐,
    #     免得"只挡住了 53"被当成"数据面隔离到位"。
    guarded = []
    for port in (81, 853, 7893, 8445, 8446):
        lp = listener_start(port)
        time.sleep(0.5)
        reachable = probe_tcp(TSC, BOX_TS, port)
        lp.kill()
        if reachable:
            guarded.append(port)
    if guarded:
        bad("tailnet 能连上受保护端口 %s —— 数据面隔离不完整" % guarded)
    else:
        ok("tailnet 到 81/853/7893/8445/8446 全部被 policy drop 收口")
finally:
    lis.kill()
    lis53.kill()
    cleanup()

print("\n" + "─" * 66)
print("通过 %d, 失败 %d, 跳过 %d" % (npass, nfail, nskip))
sys.exit(1 if nfail else 0)

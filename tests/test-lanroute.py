#!/usr/bin/env python3
"""门一(子网路由重叠拒绝)的判据测试。

**每条判据都配一条"空测"**: 把触发条件拿掉之后必须放行。只测"会拒"不够 ——
一个永远返回"拒绝"的实现也能让那些用例全绿, 而它在真机上的表现是谁都用不了。

反过来同样要紧: 作者自己的家用段(192.168.100.0/24)与网关的 172.22.0.0/16 天然不相交,
在真机上跑门一会一路放行。所以**不能拿"真机没报错"当作门一在工作的证据**, 必须另造
一个确实相交的样本 —— 见 test_internal_overlap_has_teeth。
"""
import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "deploy/bot/lanroute.py"

spec = importlib.util.spec_from_file_location("lanroute", MOD)
lr = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(lr)

INTERNAL = "172.22.0.0/16"


def tags(advertised, internal=INTERNAL, locals_=()):
    """跑一次判定, 返回命中的标识集合(不比中文文案 —— 文案会改)。"""
    locs = [lr.parse_net(x) for x in locals_]
    inet = lr.parse_net(internal) if internal else None
    out = lr.judge([advertised], inet, locs)
    if not out:
        return set()
    return {t for _, reasons in out for t, _ in reasons}


# ── ① 干净样本必须放行 ────────────────────────────────────────────────────────
assert tags("192.168.1.0/24") == set()
assert tags("192.168.100.0/24") == set()          # 作者家里的真实段
assert tags("10.9.9.0/24", locals_=["10.0.0.5/24"]) == set()

# ── ② 默认路由 ───────────────────────────────────────────────────────────────
assert lr.R_DEFAULT in tags("0.0.0.0/0")
assert lr.R_DEFAULT in tags("::/0")
# 空测: 只要不是 /0 就不该按默认路由拒。0.0.0.0/1 大得离谱但性质不同 ——
# 它不会把网关变成出口节点, 判据不能把"大"和"默认路由"混为一谈。
assert lr.R_DEFAULT not in tags("0.0.0.0/1")

# ── ③ 与内网卡来源段相交 ─────────────────────────────────────────────────────
assert lr.R_INTERNAL in tags("172.22.0.0/24")     # 被包含
assert lr.R_INTERNAL in tags("172.22.0.0/16")     # 完全相同
assert lr.R_INTERNAL in tags("172.0.0.0/8")       # 反过来包含内网段


def test_internal_overlap_has_teeth():
    """这条判据的**牙**: 相邻但不相交的段必须放行, 相交的必须拒。

    两者只差一个 bit —— 如果实现写成"前两段相同就算相交"之类的近似, 这里会立刻塌。
    """
    assert tags("172.21.255.0/24") == set(), "相邻不相交, 不该拒"
    assert lr.R_INTERNAL in tags("172.22.255.0/24"), "在 /16 之内, 必须拒"
    # 边界的两头各取一个
    assert lr.R_INTERNAL in tags("172.22.0.0/32")
    assert lr.R_INTERNAL in tags("172.22.255.255/32")
    assert tags("172.23.0.0/32") == set()


test_internal_overlap_has_teeth()

# 空测: 没给内网段时, 这条判据不该凭空成立
assert lr.R_INTERNAL not in tags("172.22.0.0/24", internal=None)

# ── ④ 与本机接口网段相交 ─────────────────────────────────────────────────────
assert lr.R_LOCAL in tags("10.0.0.0/24", locals_=["10.0.0.5/24"])
assert lr.R_LOCAL in tags("10.0.0.0/8", locals_=["10.0.0.5/24"])
# 空测: 不给本机接口就不该有这条
assert lr.R_LOCAL not in tags("10.0.0.0/24")
# 空测: 接口在别的段, 放行
assert tags("10.0.0.0/24", locals_=["192.168.50.7/24"]) == set()

# ── ⑤ Tailscale 自身段 ───────────────────────────────────────────────────────
assert lr.R_TAILNET in tags("100.64.0.0/10")
assert lr.R_TAILNET in tags("100.100.0.0/16")     # /10 之内
assert lr.R_TAILNET in tags("fd7a:115c:a1e0::/48", internal=None)
# 空测: 100.128/9 在 100.64/10 之外(CGNAT 只到 100.127.255.255)
assert lr.R_TAILNET not in tags("100.128.0.0/9")

# ── ⑥ 环回 ───────────────────────────────────────────────────────────────────
assert lr.R_LOOPBACK in tags("127.0.0.0/8")
assert lr.R_LOOPBACK in tags("127.0.0.1/32")
assert lr.R_LOOPBACK not in tags("128.0.0.0/8")

# ── ⑦ IPv4 / IPv6 不许互相误判 ───────────────────────────────────────────────
# 不同协议族之间谈"相交"没有意义; 实现里若漏了 version 判断, ipaddress 会直接抛异常,
# 那会变成一个看起来像 bug 的崩溃而不是一条清楚的拒绝理由。
assert tags("2001:db8::/32", internal=INTERNAL) == set()
assert tags("192.168.1.0/24", internal=None, locals_=["2001:db8::1/64"]) == set()

# ── ⑧ 一个网段同时踩中多条时要全列出来 ──────────────────────────────────────
multi = tags("172.22.0.0/16", locals_=["172.22.5.1/24"])
assert lr.R_INTERNAL in multi and lr.R_LOCAL in multi, multi

# ── ⑨ 形态不合法 ─────────────────────────────────────────────────────────────
assert "bad-cidr" in tags("192.168.1.0/33")
assert "bad-cidr" in tags("不是网段")
# 带主机位的写法按网段取整, 不算错 —— "接口地址所在网段"本来就是这个意思
assert tags("192.168.7.9/24") == set()

# ── ⑩ 命令行契约(pdg lan 与 doctor 都按退出码分支) ──────────────────────────
def cli(*args):
    p = subprocess.run([sys.executable, str(MOD)] + list(args),
                       capture_output=True, text=True)
    return p.returncode, p.stdout


rc, out = cli("judge", "--internal", INTERNAL, "192.168.1.0/24")
assert rc == 0 and out.strip() == "", (rc, out)

rc, out = cli("judge", "--internal", INTERNAL, "172.22.9.0/24")
assert rc == 2 and lr.R_INTERNAL in out, (rc, out)

rc, out = cli("judge", "--internal", "垃圾", "192.168.1.0/24")
assert rc == 3, (rc, out)

# 一次判多个: 只要有一个被拒, 整体就是 2 —— 调用方不必逐个跑
rc, out = cli("judge", "--internal", INTERNAL, "192.168.1.0/24", "0.0.0.0/0")
assert rc == 2 and lr.R_DEFAULT in out, (rc, out)

# 空测: 什么都不给, 不该报错
rc, out = cli("judge", "--internal", INTERNAL)
assert rc == 0, (rc, out)

print("test-lanroute.py: OK")

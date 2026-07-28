#!/usr/bin/env python3
"""监听地址(PDG_RESCUE_BIND)与应用层来源校验的判定逻辑。

两件事在这里被钉死, 它们都是 .200 实机验出来的:

一、**监听地址与来源段是两回事**。来源段是客户端所在的网(运营商内网卡), 网关自己的地址在
    另一张网上 —— "在来源段里挑一个本机地址"在真实网关上什么也挑不到, 救援平面于是在它唯一
    被需要的拓扑上根本起不来。所以监听地址必须显式配置, 且绝不回落到 0.0.0.0。

二、既然监听地址可能是**全局可路由**的, nft 之外必须有第二层来源限制。它只认内核给的 peer
    地址: X-Forwarded-For / Forwarded 由客户端随便填, 拿它做访问控制等于没有访问控制。
    判定放在 accept 之后、TLS 握手之前 —— 非允许来源连证书都拿不到, 更谈不上登录页与鉴权。

这里直接测判定函数本身(不起服务): 真流量路径由 tests/e2e-rescue-10b.sh 在真 systemd/nft
上验, 两者各管一段, 谁也不替谁。
"""
import ipaddress
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def load_rescue():
    """只取需要的两个符号, 不启动服务(import 时不会起监听)。"""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "rescue_mod", os.path.join(ROOT, "deploy", "rescue", "rescue.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


R = load_rescue()

# ── 1. 应用层来源校验 ──────────────────────────────────────────────────────
print("── 1. 来源校验 ──")
g = R.SourceGuard("172.22.0.0/16")
cases = [
    (("172.22.99.9", 5000), True, "来源段内 → 放行"),
    (("172.22.0.1", 5000), True, "来源段内(边界)→ 放行"),
    (("192.168.77.9", 5000), False, "来源段外 → 拒绝"),
    (("177.0.142.7", 5000), False, "同机所在公网段的别的地址 → 拒绝"),
    (("127.0.0.1", 5000), True, "回环 → 放行(本机自检)"),
    (("::ffff:172.22.99.9", 5000), True, "IPv4-mapped 的允许来源 → 规范化后放行"),
    (("::ffff:192.168.77.9", 5000), False, "IPv4-mapped 的非允许来源 → 规范化后仍拒绝"),
    (("2001:db8::1", 5000), False, "纯 IPv6 → 拒绝(本轮来源段只有 IPv4)"),
    (("垃圾", 5000), False, "解析不了的地址 → 拒绝"),
]
for addr, want, label in cases:
    got = g.allows(addr)
    if got == want:
        ok(label)
    else:
        bad("%s: 期望 %s 实得 %s" % (label, want, got))

# mapped 规范化必须真的发生(不是碰巧字符串不等)
ip = R._peer_ip(("::ffff:172.22.99.9", 0))
if str(ip) == "172.22.99.9":
    ok("_peer_ip 把 IPv4-mapped 规范成了 IPv4(换个写法绕不过判定)")
else:
    bad("规范化没生效: %r" % ip)

# CIDR 无效 → fail-closed, 谁都不放行
bad_guard = R.SourceGuard("这不是网段")
if bad_guard.net is None and not bad_guard.allows(("172.22.99.9", 0)) \
        and not bad_guard.allows(("127.0.0.1", 0)):
    ok("来源段解析不了 → **谁都不放行**(绝不退化成不限制来源)")
else:
    bad("无效来源段下仍放行了")
if not R.SourceGuard(None).allows(("172.22.99.9", 0)):
    ok("来源段缺失 → 同样 fail-closed")
else:
    bad("来源段缺失时放行了")

# 判定入参里根本没有 HTTP 头的位置 —— 结构上就不可能信任 X-Forwarded-For
import inspect  # noqa: E402

sig = inspect.signature(R.SourceGuard.allows)
if list(sig.parameters) == ["self", "addr"]:
    ok("allows() 只接受内核给的 peer 地址, 结构上没有让 HTTP 头进来的口子")
else:
    bad("allows() 的签名多了参数: %s" % sig)
src = open(os.path.join(ROOT, "deploy", "rescue", "rescue.py"), encoding="utf-8").read()
guard_src = src[src.index("class SourceGuard"):src.index("class BlockedSource")]
if "Forwarded" not in guard_src.replace("X-Forwarded-For / Forwarded", "") and \
        "headers" not in guard_src:
    ok("来源判定的实现里不读任何 HTTP 头")
else:
    bad("来源判定里出现了 HTTP 头")

# 拒绝点必须早于读 body / token / session
get_req = src[src.index("    def get_request(self):"):src.index("    def handle_error(")]
if get_req.index("self.guard.allows") < get_req.index("wrap_socket"):
    ok("拒绝发生在 TLS 握手**之前**(更早于读 body、token 与 session)")
else:
    bad("来源判定排在 TLS 握手之后")

# ── 2. 监听地址校验 ────────────────────────────────────────────────────────
print()
print("── 2. 监听地址 ──")
for v, want, label in [
    ("177.0.142.200", True, "普通 IPv4 字面量 → 收"),
    ("10.7.0.5", True, "私网地址 → 收"),
    ("0.0.0.0", False, "0.0.0.0 → 拒(那是把恢复入口开给所有人)"),
    ("255.255.255.255", False, "受限广播 → 拒"),
    ("224.0.0.1", False, "组播 → 拒"),
    ("gateway.local", False, "主机名 → 拒(解析结果会变, 不能作为绑定判据)"),
    ("", False, "空值 → 拒"),
    ("999.1.1.1", False, "非法八位组 → 拒"),
    ("2001:db8::1", False, "IPv6 → 本轮不支持"),
]:
    got = R._valid_bind(v) if v else False
    if got == want:
        ok(label)
    else:
        bad("%s: 期望 %s 实得 %s" % (label, want, got))

# bash 侧与 python 侧的判据必须一致 —— 两处口径不同, 就会出现"CLI 收了服务却拒"的怪事
def sh_valid(v):
    r = subprocess.run(["bash", "-c",
                        "source %s/lib/rescue.sh; pdg_rescue_bind_valid %s" % (ROOT, v or "''")],
                       capture_output=True)
    return r.returncode == 0


mism = [v for v in ("177.0.142.200", "10.7.0.5", "0.0.0.0", "255.255.255.255",
                    "224.0.0.1", "gateway.local", "999.1.1.1", "2001:db8::1")
        if sh_valid(v) != R._valid_bind(v)]
if not mism:
    ok("bash 侧 pdg_rescue_bind_valid 与 python 侧 _valid_bind 判据一致")
else:
    bad("两侧判据不一致: %s" % ", ".join(mism))

# 全局可路由 → 必须能被识别出来(status/doctor 据此给安全提醒)
def sh_global(v):
    r = subprocess.run(["bash", "-c",
                        "source %s/lib/rescue.sh; pdg_rescue_bind_is_global %s" % (ROOT, v)],
                       capture_output=True)
    return r.returncode == 0


for v, want, label in [("177.0.142.200", True, "公网可路由地址 → 判为全局(要提醒)"),
                       ("10.7.0.5", False, "10/8 → 私网"),
                       ("172.22.0.1", False, "172.16/12 → 私网"),
                       ("192.168.1.1", False, "192.168/16 → 私网"),
                       ("100.64.0.1", False, "CGNAT 100.64/10 → 非公网"),
                       ("127.0.0.1", False, "回环 → 非公网")]:
    got = sh_global(v)
    if got == want:
        ok(label)
    else:
        bad("%s: 期望 %s 实得 %s" % (label, want, got))

# ── 3. 与来源段互不推导 ────────────────────────────────────────────────────
print()
print("── 3. 两个键互不推导 ──")
pdg = open(os.path.join(ROOT, "deploy", "bot", "pdg.sh"), encoding="utf-8").read()
fn = pdg[pdg.index("_rescue_bind_addr(){"):]
fn = fn[:fn.index("\n}\n")]
if "pdg_rescue_bind" in fn and "internal_cidr" not in fn:
    ok("_rescue_bind_addr 只读 PDG_RESCUE_BIND, 不碰来源段")
else:
    bad("_rescue_bind_addr 又从来源段推导了: %s" % fn[:160])
if "PDG_RESCUE_BIND" in src and "local_addr_in(cidr)" not in src:
    ok("救援服务本体同样不从来源段推导监听地址")
else:
    bad("rescue.py 里还留着从来源段推导的回落")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

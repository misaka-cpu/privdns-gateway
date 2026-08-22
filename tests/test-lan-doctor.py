#!/usr/bin/env python3
"""内网面板(方案 B)四项自检的判据测试。

打桩替掉 _run / _lan_cfg / _lan_on, 把每条分支都走到 —— 尤其是那些**只在出事时才成立**
的分支: 它们在真机上一辈子也许都不触发一次, 而那正是最容易写错又没人发现的地方。

ACL 越界探测那一项的三种读法要分清, 不是"成功/失败"两分:
  连上了 → fail; 连接被拒(RST, 说明包到达了对端) → **同样 fail**; 不可达/超时 → ok。
"""
import importlib.util
import json
import os
import socket
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS = [0]


def ok(m):
    PASS[0] += 1


def cfg_with(*targets):
    return {"panels": [{"name": "p%d" % n, "host": "p%d.home.example.com" % n,
                        "target": "http://%s:%d" % t}
                       for n, t in enumerate(targets)]}


def stub(**kw):
    """临时替换 checks 模块里的若干属性, 用完还原。"""
    old = {k: getattr(C, k) for k in kw}
    for k, v in kw.items():
        setattr(C, k, v)
    return old


def restore(old):
    for k, v in old.items():
        setattr(C, k, v)


# ══ ① check_lan_whitelist ═══════════════════════════════════════════════════
CFG = cfg_with(("192.168.50.10", 443), ("192.168.50.20", 8080))


def nft_json(pairs):
    return json.dumps({"nftables": [
        {"rule": {"table": "pdglan", "expr": [
            {"match": {"left": {"payload": {"field": "daddr"}}, "right": ip}},
            {"match": {"left": {"payload": {"field": "dport"}}, "right": port}},
        ]}} for ip, port in pairs]})


def run_wl(pairs, active=True, rc=0, err=""):
    old = stub(_lan_cfg=lambda: CFG,
               _lan_on=lambda: (True, active),
               _run=lambda cmd, t=10: (rc, nft_json(pairs) if rc == 0 else "", err))
    try:
        return C.check_lan_whitelist()
    finally:
        restore(old)


st, _n, msg = run_wl([("192.168.50.10", 443), ("192.168.50.20", 8080)])
assert st == "ok", (st, msg)
ok("白名单与面板表一致 → ok")

st, _n, msg = run_wl([("192.168.50.10", 443)])
assert st == "fail" and "缺少" in msg and "192.168.50.20:8080" in msg, msg
ok("白名单少一条 → fail 且点名")

st, _n, msg = run_wl([("192.168.50.10", 443), ("192.168.50.20", 8080), ("10.9.9.9", 22)])
assert st == "fail" and "多出" in msg and "10.9.9.9:22" in msg, msg
ok("白名单多一条 → fail 且点名")

# 表根本不存在: 服务在跑 = 严重(反代此刻无约束); 服务没跑 = 只是没启用
st, _n, msg = run_wl([], active=True, rc=1, err="No such file or directory")
assert st == "fail" and "正在运行" in msg, msg
ok("表不在 + 服务在跑 → fail")

st, _n, msg = run_wl([], active=False, rc=1, err="No such file or directory")
assert st == "warn" and "没在跑" in msg, msg
ok("表不在 + 服务没跑 → warn(不是 fail)")

# nft 用不了 ≠ 表不存在 —— 混成一句会让缺权限的机器看起来像防火墙丢了
st, _n, msg = run_wl([], rc=1, err="Operation not permitted")
assert st == "warn" and "读不到" in msg, msg
ok("nft 用不了 → warn, 与'表不存在'分开")

# 停用时不该报红
old = stub(_lan_cfg=lambda: CFG, _lan_on=lambda: (False, False))
st, _n, msg = C.check_lan_whitelist()
restore(old)
assert st == "ok" and "已停用" in msg, msg
ok("功能停用 → 不报红")

# 从来没配过 → 整项不显示
old = stub(_lan_cfg=lambda: None)
assert C.check_lan_whitelist() is None
restore(old)
ok("没配过 → 返回 None(不占版面)")


# ══ ② check_lan_routes ══════════════════════════════════════════════════════
def ts_json(routes):
    return json.dumps({"Peer": {"n1": {"PrimaryRoutes": routes}}})


def run_routes(routes, internal="172.22.0.0/16", have_iface=True):
    devfile = tempfile.NamedTemporaryFile("w", delete=False, suffix=".dev")
    devfile.write("Inter-|   Receive\n face |bytes\n")
    if have_iface:
        devfile.write("tailscale0: 0 0\n")
    devfile.close()

    def _run(cmd, t=10):
        if cmd[:2] == ["tailscale", "status"]:
            return (0, ts_json(routes), "")
        if cmd[0] == "ip":
            return (0, "2: eth0    inet 10.7.0.5/24 scope global eth0\\n", "")
        return (1, "", "")

    old = stub(_run=_run, _profile=lambda k: internal if k == "PDG_INTERNAL_CIDR" else None)
    real_open = C.open if hasattr(C, "open") else open
    import builtins
    ob = builtins.open

    def fake_open(path, *a, **k):
        if str(path) == "/proc/net/dev":
            return ob(devfile.name, *a, **k)
        return ob(path, *a, **k)
    builtins.open = fake_open
    old_exists = os.path.exists
    os.path.exists = lambda p: True if p == "/proc/net/dev" else old_exists(p)
    try:
        return C.check_lan_routes()
    finally:
        builtins.open = ob
        os.path.exists = old_exists
        restore(old)
        os.unlink(devfile.name)


st, _n, msg = run_routes(["192.168.50.0/24"])
assert st == "ok", (st, msg)
ok("不相交的通告路由 → ok")

st, _n, msg = run_routes(["172.22.9.0/24"])
assert st == "fail" and "172.22" in msg, msg
ok("与内网卡段相交 → fail")

st, _n, msg = run_routes(["0.0.0.0/0"])
assert st == "fail", msg
ok("默认路由 → fail")

st, _n, msg = run_routes(["10.7.0.0/24"])
assert st == "fail" and "10.7.0" in msg, msg
ok("与本机接口网段相交 → fail")

# 读不到内网卡段: 最要紧的判据没跑, 即使其余都过也只能是 warn
st, _n, msg = run_routes(["192.168.50.0/24"], internal=None)
assert st == "warn" and "PDG_INTERNAL_CIDR" in msg, msg
ok("读不到内网卡段 → warn 并说明哪条没跑")

st, _n, msg = run_routes([])
assert st == "ok" and "没有从别的节点接受" in msg, msg
ok("没接受任何路由 → ok")

assert run_routes(["192.168.50.0/24"], have_iface=False) is None
ok("没有 tailscale0 → 整项不适用")


# ══ ③ check_deep_lan_acl: 三种读法 ══════════════════════════════════════════
def run_acl(exc):
    class FakeSock:
        def settimeout(self, t): pass
        def connect(self, addr):
            if exc is not None:
                raise exc
        def close(self): pass

    old = stub(_lan_cfg=lambda: CFG, _lan_on=lambda: (True, True))
    real = socket.socket
    socket.socket = lambda *a, **k: FakeSock()
    try:
        return C.check_deep_lan_acl()
    finally:
        socket.socket = real
        restore(old)


st, _n, msg = run_acl(None)
assert st == "fail" and "能连上" in msg, msg
ok("连上了 → fail")

st, _n, msg = run_acl(ConnectionRefusedError(111, "refused"))
assert st == "fail" and "RST" in msg, msg
ok("连接被拒 → **同样 fail**(包到达了对端才会有 RST)")

st, _n, msg = run_acl(socket.timeout())
assert st == "ok", msg
ok("超时 → ok")

st, _n, msg = run_acl(OSError(113, "No route to host"))
assert st == "ok" and "丢弃" in msg, msg
ok("EHOSTUNREACH → ok")

st, _n, msg = run_acl(OSError(13, "Permission denied"))
assert st == "warn" and "没跑成" in msg, msg
ok("其它错误 → warn(不冒充结论)")

# 探测地址必须**不在**面板表里
pick = C._lan_probe_target(CFG)
assert pick is not None
assert pick[0] not in ("192.168.50.10", "192.168.50.20"), pick
assert pick[0].startswith("192.168.50."), pick
ok("探测地址与面板同网段但不在表里: %s:%d" % (pick[0], pick[1]))

# ══ ④ check_lan_cert ═══════════════════════════════════════════════════════
# 判据用 `openssl x509 -checkend`, 不自己解析 notAfter —— 那个格式带时区缩写,
# strptime 在不同 locale 下解出来的东西不一样。桩按 checkend 的秒数分支即可。
def run_cert(have_crt=True, sans=None, expired=False, soon=False):
    """所有面板**共用一张 SAN 证书**, 所以桩按"这一张"来造, 不是按面板逐张。"""
    d = tmpguard.mkdtemp(prefix="lan-doctor.")
    if have_crt:
        open(os.path.join(d, "panel.crt"), "w").write("x")
    hosts = [q["host"] for q in CFG["panels"]] if sans is None else sans

    def _run(cmd, t=10):
        if cmd[:2] == ["openssl", "x509"]:
            if "-ext" in cmd:
                return (0, "X509v3 Subject Alternative Name:\n    "
                        + ", ".join("DNS:%s" % h for h in hosts), "")
            secs = int(cmd[cmd.index("-checkend") + 1])
            if expired:
                return (1, "", "")
            if secs > 0 and soon:
                return (1, "", "")
            return (0, "", "")
        return (1, "", "")

    old = stub(_lan_cfg=lambda: CFG, _lan_on=lambda: (True, True),
               LAN_CERT_DIR=d, _run=_run)
    try:
        return C.check_lan_cert()
    finally:
        restore(old)


st, _n, msg = run_cert()
assert st == "ok", (st, msg)
ok("SAN 覆盖全部面板且未临期 → ok")

# ── 证书项**一律 warn, 不能 fail** ───────────────────────────────────────────
# `pdg update` 跑完自检, 任何 fail 都会让整次更新回滚。而面板证书出问题只是"面板打不开",
# 不该把一个修了 DNS/代理缺陷的更新一起挡掉。真机上撞过: 在 v1.10.7 启用过面板的机器,
# 因为证书布局变了(一板一张 → 共用一张 SAN)这一项判 fail, 于是**每次更新都回滚,
# 永远升不上来**。危险的那种状态(反代在跑而白名单不在)由 check_lan_whitelist 负责 fail。
st, _n, msg = run_cert(have_crt=False)
assert st == "warn" and "panel.crt" in msg, (st, msg)
ok("没有证书 → warn(不是 fail —— fail 会让 pdg update 回滚)")

# **共用证书带来的新失败形态**: 加了面板却没重签 —— 文件在、也没过期, 但 SAN 里没有它。
# 只看"文件在不在"会整类漏掉, 而手机上表现成证书错误。
st, _n, msg = run_cert(sans=["p0.home.example.com"])
assert st == "warn" and "SAN" in msg and "p1.home.example.com" in msg, (st, msg)
ok("加了面板没重签(SAN 缺该名字) → warn 且点名")

st, _n, msg = run_cert(expired=True)
assert st == "warn" and "已过期" in msg, (st, msg)
ok("证书已过期 → warn")

# 空测: 整个证书项都不许出现 fail —— 否则升级路径又会被它挡住
for _case in (dict(have_crt=False), dict(sans=["p0.home.example.com"]),
              dict(expired=True), dict(soon=True), dict()):
    _st, _n2, _m = run_cert(**_case)
    assert _st != "fail", "证书项返回了 fail(%r), 那会让 pdg update 回滚: %s" % (_case, _m)
ok("证书项在所有分支上都不返回 fail")

st, _n, msg = run_cert(soon=True)
assert st == "warn" and "14 天内" in msg, msg
assert "续期链" in msg, "临期要提醒续期链可能断了 —— 它断掉时不会有任何报错"
ok("证书 14 天内到期 → warn 并提醒续期链")


old = stub(_lan_cfg=lambda: CFG, _lan_on=lambda: (False, False))
assert C.check_lan_cert() is None
restore(old)
ok("功能停用 → 证书项不适用(过不过期都不影响任何东西)")

print("test-lan-doctor.py: 通过 %d 项" % PASS[0])

#!/usr/bin/env python3
"""受管恢复的**真 HTTPS 表单闭环**(5.2/10c 实机验收的地面预演)。

和 test-rescue-cfgrestore.py 的分工: 那个直接调 `cr.restore_managed(...)`, 验的是恢复语义;
这个从**浏览器看到的那张页面**出发, 解析 form 与隐藏字段并原样提交, 验的是页面到后端这一段
协议本身。实机上连撞的 401/404/400 全部落在这一段, 而当时没有任何用例覆盖它 —— 直接调函数
的测试永远发现不了"页面上有个 confirm 复选框而客户端没提交"。

证书固定的期望值从**磁盘上的证书**独立算出(对应真机上 SSH 里跑 `pdg rescue fingerprint`),
不从这条连接自己取 —— 那等于自己给自己作证。全程不打印 token / cookie / nonce / digest 全值。
"""
import hashlib
import os
import shutil
import ssl
import sys
import tempfile
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
from rescuebox import Inst, TOKEN  # noqa: E402
from rescueform import Client, FormError, find_form, snapshot_ids  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


def tag(v):
    """秘密只报前 8 位做同一性比对, 不落全值。"""
    return (v or "")[:8] + "…" if v else "(空)"


import json  # noqa: E402

MODEL_OLD = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}], "route": {"rules": [], "final": "direct"}})
MODEL_NEW = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
    "route": {"rules": [], "final": "direct"}})

work = tempfile.mkdtemp(prefix="formflow.")


def build():
    """造一个带现网配置与一份可恢复快照的沙箱, 并起真的救援服务。"""
    import io
    import tarfile
    box = Box(work)
    box.up("mosdns")
    box.up("mihomo")
    live = {"etc/sing-box/config.json": MODEL_OLD,
            "etc/mosdns/config.yaml": _mos(1024),
            "etc/mosdns/rules/custom_direct.txt": "domain:old.example\n"}
    for rel, data in live.items():
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
    snap_id = "20260101-010101"
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    # 必须是 v1.6 结构(含数据模型), 否则确认页只给"紧急完整恢复"提示而**不出表单** ——
    # 头一版夹具漏了它, 客户端如实报了"页面上没有这张表单", 正是它该有的表现。
    want = {"etc/sing-box/config.json": MODEL_NEW,
            "etc/mosdns/config.yaml": _mos(4096),
            "etc/mosdns/rules/custom_direct.txt": "domain:new.example\n"}
    with tarfile.open(os.path.join(d, "snap.tar.gz"), "w:gz") as t:
        for rel, data in want.items():
            b = data.encode()
            info = tarfile.TarInfo(rel)
            info.size, info.mode = len(b), 0o644
            t.addfile(info, io.BytesIO(b))
    keep = ("PDG_TX_", "PDG_LOCKFILE", "PDG_STABLE", "PATH")
    env = {k: v for k, v in box.env.items() if k.startswith(keep)}
    env["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    env["PDG_TX_FSROOT"] = box.root
    inst = Inst(work, extra_env=env)
    if not inst.start():
        bad("救援服务没起来: %s" % inst.err[:200])
        sys.exit(1)
    return box, inst, snap_id, want


def _mos(size):
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["172.22.0.0/16"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n  - tag: main_sequence\n    type: sequence\n"
            "    args:\n      - exec: reject 3\n" % size)


def fp_from_disk(pem_path):
    """独立渠道取指纹: 读盘上的证书自己算, 不碰那条 TLS 连接。"""
    with open(pem_path, encoding="utf-8") as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


box, inst, SNAP, want = build()
expect_fp = fp_from_disk(inst.cert)
print("\n== 1. 证书固定 ==")
cli = Client("127.0.0.1", inst.port, expect_fp=expect_fp)
try:
    st, _ = cli.request("GET", "/")
    ok("按独立取得的指纹固定后连接成功(st=%s, 指纹前 8 位 %s)" % (st, expect_fp[:11]))
except FormError as e:
    bad("指纹固定失败: %s" % e)

evil = Client("127.0.0.1", inst.port, expect_fp="AA:" * 31 + "AA")
try:
    evil.request("GET", "/")
    bad("指纹不匹配竟然连上了 —— 固定形同虚设")
except FormError:
    ok("指纹不匹配时连接被拒(不是 verify=False 假校验)")

print("\n== 2. 登录 ==")
st, body = cli.login(TOKEN)
if st == 200 and "状态" in body:
    ok("登录成功并拿到状态页(st=200)")
else:
    bad("登录失败 st=%s" % st)
if cli.jar:
    ok("会话 cookie 已入 jar(%d 项, 值不外泄)" % len(cli.jar))
else:
    bad("没有拿到会话 cookie")

print("\n== 3. 快照列表与确认页 ==")
st, body = cli.request("GET", "/snapshots")
ids = snapshot_ids(body)
if SNAP in ids:
    ok("/snapshots 列出了目标快照(共 %d 份)" % len(ids))
else:
    bad("/snapshots 里没有目标快照: %r" % ids)

st, page = cli.request("GET", "/snapshot/" + SNAP)
if st != 200:
    bad("确认页打不开 st=%s" % st)
    sys.exit(1)
form = find_form(page, "/snapshot/restore")
names = set(form["fields"])
need = {"csrf", "snapshot", "digest", "nonce", "confirm"}
if names == need:
    ok("确认页表单字段与产品代码一致: %s" % " ".join(sorted(names)))
else:
    bad("字段对不上 缺=%s 多=%s" % (sorted(need - names), sorted(names - need)))
if form["checkboxes"] == {"confirm"} and form["fields"].get("confirm") == "yes":
    ok("confirm 是复选框且 value=yes —— 上一轮 400 正是漏了它")
else:
    bad("confirm 复选框形态不符: %r / %r" % (form["checkboxes"], form["fields"].get("confirm")))
if form["method"] == "post" and form["action"] == "/snapshot/restore":
    ok("method/action 按页面原样取用: POST /snapshot/restore")
else:
    bad("method/action 不符: %r %r" % (form["method"], form["action"]))
saved = dict(form["fields"])      # 留作重放/篡改负控

print("\n== 4. 漏勾 confirm 必须 400(复现上一轮故障) ==")
st, _ = cli.submit("/snapshot/" + SNAP, "/snapshot/restore", checks=())
if st == 400:
    ok("不勾 confirm → 400, 且未执行任何操作")
else:
    bad("不勾 confirm 竟然得到 st=%s" % st)

print("\n== 5. 字段名写错必须 404(复现上一轮故障) ==")
wrong = {k: v for k, v in saved.items() if k != "snapshot"}
wrong["snap"] = SNAP           # 上一轮就是把 snapshot 写成了 snap
wrong["confirm"] = "yes"
st, _ = cli.request("POST", "/snapshot/restore", urllib.parse.urlencode(wrong))
if st == 404:
    ok("字段名写成 snap → 404(服务端读不到 snapshot, 空 ID 不在索引里)")
else:
    bad("字段名写错得到 st=%s(期望 404)" % st)

print("\n== 6. 按页面原样提交一次真恢复 ==")
st, body = cli.submit("/snapshot/" + SNAP, "/snapshot/restore", checks=("confirm",))
if st == 200:
    ok("恢复提交成功 st=200")
else:
    bad("恢复失败 st=%s: %s" % (st, body[:200].replace("\n", " ")))
good = True
for rel, data in want.items():
    p = os.path.join(box.root, rel)
    with open(p, encoding="utf-8") as f:
        cur = f.read()
    if cur != data:
        good = False
        bad("%s 内容与快照不一致" % rel)
if good:
    ok("受管文件逐字节等于快照内容(%d 个)" % len(want))
if "COMMITTED" in body or "已恢复" in body or "成功" in body:
    ok("页面回报事务完成")
else:
    bad("页面没有回报完成: %s" % body[:160].replace("\n", " "))

print("\n== 7. nonce 重放 ==")
# 必须重放**刚刚成功那次**发出去的原样字段。第一版重放的是 §3 抓到的旧表单, 而 §6 重新取页
# 换了个新 nonce —— 于是"重放"的是个从没用过的 nonce, 服务端放行完全正确, 是测试在冤枉产品。
replay = dict(cli.last)
used_nonce = replay.get("nonce")
st, rb = cli.request("POST", "/snapshot/restore", urllib.parse.urlencode(replay))
if st == 409 and "已经用过或已失效" in rb:
    ok("刚用过的那份 nonce 再提交一次 → 409/一次性(前 8 位 %s)" % tag(used_nonce))
else:
    bad("nonce 重放得到 st=%s, 文案未指向一次性(期望 409)" % st)

print("\n== 8. digest 被改动 ==")
st, page2 = cli.request("GET", "/snapshot/" + SNAP)
f2 = find_form(page2, "/snapshot/restore")
tampered = dict(f2["fields"])
tampered["confirm"] = "yes"
d0 = tampered["digest"]
tampered["digest"] = ("0" if d0[:1] != "0" else "1") + d0[1:]
st, tb = cli.request("POST", "/snapshot/restore", urllib.parse.urlencode(tampered))
# 必须按**文案**区分是哪道闸拦的。只看 409 分不清: nonce 本身绑定了 digest, 就算摘要比对被
# 摘掉, 后面的 consume 照样会拒 —— 状态码一模一样。负控里关掉摘要比对时用例仍然全绿, 就是
# 这么来的。产品有纵深防御是好事, 但断言得说清自己在验哪一层。
if st == 409 and "快照内容在确认之后发生了变化" in tb:
    ok("digest 改一位 → 409, 且由摘要比对这道闸拦下")
else:
    bad("digest 被篡改得到 st=%s, 拦它的不是摘要比对(期望 409/内容已变化)" % st)

print("\n== 9. 换 session 后旧 nonce ==")
st, page3 = cli.request("GET", "/snapshot/" + SNAP)
f3 = find_form(page3, "/snapshot/restore")
old_nonce = f3["fields"]["nonce"]
cli2 = Client("127.0.0.1", inst.port, expect_fp=expect_fp)
st, _ = cli2.login(TOKEN)
st, page4 = cli2.request("GET", "/snapshot/" + SNAP)
f4 = find_form(page4, "/snapshot/restore")
cross = dict(f4["fields"])        # 新会话的 csrf, 但塞旧会话的 nonce
cross["nonce"] = old_nonce
cross["confirm"] = "yes"
if old_nonce != f4["fields"]["nonce"]:
    ok("两个会话拿到的 nonce 不同(前 8 位 %s vs %s)" % (tag(old_nonce), tag(f4["fields"]["nonce"])))
else:
    bad("两个会话拿到了同一个 nonce")
st, cb = cli2.request("POST", "/snapshot/restore", urllib.parse.urlencode(cross))
if st == 409 and "已经用过或已失效" in cb:
    ok("旧会话的 nonce 在新会话里被拒 → 409(nonce 绑定 session)")
else:
    bad("跨会话 nonce 得到 st=%s(期望 409/一次性)" % st)

print("\n== 10. 未登录 ==")
anon = Client("127.0.0.1", inst.port, expect_fp=expect_fp)
fresh = dict(f4["fields"])
fresh["confirm"] = "yes"
st, _ = anon.request("POST", "/snapshot/restore", urllib.parse.urlencode(fresh))
if st == 401:
    ok("无会话直接提交 → 401(上一轮 401 的成因: 登录后重启服务, 内存会话没了)")
else:
    bad("无会话提交得到 st=%s(期望 401)" % st)

print("\n== 11. 客户端不许猜字段 ==")
try:
    find_form("<html><body>没有表单</body></html>", "/snapshot/restore")
    bad("页面没有表单时客户端竟然没报错")
except FormError:
    ok("页面缺表单时客户端提交前就失败, 不发注定被拒的请求")

inst.stop() if hasattr(inst, "stop") else None
shutil.rmtree(work, ignore_errors=True)

total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""救援平面的**受管配置恢复**回归(5.2/commit 7)。

它只恢复 pdgtx 白名单覆盖的配置, 走一笔真事务(候选 → 校验 → before-image → 落盘 → 服务动作
→ 观察 → COMMITTED 或完整回滚)。二进制、Bot 程序、platform/backend、bot.env 一律不碰, 失败
也**绝不**自动降级成完整快照恢复。

快照的安全边界是重点: 页面只能选服务端索引里的逻辑 ID, 路径/软链/`..` 一律拒; 确认到执行之间
快照被换掉要靠摘要挡住; 快照里的额外文件只能列为 excluded, 不能落盘。
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
from rescuebox import Inst, TOKEN  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-cfgrestore-42"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


MODEL_OLD = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}], "route": {"rules": [], "final": "direct"}})
MODEL_NEW = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
    "route": {"rules": [], "final": "direct"}})


def mos(size):
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["172.22.0.0/16"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n  - tag: main_sequence\n    type: sequence\n"
            "    args:\n      - exec: reject 3\n" % size)


def seed_box(box):
    """现网: 旧配置 + 一些**不受管**的东西(它们必须逐字节不变)。"""
    box.up("mosdns")
    box.up("mihomo")
    w = {}
    for rel, data in (("etc/sing-box/config.json", MODEL_OLD),
                      ("etc/mosdns/config.yaml", mos(1024)),
                      ("etc/mosdns/rules/custom_direct.txt", "domain:old.example\n"),
                      ("opt/pdg-bot/rulesets.json", '{"old": {"label": "旧"}}'),
                      ("etc/privdns-gateway/bot.env", "PDG_BOT_TOKEN=123456789:%s\n" % SENTINEL),
                      ("etc/privdns-gateway/platform", "ios\n"),
                      ("etc/privdns-gateway/backend", "mihomo\n"),
                      ("usr/local/bin/mihomo", "REAL-BINARY-CONTENT\n")):
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        w[rel] = data
    return w


def make_snapshot(box, snap_id="20260101-010101", members=None, extra=()):
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    items = members if members is not None else [
        ("etc/sing-box/config.json", MODEL_NEW),
        ("etc/mosdns/config.yaml", mos(4096)),
        ("etc/mosdns/rules/custom_direct.txt", "domain:new.example\n"),
        ("opt/pdg-bot/rulesets.json", '{"new": {"label": "新"}}'),
        # 快照里本来就有的、**不受管**的东西
        ("usr/local/bin/mihomo", "SNAPSHOT-BINARY\n"),
        ("etc/privdns-gateway/bot.env", "PDG_BOT_TOKEN=999999999:FROM-SNAPSHOT\n"),
        ("etc/privdns-gateway/platform", "android\n"),
        ("etc/privdns-gateway/backend", "singbox\n"),
        ("etc/systemd/system/pdg-bot.service", "[Unit]\n"),
    ] + list(extra)
    with tarfile.open(os.path.join(d, "snap.tar.gz"), "w:gz") as t:
        for rel, data in items:
            b = data.encode() if isinstance(data, str) else data
            info = tarfile.TarInfo(rel)
            info.size = len(b)
            info.mode = 0o644
            t.addfile(info, io.BytesIO(b))
    return snap_id


def rescue_for(box, **kw):
    keep = ("PDG_TX_", "PDG_LOCKFILE", "PDG_STABLE", "PATH")
    env = {k: v for k, v in box.env.items() if k.startswith(keep)}
    env["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    env["PDG_TX_FSROOT"] = box.root
    return Inst(work, extra_env=env, **kw)


def load_cr(box):
    """按这个沙箱的环境加载一份**全新的** cfgrestore + pdgtx。

    pdgtx 的 TX_ROOT / 锁 / 探针端点都是 import 期从环境读的常量, 而 cfgrestore 内部
    `import pdgtx` 拿到的是缓存实例 —— 不把它踢掉的话, 第二个沙箱用的还是第一个沙箱的事务根与
    探针端口(第一版就这么误判了三条用例)。"""
    import importlib.util
    for k, v in box.env.items():
        os.environ[k] = v
    os.environ["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    sys.modules.pop("pdgtx", None)
    spec = importlib.util.spec_from_file_location(
        "cfgrestore_%d" % time.time_ns(), os.path.join(ROOT, "deploy/bot/cfgrestore.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.SNAP_DIR = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    return m


def audit(box, op="config_restore"):
    f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    if not os.path.exists(f):
        return []
    out = []
    for line in open(f, encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("op") == op:
            out.append(r)
    return out


def unchanged(box, base, keys, label):
    diff = [k for k in keys
            if open(os.path.join(box.root, k), encoding="utf-8").read() != base[k]]
    if not diff:
        ok("%s: %s 逐字节未变" % (label, "/".join(k.split("/")[-1] for k in keys)))
    else:
        bad("%s: 这些被改了 %s" % (label, diff))


work = tempfile.mkdtemp(prefix="cfgrestore.")
NOT_MANAGED = ("etc/privdns-gateway/bot.env", "etc/privdns-gateway/platform",
               "etc/privdns-gateway/backend", "usr/local/bin/mihomo")

# ── 1. 多目标正常恢复 ───────────────────────────────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box)
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if res.get("ok") and res.get("state") == "COMMITTED":
    ok("多目标恢复: 事务 COMMITTED")
else:
    bad("正常恢复失败: %r" % {k: res[k] for k in ("state", "error", "restored")})
got = set(res.get("restored") or [])
if {"model", "mosdns_conf", "rs_meta", "mosdns_rule:custom_direct.txt"} <= got:
    ok("多目标恢复: 四个受管目标都恢复了(%d 个)" % len(got))
else:
    bad("恢复的目标不全: %r" % got)
if json.loads(open(os.path.join(box.root, "etc/sing-box/config.json"), encoding="utf-8").read()) \
        == json.loads(MODEL_NEW):
    ok("多目标恢复: model 已换成快照里的内容")
else:
    bad("model 没换")
unchanged(box, base, NOT_MANAGED, "多目标恢复")
recs = audit(box)
if len(recs) == 1:
    ok("审计: 只有一条 config_restore 事件(核心统一写)")
else:
    bad("审计条数 %d" % len(recs))
r0 = recs[-1] if recs else {}
need = ("op", "txid", "trigger_source", "snapshot", "snapshot_format", "restored_count",
        "excluded_count", "state", "error_class")
miss = [k for k in need if k not in r0]
if not miss and r0.get("trigger_source") == "rescue" and r0.get("snapshot") == snap:
    ok("审计: 字段齐全且 trigger_source=rescue / 快照 ID 正确")
else:
    bad("审计字段: 缺 %s, 记录 %r" % (miss, r0))
if r0.get("excluded_count", 0) >= 4:
    ok("审计: 记录了被排除的项数(%d)" % r0["excluded_count"])
else:
    bad("excluded_count 不对: %r" % r0.get("excluded_count"))
box.clean()

# ── 2. 无变化恢复(快照与现网一致)──────────────────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box, members=[
    ("etc/sing-box/config.json", MODEL_OLD), ("etc/mosdns/config.yaml", mos(1024))])
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if res.get("ok"):
    ok("无变化恢复: 仍然干净提交")
else:
    bad("无变化恢复失败: %r" % res.get("error"))
if open(os.path.join(box.root, "etc/mosdns/config.yaml"), encoding="utf-8").read() == mos(1024):
    ok("无变化恢复: 内容与操作前一致")
else:
    bad("内容被改了")
box.clean()

# ── 3. 快照 ID 的安全边界 ───────────────────────────────────────────────────
box = Box()
seed_box(box)
snap = make_snapshot(box)
cr = load_cr(box)
evil = ["../../etc", "/etc/passwd", "..", "20260101-010101/../../..", "snap.tar.gz",
        "20260101-010101\x00", "*", "20260101-999999"]
if all(cr.snapshot_path(e) is None for e in evil):
    ok("快照 ID: 路径/`..`/通配/不存在的 ID 一律拒绝")
else:
    bad("有恶意 ID 被接受: %r" % [e for e in evil if cr.snapshot_path(e)])
# 目录被换成软链 → 也不接受
link_id = "20260202-020202"
snapdir = os.path.join(box.root, "var/lib/privdns-gateway/backups")
os.symlink("/etc", os.path.join(snapdir, link_id))
if cr.snapshot_path(link_id) is None:
    ok("快照 ID: 指向软链的条目被拒")
else:
    bad("软链条目被接受")
os.unlink(os.path.join(snapdir, link_id))
# 快照文件本身是软链 → 拒
link2 = os.path.join(snapdir, "20260303-030303")
os.makedirs(link2, exist_ok=True)
os.symlink("/etc/passwd", os.path.join(link2, "snap.tar.gz"))
if cr.snapshot_path("20260303-030303") is None:
    ok("快照 ID: snap.tar.gz 是软链时被拒")
else:
    bad("软链快照文件被接受")
shutil.rmtree(link2, ignore_errors=True)
box.clean()

# ── 4. 确认之后快照被替换 → 摘要不符, 拒绝 ─────────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box)
cr = load_cr(box)
old_digest = cr.snapshot_digest(snap)
make_snapshot(box, snap_id=snap, members=[("etc/mosdns/config.yaml", mos(9999))])   # 换掉
res = cr.restore_managed(snap, expect_digest=old_digest, trigger_source="rescue")
if not res.get("ok") and "变化" in (res.get("error") or ""):
    ok("确认后快照被替换: 摘要不符 → 拒绝执行")
else:
    bad("被替换的快照仍被恢复: %r" % res)
if open(os.path.join(box.root, "etc/mosdns/config.yaml"), encoding="utf-8").read() == mos(1024):
    ok("确认后快照被替换: 现网未变")
else:
    bad("现网被改了")
box.clean()

# ── 5. 快照里的额外/未知文件只列 excluded, 不落盘 ──────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box, extra=[("etc/weird/unknown.conf", "x\n"),
                                 ("var/lib/other/thing.db", "y\n")])
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
exc = set(res.get("excluded") or [])
if {"etc/weird/unknown.conf", "var/lib/other/thing.db"} <= exc:
    ok("额外/未知文件被列为 excluded")
else:
    bad("未知文件没列出来: %r" % exc)
if not os.path.exists(os.path.join(box.root, "etc/weird/unknown.conf")) \
        and not os.path.exists(os.path.join(box.root, "var/lib/other/thing.db")):
    ok("额外/未知文件没有落盘")
else:
    bad("未知文件落盘了")
unchanged(box, base, NOT_MANAGED, "含未知文件的恢复")
# 再直接验共享解包本身: 不受管成员**连 staging 都不该落地**(生产没被改只是结果, 不是判据)
stage = tempfile.mkdtemp(dir=work)
with tarfile.open(cr.snapshot_path(snap), "r:gz") as _t:
    skipped = cr.safe_extract(_t, stage, unmanaged="skip")
landed = set()
for r_, _d, fs in os.walk(stage):
    for fn in fs:
        landed.add(os.path.relpath(os.path.join(r_, fn), stage))
strays = [n for n in landed if not cr.target_for(n)]
if not strays:
    ok("安全解包(skip 模式): staging 里只有受管成员, 不受管的一个都没落地")
else:
    bad("staging 里落了不受管成员: %r" % strays[:5])
if {"usr/local/bin/mihomo", "etc/privdns-gateway/bot.env"} <= set(skipped):
    ok("安全解包(skip 模式): 不受管成员被如实回报给调用方")
else:
    bad("skipped 清单不对: %r" % skipped[:5])
shutil.rmtree(stage, ignore_errors=True)
box.clean()

# ── 6. 候选校验失败 → 不提交, 现网不变 ─────────────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box, members=[("etc/mosdns/config.yaml", "这不是合法的 mosdns 配置\n")])
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if not res.get("ok"):
    ok("候选校验失败: 未提交(%s)" % (res.get("state") or "ABORTED"))
else:
    bad("坏候选被提交了")
if open(os.path.join(box.root, "etc/mosdns/config.yaml"), encoding="utf-8").read() == mos(1024):
    ok("候选校验失败: 现网逐字节未变")
else:
    bad("现网被改了")
box.clean()

# ── 7. 服务动作失败 → 回滚, 所有目标回到操作前 ─────────────────────────────
box = Box(svc_fail=["mihomo"])
base = seed_box(box)
snap = make_snapshot(box)
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if res.get("state") in ("ROLLED_BACK", "ROLLBACK_FAILED") and not res.get("ok"):
    ok("服务动作失败: 事务 %s" % res.get("state"))
else:
    bad("服务失败却提交了: %r" % res.get("state"))
same = all(open(os.path.join(box.root, k), encoding="utf-8").read() == base[k]
           for k in ("etc/sing-box/config.json", "etc/mosdns/config.yaml",
                     "etc/mosdns/rules/custom_direct.txt", "opt/pdg-bot/rulesets.json"))
if same:
    ok("服务动作失败: 四个受管目标全部回到操作前")
else:
    bad("回滚不完整")
unchanged(box, base, NOT_MANAGED, "服务失败回滚后")
box.clean()

# ── 8. 观察期退化 → 回滚 ───────────────────────────────────────────────────
box = Box(restart_crash=True)
base = seed_box(box)
with open(os.path.join(box.root, "etc/sing-box/config.json"), "w", encoding="utf-8") as f:
    f.write(MODEL_OLD.replace('"log": {}', '"log": {"note": "CRASHME"}'))
base["etc/sing-box/config.json"] = open(
    os.path.join(box.root, "etc/sing-box/config.json"), encoding="utf-8").read()
snap = make_snapshot(box, members=[("etc/mosdns/config.yaml", mos(4096))])
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if not res.get("ok"):
    ok("观察期退化: 未提交(%s)" % res.get("state"))
else:
    bad("观察期退化却提交了")
if open(os.path.join(box.root, "etc/mosdns/config.yaml"), encoding="utf-8").read() == mos(1024):
    ok("观察期退化: 现网回到操作前")
else:
    bad("现网没回滚")
box.clean()

# ── 9. 存在未完成事务 → 拒绝, 不自动 recover ───────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box)
txroot = box.env["PDG_TX_ROOT"]
stuck = os.path.join(txroot, "20250101T000000Z-stuck123")
os.makedirs(stuck, exist_ok=True)
with open(os.path.join(stuck, "meta.json"), "w", encoding="utf-8") as f:
    json.dump({"txid": "20250101T000000Z-stuck123", "state": "APPLYING", "op": "x",
               "source": "bot", "schema_version": 1, "targets": []}, f)
cr = load_cr(box)
res = cr.restore_managed(snap, expect_digest=cr.snapshot_digest(snap), trigger_source="rescue")
if not res.get("ok") and "未完成" in (res.get("error") or ""):
    ok("存在未完成事务: 配置恢复被拒绝并提示先 recover")
else:
    bad("有 pending 却执行了: %r" % res)
if json.load(open(os.path.join(stuck, "meta.json"), encoding="utf-8"))["state"] == "APPLYING":
    ok("存在未完成事务: 没有自动 recover 它")
else:
    bad("自动 recover 了 pending 事务")
unchanged(box, base, NOT_MANAGED + ("etc/mosdns/config.yaml",), "pending 拒绝后")
box.clean()

# ── 10. 旧结构快照 → 只识别不转换 ──────────────────────────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box, snap_id="20240101-010101",
                     members=[("etc/dnsdist/dnsdist.conf", "-- old\n")])
cr = load_cr(box)
res = cr.restore_managed("20240101-010101", trigger_source="rescue")
if not res.get("ok") and res.get("incompatible") and "完整恢复" in (res.get("error") or ""):
    ok("旧结构快照: 标记为只能走紧急完整恢复, 不做结构转换")
else:
    bad("旧结构处理不对: %r" % res)
unchanged(box, base, NOT_MANAGED + ("etc/mosdns/config.yaml",), "旧结构拒绝后")
box.clean()

# ── 11. HTTP 层: 确认页 / nonce / 双击重放 / 并发 / 断线 ────────────────────
box = Box()
base = seed_box(box)
snap = make_snapshot(box)
inst = rescue_for(box)
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:200])
else:
    st, cookie = inst.login()
    st1, body1, _sc, _h = inst.req("GET", "/snapshot/" + snap, cookie=cookie)
    if st1 == 200 and "恢复受管配置" in body1:
        ok("确认页: 按钮文案是「恢复受管配置」, 不是恢复全部/恢复快照")
    else:
        bad("确认页不对: st=%s" % st1)
    for kw in (snap, "结构版本", "内容摘要", "可以事务恢复的配置", "明确不恢复"):
        if kw not in body1:
            bad("确认页缺少 %s" % kw)
            break
    else:
        ok("确认页列出 ID/创建时间/版本/摘要/可恢复目标/排除项")
    for kw in ("bot.env", "platform", "backend", "usr/local/bin/mihomo"):
        if kw not in body1:
            bad("确认页没有把 %s 列进排除清单" % kw)
            break
    else:
        ok("确认页明确列出二进制/Bot 程序/平台标记/凭据为不恢复")
    if "恢复全部" not in body1 and "恢复快照</button>" not in body1:
        ok("确认页没有会被误解成整机恢复的按钮文案")
    else:
        bad("出现了容易误解的按钮文案")
    m = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body1)
    csrf = m.group(1) if m else ""
    dg = re.search(r"name=digest value='([0-9a-f]+)'", body1)
    dg = dg.group(1) if dg else ""
    nn = re.search(r"name=nonce value='([A-Za-z0-9_-]+)'", body1)
    nn = nn.group(1) if nn else ""
    if csrf and dg and nn:
        ok("确认页带 CSRF / 快照摘要 / 一次性 nonce")
    else:
        bad("表单字段不全")

    def post(nonce=None, snapv=None, digest=None, confirm="yes", csrfv=None, cookie_=None):
        return inst.req("POST", "/snapshot/restore",
                        body="csrf=%s&snapshot=%s&digest=%s&nonce=%s&confirm=%s" % (
                            csrfv if csrfv is not None else csrf,
                            snapv if snapv is not None else snap,
                            digest if digest is not None else dg,
                            nonce if nonce is not None else nn, confirm),
                        cookie=cookie if cookie_ is None else cookie_)

    st, _b, _sc, _h = post(csrfv="bogus")
    if st == 403:
        ok("HTTP: CSRF 不符 → 403")
    else:
        bad("CSRF 错返回 %s" % st)
    st, _b, _sc, _h = post(confirm="no")
    if st == 400:
        ok("HTTP: 未勾确认 → 400")
    else:
        bad("未确认返回 %s" % st)
    st, _b, _sc, _h = post(snapv="../../etc")
    if st == 404:
        ok("HTTP: 快照 ID 是路径 → 404")
    else:
        bad("路径 ID 返回 %s" % st)
    st, _b, _sc, _h = post(nonce="forged-nonce-value")
    if st == 409:
        ok("HTTP: 伪造 nonce → 409")
    else:
        bad("伪造 nonce 返回 %s" % st)
    # 正常执行一次
    st2, body2, _sc, _h = post()
    if st2 == 200 and "配置恢复结果" in body2 and "COMMITTED" in body2:
        ok("HTTP: 正常执行一次并返回结果页")
    else:
        bad("执行失败: st=%s" % st2)
    # 重放同一个 nonce(双击/刷新)→ 只执行一次
    st3, body3, _sc, _h = post()
    if st3 == 409 and "已经用过" in body3:
        ok("HTTP: 重放同一 nonce → 409(双击只执行一次)")
    else:
        bad("重放返回 %s" % st3)
    recs = audit(box)
    if len(recs) == 1:
        ok("HTTP: 重放没有产生第二条审计/第二次恢复")
    else:
        bad("产生了 %d 条 config_restore" % len(recs))
    unchanged(box, base, NOT_MANAGED, "HTTP 恢复后")
    if SENTINEL not in body1 + body2 + body3 and TOKEN not in body1 + body2 + body3:
        ok("HTTP: 页面不含哨兵与 Token")
    else:
        bad("页面泄漏了凭据")
inst.stop()
aud_txt = open(os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl"), encoding="utf-8").read()
if SENTINEL not in aud_txt and SENTINEL not in (inst.err or ""):
    ok("哨兵不出现在审计与服务端日志里")
else:
    bad("哨兵泄漏到审计/日志")
box.clean()

# ── 12. 配置恢复路径不得触达完整恢复 ───────────────────────────────────────
# 完整恢复自 commit 8 起是**独立入口**(deploy/rescue/breakglass.py), 所以不能再拿"全仓没有
# pdg rollback 字样"当判据 —— 那既会误伤结果页里给用户的 SSH 指引, 也验不出真正要防的事情:
# **配置恢复失败之后不会自己走到完整恢复**。改为逐条核对这条边界。
cr_src = open(os.path.join(ROOT, "deploy/bot/cfgrestore.py"), encoding="utf-8").read()
# 判"是不是真的会走到完整恢复", 而不是"有没有 rollback 这个词" —— pdgtx 的
# rollback_failed_items 是回滚结果字段, 与调用 pdg rollback 是两回事。
_calls_rollback = ("pdg rollback" in cr_src or '"rollback"' in cr_src
                   or "'rollback'" in cr_src or "rollback --dir" in cr_src)
_imports_bg = bool(re.search(r"^\s*(import|from)\s+breakglass", cr_src, re.M))
if not _calls_rollback and not _imports_bg:
    ok("配置恢复实现里既不调用 pdg rollback, 也不引用完整恢复模块")
else:
    bad("cfgrestore 会触达完整恢复(调用=%s 引用=%s)" % (_calls_rollback, _imports_bg))
rs_src = open(os.path.join(ROOT, "deploy/rescue/rescue.py"), encoding="utf-8").read()
_m = re.search(r"def _post_cfg_restore\(self\):.*?(?=\n    def )", rs_src, re.S)
if _m and "breakglass" not in _m.group(0) and "rollback" not in _m.group(0):
    ok("配置恢复的 HTTP 处理器里没有任何通往完整恢复的分支")
else:
    bad("配置恢复处理器引用了完整恢复")
# 完整恢复只能由**用户显式访问那个页面**触发: 它有自己的路由与票据
if "/breakglass/restore" in rs_src and 'consume(nonce, self._sid(), snap, digest, "breakglass")' in rs_src:
    ok("完整恢复是独立路由 + 独立一次性票据(与配置恢复不共用)")
else:
    bad("完整恢复没有独立票据")

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

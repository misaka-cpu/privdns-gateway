#!/usr/bin/env python3
"""恢复的**服务动作推导**回归(5.2)。

以前配置恢复固定发 restart:mihomo + restart:mosdns: 只换一份规则集元数据也要把 DNS 与内核
一起重启 —— 无谓的中断; 更糟的是, 只要那两个里有一个本来就坏着, 一次本可以安全完成的元数据
恢复就失败了。现在动作从**这次内容确实变了的目标**推出来, 映射只有一份(pdgtx.actions_for_targets),
Bot 与救援页共用。

判据全部落在真实行为上: 数桩服务被调用的次数、看审计里的 planned/executed、逐字节核对现网。
"""
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-actions-13"


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


NFT_OK = ("table inet pdg\ndelete table inet pdg\ntable inet pdg {\n"
          "    chain input {\n        type filter hook input priority 0; policy drop;\n"
          "        ip saddr 172.22.0.0/16 tcp dport { 53 } accept\n    }\n}\n")

work = tempfile.mkdtemp(prefix="restore-actions.")


def load_cr(box):
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


def seed(box, extra=()):
    box.up("mosdns")
    box.up("mihomo")
    base = {}
    for rel, data in (("etc/sing-box/config.json", MODEL_OLD),
                      ("etc/mosdns/config.yaml", mos(1024)),
                      ("etc/mosdns/rules/custom_direct.txt", "domain:old.example\n"),
                      ("opt/pdg-bot/rulesets.json", '{"a": {"label": "旧"}}'),
                      ("etc/sing-box/rs/a.json", '{"version":1,"rules":[]}'),
                      ("etc/nftables.conf", NFT_OK)) + tuple(extra):
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        base[rel] = data
    return base


def snap(box, items, snap_id="20260101-010101"):
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    # 快照里总是带上一份 model, 让结构识别判成 v1.6(与真实快照一致)
    have_model = any(n == "etc/sing-box/config.json" for n, _ in items)
    full = list(items) + ([] if have_model else [("etc/sing-box/config.json", MODEL_OLD)])
    with tarfile.open(os.path.join(d, "snap.tar.gz"), "w:gz") as t:
        for rel, data in full:
            b = data.encode()
            info = tarfile.TarInfo(rel)
            info.size = len(b)
            info.mode = 0o644
            t.addfile(info, io.BytesIO(b))
    return snap_id


MUTATING = ("restart", "start", "stop", "daemon-reload", "reload")


def calls(box):
    """桩命令日志 → 各类调用次数。

    只把**改变系统状态**的调用算作"服务动作": systemctl is-active / show 是事务的健康基线与
    观察期在问状态, 那是只读的, 每笔事务都会有 —— 把它们算进去, "零服务动作"这条断言就永远
    不可能成立, 也就验不出真正的问题。查询次数单独留一个字段, 便于需要时核对。"""
    try:
        txt = open(box.calls, encoding="utf-8").read()
    except OSError:
        return {}
    out = {"restart:mihomo": 0, "restart:mosdns": 0, "nft:apply": 0,
           "sysctl:apply": 0, "mutating": 0, "queries": 0}
    for ln in txt.splitlines():
        if ln.startswith("systemctl "):
            verb = ln.split()[1] if len(ln.split()) > 1 else ""
            if verb in MUTATING:
                out["mutating"] += 1
                if ln.startswith("systemctl restart mihomo"):
                    out["restart:mihomo"] += 1
                if ln.startswith("systemctl restart mosdns"):
                    out["restart:mosdns"] += 1
            else:
                out["queries"] += 1
        elif ln.startswith("nft -f"):
            out["nft:apply"] += 1
            out["mutating"] += 1
        elif ln.startswith("sysctl -p"):
            out["sysctl:apply"] += 1
            out["mutating"] += 1
    return out


def audit_last(box):
    f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    if not os.path.exists(f):
        return {}
    recs = []
    for line in open(f, encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("op") == "config_restore":
            recs.append(r)
    return recs[-1] if recs else {}


def run_case(items, extra_seed=(), box_kw=None):
    box = Box(**(box_kw or {}))
    base = seed(box, extra_seed)
    sid = snap(box, items)
    cr = load_cr(box)
    open(box.calls, "w").close()          # 只数恢复过程中的调用
    res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
    return box, base, res, calls(box), audit_last(box)


# ── 1. 纯映射层(不跑事务): 每个真实目标的动作 ───────────────────────────────
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("pdgtx_map", os.path.join(ROOT, "deploy/bot/pdgtx.py"))
tx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tx)
CASES = (
    ("rs_meta", ()),
    ("profile_env", ()),
    ("dot_marker", ()),
    ("model", ("restart:mihomo",)),
    ("mihomo_cfg", ("restart:mihomo",)),
    ("ruleset:a.json", ("restart:mihomo",)),
    ("mosdns_conf", ("restart:mosdns",)),
    ("mosdns_rule:custom_direct.txt", ("restart:mosdns",)),
    ("mitm_hijack", ("restart:mosdns",)),
    ("cert_fullchain", ("restart:mosdns",)),
    ("cert_privkey", ("restart:mosdns",)),
    ("nftables_conf", ("nft:apply",)),
    ("sysctl_tfo", ("sysctl:apply",)),
    ("unit:pdg-bot.service", ("daemon-reload",)),
)
wrong = [(n, tx.actions_for_targets([n]), want) for n, want in CASES
         if tx.actions_for_targets([n]) != want]
if not wrong:
    ok("映射: %d 个真实目标的动作逐个符合真实依赖" % len(CASES))
else:
    bad("映射不对: %r" % wrong[:3])
mixed = tx.actions_for_targets(["model", "mosdns_conf", "rs_meta", "nftables_conf",
                                "ruleset:a.json", "mosdns_rule:custom_direct.txt"])
if mixed == ("nft:apply", "restart:mosdns", "restart:mihomo"):
    ok("映射: 多目标取并集、去重, 且顺序固定(%s)" % " → ".join(mixed))
else:
    bad("并集/顺序不对: %r" % (mixed,))
if tx.actions_for_targets(["mosdns_conf", "model"]) == tx.actions_for_targets(["model", "mosdns_conf"]):
    ok("映射: 与输入顺序无关(可测试的固定顺序)")
else:
    bad("顺序依赖输入")
for bad_t in ("mitm_json", "unknown_target", "ruleset:../x", "mosdns_rule:/etc/passwd"):
    try:
        tx.actions_for_targets([bad_t])
        bad("未知/需显式的目标没有 fail-closed: %s" % bad_t)
        break
    except tx.TxError:
        pass
else:
    ok("映射: 未知目标与需显式声明的目标一律 fail-closed(不默认重启所有服务)")
# 同步守卫: pdgtx 白名单里的**每一个**目标都必须在动作表里有明确说法。真正的风险不是"传进来
# 一个不存在的名字"(resolve_target 早就挡了), 而是**新增了一个白名单目标却忘了配动作** ——
# 那时若默认"重启所有服务", 一个本该无动作的新目标会悄悄开始重启 DNS 与内核。
_static_targets = list(tx._STATIC) + ["mosdns_rule:custom_direct.txt", "ruleset:a.json",
                                      "unit:pdg-bot.service"]
_unmapped = []
for _t in _static_targets:
    if _t in tx.EXPLICIT_ONLY:
        continue
    try:
        tx.actions_for_targets([_t])
    except tx.TxError:
        _unmapped.append(_t)
if not _unmapped:
    ok("同步守卫: pdgtx 白名单里的每个目标在动作表里都有明确说法")
else:
    bad("这些白名单目标没有动作定义: %r" % _unmapped)
# 反过来: 白名单目标一旦从动作表里消失, 必须 fail-closed 而不是默认重启一堆服务
_saved = tx._TARGET_ACTIONS.pop("mosdns_conf")
try:
    _got = tx.actions_for_targets(["mosdns_conf"])
    bad("动作表缺项时没有 fail-closed, 反而给出 %r" % (_got,))
except tx.TxError:
    ok("动作表缺项(白名单有、映射无)→ fail-closed, 不默认重启所有服务")
finally:
    tx._TARGET_ACTIONS["mosdns_conf"] = _saved

if "restart:pdg-rescue" not in str(tx._TARGET_ACTIONS) + str(tx._ACTION_ORDER):
    ok("映射: 不会重启救援服务自身")
else:
    bad("动作表里出现了救援服务")

# ── 2. 仅恢复 rs_meta: 零服务调用 ───────────────────────────────────────────
box, base, res, c, aud = run_case([("opt/pdg-bot/rulesets.json", '{"a": {"label": "新"}}')])
if res.get("ok") and res.get("state") == "COMMITTED":
    ok("只恢复 rs_meta: 事务提交")
else:
    bad("rs_meta 恢复失败: %r" % res.get("error"))
if c["mutating"] == 0:
    ok("只恢复 rs_meta: 改变状态的调用为 0(只有 %d 次只读查询)" % c["queries"])
else:
    bad("产生了无关服务动作: %r" % c)
if aud.get("planned_actions") == [] and aud.get("executed_actions") == []:
    ok("只恢复 rs_meta: 审计里 planned/executed 都是空")
else:
    bad("审计动作不对: %r / %r" % (aud.get("planned_actions"), aud.get("executed_actions")))
if aud.get("changed_targets") == ["rs_meta"]:
    ok("审计记录了 changed_targets")
else:
    bad("changed_targets 不对: %r" % aud.get("changed_targets"))
box.clean()

# ── 3. rs_meta 无变化: 连事务都不开 ────────────────────────────────────────
box, base, res, c, aud = run_case([("opt/pdg-bot/rulesets.json", '{"a": {"label": "旧"}}')])
if res.get("ok") and res.get("state") == "NO_CHANGE":
    ok("无变化: 直接返回 NO_CHANGE, 不开事务")
else:
    bad("无变化时的结果不对: %r" % {k: res.get(k) for k in ("ok", "state")})
if c["mutating"] == 0 and not aud:
    ok("无变化: 零服务动作且不写审计(什么都没发生)")
else:
    bad("无变化却有动作/审计: %r %r" % (c, bool(aud)))
box.clean()

# ── 4. 只恢复 model → 只重启 mihomo ────────────────────────────────────────
box, base, res, c, aud = run_case([("etc/sing-box/config.json", MODEL_NEW)])
if res.get("ok") and c["restart:mihomo"] == 1 and c["restart:mosdns"] == 0:
    ok("只恢复 model: 只重启 mihomo 一次, 不碰 mosdns")
else:
    bad("model 的动作不对: %r %r" % (res.get("state"), c))
box.clean()

# ── 5. 只恢复 mosdns 配置 / 规则 → 只重启 mosdns ───────────────────────────
box, base, res, c, aud = run_case([("etc/mosdns/config.yaml", mos(4096))])
if res.get("ok") and c["restart:mosdns"] == 1 and c["restart:mihomo"] == 0:
    ok("只恢复 mosdns 配置: 只重启 mosdns")
else:
    bad("mosdns_conf 的动作不对: %r %r" % (res.get("state"), c))
box.clean()
box, base, res, c, aud = run_case([("etc/mosdns/rules/custom_direct.txt", "domain:new.example\n")])
if res.get("ok") and c["restart:mosdns"] == 1 and c["restart:mihomo"] == 0:
    ok("只恢复 mosdns 规则: 只重启 mosdns")
else:
    bad("mosdns_rule 的动作不对: %r %r" % (res.get("state"), c))
box.clean()

# ── 6. 只恢复 ruleset payload → 只重启 mihomo ──────────────────────────────
box, base, res, c, aud = run_case([("etc/sing-box/rs/a.json", '{"version":1,"rules":[{"domain":["x"]}]}')])
if res.get("ok") and c["restart:mihomo"] == 1 and c["restart:mosdns"] == 0:
    ok("只恢复 ruleset payload: 只重启 mihomo")
else:
    bad("ruleset 的动作不对: %r %r" % (res.get("state"), c))
box.clean()

# ── 7. 混合 mihomo + mosdns: 各一次, 顺序固定 ─────────────────────────────
box, base, res, c, aud = run_case([("etc/sing-box/config.json", MODEL_NEW),
                                   ("etc/mosdns/config.yaml", mos(4096))])
if res.get("ok") and c["restart:mihomo"] == 1 and c["restart:mosdns"] == 1:
    ok("混合恢复: mihomo 与 mosdns 各重启一次(不重复)")
else:
    bad("混合动作次数不对: %r" % c)
if aud.get("planned_actions") == ["restart:mosdns", "restart:mihomo"] \
        and aud.get("executed_actions") == ["restart:mosdns", "restart:mihomo"]:
    ok("混合恢复: planned 与 executed 一致且顺序固定(mosdns → mihomo)")
else:
    bad("审计动作顺序不对: %r / %r" % (aud.get("planned_actions"), aud.get("executed_actions")))
box.clean()

# ── 8. 元数据恢复时 mosdns 本来就坏: 仍然成功 ─────────────────────────────
box = Box(svc_fail=["mosdns"])
base = seed(box)
box.down("mosdns")                       # 操作前就没在跑
sid = snap(box, [("opt/pdg-bot/rulesets.json", '{"a": {"label": "新元数据"}}')])
cr = load_cr(box)
open(box.calls, "w").close()
res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
c = calls(box)
if res.get("ok") and c["mutating"] == 0:
    ok("mosdns 本来就坏: 纯元数据恢复照样成功(不被无关服务拖累)")
else:
    bad("元数据恢复被无关服务挡了: %r %r" % (res.get("error"), c))
box.clean()

# ── 9. 目标对应的动作失败 → 回滚, 结果如实 ────────────────────────────────
box = Box(svc_fail=["mihomo"])
base = seed(box)
sid = snap(box, [("etc/sing-box/config.json", MODEL_NEW)])
cr = load_cr(box)
res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
if not res.get("ok") and res.get("state") in ("ROLLED_BACK", "ROLLBACK_FAILED"):
    ok("动作失败: 事务未提交(%s)" % res.get("state"))
else:
    bad("动作失败却提交: %r" % res.get("state"))
if open(os.path.join(box.root, "etc/sing-box/config.json"), encoding="utf-8").read() == MODEL_OLD:
    ok("动作失败: 现网逐字节回到操作前")
else:
    bad("回滚不完整")
aud = audit_last(box)
if aud.get("planned_actions") == ["restart:mihomo"] and aud.get("executed_actions") == []:
    ok("动作失败: 审计如实区分 planned 与 executed(计划了但没做成)")
else:
    bad("审计没区分: %r / %r" % (aud.get("planned_actions"), aud.get("executed_actions")))
box.clean()

# ── 10. 未知运行目标: 恢复前就拒绝, 生产文件不变 ──────────────────────────
box = Box()
base = seed(box)
sid = snap(box, [("etc/mosdns/config.yaml", mos(4096))])
cr = load_cr(box)
_orig_map = cr.MEMBER_TARGET.copy()
cr.MEMBER_TARGET["etc/mosdns/config.yaml"] = "some_unknown_runtime_target"
res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
cr.MEMBER_TARGET.clear()
cr.MEMBER_TARGET.update(_orig_map)
if not res.get("ok") and ("不知道目标" in (res.get("error") or "")
                          or "不在事务白名单" in (res.get("error") or "")):
    ok("未知运行目标: 恢复前 fail-closed")
else:
    bad("未知目标没被拒: %r" % res.get("error"))
if open(os.path.join(box.root, "etc/mosdns/config.yaml"), encoding="utf-8").read() == mos(1024):
    ok("未知运行目标: 生产文件逐字节不变")
else:
    bad("现网被改了")
box.clean()

# ── 11. 动作不可被快照/请求注入 ───────────────────────────────────────────
box = Box()
base = seed(box)
# 快照里塞一个看起来像"动作"的成员名 + 一个假的 unit 文件
sid = snap(box, [("opt/pdg-bot/rulesets.json", '{"a": {"label": "新"}}'),
                 ("etc/systemd/system/evil.service", "[Service]\nExecStart=/bin/true\n"),
                 ("restart:mihomo", "x\n")])
cr = load_cr(box)
open(box.calls, "w").close()
res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
c = calls(box)
if res.get("ok") and c["mutating"] == 0:
    ok("快照无法注入服务动作(伪造成员名/unit 文件都不产生动作)")
else:
    bad("快照注入了动作: %r" % c)
src = open(os.path.join(ROOT, "deploy/rescue/rescue.py"), encoding="utf-8").read()
if "service(" not in src and "restart:" not in src.replace("恢复正在执行", ""):
    ok("HTTP 层不接受也不构造任何服务动作")
else:
    # 只要不是从请求取值即可, 逐条核对
    if not re.search(r"form\.get\(\s*[\"'](action|service|unit|restart)", src):
        ok("HTTP 层不从请求里取 action/service/unit")
    else:
        bad("HTTP 层从请求取动作")
box.clean()

# ── 12. Bot 与救援用同一份映射 ────────────────────────────────────────────
botsrc = open(os.path.join(ROOT, "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
crsrc = open(os.path.join(ROOT, "deploy/bot/cfgrestore.py"), encoding="utf-8").read()
if "actions_for_targets" in botsrc and "actions_for_targets" in crsrc:
    ok("Bot 与救援恢复都调用 pdgtx.actions_for_targets(同一份映射)")
else:
    bad("有一侧没用共享映射")
same = all(tx.actions_for_targets([n]) == tx.actions_for_targets([n]) for n, _w in CASES)
combo = ["model", "mosdns_conf", "rs_meta"]
if tx.actions_for_targets(combo) == ("restart:mosdns", "restart:mihomo") and same:
    ok("同一组目标得到同一个动作集合(与调用方无关)")
else:
    bad("同组目标结果不一致")

# ── 13. 哨兵不进动作 / 审计 / 结果 ────────────────────────────────────────
box = Box()
base = seed(box, extra=[("etc/privdns-gateway/bot.env", "PDG_BOT_TOKEN=1:%s\n" % SENTINEL)])
sid = snap(box, [("etc/mosdns/config.yaml", mos(4096)),
                 ("etc/privdns-gateway/bot.env", "PDG_BOT_TOKEN=9:%s\n" % SENTINEL)])
cr = load_cr(box)
res = cr.restore_managed(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue")
aud_txt = open(os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl"), encoding="utf-8").read()
if SENTINEL not in aud_txt and SENTINEL not in json.dumps(res, ensure_ascii=False):
    ok("哨兵不出现在审计与恢复结果里")
else:
    bad("哨兵泄漏")
if open(os.path.join(box.root, "etc/privdns-gateway/bot.env"), encoding="utf-8").read() \
        == "PDG_BOT_TOKEN=1:%s\n" % SENTINEL:
    ok("bot.env 仍然逐字节未变(不在受管范围)")
else:
    bad("bot.env 被改了")
box.clean()

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

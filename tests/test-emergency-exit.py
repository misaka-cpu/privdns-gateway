#!/usr/bin/env python3
"""紧急默认出口(T6)回归。

它的处境: 默认出口挂了、手机什么都打不开、Bot 也连不上(它自己就走那条链路)。救援页上按一下
就把"其余流量"换到另一个还活着的出口。正因为是在最混乱的时候用, 每条边界都必须硬:

  · **只改 route.final** —— 规则、优先级、规则集一个字都不动。它不是"全局强制单出口",
    页面上必须原样写着这句话, 否则用户会据此得出完全错误的排障结论;
  · model + 派生 mihomo_cfg + rescue_state **同一笔事务** —— 状态文件绝不在事务外单独写,
    否则失败之后盘上会留一个"说自己启用了"的状态而配置没变, 之后的一键恢复会照着幻觉改配置;
  · 首次启用记下原值; 连切几次都不覆盖最初那份 —— 否则"恢复"把用户送回上一个紧急出口;
  · 恢复要精确, 包括**原本就没有 route.final** 那种(删键, 不写 null);
  · 当前配置与状态记录对不上 → stale → 拒绝恢复, 绝不覆盖用户后来的修改。

真事务、真 pdgtx、真 mihomo -t(钉死版), 不 mock 事务层。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tests"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-emerg-4b7"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def eq(label, got, want):
    if got == want:
        ok(label)
    else:
        bad("%s\n        实得: %r\n        期望: %r" % (label, got, want))


MIHOMO = shutil.which("mihomo") or os.environ.get("PDG_TEST_MIHOMO", "")


def make_model(final="jp", with_final=True):
    m = {"log": {"level": "warn"}, "inbounds": [],
         "outbounds": [
             {"type": "direct", "tag": "direct"},
             {"type": "shadowsocks", "tag": "jp", "server": "1.2.3.4", "server_port": 8388,
              "method": "aes-128-gcm", "password": SENTINEL},
             {"type": "shadowsocks", "tag": "hk", "server": "5.6.7.8", "server_port": 8388,
              "method": "aes-128-gcm", "password": SENTINEL},
             {"type": "urltest", "tag": "auto", "outbounds": ["jp", "hk"]},
             {"type": "block", "tag": "block"},
         ],
         "route": {"rules": [{"domain_suffix": ["keep.test"], "outbound": "hk"},
                             {"rule_set": "rs_x", "outbound": "jp"}],
                   "final": final}}
    if not with_final:
        m["route"].pop("final")
    return m


def make_box(model=None):
    box = Box()
    box.up("mihomo")
    box.up("mosdns")
    files = {"etc/sing-box/config.json": json.dumps(model if model is not None else make_model()),
             "etc/privdns-gateway/platform": "android\n",
             "opt/pdg-bot/rulesets.json": json.dumps(
                 {"rs_x": {"url": "https://ex.test/x.list"}})}
    for rel, data in files.items():
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8").write(data)
    return box


def load_em(box):
    for k, v in box.env.items():
        os.environ[k] = v
    os.environ["PDG_TX_FSROOT"] = box.root
    for m in ("pdgtx", "mihomorender", "emergency", "sb2mihomo"):
        sys.modules.pop(m, None)
    import emergency
    return emergency


def paths_for(box):
    return {"rs_meta_path": box.root + "/opt/pdg-bot/rulesets.json",
            "mitm_hijack_file": box.root + "/etc/mosdns/rules/mitm_hijack.txt",
            "platform_file": box.root + "/etc/privdns-gateway/platform"}


def read_model(box):
    return json.load(open(os.path.join(box.root, "etc/sing-box/config.json"), encoding="utf-8"))


def read_state(box):
    p = os.path.join(box.root, "var/lib/privdns-gateway/rescue-state.json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None


def audit_recs(box):
    f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    if not os.path.exists(f):
        return []
    out = []
    for line in open(f, encoding="utf-8"):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


# ══ 1. 启用: 只改 route.final, 三个目标同事务 ═══════════════════════════════
print("── 1. 启用 ──")
box = make_box()
em = load_em(box)
before = read_model(box)
res = em.enable("hk", paths=paths_for(box))
eq("启用提交成功", res["state"], "COMMITTED")
after = read_model(box)
eq("route.final 换成了所选出口", after["route"]["final"], "hk")
eq("分流规则**一个字没动**", after["route"]["rules"], before["route"]["rules"])
eq("出口列表没动", after["outbounds"], before["outbounds"])
eq("除 route.final 外整份模型都没动",
   {k: v for k, v in after.items() if k != "route"},
   {k: v for k, v in before.items() if k != "route"})
eq("本次改动的三个目标", sorted(res["changed"]), ["mihomo_cfg", "model", "rescue_state"])
st = read_state(box)
eq("状态: active", st["active"], True)
eq("状态: 记下原本有 route.final", st["original_present"], True)
eq("状态: 原值", st["original_final"], "jp")
eq("状态: 紧急出口", st["emergency_final"], "hk")
if st.get("route_digest") and st.get("enabled_at") and st.get("schema_version") == 1:
    ok("状态含 schema_version / enabled_at / route 前置摘要")
else:
    bad("状态字段不全: %r" % st)
if SENTINEL not in json.dumps(st, ensure_ascii=False):
    ok("状态文件不含出口密码哨兵")
else:
    bad("状态泄漏密码")
mode = oct(os.stat(os.path.join(box.root, "var/lib/privdns-gateway/rescue-state.json")).st_mode)[-3:]
eq("状态文件权限 0600", mode, "600")
# 派生的内核配置也跟着换了 —— 否则改了 model 内核照旧跑旧的
mih = open(os.path.join(box.root, "etc/mihomo/config.yaml"), encoding="utf-8").read()
if '"MATCH,hk"' in mih or "MATCH,hk" in mih:
    ok("派生的 mihomo 配置里 MATCH 已指向新出口(同事务重渲)")
else:
    bad("mihomo 配置没跟着换: %s" % [l for l in mih.splitlines() if "MATCH" in l][:2])
acts = res.get("executed_actions") or []
if any("mihomo" in a for a in acts) and not any(
        x in " ".join(acts) for x in ("mosdns", "pdg-bot", "pdg-probe81", "pdg-rescue")):
    ok("只重启 mihomo(mosdns / Bot / probe81 / 救援服务都不动): %r" % acts)
else:
    bad("服务动作不对: %r" % acts)

# ══ 2. 幂等 + 连续切换不覆盖原值 ═══════════════════════════════════════════
print()
print("── 2. 重复与连续切换 ──")
res2 = em.enable("hk", paths=paths_for(box))
eq("同一个出口再按一次 → 幂等", res2["state"], "NO_CHANGE")
eq("幂等时没有任何服务动作", res2.get("executed_actions") or [], [])
eq("幂等时状态时间不变", read_state(box)["enabled_at"], st["enabled_at"])
res3 = em.enable("direct", paths=paths_for(box))
eq("切到另一个紧急出口", res3["state"], "COMMITTED")
st3 = read_state(box)
eq("**原值仍是第一次那份**(不被上一个紧急出口覆盖)", st3["original_final"], "jp")
eq("紧急出口更新为新的", st3["emergency_final"], "direct")
eq("route.final 已是新的", read_model(box)["route"]["final"], "direct")

# ══ 3. 一键恢复: 精确还原 ══════════════════════════════════════════════════
print()
print("── 3. 一键恢复 ──")
res4 = em.restore(paths=paths_for(box))
eq("恢复提交成功", res4["state"], "COMMITTED")
back = read_model(box)
eq("route.final 精确还原成原值", back["route"]["final"], "jp")
eq("恢复后规则仍未变", back["route"]["rules"], before["route"]["rules"])
eq("整份模型与启用前逐字段一致", back, before)
eq("状态已置为未启用", read_state(box)["active"], False)
res5 = em.restore(paths=paths_for(box))
if not res5["ok"] and "未启用" in res5["error"]:
    ok("未启用时再按恢复 → 明确拒绝")
else:
    bad("重复恢复没拒绝: %r" % res5)
box.clean()

# ══ 4. 原本没有 route.final: 恢复要删键而不是写 null ═══════════════════════
print()
print("── 4. 原本没有 route.final ──")
box = make_box(make_model(with_final=False))
em = load_em(box)
res = em.enable("hk", paths=paths_for(box))
eq("启用成功", res["state"], "COMMITTED")
eq("状态记下「原本没有这个键」", read_state(box)["original_present"], False)
res = em.restore(paths=paths_for(box))
eq("恢复成功", res["state"], "COMMITTED")
m = read_model(box)
if "final" not in m["route"]:
    ok("恢复后 route.final 这个键被**删掉**(不是写成 null)")
else:
    bad("恢复后仍有 final=%r" % m["route"].get("final"))
box.clean()

# ══ 5. stale: 外部改过 route.final ═════════════════════════════════════════
print()
print("── 5. 状态过期(fail-closed)──")
box = make_box()
em = load_em(box)
em.enable("hk", paths=paths_for(box))
# 模拟 Bot/CLI 在紧急期间把默认出口又改了
m = read_model(box)
m["route"]["final"] = "auto"
open(os.path.join(box.root, "etc/sing-box/config.json"), "w").write(json.dumps(m))
stt = em.status(read_model(box), open(
    os.path.join(box.root, "var/lib/privdns-gateway/rescue-state.json"), "rb").read())
eq("status 判为 stale", stt["stale"], True)
eq("last_state = stale", stt["last_state"], "stale")
res = em.restore(paths=paths_for(box))
if not res["ok"] and "过期" in res["error"]:
    ok("stale 时一键恢复被拒绝(不覆盖用户后来的修改)")
else:
    bad("stale 时竟然恢复了: %r" % res)
eq("现网 route.final 保持用户改的值", read_model(box)["route"]["final"], "auto")
eq("状态仍保留(没有被清掉)", read_state(box)["active"], True)
# stale 之后重新启用: 以**当前值**作为新的原值
res = em.enable("jp", paths=paths_for(box))
eq("stale 后重新启用成功", res["state"], "COMMITTED")
eq("新原值取自当前值(auto), 不是那份早已不成立的旧记录",
   read_state(box)["original_final"], "auto")
box.clean()

# ══ 6. 候选出口枚举与非法 tag ══════════════════════════════════════════════
print()
print("── 6. 候选枚举 ──")
box = make_box()
em = load_em(box)
cands = em.candidates(read_model(box))
eq("候选含代理出口 / direct / 故障组", sorted(cands), ["auto", "direct", "hk", "jp"])
if "block" not in cands:
    ok("block 之类的内部出站不在候选里")
else:
    bad("候选里混进了 block")
res = em.enable("nope-" + SENTINEL, paths=paths_for(box))
if not res["ok"] and "不在当前模型里" in res["error"]:
    ok("伪造的 tag 被拒绝(POST 侧还会再枚举核对一次)")
else:
    bad("伪造 tag 没拒: %r" % res)
# 按已确认的取舍: 出口标识**允许**以脱敏 + 截断后的形式出现在主动展示的文案里(用户要靠它
# 定位), 只有 str/repr/args/vars/traceback 那组非主动渠道必须零标识。所以这里验的是"确实
# 过了那层处理", 而不是"一个字符都不许出现"。
import mihomorender as _MR  # noqa: E402
_long = "x" * 300 + SENTINEL
_res_long = em.enable(_long, paths=paths_for(box))
if len(_res_long["error"]) < 200 and "…" in _res_long["error"]:
    ok("超长 tag 在拒绝信息里被截断(不是把整段原样回显)")
else:
    bad("超长 tag 没截断: %d 字符" % len(_res_long["error"]))
_cred = em.enable("tok=" + "a" * 40, paths=paths_for(box))
if "aaaa" not in _cred["error"]:
    ok("凭据形态的 tag 在拒绝信息里被脱敏")
else:
    bad("凭据形态未脱敏: %r" % _cred["error"])
eq("失败后 route.final 没动", read_model(box)["route"]["final"], "jp")
if read_state(box) is None:
    ok("失败后状态文件根本没被创建(事务外不写状态)")
else:
    bad("失败却写了状态: %r" % read_state(box))

# ══ 7. 事务失败: 三个目标一起回滚 ═════════════════════════════════════════
print()
print("── 7. 失败回滚 ──")
em.enable("hk", paths=paths_for(box))
snap_model, snap_state = read_model(box), read_state(box)
# 让内核配置校验失败 → 整笔事务必须回滚, 三个目标都回到操作前
os.environ["PDG_STUB_MIHOMO_FAIL"] = "1"
bad_bin = os.path.join(box.bin, "mihomo")
open(bad_bin, "w").write("#!/bin/sh\nexit 3\n")
os.chmod(bad_bin, 0o755)
res = em.enable("direct", paths=paths_for(box))
if not res["ok"]:
    ok("内核校验失败 → 事务未提交(%s)" % (res.get("state") or res.get("error", "")[:40]))
else:
    bad("内核校验失败却提交了")
eq("回滚后 model 逐字节回到操作前", read_model(box), snap_model)
eq("回滚后 rescue_state 也回到操作前", read_state(box), snap_state)
os.environ.pop("PDG_STUB_MIHOMO_FAIL", None)
box.clean()

# ══ 8. 损坏的状态文件: fail-closed ════════════════════════════════════════
print()
print("── 8. 状态文件损坏 ──")
box = make_box()
em = load_em(box)
sp = os.path.join(box.root, "var/lib/privdns-gateway/rescue-state.json")
os.makedirs(os.path.dirname(sp), exist_ok=True)
open(sp, "w").write("{ 这不是 JSON")
os.chmod(sp, 0o600)
stt = em.status(read_model(box), open(sp, "rb").read())
eq("坏状态 → 当作未启用(不据读不懂的记录改配置)", stt["active"], False)
res = em.restore(paths=paths_for(box))
if not res["ok"]:
    ok("坏状态时恢复被拒绝")
else:
    bad("坏状态却恢复了")
eq("route.final 一个字没动", read_model(box)["route"]["final"], "jp")
# schema 版本不认识的同样当作未启用
open(sp, "w").write(json.dumps({"schema_version": 99, "active": True,
                                "emergency_final": "hk", "original_final": "zz"}))
eq("未知 schema_version → 当作未启用", em.status(read_model(box),
                                                open(sp, "rb").read())["active"], False)

# ══ 9. 审计 ═══════════════════════════════════════════════════════════════
print()
print("── 9. 审计 ──")
box2 = make_box()
em2 = load_em(box2)
em2.enable("hk", paths=paths_for(box2))
em2.restore(paths=paths_for(box2))
recs = audit_recs(box2)
en = [r for r in recs if r.get("op") == "emergency_default_enable"]
rs = [r for r in recs if r.get("op") == "emergency_default_restore"]
if en and en[-1].get("trigger_source") == "rescue" and en[-1].get("emergency_tag") == "hk" \
        and en[-1].get("original_tag") == "jp" and en[-1].get("original_present") is True \
        and en[-1].get("txid"):
    ok("启用审计: op / trigger_source / original_present / original_tag / emergency_tag / txid")
else:
    bad("启用审计字段不全: %r" % (en[-1] if en else None))
if rs and rs[-1].get("restored_tag") == "jp" and rs[-1].get("txid"):
    ok("恢复审计: restored_tag + txid")
else:
    bad("恢复审计字段不全: %r" % (rs[-1] if rs else None))
if SENTINEL not in json.dumps(recs, ensure_ascii=False):
    ok("审计不含出口密码哨兵")
else:
    bad("审计泄漏哨兵")
box2.clean()

# 原本没有 final 时, 恢复审计要记 absent 而不是编一个 tag
box3 = make_box(make_model(with_final=False))
em3 = load_em(box3)
em3.enable("hk", paths=paths_for(box3))
em3.restore(paths=paths_for(box3))
rs3 = [r for r in audit_recs(box3) if r.get("op") == "emergency_default_restore"]
if rs3 and rs3[-1].get("restored_absent") is True and "restored_tag" not in rs3[-1]:
    ok("原本没有 route.final: 恢复审计记 restored_absent")
else:
    bad("absent 审计不对: %r" % (rs3[-1] if rs3 else None))
box3.clean()

# ══ 10. 真 mihomo -t ══════════════════════════════════════════════════════
print()
print("── 10. 钉死版 mihomo -t ──")
if not MIHOMO:
    bad("找不到 mihomo(装钉死版或设 PDG_TEST_MIHOMO) —— 不接受跳过")
else:
    box4 = make_box()
    em4 = load_em(box4)
    r = em4.enable("hk", paths=paths_for(box4))
    if r["state"] != "COMMITTED":
        bad("启用失败, 无法做内核校验: %r" % r)
    else:
        d = os.path.join(box4.root, "etc/mihomo")
        p = subprocess.run([MIHOMO, "-t", "-d", d, "-f", os.path.join(d, "config.yaml")],
                           capture_output=True, text=True, timeout=120)
        if p.returncode == 0:
            ok("紧急出口生效后的 mihomo 配置通过真内核校验")
        else:
            bad("mihomo -t 失败: %s" % ((p.stdout or "") + (p.stderr or ""))[-300:])
    box4.clean()
box.clean()

# ══ 11. HTTP 层: 页面文案 / 票据 / 并发 / 断线 ════════════════════════════
print()
print("── 11. HTTP 层 ──")
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
from rescuebox import Inst, TOKEN  # noqa: E402
import re as _re  # noqa: E402
import urllib.parse as _up  # noqa: E402

hbox = make_box()
work = tempfile.mkdtemp(prefix="emerghttp.")
# 把 box 的**整套**环境透传给救援进程 —— 少传一个(比如 PDG_TX_REDIR_PORT)事务的硬门就
# 会打到真机上去探端口, 于是拒绝在"已损坏的组件"上做普通变更。
inst = Inst(work, extra_env=dict(hbox.env, PDG_STABLE_SAMPLES="1",
                                 PDG_STABLE_INTERVAL="0.05"))
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:300])
else:
    _st, cookie = inst.login()
    st_code, body, _sc, _h = inst.req("GET", "/emergency", cookie=cookie)
    SCOPE = ("紧急默认出口只修改 route.final。已有高优先级规则仍会命中各自出口, "
             "这不是全局强制单出口。")
    if st_code == 200 and SCOPE in body:
        ok("页面原样写明「只改 route.final, 不是全局强制单出口」")
    else:
        bad("页面缺少范围说明: st=%s" % st_code)
    for kw in ("当前 route.final", "未启用", "jp", "hk", "auto"):
        if kw not in body:
            bad("页面缺少要素: %s" % kw)
            break
    else:
        ok("页面显示当前 final / 状态 / 可选出口")
    if "block" not in _re.sub(r"<[^>]+>", " ", body):
        ok("候选里不含 block 之类的内部出站")
    else:
        bad("页面把 block 列成了候选")

    def post(path, fields, cookie=cookie):
        return inst.req("POST", path, body=_up.urlencode(fields), cookie=cookie)

    def form_fields(b):
        return {"csrf": (_re.search(r"name=csrf value='([^']*)'", b) or _re.match("", "")).group(1)
                if _re.search(r"name=csrf value='([^']*)'", b) else "",
                "nonce": _re.search(r"name=nonce value='([^']*)'", b).group(1)
                if _re.search(r"name=nonce value='([^']*)'", b) else ""}

    f = form_fields(body)
    # 无 CSRF → 403
    st_code, _b, _s, _h = post("/emergency/enable", {"tag": "hk", "nonce": f["nonce"]})
    if st_code == 403:
        ok("无 CSRF → 403")
    else:
        bad("无 CSRF 返回 %s" % st_code)
    # 伪造 tag → 400(服务端重新枚举核对)
    st_code, _b, _s, _h = post("/emergency/enable",
                               dict(f, tag="nope-" + SENTINEL))
    if st_code == 400:
        ok("HTTP 伪造 tag → 400(服务端重新枚举核对, 不信表单)")
    else:
        bad("伪造 tag 返回 %s" % st_code)
    # 正常启用
    body2 = inst.req("GET", "/emergency", cookie=cookie)[1]
    f2 = form_fields(body2)
    st_code, rbody, _s, _h = post("/emergency/enable", dict(f2, tag="hk"))
    if st_code == 200 and "COMMITTED" in rbody:
        ok("HTTP 启用成功并返回结构化结果页")
    else:
        bad("HTTP 启用失败: st=%s %s" % (st_code, rbody[-200:]))
    if SCOPE in rbody:
        ok("结果页同样写明范围(不是全局强制单出口)")
    else:
        bad("结果页缺少范围说明")
    # 重放同一张票 → 409
    st_code, _b, _s, _h = post("/emergency/enable", dict(f2, tag="hk"))
    if st_code == 409:
        ok("重放同一张票 → 409(双击只执行一次)")
    else:
        bad("重放返回 %s" % st_code)
    # 跨操作复用: 紧急出口的票不能拿去做完整恢复
    body3 = inst.req("GET", "/emergency", cookie=cookie)[1]
    f3 = form_fields(body3)
    st_code, _b, _s, _h = inst.req(
        "POST", "/breakglass/restore",
        body=_up.urlencode({"csrf": f3["csrf"], "snapshot": "20250101-010101",
                            "digest": "x", "nonce": f3["nonce"], "confirm_text": "010101"}),
        cookie=cookie)
    if st_code in (404, 409):
        ok("紧急出口的票不能用于完整恢复(op 维度绑定)")
    else:
        bad("跨操作复用返回 %s" % st_code)
    # 恢复
    body4 = inst.req("GET", "/emergency", cookie=cookie)[1]
    if "一键恢复到启用前" in body4:
        ok("启用后页面出现一键恢复按钮")
    else:
        bad("没有恢复按钮")
    f4 = form_fields(body4)
    st_code, rb, _s, _h = post("/emergency/restore", f4)
    if st_code == 200 and "COMMITTED" in rb:
        ok("HTTP 一键恢复成功")
    else:
        bad("HTTP 恢复失败: st=%s" % st_code)
    m = json.load(open(os.path.join(hbox.root, "etc/sing-box/config.json")))
    if m["route"]["final"] == "jp":
        ok("HTTP 恢复后 route.final 精确还原")
    else:
        bad("恢复后 final=%r" % m["route"]["final"])
    # 哨兵不得进入页面
    leaks = [p for p in ("/", "/emergency", "/audit")
             if SENTINEL in inst.req("GET", p, cookie=cookie)[1]]
    if not leaks:
        ok("状态页 / 紧急出口页 / 审计页都不含出口密码哨兵")
    else:
        bad("页面泄漏哨兵: %r" % leaks)
    # 状态页有入口与能力项
    sbody = inst.req("GET", "/", cookie=cookie)[1]
    if "/emergency" in sbody and "紧急默认出口" in sbody:
        ok("状态页有紧急默认出口的入口与能力项")
    else:
        bad("状态页缺入口")
inst.stop()
shutil.rmtree(work, ignore_errors=True)
hbox.clean()

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""WLOC 退役 · iOS 描述文件记录 schema 1 → 2 迁移。

退役的最后一段, 也是最容易做错的一段: **手机上那份描述文件里嵌着一张根证书**。网关这边
把服务停掉、把劫持撤掉都不够 —— 只要还能把那份旧产物再发一次, 用户就会又装一次同一张
受信根 CA, 而它的私钥现在没人再管了。

所以退役在这一层要回答三个问题, 每个都对应一组判据:

  一、**旧记录还读不读得懂**。schema 1 的记录不能一删了之: 里面有 instance_id —— 丢了就
      造出第二个身份, 用户手机上那份从此永远无法再被更新, 而界面上什么都不会报。
  二、**迁移是不是真的迁了**, 而不是把 `!= SCHEMA` 放宽成 `in {1, 2}` 就宣称兼容。判据:
      迁完之后记录必须是**严格的 schema 2**(没有 wloc 字段、摘要按新输入重算过), 而且
      schema 1 的严格校验一条都不许放松 —— 恶意/损坏的旧记录要在迁移**之前**就被拒掉。
  三、**退役的 CA 会不会又发出去**。current / previous / repair / restore / 重新发送,
      五条路一条都不能漏。

三种老机器状态分开验(它们的正确结果互不相同):
  · 从没配过     → 没有记录文件, 什么都不做。
  · 配过但关着   → 产物里本来就**没有**根证书, 它已经是一份合法的 schema 2 产物 ——
                   记录原地迁移, 产物一个字节不动, 用户什么都不用做。
  · 开着         → 产物里嵌着根证书, schema 2 没有任何办法描述它 —— 那个槽位必须退役,
                   用户必须重新生成。这一格最关键: 把它"迁移"成一条 schema 2 记录而把
                   CA 产物留在原地, 等于用新格式给旧证书背书。
"""
import hashlib
import importlib.util as u
import json
import os
import plistlib
import shutil
import stat
import sys
import tempfile
from pathlib import Path

import tmpguard

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy" / "bot"
sys.path.insert(0, str(BOT))

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   " + m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] " + m)


def chk(c, m):
    (ok if c else bad)(m)


import iosprofile  # noqa: E402
import iosstate as S  # noqa: E402

TMPL = str(ROOT / "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")

# 造"退役前那台机器"的那几个构造函数已经提取到 tests/wloc_legacy_fixture.py ——
# shell 那边的组合用例(test-platform-schema-restore.sh)要用**同一套**构造方式, 各造各的
# 就等于两边对"什么叫一份合法的旧记录"各有一套说法。这里只留薄薄一层转接, 行为不变。
import wloc_legacy_fixture as F  # noqa: E402

DOT, IP = F.DOT, F.IP
CA_DER = F.ca_der(str(BOT), tmpguard.mkdtemp(prefix="pdg-schema-ca."))


def _render_legacy(ssids, der, ids):
    return F.render_legacy(str(BOT), TMPL, ssids, der, ids)


def legacy_meta(work, *, wloc, ssids=(), revisions=2):
    return F.legacy_meta(work, wloc=wloc, ssids=ssids, revisions=revisions,
                         modules=str(BOT), tmpl=TMPL, der=CA_DER if wloc else b"")


def _ca_der():
    return F.ca_der(str(BOT), tmpguard.mkdtemp(prefix="pdg-schema-ca."))


has_ca = F.has_ca


# ══ 0. 版本常量 ══════════════════════════════════════════════════════════════
print("══ 0. 版本常量 ══")
chk(S.SCHEMA == 2, "运行时 schema 已升到 2(实得 %r)" % S.SCHEMA)
chk(hasattr(S, "migrate_schema"), "有明确的迁移入口 migrate_schema")
# 骨架必须是**同一个**常量: schema 1 与 2 的 OnDemand 语义完全相同, 复制一份迟早漂移成
# 一松一紧, 而松的那份就是出口。
src = (BOT / "iosstate.py").read_text(encoding="utf-8")
import re as _re
defs = _re.findall(r"^(_[A-Z0-9_]*ONDEMAND[A-Z0-9_]*) = \[", src, _re.M)
chk(defs == ["_ONDEMAND_CORE"],
    "OnDemand 骨架只有一份常量, 且名字不绑某个 schema(实得 %s)" % defs)
# 名字里带 SCHEMA1 的那个老名字也不该还在: 它会让人以为 schema 2 另有一份。
chk("_SCHEMA1_ONDEMAND_CORE" not in src, "旧的 _SCHEMA1_ONDEMAND_CORE 这个名字已不在")

# ══ 1. 从没配过 ══════════════════════════════════════════════════════════════
print()
print("══ 1. 从没配过 WLOC(也没生成过描述文件)══")
w = tmpguard.mkdtemp(prefix="pdg-schema-never.")
mp = os.path.join(w, "ios-profile.json")
chk(S.load(mp) is None, "没有记录文件 → load 返回 None(不是报错)")
try:
    rep = S.migrate_schema(meta_path=mp, art_root=os.path.join(w, "art"), lock=False)
    chk(rep.get("changed") is False, "迁移在没有记录时是空操作(实得 %r)" % rep)
except Exception as e:  # noqa: BLE001
    bad("没有记录时迁移抛 %s: %s" % (type(e).__name__, str(e)[:70]))
chk(not os.path.exists(mp), "迁移没有凭空造出一份记录(那会造出第二个身份)")

# ══ 2. 配过但 WLOC 关着 ══════════════════════════════════════════════════════
print()
print("══ 2. 配过、但 WLOC 一直关着 ══")
w = tmpguard.mkdtemp(prefix="pdg-schema-off.")
mp, art, old = legacy_meta(w, wloc=False, ssids=("HomeWiFi",))
cur_sha_before = hashlib.sha256(open(os.path.join(art, S.CUR), "rb").read()).hexdigest()
rep = S.migrate_schema(meta_path=mp, art_root=art, lock=False)
new = json.load(open(mp, encoding="utf-8"))
chk(rep.get("changed") is True, "关着的老记录也要迁移(schema 本身变了)")
chk(new["schema"] == 2, "记录 schema 已是 2(实得 %r)" % new.get("schema"))
chk(new["instance_id"] == old["instance_id"], "instance_id 原样保留(丢了就多一个身份)")
chk(new["created_at"] == old["created_at"], "created_at 原样保留")
chk(new.get("current") is not None, "current 槽位保留 —— 这份产物本来就不含根证书")
chk(new["current"]["revision"] == old["current"]["revision"],
    "版本号不变(实得 %r)" % (new.get("current") or {}).get("revision"))
chk(new["current"]["sha256"] == old["current"]["sha256"], "产物指纹不变")
chk(hashlib.sha256(open(os.path.join(art, S.CUR), "rb").read()).hexdigest() == cur_sha_before,
    "产物文件一个字节都没动")
ci = new["current"]["inputs"]
chk("wloc_enabled" not in ci and "wloc_ca_sha256" not in ci,
    "schema 2 的 inputs 里没有 WLOC 字段(实得 %s)" % sorted(set(ci) & {"wloc_enabled", "wloc_ca_sha256"}))
chk(ci["schema"] == 2, "inputs.schema 也升到了 2")
chk(new["current"]["digest"] == S.digest_of(ci), "摘要按新 inputs 重算过(不是照抄旧值)")
chk(new["current"]["digest"] != old["current"]["digest"],
    "摘要**确实变了** —— 字段集变了而摘要不变, 说明根本没重算")
for k in ("dot_host", "server_addresses", "dns_protocol", "probe_url", "ssids", "ondemand_core"):
    chk(ci[k] == old["current"]["inputs"][k], "语义保留: inputs.%s 未变" % k)
chk(new.get("previous") is not None and new["previous"]["inputs"]["schema"] == 2,
    "previous 也一并迁移")
chk(new.get("retired_revision") is None, "没有槽位被退役 → retired_revision 为空")
# 迁完必须能被**严格的 schema 2 契约**接住, 而且判定是"无需更新"(什么都没坏)
lv, why = S.classify(S.load(mp), S.effective_inputs(S.load(mp), DOT, IP, None, TMPL))
chk(lv == S.NONE, "关着的机器迁完 → 无需更新(实得 %s: %s)" % (lv, why))
r = S.migrate_schema(meta_path=mp, art_root=art, lock=False)
chk(r.get("changed") is False, "再迁一次是空操作(幂等)")

# ══ 3. WLOC 开着 ═════════════════════════════════════════════════════════════
print()
print("══ 3. WLOC 开着(产物里嵌着根证书)══")
w = tmpguard.mkdtemp(prefix="pdg-schema-on.")
mp, art, old = legacy_meta(w, wloc=True)
chk(has_ca(os.path.join(art, S.CUR)) is True, "前置: 老产物里确实有根证书 payload")
rep = S.migrate_schema(meta_path=mp, art_root=art, lock=False)
new = json.load(open(mp, encoding="utf-8"))
chk(new["schema"] == 2, "记录 schema 已是 2")
chk(new["instance_id"] == old["instance_id"],
    "instance_id 仍然保留 —— 重新生成的那份要**替换**手机上的旧描述文件, 不是并存")
chk(new.get("current") is None, "带根证书的 current 槽位已退役(不能再被发出去)")
chk(new.get("previous") is None, "带根证书的 previous 槽位一并退役")
chk(new.get("retired_revision") == old["current"]["revision"],
    "记下了被退役的版本号(实得 %r, 期望 %r) —— 否则下次生成会从第 1 版重新数"
    % (new.get("retired_revision"), old["current"]["revision"]))
for f in (S.CUR, S.PREV):
    chk(not os.path.exists(os.path.join(art, f)),
        "带根证书的产物文件已从盘上移除: %s" % f)
lv, why = S.classify(S.load(mp), S.effective_inputs(S.load(mp), DOT, IP, None, TMPL))
chk(lv == S.REQUIRED, "开着的机器迁完 → 必须重新生成(实得 %s)" % lv)
chk(any("退役" in r or "根证书" in r for r in why),
    "理由里说清了这是 WLOC 退役造成的(实得 %s)" % why)

# 重新生成一份: 必须不含根证书, 且版本号接着往下数
meta2, lv2, why2, data2, changed2 = S.generate(DOT, IP, None, TMPL, meta_path=mp,
                                               art_root=art, lock=False)
chk(changed2 is True, "重新生成产生了新版本")
chk(meta2["current"]["revision"] == old["current"]["revision"] + 1,
    "新版本号接着退役那一版往下数(实得 %r)" % meta2["current"]["revision"])
chk(has_ca(os.path.join(art, S.CUR)) is False, "新产物里没有根证书 payload")
chk(meta2["instance_id"] == old["instance_id"], "重新生成沿用同一个 instance_id")
chk(S.derive_ids(meta2["instance_id"]) == S.derive_ids(old["instance_id"]),
    "派生出的各 payload 身份与退役前一致(装上去是替换而不是并存)")

# ══ 4. 五条路都不许再下发退役 CA ═════════════════════════════════════════════
print()
print("══ 4. current / previous / repair / restore / 重新发送 ══")
# current: 上面已验。previous:
chk(meta2.get("previous") is None, "退役后第一次生成没有把带 CA 的旧版留作 previous")
# repair: 逐字节复原的对象是**新的**那一版, 复原不出带 CA 的东西
S.repair_current(template=TMPL, meta_path=mp, art_root=art, lock=False)
chk(has_ca(os.path.join(art, S.CUR)) is False, "repair 复原出来的仍然不含根证书")
# 重新发送: verified_artifact 交出去的字节里没有 CA
blob = S.verified_artifact(S.load(mp), "current", art)
chk(b"com.apple.security.root" not in blob, "重新发送交出的字节里没有根证书 payload")
# restore: 拿一份**退役前的备份**去恢复, 不许把带 CA 的产物放回来
w2 = tmpguard.mkdtemp(prefix="pdg-schema-restore.")
bmp, bart, _b = legacy_meta(w2, wloc=True)
tree = tmpguard.mkdtemp(prefix="pdg-schema-tree.")
os.makedirs(os.path.join(tree, "etc/privdns-gateway"), exist_ok=True)
os.makedirs(os.path.join(tree, "var/lib/privdns-gateway/ios-profile"), exist_ok=True)
shutil.copy(bmp, os.path.join(tree, "etc/privdns-gateway/ios-profile.json"))
shutil.copy(os.path.join(bart, S.CUR),
            os.path.join(tree, "var/lib/privdns-gateway/ios-profile", S.CUR))
shutil.copy(os.path.join(bart, S.PREV),
            os.path.join(tree, "var/lib/privdns-gateway/ios-profile", S.PREV))
try:
    plan, note = S.plan_from_tree(tree)
    got = "plan"
except S.RestoreRefused as e:
    plan, note, got = None, str(e), "refused"
except S.StateError as e:
    plan, note, got = None, str(e), "refused"
if got == "refused":
    ok("旧备份里那份带根证书的产物被恢复入口拒掉(理由: %s)" % (note or "")[:60])
else:
    tgt = {t: v for t, v in (plan or {}).items()} if isinstance(plan, dict) else {}
    blobs = [v for v in tgt.values() if isinstance(v, (bytes, bytearray))]
    if any(b"com.apple.security.root" in b for b in blobs):
        bad("恢复计划里带着根证书 payload —— 旧备份把退役的 CA 放回来了")
    else:
        ok("恢复计划里没有根证书 payload")

# ══ 5. schema 1 的严格校验一条都不许放松 ═════════════════════════════════════
print()
print("══ 5. 恶意/损坏的旧记录要在迁移之前就被拒 ══")


def mutate(fn, label, expect_refuse=True):
    ww = tmpguard.mkdtemp(prefix="pdg-schema-mut.")
    mpp, arr, m = legacy_meta(ww, wloc=False)
    m = json.loads(open(mpp, encoding="utf-8").read())
    fn(m)
    open(mpp, "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2,
                                                      sort_keys=True) + "\n")
    before = open(mpp, "rb").read()
    try:
        S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
        refused = False
    except S.StateError:
        refused = True
    except Exception as e:  # noqa: BLE001
        bad("%s: 抛的是 %s 而不是 StateError" % (label, type(e).__name__))
        return
    if expect_refuse and not refused:
        bad("%s: 迁移没有拒绝" % label)
        return
    if expect_refuse and open(mpp, "rb").read() != before:
        bad("%s: 拒绝了却改了记录文件" % label)
        return
    ok("%s → 迁移前拒绝, 且一个字节都没改" % label)


def _bump_digest(m):
    m["current"]["digest"] = "sha256:" + "0" * 64


mutate(_bump_digest, "摘要与 inputs 对不上")
mutate(lambda m: m["current"]["inputs"].update(
    {"probe_url": "http://evil.example.com:81/probe"}), "探测地址被改成别人的服务器")
mutate(lambda m: m["current"]["inputs"]["ondemand_core"].insert(
    0, {"Action": "Connect"}), "按需规则被塞了一条无条件 Connect")
mutate(lambda m: m.update({"instance_id": "NOT-A-UUID"}), "instance_id 不是规范 UUID4")
mutate(lambda m: m["current"]["inputs"].pop("wloc_ca_sha256"), "schema 1 的 inputs 少一个字段")
mutate(lambda m: m["current"]["inputs"].update({"extra": 1}), "schema 1 的 inputs 多一个字段")
mutate(lambda m: m["current"]["inputs"].update({"wloc_enabled": True}),
       "自相矛盾: 说开着 WLOC 却没有证书指纹")
mutate(lambda m: m.update({"previous": m["current"]}), "previous 的版本号不小于 current")

# 校验不能被"两边一起改再配平"绕过: 这正是不该把新旧字段并成一个松并集的理由。
ww = tmpguard.mkdtemp(prefix="pdg-schema-union.")
mpp, arr, _m = legacy_meta(ww, wloc=False)
m = json.loads(open(mpp, encoding="utf-8").read())
m["current"]["inputs"]["schema"] = 2          # 声称自己是 schema 2
m["current"]["digest"] = S.digest_of(m["current"]["inputs"])   # 摘要配平
open(mpp, "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2) + "\n")
try:
    S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
    bad("顶层 schema=1 而 inputs.schema=2 的混合记录被放行了 —— 新旧契约被并成了松并集")
except S.StateError:
    ok("顶层与 inputs 的 schema 必须一致, 混合记录被拒(两套契约没有并成松并集)")

m2 = json.loads(open(mpp, encoding="utf-8").read())
m2["schema"] = 2                               # 顶层也改成 2, 但 inputs 还带着 wloc 字段
m2["current"]["inputs"]["schema"] = 2
open(mpp, "w", encoding="utf-8").write(json.dumps(m2, ensure_ascii=False, indent=2) + "\n")
try:
    S.load(mpp)
    bad("自称 schema 2 却带着 wloc 字段的记录被 load 放行了")
except S.StateError:
    ok("自称 schema 2 却带着 WLOC 字段 → 拒绝(schema 2 的字段集是**闭**的)")

# 完全不认识的版本号
ww = tmpguard.mkdtemp(prefix="pdg-schema-future.")
mpp, arr, _m = legacy_meta(ww, wloc=False)
m3 = json.loads(open(mpp, encoding="utf-8").read())
m3["schema"] = 99
open(mpp, "w", encoding="utf-8").write(json.dumps(m3, ensure_ascii=False, indent=2) + "\n")
for fn, lbl in ((lambda: S.load(mpp), "load"), (lambda: S.migrate_schema(meta_path=mpp, art_root=arr, lock=False), "migrate")):
    try:
        fn()
        bad("schema=99 被 %s 放行了" % lbl)
    except S.StateError:
        ok("schema=99(不认识的版本)被 %s 拒绝" % lbl)

# ══ 6. load 对未迁移的老机器: 读得懂, 但绝不交出退役 CA ═══════════════════════
print()
print("══ 6. 还没跑迁移的老机器 ══")
w = tmpguard.mkdtemp(prefix="pdg-schema-unmig.")
mp, art, old = legacy_meta(w, wloc=True)
try:
    m = S.load(mp)
    chk(m is not None and m["schema"] == 2,
        "load 读得懂 schema 1 并当场迁成 schema 2 的视图(实得 %r)" % (m or {}).get("schema"))
    chk(m.get("instance_id") == old["instance_id"], "身份在读的过程中没有丢")
    chk(m.get("current") is None, "读出来的视图里没有带 CA 的 current(不会被当成可发送的一版)")
except Exception as e:  # noqa: BLE001
    bad("load 读 schema 1 抛 %s: %s" % (type(e).__name__, str(e)[:70]))
chk(json.load(open(mp, encoding="utf-8"))["schema"] == 1,
    "load 是**只读**的: 盘上那份仍是 schema 1, 改写由明确的迁移入口负责")

# ══ 7. 退役不许静默改掉用户的非 WLOC 设置 ═══════════════════════════════════
print()
print("══ 7. 用户的 SSID / OnDemand 意图必须活过退役 ══")
# 带 CA 的 current 被退役之后, 记录里那一栏就空了。而"没传 SSID = 沿用记录里的"这条语义
# (effective_ssids)正是从 current.inputs.ssids 取的 —— current 一空, 下一次**普通生成**
# 会把用户配好的强制直连名单当成"用户要清空", 悄悄抹掉并推进一个版本。
#
# 用户既没做过这个决定, 界面上也不会报。退役撤的是 WLOC, 不是他的 Wi-Fi 名单。
SS = ["Home", "Office"]
w = tmpguard.mkdtemp(prefix="pdg-schema-keep.")
mp, art, old = legacy_meta(w, wloc=True, ssids=SS)
S.migrate_schema(meta_path=mp, art_root=art, lock=False)
m = S.load(mp)
chk(m.get("current") is None, "前置: 带 CA 的 current 确实被退役了")

# ① 沿用语义: 不指定 SSID 时, 算出来的输入里必须仍是用户那份名单
eff = S.effective_inputs(m, DOT, IP, None, TMPL)
chk(eff["ssids"] == SS, "不指定 SSID → 仍沿用用户配好的名单(实得 %r)" % (eff["ssids"],))

# ② 走**真的**后继生成: 产物里必须真的有那条 SSID 规则
meta2, lv2, why2, data2, ch2 = S.generate(DOT, IP, None, TMPL, meta_path=mp,
                                          art_root=art, lock=False)
chk(meta2["current"]["inputs"]["ssids"] == SS,
    "退役后第一次普通生成: SSID 名单原样保留(实得 %r)" % (meta2["current"]["inputs"]["ssids"],))
_pl = plistlib.loads(data2)
_rules = _pl["PayloadContent"][0].get("OnDemandRules") or []
chk(_rules and _rules[0].get("SSIDMatch") == SS,
    "产物里那条 SSID 强制直连规则仍在最前面(实得 %r)" % (_rules[0] if _rules else None))
# OnDemand 骨架本身也不能被退役改掉
chk([r for r in _rules if "SSIDMatch" not in r] == S.ondemand_core(TMPL) or True, "")
PASS[0] -= 1                                   # 上一行只是取值, 不计数
_core = [dict(r) for r in _rules if "SSIDMatch" not in r]
for r in _core:
    if "URLStringProbe" in r:
        r["URLStringProbe"] = "<probe>"
chk(_core == S.ondemand_core(TMPL), "OnDemand 骨架没有被退役改动")

# ③ 保留意图**不等于**保留一份能发的旧产物
chk(m.get("previous") is None, "没有把带 CA 的旧版留作 previous")
for f in (S.CUR, S.PREV):
    pass
chk(not any(b"com.apple.security.root" in open(os.path.join(art, f), "rb").read()
            for f in (S.CUR, S.PREV) if os.path.exists(os.path.join(art, f))),
    "盘上不存在任何仍含根证书的产物")

# ④ 不许伪造发送记录: 沿用下来的只能是**输入**, 不能带版本号/指纹/发送时间
raw = json.load(open(mp, encoding="utf-8")) if False else None
mig = json.load(open(mp, encoding="utf-8"))
kept = mig.get("retired_inputs")
if kept is None:
    bad("迁移没有把用户意图带过来 —— 下一次生成会把 SSID 抹掉")
else:
    ok("迁移把退役那一版的**输入**带了过来(retired_inputs)")
    stray = sorted(set(kept) & {"revision", "sha256", "sent_at", "generated_at", "digest"})
    chk(not stray, "带过来的只有输入, 没有版本号/指纹/发送时间(实得 %s)" % (stray or "无"))
    chk("wloc_enabled" not in kept and "wloc_ca_sha256" not in kept,
        "带过来的输入里没有 WLOC 字段")

# ⑤ 空名单的机器: 不许凭空长出 SSID
w2 = tmpguard.mkdtemp(prefix="pdg-schema-keep0.")
mp2, art2, _o2 = legacy_meta(w2, wloc=True, ssids=())
S.migrate_schema(meta_path=mp2, art_root=art2, lock=False)
eff2 = S.effective_inputs(S.load(mp2), DOT, IP, None, TMPL)
chk(eff2["ssids"] == [], "本来就没有 SSID 的机器: 迁移后仍然是空(不凭空长出来)")

# ⑥ 混合状态: current 带 CA(要退役)、previous 不带(本来可留)
#    —— "有 previous 没 current"这一组不成立, 所以 previous 也一起退役; 但用户意图取的是
#    **current 那一版**的(它才是最新的一次意图), 不能退回到 previous 那一版的旧名单。
w3 = tmpguard.mkdtemp(prefix="pdg-schema-mixed.")
mp3, art3, _o3 = legacy_meta(w3, wloc=False, ssids=["OldWiFi"])
m3 = json.load(open(mp3, encoding="utf-8"))
# 把 current 改成"带 CA"那一版, 名单换成新的 —— 手工拼(当前代码渲染不出带 CA 的产物)
cur_data = _render_legacy(["NewWiFi"], CA_DER, S.derive_ids(m3["instance_id"]))
ci = dict(m3["current"]["inputs"])
ci.update({"ssids": ["NewWiFi"], "wloc_enabled": True,
           "wloc_ca_sha256": hashlib.sha256(CA_DER).hexdigest()})
m3["current"] = dict(m3["current"], inputs=ci, digest=S.digest_of(ci),
                     sha256=hashlib.sha256(cur_data).hexdigest())
open(os.path.join(art3, S.CUR), "wb").write(cur_data)
open(mp3, "w", encoding="utf-8").write(json.dumps(m3, ensure_ascii=False, indent=2,
                                                  sort_keys=True) + "\n")
S.migrate_schema(meta_path=mp3, art_root=art3, lock=False)
m3n = S.load(mp3)
chk(m3n.get("current") is None and m3n.get("previous") is None,
    "混合状态: current 带 CA → 两栏一起退役(有 previous 没 current 这一组不成立)")
eff3 = S.effective_inputs(m3n, DOT, IP, None, TMPL)
chk(eff3["ssids"] == ["NewWiFi"],
    "混合状态: 沿用的是 current 那一版的最新意图, 不是 previous 的旧名单(实得 %r)"
    % (eff3["ssids"],))

# ⑦ 撤销修复对照: 把沿用链掐掉, ② 必须转红
_saved = S.effective_ssids
try:
    S.effective_ssids = lambda meta, ssids: list(ssids) if ssids is not None else \
        list(((meta or {}).get("current") or {}).get("inputs", {}).get("ssids") or ())
    w4 = tmpguard.mkdtemp(prefix="pdg-schema-undo.")
    mp4, art4, _o4 = legacy_meta(w4, wloc=True, ssids=SS)
    S.migrate_schema(meta_path=mp4, art_root=art4, lock=False)
    e4 = S.effective_inputs(S.load(mp4), DOT, IP, None, TMPL)
    chk(e4["ssids"] == [], "撤销修复对照: 掐掉沿用链后 SSID 确实被抹掉 —— ② 不是碰巧绿的")
finally:
    S.effective_ssids = _saved

# ══ 8. 改任何东西之前先验产物; 改的过程要么整笔成, 要么整笔回 ══════════════
print()
print("══ 8. 迁移前的产物校验与原子性 ══")


def _tree(d):
    """目录的完整身份: 相对路径 + 内容 sha + mode + uid + gid。回滚要能精确复原,
    光比内容不够 —— 权限被改掉同样是现场被动过。

    **读不出来的条目按"读不到"记, 不抛异常**: 有几格故意把文件设成 0o000 或换成目录来验
    "读不出来 ≠ 不存在"。快照在这里炸掉的话, 那几格就退化成 traceback —— 而崩溃不是具名
    失败, 撤掉被测的那道门反而会显示成"没有新增红行"。
    这一层要证的是"现场没被动过", 读不读得出内容不影响这个判断。
    """
    out = {}
    for base, dirs, files in os.walk(d):
        for f in sorted(files) + sorted(dirs):
            fp = os.path.join(base, f)
            try:
                st = os.lstat(fp)
            except OSError as e:
                out[os.path.relpath(fp, d)] = ("lstat:%s" % e.errno,)
                continue
            if stat.S_ISDIR(st.st_mode):
                digest = "<dir>"
            elif stat.S_ISLNK(st.st_mode):
                digest = "<link:%s>" % os.readlink(fp)
            else:
                try:
                    with open(fp, "rb") as fh:
                        digest = hashlib.sha256(fh.read()).hexdigest()
                except OSError as e:
                    digest = "<unreadable:%s>" % e.errno
            out[os.path.relpath(fp, d)] = (
                digest, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)
    return out


def _snap(mp, art):
    return (_tree(os.path.dirname(mp)), _tree(art))


def refuse_case(label, mutate, *, words=()):
    """迁移必须**具名拒绝**, 且记录与产物一个字节、一格权限都不许动。"""
    ww = tmpguard.mkdtemp(prefix="pdg-schema-atom.")
    mpp, arr, _m = legacy_meta(ww, wloc=True)
    mutate(mpp, arr)
    before = _snap(mpp, arr)
    try:
        S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
        bad("%s: 迁移没有拒绝 —— 损坏现场被洗成了当前格式" % label)
        return
    except S.StateError as e:
        msg = str(e)
    except Exception as e:  # noqa: BLE001
        bad("%s: 抛的是 %s 而不是 StateError" % (label, type(e).__name__))
        return
    hit = [w for w in words if w in msg]
    if words and not hit:
        bad("%s: 拒是拒了, 但不是这道门: %s" % (label, msg.replace("\n", " ")[:110]))
        return
    if _snap(mpp, arr) != before:
        bad("%s: 拒绝了却动过记录/产物(含权限)" % label)
        return
    ok("%s → 具名拒绝(%s), 记录与产物逐字节+权限未动" % (label, (hit or ["已拒"])[0]))


def _tamper_cur_bytes(mpp, arr):
    fp = os.path.join(arr, S.CUR)
    b = bytearray(open(fp, "rb").read())
    i = b.find(b"dot.example.com")
    b[i:i + 3] = b"XXX"
    open(fp, "wb").write(bytes(b))


def _swap_identity(mpp, arr):
    # 产物换成**另一台机器**生成的那一份(身份对不上), 并把记录里的 sha 配平
    other = _render_legacy((), CA_DER, S.derive_ids("11111111-2222-4333-8444-555555555555"))
    open(os.path.join(arr, S.CUR), "wb").write(other)
    m = json.load(open(mpp, encoding="utf-8"))
    m["current"]["sha256"] = hashlib.sha256(other).hexdigest()
    open(mpp, "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2,
                                                      sort_keys=True) + "\n")


def _swap_ca(mpp, arr):
    # 产物里的根证书换成另一张, 记录里的 sha 配平 —— 只剩指纹那道门能拦
    other = _ca_der()
    doc = plistlib.loads(open(os.path.join(arr, S.CUR), "rb").read())
    for x in doc["PayloadContent"]:
        if x.get("PayloadType") == "com.apple.security.root":
            x["PayloadContent"] = other
    blob = plistlib.dumps(doc)
    open(os.path.join(arr, S.CUR), "wb").write(blob)
    m = json.load(open(mpp, encoding="utf-8"))
    m["current"]["sha256"] = hashlib.sha256(blob).hexdigest()
    open(mpp, "w", encoding="utf-8").write(json.dumps(m, ensure_ascii=False, indent=2,
                                                      sort_keys=True) + "\n")


refuse_case("产物被改过(与记录的 sha256 对不上)", _tamper_cur_bytes, words=("内容指纹", "sha256"))
refuse_case("产物是另一台机器生成的(身份对不上)", _swap_identity, words=("身份", "instance"))
refuse_case("产物里的根证书换成了另一张", _swap_ca, words=("根证书", "指纹"))

# 合法缺失 ≠ 损坏: 记录说有 current 而盘上没有那份文件, 是既有契约里的 MISSING,
# 不该被当成"被人改过"而整笔拒 —— 那台机器只是丢了文件, 身份还在, 迁移照走。
w8 = tmpguard.mkdtemp(prefix="pdg-schema-missing.")
mp8, art8, _o8 = legacy_meta(w8, wloc=False)
os.remove(os.path.join(art8, S.CUR))
try:
    rep8 = S.migrate_schema(meta_path=mp8, art_root=art8, lock=False)
    ok("产物合法缺失 → 仍然迁移(不与「被改过」混为一谈): %s" % rep8.get("reason", "")[:40])
    chk(json.load(open(mp8, encoding="utf-8"))["schema"] == 2, "缺失产物的机器也迁到了 schema 2")
    chk("缺" in json.dumps(rep8, ensure_ascii=False) or rep8.get("missing"),
        "报告里说明了哪一栏的产物不在(实得 %s)" % json.dumps(rep8, ensure_ascii=False)[:90])
except S.StateError as e:
    bad("产物合法缺失被当成损坏整笔拒了: %s" % str(e)[:90])

# ── 原子性: 注入三种失败, 每一种都要逐字节 + 权限恢复 ──────────────────────
import pdgtx as _TX  # noqa: E402


def inject_case(label, arm, disarm):
    ww = tmpguard.mkdtemp(prefix="pdg-schema-inj.")
    mpp, arr, _m = legacy_meta(ww, wloc=True)
    before = _snap(mpp, arr)
    arm()
    try:
        S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
        bad("%s: 注入了失败却报成功" % label)
        return
    except Exception:  # noqa: BLE001
        pass
    finally:
        disarm()
    after = _snap(mpp, arr)
    if after == before:
        ok("%s → 整笔回到操作前(内容 + mode + uid/gid 逐项相等)" % label)
    else:
        diff = []
        for tag, b, a in (("记录目录", before[0], after[0]), ("产物目录", before[1], after[1])):
            for k in sorted(set(b) | set(a)):
                if b.get(k) != a.get(k):
                    diff.append("%s/%s: %r → %r" % (tag, k, b.get(k), a.get(k)))
        bad("%s: 没有完整回滚 —— %s" % (label, "; ".join(diff)[:200]))


_real_write = _TX.atomic_write
_state = {"n": 0}


def _boom_write():
    def w(path, data, *a, **kw):
        if path.endswith("ios-profile.json") and _state["n"] == 0:
            _state["n"] = 1
            raise OSError(28, "No space left on device")
        return _real_write(path, data, *a, **kw)
    _state["n"] = 0
    _TX.atomic_write = w


inject_case("写记录时磁盘满", _boom_write, lambda: setattr(_TX, "atomic_write", _real_write))

_real_load = S.load


def _boom_load():
    def l(path=None):
        if _state.get("armed"):
            _state["armed"] = False
            raise S.StateError("注入: 写后读回失败")
        return _real_load(path)
    _state["armed"] = True
    S.load = l


inject_case("写完之后读回失败", _boom_load, lambda: setattr(S, "load", _real_load))

_real_check = S._check_meta_object


def _boom_verify():
    """只打**写后**那一次复核。

    迁移里对 schema 2 的复核有两次: _migrate_1_to_2 结尾那次(在内存里、写盘之前)与写盘之后
    从盘上读回来那次。打第一次只能证明"写之前失败不会动盘", 那本来就成立; 要证的是
    **写完之后**才失败时能不能整笔回滚, 所以跳过第一次、打第二次。
    """
    def c(meta, schema=None):
        r = _real_check(meta, schema)
        if schema == S.SCHEMA:
            _state["v"] = _state.get("v", 0) + 1
            if _state["v"] == 2:
                raise S.RestoreRefused("注入", "末段复核失败")
        return r
    _state["v"] = 0
    S._check_meta_object = c


def _disarm_verify():
    S._check_meta_object = _real_check
    _state["v"] = False


inject_case("末段复核失败", _boom_verify, _disarm_verify)

# ── 合法样本必须**真的走通**, 不能"拒绝或成功均可" ────────────────────────
w9 = tmpguard.mkdtemp(prefix="pdg-schema-legit.")
mp9, art9, o9 = legacy_meta(w9, wloc=False, ssids=["Home"])
rep9 = S.migrate_schema(meta_path=mp9, art_root=art9, lock=False)
chk(rep9.get("changed") is True, "合法旧记录: 迁移确实发生了(不是被拒)")
m9 = S.load(mp9)
chk(m9["schema"] == 2 and m9["current"] is not None
    and m9["current"]["sha256"] == o9["current"]["sha256"],
    "合法旧记录: 产物一个字节没动, 记录已是 schema 2")
S.verified_artifact(m9, "current", art9)
ok("合法旧记录: 迁移后 verified_artifact 仍然交得出字节(契约自洽)")

# ── 撤销修复对照: 拿掉产物校验, 损坏样本就会被洗掉 ────────────────────────
ww = tmpguard.mkdtemp(prefix="pdg-schema-undo8.")
mpp, arr, _m = legacy_meta(ww, wloc=True)
_tamper_cur_bytes(mpp, arr)
_real_ca = S._check_artifact
try:
    S._check_artifact = lambda *a, **k: None          # 撤销这一轮加的那道门
    try:
        S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
        ok("撤销修复对照: 拿掉产物校验后, 被改过的产物确实被洗成了当前格式")
    except S.StateError:
        bad("撤销修复对照: 拿掉产物校验后仍被拒 —— 说明拦它的不是这道门")
finally:
    S._check_artifact = _real_ca

# ══ 9. 只有**真的不在**才算 MISSING ═════════════════════════════════════════
print()
print("══ 9. 读不出来 ≠ 不存在 ══")
# 迁移把"读不到产物"当成 MISSING 放行。但 read_artifact 把**所有** OSError 都压成 None ——
# 于是权限不足(EACCES)、IO 错误、路径上放了个目录、软链指向不存在的地方, 统统被当成
# "那台机器只是丢了文件"。
#
# 后果很具体: 一台产物**还在**、只是暂时读不出来的机器, 会被当成缺产物照常迁移 —— 记录改写、
# 带 CA 的产物删掉。等权限修好, 那份东西已经没有任何记录能解释它了。
# "看不见"不等于"没有", 这条与 mitm_ca._probe 是同一个判据(那边也踩过)。


def readerr_case(label, setup, cleanup=None):
    ww = tmpguard.mkdtemp(prefix="pdg-schema-rderr.")
    mpp, arr, _m = legacy_meta(ww, wloc=False)
    try:
        setup(mpp, arr)
        before = _snap(mpp, arr)
        try:
            S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
            bad("%s: 被当成 MISSING 放行了 —— 产物其实还在" % label)
            return
        except S.StateError as e:
            msg = str(e)
        except Exception as e:  # noqa: BLE001
            bad("%s: 抛的是 %s 而不是 StateError" % (label, type(e).__name__))
            return
        if _snap(mpp, arr) != before:
            bad("%s: 拒绝了却动过记录/产物" % label)
            return
        # **必须是可读性那道门**拦下的, 不能只断言"被拒了"。
        # 把这道门拿掉之后, data 会以 None 继续往下走, 被"三件配套: 是空文件"那一条拒掉 ——
        # 于是"只要红就算过"的写法在撤销修复之后照样绿, 这一格等于没有。
        if "读不出来" not in msg and "产物可读性" not in msg:
            bad("%s: 拒是拒了, 但不是可读性那道门: %s" % (label, msg.replace("\n", " ")[:110]))
            return
        ok("%s → 由可读性那道门拒绝, 记录与产物零改动" % label)
    finally:
        if cleanup:
            cleanup(mpp, arr)


def _unreadable(mpp, arr):
    os.chmod(os.path.join(arr, S.CUR), 0o000)


def _unchmod(mpp, arr):
    try:
        os.chmod(os.path.join(arr, S.CUR), 0o644)
    except OSError:
        pass


def _dir_masquerade(mpp, arr):
    fp = os.path.join(arr, S.CUR)
    os.remove(fp)
    os.makedirs(fp)


def _dangling_symlink(mpp, arr):
    fp = os.path.join(arr, S.CUR)
    os.remove(fp)
    os.symlink(os.path.join(arr, "nope-not-here"), fp)


if os.geteuid() == 0:
    print("[SKIP] 权限不足(EACCES)这一格: 本次以 root 身份运行, 0o000 拦不住 root。"
          " 其余几格照跑。")
else:
    readerr_case("产物存在但读不出来(EACCES)", _unreadable, _unchmod)
readerr_case("产物的位置上放着一个目录", _dir_masquerade)
readerr_case("产物是一条指向不存在目标的软链", _dangling_symlink)

# 反面: **真的**不在才算 MISSING(§8 已验一次, 这里再确认它没被上面几格带偏)
w9b = tmpguard.mkdtemp(prefix="pdg-schema-realmiss.")
mp9b, art9b, _o = legacy_meta(w9b, wloc=False)
os.remove(os.path.join(art9b, S.CUR))
try:
    r = S.migrate_schema(meta_path=mp9b, art_root=art9b, lock=False)
    chk(r.get("missing_artifacts") == ["current"],
        "真的不在 → 仍按 MISSING 放行并点名(实得 %r)" % (r.get("missing_artifacts"),))
except S.StateError as e:
    bad("真的不在却被拒了: %s" % str(e)[:80])

# 撤销修复对照: 把**三态**探测换回两态("读不到就是 None"), 目录冒充那一格必须转红。
# 瞄的必须是 read_artifact_strict —— 迁移读的是它; 换掉 read_artifact 只会换掉一个
# 迁移根本不走的函数, 那样的"对照"什么都不证明(第一版正是这么写的, 于是它自己先红了)。
_real_read = S.read_artifact_strict
try:
    def _naive(which, root=None):
        try:
            with open(S.art_path(which, root), "rb") as f:
                return f.read(), "ok"
        except OSError:
            return None, "missing"
    S.read_artifact_strict = _naive
    ww = tmpguard.mkdtemp(prefix="pdg-schema-undo9.")
    mpp, arr, _m = legacy_meta(ww, wloc=False)
    _dir_masquerade(mpp, arr)
    try:
        S.migrate_schema(meta_path=mpp, art_root=arr, lock=False)
        ok("撤销修复对照: 退回「读不到就是 None」后, 目录冒充确实被当成 MISSING 放行")
    except S.StateError:
        bad("撤销修复对照: 退回之后仍被拒 —— 拦它的不是这道门")
finally:
    S.read_artifact_strict = _real_read

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

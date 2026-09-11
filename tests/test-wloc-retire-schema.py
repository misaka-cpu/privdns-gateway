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
DOT, IP = "dot.example.com", "203.0.113.10"


def _ca_der():
    """一张真的自签 CA(DER)。不能用随便一串字节 —— 产物校验会拿它过 X.509 解析。"""
    d = tmpguard.mkdtemp(prefix="pdg-schema-ca.")
    import subprocess
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec",
                    "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", os.path.join(d, "k.pem"), "-out", os.path.join(d, "c.pem"),
                    "-days", "30", "-subj", "/CN=PDG Retire Test CA"],
                   check=True, capture_output=True)
    return iosprofile.ca_der_from_pem(open(os.path.join(d, "c.pem"), encoding="utf-8").read())


CA_DER = _ca_der()


def _render_legacy(ssids, der, ids):
    """手工摆出一份**退役前**的 .mobileconfig 字节。

    不能用 iosprofile.render 造带根证书的那一版 —— 它已经不接受 ca_der 了, 而那正是退役
    做对了的证明。所以这里照着 schema 1 的产物形态自己拼: 先渲染出不含 CA 的那一份, 再把
    根证书那一格按老格式追加回去。这也更贴近事实 —— 老机器盘上躺着的就是这样一份东西,
    它不是当前代码的产物。
    """
    raw = iosprofile.render(DOT, IP, ssids, ids, TMPL)
    if not der:
        return raw
    pl = plistlib.loads(raw)
    pl["PayloadContent"].append({
        "PayloadType": "com.apple.security.root",
        "PayloadVersion": 1,
        "PayloadIdentifier": iosprofile.ID_CA,
        "PayloadUUID": ids["ca"],
        "PayloadDisplayName": iosprofile.CA_DISPLAY,
        "PayloadContent": der,
        "PayloadCertificateFileName": iosprofile.CA_FILENAME,
    })
    return plistlib.dumps(pl)


def legacy_meta(work, *, wloc, ssids=(), revisions=2):
    """造一台**退役前**的机器: schema 1 的记录 + 对应产物。

    刻意不用当前代码去生成 —— 当前代码已经产不出 schema 1 了。这里照着 schema 1 的契约
    手工摆出来, 那才是老机器上真实躺着的东西。
    """
    meta_p = os.path.join(work, "ios-profile.json")
    art = os.path.join(work, "art")
    os.makedirs(art, exist_ok=True)
    iid = "8f14e45f-ceea-4d4c-a3e6-5b0a1c2d3e4f"
    ids = S.derive_ids(iid)
    der = CA_DER if wloc else b""
    recs = []
    for rev in range(1, revisions + 1):
        data = _render_legacy(ssids, der, ids)
        inp = {
            "schema": 1,
            "dot_host": iosprofile.norm_host(DOT),
            "server_addresses": iosprofile.norm_addrs(IP),
            "dns_protocol": "TLS",
            "probe_url": S.probe_url_for(IP),
            "ondemand_core": S.ondemand_core(TMPL),
            "ssids": iosprofile.norm_ssids(ssids),
            "wloc_enabled": bool(wloc),
            "wloc_ca_sha256": hashlib.sha256(der).hexdigest() if der else "",
        }
        recs.append({"revision": rev, "digest": S.digest_of(inp), "inputs": inp,
                     "sha256": hashlib.sha256(data).hexdigest(),
                     "generated_at": "2026-01-0%dT00:00:00Z" % rev, "sent_at": None})
        if rev == revisions:
            open(os.path.join(art, S.CUR), "wb").write(data)
        elif rev == revisions - 1:
            open(os.path.join(art, S.PREV), "wb").write(data)
    meta = {"schema": 1, "instance_id": iid, "created_at": "2026-01-01T00:00:00Z",
            "migration_pending": False,
            "current": recs[-1],
            "previous": recs[-2] if revisions >= 2 else None}
    open(meta_p, "w", encoding="utf-8").write(json.dumps(meta, ensure_ascii=False, indent=2,
                                                         sort_keys=True) + "\n")
    return meta_p, art, meta


def has_ca(path):
    try:
        p = plistlib.loads(open(path, "rb").read())
    except Exception:  # noqa: BLE001
        return None
    return any((x or {}).get("PayloadType") == "com.apple.security.root"
               for x in (p.get("PayloadContent") or []) if isinstance(x, dict))


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

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

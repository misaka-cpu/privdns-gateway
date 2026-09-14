#!/usr/bin/env python3
"""造一台**退役前**的机器: schema 1 的记录 + 与它对应的 .mobileconfig 产物。

这一份是从 tests/test-wloc-retire-schema.py 里**原样提取**出来的(那边原来自己带着这几个
构造函数)。提出来只有一个目的: 让 shell 那边的组合用例
(tests/test-platform-schema-restore.sh)用**同一套**构造方式造现场, 而不是各造各的 ——
两边对"什么叫一份合法的旧记录"如果有分歧, 组合用例就等于在测一个不存在的形态。

刻意不用当前代码去生成: 当前代码已经产不出 schema 1 了。这里照着 schema 1 的契约手工摆,
那才是老机器上真实躺着的东西。

模块路径与模板路径都做成**入参** —— shell 那边要在自有隔离根里(/opt/pdg-bot)跑, 用的是
那个根里的 iosprofile/iosstate, 不是仓库工作区里的那一份。

命令行(给 shell 用):
    python3 wloc_legacy_fixture.py --modules <dir> --tmpl <path> --out <dir>
                                   [--wloc] [--ssid NAME]... [--revisions N]
  在 <dir> 下写出 ios-profile.json 与 art/(CUR/PREV 两份产物), 并把一份摘要打到 stdout。
"""
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile

DOT, IP = "dot.example.com", "203.0.113.10"


def _mods(modules):
    """把 iosprofile / iosstate 从指定目录导进来。"""
    if modules not in sys.path:
        sys.path.insert(0, modules)
    import iosprofile
    import iosstate
    return iosprofile, iosstate


def ca_der(modules, workdir=None):
    """一张真的自签 CA(DER)。不能用随便一串字节 —— 产物校验会拿它过 X.509 解析。"""
    iosprofile, _ = _mods(modules)
    d = workdir or tempfile.mkdtemp(prefix="pdg-legacy-ca.")
    os.makedirs(d, exist_ok=True)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec",
                    "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", os.path.join(d, "k.pem"), "-out", os.path.join(d, "c.pem"),
                    "-days", "30", "-subj", "/CN=PDG Retire Test CA"],
                   check=True, capture_output=True)
    return iosprofile.ca_der_from_pem(open(os.path.join(d, "c.pem"), encoding="utf-8").read())


def render_legacy(modules, tmpl, ssids, der, ids):
    """手工摆出一份**退役前**的 .mobileconfig 字节。

    不能用 iosprofile.render 造带根证书的那一版 —— 它已经不接受 ca_der 了, 而那正是退役
    做对了的证明。所以这里照着 schema 1 的产物形态自己拼: 先渲染出不含 CA 的那一份, 再把
    根证书那一格按老格式追加回去。
    """
    iosprofile, _ = _mods(modules)
    raw = iosprofile.render(DOT, IP, ssids, ids, tmpl)
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


def legacy_meta(work, *, wloc, ssids=(), revisions=2, modules=None, tmpl=None,
                der=None, meta_name="ios-profile.json", art_name="art"):
    """schema 1 的记录 + 对应产物。返回 (记录路径, 产物目录, 记录对象)。"""
    iosprofile, S = _mods(modules)
    meta_p = os.path.join(work, meta_name)
    art = os.path.join(work, art_name)
    os.makedirs(art, exist_ok=True)
    iid = "8f14e45f-ceea-4d4c-a3e6-5b0a1c2d3e4f"
    ids = S.derive_ids(iid)
    if der is None:
        der = ca_der(modules) if wloc else b""
    elif not wloc:
        der = b""
    recs = []
    for rev in range(1, revisions + 1):
        data = render_legacy(modules, tmpl, ssids, der, ids)
        inp = {
            "schema": 1,
            "dot_host": iosprofile.norm_host(DOT),
            "server_addresses": iosprofile.norm_addrs(IP),
            "dns_protocol": "TLS",
            "probe_url": S.probe_url_for(IP),
            "ondemand_core": S.ondemand_core(tmpl),
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modules", required=True)
    ap.add_argument("--tmpl", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--wloc", action="store_true")
    ap.add_argument("--ssid", action="append", default=[])
    ap.add_argument("--revisions", type=int, default=2)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    meta_p, art, meta = legacy_meta(a.out, wloc=a.wloc, ssids=tuple(a.ssid),
                                    revisions=a.revisions, modules=a.modules, tmpl=a.tmpl)
    _, S = _mods(a.modules)
    print(json.dumps({
        "meta": meta_p, "art": art,
        "instance_id": meta["instance_id"],
        "schema": meta["schema"],
        "revision": meta["current"]["revision"],
        "ssids": meta["current"]["inputs"]["ssids"],
        "wloc_enabled": meta["current"]["inputs"]["wloc_enabled"],
        "wloc_ca_sha256": meta["current"]["inputs"]["wloc_ca_sha256"],
        "cur_has_ca": has_ca(os.path.join(art, S.CUR)),
        "prev_has_ca": has_ca(os.path.join(art, S.PREV)) if a.revisions >= 2 else None,
        "cur_name": S.CUR, "prev_name": S.PREV,
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()

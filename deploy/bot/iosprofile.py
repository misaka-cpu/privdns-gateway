#!/usr/bin/env python3
"""iOS/iPadOS 描述文件的**唯一生成实现**(5.4)。

在此之前有两份: Bot 的 `_ios_profile()` 用 plistlib 组装, 支持 SSID 排除与 WLOC 根证书;
CLI 的 `cmd_ios` 用 `sed` 换四个占位符, 两样都不支持。同一台网关, 走 Telegram 拿到的文件
和走命令行拿到的文件**内容不一样** —— 这种分歧不会报错, 只会在某天变成"我按文档做的, 但
它没生效"。所以这里收成一份, Bot 与 CLI 都调它, 相同输入必须产出**逐字节相同**的文件。

几条硬约束, 改这个文件之前先读:

  · 结构以 `pdg-dot-ondemand.mobileconfig.tmpl` 为准 —— 模板才是 OnDemand 规则顺序、
    DNSSettings 平级关系这些 Apple 语义的出处, 不在 Python 里再抄一份;
  · `PayloadVersion` 恒为 Apple 规定的 `1`。业务修订号是另一个东西(见 iosstate.revision),
    不许拿 PayloadVersion 冒充 —— iOS 不按它判新旧;
  · 描述文件里**只允许公开 CA 证书**。任何私钥迹象一律拒绝生成, 不做"过滤掉再继续";
  · 输入全部显式传参, 不 import Bot 本体、不读 Telegram 会话状态 —— 反向依赖会让 CLI
    在没有 bot 环境的机器上跑不起来;
  · 只用标准库。

用法(供 pdg.sh 调用):
  iosprofile.py render --dot-host H --server-ip A [--ssid S]... [--ca-pem F]
                       [--uuid-root U --uuid-dns U --uuid-ca U] [--template T] > out.mobileconfig
"""
import argparse
import base64
import binascii
import json
import os
import plistlib
import re
import sys
import uuid

TEMPLATE = "/opt/pdg-bot/pdg-dot.mobileconfig.tmpl"
MITM_CONFIG = "/etc/privdns-gateway/mitm.json"
CA_CRT = "/etc/privdns-gateway/ca/ca.crt"

# 顶层与 DNS payload 的 identifier 前缀。UUID 拼在后面: 同一网关稳定 ⇒ iOS 视为"同一份文件
# 的新版本"; 不同网关不同 ⇒ 两台网关的描述文件不会互相顶掉(有人同时用两台)。
ID_ROOT = "com.privdns.gateway"
ID_DNS = "com.privdns.gateway.dot"
ID_CA = "com.privdns.mitm.ca"
CA_DISPLAY = "PrivDNS Gateway MITM CA"
CA_FILENAME = "pdg-mitm-ca.crt"

_UUID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")
# 私钥的各种写法。DER 里不会有这些字面量, 出现即说明有人把 key 文件当成 cert 传进来了。
_KEY_MARKERS = (b"PRIVATE KEY", b"BEGIN RSA PRIVATE", b"BEGIN EC PRIVATE",
                b"BEGIN OPENSSH PRIVATE", b"BEGIN PGP PRIVATE")


class ProfileError(Exception):
    """生成被拒。消息是给用户看的中文, 说清楚"为什么不给"和"怎么办"。"""


# ── 输入规范化 ──────────────────────────────────────────────────────────────
def norm_ssids(ssids):
    """去空白、去空项、去重、**排序**。排序是为了确定性: 用户两次填同样的 SSID 但顺序不同,
    不应该被判成"配置变了"。返回 list。"""
    out = []
    for s in ssids or ():
        s = str(s).strip()
        if s and s not in out:
            out.append(s)
    return sorted(out)


def norm_host(h):
    h = str(h or "").strip()
    if not h:
        raise ProfileError("缺少 DoT 主机名 —— 描述文件没有它就连不上, 拒绝生成。")
    if any(c.isspace() for c in h):
        raise ProfileError("DoT 主机名含空白字符: %r" % h)
    return h


def norm_addrs(addrs):
    """服务器地址列表。允许多个(Apple 支持), 但至少要有一个。"""
    if isinstance(addrs, (str, bytes)):
        addrs = [addrs]
    out = []
    for a in addrs or ():
        a = str(a).strip()
        if a and a not in out:
            out.append(a)
    if not out:
        raise ProfileError("缺少网关地址 —— 描述文件没有它就连不上, 拒绝生成。")
    for a in out:
        if any(c.isspace() for c in a):
            raise ProfileError("网关地址含空白字符: %r" % a)
    return out


def reject_key_material(raw, what="CA 证书"):
    """见到任何私钥标记就拒。调用点不止一处是**故意**的: PEM 解析是一道门, 最终字节是另一道,
    直接传进来的 DER 又是一道。私钥外泄没有"下一次再修"的机会, 所以宁可查三遍。"""
    b = bytes(raw or b"")
    for mark in _KEY_MARKERS:
        if mark in b:
            raise ProfileError("%s 里含私钥, 拒绝生成描述文件。描述文件只能包含公开证书, "
                               "请检查证书路径是否误指向了 key 文件。" % what)


def ca_der_from_pem(pem):
    """PEM → DER, 但**先当成不可信输入检查一遍**。

    这里是"CA 私钥绝不进描述文件"这条红线的执行点。做法是白名单: 只接受恰好由 CERTIFICATE
    块组成的 PEM, 见到任何私钥标记直接拒绝 —— 不是"把私钥那段删掉再继续", 因为那意味着我们
    在替用户猜"他其实想给的是证书", 而猜错的代价是私钥出门。
    """
    if not pem:
        return b""
    raw = pem.encode() if isinstance(pem, str) else bytes(pem)
    reject_key_material(raw, "CA 文件")
    text = raw.decode("utf-8", "replace")
    blocks = re.findall(r"-----BEGIN ([A-Z0-9 ]+)-----(.*?)-----END \1-----", text, re.S)
    if not blocks:
        raise ProfileError("CA 证书不是可识别的 PEM, 拒绝生成描述文件(可能已损坏)。")
    kinds = {k.strip() for k, _ in blocks}
    if kinds - {"CERTIFICATE", "TRUSTED CERTIFICATE"}:
        raise ProfileError("CA 文件里有非证书内容(%s), 拒绝生成描述文件。"
                           % ", ".join(sorted(kinds - {"CERTIFICATE", "TRUSTED CERTIFICATE"})))
    body = "".join(l for l in blocks[0][1].splitlines() if l.strip())
    try:
        der = base64.b64decode(body, validate=True)
    except (binascii.Error, ValueError):
        raise ProfileError("CA 证书 base64 解不开, 拒绝生成描述文件(可能已损坏)。")
    if not der or der[0] != 0x30:
        raise ProfileError("CA 证书不是合法 DER 结构, 拒绝生成描述文件(可能已损坏)。")
    return der


def wloc_enabled(config_path=None):
    """MITM 插件配置里有没有启用项。读不到文件按"没启用"处理(那台机器根本没开过 WLOC);
    但文件在却解不开 —— 那是**坏了**, 不能当成没启用, 否则会悄悄发出一份不含 CA 的描述文件。"""
    path = config_path or MITM_CONFIG
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return False
    except OSError as e:
        raise ProfileError("读不到 MITM 配置 %s: %s —— 无法判断是否需要下发根证书, 拒绝生成。"
                           % (path, e.strerror))
    try:
        cfg = json.loads(raw) if raw.strip() else {}
    except ValueError:
        raise ProfileError("MITM 配置 %s 解析失败, 无法判断是否需要下发根证书, 拒绝生成。" % path)
    if not isinstance(cfg, dict):
        return False
    return any(isinstance(v, dict) and v.get("enabled") for v in cfg.values())


def ca_der_for(enabled, ca_crt=None):
    """按"是否启用 WLOC"决定要不要根证书, 并在需要时把它读出来。

    未启用 ⇒ 不带 CA(多带一张根证书是扩大信任面, 不是"顺手")。
    启用但 CA 缺失/损坏 ⇒ **拒绝生成**, 而不是发一份没有 CA 的。后者装到手机上的表现是
    被接管的站点全部证书报错, 用户完全无从知道是这里出的问题。
    """
    if not enabled:
        return b""
    path = ca_crt or CA_CRT
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            pem = f.read()
    except OSError as e:
        raise ProfileError("WLOC 已启用, 但读不到根 CA 证书 %s(%s) —— 拒绝生成描述文件: "
                           "不含 CA 的描述文件装上去会让被接管的站点全部证书报错。"
                           % (path, e.strerror))
    der = ca_der_from_pem(pem)
    if not der:
        raise ProfileError("WLOC 已启用, 但根 CA 证书 %s 为空, 拒绝生成描述文件。" % path)
    return der


def _check_uuid(u, what):
    u = str(u or "").strip().upper()
    if not _UUID_RE.match(u):
        raise ProfileError("%s 不是合法 UUID: %r" % (what, u))
    return u


def random_ids():
    """随机身份。v1.7.8 及以前每次生成都用它 —— 受管生命周期改为从 instance_id 派生
    (见 iosstate.derive_ids), 这里保留是为了让"未启用受管生命周期"的路径行为不变。"""
    return {r: str(uuid.uuid4()).upper() for r in ("root", "dns", "ca")}


# ── 渲染 ────────────────────────────────────────────────────────────────────
def _read_template(path):
    path = path or TEMPLATE
    if not os.path.exists(path):
        raise ProfileError("缺少描述文件模板 %s —— 请先跑 `pdg update` 补齐 iOS 组件。" % path)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise ProfileError("读不到描述文件模板 %s: %s" % (path, e.strerror))


def render(dot_host, server_addresses, ssids=(), ca_der=b"", ids=None, template=None):
    """生成 .mobileconfig 字节。

    输出**始终**走 plistlib.dumps 这一条路。以前"没有 SSID 也没有 CA"时直接返回替换过占位符
    的模板原文, 于是同一台网关会吐出两种不同格式(还夹着模板里那段解释部署细节的 XML 注释)。
    受管生命周期要拿"字节是否相同"当证据, 就不能容忍"取决于走哪条分支"的格式。
    """
    if ca_der:
        reject_key_material(ca_der, "传入的根证书")
    ids = dict(ids or random_ids())
    u_root = _check_uuid(ids.get("root"), "顶层 PayloadUUID")
    u_dns = _check_uuid(ids.get("dns"), "DNS payload UUID")
    host = norm_host(dot_host)
    addrs = norm_addrs(server_addresses)
    ssids = norm_ssids(ssids)

    raw = (_read_template(template)
           .replace("__DOT_HOST__", host)
           .replace("__JP_IP__", addrs[0])
           .replace("__UUID1__", u_dns)
           .replace("__UUID2__", u_root)).encode()
    try:
        p = plistlib.loads(raw)
    except Exception as e:  # noqa: BLE001
        raise ProfileError("描述文件模板不是合法 plist(%s), 拒绝生成。" % type(e).__name__)

    dns = (p.get("PayloadContent") or [None])[0]
    if not isinstance(dns, dict) or dns.get("PayloadType") != "com.apple.dnsSettings.managed":
        raise ProfileError("描述文件模板的 DNS payload 结构不对, 拒绝生成。")
    if len(addrs) > 1:
        dns["DNSSettings"]["ServerAddresses"] = list(addrs)
    if ssids:
        # 插在最前面: OnDemand 是"第一条命中的说了算", 排在探测规则之后就永远轮不到。
        dns["OnDemandRules"].insert(
            0, {"InterfaceTypeMatch": "WiFi", "SSIDMatch": list(ssids), "Action": "Disconnect"})
    if ca_der:
        p["PayloadContent"].append({
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": ID_CA,
            "PayloadUUID": _check_uuid(ids.get("ca"), "CA payload UUID"),
            "PayloadDisplayName": CA_DISPLAY,
            "PayloadContent": ca_der,
            "PayloadCertificateFileName": CA_FILENAME,
        })
    out = plistlib.dumps(p)
    validate(out, expect_ca=bool(ca_der))
    return out


def validate(data, expect_ca=None):
    """对**最终字节**做校验, 而不是对中间的 dict。

    校验中间结构证明不了落盘的那份是对的 —— 序列化本身也可能把东西弄丢(比如 bytes 被当成
    字符串)。所以这里重新解析一遍输出, 顺便再扫一次私钥标记: render 之外还有别的写入路径
    (迁移、恢复), 让它们共用同一道门。
    """
    if not isinstance(data, (bytes, bytearray)):
        raise ProfileError("描述文件必须是字节")
    for mark in _KEY_MARKERS:
        if mark in bytes(data):
            raise ProfileError("描述文件里出现私钥标记, 已拒绝输出。")
    try:
        p = plistlib.loads(bytes(data))
    except Exception as e:  # noqa: BLE001
        raise ProfileError("生成的描述文件不是合法 plist(%s)。" % type(e).__name__)
    if p.get("PayloadType") != "Configuration":
        raise ProfileError("顶层 PayloadType 不是 Configuration")
    if p.get("PayloadVersion") != 1:
        raise ProfileError("顶层 PayloadVersion 必须是 Apple 规定的 1, 实际 %r"
                           % p.get("PayloadVersion"))
    _check_uuid(p.get("PayloadUUID"), "顶层 PayloadUUID")
    if not str(p.get("PayloadIdentifier") or "").startswith(ID_ROOT + "."):
        raise ProfileError("顶层 PayloadIdentifier 前缀不对: %r" % p.get("PayloadIdentifier"))
    items = p.get("PayloadContent") or []
    dns = [x for x in items if isinstance(x, dict)
           and x.get("PayloadType") == "com.apple.dnsSettings.managed"]
    if len(dns) != 1:
        raise ProfileError("DNS payload 应当恰好一个, 实际 %d 个" % len(dns))
    d = dns[0]
    if d.get("PayloadVersion") != 1:
        raise ProfileError("DNS payload 的 PayloadVersion 必须是 1")
    _check_uuid(d.get("PayloadUUID"), "DNS payload UUID")
    s = d.get("DNSSettings") or {}
    if s.get("DNSProtocol") != "TLS":
        raise ProfileError("DNSProtocol 不是 TLS")
    if not str(s.get("ServerName") or "").strip():
        raise ProfileError("缺少 ServerName")
    if not (s.get("ServerAddresses") or []):
        raise ProfileError("缺少 ServerAddresses")
    if "OnDemandRules" in s:
        raise ProfileError("OnDemandRules 嵌进了 DNSSettings —— 必须与它平级, iOS 才认")
    rules = d.get("OnDemandRules") or []
    if not rules:
        raise ProfileError("缺少 OnDemandRules")
    if not any(r.get("URLStringProbe") for r in rules if isinstance(r, dict)):
        raise ProfileError("OnDemandRules 里没有探测规则 —— 会变成无条件启用 DoT")
    if rules[-1] != {"Action": "Disconnect"}:
        raise ProfileError("OnDemandRules 最后一条必须是兜底 Disconnect")
    cas = [x for x in items if isinstance(x, dict)
           and x.get("PayloadType") == "com.apple.security.root"]
    if len(cas) > 1:
        raise ProfileError("根证书 payload 出现 %d 个" % len(cas))
    if expect_ca is not None and bool(cas) != bool(expect_ca):
        raise ProfileError("根证书 payload 与预期不符(预期 %s)" % ("有" if expect_ca else "无"))
    for c in cas:
        _check_uuid(c.get("PayloadUUID"), "CA payload UUID")
        body = c.get("PayloadContent")
        if not isinstance(body, bytes) or not body or body[0] != 0x30:
            raise ProfileError("根证书 payload 内容不是 DER 证书")
    return p


# ── 命令行(供 pdg.sh 调用)───────────────────────────────────────────────
def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(prog="iosprofile.py", add_help=True)
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("render", help="生成 .mobileconfig 到 stdout")
    r.add_argument("--dot-host", required=True)
    r.add_argument("--server-ip", required=True, action="append",
                   help="网关地址, 可重复")
    r.add_argument("--ssid", action="append", default=[], help="强制直连的 Wi-Fi 名, 可重复")
    r.add_argument("--ca-pem", help="直接指定根 CA 证书 PEM(无条件附带)")
    r.add_argument("--wloc-config", help="MITM 配置路径; 据它判断要不要附根证书")
    r.add_argument("--ca-crt", help="配合 --wloc-config: 根 CA 证书路径")
    r.add_argument("--uuid-root")
    r.add_argument("--uuid-dns")
    r.add_argument("--uuid-ca")
    r.add_argument("--template")
    a = ap.parse_args(argv)
    if a.cmd != "render":
        ap.print_help(sys.stderr)
        return 2
    try:
        if a.ca_pem:
            der = ca_der_for(True, a.ca_pem)
        elif a.wloc_config:
            der = ca_der_for(wloc_enabled(a.wloc_config), a.ca_crt)
        else:
            der = b""
        ids = None
        if a.uuid_root or a.uuid_dns or a.uuid_ca:
            ids = {"root": a.uuid_root, "dns": a.uuid_dns, "ca": a.uuid_ca or a.uuid_root}
        out = render(a.dot_host, a.server_ip, a.ssid, der, ids, a.template)
    except ProfileError as e:
        sys.stderr.write("%s\n" % e)
        return 3
    sys.stdout.buffer.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

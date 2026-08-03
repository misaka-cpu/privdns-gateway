#!/usr/bin/env python3
"""SIM/APN 链路诊断 —— 6.1A: **服务器准备状态**(只读)。

这个模块只回答一件事: **服务器是否具备接收和处理这条链路上流量的条件。**

它证明不了的(一条都不许在文案里暗示):
  · 手机是否用了目标 SIM / 目标 APN;
  · 手机的流量是否到达了本机;
  · 手机的 DoT 查询是否进了 mosdns;
  · 手机是否信任这张证书;
  · 出口或目标服务是否可用(那是 6.3)。

本机回环检查**不得**冒充手机端到端证据。本机 dig 走的是 127.0.0.1, 而 127.0.0.1 不在
内网卡段里 —— mosdns 的劫持与分流对它根本不生效(checks.check_deep_hijack_note 里写了同一
件事)。所以"本机 DNS 能解析"只说明 mosdns 活着, 与手机那条路无关。

私网侧的层级在 6.1A 一律是 NOT_OBSERVED: 我们还没有实时观测能力(那是 6.1B)。
NOT_OBSERVED 是**独立状态**, 既不能升成 PASS 也不能降成 FAIL —— 它的意思是"没看到",
而"没看到"在这里既不能证明正常, 也不能证明故障。

平台差异有一条硬事实: pdg-probe81 / 端口 81 / probe81.py 都是 **iOS 专属**
(见 lib/modules.sh 的 PDG_IOS_MODULES 与 nft 模板里的 81)。Android 上它根本不装、不监听、
也不放行 —— 那不是"缺失", 是 SKIP。

只读约束: 不取全局配置写锁、不开事务、不写任何配置/快照/状态/缓存/审计文件、不重启服务、
不跑迁移。配置坏了只报告, 不代为修复。
"""
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")
import checks  # noqa: E402  复用它的**底层原语**(_platform/_internal_cidr/...), 不解析它的终端文案

SCHEMA_VERSION = 1

# ── 状态闭集 ─────────────────────────────────────────────────────────────────
PASS = "PASS"
WARN = "WARN"
FAIL = "FAIL"
NOT_OBSERVED = "NOT_OBSERVED"
STALE = "STALE"
SKIP = "SKIP"
STATUSES = (PASS, WARN, FAIL, NOT_OBSERVED, STALE, SKIP)

# ── 错误类别(与总体框架一致) ─────────────────────────────────────────────────
NETWORK_PRIVATE = "NETWORK_PRIVATE"
DNS = "DNS"
FORWARDING = "FORWARDING"
DEPENDENCY = "DEPENDENCY"
SECURITY = "SECURITY"
RESOURCE = "RESOURCE"
CATEGORIES = (NETWORK_PRIVATE, DNS, FORWARDING, DEPENDENCY, SECURITY, RESOURCE)

# ── reason code: 只登记 6.1A **真的能产生**的那些 ────────────────────────────
# 服务器分不清的结论(如 TCP853_TIMEOUT / DOT_QUERY_NOT_SEEN)一律不预留 —— 提前放进闭集
# 会让人以为已经能观测到, 而它们要到 6.1B 有了会话证据才谈得上。
CODES = (
    "L1_NOT_OBSERVED", "L1_HTTP_PROBE_OBSERVED", "L1_HTTP_PROBE_STALE",
    "L2_CIDR_READY", "L2_CIDR_DRIFT",
    "L2_SOURCE_INSIDE_CIDR", "L2_SOURCE_OUTSIDE_CIDR",
    "L3_SERVER_PROBE_READY", "L3_PLATFORM_NA",
    "L4_DOT_LISTENER_READY", "L4_DOT_LISTENER_MISSING",
    "L5_TLS_READY", "L5_TLS_HANDSHAKE_FAILED", "L5_CERT_CN_MISMATCH",
    "L5_CERT_EXPIRING", "L5_CERT_EXPIRED",
    "L6_LOCAL_DNS_READY", "L6_LOCAL_DNS_FAILED", "L6_PHONE_QUERY_NOT_OBSERVED",
    # 6.1B 的 DNS 时间窗证据。WINDOW_OBSERVED / PROBE_NOT_OBSERVED 目前**产不出来** ——
    # 阶段 3 因 mosdns API 的安全问题停止(见 tests/test-link-dns-evidence.py)。留在
    # 闭集里是因为模型契约已定, 但当前唯一会出现的是 METRICS_UNAVAILABLE。
    "L6_DOT_PROBE_WINDOW_OBSERVED", "L6_DOT_PROBE_NOT_OBSERVED",
    "L6_DOT_METRICS_UNAVAILABLE",
    "L7_REDIRECT_READY", "L7_REDIRECT_RULE_MISSING",
    "L8_SERVICES_READY", "L8_MOSDNS_DOWN", "L8_MIHOMO_DOWN", "L8_NFT_DRIFT",
    "COLLECTOR_ERROR",          # 单项采集器自己抛了 —— 报出来, 但不拖垮整份结果
)

# 哪些层属于"手机/SIM 实时证据"。它们在 6.1A 永远拿不到真实观测, 单独成段展示,
# 免得和"服务器准备好了"混在一起被读成"整条链路正常"。
PHONE_LAYERS = (1, 6.5)

# 手机侧证据不全都落在 PHONE_LAYERS 上: 6.1B 把"这次探测的来源在不在 PDG_INTERNAL_CIDR"
# 挂在第 2 层, 而第 2 层同时还有服务器侧的三方一致性判定 —— 那条必须留在服务器段、
# 也必须继续影响退出码。所以归属按 **code** 再补一层, 而不是给 Finding 加第 13 个字段
# (12 字段是已定的模型契约)。
PHONE_CODES = frozenset((
    "L2_SOURCE_INSIDE_CIDR", "L2_SOURCE_OUTSIDE_CIDR",
))


def is_phone_evidence(f):
    """这条是不是手机侧证据 —— 决定它渲染进哪一段, 以及算不算进退出码。"""
    return f["layer"] in PHONE_LAYERS or f["code"] in PHONE_CODES

CERT_EXPIRING_DAYS = 14


class Finding(dict):
    """一条结构化结果。用 dict 子类是为了能直接 json 序列化, 同时保留属性式读写。"""

    FIELDS = ("layer", "code", "status", "category", "title", "detail",
              "evidence_source", "observed_at", "freshness_secs", "platform",
              "next_step", "blocks_downstream")

    def __init__(self, layer, code, status, category, title, detail,
                 evidence_source, observed_at=None, freshness_secs=0,
                 platform="both", next_step="", blocks_downstream=False):
        if status not in STATUSES:
            raise ValueError("非法状态: %r(闭集: %s)" % (status, ", ".join(STATUSES)))
        if code not in CODES:
            raise ValueError("未登记的 reason code: %r" % (code,))
        if category is not None and category not in CATEGORIES:
            raise ValueError("非法类别: %r" % (category,))
        if platform not in ("both", "ios", "android"):
            raise ValueError("非法平台: %r" % (platform,))
        super().__init__(
            layer=layer, code=code, status=status, category=category, title=title,
            detail=detail, evidence_source=evidence_source,
            observed_at=observed_at if observed_at is not None else time.time(),
            freshness_secs=freshness_secs, platform=platform,
            next_step=next_step, blocks_downstream=bool(blocks_downstream))

    def __getattr__(self, k):
        try:
            return self[k]
        except KeyError:
            raise AttributeError(k)


# ── 采集器 ───────────────────────────────────────────────────────────────────
# 每个采集器返回 Finding 或 Finding 列表; 抛异常由 collect() 兜住, 不影响其它层。


# ── 6.1B: 手机协助会话的证据 ─────────────────────────────────────────────
def _session():
    """读当前会话。拿不到就返回 None —— 会话模块缺失/无会话/状态损坏都当"没有"。

    这里**只读**, 不建也不改会话: `pdg link status` 是只读命令, 6.1A 定下的规矩
    在 6.1B 不放宽。
    """
    try:
        import linksess
        rec, why = linksess.read_state()
        return (rec, why, linksess)
    except Exception:  # noqa: BLE001
        return (None, "NO_SESSION", None)


def _l1_private_traffic(_ctx):
    """手机的 HTTP 探测流量到没到过 :81。

    有会话且已被消费 → 这是**真的观察到了**(内核 peer 地址, 不是推断);
    会话过期 → STALE(观察过, 但那是上一次的事了);
    没有会话 → NOT_OBSERVED, 而不是 FAIL —— 没做诊断不等于坏了。
    """
    rec, _why, mod = _session()
    if rec is None:
        return Finding(
            1, "L1_NOT_OBSERVED", NOT_OBSERVED, None, "手机 HTTP 探测到达",
            "当前没有诊断会话, 所以没有观察。这不代表链路有问题。",
            evidence_source="none(无会话)",
            next_step="要验证手机那条路: pdg link session start")
    consumed = rec.get("http_consumed_at")
    expired = time.time() >= rec.get("expires_at", 0)
    if consumed is None:
        return Finding(
            1, "L1_HTTP_PROBE_STALE" if expired else "L1_NOT_OBSERVED",
            STALE if expired else NOT_OBSERVED, None, "手机 HTTP 探测到达",
            "会话已过期, 期间没有观察到手机访问 :81。" if expired
            else "会话进行中, 还没有观察到手机访问 :81。",
            evidence_source="pdg-probe81 会话状态",
            observed_at=None,
            next_step="在手机上打开 `pdg link session start` 给出的第 1 步链接。")
    return Finding(
        1, "L1_HTTP_PROBE_STALE" if expired else "L1_HTTP_PROBE_OBSERVED",
        STALE if expired else PASS, None, "手机 HTTP 探测到达",
        "观察到一次来自手机的 :81 探测(会话 %s)。这证明手机的网络能到达网关, "
        "**不**证明 SIM/APN 正常, 也不证明 DNS 走通了。" % rec.get("session_id"),
        evidence_source="pdg-probe81 内核 peer 地址(不读 X-Forwarded-For)",
        observed_at=consumed,
        freshness_secs=int(time.time() - consumed))


def _l2_source_evidence(_ctx):
    """会话里记下的实际来源, 命中没命中 PDG_INTERNAL_CIDR。

    只有 /16 前缀与一个布尔 —— 完整 IP 从来没落过盘(见 linksess.py)。
    这条**永不判 FAIL**: 手机连在别的网络上不是服务器故障, 判 FAIL 会污染
    `pdg link status` 的服务器准备状态退出码。
    """
    rec, _why, _m = _session()
    if rec is None or not rec.get("source"):
        return None
    src = rec["source"]
    inside = src.get("inside_internal_cidr")
    pre = src.get("ipv4_16") or "未记录"
    expired = time.time() >= rec.get("expires_at", 0)
    if inside is True:
        return Finding(
            2, "L2_SOURCE_INSIDE_CIDR", STALE if expired else PASS, None,
            "手机来源网段",
            "那次探测的来源落在 PDG_INTERNAL_CIDR 里(网段 %s)。" % pre,
            evidence_source="pdg-probe81 内核 peer 地址 → 仅保留 /16",
            observed_at=rec.get("http_consumed_at"))
    if inside is False:
        return Finding(
            2, "L2_SOURCE_OUTSIDE_CIDR", WARN, NETWORK_PRIVATE, "手机来源网段",
            "那次探测的来源(网段 %s)**不在** PDG_INTERNAL_CIDR 里 —— 手机这次很可能"
            "没走目标 SIM 的私网。" % pre,
            evidence_source="pdg-probe81 内核 peer 地址 → 仅保留 /16",
            observed_at=rec.get("http_consumed_at"),
            next_step="确认手机用的是要诊断的那张 SIM, 且已关闭 Wi-Fi。")
    return Finding(
        2, "L2_SOURCE_INSIDE_CIDR", NOT_OBSERVED, None, "手机来源网段",
        "记到了来源网段 %s, 但 profile.env 里没有 PDG_INTERNAL_CIDR, 无法判断归属。" % pre,
        evidence_source="pdg-probe81 内核 peer 地址 → 仅保留 /16")


def _l2_cidr(ctx):
    src = checks._profile("PDG_INTERNAL_CIDR")
    nftv = checks._cidr_from_nft()
    mosv = checks._cidr_from_mosdns()
    ctx["cidr"] = src or mosv
    diff = []
    if src and nftv and nftv != src:
        diff.append("nft=%s" % nftv)
    if src and mosv and mosv != src:
        diff.append("mosdns=%s" % mosv)
    if not src:
        return Finding(
            2, "L2_CIDR_DRIFT", FAIL, DEPENDENCY, "内网卡段",
            "profile.env 里没有 PDG_INTERNAL_CIDR(真源缺失)。当前实际生效: nft=%s / mosdns=%s"
            % (nftv or "读不到", mosv or "读不到"),
            evidence_source="profile.env / nft / mosdns",
            next_step="sudo pdg migrate 写入真源, 或 sudo pdg detect-cidr 重新统一。",
            blocks_downstream=True)
    try:
        import ipaddress
        ipaddress.ip_network(src, strict=False)
    except Exception:  # noqa: BLE001
        return Finding(
            2, "L2_CIDR_DRIFT", FAIL, DEPENDENCY, "内网卡段",
            "%s 不是合法 CIDR" % src, evidence_source="profile.env",
            next_step="sudo pdg detect-cidr 重新设置。", blocks_downstream=True)
    if diff:
        return Finding(
            2, "L2_CIDR_DRIFT", FAIL, DEPENDENCY, "内网卡段",
            "profile.env 记的是 %s, 但 %s —— 三处不一致时放行/分流/救援入口会各说各话。"
            % (src, "、".join(diff)),
            evidence_source="profile.env / nft / mosdns",
            next_step="sudo pdg detect-cidr 重新统一三处。", blocks_downstream=True)
    return Finding(
        2, "L2_CIDR_READY", PASS, None, "内网卡段",
        "%s(profile.env / nft / mosdns 三处一致)" % src,
        evidence_source="profile.env / nft / mosdns")


def _l3_probe(ctx):
    if ctx["platform"] != "ios":
        return Finding(
            3, "L3_PLATFORM_NA", SKIP, None, "iOS 探测端点(:81)",
            "Android 不安装 pdg-probe81, 也不监听/放行 81 —— 该层不适用本平台。",
            evidence_source="/etc/privdns-gateway/platform", platform="android")
    rc, out, _ = checks._run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                              "--max-time", "5", "http://127.0.0.1:81/probe"])
    code = (out or "").strip()
    if code == "200":
        return Finding(
            3, "L3_SERVER_PROBE_READY", PASS, None, "iOS 探测端点(:81)",
            "本机 127.0.0.1:81 返回 200 —— 服务端就绪。"
            "这**不**代表手机经运营商私网连得上它。",
            evidence_source="本机 curl 127.0.0.1:81", platform="ios")
    return Finding(
        3, "L3_SERVER_PROBE_READY", FAIL, DEPENDENCY, "iOS 探测端点(:81)",
        "本机 127.0.0.1:81 返回 %s(iOS OnDemand 需要 200)" % (code or "无响应"),
        evidence_source="本机 curl 127.0.0.1:81", platform="ios",
        next_step="systemctl status pdg-probe81 查看服务。")


def _l4_dot_listener(_ctx):
    s = socket.socket()
    s.settimeout(2.0)
    try:
        ok = s.connect_ex(("127.0.0.1", 853)) == 0
    except OSError:
        ok = False
    finally:
        s.close()
    if ok:
        return Finding(
            4, "L4_DOT_LISTENER_READY", PASS, None, "DoT 监听(853)",
            "本机 853 在监听。这只说明端口开着, 不代表手机能连到它。",
            evidence_source="本机 TCP connect 127.0.0.1:853")
    return Finding(
        4, "L4_DOT_LISTENER_MISSING", FAIL, DEPENDENCY, "DoT 监听(853)",
        "本机 853 连不上(mosdns 的 DoT 入口没起?)",
        evidence_source="本机 TCP connect 127.0.0.1:853",
        next_step="systemctl status mosdns; sudo pdg doctor --deep",
        blocks_downstream=True)


def _cert_not_after(path):
    """只取证书的到期时间与 CN。**绝不读取也绝不输出私钥正文** —— 只用 x509 子命令,
    它对私钥文件会直接失败(那正是我们要报的 FAIL)。"""
    rc, out, err = checks._run(
        ["openssl", "x509", "-in", path, "-noout", "-enddate", "-subject"], t=12)
    if rc != 0 or "notAfter=" not in (out or ""):
        # openssl 的报错常是多行(还带一行十六进制错误码)。原样塞进 detail 会把版面撑乱,
        # 而诊断输出的可读性本身就是它的价值之一。压成一行再截断。
        why = re.sub(r"\s+", " ", (err or out or "")).strip()
        return None, "", why[:110]
    m = re.search(r"notAfter=(.+)", out)
    cn = ""
    mc = re.search(r"CN\s*=\s*([A-Za-z0-9.*-]+)", out)
    if mc:
        cn = mc.group(1)
    try:
        ts = ssl.cert_time_to_seconds(m.group(1).strip())
    except Exception:  # noqa: BLE001
        return None, cn, "notAfter 解析失败"
    return ts, cn, ""


def _l5_tls(ctx):
    """本机 DoT TLS 握手 + 证书主机名 + 有效期。

    三件事分开判: 握手不通是 FAIL(手机必然也连不上); CN 不符是 FAIL(手机会拒);
    临期是 WARN(现在还能用, 但不修就会变成 FAIL)。
    """
    out = []
    path = checks._cert_path()
    ts, cn, why = _cert_not_after(path)
    dot = checks._dot_file() or cn
    if ts is None:
        out.append(Finding(
            5, "L5_CERT_EXPIRED", FAIL, SECURITY, "DoT 证书",
            "读不到或解析不了证书(%s): %s" % (path, why or "未知原因"),
            evidence_source="openssl x509 -noout -enddate -subject",
            next_step="确认 %s 是证书而不是私钥, 或重新签发。" % path,
            blocks_downstream=True))
    else:
        left = int((ts - time.time()) // 86400)
        if left < 0:
            out.append(Finding(
                5, "L5_CERT_EXPIRED", FAIL, SECURITY, "DoT 证书",
                "证书已过期 %d 天(CN=%s)" % (-left, cn or "?"),
                evidence_source="openssl x509 -noout -enddate",
                next_step="续期证书后重启 mosdns。", blocks_downstream=True))
        elif left < CERT_EXPIRING_DAYS:
            out.append(Finding(
                5, "L5_CERT_EXPIRING", WARN, SECURITY, "DoT 证书",
                "证书还有 %d 天到期(CN=%s)" % (left, cn or "?"),
                evidence_source="openssl x509 -noout -enddate",
                next_step="尽快续期, 否则手机会在到期后连不上。"))
        if dot and cn and cn != dot:
            out.append(Finding(
                5, "L5_CERT_CN_MISMATCH", FAIL, SECURITY, "DoT 证书主机名",
                "证书 CN=%s 与配置的 DoT 主机名 %s 不符 —— 手机会拒绝这条连接。" % (cn, dot),
                evidence_source="openssl x509 -noout -subject / dot-domain",
                next_step="让证书 CN 与 DoT 主机名一致后重启 mosdns。",
                blocks_downstream=True))

    rc, hs, hs_err = checks._run(
        ["openssl", "s_client", "-connect", "127.0.0.1:853", "-servername", dot or "localhost"],
        t=14)
    if "BEGIN CERTIFICATE" not in (hs or "") and "Verify return code" not in (hs or ""):
        # 握手没成。**为什么**没成决定了该不该单独记一条 —— 上面若已经查出具体的证书
        # 故障(过期 / 读不出 / CN 不符), 再加一条通用的"握手失败"就是同一个根因写两遍,
        # 而且通用那条不带任何可执行信息, 只会让人多修一遍。
        blob = (hs or "") + (hs_err or "")
        connect_level = bool(re.search(
            r"connect:|Connection refused|No route to host|unable to connect|"
            r"Network is unreachable", blob))
        specific = [f for f in out if f["status"] == FAIL]
        if specific:
            # 不是吞掉: 观察到的现象并进那条具体结论的证据里, 归因链仍然完整。
            # 真正独立的故障(证书没毛病却握不上手)走 else 分支, 照常单独报。
            specific[0]["evidence_source"] += (
                " + 本机 853 %s" % ("连不上(端口层, 见第 4 层)" if connect_level
                                    else "TLS 握手未完成"))
        else:
            out.append(Finding(
                5, "L5_TLS_HANDSHAKE_FAILED", FAIL, SECURITY, "DoT TLS 握手",
                "本机 853 连不上, TLS 握手无从谈起(根因在第 4 层的监听)。" if connect_level
                else "本机 853 的 TLS 握手没完成。",
                evidence_source="本机 openssl s_client 127.0.0.1:853",
                next_step="systemctl status mosdns; 检查证书与私钥是否配对。",
                blocks_downstream=True))
    elif not any(f["status"] == FAIL for f in out):
        out.append(Finding(
            5, "L5_TLS_READY", PASS, None, "DoT TLS 握手",
            "本机 TLS 握手成功(CN=%s)。这**不**代表手机信任这张证书。" % (cn or "?"),
            evidence_source="本机 openssl s_client 127.0.0.1:853"))
    return out


def _l6_dns(_ctx):
    out = []
    rc, ans, _ = checks._run(
        ["dig", "+short", "+time=3", "+tries=1", "@127.0.0.1", "example.com", "A"], t=12)
    ips = [x for x in (ans or "").split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
    if ips:
        out.append(Finding(
            6, "L6_LOCAL_DNS_READY", PASS, None, "本机 DNS 解析",
            "本机 dig @127.0.0.1 有应答 —— mosdns 在处理查询。"
            "注意: 127.0.0.1 不在内网卡段里, 劫持与分流对它不生效, 所以这**不是**手机那条路的证据。",
            evidence_source="本机 dig @127.0.0.1"))
    else:
        out.append(Finding(
            6, "L6_LOCAL_DNS_FAILED", FAIL, DNS, "本机 DNS 解析",
            "本机 dig @127.0.0.1 没有 A 记录(mosdns 或上游异常?)",
            evidence_source="本机 dig @127.0.0.1",
            next_step="systemctl status mosdns; sudo pdg doctor --deep",
            blocks_downstream=True))
    out.append(Finding(
        6.5, "L6_DOT_METRICS_UNAVAILABLE", NOT_OBSERVED, None, "手机 DoT 查询到达",
        "没有 DNS 侧证据: 专用 probe 计数器未启用。6.1B 在安全审查中停止了这一步 —— "
        "官方 mosdns v5.3.4 的 API 一旦打开, 同一个端口上还会暴露 DNS 缓存导出与投喂"
        "接口(见 tests/test-link-dns-evidence.py), 那会泄露普通浏览域名。留到 6.2。",
        evidence_source="none(6.1A 无实时观测)",
        next_step="要验证需要 6.1B 的一次性协助会话。"))
    return out


def _l7_redirect(ctx):
    cidr = ctx.get("cidr") or ""
    rc, out, _ = checks._run(["nft", "list", "chain", "inet", "pdg", "prerouting"], t=12)
    txt = out or ""
    ok = bool(re.search(r"redirect to :\d+", txt)) and (not cidr or cidr in txt)
    if ok:
        return Finding(
            7, "L7_REDIRECT_READY", PASS, None, "80/443 私网入口",
            "内核里有 %s 的 80/443 → redirect 规则。" % (cidr or "内网卡段"),
            evidence_source="nft list chain inet pdg prerouting")
    return Finding(
        7, "L7_REDIRECT_RULE_MISSING", FAIL, FORWARDING, "80/443 私网入口",
        "内核 prerouting 链里没找到 %s 的 80/443 redirect 规则。" % (cidr or "内网卡段"),
        evidence_source="nft list chain inet pdg prerouting",
        next_step="sudo pdg doctor 查看; 必要时 sudo pdg migrate-fw。")


def _l8_services(ctx):
    out = []
    # 判据与 checks.check_services 同一句(systemctl is-active), 不另造一套。
    down = [u for u in ("mosdns", "mihomo")
            if checks._run(["systemctl", "is-active", u])[1].strip() != "active"]
    if "mosdns" in down:
        out.append(Finding(
            8, "L8_MOSDNS_DOWN", FAIL, DEPENDENCY, "核心服务",
            "mosdns 没在运行 —— DNS 这条路整条断。", evidence_source="systemctl is-active",
            next_step="systemctl status mosdns", blocks_downstream=True))
    if "mihomo" in down:
        out.append(Finding(
            8, "L8_MIHOMO_DOWN", FAIL, DEPENDENCY, "核心服务",
            "mihomo 没在运行 —— 分流与出口不可用。", evidence_source="systemctl is-active",
            next_step="systemctl status mihomo", blocks_downstream=True))
    if not down:
        extra = ""
        if ctx["platform"] == "ios":
            extra = "(iOS 另有 pdg-mitm / pdg-probe81, 由 doctor 单独检查)"
        out.append(Finding(
            8, "L8_SERVICES_READY", PASS, None, "核心服务",
            "mosdns / mihomo 均在运行%s" % extra, evidence_source="systemctl is-active"))

    # nft: 磁盘配置与内核运行态是否一致 —— 只读磁盘会漏掉"改了文件但没 apply"这种最常见的漂移
    rc_k, kern, _ = checks._run(["nft", "list", "table", "inet", "pdg"], t=15)
    if rc_k != 0 or not (kern or "").strip():
        out.append(Finding(
            8, "L8_NFT_DRIFT", FAIL, FORWARDING, "防火墙磁盘/内核一致性",
            "内核里读不到 inet pdg 表(规则没加载?)", evidence_source="nft list table inet pdg",
            next_step="sudo nft -f /etc/nftables.conf 后复查。", blocks_downstream=True))
        return out
    try:
        disk = open("/etc/nftables.conf", encoding="utf-8").read()
    except OSError as e:
        out.append(Finding(
            8, "L8_NFT_DRIFT", WARN, FORWARDING, "防火墙磁盘/内核一致性",
            "读不到 /etc/nftables.conf(%s) —— 无法比对磁盘与内核。" % type(e).__name__,
            evidence_source="/etc/nftables.conf"))
        return out
    kn = _nft_rule_set(kern)
    dn = _nft_rule_set(disk)
    missing = dn - kn
    if missing:
        out.append(Finding(
            8, "L8_NFT_DRIFT", FAIL, FORWARDING, "防火墙磁盘/内核一致性",
            "磁盘上有 %d 条规则没在内核里生效(例: %s)"
            % (len(missing), sorted(missing)[0][:70]),
            evidence_source="/etc/nftables.conf vs nft list table inet pdg",
            next_step="sudo nft -f /etc/nftables.conf 让内核与磁盘一致。"))
    else:
        out.append(Finding(
            8, "L8_NFT_DRIFT", PASS, None, "防火墙磁盘/内核一致性",
            "磁盘上的规则都能在内核里找到。", evidence_source="/etc/nftables.conf vs nft list"))
    return out


def _nft_rule_set(text):
    """把 nft 文本归一成"规则行集合", 用于磁盘/内核比对。

    只取真正的规则行: 表/链声明、大括号、注释、include 都不算。归一化掉多余空白与行尾注释,
    否则内核输出里的 `# handle 5` 会让每一条都判成不一致。
    """
    out = set()
    for ln in (text or "").splitlines():
        s = ln.strip()
        if not s or s.startswith("#") or s.startswith("include"):
            continue
        if s.startswith("table ") or s.startswith("chain ") or s in ("{", "}", "};"):
            continue
        if s.startswith("type ") or s.startswith("delete table"):
            continue
        s = re.sub(r"#.*$", "", s).strip()
        s = re.sub(r"\s+", " ", s)
        if s and s not in ("{", "}"):
            out.add(s)
    return out


COLLECTORS = (
    ("L1", _l1_private_traffic),
    ("L2", _l2_cidr),
    ("L2", _l2_source_evidence),      # 会话里的实际来源(仅 /16 + 布尔)
    ("L3", _l3_probe),
    ("L4", _l4_dot_listener),
    ("L5", _l5_tls),
    ("L6", _l6_dns),
    ("L7", _l7_redirect),
    ("L8", _l8_services),
)


def collect(platform=None):
    """跑一遍全部采集器。**单项抛异常不许拖垮整份结果** —— 那一层记 COLLECTOR_ERROR,
    其余照常输出。诊断工具最不该做的事就是"出了点问题所以什么都不告诉你"。"""
    ctx = {"platform": platform or checks._platform()}
    findings = []
    for name, fn in COLLECTORS:
        try:
            r = fn(ctx)
        except Exception as e:  # noqa: BLE001
            findings.append(Finding(
                int(name[1:]), "COLLECTOR_ERROR", FAIL, RESOURCE, "%s 采集失败" % name,
                "这一层的检查自己出错了(%s) —— 其余层的结果仍然有效。" % type(e).__name__,
                evidence_source="collector:%s" % name,
                next_step="把这条连同 sudo pdg doctor --deep 的输出一起反馈。"))
            continue
        if r is None:
            continue
        findings.extend(r if isinstance(r, list) else [r])
    return findings


# ── 呈现 ─────────────────────────────────────────────────────────────────────
_MARK = {PASS: "🟢", WARN: "🟡", FAIL: "🔴", NOT_OBSERVED: "⚪", STALE: "🕓", SKIP: "⏭️"}

_PHONE_NOTE = ("当前仅检查服务器准备状态, 尚未观察手机的实时链路; "
               "这不代表 SIM/APN 正常, 也不代表发生故障。")

# 会话里真的观察到东西之后, 上面那句就不再成立了(它说的是"尚未观察")。但**能说的
# 上限**没变: 观察到的是"手机的网络到达了 :81", 不是 SIM/APN 正常, 更不是 DNS 走通。
_PHONE_NOTE_OBSERVED = (
    "以上是本次会话时间窗内观察到的证据。HTTP 证据只说明手机的网络到达了网关的 :81; "
    "它不证明 SIM/APN 正常, 不证明手机采用了这次 DNS 响应, 也不证明最终走了哪个上游。")


def render_text(findings):
    server = [f for f in findings if not is_phone_evidence(f)]
    phone = [f for f in findings if is_phone_evidence(f)]
    lines = ["━━ 服务器准备状态 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"]
    for f in sorted(server, key=lambda x: x["layer"]):
        lines.append("  %s %-16s %s" % (_MARK[f["status"]], f["title"], f["detail"]))
        if f["next_step"] and f["status"] in (WARN, FAIL):
            lines.append("       → %s" % f["next_step"])
    lines.append("")
    lines.append("━━ 手机/SIM 实时证据 ━━━━━━━━━━━━━━━━━━━━━━━━━━")
    for f in sorted(phone, key=lambda x: x["layer"]):
        lines.append("  %s %-16s %s" % (_MARK[f["status"]], f["title"], f["detail"]))
    observed = any(f["status"] in (PASS, STALE) for f in phone)
    lines.append("     %s" % (_PHONE_NOTE_OBSERVED if observed else _PHONE_NOTE))
    return "\n".join(lines)


def exit_code(findings):
    """退出码规则(实现前定死, 有测试盯着):
      2 = 服务器准备状态里有 FAIL(真的坏了, 值得脚本据此报警)
      0 = 只有 PASS / WARN / NOT_OBSERVED / STALE / SKIP
      3 = 模型损坏或命令自身没能完成
    NOT_OBSERVED **不得**导致非零 —— 它是"没看到", 不是"坏了"。
    """
    try:
        for f in findings:
            if f["status"] not in STATUSES:
                return 3
            if f["status"] == FAIL and not is_phone_evidence(f):
                return 2
        return 0
    except Exception:  # noqa: BLE001
        return 3


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    try:
        findings = collect()
    except Exception as e:  # noqa: BLE001
        print("链路诊断没能完成: %s" % type(e).__name__, file=sys.stderr)
        return 3
    if as_json:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "findings": findings},
                         ensure_ascii=False, indent=1))
    else:
        print(render_text(findings))
    return exit_code(findings)


if __name__ == "__main__":
    sys.exit(main())

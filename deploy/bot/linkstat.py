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
    "L8_SERVICES_READY", "L8_MOSDNS_DOWN", "L8_MIHOMO_DOWN",
    # 第 8 层的防火墙判据。旧的 L8_NFT_DRIFT(磁盘/内核逐条文本相等)已**整个删掉**:
    # 它把 nft 自己的规范化(单元素集合折叠、reject 默认值展开、协议名别名)当成漂移,
    # `.153` 上一台完全健康的机器因此被判 FAIL、Bot 拒绝创建手机测试会话。
    # 查过了: 它引入于 745e5f8(6.1A), 包含它的 tag 数为 0, linkstat.py 在 origin/main 与
    # v1.8.0 里都不存在 —— 从未进过正式版本, 没有兼容债务, 所以不留无调用的死常量。
    "L8_FIREWALL_READY", "L8_FIREWALL_CONFIG_INVALID",
    "L8_FIREWALL_KERNEL_UNREADABLE", "L8_FIREWALL_RULE_MISSING",
    "L8_FIREWALL_RULE_UNSAFE", "L8_FIREWALL_RULE_ORDER_INVALID",
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
            "会话已过期, 期间服务器没有观察到本次会话的 HTTP 请求。" if expired
            else "会话进行中, 服务器还没有观察到本次会话的 HTTP 请求。",
            evidence_source="pdg-probe81 会话状态",
            observed_at=None,
            next_step="在手机上打开 `pdg link session start` 给出的第 1 步链接。")
    return Finding(
        1, "L1_HTTP_PROBE_STALE" if expired else "L1_HTTP_PROBE_OBSERVED",
        STALE if expired else PASS, None, "手机 HTTP 探测到达",
        "服务器观察到本次会话的 HTTP 请求(会话 %s)。这只说明该请求到达了网关的 :81, "
        "不能据此判断 SIM/APN、DoT 或手机整体联网是否正常。" % rec.get("session_id"),
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
            "该请求来自配置的内网卡来源段(网段 %s)。这只说明来源网段一致, "
            "不代表 DoT 或手机整体联网正常。" % pre,
            evidence_source="pdg-probe81 内核 peer 地址 → 仅保留 /16",
            observed_at=rec.get("http_consumed_at"))
    if inside is False:
        return Finding(
            2, "L2_SOURCE_OUTSIDE_CIDR", WARN, NETWORK_PRIVATE, "手机来源网段",
            "该请求**不是**来自配置的内网卡来源段(网段 %s)。" % pre,
            evidence_source="pdg-probe81 内核 peer 地址 → 仅保留 /16",
            observed_at=rec.get("http_consumed_at"),
            next_step="确认手机用的是要诊断的那张 SIM, 且已关闭 Wi-Fi。")
    return Finding(
        2, "L2_SOURCE_INSIDE_CIDR", NOT_OBSERVED, None, "手机来源网段",
        "记到了来源网段 %s, 但 profile.env 里没有 PDG_INTERNAL_CIDR, "
        "无法判断它是不是配置的内网卡来源段。" % pre,
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
    # 6.1B 起 pdg-probe81 是 **Android/iOS 公共**组件 —— 手机链路测试的 HTTP 探测端点两
    # 平台都要用它。这里以前按 iOS 专属跳过, 于是 Android 上报"不安装、不监听/放行 81",
    # 而同一台机器上它 active、:81 在听、nft 有放行、doctor 报绿: 又是两套检查对同一台
    # 机器给出相反说法(`.153` 实测撞到)。平台门去掉, 标题也不再叫"iOS 探测端点"。
    rc, out, _ = checks._run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                              "--max-time", "5", "http://127.0.0.1:81/probe"])
    code = (out or "").strip()
    if code == "200":
        return Finding(
            3, "L3_SERVER_PROBE_READY", PASS, None, "探测端点(:81)",
            "本机 127.0.0.1:81 返回 200 —— 服务端就绪。"
            "这**不**代表手机经运营商私网连得上它。",
            evidence_source="本机 curl 127.0.0.1:81")
    return Finding(
        3, "L3_SERVER_PROBE_READY", FAIL, DEPENDENCY, "探测端点(:81)",
        "本机 127.0.0.1:81 返回 %s(手机链路测试的 HTTP 探测端点需要 200)"
        % (code or "无响应"),
        evidence_source="本机 curl 127.0.0.1:81",
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
        6.5, "L6_DOT_METRICS_UNAVAILABLE", NOT_OBSERVED, None, "手机 DoT 查询证据",
        # 这里只留结论。为什么不采集(接口暴露面、缓存导出、投喂端点、本机 SSRF、反向代理
        # 隔离不了上游端口)是给维护者看的论证, 放在 README 与 docs/ROADMAP.md ——
        # 用户在自检里看到一串内部实现名词, 既看不懂也无从处置。
        "当前版本暂不采集这项证据，因此无法判断手机的 DoT 查询是否到达；"
        "这不代表正常，也不代表故障。",
        evidence_source="none(本版本不采集 DNS 侧证据)",
        next_step="可先完成 HTTP 链路测试；DNS 实时证据将在后续版本重新设计。"
                  "技术原因见项目路线图。"))
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

    # ── 防火墙运行状态 ────────────────────────────────────────────────────
    # 分成两件互不冒充的事:
    #   1) 磁盘配置有效 —— 只读的 `nft -c -f`, 不加载、不改内核;
    #   2) 内核里项目运行必需的规则确实生效 —— `nft -j` 读 live kernel, 交给 nftlive 按
    #      JSON 表达式做**语义**判断(doctor 与这里共用同一个核心, 不各写一套)。
    #
    # 以前这里拿磁盘文本与内核文本做集合比对。nft 输出时会自己规范化写法, 于是四条完全
    # 等价的规则被判成"磁盘有、内核没有" —— `.153` 上一台健康机器常年 FAIL, 而 doctor
    # 同时报 0 失败 0 警告。文本近似不是判据。
    #
    # "磁盘每条规则都在内核里逐条生效"仍然**没做**: 要可靠比对得先把候选配置规范化, 而
    # 实测 nftables v1.0.6 的 `nft -c -j -f` 输出 0 字节 —— 只有真正加载才吐得出规范形态。
    # 加载到宿主机、或为每次自检建 netns, 都越过了 linkstat 只读无副作用的边界。所以这里
    # 明确只证"配置有效 + 必需规则安全生效", 全量逐条审计移交后续阶段, 不用文本近似冒充。
    import nftlive
    cfg_ok, cfg_why = nftlive.check_disk_config()
    if not cfg_ok:
        out.append(Finding(
            8, "L8_FIREWALL_CONFIG_INVALID", FAIL, FORWARDING, "防火墙运行状态",
            "磁盘上的防火墙配置无效: %s" % cfg_why,
            evidence_source="nft -c -f /etc/nftables.conf",
            next_step="修好 /etc/nftables.conf 后复查。", blocks_downstream=True))
        return out
    kobj, kwhy = nftlive.read_kernel()
    if kobj is None:
        out.append(Finding(
            8, "L8_FIREWALL_KERNEL_UNREADABLE", FAIL, FORWARDING, "防火墙运行状态",
            "读不到当前内核的防火墙规则: %s" % kwhy,
            evidence_source="nft -j list table inet pdg",
            next_step="在服务器上确认 nft 可用、规则已加载后复查。", blocks_downstream=True))
        return out
    audit = nftlive.audit_kernel(
        kobj, cidr=(ctx.get("cidr") or checks._profile("PDG_INTERNAL_CIDR")),
        # 平台从 ctx 取: 这个采集器的签名只有 ctx, 直接写 platform 是 NameError ——
        # 而 collect() 会把整层的异常收成 COLLECTOR_ERROR, 于是"防火墙这一层没有结论",
        # 看起来像检查不存在。
        platform=(ctx.get("platform") if ctx.get("platform") in ("ios", "android")
                  else "android"),
        # 改写目标口取自 mihomo 配置(与 doctor 同一个读法), 不在这里再写一次 7893。
        redir_port=checks._mihomo_redir_port())
    if audit.ok:
        out.append(Finding(
            8, "L8_FIREWALL_READY", PASS, None, "防火墙运行状态",
            "防火墙配置有效，手机链路所需规则已在内核中生效。",
            evidence_source="nft -c -f + nft -j list table inet pdg"))
    else:
        # reason code 按 kind 选, 不按文案关键字 —— 靠"排在""来源"这类词分类, 改一次措辞
        # 就会静默错档, 而 code 是闭集契约, 外部靠它判断该怎么处理。
        kinds = {p.kind for p in audit.problems}
        code = ("L8_FIREWALL_RULE_ORDER_INVALID" if "order" in kinds
                else "L8_FIREWALL_RULE_UNSAFE" if kinds & {"source", "leak", "verdict"}
                else "L8_FIREWALL_RULE_MISSING")
        out.append(Finding(
            8, code, FAIL, FORWARDING, "防火墙运行状态",
            "内核里的防火墙规则不满足手机链路要求: %s" % "; ".join(audit.problems[:3]),
            evidence_source="nft -j list table inet pdg",
            next_step="核对 /etc/nftables.conf 并让它在内核中生效后复查。",
            blocks_downstream=True))
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
    "以上是本次会话时间窗内观察到的证据。HTTP 证据只说明服务器观察到本次会话的 HTTP 请求, "
    "来源段只说明该请求来自配置的内网卡来源段; 本版本无法观察手机是否真的发出了 DoT 查询。"
    "因此不能据此判断 SIM/APN、DoT 或手机整体联网是否正常。")


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

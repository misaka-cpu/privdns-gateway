#!/usr/bin/env python3
"""PrivDNS Gateway 只读检查库。doctor.py 跑全部, healthcheck.py 跑子集。
每个 check() 返回 (level, label, detail), level ∈ 'ok'|'warn'|'fail'|'info'。只读, 不改任何东西。"""
import os, re, json, ipaddress, subprocess, sys, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nftscan  # noqa: E402  与迁移前置门共用的 input 链冲突判据(单一来源)

SB = "/etc/sing-box/config.json"
MOSDNS_CONF = "/etc/mosdns/config.yaml"
DOT_DOMAIN_FILE = "/opt/pdg-bot/dot-domain"
BACKEND_MARKER = "/etc/privdns-gateway/backend"
MIHOMO_CFG = "/etc/mihomo/config.yaml"
NFT_CONF = "/etc/nftables.conf"
PROFILE_ENV = "/etc/privdns-gateway/profile.env"   # 内网卡段等持久化配置的**唯一真源**
PLATFORM_FILE = "/etc/privdns-gateway/platform"
PLATFORM_GUESSED = PLATFORM_FILE + ".guessed"   # 存在 = 平台是推测出来的, 没人确认过
REPO_DIR = "/opt/privdns-gateway"   # 已装仓库(比对部署文件是否与当前发布同版本)
RS_META = "/opt/pdg-bot/rulesets.json"   # 规则集元数据(与 bot 同源)
MOSDNS_RULES_DIR = "/etc/mosdns/rules"
UNLOCK_FILE = MOSDNS_RULES_DIR + "/unlock.txt"                # WDA 解锁清单(= 自动生成那批域名的真源)
MITM_HIJACK_FILE = MOSDNS_RULES_DIR + "/mitm_hijack.txt"      # MITM 接管域名
CUSTOM_DIRECT_FILE = MOSDNS_RULES_DIR + "/custom_direct.txt"  # 用户判直连的域名(DNS 侧就返真实 IP)
# 面板 UI 在 /etc/sing-box/ui/dist, 不在 mihomo 工作目录下 → SAFE_PATHS 放行, 否则 `mihomo -t` 拒。
os.environ.setdefault("SAFE_PATHS", "/etc/sing-box/ui/dist")

def _core():
    """活动内核: v1.6.0 起恒 mihomo(彻底移除 sing-box 运行时)。"""
    return "mihomo"

def _core_svc():
    return "mihomo"

def _platform():
    """手机平台: ios / android(读不到默认 android)。用于跳过平台不相关的检查。"""
    try:
        p = open(PLATFORM_FILE, encoding="utf-8").read().strip()
        if p in ("ios", "android"):
            return p
    except OSError:
        pass
    return "android"

def _run(cmd, t=10):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=t)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)

def _mos():
    try:
        return open(MOSDNS_CONF).read()
    except Exception:  # noqa: BLE001
        return ""

def _server_ip():
    try:
        for r in json.load(open(SB)).get("route", {}).get("rules", []):
            if r.get("action") == "reject":
                for x in r.get("ip_cidr", []):
                    if x.endswith("/32") and not x.startswith("127."):
                        return x.split("/")[0]
    except Exception:  # noqa: BLE001
        pass
    return ""

def _cert_path():
    m = re.search(r'cert:\s*"([^"]+)"', _mos())
    return m.group(1) if m else os.environ.get("PDG_CERT", "/etc/mosdns/certs/fullchain.pem")

def _profile(key):
    """从 profile.env 读一个键(唯一真源)。读不到返回空串。"""
    try:
        with open(PROFILE_ENV, encoding="utf-8") as f:
            m = re.findall(r"^[ \t]*%s=[\"']?([^\"'\n]+)" % re.escape(key), f.read(), re.M)
        return m[-1].strip() if m else ""
    except OSError:
        return ""


def _cidr_from_mosdns():
    m = re.search(r'ips:\s*\[\s*"([^"]+)"', _mos())
    return m.group(1) if m else ""


def _cidr_from_nft():
    _, out, _ = _run(["nft", "list", "chain", "inet", "pdg", "input"])
    if not out:
        _, out, _ = _run(["nft", "list", "chain", "inet", "filter", "input"])
    m = re.search(r"ip saddr ([0-9.]+/[0-9]+)", out or "")
    return m.group(1) if m else ""


def _internal_cidr():
    """内网卡来源段。**真源是 profile.env 的 PDG_INTERNAL_CIDR**(5.2/T7)。

    回退到 mosdns 配置只为兼容"尚未迁移写入真源"的老机器 —— 迁移之后这条回退就不该再命中,
    check_cidr_drift() 会把仍在回退的机器报出来。不能反过来以 mosdns 为准: 那份配置正是
    救援场景里可能损坏的东西, 而这个值决定救援服务绑在哪个地址上。"""
    return _profile("PDG_INTERNAL_CIDR") or _cidr_from_mosdns()

def _cert_cn():
    _, out, _ = _run(["openssl", "x509", "-in", _cert_path(), "-noout", "-subject"])
    m = re.search(r"CN\s*=\s*([A-Za-z0-9.*-]+)", out)
    return m.group(1) if m else ""

def _dot_domain():
    # 证书 CN = mosdns 实际服务、手机 TLS 必须匹配的域名(权威); dot-domain 文件只是续期提示, 可能过期
    return _cert_cn() or _dot_file()

def _dot_file():
    try:
        return open(DOT_DOMAIN_FILE).read().strip()
    except Exception:  # noqa: BLE001
        return ""

# ── 平台线索 ────────────────────────────────────────────────────────────────
# 老装(v1.4.x)升上来时平台是**推测**的: 那会儿 probe81/描述文件模板装给了所有机器,
# 它们的存在证明不了平台。但手机自己会说话 —— 两个系统各有一条**系统级长连接**,
# 从网关这侧看得见, 手机待机也在:
#   Android: GMS 推送 mtalk.google.com:5228(v1.4.x 装机就把 5228-5230 转进代理)
#   iOS:     APNs / 定位 / 联网检测 → *.push.apple.com、gs-loc.apple.com、captive.apple.com
# 只作**线索**提示, 绝不据此自动改标记 —— 猜错方向去做破坏性清理正是要避免的事。
_APPLE_HOSTS   = ("push.apple.com", "gs-loc.apple.com", "captive.apple.com", "gsp-ssl.ls.apple.com")
_ANDROID_HOSTS = ("mtalk.google.com", "connectivitycheck.gstatic.com", "android.clients.google.com")

def _conn_hosts():
    """内核活动连接的目标主机名(clash_api /connections)。读不到就返回 [] —— 没线索不影响判定。"""
    try:
        req = urllib.request.Request("http://127.0.0.1:9090/connections")
        try:                                        # 面板开启时设了 secret, 本机调用也要带 Bearer
            sec = (json.load(open(SB)).get("experimental", {}).get("clash_api", {}) or {}).get("secret") or ""
        except Exception:  # noqa: BLE001
            sec = ""
        if sec:
            req.add_header("Authorization", "Bearer " + sec)
        with urllib.request.urlopen(req, timeout=3) as r:
            data = json.load(r)
    except Exception:  # noqa: BLE001
        return []
    out = []
    for c in (data.get("connections") or []):
        h = ((c.get("metadata") or {}).get("host") or "").strip().lower()
        if h:
            out.append(h)
    return out

def _gms_established():
    """GMS 推送端口(5228-5230)上有没有活动连接。iPhone 不用 GMS, 这是 Android 的强线索。
    转发两侧都算数: 手机→网关那条被 REDIRECT 后本地口是 5228, 网关→Google 那条对端口是 5228。"""
    rc, out, _ = _run(["ss", "-Htn", "state", "established"], t=5)
    if rc != 0:
        return False
    return bool(re.search(r":(?:5228|5229|5230)\b", out))

def platform_hint():
    """按可观测证据给平台线索: (ios|android, 说明) 或 (None, "")。只读; 拿不到证据就沉默。"""
    hosts = _conn_hosts()
    for h in hosts:
        if any(h == d or h.endswith("." + d) for d in _APPLE_HOSTS):
            return ("ios", "内核活动连接里有 %s(iOS 系统级服务)" % h)
    for h in hosts:
        if any(h == d or h.endswith("." + d) for d in _ANDROID_HOSTS):
            return ("android", "内核活动连接里有 %s(Android 系统级服务)" % h)
    if _gms_established():
        return ("android", "有 GMS 推送端口 5228-5230 上的活动连接(iPhone 不用 GMS)")
    return (None, "")

def check_platform():
    """平台标记(/etc/privdns-gateway/platform)是否明确。缺失/非法 → warn: 当前按 Android 安全回退,
    但这不是已确认的 Android; 跑一次 sudo pdg(触发 migrate_platform_marker)即可落定。"""
    try:
        p = open(PLATFORM_FILE, encoding="utf-8").read().strip()
    except OSError:
        p = ""
    if p in ("ios", "android"):
        # 标记是"推测"出来的(老装无平台概念, 且机器上的 iOS 组件证明不了平台): 持续提示到人工确认。
        # 推测状态下破坏性的平台清理一律不做, 免得把真 iPhone 部署的 iOS 组件删掉。
        if os.path.exists(PLATFORM_GUESSED):
            g, why = platform_hint()
            tip = ("; 线索: %s → 疑似 %s" % (why, g)) if g else ""
            return ("warn", "平台", p + "(**推测**, 未确认) → 平台相关清理暂缓" + tip +
                    "; 确认后运行: sudo pdg platform ios  或  sudo pdg platform android")
        return ("ok", "平台", p)
    return ("warn", "平台", "平台标记缺失/非法 → 当前按 Android 安全回退(非已确认); 运行 sudo pdg 触发迁移落定")

BOT_ENV = "/etc/privdns-gateway/bot.env"


def bot_credentials():
    """Bot 凭据状态: "ready" | "unset" | "partial"。CLI / status / doctor / healthcheck /
    update 校验门统一取这里, 别处不许再各写一份判断。

    token 与 allowed **都空**是合法的"没配 bot" —— 这台机器就是不用 Telegram 管理, pdg-bot
    不运行属于正常禁用态, 不是故障。都配了才要求它必须在跑。只配一半是配置错误(bot 起来了
    也不会响应任何人), 得明确点出来, 而不是含糊地报"服务未运行"。"""
    vals = {}
    try:
        with open(BOT_ENV, encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if ln.startswith("PDG_BOT_TOKEN=") or ln.startswith("PDG_BOT_ALLOWED="):
                    k, _, v = ln.partition("=")
                    vals[k] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    tok = bool(vals.get("PDG_BOT_TOKEN"))
    allowed = bool(vals.get("PDG_BOT_ALLOWED"))
    if tok and allowed:
        return "ready"
    if not tok and not allowed:
        return "unset"
    return "partial"


def expected_services():
    """必需服务集。pdg-probe81 是 Android/iOS **公共**组件(:81 探测 + 链路会话入口),
    两平台都必需。pdg-mitm 由 check_mitm 单独按启用态判定, 不列入必需集。
    未配 bot 凭据时 pdg-bot 不在必需集里 —— 它本来就不该启动。
    CLI/status/report/healthcheck 统一取此。"""
    svc = _core_svc()
    names = ["mosdns", svc, "pdg-probe81"]
    if bot_credentials() == "ready":
        names.append("pdg-bot")
    return names

def check_services():
    names = expected_services()
    bad = [s for s in names if _run(["systemctl", "is-active", s])[1].strip() != "active"]
    return ("fail", "服务", "未运行: " + ", ".join(bad)) if bad \
        else ("ok", "服务", "/".join(names) + " 都在")


def check_bot_credentials():
    """Bot 凭据本身的状态。没配是正常禁用态(info), 配了一半是明确的配置错误(fail)。"""
    st = bot_credentials()
    if st == "ready":
        act = _run(["systemctl", "is-active", "pdg-bot"])[1].strip()
        if act == "active":
            return ("ok", "Bot 凭据", "token + 允许 id 均已配置, pdg-bot 运行中")
        return ("fail", "Bot 凭据", "token + 允许 id 已配置, 但 pdg-bot 未运行(" + (act or "unknown") + ")")
    if st == "partial":
        return ("fail", "Bot 凭据",
                "只配了一项(token 与允许 id 必须成对): pdg-bot 起来了也不会响应任何人。"
                "请用 <code>pdg-set-token</code> 补齐, 或把两项都留空以彻底禁用 bot。")
    return ("info", "Bot 凭据", "未配置(token 与允许 id 都为空)→ pdg-bot 不启动, 属正常禁用态。"
                               "需要用 Telegram 管理时运行 pdg-set-token 配置。")

def check_health_timer():
    """健康自检定时器**排不排得出下一次**。

    jp2 上出过一次: is-enabled=enabled、is-active=active、is-failed 不 failed、
    Result=success —— 常规三态全绿, 而 SubState=elapsed、NextElapse 两项都是空/infinity,
    服务 8 天没跑过, doctor 一路判绿(那时它根本没有这一项)。所以判据不能只看三态,
    必须看**下一次触发时间**。

    只读: 不 restart / enable / reset-failed / daemon-reload —— 自检的职责是如实报告,
    不是替用户按开关; 自动重启还会把问题掩盖掉, 下次照样静默停摆。
    """
    T = "pdg-health.timer"
    NAME = "健康自检定时器"

    def _get(args):
        rc, out, _e = _run(["systemctl"] + args)
        return out.strip() if rc == 0 else None

    en = _get(["is-enabled", T])
    if en is None:
        return ("fail", NAME, "读不到 %s 的启用状态 —— 无法确认健康检查是否还在运行。" % T)
    if en not in ("enabled", "enabled-runtime", "static", "indirect"):
        # 用户显式停用过就不该当故障报; 但"根本没装"要说出来。
        if en in ("disabled", "masked"):
            return ("info", NAME, "已停用(%s)。健康检查不会自动运行。" % en)
        return ("fail", NAME, "启用状态异常: %s" % en)

    act = _get(["is-active", T])
    if act is None:
        return ("fail", NAME, "读不到 %s 的运行状态 —— 无法确认健康检查是否还在运行。" % T)

    # 一次取齐; 任一属性读不出即 fail-closed(读不到 ≠ 没问题)。
    # 解析 KEY=VALUE 而不是按位取 `--value` 的输出: systemd **按它自己的规范顺序**打印,
    # 不是按 -p 传入的顺序。真机上就是这么错位的 —— NextElapseUSecRealtime 排在最前,
    # 于是 ActiveState 拿到了时间串, doctor 把一台好机器判成红的。
    vals = _get(["show", T, "-p", "ActiveState", "-p", "SubState",
                 "-p", "NextElapseUSecMonotonic", "-p", "NextElapseUSecRealtime"])
    if vals is None:
        return ("fail", NAME, "读不到 %s 的 systemd 属性 —— 无法确认下一次运行时间。" % T)
    props = {}
    for line in vals.split("\n"):
        if "=" in line:
            k, _sep, v = line.partition("=")
            props[k.strip()] = v.strip()
    need = ("ActiveState", "SubState",
            "NextElapseUSecMonotonic", "NextElapseUSecRealtime")
    if not all(k in props for k in need):
        return ("fail", NAME,
                "%s 的 systemd 属性不完整(缺 %s)—— 无法确认下一次运行时间。"
                % (T, ", ".join(k for k in need if k not in props)))
    a_state = props["ActiveState"]; sub = props["SubState"]
    nxt_mono = props["NextElapseUSecMonotonic"]; nxt_real = props["NextElapseUSecRealtime"]

    if act != "active" or a_state != "active":
        return ("fail", NAME,
                "定时器已启用却没在运行(%s)。健康检查不会自动运行。"
                % (a_state or act or "unknown"))

    def _finite(v):
        return bool(v) and v not in ("infinity", "n/a")

    has_next = _finite(nxt_mono) or _finite(nxt_real)

    # 正在跑的那一瞬: 下一次还没重新算出来, 不能据此报故障。
    if sub in ("running", "elapsed-running") or not sub:
        if sub == "running":
            return ("ok", NAME, "健康检查正在运行。")

    if sub == "elapsed" or not has_next:
        return ("fail", NAME,
                "健康检查定时器没有安排下一次运行。它看上去是启用且在运行的, 但不会再触发 —— "
                "服务异常时你不会收到通知。跑 <code>sudo pdg __migrate</code> 让它重新排程。")

    # 具体的绝对时间只进诊断日志: 机器是 UTC 而人按本地时区读, 摆出来容易看错四五个小时。
    sys.stderr.write("health-timer: sub=%s next_mono=%s next_real=%s\n"
                     % (sub, nxt_mono, nxt_real))
    return ("ok", NAME, "已排定下一次运行。")


def check_core_version():
    _, out, _ = _run(["mihomo", "-v"])
    m = re.search(r"v?(\d+\.\d+\.\d+)", out or "")
    return ("ok", "mihomo 版本", "v" + m.group(1) + " ✓(版本随项目发布更新)") if m \
        else ("warn", "mihomo 版本", "读不到版本")

def check_dot_arecord():
    d = _dot_domain(); sip = _server_ip()
    if not d or not sip:
        return ("warn", "DoT A 记录", "域名或本机 IP 读不到")
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@1.1.1.1", d, "A"])
    ips = [x for x in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
    if sip in ips:
        return ("ok", "DoT A 记录", f"{d} → {sip} ✓")
    if not ips:
        return ("warn", "DoT A 记录", f"{d} 解析不到 A 记录")
    return ("fail", "DoT A 记录", f"{d} → {ips[0]}, 不是本机 {sip}")

def check_dot_domain_sync():
    """dot-domain 文件(续期 deploy-hook 据它选证书)应与证书 CN 一致, 否则续期会部署错证书、DoT 失配。"""
    cn = _cert_cn(); f = _dot_file()
    if not cn or not f:
        return ("ok", "DoT 域名一致性", "无需检查")
    if f != cn:
        return ("warn", "DoT 域名一致性",
                f"dot-domain={f} 与证书 CN={cn} 不一致; 续期可能部署错证书。建议: echo {cn} > {DOT_DOMAIN_FILE}")
    return ("ok", "DoT 域名一致性", f"{cn} ✓")

# 续期钩子写证书的目录: profile.env 的 PDG_CERT_DIR, 缺省与 deploy/cert/99-reload-cert.deploy-hook.sh
# 里的 `CERT_DIR="${PDG_CERT_DIR:-/etc/mosdns/certs}"` 保持同一个字面量。两处改一处忘一处,
# 这道门就会从"防线"变成"误报", 所以它们必须一起改。
HOOK_CERT_DIR_DEFAULT = "/etc/mosdns/certs"

def check_cert_dir_sync():
    """续期钩子写证书的目录, 必须就是 mosdns 实际读证书的目录。

    为什么单独立一道门: 现有的 check_cert 只问"mosdns 配的那个文件在不在、过没过期" ——
    两个问题它都答得出"在、没过期", 因为旧证书**确实**在原地躺着。它答不出的是"下次续期
    的新证书会不会落到这里"。于是路径一错, 整条链路全绿:certbot 续期成功、钩子退 0、
    doctor 26 项无一异常, 而 mosdns 从头到尾抱着那张不再更新的旧证书, 直到到期当天 DoT
    对全部手机静默失效 —— 那天没有任何一个组件会说自己出了错。

    .153 上就是这样: mosdns 读 /etc/dnsdist/certs(dnsdist 时代留下的路径), 钩子写
    /etc/mosdns/certs, 中间靠一个名叫 99-reload-dnsdist.sh 的老钩子兜着。而那个钩子
    看名字就该跟 dnsdist 一起清掉 —— 清掉的那一刻, 到期日就成了停服日。
    """
    m = re.search(r'cert:\s*"([^"]+)"', _mos())
    if not m:
        return ("ok", "证书路径一致性", "mosdns 未配 DoT 证书, 无需检查")
    # realpath: 软链与结尾斜杠都归一, 否则 /etc/mosdns/certs 与 /etc/mosdns/certs/ 会被判成两处。
    mos_dir = os.path.realpath(os.path.dirname(m.group(1)))
    hook_dir = os.path.realpath(_profile("PDG_CERT_DIR") or HOOK_CERT_DIR_DEFAULT)
    if mos_dir != hook_dir:
        return ("fail", "证书路径一致性",
                f"mosdns 读 {mos_dir}, 续期钩子写 {hook_dir} —— 续期不会更新 mosdns 在用的证书, "
                f"到期当天 DoT 会静默失效(在那之前一切正常)。二选一: 把证书迁到 {hook_dir} "
                f"并同步改 mosdns config 的 cert/key; 或在 profile.env 写 PDG_CERT_DIR={mos_dir}")
    return ("ok", "证书路径一致性", f"{mos_dir} ✓")

def check_internal_cidr():
    c = _internal_cidr()
    if not c:
        return ("fail", "内网卡段", "未配置(npn_clients 空)")
    try:
        net = ipaddress.ip_network(c, strict=False)
    except Exception:  # noqa: BLE001
        return ("fail", "内网卡段", f"{c} 不是合法 CIDR")
    if net.prefixlen == 0:
        return ("fail", "内网卡段", f"{c} 等于全网, 会劫持所有来源!")
    cgnat = ipaddress.ip_network("100.64.0.0/10")   # 运营商 CGNAT(RFC 6598), py<3.13 的 is_private 不含它
    if not (net.is_private or net.subnet_of(cgnat) or net == cgnat):
        return ("fail", "内网卡段", f"{c} 是公网段, 危险")
    if net.prefixlen < 12:
        return ("warn", "内网卡段", f"{c} 偏宽(/{net.prefixlen}), 建议收到内网卡精确 /16")
    return ("ok", "内网卡段", c)

def check_cidr_drift():
    """内网卡段的四方一致性: profile.env(真源) / nft / mosdns / 本机网卡。

    为什么要单独查: 这四处必须同时改, 少改一处的表现各不相同但都难查 ——
      · nft 落后 → 手机来源不被放行, DNS 直接不通;
      · mosdns 落后 → 查询进得来却不被判成"内网客户端", 分流与劫持全失效;
      · profile.env 落后 → 救援服务绑到一个已经不存在的地址上, 出事时才发现进不去;
      · 网卡实际地址不在段内 → 段本身写错了, 上面三处一致也没用。
    只**报告**, 不代为修改: 改它要写 nft+mosdns 并重启, 那是 `pdg detect-cidr` 的事。"""
    src = _profile("PDG_INTERNAL_CIDR")
    nftv = _cidr_from_nft()
    mosv = _cidr_from_mosdns()
    if not src:
        if nftv or mosv:
            return ("warn", "内网卡段一致性",
                    "profile.env 里没有 PDG_INTERNAL_CIDR(老装尚未迁移)。当前实际生效: "
                    "nft=%s / mosdns=%s。请运行 <code>sudo pdg migrate</code> 写入真源。"
                    % (nftv or "读不到", mosv or "读不到"))
        return ("warn", "内网卡段一致性", "profile.env 与 nft/mosdns 都读不到内网卡段")
    diff = []
    if nftv and nftv != src:
        diff.append("nft=%s" % nftv)
    if mosv and mosv != src:
        diff.append("mosdns=%s" % mosv)
    if diff:
        return ("fail", "内网卡段一致性",
                "profile.env 记的是 %s, 但 %s —— 三处必须一致, 否则放行/分流/救援入口会各说各话。"
                "请运行 <code>sudo pdg detect-cidr</code> 重新统一。" % (src, "、".join(diff)))
    # 四方的最后一方: 本机是否真有一个落在这个段里的地址。没有不一定是错(手机不在线时该段
    # 可能只在对端出现), 所以只提示, 不判失败。
    try:
        net = ipaddress.ip_network(src, strict=False)
    except Exception:  # noqa: BLE001
        return ("fail", "内网卡段一致性", "%s 不是合法 CIDR" % src)
    _, addrs, _ = _run(["ip", "-4", "-o", "addr"])
    local = [ipaddress.ip_address(a) for a in re.findall(r"inet ([0-9.]+)/", addrs or "")]
    if local and not any(a in net for a in local):
        return ("ok", "内网卡段一致性",
                "%s(三处一致; 本机网卡地址不在该段内 —— 内网卡为对端下发时属正常)" % src)
    return ("ok", "内网卡段一致性", "%s(profile.env / nft / mosdns 三处一致)" % src)


def platform_ports_text():
    """按当前平台列出应放行的端口。写死一串会在 iOS 上声称 GMS 5228-5230 已就位
    (iOS 走 APNs, 装机就把它剥掉了)。81 两平台都列 —— pdg-probe81 已是公共组件,
    nft 模板里 81 本来也只有一份、对 __INTERNAL_CIDR__ 放行, 无平台分叉。

    端口从 nftlive 的常量推出来, doctor 这边不另存一份: 判据用一份端口表、展示用另一份,
    迟早会出现"报告说 8445 已放行、判据根本没查它"这种两头对不上的事。"""
    import nftlive
    ios = _platform() == "ios"
    ports = set(nftlive.REQUIRED_INTERNAL_TCP) | set(nftlive.REDIRECT_TCP) \
        | set(nftlive.DOCTOR_ONLY_INTERNAL_TCP)
    out = [str(p) for p in sorted(ports)]
    if not ios:
        lo, hi = min(nftlive.GMS_TCP), max(nftlive.GMS_TCP)
        out.append("%d-%d(仅 Android)" % (lo, hi))
    return "/".join(out)


# ── 防火墙判定: 整轮 doctor 只做一次, 由 nftlive 统一判 ─────────────────────
# 以前这里有三份各自为政的解析: check_nft 自己 grep `dport {…}` 找敏感端口、check_redirect
# 自己找 `redirect to :7893`、check_gms 自己找含 5228 的行 —— 三份都是文本近似, 各自的口径
# 还不一样(check_nft 只看"有没有对全网开放", 规则整条消失反而更"干净")。同一时期 linkstat
# 又有第四份, 结论与 doctor 相反, `.153` 上一台健康机器被它挡住做不了链路测试。
#
# 现在只有一份: nftlive 按 `nft -j` 的表达式做语义判断。doctor 这边读一次真源(内网卡段、
# 平台、mihomo 的 redir 口、nft 配置路径与二进制), 显式传进去, 判一次, 三个检查项各取
# 自己那一档 —— 同一个根因只会出现在一个检查项里。
_NFT_VIEW = None


class _NftView(object):
    """一轮 doctor 内共享的防火墙判定。calls 记录这轮实际发出的 nft 命令(供测试点数)。"""

    def __init__(self, disk_ok, disk_why, audit, kern_why, calls):
        self.disk_ok, self.disk_why = disk_ok, disk_why
        self.audit, self.kern_why, self.calls = audit, kern_why, calls


def _nft_view_reset():
    """每轮 doctor 开始时清空 —— Bot 是长驻进程, 缓存跨轮复用等于拿旧状态糊弄用户。"""
    global _NFT_VIEW
    _NFT_VIEW = None


def _nft_view():
    global _NFT_VIEW
    if _NFT_VIEW is not None:
        return _NFT_VIEW
    import nftlive
    calls = []

    def _runner(cmd):
        calls.append(list(cmd))
        return _run(cmd, 15)

    disk_ok, disk_why = nftlive.check_disk_config(path=NFT_CONF, runner=_runner)
    audit, kern_why = None, ""
    if disk_ok:
        obj, kern_why = nftlive.read_kernel(runner=_runner)
        if obj is not None:
            audit = nftlive.audit_kernel(
                obj, cidr=_internal_cidr(), platform=_platform(),
                redir_port=_mihomo_redir_port())
    _NFT_VIEW = _NftView(disk_ok, disk_why, audit, kern_why, calls)
    return _NFT_VIEW


def check_nft():
    """input 链本身: 表/链结构、必需放行、来源限定、顺序, 外加 doctor 专项端口(8445)。

    prerouting 的 80/443 归 check_redirect、GMS 归 check_gms —— 判定是同一份, 只是各报各的。
    """
    v = _nft_view()
    if not v.disk_ok:
        return ("fail", "防火墙", "磁盘上的防火墙配置无效: %s" % v.disk_why)
    if v.audit is None:
        # 读不到内核 = 不知道现在到底放行了什么。这里必须 fail-closed: 上一版返回
        # warn "读不到 nftables", 于是"防火墙被整个卸了"和"一切正常"在报告里同色。
        return ("fail", "防火墙", "读不到内核里的防火墙规则(%s) —— 无法确认放行是否生效"
                % (v.kern_why or "原因未知"))
    core = v.audit.of_kind("table", "missing", "source", "order", "verdict", "leak")
    if core:
        return ("fail", "防火墙", "; ".join(core))
    extra = v.audit.of_kind("socks")
    if extra:
        # 专项功能: 报出来, 但不是核心链路故障 —— 它不该让"手机能不能上网"这件事变红。
        return ("warn", "防火墙", "; ".join(extra) + "(不影响手机基础链路)")
    return ("ok", "防火墙", platform_ports_text() + " 仅限内网卡来源")


TS_IFACE = "tailscale0"


RESCUE_MARK = "pdg-rescue"


def _rule_has_rescue_mark(rule):
    """这条规则是不是救援平面注入的(带 comment "pdg-rescue")。

    nft JSON 里 comment 既可能挂在规则上, 也可能作为表达式出现, 两处都认。
    """
    if rule.get("comment") == RESCUE_MARK:
        return True
    for e in rule.get("expr", []) or []:
        if isinstance(e, dict) and e.get("comment") == RESCUE_MARK:
            return True
    return False


def _ts_isolation_scan(obj):
    """在内核 nft JSON 里找每条链的「tailscale0 排除规则」与「首个来源匹配」的位置。

    返回 {链名: (排除规则序号, 首个 saddr 规则序号)}, 找不到的用 None。
    序号按该链内的规则出现顺序, 顺序本身就是判据 —— 先匹配再排除等于没排除。
    """
    pos = {}
    idx = {}
    for item in (obj or {}).get("nftables", []):
        r = item.get("rule")
        if not r or r.get("table") != "pdg":
            continue
        ch = r.get("chain")
        i = idx[ch] = idx.get(ch, -1) + 1
        # 救援平面的放行不算"数据面来源匹配"。它按设计插在 input 链首(见 rescue_nft.py),
        # 带 `ip saddr` 但也带具体 `ip daddr` —— 是对单个绑定地址的点状放行, 不是把一整个
        # 网段接管进 SIM/APN 数据面。把它当成来源匹配, 结论就成了"排除规则排在来源匹配
        # 之后", 于是**任何启用过救援的机器一升级就判红** —— 实测 e2e-rescue-migration-lock
        # 正是这么红的, 而规则本身一条不少、顺序也没问题。
        #
        # 认标记, 不认端口或地址: 用户完全可能自己写过同端口的放行, 而标记是我们自己注入的
        # 凭证(rescue_nft.MARK), 也是别处精确撤销时用的同一个依据。
        if _rule_has_rescue_mark(r):
            continue
        ex, src = pos.get(ch, (None, None))
        for e in r.get("expr", []):
            m = e.get("match") or {}
            left = m.get("left") or {}
            if left.get("meta", {}).get("key") == "iifname" and m.get("right") == TS_IFACE:
                if ex is None:
                    ex = i
            p = left.get("payload") or {}
            if p.get("protocol") == "ip" and p.get("field") == "saddr":
                if src is None:
                    src = i
        pos[ch] = (ex, src)
    return pos


def check_tailscale_isolation():
    """Tailscale 入口隔离: 从 tailscale0 进来的流量不得进入 SIM/APN 数据面。

    为什么单独一项: Tailscale 节点地址来自 100.64.0.0/10, 而运营商 SIM/APN 也合法用
    同一个段(RFC 6598) —— **只看源地址分不开这两者**。所以判据不能是"看见 CGNAT 段就
    报错"(那会误伤真实运营商用户, 也是本项目明确不接受的做法), 而必须是"排除规则在不在、
    排得对不对"。

    这一项与 Tailscale 装没装无关: 规则来自模板, 任何时候都该在。没装 Tailscale 时
    iifname 只是永不命中, 不会因此产生告警 —— 否则每台没用 Tailscale 的机器都会平白多一条红。
    """
    v = _nft_view()
    if not v.disk_ok:
        return ("fail", "Tailscale 入口隔离", "磁盘上的防火墙配置无效: %s" % v.disk_why)
    import nftlive
    obj, why = nftlive.read_kernel(runner=lambda cmd: _run(cmd, 15))
    if obj is None:
        return ("fail", "Tailscale 入口隔离",
                "读不到内核里的防火墙规则(%s) —— 无法确认隔离是否生效" % (why or "原因未知"))
    pos = _ts_isolation_scan(obj)
    if not pos:
        return ("fail", "Tailscale 入口隔离", "内核里没有 inet pdg 的规则")
    bad = []
    for ch in ("prerouting", "input"):
        if ch not in pos:
            bad.append("%s 链不存在" % ch)
            continue
        ex, src = pos[ch]
        if ex is None:
            bad.append("%s 缺少 iifname %s 的排除规则" % (ch, TS_IFACE))
        elif src is not None and ex > src:
            bad.append("%s 的排除规则排在来源匹配之后(第 %d 条 > 第 %d 条)" % (ch, ex, src))
    if bad:
        return ("fail", "Tailscale 入口隔离",
                "; ".join(bad) + " —— tailnet 流量可能被当成内网卡来源接管")
    return ("ok", "Tailscale 入口隔离", "prerouting/input 均在来源匹配前排除 %s" % TS_IFACE)


# 三个探测点列成常量: 测试可以指到临时文件, 免得为了造"src_valid_mark=1 且没有
# tailscale0"这种现场去 patch open() 之类的底层函数 —— 那种打桩一旦写错, 测的就不是
# 产品了。同样的写法见 nftscan.NFT_CANDIDATES。
PROC_NET_DEV = "/proc/net/dev"
SRC_VALID_MARK = "/proc/sys/net/ipv4/conf/all/src_valid_mark"
TAILSCALE_BIN = "/usr/bin/tailscale"
# 包还装着的第二个凭据。Debian 12 上 tailscale 这个 deb 会放下 unit 文件, 它跟接口在不在
# 完全无关 —— `tailscale down` 或 tailscaled 停着的时候, 它照样在。
TAILSCALED_UNIT = "/lib/systemd/system/tailscaled.service"
# Debian 12 的 tailscale 包把监听端口放在这里, unit 经 EnvironmentFile 传给
# `tailscaled --port=${PORT}`。项目里 41641 是硬编码常量, 靠这份文件对账。
TAILSCALED_DEFAULTS = "/etc/default/tailscaled"
TAILNET_DIRECT_COMMENT = "pdg-tailnet-direct"


def _tailscale_installed():
    """Tailscale 这个**包**还在不在 —— 与它此刻通没通没关系。

    返回 (installed, why)。两个凭据, 命中一个就算装着:
      · dpkg 认领 /usr/bin/tailscale —— 那它就是包的文件, 谁都不许建议删;
      · tailscaled 的 unit 文件还在 —— deb 放下的, 卸载才会消失。

    刻意**不**看 tailscale0 接口, 也不看 tailscaled 跑没跑: 那两样回答的是"此刻通不通",
    不是"装没装"。把它们当成安装判据, 正是这一项原先误诊的根子。
    """
    rc, out, _err = _run(["dpkg-query", "-S", TAILSCALE_BIN])
    if rc == 0 and TAILSCALE_BIN in out:
        return True, "dpkg 认领了 %s(%s)" % (TAILSCALE_BIN, out.strip().split(":")[0])
    if os.path.exists(TAILSCALED_UNIT):
        return True, "%s 还在" % TAILSCALED_UNIT
    return False, ""


def check_tailscale_residue():
    """Tailscale 卸下之后留在系统里的东西。

    两样都是 Tailscale 自己的行为, 不是本项目造成的 —— 但**只有本项目的 doctor 会去看**,
    不报就没人会发现:

    1. `net.ipv4.conf.all.src_valid_mark` 被它从 0 改成 1, 而且**不落 /etc/sysctl.d** ——
       `tailscale logout` + `apt purge` 之后仍是 1, 要等重启才恢复。它放宽的是反向路径
       过滤(rp_filter)对带 fwmark 的包的校验; 留着不至于立刻出事, 但那是一台机器上
       没人知道为什么被改过的内核参数, 而且**重启后又会自己变回去** —— 于是"重启前后
       行为不一致"这种最难查的现象就有了来源。
    2. `apt purge` 之后 `/usr/bin/tailscale` 仍然留着(dpkg 查不到归属)。它不再工作,
       但 `command -v tailscale` 照样能找到 —— 任何按"命令在不在"判断的脚本都会被骗。

    两条都**只在真的卸载之后**才成立, 所以"卸没卸"这个前提必须站得住。原先它取的是
    tailscale0 接口在不在, 那是错的: 接口不在的原因还有 `tailscale down`、tailscaled
    临时停、以及装好了从没 `tailscale up` 过。那三种情形下 src_valid_mark=1 本来就正常,
    /usr/bin/tailscale 也是包自己的文件 —— 照原判据会建议 `rm -f` 掉一个 dpkg 拥有的
    文件, 把包弄成破损状态, 而且要到下次 apt 操作才看得出来。
    见 tests/negctl/tailscale-residue-misdiagnosis.py。

    所以现在分两步: 先看**包**还在不在(_tailscale_installed, 看 dpkg 与 unit 文件),
    装着就整项不适用; 确认卸了, 才谈得上残留。
    """
    name = "Tailscale 卸载残留"
    try:
        with open(PROC_NET_DEV, encoding="utf-8") as f:
            has_if = any(l.strip().startswith("tailscale0:") for l in f)
    except OSError:
        return ("warn", name, "读不到 %s, 无法判断 tailscale0 是否还在, 本项无结论" % PROC_NET_DEV)
    if has_if:
        return ("ok", name, "tailscale0 仍在, 不适用(装着的时候这些都是正常状态)")
    installed, why = _tailscale_installed()
    if installed:
        # 接口不在但包还在 —— 这是 down / 停服 / 从没 up 过, 不是残留。
        return ("ok", name,
                "没有 tailscale0, 但 Tailscale 还装着(%s) —— 这是 `tailscale down`、"
                "tailscaled 停着或还没 `tailscale up`, 不是卸载残留, 本项不适用。" % why)
    bad = []
    try:
        with open(SRC_VALID_MARK, encoding="utf-8") as f:
            if f.read().strip() == "1":
                bad.append("net.ipv4.conf.all.src_valid_mark 仍是 1(Tailscale 改的, 它不会自己还原; "
                           "重启会变回 0 —— 于是重启前后行为不一致)。"
                           "确认不再用 Tailscale 就: sysctl -w net.ipv4.conf.all.src_valid_mark=0")
    except OSError:
        pass                      # 内核没这个参数(旧内核/容器)—— 不是问题, 不报
    if os.path.exists(TAILSCALE_BIN):
        # 走到这里 dpkg 已经明确不认领它了, 删它不会弄破任何包。
        bad.append("%s 仍在(apt purge 之后的残留, dpkg 查不到归属) —— " % TAILSCALE_BIN +
                   "`command -v tailscale` 还能找到它, 按命令是否存在做判断的脚本会被骗。"
                   "确认不用了就: rm -f /usr/bin/tailscale")
    if bad:
        return ("warn", name, "; ".join(bad))
    return ("ok", name, "没有 tailscale0, 也没有留下 src_valid_mark / 残留二进制")


def check_tailnet_direct_port():
    """放行的 UDP 端口与 tailscaled 实际监听的端口是否还对得上。

    `pdg ssh-source tailnet` 会插一条 `udp dport 41641 accept comment "pdg-tailnet-direct"`。
    41641 是官方默认值, 但**它是可配的** —— Debian 12 上来自 /etc/default/tailscaled 的
    `PORT=`。项目里那个数字是硬编码常量, 从不读那份文件。

    用户改了 PORT 之后, 这条放行**静默地双向失效**:
      · 41641 那条没有监听者, 成了一个永远不会有人应答的陈旧洞;
      · 真正的端口被 input 链的 policy drop 挡住。
    于是 `pdg ssh-source` 当初要消除的冷启动窗口原样回来 —— 几小时没用 tailnet, 出事了
    想连进去, 第一次 SSH 必超时。而从配置上完全看不出两者有关系。

    判据只做**两份配置的对账**, 不发探测包: 端口通不通要发包才知道, 而"探不到"证明不了
    任何事(同 check_deep_lan_acl 那条教训)。读文件是确定的。

    读不到 /etc/default/tailscaled 就**无结论** —— 那可能是没装 Tailscale、或者不是 deb
    装的。不猜, 也绝不判 fail: fail 会让 `pdg update` 的自检门整次回滚。
    """
    name = "Tailscale 直连端口对账"
    try:
        with open(NFT_CONF, encoding="utf-8") as f:
            nft = f.read()
    except OSError:
        return None                       # 读不到防火墙配置, 别的判据会报, 这里不重复
    m = re.search(r"udp\s+dport\s+(\d+)\s+accept\s+comment\s+\"%s\""
                  % TAILNET_DIRECT_COMMENT, nft)
    if not m:
        return None                       # SSH 没收紧为 tailnet, 整项不适用
    allowed = int(m.group(1))
    try:
        with open(TAILSCALED_DEFAULTS, encoding="utf-8") as f:
            txt = f.read()
    except OSError:
        return ("ok", name,
                "放行了 UDP %d; 读不到 %s, 没法跟 tailscaled 的实际端口对账(没装 Tailscale "
                "或不是 deb 装的?), 本项无结论。" % (allowed, TAILSCALED_DEFAULTS))
    pm = re.search(r"^\s*PORT\s*=\s*[\"']?(\d+)[\"']?", txt, re.M)
    if not pm:
        return ("ok", name,
                "放行了 UDP %d; %s 里没有 PORT= 这一行, 无从对账。"
                % (allowed, TAILSCALED_DEFAULTS))
    actual = int(pm.group(1))
    if actual == allowed:
        return ("ok", name, "放行的 UDP %d 与 tailscaled 的监听端口一致。" % allowed)
    return ("warn", name,
            "防火墙放行的是 UDP %d, 但 %s 里写的是 PORT=%d —— 两边对不上。"
            "于是 %d 那条成了没有监听者的陈旧放行, 而真正在用的 %d 被 input 链丢掉。"
            "后果是 `pdg ssh-source tailnet` 本来要消除的冷启动窗口又回来了: 空闲一段之后"
            "第一次 SSH 会超时。要么把 PORT 改回 %d, 要么跑一次 `pdg ssh-source tailnet` "
            "让放行跟上(它目前只认 %d, 改端口的话需要手工调 /etc/nftables.conf 里那一行)。"
            % (allowed, TAILSCALED_DEFAULTS, actual, allowed, actual, allowed, allowed))


def _filesha(path):
    """文件 SHA256(读不到返回空串)。用于比对部署文件与仓库文件是否同一版本。"""
    import hashlib
    try:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return ""


def _mihomo_redir_port():
    """mihomo 的 redir-port(装机固定 7893; 读不到按它兜底)。"""
    try:
        txt = open(MIHOMO_CFG, encoding="utf-8").read()
    except OSError:
        return 7893
    m = re.search(r'["\']?redir-port["\']?\s*:\s*(\d+)', txt)
    return int(m.group(1)) if m else 7893


def check_redirect():
    """mihomo 模式: 内网卡来源的 80/443 必须 REDIRECT 到 mihomo 的 redir 口, 否则代理链路是断的。

    专门补的一项: 这条规则曾被 iOS GMS 清理迁移整行删掉, 而 doctor 一路全绿 —— 防火墙那项
    只查"敏感端口有没有对全网开放", 规则整条消失反而更"干净", 于是线上代理断了好几天没人发现。

    判据来自与 check_nft / linkstat 同一份 nftlive 判定(kind="redirect"), 这里不再自己
    grep `redirect to :7893` —— 那份文本近似认不出 `redirect to :7893` 与 nft 规范化后的
    其它写法, 也认不出"改写目标是个没人监听的端口"。"""
    port = _mihomo_redir_port()
    v = _nft_view()
    if not v.disk_ok or v.audit is None:
        # 读不到就说读不到, 不猜。核心故障由 check_nft 报, 这里不重复。
        return ("warn", "代理入口", "读不到 nftables, 无法确认 80/443 是否 REDIRECT 到 mihomo。")
    if "prerouting" not in v.audit.evaluated:
        # 表/链没到能查 prerouting 的地步 —— 那是 check_nft 的根因, 这里只说没结论。
        bad = v.audit.of_kind("redirect")
        if bad:
            return ("fail", "代理入口", "; ".join(bad))
        return ("warn", "代理入口", "读不到 prerouting 链, 无法确认 80/443 是否 REDIRECT。")
    bad = v.audit.of_kind("redirect")
    if bad:
        return ("fail", "代理入口",
                "; ".join(bad) + " —— 代理链路不通(规则可能被误删)。"
                "修复: nft add rule inet pdg prerouting ip saddr <内网段> tcp dport "
                "{ 80, 443 } redirect to :%d, 并写回 %s。" % (port, NFT_CONF))
    return ("ok", "代理入口", "内网卡 80/443 已 REDIRECT → mihomo :%d" % port)


def check_gms():
    """GMS/FCM 推送端口(5228-5230)是否完整启用。只读、不触发迁移: 老装第一次 pdg update
    跑在旧脚本里, 迁移要等下一次 root 管理类命令; 没落地前用 warn 提示(不 fail, 自定义防火墙用户合法缺席)。"""
    if _platform() == "ios":
        # iOS 走 APNs, 不用 GMS。正常应无残留; 若 sing-box model 仍有 in-gms 或 nft 端口集含 5228 → warn
        # (应由 migrate_ios_gms_cleanup 清掉; 自定义防火墙形态清不掉时在此提示)。无残留 → None(不显示)。
        residue = []
        try:
            if '"in-gms-5228"' in open(SB).read():
                residue.append("sing-box 入站")
        except OSError:
            pass
        _, nft, _ = _run(["nft", "list", "ruleset"])
        if not nft:
            try:
                nft = open("/etc/nftables.conf").read()
            except OSError:
                nft = ""
        if re.search(r"tcp dport \{[^}]*5228", nft):
            residue.append("nft 端口集")
        if residue:
            return ("warn", "GMS 残留", "iOS 不应有 GMS 5228-5230, 检出于 " + "、".join(residue)
                    + "; 运行 sudo pdg __migrate 清理(自定义防火墙形态需手动移除)。")
        return None
    # mihomo(唯一内核): 5228-5230 由 nft prerouting REDIRECT 到 redir 端口 + sniffer 处理,
    # 不在 input accept。判据同样取自共享判定的 kind="gms" 那一档 —— 它在 nftlive 里被归为
    # **doctor 专项**: 缺了要报, 但不参与 audit.ok, 因而不会挡住手机的基础 HTTP 链路测试
    # (那次测试只证明"HTTP 请求到没到达网关", 从不声称 Google Play 推送正常)。
    v = _nft_view()
    if not v.disk_ok or v.audit is None or "gms" not in v.audit.evaluated:
        return ("warn", "GMS 推送", "读不到 nft prerouting 链, 无法确认 5228-5230 是否已 REDIRECT。")
    bad = v.audit.of_kind("gms")
    if bad:
        return ("warn", "GMS 推送", "; ".join(bad) + " —— 检查防火墙模板是否生效"
                "(不影响手机基础链路)。")
    return ("ok", "GMS 推送", "GMS/FCM 5228-5230 已启用(nft REDIRECT→mihomo 嗅探)")

def _internal_seq_block(conf):
    """截取 mosdns config 里 internal_sequence 一段文本 (到下一个顶层 '  - tag:' 为止)。"""
    lines = conf.splitlines()
    out, grab = [], False
    for ln in lines:
        if ln.startswith("  - tag: internal_sequence"):
            grab = True; out.append(ln); continue
        if grab and ln.startswith("  - tag: "):
            break
        if grab:
            out.append(ln)
    return "\n".join(out)

_RL_WARN = ("warn", "限流", "mosdns 单客户端 QPS 兜底(rate_limiter)缺失或参数/动作异常; "
                            "运行 sudo pdg restart 或 sudo pdg 触发迁移。高度自定义配置请手动在 "
                            "internal_sequence 缓存前加 client_limiter(qps200/burst400/mask4-32/mask6-128)+ "
                            "'!$client_limiter → reject 5'。")
_RL_WANT = {"qps": "200", "burst": "400", "mask4": "32", "mask6": "128"}

def check_mosdns_ratelimit():
    """单客户端 QPS 兜底(rate_limiter)是否就位且参数/动作正确:
    插件 client_limiter 是 rate_limiter 且 qps200/burst400/mask4-32/mask6-128;
    internal_sequence 缓存查询之前 '!$client_limiter' 的动作确为 reject 5。
    只读; 任一不符 → warn(不 fail, 老装未迁移或高度自定义配置属合法缺席)。"""
    conf = _mos()
    if not conf:
        return ("warn", "限流", "读不到 mosdns 配置")
    # 1) 精确解析插件块参数(client_limiter / type: rate_limiter / args {...})
    m = re.search(r"-\s*tag:\s*client_limiter\s*\n\s*type:\s*rate_limiter\s*\n\s*args:\s*\{([^}]*)\}", conf)
    if not m:
        return _RL_WARN
    args = m.group(1)
    for k, v in _RL_WANT.items():
        mm = re.search(r"\b" + k + r"\s*:\s*(\d+)", args)
        if not mm or mm.group(1) != v:
            return _RL_WARN
    # 2) 缓存查询之前必须有一条 '!$client_limiter → reject 5'。
    #    关键: 匹配到的 reject 5 步骤本身要在缓存之前 —— 否则"缓存前动作错(如 accept)+ 缓存后另有正确 reject 5"
    #    会被误判为 ok。故用 step.start() < i_cache 校验, 而非只看首个 !$client_limiter 的位置。
    blk = _internal_seq_block(conf)
    i_cache = blk.find("$lazy_cache")
    step = re.search(r'matches:\s*"?!\$client_limiter"?[ \t]*(?:#[^\n]*)?\n\s*exec:\s*reject\s+5\b', blk)
    if not step or (i_cache >= 0 and step.start() >= i_cache):
        return _RL_WARN
    return ("ok", "限流", "单客户端 QPS 兜底已就位(rate_limiter qps200/burst400, reject 5, 缓存前)")

# ── 明确代理优先级(点名的出口域名必须先于 geosite_cn 判断)────────────────────
_EP_FILES = ("/etc/mosdns/rules/custom_hijack.txt", "/etc/mosdns/rules/ruleset_hijack.txt")

def check_mosdns_explicit_proxy():
    """bot 里**点名**指到某个出口的域名(custom_hijack.txt)、以及启用规则集所需的劫持域名
    (ruleset_hijack.txt), 在 internal_sequence 里必须排在 geosite_cn **之前**。

    为什么单独检: 排在后面时 doctor 的其他项全绿 —— 内核里那条出口规则确实存在, mosdns 也在
    跑, 只是上游 geosite 一旦把域名归进 CN, DNS 就先返真实地址, 流量根本不进 mihomo, 那条
    规则永远匹配不到。除了显式比一次顺序, 没有别的地方看得出来。

    缺插件 → warn 并**点名这台机器的配置未迁移**(老装未更新, 或自定义形态被迁移 fail-closed
    地拒绝了 —— 两种都属合法缺席, 不 fail); 插件在但顺序反了 → fail(本项目的渲染/迁移都不会
    产出这种配置, 出现即为真故障)。只读。"""
    conf = _mos()
    if not conf:
        return ("warn", "指定域名优先级", "读不到 mosdns 配置")
    blk = _internal_seq_block(conf)
    gi = blk.find("qname $explicit_proxy")
    ci = blk.find("qname $geosite_cn")
    has_set = re.search(r"-\s*tag:\s*explicit_proxy\s*\n\s*type:\s*domain_set", conf)
    has_seq = re.search(r"-\s*tag:\s*explicit_proxy_seq\s*\n\s*type:\s*sequence", conf)
    if not has_set or not has_seq or gi < 0:
        return ("warn", "指定域名优先级",
                "这台机器的 /etc/mosdns/config.yaml **未迁移**(缺 explicit_proxy 域名集/序列/判断)"
                ": bot 里用户指定要走出口的域名, 一旦被上游 geosite 归进 CN 就会返真实地址、不进 "
                "mihomo, 内核里那条出口规则不会生效。跑 sudo pdg update 触发迁移; 若因配置是"
                "自定义形态而被拒绝(不猜着改), 需手动在 internal_sequence 的 geosite_cn 判断"
                "**之前**加 'qname $explicit_proxy → goto explicit_proxy_seq'。")
    if ci >= 0 and gi > ci:
        return ("fail", "指定域名优先级",
                "explicit_proxy 判断排在 geosite_cn **之后** —— 用户指定要走出口的域名会被判直连, "
                "内核规则形同虚设。把该判断移到 geosite_cn 之前。")
    missing = [f for f in _EP_FILES if f not in conf]
    if missing:
        return ("warn", "指定域名优先级",
                "explicit_proxy 域名集缺文件: " + ", ".join(missing))
    return ("ok", "指定域名优先级",
            "用户指定的域名规则先于 geosite_cn 判断(custom_hijack + ruleset_hijack)")


PROFILE_ENV = "/etc/privdns-gateway/profile.env"

def check_ruleset_hijack():
    """规则集派生的劫持表是否与启用中的规则集同步。

    规则集只写 mihomo 那一侧; 流量能不能到 mihomo 由 mosdns 决定。all 模式下"不是国内就
    劫持"顺带兜住了, gfw 模式下就露馅: 规则集里的域名拿到真实 IP、手机直连, 那条 RULE-SET
    规则永远匹配不到 —— 规则在、UI 说成功、其它检查全绿, 就是不生效。

    只读: 按当前 rulesets.json 重算一遍, 与磁盘上的文件比。不一致 → gfw 模式判 warn
    (all 模式只提示: 那边不影响命中)。.mrs 派生不了, 单独点名。"""
    import json as _json
    meta_path = "/opt/pdg-bot/rulesets.json"
    f = "/etc/mosdns/rules/ruleset_hijack.txt"
    try:
        with open(meta_path, encoding="utf-8") as fh:
            meta = _json.load(fh)
    except Exception:  # noqa: BLE001
        return None                      # 没有规则集 → 这项不适用, 不显示
    if not meta:
        return None
    mode = (_profile("PDG_HIJACK_MODE") or "all").strip() or "all"
    try:
        sys.path.insert(0, "/opt/pdg-bot")
        import importlib
        bot = importlib.import_module("bot")
        want, undrivable = bot.ruleset_hijack_text(meta)
    except Exception as e:  # noqa: BLE001
        return ("warn", "规则集生效状态", "算不出应有内容(%s), 无法核对" % type(e).__name__)
    try:
        with open(f, "rb") as fh:
            have = fh.read()
    except OSError:
        have = None
    drivable = len(meta) - len(undrivable)
    if have != want and drivable:
        lvl = "fail" if mode == "gfw" else "warn"
        return (lvl, "规则集生效状态",
                "与启用中的规则集不同步(%s 模式): 规则集里的域名在 gfw 模式下不会被劫持到网关, "
                "那些 RULE-SET 规则不会命中。跑 sudo pdg update 或在 bot 里刷新一次规则集即可重算。"
                % mode)
    if undrivable:
        return ("warn", "规则集生效状态",
                "%d 个规则集读不出域名(文件损坏 / 类型认不出 / 缺 mihomo 二进制): %s。"
                "gfw 模式下它们的规则不会命中; 重新添加或刷新一次这些规则集试试, "
                "实在不行把域名手写进 %s。"
                % (len(undrivable), "、".join(str(x) for x in undrivable[:3]), f))
    return ("ok", "规则集生效状态", "%d 个规则集的域名已同步(gfw 模式下也能命中)" % drivable)


GEOSITE_DIR = "/etc/mosdns/rules"
_GEOSITE_FILES = ("geosite_cn.txt", "geosite_apple.txt", "geosite_gfw.txt",
                  "geosite_geolocation-!cn.txt")

def check_geosite_db():
    """geosite 规则库是不是空的。

    装机时 geosite 下载失败(没网/源站抽风/被墙)会退化成空规则库 —— 网关照常起来, 只是
    "哪些域名算国内"这件事没有依据了。这个降级只在装机那一刻打了一行黄字, 之后再没人提;
    而症状("怎么什么都走代理"/"国内网站变慢")跟规则库空了对不上号, 用户很难自己想到这。

    只读: 看文件在不在、有没有内容。缺文件比空文件更要紧 —— mosdns 的 domain_set 缺文件
    直接 FATAL, 那台机器下次重启就起不来了。"""
    d = GEOSITE_DIR
    if not os.path.isdir(d):
        return None                       # 没装 mosdns → 这项不适用
    missing = [f for f in _GEOSITE_FILES if not os.path.exists(os.path.join(d, f))]
    if missing:
        return ("fail", "geosite 规则库",
                "缺文件: %s —— mosdns 启动时读不到会直接退出(下次重启就起不来)。"
                "在 bot「更新规则库」跑一次即可补齐。" % "、".join(missing))
    empty = [f for f in _GEOSITE_FILES if os.path.getsize(os.path.join(d, f)) == 0]
    if len(empty) == len(_GEOSITE_FILES):
        return ("warn", "geosite 规则库",
                "全是空的 —— 多半是装机时下载失败。网关能用, 但国内域名不会被识别为直连, "
                "等于全都当境外处理。在 bot「更新规则库」跑一次就好。")
    if empty:
        return ("warn", "geosite 规则库",
                "这几个是空的: %s。对应类别的分流暂时没有依据, "
                "在 bot「更新规则库」跑一次重新拉取。" % "、".join(empty))
    n = sum(1 for f in _GEOSITE_FILES
            for _ in open(os.path.join(d, f), encoding="utf-8", errors="replace"))
    return ("ok", "geosite 规则库", "%d 条规则, 4 个类别齐全" % n)


NFT_EXTRA_DIR = "/etc/privdns-gateway/nft-input.d"

def check_nft_extra():
    """用户自定义放行的 include 点是否就位。

    本项目的 `table inet pdg` 每次装机/迁移都按模板重建 —— 手加在里面的规则会被冲掉。所以
    模板末尾 glob include 这个目录, 它不受更新影响。**目录里有 .conf 但配置里没有 include 行**
    是最坏的一种: 用户以为规则生效了, 实际一条都没进内核, 而且哪儿都不报错。"""
    import glob as _glob
    confs = sorted(_glob.glob(os.path.join(NFT_EXTRA_DIR, "*.conf")))
    try:
        with open("/etc/nftables.conf", encoding="utf-8") as f:
            has_inc = "nft-input.d/*.conf" in f.read()
    except OSError:
        return None                       # 读不到防火墙配置, 别在这里瞎报(另有检查管它)
    if confs and not has_inc:
        return ("fail", "自定义放行",
                "%s 里有 %d 个 .conf, 但 /etc/nftables.conf 没有 include 它们 —— "
                "这些规则一条都没进内核, 而且哪儿都不报错。跑 sudo pdg update 补上 include 点。"
                % (NFT_EXTRA_DIR, len(confs)))
    if not has_inc:
        return ("warn", "自定义放行",
                "防火墙里没有自定义放行的 include 点(老装尚未迁移)。需要额外放行端口时, "
                "跑一次 sudo pdg update 补上, 之后把规则写进 %s/*.conf。" % NFT_EXTRA_DIR)
    if not confs:
        return ("ok", "自定义放行", "自定义防火墙规则入口已启用(%s/*.conf, 目前为空)" % NFT_EXTRA_DIR)
    return ("ok", "自定义放行",
            "自定义防火墙规则入口已启用, 已加载 %d 个自定义规则文件: %s"
            % (len(confs), "、".join(os.path.basename(c) for c in confs[:3])))


def check_mem():
    """显示当前内存模式 + mosdns cache size(只读, 不写 profile)。始终 ok, 仅信息展示。"""
    mode = None
    try:
        for ln in open(PROFILE_ENV):
            if ln.startswith("PDG_LOWMEM="):
                mode = ln.strip().split("=", 1)[1]
    except OSError:
        pass
    if mode not in ("0", "1"):                      # 无 profile → 按内存推断(不写盘)
        try:
            kb = int(next(l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemTotal:")))
            mode = "1" if kb <= 1331200 else "0"    # 1300 MiB
        except Exception:  # noqa: BLE001
            mode = "?"
    label = {"1": "低内存", "0": "标准", "?": "未知"}[mode]
    size = "?"
    m = re.search(r"tag: lazy_cache.*?size:\s*(\d+)", _mos(), re.S)
    if m:
        size = m.group(1)
    return ("ok", "内存模式", f"{label} · mosdns cache={size}")

def check_cert():
    p = _cert_path()
    if not os.path.exists(p):
        return ("fail", "证书", f"{p} 不存在")
    rc, _, _ = _run(["openssl", "x509", "-checkend", str(14 * 86400), "-noout", "-in", p])
    return ("warn", "证书", "14 天内过期, 查 certbot.timer") if rc != 0 else ("ok", "证书", "存在且 >14 天")

def check_dns():
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@127.0.0.1", "example.com", "A"])
    return ("ok", "本机DNS", "mosdns 应答正常") if out.strip() \
        else ("fail", "本机DNS", "127.0.0.1:53 不应答(mosdns?)")

def check_core_config():
    rc, out, err = _run(["mihomo", "-t", "-d", "/etc/mihomo", "-f", MIHOMO_CFG], t=20)
    return ("ok", "mihomo 配置", "check 通过") if rc == 0 \
        else ("fail", "mihomo 配置", "check 失败: " + (out + err)[-200:])

# ── 深度(慢速)端到端检查: `pdg doctor --deep` 用, 仍只读 ──
def check_deep_dot_handshake():
    d = _dot_domain()
    try:
        p = subprocess.run(["openssl", "s_client", "-connect", "127.0.0.1:853",
                            "-servername", d or "localhost"],
                           input="Q\n", capture_output=True, text=True, timeout=12)
        out = p.stdout + p.stderr
    except Exception as e:  # noqa: BLE001
        return ("fail", "DoT 握手(853)", f"连接失败: {e}")
    if "BEGIN CERTIFICATE" not in out and "Verify return code" not in out:
        return ("fail", "DoT 握手(853)", "TLS 握手未完成(mosdns DoT 没起?)")
    m = re.search(r"subject=.*?CN\s*=\s*([A-Za-z0-9.*-]+)", out)
    cn = m.group(1) if m else "?"
    if d and cn not in ("?", d):
        return ("warn", "DoT 握手(853)", f"握手 OK 但证书 CN={cn} 与 DoT 域名 {d} 不符")
    return ("ok", "DoT 握手(853)", f"TLS 握手成功, CN={cn}")

def check_deep_probe81():
    """:81 探测端点。两平台都查 —— pdg-probe81 已是公共组件。

    iOS 靠它做 OnDemand 探测(URLStringProbe 只认 200), Android 靠它做链路诊断的
    HTTP 会话入口。这里请求的是 `/`: 会话路径 `/probe?t=…` 需要 token, 拿它做
    健康检查会把无效尝试计数打满。"""
    rc, out, _ = _run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                       "--max-time", "5", "http://127.0.0.1:81/"])
    code = out.strip()
    return ("ok", ":81 探测端点", "返回 200 ✓") if code == "200" \
        else ("fail", ":81 探测端点", f"返回 {code or '无响应'}(需要 200)")

def check_deep_dot_witness():
    """DoT 证据端(pdg-dotwitness)。**独立于关键 DNS 服务集**。

    为什么不放进 expected_services(): 那是"普通 DNS 能不能用"的判据集。witness 只是
    链路诊断用的旁路观察端 —— 它挂了, mosdns、mihomo、普通解析一点不受影响(P0 隔离门
    实测两种故障下 UDP/TCP/DoT 各 9/9)。把它算进关键服务, 等于让一个辅助件的故障把
    整台机器判成坏的。所以异常一律用 warn 级, 不用 fail。

    反过来也不能装看不见: 四件套缺一件就会出现"service active 却查不到证据"那种假健康,
    而上层据此会对用户说"你手机的加密 DNS 没到达网关" —— 那是假话。所以要独立报出来。

    文案只说部署状态, 不碰 probe label、qname、token、来源地址或 evidence 内容。
    """
    unit = "/etc/systemd/system/pdg-dotwitness.service"
    if not os.path.exists(unit):
        return ("warn", "DoT 证据端", "未安装 —— 手机 DoT 证据这项会一直报不可判断")
    st = _run(["systemctl", "is-active", "pdg-dotwitness"])[1].strip()
    if st == "failed" or _run(["systemctl", "is-failed", "pdg-dotwitness"])[1].strip() == "failed":
        return ("warn", "DoT 证据端", "服务 failed(不影响普通 DNS, 但证据采不到)")
    if st != "active":
        return ("warn", "DoT 证据端", f"服务 {st or '未运行'}(不影响普通 DNS, 但证据采不到)")
    env = "/etc/privdns-gateway/dotwitness.env"
    try:
        suffix = ""
        for line in open(env, encoding="utf-8"):
            if line.startswith("PDG_DOTWITNESS_SUFFIX="):
                suffix = line.split("=", 1)[1].strip()
        if not suffix or suffix.startswith(".") or suffix.endswith(".") or ".." in suffix:
            return ("warn", "DoT 证据端", "环境文件里的探测命名空间不合法")
    except OSError:
        return ("warn", "DoT 证据端", "环境文件缺失或读不到")
    # 只认回环。绑到别的地址等于把证据端暴露给内网, 那是硬错不是提示。
    _, out, _ = _run(["ss", "-lun"])
    lines = [l for l in out.splitlines() if ":5399" in l]
    if not lines:
        return ("warn", "DoT 证据端", "服务在跑但没有在 5399 监听(四件套未闭合)")
    if not all("127.0.0.1:5399" in l for l in lines):
        return ("warn", "DoT 证据端", "5399 绑定了非回环地址 —— 证据端不该对内网可见")
    return ("ok", "DoT 证据端", "已部署, 仅监听 127.0.0.1:5399 ✓")


def check_deep_dns_cn():
    # 本机源(127.0.0.1)不在内网卡段 → 走 remote_upstream; 国内域名应得真实 IP(非本机)
    _, out, _ = _run(["dig", "+short", "+time=3", "+tries=1", "@127.0.0.1", "www.qq.com", "A"])
    ips = [x for x in out.split() if re.match(r"^\d+\.\d+\.\d+\.\d+$", x)]
    sip = _server_ip()
    if not ips:
        return ("fail", "DNS 解析(国内)", "www.qq.com 无 A 记录(mosdns/上游异常?)")
    if sip and sip in ips:
        return ("warn", "DNS 解析(国内)", f"www.qq.com → 本机 {sip}?? 国内域名不该被劫持")
    return ("ok", "DNS 解析(国内)", f"www.qq.com → {ips[0]}(直连)")

def check_deep_clash():
    try:
        req = urllib.request.Request("http://127.0.0.1:9090/proxies")
        sec = ""                                    # 观测面板开启时 clash_api 设了 secret, 本机也要带 Bearer
        try:
            sec = (json.load(open(SB)).get("experimental", {}).get("clash_api", {}) or {}).get("secret") or ""
        except Exception:  # noqa: BLE001
            pass
        if sec:
            req.add_header("Authorization", "Bearer " + sec)
        with urllib.request.urlopen(req, timeout=5) as r:
            n = len(json.load(r).get("proxies", {}))
        return ("ok", "内核状态接口", f"127.0.0.1:9090 可读, {n} 个出站/组")
    except Exception as e:  # noqa: BLE001
        return ("warn", "内核状态接口", f"读不到 127.0.0.1:9090 ({e})")

def check_deep_hijack_note():
    c = _internal_cidr() or "内网卡段"
    return ("info", "代理劫持验证",
            f"A 劫持 / AAAA 抑制只对来源 {c} 生效; 本机 dig(源 127.0.0.1)走直连上游, "
            "无法复现劫持。端到端请用手机走内网卡实测。")

# ── DNS 上游可观测性: 逐上游探测可达性/延迟 + 近 1h mosdns 上游错误计数 ──
def _upstreams_of(tag):
    """从 mosdns 配置里抽某个 forward 块的 upstream addr 列表。"""
    m = re.search(r"- tag:\s*" + re.escape(tag) + r"\b(.*?)(?:\n\s*- tag:|\Z)", _mos(), re.S)
    return re.findall(r'addr:\s*"([^"]+)"', m.group(1)) if m else []

def _dns_query(qname="example.com"):
    """构造一个 A 查询的 wire bytes, 返回 (qid, bytes)。"""
    import os, struct
    qid = os.getpid() & 0xffff
    hdr = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)              # RD=1
    qn = b"".join(bytes([len(x)]) + x.encode() for x in qname.split(".")) + b"\x00"
    return qid, hdr + qn + struct.pack(">HH", 1, 1)                   # QTYPE=A, QCLASS=IN

def _dns_resp_ok(resp, qid):
    """合法 DNS 应答: ID 匹配 + QR=1 + RCODE=0(NOERROR) + 至少 1 条回答。"""
    import struct
    if len(resp) < 12:
        return False
    rid, flags, _, an = struct.unpack(">HHHH", resp[:8])
    return rid == qid and bool(flags & 0x8000) and (flags & 0x000f) == 0 and an >= 1

def _recvn(sock, n):
    b = b""
    while len(b) < n:
        c = sock.recv(n - len(b))
        if not c:
            break
        b += c
    return b

def _probe_upstream(addr):
    """返回 (addr, 毫秒|None, 说明)。None=不健康。每种协议都发真实 DNS 查询并校验应答(ID/RCODE/有回答),
    避免"端口被别的服务占着也算健康"——CDN/反代/错服务过不了 DNS 应答校验。"""
    import time, socket
    t0 = time.monotonic()
    ok = False; note = ""
    try:
        if addr.startswith(("udp://", "tcp://")):
            hp = addr.split("://", 1)[1]; host, _, port = hp.partition(":"); port = port or "53"
            args = ["dig", "+time=2", "+tries=1", "+short", "@" + host, "-p", port, "example.com", "A"]
            if addr.startswith("tcp://"):
                args.insert(1, "+tcp")
            rc, out, _ = _run(args, t=4); ok = (rc == 0 and bool(out.strip()))   # dig 已校验 RCODE/回答
        elif addr.startswith("https://"):                                        # DoH: 发真实 wire query
            import urllib.request
            qid, wire = _dns_query()
            req = urllib.request.Request(addr, data=wire,
                headers={"content-type": "application/dns-message", "accept": "application/dns-message"})
            with urllib.request.urlopen(req, timeout=3) as r:
                ok = (getattr(r, "status", 200) == 200) and _dns_resp_ok(r.read(), qid)
        elif addr.startswith("tls://"):                                          # DoT: TLS + DNS-over-TCP
            import ssl, struct
            hp = addr.split("://", 1)[1]; host, _, port = hp.partition(":")
            qid, wire = _dns_query()
            ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            with socket.create_connection((host, int(port or 853)), timeout=3) as raw:
                with ctx.wrap_socket(raw, server_hostname=host) as tls:
                    tls.sendall(struct.pack(">H", len(wire)) + wire)
                    head = _recvn(tls, 2)
                    body = _recvn(tls, struct.unpack(">H", head)[0]) if len(head) == 2 else b""
                    ok = _dns_resp_ok(body, qid)
        else:
            return (addr, None, "未知协议")
    except Exception as e:  # noqa: BLE001
        note = str(e)[:40]
    ms = int((time.monotonic() - t0) * 1000)
    return (addr, ms if ok else None, note or ("不可达/超时" if not ok else ""))

def check_deep_upstreams():
    rank = {"ok": 0, "warn": 1, "fail": 2}; level = "ok"; parts = []
    for name, tag in (("国际remote", "remote_upstream"), ("国内local", "local_upstream")):
        ups = _upstreams_of(tag)
        if not ups:
            parts.append(f"{name} 读不到配置"); level = max(level, "warn", key=rank.get); continue
        oks = []; bad = []
        for a in ups:
            _, ms, msg = _probe_upstream(a)
            (bad if ms is None else oks).append(f"{a} {msg}" if ms is None else (a, ms))
        if not oks:
            level = max(level, "fail", key=rank.get)
            parts.append(f"{name} 0/{len(ups)} ❌ ({'; '.join(bad)})")
        else:
            slow = max(oks, key=lambda x: x[1])
            seg = f"{name} {len(oks)}/{len(ups)} 最慢 {slow[0]} {slow[1]}ms"
            if bad:
                level = max(level, "warn", key=rank.get); seg += f" ⚠️挂:{'; '.join(bad)}"
            parts.append(seg)
    _, log, _ = _run(["journalctl", "-u", "mosdns", "--since", "-1h", "--no-pager", "-o", "cat"], t=8)
    nerr = log.count("upstream error")
    if nerr:
        parts.append(f"近1h上游错误 {nerr} 次")
        level = max(level, "warn", key=rank.get)
    return (level, "DNS 上游探测", " ; ".join(parts))

GS_LOC = ("gs-loc.apple.com", "gs-loc-cn.apple.com")   # WLOC 接管域名(与 bot MITM_PLUGIN_DOMAINS 同源)

def check_mitm_structure():
    """MITM 接管结构(mosdns force_hijack domain_set + force_hijack_seq + 优先级规则 + mitm_hijack.txt):
    升级迁移是否补到位。仅 iOS。自定义/读不到 → info(不判); 标准结构缺 force_hijack 或规则顺序错 → warn。
    与「MITM 插件」启用态分开: 结构应常驻(平时空文件=休眠), 缺了说明 v1.4.x 升级迁移没跑到。"""
    if _platform() != "ios":
        return None
    conf = _mos()
    if not conf:
        return ("info", "WLOC DNS 接管", "读不到 mosdns 配置")
    if "tag: internal_sequence" not in conf or "tag: ecs_china" not in conf:
        return ("info", "WLOC DNS 接管", "自定义 mosdns 配置, 跳过 force_hijack 检查")
    if "tag: force_hijack" not in conf:
        return ("warn", "WLOC DNS 接管", "缺 force_hijack 接管结构(v1.4.x 升级迁移未跑到); 开 WLOC 前 sudo pdg __migrate")
    blk = _internal_seq_block(conf)
    i_fh, i_cn = blk.find("qname $force_hijack"), blk.find("qname $geosite_cn")
    if i_fh < 0 or (i_cn >= 0 and i_fh > i_cn):
        return ("warn", "WLOC DNS 接管", "force_hijack 优先级规则缺失或顺序错(应在 geosite_cn 之前强制接管)")
    if "tag: force_hijack_seq" not in conf:
        return ("warn", "WLOC DNS 接管", "缺 force_hijack_seq(接管域名的 AAAA/HTTPS 抑制 + A 劫持序列)")
    if not os.path.isfile(MITM_HIJACK_FILE):
        return ("warn", "WLOC DNS 接管", "缺 " + MITM_HIJACK_FILE + "(接管域名集文件)")
    return ("ok", "WLOC DNS 接管", "force_hijack + force_hijack_seq + 优先级规则 + mitm_hijack.txt 就位")

def check_mitm():
    """MITM 插件(Feature B / iOS): 启用时应 pdg-mitm active + CA + mitm_hijack 含接管域名 +
    当前内核有 MITM 路由。未启用 = info。安卓不适用。(不只是 CA+active)"""
    if _platform() != "ios":
        return None                              # MITM/WLOC 仅 iOS, 安卓不显示此项
    try:
        cfg = json.load(open("/etc/privdns-gateway/mitm.json"))
    except Exception:  # noqa: BLE001
        cfg = {}
    enabled = [k for k in ("wloc",) if (cfg.get(k) or {}).get("enabled")]
    if not enabled:
        return ("info", "WLOC 服务", "未启用")
    # WLOC 开着就说明这几个组件是必需件: 更新时若某个装失败(旧实现 ||true 会静默跳过),
    # 目标位置留着上一版文件 —— 光看"服务 active"发现不了新旧混装, 这里按文件在不在直接判死。
    need = ["/opt/pdg-bot/mitm_ca.py", "/opt/pdg-bot/mitm_server.py", "/opt/pdg-bot/mitm_wloc.py",
            "/opt/pdg-bot/probe81.py", "/opt/pdg-bot/pdg-dot.mobileconfig.tmpl",
            # 缺它 ⇒ 描述文件根本生成不出来(Bot 与 CLI 都走这一份), 而 WLOC 开着时
            # 用户恰恰**必须**重新生成一份带根证书的描述文件。
            "/opt/pdg-bot/iosprofile.py", "/opt/pdg-bot/iosstate.py"]
    miss = [os.path.basename(p) for p in need if not os.path.isfile(p)]
    if miss:
        return ("fail", "WLOC 服务", "已启用但缺 iOS 组件: " + ", ".join(miss)
                + "; 运行 sudo pdg update 重新部署。")
    # 版本一致性: 仓库在本机可读时, 逐个比对部署文件与仓库文件。装到一半失败会把上一版留在
    # 原地, 只看"文件在不在"发现不了这种新旧混装。仓库不可用则跳过这一层(不误报)。
    drift = []
    for dst, src in (("mitm_ca.py", "deploy/bot/mitm_ca.py"),
                     ("mitm_server.py", "deploy/bot/mitm_server.py"),
                     ("mitm_wloc.py", "deploy/bot/mitm_wloc.py"),
                     ("iosprofile.py", "deploy/bot/iosprofile.py"),
                     ("iosstate.py", "deploy/bot/iosstate.py"),
                     ("probe81.py", "deploy/bot/probe81.py"),
                     ("pdg-dot.mobileconfig.tmpl", "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")):
        sp = os.path.join(REPO_DIR, src)
        if not os.path.isfile(sp):
            continue
        if _filesha(os.path.join("/opt/pdg-bot", dst)) != _filesha(sp):
            drift.append(dst)
    if drift:
        return ("fail", "WLOC 服务", "已启用但这些组件与当前发布不一致(疑似新旧混装): "
                + ", ".join(drift) + "; 运行 sudo pdg update 重新部署。")
    if _run(["systemctl", "is-active", "pdg-mitm"])[1].strip() != "active":
        return ("fail", "WLOC 服务", "已启用(" + ",".join(enabled) + ")但 pdg-mitm 未运行")
    if not os.path.isfile("/etc/privdns-gateway/ca/ca.crt"):
        return ("fail", "WLOC 服务", "缺 CA 证书 /etc/privdns-gateway/ca/ca.crt")
    # 接管域名集应含 gs-loc 两域名(mosdns 强制劫持源)
    try:
        hij = open(MITM_HIJACK_FILE).read()
    except OSError:
        hij = ""
    if not all(d in hij for d in GS_LOC):
        return ("fail", "WLOC 服务", "mitm_hijack.txt 未含 gs-loc 接管域名(mosdns 未强制劫持, 重开一次 WLOC)")
    # MITM 路由(mihomo): 需 MITM-OUT 出站 + gs-loc → MITM-OUT 规则。
    try:
        mc = json.load(open(MIHOMO_CFG))
        has_out = any(p.get("name") == "MITM-OUT" for p in mc.get("proxies", []))
        has_rule = any(("MITM-OUT" in r) and ("gs-loc" in r) for r in mc.get("rules", []))
    except Exception:  # noqa: BLE001
        has_out = has_rule = False
    if not (has_out and has_rule):
        return ("fail", "WLOC 服务", "mihomo 缺 MITM-OUT 出站或 gs-loc 路由(重开一次 WLOC 重渲染内核)")
    return ("ok", "WLOC 服务", "pdg-mitm active + CA + mitm_hijack + mihomo MITM 路由 就位")

def check_rulesets():
    """规则集能否进入 mihomo 运行配置。

    mihomo 读不了 sing-box 的二进制 `.srs`; 这类**老机器遗留**的规则集会让渲染器把对应规则
    丢弃 → _core_apply/迁移一律判失败。若等到 `pdg update` 才发现, 用户是"更新被挡住"才回头
    查原因。这里提前报出来, 并直说该怎么办。只读, 不改任何东西。"""
    try:
        meta = json.load(open(RS_META, encoding="utf-8"))
    except Exception:  # noqa: BLE001  没有规则集元数据 = 没加过规则集
        return None
    if not isinstance(meta, dict) or not meta:
        return None
    stale = []
    for name, info in meta.items():
        if not isinstance(info, dict):
            continue
        url = str(info.get("url", "")).lower().split("?", 1)[0]
        if url.endswith(".srs") or str(info.get("format", "")) == "binary" \
           or str(info.get("path", "")).endswith(".srs"):
            stale.append(str(info.get("label") or name))
    if stale:
        return ("fail", "规则集", "这些是 sing-box 二进制 .srs, mihomo 读不了 → 分流不会生效, "
                                  "且会挡住 `pdg update`: " + "、".join(stale[:6])
                                  + "。请在 bot「📑 分流管理」里删掉它们, 换成 .list/.txt/.yaml/.mrs。")
    return ("ok", "规则集", "%d 个, 格式均可被 mihomo 加载" % len(meta))


# ── 分流优先级: 自动生成的规则不许静默压过用户点名的域名规则 ──────────────────
# 内核自上而下第一条命中即止, 所以规则表的**顺序就是优先级**。本项目会自动往规则表里塞两批
# 规则: WDA 解锁(unlock.txt 那批, 目标是 jp 直出 → 渲染成 DIRECT)与 MITM 接管(mitm_hijack.txt
# 那批 → MITM-OUT)。它们排在用户点名规则前面时, 用户那条规则就成了死规则 —— 配置里两条都在,
# 面板、`测域名`、`pdg doctor` 以前全都看不出来, 只有把 clash_api /rules 拉出来数才发现
# (.200 现场: netflix.com 点名指到 hkt, 实际一直走直连)。
#
# 判据落在**渲染出来的内核配置**上, 而不是数据模型: 那才是内核真正拿去求值的东西, 也与用户
# 自查时看到的 /rules 一致; 模型对了而渲染没跟上(比如恢复了旧配置忘了重渲)同样能被这里逮住。
_DOMAIN_KINDS = ("DOMAIN-SUFFIX", "DOMAIN", "DOMAIN-KEYWORD")


def _domain_list(path):
    """读 mosdns 的域名清单(去 domain: 前缀)。读不到 = 空。"""
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    out.append(line.replace("domain:", "").strip())
    except OSError:
        pass
    return [d for d in out if d]


def _rendered_domain_rules(rules):
    """渲染出来的规则表 → [(下标, 类型, 域名, 目标)], 只取按域名匹配的那几类。

    逻辑规则(AND,…)与 RULE-SET 不在其中: 前者要展开条件树、后者要读 provider 内容才知道命中
    什么, 猜不得 —— 认不出的一律不参与判断, 宁可漏报也不误报。"""
    out = []
    for i, rule in enumerate(rules):
        if not isinstance(rule, str):
            continue
        parts = rule.split(",")
        if len(parts) < 3 or parts[0] not in _DOMAIN_KINDS:
            continue
        out.append((i, parts[0], parts[1].strip(), parts[2].strip()))
    return out


def _covers(kind, value, other_kind, other_value):
    """(kind,value) 这条规则是否**吃掉**了 (other_kind,other_value) 能命中的全部域名。

    只在能完整覆盖时才算数 —— 部分重叠(如 DOMAIN,a.com 之于 DOMAIN-SUFFIX,a.com)不报,
    那条规则对其它子域仍然有效, 报出来只会变成噪声。"""
    if kind == "DOMAIN-SUFFIX":
        if other_kind in ("DOMAIN", "DOMAIN-SUFFIX"):
            return other_value == value or other_value.endswith("." + value)
        return False
    if kind == "DOMAIN":
        return other_kind == "DOMAIN" and other_value == value
    if kind == "DOMAIN-KEYWORD":
        # 关键词在对方的域名里 ⇒ 对方能命中的每一个主机名都含这个关键词 ⇒ 全被吃掉
        return other_kind in ("DOMAIN", "DOMAIN-SUFFIX") and value in other_value
    return False


def _auto_batches(dom_rules, unlock, mitm):
    """哪些规则是**自动生成**的 → {下标: 批次名}。按位置认, 不按域名文本认。

    为什么不能只看域名在不在 unlock.txt 里: 用户点名 netflix.com 时, 他那条规则与 WDA 自动
    那条**逐字节只差目标**, 单看域名分不出谁是谁 —— 于是"用户规则被自动规则压过"和"自动规则
    被用户规则接管"这两件相反的事会被判成同一件(第一版就是这么把现场那条漏掉的)。

    位置判据来自渲染方式本身:
      · MITM 接管那批的目标是 MITM-OUT —— 这个出站名是渲染器造出来的, 别处不会有;
      · WDA 那批由 model 里**一条** domain_suffix 规则展开, 因此是一段**连续**、同目标、
        域名都在 unlock.txt 里的 DOMAIN-SUFFIX。取覆盖最多的那一段: 用户自己那条同名规则
        是孤立的一两条, 不会被算成批次。"""
    auto = {}
    for i, _kind, value, target in dom_rules:
        if target == "MITM-OUT" and (not mitm or value in mitm):
            auto[i] = "MITM 接管"
    best, run = [], []
    for i, kind, value, target in dom_rules:
        member = kind == "DOMAIN-SUFFIX" and value in unlock and i not in auto
        if member and run and i == run[-1][0] + 1 and target == run[-1][1]:
            run.append((i, target))
        else:
            run = [(i, target)] if member else []
        if len(run) > len(best):
            best = list(run)
    if len(best) >= 2:            # 一两条孤立规则不是"批次", 不猜
        for i, _target in best:
            auto[i] = "WDA 解锁"
    return auto


def rule_precedence_scan(cfg=None):
    """扫一遍内核规则表, 找出"永远轮不到"的域名规则。只读, 不改任何东西。

    返回 dict:
      auto    [(域名, 本该去的出口, 实际被谁截走, 截走它的批次名)] —— 被自动规则压过的用户规则
      user    [(域名, 本该去的出口, 实际去向)]                     —— 被用户自己另一条规则压过
      wda     {"count": WDA 批量域名数, "target": 它们的去向, "taken": [(域名, 出口)]}
      error   读不出规则表时的说明(此时其余字段为空)

    bot 面板与 doctor 用的是同一份扫描 —— 两处各写一份判据迟早会一个说有问题一个说没有。"""
    res = {"auto": [], "user": [], "wda": {}, "error": ""}
    if cfg is None:
        if not os.path.exists(MIHOMO_CFG):
            return res
        try:
            cfg = json.load(open(MIHOMO_CFG, encoding="utf-8"))
        except Exception:  # noqa: BLE001
            res["error"] = "读不到 mihomo 规则表(不是本项目渲染出来的形态?)"
            return res
    rules = cfg.get("rules") if isinstance(cfg, dict) else None
    if not isinstance(rules, list):
        res["error"] = "mihomo 配置里没有 rules 列表"
        return res

    unlock = set(_domain_list(UNLOCK_FILE))
    mitm = set(_domain_list(MITM_HIJACK_FILE))
    direct = set(_domain_list(CUSTOM_DIRECT_FILE))
    dom_rules = _rendered_domain_rules(rules)
    auto = _auto_batches(dom_rules, unlock, mitm)

    taken = []                             # WDA 域名被用户点名规则接管(修好之后的正常形态)
    for idx, kind, value, target in dom_rules:
        for jdx, jkind, jvalue, jtarget in dom_rules:
            if jdx >= idx or not _covers(jkind, jvalue, kind, value):
                continue
            # **第一条**覆盖它的规则就定了这个域名的去向, 后面的一概不看 —— 哪怕后面还有一条
            # 目标不同的。跳过同目标那条去找"目标不同"的会凭空造出一条不存在的冲突: 真正生效的
            # 是最靠前那条, 它的目标与本条相同时, 结果与用户期望一致, 没什么好报的。
            if jtarget != target:
                victim, culprit = auto.get(idx, ""), auto.get(jdx, "")
                if victim and not culprit:
                    if victim == "WDA 解锁":
                        taken.append((value, jtarget))
                elif culprit and not victim:
                    res["auto"].append((value, target, jtarget, culprit))
                elif not culprit and not victim:
                    res["user"].append((value, target, jtarget))
            break

    if unlock:
        batch = [t for i, _k, _v, t in dom_rules if auto.get(i) == "WDA 解锁"]
        res["wda"] = {
            "count": len(batch),
            "target": batch[0] if batch else "(未渲染)",
            "taken": sorted(set(taken)),
            "direct_list": sorted(unlock & direct),
        }
    return res


def check_rule_precedence():
    """用户点名的域名规则有没有被自动生成的规则(WDA 解锁 / MITM 接管)静默压过。

    压过 = 那条规则永远轮不到, 但配置里它还在 —— 用户看到的是"规则加了却不生效", 而以前
    整套自检没有一项会提这件事。同时把"WDA 正在把哪一批域名判成什么"如实说出来: 那批 DIRECT
    是自动加的, 用户没写过, 至少得看得见。"""
    scan = rule_precedence_scan()
    if scan["error"]:
        return ("warn", "分流优先级", scan["error"] + " —— 无法核对用户指定的域名规则是否被系统自动规则抢先匹配")
    wda = scan.get("wda") or {}
    notes = []
    if wda.get("count"):
        where = "直连(本机直出)" if wda["target"] == "DIRECT" else "出口 " + str(wda["target"])
        notes.append("WDA 解锁自动把 %d 个域名判给%s" % (wda["count"], where))
        if wda.get("taken"):
            notes.append("其中 %d 个按你自己的规则走: %s"
                         % (len(wda["taken"]),
                            "、".join("%s→%s" % (d, t) for d, t in wda["taken"][:4])
                            + ("…" if len(wda["taken"]) > 4 else "")))
        if wda.get("direct_list"):
            notes.append("另有 %d 个在直连表里(DNS 直接返真实地址, 流量不进网关, WDA 对它们不生效): %s"
                         % (len(wda["direct_list"]), "、".join(wda["direct_list"][:4])
                            + ("…" if len(wda["direct_list"]) > 4 else "")))
    if scan["auto"]:
        items = "; ".join("%s 本该走 %s, 实际被「%s」判给 %s" % (d, want, batch, got)
                          for d, want, got, batch in scan["auto"][:5])
        more = "…等 %d 条" % len(scan["auto"]) if len(scan["auto"]) > 5 else ""
        # 两批自动规则的处置**不一样**, 不能给一句通用建议:
        #   · WDA 那批本就该排在点名规则之后 —— 出现在这里说明是老顺序, 下一次 model 写入
        #     会自愈, 也可以立刻关一次再开 🔓 WDA;
        #   · MITM 接管那批**故意**排在最前(iOS 的 WLOC 要先终止 TLS 才改得了坐标), 它不会
        #     给点名规则让路 —— 要么删掉那条规则, 要么关掉 WLOC。说反了会让人白等自愈。
        how = []
        if any(b == "WDA 解锁" for *_x, b in scan["auto"]):
            how.append("WDA 这批: 在 bot 里改一次这几个域名的规则, 或关一次再开 🔓 WDA "
                       "—— 新版把系统自动规则排在用户指定的域名规则之后")
        if any(b == "MITM 接管" for *_x, b in scan["auto"]):
            how.append("MITM 接管这批是**故意**排在最前的(WLOC 要先接管 TLS), 不会给用户指定的域名规则"
                       "让路 —— 要么删掉那条规则, 要么关掉 WLOC")
        return ("warn", "分流优先级",
                "有 %d 条用户指定的域名规则被系统自动规则抢先匹配, 当前无法生效 —— 自动生成的规则排在它前面: %s%s。"
                "内核自上而下第一条命中即止, 所以配置里两条都在也没用。→ %s。"
                % (len(scan["auto"]), items, more, "; ".join(how))
                + ("　[" + "; ".join(notes) + "]" if notes else ""))
    if scan["user"]:
        items = "; ".join("%s 本该走 %s, 实际走 %s" % (d, want, got)
                          for d, want, got in scan["user"][:5])
        return ("warn", "分流优先级",
                "有 %d 条域名规则被你自己**更靠前**的另一条规则抢先匹配, 当前无法生效(不是自动规则): %s。"
                "删掉其中一条即可。" % (len(scan["user"]), items)
                + ("　[" + "; ".join(notes) + "]" if notes else ""))
    if notes:
        return ("ok", "分流优先级",
                "; ".join(notes) + "; 用户指定的域名规则均优先于系统自动规则")
    return ("ok", "分流优先级", "用户指定的域名规则均优先于系统自动规则")


def check_nft_input_chains():
    """除 table inet pdg 外还有挂 hook input 的 base chain → 本项目的放行会被架空。

    装机/迁移时有前置门挡着, 但那只管当时: 之后用户自己往 filter 表加一条 input 链, 谁也不会
    再提醒 —— 端口看着开着、实际不通, 而且从配置文件上完全看不出问题。判据与迁移前置门共用
    nftscan.py, 不另写一份。"""
    found, readable = nftscan.scan()
    if found:
        msg = ("; ".join(found) + " —— PDG 的 input chain 是 policy drop, 同一 hook 上每条 "
               "base chain 都会执行, 上述表里的放行会被架空(端口看着开着实际不通)。"
               "请把需要的放行并入 table inet pdg 的 input chain, 或把那些链改挂到非 input hook。")
        # 判据说"有冲突"是对的, 但只说这一句, 排查得从头做起。本轮在生产机上定位一条 80
        # 放行花了七八步, 卡点是 `nft list` **显示不出 iptables 的 comment 匹配** —— 那条
        # 规则在 nft 眼里只是 `tcp dport 80 counter accept`, 换 `iptables -S` 一看归属就
        # 写在上面。这里把 iptables 视角的原文与已知签名一并附上, 省掉大半排查。
        # 拿不到就少几行提示: 它绝不参与"有没有冲突"的判定。
        try:
            hints = nftscan.creator_hints()
        except Exception:                                    # noqa: BLE001
            hints = []
        if hints:
            msg += "\n    可能是谁建的:\n    " + "\n    ".join(hints)
        return ("fail", "防火墙链冲突", msg)
    if not readable:
        # 只说"读不到"等于把问题丢回给用户。分清是权限还是 nftables 本身 —— 前者重跑一次就好,
        # 后者加多少 sudo 都没用。
        how = ("请用 <code>sudo pdg doctor</code> 重跑以完整检查"
               if os.geteuid() != 0 else
               "本机 nftables 不可用或未加载(nft list ruleset 失败), 请先确认 nftables 正常")
        return ("warn", "防火墙链冲突",
                "读不到运行中的 nftables ruleset, 仅据 " + NFT_CONF + " 判断: 未见冲突。" + how)
    return ("ok", "防火墙链冲突", "只有 table inet pdg 挂在 hook input 上")


# 救援启用意图的键名。与 lib/rescue.sh 的 RESCUE_INTENT_KEY 同名 —— 那边是唯一事实源,
# 这里只是引用它的名字, 不另定义一份取值语义。
RESCUE_INTENT_KEY = "PDG_RESCUE_ENABLED"


def _valid_ipv4(v):
    """点分四段且每段 0-255。只做形态校验 —— 它不是第二份"能不能启用"的判据,
    只是把"意图说要开、地址却明显不成立"这种情况和"地址没配"区分开。"""
    parts = (v or "").split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit() or not 0 <= int(p) <= 255 or (len(p) > 1 and p[0] == "0"):
            return False
    return True


def check_rescue_firewall():
    """救援平面的防火墙放行 —— 端口是**动态**的, 所以它不在 nftlive 的固定端口集合里。

    为什么必须单独一项, 而不是往 nftlive 的必需端口里加那个救援口:
      · 救援平面默认**是关的**。写进固定集合会让每台没开救援的机器都被报"缺规则";
      · 端口取自 lib/rescue.sh 的 PDG_RESCUE_PORT(有默认值), 用户可以改, 把它硬编码进代码
        会在改过的机器上查错端口, 报一个不存在的故障, 同时放过真正的那个;
      · 它与 Telegram SOCKS5 那个口是两码事 —— 早先混过一次, 这里不再混。

    **启用与否只看 PDG_RESCUE_ENABLED, 不从 bind 推。** `pdg rescue disable` 只撤放行 + 把
    意图写成 0, 它**不清 PDG_RESCUE_BIND** —— 监听地址是配置, 留着下次好直接开。拿"有没有
    bind"当"启没启用"用, 一台停用过的机器会被判成"已启用却没放行", doctor fail, 而
    `pdg update` 的更新后自检门据此**整次回滚**: 机器完全正常, 用户却更新不了。

    停用之后也不是什么都不看: 意图是 0 却仍有带 pdg-rescue 标记的放行, 说明端口还开着 ——
    那是暴露面, 必须报出来, 不能因为"反正已经停用了"就放过。
    """
    try:
        import rescue_const
        import rescue_nft
    except Exception:  # noqa: BLE001
        return None                      # 老机器还没有救援平面: 不显示这一项
    try:
        intent = rescue_const.profile_value(RESCUE_INTENT_KEY)
        bind = rescue_const.rescue_bind()
        port = rescue_const.port()
    except Exception:  # noqa: BLE001
        # 常量源(lib/rescue.sh / profile.env)读不到 —— 这时连"用没用这个功能"都判断不了。
        # 不显示这一项: 报一条"读不到常量"的警告只会在没装救援平面的机器上平白刷屏。
        return None
    try:
        with open(NFT_CONF, encoding="utf-8") as f:
            txt = f.read()
    except OSError:
        if intent == "1":
            return ("warn", "救援平面放行",
                    "读不到 %s, 无法确认救援放行是否就位" % NFT_CONF)
        return None
    # 带 pdg-rescue 标记的放行有几条 —— 停用/未部署时用它发现残留, 不看端口对不对
    leftover = rescue_nft.count_rules(txt)

    if intent is None:
        # 从未部署: 首次启用归 migrate_rescue_plane 管, 这里不猜、不显示。
        # 但**有残留规则**是另一回事: 没有任何启用记录, 端口却开着, 必须如实说。
        if leftover:
            return ("fail", "救援平面放行",
                    "没有启用记录(profile.env 里没有 %s), 防火墙里却有 %d 条救援放行 —— "
                    "端口开着而没人管它。跑 <code>sudo pdg rescue status</code> 查清来历。"
                    % (RESCUE_INTENT_KEY, leftover))
        return None
    if intent == "0":
        if leftover:
            return ("fail", "救援平面放行",
                    "救援平面已停用, 但防火墙里仍有 %d 条救援放行 —— 端口还开着, 属暴露面。"
                    "跑一次 <code>sudo pdg rescue disable</code> 把它撤干净。" % leftover)
        return None                      # disable 之后的正常样子: 不显示
    if intent != "1":
        return ("fail", "救援平面放行",
                "%s 的取值损坏(实得 %r, 只接受 0 或 1)—— 无法判断救援平面该开还是该关, "
                "拒绝猜。请用 <code>sudo pdg rescue enable</code> 或 "
                "<code>disable</code> 重新写入。" % (RESCUE_INTENT_KEY, intent))
    # ── 以下是 intent == "1" ────────────────────────────────────────────────
    if not bind or not _valid_ipv4(bind):
        return ("fail", "救援平面放行",
                "救援平面意图为启用, 但监听地址%s —— 开不起来。"
                "跑 <code>sudo pdg rescue bind &lt;IPv4&gt;</code> 设置。"
                % ("不合法(%r)" % bind if bind else "没有配置"))
    if rescue_nft.has_rescue_rule(txt, port, bind):
        return ("ok", "救援平面放行", "救援平面已启用, 防火墙放行就位(%s:%d)" % (bind, port))
    return ("fail", "救援平面放行",
            "救援平面已启用(绑 %s), 但 %s 里没有 tcp dport %d 的放行 —— 救援页面打不开。"
            "跑 <code>sudo pdg rescue status</code> 复查, 或重开一次 pdg rescue enable。"
            % (bind, NFT_CONF, port))


def check_transactions():
    """未完成的配置事务 —— pdgtx.NEEDS_RECOVERY 的四个状态全算:
    APPLYING / OBSERVING / ROLLING_BACK / ROLLBACK_FAILED。

    OBSERVING 尤其容易被漏掉: 那时文件已经落盘、服务动作也做完了, 只差最后判定, 现网却已经
    是新内容 —— 崩在这里和崩在 APPLYING 一样需要人工收尾, 所以必须报出来, 并**点名 txid**
    (只说"有未完成事务"等于让人自己去猜是哪一笔, 而 recover 命令要的正是那个 id)。

    doctor 只**报告**, 绝不代为恢复: 恢复要写现网、要拿写锁, 那是 `pdg tx recover` 的事;
    自检必须保持只读, 否则"跑个 doctor 顺手改了配置"就是下一个惊喜。"""
    try:
        import pdgtx
    except Exception:  # noqa: BLE001
        return None                      # 老机器还没有事务核心: 不显示这一项
    try:
        pend = pdgtx.pending_recovery()
    except Exception:  # noqa: BLE001
        return ("warn", "配置事务", "读不到事务目录, 无法确认是否有未完成事务")
    # 终态事务却仍留着 candidate/before: 事务本身收尾了, 但那些目录里可能有出口密码、UUID、
    # 证书私钥 —— 清理失败不会再被 pending/stale 提起, 必须单独报出来(只报 txid 与材料类型)。
    try:
        left = pdgtx.leftover_materials()
    except Exception:  # noqa: BLE001  老机器的核心还没有这个函数
        left = []
    if left:
        items = "; ".join("%s(%s: %s)" % (x.get("txid"), x.get("state"),
                                          "、".join(x.get("materials") or []))
                          for x in left[:3])
        note = ("有 %d 笔已收尾的事务仍留着敏感材料: %s —— 里面可能有出口密码/证书私钥, "
                "确认无需排查后请删除对应事务目录下的这些子目录。" % (len(left), items))
        if not pend:
            return ("warn", "配置事务", note)
    if not pend:
        recent = pdgtx.list_tx(limit=1)
        note = ("最近一笔: %s %s" % (recent[0].get("op"), recent[0].get("state"))) if recent \
            else "暂无记录"
        return ("ok", "配置事务", "没有未完成的事务(" + note + ")")
    worst = "fail" if any(m.get("state") == "ROLLBACK_FAILED" for m in pend) else "warn"
    items = "; ".join("%s(%s, %s)" % (m.get("txid"), m.get("op"), m.get("state")) for m in pend[:3])
    return (worst, "配置事务",
            "有 %d 笔未完成的配置事务: %s —— 在处理之前, 新的写操作会被拒绝。"
            "请运行 <code>sudo pdg tx show &lt;id&gt;</code> 查看, 再用 "
            "<code>sudo pdg tx recover &lt;id&gt;</code> 恢复。" % (len(pend), items))



# ── 内网面板(方案 B) ─────────────────────────────────────────────────────────
LAN_TABLE = "/etc/privdns-gateway/lan-panels.json"
LAN_CERT_DIR = "/etc/pdg-lan/certs"
LAN_NFT_TABLE = "pdglan"
LAN_USER = "pdg-lan"


def _lan_cfg():
    try:
        with open(LAN_TABLE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _lan_on():
    """这台机器**此刻是否真的在用**内网面板。

    判据不能只看面板表在不在: 停用之后表是刻意留下的(disable 的语义就是先停一停),
    对着一个没在跑的功能报红只会让人下次不看 doctor。反过来, 服务在跑就必须查 ——
    哪怕 profile 里的意图写着 0。

    返回 (在用吗, 服务是否 active)。
    """
    _rc, out, _e = _run(["systemctl", "is-active", "pdg-lan"], 8)
    active = (out or "").strip() == "active"
    intent = (_profile("PDG_LAN_ENABLED") or "").strip() == "1"
    return (active or intent), active


def _lanpanel():
    """按需 import lanpanel —— 它与 doctor 装在同一个目录(lib/modules.sh 的清单里)。
    取不到就让调用方报"判据跑不了", 而不是让整个 doctor 崩掉。"""
    try:
        import lanpanel
        return lanpanel
    except Exception:  # noqa: BLE001
        return None


def check_lan_routes():
    """门一常驻: 本机接受的子网路由有没有与自己正在用的网段相交。

    **与内网面板功能开没开无关**。危险来自"接受了一个重叠的路由"这件事本身: 只要接受了,
    本机发往那个段的包就会走进 tailnet, 而分流数据面从配置上完全看不出问题。所以判据
    挂在"有没有接受路由"上, 不挂在 PDG_LAN_ENABLED 上。
    """
    name = "内网面板: 子网路由重叠"
    if not os.path.exists("/proc/net/dev"):
        return None
    try:
        with open("/proc/net/dev", encoding="utf-8") as f:
            if not any(l.strip().startswith("tailscale0:") for l in f):
                return None          # 没有 tailnet, 这条不适用
    except OSError:
        return None
    rc, out, _ = _run(["tailscale", "status", "--json"], 10)
    if rc != 0 or not out.strip():
        return ("warn", name, "读不到 tailscale status —— 无法确认接受了哪些子网路由")
    try:
        st = json.loads(out)
    except ValueError:
        return ("warn", name, "tailscale status 输出不是合法 JSON, 判据本次没跑")
    # 本机**接受**的路由: 其它节点通告、且本机装进了路由表的那些。
    routes = []
    for peer in (st.get("Peer") or {}).values():
        for r in (peer.get("PrimaryRoutes") or []):
            if r not in routes:
                routes.append(r)
    if not routes:
        return ("ok", name, "没有从别的节点接受任何子网路由, 不存在重叠")
    try:
        import lanroute
    except Exception:  # noqa: BLE001
        return ("warn", name, "取不到 lanroute 模块, 重叠判据本次没跑(装机清单里少了它?)")
    internal = _profile("PDG_INTERNAL_CIDR")
    locals_ = []
    for fam in ("-4", "-6"):
        rc, o, _ = _run(["ip", "-o", fam, "addr", "show", "scope", "global"], 8)
        if rc == 0:
            for line in o.splitlines():
                parts = line.split()
                if len(parts) > 3:
                    try:
                        locals_.append(lanroute.parse_net(parts[3]))
                    except ValueError:
                        pass
    inet = None
    if internal:
        try:
            inet = lanroute.parse_net(internal)
        except ValueError:
            inet = None
    bad = lanroute.judge(routes, inet, locals_)
    if not bad:
        note = "" if inet else "(注意: 读不到 PDG_INTERNAL_CIDR, 最要紧的那条判据没跑)"
        return ("ok" if inet else "warn", name,
                "接受的 %d 条路由都不与本机网段相交%s" % (len(routes), note))
    why = "; ".join("%s: %s" % (c, r[0][1]) for c, r in bad[:3])
    return ("fail", name,
            "接受的子网路由里有 %d 条会打乱本机数据面 —— %s。"
            "这类故障从配置上完全看不出来, 要在家里那侧改小通告范围。" % (len(bad), why))


def check_lan_whitelist():
    """门三: 内核里的出站白名单必须与面板表**逐条一致**。

    漂移的两个方向都危险, 但不是同一种危险:
      · 白名单多出面板表没有的地址 = 反代能连到不该连的地方(通常是删了面板没重新生成);
      · 白名单少了面板表里的地址 = 那个面板打不开, 而症状是 502, 看着像设备坏了。
    """
    name = "内网面板: 出站白名单"
    cfg = _lan_cfg()
    if cfg is None:
        return None                   # 从来没配过这个功能
    on, active = _lan_on()
    if not on:
        return ("ok", name, "内网面板已停用(面板表留着, pdg lan enable 可以随时回来) —— 不适用")
    lp = _lanpanel()
    if lp is None:
        return ("warn", name, "取不到 lanpanel 模块, 白名单判据本次没跑")
    try:
        want = set(lp.targets(cfg))
    except Exception as e:  # noqa: BLE001
        return ("warn", name, "面板表读不出目标(%s)" % e)
    # **不能用 nftlive.read_kernel()**: 它只取 `inet pdg` 那一张表, 看不见 pdglan ——
    # 用它的话这一项会永远报"表不存在", 而一个永远报红的检查等于没有。这里直接问那张表。
    rc, raw, err = _run(["nft", "-j", "list", "table", "inet", LAN_NFT_TABLE], 15)
    if rc != 0:
        # nft 明确说"没有这张表"与"nft 用不了"要分开: 前者是判据成立的一种结果,
        # 后者是判据没跑成 —— 混成一句会让缺权限的机器看起来像防火墙丢了。
        low = (err or "").lower()
        if "no such file" in low or "does not exist" in low:
            seen_table, have, obj = False, set(), None
        else:
            return ("warn", name, "读不到 inet %s 表(%s)" % (LAN_NFT_TABLE, (err or "").strip()[:120]))
    else:
        try:
            obj = json.loads(raw)
        except ValueError:
            return ("warn", name, "nft -j 输出不是合法 JSON, 白名单判据本次没跑")
        seen_table = True
        have = set()
    for item in ((obj or {}).get("nftables", []) if obj else []):
        rule = item.get("rule")
        if not rule or rule.get("table") != LAN_NFT_TABLE:
            continue
        ip_, port = None, None
        for ex in rule.get("expr", []):
            m = ex.get("match")
            if not m:
                continue
            left, right = m.get("left", {}), m.get("right")
            pl = left.get("payload") or {}
            if pl.get("field") == "daddr" and isinstance(right, str):
                ip_ = right
            elif pl.get("field") == "dport" and isinstance(right, int):
                port = right
        if ip_ and port:
            have.add((ip_, port))
    if not seen_table:
        if not want:
            return ("ok", name, "面板表是空的, 也没有白名单表 —— 一致")
        if active:
            # 反代**正在跑**而白名单不在 = 这个进程此刻能连到内网任意地址。门三本来靠
            # ExecStartPre 挡住这种状态, 走到这里说明有人在服务起来之后把表删了。
            return ("fail", name,
                    "反代正在运行, 但内核里没有 inet %s 表 —— 它此刻**能连到内网任意地址**。"
                    "立刻 sudo pdg lan render 再 sudo systemctl restart pdg-lan。" % LAN_NFT_TABLE)
        return ("warn", name,
                "启用意图开着, 但反代没在跑、白名单也不在 —— 功能实际上是停的。"
                "要用就 sudo pdg lan enable, 不用就 sudo pdg lan disable 把意图也改掉。")
    extra, miss = have - want, want - have
    if not extra and not miss:
        return ("ok", name, "白名单与面板表逐条一致(%d 个上游)" % len(want))
    parts = []
    if extra:
        parts.append("白名单多出 %s —— 反代能连到面板表之外的地址"
                     % ", ".join("%s:%d" % t for t in sorted(extra)[:3]))
    if miss:
        parts.append("白名单缺少 %s —— 那些面板会以 502 打不开, 看着像设备坏了"
                     % ", ".join("%s:%d" % t for t in sorted(miss)[:3]))
    return ("fail", name, "; ".join(parts) + "。跑 sudo pdg lan render 后重启 pdg-lan。")


def check_lan_cert():
    """面板证书的剩余天数。

    反代读的是**落盘的**证书, 它自己不去续 —— 续期靠 acme.sh 装的 cron。那条链断掉时
    不会有任何报错, 直到某天所有面板一起打不开。所以这一项存在的意义就是提前那两周。

    判据用 `openssl x509 -checkend`(与 check_cert 同一个惯用法), 不自己解析日期字符串:
    notAfter 的格式带时区缩写, strptime 在不同 locale 下解出来的东西不一样。
    """
    name = "内网面板: 证书"
    cfg = _lan_cfg()
    if cfg is None:
        return None
    on, _active = _lan_on()
    if not on:
        return None                   # 停用中: 证书过不过期都不影响任何东西
    panels = [p for p in cfg.get("panels", []) if isinstance(p, dict) and p.get("name")]
    if not panels:
        return None
    # 所有面板**共用一张 SAN 证书**。所以判据有两层, 缺一不可:
    #   ① 这张证书本身没过期;
    #   ② 它的 SAN 覆盖了**每一个**面板 —— 加了面板却没重签时文件照样在、也没过期,
    #      而新面板的名字不在 SAN 里, 手机上是证书错误。只看文件在不在会漏掉这一整类。
    # **一律不用 fail。**`pdg update` 跑完自检, 任何 fail 都会让整次更新回滚 —— 而面板
    # 证书出问题只是"面板打不开", 不该把一个修了 DNS/代理缺陷的更新一起挡掉。
    # 真机上撞过: 在 v1.10.7 启用过面板的机器升级时, 因为证书布局变了(一板一张 → 共用
    # 一张 SAN)这一项判 fail, 于是**每次更新都回滚, 永远升不上来**。
    # 危险的那种状态(反代在跑而白名单不在)由 check_lan_whitelist 负责, 那一项才该 fail。
    crt = os.path.join(LAN_CERT_DIR, "panel.crt")
    if not os.path.exists(crt):
        old = [f for f in os.listdir(LAN_CERT_DIR)] if os.path.isdir(LAN_CERT_DIR) else []
        hint = ("(检测到旧版一板一张的证书布局: %s —— `sudo pdg lan render` 会自动搬过来)"
                % ", ".join(sorted(x for x in old if x.endswith(".crt"))[:4])) if old else ""
        return ("warn", name, "没有 %s, 面板打不开 —— 跑 sudo pdg lan cert <dns插件名> 签发%s"
                % (crt, hint))
    rc, out, _ = _run(["openssl", "x509", "-in", crt, "-noout", "-ext", "subjectAltName"], 8)
    if rc != 0:
        return ("warn", name, "证书读不出来(openssl rc=%d), 本项无结论" % rc)
    sans = {x.strip().replace("DNS:", "") for x in (out or "").replace("\n", ",").split(",")
            if "DNS:" in x}
    absent = [p["host"] for p in panels if p.get("host") and p["host"] not in sans]
    if absent:
        return ("warn", name,
                "证书的 SAN 里没有这些面板: %s —— 手机上访问它们会是证书错误。"
                "加过面板就要重签(所有面板共用一张证书): sudo pdg lan cert <dns插件名>"
                % ", ".join(absent[:5]))
    rc, _, _ = _run(["openssl", "x509", "-checkend", "0", "-noout", "-in", crt], 8)
    if rc != 0:
        return ("warn", name, "证书已过期 —— 面板全部打不开(不影响分流与 DNS)")
    rc, _, _ = _run(["openssl", "x509", "-checkend", str(14 * 86400), "-noout", "-in", crt], 8)
    if rc != 0:
        return ("warn", name, "证书 14 天内到期 —— 续期链(acme.sh 的 cron)可能已经断了, "
                              "它断掉时不会有任何报错")
    return ("ok", name, "一张 SAN 证书覆盖 %d 个面板, 还有 14 天以上" % len(panels))



def _lan_probe_target(cfg):
    """在面板所在网段里**猜**一个不在面板表里的地址, 用来发现明显的越界。

    这个地址只能往一个方向读: 连上了、或者收到 RST, 说明包**到达了对端**, 那是确凿的
    越界证据。反过来不成立 —— 猜出来的地址本来就可能没有设备, "探不到"既可能是 ACL 把
    包丢了, 也可能是那儿压根没人。两种情形给出完全相同的观测, 所以探不到**不能**反推
    Access controls 已收紧。要把"探不到"读成安全, 需要一个已知存活、又在面板表之外的
    对照地址(canary)来校准, 而那个信息网关自己猜不出来。

    返回 (ip, port, 参照的面板 IP) 或 None。
    """
    import ipaddress
    tgts = []
    lp = _lanpanel()
    if lp is None:
        return None
    try:
        tgts = lp.targets(cfg)
    except Exception:  # noqa: BLE001
        return None
    for ip_s, port in tgts:
        try:
            ip = ipaddress.ip_address(ip_s)
        except ValueError:
            continue
        if ip.version != 4:
            continue
        net = ipaddress.ip_network("%s/24" % ip_s, strict=False)
        used = {t[0] for t in tgts}
        # 从网段末尾往回找一个没被用到的主机位 —— 靠后的地址通常没有设备,
        # 探它比探 .1(往往是路由器)更不容易打扰到真在跑的东西。
        for host in list(net.hosts())[::-1][:8]:
            if str(host) not in used:
                return (str(host), port, ip_s)
    return None


_ACL_UNVERIFIED = (
    "%s:%d(面板表之外)%s —— 但这**无法证明** Access controls 已收紧。这个地址是猜出来"
    "的, 它上面本来就可能没有设备; 那种情况下 tailnet 哪怕还是默认的 allow-all, 观测到"
    "的也是同一个结果。要把这项读成绿灯, 得有一个**已知存活、又在面板表之外**的对照地址"
    "(canary)先把仪器校准, 而那个信息网关自己猜不出来。本项只能发现越界, 不能出具安全"
    "证明 —— 请到 tailnet 后台按 docs/design-lan-panels.md 第 4 节人工核对 Access "
    "controls。"
)


def check_deep_lan_acl():
    """tailnet ACL 越界探测(慢速, 只在 --deep 跑)。

    设计文档第 4 节把这条列为"能测出来的, 不是只能靠嘱咐": **真正的硬边界在家里那台
    子网路由器上** —— Tailscale 的包过滤在目标节点执行, 所以网关就算被 root 了, 往
    ACL 之外的地址发包也会被家里那台丢掉。项目管不了用户的 tailnet 后台, 但可以探。

    只是这个探测**不对称**, 能出结论的只有一个方向:
      · 连上了        → 包到达了对端 → 放行了面板表之外的地址 → fail
      · 连接被拒(RST) → 包同样到达了对端才会有这个回应       → fail
      · 不可达/超时   → **无结论**。探的地址是猜的, 它可能根本不存在, 那时 ACL 收没收紧
                        都是这一个观测。没有已知存活的对照地址(canary)校准仪器, 量到的
                        东西反推不出 Access controls 的状态 → warn

    早先这里把超时和不可达判成 ok, 文案写"ACL 边界成立"。那是个假绿: 它证明的只是
    "这个猜出来的地址没有回应"。见 tests/negctl/lan-acl-false-green.py。

    探测**以 root 身份发起**, 因此不受门三(出站白名单)约束 —— 那是有意的: 门三管的是
    反代进程, 而这一项要量的是**家里那侧**的过滤器。用受限身份去探, 量到的会是自己的
    防火墙, 那等于什么都没验。
    """
    name = "内网面板: tailnet ACL 边界(deep)"
    cfg = _lan_cfg()
    if cfg is None:
        return None
    on, _active = _lan_on()
    if not on:
        return None
    pick = _lan_probe_target(cfg)
    if pick is None:
        return ("warn", name, "挑不出可用的探测地址(面板表里没有 IPv4 上游?), 本项没跑")
    ip_, port, ref = pick
    import socket
    s = socket.socket()
    s.settimeout(4)
    try:
        s.connect((ip_, port))
        s.close()
        return ("fail", name,
                "从网关能连上 %s:%d —— 它**不在**面板表里, 说明 tailnet ACL 没有收窄到"
                "只允许那几个 IP:端口。一台被拿下的网关因此能摸到你家整个网段。"
                "去 tailnet 后台按 docs/design-lan-panels.md 第 4 节的模板配 ACL。" % (ip_, port))
    except socket.timeout:
        return ("warn", name, _ACL_UNVERIFIED % (ip_, port, "连不上"))
    except ConnectionRefusedError:
        return ("fail", name,
                "%s:%d 回了 RST —— 包**到达了对端**才会有这个回应, 说明 tailnet ACL 放行了"
                "面板表之外的地址(参照面板 %s)。ACL 该做的是把它丢掉, 而不是让对端拒绝。"
                % (ip_, port, ref))
    except OSError as e:
        # EHOSTUNREACH(113)/ENETUNREACH(101) = 包被丢在半路。看着像 ACL 在起作用, 但
        # 地址不存在时也是这个结果, 所以同样只能记成无结论。
        if getattr(e, "errno", None) in (101, 113):
            return ("warn", name, _ACL_UNVERIFIED % (ip_, port, "被丢弃"))
        return ("warn", name, "探测没跑成(%s), 本项无结论" % e)
    finally:
        try:
            s.close()
        except OSError:
            pass


ALL = [check_platform, check_services, check_bot_credentials, check_health_timer, check_core_version, check_dot_arecord, check_dot_domain_sync,
       check_internal_cidr, check_cidr_drift, check_nft, check_nft_input_chains, check_redirect, check_gms,
       check_tailscale_isolation, check_tailscale_residue, check_tailnet_direct_port,
       check_lan_routes, check_lan_whitelist, check_lan_cert,
       check_mosdns_ratelimit, check_mosdns_explicit_proxy, check_ruleset_hijack,
       check_nft_extra, check_rescue_firewall, check_geosite_db, check_mem,
       check_cert, check_cert_dir_sync, check_dns, check_core_config, check_rulesets, check_rule_precedence,
       check_mitm_structure, check_mitm, check_transactions]
ALERT = [check_services, check_dns, check_cert]  # healthcheck 用的轻量子集(运行期故障)
DEEP = [check_deep_lan_acl,
        check_deep_dot_handshake, check_deep_probe81, check_deep_dot_witness, check_deep_dns_cn,
        check_deep_clash, check_deep_upstreams, check_deep_hijack_note]  # pdg doctor --deep 追加

def run(funcs=None):
    # 每轮开头清掉防火墙判定缓存: 缓存的作用是"这一轮里三个检查项共用同一次 nft 查询",
    # 不是"这台机器的防火墙状态一辈子不变"。Bot 是长驻进程, 不清等于第二次 doctor 拿的是
    # 上一次的旧结论。
    _nft_view_reset()
    return [r for f in (funcs or ALL) if (r := f()) is not None]   # 平台不相关的 check 返回 None → 跳过不显示

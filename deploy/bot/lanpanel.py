#!/usr/bin/env python3
"""内网面板(方案 B)的面板表: 校验(门二)、反代配置生成、出站白名单派生(门三的输入)。

**门二 = 反代只做白名单映射。**域名到 `IP:端口` 一对一, 不接受通配、不按 Host 动态解析
目标。否则任何能触发 SNI 的人都能让网关去连家里的任意地址 —— 反代会老老实实照做, 因为
"按 Host 找上游"正是反代的本职。

这里有一条比设计文档更严的要求: **上游必须写字面 IP, 不接受域名。**写域名的话, 决定
网关去连哪台机器的是 DNS 而不是这份表 —— 而这台网关自己就是做 DNS 劫持的, 上游解析结果
被换掉时白名单一个字都不用改。门三按这份表派生放行规则, 表里是域名就没法派生。

生成而不是让用户手写反代配置, 与 mihomo 配置由 sb2mihomo.py 渲染同一个理由: 手写的那份
迟早与面板表不一致, 而不一致的方向恰恰是"防火墙按表放行、反代按手写的连别处"。

用法:
  lanpanel.py check   <表.json>              校验(门二), 0=通过 2=有问题
  lanpanel.py list    <表.json>              人看的面板清单
  lanpanel.py add     <表.json> --name .. --host .. --target ..   生成加了一条的**候选表**
  lanpanel.py rm      <表.json> <name>       生成删了一条的候选表
  lanpanel.py zone-risk <表.json> <DoT域名>  风险②: 面板域名与 DoT 是否同 zone
  lanpanel.py render  <表.json> --certs <目录> [--bind <地址>]   生成 Caddyfile
  lanpanel.py targets <表.json>              列出 IP<TAB>端口, 供防火墙白名单使用
  lanpanel.py nft     <表.json> --uid <用户>  门三: 出站白名单的 nft 规则
"""
import ipaddress
import json
import re
import sys

# 面板名: 用来做文件名和日志标识, 限死字符集免得后面到处转义。
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
# 主机名: 普通域名。**明确不接受通配**(`*.` 开头) —— 那正是门二要挡的东西。
HOST_RE = re.compile(r"^(?!-)[a-z0-9-]{1,63}(\.(?!-)[a-z0-9-]{1,63})+$")

KNOWN_KEYS = {
    "name", "host", "target", "insecure_upstream",
    "rewrite_location", "fix_referer", "legacy_tls", "entry_query",
}


class PanelError(Exception):
    pass


def _err(lst, panel_ix, msg):
    lst.append("第 %d 条面板: %s" % (panel_ix + 1, msg))


def parse_target(t):
    """拆 `scheme://IP[:port]`, 返回 (scheme, ip, port)。

    只认 http / https, 只认字面 IP。端口省略时按 scheme 取默认值 —— 派生防火墙规则要用到
    具体端口, "默认端口"这件事不能留给两个地方各猜一次。
    """
    # 先只拆形状, **不在正则里限定必须是 IP**: 那样写域名的人只会看到一句"格式不对",
    # 而真正该告诉他的是"这里不能写域名, 因为决定连哪台机器的会变成 DNS"。
    m = re.match(r"^(https?)://(\[[0-9a-fA-F:]+\]|[^/:\s]+)(?::([0-9]{1,5}))?/?$", t or "")
    if not m:
        raise PanelError("上游要写成 http(s)://<字面 IP>[:端口], 收到的是 %r" % (t,))
    scheme, host, port = m.group(1), m.group(2), m.group(3)
    host = host.strip("[]")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        raise PanelError("上游 %r 不是字面 IP —— 写域名的话决定连哪台机器的是 DNS 而不是这份表, "
                         "而这台网关自己就在做 DNS 劫持" % host)
    if ip.is_loopback:
        raise PanelError("上游 %s 是环回地址 —— 那指向网关自己, 不是家里的设备" % ip)
    p = int(port) if port else (443 if scheme == "https" else 80)
    if not (1 <= p <= 65535):
        raise PanelError("端口 %s 不在 1-65535" % port)
    return scheme, str(ip), p


def validate(cfg):
    """返回问题列表(空 = 通过)。一次把所有问题列全, 不在第一条就返回 ——
    用户改一条跑一次、再撞下一条, 那种来回是能一次说完的。"""
    errs = []
    if not isinstance(cfg, dict):
        return ["面板表最外层要是一个 JSON 对象"]
    panels = cfg.get("panels")
    if not isinstance(panels, list):
        return ['面板表缺 "panels" 数组']
    seen_name, seen_host, seen_target = {}, {}, {}
    for i, p in enumerate(panels):
        if not isinstance(p, dict):
            _err(errs, i, "要是一个对象")
            continue
        unknown = set(p) - KNOWN_KEYS
        if unknown:
            # 不静默忽略: 拼错的键(比如 insecure_upstrem)会让一个本该显式的决定变成默认值,
            # 而默认值恰好是更宽松的那个。
            _err(errs, i, "有认不出的字段 %s —— 拼错的话本该显式的决定会静默变成默认值"
                 % ", ".join(sorted(unknown)))

        name = p.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            _err(errs, i, "name 要是 [a-z0-9-] 的短名(收到 %r)" % (name,))
        elif name in seen_name:
            _err(errs, i, "name %r 与第 %d 条重复" % (name, seen_name[name] + 1))
        else:
            seen_name[name] = i

        host = p.get("host")
        if not isinstance(host, str) or not HOST_RE.match(host or ""):
            if isinstance(host, str) and host.startswith("*"):
                _err(errs, i, "host %r 是通配 —— 门二不接受通配: 那等于让任何能触发 SNI 的人"
                              "决定网关去连谁" % host)
            else:
                _err(errs, i, "host 要是普通域名(收到 %r)" % (host,))
        elif host in seen_host:
            _err(errs, i, "host %r 与第 %d 条重复 —— 同一个域名指两个上游, "
                          "实际生效的是哪个取决于反代的实现细节" % (host, seen_host[host] + 1))
        else:
            seen_host[host] = i

        try:
            scheme, ip, port = parse_target(p.get("target"))
        except PanelError as e:
            _err(errs, i, str(e))
        else:
            key = (ip, port)
            if key in seen_target:
                # 不是错误, 但值得说: 两个域名指同一台设备的同一个端口通常是笔误
                pass
            seen_target[key] = i
            if scheme == "https" and p.get("insecure_upstream") is None:
                _err(errs, i, "上游是 https, 必须显式写 insecure_upstream —— 家用设备几乎都是"
                              "自签证书, 但\"默认跳过校验\"是错的: 那该由你按设备逐个确认")

        for k in ("insecure_upstream", "rewrite_location", "fix_referer", "legacy_tls"):
            v = p.get(k)
            if v is not None and not isinstance(v, bool):
                _err(errs, i, "%s 要是 true/false(收到 %r)" % (k, v))

        q = p.get("entry_query")
        if q is not None and (not isinstance(q, str) or not re.match(r"^[A-Za-z0-9_.=&%-]{1,200}$", q)):
            _err(errs, i, "entry_query 要是查询串片段, 如 magicpath=xxxx(收到 %r)" % (q,))

    return errs


def targets(cfg):
    """派生出站白名单需要的 (IP, 端口) 集合 —— 门三按它放行, 与反代读同一份表。"""
    out = []
    for p in cfg.get("panels", []):
        if not isinstance(p, dict):
            continue
        try:
            _, ip, port = parse_target(p.get("target"))
        except PanelError:
            continue
        if (ip, port) not in out:
            out.append((ip, port))
    return out


def render_caddy(cfg, certs_dir, bind="127.0.0.1"):
    """由面板表生成 Caddyfile。

    这些改写能力**从第一版就带上**, 不等踩到再补: 方案 A 在七台真机上逐个踩过一遍(见
    docs/design-lan-panels.md 第 6 节), 它们是设备的毛病, 与反代跑在哪台机器上无关。
    """
    errs = validate(cfg)
    if errs:
        raise PanelError("面板表没通过校验, 拒绝生成:\n" + "\n".join("  " + e for e in errs))

    L = []
    L.append("# 由 lanpanel.py 生成 —— 不要手改。改面板用 `pdg lan add/rm`。")
    L.append("# 手改的那份迟早与面板表不一致, 而不一致的方向恰恰是"
             "\"防火墙按表放行、反代按手改的连别处\"。")
    L.append("{")
    L.append("\tadmin off")
    # 证书由 acme.sh 签发落盘, Caddy 不自己去要 —— 那样才不必为每个 DNS 服务商单独构建。
    L.append("\tauto_https off")
    L.append("}")
    L.append("")

    for idx, p in enumerate(cfg["panels"]):
        scheme, ip, port = parse_target(p["target"])
        host = p["host"]
        name = p["name"]
        up = "%s://%s:%d" % (scheme, ip, port)
        # 给设备看的地址: 默认端口不写出来(见下面 fix_referer 那段的理由)。
        default_port = 443 if scheme == "https" else 80
        up_display = up if port != default_port else "%s://%s" % (scheme, ip)
        # 正则里的点要转义 —— 不转义的话 `.` 会匹配任意字符, 改写范围比预期大。
        ip_re = re.escape(ip)
        host_re = re.escape(host)

        L.append("# 面板 %s" % name)
        L.append("%s:443 {" % host)
        L.append("\tbind %s" % bind)
        # **所有面板共用一张证书**, 不是一板一张。acme.sh `--issue -d A -d B ...` 产出的
        # 就是一张覆盖全部名字的 SAN 证书 —— 按域名逐个去装会对除第一个之外的全部失败
        # (它们没有各自的证书目录)。真机上踩过: 7 个面板只装上 1 个。
        # 代价要知道: 加一个面板必须重签整张证书, 而且一个名字签不下来会连累全部。
        # doctor 的证书项因此还要核对 SAN 是否覆盖了每个面板 —— 见 check_lan_cert。
        L.append("\ttls %s/%s %s/%s" % (certs_dir, CERT_CRT, certs_dir, CERT_KEY))

        if p.get("entry_query"):
            # 前后端分离的应用(sub-store 之类)要在入口带参数, 否则每台设备都得手输后端地址。
            #
            # 判据必须是"根路径 **而且还没带这个参数**"。只判路径的话, 跳到 `/?k=v` 之后
            # 路径**仍然是 `/`** —— 于是再跳一次, 无限循环, 浏览器报"重定向次数过多"。
            # 真机上撞过: 从网关用 curl 不跟跳转只看到第一个 302, 看着一切正常, 而手机上
            # 根本打不开。
            key = p["entry_query"].split("=", 1)[0]
            L.append("\t@entry {")
            L.append("\t\tpath /")
            L.append("\t\tnot query %s=*" % key)
            L.append("\t}")
            L.append("\tredir @entry /?%s 302" % p["entry_query"])

        L.append("\treverse_proxy %s {" % up)
        if scheme == "https":
            L.append("\t\ttransport http {")
            L.append("\t\t\ttls")
            if p.get("insecure_upstream"):
                L.append("\t\t\ttls_insecure_skip_verify")
            L.append("\t\t}")
        # 指向**本域名**却带着上游端口(或 http)的 Location, 无条件规范化。
        #
        # 上游只要遵从 Host 头就会这么干 —— Apache 的 UseCanonicalName Off 是默认行为,
        # 它把 Host 原样回显、再补上自己实际监听的端口:
        #     http://nas.example.com:30035/dir/
        # 主机名是对的, 错的是 scheme 和端口。而反代只在 443 上, 客户端跟着跳必然到不了,
        # 表现是浏览器卡在"服务器已停止响应"。真机上撞过: TrueNAS 的 WebDAV(Apache,
        # 30035)对不带结尾斜杠的目录发 301, iPhone 跟过去就死在那儿。
        #
        # **不挂在 rewrite_location 后面**, 因为这条不需要用户判断: Location 指向本域名
        # 却带上游端口, 对客户端永远是坏的, 不存在"用户可能想要"的情形。上面那条不一样 ——
        # 改写上游 IP 是设备特性, 得由用户按设备确认。
        #
        # 端口段之后必须有个**边界**, 否则 `nas.example.com.evil.com` 会被前缀匹配吃进来。
        #
        # 边界是 `/` `?` `#` 或**字符串结尾**四选一, 不能只认 `/`。RFC 3986 里 authority
        # 之后可以直接跟 query、fragment, 或者干脆到此为止 —— `http://HOST:30035` 是完全
        # 合法的 Location。早先只认 `/`, 理由写的是"Location 总是带路径" —— 那是拍脑袋的
        # 断言不是事实, 于是无路径 / 直接跟 `?` / 直接跟 `#` 三种形态全漏, 而静态测试对此
        # 一路绿灯。补这一条的同时新增了 tests/test-lan-location-live.sh: 起真 Caddy、打真
        # 响应头, 因为"生成的文本长这样"和"头真的被改了"是两回事。
        #
        # 边界那一段要**原样带回**替换结果, 所以用 $2 引回去 —— 少了它 `?x=1` 会被吃掉。
        L.append("\t\theader_down Location \"^https?://%s(:[0-9]+)?(/|\\?|#|$)\" \"https://%s$2\""
                 % (host_re, host))
        if p.get("rewrite_location"):
            # 设备会把自己的局域网 IP 写进 Location 跳转头(Zyxel 交换机、华为 UPS 实测)。
            # 不改写的话手机会跟着跳到一个到不了的地址。
            #
            # 用**一条正则**覆盖 http/https 与"带不带端口", 而不是几条字面替换: 设备回的
            # Location 可能是 `https://IP`、`https://IP:443`、`http://IP` 里的任意一种,
            # 逐条穷举总会漏, 而漏掉的那种表现是手机跳到一个到不了的地址。
            L.append("\t\theader_down Location \"https?://%s(:[0-9]+)?\" \"https://%s\""
                     % (ip_re, host))
        if p.get("fix_referer"):
            # 有些设备校验 Referer/Origin 必须是自己的地址(华为 UPS2000 实测, 否则返回
            # Error Referer Request!)。
            #
            # **是"替换"不是"设置"**。写成无条件设置的话, 客户端本来没带 Referer 的请求
            # (浏览器首次导航就不带)会被硬塞一个进去 —— 那是伪造一个不存在的来源, 严格
            # 校验的设备照样会拒。这里只把**已经存在的**那个头里的对外域名换回上游地址,
            # 路径部分原样保留。
            #
            # 替换成的地址不带默认端口, 与方案 A 的写法一致, 也更接近 origin 的规范形式。
            # **但这一条不是实测出来的**: 对华为 UPS2000 直接试过, 带不带 `:443` 都一样
            # 返回 404 —— 决定性的是上面那条"不要凭空塞一个 Referer", 不是端口。
            # 不把没量到的东西写成量到的。
            # 判据是"**有没有** Referer", 不是"它指向谁":
            #   · 没有  → 不加(浏览器首次导航就不带; 凭空塞一个进去等于伪造来源, 严格
            #             校验的设备照样拒 —— 华为 UPS2000 实测)
            #   · 有    → **不管指向谁**, 一律换成上游地址
            # 早先只替换"指向本域名"的那种, 于是从 Telegram 按钮点进来时(Referer 是
            # t.me / android-app://…)规则匹配不上, 外来 Referer 原样透传, 设备回
            # "Error Referer Request!"。真机复现过 —— 而这个洞是加了按钮之后才被触发的:
            # 以前手输网址不带 Referer, 一直没暴露。
            # 形式是 `header_up <名> <正则> <替换>` —— 三个参数那种是**在已有的头上做替换**,
            # 头不存在时什么都不做。正则写成 `.*` 就是"不管原来指向谁, 一律换掉"。
            #
            # **不能用 @matcher**: `header_up` 在 reverse_proxy 里不支持请求匹配器(那是站点级
            # `header` 指令才有的)。写了 `header_up @x Referer "值"` 的话 Caddy 会把 @x 当成
            # **头的名字**, 于是变成"给一个叫 @x 的头做替换", 真 Referer 原样透传 ——
            # 而 `caddy validate` 照样通过(它只验语法)。真机上踩过, adapt 成 JSON 才看出来。
            L.append("\t\theader_up Referer \".*\" \"%s/\"" % up_display)
            L.append("\t\theader_up Origin \".*\" \"%s\"" % up_display)
        L.append("\t}")
        L.append("}")
        L.append("")

    return "\n".join(L)


def shared_zone(a, b):
    """两个域名共同的父域(按标签从右往左比)。只有一个标签(纯 TLD)时返回 None ——
    example.com 与 example.net 共有 "com" 不说明任何事。"""
    la = [x for x in (a or "").lower().strip(".").split(".") if x]
    lb = [x for x in (b or "").lower().strip(".").split(".") if x]
    common = []
    for x, y in zip(reversed(la), reversed(lb)):
        if x != y:
            break
        common.append(x)
    if len(common) < 2:
        return None
    return ".".join(reversed(common))


def zone_risk(cfg, dot_domain):
    """风险②: 签发面板证书用的 DNS token 会不会顺带能签发本项目自己的 DoT 域名。

    为什么这是**权限升级**而不只是"多一个凭据": Cloudflare 这类服务商的 token 按 zone 授权,
    而面板域名与 DoT 域名通常在同一个 zone 里。那么一台被拿下的网关可以用这个 token 签发
    `dot.example.com` 的证书, 进而 MITM 用户自己的 DNS —— 而 DoT 正是这个项目存在的理由。
    面板被看到是一回事, DNS 被劫持是另一回事。

    判据是"共同父域至少两个标签"。这是对 eTLD+1 的近似 —— 不引 public suffix list:
    多带一份要跟着上游更新的数据, 而这里**宁可多报**: 报错了用户看一眼就知道不相干,
    漏报了他会在不知情的情况下把 DoT 的签发权交出去。

    返回 [(面板 host, 共同父域), ...], 空 = 没有这个风险。
    """
    if not dot_domain:
        return []
    out = []
    for p in cfg.get("panels", []):
        if not isinstance(p, dict):
            continue
        h = p.get("host")
        z = shared_zone(h, dot_domain)
        if z:
            out.append((h, z))
    return out


# 共用证书的文件名。面板表变了要重签, 所以名字与面板无关。
CERT_CRT = "panel.crt"
CERT_KEY = "panel.key"

NFT_TABLE = "pdglan"


def render_nft(cfg, uid):
    """门三: 反代进程的**出站白名单**。除了面板表里出现过的 IP:端口, 它什么都连不到。

    按 uid 过滤而不是按端口 —— 端口挡不住"别的进程发起同样的连接"。uid 才是"这些包是反代
    发的"这件事的判据。

    比设计文档更严: 文档说的是"只允许经 tailscale0 访问白名单", 这里做成**不分接口**的
    白名单。反代的合法出站本来就只有那几个上游 —— 上游必须是字面 IP(见 parse_target),
    所以它连 DNS 都不需要。多留一个"经别的接口可以随便连"的口子没有任何用途, 只是攻击面。

    为什么可以用独立的表(与救援平面当年的教训相反):
      · 救援平面那次栽在 **input** 方向 —— 同一 hook 上多条 base chain 都会执行, 别的链里的
        `accept` 终止不了本链, `inet pdg` 的 policy drop 照样把包丢掉, 于是独立表里的放行
        形同虚设。
      · 这里是 **output** 方向而且判决是 `reject` —— drop/reject 是跨链终局的, 任一条链拒了
        包就没了。所以独立表在这个方向上成立。
      · 而且 doctor/nftscan 的冲突判据只认 `hook input`(见 nftscan.py 的 _HOOK_IN),
        挂 output 不会被自己的自检判成冲突 —— 那正是救援平面独立表当年踩的第二个坑。

    **这份规则是 fail-open 的**: 文件加载失败时白名单就不存在, 而反代照跑。所以调用方必须
    把它挂成反代 unit 的 ExecStartPre —— 加载不上就别启动。这一条不是建议, 是这道门能不能
    成立的前提。
    """
    errs = validate(cfg)
    if errs:
        raise PanelError("面板表没通过校验, 拒绝生成防火墙规则:\n" + "\n".join("  " + e for e in errs))
    if not (isinstance(uid, str) and re.match(r"^[a-z_][a-z0-9_-]{0,31}$", uid)):
        raise PanelError("uid 要是用户名(收到 %r)" % (uid,))

    L = []
    L.append("#!/usr/sbin/nft -f")
    L.append("# 由 lanpanel.py 生成 —— 不要手改。")
    L.append("# 反代进程(%s)的出站白名单: 只有面板表里出现过的 IP:端口。" % uid)
    L.append("# 必须挂成反代 unit 的 ExecStartPre —— 这份加载不上就不该让反代跑起来。")
    L.append("table inet %s" % NFT_TABLE)
    L.append("delete table inet %s" % NFT_TABLE)
    L.append("table inet %s {" % NFT_TABLE)
    L.append("\tchain output {")
    L.append("\t\ttype filter hook output priority filter; policy accept;")
    L.append("\t\t# 不是反代发的包, 本链一概不管")
    L.append('\t\tmeta skuid != "%s" accept' % uid)
    L.append("\t\t# 回给本机的响应(反代监听在环回上, 由 mihomo 拨进来)")
    L.append("\t\toif lo accept")
    tgts = targets(cfg)
    if tgts:
        L.append("\t\t# ── 白名单: 与反代读同一份面板表派生 ──")
    for ip, port in tgts:
        fam = "ip6" if ":" in ip else "ip"
        L.append("\t\t%s daddr %s tcp dport %d accept" % (fam, ip, port))
    L.append("\t\t# 其余一律拒。用 reject 而不是 drop: 反代会立刻拿到错误并回 502,")
    L.append("\t\t# 而 drop 要等到超时 —— 那时故障看起来像\"设备很慢\", 不像\"被挡了\"。")
    L.append("\t\treject with icmpx admin-prohibited")
    L.append("\t}")
    L.append("}")
    return "\n".join(L) + "\n"


def legacy_tls_panels(cfg):
    """需要放宽 TLS 套件的面板名。

    老设备可能只提供 AES256-GCM-SHA384(RSA 密钥交换), Go 1.22 起默认禁用 —— 表现是 502
    加 handshake failure, **看着像证书问题**。这不是靠 Caddyfile 能解决的, 要给进程加
    GODEBUG=tlsrsakex=1, 所以单独列出来给 unit 生成用。
    """
    return [p["name"] for p in cfg.get("panels", []) if isinstance(p, dict) and p.get("legacy_tls")]


def add_panel(cfg, panel):
    """返回**新的**面板表(不改原对象, 不写盘)。

    与 cidrgen.py 同一个规矩: 这里只从现有内容生成候选内容, 落盘、校验、观察、回滚全交给
    pdgtx。于是"改到一半失败"这种状态不存在 —— 要么整张新表生效, 要么原样不动。

    候选**整体**过一次校验, 不只校验新增那条: 新面板可能与既有面板撞 name 或 host, 那种
    冲突只有把整张表放在一起看才发现得了。
    """
    panels = list(cfg.get("panels", []))
    panels.append(panel)
    cand = dict(cfg)
    cand["panels"] = panels
    errs = validate(cand)
    if errs:
        raise PanelError("加进去之后这张表就不合法了, 拒绝改动:\n" + "\n".join("  " + e for e in errs))
    return cand


def rm_panel(cfg, name):
    """按 name 删一条。删不到就报错而不是静默成功 —— "删了个不存在的东西"和"删掉了"
    在事后看起来一模一样, 而用户以为面板已经没了。"""
    panels = list(cfg.get("panels", []))
    left = [p for p in panels if not (isinstance(p, dict) and p.get("name") == name)]
    if len(left) == len(panels):
        have = [p.get("name") for p in panels if isinstance(p, dict)]
        raise PanelError("没有名叫 %r 的面板。现有: %s"
                         % (name, ", ".join(have) if have else "(一个都没有)"))
    cand = dict(cfg)
    cand["panels"] = left
    return cand


def dumps(cfg):
    """落盘用的文本。固定 indent 与 key 顺序 —— 事务要比对 before/after, 格式抖动会让
    "没改内容"的一次操作看起来像改过。"""
    return json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[-4])
        return 3
    mode, path = argv[1], argv[2]
    try:
        cfg = load(path)
    except (OSError, ValueError) as e:
        print("读不了面板表 %s: %s" % (path, e))
        return 3

    if mode == "check":
        errs = validate(cfg)
        for e in errs:
            print(e)
        return 2 if errs else 0

    if mode == "add":
        # lanpanel.py add <表> --name x --host y --target z [--insecure|--no-insecure]
        #                     [--rewrite-location] [--fix-referer] [--legacy-tls] [--entry-query q]
        panel, rest = {}, argv[3:]
        flags = {"--rewrite-location": "rewrite_location", "--fix-referer": "fix_referer",
                 "--legacy-tls": "legacy_tls"}
        while rest:
            a = rest[0]
            if a in ("--name", "--host", "--target", "--entry-query") and len(rest) > 1:
                panel[a[2:].replace("-", "_")] = rest[1]; rest = rest[2:]
            elif a == "--insecure":
                panel["insecure_upstream"] = True; rest = rest[1:]
            elif a == "--no-insecure":
                panel["insecure_upstream"] = False; rest = rest[1:]
            elif a in flags:
                panel[flags[a]] = True; rest = rest[1:]
            else:
                print("认不出的参数: %s" % a)
                return 3
        try:
            sys.stdout.write(dumps(add_panel(cfg, panel)))
        except PanelError as e:
            print(str(e))
            return 2
        return 0

    if mode == "rm":
        if len(argv) < 4:
            print("rm 要给面板名")
            return 3
        try:
            sys.stdout.write(dumps(rm_panel(cfg, argv[3])))
        except PanelError as e:
            print(str(e))
            return 2
        return 0

    if mode == "list":
        panels = cfg.get("panels", [])
        if not panels:
            print("(还没有面板)")
            return 0
        for p in panels:
            if not isinstance(p, dict):
                continue
            marks = [k for k in ("rewrite_location", "fix_referer", "legacy_tls") if p.get(k)]
            if p.get("insecure_upstream"):
                marks.append("不校验上游证书")
            if p.get("entry_query"):
                marks.append("入口参数")
            print("%-12s %-34s → %s%s"
                  % (p.get("name"), p.get("host"), p.get("target"),
                     ("   [" + ", ".join(marks) + "]") if marks else ""))
        return 0

    if mode == "nft":
        # lanpanel.py nft <表> --uid <用户名>
        uid = None
        rest = argv[3:]
        while rest:
            if rest[0] == "--uid" and len(rest) > 1:
                uid, rest = rest[1], rest[2:]
            else:
                print("认不出的参数: %s" % rest[0]); return 3
        if not uid:
            print("nft 要 --uid <运行反代的用户名>"); return 3
        try:
            sys.stdout.write(render_nft(cfg, uid))
        except PanelError as e:
            print(str(e)); return 2
        return 0

    if mode == "zone-risk":
        # lanpanel.py zone-risk <表> <DoT域名>
        dot = argv[3] if len(argv) > 3 else ""
        risks = zone_risk(cfg, dot)
        for host, z in risks:
            print("%s\t%s" % (host, z))
        return 2 if risks else 0

    if mode == "targets":
        for ip, port in targets(cfg):
            print("%s\t%d" % (ip, port))
        return 0

    if mode == "render":
        certs, bind = None, "127.0.0.1"
        rest = argv[3:]
        while rest:
            if rest[0] == "--certs" and len(rest) > 1:
                certs, rest = rest[1], rest[2:]
            elif rest[0] == "--bind" and len(rest) > 1:
                bind, rest = rest[1], rest[2:]
            else:
                print("认不出的参数: %s" % rest[0])
                return 3
        if not certs:
            print("render 要 --certs <证书目录>")
            return 3
        try:
            sys.stdout.write(render_caddy(cfg, certs, bind))
        except PanelError as e:
            print(str(e))
            return 2
        return 0

    print("认不出的子命令: %s" % mode)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))

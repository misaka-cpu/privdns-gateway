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
  lanpanel.py render  <表.json> --certs <目录> [--bind <地址>]   生成 Caddyfile
  lanpanel.py targets <表.json>              列出 IP<TAB>端口, 供防火墙白名单使用
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

    for p in cfg["panels"]:
        scheme, ip, port = parse_target(p["target"])
        host = p["host"]
        name = p["name"]
        up = "%s://%s:%d" % (scheme, ip, port)

        L.append("# 面板 %s" % name)
        L.append("%s:443 {" % host)
        L.append("\tbind %s" % bind)
        L.append("\ttls %s/%s.crt %s/%s.key" % (certs_dir, name, certs_dir, name))

        if p.get("entry_query"):
            # 前后端分离的应用(sub-store 之类)要在入口带参数, 否则每台设备都得手输后端地址。
            L.append("\t@bare path /")
            L.append("\tredir @bare /?%s 302" % p["entry_query"])

        L.append("\treverse_proxy %s {" % up)
        if scheme == "https":
            L.append("\t\ttransport http {")
            L.append("\t\t\ttls")
            if p.get("insecure_upstream"):
                L.append("\t\t\ttls_insecure_skip_verify")
            L.append("\t\t}")
        if p.get("rewrite_location"):
            # 设备会把自己的局域网 IP 写进 Location 跳转头(Zyxel 交换机、华为 UPS 实测)。
            # 不改写的话手机会跟着跳到一个到不了的地址。
            L.append("\t\theader_down Location \"%s\" \"https://%s\"" % (up, host))
            L.append("\t\theader_down Location \"http://%s\" \"https://%s\"" % (ip, host))
        if p.get("fix_referer"):
            # 有些设备校验 Referer/Origin 必须是自己的地址(华为 UPS2000 实测, 否则返回
            # Error Referer Request!)。要在上行方向改回去。
            L.append("\t\theader_up Referer \"%s/\"" % up)
            L.append("\t\theader_up Origin \"%s\"" % up)
        L.append("\t}")
        L.append("}")
        L.append("")

    return "\n".join(L)


def legacy_tls_panels(cfg):
    """需要放宽 TLS 套件的面板名。

    老设备可能只提供 AES256-GCM-SHA384(RSA 密钥交换), Go 1.22 起默认禁用 —— 表现是 502
    加 handshake failure, **看着像证书问题**。这不是靠 Caddyfile 能解决的, 要给进程加
    GODEBUG=tlsrsakex=1, 所以单独列出来给 unit 生成用。
    """
    return [p["name"] for p in cfg.get("panels", []) if isinstance(p, dict) and p.get("legacy_tls")]


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

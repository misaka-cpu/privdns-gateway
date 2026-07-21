#!/usr/bin/env python3
"""MITM 服务(Feature B / iOS 专属)。

本地 socks5 入口: mihomo 把"接管域名"的连接按规则路由到本服务(socks5 出站, 目标=接管域名)。
本服务用自签 CA(mitm_ca)给该域名现签叶子证书、终止 TLS、把解密后的连接交给对应插件改写响应。
非接管目标不该到这里(mihomo 只把接管域名指过来)→ 兜底关闭。

插件 = 任意带 .domains(list) 与 .handle(tls, host, port) 的对象; register() 登记。
出口"仍由内核决定": 非接管域名压根不进本服务。
"""
import socket
import ssl
import threading

import mitm_ca

_REGISTRY = {}   # domain(lower) -> plugin


def register(plugin):
    """登记插件(用它声明的 domains)。"""
    for d in getattr(plugin, "domains", []):
        _REGISTRY[d.lower()] = plugin


def clear():
    _REGISTRY.clear()


def managed_domains():
    return sorted(_REGISTRY)


def _match(host):
    h = (host or "").lower()
    if h in _REGISTRY:
        return _REGISTRY[h]
    for d, p in _REGISTRY.items():          # 后缀匹配: 声明 example.com 接管 *.example.com
        if h == d or h.endswith("." + d):
            return p
    return None


def _recvn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d:
            raise IOError("eof")
        b += d
    return b


def _socks5_target(conn):
    """完成 socks5 无认证握手, 返回 (host, port)。"""
    hdr = _recvn(conn, 2)                    # VER, NMETHODS
    if hdr[0] != 5:
        raise IOError("not socks5")
    _recvn(conn, hdr[1])                     # methods
    conn.sendall(b"\x05\x00")               # 选无认证
    req = _recvn(conn, 4)                    # VER CMD RSV ATYP
    atyp = req[3]
    if atyp == 1:
        host = socket.inet_ntoa(_recvn(conn, 4))
    elif atyp == 3:
        host = _recvn(conn, _recvn(conn, 1)[0]).decode("utf-8", "ignore")
    elif atyp == 4:
        host = socket.inet_ntop(socket.AF_INET6, _recvn(conn, 16))
    else:
        raise IOError("bad atyp")
    port = int.from_bytes(_recvn(conn, 2), "big")
    return host, port


def _log(msg):
    import sys
    import time
    sys.stderr.write("[pdg-mitm %s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def _handle(conn):
    host = "?"
    try:
        conn.settimeout(30)                  # 防卡死连接长期占线程(本机 mihomo 连入, 30s 足够)
        host, port = _socks5_target(conn)
        plugin = _match(host)
        if plugin is None:
            _log("非接管连接 host=%s → 关闭" % host)
            conn.close()
            return
        conn.sendall(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")   # socks5 成功应答
        crt, key = mitm_ca.leaf_cert(host)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        try:
            tls = ctx.wrap_socket(conn, server_side=True)
        except Exception as e:               # noqa: BLE001  握手失败 = 证书 pinning 或 CA 未信任
            _log("TLS 握手失败 host=%s(pinning 或未信任 CA?): %s" % (host, e))
            conn.close()
            return
        _log("TLS 已终止 host=%s → 插件 %s" % (host, type(plugin).__name__))
        try:
            plugin.handle(tls, host, port)
        finally:
            try:
                tls.close()
            except Exception:  # noqa: BLE001
                pass
    except Exception as e:  # noqa: BLE001
        _log("连接异常 host=%s: %s" % (host, e))
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def serve(listen="127.0.0.1", port=7894):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((listen, port))
    srv.listen(128)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=_handle, args=(c,), daemon=True).start()


MITM_CONFIG = "/etc/privdns-gateway/mitm.json"
# 插件名 → 接管域名(bot 与服务共识; 与 mitm_hijack.txt / 渲染器同源)
PLUGIN_DOMAINS = {"wloc": ["gs-loc.apple.com", "gs-loc-cn.apple.com"]}


def _wloc_active(w):
    """取 WLOC 激活地点坐标; 兼容老单坐标格式 {lat,lon}。返回 {lat,lon} 或 None。"""
    locs = w.get("locations")
    if locs:
        for loc in locs:
            if loc.get("name") == w.get("active"):
                return loc
        return locs[0]
    if "lat" in w and "lon" in w:                 # 老格式(单坐标)
        return {"lat": w["lat"], "lon": w["lon"]}
    return None


def load_from_config(path=None):
    """按 mitm.json 里启用的插件登记(WLOC 用激活地点坐标)。返回已加载插件名列表。"""
    import json
    clear()
    try:
        cfg = json.load(open(path or MITM_CONFIG, encoding="utf-8"))
    except OSError:
        return []
    loaded = []
    w = cfg.get("wloc") or {}
    loc = _wloc_active(w)
    if w.get("enabled") and loc:
        import mitm_wloc
        register(mitm_wloc.WLOCPlugin(float(loc["lat"]), float(loc["lon"]),
                                      int(w.get("accuracy", 50))))
        loaded.append("wloc")
    return loaded


if __name__ == "__main__":
    import sys
    load_from_config()
    serve(port=int(sys.argv[1]) if len(sys.argv) > 1 else 7894)

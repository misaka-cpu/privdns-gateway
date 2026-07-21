#!/usr/bin/env python3
"""Apple WLOC 位置改写插件(Feature B / iOS)。

截 gs-loc.apple.com / gs-loc-cn.apple.com 的 Wi-Fi 定位请求(设备问"我周围这些 BSSID 在哪"), 回一个把
每个被问的 BSSID 都指到设定坐标的响应 → 设备定位落在该点。

wire 格式(苹果私有, 逆向公开): 头部(locale/identifier 长度前缀)+ protobuf。
  请求 protobuf: field 2 (repeated) = {field 1 = BSSID(MAC 串)}
  响应 protobuf: field 2 (repeated) = {field 1 = BSSID, field 2 = {1=纬度×1e8, 2=经度×1e8, 3=精度}}
  经纬度是 int64 ×1e8(负数按 protobuf int64 两补码 varint)。

⚠️ 头部确切字节需真 iPhone 抓包核对(_HEADER/_split_header 是当前最佳猜测, 留口子在阶段5校准)。
纯 stdlib 手写 protobuf(沿用 parse-geosite.py 的路子), 不引入依赖。
"""

_LOCALE = b"en_US"
_IDENT = b"com.apple.locationd"


# ── protobuf 编码 ──
def _uvarint(n):
    n &= (1 << 64) - 1                       # 负数 → 64 位两补码(protobuf int64 负数编码)
    out = bytearray()
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _tag(field, wt):
    return _uvarint((field << 3) | wt)


def _f_varint(field, n):
    return _tag(field, 0) + _uvarint(n)


def _f_bytes(field, data):
    return _tag(field, 2) + _uvarint(len(data)) + data


# ── protobuf 解码(手写, 同 parse-geosite.py)──
def _rv(b, i):
    s = r = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80:
            return r, i
        s += 7


def _fields(b):
    i, n, o = 0, len(b), []
    while i < n:
        k, i = _rv(b, i); fn, wt = k >> 3, k & 7
        if wt == 0:
            v, i = _rv(b, i); o.append((fn, wt, v))
        elif wt == 2:
            ln, i = _rv(b, i); o.append((fn, wt, bytes(b[i:i + ln]))); i += ln
        elif wt == 5:
            o.append((fn, wt, bytes(b[i:i + 4]))); i += 4
        elif wt == 1:
            o.append((fn, wt, bytes(b[i:i + 8]))); i += 8
        else:
            raise ValueError("bad wiretype")
    return o


def _svar(n):
    """无符号 varint 值 → 有符号 int64。"""
    return n - (1 << 64) if n >= (1 << 63) else n


# ── 头部 ──
def _header():
    return (b"\x00\x01"
            + len(_LOCALE).to_bytes(2, "big") + _LOCALE
            + len(_IDENT).to_bytes(2, "big") + _IDENT
            + b"\x00\x00\x00\x01\x00\x00")


def _pb_has_wifi(pb):
    """pb 能解析且含 field 2(WiFi 列表)= 认为是有效的 wloc protobuf。"""
    try:
        return any(fn == 2 and wt == 2 for fn, wt, _ in _fields(pb))
    except Exception:                         # noqa: BLE001
        return False


def _split_header(body):
    """跳过头部返回 protobuf。格式待真机核对; 结构化偏移不成立则扫首个能解析出 WiFi 列表的位置。"""
    try:                                      # 结构化: 2 + locale + identifier + 6(0x00000001 0x0000)
        i = 2
        for _ in range(2):
            ln = int.from_bytes(body[i:i + 2], "big"); i += 2 + ln
        i += 6
        if 0 < i <= len(body) and _pb_has_wifi(body[i:]):
            return body[i:]
    except Exception:                         # noqa: BLE001
        pass
    pos = 0                                    # 回退: 扫首个 field-2 tag(0x12) 且能解析出 WiFi 列表
    while True:
        pos = body.find(b"\x12", pos)
        if pos < 0:
            return body
        if _pb_has_wifi(body[pos:]):
            return body[pos:]
        pos += 1


# ── 请求解析 / 响应构造 ──
def parse_request(body):
    """从请求体解析出被问的 BSSID 列表。"""
    pb = _split_header(body)
    bssids = []
    for fn, wt, val in _fields(pb):
        if fn == 2 and wt == 2:              # 每个 WiFi 项
            for f2, w2, v2 in _fields(val):
                if f2 == 1 and w2 == 2:
                    bssids.append(v2.decode("utf-8", "ignore"))
    return bssids


def build_request(bssids):
    """构造一个请求(供测试用, 模拟设备)。"""
    pb = b""
    for m in bssids:
        pb += _f_bytes(2, _f_bytes(1, m.encode()))
    pb += _f_varint(3, 100)                  # numberOfResults
    return _header() + pb


def build_response(bssids, lat, lon, accuracy=50):
    """把每个 BSSID 都指到 (lat, lon) 的响应体。"""
    lat_e8 = int(round(lat * 1e8))
    lon_e8 = int(round(lon * 1e8))
    pb = b""
    for m in bssids:
        loc = _f_varint(1, lat_e8) + _f_varint(2, lon_e8) + _f_varint(3, accuracy)
        pb += _f_bytes(2, _f_bytes(1, m.encode()) + _f_bytes(2, loc))
    return _header() + pb


def parse_response(body):
    """解析响应体 → {bssid: (lat, lon, acc)}(供测试)。"""
    pb = _split_header(body)
    out = {}
    for fn, wt, val in _fields(pb):
        if fn == 2 and wt == 2:
            mac = None; loc = None
            for f2, w2, v2 in _fields(val):
                if f2 == 1 and w2 == 2:
                    mac = v2.decode("utf-8", "ignore")
                elif f2 == 2 and w2 == 2:
                    lat = lon = acc = 0
                    for f3, w3, v3 in _fields(v2):
                        if f3 == 1:
                            lat = _svar(v3)
                        elif f3 == 2:
                            lon = _svar(v3)
                        elif f3 == 3:
                            acc = _svar(v3)
                    loc = (lat / 1e8, lon / 1e8, acc)
            if mac and loc:
                out[mac] = loc
    return out


# ── forward+patch: 转发真请求给 Apple、只把响应里的坐标改成目标点(格式 100% 对, 不再自造)──
import socket as _socket                         # noqa: E402
import ssl as _ssl                               # noqa: E402

_RESOLVERS = ["8.8.8.8", "1.1.1.1", "223.5.5.5"]
_ipcache = {}                                     # host -> (ip, ts)


def _try_fields(data):
    """能无损解析成 protobuf(恒等重编码字节一致)才返回字段, 否则 None(视作不透明字节, 如 BSSID 串)。"""
    if not data:
        return None
    try:
        flds = _fields(data)
    except Exception:                             # noqa: BLE001
        return None
    chk = b""
    for fn, wt, val in flds:
        if wt == 0:
            chk += _f_varint(fn, val)
        elif wt == 2:
            chk += _f_bytes(fn, val)
        elif wt == 5:
            chk += _tag(fn, 5) + val
        elif wt == 1:
            chk += _tag(fn, 1) + val
        else:
            return None
    return flds if chk == data else None


def _has_loc(data):
    """递归判断是否含 location 子消息(同时有 field1+field2 varint)。"""
    flds = _try_fields(data)
    if not flds:
        return False
    fnos = {(fn, wt) for fn, wt, _ in flds}
    if (1, 0) in fnos and (2, 0) in fnos:
        return True
    return any(wt == 2 and _has_loc(val) for fn, wt, val in flds)


def _split_resp(body):
    """响应体可能带非 protobuf 头部前缀; 扫出 protobuf 起点, 返回 (prefix, pb)。"""
    for i in range(min(len(body), 64)):
        if _try_fields(body[i:]) is not None and _has_loc(body[i:]):
            return body[:i], body[i:]
    return body, b""


def _patch_pb(data, lat_e8, lon_e8):
    """递归重编码: location 子消息(含 field1+field2 varint)里 field1/2 换成目标坐标; 其余原样。"""
    flds = _try_fields(data)
    if flds is None:
        return data
    fnos = {(fn, wt) for fn, wt, _ in flds}
    is_loc = (1, 0) in fnos and (2, 0) in fnos
    out = b""
    for fn, wt, val in flds:
        if wt == 0:
            if is_loc and fn == 1:
                out += _f_varint(1, lat_e8)
            elif is_loc and fn == 2:
                out += _f_varint(2, lon_e8)
            else:
                out += _f_varint(fn, val)
        elif wt == 2:
            out += _f_bytes(fn, _patch_pb(val, lat_e8, lon_e8))
        elif wt == 5:
            out += _tag(fn, 5) + val
        else:                                     # wt == 1
            out += _tag(fn, 1) + val
    return out


def patch_response(body, lat, lon):
    """把 Apple 真响应里所有坐标改成 (lat, lon), 保留头部/结构; 找不到 protobuf 则原样返回。"""
    prefix, pb = _split_resp(body)
    if not pb:
        return body
    return prefix + _patch_pb(pb, int(round(lat * 1e8)), int(round(lon * 1e8)))


def _dns_a(host, server, timeout=4):
    import struct
    pkt = (b"\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
           + b"".join(bytes([len(p)]) + p.encode() for p in host.split(".")) + b"\x00\x00\x01\x00\x01")
    s = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(pkt, (server, 53))
        d, _ = s.recvfrom(1024)
    finally:
        s.close()
    i = 12
    while d[i]:
        i += 1 + d[i]
    i += 5
    while i + 12 <= len(d):
        i += 2
        typ = struct.unpack(">H", d[i:i + 2])[0]; i += 8
        rdlen = struct.unpack(">H", d[i:i + 2])[0]; i += 2
        if typ == 1 and rdlen == 4:
            return ".".join(map(str, d[i:i + 4]))
        i += rdlen
    return None


def _resolve(host):
    import time
    ip, ts = _ipcache.get(host, (None, 0))
    if ip and time.time() - ts < 300:
        return ip
    for r in _RESOLVERS:
        try:
            ip = _dns_a(host, r)
        except Exception:                         # noqa: BLE001
            ip = None
        if ip:
            _ipcache[host] = (ip, time.time())
            return ip
    return None


def _dechunk(body):
    out = b""
    while body:
        nl = body.find(b"\r\n")
        if nl < 0:
            break
        try:
            n = int(body[:nl].split(b";")[0], 16)
        except ValueError:
            return body
        if n == 0:
            break
        out += body[nl + 2:nl + 2 + n]
        body = body[nl + 2 + n + 2:]
    return out


def _forward(host, head, body):
    """转发手机的原始请求(保留 User-Agent 等所有头, 只换 Host/Connection)给真 gs-loc。
    先试原 host, 失败回落 gs-loc.apple.com。返回 (resp_ctype, resp_body) 或 None。"""
    import sys
    lines = head.split(b"\r\n")
    reqline = lines[0]                             # POST /clls/wloc HTTP/1.1
    keep = [ln for ln in lines[1:] if ln.strip() and not ln.lower().startswith(
        (b"host:", b"connection:", b"content-length:", b"accept-encoding:"))]   # 去 AE → 拿明文
    seen = []
    for up in dict.fromkeys([host, "gs-loc.apple.com"]):
        ip = _resolve(up)
        if not ip:
            seen.append("%s=解析失败" % up); continue
        req = (reqline + b"\r\nHost: " + up.encode() + b"\r\n"
               + (b"\r\n".join(keep) + b"\r\n" if keep else b"")
               + b"Content-Length: " + str(len(body)).encode()
               + b"\r\nConnection: close\r\n\r\n" + body)
        try:
            raw = _socket.create_connection((ip, 443), timeout=10)
            tls = _ssl.create_default_context().wrap_socket(raw, server_hostname=up)
            tls.sendall(req)
            buf = b""                              # 先读到响应头结束
            while b"\r\n\r\n" not in buf:
                d = tls.recv(8192)
                if not d:
                    break
                buf += d
            rhead, _, rbody = buf.partition(b"\r\n\r\n")
            rlines = rhead.split(b"\r\n")
            if b" 200" not in rlines[0]:
                raw.close()
                seen.append("%s→%s" % (up, rlines[0][:40].decode("latin1", "ignore"))); continue
            if b"chunked" in rhead.lower():        # 按 chunked / Content-Length 读完就停(不等 close)
                while b"0\r\n\r\n" not in rbody[-16:]:
                    d = tls.recv(8192)
                    if not d:
                        break
                    rbody += d
                rbody = _dechunk(rbody)
            else:
                clen = 0
                for ln in rlines[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        try:
                            clen = int(ln.split(b":", 1)[1].strip())
                        except ValueError:
                            clen = 0
                while len(rbody) < clen:
                    d = tls.recv(8192)
                    if not d:
                        break
                    rbody += d
            raw.close()
        except Exception as e:                    # noqa: BLE001
            seen.append("%s(%s)异常:%s" % (up, ip, type(e).__name__)); continue
        ctype = b"application/x-protobuf"
        for ln in rlines[1:]:
            if ln.lower().startswith(b"content-type:"):
                ctype = ln.split(b":", 1)[1].strip()
        return ctype, rbody
    sys.stderr.write("[pdg-wloc] 转发全失败: %s\n" % " | ".join(seen))
    return None


class WLOCPlugin:
    """接管 Apple 网络定位查询(/clls/wloc), 把定位改写成设定坐标。
    截 gs-loc.apple.com / gs-loc-cn.apple.com(与 Yu9191/OpenHRTT wloc 同源);
    不碰 gspe*-ssl.ls.apple.com —— 那是 Apple 地图瓦片, 劫了会砸地图。"""
    domains = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]

    def __init__(self, lat, lon, accuracy=50):
        self.lat, self.lon, self.accuracy = lat, lon, accuracy

    def handle(self, tls, host, port):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = tls.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        clen = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                try:
                    clen = int(line.split(b":", 1)[1].strip())
                except ValueError:
                    clen = 0
        while len(body) < clen:
            chunk = tls.recv(4096)
            if not chunk:
                break
            body += chunk
        import sys
        reqline = head.split(b"\r\n", 1)[0].decode("latin1", "ignore")[:60]
        try:
            fwd = _forward(host, head, body)      # 转发手机原始请求 → 真响应(格式 100% 对)
        except Exception as e:                    # noqa: BLE001
            fwd = None
            sys.stderr.write("[pdg-wloc] 转发异常 %s: %s\n" % (host, e))
        if fwd is None:                           # 转发失败: 502 让 iOS 回落(不给坏格式)
            sys.stderr.write("[pdg-wloc] %s <= %s | body=%d 转发失败\n" % (host, reqline, len(body)))
            sys.stderr.flush()
            tls.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        rctype, rbody = fwd
        patched = patch_response(rbody, self.lat, self.lon)
        sys.stderr.write("[pdg-wloc] %s <= %s | req=%d resp=%d patched=%d %s → (%s, %s)\n"
                         % (host, reqline, len(body), len(rbody), len(patched),
                            "改写OK" if patched != rbody else "未命中坐标", self.lat, self.lon))
        sys.stderr.flush()
        tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: " + rctype
                    + b"\r\nContent-Length: " + str(len(patched)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + patched)

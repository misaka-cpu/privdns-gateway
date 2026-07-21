#!/usr/bin/env python3
"""Apple WLOC 插件回归: protobuf 编解码往返 + patch_response 只改坐标保结构 + handle(mock 转发)。

handle 走 forward+patch(转发手机原请求给真 gs-loc、拿真响应、只 patch 坐标),
故端到端用 mock 的 _forward;真机链路由 .200 集成测试覆盖。
"""
import socket
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import mitm_wloc  # noqa: E402

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def approx(a, b, eps=1e-6):
    return abs(a - b) < eps


def main():
    macs = ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"]

    # 请求编解码往返
    req = mitm_wloc.build_request(macs)
    assert mitm_wloc.parse_request(req) == macs; ok("请求 protobuf 往返(BSSID 列表)")

    # 响应: 每个 BSSID 都被指到设定坐标(东京)
    lat, lon = 35.6812, 139.7671
    resp = mitm_wloc.build_response(macs, lat, lon, accuracy=42)
    got = mitm_wloc.parse_response(resp)
    assert set(got) == set(macs); ok("响应含所有被问 BSSID")
    for m in macs:
        la, lo, ac = got[m]
        assert approx(la, lat) and approx(lo, lon) and ac == 42, got[m]
    ok("每个 BSSID 都改写到设定坐标 + 精度")

    # 负坐标(旧金山 lon 为负 / 南半球 lat 为负)往返
    resp2 = mitm_wloc.build_response(["00:00:00:00:00:01"], -33.8688, -151.2093)
    la, lo, _ = mitm_wloc.parse_response(resp2)["00:00:00:00:00:01"]
    assert approx(la, -33.8688) and approx(lo, -151.2093), (la, lo)
    ok("负坐标(南纬/西经)int64 两补码往返正确")

    # 头部容错: 若头部字节不符, 扫描回退仍能解析出 BSSID
    body = b"\x99\x99garbage-header" + mitm_wloc.build_request(macs)[len(mitm_wloc._header()):]
    assert mitm_wloc.parse_request(body) == macs; ok("头部不符时扫描回退仍解析出 BSSID")

    # patch_response: 合成"Apple 真响应"(头部前缀 + entries + 顶层非坐标字段), 只改坐标、保结构
    prefix = b"\x00\x01\x00\x05zh_CN\x00\x00"
    def _entry(mac, la, lo, ac):
        loc = (mitm_wloc._f_varint(1, int(la * 1e8)) + mitm_wloc._f_varint(2, int(lo * 1e8))
               + mitm_wloc._f_varint(3, ac))
        return mitm_wloc._f_bytes(2, mitm_wloc._f_bytes(1, mac.encode()) + mitm_wloc._f_bytes(2, loc))
    real = prefix + _entry(macs[0], 30.1, 120.1, 40) + _entry(macs[1], 31.2, 121.4, 65) \
        + mitm_wloc._f_varint(5, 99)               # 顶层 numberOfResults 之类, 不该被动
    patched = mitm_wloc.patch_response(real, lat, lon)
    assert patched.startswith(prefix); ok("patch_response 保留头部前缀")
    pr = mitm_wloc.parse_response(patched)
    assert set(pr) == set(macs) and all(approx(pr[m][0], lat) and approx(pr[m][1], lon) for m in macs)
    assert {pr[m][2] for m in macs} == {40, 65}; ok("patch_response 只改经纬度, 保 BSSID/精度")
    top = {fn: v for fn, wt, v in mitm_wloc._fields(mitm_wloc._split_resp(patched)[1])}
    assert top.get(5) == 99; ok("patch_response 保留顶层非坐标字段")

    # 插件 handle: mock _forward 返回上面的"真响应", 验证 handle 转发→patch→回 200
    orig_forward = mitm_wloc._forward
    mitm_wloc._forward = lambda host, head, body: (b"application/x-protobuf", real)
    try:
        a, b = socket.socketpair()
        a.settimeout(5); b.settimeout(5)
        rb = mitm_wloc.build_request(macs)
        b.sendall(b"POST /clls/wloc HTTP/1.1\r\nHost: gs-loc.apple.com\r\nContent-Length: "
                  + str(len(rb)).encode() + b"\r\n\r\n" + rb)
        plugin = mitm_wloc.WLOCPlugin(lat, lon)
        t = threading.Thread(target=plugin.handle, args=(a, "gs-loc.apple.com", 443)); t.start()
        resp_raw = b""
        while b"\r\n\r\n" not in resp_raw:
            resp_raw += b.recv(4096)
        rhead, _, body2 = resp_raw.partition(b"\r\n\r\n")
        clen = int([l.split(b":")[1].strip() for l in rhead.split(b"\r\n")
                    if l.lower().startswith(b"content-length:")][0])
        while len(body2) < clen:
            body2 += b.recv(4096)
        t.join(5)
        assert b"200 OK" in rhead; ok("插件返回 HTTP 200")
        pr2 = mitm_wloc.parse_response(body2)
        assert set(pr2) == set(macs) and all(approx(pr2[m][0], lat) and approx(pr2[m][1], lon) for m in macs)
        ok("插件端到端(mock 转发): 真响应 → patch 坐标 → 回给手机")
        a.close(); b.close()
    finally:
        mitm_wloc._forward = orig_forward

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

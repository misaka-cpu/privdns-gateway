#!/usr/bin/env python3
"""pdg-mitm 不重启也能换坐标(WLOC 热加载)。

切一次地点原先要重启 pdg-mitm、重启 mosdns、重渲内核 —— 只为把新经纬度送进插件。现在
切换只原子更新 mitm.json, WlocConfig 在下一次 WLOC 请求开始时读取当前配置(整份读, 不看
mtime), 服务进程从头到尾同一个 PID。

本用例起一个**真的 pdg-mitm 子进程**(真 socks5 + 真 CA 签的叶子证书 + 真 TLS + 真插件),
只把"向 Apple 转发"这一步换成本地假上游(测试机连不到 gs-loc.apple.com)。验证:
  · 第一份请求用坐标 A, 原子换配置后第二份用坐标 B, 进程 PID 不变;
  · 切换与请求并发时, 每个响应要么整份 A 要么整份 B, 不会半新半旧;
  · 配置临时坏掉时不崩、继续用最后一次有效配置, 并把错误类型记进状态文件;
  · 状态文件原子写、0600, 只有约定字段(没有 BSSID / 请求头 / 请求正文)。
"""
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import mitm_ca      # noqa: E402
import mitm_wloc as W  # noqa: E402

pass_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m); pass_n += 1


def bad(m):
    print("[FAIL]", m); sys.exit(1)


A = ("东京", 35.6812, 139.7671)
B = ("大阪", 34.6937, 135.5023)
MACS = ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66", "de:ad:be:ef:00:01"]
UPSTREAM = (51.5074, -0.1278)          # 假 Apple 一律回"伦敦"

LAUNCHER = r'''
import os, sys
sys.path.insert(0, %(botdir)r)
import mitm_ca, mitm_server, mitm_wloc
mitm_ca.CA_DIR = %(cadir)r
mitm_server.MITM_CONFIG = %(cfg)r
mitm_wloc.MITM_CONFIG = %(cfg)r
mitm_wloc.STATUS_FILE = %(status)r
# 唯一的替身: 测试机连不到 gs-loc.apple.com, 用一份**格式真实**的 Apple 响应代替转发结果。
# 坐标改写、配置热加载、状态落盘全都跑真代码。
_REAL = mitm_wloc.build_response(%(macs)r, %(ulat)r, %(ulon)r, 40)
mitm_wloc._forward = lambda host, head, body: (b"application/x-protobuf", _REAL)
mitm_server.load_from_config()
sys.stderr.write("READY %%d\n" %% os.getpid()); sys.stderr.flush()
mitm_server.serve(port=%(port)d)
'''


def write_cfg(path, name, lat, lon, generation, enabled=True):
    doc = {"wloc": {"enabled": enabled, "accuracy": 50, "active": name,
                    "generation": generation,
                    "locations": [{"name": name, "lat": lat, "lon": lon}]}}
    t = path + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
    os.replace(t, path)                 # 与 bot 一样原子替换


def write_raw(path, text):
    t = path + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(t, path)


def recvn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d:
            return b
        b += d
    return b


def socks5_connect(sock, host, port):
    sock.sendall(b"\x05\x01\x00")
    if recvn(sock, 2) != b"\x05\x00":
        raise IOError("socks5 握手失败")
    h = host.encode()
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + port.to_bytes(2, "big"))
    rep = recvn(sock, 10)
    if len(rep) != 10 or rep[1] != 0:
        raise IOError("socks5 CONNECT 失败")


def wloc_request(port, ca_crt, host="gs-loc.apple.com", timeout=15):
    """完整跑一遍手机侧: socks5 → TLS(用网关 CA 验证) → POST /clls/wloc → 解析响应坐标。"""
    body = W.build_request(MACS)
    sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    try:
        socks5_connect(sock, host, 443)
        ctx = ssl.create_default_context(cafile=ca_crt)
        tls = ctx.wrap_socket(sock, server_hostname=host)
        tls.sendall(b"POST /clls/wloc HTTP/1.1\r\nHost: " + host.encode()
                    + b"\r\nUser-Agent: locationd/2890.0.14 CFNetwork/1568 Darwin/24.0.0"
                    + b"\r\nContent-Type: application/x-www-form-urlencoded"
                    + b"\r\nContent-Length: " + str(len(body)).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body)
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = tls.recv(4096)
            if not d:
                break
            buf += d
        head, _, rbody = buf.partition(b"\r\n\r\n")
        clen = 0
        for ln in head.split(b"\r\n"):
            if ln.lower().startswith(b"content-length:"):
                clen = int(ln.split(b":", 1)[1].strip())
        while len(rbody) < clen:
            d = tls.recv(4096)
            if not d:
                break
            rbody += d
        tls.close()
        return head.split(b"\r\n", 1)[0], W.parse_response(rbody)
    finally:
        try:
            sock.close()
        except OSError:
            pass


def coords_of(parsed):
    """响应里所有 BSSID 的坐标必须一致; 返回那一个坐标(不一致就是半新半旧)。"""
    pts = {(round(lat, 6), round(lon, 6)) for lat, lon, _ in parsed.values()}
    if len(pts) != 1:
        bad(f"同一个响应里出现了多个坐标(半新半旧): {pts}")
    return pts.pop()


def read_status(path):
    for _ in range(40):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.05)
    return None


def main():
    if subprocess.run(["openssl", "version"], capture_output=True).returncode != 0:
        print("[SKIP] 无 openssl, 跳过(需要真 CA 签叶子证书)"); return
    tmp = tmpguard.mkdtemp(prefix="pdgwlochot")
    cfg = os.path.join(tmp, "mitm.json")
    status = os.path.join(tmp, "wloc-status.json")
    cadir = os.path.join(tmp, "ca")
    mitm_ca.CA_DIR = cadir
    ca_crt = mitm_ca.ensure_ca()
    mitm_ca.prewarm(["gs-loc.apple.com"], strict=True)

    write_cfg(cfg, *A, generation=7)
    s0 = socket.socket(); s0.bind(("127.0.0.1", 0)); port = s0.getsockname()[1]; s0.close()
    launcher = os.path.join(tmp, "run_mitm.py")
    with open(launcher, "w", encoding="utf-8") as f:
        f.write(LAUNCHER % {"botdir": str(ROOT / "deploy" / "bot"), "cadir": cadir,
                            "cfg": cfg, "status": status, "port": port,
                            "macs": MACS, "ulat": UPSTREAM[0], "ulon": UPSTREAM[1]})
    proc = subprocess.Popen([sys.executable, launcher], stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE)
    try:
        ready = proc.stderr.readline().decode("utf-8", "ignore")
        if not ready.startswith("READY"):
            bad(f"pdg-mitm 没起来: {ready}")
        srv_pid = proc.pid
        threading.Thread(target=lambda: [proc.stderr.readline() for _ in iter(int, 1)],
                         daemon=True).start()      # 排空 stderr, 免得插件日志把管道写满
        time.sleep(0.3)

        # ── 1. 第一份请求: 坐标 A ──
        _, r1 = wloc_request(port, ca_crt)
        got = coords_of(r1)
        if abs(got[0] - A[1]) > 1e-6 or abs(got[1] - A[2]) > 1e-6:
            bad(f"第一份请求没用坐标 A: {got}")
        if set(r1) != set(MACS):
            bad(f"BSSID 集合被改动了: {set(r1)}")
        ok(f"第一份 WLOC 请求按坐标 A 改写({A[0]})")
        st1 = read_status(status)
        if not st1 or st1.get("generation") != 7 or not st1.get("patched"):
            bad(f"状态文件没记下这次命中: {st1}")
        ok("状态文件记下 generation / patched / target_name")

        # ── 2. 原子换配置为 B, **不重启进程** ──
        write_cfg(cfg, *B, generation=8)
        _, r2 = wloc_request(port, ca_crt)
        got = coords_of(r2)
        if abs(got[0] - B[1]) > 1e-6 or abs(got[1] - B[2]) > 1e-6:
            bad(f"换配置后仍在用旧坐标(热加载没生效): {got}")
        ok(f"原子换 mitm.json 后, 下一份请求立刻用坐标 B({B[0]})")
        st2 = read_status(status)
        if st2.get("generation") != 8 or st2.get("target_name") != B[0]:
            bad(f"状态文件没跟上新 generation: {st2}")
        ok("状态文件跟着 generation 走(bot 能认出是哪一次切换的命中)")

        # ── 3. 同一个 PID: 没重启过服务 ──
        if proc.poll() is not None:
            bad("pdg-mitm 进程中途退出了")
        if st1.get("pid") != st2.get("pid") or st1.get("pid") != srv_pid:
            bad(f"服务 PID 变了: {st1.get('pid')} → {st2.get('pid')}(期望 {srv_pid})")
        ok(f"两次请求的 pdg-mitm PID 相同({srv_pid}) —— 全程没重启进程")

        # ── 4. 并发: 切换与请求同时发生, 每个响应只能整份 A 或整份 B ──
        stop = threading.Event()
        seen, errs = [], []

        def flipper():
            g = 100
            while not stop.is_set():
                g += 1
                write_cfg(cfg, *(A if g % 2 else B), generation=g)
                time.sleep(0.01)

        def requester():
            try:
                for _ in range(4):
                    _, r = wloc_request(port, ca_crt)
                    seen.append(coords_of(r))       # coords_of 内部就会挡下"半新半旧"
            except Exception as e:  # noqa: BLE001
                errs.append("%s: %s" % (type(e).__name__, e))

        fl = threading.Thread(target=flipper, daemon=True); fl.start()
        ths = [threading.Thread(target=requester) for _ in range(4)]
        for t in ths:
            t.start()
        for t in ths:
            t.join(60)
        stop.set(); fl.join(5)
        if errs:
            bad(f"并发请求出错: {errs[:2]}")
        allowed = {(round(A[1], 6), round(A[2], 6)), (round(B[1], 6), round(B[2], 6))}
        wrong = [p for p in seen if p not in allowed]
        if wrong or not seen:
            bad(f"并发下出现了非 A 非 B 的坐标: {wrong[:3]}(共 {len(seen)} 次)")
        ok(f"配置切换与请求并发 {len(seen)} 次: 每个响应都是完整的 A 或 B")

        # ── 5. 配置临时坏掉: 不崩, 继续用最后一次有效配置, 并记下错误类型 ──
        write_cfg(cfg, *B, generation=200)
        wloc_request(port, ca_crt)                  # 先让 B/200 成为 last-known-good
        write_raw(cfg, "{ 这不是 JSON")
        _, r5 = wloc_request(port, ca_crt)
        got = coords_of(r5)
        if abs(got[0] - B[1]) > 1e-6 or abs(got[1] - B[2]) > 1e-6:
            bad(f"坏配置下没有沿用最后一次有效坐标: {got}")
        ok("mitm.json 临时坏掉: 不崩、继续用最后一次有效坐标")
        st5 = read_status(status)
        if not st5.get("error_type"):
            bad(f"坏配置没被记进状态文件的 error_type: {st5}")
        if st5.get("generation") != 200:
            bad(f"坏配置期间 generation 不该乱跳: {st5}")
        ok(f"坏配置被如实记进 error_type({st5['error_type']}), 沿用上一代 generation")

        # ── 6. 状态文件: 权限 / 原子 / 只含约定字段 ──
        mode = os.stat(status).st_mode & 0o777
        if mode != 0o600:
            bad(f"状态文件权限不是 0600: {oct(mode)}")
        ok("状态文件权限 0600")
        if os.path.exists(status + ".tmp"):
            bad("状态文件的临时文件没清掉(原子替换没做干净)")
        ok("状态文件用临时文件 + os.replace 原子写, 不留残件")
        allowed_keys = {"generation", "target_name", "received_at", "upstream_ok",
                        "patched", "error_type", "pid"}
        extra = set(st5) - allowed_keys
        if extra:
            bad(f"状态文件出现了约定之外的字段: {extra}")
        blob = open(status, encoding="utf-8").read().lower()
        for leak in [m.lower() for m in MACS] + ["user-agent", "locationd", "clls/wloc",
                                                 "content-length", "authorization"]:
            if leak in blob:
                bad(f"状态文件里出现了敏感内容: {leak}")
        ok("状态文件不含 BSSID / 请求头 / 请求正文等敏感内容")

        # ── 7. 时间戳没变但内容换了: 也必须读到新坐标 ──
        # mtime_ns 的分辨率不是无限的, bot 连着两次 os.replace 完全可能落在同一个时间戳上。
        # 这里把新配置的 mtime **强制设回**旧值, 稳定复现那一刻: 只要还按 mtime 判"变没变",
        # 这一步必然读到旧坐标。
        write_cfg(cfg, *A, generation=300)
        wloc_request(port, ca_crt)                  # 让 A/300 进缓存
        old_mt = os.stat(cfg).st_mtime_ns
        write_cfg(cfg, *B, generation=301)
        os.utime(cfg, ns=(old_mt, old_mt))
        if os.stat(cfg).st_mtime_ns != old_mt:
            bad("样本没造对: mtime 没能设回旧值")
        _, r7 = wloc_request(port, ca_crt)
        got = coords_of(r7)
        if abs(got[0] - B[1]) > 1e-6 or abs(got[1] - B[2]) > 1e-6:
            bad(f"时间戳相同但内容已换时读到了旧坐标(仍在靠 mtime 判变化): {got}")
        ok("时间戳与上一次完全相同、内容已替换 → 照样读到新坐标(不靠 mtime 判变化)")

        # ── 8. 并发写状态: 唯一临时文件 + 旧 generation 不覆盖新的 ──
        import mitm_wloc as WW
        stat2 = os.path.join(os.path.dirname(status), "concurrent-status.json")
        errs2 = []

        def writer(g):
            try:
                for _ in range(30):
                    WW.write_status(g, "gen%d" % g, True, True, path=stat2)
            except Exception as e:  # noqa: BLE001
                errs2.append("%s: %s" % (type(e).__name__, e))

        ths = [threading.Thread(target=writer, args=(g,)) for g in (11, 12, 13, 14)]
        for t in ths:
            t.start()
        for t in ths:
            t.join(30)
        if errs2:
            bad(f"并发写状态出错: {errs2[:2]}")
        with open(stat2, encoding="utf-8") as f:
            final = json.load(f)                     # 能解析 = 没写出半份
        if final.get("generation") != 14:
            bad(f"并发写完后不是最新一代: {final}")
        leftovers = [n for n in os.listdir(os.path.dirname(stat2))
                     if n.startswith("concurrent-status.json.")]
        if leftovers:
            bad(f"并发写留下了临时文件残件: {leftovers[:3]}")
        ok("4 线程并发写状态: 内容完整、最终留最新一代、无临时文件残件")

        WW.write_status(9, "旧目标", True, True, path=stat2)
        with open(stat2, encoding="utf-8") as f:
            after_old = json.load(f)
        if after_old.get("generation") != 14 or after_old.get("target_name") != "gen14":
            bad(f"旧 generation 覆盖了更新的状态: {after_old}")
        ok("旧 generation 的请求晚到 → 不覆盖已写入的更新状态")

        write_cfg(cfg, *B, generation=400)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

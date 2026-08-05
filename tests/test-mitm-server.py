#!/usr/bin/env python3
"""MITM 服务端到端回归: socks5 入口 → 自签 CA 现签叶子终止 TLS → 插件拿到明文并改写响应。
关键: 客户端用 CA 证书能验证叶子(证明信任 CA 的设备会接受 MITM);非接管域名兜底关闭。"""
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
import mitm_server  # noqa: E402

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


class Echo:
    domains = ["mitm-test.local"]
    def handle(self, tls, host, port):
        try:
            tls.recv(4096)
        except Exception:  # noqa: BLE001
            pass
        body = ("MITM-OK host=%s port=%d" % (host, port)).encode()
        tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)


def recvn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d:
            return b
        b += d
    return b


def socks5_connect(sock, host, port):
    sock.sendall(b"\x05\x01\x00")                       # VER, 1 method, no-auth
    assert recvn(sock, 2) == b"\x05\x00"
    h = host.encode()
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + port.to_bytes(2, "big"))
    return recvn(sock, 10)                              # 成功 = 10 字节, REP=0; 关闭 = 空


def main():
    if subprocess.run(["openssl", "version"], capture_output=True).returncode != 0:
        print("[SKIP] 无 openssl"); return
    tmp = tmpguard.mkdtemp()
    mitm_ca.CA_DIR = os.path.join(tmp, "ca")
    ca_crt = mitm_ca.ensure_ca()

    mitm_server.clear()
    mitm_server.register(Echo())
    assert "mitm-test.local" in mitm_server.managed_domains(); ok("插件注册(接管域名进注册表)")

    # 找空闲端口起服务
    s0 = socket.socket(); s0.bind(("127.0.0.1", 0)); port = s0.getsockname()[1]; s0.close()
    threading.Thread(target=mitm_server.serve, kwargs={"port": port}, daemon=True).start()
    time.sleep(0.4)

    # ── 接管域名: socks → TLS 终止 → echo ──
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    rep = socks5_connect(sock, "mitm-test.local", 443)
    assert len(rep) == 10 and rep[1] == 0, rep; ok("socks5 CONNECT 接管域名 → 成功应答")

    ctx = ssl.create_default_context(cafile=ca_crt)     # 只信任我们的 CA
    tls = ctx.wrap_socket(sock, server_hostname="mitm-test.local")
    ok("TLS 握手成功(客户端用 CA 验证了叶子证书 → 信任 CA 的设备会接受 MITM)")
    peer = tls.getpeercert()
    assert any("mitm-test.local" in str(v) for v in peer.get("subjectAltName", ())); ok("叶子证书 SAN=接管域名")
    tls.sendall(b"GET / HTTP/1.1\r\nHost: mitm-test.local\r\n\r\n")
    resp = b""
    while b"MITM-OK" not in resp:
        d = tls.recv(4096)
        if not d:
            break
        resp += d
    assert b"MITM-OK host=mitm-test.local port=443" in resp, resp; ok("插件拿到明文并改写响应(echo 回显 host/port)")
    tls.close()

    # ── 非接管域名: 兜底关闭(不回 socks 成功) ──
    sock2 = socket.create_connection(("127.0.0.1", port), timeout=5)
    rep2 = socks5_connect(sock2, "not-managed.example", 443)
    assert rep2 == b"", "非接管域名应被兜底关闭, 不回成功应答"; ok("非接管域名 → 兜底关闭(不 MITM)")
    sock2.close()

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

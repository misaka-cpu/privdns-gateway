#!/usr/bin/env python3
"""对本机 853 发一条普通 DoT 查询, 打印第一个 A 记录。给 E2E 当"普通 DoT 可用"的判据。"""
import socket, ssl, struct, sys

def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "example.com"
    sni = sys.argv[2] if len(sys.argv) > 2 else "dot.example.test"
    body = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    msg = struct.pack("!HHHHHH", 0x2345, 0x0100, 1, 0, 0, 0) + body + struct.pack("!HH", 1, 1)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", 853), timeout=6),
                        server_hostname=sni)
    s.sendall(struct.pack("!H", len(msg)) + msg)
    n = struct.unpack("!H", s.recv(2))[0]
    r = s.recv(n)
    s.close()
    # 只要有应答且 ANCOUNT>0 就算通 —— 这里不解析 rdata, E2E 关心的是"这条路通不通"
    an = struct.unpack("!H", r[6:8])[0]
    print("ANCOUNT=%d" % an)
    return 0 if an > 0 else 1

if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""发一条**带 label 的**探测查询, 走 DoT + 正确 SNI。

生产迁移**不**做这件事(那会往用户的单槽 evidence 里写一笔合成记录, 和真实查询抢位置)。
它只作为独立的 E2E 验收门: 迁移完成后由测试发一次, 必须能产生 evidence。
"""
import socket, ssl, struct, sys

LABEL = "a1b2c3d4e5f6a7b8c9d0e1f2"

def main():
    # 缺省值只对"域名恰好就叫它"的夹具环境成立。真装机上域名是用户填的, 不传参数就会
    # 两个判据(qname 后缀 / SNI)同时落空, 表现为"没出 evidence" —— 那是探针打偏, 不是
    # 产品坏。调用方在真环境里必须显式传本机域名(见 tests/e2e-dot-p0.sh 的取法)。
    dom = sys.argv[1] if len(sys.argv) > 1 else "dot.example.test"
    qn = "%s.probe.%s" % (LABEL, dom)
    body = b"".join(bytes([len(p)]) + p.encode() for p in qn.split(".")) + b"\x00"
    msg = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + body + struct.pack("!HH", 1, 1)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", 853), timeout=6),
                        server_hostname=dom)
    s.sendall(struct.pack("!H", len(msg)) + msg)
    n = struct.unpack("!H", s.recv(2))[0]
    s.recv(n)
    s.close()
    print("probe sent")
    return 0

if __name__ == "__main__":
    sys.exit(main())

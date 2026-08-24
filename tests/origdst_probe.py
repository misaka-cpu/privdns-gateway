#!/usr/bin/env python3
"""探针: 本 netns 的 conntrack 在不在跟踪 —— 也就是 redir 入站能不能拿回原始目的地。

mihomo 的 redir 入站在 accept 之后立刻 getsockopt(SOL_IP, SO_ORIGINAL_DST) 取原始目的地
(deploy/firewall/nftables-mihomo.conf 开头就是这么写的)。那个 sockopt 由 conntrack 提供:
本 netns 没启用 conntrack hook 时它返回 ENOENT —— mihomo 会**静默丢掉**这条连接, 于是三个
出口日志全空, 表面上完全看不出真因(mihomo 自己在 warning 级别一个字都不打)。

这支把那一个系统调用单独拿出来问一遍, 让前提失败在启动 mihomo **之前**就显形, 并且报出的
是 errno, 而不是"三个格子都是空的"这种只能靠猜的症状。

做法: 自己起一个只绑 127.0.0.1 的临时监听(端口交给内核挑, 不写死 —— 写死就会和并跑的
测试撞), 连自己一次, 在 accept 出来的那个 fd 上问一次 SO_ORIGINAL_DST。不改任何系统状态。

退出码(三档分明, 调用方据此决定建不建前提, 不允许把"问不出来"当成"可用"):
  0  可用(conntrack 在跟踪)      stdout: ORIGDST=ok <ip:port>
  3  ENOENT —— conntrack 未激活   stdout: ORIGDST=enoent …
  4  其它错误(含探针自身起不来)   stdout: ORIGDST=error …
"""
import errno
import socket
import struct
import sys
import threading

SO_ORIGINAL_DST = 80          # include/uapi/linux/netfilter_ipv4.h


def main():
    result = {}

    def serve(srv):
        try:
            conn, _ = srv.accept()
        except OSError as e:
            result["rc"], result["msg"] = 4, "error accept 拿不到连接: %s" % e
            return
        try:
            raw = conn.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
            _fam, port, ip = struct.unpack_from("!HH4s", raw)
            result["rc"] = 0
            result["msg"] = "ok %s:%d" % (socket.inet_ntoa(ip), port)
        except OSError as e:
            if e.errno == errno.ENOENT:
                # 不是"没这个文件": conntrack 查不到本连接的条目就返回它。
                result["rc"] = 3
                result["msg"] = "enoent errno=2(ENOENT) 本 netns 的 conntrack 没在跟踪"
            else:
                result["rc"] = 4
                result["msg"] = "error errno=%s(%s) %s" % (
                    e.errno, errno.errorcode.get(e.errno, "?"), e.strerror)
        finally:
            conn.close()

    try:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.settimeout(5)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
    except OSError as e:
        print("ORIGDST=error 探针自己起不来: %s" % e)
        return 4

    t = threading.Thread(target=serve, args=(srv,))
    t.start()
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        c.close()
    except OSError as e:
        print("ORIGDST=error 连不上探针自己的监听: %s" % e)
        t.join(10)
        srv.close()
        return 4
    t.join(10)
    srv.close()
    if not result:
        print("ORIGDST=error 探针没拿到结果(accept 超时)")
        return 4
    print("ORIGDST=%s" % result["msg"])
    return result["rc"]


if __name__ == "__main__":
    sys.exit(main())

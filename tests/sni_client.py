#!/usr/bin/env python3
"""向 redir 入口发一个带指定 SNI 的 TLS ClientHello, 触发 SNI 嗅探。

## 成功契约(按真实协议, 不是按"握手成功")

对端最终是 mock_socks.py —— 它完成 SOCKS5 握手、记下 CONNECT 目标、读掉首包(ClientHello)
就 close, **从不说 TLS**。所以握手以 EOF/reset 结束是**预期终止**, 不是失败: 本支的任务只是
把 ClientHello 送进去让核心嗅到 SNI, 分流对不对由**出口的接收记录**判定, 不由本支判定。

反过来也不能把错误全吞掉恒返回 0: 连不上入口、对端既不回应也不关闭(超时)是真的异常。
而且有一条必须说清楚 —— **"入口收下就立刻关掉"与"健康路径下 mock 读完首包再关"在客户端
这一侧是同一种现象**(都是 EOF/reset, 实测耗时也相近)。本支因此只如实分类, 不替调用方
下"分流错了"这种结论; 判别要靠出口记录, 以及用下面打出的 local 地址去关联核心日志。

## 输出(stdout 恒一行, 供调用方记录与关联)
    CLIENT sni=<sni> local=<ip:port> phase=<connect|handshake> result=<...> dur=<秒> [err=...]

## 退出码
    0  peer_closed         —— ClientHello 已交给内核, 连接由对端终止(**预期终止**)
    0  handshake_completed —— 握手竟然完成(本夹具下不该出现, 但不是客户端的错)
    2  connect_failed      —— 连不上入口
    4  timeout             —— 对端既不回应也不关闭, 等到超时
    5  other_error         —— 其它错误(带 errno/类型)
用法: sni_client.py <host> <port> <sni>
"""
import errno
import socket
import ssl
import sys
import time


def main():
    host, port, sni = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    t0 = time.monotonic()
    local = "-"
    phase = "connect"

    def emit(result, rc, err=""):
        print("CLIENT sni=%s local=%s phase=%s result=%s dur=%.3f%s"
              % (sni, local, phase, result, time.monotonic() - t0,
                 (" err=%s" % err) if err else ""), flush=True)
        return rc

    try:
        raw = socket.create_connection((host, port), timeout=5)
    except OSError as e:
        return emit("connect_failed", 2, "%s(%s)" % (errno.errorcode.get(e.errno, "?"), e))
    local = "%s:%d" % raw.getsockname()
    raw.settimeout(5)
    phase = "handshake"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    s = ctx.wrap_socket(raw, server_hostname=sni, do_handshake_on_connect=False)
    try:
        s.do_handshake()                      # 发出 ClientHello(含 SNI)
    except (socket.timeout, ssl.SSLWantReadError) as e:
        rc = emit("timeout", 4, type(e).__name__)
    except (ssl.SSLEOFError, ssl.SSLZeroReturnError, ConnectionResetError,
            BrokenPipeError) as e:
        rc = emit("peer_closed", 0, type(e).__name__)      # 预期终止
    except ssl.SSLError as e:
        # 对端不是 TLS 服务时也可能报成通用 SSLError(记录原文, 仍按预期终止计)
        rc = emit("peer_closed", 0, "SSLError:%s" % (getattr(e, "reason", None) or e))
    except OSError as e:
        rc = emit("other_error", 5, "%s(%s)" % (errno.errorcode.get(e.errno, "?"), e))
    else:
        rc = emit("handshake_completed", 0)
    finally:
        try:
            s.close()
        except OSError:
            pass
    return rc


if __name__ == "__main__":
    sys.exit(main())

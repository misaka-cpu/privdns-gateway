#!/usr/bin/env python3
"""E2E 用的可编程 UDP DNS 桩。

两种用途:
  1. 当"普通上游" —— 只计数 + 给一个可辨认的应答;
  2. 当"坏掉的 witness" —— 按 mode 制造各种故障, 用来验普通 DNS 有没有被拖累。

每个实例有**自己的**计数文件与日志。上一轮踩过的坑就是两个观察端写同一个文件, 结果
"命中了谁"根本分不出来 —— 所以这里把路径做成必填参数, 不给默认值。

用法: dns-stub.py --port P --count FILE --log FILE [--mode M] [--answer IP]
mode: answer(默认) | silent | truncate | wrongid | servfail | die
"""
import argparse
import os
import socket
import struct
import sys
import time


def qname_of(pkt):
    i, out = 12, []
    while i < len(pkt):
        n = pkt[i]
        if n == 0 or (n & 0xC0):
            break
        out.append(pkt[i + 1:i + 1 + n].decode("ascii", "replace"))
        i += 1 + n
    return ".".join(out)


def bump(path):
    """计数用 O_APPEND 追加一行, 不做读-改-写 —— 并发下不会丢。"""
    with open(path, "a") as f:
        f.write("1\n")
        f.flush()
        os.fsync(f.fileno())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--count", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--mode", default="answer")
    ap.add_argument("--answer", default="192.0.2.77")
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", a.port))
    open(a.count, "a").close()
    with open(a.log, "a") as f:
        f.write("started mode=%s port=%d\n" % (a.mode, a.port))
        f.flush()
    print("stub ready %s:%d mode=%s" % ("127.0.0.1", a.port, a.mode), flush=True)

    while True:
        try:
            pkt, src = s.recvfrom(4096)
        except OSError:
            continue
        if len(pkt) < 12:
            continue
        bump(a.count)
        with open(a.log, "a") as f:
            f.write("%.3f q=%s len=%d\n" % (time.time(), qname_of(pkt), len(pkt)))
            f.flush()

        if a.mode == "silent":
            continue                                   # 收了不回 —— 让上游侧超时
        if a.mode == "die":
            os._exit(9)                                # 处理到一半直接退

        qid = pkt[:2]
        if a.mode == "wrongid":
            qid = bytes([pkt[0] ^ 0xFF, pkt[1] ^ 0xFF])
        rcode = 0x02 if a.mode == "servfail" else 0x00
        head = qid + bytes([0x81, 0x80 | rcode]) + pkt[4:6] + b"\x00\x00\x00\x00\x00\x00"
        resp = head + pkt[12:]
        if a.mode == "truncate":
            resp = resp[:6]                            # 明显截断的半截包
        try:
            s.sendto(resp, src)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""E2E 用的可编程 UDP DNS 桩。

两种用途:
  1. 当"普通上游" —— 只计数 + 给一个可辨认的应答;
  2. 当"坏掉的 witness" —— 按 mode 制造各种故障, 用来验普通 DNS 有没有被拖累。

每个实例有**自己的**计数文件与日志。上一轮踩过的坑就是两个观察端写同一个文件, 结果
"命中了谁"根本分不出来 —— 所以这里把路径做成必填参数, 不给默认值。

用法: dns-stub.py --port P --count FILE --log FILE [--mode M] [--answer IP]
mode: answer(默认) | answer-a | silent | truncate | wrongid | servfail | die

`answer` 是历史默认: NOERROR 但 **ANCOUNT=0**(不带任何记录)。已有调用方依赖这一点,
所以它一个字节都没改。

`answer-a` 是**新增的可选模式**: 在 `answer` 的基础上带一条 A 记录, 地址由 --answer 指定。
它是给"要用上游答案作判据"的场景准备的 —— 没有它就分不出"上游答了什么"和"根本没问上游"。
不指定 --mode 时行为与以前完全一致。
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


def _qname_end(pkt):
    """问题段里名字结束后的偏移(指向 QTYPE 的第一个字节)。"""
    i = 12
    while i < len(pkt):
        n = pkt[i]
        if n == 0:
            return i + 1
        if n & 0xC0:
            return i + 2
        i += 1 + n
    return i


def qtype_of(pkt):
    """问题段的 QTYPE。名字走完之后紧跟 2 字节 QTYPE。"""
    i = _qname_end(pkt)
    if i + 2 > len(pkt):
        return 0
    return struct.unpack("!H", pkt[i:i + 2])[0]


def question_only(pkt):
    """只取问题段(名字 + QTYPE + QCLASS)。

    为什么必须截: dig 的查询包里**还带着 EDNS0 的 OPT 记录**(附加段)。直接把 pkt[12:]
    原样抄回去, 再在后面接一条 A 记录, 那条 OPT 就落在答案段的位置上被当成第一条记录读,
    客户端看到的是一坨 base64 垃圾。默认的 answer 模式因为 ANCOUNT=0 没人去读, 所以一直
    没暴露 —— 但一旦真的带记录就必须截干净。
    """
    return pkt[12:_qname_end(pkt) + 4]


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
        # answer-a: 带一条 A 记录(仅对 qtype=A 的查询); 其余模式与以前逐字节相同。
        ancount = b"\x00\x00"
        rr = b""
        if a.mode == "answer-a" and qtype_of(pkt) == 1:
            ancount = b"\x00\x01"
            rr = (b"\xc0\x0c"                      # 指回问题段的名字
                  + b"\x00\x01\x00\x01"           # TYPE=A CLASS=IN
                  + struct.pack("!I", 60)            # TTL
                  + b"\x00\x04"
                  + bytes(int(x) for x in a.answer.split(".")))
        head = qid + bytes([0x81, 0x80 | rcode]) + pkt[4:6] + ancount + b"\x00\x00\x00\x00"
        if rr:
            resp = head + question_only(pkt) + rr      # 带记录时必须只留问题段(见 question_only)
        else:
            resp = head + pkt[12:]                     # 历史默认: 一个字节都不变
        if a.mode == "truncate":
            resp = resp[:6]                            # 明显截断的半截包
        try:
            s.sendto(resp, src)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())

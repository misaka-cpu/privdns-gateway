#!/usr/bin/env python3
"""去广告测试专用的"上游":对每个收到的查询记一行日志,并返回**非空**应答。

为什么单独一份而不复用 tests/mock_dns.py:那一份被 dns-policy-test.sh 用着,而这里需要
**记录收到了哪些查询** —— 这是"被阻断的查询不得访问上游"那条判据唯一的证据来源。
判据不能只看客户端拿到什么:阻断成功但同时仍向上游发了一份,客户端侧完全看不出来。

返回非空应答是有意的:这样"被阻断"与"上游本来就没有答案"才区分得开。
用法: adblock_upstream.py <listen_port> <answer_ip> <log_path>
"""
import socket
import struct
import sys

ANSWER_AAAA = "2001:db8::1"


def qname_of(data):
    """从查询里取出 qname 与 qtype。只用于测试日志,不解析压缩指针。"""
    labels, i = [], 12
    while i < len(data) and data[i]:
        n = data[i]
        labels.append(data[i + 1:i + 1 + n].decode("ascii", "replace"))
        i += 1 + n
    qtype = struct.unpack("!H", data[i + 1:i + 3])[0] if i + 3 <= len(data) else 0
    return ".".join(labels), qtype


def build_response(query, answer_ip):
    if len(query) < 12:
        return None
    qid = query[:2]
    name, qtype = qname_of(query)
    qend = 12
    while qend < len(query) and query[qend]:
        qend += 1 + query[qend]
    qend += 5                                   # 0 结尾 + qtype(2) + qclass(2)
    question = query[12:qend]
    hdr = qid + b"\x81\x80" + b"\x00\x01"
    ptr = b"\xc0\x0c"
    if qtype == 1:
        rd = socket.inet_aton(answer_ip)
        rr = ptr + struct.pack("!HHIH", 1, 1, 60, len(rd)) + rd
        return hdr + b"\x00\x01\x00\x00\x00\x00" + question + rr
    if qtype == 28:
        rd = socket.inet_pton(socket.AF_INET6, ANSWER_AAAA)
        rr = ptr + struct.pack("!HHIH", 28, 1, 60, len(rd)) + rd
        return hdr + b"\x00\x01\x00\x00\x00\x00" + question + rr
    if qtype == 65:
        rd = b"\x00\x01\x00\x00"                # 最小 SVCB: prio=1, target=root
        rr = ptr + struct.pack("!HHIH", 65, 1, 60, len(rd)) + rd
        return hdr + b"\x00\x01\x00\x00\x00\x00" + question + rr
    return hdr + b"\x00\x00\x00\x00\x00\x00" + question


def main():
    port, answer_ip, logp = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    while True:
        try:
            data, addr = s.recvfrom(2048)
        except OSError:
            break
        try:
            name, qtype = qname_of(data)
            with open(logp, "a", encoding="utf-8") as fh:
                fh.write("%s qtype=%d\n" % (name, qtype))
        except Exception:                        # noqa: BLE001 - 日志坏了不该拖垮上游
            pass
        resp = build_response(data, answer_ip)
        if resp:
            s.sendto(resp, addr)


if __name__ == "__main__":
    main()

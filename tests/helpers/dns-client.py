#!/usr/bin/env python3
"""E2E 用的 DNS 客户端: 同一个查询能分别走 UDP53 / TCP53 / DoT(可指定或省略 SNI)。

输出一行 KEY=VALUE, 供 shell 直接解析:
  rc=<0|1> mode=.. elapsed_ms=.. resp_len=.. qid_echo=<0|1> qr=<0|1>
  rcode=.. ancount=.. qdcount=.. question_match=<0|1> has_addr=<0|1> err=..

用法: dns-client.py --mode M --host H --port P --qname N [--qtype T] [--sni S] [--timeout T]
mode: udp | tcp | dot | dot-nosni | dot-handshake
"""
import argparse
import socket
import ssl
import struct
import sys
import time


def wire(qname, qtype, qid):
    parts = [p for p in qname.rstrip(".").split(".") if p]
    q = b"".join(bytes([len(p)]) + p.encode("ascii") for p in parts) + b"\x00"
    return struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack("!HH", qtype, 1)


def parse(resp, sent_qid, sent_question):
    out = {"resp_len": len(resp)}
    if len(resp) < 12:
        out.update(qid_echo=0, qr=0, rcode="", ancount="", qdcount="", question_match=0, has_addr=0)
        return out
    qid, flags, qd, an, ns, ar = struct.unpack("!HHHHHH", resp[:12])
    out["qid_echo"] = 1 if qid == sent_qid else 0
    out["qr"] = 1 if flags & 0x8000 else 0
    out["rcode"] = flags & 0x0F
    out["ancount"] = an
    out["qdcount"] = qd
    out["question_match"] = 1 if resp[12:12 + len(sent_question)] == sent_question else 0
    # ancount=0 时不可能带地址; 有 answer 就当带了地址(本轮只需要区分"有没有")
    out["has_addr"] = 1 if an > 0 else 0
    return out


def run(a):
    qid = 0x4242
    pkt = wire(a.qname, a.qtype, qid)
    question = pkt[12:]
    t0 = time.time()
    try:
        if a.mode == "udp":
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(a.timeout)
            try:
                s.sendto(pkt, (a.host, a.port))
                resp = s.recvfrom(4096)[0]
            finally:
                s.close()
        else:
            raw = socket.create_connection((a.host, a.port), timeout=a.timeout)
            try:
                if a.mode.startswith("dot"):
                    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                    ctx.check_hostname = False
                    ctx.verify_mode = ssl.CERT_NONE
                    sni = None if a.mode == "dot-nosni" else (a.sni or None)
                    c = ctx.wrap_socket(raw, server_hostname=sni)
                else:
                    c = raw
                if a.mode == "dot-handshake":
                    return {"rc": 0, "elapsed_ms": int((time.time() - t0) * 1000),
                            "resp_len": 0, "qid_echo": 0, "qr": 0, "rcode": "",
                            "ancount": "", "qdcount": "", "question_match": 0,
                            "has_addr": 0, "err": ""}
                c.settimeout(a.timeout)
                c.sendall(struct.pack("!H", len(pkt)) + pkt)
                head = b""
                while len(head) < 2:
                    ch = c.recv(2 - len(head))
                    if not ch:
                        raise ConnectionError("eof")
                    head += ch
                n = struct.unpack("!H", head)[0]
                resp = b""
                while len(resp) < n:
                    ch = c.recv(n - len(resp))
                    if not ch:
                        break
                    resp += ch
            finally:
                try:
                    raw.close()
                except Exception:  # noqa: BLE001
                    pass
        out = parse(resp, qid, question)
        out["rc"] = 0
        out["err"] = ""
    except Exception as e:  # noqa: BLE001
        out = {"rc": 1, "resp_len": 0, "qid_echo": 0, "qr": 0, "rcode": "", "ancount": "",
               "qdcount": "", "question_match": 0, "has_addr": 0,
               "err": "%s" % type(e).__name__}
    out["elapsed_ms"] = int((time.time() - t0) * 1000)
    out["mode"] = a.mode
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--qname", required=True)
    ap.add_argument("--qtype", type=int, default=1)
    ap.add_argument("--sni", default="")
    ap.add_argument("--timeout", type=float, default=5.0)
    r = run(ap.parse_args())
    print(" ".join("%s=%s" % (k, r[k]) for k in sorted(r)))

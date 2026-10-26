#!/usr/bin/env python3
# F-1 真实验收专用的外来占用者 —— 测试夹具, **不是产品的一部分**; 只由 tests/e2e-real-f1.sh 装出的 runtime unit 调用。
# 启动时只做一件事: --arm 指向的文件存在且大小为 0 ⇒ 先绑 UDP 127.0.0.1:<port>, 记 held; 不存在或非空 ⇒ 不绑, 记 idle;
# 绑不上记 hold-failed; 判不了(stat 失败)记 arm-unreadable 且不绑。四种都照常报 READY=1(Type=notify), 不让 mosdns 的重启事务因为它失败。
# 不读 --arm 的内容(只 stat), 不写任何产品文件, 不接收、不回答任何报文。
# 记录(追加到 --log, 同时打到 stdout 进 journal): "<CLOCK_MONOTONIC 纳秒> <事件> pid=<pid>"。记录写不进 ⇒ 非零退出(本次启动失败, 由验收器看见)。
import argparse
import os
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--arm", required=True)
    ap.add_argument("--log", required=True)
    a = ap.parse_args()
    if not 1 <= a.port <= 65535:
        print("f1-occupant: port out of range", file=sys.stderr)
        return 64

    def rec(ev):
        line = "%d %s pid=%d" % (time.clock_gettime_ns(time.CLOCK_MONOTONIC), ev, os.getpid())
        with open(a.log, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        print("f1-occupant: " + line, flush=True)

    held = None
    try:
        armed = os.stat(a.arm).st_size == 0
        why = None
    except FileNotFoundError:
        armed, why = False, None
    except OSError as e:
        armed, why = False, e.errno
    if why is not None:
        rec("arm-unreadable errno=%d" % why)
    elif armed:
        held = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            held.bind(("127.0.0.1", a.port))
            rec("held")
        except OSError as e:
            held.close()
            held = None
            rec("hold-failed errno=%d" % e.errno)
    else:
        rec("idle")
    addr = os.environ.get("NOTIFY_SOCKET")
    if addr:
        if addr.startswith("@"):
            addr = "\0" + addr[1:]
        n = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            n.sendto(b"READY=1", addr)
        finally:
            n.close()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.exit(main())

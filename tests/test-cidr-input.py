#!/usr/bin/env python3
"""内网卡来源段取值回归(lib/cidr.sh)。

真实装机踩出来的三件事:
  ① 抓包最长 90 秒, 而多数人**早就知道**自己的网段 —— 必须能边抓边输, 谁先出结果用谁;
  ② "可先手填"的提示得在**抓包期间**给, 等抓完再说等于白等一次;
  ③ 等满 90 秒后一个空回车就 die + 回滚整场安装 —— 填错/没填都该再给机会, 且要拦下
     形如 `172.22.0.0`(漏了 /16) 这种会渲染出"谁都匹配不上"的配置的输入。

竞速那部分必须在**真 pty** 里验: read -t 的行为、以及"抓包先到时把用户敲了一半的残留
清掉(免得漏进下一个提问当答案)"，用管道都复现不出来。
"""
import os
import pty
import select
import subprocess
import sys
import time

import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "lib", "cidr.sh")
# 假 tcpdump 的存放处。以前是写死的 /tmp/pdg-cidr-test-bin: 跑完没人清, 而且两个人(或两支
# 并发的用例)同时跑就会互相覆盖对方的桩 —— 那时"多久才抓到"由别人说了算, 竞速判据随机翻车。
BIN = tmpguard.mkdtemp(prefix="pdg-cidr-bin.")

pass_n = 0


def ok(msg):
    global pass_n
    pass_n += 1
    print(f"[OK]   {msg}")


def bad(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


def fake_tcpdump(delay):
    """假 tcpdump: delay 秒后吐几个私网入站包(控制"多久才抓到")。

    **必须模仿 tcpdump ≥4.99 的 `-i any` 格式**, 也就是带上时刻 / 接口名 / 方向:

        <时刻> <接口> In  IP <源>.<端口> > <目的>.<端口>: …

    原来的桩吐的是老格式(整行只有 `IP a.b.c.d.p > …`)。后果不是"少测一条路径", 而是
    **这支测试在装了 Tailscale 的机器上恒红**:
      · lib/detect-internal-range.sh 会先用 `tcpdump -ni any -c 1` 探一次"这台的 tcpdump
        打不打接口名"; 打不出来就 ifname_ok=0;
      · 宿主有 tailscale0 且 ifname_ok=0 时, 产品**有意拒绝猜测**(宁可让人手输, 也不冒险
        把 tailnet 地址当成内网卡来源)—— 于是 RESULT 为空, 断言失败。
    产品那个分支是对的; 错的是桩没把现代 tcpdump 的样子演出来。

    另一半同样要紧: **探测调用要立刻应答**。探测那句外面套着 `timeout 3`, 而桩原来对所有
    调用一律先 sleep delay ——  delay=60 的那一格必然把探测拖超时, 于是又回到 ifname_ok=0。
    真机上这两次调用本来就不同: 探测只要一个包, 抓取要等够样本。按 `-c 1` 区分即可。
    """
    os.makedirs(BIN, exist_ok=True)
    p = os.path.join(BIN, "tcpdump")
    line = "12:34:56.789012 enp1s0 In  IP 172.22.0.5.55000 > 10.0.0.1.853: tcp"
    with open(p, "w") as f:
        f.write(
            "#!/bin/sh\n"
            "# 探测调用(-c 1, 无 BPF 过滤): 立刻给一行现代格式, 让 ifname_ok=1\n"
            "for a in \"$@\"; do\n"
            "  if [ \"$a\" = \"1\" ] && [ \"$prev\" = \"-c\" ]; then\n"
            "    printf '%s\\n'; exit 0\n"
            "  fi\n"
            "  prev=$a\n"
            "done\n"
            "sleep %s\n"
            "printf '%s\\n%s\\n%s\\n'\n"
            "exit 0\n" % (line, delay, line, line, line))
    os.chmod(p, 0o755)


def run_pty(script, feed_after=None, feed=b"", limit=90):
    """在真 pty 里跑 script; feed_after 秒后喂 feed。返回 (输出, 耗时)。"""
    t0 = time.time()
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", "-c", script])
    buf = b""
    sent = False
    while time.time() - t0 < limit:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
            buf += d
        if feed_after is not None and not sent and time.time() - t0 >= feed_after:
            os.write(fd, feed)
            sent = True
        wp, _st = os.waitpid(pid, os.WNOHANG)
        if wp:
            time.sleep(0.2)
            try:
                while True:
                    d = os.read(fd, 4096)
                    if not d:
                        break
                    buf += d
            except OSError:
                pass
            break
    return buf.decode(errors="replace"), time.time() - t0


def sh(snippet):
    return subprocess.run(["bash", "-c", f"source {LIB}\n{snippet}"],
                          capture_output=True, text=True)


def main():
    # ── ③ 形态校验: 漏 /前缀、越界八位组、前缀 >32 都必须拒 ──
    for good in ("172.22.0.0/16", "10.0.0.0/8", "100.64.0.0/10", "192.168.1.0/24",
                 "0.0.0.0/0", "255.255.255.255/32"):
        if sh(f'pdg_cidr_valid "{good}"').returncode != 0:
            bad(f"合法 CIDR 被拒: {good}")
    ok("pdg_cidr_valid 接受合法 CIDR(含 /0 /32 边界)")
    for bad_v in ("", "172.22.0.0", "172.22.0.0/33", "256.1.1.1/16", "1.2.3/16",
                  "abc/16", "/16", "1.2.3.4.5/16", "172.22.0.0 /16"):
        if sh(f'pdg_cidr_valid "{bad_v}"').returncode == 0:
            bad(f"非法 CIDR 被接受: [{bad_v}]")
    ok("pdg_cidr_valid 拒绝漏前缀/越界/畸形输入(含 `172.22.0.0` 这种漏 /16 的)")

    race = (f'export PATH={BIN}:$PATH\n'
            f'source {LIB}\n'
            'r=$(pdg_detect_cidr_race %d 203.0.113.1); echo "RESULT=[$r]"')

    # ── ① 手输先到: 抓包要 60s, 用户 2s 就输 → 立刻用手输值, 不等抓包 ──
    fake_tcpdump(60)
    out, el = run_pty(race % 60, feed_after=2, feed=b"172.22.0.0/16\n")
    if "RESULT=[172.22.0.0/16]" not in out:
        bad(f"手输未被采纳: {out[-300:]}")
    if el > 20:
        bad(f"手输已给出却仍在等抓包({el:.0f}s)")
    ok(f"手输先到 → 立即采用并掐掉抓包({el:.1f}s, 未干等 60s)")

    # ── ② 抓包期间就得提示"现在能直接输" ──
    if "现在就能直接输入" not in out:
        bad("抓包期间没有提示可以手输")
    ok("抓包期间即提示可直接手输(不是等抓完才说)")

    # ── 抓包先到: 用抓到的值, 同样不等满时限 ──
    fake_tcpdump(3)
    out, el = run_pty(race % 40)
    if "RESULT=[172.22.0.0/16]" not in out:
        bad(f"抓包结果未被采用: {out[-300:]}")
    if el > 25:
        bad(f"抓到了却仍等满时限({el:.0f}s)")
    ok(f"抓包先到 → 直接采用, 不再多问一遍({el:.1f}s, 未干等 40s)")

    # ── 抓包先到时用户敲了一半(无回车): 残留不得漏进下一个提问 ──
    fake_tcpdump(3)
    leak = (f'export PATH={BIN}:$PATH\n'
            f'source {LIB}\n'
            'r=$(pdg_detect_cidr_race 40 203.0.113.1); echo "RESULT=[$r]"\n'
            'nxt=""; read -t 2 -r nxt </dev/tty; echo "NEXT=[$nxt]"')
    out, _el = run_pty(leak, feed_after=1.0, feed=b"172.9")     # 敲一半, 不回车
    if "NEXT=[]" not in out:
        bad(f"半截输入漏进了下一个提问: {out[-300:]}")
    ok("抓包先到时清掉半截输入(不会漏进平台/token 提问当答案)")

    # ── 无终端(非交互/CI): 退化成纯抓包, 不因 /dev/tty 不可用而崩 ──
    fake_tcpdump(2)
    r = subprocess.run(["bash", "-c",
                        f'export PATH={BIN}:$PATH; source {LIB}; '
                        'pdg_detect_cidr_race 20 203.0.113.1'],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL,
                       start_new_session=True)     # 无控制终端
    if r.stdout.strip() != "172.22.0.0/16":
        bad(f"无终端时纯抓包失败: rc={r.returncode} out={r.stdout!r} err={r.stderr[-200:]!r}")
    ok("无可用终端 → 退化成纯抓包(非交互装机不受影响)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

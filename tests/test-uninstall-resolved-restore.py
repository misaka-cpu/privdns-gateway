#!/usr/bin/env python3
"""卸载还原 systemd-resolved: 不许漏启用, 也不许把装机写的 127.0.0.1 留在 resolved 的全局 DNS 里。

两次真机卸载(.200, 2026-10-29)各中了一种:
  · 探测写成 `systemctl list-unit-files | grep -q '^systemd-resolved'`, 卸载脚本开着 pipefail:
    grep -q 命中即退, systemctl 后面的输出撞上已关的管道挨 SIGPIPE(141), 整条判假 → resolved
    根本没被重新启用(实测 200 次里 77 次)。resolv.conf 指着 /run 里的旧文件, 重启后整机没有 DNS。
    清单只有十几 KB —— 守卫 test-pipefail-grepq-guard.py 按"整体透传 >64KiB 文件"判风险, 管不到它。
  · 探测碰巧成立时: resolved 先于 resolv.conf 还原启动, 读到装机写的静态文件, 把 127.0.0.1 收进
    全局 DNS; 之后 resolv.conf 换回它自己的文件, 127.0.0.1 仍一直留着(实测 resolvectl), 而 mosdns
    已经卸了。为什么不清: 按 resolved 源码, 它发现 /etc/resolv.conf 是自己的文件就直接返回, 不清
    先前收进来的服务器 —— 这一半是推断, 替身照这个模型写。

这里把 uninstall.sh 里**原样**那一段抽出来, 路径改到临时根下, 配一个会模拟上面两种行为的
systemctl 替身真跑一遍:
  · 替身的 list-unit-files 有两种出法: slow(先写出 resolved 那行, 停一下再写其余 —— 管道里的
    grep -q 一定先退, 后面的写必挨 SIGPIPE)与 fast(不到 1KB 一次写完, 不会挨; 用来单独钉住
    "探测成立时的顺序问题")。
  · 替身的 start / restart 模拟 resolved 读 /etc/resolv.conf: 是它自己 /run 下的文件就不收外部
    服务器, 否则把里面的 nameserver 收进全局; 已经在跑时 start 不重读, restart 重读。
"""
import os
import re
import stat
import subprocess
import sys

import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UN = os.environ.get("PDG_UNINSTALL_SH") or os.path.join(ROOT, "uninstall.sh")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def finish():
    print("-" * 62)
    print("test-uninstall-resolved-restore.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1 if FAIL[0] else 0)


print("── 0. 从 uninstall.sh 抽出 DNS 还原段(原样) ──")
src = open(UN, encoding="utf-8").read()
BEGIN = "# DNS: 还原 systemd-resolved 与 resolv.conf"
END = 'if [[ -n "$RESOLV_WARN" ]]; then'
if src.count(BEGIN) != 1 or src.count(END) != 1:
    bad("起止标记不是恰好各一处(BEGIN %d, END %d), 抽不出来" % (src.count(BEGIN), src.count(END)))
    finish()
block = src[src.index(BEGIN):src.index(END)]
setline = re.search(r"^set -[a-z]*o pipefail$", src, re.M)
# 抽空了也会"跑通": 先确认抽到的是那段真代码, 而且卸载脚本自己确实开着 pipefail
if "resolv.conf.pdg-orig" in block and "systemd-resolved" in block and setline:
    ok("抽到 %d 行; 卸载脚本的 `%s` 一并带上" % (block.count("\n"), setline.group(0)))
else:
    bad("抽到的段落不对或卸载脚本没开 pipefail: %r" % (block[:120],))
    finish()


def build(tmp):
    """把段落里的绝对路径改到临时根下; 改完还有 /etc 或 /run 就拒绝运行(不许碰宿主)。"""
    b = block.replace("/etc/resolv.conf", tmp + "/etc/resolv.conf")
    b = b.replace("/run/systemd/resolve/", tmp + "/run/systemd/resolve/")
    left = [m.group(0) for m in re.finditer(r"(?<![\w.-])/(?:etc|run)/[^\s\"']*", b)
            if not m.group(0).startswith(tmp)]
    return b, left


STUB = r'''#!/usr/bin/env bash
# systemctl 替身: 只认本测试用得到的几种调用; 每次调用记一行(调用 | 当时 /etc/resolv.conf 的样子)
T="$PDG_T"
shape() {
  if [[ -L "$T/etc/resolv.conf" ]]; then echo "link:$(readlink "$T/etc/resolv.conf")"
  elif [[ -f "$T/etc/resolv.conf" ]]; then echo "file:$(tr '\n' ' ' < "$T/etc/resolv.conf")"
  else echo "missing"; fi
}
echo "$* | $(shape)" >> "$T/calls"
read_conf() {   # resolved 启动 / 重启时读 /etc/resolv.conf
  mkdir -p "$T/run/systemd/resolve"
  printf 'nameserver 8.8.8.8\n' > "$T/run/systemd/resolve/resolv.conf"
  printf 'nameserver 127.0.0.53\n' > "$T/run/systemd/resolve/stub-resolv.conf"
  local tgt=""
  [[ -L "$T/etc/resolv.conf" ]] && tgt="$(readlink "$T/etc/resolv.conf")"
  case "$tgt" in
    "$T/run/systemd/resolve/resolv.conf"|"$T/run/systemd/resolve/stub-resolv.conf") : > "$T/global" ;;
    *) grep -h '^nameserver' "$T/etc/resolv.conf" 2>/dev/null | awk '{print $2}' > "$T/global" ;;
  esac
  : > "$T/running"
}
case "$1" in
  list-unit-files)
    line='systemd-resolved.service                   disabled        enabled'
    if [[ "$PDG_STUB_MODE" == slow ]]; then
      printf 'UNIT FILE STATE PRESET\n%s\n' "$line"
      sleep 0.3                                     # 管道另一头的 grep -q 早已命中退出
      for i in $(seq 1 300); do printf 'zz-%03d.service static -\n' "$i"; done
    else
      # 一次写完且远小于 4KiB 的 stdio 缓冲: 探测必定成立。清单一长, bash 的 printf 也会分几次写,
      # 照样可能挨 SIGPIPE —— 负控里 300 行(约 8KB)的版本就随机中过, 所以这里刻意只给 20 行。
      all="$(printf 'UNIT FILE STATE PRESET\n%s\n' "$line"; for i in $(seq 1 20); do printf 'zz-%03d.service static -\n' "$i"; done)"
      printf '%s\n' "$all"
    fi ;;
  enable)
    if [[ "$2" == --now && "$3" == systemd-resolved ]]; then
      [[ -e "$T/running" ]] || read_conf            # start 一个已在跑的单元不重读
    fi ;;
  start)   [[ "$2" == systemd-resolved && ! -e "$T/running" ]] && read_conf ;;
  restart) [[ "$2" == systemd-resolved ]] && read_conf ;;
esac
exit 0
'''


def scenario(name, mode, run_exists):
    """装机后的典型现场: 备份是指向 /run 的符号链接, 当前 resolv.conf 是装机写的静态文件。"""
    tmp = tmpguard.mkdtemp(prefix="pdg-unresolved.")
    os.makedirs(tmp + "/etc")
    os.makedirs(tmp + "/bin")
    os.makedirs(tmp + "/run/systemd/resolve")
    if run_exists:                                   # 同一次开机: resolved 装机前写下的文件还在
        open(tmp + "/run/systemd/resolve/resolv.conf", "w").write("nameserver 8.8.8.8\n")
    os.symlink(tmp + "/run/systemd/resolve/resolv.conf", tmp + "/etc/resolv.conf.pdg-orig")
    open(tmp + "/etc/resolv.conf", "w").write("nameserver 127.0.0.1\nnameserver 1.1.1.1\n")
    sp = tmp + "/bin/systemctl"
    open(sp, "w").write(STUB)
    os.chmod(sp, os.stat(sp).st_mode | stat.S_IXUSR)
    body, left = build(tmp)
    if left:
        bad("%s: 改写后仍有宿主绝对路径 %s —— 拒绝运行" % (name, left))
        return None
    script = "%s\n%s\necho \"RESOLV_WARN=[$RESOLV_WARN]\"\n" % (setline.group(0), body)
    env = dict(os.environ, PATH=tmp + "/bin:" + os.environ.get("PATH", "/usr/bin:/bin"),
               PDG_T=tmp, PDG_STUB_MODE=mode)
    r = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=60)
    calls = open(tmp + "/calls").read() if os.path.exists(tmp + "/calls") else ""
    glob = open(tmp + "/global").read().split() if os.path.exists(tmp + "/global") else None
    st = {
        "rc": r.returncode, "out": r.stdout, "calls": calls, "global": glob,
        "link": os.readlink(tmp + "/etc/resolv.conf") if os.path.islink(tmp + "/etc/resolv.conf") else None,
        "bak_left": os.path.lexists(tmp + "/etc/resolv.conf.pdg-orig"),
        "tmp": tmp,
    }
    return st


def check(name, st):
    if st is None:
        return
    t = st["tmp"]
    enabled = any(l.startswith("enable --now systemd-resolved") for l in st["calls"].splitlines())
    (ok if enabled else bad)("%s: resolved 被重新启用%s" % (
        name, "" if enabled else "(没有 enable 调用; 调用记录: %r)" % st["calls"]))
    g = st["global"]
    if g is None:
        bad("%s: resolved 从没启动过, 全局 DNS 无从谈起" % name)
    elif "127.0.0.1" in g:
        bad("%s: resolved 全局 DNS 里留着装机的 127.0.0.1(%s) —— 卸载后那里没人监听" % (name, " ".join(g)))
    else:
        ok("%s: resolved 全局 DNS 不含 127.0.0.1(%s)" % (name, " ".join(g) or "空: 只用链路 DNS"))
    want = t + "/run/systemd/resolve/resolv.conf"
    (ok if st["link"] == want else bad)("%s: /etc/resolv.conf 还原为装机前的符号链接%s" % (
        name, "" if st["link"] == want else "(实际 %r)" % st["link"]))
    (ok if not st["bak_left"] else bad)("%s: 还原成功后备份已删" % name)
    (ok if "RESOLV_WARN=[]" in st["out"] else bad)("%s: 没有报还原失败%s" % (
        name, "" if "RESOLV_WARN=[]" in st["out"] else "(%r)" % st["out"][-200:]))


print()
print("── 1. 慢清单(systemctl 还在写时 grep 已退): 探测不许被 SIGPIPE 反转 ──")
check("慢清单/同次开机", scenario("慢清单/同次开机", "slow", True))
check("慢清单/重启过", scenario("慢清单/重启过", "slow", False))

print()
print("── 2. 快清单(探测成立): resolved 不许把装机的 127.0.0.1 留在全局 DNS ──")
check("快清单/同次开机", scenario("快清单/同次开机", "fast", True))
check("快清单/重启过", scenario("快清单/重启过", "fast", False))

finish()

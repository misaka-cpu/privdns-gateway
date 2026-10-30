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

装机前的状态(装机记在 /etc/resolv.conf.pdg-resolved, 卸载按它还原):
  · 第 3 节只跑卸载段: 记录是 disabled / untouched / 认不出的内容时各该怎么做;
  · 第 4 节把 install.sh 里"释放 53 口"那一段(原样)与卸载段先后跑在同一个临时根下, 看装机前的
    resolved 状态与 resolv.conf 是否原样回来 —— 包括重装(备份已在)时不写记录、卸载照旧启用。
"""
import os
import re
import stat
import subprocess
import sys

import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UN = os.environ.get("PDG_UNINSTALL_SH") or os.path.join(ROOT, "uninstall.sh")
INSTALL = os.environ.get("PDG_INSTALL_SH") or os.path.join(ROOT, "install.sh")

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


def build(tmp, src=None):
    """把段落里的绝对路径改到临时根下; 改完还有 /etc 或 /run 就拒绝运行(不许碰宿主)。"""
    b = (block if src is None else src).replace("/etc/resolv.conf", tmp + "/etc/resolv.conf")
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
    [[ -n "${PDG_STUB_NOUNIT:-}" ]] && line='zz-000.service static -'      # 机器上没有 resolved
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
      : > "$T/enabled"
      [[ -e "$T/running" ]] || read_conf            # start 一个已在跑的单元不重读
    fi ;;
  disable)
    [[ "$2" == --now && "$3" == systemd-resolved ]] && rm -f "$T/running" "$T/enabled" ;;
  is-active)
    [[ "${*: -1}" == systemd-resolved && -e "$T/running" ]] && exit 0
    exit 3 ;;
  start)   [[ "$2" == systemd-resolved && ! -e "$T/running" ]] && read_conf ;;
  restart) [[ "$2" == systemd-resolved ]] && read_conf ;;
esac
exit 0
'''


def mkroot(prefix):
    tmp = tmpguard.mkdtemp(prefix=prefix)
    for d in ("/etc", "/bin", "/run/systemd/resolve"):
        os.makedirs(tmp + d)
    sp = tmp + "/bin/systemctl"
    open(sp, "w").write(STUB)
    os.chmod(sp, os.stat(sp).st_mode | stat.S_IXUSR)
    return tmp


def run_sh(tmp, script, mode, nounit=False):
    env = dict(os.environ, PATH=tmp + "/bin:" + os.environ.get("PATH", "/usr/bin:/bin"),
               PDG_T=tmp, PDG_STUB_MODE=mode)
    if nounit:
        env["PDG_STUB_NOUNIT"] = "1"
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=60)


def read(path):
    return open(path).read() if os.path.isfile(path) else None


def state(tmp, r, calls_from=0):
    """calls 只取第 calls_from 行之后的: 往返场景里只看卸载那一段做了什么。"""
    rc = tmp + "/etc/resolv.conf"
    glob = read(tmp + "/global")
    return {
        "rc": r.returncode, "out": r.stdout,
        "calls": "".join((read(tmp + "/calls") or "").splitlines(True)[calls_from:]),
        "global": None if glob is None else glob.split(),
        "link": os.readlink(rc) if os.path.islink(rc) else None,
        "content": None if os.path.islink(rc) else read(rc),
        "bak_left": os.path.lexists(tmp + "/etc/resolv.conf.pdg-orig"),
        "marker": read(tmp + "/etc/resolv.conf.pdg-resolved"),
        "running": os.path.exists(tmp + "/running"), "enabled": os.path.exists(tmp + "/enabled"),
        "tmp": tmp,
    }


def uninstall(tmp, name, mode, nounit=False):
    body, left = build(tmp)
    if left:
        bad("%s: 改写后仍有宿主绝对路径 %s —— 拒绝运行" % (name, left))
        return None
    script = "%s\n%s\necho \"RESOLV_WARN=[$RESOLV_WARN]\"\n" % (setline.group(0), body)
    before = len((read(tmp + "/calls") or "").splitlines())
    return state(tmp, run_sh(tmp, script, mode, nounit), before)


def scenario(name, mode, run_exists, marker=None, backup="link"):
    """装机后的典型现场: 备份是指向 /run 的符号链接, 当前 resolv.conf 是装机写的静态文件。
    marker: 装机记下的 resolved 状态(None = 没有记录, 即旧版本装的机器); backup="file": 装机前是静态文件。"""
    tmp = mkroot("pdg-unresolved.")
    if run_exists:                                   # 同一次开机: resolved 装机前写下的文件还在
        open(tmp + "/run/systemd/resolve/resolv.conf", "w").write("nameserver 8.8.8.8\n")
    if backup == "link":
        os.symlink(tmp + "/run/systemd/resolve/resolv.conf", tmp + "/etc/resolv.conf.pdg-orig")
    else:
        open(tmp + "/etc/resolv.conf.pdg-orig", "w").write("nameserver 9.9.9.9\n")
    open(tmp + "/etc/resolv.conf", "w").write("nameserver 127.0.0.1\nnameserver 1.1.1.1\n")
    if marker is not None:
        open(tmp + "/etc/resolv.conf.pdg-resolved", "w").write(marker)
    return uninstall(tmp, name, mode)


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


def resolved_actions(calls):
    return [l for l in calls.splitlines() if re.match(r"(enable|disable|start|restart)\b.*systemd-resolved", l)]


def check_left_alone(name, st, want_content="nameserver 9.9.9.9\n"):
    """装机前 resolved 没在跑: 卸载不许启用它, resolv.conf 换回装机前的静态文件。"""
    if st is None:
        return
    acts = resolved_actions(st["calls"])
    (ok if not acts else bad)("%s: 卸载没有启用 / 启动 / 重启 resolved%s" % (name, "" if not acts else "(实际 %r)" % acts))
    (ok if not st["running"] and not st["enabled"] else bad)("%s: resolved 仍是停用、没在跑" % name)
    (ok if st["link"] is None and st["content"] == want_content else bad)(
        "%s: /etc/resolv.conf 还原为装机前的静态文件%s" % (
            name, "" if st["content"] == want_content else "(实际 链接 %r 内容 %r)" % (st["link"], st["content"])))
    (ok if not st["bak_left"] else bad)("%s: 还原成功后备份已删" % name)
    (ok if "RESOLV_WARN=[]" in st["out"] else bad)("%s: 没有报还原失败" % name)


def check_marker_gone(name, st):
    if st is not None:
        (ok if st["marker"] is None else bad)("%s: 还原成功后装机记录已删%s" % (
            name, "" if st["marker"] is None else "(还在: %r)" % st["marker"]))


print()
print("── 3. 装机记下的 resolved 状态: 卸载按它还原 ──")
st = scenario("记录 disabled", "fast", True, marker="disabled\n")
check("记录 disabled", st)
check_marker_gone("记录 disabled", st)
st = scenario("记录 untouched", "fast", False, marker="untouched\n", backup="file")
check_left_alone("记录 untouched", st)
check_marker_gone("记录 untouched", st)
st = scenario("记录认不出", "fast", True, marker="garbage\n")
check("记录认不出(照旧启用)", st)
check_marker_gone("记录认不出", st)

print()
print("── 4. 装机(install.sh 原样)→ 卸载: resolved 与 resolv.conf 回到装机前 ──")
isrc = open(INSTALL, encoding="utf-8").read()
IB = "# ── 释放 53 口(必须在第 7 步之前) ──"
IE = "# ── 7. geosite 规则库 ──"
STEP8 = '_write_resolv "nameserver 127.0.0.1" "nameserver 1.1.1.1"'   # 第 8 步装好 mosdns 后写的
iset = re.search(r"^set -[a-z]*o pipefail$", isrc, re.M)
if isrc.count(IB) != 1 or isrc.count(IE) != 1 or isrc.count(STEP8) != 1 or not iset:
    bad("install.sh 里抽不到释放 53 口那一段(起 %d, 止 %d, 第 8 步那行 %d, set 行 %s)" % (
        isrc.count(IB), isrc.count(IE), isrc.count(STEP8), bool(iset)))
    finish()
iblock = isrc[isrc.index(IB):isrc.index(IE)]
if "resolv.conf.pdg-resolved" in iblock and "disable --now systemd-resolved" in iblock:
    ok("抽到 install.sh 释放 53 口那一段 %d 行; `%s` 一并带上" % (iblock.count("\n"), iset.group(0)))
else:
    bad("抽到的 install.sh 段落不对: %r" % (iblock[:120],))
    finish()


def roundtrip(name, pre, nounit=False):
    tmp = mkroot("pdg-rtresolved.")
    pre(tmp)
    body, left = build(tmp, iblock)
    if left:
        bad("%s: install 段改写后仍有宿主绝对路径 %s —— 拒绝运行" % (name, left))
        return None, None
    script = "%s\nc_y(){ echo \"$*\"; }\nRESOLVED_DISABLED=0\n%s\n%s\n" % (iset.group(0), body, STEP8)
    r = run_sh(tmp, script, "fast", nounit)
    if r.returncode != 0:
        bad("%s: 装机那一段没跑通 rc=%d: %r" % (name, r.returncode, (r.stdout + r.stderr)[-300:]))
        return None, None
    return state(tmp, r), uninstall(tmp, name, "fast", nounit)


def pre_running(tmp):        # Ubuntu 默认: resolved 在跑, resolv.conf 指向它的 stub
    open(tmp + "/run/systemd/resolve/stub-resolv.conf", "w").write("nameserver 127.0.0.53\n")
    os.symlink(tmp + "/run/systemd/resolve/stub-resolv.conf", tmp + "/etc/resolv.conf")
    for f in ("running", "enabled", "global"):
        open(tmp + "/" + f, "w").close()


def pre_static(tmp):         # resolved 装着但停用(或机器上根本没有), resolv.conf 是静态文件
    open(tmp + "/etc/resolv.conf", "w").write("nameserver 9.9.9.9\n")


def pre_reinstall(tmp):      # 旧版本装过一次: 备份已在、resolved 已被它停掉、没有记录
    open(tmp + "/run/systemd/resolve/stub-resolv.conf", "w").write("nameserver 127.0.0.53\n")
    os.symlink(tmp + "/run/systemd/resolve/stub-resolv.conf", tmp + "/etc/resolv.conf.pdg-orig")
    open(tmp + "/etc/resolv.conf", "w").write("nameserver 127.0.0.1\nnameserver 1.1.1.1\n")


def check_back_on(name, st):
    """装机停过 resolved(或没有记录): 卸载后它启用、在跑, resolv.conf 指回它的 stub, 全局 DNS 不含 127.0.0.1。"""
    if st is None:
        return
    (ok if st["running"] and st["enabled"] else bad)("%s: resolved 启用并在跑" % name)
    want = st["tmp"] + "/run/systemd/resolve/stub-resolv.conf"
    (ok if st["link"] == want else bad)("%s: /etc/resolv.conf 指回 resolved 的 stub%s" % (
        name, "" if st["link"] == want else "(实际 链接 %r 内容 %r)" % (st["link"], st["content"])))
    g = st["global"] or []
    (ok if "127.0.0.1" not in g else bad)("%s: resolved 全局 DNS 不含 127.0.0.1(%s)" % (name, " ".join(g) or "空"))
    (ok if not st["bak_left"] else bad)("%s: 还原成功后备份已删" % name)
    (ok if "RESOLV_WARN=[]" in st["out"] else bad)("%s: 没有报还原失败" % name)


n = "往返/装机前 resolved 在跑"
inst, un = roundtrip(n, pre_running)
if inst:
    (ok if inst["marker"] == "disabled\n" else bad)("%s: 装机记下 disabled(实际 %r)" % (n, inst["marker"]))
    (ok if not inst["running"] and not inst["enabled"] else bad)("%s: 装机停用了 resolved" % n)
check_back_on(n, un)
check_marker_gone(n, un)

for n, nounit in (("往返/resolved 装着但停用", False), ("往返/机器上没有 resolved", True)):
    inst, un = roundtrip(n, pre_static, nounit)
    if inst:
        (ok if inst["marker"] == "untouched\n" else bad)("%s: 装机记下 untouched(实际 %r)" % (n, inst["marker"]))
        acts = resolved_actions(inst["calls"])
        (ok if not acts else bad)("%s: 装机没动 resolved%s" % (n, "" if not acts else "(实际 %r)" % acts))
    check_left_alone(n, un)
    check_marker_gone(n, un)

n = "往返/重装(备份已在, 旧版本装的)"
inst, un = roundtrip(n, pre_reinstall)
if inst:
    (ok if inst["marker"] is None else bad)("%s: 备份不是这次做的 → 不写记录(实际 %r)" % (n, inst["marker"]))
check_back_on(n, un)

finish()

#!/usr/bin/env python3
"""mosdns 的证据必须同时认**退出码、执行路径和二进制内容**, 三者缺一都是假绿。

实测: 下面这组输入会被当前判据判成 OK ——

    rc=1
    stdout="mosdns v5.3.4-0-gb732318"
    stderr="fatal: broken"

判据把 stdout 与 stderr 拼起来正则找版本号, 找到就算数, 退出码根本没看。一个起不来的
mosdns 只要还能打印自己的版本, doctor 就会说"✓ 钉死值"。

第二件: 判据调的是 PATH 里的 `mosdns`, 而 systemd 实际执行的是 /usr/local/bin/mosdns
(ExecStart 写死)。PATH 前面搁一个别的 mosdns, doctor 报的就不是网关在跑的那个。

第三件: 安装器的短路条件是"自报版本相同就跳过下载"。于是一个**内容不同、但自报 v5.3.4**
的二进制会让整段安装被跳过 —— 连带跳过 SHA256 供应链校验。项目钉的 PDG_SHA256[mosdns-*]
是下载**压缩包**的哈希, 一旦跳过下载, 它就再也没有机会被用上; 落盘的那个二进制本身,
项目从来没有钉过。

线上两台当前的二进制已经核实为官方原版, 这里修的是**证据闭包**, 不是事故现场。
"""
import hashlib
import os
import re
import stat
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy/bot"))
sys.path.insert(0, os.path.join(ROOT, "tests"))
import tmpguard                                              # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


import checks                                                # noqa: E402

CHK = open(os.path.join(ROOT, "deploy/bot/checks.py"), encoding="utf-8").read()
VERS = open(os.path.join(ROOT, "lib/versions.sh"), encoding="utf-8").read()
INST = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
W = tmpguard.mkdtemp(prefix="pdg-mosbin.")

PIN_VER = (re.search(r'^MOSDNS_VER="([^"]+)"', VERS, re.M) or [None, "v5.3.4"])[1]

print("══ 1. 判据固定在 systemd 真正执行的那个路径上 ══")
# ExecStart 写的是绝对路径; 判据必须问同一个文件, 否则报的是"某个 mosdns"而不是"这台跑的那个"
unit = re.search(r"ExecStart=(\S*/mosdns)\s", INST)
(ok if unit else bad)("install.sh 的 mosdns.service 里抽得到 ExecStart 路径")
UNIT_BIN = unit.group(1) if unit else "/usr/local/bin/mosdns"
(ok if UNIT_BIN in CHK else
 bad)("checks.py 里出现 systemd 执行的那个绝对路径 %s(实得: 未出现)" % UNIT_BIN)
body = re.search(r"def check_mosdns_version\(.*?\n(?=\ndef )", CHK, re.S)
(ok if body else bad)("抽得到 check_mosdns_version")
if body:
    b = body.group(0)
    (ok if not re.search(r'_run\(\[\s*"mosdns"', b) else
     bad)("判据不再用裸的 \"mosdns\"(那会跟着 PATH 走, 报的可能是另一个二进制)")

print()
print("══ 2. 退出码是证据的一部分 ══")
_run0 = checks._run


def stub(seq, path_filter=None):
    def f(cmd, *a, **k):
        if cmd and "mosdns" in str(cmd[0]):
            if path_filter is not None:
                path_filter.append(cmd[0])
            return seq
        return _run0(cmd, *a, **k)
    return f


if body:
    seen = []
    checks._run = stub((0, "mosdns %s-0-gb732318\n" % PIN_VER, ""), seen)
    r = checks.check_mosdns_version()
    (ok if r and r[0] == "ok" else bad)("rc=0 + 版本相符 → ok(实得 %r)" % (r,))
    (ok if seen and seen[0] == UNIT_BIN else
     bad)("判据调的是 %s(实得 %r)" % (UNIT_BIN, seen[0] if seen else None))

    # ★ 实测的假绿形态: 命令失败了, 但它在崩之前把版本号打出来了
    checks._run = stub((1, "mosdns %s-0-gb732318\n" % PIN_VER, "fatal: broken"))
    r = checks.check_mosdns_version()
    (ok if r and r[0] != "ok" else
     bad)("rc=1 但 stdout 里有正确版本 → **不许**判绿(实得 %r)" % (r,))
    (ok if r and ("rc" in r[2] or "退出" in r[2] or "非 0" in r[2]) else
     bad)("说清是命令失败而不是版本不符(实得 %r)" % (r[2] if r else None))

    # 版本号只出现在 stderr 里, 同样不算成功证据
    checks._run = stub((0, "", "mosdns %s-0-gb732318\n" % PIN_VER))
    r = checks.check_mosdns_version()
    (ok if r and r[0] != "ok" else
     bad)("版本只在 stderr 里 → 不算成功证据(实得 %r)" % (r,))

    # 解析不出版本 → warn + 无结论
    checks._run = stub((0, "hello world\n", ""))
    r = checks.check_mosdns_version()
    (ok if r and r[0] == "warn" else bad)("解析不出版本 → warn(实得 %r)" % (r,))

    # 版本不符 → warn, 两边都报
    checks._run = stub((0, "mosdns v9.9.9-0-gx\n", ""))
    r = checks.check_mosdns_version()
    (ok if r and r[0] == "warn" and "v9.9.9" in r[2] and PIN_VER in r[2] else
     bad)("版本不符 → warn 且两边的值都报出来(实得 %r)" % (r,))
    checks._run = _run0

print()
print("══ 3. lib/versions.sh 里钉了**解压后二进制**的哈希 ══")
HEX = r'"([0-9a-f]{64})"'
pins = dict(re.findall(r"\[mosdns-bin-(amd64|arm64)\]=" + HEX, VERS))
for arch in ("amd64", "arm64"):
    (ok if arch in pins else
     bad)("PDG_SHA256[mosdns-bin-%s] 已钉(压缩包哈希在跳过下载时根本用不上)" % arch)
zips = dict(re.findall(r"\[mosdns-(amd64|arm64)\]=" + HEX, VERS))
for arch in pins:
    (ok if pins[arch] != zips.get(arch) else
     bad)("%s 的二进制哈希与压缩包哈希不是同一个值(相同说明钉错了对象)" % arch)
# 取值过程必须写下来: 没有出处的哈希就是 TOFU, 换个人来无从复算
(ok if re.search(r"解压后|unzip", VERS) and "mosdns-bin-" in VERS else
 bad)("versions.sh 里写清了这两个值是怎么算出来的")

print()
print("══ 4. doctor 有一条二进制完整性判据 ══")
(ok if hasattr(checks, "check_mosdns_binary") else
 bad)("checks.py 里有 check_mosdns_binary")
(ok if "check_mosdns_binary" in CHK.split("ALL = [")[-1] else
 bad)("check_mosdns_binary 登记进了 ALL(不登记就永远不会跑)")

if hasattr(checks, "check_mosdns_binary"):
    real = os.path.join(W, "mosdns_real")
    open(real, "wb").write(b"official-bytes")
    os.chmod(real, 0o755)
    real_sha = hashlib.sha256(b"official-bytes").hexdigest()
    other = os.path.join(W, "mosdns_other")
    open(other, "wb").write(b"tampered-bytes")
    os.chmod(other, 0o755)
    gone = os.path.join(W, "mosdns_gone")

    def call(path, pin, arch="amd64"):
        return checks.check_mosdns_binary(_bin=path, _pin=pin, _arch=arch)

    r = call(real, real_sha)
    (ok if r and r[0] == "ok" else bad)("摘要相符 → ok(实得 %r)" % (r,))
    (ok if r and real_sha[:12] in r[2] else
     bad)("绿的时候给出短前缀, 便于人工核对(实得 %r)" % (r[2] if r else None))
    (ok if r and real_sha not in r[2] else
     bad)("只给短前缀, 不整串打出来(实得 %r)" % (r[2] if r else None))

    r = call(other, real_sha)
    (ok if r and r[0] == "fail" else
     bad)("同版本、内容不同 → fail(这正是跳过下载后无人再校验的那个形态)(实得 %r)" % (r,))
    (ok if r and ("内容" in r[2] or "不一致" in r[2]) else
     bad)("说清是「二进制内容与官方钉值不一致」(实得 %r)" % (r[2] if r else None))

    r = call(gone, real_sha)
    (ok if r and r[0] != "ok" else bad)("文件不存在 → 不许 ok(实得 %r)" % (r,))

    r = call(real, "")
    (ok if r and r[0] == "warn" else
     bad)("钉值读不到 → warn + 无结论(不是「没问题」)(实得 %r)" % (r,))

    r = call(real, real_sha, arch="riscv64")
    (ok if r and r[0] == "warn" else
     bad)("架构不在钉值表里 → warn + 无结论(实得 %r)" % (r,))

print()
print("══ 5. 安装器: 同版本但内容不同, 不许短路 ══")
# 短路条件必须是"语义版本相同 **且** 落盘二进制的 SHA256 等于该架构钉值"。
seg = re.search(r"if ! pdg_mosdns_is_version.*?\nfi\n", INST, re.S)
(ok if seg else bad)("抽得到 install.sh 的 mosdns 安装段")
if seg:
    s = seg.group(0)
    (ok if "mosdns-bin-" in s or "pdg_mosdns_binary_ok" in s else
     bad)("短路条件里带上了二进制摘要(否则跳过下载 = 跳过供应链校验)")
    (ok if "PDG_SHA256[mosdns-$MARCH]" in s else
     bad)("下载后的压缩包 ZIP 校验没有被削弱")
    (ok if "_stash_bin" in s else bad)("既有的回滚保护还在")

# 真跑一次判据函数(在沙箱里, 不碰 /usr/local/bin)
helper = re.search(r"\npdg_mosdns_binary_ok\(\)\{", VERS)
(ok if helper else
 bad)("lib/versions.sh 里有 pdg_mosdns_binary_ok(单一真源, install.sh 与测试共用)")
if helper:
    sb = os.path.join(W, "bin")
    os.makedirs(sb, exist_ok=True)
    fake = os.path.join(sb, "mosdns")
    open(fake, "w").write('#!/bin/sh\necho "mosdns %s-0-gb732318"\n' % PIN_VER)
    os.chmod(fake, 0o755)
    fake_sha = hashlib.sha256(open(fake, "rb").read()).hexdigest()

    def probe(pin_sha):
        script = (
            'source "%s/lib/versions.sh"\n'
            'PDG_SHA256[mosdns-amd64test]="%s"\n'
            'PATH="%s:$PATH"\n'
            'pdg_mosdns_binary_ok amd64test "%s" "%s"; echo "rc=$?"\n'
            % (ROOT, pin_sha, sb, PIN_VER, fake))
        return subprocess.run(["bash", "-c", script],
                              capture_output=True, text=True).stdout.strip()

    out = probe(fake_sha)
    (ok if out.endswith("rc=0") else
     bad)("版本对 + 摘要对 → 0(可以短路)(实得 %r)" % out)
    out = probe("0" * 64)
    (ok if out.endswith("rc=1") else
     bad)("版本对但摘要不对 → 非 0(必须重新下载并走 ZIP 校验)(实得 %r)" % out)
    out = probe("")
    (ok if out.endswith("rc=1") else
     bad)("钉值为空 → 非 0(存疑就装, 不能存疑就跳过)(实得 %r)" % out)

print("-" * 62)
print("test-mosdns-binary-evidence.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

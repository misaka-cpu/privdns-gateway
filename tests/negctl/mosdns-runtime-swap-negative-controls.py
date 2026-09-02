#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mosdns 运行时换版路径的负控: 逐条把生产代码改坏, 证明测试真的会红。

绿灯本身不是证据 —— 一支从不失败的测试和一支写对了的测试, 在通过时长得一模一样。
每一格都是: 精确改坏生产代码的一处 → 跑指定测试 → **要求它变红** → 还原。
外加一格正控(不改任何东西, 要求全绿), 用来证明红不是夹具自己坏了。

本脚本只在本地手工跑, 不进 CI: 它要反复改写工作区里的生产文件。
用法: python3 tests/negctl/mosdns-runtime-swap-negative-controls.py
"""
import io, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")

def run(test):
    cmd = ([sys.executable, os.path.join(ROOT, "tests", test)] if test.endswith(".py")
           else ["bash", os.path.join(ROOT, "tests", test)])
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout + r.stderr

CELLS = [
    # (名字, 文件, 原文, 改成, 该红的测试, 期望红在哪句里出现的关键字)
    ("换版根本不被调用", PDG,
     "  if ! _update_mosdns_binary; then", "  if false; then",
     "test-update-mosdns-binary.sh", "cmd_update"),

    ("「查不了」伪装成「通过」", PDG,
     "    mosdns) return 2 ;;", "    mosdns) return 0 ;;",
     "test-core-swap.sh", "离线校验"),

    ("换核后的监听对照被摘掉", PDG,
     '  if [[ "$cc" == 2 ]]; then\n    if [[ -z "$lis0" ]]; then',
     '  if false; then\n    if [[ -z "$lis0" ]]; then',
     "test-core-swap.sh", "J1"),

    ("解压产物不再核内容", PDG,
     '  pdg_verify_sha256 "$tmp/mosdns" "${PDG_SHA256[mosdns-bin-$march]:-}" "mosdns $ver 二进制 ($march)" \\\n    || { c_y "  二进制内容与钉值不符 → 拒绝换核(ZIP 已过, 说明问题出在解压这一段)"; rm -rf "$tmp"; return 1; }',
     '  true',
     "test-update-mosdns-binary.sh", "解压产物摘要不符"),

    ("压缩包不再核内容", PDG,
     '  pdg_verify_sha256 "$tmp/m.zip" "${PDG_SHA256[mosdns-$march]:-}" "mosdns $ver ($march)" \\\n    || { c_y "  压缩包 SHA 校验失败 → 判为更新失败(不降级成警告后继续)"; rm -rf "$tmp"; return 1; }',
     '  true',
     "test-update-mosdns-binary.sh", "压缩包摘要不符"),

    ("短路判据退回「只比版本」", PDG,
     '  pdg_mosdns_binary_ok "$march" "$ver" "$bindir/mosdns" && return 0   # 版本 + 内容都已是钉死版',
     '  pdg_mosdns_is_version "$ver" && return 0',
     "test-update-mosdns-binary.sh", "短路失效"),

    # ⚠️ 锚点必须落在 mosdns 独有的那行上。两个内核判据的**摘要段逐字相同**(先证内容后执行
    # 之后更是如此), 只取摘要段会命中 2 次、负控自己先红。mosdns 读版本用 `"$bin" version`,
    # mihomo 用 `"$bin" -v` —— 这是两者唯一逐字不同的地方。
    ("共用判据不再比对内容(只剩版本)", os.path.join(ROOT, "lib/versions.sh"),
     '  got="$(sha256sum "$bin" 2>/dev/null | awk \'{print $1}\')"\n'
     '  [[ -n "$got" && "$got" == "$exp" ]] || return 1\n'
     '  # 顺带补上一处一直没跟上的不对称: 原来这里是 `$("$bin" version | head -1)`, 退出码取的是\n'
     '  # head 的、永远为 0 —— 与 mihomo 那边 v1.11.7 已经修掉的形态一样。改成不经管道取首行。\n'
     '  got="$("$bin" version 2>/dev/null)" || return 1   # 退出码必须是 0',
     '  got="$("$bin" version 2>/dev/null)" || return 1',
     "test-update-mosdns-binary.sh", "短路跳过"),

    ("快照不再收 mosdns 二进制", PDG,
     "              usr/local/bin/mosdns usr/local/bin/mihomo",
     "              usr/local/bin/mihomo",
     "test-update-mosdns-binary.sh", "快照"),

    ("版本漂移又变回「拒绝更新」", PDG,
     '  if [[ "$rc" == 5 ]]; then', '  if false; then',
     "test-update-mosdns-preflight.sh", "自报版本不符"),

    ("篡改形态被顺手放行", PDG,
     '  if [[ "$rc" == 5 ]]; then', '  if [[ "$rc" == 5 || "$rc" == 6 ]]; then',
     "test-update-mosdns-preflight.sh", "摘要不符"),

    ("换版排到了 doctor 自检门之后", PDG,
     "  if ! _update_mosdns_binary; then\n    c_y \"mosdns 二进制更新失败, 回滚到更新前快照…\"; cmd_rollback --dir \"$snap_dir\" --git \"$pre_sha\"; return 1\n  fi\n",
     "",
     "test-update-mosdns-binary.sh", "cmd_update"),
]

def main():
    npass = nfail = 0
    print("══ 正控: 不改任何东西, 全部必须绿 ══")
    for t in ("test-update-mosdns-binary.sh", "test-core-swap.sh",
              "test-update-mosdns-preflight.sh", "test-release-faults.py"):
        rc, out = run(t)
        if rc == 0:
            print("[OK]   正控 %s 绿" % t); npass += 1
        else:
            print("[FAIL] 正控 %s 就是红的 —— 后面的负控都不算数\n%s" % (t, out[-1500:])); nfail += 1
    if nfail:
        print("正控没过, 停。"); return 1

    print("\n══ 负控: 每格改坏一处, 必须变红 ══")
    for name, path, old, new, test, kw in CELLS:
        src = io.open(path, encoding="utf-8").read()
        if src.count(old) != 1:
            print("[FAIL] [%s] 锚点命中 %d 次(期望 1) —— 生产代码换写法了, 负控要跟着改"
                  % (name, src.count(old))); nfail += 1; continue
        io.open(path, "w", encoding="utf-8").write(src.replace(old, new))
        try:
            rc, out = run(test)
        finally:
            io.open(path, "w", encoding="utf-8").write(src)   # 无论如何都还原
        if rc == 0:
            print("[FAIL] [%s] 改坏了 %s 却仍然绿 —— 那条断言没有牙齿" % (name, test)); nfail += 1
        else:
            fails = [l for l in out.splitlines() if l.startswith("[FAIL]") or " ✗ " in l]
            hit = any(kw in l for l in fails)
            print("[OK]   [%s] → %s 变红(%d 条), %s"
                  % (name, test, len(fails),
                     ("且点到「%s」" % kw) if hit else ("但没点到「%s」: %s" % (kw, fails[:1]))))
            npass += 1
            if not hit:
                print("       ⚠️ 红在别处, 说明这一格测到的不是它该测的那条")
    # 还原之后必须回到全绿, 否则说明某一格没还原干净
    print("\n══ 收尾: 还原后必须回到全绿 ══")
    for t in ("test-update-mosdns-binary.sh", "test-core-swap.sh", "test-update-mosdns-preflight.sh"):
        rc, _ = run(t)
        print("%s %s 还原后 %s" % ("[OK]  " if rc == 0 else "[FAIL]", t, "绿" if rc == 0 else "红"))
        npass += 1 if rc == 0 else 0; nfail += 0 if rc == 0 else 1
    print("────────────────────────────────────────")
    print("通过 %d, 失败 %d" % (npass, nfail))
    return 1 if nfail else 0

sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E2E 夹具闭包(e2e_git 收口 + mihomo 取件钉值闭包)的负控。

由来: exact-head CI 33348976467 的六支红灯。夹具替被测代码说谎时, 上游测试是绿的 ——
所以这里逐格改坏夹具, 要求对应的守卫/闭包测试**变红且红在该红的那条上**。

本脚本会反复改写工作区里的测试文件, 只在本地手工跑, 不进 CI。
"""
import hashlib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIB = os.path.join(ROOT, "tests/e2e-lib.sh")
INTEG = os.path.join(ROOT, "tests/test-mihomo-integrity.sh")
INST = os.path.join(ROOT, "tests/e2e-install.sh")

TESTS = {
    "guard":   (sys.executable, "tests/test-e2e-repo-guard.py"),
    "fixture": (sys.executable, "tests/test-e2e-mihomo-fixture.py"),
}


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def run(key):
    cmd = list(TESTS[key]); cmd[1] = os.path.join(ROOT, cmd[1])
    env = dict(os.environ)
    env.setdefault("PDG_TEST_MIHOMO", os.path.join(ROOT, "tests/.bin/mihomo"))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, errors="replace", env=env)
    fails = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("[FAIL]")]
    return r.returncode, fails


CELLS = [
    ("① e2e_git 改回裸 git", INTEG,
     'e2e_git "$REPO" config user.email t@t        >/dev/null 2>&1',
     'git -C "$REPO" config user.email t@t         >/dev/null 2>&1',
     "guard", "没走 e2e_git"),

    ("② 复用门摘掉内容摘要判据", LIB,
     '  if pdg_mihomo_binary_ok "$march" "$MIHOMO_VER" "$bin" && e2e_mihomo_is_real "$bin"; then',
     '  if e2e_mihomo_is_real "$bin"; then',
     "fixture", "不短路"),

    ("③ 摘掉归档 SHA 校验", LIB,
     '  if ! pdg_verify_sha256 "$tmp/m.gz" "${PDG_SHA256[mihomo-$march]:-}" "mihomo $MIHOMO_VER 归档 ($march)" >/dev/null 2>&1; then',
     '  if false; then',
     "fixture", "归档"),

    ("④ 摘掉解压产物的生产判据", LIB,
     '  if ! pdg_mihomo_binary_ok "$march" "$MIHOMO_VER" "$cand"; then',
     '  if false; then',
     "fixture", "坏件绝不落盘"),

    ("⑤ 复用门改回 PATH 查找", LIB,
     '  if pdg_mihomo_binary_ok "$march" "$MIHOMO_VER" "$bin" && e2e_mihomo_is_real "$bin"; then',
     '  if e2e_mihomo_is_real; then',
     "fixture", "PATH"),

    ("⑥ 下载失败后仍继续", LIB,
     '''       -o "$tmp/m.gz" 2>/dev/null; then
    echo "[FAIL] 夹具下载 mihomo $MIHOMO_VER ($march) 失败(网络不通? 版本不存在?)" >&2
    rm -rf "$tmp"; return 1
  fi''',
     '''       -o "$tmp/m.gz" 2>/dev/null; then
    :
  fi''',
     "fixture", "点到**下载**这一层"),
    ('⑦ E2E 里重新长出 shell 桩 mihomo', INST,
     'e2e_seed_mihomo_bin || { echo "[FAIL] 播种钉定 mihomo 失败"; exit 1; }',
     'cat > /usr/local/bin/mihomo <<EOSTUB\n#!/bin/sh\necho stub\nEOSTUB',
     'fixture', '内联 shell 桩'),

    ('⑧ 播种跳过源文件校验', LIB,
     '    _e2e_mihomo_ok "$src" || continue\n    install -m755 "$src" "$bin" 2>/dev/null || continue',
     '    install -m755 "$src" "$bin" 2>/dev/null || continue',
     'fixture', 'install **之前**'),

    ('⑨ 播种改成自己 curl(绕开 artifact)', LIB,
     '  bash "$E2E_ROOT/tests/prepare-mihomo.sh" >/dev/null 2>&1 || true',
     '  curl -fsSL http://example.invalid/mihomo -o "$bin" 2>/dev/null || true',
     'fixture', '不联网'),

    ('⑩ e2e-install 把播种挪到假 curl 之后', INST,
     'e2e_seed_mihomo_bin || { echo "[FAIL] 播种钉定 mihomo 失败"; exit 1; }\n\ncat > /usr/local/bin/curl <<S',
     'cat > /usr/local/bin/curl <<S',
     'fixture', '假 curl'),

]


def main():
    npass = nfail = 0
    print("══ 正控: 不改任何东西, 两支必须全绿 ══")
    for k in TESTS:
        rc, f = run(k)
        if rc == 0:
            print("[OK]   正控 %-8s 绿" % k); npass += 1
        else:
            print("[FAIL] 正控 %s 本来就红(%d 条)" % (k, len(f)))
            for l in f[:4]:
                print("       " + l)
            nfail += 1
    if nfail:
        print("正控没过, 停。"); return 1

    print("\n══ 负控: %d 格 ══" % len(CELLS))
    for name, path, old, new, test, kw in CELLS:
        src = io.open(path, encoding="utf-8").read()
        hits = src.count(old)
        if hits != 1:
            print("[FAIL] [%s] 锚点命中 %d 次(期望 1)" % (name, hits)); nfail += 1; continue
        before = sha(path)
        io.open(path, "w", encoding="utf-8").write(src.replace(old, new))
        try:
            rc, fails = run(test)
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
        if sha(path) != before:
            print("[FAIL] [%s] 还原后摘要对不上" % name); nfail += 1; continue
        if rc == 0:
            print("[FAIL] [%s] 改坏了 %s 却仍全绿 —— 那条断言没有牙齿" % (name, test)); nfail += 1; continue
        hit = any(kw in l for l in fails)
        print("[OK]   [%s] 锚点 1 命中 → %s 变红 %d 条%s"
              % (name, test, len(fails), (", 且点到「%s」" % kw) if hit else (", 但没点到「%s」" % kw)))
        npass += 1
        if not hit:
            print("       ⚠️ 新增具名失败前 3 条: %s" % fails[:3])

    print("\n══ ⑦ 反向对照: 只加无关注释, 新增失败必须为 0 ══")
    for path in (LIB, INTEG):
        src = io.open(path, encoding="utf-8").read(); before = sha(path)
        io.open(path, "a", encoding="utf-8").write(
            "\n# 无关注释: git config git commit pdg_mihomo_binary_ok PDG_SHA256[mihomo- gunzip\n")
        try:
            rg, fg = run("guard"); rf, ff = run("fixture")
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
        okr = sha(path) == before
        if rg == 0 and rf == 0 and okr:
            print("[OK]   [%s] 纯注释后仍全绿, 新增失败 0, 还原摘要一致" % os.path.basename(path))
            npass += 1
        else:
            print("[FAIL] [%s] guard新增%d 条 fixture新增%d 条, 还原=%s"
                  % (os.path.basename(path), len(fg), len(ff), okr)); nfail += 1

    print("\n══ 收尾: 正式树摘要 ══")
    for p in (LIB, INTEG, os.path.join(ROOT, "tests/test-bump-kernel-tool.sh")):
        print("  %-28s %s…" % (os.path.basename(p), sha(p)[:16]))
    rc, _ = run("guard"); print("  还原后 guard: %s" % ("绿" if rc == 0 else "红"))
    npass += 1 if rc == 0 else 0
    nfail += 0 if rc == 0 else 1
    print("─" * 44)
    print("通过 %d, 失败 %d" % (npass, nfail))
    return 1 if nfail else 0


sys.exit(main())

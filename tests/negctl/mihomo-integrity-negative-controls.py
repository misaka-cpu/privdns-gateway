#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mihomo 完整性闭包 / doctor 四态 / 换核 / bump 工具 的负控。

绿灯不是证据: 一支从不失败的测试和一支写对了的测试, 通过时长得一模一样。
每格 = 精确改坏生产代码一处 → 跑指定测试 → **要求它变红且红在该红的那条上** → 还原。
另有正控(不改任何东西全绿)与反向对照(只加注释不得凭空造出失败)。

本脚本反复改写工作区里的生产文件, 只在本地手工跑, **不进 CI**。
"""
import hashlib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")
VER = os.path.join(ROOT, "lib/versions.sh")
CHK = os.path.join(ROOT, "deploy/bot/checks.py")
INST = os.path.join(ROOT, "install.sh")
TOOL = os.path.join(ROOT, "tools/bump-kernel.sh")

TESTS = {
    "integrity": ("bash", "tests/test-mihomo-integrity.sh"),
    "doctor":    (sys.executable, "tests/test-mihomo-binary-evidence.py"),
    "swap":      ("bash", "tests/test-mihomo-real-swap.sh"),
    "bump":      ("bash", "tests/test-bump-kernel-tool.sh"),
}


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def run(key):
    cmd = list(TESTS[key])
    cmd[1] = os.path.join(ROOT, cmd[1])
    env = dict(os.environ)
    env.setdefault("PDG_TEST_MIHOMO", os.path.join(ROOT, "tests/.bin/mihomo"))
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                       errors="replace", env=env)
    fails = [l for l in (r.stdout + r.stderr).splitlines() if l.startswith("[FAIL]")]
    return r.returncode, fails


# (名字, 文件, 原文, 改成, 测试, 期望红里出现的关键词)
CELLS = [
    ("判据退回只比自报版本", VER,
     '  out="$("$bin" -v 2>/dev/null)" || return 1        # 退出码必须是 0',
     '  out="$("$bin" -v 2>/dev/null || true)"',
     "integrity", "命令非零"),

    ("判据不再比对内容摘要", VER,
     '  exp="${PDG_SHA256[mihomo-bin-$arch]:-}"',
     '  exp=""; return 0 # ',
     "integrity", "同版本错误摘要"),

    ("install.sh 退回 PATH 判据", INST,
     'if ! pdg_mihomo_binary_ok "$MARCH" "$MIHOMO_VER" /usr/local/bin/mihomo; then',
     'if ! pdg_mihomo_is_version "$MIHOMO_VER"; then',
     "integrity", "install.sh"),

    ("install.sh 落盘后不再核内容", INST,
     '  pdg_verify_sha256 /usr/local/bin/mihomo "${PDG_SHA256[mihomo-bin-$MARCH]:-}" \\\n    "mihomo $MIHOMO_VER 二进制 ($MARCH)" \\\n    || { rm -rf "$t"; die "mihomo 二进制内容与钉值不符 → 拒绝继续(归档校验已过, 问题出在解压/落盘这一段)"; }',
     '  true',
     "integrity", "二次核验"),

    ("换核短路退回只比版本", PDG,
     '  pdg_mihomo_binary_ok "$march" "$ver" "$bindir/mihomo" && { rm -rf "$tmp"; return 0; }',
     '  pdg_mihomo_is_version "$ver" && { rm -rf "$tmp"; return 0; }',
     "swap", "内容漂移"),

    ("换核不再核解压产物", PDG,
     '  pdg_verify_sha256 "$tmp/mihomo" "${PDG_SHA256[mihomo-bin-$march]:-}" "mihomo $ver 二进制 ($march)" \\\n    || { c_y "  二进制内容与钉值不符 → 拒绝换核(归档校验已过, 问题出在解压这一段)"; rm -rf "$tmp"; return 1; }',
     '  true',
     "swap", "二进制"),

    ("顶层短路不再看内核二进制", PDG,
     '    pdg_mihomo_binary_ok "$march" "${MIHOMO_VER:-}" "$bindir/mihomo" || exit 1',
     '    true',
     "integrity", "没走到换核这一步"),

    ("doctor 版本判据退回「能解析就绿」", CHK,
     '    if got != (want if want.startswith("v") else "v" + want):',
     '    if False:',
     "doctor", "自报旧版"),

    ("doctor 不再看绝对路径", CHK,
     '    b = _bin or MIHOMO_BIN\n    want = _pin if _pin is not None else _pinned_mihomo_ver()',
     '    b = "mihomo"\n    want = _pin if _pin is not None else _pinned_mihomo_ver()',
     "doctor", ""),

    ("doctor 内容判据永远 ok", CHK,
     '    shas = _pinned_mihomo_bin_shas()',
     '    shas = _pinned_mihomo_bin_shas(); pin = _pin or "x"; _arch = _arch or "amd64"\n    return ("ok", name, "内容与官方钉值一致 ✓")  #',
     "doctor", "内容不符"),

    ("bump 工具退回逐次直写正式文件", TOOL,
     'mv -f "$STAGE" "$VERSIONS" || die "原子替换失败 —— 正式文件未动"',
     'cat "$STAGE" > "$VERSIONS" || die "替换失败"',
     "bump", "原子替换"),

    ("bump 工具的 SKIP_VERIFY 后门放开", TOOL,
     'if [[ -n "${PDG_BUMP_SKIP_VERIFY:-}" && -z "$FETCH" ]]; then\n  die "PDG_BUMP_SKIP_VERIFY 只能与 PDG_BUMP_FETCHER(测试取件器)同时使用; 官方下载路径不接受跳过校验"\nfi',
     'true',
     "bump", "后门"),

    ("bump 工具只读 e_machine", TOOL,
     '  [[ "$magic"  == "7f454c46" ]] || { say "  不是 ELF(magic=$magic)"; return 1; }',
     '  true',
     "bump", "ELF 判据没覆盖"),

    ("bump 工具资产名改成模糊匹配", TOOL,
     'select(.name==\\"$name\\")',
     'select(.name|contains(\\"linux\\"))',
     "bump", "资产名不是精确匹配"),
]


def main():
    npass = nfail = 0
    print("══ 正控: 不改任何东西, 四支必须全绿 ══")
    for k in TESTS:
        rc, fails = run(k)
        if rc == 0:
            print("[OK]   正控 %-10s 绿" % k); npass += 1
        else:
            print("[FAIL] 正控 %s 本来就是红的(%d 条) —— 后面负控都不算数" % (k, len(fails)))
            for l in fails[:5]:
                print("       " + l)
            nfail += 1
    if nfail:
        print("正控没过, 停。")
        return 1

    print("\n══ 负控: %d 格 ══" % len(CELLS))
    for name, path, old, new, test, kw in CELLS:
        src = io.open(path, encoding="utf-8").read()
        hits = src.count(old)
        if hits != 1:
            print("[FAIL] [%s] 锚点命中 %d 次(期望 1) —— 生产代码换写法了, 负控要跟着改"
                  % (name, hits))
            nfail += 1
            continue
        before = sha(path)
        io.open(path, "w", encoding="utf-8").write(src.replace(old, new))
        try:
            rc, fails = run(test)
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
        after = sha(path)
        if after != before:
            print("[FAIL] [%s] 还原后文件摘要对不上 —— 负控自己弄脏了正式树" % name)
            nfail += 1
            continue
        if rc == 0:
            print("[FAIL] [%s] 改坏了 %s 却仍然全绿 —— 那条断言没有牙齿" % (name, test))
            nfail += 1
            continue
        hit = (not kw) or any(kw in l for l in fails)
        print("[OK]   [%s] 锚点 1 命中 → %s 变红 %d 条%s"
              % (name, test, len(fails),
                 ("" if not kw else (", 且点到「%s」" % kw if hit else ", 但没点到「%s」" % kw))))
        npass += 1
        if kw and not hit:
            print("       ⚠️ 红在别处; 新增具名失败集合前 3 条: %s" % fails[:3])

    print("\n══ 反向对照: 只加注释不得凭空造出失败 ══")
    for path in (PDG, VER, TOOL):
        src = io.open(path, encoding="utf-8").read()
        before = sha(path)
        io.open(path, "a", encoding="utf-8").write(
            "\n# 无关注释: pdg_mihomo_is_version mihomo -v sha256sum select(.name== 工作树\n")
        try:
            rc_i, f_i = run("integrity")
            rc_b, f_b = run("bump")
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
        ok_restore = sha(path) == before
        if rc_i == 0 and rc_b == 0 and ok_restore:
            print("[OK]   [%s] 追加纯注释后仍全绿, 新增失败 0, 还原后摘要一致"
                  % os.path.basename(path))
            npass += 1
        else:
            print("[FAIL] [%s] 纯注释造出了失败(integrity=%d 条, bump=%d 条)或未还原(%s)"
                  % (os.path.basename(path), len(f_i), len(f_b), ok_restore))
            nfail += 1

    print("\n══ 收尾: 正式树摘要 ══")
    for p in (PDG, VER, CHK, INST, TOOL):
        print("  %-22s sha256 %s…" % (os.path.basename(p), sha(p)[:16]))
    rc, _ = run("integrity")
    print("  还原后 integrity: %s" % ("绿" if rc == 0 else "红"))
    npass += 1 if rc == 0 else 0
    nfail += 0 if rc == 0 else 1

    print("─" * 44)
    print("通过 %d, 失败 %d" % (npass, nfail))
    return 1 if nfail else 0


sys.exit(main())

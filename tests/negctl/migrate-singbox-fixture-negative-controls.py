#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test-migrate-drop-singbox.sh 的夹具闭包 + 迁移前 P0 门 的负控。

起因(v1.11.9): v1.11.7 把 _activate_mihomo_core 的跳过判据换成 pdg_mihomo_binary_ok 之后,
这支测试的 shell 桩不再满足判据 —— 它从此**每跑一次真去 GitHub 下 8 次 mihomo**, 却仍然
18/0。它没有报错, 只是从"确定性测试"退化成"网络运气的函数", 直到 main 上撞了一次
connection reset 才红。同一支里还藏着第二处: _pdg_nft_foreign_input_chains 与
_nft_apply_main 既没抽也没打桩, 返回 127 被下游判据当普通返回值吞掉。

所以这里验的不是业务, 是**前提**: 播种、闭包、P0 门三样, 任一样被改坏, 那支测试必须变红,
而且要红在该红的那一条上。

本脚本反复改写工作区里的文件, 只在本地手工跑, **不进 CI**。
"""
import hashlib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")
TST = os.path.join(ROOT, "tests/test-migrate-drop-singbox.sh")
GUARD = os.path.join(ROOT, "tests/test-fixture-network-guard.py")


def sha(p):
    h = hashlib.sha256()
    with io.open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def run(script=TST):
    """跑目标测试, 回 (rc, [FAIL 行])。PATH 上挂 curl 探针: 夹具真联网了这里也能看见。"""
    env = dict(os.environ)
    env.setdefault("PDG_TEST_MIHOMO", os.path.join(ROOT, "tests/.bin/mihomo"))
    cmd = [sys.executable, script] if script.endswith(".py") else ["bash", script]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                       errors="replace", env=env, timeout=900)
    out = r.stdout + r.stderr
    fails = [l for l in out.splitlines() if l.startswith("[FAIL]")]
    return r.returncode, fails


# (名字, 文件, 原文, 改成, 期望红里出现的关键词)
CELLS = [
    # ── 夹具前提 ──────────────────────────────────────────────────────────
    # 完整还原历史缺陷形态: 播种整段拿掉(装 + 装后再验), 沙箱根里就没有 mihomo 这个文件,
    # pdg_mihomo_binary_ok 恒假 → 生产代码真去取件 → 禁令桩记账 → 末尾那条断言点名。
    ("沙箱不再播种钉死版 mihomo(历史缺陷形态)", TST,
     '  install -m755 "$MIHOMO_SRC" "$SB/usr/local/bin/mihomo" \\\n'
     '    || { echo "[FAIL] 播种 mihomo 到沙箱失败"; exit 1; }\n'
     '  _mihomo_ok "$SB/usr/local/bin/mihomo" \\\n'
     '    || { echo "[FAIL] 播种后的 mihomo 过不了生产判据 pdg_mihomo_binary_ok"; exit 1; }',
     '  :',
     "夹具联网了"),

    ("播种的是个自报版本对、内容不对的桩", TST,
     '  install -m755 "$MIHOMO_SRC" "$SB/usr/local/bin/mihomo" \\\n'
     '    || { echo "[FAIL] 播种 mihomo 到沙箱失败"; exit 1; }',
     '  printf \'#!/bin/sh\\necho "Mihomo Meta $MIHOMO_VER"\\n\' > "$SB/usr/local/bin/mihomo"\n'
     '  chmod 755 "$SB/usr/local/bin/mihomo"',
     "生产判据"),

    ("P0 判据函数的桩被拿掉", TST,
     '_pdg_nft_foreign_input_chains(){\n'
     '  case "${FOREIGN_RC:-1}" in\n'
     '    0) echo "table inet myfw (chain input, hook input priority filter 0)"; return 0;;\n'
     '    2) echo "找不到 nftscan.py(判据脚本缺失), 无法确认防火墙链冲突"; return 2;;\n'
     '    *) return 1;;\n'
     '  esac\n'
     '}',
     ':',
     "闭包漏桩"),

    ("回滚用的 _nft_apply_main 桩被拿掉", TST,
     '_nft_apply_main(){ echo applied >> "$SB/nft-applied"; return "${NFT_APPLY_RC:-0}"; }',
     ':',
     "闭包漏桩"),

    ("P0 桩恒报「现场干净」(门被架空)", TST,
     '    0) echo "table inet myfw (chain input, hook input priority filter 0)"; return 0;;\n'
     '    2) echo "找不到 nftscan.py(判据脚本缺失), 无法确认防火墙链冲突"; return 2;;',
     '',
     "2b"),

    # ── 生产侧: 这两格证明新增用例咬的是真代码, 不是自己的桩 ────────────────
    ("生产侧: 发现外来 input 链却不再中止", PDG,
     '  if [[ "$_frc" == 0 ]]; then\n'
     '    c_y "检测到自定义 input base chain, 无法保证与 PDG 默认拒绝策略(policy drop)兼容 → 中止迁移。"',
     '  if false; then\n'
     '    c_y "检测到自定义 input base chain, 无法保证与 PDG 默认拒绝策略(policy drop)兼容 → 中止迁移。"',
     "2b"),

    ("生产侧: 「判不了」被当成「干净」", PDG,
     '  if [[ "$_frc" == 2 ]]; then',
     '  if false; then',
     "2c"),

    ("生产侧: nft 回滚只拷文件不再应用", PDG,
     'cp /etc/nftables.conf.scbak /etc/nftables.conf; _nft_apply_main; }',
     'cp /etc/nftables.conf.scbak /etc/nftables.conf; }',
     "4c"),
]

# 静态守卫自己的负控: 把 curl 禁令桩拿掉, 守卫必须点名这支
GUARD_CELL = ("守卫: 抽了含 curl 的生产函数却没有禁令桩", TST,
              'curl(){ echo "curl $*" >> "$NETLOG"; echo "curl: 夹具禁止联网" >&2; return 7; }',
              ':',
              "test-migrate-drop-singbox.sh")


def cell(name, path, old, new, kw, script=TST):
    src = io.open(path, encoding="utf-8").read()
    hits = src.count(old)
    if hits != 1:
        return False, "[FAIL] [%s] 锚点命中 %d 次(期望 1) —— 被测文件换写法了, 负控要跟着改" % (name, hits)
    before = sha(path)
    io.open(path, "w", encoding="utf-8").write(src.replace(old, new))
    try:
        rc, fails = run(script)
    finally:
        io.open(path, "w", encoding="utf-8").write(src)
    if sha(path) != before:
        return False, "[FAIL] [%s] 还原后摘要对不上 —— 负控自己弄脏了工作树" % name
    if rc == 0:
        return False, "[FAIL] [%s] 改坏了却仍然全绿 —— 那条断言没有牙齿" % name
    hit = (not kw) or any(kw in l for l in fails)
    tail = "" if not kw else (", 且点到「%s」" % kw if hit else ", 但**没**点到「%s」" % kw)
    line = "[%s]   [%s] 变红 %d 条%s" % ("OK" if hit else "FAIL", name, len(fails), tail)
    if not hit:
        line += "\n       红在别处, 前 3 条: %s" % fails[:3]
    return hit, line


def main():
    npass = nfail = 0
    print("══ 正控: 不改任何东西, 必须全绿且零联网 ══")
    rc, fails = run()
    if rc == 0:
        print("[OK]   正控绿"); npass += 1
    else:
        print("[FAIL] 正控本来就是红的(%d 条) —— 后面负控都不算数" % len(fails))
        for l in fails[:5]:
            print("       " + l)
        return 1
    if os.path.exists(GUARD):
        rc, fails = run(GUARD)
        if rc == 0:
            print("[OK]   正控: 静态守卫绿"); npass += 1
        else:
            print("[FAIL] 静态守卫本来就是红的: %s" % fails[:3]); nfail += 1

    print("\n══ 负控: %d 格 ══" % (len(CELLS) + (1 if os.path.exists(GUARD) else 0)))
    for c in CELLS:
        ok, line = cell(*c)
        print(line)
        npass += 1 if ok else 0
        nfail += 0 if ok else 1
    if os.path.exists(GUARD):
        n, p, o, w, k = GUARD_CELL
        ok, line = cell(n, p, o, w, k, script=GUARD)
        print(line)
        npass += 1 if ok else 0
        nfail += 0 if ok else 1

    print("\n══ 反向对照: 只加注释不得凭空造出失败 ══")
    for path in (PDG, TST):
        src = io.open(path, encoding="utf-8").read()
        before = sha(path)
        io.open(path, "a", encoding="utf-8").write(
            "\n# 无关注释: _pdg_nft_foreign_input_chains curl MIHOMO_SRC _nft_apply_main\n")
        try:
            rc, f = run()
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
        if rc == 0 and sha(path) == before:
            print("[OK]   [%s] 追加纯注释后仍全绿, 还原后摘要一致" % os.path.basename(path))
            npass += 1
        else:
            print("[FAIL] [%s] 纯注释造出了失败(%d 条)或未还原" % (os.path.basename(path), len(f)))
            nfail += 1

    print("\n══ 收尾 ══")
    for p in (PDG, TST):
        print("  %-34s sha256 %s…" % (os.path.basename(p), sha(p)[:16]))
    rc, _ = run()
    print("  还原后目标测试: %s" % ("绿" if rc == 0 else "红"))
    npass += 1 if rc == 0 else 0
    nfail += 0 if rc == 0 else 1

    print("\n" + "─" * 40)
    print("通过 %d, 失败 %d" % (npass, nfail))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())

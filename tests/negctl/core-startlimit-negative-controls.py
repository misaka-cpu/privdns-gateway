#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""换核恢复闭包(start-limit + 真实跨版本)的负控。

绿灯不是证据: 一支从不失败的测试和一支写对了的测试, 通过时长得一模一样。
每格 = 精确改坏一处 → 跑指定测试 → **要求它变红且红在该红的那条上** → 还原。

⚠️ 这支要 root 与真 systemd(被测的两支 E2E 会写 unit、起服务、读 journal), 跑一轮十几分钟。
只在本地手工跑, **不进 CI**。
"""
import hashlib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")
PINS = os.path.join(ROOT, "tests/legacy-pins.sh")
CI = os.path.join(ROOT, ".github/workflows/ci.yml")

LEGACY = os.environ.get("PDG_TEST_MOSDNS_LEGACY", os.path.join(ROOT, "tests/.bin/mosdns-legacy"))
NEWBIN = os.environ.get("PDG_TEST_MOSDNS", "/usr/local/bin/mosdns")
VENV_PY = os.environ.get("PDG_VENV_PY", sys.executable)

TESTS = {
    "slimit": ["sudo", "-E", "env", "PDG_TEST_STRICT=1",
               "PDG_TEST_MOSDNS_LEGACY=" + LEGACY,
               "bash", os.path.join(ROOT, "tests/e2e-core-startlimit-recovery.sh")],
    "xver":   ["sudo", "-E", "env", "PDG_TEST_STRICT=1",
               "PDG_TEST_MOSDNS=" + NEWBIN, "PDG_TEST_MOSDNS_LEGACY=" + LEGACY,
               "bash", os.path.join(ROOT, "tests/e2e-mosdns-crossver-swap.sh")],
    "topo":   [VENV_PY, os.path.join(ROOT, "tests/test-ci-mosdns-topology.py")],
}


def sha(p):
    h = hashlib.sha256()
    with io.open(p, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def run(key):
    r = subprocess.run(TESTS[key], cwd=ROOT, capture_output=True, text=True,
                       errors="replace", timeout=1800)
    out = r.stdout + r.stderr
    fails = [l for l in out.splitlines() if l.startswith("[FAIL]") or l.lstrip().startswith("✗")]
    return r.returncode, fails


# (名字, 文件, 原文, 改成, 目标测试, 期望红里出现的关键词)
CELLS = [
    ("① 新核 restart 前不清限速", PDG,
     '  if ! _core_restart_clean "$svc"; then\n    c_y "  新版内核重启失败, 已还原旧版内核"',
     '  if ! systemctl restart "$svc"; then\n    c_y "  新版内核重启失败, 已还原旧版内核"',
     "slimit", "_core_swap_verify"),

    # 靶子必须是 6d: 第 3 格里新核那次 restart 会先清掉计数, 恢复侧的 reset-failed 被上游
    # 遮住 —— 拿第 3 格当靶子的话, 这一格改坏了也全绿(第一版就是这么写的, 负控自己抓出来的)。
    ("② 旧核 restart 前不清限速", PDG,
     '  if ! _core_restart_clean "$svc"; then\n    c_y "  旧内核已还原到盘上, 但服务没有恢复',
     '  if ! systemctl restart "$svc"; then\n    c_y "  旧内核已还原到盘上, 但服务没有恢复',
     "xver", "6d"),

    ("③ reset-failed 挪到 restart 之后", PDG,
     '  rfout="$(systemctl reset-failed "$svc" 2>&1)"; rfrc=$?\n  if ! systemctl restart "$svc" 2>/dev/null; then',
     '  if ! systemctl restart "$svc" 2>/dev/null; then\n    rfout="$(systemctl reset-failed "$svc" 2>&1)"; rfrc=$?',
     "slimit", "reset-failed 不在 restart 之前"),

    ("④ reset-failed 失败就当成功返回", PDG,
     '  rfout="$(systemctl reset-failed "$svc" 2>&1)"; rfrc=$?',
     '  rfout="$(systemctl reset-failed "$svc" 2>&1)"; rfrc=$?\n  [[ "$rfrc" == 0 ]] || return 0',
     "xver", "6b"),

    ("⑤ 恢复了旧二进制但不重启", PDG,
     '  if ! _core_restart_clean "$svc"; then\n    c_y "  旧内核已还原到盘上, 但服务没有恢复',
     '  if false; then\n    c_y "  旧内核已还原到盘上, 但服务没有恢复',
     "xver", "旧核没恢复"),

    ("⑥ 装完新核就把 .prev 删掉", PDG,
     '  _core_config_check "$svc" "$bindir"; cc=$?',
     '  rm -f "$bak"; _core_config_check "$svc" "$bindir"; cc=$?',
     "xver", "没恢复旧版"),

    ("⑦ 摘掉监听集合对账", PDG,
     '      if [[ "$lis1" != "$lis0" ]]; then',
     '      if false; then',
     "xver", "监听没回来却判成功"),

    ("⑧ 摘掉恢复时的旧核 SHA 对账", PDG,
     '    if [[ -n "$sha" && "$(_pdg_sha "$bin")" != "$sha" ]]; then',
     '    if false; then',
     "xver", "6c"),

    ("⑨ 旧版钉值被改(拿别的东西冒充真实旧版)", PINS,
     '  [mosdns-bin-amd64]="c6c255ec47ef0698308fcecfa41c8af91ea1c8bea273d1254b5b53aa45dc317c"',
     '  [mosdns-bin-amd64]="0000000000000000000000000000000000000000000000000000000000000000"',
     "xver", "旧版与钉值不符"),

    ("⑩ 旧版自报版本判据被架空", PINS,
     'PDG_LEGACY_MOSDNS_SELFVER="v5.3.3-0-g025823c"',
     'PDG_LEGACY_MOSDNS_SELFVER="v9.9.9-0-gdeadbee"',
     "xver", "旧版自报版本不符"),

    ("⑪ 真 systemd job 自己去 GitHub 取件", CI,
     '      - name: "换核回滚穿过启动限速 (真 v5.3.3 + 真 systemd; 八项排除法钉死第一失败点)"',
     '      - name: "偷偷取件"\n        run: curl -fsSL https://github.com/IrineSistiana/mosdns/releases/download/v5.3.3/mosdns-linux-amd64.zip -o /tmp/x.zip\n'
     '      - name: "换核回滚穿过启动限速 (真 v5.3.3 + 真 systemd; 八项排除法钉死第一失败点)"',
     "topo", "curl"),
]


def main():
    npass = nfail = 0
    print("══ 正控: 不改任何东西, 三支必须全绿 ══")
    for k in TESTS:
        rc, fails = run(k)
        if rc == 0:
            print("[OK]   正控 %-7s 绿" % k); npass += 1
        else:
            print("[FAIL] 正控 %s 本来就是红的(%d 条): %s" % (k, len(fails), fails[:3]))
            print("正控没过, 停。")
            return 1

    print("\n══ 负控: %d 格 ══" % len(CELLS))
    for name, path, old, new, test, kw in CELLS:
        src = io.open(path, encoding="utf-8").read()
        hits = src.count(old)
        if hits != 1:
            print("[FAIL] [%s] 锚点命中 %d 次(期望 1) —— 被测代码换写法了, 负控要跟着改" % (name, hits))
            nfail += 1
            continue
        before, mode = sha(path), os.stat(path).st_mode
        io.open(path, "w", encoding="utf-8").write(src.replace(old, new))
        try:
            rc, fails = run(test)
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
            os.chmod(path, mode)
        if sha(path) != before or os.stat(path).st_mode != mode:
            print("[FAIL] [%s] 还原后内容或 mode 对不上 —— 负控自己弄脏了工作树" % name)
            nfail += 1
            continue
        if rc == 0:
            print("[FAIL] [%s] 改坏了 %s 却仍然全绿 —— 那条断言没有牙齿" % (name, test))
            nfail += 1
            continue
        hit = any(kw in l for l in fails)
        print("[%s]   [%s] → %s 变红 %d 条%s"
              % ("OK" if hit else "FAIL", name, test, len(fails),
                 (", 且点到「%s」" % kw) if hit else (", 但**没**点到「%s」" % kw)))
        if hit:
            npass += 1
        else:
            nfail += 1
            print("       红在别处, 前 3 条: %s" % fails[:3])

    print("\n══ 反向对照: 只加注释不得凭空造出失败 ══")
    for path in (PDG, PINS):
        src = io.open(path, encoding="utf-8").read()
        before, mode = sha(path), os.stat(path).st_mode
        io.open(path, "a", encoding="utf-8").write(
            "\n# 无关注释: _core_restart_clean reset-failed systemctl restart PDG_LEGACY_SHA256\n")
        try:
            rc, f = run("xver")
        finally:
            io.open(path, "w", encoding="utf-8").write(src)
            os.chmod(path, mode)
        if rc == 0 and sha(path) == before:
            print("[OK]   [%s] 追加纯注释后仍全绿, 还原后摘要一致" % os.path.basename(path))
            npass += 1
        else:
            print("[FAIL] [%s] 纯注释造出了失败(%d 条)或未还原" % (os.path.basename(path), len(f)))
            nfail += 1

    print("\n══ 收尾 ══")
    for p in (PDG, PINS, CI):
        print("  %-22s sha256 %s…" % (os.path.basename(p), sha(p)[:16]))
    rc, _ = run("xver")
    print("  还原后跨版本 E2E: %s" % ("绿" if rc == 0 else "红"))
    npass += 1 if rc == 0 else 0
    nfail += 0 if rc == 0 else 1

    print("\n" + "-" * 40)
    print("通过 %d, 失败 %d" % (npass, nfail))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())

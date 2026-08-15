#!/usr/bin/env python3
"""迁移矩阵的子集执行开关必须 fail-closed。

为什么要有这个开关: 负控要给 12 类各跑一遍矩阵, 而完整矩阵约 10 分钟(F11 光是等
5399 门走满 21 次轮询就 5 秒), 25 次运行超过 4 小时。让每类只跑相关的节能把总时长
降一个量级 —— 但**不削弱任何判据**: 被选节的断言一条不减, 只是不跑无关的节。

为什么必须 fail-closed: 这个开关只该出现在负控里。要是它在 CI 或普通运行里被误设,
矩阵会静默地只跑一小部分却照样打印"通过" —— 那正是这套东西最怕的假绿。所以未经
授权、拼错、重复、空值一律立即非零退出, 而不是忽略或降级。

这支只验解析层, 秒级, 不需要 root 也不需要 systemd。
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MX = os.path.join(ROOT, "tests", "e2e-dot-migrate.sh")
npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def run(**env):
    e = dict(os.environ, PDG_E2E_ISOLATED="1", **env)
    p = subprocess.run(["bash", MX], capture_output=True, text=True, timeout=120, env=e)
    return p.returncode, (p.stdout or "").splitlines()[:1]


print("── 未经授权/非法输入必须拒绝(rc=2) ──")
CASES = [
    ("未授权: 设了 SECTIONS 但没有 PDG_NEGCTL", {"PDG_MIGRATE_SECTIONS": "F11"}),
    ("空值", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": ""}),
    ("未知标识", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "NOPE"}),
    ("重复标识", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "F11,F11"}),
    ("只有逗号", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": ",,"}),
    ("非法分隔符", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "F11;F12"}),
    ("小写标识", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "f11"}),
    ("前后空格", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": " F11"}),
]
for name, env in CASES:
    rc, first = run(**env)
    (ok if rc == 2 else bad)("%-34s → rc=%d(应 2) %s" % (name, rc, first))

print("\n── 合法输入解析正确(随后停在 root 门 rc=1, 这里只看首行) ──")
for name, env, want in (
    ("未设置 → FULL", {}, "SECTIONS: FULL"),
    ("单选 F11", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "F11"}, "SECTIONS: F11"),
    ("多选", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "PREFLIGHT,F11"},
     "SECTIONS: PREFLIGHT F11"),
    # 乱序不拒绝, 而是规范化成固定顺序 —— 这样"选了哪几节"与"写的顺序"无关,
    # 负控每次跑出来的节序都一样, 便于逐次比对
    ("乱序规范化", {"PDG_NEGCTL": "1", "PDG_MIGRATE_SECTIONS": "F13,PREFLIGHT,F02"},
     "SECTIONS: PREFLIGHT F02 F13"),
):
    rc, first = run(**env)
    got = first[0] if first else ""
    (ok if got == want else bad)("%-16s → 首行 %r(应 %r)" % (name, got, want))

print("\n── CI 与生产路径里不得出现这个变量 ──")
ci = open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8").read()
(ok if "PDG_MIGRATE_SECTIONS" not in ci else bad)("ci.yml 里没有 PDG_MIGRATE_SECTIONS")
(ok if "PDG_NEGCTL" not in ci else bad)("ci.yml 里没有 PDG_NEGCTL")
for rel in ("deploy/bot/pdg.sh", "install.sh", "uninstall.sh"):
    src = open(os.path.join(ROOT, rel), encoding="utf-8").read()
    (ok if "PDG_MIGRATE_SECTIONS" not in src else bad)("%s 里没有这个测试开关" % rel)

print("\n── 生产轮询次数没被动过 ──")
pdg = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
(ok if "while [[ $i -lt 20 ]]" in pdg else bad)("5399 等待仍是 20 次循环(未被测试改小)")
(ok if "sleep 0.25" in pdg else bad)("轮询间隔仍是 0.25s")

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

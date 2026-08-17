#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ─────────────────────────────────────────────────────────────────────────────
# doctor 必须看得见「续期钩子写证书的目录 ≠ mosdns 读证书的目录」。
#
# .153 上的真实形态: mosdns 的 config.yaml 里 cert 指向 /etc/dnsdist/certs(dnsdist
# 时代留下的路径), 而 deploy-hook 按 PDG_CERT_DIR 缺省写 /etc/mosdns/certs。那台机器
# 之所以一直没出事, 是因为还留着一个名叫 99-reload-dnsdist.sh 的老钩子在往
# /etc/dnsdist/certs 拷 —— 而那个钩子, 从名字到位置都像是该跟 dnsdist 一起删掉的残留。
#
# 这类故障最难的地方在于**它在到期前完全没有征兆**: 证书文件在、没过期, check_cert 判绿;
# certbot 续期成功; 钩子退 0; doctor 26 项全 ok。一直到证书到期那天, 全部手机的 DoT
# 同时连不上, 而现场没有任何一条日志说自己错了。
#
# 判据不碰真文件系统: 把 checks._mos()(读 mosdns 配置)和 checks._profile()(读
# profile.env)换成受控替身, 逐格喂路径组合, 看 doctor 给什么。
# ─────────────────────────────────────────────────────────────────────────────
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import checks  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m); PASS[0] += 1


def bad(m):
    print("[FAIL] " + m); FAIL[0] += 1


def run(cert_line, profile_cert_dir=""):
    """喂一份 mosdns 配置片段与 PDG_CERT_DIR, 取回 (level, check, detail)。

    cert_line 为 None 表示 mosdns 配置里压根没有 cert: 那一行(没开 DoT)。
    """
    mos = "" if cert_line is None else (
        "plugins:\n"
        "  - tag: dot_server\n"
        "    type: tcp_server\n"
        '    args: {entry: main_sequence, listen: "0.0.0.0:853", '
        f'cert: "{cert_line}", key: "/x/privkey.pem"}}\n'
    )
    old_mos, old_profile = checks._mos, checks._profile
    try:
        checks._mos = lambda: mos
        checks._profile = lambda k: (profile_cert_dir if k == "PDG_CERT_DIR" else "")
        return checks.check_cert_dir_sync()
    finally:
        checks._mos, checks._profile = old_mos, old_profile


# ── 1) .153 的真实故障: 路径不一致必须判 fail ────────────────────────────────
lvl, name, detail = run("/etc/dnsdist/certs/fullchain.pem")
if lvl == "fail":
    ok("mosdns 读 /etc/dnsdist/certs 而钩子写 /etc/mosdns/certs → 判 fail")
else:
    bad("路径不一致却判 %r —— 这正是到期日静默停服那条路" % lvl)

# 报错必须把**两个**路径都说出来: 只说"不一致"的话, 运维不知道该改哪一头。
if "/etc/dnsdist/certs" in detail and "/etc/mosdns/certs" in detail:
    ok("失败详情同时点出 mosdns 侧与钩子侧的路径")
else:
    bad("失败详情没把两个路径都写出来, 定位不了: %r" % detail[:90])

# 而且要给出可执行的两条出路(迁目录 / 设 PDG_CERT_DIR), 不是只报"坏了"。
if "PDG_CERT_DIR" in detail:
    ok("失败详情给了 PDG_CERT_DIR 这条现成出路")
else:
    bad("失败详情没告诉运维怎么修")

# ── 2) 一致就得判 ok, 不许误报 ───────────────────────────────────────────────
lvl, _, _ = run("/etc/mosdns/certs/fullchain.pem")
if lvl == "ok":
    ok("两边都是 /etc/mosdns/certs → 判 ok")
else:
    bad("路径一致却判 %r —— 误报会挡住 pdg update(doctor 是更新硬门)" % lvl)

# ── 3) PDG_CERT_DIR 覆盖: 旧机合法地把两边都设成老路径 ──────────────────────
# 这是产品**支持**的用法(pdgtx.py 会校验这个值), 不能因为路径长得旧就判红。
lvl, _, _ = run("/etc/dnsdist/certs/fullchain.pem",
                profile_cert_dir="/etc/dnsdist/certs")
if lvl == "ok":
    ok("profile.env 设了 PDG_CERT_DIR 对齐老路径 → 判 ok")
else:
    bad("合法的 PDG_CERT_DIR 覆盖被判 %r" % lvl)

# 反过来: PDG_CERT_DIR 设成第三个地方, 依然要红。
lvl, _, _ = run("/etc/mosdns/certs/fullchain.pem",
                profile_cert_dir="/opt/somewhere/certs")
if lvl == "fail":
    ok("PDG_CERT_DIR 指向第三处 → 判 fail")
else:
    bad("PDG_CERT_DIR 与 mosdns 各指一处却判 %r" % lvl)

# ── 4) 没开 DoT 的机器不该被这道门拦住 ───────────────────────────────────────
lvl, _, detail = run(None)
if lvl == "ok" and "无需检查" in detail:
    ok("mosdns 没配 DoT 证书 → 明说无需检查, 不拿缺省值硬凑一个结论")
else:
    bad("没配 DoT 时判 %r / %r" % (lvl, detail[:60]))

# ── 5) 归一化: 结尾斜杠不是"另一个目录" ──────────────────────────────────────
# 这条不是吹毛求疵 —— PDG_CERT_DIR 是人手写进 profile.env 的, 多一个斜杠是常事,
# 而一次误报会直接把 pdg update 挡死(doctor 是更新的硬门)。
lvl, _, _ = run("/etc/mosdns/certs/fullchain.pem",
                profile_cert_dir="/etc/mosdns/certs/")
if lvl == "ok":
    ok("PDG_CERT_DIR 结尾多一个斜杠不算不一致")
else:
    bad("结尾斜杠被判成不同目录 (%r) —— 误报会挡死 pdg update" % lvl)

# ── 6) 这道门确实注册进了 doctor, 不是写完没挂上 ─────────────────────────────
# 光有函数没进 ALL, 等于没写 —— 而且这种"漏挂"从测试里看不出来, 除非专门验一次。
if checks.check_cert_dir_sync in checks.ALL:
    ok("check_cert_dir_sync 已注册进 checks.ALL, pdg doctor 会真的跑它")
else:
    bad("函数写了但没进 checks.ALL —— doctor 永远不会执行它")

# ── 7) 缺省值必须与钩子里的字面量同源 ────────────────────────────────────────
# 两处各写各的, 就会出现"钩子改了目录、doctor 还按老缺省判绿"的最坏情况:
# 门还在, 但它守的是一个已经不存在的约定。
HOOK = os.path.join(ROOT, "deploy", "cert", "99-reload-cert.deploy-hook.sh")
with open(HOOK, encoding="utf-8") as f:
    hook_src = f.read()
if ('PDG_CERT_DIR:-%s' % checks.HOOK_CERT_DIR_DEFAULT) in hook_src:
    ok("doctor 的缺省证书目录与 deploy-hook 里的字面量一致")
else:
    bad("doctor 缺省 %r 在钩子里找不到对应的 ${PDG_CERT_DIR:-...} —— 两处已经漂移"
        % checks.HOOK_CERT_DIR_DEFAULT)

# 同一个路径在仓库里有**三处**字面量: 这道门的缺省、钩子的 ${PDG_CERT_DIR:-...}, 以及
# install.sh 的 CERT_DIR(它决定新装机器的 mosdns config 里那行 cert 写什么)。
# 装机那处一旦跟另外两处岔开, 后果不是"有台机器配错了", 而是**从此每台新机**都装出
# 一个到期即停服的现场 —— 而且装完 doctor 立刻就红, 属于最贵的那种漂移。
INSTALL = os.path.join(ROOT, "install.sh")
with open(INSTALL, encoding="utf-8") as f:
    install_src = f.read()
if ('CERT_DIR="%s"' % checks.HOOK_CERT_DIR_DEFAULT) in install_src:
    ok("install.sh 装机时渲染的证书目录与这道门的缺省一致")
else:
    bad("install.sh 的 CERT_DIR 与 %r 不一致 —— 新装机器会当场踩这道门"
        % checks.HOOK_CERT_DIR_DEFAULT)

print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

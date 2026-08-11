#!/usr/bin/env python3
"""6.2B: witness 的正式生命周期 —— 装机、升级、平台切换、卸载。

这支测试要挡住的是一种**比不装更糟**的状态: service 显示 active、盘上一切齐全,
而 mosdns 那边根本没有把探测查询转给它。那时 linkstat 会一路走到"全程可用 + 无匹配
证据" → 报出 NOT_OBSERVED, 也就是对用户说"你手机的加密 DNS 没到达网关" —— 而真相是
我们的路由压根没接上。取证类结论撒这种谎, 比直接说"不可用"有害得多。

所以这里把 observer 当成一个**四件套的状态机**来验, 缺一不可:
    模块(dotwitness.py) + unit + env + mosdns 路由
四件齐了才允许说 observer 已部署; 任何一件缺失都必须能被明确指出来。

v1.9.0 是本轮的真实起点: 它的 mosdns 模板里一条 witness 都没有(实测命中 0), 而
`pdg update` 从不用新模板重渲 /etc/mosdns/config.yaml —— 它只做外科式的 _mosdns_*
迁移。所以"升级完就有 observer"这件事必须由一条**受管块迁移**来保证, 不能指望覆盖。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tmpguard  # noqa: E402

npass = nfail = 0


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


def sh(script, **kw):
    """在仓库根跑一段 bash, 返回 (rc, out)。"""
    p = subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True,
                       text=True, timeout=600, **kw)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


PDGSH = os.path.join(ROOT, "deploy", "bot", "pdg.sh")
INSTALL = os.path.join(ROOT, "install.sh")
UNINSTALL = os.path.join(ROOT, "uninstall.sh")
MODULES = os.path.join(ROOT, "lib", "modules.sh")
pdg_src = open(PDGSH, encoding="utf-8").read()
ins_src = open(INSTALL, encoding="utf-8").read()
uni_src = open(UNINSTALL, encoding="utf-8").read()
tmpl = open(os.path.join(ROOT, "deploy", "mosdns", "config.yaml"), encoding="utf-8").read()


# ═══ 1. 受管块标记: 新装模板与升级迁移必须用同一套 ═════════════════════════
head("1. mosdns 受管块标记")

BEGIN = "# >>> pdg-dotwitness"
END = "# <<< pdg-dotwitness"
(ok if BEGIN in tmpl and END in tmpl else bad)(
    "新装模板里有受管块起止标记 —— 升级迁移要靠它认出哪一段是我们管的; "
    "只看见某个插件名就当装好了的话, 半安装状态会被当成完整")
(ok if tmpl.count(BEGIN) == 2 and tmpl.count(END) == 2 else bad)(
    "模板里恰好两段受管块(插件区一段、main_sequence 分支一段), 实得 %d/%d"
    % (tmpl.count(BEGIN), tmpl.count(END)))

# 迁移必须用**同一套**标记。最初这条要求 pdg.sh 里也出现字面量 —— 那反而是在鼓励
# 抄第二份。真正该守的是"标记只有一个定义处": 模板里的那两段和迁移用的那两段来自
# 同一个模块, 迁移只是调用它。
route_src = open(os.path.join(ROOT, "deploy", "bot", "dotwroute.py"), encoding="utf-8").read()
(ok if BEGIN in route_src and END in route_src else bad)(
    "受管块标记定义在 dotwroute.py 里")
(ok if "dotwroute.py" in pdg_src else bad)(
    "迁移调用 dotwroute.py, 不自带第二份标记/插入逻辑(两份迟早分叉)")


# ═══ 2. 迁移函数存在并接进迁移链 ═══════════════════════════════════════════
head("2. 迁移函数与迁移链")

(ok if re.search(r"^migrate_dotwitness\(\)\{", pdg_src, re.M) else bad)(
    "有 migrate_dotwitness —— 没有它, v1.9.0 机器升级后 unit 会 active 而路由缺失")
m = re.search(r"^run_all_migrations\(\)\{(?:.*\n)*?^\}", pdg_src, re.M)
chain = m.group(0) if m else ""
(ok if "migrate_dotwitness" in chain else bad)("migrate_dotwitness 接进了 run_all_migrations")
(ok if re.search(r"migrate_dotwitness \|\| rc=1", chain) else bad)(
    "失败以 `|| rc=1` 传给既有 update rollback(用 `|| true` 的话装了一半也算成功)")
# 顺序: 必须排在模块部署之后 —— unit 起来时 /opt/pdg-bot/dotwitness.py 得先在
i_mod = chain.find("migrate_deploy_botfiles")
i_dw = chain.find("migrate_dotwitness")
(ok if 0 <= i_mod < i_dw else bad)(
    "排在 migrate_deploy_botfiles 之后(模块没落地就起服务 = 起一个空壳)")


# ═══ 3. 新装路径 ═══════════════════════════════════════════════════════════
head("3. fresh install(本轮不做, 预期红)")

# 判据要分开钉: 这个字符串在 units= 闭包和安装行里各出现一次, 只查"文件里有没有"的话
# 删掉任一处另一处仍在, 判据恒真(负控 LC-1/LC-2 就是这么抓到的)。
(ok if re.search(r'^install -m644 "\$REPO_DIR"/deploy/bot/pdg-dotwitness\.service '
                 r'/etc/systemd/system/$', ins_src, re.M) else bad)(
    "install.sh 安装 witness unit(独立的 install -m644 行)")
m_units = re.search(r'local units="([^"]*)"', ins_src, re.S)
(ok if m_units and "pdg-dotwitness.service" in m_units.group(1) else bad)(
    "witness unit 在 install 的回滚闭包 units= 里 —— 不在的话装失败时它不会被收回")
(ok if re.search(r"enable[^\n]*pdg-dotwitness|pdg-dotwitness[^\n]*enable", ins_src) else bad)(
    "install.sh enable witness —— 装完即可用, 不要求用户再手工跑迁移")
(ok if "dotwitness.env" in ins_src else bad)("install.sh 写 dotwitness.env(6.2A 已有)")


# ═══ 4. 卸载 ═══════════════════════════════════════════════════════════════
head("4. uninstall(本轮不做, 预期红)")

(ok if "pdg-dotwitness" in uni_src else bad)("uninstall 处理 pdg-dotwitness")
(ok if re.search(r"disable[^\n]*pdg-dotwitness", uni_src) else bad)("uninstall disable --now 它")
(ok if re.search(r"pdg-dotwitness\}?\.service|pdg-dotwitness,|,pdg-dotwitness", uni_src)
 else bad)("uninstall 删 unit 文件")


# ═══ 5. 快照/备份覆盖 ══════════════════════════════════════════════════════
head("5. 快照必须覆盖新增的四件套")

# 判据按**实际覆盖方式**来, 不要求字面量: env 与 mosdns 配置是随父目录整个进快照的
# (etc/privdns-gateway、etc/mosdns), 硬要求文件名出现反而会逼人写一条冗余条目。
m = re.search(r"local cand=\((?:.*\n)*?[^\n]*\)\n", pdg_src)
cand = m.group(0) if m else ""
(ok if cand else bad)("找得到 update 快照的候选清单")
for path, why in (("etc/systemd/system/pdg-dotwitness.service", "witness unit"),
                  ("etc/privdns-gateway", "env 所在目录"),
                  ("etc/mosdns", "mosdns 配置所在目录"),
                  ("opt/pdg-bot", "运行模块所在目录")):
    (ok if path in cand else bad)(
        "%s 在快照清单里(%s) —— 不在的话 update 回滚回不到原状" % (path, why))
# evidence 是 /run 上的易失证据, **不许**进持久快照: 把它存下来等于把一次诊断的
# 观测结果带到另一个时间点去, 那时它既不新鲜也不再对应任何会话。
(ok if "evidence.json" not in cand and "run/pdg-dotwitness" not in cand else bad)(
    "evidence.json 不进持久快照(它在 /run, 是易失证据)")


# ═══ 6. 状态机: 不变不动 ═══════════════════════════════════════════════════
head("6. 状态机语义(静态判据)")

fn = re.search(r"^migrate_dotwitness\(\)\{(?:.*\n)*?^\}", pdg_src, re.M)
body = fn.group(0) if fn else ""
if not body:
    bad("拿不到 migrate_dotwitness 函数体, 下面几条无从判断")
else:
    (ok if re.search(r"cmp -s|cmp -s|_dw_same|changed=", body) else bad)(
        "按内容比较决定要不要写盘(每次都写 + daemon-reload 会平白打断在用的连接)")
    (ok if "daemon-reload" in body else bad)("unit 变化后 daemon-reload")
    (ok if re.search(r"restart mosdns|restart[^\n]*mosdns", body) else bad)(
        "mosdns 配置变化才 restart mosdns")
    (ok if re.search(r"restart[^\n]*pdg-dotwitness", body) else bad)(
        "witness 侧变化才 restart witness")
    # 回滚: 候选校验失败/启动失败都要恢复
    (ok if re.search(r"before|backup|_dw_restore|rollback", body, re.I) else bad)(
        "留 before-image 并在失败时恢复")
    (ok if re.search(r"mosdns start -c|mosdns -c|check_config|_mosdns_validate", body) else bad)(
        "用真 mosdns 二进制校验候选(只做文本检查的话, 坏配置会在 restart 时才炸)")


# ═══ 7. doctor: witness 故障不得冒充普通 DNS 故障 ══════════════════════════
head("7. doctor 严重级别(本轮只做「不进关键服务集」那条)")

chk = open(os.path.join(ROOT, "deploy", "bot", "checks.py"), encoding="utf-8").read()
m = re.search(r"^def expected_services\(\):(?:.*\n)*?^\s*return[^\n]*\n", chk, re.M)
exp = m.group(0) if m else ""
(ok if "pdg-dotwitness" not in exp else bad)(
    "witness **不在** expected_services —— 那是关键 DNS 服务集, 放进去等于让一个"
    "诊断辅助件的故障把普通 DNS 判成坏的")
(ok if re.search(r"^def check_deep_dot_witness\(\):", chk, re.M) else bad)(
    "doctor 有独立的 witness 检查函数")
# 定义了还不够, 得真的登记进 DEEP —— 只查函数在不在的话, 把登记删掉照样绿(LC-6)
m_deep = re.search(r"^DEEP = \[(.*?)\]", chk, re.M | re.S)
(ok if m_deep and "check_deep_dot_witness" in m_deep.group(1) else bad)(
    "witness 检查项已登记进 DEEP(定义了却不登记等于没查)")
# 严重级别: 旁路件的异常只能是 warn。升成 fail 等于让它把整台机器判成 DNS 坏了。
m_fn = re.search(r"^def check_deep_dot_witness\(\):(?:.*?)(?=^def )", chk, re.M | re.S)
body = m_fn.group(0) if m_fn else ""
(ok if body and '"fail"' not in body else bad)(
    "witness 检查的异常分支一律 warn, 没有 fail —— 它是旁路观察端, "
    "普通 DNS 不受它影响(P0 隔离门实测两种故障下各 9/9)")
# 文案不许泄露
mm = re.findall(r"[\"']([^\"']*dotwitness[^\"']*)[\"']", chk)
leak = [s for s in mm if re.search(r"qname|label|sha256|probe\.", s)]
(ok if not leak else bad)("doctor 文案不含 label/qname/hash/域名(实得 %s)" % (leak[:1] or "无"))


# ═══ 8. 平台通用 ═══════════════════════════════════════════════════════════
head("8. 平台通用性")

mod_src = open(MODULES, encoding="utf-8").read()
(ok if "dotwitness.py" in mod_src else bad)("dotwitness.py 在通用运行模块清单里")
m = re.search(r"PDG_IOS_MODULES=\"(?:[^\"]*)\"", mod_src)
(ok if m and "dotwitness" not in m.group(0) else bad)(
    "**不在** iOS 专属清单 —— 它是两平台公共件, 不能跟着 iOS unit 的生命周期走")
if body:
    (ok if not re.search(r"_pdg_platform.*ios|== ios", body) else bad)(
        "迁移函数不按平台分叉(平台切换后 witness 仍是同一个通用服务)")


print("\n" + "─" * 66)
print("通过 %d, 失败 %d" % (npass, nfail))
print("其中 fresh install / uninstall / doctor 三节本轮不在范围内(见 §10), "
      "它们的红是**已知待办**而不是回归。")
sys.exit(1 if nfail else 0)

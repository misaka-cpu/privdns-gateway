#!/usr/bin/env python3
"""文案必须与当前行为一致(历史记录不动, 但"现在怎么工作"不许说错)。

守三处曾经说错的:
  1. WLOC: 这一节原本守"热加载按 mtime"那句错话。该功能已**退役**, 现在守的是退役本身没
     说漏 —— 面向用户的文档不许再教人怎么用它, 设计文档保留但要标明是历史记录, 而且必须
     交代"网关删不掉手机上已经给出的证书信任, 那一步只有用户自己能做"。
  2. :81 探测端点: probe81.py 一直返回 **200**(iOS 的 URLStringProbe 只认 200), 而 unit
     描述和实战记录里写成 204 —— 有人照着去"修正"实现就把探测搞挂了。
  3. 端口清单: 写死一串全平台端口, 于是 iOS 机器上 doctor 声称 GMS 5228-5230 已就位
     (那段装机就剥掉了), Android 上又提 :81(它根本不装 pdg-probe81)。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
pass_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m); pass_n += 1


def bad(m):
    print("[FAIL]", m); sys.exit(1)


def text(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


# ── 1. WLOC 已退役: 文档不许再教人怎么用它 ─────────────────────────────────
# 这一节原本守的是"WLOC 热加载按 mtime"这句错话。功能退役后, 错的不再是某句描述, 而是
# **整套使用说明还在**: 照着它去操作的人会找不到按钮、找不到服务, 然后以为是自己装坏了。
#
# 判据分两层, 因为两种错法不同:
#   · 面向用户的文档(README)必须明确写"已退役", 并且**不再**给出操作步骤;
#   · 设计文档保留(它记着当初为什么这么做), 但必须在开头标明它是历史记录 —— 否则它读起来
#     和一份现行设计没有区别。
readme = text("README.md")
if "已退役" not in readme:
    bad("README 没写明 WLOC 已退役")
for lure in ("🍏 位置改写", "➕ 添加地点", "📍 地点 / 切换"):
    if lure in readme:
        bad(f"README 里还留着 WLOC 的操作入口「{lure}」—— 那些按钮已经不存在了")
ok("README 写明 WLOC 已退役, 且不再给出操作步骤")

# 退役说明必须把**手机那一侧**交代清楚: 网关删不掉手机上已经给出的证书信任, 只有用户能。
# 漏掉这一条, 用户手机上会长期留着一张仍被信任、而私钥去向不明的根证书。
sec = readme.split("## 10.", 1)[1].split("\n## ", 1)[0] if "## 10." in readme else ""
for need in ("证书信任设置", "重新生成"):
    if need not in sec:
        bad(f"README 的退役说明没交代「{need}」这一步")
ok("README 的退役说明交代了: 重新生成描述文件 + 到手机上取消对根 CA 的信任")

design = text("docs/design-mitm-plugins.md")
if "已退役" not in design.split("\n## ", 1)[0]:
    bad("docs/design-mitm-plugins.md 开头没标明它是已退役功能的历史记录")
ok("设计文档保留为历史记录, 且开头标明已退役")

# 实现侧: 那两个模块必须真的不在(文档说退役而代码还在, 同样是不一致)
for gone in ("deploy/bot/mitm_server.py", "deploy/bot/mitm_wloc.py"):
    if (ROOT / gone).exists():
        bad(f"{gone} 还在 —— 文档说退役了, 代码没退")
ok("MITM 宿主与 WLOC 插件确实已从仓库移除")

# ── 2. :81 返回 200 ─────────────────────────────────────────────────────────
probe = text("deploy/bot/probe81.py")
if "send_response(200)" not in probe:
    bad("probe81.py 的实现不是返回 200(不要按文档去改实现!)")
if "send_response(204)" in probe:
    bad("probe81.py 改成 204 了 —— iOS 的 URLStringProbe 不认 204")
ok("实现仍返回 HTTP 200(iOS URLStringProbe 只认 200)")

unit = text("deploy/bot/pdg-probe81.service")
if "204" in unit:
    bad("pdg-probe81.service 的描述里仍写 204")
if "200" not in unit:
    bad("pdg-probe81.service 的描述没写明返回 200")
ok("pdg-probe81.service 描述已改为 HTTP 200")

notes = text("docs/production-notes.md")
for m in re.finditer(r"[^\n]*204[^\n]*", notes):
    line = m.group(0)
    if "generate_204" in line:
        continue          # Google 的 generate_204 探测地址, 与 :81 无关, 不能动
    if ":81" in line or "probe81" in line or "探测端点" in line:
        bad(f"production-notes 里 :81 相关说明仍写 204: {line.strip()[:70]}")
ok("production-notes 的 :81 说明已改为 200(generate_204 那些是 Google 地址, 原样保留)")

# ── 3. 端口按平台 ──────────────────────────────────────────────────────────
checks = text("deploy/bot/checks.py")
if "def platform_ports_text(" not in checks:
    bad("端口清单没有按平台生成的函数")
ok("doctor 的端口清单由 platform_ports_text() 按平台生成")

install_md = text("docs/INSTALL.md")
for port, tag in (("| 81 |", "仅 iOS"), ("| 5228-5230 |", "仅 Android")):
    row = next((ln for ln in install_md.splitlines() if ln.startswith(port)), "")
    if not row:
        bad(f"INSTALL.md 端口表里找不到 {port}")
    if tag not in row:
        bad(f"INSTALL.md 里 {port} 没标注「{tag}」: {row}")
ok("INSTALL.md 端口表标注了 :81 仅 iOS / 5228-5230 仅 Android")

# 8445 是两平台共用的 Telegram SOCKS5 —— 不许被标成某个平台专属
if "8445" not in checks:
    bad("checks 里没有 8445(Telegram SOCKS5)")
_pp = checks.split("def platform_ports_text(", 1)[1].split("\ndef ", 1)[0]
if "8445" not in _pp:
    bad("8445 没进端口清单")
if re.search(r'"8445[^"]*(仅 iOS|仅 Android)', _pp):
    bad("8445 被标成了某平台专属 —— 它是两平台共用的 Telegram SOCKS5")
ok("8445 仍是两平台共用的 Telegram SOCKS5")

print("\n通过 %d 项断言" % pass_n)

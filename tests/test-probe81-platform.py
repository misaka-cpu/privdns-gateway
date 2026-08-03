#!/usr/bin/env python3
"""6.1B 阶段 1: pdg-probe81 从 iOS 专属改成 Android/iOS 公共组件。

6.1A 里 probe81 是 iOS 专属, 判据写死了"Android 不装 = 正确"。6.1B 要让两个平台
都有这个 HTTP 探测端点, 所以那批判据必须整体翻面 —— 翻不干净就会留下"Android 装了
服务但 doctor 不认它 / 平台切换又把它删掉"这种半残现场。

这支测试沿真实调用链逐个核对, 不看注释、不看文档:
  install / update / 老机迁移 / 平台切换 / doctor·checks·report / restart·status /
  uninstall / clean-root 安装闭包 / 模块 manifest。

刻意**不**改的三件事(它们已经是跨平台的, 见 6.1A 审查):
  · nftables 模板只有一份, 81 早就对 __INTERNAL_CIDR__ 放行, 无平台分叉;
  · uninstall.sh 无条件停用并删除 pdg-probe81;
  · pdgtx._SERVICE_UNITS 已含 pdg-probe81。
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS_N = [0]
FAIL_N = [0]


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def text(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def sh_fn(script, fn, pre="", post=""):
    """把 pdg.sh 里的一个函数抽出来真跑 —— 不是 grep 源码, 是看它的实际输出。"""
    src = text(script)
    r = subprocess.run(["bash", "-c", "set -u\n%s\n%s\n%s" % (pre, _extract(src, fn), post)],
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def _extract(src, fn):
    m = re.search(r"^%s\(\)\{.*?^\}" % re.escape(fn), src, re.S | re.M)
    if not m:
        m = re.search(r"^%s\(\)\s*\{.*?^\}" % re.escape(fn), src, re.S | re.M)
    return m.group(0) if m else ""


# ── 1. systemd unit: 会话状态的落点 ────────────────────────────────────────
print("── 1. pdg-probe81.service 具备写会话状态的条件 ──")
unit = text("deploy/ios/pdg-probe81.service")
for key, want, why in (
        ("DynamicUser", "true", "不许改成 root 常驻"),
        ("RuntimeDirectory", "pdg-probe81", "会话状态的唯一落点"),
        ("RuntimeDirectoryMode", "0700", "不许靠放宽权限解决所有权问题")):
    got = re.search(r"^%s=(.*)$" % key, unit, re.M)
    (ok if got and got.group(1).strip() == want else bad)(
        "%s=%s (%s)" % (key, got.group(1).strip() if got else "缺失", why))
# 不许出现新的持久数据目录
(ok if "StateDirectory" not in unit else bad)(
    "没有 StateDirectory —— 会话不跨重启存活, 不新增持久目录")
# 注意锚行首: "User=" 是 "DynamicUser=" 的子串, 朴素 in 判断在这里恒为假。
(ok if not re.search(r"^User=", unit, re.M) else bad)(
    "没有显式 User=(DynamicUser 生效, 不是 root 常驻)")

# ── 2. 模块 manifest: probe81.py 进公共运行模块 ────────────────────────────
print()
print("── 2. 模块 manifest 与安装/更新/卸载同一份真源 ──")
mods = text("lib/modules.sh")
rt = mods.split("PDG_RUNTIME_MODULES=")[1].split("PDG_IOS_MODULES=")[0]
ios_blk = mods.split("PDG_IOS_MODULES=")[1]
(ok if "probe81.py" in rt else bad)(
    "probe81.py 在 PDG_RUNTIME_MODULES 里(两平台都装)")
(ok if "probe81.py" not in ios_blk else bad)(
    "probe81.py 不再留在 PDG_IOS_MODULES 里(否则 iOS 会装两遍)")
for plat in ("android", "ios"):
    r = subprocess.run(["bash", "-c",
                        "source %s/lib/modules.sh; pdg_platform_modules %s" % (ROOT, plat)],
                       capture_output=True, text=True, timeout=60)
    names = [l.split()[1] for l in r.stdout.strip().splitlines() if len(l.split()) > 1]
    (ok if "probe81.py" in names else bad)(
        "%s 的模块集合含 probe81.py(共 %d 项)" % (plat, len(names)))

# ── 3. checks: 必需服务集与端口文案 ────────────────────────────────────────
print()
print("── 3. checks/doctor 在两平台都认 pdg-probe81 ──")
import checks  # noqa: E402
_orig_plat = checks._platform
for plat in ("android", "ios"):
    checks._platform = lambda _p=plat: _p
    try:
        svcs = checks.expected_services()
        ports = checks.platform_ports_text()
    finally:
        checks._platform = _orig_plat
    (ok if "pdg-probe81" in svcs else bad)(
        "%s 的必需服务集含 pdg-probe81(实得 %s)" % (plat, svcs))
    (ok if "81" in ports else bad)("%s 的端口文案含 81(实得 %s)" % (plat, ports))
    (ok if "仅 iOS" not in ports else bad)(
        "%s 的端口文案不再写「81(仅 iOS)」" % plat)
# deep 探测两平台都要跑
checks._platform = lambda: "android"
try:
    deep = checks.check_deep_probe81()
finally:
    checks._platform = _orig_plat
(ok if deep is not None else bad)(
    "Android 也走 deep :81 探测, 不再直接返回 None(实得 %r)" % (deep,))
# 返回的三元组第二项是标题: 两平台都跑了, 就不该再叫"iOS 探测"
checks._platform = lambda: "android"
try:
    deep_a = checks.check_deep_probe81()
    checks._platform = lambda: "ios"
    deep_i = checks.check_deep_probe81()
finally:
    checks._platform = _orig_plat
(ok if deep_a and deep_i and deep_a[1] == deep_i[1] else bad)(
    "两平台的 :81 探测标题一致(android=%r ios=%r)"
    % (deep_a[1] if deep_a else None, deep_i[1] if deep_i else None))
(ok if deep_a and "iOS" not in deep_a[1] else bad)(
    "Android 上的标题不再写「iOS 探测」(实得 %r)" % (deep_a[1] if deep_a else None))

# ── 4. pdg.sh 的服务集与重启清单 ──────────────────────────────────────────
print()
print("── 4. CLI 的服务集/重启清单两平台一致 ──")
for plat in ("android", "ios"):
    pre = '_pdg_core_svc(){ echo sing-box; }\n_pdg_platform(){ echo %s; }' % plat
    for fn in ("_pdg_svcs", "_pdg_required_svcs"):
        pre2 = pre + ('\n_pdg_bot_cred(){ echo ready; }' if fn == "_pdg_required_svcs" else "")
        rc, out, err = sh_fn("deploy/bot/pdg.sh", fn, pre2, fn)
        (ok if "pdg-probe81" in out else bad)(
            "%s / %s → %s" % (plat, fn, out or ("(空) " + err[:60])))

# ── 5. install.sh: 两平台都装 unit、都 enable、都纳入启动门槛 ──────────────
print()
print("── 5. install.sh 的三处平台闸门 ──")
ins = text("install.sh")
bad_gates = []
for pat, what in (
        (r'\[\[ "\$PLATFORM" == ios \]\] && install -m644 .*pdg-probe81\.service', "装 unit"),
        (r'\[\[ "\$PLATFORM" == ios \]\] && \{ systemctl enable --now pdg-probe81', "enable"),
        (r'\[\[ "\$PLATFORM" == ios \]\] && PLAT_SVCS\+=\(pdg-probe81\)', "启动门槛")):
    if re.search(pat, ins):
        bad_gates.append(what)
(ok if not bad_gates else bad)(
    "install.sh 里没有「仅 iOS 才装/起/校验 probe81」的闸门(残留: %s)" % (bad_gates or "无"))
(ok if re.search(r"install -m644 .*pdg-probe81\.service", ins) else bad)(
    "install.sh 无条件安装 pdg-probe81.service")
(ok if re.search(r"PLAT_SVCS=\((?=[^)]*pdg-probe81)", ins)
    or re.search(r"PLAT_SVCS=\(mosdns \"\$CORE_SVC\" pdg-probe81\)", ins) else bad)(
    "pdg-probe81 进了 PLAT_SVCS 启动门槛(两平台)")

# ── 6. 平台切换: Android 清理路径不许再删 probe81 ──────────────────────────
print()
print("── 6. 平台切换幂等: Android 清理不再删 probe81 ──")
pdgsh = text("deploy/bot/pdg.sh")
# 查字符串会误伤注释(说明"不再清理 probe81"的那句本身就含这个词), 所以**真跑一遍**:
# 进 mount namespace 把 /opt 和 /etc 铺成 tmpfs, 摆好 iOS 现场, 跑清理, 看谁活下来。
_probe = r"""
set -u
mkdir -p /opt/pdg-bot /etc/systemd/system /etc/privdns-gateway
: > /opt/pdg-bot/probe81.py
: > /opt/pdg-bot/mitm_ca.py
: > /opt/pdg-bot/mitm_server.py
: > /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
: > /etc/systemd/system/pdg-probe81.service
: > /etc/systemd/system/pdg-mitm.service
echo android > /etc/privdns-gateway/platform
c_g(){ :; }; c_y(){ :; }; c_r(){ :; }
systemctl(){ echo "systemctl $*" >> /opt/sysctl.log; return 0; }
_pdg_platform(){ echo android; }
_profile_set(){ :; }
PDG_PLATFORM_FILE=/etc/privdns-gateway/platform
%s
migrate_android_cleanup
echo "--FILES--"
for f in /opt/pdg-bot/probe81.py /etc/systemd/system/pdg-probe81.service \
         /opt/pdg-bot/mitm_ca.py /etc/systemd/system/pdg-mitm.service; do
  [ -e "$f" ] && echo "ALIVE $f" || echo "GONE  $f"
done
echo "--SYSCTL--"; cat /opt/sysctl.log 2>/dev/null || true
""" % _extract(pdgsh, "migrate_android_cleanup")
_sc = tempfile.mkdtemp(prefix="p81ns.")
_scp = os.path.join(_sc, "run.sh")
open(_scp, "w").write(_probe)
_r = subprocess.run(
    ["unshare", "-rm", "--", "sh", "-c",
     "mount -t tmpfs none /opt && mount -t tmpfs none /etc/systemd && exec bash \"$1\"",
     "sh", _scp],
    capture_output=True, text=True, timeout=120)
if _r.returncode != 0:
    bad("清理路径真跑失败: %s" % (_r.stderr.strip()[-140:] or _r.stdout.strip()[-140:]))
else:
    o = _r.stdout
    (ok if "ALIVE /opt/pdg-bot/probe81.py" in o else bad)(
        "Android 清理后 probe81.py **仍在**(公共件不该被删)")
    (ok if "ALIVE /etc/systemd/system/pdg-probe81.service" in o else bad)(
        "Android 清理后 pdg-probe81.service **仍在**")
    (ok if "disable --now pdg-probe81" not in o else bad)(
        "清理过程没有停用 pdg-probe81")
    (ok if "GONE  /opt/pdg-bot/mitm_ca.py" in o else bad)(
        "但 mitm_ca.py 被清掉了 —— 它才是真正的 iOS 专属(否则这几条是空转)")
    (ok if "GONE  /etc/systemd/system/pdg-mitm.service" in o else bad)(
        "pdg-mitm.service 也被清掉了")
# iOS 组件必需清单里不该再重复列 probe81(它已经是公共件, 由通用安装路径负责)
req = re.search(r"_PLAT_IOS_REQUIRED=\((.*?)\n\)", pdgsh, re.S)
if req:
    (ok if "probe81" not in req.group(1) else bad)(
        "_PLAT_IOS_REQUIRED 里不再列 probe81(公共件不归 iOS 专属清单管)")
# 平台切换失败的回滚清单同理
# 平台切换失败的回滚会按 _PLAT_FILES 逐个还原/删除。probe81 变公共件之后, 它在
# 两个平台都该存在, 不能再被当成"iOS 装上去的东西"在回滚时抹掉。
pf = re.search(r"local _PLAT_FILES=\((.*?)\n\s*\)", pdgsh, re.S)
if not pf:
    bad("找不到 _PLAT_FILES 回滚清单")
else:
    (ok if "probe81" not in pf.group(1) else bad)(
        "_PLAT_FILES 回滚清单里不再含 probe81(公共件不参与平台回滚)")
    (ok if "mitm" in pf.group(1) else bad)(
        "但 MITM 仍在回滚清单里 —— 它才是平台专属")
# 回滚时记录/恢复的服务状态同理
(ok if not re.search(r'for _psvc in pdg-probe81 pdg-mitm', pdgsh) else bad)(
    "回滚不再记录/还原 pdg-probe81 的 enabled/active 状态")

# ── 7. report: 服务列表两平台一致 ─────────────────────────────────────────
print()
print("── 7. report 的服务列表 ──")
rep = text("deploy/bot/report.py")
m = re.search(r"_svcs = list\(checks\.expected_services\(\)\).*?\n\n", rep, re.S)
seg = m.group(0) if m else rep
(ok if not re.search(r'_platform\(\) == "ios":\s*\n\s*_svcs\.append\("pdg-probe81"\)', seg) else bad)(
    "report 不再按平台单独补 pdg-probe81(已在 expected_services 里)")

# ── 8. clean-root 安装闭包 ────────────────────────────────────────────────
print()
print("── 8. 两平台的 clean-root 导入闭包 ──")
box = tempfile.mkdtemp(prefix="p81closure.")
for plat in ("android", "ios"):
    d = os.path.join(box, plat); os.makedirs(d, exist_ok=True)
    r = subprocess.run(["bash", "-c",
                        "source %s/lib/modules.sh; pdg_platform_modules %s" % (ROOT, plat)],
                       capture_output=True, text=True, timeout=60)
    for line in r.stdout.strip().splitlines():
        f = line.split()
        if len(f) < 2:
            continue
        src = ROOT / f[0]
        if src.exists():
            (Path(d) / f[1]).write_bytes(src.read_bytes())
    p = subprocess.run([sys.executable, "-c", "import probe81"], cwd=d,
                       capture_output=True, text=True, timeout=60,
                       env=dict(os.environ, PYTHONPATH=d))
    (ok if p.returncode == 0 else bad)(
        "%s clean-root 能 import probe81 (%s)" % (plat, p.stderr.strip()[-70:] or "OK"))

print("─" * 44)
print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
if PASS_N[0] + FAIL_N[0] == 0:
    print("零断言 —— 判失败"); sys.exit(1)
sys.exit(1 if FAIL_N[0] else 0)

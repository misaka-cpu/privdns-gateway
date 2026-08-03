#!/usr/bin/env python3
"""probe81 公共迁移必须 fail-closed: 部署源缺 unit 模板时不许静默说成功。

`.153` 真机验收踩到的那一幕: 我把运行模块与 CLI 同步到了新版本, 却没把 `$REPO_DIR`
(/opt/privdns-gateway)一起放到目标 commit。旧仓库里没有 deploy/bot/pdg-probe81.service,
于是 migrate_probe81_public 在第一行守卫 `[[ -f "$REPO_DIR/…" ]] || return 0` 直接返回 0 ——
**迁移一个字节没做, 调用方却收到"成功"**。表现是: `pdg __migrate` rc=0、更新流程一路绿灯,
而 pdg-probe81 unit 根本不存在, 链路诊断的 HTTP 会话入口整块能力静默缺席。

probe81 在 6.1B 之后是 Android/iOS **公共必需**服务, "模板不在就跳过"这条前提已经不成立了。
所以模板缺失现在是硬失败: 报错、返回非零、一个字节都不写。

判据全部落在**真跑那个 bash 函数**上(抽出来执行, 不是 grep 源码), 并且每一格都先自证前提:
夹具里 systemctl / install / daemon-reload 都是可观测的桩, 谁被调用过、调用了几次都留痕 ——
否则"没有写入"可能只是桩根本没接上。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


PDGSH = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")


def extract(fn):
    m = re.search(r"^%s\(\)\s*\{.*?^\}" % re.escape(fn), PDGSH, re.S | re.M)
    return m.group(0) if m else ""


FN = extract("migrate_probe81_public")
if not FN:
    bad("抽不到 migrate_probe81_public —— 判据无从谈起")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
ok("抽到了 migrate_probe81_public(%d 行)" % FN.count("\n"))


def run_case(*, template, unit_exists, unit_body="旧内容\n",
             fail_install=False, fail_reload=False, fail_enable=False,
             module_exists=True, platform="android"):
    """真跑一次迁移。返回 (rc, stdout, 事件列表, unit 最终内容或 None)。

    夹具把 install / systemctl / cmp 换成留痕的桩 —— 这样"没写入"是被证明的, 不是被假设的。
    """
    box = tempfile.mkdtemp(prefix="p81mig.")
    repo = os.path.join(box, "repo")
    os.makedirs(os.path.join(repo, "deploy", "bot"))
    if template:
        with open(os.path.join(repo, "deploy/bot/pdg-probe81.service"), "w") as f:
            f.write("[Service]\nDynamicUser=true\nRuntimeDirectory=pdg-probe81\n"
                    "RuntimeDirectoryMode=0700\nExecStart=/usr/bin/python3 "
                    "/opt/pdg-bot/probe81.py\n")
    optdir = os.path.join(box, "opt", "pdg-bot")
    os.makedirs(optdir)
    if module_exists:
        open(os.path.join(optdir, "probe81.py"), "w").write("# stub\n")
    sysd = os.path.join(box, "etc", "systemd", "system")
    os.makedirs(sysd)
    unit_path = os.path.join(sysd, "pdg-probe81.service")
    if unit_exists:
        open(unit_path, "w").write(unit_body)
    events = os.path.join(box, "events.log")
    bindir = os.path.join(box, "bin")
    os.makedirs(bindir)
    # install / systemctl / cmp 桩: 全部留痕, 并可按需失败
    with open(os.path.join(bindir, "install"), "w") as f:
        f.write("#!/bin/bash\necho \"install $*\" >> %s\n" % events
                + ("exit 1\n" if fail_install else
                   'dst="${@: -1}"; src="${@: -2:1}"; cp "$src" "$dst" 2>/dev/null; exit 0\n'))
    with open(os.path.join(bindir, "systemctl"), "w") as f:
        f.write("#!/bin/bash\necho \"systemctl $*\" >> %s\n" % events)
        f.write('case "$1" in\n')
        f.write("  daemon-reload) exit %d;;\n" % (1 if fail_reload else 0))
        f.write("  enable) exit %d;;\n" % (1 if fail_enable else 0))
        f.write("  is-enabled) %s;;\n" % ("echo enabled; exit 0" if unit_exists
                                          else "echo disabled; exit 1"))
        f.write("esac\nexit 0\n")
    for n in ("install", "systemctl"):
        os.chmod(os.path.join(bindir, n), 0o755)
    pre = (
        'export PATH="%s:$PATH"\n' % bindir
        + 'REPO_DIR="%s"\n' % repo
        + 'c_y(){ echo "WARN: $*"; }\nc_g(){ echo "OK: $*"; }\nc_r(){ echo "ERR: $*"; }\n'
        + '_pdg_platform(){ echo "%s"; }\n' % platform
        # 真实路径换成夹具里的 —— 函数体里的绝对路径靠这两个变量替换
    )
    body = (FN.replace("/etc/systemd/system/pdg-probe81.service", unit_path)
              .replace("/opt/pdg-bot/probe81.py", os.path.join(optdir, "probe81.py")))
    r = subprocess.run(["bash", "-c", "set -u\n%s\n%s\nmigrate_probe81_public; echo RC=$?"
                        % (pre, body)],
                       capture_output=True, text=True, timeout=60)
    ev = []
    if os.path.exists(events):
        ev = [l.strip() for l in open(events) if l.strip()]
    final = open(unit_path).read() if os.path.exists(unit_path) else None
    m = re.search(r"RC=(\d+)", r.stdout)
    rc = int(m.group(1)) if m else -1
    shutil.rmtree(box, ignore_errors=True)
    return rc, r.stdout + r.stderr, ev, final


# ═══ 夹具自证: 桩真的接上了 ═══════════════════════════════════════════════
print()
print("══ 0. 夹具自证 ══")
rc, out, ev, final = run_case(template=True, unit_exists=False)
(ok if any(e.startswith("install ") for e in ev) else bad)(
    "模板存在时 install 桩确实被调用过(夹具接上了, 实得 %s)" % ev[:3])
(ok if any("daemon-reload" in e for e in ev) else bad)("systemctl 桩确实被调用过")

# ═══ 1. 模板缺失 + 没有旧 unit → 必须非零且零写入 ═════════════════════════
print()
print("══ 1. 模板缺失, 目标机也没有 unit ══")
rc, out, ev, final = run_case(template=False, unit_exists=False)
(ok if rc != 0 else bad)("返回非零(实得 rc=%d) —— 修改前它返回 0, 那正是这次要修的" % rc)
(ok if final is None else bad)("没有创建 unit(实得 %r)" % (final,))
(ok if not any(e.startswith("install ") for e in ev) else bad)(
    "一次 install 都没跑(实得 %s)" % ev)
(ok if not any("daemon-reload" in e for e in ev) else bad)("没有 daemon-reload")
(ok if not any(e.startswith("systemctl enable") or "start" in e for e in ev) else bad)(
    "没有 enable/start 任何服务")
(ok if re.search(r"(缺少|缺失).*(模板|unit)", out) else bad)(
    "报出了明确原因(部署源缺 unit 模板), 实得: %s" % out.strip().splitlines()[:2])

# ═══ 2. 模板缺失但旧 unit 还在 → 仍非零, 旧 unit 原样保留 ═════════════════
print()
print("══ 2. 模板缺失, 但机器上已有旧 unit ══")
rc, out, ev, final = run_case(template=False, unit_exists=True, unit_body="老内容\n")
(ok if rc != 0 else bad)("仍然返回非零(实得 rc=%d)" % rc)
(ok if final == "老内容\n" else bad)("旧 unit 逐字节保留(实得 %r)" % (final,))
(ok if not any(e.startswith("install ") for e in ev) else bad)("没有覆盖旧 unit")
(ok if not any("daemon-reload" in e for e in ev) else bad)("没有 daemon-reload")

# ═══ 3. 模板存在 + 旧机没有 unit → 安装并启动 ═════════════════════════════
print()
print("══ 3. 模板存在, 旧机第一次装上 ══")
rc, out, ev, final = run_case(template=True, unit_exists=False)
(ok if rc == 0 else bad)("返回 0(实得 %d)" % rc)
(ok if final and "DynamicUser=true" in final else bad)("unit 落盘且内容来自项目真源")
(ok if final and "RuntimeDirectoryMode=0700" in final else bad)(
    "RuntimeDirectoryMode=0700 保持不变")
(ok if any(e.startswith("install -m644") for e in ev) else bad)(
    "用 install -m644 装(mode 正确, 实得 %s)" % [e for e in ev if e.startswith("install")])
(ok if any("daemon-reload" in e for e in ev) else bad)("做了 daemon-reload")
(ok if any("enable" in e for e in ev) else bad)("enable 了服务")

# ═══ 4. 模板存在 + unit 已是最新 → 幂等, 不做无意义重启 ═══════════════════
print()
print("══ 4. 已经装好了(幂等) ══")
tmpl = ("[Service]\nDynamicUser=true\nRuntimeDirectory=pdg-probe81\n"
        "RuntimeDirectoryMode=0700\nExecStart=/usr/bin/python3 /opt/pdg-bot/probe81.py\n")
rc, out, ev, final = run_case(template=True, unit_exists=True, unit_body=tmpl)
(ok if rc == 0 else bad)("返回 0(实得 %d)" % rc)
(ok if not any(e.startswith("install ") for e in ev) else bad)(
    "内容一致时不重复写盘(实得 %s)" % [e for e in ev if e.startswith("install")])
(ok if not any("restart" in e for e in ev) else bad)(
    "不做无意义重启(实得 %s)" % [e for e in ev if "restart" in e])

# ═══ 5. 模板存在 + unit 内容过旧 → 更新 ═══════════════════════════════════
print()
print("══ 5. unit 内容过旧 ══")
rc, out, ev, final = run_case(template=True, unit_exists=True, unit_body="很旧的内容\n")
(ok if rc == 0 else bad)("返回 0(实得 %d)" % rc)
(ok if final and "DynamicUser=true" in final else bad)("旧内容被换成项目真源")
(ok if any("daemon-reload" in e for e in ev) else bad)("换过之后 daemon-reload")

# ═══ 6-8. install / daemon-reload / enable 失败 ═════════════════════════
print()
print("══ 6-8. 各步失败 ══")
rc, out, ev, final = run_case(template=True, unit_exists=False, fail_install=True)
(ok if rc != 0 else bad)("install 失败 → 非零(实得 %d)" % rc)
(ok if not any("daemon-reload" in e for e in ev) else bad)(
    "install 失败后不继续 daemon-reload(不留半安装)")

rc, out, ev, final = run_case(template=True, unit_exists=False, fail_reload=True)
(ok if rc != 0 else bad)("daemon-reload 失败 → 非零(实得 %d)" % rc)

rc, out, ev, final = run_case(template=True, unit_exists=False, fail_enable=True)
(ok if rc != 0 else bad)("enable/start 失败 → 非零(实得 %d)" % rc)

# ═══ 9. 两个平台跑同一份公共迁移 ═════════════════════════════════════════
print()
print("══ 9. Android / iOS 一致 ══")
res = {}
for plat in ("android", "ios"):
    res[plat] = run_case(template=False, unit_exists=False, platform=plat)[0]
(ok if res["android"] == res["ios"] != 0 else bad)(
    "缺模板时两平台都非零(android=%s ios=%s)" % (res["android"], res["ios"]))
res2 = {}
for plat in ("android", "ios"):
    res2[plat] = run_case(template=True, unit_exists=False, platform=plat)[0]
(ok if res2["android"] == res2["ios"] == 0 else bad)(
    "模板存在时两平台都成功(android=%s ios=%s)" % (res2["android"], res2["ios"]))

# ═══ 10. 失败传播: run_all_migrations / __migrate / cmd_update ═══════════
print()
print("══ 10. 非零状态不被吞掉 ══")
# 要看的是 run_all_migrations 里的**调用点**, 不是函数定义那一行 —— 第一版正则匹配到了
# 定义行(`migrate_probe81_public(){`), 于是"没有 || true"这条永远成立, 是假绿。
_ra = re.search(r"^run_all_migrations\(\)\s*\{.*?^\}", PDGSH, re.S | re.M)
_call = None
if _ra:
    _call = re.search(r"^\s*migrate_probe81_public[^\n]*", _ra.group(0), re.M)
(ok if _ra else bad)("抽到了 run_all_migrations(前提成立)")
(ok if _call else bad)("run_all_migrations 里确实调了 migrate_probe81_public")
(ok if _call and "|| true" not in _call.group(0) else bad)(
    "调用点没有 `|| true` 吞掉非零(实得 %r)" % (_call.group(0).strip() if _call else None))
(ok if _call and ("rc=1" in _call.group(0) or "return" in _call.group(0)) else bad)(
    "失败被记进返回状态(实得 %r)" % (_call.group(0).strip() if _call else None))
upd = re.search(r"if ! bash /usr/local/bin/pdg __migrate; then.*?fi", PDGSH, re.S)
(ok if upd and "cmd_rollback" in upd.group(0) else bad)(
    "cmd_update 里 __migrate 失败会走回滚")
(ok if upd and "return 1" in upd.group(0) else bad)("并且不谎报更新完成")

# ═══ 10b. run_all_migrations 真的把非零传出来(行为级, 不是读源码)═════════
print()
print("══ 10b. run_all_migrations 的 rc(真跑)══")
_ra_body = extract("run_all_migrations")
_probe = subprocess.run(
    ["bash", "-c", "set -u\n"
     # 把这一轮里除 probe81 外的迁移全桩成成功, 只让 probe81 失败 —— 判据是"这一个失败
     # 能不能把整体 rc 顶成非零", 不是别的迁移的事。
     + "\n".join("%s(){ return 0; }" % f for f in re.findall(r"^\s*(migrate_[a-z0-9_]+)",
                                                             _ra_body, re.M))
     + "\nmigrate_probe81_public(){ return 1; }\n"
     + 'c_y(){ :; }; c_g(){ :; }\n'
     + _ra_body + "\nrun_all_migrations; echo RC=$?"],
    capture_output=True, text=True, timeout=60)
_m = re.search(r"RC=(\d+)", _probe.stdout)
(ok if _m and _m.group(1) != "0" else bad)(
    "只有 probe81 失败时 run_all_migrations 返回非零(实得 %s)"
    % (_m.group(1) if _m else _probe.stderr[-120:]))

print()
print("══ 10c. __migrate 与平台切换这两层 ══")
# 要钉的是 case 分派那一行, 不是 cmd_update 里那句含 "__migrate" 的错误提示 ——
# 宽松正则会先命中后者, 于是断言变成假绿(这一类错误本轮已经犯过三次)。
_disp = re.search(r"^\s*__migrate\)\s+need_root[^\n]*", PDGSH, re.M)
(ok if _disp else bad)("找到了 `__migrate` 的 case 分派行")
(ok if _disp and "run_all_migrations" in _disp.group(0) else bad)(
    "它直接调 run_all_migrations(rc 就是 CLI 的退出码, 实得 %r)"
    % (_disp.group(0).strip() if _disp else None))
(ok if _disp and "|| true" not in _disp.group(0) and "|| :" not in _disp.group(0)
 else bad)("分派行没有吞掉非零")
_cp = extract("cmd_platform")
_cpm = re.search(r"if ! migrate_probe81_public; then.*?fi", _cp, re.S)
(ok if _cpm else bad)("平台切换里单独跑了 probe81 迁移并判失败")
(ok if _cpm and "_plat_rollback" in _cpm.group(0) else bad)(
    "失败时走 _plat_rollback(不留半切换状态)")
(ok if _cpm and "return 1" in _cpm.group(0) else bad)("并且返回非零")

# ═══ 11. doctor 仍把 probe81 当两平台必需 ════════════════════════════════
print()
print("══ 11. doctor 的必需服务集 ══")
checks = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")
m = re.search(r"def expected_services.*?(?=\ndef )", checks, re.S)
blk = m.group(0) if m else ""
(ok if "pdg-probe81" in blk else bad)("expected_services 里有 pdg-probe81")
(ok if not re.search(r'ios.*?pdg-probe81|pdg-probe81.*?== "ios"', blk) else bad)(
    "没有把它写成 iOS 专属")

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

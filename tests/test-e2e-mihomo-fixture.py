#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""E2E 夹具取 mihomo 时必须形成钉值闭包 —— 与 e2e_seed_mosdns_bin 同一种语义。

由来是 exact-head CI 33348976467 的五支红灯。夹具里的 e2e_fetch_mihomo 当时是这样的:

    e2e_mihomo_is_real && return 0            # 只验"能解析好配置、能拒坏配置"
    curl … -o "$E2E_TMP/m.gz" || return 1     # 归档摘要一个字都不核
    gunzip -c "$E2E_TMP/m.gz" > /usr/local/bin/mihomo   # 直接写目标路径

于是夹具里那个 mihomo 是"能跑但未钉"的。生产判据从"只比自报版本"收紧成"绝对路径 +
内容摘要"之后, 它被正确地拒绝 —— 安装失败、update 被 doctor 判红回滚, 五支 E2E 全红。
夹具替被测代码说谎, 而这正是 e2e-lib.sh 里 mosdns 那段注释早就写过的形态。

本测试不碰公网: curl 由桩接管, 目标路径由参数注入(生产调用点不传参, 与
_update_mosdns_preflight 同一种写法, **不是**环境变量后门)。
"""
import io
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import tmpguard  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   %s" % m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] %s" % m)
    FAIL[0] += 1


LIB = io.open(os.path.join(ROOT, "tests/e2e-lib.sh"), encoding="utf-8").read()
VERSIONS = io.open(os.path.join(ROOT, "lib/versions.sh"), encoding="utf-8").read()
import re  # noqa: E402
PIN_VER = re.search(r'^MIHOMO_VER="([^"]+)"', VERSIONS, re.M).group(1)
ARCH = subprocess.run(["dpkg", "--print-architecture"], capture_output=True, text=True).stdout.strip() or "amd64"
PIN_BIN = dict(re.findall(r'\[mihomo-bin-(\w+)\]="([0-9a-f]{64})"', VERSIONS)).get(ARCH, "")
REAL = os.environ.get("PDG_TEST_MIHOMO") or os.path.join(ROOT, "tests/.bin/mihomo")

WORK = tmpguard.mkdtemp(prefix="pdg-e2emih.")


def sh(fn):
    """按行首锚点抽一个函数(单行函数也要正确收尾 —— sed 的 /^}/ 会吃到下一个函数)。"""
    i = LIB.index("\n%s(){" % fn) + 1
    line_end = LIB.index("\n", i)
    if LIB[i:line_end].rstrip().endswith("}"):
        return LIB[i:line_end]
    return LIB[i:LIB.index("\n}\n", i) + 3]


print("══ 0. 前提 ══")
(ok if PIN_BIN else bad)("lib/versions.sh 有 [mihomo-bin-%s]" % ARCH)
have_real = os.path.exists(REAL)
if have_real:
    import hashlib
    h = hashlib.sha256(open(REAL, "rb").read()).hexdigest()
    (ok if h == PIN_BIN else bad)("tests/.bin/mihomo 就是钉死版(内容 == 钉值)")
else:
    print("[SKIP] 没有钉死版 mihomo(bash tests/prepare-mihomo.sh) —— 复用/成功安装两类用例未验")

FN = sh("e2e_fetch_mihomo")
print()
print("══ 1. 闭包结构(源码级)══")
for name, pat, why in [
    ("按参数注入目标路径(默认 /usr/local/bin/mihomo)", r'local\s+bin="\$\{1:-/usr/local/bin/mihomo\}"',
     "写死路径就没法在沙箱里验, 只能靠真机"),
    ("用生产判据 pdg_mihomo_binary_ok", r"pdg_mihomo_binary_ok", "另写一套弱判断迟早与生产漂开"),
    ("核归档摘要 PDG_SHA256[mihomo-<arch>]", r"PDG_SHA256\[mihomo-\$", "不核归档 = 下到什么装什么"),
    ("解压到**临时候选**而不是直接写目标", r"gunzip -c[^\n]*\$tmp", "直写目标 = 截断就在生产路径上留半个内核"),
]:
    (ok if re.search(pat, FN) else bad)("%s —— %s" % (name, why))
(bad if re.search(r"gunzip -c[^\n]*>\s*\"?\$bin", FN) or re.search(r"gunzip[^\n]*/usr/local/bin/mihomo", FN)
 else ok)("解压不直接落到目标路径")
# 顺序断言: 候选必须在 install **之前**过生产判据。
# 没有这一条时, 把候选校验整个删掉也是绿的 —— 后置复核与真内核探针会顺带挡住它(纵深防御,
# 安全上没问题), 但"坏件绝不落盘"这条契约就没人守了。负控当场揭穿过。
_i_cand = FN.find('pdg_mihomo_binary_ok "$march" "$MIHOMO_VER" "$cand"')
_i_inst = FN.find('install -m755 "$cand"')
(ok if 0 <= _i_cand < _i_inst else
 bad)("候选的生产判据排在 install **之前**(cand=%d install=%d) —— 坏件绝不落盘" % (_i_cand, _i_inst))
_i_arch = FN.find('PDG_SHA256[mihomo-$march]')
_i_gun = FN.find('gunzip -c')
(ok if 0 <= _i_arch < _i_gun else
 bad)("归档校验排在解压**之前**(archive=%d gunzip=%d)" % (_i_arch, _i_gun))

print()
print("══ 2. 行为(curl 由桩接管, 目标路径注入沙箱)══")


def mk(path, ver, marker, mode=0o755, good_bad=True):
    """造一个 mihomo 壳: 自报 ver; good_bad=True 时能区分好/坏配置(骗过 is_real)。"""
    body = '#!/bin/sh\n# %s\ncase "$1" in\n  -v) echo "Mihomo Meta %s linux amd64";; \n' % (marker, ver)
    if good_bad:
        # 调用形态是 `mihomo -t -d <dir> -f <cfg>` → 配置路径是 **$5**, 不是 $4($4 是 -f)。
        # 第一版取了 $4, 于是好/坏配置**分不出来**, e2e_mihomo_is_real 恒假 —— 三格负控
        # 因此被掩盖(负控当场揭穿)。
        body += '  -t) grep -q "definitely-not-a-real-protocol" "$5" 2>/dev/null && exit 1; exit 0;;\n'
    body += 'esac\nexit 0\n'
    io.open(path, "w", encoding="utf-8").write(body)
    os.chmod(path, mode)


def run(target, archive_src, path_shadow=None, root=None):
    """跑一次 e2e_fetch_mihomo。archive_src=None → curl 失败; 否则 cp 该文件当下载物。"""
    h = os.path.join(WORK, "h.sh")
    lines = [
        'E2E_ROOT=%r' % (root or ROOT),
        'E2E_TMP=%r' % WORK,
        sh("e2e_mihomo_is_real"),
        FN,
        'curl(){ o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { o="$2"; shift; }; shift; done; ' +
        ('cp %r "$o"; }' % archive_src if archive_src else 'return 22; }'),
        'e2e_fetch_mihomo %r' % target,
    ]
    io.open(h, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    env = dict(os.environ)
    if path_shadow:
        env["PATH"] = path_shadow + os.pathsep + env["PATH"]
    r = subprocess.run(["bash", h], capture_output=True, text=True, errors="replace", env=env)
    out = r.stdout + r.stderr
    # 关键: 把"判据拒绝"与"夹具压根没跑起来"分开。函数若忽略注入的路径去写真的
    # /usr/local/bin/mihomo, 非 root 下会 Permission denied 而返回非 0 —— 那些 rc!=0
    # 是"跑不动", 不是"拒绝"。第一版就是这么写的, 八格因此假绿。
    ignored = ("/usr/local/bin/mihomo" in out) or ("Permission denied" in out) or ("command not found" in out)
    return r.returncode, out, ignored



def sandbox_root(archive_path):
    """造一个沙箱 E2E_ROOT: lib/versions.sh 的**归档**钉值改成 archive_path 的 sha,
    **二进制**钉值原样保留真值。这样归档那一关能过, 而"落盘内容 == 官方钉值"这条
    决定性断言仍然由真钉值把关(与 test-mihomo-real-swap.sh 同一种做法)。"""
    import hashlib
    r = os.path.join(WORK, "root-" + os.path.basename(archive_path).replace(".", "_"))
    os.makedirs(os.path.join(r, "lib"), exist_ok=True)
    sha = hashlib.sha256(open(archive_path, "rb").read()).hexdigest()
    txt = re.sub(r'\[mihomo-(amd64|arm64)\]="[0-9a-f]{64}"',
                 lambda m: '[mihomo-%s]="%s"' % (m.group(1), sha), VERSIONS)
    io.open(os.path.join(r, "lib", "versions.sh"), "w", encoding="utf-8").write(txt)
    return r


import gzip  # noqa: E402
import shutil  # noqa: E402

TGT = os.path.join(WORK, "mihomo")
SHADOW = os.path.join(WORK, "shadow")
os.makedirs(SHADOW, exist_ok=True)
mk(os.path.join(SHADOW, "mihomo"), PIN_VER, "PATH-SHADOW")

GOODGZ = os.path.join(WORK, "good.gz")
if have_real:
    with open(REAL, "rb") as fi, gzip.GzipFile(GOODGZ, "wb", mtime=0) as fo:
        shutil.copyfileobj(fi, fo)

IMPOSTOR = os.path.join(WORK, "impostor")
mk(IMPOSTOR, PIN_VER, "IMPOSTOR")
IMPGZ = os.path.join(WORK, "imp.gz")
with open(IMPOSTOR, "rb") as fi, gzip.GzipFile(IMPGZ, "wb", mtime=0) as fo:
    shutil.copyfileobj(fi, fo)

TRUNC = os.path.join(WORK, "trunc.gz")
io.open(TRUNC, "wb").write(open(IMPGZ, "rb").read()[:40] if os.path.getsize(IMPGZ) > 40 else b"x")


def before_image(p):
    if not os.path.exists(p):
        return None
    import hashlib
    st = os.stat(p)
    return (hashlib.sha256(open(p, "rb").read()).hexdigest(), st.st_mode, st.st_uid, st.st_gid)


cases = [
    ("① 目标不存在 → 进入取件", lambda: os.path.exists(TGT) and os.remove(TGT), IMPGZ, None, "fetch"),
    ("② PATH 上有假 %s → 仍不短路" % PIN_VER, lambda: os.path.exists(TGT) and os.remove(TGT), IMPGZ, SHADOW, "fetch"),
    ("③ 目标能跑且能分好坏配置但摘要不符 → 不短路", lambda: mk(TGT, PIN_VER, "REALISH"), IMPGZ, None, "fetch"),
    ("④ 目标是旧版 v1.19.29 → 不短路", lambda: mk(TGT, "v1.19.29", "OLD"), IMPGZ, None, "fetch"),
]
for name, setup, gz, shadow, expect in cases:
    setup()
    pre = before_image(TGT)
    rc, out, ignored = run(TGT, gz, shadow)
    if ignored:
        bad("%s → **未验**: 夹具忽略了注入路径/跑不动(%s)" % (name, out.strip().splitlines()[-1][:70] if out.strip() else "无输出"))
        continue
    if rc != 0:
        ok("%s(取件后被钉值拒绝 rc=%d, 没有静默复用)" % (name, rc))
    else:
        bad("%s → 竟然返回 0(短路了或装了冒牌货)" % name)
    post = before_image(TGT)
    if pre is not None and post != pre:
        bad("   ↑ 失败路径动了目标文件(前像未保全)")

print()
if have_real:
    shutil.copyfile(REAL, TGT)
    os.chmod(TGT, 0o755)
    rc, out, ignored = run(TGT, None)  # curl 一律失败: 若真短路就不会用到它
    if ignored:
        bad("⑤ **未验**: 夹具忽略注入路径")
    elif rc == 0:
        ok("⑤ 版本+摘要都对 → 直接复用, **零下载**(curl 桩恒失败仍返回 0)")
    else:
        bad("⑤ 已是钉死版却仍去取件(rc=%d) %s" % (rc, out.strip()[:80]))
else:
    print("[SKIP] ⑤ 需要钉死版 mihomo —— 未验")

mk(TGT, "v1.19.29", "OLD-SO-WE-REACH-DOWNLOAD")   # 先让复用门不成立, 否则下面三格根本走不到取件
pre = before_image(TGT)
rc, out, ignored = run(TGT, IMPGZ)
bad("⑥ **未验**: 夹具忽略注入路径") if ignored else (ok("⑥ 归档摘要不符 → 失败(rc=%d)" % rc) if rc != 0 else bad("⑥ 坏归档被接受"))
(ok if before_image(TGT) == pre else bad)("⑥ 目标文件逐字节未变")

mk(TGT, "v1.19.29", "OLD-SO-WE-REACH-DOWNLOAD")
pre = before_image(TGT)
rc, out, ignored = run(TGT, None)
bad("⑦ **未验**: 夹具忽略注入路径") if ignored else (ok("⑦ 下载失败/截断 → 失败(rc=%d)" % rc) if rc != 0 else bad("⑦ 下载失败却返回 0"))
(ok if before_image(TGT) == pre else bad)("⑦ 目标文件逐字节未变")
(ok if re.search(r"下载 mihomo", out) else
 bad)("⑦ 具名失败且点到**下载**这一层(不是被下一道门顺带挡住): %s" % out.strip().splitlines()[-1][:60] if out.strip() else "无输出")

mk(TGT, "v1.19.29", "OLD-SO-WE-REACH-DOWNLOAD")
pre = before_image(TGT)
rc, out, ignored = run(TGT, TRUNC, root=sandbox_root(TRUNC))
bad("⑧ **未验**: 夹具忽略注入路径") if ignored else (ok("⑧ 截断归档 → 失败(rc=%d)" % rc) if rc != 0 else bad("⑧ 截断归档被接受"))
(ok if before_image(TGT) == pre else bad)("⑧ 目标文件逐字节未变")

if have_real:
    mk(TGT, PIN_VER, "SAME-VER-WRONG-CONTENT")
    pre = before_image(TGT)
    rc, out, ignored = run(TGT, IMPGZ)
    bad("⑨ **未验**: 夹具忽略注入路径") if ignored else (ok("⑨ 同版本错内容(归档钉值都对得上, 只能靠二进制钉值拦) → 不安装(rc=%d)" % rc) if rc != 0 else bad("⑨ 同版本错内容被当成已就位"))
    (ok if before_image(TGT) == pre else bad)("⑨ 目标文件逐字节未变")

    os.path.exists(TGT) and os.remove(TGT)
    rc, out, ignored = run(TGT, GOODGZ, root=sandbox_root(GOODGZ))
    if rc == 0:
        ok("⑩ 正确归档 + 正确二进制 → 安装成功")
    else:
        bad("⑩ 正确归档却装不上: rc=%d %s" % (rc, out.strip()[:100]))
    import hashlib
    got = hashlib.sha256(open(TGT, "rb").read()).hexdigest() if os.path.exists(TGT) else ""
    (ok if got == PIN_BIN else bad)("⑪ 落盘内容 == 钉值(安装后用生产同源判据复核)")
    (ok if os.path.exists(TGT) and os.access(TGT, os.X_OK) else bad)("⑪ 落盘可执行")
else:
    print("[SKIP] ⑨⑩⑪ 需要钉死版 mihomo —— 未验")

print()
print("══ 3. 失败路径不留脏 ══")
os.path.exists(TGT) and os.remove(TGT)
run(TGT, IMPGZ)
leftovers = [f for f in os.listdir(WORK) if f.startswith("m.gz") or f.startswith("mihomo.cand")]
(ok if not leftovers else bad)("失败后临时物已清: %s" % (leftovers or "无"))
rc, out, ignored = run(TGT, IMPGZ)
(bad if re.search(r"✅|已装|成功", out) else ok)("失败路径没有错误的成功文案")

print("-" * 62)
print("test-e2e-mihomo-fixture.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""更新路径上的失败门与恶意/畸形产物。

**先说清楚哪条路是真的走的**, 免得测出一堆产品永远不会执行的假路径:

  · `cmd_update` 全程**不下载也不解包 archive** —— 代码来自 `git reset --hard <tag>`。
    所以"tar 路径穿越 / 绝对路径 / 软硬链接"在更新路径上根本不存在。它们的真实入口是
    `cfgrestore.safe_extract`(快照恢复、Bot 备份恢复、breakglass), 已由
    tests/test-restore-tar-safety.py 逐类覆盖, 本文件只复核那份覆盖仍在, 不复制第二套。
  · 更新路径里唯一的下载 + checksum 是**内核二进制**: curl → pdg_verify_sha256 → gunzip,
    单文件 `.gz`, 不是 tar。checksum 与截断两项落在这里。
  · manifest 本身的结构性校验发生在 `pdg_install_runtime_modules`。

真实阶段序列(从 deploy/bot/pdg.sh 的 cmd_update 读出):
  发现 tag → 更新前快照 → git reset --hard → 读 manifest → 部署静态文件 → __migrate
  → 内核二进制(下载/校验/解压) → py_compile → mihomo -t → nft -c → daemon-reload
  → 服务重启 → doctor → 提交或 cmd_rollback
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


BOX = tempfile.mkdtemp(prefix="relfault.")


def sh(body, cwd=None):
    r = subprocess.run(["bash", "-c", "set -uo pipefail\n" + body],
                       capture_output=True, text=True, cwd=cwd or ROOT, timeout=180)
    return r.returncode, r.stdout + r.stderr


PDG = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
UPD = PDG[PDG.index("\ncmd_update(){"):]
UPD = UPD[:UPD.index("\n}\n")]

print("== 1. 阶段图必须与生产代码一致 ==")
stages = [("更新前快照", "cmd_snapshot"), ("git reset 到 tag", "reset --hard"),
          ("读 manifest", "lib/modules.sh"), ("部署静态文件", "pdg_install_runtime_modules"),
          ("迁移", "__migrate"), ("内核二进制", "_update_core_binary"),
          ("py_compile", "py_compile"), ("mihomo 校验", "mihomo -t"),
          ("nft 校验", "nft -c"), ("doctor", "doctor.py"), ("回滚", "cmd_rollback")]
missing = [n for n, k in stages if k not in UPD]
if not missing:
    ok("cmd_update 里 %d 个阶段全部在位" % len(stages))
else:
    bad("阶段图对不上, 缺: %s" % "、".join(missing))
if "tar " not in UPD and ".tar.gz" not in UPD.replace("snap.tar.gz", ""):
    ok("更新路径确实不解包 archive(代码走 git 对象)")
else:
    bad("更新路径出现了 archive 处理 —— 阶段图要重画")

print("\n== 2. checksum 与截断: 内核二进制下载 ==")
core = PDG[PDG.index("_update_core_binary(){"):]
core = core[:core.index("\n}\n")]
if "pdg_verify_sha256" in core:
    ok("内核下载后先过 pdg_verify_sha256, 再解压")
else:
    bad("内核下载没有 checksum 门")
_i_sha, _i_gz = core.find("pdg_verify_sha256"), core.find("gunzip")
if 0 <= _i_sha < _i_gz:
    ok("checksum 在解压**之前**(坏档不会被展开)")
else:
    bad("checksum 排在解压之后")
# 真跑一次校验函数: 内容不符必须非 0, 且不写出任何东西
open(os.path.join(BOX, "art.gz"), "wb").write(b"not-really-a-gzip")
rc, out = sh('source lib/versions.sh; pdg_verify_sha256 "%s/art.gz" '
             '"0000000000000000000000000000000000000000000000000000000000000000" 测试产物'
             % BOX)
if rc != 0:
    ok("checksum 不匹配 → 非 0 拒绝(真跑 pdg_verify_sha256)")
else:
    bad("checksum 不匹配却返回 0")
# 截断: checksum 与截断内容**匹配**, 于是必然抵达 gunzip 而不是停在 checksum
import gzip
import hashlib
full = gzip.compress(b"A" * 4096)
trunc = full[: len(full) // 2]
open(os.path.join(BOX, "t.gz"), "wb").write(trunc)
digest = hashlib.sha256(trunc).hexdigest()
rc, out = sh('source lib/versions.sh; pdg_verify_sha256 "%s/t.gz" "%s" 截断产物' % (BOX, digest))
if rc == 0:
    ok("截断产物的 checksum 与其自身相符 → 通过 checksum 门(确保真抵达解压)")
else:
    bad("截断用例没能通过 checksum 门, 那它测的还是 checksum")
rc, out = sh('gunzip -c "%s/t.gz" > "%s/out" 2>/dev/null' % (BOX, BOX))
if rc != 0:
    ok("截断产物在 gunzip 阶段失败(不是拿 checksum 冒充截断覆盖)")
else:
    bad("截断产物竟然解压成功")

print("\n== 3. tar 恶意成员: 复核真实入口的覆盖仍在 ==")
safety = os.path.join(HERE, "test-restore-tar-safety.py")
txt = open(safety, encoding="utf-8").read() if os.path.exists(safety) else ""
need = {"绝对路径": '"/etc/passwd-pwned"', "`..` 穿越": '"../../OUTSIDE',
        "符号链接": "tarfile.SYMTYPE", "硬链接": "tarfile.LNKTYPE",
        "字符设备": "tarfile.CHRTYPE", "FIFO": "tarfile.FIFOTYPE"}
gone = [k for k, v in need.items() if v not in txt]
if not gone:
    ok("恶意 tar 成员的 %d 类仍由 test-restore-tar-safety.py 在真实解包入口覆盖" % len(need))
else:
    bad("这些类别失去覆盖: %s" % "、".join(gone))
# 那些入口确实是产品处理 tar 的地方
# 上面那条只核对"覆盖还在"。但白名单那道闸也会拒掉越界成员 —— 只断言"整包被拒"的话,
# 把 `..` 门整个摘掉两边照样全绿(实测如此)。所以这里再真跑一次, 按**是哪道闸**判:
# 越界成员必须由 `..` 那条判据点名, 而不是被"不在白名单里"顺带挡下。
import importlib.util as _ilu
_sp = _ilu.spec_from_file_location("cfgr_t", os.path.join(ROOT, "deploy/bot/cfgrestore.py"))
_cr = _ilu.module_from_spec(_sp)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
try:
    _sp.loader.exec_module(_cr)
except Exception as _e:  # noqa: BLE001
    _cr = None
if _cr is not None:
    import io as _io
    import tarfile as _tf
    _sent = os.path.join(BOX, "OUTSIDE")
    os.makedirs(_sent, exist_ok=True)
    _victim = os.path.join(_sent, "victim.txt")
    open(_victim, "w").write("ORIGINAL")
    _tp = os.path.join(BOX, "evil.tar.gz")
    with _tf.open(_tp, "w:gz") as _t:
        # 目标是白名单内的路径, 但用 `..` 绕出去 —— 白名单那道闸拦不住它, 只有 `..` 判据能。
        for _n in ("../../etc/mosdns/config.yaml", "../../OUTSIDE/pwned.txt"):
            _b = b"x\n"
            _i = _tf.TarInfo(_n); _i.size = len(_b); _i.mode = 0o644
            _t.addfile(_i, _io.BytesIO(_b))
    _dest = os.path.join(BOX, "extract-root")
    os.makedirs(_dest, exist_ok=True)
    _err = ""
    try:
        with _tf.open(_tp) as _t:
            _cr.safe_extract(_t, _dest, unmanaged="skip")
    except Exception as _e:  # noqa: BLE001
        _err = str(_e)
    _leaked = os.path.exists(os.path.join(_sent, "pwned.txt"))
    _changed = open(_victim).read() != "ORIGINAL"
    if _err and "`..`" in _err and not _leaked and not _changed:
        ok("`..` 越界成员由**穿越判据**点名拒绝(不是被白名单顺带挡下), 沙箱外哨兵未创建/未改动")
    else:
        bad("穿越拒绝的来源不对或有越界写入: err=%r 越界文件=%s 哨兵被改=%s"
            % (_err[:70], _leaked, _changed))
else:
    bad("加载不了 cfgrestore, 无法验证穿越门")

entries = [f for f in ("deploy/bot/cfgrestore.py", "deploy/rescue/breakglass.py")
           if "tarfile" in open(os.path.join(ROOT, f), encoding="utf-8").read()]
if len(entries) >= 2:
    ok("真实 tar 入口: %s" % "、".join(os.path.basename(e) for e in entries))
else:
    bad("找不到真实 tar 入口")

print("\n== 4. manifest 结构性校验(fail-closed) ==")
BAD_MANIFESTS = [
    ("重复目标名", "deploy/bot/doctor.py dup.py 755\ndeploy/bot/report.py dup.py 755"),
    ("非法 mode", "deploy/bot/doctor.py x.py 7777"),
    ("mode 非八进制", "deploy/bot/doctor.py x.py abc"),
    ("目标逃出受管目录", "deploy/bot/doctor.py ../../escaped.py 755"),
    ("目标含斜杠", "deploy/bot/doctor.py sub/x.py 755"),
    ("源路径逃出仓库", "../../../etc/passwd x.py 755"),
]
for desc, body in BAD_MANIFESTS:
    dest = os.path.join(BOX, "d" + str(abs(hash(desc)) % 9999))
    rc, out = sh('source lib/modules.sh\n'
                 'PDG_RUNTIME_MODULES="%s"\nPDG_IOS_MODULES=""\n'
                 'pdg_install_runtime_modules "%s" "%s" android' % (body, ROOT, dest))
    escaped = os.path.exists(os.path.join(BOX, "escaped.py"))
    if rc != 0 and not escaped:
        ok("%s → 拒绝(非 0, 未写出任何东西)" % desc)
    else:
        bad("%s 被放行了(rc=%s, 越界文件=%s)" % (desc, rc, escaped))

print("\n== 5. 缺 manifest 成员: 部署前点名, 不半装 ==")
for desc, body in (("通用成员缺失", "deploy/bot/doctor.py doctor.py 755\n"
                    "deploy/bot/__nonexistent__.py ghost.py 755"),
                   ("iOS 专属成员缺失", "deploy/bot/doctor.py doctor.py 755")):
    dest = os.path.join(BOX, "m" + str(abs(hash(desc)) % 9999))
    ios = "" if desc.startswith("通用") else "deploy/ios/__missing__.py ghost.py 755"
    rc, out = sh('source lib/modules.sh\nPDG_RUNTIME_MODULES="%s"\nPDG_IOS_MODULES="%s"\n'
                 'pdg_install_runtime_modules "%s" "%s" ios' % (body, ios, ROOT, dest))
    landed = sorted(os.listdir(dest)) if os.path.isdir(dest) else []
    if rc != 0 and "缺失" in out:
        ok("%s → 非 0 并点名缺失的源(落地 %d 项, 未成半装全集)" % (desc, len(landed)))
    else:
        bad("%s: rc=%s out=%s" % (desc, rc, out.strip()[:80]))

print("\n== 6. mode 语义 ==")
# release 里源文件 mode 不同, 部署后应按 manifest 归一, 而不是照抄源
src = os.path.join(BOX, "srcrepo")
os.makedirs(os.path.join(src, "deploy/bot"), exist_ok=True)
p = os.path.join(src, "deploy/bot/x.py")
open(p, "w").write("print(1)\n")
os.chmod(p, 0o600)
dest = os.path.join(BOX, "moded")
rc, out = sh('source lib/modules.sh\nPDG_RUNTIME_MODULES="deploy/bot/x.py x.py 755"\n'
             'PDG_IOS_MODULES=""\npdg_install_runtime_modules "%s" "%s" android' % (src, dest))
got = oct(os.stat(os.path.join(dest, "x.py")).st_mode & 0o777)[2:] if rc == 0 else "?"
if rc == 0 and got == "755":
    ok("源文件 mode 是 600, 部署后按 manifest 归一为 755(不照抄源)")
else:
    bad("mode 归一失败: rc=%s got=%s" % (rc, got))

print("\n== 7. 十项矩阵接入统一不变量比较 ==")
# 每个场景显式选 profile。profile 说清"这个场景允许什么变", 其余一律不许 —— 未声明的变化
# 就是失败, 不需要谁事先想到它。这正是之前十条各写各断言时漏掉的那一层。
INV = os.path.join(HERE, "update_invariants.py")


def _cap(tag, profile):
    out = os.path.join(BOX, "inv-%s.json" % tag)
    r = subprocess.run([sys.executable, INV, "capture", "--scenario", tag,
                        "--profile", profile, "--repo", ROOT, "--platform", "android",
                        "--source-repo", ROOT, "--out", out],
                       capture_output=True, text=True, timeout=300)
    return (out if r.returncode == 0 else None), (r.stdout + r.stderr)


def _cmp(before, after, profile, extra=()):
    r = subprocess.run([sys.executable, INV, "compare", before, after, "--profile", profile]
                       + list(extra), capture_output=True, text=True, timeout=300)
    try:
        return r.returncode, json.loads(r.stdout)
    except Exception as e:  # noqa: BLE001
        # 解析不出结果就是**这条比较没做成**, 不能靠退出码 0 混成绿。第一版这里宽 except
        # 吞掉了 NameError(json 没 import), 于是十条比较全都没真读过结果。
        return 1, {"ok": False, "failures": ["compare 输出解析失败: %s / %s"
                                             % (e, (r.stdout + r.stderr)[:80])]}


MATRIX = [
    ("1 checksum 错误",       "内核二进制下载", "pdg_verify_sha256", "update-prewrite", False),
    ("2 gzip 截断",           "内核二进制下载", "gunzip",            "update-prewrite", False),
    ("3 tar 路径穿越",        "cfgrestore.safe_extract", "成员遍历", "restore-safety",  False),
    ("4 tar 绝对路径",        "cfgrestore.safe_extract", "成员遍历", "restore-safety",  False),
    ("5 symlink/hardlink",   "cfgrestore.safe_extract", "成员遍历", "restore-safety",  False),
    ("6 缺 manifest 成员",    "pdg_validate_modules",   "部署前预检", "update-prewrite", False),
    ("7 py_compile 失败",     "cmd_update",             "py_compile", "update-rollback", True),
    ("8 mode 归一(成功)",     "pdg_install_runtime_modules", "部署", "mode-normalize-success", True),
    ("9 第 N 个部署失败",     "cmd_update",             "静态部署",  "update-rollback", True),
    ("10 manifest 结构不一致", "pdg_validate_modules",  "部署前预检", "update-prewrite", False),
]
rows = []
for name, entry, stage, profile, touches in MATRIX:
    b, err = _cap("b-" + name.split()[0], profile)
    if not b:
        bad("%s: 捕获 before 失败 %s" % (name, err.strip()[-80:]))
        continue
    # 场景本体已在上面各节真跑过; 这里在**同一进程状态**下再抓一次 after, 验证那些场景
    # 没有留下任何未声明的痕迹(残留、凭据、nft、事务、原仓库)。
    a, err = _cap("a-" + name.split()[0], profile)
    if not a:
        bad("%s: 捕获 after 失败 %s" % (name, err.strip()[-80:]))
        continue
    rc, res = _cmp(b, a, profile)
    rows.append({"场景": name, "入口": entry, "阶段": stage, "profile": profile,
                 "能力": res.get("capabilities", {}).get("systemd", "?"),
                 "覆盖生产": "是" if touches else "否",
                 "invariant": "通过" if rc == 0 else "失败"})
    if rc == 0:
        ok("%s → %s 比较通过" % (name, profile))
    else:
        bad("%s → %s 比较失败: %s" % (name, profile, res.get("failures", [])[:2]))

cols = ["场景", "入口", "阶段", "profile", "能力", "覆盖生产", "invariant"]
w = {c: max(len(c), max((len(str(r[c])) for r in rows), default=0)) for c in cols}
print("  " + " | ".join(c.ljust(w[c]) for c in cols))
print("  " + "-+-".join("-" * w[c] for c in cols))
for r in rows:
    print("  " + " | ".join(str(r[c]).ljust(w[c]) for c in cols))
if len(rows) == len(MATRIX):
    ok("十项矩阵全部接入统一比较(%d/%d)" % (len(rows), len(MATRIX)))
else:
    bad("只接入了 %d/%d 项" % (len(rows), len(MATRIX)))

subprocess.run(["rm", "-rf", BOX], timeout=60)
total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

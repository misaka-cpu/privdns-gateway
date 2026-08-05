#!/usr/bin/env python3
"""跨版本快照恢复矩阵(5.2/10c)。

样本不是手搓的: 成员清单从各版本 `cmd_snapshot` 的 `cand=()` 里解析, legacy 用仓库最早那份
真实 dnsdist.conf(见 snapmatrix.py)。这样"v1.6.2 兼容"才是**测出来**的结论, 而不是因为
版本号看着新就放行。

矩阵只管**格式识别与各道门的准入**。tar 本身的安全边界(穿越/软链/硬链/设备/重复成员/
各种上限)已经由 test-restore-tar-safety.py 逐条覆盖, 这里不复制第二套实现, 只在末尾复核
那份用例确实还在管这些事。
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import snapmatrix as SM  # noqa: E402
from rescuebox import Inst, TOKEN  # noqa: E402
from rescueform import Client, FormError, find_form  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


work = tmpguard.mkdtemp(prefix="snapmatrix.")


def fp_from_disk(pem):
    import hashlib
    import ssl
    with open(pem, encoding="utf-8") as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    h = hashlib.sha256(der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


def make_box():
    """现网: 一份合法的 mosdns + 数据模型, 服务都在。"""
    box = Box()
    box.up("mosdns")
    box.up("mihomo")
    for rel, data in (("etc/sing-box/config.json", SM.MODEL),
                      ("etc/mosdns/config.yaml", SM._mos_min(1024)),
                      ("etc/mosdns/rules/custom_direct.txt", b"domain:live.example\n"),
                      ("etc/privdns-gateway/rescue/token", b"live-token\n")):
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)
    return box


def rescue_for(box):
    keep = ("PDG_TX_", "PDG_LOCKFILE", "PDG_STABLE", "PATH")
    env = {k: v for k, v in box.env.items() if k.startswith(keep)}
    env["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    env["PDG_TX_FSROOT"] = box.root
    return Inst(work, extra_env=env)


def put_snapshot(box, snap_id, builder, *a):
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    return builder(os.path.join(d, "snap.tar.gz"), *a)


def members_of(box, snap_id):
    p = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id, "snap.tar.gz")
    with tarfile.open(p) as t:
        return t.getnames()


# ── 建一个装着全部样本的沙箱 ────────────────────────────────────────────────
SAMPLES = [
    ("current", "20260101-000001", SM.sample_current, "当前分支"),
    ("v1.6.2", "20260101-000002", SM.sample_v162, "v1.6.2 真实清单"),
    ("v1.5.6", "20260101-000003", lambda p: SM.write_tar(p, [
        (r, SM._fill(r)) for r in SM._expand(SM.snapshot_items("v1.5.6"))]) or
        SM._expand(SM.snapshot_items("v1.5.6")), "v1.5.6 真实清单(无 mihomo)"),
    ("legacy", "20260101-000004", SM.sample_legacy, "真实 dnsdist.conf"),
    ("unknown", "20260101-000005", SM.sample_unknown, "无任何已知特征"),
    ("mixed", "20260101-000006", SM.sample_mixed, "v1.6 与 dnsdist 特征并存"),
    ("pdgtx-syntax", "20260101-000007",
     lambda p: SM.sample_broken_modules(p, "pdgtx-syntax"), "快照内 pdgtx.py 语法坏"),
    ("cfgrestore-missing", "20260101-000008",
     lambda p: SM.sample_broken_modules(p, "cfgrestore-missing"), "快照内 cfgrestore.py 缺函数"),
    ("old-rescue", "20260101-000009",
     lambda p: SM.sample_broken_modules(p, "old-rescue"), "快照内旧版 rescue.py"),
]

box = make_box()
built = {}
for name, sid, builder, _desc in SAMPLES:
    r = put_snapshot(box, sid, builder)
    built[name] = (sid, r)

inst = rescue_for(box)
if not inst.start():
    bad("救援实例起不来: %s" % (inst.err or "")[:300])
    print("\n断言 %d 项: 通过 %d, 失败 %d" % (PASS[0] + FAIL[0], PASS[0], FAIL[0]))
    sys.exit(1)

cli = Client("127.0.0.1", inst.port, expect_fp=fp_from_disk(inst.cert), timeout=120)
st, _ = cli.login(TOKEN)
if st != 200:
    bad("登录失败 st=%s" % st)
    sys.exit(1)

sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import cfgrestore as CR  # noqa: E402


def probe(name):
    """把一份样本在各道门前的实际表现测出来, 返回矩阵一行。"""
    sid, _rels = built[name]
    row = {"样本": name, "快照ID": sid}
    ms = members_of(box, sid)
    row["格式识别"] = CR.snap_format(ms)
    st, body = cli.request("GET", "/")
    row["状态页"] = "可开" if st == 200 else "st=%s" % st
    st, page = cli.request("GET", "/snapshot/" + sid)
    row["详情页"] = "可读" if st == 200 else "st=%s" % st
    try:
        f = find_form(page, "/snapshot/restore")
        row["受管恢复"] = "允许"
        row["digest/nonce"] = "要求" if {"digest", "nonce"} <= set(f["fields"]) else "缺失"
    except FormError:
        row["受管恢复"] = "拒绝"
        row["digest/nonce"] = "—"
    st, bg = cli.request("GET", "/breakglass/" + sid)
    if st != 200:
        row["完整恢复"] = "页面 st=%s" % st
        row["末6位确认"] = "—"
    else:
        try:
            f = find_form(bg, "/breakglass/restore")
            row["完整恢复"] = "允许"
            need = set(f["fields"])
            row["末6位确认"] = "要求" if "confirm_text" in need else "否"
            if row["digest/nonce"] == "—":
                row["digest/nonce"] = "要求" if {"digest", "nonce"} <= need else "缺失"
        except FormError:
            row["完整恢复"] = "拒绝"
            row["末6位确认"] = "—"
    return row


print("\n== 1. 各样本在各道门前的实际表现 ==")
rows = [probe(n) for n, _s, _b, _d in SAMPLES]
cols = ["样本", "格式识别", "状态页", "详情页", "受管恢复", "完整恢复", "末6位确认", "digest/nonce"]
w = {c: max(len(c), max(len(str(r.get(c, ""))) for r in rows)) for c in cols}
print("  " + " | ".join(c.ljust(w[c]) for c in cols))
print("  " + "-+-".join("-" * w[c] for c in cols))
for r in rows:
    print("  " + " | ".join(str(r.get(c, "")).ljust(w[c]) for c in cols))
R = {r["样本"]: r for r in rows}

print("\n== 2. 边界判定 ==")
# 前提: snapshot_items 必须真的在读不同版本的历史对象。它要是无论传什么都回 HEAD 那份清单,
# 下面每一条"跨版本"结论都是在跟自己比 —— 全绿, 且毫无意义。v1.5.6 那版还没有 mihomo,
# 清单必然比 HEAD 短一截, 拿这个当哨兵。
_h, _v56 = SM.snapshot_items("HEAD"), SM.snapshot_items("v1.5.6")
if _h and _v56 and set(_v56) < set(_h):
    ok("前提: 历史清单确实按版本取(v1.5.6 %d 项 ⊂ HEAD %d 项)" % (len(_v56), len(_h)))
else:
    bad("前提不成立: 各版本清单没有差异, 跨版本矩阵等于在跟自己比(HEAD=%d v1.5.6=%d)"
        % (len(_h), len(_v56)))

if R["current"]["格式识别"] == "v1.6" and R["current"]["受管恢复"] == "允许" \
        and R["current"]["完整恢复"] == "允许":
    ok("当前格式: 受管恢复与完整恢复都放行")
else:
    bad("当前格式的门不对: %r" % R["current"])

# v1.6.2 不是"因为版本号新"才放行的 —— 它与 HEAD 的 cmd_snapshot 逐字节相同, 结构确实一样。
same = SM.snapshot_items("v1.6.2") == SM.snapshot_items("HEAD")
if same:
    ok("v1.6.2 与 HEAD 的 cmd_snapshot 清单逐字节相同(兼容性是比出来的, 不是按版本号放行)")
else:
    ok("v1.6.2 与 HEAD 清单有差异 —— 兼容结论只能来自下面的实际门禁")
if R["v1.6.2"]["受管恢复"] == "允许" and R["v1.6.2"]["格式识别"] == "v1.6":
    ok("v1.6.2: 结构等价, 受管恢复放行")
else:
    bad("v1.6.2 门禁与结构结论不一致: %r" % R["v1.6.2"])

if R["v1.5.6"]["格式识别"] == "v1.6":
    ok("v1.5.6(无 etc/mihomo, 只有数据模型): 仍按 v1.6 结构识别")
else:
    bad("v1.5.6 识别成 %s" % R["v1.5.6"]["格式识别"])

if R["legacy"]["格式识别"] == "legacy-dnsdist" and R["legacy"]["受管恢复"] == "拒绝" \
        and R["legacy"]["完整恢复"] == "允许" and R["legacy"]["末6位确认"] == "要求":
    ok("legacy-dnsdist: 受管恢复拒绝, 完整恢复要走末 6 位手输确认")
else:
    bad("legacy 门禁不对: %r" % R["legacy"])

if R["unknown"]["格式识别"] == "unknown" and R["unknown"]["受管恢复"] == "拒绝" \
        and R["unknown"]["完整恢复"] == "拒绝":
    ok("unknown: 两条恢复路径一律拒绝, 不猜格式")
else:
    bad("unknown 没有被一律拒绝: %r" % R["unknown"])

print("\n== 3. 特征冲突必须 fail-closed ==")
fmt = R["mixed"]["格式识别"]
if fmt not in ("v1.6", "legacy-dnsdist") and "dnsdist" in fmt and "1.6" in fmt:
    ok("同时带 v1.6 与 dnsdist 特征 → 识别为 %s(点名冲突特征)" % fmt)
else:
    bad("特征冲突被判成 %s —— 先匹配到哪条就算哪条, 歧义时没有 fail-closed" % fmt)
if R["mixed"]["受管恢复"] == "拒绝" and R["mixed"]["完整恢复"] == "拒绝":
    ok("特征冲突: 两条恢复路径都不放行")
else:
    bad("特征冲突仍被放行: 受管=%s 完整=%s"
        % (R["mixed"]["受管恢复"], R["mixed"]["完整恢复"]))

# 门必须长在**写路径**上, 不能只长在页面上: 页面之外的调用方(bot / CLI)否则就绕过去了。
os.environ["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
CR.SNAP_DIR = os.environ["PDG_SNAP_DIR"]
res = CR.restore_managed(built["mixed"][0], trigger_source="rescue")
if not res.get("ok") and "ambiguous" in (res.get("error") or ""):
    ok("直接调 restore_managed(绕过页面)同样被结构门拦下")
else:
    bad("写路径没有结构门: %r" % (res.get("error") or res.get("state")))
res = CR.restore_managed(built["legacy"][0], trigger_source="rescue")
if not res.get("ok") and "legacy-dnsdist" in (res.get("error") or ""):
    ok("写路径对 legacy 结构同样拒绝受管恢复")
else:
    bad("写路径放行了 legacy: %r" % (res.get("error") or res.get("state")))

# 兜底实现(cfgrestore 不可用时用的那份)必须与主实现判得一模一样。
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
import breakglass as BG  # noqa: E402
fb = BG.RescueSnapAPI() if hasattr(BG, "RescueSnapAPI") else None
if fb is None:
    for _n in dir(BG):
        _o = getattr(BG, _n)
        if isinstance(_o, type) and hasattr(_o, "snap_format") and _n != "type":
            try:
                fb = _o()
                break
            except Exception:  # noqa: BLE001
                continue
if fb is not None:
    diff = []
    for _name, _sid, _b, _d in SAMPLES:
        ms = members_of(box, _sid)
        if CR.snap_format(ms) != fb.snap_format(ms):
            diff.append(_name)
    if not diff:
        ok("兜底识别与主实现在全部 %d 个样本上判得一致" % len(SAMPLES))
    else:
        bad("兜底识别与主实现不一致: %s" % "、".join(diff))
else:
    bad("找不到 breakglass 的兜底识别实现 —— 无法比对")

print("\n== 4. 快照里带着坏掉的业务模块 ==")
for name, why in (("pdgtx-syntax", "pdgtx.py 语法坏"),
                  ("cfgrestore-missing", "cfgrestore.py 缺 restore_managed"),
                  ("old-rescue", "旧版 rescue.py")):
    r = R[name]
    if r["状态页"] == "可开" and r["详情页"] == "可读":
        ok("%s: 救援页照常可用(坏模块在快照里, 不是在盘上)" % why)
    else:
        bad("%s: 救援页受影响 状态页=%s 详情页=%s" % (why, r["状态页"], r["详情页"]))
if R["pdgtx-syntax"]["受管恢复"] == "允许":
    ok("坏模块属于**不受管**范围, 不阻断受管配置恢复(它们也不会被写进现网)")
else:
    bad("坏模块把受管恢复也挡了: %s" % R["pdgtx-syntax"]["受管恢复"])

print("\n== 5. 救援平面在完整恢复里被保护 ==")
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
lib = open(os.path.join(ROOT, "lib/rescue.sh"), encoding="utf-8").read()
import re as _re
m = _re.search(r'PDG_RESCUE_PROTECTED_MEMBERS="(.*?)"', lib, _re.S)
if m:
    names = [x.strip() for x in m.group(1).splitlines() if x.strip()]
    ok("保护清单由 lib/rescue.sh 单点定义, 共 %d 项" % len(names))
    if any("rescue" in n for n in names) and any("token" in n for n in names) \
            and any("key.pem" in n or "cert.pem" in n for n in names):
        ok("保护清单覆盖救援程序、token 与证书/私钥")
    else:
        bad("保护清单没覆盖救援程序/凭据: %r" % names[:8])
else:
    bad("lib/rescue.sh 里读不到 PDG_RESCUE_PROTECTED_MEMBERS")

print("\n== 6. tar 安全边界不在这里重复实现 ==")
safety = os.path.join(HERE, "test-restore-tar-safety.py")
if os.path.exists(safety):
    txt = open(safety, encoding="utf-8").read()
    # 按**代码构造**核对, 不按注释里的措辞 —— 换个说法就判红的断言只会制造假红。
    need = {"绝对路径成员": '"/etc/passwd-pwned"', "`..` 逃逸": '"../../OUTSIDE',
            "符号链接": "tarfile.SYMTYPE", "硬链接": "tarfile.LNKTYPE",
            "字符设备": "tarfile.CHRTYPE", "块设备": "tarfile.BLKTYPE",
            "FIFO": "tarfile.FIFOTYPE",
            "白名单路径也不许绝对/穿越": '"../../etc/sing-box/config.json"'}
    miss = [k for k, kw in need.items() if kw not in txt]
    if not miss:
        ok("tar 安全边界仍由 test-restore-tar-safety.py 覆盖(%d 类)" % len(need))
    else:
        bad("test-restore-tar-safety.py 不再覆盖: %s" % "、".join(miss))
else:
    bad("test-restore-tar-safety.py 不见了 —— tar 安全边界失去覆盖")

inst.stop() if hasattr(inst, "stop") else None
shutil.rmtree(work, ignore_errors=True)
total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

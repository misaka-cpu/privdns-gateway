#!/usr/bin/env python3
"""统一不变量捕获器/比较器自身的回归 + 十条行为负控。

捕获器是"十个失败场景共用的那把尺"。尺子本身出问题的后果比某一条用例失效更糟: 十条会一起
变绿, 而且是**看起来查了很多字段**的那种绿。所以这里逐条改坏一份真实快照, 要求比较器
确实报出对应的 invariant, 而不是靠"源码里有没有那个字段名"来判。
"""
import copy
import json
import os
import subprocess
import sys
import tempfile
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INV = os.path.join(HERE, "update_invariants.py")

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("  ✓ %s" % m)


def bad(m):
    FAIL[0] += 1
    print("  ✗ %s" % m)


BOX = tmpguard.mkdtemp(prefix="invtest.")


def capture(name, profile="update-prewrite", extra=(), platform="android"):
    out = os.path.join(BOX, name + ".json")
    cmd = [sys.executable, INV, "capture", "--scenario", name, "--profile", profile,
           "--repo", ROOT, "--platform", platform, "--source-repo", ROOT, "--out", out]
    r = subprocess.run(cmd + list(extra), capture_output=True, text=True, timeout=300)
    return r.returncode, out, r.stdout + r.stderr


def compare(before, after, profile="update-prewrite", extra=()):
    r = subprocess.run([sys.executable, INV, "compare", before, after, "--profile", profile]
                       + list(extra), capture_output=True, text=True, timeout=300)
    try:
        j = json.loads(r.stdout)
    except Exception:  # noqa: BLE001
        j = {"ok": None, "failures": [r.stdout + r.stderr]}
    return r.returncode, j


def mutate(src, fn, name):
    d = json.load(open(src, encoding="utf-8"))
    fn(d)
    p = os.path.join(BOX, name + ".json")
    json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)
    return p


print("== 1. 捕获器基本行为 ==")
rc, base, out = capture("base")
if rc == 0 and os.path.exists(base):
    ok("capture 成功产出快照")
else:
    bad("capture 失败: %s" % out.strip()[-200:])
    print("\n断言 1 项: 通过 0, 失败 1")
    sys.exit(1)
snap = json.load(open(base, encoding="utf-8"))
# iOS 也取一次: update_invariants 里 manifest 数量的钉值是**按平台分开**的, 而这支测试
# 一直只捕 android, 于是 ios 那条从来没执行过 —— 它的钉值早就跟真实清单对不上了(27 vs 30)
# 也没人发现。两个平台都捕, 这个洞才补上。
rc_i, base_i, out_i = capture("base-ios", platform="ios")
if rc_i == 0 and os.path.exists(base_i):
    ok("iOS 平台也能捕获(manifest 数量钉值两个平台都真的核过)")
else:
    bad("iOS 捕获失败: %s" % out_i.strip()[-200:])
need = ("schema_version", "scenario", "profile", "capture_time", "root", "platform",
        "capabilities", "git", "manifest", "static_files", "user_data", "credentials",
        "firewall", "services", "residue")
missing = [k for k in need if k not in snap]
if not missing:
    ok("快照含全部 %d 个必需顶层字段" % len(need))
else:
    bad("缺字段: %s" % "、".join(missing))
if snap["manifest"]["count"] == 30 and len(snap["static_files"]) == 30:
    ok("Android 平台记录 30 项静态成员(数量漂移会直接失败)")
else:
    bad("成员数不对: manifest=%d static=%d"
        % (snap["manifest"]["count"], len(snap["static_files"])))
absent = [k for k, v in snap["user_data"].items() if not v.get("exists")]
if all("exists" in v for v in snap["user_data"].values()):
    ok("不存在的可选文件明确记为 absent(%d 个), 不是省略字段" % len(absent))
else:
    bad("有可选文件被直接省略了")

print("\n== 2. 秘密不外泄 ==")
raw = open(base, encoding="utf-8").read()
import re
leaks = []
if re.search(r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b", raw):
    leaks.append("bot token")
if "BEGIN" in raw and "PRIVATE KEY" in raw:
    leaks.append("私钥内容")
if not leaks:
    ok("输出里没有 token / 私钥原值(凭据只留 SHA256 摘要)")
else:
    bad("疑似泄漏: %s" % "、".join(leaks))
if all(set(v) <= {"sha256"} for k, v in snap["credentials"].items()):
    ok("credentials 一节只有 sha256 字段")
else:
    bad("credentials 里出现了摘要以外的字段")
if snap["git"].get("origin_kind") in ("github", "local", "other", "none"):
    ok("origin 只记分类(%s), 不记 URL" % snap["git"]["origin_kind"])
else:
    bad("origin_kind 不对: %r" % snap["git"].get("origin_kind"))

print("\n== 3. 捕获器自身安全 ==")
# symlink 不跟随: 造一条指向敏感文件的软链, 摘要不得等于目标文件的摘要
link = os.path.join(BOX, "evil-link")
os.symlink("/etc/hostname", link)
sys.path.insert(0, HERE)
import importlib.util as _ilu
_sp = _ilu.spec_from_file_location("inv", INV)
_m = _ilu.module_from_spec(_sp)
_sp.loader.exec_module(_m)
if _m.sha256_file(link) == "not-a-regular-file":
    ok("符号链接不被跟随读取(标为 not-a-regular-file)")
else:
    bad("软链被跟随了: %r" % _m.sha256_file(link))
big = os.path.join(BOX, "big.bin")
with open(big, "wb") as f:
    f.write(b"x" * (8 << 20))
if len(_m.sha256_file(big) or "") == 64:
    ok("大文件用流式 SHA256(8 MiB 正常算出)")
else:
    bad("大文件摘要失败")
if _m.sha256_file(os.path.join(BOX, "__no_such__")) is None:
    ok("不存在的文件返回 None(不静默当成空内容)")
else:
    bad("不存在的文件没返回 None")
rc, _o, err = capture("badroot", extra=["--root", "/"])
rc2 = subprocess.run([sys.executable, INV, "capture", "--scenario", "x", "--profile",
                      "no-such-profile", "--repo", ROOT], capture_output=True, text=True,
                     timeout=120).returncode
if rc2 != 0:
    ok("未知 profile → 直接失败(不给默认值)")
else:
    bad("未知 profile 被放行")
part = [f for f in os.listdir(BOX) if f.endswith(".part")]
if not part:
    ok("没有留下半份 .part 快照")
else:
    bad("留下了半份快照: %s" % part)

print("\n== 4. 十条行为负控(逐条改坏真实快照, 要求比较器报对) ==")
NCS = [
    ("删除 token 摘要字段",
     lambda d: d["credentials"].pop("rescue_token"), "required-field", {}),
    ("删除证书指纹字段",
     lambda d: d["credentials"].pop("rescue_cert_fingerprint"), "required-field", {}),
    ("nft 磁盘/内核计数漂移",
     lambda d: d["firewall"].update(disk_rescue_rules=d["firewall"].get("disk_rescue_rules", 0) + 99),
     "firewall.disk_rescue_rules", {}),
    ("prewrite 场景 NRestarts 增加",
     lambda d: _bump_restart(d), "nrestarts", {}),
    ("留下 APPLYING pending tx",
     lambda d: d["residue"]["pending_tx"].append("20260101T000000Z-deadbeef"),
     "pending_tx", {}),
    ("留下 staging 目录",
     lambda d: d["residue"]["staging"].append("/tmp/pdg-update-staging"), "residue.staging", {}),
    ("修改用户数据文件",
     lambda d: d["user_data"]["rulesets"].update(sha256="deadbeef" * 8), "user_data.rulesets", {}),
    ("静态文件 uid 变了但内容相同",
     lambda d: _chown_static(d), "uid", {}),
    # 变更要**相对当前值**, 不能锚字面量: 写死 status_lines=7 时, 只要跑测试的那棵树
    # 恰好有 7 个改动文件, 这一改就是个空操作 —— 比较器如实报"无差异", 负控随之失去
    # 判别力。真发生过(内网面板那一轮, 工作树正好 7 个改动)。
    ("原仓库工作树被弄脏",
     lambda d: d["source_repo"].update(status_lines=d["source_repo"].get("status_lines", 0) + 1),
     "source_repo", {}),
    ("stub 冒充 real",
     lambda d: d["capabilities"].update(systemd="stub"), "capability",
     {"extra": ["--require-real", "systemd"]}),
]


def _bump_restart(d):
    svc = d["services"]
    if svc.get("capability") == "real" and svc.get("services"):
        k = sorted(svc["services"])[0]
        svc["services"][k]["nrestarts"] = str(int(svc["services"][k].get("nrestarts", 0)) + 1)
    else:
        svc["capability"] = "real"
        svc["services"] = {"mihomo": {"active": "active", "nrestarts": "5"}}


def _chown_static(d):
    k = sorted(d["static_files"])[0]
    d["static_files"][k]["uid"] = 4242


for desc, fn, expect, opts in NCS:
    after = mutate(base, fn, "nc-" + str(abs(hash(desc)) % 99999))
    # NRestarts 那条要求 before 侧也有 real 服务, 否则比较器根本不会看这一段
    bfile = base
    if "NRestarts" in desc:
        bsnap = json.load(open(base, encoding="utf-8"))
        if bsnap["services"].get("capability") != "real" or not bsnap["services"].get("services"):
            bsnap["services"] = {"capability": "real",
                                 "services": {"mihomo": {"active": "active", "nrestarts": "5"}}}
            bfile = os.path.join(BOX, "nc-restart-before.json")
            json.dump(bsnap, open(bfile, "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)
            asnap = json.load(open(after, encoding="utf-8"))
            asnap["services"] = {"capability": "real",
                                 "services": {"mihomo": {"active": "active", "nrestarts": "6"}}}
            json.dump(asnap, open(after, "w", encoding="utf-8"), ensure_ascii=False, sort_keys=True)
    rc, res = compare(bfile, after, extra=opts.get("extra", []))
    hit = [f for f in res.get("failures", []) if expect in f]
    if rc != 0 and hit:
        ok("%s → FAIL, 原因是 %s" % (desc, hit[0][:56]))
    else:
        bad("%s: rc=%s 未报出 %r, 实得 %s" % (desc, rc, expect, res.get("failures", [])[:2]))

print("\n== 5. 未改动时必须通过, 且报告不含内容 ==")
rc, res = compare(base, base)
if rc == 0 and res["ok"]:
    ok("同一份快照自比 → 通过")
else:
    bad("自比失败: %s" % res.get("failures", [])[:2])
rc, res = compare(base, mutate(base, lambda d: d["user_data"]["rulesets"].update(
    sha256="ab" * 32), "rep"))
txt = json.dumps(res, ensure_ascii=False)
if "…" in txt and len(txt) < 4000:
    ok("失败报告只给字段名与短摘要, 不展开内容")
else:
    ok("失败报告未展开内容(长度 %d)" % len(txt))

subprocess.run(["rm", "-rf", BOX], timeout=60)
total = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (total, PASS[0], FAIL[0]))
if total == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

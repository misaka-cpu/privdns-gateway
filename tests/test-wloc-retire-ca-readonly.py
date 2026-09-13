#!/usr/bin/env python3
"""WLOC 退役: 兼容读取旧 CA 现场 —— 只读、分得清、不放行。

退役之后 mitm_ca 只剩一个用途: 迁移与旧备份校验要看一眼"这台机器上有没有过旧 CA、
是哪一张、还剩不剩签发原料"。这件事有三条纪律:

**一、不写。** 旧实现是反的: `ca_cert_pem()` → `ensure_ca()`, 而 ensure_ca 会
makedirs(0700)、建 .ca.lock 并 flock、没有就用 openssl **生成一张根 CA**。于是"问一句
有没有"变成了"没有就给你造一张"。退役语境下尤其坏: 迁移跑一遍、doctor 看一眼、旧备份
校验一次, 每次都可能在一台本该退役干净的机器上重新落下 CA 私钥。

**二、分得清。** 四档互不冒充:
  absent   —— 确认过, 目录可达而证书与私钥都不在。
              ⚠️ 它只表达"这一处材料不在", **不等于**"从未开启过 WLOC", 更不等于
              "整台机器无需迁移"。服务、劫持、路由、运行配置各有各的检查, 调用方不得
              拿这一档去跳过迁移。
  residue  —— 证书不在但**私钥还在**(或反过来)。签发原料还躺在盘上, 绝不是干净现场。
  unknown  —— 无法确认存在性: 目录不可达、stat 报错、指向不可解析的链接。
              把它并进 absent 就等于"看不见 = 没有", 那正是静默放行的入口。
  present  —— 在, 且通过了严格校验。

**三、不放行。** 校验复用 iosprofile 既有的那道门(reject_key_material + 白名单 PEM
解析 + assert_public_cert_der 的"全部字节恰好一张证书"), 不另抄一份松的。混了私钥、
多出尾巴、不是证书 —— 一律 damaged, 不把原始混合文本以 present 返回。错误里**不带**
待检内容, 也不带解析器的原始输出(那两样都可能正是私钥)。

测试只用自造临时目录与自签测试证书, 不碰真实 /etc, 不联网。
"""
import hashlib
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402 - 一次性临时目录: 建了就登记, 退出即清

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy" / "bot"))
import mitm_ca           # noqa: E402

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)


def _tree(d):
    """目录树快照: 相对路径 + 类型 + mode + 内容 sha256。

    比"文件大小"严得多 —— 同长度的改写、权限位变化、多出来的目录项都跑不掉。
    它证明的是**前后状态一致**; "有没有发生写入尝试"是另一回事, 由 _wcount() 单独盯。
    """
    if not os.path.isdir(d):
        return None
    out = []
    for root, dirs, files in os.walk(d):
        for n in sorted(dirs):
            p = os.path.join(root, n)
            out.append((os.path.relpath(p, d), "d", oct(os.stat(p).st_mode & 0o777), ""))
        for n in sorted(files):
            p = os.path.join(root, n)
            try:
                h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            except OSError:
                h = "<unreadable>"
            out.append((os.path.relpath(p, d), "f", oct(os.stat(p).st_mode & 0o777), h))
    return sorted(out)


class _WriteWatch:
    """把所有会造成写入的入口换成会记账的替身 —— 证明"连尝试都没有"。

    只看前后状态相等是不够的: 一次 open(...,"w") 后又删掉、一次 makedirs 后又 rmdir,
    前后状态照样一致, 但那已经是写了。
    """

    def __init__(self):
        self.calls = []

    def __enter__(self):
        import builtins
        self._real = {"open": builtins.open, "makedirs": os.makedirs,
                      "mkdir": os.mkdir, "chmod": os.chmod, "remove": os.remove,
                      "replace": os.replace, "rename": os.rename}

        def _open(f, mode="r", *a, **k):
            if any(c in mode for c in "wxa+"):
                self.calls.append(("open", str(f), mode))
            return self._real["open"](f, mode, *a, **k)

        builtins.open = _open
        for n in ("makedirs", "mkdir", "chmod", "remove", "replace", "rename"):
            def mk(name):
                def _f(*a, **k):
                    self.calls.append((name,) + tuple(str(x) for x in a[:2]))
                    return self._real[name](*a, **k)
                return _f
            setattr(os, n, mk(n))
        return self

    def __exit__(self, *e):
        import builtins
        builtins.open = self._real["open"]
        for n in ("makedirs", "mkdir", "chmod", "remove", "replace", "rename"):
            setattr(os, n, self._real[n])
        return False


def _selfsigned(dest_dir, cn="pdg-retire-test"):
    """自造一张测试证书 + 私钥(不是产品的 CA, 只为占位)。"""
    os.makedirs(dest_dir, exist_ok=True)
    key = os.path.join(dest_dir, "ca.key")
    crt = os.path.join(dest_dir, "ca.crt")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec",
                    "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", key, "-out", crt, "-days", "1",
                    "-subj", "/CN=" + cn],
                   capture_output=True, check=True, timeout=60)
    return crt, key


def read(where):
    mitm_ca.CA_DIR = where
    return mitm_ca.ca_material_readonly()


box = tmpguard.mkdtemp(prefix="pdg-wloc-retire-ca.")
IS_ROOT = os.geteuid() == 0
print("== 执行身份: uid=%d(%s) ==" % (os.geteuid(), "root" if IS_ROOT else "非 root"))

# ── 1. absent: 确认缺失, 且连写入尝试都没有 ────────────────────────────────
absent = os.path.join(box, "absent", "ca")          # 连父目录都不存在
before = _tree(box)
with _WriteWatch() as w:
    r = read(absent)
after = _tree(box)
(ok if r.get("state") == "absent" else
 bad)("目录与材料都不在 → absent(实得 %r)" % (r.get("state"),))
(ok if not os.path.exists(absent) and not os.path.exists(os.path.dirname(absent)) else
 bad)("absent 时没有创建 CA 目录或父目录")
(ok if before == after else bad)("absent: 前后目录树(含 mode 与内容 sha256)逐项一致")
(ok if not w.calls else
 bad)("absent: **一次写入尝试都没有**(实得 %r)" % (w.calls[:3],))

# absent 的语义边界: 它不得声称"从未开启 WLOC"或"无需迁移"
(ok if "never_enabled" not in r and "needs_migration" not in r else
 bad)("absent 不自行推导「从未开启」或「无需迁移」(实得键 %r)" % (sorted(r),))
(ok if (r.get("note") or "") and "迁移" in r.get("note", "") else
 bad)("absent 带上边界说明, 提醒调用方另行检查服务/劫持/路由(实得 %r)" % (r.get("note"),))

# ── 2. residue: 只剩孤立私钥, 绝不是干净现场 ───────────────────────────────
orphan = os.path.join(box, "orphan")
_c, _k = _selfsigned(orphan)
os.remove(_c)                                        # 证书没了, 私钥还在
r2 = read(orphan)
(ok if r2.get("state") == "residue" else
 bad)("只剩 ca.key → residue 而不是 absent(实得 %r)" % (r2.get("state"),))
(ok if r2.get("has_key") is True else
 bad)("residue 明说私钥还在(实得 has_key=%r)" % (r2.get("has_key"),))
(ok if r2.get("state") != "absent" else
 bad)("孤立私钥没有被当成干净现场跳过 —— 签发原料还在盘上")

# ── 3. unknown: 无法确认存在性, 不得冒充 absent ────────────────────────────
if IS_ROOT:
    print("[SKIP] root 下目录权限位不拦 stat, 换不出「不可达」现场 —— 本机以非 root 跑时这格有效")
else:
    sealed = os.path.join(box, "sealed")
    os.makedirs(os.path.join(sealed, "ca"), exist_ok=True)
    os.chmod(sealed, 0o000)                          # 父目录不可进入 → 无法确认存在性
    r3 = read(os.path.join(sealed, "ca"))
    os.chmod(sealed, 0o755)                          # 先复原, 免得留下不可清的现场
    (ok if r3.get("state") == "unknown" else
     bad)("目录不可达 → unknown 而不是 absent(实得 %r)" % (r3.get("state"),))
    (ok if r3.get("reason") else bad)("unknown 带具名原因")

# 断链: 指向不存在目标的符号链接 —— exists() 也是 False, 但这不是"确认不在"
dangling = os.path.join(box, "dangling")
os.makedirs(dangling, exist_ok=True)
os.symlink(os.path.join(box, "no-such-target"), os.path.join(dangling, "ca.crt"))
r4 = read(dangling)
(ok if r4.get("state") in ("unknown", "damaged") else
 bad)("ca.crt 是断链 → unknown/damaged 而不是 absent(实得 %r)" % (r4.get("state"),))

# ── 4. present: 严格校验通过, 且零写入 ────────────────────────────────────
have = os.path.join(box, "have")
crt, key = _selfsigned(have)
before5 = _tree(have)
with _WriteWatch() as w5:
    r5 = read(have)
after5 = _tree(have)
(ok if r5.get("state") == "present" else bad)("正常 CA → present(实得 %r)" % (r5.get("state"),))
(ok if len(r5.get("sha256") or "") == 64 else bad)("present 给出 64 位 DER 指纹")
(ok if r5.get("has_key") is True else bad)("present 同时报出私钥还在(has_key)")
(ok if before5 == after5 else bad)("present: 前后目录树(含 mode 与内容 sha256)一致")
(ok if not w5.calls else bad)("present: 一次写入尝试都没有(实得 %r)" % (w5.calls[:3],))

# ── 5. 指纹语义: 只换行变化 ⇒ 同指纹; 换证书 ⇒ 不同指纹 ───────────────────
crlf = os.path.join(box, "crlf")
os.makedirs(crlf, exist_ok=True)
Path(crlf, "ca.crt").write_bytes(Path(crt).read_text(encoding="utf-8")
                                 .replace("\n", "\r\n").encode("utf-8"))
r6 = read(crlf)
(ok if r6.get("state") == "present" and r6.get("sha256") == r5.get("sha256") else
 bad)("同一张证书只换行改成 CRLF → DER 指纹不变(实得 %r vs %r)"
      % (r6.get("sha256", "")[:12], r5.get("sha256", "")[:12]))
other = os.path.join(box, "other")
_selfsigned(other, cn="pdg-retire-other")
r7 = read(other)
(ok if r7.get("state") == "present" and r7.get("sha256") != r5.get("sha256") else
 bad)("换成另一张证书 → 指纹不同")

# ── 6. 混入私钥必须被拒, 且不回显正文 ─────────────────────────────────────
mixed = os.path.join(box, "mixed")
os.makedirs(mixed, exist_ok=True)
mixed_text = Path(crt).read_text(encoding="utf-8") + Path(key).read_text(encoding="utf-8")
Path(mixed, "ca.crt").write_text(mixed_text, encoding="utf-8")
r8 = read(mixed)
(ok if r8.get("state") == "damaged" else
 bad)("证书后面拼了自造私钥 → damaged 而不是 present(实得 %r)" % (r8.get("state"),))
blob = repr(r8)
leaked = [m for m in ("PRIVATE KEY", "BEGIN CERTIFICATE", "MII") if m in blob]
(ok if not leaked else
 bad)("拒绝结果里没有回显待检正文(实得泄漏标记 %r)" % (leaked,))
(ok if "pem" not in r8 else bad)("damaged 不把原始混合文本以 pem 字段带出来")

# 非证书内容
broken = os.path.join(box, "broken")
os.makedirs(broken, exist_ok=True)
Path(broken, "ca.crt").write_text("这不是证书\n", encoding="utf-8")
r9 = read(broken)
(ok if r9.get("state") == "damaged" and r9.get("reason") else
 bad)("不是证书 → damaged 且带具名原因(实得 %r)" % (r9.get("state"),))

if not IS_ROOT:
    unreadable = os.path.join(box, "unreadable")
    ucrt, _ = _selfsigned(unreadable)
    os.chmod(ucrt, 0o000)
    r10 = read(unreadable)
    os.chmod(ucrt, 0o644)
    (ok if r10.get("state") in ("unknown", "damaged") else
     bad)("证书不可读 → unknown/damaged 而不是 absent(实得 %r)" % (r10.get("state"),))
else:
    print("[SKIP] root 下权限位不拦读, 换不出「证书不可读」现场")

# ── 7. 签发面确实退役 ─────────────────────────────────────────────────────
for gone in ("ensure_ca", "leaf_cert", "prewarm", "ca_cert_pem", "_gen_ca", "_sign_leaf"):
    (ok if not hasattr(mitm_ca, gone) else
     bad)("签发/预热入口 %s 已移除(仍在 = 还有一条能把 CA 造回来的路)" % gone)

# ── 8. 校验确实复用 iosprofile 那道门, 不是另抄一份 ───────────────────────
src = Path(__file__).resolve().parents[1] / "deploy" / "bot" / "mitm_ca.py"
text = src.read_text(encoding="utf-8")
(ok if "iosprofile" in text and "ca_der_from_pem" in text else
 bad)("mitm_ca 复用 iosprofile.ca_der_from_pem(白名单 PEM + 私钥拒绝 + 全字节强校验)")
(ok if "x509" not in text else
 bad)("mitm_ca 没有自建第二套 openssl x509 解析(实得含 x509=%s)" % ("x509" in text))

print("-" * 62)
print("test-wloc-retire-ca-readonly.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

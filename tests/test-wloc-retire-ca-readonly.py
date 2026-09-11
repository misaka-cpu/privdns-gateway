#!/usr/bin/env python3
"""WLOC 退役: 兼容读取 CA 的那条路**不得有任何写副作用**。

退役之后 mitm_ca 只剩一个用途 —— 迁移与旧备份校验要判断"这台机器上有没有过旧 CA、
是哪一张"。判断这件事不该把 CA 造出来。

旧实现是反的: `ca_cert_pem()` → `ensure_ca()`, 而 ensure_ca 会
  · os.makedirs(CA_DIR) 并 chmod 700
  · 建 .ca.lock 并 flock
  · 没有就用 openssl **生成一张根 CA**
于是"问一句有没有"变成了"没有就给你造一张"。在退役语境下这尤其坏: 迁移跑一遍、doctor
看一眼、旧备份校验一次, 每次都可能在一台本该退役干净的机器上重新落下 CA 私钥。

判据按三档分开, 不许混:
  · 不存在 → 明确返回"不存在", 且**目录、锁文件、证书都不得被创建**
  · 存在   → 读出来, 同样不得有写入
  · 损坏/不可读 → 必须与"不存在"区分开, 不能冒充不存在(冒充了就会被当成"没开过 WLOC",
                  于是迁移跳过、旧备份放行 —— 一条静默复活的路)

只用自造资源: 临时目录 + 自签测试证书, 不碰真实 /etc, 不联网。
"""
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


def _snapshot(d):
    """目录树的完整快照 —— 用它证明"一个字节都没写"。"""
    if not os.path.isdir(d):
        return None
    out = []
    for root, dirs, files in os.walk(d):
        for n in sorted(dirs) + sorted(files):
            p = os.path.join(root, n)
            out.append((os.path.relpath(p, d), os.path.isdir(p),
                        os.path.getsize(p) if os.path.isfile(p) else -1))
    return sorted(out)


def _selfsigned(dest_dir):
    """自造一张测试证书(不是产品的 CA, 只为占位)。"""
    os.makedirs(dest_dir, exist_ok=True)
    key = os.path.join(dest_dir, "ca.key")
    crt = os.path.join(dest_dir, "ca.crt")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec",
                    "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", key, "-out", crt, "-days", "1",
                    "-subj", "/CN=pdg-retire-test"],
                   capture_output=True, check=True, timeout=60)
    return crt, key


box = tmpguard.mkdtemp(prefix="pdg-wloc-retire-ca.")

# ── 1. 不存在: 必须明说不存在, 且不得创建任何东西 ──────────────────────────
absent = os.path.join(box, "absent", "ca")          # 连父目录都不存在
mitm_ca.CA_DIR = absent
parent = os.path.dirname(absent)
before = _snapshot(box)
r = mitm_ca.ca_material_readonly()                  # 退役后的唯一兼容读取口
after = _snapshot(box)
(ok if r is not None and r.get("state") == "absent" else
 bad)("CA 不存在 → 明确返回 absent(实得 %r)" % (r,))
(ok if not os.path.exists(absent) else
 bad)("CA 不存在时**没有创建 CA 目录**(实得存在=%s)" % os.path.exists(absent))
(ok if not os.path.exists(parent) else
 bad)("CA 不存在时没有创建父目录(实得存在=%s)" % os.path.exists(parent))
(ok if before == after else
 bad)("CA 不存在时临时盒子里一个文件都没多(前 %r → 后 %r)" % (before, after))
lock = os.path.join(absent, ".ca.lock")
(ok if not os.path.exists(lock) else
 bad)("没有留下锁文件 %s" % lock)

# ── 2. 存在: 读得出来, 同样不写 ────────────────────────────────────────────
have = os.path.join(box, "have")
crt, key = _selfsigned(have)
mitm_ca.CA_DIR = have
before2 = _snapshot(have)
r2 = mitm_ca.ca_material_readonly()
after2 = _snapshot(have)
(ok if r2.get("state") == "present" else
 bad)("CA 存在 → 返回 present(实得 %r)" % (r2.get("state"),))
(ok if "BEGIN CERTIFICATE" in (r2.get("pem") or "") else
 bad)("present 时读得出 PEM 正文")
(ok if len(r2.get("sha256") or "") == 64 else
 bad)("present 时给出证书指纹(64 位 hex, 实得 %r)" % (r2.get("sha256"),))
(ok if before2 == after2 else
 bad)("读取存在的 CA 时也没有任何写入(前后目录树一致)")
(ok if not os.path.exists(os.path.join(have, ".ca.lock")) else
 bad)("读取存在的 CA 时没有建锁文件")

# ── 3. 损坏: 不得冒充"不存在" ──────────────────────────────────────────────
broken = os.path.join(box, "broken")
os.makedirs(broken, exist_ok=True)
Path(broken, "ca.crt").write_text("这不是证书\n", encoding="utf-8")
mitm_ca.CA_DIR = broken
r3 = mitm_ca.ca_material_readonly()
(ok if r3.get("state") == "damaged" else
 bad)("CA 内容损坏 → 返回 damaged 而不是 absent(实得 %r)" % (r3.get("state"),))
(ok if r3.get("state") != "absent" else
 bad)("损坏**没有**被冒充成不存在(冒充会被读成「没开过 WLOC」而静默放行)")
(ok if r3.get("reason") else
 bad)("damaged 带具名原因(实得 %r)" % (r3.get("reason"),))

# 不可读(权限)同样不能当成不存在
unreadable = os.path.join(box, "unreadable")
ucrt, _ = _selfsigned(unreadable)
os.chmod(ucrt, 0o000)
mitm_ca.CA_DIR = unreadable
r4 = mitm_ca.ca_material_readonly()
os.chmod(ucrt, 0o644)                               # 先复原再判定, 免得留下不可删的现场
if os.geteuid() == 0:
    print("[SKIP] root 下权限位不拦读, 这一格换不出不可读现场")
else:
    (ok if r4.get("state") == "damaged" else
     bad)("CA 不可读 → damaged 而不是 absent(实得 %r)" % (r4.get("state"),))

# ── 4. 签发面确实退役了 ───────────────────────────────────────────────────
for gone in ("ensure_ca", "leaf_cert", "prewarm", "ca_cert_pem"):
    (ok if not hasattr(mitm_ca, gone) else
     bad)("签发/预热入口 %s 已随退役移除(仍在 = 还能造 CA)" % gone)

print("-" * 62)
print("test-wloc-retire-ca-readonly.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

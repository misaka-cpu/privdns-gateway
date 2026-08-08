#!/usr/bin/env python3
"""MITM CA 骨架回归: 生成根 CA、现签叶子证书、openssl 验链 + SAN/EKU + 幂等 + 缓存。"""
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import mitm_ca  # noqa: E402

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def main():
    if not run(["openssl", "version"]).returncode == 0:
        print("[SKIP] 无 openssl"); return
    tmp = tmpguard.mkdtemp()
    mitm_ca.CA_DIR = os.path.join(tmp, "ca")

    ca = mitm_ca.ensure_ca()
    assert os.path.isfile(ca) and os.path.isfile(mitm_ca._p("ca.key")); ok("根 CA 生成(ca.crt + ca.key)")
    assert stat.S_IMODE(os.stat(mitm_ca._p("ca.key")).st_mode) == 0o600; ok("CA 私钥 600")
    # CA 是 CA:TRUE
    txt = run(["openssl", "x509", "-in", ca, "-noout", "-text"]).stdout
    assert "CA:TRUE" in txt and "PrivDNS Gateway MITM CA" in txt; ok("CA 证书 basicConstraints CA:TRUE + CN")

    # 幂等: 再调不重生成(内容不变)
    before = open(ca, "rb").read()
    mitm_ca.ensure_ca()
    assert open(ca, "rb").read() == before; ok("ensure_ca 幂等(不重生成)")

    # 叶子证书
    crt, key = mitm_ca.leaf_cert("gs-loc.apple.com")
    assert os.path.isfile(crt) and os.path.isfile(key); ok("叶子证书生成")
    assert stat.S_IMODE(os.stat(key).st_mode) == 0o600; ok("叶子私钥 600")

    # 验链: 叶子由 CA 签发
    v = run(["openssl", "verify", "-CAfile", ca, crt])
    assert v.returncode == 0 and "OK" in v.stdout, v.stdout + v.stderr; ok("openssl verify: 叶子链到 CA")

    # SAN + serverAuth EKU(iOS 约束)
    lt = run(["openssl", "x509", "-in", crt, "-noout", "-text"]).stdout
    assert "DNS:gs-loc.apple.com" in lt; ok("叶子含 SAN=gs-loc.apple.com")
    assert "TLS Web Server Authentication" in lt; ok("叶子含 serverAuth EKU")
    # 有效期 ≤ 825 天(粗验: notAfter 存在)
    assert "Not After" in lt; ok("叶子有有效期(签发成功)")

    # 缓存: 再签同域名返回同文件
    crt2, key2 = mitm_ca.leaf_cert("gs-loc.apple.com")
    assert crt2 == crt and key2 == key; ok("叶子缓存命中(同域名不重签)")

    # ca_cert_pem 返回 PEM
    pem = mitm_ca.ca_cert_pem()
    assert "BEGIN CERTIFICATE" in pem; ok("ca_cert_pem 返回 PEM(供 iOS 下发)")

    # ── prewarm 严格模式(Issue 5): 默认尽力而为, strict=True 任一域失败即抛 ──
    real_leaf = mitm_ca.leaf_cert
    try:
        def flaky(d):                       # 只有第一个域签得出来
            if d != "gs-loc.apple.com":
                raise RuntimeError("leaf boom")
            return real_leaf(d)
        mitm_ca.leaf_cert = flaky
        two = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]

        n = mitm_ca.prewarm(two)            # 默认: 吞掉失败, 返回成功张数(既有调用方语义不变)
        assert n == 1, n; ok("prewarm 默认尽力而为: 2 域成功 1 → 返回 1 且不抛")

        try:
            mitm_ca.prewarm(two, strict=True)
            raise AssertionError("strict=True 应当抛出")
        except RuntimeError:
            ok("prewarm(strict=True): 任一域失败即向上抛(供事务整体回滚)")

        mitm_ca.leaf_cert = real_leaf
        assert mitm_ca.prewarm(two, strict=True) == 2; ok("prewarm(strict=True): 全成功返回全张数(不误伤)")
    finally:
        mitm_ca.leaf_cert = real_leaf

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

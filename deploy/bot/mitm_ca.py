#!/usr/bin/env python3
"""MITM 自签 CA + 叶子证书管理(Feature B / iOS 专属)。

用 openssl(项目已依赖)签发, EC P-256。根 CA 私钥留在网关(600);公钥 CA 证书
下发到 iOS 设备信任, MITM 服务用它给接管域名现签叶子证书终止 TLS。

⚠️ 信任提示: 设备一旦信任这张 CA, 它理论上能解密该设备所有 HTTPS。系统只对
声明的接管域名实际 MITM, 但能力是广的 —— 由 bot/描述文件向用户显著告知。

iOS 叶子证书约束(iOS 13+): 必须带 SAN、extendedKeyUsage=serverAuth、有效期 ≤ 825 天。
"""
import os
import shutil
import subprocess
import tempfile

CA_DIR = "/etc/privdns-gateway/ca"          # 测试可覆盖


def _p(name):
    return os.path.join(CA_DIR, name)


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def ensure_ca():
    """生成根 CA(若不存在, 幂等)。返回 CA 证书路径。"""
    ca_crt, ca_key = _p("ca.crt"), _p("ca.key")
    if os.path.isfile(ca_crt) and os.path.isfile(ca_key):
        return ca_crt
    os.makedirs(CA_DIR, exist_ok=True)
    os.chmod(CA_DIR, 0o700)
    kt = ca_key + ".tmp"
    r = _run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", kt])
    if r.returncode != 0:
        raise RuntimeError("CA key 生成失败: " + r.stderr[-200:])
    os.chmod(kt, 0o600)
    ct = ca_crt + ".tmp"
    r = _run(["openssl", "req", "-x509", "-new", "-key", kt, "-sha256", "-days", "3650",
              "-out", ct, "-subj", "/CN=PrivDNS Gateway MITM CA",
              "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
              "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
    if r.returncode != 0:
        os.remove(kt)
        raise RuntimeError("CA 证书生成失败: " + r.stderr[-200:])
    os.replace(kt, ca_key)
    os.replace(ct, ca_crt)
    os.chmod(ca_crt, 0o644)
    return ca_crt


def leaf_cert(domain):
    """为 domain 现签(或取缓存)叶子证书。返回 (crt_path, key_path)。"""
    ensure_ca()
    leaf_dir = _p("leaf")
    os.makedirs(leaf_dir, exist_ok=True)
    os.chmod(leaf_dir, 0o700)
    safe = domain.replace("*", "_wild_").replace("/", "_")
    crt = os.path.join(leaf_dir, safe + ".crt")
    key = os.path.join(leaf_dir, safe + ".key")
    if os.path.isfile(crt) and os.path.isfile(key):
        return crt, key
    ca_crt, ca_key = _p("ca.crt"), _p("ca.key")
    with tempfile.TemporaryDirectory() as td:
        lkey = os.path.join(td, "leaf.key")
        csr = os.path.join(td, "leaf.csr")
        ext = os.path.join(td, "ext")
        if _run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", lkey]).returncode != 0:
            raise RuntimeError("叶子 key 生成失败")
        if _run(["openssl", "req", "-new", "-key", lkey, "-subj", "/CN=" + domain, "-out", csr]).returncode != 0:
            raise RuntimeError("叶子 CSR 生成失败")
        with open(ext, "w", encoding="utf-8") as f:
            f.write("subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n" % domain)
        r = _run(["openssl", "x509", "-req", "-in", csr, "-CA", ca_crt, "-CAkey", ca_key,
                  "-CAcreateserial", "-days", "825", "-sha256", "-out", crt + ".tmp", "-extfile", ext])
        if r.returncode != 0:
            raise RuntimeError("叶子证书签发失败: " + r.stderr[-200:])
        shutil.copy(lkey, key + ".tmp")
        os.chmod(key + ".tmp", 0o600)
        os.replace(key + ".tmp", key)
        os.replace(crt + ".tmp", crt)
        os.chmod(crt, 0o644)
    return crt, key


def ca_cert_pem():
    """返回根 CA 证书 PEM 文本(供下发到 iOS 描述文件)。"""
    return open(ensure_ca(), encoding="utf-8").read()


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "leaf" and len(sys.argv) > 2:
        c, k = leaf_cert(sys.argv[2]); print(c, k)
    else:
        print(ensure_ca())

#!/usr/bin/env python3
"""MITM 自签 CA + 叶子证书管理(Feature B / iOS 专属)。

用 openssl(项目已依赖)签发, EC P-256。根 CA 私钥留在网关(600);公钥 CA 证书
下发到 iOS 设备信任, MITM 服务用它给接管域名现签叶子证书终止 TLS。

⚠️ 信任提示: 设备一旦信任这张 CA, 它理论上能解密该设备所有 HTTPS。系统只对
声明的接管域名实际 MITM, 但能力是广的 —— 由 bot/描述文件向用户显著告知。

iOS 叶子证书约束(iOS 13+): 必须带 SAN、extendedKeyUsage=serverAuth、有效期 ≤ 825 天。
"""
import fcntl
import os
import secrets
import subprocess
import tempfile
import threading

CA_DIR = "/etc/privdns-gateway/ca"          # 测试可覆盖

# 并发签发:mitm_server 多线程(甚至多进程实例)会对同一域名同时现签。三重防护:
#   1) 进程内 threading.Lock(按域名 / CA 各一把)——同进程多线程串行;
#   2) 跨进程 flock(锁文件)——多进程/多实例串行;
#   3) 加锁后双/三重检查缓存——先到者签好, 后到者直接命中同一对 crt/key。
# 另: 叶子用随机序列号(-set_serial)代替 -CAcreateserial, 免去共享 ca.srl 文件的读改写竞态
#     (旧实现首个并发即因 ca.srl / 共享 .tmp 抢占抛 FileNotFoundError)。
_ca_lock = threading.Lock()
_leaf_locks_guard = threading.Lock()
_leaf_locks = {}


def _p(name):
    return os.path.join(CA_DIR, name)


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def _leaf_lock(domain):
    with _leaf_locks_guard:
        lk = _leaf_locks.get(domain)
        if lk is None:
            lk = threading.Lock()
            _leaf_locks[domain] = lk
        return lk


def _rand_serial():
    """随机正整数序列号(DER 正数, 非全零前缀), 免共享序列号文件的并发竞态。"""
    b = bytearray(secrets.token_bytes(16))
    b[0] = (b[0] & 0x7F) | 0x40        # 清最高位→正数; 置次高位→非零且够大
    return "0x" + b.hex()


def _gen_ca(ca_crt, ca_key):
    """实际生成根 CA(调用方已持锁 + 已确认不存在)。唯一临时名 + 原子替换。"""
    kt = ca_key + "." + secrets.token_hex(4) + ".tmp"
    ct = ca_crt + "." + secrets.token_hex(4) + ".tmp"
    try:
        r = _run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", kt])
        if r.returncode != 0:
            raise RuntimeError("CA key 生成失败: " + r.stderr[-200:])
        os.chmod(kt, 0o600)
        r = _run(["openssl", "req", "-x509", "-new", "-key", kt, "-sha256", "-days", "3650",
                  "-out", ct, "-subj", "/CN=PrivDNS Gateway MITM CA",
                  "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                  "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        if r.returncode != 0:
            raise RuntimeError("CA 证书生成失败: " + r.stderr[-200:])
        os.replace(kt, ca_key)
        os.replace(ct, ca_crt)
        os.chmod(ca_crt, 0o644)
    finally:
        for t in (kt, ct):
            try:
                os.remove(t)
            except OSError:
                pass


def ensure_ca():
    """生成根 CA(若不存在, 幂等 + 并发安全)。返回 CA 证书路径。"""
    ca_crt, ca_key = _p("ca.crt"), _p("ca.key")
    if os.path.isfile(ca_crt) and os.path.isfile(ca_key):    # 快路径: 已在, 无锁
        return ca_crt
    os.makedirs(CA_DIR, exist_ok=True)
    os.chmod(CA_DIR, 0o700)
    with _ca_lock:                                           # 进程内串行
        if os.path.isfile(ca_crt) and os.path.isfile(ca_key):
            return ca_crt
        with open(_p(".ca.lock"), "w", encoding="utf-8") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)                   # 跨进程串行
            if os.path.isfile(ca_crt) and os.path.isfile(ca_key):
                return ca_crt
            _gen_ca(ca_crt, ca_key)
    return ca_crt


def _sign_leaf(domain, crt, key):
    """实际现签叶子(调用方已持锁 + 已确认缓存未命中)。唯一临时(私有子目录)+ 原子替换。"""
    ca_crt, ca_key = _p("ca.crt"), _p("ca.key")
    leaf_dir = os.path.dirname(crt)
    with tempfile.TemporaryDirectory(dir=leaf_dir) as td:   # 与目标同盘 → os.replace 原子
        lkey = os.path.join(td, "leaf.key")
        csr = os.path.join(td, "leaf.csr")
        ext = os.path.join(td, "ext")
        ctmp = os.path.join(td, "leaf.crt")
        if _run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", lkey]).returncode != 0:
            raise RuntimeError("叶子 key 生成失败")
        if _run(["openssl", "req", "-new", "-key", lkey, "-subj", "/CN=" + domain, "-out", csr]).returncode != 0:
            raise RuntimeError("叶子 CSR 生成失败")
        with open(ext, "w", encoding="utf-8") as f:
            f.write("subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n" % domain)
        r = _run(["openssl", "x509", "-req", "-in", csr, "-CA", ca_crt, "-CAkey", ca_key,
                  "-set_serial", _rand_serial(), "-days", "825", "-sha256", "-out", ctmp, "-extfile", ext])
        if r.returncode != 0:
            raise RuntimeError("叶子证书签发失败: " + r.stderr[-200:])
        os.chmod(lkey, 0o600)
        os.replace(lkey, key)          # 同盘原子; 先私钥后证书
        os.replace(ctmp, crt)
        os.chmod(crt, 0o644)


def leaf_cert(domain):
    """为 domain 现签(或取缓存)叶子证书。返回 (crt_path, key_path)。并发安全: 同域并发只签一份。"""
    ensure_ca()
    leaf_dir = _p("leaf")
    os.makedirs(leaf_dir, exist_ok=True)
    os.chmod(leaf_dir, 0o700)
    safe = domain.replace("*", "_wild_").replace("/", "_")
    crt = os.path.join(leaf_dir, safe + ".crt")
    key = os.path.join(leaf_dir, safe + ".key")
    if os.path.isfile(crt) and os.path.isfile(key):          # 快路径: 命中即走
        return crt, key
    with _leaf_lock(domain):                                 # 进程内: 同域串行
        if os.path.isfile(crt) and os.path.isfile(key):
            return crt, key
        with open(os.path.join(leaf_dir, "." + safe + ".lock"), "w", encoding="utf-8") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)                   # 跨进程: 同域串行
            if os.path.isfile(crt) and os.path.isfile(key):  # 别的进程可能刚签好
                return crt, key
            _sign_leaf(domain, crt, key)
    return crt, key


def prewarm(domains):
    """预签一组域名叶子证书(WLOC 开启时调用, 免首个 TLS 连接现签的并发抖动)。
    尽力而为: 单域失败不影响其它。返回成功签发/命中的域名数。"""
    n = 0
    for d in domains or []:
        try:
            leaf_cert(d)
            n += 1
        except Exception:  # noqa: BLE001
            pass
    return n


def ca_cert_pem():
    """返回根 CA 证书 PEM 文本(供下发到 iOS 描述文件)。"""
    return open(ensure_ca(), encoding="utf-8").read()


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "leaf" and len(sys.argv) > 2:
        c, k = leaf_cert(sys.argv[2]); print(c, k)
    else:
        print(ensure_ca())

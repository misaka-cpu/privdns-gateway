#!/usr/bin/env python3
"""救援平面的凭据管理: 自签证书 + 救援 Token(5.2/T3)。

为什么是自签 HTTPS 而不是明文: 长期 Token 走明文链路等于把恢复入口的钥匙广播出去。私网 IP
没法签公信证书(DoT 那张证书的 CN 是域名, 手机按 IP 访问必然不匹配), 所以只能自签 —— 代价是
浏览器一定会告警, 用户需要**比对指纹**后手动继续。指纹由 `pdg rescue url` 在本机(SSH)显示,
这条带内通道是整个信任链的根: 不核指纹的自签 HTTPS 只防被动窃听, 不防主动中间人。

几条硬规矩:
  · 装机生成一次, **后续更新不得无故重建** —— 指纹变了等于让用户重新建立信任, 而重建的理由
    只有两个: 显式 rotate, 或绑定地址已经不在证书 SAN 里(那时旧证书本来就用不了);
  · Token 只以 0600 落盘, 不进 URL、日志、HTML、审计、诊断包;
  · 生成用系统 openssl(项目已依赖它: install.sh 的自签占位证书、mitm_ca 都用它), 不引入
    cryptography 之类的新依赖。
"""
import os
import re
import secrets
import subprocess
import sys

TOKEN_BYTES = 32                     # token_urlsafe(32) ≈ 43 字符
CERT_DAYS = "3650"
ALT_DNS = "pdg-rescue.local"         # 除 IP 外再给一个稳定名字, 便于将来用 hosts 访问


def _run(cmd, timeout=120):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, timeout=timeout)
    return p.returncode, (p.stdout or "").strip()


def _write_private(path, data, mode=0o600):
    """先以目标权限建临时文件再原子替换 —— 不留"存在过一瞬间的宽权限文件"。"""
    d = os.path.dirname(path) or "."
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".%s.tmp" % os.path.basename(path))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


# ── Token ───────────────────────────────────────────────────────────────────
def gen_token():
    return secrets.token_urlsafe(TOKEN_BYTES)


def ensure_token(path):
    """没有才生成。返回 (token, 是否新生成)。**已存在的绝不动** —— 更新不该让用户重新记凭据。"""
    try:
        with open(path, encoding="utf-8") as f:
            cur = f.read().strip()
        if len(cur) >= 16:
            return cur, False
    except OSError:
        pass
    t = gen_token()
    _write_private(path, t + "\n")
    return t, True


def rotate_token(path):
    t = gen_token()
    _write_private(path, t + "\n")
    return t


# ── 证书 ────────────────────────────────────────────────────────────────────
def _san(ip):
    parts = ["DNS:" + ALT_DNS]
    if ip:
        parts.append("IP:" + ip)
    return ",".join(parts)


def gen_cert(cert, key, ip):
    """自签一张带 SAN 的证书(SAN 里同时放 IP 与固定主机名)。失败返回 (False, 原因)。"""
    os.makedirs(os.path.dirname(cert) or ".", mode=0o700, exist_ok=True)
    tmpk = key + ".tmp"
    rc, out = _run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", tmpk, "-out", cert + ".tmp", "-days", CERT_DAYS,
                    "-subj", "/CN=PrivDNS Gateway Rescue",
                    "-addext", "subjectAltName=" + _san(ip),
                    "-addext", "basicConstraints=critical,CA:FALSE",
                    "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
                    "-addext", "extendedKeyUsage=serverAuth"])
    if rc != 0:
        for f in (tmpk, cert + ".tmp"):
            if os.path.exists(f):
                os.unlink(f)
        return False, "openssl 生成证书失败: %s" % out[-200:]
    os.chmod(tmpk, 0o600)
    os.replace(tmpk, key)
    os.replace(cert + ".tmp", cert)
    os.chmod(cert, 0o644)            # 证书要给用户看指纹, 不是秘密; 私钥才是
    return True, ""


def cert_ips(cert):
    """证书 SAN 里的 IP 列表。读不到返回 []。"""
    rc, out = _run(["openssl", "x509", "-in", cert, "-noout", "-text"])
    if rc != 0:
        return []
    return re.findall(r"IP Address:([0-9.]+)", out)


def fingerprint(cert):
    """SHA-256 指纹(冒号十六进制)。这是用户在浏览器里要比对的那串。"""
    rc, out = _run(["openssl", "x509", "-in", cert, "-noout", "-fingerprint", "-sha256"])
    if rc != 0:
        return ""
    m = re.search(r"=\s*([0-9A-Fa-f:]+)", out)
    return m.group(1).upper() if m else ""


def ensure_cert(cert, key, ip):
    """没有才生成; 已有但**绑定地址不在 SAN 里**才重建(那时旧证书本来就用不了)。

    返回 (指纹, 动作): 动作 ∈ {"kept", "created", "rebuilt-address-changed"}。
    """
    if os.path.isfile(cert) and os.path.isfile(key):
        if not ip or ip in cert_ips(cert):
            return fingerprint(cert), "kept"
        good, why = gen_cert(cert, key, ip)
        if not good:
            return "", "failed:" + why
        return fingerprint(cert), "rebuilt-address-changed"
    good, why = gen_cert(cert, key, ip)
    if not good:
        return "", "failed:" + why
    return fingerprint(cert), "created"


# ── CLI(供 install.sh 与 pdg rescue 调用)────────────────────────────────────
def main(argv):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, "/opt/pdg-bot")
    try:
        import rescue_const as C
    except ImportError:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "bot"))
        import rescue_const as C
    paths = C.paths()
    cert, key, tokenf = paths["PDG_RESCUE_CERT"], paths["PDG_RESCUE_KEY"], paths["PDG_RESCUE_TOKEN"]
    cmd = argv[1] if len(argv) > 1 else "show"
    ip = argv[2] if len(argv) > 2 else ""
    if cmd == "ensure":                       # 装机/迁移: 缺什么补什么, 已有的不动
        _t, tnew = ensure_token(tokenf)
        fp, act = ensure_cert(cert, key, ip)
        if act.startswith("failed:"):
            print(act[7:], file=sys.stderr)
            return 1
        print("token=%s cert=%s fingerprint=%s" % ("created" if tnew else "kept", act, fp))
        return 0
    if cmd == "rotate-token":
        rotate_token(tokenf)
        print("已重建救援 Token(所有已登录会话立即失效)")
        return 0
    if cmd == "rotate-cert":
        good, why = gen_cert(cert, key, ip)
        if not good:
            print(why, file=sys.stderr)
            return 1
        print("已重建自签证书, 新指纹: %s" % fingerprint(cert))
        return 0
    if cmd == "fingerprint":
        fp = fingerprint(cert)
        if not fp:
            print("读不到证书: %s" % cert, file=sys.stderr)
            return 1
        print(fp)
        return 0
    if cmd == "token":                        # **只在 tty 上打印**: 不进日志/管道
        if not sys.stdout.isatty() and not os.environ.get("PDG_RESCUE_ALLOW_PIPE"):
            print("拒绝把救援 Token 输出到非终端(会进日志/管道)。请在 SSH 终端里直接运行。",
                  file=sys.stderr)
            return 1
        try:
            with open(tokenf, encoding="utf-8") as f:
                print(f.read().strip())
        except OSError as e:
            print("读不到 Token(%s)" % type(e).__name__, file=sys.stderr)
            return 1
        return 0
    print("用法: rescue_cred.py {ensure|rotate-token|rotate-cert|fingerprint|token} [绑定IP]",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

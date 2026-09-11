#!/usr/bin/env python3
"""退役后的 CA 兼容读取(WLOC 已退役, 本模块只剩「看一眼旧现场」这一个用途)。

WLOC 位置改写及其专属 MITM 执行能力已退役: 不再签发根 CA、不再现签叶子证书、不再有
服务消费它们。留下这个模块只为两件**只读**的事:

  · 退役迁移要判断这台机器上有没有过旧 CA —— 有才需要按保留策略搬走并记档;
  · 旧备份 / 旧描述文件的校验要拿到旧 CA 的指纹, 才能判断"这份旧产物里嵌的是不是它"。

**这里不写任何东西。** 旧实现是反的: `ca_cert_pem()` 走 `ensure_ca()`, 而 ensure_ca 会
建目录(0700)、建 .ca.lock 并 flock、没有就用 openssl **生成一张根 CA**。于是"问一句有没有"
变成了"没有就给你造一张" —— 在退役语境下尤其坏: 迁移跑一遍、doctor 看一眼、旧备份校验
一次, 每次都可能在一台本该退役干净的机器上重新落下 CA 私钥。

三档分明, 不许混:
  absent   —— 确实没有。迁移据此判定"这台机器没开过 WLOC", 可以直接跳过搬迁。
  present  —— 有, 连同 PEM 正文与 sha256 指纹一起给出。
  damaged  —— 在, 但读不出或不是证书。**绝不能冒充 absent**: 冒充了就会被读成"没开过
              WLOC", 于是迁移跳过、旧备份放行 —— 一条静默复活的路。

签发面(ensure_ca / _gen_ca / leaf_cert / _sign_leaf / prewarm / ca_cert_pem)随退役一并
移除。它们是"制造信任"的入口, 退役之后留着就是留了一条能把 CA 变回来的路。
"""
import hashlib
import os
import subprocess

CA_DIR = "/etc/privdns-gateway/ca"          # 测试可覆盖


def _p(name):
    return os.path.join(CA_DIR, name)


def _pem_to_der(pem_text):
    """用 openssl 把 PEM 转 DER —— 指纹要按证书的 DER 算, 不是按文件字节算。

    文件里可能有多余空行/CRLF/注释, 按文件字节算出来的"指纹"会因为无关编辑而变,
    那种指纹拿去比对旧描述文件只会得出假的不一致。
    """
    r = subprocess.run(["openssl", "x509", "-outform", "DER"],
                       input=pem_text.encode("utf-8"),
                       capture_output=True, timeout=30)
    if r.returncode != 0 or not r.stdout:
        raise ValueError((r.stderr or b"").decode("utf-8", "replace").strip()[:120]
                         or "openssl 不认这份 PEM")
    return r.stdout


def ca_material_readonly():
    """只读地看一眼旧 CA 现场。**不创建目录、不建锁、不生成、不缓存。**

    返回 dict:
      {"state": "absent"}
      {"state": "present", "pem": <str>, "sha256": <str 64hex>, "path": <str>,
       "has_key": <bool>}
      {"state": "damaged", "reason": <str>, "path": <str>}

    has_key 单独给出来: 证书在而私钥也在, 说明这台机器上还留着签发能力的原料,
    退役迁移要按保留策略把它搬走并记档(而不是当作"只有一张公钥证书"轻轻放过)。
    """
    crt = _p("ca.crt")
    if not os.path.exists(crt):
        # 只问存在性, 不 makedirs、不 touch。父目录不存在也照样是 absent。
        return {"state": "absent"}
    try:
        pem = open(crt, encoding="utf-8").read()
    except OSError as e:
        return {"state": "damaged", "path": crt,
                "reason": "读不出 %s(%s)" % (crt, type(e).__name__)}
    except UnicodeDecodeError:
        return {"state": "damaged", "path": crt, "reason": "%s 不是文本 PEM" % crt}
    if "BEGIN CERTIFICATE" not in pem:
        return {"state": "damaged", "path": crt, "reason": "%s 里没有证书块" % crt}
    try:
        der = _pem_to_der(pem)
    except Exception as e:  # noqa: BLE001
        return {"state": "damaged", "path": crt,
                "reason": "%s 解析不出证书(%s)" % (crt, e)}
    return {"state": "present", "path": crt, "pem": pem,
            "sha256": hashlib.sha256(der).hexdigest(),
            "has_key": os.path.exists(_p("ca.key"))}

#!/usr/bin/env python3
"""退役后的 CA 兼容读取(WLOC 已退役, 本模块只剩「看一眼旧现场」这一个用途)。

WLOC 位置改写及其专属 MITM 执行能力已退役: 不再签发根 CA、不再现签叶子证书、不再有
服务消费它们。留下这个模块只为两件**只读**的事:

  · 退役迁移要看这台机器上还剩不剩旧 CA 材料 —— 剩了才需要按保留策略搬走并记档;
  · 旧备份 / 旧描述文件的校验要拿到旧 CA 的指纹, 才能判断"这份旧产物里嵌的是不是它"。

## 一、这里不写任何东西

旧实现是反的: `ca_cert_pem()` 走 `ensure_ca()`, 而 ensure_ca 会建目录(0700)、建
.ca.lock 并 flock、没有就用 openssl **生成一张根 CA**。于是"问一句有没有"变成了"没有
就给你造一张" —— 在退役语境下尤其坏: 迁移跑一遍、doctor 看一眼、旧备份校验一次, 每次
都可能在一台本该退役干净的机器上重新落下 CA 私钥。

签发面(ensure_ca / _gen_ca / leaf_cert / _sign_leaf / prewarm / ca_cert_pem)一并移除:
它们是"制造信任"的入口, 退役之后留着就是留了一条能把 CA 变回来的路。

## 二、四档互不冒充

    absent   目录可达, 证书与私钥都确认不在。
    residue  证书不在但**私钥还在**(或证书在而不可用却仍有私钥)—— 签发原料还在盘上。
    unknown  **无法确认**存在性: 目录不可达、stat 报错、断链。
    present  在, 且通过严格校验。

两条容易写错的地方, 这里刻意分开:

  · `absent` 只表达"这一处材料不在"。它**不等于**"从未开启过 WLOC", 更不等于"整台机器
    无需迁移" —— 服务有没有在跑、劫持规则撤没撤、内核路由还在不在、运行配置留没留,
    每一样都得各自去查。调用方拿 absent 去跳过迁移, 就会漏掉一台"CA 被手工删过、其余
    全在"的机器。所以 absent 这一档带 `note` 把边界写在返回值里。
  · `unknown` 不能并进 absent。`os.path.exists()` 对"不可达"和"不存在"都返回 False,
    统一裁决就等于"看不见 = 没有" —— 那正是静默放行的入口。

## 三、校验复用既有那道门, 不另抄一份松的

`iosprofile.ca_der_from_pem()` 已经是白名单式的严格校验: 拒私钥标记、只接受恰好由
CERTIFICATE 块组成的 PEM、再过 `assert_public_cert_der()` 的"全部字节恰好组成这一张
证书"。这里直接用它 —— 不是因为省事, 是因为"证书后面拼一把私钥"这种输入必须在**同一道**
门上被拒: 两份判据迟早会漂移成一松一紧, 而松的那份就是出口。

错误里**不带待检内容, 也不带解析器原始输出** —— 那两样都可能正是私钥。damaged 这一档
不返回 `pem` 字段, 免得混合文本顺着返回值流进日志或工单。
"""
import os

# 同目录模块。iosprofile 不 import 本模块, 无循环。
import iosprofile

CA_DIR = "/etc/privdns-gateway/ca"          # 测试可覆盖

_ABSENT_NOTE = ("只说明这一处 CA 材料不在; 是否开启过 WLOC、是否仍需退役迁移, "
                "要另行检查服务、劫持规则、内核路由与运行配置。")


def _p(name):
    return os.path.join(CA_DIR, name)


def _probe(path):
    """存在性三态: True=在, False=**确认**不在, None=无法确认。

    不能用 os.path.exists() 裁决: 它把 ENOENT(真的不在)和 EACCES(进不去所以看不见)都压成
    False。压平之后"看不见"就成了"没有" —— 而在退役语境下, 那意味着一台 CA 还躺在盘上、
    只是目录权限被改过的机器会被判成干净现场, 迁移直接跳过。

    所以按 errno 分: ENOENT 才是"不在", 且还要沿父目录逐级确认这条路径真的可走完 ——
    最上面那一级如果是 EACCES, 说明我们从一开始就没看见过, 只能判无法确认。
    断链另算: lstat 成功而 stat 失败 = 链接在、目标解析不了, 同样不是"确认不在"。
    """
    try:
        os.lstat(path)                          # 链接本身存在?
    except FileNotFoundError:
        pass                                    # 往下逐级确认父目录
    except OSError:
        return None                             # EACCES / ELOOP / ENOTDIR …
    else:
        try:
            os.stat(path)                       # 目标解析得开?
            return True
        except FileNotFoundError:
            return None                         # 断链: 在, 但指向解析不了的地方
        except OSError:
            return None

    cur = os.path.dirname(path) or "."
    while True:
        try:
            os.stat(cur)
            return False                        # 某一级父目录可达且存在 ⇒ 文件确认不在
        except FileNotFoundError:
            nxt = os.path.dirname(cur) or "."
            if nxt == cur:
                return False                    # 一路到根都不存在 ⇒ 确认不在
            cur = nxt
        except OSError:
            return None                         # 进不去 ⇒ 无法确认


def ca_material_readonly():
    """只读地看一眼旧 CA 现场。**不创建目录、不建锁、不生成、不缓存、不落盘。**

    返回 dict, `state` 为 absent / residue / unknown / damaged / present 之一:

      absent   {"state","note"}                      —— note 写明边界, 见模块文档
      residue  {"state","has_key","has_cert","reason"}
      unknown  {"state","reason"}
      damaged  {"state","path","reason","has_key"}   —— 不含 pem
      present  {"state","path","sha256","has_key"}   —— sha256 是**证书 DER** 的指纹
    """
    crt, key = _p("ca.crt"), _p("ca.key")
    c_state, k_state = _probe(crt), _probe(key)

    if c_state is None or k_state is None:
        which = "ca.crt" if c_state is None else "ca.key"
        return {"state": "unknown",
                "reason": "无法确认 %s 是否存在(目录不可达或指向解析不了的目标)" % which}

    if not c_state:
        if k_state:
            # 证书没了、私钥还在: 签发原料仍在盘上, 绝不是干净现场。
            return {"state": "residue", "has_key": True, "has_cert": False,
                    "reason": "证书不在但私钥仍在 —— 签发原料还留在盘上, 需按保留策略处置"}
        return {"state": "absent", "note": _ABSENT_NOTE}

    try:
        pem = open(crt, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as e:
        # 读不出/不是文本: 与"确认不在"分开。类型名不带内容, 安全。
        return {"state": "unknown",
                "reason": "%s 在, 但读不出来(%s)" % (crt, type(e).__name__)}

    try:
        # 同一道门: 拒私钥标记 + 只认 CERTIFICATE 块 + 全部字节恰好一张证书。
        der = iosprofile.ca_der_from_pem(pem)
    except iosprofile.ProfileError as e:
        # 只带这道门自己的结论, 不带待检正文, 也不带 openssl 原始输出。
        return {"state": "damaged", "path": crt, "has_key": bool(k_state),
                "reason": str(e)}
    except Exception as e:  # noqa: BLE001
        return {"state": "damaged", "path": crt, "has_key": bool(k_state),
                "reason": "证书校验未能完成(%s)" % type(e).__name__}

    import hashlib
    return {"state": "present", "path": crt, "has_key": bool(k_state),
            "sha256": hashlib.sha256(der).hexdigest()}

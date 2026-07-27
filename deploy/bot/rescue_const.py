#!/usr/bin/env python3
"""救援平面常量的 Python 侧读取 —— **不在这里另定义一份**, 只解析 lib/rescue.sh。

为什么绕这一圈: 端口/路径同时被 bash(装机、迁移、pdg 子命令、nft 渲染)与 python(救援服务
本体、doctor 检查)使用。两边各写一份字面量, 改一处漏一处的后果是"防火墙放行 A、服务监听 B",
而 doctor 检查的是它自己那第三份 —— 页面打不开却一切报绿。所以单一事实源固定在 lib/rescue.sh,
这里只读它。

找不到那份文件 → **抛异常, 不给默认值**。救援服务据此拒绝启动: 猜一个端口去监听, 等于把恢复
入口开在一个防火墙没放行(打不开)或没预期到(可能暴露)的位置上。
"""
import os
import re

# 搜索顺序: 仓库副本 → 与 rescue.py 并排安装的那份(装机时逐字节复制过去, 仓库丢了仍能起)
_CANDIDATES = (
    "/opt/privdns-gateway/lib/rescue.sh",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "rescue.sh"),
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), "lib", "rescue.sh"),      # 仓库内直跑(tests/开发)
)

# 只认 `KEY="${KEY:-VALUE}"` 与 `KEY="VALUE"` 两种形态 —— lib/rescue.sh 里就这两种,
# 不做通用 shell 求值(那等于在解析别人的脚本, 出错方式远比收益多)。
_DEFAULT_RE = r'^%s="\$\{%s:-([^}"]*)\}"'
_PLAIN_RE = r'^%s="([^"]*)"'


def _source_path():
    for p in _CANDIDATES:
        if os.path.isfile(p):
            return p
    raise RuntimeError("找不到 lib/rescue.sh(救援常量单一事实源), 拒绝使用猜测值")


def _raw(key, text):
    for rex in (_DEFAULT_RE % (re.escape(key), re.escape(key)), _PLAIN_RE % re.escape(key)):
        m = re.search(rex, text, re.M)
        if m:
            return m.group(1)
    raise RuntimeError("lib/rescue.sh 里没有常量 %s" % key)


def get(key, path=None, _depth=0):
    """读一个常量。环境变量优先(与 bash 侧 ${KEY:-默认} 的语义一致, 便于测试注入)。

    值里引用别的常量(如 PDG_RESCUE_CERT="$PDG_RESCUE_DIR/cert.pem")要展开 —— 否则 python
    侧拿到的是字面量 `$PDG_RESCUE_DIR/cert.pem`, 与 bash 侧展开后的真实路径不是同一个东西,
    于是"单一事实源"名存实亡(守卫测试正是这么抓到的)。只展开**本文件里定义过的**键, 深度
    有限, 不做通用 shell 求值。"""
    env = os.environ.get(key)
    if env:
        return env
    if _depth > 4:
        raise RuntimeError("常量 %s 的引用层级过深(循环引用?)" % key)
    text = open(path or _source_path(), encoding="utf-8").read()
    val = _raw(key, text)

    def _sub(m):
        ref = m.group(1) or m.group(2)
        return get(ref, path, _depth + 1)

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", _sub, val)


def port(path=None):
    v = get("PDG_RESCUE_PORT", path)
    if not v.isdigit() or not (1 <= int(v) <= 65535):
        raise RuntimeError("救援端口不是合法端口号: %r" % v)
    return int(v)


def paths(path=None):
    return {k: get(k, path) for k in (
        "PDG_RESCUE_DIR", "PDG_RESCUE_CERT", "PDG_RESCUE_KEY",
        "PDG_RESCUE_TOKEN", "PDG_RESCUE_STATE", "PDG_PROFILE_ENV")}


def protected_members(path=None):
    """救援平面的固定受保护成员(相对快照根)。与 bash 侧读的是**同一份** lib/rescue.sh。

    读不到就抛错 —— 宁可让完整恢复拒绝执行, 也不能拿一个空清单去"保护"(那等于没保护)。"""
    text = open(path or _source_path(), encoding="utf-8").read()
    m = re.search(r'PDG_RESCUE_PROTECTED_MEMBERS="([^"]*)"', text)
    if not m:
        raise RuntimeError("lib/rescue.sh 里没有 PDG_RESCUE_PROTECTED_MEMBERS")
    items = tuple(x.strip() for x in m.group(1).splitlines() if x.strip())
    if not items:
        raise RuntimeError("受保护成员清单为空, 拒绝以空清单执行完整恢复")
    return items


def internal_cidr(profile=None):
    """内网卡来源段 —— 唯一真源是 profile.env 的 PDG_INTERNAL_CIDR。

    读不到就返回 None, **不回落去解析 mosdns 配置**: 救援服务用它决定监听地址, 而 mosdns
    配置恰恰是可能已经损坏的那一份。调用方必须显式处理 None(拒绝启动并说明原因)。"""
    f = profile or get("PDG_PROFILE_ENV")
    try:
        with open(f, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    m = re.findall(r"^[ \t]*PDG_INTERNAL_CIDR=[\"']?([^\"'\n]+)", text, re.M)
    return m[-1].strip() if m else None


if __name__ == "__main__":
    import sys
    print(port() if "--port" in sys.argv else _source_path())

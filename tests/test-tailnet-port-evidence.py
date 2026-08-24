#!/usr/bin/env python3
"""tailnet 直连端口对账的**证据等级契约**。

这一项做的是"两份配置对不对得上", 不是"端口通不通" —— 它读 nft 里那条放行, 再读
/etc/default/tailscaled 里的 PORT=, 比一比。所以它能给的结论只有三种:

    对得上        → ok
    对不上        → warn(且必须把两个端口都说出来, 否则用户不知道改哪个)
    取不到证据    → warn + 明说无结论

**第三种以前判 ok, 那是把"没证据"染成了绿灯。**读不到配置文件、或者文件里根本没有
PORT= 时, 我们对"防火墙放行的端口是否还有人监听"一无所知 —— 那不是"没问题", 那是
"不知道"。判绿的代价是: 用户改过端口、冷启动窗口已经回来了, 而 doctor 一路绿灯。

级别只能是 warn, **不能是 fail**: fail 会让 `pdg update` 的自检门整次回滚, 而"这台机器
没装 Tailscale"根本不该阻断更新。

PORT= 的取值按 systemd EnvironmentFile 的语义: 逐行解析, 后面的赋值覆盖前面的。取第一个
是错的 —— 那正好取到被覆盖掉的那个值, 而且错得很安静。

这支是**普通测试**(登记进 CI), 与 tests/negctl/tailnet-direct-port-drift.py 分工不同:
那支证明"判据有牙", 这支钉死"判据说什么"。
"""
import builtins
import importlib.util
import io
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS, FAIL = [0], [0]
def ok(m):  PASS[0] += 1; print("[OK]   %s" % m)
def bad(m): FAIL[0] += 1; print("[FAIL] %s" % m)

_open, _exists = builtins.open, os.path.exists
DEFAULTS = getattr(C, "TAILSCALED_DEFAULTS", "/etc/default/tailscaled")

NFT_WITH = ('table inet pdg {\n chain input {\n'
            '  udp dport %d accept comment "pdg-tailnet-direct"\n }\n}\n')
NFT_NONE = 'table inet pdg {\n chain input {\n  tcp dport { 22 } accept\n }\n}\n'


def run(nft, defaults, defaults_err=None):
    """defaults: 文件内容; None = 文件不存在; defaults_err = 打开时抛的异常(权限等)"""
    def fo(p, *a, **k):
        p = str(p)
        if p == C.NFT_CONF:
            if nft is None:
                raise OSError(2, "No such file")
            return io.StringIO(nft)
        if p == DEFAULTS:
            if defaults_err is not None:
                raise defaults_err
            if defaults is None:
                raise OSError(2, "No such file")
            return io.StringIO(defaults)
        return _open(p, *a, **k)

    def fe(p):
        p = str(p)
        if p == DEFAULTS:
            return defaults is not None or defaults_err is not None
        return _exists(p)

    builtins.open, os.path.exists = fo, fe
    try:
        return C.check_tailnet_direct_port() or (None, "", "(不适用)")
    finally:
        builtins.open, os.path.exists = _open, _exists


def expect(label, r, level, must=(), must_not=()):
    lv, _n, msg = r
    if lv == level:
        ok("%s → %s" % (label, level if level else "None(不适用)"))
    else:
        bad("%s → 得到 %r, 期望 %r。文案: %s" % (label, lv, level, msg[:90]))
        return
    for w in must:
        if w not in msg:
            bad("%s 的文案里缺 %r: %s" % (label, w, msg[:110]))
            return
    for w in must_not:
        if w in msg:
            bad("%s 的文案里不该有 %r: %s" % (label, w, msg[:110]))
            return
    if must or must_not:
        ok("%s 的文案符合要求" % label)


print("== 1. 不适用与一致 ==")
expect("nft 没有 pdg-tailnet-direct", run(NFT_NONE, 'PORT="45678"\n'), None)
expect("端口一致", run(NFT_WITH % 41641, 'PORT="41641"\n'), "ok")

print()
print("== 2. 漂移: warn, 且两个端口都要说出来 ==")
expect("41641 vs 45678", run(NFT_WITH % 41641, 'PORT="45678"\n'), "warn",
       must=("41641", "45678"))

print()
print("== 3. 取不到证据 → warn + 无结论(以前这两格判 ok) ==")
expect("defaults 文件不存在", run(NFT_WITH % 41641, None), "warn", must=("无结论",))
expect("defaults 读取失败(权限)",
       run(NFT_WITH % 41641, None, defaults_err=PermissionError(13, "Permission denied")),
       "warn", must=("无结论",))
expect("文件在但没有 PORT=", run(NFT_WITH % 41641, 'FLAGS=""\n# nothing here\n'),
       "warn", must=("无结论",))

print()
print("== 4. 多重赋值: 取最后一个(systemd EnvironmentFile 语义) ==")
expect("PORT 两次, 最后一个与 nft 一致 → ok",
       run(NFT_WITH % 45678, 'PORT="41641"\nFLAGS=""\nPORT="45678"\n'), "ok")
expect("PORT 两次, 最后一个与 nft 不一致 → warn",
       run(NFT_WITH % 41641, 'PORT="41641"\nPORT="45678"\n'), "warn",
       must=("41641", "45678"))
expect("最后一条非法 → 不退回前一个, 判无结论",
       run(NFT_WITH % 41641, 'PORT="41641"\nPORT=abc\n'), "warn", must=("无结论",))
expect("最后一条端口越界 → 无结论",
       run(NFT_WITH % 41641, 'PORT="41641"\nPORT=70000\n'), "warn", must=("无结论",))

print()
print("== 5. 行首注释里的 PORT= 不算赋值 ==")
expect("只有注释里有 PORT=", run(NFT_WITH % 41641, '# PORT="45678"\nFLAGS=""\n'),
       "warn", must=("无结论",))
expect("注释在真赋值之后, 不该覆盖",
       run(NFT_WITH % 41641, 'PORT="41641"\n#PORT="45678"\n'), "ok")

print()
print("== 6. 引号与空格 ==")
for txt, label in (('PORT=45678\n', "无引号"),
                   ("PORT='45678'\n", "单引号"),
                   ('PORT="45678"\n', "双引号"),
                   ('  PORT = "45678"  \n', "两侧空格")):
    expect(label, run(NFT_WITH % 41641, txt), "warn", must=("45678",))

print()
print("== 7. 文案不得暗示 pdg ssh-source 会跟随自定义端口 ==")
_lv, _n, _msg = run(NFT_WITH % 41641, 'PORT="45678"\n')
for phrase in ("让放行跟上", "自动跟随", "会跟着改"):
    if phrase in _msg:
        bad("漂移文案里仍有误导措辞 %r —— 该命令只会生成 41641" % phrase)
        break
else:
    ok("漂移文案没有暗示该命令会跟随自定义端口")
if "41641" in _msg and ("只支持" in _msg or "只生成" in _msg or "只认" in _msg):
    ok("文案明说了该命令目前只支持默认端口")
else:
    bad("文案没说清该命令只支持 41641: " + _msg[:120])
# 盯的是**冒充运行时事实**这一形态, 不是某个字。defaults 只是端口的配置来源, 进程有没有
# 按它跑, 这条判据管不着 —— 所以不能写"实际监听/监听端口/在监听", 只能写"声明/配置"。
_claims_runtime = [w for w in ("实际监听", "监听端口", "正在监听", "监听的端口") if w in _msg]
if _claims_runtime:
    bad("文案把 defaults 说成了运行时监听事实(%s), 而这一项只是配置对账" % _claims_runtime[0])
elif not any(w in _msg for w in ("声明", "配置", "对账")):
    bad("文案没把自己限定为配置对账, 读者会以为它探过端口: " + _msg[:110])
else:
    ok("文案把自己限定为配置对账, 没冒充监听探测")

print()
print("== 8. 级别不得升成 fail(会让 update 自检门回滚) ==")
_bad_fail = []
for label, r in (("不存在", run(NFT_WITH % 41641, None)),
                 ("没有 PORT=", run(NFT_WITH % 41641, 'FLAGS=""\n')),
                 ("漂移", run(NFT_WITH % 41641, 'PORT="45678"\n'))):
    if r[0] == "fail":
        _bad_fail.append(label)
if _bad_fail:
    bad("这些格判成了 fail, 会让没装 Tailscale 的机器升级回滚: %s" % _bad_fail)
else:
    ok("没有任何一格是 fail")

print()
print("== 9. 判据仍接在 doctor 上 ==")
if C.check_tailnet_direct_port in C.ALL:
    ok("check_tailnet_direct_port 在 checks.ALL 里")
else:
    bad("判据没接进 checks.ALL —— 写了也不会跑")

print("-" * 62)
print("test-tailnet-port-evidence.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

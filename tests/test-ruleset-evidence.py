#!/usr/bin/env python3
"""`check_rulesets` 的证据等级必须与它真正验过的东西相符。

它现在读的只有 `rulesets.json` 这份**元数据**, 于是它能证明的仅仅是:

  · 文件读得出来;
  · 元数据里没有明确属于 sing-box 的 `.srs` / `format=binary`;
  · 扩展名或 format 没命中已知不兼容形态。

它**不能**证明:

  · mihomo 已经读到了这些 provider;
  · provider 下载成功;
  · provider 解析出非零条规则;
  · 运行期配置里真有对应的 RULE-SET;
  · provider 当前没有 error。

而它的文案是 `ok / N 个, 格式均可被 mihomo 加载` —— "可被 mihomo 加载"是一句**运行期结论**,
用静态元数据说出来就是假绿。一个写着 `.yaml` 但运行期根本没被加载的 provider, 在这条判据
下与一切正常的机器长得一模一样。

本轮关掉的是这句假绿文案, **不是**运行期 provider 证据本身。要真证明"已加载", 需要一个
安全的运行期查询接口(mihomo 的管理面), 那是架构待决项, 本轮不引入: 不新增 HTTP 管理端口、
不读现有 9090、不偷偷开 ext-ctl-unix、不拿 `mihomo -t` 的配置语法通过冒充 provider 已加载、
不去访问 provider URL 做在线探测。

新契约:
  · 明确不兼容(.srs / format=binary / path 以 .srs 结尾)→ 仍然 **fail**;
  · 没有元数据 / 元数据为空 → 仍然 **None**(没配过规则集, 不是问题);
  · 元数据损坏 → **不得静默当成"没配置"**;
  · 有规则集且静态形态没发现已知不兼容 → **warn**, 并说清"本项未读取运行期 provider 状态,
    因此不能证明规则已加载";
  · WARN 不改变 `pdg doctor` 的总退出码(更新自检只按 level=="fail" 计数)。
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402

spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

PASS = [0]
FAIL = [0]
def ok(m):  PASS[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL[0] += 1; print("  ✗ %s" % m)

WD = tmpguard.mkdtemp(prefix="pdg-rsev.")


def ask(meta, raw=None):
    """把 RS_META 指到一份临时元数据上, 问一次判据。raw 非 None 时按原样写(用来造损坏)。"""
    p = os.path.join(WD, "rulesets.json")
    if raw is not None:
        open(p, "w", encoding="utf-8").write(raw)
    elif meta is None:
        if os.path.exists(p):
            os.remove(p)
    else:
        json.dump(meta, open(p, "w", encoding="utf-8"))
    old = checks.RS_META
    checks.RS_META = p
    try:
        return checks.check_rulesets()
    finally:
        checks.RS_META = old


print("== 1. 没配过规则集: 保持 None(不是问题, 不该出现在报告里)==")
r = ask(None)
(ok if r is None else bad)("无元数据 → None(实得 %r)" % (r,))
r = ask({})
(ok if r is None else bad)("空元数据 → None(实得 %r)" % (r,))

print("\n== 2. 明确不兼容: 仍然 fail ==")
for label, meta in (
    (".srs URL", {"a": {"url": "https://x/y.srs", "label": "A"}}),
    ("format=binary", {"a": {"url": "https://x/y.list", "format": "binary", "label": "B"}}),
    # 这是**元数据里的字符串**, 不是真去建的临时目录 —— 但写死 /tmp 会被 tmp 卫生守卫逮住
    # (它逮得对: 按字面扫分不出"路径数据"和"真临时目录", 而放宽扫描等于给真违规开口子)。
    ("path 以 .srs 结尾",
     {"a": {"url": "https://x/y.list", "path": "/var/lib/pdg/z.srs", "label": "C"}}),
):
    r = ask(meta)
    if r and r[0] == "fail":
        ok("%s → fail" % label)
    else:
        bad("%s → 实得 %r(应为 fail)" % (label, r))

print("\n== 3. 元数据损坏: 不得静默当成「没配置」==")
r = ask(None, raw="{ this is not json")
if r is None:
    bad("JSON 损坏被当成 None —— 读不出来不等于没配过, 这是把无结论说成没问题")
elif r[0] in ("warn", "fail"):
    ok("JSON 损坏 → %s(有结论, 不冒充「没配置」)" % r[0])
else:
    bad("JSON 损坏 → 实得 %r" % (r,))

print("\n== 4. 静态形态没问题 ≠ 已加载: 必须 warn, 不许 ok ==")
for ext in (".list", ".txt", ".yaml", ".mrs"):
    meta = {"a": {"url": "https://x/y" + ext, "label": "R" + ext}}
    r = ask(meta)
    if not r:
        bad("%s → 实得 None(有规则集就该说话)" % ext)
    elif r[0] == "ok":
        bad("%s → **ok**: 静态元数据说不出「已被 mihomo 加载」, 这是假绿(实得 %r)" % (ext, r[2]))
    elif r[0] == "warn":
        ok("%s → warn(不冒充运行期结论)" % ext)
    else:
        bad("%s → 实得 %r" % (ext, r))

print("\n== 5. 文案要分清「发现不兼容」与「没验过运行期」==")
r = ask({"a": {"url": "https://x/y.yaml", "label": "R"}})
txt = r[2] if r else ""
if r and r[0] == "warn":
    (ok if ("未读取" in txt or "未验证" in txt or "无法证明" in txt or "不能证明" in txt)
     else bad)("warn 文案点明「本项没读运行期 provider 状态」(实得: %s)" % txt[:70])
    (ok if ("加载" not in txt or "不能证明" in txt or "无法证明" in txt) else bad)(
        "warn 文案不再宣称「均可被 mihomo 加载」(实得: %s)" % txt[:70])
else:
    bad("拿不到 warn, 文案无从检查(实得 %r)" % (r,))
rf = ask({"a": {"url": "https://x/y.srs", "label": "S"}})
if rf and rf[0] == "fail":
    (ok if "srs" in rf[2].lower() else bad)("fail 文案点名了不兼容的形态(实得: %s)" % rf[2][:60])

print("\n== 6. WARN 不改变 doctor 总退出码 ==")
# 更新自检只按 level=="fail" 计数(deploy/bot/pdg.sh 的内嵌 python)。
pdg = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
(ok if 'fails = [x for x in d if x.get("level") == "fail"]' in pdg else bad)(
    "更新自检只把 level==fail 计入失败数")
(ok if 'warns = [x for x in d if x.get("level") == "warn"]' in pdg else bad)(
    "warn 单独统计, 不进失败数")

print("\n== 7. 本项不得读 controller, 不得发网络请求 ==")
# 只扫**代码**, 不扫 docstring 与注释。按词面扫整段是假判据: 函数的 docstring 里正好写着
# "不读现有 9090、不开 ext-ctl-unix" 这句自我说明, 于是"说明自己不碰"反而被判成"碰了"。
# 我第一版就这么误报了一次 —— 判据不该看噪声。
import ast as _ast
_mod = _ast.parse((ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8"))
_fn = next(n for n in _ast.walk(_mod)
           if isinstance(n, _ast.FunctionDef) and n.name == "check_rulesets")
_stmts = _fn.body[1:] if (_fn.body and isinstance(_fn.body[0], _ast.Expr)
                          and isinstance(_fn.body[0].value, _ast.Constant)
                          and isinstance(_fn.body[0].value.value, str)) else _fn.body
body = "\n".join(_ast.unparse(n) for n in _stmts)
for pat in ("9090", "external-controller", "ext-ctl", "requests.", "urlopen", "urllib",
            "socket.", "curl", "http://", "https://"):
    (bad if pat in body else ok)(
        ("check_rulesets 里出现了 %s —— 本项不该碰运行期/网络" % pat) if pat in body
        else "check_rulesets 不含: %s" % pat)

print("\n== 8. 本项只读 RS_META 这一个文件, 不拿别的文件冒充证据 ==")
# "配置文件存在 → 视为 provider 已加载"是最省事也最像样的**证据替换**: 它返回 ok, 而它
# 证明的东西和规则集有没有被加载毫无关系。按行为判抓不住它 —— 沙箱里那个路径通常不存在,
# 分支根本不触发, 于是"改坏了却 0 条转红"。所以这一条按**结构**判: 函数体里除了 RS_META,
# 不许再出现任何文件系统探测。
_fs_calls = []
for _n in _ast.walk(_ast.parse(body)):
    if isinstance(_n, _ast.Call):
        _f = _n.func
        _nm = _f.attr if isinstance(_f, _ast.Attribute) else getattr(_f, "id", "")
        if _nm in ("exists", "isfile", "isdir", "glob", "listdir", "stat", "read_text"):
            _fs_calls.append(_nm)
(ok if not _fs_calls else bad)(
    "函数体不含额外的文件系统探测(实得 %s)" % (_fs_calls or "无"))
_paths = [c.value for c in _ast.walk(_ast.parse(body))
          if isinstance(c, _ast.Constant) and isinstance(c.value, str)
          and c.value.startswith("/") and len(c.value) > 1]
(ok if not _paths else bad)(
    "函数体里没有写死的其它路径(实得 %s)" % (_paths or "无"))
_opens = [c for c in _ast.walk(_ast.parse(body))
          if isinstance(c, _ast.Call) and getattr(c.func, "id", "") == "open"]
_bad_open = [c for c in _opens
             if not (c.args and isinstance(c.args[0], _ast.Name) and c.args[0].id == "RS_META")]
(ok if not _bad_open else bad)(
    "所有 open() 的第一个参数都是 RS_META(实得 %d 处不是)" % len(_bad_open))

n = PASS[0] + FAIL[0]
print("\n断言 %d 项: 通过 %d, 失败 %d" % (n, PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

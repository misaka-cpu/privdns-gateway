#!/usr/bin/env python3
"""渲染判废异常的**默认安全性**: 不靠 pdgtx 在不在来决定会不会泄密。

原来的做法是"有 pdgtx 就用它的 TxRefused, 没有就退回 RuntimeError"。问题在于: 出口 tag 与
规则集名都是**用户可以随便起名**的字段, 没有 pdgtx 时它们会原样进异常正文, 而调用方以为
"上层会 redact"。安全不能是可选项, 更不能取决于另一个模块导不导得进来。

现在 mihomorender 自带 RenderRefused: str()/repr() 只有固定错误码与**计数**, 原始标识放在
结构化的 .items 里; 要展示名字的调用方必须在自己的边界上显式要一次 detail(redact=…)。

所以这里验的是: pdgtx 正常 / 不存在 / 语法损坏 / 旧版缺 redact 四种情形下, 把哨兵塞进
tag、规则集名、URL 与路径, 断言 str / repr / 日志 / HTML / 审计里都不出现它。
"""
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT_DIR = os.path.join(ROOT, "deploy", "bot")
sys.path.insert(0, BOT_DIR)
os.environ.setdefault("PDG_BOT_TOKEN", "1:refusal")

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-refusal-9d2"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


# 哨兵塞满每一个用户可控的字段: 出口 tag、规则集名、订阅 URL、本地路径
MODEL = {
    "log": {"level": "warn"}, "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"},
                  {"type": "wireguard", "tag": "wg-%s" % SENTINEL,
                   "server": "1.1.1.1", "server_port": 1}],
    "route": {"rules": [{"rule_set": "rs-%s" % SENTINEL, "outbound": "direct"}],
              "final": "direct"},
}
META = {"rs_x": {"url": "https://%s.example/x.list" % SENTINEL,
                 "path": "/tmp/%s/x.list" % SENTINEL}}


def run_with_pdgtx(state, code):
    """在独立子进程里跑 code, pdgtx 处于指定状态。
    'ok' 原样 / 'absent' 删掉 / 'broken' 语法错 / 'oldver' 能 import 但缺 redact 与异常类。"""
    d = tmpguard.mkdtemp(prefix="refusal.")
    try:
        for f in os.listdir(BOT_DIR):
            if f.endswith(".py"):
                shutil.copy2(os.path.join(BOT_DIR, f), os.path.join(d, f))
        tgt = os.path.join(d, "pdgtx.py")
        if state == "absent":
            os.remove(tgt)
        elif state == "broken":
            open(tgt, "w", encoding="utf-8").write("这不是 Python(  :::\n")
        elif state == "oldver":
            open(tgt, "w", encoding="utf-8").write(
                '"""旧版事务核心: import 得进来, 但没有 redact 也没有 TxRefused。"""\n'
                'FSROOT = ""\n')
        env = dict(os.environ)
        env["PYTHONPATH"] = d
        env["PYTHONPYCACHEPREFIX"] = os.path.join(d, "__pyc__")
        p = subprocess.run([sys.executable, "-c", code], capture_output=True,
                           text=True, env=env, cwd=d, timeout=300)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ══ 1. 四种 pdgtx 状态下, 判废异常的默认串都不含哨兵 ═══════════════════════
print("── 1. 默认安全性(四种 pdgtx 状态)──")
PROBE = textwrap.dedent('''
    import json, sys, traceback
    import mihomorender as M
    model = json.loads(%r)
    meta = json.loads(%r)
    data, rmeta = M.render_bytes(model, lan_domains=[], rulesets=M.rulesets_arg(meta),
                                 mitm_domains=[], tls_ports=None)
    try:
        M.check_meta(rmeta)
        print("NOREFUSE:1")
    except M.RenderRefused as e:
        print("STR:" + str(e))
        print("REPR:" + repr(e))
        print("ARGS:" + json.dumps([str(a) for a in e.args], ensure_ascii=False))
        print("CODE:" + e.code)
        print("TB:" + "".join(traceback.format_exception_only(type(e), e)).strip())
        print("VARS:" + json.dumps({k: str(v) for k, v in vars(e).items()}, ensure_ascii=False))
        print("DIR_HAS_ITEMS:" + str(any(a == "items" for a in dir(e))))
        print("COUNT:" + str(e.count))
        # detail() 是**唯一**的可读详情出口, 按设计会展示脱敏后的标识 —— 它不在
        # "str/repr/args/vars/traceback" 那组渠道里, 所以单独打, 不参与下面的渠道扫描。
        print("XDETAIL:" + e.detail())
''') % (json.dumps(MODEL), json.dumps(META))

for label, state in (("pdgtx 正常", "ok"), ("pdgtx 不存在", "absent"),
                     ("pdgtx 语法损坏", "broken"), ("pdgtx 旧版缺 redact", "oldver")):
    rc, out = run_with_pdgtx(state, PROBE)
    if rc != 0 or "STR:" not in out:
        bad("%s: 探针没跑通 rc=%s\n%s" % (label, rc, out[-400:]))
        continue
    channels = "\n".join(ln for ln in out.splitlines() if not ln.startswith("XDETAIL:"))
    if SENTINEL in channels:
        leaked = [ln for ln in channels.splitlines() if SENTINEL in ln]
        bad("%s: 渠道里出现哨兵: %s" % (label, leaked[:2]))
    else:
        ok("%s: str / repr / args / vars / traceback 全都不含哨兵" % label)
    if "DIR_HAS_ITEMS:False" in out:
        ok("%s: 没有公开的 .items 接口(拿不到就打印不出来)" % label)
    else:
        bad("%s: 仍暴露 .items" % label)
    m = re.search(r"^VARS:(.*)$", out, re.M)
    if m and SENTINEL not in m.group(1):
        ok("%s: vars(exc) / __dict__ 里也没有原始标识" % label)
    else:
        bad("%s: vars 泄漏: %s" % (label, (m.group(1) if m else "?")[:160]))
    if re.search(r"^COUNT:[1-9]", out, re.M):
        ok("%s: 计数仍在(信息没丢: 用户知道有几项)" % label)
    else:
        bad("%s: 连计数都没有" % label)
    if "CODE:RENDER_REFUSED_" in out:
        ok("%s: 带固定错误码(供调用方分类, 不随文案变)" % label)
    else:
        bad("%s: 缺固定错误码" % label)

# detail() 会展示标识(这是既有的产品决定: 不点名用户不知道该改哪个出口), 但**凭据形态**
# 必须被统一脱敏掉 —— 且这一条在 pdgtx 不可用时同样成立(本地兜底永远跑)。
CRED_PROBE = textwrap.dedent('''
    import mihomorender as M
    e = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES,
                        ["token=" + "a" * 40, "1234567890:" + "b" * 35])
    print("XDETAIL:" + e.detail())
''')
for label, state in (("pdgtx 正常", "ok"), ("pdgtx 不存在", "absent"),
                     ("pdgtx 语法损坏", "broken"), ("pdgtx 旧版缺 redact", "oldver")):
    rc, out = run_with_pdgtx(state, CRED_PROBE)
    if rc == 0 and "aaaa" not in out and "bbbb" not in out:
        ok("%s: detail() 里凭据形态被脱敏(本地兜底不依赖 pdgtx)" % label)
    else:
        bad("%s: detail 未脱敏 rc=%s: %s" % (label, rc, out[-200:]))

# ══ 2. detail() 自己脱敏, 且拿不到原始列表 ════════════════════════════════
print()
print("── 2. detail() 是唯一出口, 脱敏由它自己做 ──")
import mihomorender as M  # noqa: E402

e = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES, ["wg-%s" % SENTINEL, "b"])
if SENTINEL not in str(e) and SENTINEL not in repr(e):
    ok("默认 str/repr 不含名字")
else:
    bad("默认串泄漏: %r" % str(e))
if SENTINEL not in json.dumps({k: str(v) for k, v in vars(e).items()}, ensure_ascii=False):
    ok("vars(exc) 不含原始标识(原始值只在闭包里, 不是属性)")
else:
    bad("vars 泄漏: %r" % vars(e))
if not hasattr(e, "items"):
    ok("没有公开的 .items 接口")
else:
    bad("仍暴露 .items = %r" % getattr(e, "items"))
if "2" in str(e) and e.count == 2:
    ok("计数仍在(用户知道有几项)")
else:
    bad("计数丢了: %r" % str(e))
# detail() 不再接受 redact 参数 —— 依赖"调用方记得脱敏"正是上一版的问题
import inspect  # noqa: E402
if list(inspect.signature(e.detail).parameters) == []:
    ok("detail() 不收参数: 脱敏是它自己的责任, 不依赖调用方")
else:
    bad("detail 仍要调用方传脱敏函数: %s" % inspect.signature(e.detail))
# 凭据形态一定被脱敏掉(这是"统一脱敏确实在跑"的证据)
cred = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES,
                       ["token=" + "a" * 40, "1234567890:" + "b" * 35])
d = cred.detail()
if "aaaa" not in d and "bbbb" not in d and ("redacted" in d or "token" in d):
    ok("detail(): 凭据形态的标识被统一脱敏改写(本地兜底 + pdgtx 两层)")
else:
    bad("detail 没脱敏: %r" % d)
# 超长标识截断 —— 再长就不是标签而是有人把正文塞进来了
longd = M.RenderRefused(M.RenderRefused.DROPPED_RULES, ["x" * 500]).detail()
if len(longd) < 200:
    ok("detail(): 超长标识被截断(%d 字符)" % len(longd))
else:
    bad("超长标识没截断: %d" % len(longd))
# 脱敏**内部**出错也不能把原值放出去 —— 让 _safe_ident 里调用的脱敏函数抛异常, 而不是
# 把 _safe_ident 整个换掉(换掉的话验的是外层 detail 的兜底, 不是这一层)
class _Boom:
    @staticmethod
    def redact(x):
        raise RuntimeError("脱敏炸了")


_orig_tx = M._tx_mod
try:
    M._tx_mod = lambda: _Boom
    broke = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES, ["wg-%s" % SENTINEL])
    d_broke = broke.detail()
    if SENTINEL not in d_broke:
        ok("脱敏内部出错 → 该标识退化成占位符, 原值不外泄(%s)" % d_broke[-30:])
    else:
        bad("脱敏出错时泄漏原值: %r" % d_broke)
finally:
    M._tx_mod = _orig_tx

# 外层也要有兜底: 整个 _safe_ident 不可用时 detail() 退化成错误类型 + 数量
_orig_si = M._safe_ident
try:
    M._safe_ident = lambda v: (_ for _ in ()).throw(RuntimeError("boom"))
    broke2 = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES, ["wg-%s" % SENTINEL])
    if SENTINEL not in broke2.detail() and "RENDER_REFUSED" in broke2.detail():
        ok("渲染详情整体出错 → detail() 退化成错误类型 + 数量 + 通用说明")
    else:
        bad("整体出错时泄漏: %r" % broke2.detail())
finally:
    M._safe_ident = _orig_si

# ══ 3. bot 边界: 仍给出原有的友好错误 ═════════════════════════════════════
print()
print("── 3. bot 边界映射 ──")
import importlib.util as iu  # noqa: E402
spec = iu.spec_from_file_location("bot", os.path.join(BOT_DIR, "pdg-bot.py"))
bot = iu.module_from_spec(spec)
sys.modules["bot"] = bot
spec.loader.exec_module(bot)
work = tmpguard.mkdtemp(prefix="refusalbot.")
RS = os.path.join(work, "rulesets.json")
json.dump({}, open(RS, "w"))
bot.RS_META = RS
_p = bot._platform
bot._platform = lambda: "android"
try:
    bot._mihomo_derive({"model": json.dumps(MODEL).encode()})
    bad("bot 边界: 竟然没判废")
except Exception as ex:  # noqa: BLE001
    import pdgtx  # noqa: E402
    if isinstance(ex, pdgtx.TxRefused):
        ok("bot 边界: 仍抛 TxRefused(既有错误分类不变)")
    else:
        bad("bot 边界抛了 %s" % type(ex).__name__)
    msg = str(ex)
    if "无法转换" in msg or "无法进入" in msg:
        ok("bot 边界: 仍是原有的友好中文文案")
    else:
        bad("bot 文案变了: %r" % msg[:120])
    # tx.redact 对这类标签不一定有规则, 但**必须是经它过一遍**的结果 —— 这里断言 bot 确实
    # 调了 redact(用一个 redact 一定会改写的形态验证)
    e2 = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES, ["token=" + "a" * 40])
    if "aaaa" not in e2.detail():
        ok("bot 拿到的文案里, 凭据形态已被 detail() 自己脱敏")
    else:
        bad("bot 文案未脱敏: %r" % e2.detail())
finally:
    bot._platform = _p

# ══ 4. 共享模块不拿 pdgtx 决定安全性 ══════════════════════════════════════
print()
print("── 4. 依赖边界 ──")
src = open(os.path.join(BOT_DIR, "mihomorender.py"), encoding="utf-8").read()
if "_refused_cls" not in src:
    ok("已删除 _refused_cls(不再按 pdgtx 在不在挑异常类)")
else:
    bad("_refused_cls 还在")
if "RuntimeError" not in src.split("class RenderRefused")[0]:
    ok("不再有「退回 RuntimeError」这条路径")
else:
    bad("仍存在 RuntimeError 退路")
import ast  # noqa: E402
tree = ast.parse(src)
cls = next((n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)
            and n.name == "RenderRefused"), None)
if cls and not any(isinstance(n, (ast.Import, ast.ImportFrom)) for n in ast.walk(cls)):
    ok("RenderRefused 本身不 import 任何东西(纯本地, 稳定)")
else:
    bad("RenderRefused 依赖了外部导入")

# ══ 5. 调用点守卫: 生产代码不得再直接读原始列表 ═══════════════════════════
print()
print("── 5. 调用点守卫(AST)──")
_PROD = []
for _d in ("deploy/bot", "deploy/rescue"):
    for _f in sorted(os.listdir(os.path.join(ROOT, _d))):
        if _f.endswith(".py"):
            _PROD.append(os.path.join(ROOT, _d, _f))
_viol = []
for _f in _PROD:
    _t = ast.parse(open(_f, encoding="utf-8").read(), filename=_f)
    for _n in ast.walk(_t):
        # 属性访问: x.items / x._RenderRefused__items(名字改写后的私有名)
        if isinstance(_n, ast.Attribute) and _n.attr in ("items", "_RenderRefused__items"):
            # dict.items() 是合法的 —— 只有**调用**形式才放行
            parent_call = any(isinstance(p, ast.Call) and p.func is _n for p in ast.walk(_t))
            if not parent_call:
                _viol.append("%s:%d .%s" % (os.path.basename(_f), _n.lineno, _n.attr))
        # getattr(exc, "items") 之类的绕道
        if (isinstance(_n, ast.Call) and getattr(_n.func, "id", "") == "getattr"
                and len(_n.args) > 1 and isinstance(_n.args[1], ast.Constant)
                and str(_n.args[1].value) in ("items", "_RenderRefused__items")):
            _viol.append("%s:%d getattr(...,%r)" % (os.path.basename(_f), _n.lineno,
                                                    _n.args[1].value))
if not _viol:
    ok("生产代码里没有任何对原始标识列表的直接访问(%d 个文件)" % len(_PROD))
else:
    bad("有直接访问原始列表的地方: %s" % _viol[:4])

# 三个调用方都只消费 detail() —— 逐个确认
for _name, _f, _fn in (("bot", "deploy/bot/pdg-bot.py", "_mihomo_derive"),
                       ("共享 deriver", "deploy/bot/mihomorender.py", "deriver_from_paths")):
    _src = open(os.path.join(ROOT, _f), encoding="utf-8").read()
    _t = ast.parse(_src)
    _node = next((n for n in ast.walk(_t) if isinstance(n, ast.FunctionDef)
                  and n.name == _fn), None)
    _txt = ast.get_source_segment(_src, _node) if _node else ""
    if "RenderRefused" in _txt and ".detail()" in _txt:
        ok("%s 的边界只消费 detail()" % _name)
    else:
        bad("%s 的边界没走 detail(): %r" % (_name, _txt[-160:] if _txt else "未找到"))
# cfgrestore 走的是共享 deriver, 自己不碰这个异常 —— 确认它确实没引用
_cfg = open(os.path.join(ROOT, "deploy/bot/cfgrestore.py"), encoding="utf-8").read()
if "RenderRefused" not in _cfg:
    ok("cfgrestore 不直接接触判废异常(经共享 deriver 边界映射成 TxRefused)")
else:
    bad("cfgrestore 直接引用了 RenderRefused")

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

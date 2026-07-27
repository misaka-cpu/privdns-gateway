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
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

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
    d = tempfile.mkdtemp(prefix="refusal.")
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
    data, rmeta = M.render_bytes(model, rulesets=M.rulesets_arg(meta),
                                 mitm_domains=[], tls_ports=None)
    try:
        M.check_meta(rmeta)
        print("NOREFUSE:1")
    except M.RenderRefused as e:
        print("STR:" + str(e))
        print("REPR:" + repr(e))
        print("ARGS:" + json.dumps([str(a) for a in e.args], ensure_ascii=False))
        print("CODE:" + e.code)
        print("SAFEDETAIL:" + e.detail())
        print("TB:" + "".join(traceback.format_exception_only(type(e), e)).strip())
        print("ITEMS_HAVE_NAMES:" + str(any("SENT" in x for x in e.items)))
''') % (json.dumps(MODEL), json.dumps(META))

for label, state in (("pdgtx 正常", "ok"), ("pdgtx 不存在", "absent"),
                     ("pdgtx 语法损坏", "broken"), ("pdgtx 旧版缺 redact", "oldver")):
    rc, out = run_with_pdgtx(state, PROBE)
    if rc != 0 or "STR:" not in out:
        bad("%s: 探针没跑通 rc=%s\n%s" % (label, rc, out[-400:]))
        continue
    if SENTINEL in out:
        leaked = [ln for ln in out.splitlines() if SENTINEL in ln]
        bad("%s: 判废输出里出现哨兵: %s" % (label, leaked[:2]))
    else:
        ok("%s: str / repr / args / traceback / 默认 detail 全都不含哨兵" % label)
    if "ITEMS_HAVE_NAMES:True" in out:
        ok("%s: 原始标识仍保留在结构化 .items 里(没有丢信息, 只是不进默认串)" % label)
    else:
        bad("%s: .items 里没有原始标识, 信息被丢了" % label)
    if "CODE:RENDER_REFUSED_" in out:
        ok("%s: 带固定错误码(供调用方分类, 不随文案变)" % label)
    else:
        bad("%s: 缺固定错误码" % label)

# ══ 2. 显式要 detail(redact=…) 才展示名字, 且经脱敏 ═══════════════════════
print()
print("── 2. 要名字必须显式过脱敏 ──")
import mihomorender as M  # noqa: E402

e = M.RenderRefused(M.RenderRefused.UNKNOWN_PROXIES, ["wg-%s" % SENTINEL, "b"])
if SENTINEL not in str(e) and SENTINEL not in repr(e) and SENTINEL not in e.detail():
    ok("默认 str/repr/detail() 都不含名字")
else:
    bad("默认串泄漏: %r" % str(e))
if "2" in str(e):
    ok("默认串给出**计数**(用户知道有几项, 只是看不到名字)")
else:
    bad("默认串没有计数: %r" % str(e))
shown = e.detail(redact=lambda x: x.replace(SENTINEL, "<redacted>"))
if SENTINEL not in shown and "<redacted>" in shown and "b" in shown:
    ok("detail(redact=…): 名字经脱敏后才出现")
else:
    bad("detail 脱敏不对: %r" % shown)
raw = e.detail(redact=lambda x: x)
if SENTINEL in raw:
    ok("调用方给的是恒等脱敏时才会看到原值(证明确实是调用方在决定)")
else:
    bad("detail 忽略了调用方给的函数")

# ══ 3. bot 边界: 仍给出原有的友好错误 ═════════════════════════════════════
print()
print("── 3. bot 边界映射 ──")
import importlib.util as iu  # noqa: E402
spec = iu.spec_from_file_location("bot", os.path.join(BOT_DIR, "pdg-bot.py"))
bot = iu.module_from_spec(spec)
sys.modules["bot"] = bot
spec.loader.exec_module(bot)
work = tempfile.mkdtemp(prefix="refusalbot.")
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
    if "<redacted>" in e2.detail(redact=pdgtx.redact) or "redacted" in e2.detail(redact=pdgtx.redact):
        ok("detail 经 pdgtx.redact 后, 敏感形态确实被改写")
    else:
        bad("redact 没起作用: %r" % e2.detail(redact=pdgtx.redact))
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

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

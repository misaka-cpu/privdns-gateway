#!/usr/bin/env python3
"""共享渲染模块的**独立性**回归: 它必须在 pdg-bot 缺席/损坏时照样工作。

这是整次提取的全部理由。救援平面的立身之本是"bot 可能正是坏掉的那一个" —— 如果渲染仍然只能
经由 bot 才拿得到, 那么 model 一变就必须重渲内核配置这条纪律, 救援与配置恢复根本没法遵守
(cfgrestore 此前就栽在这里: 换回了 config.json, 却让内核继续跑旧的 config.yaml)。

所以这里验的不是"渲染对不对"(那是 test-render-characterize 的活), 而是**依赖边界**:
  · pdg-bot.py 语法坏掉 / 根本不存在时, 共享模块与 cfgrestore 的 deriver 照样能出候选;
  · 禁止 import pdg-bot 时, 共享模块的测试仍然通过;
  · bot 与共享模块对同一份输入产出**逐字节相同**的结果;
  · bot 侧六个 monkeypatch 点仍然生效(共享模块不许暗读 bot 的可变全局);
  · 不产生循环导入。
"""
import hashlib
import importlib.util as iu
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOT_DIR = os.path.join(ROOT, "deploy", "bot")
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
sys.path.insert(0, BOT_DIR)
os.environ.setdefault("PDG_BOT_TOKEN", "1:shared")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


MODEL = {
    "log": {"level": "warn"},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"},
                  {"type": "shadowsocks", "tag": "ss1", "server": "1.2.3.4",
                   "server_port": 8388, "method": "aes-128-gcm", "password": "PW-SENTINEL"}],
    "route": {"rules": [{"domain_suffix": ["ex.test"], "outbound": "ss1"}], "final": "direct"},
}
META = {"rs_yaml": {"url": "https://ex.test/b.yaml"},
        "rs_mrs": {"url": "https://ex.test/f.mrs",
                   "path": os.path.join(FIXTURES, "behavior-domain.mrs")}}


def run_isolated(code, *, bot_state, extra_env=None):
    """在**独立子进程**里跑一段代码。bot_state 决定 pdg-bot.py 长什么样:
    'ok' 原样 / 'broken' 语法错误 / 'absent' 根本不存在 / 'blocked' 存在但禁止 import。

    必须开子进程: 同一个解释器里 sys.modules 早就缓存了正常的 bot, 那样测出来的
    "不依赖 bot"是假的。"""
    d = tempfile.mkdtemp(prefix="sharedbot.")
    try:
        for f in os.listdir(BOT_DIR):
            if f.endswith(".py"):
                shutil.copy2(os.path.join(BOT_DIR, f), os.path.join(d, f))
        tgt = os.path.join(d, "pdg-bot.py")
        if bot_state == "broken":
            open(tgt, "w", encoding="utf-8").write("这行不是 Python(  :::\n")
        elif bot_state == "absent":
            os.remove(tgt)
        env = dict(os.environ)
        env["PYTHONPATH"] = d
        env["PYTHONPYCACHEPREFIX"] = os.path.join(d, "__pyc__")
        env.update(extra_env or {})
        pre = ""
        if bot_state == "blocked":
            # 硬门: 任何试图 import pdg-bot / bot 的行为直接抛错
            pre = textwrap.dedent('''
                import builtins
                _real = builtins.__import__
                def _guard(name, *a, **k):
                    if name in ("bot", "pdg-bot", "pdg_bot"):
                        raise ImportError("测试禁止 import pdg-bot: " + name)
                    return _real(name, *a, **k)
                builtins.__import__ = _guard
            ''')
        p = subprocess.run([sys.executable, "-c", pre + code], capture_output=True,
                           text=True, env=env, cwd=d, timeout=300)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    finally:
        shutil.rmtree(d, ignore_errors=True)


RENDER_CODE = '''
import hashlib, json, sys
import mihomorender as M
model = json.loads(%r)
meta = json.loads(%r)
data, meta_out = M.render_bytes(model, rulesets=M.rulesets_arg(meta),
                                mitm_domains=[], tls_ports=None)
print("SHA:" + hashlib.sha256(data).hexdigest())
print("RS:" + json.dumps(M.rulesets_arg(meta), sort_keys=True))
print("BH:" + str(M.mrs_behavior(open(%r, "rb").read())))
print("LOADED_BOT:" + str(any(m in sys.modules for m in ("bot", "pdg_bot"))))
''' % (json.dumps(MODEL), json.dumps(META), os.path.join(FIXTURES, "behavior-domain.mrs"))


def parse(out):
    return {ln.split(":", 1)[0]: ln.split(":", 1)[1]
            for ln in out.splitlines() if ln.split(":", 1)[0] in ("SHA", "RS", "BH", "LOADED_BOT")}


# ══ 1. bot 正常时的基准 ═════════════════════════════════════════════════════
print("── 1. 依赖边界 ──")
rc, out = run_isolated(RENDER_CODE, bot_state="ok")
base = parse(out)
if rc == 0 and base.get("SHA"):
    ok("bot 正常时: 共享模块渲染成功")
else:
    bad("基准渲染失败 rc=%s: %s" % (rc, out[-400:]))
if base.get("LOADED_BOT") == "False":
    ok("共享模块渲染全程**没有**加载 pdg-bot(不是碰巧能用)")
else:
    bad("渲染过程里 bot 被加载了: %s" % base.get("LOADED_BOT"))

for label, state in (("pdg-bot.py 语法损坏", "broken"),
                     ("pdg-bot.py 根本不存在", "absent"),
                     ("禁止 import pdg-bot", "blocked")):
    rc, out = run_isolated(RENDER_CODE, bot_state=state)
    got = parse(out)
    if rc == 0 and got.get("SHA") == base.get("SHA"):
        ok("%s: 共享模块照常导入并渲染出**同样的字节**" % label)
    else:
        bad("%s: rc=%s sha=%s(基准 %s)\n%s" % (label, rc, got.get("SHA"),
                                              base.get("SHA"), out[-400:]))
    if got.get("RS") == base.get("RS") and got.get("BH") == base.get("BH"):
        ok("%s: rulesets_arg 与 mrs behavior 也完全一致" % label)
    else:
        bad("%s: rs/behavior 有差异 %s / %s" % (label, got.get("RS"), got.get("BH")))

# ══ 2. cfgrestore 的 deriver 在没有 bot 时仍能出候选 ═══════════════════════
print()
print("── 2. 配置恢复的 deriver 不依赖 bot ──")
DERIVE_CODE = '''
import hashlib, json, os, sys, tempfile
import mihomorender as M
d = tempfile.mkdtemp()
open(os.path.join(d, "platform"), "w").write("android\\n")
json.dump(json.loads(%r), open(os.path.join(d, "rulesets.json"), "w"))
fn = M.deriver_from_paths(rs_meta_path=os.path.join(d, "rulesets.json"),
                          mitm_hijack_file=os.path.join(d, "mitm_hijack.txt"),
                          platform_file=os.path.join(d, "platform"))
data = fn({"model": json.dumps(json.loads(%r)).encode()})
print("SHA:" + hashlib.sha256(data).hexdigest())
print("HASPROV:" + str("rs_yaml" in json.loads(data.decode())["rule-providers"]))
print("LOADED_BOT:" + str(any(m in sys.modules for m in ("bot", "pdg_bot"))))
''' % (json.dumps(META), json.dumps(MODEL))
for label, state in (("bot 正常", "ok"), ("pdg-bot.py 语法损坏", "broken"),
                     ("pdg-bot.py 不存在", "absent"), ("禁止 import pdg-bot", "blocked")):
    rc, out = run_isolated(DERIVE_CODE, bot_state=state)
    got = parse(out)
    hasprov = "HASPROV:True" in out
    if rc == 0 and got.get("SHA") and hasprov and got.get("LOADED_BOT") == "False":
        ok("deriver_from_paths(%s): 出候选成功、规则集进了配置、未加载 bot" % label)
    else:
        bad("deriver_from_paths(%s): rc=%s sha=%s prov=%s bot=%s\n%s"
            % (label, rc, got.get("SHA"), hasprov, got.get("LOADED_BOT"), out[-400:]))

# ══ 3. bot 与共享模块逐字节一致 ════════════════════════════════════════════
print()
print("── 3. bot 与共享实现逐字节一致 ──")
spec = iu.spec_from_file_location("bot", os.path.join(BOT_DIR, "pdg-bot.py"))
bot = iu.module_from_spec(spec)
sys.modules["bot"] = bot
spec.loader.exec_module(bot)
import mihomorender as M  # noqa: E402

work = tempfile.mkdtemp(prefix="sharedcmp.")
RS_PATH = os.path.join(work, "rulesets.json")
json.dump(META, open(RS_PATH, "w"))
bot.RS_META = RS_PATH
bot_rs = bot._mihomo_rulesets()
shared_rs = M.rulesets_arg(META)
if bot_rs == shared_rs:
    ok("_mihomo_rulesets 与 rulesets_arg 结果完全一致")
else:
    bad("两者不一致:\n  bot=%r\n  shared=%r" % (bot_rs, shared_rs))

_p = bot._platform
bot._platform = lambda: "android"
try:
    bot_bytes, _m = bot._render_mihomo_bytes(MODEL, rs_meta=META, mitm_domains=[])
finally:
    bot._platform = _p
shared_bytes, _m2 = M.render_bytes(MODEL, rulesets=shared_rs, mitm_domains=[], tls_ports=None)
if hashlib.sha256(bot_bytes).hexdigest() == hashlib.sha256(shared_bytes).hexdigest():
    ok("bot._render_mihomo_bytes 与 mihomorender.render_bytes 逐字节相同")
else:
    bad("渲染结果不同: bot=%s shared=%s" % (hashlib.sha256(bot_bytes).hexdigest()[:16],
                                          hashlib.sha256(shared_bytes).hexdigest()[:16]))

# ══ 4. 六个 monkeypatch 点仍然生效 ═════════════════════════════════════════
print()
print("── 4. bot 的 monkeypatch 入口仍然生效 ──")
# RS_META: 改成一份**不同的**元数据, 结果必须跟着变(共享模块不许自己去读固定路径)
ALT = {"rs_only": {"url": "https://alt.test/x.list"}}
ALT_PATH = os.path.join(work, "alt.json")
json.dump(ALT, open(ALT_PATH, "w"))
bot.RS_META = ALT_PATH
if bot._mihomo_rulesets() == M.rulesets_arg(ALT) and "rs_only" in bot._mihomo_rulesets():
    ok("monkeypatch bot.RS_META → _mihomo_rulesets 跟着变(共享模块没暗读固定路径)")
else:
    bad("patch RS_META 无效: %r" % bot._mihomo_rulesets())
bot.RS_META = RS_PATH

HJ = os.path.join(work, "hijack.txt")
open(HJ, "w").write("domain:patched.example.com\n")
bot.MITM_HIJACK_FILE = HJ
bot._platform = lambda: "ios"
try:
    if bot._mitm_domains() == ["patched.example.com"]:
        ok("monkeypatch bot.MITM_HIJACK_FILE → _mitm_domains 跟着变")
    else:
        bad("patch MITM_HIJACK_FILE 无效: %r" % bot._mitm_domains())
finally:
    bot._platform = _p

for name in ("mrs_behavior", "_mrs_behavior_of_file", "_mihomo_rulesets",
             "_mitm_domains", "_render_mihomo_bytes", "_mihomo_derive",
             "_fmt_dropped", "_panel_render_args", "MRS_BEHAVIORS"):
    if hasattr(bot, name):
        ok("bot.%s 仍然存在(既有调用方与测试的入口未被搬走)" % name)
    else:
        bad("bot.%s 不见了" % name)

# ══ 5. 无循环导入 ══════════════════════════════════════════════════════════
print()
print("── 5. 依赖方向 ──")
src = open(os.path.join(BOT_DIR, "mihomorender.py"), encoding="utf-8").read()
# 查真实 import, 不是查字符串 —— 模块的文档里本来就要说明"为什么不能依赖 pdg-bot",
# 拿子串匹配会把那段解释当成违规。
import ast  # noqa: E402
_imported = set()
for _n in ast.walk(ast.parse(src)):
    if isinstance(_n, ast.Import):
        _imported |= {a.name.split(".")[0] for a in _n.names}
    elif isinstance(_n, ast.ImportFrom) and _n.module:
        _imported.add(_n.module.split(".")[0])
_forbidden = _imported & {"bot", "pdg_bot", "checks", "report"}
if not _forbidden:
    ok("共享模块不 import bot/checks/report(实际 import 名单: %s)"
       % ", ".join(sorted(_imported)))
else:
    bad("共享模块引用了不该引用的模块: %s" % sorted(_forbidden))
rc, out = run_isolated("import mihomorender, cfgrestore; print('SHA:ok')", bot_state="blocked")
if rc == 0:
    ok("mihomorender 与 cfgrestore 在禁止 import bot 时都能加载(无循环导入)")
else:
    bad("加载失败: %s" % out[-300:])
# subprocess 纪律: 搬过来的 zstd 调用仍是固定 argv + 超时, 没有 shell
if "shell=True" not in src and 'subprocess.Popen(["zstd", "-dcq", tmp]' in src \
        and "wait(timeout=10)" in src:
    ok("zstd 子进程仍是固定 argv + 超时, 没有 shell=True")
else:
    bad("subprocess 纪律被改动了")

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

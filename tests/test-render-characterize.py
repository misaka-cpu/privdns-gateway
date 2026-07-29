#!/usr/bin/env python3
"""mihomo 渲染链的**特征测试**(characterization): 把当前行为逐字节钉住。

写它的时机很关键: 这是在把 mrs/zstd 识别与 ruleset 渲染从 pdg-bot.py 搬进共享模块**之前**
建立的基线。搬迁本身不该改变任何行为, 但"不该"和"没有"是两回事 —— 这个文件的职责就是让
"没有"变成可验证的: 同样的输入, 搬前搬后 behavior、rulesets_arg、dropped、unknown_proxies
与最终渲染出来的字节必须完全一致。

所以这里**不追求可读的高层断言, 追求精确**: 期望值是写死的字面量(取自搬迁前的真实实现),
不是"跟着实现算一遍再比"。后者永远绿, 什么都证明不了。

覆盖的输入矩阵(全部对应真实格式):
  · 规则集: .json / .yaml / .list(text) / .srs(拒) / format=binary(拒) / .mrs
  · .mrs 的 behavior: 元数据里有 / 元数据里没有(靠嗅探) / 文件不存在 / 不可读
  · zstd: 正常压缩 / 未压缩(防御分支) / 截断 / 损坏 / 空
  · RS_META: 正常 / JSON 损坏 / 文件不存在
  · MITM_HIJACK_FILE: 存在 / 缺失 / 空文件
  · 出口: 可转换 / mihomo 转换不了(unknown_proxies) / 规则被丢弃(dropped)
"""
import hashlib
import importlib.util as iu
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
os.environ.setdefault("PDG_BOT_TOKEN", "1:characterize")

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def eq(label, got, want):
    if got == want:
        ok(label)
    else:
        bad("%s\n        实得: %r\n        期望: %r" % (label, got, want))


def load_bot():
    spec = iu.spec_from_file_location("bot", os.path.join(ROOT, "deploy/bot/pdg-bot.py"))
    mod = iu.module_from_spec(spec)
    sys.modules["bot"] = mod
    spec.loader.exec_module(mod)
    return mod


bot = load_bot()
work = tempfile.mkdtemp(prefix="charrender.")


def fx(name):
    return os.path.join(FIXTURES, name)


# ══ 1. mrs_behavior: 二进制识别的完整真值表 ═════════════════════════════════
# 认不出一律 None —— **绝不猜默认值**。猜错的后果是"规则看着加了却永不命中", 比直接拒绝
# 难查得多; 这条纪律是这一簇代码存在的全部理由, 所以放在最前面钉死。
print("── 1. mrs_behavior 真值表 ──")
_zstd_frames = {
    "zstd 压缩的 domain .mrs": ("behavior-domain.mrs", "domain"),
    "zstd 压缩的 ipcidr .mrs": ("behavior-ipcidr.mrs", "ipcidr"),
    "未压缩的 .mrs(防御分支)": ("behavior-plain.mrs", "domain"),
    "既有 fixture: ruleset-domain": ("ruleset-domain.mrs", "domain"),
    "既有 fixture: ruleset-ipcidr": ("ruleset-ipcidr.mrs", "ipcidr"),
}
for label, (fname, want) in _zstd_frames.items():
    eq("mrs_behavior: %s → %s" % (label, want),
       bot.mrs_behavior(open(fx(fname), "rb").read()), want)

_domain_bytes = open(fx("behavior-domain.mrs"), "rb").read()
for label, data in (
        ("空字节", b""),
        ("完全不是 mrs", b"not an mrs at all"),
        ("zstd 帧被截断", _domain_bytes[:40]),
        ("zstd 帧内容损坏", b"\x28\xb5\x2f\xfd" + b"\x00" * 40),
        ("MRS 头但版本不是 1", b"MRS" + bytes([9]) + bytes([0]) + b"x" * 16),
        ("MRS 头但 behavior 字节未知", b"MRS" + bytes([1]) + bytes([7]) + b"x" * 16),
        ("不是 bytes(传了 str)", "MRS\x01\x00"),
):
    eq("mrs_behavior: %s → None(fail-closed, 不猜)" % label, bot.mrs_behavior(data), None)

# 压缩 fixture 必须是"只有真解压才认得出"的那种 —— 否则下面的负控(删掉 zstd 判定)会因为
# 兜底扫描碰巧还能还原头部而假绿。
_i = _domain_bytes.find(b"MRS", 0, 65536)
_scan_head = _domain_bytes[_i:_i + 8] if _i >= 0 else b""
if not (_scan_head[:3] == b"MRS" and len(_scan_head) >= 5 and _scan_head[3] == 1):
    ok("压缩 fixture 的头部无法靠字节扫描还原(保证下面验的是真解压路径)")
else:
    bad("压缩 fixture 可被扫描还原 —— 这个 fixture 证明不了 zstd 路径")

# ══ 2. _mihomo_rulesets: 逐条目的分类与取舍 ════════════════════════════════
print()
print("── 2. _mihomo_rulesets 分类真值表 ──")
META = {
    "rs_json":    {"url": "https://ex.test/a.json", "path": work + "/a.json"},
    "rs_yaml":    {"url": "https://ex.test/b.yaml", "path": work + "/b.yaml"},
    "rs_yml":     {"url": "https://ex.test/b2.yml", "path": work + "/b2.yml"},
    "rs_txt":     {"url": "https://ex.test/c.list", "path": work + "/c.list"},
    "rs_srs":     {"url": "https://ex.test/d.srs", "path": work + "/d.srs"},
    "rs_bin":     {"url": "https://ex.test/i.dat", "format": "binary", "path": work + "/i.dat"},
    # 元数据里已记 behavior: **元数据说了算**, 不去嗅探(哪怕文件里其实是 domain)
    "rs_mrs_bh":  {"url": "https://ex.test/e.mrs", "behavior": "ipcidr",
                   "path": fx("behavior-domain.mrs")},
    # 元数据没记 behavior(老条目): 从本地文件嗅探
    "rs_mrs_no":  {"url": "https://ex.test/f.mrs", "path": fx("behavior-domain.mrs")},
    "rs_mrs_ip":  {"url": "https://ex.test/g.mrs", "path": fx("behavior-ipcidr.mrs")},
    # 没记 behavior 且本地文件不在 → 认不出 → 整条跳过(交由 dropped 点名)
    "rs_mrs_gone": {"url": "https://ex.test/h.mrs", "path": work + "/missing.mrs"},
    # 没记 behavior 且本地文件不可读 → 同上
    "rs_mrs_noperm": {"url": "https://ex.test/j.mrs", "path": work + "/noperm.mrs"},
}
open(work + "/noperm.mrs", "wb").write(_domain_bytes)
os.chmod(work + "/noperm.mrs", 0o000)

RS_META_PATH = os.path.join(work, "rulesets.json")
json.dump(META, open(RS_META_PATH, "w"))
bot.RS_META = RS_META_PATH                       # ← 既有 monkeypatch 点, 必须继续生效

# 搬迁前实现的**真实输出**(字面量, 不是算出来的)
EXPECT_RULESETS = {
    "rs_json":   {"url": "https://ex.test/a.json", "behavior": "classical", "format": "text"},
    "rs_yaml":   {"url": "https://ex.test/b.yaml", "behavior": "classical", "format": "yaml"},
    "rs_yml":    {"url": "https://ex.test/b2.yml", "behavior": "classical", "format": "yaml"},
    "rs_txt":    {"url": "https://ex.test/c.list", "behavior": "classical", "format": "text"},
    "rs_mrs_bh": {"url": "https://ex.test/e.mrs", "behavior": "ipcidr", "format": "mrs"},
    "rs_mrs_no": {"url": "https://ex.test/f.mrs", "behavior": "domain", "format": "mrs"},
    "rs_mrs_ip": {"url": "https://ex.test/g.mrs", "behavior": "ipcidr", "format": "mrs"},
}
got = bot._mihomo_rulesets()
eq("_mihomo_rulesets: 逐条目内容逐字节一致", got, EXPECT_RULESETS)
eq("_mihomo_rulesets: 键集合(.srs/binary/认不出的 .mrs 一律不出现)",
   sorted(got), sorted(EXPECT_RULESETS))
# 顺序也钉住: dict 有序, 搬迁后遍历顺序变了会改渲染出来的字节
eq("_mihomo_rulesets: 键的顺序与元数据一致", list(got), list(EXPECT_RULESETS))
eq("_mihomo_rulesets: 元数据已记 behavior 时不去嗅探文件(元数据说了算)",
   got["rs_mrs_bh"]["behavior"], "ipcidr")
eq("_mihomo_rulesets: 元数据没记 behavior 时从文件嗅探",
   got["rs_mrs_no"]["behavior"], "domain")

# RS_META 本身损坏 / 不存在 → 返回空 dict, 不抛异常(渲染仍能进行, 规则集进 dropped)
open(RS_META_PATH, "w").write("{ 这不是合法 JSON")
eq("_mihomo_rulesets: RS_META 是坏 JSON → {}(不抛异常)", bot._mihomo_rulesets(), {})
bot.RS_META = os.path.join(work, "does-not-exist.json")
eq("_mihomo_rulesets: RS_META 不存在 → {}", bot._mihomo_rulesets(), {})
bot.RS_META = RS_META_PATH
json.dump(META, open(RS_META_PATH, "w"))
# 显式传入 meta 时不读盘(供事务用**候选** rs_meta 渲染)
bot.RS_META = os.path.join(work, "does-not-exist.json")
eq("_mihomo_rulesets(meta=...): 显式传入时不读盘", bot._mihomo_rulesets(META), EXPECT_RULESETS)
bot.RS_META = RS_META_PATH

# ══ 3. _mitm_domains: 平台门控 + 文件三态 ══════════════════════════════════
print()
print("── 3. _mitm_domains(平台 × 文件状态)──")
HJ = os.path.join(work, "mitm_hijack.txt")
bot.MITM_HIJACK_FILE = HJ                        # ← 既有 monkeypatch 点
open(HJ, "w").write("domain:gs-loc.apple.com\n# 注释\n\ndomain:gs-loc-cn.apple.com\n")
_plat = bot._platform
try:
    bot._platform = lambda: "android"
    eq("_mitm_domains: Android 平台恒空(不看文件)", bot._mitm_domains(), [])
    bot._platform = lambda: "ios"
    eq("_mitm_domains: iOS + 文件存在 → 去 domain: 前缀, 跳过注释与空行",
       bot._mitm_domains(), ["gs-loc.apple.com", "gs-loc-cn.apple.com"])
    open(HJ, "w").write("")
    eq("_mitm_domains: iOS + 空文件 → []", bot._mitm_domains(), [])
    os.remove(HJ)
    eq("_mitm_domains: iOS + 文件不存在 → [](不抛异常)", bot._mitm_domains(), [])
finally:
    bot._platform = _plat

# ══ 4. 整链渲染: 逐字节 + dropped / unknown_proxies ════════════════════════
print()
print("── 4. _render_mihomo_bytes / _mihomo_derive 整链 ──")
BASE_MODEL = {
    "log": {"level": "warn"},
    "inbounds": [],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "shadowsocks", "tag": "ss1", "server": "1.2.3.4", "server_port": 8388,
         "method": "aes-128-gcm", "password": "PW-SENTINEL"},
    ],
    "route": {"rules": [{"domain_suffix": ["ex.test"], "outbound": "ss1"}], "final": "direct"},
}


def render(model, meta=None, mitm=None, platform="android"):
    """固定所有环境输入后渲染 —— 结果必须只由入参决定(不受本机 /etc 影响)。"""
    _p = bot._platform
    bot._platform = lambda: platform
    try:
        return bot._render_mihomo_bytes(model, rs_meta=meta, mitm_domains=mitm or [])
    finally:
        bot._platform = _p


data_a, meta_a = render(BASE_MODEL, meta={})
SHA_NO_RS = hashlib.sha256(data_a).hexdigest()
eq("渲染: 无规则集时 dropped 为空", (meta_a or {}).get("dropped") or [], [])
eq("渲染: 无规则集时 unknown_proxies 为空", (meta_a or {}).get("unknown_proxies") or [], [])
# 逐字节锚点: 同一份输入必须永远产出同一串字节(搬迁后这一条最能说明问题)
eq("渲染: 同一输入两次渲染逐字节一致",
   hashlib.sha256(render(BASE_MODEL, meta={})[0]).hexdigest(), SHA_NO_RS)
if SHA_NO_RS == hashlib.sha256(render(BASE_MODEL, meta=META)[0]).hexdigest():
    bad("带规则集与不带规则集渲染出了同样的字节 —— 规则集根本没进配置")
else:
    ok("渲染: 规则集确实进入了渲染结果(两种输入产出不同字节)")
data_b, meta_b = render(BASE_MODEL, meta=META)
SHA_WITH_RS = hashlib.sha256(data_b).hexdigest()
cfg_b = json.loads(data_b.decode("utf-8"))
eq("渲染: rule-providers 名单与 _mihomo_rulesets 一致",
   sorted(cfg_b.get("rule-providers") or {}), sorted(EXPECT_RULESETS))
eq("渲染: 每个 provider 的 behavior/format 逐条一致",
   {k: {"behavior": v.get("behavior"), "format": v.get("format")}
    for k, v in (cfg_b.get("rule-providers") or {}).items()},
   {k: {"behavior": v["behavior"], "format": v["format"]} for k, v in EXPECT_RULESETS.items()})

# iOS 与 Android 的渲染必须不同(tls_ports 差异) —— 平台入参是真的在起作用
if hashlib.sha256(render(BASE_MODEL, meta={}, platform="ios")[0]).hexdigest() != SHA_NO_RS:
    ok("渲染: iOS 与 Android 产出不同字节(平台入参生效)")
else:
    bad("iOS/Android 渲染无差别 —— 平台入参没起作用")

# unknown_proxies: mihomo 转换不了的出口必须被点名, 不能静默丢
MODEL_BAD_OUT = json.loads(json.dumps(BASE_MODEL))
MODEL_BAD_OUT["outbounds"].append({"type": "wireguard", "tag": "wg1",
                                   "server": "1.1.1.1", "server_port": 1})
_d, meta_bad = render(MODEL_BAD_OUT, meta={})
eq("渲染: 无法转换的出口进 unknown_proxies 并点名",
   sorted((meta_bad or {}).get("unknown_proxies") or []), ["wg1"])

# dropped: 指向未知规则集的规则必须被记下来
MODEL_DROP = json.loads(json.dumps(BASE_MODEL))
# rule_set 在本项目里是**标量字符串**(sb2mihomo._rules_from_route 这么消费)
MODEL_DROP["route"]["rules"].append({"rule_set": "rs_not_declared", "outbound": "ss1"})
_d2, meta_drop = render(MODEL_DROP, meta={})
if (meta_drop or {}).get("dropped"):
    ok("渲染: 无法进入运行配置的规则被记入 dropped")
else:
    bad("未声明的规则集没有进 dropped —— 会被静默丢弃")

# deriver: dropped / unknown_proxies 一律判废并**点名**(不是静默成功)
print()
print("── 5. _mihomo_derive 判废 ──")
good = bot._mihomo_derive({"model": json.dumps(BASE_MODEL).encode()})
eq("deriver: 正常 model → 产出与直接渲染一致的字节",
   hashlib.sha256(good).hexdigest(),
   hashlib.sha256(render(BASE_MODEL, meta=bot._mihomo_rulesets())[0]).hexdigest())
for label, model, kw in (("无法转换的出口", MODEL_BAD_OUT, "wg1"),
                         ("无法进入配置的规则集", MODEL_DROP, "rs_not_declared")):
    try:
        bot._mihomo_derive({"model": json.dumps(model).encode()})
        bad("deriver: %s 竟然通过了(会被静默丢弃)" % label)
    except Exception as e:  # noqa: BLE001
        if kw in str(e):
            ok("deriver: %s → 判废并点名(%s)" % (label, kw))
        else:
            bad("deriver: %s 判废了但没点名: %s" % (label, str(e)[:120]))
# 候选 rs_meta 优先于现网文件
staged = {"model": json.dumps(BASE_MODEL).encode(),
          "rs_meta": json.dumps({"rs_yaml": META["rs_yaml"]}).encode()}
cfg_staged = json.loads(bot._mihomo_derive(staged).decode("utf-8"))
eq("deriver: 候选 rs_meta 优先于现网 RS_META",
   sorted(cfg_staged.get("rule-providers") or {}), ["rs_yaml"])

# 凭据不得进入渲染产物之外的任何地方(渲染产物里出口密码是必需的, 但 meta 不该带)
if "PW-SENTINEL" not in json.dumps(meta_b or {}) and "PW-SENTINEL" not in json.dumps(meta_a or {}):
    ok("渲染 meta 不含出口密码哨兵")
else:
    bad("渲染 meta 泄漏了出口密码")

# ══ 6. 逐字节锚点 ═══════════════════════════════════════════════════════════
# 搬迁前实现的真实产出摘要, 写死在这里。搬完之后这两条必须**原样通过** —— 那就是"行为没变"
# 的证据。若将来 sb2mihomo 本身有意改了渲染, 这里会红, 那时应当**先确认改动是有意的**再
# 重新取基线, 而不是顺手把期望值改掉。
print()
print("── 6. 逐字节锚点 ──")
ANCHOR_NO_RS = "1343b7b40df2e6d495fe88ef0295d424d67ae60bd61bf00c0e1489c678646af9"
ANCHOR_WITH_RS = "bbb893af2d402378d4273cee606ca2fe06d17e5125b69c41e3ab3e995896476f"
eq("锚点: 无规则集渲染的字节摘要", SHA_NO_RS, ANCHOR_NO_RS)
eq("锚点: 带全套规则集渲染的字节摘要", SHA_WITH_RS, ANCHOR_WITH_RS)

os.chmod(work + "/noperm.mrs", 0o600)
shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

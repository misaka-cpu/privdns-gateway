#!/usr/bin/env python3
"""WLOC 退役 · 执行面与用户入口的闭合判据。

上一支(test-wloc-retire-ca-readonly)只管住了 CA 那一个底层接口。光有它, 分支是**半退役**:
签发接口没了, 而 mitm_server / pdg-bot 还在调它 —— 这种中间态比退役前更坏, 因为它既不能装,
也没有把能力真的撤掉。这支管的就是"退役到底了没有", 分四个方向:

  一、**执行能力不在了**: 专属插件与服务宿主从仓库消失, 专属 unit 不再生成。
  二、**没有悬空调用**: 正常运行路径不再引用任何已删接口 —— 判据是"产品源零引用 + 全部
      能编译", 不是"看着像没了"。
  三、**用户入口只剩退役提示**: 旧消息里的按钮还会被点(TG 消息不会自己消失), 点了必须得到
      一句能照着做的话, 而且**一个字节都不写**。
  四、**装不回来**: 新装不装这些文件; 渲染即便读到一份残留的 gs-loc 劫持表也不注入 MITM 路由。

第四条是本支的重点负控。前三条都是"东西没了", 而"没了"很容易被一条残留数据绕回去:
mitm_hijack.txt 是**用户机器上的文件**, 退役迁移撤它, 但迁移可能没跑到、可能被还原、也可能
被手工放回去。渲染器如果照旧读它, WLOC 的流量路径就在一台"已退役"的机器上自己长了回来 ——
界面上没有任何按钮, 日志里没有任何动作, 而 7894 上的转发是真的。所以这里喂它一份非空的
劫持表, 盯死渲染结果里既没有 MITM-OUT 出站、也没有 gs-loc 规则、更没有 7894。
"""
import importlib.util as u
import json
import os
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy" / "bot"

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   " + m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] " + m)


def chk(cond, m):
    (ok if cond else bad)(m)


def text_of(p):
    try:
        return Path(p).read_text(encoding="utf-8")
    except OSError:
        return ""


# 产品源 = 会被装到机器上、或参与装机决策的东西。tests/ 不算: 测试引用旧接口是它自己的事,
# 该删的测试在测试处置那一轮统一收口, 混进来会让"运行路径还有没有悬空调用"这个判据失焦。
def product_sources():
    out = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs
                   if d not in (".git", "tests", "__pycache__", ".github")]
        for f in files:
            if f.endswith((".py", ".sh", ".yaml", ".yml")):
                out.append(os.path.join(base, f))
    return sorted(out)


PRODUCT = product_sources()

# ══ 1. 执行能力: 专属插件、服务宿主、专属 unit ════════════════════════════════
print("══ 1. 执行能力已移除 ══")

for rel in ("deploy/bot/mitm_wloc.py", "deploy/bot/mitm_server.py"):
    chk(not (ROOT / rel).exists(), "%s 已从仓库移除" % rel)

units = text_of(ROOT / "lib/units.sh")
chk("pdg_unit_pdg_mitm" not in units, "lib/units.sh 不再生成 pdg-mitm 的 unit")
chk("7894" not in units, "lib/units.sh 里不再有 MITM 监听端口")

# ══ 2. 没有悬空调用, 且产品源全部可编译 ══════════════════════════════════════
print()
print("══ 2. 无悬空调用 ══")

GONE_API = ("ensure_ca", "leaf_cert", "prewarm", "ca_cert_pem", "_gen_ca", "_sign_leaf")
hits = []
for p in PRODUCT:
    if os.path.basename(p) == "mitm_ca.py":
        continue                       # 它自己的模块文档要说明这些接口为什么没了
    src = text_of(p)
    for api in GONE_API:
        if re.search(r"\b" + re.escape(api) + r"\s*\(", src):
            hits.append("%s:%s" % (os.path.relpath(p, ROOT), api))
chk(not hits, "产品源不再调用已删的签发接口(实得 %s)" % (hits or "0 处"))

mod_hits = []
for p in PRODUCT:
    src = text_of(p)
    for mod in ("mitm_wloc", "mitm_server"):
        if re.search(r"(^|\W)import\s+" + mod + r"\b", src, re.M):
            mod_hits.append("%s:%s" % (os.path.relpath(p, ROOT), mod))
chk(not mod_hits, "产品源不再 import 已删模块(实得 %s)" % (mod_hits or "0 处"))

# 字节码落到**本轮独占**的临时目录, 不是 /tmp 下一个固定文件名。固定名字有两个真问题:
# 并发跑两支测试时互相覆盖(结果取决于谁最后写), 以及别的用户先建了同名文件时这里会因为
# 权限直接炸 —— 两种都表现成"编译失败", 而实际上源码好好的。
_pyc_dir = tmpguard.mkdtemp(prefix="pdg-wloc-pyc.")
bad_compile = []
for p in sorted(BOT.glob("*.py")):
    try:
        py_compile.compile(str(p), cfile=os.path.join(_pyc_dir, p.name + "c"),
                           doraise=True)
    except py_compile.PyCompileError as e:
        bad_compile.append("%s(%s)" % (p.name, type(e).__name__))
chk(not bad_compile, "deploy/bot/*.py 全部可编译(实得坏 %s)" % (bad_compile or "0 个"))

# ══ 3. 装机清单: 新装不装, 卸载仍收走 ════════════════════════════════════════
print()
print("══ 3. 新装不装 / 卸载仍收走 ══")

mods = text_of(ROOT / "lib/modules.sh")


def _block(name):
    m = re.search(name + r'="(.*?)"', mods, re.S)
    return m.group(1) if m else ""


ios_blk, legacy_blk = _block("PDG_IOS_MODULES"), _block("PDG_LEGACY_MODULES")
for f in ("mitm_server.py", "mitm_wloc.py"):
    chk(f not in ios_blk, "PDG_IOS_MODULES 不再安装 %s" % f)
    # 卸载要收走: 老机器上躺着一份不再被任何东西调用的 MITM 宿主, 既误导人, 也让
    # "卸载干净了吗"没有确定答案。项目已有 PDG_LEGACY_MODULES 就是干这个的。
    chk(f in legacy_blk, "PDG_LEGACY_MODULES 仍收走老机器上的 %s" % f)

pdgsh = text_of(BOT / "pdg.sh")
inst = re.findall(r'"deploy/bot/(mitm_server|mitm_wloc)\.py\|', pdgsh)
chk(not inst, "pdg.sh 的安装清单不再部署 MITM 宿主与插件(实得 %s)" % (inst or "0 条"))

# ══ 3b. 新装: 既不安装, 也不启动 ════════════════════════════════════════════
# 装机脚本是**另一条**路径(不经 pdg.sh 的平台切换、也不经迁移)。漏改它的后果不是报错 ——
# 是每一台新装的 iOS 机器都会去写一个已经不存在的 unit 生成器, 或者去 enable 一个没有
# unit 文件的服务。第一种当场失败, 第二种静默留下"该服务应存在"的错觉。
ins = text_of(ROOT / "install.sh")
ins_code = "\n".join(l for l in ins.splitlines() if not l.lstrip().startswith("#"))
chk("pdg_unit_pdg_mitm" not in ins_code, "install.sh 不再写 pdg-mitm 的 unit")
chk("enable --now pdg-mitm" not in ins_code, "install.sh 不再启动 pdg-mitm")
# 卸载与失败回滚这两条**相反**: 老机器上那份 unit 还在, 收不走就留下一个孤儿服务。
chk("pdg-mitm" in text_of(ROOT / "uninstall.sh"), "uninstall.sh 仍然收走老机器上的 pdg-mitm")
chk("pdg-mitm.service" in ins, "install.sh 的失败回滚清单里仍列着 pdg-mitm(重装前的残留要收走)")

# ══ 4. 事务层不再具备 pdg-mitm 的目标态能力 ══════════════════════════════════
print()
print("══ 4. 事务层 ══")

sys.path.insert(0, str(BOT))
import pdgtx  # noqa: E402

chk("pdg-mitm" not in pdgtx._SERVICE_UNITS,
    "pdgtx 不再把 pdg-mitm 当可操作服务(实得 %s)" % (pdgtx._SERVICE_UNITS,))
chk("pdg-mitm" not in getattr(pdgtx, "_STATE_UNITS", ()),
    "pdgtx 不再给 pdg-mitm 开 start/stop 目标态(实得 %s)"
    % (getattr(pdgtx, "_STATE_UNITS", ()),))
left = [a for a in pdgtx._ACTIONS if "pdg-mitm" in a]
chk(not left, "事务动作表里没有 pdg-mitm 动作(实得 %s)" % (left or "0 个"))

# ══ 5. 用户入口: 只剩退役提示, 且零副作用 ════════════════════════════════════
print()
print("══ 5. 用户入口 ══")

ROOTFS = tmpguard.mkdtemp(prefix="pdg-wloc-retire.")
os.makedirs(os.path.join(ROOTFS, "etc", "privdns-gateway"), exist_ok=True)
os.makedirs(os.path.join(ROOTFS, "run"), exist_ok=True)
PROFILE = os.path.join(ROOTFS, "etc", "privdns-gateway", "profile.env")
Path(PROFILE).write_text("PDG_INTERNAL_CIDR=127.0.0.0/8\nPDG_SERVER_IP=127.0.0.1\n",
                         encoding="utf-8")
os.environ["PDG_PROFILE_ENV"] = PROFILE
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = os.path.join(ROOTFS, "run", "privdns-gateway.lock")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")
os.environ.setdefault("PDG_BOT_TOKEN", "1:retire")

_spec = u.spec_from_file_location("pdg_bot_retire", str(BOT / "pdg-bot.py"))
bot = u.module_from_spec(_spec)
_spec.loader.exec_module(bot)
BOTSRC = text_of(BOT / "pdg-bot.py")

EDITS, SENDS, PLAIN = [], [], []
TX_CALLS = []


def setup(platform="ios"):
    for x in (EDITS, SENDS, PLAIN):
        x.clear()
    TX_CALLS.clear()
    bot.state.clear()
    bot.edit = lambda chat, mid, t, kb=None: EDITS.append((t, kb))
    bot.edit_only = lambda chat, mid, t, kb=None: (EDITS.append((t, kb)) or True)
    bot.send = lambda chat, t, kb=None: SENDS.append((t, kb))
    bot.send_plain = lambda chat, t: PLAIN.append(t)
    bot.answer_cb_async = lambda *a, **k: None
    bot.status_text = lambda: "(主菜单)"
    bot.post = lambda method, payload=None, **kw: {"ok": True}
    bot._platform = lambda: platform
    # 指进沙箱: 生产常量写死 /etc, 不改的话这支测试会去动真实系统 —— 而且崩掉之后
    # 后面两节根本跑不到, 负控就没牙了(崩溃产生 traceback, 不是具名失败行)。
    bot.MITM_CONFIG = os.path.join(ROOTFS, "etc", "privdns-gateway", "mitm.json")
    # 事务被开起来就是失败: 退役提示不该动任何配置。用探针而不是"看返回值",
    # 因为"提示对了但顺手跑了一笔事务"照样是退役没做干净。
    def _no_tx(*a, **k):
        TX_CALLS.append(a)
        raise AssertionError("退役路径不该开事务")
    bot._pdgtx = _no_tx


def all_text():
    return "\n".join([t for t, _ in EDITS] + [t for t, _ in SENDS] + list(PLAIN))


def buttons():
    out = []
    for _, kb in EDITS + SENDS:
        for row in (kb or {}).get("inline_keyboard", []) if isinstance(kb, dict) else []:
            for b in row:
                out.append((b.get("text", ""), b.get("callback_data", "")))
    return out


def cb(data, chat=1):
    try:
        bot.handle_cb(chat, 2, data, 1)
    except TypeError:
        bot.handle_cb(chat, 2, data)
    except Exception as e:  # noqa: BLE001
        bad("handle_cb(%s) 抛 %s: %s" % (data, type(e).__name__, str(e)[:60]))


# 菜单入口
setup()
bot.handle_text(1, "/start", 3)
setup()
try:
    _t, kb = bot._nav("ops")
except Exception as e:  # noqa: BLE001
    kb = {}
    bad("_nav('ops') 抛 %s" % type(e).__name__)
ops_btns = [b.get("callback_data", "")
            for row in (kb or {}).get("inline_keyboard", []) for b in row]
chk(not [d for d in ops_btns if d.startswith("wloc")],
    "运维菜单里没有 WLOC 按钮(实得 %s)" % ([d for d in ops_btns if d.startswith("wloc")] or "0 个"))

# 旧消息里的按钮: 每一个都必须给退役提示, 而不是堆栈 / 沉默 / 照旧执行
OLD_CBS = ["wloc", "wloc:menu", "wloc:on", "wloc:off", "wloc:list",
           "wloc:add", "wloc:del", "wloc:sw:0", "wloc:rm:0"]
no_notice, silent = [], []
for d in OLD_CBS:
    setup()
    cb(d)
    t = all_text()
    if not t.strip():
        silent.append(d)
    elif "退役" not in t:
        no_notice.append(d)
chk(not silent, "旧 WLOC 按钮没有一个是静默吞掉的(实得静默 %s)" % (silent or "0 个"))
chk(not no_notice, "旧 WLOC 按钮都回退役提示(实得没提示 %s)" % (no_notice or "0 个"))

# 提示必须可操作: 光说"已退役"不够, 得说清"你手机上那份描述文件/那张 CA 怎么办"。
setup()
cb("wloc")
notice = all_text()
chk("退役" in notice and ("描述文件" in notice or "证书" in notice),
    "退役提示里交代了描述文件/证书这一侧要做什么")
chk(not TX_CALLS, "退役提示没有开配置事务(实得 %d 次)" % len(TX_CALLS))

# 提示里不该再挂一个能回到 WLOC 的按钮 —— 那是把退役做成了改文案。
setup()
cb("wloc")
back = [d for _, d in buttons() if d.startswith("wloc")]
chk(not back, "退役提示的键盘不再指回 WLOC(实得 %s)" % (back or "0 个"))

# 非 iOS 机器点旧按钮也不能崩
setup(platform="android")
cb("wloc")
chk(all_text().strip() != "", "Android 上点旧 WLOC 按钮同样有回话, 不是沉默")

# 裸发「名称 纬度,经度」: 退役后不该再被当成加地点
setup()
before = sorted(os.listdir(os.path.join(ROOTFS, "etc", "privdns-gateway")))
try:
    bot.handle_text(1, "东京 35.6812,139.7671", 3)
except Exception as e:  # noqa: BLE001
    bad("裸发坐标抛 %s: %s" % (type(e).__name__, str(e)[:70]))
after = sorted(os.listdir(os.path.join(ROOTFS, "etc", "privdns-gateway")))
chk(before == after, "裸发坐标不再落地成地点(目录前后一致)")
chk("mitm.json" not in after, "裸发坐标没有造出 mitm.json")

# 源码层: 不该还留着 wloc_add / wloc_enable 这类能改配置的后端
live = re.findall(r"^def (wloc_[a-z_]+|set_wloc|_mitm_transact)\(", BOTSRC, re.M)
chk(not live, "pdg-bot 里不再有能改 WLOC 配置的后端函数(实得 %s)" % (live or "0 个"))

# ══ 6. 防复活: 残留劫持表不该把 MITM 路由长回来 ══════════════════════════════
print()
print("══ 6. 残留数据不复活 MITM 路由 ══")

import mihomorender as M  # noqa: E402

MODEL = {
    "log": {"level": "warn"},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"},
                  {"type": "shadowsocks", "tag": "ss1", "server": "1.2.3.4",
                   "server_port": 8388, "method": "aes-128-gcm", "password": "PW"}],
    "route": {"rules": [{"domain_suffix": ["ex.test"], "outbound": "ss1"}], "final": "direct"},
}

d = tmpguard.mkdtemp(prefix="pdg-wloc-render.")
hij = os.path.join(d, "mitm_hijack.txt")
# 一台"迁移没跑到 / 被还原回来 / 被手工放回去"的机器上的残留
Path(hij).write_text("domain:gs-loc.apple.com\ndomain:gs-loc-cn.apple.com\n", encoding="utf-8")
plat = os.path.join(d, "platform")
Path(plat).write_text("ios\n", encoding="utf-8")

# 先把注入入口本身钉死: 传得进去就说明这条路还在, 那么"渲染结果干净"只是因为这次没传。
try:
    M.deriver_from_paths(rs_meta_path=os.path.join(d, "rs.json"), mitm_hijack_file=hij,
                         platform_file=plat, lan_table_file=os.path.join(d, "lan.json"))
    bad("deriver_from_paths 仍收 mitm_hijack_file —— 注入入口还在")
except TypeError:
    ok("deriver_from_paths 不再收 mitm_hijack_file(注入入口已删)")

# 再看实际行为: 那份残留就摆在盘上的标准位置, 渲染器必须**根本不去读它**。
deriver = M.deriver_from_paths(rs_meta_path=os.path.join(d, "rs.json"),
                               platform_file=plat,
                               lan_table_file=os.path.join(d, "lan.json"))
try:
    out = deriver({"model": json.dumps(MODEL).encode("utf-8")}).decode("utf-8")
except Exception as e:  # noqa: BLE001
    out = ""
    bad("渲染抛 %s: %s" % (type(e).__name__, str(e)[:80]))

chk("MITM-OUT" not in out, "残留劫持表在场时渲染不出 MITM-OUT 出站")
chk("gs-loc" not in out, "残留劫持表在场时渲染不出 gs-loc 路由规则")
chk("7894" not in out, "渲染结果里没有 MITM 监听端口 7894")

# 渲染器自己也不该再有这条入口 —— 留着参数就是留着一条"传进来就生效"的路。
chk(not hasattr(M, "read_mitm_domains"),
    "mihomorender 不再提供 read_mitm_domains 这个读劫持表的入口")
chk(not hasattr(M, "MITM_PORT"), "mihomorender 里没有 MITM 端口常量了")
sb = text_of(BOT / "sb2mihomo.py")
chk("mitm_domains" not in sb, "sb2mihomo 不再接受 mitm_domains 参数")

# ══ 7. 巡检面 ════════════════════════════════════════════════════════════════
print()
print("══ 7. 巡检面 ══")

chks = text_of(BOT / "checks.py")
for fn in ("check_mitm_structure", "check_mitm"):
    chk(("def %s(" % fn) not in chks, "checks.py 不再定义 %s" % fn)
reg = re.search(r"check_mitm\w*", chks)
chk(reg is None, "巡检注册表里没有 MITM 项(实得 %s)" % (reg.group(0) if reg else "无"))

print()
print("[SUM] OK=%d FAIL=%d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

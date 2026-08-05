#!/usr/bin/env python3
"""越界结论的通用闸门: 手机侧证据能支撑的结论**上限**。

6.1B 只有两类手机侧证据 —— "服务器观察到本次会话的 HTTP 请求"与"该请求来自配置的内网卡
来源段"。这两条都**不能**推出 SIM 正常、APN 正常、DoT 正常、移动网络正常或整体链路正常;
DNS 侧证据本版本根本收不到(见 [[test-link-dns-evidence]] 与 docs/ROADMAP.md)。

为什么要单独一支: 逐处钉字面量管不住"下一处新写的文案"。这里从**用户真正看到的输出**
入手 —— 渲染出来的 `pdg link status` 全文、CLI 两步说明、Bot 自检文本 —— 对越界结论做
统一扫描。判据是"每次出现都紧跟否定", 而不是"全文别处有免责句": 后者会让一句
"DoT 正常" 靠十行之外的免责声明蒙混过关。

同时守住反方向: `NOT_OBSERVED` 既不能被写成故障(用户会去修一个不存在的问题), 也不能
影响服务器层退出码(脚本会据此误报警)。
"""
import atexit
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

pass_n = fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   " + m)
    pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] " + m)
    fail_n += 1


# 断言"手机侧证据 → 这些结论"永远不成立。允许出现的唯一形态是紧跟否定词
# ("不能据此判断 SIM/APN…"合法, "SIM/APN 正常"裸用不合法)。
OVERREACH = ("SIM 正常", "APN 正常", "SIM/APN 正常", "DoT 正常", "DoT 已通",
             "手机网络正常", "移动网络正常", "链路完全正常", "链路正常",
             "整体联网正常", "手机已连通", "运营商私网正常")
# 否定与被否定的词之间**不能有句读**(。;；换行) —— 这是"同一句话里被否掉"的判据。
# 回看窗口放宽到 40 字: 一句话可以一次否掉一串("不能证明 DoT、SIM/APN 或整体联网正常"),
# 14 字够不到那个"不", 会把正确写法判成越界。窗口再宽也仍受"中间无句读"约束, 隔壁
# 句子的否定词借不过来 —— 下面 6 节有负控盯着这一点。
_NEG = re.compile(r"[不没未无][^。;；\n]{0,40}$")


def scan(text, where):
    """逐次命中检查: 每一处越界词都必须紧跟在否定语境之后。"""
    bare = []
    for w in OVERREACH:
        for m in re.finditer(re.escape(w), text):
            lead = text[max(0, m.start() - 48):m.start()]
            if not _NEG.search(lead):
                bare.append((w, text[max(0, m.start() - 16):m.end() + 6]))
    (ok if not bare else bad)(
        "%s: 没有裸用的越界结论(裸用 %d 处%s)"
        % (where, len(bare), "" if not bare else ": %r" % (bare[:2],)))
    return not bare


print("── 1. pdg link status 的渲染全文 ──")
_rt = tmpguard.mkdtemp(prefix="linkcopy.")
atexit.register(shutil.rmtree, _rt, True)   # 测试自己不许留残留
os.environ.setdefault("PDG_LINK_RUNTIME", _rt)
import linkstat as L  # noqa: E402

# 不依赖真机: 直接用模型构造四类手机侧证据, 渲染成用户看到的样子。
def F(layer, code, status, title, detail):
    return L.Finding(layer, code, status, None, title, detail,
                     evidence_source="test")


samples = {
    "已观察": F(1, "L1_HTTP_PROBE_OBSERVED", L.PASS, "手机 HTTP 探测到达",
              "服务器观察到本次会话的 HTTP 请求(会话 x)。这只说明该请求到达了网关的 :81, "
              "不能据此判断 SIM/APN、DoT 或手机整体联网是否正常。"),
}
txt = L.render_text(list(samples.values()))
scan(txt, "link status(已观察)")
(ok if "手机/SIM 实时证据" in txt else bad)("渲染分成服务器/手机两段")

# 真实渲染路径: 无会话时的默认文案也要过一遍同一把尺子
txt0 = L.render_text([F(1, "L1_NOT_OBSERVED", L.NOT_OBSERVED, "手机 HTTP 探测到达",
                        "当前没有诊断会话, 所以没有观察。这不代表链路有问题。")])
scan(txt0, "link status(无会话)")
(ok if "尚未观察" in txt0 else bad)("无证据时说明「尚未观察」而不是判故障")

print()
print("── 2. 源码里所有手机侧 Finding 的 detail ──")
src = (ROOT / "deploy/bot/linkstat.py").read_text(encoding="utf-8")
phone_block = src[src.find("def _l1_private_traffic"):src.find("def _l2_cidr")]
scan(phone_block, "linkstat 手机侧 Finding")
l65 = src[src.find("L6_DOT_METRICS_UNAVAILABLE", src.find("def _l6")):]
scan(l65[:1200], "linkstat 第 6.5 层")

print()
print("── 3. CLI 的两步说明 ──")
sess = (ROOT / "deploy/bot/linksess.py").read_text(encoding="utf-8")
two = sess.split("_TWO_STEP = ")[1].split('"""')[1]
scan(two, "两步说明")
(ok if "不代表 SIM/APN、DoT 或手机整体\n    联网正常" in two
       or "不代表 SIM/APN" in two else bad)("第 1 步的证据写明了它的上限")

print()
print("── 4. Bot 自检文本 ──")
bot = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
scan(bot, "pdg-bot.py")
checks = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")
scan(checks, "checks.py")

print()
print("── 4b. 内部实现术语不进用户面前的字 ──")
# 拒绝 mosdns metrics 的技术论证是**给维护者看的**: 用户在自检里读到"本机 SSRF""缓存投喂
# 端点", 既看不懂也无从处置, 只会觉得网关坏了。论证留在 README 与 docs/ROADMAP.md, 用户
# 侧只给结论与下一步。
JARGON = ("SSRF", "缓存投喂", "上游端口", "load_dump", "pprof",
          "metrics 接口", "缓存导出", "反向代理")
for label, path in (("linkstat 用户可见文案", "deploy/bot/linkstat.py"),
                    ("linksess 两步说明", "deploy/bot/linksess.py")):
    txt = (ROOT / path).read_text(encoding="utf-8")
    # 只看**字符串字面量**: 同一批词出现在注释里是允许的(那正是留给维护者的线索)。
    import ast as _ast
    lits = []
    for n in _ast.walk(_ast.parse(txt)):
        if isinstance(n, _ast.Constant) and isinstance(n.value, str):
            lits.append(n.value)
    body = "\n".join(lits)
    hit = sorted({w for w in JARGON if w in body})
    (ok if not hit else bad)("%s: 不含内部实现术语(实得 %s)" % (label, hit))

print()
print("── 4c. 但论证必须在 README / ROADMAP 里留全 ──")
# 反方向: 简化用户文案不等于把理由删掉。谁要是把这段论证一并清掉, 下一个人就会以为
# "开 metrics 就行", 白白把用户的浏览域名摊开。
readme = (ROOT / "README.md").read_text(encoding="utf-8")
roadmap = (ROOT / "docs/ROADMAP.md").read_text(encoding="utf-8")
for label, txt, need in (
        ("README", readme, ("metrics", "缓存导出", "明文查询域名")),
        ("ROADMAP", roadmap, ("load_dump", "SSRF", "反向代理", "明文查询域名",
                              "不更换 mosdns 版本"))):
    miss = [w for w in need if w not in txt]
    (ok if not miss else bad)("%s 保留了拒绝 mosdns API 的完整理由(缺 %s)" % (label, miss))
(ok if "不等于「手机显示的位置已经变了」" in readme else bad)(
    "README 仍保留「网关改写响应 ≠ 手机显示的位置已改变」的边界")

print()
print("── 4d. 放宽后的否定判据仍然抓得住裸用 ──")
# 上面把回看窗口从 14 放宽到 40, 必须证明它没被放成筛子。
_probe = [
    ("这只证明请求到达网关，不代表 DoT、SIM/APN 或整体联网正常。", True,  "同句列表否定"),
    ("HTTP 请求已到达。DoT 正常。", False, "隔壁句子的否定借不过来"),
    ("SIM/APN 正常，可以放心使用。", False, "裸用"),
    ("链路已通，整体联网正常。", False, "裸用(前面无否定)"),
    ("本版本无法判断 DoT 正常与否。", True,  "同句否定"),
]
for _txt, _should_pass, _why in _probe:
    _bare = []
    for _w in OVERREACH:
        for _m in re.finditer(re.escape(_w), _txt):
            _lead = _txt[max(0, _m.start() - 48):_m.start()]
            if not _NEG.search(_lead):
                _bare.append(_w)
    _passed = not _bare
    (ok if _passed == _should_pass else bad)(
        "%s: %r 判为%s(期望%s)" % (_why, _txt[:22],
                                  "合规" if _passed else "越界",
                                  "合规" if _should_pass else "越界"))

print()
print("── 5. NOT_OBSERVED 既不是故障, 也不影响退出码 ──")
nf = [F(6.5, "L6_DOT_METRICS_UNAVAILABLE", L.NOT_OBSERVED, "手机 DoT 查询证据",
        "当前版本暂不采集这项证据，因此无法判断手机的 DoT 查询是否到达；"
        "这不代表正常，也不代表故障。")]
(ok if L.exit_code(nf) == 0 else bad)(
    "只有 NOT_OBSERVED 时退出码 0(实得 %d)" % L.exit_code(nf))
mark = L._MARK[L.NOT_OBSERVED]
(ok if mark not in ("🔴", "🟡") else bad)(
    "NOT_OBSERVED 的标记不是故障色(实得 %s)" % mark)
rendered = L.render_text(nf)
(ok if "暂不采集这项证据" in rendered else bad)("渲染里保留了「暂不采集这项证据」的说明")
# 只看第 6.5 层**自己那一行**。整段末尾的免责句里有"也不代表发生故障"—— 那是否定语境,
# 把它算进来就成了假红(第一版判据正是这么写错的)。
line65 = [l for l in rendered.splitlines() if "手机 DoT 查询证据" in l]
# "也不代表故障"是**否定**语境, 恰恰是我们要的写法。判据因此不能是"整行不许出现故障",
# 而是"每次出现都得跟在否定后面" —— 与本文件的越界扫描同一把尺子。
_bare_fail = []
for _m in re.finditer(r"(失败|故障|错误)", line65[0] if line65 else ""):
    _lead = line65[0][max(0, _m.start() - 10):_m.start()]
    if not re.search(r"[不没未无][^，。;；]{0,8}$", _lead):
        _bare_fail.append(line65[0][max(0, _m.start() - 10):_m.end() + 4])
(ok if line65 and not _bare_fail else bad)(
    "第 6.5 层那一行没把它写成失败/故障/错误(裸用 %s)" % (_bare_fail or "无"))

print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)

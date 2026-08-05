#!/usr/bin/env python3
"""三处「拿不到值就编个占位符继续走」—— 修改前先红。

`.153` 真机验收一天之内撞到三次同一个形状的缺陷。它们分散在三个模块, 但错的是同一件事:
**读不到一个必需的值时, 不说"我读不到", 而是塞一个占位符继续往下走**, 于是下游拿着一个
必然不成立的东西去干活, 而界面上一切正常。

这与整条链路的立身之本正好相反 —— 6.1A 起就反复写: 宁可 NOT_OBSERVED, 不许把不知道说成
知道。占位符比"不知道"更糟: 它看起来像个答案。

  a) linksess.start_session()   PDG_SERVER_IP 空 → ip = "<网关IP>" → 拼出点不通的链接,
                                而且是在会话**已经写盘、token 已经生成**之后;
  b) pdg-bot._dot_host()        证书不在写死的默认路径 → 吞成 "?" → 用户拿着 "?" 去配
                                Android 私密 DNS。而正确的解析 checks._cert_path() 就在
                                隔壁: 它从 mosdns 配置里读 `cert:`。同一件事两份实现,
                                一份对一份错;
  c) linkstat._l3_probe()       6.1B 把 probe81 转成两平台公共件之后, 这一层仍报
                                "Android 不安装 pdg-probe81, 也不监听/放行 81"。而真机上
                                它 active、:81 在听、nft 有放行、curl 返回 200、doctor 报绿。

夹具全部合成, 不含真机地址与凭据。
"""
import io
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


BOX = tempfile.mkdtemp(prefix="honesty.")

# ═══ a) start_session: PDG_SERVER_IP 缺失必须 fail-closed ══════════════════
print("── a) start_session 缺 PDG_SERVER_IP ──")
import linksess  # noqa: E402

RUN = os.path.join(BOX, "run")
os.makedirs(RUN, exist_ok=True)
os.environ["PDG_PROBE81_RUNTIME_DIR"] = RUN


def start_with(server_ip):
    """摆一份只缺/只有 PDG_SERVER_IP 的 profile, 跑真的 start_session()。"""
    prof = os.path.join(BOX, "profile.env")
    lines = ["PDG_INTERNAL_CIDR=172.22.0.0/16"]
    if server_ip is not None:
        lines.append("PDG_SERVER_IP=%s" % server_ip)
    io.open(prof, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    os.environ["PDG_PROFILE_ENV"] = prof
    for f in os.listdir(RUN):
        os.remove(os.path.join(RUN, f))
    return linksess.start_session()


okr, p = start_with(None)
(ok if not okr else bad)("缺 PDG_SERVER_IP → start_session 返回 ok=False(实得 %s)" % okr)
if not okr:
    (ok if "PDG_SERVER_IP" in (p.get("error") or "") else bad)(
        "  错误文案点名 PDG_SERVER_IP(实得 %r)" % p.get("error"))
    (ok if p.get("reason") else bad)("  带 reason code(实得 %r)" % p.get("reason"))
else:
    url = p.get("step1_url", "")
    bad("  它返回的链接是: %s" % re.sub(r"t=[^&]+", "t=<token>", url))
# 关键: 失败时**不能**留下会话 —— 否则用户"再测一次"会撞上一个已存在但没用的会话
left = [x for x in os.listdir(RUN) if not x.startswith(".")]
(ok if not left else bad)("  失败时不落盘、不生成 token(残留 %r)" % left)

okr, p = start_with("203.0.113.7")
(ok if okr else bad)("有 PDG_SERVER_IP → 正常建会话(实得 ok=%s err=%r)"
                     % (okr, (p or {}).get("error")))
if okr:
    (ok if p["step1_url"].startswith("http://203.0.113.7:81/") else bad)(
        "  URL 用的是真地址(实得 %s)" % re.sub(r"t=[^&]+", "t=<token>", p["step1_url"]))
linksess.clear_state()

# 源码形态: 不许再出现"拿占位符顶上"
_src = io.open(str(ROOT / "deploy/bot/linksess.py"), encoding="utf-8").read()
(ok if '_server_ip() or "<网关IP>"' not in _src else bad)(
    "源码里没有 `_server_ip() or \"<网关IP>\"` 这种占位符兜底")

# ═══ b) _dot_host: 证书路径要复用 checks 那份对的解析 ══════════════════════
print()
print("── b) _dot_host 找不到证书 ──")
_bsrc = io.open(str(ROOT / "deploy/bot/pdg-bot.py"), encoding="utf-8").read()
_fn = re.search(r"\ndef _dot_host\(\):.*?\n(?=def )", _bsrc, re.S)
(ok if _fn else bad)("抽到了 _dot_host")
_body = _fn.group(0) if _fn else ""
(ok if '"?"' not in _body else bad)(
    "_dot_host 不再把读不到吞成 \"?\"(实得 %d 处)" % _body.count('"?"'))
(ok if "_cert_path" in _body or "checks." in _body else bad)(
    "_dot_host 复用 checks 那份从 mosdns 配置读 cert: 的解析, 不各写一份")
# checks 那份必须还在, 并且真的从配置里读
_csrc = io.open(str(ROOT / "deploy/bot/checks.py"), encoding="utf-8").read()
(ok if re.search(r"def _cert_path\(\):", _csrc) else bad)("checks._cert_path 仍在")
(ok if 'cert:\\s*"' in _csrc or "cert:" in _csrc else bad)(
    "  它是从 mosdns 配置里解析 cert: 路径")

# 行为: 证书不在默认路径、但 mosdns 配置里指到别处时, 要能找对
import checks  # noqa: E402
_mos = os.path.join(BOX, "mosdns.yaml")
_cert = os.path.join(BOX, "fullchain.pem")
io.open(_mos, "w", encoding="utf-8").write(
    'args: {entry: main, listen: "0.0.0.0:853", cert: "%s", key: "%s"}\n' % (_cert, _cert))
_om = checks.MOSDNS_CONF
checks.MOSDNS_CONF = _mos
try:
    got = checks._cert_path()
finally:
    checks.MOSDNS_CONF = _om
(ok if got == _cert else bad)(
    "checks._cert_path 从配置里读出了非默认路径(实得 %s)" % got)

# ═══ c) linkstat 第 3 层: probe81 已是两平台公共件 ════════════════════════
print()
print("── c) linkstat 第 3 层的平台门 ──")
import linkstat  # noqa: E402

_lsrc = io.open(str(ROOT / "deploy/bot/linkstat.py"), encoding="utf-8").read()
(ok if "Android 不安装 pdg-probe81" not in _lsrc else bad)(
    "不再声称「Android 不安装 pdg-probe81, 也不监听/放行 81」—— 6.1B 起它是两平台公共件")
_f3 = re.search(r"\ndef _l3_probe\(ctx\):.*?\n(?=def )", _lsrc, re.S)
(ok if _f3 else bad)("抽到了 _l3_probe")
_b3 = _f3.group(0) if _f3 else ""
(ok if 'L3_PLATFORM_NA' not in _b3 else bad)(
    "Android 不再走 L3_PLATFORM_NA 这条跳过分支")
(ok if "iOS 探测端点" not in _b3 else bad)(
    "标题不再叫「iOS 探测端点」—— 它两平台都有")

# 行为: 同一份"探测端点返回 200"的现场, 两平台都应判 PASS
_orig_run = checks._run
checks._run = lambda cmd, t=10: (0, "200", "") if "curl" in cmd[0] else _orig_run(cmd, t)
try:
    for plat in ("android", "ios"):
        f = linkstat._l3_probe({"platform": plat})
        s, c = (f["status"], f["code"]) if isinstance(f, dict) else (f.status, f.code)
        (ok if s == linkstat.PASS else bad)(
            "%s: 端点返回 200 → PASS(实得 %s / %s)" % (plat, s, c))
finally:
    checks._run = _orig_run

shutil.rmtree(BOX, ignore_errors=True)
print("──────────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

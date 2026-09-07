#!/usr/bin/env python3
"""`check_rulesets` 要能拿到**运行期证据**, 而不是永远停在"形态没问题"。

v1.11.11 把这条判据从假绿改成 warn, 是对的 —— 它当时确实没读运行期。但那句 warn 是
**证据缺口**, 不是终点: mihomo 的管理面(external-controller)就摆在那里, `/providers/rules`
会给出每个 rule provider 的 `name / behavior / format / ruleCount / updatedAt`。拿到它,
"已加载、多少条、何时更新"就是可证的; 拿不到, 才该继续说"无结论"。

契约(缺一不可):

  · **拿得到且齐全** —— 声明的每个规则集都能在运行期找到同名 provider, 且 ruleCount>0
    → **ok**, 并报出条数与最旧的 updatedAt;
  · **声明了却没加载**(运行期缺同名 provider)→ **fail**: 规则被静默丢弃, 分流是死的;
  · **加载了但 ruleCount==0** → **fail**: 同上, "有这个 provider"不等于"有规则";
  · **控制面读不到 / 非 200 / JSON 坏 / 字段缺** → **warn 且说明运行期状态不可得**,
    绝不因为"试过了"就退回 ok;
  · **external-controller 不是回环 / 没配** → **warn**, 且**不主动去连非回环地址**;
  · 既有契约一个字不动: `.srs`/`format=binary` 仍 fail; 无元数据/空元数据仍 None;
    元数据损坏仍 fail。

本测试用**真的 HTTP 服务**绑回环随机端口冒充管理面(不碰 9090、不连任何生产机),
元数据与配置都在隔离临时目录里。
"""
import importlib.util
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402

spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

PASS = [0]; FAIL = [0]
def ok(m):  PASS[0] += 1; print("  ✓ %s" % m)
def bad(m): FAIL[0] += 1; print("  ✗ %s" % m)

WD = tmpguard.mkdtemp(prefix="pdg-rsrt.")


class Fake(BaseHTTPRequestHandler):
    """冒充 mihomo 管理面。只应答 /providers/rules; 行为由 server 上的属性决定。"""
    def log_message(self, *a): pass

    def do_GET(self):
        code, body = self.server.plan.get(self.path, (404, b"{}"))
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(plan):
    srv = HTTPServer(("127.0.0.1", 0), Fake)
    srv.plan = plan
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def providers_body(items):
    return json.dumps({"providers": items}).encode()


def ask(meta, controller=None, plan=None, raw=None):
    """把 RS_META 与 MIHOMO_CFG 指到临时文件, 问一次判据。返回 (level,name,msg) 或 None。"""
    mp = os.path.join(WD, "rulesets.json")
    if raw is not None:
        open(mp, "w", encoding="utf-8").write(raw)
    elif meta is None:
        if os.path.exists(mp): os.remove(mp)
    else:
        json.dump(meta, open(mp, "w", encoding="utf-8"))
    cp = os.path.join(WD, "mihomo.json")
    cfg = {}
    if controller is not None:
        cfg["external-controller"] = controller
    json.dump(cfg, open(cp, "w", encoding="utf-8"))
    old_rs, old_cfg = checks.RS_META, checks.MIHOMO_CFG
    checks.RS_META, checks.MIHOMO_CFG = mp, cp
    try:
        return checks.check_rulesets()
    finally:
        checks.RS_META, checks.MIHOMO_CFG = old_rs, old_cfg


def lvl(r): return r[0] if r else None
def msg(r): return r[2] if r else ""

META3 = {"rs_a": {"label": "A", "url": "https://x/a.list"},
         "rs_b": {"label": "B", "url": "https://x/b.list"},
         "rs_c": {"label": "C", "url": "https://x/c.list"}}
FULL = {"rs_a": {"name": "rs_a", "behavior": "Classical", "format": "TextRule",
                 "ruleCount": 13, "updatedAt": "2026-09-06T13:30:45Z"},
        "rs_b": {"name": "rs_b", "behavior": "Classical", "format": "TextRule",
                 "ruleCount": 44, "updatedAt": "2026-09-06T13:30:49Z"},
        "rs_c": {"name": "rs_c", "behavior": "Classical", "format": "TextRule",
                 "ruleCount": 129, "updatedAt": "2026-09-06T13:30:10Z"}}

print("== 1. 运行期证据齐全 → 必须给出 ok, 并报条数 ==")
srv = serve({"/providers/rules": (200, providers_body(FULL))})
port = srv.server_address[1]
r = ask(META3, controller="127.0.0.1:%d" % port)
if lvl(r) == "ok" and "186" in msg(r):
    ok("三个 provider 均已加载且 ruleCount>0 → ok, 文案含总条数 186: %s" % msg(r)[:80])
elif lvl(r) == "ok":
    ok("→ ok(但文案未报总条数): %s" % msg(r)[:90])
else:
    bad("运行期齐全却没给 ok: level=%s msg=%s" % (lvl(r), msg(r)[:110]))
srv.shutdown()

print("== 2. 声明了但运行期没有同名 provider → fail(规则被静默丢弃)==")
srv = serve({"/providers/rules": (200, providers_body({k: FULL[k] for k in ("rs_a", "rs_b")}))})
r = ask(META3, controller="127.0.0.1:%d" % srv.server_address[1])
if lvl(r) == "fail" and ("rs_c" in msg(r) or "C" in msg(r)):
    ok("缺 rs_c → fail 并点名: %s" % msg(r)[:80])
else:
    bad("声明了却没加载, 判据没报 fail: level=%s msg=%s" % (lvl(r), msg(r)[:110]))
srv.shutdown()

print("== 3. 加载了但 ruleCount==0 → fail ==")
z = dict(FULL); z["rs_b"] = dict(FULL["rs_b"], ruleCount=0)
srv = serve({"/providers/rules": (200, providers_body(z))})
r = ask(META3, controller="127.0.0.1:%d" % srv.server_address[1])
if lvl(r) == "fail" and ("rs_b" in msg(r) or "B" in msg(r)):
    ok("ruleCount=0 → fail 并点名: %s" % msg(r)[:80])
else:
    bad("ruleCount=0 没被判 fail: level=%s msg=%s" % (lvl(r), msg(r)[:110]))
srv.shutdown()

print("== 4. 控制面连不上 → warn 且说明运行期不可得(不得退回 ok)==")
srv = serve({"/providers/rules": (200, providers_body(FULL))})
dead = srv.server_address[1]; srv.shutdown(); srv.server_close()
r = ask(META3, controller="127.0.0.1:%d" % dead)
if lvl(r) == "warn" and ("运行期" in msg(r) or "无结论" in msg(r) or "不可得" in msg(r)):
    ok("连不上 → warn 且明说运行期状态不可得: %s" % msg(r)[:80])
else:
    bad("连不上时判据不对: level=%s msg=%s" % (lvl(r), msg(r)[:110]))

print("== 5. 非 200 / JSON 坏 / 字段缺 → 一律 warn ==")
bad_cases = [("非 200", {"/providers/rules": (500, b"{}")}),
             ("JSON 坏", {"/providers/rules": (200, b"{not json")}),
             ("缺 providers 键", {"/providers/rules": (200, b'{"x":1}')}),
             ("缺 ruleCount", {"/providers/rules": (200, providers_body(
                 {k: {kk: vv for kk, vv in v.items() if kk != "ruleCount"} for k, v in FULL.items()}))})]
allw = True
for label, plan in bad_cases:
    srv = serve(plan)
    r = ask(META3, controller="127.0.0.1:%d" % srv.server_address[1])
    if lvl(r) != "warn":
        allw = False; bad("%s → 期望 warn, 实得 %s: %s" % (label, lvl(r), msg(r)[:80]))
    srv.shutdown()
if allw:
    ok("非 200 / JSON 坏 / 缺 providers / 缺 ruleCount 四种都判 warn")

print("== 6. external-controller 非回环或缺失 → warn, 且不主动连非回环 ==")
r1 = ask(META3, controller="10.0.0.5:9090")
r2 = ask(META3, controller=None)
# 光看 level 不够: 去掉回环限制之后, 连非回环也会连失败 → 照样是 warn, 那这一格就白设了。
# 判据落在**理由**上 —— 必须是"不在回环"(压根没去连), 而不是"读不到管理面"(连了没连上)。
p1 = lvl(r1) == "warn" and "不在回环" in msg(r1) and "读不到管理面" not in msg(r1)
p2 = lvl(r2) == "warn" and "未配置" in msg(r2)
if p1 and p2:
    ok("非回环 → warn 且理由是「不在回环」(根本没发起连接); 未配置 → warn 且理由是「未配置」")
else:
    bad("非回环/缺失处理不对: r1=%s|%s ; r2=%s|%s" % (lvl(r1), msg(r1)[:60], lvl(r2), msg(r2)[:60]))

print("== 7. 既有契约不得回退 ==")
srv = serve({"/providers/rules": (200, providers_body(FULL))})
p = "127.0.0.1:%d" % srv.server_address[1]
checks_srs = ask({"rs_x": {"label": "X", "url": "https://x/a.srs"}}, controller=p)
none1 = ask(None, controller=p)
none2 = ask({}, controller=p)
broken = ask(None, controller=p, raw="{not json")
srv.shutdown()
probs = []
if lvl(checks_srs) != "fail": probs.append(".srs 未判 fail(%s)" % lvl(checks_srs))
if none1 is not None: probs.append("无元数据未返回 None")
if none2 is not None: probs.append("空元数据未返回 None")
if lvl(broken) != "fail": probs.append("元数据损坏未判 fail(%s)" % lvl(broken))
if probs: bad("既有契约回退: " + "; ".join(probs))
else: ok(".srs→fail / 无元数据→None / 空→None / 损坏→fail 四条既有契约均未回退")

print()
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

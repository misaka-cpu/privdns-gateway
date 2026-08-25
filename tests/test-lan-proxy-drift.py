#!/usr/bin/env python3
"""门四: 受管的反代路由必须与面板表**双向一致**。

为什么需要这一条: 面板表是权威模型, 三个派生产物(caddy.conf / 出站白名单 / unit)
都由它渲染。白名单那半已经有 check_lan_whitelist 逐条对账了, 而**反代那半一直没人看** ——
于是这种状态可以长期存在且零告警:

    模型里没有 c 面板了, 而 caddy.conf 还在为 c 转发。

它最典型的来源是**回滚**: /etc/privdns-gateway 在全局快照内(模型跟着回去了),
/etc/pdg-lan/caddy.conf 在快照外(产物留在原地)。两个方向的危险不对称:

  · Caddy 多出模型没有的站点 = 反代仍在服务一个**已经被移除**的面板;
  · Caddy 少了模型有的站点   = 那个面板打不开, 而白名单是按模型放行的, 看着一切正常。

判据取**同一个渲染器 + 同一个抽取器**: 拿 lanpanel.render_caddy 现渲一份期望值, 再用
同一个抽取器把两侧都投影成 {host: 上游} 去比。不另写一套宽松版渲染逻辑 —— 那种"第二实现"
迟早与真渲染器分叉, 而分叉的方向通常是"判据比产品宽", 也就是假绿。
"""
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(C)

PASS = [0]
FAILED = []


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAILED.append(m)
    print("[FAIL] %s" % m)


def stub(**kw):
    old = {k: getattr(C, k, None) for k in kw}
    for k, v in kw.items():
        setattr(C, k, v)
    return old


def restore(old):
    for k, v in old.items():
        if v is None:
            try:
                delattr(C, k)
            except AttributeError:
                pass
        else:
            setattr(C, k, v)


def cfg(*panels):
    return {"panels": [{"name": n, "host": h, "target": "http://%s:%d" % (ip, port)}
                       for n, h, ip, port in panels]}


P_A = ("a", "a.lan.test", "192.168.100.10", 80)
P_B = ("b", "b.lan.test", "192.168.100.11", 8080)
P_C = ("c", "c.lan.test", "192.168.100.12", 80)

WORK = Path(tmpguard.mkdtemp(prefix="lan-drift-"))

sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import lanpanel          # noqa: E402  真渲染器: "盘上那份"要长得跟真的一样


def live_conf(model, name="caddy.conf"):
    """按某个模型渲染出一份"盘上的 caddy.conf"。"""
    p = WORK / name
    p.write_text(lanpanel.render_caddy(model, "/etc/pdg-lan/certs"), encoding="utf-8")
    return str(p)


def run_check(model, live_path, on=(True, True)):
    """跑门四。判据函数不存在 = 本轮要新增的东西还没有 —— 具名报出来, 不伪装成别的失败。"""
    fn = getattr(C, "check_lan_proxy_routes", None)
    if fn is None:
        return ("MISSING", "check_lan_proxy_routes", "checks.py 里没有这条判据")
    old = stub(_lan_cfg=lambda: model, _lan_on=lambda: on, LAN_CADDYFILE=live_path)
    try:
        return fn()
    finally:
        restore(old)


def verdict(res):
    return res[0] if res else None


# ══ ① 完全一致 → ok ═════════════════════════════════════════════════════════
m = cfg(P_A, P_B)
r = run_check(m, live_conf(m, "same.conf"))
if verdict(r) == "ok":
    ok("① 模型与反代逐条一致 → ok(%s)" % r[2])
else:
    bad("① 一致时判据没给 ok: %r" % (r,))

# ══ ② 模型有、Caddy 缺 → fail 且点名 ════════════════════════════════════════
m = cfg(P_A, P_B)
r = run_check(m, live_conf(cfg(P_A), "missing.conf"))
if verdict(r) == "fail" and "b.lan.test" in (r[2] if r else ""):
    ok("② 反代少了模型里的站点 → fail 并点名 b.lan.test")
else:
    bad("② 反代缺站点时没判红或没点名: %r" % (r,))

# ══ ③ Caddy 有、模型已删 → fail 且点名 ══════════════════════════════════════
# 这正是"回滚删了面板、反代还在转发"的形态 —— 最危险的那个方向。
m = cfg(P_A)
r = run_check(m, live_conf(cfg(P_A, P_C), "extra.conf"))
if verdict(r) == "fail" and "c.lan.test" in (r[2] if r else ""):
    ok("③ 反代多出模型已删的站点 → fail 并点名 c.lan.test")
else:
    bad("③ 反代多站点时没判红或没点名: %r" % (r,))

# ══ ④ 上游漂移 → fail ══════════════════════════════════════════════════════
m = cfg(P_A)
drift = cfg(("a", "a.lan.test", "192.168.100.99", 80))
r = run_check(m, live_conf(drift, "upstream.conf"))
if verdict(r) == "fail" and "a.lan.test" in (r[2] if r else ""):
    ok("④ 同一站点上游漂移 → fail 并点名")
else:
    bad("④ 上游漂移没判红: %r" % (r,))

# ══ ⑤ 域名漂移 → fail(一缺一多, 两个方向都要说出来)══════════════════════
m = cfg(P_A)
r = run_check(m, live_conf(cfg(("a", "a2.lan.test", "192.168.100.10", 80)), "host.conf"))
if verdict(r) == "fail":
    ok("⑤ 域名漂移 → fail(%s)" % r[2][:60])
else:
    bad("⑤ 域名漂移没判红: %r" % (r,))

# ══ ⑥ 未启用 → 按既有语义, 不报红 ══════════════════════════════════════════
m = cfg(P_A)
r = run_check(m, live_conf(cfg(P_A, P_C), "off.conf"), on=(False, False))
if verdict(r) == "ok":
    ok("⑥ 面板停用时不报红(与其余三条判据同语义)")
else:
    bad("⑥ 停用时判据不该报红: %r" % (r,))

# ══ ⑦ 从未配过 → None(整条不出现)═════════════════════════════════════════
r = run_check(None, live_conf(cfg(P_A), "never.conf"))
if r is None:
    ok("⑦ 从未配过面板 → 判据整条不出现")
else:
    bad("⑦ 没配过面板时判据不该出现: %r" % (r,))

# ══ ⑧ 读不到 caddy.conf → warn, 不是 fail ══════════════════════════════════
# "判据没跑成"与"判据成立"必须分开: 混成一句会让一台缺文件的机器看起来像反代丢了配置。
m = cfg(P_A)
r = run_check(m, str(WORK / "does-not-exist.conf"))
if verdict(r) == "warn":
    ok("⑧ 读不到反代配置 → warn(说明本项没跑成)")
elif verdict(r) == "fail":
    bad("⑧ 读不到配置被判成 fail —— 把'没跑成'说成了'不一致'")
else:
    bad("⑧ 读不到配置时的判据不对: %r" % (r,))

# ══ ⑨ 模型自己不合法 → warn, 不得崩、不得假绿 ══════════════════════════════
r = run_check({"panels": [{"name": "x"}]}, live_conf(cfg(P_A), "badmodel.conf"))
if verdict(r) == "warn":
    ok("⑨ 模型渲不出来 → warn(不崩、不假绿)")
else:
    bad("⑨ 模型不合法时的判据不对: %r" % (r,))

# ══ ⑩ 必须登记进 doctor 的判据表 ═══════════════════════════════════════════
# 判据写了却没人调 = 永远不会跑的死代码, 而看起来"已经有这条检查了"。
src = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")
try:
    import ast
    tree = ast.parse(src)
    called = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)}
    called |= {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
    registered = "check_lan_proxy_routes" in called and "def check_lan_proxy_routes" in src
except SyntaxError as e:
    registered = False
    print("    (checks.py 解析失败: %s)" % e)
if registered:
    ok("⑩ 判据已在 checks.py 里被登记调用")
else:
    bad("⑩ check_lan_proxy_routes 没定义或没被 doctor 调到(死代码)")

print("─────────────────────────────────────────")
print("通过 %d, 失败 %d" % (PASS[0], len(FAILED)))
sys.exit(1 if FAILED else 0)

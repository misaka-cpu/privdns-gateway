#!/usr/bin/env python3
"""救援平面的 recover 写路径回归(5.2/commit 6)。

这是救援平面第一个**会写现网**的操作, 所以纪律比页面本身更重要:
  · 恢复逻辑一行都不重写 —— 锁、漂移保护、材料校验、审计全在 pdgtx.recover 里;
  · txid 只能是**本次枚举出来的未完成事务**, 页面上的值一律当不可信输入重新校验;
  · 必须已登录 + CSRF 与本会话绑定 + 勾了确认, 三者缺一不做事;
  · 救援页**不提供 --force**: 覆盖别人的人工修复必须去 SSH 上显式做;
  · 结果如实呈现 —— 回滚没完成就写明 ROLLBACK_FAILED, 不粉饰。

事务用真沙箱造: 起一笔真事务, 在 APPLYING 阶段把进程 SIGKILL 掉(等价于断电), 于是现网留在
"改了一半"、事务停在 APPLYING —— 与 e2e-config-transaction-recovery 同一种造法。
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from rescuebox import Inst, TOKEN  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-recover-77"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


work = tmpguard.mkdtemp(prefix="rescue-recover.")

# ── 造一笔停在 APPLYING 的事务 ──────────────────────────────────────────────
# 候选必须是**合法的 mosdns 配置** —— 校验器会拿真 mosdns 解析它, 塞一段随便的文本只会在
# 候选校验阶段就被拒(那验的是校验器, 不是恢复)。两份配置只差 cache size 一处。
def _mos_cfg(size):
    return (
        "log:\n  level: error\n"
        "plugins:\n"
        "  - tag: npn_clients\n"
        "    type: ip_set\n"
        '    args: { ips: ["172.22.0.0/16"] }\n'
        "  - tag: cache\n"
        "    type: cache\n"
        "    args: { size: %d }\n"
        "  - tag: main_sequence\n"
        "    type: sequence\n"
        "    args:\n"
        "      - exec: reject 3\n"
        "  - tag: udp_server\n"
        "    type: udp_server\n"
        '    args: {entry: main_sequence, listen: "127.0.0.1:0"}\n'
        % size)


ORIG_CFG = _mos_cfg(1024)
NEW_CFG = _mos_cfg(4096)

CRASH = r'''
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
t = tx.Tx(source="bot", op="test-op")
cur, sha = t.read_for_update("mosdns_conf")
t.stage("mosdns_conf", sys.argv[2].encode("utf-8"), expect=sha)
t.service("restart:mosdns")
# 落盘做完、服务动作还没走完时断电: 状态停在 APPLYING, 现网已经是新内容
orig = tx.Tx._do_actions
def boom(self):
    os.kill(os.getpid(), signal.SIGKILL)
tx.Tx._do_actions = boom
t.commit()
'''


STUCK_MODE = 0o640          # 与 mosdns 配置的规范默认值不同, 便于分辨还原来源


def make_stuck(box, content=None):
    """返回 (txid, mosdns 路径)。事务停在 APPLYING, 现网是新内容, before-image 是旧内容。"""
    p = box.root + "/etc/mosdns/config.yaml"
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(content if content is not None else ORIG_CFG)
    # 故意给一个**不等于目标默认值**的权限位: recover 必须照 before-image 里记下的那个还原,
    # 而不是拿目标的规范默认值顶上。区分不开这两者的话, "恢复"会顺手改掉现网权限。
    os.chmod(p, STUCK_MODE)
    box.up("mosdns")
    env = dict(os.environ, **box.env)
    env["PYTHONPYCACHEPREFIX"] = os.path.join(work, "pycache")
    subprocess.run([sys.executable, "-c", CRASH, os.path.join(ROOT, "deploy/bot/pdgtx.py"), NEW_CFG],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    root = box.env["PDG_TX_ROOT"]
    ids = sorted(os.listdir(root)) if os.path.isdir(root) else []
    for d in ids:
        mp = os.path.join(root, d, "meta.json")
        if os.path.isfile(mp):
            m = json.load(open(mp, encoding="utf-8"))
            if m.get("state") == "APPLYING":
                return m["txid"], p
    return None, p


def rescue_for(box, **kw):
    """救援实例要跑在**同一个沙箱**里: 事务根、锁、探针端点之外, PATH 也必须带上 ——
    恢复阶段会 systemctl 还原服务态, 拿真 systemctl 去操作沙箱里的假服务只会失败, 结果被
    误读成"回滚不完整"(第一版就这么误判了一次)。"""
    keep = ("PDG_TX_", "PDG_LOCKFILE", "PDG_STABLE", "PATH")
    return Inst(work, extra_env={k: v for k, v in box.env.items() if k.startswith(keep)}, **kw)


box = Box()
txid, mos_path = make_stuck(box)
if txid:
    ok("造出一笔停在 APPLYING 的事务(%s)" % txid)
else:
    bad("没造出 APPLYING 事务")
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
if open(mos_path, encoding="utf-8").read() == NEW_CFG:
    ok("前提: 现网已经是改了一半的新内容")
else:
    bad("现网内容不对: %r" % open(mos_path, "rb").read()[:40])

inst = rescue_for(box)
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:300])
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)

# ── 1. 页面确实看得到这笔未完成事务, 并给出恢复表单 ─────────────────────────
st, cookie = inst.login()
st1, body1, _sc, _h = inst.req("GET", "/tx", cookie=cookie)
if st1 == 200 and txid in body1 and "APPLYING" in body1:
    ok("事务列表: 列出了这笔未完成事务")
else:
    bad("列表没显示: st=%s" % st1)
st2, body2, _sc, _h = inst.req("GET", "/tx/" + txid, cookie=cookie)
if st2 == 200 and "执行恢复" in body2 and "name=confirm" in body2:
    ok("详情页: 未完成事务给出恢复表单(带确认框)")
else:
    bad("详情页没有恢复表单")
if "--force" not in body2.replace("pdg tx recover", ""):
    ok("详情页不提供强制覆盖入口")
else:
    bad("页面上出现了 --force 操作入口")
import re  # noqa: E402

csrf = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body2)
csrf = csrf.group(1) if csrf else ""
if csrf:
    ok("详情页表单带会话绑定的 CSRF token")
else:
    bad("表单没有 CSRF token")


def post_recover(tid, conf="yes", token=None, cookie_=None):
    body = "csrf=%s&txid=%s&confirm=%s" % (token if token is not None else csrf, tid, conf)
    return inst.req("POST", "/tx/recover", body=body,
                    cookie=cookie if cookie_ is None else cookie_)


def content():
    return open(mos_path, "rb").read()


# ── 2. 拒绝路径: 每一条都不许碰现网 ─────────────────────────────────────────
before = content()
st, _b, _sc, _h = inst.req("POST", "/tx/recover", body="csrf=%s&txid=%s&confirm=yes" % (csrf, txid))
if st == 401 and content() == before:
    ok("未认证 → 401, 现网未变")
else:
    bad("未认证的恢复返回 %s" % st)
st, _b, _sc, _h = post_recover(txid, token="wrong-csrf-value")
if st == 403 and content() == before:
    ok("CSRF 不匹配 → 403, 现网未变")
else:
    bad("CSRF 错却返回 %s" % st)
st, _b, _sc, _h = post_recover(txid, conf="no")
if st == 400 and content() == before:
    ok("没勾确认 → 400, 现网未变")
else:
    bad("未确认却返回 %s" % st)
for evil in ("../../etc/passwd", "20990101T000000Z-deadbeef", "..", "%2e%2e%2f", "a" * 300):
    st, _b, _sc, _h = post_recover(evil)
    if st != 404 or content() != before:
        bad("非枚举 txid 未被拒: %r → %s" % (evil[:20], st))
        break
else:
    ok("非枚举 txid / 路径穿越一律 404, 现网未变")

# ── 3. 锁被占用 → 409, 现网不变 ────────────────────────────────────────────
lock_holder = subprocess.Popen(
    [sys.executable, "-c",
     "import fcntl, sys, time\n"
     "f = open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX)\n"
     "sys.stdout.write('locked\\n'); sys.stdout.flush(); time.sleep(30)\n",
     box.env["PDG_LOCKFILE"]],
    stdout=subprocess.PIPE, universal_newlines=True)
lock_holder.stdout.readline()
st, body, _sc, _h = post_recover(txid)
if st == 409 and content() == before:
    ok("锁被占用 → 409(不排队、不强行写), 现网未变")
else:
    bad("锁占用时返回 %s, 内容变了=%s" % (st, content() != before))
lock_holder.kill()
lock_holder.wait(timeout=10)

# ── 4. 正常恢复: 现网回到 before-image, 状态转 ROLLED_BACK, 有审计 ──────────
st, body, _sc, _h = post_recover(txid)
after = content()
if st == 200 and "恢复结果" in body:
    ok("正常恢复: 返回结果页")
else:
    bad("恢复返回 %s" % st)
if after.decode("utf-8") == ORIG_CFG:
    ok("正常恢复: 现网逐字节回到 before-image")
else:
    bad("现网没还原: %r" % after[:40])
mode_now = stat.S_IMODE(os.stat(mos_path).st_mode)
if mode_now == STUCK_MODE:
    ok("正常恢复: 权限位按 before-image 还原(0%o)" % mode_now)
else:
    bad("权限位没还原: 期望 0%o, 实际 0%o —— 恢复顺手改了现网权限" % (STUCK_MODE, mode_now))
meta = json.load(open(os.path.join(box.env["PDG_TX_ROOT"], txid, "meta.json"), encoding="utf-8"))
if meta.get("state") == "ROLLED_BACK" and meta.get("rollback_complete") is True:
    ok("正常恢复: 事务状态转 ROLLED_BACK 且标记完成")
else:
    bad("状态不对: %r" % meta.get("state"))
audit = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
lines = [json.loads(x) for x in open(audit, encoding="utf-8")] if os.path.exists(audit) else []
if any(str(r.get("op", "")).startswith("recover:") and r.get("txid") == txid for r in lines):
    ok("正常恢复: 审计里有 recover 记录")
else:
    bad("审计没记 recover")
if "ROLLED_BACK" in body and "已按 before-image 还原完成" in body:
    ok("结果页如实显示状态与结论")
else:
    bad("结果页内容不对")

# 恢复完之后它不再是"未完成", 再点一次必须 404(不是重复执行)
st, _b, _sc, _h = post_recover(txid)
if st == 404:
    ok("已恢复的事务不能再次执行(不在未完成名单里)")
else:
    bad("重复恢复返回 %s" % st)
inst.stop()
box.clean()

# ── 5. 恢复失败要如实报告: before-image 损坏 ────────────────────────────────
box2 = Box()
txid2, mos2 = make_stuck(box2)
bad_before = os.path.join(box2.env["PDG_TX_ROOT"], txid2, "before", "index.json")
with open(bad_before, "w", encoding="utf-8") as f:
    f.write("{ this is not valid json")
inst2 = rescue_for(box2)
if inst2.start():
    st, cookie2 = inst2.login()
    b2 = inst2.req("GET", "/tx/" + txid2, cookie=cookie2)[1]
    c2 = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", b2)
    before2 = open(mos2, "rb").read()
    st, body, _sc, _h = inst2.req(
        "POST", "/tx/recover",
        body="csrf=%s&txid=%s&confirm=yes" % (c2.group(1) if c2 else "", txid2), cookie=cookie2)
    if st == 200 and ("before-image" in body or "无法自动恢复" in body):
        ok("before-image 损坏: 如实报告无法自动恢复")
    else:
        bad("损坏时的结果不对: st=%s body=%r" % (st, body[-200:]))
    if open(mos2, "rb").read() == before2:
        ok("before-image 损坏: 现网逐字节未变")
    else:
        bad("损坏路径下现网被改了")
else:
    bad("实例2 起不来")
inst2.stop()
box2.clean()

# ── 6. 漂移: 事务之外有人改过 → 不覆盖, 并指引去 SSH 用 --force ─────────────
box3 = Box()
txid3, mos3 = make_stuck(box3)
with open(mos3, "wb") as f:
    f.write(_mos_cfg(777).encode("utf-8"))     # 运维手工救过场(仍是合法配置)
inst3 = rescue_for(box3)
if inst3.start():
    st, cookie3 = inst3.login()
    b3 = inst3.req("GET", "/tx/" + txid3, cookie=cookie3)[1]
    c3 = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", b3)
    st, body, _sc, _h = inst3.req(
        "POST", "/tx/recover",
        body="csrf=%s&txid=%s&confirm=yes" % (c3.group(1) if c3 else "", txid3), cookie=cookie3)
    if open(mos3, encoding="utf-8").read() == _mos_cfg(777):
        ok("漂移保护: 不覆盖事务之外的人工修复")
    else:
        bad("覆盖了人工修复")
    if "没有覆盖" in body and "--force" in body:
        ok("漂移保护: 页面说明冲突并指引去 SSH 显式强制(页面自己不给)")
    else:
        bad("冲突提示不对: %r" % body[-200:])
else:
    bad("实例3 起不来")
inst3.stop()
box3.clean()

# ── 7. 事务核心不可用时, 写路径必须 503 而不是 500/静默 ─────────────────────
box4 = Box()
inst4 = rescue_for(box4, with_pdgtx=False)
if inst4.start():
    st, cookie4 = inst4.login()
    b4 = inst4.req("GET", "/", cookie=cookie4)[1]
    st, body, _sc, _h = inst4.req("POST", "/tx/recover",
                                  body="csrf=x&txid=y&confirm=yes", cookie=cookie4)
    if st in (403, 503):
        ok("事务核心不可用: 写路径拒绝执行(%s)" % st)
    else:
        bad("pdgtx 不可用时返回 %s" % st)
else:
    bad("实例4 起不来")
inst4.stop()
box4.clean()

# ── 8. 凭据不进页面与日志 ───────────────────────────────────────────────────
logs = (inst.err or "") + (inst2.err or "") + (inst3.err or "")
if TOKEN not in logs and SENTINEL not in logs:
    ok("服务端日志不含 Token 与哨兵")
else:
    bad("日志泄漏了凭据")

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

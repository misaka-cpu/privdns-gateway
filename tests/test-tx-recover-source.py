#!/usr/bin/env python3
"""恢复的**触发来源**审计回归(5.2)。

事务的 source(这笔事务当初由谁创建: bot / cli / scheduler)与恢复的 trigger_source(这次恢复
由谁按下: cli / rescue / legacy)是两回事。出事之后要能回答"那次恢复是人在救援页点的,
还是 SSH 上敲的" —— 所以两个都记, 且原 source 绝不被覆盖。

同时钉住几条纪律:
  · 旧调用 recover(txid) 必须继续能用, 并记成 legacy(**不能伪装成 cli**);
  · 枚举只列真有调用方的来源(cli / rescue / legacy), 不给还不存在的自动恢复入口预留名字;
  · trigger_source 由服务端硬编码, HTTP 参数伪造无效;
  · 审计由 pdgtx 核心统一写, 救援服务不再写第二条;
  · 审计写失败不得把已经成功的恢复反判成失败, 但要给出明确 warning;
  · 并发恢复只有一个进核心, 另一个立刻 BUSY(不排队);
  · 客户端中途断开, 恢复照样完成并留下最终审计。
"""
import importlib.util
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from rescuebox import Inst, TOKEN  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-trigger-91"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def mos_cfg(size):
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["172.22.0.0/16"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n  - tag: main_sequence\n    type: sequence\n"
            "    args:\n      - exec: reject 3\n"
        "  - tag: udp_server\n"
        "    type: udp_server\n"
        '    args: {entry: main_sequence, listen: "127.0.0.1:0"}\n'
            % size)


CRASH = r'''
import importlib.util, os, signal, sys
spec = importlib.util.spec_from_file_location("pdgtx", sys.argv[1])
tx = importlib.util.module_from_spec(spec); spec.loader.exec_module(tx)
t = tx.Tx(source=sys.argv[3], op="test-op")
cur, sha = t.read_for_update("mosdns_conf")
t.stage("mosdns_conf", sys.argv[2].encode("utf-8"), expect=sha)
t.service("restart:mosdns")
def boom(self):
    os.kill(os.getpid(), signal.SIGKILL)
tx.Tx._do_actions = boom
t.commit()
'''

work = tmpguard.mkdtemp(prefix="trigger-src.")


def make_stuck(box, src="bot"):
    p = box.root + "/etc/mosdns/config.yaml"
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(mos_cfg(1024))
    box.up("mosdns")
    env = dict(os.environ, **box.env)
    env["PYTHONPYCACHEPREFIX"] = os.path.join(work, "pycache")
    subprocess.run([sys.executable, "-c", CRASH, os.path.join(ROOT, "deploy/bot/pdgtx.py"),
                    mos_cfg(4096), src], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    root = box.env["PDG_TX_ROOT"]
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        mp = os.path.join(root, d, "meta.json")
        if os.path.isfile(mp) and json.load(open(mp, encoding="utf-8")).get("state") == "APPLYING":
            return json.load(open(mp, encoding="utf-8"))["txid"], p
    return None, p


def load_tx(box):
    for k, v in box.env.items():
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location("pdgtx_%d" % time.time_ns(),
                                                  os.path.join(ROOT, "deploy/bot/pdgtx.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def audit_recs(box):
    f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    if not os.path.exists(f):
        return []
    out = []
    for line in open(f, encoding="utf-8"):
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def rescue_for(box, **kw):
    keep = ("PDG_TX_", "PDG_LOCKFILE", "PDG_STABLE", "PATH")
    return Inst(work, extra_env={k: v for k, v in box.env.items() if k.startswith(keep)}, **kw)


# ── 1. 旧签名仍可调用, 且记成 legacy(不冒充 cli)──────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="bot")
tx = load_tx(box)
res = tx.recover(txid)                       # 旧调用: 位置参数一个都没多
if res.get("ok") and res.get("state") == "ROLLED_BACK":
    ok("旧签名 recover(txid) 仍可调用且恢复成功")
else:
    bad("旧签名调用失败: %r" % res)
rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
if rec and rec[-1].get("trigger_source") == "legacy":
    ok("未更新的旧调用记成 legacy(没有伪装成 cli)")
else:
    bad("旧调用的 trigger_source 不对: %r" % (rec[-1].get("trigger_source") if rec else None))
if rec and rec[-1].get("source") == "bot":
    ok("原事务 source(bot)未被覆盖")
else:
    bad("原 source 被改了: %r" % (rec[-1].get("source") if rec else None))
need = ("event", "txid", "source", "trigger_source", "started_at", "ended_at", "state",
        "restored_count", "failed_count", "error_class")
missing = [k for k in need if k not in (rec[-1] if rec else {})]
if not missing:
    ok("审计事件字段齐全(%d 项)" % len(need))
else:
    bad("审计缺字段: %s" % missing)
if rec and rec[-1]["restored_count"] == 1 and rec[-1]["failed_count"] == 0:
    ok("审计记录了 restored/failed 数量")
else:
    bad("数量不对: %r" % rec[-1])
box.clean()

# ── 2. 非法 trigger 归一成 unknown, 不落成 cli ──────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="cli")
tx = load_tx(box)
res = tx.recover(txid, trigger_source="../../evil; DROP")
rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
if rec and rec[-1].get("trigger_source") == "unknown":
    ok("不在枚举里的 trigger_source → unknown(绝不回落 cli)")
else:
    bad("非法值没被归一: %r" % (rec[-1].get("trigger_source") if rec else None))
if rec and rec[-1].get("source") == "cli":
    ok("原事务 source(cli)保持不变")
else:
    bad("原 source 变了")
box.clean()

# ── 3. CLI 路径记 cli ───────────────────────────────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="bot")
env = dict(os.environ, **box.env)
env["PYTHONPYCACHEPREFIX"] = os.path.join(work, "pycache")
p = subprocess.run([sys.executable, os.path.join(ROOT, "deploy/bot/pdgtx.py"), "recover", txid],
                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                   universal_newlines=True, timeout=180)
rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
if p.returncode == 0 and rec and rec[-1].get("trigger_source") == "cli":
    ok("CLI recover 记 trigger_source=cli")
else:
    bad("CLI 记录不对: rc=%s trig=%r" % (p.returncode, rec[-1].get("trigger_source") if rec else None))
box.clean()

# ── 4. 救援页记 rescue, 且 HTTP 参数伪造无效 ───────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="scheduler")
inst = rescue_for(box)
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:200])
else:
    st, cookie = inst.login()
    body = inst.req("GET", "/tx/" + txid, cookie=cookie)[1]
    csrf = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body)
    csrf = csrf.group(1) if csrf else ""
    # 请求里塞一个伪造的 trigger_source, 服务端必须无视
    st, rbody, _sc, _h = inst.req(
        "POST", "/tx/recover",
        body="csrf=%s&txid=%s&confirm=yes&trigger_source=cli&source=cli" % (csrf, txid),
        cookie=cookie)
    rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
    if st == 200 and rec and rec[-1].get("trigger_source") == "rescue":
        ok("救援页恢复记 trigger_source=rescue")
    else:
        bad("救援记录不对: st=%s trig=%r" % (st, rec[-1].get("trigger_source") if rec else None))
    if rec and rec[-1].get("source") == "scheduler":
        ok("HTTP 参数伪造无效: 原 source 与 trigger_source 都没被请求参数左右")
    else:
        bad("参数伪造生效了: %r" % (rec[-1] if rec else None))
    # 救援服务不许再写第二条审计
    if len(rec) == 1:
        ok("同一次恢复只有一条审计记录(救援服务没有重复写)")
    else:
        bad("出现了 %d 条 recover 审计" % len(rec))
inst.stop()
box.clean()

# ── 5. 失败与 ROLLBACK_FAILED 也要有准确事件 ───────────────────────────────
box = Box(svc_fail=["mosdns"])
txid, mos = make_stuck(box, src="bot")
tx = load_tx(box)
res = tx.recover(txid, trigger_source="cli")
rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
if res.get("state") == "ROLLBACK_FAILED" and rec and rec[-1].get("state") == "ROLLBACK_FAILED":
    ok("ROLLBACK_FAILED: 审计如实记录最终状态")
else:
    bad("失败态记录不对: res=%r rec=%r" % (res.get("state"), rec[-1].get("state") if rec else None))
if rec and rec[-1].get("trigger_source") == "cli" and rec[-1].get("failed_count", 0) >= 1:
    ok("ROLLBACK_FAILED: trigger_source 如实记录且 failed_count 非零")
else:
    bad("字段不对: %r" % (rec[-1] if rec else None))
# 重复 recover(仍在 NEEDS_RECOVERY)→ 再来一条事件
res2 = tx.recover(txid, trigger_source="rescue")
rec2 = [r for r in audit_recs(box) if r.get("event") == "recover"]
if len(rec2) == len(rec) + 1 and rec2[-1].get("trigger_source") == "rescue":
    ok("重复 recover: 每次都留下独立事件(来源各记各的)")
else:
    bad("重复恢复的事件不对: %d → %d" % (len(rec), len(rec2)))
box.clean()

# ── 6. 审计写失败: 不反判恢复失败, 但要给 warning ──────────────────────────
box = Box()
txid, mos = make_stuck(box, src="bot")
tx = load_tx(box)
_orig_audit = tx._audit_rec
tx._audit_rec = lambda rec: (_ for _ in ()).throw(OSError("注入: 审计磁盘满"))
res = tx.recover(txid, trigger_source="cli")
tx._audit_rec = _orig_audit
if res.get("ok") and res.get("state") == "ROLLED_BACK":
    ok("审计写失败: 已完成的恢复仍判成功(不反向翻案)")
else:
    bad("审计失败把恢复判成了失败: %r" % res)
if "audit_warning" in res and "审计" in res["audit_warning"]:
    ok("审计写失败: 返回明确的 audit warning")
else:
    bad("没有 audit warning: %r" % res)
if open(mos, encoding="utf-8").read() == mos_cfg(1024):
    ok("审计写失败: 现网确实已按 before-image 还原")
else:
    bad("现网没还原")
box.clean()

# ── 7. 并发: 只有一个进核心, 另一个**立刻** BUSY(不排队)─────────────────────
# 要验的是"不排队", 所以恢复必须足够慢: 把桩 systemctl 的 restart 拖 3 秒, 于是第二个请求
# 一定落在第一个还没跑完的窗口里。断言收紧成"第二个必须是 409, 且明显早于第一个返回" ——
# 只判"有一个 200"太松: 没有闸门时第二个会在 flock 上排队, 等第一个做完再拿到 404, 那也满足
# "只有一个 200", 缺陷就漏过去了(负控确认过这一点)。
box = Box()
_stub = open(os.path.join(box.bin, "systemctl"), encoding="utf-8").read()
open(os.path.join(box.bin, "systemctl"), "w", encoding="utf-8").write(
    _stub.replace("  restart|start)", "  restart|start)\n    sleep 3"))
txid, mos = make_stuck(box, src="bot")
inst = rescue_for(box)
results = []
if inst.start():
    st, cookie = inst.login()
    body = inst.req("GET", "/tx/" + txid, cookie=cookie)[1]
    m = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body)
    csrf = m.group(1) if m else ""
    payload = "csrf=%s&txid=%s&confirm=yes" % (csrf, txid)

    def fire(tag, delay=0.0):
        if delay:
            time.sleep(delay)
        t0 = time.time()
        try:
            st_, body_, _s, _h = inst.req("POST", "/tx/recover", body=payload, cookie=cookie)
        except Exception:  # noqa: BLE001
            st_, body_ = -1, ""
        results.append((tag, st_, time.time() - t0, body_))

    ths = [threading.Thread(target=fire, args=("A", 0.0)),
           threading.Thread(target=fire, args=("B", 0.5))]
    for t in ths:
        t.start()
    for t in ths:
        t.join(timeout=90)
    by = {tag: (code, dur, body_) for tag, code, dur, body_ in results}
    rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
    if by.get("A", (0, 0, ""))[0] == 200 and by.get("B", (0, 0, ""))[0] == 409:
        ok("并发两个恢复: 先到的执行(200), 后到的 409")
    else:
        bad("并发返回码不对: %r" % results)
    b_dur = by.get("B", (0, 99, ""))[1]
    if b_dur < 1.5:
        ok("后到的请求**立刻**返回(%.2fs), 没有在锁上排队" % b_dur)
    else:
        bad("后到的请求排了 %.2fs 才返回(应立即 409)" % b_dur)
    # 必须是**救援服务自己的闸门**挡下的, 而不是"碰巧"落到核心的 TxBusy 上: 两者文案不同,
    # 而闸门的意义正是让第二个请求连核心都不进(负控拿掉闸门时, 这条会因为文案变成 TxBusy 而红)。
    if "恢复正在执行" in by.get("B", (0, 0, ""))[2]:
        ok("后到的请求由救援服务的并发闸门挡下(文案: 恢复正在执行, 请勿重复操作)")
    else:
        bad("409 不是闸门给的: %r" % by.get("B", (0, 0, ""))[2][-120:])
    if len([r for r in rec if r.get("state") in ("ROLLED_BACK", "ROLLBACK_FAILED")]) == 1:
        ok("并发只产生一条恢复记录")
    else:
        bad("产生了 %d 条恢复记录" % len(rec))
else:
    bad("并发实例起不来")
inst.stop()
box.clean()

# ── 8. 客户端中途断开: 恢复照样完成并留下审计 ───────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="bot")
inst = rescue_for(box)
if inst.start():
    st, cookie = inst.login()
    body = inst.req("GET", "/tx/" + txid, cookie=cookie)[1]
    m = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body)
    csrf = m.group(1) if m else ""
    payload = "csrf=%s&txid=%s&confirm=yes" % (csrf, txid)
    ctx = ssl._create_unverified_context()
    raw = socket.create_connection(("127.0.0.1", inst.port), timeout=10)
    tls = ctx.wrap_socket(raw)
    req = ("POST /tx/recover HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: %s\r\n"
           "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n%s"
           % (cookie, len(payload), payload))
    tls.sendall(req.encode())
    time.sleep(0.05)
    tls.close()                                   # 请求已发出, 立刻挂断
    deadline = time.time() + 30
    done = False
    while time.time() < deadline:
        mp = os.path.join(box.env["PDG_TX_ROOT"], txid, "meta.json")
        if os.path.isfile(mp):
            stt = json.load(open(mp, encoding="utf-8")).get("state")
            if stt in ("ROLLED_BACK", "ROLLBACK_FAILED"):
                done = True
                break
        time.sleep(0.3)
    if done:
        ok("客户端中途断开: 服务端的恢复仍然跑完")
    else:
        bad("断开后恢复没完成")
    # 状态到位**不等于**审计已落盘: 上面那个循环等的是 meta.json 的 state, 而审计是
    # 另一次写。机器慢的时候(CI 上真撞过)state 已经是 ROLLED_BACK 而审计还没 flush,
    # 于是这条断言拿到空列表。要等就各等各的, 不能拿一个信号去代表两件事。
    rec = []
    _dl = time.time() + 15
    while time.time() < _dl:
        rec = [r for r in audit_recs(box) if r.get("event") == "recover"]
        if rec and rec[-1].get("trigger_source") == "rescue":
            break
        time.sleep(0.3)
    if rec and rec[-1].get("trigger_source") == "rescue":
        ok("客户端中途断开: 最终审计仍然落盘(trigger_source=rescue)")
    else:
        bad("断开后审计缺失(等了 15s): %r" % rec)
    if inst.proc.poll() is None:
        ok("客户端中途断开: 服务进程没有被写响应失败搞崩")
    else:
        bad("进程退出了: %s" % inst.proc.poll())
else:
    bad("断线实例起不来")
inst.stop()
box.clean()

# ── 9. 哨兵不进 meta / 审计 / 日志 / HTML ───────────────────────────────────
box = Box()
txid, mos = make_stuck(box, src="bot")
with open(box.root + "/etc/privdns-gateway/profile.env", "w", encoding="utf-8") as f:
    f.write("PDG_INTERNAL_CIDR=127.0.0.0/8\nPDG_BOT_TOKEN=123456789:%s\n" % SENTINEL)
inst = rescue_for(box)
html_all = ""
if inst.start():
    st, cookie = inst.login()
    body = inst.req("GET", "/tx/" + txid, cookie=cookie)[1]
    m = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", body)
    st, rbody, _sc, _h = inst.req("POST", "/tx/recover",
                                  body="csrf=%s&txid=%s&confirm=yes" % (m.group(1) if m else "", txid),
                                  cookie=cookie)
    html_all = body + rbody + inst.req("GET", "/tx", cookie=cookie)[1]
inst.stop()
meta_txt = open(os.path.join(box.env["PDG_TX_ROOT"], txid, "meta.json"), encoding="utf-8").read()
audit_txt = open(os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl"), encoding="utf-8").read()
leaks = [n for n, t in (("meta", meta_txt), ("audit", audit_txt), ("html", html_all),
                        ("log", inst.err or "")) if SENTINEL in t or TOKEN in t]
if not leaks:
    ok("哨兵与 Token 不出现在 meta / 审计 / HTML / 日志里")
else:
    bad("泄漏到: %s" % leaks)
# 审计里也不该出现 cookie / csrf 字样
if "pdgsid" not in audit_txt and "pdgcsrf" not in audit_txt and "csrf" not in audit_txt:
    ok("审计里没有 Cookie / CSRF 痕迹")
else:
    bad("审计里出现了会话痕迹")
box.clean()

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

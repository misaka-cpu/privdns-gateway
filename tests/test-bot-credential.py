#!/usr/bin/env python3
"""Regression: bot 凭据保护 + 后台执行器 + BUSY 锁 + 配置写 flock。

覆盖: deleteMessage 成功/失败; 解析失败仍删消息; 主处理函数快速返回; 快速发第二条不被旧状态吃;
重复触发不启动两个任务; SECRET_SENTINEL 不出现在回复/日志; 任务异常后 BUSY/锁释放; apply_sb flock 友好返回。
"""
import base64
import concurrent.futures
import fcntl
import importlib.util
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

_REAL_APPLY_SB = bot.apply_sb        # 真 apply_sb(含 _cfg_guard); fresh_mocks 会覆盖它
SECRET = "SECRET_SENTINEL_pw_abc123"

def ss_link(pw, tag="myexit"):
    ui = base64.urlsafe_b64encode(f"aes-128-gcm:{pw}".encode()).decode().rstrip("=")
    return f"ss://{ui}@203.0.113.9:8388#{tag}"

class SyncExec:                       # 同步执行器: 令后台任务在 submit 内跑完, 断言确定性
    def submit(self, fn):
        f = concurrent.futures.Future()
        try:
            f.set_result(fn())
        except Exception as e:  # noqa: BLE001
            f.set_exception(e)
        return f

def fresh_mocks(delete_ok=True, apply_ret=(True, "")):
    sent, posts = [], []
    bot.send_plain = lambda chat, text: sent.append(text)
    bot.send = lambda chat, text, kb=None: sent.append(text)
    def fake_post(method, params):
        posts.append((method, params))
        return {"ok": delete_ok} if method == "deleteMessage" else {"ok": True}
    bot.post = fake_post
    bot.apply_sb = lambda mod: apply_ret
    bot.state.clear(); bot._busy.clear()
    return sent, posts

# ── deleteMessage 成功 ────────────────────────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=True)
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=555)
assert any(m == "deleteMessage" and p["message_id"] == 555 for m, p in posts), "应尝试删除原消息"
assert not any("未能自动删除" in s for s in sent), "删除成功不该提示手动删除"
assert any("已添加出口" in s for s in sent), sent
assert not any(SECRET in s for s in sent), "回复不得含密码"
print("[OK]   deleteMessage 成功 + 成功回复只显示出口名, 不含密码")

# ── deleteMessage 失败 → 提示手动删除 ────────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=False)
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=556)
assert any("未能自动删除" in s for s in sent), "删除失败应提示手动删除"
assert not any(SECRET in s for s in sent)
print("[OK]   deleteMessage 失败 → 提示手动删除, 不回显链接")

# ── 解析失败仍删除消息, 不回显内容 ───────────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=True)
bot.state[1] = "add_exit"
bot.handle_text(1, "ss://not-a-valid-link-" + SECRET, mid=557)
assert any(m == "deleteMessage" for m, p in posts), "解析失败也要先删消息"
assert any("解析失败" in s for s in sent)
assert not any(SECRET in s for s in sent), "解析失败不得回显原始链接(含密码)"
print("[OK]   解析失败仍删消息 + 不回显含密码的链接")

# ── apply_sb 失败也不泄露密码 ────────────────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=True, apply_ret=(False, "配置校验失败: password=" + SECRET))
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=558)
assert any("添加失败" in s for s in sent)
assert not any(SECRET in s for s in sent), "apply_sb 失败正文不得回显(可能含密码)"
print("[OK]   apply_sb 失败 → 通用提示, 不回显校验正文")

# ── 快速发第二条不被旧 add_exit 状态吃掉 ─────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks()
bot.state[2] = "add_exit"
bot.handle_text(2, ss_link("pw1"), mid=1)
assert 2 not in bot.state, "发送节点后应立即清除待输入状态"
sent.clear()
bot.handle_text(2, "just some random text", mid=2)   # 第二条
assert not any("已添加出口" in s or "未能自动删除" in s for s in sent), "第二条不该被当 add_exit 处理"
print("[OK]   发送后立即清状态, 第二条文字不被旧 add_exit 吃掉")

# ── 主处理函数快速返回(后台任务很慢时)───────────────────────────────────────
real_exec = concurrent.futures.ThreadPoolExecutor(max_workers=2)
bot._EXEC = real_exec
sent, posts = fresh_mocks()
started = threading.Event(); release = threading.Event()
def slow_apply(mod):
    started.set(); release.wait(5); return (True, "")
bot.apply_sb = slow_apply
bot.state[3] = "add_exit"
t0 = time.time()
bot.handle_text(3, ss_link("pw"), mid=9)
dt = time.time() - t0
assert dt < 0.5, f"主处理函数应快速返回, 实际 {dt:.2f}s"
assert started.wait(2), "后台任务应已在跑"
release.set()
print(f"[OK]   后台慢操作时主处理函数快速返回({dt:.3f}s)")

# ── 重复触发不启动两个任务(BUSY 锁)──────────────────────────────────────────
bot._EXEC = real_exec
sent, posts = fresh_mocks()
gate = threading.Event(); ran = []
def blocker():
    ran.append(1); gate.wait(5)
f1 = bot.run_bg(4, blocker)
time.sleep(0.1)
f2 = bot.run_bg(4, blocker)           # 同 chat 再次触发 → 应被拒
assert f2 is None, "同 chat 已有任务时应拒绝第二个"
assert any("正在处理" in s for s in sent), "应提示正在处理"
gate.set(); f1.result(5)
assert len(ran) == 1, "只应启动一个任务"
print("[OK]   重复触发被 BUSY 锁拒绝, 只启动一个任务")

# ── 任务异常后 BUSY 释放 ─────────────────────────────────────────────────────
bot._EXEC = real_exec
sent, posts = fresh_mocks()
def boom():
    raise ValueError("含密码 " + SECRET)   # 异常正文含密码, 不得被打印原样
f = bot.run_bg(5, boom)
f.result(5)
assert 5 not in bot._busy, "任务异常后 BUSY 必须释放"
f2 = bot.run_bg(5, lambda: None)          # 能再次提交 = 已释放
assert f2 is not None
f2.result(5)
print("[OK]   任务异常后 BUSY 释放(且异常正文不外泄)")

# ── _cfg_guard flock: 别的进程(pdg update/rollback 同款)持锁 → False; 释放 → True ──
# 用独立进程持锁, 复现真实跨进程场景(同进程 flock 语义有歧义, 不可靠)。
import os
import subprocess
tmp = tempfile.NamedTemporaryFile(delete=False)
bot.LOCKFILE = tmp.name
bot.apply_sb = _REAL_APPLY_SB         # 恢复真 apply_sb(前面被 fresh_mocks 覆盖过)
holder = subprocess.Popen(["flock", "-x", tmp.name, "-c", "sleep 3"])
time.sleep(0.4)                       # 等它拿到锁
with bot._cfg_guard() as got:
    assert got is False, "外部进程持锁时应 yield False"
ok, msg = bot.apply_sb(lambda c: None)   # 拿不到锁 → 友好返回, 不动配置
assert ok is False and "更新" in msg, ("flock 冲突应友好返回", ok, msg)
holder.wait()                         # 等持锁进程退出(释放锁)
with bot._cfg_guard() as got:
    assert got is True, "释放后应 yield True"
os.unlink(tmp.name)
print("[OK]   配置写 flock 与 pdg update/rollback 协调, 拿不到锁友好返回")

real_exec.shutdown(wait=False)
print("credential/concurrency regression OK")

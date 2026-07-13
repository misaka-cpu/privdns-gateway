#!/usr/bin/env python3
"""Regression: bot 凭据保护 + 后台执行器 + BUSY 锁 + 配置写 flock。

覆盖: deleteMessage 成功/失败; 解析失败仍删; BUSY 拒绝/提交失败路径仍独立删凭据; 主函数快速返回;
快速发第二条不被吃; 重复触发只跑一个; 锁冲突显示安全信息(非"校验未过"); SECRET_SENTINEL 不外泄;
任务异常后 BUSY 释放; apply_sb flock 非阻塞友好返回。
"""
import base64
import concurrent.futures
import importlib.util
import os
import subprocess
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
_rec = threading.Lock()

def ss_link(pw, tag="myexit"):
    ui = base64.urlsafe_b64encode(f"aes-128-gcm:{pw}".encode()).decode().rstrip("=")
    return f"ss://{ui}@203.0.113.9:8388#{tag}"

class SyncExec:                       # 同步执行器: 令后台任务在 submit 内跑完
    def submit(self, fn):
        f = concurrent.futures.Future()
        try:
            f.set_result(fn())
        except Exception as e:  # noqa: BLE001
            f.set_exception(e)
        return f

def fresh_mocks(delete_ok=True, apply_ret=(True, "")):
    sent, posts = [], []
    def sp(chat, text):
        with _rec:
            sent.append(text)
    bot.send_plain = sp
    bot.send = lambda chat, text, kb=None: sp(chat, text)
    def fake_post(method, params):
        with _rec:
            posts.append((method, params))
        return {"ok": delete_ok} if method == "deleteMessage" else {"ok": True}
    bot.post = fake_post
    bot.apply_sb = lambda mod: apply_ret
    bot.state.clear(); bot._busy.clear()
    return sent, posts

def wait_for(pred, t=3.0):
    end = time.time() + t
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.01)
    return pred()

def sent_has(sent, s):
    return lambda: any(s in x for x in list(sent))
def deleted(posts, mid=None):
    return lambda: any(m == "deleteMessage" and (mid is None or p["message_id"] == mid) for m, p in list(posts))
def no_secret(sent):
    with _rec:
        return not any(SECRET in x for x in sent)

# ── deleteMessage 成功 → 只显示出口名, 无手动删提示 ──────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=True)
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=555)
assert wait_for(deleted(posts, 555)), "应尝试删除原消息"
assert wait_for(sent_has(sent, "已添加出口")), sent
assert not any("未能自动删除" in s for s in sent) and no_secret(sent)
print("[OK]   deleteMessage 成功 + 成功回复只显示出口名, 不含密码")

# ── deleteMessage 失败 → 提示手动删除 ────────────────────────────────────────
sent, posts = fresh_mocks(delete_ok=False)
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=556)
assert wait_for(sent_has(sent, "未能自动删除")), "删除失败应提示手动删除"
assert no_secret(sent)
print("[OK]   deleteMessage 失败 → 提示手动删除, 不回显链接")

# ── BUSY 拒绝路径仍独立删凭据(关键回归)──────────────────────────────────────
sent, posts = fresh_mocks(delete_ok=True)
assert bot._acquire_busy(7) is True          # 模拟该 chat 已有任务在跑
bot.state[7] = "add_exit"
bot.handle_text(7, ss_link(SECRET), mid=777)
assert wait_for(deleted(posts, 777)), "BUSY 拒绝时凭据消息仍必须被删除"
assert wait_for(sent_has(sent, "正在处理")), "应提示正在处理上一项操作"
assert not any("已添加出口" in s for s in sent), "BUSY 时不该真的添加出口"
assert no_secret(sent)
bot._release_busy(7)
print("[OK]   BUSY 拒绝路径: 凭据消息仍被删除 + 提示正在处理")

# ── 解析失败仍删除消息, 不回显内容 ───────────────────────────────────────────
bot._EXEC = SyncExec()
sent, posts = fresh_mocks(delete_ok=True)
bot.state[1] = "add_exit"
bot.handle_text(1, "ss://not-a-valid-link-" + SECRET, mid=557)
assert wait_for(deleted(posts, 557)), "解析失败也要删消息"
assert wait_for(sent_has(sent, "解析失败")) and no_secret(sent)
print("[OK]   解析失败仍删消息 + 不回显含密码的链接")

# ── apply_sb 校验失败 → 通用提示, 不泄露正文 ─────────────────────────────────
sent, posts = fresh_mocks(delete_ok=True, apply_ret=(False, "配置校验失败: password=" + SECRET))
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=558)
assert wait_for(sent_has(sent, "添加失败")) and no_secret(sent)
print("[OK]   apply_sb 校验失败 → 通用提示, 不回显校验正文")

# ── apply_sb 锁冲突 → 显示安全的 BUSY_MSG, 不是"校验未过"──────────────────────
sent, posts = fresh_mocks(delete_ok=True, apply_ret=(False, bot.BUSY_MSG))
bot.state[1] = "add_exit"
bot.handle_text(1, ss_link(SECRET), mid=559)
assert wait_for(sent_has(sent, bot.BUSY_MSG)), "锁冲突应原样显示安全信息"
assert not any("校验未过" in s for s in sent), "锁冲突不该误报校验未过"
print("[OK]   锁冲突 → 显示准确安全信息(非'校验未过')")

# ── 快速发第二条不被旧 add_exit 状态吃掉 ─────────────────────────────────────
sent, posts = fresh_mocks()
bot.state[2] = "add_exit"
bot.handle_text(2, ss_link("pw1"), mid=1)
assert 2 not in bot.state, "发送节点后应立即清除待输入状态"
with _rec:
    sent.clear()
bot.handle_text(2, "just some random text", mid=2)
assert not any("已添加出口" in s or "未能自动删除" in s for s in sent), "第二条不该被当 add_exit"
print("[OK]   发送后立即清状态, 第二条文字不被旧 add_exit 吃掉")

# ── 主处理函数快速返回(后台很慢时)────────────────────────────────────────────
real_exec = concurrent.futures.ThreadPoolExecutor(max_workers=2)
bot._EXEC = real_exec
sent, posts = fresh_mocks()
started = threading.Event(); release = threading.Event()
def slow_apply(mod):
    started.set(); release.wait(5); return (True, "")
bot.apply_sb = slow_apply
bot.state[3] = "add_exit"
t0 = time.time(); bot.handle_text(3, ss_link("pw"), mid=9); dt = time.time() - t0
assert dt < 0.5, f"主处理函数应快速返回, 实际 {dt:.2f}s"
assert started.wait(2), "后台任务应已在跑"
release.set()
print(f"[OK]   后台慢操作时主处理函数快速返回({dt:.3f}s)")

# ── 重复触发只启动一个任务(BUSY 锁)──────────────────────────────────────────
sent, posts = fresh_mocks()
gate = threading.Event(); ran = []
def blocker():
    ran.append(1); gate.wait(5)
f1 = bot.run_bg(4, blocker); time.sleep(0.1)
f2 = bot.run_bg(4, blocker)
assert f2 is None and any("正在处理" in s for s in sent), "同 chat 第二个应被拒"
gate.set(); f1.result(5)
assert len(ran) == 1, "只应启动一个任务"
print("[OK]   重复触发被 BUSY 锁拒绝, 只启动一个任务")

# ── 任务异常后 BUSY 释放(异常正文不外泄)────────────────────────────────────
sent, posts = fresh_mocks()
def boom():
    raise ValueError("含密码 " + SECRET)
bot.run_bg(5, boom).result(5)
assert 5 not in bot._busy, "任务异常后 BUSY 必须释放"
bot.run_bg(5, lambda: None).result(5)
print("[OK]   任务异常后 BUSY 释放")

# ── _cfg_guard: 别的进程持 flock → False; 且 _cfg_lock 非阻塞 ────────────────
bot.apply_sb = _REAL_APPLY_SB
tmp = tempfile.NamedTemporaryFile(delete=False); tmp.close()
bot.LOCKFILE = tmp.name
holder = subprocess.Popen(["flock", "-x", tmp.name, "-c", "sleep 3"])
time.sleep(0.4)
with bot._cfg_guard() as got:
    assert got is False, "外部进程持锁时应 yield False"
ok, msg = bot.apply_sb(lambda c: None)
assert ok is False and msg == bot.BUSY_MSG, ("flock 冲突应返回 BUSY_MSG", ok, msg)
holder.wait()
with bot._cfg_guard() as got:
    assert got is True, "释放后应 yield True"
# 进程内 _cfg_lock 非阻塞: 已被占 → 立即 False(不卡)
bot._cfg_lock.acquire()
t0 = time.time()
with bot._cfg_guard() as got:
    assert got is False, "_cfg_lock 被占时应立即 False"
assert time.time() - t0 < 0.2, "非阻塞获取不该等待"
bot._cfg_lock.release()
os.unlink(tmp.name)
print("[OK]   配置写锁: 跨进程 flock 冲突返回 BUSY_MSG + 进程内锁非阻塞不卡")

real_exec.shutdown(wait=False)
print("credential/concurrency regression OK")

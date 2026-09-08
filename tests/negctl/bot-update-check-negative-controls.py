#!/usr/bin/env python3
"""负控: Bot 更新检查这几条判据有没有牙。

正控在 tests/test-bot-update-check.py。这里逐项把修复撤回去, 看正控会不会红。
撤回的都是**用户实际遇到过的那三个形态**: 整段 log 拼进消息、异常只包前半段、同步占主轮询。

夹具崩溃 / 导入失败 / 零断言 / 正控被超时强杀, 一律**不算检出** —— 那和"判据没牙"长得一样,
必须分开。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
BOT = "deploy/bot/pdg-bot.py"
POS = "tests/test-bot-update-check.py"
TOUCHED = [ROOT / BOT, ROOT / POS]
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


SRC = (ROOT / BOT).read_text(encoding="utf-8")


def lift(pattern, max_lines=24, flags=re.M | re.S):
    m = re.search(pattern, SRC, flags)
    assert m, pattern
    g = m.group(0)
    assert SRC.count(g) == 1, pattern
    n = g.count("\n") + 1
    assert n <= max_lines, "锚点跨度 %d 行 > %d: %s" % (n, max_lines, pattern)
    return g


RENDER = lift(r'^        return True, _upd_render\(cur, tgt, lines, _upd_repo_slug\(\)\)$')
TRY = lift(r'^    except _UpdCheckTimeout:\n.*?稍后重试。" % type\(e\)\.__name__$')
ASYNC = lift(r'^        if not _upd_check_async\(chat, mid\):\n.*?结果会更新到这条消息\)", BACK\); return$')
INVAL = lift(r'^    _upd_invalidate\(chat, mid\)$')
CLIP = lift(r'^    return line if len\(line\) <= UPD_LINE_MAX else line\[:UPD_LINE_MAX - 1\] \+ "…"$')
KILLPG = lift(r'^        try:\n            os\.killpg\(os\.getpgid\(p\.pid\), signal\.SIGKILL\)\n.*?p\.kill\(\)$')

MUT = [
    ("① 整段 log 拼回一条消息(不做长度预算)",
     [(RENDER,
       '        return True, ("🔄 有新发布 <b>%s</b>(当前 <code>%s</code>,含 %d 个提交):\\n"\n'
       '                      "<pre>%s</pre>\\n确认后后台执行 pdg update。"\n'
       '                      % (_esc(tgt), _esc(cur), len(lines), _esc("\\n".join(lines))))', 1)]),
    ("② 后半段异常不再兜底(恢复只包前半段)",
     [(TRY,
       '    except _UpdCheckTimeout:\n'
       '        raise\n'
       '    except subprocess.TimeoutExpired:\n'
       '        raise', 1)]),
    ("③ 回调恢复同步调用(占住主轮询)",
     [(ASYNC,
       '        edit(chat, mid, "🔄 检查更新中…", BACK)\n'
       '        has, txt = update_check()\n'
       '        edit(chat, mid, txt, UPD_CONFIRM_KB if has else BACK); return', 1)]),
    ("④ 取消归属作废(旧结果会覆盖新页面)",
     [(INVAL, '    pass  # 变异: 不再作废在飞的检查', 1)]),
    ("⑤ 单条标题不再裁剪(超长标题撑爆消息)",
     [(CLIP, '    return line', 1)]),
    ("⑥ 超时只杀父进程(留下 git 派生的助手)",
     [(KILLPG, '        try:\n            p.kill()\n        except Exception:  # noqa: BLE001\n            p.kill()', 1)]),
    ("⑦ 只加无关注释(反向对照)",
     [(INVAL, '    # (负控的空转对照)\n' + INVAL, 1)]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}
wd = tmpguard.mkdtemp(prefix="pdg-updcheck-negctl.")
shutil.rmtree(wd)          # git clone 要目标不存在
try:
    # 沙箱要有**真实的 git 历史与 tag**(正控要按 v1.11.3/v1.11.10 回放), 所以先 clone 一份 ——
    # worktree 里的 .git 是文件不是目录, 直接 copytree 会炸。clone 之后再把**当前工作树**的
    # tests/ deploy/ lib/ 覆盖上去, 于是历史是真的、被测代码是现在这一版。
    # 只读本地对象, 不写共享 refs/tag/remote。
    subprocess.run(["git", "clone", "-q", "--no-hardlinks", str(ROOT), wd], check=True,
                   env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    subprocess.run(["git", "-C", wd, "fetch", "-q", "--tags", "origin"], check=False)
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True, symlinks=True,
                        ignore=shutil.ignore_patterns("__pycache__", ".bin"))
    pristine = (Path(wd) / BOT).read_text(encoding="utf-8")

    def run_pos():
        """跑一次正控, 返回 (具名失败集合, 形态)。形态用来把「没牙」和「压根没跑起来」分开。"""
        try:
            r = subprocess.run([sys.executable, POS], cwd=wd, capture_output=True,
                               text=True, timeout=900, errors="replace")
        except subprocess.TimeoutExpired:
            return set(), "正控被超时强杀"
        out = r.stdout + r.stderr
        n_ok = len(re.findall(r"^\[OK\]", out, re.M))
        n_fail = len(re.findall(r"^\[FAIL\]", out, re.M))
        if "Traceback (most recent call last)" in out:
            return set(), "崩溃(Traceback)"
        if "ModuleNotFoundError" in out or "ImportError" in out:
            return set(), "导入失败"
        if n_ok + n_fail == 0:
            return set(), "零有效断言"
        if "通过 " not in out:
            return set(), "没有汇总行"
        fails = {re.sub(r"\s+", " ", l.strip())[:150]
                 for l in out.splitlines() if l.startswith("[FAIL]")}
        return fails, "正常"

    base, kind = run_pos()
    if kind != "正常":
        bad("基线正控没有正常运行(%s) —— 后面每一格都算不出「新增」" % kind)
        raise SystemExit(1)
    if base:
        bad("基线正控不绿(%d 条)" % len(base))
        for f in sorted(base)[:4]:
            print("       " + f[:140])
        raise SystemExit(1)
    ok("基线绿: 正控在未改坏的副本上 0 条具名失败")

    for tag, edits in MUT:
        text, good = pristine, True
        for anchor, repl, want in edits:
            hits = text.count(anchor)
            if hits != want:
                bad("%s → 锚点命中 %d 次, 期望 %d" % (tag, hits, want))
                good = False
                break
            after = text.replace(anchor, repl, want)
            if after == text:
                bad("%s → 改坏器空转" % tag)
                good = False
                break
            text = after
        if not good:
            continue
        (Path(wd) / BOT).write_text(text, encoding="utf-8")
        if subprocess.run([sys.executable, "-m", "py_compile", str(Path(wd) / BOT)],
                          capture_output=True).returncode != 0:
            bad("%s → 改坏后语法不合法" % tag)
            (Path(wd) / BOT).write_text(pristine, encoding="utf-8")
            continue
        got, kind = run_pos()
        (Path(wd) / BOT).write_text(pristine, encoding="utf-8")
        if kind != "正常":
            bad("%s → 正控没有正常运行(%s), 这一格既不算有牙也不算无牙" % (tag, kind))
            continue
        new = got - base
        if tag.startswith("⑦"):
            (ok if not new else bad)("%s → %d 条新增(应为 0)" % (tag, len(new)))
            continue
        if new:
            ok("%s → 新增具名失败 %d 条" % (tag, len(new)))
            for f in sorted(new)[:2]:
                print("       " + f[:135])
        else:
            bad("%s → 正控正常运行但 0 条转红, 这一格无效" % tag)
finally:
    shutil.rmtree(wd, ignore_errors=True)

clean = all(sha(p) == before[p] and os.stat(p).st_mode == modes[p] for p in TOUCHED)
(ok if clean else bad)("正式树未被污染: pdg-bot.py 与正控 sha256/mode 均一致"
                       if clean else "正式树被改动了!")
print("-" * 62)
print("bot-update-check-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

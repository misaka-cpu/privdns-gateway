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


PSRC = (ROOT / POS).read_text(encoding="utf-8")


def plift(pattern, max_lines=24, flags=re.M | re.S):
    """同 lift(), 但锚在**正控**里。21f 的所有权判据住在测试侧, 要验证"换回旧的全进程
    计数判据会怎样", 就必须能改坏正控本身 —— 否则那一格根本挂不上去。"""
    m = re.search(pattern, PSRC, flags)
    assert m, pattern
    g = m.group(0)
    assert PSRC.count(g) == 1, pattern
    n = g.count("\n") + 1
    assert n <= max_lines, "锚点跨度 %d 行 > %d: %s" % (n, max_lines, pattern)
    return g


GUARDCANCEL = lift(r'^            finally:\n                guard\.cancel\(\)$')
OWNA = plift(r'^\(ok if _a_ok else$')
OWNB = plift(r'^\(ok if \(not _b_ok\) and _b_stuck else$')

RENDER = lift(r'^        return True, _upd_render\(cur, tgt, lines, _upd_repo_slug\(deadline\)\)$')
TRY = lift(r'^    except _UpdCheckTimeout:\n.*?稍后重试。" % type\(e\)\.__name__$')
# 回调这一段在本轮重写过(受理返回三态 + 反馈全走后台), 锚点跟着挪。
ASYNC = lift(r'^        _acc, _tok = _upd_check_async\(chat, mid\)\n.*?^        return$', max_lines=18)
INVAL = lift(r'^    _upd_invalidate\(chat, mid\)$')
CLIP = lift(r'^    return line if len\(line\) <= UPD_LINE_MAX else line\[:UPD_LINE_MAX - 1\] \+ "…"$')
# ── 本轮新增的六条承重性质 ────────────────────────────────────────────────────
SENDLOCK = lift(r'^    with send_lock:$')
# ── 本轮六项 ──────────────────────────────────────────────────────────────────
POSTDL = lift(r'^        if deadline is not None:\n            left = deadline - time\.monotonic\(\)\n            if left <= 0:\n                print\("api", method, "deadline-exceeded"\); return \{\}$')
EDITDL = lift(r'^    if deadline is not None and time\.monotonic\(\) >= deadline:\n'
              r'        print\("edit_only give up: deadline"\); return False.*?$')
REAPER = lift(r'^                if now >= sess\["deadline"\] - UPD_DELIVER_BUDGET:$')
CANCEL = lift(r'^                if not sess or sess\.get\("job"\) != job or sess\.get\("cancelled"\):$')
DROPJOB = lift(r'^    if sess is not None and sess\.get\("job"\) == job:\n        _upd_sess\.pop\(\(chat, mid\), None\)$')
NOTICE = lift(r'^            job = _upd_new_sess\(chat, mid, now \+ UPD_NOTICE_BUDGET, kind="notice"\)\n            return ACCEPT_FULL, job$')
# 合并点本轮从"只看待发"改成"待发或在飞", 锚点跟着挪。
NOTEMERGE = lift(r'^        if key in _upd_notify_pending or key in _upd_notify_live:$')
INTENTVER = lift(r'^        ver, intent, last = _intent_now\(chat, mid\)$')
PHASE = lift(r'^            if sess\.get\("phase", 0\) >= want:\n                return False, "stale-phase"$')
# 忙/拒绝反馈现在一律经通道(notice 阶段), 锚点跟着挪。
NOTIFY_TOK = lift(r'^                        _upd_emit\(chat, mid, tok, "notice", txt, BACK\)$')
ADMIT = lift(r'^        if len\(_upd_inflight\) >= UPD_MAX_INFLIGHT:$')
SHALLOW = lift(r'^    if shallow\.returncode != 0 or _sv not in \("true", "false"\):\n.*?shallow\.returncode$')
SLUGCAP = lift(r'^        cap = 5 if deadline is None else min\(5, max\(0\.0, deadline - time\.monotonic\(\)\)\)$')
# 补绘已改成按用户意图版本收敛, 锚点指到它的调用点。
REPAINT = lift(r'^        if need_repaint and delivered:\n            _upd_repaint\(chat, mid, dl\)$')

# ── 本轮(绝对期限 / 撤销权限 / 通知生命周期)的锚点 ─────────────────────────────
REUSETO = lift(r'^                conn\.timeout = _to\n'
               r'                if conn\.sock is not None:\n'
               r'                    conn\.sock\.settimeout\(_to\)$')
# 空 token 有两道拦截(入口快速判 + 取到投递锁后复查)。单撤一道另一道仍拦得住 ——
# 要撤就两道一起撤, 否则这一格没牙。
EMITNULL = lift(r'^    if token is None:$')
EMITNULL2 = lift(r'^            if not sess or sess\.get\("token"\) is None or sess\.get\("token"\) != token:$')
REVOKED = lift(r'^                if sess\.get\("token"\) is None:$')
REAPMINE = lift(r'^                mine = cur is not None and cur\.get\("job"\) == job$')
REAPREVOKE = lift(r'^                if mine and not revoked:$')
NOTICEREL = lift(r'^    cur = _upd_sess\.get\(\(chat, mid\)\)\n'
                 r'    if cur is not None and cur\.get\("job"\) == job:\n'
                 r'        if cur\.get\("kind"\) == "notice":\n'
                 r'            _upd_drop_sess\(chat, mid, job\)$')
NOTICEKIND = lift(r'^        if cur\.get\("kind"\) == "notice":\n'
                  r'            _upd_drop_sess\(chat, mid, job\)$')
NOTICECAP = lift(r'^        if len\(_upd_notify_live\) >= UPD_NOTICE_MAX:$')
READCLOSE = lift(r'^    resp\.close\(\)\n    return bytes\(buf\)$')

# ── 本轮(完整响应期限 / 回收器撤销窗口)的锚点 ─────────────────────────────────
# _api_read 里的逐轮期限检查、逐轮 settimeout, 以及用 read1 而不是 read —— 这三处**没有**
# 对应的变异格。加了 _ApiGuard 之后它们被完全包住: 实测单撤 ㉕、合并撤 ㉕+㊵、以及 read1
# 换回 read, 都是 0 条转红。它们是同线程的第一道(不依赖定时器线程被调度), 保留在实现里,
# 但按纪律不计入"已验证" —— 一格永远不会红的对照等于没有对照。
# 若将来去掉 guard, 必须把这几格补回来。
GUARDARM = lift(r'^            sk = conn\.sock\n            guard = _ApiGuard\(sk, deadline\)$')
GUARDFIRE = lift(r'^    def _fire\(self\):\n'
                 r'        self\.fired = True\n'
                 r'        try:\n'
                 r'            self\.sock\.shutdown\(socket\.SHUT_RDWR\)$')
GUARDCHK = lift(r'^            if guard\.fired:\n                raise _ApiDeadline\(\)$')
LATECHK = lift(r'^            if deadline is not None and time\.monotonic\(\) >= deadline:\n'
               r'                # 逐轮检查通过之后才读完的那一次.*?\n.*?\n'
               r'                raise _ApiDeadline\(\)$', max_lines=6)
REAPRECHK = lift(r'^                revoked = mine and cur\.get\("token"\) is None$')
SESSOLD = lift(r'^    old = _upd_sess\.get\(\(chat, mid\)\)\n'
               r'    if old is not None:\n'
               r'        _upd_jobs\.pop\(old\.get\("job"\), None\)$')
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
       '        edit(chat, mid, "🔄 检查更新中…(结果会更新到这条消息)", BACK)\n'
       '        has, txt = update_check()\n'
       '        edit(chat, mid, txt, UPD_CONFIRM_KB if has else BACK)\n'
       '        return', 1)]),
    ("④ 取消归属作废(旧结果会覆盖新页面)",
     [(INVAL, '    pass  # 变异: 不再作废在飞的检查', 1)]),
    ("⑤ 单条标题不再裁剪(超长标题撑爆消息)",
     [(CLIP, '    return line', 1)]),
    ("⑥ 超时只杀父进程(留下 git 派生的助手)",
     [(KILLPG, '        try:\n            p.kill()\n        except Exception:  # noqa: BLE001\n            p.kill()', 1)]),
    ("⑦ 取消按消息串行化投递(阶段序只管准入, 落地会乱序)",
     [(SENDLOCK, '    if True:', 1)]),
    ("⑧ 取消阶段序(低阶段可以盖掉已落地的高阶段)",
     [(PHASE, '            if False:\n                return False, "stale-phase"', 1)]),
    ("⑨ 忙反馈绕过通道(退化成裸 edit_only)",
     [(NOTIFY_TOK, '                        edit_only(chat, mid, txt, BACK)', 1)]),
    ("⑩ 取消全局准入上限(线程有限≠队列有界)",
     [(ADMIT, '        if False:', 1)]),
    ("⑪ shallow 探测不校验退出码/取值",
     [(SHALLOW, '    if False:\n        return False, "x" % shallow.returncode', 1)]),
    ("⑫ origin 查询另拿独立预算",
     [(SLUGCAP, '        cap = 5', 1)]),
    ("⑬ 取消导航抢写后的收敛修复",
     [(REPAINT, '        if False:\n            _upd_repaint(chat, mid, dl)', 1)]),
    ("⑮ post 忽略 deadline(投递回到恒定 70s + 必重连)",
     [(POSTDL, '        if False:\n            left = 0\n            if left <= 0:\n'
               '                print("x"); return {}', 1)]),
    ("⑯ edit_only 期限到了仍然回退重试",
     [(EDITDL, '    if False:\n        print("x"); return False', 1)]),
    ("⑰ 取消收割线程的排队裁决(回到等空闲 worker)",
     [(REAPER, '                if False:', 1)]),
    ("⑱ 迟到启动的旧任务仍然执行(不看 cancelled)",
     [(CANCEL, '                if not sess or sess.get("job") != job:\n                    return', 1)]),
    ("⑲ 清理按写入权而不是稳定身份(作废后漏清理)",
     [(DROPJOB, '    if sess is not None and sess.get("token") == job:\n        _upd_sess.pop((chat, mid), None)', 1)]),
    ("⑳ 拒绝通知不再建归属(裸通知, 不可作废)",
     [(NOTICE, '            return ACCEPT_FULL, None', 1)]),
    ("㉑ 通知不合并(每次点击都排一份新工作)",
     [(NOTEMERGE, '        if False:', 1)]),
    ("㉒ 补绘回到猜「最近一次写入」而非最新意图",
     [(INTENTVER, '        ver, intent, last = (0, None, None)', 1)]),
    # ── A: 绝对期限贯穿真实请求 ──
    ("㉔ 复用的连接不按剩余预算重设超时(缓存超时)",
     [(REUSETO, '                pass', 1)]),
    ("㉟ 按块读之后不收尾(keep-alive 名存实亡, 每次都白重连一次)",
     [(READCLOSE, '    return bytes(buf)', 1)]),
    ("㊱ 期限不覆盖状态行/响应头(守卫不武装, getresponse 裸奔)",
     [(GUARDARM, '            sk = conn.sock\n            guard = _ApiGuard(sk, None)', 1)]),
    ("㊲ 守卫到点不结束实际网络工作(只置标志, 不 shutdown)",
     [(GUARDFIRE, '    def _fire(self):\n        self.fired = True\n        try:\n'
                  '            pass', 1)]),
    ("㊳ 超期不再判失败(守卫开火与读完后两处判定一起撤)",
     [(GUARDCHK, '            if False:\n                raise _ApiDeadline()', 1),
      (LATECHK, '            if False:\n                raise _ApiDeadline()', 1)]),
    # ── B: 撤销即撤销 ──
    ("㊶ 回收器动作前不重读撤销状态(用快照时的 revoked 裁决)",
     [(REAPRECHK, '                revoked = False', 1)]),
    ("㉖ 空 token 重新被当成写回权(两道拦截一起撤: None == None 放行)",
     [(EMITNULL, '    if False:', 1),
      (EMITNULL2, '            if not sess or sess.get("token") != token:', 1)]),
    ("㉗ 排队期间被撤销的任务照样执行",
     [(REVOKED, '                if False:', 1)]),
    ("㉘ 过期处理靠新建通知恢复写回权(不看撤销事实)",
     [(REAPREVOKE, '                if mine:', 1)]),
    ("㉙ 收割器动作前不重新核对身份(会覆盖后来的新任务)",
     [(REAPMINE, '                mine = True', 1)]),
    # ── C: 通知生命周期与全局准入 ──
    ("㉚ 通知投递完不释放自己的记录",
     [(NOTICEREL, '    cur = None\n    if cur is not None and cur.get("job") == job:\n'
                  '        if cur.get("kind") == "notice":\n'
                  '            _upd_drop_sess(chat, mid, job)', 1)]),
    ("㉛ 通知收尾不看 kind(忙提示把在跑的检查会话一起收掉)",
     [(NOTICEKIND, '        if True:\n            _upd_drop_sess(chat, mid, job)', 1)]),
    ("㉜ 通知排队没有全局上限(只限执行线程数)",
     [(NOTICECAP, '        if False:', 1)]),
    ("㉝ 替换会话不摘旧身份(_upd_jobs 单调增长)",
     [(SESSOLD, '    old = None', 1)]),
    # ── C: 21f 的资源归属 ──
    ("㊴ 换回旧的全进程计数判据(丢掉资源归属)",
     [(OWNA, '(ok if _a_after == _a_before else', 1),
      (OWNB, '(ok if _b_after != _b_before else', 1)], POS),
    ("㊵ 正常路径不再取消守卫(cancel 撤掉, 线程留到 60s 期限)",
     [(GUARDCANCEL, '            finally:\n                pass', 1)]),
    ("㉓ 只加无关注释(反向对照)",
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
    pristine = {f: (Path(wd) / f).read_text(encoding="utf-8") for f in (BOT, POS)}

    _crash = {"out": None}

    def _stash(out):
        """把这一次"没跑正常"的完整输出留住 —— 只报个形态, 排查时等于什么都没说。"""
        _crash["out"] = out

    def _crash_excerpt():
        out = _crash["out"] or ""
        i = out.find("Traceback (most recent call last)")
        if i < 0:
            return [l for l in out.splitlines() if l.strip()][-6:]
        return out[i:].splitlines()[:14]

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
            _stash(out)
            return set(), "崩溃(Traceback)"
        if "ModuleNotFoundError" in out or "ImportError" in out:
            _stash(out)
            return set(), "导入失败"
        if n_ok + n_fail == 0:
            _stash(out)
            return set(), "零有效断言"
        if "通过 " not in out:
            _stash(out)
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

    for _entry in MUT:
        tag, edits = _entry[0], _entry[1]
        tgt = _entry[2] if len(_entry) > 2 else BOT     # 默认改坏产品; 声明了就改那一支
        text, good = pristine[tgt], True
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
        (Path(wd) / tgt).write_text(text, encoding="utf-8")
        if subprocess.run([sys.executable, "-m", "py_compile", str(Path(wd) / tgt)],
                          capture_output=True).returncode != 0:
            bad("%s → 改坏后语法不合法" % tag)
            (Path(wd) / tgt).write_text(pristine[tgt], encoding="utf-8")
            continue
        got, kind = run_pos()
        (Path(wd) / tgt).write_text(pristine[tgt], encoding="utf-8")
        if kind != "正常":
            bad("%s → 正控没有正常运行(%s), 这一格既不算有牙也不算无牙" % (tag, kind))
            for _l in _crash_excerpt():
                print("       | " + _l[:150])
            continue
        new = got - base
        if tag.startswith("㉓"):
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

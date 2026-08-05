#!/usr/bin/env python3
"""一次性临时目录: **建的时候就登记, 退出时按登记表清** —— 只清本进程这一次建的。

为什么不是"跑完扫一遍 /tmp, 把 pdgtx-* 前缀的都删掉":
那是在删**别人的**沙箱。这个仓库的测试经常并发跑(几支 py 测试同时开, 加上一个正在跑的
E2E), 前缀相同的目录里有一半是隔壁进程正用着的; 按前缀扫等于随机破坏并发中的用例, 而且
症状是"另一支测试莫名其妙红了", 排查成本极高。登记表是唯一安全的依据: 本进程建了什么,
就只清什么。

用法(替掉 tempfile.mkdtemp):

    import tmpguard
    d = tmpguard.mkdtemp(prefix="pdgtx-faults.")     # 进程退出时自动清
    ...
    tmpguard.cleanup(d)                              # 想早点清也行(幂等, 会销号)

留现场: 置 `PDG_KEEP_TMP=1`(或任意非空非 0 值)则一个都不清, 并把路径打到 stderr ——
调试失败用例时要的就是那堆残骸, 不能因为"清理做得好"而没法排查。

清理时机覆盖三条路径(测试红的时候恰恰最需要它):
  · 正常返回 / sys.exit    → atexit
  · 抛异常 / 断言失败      → atexit(解释器仍走正常退出流程)
  · SIGTERM(CI 超时杀)     → 自装处理器, 清完再按默认语义死掉
SIGKILL 和 os._exit() 清不掉 —— 那两条路径谁也拦不住, 如实说明, 不假装覆盖。
"""
import atexit
import os
import shutil
import signal
import stat
import sys
import tempfile

KEEP_ENV = "PDG_KEEP_TMP"

# (pid, path) —— pid 是必需的: pty.fork()/os.fork() 出来的子进程继承整张表, 子进程退出时
# 它的 atexit 会照着表把**父进程还在用的**目录删掉。带上 pid 就只有建它的那个进程会动手。
_REG = []
_INSTALLED = False


def keeping():
    """是否要留现场。"""
    return os.environ.get(KEEP_ENV, "") not in ("", "0")


def _rmtree(path):
    """删掉一棵目录树。已经不在了当作已完成 —— 用例自己 rmtree 过是常态, 不该因此报错。

    真删不掉(权限/占用)则**照旧抛出来**: 那是"清理没做到", 不是"没什么可清"。
    ignore_errors=True 会把两者混为一谈, 于是漏了也没人知道。
    """
    if not os.path.exists(path):
        return
    shutil.rmtree(path, onerror=_force_rw)


def _force_rw(func, path, _exc):
    """rmtree 的兜底: 目录被故意置成不可写(如 0o500 的只读目录)时先把权限改回来再删。

    故障注入用例会造这种目录(`_unwritable_lock_path`), 不处理的话清理会静默失败 ——
    ignore_errors=True 能让它"看着清干净了", 但那是把漏当成没漏, 所以这里选择真的去删。
    """
    try:
        parent = os.path.dirname(path)
        os.chmod(parent, os.stat(parent).st_mode | stat.S_IRWXU)
        os.chmod(path, os.stat(path).st_mode | stat.S_IRWXU)
    except OSError:
        pass
    func(path)


def _install():
    global _INSTALLED
    if _INSTALLED:
        return
    _INSTALLED = True
    atexit.register(_cleanup_all)
    # SIGTERM 默认直接死, atexit 不会跑 —— CI 的 `timeout` 走的正是这条路。只在没人接管过
    # 信号时才装, 不覆盖用例自己的处理器(有几支就是在验信号行为的)。
    try:
        if signal.getsignal(signal.SIGTERM) is signal.SIG_DFL:
            signal.signal(signal.SIGTERM, _on_sigterm)
    except ValueError:
        # 首次建目录发生在工作线程里 —— signal.signal 只能在主线程调。装不上就算了,
        # atexit 那条路照常有效; 硬抛会把一支正常的并发用例弄红, 得不偿失。
        pass


def _on_sigterm(_sig, _frm):
    _cleanup_all()
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGTERM)


def mkdtemp(prefix=None, suffix=None, dir=None):  # noqa: A002 - 与 tempfile 同名参数
    """建一个一次性目录并登记。参数与 tempfile.mkdtemp 一致。"""
    d = tempfile.mkdtemp(prefix=prefix, suffix=suffix, dir=dir)
    register(d)
    return d


def register(path):
    """把一个**已经存在**的路径纳入登记表(自己 os.makedirs 出来的也能托管)。"""
    _install()
    ent = (os.getpid(), os.path.abspath(path))
    if ent not in _REG:
        _REG.append(ent)
    return path


def cleanup(path):
    """立刻清掉某个已登记的路径并销号。幂等; 留现场模式下只销号不删。

    循环里反复建沙箱的用例(如 txbox 的 50 次建/清)要用它, 否则登记表会一直涨,
    磁盘上的目录也要等进程退出才消失。
    """
    p = os.path.abspath(path)
    me = os.getpid()
    _REG[:] = [e for e in _REG if e != (me, p)]
    if keeping():
        return
    _rmtree(p)


def registered():
    """本进程当前还登记着哪些路径(供判据自查)。"""
    me = os.getpid()
    return [p for pid, p in _REG if pid == me]


def _cleanup_all():
    me = os.getpid()
    mine = [p for pid, p in _REG if pid == me]
    _REG[:] = [e for e in _REG if e[0] != me]
    if not mine:
        return
    if keeping():
        sys.stderr.write("[%s] 保留 %d 个临时目录(留现场):\n" % (KEEP_ENV, len(mine)))
        for p in mine:
            sys.stderr.write("  %s\n" % p)
        return
    for p in reversed(mine):        # 后建的先删: 嵌套目录时子目录先走
        _rmtree(p)

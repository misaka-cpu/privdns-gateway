#!/usr/bin/env python3
"""事务测试用的一次性沙箱(供 test-config-transaction*.py 共用)。

不是 mock 事务逻辑, 而是给它造一个**真实的外部世界**: 沙箱文件树 + 假 systemctl/nft/mihomo
(会把调用记进日志, 也能按需装成失败或"起来即崩")+ 真的 UDP DNS 应答器与 TCP 监听 ——
硬门探针因此有真实落点, 判据本身一行都没关掉。
"""
import importlib.util
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard  # noqa: E402


class PycacheIsolation:
    """负控专用: 让每次"改坏源码 → 跑 → 恢复 → 再跑"都用**独有且为空**的字节码缓存。

    CPython 默认的 __pycache__ 按**秒级 mtime + 文件长度**判定源码是否变过。负控恰恰在同一秒
    内把源码改成等长内容, 判据完全命中旧记录 → 跑的是上一版字节码, 于是"负控通过"验的其实是
    没被改过的旧代码; 恢复源码后同理会继续读坏版本。这不是理论风险, 是本项目真踩过的一次
    假结果。

    用法:
        with PycacheIsolation(work_dir) as pc:
            run_child(env=pc.env())      # 第一次
            pc.reset()                   # 每次负控前清空, 保证"空"
            run_child(env=pc.env())      # 改坏之后
    退出时只删自己那一个目录, 不碰仓库里的 __pycache__。
    """

    def __init__(self, parent):
        self.dir = tempfile.mkdtemp(prefix="pycache.", dir=parent)

    def env(self, base=None):
        e = dict(base if base is not None else os.environ)
        e["PYTHONPYCACHEPREFIX"] = self.dir
        return e

    def reset(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        os.makedirs(self.dir, exist_ok=True)

    def files(self):
        out = []
        for root, _d, names in os.walk(self.dir):
            out += [os.path.join(root, n) for n in names]
        return out

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def load_tx(env):
    """按给定环境变量加载事务核心(模块级常量会读环境, 故每个沙箱重新导入一次)。"""
    for k, v in env.items():
        os.environ[k] = v
    spec = importlib.util.spec_from_file_location("pdgtx_%d" % time.time_ns(),
                                                  ROOT / "deploy/bot/pdgtx.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class Box:
    """一次性沙箱: 假文件树 + 假 systemctl/nft/mihomo/mosdns/sysctl。"""

    def __init__(self, svc_fail=None, restart_crash=False, healthy=True):
        # 走 tmpguard: 用例忘了 clean()、或者在中途抛异常, 目录仍会在进程退出时被清掉。
        # 它只是兜底 —— 探针线程和端口还是要靠 clean() 才收得回来, 所以该调还得调
        # (推荐 `with Box() as b:`)。
        self.root = tmpguard.mkdtemp(prefix="pdgtx-box.")
        self.bin = os.path.join(self.root, "stub-bin")
        os.makedirs(self.bin)
        self.calls = os.path.join(self.root, "calls.log")
        self.state = os.path.join(self.root, "svcstate")
        os.makedirs(self.state)
        self._systemctl(self._check_units(svc_fail), restart_crash)
        self._simple("nft", 0)
        self._simple("mihomo", 0)
        self._simple("sysctl", 0)
        self._simple("openssl", 0)
        for d in ("/etc/sing-box/rs", "/etc/mosdns/rules", "/etc/mihomo",
                  "/etc/privdns-gateway", "/opt/pdg-bot", "/run", "/etc/systemd/system"):
            os.makedirs(self.root + d, exist_ok=True)
        # 硬门探针的真实落点: 一个真 UDP DNS 应答器 + 一个真 TCP 监听。
        # 判据没有被关掉 —— 把它们停掉, 健康检查就会真的判失败(见"退化"用例)。
        self._probes = []
        # 探针线程的句柄与停止信号。以前两样都没有: `clean()` 只关 socket, 而在 Linux 上
        # 关闭 fd **不会**唤醒另一个线程里阻塞的 recvfrom()/accept() —— 那个线程会一直挂着,
        # 连带把监听端口也一直占着(实测: 建 30 个 Box 后进程里 91 个线程, 等多久都不减,
        # clean() 之后 TCP 端口仍然能连上)。现在改成: 短超时 + 停止事件 + 有上限的 join。
        self._probe_threads = []
        self._probe_started = 0             # 起了几个探针 —— 与登记数对不上就是漏登记了
        self._stop = threading.Event()
        self.dns_port = self._start_dns() if healthy else 1
        self.redir_port = self._start_tcp() if healthy else 1
        self.dot_port = self._start_tcp() if healthy else 1
        self.env = {
            "PDG_TX_DNS_PROBE": "127.0.0.1:%d" % self.dns_port,
            "PDG_TX_REDIR_PORT": str(self.redir_port),
            "PDG_TX_DOT_PORT": str(self.dot_port),
            "PDG_TX_FSROOT": self.root,
            "PDG_TX_ROOT": self.root + "/var/lib/privdns-gateway/tx",
            "PDG_LOCKFILE": self.root + "/run/privdns-gateway.lock",
            "PDG_STABLE_SAMPLES": "1",
            "PDG_STABLE_INTERVAL": "0.05",     # 采样间隔: 沙箱里没必要按真机的 0.6s 等
            "PATH": self.bin + os.pathsep + os.environ["PATH"],
        }

    def _start_dns(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        # 短超时是**唯一**能让阻塞中的 recvfrom 定期回来看停止事件的办法 —— 关 fd 不行。
        # 0.2s 对 DNS 应答的实时性毫无影响(应答仍是收到就回), 只影响退出的最坏延迟。
        s.settimeout(0.2)
        self._probes.append(s)
        stop = self._stop

        def loop():
            while not stop.is_set():
                try:
                    data, addr = s.recvfrom(512)
                except socket.timeout:      # 超时只是"这一轮没人问", 回去看停止事件
                    continue
                except OSError:             # socket 被关了 / 出错 → 收工
                    return
                try:
                    s.sendto(data[:2] + b"\x81\x83" + data[4:12], addr)   # 回一个 NXDOMAIN
                except socket.timeout:
                    continue
                except OSError:
                    return

        t = threading.Thread(target=loop, daemon=True, name="pdgtx-box-dns:%d" % port)
        t.start()
        self._probe_started += 1
        self._probe_threads.append(t)
        # **就绪同步**: 线程起来之前(或解释器忙得没调度到它时)事务的 DNS 硬门会拿不到应答,
        # 于是"基线好、观察期坏"被误判成本次操作造成的退化 —— 那是沙箱的锅, 不是判据的锅。
        # 这里先自己问一次, 确认应答器真的在服务了再把端口交出去; 判据本身一行没改。
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.settimeout(0.3)
        try:
            deadline = time.time() + 5
            while time.time() < deadline:
                try:
                    probe.sendto(b"\x00\x01\x01\x00" + b"\x00" * 8, ("127.0.0.1", port))
                    probe.recvfrom(512)
                    break
                except OSError:
                    continue
            else:
                raise RuntimeError("沙箱 DNS 应答器 5 秒内没就绪")
        finally:
            probe.close()
        return port

    def _start_tcp(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0)); s.listen(8)
        port = s.getsockname()[1]
        s.settimeout(0.2)                   # 同上: 让 accept 能定期回来看停止事件
        self._probes.append(s)
        stop = self._stop

        def loop():
            while not stop.is_set():
                try:
                    c, _ = s.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                c.close()

        t = threading.Thread(target=loop, daemon=True, name="pdgtx-box-tcp:%d" % port)
        t.start()
        self._probe_started += 1
        self._probe_threads.append(t)
        return port

    JOIN_TIMEOUT = 8.0                      # 单个探针线程最多等这么久

    def stop_probes(self):
        """停掉全部探针并**确认它们真的退出了**。可重复调用。

        顺序有讲究: 先置停止事件, 再关 socket。反过来的话线程可能正卡在 recvfrom 里,
        关 fd 唤不醒它, 而它下一轮才会看到事件 —— 两种顺序最终都能退, 但先置事件退得更快。

        超时仍活着就**抛异常**, 不静默忽略: 那正是这个夹具以前的毛病 —— 悄悄漏着, 谁也
        不知道进程里堆了多少线程和端口。"""
        missing = self._probe_started - len(self._probe_threads)
        self._stop.set()
        # **先 join, 后关 socket**。反过来写的话线程会因为"在已关闭的 socket 上 recvfrom"
        # 抛 OSError 而退出 —— 看着也能停, 但停止事件就成了摆设: 哪天有人把它删了,
        # 一样绿。顺序改过来之后, join 窗口里 socket 还开着, 能停下来的只有那个事件。
        # 附带好处: 不再出现"线程正在 sendto 而主线程把 socket 关了"那种半路报错。
        stuck = []
        for t in self._probe_threads:
            t.join(timeout=self.JOIN_TIMEOUT)
            if t.is_alive():
                stuck.append(t.name)
        self._probe_threads = []
        for s in self._probes:
            try:
                s.close()
            except OSError:
                pass
        self._probes = []
        if stuck:
            raise RuntimeError("探针线程在 %.0f 秒内没退出: %s"
                               % (self.JOIN_TIMEOUT, ", ".join(stuck)))
        if missing > 0:
            raise RuntimeError("有 %d 个探针起来了却没被登记 —— 它们不会被 join, "
                               "端口也不会被关" % missing)
        self._probe_started = 0

    @staticmethod
    def _check_units(svc_fail):
        """svc_fail 只收**单元名的列表**; 形状不对当场抛, 不静默退化成"一个都没配"。

        传字符串不会报错, 但 _systemctl 里的 " ".join 会把它按字符拆开, fail 列表就成了
        `/ t m p / f o r m f l o w` 这种谁也匹配不上的东西 —— 桩看着配上了, 其实没有任何
        服务会失败, 用例照样全绿。两支用例真这么写过(把 `Inst(work, ...)` 的第一个位置参数
        抄了过来, 而 Box 自己建根目录、根本不收路径)。
        """
        if svc_fail is None:
            return []
        if isinstance(svc_fail, (str, bytes)):
            raise TypeError("svc_fail 要的是单元名列表(如 [\"mosdns\"]), 不是字符串: %r"
                            % (svc_fail,))
        units = list(svc_fail)
        for u in units:
            # 带空白的名字会被桩里的 `for f in %s` 拆成两个词, 同样谁也匹配不上。
            if not isinstance(u, str) or u.split() != [u]:
                raise TypeError("svc_fail 的成员要是不含空白的单元名: %r" % (u,))
        return units

    def _write(self, name, body):
        p = os.path.join(self.bin, name)
        with open(p, "w") as f:
            f.write(body)
        os.chmod(p, 0o755)

    def _systemctl(self, fail_units, crash):
        # is-active 读 <state>/<unit>; restart 写 active(或按 fail 列表失败)。
        # crash=True 时模拟"坏配置起来即崩": restart 时看 config.json 里有没有 CRASH_MARK ——
        # 有就进入崩溃循环(NRestarts 每问一次涨一次), 换回旧配置再 restart 就恢复正常。
        # 这样回滚是否**真的解决问题**才有意义, 而不是让桩无条件永远崩。
        # ActiveState: 事务的 stop 判据看的是它(failed / activating / deactivating 都不能冒充
        # "已停下"), 所以桩必须能表达这些状态 —— 用 <unit>.state 文件放任意 ActiveState,
        # 用 <unit>.stopstate 表达"stop 之后它会落到哪个状态"(如 failed)。
        self._write("systemctl", """#!/bin/bash
echo "systemctl $*" >> %s
S=%s
case "$1" in
  is-active) [[ -f "$S/$2.active" ]] && { echo active; exit 0; }; echo inactive; exit 3;;
  show)  # show -p PROP --value UNIT
    U="${!#}"; P="$3"; [[ "$2" != "-p" ]] && P="$2"
    case "$P" in
      NRestarts) n=$(cat "$S/$U.nr" 2>/dev/null || echo 0)
                 if [[ -f "$S/$U.crash" ]]; then n=$((n+1)); echo $n > "$S/$U.nr"; fi
                 echo "$n";;
      UnitFileState) cat "$S/$U.ufs" 2>/dev/null || echo enabled;;
      LoadState) echo loaded;;
      SubState)
        # ActiveState=activating 有两种截然不同的处境, 只有 SubState 分得清:
        # start/start-pre(真在启动) vs auto-restart(崩了在等下次重试)。桩必须能表达,
        # 否则"崩溃重启循环能不能被修好"这条根本验不到。
        if [[ -f "$S/$U.sub" ]]; then cat "$S/$U.sub"
        elif [[ -f "$S/$U.active" ]]; then echo running
        else echo dead; fi;;
      ActiveState)
        M=$(cat "$S/__as_mode" 2>/dev/null || echo normal)
        case "$M" in
          fail)  exit 1;;                      # 查询失败(命令返回非 0)
          empty) echo "";;                     # 命令成功但没输出
          normal)
            if [[ -f "$S/$U.state" ]]; then cat "$S/$U.state"
            elif [[ -f "$S/$U.active" ]]; then echo active
            else echo inactive; fi;;
          *) echo "$M";;                       # 直接给一个字面状态(activating 之类)
        esac;;
      *) echo "";;
    esac; exit 0;;
  restart|start)
    for f in %s; do [[ "$2" == "$f" ]] && { echo "$1 refused"; exit 1; }; done
    touch "$S/$2.active"; rm -f "$S/$2.state" "$S/$2.sub"; %s
    exit 0;;
  stop)
    [[ -f "$S/$2.nostop" ]] && { echo "stop refused"; exit 1; }
    rm -f "$S/$2.active"
    if [[ -f "$S/$2.stopstate" ]]; then cp "$S/$2.stopstate" "$S/$2.state"; else rm -f "$S/$2.state"; fi
    exit 0;;
  reset-failed|daemon-reload|enable|disable) exit 0;;
esac
exit 0
""" % (self.calls, self.state, " ".join(fail_units) or "__none__",
        ('if grep -q CRASHME %s/etc/sing-box/config.json 2>/dev/null; '
         'then touch "$S/$2.crash"; else rm -f "$S/$2.crash" "$S/$2.nr"; fi' % self.root)
        if crash else ":"))

    def _simple(self, name, rc):
        self._write(name, '#!/bin/bash\necho "%s $*" >> %s\nexit %d\n' % (name, self.calls, rc))

    def fail_cmd(self, name):
        self._simple(name, 1)

    def up(self, unit):
        open(os.path.join(self.state, unit + ".active"), "w").close()

    def down(self, unit):
        """让 unit 变成"没在跑"(ActiveState=inactive)。"""
        for suf in (".active", ".state"):
            try:
                os.unlink(os.path.join(self.state, unit + suf))
            except OSError:
                pass

    def set_active_state(self, unit, state):
        """直接摆一个 ActiveState(failed / activating / deactivating …), 用来验"不许冒充 inactive"。"""
        with open(os.path.join(self.state, unit + ".state"), "w") as f:
            f.write(state + "\n")

    def crash_loop(self, unit):
        """把 unit 摆成崩溃重启循环: ActiveState=activating + SubState=auto-restart。

        真机上 mosdns 缺一个规则文件就 FATAL, systemd(Restart=on-failure)于是让它在
        activating(auto-restart) 与 failed 之间无限摆动 —— 这是**稳定的"没在跑"**, 不是过渡。
        容器实测: 老实现在这里两种模式都拒, 那台机器谁也修不了。"""
        with open(os.path.join(self.state, unit + ".state"), "w") as f:
            f.write("activating\n")
        with open(os.path.join(self.state, unit + ".sub"), "w") as f:
            f.write("auto-restart\n")
        try:
            os.unlink(os.path.join(self.state, unit + ".active"))
        except OSError:
            pass

    def starting_up(self, unit):
        """真在启动中: activating + SubState=start —— 这种必须照旧拒(等它有结果)。"""
        with open(os.path.join(self.state, unit + ".state"), "w") as f:
            f.write("activating\n")
        with open(os.path.join(self.state, unit + ".sub"), "w") as f:
            f.write("start\n")

    def active_state_mode(self, mode):
        """ActiveState 查询的行为: normal / fail(命令失败) / empty(成功但空输出) / 字面状态。
        before-image 那一步就是靠它区分"查不到"与"确实没在跑"。"""
        with open(os.path.join(self.state, "__as_mode"), "w") as f:
            f.write(mode + "\n")

    def fail_stop(self, unit):
        """让 `systemctl stop <unit>` 返回非 0 —— 验"停不下来必须如实报未恢复"。"""
        open(os.path.join(self.state, unit + ".nostop"), "w").close()

    def stop_leaves(self, unit, state):
        """stop 之后这个 unit 会落到哪个 ActiveState(如 failed) —— 桩用它模拟"停了但死了"。"""
        with open(os.path.join(self.state, unit + ".stopstate"), "w") as f:
            f.write(state + "\n")

    def bump_restarts(self, unit, n):
        """把 NRestarts 直接抬上去, 模拟"起来了但在崩溃循环里"。"""
        with open(os.path.join(self.state, unit + ".nr"), "w") as f:
            f.write(str(n) + "\n")
        open(os.path.join(self.state, unit + ".crash"), "w").close()

    def path(self, rel):
        return self.root + rel

    def put(self, rel, data, mode=0o600):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())
        os.chmod(p, mode)
        return p

    def read(self, rel):
        try:
            with open(self.path(rel), "rb") as f:
                return f.read()
        except OSError:
            return None

    def clean(self):
        # 临时目录放 finally: 探针没停干净要如实抛出来, 但不能因此再漏一个目录。
        try:
            self.stop_probes()
        finally:
            tmpguard.cleanup(self.root)      # 同时销号, 循环里建几十个也不会攒着

    # `with Box() as b:` —— 用例中途断言失败/抛异常时探针和目录照样收得回来。
    # 老写法(建完在末尾手工 clean())在异常路径上一定漏, 三支用例就是这么漏的。
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.clean()
        return False

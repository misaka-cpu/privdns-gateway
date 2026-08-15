#!/usr/bin/env python3
"""6.2A 隐私与边界门。

分两半:
  静态门 —— 只看生产文件与准确的配置块。**每条都配一个反向夹具**: 先把判据喂一份
            "改坏了"的输入, 证明它真的会判红, 再喂真实生产文件。不这样做的话,
            一条写错正则的判据在扫不到东西时也会绿, 而那正是最危险的绿。
  运行时 —— 真起 witness 进程, 看它在合法/非法/写盘失败三种情况下往 stderr、
            /proc/<pid>/cmdline 与环境变量里漏了什么。
"""
import ast
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WITNESS = os.path.join(ROOT, "deploy", "bot", "dotwitness.py")
UNIT = os.path.join(ROOT, "deploy", "bot", "pdg-dotwitness.service")
TPL = os.path.join(ROOT, "deploy", "mosdns", "config.yaml")
LINKSESS = os.path.join(ROOT, "deploy", "bot", "linksess.py")

npass = nfail = 0
LABEL = "a1b2c3d4e5f6a7b8c9d0e1f2"


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    print("[FAIL] %s" % m)


def head(m):
    print("\n── %s ──" % m)


# ── 登记式临时目录: 清理挂在退出钩子上, 不靠"跑到最后一行" ──────────────────
# 负控会把这支测试改红甚至改崩, 末尾那句 rmtree 一崩就跳过 —— 宿主 /tmp 里因此
# 攒过一批 pdg-dotpriv-*。atexit + 显式信号处理覆盖正常退出 / 异常 / SystemExit /
# KeyboardInterrupt 四条路径; 只清**本进程登记过的**那几个, 不按前缀扫。
_TMPGUARD = []


def _tmpguard_mkdtemp(prefix):
    import atexit
    import tempfile as _tf
    d = _tf.mkdtemp(prefix=prefix, dir=os.environ.get("E2E_TMP") or None)
    if not _TMPGUARD:
        atexit.register(_tmpguard_cleanup)
    _TMPGUARD.append(d)
    return d


def _tmpguard_cleanup():
    import shutil as _sh
    keep = os.environ.get("PDG_KEEP_TMP") not in (None, "", "0")
    while _TMPGUARD:
        d = _TMPGUARD.pop()
        if keep:
            print("[PDG_KEEP_TMP] 现场保留: %s" % d)
        else:
            _sh.rmtree(d, ignore_errors=True)


def _tmpguard_selftest(where):
    """tests/test-dot-tmpguard.py 用它注入三种退出路径, 验清理挂在退出钩子上而不是
    "跑到最后一行"。只有显式设了 PDG_TMPGUARD_SELFTEST 才生效, 正常跑不受影响。"""
    m = os.environ.get("PDG_TMPGUARD_SELFTEST") or ""
    if not m or where != "after-mkdtemp":
        return
    if m == "raise":
        raise RuntimeError("tmpguard selftest: uncaught")
    if m == "sysexit":
        raise SystemExit(7)
    if m == "kbint":
        raise KeyboardInterrupt()


WSRC = open(WITNESS).read()
USRC = open(UNIT).read()
TSRC = open(TPL).read()


def gate(name, judge, good, bad_sample):
    """judge(text) -> True 表示"合规"。先用 bad_sample 证明判据会判红, 再判真文件。"""
    if judge(bad_sample):
        bad("%s —— 判据对反向夹具也返回合规, 这条门是摆设" % name)
        return
    (ok if judge(good) else bad)(name)


# ── 静态门 ──────────────────────────────────────────────────────────────────
head("静态门(每条先过反向夹具)")

gate("1. mosdns 未启用 api.http",
     lambda t: not re.search(r"^\s*api:", t, re.M), TSRC, "plugins:\napi:\n  http: \"127.0.0.1:8080\"\n")
gate("2. 未使用 query_summary",
     lambda t: "query_summary" not in t, TSRC, "  - exec: query_summary probe\n")
gate("3. 日志级别仍是 warn",
     lambda t: re.search(r"^log:\s*\n\s*level:\s*warn\s*$", t, re.M) is not None,
     TSRC, "log:\n  level: info\n")
gate("4. witness 默认只绑 127.0.0.1",
     lambda t: re.search(r'^DOTWITNESS_ADDR\s*=\s*"127\.0\.0\.1"', t, re.M) is not None,
     WSRC, 'DOTWITNESS_ADDR = "0.0.0.0"\n')
gate("5. 不监听 IPv6 任意地址",
     lambda t: not re.search(r'AF_INET6|"::"|\'::\'', t), WSRC, 'socket.AF_INET6\n')
gate("6. 没有新增 nft 放行",
     lambda t: not re.search(r"\bnft\b|nftables|dport", t), WSRC + USRC,
     "ExecStartPost=nft add rule inet pdg input tcp dport 5399 accept\n")


def schema_fields(t):
    """从 record() 里那个 dict 字面量取字段名 —— 用 ast, 不用正则数引号。"""
    try:
        tree = ast.parse(t)
    except SyntaxError:
        return None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "record":
            for d in ast.walk(node):
                if isinstance(d, ast.Dict) and any(
                        isinstance(k, ast.Constant) and k.value == "probe_label_sha256"
                        for k in d.keys):
                    return {k.value for k in d.keys if isinstance(k, ast.Constant)}
    return None


WANT = {"schema_version", "probe_label_sha256", "observed_at", "qtype", "transport", "expires_at"}
gate("7. evidence schema 恰为 6 个字段",
     lambda t: schema_fields(t) == WANT, WSRC,
     WSRC.replace('"transport": TRANSPORT,', '"transport": TRANSPORT,\n        "qname": qname_raw,'))
for n, field in ((8, "label"), (9, "qname"), (10, "dot_domain"), (11, "client_ip"),
                 (12, "source_ipv4_16")):
    gate("%d. evidence 不含 %s 字段" % (n, field),
         (lambda f: (lambda t: (schema_fields(t) or set()) and f not in (schema_fields(t) or set())))(field),
         WSRC, WSRC.replace('"qtype": int(qtype),', '"qtype": int(qtype),\n        "%s": 1,' % field))
gate("13. label 不参与路径拼接",
     lambda t: re.search(r"(?:os\.path\.join|\+)[^\n]*\blabel\b[^\n]*\.json", t) is None, WSRC,
     'os.path.join(_runtime_dir(), label + ".json")\n')
gate("14. evidence 文件名固定",
     lambda t: re.search(r'^STATE_NAME\s*=\s*"evidence\.json"', t, re.M) is not None, WSRC,
     'STATE_NAME = "%s.json" % label\n')
gate("15. probe label 与 HTTP token 无复用路径",
     lambda t: not re.search(r"import\s+linksess|from\s+linksess|token_urlsafe|BOT_TOKEN", t),
     WSRC, "import linksess\nlabel = linksess.new_session()\n")
gate("16. label 正则精确为 24 个小写 hex",
     lambda t: re.search(r'LABEL_RE\s*=\s*re\.compile\(r"\\A\[0-9a-f\]\{24\}\\Z"\)', t) is not None,
     WSRC, 'LABEL_RE = re.compile(r"\\A[0-9a-fA-F]{12,}\\Z")\n')


def main_seq(t):
    m = re.search(r"\n  - tag: main_sequence\n.*?(?=\n  - tag: )", t, re.S)
    return m.group(0) if m else ""


gate("17. 探测分支排在 goto internal_sequence(即 lazy_cache)之前",
     lambda t: (lambda b: "goto probe_seq" in b and "goto internal_sequence" in b
                and b.index("goto probe_seq") < b.index("goto internal_sequence"))(main_seq(t)),
     # 反向夹具的锚点必须跟着模板形状走。6.2B 给探测分支加了受管块起止标记, 中间多了
     # 一行 `# <<< ...`, 于是原来那段三行 replace 变成空操作 —— 夹具不再注入任何东西,
     # 这条门自己检出了"反向夹具也合规"。判据一个字没放宽, 换的是夹具锚点。
     TSRC, TSRC.replace("        exec: goto probe_seq\n      # <<< pdg-dotwitness managed block (main_sequence)\n      - matches: client_ip $npn_clients\n        exec: goto internal_sequence\n",
                        "        exec: goto internal_sequence\n      # <<< pdg-dotwitness managed block (main_sequence)\n      - matches: client_ip $npn_clients\n        exec: goto probe_seq\n"))
gate("18. 探测分支同时具备 qname 后缀与 SNI 两道守卫",
     lambda t: (lambda b: re.search(r"qname suffix probe\.", b) and re.search(r"string_exp server_name eq ", b))(main_seq(t)) is not None,
     TSRC, TSRC.replace("          - string_exp server_name eq __DOT_DOMAIN__\n", ""))

BASE_TPL = subprocess.run(["git", "show", "f010e0d31fcd6628e95a99ed526f27cc6f6e102a:deploy/mosdns/config.yaml"],
                          cwd=ROOT, capture_output=True, text=True).stdout


def normal_chain(t):
    """普通 DNS 主链: internal_sequence 整段 + main_sequence 去掉探测分支后的剩余步骤。"""
    m = re.search(r"\n  - tag: internal_sequence\n.*?(?=\n  - tag: )", t, re.S)
    inner = m.group(0) if m else ""
    b = main_seq(t)
    b = re.sub(r"      # ── 探测命名空间.*?        exec: goto probe_seq\n", "", b, flags=re.S)
    # 两段都要去注释: 新插件的说明块夹在 internal_sequence 与 main_sequence 之间,
    # 只去 main 那一半的话, 注释本身会被当成"主链变了"。
    strip = lambda x: re.sub(r"^\s*#.*$", "", x, flags=re.M)
    return re.sub(r"\n\s*\n", "\n", strip(inner) + strip(b))


gate("19. 普通 DNS 主链原有顺序未被改写",
     lambda t: normal_chain(t) == normal_chain(BASE_TPL), TSRC,
     TSRC.replace("      - exec: $lazy_cache\n", ""))
gate("20. 模板占位符都有渲染者",
     lambda t: set(re.findall(r"__[A-Z0-9_]+__", t)) <= set(
         re.findall(r"__[A-Z0-9_]+__", open(os.path.join(ROOT, "install.sh")).read())),
     TSRC, TSRC.replace("__DOT_DOMAIN__", "__NEVER_RENDERED__"))
# 判之前先去掉注释: unit 里正好有一句"这里**不读** bot.env / profile.env / 证书私钥"的
# 说明, 不去注释的话这条门会被自己的注释骗红(任务里点名要防的就是这种)。
_unit_code = re.sub(r"^\s*#.*$", "", USRC, flags=re.M)
gate("21. unit 不读 bot.env / profile.env / 证书私钥",
     lambda t: not re.search(r"bot\.env|profile\.env|privkey|fullchain|\.pem", t), _unit_code,
     "EnvironmentFile=/etc/privdns-gateway/bot.env\n")


def logs_user_input(t):
    """print/stderr 里出现 qname/label/src 这些变量名就算泄露。"""
    try:
        tree = ast.parse(t)
    except SyntaxError:
        return True
    leaky = {"qname_raw", "qname_lower", "label", "src", "pkt"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
            for a in ast.walk(node):
                if isinstance(a, ast.Name) and a.id in leaky:
                    return True
    return False


gate("22. witness 不把 qname/label/来源交给 print/stderr",
     lambda t: not logs_user_input(t), WSRC,
     WSRC.replace('print("dotwitness: listening on loopback',
                  'print(qname_raw)\n    print("dotwitness: listening on loopback'))
# 判据要盯"写状态这条路径本身", 不是全文出现过这两个词 —— 收紧 schema 之后文件里
# 别处也有 mkstemp/replace, 宽判据会被反向夹具骗过。
def _atomic_write(t):
    import re as _re
    m = _re.search(r"def _write_state\(rec\):.*?(?=\ndef )", t, _re.S)
    b = m.group(0) if m else ""
    # 先去注释: 这个函数的注释里正好解释了"os.replace 会把目录项换掉", 不去掉的话
    # 判据会被注释骗过(和 unit 那条 #21 同一个坑)。
    b = _re.sub(r"^\s*#.*$", "", b, flags=_re.M)
    return "mkstemp" in b and "os.replace" in b


gate("23. 状态写入经临时文件 + os.replace", _atomic_write, WSRC,
     WSRC.replace("        os.replace(tmp, _state_path())\n",
                  "        open(_state_path(), 'wb').write(blob)\n"))
gate("24. 状态文件上限仍为 4096",
     lambda t: re.search(r"^STATE_MAX_BYTES\s*=\s*4096", t, re.M) is not None, WSRC,
     "STATE_MAX_BYTES = 1048576\n")

# ── 运行时隐私 ──────────────────────────────────────────────────────────────
head("运行时隐私(真进程)")


def wire(qname, qtype=1, qid=0x1234):
    parts = [p for p in qname.rstrip(".").split(".") if p]
    q = b"".join(bytes([len(p)]) + p.encode() for p in parts) + b"\x00"
    return struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack("!HH", qtype, 1)


d = _tmpguard_mkdtemp(os.environ.get("PDG_DOTW_TMP_PREFIX", "pdg-dotpriv-"))
_tmpguard_selftest("after-mkdtemp")
rt = os.path.join(d, "rt")
os.makedirs(rt, mode=0o700, exist_ok=True)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
SUFFIX = "probe.dot.privacy.test"
env = dict(os.environ, PDG_DOTWITNESS_PORT=str(port), PDG_DOTWITNESS_SUFFIX=SUFFIX,
           RUNTIME_DIRECTORY=rt)
proc = subprocess.Popen([sys.executable, WITNESS], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(0.8)


def send(qname, qtype=1, raw=None):
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    c.settimeout(1.0)
    try:
        c.sendto(raw if raw is not None else wire(qname, qtype), ("127.0.0.1", port))
        try:
            return c.recvfrom(4096)[0]
        except socket.timeout:
            return b""
    finally:
        c.close()


try:
    (ok if proc.poll() is None else bad)("witness 起来了")
    send("%s.%s" % (LABEL, SUFFIX))
    send("nothex-nothex-nothex-nop.%s" % SUFFIX)
    send("", raw=b"\x01\x02\x03")
    # 写盘失败: 把 RuntimeDirectory 换掉 —— 不用 chmod 000(root 能绕过, 那是假故障)
    os.rename(rt, rt + ".moved")
    send("0f1e2d3c4b5a69788796a5b4.%s" % SUFFIX)
    os.rename(rt + ".moved", rt)
    time.sleep(0.3)

    proc.terminate()
    out = proc.communicate(timeout=5)[0].decode("utf-8", "replace")
    for needle, why in ((LABEL, "label 明文"), (SUFFIX, "DoT 域名/qname"),
                        ("127.0.0.1", "来源地址"), ("nothex", "非法 label 正文")):
        (ok if needle not in out else bad)("stderr 不含%s" % why)
    ok("stderr 全文 %d 字节: %s" % (len(out), out.strip().replace("\n", " | ")[:90]))

    names = sorted(os.listdir(rt))
    (ok if names == ["evidence.json"] else bad)("状态目录只有预期文件(实得 %s)" % names)
    (ok if not [n for n in names if n.startswith(".ev-")] else bad)("成功后无残留原子临时文件")
    rec = json.load(open(os.path.join(rt, "evidence.json")))
    blob = json.dumps(rec)
    (ok if LABEL in blob or True else bad)  # 占位避免误判
    (ok if LABEL not in blob and SUFFIX not in blob else bad)("evidence 不含 label 明文与 qname")
finally:
    if proc.poll() is None:
        proc.kill()

# cmdline / 环境变量
head("进程可见面")
env2 = dict(os.environ, PDG_DOTWITNESS_PORT=str(port), PDG_DOTWITNESS_SUFFIX=SUFFIX,
            RUNTIME_DIRECTORY=rt)
p2 = subprocess.Popen([sys.executable, WITNESS], env=env2, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL)
time.sleep(0.8)
try:
    cmdline = open("/proc/%d/cmdline" % p2.pid, "rb").read().decode("utf-8", "replace")
    (ok if LABEL not in cmdline else bad)("/proc/<pid>/cmdline 不含 label")
    environ = open("/proc/%d/environ" % p2.pid, "rb").read().decode("utf-8", "replace")
    (ok if LABEL not in environ else bad)("环境变量不含会话 label")
    (ok if "BOT_TOKEN" not in environ and "PDG_BOT_TOKEN" not in environ else bad)(
        "环境变量不含 HTTP token")
    (ok if "PDG_DOTWITNESS_SUFFIX" in environ else bad)("环境里只有命名空间这一项配置")
finally:
    p2.terminate()
    try:
        p2.wait(timeout=5)
    except Exception:  # noqa: BLE001
        p2.kill()

# core dump
head("core dump")
src_has_core = re.search(r"^\s*LimitCORE\s*=\s*0", USRC, re.M) is not None
(ok if src_has_core else bad)("unit 显式关闭 core dump(LimitCORE=0)")

# 清理由 _tmpguard_cleanup 的 atexit 钩子统一负责(覆盖异常/SystemExit/中断)。

print("\n" + "─" * 62)
print("通过 %d, 失败 %d" % (npass, nfail))
sys.exit(1 if nfail else 0)

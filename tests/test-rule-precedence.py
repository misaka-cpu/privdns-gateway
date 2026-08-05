#!/usr/bin/env python3
"""分流优先级回归: 自动生成的规则不许静默压过用户点名的域名规则。

现场(2026-08-01, .200): 用户在 bot 里把 netflix.com 指到出口 hkt, 面板与 `测域名` 都显示
规则在, 手机上却是直连。clash_api /rules 给出的求值顺序是:

    [ 5] DomainSuffix netflix.com -> DIRECT      ← WDA 解锁那批(自动生成)
    …
    [78] DomainSuffix netflix.com -> hkt         ← 用户自己那条, 永远轮不到

成因: `set_wda_mode(True)` 把 55 个 WDA 域名整体插在 route.rules **最前面**(reject 之后),
而 WDA 的出口 `jp` 是 direct 型出站 → 渲染成 DOMAIN-SUFFIX,…,DIRECT。mihomo 自上而下第一条
命中即止, 于是用户先加的那条规则被这批自动规则整个盖住 —— 配置里两条都在, 界面上看不出问题,
只有把内核的求值顺序拉出来看才发现。

修好的语义(优先级由"意图有多具体"决定):
    用户点名的单域名规则  >  自动生成的批量规则(WDA)  >  规则集 / 默认出口
WDA 对用户没有点名的域名照常生效 —— 修复不是"关掉 WDA", 而是不让它盖住点名规则。

五段验证, 前三段一层比一层贴近现网:
  1. 数据模型: bot 的操作产出的 route.rules 顺序, 以及 bot 自己的「测域名」给出的答案;
  2. 渲染产物: 按 mihomo「自上而下第一条命中即止」的求值顺序走一遍渲染出来的规则表;
  3. 真内核: 用**钉死版 mihomo** 真的跑起来, 从它自己的匹配日志与 clash_api /rules 读出
     "这个域名走了哪个出口" —— 断言的是内核的判定, 不是配置文本长什么样;
  4. 老机器自愈: 现网已经是坏顺序时, 任意一次 model 写入(走真事务)都要把它修正回来;
  5. 看得见: doctor 必须报出被压过的规则, 并如实说明"WDA 把哪一批域名自动判成了直连"
     —— 自动加的规则用户没写过, 不能只有内核知道。

第 2、3 段各带一条**反向用例**: 把顺序改回出事那天的样子, 同一套断言必须给出 DIRECT ——
断言证明不了缺陷的话, 它变绿也说明不了修好了。
"""
import copy
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))     # 供 pdg-bot 内部 `import sb2mihomo`
sys.path.insert(0, str(ROOT / "tests"))
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def skip(m):
    """环境限制导致某项没跑成 —— 与 PASS 严格区分, 不计入通过数。"""
    print("[SKIP] " + m)


def eq(label, got, want):
    if got == want:
        ok(label)
    else:
        bad("%s\n        实得: %r\n        期望: %r" % (label, got, want))


# ── 沙箱: 与 test-wda-mihomo.py 同款(不碰现网, 事务用假的但 model_mod 是真的)────────
def base_model():
    """出事那台机器的骨架: reject + tg-proxy 入口 pin + 一条用户自己的出口规则。

    `jp` 必须是 direct 型出站 —— 现网就是这样(WDA = 本机直出 + 解锁 DNS 拿中继), 也正是
    这批规则渲染成 DIRECT 的原因。写成代理型出口的话, 这个缺陷根本复现不出来。"""
    return {
        "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
        "inbounds": [{"type": "mixed", "tag": "tg-proxy",
                      "listen": "0.0.0.0", "listen_port": 8445}],
        "outbounds": [
            {"type": "direct", "tag": "jp"},
            {"type": "shadowsocks", "tag": "hkt", "server": "198.51.100.9",
             "server_port": 8388, "method": "aes-128-gcm", "password": "x"},
            {"type": "shadowsocks", "tag": "hk", "server": "198.51.100.8",
             "server_port": 8388, "method": "aes-128-gcm", "password": "x"},
        ],
        "route": {
            "rules": [
                {"ip_cidr": ["203.0.113.200/32", "127.0.0.0/8"], "action": "reject"},
                {"inbound": ["tg-proxy"], "outbound": "hk"},
            ],
            "rule_set": [],
            "final": "hk",
        },
    }


state = {"model": base_model(), "files": {}, "mihomo": b""}
unlock_domains = {"v": []}                 # 现网 unlock.txt 的镜像(事务提交什么它就跟着变)

bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda domains: (True, "")
bot._platform = lambda: "android"
bot._mitm_domains = lambda: []
bot._mihomo_rulesets = lambda rs_meta=None: {}
bot.load = lambda: copy.deepcopy(state["model"])
bot._read_hijack = lambda: []
bot._read_direct = lambda: []
bot._read_unlock_domains = lambda: list(unlock_domains["v"])


def fake_tx_apply(op, model_mod=None, files=None, **_kwargs):
    """假事务: 只省掉落盘与重启, model_mod / 渲染 / 判废都跑真的。"""
    candidate = copy.deepcopy(state["model"])
    if model_mod:
        model_mod(candidate)
    data, meta = bot._render_mihomo_bytes(candidate, rs_meta={})
    try:
        bot.mihomorender.check_meta(meta)
    except bot.mihomorender.RenderRefused as exc:
        return False, exc.detail()
    state["model"] = candidate
    state["files"] = dict(files or {})
    state["mihomo"] = data
    raw = state["files"].get("mosdns_rule:unlock.txt")
    if raw is not None:
        unlock_domains["v"] = [line[len("domain:"):] for line in raw.decode().splitlines()
                               if line.startswith("domain:")]
    return True, "committed"


REAL_TX_APPLY = bot.tx_apply       # 第 4 段要用真事务, 先把真的收好再换成假的
bot.tx_apply = fake_tx_apply


# ── 求值模型: mihomo 自上而下, 第一条命中即止 ────────────────────────────────
def first_match(rules, host, in_name=None):
    """按 mihomo 的求值顺序走一遍渲染出来的规则表, 返回 (下标, 规则原文, 目标)。

    只实现本项目渲染得出的那几类规则; 认不出的一律当"不匹配"(宁可漏判也不冒判 —— 冒判会
    让断言在错误的地方变绿)。RULE-SET 要读 provider 内容才知道命不命中, 这里不猜, 本用例的
    model 里也没有规则集。IP-CIDR 带 no-resolve, 域名连接根本不会走到它。"""
    for i, rule in enumerate(rules):
        kind, _, rest = rule.partition(",")
        if kind == "MATCH":
            return i, rule, rest
        parts = rest.split(",")
        value = parts[0]
        target = parts[1] if len(parts) > 1 else ""
        if kind == "DOMAIN-SUFFIX":
            if host == value or host.endswith("." + value):
                return i, rule, target
        elif kind == "DOMAIN":
            if host == value:
                return i, rule, target
        elif kind == "DOMAIN-KEYWORD":
            if value in host:
                return i, rule, target
        elif kind == "IN-NAME":
            if in_name is not None and in_name == value:
                return i, rule, target
    return None, None, None


def rendered_rules(model):
    data, meta = bot._render_mihomo_bytes(model, rs_meta={})
    assert not meta["dropped"] and not meta["unknown_proxies"], meta
    return json.loads(data.decode("utf-8"))["rules"]


def rule_index(rules, prefix):
    return [i for i, r in enumerate(rules) if r == prefix]


# ══ 1. 数据模型层: 用户点名规则在前, 自动批量在后 ═══════════════════════════
def model_layer():
    state["model"] = base_model()
    state["files"] = {}
    unlock_domains["v"] = []

    # 用户先按自己的意思配好: netflix.com / google.com → hkt(现网就是这个顺序: 先有规则,
    # 后开的 WDA)
    okr, msg = bot.add_rule("netflix.com", "hkt")
    assert okr, msg
    okr, msg = bot.add_rule("google.com", "hkt")
    assert okr, msg

    okr, msg = bot.set_wda_mode(True)
    assert okr, msg
    model = state["model"]
    rules = model["route"]["rules"]
    wda_idx = [i for i, r in enumerate(rules)
               if set(r.get("domain_suffix") or []) == set(bot.WDA_DOMAINS)]
    user_idx = [i for i, r in enumerate(rules)
                if r.get("outbound") == "hkt" and "netflix.com" in (r.get("domain_suffix") or [])]
    assert len(wda_idx) == 1 and len(user_idx) == 1, (wda_idx, user_idx)
    if user_idx[0] < wda_idx[0]:
        ok("开 WDA 之后, 用户点名规则(#%d)仍排在 WDA 自动批量(#%d)之前"
           % (user_idx[0], wda_idx[0]))
    else:
        bad("WDA 自动批量(#%d)插到了用户点名规则(#%d)前面 —— 用户那条永远轮不到"
            % (wda_idx[0], user_idx[0]))

    # bot 自己的「测域名」是用户唯一能自查的入口: 它必须和内核给出同一个答案
    tag, why = bot._singbox_route("www.netflix.com")
    eq("「测域名」www.netflix.com → hkt(命中用户规则)", (tag, why), ("hkt", "显式域名规则"))
    tag, _ = bot._singbox_route("disneyplus.com")
    eq("「测域名」disneyplus.com → jp(用户没点名, WDA 照常生效)", tag, "jp")
    assert bot._wda_on(state["model"]), "WDA 仍要是开着的"
    ok("重排之后 WDA 状态不变(面板不会显示成落地出口)")

    # WDA 开着时**新加**一条点名规则, 同样要压过 WDA
    okr, msg = bot.add_rule("openai.com", "hkt")
    assert okr, msg
    tag, _ = bot._singbox_route("chat.openai.com")
    eq("WDA 开着时新加的点名规则 openai.com → hkt 也在 WDA 之前", tag, "hkt")

    # 关掉 WDA 不许动用户的规则
    okr, msg = bot.set_wda_mode(False)
    assert okr, msg
    tag, _ = bot._singbox_route("www.netflix.com")
    eq("关掉 WDA 后 netflix.com 仍是用户那条 hkt", tag, "hkt")
    assert not bot._wda_on(state["model"])
    ok("关 WDA 干净(用户点名规则一条不少)")


# ══ 2. 渲染产物: 按求值顺序断言 ═════════════════════════════════════════════
def build_conflict_model():
    """回到"用户规则在前、WDA 在后"的现场形态, 返回提交后的 model。"""
    state["model"] = base_model()
    state["files"] = {}
    unlock_domains["v"] = []
    assert bot.add_rule("netflix.com", "hkt")[0]
    assert bot.add_rule("google.com", "hkt")[0]
    okr, msg = bot.set_wda_mode(True)
    assert okr, msg
    return copy.deepcopy(state["model"])


def shadowed_model(model):
    """反向用例: 把 WDA 那条搬回 reject 之后(出事那天的顺序)。"""
    bad_model = copy.deepcopy(model)
    rules = bad_model["route"]["rules"]
    wda = [r for r in rules if set(r.get("domain_suffix") or []) == set(bot.WDA_DOMAINS)]
    assert len(wda) == 1
    rest = [r for r in rules if r is not wda[0]]
    idx = 1 if rest and rest[0].get("action") == "reject" else 0
    bad_model["route"]["rules"] = rest[:idx] + wda + rest[idx:]
    return bad_model


def render_layer(model, bad_order):
    rules = rendered_rules(model)
    _, rule, target = first_match(rules, "www.netflix.com")
    eq("求值顺序: www.netflix.com 命中用户规则 → hkt", target, "hkt")
    _, _, target = first_match(rules, "netflix.com")
    eq("求值顺序: netflix.com(裸域)同样 → hkt", target, "hkt")
    _, _, target = first_match(rules, "disneyplus.com")
    eq("求值顺序: disneyplus.com 仍走 WDA → DIRECT(WDA 没被削弱)", target, "DIRECT")
    _, _, target = first_match(rules, "github.com")
    eq("求值顺序: 没人管的域名落到默认出口 → hk", target, "hk")
    _, _, target = first_match(rules, "anything.test", in_name="tg-proxy")
    eq("求值顺序: tg-proxy 入口 pin 仍在最前", target, "hk")

    # 两条 netflix.com 规则都还在配置里 —— 断言的是**谁在前**, 不是谁存在
    hits = [i for i, r in enumerate(rules) if r.startswith("DOMAIN-SUFFIX,netflix.com,")]
    if len(hits) == 2 and rules[hits[0]].endswith(",hkt"):
        ok("渲染产物里两条 netflix.com 规则都在, 用户那条在前(#%d 早于 #%d)" % tuple(hits))
    else:
        bad("netflix.com 规则的排布不对: %r" % [rules[i] for i in hits])

    # 反向用例: 顺序一改回去, 同一套断言必须变成 DIRECT —— 否则断言是空转的
    bad_rules = rendered_rules(bad_order)
    _, _, bad_target = first_match(bad_rules, "www.netflix.com")
    if bad_target == "DIRECT":
        ok("反向用例: 换回出事那天的顺序, www.netflix.com 果然命中 DIRECT(断言有效)")
    else:
        bad("反向用例没能复现缺陷(实得 %r) —— 说明这套断言证明不了什么" % bad_target)


# ══ 3. 真内核: 让 mihomo 自己说它把这个域名送去了哪儿 ═══════════════════════
def _freeport():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Kernel:
    """把渲染出来的配置交给真 mihomo 跑起来, 再问它"这个域名走哪个出口"。

    问法: 从一个**额外挂上去的** mixed 监听进去发 CONNECT, 内核在匹配时会打一行
    `match DomainSuffix(netflix.com) using DIRECT` —— 那是内核自己的判定, 不是配置文本。
    这个监听是测试脚手架: 它只加在 listeners 里, **不产生任何路由规则**(IN-NAME 规则只由
    model 的 mixed 入站生成), 所以 rules 列表逐字节还是渲染出来的那一份。
    端口(controller / redir / tg-proxy)换成随机空闲端口, 否则并发跑测试会互相撞。"""

    def __init__(self, exe, cfg):
        self.exe = exe
        self.api = _freeport()
        self.probe_port = _freeport()
        self.cfg = copy.deepcopy(cfg)
        self.cfg["external-controller"] = "127.0.0.1:%d" % self.api
        self.cfg["redir-port"] = _freeport()
        for lst in self.cfg.get("listeners", []):
            lst["port"] = _freeport()
            lst["listen"] = "127.0.0.1"
        self.cfg.setdefault("listeners", []).append(
            {"name": "pdg-test-probe", "type": "mixed",
             "port": self.probe_port, "listen": "127.0.0.1"})
        self.dir = tmpguard.mkdtemp(prefix="pdgrule.")
        self.proc = None
        self.lines = []

    def __enter__(self):
        path = os.path.join(self.dir, "config.yaml")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.cfg, fh, ensure_ascii=False, indent=2)
        self.proc = subprocess.Popen([self.exe, "-d", self.dir, "-f", path],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True)
        for _ in range(80):
            time.sleep(0.25)
            if self.proc.poll() is not None:
                raise RuntimeError("mihomo 没起来: " + (self.proc.stdout.read() or "")[-800:])
            try:
                urllib.request.urlopen(self._url("/version"), timeout=2)
                break
            except Exception:  # noqa: BLE001
                continue
        else:
            raise RuntimeError("mihomo 起来了但 clash API 一直不响应")
        self._tail = threading.Thread(target=self._read_logs, daemon=True)
        self._tail.start()
        time.sleep(0.6)                 # 让日志流先连上, 否则最早那条匹配可能读不到
        return self

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)
        return False

    def _url(self, path):
        return "http://127.0.0.1:%d%s" % (self.api, path)

    def _read_logs(self):
        """/logs 是一行一个 JSON 的长连接; 只留 payload(内核那句人话)。"""
        try:
            resp = urllib.request.urlopen(self._url("/logs?level=info"), timeout=60)
            while True:
                line = resp.readline()
                if not line:
                    return
                try:
                    self.lines.append(json.loads(line.decode("utf-8", "replace"))["payload"])
                except Exception:  # noqa: BLE001
                    continue
        except Exception:  # noqa: BLE001
            return

    def api_rules(self):
        with urllib.request.urlopen(self._url("/rules"), timeout=5) as resp:
            return json.load(resp)["rules"]

    def route_of(self, host):
        """内核把 host:443 送去了哪个出口(读它自己的匹配日志)。"""
        mark = len(self.lines)
        sock = socket.create_connection(("127.0.0.1", self.probe_port), timeout=5)
        try:
            sock.sendall(("CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" % (host, host))
                         .encode("utf-8"))
            sock.settimeout(3)
            try:
                sock.recv(64)
            except (socket.timeout, OSError):
                pass
        finally:
            sock.close()
        # 内核用**两种**句式说同一件事, 取决于这一拨拨没拨通 —— 而判定(命中哪条规则、判给
        # 哪个出口)两种都带全了:
        #   拨通:   `[TCP] 1.2.3.4:5678 --> host:443 match DomainSuffix(x) using hkt`
        #   拨不通: `[TCP] dial hkt (match DomainSuffix/x) 1.2.3.4:5678 --> host:443 error: …`
        # 本用例断的是"内核把它判给了谁", 与出口通不通无关 —— 出口地址本来就是 TEST-NET-2
        # 的文档保留段(198.51.100.0/24), 永远拨不通。只认第一种句式就变成了看拨号快慢的
        # 抛硬币: 有网时那个地址是黑洞、拨号挂住, 于是先打出 match 行; 无网时拨号立刻失败,
        # 只剩 error 行。开发机(有网)全绿而 CI(容器无出网)红两条, 差别就在这里。
        ok_pat = re.compile(re.escape(host) + r":443 match (\S+) using (\S+)\s*$")
        err_pat = re.compile(r"dial (\S+) \(match ([^)]+)\).*?" + re.escape(host) + r":443 error:")
        for _ in range(40):
            for line in self.lines[mark:]:
                m = ok_pat.search(line)
                if m:
                    return m.group(1), m.group(2)
                m = err_pat.search(line)
                if m:
                    # `DomainSuffix/netflix.com` → `DomainSuffix(netflix.com)`, 与另一种句式同形
                    kind, _, val = m.group(2).partition("/")
                    return ("%s(%s)" % (kind, val) if val else kind), m.group(1)
            time.sleep(0.25)
        return None, None


def kernel_layer(exe, model, bad_order):
    with Kernel(exe, json.loads(bot._render_mihomo_bytes(model, rs_meta={})[0].decode())) as k:
        rule, out = k.route_of("www.netflix.com")
        eq("真内核: www.netflix.com 走用户点名的出口(命中 %s)" % (rule or "?"), out, "hkt")
        rule, out = k.route_of("disneyplus.com")
        eq("真内核: disneyplus.com 仍走 WDA(直出)", out, "DIRECT")
        rule, out = k.route_of("github.com")
        eq("真内核: 没人管的域名走默认出口", out, "hk")

        # 与现场同款的诊断: clash_api /rules 就是内核的求值顺序
        api = k.api_rules()
        idx = [i for i, r in enumerate(api)
               if r.get("type") == "DomainSuffix" and r.get("payload") == "netflix.com"]
        got = [api[i]["proxy"] for i in idx]
        eq("真内核 /rules: 两条 netflix.com 规则里用户那条在前", got, ["hkt", "DIRECT"])

    # 反向用例: 同一台内核、同一套问法, 换回坏顺序必须给出 DIRECT
    with Kernel(exe, json.loads(bot._render_mihomo_bytes(bad_order, rs_meta={})[0].decode())) as k:
        _, out = k.route_of("www.netflix.com")
        if out == "DIRECT":
            ok("反向用例(真内核): 坏顺序下 www.netflix.com 果然被判直连")
        else:
            bad("反向用例(真内核)没能复现缺陷: 实得 %r" % out)


# ══ 4. 老机器自愈: 现网已经是坏顺序时, 下一次 model 写入要修正它 ═══════════
def selfheal_layer(bad_order):
    """走**真事务**(pdgtx, 沙箱文件树): 任意一次 model 写入之后, 落盘的 model 与渲染出来的
    内核配置都必须是"用户规则在前"。这是出事那台机器的修复路径 —— 用户不必知道要重开一次
    WDA, 下一次改任何配置就顺手修好了。"""
    import importlib
    with tempfile.TemporaryDirectory() as tmp:
        for d in ("/etc/sing-box", "/etc/mihomo", "/etc/mosdns/rules", "/run",
                  "/var/lib/privdns-gateway", "/etc/privdns-gateway"):
            os.makedirs(tmp + d, exist_ok=True)
        os.environ["PDG_TX_FSROOT"] = tmp
        os.environ["PDG_TX_ROOT"] = tmp + "/var/lib/privdns-gateway/tx"
        os.environ["PDG_LOCKFILE"] = tmp + "/run/pdg.lock"
        os.environ["PDG_STABLE_SAMPLES"] = "1"
        for m in list(sys.modules):
            if m.startswith("pdgtx"):
                del sys.modules[m]
        tx = importlib.import_module("pdgtx")
        tx.svc_stable = lambda unit, **k: (True, "")
        tx.health_snapshot = lambda services, relax_units=(): {"svc:" + u: True for u in services}
        tx._svc_prop_ex = lambda unit, prop: (
            {"ActiveState": "active", "UnitFileState": "enabled", "NRestarts": "0"}.get(prop, ""),
            True)
        tx._run = lambda cmd, timeout=60: (0, "")
        tx.VALIDATORS["mihomo_check"] = lambda path, data, ctx: (True, "")

        bot.SB = tmp + "/etc/sing-box/config.json"
        bot.MIHOMO_DIR = tmp + "/etc/mihomo"
        bot.MIHOMO_CFG = bot.MIHOMO_DIR + "/config.yaml"
        with open(bot.SB, "w", encoding="utf-8") as fh:
            json.dump(bad_order, fh, ensure_ascii=False, indent=2)
        # 这一段要真的走 tx_apply → load() 必须读沙箱里的文件, unlock.txt 也照现网写一份
        with open(tmp + "/etc/mosdns/rules/unlock.txt", "w", encoding="utf-8") as fh:
            fh.write("".join("domain:%s\n" % d for d in bot.WDA_DOMAINS))
        bot.load = lambda: json.load(open(bot.SB, encoding="utf-8"))
        bot._read_unlock_domains = lambda: list(bot.WDA_DOMAINS)
        bot.tx_apply = REAL_TX_APPLY
        try:
            okr, msg = bot.apply_sb(lambda cc: cc["route"].__setitem__("final", "hk"))
            if not okr:
                bad("自愈用例: 事务没提交(%s)" % msg)
                return
            saved = json.load(open(bot.SB, encoding="utf-8"))
            rules = saved["route"]["rules"]
            wda_idx = [i for i, r in enumerate(rules)
                       if set(r.get("domain_suffix") or []) == set(bot.WDA_DOMAINS)]
            user_idx = [i for i, r in enumerate(rules)
                        if r.get("outbound") == "hkt"
                        and "netflix.com" in (r.get("domain_suffix") or [])]
            if wda_idx and user_idx and user_idx[0] < wda_idx[0]:
                ok("老机器自愈: 一次普通的 model 写入之后, 用户规则(#%d)排到了 WDA(#%d)之前"
                   % (user_idx[0], wda_idx[0]))
            else:
                bad("老机器自愈没生效: user=%r wda=%r" % (user_idx, wda_idx))
            cfg = json.load(open(bot.MIHOMO_CFG, encoding="utf-8"))
            _, _, target = first_match(cfg["rules"], "www.netflix.com")
            eq("老机器自愈: 事务落盘的内核配置里 www.netflix.com → hkt", target, "hkt")
        finally:
            bot.tx_apply = fake_tx_apply
            bot.load = lambda: copy.deepcopy(state["model"])
            bot._read_unlock_domains = lambda: list(unlock_domains["v"])


# ══ 5. 看得见: doctor 必须把这批自动规则和被压过的规则说出来 ══════════════════
def doctor_layer(model, bad_order):
    """自检库读的是**渲染出来的内核规则表** —— 用户自查时看到的 /rules 就是它。

    这一段验四件事: 压过了要报; 没压过时那批自动 DIRECT 也得看得见(用户没写过这批规则);
    MITM 接管同样算自动规则; WDA 关着时不许无中生有。"""
    spec_c = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
    checks = importlib.util.module_from_spec(spec_c)
    spec_c.loader.exec_module(checks)

    with tempfile.TemporaryDirectory() as tmp:
        checks.MIHOMO_CFG = os.path.join(tmp, "config.yaml")
        checks.UNLOCK_FILE = os.path.join(tmp, "unlock.txt")
        checks.MITM_HIJACK_FILE = os.path.join(tmp, "mitm_hijack.txt")
        checks.CUSTOM_DIRECT_FILE = os.path.join(tmp, "custom_direct.txt")

        def put(model_, mitm=()):
            old = bot._mitm_domains
            bot._mitm_domains = lambda: list(mitm)
            try:
                data, _ = bot._render_mihomo_bytes(model_, rs_meta={})
            finally:
                bot._mitm_domains = old
            with open(checks.MIHOMO_CFG, "wb") as fh:
                fh.write(data)
            with open(checks.MITM_HIJACK_FILE, "w", encoding="utf-8") as fh:
                fh.write("".join("domain:%s\n" % d for d in mitm))

        with open(checks.UNLOCK_FILE, "w", encoding="utf-8") as fh:
            fh.write("".join("domain:%s\n" % d for d in bot.WDA_DOMAINS))
        open(checks.CUSTOM_DIRECT_FILE, "w").close()

        # ① 坏顺序(现网出事那天): 必须点名报出来
        put(bad_order)
        level, label, detail = checks.check_rule_precedence()
        if level == "warn" and "netflix.com" in detail and "hkt" in detail:
            ok("doctor 在坏顺序下点名报出被压过的规则: %s" % detail[:70])
        else:
            bad("doctor 没报出被压过的规则: (%s) %s" % (level, detail))

        # ② 修好之后: 不再报警, 但那批自动判直连的域名仍要**看得见**
        put(model)
        level, label, detail = checks.check_rule_precedence()
        if level == "ok" and "WDA" in detail and "直连" in detail:
            ok("doctor 在正常顺序下不报警, 但把 WDA 自动判直连这件事说了出来")
        else:
            bad("正常顺序下的自检结论不对: (%s) %s" % (level, detail))
        if "netflix.com" in detail:
            ok("doctor 同时说清哪几个 WDA 域名按用户规则走: %s" % detail[-90:])
        else:
            bad("doctor 没说明被用户规则接管的 WDA 域名: %s" % detail)

        # ③ 直连表: WDA 开着但域名被判直连 —— 流量根本不进网关, 以前界面上完全看不出来
        with open(checks.CUSTOM_DIRECT_FILE, "w", encoding="utf-8") as fh:
            fh.write("domain:dazn.com\n")
        level, _, detail = checks.check_rule_precedence()
        if "dazn.com" in detail and "直连表" in detail:
            ok("doctor 报出「WDA 开着但该域名在直连表里, 对它不生效」")
        else:
            bad("直连表冲突没被报出来: (%s) %s" % (level, detail))
        open(checks.CUSTOM_DIRECT_FILE, "w").close()

        # ④ MITM 接管也是自动生成的规则: 压过用户规则同样要报
        mitm_model = copy.deepcopy(model)
        mitm_model["route"]["rules"].insert(
            1, {"domain_suffix": ["gs-loc.apple.com"], "outbound": "hkt"})
        put(mitm_model, mitm=["gs-loc.apple.com"])
        level, _, detail = checks.check_rule_precedence()
        # MITM 那批是**故意**排最前的, 建议必须与 WDA 那批不同 —— 说成"等自愈"会让人白等
        if level == "warn" and "gs-loc.apple.com" in detail and "MITM" in detail \
           and "WLOC" in detail:
            ok("doctor 也认 MITM 接管这一批, 并给出与 WDA 不同的处置(删规则或关 WLOC)")
        else:
            bad("MITM 压过用户规则没被报出来/建议不对: (%s) %s" % (level, detail))

        # ⑤ WDA 关着: 不许无中生有
        with open(checks.UNLOCK_FILE, "w", encoding="utf-8"):
            pass
        plain = base_model()
        plain["route"]["rules"].append({"domain_suffix": ["netflix.com"], "outbound": "hkt"})
        put(plain)
        level, _, detail = checks.check_rule_precedence()
        if level == "ok" and "WDA" not in detail:
            ok("WDA 关着且没有冲突时, 自检安静(不制造噪声)")
        else:
            bad("WDA 关着却报了东西: (%s) %s" % (level, detail))

        # ⑥ 用户自己两条规则互相盖住: 也要说, 但要说清不是自动规则干的
        dup = base_model()
        dup["route"]["rules"].append({"domain_suffix": ["a.example"], "outbound": "hkt"})
        dup["route"]["rules"].append({"domain": ["www.a.example"], "outbound": "hk"})
        put(dup)
        level, _, detail = checks.check_rule_precedence()
        if level == "warn" and "www.a.example" in detail and "自己" in detail:
            ok("用户自己两条规则相互覆盖时如实说明(与自动规则分开说)")
        else:
            bad("用户自覆盖没被报出来: (%s) %s" % (level, detail))

        # ⑦ 定去向的是**最靠前**那条覆盖它的规则, 中间那条不算。三条 b.example: hkt / hk / hkt
        #    → 只有中间那条(hk)真的永远轮不到; 第三条与第一条同目标, 结果就是用户要的, 报它
        #    等于自检自己造假警报(第一版跳过同目标去找"目标不同的"时正是这么报的)。
        same = base_model()
        same["route"]["rules"].append({"domain_suffix": ["b.example"], "outbound": "hkt"})
        same["route"]["rules"].append({"domain_suffix": ["b.example"], "outbound": "hk"})
        same["route"]["rules"].append({"domain_suffix": ["b.example"], "outbound": "hkt"})
        put(same)
        scan = checks.rule_precedence_scan()
        if scan["user"] == [("b.example", "hk", "hkt")] and not scan["auto"]:
            ok("只报真的死规则(中间那条), 不把最靠前那条与本条同目标的也算成冲突")
        else:
            bad("死规则判定不对: user=%r auto=%r" % (scan["user"], scan["auto"]))


def main():
    print("── 1. 数据模型层 ──")
    model_layer()

    print("\n── 2. 渲染产物的求值顺序 ──")
    model = build_conflict_model()
    bad_order = shadowed_model(model)
    render_layer(model, bad_order)

    print("\n── 3. 真内核判定 ──")
    import mihomobin
    exe = mihomobin.require(ok, bad, skip)
    if exe:
        try:
            kernel_layer(exe, model, bad_order)
        except Exception as e:  # noqa: BLE001
            bad("真内核用例执行失败: %r" % (e,))

    print("\n── 4. 老机器自愈 ──")
    selfheal_layer(bad_order)

    print("\n── 5. doctor 可见性 ──")
    doctor_layer(model, bad_order)

    print("─" * 40)
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

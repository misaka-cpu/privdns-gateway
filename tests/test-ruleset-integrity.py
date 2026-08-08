#!/usr/bin/env python3
"""规则集完整性回归(P0): 没进到实际运行配置的规则集, 一律不许当成功。

旧行为的三个洞:
  · bot 的 add_ruleset 接受 `.srs` 并回"已添加", 但 _mihomo_rulesets 会跳过 .srs
    (mihomo 消费不了 sing-box 的二进制规则集) → 渲染器把它记进 meta["dropped"];
  · _core_apply 与迁移只检查 meta["unknown_proxies"], **不看 dropped** → 规则集被静默
    丢弃, 配置照样应用, 用户以为分流生效了, 实际那条规则根本不存在;
  · `.mrs` 是 mihomo 原生格式(渲染层本来就支持), 却被 add_ruleset 以"sing-box 不支持"拒掉。

现在: dropped 非空即判失败并列出被丢弃的规则集; .mrs 放行; .srs 在入口就拒(并给出替换指引);
已有 .srs 的老机器迁移时会被拦下, 保留 sing-box 运行, 而不是迁过去悄悄少一条分流。
"""
import contextlib
import importlib.util
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

import sb2mihomo

# 真函数留底: 个别用例会打桩 _build_source/_fetch_bytes, 但那种桩**绝不能泄漏**到后面用
# 真实 fixture 的用例里(否则等于把被测逻辑 mock 掉了还以为在测)。setup() 每次都复原。
_REAL_BUILD_SOURCE = bot._build_source
_REAL_FETCH_BYTES = bot._fetch_bytes

pass_n = 0


def ok(msg):
    global pass_n
    print("[OK]  ", msg)
    pass_n += 1


def bad(msg):
    print("[FAIL]", msg)
    sys.exit(1)


SAMPLE = {
    "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}},
    "outbounds": [
        {"type": "shadowsocks", "tag": "hk", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "pw"},
        {"type": "direct", "tag": "jp"},
    ],
    "route": {"rules": [{"ip_cidr": ["127.0.0.0/8"], "action": "reject"}], "final": "jp"},
}


class FakeSh:
    def __init__(self):
        self.calls = []

    def __call__(self, cmd):
        self.calls.append(list(cmd))
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")


def setup(tmp):
    # 5.1: 规则集操作经统一事务落盘, 事务的目标白名单是镜像的 /etc 结构 —— 沙箱按镜像树铺,
    # 并把事务根/锁指进来(锁 fail-closed, 必须给可写路径)。
    for d in ("/etc/sing-box/rs", "/etc/mihomo", "/etc/mosdns/rules", "/run",
              "/var/lib/privdns-gateway", "/opt/pdg-bot"):
        os.makedirs(tmp + d, exist_ok=True)
    os.environ["PDG_TX_FSROOT"] = tmp
    os.environ["PDG_TX_ROOT"] = tmp + "/var/lib/privdns-gateway/tx"
    os.environ["PDG_LOCKFILE"] = tmp + "/run/pdg.lock"
    os.environ["PDG_STABLE_SAMPLES"] = "1"
    for m in list(sys.modules):
        if m.startswith("pdgtx"):
            del sys.modules[m]
    bot.SB = tmp + "/etc/sing-box/config.json"
    bot.RS_DIR = tmp + "/etc/sing-box/rs"
    bot.RS_META = tmp + "/opt/pdg-bot/rulesets.json"
    bot.MIHOMO_DIR = tmp + "/etc/mihomo"
    bot.MIHOMO_CFG = bot.MIHOMO_DIR + "/config.yaml"
    bot.BACKEND_MARKER = os.path.join(tmp, "backend")
    bot.LOCKFILE = os.environ["PDG_LOCKFILE"]
    os.makedirs(bot.RS_DIR, exist_ok=True)
    with open(bot.SB, "w") as f:
        json.dump(SAMPLE, f)
    with open(bot.BACKEND_MARKER, "w") as f:
        f.write("mihomo")
    fake = FakeSh()
    bot.sh = fake
    sys.path.insert(0, str(ROOT / "deploy" / "bot"))
    import importlib
    tx = importlib.import_module("pdgtx")
    tx.svc_stable = lambda unit, **k: (True, "")            # 服务动力学由事务专属用例覆盖
    tx.health_snapshot = lambda services, relax_units=(): {"svc:" + u: True for u in services}
    # before-image 现在会带返回码去问 systemd(ActiveState/UnitFileState/NRestarts)。
    # 这些用例本来就不测 systemd, 沙箱里也没有真 unit —— 给它一份确定的应答, 免得"查不到"
    # 触发 fail-closed(那条判据本身由 test-config-transaction-faults.py 专门验)。
    tx._svc_prop_ex = lambda unit, prop: (
        {"ActiveState": "active", "UnitFileState": "enabled", "NRestarts": "0"}.get(prop, ""), True)
    tx._run = lambda cmd, timeout=60: (0, "")
    tx.VALIDATORS["mihomo_check"] = lambda path, data, ctx: (
        (False, "mihomo 配置校验失败") if getattr(fake, "mihomo_t_rc", 0) else (True, ""))
    bot._svc_active = lambda unit, **k: True
    bot._build_source = _REAL_BUILD_SOURCE      # 复原, 防止上一个用例的桩泄漏进来
    bot._fetch_bytes = _REAL_FETCH_BYTES
    return fake


def main():
    # ── 1. 渲染层: 规则集没进 rule-providers 就必须记进 dropped ──
    model = json.loads(json.dumps(SAMPLE))
    model["route"]["rules"].append({"rule_set": "rs_deadbeef", "outbound": "hk"})
    _cfg, meta = sb2mihomo.singbox_to_mihomo(model, redir_port=7893, rulesets={})
    if not meta.get("dropped"):
        bad("规则集未进 rule-providers 却没被记进 dropped")
    ok("渲染层: 未能翻译的规则集被记进 meta['dropped']")

    # ── 2. 候选派生器: dropped 非空必须判失败并点名(而不是静默应用) ──
    #    这一判据现在只有 _mihomo_derive 一处 —— tx_apply 与恢复备份共用它, 事务因此拿不到
    #    候选、更不会落盘(以前是 _core_apply 在写完 model 之后才发现)。
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        c = json.load(open(bot.SB))
        c["route"]["rules"].append({"rule_set": "rs_deadbeef", "outbound": "hk"})
        before = open(bot.MIHOMO_CFG, "rb").read() if os.path.exists(bot.MIHOMO_CFG) else None
        try:
            bot._mihomo_derive({"model": json.dumps(c).encode()})
            bad("dropped 非空却派生成功了(规则集被静默丢弃)")
        except Exception as e:  # noqa: BLE001  事务用 TxRefused 把"点名"的理由带给用户
            if "rs_deadbeef" not in str(e):
                bad(f"失败信息没点名被丢弃的规则集: {e}")
            now = open(bot.MIHOMO_CFG, "rb").read() if os.path.exists(bot.MIHOMO_CFG) else None
            if now != before:
                bad("派生失败却动了现网 mihomo 配置")
            ok("候选派生: dropped 非空 → 抛错并点名被丢弃的规则集, 现网零改动")

    # ── 3. .srs 在入口就被拒(mihomo 消费不了), 且给出替换指引 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        okr, msg = bot.add_ruleset("https://example.com/list.srs", "hk")
        if okr:
            bad(".srs 仍被接受(它进不了 mihomo 运行配置)")
        if ".srs" not in msg or "mihomo" not in msg:
            bad(f".srs 拒绝文案不清楚: {msg}")
        ok(f".srs 入口即拒并说明原因: {msg[:48]}…")
        # 拒绝之后不得留下半截状态
        if os.path.exists(bot.RS_META) and "rs_" in open(bot.RS_META).read():
            bad(".srs 被拒却写进了规则集元数据")
        rules = json.load(open(bot.SB))["route"]["rules"]
        if any(r.get("rule_set") for r in rules):
            bad(".srs 被拒却把规则写进了 model")
        ok(".srs 被拒后不留半截状态(元数据与 model 都干净)")

    # ── 4. .mrs 是 mihomo 原生格式 → 必须放行(旧代码以"sing-box 不支持"拒掉) ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        bot._fetch_bytes = lambda url: b"MRSbinary"
        # .mrs 的 behavior 判不出来, 必须显式声明(见下方真实 fixture 用例里的"未声明即拒绝")
        okr, msg = bot.add_ruleset("https://example.com/geo.mrs", "hk", behavior="domain")
        if not okr:
            bad(f".mrs 被拒了(mihomo 原生格式应当可用): {msg}")
        m = json.load(open(bot.RS_META))
        if not any(i.get("format") == "mrs" for i in m.values()):
            bad(f".mrs 未按 mrs 格式记录: {m}")
        ok(".mrs 放行并按 mihomo 原生格式记录")

    # ── 5. YAML provider 放行 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        bot._build_source = lambda url, path: (12, False)
        okr, msg = bot.add_ruleset("https://example.com/rules.yaml", "hk")
        if not okr:
            bad(f"YAML provider 被拒: {msg}")
        ok("YAML provider 放行")

    # ── 6. 应用失败后原后端仍可用: model 回到改前, 磁盘上不留坏渲染 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        before = open(bot.SB).read()
        # 直接往 model 里塞一条"进不了 rule-providers"的规则集规则 → apply 必失败
        okr, msg = bot.apply_sb(lambda c: c["route"]["rules"].append(
            {"rule_set": "rs_missing", "outbound": "hk"}))
        if okr:
            bad("dropped 非空却 apply 成功")
        if open(bot.SB).read() != before:
            bad("apply 失败后 model 没还原(原后端不再可用)")
        ok("应用失败 → model 完整还原, 原后端保持可用")

    # ── 7. 升级前就存在的 .srs(老机器现场): 必须挡住迁移, 而不是迁过去悄悄少一条分流 ──
    # 迁移侧(pdg.sh 的 _activate_mihomo_core)调的正是 bot._render_mihomo_file, 这里验同一判据。
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        srs = os.path.join(bot.RS_DIR, "rs_legacy.srs")
        open(srs, "wb").write(b"SRSbinary")
        json.dump({"rs_legacy": {"url": "https://old.example/geo.srs", "outbound": "hk",
                                 "format": "binary", "path": srs, "count": None}},
                  open(bot.RS_META, "w"))
        c = json.load(open(bot.SB))
        c["route"].setdefault("rule_set", []).append(
            {"tag": "rs_legacy", "type": "local", "format": "binary", "path": srs})
        c["route"]["rules"].append({"rule_set": "rs_legacy", "outbound": "hk"})
        json.dump(c, open(bot.SB, "w"))
        meta = bot._render_mihomo_file()
        if not (meta or {}).get("dropped"):
            bad("老机器遗留 .srs 未被记进 dropped(迁移会静默丢掉这条分流)")
        try:
            bot._mihomo_derive({"model": json.dumps(c).encode()})
            bad("遗留 .srs 仍让候选照常生成")
        except Exception as e:  # noqa: BLE001
            if "rs_legacy" not in str(e):
                bad(f"未点名遗留的 .srs 规则集: {e}")
            ok("老机器遗留 .srs → 候选阶段判失败并点名(事务据此中止, 现网不动)")

    # ── 8. 正常规则集(有 rule-provider)不受影响 ──
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp)
        bot._build_source = lambda url, path: (34, False)
        okr, msg = bot.add_ruleset("https://example.com/cn.list", "hk")
        if not okr:
            bad(f"正常 .list 规则集被误拒: {msg}")
        cfg = json.load(open(bot.MIHOMO_CFG))
        if not any(str(r).startswith("RULE-SET,") for r in cfg.get("rules", [])):
            bad("正常规则集没进 mihomo 运行配置")
        ok("正常 .list 规则集照常添加, 并真的进了 mihomo 运行配置")

    # ── 9. doctor 要提前预警遗留 .srs, 而不是等 update 被挡住才让用户回头查 ──
    import importlib.util as _il
    _s = _il.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
    checks = _il.module_from_spec(_s)
    _s.loader.exec_module(checks)
    with tempfile.TemporaryDirectory() as tmp:
        checks.RS_META = os.path.join(tmp, "none.json")
        if checks.check_rulesets() is not None:
            bad("没有规则集时不该显示该检查项")
        checks.RS_META = os.path.join(tmp, "ok.json")
        json.dump({"rs_a": {"url": "https://x/a.list", "format": "source"}},
                  open(checks.RS_META, "w"))
        lv, _lab, _d = checks.check_rulesets()
        if lv != "ok":
            bad(f"正常规则集被判成 {lv}")
        checks.RS_META = os.path.join(tmp, "srs.json")
        json.dump({"rs_old": {"url": "https://x/geo.srs", "format": "binary", "label": "旧规则"}},
                  open(checks.RS_META, "w"))
        lv, _lab, detail = checks.check_rulesets()
        if lv != "fail" or "旧规则" not in detail:
            bad(f"遗留 .srs 未被 doctor 判 fail 并点名: {lv} {detail}")
        if "pdg update" not in detail or "分流管理" not in detail:
            bad(f"doctor 提示不具可操作性: {detail}")
        ok("doctor 提前预警遗留 .srs(点名 + 说明会挡住 update + 给出处理入口)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

# ══════════════════════════════════════════════════════════════════════════════
# 真实规则集 fixture 走**本地 HTTP 服务** —— 不 mock _build_source, 完整跑
# 添加 → 刷新 → 渲染 → 内核校验。
# ══════════════════════════════════════════════════════════════════════════════
import http.server
import threading

FIXTURES = ROOT / "tests" / "fixtures"

# 真实的 Clash YAML provider(mihomo/Clash 生态最常见的形态)
YAML_PROVIDER = b"""payload:
  - DOMAIN-SUFFIX,example.com
  - DOMAIN,api.example.com
  - 'DOMAIN-KEYWORD,exam'
  - IP-CIDR,1.2.3.0/24
"""
SURGE_LIST = b"""# comment
DOMAIN-SUFFIX,surge.example.com
DOMAIN,x.surge.example.com
"""


class _Serve(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):     # 别把请求日志刷进测试输出
        pass


def serve_dir(d):
    """起一个本地 HTTP 服务伺服目录 d, 返回 (base_url, shutdown)。"""
    handler = lambda *a, **k: _Serve(*a, directory=d, **k)   # noqa: E731
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return "http://127.0.0.1:%d" % srv.server_address[1], srv.shutdown


def mihomo_bin():
    """钉死版内核: 走共享 helper(tests/mihomobin.py), 版本核对在它里面。

    以前直接 `shutil.which("mihomo")` —— 捡到机器上任意一版都算数, 而这条断言的意义正是
    "钉死版认不认这份规则集"。找不到返回 None(该断言跳过并说明), 版本不符则抛错。"""
    sys.path.insert(0, os.path.join(ROOT, "tests"))
    import mihomobin
    try:
        return mihomobin.find()[0]
    except mihomobin.MihomoMissing:
        return None


_ZSTD_MODS = ("compression.zstd", "pyzstd", "zstandard")


class _BlockZstdImport:
    """import 时挡掉所有 python zstd 实现(meta_path 钩子)。"""

    def find_spec(self, name, path=None, target=None):
        if name in _ZSTD_MODS:
            raise ImportError("no zstd (blocked by test)")
        return None


@contextlib.contextmanager
def no_zstd():
    """模拟一台**彻底没有 zstd** 的机器: PATH 上没有 zstd 命令, python 也 import 不到实现。

    只摘命令是不够的 —— mrs_behavior 先试 compression.zstd / pyzstd / zstandard, 只有全都
    没有才会退到外部命令。本地 Debian 12(3.11 且没装这些包)恰好两条路都没有, 于是"摘掉命令"
    看起来够用; 换到带这些模块的机器(CI runner 就是), 前提根本不成立, 这条负向用例便会失败 ——
    它测的是"认不出来", 而那台机器其实认得出来。前提要自己造齐, 不能靠跑测试的机器碰巧没装。"""
    d = tmpguard.mkdtemp(prefix="pdgnozstd")
    old = os.environ["PATH"]
    saved = {n: sys.modules.pop(n) for n in _ZSTD_MODS if n in sys.modules}   # 绕开 import 缓存
    blocker = _BlockZstdImport()
    sys.meta_path.insert(0, blocker)
    # 只保留必要目录里的其它命令: 造一个只含符号链接、独独没有 zstd 的 bin 目录
    for p in old.split(os.pathsep):
        if not os.path.isdir(p):
            continue
        for f in os.listdir(p):
            if f == "zstd":
                continue
            dst = os.path.join(d, f)
            if not os.path.exists(dst):
                try:
                    os.symlink(os.path.join(p, f), dst)
                except OSError:
                    pass
    os.environ["PATH"] = d
    try:
        yield
    finally:
        os.environ["PATH"] = old
        try:
            sys.meta_path.remove(blocker)
        except ValueError:
            pass
        sys.modules.update(saved)
        shutil.rmtree(d, ignore_errors=True)


def make_big_mrs():
    """造一份"头部落在压缩块里"的大 .mrs(没有 zstd 命令就返回 None)。

    真实的大规则集就是这个形态 —— 光靠"在原始字节里找 MRS"根本找不到。"""
    if not shutil.which("zstd"):
        return None
    # 内容要**可压缩**(真实规则集就是一堆相似域名): 不可压缩的数据 zstd 会原样存字面量,
    # 头部反而留在明处, 造不出我们要复现的那个形态。
    body = bytearray(b"MRS\x01\x00")
    rnd = random.Random(20260725)
    for i in range(40000):
        body += b"%s%d.example%d.com\n" % (rnd.choice([b"a", b"bb", b"ccc"]), i, i % 997)
    p = subprocess.run(["zstd", "-q", "-19", "-c"], input=bytes(body),
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout if p.returncode == 0 and p.stdout else None


def zstd_or_raw(data):
    """把 MRS 的 zstd 外壳拆掉(拆不了就原样返回) —— 只给测试造"未知版本"的畸形档用。"""
    try:
        p = subprocess.run(["zstd", "-dc"], input=data, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=20)
        if p.returncode == 0 and p.stdout[:3] == b"MRS":
            return p.stdout
    except (OSError, subprocess.SubprocessError):
        pass
    return data


def ruleset_main():
    mrs_fix = FIXTURES / "ruleset-domain.mrs"
    ip_fix = FIXTURES / "ruleset-ipcidr.mrs"
    for f in (mrs_fix, ip_fix):
        if not f.exists():
            bad("缺少真实 MRS fixture: %s" % f)
    mrs_bytes = mrs_fix.read_bytes()
    ipcidr_bytes = ip_fix.read_bytes()

    www = tmpguard.mkdtemp(prefix="pdgwww")
    (Path(www) / "cn.yaml").write_bytes(YAML_PROVIDER)
    (Path(www) / "cn.list").write_bytes(SURGE_LIST)
    (Path(www) / "geo.mrs").write_bytes(mrs_bytes)
    (Path(www) / "ip.mrs").write_bytes(ipcidr_bytes)
    (Path(www) / "opaque.mrs").write_bytes(b"\x28\xb5\x2f\xfd\x00\x00\x00")   # 像 .mrs 但认不出
    base, shutdown = serve_dir(www)
    try:
        # ── 真实 YAML provider: 添加 → 解析出规则 → 刷新 → 渲染进运行配置 ──
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/cn.yaml", "hk")
            if not okr:
                bad(f"真实 Clash YAML provider 添加失败: {msg}")
            m = json.load(open(bot.RS_META))
            info = next(iter(m.values()))
            local = json.load(open(info["path"]))
            rules = local["rules"][0]
            if "example.com" not in rules.get("domain_suffix", []):
                bad(f"YAML provider 的 DOMAIN-SUFFIX 没解析出来: {rules}")
            if "api.example.com" not in rules.get("domain", []):
                bad(f"YAML provider 的 DOMAIN 没解析出来: {rules}")
            if "1.2.3.0/24" not in rules.get("ip_cidr", []):
                bad(f"YAML provider 的 IP-CIDR 没解析出来: {rules}")
            ok("真实 Clash YAML provider(payload: 列表)被正确解析并添加")

            cfg = json.load(open(bot.MIHOMO_CFG))
            if not any(str(r).startswith("RULE-SET,") for r in cfg.get("rules", [])):
                bad("YAML provider 没进 mihomo 运行配置")
            ok("YAML provider 已渲染进 mihomo 运行配置(RULE-SET)")

            rr = bot.refresh_rulesets()
            if not (isinstance(rr, tuple) and len(rr) == 2):
                bad(f"refresh_rulesets 未返回 (成功数, 失败项) 二元组: {rr!r}")
            nok, failed = rr
            if failed or nok < 1:
                bad(f"刷新真实 YAML provider 失败: {rr!r}")
            ok("刷新真实 YAML provider 成功, 且返回明确状态 (成功数, 失败项)")

            mh = mihomo_bin()
            if mh:
                r = subprocess.run([mh, "-t", "-d", bot.MIHOMO_DIR, "-f", bot.MIHOMO_CFG],
                                   capture_output=True, text=True)
                if r.returncode != 0:
                    bad(f"真 mihomo -t 拒绝了含 YAML provider 的配置: {(r.stdout + r.stderr)[-300:]}")
                ok("真 mihomo -t 接受含 YAML provider 的运行配置")
            else:
                print("[SKIP] 本机无 mihomo, 跳过真内核校验(CI 的 e2e/functional job 会覆盖)")

        # ── .mrs: 必须按二进制下载, 不得进文本解析路径 ──
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/geo.mrs", "hk", behavior="domain")
            if not okr:
                bad(f"真实 .mrs 添加失败: {msg}")
            m = json.load(open(bot.RS_META))
            info = next(iter(m.values()))
            got = open(info["path"], "rb").read()
            if got != mrs_bytes:
                bad(".mrs 落盘内容与源文件不一致(疑似走了文本解析路径)")
            if info.get("behavior") != "domain":
                bad(f".mrs 的 behavior 未按显式声明记录: {info}")
            ok("真实 .mrs 按二进制落盘, 内容逐字节一致, behavior 按显式声明记录")

            rr = bot.refresh_rulesets()
            nok, failed = rr
            if failed:
                bad(f".mrs 刷新失败: {rr!r}")
            if open(info["path"], "rb").read() != mrs_bytes:
                bad(".mrs 刷新后内容变了(文本解析把二进制毁了?)")
            ok("再次刷新 .mrs: 仍按二进制处理, 内容逐字节不变")

            # 源头变成坏档(空响应)→ 刷新必须失败并回滚到上一份好档
            (Path(www) / "geo.mrs").write_bytes(b"")
            rr = bot.refresh_rulesets()
            nok, failed = rr
            if not failed:
                bad("坏档(.mrs 空响应)却报刷新成功")
            if open(info["path"], "rb").read() != mrs_bytes:
                bad("坏档刷新后没回滚到上一份好档")
            ok("坏 .mrs → 刷新明确失败并回滚到上一份好档(不断网)")
            (Path(www) / "geo.mrs").write_bytes(mrs_bytes)

        # ── .mrs 的 behavior 从二进制头**认**出来, 而不是猜, 也不是逼用户手填 ──
        # MRS = zstd 压缩, 解压后是 b"MRS" + 版本(1B) + behavior(1B: 0=domain 1=ipcidr)。
        # 认得出就自动填; 认不出(版本不认识/不是 MRS)才要求显式声明 —— 猜错的后果是
        # "规则看着加了却永不命中", 比拒绝难查得多。
        if bot.mrs_behavior(mrs_bytes) != "domain":
            bad("真实 domain .mrs 的 behavior 没认出来: %r" % bot.mrs_behavior(mrs_bytes))
        if bot.mrs_behavior(ipcidr_bytes) != "ipcidr":
            bad("真实 ipcidr .mrs 的 behavior 没认出来: %r" % bot.mrs_behavior(ipcidr_bytes))
        ok("两份真实 .mrs(domain/ipcidr)的 behavior 都从二进制头认了出来")
        if bot.mrs_behavior(b"not an mrs at all") is not None:
            bad("非 MRS 数据被认出了 behavior")
        # 版本号不是 1 → 布局可能变了, 宁可不认(别拿旧假设去解析新格式)
        future = bytearray(zstd_or_raw(mrs_bytes))
        i = future.find(b"MRS")
        future[i + 3] = 9
        if bot.mrs_behavior(bytes(future)) is not None:
            bad("未知 MRS 版本仍被解析了 behavior")
        ok("非 MRS / 未知版本 → 不认(返回 None), 不做危险假设")

        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/geo.mrs", "hk")     # 不带 behavior
            if not okr:
                bad(f"能认出 behavior 的 .mrs 仍被拒: {msg}")
            info = next(iter(json.load(open(bot.RS_META)).values()))
            if info.get("behavior") != "domain":
                bad(f".mrs 的 behavior 没自动认出并记录: {info}")
            cfg = json.load(open(bot.MIHOMO_CFG))
            prov = next(iter(cfg.get("rule-providers", {}).values()), {})
            if prov.get("format") != "mrs" or prov.get("behavior") != "domain":
                bad(f"自动识别的 .mrs 没按 mrs/domain 渲染进运行配置: {prov}")
            ok("未声明 behavior 的 .mrs: 自动识别为 domain 并渲染进运行配置")

        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/ip.mrs", "hk")
            info = next(iter(json.load(open(bot.RS_META)).values()))
            if not okr or info.get("behavior") != "ipcidr":
                bad(f"ipcidr .mrs 没被认出: {okr} {msg} {info}")
            ok("ipcidr 的 .mrs 同样自动识别(没有一律当 domain)")
            mh = mihomo_bin()
            if mh:
                r = subprocess.run([mh, "-t", "-d", bot.MIHOMO_DIR, "-f", bot.MIHOMO_CFG],
                                   capture_output=True, text=True)
                if r.returncode != 0:
                    bad(f"真 mihomo -t 拒绝了自动识别 behavior 的 .mrs 配置: {(r.stdout + r.stderr)[-300:]}")
                ok("真 mihomo -t 接受自动识别 behavior 的 .mrs 运行配置")

        # 用户填错类型 → 以文件里的为准(文件是事实), 并说明已纠正
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/geo.mrs", "hk", behavior="ipcidr")
            info = next(iter(json.load(open(bot.RS_META)).values()))
            if info.get("behavior") != "domain":
                bad(f"用户填错类型时没以文件为准: {info}")
            if "domain" not in msg:
                bad(f"纠正了类型却没告诉用户: {msg}")
            ok("用户填错 behavior → 以文件二进制头为准并说明(不按错的渲染)")

        # 认不出来的 .mrs: 仍旧拒绝并要求显式声明, 绝不猜
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            okr, msg = bot.add_ruleset(base + "/opaque.mrs", "hk")
            if okr:
                bad("认不出 behavior 的 .mrs 却被接受(等于猜)")
            if "behavior" not in msg and "类型" not in msg:
                bad(f"拒绝文案没说清要指定类型: {msg}")
            ok("认不出 behavior 的 .mrs → 仍要求显式声明(不猜)")

        # 老机器: RS_META 里的旧 .mrs 条目没有 behavior 字段 —— 靠本地已下好的文件补上,
        # 不必让用户逐条手填(此前这类条目一律被跳过, 分流静默失效)
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            bot.add_ruleset(base + "/geo.mrs", "hk", behavior="domain")
            m = json.load(open(bot.RS_META))
            name, info = next(iter(m.items()))
            del m[name]["behavior"]                       # 造出老条目
            json.dump(m, open(bot.RS_META, "w"))
            rs = bot._mihomo_rulesets()
            if name not in rs or rs[name].get("behavior") != "domain":
                bad(f"老条目没能从本地 .mrs 文件补出 behavior: {rs}")
            ok("老条目(缺 behavior)从本地 .mrs 文件补出类型, 不再被静默跳过")

            # 刷新时把认出来的类型**持久化**回元数据, 省得每次渲染重新嗅探
            bot.refresh_rulesets()
            if json.load(open(bot.RS_META))[name].get("behavior") != "domain":
                bad("刷新后没把识别出的 behavior 回填进元数据")
            ok("刷新把识别出的 behavior 回填进元数据(一次性收敛)")

            # 本地文件也认不出 → 仍旧跳过, 不猜
            open(info["path"], "wb").write(b"garbage-not-mrs")
            m = json.load(open(bot.RS_META)); del m[name]["behavior"]
            json.dump(m, open(bot.RS_META, "w"))
            if name in bot._mihomo_rulesets():
                bad("本地文件认不出类型却仍被渲染(等于猜)")
            ok("本地文件也认不出 → 仍跳过并交由上层报错(不猜)")

        # ── 大 .mrs: 头部落在压缩块里, "在原始字节里找 MRS"这条兜底根本找不到 ──
        # 真实规则集(几十万条域名)就是这个量级。之前只有小文件能被认出来, 大文件全部退化成
        # "要用户手填", 而用户根本不知道为什么同样是 .mrs 有的要填有的不要。
        big = make_big_mrs()
        if big is None:
            print("[SKIP] 本机无 zstd 命令, 造不出大 .mrs 样本(跳过该用例)")
        else:
            if big.find(b"MRS", 0, 65536) >= 0:
                bad("样本没造对: 大 .mrs 的头部不该能在原始字节里直接找到")
            if bot.mrs_behavior(big) != "domain":
                bad("大 .mrs(头部在压缩块内)的 behavior 没认出来: %r" % bot.mrs_behavior(big))
            ok("大 .mrs(头部在压缩块内, 盲扫找不到)照样认出 behavior")

            # 本机连 zstd 都没有时: 老实认不出, 并**指出装 zstd 就能自动识别** ——
            # 只说"请指定类型"等于让用户永远手填下去
            (Path(www) / "big.mrs").write_bytes(big)
            with tempfile.TemporaryDirectory() as tmp, no_zstd():
                setup(tmp)
                if bot.mrs_behavior(big) is not None:
                    bad("无 zstd 时不该还能认出大 .mrs 的类型")
                okr, msg = bot.add_ruleset(base + "/big.mrs", "hk")
                if okr:
                    bad("无 zstd、认不出类型的大 .mrs 却被接受")
                if "zstd" not in msg:
                    bad(f"没告诉用户装 zstd 即可自动识别: {msg}")
                ok("无 zstd → 认不出时明确提示装 zstd(而不是让用户永远手填)")

                # 小文件在无 zstd 时仍能靠原始字节扫出来(别把已有能力弄丢)
                if bot.mrs_behavior(mrs_bytes) != "domain":
                    bad("无 zstd 时小 .mrs 也认不出了(原始扫描兜底被弄丢)")
                ok("无 zstd 时小 .mrs 仍能靠原始字节兜底认出")

        # 有 python zstd 模块的环境不该依赖外部命令(接线要通)
        with no_zstd():
            fake = types.ModuleType("pyzstd")
            fake.decompress = lambda d: b"MRS\x01\x01" + b"\x00" * 16
            sys.modules["pyzstd"] = fake
            try:
                if bot.mrs_behavior(b"\x28\xb5\x2f\xfd" + b"\x00" * 32) != "ipcidr":
                    bad("有 python zstd 模块时没走模块路径")
                ok("有 python zstd 模块时不依赖外部 zstd 命令")
            finally:
                sys.modules.pop("pyzstd", None)

        # 装机依赖里必须带 zstd, 否则上面那条"装了就能自动识别"在新机器上永远用不上
        inst = (ROOT / "install.sh").read_text(encoding="utf-8")
        apt = [ln for ln in inst.splitlines() if "apt-get install" in ln and "nftables" in ln]
        if not apt or not any(re.search(r"\bzstd\b", ln) for ln in apt):
            bad("install.sh 的依赖列表里没有 zstd")
        ok("装机依赖含 zstd(新机器开箱即可自动识别 .mrs 类型)")

        # .mrs 只支持 domain / ipcidr: classical 连 mihomo 自己的 convert-ruleset 都会崩,
        # 收下它等于配出一份内核加载不了的规则
        if "classical" in bot.MRS_BEHAVIORS:
            bad(".mrs 仍接受 classical(mihomo 不支持该组合)")
        ok(".mrs 的可选类型收敛为 domain / ipcidr(不再放行 mihomo 不支持的 classical)")

        # ── 刷新部分失败: 必须如实报出是哪一个 ──
        with tempfile.TemporaryDirectory() as tmp:
            setup(tmp)
            bot.add_ruleset(base + "/cn.list", "hk")
            m = json.load(open(bot.RS_META))
            name = next(iter(m))
            m[name]["url"] = base + "/does-not-exist.list"      # 让它刷新时 404
            json.dump(m, open(bot.RS_META, "w"))
            nok, failed = bot.refresh_rulesets()
            if not failed:
                bad("规则集 404 却报刷新成功")
            if not any(name in str(f) for f in failed):
                bad(f"失败项没点名是哪个规则集: {failed}")
            ok("刷新失败如实返回失败项并点名(不再只 print 却表现为成功)")
    finally:
        shutdown()
        shutil.rmtree(www, ignore_errors=True)

    print(f"通过 {pass_n} 项断言(含真实 fixture)")


if __name__ == "__main__":
    ruleset_main()

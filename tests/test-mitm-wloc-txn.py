#!/usr/bin/env python3
"""WLOC/MITM 应用走**统一配置事务**(5.1B)。

_mitm_transact 现在是一笔 pdgtx 事务: mitm_json + mitm_hijack + mihomo_cfg 一起校验、一起落盘,
服务动作固定顺序(开启: 落盘 → restart:mihomo → restart:mosdns → start:pdg-mitm;
关闭: 落盘 → stop:pdg-mitm → restart:mihomo → restart:mosdns), 回滚与崩溃恢复交给事务核心。

这里**不 mock 事务核心, 也不 mock 锁**: 用真沙箱(真文件树 + 假 systemd + 真 mihomo 桩)跑真事务,
只把"外部世界"注入故障 —— CA/预热、服务起不来、mihomo 校验不过、别的进程占锁或改了 model。
保证仍然是那两条:
  · 绝不『返回失败但新态(enabled=true)已持久化』;
  · 绝不『服务失败却返回成功』。
"""
import importlib.util as u
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
from txbox import Box, load_tx  # noqa: E402

pass_n = 0
fail_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m); pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL]", m); fail_n += 1


MODEL = {"outbounds": [{"type": "shadowsocks", "tag": "hk", "server": "1.1.1.1",
                        "server_port": 8388, "method": "aes-256-gcm", "password": "pw"},
                       {"type": "direct", "tag": "direct"}],
         "route": {"rules": [{"ip_cidr": ["127.0.0.0/8"], "action": "reject"}], "final": "hk"},
         "inbounds": [{"type": "direct", "tag": "in"}]}
OLD_W = {"enabled": False, "accuracy": 50, "active": "old", "generation": 3,
         "locations": [{"name": "old", "lat": 1.0, "lon": 2.0}]}
NEW_W = {"enabled": True, "accuracy": 50, "active": "tokyo", "generation": 4,
         "locations": [{"name": "tokyo", "lat": 35.6, "lon": 139.7}]}


class Ctx:
    ca_raises = False
    prewarm_n = None          # None = 全部成功; int = 只成功这么多张
    prewarm_raises = False
    ca_calls = 0              # ensure_ca + prewarm 一共被调了几次
    warmed_doms = []          # 最后一次预热的域名(数量/内容都要对)


def make_box(mitm_active=False):
    """一台"iOS 平台、WLOC 关着"的机器 + 接好线的 bot 模块。"""
    box = Box()
    load_tx(box.env)
    for m in list(sys.modules):
        if m == "pdgtx":
            del sys.modules[m]
    spec = u.spec_from_file_location("pdg_bot_mitm_%d" % id(box), ROOT / "deploy/bot/pdg-bot.py")
    bot = u.module_from_spec(spec); spec.loader.exec_module(bot)
    bot.SB = box.path("/etc/sing-box/config.json")
    bot.MITM_CONFIG = box.path("/etc/privdns-gateway/mitm.json")
    bot.MITM_HIJACK_FILE = box.path("/etc/mosdns/rules/mitm_hijack.txt")
    bot.MIHOMO_CFG = box.path("/etc/mihomo/config.yaml")
    bot.MIHOMO_DIR = box.path("/etc/mihomo")
    bot.RS_META = box.path("/opt/pdg-bot/rulesets.json")
    bot.LOCKFILE = box.env["PDG_LOCKFILE"]
    bot._platform = lambda: "ios"
    bot._core_backend = lambda: "mihomo"
    box.put("/etc/sing-box/config.json", json.dumps(MODEL).encode())
    box.put("/etc/privdns-gateway/mitm.json",
            json.dumps({"wloc": bot._wloc_doc(OLD_W)}, ensure_ascii=False).encode())
    box.put("/etc/mosdns/rules/mitm_hijack.txt", b"", 0o644)
    box.put("/etc/mihomo/config.yaml", b"{}\n")
    box.up("mosdns"); box.up("mihomo")
    if mitm_active:
        box.up("pdg-mitm")
    else:
        box.down("pdg-mitm")
    import mitm_ca
    mitm_ca.ensure_ca = _ensure_ca
    mitm_ca.prewarm = _prewarm
    Ctx.ca_raises = False; Ctx.prewarm_n = None; Ctx.prewarm_raises = False
    Ctx.ca_calls = 0; Ctx.warmed_doms = []
    return box, bot


def _ensure_ca():
    Ctx.ca_calls += 1
    if Ctx.ca_raises:
        raise RuntimeError("openssl boom /etc/secret/path")
    return "/x/ca.crt"


def _prewarm(d, strict=False):
    """故意"短返回但不抛" —— 独立验证调用方真的检查了返回张数, 而不是只靠严格模式抛异常兜底。"""
    Ctx.ca_calls += 1
    Ctx.warmed_doms = list(d or [])
    if Ctx.prewarm_raises:
        raise RuntimeError("leaf boom /etc/secret/leaf.key")
    doms = list(d or [])
    return len(doms) if Ctx.prewarm_n is None else Ctx.prewarm_n


def snap(box):
    return {
        "mitm": box.read("/etc/privdns-gateway/mitm.json"),
        "hijack": box.read("/etc/mosdns/rules/mitm_hijack.txt"),
        "mihomo": box.read("/etc/mihomo/config.yaml"),
        "model": box.read("/etc/sing-box/config.json"),
    }


def enabled_on_disk(box):
    try:
        return json.loads(box.read("/etc/privdns-gateway/mitm.json").decode()).get("wloc", {}).get("enabled")
    except Exception:  # noqa: BLE001
        return None


def unchanged(box, before, label):
    now = snap(box)
    diff = [k for k in before if before[k] != now[k]]
    if diff:
        bad("%s: 这些生产文件被动过了: %s" % (label, diff))
        return False
    return True


def main():
    # ── 1. 开启成功: 三个目标一起落盘 + pdg-mitm 起来 ──
    box, bot = make_box()
    okr, msg = bot._mitm_transact(NEW_W)
    if not okr:
        bad("正常开启失败: %s" % msg)
    else:
        ok("开启: 事务提交成功")
    if enabled_on_disk(box) is True:
        ok("开启: mitm.json 持久化 enabled=true")
    else:
        bad("mitm.json 没落新态")
    hij = (box.read("/etc/mosdns/rules/mitm_hijack.txt") or b"").decode()
    if "domain:gs-loc.apple.com" in hij and "domain:gs-loc-cn.apple.com" in hij:
        ok("开启: mitm_hijack 由候选 mitm.json 派生出两个接管域名")
    else:
        bad("hijack 内容不对: %r" % hij)
    mih = (box.read("/etc/mihomo/config.yaml") or b"").decode()
    if "gs-loc.apple.com" in mih:
        ok("开启: mihomo 配置里出现接管域名(派生自候选, 不是回读旧生产 hijack)")
    else:
        bad("mihomo 配置没带上接管域名")
    if os.path.exists(os.path.join(box.state, "pdg-mitm.active")):
        ok("开启: pdg-mitm 已 active(start 动作 + 观察期确认)")
    else:
        bad("pdg-mitm 没起来")
    calls = open(box.calls).read()
    order = [l for l in calls.splitlines() if l.startswith("systemctl restart")
             or l.startswith("systemctl start") or l.startswith("systemctl stop")]
    if order and order[-1].endswith("start pdg-mitm") and "restart mihomo" in order[0]:
        ok("开启动作顺序: restart:mihomo → restart:mosdns → start:pdg-mitm")
    else:
        bad("动作顺序不对: %s" % order)
    if Ctx.ca_calls >= 2 and sorted(Ctx.warmed_doms) == sorted(
            ["gs-loc.apple.com", "gs-loc-cn.apple.com"]):
        ok("开启: CA 已生成、两个接管域名都预签过(缓存准备在落盘之前)")
    else:
        bad("CA/预热没按候选域名做: calls=%d doms=%s" % (Ctx.ca_calls, Ctx.warmed_doms))
    if not any(p.endswith(".botbak") for p in os.listdir(os.path.dirname(bot.SB))):
        ok("不再有手工备份文件(.botbak)—— before-image 由事务负责")
    else:
        bad("仍在写手工备份")
    box.clean()

    # ── 2. 关闭成功: 清空 hijack + 停 pdg-mitm ──
    box, bot = make_box(mitm_active=True)
    box.put("/etc/privdns-gateway/mitm.json",
            json.dumps({"wloc": bot._wloc_doc(NEW_W)}, ensure_ascii=False).encode())
    box.put("/etc/mosdns/rules/mitm_hijack.txt", b"domain:gs-loc.apple.com\n", 0o644)
    okr, msg = bot._mitm_transact({**NEW_W, "enabled": False})
    if Ctx.ca_calls == 0:
        ok("关闭: 没有接管域名 → 不碰 CA/预热")
    else:
        bad("关闭时还去动了 CA: %d 次" % Ctx.ca_calls)
    if okr and enabled_on_disk(box) is False \
            and (box.read("/etc/mosdns/rules/mitm_hijack.txt") or b"").strip() == b"":
        ok("关闭: enabled=false + hijack 清空(无域名不需 CA)")
    else:
        bad("关闭失败: %s / enabled=%s" % (msg, enabled_on_disk(box)))
    if not os.path.exists(os.path.join(box.state, "pdg-mitm.active")):
        ok("关闭: pdg-mitm 已确认 inactive(stop 成功不被判成服务故障)")
    else:
        bad("关闭后 pdg-mitm 仍在跑")
    stops = [l for l in open(box.calls).read().splitlines() if "stop pdg-mitm" in l]
    if stops:
        ok("关闭用的是 stop:pdg-mitm 目标态动作")
    else:
        bad("没看到 stop pdg-mitm")
    box.clean()

    # ── 3. CA / 预热失败: 事务连 stage 都不做 → 生产零改动 ──
    for label, setup in (("CA 抛异常", lambda: setattr(Ctx, "ca_raises", True)),
                         ("预签返回 0 张", lambda: setattr(Ctx, "prewarm_n", 0)),
                         ("预签少一张", lambda: setattr(Ctx, "prewarm_n", 1)),
                         ("预签抛异常", lambda: setattr(Ctx, "prewarm_raises", True))):
        box, bot = make_box()
        before = snap(box)
        setup()
        okr, msg = bot._mitm_transact(NEW_W)
        if okr:
            bad("%s 却报成功" % label)
        elif unchanged(box, before, label):
            ok("%s → 失败且生产零改动(缓存准备在落盘之前)" % label)
        if "boom" in msg or "/etc/secret" in msg:
            bad("%s 的提示泄露了内部异常/路径: %s" % (label, msg))
        else:
            ok("%s 的提示不含内部路径与异常正文" % label)
        box.clean()

    # ── 4. 候选校验不过(mihomo -t 失败)→ 拒绝, 生产零改动 ──
    box, bot = make_box()
    before = snap(box)
    box.fail_cmd("mihomo")
    okr, msg = bot._mitm_transact(NEW_W)
    if not okr and unchanged(box, before, "mihomo 校验失败"):
        ok("mihomo 候选校验不过 → 拒绝提交, 生产零改动(连回滚都不需要)")
    else:
        bad("mihomo 校验失败却提交了: %s" % msg)
    box.clean()

    # ── 5. 服务失败: pdg-mitm 起不来 / mosdns 重启失败 → 完整回滚 ──
    for unit in ("pdg-mitm", "mosdns", "mihomo"):
        box, bot = make_box()
        before = snap(box)
        box._systemctl([unit], False)          # 该 unit 的 start/restart 一律 rc!=0
        okr, msg = bot._mitm_transact(NEW_W)
        if okr:
            bad("%s 起不来却报成功" % unit)
        elif unchanged(box, before, "%s 失败" % unit):
            ok("%s 起不来 → 三个目标一起回滚到操作前(逐字节)" % unit)
        if enabled_on_disk(box) is False:
            ok("%s 失败: 没留下 enabled=true 的半套状态" % unit)
        else:
            bad("%s 失败后 enabled 是 %s" % (unit, enabled_on_disk(box)))
        box.clean()

    # ── 6. pdg-mitm 起来了但在崩溃循环里 → 判失败并回滚 ──
    box, bot = make_box()
    before = snap(box)
    box.bump_restarts("pdg-mitm", 2)
    okr, msg = bot._mitm_transact(NEW_W)
    if not okr and unchanged(box, before, "pdg-mitm 崩溃循环"):
        ok("pdg-mitm 起来即崩(NRestarts 上涨)→ 判失败并回滚")
    else:
        bad("崩溃循环被当成成功: %s" % msg)
    box.clean()

    # ── 7. 并发: model / rs_meta 在候选生成后被改 → PRECONDITION_FAILED ──
    for dep in ("model", "rs_meta"):
        box, bot = make_box()
        before = snap(box)
        real_derive = None

        def _mut(w, dep=dep, box=box):
            w.update({k: v for k, v in NEW_W.items()})
            # 在 watch 之后、commit 之前改掉依赖: 用 mutate 回调里改不行(watch 还没跑),
            # 所以借 derive 的时机 —— 派生器在 commit 里、前置检查之前被调用。
            return None

        okr = None
        t_orig = bot._render_mihomo_bytes

        def _render(model, rs_meta=None, mitm_domains=None, dep=dep, box=box):
            if dep == "model":
                box.put("/etc/sing-box/config.json",
                        json.dumps({**MODEL, "route": {"rules": [], "final": "direct"}}).encode())
            else:
                box.put("/opt/pdg-bot/rulesets.json", b'{"x": {"url": "https://e/x.list"}}', 0o644)
            return t_orig(model, rs_meta, mitm_domains=mitm_domains)

        bot._render_mihomo_bytes = _render
        try:
            okr, msg = bot._mitm_transact(NEW_W)
        finally:
            bot._render_mihomo_bytes = t_orig
        if okr:
            bad("%s 被并发改过却照样提交" % dep)
        elif "PRECONDITION_FAILED" in msg:
            ok("%s 在候选生成后被改 → PRECONDITION_FAILED" % dep)
        else:
            bad("%s 并发变化的报错不对: %s" % (dep, msg))
        if box.read("/etc/privdns-gateway/mitm.json") == before["mitm"]:
            ok("%s 并发变化时 mitm.json 一个字节都没写" % dep)
        else:
            bad("%s 并发变化却写了 mitm.json" % dep)
        box.clean()

    # ── 8. 事务锁被别的进程占着 → BUSY_MSG, 生产零改动 ──
    box, bot = make_box()
    before = snap(box)
    holder = subprocess.Popen(
        [sys.executable, "-c",
         "import fcntl, sys\nf = open(sys.argv[1], 'w')\nfcntl.flock(f, fcntl.LOCK_EX)\n"
         "sys.stdout.write('READY\\n'); sys.stdout.flush()\nsys.stdin.readline()\n",
         box.env["PDG_LOCKFILE"]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, universal_newlines=True)
    try:
        if (holder.stdout.readline() or "").strip() != "READY":
            bad("占锁进程没拿到锁, 这条用例前提不成立")
        okr, msg = bot._mitm_transact(NEW_W)
        if okr is False and msg == bot.BUSY_MSG and unchanged(box, before, "锁被占"):
            ok("事务锁被占 → BUSY_MSG 且生产零改动")
        else:
            bad("锁被占时的行为不对: %s / %r" % (okr, msg))
    finally:
        try:
            holder.stdin.write("go\n"); holder.stdin.flush()
        except Exception:  # noqa: BLE001
            holder.kill()
        holder.wait(timeout=10)
    box.clean()

    # ── 9. Android: 连事务目录都不建, 一个字节不写 ──
    box, bot = make_box()
    before = snap(box)
    bot._platform = lambda: "android"
    txroot = box.env["PDG_TX_ROOT"]
    n_before = len(os.listdir(txroot)) if os.path.isdir(txroot) else 0
    okr, msg = bot._mitm_transact(NEW_W)
    n_after = len(os.listdir(txroot)) if os.path.isdir(txroot) else 0
    if okr is False and "iOS" in msg and unchanged(box, before, "Android") and n_after == n_before:
        ok("Android: 平台门控在最前面 —— 不写文件, 连事务都不开")
    else:
        bad("Android 门控不对: %s / %s / 事务目录 %d→%d" % (okr, msg, n_before, n_after))
    box.clean()

    # ── 10. 候选阶段放弃不留残骸: _WlocAbort / CA 失败 / 预签失败 ──
    def tx_states(box):
        root = box.env["PDG_TX_ROOT"]
        out = []
        for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            mp = os.path.join(root, d, "meta.json")
            if os.path.isfile(mp):
                m = json.load(open(mp, encoding="utf-8"))
                out.append((d, m.get("state"),
                            os.path.isdir(os.path.join(root, d, "candidate"))))
        return out

    for label, setup in (("_WlocAbort", None),
                         ("CA 失败", lambda: setattr(Ctx, "ca_raises", True)),
                         ("预签失败", lambda: setattr(Ctx, "prewarm_n", 0))):
        box, bot = make_box()
        if setup:
            setup()
        if label == "_WlocAbort":
            def _abort(w):
                raise bot._WlocAbort("没有可用地点")
            okr, msg = bot._mitm_transact(_abort)
        else:
            okr, msg = bot._mitm_transact(NEW_W)
        sts = tx_states(box)
        bad_left = [x for x in sts if x[1] in ("PREPARING", "VALIDATED") or x[2]]
        if okr is False and not bad_left and sts:
            ok("%s → 事务自己收尾成 %s, 候选材料已删" % (label, sts[-1][1]))
        else:
            bad("%s 之后残留: %s" % (label, sts))
        # 判据找的是**候选正文**有没有漏进 meta。txid 与 started_at/ended_at 不是候选
        # 内容, 但它们的格式(`…SS.mmm…` / `1787378576.055…`)天然可能含有 "35.6" 这四个
        # 字符 —— 那会让这条断言在某些时刻凭空变红。CI 上真撞过一次(同一 commit 重跑即绿)。
        # 所以先把这几个字段摘掉再搜: 剔的是干草, 不是针 —— "35.6" 仍是原来那根针。
        def _no_ts(raw):
            try:
                d_ = json.loads(raw)
            except ValueError:
                return raw
            for k in ("txid", "started_at", "ended_at"):
                d_.pop(k, None)
            return json.dumps(d_, ensure_ascii=False)

        metas = "".join(_no_ts(open(os.path.join(box.env["PDG_TX_ROOT"], d, "meta.json"),
                                    encoding="utf-8").read()) for d, _s, _c in sts)
        if "BACKUP-PASSWORD" not in metas and "35.6" not in metas:
            ok("%s: meta 里没有候选正文/坐标" % label)
        else:
            bad("%s: meta 泄露了候选内容" % label)
        box.clean()

    print("\n通过 %d, 失败 %d" % (pass_n, fail_n))
    return 1 if fail_n else 0


if __name__ == "__main__":
    sys.exit(main())

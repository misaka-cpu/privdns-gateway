#!/usr/bin/env python3
"""WLOC 切地点走快路径, 开/关才走完整事务; 以及切换后的真实反馈。

只改经纬度时, 接管域名没变 —— CA 预热、写 hijack、重渲内核、重启 pdg-mitm/mosdns 一件都
不需要: 切换只原子更新 mitm.json, pdg-mitm 在下一次 WLOC 请求开始时读取当前配置。
旧实现每次切换都跑完整事务: 慢, 而且白断一次
DNS。这里用**探针**盯死这几件事一件都没发生, 而不是只看返回值。

反馈这一半的要求同样明确: 网关只能保证"下一次 WLOC 请求会用新坐标", 所以 bot 等的是**手机
真的来过请求**这件事实, 没等到就如实说没等到 —— 绝不把"网关改写了响应"说成"手机位置变了"。
"""
import importlib.util as u
import json
import os
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))


class FakeCA:
    """假的 mitm_ca —— 只为数被调用了几次(切换路径下必须是 0 次)。"""
    calls = 0

    @staticmethod
    def ensure_ca():
        FakeCA.calls += 1
        return "/x/ca.crt"

    @staticmethod
    def prewarm(doms, strict=False):
        FakeCA.calls += 1
        return len(list(doms or []))

    @staticmethod
    def ca_cert_pem():
        return ""


sys.modules["mitm_ca"] = types.SimpleNamespace(
    ensure_ca=FakeCA.ensure_ca, prewarm=FakeCA.prewarm, ca_cert_pem=FakeCA.ca_cert_pem)

spec = u.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = u.module_from_spec(spec); spec.loader.exec_module(bot)

real_edit_only = bot.edit_only          # 留底: 有一组用例要测真的 edit_only, 别用桩

pass_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m); pass_n += 1


def bad(m):
    print("[FAIL]", m); sys.exit(1)


class Spy:
    """记录本轮里"重活"被干了几次。"""
    def __init__(self):
        self.tx = 0                 # 开过几笔 pdgtx 事务(热路径必须是 0)
        self.transact = 0           # 走过几次完整路径(_mitm_transact)
        self.sh = []
        self.ca0 = FakeCA.calls

    @property
    def ca(self):
        return FakeCA.calls - self.ca0

    def restarts(self):
        return [c[2] for c in self.sh if len(c) >= 3 and c[1] in ("restart", "start", "stop")]


SPY = Spy()


def _sh(cmd):
    SPY.sh.append(list(cmd))
    return types.SimpleNamespace(returncode=0, stdout="active", stderr="")


def setup(tmp):
    global SPY
    bot.MITM_CONFIG = os.path.join(tmp, "mitm.json")
    bot.MITM_HIJACK_FILE = os.path.join(tmp, "mitm_hijack.txt")
    bot.LOCKFILE = os.path.join(tmp, "pdg.lock")        # 真的走一遍配置锁(含跨进程 flock)
    bot.WLOC_STATUS_FILE = os.path.join(tmp, "wloc-status.json")
    bot._platform = lambda: "ios"
    bot._svc_active = lambda unit, **k: True
    bot.sh = _sh
    # 热路径的判据从"没调某个内部函数"改成"**没开事务**": 前者在函数被删掉后会变成空断言,
    # 后者盯的是真正要避免的东西(完整事务 = 观察窗口 + 服务动作)。
    os.environ["PDG_TX_ROOT"] = os.path.join(tmp, "tx")
    real_pdgtx = bot._pdgtx

    def _spy_pdgtx():
        m = real_pdgtx()
        m.TX_ROOT = os.path.join(tmp, "tx")
        m.AUDIT = os.path.join(tmp, "tx", "index.jsonl")
        if not getattr(m, "_spied", False):
            real_tx = m.Tx

            class SpyTx(real_tx):
                def __init__(self, *a, **k):
                    SPY.tx += 1
                    super().__init__(*a, **k)
            m.Tx = SpyTx
            m._spied = True
        return m
    bot._pdgtx = _spy_pdgtx

    def _fake_transact(new_wloc):
        """只记账 + 落盘目标态。完整事务的内部行为(候选/服务动作/回滚)由
        test-mitm-wloc-txn.py 在真沙箱里验 —— 这里验的是**哪条路径被选中**。"""
        SPY.transact += 1
        w = bot._wloc_state()
        if callable(new_wloc):
            try:
                new_wloc(w)
            except bot._WlocAbort as e:
                return False, str(e)
        else:
            w = new_wloc
        bot._wloc_save(w)
        return True, ""
    bot._mitm_transact = _fake_transact
    SPY = Spy()


def write_status(path, generation, target, upstream_ok=True, patched=True, error_type=""):
    doc = {"generation": generation, "target_name": target, "received_at": time.time(),
           "upstream_ok": upstream_ok, "patched": patched, "error_type": error_type, "pid": 1}
    t = path + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
    os.replace(t, path)


def seed(enabled=True):
    """造出"已有三个地点"的现场(直接写配置, 不经事务)。"""
    doc = {"wloc": {"enabled": enabled, "accuracy": 50, "active": "东京", "generation": 3,
                    "locations": [{"name": "东京", "lat": 35.6812, "lon": 139.7671},
                                  {"name": "大阪", "lat": 34.6937, "lon": 135.5023},
                                  {"name": "上海", "lat": 31.2304, "lon": 121.4737}]}}
    with open(bot.MITM_CONFIG, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)


def main():
    # ══ 1. WLOC 已开启, 只切地点 → 快路径 ═══════════════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        t0 = time.monotonic()
        okr, msg, gen = bot.wloc_switch_gen("大阪")
        cost = time.monotonic() - t0
        if not okr:
            bad(f"切换失败: {msg}")
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if w["active"] != "大阪":
            bad(f"active 没切过去: {w}")
        ok("已开启时切地点: active 正确变化")
        if w["generation"] != 4 or gen != 4:
            bad(f"generation 没 +1: {w.get('generation')} / 返回 {gen}")
        ok("generation 恰好 +1(bot 靠它认出这次命中属于哪次切换)")
        if SPY.tx:
            bad(f"热路径开了 {SPY.tx} 笔完整事务(观察窗口会把 1 秒目标击穿)")
        ok("热路径没开完整事务(不重渲内核、不进观察窗口)")
        if SPY.ca:
            bad(f"CA 相关函数被调用了 {SPY.ca} 次(不该重生成/预热证书)")
        ok("CA 未被生成或预热")
        if SPY.sh:
            bad(f"执行了 systemctl: {SPY.sh}")
        ok("一条 systemctl 都没执行(mihomo / mosdns / pdg-mitm 均未重启)")
        if os.path.exists(bot.MITM_HIJACK_FILE):
            bad("mitm_hijack.txt 被改写了(接管域名并没变)")
        ok("mitm_hijack.txt 未被触碰")
        if cost > 1.0:
            bad(f"快路径耗时 {cost:.3f}s, 超过 1 秒")
        ok(f"快路径耗时 {cost * 1000:.1f} ms(<1s)")
        for kw in ("网关服务无需重启", "关闭 iPhone 定位服务"):
            if kw not in msg:
                bad(f"提示里没有「{kw}」: {msg}")
        # 这道守卫要防的是"把网关改写响应说成手机位置已经变了"。原来用 "位置已" 做判据,
        # 但文案现在以「位置已切换，网关服务无需重启」开头 —— 主语是网关。所以判据落到
        # **手机**上: 谁声称 iPhone/手机的位置或定位已经成功, 谁就越界。
        for claim in ("手机位置已", "iPhone 位置已", "定位已成功", "手机显示的位置已",
                      "已定位到", "位置已生效"):
            if claim in msg:
                bad(f"文案把网关改写说成了手机位置已变化(「{claim}」): {msg}")
        if "网关" not in msg:
            bad(f"提示里没点明主语是网关, 「位置已切换」会被读成手机已变: {msg}")
        ok("提示只说到「网关目标已切换 / 网关服务无需重启」, 不谎称手机位置已变")

        # ── 热路径例外的代价: 必须留一条脱敏审计(与事务同一份日志/同一种格式) ──
        audit = os.path.join(tmp, "tx", "index.jsonl")
        lines = [json.loads(l) for l in open(audit, encoding="utf-8")] \
            if os.path.exists(audit) else []
        hot = [r for r in lines if str(r.get("op", "")).startswith("wloc_hot")]
        if not hot:
            bad("热路径没有留下任何审计记录(受控例外也要留痕)")
        ok("热路径写了审计记录: %s" % hot[-1]["op"])
        rec = hot[-1]
        if rec.get("generation_before") == 3 and rec.get("generation_after") == 4 \
                and rec.get("generation_changed") is True:
            ok("审计记了 generation 变化(3→4)与结果, 足够对账")
        else:
            bad("审计里的 generation 信息不对: %s" % rec)
        raw = json.dumps(rec, ensure_ascii=False)
        leaked = [x for x in ("大阪", "东京", "35.68", "139.76", "34.69", "135.50") if x in raw]
        if leaked:
            bad("审计泄露了位置信息: %s" % leaked)
        ok("审计里没有地点名, 也没有经纬度(位置数据不入日志)")
        if rec.get("txid") is None and rec.get("schema_version") == 1:
            ok("审计格式与事务记录同源(同字段集, txid 为空表示不是完整事务)")
        else:
            bad("审计格式和事务记录不一致: %s" % rec)

        # ── 审计写失败绝不能把已经成功的切换报成失败 ──
        real_pdgtx = bot._pdgtx
        bot._pdgtx = lambda: (_ for _ in ()).throw(OSError("audit down"))
        try:
            okr2, msg2, gen2 = bot.wloc_switch_gen("上海")
        finally:
            bot._pdgtx = real_pdgtx
        w2 = json.load(open(bot.MITM_CONFIG))["wloc"]
        if okr2 and w2["active"] == "上海" and gen2 == 5:
            ok("审计写入失败时: 切换照样成功落盘并如实回报(坐标已生效, 不能谎报失败)")
        else:
            bad(f"审计故障影响了切换本身: ok={okr2} active={w2.get('active')} gen={gen2}")

    # ══ 2. WLOC 未开启时切地点: 只存配置, 不碰任何服务 ══════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=False)
        okr, msg, gen = bot.wloc_switch_gen("上海")
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or w["active"] != "上海" or w["generation"] != 4:
            bad(f"未开启时切换没存对: {okr} {w}")
        if SPY.transact or SPY.ca or SPY.sh:
            bad(f"未开启却动了东西: transact={SPY.transact} ca={SPY.ca} sh={SPY.sh}")
        if w["enabled"] is not False:
            bad("未开启的状态被改掉了")
        ok("未开启时切地点: 只存 active+generation, 不启动/重启任何服务")
        if "开启" not in msg:
            bad(f"没提示需要开启 WLOC 才生效: {msg}")
        ok("提示该地点已选中但需要开启 WLOC 才生效")

    # ══ 3. 开启 / 关闭仍走完整事务 ═════════════════════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=False)
        okr, msg = bot.wloc_enable(True)
        if not okr:
            bad(f"开启失败: {msg}")
        if not SPY.transact:
            bad("开启 WLOC 没走完整事务(热路径不该处理接管域名变化)")
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if w.get("enabled") is not True:
            bad(f"开启没落盘: {w}")
        # CA 预热 / hijack / 内核渲染 / 服务动作发生在完整事务内部, 由
        # test-mitm-wloc-txn.py 在真沙箱里逐项验(那里连顺序都断言); 这里只认路径选择。
        ok("开启 WLOC: 走完整事务(候选/CA/服务动作由 test-mitm-wloc-txn.py 覆盖)")

        SPY.__init__()
        okr, msg = bot.wloc_enable(False)
        if not okr:
            bad(f"关闭失败: {msg}")
        if not SPY.transact:
            bad(f"关闭 WLOC 没走完整事务: transact={SPY.transact}")
        if json.load(open(bot.MITM_CONFIG))["wloc"].get("enabled") is not False:
            bad("关闭没落盘")
        ok("关闭 WLOC: 走完整事务(撤接管域名与停 pdg-mitm 由事务用例覆盖)")

    # ══ 4. 删除地点的三条路径 ══════════════════════════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        okr, msg = bot.wloc_del("上海")                 # 删的不是 active
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or [l["name"] for l in w["locations"]] != ["东京", "大阪"]:
            bad(f"删非 active 没删对: {okr} {w}")
        if w["active"] != "东京" or w["generation"] != 3:
            bad(f"删非 active 不该动 active/generation: {w}")
        if SPY.transact or SPY.ca or SPY.sh:
            bad(f"删非 active 却动了服务: transact={SPY.transact} sh={SPY.sh}")
        ok("删除非当前目标: 只更新地点列表, 不动服务、不改 generation")

        SPY.__init__()
        okr, msg = bot.wloc_del("东京")                 # 删 active, 还剩大阪
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or w["active"] != "大阪" or w["generation"] != 4:
            bad(f"删 active 没切到剩余地点/没 +1: {w}")
        if SPY.transact or SPY.ca or SPY.sh:
            bad(f"删 active 走了完整事务: transact={SPY.transact} sh={SPY.sh}")
        if "大阪" not in msg:
            bad(f"没告诉用户切到了哪个地点: {msg}")
        ok("删除当前目标(还有别的): 切到剩余地点并走热切换, 仍不重启服务")

        SPY.__init__()
        okr, msg = bot.wloc_del("大阪")                 # 删最后一个 → 必须关掉 WLOC
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or w["locations"] or w["enabled"] is not False:
            bad(f"删最后一个地点没关掉 WLOC: {okr} {w}")
        if not SPY.transact:
            bad(f"删最后一个地点没走完整关闭事务: transact={SPY.transact}")
        ok("删除最后一个地点: 走完整关闭事务(撤接管域名由事务用例覆盖)")

    # ══ 4b. 加/改地点的三种语义 ════════════════════════════════════════════
    # 以前含糊: 改当前地点会被 pdg-mitm 立刻热加载, 但 generation 不变, bot 还让用户"到列表
    # 点它" —— 点了不产生任何新效果, 用户以为没生效。
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        okr, msg, gen = bot.wloc_add_gen("京都", 35.0116, 135.7681)   # 新增的不是当前目标
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or gen != 0 or w["active"] != "东京" or w["generation"] != 3:
            bad(f"新增非当前地点不该切换/不该动 generation: gen={gen} {w}")
        if "京都" not in [l["name"] for l in w["locations"]]:
            bad("新增的地点没存进去")
        ok("新增非当前地点: 只保存, 不切换、不动 generation")

        SPY.__init__()
        okr, msg, gen = bot.wloc_add_gen("东京", 35.9, 139.9)          # 改的就是当前目标
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or gen != 4 or w["generation"] != 4:
            bad(f"改当前地点没当成一次热切换: gen={gen} {w}")
        cur = [l for l in w["locations"] if l["name"] == "东京"][0]
        if cur["lat"] != 35.9 or cur["lon"] != 139.9:
            bad(f"新坐标没存进去: {cur}")
        if SPY.transact or SPY.ca or SPY.sh:
            bad(f"改当前地点却动了服务: transact={SPY.transact} sh={SPY.sh}")
        if "已更新" not in msg or "网关服务无需重启" not in msg:
            bad(f"没提示当前目标坐标已更新且无需重启网关服务: {msg}")
        if "地点/切换" in msg or "再点" in msg:
            bad(f"仍在让用户去列表重复点击: {msg}")
        ok("修改当前地点(WLOC 已开启): 视为热切换, generation +1, 不再让用户重复点击")

        SPY.__init__()
        seed(enabled=False)
        okr, msg, gen = bot.wloc_add_gen("东京", 36.1, 140.1)
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if not okr or gen != 0 or w["generation"] != 3:
            bad(f"未开启时改当前地点不该 +generation: gen={gen} {w}")
        if [l for l in w["locations"] if l["name"] == "东京"][0]["lat"] != 36.1:
            bad("未开启时新坐标没存下来")
        if "开启" not in msg:
            bad(f"未开启时没提示开启后才生效: {msg}")
        if SPY.transact or SPY.sh:
            bad(f"未开启却动了服务: transact={SPY.transact} sh={SPY.sh}")
        ok("修改当前地点(WLOC 未开启): 只保存, 提示开启后才生效")

    # ══ 5. 并发切换: mitm.json 任何时刻都是完整 JSON ════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        stop = threading.Event()
        broken = []

        def reader():
            while not stop.is_set():
                try:
                    with open(bot.MITM_CONFIG, encoding="utf-8") as f:
                        d = json.load(f)
                    if "wloc" not in d or "active" not in d["wloc"]:
                        broken.append("字段缺失")
                except FileNotFoundError:
                    pass                                 # 替换瞬间不存在是可以的
                except ValueError as e:
                    broken.append("半个 JSON: %s" % e)

        th = threading.Thread(target=reader, daemon=True); th.start()
        for i in range(60):
            bot.wloc_switch_gen("大阪" if i % 2 else "东京")
        stop.set(); th.join(5)
        if broken:
            bad(f"并发下读到过不完整配置: {broken[:2]}")
        w = json.load(open(bot.MITM_CONFIG))["wloc"]
        if w["generation"] != 3 + 60:
            bad(f"60 次切换后 generation 不对: {w['generation']}")
        ok("60 次连续切换: 配置始终是完整 JSON, generation 一次不落")

    # ══ 6. 切换后的反馈: 等一次真实命中 ════════════════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        edits = []
        # 监听走的是 edit_only(只编辑、不补发), 桩要打在它上面
        bot.edit_only = lambda chat, mid, text, kb=None: (edits.append((chat, mid, text)), True)[1]

        # (a) 对上 generation 且 patched → 报"已收到 iPhone 的新定位请求"
        since = time.time()
        okr, msg, gen = bot.wloc_switch_gen("大阪")
        write_status(bot.WLOC_STATUS_FILE, gen, "大阪")
        fut = bot._wloc_watch_async(1, 11, gen, "大阪", timeout=5, interval=0.05, since=since)
        fut.result(10)
        if not edits or "已收到 iPhone 的新定位请求" not in edits[-1][2]:
            bad(f"命中后没更新成功消息: {edits}")
        if "大阪" not in edits[-1][2]:
            bad(f"成功消息没写明改写到哪个目标: {edits[-1][2]}")
        if "位置已成功变化" in edits[-1][2] or "手机位置已" in edits[-1][2]:
            bad(f"把改写响应说成了手机位置已变化: {edits[-1][2]}")
        ok("命中对应 generation → 更新为「已收到新定位请求 + 已改写为 X」")

        # (b) 超时: 如实说没收到, 并给出排查项(含 iOS 26 可能要重启)
        edits.clear()
        since = time.time()
        okr, msg, gen = bot.wloc_switch_gen("东京")
        fut = bot._wloc_watch_async(1, 12, gen, "东京", timeout=0.6, interval=0.05, since=since)
        fut.result(10)
        if not edits or "尚未收到" not in edits[-1][2]:
            bad(f"超时没提示未收到请求: {edits}")
        for kw in ("内网卡", "Wi-Fi", "CA", "iOS 26"):
            if kw not in edits[-1][2]:
                bad(f"超时提示缺少排查项「{kw}」: {edits[-1][2]}")
        ok("30 秒(用例里 0.6 秒)没等到 → 如实提示未收到, 并给出排查项")

        # (c) 上游失败 / 没改写: 报真实原因, 不冒充成功
        edits.clear()
        since = time.time()
        okr, msg, gen = bot.wloc_switch_gen("大阪")
        write_status(bot.WLOC_STATUS_FILE, gen, "大阪", upstream_ok=False, patched=False,
                     error_type="ForwardFailed")
        bot._wloc_watch_async(1, 13, gen, "大阪", timeout=5, interval=0.05, since=since).result(10)
        if "ForwardFailed" not in edits[-1][2] or "已收到 iPhone 的新定位请求" in edits[-1][2]:
            bad(f"上游失败没如实报: {edits[-1][2]}")
        ok("上游失败 → 报真实原因(不报成功)")

        edits.clear()
        since = time.time()
        okr, msg, gen = bot.wloc_switch_gen("东京")
        write_status(bot.WLOC_STATUS_FILE, gen, "东京", upstream_ok=True, patched=False,
                     error_type="NoCoordsInResponse")
        bot._wloc_watch_async(1, 14, gen, "东京", timeout=5, interval=0.05, since=since).result(10)
        if "没有可改写的坐标" not in edits[-1][2]:
            bad(f"未改写没如实报: {edits[-1][2]}")
        ok("拿到响应但没改写成 → 如实说明, 不算成功")

        # (d) 等待期间又切了新地点: 旧任务不得覆盖新消息
        edits.clear()
        _, _, gen_old = bot.wloc_switch_gen("大阪")
        fut_old = bot._wloc_watch_async(1, 15, gen_old, "大阪", timeout=3, interval=0.05)
        time.sleep(0.1)
        _, _, gen_new = bot.wloc_switch_gen("东京")
        fut_new = bot._wloc_watch_async(1, 16, gen_new, "东京", timeout=3, interval=0.05)
        write_status(bot.WLOC_STATUS_FILE, gen_old, "大阪")     # 旧那一代的命中晚到了
        fut_old.result(10)
        if any("大阪" in e[2] for e in edits):
            bad(f"旧 generation 覆盖了新切换的消息: {edits}")
        ok("等待期间又切了地点 → 旧 generation 的任务闭嘴退出, 不覆盖新消息")
        write_status(bot.WLOC_STATUS_FILE, gen_new, "东京")
        fut_new.result(10)
        if not edits or "东京" not in edits[-1][2]:
            bad(f"新 generation 的命中没更新: {edits}")
        ok("新 generation 的命中正常更新")

        # (e) 后台等待不阻塞主循环: 提交后立刻返回
        edits.clear()
        _, _, gen = bot.wloc_switch_gen("大阪")
        t0 = time.monotonic()
        fut = bot._wloc_watch_async(1, 17, gen, "大阪", timeout=3, interval=0.05)
        submit_cost = time.monotonic() - t0
        if submit_cost > 0.2:
            bad(f"提交后台任务耗时 {submit_cost:.3f}s, 会拖住 getUpdates 主循环")
        ok(f"后台等待提交耗时 {submit_cost * 1000:.1f} ms —— 主轮询不等它")
        write_status(bot.WLOC_STATUS_FILE, gen, "大阪")
        fut.result(10)

    # ══ 6b. 监听绝不覆盖用户当前正看的界面 ═════════════════════════════════
    # 切完地点用户往往立刻点「返回 WLOC / 主菜单」。监听还在等的话, 30 秒后它会把那条消息
    # 原地改成"尚未收到请求" —— 用户正看的菜单没了。监听绑 (chat, message_id, token),
    # 对同一条消息的任何新回调都让旧监听立即失效。
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        edits = []
        # 监听走的是 edit_only(只编辑、不补发), 桩要打在它上面
        bot.edit_only = lambda chat, mid, text, kb=None: (edits.append((chat, mid, text)), True)[1]
        since = time.time()
        _, _, gen = bot.wloc_switch_gen("大阪")
        fut = bot._wloc_watch_async(7, 70, gen, "大阪", timeout=3, interval=0.05, since=since)
        edits.append((7, 70, "MENU"))                  # 用户点了「返回 WLOC」, 这条消息被改成菜单
        bot.wloc_invalidate_watch(7, 70)               # handle_cb 进来就会做这件事
        write_status(bot.WLOC_STATUS_FILE, gen, "大阪")
        fut.result(10)
        if [e[2] for e in edits] != ["MENU"]:
            bad(f"监听把菜单覆盖了(编辑顺序: {[e[2][:12] for e in edits]})")
        ok("返回菜单后命中晚到 → 监听已失效, 不覆盖菜单")

        edits.clear()
        since = time.time()
        _, _, gen = bot.wloc_switch_gen("东京")
        fut = bot._wloc_watch_async(7, 71, gen, "东京", timeout=0.5, interval=0.05, since=since)
        edits.append((7, 71, "MENU"))
        bot.wloc_invalidate_watch(7, 71)
        fut.result(10)
        if [e[2] for e in edits] != ["MENU"]:
            bad(f"超时提示覆盖了菜单: {[e[2][:12] for e in edits]}")
        ok("返回菜单后监听超时 → 同样不覆盖菜单")

        # 失效之后再切一次, 新监听要照常工作
        edits.clear()
        since = time.time()
        _, _, gen = bot.wloc_switch_gen("大阪")
        fut = bot._wloc_watch_async(7, 72, gen, "大阪", timeout=3, interval=0.05, since=since)
        write_status(bot.WLOC_STATUS_FILE, gen, "大阪")
        fut.result(10)
        if not edits or "已收到" not in edits[-1][2]:
            bad(f"新监听没工作: {edits}")
        ok("旧监听失效后, 新的切换仍能正常启动监听并回报命中")

        # 历史状态(本次切换之前就存在)不算命中 —— /run 没清干净时不该冒充刚刚的请求
        edits.clear()
        _, _, gen = bot.wloc_switch_gen("东京")
        stale = {"generation": gen, "target_name": "东京", "received_at": time.time() - 600,
                 "upstream_ok": True, "patched": True, "error_type": "", "pid": 1}
        with open(bot.WLOC_STATUS_FILE, "w", encoding="utf-8") as f:
            json.dump(stale, f, ensure_ascii=False)
        bot._wloc_watch_async(7, 73, gen, "东京", timeout=0.5, interval=0.05,
                              since=time.time()).result(10)
        if not edits or "尚未收到" not in edits[-1][2]:
            bad(f"历史状态被当成了本次命中: {edits}")
        ok("历史状态(received_at 早于本次切换)不算命中")

        # 目标名对不上也不算命中(generation 恰好撞上的情况)
        edits.clear()
        since = time.time()
        _, _, gen = bot.wloc_switch_gen("大阪")
        write_status(bot.WLOC_STATUS_FILE, gen, "别的地方")
        bot._wloc_watch_async(7, 74, gen, "大阪", timeout=0.5, interval=0.05,
                              since=since).result(10)
        if not edits or "尚未收到" not in edits[-1][2]:
            bad(f"目标名对不上却算成了命中: {edits}")
        ok("目标名对不上不算命中")

        # 状态字段类型异常: 监听不许直接崩(崩了连超时提示都没有)
        edits.clear()
        since = time.time()
        _, _, gen = bot.wloc_switch_gen("东京")
        with open(bot.WLOC_STATUS_FILE, "w", encoding="utf-8") as f:
            json.dump({"generation": "不是数字", "target_name": None,
                       "received_at": "刚刚", "patched": "yes"}, f, ensure_ascii=False)
        bot._wloc_watch_async(7, 75, gen, "东京", timeout=0.5, interval=0.05,
                              since=since).result(10)
        if not edits or "尚未收到" not in edits[-1][2]:
            bad(f"状态字段异常时监听没能正常收尾: {edits}")
        ok("状态字段类型异常 → 当作没命中, 监听不崩、超时提示照常")

    # ══ 6e. 原消息被删掉: 监听只编辑, 绝不补发新消息 ═══════════════════════
    # 用户切完随手把那条消息删了。普通 edit() 编辑失败会退化成 send() —— 刚清掉的东西 30 秒
    # 后又冒出来一条。监听走 edit_only: 编辑不成就安静结束。
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        calls = []
        real_post = bot.post

        def fake_post(method, params):
            calls.append(method)
            if method == "editMessageText":       # 真实形态: 消息已删 → 400 message to edit not found
                return {"ok": False, "error_code": 400,
                        "description": "Bad Request: message to edit not found"}
            return {"ok": True, "result": {"message_id": 999}}

        bot.post = fake_post
        bot.edit_only = real_edit_only            # 用真的 edit_only(这正是被测对象)
        try:
            # (a) 命中后编辑: 消息已删 → 不得发新消息
            since = time.time()
            _, _, gen = bot.wloc_switch_gen("大阪")
            write_status(bot.WLOC_STATUS_FILE, gen, "大阪")
            bot._wloc_watch_async(8, 80, gen, "大阪", timeout=3, interval=0.05,
                                  since=since).result(10)
            if "sendMessage" in calls:
                bad(f"原消息被删后监听补发了新消息: {calls}")
            if calls.count("editMessageText") < 1:
                bad(f"监听没尝试编辑: {calls}")
            ok("命中回报时原消息已删 → 只尝试编辑, 不补发新消息")

            # (b) 超时提示同样不补发
            calls.clear()
            since = time.time()
            _, _, gen = bot.wloc_switch_gen("东京")
            bot._wloc_watch_async(8, 81, gen, "东京", timeout=0.4, interval=0.05,
                                  since=since).result(10)
            if "sendMessage" in calls:
                bad(f"超时提示在原消息已删时补发了新消息: {calls}")
            ok("超时提示时原消息已删 → 同样不补发新消息")

            # (c) 编辑失败不该反复骚扰: 一次回报最多两次编辑尝试(HTML + 纯文本回退)
            if calls.count("editMessageText") > 2:
                bad(f"编辑失败后反复重试/通知: {calls}")
            ok("编辑失败只试到纯文本回退为止, 不反复通知用户")
        finally:
            bot.post = real_post

    # ══ 6c. 配置锁: 持锁期间任何 WLOC 写入都必须被拒 ═══════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        before = open(bot.MITM_CONFIG, encoding="utf-8").read()
        with bot._cfg_guard() as got:                  # 模拟"另一个操作正持锁"
            if not got:
                bad("测试自己都没拿到锁")
            okr, msg, gen = bot.wloc_add_gen("京都", 35.0116, 135.7681)
            if okr or msg != bot.BUSY_MSG:
                bad(f"持锁时 wloc_add 竟然成功了: {okr} {msg}")
            okr2, msg2, _ = bot.wloc_switch_gen("大阪")
            okr3, msg3 = bot.wloc_del("上海")
            if okr2 or msg2 != bot.BUSY_MSG or okr3 or msg3 != bot.BUSY_MSG:
                bad(f"持锁时 switch/del 没被拒: {okr2} {msg2} | {okr3} {msg3}")
        if open(bot.MITM_CONFIG, encoding="utf-8").read() != before:
            bad("持锁期间配置被写了")
        ok("持锁期间 add / switch / del 一律返回 BUSY 且一个字节都没写")

    # ══ 6d. 并发增删切换: 不丢地点、不出悬空 active、不动其它配置字段 ═══════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        cfg = json.load(open(bot.MITM_CONFIG))
        cfg["other_plugin"] = {"keep": "me"}           # 无关字段, 全程不许被动
        with open(bot.MITM_CONFIG, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False)
        errs = []

        def worker(i):
            try:
                for k in range(12):
                    bot.wloc_add_gen("城市%d" % i, 30.0 + i, 120.0 + k)
                    bot.wloc_switch_gen("东京" if k % 2 else "大阪")
                    bot.wloc_del("城市%d" % i)
            except Exception as e:  # noqa: BLE001
                errs.append("%s: %s" % (type(e).__name__, e))

        ths = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
        for t in ths:
            t.start()
        for t in ths:
            t.join(60)
        if errs:
            bad(f"并发增删切换出错: {errs[:2]}")
        final = json.load(open(bot.MITM_CONFIG))
        w = final["wloc"]
        names = [l["name"] for l in w["locations"]]
        for seeded in ("东京", "大阪", "上海"):
            if seeded not in names:
                bad(f"并发过程中把原有地点弄丢了: {names}")
        if len(names) != len(set(names)):
            bad(f"出现重复地点: {names}")
        if w["active"] not in names:
            bad(f"active 悬空(指向不存在的地点): active={w['active']} names={names}")
        if final.get("other_plugin") != {"keep": "me"}:
            bad(f"其它配置字段被覆盖了: {final.get('other_plugin')}")
        ok(f"4 线程并发增删切换 144 次: 地点不丢不重、active 不悬空、无关字段完好")

    # ══ 7. Android: 看不到也调不动 ═════════════════════════════════════════
    with tempfile.TemporaryDirectory() as tmp:
        setup(tmp); seed(enabled=True)
        bot._platform = lambda: "android"
        okr, msg, gen = bot.wloc_switch_gen("大阪")
        if okr or "iOS" not in msg:
            bad(f"Android 上竟然能切地点: {okr} {msg}")
        okr, msg = bot.wloc_del("大阪")
        if okr:
            bad("Android 上竟然能删地点")
        if bot._mitm_enabled_domains() or bot._mitm_domains():
            bad("Android 上仍推导出了接管域名")
        if SPY.transact or SPY.sh:
            bad(f"Android 上动了服务: transact={SPY.transact} sh={SPY.sh}")
        ok("Android: WLOC 切换/删除一律拒绝, 也推不出接管域名")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

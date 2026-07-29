#!/usr/bin/env python3
"""统一配置事务核心(5.1)回归: 状态机 / 白名单 / 前置检查 / 原子落盘 / 观察 / 回滚 / 审计。

全部是**行为测试**: 在沙箱文件树(PDG_TX_FSROOT)里真跑一遍事务, 用假的 systemctl / nft /
mihomo 充当"外部世界"(桩会把每次调用记进日志, 也能按需装成失败), 断言的是磁盘与状态的真实
结果, 不是源码里有没有某个字符串。
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
pass_n = 0
fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   %s" % m); pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] %s" % m); fail_n += 1


from txbox import Box, load_tx  # noqa: E402


MODEL = json.dumps({"outbounds": [{"type": "direct", "tag": "direct"}],
                    "route": {"rules": []}, "inbounds": []}).encode()


def main():
    # ── 1. 状态机(用一次性沙箱: 这里会故意把事务停在 APPLYING, 那是"待恢复"状态,
    #        它本身就应该挡住后续事务 —— 见第 13 段) ──
    box0 = Box(); tx = load_tx(box0.env)
    assert tx.PREPARING in tx._ALLOWED
    t = tx.Tx("test", "op1")
    t2 = tx.Tx("test", "op2")
    if t.txid == t2.txid:
        bad("两笔事务拿到同一个 txid")
    else:
        ok("transaction ID 唯一(同秒内也不同)")
    try:
        t._set_state(tx.COMMITTED)          # PREPARING → COMMITTED 非法
        bad("非法状态跳转没有被拒绝")
    except tx.TxError:
        ok("非法状态跳转(PREPARING→COMMITTED)被拒绝")
    t._set_state(tx.VALIDATED); t._set_state(tx.APPLYING)
    try:
        t._set_state(tx.ABORTED)            # APPLYING 不能直接 ABORTED(现网已被动过)
        bad("APPLYING→ABORTED 竟被允许")
    except tx.TxError:
        ok("APPLYING 不允许跳到 ABORTED(那会掩盖已改动的现网)")
    for st in (tx.APPLYING, tx.ROLLING_BACK, tx.ROLLBACK_FAILED):
        if st not in tx.NEEDS_RECOVERY:
            bad("%s 不在需要恢复的状态集合里" % st)
    ok("APPLYING / ROLLING_BACK / ROLLBACK_FAILED 都被认定为需要恢复")

    # ── 1b. 停在 APPLYING 的事务会挡住下一笔写 ──
    box0.put("/etc/sing-box/config.json", MODEL)
    box0.up("mihomo")
    t3 = tx.Tx("test", "blocked-by-pending")
    t3.stage("model", MODEL)
    try:
        t3.commit(); bad("上一笔停在 APPLYING, 新事务竟然照跑")
    except tx.TxRefused as e:
        if "recover" in str(e):
            ok("上一笔停在 APPLYING → 新的写事务被拒绝, 并指向 tx recover")
        else:
            bad("拒绝原因不对: %s" % e)
    box0.clean()

    # ── 2. 目标白名单 ──
    box = Box(); tx = load_tx(box.env)
    for bad_name in ("../../etc/shadow", "/etc/passwd", "model2", "mosdns_rule:../x.txt",
                     "mosdns_rule:x.yaml", "ruleset:../../a.json", "unit:evil.sh"):
        try:
            tx.resolve_target(bad_name)
            bad("白名单没挡住: %s" % bad_name)
        except tx.TxError:
            pass
    ok("白名单挡掉越界目标(绝对路径 / ../ / 非法后缀 / 未知名字)")
    p, mode, secret, val = tx.resolve_target("model")
    if p == box.path("/etc/sing-box/config.json") and secret and mode == 0o600:
        ok("合法目标解析出沙箱内的绝对路径 + 0600 + 标记含凭据")
    else:
        bad("model 解析结果不对: %s %s %s" % (p, oct(mode), secret))

    # ── 3. 候选校验失败 → 现网零改动 + ABORTED ──
    box.put("/etc/sing-box/config.json", MODEL)
    box.up("mihomo")
    before = box.read("/etc/sing-box/config.json")
    t = tx.Tx("test", "bad-model")
    t.stage("model", b"{not json")
    try:
        t.commit(); bad("坏候选竟然提交成功")
    except tx.TxRefused as e:
        if box.read("/etc/sing-box/config.json") == before and t.state == tx.ABORTED:
            ok("候选校验失败 → 现网零改动 + 状态 ABORTED")
        else:
            bad("校验失败后现网被改了或状态不对: %s" % t.state)

    # ── 4. 正常提交: 原子落盘 + 服务动作 + 观察 + 材料清理 ──
    newmodel = json.dumps({"outbounds": [{"type": "direct", "tag": "direct"}],
                           "route": {"rules": [{"domain_suffix": ["a.com"], "outbound": "direct"}]},
                           "inbounds": []}).encode()
    t = tx.Tx("test", "add-rule")
    t.stage("model", newmodel)
    t.stage("mosdns_rule:custom_hijack.txt", b"domain:a.com\n")
    t.service("restart:mihomo"); t.service("restart:mosdns")
    box.up("mosdns")
    res = t.commit()
    if res["state"] == tx.COMMITTED and box.read("/etc/sing-box/config.json") == newmodel \
            and box.read("/etc/mosdns/rules/custom_hijack.txt") == b"domain:a.com\n":
        ok("正常提交: 两个目标都落盘, 状态 COMMITTED")
    else:
        bad("提交结果不对: %s / %s" % (res["state"], res.get("error")))
    calls = open(box.calls).read()
    if "systemctl restart mihomo" in calls and "systemctl restart mosdns" in calls:
        ok("声明的服务动作真的执行了(两个 restart 都在调用日志里)")
    else:
        bad("服务动作没执行: %s" % calls[-200:])
    txd = os.path.join(box.env["PDG_TX_ROOT"], res["txid"])
    if not os.path.exists(os.path.join(txd, "candidate")) and \
            not os.path.exists(os.path.join(txd, "before")):
        ok("COMMITTED 后候选与 before 材料已删除(不把凭据留在盘上)")
    else:
        bad("提交后仍留着候选/before 材料")
    if os.path.exists(os.path.join(txd, "meta.json")) and os.path.exists(os.path.join(txd, "diff.txt")):
        ok("脱敏 meta.json 与 diff.txt 保留下来供审计")
    else:
        bad("meta/diff 没留下")

    # ── 5. 前置检查: 准备期间被别人改过 → 拒绝覆盖 ──
    t = tx.Tx("test", "stale")
    t.stage("model", MODEL)
    box.put("/etc/sing-box/config.json", json.dumps({"outbounds": [], "route": {}}).encode())
    try:
        t.commit(); bad("目标被改过仍然覆盖了")
    except tx.TxRefused:
        ok("目标在准备期间被改过 → 拒绝覆盖(expect_sha256 前置检查)")

    # ── 6. 观察期: 服务起来即崩 → 回滚 ──
    box2 = Box(restart_crash=True); tx2 = load_tx(box2.env)
    box2.put("/etc/sing-box/config.json", MODEL)
    box2.up("mihomo")
    crashy = json.dumps({"outbounds": [{"type": "direct", "tag": "CRASHME"}],
                         "route": {"rules": []}, "inbounds": []}).encode()
    t = tx2.Tx("test", "crashy")
    t.stage("model", crashy); t.service("restart:mihomo")
    res = t.commit()
    if res["state"] == tx2.ROLLED_BACK and box2.read("/etc/sing-box/config.json") == MODEL:
        ok("观察期 NRestarts 上涨(起来即崩)→ 回滚且内容逐字节还原")
    else:
        bad("崩溃循环没被判失败: %s" % res)
    if res.get("rollback_complete"):
        ok("回滚被验证为完整")
    else:
        bad("回滚完整性没被确认")
    box2.clean()

    # ── 7. 服务 restart 失败 → 回滚 ──
    box3 = Box(svc_fail=["mosdns"]); tx3 = load_tx(box3.env)
    box3.put("/etc/mosdns/rules/custom_direct.txt", b"domain:old.com\n", 0o644)
    box3.up("mosdns")
    t = tx3.Tx("test", "mosdns-fail")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:new.com\n")
    t.service("restart:mosdns")
    res = t.commit()
    # 桩里的 mosdns 永远起不来 → 文件能回滚, 但运行时确实没恢复: 诚实结论是 ROLLBACK_FAILED
    if res["state"] == tx3.ROLLBACK_FAILED and box3.read("/etc/mosdns/rules/custom_direct.txt") == b"domain:old.com\n":
        ok("服务重启失败 → 文件回滚到操作前内容")
    else:
        bad("重启失败没回滚: %s / %r" % (res["state"], box3.read("/etc/mosdns/rules/custom_direct.txt")))
    if any("mosdns" in x for x in res["rollback_failed_items"]):
        ok("运行时没恢复被如实点名(不再假装 ROLLED_BACK)")
    else:
        bad("没点名未恢复的运行时项: %s" % res["rollback_failed_items"])
    box3.clean()

    # ── 8. 新建文件的回滚 = 删除 ──
    box4 = Box(svc_fail=["mosdns"]); tx4 = load_tx(box4.env)
    box4.up("mosdns")
    t = tx4.Tx("test", "create-then-fail")
    t.stage("mosdns_rule:brand_new.txt", b"domain:x.com\n")
    t.service("restart:mosdns")
    res = t.commit()
    if res["state"] in (tx4.ROLLED_BACK, tx4.ROLLBACK_FAILED) \
            and box4.read("/etc/mosdns/rules/brand_new.txt") is None:
        ok("原本不存在的目标: 回滚 = 删掉本次新建的文件(absent 标记生效)")
    else:
        bad("新建文件没被回滚删除")
    box4.clean()

    # ── 9. 基线门: 相关组件操作前就坏 → 普通事务拒绝开始; repair 模式放行 ──
    box5 = Box(healthy=False); tx5 = load_tx(box5.env)
    box5.put("/etc/sing-box/config.json", MODEL)          # mihomo 故意不 up, 探针也不起
    t = tx5.Tx("test", "normal-on-broken")
    t.stage("model", newmodel)
    try:
        t.commit(); bad("组件已坏仍允许普通变更")
    except tx5.TxRefused as e:
        ok("操作前硬门已坏 → 普通事务拒绝开始(%s)" % str(e)[:40])
    t = tx5.Tx("test", "repair-on-broken", mode="repair")
    t.stage("model", newmodel); t.service("restart:mihomo")
    res = t.commit()
    if res["state"] == tx5.COMMITTED:
        ok("修复模式允许在降级基线上运行")
    else:
        bad("修复模式被挡住了: %s" % res)
    box5.clean()

    # ── 10. 锁: 被别人占着 → TxBusy(不阻塞) ──
    import fcntl
    lf = open(box.env["PDG_LOCKFILE"], "w")
    fcntl.flock(lf, fcntl.LOCK_EX)
    t = tx.Tx("test", "busy"); t.stage("mosdns_rule:custom_direct.txt", b"domain:z.com\n")
    t0 = time.time()
    try:
        t.commit(); bad("锁被占着还是提交了")
    except tx.TxBusy:
        ok("锁被占用 → 立刻 TxBusy(耗时 %.1fs, 没有排队)" % (time.time() - t0))
    fcntl.flock(lf, fcntl.LOCK_UN); lf.close()

    # ── 11. 审计 ──
    audit = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    lines = [json.loads(x) for x in open(audit, encoding="utf-8")]
    if lines and all("txid" in r and "state" in r and "op" in r for r in lines):
        ok("审计记录逐笔落盘(txid/state/op 齐全, 共 %d 条)" % len(lines))
    else:
        bad("审计记录不完整")
    if any(r["state"] == "ABORTED" for r in lines) and any(r["state"] == "COMMITTED" for r in lines):
        ok("审计里 ABORTED 与 COMMITTED 都被如实记录")
    else:
        bad("审计状态记录不全: %s" % {r["state"] for r in lines})

    # ── 12. runner / schema 固定 ──
    t = tx.Tx("test", "runner")
    m = json.load(open(os.path.join(box.env["PDG_TX_ROOT"], t.txid, "meta.json")))
    if m.get("runner_sha256") and m.get("schema_version") == tx.SCHEMA_VERSION:
        ok("每笔事务记录 runner_sha256 与 schema_version")
    else:
        bad("缺 runner/schema 记录")
    m["runner_sha256"] = "0" * 64
    tx.atomic_write(os.path.join(box.env["PDG_TX_ROOT"], t.txid, "meta.json"),
                    json.dumps(m).encode(), 0o600)
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "apply", "--tx", t.txid],
                       capture_output=True, text=True, env=dict(os.environ, **box.env))
    if r.returncode == 3 and "runner" in (r.stderr or ""):
        ok("runner 版本与事务不符 → apply 拒绝执行(退出码 3)")
    else:
        bad("runner 漂移没被拒绝: rc=%s %s" % (r.returncode, r.stderr[:120]))

    # ── 13. DoT 证书部署: 三个目标一起提交; 任一步失败继续用旧证书 ──
    box6 = Box(); tx6 = load_tx(box6.env)
    box6.up("mosdns")
    old_chain = b"-----BEGIN CERTIFICATE-----\nOLD\n-----END CERTIFICATE-----\n"
    old_key = b"-----BEGIN PRIVATE KEY-----\nOLD\n-----END PRIVATE KEY-----\n"
    box6.put("/etc/mosdns/certs/fullchain.pem", old_chain, 0o644)
    box6.put("/etc/mosdns/certs/privkey.pem", old_key, 0o600)
    box6.put("/opt/pdg-bot/dot-domain", b"old.example.com\n", 0o644)
    new_chain = b"-----BEGIN CERTIFICATE-----\nNEW\n-----END CERTIFICATE-----\n"
    new_key = b"-----BEGIN PRIVATE KEY-----\nNEW\n-----END PRIVATE KEY-----\n"
    t = tx6.Tx("bot", "dot_cert_deploy")
    t.stage("cert_fullchain", new_chain)
    t.stage("cert_privkey", new_key)
    t.stage("dot_marker", b"new.example.com\n")
    t.service("restart:mosdns")
    res = t.commit()
    if res["state"] == tx6.COMMITTED and box6.read("/etc/mosdns/certs/privkey.pem") == new_key \
            and box6.read("/opt/pdg-bot/dot-domain") == b"new.example.com\n":
        ok("证书部署: 证书 + 私钥 + 活动域名标记一笔事务提交")
    else:
        bad("证书部署失败: %s" % res)
    st = os.stat(box6.path("/etc/mosdns/certs/privkey.pem"))
    if st.st_mode & 0o777 == 0o600:
        ok("私钥保持 0600(权限随 before-image 还原, 不被候选带偏)")
    else:
        bad("私钥权限变成 %o" % (st.st_mode & 0o777))
    # mosdns 起不来 → 全部回到旧证书
    box7 = Box(svc_fail=["mosdns"]); tx7 = load_tx(box7.env)
    box7.up("mosdns")
    box7.put("/etc/mosdns/certs/fullchain.pem", old_chain, 0o644)
    box7.put("/etc/mosdns/certs/privkey.pem", old_key, 0o600)
    box7.put("/opt/pdg-bot/dot-domain", b"old.example.com\n", 0o644)
    t = tx7.Tx("bot", "dot_cert_deploy")
    t.stage("cert_fullchain", new_chain); t.stage("cert_privkey", new_key)
    t.stage("dot_marker", b"new.example.com\n"); t.service("restart:mosdns")
    res = t.commit()
    if res["state"] in (tx7.ROLLED_BACK, tx7.ROLLBACK_FAILED) \
            and box7.read("/etc/mosdns/certs/fullchain.pem") == old_chain \
            and box7.read("/etc/mosdns/certs/privkey.pem") == old_key \
            and box7.read("/opt/pdg-bot/dot-domain") == b"old.example.com\n":
        ok("部署后 mosdns 起不来 → 证书/私钥/域名标记全部回到旧的(DoT 继续可用)")
    else:
        bad("证书回滚不完整: %s" % res)
    box6.clean(); box7.clean()

    # ── 14. 规则集刷新的"部分来源成功"语义(5.1 定死)──
    import importlib.util as _il
    box8 = Box(); tx8 = load_tx(box8.env)
    box8.up("mihomo"); box8.up("mosdns")
    spec = _il.spec_from_file_location("pdg_bot_rs", ROOT / "deploy/bot/pdg-bot.py")
    b = _il.module_from_spec(spec); spec.loader.exec_module(b)
    b.RS_DIR = box8.path("/etc/sing-box/rs")
    b.RS_META = box8.path("/opt/pdg-bot/rulesets.json")
    b.SB = box8.path("/etc/sing-box/config.json")
    b.MIHOMO_CFG = box8.path("/etc/mihomo/config.yaml")
    b.LOCKFILE = box8.env["PDG_LOCKFILE"]
    os.makedirs(b.RS_DIR, exist_ok=True)
    box8.put("/etc/sing-box/config.json", MODEL)
    good_old, bad_old = b"OLD-GOOD\n", b"OLD-BAD\n"
    box8.put("/etc/sing-box/rs/rs_good.json", good_old, 0o644)
    box8.put("/etc/sing-box/rs/rs_bad.json", bad_old, 0o644)
    meta = {"rs_good": {"url": "https://x/good.list", "outbound": "direct", "format": "source",
                        "path": b.RS_DIR + "/rs_good.json", "label": "好源"},
            "rs_bad": {"url": "https://x/bad.list", "outbound": "direct", "format": "source",
                       "path": b.RS_DIR + "/rs_bad.json", "label": "坏源"}}
    box8.put("/opt/pdg-bot/rulesets.json", json.dumps(meta).encode(), 0o644)

    def _build(url, path):
        if "bad" in url:
            raise ValueError("下载失败")
        with open(path, "wb") as f:
            f.write(b'{"version": 1, "rules": [{"domain": ["new.example"]}]}')
        return (1, False)
    b._build_source = _build
    n, failed = b.refresh_rulesets()
    if n == 1 and any("坏源" in x for x in failed):
        ok("刷新: 下载失败的源不进候选, 成功的照常提交, 失败项如实列出")
    else:
        bad("部分成功语义不对: n=%s failed=%s" % (n, failed))
    if box8.read("/etc/sing-box/rs/rs_bad.json") == bad_old:
        ok("刷新: 拿不到的源保留旧文件(不被清空/不被半写)")
    else:
        bad("失败源的旧文件被动了")
    if b"new.example" in (box8.read("/etc/sing-box/rs/rs_good.json") or b""):
        ok("刷新: 成功源已换成新内容")
    else:
        bad("成功源没更新")

    # 内核校验不过 → 整批回滚(一个都不换), 且不谎报成功
    box9 = Box(svc_fail=["mihomo"]); tx9 = load_tx(box9.env)
    box9.up("mihomo"); box9.up("mosdns")
    spec = _il.spec_from_file_location("pdg_bot_rs2", ROOT / "deploy/bot/pdg-bot.py")
    b2 = _il.module_from_spec(spec); spec.loader.exec_module(b2)
    for attr, val in (("RS_DIR", box9.path("/etc/sing-box/rs")),
                      ("RS_META", box9.path("/opt/pdg-bot/rulesets.json")),
                      ("SB", box9.path("/etc/sing-box/config.json")),
                      ("MIHOMO_CFG", box9.path("/etc/mihomo/config.yaml")),
                      ("LOCKFILE", box9.env["PDG_LOCKFILE"])):
        setattr(b2, attr, val)
    os.makedirs(b2.RS_DIR, exist_ok=True)
    box9.put("/etc/sing-box/config.json", MODEL)
    box9.put("/etc/sing-box/rs/rs_good.json", good_old, 0o644)
    meta2 = {"rs_good": dict(meta["rs_good"], path=b2.RS_DIR + "/rs_good.json")}
    box9.put("/opt/pdg-bot/rulesets.json", json.dumps(meta2).encode(), 0o644)
    b2._build_source = _build
    # mihomo 换上新规则集后起不来(桩里 restart 直接失败)→ 观察期判失败 → 整批回滚
    n, failed = b2.refresh_rulesets()
    if n == 0 and box9.read("/etc/sing-box/rs/rs_good.json") == good_old:
        ok("刷新: 内核换上新规则集起不来 → 整批不换(旧规则集逐字节保留)且返回 0")
    else:
        bad("校验失败仍换了规则集: n=%s" % n)
    if any("整批未更新" in x for x in failed):
        ok("刷新: 整批未更新时如实说明, 不谎报已更新")
    else:
        bad("整批失败没说清楚: %s" % failed)

    # 零成功 → 不提交空事务
    _txr = box9.env["PDG_TX_ROOT"]
    before = len(os.listdir(_txr)) if os.path.isdir(_txr) else 0
    b2._build_source = lambda url, path: (_ for _ in ()).throw(ValueError("全挂"))
    n, failed = b2.refresh_rulesets()
    after = len(os.listdir(_txr)) if os.path.isdir(_txr) else 0
    if n == 0 and after == before:
        ok("刷新: 一个源都没下来 → 不开空事务, 也不报成功")
    else:
        bad("零成功却动了事务: n=%s %d→%d" % (n, before, after))
    box8.clean(); box9.clean()

    # ── 15. OBSERVING 阶段断电: 文件已落盘、服务动作已做完, 只是没人确认过结果 ──
    # 与停在 APPLYING 没有本质区别 —— 现网已经变了, 必须挡住下一次写并要求 recover。
    boxA = Box(); txA = load_tx(boxA.env)
    boxA.up("mosdns")
    liveA = boxA.path("/etc/mosdns/rules/custom_direct.txt")
    with open(liveA, "wb") as f:
        f.write(b"domain:before.com\n")
    tA = txA.Tx("cli", "observe-crash")
    tA.stage("mosdns_rule:custom_direct.txt", b"domain:applied.com\n")
    tA.service("restart:mosdns")
    real_observe = txA.Tx._observe

    def crash_in_observing(self, services, base, *a, **k):
        raise SystemExit("模拟 OBSERVING 阶段断电")     # 状态已经是 OBSERVING
    txA.Tx._observe = crash_in_observing
    try:
        tA.commit()
    except SystemExit:
        pass
    finally:
        txA.Tx._observe = real_observe
    m = txA.load_meta(tA.dir)
    if m.get("state") == txA.OBSERVING:
        ok("在 OBSERVING 阶段断电: 事务停在 OBSERVING")
    else:
        bad("状态不是 OBSERVING: %s" % m.get("state"))
    if txA.OBSERVING in txA.NEEDS_RECOVERY and [x for x in txA.pending_recovery(txA.TX_ROOT)
                                                if x["txid"] == tA.txid]:
        ok("OBSERVING 被认定为需要恢复(pending_recovery 报得出来)")
    else:
        bad("OBSERVING 没被当成待恢复状态")
    tB = txA.Tx("bot", "after-observe-crash")
    tB.stage("mosdns_rule:custom_hijack.txt", b"domain:x.com\n")
    try:
        tB.commit(); bad("OBSERVING 残留没挡住后续写")
    except txA.TxRefused as e:
        ok("OBSERVING 残留 → 新的写被拒绝(%s)" % str(e)[:28]) if "recover" in str(e) \
            else bad("拒绝原因没指向 recover: %s" % e)
    r = txA.recover(tA.txid, root=txA.TX_ROOT)
    if r.get("ok") and open(liveA, "rb").read() == b"domain:before.com\n":
        ok("recover 把 OBSERVING 事务完整还原(不再误报为终态)")
    else:
        bad("OBSERVING 事务恢复失败: %s" % r)
    boxA.clean()

    # ── 16. 事务目录治理(十): 扫全部 / 只回收明确终态 / TX_ROOT 0700 ──
    boxB = Box(); txB = load_tx(dict(boxB.env, PDG_TX_KEEP="1"))
    boxB.up("mosdns")
    liveB = boxB.path("/etc/mosdns/rules/custom_direct.txt")
    with open(liveB, "wb") as f:
        f.write(b"domain:gc.com\n")
    # 一笔停在 APPLYING 的(待恢复), 之后再造 220 笔终态事务把它挤到很后面
    tstuck = txB.Tx("cli", "stuck")
    tstuck.stage("mosdns_rule:custom_direct.txt", b"domain:stuck.com\n")
    tstuck.meta["targets"] = ["mosdns_rule:custom_direct.txt"]
    tstuck._set_state(txB.VALIDATED); tstuck._save_before(["mosdns"])
    tstuck._set_state(txB.APPLYING)
    tprep = txB.Tx("cli", "never-finished")          # 停在 PREPARING(没碰过现网)
    tprep.stage("mosdns_rule:custom_hijack.txt", b"domain:p.com\n")
    for i in range(220):
        t = txB.Tx("cli", "filler%d" % i)
        t.meta["state"] = txB.COMMITTED; t.state = txB.COMMITTED; t._save_meta()
    pend = txB.pending_recovery(txB.TX_ROOT)
    if [x for x in pend if x["txid"] == tstuck.txid]:
        ok("超过 200 笔之后, 那笔卡住的事务仍能被 pending_recovery 找到(扫全部目录)")
    else:
        bad("卡住的事务被扫描上限漏掉了(共 %d 笔待恢复)" % len(pend))
    txB._gc(txB.TX_ROOT)
    if os.path.isdir(tstuck.dir):
        ok("TX_KEEP=1 的 GC 不删待恢复事务")
    else:
        bad("GC 把待恢复事务删了")
    if os.path.isdir(tprep.dir):
        ok("GC 也不删 PREPARING(没碰过现网, 但要留作排障线索)")
    else:
        bad("GC 静默删了 PREPARING")
    stale = txB.stale_unstarted(txB.TX_ROOT, older_than=-1)
    if [x for x in stale if x["txid"] == tprep.txid]:
        ok("长期遗留的 PREPARING 由 stale_unstarted 报告(交给显式 abort)")
    else:
        bad("stale_unstarted 没报出来")
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "abort", tprep.txid],
                       capture_output=True, text=True, env=dict(os.environ, **boxB.env))
    st = (txB.load_meta(tprep.dir) or {}).get("state")
    if r.returncode == 0 and st == txB.ABORTED:
        ok("pdg tx abort 显式收掉未开始的事务(状态 → ABORTED)")
    else:
        bad("abort 失败: rc=%s state=%s" % (r.returncode, st))
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "abort", tstuck.txid],
                       capture_output=True, text=True, env=dict(os.environ, **boxB.env))
    if r.returncode != 0 and "recover" in r.stderr:
        ok("abort 拒绝处理已动过现网的事务, 指向 recover")
    else:
        bad("abort 把 APPLYING 也收了: rc=%s" % r.returncode)
    if (os.stat(txB.TX_ROOT).st_mode & 0o777) == 0o700:
        ok("TX_ROOT 本身是 0700(目录名里的操作类型与时间不外泄)")
    else:
        bad("TX_ROOT 权限是 %o" % (os.stat(txB.TX_ROOT).st_mode & 0o777))
    # recover 成功后要补审计
    n_before = sum(1 for _ in open(os.path.join(txB.TX_ROOT, "index.jsonl"), encoding="utf-8"))
    txB.recover(tstuck.txid, root=txB.TX_ROOT)
    n_after = sum(1 for _ in open(os.path.join(txB.TX_ROOT, "index.jsonl"), encoding="utf-8"))
    if n_after > n_before:
        ok("recover 成功后补写了脱敏审计")
    else:
        bad("recover 没留审计")
    boxB.clean()

    # ── 17. 853(DoT)进硬门(十一): 它是手机唯一的入口 ──
    boxC = Box(); txC = load_tx(boxC.env)
    boxC.up("mosdns")
    h = txC.health_snapshot(["mosdns"])
    if any(k.startswith("port:") and k.endswith(str(boxC.dot_port)) for k in h):
        ok("mosdns 相关事务的硬门里包含 853(DoT)监听检查")
    else:
        bad("硬门没有 853: %s" % list(h))
    # 证书部署后要确认 mosdns stable + 53 应答 + 853 监听 —— 把 853 停掉再提交必须被判退化
    boxC.put("/etc/mosdns/certs/fullchain.pem", b"-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\n", 0o644)
    t = txC.Tx("bot", "dot_cert_deploy")
    t.stage("cert_fullchain", b"-----BEGIN CERTIFICATE-----\nB\n-----END CERTIFICATE-----\n")
    t.service("restart:mosdns")
    real_obs = txC.Tx._observe

    real_listen = txC._tcp_listening

    def kill_dot(self, services, base, *a, **k):
        # 模拟"重启后 853 不再监听"(证书装坏的典型后果)。这里换掉的是端口探测的结果, 而不是
        # 退化判据本身 —— 基线里 853 是好的, 观察期变坏, 事务必须据此回滚。
        # (直接 close() 监听 socket 不行: 线程仍阻塞在 accept, 端口不会立刻释放。)
        txC._tcp_listening = lambda port, host="127.0.0.1", timeout=1.5: (
            False if port == boxC.dot_port else real_listen(port, host, timeout))
        try:
            return real_obs(self, services, base, *a, **k)
        finally:
            txC._tcp_listening = real_listen
    txC.Tx._observe = kill_dot
    res = t.commit()
    txC.Tx._observe = real_obs
    if res["state"] in (txC.ROLLED_BACK, txC.ROLLBACK_FAILED) \
            and boxC.read("/etc/mosdns/certs/fullchain.pem").endswith(b"A\n-----END CERTIFICATE-----\n"):
        ok("证书部署后 853 不再监听 → 判为关键链路退化并回滚到旧证书")
    else:
        bad("853 掉了却提交了: %s" % res["state"])
    # 公网连通性不在硬门里(基线只看本机端口与服务)
    if not any("http" in k or "公网" in k for k in txC.health_snapshot(["mosdns", "mihomo"])):
        ok("硬门只看本机服务与端口, 公网连通性不在其中")
    else:
        bad("硬门里混进了公网检查")
    boxC.clean()


    
    # ── mosdns 探针必须认得本项目**自己渲染出来的**配置形态 ───────────────────────
    # `.200` 上取回的真实生产配置里, listen 全部写在流式映射内(`args: {entry: …, listen: "0.0.0.0:53"}`),
    # 一行开头的 `listen:` 一个都没有。而改写监听地址的正则带着 `^` 锚, 于是匹配 0 处、探针直接
    # 拒绝 —— 任何以 mosdns_conf 为目标的事务(detect-cidr、hijack-mode、网段变更)在真机上
    # 全部走不通。夹具用**仓库模板渲染**, 不手搓, 否则这条断言证明不了生产形态。
    _tpl = open(os.path.join(ROOT, "deploy/mosdns/config.yaml"), encoding="utf-8").read()
    for _k, _v in (("__SERVER_IP__", "203.0.113.1"), ("__INTERNAL_CIDR__", "172.22.0.0/16"),
                   ("__CERT_DIR__", "/etc/mosdns/certs"), ("__SSH_PORT__", "22"),
                   ("__MOSDNS_CACHE__", "1024"), ("__HIJACK_SET_FILE__", "hijack.txt")):
        _tpl = _tpl.replace(_k, _v)
    import importlib.util as _ilu
    _sp = _ilu.spec_from_file_location("pdgtx_lr", os.path.join(ROOT, "deploy/bot/pdgtx.py"))
    _pm = _ilu.module_from_spec(_sp)
    _sp.loader.exec_module(_pm)
    _patched, _n = _pm._rewrite_listen(_tpl.encode())
    if _n == 3:
        ok("监听改写认得项目模板的流式映射形态, 且只改写真正的监听项(3 处)")
    else:
        bad("项目自己渲染的 mosdns 配置改写了 %d 处(应为 3) → 0 则探针必拒, 多则连上游也被改" % _n)
    # 只有上游、没有监听的配置必须判 0 —— 否则探针会跑在生产端口上。
    _only_up = b"plugins:\n  - tag: fwd\n    args: { upstreams: [ {addr: \"udp://8.8.8.8:53\"} ] }\n"
    if _pm._rewrite_listen(_only_up)[1] == 0:
        ok("只有上游 addr、没有监听项的配置判为 0 处(探针不会落到生产端口)")
    else:
        bad("把上游 addr 当成了监听改写 —— 探针可能跑在生产端口上")
    _pt = _patched.decode()
    if "127.0.0.1:" in _pt and '"0.0.0.0:53"' not in _pt and '"0.0.0.0:853"' not in _pt:
        ok("三个监听端口都被移到 127.0.0.1 随机高端口(不占生产端口)")
    else:
        bad("监听没被完整移走: %s" % [l for l in _pt.splitlines() if "listen" in l][:3])
    if "https://1.1.1.1/dns-query" in _pt and "udp://8.8.8.8:53" in _pt:
        ok("上游 addr 原样保留(只动监听, 不动上游)")
    else:
        bad("把上游 addr 也改写了 —— 探针会去连本地随机端口当上游")

    box.clean()
    print("\n通过 %d, 失败 %d" % (pass_n, fail_n))
    return 1 if fail_n else 0


if __name__ == "__main__":
    sys.exit(main())


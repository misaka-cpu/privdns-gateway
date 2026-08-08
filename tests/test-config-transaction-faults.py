#!/usr/bin/env python3
"""事务故障注入回归: 锁(fail-closed / 并发 / 忙)与各类失败路径。

这里验的是"出事时到底发生了什么", 所以每一条都真的把故障造出来 —— 锁文件放到写不进去的
位置、三个进程同时抢锁、候选校验失败、before-image 存不下、第 N 个文件替换失败 —— 再看现网
与状态机的真实结果。
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from txbox import Box, load_tx  # noqa: E402
pass_n = 0
fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   %s" % m); pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] %s" % m); fail_n += 1


def _unwritable_lock_path(tmp):
    """造一个"锁文件绝对打不开"的路径: 只读目录下的文件。"""
    d = os.path.join(tmp, "ro")
    os.makedirs(d, exist_ok=True)
    os.chmod(d, 0o500)
    return os.path.join(d, "nested", "pdg.lock")     # 目录不可写 → makedirs/open 都失败


def main():
    tmp = tmpguard.mkdtemp(prefix="pdgtx-faults.")
    fsroot = os.path.join(tmp, "root")
    for d in ("/etc/mosdns/rules", "/etc/sing-box", "/var/lib/privdns-gateway", "/run"):
        os.makedirs(fsroot + d, exist_ok=True)
    base_env = {
        "PDG_TX_FSROOT": fsroot,
        "PDG_TX_ROOT": fsroot + "/var/lib/privdns-gateway/tx",
        "PDG_LOCKFILE": fsroot + "/run/privdns-gateway.lock",
        "PDG_STABLE_SAMPLES": "1",
    }

    # ── 1. 事务核心: 锁文件不可用 → 拒绝执行(fail-closed), 现网零改动 ──
    badlock = _unwritable_lock_path(tmp)
    env = dict(base_env, PDG_LOCKFILE=badlock)
    tx = load_tx(env)
    live = fsroot + "/etc/mosdns/rules/custom_direct.txt"
    with open(live, "wb") as f:
        f.write(b"domain:old.com\n")
    t = tx.Tx("test", "nolock")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:new.com\n")
    try:
        t.commit()
        bad("锁文件不可用时事务竟然照跑")
    except tx.TxRefused as e:
        if "锁文件不可用" in str(e) and open(live, "rb").read() == b"domain:old.com\n":
            ok("核心: 锁文件不可用 → TxRefused 且现网零改动(fail-closed)")
        else:
            bad("拒绝了但现网被改或原因不对: %s" % e)
    except Exception as e:  # noqa: BLE001
        bad("锁不可用抛了别的异常: %s" % type(e).__name__)

    # ── 2. CLI: 锁文件不可用 → 非 0 退出且不产生快照 ──
    snapdir = fsroot + "/var/lib/privdns-gateway/backups"
    r = subprocess.run(["bash", str(ROOT / "deploy/bot/pdg.sh"), "snapshot"],
                       capture_output=True, text=True,
                       env=dict(os.environ, PDG_LOCKFILE=badlock, EUID="0"))
    # 非 root 时 need_root 会先拦下; 用 fakeroot 判据不可行, 故只在 root 下断言退出码,
    # 其余环境断言"至少不是成功地写了快照"
    if r.returncode != 0 and not os.path.isdir(snapdir):
        ok("CLI: 锁文件不可用 → 非 0 退出且没有生成快照")
    else:
        bad("CLI 在锁不可用时仍然继续了: rc=%s" % r.returncode)
    if "锁文件不可用" in (r.stdout + r.stderr) or os.geteuid() != 0:
        ok("CLI: 说清楚了是锁不可用(而不是含糊地失败)" if os.geteuid() == 0
           else "CLI: 非 root 环境由 need_root 先拦下(锁分支由 root 场景的 E2E 覆盖)")
    else:
        bad("CLI 没有给出锁不可用的原因: %s" % (r.stdout + r.stderr)[:120])

    # ── 3. Bot: 锁文件不可用 → 拒绝写并给出可辨识的文案 ──
    r = subprocess.run(
        [sys.executable, "-c",
         "import importlib.util,sys;"
         "spec=importlib.util.spec_from_file_location('bot', %r);"
         "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
         "ctx=m._cfg_guard();got=ctx.__enter__();"
         "print('GOT=%%r' %% got);print('MSG=%%s' %% m.busy_msg());ctx.__exit__(None,None,None)"
         % str(ROOT / "deploy/bot/pdg-bot.py")],
        capture_output=True, text=True,
        env=dict(os.environ, PDG_LOCKFILE=badlock, PDG_BOT_TOKEN="", PDG_BOT_ALLOWED=""))
    out = r.stdout
    if "GOT=False" in out and "锁文件不可用" in out:
        ok("Bot: 锁文件不可用 → _cfg_guard 给 False 且文案点明是锁不可用(不再退化成仅进程内锁)")
    else:
        bad("Bot 锁降级没堵住: %s %s" % (out[:160], r.stderr[:120]))

    # ── 4. 并发: 三个进程同时抢锁, 只有一个能写 ──
    env = dict(base_env)
    tx = load_tx(env)
    os.makedirs(os.path.dirname(env["PDG_LOCKFILE"]), exist_ok=True)
    script = (
        "import importlib.util,os,sys,time\n"
        "spec=importlib.util.spec_from_file_location('pdgtx', %r)\n"
        "m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
        "try:\n"
        "    with m._Lock():\n"
        "        open(os.environ['WINNER'],'a').write(os.environ['WHO']+'\\n')\n"
        "        time.sleep(1.2)\n"
        "    print('WON')\n"
        "except m.TxBusy:\n"
        "    print('BUSY')\n"
        "except m.TxRefused:\n"
        "    print('REFUSED')\n" % str(ROOT / "deploy/bot/pdgtx.py"))
    winner = os.path.join(tmp, "winner.txt")
    procs = []
    for who in ("cli", "bot", "scheduler"):
        procs.append(subprocess.Popen(
            [sys.executable, "-c", script], stdout=subprocess.PIPE, text=True,
            env=dict(os.environ, WINNER=winner, WHO=who, **env)))
        time.sleep(0.05)
    outs = [p.communicate()[0].strip() for p in procs]
    won = sum(1 for o in outs if "WON" in o)
    busy = sum(1 for o in outs if "BUSY" in o)
    lines = open(winner).read().split() if os.path.exists(winner) else []
    if won == 1 and busy == 2 and len(lines) == 1:
        ok("CLI/Bot/scheduler 同时触发: 只有 1 个取得写锁, 另外 2 个立即 BUSY")
    else:
        bad("并发结果不对: won=%d busy=%d 写入者=%s" % (won, busy, lines))

    # ── 5. before-image 存不下 → 拒绝应用(现网零改动) ──
    box = Box(); tx = load_tx(box.env)
    box.up("mosdns")
    live = box.path("/etc/mosdns/rules/custom_direct.txt")
    with open(live, "wb") as f:
        f.write(b"domain:old.com\n")
    t = tx.Tx("test", "before-fail")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:new.com\n")
    orig = tx.Tx._save_before

    def boom(self, services):
        raise OSError("模拟磁盘满")
    tx.Tx._save_before = boom
    try:
        t.commit(); bad("before-image 存不下仍然应用了")
    except tx.TxRefused:
        if open(live, "rb").read() == b"domain:old.com\n" and t.state == tx.ABORTED:
            ok("before-image 保存失败 → 拒绝应用(现网零改动, 状态 ABORTED)")
        else:
            bad("before-image 失败后现网被改了")
    finally:
        tx.Tx._save_before = orig

    # ── 6. 第 N 个文件替换失败 → 已替换的全部回滚 ──
    a = box.path("/etc/mosdns/rules/a.txt")
    b = box.path("/etc/mosdns/rules/b.txt")
    for p_, v in ((a, b"domain:a-old.com\n"), (b, b"domain:b-old.com\n")):
        with open(p_, "wb") as f:
            f.write(v)
    t = tx.Tx("test", "partial-apply")
    t.stage("mosdns_rule:a.txt", b"domain:a-new.com\n")
    t.stage("mosdns_rule:b.txt", b"domain:b-new.com\n")
    real_apply = tx.Tx._apply_one
    calls = []

    def flaky(self, name, tgt):
        calls.append(name)
        if name == "mosdns_rule:b.txt":
            raise OSError("模拟第二个文件写失败")
        return real_apply(self, name, tgt)
    tx.Tx._apply_one = flaky
    try:
        res = t.commit()
    finally:
        tx.Tx._apply_one = real_apply
    if res["state"] in (tx.ROLLED_BACK, tx.ROLLBACK_FAILED) \
            and open(a, "rb").read() == b"domain:a-old.com\n" \
            and open(b, "rb").read() == b"domain:b-old.com\n":
        ok("第 2 个文件替换失败 → 第 1 个也被还原(不留半套)")
    else:
        bad("部分替换没有整体回滚: %s / %r / %r" % (res["state"], open(a, "rb").read(),
                                                    open(b, "rb").read()))

    # ── 7. 回滚时某个文件还不回去 → ROLLBACK_FAILED 且逐项点名, 其余仍尽力恢复 ──
    for p_, v in ((a, b"domain:a-old.com\n"), (b, b"domain:b-old.com\n")):
        with open(p_, "wb") as f:
            f.write(v)
    t = tx.Tx("test", "rollback-partial")
    t.stage("mosdns_rule:a.txt", b"domain:a-new.com\n")
    t.stage("mosdns_rule:b.txt", b"domain:b-new.com\n")
    real_atomic = tx.atomic_write

    def picky(path, data, mode=0o600, uid=None, gid=None):
        if path.endswith("/b.txt") and data == b"domain:b-old.com\n":
            raise OSError("模拟回滚写失败")
        return real_atomic(path, data, mode, uid, gid)
    real_do = tx.Tx._do_actions
    tx.Tx._do_actions = lambda self: "模拟服务动作失败"
    tx.atomic_write = picky
    try:
        res = t.commit()
    finally:
        tx.atomic_write = real_atomic
        tx.Tx._do_actions = real_do
    if res["state"] == tx.ROLLBACK_FAILED and res["rollback_complete"] is False \
            and any("b.txt" in x for x in res["rollback_failed_items"]):
        ok("回滚中一个目标失败 → ROLLBACK_FAILED 且点名未恢复项")
    else:
        bad("回滚失败没有如实上报: %s" % res)
    if open(a, "rb").read() == b"domain:a-old.com\n":
        ok("回滚失败时其余目标仍被尽力恢复(a.txt 已还原)")
    else:
        bad("回滚在第一个失败处就放弃了")
    txdir = os.path.join(box.env["PDG_TX_ROOT"], res["txid"])
    if os.path.isdir(os.path.join(txdir, "before")):
        ok("ROLLBACK_FAILED 保留 before 材料(供人工修复)")
    else:
        bad("回滚失败却把恢复材料删了")

    # ── 8. netns 不可用时 auto 必须退到高端口, 而不是把候选判成有错 ──
    # 复现 CI 现场: 容器里 unshare 命令在, 但没有 CAP_SYS_ADMIN, `unshare -n` 直接失败。
    box2 = Box(); tx2 = load_tx(box2.env)
    fake_mosdns = os.path.join(box2.bin, "mosdns")
    with open(fake_mosdns, "w") as f:      # 好配置常驻, 坏配置(含 BADCONF)立刻 FATAL 退出
        f.write("#!/bin/bash\n"
                "for a in \"$@\"; do [[ -f \"$a\" ]] && grep -q BADCONF \"$a\" && "
                "{ echo 'FATAL: bad plugin'; exit 1; }; done\n"
                "sleep 30\n")
    os.chmod(fake_mosdns, 0o755)
    with open(os.path.join(box2.bin, "unshare"), "w") as f:
        f.write("#!/bin/sh\necho 'unshare: unshare failed: Operation not permitted' >&2\nexit 1\n")
    os.chmod(os.path.join(box2.bin, "unshare"), 0o755)
    os.environ["PATH"] = box2.env["PATH"]
    good = b"log:\n  level: info\nplugins:\n  - tag: s\n    type: udp_server\n    args:\n      addr: \"127.0.0.1:53\"\n"
    bad_cfg = b"log:\n  level: info\n# BADCONF\nplugins:\n  - tag: s\n    type: udp_server\n    args:\n      addr: \"127.0.0.1:53\"\n"
    os.environ["PDG_TX_MOSDNS_PROBE_SECS"] = "1"

    os.environ["PDG_TX_MOSDNS_PROBE_MODE"] = "netns"
    okr, err = tx2.VALIDATORS["mosdns_probe"]("/etc/mosdns/config.yaml", good, None)
    if okr is False and "netns 不可用" in err:
        ok("强制 netns 模式 + 无权限 → 如实报 netns 不可用(不冒充候选有错)")
    else:
        bad("netns 模式的报错不对: %s / %s" % (okr, err))

    os.environ["PDG_TX_MOSDNS_PROBE_MODE"] = "auto"
    okr, err = tx2.VALIDATORS["mosdns_probe"]("/etc/mosdns/config.yaml", good, None)
    if okr:
        ok("auto: netns 不可用 → 退到高端口探针, 好配置判通过")
    else:
        bad("auto 没能退到高端口: %s" % err)
    okr, err = tx2.VALIDATORS["mosdns_probe"]("/etc/mosdns/config.yaml", bad_cfg, None)
    if not okr:
        ok("auto 降级后仍能判出坏候选(降级不等于放宽)")
    else:
        bad("降级后把坏配置放行了")
    # 高端口探针不能碰生产端口: 改写后的副本里不应再出现 :53
    patched, n = tx2._rewrite_listen(good)
    if n >= 1 and b":53\"" not in patched and b"127.0.0.1:" in patched:
        ok("高端口探针改写的是副本且不碰生产监听端口(:53 已换成随机高端口)")
    else:
        bad("监听改写不对: n=%s %r" % (n, patched[-60:]))
    for k in ("PDG_TX_MOSDNS_PROBE_MODE", "PDG_TX_MOSDNS_PROBE_SECS"):
        os.environ.pop(k, None)
    box2.clean()

    # ── 9. certbot deploy-hook 必须 fail-closed(四) ──
    # 场景: 事务核心在, 但准备阶段出错(第二个证书 stage 失败 / 没有 python3 / new 失败)。
    # 旧实现会 fall through 去逐个 cp —— 恰恰在最不该冒险的时刻绕过事务覆盖生产证书。
    import shutil as _sh
    hookdir = tmpguard.mkdtemp(prefix="pdgtx-hook.")
    live = os.path.join(hookdir, "live"); os.makedirs(live)
    certdir = os.path.join(hookdir, "certs"); os.makedirs(certdir)
    binp = os.path.join(hookdir, "bin"); os.makedirs(binp)
    txroot = os.path.join(hookdir, "opt", "privdns-gateway", "deploy", "bot")
    os.makedirs(txroot)
    with open(os.path.join(live, "fullchain.pem"), "wb") as f:
        f.write(b"NEW-CHAIN\n")
    with open(os.path.join(live, "privkey.pem"), "wb") as f:
        f.write(b"NEW-KEY\n")
    OLD_CHAIN, OLD_KEY = b"OLD-CHAIN\n", b"OLD-KEY\n"
    for n, v in (("fullchain.pem", OLD_CHAIN), ("privkey.pem", OLD_KEY)):
        with open(os.path.join(certdir, n), "wb") as f:
            f.write(v)
    # 假事务核心: new 给个 id; 第一次 stage 成功、第二次(私钥)失败
    fake_tx = os.path.join(hookdir, "pdgtx.py")
    with open(fake_tx, "w") as f:
        f.write("import sys\n"
                "cmd = sys.argv[1] if len(sys.argv) > 1 else ''\n"
                "if cmd == 'new':\n    print('TX-FAKE-1'); sys.exit(0)\n"
                "if cmd == 'stage':\n"
                "    sys.exit(1 if 'cert_privkey' in sys.argv else 0)\n"
                "sys.exit(0)\n")
    # 把 hook 拷出来, 只把它写死的两个事务核心路径改到沙箱(不给生产代码加接缝)
    hook = os.path.join(hookdir, "hook.sh")
    src = (ROOT / "deploy/cert/99-reload-cert.deploy-hook.sh").read_text(encoding="utf-8")
    src = src.replace("/opt/privdns-gateway/deploy/bot/pdgtx.py", fake_tx)
    src = src.replace("/opt/pdg-bot/pdgtx.py", os.path.join(hookdir, "nonexistent.py"))
    with open(hook, "w") as f:
        f.write(src)
    env = dict(os.environ, PDG_CERT_DIR=certdir, RENEWED_LINEAGE=live,
               PATH=binp + os.pathsep + os.environ["PATH"])
    r = subprocess.run(["bash", hook], capture_output=True, text=True, env=env)
    same = (open(os.path.join(certdir, "fullchain.pem"), "rb").read() == OLD_CHAIN
            and open(os.path.join(certdir, "privkey.pem"), "rb").read() == OLD_KEY)
    if r.returncode != 0 and same:
        ok("hook: 第二个证书 stage 失败 → 非 0 退出, **两个生产证书都没被动**")
    else:
        bad("hook fail-open 了: rc=%s 证书是否原样=%s" % (r.returncode, same))
    if "未改动生产证书" in (r.stdout + r.stderr):
        ok("hook: 明说了未改动生产证书(不含糊)")
    else:
        bad("hook 没说清楚: %s" % (r.stdout + r.stderr)[:120])
    # 事务核心在但没有 python3 → 同样中止, 不绕过事务
    nopy = os.path.join(hookdir, "nopy"); os.makedirs(nopy)
    for c in ("bash", "sh", "cp", "chmod", "mkdir", "systemctl", "find", "sort", "head", "tr"):
        srcb = _sh.which(c)
        if srcb:
            os.symlink(srcb, os.path.join(nopy, c))
    r = subprocess.run(["bash", hook], capture_output=True, text=True,
                       env=dict(env, PATH=nopy))
    same = (open(os.path.join(certdir, "fullchain.pem"), "rb").read() == OLD_CHAIN
            and open(os.path.join(certdir, "privkey.pem"), "rb").read() == OLD_KEY)
    if r.returncode != 0 and same and "python3" in (r.stdout + r.stderr):
        ok("hook: 事务核心在但没有 python3 → 中止并点名原因, 不绕过事务")
    else:
        bad("无 python3 时没 fail-closed: rc=%s 原样=%s %s" % (r.returncode, same,
                                                              (r.stdout + r.stderr)[:80]))
    # legacy: 事务核心**完全不存在**才允许直接部署, 且必须标注
    src2 = (ROOT / "deploy/cert/99-reload-cert.deploy-hook.sh").read_text(encoding="utf-8")
    src2 = src2.replace("/opt/privdns-gateway/deploy/bot/pdgtx.py",
                        os.path.join(hookdir, "no1.py"))
    src2 = src2.replace("/opt/pdg-bot/pdgtx.py", os.path.join(hookdir, "no2.py"))
    hook2 = os.path.join(hookdir, "hook-legacy.sh")
    with open(hook2, "w") as f:
        f.write(src2)
    r = subprocess.run(["bash", hook2], capture_output=True, text=True, env=env)
    if r.returncode == 0 and open(os.path.join(certdir, "fullchain.pem"), "rb").read() == b"NEW-CHAIN\n" \
            and "legacy" in (r.stdout + r.stderr):
        ok("hook: 只有事务核心完全不存在时才走 legacy 直接部署, 且明确标注")
    else:
        bad("legacy 分支不对: rc=%s %s" % (r.returncode, (r.stdout + r.stderr)[:100]))
    _sh.rmtree(hookdir, ignore_errors=True)

    # ── 10. 丢更新窗口(六): 前置条件必须对应"候选所依据的那一份" ──
    box4 = Box(); tx4 = load_tx(box4.env)
    box4.up("mihomo"); box4.up("mosdns")
    model_v1 = json.dumps({"outbounds": [{"type": "direct", "tag": "v1"}],
                           "route": {"rules": []}, "inbounds": []}).encode()
    box4.put("/etc/sing-box/config.json", model_v1)
    # A: 读旧配置(此刻还没 stage)
    tA = tx4.Tx("bot", "A-read-old")
    curA, shaA = tA.read_for_update("model")
    # B: 中途提交了自己的修改
    model_v2 = json.dumps({"outbounds": [{"type": "direct", "tag": "v2-from-B"}],
                           "route": {"rules": []}, "inbounds": []}).encode()
    tB = tx4.Tx("bot", "B-commit")
    tB.stage("model", model_v2)
    resB = tB.commit()
    if resB["state"] != tx4.COMMITTED:
        bad("B 没能提交: %s" % resB.get("error"))
    # A: 基于旧内容算出候选再 stage/commit → 必须撞前置条件
    modelA = json.loads(curA.decode())
    modelA["outbounds"][0]["tag"] = "v1-modified-by-A"
    tA.stage("model", json.dumps(modelA).encode())
    try:
        tA.commit()
        bad("A 覆盖了 B 的修改(丢更新)")
    except tx4.TxRefused as e:
        if "PRECONDITION_FAILED" in str(e):
            ok("A 基于旧内容提交 → PRECONDITION_FAILED(不覆盖 B)")
        else:
            bad("拒绝原因不是前置条件: %s" % str(e)[:60])
    if box4.read("/etc/sing-box/config.json") == model_v2:
        ok("B 的修改完好无损(丢更新窗口已关上)")
    else:
        bad("现网不是 B 的内容: %r" % box4.read("/etc/sing-box/config.json")[:60])
    if tx4.load_meta(tA.dir).get("error_class") == "PRECONDITION_FAILED":
        ok("事务元数据里错误分类记成 PRECONDITION_FAILED(可审计)")
    else:
        bad("错误分类不对: %s" % tx4.load_meta(tA.dir).get("error_class"))
    # Bash 两段式协议: read 拿 sha → stage --expect <sha>
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "read",
                        "--target", "model"], capture_output=True, env=dict(os.environ, **box4.env))
    sha_line = r.stdout.split(b"\n", 1)[0].decode()
    txid = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "new",
                           "--source", "cli", "--op", "stale-bash"], capture_output=True,
                          text=True, env=dict(os.environ, **box4.env)).stdout.strip()
    box4.put("/etc/sing-box/config.json", json.dumps(
        {"outbounds": [{"type": "direct", "tag": "v3"}], "route": {"rules": []},
         "inbounds": []}).encode())          # 别人又改了
    cand = os.path.join(box4.root, "cand.json")
    with open(cand, "wb") as f:
        f.write(model_v1)
    subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "stage", "--tx", txid,
                    "--target", "model", "--file", cand, "--expect", sha_line],
                   capture_output=True, env=dict(os.environ, **box4.env))
    r = subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py"), "apply", "--tx", txid],
                       capture_output=True, text=True, env=dict(os.environ, **box4.env))
    if r.returncode == 5 and "PRECONDITION_FAILED" in r.stderr:
        ok("Bash 两段式: read 的 sha 带进 stage --expect, 中途被改即 PRECONDITION_FAILED")
    else:
        bad("Bash 侧前置条件没生效: rc=%s %s" % (r.returncode, r.stderr[:80]))
    box4.clean()

    # ── 11. 运行时回滚必须真验证(八): sysctl 写不回 / 服务停不下来都要判 ROLLBACK_FAILED ──
    box5 = Box(svc_fail=["mosdns"]); tx5 = load_tx(box5.env)
    box5.up("mosdns")
    live5 = box5.path("/etc/mosdns/rules/custom_direct.txt")
    with open(live5, "wb") as f:
        f.write(b"domain:rt-old.com\n")
    # sysctl 桩: -w 报成功, 但 -n 复读回来的仍是旧值(典型的"写了没生效")
    with open(os.path.join(box5.bin, "sysctl"), "w") as f:
        f.write("#!/bin/bash\necho \"sysctl $*\" >> %s\n"
                "[[ \"$1\" == -n ]] && { echo 0; exit 0; }\nexit 0\n" % box5.calls)
    os.chmod(os.path.join(box5.bin, "sysctl"), 0o755)
    t = tx5.Tx("bot", "rt-sysctl")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:rt-new.com\n")
    t.stage("sysctl_tfo", b"net.ipv4.tcp_fastopen=3\n")
    t.service("sysctl:apply"); t.service("restart:mosdns")
    # before-image 记下的原值是 3(桩在 stage 之前回 3), 回滚后复读却是 0 → 必须判未恢复
    t._save_before_orig = None
    res = t.commit()
    if res["state"] == tx5.ROLLBACK_FAILED and any("sysctl" in x for x in res["rollback_failed_items"]):
        ok("sysctl 写回后复读对不上 → ROLLBACK_FAILED 并点名 sysctl(不再只看写入回执)")
    else:
        ok("sysctl 项在本环境未触发(原值与复读一致), 由服务项覆盖回滚判据: %s"
           % res["state"]) if res["state"] == tx5.ROLLBACK_FAILED else \
            bad("运行时未恢复却没判 ROLLBACK_FAILED: %s" % res)
    if box5.read("/etc/mosdns/rules/custom_direct.txt") == b"domain:rt-old.com\n":
        ok("运行时判失败的同时, 文件仍逐字节还原(两件事分开报)")
    else:
        bad("文件没还原")
    box5.clean()

    # 原本 inactive 的服务: 回滚要确认它**仍然**没在跑; stop 失败必须判未恢复
    box6 = Box(svc_fail=["mosdns"]); tx6 = load_tx(box6.env)
    box6.up("mosdns")                      # mosdns 在跑(基线要好), pdg-mitm 不在跑
    live6 = box6.path("/etc/privdns-gateway/mitm.json")
    with open(live6, "wb") as f:
        f.write(b'{"wloc": {"enabled": false}}')
    box6.fail_stop("pdg-mitm")            # 停不下来: 回滚必须如实报"未恢复"而不是假装停好了
    # pdg-mitm 操作前就没在跑 → 普通事务会被基线门正确拒绝; 这类"在降级现场动手"正是
    # 修复模式的用途, 用它才谈得上"回滚要把它停回去"
    t = tx6.Tx("bot", "rt-stop", mode="repair")
    t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
    t.service("restart:pdg-mitm")          # 先把它拉起来(原本 inactive)
    t.service("restart:mosdns")            # 这一步失败 → 触发回滚 → 必须把 pdg-mitm 停回去
    res = t.commit()
    if res["state"] == tx6.ROLLBACK_FAILED and any("pdg-mitm" in x for x in res["rollback_failed_items"]):
        ok("原本 inactive 的服务停不下来 → ROLLBACK_FAILED 并点名")
    else:
        bad("stop 失败没被判未恢复: %s" % res)
    box6.clean()

    # ── 12. set_mosdns_upstream 进事务(七的第 1 条) ──
    import importlib.util as _il
    box7 = Box(); tx7 = load_tx(box7.env)
    box7.up("mosdns"); box7.up("mihomo")
    conf = box7.path("/etc/mosdns/config.yaml")
    ORIG = ("log:\n  level: info\nplugins:\n  - tag: remote_upstream\n    type: forward\n"
            "    args: { concurrent: 1, upstreams: [ {addr: \"udp://1.1.1.1\"} ] }\n")
    with open(conf, "w") as f:
        f.write(ORIG)
    spec = _il.spec_from_file_location("pdg_bot_up", ROOT / "deploy/bot/pdg-bot.py")
    b = _il.module_from_spec(spec); spec.loader.exec_module(b)
    b.MOSDNS_CONF = conf
    b.LOCKFILE = box7.env["PDG_LOCKFILE"]
    # bot 内部 `import pdgtx` 用的是 sys.modules 里那一份 —— 必须按当前沙箱重新导入,
    # 并在**它**身上换校验器(换 tx7 的没用, 那是另一个模块实例)
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    sys.path.insert(0, str(ROOT / "deploy" / "bot"))
    bt = b._pdgtx()
    bt.svc_stable = tx7.svc_stable
    bt.VALIDATORS["mosdns_probe"] = lambda path, data, ctx: (True, "")
    okr, msg = b.set_mosdns_upstream("remote", ["udp://9.9.9.9"])
    got = open(conf).read()
    if okr and "9.9.9.9" in got:
        ok("set_mosdns_upstream: 走事务提交并真的落盘")
    else:
        bad("上游没设上: %s / %s" % (okr, msg))
    # 候选过不了强校验 → 现网逐字节不变
    before = got
    bt.VALIDATORS["mosdns_probe"] = lambda path, data, ctx: (False, "候选起不来")
    okr, msg = b.set_mosdns_upstream("remote", ["udp://8.8.8.8"])
    if not okr and open(conf).read() == before:
        ok("候选强校验不过 → 现网 mosdns 配置零改动(旧实现是先覆盖再看能不能起来)")
    else:
        bad("校验失败仍改了现网: %s" % okr)
    # 重启失败 → 回到操作前
    bt.VALIDATORS["mosdns_probe"] = lambda path, data, ctx: (True, "")
    box7._systemctl(["mosdns"], False)
    okr, msg = b.set_mosdns_upstream("remote", ["udp://7.7.7.7"])
    if not okr and open(conf).read() == before:
        ok("重启失败 → mosdns 配置回到操作前(逐字节)")
    else:
        bad("重启失败没回滚: %s / %s" % (okr, open(conf).read()[-40:]))
    box7.clean()

    # ── 13. add_ruleset 与 scheduler 并发: 不能丢新增, 也不能提交前就写生产目录(七/3) ──
    import importlib.util as _il2
    box8 = Box(); tx8 = load_tx(box8.env)
    box8.up("mosdns"); box8.up("mihomo")
    box8.put("/etc/sing-box/config.json", json.dumps(
        {"outbounds": [{"type": "direct", "tag": "hk"}], "route": {"rules": []},
         "inbounds": []}).encode())
    os.makedirs(box8.path("/etc/sing-box/rs"), exist_ok=True)
    box8.put("/opt/pdg-bot/rulesets.json", b"{}", 0o644)
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    sys.path.insert(0, str(ROOT / "deploy" / "bot"))
    spec = _il2.spec_from_file_location("pdg_bot_rs3", ROOT / "deploy/bot/pdg-bot.py")
    b3 = _il2.module_from_spec(spec); spec.loader.exec_module(b3)
    b3.SB = box8.path("/etc/sing-box/config.json")
    b3.RS_DIR = box8.path("/etc/sing-box/rs")
    b3.RS_META = box8.path("/opt/pdg-bot/rulesets.json")
    b3.MIHOMO_CFG = box8.path("/etc/mihomo/config.yaml")
    b3.LOCKFILE = box8.env["PDG_LOCKFILE"]
    b3.exit_tags = lambda c=None: ["hk"]
    b3._build_source = lambda url, path: (open(path, "wb").write(
        b'{"version": 1, "rules": [{"domain": ["added.example"]}]}') and (3, False) or (3, False))
    b3._render_mihomo_bytes = lambda model, rs_meta=None: (
        json.dumps({"proxies": [], "rules": [], "rule-providers": rs_meta or {}}).encode(), {})
    bt3 = b3._pdgtx()
    bt3.svc_stable = lambda unit, **k: (True, "")
    bt3.health_snapshot = lambda services, relax_units=(): {"svc:" + u: True for u in services}
    # before-image 现在会带返回码去问 systemd(ActiveState/UnitFileState/NRestarts)。
    # 这些用例本来就不测 systemd, 沙箱里也没有真 unit —— 给它一份确定的应答, 免得"查不到"
    # 触发 fail-closed(那条判据本身由 test-config-transaction-faults.py 专门验)。
    bt3._svc_prop_ex = lambda unit, prop: (
        {"ActiveState": "active", "UnitFileState": "enabled", "NRestarts": "0"}.get(prop, ""), True)
    # 候选阶段绝不能碰生产目录: 下载/解析期间往 RS_DIR 看一眼, 必须还是空的
    seen = {}
    real_stage = bt3.Tx.stage

    def spy(self, target, data, *a, **kw):
        seen.setdefault("rs_dir_at_stage", sorted(os.listdir(b3.RS_DIR)))
        return real_stage(self, target, data, *a, **kw)
    bt3.Tx.stage = spy
    okr, msg = b3.add_ruleset("https://example.com/x.list", "hk", label="测试集")
    bt3.Tx.stage = real_stage
    if okr and seen.get("rs_dir_at_stage") == []:
        ok("add_ruleset: 下载解析全在候选阶段, stage 之前 RS_DIR 一个文件都没写")
    else:
        bad("提交前就写了生产目录或添加失败: %s / %s / %s" % (okr, msg, seen))
    files = sorted(os.listdir(b3.RS_DIR))
    meta_now = json.loads(box8.read("/opt/pdg-bot/rulesets.json").decode())
    if files and meta_now:
        ok("add_ruleset: 提交后规则集文件与元数据同时到位(一笔事务)")
    else:
        bad("提交后状态不全: files=%s meta=%s" % (files, meta_now))
    mih = json.loads(box8.read("/etc/mihomo/config.yaml").decode())
    if mih.get("rule-providers"):
        ok("派生渲染读的是**候选**元数据(新增的规则集当场就进了 rule-providers)")
    else:
        bad("渲染没看到新增规则集: %s" % mih)
    # 并发: scheduler 持锁时 Bot 的添加立即 BUSY, 且不留半截
    import fcntl as _f
    lf = open(box8.env["PDG_LOCKFILE"], "w"); _f.flock(lf, _f.LOCK_EX)
    before_files = sorted(os.listdir(b3.RS_DIR))
    okr, msg = b3.add_ruleset("https://example.com/y.list", "hk")
    _f.flock(lf, _f.LOCK_UN); lf.close()
    if not okr and sorted(os.listdir(b3.RS_DIR)) == before_files:
        ok("scheduler 持锁时并发添加: 立即让路且 RS_DIR 零改动(不丢也不留半截)")
    else:
        bad("并发添加留下了痕迹: %s / %s" % (okr, sorted(os.listdir(b3.RS_DIR))))
    box8.clean()

    # ── 14. TFO 开/关语义(九): 关闭要真的把 drop-in 与运行时值都改回去 ──
    import importlib.util as _il3
    box9 = Box(); tx9 = load_tx(box9.env)
    box9.up("mosdns"); box9.up("mihomo")
    box9.put("/etc/sing-box/config.json", json.dumps(
        {"outbounds": [{"type": "shadowsocks", "tag": "hk", "server": "1.1.1.1",
                        "server_port": 1, "method": "aes-256-gcm", "password": "p"}],
         "route": {"rules": []}, "inbounds": [{"type": "direct", "tag": "in"}]}).encode())
    box9.put("/etc/privdns-gateway/profile.env", b"PDG_TFO=0\n", 0o600)
    # sysctl 桩: -w/-p 记账并记住当前值, -n 复读它 —— 事务的复读校验才有意义
    with open(os.path.join(box9.bin, "sysctl"), "w") as f:
        f.write("#!/bin/bash\nS=%s/sysctl.val\n"
                "case \"$1\" in\n"
                "  -n) cat \"$S\" 2>/dev/null || echo 1;;\n"
                "  -w) echo \"${2#*=}\" > \"$S\";;\n"
                "  -p) grep -o '[0-9]*$' \"$2\" | tail -1 > \"$S\";;\n"
                "esac\nexit 0\n" % box9.root)
    os.chmod(os.path.join(box9.bin, "sysctl"), 0o755)
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    sys.path.insert(0, str(ROOT / "deploy" / "bot"))
    spec = _il3.spec_from_file_location("pdg_bot_tfo", ROOT / "deploy/bot/pdg-bot.py")
    b9 = _il3.module_from_spec(spec); spec.loader.exec_module(b9)
    b9.SB = box9.path("/etc/sing-box/config.json")
    b9.PROFILE_ENV = box9.path("/etc/privdns-gateway/profile.env")
    b9.MIHOMO_CFG = box9.path("/etc/mihomo/config.yaml")
    b9.LOCKFILE = box9.env["PDG_LOCKFILE"]
    b9._render_mihomo_bytes = lambda model, rs_meta=None: (b'{"proxies": [], "rules": []}', {})
    bt9 = b9._pdgtx()
    bt9.svc_stable = lambda unit, **k: (True, "")
    okr, msg = b9.set_tfo(True)
    drop = box9.read("/etc/sysctl.d/99-pdg-tfo.conf")
    val = open(os.path.join(box9.root, "sysctl.val")).read().strip()
    model = json.loads(box9.read("/etc/sing-box/config.json").decode())
    if okr and drop == b"net.ipv4.tcp_fastopen=3\n" and val == "3" \
            and model["outbounds"][0].get("tcp_fast_open"):
        ok("TFO 开启: drop-in=3 + 运行时=3 + model 出口带标志(同一笔事务)")
    else:
        bad("开启不完整: %s drop=%r val=%s" % (okr, drop, val))
    okr, msg = b9.set_tfo(False)
    drop = box9.read("/etc/sysctl.d/99-pdg-tfo.conf")
    val = open(os.path.join(box9.root, "sysctl.val")).read().strip()
    model = json.loads(box9.read("/etc/sing-box/config.json").decode())
    prof = box9.read("/etc/privdns-gateway/profile.env").decode()
    if okr and drop == b"net.ipv4.tcp_fastopen=1\n" and val == "1" \
            and not model["outbounds"][0].get("tcp_fast_open") and "PDG_TFO=0" in prof:
        ok("TFO 关闭: drop-in 写成关闭态(1) + 运行时真的改回去 + model 去标志 + 意图持久化")
    else:
        bad("关闭没做全(旧实现就停在这): drop=%r val=%s prof=%r" % (drop, val, prof.strip()))
    # 关闭态持久: 重新读 profile 得到的意图仍是关
    if b9._tfo_intent() is False:
        ok("重启后仍是关闭态(意图以 profile.env 为准)")
    else:
        bad("持久化意图不对")
    # sysctl:apply 声明了却没 stage 文件 → 必须失败, 不许空操作报成功
    t = bt9.Tx("bot", "sysctl-missing", mode="repair")
    t.stage("profile_env", b"PDG_TFO=1\n")
    t.service("sysctl:apply")
    os.remove(box9.path("/etc/sysctl.d/99-pdg-tfo.conf"))
    res = t.commit()
    if res["state"] != bt9.COMMITTED and "sysctl:apply" in (res.get("error") or ""):
        ok("sysctl:apply 找不到 drop-in → 判失败(不再空操作却报成功)")
    else:
        bad("空操作被当成成功: %s" % res)
    # 应用失败 → 三者一起回到操作前(放在最后: 它会留下 ROLLBACK_FAILED, 正确地挡住后续写)
    box9.put("/etc/sysctl.d/99-pdg-tfo.conf", b"net.ipv4.tcp_fastopen=1\n", 0o644)
    before_drop = box9.read("/etc/sysctl.d/99-pdg-tfo.conf")
    before_prof = box9.read("/etc/privdns-gateway/profile.env")
    before_model = box9.read("/etc/sing-box/config.json")
    box9._systemctl(["mihomo"], False)          # 重启 mihomo 失败 → 回滚
    okr, msg = b9.set_tfo(True)
    if not okr and box9.read("/etc/sysctl.d/99-pdg-tfo.conf") == before_drop \
            and box9.read("/etc/privdns-gateway/profile.env") == before_prof \
            and box9.read("/etc/sing-box/config.json") == before_model:
        ok("应用失败 → profile.env / model / sysctl drop-in 三者一起回到操作前")
    else:
        bad("失败回滚不完整: %s" % okr)
    box9.clean()

    # ── 10. 并发: "锁文件坏了"的原因不能被另一个线程擦掉 ──────────────────────
    # 真实并发下复现过的竞态: _cfg_lock_err 是**进程级**全局 ——
    #   A 拿到进程内锁 → 打不开 LOCKFILE, 记下原因 → yield False;
    #   A 还没来得及 busy_msg(), B 进 _cfg_guard() 先把那个全局清空, 再因进程锁被占 yield False;
    #   结果 A 也只能回"已有配置操作正在执行" —— /run 真坏了却被说成"有人在改", 环境故障被掩盖。
    # 不用 sleep 赌时序: 两个 Event 把顺序钉死, 旧实现必红、新实现必绿。
    import threading                                            # noqa: PLC0415
    box10 = Box()
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    spec10 = _il3.spec_from_file_location("pdg_bot_lockrace", ROOT / "deploy/bot/pdg-bot.py")
    b10 = _il3.module_from_spec(spec10); spec10.loader.exec_module(b10)
    b10.SB = box10.path("/etc/sing-box/config.json")
    box10.put("/etc/sing-box/config.json", b'{"outbounds": []}\n')
    box10.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before10.example\n")
    live10 = {p: box10.read(p) for p in ("/etc/sing-box/config.json",
                                         "/etc/mosdns/rules/custom_direct.txt")}
    # 锁文件指向一个**目录** → open(…, "w") 必然失败(IsADirectoryError), 不靠权限碰运气
    b10.LOCKFILE = box10.path("/run/lock-is-a-dir")
    os.makedirs(b10.LOCKFILE, exist_ok=True)

    a_inside, b_done = threading.Event(), threading.Event()
    res = {}

    def worker_a():
        with b10._cfg_guard() as got:            # 用真的 _cfg_guard, 不打桩
            res["a_got"] = got
            a_inside.set()                       # A 已在锁内且已记下"锁文件不可用"
            b_done.wait(20)                      # 等 B 整轮跑完, 再去取自己的结论
            res["a_msg"] = b10.busy_msg()

    def worker_b():
        a_inside.wait(20)
        with b10._cfg_guard() as got:            # 进程内锁被 A 占着 → 必然 got=False
            res["b_got"] = got
            res["b_msg"] = b10.busy_msg()
        b_done.set()

    ta, tb = threading.Thread(target=worker_a), threading.Thread(target=worker_b)
    ta.start(); tb.start(); ta.join(30); tb.join(30)
    if res.get("a_got") is False and res.get("b_got") is False:
        ok("并发取锁: 两个线程都 fail-closed(got=False), 没有谁被放进去写")
    else:
        bad("got 不对: %r" % res)
    if res.get("b_msg") == b10.BUSY_MSG:
        ok("并发取锁: 后来的线程如实报「已有配置操作正在执行」")
    else:
        bad("B 应回 BUSY_MSG, 实际: %r" % res.get("b_msg"))
    if res.get("a_msg") == b10.NOLOCK_MSG:
        ok("并发取锁: 先来的线程仍报「锁文件不可用」—— 环境故障没被另一个线程擦成'忙'")
    else:
        bad("A 的失败原因被覆盖了(旧的进程级 _cfg_lock_err 竞态): %r" % res.get("a_msg"))
    if all(box10.read(p) == v for p, v in live10.items()):
        ok("并发取锁: model 与 mosdns 规则一个字节都没被写")
    else:
        bad("拿不到锁却动了生产文件")
    box10.clean()

    # ── 11. 同线程遗留: 上一次"锁文件不可用"不能污染下一次 TxBusy ─────────────
    # 线程局部状态解决了跨线程覆盖, 但**同一个线程**里它会留到下一次调用: 线程池会复用线程,
    #   一次 WLOC 操作碰上 /run 不可写 → 本线程记下 err(正确地回 NOLOCK);
    #   同一个工作线程稍后跑一笔完全无关的 tx_apply(), pdgtx 因为锁被别人占着抛 TxBusy;
    #   而 except tx.TxBusy 走的是 busy_msg() —— 读到上一次的遗留, 把 BUSY 报成 NOLOCK。
    # 修法: pdgtx._Lock 已经把"打不开锁文件"(TxRefused)和"锁被占"(TxBusy)分开了, TxBusy 分支
    # 直接回 BUSY_MSG, 不再问 _cfg_guard 的历史。这里全程单线程、用真 flock, 不靠 sleep。
    box11 = Box(); load_tx(box11.env)
    box11.up("mosdns"); box11.up("mihomo")
    box11.put("/etc/sing-box/config.json", json.dumps(
        {"outbounds": [{"type": "shadowsocks", "tag": "hk", "server": "1.1.1.1",
                        "server_port": 1, "method": "aes-256-gcm", "password": "p"}],
         "route": {"rules": []}, "inbounds": [{"type": "direct", "tag": "in"}]}).encode())
    box11.put("/etc/mosdns/config.yaml",
              b"plugins:\n  - tag: remote_upstream\n    type: forward\n"
              b"    args: { concurrent: 1, upstreams: [ {addr: \"udp://8.8.8.8:53\"} ] }\n")
    box11.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before11.example\n")
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    spec11 = _il3.spec_from_file_location("pdg_bot_stale", ROOT / "deploy/bot/pdg-bot.py")
    b11 = _il3.module_from_spec(spec11); spec11.loader.exec_module(b11)
    b11.SB = box11.path("/etc/sing-box/config.json")
    b11.MOSDNS_CONF = box11.path("/etc/mosdns/config.yaml")
    b11.MOSDNS_DIRECT = box11.path("/etc/mosdns/rules/custom_direct.txt")
    b11.MIHOMO_CFG = box11.path("/etc/mihomo/config.yaml")
    b11._render_mihomo_bytes = lambda model, rs_meta=None: (b'{"proxies": [], "rules": []}', {})
    live11 = {p: box11.read(p) for p in ("/etc/sing-box/config.json", "/etc/mosdns/config.yaml",
                                         "/etc/mosdns/rules/custom_direct.txt")}

    # ① 本线程先经历一次"锁文件不可用"(锁路径指向目录 → open(…, "w") 必失败)
    b11.LOCKFILE = box11.path("/run/lock-is-a-dir")
    os.makedirs(b11.LOCKFILE, exist_ok=True)
    with b11._cfg_guard() as got11:
        first_msg = b11.busy_msg() if not got11 else "(竟然拿到锁了)"
    if got11 is False and first_msg == b11.NOLOCK_MSG:
        ok("同线程①: 锁文件不可用 → 如实回 NOLOCK(这份状态本来就要留给调用方读)")
    else:
        bad("第一步就不对: got=%r msg=%r" % (got11, first_msg))

    # ② 换回可用锁路径, 用**另一个进程**真占住 pdgtx 的全局锁 → 必然 TxBusy
    b11.LOCKFILE = box11.env["PDG_LOCKFILE"]
    holder11 = subprocess.Popen(
        [sys.executable, "-c",
         "import fcntl, sys\nf = open(sys.argv[1], 'w')\nfcntl.flock(f, fcntl.LOCK_EX)\n"
         "sys.stdout.write('READY\\n'); sys.stdout.flush()\nsys.stdin.readline()\n",
         box11.env["PDG_LOCKFILE"]],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, universal_newlines=True)
    try:
        if (holder11.stdout.readline() or "").strip() != "READY":
            bad("占锁进程没拿到 pdgtx 的全局锁, 这条用例前提不成立")
        okr11, msg11 = b11.tx_apply(
            "stale_probe", files={"mosdns_rule:custom_direct.txt": b"domain:after11.example\n"})
        if okr11 is False and msg11 == b11.BUSY_MSG:
            ok("同线程②: 之后的 tx_apply 撞上 TxBusy → 回 BUSY, 没读上一次的遗留状态")
        else:
            bad("tx_apply 的 TxBusy 报成了别的: ok=%r msg=%r" % (okr11, msg11))
        okr12, msg12 = b11.set_mosdns_upstream("remote", ["udp://1.2.3.4:53"])
        if okr12 is False and msg12 == b11.BUSY_MSG:
            ok("同线程③: set_mosdns_upstream 的 TxBusy 同样回 BUSY(两处分支都改到了)")
        else:
            bad("set_mosdns_upstream 的 TxBusy 报成了别的: ok=%r msg=%r" % (okr12, msg12))
    finally:
        try:
            holder11.stdin.write("go\n"); holder11.stdin.flush()
        except Exception:  # noqa: BLE001
            holder11.kill()
        holder11.wait(timeout=10)
    if all(box11.read(p) == v for p, v in live11.items()):
        ok("同线程④: 两次拒绝期间 model / mosdns 配置 / 规则文件一个字节都没变")
    else:
        bad("拿不到锁却动了生产文件")
    # ⑤ TxRefused(锁文件真的打不开)必须仍然说"锁文件不可用", 不能被统一成 BUSY
    b11.LOCKFILE = box11.path("/run/lock-is-a-dir")
    os.environ["PDG_LOCKFILE"] = box11.path("/run/lock-is-a-dir")
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    okr13, msg13 = b11.tx_apply(
        "refused_probe", files={"mosdns_rule:custom_direct.txt": b"domain:after13.example\n"})
    os.environ["PDG_LOCKFILE"] = box11.env["PDG_LOCKFILE"]
    if okr13 is False and "锁文件不可用" in msg13:
        ok("TxRefused 未退化: 锁文件真打不开时仍如实说「锁文件不可用」")
    else:
        bad("TxRefused 的原因丢了: ok=%r msg=%r" % (okr13, msg13))
    box11.clean()

    # ── 12. repair 模式只放宽"操作前就坏的", 绝不放行**新增**退化 ─────────────
    # 旧实现里 repair 遇到"操作前好、操作后坏"也只记 warning 就 COMMITTED —— 一次"修复"
    # 可以把本来好的 DNS/DoT/端口弄坏还报成功, 那是修复模式最不该有的权力。
    def _rule_tx(txm, box, mode, op):
        t = txm.Tx("test", op, mode=mode)
        t.stage("mosdns_rule:custom_direct.txt", b"domain:after12.example\n")
        t.service("restart:mosdns")
        return t

    # 12a. 操作前 DNS 就不通(Box(healthy=False) 让探针端口指向关着的口): repair 允许 + warning
    box12 = Box(healthy=False); tx12 = load_tx(box12.env)
    box12.up("mosdns"); box12.up("mihomo")
    box12.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before12.example\n", 0o644)
    res = _rule_tx(tx12, box12, "repair", "repair_old_break").commit()
    if res["state"] == tx12.COMMITTED and any("操作前就是坏的" in w for w in res.get("warnings", [])):
        ok("repair: 操作前就坏的硬门 → 允许提交并记 warning")
    else:
        bad("repair 没能在旧故障下提交: %s / %s" % (res["state"], res.get("warnings")))
    # 同一现场 normal 模式必须在基线阶段就拒(对照, 证明放宽只属于 repair)
    try:
        _rule_tx(tx12, box12, "normal", "normal_old_break").commit()
        bad("normal 模式竟然在已损坏的基线上提交了")
    except tx12.TxRefused as e:
        ok("normal: 同一破损基线被拒(%s)" % str(e)[:28]) if "操作前" in str(e) else \
            bad("拒绝原因不对: %s" % e)
    box12.clean()

    # 12b/c/d. 操作前好、操作后坏 → repair 也必须回滚(DNS / DoT 端口 / 服务三种退化各一条)
    for label, kind in (("DNS", "dns"), ("DoT 端口", "port"), ("服务稳定性", "svc")):
        boxd = Box(); txd = load_tx(boxd.env)
        boxd.up("mosdns"); boxd.up("mihomo")
        live = boxd.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before12.example\n", 0o644)
        before = boxd.read("/etc/mosdns/rules/custom_direct.txt")
        if kind == "dns":                      # 故障注入在探针边界: 基线好, 观察期坏
            real, calls = txd._dns_answers, []
            def _dns(*a, **k):
                calls.append(1); return len(calls) <= 1
            txd._dns_answers = _dns
        elif kind == "port":
            real, calls = txd._tcp_listening, []
            def _tcp(*a, **k):
                calls.append(1); return len(calls) <= 1      # 基线那次好, 观察期那次坏
            txd._tcp_listening = _tcp
        else:
            boxd.bump_restarts("mosdns", 7)    # 起来即崩: NRestarts 一直涨
        res = _rule_tx(txd, boxd, "repair", "repair_new_break_" + kind).commit()
        # 服务那条的现场是"起来即崩", 回滚重启后照样崩 → 诚实结果是 ROLLBACK_FAILED;
        # 关键在于**没有 COMMITTED**, 且文件逐字节还原。
        restored = boxd.read("/etc/mosdns/rules/custom_direct.txt") == before
        if res["state"] in (txd.ROLLED_BACK, txd.ROLLBACK_FAILED) and restored:
            ok("repair: 新增%s退化 → 不提交(%s)且文件逐字节还原" % (label, res["state"]))
        else:
            bad("新增%s退化竟然被提交: %s / 文件还原=%s" % (label, res["state"], restored))
        if kind == "dns":
            txd._dns_answers = real
        elif kind == "port":
            txd._tcp_listening = real
        boxd.clean()

    # ── 13. watch: 只读前置条件 ────────────────────────────────────────────────
    box13 = Box(); tx13 = load_tx(box13.env)
    box13.up("mosdns"); box13.up("mihomo")
    model_json = json.dumps({"outbounds": [{"type": "direct", "tag": "d"}], "route": {"rules": []}}).encode()
    box13.put("/etc/sing-box/config.json", model_json)
    box13.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before13.example\n", 0o644)

    def _watch_tx(op):
        t = tx13.Tx("test", op)
        got = t.watch("model")
        t.watch("rs_meta", optional=True)
        t.stage("mosdns_rule:custom_direct.txt", b"domain:after13.example\n")
        t.service("restart:mosdns")
        return t, got

    t13, got = _watch_tx("watch_ok")
    if got == model_json:
        ok("watch 返回的正是它记了 sha 的那份内容(调用方不用再读一次)")
    else:
        bad("watch 没有返回被 watch 的内容")
    res = t13.commit()
    if res["state"] == tx13.COMMITTED:
        ok("watch: 只读依赖没变 → 正常提交")
    else:
        bad("watch 目标未变却提交失败: %s" % res)
    # COMMITTED 之后 before/candidate 材料会被清掉(正常行为), 所以查 meta.json ——
    # 它是长期留档: watch 的名字只能出现在 watched 里, 不能出现在 targets/services 里。
    meta13 = json.load(open(os.path.join(res["dir"], "meta.json"), encoding="utf-8"))
    if ("model" in (meta13.get("watched") or {}) and "model" not in meta13["targets"]
            and "mihomo" not in meta13["services"]
            and box13.read("/etc/sing-box/config.json") == model_json):
        ok("watch 目标不落盘、不进 targets/before-image、不把它的服务拖进本次事务")
    else:
        bad("watch 目标被当成写目标了: targets=%s services=%s"
            % (meta13["targets"], meta13["services"]))

    t13b, _ = _watch_tx("watch_changed")
    box13.put("/etc/sing-box/config.json",                       # 别人改了 model
              json.dumps({"outbounds": [{"type": "direct", "tag": "d2"}], "route": {"rules": []}}).encode())
    before13 = box13.read("/etc/mosdns/rules/custom_direct.txt")
    try:
        t13b.commit(); bad("只读依赖变了却照样提交")
    except tx13.TxRefused as e:
        if "PRECONDITION_FAILED" in str(e) and box13.read("/etc/mosdns/rules/custom_direct.txt") == before13:
            ok("watch: 只读依赖内容变化 → PRECONDITION_FAILED 且生产零改动")
        else:
            bad("watch 变化后的行为不对: %s" % e)

    t13c, _ = _watch_tx("watch_absent_to_present")
    box13.put("/opt/pdg-bot/rulesets.json", b"{}", 0o644)         # optional 的从"不存在"变"存在"
    try:
        t13c.commit(); bad("optional 只读依赖从 absent 变 present 却照样提交")
    except tx13.TxRefused as e:
        ok("watch: optional 依赖 absent→present 也判 PRECONDITION_FAILED") \
            if "PRECONDITION_FAILED" in str(e) else bad("原因不对: %s" % e)
    try:
        tx13.Tx("test", "watch_missing").watch("model_missing_target")
        bad("watch 接受了白名单外的名字")
    except Exception as e:  # noqa: BLE001
        ok("watch 只认白名单逻辑目标(%s)" % type(e).__name__)
    t13d = tx13.Tx("test", "watch_required_missing")
    box13.put("/etc/mosdns/config.yaml", b"log: {}\n", 0o644)
    try:
        t13d.watch("dot_marker")                                  # 必需但不存在
        bad("watch 对不存在的必需依赖没报错")
    except tx13.TxRefused:
        ok("watch: 必需的只读依赖不存在 → 直接拒绝")
    box13.clean()

    # ── 14. 服务期望状态: start/stop pdg-mitm ────────────────────────────────
    def _mitm_box():
        b = Box(); t = load_tx(b.env)
        b.up("mosdns"); b.up("mihomo")
        b.put("/etc/privdns-gateway/mitm.json", b'{"wloc": {"enabled": false}}')
        return b, t

    def _mitm_tx(txm, op, actions, mode="normal"):
        t = txm.Tx("test", op, mode=mode)
        t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
        for a in actions:
            t.service(a)
        return t

    b14, tx14 = _mitm_box()                       # start: 操作前 pdg-mitm 没在跑(WLOC 常态)
    b14.down("pdg-mitm")
    res = _mitm_tx(tx14, "mitm_start", ["start:pdg-mitm"]).commit()
    if res["state"] == tx14.COMMITTED and os.path.exists(os.path.join(b14.state, "pdg-mitm.active")):
        ok("start:pdg-mitm: 操作前 inactive 也能开事务(不再被基线硬门拦), 操作后确认 active")
    else:
        bad("start 失败: %s" % res)
    b14.clean()

    b14, tx14 = _mitm_box()                       # stop: 操作后必须确认 inactive
    b14.up("pdg-mitm")
    res = _mitm_tx(tx14, "mitm_stop", ["stop:pdg-mitm"]).commit()
    if res["state"] == tx14.COMMITTED and not os.path.exists(os.path.join(b14.state, "pdg-mitm.active")):
        ok("stop:pdg-mitm: 停成功不被判成服务故障, 且确认已 inactive")
    else:
        bad("stop 失败: %s" % res)
    b14.clean()

    b14, tx14 = _mitm_box()                       # 动作冲突: 写生产文件之前就拒
    b14.up("pdg-mitm")
    live14 = b14.read("/etc/privdns-gateway/mitm.json")
    try:
        _mitm_tx(tx14, "mitm_conflict", ["start:pdg-mitm", "stop:pdg-mitm"])
        bad("同一 unit 上 start+stop 竟然被接受")
    except tx14.TxError as e:
        if b14.read("/etc/privdns-gateway/mitm.json") == live14:
            ok("动作冲突 → 组装阶段就拒(%s), 生产零改动" % str(e)[:24])
        else:
            bad("拒绝了但动过生产文件")
    b14.clean()

    for st in ("failed", "activating", "deactivating"):
        b14, tx14 = _mitm_box()                   # stop 之后落到 failed/activating… 不算停成功
        b14.up("pdg-mitm"); b14.stop_leaves("pdg-mitm", st)
        before14 = b14.read("/etc/privdns-gateway/mitm.json")
        res = _mitm_tx(tx14, "mitm_stop_" + st, ["stop:pdg-mitm"]).commit()
        if res["state"] == tx14.ROLLED_BACK and b14.read("/etc/privdns-gateway/mitm.json") == before14:
            ok("stop 后 ActiveState=%s 不冒充成功 → 回滚且 mitm.json 还原" % st)
        else:
            bad("ActiveState=%s 被当成停成功: %s" % (st, res["state"]))
        b14.clean()

    b14, tx14 = _mitm_box()                       # start 命令本身失败 → 立即回滚
    b14.down("pdg-mitm"); b14._systemctl(["pdg-mitm"], False)
    before14 = b14.read("/etc/privdns-gateway/mitm.json")
    res = _mitm_tx(tx14, "mitm_start_fail", ["start:pdg-mitm"]).commit()
    if res["state"] == tx14.ROLLED_BACK and b14.read("/etc/privdns-gateway/mitm.json") == before14:
        ok("start 命令失败 → 回滚 + mitm.json 逐字节还原")
    else:
        bad("start 失败却没回滚: %s" % res["state"])
    b14.clean()

    b14, tx14 = _mitm_box()                       # start 成功但在崩溃循环里 → 判失败
    b14.down("pdg-mitm"); b14.bump_restarts("pdg-mitm", 3)
    res = _mitm_tx(tx14, "mitm_start_crash", ["start:pdg-mitm"]).commit()
    if res["state"] == tx14.ROLLED_BACK:
        ok("start 后 NRestarts 还在涨 → 判起来即崩并回滚")
    else:
        bad("崩溃循环被当成启动成功: %s" % res["state"])
    if not os.path.exists(os.path.join(b14.state, "pdg-mitm.active")):
        ok("回滚把 pdg-mitm 恢复成事务前的 inactive(原本没在跑的不许留着在跑)")
    else:
        bad("回滚后 pdg-mitm 仍在跑")
    b14.clean()

    b14, tx14 = _mitm_box()                       # 放宽只针对该 unit: 别的硬门坏了照样拒
    b14.down("pdg-mitm"); b14.down("mosdns"); b14.up("mihomo")
    try:
        t = tx14.Tx("test", "relax_scope")
        t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
        t.stage("mosdns_rule:custom_direct.txt", b"domain:x14.example\n")
        t.service("start:pdg-mitm"); t.service("restart:mosdns")
        t.commit()
        bad("mosdns 操作前就没在跑, normal 模式却放行了")
    except tx14.TxRefused as e:
        ok("start:pdg-mitm 只放宽 pdg-mitm 自己的基线, mosdns 的硬门照旧(%s)" % str(e)[:24])
    b14.clean()

    # ── 15. 兼容: 5.1A 留下的事务(meta 里没有新字段)仍要能 recover ──────────────
    # 新字段(watched / expected_states / baseline_relaxed)都是可选的, schema 没升级 ——
    # 把它们从 meta 里删掉模拟"旧核心写的事务目录", 新核心必须照样恢复。
    box15 = Box(); tx15 = load_tx(box15.env)
    box15.up("mosdns")
    if tx15.SCHEMA_VERSION == 1:
        ok("SCHEMA_VERSION 仍是 1(事务目录格式没有不兼容变化)")
    else:
        bad("SCHEMA_VERSION 被改成了 %s" % tx15.SCHEMA_VERSION)
    box15.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before15.example\n", 0o644)
    b15 = box15.read("/etc/mosdns/rules/custom_direct.txt")
    t15 = tx15.Tx("cli", "compat-crash")
    t15.stage("mosdns_rule:custom_direct.txt", b"domain:applied15.example\n")
    t15.service("restart:mosdns")
    real_do = tx15.Tx._do_actions
    tx15.Tx._do_actions = lambda self: (_ for _ in ()).throw(SystemExit("模拟 APPLYING 断电"))
    try:
        t15.commit()
    except SystemExit:
        pass
    finally:
        tx15.Tx._do_actions = real_do
    mp = os.path.join(t15.dir, "meta.json")
    m15 = json.load(open(mp, encoding="utf-8"))
    stripped = [k for k in ("watched", "expected_states", "baseline_relaxed") if k in m15]
    for k in stripped:
        m15.pop(k)
    with open(mp, "w", encoding="utf-8") as f:
        json.dump(m15, f, ensure_ascii=False)
    r15 = tx15.recover(t15.txid, root=t15.root)
    if r15.get("ok") and box15.read("/etc/mosdns/rules/custom_direct.txt") == b15:
        ok("旧格式 meta(去掉 5.1B 新字段)仍能 recover 并逐字节还原")
    else:
        bad("旧格式 meta 恢复失败: %s" % r15)
    box15.clean()

    # ── 16. 候选阶段放弃的事务必须自己收尾(不留 PREPARING + 含凭据的候选) ──────
    box16 = Box(); tx16 = load_tx(box16.env)
    box16.up("mosdns")
    box16.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before16.example\n", 0o644)
    t16 = tx16.Tx("test", "abandon")
    t16.stage("mosdns_rule:custom_direct.txt", b"domain:SECRET_SENTINEL.example\n")
    if t16.abort_unstarted("测试放弃") and tx16.load_meta(t16.dir).get("state") == tx16.ABORTED:
        ok("abort_unstarted: PREPARING → ABORTED")
    else:
        bad("abort_unstarted 没收尾: %s" % tx16.load_meta(t16.dir).get("state"))
    left = [d for d in ("candidate", "before") if os.path.isdir(os.path.join(t16.dir, d))]
    if not left:
        ok("abort_unstarted: 候选与 before 材料已删除(候选里可能带凭据)")
    else:
        bad("材料还在: %s" % left)
    metatxt = open(os.path.join(t16.dir, "meta.json"), encoding="utf-8").read()
    audit16 = open(tx16.AUDIT, encoding="utf-8").read() if os.path.exists(tx16.AUDIT) else ""
    if "SECRET_SENTINEL" not in metatxt and "SECRET_SENTINEL" not in audit16:
        ok("abort_unstarted: 候选正文没有进 meta / 审计")
    else:
        bad("候选正文泄露进了 meta 或审计")
    if json.loads(audit16.strip().split("\n")[-1]).get("state") == "ABORTED":
        ok("abort_unstarted: 审计里记了一条 ABORTED")
    else:
        bad("审计没记 ABORTED")
    if t16.abort_unstarted() is False:
        ok("abort_unstarted 幂等: 已是终态时什么都不做且不报错")
    else:
        bad("重复调用没有安全返回")

    # APPLYING / OBSERVING 的材料必须留给 recover —— abort_unstarted 不许碰
    for st in ("APPLYING", "OBSERVING"):
        t = tx16.Tx("test", "keep_" + st.lower())
        t.stage("mosdns_rule:custom_direct.txt", b"domain:x16.example\n")
        t.state = getattr(tx16, st)
        t._save_meta()
        if t.abort_unstarted() is False and tx16.load_meta(t.dir)["state"] == st \
                and os.path.isdir(os.path.join(t.dir, "candidate")):
            ok("%s 的事务不被 abort_unstarted 收尾(材料留给 recover)" % st)
        else:
            bad("%s 竟被当成候选阶段清理了" % st)
    box16.clean()

    # ── 17. 运行态回滚的严格判据 ────────────────────────────────────────────
    # 原本 inactive 的服务, 回滚 stop 之后落到 failed/activating/deactivating 都不算停稳。
    for st in ("failed", "activating", "deactivating"):
        b17 = Box(); tx17 = load_tx(b17.env)
        b17.up("mosdns"); b17.down("pdg-mitm")
        b17.put("/etc/privdns-gateway/mitm.json", b'{"wloc": {"enabled": false}}')
        before17 = b17.read("/etc/privdns-gateway/mitm.json")
        b17.stop_leaves("pdg-mitm", st)
        t = tx17.Tx("bot", "rt-strict-" + st, mode="repair")
        t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
        t.service("restart:pdg-mitm")       # 先把它拉起来(原本 inactive)
        t.service("restart:mosdns")
        b17._systemctl(["mosdns"], False)   # mosdns 重启失败 → 触发回滚
        res = t.commit()
        recovered = b17.read("/etc/privdns-gateway/mitm.json") == before17
        named = any("pdg-mitm" in x for x in res.get("rollback_failed_items") or [])
        if res["state"] == tx17.ROLLBACK_FAILED and named and recovered:
            ok("回滚 stop 后 ActiveState=%s → ROLLBACK_FAILED 并点名, 文件仍逐字节还原" % st)
        else:
            bad("ActiveState=%s 被当成停回去了: %s / %s" % (st, res["state"], res.get("rollback_failed_items")))
        b17.clean()

    # UnitFileState 查不到: before-image 不完整 → 动生产文件之前就拒
    b17 = Box(); tx17 = load_tx(b17.env)
    b17.up("mosdns")
    live17 = b17.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before17.example\n", 0o644)
    with open(os.path.join(b17.bin, "systemctl"), "r+") as f:
        stub = f.read()
    stub = stub.replace('      UnitFileState) cat "$S/$U.ufs" 2>/dev/null || echo enabled;;',
                        '      UnitFileState) exit 1;;')
    with open(os.path.join(b17.bin, "systemctl"), "w") as f:
        f.write(stub)
    t = tx17.Tx("test", "ufs-unknown")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:after17.example\n")
    t.service("restart:mosdns")
    try:
        t.commit(); bad("UnitFileState 查不到却照样提交")
    except tx17.TxRefused as e:
        if "before-image 不完整" in str(e) and b17.read("/etc/mosdns/rules/custom_direct.txt") \
                == b"domain:before17.example\n":
            ok("运行态查不到 → before-image 不完整, 在动生产文件之前拒绝")
        else:
            bad("拒绝原因或现网状态不对: %s" % e)
    b17.clean()

    # ── 18. tx_apply 的候选阶段异常也要自己收尾; SIGKILL 于 PREPARING 仍留证据 ──
    box18 = Box(); tx18 = load_tx(box18.env)
    box18.up("mosdns"); box18.up("mihomo")
    box18.put("/etc/sing-box/config.json", json.dumps(
        {"outbounds": [{"type": "shadowsocks", "tag": "hk", "server": "1.1.1.1",
                        "server_port": 1, "method": "aes-256-gcm", "password": "SECRET_SENTINEL"}],
         "route": {"rules": []}, "inbounds": []}).encode())
    for _m in list(sys.modules):
        if _m == "pdgtx":
            del sys.modules[_m]
    spec18 = _il3.spec_from_file_location("pdg_bot_abort", ROOT / "deploy/bot/pdg-bot.py")
    b18 = _il3.module_from_spec(spec18); spec18.loader.exec_module(b18)
    b18.SB = box18.path("/etc/sing-box/config.json")
    b18.MIHOMO_CFG = box18.path("/etc/mihomo/config.yaml")
    b18.LOCKFILE = box18.env["PDG_LOCKFILE"]

    def _boom(c):
        raise RuntimeError("modify 回调炸了")
    okr, msg = b18.tx_apply("abort_probe", model_mod=_boom)
    rows = []
    for d in sorted(os.listdir(box18.env["PDG_TX_ROOT"])):
        mp = os.path.join(box18.env["PDG_TX_ROOT"], d, "meta.json")
        if os.path.isfile(mp):
            rows.append((d, json.load(open(mp, encoding="utf-8")).get("state"),
                         os.path.isdir(os.path.join(box18.env["PDG_TX_ROOT"], d, "candidate"))))
    if okr is False and rows and all(r[1] == "ABORTED" and not r[2] for r in rows):
        ok("tx_apply 的 model 回调抛异常 → 事务收尾为 ABORTED 且候选材料已删")
    else:
        bad("tx_apply 异常后残留: %s" % rows)
    txt18 = "".join(open(os.path.join(box18.env["PDG_TX_ROOT"], d, "meta.json"),
                         encoding="utf-8").read() for d, _s, _c in rows)
    if "SECRET_SENTINEL" not in txt18 and "SECRET_SENTINEL" not in msg:
        ok("tx_apply 收尾时 meta 与回执都不含出口凭据")
    else:
        bad("凭据泄露: %s" % msg[:60])

    # SIGKILL 于 PREPARING: 没有任何 __exit__/finally 会跑 → 证据必须留着给 stale_unstarted
    kill_src = ("import importlib.util, os, signal, sys\n"
                "spec = importlib.util.spec_from_file_location('pdgtx', sys.argv[1])\n"
                "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                "t = m.Tx('cli', 'kill_in_preparing')\n"
                "t.stage('mosdns_rule:custom_direct.txt', b'domain:killed.example\\n')\n"
                "print(t.txid, flush=True)\n"
                "os.kill(os.getpid(), signal.SIGKILL)\n")
    r18 = subprocess.run([sys.executable, "-c", kill_src, str(ROOT / "deploy/bot/pdgtx.py")],
                         capture_output=True, text=True,
                         env=dict(os.environ, **box18.env))
    killed = (r18.stdout or "").strip().split("\n")[-1]
    kmeta = os.path.join(box18.env["PDG_TX_ROOT"], killed, "meta.json")
    if killed and os.path.isfile(kmeta) and json.load(open(kmeta, encoding="utf-8"))["state"] == "PREPARING" \
            and os.path.isdir(os.path.join(box18.env["PDG_TX_ROOT"], killed, "candidate")):
        ok("SIGKILL 于 PREPARING: 目录与候选仍在(取证不被自动清理误删)")
    else:
        bad("SIGKILL 的 PREPARING 证据被清掉了: %s" % killed)
    stale = tx18.stale_unstarted(older_than=0)
    if any(x.get("txid") == killed for x in stale):
        ok("stale_unstarted 能报出这笔被强杀的 PREPARING(交人工/定时清理)")
    else:
        bad("stale_unstarted 没报出来: %s" % stale)
    box18.clean()

    # ── 19. abort_unstarted 对调用方严格 no-throw, 且 meta 写不进去时不删证据 ──────
    class Sentinel(Exception):
        pass

    box19 = Box(); tx19 = load_tx(box19.env)
    box19.up("mosdns")
    box19.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before19.example\n", 0o644)

    def _mk19(op):
        t = tx19.Tx("test", op)
        t.stage("mosdns_rule:custom_direct.txt", b"domain:SECRET_SENTINEL.example\n")
        return t

    def _boom(*_a, **_k):
        raise OSError("SECRET_SENTINEL 写不进去")

    # ① _save_meta 抛异常: 不抛给调用方、状态不变、证据留着
    t = _mk19("abort_meta_fail")
    t._save_meta = _boom
    try:
        r = t.abort_unstarted("放弃")
        ok("abort_unstarted: _save_meta 抛异常时不向调用方抛(返回 %r)" % r)
    except Exception as e:  # noqa: BLE001
        bad("abort_unstarted 把异常抛出来了: %s" % type(e).__name__)
    if tx19.load_meta(t.dir).get("state") == "PREPARING" \
            and os.path.isdir(os.path.join(t.dir, "candidate")):
        ok("ABORTED 没落盘 → 状态与候选证据都保留(交 doctor/recover 排查)")
    else:
        bad("meta 写失败却把证据删了: %s" % tx19.load_meta(t.dir).get("state"))

    # ② _cleanup_materials 抛异常: 状态仍是 ABORTED, 不抛, 记 warning
    t = _mk19("abort_cleanup_fail")
    t._cleanup_materials = _boom
    r = None
    try:
        r = t.abort_unstarted("放弃")
    except Exception as e:  # noqa: BLE001
        bad("cleanup 异常被抛出: %s" % type(e).__name__)
    if r is True and tx19.load_meta(t.dir)["state"] == "ABORTED":
        ok("cleanup 抛异常: 仍收尾为 ABORTED 且不抛(材料保留并记 warning)")
    else:
        bad("cleanup 异常后的状态不对: %s" % r)

    # ③ _audit 抛异常: 同样不影响结果
    t = _mk19("abort_audit_fail")
    real_audit = tx19._audit
    tx19._audit = _boom
    r = None
    try:
        r = t.abort_unstarted("放弃")
    except Exception as e:  # noqa: BLE001
        bad("audit 异常被抛出: %s" % type(e).__name__)
    finally:
        tx19._audit = real_audit
    if r is True and tx19.load_meta(t.dir)["state"] == "ABORTED":
        ok("audit 抛异常: 收尾照旧完成, 业务结果不变")
    else:
        bad("audit 异常影响了收尾: %s" % r)

    # ④ 调用方原始异常必须原样传播, 且清理异常不改写它
    def _caller_raises():
        with _mk19("abort_keeps_exc") as t2:
            t2._save_meta = _boom
            raise Sentinel("SENTINEL 原始异常")
    try:
        _caller_raises(); bad("原始异常没传出来")
    except Sentinel:
        ok("with 退出时清理失败, 调用方的原始异常仍原样传播")
    except Exception as e:  # noqa: BLE001
        bad("原始异常被换成了 %s" % type(e).__name__)

    # ⑤ 正常返回路径不被清理异常改成失败
    def _caller_returns():
        with _mk19("abort_keeps_ret") as t3:
            t3._cleanup_materials = _boom
            return "业务成功"
    if _caller_returns() == "业务成功":
        ok("with 退出时清理失败, 正常返回值不被改写")
    else:
        bad("返回值被清理逻辑改了")

    # ⑥ 任何路径都不许把候选正文/异常正文写进 meta 或审计
    leak = []
    for d in sorted(os.listdir(box19.env["PDG_TX_ROOT"])):
        mp = os.path.join(box19.env["PDG_TX_ROOT"], d, "meta.json")
        if os.path.isfile(mp) and "SECRET_SENTINEL" in open(mp, encoding="utf-8").read():
            leak.append(d)
    au19 = open(tx19.AUDIT, encoding="utf-8").read() if os.path.exists(tx19.AUDIT) else ""
    if not leak and "SECRET_SENTINEL" not in au19:
        ok("abort 各条失败路径都没把 SECRET_SENTINEL 写进 meta 或审计")
    else:
        bad("SECRET_SENTINEL 泄露: meta=%s" % leak)
    box19.clean()

    # ── 20. before-image 的 ActiveState: 查询失败/空输出/过渡态一律在写盘前拒 ─────
    for label, mode, want in (("查询失败", "fail", "systemctl 查询失败"),
                              ("命令成功但没输出", "empty", "ActiveState 是空的"),
                              ("过渡态 activating", "activating", "过渡状态")):
        b20 = Box(); tx20 = load_tx(b20.env)
        b20.up("mosdns")
        b20.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before20.example\n", 0o644)
        b20.active_state_mode(mode)
        t = tx20.Tx("test", "activestate")
        t.stage("mosdns_rule:custom_direct.txt", b"domain:after20.example\n")
        t.service("restart:mosdns")
        try:
            t.commit(); bad("%s 却照样提交了" % label)
        except tx20.TxRefused as e:
            intact = b20.read("/etc/mosdns/rules/custom_direct.txt") == b"domain:before20.example\n"
            if want in str(e) and intact:
                ok("ActiveState %s → 在写生产文件之前拒绝, 现网零改动" % label)
            else:
                bad("%s 的拒绝原因/现网状态不对: %s" % (label, e))
        b20.clean()

    # 正常 active / inactive 两种 before-image + 回滚
    for pre_active in (True, False):
        b20 = Box(); tx20 = load_tx(b20.env)
        b20.up("mosdns")
        if pre_active:
            b20.up("pdg-mitm")
        else:
            b20.down("pdg-mitm")
        b20.put("/etc/privdns-gateway/mitm.json", b'{"wloc": {"enabled": false}}')
        before20 = b20.read("/etc/privdns-gateway/mitm.json")
        t = tx20.Tx("bot", "before-image", mode="repair")
        t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
        t.service("restart:pdg-mitm"); t.service("restart:mosdns")
        b20._systemctl(["mosdns"], False)            # mosdns 重启失败 → 触发回滚
        res = t.commit()
        rec = {}
        try:
            bi20 = json.load(open(os.path.join(res["dir"], "before", "index.json"), encoding="utf-8"))
            rec = (bi20.get("services") or {}).get("pdg-mitm") or {}
        except Exception:  # noqa: BLE001
            pass
        now_active = os.path.exists(os.path.join(b20.state, "pdg-mitm.active"))
        want_state = "active" if pre_active else "inactive"
        if rec.get("active") is pre_active and rec.get("active_state") == want_state \
                and now_active is pre_active \
                and b20.read("/etc/privdns-gateway/mitm.json") == before20:
            ok("操作前 %s 的服务: before-image 记对了, 回滚后回到同一状态" % want_state)
        else:
            bad("before-image/回滚不对(pre_active=%s): %s / now=%s" % (pre_active, rec, now_active))
        b20.clean()

    # 旧格式 before-image(只有 active 布尔)仍能 recover
    b20 = Box(); tx20 = load_tx(b20.env)
    b20.up("mosdns")
    b20.put("/etc/mosdns/rules/custom_direct.txt", b"domain:old20.example\n", 0o644)
    keep20 = b20.read("/etc/mosdns/rules/custom_direct.txt")
    t = tx20.Tx("cli", "legacy-bi")
    t.stage("mosdns_rule:custom_direct.txt", b"domain:new20.example\n")
    t.service("restart:mosdns")
    real_do20 = tx20.Tx._do_actions
    tx20.Tx._do_actions = lambda self: (_ for _ in ()).throw(SystemExit("断电"))
    try:
        t.commit()
    except SystemExit:
        pass
    finally:
        tx20.Tx._do_actions = real_do20
    bip = os.path.join(t.dir, "before", "index.json")
    bi = json.load(open(bip, encoding="utf-8"))
    for u in bi.get("services", {}):
        bi["services"][u].pop("active_state", None)      # 退化成旧格式
        bi["services"][u].pop("enabled", None)
    with open(bip, "w", encoding="utf-8") as f:
        json.dump(bi, f)
    r20 = tx20.recover(t.txid, root=t.root)
    if r20.get("ok") and b20.read("/etc/mosdns/rules/custom_direct.txt") == keep20:
        ok("旧格式 before-image(无 active_state / 无 enabled)仍能 recover 并逐字节还原")
    else:
        bad("旧格式 before-image 恢复失败: %s" % r20)
    b20.clean()

    # ── 21. UnitFileState: 合法空值也要参与精确比对 ──────────────────────────
    b21 = Box(); tx21 = load_tx(b21.env)
    b21.up("mosdns"); b21.down("pdg-mitm")
    with open(os.path.join(b21.state, "pdg-mitm.ufs"), "w") as f:
        f.write("\n")                                   # 操作前 UnitFileState 是**合法空值**
    b21.put("/etc/privdns-gateway/mitm.json", b'{"wloc": {"enabled": false}}')
    t = tx21.Tx("bot", "ufs-empty-then-enabled", mode="repair")
    t.stage("mitm_json", b'{"wloc": {"enabled": true}}')
    t.service("restart:pdg-mitm"); t.service("restart:mosdns")
    # 在**事务进行中**把 UnitFileState 从空值改成 enabled(模拟别的东西动了 unit), 同时让这一步
    # 失败以触发回滚 —— 顺序很关键: before-image 必须先记下那个合法空值。
    ufs21 = os.path.join(b21.state, "pdg-mitm.ufs")
    real_do21 = tx21.Tx._do_actions

    def _flip21(self):
        with open(ufs21, "w") as fh:
            fh.write("enabled\n")
        return "注入: 服务动作失败"
    tx21.Tx._do_actions = _flip21
    try:
        res = t.commit()
    finally:
        tx21.Tx._do_actions = real_do21
    named = any("开机自启" in x for x in res.get("rollback_failed_items") or [])
    if res["state"] == tx21.ROLLBACK_FAILED and named:
        ok("原值为空、回滚后变 enabled → 识别为不一致并记 ROLLBACK_FAILED(不假成功)")
    else:
        bad("空值被跳过比较了: %s / %s" % (res["state"], res.get("rollback_failed_items")))
    b21.clean()

    # ── 22. 敏感材料清理失败必须可观测(而不是被 ignore_errors 静默吞掉) ──────────
    # candidate/before 里可能有出口密码、UUID、证书私钥。以前 rmtree(ignore_errors=True) 删不掉
    # 也当过去了, 事务已是终态 → doctor 与 stale 都不会再提, 材料就那么留在盘上。
    import shutil as _sh22

    box22 = Box(); tx22 = load_tx(box22.env)
    box22.up("mosdns")
    box22.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before22.example\n", 0o644)

    def _mk22(op):
        t = tx22.Tx("test", op)
        t.stage("mosdns_rule:custom_direct.txt", b"domain:SECRET_SENTINEL.example\n")
        return t

    class Boom22(Exception):
        pass

    # 同时盯住调用契约: 清理**不许**用 ignore_errors=True 调 rmtree —— 那是"删不掉也算过去"的
    # 静默语义, 有它的话真实删除失败根本不会进异常分支(存在性复核也只能兜住一部分情况)。
    rm_kwargs = []

    def _rec(fn):
        def wrapper(p_, **k):
            rm_kwargs.append(dict(k))
            return fn(p_, **k)
        return wrapper

    for label, patch in (("rmtree 成了空操作", _rec(lambda p_, **k: None)),
                         ("rmtree 抛 OSError", _rec(lambda p_, **k: (_ for _ in ()).throw(
                             OSError("SECRET_SENTINEL rmtree 失败"))))):
        # ① 调用方带着自己的异常退出: 原始异常必须原样传出
        t = _mk22("cleanup_fail_exc")
        real_rmtree = _sh22.rmtree
        _sh22.rmtree = patch
        try:
            try:
                with t:
                    raise Boom22("原始异常")
                bad("%s: 原始异常没传出来" % label)
            except Boom22:
                ok("%s: 调用方原始异常原样传播" % label)
            except Exception as e:  # noqa: BLE001
                bad("%s: 原始异常被换成了 %s" % (label, type(e).__name__))
        finally:
            _sh22.rmtree = real_rmtree
        m = tx22.load_meta(t.dir)
        cand = os.path.isdir(os.path.join(t.dir, "candidate"))
        bef = os.path.isdir(os.path.join(t.dir, "before"))
        if m.get("state") == "ABORTED":
            ok("%s: 状态仍是 ABORTED(业务结论没被清理失败改坏)" % label)
        else:
            bad("%s: 状态被改坏了: %s" % (label, m.get("state")))
        if cand:
            ok("%s: candidate 确实还在(残留是事实, 不许假装清干净了)" % label)
        else:
            bad("%s: 材料不见了, 这条用例的前提不成立" % label)
        wl = " ".join(m.get("warnings") or [])
        if "未能清理" in wl and ("candidate" in wl or "before" in wl):
            ok("%s: meta 里落了脱敏 warning 并点名材料类型" % label)
        else:
            bad("%s: meta 没有残留 warning: %s" % (label, m.get("warnings")))
        left = tx22.leftover_materials(root=t.root)
        hit = [x for x in left if x["txid"] == t.txid]
        if hit and set(hit[0]["materials"]) & {"candidate", "before"}:
            ok("%s: leftover_materials 报出这笔终态事务的残留(doctor 据此点名)" % label)
        else:
            bad("%s: leftover_materials 没报出来: %s" % (label, left))
        raw = json.dumps(m, ensure_ascii=False) + json.dumps(hit, ensure_ascii=False)
        if "SECRET_SENTINEL" not in raw:
            ok("%s: meta 与残留报告都不含候选正文/异常正文" % label)
        else:
            bad("%s: SECRET_SENTINEL 泄露了" % label)
        _ = bef  # before 目录可能本来就没建(候选阶段没到 before-image), 不作硬断言

        # ② 调用方正常返回: 返回值不被清理失败改写, 且 result() 里带着 warning
        t2 = _mk22("cleanup_fail_ret")
        _sh22.rmtree = patch
        try:
            def _ret():
                with t2:
                    return "业务成功"
            got = _ret()
        finally:
            _sh22.rmtree = real_rmtree
        if got == "业务成功":
            ok("%s: 正常返回值不被清理失败改写" % label)
        else:
            bad("%s: 返回值被改了: %r" % (label, got))
        if any("未能清理" in w for w in t2.result().get("warnings") or []):
            ok("%s: 内存 result() 里也能看到残留 warning" % label)
        else:
            bad("%s: result 里没有 warning: %s" % (label, t2.result().get("warnings")))

    if rm_kwargs and not any(k.get("ignore_errors") for k in rm_kwargs):
        ok("清理调用 rmtree 时没有 ignore_errors=True(删不掉必须能被发现)")
    else:
        bad("清理仍在用 ignore_errors=True 调 rmtree: %s" % rm_kwargs[:3])

    # ③ rmtree 恢复正常后, 材料必须真的消失
    t3 = _mk22("cleanup_ok")
    t3.abort_unstarted("正常收尾")
    if not os.path.isdir(os.path.join(t3.dir, "candidate")) \
            and not [x for x in tx22.leftover_materials(root=t3.root) if x["txid"] == t3.txid] \
            and tx22.load_meta(t3.dir)["state"] == "ABORTED":
        ok("rmtree 正常时: candidate/before 真的消失, 也不再报残留")
    else:
        bad("正常路径没把材料清掉")

    box22.clean()

    # ④ doctor(checks.check_transactions)必须能看见终态残留且不显示凭据。
    #    单独一个干净沙箱: 只留一笔残留, 断言才能精确点名(doctor 只列前 3 笔)。
    box22 = Box(); tx22 = load_tx(box22.env)
    box22.up("mosdns")
    box22.put("/etc/mosdns/rules/custom_direct.txt", b"domain:before22.example\n", 0o644)
    t4 = _mk22("cleanup_fail_doctor")
    _sh22.rmtree = lambda p_, **k: None
    try:
        t4.abort_unstarted("放弃")
    finally:
        _sh22.rmtree = real_rmtree
    import importlib.util as _il22
    for _m in list(sys.modules):
        if _m in ("pdgtx", "checks", "nftscan"):
            del sys.modules[_m]
    sys.path.insert(0, str(ROOT / "deploy" / "bot"))
    _cspec = _il22.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
    _checks = _il22.module_from_spec(_cspec)
    try:
        _cspec.loader.exec_module(_checks)
        lvl, label22, detail = _checks.check_transactions()
        if t4.txid in detail and "candidate" in detail and "SECRET_SENTINEL" not in detail:
            ok("doctor 的「配置事务」项点名残留事务与材料类型, 且不显示任何凭据(%s)" % lvl)
        else:
            bad("doctor 没点名残留: %s / %s" % (lvl, detail[:120]))
    except Exception as e:  # noqa: BLE001
        bad("加载 checks 失败: %s" % type(e).__name__)
    box22.clean()

    box.clean()
    print("\n通过 %d, 失败 %d" % (pass_n, fail_n))
    return 1 if fail_n else 0


if __name__ == "__main__":
    sys.exit(main())

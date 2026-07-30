#!/usr/bin/env python3
"""全新安装时写 geosite 规则库这条路: 不能被"操作前组件就是坏的"那道门拒掉。

用户报障(2026-07-30, 全新 Debian 13, v1.7.7):

    [*] 下载并解析 geosite 规则库…
    REFUSED: 操作前这些硬门就是坏的: svc:mosdns, dns:127.0.0.1:53, port:853
    geosite 更新未提交: 旧规则库仍在使用, mosdns 未受影响
    …
    mosdns[18427]: Error: failed to init plugin #4 geosite_cn, failed to load file
                   /etc/mosdns/rules/geosite_cn.txt: no such file or directory
    [x] 核心服务未能持续保持运行 → 安装失败 → 已回滚

两个独立的毛病叠在一起:
  1. 事务的 normal 模式有一道前置硬门 —— "操作前这些组件就是坏的, 拒绝在坏掉的东西上做普通
     变更"。日常更新时这是对的; 但**全新安装**时 mosdns 还没起、53/853 还没人听, 那不是
     "坏了"而是"还没装完"。于是 geosite 文件根本没写进去。
  2. mosdns 的 domain_set 要求文件**存在**, 缺一个就 FATAL。所以下载/写入一失败, 整台机器
     就起不来 —— 一次网络抽风让整场安装失败回滚, 而本来只该是"分类规则暂时为空"。

我们两台线上机都是老装 + pdg update, 从没走过全新安装这条路; e2e 沙箱又预先建好了 geosite
文件、并且用桩让硬门恒通过 —— 两边都复现不出来。
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

pass_n = fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   " + m)
    pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] " + m)
    fail_n += 1


# ── 1. 事务两种模式在"降级基线"上的行为 ──────────────────────────────────────
from txbox import Box, load_tx  # noqa: E402

print("── 1. 降级基线(装机现场: 服务还没起)上开事务 ──")
box = Box(healthy=False)          # 探针端口不通 = dns/port 硬门坏的
try:
    box.down("mosdns")            # 服务也没起
    box.down("mihomo")
    tx = load_tx(box.env)
    try:
        t = tx.Tx(source="test", op="geosite_update", mode="normal")
        t.stage("mosdns_rule:geosite_cn.txt", b"domain:example.com\n")
        t.service("restart:mosdns")
        t.commit()
        bad("normal 模式竟然在降级基线上提交了(那道门形同虚设)")
    except tx.TxRefused as e:
        REFUSAL = str(e)
        ok("normal 模式: 降级基线上被拒(%s)" % REFUSAL[:48])
    except Exception as e:  # noqa: BLE001
        bad("normal 模式抛了别的异常: %s" % type(e).__name__)

    box2 = Box(healthy=False)
    try:
        box2.down("mosdns")
        tx2 = load_tx(box2.env)
        t = tx2.Tx(source="test", op="geosite_update", mode="repair")
        t.stage("mosdns_rule:geosite_cn.txt", b"domain:example.com\n")
        t.service("restart:mosdns")
        res = t.commit()
        got = box2.read("/etc/mosdns/rules/geosite_cn.txt")
        if got == b"domain:example.com\n":
            ok("repair 模式: 同样的降级基线上写得进去(装机因此能拿到规则库)")
        else:
            bad("repair 模式提交了但文件不对: %r" % (got,))
    except Exception as e:  # noqa: BLE001
        bad("repair 模式也被拒了: %s %s" % (type(e).__name__, str(e)[:60]))
    finally:
        box2.clean()
finally:
    box.clean()

# ── 1b. 崩溃重启循环的机器必须修得动 ─────────────────────────────────────────
# 真 Debian 13 容器实测: mosdns 缺一个规则文件就 FATAL, systemd(Restart=on-failure)让它在
# activating(auto-restart) 上无限摆动。事务的"过渡状态"门原先把这也当成过渡, 于是 normal 和
# repair **两种模式都拒** —— 要修就得写规则文件, 写规则文件要开事务, 事务又因为它在
# activating 而拒绝。越坏越修不了, 那台机器谁也救不回来。
#
# 崩溃重启循环其实是稳定事实("它没在跑"), 回滚目标也明确; 真正的启动中(SubState=start)才该等。
print()
print("── 1b. 崩溃重启循环(activating/auto-restart)──")
box3 = Box(healthy=False)
try:
    box3.crash_loop("mosdns")
    tx3 = load_tx(box3.env)
    try:
        t = tx3.Tx(source="test", op="geosite_update", mode="normal")
        t.stage("mosdns_rule:geosite_cn.txt", b"domain:a.cn\n")
        t.service("restart:mosdns")
        t.commit()
        bad("normal 竟然放行了 —— 那道硬门形同虚设")
    except tx3.TxRefused as e:
        if "过渡状态" in str(e):
            bad("normal 仍卡在过渡状态门(而不是硬门), 说明崩溃循环还是被当成了过渡")
        else:
            ok("normal: 按硬门拒, 理由准确(不再是过渡状态): %s" % str(e)[:40])
    except Exception as e:  # noqa: BLE001
        bad("normal 抛了别的异常: %s" % type(e).__name__)

    box4 = Box(healthy=False)
    try:
        box4.crash_loop("mosdns")
        tx4 = load_tx(box4.env)
        t = tx4.Tx(source="test", op="geosite_update", mode="repair")
        t.stage("mosdns_rule:geosite_cn.txt", b"domain:a.cn\n")
        t.service("restart:mosdns")
        t.commit()
        if box4.read("/etc/mosdns/rules/geosite_cn.txt") == b"domain:a.cn\n":
            ok("repair: 崩溃重启循环的机器修得动了(规则文件真的写进去)")
        else:
            bad("repair 提交了但文件没写进去")
    except Exception as e:  # noqa: BLE001
        bad("repair 仍然救不了崩溃循环: %s %s" % (type(e).__name__, str(e)[:70]))
    finally:
        box4.clean()

    # 反方向: 真在启动中(SubState=start)必须照旧拒 —— 这道门是拆不得的, 只是分清了两种处境
    box5 = Box(healthy=False)
    try:
        box5.starting_up("mosdns")
        tx5 = load_tx(box5.env)
        t = tx5.Tx(source="test", op="geosite_update", mode="repair")
        t.stage("mosdns_rule:geosite_cn.txt", b"domain:a.cn\n")
        t.service("restart:mosdns")
        t.commit()
        bad("真在启动中也放行了 —— 那道门被拆掉了, 快照可能拍在半空中")
    except Exception as e:  # noqa: BLE001
        if "过渡状态" in str(e):
            ok("真在启动中(SubState=start)照旧拒(门没拆, 只是分清了两种处境)")
        else:
            bad("启动中被拒的理由不对: %s %s" % (type(e).__name__, str(e)[:60]))
    finally:
        box5.clean()
finally:
    box3.clean()

# ── 2. update-rules.sh 真的把模式透传下去 ────────────────────────────────────
print()
print("── 2. update-rules.sh 的模式透传 ──")
src = (ROOT / "deploy/bot/update-rules.sh").read_text(encoding="utf-8")
if re.search(r'--mode\s+"\$TXMODE"', src):
    ok("update-rules.sh 把 --mode 传给了 pdgtx")
else:
    bad("update-rules.sh 没传 --mode")
if re.search(r'TXMODE="\$\{PDG_TX_MODE:-normal\}"', src):
    ok("默认仍是 normal(日常更新不放宽)")
else:
    bad("默认模式不是 normal")

inst = (ROOT / "install.sh").read_text(encoding="utf-8")
if re.search(r"PDG_TX_MODE=repair\s+bash\s+/opt/pdg-bot/update-rules\.sh", inst):
    ok("install.sh 装机时用 repair 模式调它")
else:
    bad("install.sh 没用 repair 模式")

# ── 3. geosite 文件必须先建出来(哪怕是空的)──────────────────────────────────
print()
print("── 3. 下载失败也不该让 mosdns 起不来 ──")
m = re.search(r"for _gf in ([^\n]*); do\n\s*\[\[ -s \"/etc/mosdns/rules/\$_gf\.txt\" \]\] \|\| : >", inst)
if m:
    names = m.group(1).replace("'", "").split()
    want = {"geosite_cn", "geosite_apple", "geosite_gfw", "geosite_geolocation-!cn"}
    if want <= set(names):
        ok("装机先把 4 个 geosite 文件建成空文件(domain_set 要求文件存在)")
    else:
        bad("建的文件不全, 少了: %s" % (want - set(names)))
else:
    bad("install.sh 里没有预建 geosite 文件那一步")
# 顺序: 必须在**调用 update-rules.sh 之前**, 否则下载一失败照样缺文件
i_pre = inst.find("for _gf in geosite_cn")
i_upd = inst.find("bash /opt/pdg-bot/update-rules.sh")   # 调用点, 不是文件名的其它提及
if 0 < i_pre < i_upd:
    ok("预建发生在下载之前(下载失败也已经有文件了)")
else:
    bad("预建顺序不对: 预建 %d, 下载 %d" % (i_pre, i_upd))
# 下载失败不能中止安装
if re.search(r"if PDG_TX_MODE=repair bash /opt/pdg-bot/update-rules\.sh; then :; else", inst):
    ok("下载失败只告警, 不中止安装")
else:
    bad("下载失败仍会中止安装")
if "分类规则是空的" in inst and "更新规则库" in inst:
    ok("并如实说明了影响与补救办法")
else:
    bad("没说清影响")

# ── 4. 空的 geosite 文件确实能让 mosdns 起来 ─────────────────────────────────
print()
print("── 4. 真 mosdns: 规则文件是空的也要能起 ──")
MOSDNS = shutil.which("mosdns") or "/usr/local/bin/mosdns"
if not os.access(MOSDNS, os.X_OK):
    msg = "本段需要真 mosdns"
    if os.environ.get("PDG_TEST_STRICT") or os.environ.get("CI") == "true":
        bad(msg + " —— 严格模式判失败")
    else:
        print("[SKIP] " + msg)
else:
    d = tempfile.mkdtemp(prefix="bootrules.")
    try:
        rules = os.path.join(d, "rules")
        os.makedirs(rules)
        for leaf in ("geosite_cn", "geosite_apple", "geosite_gfw", "geosite_geolocation-!cn",
                     "custom_direct", "custom_hijack", "ruleset_hijack", "unlock", "mitm_hijack"):
            open(os.path.join(rules, leaf + ".txt"), "w").close()   # 全空
        tmpl = (ROOT / "deploy/mosdns/config.yaml").read_text(encoding="utf-8")
        cfg = (tmpl.split("  - tag: dot_server")[0]
               .replace("__SERVER_IP__", "10.9.9.9")
               .replace("__INTERNAL_CIDR__", "127.0.0.0/8")
               .replace("__MOSDNS_CACHE__", "1024")
               .replace("__HIJACK_SET_FILE__", "geosite_geolocation-!cn.txt")
               .replace("/etc/mosdns/rules/", rules + "/")
               .replace("0.0.0.0:53", "127.0.0.1:15788"))
        cf = os.path.join(d, "config.yaml")
        with open(cf, "w") as f:
            f.write(cfg)
        p = subprocess.Popen([MOSDNS, "start", "-c", cf, "-d", d],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        up = False
        for _ in range(50):
            r = subprocess.run(["dig", "+short", "+time=1", "+tries=1", "@127.0.0.1",
                                "-p", "15788", "rdy.test", "A"],
                               capture_output=True, timeout=10)
            if r.returncode == 0:
                up = True
                break
            if p.poll() is not None:
                break
            __import__("time").sleep(0.2)
        out = b""
        if not up:
            p.terminate()
            out = (p.stdout.read() or b"")[:400]
        else:
            p.terminate()
        p.wait(timeout=10)
        if up:
            ok("四个 geosite 文件全空时, 真 mosdns 照常起来并应答(网关可用, 只是分类为空)")
        else:
            bad("空规则文件起不来 mosdns: %s" % out.decode("utf-8", "replace")[:200])

        # 反向对照: 把其中一个文件**删掉**(修复前装机后的实际状态)—— 真 mosdns 必须起不来。
        # 少了这一条, 上面那句"空文件能起来"就说明不了问题: 万一 mosdns 根本不在乎这些文件,
        # 那预建空文件就是白做的。用户那台机器正是死在这里(no such file → 重启 7 次 → 回滚)。
        os.unlink(os.path.join(rules, "geosite_cn.txt"))
        p = subprocess.Popen([MOSDNS, "start", "-c", cf, "-d", d],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            rc = p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            rc = None
            p.kill()
            p.wait(timeout=5)
        log = (p.stdout.read() or b"").decode("utf-8", "replace")
        if rc not in (0, None) and "no such file" in log.lower():
            ok("缺一个规则文件 → 真 mosdns 直接退出(证实预建空文件不是白做的)")
        else:
            bad("缺文件时 mosdns 竟然没死(rc=%r): %s" % (rc, log[:200]))
    finally:
        shutil.rmtree(d, ignore_errors=True)

# ── 4b. bot 的「更新规则库」必须能解开这个死锁 ─────────────────────────────────
# 缺规则文件 → mosdns 起不来 → 硬门坏 → normal 模式拒绝写规则文件 → 越坏越修不了。
# doctor 让用户去点「更新规则库」, 那这个按钮就必须真的修得动。
print()
print("── 4b. bot「更新规则库」能不能修得动 ──")
botsrc = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
branch = botsrc.split('if data == "updgeo":', 1)[-1].split('if data.startswith("delx:")', 1)[0]
trig = re.search(r'if r\.returncode != 0 and "([^"]+)" in \(r\.stdout \+ r\.stderr\)', branch)
if not trig:
    bad("bot 没有按拒绝理由重试的分支 —— 那个按钮修不动这种机器")
elif "REFUSAL" not in dir() and not globals().get("REFUSAL"):
    bad("拿不到 pdgtx 的真实拒绝文案, 无从核对 bot 的触发条件")
elif trig.group(1) in globals()["REFUSAL"]:
    ok("bot 重试的触发词确实出现在 pdgtx 真实抛出的拒绝里(不是猜的字面量)")
else:
    bad("bot 等的是 %r, 但 pdgtx 实际说的是 %r —— 永远触发不了"
        % (trig.group(1), globals()["REFUSAL"][:60]))
if re.search(r'PDG_TX_MODE="repair"', branch):
    ok("重试时用 repair 模式")
else:
    bad("重试没用 repair 模式")
if "当时 mosdns 没在运行" in branch and "诊断" in branch:
    ok("并如实告诉用户走的是修复模式, 让他再看一眼诊断")
else:
    bad("修复模式重试后没如实告知")

# ── 5. 降级之后要有人一直提醒(装机那一行黄字滚过去就没了)────────────────────
print()
print("── 5. doctor 认不认『规则库是空的』 ──")
spec = importlib.util.spec_from_file_location("pdgchecks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

d5 = tempfile.mkdtemp(prefix="geodb.")
try:
    checks.GEOSITE_DIR = d5
    names = ("geosite_cn.txt", "geosite_apple.txt", "geosite_gfw.txt",
             "geosite_geolocation-!cn.txt")

    for n in names:                                   # 下载失败后的样子: 都在, 都是空的
        open(os.path.join(d5, n), "w").close()
    r = checks.check_geosite_db()
    if r and r[0] == "warn" and "空" in r[2]:
        ok("全空 → warn 并说清后果(%s)" % r[2][:28])
    else:
        bad("全空时判定不对: %r" % (r,))

    with open(os.path.join(d5, "geosite_cn.txt"), "w") as f:   # 部分成功
        f.write("domain:example.cn\n")
    r = checks.check_geosite_db()
    if r and r[0] == "warn" and "geosite_apple.txt" in r[2] and "geosite_cn.txt" not in r[2]:
        ok("部分为空 → 只点名空的那几个, 不误伤有内容的")
    else:
        bad("部分为空时判定不对: %r" % (r,))

    for n in names[1:]:                               # 全都有内容
        with open(os.path.join(d5, n), "w") as f:
            f.write("domain:a.test\ndomain:b.test\n")
    r = checks.check_geosite_db()
    if r and r[0] == "ok" and "7" in r[2]:
        ok("规则齐全 → ok 并报出条数(%s)" % r[2])
    else:
        bad("齐全时判定不对: %r" % (r,))

    os.unlink(os.path.join(d5, "geosite_gfw.txt"))    # 缺文件比空文件更要紧
    r = checks.check_geosite_db()
    if r and r[0] == "fail" and "geosite_gfw.txt" in r[2]:
        ok("缺文件 → fail(mosdns 下次重启会起不来, 不能只是 warn)")
    else:
        bad("缺文件时判定不对: %r" % (r,))

    checks.GEOSITE_DIR = os.path.join(d5, "nope")     # 没装 mosdns
    if checks.check_geosite_db() is None:
        ok("没有 mosdns 规则目录 → 这项不适用, 不刷屏")
    else:
        bad("没装 mosdns 时不该报这项")
finally:
    shutil.rmtree(d5, ignore_errors=True)

if checks.check_geosite_db in checks.ALL:
    ok("已挂进 doctor 的检查清单(不然写了也跑不到)")
else:
    bad("没挂进 checks.ALL")

print("────────────────────────────────────────")
print("通过 %d, 失败 %d" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)

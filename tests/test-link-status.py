#!/usr/bin/env python3
"""6.1A 采集器: 证书七种情形、分层归因、只读纪律。

判据都落在**真实产物**上: 用 openssl 真签出正常/临期/过期/错域名的证书, 真造损坏文件与
"证书位置放的其实是私钥"这种现场, 再看采集器给出的 code 与 status。不打桩 openssl ——
打了就等于在测我自己写的桩。

只读纪律这一节尤其要紧: `pdg link status` 是给"出事了想看看"的人用的, 它自己再去写文件、
抢锁、开事务, 就会在最不该添乱的时候添乱。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
import linkstat as L  # noqa: E402
import checks  # noqa: E402

PASS_N = [0]
FAIL_N = [0]
TMPS = []


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def skip(m):
    print("[SKIP] %s" % m)


def have_openssl():
    return shutil.which("openssl") is not None


def gen_cert(d, cn, days):
    """真签一张证书。days > 0 走 `openssl req -x509 -days`。"""
    key = os.path.join(d, "k.pem")
    crt = os.path.join(d, "c.pem")
    r = subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", crt, "-days", str(days), "-subj", "/CN=%s" % cn],
        capture_output=True, text=True, timeout=90)
    if r.returncode != 0 or not os.path.exists(crt):
        return None, None, (r.stderr or "")[-160:]
    return crt, key, ""


def gen_expired_cert(d, cn):
    """签一张**已经过期**的证书。

    `openssl req -x509` 给不了过去的日期: -days 只收正数, -not_after 要 3.5+ 才有(本机
    3.0.20 不认)。所以走 `openssl ca -selfsign` —— 它有 -startdate/-enddate, 能明确指定
    一段已经过去的区间。需要一个最小 CA 配置 + index/serial, 一并在临时目录里造。
    """
    key = os.path.join(d, "k.pem")
    csr = os.path.join(d, "r.csr")
    crt = os.path.join(d, "expired.pem")
    cnf = os.path.join(d, "ca.cnf")
    for name in ("index.txt",):
        open(os.path.join(d, name), "w").close()
    open(os.path.join(d, "serial"), "w").write("01\n")
    open(cnf, "w").write(
        "[ca]\ndefault_ca = CA_default\n"
        "[CA_default]\n"
        "dir = %s\ndatabase = $dir/index.txt\nserial = $dir/serial\n"
        "new_certs_dir = $dir\ndefault_md = sha256\npolicy = pol\n"
        "email_in_dn = no\nunique_subject = no\n"
        "[pol]\ncommonName = supplied\n" % d)
    r = subprocess.run(
        ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
         "-keyout", key, "-out", csr, "-subj", "/CN=%s" % cn],
        capture_output=True, text=True, timeout=90)
    if r.returncode != 0:
        return None, (r.stderr or "")[-160:]
    start = time.strftime("%Y%m%d%H%M%SZ", time.gmtime(time.time() - 86400 * 60))
    end = time.strftime("%Y%m%d%H%M%SZ", time.gmtime(time.time() - 86400 * 5))
    r = subprocess.run(
        ["openssl", "ca", "-selfsign", "-batch", "-notext", "-config", cnf,
         "-keyfile", key, "-in", csr, "-out", crt,
         "-startdate", start, "-enddate", end],
        capture_output=True, text=True, timeout=90)
    if r.returncode != 0 or not os.path.exists(crt):
        return None, (r.stderr or "")[-200:]
    return crt, ""


def main():
    if not have_openssl():
        skip("本环境没有 openssl, 证书用例无法真签 —— 不伪造通过")
        print("─" * 40); print("通过 0, 失败 0"); print("零断言 —— 判失败")
        return 1

    d = tempfile.mkdtemp(prefix="linkstat-cert.")
    TMPS.append(d)

    print("── 1. 证书有效期: 正常 / 临期 / 过期 ──")
    for name, days, want_code, want_status in (
            ("正常(365 天)", 365, None, None),
            ("临期(7 天)", 7, "L5_CERT_EXPIRING", L.WARN),
            ("已过期", -5, "L5_CERT_EXPIRED", L.FAIL)):
        sub = tempfile.mkdtemp(prefix="c.", dir=d)
        if days >= 0:
            crt, _key, err = gen_cert(sub, "dot.example", days)
        else:
            crt, err = gen_expired_cert(sub, "dot.example")
        if not crt:
            skip("%s 签发失败, 该情形未验: %s" % (name, err)); continue
        ts, cn, why = L._cert_not_after(crt)
        if ts is None:
            bad("%s: 读不出到期时间(%s)" % (name, why)); continue
        left = int((ts - time.time()) // 86400)
        if want_code is None:
            (ok if left > L.CERT_EXPIRING_DAYS else bad)(
                "%s → 剩 %d 天, 不触发临期/过期" % (name, left))
        elif want_code == "L5_CERT_EXPIRING":
            (ok if 0 <= left < L.CERT_EXPIRING_DAYS else bad)(
                "%s → 剩 %d 天, 落在临期窗口(<%d)" % (name, left, L.CERT_EXPIRING_DAYS))
        else:
            (ok if left < 0 else bad)("%s → 剩 %d 天(负数=已过期)" % (name, left))

    print()
    print("── 2. 读不出来的三种: 损坏 / 空 / 位置放的是私钥 ──")
    bads = {}
    p = os.path.join(d, "broken.pem"); open(p, "w").write("-----BEGIN CERTIFICATE-----\nnot base64\n")
    bads["损坏证书"] = p
    p = os.path.join(d, "empty.pem"); open(p, "w").write("")
    bads["空文件"] = p
    crt, key, err = gen_cert(os.path.join(d, "kk") if os.makedirs(os.path.join(d, "kk"), exist_ok=True) is None else d,
                             "dot.example", 365)
    if key:
        bads["证书位置放的其实是私钥"] = key
    for name, path in bads.items():
        ts, cn, why = L._cert_not_after(path)
        (ok if ts is None else bad)("%s → 解析失败(采集器会判 FAIL)" % name)
        if name == "证书位置放的其实是私钥":
            # 关键: 报错里不许带私钥正文
            if "PRIVATE KEY" in (why or "") or "MII" in (why or ""):
                bad("私钥正文漏进了错误信息: %s" % (why or "")[:60])
            else:
                ok("私钥文件的报错里没有私钥正文")

    print()
    print("── 3. 主机名不匹配 ──")
    crt, _k, err = gen_cert(tempfile.mkdtemp(prefix="cn.", dir=d), "wrong.example", 365)
    if crt:
        _ts, cn, _ = L._cert_not_after(crt)
        (ok if cn == "wrong.example" else bad)("能取到证书 CN: %s" % cn)
        # CN 与 DoT 主机名不同 → 采集器该判 L5_CERT_CN_MISMATCH。这里验判据本身:
        (ok if cn != "dot.example" else bad)("CN 与配置的 DoT 主机名不同 → 应判不匹配")
    else:
        skip("错域名证书签发失败: %s" % err)

    print()
    print("── 3b. 采集器的分支判定(不是只测 _cert_not_after) ──")
    # 上一节验的是"能不能读出到期时间"; 这一节验**采集器据此给了什么 code** ——
    # 少了这一节, 把 _l5_tls 里的过期/临期分支整个删掉, 上一节照样全绿。
    import types
    _orig_cert_path = checks._cert_path
    _orig_dot_file = checks._dot_file
    for name, days, want in (("正常", 365, set()),
                             ("临期", 7, {"L5_CERT_EXPIRING"}),
                             ("已过期", -5, {"L5_CERT_EXPIRED"})):
        sub = tempfile.mkdtemp(prefix="b.", dir=d)
        crt = (gen_cert(sub, "dot.example", days)[0] if days >= 0
               else gen_expired_cert(sub, "dot.example")[0])
        if not crt:
            skip("%s 证书没造出来, 分支判定未验" % name); continue
        checks._cert_path = lambda _c=crt: _c
        checks._dot_file = lambda: "dot.example"
        try:
            codes = {f["code"] for f in L._l5_tls({"platform": "android"})}
        finally:
            checks._cert_path, checks._dot_file = _orig_cert_path, _orig_dot_file
        got = codes & {"L5_CERT_EXPIRING", "L5_CERT_EXPIRED"}
        (ok if got == want else bad)(
            "%s 证书 → 采集器给出 %s(期望 %s)" % (name, sorted(got) or "无", sorted(want) or "无"))
    # 主机名不匹配也要由采集器判出来
    sub = tempfile.mkdtemp(prefix="b2.", dir=d)
    crt = gen_cert(sub, "wrong.example", 365)[0]
    if crt:
        checks._cert_path = lambda _c=crt: _c
        checks._dot_file = lambda: "dot.example"
        try:
            codes = {f["code"] for f in L._l5_tls({"platform": "android"})}
        finally:
            checks._cert_path, checks._dot_file = _orig_cert_path, _orig_dot_file
        (ok if "L5_CERT_CN_MISMATCH" in codes else bad)(
            "CN 不符 → 采集器给出 L5_CERT_CN_MISMATCH(实得 %s)" % sorted(codes))

    print()
    print("── 3e. 同一个根因不许报两遍, 但独立的握手故障不许被吞 ──")
    # 背景: CN 不符时曾经同时冒出 L5_CERT_CN_MISMATCH 和 L5_TLS_HANDSHAKE_FAILED。
    # 两条都属实, 可对用户是同一件事说了两遍 —— 而且通用那条没有任何可执行信息。
    # 规则: 有更具体的证书 FAIL 时, 通用条目不单独出现; 没有时, 它必须照常出现。
    def l5_with(crt, dot):
        checks._cert_path = lambda _c=crt: _c
        checks._dot_file = lambda _d=dot: _d
        try:
            return L._l5_tls({"platform": "android"})
        finally:
            checks._cert_path, checks._dot_file = _orig_cert_path, _orig_dot_file

    sub = tempfile.mkdtemp(prefix="c1.", dir=d)
    crt_bad_cn = gen_cert(sub, "wrong.example", 365)[0]
    if crt_bad_cn:
        fs5 = l5_with(crt_bad_cn, "dot.example")
        codes = [f["code"] for f in fs5 if f["status"] == L.FAIL]
        (ok if "L5_CERT_CN_MISMATCH" in codes else bad)(
            "CN 不符时保留了更具体的 L5_CERT_CN_MISMATCH")
        (ok if "L5_TLS_HANDSHAKE_FAILED" not in codes else bad)(
            "同时不再冒出通用的 L5_TLS_HANDSHAKE_FAILED(实得 %s)" % codes)
        (ok if len(codes) == 1 else bad)(
            "第 5 层只给出 1 条 FAIL, 不是同一根因两条(实得 %d 条: %s)" % (len(codes), codes))
        # 不是吞掉 —— 观察到的握手现象要留在那条具体结论的证据里
        mm = [f for f in fs5 if f["code"] == "L5_CERT_CN_MISMATCH"]
        (ok if mm and "853" in mm[0]["evidence_source"] else bad)(
            "握手现象并进了具体结论的证据, 没有丢失(evidence=%s)"
            % (mm[0]["evidence_source"] if mm else "?"))

    # 反面: 证书本身没问题时, 独立的握手/端口故障必须照常报出来
    sub = tempfile.mkdtemp(prefix="c2.", dir=d)
    crt_ok = gen_cert(sub, "dot.example", 365)[0]
    if crt_ok:
        codes = [f["code"] for f in l5_with(crt_ok, "dot.example") if f["status"] == L.FAIL]
        (ok if "L5_TLS_HANDSHAKE_FAILED" in codes else bad)(
            "证书没毛病时, 独立的握手故障照常报出(实得 %s)" % codes)

    # 边界: 临期是 WARN 不是 FAIL —— 它解释不了握手为什么不通, 通用条目仍须出现
    sub = tempfile.mkdtemp(prefix="c3.", dir=d)
    crt_soon = gen_cert(sub, "dot.example", 7)[0]
    if crt_soon:
        fs5 = l5_with(crt_soon, "dot.example")
        cs = [f["code"] for f in fs5]
        (ok if "L5_CERT_EXPIRING" in cs and "L5_TLS_HANDSHAKE_FAILED" in cs else bad)(
            "临期(WARN)不算「更具体的原因」, 握手故障仍单独报出(实得 %s)" % cs)

    print()
    print("── 3c. nft 那层必须真读内核, 不能只读磁盘 ──")
    # 把"读内核"这一步换成读不到, 采集器就该判 L8_NFT_DRIFT。若它只读磁盘, 这里会照常 PASS。
    # 两头都要证:
    #   a) 采集器**真的发出过**向内核要 ruleset 的那条命令(只读磁盘的实现发不出);
    #   b) 那条命令失败时状态是 FAIL —— L8_NFT_DRIFT 这个 code 在 PASS 分支里也用,
    #      只查 code 在不在会放过"改成读磁盘所以两边永远相同"这种实现。
    _orig_run = checks._run
    seen = []
    def _fake_run(cmd, t=10):
        seen.append(list(cmd))
        if cmd[:2] == ["nft", "list"] and "table" in cmd:
            return 1, "", "no kernel table"
        return _orig_run(cmd, t)
    checks._run = _fake_run
    try:
        nftf = [f for f in L._l8_services({"platform": "android"}) if f["code"] == "L8_NFT_DRIFT"]
    finally:
        checks._run = _orig_run
    kern_q = [c for c in seen if c[:2] == ["nft", "list"] and "table" in c and "pdg" in c]
    (ok if kern_q else bad)(
        "采集器向内核查了 ruleset(实发命令: %s)" % (kern_q[0] if kern_q else "一条都没有"))
    (ok if nftf and nftf[0]["status"] == L.FAIL else bad)(
        "内核读不到 inet pdg → L8_NFT_DRIFT/FAIL(实得 %s)"
        % [(f["status"], f["code"]) for f in nftf])

    print()
    print("── 3d. 模块进了单一真源, 两平台都装 ──")
    mods = (ROOT / "lib/modules.sh").read_text(encoding="utf-8")
    rt = mods.split("PDG_RUNTIME_MODULES=")[1].split("PDG_IOS_MODULES=")[0] \
        if "PDG_RUNTIME_MODULES=" in mods else ""
    (ok if "linkstat.py" in rt else bad)(
        "linkstat.py 在 PDG_RUNTIME_MODULES 里(install/update/uninstall 同一份清单)")

    print()
    print("── 4. 输出里没有私钥与敏感哨兵 ──")
    SENT = "123456789:AAHlinkSENTINELtoken0000000000000000"
    findings = L.collect(platform="android")
    blob = "\n".join("%s|%s|%s" % (f["title"], f["detail"], f["next_step"]) for f in findings)
    blob += "\n" + L.render_text(findings)
    leaks = [w for w in ("PRIVATE KEY", "BEGIN RSA", SENT) if w in blob]
    (ok if not leaks else bad)("采集与渲染结果里无私钥/哨兵" if not leaks else "泄漏: %s" % leaks)

    print()
    print("── 5. 分层归因: 服务异常 vs 配置漂移 不能混 ──")
    by_code = {f["code"]: f for f in findings}
    svc_codes = {"L8_SERVICES_READY", "L8_MOSDNS_DOWN", "L8_MIHOMO_DOWN"}
    cfg_codes = {"L2_CIDR_READY", "L2_CIDR_DRIFT"}
    got_svc = svc_codes & set(by_code)
    got_cfg = cfg_codes & set(by_code)
    (ok if got_svc else bad)("服务层有结论: %s" % (sorted(got_svc) or "无"))
    (ok if got_cfg else bad)("配置层有结论: %s" % (sorted(got_cfg) or "无"))
    for c in got_svc:
        (ok if by_code[c]["layer"] == 8 else bad)("%s 落在第 8 层" % c)
    for c in got_cfg:
        (ok if by_code[c]["layer"] == 2 else bad)("%s 落在第 2 层" % c)

    print()
    print("── 6. 私网实时层永远 NOT_OBSERVED, 且不影响退出码 ──")
    phone = [f for f in findings if f["layer"] in L.PHONE_LAYERS]
    (ok if phone else bad)("有私网实时层条目")
    if phone and all(f["status"] == L.NOT_OBSERVED for f in phone):
        ok("私网实时层全部是 NOT_OBSERVED(%d 条)" % len(phone))
    else:
        bad("私网层状态不对: %r" % [f["status"] for f in phone])
    # 造一个"私网层 FAIL"的畸形输入, 退出码也不该因此非零 —— 私网层不参与服务器就绪判定
    fake = list(phone) + [L.Finding(2, "L2_CIDR_READY", L.PASS, None, "t", "d", "e")]
    (ok if L.exit_code(fake) == 0 else bad)("只有 NOT_OBSERVED + PASS → 退出码 0")

    print()
    print("── 7. 只读纪律: 不写文件 / 不开事务 / 不取全局写锁 ──")
    # 全局锁: 判据要**两头都成立**才有意义 —— 先证明这把锁真能挡住写路径(pdgtx 会 TxBusy),
    # 再证明 collect() 在同样条件下照常完成。只做后者的话, 锁没生效也一样"通过"。
    import fcntl
    lockdir = tempfile.mkdtemp(prefix="linklock."); TMPS.append(lockdir)
    lockp = os.path.join(lockdir, "pdg.lock")
    held = open(lockp, "w")
    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.environ["PDG_LOCKFILE"] = lockp
    blocked = False
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "pdgtx_lock_probe", ROOT / "deploy/bot/pdgtx.py")
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        try:
            with m._Lock(lockp):
                pass
        except Exception as e:  # noqa: BLE001
            blocked = type(e).__name__ == "TxBusy"
    except Exception as e:  # noqa: BLE001
        skip("装载 pdgtx 失败(%s), 锁有效性未证" % type(e).__name__)
    (ok if blocked else bad)("前提成立: 这把锁被占用时, 走事务的写路径会 TxBusy")
    # 用子进程 + 超时跑: 万一它真去抢锁, 会**快速判红**而不是把整个测试挂死等到超时。
    t0 = time.time()
    try:
        probe = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, %r); import linkstat as L; "
             "print(len(L.collect(platform='android')))" % str(ROOT / "deploy/bot")],
            capture_output=True, text=True, timeout=60,
            env=dict(os.environ, PDG_LOCKFILE=lockp))
        good = probe.returncode == 0 and probe.stdout.strip().isdigit()
        detail = "rc=%d" % probe.returncode
    except subprocess.TimeoutExpired:
        good, detail = False, "60s 没返回 —— 卡在这把锁上了"
    dt = time.time() - t0
    (ok if good else bad)(
        "同样条件下 collect() 照常完成 —— 它不去抢这把锁(%s)" % detail)
    try:
        fcntl.flock(held, fcntl.LOCK_UN); held.close()
    except OSError:
        pass
    (ok if dt < 60 else bad)("采集在 %.1fs 内完成(没有卡在锁上)" % dt)

    # 事务与状态文件: 采集前后不许多出任何东西。
    #
    # 直接在开发机上 listdir("/var/lib/privdns-gateway") 是**空转**的 —— 这台机器上它
    # 根本不存在, 比的是空集对空集; 真去写的实现会撞 PermissionError 而不是被判据抓住,
    # 换成 root 跑就漏了。所以进 mount namespace, 拿 tmpfs 把 /var/lib 和 /run 铺成真实
    # 可写的目录, 再看采集前后多出什么 —— 这样"没写"是证出来的, 不是写不进去。
    probe_src = r"""
import json, os, sys
sys.path.insert(0, %r)
os.makedirs("/var/lib/privdns-gateway/tx", exist_ok=True)
def walk():
    seen = []
    for root in ("/var/lib/privdns-gateway", "/run"):
        for dp, dn, fn in os.walk(root):
            for x in dn + fn:
                seen.append(os.path.join(dp, x))
    return sorted(seen)
before = walk()
import linkstat as L
L.collect(platform="android")
L.collect(platform="ios")
print(json.dumps({"new": sorted(set(walk()) - set(before))}))
""" % str(ROOT / "deploy/bot")
    probe_py = os.path.join(tempfile.mkdtemp(prefix="nsprobe.", dir=d), "probe.py")
    with open(probe_py, "w", encoding="utf-8") as fh:
        fh.write(probe_src)
    ns = subprocess.run(
        ["unshare", "-rm", "--", "sh", "-c",
         "mount -t tmpfs none /var/lib && mount -t tmpfs none /run && exec \"$1\" \"$2\"",
         "sh", sys.executable, probe_py],
        capture_output=True, text=True, timeout=180)
    if ns.returncode != 0:
        skip("进不去 mount namespace(%s), 写入探针未跑"
             % (ns.stderr.strip().splitlines() or ["?"])[-1][:70])
    else:
        made = json.loads(ns.stdout.strip().splitlines()[-1])["new"]
        (ok if not made else bad)(
            "namespace 里 /var/lib/privdns-gateway 与 /run 可写, 采集后仍无新文件: 多出 %s"
            % (made or "无"))

    # 同一个 namespace 的反向前提: 往那两个目录写是**能成功**的(否则上一条不成立)
    ns2 = subprocess.run(
        ["unshare", "-rm", "--", "sh", "-c",
         "mount -t tmpfs none /var/lib && mkdir -p /var/lib/privdns-gateway && "
         "echo x > /var/lib/privdns-gateway/probe && echo WRITABLE"],
        capture_output=True, text=True, timeout=60)
    (ok if "WRITABLE" in ns2.stdout else bad)(
        "前提成立: 那个 namespace 里确实写得进去(否则上一条是空转)")

    print()
    print("── 8. 受管文件的内容/mode/uid/gid/mtime 一律不变 ──")
    watch = [checks.PROFILE_ENV, checks.MOSDNS_CONF, "/etc/nftables.conf",
             checks.PLATFORM_FILE]
    snap = {}
    for p in watch:
        try:
            st = os.stat(p)
            snap[p] = (open(p, "rb").read(), st.st_mode, st.st_uid, st.st_gid, st.st_mtime_ns)
        except OSError:
            continue
    if not snap:
        skip("本环境没有受管配置文件, 该节未验(真机/沙箱里会有)")
    else:
        L.collect(platform="android")
        changed = []
        for p, want in snap.items():
            try:
                st = os.stat(p)
                got = (open(p, "rb").read(), st.st_mode, st.st_uid, st.st_gid, st.st_mtime_ns)
            except OSError:
                changed.append(p + "(消失)"); continue
            if got != want:
                changed.append(p)
        (ok if not changed else bad)(
            "%d 个受管文件的内容/mode/uid/gid/mtime 全未变" % len(snap)
            if not changed else "这些被动过: %s" % ", ".join(changed))

    print("─" * 40)
    total = PASS_N[0] + FAIL_N[0]
    print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
    for t in TMPS:
        shutil.rmtree(t, ignore_errors=True)
    if total == 0:
        print("零断言 —— 判失败")
        return 1
    return 1 if FAIL_N[0] else 0


if __name__ == "__main__":
    sys.exit(main())

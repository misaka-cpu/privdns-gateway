#!/usr/bin/env python3
"""6.1B 阶段 2: 一次性会话模型 + :81 的 HTTP 入口。

这支测试盯两类东西:

  A. 会话本身的约束(token 强度、TTL、单次消费、尝试上限、隐私边界);
  B. **root 与 DynamicUser 之间的文件交接** —— 这是最容易翻车的地方: root 建的
     会话文件默认是 root:root 0600, 而 pdg-probe81 跑在动态 UID 下, 读都读不到。
     判据要求真的用两个不同 UID 跑一遍, 不是看代码里有没有 chown。

硬约束单列一条: 无论会话怎么坏(状态写不了、文件损坏、token 过期), 普通 `/` 探测
都必须照样返回 200 —— iOS 的 OnDemand 只认这个。
"""
import hashlib
import json
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy/bot"))
sys.path.insert(0, str(ROOT / "deploy/ios"))

PASS_N = [0]
FAIL_N = [0]
TMPS = []


def ok(m):
    print("[OK]   %s" % m); PASS_N[0] += 1


def bad(m):
    print("[FAIL] %s" % m); FAIL_N[0] += 1


def skip(m):
    print("[SKIP] %s" % m)


def fresh_dir():
    d = tempfile.mkdtemp(prefix="linksess."); TMPS.append(d)
    os.environ["PDG_PROBE81_RUNTIME_DIR"] = d
    return d


def main():
    import linksess as S

    print("── 1. token 强度与形状 ──")
    d = fresh_dir()
    tok, rec = S.new_session()
    (ok if len(tok) == 43 else bad)("token 长度 43(token_urlsafe(32))：实得 %d" % len(tok))
    # urlsafe base64: 每字符 6 bit, 43 字符 → 258 bit 编码空间, 熵是 32 字节 = 256 bit
    (ok if S.TOKEN_BYTES * 8 >= 128 else bad)(
        "token 熵 %d bit ≥ 128" % (S.TOKEN_BYTES * 8))
    (ok if S.TOKEN_RE.match(tok) else bad)("token 落在允许的字符集里")
    toks = {S.new_session()[0] for _ in range(200)}
    (ok if len(toks) == 200 else bad)("200 次生成无重复(实得 %d 个不同)" % len(toks))

    print()
    print("── 2. 状态里没有 token 原文 ──")
    S.write_state(rec)
    raw = open(S._state_path(), encoding="utf-8").read()
    (ok if tok not in raw else bad)("状态文件里搜不到 token 原文")
    (ok if rec["token_sha256"] == hashlib.sha256(tok.encode()).hexdigest() else bad)(
        "存的是 sha256 摘要")
    (ok if "token" not in json.loads(raw) else bad)("没有名为 token 的明文字段")

    print()
    print("── 3. TTL 5 分钟, 过期即失效 ──")
    (ok if S.TTL_SECS == 300 else bad)("TTL = %ds" % S.TTL_SECS)
    (ok if abs((rec["expires_at"] - rec["created_at"]) - 300) < 1 else bad)(
        "会话记录里的有效期确实是 300s")
    d = fresh_dir()
    tok3, rec3 = S.new_session(); S.write_state(rec3)
    acc, why, _ = S.consume(tok3, "10.20.30.40", now=rec3["expires_at"] + 1)
    (ok if not acc and why == S.R_SESSION_EXPIRED else bad)(
        "过期后消费 → 拒绝 + SESSION_EXPIRED(实得 %s/%s)" % (acc, why))
    st = S.status(now=rec3["expires_at"] + 1)
    (ok if st["active"] is False and st["reason"] == S.R_SESSION_EXPIRED else bad)(
        "status 里也标成过期")

    print()
    print("── 4. 单次消费 ──")
    d = fresh_dir()
    tok4, rec4 = S.new_session(); S.write_state(rec4)
    a1, w1, _ = S.consume(tok4, "10.20.30.40")
    a2, w2, _ = S.consume(tok4, "10.20.30.40")
    (ok if a1 and w1 == S.R_OK else bad)("第一次消费成功(%s/%s)" % (a1, w1))
    (ok if not a2 and w2 == S.R_TOKEN_REUSED else bad)(
        "第二次消费被拒 + TOKEN_REUSED(实得 %s/%s)" % (a2, w2))
    # 消费成功后**不能**立刻把整场会话删掉 —— DNS 那半边还没观测
    r5, _ = S.read_state()
    (ok if r5 is not None and r5["state"] == "http_seen" else bad)(
        "消费后会话仍在, 状态转为 http_seen(留给 DNS 观测)")

    print()
    print("── 5. 无效尝试最多 3 次 ──")
    d = fresh_dir()
    tok5, rec5 = S.new_session(); S.write_state(rec5)
    wrong = "A" * 43
    results = [S.consume(wrong, "10.20.30.40")[1] for _ in range(5)]
    n_invalid = results.count(S.R_TOKEN_INVALID)
    n_limited = results.count(S.R_RATE_LIMITED)
    (ok if n_invalid == 3 and n_limited == 2 else bad)(
        "前 3 次 TOKEN_INVALID, 之后 RATE_LIMITED(实得 %s)" % results)
    # 打满之后, 连**正确**的 token 也不再被接受
    a6, w6, _ = S.consume(tok5, "10.20.30.40")
    (ok if not a6 and w6 == S.R_RATE_LIMITED else bad)(
        "尝试打满后正确 token 也被拒(实得 %s/%s)" % (a6, w6))

    print()
    print("── 6. 用的是 hmac.compare_digest, 不是 == ──")
    src = (ROOT / "deploy/bot/linksess.py").read_text(encoding="utf-8")
    (ok if "hmac.compare_digest" in src else bad)("比对走 hmac.compare_digest")
    m = re.search(r"if not hmac\.compare_digest\(digest, rec\.get\(\"token_sha256\"", src)
    (ok if m else bad)("摘要比对这一处确实用了它(不是别处顺手 import)")

    print()
    print("── 7. 同时最多 1 个会话, 新的让旧的失效 ──")
    d = fresh_dir()
    told, recold = S.new_session(); S.write_state(recold)
    tnew, recnew = S.new_session(); S.write_state(recnew)
    a_old, w_old, _ = S.consume(told, "10.20.30.40")
    (ok if not a_old else bad)("旧 token 在新会话建立后失效(实得 %s/%s)" % (a_old, w_old))
    a_new, w_new, _ = S.consume(tnew, "10.20.30.40")
    (ok if a_new and w_new == S.R_OK else bad)("新 token 可用(%s/%s)" % (a_new, w_new))

    print()
    print("── 8. 来源只落 /16 与布尔, 不落完整 IP ──")
    d = fresh_dir()
    os.environ["PDG_PROFILE_ENV"] = os.path.join(d, "profile.env")
    open(os.environ["PDG_PROFILE_ENV"], "w").write("PDG_INTERNAL_CIDR=10.20.0.0/16\n")
    tok8, rec8 = S.new_session(); S.write_state(rec8)
    S.consume(tok8, "10.20.33.44")
    raw = open(S._state_path(), encoding="utf-8").read()
    (ok if "10.20.33.44" not in raw else bad)("状态里搜不到完整 IP")
    (ok if "33.44" not in raw else bad)("后两段也没留下")
    (ok if "10.20.0.0/16" in raw else bad)("只留了 /16 前缀")
    (ok if '"inside_internal_cidr": true' in raw.replace("True", "true") else bad)(
        "记了 inside_internal_cidr 布尔")
    # /24 明确不许出现
    (ok if not re.search(r"10\.20\.33\.0/24", raw) else bad)("没有落 /24")
    # 段外来源
    d = fresh_dir()
    os.environ["PDG_PROFILE_ENV"] = os.path.join(d, "profile.env")
    open(os.environ["PDG_PROFILE_ENV"], "w").write("PDG_INTERNAL_CIDR=10.20.0.0/16\n")
    tok8b, rec8b = S.new_session(); S.write_state(rec8b)
    S.consume(tok8b, "192.168.9.9")
    r8b, _ = S.read_state()
    (ok if r8b["source"]["inside_internal_cidr"] is False else bad)(
        "段外来源 → inside_internal_cidr=False")
    (ok if r8b["source"]["ipv4_16"] == "192.168.0.0/16" else bad)(
        "段外来源也只留 /16(实得 %s)" % r8b["source"]["ipv4_16"])
    os.environ.pop("PDG_PROFILE_ENV", None)

    print()
    print("── 9. 状态损坏 fail-closed ──")
    for name, blob in (("非 JSON", "{{{ not json"),
                       ("schema 不符", '{"schema_version": 99}'),
                       ("缺字段", '{"schema_version": 1}'),
                       ("超大", '{"schema_version": 1, "x": "' + "A" * 9000 + '"}')):
        d = fresh_dir()
        open(S._state_path(), "w").write(blob)
        rec9, why9 = S.read_state()
        (ok if rec9 is None and why9 == S.R_STATE_CORRUPT else bad)(
            "%s → fail-closed STATE_CORRUPT(实得 %s)" % (name, why9))
    # 符号链接不许穿透
    d = fresh_dir()
    target = os.path.join(d, "elsewhere.json")
    open(target, "w").write('{"schema_version": 1, "session_id": "x", "token_sha256": "y",'
                            ' "created_at": 0, "expires_at": 9e9, "state": "waiting"}')
    os.symlink(target, S._state_path())
    rec9, why9 = S.read_state()
    (ok if rec9 is None and why9 == S.R_STATE_CORRUPT else bad)(
        "状态文件是符号链接 → 拒绝(实得 %s)" % why9)
    # 硬链接(nlink>1)同理
    d = fresh_dir()
    tokh, rech = S.new_session(); S.write_state(rech)
    os.link(S._state_path(), os.path.join(d, "hard.json"))
    rec9, why9 = S.read_state()
    (ok if rec9 is None and why9 == S.R_STATE_CORRUPT else bad)(
        "状态文件被硬链接 → 拒绝(实得 %s)" % why9)

    print()
    print("── 10. 动态 UID 换过之后不误读旧会话 ──")
    d = fresh_dir()
    tok10, rec10 = S.new_session()
    rec10["owner_uid"] = (os.stat(d).st_uid + 4242)      # 冒充"上一任动态 UID"
    S.write_state(rec10)
    r10, w10 = S.read_state()
    (ok if r10 is None and w10 == S.R_STATE_CORRUPT else bad)(
        "owner_uid 与当前 RuntimeDirectory 属主不符 → 不认(实得 %s)" % w10)

    print()
    print("── 11. HTTP 入口: 只认精确路径与恰好一个 t ──")
    d = fresh_dir()
    import probe81
    tok11, rec11 = S.new_session(); S.write_state(rec11)
    srv = HTTPServer(("127.0.0.1", 0), probe81.H)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
    try:
        def get(path):
            import urllib.request
            with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path),
                                        timeout=5) as r:
                return r.status, r.read()

        code, body = get("/")
        (ok if code == 200 and body == b"ok" else bad)(
            "普通 / 仍返回 200 + ok(iOS OnDemand 依赖这个): %s %r" % (code, body))
        for p, why in (("/probe", "没有 t"),
                       ("/probe?t=", "空 t"),
                       ("/probe?t=%s&t=%s" % (tok11, tok11), "两个 t"),
                       ("/probe?t=%s&x=1" % tok11, "多余参数"),
                       ("/probe/", "路径带尾斜杠"),
                       ("/PROBE?t=%s" % tok11, "路径大小写不符"),
                       ("/probe?t=short", "token 形状不合法"),
                       ("/anything", "未知路径")):
            code, body = get(p)
            (ok if code == 200 else bad)("%s → 仍 200(%s)" % (why, code))
        # 上面那一串都不该消费掉会话
        r11, _ = S.read_state()
        (ok if r11 is not None and r11["http_consumed_at"] is None else bad)(
            "以上非法/无关请求都没有产生成功事件")
        code, body = get("/probe?t=%s" % tok11)
        (ok if code == 200 and b"ok" in body else bad)("合法请求 → 200 + probe: ok")
        r11, _ = S.read_state()
        (ok if r11["http_consumed_at"] is not None else bad)("这一次才产生成功事件")
        code, body = get("/probe?t=%s" % tok11)
        (ok if code == 200 and b"already used" in body else bad)(
            "重放 → 仍 200, 文案说明已用过: %r" % body)
    finally:
        srv.shutdown(); srv.server_close(); th.join(timeout=5)

    print()
    print("── 12. 不读也不信任 X-Forwarded-For ──")
    p81 = (ROOT / "deploy/ios/probe81.py").read_text(encoding="utf-8")
    (ok if "X-Forwarded-For" not in p81.replace("**不读也不信任 X-Forwarded-For**", "")
        .replace("不读也不信任 X-Forwarded-For", "") else bad)(
        "probe81.py 里除注释外不出现 X-Forwarded-For")
    (ok if "self.headers" not in p81 else bad)("根本没碰 self.headers")
    (ok if "client_address" in p81 else bad)("来源取自 client_address(内核 peer)")
    # 真发一个伪造头, 看它有没有被采信
    d = fresh_dir()
    os.environ["PDG_PROFILE_ENV"] = os.path.join(d, "profile.env")
    open(os.environ["PDG_PROFILE_ENV"], "w").write("PDG_INTERNAL_CIDR=10.20.0.0/16\n")
    tok12, rec12 = S.new_session(); S.write_state(rec12)
    srv = HTTPServer(("127.0.0.1", 0), probe81.H)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
    try:
        import urllib.request
        req = urllib.request.Request("http://127.0.0.1:%d/probe?t=%s" % (port, tok12))
        req.add_header("X-Forwarded-For", "10.20.7.7")
        req.add_header("X-Real-IP", "10.20.7.7")
        urllib.request.urlopen(req, timeout=5).read()
    finally:
        srv.shutdown(); srv.server_close(); th.join(timeout=5)
    r12, _ = S.read_state()
    (ok if r12["source"]["ipv4_16"] == "127.0.0.0/16" else bad)(
        "记的是真实 peer 127.0.0.x 的 /16, 不是伪造头里的 10.20(实得 %s)"
        % r12["source"]["ipv4_16"])
    (ok if r12["source"]["inside_internal_cidr"] is False else bad)(
        "伪造头没能把它算成内网来源")
    os.environ.pop("PDG_PROFILE_ENV", None)

    print()
    print("── 13. 状态写不下去时, 普通探测照样 200 ──")
    d = fresh_dir()
    tok13, rec13 = S.new_session(); S.write_state(rec13)
    os.chmod(d, 0o500)          # 目录只读 → 原子替换写不进去
    try:
        srv = HTTPServer(("127.0.0.1", 0), probe81.H)
        port = srv.server_address[1]
        th = threading.Thread(target=srv.serve_forever, daemon=True); th.start()
        try:
            import urllib.request
            with urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=5) as r:
                (ok if r.status == 200 and r.read() == b"ok" else bad)(
                    "状态目录不可写时, / 仍 200")
            with urllib.request.urlopen(
                    "http://127.0.0.1:%d/probe?t=%s" % (port, tok13), timeout=5) as r:
                (ok if r.status == 200 else bad)("会话请求也仍 200(功能降级, 服务不倒)")
        finally:
            srv.shutdown(); srv.server_close(); th.join(timeout=5)
        wrote = S.write_state(rec13)
        (ok if wrote is False else bad)("write_state 在不可写时返回 False 而不是抛异常")
    finally:
        os.chmod(d, 0o700)

    print()
    print("── 14. 会话不进 pdgtx, 不占全局写锁 ──")
    # 查字符串会误伤文档里"不进 pdgtx"那句本身。用 AST 看真正的 import 与调用。
    import ast
    tree = ast.parse(src)
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    (ok if "pdgtx" not in imported else bad)(
        "linksess.py 没有 import pdgtx(实际 import: %s)" % sorted(imported))
    (ok if "fcntl" not in imported else bad)("没有 import fcntl —— 拿不到文件锁")
    calls = {ast.unparse(n.func) for n in ast.walk(tree) if isinstance(n, ast.Call)}
    (ok if not any("flock" in c or "lockf" in c for c in calls) else bad)(
        "代码里没有任何 flock/lockf 调用")
    (ok if "PDG_LOCKFILE" not in [
        n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
        and isinstance(n.value, str)] else bad)("不引用全局锁文件名")
    # 行为验证: 占着全局锁时, 建会话/消费照常完成
    import fcntl
    lockd = tempfile.mkdtemp(prefix="sesslock."); TMPS.append(lockd)
    lockp = os.path.join(lockd, "pdg.lock")
    held = open(lockp, "w"); fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.environ["PDG_LOCKFILE"] = lockp
    d = fresh_dir()
    t0 = time.time()
    tok14, rec14 = S.new_session(); S.write_state(rec14)
    a14, w14, _ = S.consume(tok14, "10.20.1.1")
    dt = time.time() - t0
    fcntl.flock(held, fcntl.LOCK_UN); held.close()
    os.environ.pop("PDG_LOCKFILE", None)
    (ok if a14 and dt < 5 else bad)(
        "全局写锁被占用时, 会话照常建立与消费(%.2fs)" % dt)

    print()
    print("── 15. root 与 DynamicUser 的文件交接(真的换 UID 跑) ──")
    # 这条判据的全部意义在于**两个不同的 UID**。同一个 uid 下怎么测都是空转, 所以
    # 要么已经是 root, 要么借 sudo -n 拿到 root; 都拿不到就明确 SKIP, 不伪装成通过。
    # (userns 那条路走不通: 这台机器没有 newuidmap, 单 uid 映射造不出第二个身份。)
    helper = ROOT / "tests" / "linksess_uid_probe.py"
    cmd = [sys.executable, str(helper)]
    if os.geteuid() != 0:
        if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0:
            cmd = ["sudo", "-n", "-E"] + cmd
        else:
            cmd = None
    if cmd is None:
        skip("非 root 且没有免密 sudo —— UID 交接未验证(不是通过)")
    else:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180,
                           env=dict(os.environ,
                                    PYTHONPATH="%s:%s" % (ROOT / "deploy/bot",
                                                          ROOT / "deploy/ios")))
        lines = [l for l in r.stdout.strip().splitlines()
                 if l.startswith(("[OK]", "[FAIL]", "[SKIP]"))]
        if r.returncode != 0 or not lines:
            bad("UID 交接探针没跑起来: %s" % (r.stderr.strip()[-200:] or r.stdout[-200:]))
        for line in lines:
            tag, msg = line.split("] ", 1)
            {"[OK": ok, "[FAIL": bad, "[SKIP": skip}[tag](msg)

    print("─" * 46)
    print("通过 %d, 失败 %d" % (PASS_N[0], FAIL_N[0]))
    for t in TMPS:
        shutil.rmtree(t, ignore_errors=True)
    if PASS_N[0] + FAIL_N[0] == 0:
        print("零断言 —— 判失败"); return 1
    return 1 if FAIL_N[0] else 0


if __name__ == "__main__":
    sys.exit(main())

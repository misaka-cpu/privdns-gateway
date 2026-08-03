#!/usr/bin/env python3
"""root ↔ DynamicUser 的文件交接探针 —— 由 tests/test-link-session.py 以 root 调起。

为什么要单独一个进程: 这条判据的全部意义就在于**两个不同的 UID**。同一个 uid 下
怎么测都是空转 —— root 建的文件当然 root 自己读得到。所以这里真的:

  · 用 root 建一个属主是「另一个 uid」的 RuntimeDirectory(模拟 systemd 的
    DynamicUser 分配);
  · 以 root 身份写会话(模拟 `pdg link session start`);
  · fork 出一个 seteuid 到那个 uid 的子进程去读、去改(模拟 pdg-probe81);
  · 再回到 root 读回来。

并且**不允许**靠放宽权限过关: 目录固定 0700, 文件固定 0600, 任何一步用了
0666/0777 都要判失败。

输出用 [OK]/[FAIL]/[SKIP] 前缀, 由调用方转成自己的计数。
"""
import json
import os
import pwd
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "deploy", "bot"))


def out(tag, msg):
    print("[%s] %s" % (tag, msg)); sys.stdout.flush()


def pick_uid():
    """挑一个存在的、非 root 的本地 uid 当"动态 UID"。"""
    for name in ("nobody", "daemon", "bin", "systemd-network"):
        try:
            p = pwd.getpwnam(name)
            if p.pw_uid != 0:
                return p.pw_uid, p.pw_gid, name
        except KeyError:
            continue
    for p in pwd.getpwall():
        if 1 <= p.pw_uid < 65534:
            return p.pw_uid, p.pw_gid, p.pw_name
    return None, None, None


def main():
    if os.geteuid() != 0:
        out("SKIP", "UID 交接探针需要 root(拿不到第二个 uid 就是空转)")
        return 0
    uid, gid, uname = pick_uid()
    if uid is None:
        out("SKIP", "找不到可用的非 root uid")
        return 0

    import linksess as S

    box = tempfile.mkdtemp(prefix="uidhand.")
    rt = os.path.join(box, "pdg-probe81")
    os.makedirs(rt)
    # systemd 的 RuntimeDirectory=... + RuntimeDirectoryMode=0700 就是这个形态
    os.chown(rt, uid, gid)
    os.chmod(rt, 0o700)
    os.chmod(box, 0o755)
    os.environ["PDG_PROBE81_RUNTIME_DIR"] = rt

    # ── root 建会话(相当于 `pdg link session start`)────────────────────
    tok, rec = S.new_session()
    okw = S.write_state(rec)
    out("OK" if okw else "FAIL", "root 能在 0700 的 RuntimeDirectory 里建会话")
    st = os.stat(S._state_path())
    out("OK" if st.st_uid == uid else "FAIL",
        "root 写完把状态文件 chown 给了目录属主 %s(uid=%d, 实得 uid=%d)"
        % (uname, uid, st.st_uid))
    out("OK" if (st.st_mode & 0o777) == 0o600 else "FAIL",
        "状态文件是 0600, 没靠放宽权限解决(实得 %o)" % (st.st_mode & 0o777))
    dst = os.stat(rt)
    out("OK" if (dst.st_mode & 0o777) == 0o700 else "FAIL",
        "RuntimeDirectory 仍是 0700(实得 %o)" % (dst.st_mode & 0o777))

    # ── 以那个 uid 的身份读 + 改(相当于 pdg-probe81 消费 token)─────────
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        res = {}
        try:
            os.setgid(gid)
            os.setgroups([])
            os.setuid(uid)
            res["euid"] = os.geteuid()
            rec2, why = S.read_state()
            res["read"] = rec2 is not None
            res["why"] = why
            if rec2 is not None:
                acc, why2, _ = S.consume(tok, "10.20.5.6")
                res["consume"] = bool(acc)
                res["consume_why"] = why2
        except Exception as e:                       # noqa: BLE001
            res["err"] = "%s: %s" % (type(e).__name__, e)
        os.write(w, json.dumps(res).encode())
        os.close(w)
        os._exit(0)
    os.close(w)
    buf = b""
    while True:
        chunk = os.read(r, 4096)
        if not chunk:
            break
        buf += chunk
    os.close(r)
    os.waitpid(pid, 0)
    res = json.loads(buf or b"{}")

    out("OK" if res.get("euid") == uid else "FAIL",
        "子进程确实换成了 uid=%s(实得 %s)" % (uid, res.get("euid")))
    out("OK" if res.get("read") else "FAIL",
        "动态 UID 读得到 root 建的会话(reason=%s%s)"
        % (res.get("why"), " err=" + res["err"] if "err" in res else ""))
    out("OK" if res.get("consume") else "FAIL",
        "动态 UID 能消费 token 并原子写回(reason=%s)" % res.get("consume_why"))

    # ── root 再读回来 ─────────────────────────────────────────────────
    rec3, why3 = S.read_state()
    out("OK" if rec3 is not None else "FAIL",
        "动态 UID 写回后 root 仍读得到(reason=%s)" % why3)
    if rec3 is not None:
        out("OK" if rec3.get("http_consumed_at") is not None else "FAIL",
            "root 看到的是动态 UID 写下的那次消费")
    st2 = os.stat(S._state_path())
    out("OK" if st2.st_uid == uid else "FAIL",
        "写回后属主仍是动态 UID(实得 %d)" % st2.st_uid)
    out("OK" if (st2.st_mode & 0o777) in (0o600, 0o644) else "FAIL",
        "写回后权限没被放宽到组/其他可写(实得 %o)" % (st2.st_mode & 0o777))
    out("OK" if os.stat(rt).st_mode & 0o077 == 0 else "FAIL",
        "全程没有放宽 RuntimeDirectory 的组/其他权限")

    # 普通文件、单链接、非符号链接
    out("OK" if os.path.isfile(S._state_path()) and not os.path.islink(S._state_path())
        and st2.st_nlink == 1 else "FAIL",
        "状态是普通文件、单链接、无符号链接穿透")

    import shutil
    shutil.rmtree(box, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

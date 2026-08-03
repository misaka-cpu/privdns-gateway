#!/usr/bin/env python3
"""真实双 UID 探针: 动态用户读不到 profile.env 时, 来源网段结论还出不出得来。

由 tests/test-link-profile-uid.py 以 root 调起。为什么必须真的换 UID:

  `.153` 真机上 pdg-probe81 以 DynamicUser 跑, 而 /etc/privdns-gateway 是 0700 root:root、
  profile.env 是 0600 root:root。动态用户**读不到**它 —— 于是 linksess._profile() 里的
  `except OSError: pass` 把 PermissionError 静默吞掉、返回空串, inside_internal_cidr()
  拿不到 CIDR 只能返回 None。结果是 6.1C 两条证据里的第二条(来源在不在内网卡段)在真机上
  **永远产不出来**, Bot 只会说"服务器上没有配置内网卡来源段"。

  沙箱里所有测试都以同一个用户跑、文件可读, 这条边界一次都没被碰到。同一个 uid 下怎么测
  都是空转 —— root 建的文件当然 root 自己读得到。

本探针因此真的:
  · 以 root 建 0600 root:root 的 profile.env(含合法 PDG_INTERNAL_CIDR 与 SECRET_SENTINEL);
  · 以 root 建属主是「另一个 uid」的 RuntimeDirectory(模拟 systemd 分配的 DynamicUser);
  · 以 root 建会话(模拟 `pdg link session start` / Bot);
  · fork 出**真的 setuid** 到那个 uid 的子进程, 走 probe81 用的同一个入口 consume();
  · 回到 root 读回结论。

并且证明失败来自权限边界本身: 子进程先自证 open(profile.env) 抛 PermissionError,
再证明同一份数据 root 读得到 —— 否则"读不到"可能只是路径写错或前提没搭好。
输出 [OK]/[FAIL]/[SKIP], 由调用方转成自己的计数。
"""
import json
import os
import pwd
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "deploy", "bot"))

SENTINEL = "SECRET_SENTINEL_e3f1a97c"


def out(tag, msg):
    print("[%s] %s" % (tag, msg))
    sys.stdout.flush()


def pick_uid():
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


def child_consume(uid, gid, token, peer, profile, rt, out_path):
    """在**真正切到 uid 之后**跑 probe81 的入口。结果写文件回传给父进程。"""
    res = {}
    try:
        os.setgroups([])
        os.setgid(gid)
        os.setuid(uid)                      # 真的换身份, 不是 seteuid 也不是桩
        res["euid"] = os.geteuid()
        res["is_root"] = (os.geteuid() == 0)
        # 自证权限边界: 这一步必须抛 PermissionError, 否则下面的结论说明不了任何事
        try:
            with open(profile, encoding="utf-8") as f:
                f.read()
            res["profile_readable"] = True
        except PermissionError:
            res["profile_readable"] = False
        except OSError as e:
            res["profile_readable"] = "OSError:%s" % type(e).__name__
        os.environ["PDG_PROBE81_RUNTIME_DIR"] = rt
        os.environ["PDG_PROFILE_ENV"] = profile
        import linksess as S
        accepted, reason, rec = S.consume(token, peer)
        res["accepted"] = bool(accepted)
        res["reason"] = reason
        res["source"] = (rec or {}).get("source")
    except Exception as e:  # noqa: BLE001
        res["error"] = "%s: %s" % (type(e).__name__, e)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(res, f)
    os._exit(0)


def main():
    if os.geteuid() != 0:
        out("SKIP", "需要 root —— 拿不到第二个 uid 就是空转, 不能当通过")
        return 0
    uid, gid, uname = pick_uid()
    if uid is None:
        out("SKIP", "找不到可用的非 root uid")
        return 0

    import linksess as S

    # 布局照真机来。这两个父目录的权限**本来就不一样**, 混成一个会把测试搭坏:
    #   /etc/privdns-gateway  0700 root:root  ← profile.env 在这儿, 动态用户连进都进不去
    #   /run/pdg-probe81      0700 <dynuid>   ← 会话在这儿, 父目录 /run 人人可穿过
    box = tempfile.mkdtemp(prefix="profuid.")
    os.chmod(box, 0o711)                   # 相当于 /: 可穿过, 不可列
    etc = os.path.join(box, "etc")
    os.makedirs(etc, mode=0o700)           # 相当于 /etc/privdns-gateway
    os.chown(etc, 0, 0)
    rt = os.path.join(box, "run", "pdg-probe81")
    os.makedirs(rt, mode=0o700)
    os.chmod(os.path.join(box, "run"), 0o711)   # 相当于 /run
    os.chown(rt, uid, gid)                 # systemd 的 RuntimeDirectory 就是这个形态
    profile = os.path.join(etc, "profile.env")
    with open(profile, "w", encoding="utf-8") as f:
        f.write("PDG_INTERNAL_CIDR=172.22.0.0/16\n")
        f.write("PDG_RESCUE_TOKEN=%s\n" % SENTINEL)     # 模拟同文件里的其它敏感项
    os.chmod(profile, 0o600)               # 与真机一致: root 独占
    os.chown(profile, 0, 0)

    os.environ["PDG_PROBE81_RUNTIME_DIR"] = rt
    os.environ["PDG_PROFILE_ENV"] = profile

    okk, payload = S.start_session()
    if not okk:
        out("FAIL", "root 建会话失败: %s" % payload.get("error"))
        return 1
    import re as _re
    m = _re.search(r"[?&]t=([A-Za-z0-9_-]+)", payload["step1_url"])
    token = m.group(1) if m else ""
    out("OK", "root 建出会话 %s(前提成立)" % payload["session_id"])

    st = os.stat(os.path.join(rt, S.STATE_NAME))
    out("OK" if oct(st.st_mode & 0o777) == "0o600" else "FAIL",
        "状态文件 mode=%s(应为 0600)" % oct(st.st_mode & 0o777))
    out("OK" if st.st_uid == uid else "FAIL",
        "状态文件属主已交接给动态 uid(%d, 期望 %d)" % (st.st_uid, uid))
    out("OK" if oct(os.stat(rt).st_mode & 0o777) == "0o700" else "FAIL",
        "RuntimeDirectory mode=%s(应为 0700)" % oct(os.stat(rt).st_mode & 0o777))

    # root 自己读同一份配置 —— 证明数据本身是好的, 待会儿子进程读不到只能是权限所致
    out("OK" if S._profile("PDG_INTERNAL_CIDR") == "172.22.0.0/16" else "FAIL",
        "root 能从这份 profile.env 读到 CIDR(数据前提成立)")

    # 回传目录必须**属于子进程那个 uid** —— box 是 0700 root:root, 子进程写不进去。
    # (第一版就是把 child.json 放在 box 里, 子进程 PermissionError 直接崩, 那不是判据在说话。)
    cbox = os.path.join(box, "childout")
    os.makedirs(cbox, mode=0o700)
    os.chown(cbox, uid, gid)
    res_path = os.path.join(cbox, "child.json")
    pid = os.fork()
    if pid == 0:
        child_consume(uid, gid, token, "172.22.5.9", profile, rt, res_path)
    os.waitpid(pid, 0)
    try:
        with open(res_path, encoding="utf-8") as f:
            r = json.load(f)
    except Exception as e:  # noqa: BLE001
        out("FAIL", "子进程没回传结果: %s" % type(e).__name__)
        return 1

    if r.get("error"):
        out("FAIL", "子进程出错: %s" % r["error"])
        return 1
    out("OK" if not r.get("is_root") and r.get("euid") == uid else "FAIL",
        "子进程真的换到了非 root uid=%s(%s)" % (r.get("euid"), uname))
    out("OK" if r.get("profile_readable") is False else "FAIL",
        "子进程读 profile.env 抛 PermissionError(权限边界真实存在, 实得 %r)"
        % (r.get("profile_readable"),))
    out("OK" if r.get("accepted") else "FAIL",
        "HTTP 请求仍被记录(reason=%s)" % r.get("reason"))

    src = r.get("source") or {}
    inside = src.get("inside_internal_cidr")
    # 这一条就是 P0 本身: 修复前必须是 None(结论产不出来), 修复后必须是 True。
    print("[PROBE] inside_internal_cidr=%r ipv4_16=%r" % (inside, src.get("ipv4_16")))
    out("OK" if inside is True else "FAIL",
        "来源段结论产得出来(inside=%r; 修复前它是 None —— 那正是 P0)" % (inside,))
    out("OK" if src.get("ipv4_16") == "172.22.0.0/16" else "FAIL",
        "来源只落 /16 前缀(实得 %r)" % (src.get("ipv4_16"),))

    blob = open(os.path.join(rt, S.STATE_NAME), encoding="utf-8").read()
    out("OK" if SENTINEL not in blob else "FAIL", "SECRET_SENTINEL 没进状态文件")
    out("OK" if "172.22.5.9" not in blob else "FAIL", "完整 peer IP 没进状态文件")
    out("OK" if token not in blob else "FAIL", "token 原文没进状态文件")

    import shutil
    shutil.rmtree(box, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

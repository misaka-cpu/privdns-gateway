#!/usr/bin/env python3
"""系统不变量的捕获与比较 —— **只给测试用**, 不进生产, 不被 CLI/Bot/rescue import。

为什么要有这一层: 失败矩阵有十个场景, 之前每个场景各写各的断言。结果是覆盖看着挺全, 实际
每条只查了作者当时想到的那几样 —— token 摘要、证书指纹、nft 计数、NRestarts、pending 事务、
staging 残留没有一条跨场景统一核对过。一次"失败后没清干净"的回归, 只要它恰好落在某条用例
没查的那几个字段上, 十条全绿。

所以改成: 场景跑之前抓一份快照, 跑完再抓一份, 按**profile** 比。profile 明确说清这个场景
允许什么变、其余一律不许变 —— 未声明的变化就是失败, 不需要谁事先想到它。

用法:
    update_invariants.py capture --scenario NAME --profile P [--root /] [--platform ios]
    update_invariants.py compare BEFORE.json AFTER.json --profile P [--allow-mode NAME]

秘密只记 SHA256 摘要, 绝不输出原值。
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

SCHEMA_VERSION = 1

# E2E 的桩把状态写在**本轮自己的**临时目录里(e2e-lib.sh 的 $E2E_TMP), 不再是写死的 /tmp。
# 这里只是"观察"那些文件, 所以跟着同一个变量走; 不在 E2E 里跑时退回 /tmp, 探测结果照旧。
E2E_TMP = os.environ.get("E2E_TMP") or "/tmp"
STUB_SVC_DIR = os.path.join(E2E_TMP, "e2e-svc")
STUB_NFT_STATE = os.path.join(E2E_TMP, "e2e-nft-ruleset")

# 每个 profile 说清"这个场景允许什么变"。未知 profile 直接失败 —— 不给默认值, 免得写错名字
# 的场景悄悄退化成"什么都不查"。
PROFILES = {
    # 覆盖生产**之前**就失败(checksum、截断、manifest 预检): 一切原样。
    "update-prewrite": {"desc": "生产前拒绝", "allow_nrestarts_delta": 0,
                        "allow_mode_change": False},
    # 覆盖生产**之后**回滚(py_compile、第 N 个部署失败、健康门): 文件/配置/凭据/git 必须
    # 恢复; 服务可能被动过, 允许场景声明的 NRestarts 增量, 但回滚完成后不得继续上涨。
    "update-rollback": {"desc": "覆盖生产后精确回滚", "allow_nrestarts_delta": None,
                        "allow_mode_change": False},
    # tar 安全场景走的是恢复入口, 根本没有 systemd 动作 —— 不去虚构它。
    "restore-safety": {"desc": "解包入口的安全边界", "allow_nrestarts_delta": 0,
                       "allow_mode_change": False, "skip_services": True},
    # 成功路径: 只允许点名的静态文件 mode 变成 manifest 值。
    "mode-normalize-success": {"desc": "成功更新时 mode 归一", "allow_nrestarts_delta": 0,
                               "allow_mode_change": True},
}

SENTINEL_PAT = re.compile(
    r"\b\d{8,10}:[A-Za-z0-9_-]{30,}\b"          # Telegram bot token
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----")


def sha256_file(path, root=""):
    """流式算摘要 —— 超大文件不整份读进内存。不跟随符号链接: 捕获器绝不能被一条指向
    /etc/shadow 的软链骗去读它。"""
    p = os.path.join(root, path.lstrip("/")) if root and root != "/" else path
    try:
        st = os.lstat(p)
    except OSError:
        return None
    if not os.path.isfile(p) or os.path.islink(p):
        return "not-a-regular-file" if os.path.exists(p) else None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def stat_of(path, root=""):
    p = os.path.join(root, path.lstrip("/")) if root and root != "/" else path
    try:
        st = os.lstat(p)
    except OSError:
        return {"exists": False, "sha256": None, "mode": None, "uid": None, "gid": None}
    return {"exists": True, "sha256": sha256_file(path, root),
            "mode": oct(st.st_mode & 0o7777)[2:].rjust(3, "0"),
            "uid": st.st_uid, "gid": st.st_gid}


def run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "").strip()
    except Exception:  # noqa: BLE001
        return 127, ""


def detect_caps(root):
    """能力探测。**stub 必须如实标成 stub** —— 拿桩产生的数字冒充真 systemd/nft 的读数,
    比不采集更糟: 它会让"服务状态已恢复"这种结论看起来有证据。"""
    caps = {}
    sc = run(["sh", "-c", "command -v systemctl"])[1]
    if not sc:
        caps["systemd"] = "unavailable"
    elif "/usr/local/bin/systemctl" in sc or os.path.exists(STUB_SVC_DIR):
        caps["systemd"] = "stub"          # E2E 的假 systemctl(见 e2e_stub_system)
    else:
        caps["systemd"] = "real" if run(["systemctl", "is-system-running"])[0] in (0, 1) else "stub"
    nf = run(["sh", "-c", "command -v nft"])[1]
    if not nf:
        caps["nft"] = "unavailable"
    elif "/usr/local/bin/nft" in nf or os.path.exists(STUB_NFT_STATE):
        caps["nft"] = "stub"
    else:
        caps["nft"] = "real" if run(["nft", "list", "tables"])[0] == 0 else "stub"
    caps["git"] = "real" if run(["git", "--version"])[0] == 0 else "unavailable"
    return caps


def manifest_members(repo, platform):
    rc, out = run(["bash", "-c",
                   'source "%s/lib/modules.sh" && pdg_platform_modules "%s"' % (repo, platform)])
    if rc != 0:
        raise SystemExit("读不到 manifest(source lib/modules.sh 失败) —— 拒绝产出半份快照")
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            rows.append({"src": parts[0], "name": parts[1], "mode": parts[2]})
    if not rows:
        raise SystemExit("manifest 为空 —— 拒绝产出半份快照")
    return rows


# 用户与配置数据。不存在的合法可选文件记 absent, **不能直接不输出字段** —— 少一个字段和
# "这个文件本来就没有"是两回事, 比较器分不出来就会漏掉真实的删除。
USER_DATA = [
    ("bot.env", "/etc/privdns-gateway/bot.env"),
    ("model", "/etc/sing-box/config.json"),
    ("mihomo_config", "/etc/mihomo/config.yaml"),
    ("mosdns_config", "/etc/mosdns/config.yaml"),
    ("rulesets", "/opt/pdg-bot/rulesets.json"),
    ("dot_domain", "/opt/pdg-bot/dot-domain"),
    ("platform", "/etc/privdns-gateway/platform"),
    ("profile_env", "/etc/privdns-gateway/profile.env"),
    ("mitm_json", "/etc/privdns-gateway/mitm.json"),
    ("mitm_hijack", "/etc/mosdns/rules/mitm_hijack.txt"),
]
CREDENTIALS = [
    ("bot_token_file", "/etc/privdns-gateway/bot.env"),
    ("rescue_token", "/etc/privdns-gateway/rescue/token"),
    ("rescue_cert", "/etc/privdns-gateway/rescue/cert.pem"),
    ("rescue_key", "/etc/privdns-gateway/rescue/key.pem"),
]
CORE_SERVICES = ("mihomo", "mosdns", "pdg-bot", "pdg-rescue.socket")


def capture(args):
    root = args.root or "/"
    if root != "/":
        rp = os.path.realpath(root)
        if not rp.startswith("/") or rp == "/":
            raise SystemExit("root 不合法: %r" % root)
        root = rp
    repo = args.repo or "/opt/privdns-gateway"
    plat = args.platform or _read(os.path.join(root, "etc/privdns-gateway/platform")) or "android"
    plat = plat.strip() or "android"
    if args.profile not in PROFILES:
        raise SystemExit("未知 profile: %s(已知: %s)" % (args.profile, ", ".join(PROFILES)))

    snap = {
        "schema_version": SCHEMA_VERSION,
        "scenario": args.scenario,
        "profile": args.profile,
        "capture_time": time.time(),
        "root": root,
        "platform": plat,
        "capabilities": detect_caps(root),
    }

    # ── git 与版本 ────────────────────────────────────────────────────────
    g = {}
    g["head"] = run(["git", "-C", repo, "rev-parse", "HEAD"])[1] or None
    g["tree"] = run(["git", "-C", repo, "rev-parse", "HEAD^{tree}"])[1] or None
    g["describe"] = run(["git", "-C", repo, "describe", "--tags", "--always"])[1] or None
    g["dirty"] = bool(run(["git", "-C", repo, "status", "--porcelain"])[1])
    origin = run(["git", "-C", repo, "remote", "get-url", "origin"])[1]
    # origin 只记**分类**, 不记 URL —— 私有仓库地址本身也算信息。
    g["origin_kind"] = ("github" if "github.com" in origin else
                        "local" if origin.startswith("/") or origin.startswith("file:") else
                        "none" if not origin else "other")
    snap["git"] = g

    members = manifest_members(repo, plat)
    snap["manifest"] = {"count": len(members), "names": sorted(m["name"] for m in members)}
    # 数量是**故意钉死**的: 装机清单少一项就是整块能力静默降级, 多一项也该有人过目。
    # 6.1C 加了 nftlive.py(doctor 与 linkstat 共用的防火墙语义核心, 两边都 import 它,
    # 不装它 doctor 的防火墙检查会直接 ImportError), 因此两个平台各 +1。
    expect = {"android": 26, "ios": 32}.get(plat)
    if expect is not None and len(members) != expect:
        raise SystemExit("manifest 数量漂移: %s 平台应为 %d 项, 实得 %d" % (plat, expect, len(members)))

    # ── 静态文件 ──────────────────────────────────────────────────────────
    static = {}
    for m in members:
        path = "/opt/pdg-bot/" + m["name"]
        st = stat_of(path, root)
        st["path"] = path
        st["manifest_mode"] = m["mode"]
        static[m["name"]] = st
    snap["static_files"] = static

    snap["user_data"] = {k: (stat_of(p, root) if os.path.exists(
        os.path.join(root, p.lstrip("/")) if root != "/" else p)
        else {"exists": False, "sha256": None, "mode": None, "uid": None, "gid": None})
        for k, p in USER_DATA}
    snap["credentials"] = {k: {"sha256": sha256_file(p, root)} for k, p in CREDENTIALS}
    fp = None
    cert = os.path.join(root, "etc/privdns-gateway/rescue/cert.pem".lstrip("/")) \
        if root != "/" else "/etc/privdns-gateway/rescue/cert.pem"
    if os.path.isfile(cert):
        rc, out = run(["openssl", "x509", "-in", cert, "-noout", "-fingerprint", "-sha256"])
        if rc == 0:
            mm = re.search(r"=\s*([0-9A-Fa-f:]+)", out)
            fp = mm.group(1).upper() if mm else None
    snap["credentials"]["rescue_cert_fingerprint"] = {"sha256": fp}

    # ── nft 与服务 ────────────────────────────────────────────────────────
    caps = snap["capabilities"]
    nftconf = os.path.join(root, "etc/nftables.conf") if root != "/" else "/etc/nftables.conf"
    fw = {"capability": caps["nft"],
          "conf_sha256": sha256_file("/etc/nftables.conf", root),
          "disk_rescue_rules": None, "kernel_rescue_rules": None, "legacy_table": None}
    if os.path.isfile(nftconf):
        txt = open(nftconf, encoding="utf-8", errors="replace").read()
        fw["disk_rescue_rules"] = txt.count("pdg-rescue")
    if caps["nft"] == "real":
        rc, out = run(["nft", "list", "table", "inet", "pdg"])
        fw["kernel_rescue_rules"] = out.count("pdg-rescue") if rc == 0 else 0
        fw["legacy_table"] = "pdgrescue" in run(["nft", "list", "tables"])[1]
    snap["firewall"] = fw

    svc = {"capability": caps["systemd"], "services": {}}
    if caps["systemd"] == "real":
        for s in CORE_SERVICES:
            svc["services"][s] = {
                "active": run(["systemctl", "is-active", s])[1],
                "nrestarts": run(["systemctl", "show", s, "-p", "NRestarts", "--value"])[1] or "0",
            }
    elif caps["systemd"] == "stub":
        # 桩环境: 只记桩自己的状态文件摘要, **不产出看似真实的 systemctl 数值**。
        d = STUB_SVC_DIR
        svc["stub_state"] = sorted(
            "%s=%s" % (f, (open(os.path.join(d, f)).read().strip() if os.path.isfile(
                os.path.join(d, f)) else "?"))
            for f in (os.listdir(d) if os.path.isdir(d) else []))
    snap["services"] = svc

    # ── 事务与残留 ────────────────────────────────────────────────────────
    txroot = os.path.join(root, "var/lib/privdns-gateway/tx") if root != "/" \
        else "/var/lib/privdns-gateway/tx"
    pend = []
    if os.path.isdir(txroot):
        for d in sorted(os.listdir(txroot)):
            mp = os.path.join(txroot, d, "meta.json")
            if not os.path.isfile(mp):
                continue
            try:
                stt = json.load(open(mp, encoding="utf-8")).get("state")
            except Exception:  # noqa: BLE001
                continue
            if stt in ("APPLYING", "OBSERVING", "ROLLING_BACK", "ROLLBACK_FAILED"):
                pend.append(d)
    res = {"pending_tx": pend}
    res["staging"] = sorted(p for p in ("/tmp/pdg-update-staging", "/tmp/pdgtx-stage")
                            if os.path.exists(p))
    res["netns"] = sorted(x for x in run(["sh", "-c", "ip netns list 2>/dev/null"])[1].split("\n") if x)
    res["veth"] = len([x for x in run(
        ["sh", "-c", "ip -o link show type veth 2>/dev/null"])[1].split("\n") if x])
    # `pgrep -c` 没命中时既打印 0 又返回非 0, 于是 `|| echo 0` 再补一行 —— 拿到的是 "0\n0"。
    # 只取第一行。
    res["bg_mosdns"] = int((run(["sh", "-c", "pgrep -c -x mosdns 2>/dev/null || echo 0"])[1]
                            or "0").splitlines()[0])
    res["disposable_roots"] = sorted(
        x for x in run(["sh", "-c", "ls -d /tmp/e2e-box.* 2>/dev/null"])[1].split("\n") if x)
    snap["residue"] = res

    if args.source_repo:
        snap["source_repo"] = {
            "tree": run(["git", "-C", args.source_repo, "rev-parse", "HEAD^{tree}"])[1] or None,
            "status_lines": len([x for x in run(
                ["git", "-C", args.source_repo, "status", "--porcelain"])[1].split("\n") if x]),
        }

    out = json.dumps(snap, ensure_ascii=False, sort_keys=True, indent=1)
    leak = SENTINEL_PAT.search(out)
    if leak:
        raise SystemExit("捕获输出里出现了疑似秘密 —— 拒绝写出快照")
    # 中途失败不留半份"有效快照": 先全算完, 最后一次性写。
    if args.out:
        tmp = args.out + ".part"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out)
        os.replace(tmp, args.out)
    else:
        sys.stdout.write(out + "\n")
    return 0


def _read(p):
    try:
        return open(p, encoding="utf-8").read().strip()
    except OSError:
        return ""


REQUIRED_TOP = ("schema_version", "scenario", "profile", "capture_time", "root", "platform",
                "capabilities", "git", "manifest", "static_files", "user_data",
                "credentials", "firewall", "services", "residue")
REQUIRED_CRED = ("bot_token_file", "rescue_token", "rescue_cert", "rescue_key",
                 "rescue_cert_fingerprint")


def _short(v):
    s = str(v)
    return s[:12] + "…" if len(s) > 12 else s


def compare(args):
    prof = args.profile
    if prof not in PROFILES:
        print("未知 profile: %s" % prof)
        return 1
    fails = []
    try:
        b = json.load(open(args.before, encoding="utf-8"))
        a = json.load(open(args.after, encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        print("读不到快照: %s" % e)
        return 1

    for snap, tag in ((b, "before"), (a, "after")):
        for k in REQUIRED_TOP:
            if k not in snap:
                fails.append("required-field: %s 缺字段 %s" % (tag, k))
        if snap.get("schema_version") != SCHEMA_VERSION:
            fails.append("schema: %s 的 schema_version=%r" % (tag, snap.get("schema_version")))
        for k in REQUIRED_CRED:
            if k not in snap.get("credentials", {}):
                fails.append("required-field: %s 的 credentials 缺 %s" % (tag, k))
        if not isinstance(snap.get("static_files"), dict):
            fails.append("type: %s 的 static_files 不是对象" % tag)

    # 场景宣称 real 但捕获是 stub → 失败(不许拿桩冒充实测)
    for need in (args.require_real or []):
        for snap, tag in ((b, "before"), (a, "after")):
            got = snap.get("capabilities", {}).get(need)
            if got != "real":
                fails.append("capability: 场景要求 %s=real, %s 实为 %r" % (need, tag, got))
    if b.get("capabilities") != a.get("capabilities"):
        fails.append("capability: before/after 的能力标记不一致")

    if b.get("platform") != a.get("platform"):
        fails.append("platform: %s → %s" % (b.get("platform"), a.get("platform")))
    if b.get("manifest", {}).get("names") != a.get("manifest", {}).get("names"):
        fails.append("manifest: 成员集合发生变化")

    # git
    for k in ("head", "tree", "describe", "origin_kind"):
        if b.get("git", {}).get(k) != a.get("git", {}).get(k):
            fails.append("git.%s: %s → %s" % (k, _short(b["git"].get(k)), _short(a["git"].get(k))))

    # 静态文件
    allow_mode = set(args.allow_mode or [])
    if allow_mode and not PROFILES[prof]["allow_mode_change"]:
        fails.append("profile: %s 不允许声明 mode 变化" % prof)
    for name in sorted(set(b.get("static_files", {})) | set(a.get("static_files", {}))):
        bs, as_ = b["static_files"].get(name), a["static_files"].get(name)
        if bs is None or as_ is None:
            fails.append("static.%s: 只在一侧出现" % name)
            continue
        for field in ("exists", "sha256", "uid", "gid"):
            if bs.get(field) != as_.get(field):
                fails.append("static.%s.%s: %s → %s"
                             % (name, field, _short(bs.get(field)), _short(as_.get(field))))
        if bs.get("mode") != as_.get("mode"):
            if name in allow_mode and as_.get("mode") == as_.get("manifest_mode"):
                pass                      # 声明过的 mode 归一
            else:
                fails.append("static.%s.mode: %s → %s(未声明)"
                             % (name, bs.get("mode"), as_.get("mode")))

    for section in ("user_data", "credentials"):
        for k in sorted(set(b.get(section, {})) | set(a.get(section, {}))):
            if b.get(section, {}).get(k) != a.get(section, {}).get(k):
                bv = (b.get(section, {}).get(k) or {}).get("sha256")
                av = (a.get(section, {}).get(k) or {}).get("sha256")
                fails.append("%s.%s: %s → %s" % (section, k, _short(bv), _short(av)))

    for k in ("conf_sha256", "disk_rescue_rules", "kernel_rescue_rules", "legacy_table"):
        if b.get("firewall", {}).get(k) != a.get("firewall", {}).get(k):
            fails.append("firewall.%s: %s → %s"
                         % (k, _short(b["firewall"].get(k)), _short(a["firewall"].get(k))))

    if not PROFILES[prof].get("skip_services"):
        bs, as_ = b.get("services", {}), a.get("services", {})
        if bs.get("capability") == "real":
            for s in sorted(set(bs.get("services", {})) | set(as_.get("services", {}))):
                bb, aa = bs["services"].get(s, {}), as_.get("services", {}).get(s, {})
                if bb.get("active") != aa.get("active"):
                    fails.append("service.%s.active: %s → %s" % (s, bb.get("active"), aa.get("active")))
                try:
                    d = int(aa.get("nrestarts", 0)) - int(bb.get("nrestarts", 0))
                except (TypeError, ValueError):
                    d = 0
                cap = PROFILES[prof]["allow_nrestarts_delta"]
                if cap is None:
                    cap = args.allow_nrestarts if args.allow_nrestarts is not None else 0
                if d < 0:
                    fails.append("service.%s.nrestarts 倒退 %d" % (s, d))
                elif d > cap:
                    fails.append("service.%s.nrestarts +%d(本 profile 允许 %d)" % (s, d, cap))
        elif bs.get("capability") == "stub":
            if bs.get("stub_state") != as_.get("stub_state"):
                fails.append("service.stub_state: 桩状态发生变化")

    br, ar = b.get("residue", {}), a.get("residue", {})
    allowed_tx = set(br.get("pending_tx") or [])
    extra = sorted(set(ar.get("pending_tx") or []) - allowed_tx)
    if extra:
        fails.append("residue.pending_tx: 新增未完成事务 %s" % ", ".join(extra[:3]))
    for k in ("staging", "netns", "veth", "bg_mosdns", "disposable_roots"):
        if br.get(k) != ar.get(k):
            fails.append("residue.%s: %s → %s" % (k, _short(br.get(k)), _short(ar.get(k))))

    if "source_repo" in b or "source_repo" in a:
        if b.get("source_repo") != a.get("source_repo"):
            fails.append("source_repo: 原始仓库 tree/status 发生变化")

    out = json.dumps({"profile": prof, "scenario": a.get("scenario"),
                      "capabilities": a.get("capabilities"),
                      "ok": not fails, "failures": fails},
                     ensure_ascii=False, sort_keys=True, indent=1)
    print(out)
    return 1 if fails else 0


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--scenario", required=True)
    c.add_argument("--profile", required=True)
    c.add_argument("--root", default="/")
    c.add_argument("--repo", default="")
    c.add_argument("--platform", default="")
    c.add_argument("--source-repo", default="")
    c.add_argument("--out", default="")
    d = sub.add_parser("compare")
    d.add_argument("before")
    d.add_argument("after")
    d.add_argument("--profile", required=True)
    d.add_argument("--allow-mode", action="append", default=[])
    d.add_argument("--require-real", action="append", default=[])
    d.add_argument("--allow-nrestarts", type=int, default=None)
    p = sub.add_parser("profiles")
    a = ap.parse_args(argv[1:])
    if a.cmd == "capture":
        return capture(a)
    if a.cmd == "compare":
        return compare(a)
    print(json.dumps(PROFILES, ensure_ascii=False, sort_keys=True, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

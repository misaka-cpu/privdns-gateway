#!/usr/bin/env python3
"""「明确代理优先于 geosite_cn」的编辑器 / 事务 / doctor 三层验收。

DNS 行为本身由 tests/dns-policy-test.sh 真起 mosdns 验(那里才有"域名到底解析成什么"的判据),
负控由 tests/test-explicit-proxy-nc.sh 守。这里管的是另外三件事:

  A. 编辑器 `_mosdns_explicit_proxy`: 对**真正的 v1.7.0 模板**幂等补齐、顺序自检、
     形态不认识时 fail-closed(一个字节都不写)。
  B. 事务路径: 候选过不了 mosdns 强校验 / 服务重启失败 → 现网配置字节不变。
  C. doctor: 未迁移的机器必须被**点名**, 顺序反了必须判 fail。

A 段的基准配置优先取 `git show v1.7.0:deploy/mosdns/config.yaml`(真的发布产物);
取不到时退回"从当前模板里摘掉本次新增的部分"重建, 并在 tag 可达时顺带断言两者一致 ——
所以退化路径不是"换个宽松判据", 而是一条被验证过等价的路径。
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

pass_n = 0
fail_n = 0


def ok(m):
    global pass_n
    print("[OK]   " + m)
    pass_n += 1


def bad(m):
    global fail_n
    print("[FAIL] " + m)
    fail_n += 1


def sha(b):
    return hashlib.sha256(b).hexdigest()


def run_editor(cfg, server_ip="177.0.142.200"):
    """跑 lib/mosdns.sh 里的 _mosdns_explicit_proxy。返回 (rc, stdout, stderr)。"""
    p = subprocess.run(
        ["bash", "-c",
         'set -uo pipefail; source "$1"/lib/mosdns.sh; _mosdns_explicit_proxy "$2" "$3"',
         "_", str(ROOT), cfg, server_ip],
        capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def gate_before_cn(text):
    """internal_sequence 里 explicit_proxy 判断是否排在 geosite_cn 判断之前。
    两者都必须存在 —— 缺一个就返回 None(由调用方判为不合格), 不当作"顺序没问题"。"""
    seq = text.split("- tag: internal_sequence", 1)
    if len(seq) < 2:
        return None
    body = seq[1]
    g = body.find("qname $explicit_proxy")
    c = body.find("qname $geosite_cn")
    f = body.find("qname $force_hijack")
    if g < 0 or c < 0:
        return None
    return (g < c, f >= 0 and f < g)


# ── 取 v1.7.0 的真实模板 ─────────────────────────────────────────────────────
def v170_template():
    p = subprocess.run(["git", "-C", str(ROOT), "show", "v1.7.0:deploy/mosdns/config.yaml"],
                       capture_output=True, timeout=120)
    tag = p.stdout if p.returncode == 0 else None
    cur = (ROOT / "deploy/mosdns/config.yaml").read_bytes()
    # 重建: 把本次新增的三块(域名集 / 序列 / 判断)从当前模板里摘掉。
    s = cur.decode()
    s = re.sub(r"  # 明确代理集:[\s\S]*?(?=  - tag: ecs_china\n)", "", s)
    s = re.sub(r"  # 明确代理域名的劫持序列[\s\S]*?(?=  - tag: internal_sequence\n)", "", s)
    s = re.sub(r"      # 用户点名指到出口的域名[\s\S]*?exec: goto explicit_proxy_seq\n", "", s)
    # 去广告受管块(v1.11.0)也引用 $explicit_proxy —— 那是"第三方表不得压过用户显式分流"
    # 那条合取。重建 v1.7.0 形态时它整段都不该在, 所以连同 plugins 那一段一起摘掉;
    # 摘不干净会立刻表现为下面那条"仍残留 explicit_proxy"。
    s = re.sub(r" *# 不要手工编辑下面这一段[^\n]*\n *# >>> pdg-adblock managed block \(plugins\)"
               r"[\s\S]*?# <<< pdg-adblock managed block \(plugins\)\n", "", s)
    s = re.sub(r" *# 不要手工编辑下面这一段[^\n]*\n *# >>> pdg-adblock managed block \(internal_sequence\)"
               r"[\s\S]*?# <<< pdg-adblock managed block \(internal_sequence\)\n", "", s)
    rebuilt = s.encode()
    if b"explicit_proxy" in rebuilt:
        bad("重建 v1.7.0 模板失败: 摘除后仍残留 explicit_proxy")
        return rebuilt, "rebuilt-broken"
    if tag is not None:
        if sha(tag) == sha(rebuilt):
            ok("基准模板: 重建结果与 `git show v1.7.0:` 逐字节一致(退化路径已被验证等价)")
        else:
            ok("基准模板: 用 tag v1.7.0 的真实产物(重建版与之有差异, 以 tag 为准)")
        return tag, "tag"
    if os.environ.get("PDG_TEST_STRICT") or os.environ.get("CI") == "true":
        bad("取不到 tag v1.7.0(仓库历史不完整; CI 要 fetch-depth: 0), 严格模式下不接受重建版")
    else:
        print("[*] 取不到 tag v1.7.0, 用重建版(本地浅克隆常见)")
    return rebuilt, "rebuilt"


BASE, BASE_SRC = v170_template()

print("── A. 编辑器: 幂等补齐 / 顺序自检 / fail-closed ──")
work = Path(tmpguard.mkdtemp(prefix="explicit-proxy."))
try:
    # A0: 基准就是"有病的那一版" —— 先证明它确实没有这道判断, 否则后面全是空跑
    if b"explicit_proxy" not in BASE:
        ok("基准(v1.7.0 %s): 确实没有 explicit_proxy —— 这正是要修的形态" % BASE_SRC)
    else:
        bad("基准里已经有 explicit_proxy, 用例失去意义")

    # A1: 补齐
    f = work / "a1.yaml"
    f.write_bytes(BASE)
    before = f.read_bytes()
    rc, out, err = run_editor(str(f))
    txt = f.read_text()
    if rc == 0 and out == "changed":
        ok("A1 编辑器对 v1.7.0 模板返回 changed")
    else:
        bad("A1 编辑器 rc=%d out=%r err=%r" % (rc, out, err))
    have = (re.search(r"- tag: explicit_proxy\n\s*type: domain_set", txt),
            re.search(r"- tag: explicit_proxy_seq\n\s*type: sequence", txt),
            "qname $explicit_proxy" in txt)
    ok("A1 域名集/序列/判断三样齐全") if all(have) else bad("A1 缺件: %r" % (have,))
    for rf in ("custom_hijack.txt", "ruleset_hijack.txt"):
        (ok if ("/etc/mosdns/rules/" + rf) in txt else bad)("A1 明确代理集包含 %s" % rf)
    order = gate_before_cn(txt)
    if order == (True, True):
        ok("A1 顺序: force_hijack → explicit_proxy → geosite_cn")
    else:
        bad("A1 顺序不对: %r" % (order,))
    # 劫持序列必须**独立**于 MITM 那条 —— 普通代理域名不得被送进 pdg-mitm
    if "goto explicit_proxy_seq" in txt and "goto force_hijack_seq" in txt:
        ok("A1 明确代理走自己的序列, 没有复用 force_hijack_seq(不会误送 pdg-mitm)")
    else:
        bad("A1 两条劫持序列没有分开")
    # A 劫持目标必须是传入的网关地址
    m = re.search(r"- tag: explicit_proxy_seq[\s\S]*?black_hole (\S+)", txt)
    if m and m.group(1) == "177.0.142.200":
        ok("A1 A 记录劫持到传入的网关地址")
    else:
        bad("A1 black_hole 目标错: %r" % (m.group(1) if m else None))
    # 用户既有内容不得被动过: 上游、缓存大小、劫持集、限流等原样保留
    kept = all(k in txt for k in ("223.5.5.5", "__HIJACK_SET_FILE__", "client_limiter",
                                  "__MOSDNS_CACHE__", "unlock.txt"))
    ok("A1 用户上游/劫持集/限流/解锁支原样保留") if kept else bad("A1 既有配置被动过")

    # A2: 幂等
    snap = f.read_bytes()
    rc, out, _ = run_editor(str(f))
    if rc == 0 and out == "nochange" and f.read_bytes() == snap:
        ok("A2 二跑 nochange 且文件逐字节不变(幂等)")
    else:
        bad("A2 幂等失败: rc=%d out=%r 变化=%s" % (rc, out, f.read_bytes() != snap))

    # A3: 当前模板(已经是新形态)→ nochange
    f3 = work / "a3.yaml"
    shutil.copy(ROOT / "deploy/mosdns/config.yaml", f3)
    snap3 = f3.read_bytes()
    rc, out, _ = run_editor(str(f3))
    if rc == 0 and out == "nochange" and f3.read_bytes() == snap3:
        ok("A3 当前模板已是新形态 → nochange, 不重复插入")
    else:
        bad("A3 对当前模板不幂等: rc=%d out=%r" % (rc, out))

    # A4: 形态不认识 → fail-closed, 一个字节都不写
    f4 = work / "a4.yaml"
    weird = BASE.decode()
    weird = re.sub(r"  - tag: force_hijack\n    type: domain_set\n    args: \{[^\n]*\n", "", weird)
    f4.write_text(weird)
    snap4 = f4.read_bytes()
    rc, out, err = run_editor(str(f4))
    if rc != 0 and f4.read_bytes() == snap4:
        ok("A4 认不出的自定义形态 → 拒绝且文件未被写入(fail-closed)")
    else:
        bad("A4 该拒绝却 rc=%d, 文件变了=%s" % (rc, f4.read_bytes() != snap4))

    # A5: 顺序自检真的在把关 —— 造一份 geosite_cn 排在 force_hijack **之前**的配置,
    #     照着锚点插入会得到"判断在 CN 之后"的错误结果, 编辑器必须发现并拒绝落盘。
    f5 = work / "a5.yaml"
    t = BASE.decode()
    blk_cn = ("      - matches: qname $geosite_cn\n        exec: $ecs_china\n"
              "      - matches: qname $geosite_cn\n        exec: $local_upstream\n")
    if blk_cn not in t:
        bad("A5 前置: 基准里找不到 geosite_cn 判断块, 无法构造")
    else:
        t2 = t.replace(blk_cn, "", 1)
        t2 = t2.replace("      # MITM 接管域名: 强制劫持", blk_cn + "      # MITM 接管域名: 强制劫持", 1)
        f5.write_text(t2)
        snap5 = f5.read_bytes()
        rc, out, err = run_editor(str(f5))
        if rc != 0 and f5.read_bytes() == snap5:
            ok("A5 插入后顺序会不对 → 拒绝并且不落盘(顺序自检不是摆设)")
        else:
            bad("A5 顺序自检没拦住: rc=%d 文件变了=%s" % (rc, f5.read_bytes() != snap5))
finally:
    shutil.rmtree(work, ignore_errors=True)

# ── B. 事务路径: 校验失败 / 重启失败 → 现网配置字节不变 ──────────────────────
print()
print("── B. 事务: 候选校验失败 / 服务重启失败 → 现网不变 ──")
from txbox import Box  # noqa: E402

MOSDNS_BIN = shutil.which("mosdns") or "/usr/local/bin/mosdns"
if not os.access(MOSDNS_BIN, os.X_OK):
    msg = "B 段需要真 mosdns(事务的 mosdns_probe 会真启动它)"
    if os.environ.get("PDG_TEST_STRICT") or os.environ.get("CI") == "true":
        bad(msg + " —— 严格模式判失败")
    else:
        print("[SKIP] " + msg)
else:
    def live_config(base_bytes, box):
        """把模板渲染成一份能在沙箱里真启动的 mosdns 配置。

        两处必要的夹具改动(都不触碰被测判据):
          · 去掉 dot_server —— 沙箱里没有真证书, 那验的是"缺证书", 不是事务语义;
          · 规则文件路径指向沙箱里的 /etc/mosdns/rules —— 探针是**真的启动 mosdns**,
            配置里写死的宿主绝对路径在这台机器上并不存在, 于是三个用例都会以同一个
            "文件不存在"失败。那样 B1/B2 会因为**错误的原因**变绿。"""
        s = base_bytes.decode()
        s = s.split("  - tag: dot_server")[0]
        s = (s.replace("__SERVER_IP__", "10.99.99.99")
              .replace("__INTERNAL_CIDR__", "127.0.0.0/8")
              .replace("__MOSDNS_CACHE__", "1024")
              .replace("__HIJACK_SET_FILE__", "geosite_geolocation-!cn.txt"))
        return s.encode()

    def prefix_rules(data, box):
        """把配置里的规则路径一次性重定向到沙箱。只能对**未重定向过**的内容调用一次 ——
        重复调用会把 /tmp/box/etc/mosdns/rules 再套一层 /tmp/box。"""
        assert box.root.encode() not in data, "prefix_rules 被重复调用了"
        return data.replace(b"/etc/mosdns/rules/", (box.root + "/etc/mosdns/rules/").encode())

    def seed(box):
        for leaf in ("geosite_cn", "geosite_apple", "custom_direct", "custom_hijack",
                     "ruleset_hijack", "unlock", "mitm_hijack", "geosite_gfw",
                     "geosite_geolocation-!cn"):
            box.put("/etc/mosdns/rules/%s.txt" % leaf, b"", 0o644)

    def tx(box, *args):
        return subprocess.run([sys.executable, str(ROOT / "deploy/bot/pdgtx.py")] + list(args),
                              capture_output=True, text=True, timeout=300,
                              env={**os.environ, **box.env})

    def scenario(name, svc_fail=None, break_candidate=False):
        box = Box(svc_fail=svc_fail or [])
        try:
            box.up("mosdns")
            box.up("mihomo")
            seed(box)
            raw = live_config(BASE, box)              # 还带着生产路径
            box.put("/etc/mosdns/config.yaml", prefix_rules(raw, box), 0o644)
            before = box.read("/etc/mosdns/config.yaml")
            cand = Path(box.root) / "cand.yaml"
            cand.write_bytes(raw)                     # 编辑器在生产路径形态上工作
            rc, out, err = run_editor(str(cand), "10.99.99.99")
            if rc != 0 or out != "changed":
                bad("%s: 候选生成失败 rc=%d out=%r err=%r" % (name, rc, out, err))
                return None
            cand.write_bytes(prefix_rules(cand.read_bytes(), box))   # 再整体重定向一次
            if break_candidate:
                cand.write_bytes(cand.read_bytes() + b"\nplugins: [[[ not yaml\n")
            r = tx(box, "new", "--source", "test", "--op", "mosdns-explicit-proxy")
            txid = r.stdout.strip()
            if not txid:
                bad("%s: 开事务失败 %r" % (name, r.stderr[-200:]))
                return None
            r = tx(box, "read", "--target", "mosdns_conf")
            cur_sha = r.stdout.splitlines()[0] if r.stdout else "-"
            st = tx(box, "stage", "--tx", txid, "--target", "mosdns_conf",
                    "--file", str(cand), "--expect", cur_sha)
            sv = tx(box, "service", "--tx", txid, "--action", "restart:mosdns")
            ap = tx(box, "apply", "--tx", txid)
            after = box.read("/etc/mosdns/config.yaml")
            return {"stage_rc": st.returncode, "apply_rc": ap.returncode,
                    "before": before, "after": after, "cand": cand.read_bytes(),
                    "err": (st.stderr + sv.stderr + ap.stderr)[-300:]}
        finally:
            box.clean()

    r = scenario("B0 正常路径")
    if r is None:
        pass
    elif r["apply_rc"] == 0 and r["after"] == r["cand"] and r["after"] != r["before"]:
        ok("B0 正常路径: 事务提交, 现网配置换成候选")
    else:
        bad("B0 正常路径没走通: apply_rc=%s 变化=%s err=%s"
            % (r["apply_rc"], r["after"] != r["before"], r["err"]))

    r = scenario("B1 候选坏", break_candidate=True)
    if r is None:
        pass
    elif r["after"] == r["before"] and (r["stage_rc"] != 0 or r["apply_rc"] != 0):
        ok("B1 候选过不了 mosdns 强校验 → 现网配置逐字节不变")
    else:
        bad("B1 坏候选竟被接受: stage=%s apply=%s 变化=%s"
            % (r["stage_rc"], r["apply_rc"], r["after"] != r["before"]))

    r = scenario("B2 重启失败", svc_fail=["mosdns"])
    if r is None:
        pass
    elif r["after"] == r["before"] and r["apply_rc"] != 0:
        ok("B2 mosdns 重启失败 → 整笔回滚, 现网配置逐字节不变")
    else:
        bad("B2 重启失败却没回滚: apply=%s 变化=%s err=%s"
            % (r["apply_rc"], r["after"] != r["before"], r["err"]))

# ── C. doctor 必须点名未迁移的机器 ───────────────────────────────────────────
print()
print("── C. doctor: 点名未迁移 / 顺序反了判 fail ──")
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

cwork = Path(tmpguard.mkdtemp(prefix="explicit-proxy-doctor."))
try:
    def with_conf(text):
        f = cwork / "config.yaml"
        f.write_text(text)
        checks._mos = lambda _f=f: _f.read_text()
        return checks.check_mosdns_explicit_proxy()

    lvl, label, detail = with_conf(BASE.decode())
    if lvl == "warn" and "未迁移" in detail and "config.yaml" in detail:
        ok("C1 v1.7.0 形态 → warn 且点名这台机器的 config.yaml 未迁移")
    else:
        bad("C1 未点名: %r" % ((lvl, detail[:120]),))

    good = (ROOT / "deploy/mosdns/config.yaml").read_text()
    lvl, label, detail = with_conf(good)
    ok("C2 新模板 → ok") if lvl == "ok" else bad("C2 新模板判成 %s: %s" % (lvl, detail[:120]))

    # 顺序反了: 把判断挪到 geosite_cn 之后
    bad_order = good.replace(
        "      - matches: qname $explicit_proxy\n        exec: goto explicit_proxy_seq\n", "", 1)
    bad_order = bad_order.replace(
        "      - matches: qname $geosite_cn\n        exec: $local_upstream\n",
        "      - matches: qname $geosite_cn\n        exec: $local_upstream\n"
        "      - matches: qname $explicit_proxy\n        exec: goto explicit_proxy_seq\n", 1)
    lvl, label, detail = with_conf(bad_order)
    if lvl == "fail" and "之后" in detail:
        ok("C3 判断排在 geosite_cn 之后 → fail")
    else:
        bad("C3 顺序反了却判成 %s: %s" % (lvl, detail[:120]))

    # 缺文件也要说清楚缺哪个
    miss = good.replace(',"/etc/mosdns/rules/ruleset_hijack.txt"', "", 1)
    lvl, label, detail = with_conf(miss)
    if lvl == "warn" and "ruleset_hijack.txt" in detail:
        ok("C4 域名集缺文件 → warn 并指名缺的是哪个")
    else:
        bad("C4 缺文件没被指出来: %r" % ((lvl, detail[:120]),))
finally:
    shutil.rmtree(cwork, ignore_errors=True)

print("────────────────────────────────────────")
print("通过 %d, 失败 %d" % (pass_n, fail_n))
sys.exit(1 if fail_n else 0)

#!/usr/bin/env python3
"""内网卡段变更的**事务化**回归(5.2/commit 3)。

detect-cidr 要同时改三份生产文件(profile.env 真源 / nftables.conf / mosdns 配置)。旧实现是
"自己打快照 + cp -a 备份 + sed 改临时副本 + 手写 _dc_restore 还原": 落盘落一半、nft 应用失败、
mosdns 起不来各走各的还原分支, 而还原本身没有复核 —— 出事只能提示用户自己去 doctor。
现在整段收进一笔 pdgtx 事务, 于是校验门、before-image、观察期、失败回滚全都复用 5.1。

这里用真沙箱(txbox.Box: 真文件树 + 假 systemctl/nft/mosdns + 真 DNS/TCP 探针落点)真的把事务
跑起来, 逐个注入故障, 每次都**逐字节**核对三个目标是否回到操作前。不做源码字符串断言。
"""
import hashlib
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from txbox import Box, load_tx  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-4f9a2c"      # 不该出现在日志/审计/输出里的哨兵


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def _gen():
    spec = importlib.util.spec_from_file_location(
        "cidrgen", os.path.join(ROOT, "deploy/bot/cidrgen.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


gen = _gen()

NFT_BASE = """table inet pdg
delete table inet pdg
table inet pdg {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893
    }
    chain input {
        type filter hook input priority 0; policy drop;
        ip saddr 172.22.0.0/16 tcp dport { 53, 853 } accept
    }
}
# 用户自定义区(不该被事务弄丢)
table inet myown { chain c { type filter hook input priority 10; } }
"""
MOS_BASE = (
    "log:\n  level: error\n"
    "plugins:\n"
    "  - tag: npn_clients\n"
    "    type: ip_set\n"
    '    args: { ips: ["172.22.0.0/16"] }\n'
    "  - tag: main_sequence\n"
    "    type: sequence\n"
    "    args:\n"
    "      - matches: client_ip $npn_clients\n"
    "        exec: reject 3\n"
    "      - exec: reject 3\n"
    # 必须带一个真的 server 插件。少了它这份配置根本不提供 DNS, 而事务的 mosdns_probe
    # 在启动探针前要先把监听地址挪到 127.0.0.1 的随机高端口 —— 一个**没有任何监听项**的
    # 候选让它无从下手, 于是按设计拒绝"在生产端口上做探针", 整笔事务 REFUSED。
    # 本地跑不到这条分支(没有 netns 权限, 探针提前返回), CI 上有权限就撞上了。
    "  - tag: udp_server\n"
    "    type: udp_server\n"
    '    args: {entry: main_sequence, listen: "127.0.0.1:0"}\n'
)
PROF_BASE = ("PDG_LOWMEM=0\nPDG_HIJACK_MODE=gfw\nPDG_PLATFORM=ios\n"
             "PDG_INTERNAL_CIDR=172.22.0.0/16\nPDG_TFO=1\n# 用户自己加的注释\nMY_OWN_KEY=keep-me\n")

OLD, NEW = "172.22.0.0/16", "10.99.0.0/16"


def seed(box):
    """把三个目标写进沙箱, 返回操作前的逐字节快照。

    mosdns 要先处于 active: 事务的基线门要求"本次要动的组件操作前是好的" —— 那条判据不该为了
    测试关掉, 所以这里让桩服务真的处于运行态(故障注入用例自己会再把它弄坏)。"""
    box.up("mosdns")
    files = {
        "profile_env": (box.root + "/etc/privdns-gateway/profile.env", PROF_BASE),
        "nftables_conf": (box.root + "/etc/nftables.conf", NFT_BASE),
        "mosdns_conf": (box.root + "/etc/mosdns/config.yaml", MOS_BASE),
    }
    for _t, (p, text) in files.items():
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    return {t: open(p, "rb").read() for t, (p, _x) in files.items()}, \
           {t: p for t, (p, _x) in files.items()}


def unchanged(paths, before, label):
    """三个目标是否逐字节保持操作前状态。"""
    bad_ones = []
    for t, p in paths.items():
        cur = open(p, "rb").read() if os.path.exists(p) else None
        if cur != before[t]:
            bad_ones.append(t)
    if not bad_ones:
        ok("%s: 三个目标逐字节保持操作前状态" % label)
    else:
        bad("%s: 这些目标被改动了: %s" % (label, ", ".join(bad_ones)))


def run_tx(box, new_cidr=NEW, old=OLD, stage_bad=None, service_actions=("nft:apply", "restart:mosdns")):
    """真的跑一笔事务(与 pdg.sh 里 _pdg_cidr_transact 同样的步骤序列)。"""
    tx = load_tx(box.env)
    t = tx.Tx(source="cli", op="detect-cidr")
    try:
        for target, kind, arg in (("profile_env", "profile", ""),
                                  ("nftables_conf", "nft", old),
                                  ("mosdns_conf", "mosdns", "")):
            cur, sha = t.read_for_update(target)
            text = (cur or b"").decode("utf-8")
            if kind == "profile":
                out, _c = gen.profile_set(text, new_cidr)
            elif kind == "nft":
                out, n = gen.nft_replace(text, new_cidr, arg)
                if out is None:
                    raise RuntimeError("nft 候选生成失败")
            else:
                out, n = gen.mosdns_replace(text, new_cidr)
                if out is None:
                    raise RuntimeError("mosdns 候选生成失败")
            if stage_bad == target:
                out = "### 故意写坏的候选 ###\n" + out
            t.stage(target, out.encode("utf-8"), expect=sha)
        for a in service_actions:
            t.service(a)
        return t.commit(), tx, t
    except Exception as e:  # noqa: BLE001
        try:
            t.abort_unstarted("测试注入: %s" % type(e).__name__)
        except Exception:  # noqa: BLE001
            pass
        return {"state": "ABORTED", "error": str(e)}, tx, t


# ── 1. 纯函数层: 候选生成 ────────────────────────────────────────────────────
out, changed = gen.profile_set(PROF_BASE, NEW)
if "PDG_INTERNAL_CIDR=10.99.0.0/16" in out and "MY_OWN_KEY=keep-me" in out \
        and "# 用户自己加的注释" in out and "PDG_TFO=1" in out:
    ok("候选(profile): 只改真源键, 其它键/注释原样保留")
else:
    bad("profile 候选把别的内容弄丢了: %r" % out)
if [l.split("=")[0] for l in out.splitlines() if "=" in l] == \
   [l.split("=")[0] for l in PROF_BASE.splitlines() if "=" in l]:
    ok("候选(profile): 行序未被重排")
else:
    bad("profile 行序变了")
out2, _c = gen.profile_set("PDG_LOWMEM=0\n", NEW)
if out2.endswith("PDG_INTERNAL_CIDR=%s\n" % NEW) and out2.startswith("PDG_LOWMEM=0\n"):
    ok("候选(profile): 键不存在时追加到末尾")
else:
    bad("追加位置不对: %r" % out2)
nout, n = gen.nft_replace(NFT_BASE, NEW, OLD)
if n == 2 and nout.count(NEW) == 2 and "myown" in nout:
    ok("候选(nft): 旧段的每一处都替换, 用户自定义表原样保留")
else:
    bad("nft 候选不对: n=%s" % n)
# nft 候选的**边界**: 朴素 str.replace 会把 110.9.0.0/16 与 10.9.0.0/160 一起改坏, 而改坏的
# 是防火墙; 注释与引号里的字面量是人写给人看的说明, 改掉等于篡改别人的文档。
_tricky = (
    "    ip saddr 10.9.0.0/16 tcp dport { 53 } accept    # 老段 10.9.0.0/16 的说明\n"
    "    ip saddr 110.9.0.0/16 accept\n"
    "    ip saddr 10.9.0.0/160 accept\n"
    '    ip saddr 10.9.0.0/16 udp dport 53 accept comment "keep 10.9.0.0/16 here"\n'
    "# 纯注释行: 10.9.0.0/16\n"
    "    ip saddr 10.9.0.0/8 accept\n"
)
_t_out, _t_n = gen.nft_replace(_tricky, "172.22.0.0/16", "10.9.0.0/16")
_lines = _t_out.splitlines()
if _t_n == 2:
    ok("候选(nft): 只替换 2 处完整旧段(相似段/注释/字符串都不算)")
else:
    bad("替换次数不对: %d\n%s" % (_t_n, _t_out))
if "110.9.0.0/16" in _t_out and "10.9.0.0/160" in _t_out and "10.9.0.0/8" in _t_out:
    ok("候选(nft): 前缀相似/后缀相似/不同掩码的段都没被误改")
else:
    bad("相似段被误改了:\n%s" % _t_out)
if "# 老段 10.9.0.0/16 的说明" in _t_out and "# 纯注释行: 10.9.0.0/16" in _t_out:
    ok("候选(nft): 注释里的旧段原样保留")
else:
    bad("注释被改了:\n%s" % _t_out)
if 'comment "keep 10.9.0.0/16 here"' in _t_out:
    ok("候选(nft): 引号字符串里的旧段原样保留")
else:
    bad("字符串被改了:\n%s" % _t_out)
if _lines[0].startswith("    ip saddr 172.22.0.0/16") and "172.22.0.0/16 udp" in _lines[3]:
    ok("候选(nft): 两条真规则里的完整旧段都换成了新段")
else:
    bad("真规则没换对:\n%s" % _t_out)

if gen.nft_replace(NFT_BASE, NEW, "10.1.2.0/24") == (None, 0):
    ok("候选(nft): 找不到旧段时返回失败(不猜位置插入)")
else:
    bad("nft 找不到旧段却生成了候选")
# 现网"当前段"也只能从**真规则**里读: 本项目渲染出的 nft 头部注释里同样写着这个段, 而注释不
# 参与替换 —— 拿注释里的旧值当当前值, 改过一次之后就会去找一个真规则里根本不存在的段, 于是
# 把正常的 nft 判成"自定义形态"而拒绝执行(e2e-cli-ops 的幂等用例真踩到过)。
_cur_txt = ("# 安全要点: REDIRECT 只匹配 `ip saddr 127.0.0.0/8`(旧段, 注释没跟着改)\n"
            "table inet pdg {\n"
            "    chain input {\n"
            "        ip saddr 10.44.0.0/16 tcp dport { 53 } accept\n"
            "    }\n}\n")
if gen.nft_current(_cur_txt) == "10.44.0.0/16":
    ok("nft_current: 只认真规则里的段, 不被过时注释带偏")
else:
    bad("nft_current 读到了注释里的值: %r" % gen.nft_current(_cur_txt))
if gen.nft_current('table inet pdg { chain c { comment "ip saddr 10.9.0.0/16" } }\n') == "":
    ok("nft_current: 字符串里的段不算")
else:
    bad("nft_current 把字符串里的当成了当前段")
if gen.nft_current("# 只有注释: ip saddr 10.9.0.0/16\n") == "":
    ok("nft_current: 只有注释时返回空(调用方据此判'读不到')")
else:
    bad("只有注释却返回了值")

mout, mn = gen.mosdns_replace(MOS_BASE, NEW)
if mn == 1 and NEW in mout and OLD not in mout:
    ok("候选(mosdns): 只换 ips 那一个值")
else:
    bad("mosdns 候选不对")
if gen.mosdns_replace("plugins: []\n", NEW) == (None, 0):
    ok("候选(mosdns): 找不到 ips 段时返回失败")
else:
    bad("mosdns 找不到 ips 却生成了候选")
for bad_cidr, why in (("1.2.3.0/24", "公网"), ("0.0.0.0/0", "全网"), ("not-a-cidr", "形态"),
                      ("172.22.0.0/33", "掩码")):
    good, _w = gen.valid_cidr(bad_cidr)
    if not good:
        ok("非法输入被拒: %s(%s)" % (bad_cidr, why))
    else:
        bad("%s 竟然通过了校验" % bad_cidr)
for good_cidr in ("172.22.0.0/16", "10.9.0.0/16", "192.168.1.0/24", "100.64.0.0/10"):
    g, w = gen.valid_cidr(good_cidr)
    if not g:
        bad("合法私网段被误拒: %s (%s)" % (good_cidr, w))
if all(gen.valid_cidr(c)[0] for c in ("172.22.0.0/16", "10.9.0.0/16", "100.64.0.0/10")):
    ok("私网/CGNAT 段正常通过")

# ── 2. 正常路径: 一笔事务改三个目标 ─────────────────────────────────────────
box = Box()
before, paths = seed(box)
res, txmod, _t = run_tx(box)
if res.get("state") == "COMMITTED":
    ok("正常路径: 事务 COMMITTED")
else:
    bad("正常路径没提交: %r" % res)
after = {t: open(p, encoding="utf-8").read() for t, p in paths.items()}
if ("PDG_INTERNAL_CIDR=%s" % NEW) in after["profile_env"] and "MY_OWN_KEY=keep-me" in after["profile_env"]:
    ok("正常路径: 真源已更新且其它键完好")
else:
    bad("真源没更新: %r" % after["profile_env"])
if after["nftables_conf"].count(NEW) == 2 and OLD not in after["nftables_conf"]:
    ok("正常路径: 防火墙两处都换了")
else:
    bad("nft 没换全")
if NEW in after["mosdns_conf"] and OLD not in after["mosdns_conf"]:
    ok("正常路径: mosdns 已更新")
else:
    bad("mosdns 没更新")
calls = open(box.calls, encoding="utf-8").read()
if "nft -f" in calls and "restart mosdns" in calls:
    ok("正常路径: nft 应用与 mosdns 重启都真的发生了")
else:
    bad("服务动作没执行: %r" % calls[-300:])
box.clean()

# ── 3. 幂等: 同一个 CIDR 再来一次 ───────────────────────────────────────────
box = Box()
before, paths = seed(box)
res, _m, _t = run_tx(box, new_cidr=OLD, old=OLD)     # 目标值 == 现状
if res.get("state") == "COMMITTED":
    ok("幂等: 相同 CIDR 的事务仍然干净提交")
else:
    bad("幂等路径失败: %r" % res)
unchanged(paths, before, "幂等")
box.clean()

# ── 4. 候选生成失败(nft 里没有旧段)→ 事务不该开始动现网 ────────────────────
box = Box()
before, paths = seed(box)
res, _m, _t = run_tx(box, old="10.1.2.0/24")
if res.get("state") == "ABORTED":
    ok("候选生成失败: 事务转 ABORTED, 未进入落盘阶段")
else:
    bad("候选失败却继续了: %r" % res)
unchanged(paths, before, "候选生成失败")
box.clean()

# ── 5. nft -c 校验失败 ──────────────────────────────────────────────────────
box = Box()
box._simple("nft", 1)                                # 假 nft: 一律校验失败
before, paths = seed(box)
res, _m, _t = run_tx(box)
if res.get("state") in ("ROLLED_BACK", "ABORTED") and res.get("state") != "COMMITTED":
    ok("nft 校验失败: 事务未提交(%s)" % res.get("state"))
else:
    bad("nft 校验失败却提交了: %r" % res)
unchanged(paths, before, "nft 校验失败")
box.clean()

# ── 6. 服务重启失败 → 回滚 ──────────────────────────────────────────────────
box = Box(svc_fail=["mosdns"])
before, paths = seed(box)
res, _m, _t = run_tx(box)
# 桩把 mosdns 的**每一次** restart 都拒掉 —— 包括回滚阶段那一次。于是诚实的终态是
# ROLLBACK_FAILED(文件回去了、服务没能起回来), 而不是宣称"已完全回滚"。
if res.get("state") == "ROLLBACK_FAILED" and res.get("rollback_complete") is False:
    ok("mosdns 重启失败: 终态 ROLLBACK_FAILED 且 rollback_complete=False(不谎报)")
else:
    bad("重启失败的终态不对: %r" % res)
if any("mosdns" in x for x in res.get("rollback_failed_items") or []):
    ok("mosdns 重启失败: 未完成项点名了 mosdns")
else:
    bad("没点名未完成项: %r" % res.get("rollback_failed_items"))
unchanged(paths, before, "重启失败回滚后")
box.clean()

# ── 7. 观察期退化(重启成功但服务随即 failed)→ 回滚 ─────────────────────────
# 桩的崩溃模拟: restart 时看到沙箱 config.json 里的 CRASHME 就进入"起来即崩"(NRestarts 每问
# 一次涨一次), 观察期的 svc_stable 正是靠 NRestarts 判定"起来了又倒下"。直接摆 ActiveState
# 没用 —— restart 分支会把它清掉, 那样验的就不是观察期而是重启本身。
box = Box(restart_crash=True)
os.makedirs(box.root + "/etc/sing-box", exist_ok=True)
with open(box.root + "/etc/sing-box/config.json", "w", encoding="utf-8") as f:
    f.write('{"note": "CRASHME"}\n')
before, paths = seed(box)
res, _m, _t = run_tx(box, service_actions=("restart:mosdns",))
if res.get("state") in ("ROLLED_BACK", "ROLLBACK_FAILED") and res.get("state") != "COMMITTED":
    ok("观察期退化: 事务未提交(%s)" % res.get("state"))
else:
    bad("观察期退化却提交了: %r" % res)
box.clean()

# ── 8. 操作前硬门就是坏的 → 普通变更直接拒绝(现网不动) ─────────────────────
# 这条不是"落盘后退化"(那由 5.1 的事务回归覆盖), 而是基线门: DNS 探针在事务开始前就没落点时,
# detect-cidr 这类普通变更必须拒绝执行 —— 在已经坏掉的组件上叠一次变更, 出了事分不清是谁弄坏的。
box = Box()
before, paths = seed(box)
box.stop_probes()
tx = load_tx(box.env)
t = tx.Tx(source="cli", op="detect-cidr")
cur, sha = t.read_for_update("mosdns_conf")
out, _n = gen.mosdns_replace(cur.decode("utf-8"), NEW)
t.stage("mosdns_conf", out.encode("utf-8"), expect=sha)
t.service("restart:mosdns")
refused = ""
try:
    t.commit()
except Exception as e:  # noqa: BLE001
    refused = type(e).__name__
if refused == "TxRefused":
    ok("基线门: 操作前硬门就坏 → 抛 TxRefused, 普通变更拒绝执行")
else:
    bad("基线门没拦住, 结果: %r" % refused)
unchanged(paths, before, "基线门拒绝后")
box.clean()

# ── 9. expect_sha256 冲突: 生成候选后有人改了同一个文件 ─────────────────────
box = Box()
before, paths = seed(box)
tx = load_tx(box.env)
t = tx.Tx(source="cli", op="detect-cidr")
cur, sha = t.read_for_update("mosdns_conf")
out, _n = gen.mosdns_replace(cur.decode("utf-8"), NEW)
with open(paths["mosdns_conf"], "a", encoding="utf-8") as f:   # 事务之外的改动
    f.write("# 有人在事务进行中改了这个文件\n")
t.stage("mosdns_conf", out.encode("utf-8"), expect=sha)
conflict = ""
try:
    res = t.commit()
    conflict = "COMMITTED" if res.get("state") == "COMMITTED" else res.get("state")
except Exception as e:  # noqa: BLE001
    conflict = type(e).__name__ + ":" + str(e)
if "PRECONDITION_FAILED" in conflict:
    ok("expect 冲突: 前置条件不符 → TxRefused(PRECONDITION_FAILED), 不覆盖别人的修改")
else:
    bad("expect 冲突的结果不对: %r" % conflict)
# 现网必须还是"别人改过之后"的样子 —— 既不回滚掉他的修改, 也不盖上我们的候选
cur_now = open(paths["mosdns_conf"], encoding="utf-8").read()
if "有人在事务进行中改了这个文件" in cur_now and NEW not in cur_now:
    ok("expect 冲突: 现网保持第三方修改后的内容, 候选没被写进去")
else:
    bad("expect 冲突后现网内容不对: %r" % cur_now[-120:])
box.clean()

# ── 10. 锁被占用 → fail-closed ──────────────────────────────────────────────
box = Box()
before, paths = seed(box)
tx = load_tx(box.env)
lock = tx._Lock()
lock.__enter__()                                     # 先把锁拿走
t = tx.Tx(source="cli", op="detect-cidr")
cur, sha = t.read_for_update("profile_env")
t.stage("profile_env", gen.profile_set(cur.decode("utf-8"), NEW)[0].encode("utf-8"), expect=sha)
busy = False
try:
    t.commit()
except Exception as e:  # noqa: BLE001
    busy = type(e).__name__ == "TxBusy"
lock.__exit__()
if busy:
    ok("锁被占用: 抛 TxBusy, 未改动现网")
else:
    bad("锁被占用却没有 TxBusy")
unchanged(paths, before, "锁被占用")
box.clean()

# ── 11. 回滚失败 → ROLLBACK_FAILED(不谎报) ─────────────────────────────────
box = Box(svc_fail=["mosdns"])
before, paths = seed(box)
tx = load_tx(box.env)
t = tx.Tx(source="cli", op="detect-cidr")
cur, sha = t.read_for_update("mosdns_conf")
out, _n = gen.mosdns_replace(cur.decode("utf-8"), NEW)
t.stage("mosdns_conf", out.encode("utf-8"), expect=sha)
t.service("restart:mosdns")
_orig_aw = tx.atomic_write
_state = {"n": 0}


def _flaky(path, data, mode=0o600, uid=None, gid=None):
    # 回滚阶段写 mosdns 配置时失败 —— 制造"回滚本身没做完"
    if path.endswith("/etc/mosdns/config.yaml") and _state["n"] >= 1:
        raise OSError("注入: 回滚写入失败")
    if path.endswith("/etc/mosdns/config.yaml"):
        _state["n"] += 1
    return _orig_aw(path, data, mode, uid, gid)


tx.atomic_write = _flaky
res = t.commit()
tx.atomic_write = _orig_aw
if res.get("state") == "ROLLBACK_FAILED" and not res.get("rollback_complete", True):
    ok("回滚失败: 如实进入 ROLLBACK_FAILED, 不谎报成功")
else:
    bad("回滚失败没被如实标记: %r" % res)
box.clean()

# ── 12. SECRET_SENTINEL 不进日志/审计/输出 ──────────────────────────────────
box = Box()
before, paths = seed(box)
with open(paths["profile_env"], "a", encoding="utf-8") as f:
    f.write("PDG_BOT_TOKEN=123456789:%s\n" % SENTINEL)
res, txmod, _t = run_tx(box)
audit = os.path.join(box.root, "var/lib/privdns-gateway/tx/index.jsonl")
leaks = []
if os.path.exists(audit) and SENTINEL in open(audit, encoding="utf-8").read():
    leaks.append("审计")
if SENTINEL in repr(res):
    leaks.append("事务返回值")
if SENTINEL in open(box.calls, encoding="utf-8").read():
    leaks.append("命令日志")
if not leaks:
    ok("哨兵不出现在审计 / 事务返回值 / 命令日志里")
else:
    bad("哨兵泄漏到: %s" % ", ".join(leaks))
# 但真源文件本身当然要保留那一行(它是用户的配置, 不是日志)
if SENTINEL in open(paths["profile_env"], encoding="utf-8").read():
    ok("候选生成没有误删 profile.env 里的其它键(含带凭据的那行)")
else:
    bad("候选把用户的其它键弄丢了")
box.clean()

# ── 13. 第 N 个目标落盘失败 → 已落盘的要回滚 ───────────────────────────────
box = Box()
before, paths = seed(box)
tx = load_tx(box.env)
t = tx.Tx(source="cli", op="detect-cidr")
for target, kind, arg in (("profile_env", "profile", ""), ("nftables_conf", "nft", OLD),
                          ("mosdns_conf", "mosdns", "")):
    cur, sha = t.read_for_update(target)
    text = (cur or b"").decode("utf-8")
    out = (gen.profile_set(text, NEW)[0] if kind == "profile" else
           gen.nft_replace(text, NEW, arg)[0] if kind == "nft" else
           gen.mosdns_replace(text, NEW)[0])
    t.stage(target, out.encode("utf-8"), expect=sha)
_orig_aw2 = tx.atomic_write


def _fail_third(path, data, mode=0o600, uid=None, gid=None):
    if path.endswith("/etc/mosdns/config.yaml"):
        raise OSError("注入: 第三个目标落盘失败")
    return _orig_aw2(path, data, mode, uid, gid)


tx.atomic_write = _fail_third
res = t.commit()
tx.atomic_write = _orig_aw2
if res.get("state") in ("ROLLED_BACK", "ROLLBACK_FAILED"):
    ok("第 N 个目标落盘失败: 事务进入 %s" % res.get("state"))
else:
    bad("落盘失败却没回滚: %r" % res)
if res.get("state") == "ROLLED_BACK":
    unchanged(paths, before, "落盘失败回滚后")
box.clean()

# ── 13b. mosdns 证书缺失: 候选校验必须拒绝, 且现网逐字节不动 ────────────────
# 真机上 mosdns 的 dot_server 插件要读 DoT 证书; 证书没了 mosdns 本来就起不来。此时
# detect-cidr 必须**当场拒绝**并说清是证书问题, 而不是降级校验后照样落盘 —— 那样只会把一台
# "DNS 已经坏了"的机器再改一遍配置, 排查时谁也说不清是哪一步弄坏的。
MOS_WITH_DOT = (
    "log:\n  level: error\n"
    "plugins:\n"
    "  - tag: npn_clients\n"
    "    type: ip_set\n"
    '    args: { ips: ["172.22.0.0/16"] }\n'
    "  - tag: main_sequence\n"
    "    type: sequence\n"
    "    args:\n"
    "      - exec: reject 3\n"
    "  - tag: dot_server\n"
    "    type: udp_server\n"
    "    args: {entry: main_sequence, listen: \"127.0.0.1:0\"}\n"
)
box = Box()
box.up("mosdns")
_b, _p = seed(box)
# 用带 dot_server 的配置覆盖, 并把证书路径指向一个**不存在**的文件
mos_path = _p["mosdns_conf"]
cert_dir = os.path.join(box.root, "etc/mosdns/certs")
with open(mos_path, "w", encoding="utf-8") as f:
    f.write(MOS_WITH_DOT.replace(
        'args: {entry: main_sequence, listen: "127.0.0.1:0"}',
        'args: {entry: main_sequence, listen: "127.0.0.1:0", '
        'cert: "%s/fullchain.pem", key: "%s/privkey.pem"}' % (cert_dir, cert_dir))
        .replace("udp_server", "tcp_server"))
before = {t: open(p2, "rb").read() for t, p2 in _p.items()}
if not os.path.exists(os.path.join(cert_dir, "fullchain.pem")):
    ok("前提: DoT 证书确实不存在")
else:
    bad("证书居然在")
res, _m, _t = run_tx(box)
if res.get("state") != "COMMITTED":
    ok("mosdns 证书缺失: 事务未提交(%s)" % res.get("state"))
else:
    bad("证书缺失却提交了: %r" % res)
err = str(res.get("error") or "")
if "cert" in err or "证书" in err or "fullchain" in err:
    ok("mosdns 证书缺失: 错误信息点名了证书")
else:
    bad("错误没说清是证书问题: %r" % err[:200])
unchanged(_p, before, "mosdns 证书缺失")
# 不许留下 COMMITTED 的事务记录
txroot = os.path.join(box.root, "var/lib/privdns-gateway/tx")
committed = []
for d in (os.listdir(txroot) if os.path.isdir(txroot) else []):
    mp = os.path.join(txroot, d, "meta.json")
    if os.path.isfile(mp) and '"state": "COMMITTED"' in open(mp, encoding="utf-8").read():
        committed.append(d)
if not committed:
    ok("mosdns 证书缺失: 没有产生 COMMITTED 事务")
else:
    bad("产生了 COMMITTED 事务: %s" % committed)
box.clean()

# ── 14. 迁移函数本身: 成功 / 不一致 / 幂等(真跑, 不做字符串断言) ────────────
import re as _re  # noqa: E402
import tmpguard  # noqa: E402

PDG = os.path.join(ROOT, "deploy/bot/pdg.sh")
_src = open(PDG, encoding="utf-8").read()
_body = _re.search(r"^migrate_cidr_single_source\(\)\{.*?^\}", _src, _re.S | _re.M).group(0)


def run_mig(nft_text, mos_text, prof_text="PDG_LOWMEM=0\n"):
    d = tmpguard.mkdtemp()      # run_mig 会被调很多次, 每次一个沙箱 —— 必须登记, 否则全留着
    os.makedirs(d + "/etc/privdns-gateway", exist_ok=True)
    os.makedirs(d + "/etc/mosdns", exist_ok=True)
    prof = d + "/etc/privdns-gateway/profile.env"
    open(prof, "w").write(prof_text)
    if nft_text is not None:
        open(d + "/etc/nftables.conf", "w").write(nft_text)
    if mos_text is not None:
        open(d + "/etc/mosdns/config.yaml", "w").write(mos_text)
    body = _body.replace("/etc/privdns-gateway/profile.env", prof) \
                .replace("/etc/nftables.conf", d + "/etc/nftables.conf") \
                .replace("/etc/mosdns/config.yaml", d + "/etc/mosdns/config.yaml") \
                .replace("mktemp /etc/privdns-gateway/", "mktemp " + d + "/etc/privdns-gateway/")
    p = subprocess.run(["bash", "-c", "c_y(){ echo \"$*\"; }\nc_g(){ echo \"$*\"; }\n"
                        + body + "\nmigrate_cidr_single_source\n"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, timeout=60)
    return p.stdout, open(prof, encoding="utf-8").read()


out_m, prof_m = run_mig("ip saddr 172.22.0.0/16 accept\n", '  args: { ips: ["172.22.0.0/16"] }\n')
if "PDG_INTERNAL_CIDR=172.22.0.0/16" in prof_m:
    ok("迁移(真跑): 两处一致 → 写入真源")
else:
    bad("迁移没写入: %r / %r" % (prof_m, out_m))
out_m, prof_m = run_mig("ip saddr 10.0.0.0/8 accept\n", '  args: { ips: ["172.22.0.0/16"] }\n')
if "PDG_INTERNAL_CIDR" not in prof_m and "detect-cidr" in out_m:
    ok("迁移(真跑): 两处不一致 → 不写入并给出指引")
else:
    bad("迁移在不一致时行为不对: %r / %r" % (prof_m, out_m))
out_m, prof_m = run_mig("ip saddr 10.9.0.0/16 accept\n", '  args: { ips: ["10.9.0.0/16"] }\n',
                        prof_text="PDG_INTERNAL_CIDR=172.22.0.0/16\n")
if prof_m.strip() == "PDG_INTERNAL_CIDR=172.22.0.0/16":
    ok("迁移(真跑): 已有真源时幂等, 一个字节不改")
else:
    bad("迁移覆盖了已有真源: %r" % prof_m)

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

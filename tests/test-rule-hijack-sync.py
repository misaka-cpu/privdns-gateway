#!/usr/bin/env python3
"""issue #1 回归: 在 bot 里把域名指到出口后, mosdns 必须一并劫持该域名。

用户现场: `ip.skk.moe jp` 回了"✅ 已把 ip.skk.moe → jp", 但再查仍是"🏠 国内直连
(mosdns 返回真实 IP)"; 手动把域名加进 geosite_gfw.txt / geosite_geolocation-!cn.txt
再重启 mosdns 才正确分流。

根因: add_rule 指到出口时**只改内核 route.rules, 完全不碰 mosdns**。而 mosdns 的
hijack_set 只装 geosite 的策展分类, 不在集内的域名走 remote_upstream 返真实 IP ——
手机直连, 流量根本不到网关, 内核里那条规则是死的。(指到 direct 反而会写
custom_direct.txt, 所以"设直连"一直是好的 —— 正是这个不对称暴露了问题。)

修复: 增设用户劫持表 custom_hijack.txt 并入 hijack_set; add_rule 指到出口时写入、
指到 direct / 删规则时移除, 并重启 mosdns 让 domain_set 重新加载。
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from txbox import Box  # noqa: E402

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1

# 5.1 起, 规则与 mosdns 劫持表是**同一笔事务**落盘的 —— 所以这里不再打桩 apply_sb, 而是让
# 真事务跑在沙箱文件树上(镜像的 /etc 结构 + 假 systemctl), 断言的仍是"内核规则与劫持表是否
# 同步", 但顺带验证了它们确实一起提交、一起回滚。
BOX = Box()
for k, v in BOX.env.items():
    os.environ[k] = v
BOX.up("mosdns"); BOX.up("mihomo")
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec); spec.loader.exec_module(bot)
bot.MOSDNS_DIRECT = BOX.path("/etc/mosdns/rules/custom_direct.txt")
bot.MOSDNS_HIJACK = BOX.path("/etc/mosdns/rules/custom_hijack.txt")

CFG = {
    "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "shadowsocks", "tag": "jp",
                  "server": "203.0.113.9", "server_port": 1}],
    "route": {"rules": [{"action": "reject", "ip_cidr": ["203.0.113.1/32"]}], "final": "direct"},
    "inbounds": [],
}
state = {"cfg": json.loads(json.dumps(CFG))}
bot.load = lambda: json.loads(json.dumps(state["cfg"]))
bot.exit_tags = lambda c=None: ["jp"]
# model 落盘后回读进 state(事务真的写了文件, 这里只是让后续断言看得到最新 model)
BOX.put("/etc/sing-box/config.json", json.dumps(CFG).encode())


def _sync_state():
    state["cfg"] = json.loads(BOX.read("/etc/sing-box/config.json").decode())


_orig_tx_apply = bot.tx_apply


def _tx_apply(op, **kw):
    r = _orig_tx_apply(op, **kw)
    _sync_state()
    return r


bot.tx_apply = _tx_apply
# mihomo 渲染在本用例里不是被测对象(出口是假的), 用最小合法配置代替渲染结果
bot._render_mihomo_bytes = lambda model, rs_meta=None: (b'{"proxies": [], "rules": []}', {})


def restarts_of(unit):
    try:
        return [l for l in open(BOX.calls) if "restart %s" % unit in l]
    except OSError:
        return []


def hijacked():
    return set(bot._read_hijack())


def main():
    # ── 指到出口 → 必须进劫持表, 且 mosdns 被重启(domain_set 只在启动时加载) ──
    okr, msg = bot.add_rule("ip.skk.moe", "jp")
    assert okr, msg
    assert "ip.skk.moe" in hijacked(), "指到出口后域名未进 mosdns 劫持表 → mosdns 仍返真实 IP"
    ok("指到出口: 域名写入 mosdns 劫持表")
    assert restarts_of("mosdns"), "改了 domain_set 文件却没重启 mosdns"
    ok("指到出口: 重启 mosdns 让 domain_set 重新加载")
    assert any("ip.skk.moe" in r.get("domain_suffix", []) for r in state["cfg"]["route"]["rules"]), "内核规则未写入"
    ok("指到出口: 内核 route 规则同时写入(原有行为不变)")

    # ── 改指到 direct → 必须移出劫持表(否则还会被劫持进代理) ──
    okr, msg = bot.add_rule("ip.skk.moe", "direct")
    assert okr, msg
    assert "ip.skk.moe" not in hijacked(), "改直连后仍留在劫持表 → 直连意图被劫持覆盖"
    ok("改指到 direct: 域名移出劫持表")
    assert "ip.skk.moe" in bot._read_direct()
    ok("改指到 direct: 仍写入 custom_direct(原有行为不变)")

    # ── 删规则 → 劫持表同步清掉 ──
    bot.add_rule("a.example", "jp"); bot.add_rule("b.example", "jp")
    assert {"a.example", "b.example"} <= hijacked()
    bot.del_rule("a.example")
    assert "a.example" not in hijacked(), "del_rule 未清劫持表"
    assert "b.example" in hijacked(), "del_rule 误删了别的域名"
    ok("del_rule: 只清掉被删域名的劫持项")

    bot.add_rule("c.example", "jp")
    okr, msg = bot.del_rules_bulk(["b.example", "c.example"])
    assert okr, msg
    assert not ({"b.example", "c.example"} & hijacked()), "批量删除未清劫持表"
    ok("del_rules_bulk: 批量删除同步清劫持表")

    # ── mosdns 模板: hijack_set 必须包含用户劫持表 ──
    tmpl = (ROOT / "deploy/mosdns/config.yaml").read_text(encoding="utf-8")
    seg = tmpl[tmpl.index("tag: hijack_set"):tmpl.index("tag: force_hijack")]
    assert "custom_hijack.txt" in seg, "mosdns 模板的 hijack_set 未纳入 custom_hijack.txt"
    ok("mosdns 模板: hijack_set 纳入 custom_hijack.txt")

    # ── install.sh 要保证这个文件存在 ──
    # 不按字符串找 "custom_hijack.txt": 装机那段现在是"存在就保留、不存在才建"的循环, 文件名
    # 由变量拼出来。真正要验的是**跑完之后文件在不在**, 所以把那段真跑一遍(路径指到沙盒)。
    inst = (ROOT / "install.sh").read_text(encoding="utf-8")
    i = inst.index("_kept_rules=(); _new_rules=()")
    j = inst.index("(( ${#_new_rules[@]} ))")
    j = inst.index("\n", j)
    blk = inst[i:j]
    import tempfile as _tf
    box = _tf.mkdtemp(prefix="ruleinit.")
    try:
        os.makedirs(os.path.join(box, "etc/mosdns/rules"), exist_ok=True)
        script = ("source %s/lib/preserve.sh\nc_g(){ :; }\n" % ROOT) + \
                 blk.replace("/etc/mosdns/rules", os.path.join(box, "etc/mosdns/rules"))
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        made = sorted(os.listdir(os.path.join(box, "etc/mosdns/rules")))
        assert r.returncode == 0, (r.returncode, r.stderr[:200])
        assert "custom_hijack.txt" in made, made
        ok("install.sh 跑完之后 custom_hijack.txt 确实存在(真跑那段, 不是找字符串)")
        # 已有内容的不许被清掉
        f = os.path.join(box, "etc/mosdns/rules/custom_hijack.txt")
        with open(f, "w", encoding="utf-8") as fh:
            fh.write("kept.example\n")
        subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        assert open(f, encoding="utf-8").read() == "kept.example\n", "重跑把用户域名清空了"
        ok("重跑装机不会清掉已有的劫持域名")
    finally:
        shutil.rmtree(box, ignore_errors=True)

    # ── 老装迁移: 把文件补进已有 config.yaml 的 hijack_set, 并回填已有出口域名 ──
    pdg = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
    assert "migrate_custom_hijack" in pdg, "缺老装迁移 migrate_custom_hijack"
    assert "migrate_custom_hijack" in pdg[pdg.index("run_all_migrations(){"):], "迁移未接入 run_all_migrations"
    ok("pdg.sh: 老装迁移 migrate_custom_hijack 已接入")

    # ── 备份/恢复要带上这个文件 ──
    # BACKUP_FILES/RESTORE_MAP 在 import 时按真实常量构建, 故按路径子串断言(测试改的是模块属性)
    assert any("custom_hijack" in x for x in bot.BACKUP_FILES), "备份未含用户劫持表"
    assert any("custom_hijack" in k for k in bot.RESTORE_MAP), "恢复映射未含用户劫持表"
    ok("备份/恢复: 含用户劫持表")

    # ── 恢复备份必须按本机平台净化 model ──
    # .200 现场: 在 bot 里恢复了一份清理**之前**的旧备份, GMS 入站被带回来, doctor 随即报残留。
    # 恢复不做这一步的话, 得等下一次 root 管理命令触发迁移才清掉。
    GMS = [{"tag": "in-https", "listen_port": 443},
           {"tag": "in-gms-5228", "listen_port": 5228},
           {"tag": "in-gms-5229", "listen_port": 5229},
           {"tag": "in-gms-5230", "listen_port": 5230}]
    _op = bot._platform
    try:
        bot._platform = lambda: "ios"
        c = {"inbounds": list(GMS)}
        assert bot._platform_sanitize_model(c) is True
        assert [i["tag"] for i in c["inbounds"]] == ["in-https"], c
        ok("恢复净化: iOS 上剥掉备份带来的 GMS 入站")
        assert bot._platform_sanitize_model(c) is False
        ok("恢复净化: 幂等(已干净则不改)")
        bot._platform = lambda: "android"
        c2 = {"inbounds": list(GMS)}
        assert bot._platform_sanitize_model(c2) is False
        assert len(c2["inbounds"]) == 4
        ok("恢复净化: Android 不动 GMS 入站(它需要 5228-5230)")
    finally:
        bot._platform = _op
    # 净化必须发生在**进候选**之前(校验与落盘都在那之后, 由事务负责)。
    # 端到端的行为覆盖在 test-restore-transaction.py: 备份里带 GMS 入站的 iOS 恢复, 落盘的
    # model 里不能有 5228-5230。这里守的是顺序本身。
    src = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
    body = src[src.index("def _restore_commit("):]
    assert body.index("_platform_sanitize_model") < body.index('t.stage("model"'), "净化晚于入候选"
    ok("恢复净化: 排在候选 stage 之前(校验/落盘都在其后)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

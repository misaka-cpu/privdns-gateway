#!/usr/bin/env python3
"""TFO(TCP Fast Open)状态回归。

修复的 bug: 原来 TFO 状态靠"所有代理出口都带 tcp_fast_open"推断, 加一个新出口
(parse_link 出来的不带标志)就把 all(...) 打成假 → "开了 TFO 却显示关闭、新出口没享受到"。
改为持久化意图(profile.env: PDG_TFO), apply_sb 每次把意图同步到含新增的所有出口。
"""
import importlib.util as u
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = u.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = u.module_from_spec(spec); spec.loader.exec_module(bot)
import sb2mihomo  # noqa: E402

pass_n = 0
def bad(m):
    print("[FAIL]", m); sys.exit(1)


def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def apply_like(c, mod):
    """模拟 apply_sb 内的 TFO 同步顺序(改动前判定意图 → mod → 同步到所有出口)。"""
    tfo = bot._tfo_intent(c); mod(c); bot._tfo_apply(c, tfo); return c


def cfg():
    return {"outbounds": [
        {"type": "shadowsocks", "tag": "ss1", "server": "1.1.1.1", "server_port": 8388,
         "method": "aes-256-gcm", "password": "x"},
        {"type": "hysteria2", "tag": "hy", "server": "2.2.2.2", "server_port": 443, "password": "y"},
        {"type": "direct", "tag": "jp"}],
        "inbounds": [{"type": "direct", "tag": "in", "listen_port": 443}],
        "route": {"rules": [], "final": "jp"}}


def profile_set(key, val):
    """把 profile.env 写成"含这条 key"的样子。

    生产侧写 profile.env 只有一条路: _profile_text_with 生成候选 → tx_apply 落盘(事务)。
    本用例关心的是 TFO 意图的读判定, 不是事务本身, 所以直接把同一份纯函数的产物写到盘上 ——
    与生产内容逐字节一致, 但不需要拉起整笔事务。
    """
    data = bot._profile_text_with(key, val)
    with open(bot.PROFILE_ENV, "wb") as f:
        f.write(data)


def main():
    tmp = tmpguard.mkdtemp()
    bot.PROFILE_ENV = os.path.join(tmp, "profile.env")

    c = cfg()
    assert bot._tfo_on(c) is False; ok("初始(无 PDG_TFO, 出口无标志)→ 关闭")

    # 开启 → 持久化 + 同步
    profile_set("PDG_TFO", "1"); apply_like(c, lambda cc: None)
    assert bot._tfo_on(c) is True
    assert all(o.get("tcp_fast_open") for o in c["outbounds"] if o["type"] in bot.PROXY_TYPES)
    ok("开启 → _tfo_on True + 所有代理出口带标志")

    # 核心回归: 加新出口不冲掉 TFO 状态, 且新出口继承
    apply_like(c, lambda cc: cc["outbounds"].insert(
        0, {"type": "vmess", "tag": "new", "server": "3.3.3.3", "server_port": 443, "uuid": "u"}))
    assert bot._tfo_on(c) is True, "加新出口后 TFO 不该翻成关闭"
    assert c["outbounds"][0].get("tcp_fast_open") is True, "新出口应继承 TFO"
    ok("加新出口 → 状态保持开启 + 新出口继承(原 bug 已修)")

    # 关闭 → 清标志
    profile_set("PDG_TFO", "0"); apply_like(c, lambda cc: None)
    assert bot._tfo_on(c) is False
    assert not any(o.get("tcp_fast_open") for o in c["outbounds"])
    ok("关闭 → _tfo_on False + 清掉所有标志")

    # 老装回退: 无 PDG_TFO 但出口都带标志 → 推断为开
    os.remove(bot.PROFILE_ENV)
    legacy = cfg()
    for o in legacy["outbounds"]:
        if o["type"] in bot.PROXY_TYPES:
            o["tcp_fast_open"] = True
    assert bot._tfo_intent(legacy) is True; ok("老装(无 PDG_TFO, 出口都带标志)→ 回退推断为开")
    empty = {"outbounds": [{"type": "direct", "tag": "jp"}], "route": {}}
    assert bot._tfo_intent(empty) is False; ok("老装无代理出口 → 关闭")

    # 渲染器: tcp_fast_open → mihomo tfo, 仅 TCP 类
    bot.PROFILE_ENV = os.path.join(tmp, "p2.env"); profile_set("PDG_TFO", "1")
    c2 = cfg(); apply_like(c2, lambda cc: cc["outbounds"].insert(
        0, {"type": "vmess", "tag": "vm", "server": "4.4.4.4", "server_port": 443, "uuid": "u"}))
    mh, _ = sb2mihomo.singbox_to_mihomo(c2)
    assert next(p for p in mh["proxies"] if p["name"] == "vm").get("tfo") is True, "vmess(TCP)应映射 tfo"
    assert next(p for p in mh["proxies"] if p["name"] == "ss1").get("tfo") is True, "ss(TCP)应映射 tfo"
    assert "tfo" not in next(p for p in mh["proxies"] if p["name"] == "hy"), "hysteria2(QUIC)不应有 tfo"
    ok("渲染器: TCP 协议 tcp_fast_open→mihomo tfo, QUIC 排除")

    # profile.env upsert 不破坏其它键
    bot.PROFILE_ENV = os.path.join(tmp, "p3.env")
    profile_set("PDG_LOWMEM", "1"); profile_set("PDG_TFO", "1"); profile_set("PDG_LOWMEM", "0")
    assert bot._profile_get("PDG_LOWMEM") == "0" and bot._profile_get("PDG_TFO") == "1"
    ok("profile.env upsert 保留其它键(PDG_LOWMEM 与 PDG_TFO 共存)")

    # profile.env 的 Python 写入口只剩"纯函数 + 事务": 那个没人调的 _profile_set 已删除,
    # 而 pdg.sh 里的同名 Bash 函数仍是生产代码(PDG_LOWMEM / PDG_PLATFORM), 不能跟着删。
    if hasattr(bot, "_profile_set"):
        bad("Python 侧 _profile_set 还在(它没有生产调用点, 是死代码)")
    else:
        ok("Python 侧 _profile_set 已删除(生产写 profile.env 只走 _profile_text_with + 事务)")
    sh_src = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
    if "_profile_set(){" in sh_src and "_profile_set PDG_PLATFORM" in sh_src:
        ok("pdg.sh 里仍在用的 Bash _profile_set 原样保留")
    else:
        bad("误删了 pdg.sh 的 Bash _profile_set(平台切换/低内存还在用)")

    # ── 跨语言回归: 真跑升级 __migrate 路径的 BASH profile.env 写入(pdg.sh 的 pdg_lowmem_resolve),
    #    证明升级后 PDG_TFO 不丢、_tfo_intent 仍以持久化值为准(无需手动重开) ──
    mem = os.path.join(tmp, "mem512"); open(mem, "w", encoding="utf-8").write("MemTotal: 512000 kB\n")
    pdg_sh = (ROOT / "deploy" / "bot" / "pdg.sh").read_text(encoding="utf-8")
    m = re.search(r"(?sm)^LOWMEM_THRESHOLD_KB=.*?(?=^pdg_fetch_release_tags\(\)\{)", pdg_sh)
    assert m, "抽取 pdg.sh 低内存段失败"
    lowmem_section = m.group(0)

    def bash_migrate_profile(pf):
        """跑升级 __migrate 里真正改写 profile.env 的那一步(pdg_lowmem_resolve, auto)。"""
        script = "c_g(){ :; }; c_y(){ :; }\n" + lowmem_section + "\npdg_lowmem_resolve\n"
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                           env={**os.environ, "PDG_PROFILE": pf, "PDG_MEMINFO": mem, "PDG_LOWMEM": "auto"})
        assert r.returncode == 0, r.stderr
        return open(pf, encoding="utf-8").read()

    no_proxy = {"outbounds": [{"type": "direct", "tag": "jp"}], "route": {}}   # 无代理出口: 只能靠持久化值
    for tfo_val in ("1", "0"):
        pf = os.path.join(tmp, f"mig_{tfo_val}.env")
        open(pf, "w", encoding="utf-8").write(
            f"PDG_LOWMEM=0\nPDG_HIJACK_MODE=gfw\nPDG_PLATFORM=ios\nPDG_TFO={tfo_val}\nCUSTOM=keep\n")
        body = bash_migrate_profile(pf)
        assert f"PDG_TFO={tfo_val}" in body, f"升级 __migrate 后 PDG_TFO 应保留为 {tfo_val}"
        assert "CUSTOM=keep" in body and "PDG_HIJACK_MODE=gfw" in body, "未知键/其它键应保留"
        bot.PROFILE_ENV = pf
        assert bot._tfo_intent(no_proxy) is (tfo_val == "1"), "无代理出口时应以持久化 PDG_TFO 为准"
        ok(f"升级 __migrate 后 PDG_TFO={tfo_val} 保留 + _tfo_intent 以持久化值为准(无需重开)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

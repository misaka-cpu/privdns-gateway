#!/usr/bin/env python3
"""Bot 凭据三态: 没配 / 配一半 / 配齐, 以及它对必需服务集与自检结论的影响。

"Bot Token 可空"与 doctor 的语义原先是打架的: bot.env 两项都空是合法的"这台机器不用
Telegram 管理", pdg-bot 不运行属于正常禁用态 —— 可 doctor 把 pdg-bot 无条件算进必需服务,
于是永远报 fail; update 的校验门只好靠比对 doctor 的 detail 文案("未运行: pdg-bot")去豁免,
那句话改个措辞豁免就失效, 没配 bot 的机器从此升不了级。

现在判据只有一处(checks.bot_credentials), status / doctor / healthcheck / CLI 全取它。
"""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

pass_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m); pass_n += 1


def bad(m):
    print("[FAIL]", m); sys.exit(1)


def write_env(path, token=None, allowed=None):
    lines = []
    if token is not None:
        lines.append("PDG_BOT_TOKEN=%s\n" % token)
    if allowed is not None:
        lines.append("PDG_BOT_ALLOWED=%s\n" % allowed)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)


def main():
    tmp = tempfile.mkdtemp()
    checks.BOT_ENV = os.path.join(tmp, "bot.env")
    checks.PLATFORM_FILE = os.path.join(tmp, "platform")
    with open(checks.PLATFORM_FILE, "w", encoding="utf-8") as f:
        f.write("android\n")
    active = {"pdg-bot": "inactive"}
    checks._run = lambda cmd, t=10: (0, active.get(cmd[-1], "active"), "")

    # ── 1. 两项都空 = 正常禁用态 ──
    write_env(checks.BOT_ENV, token="", allowed="")
    if checks.bot_credentials() != "unset":
        bad("两项都空没判成 unset: %r" % checks.bot_credentials())
    if "pdg-bot" in checks.expected_services():
        bad("未配凭据时 pdg-bot 仍被算进必需服务: %s" % checks.expected_services())
    ok("两项都空: 判为 unset, pdg-bot 不进必需服务集")
    lvl, _, detail = checks.check_services()
    if lvl != "ok":
        bad("未配凭据 + pdg-bot 未运行, 服务检查却不是 ok: %s %s" % (lvl, detail))
    ok("未配凭据 + pdg-bot 未运行 → 服务检查 ok(不是故障)")
    lvl, _, detail = checks.check_bot_credentials()
    if lvl != "info" or "未配置" not in detail:
        bad("未配凭据没给出 info/未配置: %s %s" % (lvl, detail))
    ok("未配凭据 → Bot 凭据检查给 info「未配置」, 不是 fail")

    # bot.env 整个文件不存在 = 同样是 unset
    os.remove(checks.BOT_ENV)
    if checks.bot_credentials() != "unset":
        bad("bot.env 不存在没判成 unset")
    ok("bot.env 不存在 → 同样是 unset(不报错)")

    # ── 2. 两项都配 → pdg-bot 必须在跑 ──
    write_env(checks.BOT_ENV, token="123456:AAaaBBbb", allowed="1")
    if checks.bot_credentials() != "ready":
        bad("两项都配没判成 ready")
    if "pdg-bot" not in checks.expected_services():
        bad("配齐凭据后 pdg-bot 不在必需服务集: %s" % checks.expected_services())
    ok("两项都配: 判为 ready, pdg-bot 进必需服务集")
    lvl, _, detail = checks.check_services()
    if lvl != "fail" or "pdg-bot" not in detail:
        bad("配齐凭据但 pdg-bot 未运行, 却没报 fail: %s %s" % (lvl, detail))
    ok("配齐凭据 + pdg-bot 未运行 → 服务检查 fail 并点名")
    lvl, _, detail = checks.check_bot_credentials()
    if lvl != "fail" or "未运行" not in detail:
        bad("配齐凭据但 pdg-bot 未运行, 凭据检查没报 fail: %s %s" % (lvl, detail))
    ok("配齐凭据 + pdg-bot 未运行 → 凭据检查也 fail")
    active["pdg-bot"] = "active"
    lvl, _, _ = checks.check_bot_credentials()
    if lvl != "ok":
        bad("配齐凭据且 pdg-bot 在跑却不是 ok: %s" % lvl)
    ok("配齐凭据 + pdg-bot 在跑 → ok")
    active["pdg-bot"] = "inactive"

    # ── 3. 只配一项 = 配置错误, 要明确点出来 ──
    for tok, allowed, what in (("123456:AAaa", "", "只有 token"), ("", "1", "只有允许 id")):
        write_env(checks.BOT_ENV, token=tok, allowed=allowed)
        if checks.bot_credentials() != "partial":
            bad("%s 没判成 partial: %r" % (what, checks.bot_credentials()))
        lvl, _, detail = checks.check_bot_credentials()
        if lvl != "fail":
            bad("%s 没报 fail: %s" % (what, lvl))
        if "成对" not in detail and "只配了一项" not in detail:
            bad("%s 的提示不明确: %s" % (what, detail))
        if "pdg-bot" in checks.expected_services():
            bad("%s 时还把 pdg-bot 当必需服务(它起来了也不会响应任何人)" % what)
    ok("只配一项(两种方向): 判为 partial + fail + 明确提示要成对配置")

    # ── 4. 值带引号/空白也要判对(bot.env 是人手编辑的) ──
    with open(checks.BOT_ENV, "w", encoding="utf-8") as f:
        f.write('PDG_BOT_TOKEN="123456:AAaa"\nPDG_BOT_ALLOWED= 1 \n')
    if checks.bot_credentials() != "ready":
        bad("带引号/空白的值没判成 ready")
    with open(checks.BOT_ENV, "w", encoding="utf-8") as f:
        f.write('PDG_BOT_TOKEN=""\nPDG_BOT_ALLOWED=""\n')
    if checks.bot_credentials() != "unset":
        bad('空引号 "" 没判成 unset')
    ok("值带引号/空白/空引号都判得对")

    # ── 5. 各处用的是同一个判据(不许再各写一份) ──
    pdg_sh = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
    if "checks.bot_credentials()" not in pdg_sh:
        bad("pdg.sh 没有走 checks.bot_credentials")
    ok("CLI(pdg.sh)取的是 checks.bot_credentials 这一份判据")
    hc = (ROOT / "deploy/bot/healthcheck.py").read_text(encoding="utf-8")
    if "bot_credentials" not in hc:
        bad("healthcheck 没有走同一判据")
    ok("healthcheck 也走同一判据")

    # ── 6. CLI 的必需服务集: 真跑 pdg.sh 里的函数, 不看源码字符串 ──
    # 平台切换的校验门用的就是这个集合; 它必须与 checks.expected_services() 同语义, 否则
    # 没配 bot 的机器会因为"pdg-bot 未稳定运行"而切不了平台。
    import subprocess
    pdg_sh = str(ROOT / "deploy/bot/pdg.sh")
    shim = tempfile.mkdtemp()
    with open(os.path.join(shim, "checks_shim.py"), "w", encoding="utf-8") as f:
        f.write("import sys\nsys.path.insert(0, %r)\nimport checks\n"
                "checks.BOT_ENV = sys.argv[1]\nprint(checks.bot_credentials())\n"
                % str(ROOT / "deploy" / "bot"))

    def required_svcs(platform, token, allowed):
        envf = os.path.join(shim, "bot.env")
        write_env(envf, token=token, allowed=allowed)
        # pdg.sh 顶层会执行调度, 不能直接 source; 抽出被测函数, 再把凭据/平台判定接到
        # **真实的** checks 上(不重写它们的逻辑)
        body = subprocess.run(
            ["sed", "-n", "/^_pdg_required_svcs(){/,/^}/p", pdg_sh],
            capture_output=True, text=True).stdout
        assert "_pdg_required_svcs(){" in body, "抽取 _pdg_required_svcs 失败"
        script = (
            body
            + '_pdg_core_svc(){ echo mihomo; }\n'
            + '_pdg_platform(){ echo %s; }\n' % platform
            + '_pdg_bot_cred(){ python3 %r %r; }\n' % (os.path.join(shim, "checks_shim.py"), envf)
            + '_pdg_required_svcs\n'
        )
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        return r.stdout.split()

    got = required_svcs("android", "", "")
    if "pdg-bot" in got:
        bad("未配凭据时 CLI 仍把 pdg-bot 列为必需服务: %s" % got)
    # 6.1B: pdg-probe81 是公共件, 两平台都在必需集里(与凭据无关)。
    if got != ["mosdns", "mihomo", "pdg-probe81"]:
        bad("未配凭据的 Android 必需服务集不对: %s" % got)
    ok("CLI 必需服务集(unset/Android): mosdns + mihomo + pdg-probe81, 不含 pdg-bot")

    got = required_svcs("ios", "", "")
    if "pdg-bot" in got or "pdg-probe81" not in got:
        bad("未配凭据的 iOS 必需服务集不对: %s" % got)
    ok("CLI 必需服务集(unset/iOS): 含 pdg-probe81, 仍不含 pdg-bot")

    got = required_svcs("ios", "123456:AAaa", "1")
    if "pdg-bot" not in got or "pdg-probe81" not in got:
        bad("凭据 ready 时必需服务集缺项: %s" % got)
    ok("CLI 必需服务集(ready/iOS): mosdns + mihomo + pdg-bot + pdg-probe81")

    got = required_svcs("android", "123456:AAaa", "")     # partial
    if "pdg-bot" in got:
        bad("凭据只配一半时不该把 pdg-bot 当必需服务(它起来了也不响应): %s" % got)
    ok("CLI 必需服务集(partial): 不含 pdg-bot(由平台切换单独报配置错误)")

    # 与 checks.expected_services() 逐一对齐(两边算出来的必须是同一个集合)
    for plat in ("android", "ios"):
        for tok, al in (("", ""), ("123456:AAaa", "1")):
            checks.PLATFORM_FILE = os.path.join(shim, "platform")
            with open(checks.PLATFORM_FILE, "w", encoding="utf-8") as f:
                f.write(plat)
            write_env(checks.BOT_ENV, token=tok, allowed=al)
            if sorted(checks.expected_services()) != sorted(required_svcs(plat, tok, al)):
                bad("CLI 与 checks 的必需服务集不一致: %s vs %s"
                    % (checks.expected_services(), required_svcs(plat, tok, al)))
    ok("CLI 与 checks.expected_services() 在四种组合下逐一一致")

    print("\n通过 %d 项断言" % pass_n)


if __name__ == "__main__":
    main()

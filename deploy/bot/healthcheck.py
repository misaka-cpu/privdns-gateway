#!/usr/bin/env python3
"""PrivDNS Gateway 健康自检 —— 服务挂 / DNS 不应答 / 证书快到期时 Telegram 私信通知。
仅在「状态变化」时发(出问题发一次、恢复发一次), 不刷屏。由 pdg-health.timer 定时触发。
检查逻辑复用 checks.py(与 pdg doctor 同源, 这里只跑轻量子集 checks.ALERT)。
token / 允许 id 读自 /etc/privdns-gateway/bot.env(回退到环境变量 / 旧 unit), 不重复保存。"""
import os, re, json, sys

ENVF = "/etc/privdns-gateway/bot.env"
SVC = "/etc/systemd/system/pdg-bot.service"   # 仅作旧装兼容回退
STATE = "/opt/pdg-bot/health-state.json"

def _envfile(k):
    try:
        for line in open(ENVF):
            line = line.strip()
            if line.startswith(k + "="):
                return line[len(k) + 1:].strip().strip('"').strip("'")
    except Exception:  # noqa: BLE001
        pass
    return ""

def _svc(k):
    try:
        m = re.search(rf"^Environment={k}=(.*)$", open(SVC).read(), re.M)
        return m.group(1).strip() if m else ""
    except Exception:  # noqa: BLE001
        return ""

def _get(k):  # 环境变量 → bot.env → 旧 unit
    return os.environ.get(k) or _envfile(k) or _svc(k)

os.environ.setdefault("PDG_BOT_TOKEN", _get("PDG_BOT_TOKEN"))
os.environ.setdefault("PDG_CERT", _get("PDG_CERT") or "/etc/mosdns/certs/fullchain.pem")
sys.path.insert(0, "/opt/pdg-bot")
import bot      # noqa: E402  (复用 bot.post 发消息)
import checks   # noqa: E402  (复用检查逻辑)

ALLOWED = [int(x) for x in re.findall(r"\d+", _get("PDG_BOT_ALLOWED"))]

def _problems():
    out = []
    for level, label, detail in checks.run(checks.ALERT):
        if level == "fail":
            out.append(f"❌ {label}: {detail}")
        elif level == "warn":
            out.append(f"⚠️ {label}: {detail}")
    return out

def _notify(text):
    """发 HTML 给每个允许的用户; Telegram 以 400 拒收时退回纯文本再发一次。

    这是后台任务(健康自检、`pdg kernel` / `pdg platform` / `pdg lan renew` 的 --notify)唯一的
    Telegram 出口, 正文里常夹着别处来的文字 —— 自检项的说明、CLI 的提示。像
    `sudo pdg lan cert <dns插件名>` 里的 <…>, 在 Telegram 看来是不认识的标签, 整条 400 拒收;
    调用方又把输出丢进 /dev/null, 于是一条都收不到, 也没人知道。bot 自己的 send / edit 早就有
    这一步回退, 这里补上同一条。
    只在明确的 400 时回退: post 返回 {}(超时、断线)时不知道发没发出去, 再发一次可能让同一条
    告警收两遍; 429 之类重发也不会好。"""
    for uid in ALLOWED:
        p = {"chat_id": uid, "text": text, "parse_mode": "HTML", "disable_web_page_preview": True}
        r = bot.post("sendMessage", p) or {}
        if not r.get("ok") and r.get("error_code") == 400:
            p.pop("parse_mode", None)
            bot.post("sendMessage", p)

def main():
    # 凭据判据与 status / doctor / CLI / update 校验门同一份(checks.bot_credentials):
    # 没配齐就没人可通知, 直接安静退出 —— 这不是故障。
    if checks.bot_credentials() != "ready" or not ALLOWED:
        return
    problems = _problems()
    try:
        prev = json.load(open(STATE)).get("problems", [])
    except Exception:  # noqa: BLE001
        prev = []
    if problems and problems != prev:
        _notify("🚨 <b>PrivDNS Gateway 异常</b>\n" + "\n".join(problems) + "\n\n详情: <code>sudo pdg doctor</code>")
    elif not problems and prev:
        _notify("✅ <b>PrivDNS Gateway 已恢复正常</b>")
    try:
        json.dump({"problems": problems}, open(STATE, "w"))
    except Exception:  # noqa: BLE001
        pass

if __name__ == "__main__":
    main()

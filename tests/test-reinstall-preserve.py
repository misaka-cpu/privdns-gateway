#!/usr/bin/env python3
"""`PDG_FORCE_REINSTALL=1` 不得清空用户数据。

产品语义: 强制重装 = **重新部署程序与系统组件**, 不是"恢复出厂设置"。早期实现把两者混为
一谈 —— 重装会 `: >` 清空四个规则集、拿模板覆盖 /etc/sing-box/config.json(出口/分流/默认
出口的唯一数据源)、并用空 token 重写 bot.env。.200 实机上的实际后果: Telegram token 丢失、
10 个出口连同 route.final 回到模板默认、WLOC 的接管域名被清空 —— 全程没有一句提示。

这里测判据本体(lib/preserve.sh)与 install.sh 里那几处写入的**真实行为**: 在隔离根上跑真
函数, 不看源码字样。凭据只比对哈希, 从不打印内容。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = [0]
FAIL = [0]
SENTINEL = "USERDATA-8f2c41d7b9-DO-NOT-LOSE"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def sh(script, **env):
    return subprocess.run(["bash", "-c", "source %s/lib/preserve.sh\n%s" % (ROOT, script)],
                          capture_output=True, text=True, env=dict(os.environ, **env))


def h(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:16]


# ── 1. 用户数据清单是单一事实源 ────────────────────────────────────────────
print("── 1. 用户数据清单 ──")
items = [l for l in sh("pdg_user_data").stdout.splitlines() if l.strip()]
must = ["etc/privdns-gateway/bot.env", "etc/sing-box/config.json",
        "etc/mosdns/rules/custom_hijack.txt", "etc/mosdns/rules/mitm_hijack.txt",
        "etc/mosdns/rules/unlock.txt", "etc/mosdns/rules/custom_direct.txt",
        "etc/privdns-gateway/profile.env", "etc/privdns-gateway/platform",
        "etc/privdns-gateway/backend", "opt/pdg-bot/rulesets.json", "opt/pdg-bot/dot-domain"]
miss = [m for m in must if m not in items]
if not miss:
    ok("清单覆盖 bot 凭据 / 数据模型 / 四个规则集 / 平台与后端标记 / 规则集元数据(%d 项)" % len(items))
else:
    bad("清单漏了: %s" % ", ".join(miss))

# ── 2. 保留判据 ────────────────────────────────────────────────────────────
print()
print("── 2. 存在就保留, 不存在才初始化 ──")
work = tempfile.mkdtemp(prefix="pdgpreserve.")
try:
    f = os.path.join(work, "custom_hijack.txt")
    with open(f, "w", encoding="utf-8") as fh:
        fh.write("example.test\n")
    before = h(f)
    r = sh('pdg_keep_or_init "%s" && echo KEPT || echo NEW' % f)
    if "KEPT" in r.stdout and h(f) == before:
        ok("已有规则集 → 保留且逐字节不变")
    else:
        bad("已有规则集被动了: %s" % r.stdout.strip())
    f2 = os.path.join(work, "unlock.txt")
    r = sh('pdg_keep_or_init "%s" && echo KEPT || echo NEW' % f2)
    if "NEW" in r.stdout and os.path.exists(f2):
        ok("不存在的规则集 → 按全新安装建出来(空文件=休眠, 是合法状态)")
    else:
        bad("新建路径不对: %s" % r.stdout.strip())

    # 数据模型: 有效 / 损坏 / 缺失 三态分明
    m = os.path.join(work, "config.json")
    with open(m, "w", encoding="utf-8") as fh:
        json.dump({"outbounds": [{"tag": "jp"}, {"tag": "hk"}], "route": {"final": "hk"}}, fh)
    if sh('pdg_model_ok "%s"' % m).returncode == 0:
        ok("有出口的数据模型 → 判为有效(重装必须保留)")
    else:
        bad("有效模型被判成无效")
    with open(m + ".broken", "w", encoding="utf-8") as fh:
        fh.write('{"outbounds": [')
    if sh('pdg_model_ok "%s.broken"' % m).returncode != 0:
        ok("截断/损坏的模型 → 判为无效(调用方据此 fail-closed, 而不是拿模板盖掉)")
    else:
        bad("坏模型被判成有效")
    with open(m + ".empty", "w", encoding="utf-8") as fh:
        json.dump({"outbounds": []}, fh)
    if sh('pdg_model_ok "%s.empty"' % m).returncode != 0:
        ok("出口为空的模型 → 判为无效")
    else:
        bad("空出口模型被当成有效")

    # bot.env: 只判"有没有 token", 绝不打印
    b = os.path.join(work, "bot.env")
    with open(b, "w", encoding="utf-8") as fh:
        fh.write("PDG_BOT_TOKEN=123456:%s\nPDG_BOT_ALLOWED=1\n" % SENTINEL)
    r = sh('pdg_bot_env_ok "%s" && echo HAS || echo NO' % b)
    if "HAS" in r.stdout and SENTINEL not in r.stdout:
        ok("bot.env 有 token → 判为有效, 且判定过程不回显凭据")
    else:
        bad("token 判定不对或回显了内容")
    with open(b + ".empty", "w", encoding="utf-8") as fh:
        fh.write("PDG_BOT_TOKEN=\nPDG_BOT_ALLOWED=\n")
    if sh('pdg_bot_env_ok "%s.empty"' % b).returncode != 0:
        ok("空 token 的 bot.env → 判为无效(可以被新值写入)")
    else:
        bad("空 token 被当成有效")

    # ── 3. before-image 与回滚 ────────────────────────────────────────────
    print()
    print("── 3. before-image 与失败回滚 ──")
    img = os.path.join(work, "img")
    os.makedirs(img, exist_ok=True)
    tgt = os.path.join(work, "model.json")
    shutil.copy2(m, tgt)
    os.chmod(tgt, 0o600)
    orig, orig_mode = h(tgt), oct(os.stat(tgt).st_mode & 0o777)
    if sh('pdg_before_image "%s" "%s"' % (tgt, img)).returncode == 0:
        ok("before-image 建立成功")
    else:
        bad("before-image 失败")
    with open(tgt, "w", encoding="utf-8") as fh:      # 模拟重装把它覆盖了
        fh.write("{}")
    os.chmod(tgt, 0o644)
    if sh('pdg_restore_image "%s" "%s"' % (tgt, img)).returncode == 0 \
            and h(tgt) == orig and oct(os.stat(tgt).st_mode & 0o777) == orig_mode:
        ok("回滚后内容与权限都回到操作前(不只是内容对)")
    else:
        bad("回滚不完整: hash=%s mode=%s" % (h(tgt), oct(os.stat(tgt).st_mode & 0o777)))
    absent = os.path.join(work, "never-existed.json")
    sh('pdg_before_image "%s" "%s"' % (absent, img))
    with open(absent, "w", encoding="utf-8") as fh:
        fh.write("新建的")
    sh('pdg_restore_image "%s" "%s"' % (absent, img))
    if not os.path.exists(absent):
        ok("原本不存在的文件 → 回滚时被删掉(不留下重装造出来的半成品)")
    else:
        bad("回滚没删掉新建的文件")
finally:
    shutil.rmtree(work, ignore_errors=True)

# ── 4. install.sh 真的走了保留路径 ────────────────────────────────────────
print()
print("── 4. install.sh 的写入行为 ──")
inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
if ": > /etc/mosdns/rules/custom_hijack.txt" not in inst:
    ok("不再无条件清空规则集")
else:
    bad("仍在 `: >` 清空规则集")
if "pdg_keep_or_init" in inst:
    ok("规则集走「存在就保留」的判据")
else:
    bad("规则集没走保留判据")
def between(text, a, b, what):
    """取两个锚点之间的段落。锚点没了就是**回归本身**, 报明确原因而不是抛 ValueError ——
    崩在 index() 上虽然也是非 0, 但它指向的位置是错的。"""
    i = text.find(a)
    j = text.find(b, i + 1) if i >= 0 else -1     # 结束锚点必须在起点**之后**找:
    # 同一个字符串在文件更早处也可能出现(nft -f /etc/nftables.conf 在回滚路径里就有一处),
    # 从头找会得到 j < i, 于是这段被判成"锚点丢了"——一个纯粹由取法造成的假红。
    if i < 0 or j < 0 or j <= i:
        bad("install.sh 里找不到「%s」那段(锚点 %r/%r)—— 保留逻辑可能被改掉了" % (what, a[:12], b[:12]))
        return ""
    return text[i:j]


seg = between(inst, "# 数据模型(出口 / 分流", "# iOS: 模板含 GMS", "数据模型保留")
if seg and "pdg_model_ok" in seg and "die " in seg and "render " in seg:
    ok("数据模型三态分明: 有效→保留 / 损坏→fail-closed / 缺失→渲染")
elif seg:
    bad("数据模型的分支不全: %s" % seg[:100])
seg2 = between(inst, "# 已有 token 就保留", "chmod 600 /etc/privdns-gateway/bot.env", "bot.env 保留")
if seg2 and "pdg_bot_env_ok" in seg2 and "BOT_TOKEN" in seg2:
    ok("bot.env: 没显式给新 token 且已有有效 token → 保留")
elif seg2:
    bad("bot.env 仍会被无条件覆盖")
# 平台标记不因重装被改: 它由 PDG_PLATFORM 决定, 而重装时该值应来自现有安装
if "PDG_PLATFORM" in inst and "/etc/privdns-gateway/platform" in inst:
    ok("平台标记有单一来源(重装时按传入/现有值写, 不随机翻转)")
else:
    bad("平台标记来源不清")

# ── 5. 重装后派生配置要与 WLOC 状态一致 ────────────────────────────────────
print()
print("── 5. 重装后的 mihomo 派生配置 ──")
# 接管域名的真源是 mitm_hijack.txt(重装保留), 但 MITM-OUT 出站与 gs-loc 路由是**渲染时**
# 加进 mihomo 配置的。渲染不传域名, 重装完 doctor 立刻报 "mihomo 缺 MITM-OUT" —— 域名还在,
# WLOC 却已经不工作了(.200 实机重装后就是这样)。
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import sb2mihomo  # noqa: E402

MODEL = {"log": {}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}],
         "route": {"rules": [], "final": "direct"}}
cfg_off, _ = sb2mihomo.singbox_to_mihomo(MODEL, redir_port=7893, mitm_domains=None)
cfg_on, _ = sb2mihomo.singbox_to_mihomo(MODEL, redir_port=7893,
                                        mitm_domains=["gs-loc.apple.com"])
if not any(p.get("name") == "MITM-OUT" for p in cfg_off.get("proxies", [])):
    ok("没有接管域名(WLOC 休眠)→ 派生配置里不该有 MITM-OUT")
else:
    bad("休眠状态也渲染了 MITM-OUT")
if any(p.get("name") == "MITM-OUT" for p in cfg_on.get("proxies", [])) and \
        any("MITM-OUT" in r and "gs-loc" in r for r in cfg_on.get("rules", [])):
    ok("有接管域名 → 派生配置带 MITM-OUT 出站与 gs-loc 路由")
else:
    bad("传了域名却没渲染出 MITM-OUT/路由")
seg3 = between(inst, "# WLOC/MITM 的接管域名要一起带上", "render \"$REPO_DIR/deploy/bot/pdg-bot.service\"",
               "重装时的 mihomo 渲染")
if seg3 and "mitm_hijack.txt" in seg3 and "mitm_domains=" in seg3:
    ok("装机/重装的渲染读 mitm_hijack.txt 并把域名传进去(重装不再让 WLOC 静默失效)")
elif seg3:
    bad("渲染仍未带上接管域名")

# ── 6. 重装不得把救援放行渲染没了 ──────────────────────────────────────────
print()
print("── 6. 重装后的防火墙 ──")
# 模板里没有那条带标记的救援放行(它是 enable 时注入的)。重装重渲染防火墙后直接应用, 等于
# socket 还在监听、防火墙已经不放行 —— 而下一次 update 的迁移会去修、修不成就把整次更新
# 回滚(.200 实机上完整发生过一遍)。
seg4 = between(inst, "# 救援平面已启用的机器", "nft -f /etc/nftables.conf", "重装时补回救援放行")
if seg4 and "rescue_nft.py" in seg4 and "PDG_RESCUE_ENABLED" in seg4:
    ok("启用中的机器: 应用防火墙前先把救援放行补回候选")
elif seg4:
    bad("重装仍会把救援放行渲染没")
if seg4 and "nft -c -f" in seg4:
    ok("补回后的候选先过 nft -c 再落盘(不拿没校验的配置去应用)")
elif seg4:
    bad("补回路径没有校验门")
if seg4 and ("pdg rescue enable" in seg4 or "复查" in seg4):
    ok("注入失败时明确提示去复查, 不假装成功")
elif seg4:
    bad("失败路径静默")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

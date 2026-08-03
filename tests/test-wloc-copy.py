#!/usr/bin/env python3
"""WLOC「切换地点」文案一致性回归。

README 与 TG Bot 必须给出**同一套**手机端操作(顺序、措辞、路径都一致), 且:
  · 标题各自用本媒介的粗体(README = Markdown **…**, Bot = parse_mode 兼容 <b>…</b>);
  · 每一步各自分行(README 用有序列表项, Bot 用 \\n 分隔);
  · 只出现在 iOS/WLOC 语境, 不进 Android 菜单/安装流程;
  · **边界措辞不许被吹成"位置已改变"** —— 网关只能保证下一次 WLOC 请求用新坐标, 既清不掉
    iOS 的 locationd 缓存, 也强制不了手机立刻发请求。这条是用户预期的关键, 一旦文案吹过头,
    用户会把"iOS 缓存没刷新"当成网关坏了。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
readme = (ROOT / "README.md").read_text(encoding="utf-8")
bot = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


STEPS = [
    "控制中心把 Wi-Fi 点灰（不是在设置里关 Wi-Fi）",
    "在 Bot「📍 地点 / 切换」里点目标地点",
    "等 Bot 显示「网关目标地点已切换，网关服务无需重启」",
    "设置 → 隐私与安全性 → 定位服务：关闭，等 2 秒后重新开启",
    "打开目标 App",
    "iOS 26 如果一直没有发起新的 WLOC 请求，可能仍需重启手机",
]
FALLBACK = "长期无法定位时：设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私 → 重启手机"
TITLE = "切换地点的推荐顺序（全程用内网卡）："

# ── 标题: 各自媒介的粗体 ──
assert f"**{TITLE}**" in readme, "README 标题需为 Markdown 粗体"
ok("README: 标题 Markdown 粗体")
assert f"<b>{TITLE}</b>" in bot, "Bot 标题需为 parse_mode 兼容粗体"
ok("Bot: 标题 <b> 粗体(parse_mode 兼容)")

# ── 每一步: 两边逐条同措辞, 且各自分行 ──
CIRCLED = "①②③④⑤⑥⑦⑧⑨"
for i, it in enumerate(STEPS, 1):
    assert re.search(r"^%d\. " % i + re.escape(it) + r"$", readme, re.M), \
        f"README 缺第{i}步或未独占一行: {it}"
    assert f"{CIRCLED[i - 1]} {it}\\n" in bot, f"Bot 缺第{i}步或未分行: {it}"
ok("README: 每步独占一个有序列表项(渲染分行)")
ok("Bot: 每步以 ①②③… 开头并各自 \\n 分行")

# ── 顺序一致 ──
r_pos = [readme.index(it) for it in STEPS]
b_pos = [bot.index(it) for it in STEPS]
assert r_pos == sorted(r_pos), "README 步骤顺序与约定不符"
assert b_pos == sorted(b_pos), "Bot 步骤顺序与约定不符"
ok("README / Bot 步骤顺序一致(点灰 Wi-Fi → 选地点 → 等切换提示 → 关开定位 → 开 App → iOS 26 兜底重启)")

# ── 兜底还原步骤两边都要有 ──
assert FALLBACK in readme and FALLBACK in bot, "长期无法定位的兜底步骤缺失/被改写"
ok("兜底步骤(还原位置与隐私 → 重启手机)两边一致")

# ── 关键措辞不得被改写 ──
for kw in ("全程用内网卡", "控制中心把 Wi-Fi 点灰", "还原位置与隐私", "隐私与安全性 → 定位服务"):
    assert kw in readme and kw in bot, f"关键措辞被改写/缺失: {kw}"
ok("关键措辞保留(全程用内网卡 / 控制中心把 Wi-Fi 点灰 / 还原位置与隐私 / 定位服务路径)")

# ── 边界: 不许把"网关改写了响应"说成"手机位置已变" ──
for bad_kw in ("手机位置已成功", "位置已成功变化", "立即生效到手机", "手机定位已更新"):
    assert bad_kw not in readme and bad_kw not in bot, f"文案把网关能力吹过头了: {bad_kw}"
ok("没有把网关改写说成手机位置已变化")
assert "下一次" in readme and "下一次" in bot, "两边都要点明网关只保证『下一次』请求用新坐标"
ok("两边都写明: 网关只保证下一次 WLOC 请求使用新坐标")
assert "iOS 26" in readme and "iOS 26" in bot, "iOS 26 可能仍需重启的提示缺失"
ok("两边都保留 iOS 26 可能仍需重启的提示")

# ── 平台隔离: 这套文案只在 iOS/WLOC 语境, 不进 Android 菜单/安装 ──
for p in ("install.sh", "deploy/bot/pdg.sh"):
    txt = (ROOT / p).read_text(encoding="utf-8")
    for it in STEPS:
        assert it not in txt, f"{p} 不应包含 WLOC 手机端文案: {it}"
ok("install.sh / pdg.sh 不含该文案(不进 Android 菜单与安装流程)")

# Bot 里该文案只出现在 WLOC 菜单一处
assert bot.count(STEPS[0]) == 1, "Bot 中 WLOC 手机端文案出现多处(应只在 WLOC 菜单)"
ok("Bot 中该文案仅 WLOC 菜单一处")

print(f"\n通过 {pass_n} 项断言")

#!/usr/bin/env python3
"""iOS 描述文件 CA 归属回归(Item 5)。

  A. 普通描述文件默认**不含 CA** —— 即便 WLOC 已启用(_mitm_enabled_domains 非空)也不偷偷带上,
     否则重生成普通版会顶掉用户已信任的 CA 描述文件。
  B. WLOC-CA 描述文件(with_ca=True)含 com.apple.security.root(根 CA)payload。
  C. CA 生成/读取失败(_mitm_ca_der 返回空)→ with_ca 时**抛错**, 绝不静默产出无 CA 的『成功』件。
"""
import importlib.util
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)

bot.IOS_TMPL = str(ROOT / "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
bot._dot_host = lambda: "dot.example.com"
bot._server_ip = lambda: "203.0.113.10"

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


def has_ca(pl):
    return any(x.get("PayloadType") == "com.apple.security.root" for x in pl["PayloadContent"])


# ── A. 普通描述文件不含 CA —— 即便 WLOC 开着(域名非空 + CA 可读) ──
bot._mitm_enabled_domains = lambda: ["gs-loc.apple.com", "gs-loc-cn.apple.com"]  # WLOC 已开
bot._mitm_ca_der = lambda: b"\x30\x03\x02\x01\x00"                               # CA 可读
p = plistlib.loads(bot._ios_profile())
assert not has_ca(p), "普通描述文件不应含 CA(即使 WLOC 开着)"
ok("普通描述文件默认不含 CA(WLOC 开着也不偷偷带)")
p_ssid = plistlib.loads(bot._ios_profile(["Home"]))
assert not has_ca(p_ssid), "带 SSID 的普通描述文件也不应含 CA"
ok("带 SSID 的普通描述文件同样不含 CA")

# ── B. WLOC-CA 描述文件含根 CA payload ──
der = b"\x30\x03\x02\x01\x2a"
bot._mitm_ca_der = lambda: der
pc = plistlib.loads(bot._ios_profile(with_ca=True))
ca = [x for x in pc["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
assert len(ca) == 1, "WLOC-CA 描述文件应含且仅含一个 com.apple.security.root"
assert ca[0]["PayloadContent"] == der, "CA payload 内容应为根 CA 的 DER 字节"
ok("WLOC-CA 描述文件含 com.apple.security.root(根 CA payload)")
# WLOC-CA + SSID 也能带 CA
pcs = plistlib.loads(bot._ios_profile(["Cafe"], with_ca=True))
assert has_ca(pcs) and pcs["PayloadContent"][0]["OnDemandRules"][0].get("SSIDMatch") == ["Cafe"]
ok("WLOC-CA 描述文件可同时带 SSID 直连规则 + CA")

# ── C. CA 生成失败 → with_ca 抛错(不产出无 CA 的假成功件) ──
bot._mitm_ca_der = lambda: b""
raised = False
try:
    bot._ios_profile(with_ca=True)
except RuntimeError as e:
    raised = True
    assert "CA" in str(e), f"错误信息应点明 CA: {e}"
assert raised, "CA 生成失败时 with_ca 必须抛错, 而不是产出无 CA 的『成功』描述文件"
ok("CA 生成失败 → with_ca 抛清晰错误(不静默产出无 CA 件)")
# 但普通版(with_ca=False)在 CA 不可读时仍正常产出(不受影响)
assert not has_ca(plistlib.loads(bot._ios_profile())), "CA 不可读不影响普通版正常产出"
ok("CA 不可读时普通版仍正常产出(不含 CA)")

print(f"\n通过 {pass_n} 项断言")

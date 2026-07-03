#!/usr/bin/env python3
"""Static + dynamic regression for doctor firewall port coverage."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
checks_src = (ROOT / "deploy/bot/checks.py").read_text(encoding="utf-8")

assert '{"53", "80", "81", "443", "853", "5228", "5229", "5230", "8445"}' in checks_src, (
    "doctor firewall leak detection must include TG SOCKS5 8445 and GMS 5228-5230"
)
assert "53/80/81/443/853/5228-5230/8445" in checks_src, (
    "doctor firewall OK text should mention 8445 and 5228-5230"
)

# 动态: 端口区间写法(如 5228-5230)对全网开放也要被识别为泄露; 限内网来源则不报。
spec = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
checks = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(checks)

checks._run = lambda cmd: (0, "chain input {\n tcp dport { 22 } accept\n"
                              " tcp dport { 5228-5230 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "fail" and "5228" in msg and "5230" in msg, (st, msg)

checks._run = lambda cmd: (0, "chain input {\n tcp dport { 22 } accept\n"
                              " ip saddr 172.22.0.0/16 tcp dport { 53, 80-81, 443, 853, 5228-5230, 8445 } accept\n}", "")
st, _, msg = checks.check_nft()
assert st == "ok", (st, msg)

print("doctor-firewall regression OK")

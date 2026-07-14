#!/usr/bin/env python3
"""Static regressions for small CLI/report/bot polish fixes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
bot = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
pdg = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
report = (ROOT / "deploy/bot/report.py").read_text(encoding="utf-8")
install_doc = (ROOT / "docs/INSTALL.md").read_text(encoding="utf-8")
prod_doc = (ROOT / "docs/production-notes.md").read_text(encoding="utf-8")


def block_after(text: str, marker: str, window: int = 900) -> str:
    start = text.find(marker)
    assert start >= 0, f"missing marker: {marker}"
    return text[start:start + window]


send_plain = block_after(bot, "def send_plain")
assert "p.pop(\"parse_mode\", None)" in send_plain, (
    "send_plain should retry without HTML parse_mode when Telegram rejects unescaped user/error text"
)
assert send_plain.count("post(\"sendMessage\", p)") >= 2, (
    "send_plain should attempt HTML first, then plain text fallback"
)

pdg_pos = report.find('"inet", "pdg", "input"')
filter_pos = report.find('"inet", "filter", "input"')
assert pdg_pos >= 0, "pdg report should read the current firewall chain inet pdg/input"
assert filter_pos >= 0, "pdg report should keep fallback compatibility with old inet filter/input installs"
assert pdg_pos < filter_pos, "pdg report should prefer inet pdg before falling back to inet filter"

assert 'printf "选择: "' in pdg, "menu prompt should be printed explicitly so it survives after update output"
assert "read -r c" in pdg, "menu input should use read -r after printing the prompt"
assert 'read -rp "选择: " c' not in pdg, "read -p prompt can disappear in some terminals"
assert '3) cmd_update && exec /usr/local/bin/pdg menu;;' in pdg, (
    "after a successful menu update, pdg should re-exec the freshly installed script"
)

assert '9090(local clash_api)' in pdg, "status should retain the default local clash_api label"
assert '9090(panel临时内网)' in pdg and 'external_controller' in pdg, (
    "status should label a managed 0.0.0.0:9090 controller as a temporary LAN panel"
)

panel = block_after(bot, 'if data == "panel":', window=1250)
assert "临时观测/控制面板" in panel and "断开连接" in panel, (
    "panel copy should describe native Zashboard control capability accurately"
)
assert "只能观测" not in panel, "panel copy must not claim read-only behavior"
assert 'send_plain(chat, "✅ 观测面板已开启' not in panel, (
    "panel open flow must not leave a success message behind when sending the secret link fails"
)
assert "临时观测/控制面板" in install_doc and "临时观测/控制面板" in prod_doc, (
    "install and production docs should document the temporary panel boundary"
)

rollback = block_after(pdg, "cmd_rollback()", window=1600)
assert '[[ "$idx" =~ ^[0-9]+$ ]]' in rollback, "rollback index should reject non-numeric input"
assert 'idx >= ${#snaps[@]}' in rollback, "rollback index should reject out-of-range input"

# P2-1: cmd_update 装好新脚本后, 必须用"新脚本"跑迁移(否则 v1.2.x 新迁移要等下次命令才生效)
cmd_update = block_after(pdg, "install -m755 \"$REPO_DIR\"/deploy/bot/pdg.sh", window=400)
assert "bash /usr/local/bin/pdg __migrate" in cmd_update, (
    "cmd_update must re-invoke the freshly-installed script for migrations, not call old in-memory funcs"
)
assert "__migrate)" in pdg and "run_all_migrations" in pdg, "hidden __migrate subcommand + run_all_migrations must exist"
assert "status|st|doctor|dr|log|logs|traffic|tr|report|uninstall|rm|__migrate)" in pdg, (
    "__migrate must be excluded from the pre-dispatch auto-migrate block to avoid double-running"
)

# P2-2: snapshot 包含 journald drop-in(正确+历史错路径), rollback 重启 journald
snapshot = block_after(pdg, "cmd_snapshot()", window=1800)
assert "etc/systemd/journald.conf.d/50-pdg.conf" in snapshot, "snapshot must include journald drop-in (correct path)"
assert "etc/systemd/system/journald.conf.d/50-pdg.conf" in snapshot, "snapshot should also capture legacy wrong-path file"
assert "systemctl restart systemd-journald" in rollback, (
    "rollback must restart journald (CanReload=no) so restored cap takes effect"
)
# snapshot 只打包存在的路径(历史错路径可能已被迁移删掉)+ 检查 tar 返回值(否则 tar 返 2 仍报成功)
assert '[[ -e "/$p" ]]' in snapshot, "snapshot must only tar existing paths (legacy path may be deleted by migration)"
assert "! tar czf" in snapshot, "snapshot must check tar return code, not report success on failure"

# 面板临时态净化: snapshot 受管开启态用净化 config 入档; rollback 就地净化; 有归属判定辅助函数
assert "_sb_panel_managed_on" in pdg and "_sb_sanitize_panel" in pdg, (
    "pdg.sh must provide panel-ownership + sanitize helpers for snapshot/rollback"
)
assert "_sb_panel_managed_on /etc/sing-box/config.json" in snapshot, (
    "snapshot must sanitize a managed-on panel config so the secret never enters the archive"
)
assert "_sb_sanitize_panel /etc/sing-box/config.json" in rollback, (
    "rollback must sanitize a restored managed-on panel config (temporary state not persisted)"
)

# P2-3: mosdns cache 与 journald 修复相互独立(各自成函数, migrate_lowmem 里 mosdns 失败不 return 全函数)
assert "_migrate_mosdns_cache" in pdg and "_migrate_journald_cap" in pdg, (
    "mosdns cache and journald cap must be separate functions so one's failure doesn't skip the other"
)
mig_low = block_after(pdg, "migrate_lowmem(){", window=500)
assert "_migrate_mosdns_cache" in mig_low and "|| true" in mig_low and "_migrate_journald_cap" in mig_low, (
    "migrate_lowmem must call mosdns cache with || true then always run journald cap"
)

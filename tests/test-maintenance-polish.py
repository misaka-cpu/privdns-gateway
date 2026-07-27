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


def top_level_bash_func(text: str, name: str) -> str:
    """取一个**顶格**定义的 bash 函数体: 从 `name(){` 那一行, 到与它配对的顶格 `}`。

    为什么不用 block_after 的定长窗口: 窗口是按当时的函数长度估出来的, 函数一变长, 尾部的
    真实代码就被顶出窗口, 于是断言在代码**明明没坏**的情况下变红(cmd_rollback 加了
    --preserve-rescue 之后正是如此)。而"把窗口从 6200 调到 7800"只是把同一颗雷往后挪一格,
    下次再有人往函数里加东西就再炸一次。

    这里的边界是语法结构而不是字符数, 所以:
      · 函数长到多少都不影响(往前半部分插多少内容都一样);
      · 把调用挪到 cmd_rollback **外面**就一定找不到 —— 那正是应该判失败的情形;
      · 抽不到声明或抽不到配对的收尾一律断言失败, 不会退化成"搜全文"而假绿。
    """
    lines = text.split("\n")
    decl = f"{name}(){{"
    try:
        start = lines.index(decl)
    except ValueError:
        raise AssertionError(f"找不到顶格函数声明: {decl}") from None
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == "}"), None)
    assert end is not None, f"{name} 没有配对的顶格收尾 }}, 抽取失败(拒绝退化成全文搜索)"
    return "\n".join(lines[start:end + 1])


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

# 按语法边界取整个 cmd_rollback(不是定长窗口)——下面三条断言都只在这个函数体内找,
# 于是"调用被挪出 cmd_rollback"必然判失败, 而"函数变长"不再误报。
rollback = top_level_bash_func(pdg, "cmd_rollback")
assert '[[ "$idx" =~ ^[0-9]+$ ]]' in rollback, "rollback index should reject non-numeric input"
assert 'idx >= ${#snaps[@]}' in rollback, "rollback index should reject out-of-range input"

# P2-1: cmd_update 装好新脚本后, 必须用"新脚本"跑迁移(否则 v1.2.x 新迁移要等下次命令才生效)
# window 放宽: 必需文件安装改成"任一失败即回滚"的 if 链后, 装 pdg.sh 与调 __migrate 之间
# 还隔着失败分支 + iOS/健康服务/certbot 钩子等可选文件安装(约 1300 字符); 断言语义不变 ——
# __migrate 仍必须出现在"装好新 pdg.sh 之后"。
cmd_update = block_after(pdg, "install -m755 \"$REPO_DIR\"/deploy/bot/pdg.sh", window=1600)
assert "bash /usr/local/bin/pdg __migrate" in cmd_update, (
    "cmd_update must re-invoke the freshly-installed script for migrations, not call old in-memory funcs"
)
assert "__migrate)" in pdg and "run_all_migrations" in pdg, "hidden __migrate subcommand + run_all_migrations must exist"
# 5.1: 分派前的隐藏迁移整块取消了 —— 断言反过来: 分派段里不能再有 run_all_migrations,
# 迁移只经 `pdg __migrate`(update 内部, 快照之后)或显式 `pdg migrate`(先锁先快照)发生。
_disp = pdg.split("case \"${1:-menu}\" in", 1)[0].rsplit("cmd_tx(){", 1)[-1]
assert "run_all_migrations" not in "\n".join(
    l for l in _disp.splitlines() if not l.strip().startswith("#")), (
    "命令分派前不得再有隐藏迁移(菜单/restart 会在用户不知情时改配置)"
)
assert "migrate)       cmd_migrate;;" in pdg, "必须提供显式的事务化迁移命令 pdg migrate"

# P2-2: snapshot 包含 journald drop-in(正确+历史错路径), rollback 重启 journald
# 同 cmd_rollback: 按语法边界取整个函数, 不用字符窗口。原来那个 2600 的窗口其实**已经**
# 盖不住函数了(cmd_snapshot 现有 2670 字符), 只是四条断言的目标碰巧都还落在前 2600 字符里 ——
# 再往前半部分加 70 个字符就会在代码没坏的情况下变红。
snapshot = top_level_bash_func(pdg, "cmd_snapshot")
assert "etc/systemd/journald.conf.d/50-pdg.conf" in snapshot, "snapshot must include journald drop-in (correct path)"
assert "etc/systemd/system/journald.conf.d/50-pdg.conf" in snapshot, "snapshot should also capture legacy wrong-path file"
# journald 的 CanReload=no: 还原封顶必须 restart 才生效。要求**恰好一次** —— 多来一次是
# 白重启一个正在收日志的服务, 一次都没有则还原不生效。
assert rollback.count("systemctl restart systemd-journald") == 1, (
    "cmd_rollback must restart journald exactly once (found %d)"
    % rollback.count("systemctl restart systemd-journald"))
assert "systemctl restart systemd-journald" in rollback, (
    "rollback must restart journald (CanReload=no) so restored cap takes effect"
)
# snapshot 只打包存在的路径(历史错路径可能已被迁移删掉)+ 检查 tar 返回值(否则 tar 返 2 仍报成功)
assert '[[ -e "/$p" ]]' in snapshot, "snapshot must only tar existing paths (legacy path may be deleted by migration)"
assert "! tar czf" in snapshot, "snapshot must check tar return code, not report success on failure"

# 面板临时态净化: snapshot 用净化 config 入档; rollback 在临时树净化后再落盘。
assert "_sb_panel_managed_on" in pdg and "_sb_sanitize_panel" in pdg, (
    "pdg.sh must provide panel-ownership + sanitize helpers for snapshot/rollback"
)
assert "_sb_panel_managed_on /etc/sing-box/config.json" in snapshot, (
    "snapshot must sanitize a managed-on panel config so the secret never enters the archive"
)
assert '_sb_sanitize_panel "$tree/etc/sing-box/config.json"' in rollback, (
    "rollback must sanitize a managed-on panel config before it reaches the live filesystem"
)

# CLI 快照/回滚失败路径必须 fail closed：不允许空临时路径、坏包继续落盘或先落真实配置再净化。
assert 'stg="$(_pdg_mktemp_dir)"' in snapshot, "snapshot must use checked non-empty temporary directories"
assert 'if ! tar xzf "$f" -C "$tree"' in rollback, "rollback must stop when preflight extraction fails"
assert '_sb_sanitize_panel "$tree/etc/sing-box/config.json"' in rollback, (
    "rollback must sanitize the temporary extracted config before writing live files"
)
assert '_sb_sanitize_panel /etc/sing-box/config.json' not in rollback, (
    "rollback must not overwrite the live config before panel sanitization"
)
assert 'tar tzf "$f" > "$members"' in rollback, "rollback must validate and retain the original archive member list"
assert "快照含越界路径" in rollback, "rollback must reject archive members outside the managed etc/opt roots"
assert '_pdg_apply_snapshot_tree "$tree" "$members" /' in rollback, (
    "rollback must apply the validated temporary tree using the original archive member list"
)

# P2-3: mosdns cache 与 journald 修复相互独立(各自成函数, migrate_lowmem 里 mosdns 失败不 return 全函数)
assert "_migrate_mosdns_cache" in pdg and "_migrate_journald_cap" in pdg, (
    "mosdns cache and journald cap must be separate functions so one's failure doesn't skip the other"
)
# 这里方向相反: 原窗口 500 比函数本身(464 字符)还长, 于是越界读进了后面那个函数 ——
# 断言本该只在 migrate_lowmem 里成立, 却可能被邻居的内容满足。按边界取正好收紧这一点。
mig_low = top_level_bash_func(pdg, "migrate_lowmem")
assert "_migrate_mosdns_cache" in mig_low and "|| true" in mig_low and "_migrate_journald_cap" in mig_low, (
    "migrate_lowmem must call mosdns cache with || true then always run journald cap"
)

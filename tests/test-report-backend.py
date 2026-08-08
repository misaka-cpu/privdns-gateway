#!/usr/bin/env python3
"""Issue 6 回归: 诊断报告的内核版本与日志必须跟着**当前后端**走。

旧实现固定打印 `sing-box version` 并固定 `journalctl -u sing-box` —— 在 mihomo 机上
这两段分别退化成 "command not found" 与空日志, 恰好把排障最需要的内核信息弄丢。
断言(两内核对称): 版本小节标题 / 版本命令 / journalctl 服务名 三者都与后端一致,
且不会去取另一内核的信息。
"""
import importlib.util as u
import os
import sys
import tempfile
import types
from pathlib import Path
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
spec = u.spec_from_file_location("pdg_report", ROOT / "deploy/bot/report.py")
report = u.module_from_spec(spec); spec.loader.exec_module(report)

pass_n = 0
def ok(m):
    global pass_n; print("[OK]  ", m); pass_n += 1


TMP = tmpguard.mkdtemp()
# 只把落盘重定向到临时目录(/opt/pdg-bot 在测试环境不存在), 其余行为不动
report.os = types.SimpleNamespace(
    open=lambda p, *a, **k: os.open(os.path.join(TMP, os.path.basename(p)), *a, **k),
    fdopen=os.fdopen, O_WRONLY=os.O_WRONLY, O_CREAT=os.O_CREAT, O_TRUNC=os.O_TRUNC,
)


def collect(core):
    """以指定后端跑一次 main(), 返回 (报告全文, 执行过的命令列表)。"""
    cmds = []

    def _run(cmd, t=15):
        cmds.append(list(cmd)); return "(stub)"

    def _run_rc(cmd, t=15):
        cmds.append(list(cmd)); return 0, "(stub)"

    report.run, report.run_rc = _run, _run_rc
    report.checks = types.SimpleNamespace(
        _cert_path=lambda: "/x/fullchain.pem", _dot_domain=lambda: "dot.example",
        _server_ip=lambda: "203.0.113.1", _platform=lambda: "android",
        _core=lambda: core, expected_services=lambda: ["mosdns", "pdg-bot"],
    )
    sys.argv = ["report.py"]
    for f in os.listdir(TMP):          # 清空: 两次调用同秒生成会撞同名文件
        os.unlink(os.path.join(TMP, f))
    report.main()
    written = os.listdir(TMP)
    assert len(written) == 1, written
    return open(os.path.join(TMP, written[0]), encoding="utf-8").read(), cmds


def has_cmd(cmds, *want):
    return any(c == list(want) for c in cmds)


def journal_svcs(cmds):
    for c in cmds:
        if c and c[0] == "journalctl":
            return [c[i + 1] for i, a in enumerate(c) if a == "-u"]
    return []


def main():
    # ── mihomo 后端 ──
    text, cmds = collect("mihomo")
    assert "===== mihomo 版本 =====" in text, text[:400]; ok("mihomo: 版本小节标题为 'mihomo 版本'")
    assert has_cmd(cmds, "mihomo", "-v"); ok("mihomo: 取版本用 `mihomo -v`")
    assert not has_cmd(cmds, "sing-box", "version"); ok("mihomo: 不再去问 sing-box 版本")
    assert "===== sing-box 版本 =====" not in text; ok("mihomo: 报告不含 'sing-box 版本' 小节")
    svcs = journal_svcs(cmds)
    assert "mihomo" in svcs and "sing-box" not in svcs, svcs; ok("mihomo: journalctl 取 mihomo 日志(不取 sing-box)")
    assert "/ mihomo, 80 行)" in text, text[:400]; ok("mihomo: 日志小节标题与内核一致")

    # ── 旧机器 backend 标记里仍写着 singbox: 报告也只认 mihomo(v1.6.0 唯一内核) ──
    text, cmds = collect("singbox")
    assert "===== mihomo 版本 =====" in text; ok("旧 singbox 标记: 版本小节仍为 'mihomo 版本'")
    assert has_cmd(cmds, "mihomo", "-v"); ok("旧 singbox 标记: 取版本仍用 `mihomo -v`")
    assert not has_cmd(cmds, "sing-box", "version"); ok("旧 singbox 标记: 不去问 sing-box 版本")
    svcs = journal_svcs(cmds)
    assert "mihomo" in svcs and "sing-box" not in svcs, svcs; ok("旧 singbox 标记: journalctl 仍取 mihomo 日志")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""去广告的规则编译器、下载校验、last-known-good 与 check 判定。

这一支不起 mosdns —— 它盯的是**落盘之前**那一段:拿到的东西是不是真的规则表、规范化成
什么样、坏输入怎么拒、拒了之后现网用哪一份。三条要害:

  · **失败不得切成空表或全放行。**空表在 mosdns 那边完全合法(domain_set 允许空文件),
    所以"拿到 HTML 错页 → 编译出零条 → 一切照常" 这条路是通的, 而且全程零报错。
    唯一能挡住它的是**下载侧的判据**, 不是 mosdns。
  · **阈值不能是魔法数。**上下限与骤降比例必须能从 Phase 0 实测与当前源规模解释,
    并由边界用例钉死 —— 写死一个"看起来合理"的数字, 下次源涨了就悄悄开始拒真表。
  · **check 不许碰 DNS、不许读日志、不许落 qname。**它只查规则文件。
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmpguard          # noqa: E402 一次性临时目录: 建了就登记, 退出即清

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "deploy/bot/adblock.py"

PASS, FAIL = [0], []


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL.append(m)
    print("[FAIL] %s" % m)


def load():
    """导入生产模块。不存在就是本轮要实现的东西 —— 具名报出来, 不伪装成别的失败。"""
    if not MOD.exists():
        return None
    spec = importlib.util.spec_from_file_location("adblock", MOD)
    m = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(m)
    except Exception as e:  # noqa: BLE001
        bad("adblock.py 导入失败: %r" % (e,))
        return None
    return m


A = load()
if A is None:
    bad("deploy/bot/adblock.py 不存在 —— 下面每一条判据都无从谈起")

WORK = Path(tmpguard.mkdtemp(prefix="adblock-rules."))


def need(fn):
    """取生产函数; 缺了就记一条具名失败并返回 None(不抛, 让其余格继续跑完)。"""
    f = getattr(A, fn, None) if A else None
    if f is None:
        bad("adblock.py 缺少 %s()" % fn)
    return f


# ══ ① 规范化 ═══════════════════════════════════════════════════════════════
norm = need("normalize")
if norm:
    got = norm(["Ads.Example.INVALID.", "ads.example.invalid", "  tracker.invalid  ", "ads.example.invalid"])
    if got == ["ads.example.invalid", "tracker.invalid"]:
        ok("规范化: 小写 + 去尾点 + 去空白 + 去重, 且顺序稳定")
    else:
        bad("规范化结果不对: %r" % (got,))

# ══ ② 坏输入必须被拒(逐类) ════════════════════════════════════════════════
parse = need("parse_source")
if parse:
    cases = [
        ("HTML 错页", "<!DOCTYPE html><html><body>404</body></html>"),
        ("纯 IP", "127.0.0.1\n8.8.8.8\n"),
        ("localhost", "localhost\nlocalhost.localdomain\n"),
        ("URL", "https://example.invalid/path\n"),
        ("ABP 语法", "||ads.invalid^$third-party\n@@||good.invalid^\n"),
        ("正则", "/^ad[0-9]+\\.invalid$/\n"),
        ("空内容", "\n\n   \n"),
    ]
    for label, payload in cases:
        try:
            res = parse(payload)
            rejected = not res
        except Exception:  # noqa: BLE001 - 抛异常也算拒
            rejected = True
        (ok if rejected else bad)("拒绝 %s(未产出任何规则)" % label if rejected
                                  else "**接受了** %s —— 会编译出一张假表" % label)

# ══ ③ hosts 格式与纯域名格式都要能吃 ═══════════════════════════════════════
if parse:
    res = parse("0.0.0.0 ads.invalid\n0.0.0.0 tracker.invalid\n")
    (ok if sorted(res) == ["ads.invalid", "tracker.invalid"] else bad)(
        "hosts 格式(0.0.0.0 前缀)可解析" if sorted(res) == ["ads.invalid", "tracker.invalid"]
        else "hosts 格式解析结果不对: %r" % (res,))
    res = parse("ads.invalid\ntracker.invalid\n")
    (ok if sorted(res) == ["ads.invalid", "tracker.invalid"] else bad)(
        "纯域名格式可解析" if sorted(res) == ["ads.invalid", "tracker.invalid"]
        else "纯域名格式解析结果不对: %r" % (res,))

# ══ ④ 阈值必须可解释, 且边界被钉死 ═════════════════════════════════════════
lim = getattr(A, "LIMITS", None) if A else None
if lim is None:
    bad("adblock.py 缺少 LIMITS(阈值必须是具名常量, 不能散落成魔法数)")
else:
    need_keys = {"min_entries", "max_entries", "max_bytes", "max_drop_ratio"}
    missing = need_keys - set(lim)
    if missing:
        bad("LIMITS 缺少 %s" % sorted(missing))
    else:
        ok("LIMITS 具名齐全: %s" % ", ".join("%s=%s" % (k, lim[k]) for k in sorted(need_keys)))
        # 上限必须覆盖 Phase 0 实测过的规模(15 万条 / 5 MiB 仍在内存门内)
        if lim["max_entries"] >= 150000 and lim["max_bytes"] >= 5 * 1024 * 1024:
            ok("上限覆盖 Phase 0 实测过的 15 万条 / 5 MiB")
        else:
            bad("上限低于实测过的规模(max_entries=%s max_bytes=%s)" % (lim["max_entries"], lim["max_bytes"]))
        if 0 < lim["min_entries"] <= 1000:
            ok("下限是个真下限(%s), 能挡住截断/半截下载" % lim["min_entries"])
        else:
            bad("min_entries=%s 不合理" % lim["min_entries"])

validate = need("validate_candidate")
if validate and lim:
    small = ["a%d.invalid" % i for i in range(lim["min_entries"] - 1)]
    okc = ["a%d.invalid" % i for i in range(lim["min_entries"] + 10)]
    r1 = validate(small, prev_count=None)
    r2 = validate(okc, prev_count=None)
    (ok if not r1[0] else bad)("条目数低于下限被拒" if not r1[0] else "条目数低于下限却通过")
    (ok if r2[0] else bad)("正常规模通过" if r2[0] else "正常规模被误拒: %r" % (r2,))
    huge = ["a%d.invalid" % i for i in range(lim["max_entries"] + 1)]
    (ok if not validate(huge, prev_count=None)[0] else bad)("条目数超上限被拒")
    # 骤降: 相对上一份 LKG 掉得过狠
    drop = ["a%d.invalid" % i for i in range(lim["min_entries"] + 10)]
    r3 = validate(drop, prev_count=lim["min_entries"] * 100)
    (ok if not r3[0] else bad)("相对 LKG 骤降被拒" if not r3[0] else "骤降未被拒 —— 半截表会被当成新表")

# ══ ⑤ last-known-good: 更新失败必须继续用旧表 ══════════════════════════════
upd = need("update_lists")
if upd:
    d = WORK / "lkg"
    d.mkdir(parents=True, exist_ok=True)
    good = ["good%d.invalid" % i for i in range(2000)]
    (d / "list.lkg").write_text("\n".join(good) + "\n", encoding="utf-8")
    (d / "meta.json").write_text(json.dumps({"count": len(good), "source": "test", "updated": "2026-01-01T00:00:00Z"}), encoding="utf-8")
    before = (d / "list.lkg").read_text(encoding="utf-8")

    def fail_fetch(_url, **_kw):
        raise OSError("模拟下载失败")

    res = upd(str(d), fetch=fail_fetch)
    after = (d / "list.lkg").read_text(encoding="utf-8")
    (ok if not res.get("ok") else bad)("下载失败 → update 返回失败" if not res.get("ok") else "下载失败却报成功")
    (ok if after == before else bad)("下载失败 → LKG 逐字节未变" if after == before else "下载失败把 LKG 改坏了")
    (ok if res.get("reason") == "ADBLOCK_UPDATE_FAILED" else bad)(
        "失败带 reason code ADBLOCK_UPDATE_FAILED" if res.get("reason") == "ADBLOCK_UPDATE_FAILED"
        else "失败的 reason code 不对: %r" % res.get("reason"))

    def html_fetch(_url, **_kw):
        return ("<!DOCTYPE html><html>404</html>", "text/html", 200)

    res2 = upd(str(d), fetch=html_fetch)
    after2 = (d / "list.lkg").read_text(encoding="utf-8")
    (ok if not res2.get("ok") and after2 == before else bad)(
        "拿到 HTML 错页 → 拒绝且 LKG 未变" if (not res2.get("ok") and after2 == before)
        else "HTML 错页被接受或改动了 LKG")

# ══ ⑥ check: 分层判定 + reason code, 且不碰 DNS/日志 ═══════════════════════
check = need("check_domain")
if check:
    rd = WORK / "rules"
    rd.mkdir(parents=True, exist_ok=True)
    (rd / "infra_allow.txt").write_text("domain:dot.invalid\n", encoding="utf-8")
    (rd / "adblock_allow.txt").write_text("domain:allowed.ads.invalid\n", encoding="utf-8")
    (rd / "adblock_block.txt").write_text("domain:userblocked.invalid\n", encoding="utf-8")
    (rd / "effective_list.txt").write_text("domain:ads.invalid\n", encoding="utf-8")
    want = [
        ("dot.invalid", False, "ADBLOCK_INFRA_ALLOW"),
        ("allowed.ads.invalid", False, "ADBLOCK_USER_ALLOW"),
        ("userblocked.invalid", True, "ADBLOCK_USER_BLOCK"),
        ("deep.ads.invalid", True, "ADBLOCK_LIST_BLOCK"),
        ("nothing.invalid", False, None),
    ]
    for dom, blocked, reason in want:
        r = check(dom, str(rd))
        if r.get("blocked") == blocked and (reason is None or r.get("reason") == reason):
            ok("check %s → blocked=%s reason=%s" % (dom, r.get("blocked"), r.get("reason")))
        else:
            bad("check %s 期望 blocked=%s reason=%s, 实得 %r" % (dom, blocked, reason, r))
    r = check("deep.ads.invalid", str(rd))
    (ok if r.get("rule") else bad)(
        "check 回报命中的**规范化规则**(%s)" % r.get("rule") if r.get("rule")
        else "check 没有回报命中哪条规则")

# ══ ⑦ 零 qname 日志: 源码里不许把域名写进任何日志/文件 ═════════════════════
if A:
    src = MOD.read_text(encoding="utf-8")
    import ast
    import io
    import tokenize
    stripped = []
    try:
        for tok in tokenize.generate_tokens(io.StringIO(src).readline):
            if tok.type in (tokenize.COMMENT, tokenize.STRING):
                continue
            stripped.append(tok.string)
        body = " ".join(stripped)
    except Exception:  # noqa: BLE001
        body = src
    leaky = [k for k in ("syslog", "logging.info", "logger.info", "journal") if k in body]
    (ok if not leaky else bad)(
        "源码里没有把查询域名写日志的路径" if not leaky
        else "出现可能记录查询的调用: %s" % leaky)

print("-" * 58)
print("通过 %d, 失败 %d" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)

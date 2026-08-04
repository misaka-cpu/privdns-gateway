#!/usr/bin/env python3
"""6.1C 最终收口: 18 条负控。

每条: 精确改坏生产代码一处 → 至少一条**针对性**测试由绿转红 → 逐字节还原并 sha256 校验。

判据纪律(这几条是踩出来的, 不是写着好看的):
  · 改坏器必须先证明**锚点真实命中**。锚点没命中 = 什么都没改, 后面的"转红"要么是别的
    原因要么根本没红, 两种都不算负控;
  · **0 条转红一律判无效**。要么改坏器没打中, 要么根本没有判据盯着这件事 —— 后者才是
    真问题, 必须报出来而不是含糊过去;
  · 不许拿语法错误、测试崩溃、文件不存在冒充红灯。所以每条负控跑完都会顺带核对
    py_compile / bash -n: 改坏之后的代码必须**仍然是合法的**, 红灯得来自判据而不是解析器;
  · 还原走逐字节备份 + sha256 校验, 不用 git reset --hard / checkout -- / clean -fd。

用法: python3 tests/negctl/6.1c-final-negative-controls.py [起始编号] [结束编号]
"""
import hashlib
import io
import os
import py_compile
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BAK = tempfile.mkdtemp(prefix="negctl61c.")

TOUCHED = [
    "deploy/bot/nftlive.py",
    "deploy/bot/checks.py",
    "deploy/bot/linkstat.py",
    "deploy/bot/linksess.py",
    "deploy/bot/pdg-bot.py",
    "deploy/bot/probe81.py",
    "lib/modules.sh",
    ".github/workflows/ci.yml",
]
SHA = {}
for f in TOUCHED:
    src = os.path.join(ROOT, f)
    dst = os.path.join(BAK, f.replace("/", "__"))
    shutil.copyfile(src, dst)
    SHA[f] = hashlib.sha256(open(src, "rb").read()).hexdigest()


def restore():
    for f in TOUCHED:
        shutil.copyfile(os.path.join(BAK, f.replace("/", "__")), os.path.join(ROOT, f))
        got = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()
        if got != SHA[f]:
            print("!! 还原校验失败: %s" % f)
            sys.exit(9)


def read(f):
    return io.open(os.path.join(ROOT, f), encoding="utf-8").read()


def write(f, s):
    io.open(os.path.join(ROOT, f), "w", encoding="utf-8").write(s)


def sub(s, old, new, why):
    n = s.count(old)
    if n != 1:
        raise AssertionError("锚点命中 %d 次(应为 1): %s" % (n, why))
    return s.replace(old, new, 1)


def run_test(rel, env=None, timeout=900):
    """跑一支测试, 返回 (转红条数, 是否崩溃)。崩溃单独报 —— 它不算有效红灯。"""
    e = dict(os.environ)
    e["PDG_TEST_STRICT"] = "1"
    e.update(env or {})
    cmd = (["python3", rel] if rel.endswith(".py") else ["bash", rel])
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return 0, "超时"
    out = p.stdout + p.stderr
    red = sum(1 for l in out.splitlines() if l.startswith("[FAIL"))
    crashed = ""
    if "Traceback" in out or "SyntaxError" in out:
        crashed = "抛异常"
    if red == 0 and p.returncode != 0 and not crashed:
        # 有些支用 assert / 非 [FAIL] 前缀报错, 退出码非零同样算红, 但要区分开
        red = 1
    return red, crashed


def syntax_ok():
    """改坏之后代码仍须合法 —— 否则红灯来自解析器而不是判据。"""
    bad = []
    for f in TOUCHED:
        p = os.path.join(ROOT, f)
        if f.endswith(".py"):
            try:
                py_compile.compile(p, doraise=True, cfile=os.path.join(BAK, "x.pyc"))
            except Exception:
                bad.append(f)
        elif f.endswith(".sh"):
            if subprocess.run(["bash", "-n", p], capture_output=True).returncode:
                bad.append(f)
    return bad


RESULTS = []


ONLY = set()
for _a in sys.argv[1:]:
    if "-" in _a:
        _x, _y = _a.split("-"); ONLY |= set(range(int(_x), int(_y) + 1))
    else:
        ONLY.add(int(_a))


def nc(num, title, breaker, gates):
    if ONLY and num not in ONLY:
        return
    print("\n═══ NC%02d: %s ═══" % (num, title))
    try:
        breaker()
    except AssertionError as e:
        print("  [无效] 改坏器锚点没命中: %s" % e)
        RESULTS.append((num, title, None, "锚点没命中")); restore(); return
    print("  锚点已命中并改写")
    bad = syntax_ok()
    if bad:
        print("  [无效] 改坏后代码不合法(%s) —— 红灯会来自解析器, 不算判据" % ",".join(bad))
        RESULTS.append((num, title, None, "改坏器把代码弄成语法错")); restore(); return
    total, detail, crash = 0, [], []
    for g in gates:
        r, c = run_test(g)
        total += r
        detail.append("%s:%d" % (os.path.basename(g), r))
        if c:
            crash.append("%s(%s)" % (os.path.basename(g), c))
    if crash:
        print("  ⚠️ 有测试崩溃: %s —— 崩溃不算有效红灯" % ", ".join(crash))
    if total > 0:
        print("  ✅ 转红 %d 条  (%s)" % (total, " ".join(detail)))
        RESULTS.append((num, title, total, " ".join(detail)))
    else:
        print("  ❌ 0 条转红 —— 无效负控(没有判据盯着它)")
        RESULTS.append((num, title, 0, " ".join(detail)))
    restore()


M = "tests/test-nft-matrix.py"
D = "tests/test-doctor-firewall.py"
S = "tests/test-nft-live-semantics.py"
L = "tests/test-link-status.py"
C = "tests/test-nft-callchain.py"

# ══ 1. linkstat 退回磁盘/内核文本逐行比较 ═══════════════════════════════════
def b1():
    # 真正复现风险: 把那个**模块级**的文本比对 helper 放回来, 并让 L8 真的用它下结论。
    # (第一版只在函数内部塞了个同名局部函数 —— 那是死代码, 既不改变行为、hasattr 也看不见,
    #  于是 0 条转红。负控自己也得先证明它确实复现了要防的那件事。)
    s = read("deploy/bot/linkstat.py")
    s = sub(s, "def _l8_services(ctx):",
            "def _nft_rule_set(text):\n"
            "    return {l.strip() for l in (text or '').splitlines()\n"
            "            if l.strip() and not l.strip().startswith('#')}\n"
            "\n\n"
            "def _l8_services(ctx):", "模块级复活 _nft_rule_set")
    s = sub(s, "    if audit.ok:",
            "    import json as _j\n"
            "    _disk = _nft_rule_set(open(nftlive.DISK_CONF, encoding='utf-8',\n"
            "                               errors='replace').read())\n"
            "    _kern = _nft_rule_set(_j.dumps(kobj))\n"
            "    if _disk - _kern:\n"
            "        out.append(Finding(\n"
            "            8, 'L8_FIREWALL_RULE_MISSING', FAIL, FORWARDING, '防火墙运行状态',\n"
            "            '磁盘上有 %d 条规则没在内核里生效' % len(_disk - _kern),\n"
            "            evidence_source='磁盘/内核一致性', blocks_downstream=True))\n"
            "        return out\n"
            "    if audit.ok:", "让 L8 真的按文本差异下结论")
    write("deploy/bot/linkstat.py", s)


nc(1, "linkstat 退回磁盘/内核文本逐行比较", b1, [S, L])

# ══ 2. doctor 绕过 nftlive.audit_kernel, 恢复第二份端口解析 ═════════════════
def b2():
    s = read("deploy/bot/checks.py")
    s = sub(s, "    core = v.audit.of_kind(",
            '    _sens = {"53", "80", "81", "443", "853", "5228", "7893", "8445"}\n'
            "    _, _out, _ = _run([\"nft\", \"list\", \"chain\", \"inet\", \"pdg\", \"input\"])\n"
            "    for _ln in (_out or '').splitlines():\n"
            "        _m = re.search(r'dport\\s*\\{?\\s*([0-9,\\-\\s]+)', _ln)\n"
            "        if _m and 'saddr' not in _ln:\n"
            "            return (\"fail\", \"防火墙\", \"自查端口: \" + _m.group(1))\n"
            "    core = v.audit.of_kind(", "在 check_nft 里插回第二份端口解析")
    write("deploy/bot/checks.py", s)


nc(2, "doctor 绕过 audit_kernel, 恢复第二份端口解析", b2, [M, D])

# ══ 3. 磁盘配置无效时仍继续读内核 ═══════════════════════════════════════════
def b3():
    s = read("deploy/bot/linkstat.py")
    s = sub(s, "    if not cfg_ok:", "    if False and not cfg_ok:",
            "磁盘无效时的提前返回")
    write("deploy/bot/linkstat.py", s)


nc(3, "磁盘配置无效时仍继续读内核并给结论", b3, [M, L])

# ══ 4. 内核不可读被降成 WARN / PASS ═════════════════════════════════════════
def b4():
    s = read("deploy/bot/checks.py")
    s = sub(s, '        return ("fail", "防火墙", "读不到内核里的防火墙规则(%s) —— 无法确认放行是否生效"',
            '        return ("warn", "防火墙", "读不到内核里的防火墙规则(%s) —— 无法确认放行是否生效"',
            "读不到内核的 fail-closed")
    write("deploy/bot/checks.py", s)


nc(4, "内核不可读被降成 WARN", b4, [M, D])

# ══ 5. 必需端口缺失却放行 ═══════════════════════════════════════════════════
def b5():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893)",
            "REQUIRED_INTERNAL_TCP = ()", "必需 TCP 端口集合")
    s = sub(s, "REQUIRED_INTERNAL_UDP = (53,)", "REQUIRED_INTERNAL_UDP = ()",
            "必需 UDP 端口集合")
    write("deploy/bot/nftlive.py", s)


nc(5, "TCP 53/81/853/7893 与 UDP 53 缺失却放行会话", b5, [M, C])

# ══ 6. 80/443 redirect 缺失或目标不是 7893 却通过 ═══════════════════════════
def b6():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "        miss_core = miss_r - gms_want", "        miss_core = set()",
            "prerouting 核心缺失判定")
    s = sub(s, "            if _redirect_port(ex) != redir_port:",
            "            if False:", "redirect 目标端口核对")
    write("deploy/bot/nftlive.py", s)


nc(6, "80/443 redirect 缺失或目标口写错却通过", b6, [M, D])

# ══ 7. 来源 CIDR 放宽 / 写错 / 缺失却通过 ═══════════════════════════════════
def b7():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "        if src != cidr:\n            bad_src |= hit",
            "        if False:\n            bad_src |= hit", "TCP 来源网段核对")
    write("deploy/bot/nftlive.py", s)


nc(7, "来源 CIDR 放宽/写错/缺失却通过", b7, [M, C])

# ══ 8. verdict 错误 / 规则排在无条件 drop·reject 之后仍通过 ═════════════════
def b8():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "        if i > cut:\n            misplaced |= hit",
            "        if False:\n            misplaced |= hit", "TCP 顺序判定")
    s = sub(s, "        if _verdict(ex) != \"accept\":\n            core_hit, extra_hit",
            "        if False:\n            core_hit, extra_hit", "TCP verdict 判定")
    write("deploy/bot/nftlive.py", s)


nc(8, "verdict 错误或排在无条件 drop/reject 后仍通过", b8, [M, D])

# ══ 9. 敏感端口对全网开放未被发现 ═══════════════════════════════════════════
def b9():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "SENSITIVE_PORTS = frozenset({53, 80, 81, 443, 853, 5228, 5229, 5230, 7893, 8445})",
            "SENSITIVE_PORTS = frozenset()", "敏感端口集合")
    write("deploy/bot/nftlive.py", s)


nc(9, "敏感端口对全网开放未被发现", b9, [M, D])

# ══ 10. Android GMS 缺失被错误升级为链路硬门 ════════════════════════════════
def b10():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, '            a.doctor_fail("prerouting 缺少 Android GMS 推送的 redirect: tcp %s → mihomo"\n'
               '                          % ", ".join(str(p) for p in sorted(miss_gms)), "gms")',
            '            a.fail("prerouting 缺少 Android GMS 推送的 redirect: tcp %s → mihomo"\n'
            '                   % ", ".join(str(p) for p in sorted(miss_gms)), "gms")',
            "GMS 缺失的分档")
    write("deploy/bot/nftlive.py", s)


nc(10, "Android GMS 缺失被错误升级为链路硬门", b10, [M, S])

# ══ 11. iOS 被错误要求 / 展示 GMS ═══════════════════════════════════════════
def b11():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, '        gms_want = set(GMS_TCP) if platform != "ios" else set()',
            "        gms_want = set(GMS_TCP)", "iOS 不要求 GMS 的门")
    write("deploy/bot/nftlive.py", s)


nc(11, "iOS 被错误要求或展示 GMS", b11, [M, S])

# ══ 12. 8445 被升级为硬门 / doctor 不再点名 TG SOCKS5 ═══════════════════════
def b12():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, 'DOCTOR_ONLY_INTERNAL_TCP = {8445: "Telegram SOCKS5"}',
            "DOCTOR_ONLY_INTERNAL_TCP = {}", "doctor 专项端口表")
    s = sub(s, "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893)",
            "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893, 8445)", "把 8445 提成硬门")
    write("deploy/bot/nftlive.py", s)


nc(12, "8445 升级为硬门 / doctor 不再点名 TG SOCKS5", b12, [M, D])

# ══ 13. 8446 被写死进固定端口集合 ═══════════════════════════════════════════
def b13():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893)",
            "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893, 8446)", "把动态救援口写死进固定集合")
    write("deploy/bot/nftlive.py", s)


nc(13, "8446 写死进固定端口集合(救援关闭时误报)", b13, [M, D])

# ══ 14. 9090 被要求 nft input 放行 ══════════════════════════════════════════
def b14():
    s = read("deploy/bot/nftlive.py")
    s = sub(s, "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893)",
            "REQUIRED_INTERNAL_TCP = (53, 81, 853, 7893, 9090)", "把回环口写进 input 要求")
    write("deploy/bot/nftlive.py", s)


nc(14, "9090 被错误要求 nft input 放行", b14, [M, D])

# ══ 15. doctor 长驻进程复用陈旧审计缓存 ═════════════════════════════════════
def b15():
    s = read("deploy/bot/checks.py")
    s = sub(s, "    _nft_view_reset()\n    return [r for f in (funcs or ALL)",
            "    return [r for f in (funcs or ALL)", "run() 每轮清缓存")
    write("deploy/bot/checks.py", s)


nc(15, "doctor 长驻进程复用陈旧审计缓存", b15, [M, D])

# ══ 16. Bot / CLI 绕过 linksess.start_session() ═════════════════════════════
def b16():
    s = read("deploy/bot/pdg-bot.py")
    s = sub(s, "def _link_server_blockers():",
            "def _link_start_session_bypass():\n"
            "    import secrets, time\n"
            "    return {'token': secrets.token_urlsafe(16), 'exp': time.time() + 600}\n"
            "\n\n"
            "def _link_server_blockers():", "在 Bot 里另起一套会话生成")
    write("deploy/bot/pdg-bot.py", s)


nc(16, "Bot/CLI 绕过 linksess.start_session()", b16, ["tests/test-link-bot.py"])

# ══ 17. DynamicUser 再次尝试读 root-only profile.env ════════════════════════
def b17():
    s = read("deploy/bot/linksess.py")
    s = sub(s, "def consume(", "def _cidr_from_profile():\n"
            "    import checks\n"
            "    return checks._profile('PDG_INTERNAL_CIDR')\n"
            "\n\n"
            "def consume(", "在 consume 侧插回读 profile 的路径")
    s = sub(s, '"inside_internal_cidr": inside_internal_cidr(client_ip, rec.get("internal_cidr")),',
            '"inside_internal_cidr": inside_internal_cidr(client_ip, _cidr_from_profile()\n'
            '                                                     or rec.get("internal_cidr")),',
            "consume 改成优先读 profile 而不是会话快照")
    write("deploy/bot/linksess.py", s)


nc(17, "DynamicUser 再次尝试读 root-only profile.env", b17,
   ["tests/test-link-profile-uid.py", "tests/test-link-session.py"])

# ══ 18. nftlive.py 从安装清单 / CI 覆盖中消失 ═══════════════════════════════
def b18():
    s = read("lib/modules.sh")
    s = sub(s, "deploy/bot/nftlive.py nftlive.py 755\n", "", "安装清单里的 nftlive")
    write("lib/modules.sh", s)
    y = read(".github/workflows/ci.yml")
    y = sub(y, "        run: python3 tests/test-nft-matrix.py",
            "        run: true  # 本行被改坏器摘掉", "CI 里的 nft-matrix 登记")
    write(".github/workflows/ci.yml", y)


nc(18, "nftlive.py 从安装清单或 CI 覆盖中消失", b18,
   ["tests/test-install-closure.py", "tests/test-ci-coverage.py"])

print("\n" + "═" * 66)
for num, title, red, det in RESULTS:
    mark = "✅" if red else "❌"
    print("%s NC%02d %-44s %s  (%s)" % (mark, num, title[:44], red if red else 0, det))
bad = [r for r in RESULTS if not r[2]]
print("有效 %d / 无效 %d" % (len(RESULTS) - len(bad), len(bad)))
restore()
shutil.rmtree(BAK, ignore_errors=True)
sys.exit(1 if bad else 0)

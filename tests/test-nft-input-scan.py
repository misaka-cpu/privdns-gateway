#!/usr/bin/env python3
"""nftables input base chain 冲突扫描回归(nftscan.py / pdg.sh 前置门 / doctor)。

两件事要成立:
  ① **判据单一来源**: 迁移前置门(pdg.sh)与自检(doctor)必须用同一份实现 ——
     两处各写一遍正则迟早会漂移, 一边判冲突一边判干净比都不判还糟;
  ② **"读不到"绝不能当成"没有"**: `nft list ruleset` 失败(非 root / nft 不可用)时,
     内存里的冲突链根本没进视野。旧实现把它静默当成现场干净, 于是迁移照走 ——
     配置文本保留、端口实际不通的老毛病换个入口又回来了。

用真实 nftables 配置文本断言, 不 mock 解析逻辑本身。
"""
import importlib.util
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NFTSCAN = ROOT / "deploy/bot/nftscan.py"

spec = importlib.util.spec_from_file_location("nftscan", NFTSCAN)
nftscan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nftscan)

pass_n = 0


def ok(msg):
    global pass_n
    print("[OK]  ", msg); pass_n += 1


# ── "nft 在, 但不在 PATH 上"这套现场的搭件(第 10~12 段共用)────────────────────
def _shim_repo(tmp, candidates=()):
    """影子仓库: nftscan.py 是真实文件的原样拷贝, 只改 NFT_CANDIDATES 这一处常量(它就是为
    "测试可以指到别处"留的); lib/ 直接软链回真仓库。python 侧(--nft-path)与 shell 侧(没有
    python3 时按文本读)因此永远读到同一份清单 —— 被测的是真代码, 不是复刻。"""
    repo = os.path.join(tmp, "repo")
    os.makedirs(os.path.join(repo, "deploy", "bot"))
    os.symlink(str(ROOT / "lib"), os.path.join(repo, "lib"))
    _set_candidates(repo, candidates)
    return repo


def _set_candidates(repo, paths):
    src = (ROOT / "deploy/bot/nftscan.py").read_text(encoding="utf-8")
    body = "".join('"%s", ' % p for p in paths)
    out = re.sub(r"^NFT_CANDIDATES = \([^)]*\)", "NFT_CANDIDATES = (%s)" % body,
                 src, count=1, flags=re.M)
    assert out != src, "nftscan.py 里没有可替换的 NFT_CANDIDATES 常量"
    with open(os.path.join(repo, "deploy", "bot", "nftscan.py"), "w", encoding="utf-8") as fh:
        fh.write(out)


def _fake_nft(path, log=None, rc=0):
    """假 nft: 把每次调用的参数记进 log(用来断言"它到底被调用了没"), 按 rc 退出。"""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n")
        if log:
            fh.write('printf "%%s\\n" "$*" >> %s\n' % log)
        fh.write("exit %d\n" % rc)
    os.chmod(path, 0o755)
    return path


def _clean_env(**extra):
    """PATH 里剔掉一切含 nft 的目录 —— `command -v nft` 必须查不到, 其它命令仍可用。"""
    path = os.pathsep.join(d for d in os.environ.get("PATH", "").split(os.pathsep)
                           if d and not os.path.exists(os.path.join(d, "nft")))
    env = dict(os.environ, PATH=path, **extra)
    assert subprocess.run(["bash", "-c", "command -v nft"], env=env,
                          capture_output=True).returncode != 0, "PATH 没清干净"
    return env


# ── 真实形态的 nftables 配置文本 ───────────────────────────────────────────────
CONF_FOREIGN = """#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy accept;
    ct state established,related accept
    tcp dport 9443 accept
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
  }
}
table inet pdg {
  chain input {
    type filter hook input priority 0; policy drop;
    ip saddr 172.22.0.0/16 tcp dport { 53, 80, 443, 853 } accept
  }
}
"""

CONF_CLEAN = """#!/usr/sbin/nft -f
flush ruleset
table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
    ip saddr 172.22.0.0/16 tcp dport { 80, 443 } redirect to :7893
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    oifname "eth0" masquerade
  }
}
table inet wg {
  chain fwd {
    type filter hook forward priority 0; policy accept;
    iifname "wg0" accept
  }
}
table inet pdg {
  chain input {
    type filter hook input priority 0; policy drop;
    ip saddr 172.22.0.0/16 tcp dport { 53, 80, 443 } accept
  }
}
"""

LIVE_FOREIGN = """table inet pdg {
	chain input {
		type filter hook input priority filter; policy drop;
	}
}
table inet ufw {
	chain before-input {
		type filter hook input priority filter - 10; policy accept;
		tcp dport 51820 accept
	}
}
"""


def main():
    # ── 1. 解析: 配置文件里的外部 input 链 ──
    f = nftscan.scan_text(CONF_FOREIGN, "")
    assert len(f) == 1 and "inet filter" in f[0] and "配置文件" in f[0], f
    ok("配置文件里 table inet filter 的 input 链被认出")

    # ── 2. 只有 pdg 自己 + NAT/forward 表 → 不误报 ──
    assert nftscan.scan_text(CONF_CLEAN, "") == [], nftscan.scan_text(CONF_CLEAN, "")
    ok("NAT(prerouting/postrouting) 与 forward 表不误报")

    # ── 3. 只存在于运行 ruleset(配置文件里没有)也要认出 ──
    f = nftscan.scan_text(CONF_CLEAN, LIVE_FOREIGN)
    assert len(f) == 1 and "inet ufw" in f[0] and "运行 ruleset" in f[0], f
    ok("只在内存里的冲突链(运行 ruleset)也被认出")

    # ── 4. 两边都有 → 各报一条, 不重复 ──
    f = nftscan.scan_text(CONF_FOREIGN, LIVE_FOREIGN)
    assert len(f) == 2 and len(set(f)) == 2, f
    ok("配置文件与运行 ruleset 各报一条, 已去重")

    # ── 4b. 只认**真正的链声明**, 不认注释/字符串里的字样 ──
    # 误报的方向虽然保守(中止迁移), 但代价是用户被一条注释永久挡在升级门外, 且完全看不出
    # 为什么 —— 配置里那行明明是注释。
    commented = """table inet mynat {
  # 这台机器早期在这里挂过 hook input 的链, 后来移到 pdg 了, 留个注释备查
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    # type filter hook input priority 0; policy drop;   （已废弃）
    oifname "eth0" masquerade
  }
}
"""
    assert nftscan.scan_text(commented, "") == [], nftscan.scan_text(commented, "")
    ok("注释里写着 hook input → 不误报(用户不会被一行注释挡在升级门外)")

    quoted = """table inet myfilter {
  chain fwd {
    type filter hook forward priority 0; policy accept;
    log prefix "hook input drop test " accept
  }
}
"""
    assert nftscan.scan_text(quoted, "") == [], nftscan.scan_text(quoted, "")
    ok("字符串字面量里出现 hook input → 不误报")

    # 反向: 真的链声明一个都不能漏(收紧匹配不能把真冲突放过去)。每条都带一条放行 ——
    # 空链是惰性的、按新判据本就不算冲突, 这里要验的是"各种写法都能被认出来"。
    for decl in ("    type filter hook input priority 0; policy drop;",
                 "\t\ttype filter hook input priority filter; policy drop;",
                 "    type filter hook input priority -150; policy accept;",
                 "    type filter hook input priority mangle + 10; policy accept;"):
        txt = ("table inet other {\n  chain c {\n%s\n    tcp dport 9443 accept\n  }\n}\n"
               % decl)
        assert len(nftscan.scan_text(txt, "")) == 1, (decl, nftscan.scan_text(txt, ""))
    ok("各种真实写法的 input 链声明(数字/具名/负数/表达式优先级)一个不漏")

    # ── 4c. Debian 的 nftables 包自带空骨架 → 不算冲突 ──
    # 真机验证抓到的: 全新 Debian 12 装了 nftables 就有这么一份 /etc/nftables.conf ——
    # 三条 base chain 全是 policy accept、一条规则都没有。它既不 drop 包也没有会被架空的
    # 放行, 完全惰性; 把它当冲突拒掉等于绝大多数新机器都装不上, 而用户根本不知道该删哪行。
    STOCK = """#!/usr/sbin/nft -f
flush ruleset
table inet filter {
\tchain input {
\t\ttype filter hook input priority filter;
\t}
\tchain forward {
\t\ttype filter hook forward priority filter;
\t}
\tchain output {
\t\ttype filter hook output priority filter;
\t}
}
"""
    assert nftscan.scan_text(STOCK, "") == [], nftscan.scan_text(STOCK, "")
    ok("Debian 自带的空骨架(policy accept + 零规则)不算冲突")

    # 骨架里只要有一条放行, 就是真冲突(它会被 PDG 的 policy drop 架空)
    withrule = STOCK.replace("type filter hook input priority filter;",
                             "type filter hook input priority filter;\n\t\ttcp dport 9443 accept")
    f = nftscan.scan_text(withrule, "")
    assert len(f) == 1 and "1 条规则" in f[0], f
    ok("骨架里加一条放行 → 判为冲突, 并说明是几条规则")

    # 链自己是 policy drop: 一条规则都没有也照样冲突(它会把本项目要放行的端口丢掉)
    dropped = STOCK.replace("type filter hook input priority filter;",
                            "type filter hook input priority filter; policy drop;")
    f = nftscan.scan_text(dropped, "")
    assert len(f) == 1 and "policy drop" in f[0], f
    ok("链是 policy drop(哪怕空的)→ 判为冲突并点明原因")

    # ── 4d. nft 装在 sbin 但 PATH 里没有 → 照样要读到运行 ruleset ──
    # 真实现场: nft 在 /usr/sbin, 而 `su`(不带 -)、cron、某些容器的 root PATH 没有 sbin。
    # 只按 PATH 找的话读不到运行规则 → 扫描回"无法确认" → 调用方按"nft 没装, 没有现网规则
    # 可冲突"放过去, 于是一整套现网 input 链被当成裸机。
    with tempfile.TemporaryDirectory() as tmp:
        sbin = os.path.join(tmp, "sbin"); os.makedirs(sbin)
        fake_nft = os.path.join(sbin, "nft")
        # 桩只用 shell 内建 echo: 下面会把 PATH 清空, cat/printf(1) 这些外部命令都不在了
        with open(fake_nft, "w") as fh:
            fh.write("#!/bin/sh\n" + "".join(
                "echo '%s'\n" % ln.replace("'", "'\\''") for ln in LIVE_FOREIGN.split("\n")))
        os.chmod(fake_nft, 0o755)
        bare = os.path.join(tmp, "bin"); os.makedirs(bare)      # PATH 里只有这个空目录
        old_path, old_cand = os.environ["PATH"], nftscan.NFT_CANDIDATES
        os.environ["PATH"] = bare
        nftscan.NFT_CANDIDATES = (fake_nft,)                    # 等价于"nft 只在 sbin 里"
        try:
            assert nftscan.nft_bin() == fake_nft, "PATH 里没有 nft 时应当回落到 sbin 候选路径"
            txt, readable = nftscan.live_ruleset()
            assert readable is True, "nft 在 sbin 却被判成读不到"
            assert "inet ufw" in txt, txt[:80]
        finally:
            os.environ["PATH"] = old_path
            nftscan.NFT_CANDIDATES = old_cand
        ok("nft 只在 sbin(PATH 里没有)→ 仍能读到运行 ruleset, 不退化成「无法确认」")

    # 真的一个都没有时才算找不到
    with tempfile.TemporaryDirectory() as tmp:
        bare = os.path.join(tmp, "bin"); os.makedirs(bare)
        old_path, old_cand = os.environ["PATH"], nftscan.NFT_CANDIDATES
        os.environ["PATH"] = bare
        nftscan.NFT_CANDIDATES = (os.path.join(tmp, "nowhere", "nft"),)
        try:
            assert nftscan.nft_bin() == "", "所有候选路径都没有 nft 时应当返回空"
            _, readable = nftscan.live_ruleset()
            assert readable is False
        finally:
            os.environ["PATH"] = old_path
            nftscan.NFT_CANDIDATES = old_cand
        ok("PATH 与 sbin 候选都没有 nft → 如实回报读不到")

    # --nft-path: shell 侧与扫描器共用这一份判据
    with tempfile.TemporaryDirectory() as tmp:
        sbin = os.path.join(tmp, "sbin"); os.makedirs(sbin)
        bare = os.path.join(tmp, "bin"); os.makedirs(bare)
        nft2 = os.path.join(sbin, "nft")
        with open(nft2, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(nft2, 0o755)
        # PATH 里有 → 打印路径 + exit 0
        r = subprocess.run([sys.executable, str(NFTSCAN), "--nft-path"],
                           capture_output=True, text=True,
                           env=dict(os.environ, PATH=sbin))
        assert r.returncode == 0 and r.stdout.strip() == nft2, (r.returncode, r.stdout)
        # PATH 里没有(且候选路径也没有)→ 不打印 + exit 1
        r = subprocess.run([sys.executable, str(NFTSCAN), "--nft-path"],
                           capture_output=True, text=True,
                           env=dict(os.environ, PATH=bare))
        if os.path.exists("/usr/sbin/nft") or os.path.exists("/sbin/nft"):
            assert r.returncode == 0 and r.stdout.strip().endswith("nft"), (r.returncode, r.stdout)
            ok("--nft-path: PATH 里没有但系统 sbin 里有 → 仍报出真实路径(exit 0)")
        else:
            assert r.returncode == 1 and not r.stdout.strip(), (r.returncode, r.stdout)
            ok("--nft-path: 哪儿都没有 → exit 1 且不打印")
        ok("--nft-path 供 shell 侧复用同一判据(PATH 命中时报出该路径)")

    # ── 5. live_ruleset: 读不到必须 readable=False, 不能与"读到了且干净"混为一谈 ──
    with tempfile.TemporaryDirectory() as tmp:
        # (a) nft 返回非 0(权限不足的真实形态: Operation not permitted)
        nft = os.path.join(tmp, "nft")
        with open(nft, "w") as fh:
            fh.write("#!/bin/sh\necho 'Error: Could not process rule: Operation not permitted' >&2\nexit 1\n")
        os.chmod(nft, 0o755)
        env_path = tmp + os.pathsep + os.environ["PATH"]
        old = os.environ["PATH"]; os.environ["PATH"] = env_path
        try:
            txt, readable = nftscan.live_ruleset()
            assert readable is False, "nft 非 0 退出必须判为读不到"
            ok("nft 返回非 0(权限不足)→ readable=False")

            # (b) nft 根本不存在
            os.environ["PATH"] = tmp                     # 目录里只有上面那个 nft
            os.remove(nft)
            txt, readable = nftscan.live_ruleset()
            assert readable is False, "nft 不存在必须判为读不到"
            ok("nft 不存在 → readable=False")

            # (c) 正常返回 → readable=True, 内容原样带回
            os.environ["PATH"] = env_path                 # 桩里要用 cat, 把系统 PATH 接回来
            with open(nft, "w") as fh:
                fh.write("#!/bin/sh\ncat <<'E'\n" + LIVE_FOREIGN + "E\n")
            os.chmod(nft, 0o755)
            txt, readable = nftscan.live_ruleset()
            assert readable is True and "inet ufw" in txt
            ok("nft 正常 → readable=True 且内容带回")
        finally:
            os.environ["PATH"] = old

    # ── 6. CLI 退出码: 0=有冲突 1=确认干净 2=无法确认 ──
    with tempfile.TemporaryDirectory() as tmp:
        conf = os.path.join(tmp, "nftables.conf")
        bindir = os.path.join(tmp, "bin"); os.makedirs(bindir)
        nft = os.path.join(bindir, "nft")

        def run(conf_text, nft_script):
            with open(conf, "w") as fh:
                fh.write(conf_text)
            with open(nft, "w") as fh:
                fh.write(nft_script)
            os.chmod(nft, 0o755)
            env = dict(os.environ, PATH=bindir)
            return subprocess.run([sys.executable, str(NFTSCAN), conf],
                                  capture_output=True, text=True, env=env)

        NFT_OK = "#!/bin/sh\nexit 0\n"                       # 读得到, 内存里没规则
        NFT_DENY = "#!/bin/sh\necho denied >&2\nexit 1\n"    # 读不到

        r = run(CONF_FOREIGN, NFT_OK)
        assert r.returncode == 0 and "inet filter" in r.stdout, (r.returncode, r.stdout)
        ok("CLI: 有冲突 → 退出 0 并打印冲突表")

        r = run(CONF_CLEAN, NFT_OK)
        assert r.returncode == 1, (r.returncode, r.stdout)
        ok("CLI: 确认干净 → 退出 1")

        r = run(CONF_CLEAN, NFT_DENY)
        assert r.returncode == 2, (r.returncode, r.stdout, r.stderr)
        assert "读不到" in r.stdout or "读不到" in r.stderr, (r.stdout, r.stderr)
        ok("CLI: 读不到运行 ruleset → 退出 2(不冒充干净)")

        # 读不到、但配置文件里已经有冲突 → 仍按有冲突处理(更严的那个赢)
        r = run(CONF_FOREIGN, NFT_DENY)
        assert r.returncode == 0, (r.returncode, r.stdout)
        ok("CLI: 读不到但配置文件已有冲突 → 仍判有冲突(退出 0)")

    # ── 7. doctor 必须有这一项(迁移后再加 input 链, 此前无人告警) ──
    spec_c = importlib.util.spec_from_file_location("pdg_checks", ROOT / "deploy/bot/checks.py")
    checks = importlib.util.module_from_spec(spec_c)
    spec_c.loader.exec_module(checks)
    assert hasattr(checks, "check_nft_input_chains"), "doctor 缺少 input 链冲突检查"
    assert checks.check_nft_input_chains in checks.ALL, "该检查未挂进 doctor 的 ALL"
    ok("doctor 有 check_nft_input_chains 且已挂进 ALL")

    checks.nftscan.scan = lambda conf=None: (["配置文件: 表 `inet filter` 有挂 hook input 的 base chain"], True)
    lvl, _, detail = checks.check_nft_input_chains()
    assert lvl == "fail" and "inet filter" in detail, (lvl, detail)
    ok("doctor: 存在外部 input 链 → fail 并点名")

    checks.nftscan.scan = lambda conf=None: ([], True)
    lvl, _, _ = checks.check_nft_input_chains()
    assert lvl == "ok", lvl
    ok("doctor: 确认干净 → ok")

    checks.nftscan.scan = lambda conf=None: ([], False)
    lvl, _, detail = checks.check_nft_input_chains()
    assert lvl == "warn" and "读不到" in detail, (lvl, detail)
    ok("doctor: 读不到运行 ruleset → warn(不谎报 ok)")

    # warn 得让人知道下一步做什么: 非 root 就直说重跑一次 sudo, 别只丢一句"读不到"
    checks.os.geteuid = lambda: 1000
    _, _, detail = checks.check_nft_input_chains()
    assert "sudo pdg doctor" in detail, detail
    ok("doctor: 非 root 时告诉用户 sudo pdg doctor 才能看全")
    # 已经是 root 还读不到 → 那是 nftables 本身的问题, 别误导用户去加 sudo
    checks.os.geteuid = lambda: 0
    _, _, detail = checks.check_nft_input_chains()
    assert "sudo" not in detail and "nftables" in detail, detail
    ok("doctor: root 下仍读不到 → 指向 nftables 本身, 不误导去加 sudo")
    checks.os.geteuid = os.geteuid

    # ── 8. 单一来源: pdg.sh 不得再自带一份解析实现 ──
    pdg_src = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
    fn = pdg_src.split("_pdg_nft_foreign_input_chains(){", 1)[1].split("\n}\n", 1)[0]
    assert "nftscan.py" in fn, "pdg.sh 应调用共享的 nftscan.py"
    assert "hook\\s+input" not in fn and "hook input" not in fn.replace("hook input 的", ""), \
        "pdg.sh 里不该再内嵌一份 hook input 解析(判据必须单一来源)"
    ok("pdg.sh 委托给 nftscan.py, 未内嵌第二份解析")

    # ── 9. pdg.sh 与 doctor 对同一现场结论一致 ──
    with tempfile.TemporaryDirectory() as tmp:
        conf = os.path.join(tmp, "nftables.conf")
        bindir = os.path.join(tmp, "bin"); os.makedirs(bindir)
        with open(os.path.join(bindir, "nft"), "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(os.path.join(bindir, "nft"), 0o755)
        fnsh = os.path.join(tmp, "fn.sh")
        body = pdg_src.split("_pdg_nft_foreign_input_chains(){", 1)[1].split("\n}\n", 1)[0]
        with open(fnsh, "w") as fh:
            fh.write("_pdg_nft_foreign_input_chains(){" + body + "\n}\n")
        for text, want in ((CONF_FOREIGN, 0), (CONF_CLEAN, 1)):
            with open(conf, "w") as fh:
                fh.write(text)
            r = subprocess.run(["bash", "-c",
                                ". '%s'; _pdg_nft_foreign_input_chains '%s'" % (fnsh, conf)],
                               capture_output=True, text=True,
                               env=dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"],
                                        REPO_DIR=str(ROOT)))
            assert r.returncode == want, (want, r.returncode, r.stdout, r.stderr)
        ok("pdg.sh 前置门与 nftscan CLI 结论一致(有冲突/干净)")

    # ── 10. cmd_platform 的 nft -c 守卫: 不再靠 PATH 里有没有 nft ──
    # 回归: 守卫原本是 `command -v nft && ! nft -c -f /etc/nftables.conf`。nft 装在
    # /usr/sbin —— `su`(不带 -)、cron、精简容器的 root PATH 里没有 sbin, 于是整条校验被
    # 静默跳过: 平台切换会把一份 nft 根本不认的 nftables.conf 当成"校验通过"放行, 事务
    # 照常提交, 直到下次开机防火墙起不来才发作。
    pdg_src_txt = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")

    def _fn_body(name):
        head = "%s(){" % name
        assert head in pdg_src_txt, "pdg.sh 里没有 %s()" % name
        return head + pdg_src_txt.split(head, 1)[1].split("\n}\n", 1)[0] + "\n}\n"

    # cmd_platform 里那段守卫的**真实代码行**(不是复刻), 连同它的注释一起取出来执行
    lines = pdg_src_txt.split("\n")
    gi = [i for i, ln in enumerate(lines) if "nft 的位置与扫描器同一份判据" in ln]
    assert len(gi) == 1, "cmd_platform 的 nft 守卫标记行没找到(或不止一处): %s" % gi
    gj = next(i for i in range(gi[0], len(lines)) if lines[i] == "  fi")
    guard_src = "\n".join(lines[gi[0]:gj + 1])
    assert "_pdg_nft_bin" in guard_src and "-c -f /etc/nftables.conf" in guard_src, guard_src
    guard_code = "\n".join(ln for ln in guard_src.split("\n") if not ln.strip().startswith("#"))
    assert "command -v nft" not in guard_code, "守卫又退回 command -v nft 了: %s" % guard_code

    with tempfile.TemporaryDirectory() as tmp:
        # nft 只存在于一个**不在 PATH 上**的目录里(模拟 /usr/sbin 未导出)
        sbin = os.path.join(tmp, "sbin"); os.makedirs(sbin)
        nft_path = os.path.join(sbin, "nft")
        repo = _shim_repo(tmp, (nft_path,))

        def write_nft(rc):
            _fake_nft(nft_path, rc=rc)

        env = _clean_env(REPO_DIR=repo)

        def run(script, extra_env=None):
            return subprocess.run(["bash", "-c", _fn_body("_pdg_nft_bin") + script],
                                  capture_output=True, text=True,
                                  env=dict(env, **(extra_env or {})))

        write_nft(0)
        r = run("_pdg_nft_bin")
        assert r.stdout.strip() == nft_path, (r.stdout, r.stderr)
        ok("_pdg_nft_bin: PATH 上没有 nft, 但 sbin 里有 → 照样解析到真实路径")

        _set_candidates(repo, ())                      # 机器上真没有 nft
        r = run("_pdg_nft_bin")
        assert r.returncode == 0 and r.stdout.strip() == "", (r.returncode, r.stdout)
        ok("_pdg_nft_bin: 机器上真没有 nft → 回空串(不报错、不瞎猜路径)")
        _set_candidates(repo, (nft_path,))

        # 守卫本身: nft 不在 PATH 上, 校验依然要发生
        harness = ('_plat_rollback(){ echo ROLLBACK; }\n'
                   'g(){ local wd="%s"; mkdir -p "$wd"\n%s\n  echo PASSED_GUARD\n}\n'
                   'g; echo "rc=$?"\n' % (os.path.join(tmp, "wd"), guard_src))
        write_nft(1)                                   # nft -c 判这份配置不合法
        r = run(harness)
        assert "校验未过" in r.stdout and "ROLLBACK" in r.stdout, (r.stdout, r.stderr)
        assert "PASSED_GUARD" not in r.stdout and "rc=1" in r.stdout, r.stdout
        ok("守卫(PATH 无 nft, sbin 有): nft -c 不过 → 中止 + 回滚, 不再静默放行")

        write_nft(0)                                   # nft -c 通过
        r = run(harness)
        assert "PASSED_GUARD" in r.stdout and "ROLLBACK" not in r.stdout, r.stdout
        ok("守卫: nft -c 通过 → 正常放行")

        _set_candidates(repo, ())                      # 机器上确实没装 nft
        r = run(harness)
        assert "PASSED_GUARD" in r.stdout and "ROLLBACK" not in r.stdout, r.stdout
        ok("守卫: 机器上真没有 nft → 不拿「校验不过」卡住切换")

    # ── 11. lib/nftbin.sh: 判据只有一份, 且没有 python3 也不退化成只看 PATH ──
    # 老实现的兜底是 `command -v nft` —— 机器上缺 python3 时, "nft 在 /usr/sbin 但 PATH 没
    # 导出"这个正主场景又漏回去了。现在没 python3 就从 nftscan.py 里读**同一份** NFT_CANDIDATES。
    with tempfile.TemporaryDirectory() as tmp:
        sbin = os.path.join(tmp, "sbin"); os.makedirs(sbin)
        nft_path = _fake_nft(os.path.join(sbin, "nft"), os.path.join(tmp, "nft.log"))
        repo = _shim_repo(tmp, (nft_path,))
        env = _clean_env(REPO_DIR=repo)
        call = ". '%s/lib/nftbin.sh'; pdg_nft_bin" % repo

        r = subprocess.run(["bash", "-c", call], capture_output=True, text=True, env=env)
        assert r.returncode == 0 and r.stdout.strip() == nft_path, (r.stdout, r.stderr)
        ok("nftbin: PATH 上没有 nft → 经 nftscan 找到候选路径")

        # 真没有 python3(PATH 里连它都没有)—— 仍要找得到
        nopy = os.path.join(tmp, "nopy"); os.makedirs(nopy)
        for d in env["PATH"].split(os.pathsep):
            if not os.path.isdir(d):
                continue
            for exe in os.listdir(d):
                if exe.startswith("python"):
                    continue
                link = os.path.join(nopy, exe)
                if not os.path.exists(link):
                    try:
                        os.symlink(os.path.join(d, exe), link)
                    except OSError:
                        pass
        nopy_env = dict(env, PATH=nopy)
        assert subprocess.run(["bash", "-c", "command -v python3"], env=nopy_env,
                              capture_output=True).returncode != 0, "python3 没剔干净"
        r = subprocess.run(["bash", "-c", call], capture_output=True, text=True, env=nopy_env)
        assert r.returncode == 0 and r.stdout.strip() == nft_path, (r.stdout, r.stderr)
        ok("nftbin: 机器上没有 python3 → 从 nftscan.py 读同一份候选清单, 照样找得到")

        # 判据文件本身缺失 → 只剩 PATH, 且如实返回非 0(不瞎猜路径)
        os.remove(os.path.join(repo, "deploy", "bot", "nftscan.py"))
        r = subprocess.run(["bash", "-c", call], capture_output=True, text=True, env=env)
        assert r.returncode != 0 and r.stdout.strip() == "", (r.returncode, r.stdout)
        ok("nftbin: 连 nftscan.py 都没有 → 返回非 0 且不打印(调用方好据此提示)")

    # ── 12. 三个"只看 PATH"的老现场: uninstall 与两个 certbot 钩子 ──
    # 它们和 cmd_platform 是同一类漏检, 后果各不相同: 卸载留下内核里的 inet pdg 表(端口继续
    # 被 policy drop 挡着)、续期钩子把 80 口的放行插到 iptables(nft 那边根本没放行)。
    with tempfile.TemporaryDirectory() as tmp:
        sbin = os.path.join(tmp, "sbin"); os.makedirs(sbin)
        log = os.path.join(tmp, "nft.log")
        nft_path = _fake_nft(os.path.join(sbin, "nft"), log)
        repo = _shim_repo(tmp, (nft_path,))
        stub = os.path.join(tmp, "stub"); os.makedirs(stub)
        ipt_log = os.path.join(tmp, "iptables.log")
        _fake_nft(os.path.join(stub, "iptables"), ipt_log)      # 落到 iptables 分支就会留痕
        with open(os.path.join(stub, "systemctl"), "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")                     # 别真去动本机服务
        os.chmod(os.path.join(stub, "systemctl"), 0o755)
        base = _clean_env(REPO_DIR=repo)
        env = dict(base, PATH=stub + os.pathsep + base["PATH"])

        def nft_calls():
            with open(log, encoding="utf-8") as fh:
                return fh.read()

        # 12a. uninstall.sh 的防火墙段(真实代码行, 只是 _UN_HERE 指到影子仓库)
        #
        # 取块从 `_UN_NFT=""` 起、到还原 /etc/nftables.conf 那个 if 的 `fi` 止 —— 解析 nft 位置
        # 与用它删表之间隔着救援平面清理(那段也要 nft), 只截"删表"一小段的话, 解析代码被留在
        # 窗口外, 于是测的是"没解析当然删不掉", 而不是生产代码到底行不行。锚点用两端的语义标记,
        # 不用行数: 中间再插东西也不会让这条断言变成假红或假绿。
        un_lines = (ROOT / "uninstall.sh").read_text(encoding="utf-8").split("\n")

        def anchor(pred, what, start=0):
            for i in range(start, len(un_lines)):
                if pred(un_lines[i]):
                    return i
            raise AssertionError("uninstall.sh 里找不到锚点「%s」—— 要么它被删了(那正是本条要"
                                 "抓的回归), 要么改了写法需要同步这里" % what)

        bi = anchor(lambda ln: ln.startswith('_UN_NFT=""'), '_UN_NFT="" 位置解析')
        bj = anchor(lambda ln: ln == "fi", "还原段收尾 fi",
                    anchor(lambda ln: "nftables.conf.pdg-orig" in ln, "还原 nftables.conf", bi))
        block = "\n".join(un_lines[bi:bj + 1])
        assert "delete table inet pdg" in block and "pdg_nft_bin" in block, "取块没覆盖删表与位置解析"
        assert "command -v nft >/dev/null" not in block, "uninstall 又退回只看 PATH 了: %s" % block
        open(log, "w").close()
        r = subprocess.run(["bash", "-c", '_UN_HERE=%r\n%s' % (repo, block)],
                           capture_output=True, text=True, env=env)
        assert r.returncode == 0, (r.returncode, r.stderr)
        assert "delete table inet pdg" in nft_calls(), (nft_calls(), r.stderr)
        ok("uninstall: PATH 上没有 nft 也照样删掉内核里的 inet pdg 表")

        # 12b/12c. certbot 钩子: 拷一份把绝对路径指到沙箱(不给生产代码加接缝)
        conf = os.path.join(tmp, "nftables.conf")
        with open(conf, "w") as fh:
            fh.write("table inet pdg {}\n")
        for name, want in (("proxy-gateway-open-cert-http.sh",
                            "insert rule inet pdg input tcp dport 80 accept"),
                           ("proxy-gateway-restore-firewall.sh", "-f %s" % conf)):
            src = (ROOT / "deploy/cert" / name).read_text(encoding="utf-8")
            assert "command -v nft >/dev/null 2>&1 && nft " not in src, "%s 又退回只看 PATH" % name
            hook = os.path.join(tmp, name)
            with open(hook, "w", encoding="utf-8") as fh:
                fh.write(src.replace("/opt/privdns-gateway/lib", os.path.join(repo, "lib"))
                            .replace("/etc/nftables.conf", conf))
            os.chmod(hook, 0o755)
            open(log, "w").close(); open(ipt_log, "w").close()
            r = subprocess.run(["bash", hook], capture_output=True, text=True, env=env)
            assert r.returncode == 0, (name, r.returncode, r.stderr)
            assert want in nft_calls(), (name, nft_calls(), r.stderr)
            with open(ipt_log, encoding="utf-8") as fh:
                assert fh.read().strip() == "", "%s 落到了 iptables 分支(等于 nft 侧没生效)" % name
            ok("certbot %s: PATH 上没有 nft 也走 nft 分支(不误落 iptables)"
               % ("pre-hook" if "open" in name else "post-hook"))

    print("\n通过 %d 项断言" % pass_n)


if __name__ == "__main__":
    main()

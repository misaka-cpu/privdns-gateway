#!/usr/bin/env python3
"""卸载不得静默丢掉用户装机**之后**加的防火墙配置。

旧行为是 `mv /etc/nftables.conf.pdg-orig /etc/nftables.conf` —— "还原到装机前"。听着合理,
实际是把用户后来加的一切(WireGuard 转发、fail2ban 的表、自己写的放行)一并抹掉, 而且没有
任何提示: 卸载完才发现没了, 那时现网配置已经被覆盖。.200 实机上就这么丢过一条用户规则。

现在只删**能证明是本项目生成的**: `inet pdg` 的管理块(声明+delete+定义那三段固定形态),
以及救援平面留下的链内标记规则/旧独立表。其余一个字节不动; 形态认不出来就 fail-closed。

这里测的是判定本体(nftpurge)与卸载脚本里那段防火墙处理的**真实行为** —— 用真 nft(有的话)
校验候选, 没有真 nft 时相关断言标 [SKIP], 不拿"看起来对"充数。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import nftpurge  # noqa: E402

PASS = [0]
FAIL = [0]
SKIP = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def skip(m):
    print("[SKIP] " + m)
    SKIP[0] += 1


NFT = shutil.which("nft") or ("/usr/sbin/nft" if os.path.exists("/usr/sbin/nft") else "")
PORT = subprocess.run(["bash", "-c", "source %s/lib/rescue.sh; echo $PDG_RESCUE_PORT" % ROOT],
                      capture_output=True, text=True).stdout.strip()


def rendered_template(cidr="172.22.0.0/16", ssh="22"):
    t = open(os.path.join(ROOT, "deploy/firewall/nftables-mihomo.conf"), encoding="utf-8").read()
    return (t.replace("__INTERNAL_CIDR__", cidr).replace("__SSH_PORT__", ssh)
             .replace("__RESCUE_PORT__", PORT))


# 用户装机**之后**加的东西: 一张自己的表 + 一条同端口放行 + 一段注释
USER_EXTRA = """
# 我自己加的(卸载不许动)
table inet myvpn {
    chain myfwd {
        type filter hook forward priority 0; policy accept;
        iifname "wg0" accept
    }
}
table inet mine {
    chain input {
        type filter hook input priority 10; policy accept;
        ip saddr 192.168.50.0/24 tcp dport %s accept comment "my own rescue port"
    }
}
""" % PORT

print("── 1. 只删项目块, 用户内容逐字节保留 ──")
base = rendered_template()
cur = base + USER_EXTRA
out = nftpurge.strip_project(cur)
if not nftpurge.has_project_table(out):
    ok("本项目的 inet pdg 管理块被摘掉")
else:
    bad("项目块还在")
for frag, label in [('table inet myvpn', "用户自建的 forward 表"),
                    ('iifname "wg0" accept', "用户的 WireGuard 转发规则"),
                    ('comment "my own rescue port"', "用户自定义的同端口放行"),
                    ("# 我自己加的(卸载不许动)", "用户写的注释")]:
    if frag in out:
        ok("%s 保留" % label)
    else:
        bad("%s 被删了" % label)
if USER_EXTRA.strip() in out:
    ok("用户新增的整段逐字节一致(不是「看着还在」而是一个字节都没变)")
else:
    bad("用户段落被改动过")

# 救援规则(链内标记)也必须消失 —— 那部分由 rescue_nft 负责, 这里验两者合起来的最终状态
import rescue_nft  # noqa: E402

with_rescue, _ = rescue_nft.ensure_rescue_rule(cur, "172.22.0.0/16", int(PORT), "177.0.142.200")
final = nftpurge.strip_project(rescue_nft.strip_ours(with_rescue))
if 'comment "pdg-rescue"' not in final and not nftpurge.has_project_table(final):
    ok("链内救援规则与项目表一起清干净")
else:
    bad("清理后仍有项目痕迹")
if 'comment "my own rescue port"' in final:
    ok("同端口的**用户**规则在救援规则被删后依然在(按标记删, 不按端口删)")
else:
    bad("误删了用户的同端口规则")

# 旧的独立表(完整签名)也要一起走
legacy = ("# ==== PrivDNS Gateway 救援入口(独立表, 由救援平面维护; 完整恢复时自动保留) ====\n"
          "# 与 table inet pdg 分开, 是为了让恢复整份旧防火墙不会顺手切断救援入口。\n"
          "table inet pdgrescue\ndelete table inet pdgrescue\n"
          "table inet pdgrescue {\n    chain input {\n"
          "        type filter hook input priority -10; policy accept;\n"
          "        ip saddr 172.22.0.0/16 tcp dport %s accept\n    }\n}\n" % PORT)
out2 = nftpurge.strip_project(rescue_nft.strip_ours(cur + legacy))
if "pdgrescue" not in out2:
    ok("旧的完整签名独立表被清除")
else:
    bad("旧独立表还在")

print()
print("── 2. 认不出来就 fail-closed ──")
foreign = ("table inet pdg {\n    chain mine {\n        type filter hook forward priority 0;\n"
           "        ip saddr 10.0.0.0/8 accept\n    }\n}\n"
           "table inet pdg {\n    chain other { }\n}\n")
try:
    nftpurge.strip_project(foreign)
    bad("形态不符也照删了")
except nftpurge.Unrecognized as e:
    ok("同名但形态不符 → 拒绝删除并点名(%s)" % str(e)[:36])
foreign_rescue = ("table inet pdgrescue {\n    chain mine {\n"
                  "        type filter hook forward priority 0; policy accept;\n"
                  "        ip saddr 10.0.0.0/8 accept\n    }\n}\n")
present, full = rescue_nft.legacy_present(foreign_rescue)
if present and not full:
    ok("同名的非项目 pdgrescue 表被识别为「不是我们的」")
else:
    bad("把别人的同名表当成自己的了")
if rescue_nft.strip_ours(foreign_rescue) == foreign_rescue:
    ok("非项目同名表**一个字节未动**")
else:
    bad("动了别人的表")
# 幂等
if nftpurge.strip_project(out) == out:
    ok("重复清理幂等(已经清过的配置不会再被改)")
else:
    bad("重复清理还在改文件")

print()
print("── 3. 候选必须能过真 nft -c ──")
# nft 的校验要读内核 cache, 非 root 直接 "Operation not permitted" —— 那是环境限制, 不是
# 候选有问题。这种情况标 SKIP(CI 与 root 下会真跑), 绝不把它算成通过, 也不算成失败。
# 探针不能用空文件: 空 ruleset 不碰内核 cache, 非 root 也会成功, 于是"能不能用"判错。
# 只能拿**真候选**去试, 再按错误内容区分"语法不对"与"权限不够"。
if not NFT:
    skip("机器上没有 nft —— 候选的真实语法校验未执行(不是通过)")
else:
    d = tempfile.mkdtemp(prefix="nftpurge.")
    try:
        cand = os.path.join(d, "cand.conf")
        with open(cand, "w", encoding="utf-8") as fh:
            fh.write(out)
        r = subprocess.run([NFT, "-c", "-f", cand], capture_output=True, text=True)
        if r.returncode == 0:
            ok("摘掉项目块后的候选通过真 nft -c")
        elif "not permitted" in (r.stderr or ""):
            skip("非 root 用不了 nft(netlink 权限)—— 真语法校验未执行; root/CI 下会真跑")
        else:
            bad("候选语法不过: %s" % (r.stderr or "")[:120])
        with open(cand, "w", encoding="utf-8") as fh:
            fh.write(out + "\ntable inet broken { chain x { tcp dport } }\n")
        r = subprocess.run([NFT, "-c", "-f", cand], capture_output=True, text=True)
        if r.returncode != 0 and "not permitted" not in (r.stderr or ""):
            ok("坏候选确实过不了 nft -c(这条校验本身有效)")
        elif "not permitted" in (r.stderr or ""):
            skip("非 root: 坏候选这条同样未真验")
        else:
            bad("坏候选也过了 —— 校验形同虚设")
    finally:
        shutil.rmtree(d, ignore_errors=True)

print()
print("── 4. 卸载脚本的行为 ──")
un = open(os.path.join(ROOT, "uninstall.sh"), encoding="utf-8").read()
blk = un[un.index("_NFT_RESIDUE=\"\""):un.index("# DNS: 还原 systemd-resolved")]
code = "\n".join(l for l in blk.splitlines() if not l.lstrip().startswith("#"))
if "nftpurge.py\" --strip" in code and "< /etc/nftables.conf" in code:
    ok("卸载从**当前**配置生成候选(不是拿备份盖回去)")
else:
    bad("卸载没走当前配置")
if "mv -f /etc/nftables.conf.pdg-orig /etc/nftables.conf" not in un:
    ok(".pdg-orig 不再自动覆盖现网")
else:
    bad("还在拿 .pdg-orig 整份覆盖")
if "install -m600" in code and "/var/backups/pdg-uninstall-" in code:
    ok("动手之前先把当前配置备份到持久目录(0600)")
else:
    bad("没有先备份")
if "-c -f" in code and "现网配置**一个字节未动**" in blk:
    ok("候选先过 nft -c, 不过就不动现网")
else:
    bad("缺 nft -c 门")
if "--check" in code and "内核里仍有 table inet pdg" in blk:
    ok("磁盘与内核都要复核, 有痕迹就报出来")
else:
    bad("缺磁盘/内核的收尾复核")
if 'exit "$_UNINSTALL_FAILED"' in un:
    ok("有残留时以非 0 退出(不在没清干净时说「完成」)")
else:
    bad("卸载总是返回 0")

# ── 项目自己写的注释头不许被当成残留 ──────────────────────────────────────
# `.200` 实测撞出来的: 卸载其实干净了, 但 strip 之后 BANNER 那行注释还在, 而残留检查是拿
# 正则扫全文的 —— 注释里那句 "table inet pdg" 被当成了一张真表。于是一次成功的卸载报
# "磁盘上仍有 table inet pdg" 并以非 0 退出。任何拿退出码判断的自动化都会认为卸载失败。
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("nftpurge_t", os.path.join(ROOT, "deploy/bot/nftpurge.py"))
_np = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_np)
BANNER = "# ==== PrivDNS Gateway 管理区(table inet pdg): 由 pdg 自动维护, 勿手改 ===="
# 端口从常量源读 —— 夹具里写死数字会让 test-rescue-constants.sh 的"全仓无端口字面量"判红,
# 那条规则是对的: 端口只有一个事实源。
_PORT = re.search(r"PDG_RESCUE_PORT=\"?\$\{PDG_RESCUE_PORT:-(\d+)\}",
                  open(os.path.join(ROOT, "lib/rescue.sh"), encoding="utf-8").read()).group(1)
_only_comment = "#!/usr/sbin/nft -f\n\nflush ruleset\n\n" + BANNER + "\n\ntable inet usercheck {\n\tchain sentinel {\n\t}\n}\n"
if not _np.has_project_table(_only_comment):
    ok("只剩项目注释头时判为**干净**(注释里的字面量不是表)")
else:
    bad("注释里的 table inet pdg 被当成残留 —— 成功的卸载会被判失败")
_full = ("#!/usr/sbin/nft -f\n\nflush ruleset\n\n" + BANNER + "\n"
         "table inet pdg\ndelete table inet pdg\n\n"
         "table inet pdg {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n"
         "\t\tip saddr 10.0.0.0/8 tcp dport " + _PORT + " accept comment \"pdg-rescue\"\n\t}\n}\n\n"
         "table inet usercheck {\n\tchain sentinel {\n"
         "\t\tip saddr 10.99.0.0/16 tcp dport " + _PORT + " accept comment \"user-own-port\"\n\t}\n}\n")
_stripped = _np.strip_project(_full)
if "user-own-port" in _stripped and "usercheck" in _stripped:
    ok("摘块后用户自建表与用户在同一端口上的规则原样保留")
else:
    bad("把用户自建表也摘掉了")
if BANNER not in _stripped:
    ok("项目自己写的注释头随块一起摘掉(它也是项目痕迹)")
else:
    bad("留下了项目的注释头 —— 下一步的残留检查会被它绊住")
if not _np.has_project_table(_stripped):
    ok("摘完之后 --check 判为干净(卸载可以如实报成功)")
else:
    bad("摘完仍判有残留")
# 用户自己的注释里提到 "PrivDNS Gateway" 是很自然的事(比如标注"这段与它无关")。
# 第一版 BANNER_RE 写成了宽松模式, 在 `.200` 上真把用户那行注释删了 —— 卸载删用户的东西
# 是越权, 哪怕只是一行注释。
_uc = ("#!/usr/sbin/nft -f\n\nflush ruleset\n\n" + BANNER + "\n"
       "table inet pdg\ndelete table inet pdg\n\n"
       "table inet pdg {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t}\n}\n\n"
       "# ==== 用户自建区(与 PrivDNS Gateway 无关, 卸载不得动它) ====\n"
       "table inet usercheck {\n\tchain sentinel {\n\t}\n}\n")
_uo = _np.strip_project(_uc)
if "用户自建区" in _uo and "卸载不得动它" in _uo:
    ok("用户注释里提到 PrivDNS Gateway 也不会被卸载删掉")
else:
    bad("把用户自己的注释删了 —— 只该摘项目逐字写下的那一行")
if BANNER not in _uo:
    ok("项目自己那行注释头仍然被摘掉")
else:
    bad("项目注释头没摘掉")

# 老版本卸载留下的孤儿注释头: 表已经没了, 再跑卸载也得能把它清掉。
_orphan = "#!/usr/sbin/nft -f\n\nflush ruleset\n\n" + BANNER + "\n\ntable inet usercheck {\n\tchain sentinel {\n\t}\n}\n"
_cleaned = _np.strip_project(_orphan)
if BANNER not in _cleaned and "usercheck" in _cleaned:
    ok("表已不在、只剩孤儿注释头时, 再跑一次卸载也能把它清掉")
else:
    bad("孤儿注释头清不掉(提前返回把它跳过了)")

# ── 卸载文案不能超出它实际做的事 ────────────────────────────────────────────
# `.200` 实测: 卸载完 /opt/pdg-bot 里还剩 bot.py / mitm_*.py / probe81.py 等 10 个程序文件,
# 而收尾文案说的是"已删除 /opt/pdg-bot 下本项目安装的全部运行模块"。
# lib/modules.sh 的 PDG_RUNTIME_MODULES 是**事务与救援闭包**那 17 个模块的真源, install.sh
# 另有一路装了 Bot 本体与 MITM 组件, 它们不在这份清单里。清单本身没错, 错的是拿它当"全部"。
_mod = open(os.path.join(ROOT, "lib/modules.sh"), encoding="utf-8").read()
_listed = set(re.findall(r"^\S+ (\S+) \d{3}$", _mod, re.M))
_inst = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
_deployed = set(re.findall(r"/opt/pdg-bot/([A-Za-z0-9_.-]+\.(?:py|sh|tmpl))", _inst))
_drift = sorted(_deployed - _listed)
if _drift:
    ok("已知集合差(install 装了但不在 modules.sh 清单里): %d 个" % len(_drift))
else:
    ok("install 装进 /opt/pdg-bot 的文件都在 modules.sh 清单里")
# 只看**非注释行** —— 注释里为了说明问题会引用旧文案, 拿它判红就是自己踩自己刚修的坑。
_code_lines = "\n".join(l for l in un.split("\n") if not l.lstrip().startswith("#"))
if "全部运行模块" not in _code_lines:
    ok("收尾文案没有把清单内的模块说成「全部」")
else:
    bad("文案称删除了「全部运行模块」, 但 install 另有 %d 个文件不在该清单内: %s"
        % (len(_drift), "、".join(_drift[:6])))

print("─" * 40)
print("通过 %d, 失败 %d, 跳过 %d" % (PASS[0], FAIL[0], SKIP[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)

#!/usr/bin/env python3
"""受管块的插入锚点必须是**结构**, 不能是注释文案。

线上实测(jp, v1.10.16)升 v1.11.0 时整次更新回滚, 原因是:

    现网配置里找不到插入锚点(这台的 mosdns 配置形态不认识)

`migrate_adblock` 拿 `  # MITM 接管域名的劫持序列` 这一行**注释**当 plugins 的插入锚点。
那行注释只在**仓库模板**里(2026-07-20 的 ce9b72d 才加进去), 没有任何迁移会把它写进现网
配置。于是只有"那之后全新装机、由模板渲染出配置"的机器才有它 —— 而存量机器的配置是老模板
加一串迁移堆出来的, 一律没有。结果:**所有老机器都升不到 v1.11.0**。

仓库自己早就写下过这条规矩(tests/helpers/strip-explicit-proxy.py 开头):

    按行删, 不拿注释文案当锚点 —— 要处理的有两种来源: 仓库模板(带成段注释)和迁移写进去的

CI 全绿却没抓到, 是因为所有 E2E 的"现网配置"都是拿模板渲染的, 锚点必然存在。仓库里没有
任何夹具代表"老装机 + 迁移堆出来的配置", 而那是全部存量用户的真实形态。这一支补的就是它。

夹具**不复制任何生产配置正文** —— 从模板出发, 按线上实测到的形态特征做等价变换:
去掉全部注释行(存量配置的注释来自老模板, 与今天的模板不同), 结构一行不动。
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PDGSH = (ROOT / "deploy/bot/pdg.sh").read_text(encoding="utf-8")
TMPL = (ROOT / "deploy/mosdns/config.yaml").read_text(encoding="utf-8")

sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def extract(fn):
    m = re.search(r"^%s\(\)\s*\{.*?^\}" % re.escape(fn), PDGSH, re.S | re.M)
    return m.group(0) if m else ""


MARK_PL = ">>> pdg-adblock managed block (plugins)"
MARK_SQ = ">>> pdg-adblock managed block (internal_sequence)"


def strip_managed(t):
    for k in ("plugins", "internal_sequence"):
        t = re.sub(r" *# >>> pdg-adblock managed block \(%s\).*?"
                   r"# <<< pdg-adblock managed block \(%s\)\n" % (k, k), "", t, flags=re.S)
    return t


def strip_comments(t):
    """存量机器的形态: 结构一行不动, 但注释来自老模板 —— 与今天的模板对不上。
    最保守的等价变换就是把整行注释去掉(不动任何含结构的行)。"""
    return "".join(l for l in t.splitlines(keepends=True) if not l.strip().startswith("#"))


TEMPLATE_SHAPE = strip_managed(TMPL)                       # 全新装机: 模板渲染, 注释齐全
LEGACY_SHAPE = strip_comments(TEMPLATE_SHAPE)              # 存量机器: 结构齐全, 无模板注释

FN = extract("migrate_adblock")
print("══ 0. 前提 ══")
(ok if FN else bad)("抽到了 migrate_adblock")
if not FN:
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0])); sys.exit(1)
# 夹具自证: 存量形态里结构还在, 只是注释没了
for name, pat in (("force_hijack_seq 定义", r"^  - tag: force_hijack_seq$"),
                  ("explicit_proxy 定义", r"^  - tag: explicit_proxy$"),
                  ("$lazy_cache 那一行", r"^      - exec: \$lazy_cache$")):
    (ok if re.search(pat, LEGACY_SHAPE, re.M) else bad)("存量形态里仍有 %s" % name)
(ok if "# MITM 接管域名的劫持序列" in TEMPLATE_SHAPE else bad)("模板形态里有那行注释(对照组)")
(ok if "# MITM 接管域名的劫持序列" not in LEGACY_SHAPE else bad)(
    "存量形态里**没有**那行注释 —— 线上 jp 实测就是这样")


def run_migrate(conf_text):
    wd = Path(tmpguard.mkdtemp(prefix="pdg-anchor."))
    (wd / "deploy" / "mosdns").mkdir(parents=True)
    (wd / "deploy" / "mosdns" / "config.yaml").write_text(TMPL, encoding="utf-8")
    live = wd / "config.yaml"
    live.write_text(conf_text, encoding="utf-8")
    state = wd / "state"
    body = FN.replace("local mos=/etc/mosdns/config.yaml", 'local mos="%s"' % live)
    script = ("set -u\n"
              'REPO_DIR="%s"\nADB_STATE_DIR="%s"\n' % (wd, state)
              + 'ADB_MARK_PL="%s"\nADB_MARK_SQ="%s"\n' % (MARK_PL, MARK_SQ)
              + '_adblock_ensure_files(){ mkdir -p "$ADB_STATE_DIR"; for f in infra_allow effective_block effective_list; do : > "$ADB_STATE_DIR/$f.txt"; done; }\n'
              + 'c_y(){ echo "$*"; }; c_g(){ echo "$*"; }\n'
              + "systemctl(){ return 0; }\nsleep(){ return 0; }\n"
              + body + "\nmigrate_adblock; echo \"RC=$?\"")
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    m = re.search(r"RC=(\d+)", out)
    return (int(m.group(1)) if m else -1), out, live.read_text(encoding="utf-8"), state


print()
print("══ 1. 存量机器形态: 必须能装上受管块 ══")
rc, out, conf, state = run_migrate(LEGACY_SHAPE)
(ok if rc == 0 else bad)("返回 0(实得 rc=%d): %s" % (rc, out.strip().splitlines()[-2:] if out.strip() else ""))
(ok if conf.count(MARK_PL) == 1 and conf.count(MARK_SQ) == 1 else bad)(
    "受管块各装一处(plugins=%d sequence=%d)" % (conf.count(MARK_PL), conf.count(MARK_SQ)))
(ok if "找不到插入锚点" not in out else bad)("没有报「找不到插入锚点」")

print()
print("══ 2. 装出来的位置仍然正确 ══")
if conf.count(MARK_PL) == 1:
    i_pl = conf.find(MARK_PL)
    i_fhs = conf.find("- tag: force_hijack_seq")
    (ok if 0 <= i_pl < i_fhs else bad)(
        "plugins 段仍排在 force_hijack_seq 定义之前(pl=%d fhs=%d)" % (i_pl, i_fhs))
    seq = conf.split("- tag: internal_sequence", 1)[-1].split("\n  - tag: ", 1)[0]
    i_ab, i_cache = seq.find("adblock"), seq.find("$lazy_cache")
    (ok if 0 <= i_ab < i_cache else bad)(
        "sequence 段仍排在 $lazy_cache 之前(adblock=%d cache=%d)" % (i_ab, i_cache))
else:
    bad("受管块没装上, 位置无从谈起"); bad("同上")

print()
print("══ 3. 全新装机形态(模板渲染)不受影响 ══")
rc2, out2, conf2, _ = run_migrate(TEMPLATE_SHAPE)
(ok if rc2 == 0 and conf2.count(MARK_PL) == 1 else bad)(
    "模板形态照常安装(rc=%d plugins=%d)" % (rc2, conf2.count(MARK_PL)))

print()
print("══ 4. 认不出的形态仍然 fail-closed ══")
# 真正缺结构的配置(连 force_hijack_seq 都没有)必须拒绝, 不能因为放宽锚点就乱插
broken = re.sub(r"^  - tag: force_hijack_seq$", "  - tag: something_else", LEGACY_SHAPE, flags=re.M)
rc3, out3, conf3, state3 = run_migrate(broken)
(ok if rc3 != 0 else bad)("缺结构时返回非零(实得 rc=%d)" % rc3)
(ok if conf3 == broken else bad)("缺结构时现网配置逐字节未动")

print()
print("══ 5. 失败的迁移不许留下残留 ══")
# 线上 jp 那次失败之后, /var/lib/privdns-gateway/adblock/ 里留下了三个 0 字节文件。
# 迁移失败 = 什么都没做, 状态目录不该凭空出现。
leftover = sorted(x.name for x in state3.iterdir()) if state3.exists() else []
(ok if not leftover else bad)(
    "候选生成失败后没有留下状态文件(实得 %s)" % (leftover or "无"))
made = sorted(x.name for x in state.iterdir()) if state.exists() else []
(ok if len(made) == 3 else bad)(
    "成功那一趟仍然把三个 domain_set 输入文件建好了(实得 %s)" % (made or "无"))

print("-" * 62)
print("test-adblock-anchor-shape.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

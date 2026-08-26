#!/usr/bin/env python3
"""去广告受管块的迁移依赖: 顺序 + 前置判据。

受管块的第二条规则里写着 `!qname $explicit_proxy`。这个 tag 是 `migrate_mosdns_explicit_proxy`
装的。在 run_all_migrations 里 adblock 却排在它**前面** —— 于是一台还没有 explicit_proxy 的
老机器上, 受管块引用了不存在的插件, mosdns 起不来, 迁移正确地整份还原并返回 1, cmd_update
把整次更新回滚。结果是这台机器**永远升不上去**(HANDOFF §15 里 v1.10.2 那一类)。

两处都要修, 缺一不可:
  · 顺序: adblock 必须排在 explicit_proxy 之后;
  · 前置判据: explicit_proxy 迁移是 `|| true`, 允许自己跳过(pdgtx 卡住 / 形态不认识),
    所以 adblock 不能假设它一定成功, 必须自己确认 tag 真的在, 不在就跳过而不是插坏块。

判据全部落在**真跑那个 bash 函数**上(抽出来执行, 不是 grep 源码)。每格先自证前提。
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


def strip_managed(text):
    for kind in ("plugins", "internal_sequence"):
        text = re.sub(r" *# >>> pdg-adblock managed block \(%s\).*?"
                      r"# <<< pdg-adblock managed block \(%s\)\n" % (kind, kind),
                      "", text, flags=re.S)
    return text


def strip_explicit_proxy(text):
    """退回"还没有明确代理层"的老形态: 去掉 explicit_proxy 插件、它的 seq 与引用。"""
    out, skip = [], False
    for line in text.splitlines(keepends=True):
        if re.match(r"  - tag: explicit_proxy(_seq)?$", line.rstrip("\n")):
            skip = True
            continue
        if skip:
            if line.startswith("  - tag: ") or line.startswith("  # "):
                skip = False
            else:
                continue
        if "explicit_proxy" in line:
            continue
        out.append(line)
    return "".join(out)


OLD = strip_explicit_proxy(strip_managed(TMPL))     # 老机器: 无受管块, 无 explicit_proxy
NEW = strip_managed(TMPL)                           # 新机器: 无受管块, 有 explicit_proxy

# ═══ 0. 前提 ══════════════════════════════════════════════════════════════════
print("══ 0. 前提 ══")
FN = extract("migrate_adblock")
RA = extract("run_all_migrations")
(ok if FN else bad)("抽到了 migrate_adblock(%d 行)" % FN.count("\n"))
(ok if RA else bad)("抽到了 run_all_migrations(%d 行)" % RA.count("\n"))
if not FN or not RA:
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
# 夹具自证: 两份配置的差别恰好在 explicit_proxy 上, 且插入锚点都还在
(ok if "tag: explicit_proxy" in NEW and "tag: explicit_proxy" not in OLD else bad)(
    "夹具: NEW 有 explicit_proxy, OLD 没有")
_anchors = ("  # MITM 接管域名的劫持序列", "      - exec: $lazy_cache\n")
(ok if all(OLD.count(a) == 1 and NEW.count(a) == 1 for a in _anchors) else bad)(
    "夹具: 两份配置的插入锚点都恰好一处(否则跳过可能只是因为找不到锚点)")
(ok if MARK_PL not in OLD and MARK_PL not in NEW else bad)("夹具: 两份配置都还没有受管块")


# ═══ 1. 顺序: 真跑 run_all_migrations, 记录调用次序 ════════════════════════════
print()
print("══ 1. run_all_migrations 里的相对顺序(真跑)══")
_fns = re.findall(r"^\s*(migrate_[a-z0-9_]+)", RA, re.M)
_stub = "\n".join("%s(){ echo CALLED:%s >>\"$LOG\"; return 0; }" % (f, f) for f in set(_fns))
_log = tmpguard.mkdtemp(prefix="pdg-adblock-order.") + "/order.log"
_r = subprocess.run(["bash", "-c", "set -u\nLOG=%s\n" % _log + _stub
                     + "\nc_y(){ :; }; c_g(){ :; }; c_r(){ :; }\n"
                     + RA + "\nrun_all_migrations >/dev/null 2>&1; echo RC=$?"],
                    capture_output=True, text=True, timeout=120)
_order = [l.split(":", 1)[1] for l in Path(_log).read_text().splitlines() if l.startswith("CALLED:")]
(ok if "migrate_adblock" in _order else bad)("run_all_migrations 真的调用了 migrate_adblock")
(ok if "migrate_mosdns_explicit_proxy" in _order else bad)(
    "run_all_migrations 真的调用了 migrate_mosdns_explicit_proxy")
if "migrate_adblock" in _order and "migrate_mosdns_explicit_proxy" in _order:
    ia, ie = _order.index("migrate_adblock"), _order.index("migrate_mosdns_explicit_proxy")
    (ok if ie < ia else bad)(
        "migrate_adblock 排在 migrate_mosdns_explicit_proxy **之后**"
        "(实得 explicit_proxy=#%d, adblock=#%d)" % (ie + 1, ia + 1))
# 修顺序不等于可以把牙拔掉
_call = re.search(r"^\s*migrate_adblock[^\n]*", RA, re.M)
(ok if _call and "|| true" not in _call.group(0) and "rc=1" in _call.group(0) else bad)(
    "调用点仍然把失败记进 rc(实得 %r)" % (_call.group(0).strip() if _call else None))


# ═══ 2. 真跑 migrate_adblock ═══════════════════════════════════════════════════
def run_migrate(conf_text):
    """真跑一次 migrate_adblock。返回 (rc, 输出, 落盘后的配置正文)。"""
    wd = Path(tmpguard.mkdtemp(prefix="pdg-adblock-mig."))
    (wd / "deploy" / "mosdns").mkdir(parents=True)
    (wd / "deploy" / "mosdns" / "config.yaml").write_text(TMPL, encoding="utf-8")
    live = wd / "config.yaml"
    live.write_text(conf_text, encoding="utf-8")
    body = FN.replace("local mos=/etc/mosdns/config.yaml",
                      'local mos="%s"' % live)
    script = (
        "set -u\n"
        'REPO_DIR="%s"\n' % wd
        + 'ADB_MARK_PL="%s"\nADB_MARK_SQ="%s"\n' % (MARK_PL, MARK_SQ)
        + "_adblock_ensure_files(){ return 0; }\n"
        + "c_y(){ echo \"$*\"; }; c_g(){ echo \"$*\"; }; c_r(){ echo \"$*\"; }\n"
        # 起不起得来不是这一格要验的, 桩成"起得来"; sleep 桩掉省时间
        + "systemctl(){ return 0; }\nsleep(){ return 0; }\n"
        + body + "\nmigrate_adblock; echo \"RC=$?\"")
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=180)
    out = r.stdout + r.stderr
    m = re.search(r"RC=(\d+)", out)
    return (int(m.group(1)) if m else -1), out, live.read_text(encoding="utf-8")


print()
print("══ 2. 老机器(无 explicit_proxy): 必须跳过, 不许插坏块 ══")
rc, out, conf = run_migrate(OLD)
(ok if rc == 0 else bad)("返回 0 —— 不把整次更新拖进回滚(实得 rc=%d)" % rc)
(ok if MARK_PL not in conf and MARK_SQ not in conf else bad)(
    "现网配置里没有被插入受管块(plugins=%d sequence=%d)"
    % (conf.count(MARK_PL), conf.count(MARK_SQ)))
(ok if conf == OLD else bad)("现网配置逐字节未被改动")
(ok if "explicit_proxy" in out else bad)(
    "跳过这件事是可观察的, 且说明了原因(输出提到 explicit_proxy): %r" % out.strip()[:100])

print()
print("══ 3. 新机器(有 explicit_proxy): 照常安装(正向对照)══")
rc2, out2, conf2 = run_migrate(NEW)
(ok if rc2 == 0 else bad)("返回 0(实得 rc=%d): %s" % (rc2, out2.strip()[:120]))
(ok if conf2.count(MARK_PL) == 1 and conf2.count(MARK_SQ) == 1 else bad)(
    "受管块各装一处 —— 前置判据不是'永远跳过'(plugins=%d sequence=%d)"
    % (conf2.count(MARK_PL), conf2.count(MARK_SQ)))

print()
print("══ 4. 跳过之后仍然可恢复 ══")
# 老机器这一轮跳过了; 等 explicit_proxy 装上(同一次更新里就在后面), 下一次迁移必须补上受管块。
# 入参自证: 这一格的起点必须是"还没有受管块"的配置, 否则 migrate_adblock 会在"已经装好"
# 那条早返回上直接 return 0, 这一格就成了空转的假绿。
_step2 = NEW if conf == OLD else conf
(ok if MARK_PL not in _step2 else bad)(
    "第 4 格的起点确实还没有受管块(否则这一格是空转)")
rc3, out3, conf3 = run_migrate(_step2)
(ok if rc3 == 0 and conf3.count(MARK_PL) == 1 else bad)(
    "explicit_proxy 到位后再跑一次, 受管块补上了(rc=%d plugins=%d)"
    % (rc3, conf3.count(MARK_PL)))


# ═══ 5. 前置判据只认**定义**, 不认提及 ═════════════════════════════════════════
# 判据要回答的是"这个 plugin 存在吗"。让引用合法的是 `- tag: explicit_proxy` 这条定义;
# 注释里提一嘴、别的 tag 名恰好以它开头、或者别处引用了它, 都不能让 mosdns 认出这个插件。
# 判据一旦放宽到"文件里出现过 explicit_proxy 就算有", 这三种都会冒充成功, 于是受管块被插进
# 一个仍然没有该插件的配置 —— 正是这一轮要修的那个坏。
print()
print("══ 5. 注释 / 相似 tag / 纯引用都不算 plugin 定义 ══")
_FAKES = [
    ("注释里提到", "  # explicit_proxy 这一层等下一次更新再装\n"),
    ("相似 tag(explicit_proxy_seq)", "  - tag: explicit_proxy_seq\n    type: sequence\n"),
    ("只有引用没有定义", "      - matches: qname $explicit_proxy\n        exec: accept\n"),
]
for _label, _inject in _FAKES:
    # 注入点选在 plugins 段起始之后, 保证它确实进了文件且不破坏两个插入锚点
    _conf = OLD.replace("  - tag: ecs_china", _inject + "  - tag: ecs_china", 1)
    if _conf == OLD or "explicit_proxy" not in _conf:
        bad("%s: 夹具没注入进去 —— 这一格无效" % _label)
        continue
    _rc, _out, _after = run_migrate(_conf)
    (ok if _rc == 0 and MARK_PL not in _after else bad)(
        "%s: 仍然跳过, 没插受管块(rc=%d plugins=%d)"
        % (_label, _rc, _after.count(MARK_PL)))

# ═══ 6. 已装 / 半装 / 重复装 的处置 ════════════════════════════════════════════
# 受管块是"要么整段在, 要么整段不在"。半装(只有一半)与重复装(装了两遍)都不是本迁移能
# 自动收拾的形态 —— 猜着修比不修更危险, 必须 fail-closed 交人工, 且现网一个字节都不许动。
print()
print("══ 6. 已装 / 半装 / 重复装 ══")
_installed = run_migrate(NEW)[2]                 # 正常装好的一份
(ok if _installed.count(MARK_PL) == 1 else bad)("前提: 造出了一份装好的配置")

_rc, _out, _after = run_migrate(_installed)      # 幂等: 再跑一次什么都不该变
(ok if _rc == 0 and _after == _installed else bad)(
    "已装好时二次执行幂等: rc=%d, 配置逐字节未变=%s" % (_rc, _after == _installed))

# 重复插入: 把 plugins 与 sequence 两段各再复制一份
_dup = _installed
for _kind in ("plugins", "internal_sequence"):
    _m = re.search(r"( *# >>> pdg-adblock managed block \(%s\).*?"
                   r"# <<< pdg-adblock managed block \(%s\)\n)" % (_kind, _kind), _dup, re.S)
    _dup = _dup.replace(_m.group(1), _m.group(1) * 2, 1)
(ok if _dup.count(MARK_PL) == 2 and _dup.count(MARK_SQ) == 2 else bad)(
    "前提: 造出了重复安装的配置(plugins=%d sequence=%d)"
    % (_dup.count(MARK_PL), _dup.count(MARK_SQ)))
_rc, _out, _after = run_migrate(_dup)
(ok if _rc == 1 else bad)("重复安装: 拒绝并返回 1(实得 rc=%d)" % _rc)
(ok if _after == _dup else bad)("重复安装: 拒绝时现网配置逐字节未动")

# 半安装: 只留 plugins 那一半
_half = re.sub(r" *# >>> pdg-adblock managed block \(internal_sequence\).*?"
               r"# <<< pdg-adblock managed block \(internal_sequence\)\n", "", _installed, flags=re.S)
(ok if _half.count(MARK_PL) == 1 and _half.count(MARK_SQ) == 0 else bad)(
    "前提: 造出了半安装的配置(plugins=%d sequence=%d)"
    % (_half.count(MARK_PL), _half.count(MARK_SQ)))
_rc, _out, _after = run_migrate(_half)
(ok if _rc == 1 else bad)("半安装: 拒绝并返回 1, 不自动修补(实得 rc=%d)" % _rc)
(ok if _after == _half else bad)("半安装: 拒绝时现网配置逐字节未动")


# ═══ 7. 跳过之后 doctor 不许报绿 ═══════════════════════════════════════════════
# 迁移跳过是可恢复的, 但"可恢复"不等于"可以不说"。用户把去广告打开(profile 写了启用位)、
# 而受管块因为缺前置没装上时, 机器的实际行为是**一条都不拦** —— 这时 doctor 判绿就是在
# 替一个没生效的功能背书。判据在 checks.check_adblock, 之前没有任何测试守着它。
print()
print("══ 7. 启用位=1 但受管块不存在 → doctor 必须 fail ══")
def _doctor_verdict(conf_text, intent):
    """真跑 checks.check_adblock, 返回 (等级, 文案)。"""
    wd = Path(tmpguard.mkdtemp(prefix="pdg-adblock-doctor."))
    (wd / "config.yaml").write_text(conf_text, encoding="utf-8")
    (wd / "state").mkdir()
    code = (
        "import sys\n"
        "sys.path.insert(0, %r)\n" % str(ROOT / "deploy/bot")
        + "import checks\n"
        + "checks.MOSDNS_CONF = %r\n" % str(wd / "config.yaml")
        + "checks.ADBLOCK_STATE_DIR = %r\n" % str(wd / "state")
        + "checks._adblock_intent = lambda: %r\n" % bool(intent)
        + "r = checks.check_adblock()\n"
        + "print('NONE' if r is None else r[0] + '\\t' + r[2])\n")
    r = subprocess.run(["python3", "-c", code], capture_output=True, text=True, timeout=60)
    out = (r.stdout or "").strip()
    if not out:
        return ("<跑不起来>", (r.stderr or "")[:160])
    if out == "NONE":
        return ("none", "")
    lvl, _, msg = out.partition("\t")
    return (lvl, msg)


_lvl, _msg = _doctor_verdict(OLD, intent=True)     # 启用了, 但配置里没有受管块
(ok if _lvl == "fail" else bad)(
    "启用位=1 且无受管块: doctor 判 fail(实得 %s: %s)" % (_lvl, _msg[:70]))
(ok if "受管块" in _msg else bad)("文案点明了缺的是受管块(实得: %s)" % _msg[:70])

_lvl0, _ = _doctor_verdict(OLD, intent=False)      # 没启用也没装: 本项不适用, 不该刷屏
(ok if _lvl0 == "none" else bad)(
    "没启用也没装: 本项不适用(实得 %s)" % _lvl0)

print("-" * 62)
print("test-adblock-migration-order.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

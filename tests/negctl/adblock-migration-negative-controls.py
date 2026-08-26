#!/usr/bin/env python3
"""负控:去广告受管块的迁移依赖判据有没有牙。

盯三处生产代码 —— `run_all_migrations` 里 adblock 的调用位置、`migrate_adblock` 的
explicit_proxy 前置判据(含它在函数里的位置)、以及 `checks.check_adblock` 对"启用了却
没装上"的判决。这一支回答的是: **如果它们退回原样, 我们会不会知道?**

做法与其它负控一致(规矩见 HANDOFF §6): 逐格把生产代码改坏(只改工作副本, 正式树一个
字节不动), 跑聚焦测试, 看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本,
必须全绿 —— 基线不绿的话后面每一格的"新增"都算不出来。

每格五步, 缺一不算有效:
  · 锚点在整份文件里**恰好命中**预期次数;
  · 替换确实落进了文件;
  · 改坏后语法门仍过(bash -n / py_compile)—— 语法错造成的红不算"判据抓住了";
  · 失败集合有**具名新增**(0 条转红 = 这一格无效, 判 FAIL);
  · 恢复后正式树 sha256 与 before-image 逐字节一致。

十二格:
  ① 把 adblock 挪回 explicit_proxy 之前   —— 本轮修的头一件事
  ② 删掉整个前置判据                      —— 老机器上插进引用不存在插件的块
  ③ 前置判据反过来(有才跳过)             —— 永久跳过, 且再也补不上(不可恢复)
  ④ 跳过时返回 1                          —— 又把整次更新拖进回滚
  ⑤ 跳过时不吭声                          —— 静默缺件, 用户无从知道功能没装上
  ⑥ 判定成立却仍然插块                    —— 判据形同虚设
  ⑦ 调用点改回 `|| true`                  —— 真失败时被吞掉
  ⑧ 判据放宽到裸 explicit_proxy           —— 注释里提一嘴就能冒充 plugin 定义
  ⑨ 摘掉"重复安装"检查                    —— 装了两遍还接着改
  ⑩ 判据挪到第一个写动作之后              —— 判定要跳过的机器仍然被动过
  ⑪ doctor 把"启用了却没装上"判成绿        —— 替一个没生效的功能背书
  ⑫ 只加无关注释                          —— 反向对照, 不该有任何新失败
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PDG = "deploy/bot/pdg.sh"
CHK = "deploy/bot/checks.py"
TOUCHED = [ROOT / PDG, ROOT / CHK]

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def failures(out):
    """具名失败集合, 归一化掉临时目录/哈希/大数(§9.15)。"""
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


SUITE = ["python3", "tests/test-adblock-migration-order.py"]


def run_suites(wd):
    r = run(SUITE, cwd=wd)
    return failures(r.stdout + r.stderr)


# ── 锚点(与 deploy/bot/pdg.sh 逐字节对应)──────────────────────────────────────
CALL = "  migrate_adblock || rc=1   # 去广告受管块(默认关闭; 失败要让整次更新回滚)\n"
ORDER_BLOCK = (
    "  migrate_mosdns_explicit_proxy || true\n"
    "  # **必须排在 explicit_proxy 之后**: 去广告受管块里写着 `!qname $explicit_proxy`, 那个 tag 是\n"
    "  # 上一行装的。排在它前面的话, 一台还没有明确代理层的老机器会被插进一个引用不存在插件的块 ——\n"
    "  # mosdns 起不来, 迁移整份还原并返回 1, 整次更新回滚, 这台机器就再也升不上去了。\n"
    + CALL)
GATE_COMMENT = (
    "  # 前置依赖: 受管块对外只引用一个 tag —— `$explicit_proxy`(由 migrate_mosdns_explicit_proxy 装)。\n"
    "  # 调用顺序已经把它排在前面, 但那一支是 `|| true`, 允许自己跳过(pdgtx 卡在待收尾 / 配置形态\n"
    "  # 不认识)。所以这里不能假设它成功, 必须自己确认 tag 真的定义了。不在就**跳过**而不是报错:\n"
    "  # 插一个引用不存在插件的块会让 mosdns 起不来 → 整次更新回滚 → 这台机器再也升不上去。\n"
    "  # 跳过是可恢复的: 等 explicit_proxy 到位, 下一次 pdg update 会把受管块补上。\n"
    "  # 判据用 `- tag: explicit_proxy` 的**定义**(锚到行尾, 免得匹配上 explicit_proxy_seq),\n"
    "  # 而不是它有没有被引用 —— 让引用合法的是定义, 不是用法。\n"
    "  # 位置也是判据的一部分: 它必须排在**所有写入之前**, 包括建规则文件那一步。\n")
GATE_HEAD = "  if ! grep -qE '^ *- tag: explicit_proxy$' \"$mos\"; then\n"
SAY = ('    c_y "  [去广告] 这台的 mosdns 还没有 explicit_proxy 明确代理层 —— 本次跳过受管块安装"\n'
       '    c_y "           (去广告功能暂不可用; 等明确代理层到位后, 下一次 pdg update 会自动补上)。"\n')
GATE = GATE_COMMENT + GATE_HEAD + SAY + "    return 0\n  fi\n"
ENSURE = ('  _adblock_ensure_files || { c_y "  ❌ 去广告规则文件建不出来, 不动 mosdns 配置。"; return 1; }\n')
DUP = ('  if [[ "$n_pl" -gt 1 || "$n_sq" -gt 1 ]]; then\n'
       '    c_y "  ❌ mosdns 配置里 pdg-adblock 受管块出现多次(plugins=$n_pl sequence=$n_sq) —— 不自动修改, 请人工核对。"\n'
       '    return 1\n'
       '  fi\n')
DOCTOR = ('        if intent:\n'
          '            return ("fail", name, "profile 里写着已启用, 但 mosdns 配置里根本没有去广告受管块 "\n')

# 每格 = (标签, 文件, [(锚点, 替换, 预期命中数)], 期望转红的关键词)
MUTATIONS = [
    ("① 把 adblock 挪回 explicit_proxy 之前", PDG,
     [(ORDER_BLOCK, CALL + "  migrate_mosdns_explicit_proxy || true\n", 1)],
     "之后"),
    ("② 删掉整个前置判据", PDG,
     [(GATE, "", 1)],
     "受管块"),
    ("③ 前置判据反过来(有 explicit_proxy 才跳过 → 永久跳过)", PDG,
     [(GATE_HEAD, "  if grep -qE '^ *- tag: explicit_proxy$' \"$mos\"; then\n", 1)],
     "永远跳过"),
    ("④ 跳过时返回 1(又把整次更新拖进回滚)", PDG,
     [(SAY + "    return 0\n", SAY + "    return 1\n", 1)],
     "返回 0"),
    ("⑤ 跳过时不吭声(静默缺件)", PDG,
     [(SAY, "", 1)],
     "可观察"),
    ("⑥ 判定成立却仍然插块", PDG,
     [(SAY + "    return 0\n  fi\n", SAY + "    :\n  fi\n", 1)],
     "没有被插入受管块"),
    ("⑦ 调用点改回 `|| true`", PDG,
     [(CALL, "  migrate_adblock || true   # 去广告受管块(默认关闭; 失败要让整次更新回滚)\n", 1)],
     "记进 rc"),
    ("⑧ 判据放宽到裸 explicit_proxy(注释即可冒充定义)", PDG,
     [(GATE_HEAD, "  if ! grep -q 'explicit_proxy' \"$mos\"; then\n", 1)],
     "注释里提到"),
    ("⑨ 摘掉重复安装检查", PDG,
     [(DUP, "", 1)],
     "重复安装"),
    ("⑩ 判据挪到第一个写动作之后", PDG,
     [(GATE + ENSURE, ENSURE + GATE, 1)],
     "连规则文件都没建"),
    ("⑪ doctor 把'启用了却没装上'判成绿", CHK,
     [(DOCTOR,
       '        if intent:\n'
       '            return ("ok", name, "去广告受管块不在, 但先当它没事 "\n', 1)],
     "doctor 判 fail"),
    ("⑫ 只加一行无关注释(反向对照)", PDG,
     [("migrate_adblock(){", "# (负控的空转对照, 不改变任何行为)\nmigrate_adblock(){", 1)],
     None),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-adbmig-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (PDG, CHK)}

    base = run_suites(wd)
    if base:
        bad("基线(未改坏)就有 %d 条失败 —— 后面每一格的'新增'都算不出来: %s"
            % (len(base), sorted(base)[:2]))
        raise SystemExit(1)
    ok("基线: 聚焦测试在工作副本里全绿(具名失败 0 条)")

    for label, rel, edits, want in MUTATIONS:
        target = Path(wd) / rel
        text = pristine[rel]
        anchored = True
        for anchor, repl, hits_want in edits:
            hits = text.count(anchor)
            if hits != hits_want:
                bad("%s: 锚点命中 %d 次(应为 %d)—— 改坏器没打在预期位置" % (label, hits, hits_want))
                anchored = False
                break
            text = text.replace(anchor, repl, 1)
        if not anchored:
            target.write_text(pristine[rel], encoding="utf-8")
            continue
        if text == pristine[rel]:
            bad("%s: 替换没有真的落进文件" % label)
            continue
        target.write_text(text, encoding="utf-8")

        syn = run(["bash", "-n", str(target)]) if rel.endswith(".sh") \
            else run(["python3", "-m", "py_compile", str(target)])
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 这一格的红不作数(%s)" % (label, (syn.stderr or "")[:90]))
            target.write_text(pristine[rel], encoding="utf-8")
            continue

        got = run_suites(wd)
        new = got - base
        target.write_text(pristine[rel], encoding="utf-8")

        if want is None:
            (ok if not new else bad)(
                "%s: 新增失败 0 条(判据没在看噪声)" % label if not new
                else "%s: 不该有新失败, 却新增 %d 条: %s" % (label, len(new), sorted(new)[:2]))
            continue
        if not new:
            bad("%s: **0 条转红** —— 这一格的判据没有牙" % label)
        elif not any(want in n for n in new):
            bad("%s: 转红了但没命中预期判据(%s): %s" % (label, want, sorted(new)[:2]))
        else:
            hit = sorted(n for n in new if want in n)[0]
            ok("%s: 新增 %d 条具名失败, 含 → %s" % (label, len(new), hit[:80]))
finally:
    drift = [str(p) for p in TOUCHED if sha(p) != before[p]]
    if drift:
        bad("正式树被改动了(负控只该改工作副本): %s" % drift)
    else:
        ok("正式树 sha256 与 before-image 逐字节一致(%d 个文件)" % len(TOUCHED))
    for p in TOUCHED:
        if os.stat(p).st_mode != modes[p]:
            bad("正式树文件 mode 变了: %s" % p)

print("-" * 62)
print("adblock-migration-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

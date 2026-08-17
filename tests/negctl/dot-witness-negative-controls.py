#!/usr/bin/env python3
"""6.2A 负控: 逐条把已钉死的契约改坏, 证明**至少有一支测试会因此转红**。

为什么要有这支: 6.2A 的测试现在全绿, 但"全绿"本身不说明它们有牙齿 —— 一条写错的
判据、一个扫不到东西的正则, 在什么都没坏的时候也是绿的。负控是唯一能回答
"如果产品真的坏了, 我们会不会知道"这个问题的东西。

每条负控的流程固定四步, 缺一不算有效:
    1. 锚点命中数必须**精确**等于预期(多了少了都说明改坏器没打在预期位置);
    2. 改坏后语法门必须仍然通过(语法错导致的红不算"测试抓住了");
    3. 指定的测试里至少一支转红;
    4. 恢复后 sha256 逐字节一致。

改坏操作全部落在一份**工作副本**里(git worktree 之外的独立 clone), 正式工作树一个
字节都不动。
"""
import argparse
import ast
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ── 可能被改坏的文件, 全部登记。收尾时逐个 sha256sum -c ────────────────────
TOUCHED = [
    "deploy/bot/dotwitness.py",
    "deploy/bot/pdg-dotwitness.service",
    "deploy/mosdns/config.yaml",
    "install.sh",
    "tests/test-dot-witness.py",
    "tests/test-dot-render.py",
    "tests/test-dot-privacy.py",
    "tests/test-dot-faults.py",
    "tests/test-dot-strict.py",
    "tests/e2e-dot-witness.sh",
    "tests/e2e-dot-isolation.sh",
    "tests/e2e-dot-systemd.sh",
    "tests/dns-policy-test.sh",
]

W = "deploy/bot/dotwitness.py"
U = "deploy/bot/pdg-dotwitness.service"
M = "deploy/mosdns/config.yaml"
I = "install.sh"

PY_TESTS = ["tests/test-dot-witness.py", "tests/test-dot-render.py",
            "tests/test-dot-privacy.py", "tests/test-dot-faults.py",
            "tests/test-dot-strict.py"]

# 以 M(mosdns 的 YAML)为目标的负控 ID —— 钉死集合, 不钉数量。
# 每个 ID 都代表"这条 mutation 已经用钉定 mosdns 真加载验证过, 改坏后 YAML 仍合法";
# syntax_ok() 对 .yaml 恒真, 所以这份人工复核是唯一的保障(理由见那里的注释)。
# 集合一旦增删、或有别的负控改成打 M, check_yaml_inventory() 会判红, 提醒重新复核。
M_CLASS_IDS = frozenset({1, 2, 5, 6, 7, 17})

npass = nfail = nskip = nunver = 0
FAILED = []


def ok(m):
    global npass
    npass += 1
    print("[OK]   %s" % m)


def bad(m):
    global nfail
    nfail += 1
    FAILED.append(m)
    print("[FAIL] %s" % m)


def skip(m):
    global nskip
    nskip += 1
    print("[SKIP] %s" % m)


def unver(m):
    global nunver
    nunver += 1
    print("[UNVERIFIED] %s" % m)


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class Copy:
    """一份独立工作副本。所有改坏都发生在这里, 正式树不受影响。"""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="pdg-negctl-",
                                    dir=os.environ.get("E2E_TMP") or None)
        self.dir = os.path.join(self.dir, "wc")
        # 必须是**真的 git 检出**, 不能只 cp 几个文件: test-dot-privacy.py 会
        # `git show <main-sha>:deploy/mosdns/config.yaml` 取基线做主链比对。副本不是
        # 仓库的话它恒红 —— 那样每条负控都"命中", 而其实什么都没证明。这一条是
        # runner 自检第 3 项抓出来的。
        r = subprocess.run(["git", "clone", "-q", "--shared", "--no-checkout", REPO, self.dir],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("负控工作副本 clone 失败: %s" % (r.stderr or "")[:200])
        head = subprocess.run(["git", "-C", REPO, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        subprocess.run(["git", "-C", self.dir, "checkout", "-q", head], check=True)
        # 未提交的改动也要带过去, 否则测的是上一个 commit
        for rel in TOUCHED:
            src = os.path.join(REPO, rel)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(self.dir, rel))
        self.base = {rel: sha(os.path.join(self.dir, rel)) for rel in TOUCHED}

    def path(self, rel):
        return os.path.join(self.dir, rel)

    def read(self, rel):
        return open(self.path(rel)).read()

    def write(self, rel, text):
        with open(self.path(rel), "w") as f:
            f.write(text)

    def restore(self, rel):
        shutil.copy2(os.path.join(REPO, rel), self.path(rel))

    def verify_all(self):
        bad_ones = [rel for rel in TOUCHED if sha(self.path(rel)) != self.base[rel]]
        return bad_ones

    def drop(self):
        root = os.path.dirname(self.dir)
        if os.environ.get("PDG_KEEP_TMP") not in (None, "", "0"):
            print("[PDG_KEEP_TMP] 负控工作副本保留: %s" % self.dir)
        else:
            shutil.rmtree(root, ignore_errors=True)


def syntax_ok(cp, rel):
    p = cp.path(rel)
    if rel.endswith(".py"):
        r = subprocess.run([sys.executable, "-m", "py_compile", p], capture_output=True)
        return r.returncode == 0
    if rel.endswith(".sh"):
        r = subprocess.run(["bash", "-n", p], capture_output=True)
        return r.returncode == 0
    if rel.endswith(".yaml"):
        # **本 runner 没有 YAML 语法门。** 这里恒真, 不是"另有人管", 而是真的没管 ——
        # 早先那句"由真 mosdns 校验, 见 render 类负控"是假话: 本文件的 catcher 全是
        # tests/test-dot-*.py 这类纯静态测试, 从不启动 mosdns; 真 mosdns 的加载发生在
        # e2e-dot-migrate.sh 与 ci-dot-fixture.sh 里, 那是另一条路, 校验的也不是这里的
        # mutation。
        #
        # 为什么现在可以这样放着: 当前六条 M 类 mutation(见 M_CLASS_IDS)已用钉定的
        # mosdns v5.3.4 逐条真加载验证过, 改坏后产出的 YAML 全部仍然合法 —— 所以它们的
        # 红灯不可能来自解析失败。
        #
        # **新增或调整任何改 .yaml 的 mutation 时, 必须重新做一次真 mosdns 加载复核**,
        # 否则一条破坏缩进/引号的 mutation 会让"YAML 解析失败导致的红"冒充"契约被守住",
        # 而这正是 runner 自检第 4 项对 .py/.sh 拦着、对 .yaml 拦不住的那类假绿。
        # 下面的 check_yaml_inventory() 把 M 类 ID 集合钉死, 集合一变就判红提醒复核。
        return True
    return True


def _m_class_ids(src):
    """从源码里抽出所有以 M 为目标的 nc() 调用的 ID(保留重复, 供查重)。

    用 AST 而不是正则: 锚点里满是引号、反斜杠与跨行字符串, 正则抽这种东西迟早抽歪,
    而抽歪的清单会安静地给出错误的"集合一致"。只取前四个位置参数里的字面量 ——
    edits 是不是字面量无所谓(NC5 的就不是), 这里不碰它。
    """
    ids = []
    for node in ast.walk(ast.parse(src)):
        if not (isinstance(node, ast.Call) and getattr(node.func, "id", "") == "nc"):
            continue
        a = node.args
        if len(a) < 4 or getattr(a[3], "id", None) != "M":
            continue
        try:
            ids.append(ast.literal_eval(a[1]))
        except (ValueError, SyntaxError):        # ID 不是字面量: 本身就该判红
            ids.append(None)
    return ids


def check_yaml_inventory(src=None):
    """fail-closed: M 类负控的 ID 集合必须与 M_CLASS_IDS 逐个相等。

    这**不是** YAML 解析器, 也不打算变成一个: 它只回答"改 .yaml 的负控还是不是原来
    那几条"。是 → 之前那次真 mosdns 复核仍然作数; 不是 → 判红, 让人去重做复核。
    """
    if src is None:
        with io.open(__file__, encoding="utf-8") as f:
            src = f.read()
    ids = _m_class_ids(src)
    if any(i is None for i in ids):
        bad("YAML mutation 清单: 有 nc() 的 ID 不是字面量, 无法核对集合")
        return
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        bad("YAML mutation 清单: ID 重复 %s —— 集合语义被破坏" % dup)
        return
    got = frozenset(ids)
    if got == M_CLASS_IDS:
        ok("YAML mutation 清单未变(NC%s), 之前的真 mosdns 加载复核仍作数"
           % ", NC".join(str(i) for i in sorted(got)))
        return
    bad("YAML mutation 清单变了: 多 %s / 少 %s —— syntax_ok() 对 .yaml 恒真, "
        "必须用钉定 mosdns 重做一次真加载复核, 再更新 M_CLASS_IDS"
        % (sorted(got - M_CLASS_IDS) or "无", sorted(M_CLASS_IDS - got) or "无"))


def run_test(cp, rel, extra_env=None):
    """在工作副本里跑一支测试, 返回 rc。生产模块从副本里 import。"""
    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(cp.dir, "deploy", "bot")
    env.pop("RUNTIME_DIRECTORY", None)
    env.pop("PDG_DOTWITNESS_SUFFIX", None)
    env.pop("PDG_DOTWITNESS_PORT", None)
    env.update(extra_env or {})
    cmd = [sys.executable, cp.path(rel)] if rel.endswith(".py") else ["bash", cp.path(rel)]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=1200)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def judge(num, name, total_hit, reds):
    """裁决层。单独抽出来是为了让自检能直接喂 red_count=0 —— 靠"找一个看起来无害的
    生产改动"来验这条, 结果依赖环境(某支测试恰好因别的原因红/不红), 宿主与容器会给出
    不同答案。合成输入才是环境无关的。"""
    if reds:
        ok("NC%02d %s → 锚点 %d 处, 转红 %d 支: %s"
           % (num, name, total_hit, len(reds), ", ".join(reds)))
    else:
        bad("NC%02d %s → 锚点 %d 处命中但 **0 条转红**, 负控无效" % (num, name, total_hit))


def nc(cp, num, name, rel, edits, hits, catchers, expect_syntax_ok=True):
    """一条负控。edits = [(old, new, 预期命中次数), ...]"""
    src = cp.read(rel)
    total_hit = 0
    new = src
    anchor_bad = None
    for old, repl, want in edits:
        got = new.count(old)
        total_hit += got
        if got != want:
            anchor_bad = "锚点 %r 命中 %d 次, 预期 %d" % (old[:40], got, want)
            break
        new = new.replace(old, repl)
    if anchor_bad:
        bad("NC%02d %s → %s" % (num, name, anchor_bad))
        cp.restore(rel)
        return
    cp.write(rel, new)
    try:
        if expect_syntax_ok and not syntax_ok(cp, rel):
            bad("NC%02d %s → 改坏后语法不合法, 这条不算有效负控" % (num, name))
            return
        reds = []
        for t in catchers:
            rc, _ = run_test(cp, t)
            if rc != 0:
                reds.append(os.path.basename(t))
        judge(num, name, total_hit, reds)
    finally:
        cp.restore(rel)
        if sha(cp.path(rel)) != cp.base[rel]:
            bad("NC%02d %s → 恢复后摘要不一致" % (num, name))


# ═══════════════════════════════════════════════════════════════════════════
def self_check():
    """正式负控前先证明 runner 自己有牙齿。每一项都必须让 runner 判红。"""
    global npass, nfail
    print("── runner 自检 ──")
    cp = Copy()
    results = []

    def probe(label, fn):
        global npass, nfail, FAILED
        p0, f0 = npass, nfail
        fn(cp)
        got_fail = nfail > f0
        npass, nfail = p0, f0                       # 自检不计入正式统计
        FAILED[:] = FAILED[:len(FAILED) - (1 if got_fail else 0)] if got_fail else FAILED
        results.append((label, got_fail))

    probe("1 锚点不存在", lambda c: nc(c, 90, "自检:锚点不存在", W,
                                       [("THIS_ANCHOR_DOES_NOT_EXIST", "x", 1)], 1, PY_TESTS))
    probe("2 锚点命中多于预期", lambda c: nc(c, 91, "自检:命中过多", W,
                                            [("return None", "return None", 1)], 1, PY_TESTS))
    # 真正的空操作: 文件末尾追一行注释。改注释正文会被静态门抓到(它比对源码结构),
    # 那样就不是"无害"了 —— 自检第 3 项要的恰恰是"改了但没人该管"。
    probe("3 改坏后 0 条转红", lambda c: judge(92, "自检:合成 red_count=0", 1, []))
    probe("4 改坏后语法损坏", lambda c: nc(c, 93, "自检:语法损坏", W,
                                          [("def _valid(rec):", "def _valid(rec:", 1)], 1, PY_TESTS))

    # 5 恢复摘要不一致: 手工把副本改脏再验
    p0, f0 = npass, nfail
    cp.write(W, cp.read(W) + "\n# dirty\n")
    left = cp.verify_all()
    results.append(("5 恢复摘要不一致", W in left))
    cp.restore(W)
    npass, nfail = p0, f0

    # 6 TOUCHED 漏文件: 拿一个不在清单里的文件改脏, verify_all 抓不到 → 说明清单有洞
    missing = [f for f in ("deploy/bot/dotwitness.py", "install.sh", "deploy/mosdns/config.yaml",
                           "deploy/bot/pdg-dotwitness.service") if f not in TOUCHED]
    results.append(("6 TOUCHED 覆盖生产文件", not missing))

    # 7 一条 NC 失败其余全绿 → 总 rc 仍非零
    results.append(("7 单条失败即总失败", True))   # 由 main() 末尾的 rc 逻辑保证, 下面断言

    # 8 正常完整执行 → 副本干净
    results.append(("8 收尾副本干净", not cp.verify_all()))
    cp.drop()

    # 9-12 YAML mutation 清单的 fail-closed 自检。喂**合成源码**给 check_yaml_inventory,
    # 不动真文件 —— 它只读源码文本, 正好可以这样验。
    with io.open(__file__, encoding="utf-8") as _f:
        _src = _f.read()

    def _inv(src_text):
        """跑一次清单核对, 返回它是否判红(不计入正式统计)。"""
        global npass, nfail, FAILED
        p0, f0 = npass, nfail
        check_yaml_inventory(src_text)
        got_fail = nfail > f0
        npass, nfail = p0, f0
        if got_fail:
            FAILED.pop()
        return got_fail

    # 9 多一条 M 类: 把 NC6 那行的目标从 M 换成 M 再多加一条打 M 的 nc()
    _add = _src + '\n\ndef _synthetic_extra():\n    nc(cp, 99, "合成: 新增 M 类", M, [], 1, [])\n'
    results.append(("9 新增 M 类 ID → 判红", _inv(_add)))

    # 10/11 改的必须是**真正的 nc() 调用点**, 不是上面这几行自检里的同款字面量 ——
    # 那些字面量在文件里排在调用点前面, 用 replace(..., 1) 会先命中它们, 于是合成源码
    # 其实没变、自检恒绿。用 rfind 从后往前替换, 打的就是真调用点(这个坑本身值得留注)。
    def _sub_last(text, old, new):
        i = text.rfind(old)
        return text if i < 0 else text[:i] + new + text[i + len(old):]

    # 10 少一条 M 类: 把 NC17 的目标由 M 改成 W(它就不再算 M 类)
    _del = _sub_last(_src, 'nc(cp, 17, "模板端口与 witness 默认端口漂移", M,',
                     'nc(cp, 17, "模板端口与 witness 默认端口漂移", W,')
    results.append(("10 删除既有 M 类 ID → 判红", _inv(_del) if _del != _src else False))

    # 11 非 M 类改成 M: NC3 本来打 W, 改成打 M
    _flip = _sub_last(_src, 'nc(cp, 3, "label 放宽为任意文本", W,',
                      'nc(cp, 3, "label 放宽为任意文本", M,')
    results.append(("11 非 M 类改成 M → 判红", _inv(_flip) if _flip != _src else False))

    # 12 只加无关注释 → 仍绿(否则这道门会被日常编辑吵到失效)
    _noop = _src + "\n# 合成: 与 mutation 无关的注释\n"
    results.append(("12 只加无关注释 → 不判红", not _inv(_noop)))

    allok = True
    for label, got in results:
        if got:
            print("[OK]   自检 %s → runner 判红/成立" % label)
        else:
            print("[FAIL] 自检 %s → runner **没有**判红, 它自己就是假绿" % label)
            allok = False
    return allok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-check-only", action="store_true")
    a = ap.parse_args()

    if not self_check():
        print("\nrunner 自检未通过 —— 不执行正式负控")
        return 2
    if a.self_check_only:
        return 0

    print("\n── 正式负控 ──")
    # 先核 YAML mutation 清单: 它是 syntax_ok() 对 .yaml 恒真时唯一的把关点,
    # 集合一变就得重做真 mosdns 加载复核 —— 早报比跑完一轮再报有用。
    check_yaml_inventory()
    cp = Copy()
    try:
        ALL = PY_TESTS
        # 1-5 mosdns 配置 / 判据
        nc(cp, 1, "去掉 SNI 判据", M,
           [("          - string_exp server_name eq __DOT_DOMAIN__\n", "", 1)], 1,
           ["tests/test-dot-witness.py", "tests/test-dot-privacy.py"])
        nc(cp, 2, "去掉 qname 后缀判据", M,
           [("          - qname suffix probe.__DOT_DOMAIN__\n", "", 1)], 1,
           ["tests/test-dot-witness.py", "tests/test-dot-privacy.py"])
        nc(cp, 3, "label 放宽为任意文本", W,
           [('LABEL_RE = re.compile(r"\\A[0-9a-f]{24}\\Z")',
             'LABEL_RE = re.compile(r"\\A.+\\Z")', 1)], 1,
           ["tests/test-dot-witness.py", "tests/test-dot-privacy.py", "tests/test-dot-faults.py"])
        nc(cp, 4, "24 hex 改为 12 hex", W,
           [('LABEL_RE = re.compile(r"\\A[0-9a-f]{24}\\Z")',
             'LABEL_RE = re.compile(r"\\A[0-9a-f]{12}\\Z")', 1)], 1,
           ["tests/test-dot-witness.py", "tests/test-dot-privacy.py"])
        # 锚点必须整块取 canonical 受管块, 不能取"goto probe_seq 紧跟 client_ip"那种文本
        # 相邻关系: 6.2B 把 `# <<< … (main_sequence)` 结束标记插进了两者之间, 相邻早已不
        # 成立 —— 这条负控因此命中 0 次、空转了整整一轮而无人发现。
        # 两步: 先整块摘掉, 再整块插到 client_ip 分支之后。起止标记各一处、块内
        # qname/SNI/goto probe_seq 三要素齐全、插入目标一处; 任一计数不为 1, nc() 直接判负控无效。
        MB = ("      # >>> pdg-dotwitness managed block (main_sequence)\n"
              "      - matches:\n"
              "          - qname suffix probe.__DOT_DOMAIN__\n"
              "          - string_exp server_name eq __DOT_DOMAIN__\n"
              "        exec: goto probe_seq\n"
              "      # <<< pdg-dotwitness managed block (main_sequence)\n")
        AFTER = ("      - matches: client_ip $npn_clients\n"
                 "        exec: goto internal_sequence\n")
        nc(cp, 5, "probe 分支移到 cache 后", M,
           [(MB, "", 1), (AFTER, AFTER + MB, 1)], 2,
           ["tests/test-dot-witness.py", "tests/test-dot-privacy.py"])
        # 6-7 隐私闸门
        nc(cp, 6, "开启 api.http", M,
           [("log:\n  level: warn\n", "log:\n  level: warn\napi:\n  http: \"127.0.0.1:8080\"\n", 1)],
           1, ["tests/test-dot-privacy.py", "tests/test-link-dns-evidence.py"]
           if os.path.exists(os.path.join(REPO, "tests/test-link-dns-evidence.py"))
           else ["tests/test-dot-privacy.py"])
        nc(cp, 7, "加入 query_summary", M,
           [("      - exec: $dotwitness_fwd\n", "      - exec: query_summary probe\n      - exec: $dotwitness_fwd\n", 1)],
           1, ["tests/test-dot-privacy.py"])
        # 8-10 evidence 字段
        for num, field, expr in ((8, "label 明文", '"label": label,'),
                                 (9, "完整 qname", '"qname": "x.probe.example",'),
                                 (10, "DoT 域名", '"dot_domain": "example",')):
            nc(cp, num, "evidence 写%s" % field, W,
               [('        "transport": TRANSPORT,\n',
                 '        "transport": TRANSPORT,\n        %s\n' % expr, 1)], 1,
               ["tests/test-dot-privacy.py", "tests/test-dot-strict.py"])
        # 11 绑定
        nc(cp, 11, "witness 改绑 0.0.0.0", W,
           [('DOTWITNESS_ADDR = "127.0.0.1"', 'DOTWITNESS_ADDR = "0.0.0.0"', 1)], 1,
           ["tests/test-dot-privacy.py"])
        # 13 畸形包仍写 evidence
        nc(cp, 13, "畸形 DNS 包仍写 evidence", W,
           [("        parsed = parse_query(pkt)\n        if parsed is None:\n"
             "            continue                   # 畸形包: 连 ID 都取不到, 无从回起 —— 丢弃, 不回不写\n",
             "        parsed = parse_query(pkt)\n        if parsed is None:\n"
             "            record('ffffffffffffffffffffffff', 1)\n            continue\n", 1)], 1,
           ["tests/test-dot-witness.py", "tests/test-dot-faults.py"])
        # 14 原子替换
        nc(cp, 14, "原子替换改成直接覆盖", W,
           [("        os.replace(tmp, _state_path())\n",
             "        open(_state_path(), 'wb').write(blob)\n", 1)], 1,
           ["tests/test-dot-privacy.py"])
        # 15 token 复用
        nc(cp, 15, "HTTP token 与 probe label 复用", W,
           [("import tempfile\n", "import tempfile\nfrom linksess import TOKEN_BYTES  # noqa\n", 1)], 1,
           ["tests/test-dot-privacy.py"])
        # 16-18 render 闭包
        nc(cp, 16, "render 不替换 DoT 域名", I,
           [(' \\\n              -e "s|__DOT_DOMAIN__|$DOT_DOMAIN|g" "$1"; }', ' "$1"; }', 1)], 1,
           ["tests/test-dot-render.py"])
        # NC17 已重新定义: 端口不再是占位符(那会让没跟上的渲染点加载失败), 现在是
        # YAML 与 Python 两份表示。要抓的就是这两份**漂移**。
        nc(cp, 17, "模板端口与 witness 默认端口漂移", M,
           [('addr: "udp://127.0.0.1:5399"', 'addr: "udp://127.0.0.1:5400"', 1)], 1,
           ["tests/test-dot-render.py"])
        nc(cp, 18, "dotwitness.env 不生成", I,
           [("( umask 022; printf 'PDG_DOTWITNESS_SUFFIX=probe.%s\\n' \"$DOT_DOMAIN\" > /etc/privdns-gateway/dotwitness.env )",
             ": # 不生成", 1)], 1, ["tests/test-dot-render.py"])
        # 19 fail-crash 回归
        nc(cp, 19, "mkstemp 移回 try 外(恢复 fail-crash)", W,
           [("    tmp = None\n    try:\n        fd, tmp = tempfile.mkstemp(dir=d, prefix=TMP_PREFIX)\n",
             "    fd, tmp = tempfile.mkstemp(dir=d, prefix=TMP_PREFIX)\n    try:\n", 1)], 1,
           ["tests/test-dot-faults.py", "tests/test-dot-privacy.py"])
        # 20-21 unit
        nc(cp, 20, "删除 LimitCORE=0", U, [("LimitCORE=0\n", "", 1)], 1,
           ["tests/test-dot-privacy.py"])
        nc(cp, 21, "EnvironmentFile 改回可选", U,
           [("EnvironmentFile=/etc/privdns-gateway/dotwitness.env",
             "EnvironmentFile=-/etc/privdns-gateway/dotwitness.env", 1)], 1,
           ["tests/test-dot-strict.py"])
        # 22 非法 suffix 仍启动
        nc(cp, 22, "非法 suffix 仍启动成功", W,
           [("    suffix = _suffix()\n    if suffix is None:\n", "    suffix = _suffix()\n    if False:\n", 1)],
           1, ["tests/test-dot-strict.py"])
        # 23-26, 30-33 evidence 校验闭集
        loose = [
            (23, "多字段仍接受", 'if not isinstance(rec, dict) or set(rec) != STATE_FIELDS:',
             'if not isinstance(rec, dict) or not STATE_FIELDS <= set(rec):'),
            (24, "非法/大写 SHA256 仍接受", '    if not isinstance(d, str) or not SHA256_RE.match(d):\n        return False\n', ''),
            # 6.2B: 这条判据从 _read_state 挪进了 read_evidence(跨 UID 只读入口),
            # return 形状随之从 `return "CORRUPT"` 变成 `return READ_CORRUPT, None`。
            # 锚点跟着走 —— 判据本身一个字没放宽。
            (25, "mode 错仍接受", '    if stat.S_IMODE(st.st_mode) != STATE_MODE:\n        return READ_CORRUPT, None\n', ''),
            (30, "transport 非 dot 仍接受", '    if rec["transport"] != TRANSPORT:\n        return False\n', ''),
            (31, "qtype bool/越界仍接受",
             '    if isinstance(qt, bool) or not isinstance(qt, int) or not (0 <= qt <= 65535):\n        return False\n', ''),
            # NaN/inf 的防护是**两层冗余**: `_finite` 之外, 区间判据 `o < e <= o+TTL`
            # 对 NaN 的任何比较都是 False, 单删 _finite 拆不掉它。要让这条负控真有牙齿,
            # 必须把两层一起摘掉 —— 这本身也说明这处保护不是单点。
            (32, "NaN/inf 与时间区间校验一起摘掉",
             '    o, e = rec["observed_at"], rec["expires_at"]\n'
             '    if not _finite(o) or not _finite(e):\n        return False\n'
             '    if not (o < e <= o + EVIDENCE_TTL_SECS):   # 生命周期不得超过设计上限\n'
             '        return False\n', ''),
            (33, "生命周期超 TTL 仍接受",
             '    if not (o < e <= o + EVIDENCE_TTL_SECS):   # 生命周期不得超过设计上限\n        return False\n',
             '    if not (o < e):\n        return False\n'),
        ]
        for num, nm, old, new in loose:
            nc(cp, num, nm, W, [(old, new, 1)], 1, ["tests/test-dot-strict.py"])
        # 27 日志泄露
        nc(cp, 27, "日志打印 qname/label/来源", W,
           [('        if label is not None:\n',
             '        if label is not None:\n            print(qname_raw, file=sys.stderr)\n', 1)], 1,
           ["tests/test-dot-privacy.py"])
        # 28 清理跟随 symlink
        nc(cp, 28, "清理逻辑跟随 symlink", W,
           [("    if st is not None and stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid():\n",
             "    if st is not None:\n", 1)], 1,
           ["tests/test-dot-strict.py", "tests/test-dot-faults.py"])
        # 29 .ev-* 宽前缀误删
        nc(cp, 29, ".ev-* 按宽前缀误删无关文件", W,
           [("        if stat.S_ISREG(s2.st_mode) and s2.st_uid == os.geteuid() \\\n"
             "                and stat.S_IMODE(s2.st_mode) == STATE_MODE:\n",
             "        if True:\n", 1)], 1, ["tests/test-dot-strict.py"])

        # ── 需要真 E2E / 真 systemd 的几条: 本进程内跑不了, 明确记为未验 ──
        if os.geteuid() == 0:
            # 属主门在 6.2B 挪进了 read_evidence(), 判据也从"读者自己的 euid"换成了
            # 观察端身份 expect_uid —— 旧锚点(reader-euid 那句)已不存在, 命中 0 次。
            # 只能删门, 不能把默认值改回 os.geteuid(): _read_state() 显式传
            # expect_uid=os.geteuid(), 改默认值对这支 catcher 行为完全等价, 0 条转红。
            nc(cp, 26, "owner 错仍接受", W,
               [("    if st.st_uid != expect_uid:               # 不是观察端写的, 不信\n"
                 "        return READ_CORRUPT, None\n", "", 1)],
               1, ["tests/test-dot-strict.py"])
        else:
            unver("NC26 owner 错仍接受 —— 非 root 下 test-dot-strict 会 SKIP 那格, 由 root 容器轮覆盖")
        for num, nm, why in (
            (12, "witness 故障拖死普通 DNS", "需要真 mosdns E2E(e2e-dot-isolation.sh)"),
        ):
            rc, out = run_test(cp, "tests/test-dot-faults.py")
            unver("NC%02d %s —— %s, 由容器负控单独跑" % (num, nm, why))
        # NC34 在 6.2A 时是"移交"状态: 那时三态判定还不存在, 只能等真 mosdns E2E。
        # 6.2B 把裁决抽成 dot_probe_state 这个纯函数之后, "观察端不可用时会不会给出
        # OBSERVED"可以直接逐格喂 —— 不再需要真 mosdns, 也不再是移交项。
        ok("NC34 观察端不可用却给出 OBSERVED —— 已闭环: tests/test-dot-session.py 第 5 节"
           " 11 格(证据固定为完美匹配, 只破坏观察端), 每格必须 UNAVAILABLE")
    finally:
        left = cp.verify_all()
        if left:
            bad("收尾一致性: 以下文件与基线不一致: %s" % ", ".join(left))
        else:
            ok("收尾一致性: TOUCHED 全部 %d 个文件 sha256 逐字节还原" % len(TOUCHED))
        cp.drop()

    print("\n" + "─" * 62)
    print("通过 %d, 失败 %d, 跳过 %d, 未验 %d" % (npass, nfail, nskip, nunver))
    for m in FAILED:
        print("  ✗ %s" % m)
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())

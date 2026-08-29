#!/usr/bin/env python3
"""负控: mosdns 单次取件 + artifact 扇出这套判据有没有牙。

被盯的是三个文件 —— .github/workflows/ci.yml 的 producer/consumer 拓扑、
tests/install-mosdns-artifact.sh 的消费者四层复核、tests/mosdns-artifact-name.sh 的
名字生成。这一支回答: **如果它们退化了, 我们会不会知道?**

做法与本目录其它负控一致: 逐格把代码改坏(只改沙箱副本, 正式树一个字节不动), 再跑两支
聚焦测试, 看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本, 必须全绿。

每格五步, 缺一不算有效: 锚点恰好命中 / YAML 真解析仍过 / 失败集合有具名新增 /
反向对照零新增 / 正式树 sha256 与 mode 逐字节恢复。

十格:
  ① 给一个 E2E consumer 恢复直接官方下载
  ② 消费者加回"下不到就 curl"的联网回退
  ③ 摘掉消费者的 SHA 校验
  ④ 摘掉消费者的版本校验
  ⑤ 摘掉 needs
  ⑥ artifact 名去掉摘要段
  ⑦ producer 不再调生产判据
  ⑧ 改用 actions/cache
  ⑨ action 改成浮动引用 @main
  ⑩ 只加无关注释(反向对照)
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
CI = ".github/workflows/ci.yml"
INS = "tests/install-mosdns-artifact.sh"
NAM = "tests/mosdns-artifact-name.sh"
TOUCHED = [ROOT / f for f in (CI, INS, NAM)]

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
    # errors="replace": 被测脚本可能吐出非 UTF-8 字节(比如 `cut -c` 把一个中文字符切成半个),
    # 而负控在这里崩掉的话, 后面每一格都不会跑 —— 那是最难查的一种"负控自己坏了"。
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, errors="replace")


def failures(out):
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{7,64}\b", "H", t)
        s.add(t)
    return s


T_TOPO = [sys.executable, "tests/test-ci-mosdns-topology.py"]
T_TRIP = ["bash", "tests/test-mosdns-artifact-roundtrip.sh"]


def suite(wd, cmds):
    out = ""
    for c in cmds:
        out += (lambda r: r.stdout + r.stderr)(run(c, cwd=wd))
    return failures(out)


CONSUMER_DL = '''      - uses: actions/download-artifact@v4
        with:
          name: ${{ env.MOSDNS_ARTIFACT }}
          path: /tmp/mosdns-fixture
'''
MUT = [
    ("① consumer 恢复直接官方下载", CI,
     [(CONSUMER_DL,
       '      - name: "直接下载"\n        run: |\n'
       '          curl -fsSL -o /tmp/m.zip '
       '"https://github.com/IrineSistiana/mosdns/releases/download/v5.3.4/mosdns-linux-amd64.zip"\n', 7)],
     [T_TOPO]),
    ("② 消费者加回联网 fallback", INS,
     [('[[ -f "$BIN" ]] || die "artifact 里没有 mosdns($BIN)"',
       '[[ -f "$BIN" ]] || curl -fsSL -o "$BIN" '
       '"https://github.com/IrineSistiana/mosdns/releases/download/$MOSDNS_VER/x.zip"', 1)],
     [T_TOPO, T_TRIP]),
    ("③ 摘掉消费者 SHA 校验", INS,
     [('[[ "$got_sha" == "$want_sha" ]] \\\n  || die', 'true \\\n  || die', 1)], [T_TRIP]),
    ("④ 摘掉消费者版本校验", INS,
     [('[[ "v${got_ver:-}" == "$MOSDNS_VER" ]] \\\n  || die', 'true \\\n  || die', 1)],
     [T_TOPO, T_TRIP]),
    ("⑤ 摘掉 needs", CI,
     [("    needs: prepare-mosdns-fixture\n", "", 7)], [T_TOPO]),
    ("⑥ artifact 名去掉摘要段", NAM,
     [("printf 'mosdns-%s-%s-%s\\n' \"$MOSDNS_VER\" \"$arch\" \"${sha:0:12}\"",
       "printf 'mosdns-%s-%s\\n' \"$MOSDNS_VER\" \"$arch\"", 1)], [T_TRIP]),
    ("⑦ producer 不再调生产判据", CI,
     [('          pdg_mosdns_binary_ok "$ARCH" "$MOSDNS_VER" "$PWD/artifact/mosdns"\n', "", 1)],
     [T_TOPO]),
    ("⑧ 改用 actions/cache", CI,
     [("      - uses: actions/upload-artifact@v4\n",
       "      - uses: actions/cache@v4\n", 1)], [T_TOPO]),
    ("⑨ action 改成浮动引用", CI,
     [("      - uses: actions/download-artifact@v4\n",
       "      - uses: actions/download-artifact@main\n", 7)], [T_TOPO]),
    ("⑩ 只加一行无关注释(反向对照)", INS,
     [("die(){ echo", "# (负控的空转对照, 不改变任何行为)\ndie(){ echo", 1)], [T_TOPO, T_TRIP]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-artifact-negctl.")
try:
    for sub in ("tests", "lib", "deploy"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    os.makedirs(Path(wd) / ".github/workflows", exist_ok=True)
    shutil.copy2(ROOT / CI, Path(wd) / CI)
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8") for rel in (CI, INS, NAM)}

    print("══ 基线(未改坏的同一份副本)══")
    base = set()
    for tag, cmds in (("topo", [T_TOPO]), ("trip", [T_TRIP])):
        f = suite(wd, cmds)
        (ok if not f else bad)("基线 %s 全绿(失败 %d)" % (tag, len(f)))
        base |= f
    if base:
        bad("基线不绿 —— 后面每一格的「新增」都算不出来")
        for x in sorted(base)[:4]:
            print("       %s" % x[:150])

    for tag, rel, edits, cmds in MUT:
        print()
        print("── %s ──" % tag)
        text = pristine[rel]
        good = True
        for anchor, repl, want in edits:
            hits = text.count(anchor)
            print("   锚点命中 %d 次(期望 %d)" % (hits, want))
            if hits != want:
                bad("%s: 锚点命中 %d 次, 期望 %d —— 产品换写法了, 这一格没测到东西"
                    % (tag, hits, want))
                good = False
                break
            text = text.replace(anchor, repl, want)
        if not good:
            continue
        (Path(wd) / rel).write_text(text, encoding="utf-8")
        # YAML / bash 语法门: 改坏后必须仍能解析, 否则红的是语法不是判据
        if rel.endswith(".yml"):
            try:
                import yaml
                yaml.safe_load((Path(wd) / rel).read_text(encoding="utf-8"))
                print("   YAML 真解析: 过")
            except Exception as e:                                   # noqa: BLE001
                bad("%s: 改坏后 YAML 解析不了(%s)" % (tag, str(e)[:80]))
                (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
                continue
        else:
            r = run(["bash", "-n", rel], cwd=wd)
            print("   bash -n: %s" % ("过" if r.returncode == 0 else "不过"))
            if r.returncode != 0:
                bad("%s: 改坏后 bash -n 不过" % tag)
                (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
                continue
        got = set()
        for c in cmds:
            got |= suite(wd, [c])
        newf = got - base
        if tag.startswith("⑩"):
            (ok if not newf else
             bad)("反向对照: 无关注释新增失败 %d 条(应为 0)%s"
                  % (len(newf), (" —— " + "; ".join(sorted(newf))[:150]) if newf else ""))
        else:
            (ok if newf else
             bad)("%s → 新增具名失败 %d 条%s"
                  % (tag, len(newf), (": " + sorted(newf)[0][:105]) if newf else " —— 0 条转红, 这一格无效"))
        (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
finally:
    shutil.rmtree(wd, ignore_errors=True)

print()
print("══ 正式树逐字节恢复 ══")
for p in TOUCHED:
    (ok if sha(p) == before[p] else bad)("%s sha256 未变" % Path(p).name)
    (ok if os.stat(p).st_mode == modes[p] else bad)("%s mode 未变" % Path(p).name)

print("-" * 62)
print("mosdns-artifact-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

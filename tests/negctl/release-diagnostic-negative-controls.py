#!/usr/bin/env python3
"""负控:发布安全与诊断诚实性这几条判据有没有牙。

被盯的是四个生产文件 —— pdg.sh 的更新方向判据与去广告只读状态、checks.py 的 mosdns 证据、
lib/versions.sh 的二进制钉值、install.sh 的安装短路。这一支回答的是另一个问题:
**如果它们退化了, 我们会不会知道?**

做法与本目录其它负控一致: 逐格把生产代码改坏(只改沙箱副本, 正式树一个字节不动), 再跑
对应的聚焦测试, 看具名失败集合相对基线有没有新增。基线 = 未改坏的同一份副本, 必须全绿。

每格五步, 缺一不算有效:
  · 锚点在整份文件里**恰好命中**预期次数;
  · 替换确实落进了文件;
  · 改坏后语法门仍过(bash -n / py_compile)—— 语法错造成的红不算"判据抓住了";
  · 失败集合有**具名新增**(0 条转红 = 这一格无效, 判 FAIL);
  · 恢复后正式树 sha256 与 before-image 逐字节一致。

十四格:
  ① 摘掉"当前领先"硬门          —— 未发布提交会被静默退回上一个 Release
  ② 祖先方向写反                —— 正常升级会被误判成降级而拒绝
  ③ 分叉被当成可以更新          —— reset 打在一条没人要的方向上
  ④ dry-run 退回旧的空区间文案  —— 屏幕上只剩标题, 读起来正好是"已是最新"
  ⑤ mosdns 判据不看退出码       —— 崩溃前打印的版本号被当成成功证据
  ⑥ mosdns 判据跟着 PATH 走     —— 报的不是 systemd 在跑的那个文件
  ⑦ 二进制判据永远说一致        —— 同版本换内容不再有人管
  ⑧ 二进制钉值被改坏            —— 钉值本身要有守卫
  ⑨ 安装短路改回只看自报版本    —— 跳过下载 = 跳过供应链校验
  ⑩ 去广告 unknown 折回 disabled —— 权限问题被显示成"这台机器没开"
  ⑪ 缺规则文件仍显示 0 条       —— 证据缺失被说成一个事实
  ⑫ 自定义计数恒 0(假牙那一格)  —— 子串断言抓不到, 具名断言必须抓到
  ⑬ 只加无关注释                —— 反向对照, 不该有任何新失败
  ⑭ 行为探针(不改代码): PATH 前面搁假 mosdns / ZIP 对但二进制不对必须拒装
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
VER = "lib/versions.sh"
INS = "install.sh"
TOUCHED = [ROOT / PDG, ROOT / CHK, ROOT / VER, ROOT / INS]

PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def run(cmd, cwd=None, timeout=900, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, env=env)


def failures(out):
    """具名失败集合, 归一化掉临时目录 / 哈希 / 大数。"""
    s = set()
    for line in out.splitlines():
        if not line.startswith("[FAIL]"):
            continue
        t = re.sub(r"/tmp/[^\s,)\]]+", "/tmp/X", line.strip())
        t = re.sub(r"\b[0-9a-f]{12,64}\b", "H", t)
        t = re.sub(r"\b\d{4,}\b", "N", t)
        s.add(t)
    return s


T_REL = ["bash", "tests/test-update-release-relation.sh"]
T_MOS = ["python3", "tests/test-mosdns-binary-evidence.py"]
T_TRI = ["python3", "tests/test-adblock-status-tristate.py"]
T_LINE = ["python3", "tests/test-status-adblock-line.py"]


def suite(wd, cmds):
    out = ""
    for c in cmds:
        r = run(c, cwd=wd)
        out += r.stdout + r.stderr
    return failures(out)


# 每格 = (标签, 文件, [(锚点, 替换, 预期命中数)], 跑哪几支)
MUT = [
    ("① 摘掉「当前领先」硬门", PDG,
     [("        ahead)\n", "        __never_ahead__)\n", 1)], [T_REL]),
    ("② 祖先方向写反", PDG,
     [("    0) printf 'behind\\n'; return 0;;", "    0) printf 'ahead\\n'; return 0;;", 1)], [T_REL]),
    ("③ 分叉被当成可以更新", PDG,
     [("    1) printf 'diverged\\n'; return 0;;", "    1) printf 'behind\\n'; return 0;;", 1)], [T_REL]),
    ("④ dry-run 退回旧的空区间文案", PDG,
     [('      ahead)  c_y "当前跑的是**尚未发布**的提交, 领先 $tgt',
       '      ahead)  echo "待更新提交(HEAD..$tgt):"; c_y "领并 $tgt', 1)], [T_REL]),
    ("⑤ mosdns 判据不看退出码", CHK,
     [('    if rc != 0:\n        return ("warn", name,\n'
       '                "%s version 退出码非 0(rc=%s)',
       '    if False:\n        return ("warn", name,\n'
       '                "%s version 退出码非 0(rc=%s)', 1)],
     [T_MOS]),
    ("⑥ mosdns 判据跟着 PATH 走", CHK,
     [('rc, out, err = _run([MOSDNS_BIN, "version"])', 'rc, out, err = _run(["mosdns", "version"])', 1)],
     [T_MOS]),
    ("⑦ 二进制判据永远说一致", CHK,
     [("    if got == pin:\n", "    if True:\n", 1)], [T_MOS]),
    ("⑧ 二进制钉值被改坏", VER,
     [("  [mosdns-bin-amd64]=\"", "  [mosdns-bin-amd64]=\"0", 1)], [T_MOS]),
    ("⑨ 安装短路改回只看自报版本", INS,
     [('if ! pdg_mosdns_binary_ok "$MARCH" "$MOSDNS_VER" /usr/local/bin/mosdns; then',
       'if ! pdg_mosdns_is_version "$MOSDNS_VER"; then', 1)], [T_MOS]),
    ("⑩ 去广告 unknown 折回 disabled", PDG,
     [("    *) printf 'unknown';;\n  esac\n}", "    *) printf 'disabled';;\n  esac\n}", 1)], [T_TRI]),
    ("⑪ 缺规则文件仍显示 0 条", PDG,
     [("  if ! _adb_rules_readable \"$ADB_STATE_DIR/effective_list.txt\" \\\n"
       "     || ! _adb_rules_readable \"$ADB_USER_BLOCK\"; then",
       "  if false; then", 1)], [T_TRI]),
    ("⑫ 自定义计数恒 0(假牙那一格)", PDG,
     [('  usr="$(_adb_count_rules "$ADB_USER_BLOCK")"', "  usr=0", 1)], [T_LINE]),
    ("⑬ 只加一行无关注释(反向对照)", PDG,
     [("_adb_rules_readable(){", "# (负控的空转对照, 不改变任何行为)\n_adb_rules_readable(){", 1)],
     [T_REL, T_TRI, T_LINE]),
]

before = {p: sha(p) for p in TOUCHED}
modes = {p: os.stat(p).st_mode for p in TOUCHED}

wd = tmpguard.mkdtemp(prefix="pdg-relsafe-negctl.")
try:
    for sub in ("tests", "deploy", "lib"):
        shutil.copytree(ROOT / sub, Path(wd) / sub, dirs_exist_ok=True,
                        symlinks=True, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT / INS, Path(wd) / INS)
    pristine = {rel: (Path(wd) / rel).read_text(encoding="utf-8")
                for rel in (PDG, CHK, VER, INS)}

    print("══ 基线(未改坏的同一份副本)══")
    base = {}
    for tag, cmds in (("rel", [T_REL]), ("mos", [T_MOS]), ("tri", [T_TRI]), ("line", [T_LINE])):
        base[tag] = suite(wd, cmds)
        (ok if not base[tag] else bad)("基线 %s 全绿(失败 %d)" % (tag, len(base[tag])))
    base_all = set().union(*base.values())
    if base_all:
        bad("基线不绿 —— 后面每一格的「新增」都算不出来, 本轮负控结果不可信")

    for tag, rel, edits, cmds in MUT:
        print()
        print("── %s ──" % tag)
        text = pristine[rel]
        good = True
        for anchor, repl, want in edits:
            hits = text.count(anchor)
            if hits != want:
                bad("%s: 锚点命中 %d 次, 期望 %d —— 产品换写法了, 这一格没测到东西"
                    % (tag, hits, want))
                good = False
                break
            text = text.replace(anchor, repl, want)
        if not good:
            continue
        (Path(wd) / rel).write_text(text, encoding="utf-8")
        if (Path(wd) / rel).read_text(encoding="utf-8") == pristine[rel]:
            bad("%s: 替换没落进文件" % tag)
            (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
            continue
        syn = (run(["bash", "-n", rel], cwd=wd) if rel.endswith(".sh")
               else run(["python3", "-m", "py_compile", rel], cwd=wd))
        if syn.returncode != 0:
            bad("%s: 改坏后语法门不过 —— 语法错造成的红不算判据抓住了(%s)"
                % (tag, (syn.stderr or "").strip()[:120]))
            (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")
            continue
        got = set()
        for c in cmds:
            got |= suite(wd, [c])
        newf = got - base_all
        if tag.startswith("⑬"):
            (ok if not newf else
             bad)("反向对照: 无关注释新增失败 %d 条(应为 0)%s"
                  % (len(newf), (" —— " + "; ".join(sorted(newf))[:160]) if newf else ""))
        else:
            (ok if newf else
             bad)("%s → 新增具名失败 %d 条%s"
                  % (tag, len(newf), (": " + sorted(newf)[0][:110]) if newf else " —— 0 条转红, 这一格无效"))
        (Path(wd) / rel).write_text(pristine[rel], encoding="utf-8")

    # ── ⑭ 行为探针: 不改代码, 直接问产品 ──────────────────────────────────
    print()
    print("── ⑭ 行为探针 ──")
    # (a) PATH 最前面搁一个假 mosdns: 判据必须仍然去问 /usr/local/bin/mosdns
    sb = Path(wd) / "fakebin"
    sb.mkdir(exist_ok=True)
    (sb / "mosdns").write_text('#!/bin/sh\necho "mosdns v0.0.1-fake"\n')
    os.chmod(sb / "mosdns", 0o755)
    probe = (
        "import sys, os; sys.path.insert(0, %r)\n"
        "import checks\n"
        "seen = []\n"
        "orig = checks._run\n"
        "def f(cmd, *a, **k):\n"
        "    seen.append(cmd[0]); return (0, 'mosdns v0.0.1-fake\\n', '')\n"
        "checks._run = f\n"
        "checks.check_mosdns_version()\n"
        "print(seen[0])\n" % str(Path(wd) / "deploy/bot"))
    env = dict(os.environ, PATH="%s:%s" % (sb, os.environ.get("PATH", "")),
               PDG_REPO_ROOT=str(wd))
    r = run(["python3", "-c", probe], cwd=wd, env=env)
    called = (r.stdout or "").strip()
    (ok if called == "/usr/local/bin/mosdns" else
     bad)("PATH 前面搁假 mosdns, 判据仍问 /usr/local/bin/mosdns(实得 %r)" % called)

    # (b) ZIP 摘要对、解压出来的二进制不对 → 必须拒装
    # 抽出 install.sh 的 mosdns 段, 把外部副作用全打桩, 用一个"ZIP 哈希对得上、
    # 但解压出来的内容是别的"的现场喂它。
    seg = re.search(r"# ── 2\. mosdns ──.*?(?=# ── 3\.)",
                    (Path(wd) / INS).read_text(encoding="utf-8"), re.S)
    if not seg:
        bad("抽不到 install.sh 的 mosdns 安装段 —— 这一格没测到东西")
    else:
        box = Path(wd) / "instbox"
        shutil.rmtree(box, ignore_errors=True)
        box.mkdir()
        (box / "seg.sh").write_text(seg.group(0), encoding="utf-8")
        zip_sha = hashlib.sha256(b"the-archive").hexdigest()

        def drive(bin_sha_matches):
            """跑一次安装段。bin_sha_matches=False 表示「ZIP 对、落盘二进制不对」。"""
            wrong = "0" * 64
            # 拒装那条路会 `rm -rf "$t"` 清掉临时目录, 而 $t 正是这个沙箱(mktemp 被打桩成
            # 它)。所以每次都重建, 否则第二次调用连驱动脚本都写不进去。
            shutil.rmtree(box, ignore_errors=True)
            box.mkdir(parents=True)
            (box / "seg.sh").write_text(seg.group(0), encoding="utf-8")
            drv = f'''
set -uo pipefail
source "{wd}/lib/versions.sh"
MARCH=amd64
PDG_SHA256[mosdns-amd64]="{zip_sha}"
BIN_PIN="${{PDG_SHA256[mosdns-bin-amd64]}}"
c_g(){{ echo "$*"; }}
die(){{ echo "DIE: $*"; exit 9; }}
_stash_bin(){{ return 0; }}
curl(){{ printf 'the-archive' > "{box}/m.zip"; return 0; }}
mktemp(){{ echo "{box}"; }}
unzip(){{ printf 'x' > "{box}/mosdns"; return 0; }}
install(){{ return 0; }}
pdg_mosdns_binary_ok(){{ return 1; }}   # 强制进入下载分支
# 关键: 探针不能去核**本机真实的** /usr/local/bin/mosdns —— 这台机器上它恰好就是官方
# 原版, 于是那一步永远通过, 而这一格本来要测的正是它不通过时会怎样。
sha256sum(){{
  case "$1" in
    *m.zip)               echo "{zip_sha}  $1";;
    /usr/local/bin/mosdns) echo "{{BINSHA}}  $1";;
    *)                    command sha256sum "$@";;
  esac
}}
cd "{box}"
source "{box}/seg.sh"
echo "REACHED-END"
'''
            drv = drv.replace("{BINSHA}", "$BIN_PIN" if bin_sha_matches else wrong)
            (box / "drv.sh").write_text(drv, encoding="utf-8")
            return run(["bash", str(box / "drv.sh")], cwd=str(box))

        rr = drive(False)
        outs = (rr.stdout or "") + (rr.stderr or "")
        refused = ("DIE:" in outs) and ("REACHED-END" not in outs)
        (ok if refused else
         bad)("ZIP 摘要对但落盘二进制不对 → 拒装(rc=%s, 输出 %r)"
              % (rr.returncode, outs.strip()[:180]))
        # 反向对照: 两个摘要都对时必须走完, 否则上面那格的红说明不了任何事
        rr2 = drive(True)
        outs2 = (rr2.stdout or "") + (rr2.stderr or "")
        (ok if "REACHED-END" in outs2 and "DIE:" not in outs2 else
         bad)("反向对照: 两个摘要都对时应装完(rc=%s, 输出 %r)"
              % (rr2.returncode, outs2.strip()[:180]))
finally:
    shutil.rmtree(wd, ignore_errors=True)

print()
print("══ 正式树逐字节恢复 ══")
for p in TOUCHED:
    same = sha(p) == before[p]
    (ok if same else bad)("%s sha256 未变" % Path(p).name)
    (ok if os.stat(p).st_mode == modes[p] else bad)("%s mode 未变" % Path(p).name)

print("-" * 62)
print("release-diagnostic-negative-controls.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

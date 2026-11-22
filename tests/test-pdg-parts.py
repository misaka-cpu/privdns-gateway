#!/usr/bin/env python3
"""pdg.sh 拆分段的守门(建议 4): 结构 + "只搬不改"。

§1 结构(看工作树): 入口里的 `# @pdg-part <段>` 与 lib/pdg/*.sh 一一对应; 每个标记后面紧跟固定的 3 行载入语句
   (拼得回就说明是); 段文件第一行是 `# shellcheck shell=bash`、里面没有标记; 拼回的整份过 bash -n;
   每个段都在下面的 STEPS 里登记过。
§2 只搬不改(看历史, 不看 HEAD): 对每个登记的段, 找出引入 lib/pdg/<段>.sh 的提交 A 与它的父提交 B,
   用 git 对象拼出 A 的整份, 去掉这一步登记的新增代码后, 必须与 B 拼出的整份逐字节相同; 而且 A 相对 B
   改动的生产文件只能是登记的那几个。比的是历史事实, 以后再改这些段不会让它失效。
   还没提交时(本机开发)比工作树与 HEAD。取不到历史(不是 git 仓库 / 浅克隆缺父提交)判失败, 不跳过。
§3 判据自己的负控(不碰 git): 合成一对"上一版 / 这一版", 先验判据放行正确的搬移, 再验段里少一行、入口别处改字、
   载入语句写错、新增代码没登记或出现两次、顺手改了别的生产文件, 每一种都被拦下。
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import pdg_source  # noqa: E402

PROD = ("deploy/", "lib/", "install.sh", "uninstall.sh", "tools/")

# 每拆一段登记一项: 这一步额外加进入口的代码(原文写死, 拼回的整份里必须恰好出现一次), 以及这一步允许改动的生产文件。
# 第一步(adblock)额外加的是载入器本身: _PDG_PART_DIR / _pdg_part / _pdg_part_missing, 插在 _pdg_entry_libdir 之后。
ADBLOCK_LOADER = r'''
# 拆出去的段(lib/pdg/<段>.sh, 建议 4)在哪。已安装的 CLI 读运行模块表装的那一份(lib/modules.sh,
# 与入口一起进快照); 在一棵树里运行的入口(仓库检出 / docs/BRIDGE-ENTRY.md 的入口副本 /
# git archive 出的快照)读同一棵树里的那一份。别的形态认不出配套的是哪一份, 一律拒绝: 不猜,
# 也不回退到 $REPO_DIR。段在入口里原来的位置载入(各处 `# @pdg-part` 那 4 行), 载入顺序与拆分前
# 一样; 而且必须在顶层载入 —— 在函数里 source, 段里的 declare 会变成局部变量。
_PDG_PART_DIR="/opt/pdg-bot"
_pdg_part(){
  local n="$1" src p=""
  src="$(_pdg_entry_src)"
  if [[ "$src" == "$_PDG_INSTALLED_CLI" ]]; then p="$_PDG_PART_DIR/pdg-$n.sh"
  elif [[ "$src" == /*/deploy/bot/pdg.sh ]]; then p="${src%/deploy/bot/pdg.sh}/lib/pdg/$n.sh"
  fi
  if [[ -n "$p" && -f "$p" && -r "$p" && -s "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  _pdg_part_missing "$n" "$src" "$p"
  return 1
}
# 缺段时说清楚缺的是哪一段、在哪找的、怎么补。这时 pdg 的任何子命令都跑不起来(update / rollback
# 也一样, 覆盖重装也要先跑 pdg snapshot), 所以给的修补办法必须不依赖 pdg 本身。
_pdg_part_missing(){
  local n="$1" src="$2" p="$3" why="不存在"
  if [[ -n "$p" && -e "$p" ]]; then
    if [[ ! -r "$p" ]]; then why="读不了"; elif [[ ! -s "$p" ]]; then why="是空文件"; else why="不是普通文件"; fi
  fi
  {
    echo "❌ pdg 缺少拆出去的一段「$n」, 不能运行。"
    if [[ "$src" == "$_PDG_INSTALLED_CLI" ]]; then
      echo "   入口: $src; 应该在: $p($why)"
      echo "   这时 pdg update、pdg rollback、覆盖重装都跑不起来(它们都要先运行 pdg)。先手工补上:"
      echo "     sudo install -m644 $REPO_DIR/lib/pdg/$n.sh $p"
      echo "   补完跑 sudo pdg doctor, 看「安装清单」那一项: 受管仓库与现役入口不是同一版时它会报不一致。"
    elif [[ -n "$p" ]]; then
      echo "   入口: $src; 应该在同一棵树里: $p($why)。这棵树不完整, 换一份完整的检出再运行。"
    else
      echo "   入口: $src —— 既不是已安装的 $_PDG_INSTALLED_CLI, 也不在 <仓库>/deploy/bot/ 下, 认不出配套的段在哪。"
      echo "   pdg.sh 从这一版起不能单独拷到别处运行: 装机用 install.sh, 升级用 sudo pdg update。"
    fi
  } >&2
}
'''
STEPS = {
    "adblock": {"extra": ADBLOCK_LOADER,
                "allow": {"deploy/bot/pdg.sh", "lib/pdg/adblock.sh", "lib/modules.sh"}},
}

PASS = [0]
FAIL = [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   " + m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] " + m)


def first_diff(a, b):
    la, lb = a.split("\n"), b.split("\n")
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return i + 1
    return min(len(la), len(lb)) + 1


def check_move(entry_a, read_a, entry_b, read_b, extra, changed, allow):
    """这一版(A)相对上一版(B)是不是只搬不改。返回问题列表, 空 = 通过。"""
    try:
        got = pdg_source.render_text(entry_a, read_a)
    except (ValueError, OSError, KeyError) as e:
        return ["这一版拼不回: %s" % e]
    if got is None:
        return ["这一版的入口里没有拆分标记"]
    try:
        want = pdg_source.render_text(entry_b, read_b)
    except (ValueError, OSError, KeyError) as e:
        return ["上一版拼不回: %s" % e]
    if want is None:
        want = entry_b
    probs = []
    if extra:
        c = got.count(extra)
        if c != 1:
            probs.append("登记的新增代码在拼回的整份里出现 %d 次(应恰好 1 次)" % c)
        else:
            got = got.replace(extra, "", 1)
    if got != want:
        probs.append("去掉登记的新增代码后与上一版不同, 第一处差异在第 %d 行" % first_diff(got, want))
    other = sorted(p for p in changed if p.startswith(PROD) and p not in allow)
    if other:
        probs.append("这一步还改了别的生产文件: %s" % other[:6])
    return probs


def git(*args):
    p = subprocess.run(["git", "-C", str(ROOT)] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


def show(rev, rel):
    rc, out, err = git("show", "%s:%s" % (rev, rel))
    if rc != 0:
        raise FileNotFoundError("%s:%s 取不到(%s)" % (rev, rel, err.strip()[:80]))
    return out


def part_reader_git(rev):
    return lambda n: show(rev, "lib/pdg/%s.sh" % n)


def part_reader_tree(n):
    p = ROOT / "lib" / "pdg" / (n + ".sh")
    if not p.is_file():
        raise FileNotFoundError(str(p))
    return p.read_text(encoding="utf-8")


def main():
    entry = (ROOT / "deploy" / "bot" / "pdg.sh").read_text(encoding="utf-8")
    names = pdg_source.markers(entry)
    pdir = ROOT / "lib" / "pdg"
    files = sorted(p.stem for p in pdir.glob("*.sh")) if pdir.is_dir() else []

    print("── 1. 结构(工作树) ──")
    if not names and not files:
        ok("还没有拆出去的段: 入口里没有标记, lib/pdg/ 下也没有段文件")
    else:
        (ok if len(names) == len(set(names)) else bad)("每个段在入口里只标记一次(实得 %s)" % names)
        (ok if sorted(set(names)) == files else bad)("入口里的标记与 lib/pdg/*.sh 一一对应(标记 %s, 文件 %s)" % (sorted(set(names)), files))
        for n in files:
            t = (pdir / (n + ".sh")).read_text(encoding="utf-8")
            (ok if t.startswith(pdg_source.PART_HEADER + "\n") else bad)("lib/pdg/%s.sh 第一行是 %s" % (n, pdg_source.PART_HEADER))
            (ok if not pdg_source.markers(t) else bad)("lib/pdg/%s.sh 里没有拆分标记" % n)
        for n in names:
            (ok if n in STEPS else bad)("段「%s」在本测试的 STEPS 里登记过(新拆的段必须登记它那一步的新增代码)" % n)
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").split("\n")
        k = next((i for i, l in enumerate(ci) if "shellcheck --severity=warning" in l), None)
        scope = ci[k + 1].split() if k is not None and k + 1 < len(ci) else []
        (ok if "lib/pdg/*.sh" in scope else bad)("CI 的 ShellCheck 范围里有 lib/pdg/*.sh(范围行: %s)" % " ".join(scope)[:100])
        try:
            p = pdg_source.path(ROOT)
            ok("拼得回: 每个标记后面都是固定的 3 行载入语句")
            r = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
            (ok if r.returncode == 0 else bad)("拼回的整份过 bash -n %s" % r.stderr.strip()[:120])
        except (ValueError, OSError) as e:
            bad("拼不回: %s" % e)

    print("\n── 2. 只搬不改(历史提交) ──")
    if not STEPS:
        ok("STEPS 里还没有登记的段, 这一节没有要比的")
    for n, spec in STEPS.items():
        rel = "lib/pdg/%s.sh" % n
        rc, out, err = git("log", "--format=%H", "--diff-filter=A", "--", rel)
        if rc != 0:
            bad("段「%s」: 取不到 git 历史(%s) —— 这一节必须在完整克隆里跑(CI 的 lint 是 fetch-depth: 0)" % (n, err.strip()[:80]))
            continue
        adds = out.split()
        if len(adds) > 1:
            bad("段「%s」: %s 在历史里被引入了 %d 次, 认不出是哪一步" % (n, rel, len(adds)))
            continue
        if not adds:
            if not (ROOT / rel).is_file():
                bad("段「%s」登记了, 但 %s 既不在历史里也不在工作树里" % (n, rel))
                continue
            rc2, ch, _ = git("diff", "--name-only", "HEAD")
            rc3, un, _ = git("ls-files", "-o", "--exclude-standard")
            if rc2 != 0 or rc3 != 0:
                bad("段「%s」: 读不出工作树相对 HEAD 的改动" % n)
                continue
            where = "工作树(还没提交) 对 HEAD"
            try:
                probs = check_move(entry, part_reader_tree, show("HEAD", "deploy/bot/pdg.sh"), part_reader_git("HEAD"),
                                   spec["extra"], set(ch.split()) | set(un.split()), spec["allow"])
            except OSError as e:
                probs = ["取不到 HEAD 的 pdg.sh: %s" % e]
        else:
            a = adds[0]
            rc2, b, err2 = git("rev-parse", "--verify", "%s^" % a)
            if rc2 != 0:
                bad("段「%s」: 引入它的提交 %s 取不到父提交(浅克隆?): %s" % (n, a[:12], err2.strip()[:80]))
                continue
            b = b.strip()
            rc3, ch, _ = git("diff", "--name-only", b, a)
            where = "提交 %s 对父提交 %s" % (a[:12], b[:12])
            try:
                probs = check_move(show(a, "deploy/bot/pdg.sh"), part_reader_git(a), show(b, "deploy/bot/pdg.sh"), part_reader_git(b),
                                   spec["extra"], set(ch.split()), spec["allow"]) if rc3 == 0 else ["读不出这一步改了哪些文件"]
            except OSError as e:
                probs = ["取不到那两个提交的 pdg.sh: %s" % e]
        if probs:
            bad("段「%s」(%s)不是只搬不改: %s" % (n, where, "; ".join(probs)))
        else:
            ok("段「%s」(%s): 拼回后去掉登记的新增代码, 与上一版逐字节相同; 没改别的生产文件" % (n, where))

    print("\n── 3. 判据自己的负控 ──")
    hdr = pdg_source.PART_HEADER + "\n"
    blk = "# @pdg-part s\n" + "\n".join(pdg_source.loader_lines("s")) + "\n"
    region = "x(){\n  echo x\n}\ny(){ :; }\n"
    extra = "_helper(){ :; }\n"
    b_entry = "#!/usr/bin/env bash\na(){ :; }\n" + region + "main\n"
    a_entry = "#!/usr/bin/env bash\na(){ :; }\n" + extra + blk + "main\n"
    a_part = hdr + region
    allow = {"deploy/bot/pdg.sh", "lib/pdg/s.sh", "lib/modules.sh"}

    def run(entry_a=a_entry, part=a_part, ex=extra, changed=("deploy/bot/pdg.sh", "lib/pdg/s.sh", "tests/x.py")):
        return check_move(entry_a, lambda n: part, b_entry, lambda n: "", ex, set(changed), allow)

    (ok if run() == [] else bad)("正控: 原样搬移 + 登记的新增代码 → 放行(%s)" % run())
    cases = [
        ("段里少一行", dict(part=hdr + region.replace("  echo x\n", ""))),
        ("段里改一个字", dict(part=hdr + region.replace("echo x", "echo y"))),
        ("入口别处改了一个字", dict(entry_a=a_entry.replace("main", "mian"))),
        ("载入语句写错", dict(entry_a=a_entry.replace("source=lib/pdg/s.sh", "source=lib/pdg/t.sh"))),
        ("新增代码没登记", dict(ex="")),
        ("登记的新增代码出现两次", dict(entry_a=a_entry.replace("main\n", extra + "main\n"))),
        ("顺手改了别的生产文件", dict(changed=("deploy/bot/pdg.sh", "lib/pdg/s.sh", "install.sh"))),
        ("段换成别的内容", dict(part=hdr + "z(){ :; }\n")),
    ]
    for why, kw in cases:
        probs = run(**kw)
        (ok if probs else bad)("负控: %s → 拦下(%s)" % (why, "; ".join(probs)[:110] if probs else "没拦住"))

    print("─" * 46)
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    if PASS[0] + FAIL[0] == 0:
        print("零断言 —— 判失败")
        return 1
    return 1 if FAIL[0] else 0


if __name__ == "__main__":
    sys.exit(main())

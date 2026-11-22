#!/usr/bin/env python3
"""tests 共享 pdg.sh 源码入口(tests/pdg_source.py 与 tests/pdg-source-lib.sh)自己的测试。建议 4 第 0 步。

1. 没有拆分标记(现在就是这样): 两边给出的都是 deploy/bot/pdg.sh 本身, 内容逐字节相同。
2. 有标记: 在临时目录里造一棵"入口 + lib/pdg/<段>.sh"的树, 两边拼出的全文逐字节相同、等于预期; 段文件缺了就报错。
3. 往返: 把真 pdg.sh 的一整块函数剪成一个段、在原位置留标记, 拼回来必须与原文件逐字节相同(第一步要用的就是这个性质)。
4. 共享抽取 extract(): 多行 / 单行 / 嵌套各一例; 抽不到、同名多处、找不到收尾都报错, 不返回空串; 与 bash 的 pdg_extract_fn 输出相同。
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import pdg_source  # noqa: E402
import tmpguard  # noqa: E402

LIB = str(ROOT / "tests" / "pdg-source-lib.sh")
ENTRY = ROOT / "deploy" / "bot" / "pdg.sh"
passed = failed = 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print("[OK]   " + msg)
    else:
        failed += 1
        print("[FAIL] " + msg)


# bash 版有标记时把拼好的文件放进 ${TMPDIR:-/tmp} 下、自己不清 —— 本测试调它时把 TMPDIR 指到登记过的目录, 退出时一并清掉。
SH_TMP = tmpguard.mkdtemp(prefix="pdg-source-sh-")


def sh_path(root):
    p = subprocess.run(["bash", LIB, "path", str(root)], capture_output=True, text=True,
                       env=dict(os.environ, TMPDIR=SH_TMP))
    return p.returncode, p.stdout.rstrip("\n"), p.stderr


def raw(p):
    with open(p, "rb") as fh:
        return fh.read()


print("══ 1. 没有拆分标记: 就是 deploy/bot/pdg.sh 本身 ══")
real = raw(ENTRY)
check(b"\n# @pdg-part " not in real and not real.startswith(b"# @pdg-part "), "现在的 pdg.sh 里没有拆分标记(第 0 步不动生产代码)")
check(pdg_source.path(ROOT) == ENTRY, "path(Path) 返回 Path, 就是 deploy/bot/pdg.sh")
check(pdg_source.path(str(ROOT)) == str(ENTRY), "path(str) 返回 str, 就是 deploy/bot/pdg.sh")
check(pdg_source.text(ROOT).encode("utf-8") == real, "text() 与文件逐字节相同")
rc, out, err = sh_path(ROOT)
check(rc == 0 and out == str(ENTRY) and err == "", "bash 版 path 给出同一个路径(rc=%d)" % rc)

print("\n══ 2. 有标记: 临时树里拼回 ══")
tmp = tmpguard.mkdtemp(prefix="pdg-source-test-")
try:
    t = Path(tmp)
    (t / "deploy" / "bot").mkdir(parents=True)
    (t / "lib" / "pdg").mkdir(parents=True)
    entry = "#!/usr/bin/env bash\na(){ :; }\n# @pdg-part one\nb(){\n  :\n}\n# @pdg-part two-x\nmain\n"
    (t / "deploy" / "bot" / "pdg.sh").write_text(entry, encoding="utf-8")
    (t / "lib" / "pdg" / "one.sh").write_text("# shellcheck shell=bash\none(){\n  echo 1\n}\n", encoding="utf-8")
    (t / "lib" / "pdg" / "two-x.sh").write_text("two(){ echo 2; }", encoding="utf-8")  # 末尾没有换行也要拼对
    want = "#!/usr/bin/env bash\na(){ :; }\n# shellcheck shell=bash\none(){\n  echo 1\n}\nb(){\n  :\n}\ntwo(){ echo 2; }\nmain\n"
    p = pdg_source.path(str(t))
    check(p != str(t / "deploy" / "bot" / "pdg.sh"), "有标记时给的是临时文件, 不是入口本身")
    check(raw(p) == want.encode("utf-8"), "python 版拼出的全文等于预期")
    rc, out, err = sh_path(t)
    check(rc == 0 and raw(out) == want.encode("utf-8"), "bash 版拼出的全文等于预期(rc=%d)" % rc)
    (t / "deploy" / "bot" / "pdg.sh").write_text(entry.rstrip("\n"), encoding="utf-8")  # 入口最后一行没有换行
    pdg_source._cache.clear()
    rc, out, err = sh_path(t)
    check(rc == 0 and raw(out) == raw(pdg_source.path(str(t))) == want.rstrip("\n").encode("utf-8"),
          "入口末行没有换行: 两边都不补, 逐字节相同(rc=%d)" % rc)
    os.remove(t / "lib" / "pdg" / "two-x.sh")
    pdg_source._cache.clear()
    try:
        pdg_source.path(str(t))
        check(False, "段文件缺了, python 版必须报错")
    except FileNotFoundError:
        check(True, "段文件缺了, python 版报 FileNotFoundError")
    rc, out, err = sh_path(t)
    check(rc != 0 and "段文件不存在" in err, "段文件缺了, bash 版 rc≠0 并说明(rc=%d)" % rc)
finally:
    tmpguard.cleanup(tmp)

print("\n══ 3. 往返: 真 pdg.sh 剪出一段再拼回, 逐字节相同 ══")
tmp = tmpguard.mkdtemp(prefix="pdg-source-rt-")
try:
    t = Path(tmp)
    (t / "deploy" / "bot").mkdir(parents=True)
    (t / "lib" / "pdg").mkdir(parents=True)
    lines = real.decode("utf-8").split("\n")
    s = next(i for i, l in enumerate(lines) if l.startswith("_pdg_module(){"))
    e = next(i for i in range(s, len(lines)) if lines[i] == "}")
    (t / "lib" / "pdg" / "rt.sh").write_text("\n".join(lines[s:e + 1]) + "\n", encoding="utf-8")
    cut = lines[:s] + ["# @pdg-part rt"] + lines[e + 1:]
    (t / "deploy" / "bot" / "pdg.sh").write_text("\n".join(cut), encoding="utf-8")
    pdg_source._cache.clear()
    check(raw(pdg_source.path(str(t))) == real, "python 版: 剪出 _pdg_module 再拼回, 与原 pdg.sh 逐字节相同")
    rc, out, err = sh_path(t)
    check(rc == 0 and raw(out) == real, "bash 版: 同上(rc=%d)" % rc)
    (t / "lib" / "pdg" / "rt.sh").write_text("\n".join(lines[s:e]) + "\n", encoding="utf-8")  # 少一行: 守门必须看得出
    pdg_source._cache.clear()
    check(raw(pdg_source.path(str(t))) != real, "负控: 段里少一行时, 拼回的与原文件不同")
finally:
    tmpguard.cleanup(tmp)

print("\n══ 4. 共享抽取 extract() ══")
src = real.decode("utf-8")
L = src.split("\n")
s = next(i for i, l in enumerate(L) if l.startswith("_pdg_module(){"))
e = next(i for i in range(s, len(L)) if L[i] == "}")
check(pdg_source.extract("_pdg_module", src) == "\n".join(L[s:e + 1]), "多行顶层: _pdg_module 整段, 收在顶格的 }")
one = pdg_source.extract("c_g", src)
check(one.count("\n") == 0 and one.startswith("c_g(){") and one.rstrip().endswith("}"), "单行顶层: c_g 只取那一行, 不读穿到下一个 }")
nest = pdg_source.extract("_dw_rollback", src)
check(nest.startswith("  _dw_rollback(){") and nest.split("\n")[-1] == "  }" and nest.count("\n") >= 2, "嵌套多行: _dw_rollback 收在同一缩进的 }")
n1 = pdg_source.extract("_dw_cg_of", src)
check(n1.count("\n") == 0 and n1.lstrip().startswith("_dw_cg_of(){"), "嵌套单行: _dw_cg_of 只取那一行")
for name, s2, why in [("no_such_fn_xyz", src, "抽不到"), ("dup", "dup(){ :; }\ndup(){ :; }\n", "同名两处"), ("open", "open(){\n  echo\n", "找不到收尾")]:
    try:
        r = pdg_source.extract(name, s2)
        check(False, "%s 时必须报错, 却返回了 %r" % (why, r[:40]))
    except LookupError:
        check(True, "%s → LookupError, 不返回空串" % why)
for name in ("_pdg_module", "c_g", "_dw_rollback", "_dw_cg_of"):
    p = subprocess.run(["bash", "-c", 'source "$1"; pdg_extract_fn "$2" "$3"', "x", LIB, name, str(ENTRY)], capture_output=True, text=True)
    check(p.returncode == 0 and p.stdout.rstrip("\n") == pdg_source.extract(name, src), "bash 版 pdg_extract_fn %s 与 python 版相同" % name)
p = subprocess.run(["bash", "-c", 'source "$1"; pdg_extract_fn no_such_fn_xyz "$2"', "x", LIB, str(ENTRY)], capture_output=True, text=True)
check(p.returncode != 0 and p.stdout == "", "bash 版抽不到时 rc≠0、不输出")

print("\n────────────────────────────────────────")
print("test-pdg-source.py: 通过 %d, 失败 %d" % (passed, failed))
sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""tests 共享 pdg.sh 源码入口(tests/pdg_source.py 与 tests/pdg-source-lib.sh)自己的测试。建议 4。

1. 没有拆分标记: 两边给出的都是入口本身, 内容逐字节相同(临时树); 真仓库那份: 有没有标记都能给出一份可解析的整份。
2. 有标记: 临时树里"标记 + 3 行载入语句"整块换成段正文(段头那行工具指令不拼), 两边逐字节相同、等于预期;
   缓存: 同一内容同一路径, 内容一变路径就变; bash 版不起 Python 也能命中(证明两边的哈希算的是同一串字节);
   段文件缺了、载入语句写错, 两边都报错。
3. 往返: 把真 pdg.sh 的一整块函数剪成一个段、原位置换成那 4 行, 拼回来与原文逐字节相同; 少一行的负控看得出来。
4. 共享抽取 extract(): 多行 / 单行 / 嵌套各一例; 抽不到、同名多处、找不到收尾都报错; 与 bash 的 pdg_extract_fn 相同。
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
import pdg_source  # noqa: E402
import tmpguard  # noqa: E402

LIB = str(ROOT / "tests" / "pdg-source-lib.sh")
BASH = shutil.which("bash")   # 绝对路径: 下面有一格故意把 PATH 换成只含几个工具的目录
passed = failed = 0

# 缓存目录指到登记过的临时目录: 不碰 ~/.cache, 退出时一并清掉(bash 子进程继承同一个环境变量)
CACHE_HOME = tmpguard.mkdtemp(prefix="pdg-source-cache-")
os.environ["XDG_CACHE_HOME"] = CACHE_HOME
CACHE = os.path.join(CACHE_HOME, "pdg-source")


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print("[OK]   " + msg)
    else:
        failed += 1
        print("[FAIL] " + msg)


def sh_path(root, env=None):
    p = subprocess.run([BASH, LIB, "path", str(root)], capture_output=True, text=True, env=env or dict(os.environ))
    return p.returncode, p.stdout.rstrip("\n"), p.stderr


def raw(p):
    with open(p, "rb") as fh:
        return fh.read()


def cached():
    return sorted(os.listdir(CACHE)) if os.path.isdir(CACHE) else []


def block(name):
    return "# @pdg-part %s\n%s\n" % (name, "\n".join(pdg_source.loader_lines(name)))


def mktree(prefix, entry, parts):
    t = Path(tmpguard.mkdtemp(prefix=prefix))
    (t / "deploy" / "bot").mkdir(parents=True)
    (t / "lib" / "pdg").mkdir(parents=True)
    (t / "deploy" / "bot" / "pdg.sh").write_text(entry, encoding="utf-8")
    for n, body in parts.items():
        (t / "lib" / "pdg" / (n + ".sh")).write_text(body, encoding="utf-8")
    return t


print("══ 1. 没有拆分标记: 就是入口本身 ══")
t = mktree("pdg-source-plain-", "#!/usr/bin/env bash\na(){ :; }\nmain\n", {})
E = t / "deploy" / "bot" / "pdg.sh"
check(pdg_source.path(t) == E, "path(Path) 返回 Path, 就是入口本身")
check(pdg_source.path(str(t)) == str(E), "path(str) 返回 str, 就是入口本身")
check(pdg_source.text(t).encode("utf-8") == raw(E), "text() 与入口逐字节相同")
rc, out, err = sh_path(t)
check(rc == 0 and out == str(E) and err == "", "bash 版给出同一个路径(rc=%d)" % rc)
check(cached() == [], "没有标记时不写缓存")
tmpguard.cleanup(str(t))
real_entry = (ROOT / "deploy" / "bot" / "pdg.sh").read_text(encoding="utf-8")
real = pdg_source.text(ROOT)
names = pdg_source.markers(real_entry)
if names:
    check("\n# @pdg-part " not in real and not real.startswith("# @pdg-part "), "真仓库有 %d 段: 拼回的整份里不再有标记" % len(names))
else:
    check(pdg_source.path(ROOT) == ROOT / "deploy" / "bot" / "pdg.sh", "真仓库没有标记: 给的就是 deploy/bot/pdg.sh")
n = subprocess.run(["bash", "-n", str(pdg_source.path(ROOT))], capture_output=True, text=True)
check(n.returncode == 0, "真仓库拼回的整份过 bash -n")

print("\n══ 2. 有标记: 临时树里整块换回 ══")
entry = "#!/usr/bin/env bash\na(){ :; }\n" + block("one") + "b(){\n  :\n}\n" + block("two-x") + "main\n"
parts = {"one": "# shellcheck shell=bash\none(){\n  echo 1\n}\n",
         "two-x": "two(){ echo 2; }"}                   # 没有段头、末尾没有换行, 也要拼对
want = "#!/usr/bin/env bash\na(){ :; }\none(){\n  echo 1\n}\nb(){\n  :\n}\ntwo(){ echo 2; }\nmain\n"
t = mktree("pdg-source-parts-", entry, parts)
before = set(cached())          # 真仓库有标记时, 上面第 1 节已经往缓存里放过一份
p1 = pdg_source.path(str(t))
check(raw(p1) == want.encode("utf-8"), "python 版拼出的整份等于预期(标记与 3 行载入语句都不在, 段头不拼)")
new = set(cached()) - before
check(os.path.dirname(p1) == CACHE and new == {os.path.basename(p1)}, "拼好的放在缓存目录里(TMPDIR 之外), 只多了这一份(%d)" % len(new))
check(pdg_source.path(str(t)) == p1 and set(cached()) - before == new, "同一内容再取: 同一个路径, 不多写")
rc, out, err = sh_path(t)
check(rc == 0 and out == p1, "bash 版给出同一个缓存路径(rc=%d)" % rc)
# 只留 bash 快路径要用的几个工具, 没有 python3: 还能命中, 说明两边哈希的是同一串字节
shim = Path(tmpguard.mkdtemp(prefix="pdg-source-shim-"))
for tool in ("sed", "cat", "sha256sum", "touch", "dirname", "id"):
    w = shutil.which(tool)
    if w:
        os.symlink(w, shim / tool)
rc, out, err = sh_path(t, env=dict(os.environ, PATH=str(shim)))
check(rc == 0 and out == p1, "bash 版不用 Python 也命中缓存(rc=%d, err=%r)" % (rc, err[:80]))
(t / "lib" / "pdg" / "one.sh").write_text(parts["one"].replace("echo 1", "echo 11"), encoding="utf-8")
p2 = pdg_source.path(str(t))
check(p2 != p1 and b"echo 11" in raw(p2) and b"echo 11" not in raw(p1), "段内容一变: 换一个路径, 旧的那份不被改写")
rc, out, err = sh_path(t, env=dict(os.environ, PATH=str(shim)))
check(rc == 0 and out == p2, "bash 版也认出新内容(rc=%d)" % rc)
(t / "deploy" / "bot" / "pdg.sh").write_text(entry.rstrip("\n"), encoding="utf-8")  # 入口最后一行没有换行
check(raw(pdg_source.path(str(t))) == want.replace("echo 1\n", "echo 11\n").rstrip("\n").encode("utf-8"),
      "入口末行没有换行: 照样不补")
bad = entry.replace(pdg_source.loader_lines("two-x")[1], "# shellcheck source=lib/pdg/other.sh")
(t / "deploy" / "bot" / "pdg.sh").write_text(bad, encoding="utf-8")
try:
    pdg_source.path(str(t))
    check(False, "载入语句写错, python 版必须报错")
except ValueError as e:
    check("two-x" in str(e), "载入语句写错 → ValueError, 指出是哪一段")
rc, out, err = sh_path(t)
check(rc != 0 and out == "" and "two-x" in err, "载入语句写错, bash 版 rc≠0、不给路径(rc=%d)" % rc)
(t / "deploy" / "bot" / "pdg.sh").write_text(entry, encoding="utf-8")
os.remove(t / "lib" / "pdg" / "two-x.sh")
try:
    pdg_source.path(str(t))
    check(False, "段文件缺了, python 版必须报错")
except FileNotFoundError:
    check(True, "段文件缺了 → FileNotFoundError")
rc, out, err = sh_path(t)
check(rc != 0 and out == "" and "段文件不存在" in err, "段文件缺了, bash 版 rc≠0 并说明(rc=%d)" % rc)
tmpguard.cleanup(str(t))
tmpguard.cleanup(str(shim))

print("\n══ 3. 往返: 真 pdg.sh 剪出一段再拼回, 逐字节相同 ══")
lines = real.split("\n")
s = next(i for i, l in enumerate(lines) if l.startswith("_pdg_module(){"))
e = next(i for i in range(s, len(lines)) if lines[i] == "}")
cut = "\n".join(lines[:s]) + "\n" + block("rt") + "\n".join(lines[e + 1:])
t = mktree("pdg-source-rt-", cut, {"rt": "# shellcheck shell=bash\n" + "\n".join(lines[s:e + 1]) + "\n"})
check(pdg_source.text(t) == real, "python 版: 剪出 _pdg_module 再拼回, 与原文逐字节相同")
rc, out, err = sh_path(t)
check(rc == 0 and raw(out).decode("utf-8") == real, "bash 版: 同上(rc=%d)" % rc)
(t / "lib" / "pdg" / "rt.sh").write_text("# shellcheck shell=bash\n" + "\n".join(lines[s:e]) + "\n", encoding="utf-8")
check(pdg_source.text(t) != real, "负控: 段里少一行时, 拼回的与原文不同")
tmpguard.cleanup(str(t))

print("\n══ 4. 共享抽取 extract() ══")
L = real.split("\n")
s = next(i for i, l in enumerate(L) if l.startswith("_pdg_module(){"))
e = next(i for i in range(s, len(L)) if L[i] == "}")
check(pdg_source.extract("_pdg_module", real) == "\n".join(L[s:e + 1]), "多行顶层: _pdg_module 整段, 收在顶格的 }")
one = pdg_source.extract("c_g", real)
check(one.count("\n") == 0 and one.startswith("c_g(){") and one.rstrip().endswith("}"), "单行顶层: c_g 只取那一行, 不读穿到下一个 }")
nest = pdg_source.extract("_dw_rollback", real)
check(nest.startswith("  _dw_rollback(){") and nest.split("\n")[-1] == "  }" and nest.count("\n") >= 2, "嵌套多行: _dw_rollback 收在同一缩进的 }")
n1 = pdg_source.extract("_dw_cg_of", real)
check(n1.count("\n") == 0 and n1.lstrip().startswith("_dw_cg_of(){"), "嵌套单行: _dw_cg_of 只取那一行")
for name, s2, why in [("no_such_fn_xyz", real, "抽不到"), ("dup", "dup(){ :; }\ndup(){ :; }\n", "同名两处"), ("open", "open(){\n  echo\n", "找不到收尾")]:
    try:
        r = pdg_source.extract(name, s2)
        check(False, "%s 时必须报错, 却返回了 %r" % (why, r[:40]))
    except LookupError:
        check(True, "%s → LookupError, 不返回空串" % why)
SRC = str(pdg_source.path(ROOT))
for name in ("_pdg_module", "c_g", "_dw_rollback", "_dw_cg_of"):
    p = subprocess.run(["bash", "-c", 'source "$1"; pdg_extract_fn "$2" "$3"', "x", LIB, name, SRC], capture_output=True, text=True)
    check(p.returncode == 0 and p.stdout.rstrip("\n") == pdg_source.extract(name, real), "bash 版 pdg_extract_fn %s 与 python 版相同" % name)
p = subprocess.run(["bash", "-c", 'source "$1"; pdg_extract_fn no_such_fn_xyz "$2"', "x", LIB, SRC], capture_output=True, text=True)
check(p.returncode != 0 and p.stdout == "", "bash 版抽不到时 rc≠0、不输出")

print("\n────────────────────────────────────────")
print("test-pdg-source.py: 通过 %d, 失败 %d" % (passed, failed))
sys.exit(1 if failed else 0)

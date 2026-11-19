#!/usr/bin/env python3
"""安装清单 —— 写与核对。程序文件的全集由 lib/installset.sh 定(这里只读它给出的行)。

清单记的是"这一版装了哪些程序文件、每个应当是什么内容": 路径、仓库里那份源文件的 sha256、
mode、类别、来源。放在 /var/lib/privdns-gateway/install/manifest.json(不进快照, 也不在
验收采样的目录里)。核对只读, 不改任何东西, 也不打印文件内容 —— 只有路径、计数与状态。

  installset.py write  --repo <仓库> --platform <ios|android> [--by <谁写的>] [--dir <目录>]
                       [--runtime <名\\n名…>] [--legacy <名\\n名…>]      清单行从 stdin 读
  installset.py verify [--json] [--dir <目录>] [--repo <装着的仓库>]
  installset.py record --repo <仓库> [--pid <进程号>] [--dir <目录>]   "<源> <目标> <mode>" 行从 stdin 读
  installset.py rollback-clean --members <快照成员清单> [--keep <受保护成员>] [--dir <目录>] [--root <根>]
  installset.py reconcile [--dir <目录>] [--root <根>]
  installset.py uninstall-clean [--dir <目录>] [--root <根>]
  installset.py forget [--dir <目录>]
  installset.py undo-txn --ancestor-of <进程号> [--dir <目录>] [--root <根>] [--max-age <秒>]
后面六个见"事前记录与撤除"一节; 撤除类的退出码: 0 = 该撤的都撤了, 1 = 有留下来的(逐条报原因)。

verify 的退出码: 0 = 清单里每一项都与盘上相同、且清单记的提交就是装着的提交;
1 = 有不同 / 缺失 / 提交对不上; 2 = 没有清单或清单读不了。
"""
import ast
import calendar
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time

SCHEMA = 1
DEFAULT_DIR = "/var/lib/privdns-gateway/install"
MANIFEST = "manifest.json"
DEFAULT_REPO = "/opt/privdns-gateway"
CLASSES = ("module", "bin", "hook", "unit")
# 每次 `pdg update` 都逐个重装的两类。doctor 只按这两类给 🟡: unit 与钩子在老机器上
# 本来就可能和仓库不同(有的 unit 只在装机时装过一次), 那是部署缺口, 不是这一次出了事。
STRONG = ("module", "bin")
_MODE = re.compile(r"^[0-7]{3}$")
_SHA = re.compile(r"^[0-9a-f]{64}$")
_COMMIT = re.compile(r"^[0-9a-f]{40}$")


def _dir(d=None):
    return d or os.environ.get("PDG_INSTALLSET_DIR") or DEFAULT_DIR


def _repo(r=None):
    return r or os.environ.get("PDG_REPO_DIR") or DEFAULT_REPO


def _git(repo, *args):
    """读仓库的一个值; 读不到返回空串。safe.directory 只对这一次调用放行(装机时仓库可能还归普通用户)。"""
    try:
        p = subprocess.run(["git", "-c", "safe.directory=" + os.path.abspath(repo), "-C", repo, *args],
                           capture_output=True, text=True, timeout=20,
                           env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C"))
    except Exception:  # noqa: BLE001
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            h.update(block)
    return h.hexdigest()


def _names(text):
    return [x.strip() for x in (text or "").splitlines() if x.strip()]


# ── 写 ──────────────────────────────────────────────────────────────────────
def _check_line(n, src, dest, mode, seen, repo):
    """清单行与事前记录行共用的校验: 源在仓库里、目标是规整的绝对路径、mode 合法、目标不重复、
    源是普通文件。返回源文件路径。不合格抛 ValueError(调用方整份拒绝)。"""
    if src.startswith("/") or ".." in src.split("/"):
        raise ValueError("第 %d 行的源路径逃出仓库: %s" % (n, src))
    if not dest.startswith("/") or ".." in dest.split("/") or "//" in dest or dest.endswith("/"):
        raise ValueError("第 %d 行的目标不是规整的绝对路径: %s" % (n, dest))
    if not _MODE.match(mode):
        raise ValueError("第 %d 行的 mode 非法: %s" % (n, mode))
    if dest in seen:
        raise ValueError("目标重复: %s" % dest)
    seen.add(dest)
    p = os.path.join(repo, src)
    st = os.lstat(p) if os.path.lexists(p) else None
    if st is None or not stat.S_ISREG(st.st_mode):
        raise ValueError("源文件不存在或不是普通文件: %s" % src)
    return p


def parse_lines(lines, repo):
    """把 lib/installset.sh 给出的行解析成条目; 任何一行不合格就整份拒绝(半份清单比没有更糟)。"""
    entries, seen = [], set()
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line:
            continue
        f = line.split()
        if len(f) != 4:
            raise ValueError("第 %d 行不是 4 个字段" % n)
        src, dest, mode, cls = f
        if cls not in CLASSES:
            raise ValueError("第 %d 行的类别不认识: %s" % (n, cls))
        p = _check_line(n, src, dest, mode, seen, repo)
        entries.append({"path": dest, "sha256": _sha256(p), "mode": mode, "class": cls, "src": src})
    if not entries:
        raise ValueError("清单是空的")
    entries.sort(key=lambda e: e["path"])
    return entries


def _same(old, new):
    keys = ("schema", "commit", "platform", "entries", "runtime", "legacy")
    return isinstance(old, dict) and all(old.get(k) == new.get(k) for k in keys)


def write(lines, repo, platform, by="", d=None, runtime="", legacy=""):
    """写清单。返回 (changed, n)。内容没变就不重写(免得每次迁移都刷新写入时刻)。"""
    d = _dir(d)
    entries = parse_lines(lines, repo)
    doc = {
        "schema": SCHEMA,
        "commit": _git(repo, "rev-parse", "HEAD"),
        "describe": _git(repo, "describe", "--tags", "--always"),
        "platform": platform or "",
        "by": by or "",
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "entries": entries,
        "runtime": sorted(set(_names(runtime))),
        "legacy": sorted(set(_names(legacy))),
    }
    if os.path.lexists(d):
        if not stat.S_ISDIR(os.lstat(d).st_mode):
            raise ValueError("清单目录不是真目录: %s" % d)
    else:
        os.makedirs(d, mode=0o755)
    path = os.path.join(d, MANIFEST)
    try:
        with open(path, encoding="utf-8") as f:
            old = json.load(f)
    except Exception:  # noqa: BLE001
        old = None
    if _same(old, doc):
        return False, len(entries)
    fd, tmp = tempfile.mkstemp(prefix=".manifest.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fchmod(f.fileno(), 0o644)
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass
    return True, len(entries)


# ── 核对 ────────────────────────────────────────────────────────────────────
def load(d=None):
    """读清单。返回 (state, doc_or_why): state ∈ absent / invalid / ok。"""
    path = os.path.join(_dir(d), MANIFEST)
    if not os.path.lexists(path):
        return "absent", "没有 %s" % path
    try:
        if not stat.S_ISREG(os.lstat(path).st_mode):
            return "invalid", "清单不是普通文件"
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except Exception as e:  # noqa: BLE001
        return "invalid", "读不了(%s)" % type(e).__name__
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return "invalid", "schema 不认识(%r)" % (doc.get("schema") if isinstance(doc, dict) else None)
    ents = doc.get("entries")
    if not isinstance(ents, list) or not ents:
        return "invalid", "没有条目"
    for e in ents:
        if not (isinstance(e, dict) and isinstance(e.get("path"), str) and e["path"].startswith("/")
                and _SHA.match(str(e.get("sha256", ""))) and _MODE.match(str(e.get("mode", "")))
                and e.get("class") in CLASSES):
            return "invalid", "有一条条目格式不对"
    for k in ("runtime", "legacy"):
        if not isinstance(doc.get(k, []), list):
            return "invalid", "%s 不是列表" % k
    return "ok", doc


def _status(e):
    p = e["path"]
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "unreadable"
    if not stat.S_ISREG(st.st_mode):
        return "type"
    try:
        h = _sha256(p)
    except OSError:
        return "unreadable"
    if h != e["sha256"]:
        return "content"
    if "%03o" % stat.S_IMODE(st.st_mode) != e["mode"]:
        return "mode"
    return "same"


def _extras(doc):
    """运行模块目录里清单没记的直接子项(跳过用户数据与运行时状态)。"""
    dirs = {os.path.dirname(e["path"]) for e in doc["entries"] if e["class"] == "module"}
    if len(dirs) != 1:
        return None, []
    mdir = dirs.pop()
    known = {os.path.basename(e["path"]) for e in doc["entries"] if os.path.dirname(e["path"]) == mdir}
    runtime = [str(x) for x in doc.get("runtime", [])]
    legacy = {str(x) for x in doc.get("legacy", [])}
    out = []
    try:
        names = sorted(os.listdir(mdir))
    except OSError:
        return mdir, []
    for n in names:
        if n in known or any(fnmatch.fnmatchcase(n, pat) for pat in runtime):
            continue
        out.append({"path": os.path.join(mdir, n), "kind": "legacy" if n in legacy else "unknown"})
    return mdir, out


def verify(d=None, repo=None):
    state, doc = load(d)
    r = {"state": state, "path": os.path.join(_dir(d), MANIFEST)}
    if state != "ok":
        r["why"] = doc
        return r
    items = [{"path": e["path"], "class": e["class"], "status": _status(e)} for e in doc["entries"]]
    head = _git(_repo(repo), "rev-parse", "HEAD")
    commit = doc.get("commit") or ""
    mdir, extra = _extras(doc)
    r.update({
        "commit": commit, "describe": doc.get("describe") or "", "platform": doc.get("platform") or "",
        "by": doc.get("by") or "", "written_at": doc.get("written_at") or "",
        "head": head,
        "commit_match": (commit == head) if (_COMMIT.match(commit) and _COMMIT.match(head)) else None,
        "items": items,
        "counts": {s: sum(1 for i in items if i["status"] == s)
                   for s in ("same", "content", "mode", "type", "missing", "unreadable")},
        "module_dir": mdir or "", "extra": extra,
    })
    r["counts"]["total"] = len(items)
    return r


def verdict(r):
    if r["state"] != "ok":
        return 2
    bad = any(i["status"] != "same" for i in r["items"])
    return 1 if (bad or r["commit_match"] is False) else 0


_WORD = {"content": "内容不同", "mode": "权限不同", "type": "不是普通文件", "missing": "缺失", "unreadable": "读不了"}


def render(r):
    """人看的输出。不含写入时刻与写入者 —— 回滚前后各核一次时, 这两样会变而文件没变。"""
    out = ["安装清单: %s" % r["path"]]
    if r["state"] != "ok":
        out.append("  %s: %s" % ("没有清单" if r["state"] == "absent" else "清单读不了", r["why"]))
        out.append("结论: 无法核对")
        return out
    c = r["counts"]
    out.append("  记录的版本: %s(%s), 平台 %s" % (r["describe"] or "-", (r["commit"] or "-")[:12], r["platform"] or "-"))
    if r["commit_match"] is True:
        out.append("  装着的版本: %s —— 与清单相同" % r["head"][:12])
    elif r["commit_match"] is False:
        out.append("  装着的版本: %s —— ⚠️ 与清单记的不同" % r["head"][:12])
    else:
        out.append("  装着的版本: 读不到, 没法比")
    parts = ["相同 %d" % c["same"]] + ["%s %d" % (_WORD[k], c[k]) for k in _WORD if c[k]]
    out.append("  程序文件 %d 项: %s" % (c["total"], " / ".join(parts)))
    for i in r["items"]:
        if i["status"] != "same":
            out.append("    %s(%s): %s" % (_WORD[i["status"]], i["class"], i["path"]))
    if r["module_dir"]:
        if r["extra"]:
            out.append("  %s 里清单外的文件 %d 个:" % (r["module_dir"], len(r["extra"])))
            for x in r["extra"]:
                out.append("    %s%s" % (x["path"], "(旧版遗留, 卸载会删)" if x["kind"] == "legacy" else ""))
        else:
            out.append("  %s 里清单外的文件: 无" % r["module_dir"])
    out.append("结论: %s" % ("一致" if verdict(r) == 0 else "不一致"))
    return out


# ── 事前记录与撤除 ──────────────────────────────────────────────────────────
# 回滚是把快照 tar 覆盖写回去: 快照里有的会被还原, 快照之后才出现的文件从来不删。
# 装运行模块的那个函数(lib/modules.sh 的 pdg_install_runtime_modules)在旧版主导的升级里
# 跑的也是新版代码, 所以由它在**写任何文件之前**先落一份事前记录: 要写哪些路径、每个路径
# 写之前在不在(在的话是什么)、写进去的是什么。之后三处按记录撤除"写之前不存在"的模块:
#   · rollback-clean   本版以后的回滚: 快照的成员清单也说它当时不存在, 才算;
#   · reconcile        下一次成功安装 / 升级: 不在新清单里的才算, 收完清空记录;
#   · uninstall-clean  非 purge 卸载。
# 撤除的条件处处同一套: 在运行模块目录里、普通文件、只有一个链接、父目录都是真目录、内容
# 等于当时写进去的那份, 并且**没有服务在用它** —— unit 文件里写着它的路径, 或者被这样的
# 模块逐层 import / 引用到。新版新加的服务, 它的 unit 不在快照里, 回滚后还留着; 这时把它
# 要跑的模块删掉, 服务就起不来了。任何一条不符就留着, 照实报出来 —— 删错比漏删更糟。
TXN = "txn"
MODULE_DIR = "/opt/pdg-bot"
UNIT_DIR = "/etc/systemd/system"
# 有自己一套撤除逻辑的: DoT 证据服务三件由 pdg.sh 的 _pdg_witness_absence 连 unit 与自启一起判。
ELSEWHERE = {"/opt/pdg-bot/dotwitness.py"}
KEEP_RECORDS = 50
_BEFORE_NONREG = "not-regular"


def _ensure_dir(d):
    if os.path.lexists(d):
        if not stat.S_ISDIR(os.lstat(d).st_mode):
            raise ValueError("不是真目录: %s" % d)
    else:
        os.makedirs(d, mode=0o755)


def _fs(root, logical):
    return logical if root in ("", "/") else os.path.join(root, logical.lstrip("/"))


def record(lines, repo, pid="", d=None):
    """事前记录。lines: "<源> <目标> <mode>"。返回记录文件路径。任何一行不合格整份不记。"""
    ents, seen = [], set()
    for n, raw in enumerate(lines, 1):
        f = raw.split()
        if not f:
            continue
        if len(f) != 3:
            raise ValueError("第 %d 行不是 3 个字段" % n)
        src, dest, mode = f
        p = _check_line(n, src, dest, mode, seen, repo)
        try:
            st = os.lstat(dest)
        except FileNotFoundError:
            before = None
        else:
            before = _sha256(dest) if stat.S_ISREG(st.st_mode) else _BEFORE_NONREG
        ents.append({"path": dest, "before": before, "written": _sha256(p), "mode": mode})
    if not ents:
        raise ValueError("记录是空的")
    _ensure_dir(_dir(d))
    td = os.path.join(_dir(d), TXN)
    _ensure_dir(td)
    try:
        boot = open("/proc/sys/kernel/random/boot_id", encoding="ascii").read().strip()
    except OSError:
        boot = ""
    doc = {"schema": SCHEMA, "kind": "install-txn", "pid": str(pid or ""), "boot_id": boot,
           "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "commit": _git(repo, "rev-parse", "HEAD"), "entries": ents}
    fd, tmp = tempfile.mkstemp(prefix=".rec.", dir=td)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fchmod(f.fileno(), 0o644)
            os.fsync(f.fileno())
        base = "%s-%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), str(pid or os.getpid()))
        path, k = os.path.join(td, base + ".json"), 1
        while os.path.lexists(path):
            k += 1
            path = os.path.join(td, "%s-%d.json" % (base, k))
        os.rename(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    names = sorted(n for n in os.listdir(td) if n.endswith(".json"))
    for n in names[:-KEEP_RECORDS]:            # 只留最近这些份, 免得反复失败的机器越攒越多
        try:
            os.unlink(os.path.join(td, n))
        except OSError:
            pass
    return path


def _records(d=None):
    """读全部事前记录。返回 (有效的 [(文件, doc)], 读不了的个数)。读不了的不参与撤除。"""
    td = os.path.join(_dir(d), TXN)
    good, badn = [], 0
    try:
        names = sorted(n for n in os.listdir(td) if n.endswith(".json"))
    except OSError:
        return good, badn
    for n in names:
        p = os.path.join(td, n)
        try:
            if not stat.S_ISREG(os.lstat(p).st_mode):
                raise ValueError
            doc = json.load(open(p, encoding="utf-8"))
            if doc.get("schema") != SCHEMA or doc.get("kind") != "install-txn" or not isinstance(doc.get("entries"), list):
                raise ValueError
            for e in doc["entries"]:
                if not (isinstance(e, dict) and isinstance(e.get("path"), str) and e["path"].startswith("/")
                        and _SHA.match(str(e.get("written", "")))
                        and (e.get("before") is None or e.get("before") == _BEFORE_NONREG
                             or _SHA.match(str(e.get("before"))))):
                    raise ValueError
        except Exception:  # noqa: BLE001
            badn += 1
            continue
        good.append((p, doc))
    return good, badn


def _created(recs):
    """记录里"写之前不存在"的那些: 路径 → 当时写进去的哈希(可能有好几份记录)。"""
    out = {}
    for _p, doc in recs:
        for e in doc["entries"]:
            if e["before"] is None:
                out.setdefault(e["path"], set()).add(e["written"])
    return out


_REF = re.compile(r"/opt/pdg-bot/([A-Za-z0-9_.-]+)")
_DYN = re.compile(r"""(?:_mod|__import__|import_module)\(\s*["']([A-Za-z0-9_]+)["']""")


def _in_use(root):
    """有服务在用的运行模块(文件名): unit 里写着路径的, 加上它们逐层 import / 引用到的。"""
    names = set()
    udir = _fs(root, UNIT_DIR)
    try:
        units = sorted(os.listdir(udir))
    except OSError:
        units = []
    for u in units:
        p = os.path.join(udir, u)
        try:
            if os.path.isfile(p):
                names |= set(_REF.findall(open(p, encoding="utf-8", errors="replace").read()))
        except OSError:
            continue
    mdir = _fs(root, MODULE_DIR)
    seen, stack = set(), sorted(names)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        try:
            text = open(os.path.join(mdir, n), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        refs = set(_REF.findall(text)) | {m + ".py" for m in _DYN.findall(text)}
        if n.endswith(".py"):
            try:
                for node in ast.walk(ast.parse(text)):
                    if isinstance(node, ast.Import):
                        refs |= {a.name.split(".")[0] + ".py" for a in node.names}
                    elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
                        refs.add(node.module.split(".")[0] + ".py")
            except SyntaxError:
                pass
        stack.extend(sorted(r for r in refs if r not in seen))
    return seen


def _removable(root, logical, hashes, in_use):
    """能不能删。返回 (能, 不能的原因)。"""
    if os.path.dirname(logical) != MODULE_DIR:
        return False, "不在运行模块目录里"
    if logical in ELSEWHERE:
        return False, "由别的机制处理"
    if os.path.basename(logical) in in_use:
        return False, "还有服务在用"
    fs = _fs(root, logical)
    parent = os.path.dirname(fs)
    while True:
        try:
            if not stat.S_ISDIR(os.lstat(parent).st_mode):
                return False, "父目录不是真目录"
        except OSError:
            return False, "父目录读不了"
        up = os.path.dirname(parent)
        if up == parent:
            break
        parent = up
    try:
        st = os.lstat(fs)
    except OSError:
        return False, "读不了"
    if not stat.S_ISREG(st.st_mode):
        return False, "不是普通文件"
    if st.st_nlink != 1:
        return False, "有多个硬链接"
    try:
        h = _sha256(fs)
    except OSError:
        return False, "读不了"
    if h not in hashes:
        return False, "内容与当时写进去的不同"
    return True, ""


def _sweep(cand, root, skip=()):
    """按候选撤除。cand: 路径 → 可接受的哈希。返回 (撤掉的, [(留着的, 原因)])。"""
    removed, kept = [], []
    in_use = _in_use(root)
    for p in sorted(cand):
        if p in skip or p in ELSEWHERE or os.path.dirname(p) != MODULE_DIR:
            continue                            # 别的机制处理的不重复报
        if not os.path.lexists(_fs(root, p)):
            continue
        ok_, why = _removable(root, p, cand[p], in_use)
        if ok_:
            try:
                os.unlink(_fs(root, p))
                removed.append(p)
            except OSError as e:
                kept.append((p, "删不掉(%s)" % type(e).__name__))
        else:
            kept.append((p, why))
    return removed, kept


def _members(lines):
    out = set()
    for m in lines:
        m = m.strip()
        while m.startswith("./"):
            m = m[2:]
        m = m.rstrip("/")
        if m:
            out.add(m)
    return out


def rollback_clean(members, keep=(), d=None, root="/"):
    """回滚落盘之后撤除快照之后才出现的运行模块。members: 快照的成员清单(相对 /)。
    keep: 不许动的成员(救援完整恢复时受保护的那些)。快照里根本没有运行模块目录时什么都不做 ——
    那时"快照里没有"说明不了"当时不存在"。"""
    mem = _members(members)
    if MODULE_DIR.lstrip("/") not in mem:
        return [], []
    cand = _created(_records(d)[0])
    st, mdoc = load(d)
    if st == "ok":
        for e in mdoc["entries"]:
            if e["class"] == "module":
                cand.setdefault(e["path"], set()).add(e["sha256"])
    skip = {"/" + k for k in _members(keep)}
    skip |= {p for p in cand if p.lstrip("/") in mem}
    return _sweep(cand, root, skip)


def reconcile(d=None, root="/"):
    """成功安装 / 升级之后: 撤除以前失败那几次留下、又不在新清单里的模块, 然后清空记录。
    没有可用的新清单就什么都不做(判不出哪些是这一版的)。"""
    st, mdoc = load(d)
    if st != "ok":
        return [], [], False
    recs, _badn = _records(d)
    inman = {e["path"] for e in mdoc["entries"]}
    cand = {p: h for p, h in _created(recs).items() if p not in inman}
    removed, kept = _sweep(cand, root)
    for p, _doc in recs:
        try:
            os.unlink(p)
        except OSError:
            pass
    return removed, kept, True


def uninstall_clean(d=None, root="/"):
    """非 purge 卸载: 撤除记录里能认出来的模块, 再删掉清单与记录(本项目自己的状态)。"""
    recs, _badn = _records(d)
    removed, kept = _sweep(_created(recs), root)
    base = _dir(d)
    for p, _doc in recs:
        try:
            os.unlink(p)
        except OSError:
            pass
    for p in (os.path.join(base, MANIFEST),):
        try:
            if os.path.lexists(p) and stat.S_ISREG(os.lstat(p).st_mode):
                os.unlink(p)
        except OSError:
            pass
    for p in (os.path.join(base, TXN), base):
        try:
            os.rmdir(p)                         # 只删空目录; 里面还有别的东西就留着
        except OSError:
            pass
    return removed, kept


def _ancestors(pid, proc="/proc", limit=64):
    """pid 自己连同它的各级父进程(顺着 /proc/<pid>/stat 的第 4 个字段往上找)。读不到就停。"""
    out, cur = [], str(pid)
    for _ in range(limit):
        if not cur.isdigit() or cur in out or int(cur) <= 1:
            break
        out.append(cur)
        try:
            raw = open(os.path.join(proc, cur, "stat"), encoding="utf-8", errors="replace").read()
        except OSError:
            break
        rest = raw[raw.rfind(")") + 1:].split()      # 进程名里可能有空格和括号, 从最后一个 ) 之后取
        if len(rest) < 2:
            break
        cur = rest[1]
    return out


def _boot_id(proc="/proc"):
    try:
        return open(os.path.join(proc, "sys/kernel/random/boot_id"), encoding="ascii").read().strip()
    except OSError:
        return ""


def undo_txn(pid, d=None, root="/", max_age=3600, proc="/proc", now=None):
    """R3: 新版 __migrate 失败或被拒时, 在交还给调用方(旧版)回滚之前, 撤掉**这次升级**新放的运行模块。
    只认这次的事前记录: 记录里的进程号是当前进程的祖先、同一次开机、写于 max_age 秒内。
    写之前就在的(被覆盖的)不动 —— 那些由随后的回滚从快照还原。返回 (撤掉的, 留着的, 认出的记录数)。"""
    anc = set(_ancestors(pid, proc))
    boot = _boot_id(proc)
    now = time.time() if now is None else now
    mine = []
    for p, doc in _records(d)[0]:
        if doc.get("pid") not in anc or not boot or doc.get("boot_id") != boot:
            continue
        try:
            at = calendar.timegm(time.strptime(doc.get("at", ""), "%Y-%m-%dT%H:%M:%SZ"))
        except (ValueError, TypeError):
            continue
        if not (now - max_age <= at <= now + 300):
            continue
        mine.append((p, doc))
    removed, kept = _sweep(_created(mine), root)
    return removed, kept, len(mine)


def forget(d=None):
    """回到了没有安装清单的版本: 删掉那份只会描述一个已经不在盘上的版本的清单。"""
    p = os.path.join(_dir(d), MANIFEST)
    if os.path.lexists(p) and stat.S_ISREG(os.lstat(p).st_mode):
        os.unlink(p)


def _say(removed, kept, what):
    out = []
    if removed:
        out.append("%s: %s" % (what, "、".join(removed)))
    for p, why in kept:
        out.append("保留(%s): %s" % (why, p))
    return out


def _opt(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
        raise SystemExit("%s 缺参数" % name)
    return default


def main(argv):
    if not argv or argv[0] not in ("write", "verify", "record", "rollback-clean", "reconcile",
                                   "uninstall-clean", "forget", "undo-txn"):
        print(__doc__.strip())
        return 2
    if argv[0] == "write":
        repo = _opt(argv, "--repo")
        if not repo:
            print("write 要 --repo", file=sys.stderr)
            return 2
        try:
            changed, n = write(sys.stdin.read().splitlines(), repo, _opt(argv, "--platform", ""),
                               _opt(argv, "--by", ""), _opt(argv, "--dir"),
                               _opt(argv, "--runtime", ""), _opt(argv, "--legacy", ""))
        except (ValueError, OSError) as e:
            print("安装清单没写: %s" % e, file=sys.stderr)
            return 1
        print(("安装清单已更新(%d 项)" if changed else "安装清单无变化(%d 项)") % n)
        return 0
    if argv[0] == "record":
        repo = _opt(argv, "--repo")
        if not repo:
            print("record 要 --repo", file=sys.stderr)
            return 2
        try:
            record(sys.stdin.read().splitlines(), repo, _opt(argv, "--pid", ""), _opt(argv, "--dir"))
        except (ValueError, OSError) as e:
            print("事前记录没写: %s" % e, file=sys.stderr)
            return 1
        return 0
    root = _opt(argv, "--root", "/")
    if argv[0] == "rollback-clean":
        mf, kf = _opt(argv, "--members"), _opt(argv, "--keep")
        try:
            members = open(mf, encoding="utf-8").read().splitlines() if mf else None
            keep = open(kf, encoding="utf-8").read().splitlines() if kf else []
        except OSError as e:
            print("读不到快照成员清单(%s), 没有撤除" % type(e).__name__)
            return 1
        if members is None:
            print("rollback-clean 要 --members", file=sys.stderr)
            return 2
        removed, kept = rollback_clean(members, keep, _opt(argv, "--dir"), root)
        print("\n".join(_say(removed, kept, "撤除快照之后才出现的运行模块")) or "", end="\n" if removed or kept else "")
        return 1 if kept else 0
    if argv[0] == "reconcile":
        removed, kept, done = reconcile(_opt(argv, "--dir"), root)
        print("\n".join(_say(removed, kept, "收走以前没成功的那次留下的运行模块")) or "", end="\n" if removed or kept else "")
        return 1 if kept else 0
    if argv[0] == "uninstall-clean":
        removed, kept = uninstall_clean(_opt(argv, "--dir"), root)
        print("\n".join(_say(removed, kept, "删除以前没成功的升级留下的运行模块")) or "", end="\n" if removed or kept else "")
        return 1 if kept else 0
    if argv[0] == "undo-txn":
        pid = _opt(argv, "--ancestor-of")
        if not pid or not pid.isdigit():
            print("undo-txn 要 --ancestor-of <进程号>", file=sys.stderr)
            return 2
        removed, kept, _n = undo_txn(pid, _opt(argv, "--dir"), root, int(_opt(argv, "--max-age", "3600")),
                                     _opt(argv, "--proc", "/proc"))
        print("\n".join(_say(removed, kept, "撤除这次升级新放的运行模块")) or "", end="\n" if removed or kept else "")
        return 1 if kept else 0
    if argv[0] == "forget":
        try:
            forget(_opt(argv, "--dir"))
        except OSError as e:
            print("删不掉旧清单(%s)" % type(e).__name__, file=sys.stderr)
            return 1
        return 0
    r = verify(_opt(argv, "--dir"), _opt(argv, "--repo"))
    if "--json" in argv:
        print(json.dumps(r, ensure_ascii=False, indent=1, sort_keys=True))
    else:
        print("\n".join(render(r)))
    return verdict(r)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

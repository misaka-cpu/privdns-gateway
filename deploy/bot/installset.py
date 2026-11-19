#!/usr/bin/env python3
"""安装清单 —— 写与核对。程序文件的全集由 lib/installset.sh 定(这里只读它给出的行)。

清单记的是"这一版装了哪些程序文件、每个应当是什么内容": 路径、仓库里那份源文件的 sha256、
mode、类别、来源。放在 /var/lib/privdns-gateway/install/manifest.json(不进快照, 也不在
验收采样的目录里)。核对只读, 不改任何东西, 也不打印文件内容 —— 只有路径、计数与状态。

  installset.py write  --repo <仓库> --platform <ios|android> [--by <谁写的>] [--dir <目录>]
                       [--runtime <名\\n名…>] [--legacy <名\\n名…>]      清单行从 stdin 读
  installset.py verify [--json] [--dir <目录>] [--repo <装着的仓库>]

verify 的退出码: 0 = 清单里每一项都与盘上相同、且清单记的提交就是装着的提交;
1 = 有不同 / 缺失 / 提交对不上; 2 = 没有清单或清单读不了。
"""
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
        if src.startswith("/") or ".." in src.split("/"):
            raise ValueError("第 %d 行的源路径逃出仓库: %s" % (n, src))
        if not dest.startswith("/") or ".." in dest.split("/") or "//" in dest or dest.endswith("/"):
            raise ValueError("第 %d 行的目标不是规整的绝对路径: %s" % (n, dest))
        if not _MODE.match(mode):
            raise ValueError("第 %d 行的 mode 非法: %s" % (n, mode))
        if cls not in CLASSES:
            raise ValueError("第 %d 行的类别不认识: %s" % (n, cls))
        if dest in seen:
            raise ValueError("目标重复: %s" % dest)
        seen.add(dest)
        p = os.path.join(repo, src)
        st = os.lstat(p) if os.path.lexists(p) else None
        if st is None or not stat.S_ISREG(st.st_mode):
            raise ValueError("源文件不存在或不是普通文件: %s" % src)
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


def _opt(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
        raise SystemExit("%s 缺参数" % name)
    return default


def main(argv):
    if not argv or argv[0] not in ("write", "verify"):
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
    r = verify(_opt(argv, "--dir"), _opt(argv, "--repo"))
    if "--json" in argv:
        print(json.dumps(r, ensure_ascii=False, indent=1, sort_keys=True))
    else:
        print("\n".join(render(r)))
    return verdict(r)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

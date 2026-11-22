"""tests 共享的 pdg.sh 源码入口(建议 4)。

pdg.sh 拆成"入口 + lib/pdg/<段>.sh": 段的内容从入口里搬走, 入口在原位置换成固定的 4 行 ——
一行标记 `# @pdg-part <段>`, 后面紧跟 3 行载入语句(见 loader_lines)。测试要读"逻辑上的整份 pdg.sh"
(按名字抽函数、找字样)时一律走这里, 不直接打开 deploy/bot/pdg.sh:

  · 入口里没有标记: path() 返回的就是 deploy/bot/pdg.sh 本身, 路径与内容都不变;
  · 有标记: 把每一块 4 行整体换成对应段文件的正文(段文件开头那行 `# shellcheck shell=bash` 是给工具看的,
    不拼进去), 得到的整份等于"拆之前的 pdg.sh"(加上载入器自己那几个函数), 本身仍是一份能运行的完整脚本。
    标记后面跟的不是那 3 行固定内容就报错 —— 这同时是结构检查。

拼好的整份按"入口 + 各段"的内容哈希缓存在 TMPDIR 之外(默认 ~/.cache/pdg-source/), 先写临时文件再改名,
并发安全; 同一份内容只拼一次。bash 版(pdg-source-lib.sh)命中缓存时不起 Python, 没命中时调本文件拼。
不放 TMPDIR 的原因: 临时物卫生守卫会在私有 TMPDIR 下跑测试, 跑完要求那个目录是空的。

extract() 是共享的按名抽函数: 抽不到就报错(不返回空串), 同名定义不止一处就报错, 单行函数只取那一行,
缩进的嵌套定义按同一缩进的 `}` 收尾。

命令行(给 bash 版用): python3 pdg_source.py path <仓库根>
"""
import hashlib
import os
import re
import sys
import tempfile
import time

_MARK = re.compile(r"^# @pdg-part ([a-z0-9][a-z0-9_-]*)$")
PART_HEADER = "# shellcheck shell=bash"
RULE = "pdg-source-v2"      # 拼回规则的版本; 规则一改就换, 旧缓存自然作废(bash 版用同一个串)
KEEP = 20                   # 缓存里至少留这么多份最新的
KEEP_DAYS = 7               # 再旧、且不在最新那几份里的才删


def loader_lines(name):
    """入口里标记行后面固定的 3 行(与 deploy/bot/pdg.sh 逐字相同)。"""
    return ['_pdg_part_f="$(_pdg_part %s)" || exit 1' % name,
            "# shellcheck source=lib/pdg/%s.sh" % name,
            'source "$_pdg_part_f" || { echo "❌ 载入 $_pdg_part_f 失败(段文件坏了?) —— 停。" >&2; exit 1; }']


def markers(entry_text):
    """入口里的段名, 按出现顺序。"""
    return [m.group(1) for line in entry_text.split("\n") for m in [_MARK.match(line)] if m]


def part_body(part_text):
    """段文件里要拼回去的正文: 去掉开头那行工具指令, 再去掉恰好一个行尾。"""
    body = part_text
    if body == PART_HEADER:
        body = ""
    elif body.startswith(PART_HEADER + "\n"):
        body = body[len(PART_HEADER) + 1:]
    if body.endswith("\n"):
        body = body[:-1]
    return body


def render_text(entry_text, read_part):
    """把入口里每一块"标记 + 3 行载入语句"换成段正文。没有标记时返回 None。

    read_part(name) 返回段文件全文; 段不存在时由它抛 FileNotFoundError。
    """
    lines = entry_text.split("\n")
    if not any(_MARK.match(line) for line in lines):
        return None
    out, i = [], 0
    while i < len(lines):
        m = _MARK.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue
        name = m.group(1)
        if lines[i + 1:i + 4] != loader_lines(name):
            raise ValueError("pdg.sh 第 %d 行的拆分标记「%s」后面不是固定的 3 行载入语句" % (i + 1, name))
        out.append(part_body(read_part(name)))
        i += 4
    return "\n".join(out)


def _entry(root):
    return os.path.join(str(root), "deploy", "bot", "pdg.sh")


def _part(root, name):
    return os.path.join(str(root), "lib", "pdg", name + ".sh")


def _read_bytes(p):
    with open(p, "rb") as fh:
        return fh.read()


def _read(p):
    with open(p, encoding="utf-8", newline="") as fh:
        return fh.read()


def cache_dir():
    """与 bash 版同一规则: $XDG_CACHE_HOME → $HOME/.cache → ${TMPDIR:-/tmp}/pdg-source-<uid>(最后这条只在两者都没有时用)。"""
    base = os.environ.get("XDG_CACHE_HOME") or ""
    if not base and os.environ.get("HOME"):
        base = os.path.join(os.environ["HOME"], ".cache")
    if base:
        return os.path.join(base, "pdg-source")
    return os.path.join(tempfile.gettempdir(), "pdg-source-%d" % os.getuid())


def cache_key(entry_bytes, parts):
    """parts: [(段名, 段文件字节)], 按入口里的顺序。bash 版用同样的字节流算 sha256。"""
    h = hashlib.sha256()
    h.update(RULE.encode() + b"\0")
    h.update(entry_bytes)
    for name, data in parts:
        h.update(b"\0" + name.encode() + b"\0")
        h.update(data)
    return h.hexdigest()


def _prune(d):
    now = time.time()
    try:
        names = os.listdir(d)
    except OSError:
        return
    for n in names:                       # 写到一半的临时文件: 超过一小时的才删
        if n.endswith(".tmp"):
            try:
                if now - os.stat(os.path.join(d, n)).st_mtime > 3600:
                    os.unlink(os.path.join(d, n))
            except OSError:
                pass
    shs = []
    for n in names:
        if n.endswith(".sh"):
            try:
                shs.append((os.stat(os.path.join(d, n)).st_mtime, n))
            except OSError:
                pass
    shs.sort(reverse=True)
    for mt, n in shs[KEEP:]:
        if now - mt > KEEP_DAYS * 86400:
            try:
                os.unlink(os.path.join(d, n))
            except OSError:
                pass


def _store(text, key):
    d = cache_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    p = os.path.join(d, key + ".sh")
    data = text.encode("utf-8")
    try:
        if _read_bytes(p) == data:
            os.utime(p)                   # 用到就刷新时间, 免得被清理
            return p
    except OSError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=key + ".", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _prune(d)
    return p


def path(root):
    """逻辑上整份 pdg.sh 的路径。root 是 Path 就返回 Path, 是 str 就返回 str。

    没有标记时返回的就是按调用方给的 root 拼出的 deploy/bot/pdg.sh(逐字相同); 有标记时返回缓存里拼好的那份。
    段文件不存在抛 FileNotFoundError, 标记后面的载入语句不对抛 ValueError。
    """
    e = _entry(root)
    eb = _read_bytes(e)
    names = markers(eb.decode("utf-8"))
    if not names:
        p = e
    else:
        parts = []
        for n in names:
            pp = _part(root, n)
            if not os.path.isfile(pp):
                raise FileNotFoundError("pdg.sh 的拆分标记「%s」指向的段文件不存在: %s" % (n, pp))
            parts.append((n, _read_bytes(pp)))
        got = dict(parts)
        text = render_text(eb.decode("utf-8"), lambda n: got[n].decode("utf-8"))
        p = _store(text, cache_key(eb, parts))
    return p if isinstance(root, str) else type(root)(p)


def text(root):
    """逻辑上整份 pdg.sh 的全文。"""
    return _read(str(path(root)))


def extract(name, src):
    """从 src 里按名抽出函数 name 的完整定义。抽不到、同名多处、找不到收尾都抛异常, 绝不返回空串。"""
    lines = src.split("\n")
    head = re.compile(r"^([ \t]*)%s\(\)\s*\{" % re.escape(name))
    hits = [(i, m.group(1)) for i, l in enumerate(lines) for m in [head.match(l)] if m]
    if not hits:
        raise LookupError("没有找到函数定义: %s()" % name)
    top = [h for h in hits if h[1] == ""]
    use = top if top else hits
    if len(use) != 1:
        raise LookupError("函数 %s() 定义了 %d 处, 不知道取哪一处" % (name, len(use)))
    i, ind = use[0]
    first = lines[i]
    rest = first[head.match(first).end():]
    if rest.count("{") + 1 == rest.count("}") and re.search(r"\}\s*;?\s*(#.*)?$", rest):
        return first
    end = re.compile(r"^%s\}\s*(#.*)?$" % re.escape(ind))
    for j in range(i + 1, len(lines)):
        if end.match(lines[j]):
            return "\n".join(lines[i:j + 1])
    raise LookupError("函数 %s() 从第 %d 行起找不到收尾的 }" % (name, i + 1))


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] != "path":
        sys.stderr.write("用法: python3 pdg_source.py path <仓库根>\n")
        sys.exit(2)
    try:
        print(path(sys.argv[2]))
    except (OSError, ValueError, UnicodeDecodeError) as e:
        sys.stderr.write("pdg-source: %s\n" % e)
        sys.exit(1)

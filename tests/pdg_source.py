"""tests 共享的 pdg.sh 源码入口(建议 4 第 0 步)。

pdg.sh 以后会拆成"入口 + lib/pdg/<段>.sh": 段的内容从入口里搬走, 入口在原位置留一行
`# @pdg-part <段>`。测试要读"逻辑上的整份 pdg.sh"(按名字抽函数、找字样)时一律走这里, 不再直接
打开 deploy/bot/pdg.sh:

  · 入口里没有拆分标记(现在就是这样): path() 返回的就是 deploy/bot/pdg.sh 本身, 路径与内容都不变;
  · 有标记时: 把每个标记行换成对应段文件的全文, 写进本进程的临时文件, 返回那个临时文件的路径。

extract() 是共享的按名抽函数, 把各测试自己写正则时踩过的坑收在一处: 抽不到就报错(不返回空串),
同名定义不止一处就报错, 单行函数只取那一行, 缩进的嵌套定义按同一缩进的 `}` 收尾。
现有测试在第 0 步只换"源码从哪来", 各自的抽取写法不动; extract() 给以后的新测试用。
"""
import atexit
import os
import re
import shutil
import tempfile

_MARK = re.compile(r"^# @pdg-part ([a-z0-9][a-z0-9_-]*)$")
_cache = {}
_tmpdirs = []


def _entry(root):
    return os.path.join(str(root), "deploy", "bot", "pdg.sh")


def _read(p):
    with open(p, encoding="utf-8", newline="") as fh:
        return fh.read()


def _render(root):
    """入口 + 各段拼回的整份文本; 没有标记时返回 None(调用方直接用入口本身)。"""
    src = _read(_entry(root))
    lines = src.split("\n")
    if not any(_MARK.match(l) for l in lines):
        return None
    out = []
    for l in lines:
        m = _MARK.match(l)
        if not m:
            out.append(l)
            continue
        part = os.path.join(str(root), "lib", "pdg", m.group(1) + ".sh")
        if not os.path.isfile(part):
            raise FileNotFoundError("pdg.sh 的拆分标记指向的段文件不存在: %s" % part)
        body = _read(part)
        if body.endswith("\n"):
            body = body[:-1]
        out.append(body)
    return "\n".join(out)


def path(root):
    """逻辑上整份 pdg.sh 的路径。root 是 Path 就返回 Path, 是 str 就返回 str。

    没有标记时返回的就是按调用方给的 root 拼出的 deploy/bot/pdg.sh(与改前逐字相同, 不经缓存换成别的写法);
    有标记时按 (真实路径, 入口的 mtime 与大小) 缓存拼好的临时文件, 入口在本进程里被改过就重新拼。
    """
    st = os.stat(_entry(root))
    key = (os.path.realpath(str(root)), st.st_mtime_ns, st.st_size)
    if key not in _cache:
        text = _render(root)
        if text is None:
            _cache[key] = None
        else:
            d = tempfile.mkdtemp(prefix="pdg-source-")
            _tmpdirs.append(d)
            p = os.path.join(d, "pdg.sh")
            with open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            _cache[key] = p
    p = _cache[key]
    if p is None:
        p = _entry(root)
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


@atexit.register
def _cleanup():
    for d in _tmpdirs:
        shutil.rmtree(d, ignore_errors=True)

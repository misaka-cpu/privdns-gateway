#!/usr/bin/env python3
"""ev-lint: 发版验收取证脚本的静态检查 —— 只查**踩过**的坑, 每条规则都有出处(tools/evidence/README.md)。

用法:  python3 tools/evidence/ev-lint.py [--strict] 脚本 …
输出:  <文件>:<行>: <规则> [error|warning] <说明> | <那一行>
退出码: 0 = 没有 error(--strict 时也不能有 warning); 1 = 有; 2 = 用法不对 / 读不了文件。

不是 shell 解析器, 是一个够用的扫描器: 认得单引号、双引号、$'…'、注释、heredoc、行尾续行;
双引号里的 "$(…)" 当代码看(那里面的命令一样会执行), 其余引号里的字一律当文字 —— 路径或提示语里
出现 journalctl / awk 字样不算数。拿不准的地方宁可报 warning, 不报 error。
某一行确属有意: 行尾写 `# ev-lint: ignore=E3,E5`。
"""
import re
import sys

RULES = {
    "E1": ("error", "journalctl --since/--until 用了 ISO 的 T/Z 写法: systemd 252 不认, 直接报 Failed to parse timestamp"),
    "E2": ("error", "journalctl 的 stderr 丢进了 /dev/null: 出错时这一段就成了「没有日志」, 计数全成 0"),
    "E3": ("error", "awk 正则里用了 {n} 区间: 远端是 mawk, 不认, 静默匹配为空(要么换 gawk, 要么改用 evlib 的 bash 计数)"),
    "E4": ("error", "不加引号的 heredoc 正文里有反引号: 写的时候就会被当命令执行(证据正文一律 <<'EOF')"),
    "E4w": ("warning", "不加引号的 heredoc 正文里有 $(…): 写的时候就会执行; 若不是有意展开, 改成 <<'EOF'"),
    "E5": ("error", "cmp / diff / sha256sum -c 的比对后面只有 &&、没有 ||: 不符时一声不吭往下走(set -e 也拦不住 && 链)"),
    "E5w": ("warning", "cmp / diff / sha256sum -c 不符时只打印、不停(|| 后面不是 exit / return): 若这是守卫, 改成 || exit"),
    "E6": ("error", "pipefail 下 `| grep -q` / `| grep -m` / `| head`: 下游提前退出, 上游吃 SIGPIPE, 「有」会被判成「没有」; "
                    "先收进变量再 grep -q <<<\"$x\", 或用 evlib 的 ev_has"),
    "E7": ("error", "tr 的参数里有非 ASCII 字符: tr 按字节处理, 会把汉字拆坏"),
    "E7w": ("warning", "cut -c / cut -b 按字节切: 遇到汉字会切出半个字(用 evlib 的 ev_cut_chars)"),
    "E8": ("warning", "pgrep -f 会匹配到发起它的那个 shell 自己(命令行里带着同一个词); 改用 ps 逐进程过滤"),
    "E9": ("error", "ev_guard_* 放进了 $(…) / 管道: exit 只退出子 shell, 守卫失败了外面照样往下跑"),
    "E10": ("warning", "ssh 调用没有给 stdin(< /dev/null、<<、| 或 ssh -n): 会读走本地的 stdin, 包装脚本先 cat 收 stdin 时会一直挂住"),
    "E11": ("warning", "journalctl --since/--until 接的是变量: 拿不准它是不是 ISO 写法; 改用 evlib 的 ev_journal(会先校验格式)"),
    "E12": ("warning", "用了 -o short-iso 却没把 TZ 固定成 UTC(或 ev_init): 时间按本机时区打, 按日分组会错"),
}

HEREDOC_RE = re.compile(r"""(?<!<)<<(?!<)(-?)[ \t]*(?:'([^'\n]+)'|"([^"\n]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))""")
CMD_BOUNDARY = r"(?:^|[\s;&|(`{!])"


def _cmd(word):
    """命令词: 前面是行首 / 分隔符 / 路径, 后面是空白或行尾。"""
    return re.compile(CMD_BOUNDARY + r"(?:\S*/)?" + word + r"(?=\s|$|[;&|)])")


JOURNALCTL = _cmd("journalctl")
AWK = _cmd("awk")
TR = _cmd("tr")
CUT = _cmd("cut")
PGREP = _cmd("pgrep")
SSH = re.compile(CMD_BOUNDARY + r"(?:\S*/)?(ssh|[A-Za-z0-9_.-]*ssh[A-Za-z0-9_.-]*\.sh)(?=\s|$)")
CMP = re.compile(CMD_BOUNDARY + r"(?:\S*/)?(cmp|diff|sha256sum\s+(?:-c|--check))(?=\s|$)")
IGNORE_RE = re.compile(r"#\s*ev-lint:\s*ignore=([A-Za-z0-9,]+)")
INTERVAL_RE = re.compile(r"\{[0-9]+(,[0-9]*)?\}")


def _seg_end(m, start):
    """掩码行里从 start 起, 这条简单命令到哪儿为止(第一个不在引号里的 | ; & ) 或行尾)。"""
    hit = re.search(r"[|;&)]", m[start:])
    return start + hit.start() if hit else len(m)


def find_heredocs(lines):
    """返回 (正文行号集合, heredoc 列表[(起始行号, 是否加引号, 正文行列表[(行号, 文本)])])。行号从 1 起。"""
    body = set()
    docs = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        pending = []
        if not line.lstrip().startswith("#"):
            for m in HEREDOC_RE.finditer(line):
                # 粗略排除: << 出现在单引号里(数一数前面的单引号个数), 或者是算术里的移位 $(( a << b ))
                pre = line[:m.start()]
                if pre.count("'") % 2 == 1 or pre.count("((") > pre.count("))"):
                    continue
                strip_tabs = m.group(1) == "-"
                quoted = m.group(2) is not None or m.group(3) is not None or line[m.start():m.end()].find("\\") >= 0
                word = m.group(2) or m.group(3) or m.group(4)
                pending.append((strip_tabs, quoted, word))
        start = i + 1
        i += 1
        for strip_tabs, quoted, word in pending:
            content = []
            while i < n:
                cand = lines[i].lstrip("\t") if strip_tabs else lines[i]
                if cand == word:
                    body.add(i + 1)
                    i += 1
                    break
                content.append((i + 1, lines[i]))
                body.add(i + 1)
                i += 1
            docs.append((start, quoted, content))
    return body, docs


def mask(text):
    """把引号里的字换成 x(双引号里的 $(…) 与反引号保留), 注释换成空格; 换行原样保留, 行号对得上。
    同时返回单引号串的列表 [(起点偏移, 内容)], 给 awk 规则看程序本身。"""
    out = list(text)
    singles = []
    stack = [["N", 0]]       # 状态: N 代码 / C 代码($(…) 内, 带括号深度) / K 反引号 / S 单引号 / A $'…' / D 双引号
    i = 0
    n = len(text)
    s_start = None
    while i < n:
        ch = text[i]
        st = stack[-1][0]
        nxt = text[i + 1] if i + 1 < n else ""
        if st in ("N", "C", "K"):
            if ch == "\\":
                i += 2
                continue
            if ch == "'":
                stack.append(["S", 0]); s_start = i + 1
            elif ch == "$" and nxt == "'":
                stack.append(["A", 0]); i += 1
            elif ch == '"':
                stack.append(["D", 0])
            elif ch == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
                while i < n and text[i] != "\n":
                    out[i] = " "
                    i += 1
                continue
            elif ch == "$" and nxt == "(":
                stack.append(["C", 0]); i += 1
            elif ch == "`" and st == "K":
                stack.pop()
            elif ch == "`":
                stack.append(["K", 0])
            elif st == "C" and ch == "(":
                stack[-1][1] += 1
            elif st == "C" and ch == ")":
                if stack[-1][1] == 0:
                    stack.pop()
                else:
                    stack[-1][1] -= 1
        elif st == "S":
            if ch == "'":
                singles.append((s_start, text[s_start:i]))
                stack.pop()
            elif ch != "\n":
                out[i] = "x"
        elif st == "A":
            if ch == "\\":
                out[i] = "x"
                if i + 1 < n and text[i + 1] != "\n":
                    out[i + 1] = "x"
                i += 2
                continue
            if ch == "'":
                stack.pop()
            elif ch != "\n":
                out[i] = "x"
        elif st == "D":
            if ch == "\\":
                out[i] = "x"
                if i + 1 < n and text[i + 1] != "\n":
                    out[i + 1] = "x"
                i += 2
                continue
            if ch == '"':
                stack.pop()
            elif ch == "$" and nxt == "(":
                stack.append(["C", 0]); i += 1
            elif ch == "`":
                stack.append(["K", 0])
            elif ch != "\n":
                out[i] = "x"
        i += 1
    return "".join(out), singles


def lint_text(path, text):
    findings = []
    raw_lines = text.split("\n")
    body, docs = find_heredocs(raw_lines)

    def add(code, ln):
        raw = raw_lines[ln - 1] if 0 < ln <= len(raw_lines) else ""
        m = IGNORE_RE.search(raw)
        if m and code.rstrip("w") in m.group(1).split(","):
            return
        if m and code in m.group(1).split(","):
            return
        findings.append((path, ln, code, RULES[code][0], RULES[code][1], raw.strip()))

    # heredoc 正文: E4
    for start, quoted, content in docs:
        if quoted:
            continue
        joined = "\n".join(t for _, t in content)
        if "`" in joined:
            add("E4", start)
        elif "$(" in joined:
            add("E4w", start)

    # 代码: heredoc 正文行置空, 再做掩码
    code_lines = ["" if (k + 1) in body else ln for k, ln in enumerate(raw_lines)]
    code_text = "\n".join(code_lines)
    masked, singles = mask(code_text)
    mlines = masked.split("\n")
    line_starts = [0]
    for ln in code_lines[:-1]:
        line_starts.append(line_starts[-1] + len(ln) + 1)

    def line_of(off):
        lo, hi = 0, len(line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    # 续行拼成逻辑行: (起始行号, 掩码文本, 原文)
    logical = []
    k = 0
    while k < len(mlines):
        start = k
        m_parts, r_parts = [mlines[k]], [code_lines[k]]
        while mlines[k].rstrip().endswith("\\") and k + 1 < len(mlines):
            k += 1
            m_parts.append(mlines[k]); r_parts.append(code_lines[k])
        logical.append((start + 1, " ".join(p.rstrip("\\") for p in m_parts), " ".join(p.rstrip("\\") for p in r_parts)))
        k += 1

    pipefail = bool(re.search(r"set\s+-[A-Za-z]*o\s+pipefail|set\s+-o\s+pipefail|-o\s+pipefail", masked))
    tz_fixed = bool(re.search(r"\bTZ=UTC\b|\bev_init\b", masked))
    short_iso_reported = False

    for ln, m, raw in logical:
        if not m.strip():
            continue
        if JOURNALCTL.search(m):
            if re.search(r"--(?:since|until)[= ]\s*[\"']?(?:\d{4}-\d{2}-\d{2}T|[^\"'\s]*\d{2}:\d{2}(?::\d{2})?Z\b)", raw) \
               or re.search(r"--(?:since|until)[= ]\s*[\"']?\$\(date[^)]*%(?:F|Y-%m-%d)T", raw):
                add("E1", ln)
            elif re.search(r"--(?:since|until)[= ]\s*[\"']?\$", raw):
                add("E11", ln)
            if re.search(r"2>\s*/dev/null|&>\s*/dev/null", m):
                add("E2", ln)
            if not tz_fixed and not short_iso_reported and re.search(r"-o\s*[\"']?short-iso|--output[= ][\"']?short-iso", raw):
                add("E12", ln)
                short_iso_reported = True
        mt = CMP.search(m)
        if mt and "&&" in m[mt.end():]:
            rest = m[mt.end():]
            if "||" not in rest:
                add("E5", ln)
            elif not re.search(r"\|\|\s*(?:(?:exit|return|false|_?ev_guard\w*)\b|\{)", rest):
                add("E5w", ln)
        if pipefail:
            for mt in re.finditer(r"\|\s*(?:\S*/)?(grep|head)(?=\s|$)", m):
                if mt.group(1) == "head":
                    add("E6", ln)
                    break
                opts = re.split(r"\|\||&&|;|\|", m[mt.end():], maxsplit=1)[0]
                if re.search(r"(?:^|\s)(?:-[A-Za-z]*[qm][A-Za-z0-9]*|--quiet|--silent|--max-count\S*)(?=\s|$)", opts):
                    add("E6", ln)
                    break
        for mt in TR.finditer(m):
            if any(ord(c) > 127 for c in raw[mt.start():_seg_end(m, mt.end())]):
                add("E7", ln)
                break
        for mt in CUT.finditer(m):
            if re.search(r"\s-[A-Za-z]*[cb]", m[mt.end():_seg_end(m, mt.end())]):
                add("E7w", ln)
                break
        if PGREP.search(m) and re.search(r"pgrep\s+(?:-[A-Za-z]*\s+)*-[A-Za-z]*f", m):
            add("E8", ln)
        if re.search(r"\$\(\s*ev_guard_|`\s*ev_guard_|\|\s*ev_guard_|\(\s*ev_guard_", m):
            add("E9", ln)
        for mt in SSH.finditer(m):
            before, after = m[:mt.start()], m[mt.end():]
            if re.search(r"[A-Za-z_][A-Za-z0-9_]*\+?=\(\s*$", before + m[mt.start():mt.start() + 1].strip()):
                continue      # SSH=(ssh -o …): 数组赋值, 不是调用
            seg_after = re.split(r"\|\||&&|;|\|(?!\|)", after, maxsplit=1)[0]
            fed = re.search(r"\|\s*$", before.rstrip()) is not None or re.search(r"(?<![<0-9])<(?!\()", seg_after) \
                or re.search(r"\s-[A-Za-z]*n\b", seg_after)
            if not fed and re.search(r"\S", seg_after):
                add("E10", ln)
                break

    # awk 程序本身(单引号串): E3
    for mt in AWK.finditer(masked):          # gawk 不会被 AWK 匹配到(前面不是分隔符), 它认 {n}
        after = mt.end()
        nxt = next(((off, body_) for off, body_ in singles if off > after), None)
        if not nxt:
            continue
        off, prog = nxt
        between = masked[after:off - 1]
        if re.search(r"[|;&\n]", between):
            continue          # 那个单引号串已经不属于这条 awk 了
        if INTERVAL_RE.search(prog):
            add("E3", line_of(after))
    findings.sort(key=lambda f: (f[1], f[2]))
    return findings


def main(argv):
    strict = False
    files = []
    for a in argv:
        if a == "--strict":
            strict = True
        elif a.startswith("-"):
            print("用法: ev-lint.py [--strict] 脚本 …", file=sys.stderr)
            return 2
        else:
            files.append(a)
    if not files:
        print("用法: ev-lint.py [--strict] 脚本 …", file=sys.stderr)
        return 2
    n_err = n_warn = 0
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as e:
            print("%s: 读不了: %s" % (f, e), file=sys.stderr)
            return 2
        for path, ln, code, sev, msg, raw in lint_text(f, text):
            print("%s:%d: %s [%s] %s | %s" % (path, ln, code.rstrip("w"), sev, msg, raw[:160]))
            if sev == "error":
                n_err += 1
            else:
                n_warn += 1
    print("ev-lint: %d 个文件, error %d, warning %d" % (len(files), n_err, n_warn))
    return 1 if n_err or (strict and n_warn) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

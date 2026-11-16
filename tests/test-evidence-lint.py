#!/usr/bin/env python3
"""tools/evidence/ev-lint.py(取证脚本的静态检查): 每条规则一正一反, 外加"引号里的字不算"那几格。

正格是**真出过事**的写法(出处见 tools/evidence/README.md), 必须报出那条规则; 反格是同一件事的正确写法,
必须不报那条规则。另核三件事: 注释与引号里的 journalctl / awk 字样不算数, 双引号里的 "$(…)" 照样当代码查;
`# ev-lint: ignore=…` 只放过点名的规则; 退出码 0 / 1 / 2 与 --strict。
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402
LINT = ROOT / "tools/evidence/ev-lint.py"
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def check(cond, m):
    (ok if cond else bad)(m)


WORK = tmpguard.mkdtemp(prefix="pdg-evlint.")
_n = [0]


def lint(src, *flags):
    """把 src 写成一个脚本跑 ev-lint, 返回 (退出码, 报出的规则集合, 输出)。"""
    _n[0] += 1
    p = os.path.join(WORK, "c%03d.sh" % _n[0])
    with open(p, "w", encoding="utf-8") as f:
        f.write(src)
    r = subprocess.run([sys.executable, "-I", str(LINT), *flags, p], capture_output=True, text=True)
    codes = set()
    for ln in r.stdout.splitlines():
        if ln.startswith(p + ":"):
            parts = ln[len(p) + 1:].split(" ", 3)
            codes.add((parts[1], parts[2].strip("[]")))
    return r.returncode, codes, r.stdout


def rule(code, sev, pos, neg, why):
    rc, got, out = lint(pos)
    check((code, sev) in got, "%s %s 正格报出: %s" % (code, sev, why) + ("" if (code, sev) in got else "\n" + out))
    rc, got, out = lint(neg)
    hit = {c for c, _ in got}
    check(code not in hit, "%s 反格不报: %s" % (code, why) + ("" if code not in hit else "\n" + out))


print("══ 1. 每条规则一正一反 ══")
rule("E1", "error",
     'journalctl -u x --since "2026-11-12T09:54:30Z" --no-pager\n',
     "journalctl -u x --since '2026-11-12 09:54:30 UTC' --no-pager\n",
     "--since 用 ISO 的 T/Z")
rule("E1", "error",
     'journalctl -u x --since "$(date -u -d -1day +%FT%TZ)" --no-pager\n',
     "journalctl -u x --since \"$(date -u -d -1day '+%F %T UTC')\" --no-pager\n",
     "--since 接 $(date … %FT%TZ)")
rule("E2", "error",
     'J=$(journalctl -u pdg-rules-update.service --since "$SINCE" --no-pager -q -o cat 2>/dev/null)\n',
     'J=$(journalctl -u pdg-rules-update.service --since "$SINCE" --no-pager -q -o cat 2>&1)\n',
     "journalctl 的 stderr 丢掉(计数全成 0 的那一行, 原样)")
rule("E3", "error",
     "journalctl --list-boots --no-pager | awk '$2 ~ /^[0-9a-f]{32}$/ {print $2}'\n",
     "journalctl --list-boots --no-pager | awk '$2 ~ /^[0-9a-f]+$/ && length($2) == 32 {print $2}'\n",
     "awk 正则里的 {32}(mawk 采空的那一行)")
rule("E3", "error",
     "awk -F= -v p=1 '\n  /^x{2,}/ { print }\n' f\n",
     "gawk '/^x{2,}/' f\n",
     "多行 awk 程序里的 {2,}; gawk 不查")
rule("E4", "error",
     "cat > README <<EOF\n用 `git commit` 提交\nEOF\n",
     "cat > README <<'EOF'\n用 `git commit` 提交\nEOF\n",
     "不加引号的 heredoc 里有反引号(写的时候会执行)")
rule("E4", "warning",
     'cat > x <<EOF\nnow=$(date)\nEOF\n',
     "cat > x <<'EOF'\nnow=$(date)\nEOF\n",
     "不加引号的 heredoc 里有 $(…)")
rule("E5", "error",
     'cmp -s a.txt b.txt && echo "一致"\n',
     'cmp -s a.txt b.txt || exit 1\n',
     "cmp && echo(比对不符照样往下走)")
rule("E5", "warning",
     'diff a b && echo 相同 || echo "有差异(见上)"\n',
     'diff a b && echo 相同 || { echo 有差异; exit 1; }\n',
     "diff 不符只打印、不停")
rule("E6", "error",
     'set -uo pipefail\nif nft list table inet pdg | grep -q "chain input"; then echo y; fi\n',
     'set -uo pipefail\nt="$(nft list table inet pdg)"; if grep -q "chain input" <<<"$t"; then echo y; fi\n',
     "pipefail 下 | grep -q")
rule("E6", "error",
     'set -euo pipefail\nv=$(git tag -l "v*" --sort=-v:refname | head -1)\n',
     'v=$(git tag -l "v*" --sort=-v:refname | head -1)\n',
     "pipefail 下 | head; 没开 pipefail 不报")
rule("E7", "error",
     "x=$(echo \"$s\" | tr '，' ',')\n",
     "x=\"${s//，/,}\"\n",
     "tr 参数里有汉字标点")
rule("E7", "warning",
     'short=$(echo "$why" | cut -c1-40)\n',
     'short=$(ev_cut_chars "$why" 40)\n',
     "cut -c 截字")
rule("E8", "warning",
     "pgrep -af 'pdg kernel tick'\n",
     "ps -eo pid=,args= | while read -r p a; do :; done\n",
     "pgrep -af 会匹配到自己")
rule("E9", "error",
     'x=$(ev_guard_eq 版本 "$a" "$b")\n',
     'ev_guard_eq 版本 "$a" "$b"\n',
     "守卫放进 $(…)")
rule("E10", "warning",
     'scripts/ssh-r-retry.sh "$R" bash -s\n',
     'scripts/ssh-r-retry.sh "$R" bash -s < "$S"\n',
     "ssh 包装不给 stdin(会挂住的那一种)")
rule("E10", "warning",
     "ssh gw uptime\n",
     "ssh -n gw uptime\nSSH=(ssh -o BatchMode=yes gw)\ncat s.sh | ssh gw bash -s\n",
     "裸 ssh 带命令; -n / 数组赋值 / 管道喂入不报")
rule("E11", "warning",
     'journalctl -u x --since "$SINCE" --no-pager\n',
     'ev_journal A "$FROM" "$UNTIL" -u x\n',
     "--since 接变量")
rule("E12", "warning",
     "journalctl -u x --since '2026-11-12 09:54:30 UTC' -o short-iso\n",
     "export TZ=UTC\njournalctl -u x --since '2026-11-12 09:54:30 UTC' -o short-iso\n",
     "short-iso 没固定 TZ")

print()
print("══ 2. 引号与注释里的字不算, 双引号里的 $(…) 照样查 ══")
rc, got, out = lint('echo "提示: 别写 journalctl --since 2026-11-12T00:00:00Z 2>/dev/null"\n'
                    "# awk '/x{3}/' 这是注释\n"
                    "echo 'cmp a b && echo ok'\n"
                    "printf '%s\\n' \"用 pgrep -af 会咬到自己\"\n")
check(rc == 0 and not got, "提示语 / 注释里出现的命令字样一条都不报" + ("" if not got else "\n" + out))
rc, got, out = lint("echo '下一步; cmp a b && echo ok; journalctl --since 2026-11-12T00:00:00Z 2>/dev/null'\n"
                    "x=$'说明: ; ssh gw uptime'\n")
check(rc == 0 and not got, "单引号 / $'…' 里分号后面跟着的命令字样也不报" + ("" if not got else "\n" + out))
rc, got, out = lint('echo "计数=$(journalctl -u x --since \'2026-11-12 09:54:30 UTC\' -o cat 2>/dev/null | wc -l)"\n')
check(("E2", "error") in got, "双引号里的 \"$(journalctl … 2>/dev/null)\" 照样报 E2(那里面的命令一样会执行)")
rc, got, out = lint("cat <<'EOF'\njournalctl --since 2026-11-12T00:00:00Z 2>/dev/null\nEOF\necho done\n")
check(not got, "加引号 heredoc 的正文是数据, 不当代码查")
rc, got, out = lint("x=$(( 1 << 3 ))\njournalctl -u x --since 2026-11-12T00:00:00Z\n")
check(("E1", "error") in got, "算术里的 << 不被当成 heredoc(后面的行照样查)")
rc, got, out = lint("journalctl -u x \\\n  --since 2026-11-12T00:00:00Z \\\n  --no-pager\n")
check(("E1", "error") in got, "行尾续行拼成一条命令再查")

print()
print("══ 3. ignore 注释只放过点名的规则 ══")
rc, got, out = lint('cmp a b && echo 一致   # ev-lint: ignore=E5\n')
check(not got and rc == 0, "ignore=E5 放过 E5")
rc, got, out = lint('J=$(journalctl -u x --since "$S" 2>/dev/null)   # ev-lint: ignore=E11\n')
check(("E2", "error") in got and ("E11", "warning") not in got, "ignore=E11 不放过同一行的 E2")

print()
print("══ 4. 退出码 ══")
rc, got, out = lint("echo hi\n")
check(rc == 0 and out.strip().endswith("error 0, warning 0"), "干净的脚本 → 0")
rc, got, out = lint("ssh gw uptime\n")
check(rc == 0, "只有 warning → 0")
rc, got, out = lint("ssh gw uptime\n", "--strict")
check(rc == 1, "--strict 下有 warning → 1")
rc, got, out = lint("cmp a b && echo ok\n")
check(rc == 1, "有 error → 1")
r = subprocess.run([sys.executable, "-I", str(LINT)], capture_output=True, text=True)
check(r.returncode == 2, "不给文件 → 2")
r = subprocess.run([sys.executable, "-I", str(LINT), os.path.join(WORK, "不存在.sh")], capture_output=True, text=True)
check(r.returncode == 2, "文件读不了 → 2")

print()
print("══ 5. 库自己 ══")
r = subprocess.run([sys.executable, "-I", str(LINT), "--strict", str(ROOT / "tools/evidence/evlib.sh")],
                   capture_output=True, text=True)
check(r.returncode == 0, "tools/evidence/evlib.sh 过 --strict" + ("" if r.returncode == 0 else "\n" + r.stdout))

print("-" * 62)
print("test-evidence-lint.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)

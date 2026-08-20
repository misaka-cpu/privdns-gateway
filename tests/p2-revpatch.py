#!/usr/bin/env python3
"""把 pdg.sh 反向补丁成"修复前那一版", 供 test-p2-runtime-fixes.sh 当反向对照。

为什么不直接 `git show HEAD:deploy/bot/pdg.sh`: 那只在修复尚未提交时成立。一旦提交,
HEAD 里就是修好的版本, 四个对照格同时失去判别力 —— 而它们**不会报错**, 只会安静地和
新版给出相同结果。"负控自己坏掉了却看不出来"比没有负控更糟, 因为它还在冒充证据。

所以反向补丁逐条断言"确实改动了东西": 哪天产品换了写法、补丁打空, 这里立刻非零退出
并指名是**补丁失效**, 而不是让对照静默退化成同一份源码跑两遍。

用法: p2-revpatch.py <新版 pdg.sh> <输出路径>
"""
import io
import sys


def rev(text, new, old, what):
    if text.count(new) != 1:
        raise SystemExit("反向补丁打空: 找不到唯一的「%s」—— 产品代码换写法了, "
                         "对照必须跟着改, 否则这一格没有判别力" % what)
    return text.replace(new, old)


def main(argv):
    src = io.open(argv[1], encoding="utf-8").read()

    # ① _lock: 还原成"无命令 exec 上直接挂 2>/dev/null"的原始五行。
    #    那个写法会永久改掉当前 shell 的 fd 2, 于是取锁之后 stderr 全进黑洞,
    #    失败时也拿不到系统给的原因(临时文件根本没被写过)。
    new_lock = (
        '  local _lkerr; _lkerr="$(mktemp 2>/dev/null)" || _lkerr=/dev/null\n'
        '  exec 7>&2\n'
        '  if ! exec 2>"$_lkerr" 9>"$LOCK"; then\n'
        '    exec 2>&7 7>&-\n'
        '    echo "⛔ 锁文件不可用($LOCK) —— 为避免并发写坏配置, 本次拒绝执行。"\n'
        '    [[ -s "$_lkerr" ]] && echo "   系统给出的原因: $(head -1 "$_lkerr")"\n'
        '    echo "   请检查 /run 是否可写(磁盘满/只读挂载/权限), 修好后重试。"\n'
        '    [[ "$_lkerr" != /dev/null ]] && rm -f "$_lkerr"\n'
        '    exit 1\n'
        '  fi\n'
        '  exec 2>&7 7>&-\n'
        '  [[ "$_lkerr" != /dev/null ]] && rm -f "$_lkerr"'
    )
    old_lock = (
        '  if ! exec 9>"$LOCK" 2>/dev/null; then\n'
        '    echo "⛔ 锁文件不可用($LOCK) —— 为避免并发写坏配置, 本次拒绝执行。"\n'
        '    echo "   请检查 /run 是否可写(磁盘满/只读挂载/权限), 修好后重试。"\n'
        '    exit 1\n'
        '  fi'
    )
    src = rev(src, new_lock, old_lock, "_lock 的取锁块")

    # ② _restore: 拿掉 start 之前那句 reset-failed
    new_start = (
        '    [[ "$ac0" == active  ]] && { systemctl reset-failed "$T" >/dev/null 2>&1 || true\n'
        '                                 systemctl start  "$T" >/dev/null 2>&1 || _rbad=1; }'
    )
    old_start = '    [[ "$ac0" == active  ]] && { systemctl start  "$T" >/dev/null 2>&1 || _rbad=1; }'
    src = rev(src, new_start, old_start, "_restore 的 start 那行")

    # ③ cmd_update: 整段拿掉「已是最新」短路(从注释头到 "更新前留快照" 那行之前)
    head = '  # ── 「已是最新」短路 '
    tail = '  c_g "更新前留快照…"'
    if src.count(head) != 1 or src.count(tail) != 1:
        raise SystemExit("反向补丁打空: 定位不到「已是最新」短路段")
    i = src.index(head)
    j = src.index(tail, i)
    src = src[:i] + src[j:]

    io.open(argv[2], "w", encoding="utf-8").write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

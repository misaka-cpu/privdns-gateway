#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tools/evidence/evlib.sh(远端取证的共用函数)的行为。每一格对着一个踩过的坑(见 tools/evidence/README.md)。
#
# 外部世界只有 journalctl 是替身: 它照 systemd 252 的样子拒收 ISO 的 T/Z(先对替身本身做正控, 证明它真会拒),
# 另按 jc-mode 演"正常 / 出错 / 有 stderr / 没有日志"。awk 与 grep 也放了替身, 被调到就记一笔 ——
# 库承诺不用它们(远端是 mawk; 交互壳的 grep 是包装函数), 这里核的是承诺本身。
# 每一格都在 env -i 的干净 bash 里跑: 交互壳里的函数挡不住 PATH 替身, 也不让调用方的环境混进来。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/tools/evidence/evlib.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-evlib.XXXXXX")"
[[ -n "${PDG_KEEP_TMP:-}" ]] || trap 'rm -rf -- "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
finish(){ echo "通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; exit $?; }
[[ -s "$LIB" ]] || { bad "找不到 $LIB"; finish; }

STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/journalctl" <<'J'
#!/usr/bin/env bash
# 仿 systemd 252: --since / --until 带 ISO 的 T 或 Z 就报错退出
{ printf 'TZ=%s LC_ALL=%s ARGS=' "${TZ:-<unset>}" "${LC_ALL:-<unset>}"; printf '[%s]' "$@"; echo; } >> "$EVT_WORK/jc.log"
prev=""
for a in "$@"; do
  if [[ "$prev" == --since || "$prev" == --until ]] && [[ "$a" == *[0-9]T[0-9]* || "$a" == *Z ]]; then
    echo "Failed to parse timestamp: $a" >&2; exit 1
  fi
  prev="$a"
done
case "$(cat "$EVT_WORK/jc-mode" 2>/dev/null)" in
  fail)   echo "Failed to get journal access: Permission denied" >&2; exit 1;;
  warn)   cat "$EVT_WORK/jc-out"; echo "Hint: You are currently not seeing messages from other users and the system." >&2; exit 0;;
  empty)  exit 0;;
  *)      cat "$EVT_WORK/jc-out"; exit 0;;
esac
J
for t in awk grep gawk mawk; do
  printf '#!/bin/sh\necho "%s $*" >> "$EVT_WORK/forbidden.log"\nexit 99\n' "$t" > "$STUB/$t"
done
chmod 755 "$STUB"/*
cat > "$WORK/jc-out" <<'O'
2026-11-13T09:54:31+00:00 gw systemd[1]: Starting pdg-rules-update.service - x...
2026-11-13T09:54:40+00:00 gw pdg[1]: 自动检查: 上游 v1.19.34 发布于 2026-11-12T00:00:00Z, 还没满等待期, 之后再换
2026-11-14T09:54:31+00:00 gw systemd1: Starting pdg-rules-update.service - x...
O

# ev '<代码>': 在干净 bash 里 source 库再跑代码; 输出 stdout+stderr, 返回代码的退出码
ev(){ env -i HOME="$HOME" PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" bash --noprofile --norc -c "source '$LIB'; $1" 2>&1; }
forbidden_clean(){ [[ ! -s "$WORK/forbidden.log" ]]; }

echo "══ 0. 替身本身(正控): 照 systemd 252 拒收 ISO 写法 ══"
out="$(env -i PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" journalctl --since 2026-11-12T09:54:30Z --no-pager 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == "Failed to parse timestamp: 2026-11-12T09:54:30Z" ]] \
  && ok "替身拿到 ISO 的 T/Z → Failed to parse timestamp, rc=1" || bad "替身不像 systemd 252: rc=$rc out=$out"
out="$(env -i PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" bash --noprofile --norc -c 'awk 1 </dev/null; echo rc=$?')"
[[ "$out" == "rc=99" && -s "$WORK/forbidden.log" ]] && ok "awk 替身在 PATH 最前、被调到会记一笔" || bad "awk 替身没生效: $out"
rm -f "$WORK/forbidden.log" "$WORK/jc.log"

echo "══ 1. ev_init 与时刻写法 ══"
out="$(ev 'ev_init; echo "rc=$? TZ=$TZ LC_ALL=$LC_ALL"; s="换核前一致"; echo "len=${#s}"')"
[[ "$out" == $'rc=0 TZ=UTC LC_ALL=C.UTF-8\nlen=5' ]] && ok "ev_init: TZ=UTC、C.UTF-8, 之后按字符数汉字" || bad "ev_init: $out"
out="$(ev 'for t in "2026-11-12 09:54:30 UTC" "2026-11-12T09:54:30Z" "2026-11-12 09:54:30" "2026-11-12 09:54 UTC" ""; do ev_ts_ok "$t"; printf "%s;" $?; done')"
[[ "$out" == "0;1;1;1;1;" ]] && ok "ev_ts_ok 只认 'YYYY-MM-DD HH:MM:SS UTC'" || bad "ev_ts_ok: $out"
out="$(ev 'ev_ts_from_iso 2026-11-12T09:54:30Z; ev_ts_from_iso 2026-11-12T09:54:30+00:00; ev_ts_from_iso "2026-11-12 09:54:30 UTC"; ev_ts_from_iso 2026-11-12T17:54:30+08:00; echo "rc=$?"')"
[[ "$out" == $'2026-11-12 09:54:30 UTC\n2026-11-12 09:54:30 UTC\n2026-11-12 09:54:30 UTC\nrc=2' ]] \
  && ok "ev_ts_from_iso: Z / +00:00 转换, 合格的原样, 别的时区不猜(rc=2, 不打印)" || bad "ev_ts_from_iso: $out"

echo "══ 2. ev_journal: 采到 / 格式不对不调 / 出错不当 0 条 ══"
echo ok > "$WORK/jc-mode"
out="$(ev 'ev_journal A "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC" -u pdg-rules-update.service; echo "rc=$? EV_RC=$EV_RC EV_LINES=$EV_LINES"; printf "%s\n" "$A"')"
want_hdr='[ev journal rc=0 行数=3 起=2026-11-12 09:54:30 UTC 止=2026-11-15 05:20:00 UTC 选择=-u pdg-rules-update.service]'
[[ "$(sed -n 1p <<<"$out")" == "$want_hdr" && "$(sed -n 2p <<<"$out")" == "rc=0 EV_RC=0 EV_LINES=3" ]] \
  && ok "采到: 抬头写明 rc / 行数 / 起止 / 选择, 返回 0" || bad "抬头: $(sed -n 1,2p <<<"$out")"
[[ "$(sed -n '3,$p' <<<"$out")" == "$(cat "$WORK/jc-out")" ]] && ok "内容原样进变量" || bad "内容变了"
[[ "$(cat "$WORK/jc.log")" == "TZ=UTC LC_ALL=C.UTF-8 ARGS=[--since][2026-11-12 09:54:30 UTC][--until][2026-11-15 05:20:00 UTC][--no-pager][-q][-a][-o][short-iso][-u][pdg-rules-update.service]" ]] \
  && ok "调用: 没 ev_init 也带 TZ=UTC / C.UTF-8, 参数 -q -a -o short-iso + 选择" || bad "调用形态: $(cat "$WORK/jc.log")"
rm -f "$WORK/jc.log"
out="$(ev 'ev_journal A "2026-11-12T09:54:30Z" "2026-11-15 05:20:00 UTC" -u x; echo "rc=$?"')"
[[ "$out" == *"systemd 252 不认 ISO"* && "$out" == *"rc=2" && ! -e "$WORK/jc.log" ]] \
  && ok "ISO 写法 → rc=2, 说明原因, 根本不调 journalctl" || bad "ISO 写法: $out"
echo fail > "$WORK/jc-mode"
out="$(ev 'ev_journal A "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC" -u x; echo "rc=$? EV_RC=$EV_RC A=[$A]"')"
[[ "$out" == *"[ev journal rc=1 行数=0"* && "$out" == *"[ev journal stderr] Failed to get journal access: Permission denied"* && "$out" == *"rc=3 EV_RC=1 A=[]" ]] \
  && ok "journalctl 出错 → rc=3, stderr 原样打出, 不当成「没有日志」" || bad "出错: $out"
echo warn > "$WORK/jc-mode"
out="$(ev 'ev_journal A "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC" -u x; echo "rc=$?"')"
[[ "$out" == *"[ev journal stderr] Hint: You are currently not seeing messages"* && "$out" == *"rc=3" ]] \
  && ok "退出码 0 但有 stderr(看不全日志的提示)→ 也是 rc=3" || bad "有 stderr: $out"
echo empty > "$WORK/jc-mode"
out="$(ev 'ev_journal A "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC" -u x; echo "rc=$? lines=$EV_LINES"')"
[[ "$out" == *"[ev journal rc=0 行数=0"* && "$out" == *"rc=0 lines=0" ]] && ok "真没有日志 → rc=0、行数 0(与出错分得开)" || bad "空: $out"
out="$(ev 'ev_journal "a b" "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC"; echo "rc=$?"; ev_journal _ev_out "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC"; echo "rc=$?"')"
[[ "$(grep -c '^rc=2$' <<<"$out")" == 2 ]] && ok "变量名不合法 / 以 _ev_ 开头 → rc=2" || bad "变量名: $out"
echo ok > "$WORK/jc-mode"; rm -f "$WORK/jc.log"
out="$(ev 'ev_events E "2026-11-12 09:54:30 UTC" "2026-11-15 05:20:00 UTC"; echo "rc=$?"')"
[[ "$out" == *"选择=-t pdg-event]"* && "$(cat "$WORK/jc.log")" == *"[-t][pdg-event]" ]] && ok "ev_events 取的是 -t pdg-event" || bad "ev_events: $out"

echo "══ 3. 计数与查找: 纯 bash, 按字面 / 按整词 ══"
T="$(cat "$WORK/jc-out")"
export T
cnt(){ env -i HOME="$HOME" PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" T="$T" bash --noprofile --norc -c "source '$LIB'; $1" 2>&1; }
[[ "$(cnt 'ev_count_fixed "$T" "systemd[1]: Starting "')" == 1 ]] \
  && ok "ev_count_fixed 按字面: 'systemd[1]: ' 不会把 'systemd1: ' 也算进去" || bad "ev_count_fixed: $(cnt 'ev_count_fixed "$T" "systemd[1]: Starting "')"
[[ "$(cnt 'ev_count_fixed "$T" "还没满等待期"; ev_count_fixed "$T" "不存在的字"; ev_count_fixed "" x; ev_count_fixed "$T" ""')" == $'1\n0\n0\n0' ]] \
  && ok "ev_count_fixed: 命中 / 不命中 / 空文本 / 空字串" || bad "ev_count_fixed 边界"
# 字串里的 * ? [ 当成 glob 时计数会变: 'a*b' 按字面只算 a*b 那一行, 当 glob 会把 axxb 也算上
G=$'a*b\naxxb\na?c\nabc\n[x]\nx'
[[ "$(env -i PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" T="$G" bash --noprofile --norc -c "source '$LIB'; ev_count_fixed \"\$T\" 'a*b'; ev_count_fixed \"\$T\" 'a?c'; ev_count_fixed \"\$T\" '[x]'; ev_has \"\$T\" 'a*c' || echo n" 2>&1)" == $'1\n1\n1\nn' ]] \
  && ok "ev_count_fixed / ev_has: 字串里的 * ? [ ] 不是通配符(a*b 不算 axxb, a?c 不算 abc, [x] 不算 x)" \
  || bad "通配字符被当成了 glob"
[[ "$(cnt 'ev_lines "$T"; ev_lines ""; ev_lines $'"'"'a\n\n\nb\n'"'"'')" == $'3\n0\n2' ]] && ok "ev_lines 只数非空行" || bad "ev_lines: $(cnt 'ev_lines "$T"')"
[[ "$(cnt 'ev_has "$T" "v1.19.34" && echo y; ev_has "$T" "v9" || echo n; ev_has "$T" "" || echo e')" == $'y\nn\ne' ]] \
  && ok "ev_has: 有 / 没有 / 空字串算没有" || bad "ev_has"
E=$'2026-11-15T04:55:01+00:00 gw pdg-event[9]: event=kernel.switch result=ok via=auto from=v1.19.33 to=v1.19.34\n2026-11-15T04:55:02+00:00 gw pdg-event[9]: event=kernel.switch result=ok via=auto from=v1.19.30 to=v1.19.3'
T="$E"
[[ "$(cnt 'ev_count_tokens "$T" event=kernel.switch result=ok to=v1.19.34; ev_count_tokens "$T" to=v1.19.3; ev_count_tokens "$T" result=o; ev_count_tokens "$T"')" == $'1\n1\n0\n0' ]] \
  && ok "ev_count_tokens 按整词: to=v1.19.3 不算 to=v1.19.34, result=o 不算 result=ok" || bad "ev_count_tokens"
T="$(cat "$WORK/jc-out")"$'\n-- 不是日期开头的一行 Starting \n2026-11-13T23:59:59+00:00 gw systemd[1]: Starting y'
want=$'  2026-11-13 2\n  2026-11-14 1\n  其它 1\n  合计 4'
[[ "$(cnt 'ev_count_by_day "$T" "Starting "')" == "$want" ]] && ok "ev_count_by_day: 按日分组、排序, 非日期行归其它, 末行合计" \
  || bad "ev_count_by_day: $(cnt 'ev_count_by_day "$T" "Starting "')"
[[ "$(cnt 'ev_count_by_day "$T" "不存在"')" == "  合计 0" ]] && ok "ev_count_by_day: 没有命中只打合计 0" || bad "by_day 空"
out="$(cnt 'set -euo pipefail; n=$(ev_count_fixed "$T" 不存在); ev_has "$T" 不存在 || true; m=$(ev_count_tokens "$T" x=y); echo "n=$n m=$m 还在跑"')"
[[ "$out" == "n=0 m=0 还在跑" ]] && ok "调用方开着 set -euo pipefail: 0 次命中不会把脚本带停" || bad "严格模式下: $out"
forbidden_clean && ok "整个第 2、3 节没有调过 awk / grep" || bad "库调了被禁的工具: $(cat "$WORK/forbidden.log")"

echo "══ 4. ev_cut_chars: 按字符, 调用方在 C 区域下也一样 ══"
out="$(env -i PATH="$STUB:/usr/bin:/bin" LC_ALL=C bash --noprofile --norc -c "source '$LIB'; ev_cut_chars 换核前一致 3; ev_cut_chars ab 9; ev_cut_chars x -1; echo rc=\$?" 2>&1)"
[[ "$out" == $'换核前\nab\n[ev] ev_cut_chars 的 N 要是非负整数: [-1]\nrc=2' ]] && ok "前 3 个字符是「换核前」; N 超长原样; 负数 rc=2" || bad "ev_cut_chars: $out"

echo "══ 5. ev_run: 不吃掉后面的脚本 ══"
# 远端脚本走 bash -s 的 stdin: 不接 /dev/null 的 cat 会把后面的脚本当输入吃掉(负控), 走 ev_run 的不会
printf 'cat\necho 尾部跑到了\n' > "$WORK/eat.sh"
{ cat "$LIB"; printf 'ev_run 读stdin的命令 cat\necho 尾部跑到了\n'; } > "$WORK/noeat.sh"
neg="$(env -i PATH=/usr/bin:/bin bash --noprofile --norc -s < "$WORK/eat.sh" 2>&1)"
pos="$(env -i PATH=/usr/bin:/bin bash --noprofile --norc -s < "$WORK/noeat.sh" 2>&1)"
[[ "$neg" == "echo 尾部跑到了" ]] && ok "负控: 裸 cat 把后面那行脚本当成输入打了出来, 那一行没执行" || bad "负控没复现: [$neg]"
[[ "$pos" == $'== 读stdin的命令\n[读stdin的命令 rc=0]\n尾部跑到了' ]] && ok "ev_run: stdin 接 /dev/null, 后面的脚本照常执行" || bad "ev_run: [$pos]"
out="$(ev 'ev_run 失败的命令 false; echo "rc=$?"; ev_run 空; echo "rc=$?"')"
[[ "$out" == $'== 失败的命令\n[失败的命令 rc=1]\nrc=1\n== 空\n[空 rc=2] (没有给命令)\nrc=2' ]] && ok "ev_run 原样传出退出码; 没给命令 rc=2" || bad "ev_run rc: $out"

echo "══ 6. 守卫: 不通过就停整个脚本(86), 通过也留一行 ══"
out="$(ev 'ev_guard_eq 版本 v1 v1; echo 后面还在'; echo "rc=$?")"
[[ "$out" == $'[ev 守卫通过] 版本 = [v1]\n后面还在\nrc=0' ]] && ok "ev_guard_eq 通过: 打一行, 继续" || bad "eq 通过: $out"
out="$(ev 'ev_guard_eq 版本 v1 v2; echo 不该跑到这里'; echo "rc=$?")"
[[ "$out" == $'[ev 守卫失败] 版本 不符: 实际=[v1] 期望=[v2]\nrc=86' ]] && ok "ev_guard_eq 不通过: 退出 86, 后面不跑" || bad "eq 失败: $out"
out="$(ev 'ev_guard_nonempty 抽取 ""; echo 不该跑到这里'; echo "rc=$?")"
[[ "$out" == *"[ev 守卫失败] 抽取 是空的"* && "$out" == *"rc=86" && "$out" != *不该跑到这里* ]] && ok "ev_guard_nonempty: 空串停" || bad "nonempty: $out"
out="$(ev 'ev_guard_rc journal 1 0 1; ev_guard_rc journal 3; echo 不该跑到这里'; echo "rc=$?")"
[[ "$out" == $'[ev 守卫通过] journal rc=1\n[ev 守卫失败] journal rc=3, 允许的是: 0\nrc=86' ]] && ok "ev_guard_rc: 给了允许值按允许值, 没给只认 0" || bad "rc: $out"
printf 'abc' > "$WORK/f"; SHA="$(sha256sum < "$WORK/f")"; SHA="${SHA%% *}"; : > "$WORK/empty"
out="$(ev "ev_guard_sha256 '$WORK/f' $SHA; echo 继续")"
[[ "$out" == "[ev 守卫通过] $WORK/f sha256=$SHA"$'\n继续' ]] && ok "ev_guard_sha256 相等 → 通过" || bad "sha 通过: $out"
for c in "'$WORK/f' $(printf '0%.0s' {1..64})" "'$WORK/nosuch' $SHA" "'$WORK/empty' $SHA" "'$WORK/f' ABC"; do
  out="$(ev "ev_guard_sha256 $c; echo 不该跑到这里")"; rc=$?
  [[ "$rc" == 86 && "$out" == "[ev 守卫失败]"* && "$out" != *不该跑到这里* ]] || { bad "sha 应停: $c → rc=$rc $out"; continue; }
done
ok "ev_guard_sha256: 摘要不符 / 文件不在 / 空文件 / 期望值不是 64 位十六进制 → 都停"
out="$(ev 'x=$(ev_guard_eq a 1 2); echo "外面还在跑 rc=$?"')"
[[ "$out" == *"这是在子 shell 里调的守卫"* && "$out" == *"外面还在跑 rc=86"* ]] \
  && ok "子 shell 里的守卫: exit 只退出子 shell —— 库当场大声说出来" || bad "子 shell: $out"

echo "══ 7. 文档里的用法与自查 ══"
{ cat "$LIB"; printf 'ev_init || exit 1\nev_guard_eq 拼接用法 1 1\necho 拼在前面也能用\n'; } > "$WORK/cat-usage.sh"
out="$(env -i PATH="$STUB:/usr/bin:/bin" EVT_WORK="$WORK" bash --noprofile --norc -s < "$WORK/cat-usage.sh" 2>&1)"
[[ "$out" == $'[ev 守卫通过] 拼接用法 = [1]\n拼在前面也能用' ]] && ok "cat evlib.sh check.sh | bash -s 的拼接用法可用" || bad "拼接: $out"
out="$(python3 "$ROOT/tools/evidence/ev-lint.py" --strict "$LIB" 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "库自己过 ev-lint --strict" || bad "库没过自己的检查: $out"
forbidden_clean && ok "全程没有调过 awk / grep" || bad "库调了被禁的工具: $(cat "$WORK/forbidden.log")"
finish

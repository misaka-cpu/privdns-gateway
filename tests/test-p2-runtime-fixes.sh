#!/usr/bin/env bash
# §10 的四条 P2 运行时缺陷 —— 全部**真跑被测函数**, 每格配一个反向对照。
#
# 为什么坚持跑而不是 grep: 这四条里有三条的错误形态是"代码看着对、行为不对" ——
#   · `exec 9>… 2>/dev/null` 从字面上看只是给这一句加了个重定向;
#   · `systemctl start` 少一句 reset-failed, 静态看毫无异常;
#   · "已是最新"短路少了 `^{commit}`, 附注 tag 下永远不相等, 也看不出来。
# 静态断言对这三种一律无能为力。
#
# 反向对照统一用 `git show HEAD:deploy/bot/pdg.sh` 取修复前那一版, 同一套驱动跑两遍:
# 新版必须绿、旧版必须红。旧版也绿 = 这格什么都没测到。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# ref 守卫: tests/ 下每一处会动 ref/config 的 git 调用都必须走 e2e_git —— 那道守卫的由来
# 是一次真事故(裸 git 打在了本仓库上)。repoguard.sh 被单独拆出来就是给这类不走 e2e harness
# 的用例用的; 它对一次性独立仓库放行, 对本仓库/worktree 直接拒。
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"
NEW="$ROOT/deploy/bot/pdg.sh"
OLD="$WORK/pdg-old.sh"
# 反向对照的"修复前那一版"由**当前源码做最小反向补丁**得到, 不从 git 历史取 ——
# 锚在 HEAD 上只在修复尚未提交时成立, 提交之后四个对照格会安静地失去判别力。
# 补丁逐条断言"确实改动了东西": 打空就非零退出并指名是补丁失效(见 p2-revpatch.py)。
python3 "$ROOT/tests/p2-revpatch.py" "$NEW" "$OLD" \
  || { echo "[FAIL] 反向补丁失效 —— 负控无法构造, 本次结果不可信"; exit 1; }

pass=0; nfail=0
ok(){  pass=$((pass+1)); echo "[OK]   $1"; }
bad(){ nfail=$((nfail+1)); echo "[FAIL] $1"; }
# 反向对照没转红时不要报 OK —— 那正是"这格是摆设"的样子。
ctl(){ if [[ "$1" == "$2" ]]; then bad "反向对照: $3 —— 旧版行为与新版相同, 这一格没有判别力"; else ok "反向对照: $3"; fi; }

fn(){ sed -n "$2" "$1"; }        # $1=文件 $2=sed 范围

# ══ 一、_lock(): 取锁之后 stderr 不许被吞(交接文档 9.4) ══════════════════════
# `exec 9>"$LOCK" 2>/dev/null` 是**无命令的重定向**, 那个 `2>/dev/null` 会永久改掉当前
# shell 的 fd 2。后果不是"少看见一行", 而是取锁之后整个 pdg 的 stderr 全进黑洞。
drv_lock_stderr(){                      # $1=pdg.sh 路径 → 打印取锁后写到 stderr 的东西
  local f="$1" d="$WORK/lk1"; rm -rf "$d"; mkdir -p "$d"
  { echo 'LOCK="'"$d"'/lk"; PDG_LOCKED=""'
    fn "$f" '/^_lock_inherited(){/,/^}/p'
    fn "$f" '/^_lock(){/,/^}/p'
    echo '_lock'
    echo 'echo "STDERR-STILL-ALIVE" >&2'
  } > "$WORK/d1.sh"
  # 只要 stderr, 丢掉 stdout。写成 `{ …>/dev/null; } 2>&1` 而不是 `2>&1 >/dev/null`:
  # 后者语义虽然对, 但 shellcheck 判 SC2069(CI 对 warning 是阻断的)。
  { bash "$WORK/d1.sh" >/dev/null; } 2>&1
}
got_new="$(drv_lock_stderr "$NEW")"
got_old="$(drv_lock_stderr "$OLD")"
if grep -q 'STDERR-STILL-ALIVE' <<<"$got_new"; then
  ok "_lock 取锁成功后 stderr 仍然通畅(fd 2 已接回)"
else
  bad "_lock 之后写 stderr 的内容不见了 —— fd 2 仍被永久重定向"
fi
ctl "$(grep -c 'STDERR-STILL-ALIVE' <<<"$got_new")" "$(grep -c 'STDERR-STILL-ALIVE' <<<"$got_old")" \
    "旧版在取锁后确实吞掉了 stderr"

# ── 打不开锁文件时, 要把系统给的真实原因带出来 ──
# 只说"锁文件不可用"等于把排查丢回给用户: Read-only / No space / Permission denied
# 三种的处置完全不同。判据锚在"有没有那一行原因"上, 不锚具体英文 —— 那随 locale 变。
drv_lock_reason(){
  local f="$1"
  { echo 'LOCK="'"$WORK"'/nodir/lk"; PDG_LOCKED=""'      # 父目录不存在 → 必定打不开
    fn "$f" '/^_lock_inherited(){/,/^}/p'
    fn "$f" '/^_lock(){/,/^}/p'
    echo '_lock'
  } > "$WORK/d2.sh"
  bash "$WORK/d2.sh" 2>/dev/null
}
r_new="$(drv_lock_reason "$NEW")"; r_old="$(drv_lock_reason "$OLD")"
if grep -q '系统给出的原因' <<<"$r_new" && [[ -n "$(sed -n 's/.*系统给出的原因: //p' <<<"$r_new")" ]]; then
  ok "锁打不开时报出了系统给的真实原因(不是只说一句「不可用」)"
else
  bad "锁打不开却没带出原因: $(tr '\n' ' ' <<<"$r_new" | cut -c1-120)"
fi
ctl "$(grep -c '系统给出的原因' <<<"$r_new")" "$(grep -c '系统给出的原因' <<<"$r_old")" \
    "旧版只说「锁文件不可用」, 不给原因"

# ══ 二、_snap_meta_commit(): 只认真正的提交哈希 ═══════════════════════════════
# 这个值会被原样交给 `git reset --hard`。_snap_meta_write 在读不到仓库时写的是字面量
# "unknown" —— 放它过去, 回滚就会拿一个不存在的 ref 去复位, 失败信息还与真实原因无关。
eval "$(fn "$NEW" '/^_snap_meta_commit(){/,/^}/p')"
mk(){ local d="$WORK/s$1"; mkdir -p "$d"; printf '%s' "$2" > "$d/snapshot.json"; echo "$d"; }
SHA=0123456789abcdef0123456789abcdef01234567
[[ "$(_snap_meta_commit "$(mk 1 "{\"git_commit\":\"$SHA\"}")")" == "$SHA" ]] \
  && ok "合法哈希被读出" || bad "读不出合法的 git_commit"
[[ -z "$(_snap_meta_commit "$(mk 2 '{"git_commit":"unknown"}')")" ]] \
  && ok "字面量 unknown 被挡住(不会拿它去 git reset)" || bad "unknown 被当成提交放行了"
[[ -z "$(_snap_meta_commit "$(mk 3 '{"git_commit":"; rm -rf /"}')")" ]] \
  && ok "非哈希内容被挡住" || bad "非哈希内容被放行"
[[ -z "$(_snap_meta_commit "$(mk 4 'not json at all')")" ]] \
  && ok "元数据损坏 → 空(不报错、不挡住回滚)" || bad "元数据损坏时行为不对"
[[ -z "$(_snap_meta_commit "$WORK/nonexistent")" ]] \
  && ok "老快照没有 snapshot.json → 空(正常的跨版本形态)" || bad "缺元数据时行为不对"

# ══ 三、migrate_health_timer 的 _restore: start 之前要清 start-limit ══════════
# 会走到这条回滚路径的现场, 往往正是 unit 反复起不来 —— 那时它已经 start-limit-hit,
# `systemctl start` 必然失败, 一个**本来能恢复**的现场被记成"回滚不完整"。
drv_restore(){                          # 打印 systemctl 的调用序列 + 是否报了"回滚不完整"
  local f="$1"
  { echo 'T=pdg-health.timer; cur="'"$WORK"'/t.unit"; bak="'"$WORK"'/t.bak"; had=1; mode=""; own=""'
    echo 'en0=disabled; ac0=active'
    echo ': > "$cur"; : > "$bak"'
    echo 'c_y(){ echo "CY:$*"; }'
    # start 只在**它前面出现过 reset-failed** 时才成功 —— 模拟 start-limit-hit 的真实形态。
    echo 'systemctl(){ echo "SC:$*" >> "'"$WORK"'/calls";'
    echo '  case "$1" in start) grep -q "SC:reset-failed" "'"$WORK"'/calls" || return 1;; esac; return 0; }'
    fn "$f" '/^  _restore(){/,/^  }/p'
    echo '_restore'
  } > "$WORK/d3.sh"
  : > "$WORK/calls"
  bash "$WORK/d3.sh" 2>&1
  echo "---CALLS---"; cat "$WORK/calls"
}
o_new="$(drv_restore "$NEW")"; o_old="$(drv_restore "$OLD")"
if grep -q 'SC:reset-failed pdg-health.timer' <<<"$o_new"; then
  ok "_restore 在 start 之前调了 reset-failed"
else
  bad "_restore 没有清 start-limit —— 反复起不来的现场会被误记成「回滚不完整」"
fi
if grep -q 'CY:.*回滚.*不完整' <<<"$o_new"; then
  bad "start-limit 现场下 _restore 仍判「回滚不完整」—— 修复没生效"
else
  ok "start-limit 现场下 _restore 能把 unit 拉回 active, 不再误报不完整"
fi
ctl "$(grep -c 'CY:.*不完整' <<<"$o_new")" "$(grep -c 'CY:.*不完整' <<<"$o_old")" \
    "旧版在同一现场确实误报了「回滚不完整」"

# ══ 四、cmd_update 的「已是最新」短路 ════════════════════════════════════════
# 判别力全在**有没有真的跳过副作用**上: 只看它打印了什么, 改坏成"打印后照跑"也能骗过去。
# 所以桩把 cmd_snapshot 记成一次调用 —— 短路成立时它必须是 0 次。
mkrepo(){                               # $1=HEAD 是否落在最新 tag 上; 打印仓库路径
  local d="$WORK/repo$1"; rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null    # init 不动 ref, 也没法走 e2e_git(它要求目标已是仓库)
  e2e_git "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
  # 用**附注** tag: 轻量 tag 的对象哈希就是提交, 少写 `^{commit}` 也能碰巧相等 ——
  # 那样这一格就测不出真正的错误形态了。
  e2e_git "$d" -c user.email=t@t -c user.name=t tag -a v9.9.9 -m r 2>/dev/null
  [[ "$1" == "behind" ]] && e2e_git "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
  echo "$d"
}
drv_update(){                           # $1=pdg.sh $2=仓库 → 输出 + 副作用记录
  local f="$1" r="$2"
  { echo 'REPO_DIR="'"$r"'"'
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }'
    echo 'need_root(){ :; }; _lock(){ :; }'
    echo 'pdg_fetch_release_tags(){ return 0; }'
    echo 'cmd_snapshot(){ echo SNAPSHOT-RAN >> "'"$WORK"'/eff"; return 1; }'   # 真跑到就留痕
    fn "$f" '/^cmd_update(){/,/^}/p'
    echo 'cmd_update; echo "RC=$?"'
  } > "$WORK/d4.sh"
  : > "$WORK/eff"
  bash "$WORK/d4.sh" 2>&1
  echo "---EFF---"; cat "$WORK/eff"
}
u_new="$(drv_update "$NEW" "$(mkrepo latest)")"
u_old="$(drv_update "$OLD" "$(mkrepo latest)")"
if grep -q 'RC=0' <<<"$u_new" && ! grep -q 'SNAPSHOT-RAN' <<<"$u_new"; then
  ok "HEAD 已在最新 tag 上 → 返回 0 且**没有**建快照(副作用真的跳过了)"
else
  bad "短路没生效: $(grep -E 'RC=|SNAPSHOT' <<<"$u_new" | tr '\n' ' ')"
fi
grep -q '已是最新发布 v9.9.9' <<<"$u_new" \
  && ok "短路时点名了版本号(用户知道停在哪一版)" || bad "短路没说停在哪一版"
grep -q 'PDG_UPDATE_FORCE' <<<"$u_new" \
  && ok "给出了强制重装同一版本的出口" || bad "没给强制重装的出口 —— 修复路径被堵死"
ctl "$(grep -c 'SNAPSHOT-RAN' <<<"$u_new")" "$(grep -c 'SNAPSHOT-RAN' <<<"$u_old")" \
    "旧版在同样的「已是最新」现场照样建了快照"

# ── 反向格: 落后一个提交时**必须**照常走全程 ──
# 少了这一格, 把短路写成"无条件 return 0"也能全绿, 而那会让 pdg update 彻底失效。
u_behind="$(drv_update "$NEW" "$(mkrepo behind)")"
grep -q 'SNAPSHOT-RAN' <<<"$u_behind" \
  && ok "反向格: HEAD 落后于最新 tag → 照常进入快照流程(短路没有误伤真更新)" \
  || bad "落后时也被短路了 —— pdg update 会彻底失效: $(tr '\n' ' ' <<<"$u_behind" | cut -c1-140)"

# ── 工作树脏时不许短路: 那正是要靠 pdg update 修回来的场合 ──
dirty="$(mkrepo latest)"; echo x > "$dirty/dirty.txt"
e2e_git "$dirty" -c user.email=t@t -c user.name=t add dirty.txt 2>/dev/null
e2e_git "$dirty" -c user.email=t@t -c user.name=t commit -q -m d 2>/dev/null
e2e_git "$dirty" -c user.email=t@t -c user.name=t tag -f -a v9.9.9 -m r 2>/dev/null
echo "tampered" > "$dirty/dirty.txt"
u_dirty="$(drv_update "$NEW" "$dirty")"
grep -q 'SNAPSHOT-RAN' <<<"$u_dirty" \
  && ok "工作树被改脏 → 不短路(修复路径保持可用)" \
  || bad "工作树脏也短路了 —— 手改坏仓库后 pdg update 修不回来"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

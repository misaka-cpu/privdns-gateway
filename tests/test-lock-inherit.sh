#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 全局锁的继承与复用 —— 八格安全矩阵。
#
# 背景: cmd_update 全程持锁, 中途要用**刚装好的新脚本**跑一次迁移
# (`bash /usr/local/bin/pdg __migrate`)。子进程若重新 open 锁文件, 得到的是一个新的
# open file description, 它并不持有那把锁 —— flock 于是撞上父进程自己, 迁移当场退出,
# 更新回滚。v1.7.8 → v1.8.0 首次启用救援平面的用户踩的就是这条。
#
# 修法是"认继承来的那把锁", 而认错的代价是把并发保护整个拆掉。所以判据必须严:
#   · 不能只看 fd 号在不在  —— fd 9 可能是任何东西;
#   · 不能只比路径字符串    —— /proc 里的路径可以是符号链接、可以被 bind mount 换掉,
#                              文件也可能被删了重建;
#   · 不能信环境变量        —— 任何人都能 `PDG_LOCKED=1 pdg update`;
#   · 必须在那个 fd 上**真跑一次非阻塞 flock** —— 同一个 OFD 已持锁时成功, 别人持锁时失败。
#     这一步才是凭据, 前面几步只是防止认错文件。
#
# 这里跑的是**从 pdg.sh 抽出来的真函数**(不是复刻一份), 锁是**真 flock 真文件**(打了桩
# 这条 bug 就消失了)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deploy/bot/pdg.sh"

PASS=0; FAIL=0
ok(){ echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

command -v flock >/dev/null || { echo "[SKIP] 无 flock"; exit 0; }

BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
LOCKF="$BOX/pdg.lock"; : > "$LOCKF"

# ── 把真函数抽出来 ──────────────────────────────────────────────────────────
# 抽的是源码本身。复刻一份等于"测我自己写的第二份实现", 生产改了这里不会知道。
# 连**顶层那行 `PDG_LOCKED=""`** 一起抽 —— 它不是可有可无的初始化, 而是"绝不接受从环境
# 继承的已持锁"这条纪律本身。手写一份等于把被测对象换成我自己写的那份。
grep -E '^PDG_LOCKED=""' "$SRC" > "$BOX/fn.sh"
awk '/^_lock_inherited\(\)\{/,/^\}/' "$SRC" >> "$BOX/fn.sh"
awk '/^_lock\(\)\{/,/^\}/'          "$SRC" >> "$BOX/fn.sh"
{ [[ -s "$BOX/fn.sh" ]] && grep -q '_lock_inherited' "$BOX/fn.sh" \
  && grep -q '^PDG_LOCKED=""' "$BOX/fn.sh"; } \
  && ok "从 pdg.sh 抽到了 PDG_LOCKED 复位 + _lock + _lock_inherited(测的是生产代码本身)" \
  || { bad "抽不到锁函数 —— 判据无从谈起"; echo "通过 $PASS, 失败 $FAIL"; exit 1; }

# 被测脚本: 加载真函数, 调 _lock, 报结果。LOCK 由环境注入(生产里就是 PDG_LOCKFILE)。
cat > "$BOX/try.sh" <<'T'
set -u
LOCK="$PDG_LOCKFILE"
source "$FN"
_lock
echo "LOCKED=$PDG_LOCKED"
T

_try(){ FN="$BOX/fn.sh" PDG_LOCKFILE="$LOCKF" bash "$BOX/try.sh" 2>&1; }

# 造一个"别人正持着锁"的现场, 并且**能确定地放掉**。
# 不用 `( … sleep 8 ) & kill $!`: kill 打的是子 shell, 那个 sleep 会活下来并继续攥着 fd 9,
# 于是后面的用例莫名其妙取不到锁 —— 排查半天发现是夹具自己没撒手。改成盯一个标记文件:
# 删掉标记 = 松手, wait 回来就一定放干净了。
_hold_start(){
  : > "$BOX/holding"
  ( exec 9>"$LOCKF"; flock -n 9 || exit 1; : > "$BOX/held"
    while [[ -e "$BOX/holding" ]]; do sleep 0.05; done ) &
  HOLDER=$!
  local i=0; while [[ ! -e "$BOX/held" && $i -lt 100 ]]; do sleep 0.05; i=$((i+1)); done
  [[ -e "$BOX/held" ]] || bad "夹具: 造不出'别人持锁'的现场"
}
_hold_stop(){ rm -f "$BOX/holding"; wait "$HOLDER" 2>/dev/null; rm -f "$BOX/held"; }

# ═══ 1. 父持锁, 子继承正确 fd → 复用同一把, 成功 ════════════════════════════
cat > "$BOX/parent.sh" <<'P'
set -u
exec 9>"$PDG_LOCKFILE"
flock -n 9 || { echo "PARENT-FAILED"; exit 9; }
FN="$FN" PDG_LOCKFILE="$PDG_LOCKFILE" bash "$TRY"; echo "RC=$?"
P
out="$(FN="$BOX/fn.sh" TRY="$BOX/try.sh" PDG_LOCKFILE="$LOCKF" bash "$BOX/parent.sh" 2>&1)"
{ grep -q 'LOCKED=1' <<<"$out" && grep -q 'RC=0' <<<"$out"; } \
  && ok "1. 父持锁 + 子继承同一 fd → 子取锁成功(复用, 不重开)" \
  || bad "1. 继承锁没被复用: $out"
grep -q '已有 pdg 操作在运行' <<<"$out" \
  && bad "1b. 子进程报了 BUSY(说明还是重新 open 了)" || ok "1b. 子进程没有报 BUSY"

# ═══ 2. 没有父锁 → 独立进程自己取得锁 ═══════════════════════════════════════
out="$(setsid bash -c "exec 9<&-; FN='$BOX/fn.sh' PDG_LOCKFILE='$LOCKF' bash '$BOX/try.sh'" 2>&1)"
grep -q 'LOCKED=1' <<<"$out" && ok "2. 无父锁时独立进程自己取到锁" || bad "2. 独立取锁失败: $out"

# ═══ 3. 另一个进程持锁 → 独立进程返回 BUSY 且退出码非零 ═════════════════════
_hold_start
out="$(setsid bash -c "exec 9<&-; FN='$BOX/fn.sh' PDG_LOCKFILE='$LOCKF' bash '$BOX/try.sh'" 2>&1)"; rc=$?
{ [[ "$rc" != 0 ]] && grep -q '已有 pdg 操作在运行' <<<"$out"; } \
  && ok "3. 别人持锁时独立进程被挡住并报 BUSY(rc=$rc)" || bad "3. 竟然拿到了锁(rc=$rc): $out"

# ═══ 7. 迁移期间, Bot / CLI 的写操作同样被挡住 ══════════════════════════════
# 与 3 同一把锁, 但换一个"别的调用方"的身份跑一遍 —— 这条要证的是"锁是全局的",
# 不是"__migrate 自己跟自己排队"。
out="$(setsid bash -c "exec 9<&-; FN='$BOX/fn.sh' PDG_LOCKFILE='$LOCKF' bash '$BOX/try.sh'" 2>&1)"; rc7=$?
{ [[ "$rc7" != 0 ]] && grep -q '已有 pdg 操作在运行' <<<"$out"; } \
  && ok "7. 迁移持锁期间, 另一路写操作(Bot/CLI)同样被挡住" || bad "7. 并发写没被挡: $out"
_hold_stop

# ═══ 4. 伪造"已持锁"的环境变量绕不过去 ══════════════════════════════════════
# 有人 export PDG_LOCKED=1 就能跳过上锁的话, 一句话就把并发保护整个关掉了。
_hold_start
out="$(setsid env PDG_LOCKED=1 bash -c "exec 9<&-; FN='$BOX/fn.sh' PDG_LOCKFILE='$LOCKF' bash '$BOX/try.sh'" 2>&1)"; rc=$?
{ [[ "$rc" != 0 ]] && grep -q '已有 pdg 操作在运行' <<<"$out"; } \
  && ok "4. PDG_LOCKED=1 伪造不了持锁(仍走真 flock 并被挡住)" \
  || bad "4. 环境变量绕过了上锁(rc=$rc): $out"
# 生产脚本必须在**顶层无条件清空**这个变量, 而不是靠调用方自觉
grep -qE '^PDG_LOCKED=""' "$SRC" \
  && ok "4b. pdg.sh 顶层无条件把 PDG_LOCKED 清空(不接受从环境继承)" \
  || bad "4b. pdg.sh 没有清空 PDG_LOCKED"

# ═══ 5. fd 9 指向**别的文件** → 不能被当成继承锁 ════════════════════════════
# 这是最危险的误判: 认了它, 就等于在别人持锁时也放行, 两个进程同时改配置。
OTHER="$BOX/other.file"; : > "$OTHER"
cat > "$BOX/parent-other.sh" <<'P'
set -u
exec 9>"$OTHER"           # fd 9 开着, 但指的不是锁文件
flock -n 9 || true
FN="$FN" PDG_LOCKFILE="$PDG_LOCKFILE" bash "$TRY"; echo "RC=$?"
P
out="$(OTHER="$OTHER" FN="$BOX/fn.sh" TRY="$BOX/try.sh" PDG_LOCKFILE="$LOCKF" \
       bash "$BOX/parent-other.sh" 2>&1)"; rc=$?
{ grep -q '已有 pdg 操作在运行' <<<"$out"; } \
  && ok "5. fd 9 指向别的文件时不被认作继承锁(仍去抢真锁, 被挡住)" \
  || bad "5. 认错了文件, 把无关 fd 当成了锁: $out"
_hold_stop

# ═══ 6. 锁文件 inode 变了(被删了重建)→ 继承的 fd 不能复用 ═══════════════════
# 现场形态: 有人 rm 了锁文件, 别的进程又建了一个同名的新文件并锁上。此时继承来的 fd 指的
# 是**旧 inode**, 在它上面 flock 成功也保护不了任何人 —— 路径相同, 但已经不是同一把锁了。
cat > "$BOX/parent-inode.sh" <<'P'
set -u
exec 9>"$PDG_LOCKFILE"
flock -n 9 || { echo "PARENT-FAILED"; exit 9; }
rm -f "$PDG_LOCKFILE"; : > "$PDG_LOCKFILE"      # 同名, 新 inode
FN="$FN" PDG_LOCKFILE="$PDG_LOCKFILE" bash "$TRY"; echo "RC=$?"
P
out="$(FN="$BOX/fn.sh" TRY="$BOX/try.sh" PDG_LOCKFILE="$LOCKF" bash "$BOX/parent-inode.sh" 2>&1)"
# 新 inode 上没人持锁, 所以子进程应当**重新开、自己抢**并成功 —— 关键是它不能拿旧 fd 蒙混。
# 判据: 继承判定必须落空(旧 fd 的 inode 与 $LOCK 现在的 inode 不同)。
cat > "$BOX/inode-probe.sh" <<'P'
set -u
LOCK="$PDG_LOCKFILE"
source "$FN"
exec 9>"$LOCK"
flock -n 9 || exit 9
rm -f "$LOCK"; : > "$LOCK"
_lock_inherited && echo "INHERIT=yes" || echo "INHERIT=no"
P
probe="$(FN="$BOX/fn.sh" PDG_LOCKFILE="$LOCKF" bash "$BOX/inode-probe.sh" 2>&1)"
grep -q 'INHERIT=no' <<<"$probe" \
  && ok "6. 锁文件 inode 变了之后, 继承的 fd 不再被认作那把锁" \
  || bad "6. inode 已变却仍复用旧 fd: $probe"
: > "$LOCKF"

# ═══ 6b. 判据里确实核了设备号+inode, 而且确实真跑了 flock ═══════════════════
# 光看行为不够: 少了 dev/inode 核对而恰好行为一致的实现也能蒙混过去。这两条钉住实现形态。
grep -q "stat -Lc '%d:%i'" "$SRC" \
  && ok "6b. 判据用设备号+inode 核对(不是比路径字符串)" || bad "6b. 没有 dev/inode 核对"
sed -n '/^_lock_inherited(){/,/^}/p' "$SRC" | grep -q 'flock -n 9' \
  && ok "6c. 继承判定里对那个 fd 真跑了非阻塞 flock(不是只看 fd 存在)" \
  || bad "6c. 没有对继承 fd 做真实 flock 验证"

# ═══ 8. 迁移结束后锁正确释放, 没有残留进程或 fd ═════════════════════════════
out="$(FN="$BOX/fn.sh" TRY="$BOX/try.sh" PDG_LOCKFILE="$LOCKF" bash "$BOX/parent.sh" 2>&1)"
sleep 0.3
if ( exec 9>"$LOCKF"; flock -n 9 ); then
  ok "8. 父子都退出后锁已释放(新进程立刻能取到)"
else
  bad "8. 锁没释放, 还被谁攥着"
fi
held="$(fuser "$LOCKF" 2>/dev/null | tr -d ' ')"
[[ -z "$held" ]] && ok "8b. 锁文件上没有残留的持有进程" || bad "8b. 残留持有者: $held"

# ═══ 9. 分派入口显式上锁 ════════════════════════════════════════════════════
# "反正下游某个函数会锁"是靠不住的: 哪天某条迁移路径不再调 _rescue_enable, 整个迁移就
# 裸奔了, 而且不会有任何报错。
sed -n '/^  __migrate)/p' "$SRC" | grep -q '_lock' \
  && ok "9. __migrate 分派入口显式 _lock(不靠下游函数顺手上锁)" \
  || bad "9. __migrate 入口没有显式上锁: $(sed -n '/^  __migrate)/p' "$SRC")"
# 并且父更新进程在调 __migrate 之前**不许**放锁
sed -n '/^cmd_update(){/,/^}/p' "$SRC" | grep -n 'exec 9>&-\|flock -u' \
  && bad "10. cmd_update 在调 __migrate 前放掉了锁" \
  || ok "10. cmd_update 全程持锁, 调 __migrate 之前没有释放"

echo "────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

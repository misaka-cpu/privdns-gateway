#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役 · 配置锁交接。
#
# `pdg update` **全程持着** /run/privdns-gateway.lock, 中途用刚装好的新脚本跑一次
# `bash /usr/local/bin/pdg __migrate`。于是 migrate_wloc_retire 以及它里面那次
# `python3 -c 'iosstate.migrate_schema()'` 都跑在**父进程的锁里面**。
#
# 子进程如果照常去 `flock` 同一个文件, 拿到的是一个新的 open file description —— 它不持有
# 那把锁, 于是撞上父进程自己, 每次都 TxBusy。v1.7.1 就是这么把整次更新回滚掉的, 而
# `update` 还报成功, 只有 doctor 那条告警露了馅。
#
# 三种绕法全是错的, 这支测试逐条堵死:
#   · 无条件 lock=False   → 并发保护整个没了(第三方 CLI/Bot 此刻照样能写);
#   · 中途 LOCK_UN 释放   → 释放的是**父进程那把**(同一个 OFD), 窗口期里谁都能进来;
#   · "信任调用方说已锁"  → 说了不算, 必须**在那个 fd 上真跑一次非阻塞 flock**当凭据。
#
# 判据沿真实路径走: 起一个持锁的 bash 父进程(与 _lock 同形态: exec 9>LOCK; flock -n 9),
# 由它调**真的** migrate_wloc_retire → _retire_ios_schema → 真的 iosstate.migrate_schema。
# 不抽 Python 函数单跑, 也不打桩绕开锁。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/helpers/wloc-retire-sandbox.sh
source "$HERE/helpers/wloc-retire-sandbox.sh"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 颜色输出函数**从产品文件里抽出来用**, 测试不提供替代实现。
# 这三行以前是 `c_g(){ :; }; c_y(){ :; }; c_r(){ :; }` —— 而生产里压根没有 c_r,
# 于是测试替生产补了一个它没有的函数, WLOC 退役的拒绝/失败路径在测试里永远不报错(假绿)。
# 生产里缺哪一个, 这里就缺哪一个; 缺失的后果由 tests/test-wloc-retire-error-reporting.sh
# 用具名行为断言钉住(标题在不在), 不靠静态检查。
for _f in c_g c_y c_r; do
  eval "$(grep -m1 -E "^$_f\(\)\{.*\}[[:space:]]*\$" "$ROOT/deploy/bot/pdg.sh")"
done
unset _f

# 抽出被测函数。**只抽 shell 侧**: Python 那一半必须是真模块, 否则这支测试什么都证明不了。
eval "$(sed -n '/^_retire_ios_schema(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
if ! declare -F _retire_ios_schema >/dev/null; then
  bad "pdg.sh 里抽不出 _retire_ios_schema"
  echo "[SUM] OK=$pass FAIL=$nfail"; exit 1
fi

# ── 探针: 一个**没有继承 fd** 的第三方去抢锁。抢到 = 那一刻锁是松的。 ─────────
probe_can_lock(){  # 0 = 抢到了(说明锁没被持住)
  flock -n "$PDG_LOCKFILE" -c true 2>/dev/null
}

run_under_cli_lock(){   # 在"CLI 已持锁"的形态下跑 $@
  ( exec 9>"$PDG_LOCKFILE"
    flock -n 9 || { echo "夹具自身取锁失败"; exit 99; }
    "$@" )
}

# ══ 1. CLI 持锁时: 迁移必须成功, 不许 TxBusy ════════════════════════════════
echo "══ 1. CLI 持锁 → 真实 __migrate 路径 ══"
for state in "on Home Office" "off Home" "off"; do
  # shellcheck disable=SC2086
  sbox_new && sbox_legacy_ios $state >/dev/null || { bad "沙箱构造失败($state)"; continue; }
  out="$(run_under_cli_lock _retire_ios_schema 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    ok "有旧记录(WLOC=$state): CLI 持锁时迁移成功"
  else
    bad "有旧记录(WLOC=$state): rc=$rc —— $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
  fi
  got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schema"])' \
         "$SBOX/etc/privdns-gateway/ios-profile.json" 2>/dev/null)"
  [[ "$got" == 2 ]] && ok "有旧记录(WLOC=$state): 记录确实迁到了 schema 2" \
    || bad "有旧记录(WLOC=$state): 迁移没落盘(schema=$got)"
  sbox_rm
done

# 没有 iOS 记录的机器: 同样不许因为锁而失败, 也不许凭空造记录
sbox_new || bad "沙箱构造失败"
out="$(run_under_cli_lock _retire_ios_schema 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "没有 iOS 记录: CLI 持锁时同样 rc=0" \
  || bad "没有 iOS 记录: rc=$rc —— $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
[[ ! -e "$SBOX/etc/privdns-gateway/ios-profile.json" ]] \
  && ok "没有 iOS 记录: 迁移没有凭空造出一份(造一份 = 造出第二个身份)" \
  || bad "没有记录却写出了一份记录"
sbox_rm

# ══ 2. 锁不许被中途释放 ════════════════════════════════════════════════════
echo
echo "══ 2. 迁移期间与之后, 第三方都抢不到锁 ══"
sbox_new && sbox_legacy_ios on >/dev/null
# 观察点放在**迁移最吃紧的那一刻**: 记录已经验过、正要落盘。这里若锁是松的, 另一个进程
# 就能在两次写之间插进来。用 hook 观察而不是打桩替换 —— 被测逻辑一行都没被换掉。
PROBE_OUT="$SBOX/probe.txt"
cat > "$SBOX/opt/pdg-bot/_hook.py" <<'PYEOF'
import json, os, subprocess, sys
import iosstate as S

_real_enter = S._Txn.__enter__


def _spy(self):
    # 正要落盘这一刻: 让一个**没有继承 fd** 的第三方去抢锁, 抢到就说明锁被松开过。
    r = subprocess.run(["flock", "-n", os.environ["PDG_LOCKFILE"], "-c", "true"],
                       capture_output=True)
    with open(os.environ["PROBE_OUT"], "a") as f:
        f.write("mid=%d\n" % r.returncode)
    return _real_enter(self)


S._Txn.__enter__ = _spy
try:
    print(json.dumps(S.migrate_schema(), ensure_ascii=False))
except S.StateError as e:
    sys.stderr.write(str(e) + "\n")
    sys.exit(1)
PYEOF
run_under_cli_lock env PROBE_OUT="$PROBE_OUT" \
  bash -c 'cd "$SBOX/opt/pdg-bot" && PYTHONPATH="$SBOX/opt/pdg-bot" python3 _hook.py' >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "带观察钩子的真实迁移仍然成功(钩子只观察, 不替换逻辑)" \
  || bad "带钩子的迁移失败 rc=$rc"
if [[ -s "$PROBE_OUT" ]]; then
  if grep -q 'mid=0' "$PROBE_OUT"; then
    bad "落盘前那一刻第三方抢到了锁 —— 锁被中途释放了"
  else
    ok "落盘前那一刻第三方抢不到锁(锁始终在父进程手里, 没有被释放过)"
  fi
else
  bad "观察钩子没被调用到 —— 这一格什么都没测到"
fi
sbox_rm

# ══ 3. 没有继承锁时: 自己去取 ══════════════════════════════════════════════
echo
echo "══ 3. 直接 pdg __migrate(外层没有 update 持锁)══"
sbox_new && sbox_legacy_ios off >/dev/null
out="$(_retire_ios_schema 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "没有外层锁: 迁移自己取锁并成功" \
  || bad "没有外层锁却失败了 rc=$rc —— $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
probe_can_lock && ok "跑完之后锁已释放(自己取的锁要自己还)" || bad "自己取的锁没还回去"
sbox_rm

# ══ 4. 锁真在别人手里: 必须拒绝, 不许硬闯 ══════════════════════════════════
echo
echo "══ 4. 锁被**别的进程**占着 ══"
sbox_new && sbox_legacy_ios off >/dev/null
before="$(sha256sum "$SBOX/etc/privdns-gateway/ios-profile.json" | cut -d' ' -f1)"
# 另一个进程持锁, 且**不把 fd 传给我们** —— 这正是"别人正在改配置"的真实形态
flock -n "$PDG_LOCKFILE" -c 'sleep 6' &
holder=$!
sleep 0.4
out="$(_retire_ios_schema 2>&1)"; rc=$?
wait "$holder" 2>/dev/null
[[ $rc -ne 0 ]] && ok "锁在别人手里 → 拒绝执行(rc=$rc)" \
  || bad "锁在别人手里却照样迁移了 —— 并发保护没了"
[[ "$(sha256sum "$SBOX/etc/privdns-gateway/ios-profile.json" | cut -d' ' -f1)" == "$before" ]] \
  && ok "被拒时记录一个字节都没动" || bad "拒绝了却改了记录"
sbox_rm

# ══ 5. 撤销修复对照: 关掉继承锁识别, 第 1 格必须转红 ════════════════════════
echo
echo "══ 5. 撤销修复对照 ══"
# 这一格证明上面第 1 格**有牙**: 把继承锁识别关掉(PDG_LOCK_FD=none), CLI 持锁时就该失败。
# 没有它的话, "实现根本没做继承锁, 只是碰巧没锁" 也会让第 1 格绿。
sbox_new && sbox_legacy_ios off >/dev/null
out="$(PDG_LOCK_FD=none run_under_cli_lock _retire_ios_schema 2>&1)"; rc=$?
if [[ $rc -ne 0 ]]; then
  ok "关掉继承锁识别后, CLI 持锁时迁移确实失败 —— 第 1 格不是碰巧绿的"
else
  bad "关掉继承锁识别后仍然成功 —— 说明根本没在抢那把锁, 第 1 格没有牙"
fi
sbox_rm

echo
echo "[SUM] OK=$pass FAIL=$nfail"
[[ $nfail -eq 0 ]]

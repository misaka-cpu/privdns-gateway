#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 门三(反代出站白名单)的**真 nft 行为验证** —— 本地门, 不进 CI。
#
# 为什么不进 CI: 加载 nft 规则要 NET_ADMIN, GitHub Actions 的 job 容器没有这个 cap。
# 实测过, 连 `nft -c -f`(只校验不加载)都会停在 `cache initialization failed:
# Operation not permitted`。所以 CI 里只能验生成出来的**文本结构**
# (tests/test-lanpanel.py 第 ⑭ 组), 规则到底挡不挡得住必须在有权限的地方跑。
#
# 三路探测, 第三路是**标定**:
#   A 白名单内的端口, 以反代 uid 连 → 该是 Connection refused(防火墙放行了, 只是没人监听)
#   B 白名单外的端口, 以反代 uid 连 → 该是 EHOSTUNREACH(被 admin-prohibited 拒了)
#   C 与 B 完全相同的连接, 换 root 连 → 该是 Connection refused
#
# 没有 C 就证明不了 B: B 失败也可能是环境本来就不通。C 一旦和 B 一样, 说明这次
# 测量里 uid 判据根本没起作用, 整轮结果作废。
#
# 跑法(需要 root + NET_ADMIN, 建议在一次性容器里):
#   sudo bash tests/negctl/lan-egress-live.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
USER_NAME="pdg-lan-negctl"
# 探测目标取默认路由的下一跳 —— 容器/虚机里都存在, 且几乎不会真有人监听这两个高位端口。
PEER="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
PORT_OK=9101
PORT_NO=9102
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── 前置: 没权限就**明确失败**, 不静默跳过 ──────────────────────────────────
# 跳过是本项目明确不接受的形态: 一支永远跳过的测试和没写是一回事, 而它在汇总里
# 看起来是绿的。
[ "$(id -u)" -eq 0 ] || { echo "[SKIP-FATAL] 要 root 才能加载 nft 规则"; exit 2; }
command -v nft >/dev/null 2>&1 || { echo "[SKIP-FATAL] 没装 nft"; exit 2; }
[ -n "$PEER" ] || { echo "[SKIP-FATAL] 取不到默认路由下一跳, 没有可用的探测目标"; exit 2; }
nft list tables >/dev/null 2>&1 || { echo "[SKIP-FATAL] nft 用不了(多半缺 NET_ADMIN)"; exit 2; }

id "$USER_NAME" >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin "$USER_NAME"

TABLE="$(python3 - "$ROOT" "$USER_NAME" "$PEER" "$PORT_OK" <<'PY'
import importlib.util, sys, json
root, uid, peer, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
spec = importlib.util.spec_from_file_location("lp", root + "/deploy/bot/lanpanel.py")
lp = importlib.util.module_from_spec(spec); spec.loader.exec_module(lp)
cfg = {"panels": [{"name": "negctl", "host": "negctl.example.com",
                   "target": "http://%s:%d" % (peer, port)}]}
sys.stdout.write(lp.render_nft(cfg, uid))
PY
)"
[ -n "$TABLE" ] || { echo "[FAIL] 生成不出规则"; exit 1; }

TMP="$(mktemp)"; printf '%s' "$TABLE" > "$TMP"
cleanup(){ nft delete table inet pdglan 2>/dev/null; userdel "$USER_NAME" 2>/dev/null; rm -f "$TMP"; }
trap cleanup EXIT

nft -f "$TMP" || { echo "[FAIL] 规则加载失败"; exit 1; }

probe(){    # $1=端口 → 打印 errno 名
  python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(4)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("CONNECTED")
except OSError as e:
    print(getattr(e, "errno", "?"))
' "$PEER" "$1"
}

A="$(su -s /bin/bash "$USER_NAME" -c "$(declare -f probe); PEER=$PEER probe $PORT_OK")"
B="$(su -s /bin/bash "$USER_NAME" -c "$(declare -f probe); PEER=$PEER probe $PORT_NO")"
C="$(probe "$PORT_NO")"

echo "  A(白名单内, $USER_NAME) = $A"
echo "  B(白名单外, $USER_NAME) = $B"
echo "  C(白名单外, root 标定)  = $C"

# ── 标定先判: C 不成立就整轮作废 ────────────────────────────────────────────
if [ "$C" = "113" ]; then
  bad "标定失效: root 连白名单外的端口也不通($C) —— 这次测量里 uid 判据没起作用, B 的结果无意义"
  echo "汇总: 通过 $PASS, 失败 $FAIL"; exit 1
else
  ok "标定成立: 换 uid 就能连出去($C), 说明拦截确实来自 uid 判据"
fi

[ "$A" = "111" ] && ok "白名单内放行(ECONNREFUSED = 防火墙没挡, 只是没人监听)" \
                 || bad "白名单内应为 111(ECONNREFUSED), 实际 $A"
[ "$B" = "113" ] && ok "白名单外被拒(EHOSTUNREACH = admin-prohibited)" \
                 || bad "白名单外应为 113(EHOSTUNREACH), 实际 $B"

echo "汇总: 通过 $PASS, 失败 $FAIL"
[ "$FAIL" -eq 0 ]

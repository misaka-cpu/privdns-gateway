#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 救援平面常量的**单一事实源**守卫(5.2/T4)。
#
# 端口要同时出现在 nftables 模板、systemd socket、doctor 端口文案与敏感端口集、老机器迁移
# 与文档里。各处各写一遍字面量, 改端口时漏一处的下场是: 防火墙放行 A、服务监听 B、页面打不开,
# 而 doctor 检查的是它自己那第三份硬编码 —— 一切报绿。
#
# 这里验的是真实行为, 不是"文件里有没有这个词":
#   · bash 侧与 python 侧读出来的端口必须**逐字节相同**(两边真的跑一遍);
#   · 除单一事实源之外, 全仓不许出现该端口的字面量;
#   · 常量文件缺失时 python 侧必须**抛错**, 不许回落到猜测值。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

LIB="$ROOT/lib/rescue.sh"
CONST="$ROOT/deploy/bot/rescue_const.py"

# ── 1. 单一事实源存在且能被 source ──
if [[ -f "$LIB" ]]; then ok "lib/rescue.sh 存在"; else bad "缺少 lib/rescue.sh"; fi
# shellcheck source=lib/rescue.sh
if source "$LIB" 2>/dev/null; then ok "lib/rescue.sh 可被 source"; else bad "source lib/rescue.sh 失败"; fi
PORT="${PDG_RESCUE_PORT:-}"
if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
  ok "bash 侧读到合法端口: $PORT"
else
  bad "bash 侧端口不合法: [$PORT]"
fi

# ── 2. python 侧与 bash 侧必须一致(真的各跑一遍, 不比对源码文本) ──
PYPORT="$(env -u PDG_RESCUE_PORT python3 "$CONST" --port 2>&1)"
if [[ "$PYPORT" == "$PORT" ]]; then
  ok "python 侧与 bash 侧端口一致($PYPORT)"
else
  bad "两侧端口不一致: bash=$PORT python=$PYPORT"
fi

# ── 3. 常量文件缺失 → python 必须抛错, 不许给默认值 ──
_miss="$(cd /tmp && env -u PDG_RESCUE_PORT PDG_RESCUE_CONST_TEST=1 python3 - "$CONST" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1])
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
rc._CANDIDATES = ("/nonexistent/lib/rescue.sh",)      # 三个候选全部落空
try:
    print("NO-RAISE:", rc.port())
except Exception as e:
    print("RAISED:", type(e).__name__)
PY
)"
if grep -q "^RAISED:" <<<"$_miss"; then
  ok "常量源缺失时 python 侧抛错(不回落猜测值)"
else
  bad "常量源缺失却没抛错: $_miss"
fi

# ── 4. 全仓不许出现端口字面量(单一事实源与本测试自身除外) ──
# 本测试从不写死端口, 用的是 source 出来的 $PORT —— 所以它自己也在扫描范围内。
mapfile -t hits < <(cd "$ROOT" && grep -rn --binary-files=without-match "\b$PORT\b" \
  --exclude-dir=.git --exclude-dir=__pycache__ . 2>/dev/null \
  | grep -v "^./lib/rescue.sh:")
if [[ ${#hits[@]} -eq 0 ]]; then
  ok "除 lib/rescue.sh 外, 全仓没有端口 $PORT 的字面量"
else
  bad "端口字面量散落在 ${#hits[@]} 处(应改为读常量):"
  printf '       %s\n' "${hits[@]:0:5}"
fi

# ── 5. 路径常量齐全且形态合理 ──
_bad_path=0
for v in PDG_RESCUE_DIR PDG_RESCUE_CERT PDG_RESCUE_KEY PDG_RESCUE_TOKEN PDG_RESCUE_STATE PDG_PROFILE_ENV; do
  [[ "${!v:-}" == /* ]] || { bad "常量 $v 不是绝对路径: [${!v:-}]"; _bad_path=1; }
done
(( _bad_path == 0 )) && ok "六个路径常量都是绝对路径"
# 凭据不许落在 world-readable 的临时区
if [[ "$PDG_RESCUE_TOKEN" == /tmp/* || "$PDG_RESCUE_KEY" == /tmp/* ]]; then
  bad "凭据路径落在 /tmp"
else
  ok "凭据路径不在 /tmp"
fi

# ── 6. python 侧 paths() 与 bash 侧逐项一致 ──
_diff=0
while IFS='=' read -r k v; do
  [[ -n "$k" ]] || continue
  if [[ "${!k:-}" != "$v" ]]; then bad "常量 $k 两侧不一致: bash=${!k:-} python=$v"; _diff=1; fi
done < <(env -u PDG_RESCUE_DIR python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('rc', '$CONST')
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
for k, v in rc.paths().items(): print('%s=%s' % (k, v))
" 2>/dev/null)
(( _diff == 0 )) && ok "六个路径常量两侧逐项一致"

# ── 7. internal_cidr(): 唯一真源是 profile.env, 且读不到返回 None ──
_w="$(mktemp -d)"; trap 'rm -rf "$_w"' EXIT
printf 'PDG_LOWMEM=0\nPDG_INTERNAL_CIDR=172.22.0.0/16\nPDG_PLATFORM=ios\n' > "$_w/profile.env"
_got="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rc', '$CONST')
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
print(rc.internal_cidr('$_w/profile.env'))
print(rc.internal_cidr('$_w/does-not-exist'))
")"
if [[ "$(sed -n 1p <<<"$_got")" == "172.22.0.0/16" ]]; then
  ok "internal_cidr(): 从 profile.env 读出真源值"
else
  bad "internal_cidr() 读错: $(sed -n 1p <<<"$_got")"
fi
if [[ "$(sed -n 2p <<<"$_got")" == "None" ]]; then
  ok "internal_cidr(): profile.env 不存在时返回 None(不猜、不回落 mosdns)"
else
  bad "读不到时没有返回 None: $(sed -n 2p <<<"$_got")"
fi
# 真源缺这个键时也必须是 None —— 不能把"没配"当成"空段"放行
printf 'PDG_LOWMEM=0\n' > "$_w/nokey.env"
_nk="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('rc', '$CONST')
rc = importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
print(rc.internal_cidr('$_w/nokey.env'))
")"
if [[ "$_nk" == "None" ]]; then ok "internal_cidr(): 缺键时返回 None"; else bad "缺键却返回 [$_nk]"; fi

# ── 8. pdg_internal_cidr(bash 侧)同语义 ──
if out="$(pdg_internal_cidr "$_w/profile.env")" && [[ "$out" == "172.22.0.0/16" ]]; then
  ok "bash pdg_internal_cidr(): 读出真源值"
else
  bad "bash pdg_internal_cidr() 读错: [${out:-}]"
fi
if pdg_internal_cidr "$_w/nokey.env" >/dev/null 2>&1; then
  bad "bash pdg_internal_cidr() 缺键时返回了成功"
else
  ok "bash pdg_internal_cidr(): 缺键时返回非 0(调用方能区分'没配'与'空值')"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

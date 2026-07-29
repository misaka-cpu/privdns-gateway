#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# v1.4.x(WLOC 之前)→ 当前版 的 MITM 接管结构升级迁移回归(Item 3)。
#   A. 升级: 老 mosdns 配置(无 force_hijack)→ 迁移补 force_hijack domain_set + force_hijack_seq
#      + internal_sequence 优先级规则(在 geosite_cn 之前)+ 空 mitm_hijack.txt; 迁移后真起 mosdns 通过。
#   B. 幂等: 再跑不变(已有 force_hijack 即退)。
#   C. 自定义配置(无 internal_sequence/ecs_china 锚点)→ 跳过不动。
#   D. 失败还原: 生成阶段失败(锚点不唯一)→ 配置原样还原, 不留半截。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"
WORK="$(mktemp -d)"; PIDS=()
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

# ── 抽取被测迁移函数 + 打桩 ──────────────────────────────────────────────────
c_g(){ :; }; c_y(){ :; }
eval "$(sed -n '/^migrate_mosdns_mitm(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"

# ── 规则 fixture(都在 $WORK/rules, 迁移从 geosite_cn 路径推导目录)──
mkdir -p "$WORK/rules"
echo "qq.com" > "$WORK/rules/geosite_cn.txt"
: > "$WORK/rules/geosite_apple.txt"; : > "$WORK/rules/custom_direct.txt"; : > "$WORK/rules/custom_hijack.txt"; : > "$WORK/rules/ruleset_hijack.txt"; : > "$WORK/rules/unlock.txt"
echo "example.com" > "$WORK/rules/geosite_geolocation-!cn.txt"
# (mitm_hijack.txt 故意不建: 迁移应自动补)

# ── 渲染当前 config → 完整版(v1.5), 端口换高位、去 DoT、rules 指向 $WORK/rules ──
render_full(){
  sed -e "s/__SERVER_IP__/10.9.9.9/g" -e "s#__INTERNAL_CIDR__#127.0.0.0/8#g" -e "s#__CERT_DIR__#$WORK#g" \
      -e "s#__MOSDNS_CACHE__#8192#g" -e "s#__HIJACK_SET_FILE__#geosite_geolocation-!cn.txt#g" \
      -e "s#/etc/mosdns/rules/#$WORK/rules/#g" -e "s#0.0.0.0:53#127.0.0.1:15997#g" \
      -e "/- tag: dot_server/,\$d" "$ROOT/deploy/mosdns/config.yaml"
}
render_full > "$WORK/full.yaml"

# ── 造 v1.4.x fixture: 从完整版剥掉 force_hijack domain_set / force_hijack_seq / 优先级规则 ──
python3 - "$WORK/full.yaml" "$WORK/v14.yaml" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
s = re.sub(r'  - tag: force_hijack\n    type: domain_set\n    args:[^\n]*\n', '', s)
s = re.sub(r'  - tag: force_hijack_seq\n(?:.*\n)*?      - matches: qtype 1\n        exec: black_hole [0-9.]+\n', '', s)
s = re.sub(r'      # MITM 接管域名[^\n]*\n      - matches: qname \$force_hijack\n        exec: goto force_hijack_seq\n', '', s)
open(sys.argv[2], 'w').write(s)
PY
grep -vE '^[[:space:]]*#' "$WORK/v14.yaml" | grep -q 'force_hijack' && bad "v1.4.x fixture 构造失败(仍含 force_hijack)" || ok "构造 v1.4.x fixture(无 force_hijack)"

start_mosdns(){   # 起 mosdns 加载 $1, 成功返回0
  "$MD" start -c "$1" -d "$WORK" > "$WORK/mos.out" 2>&1 & PIDS+=($!)
  local p=$!
  for _ in $(seq 1 30); do
    dig +short +time=1 +tries=1 @127.0.0.1 -p 15997 rdy.test A >/dev/null 2>&1 && return 0
    kill -0 "$p" 2>/dev/null || break
    sleep 0.1
  done
  kill "$p" 2>/dev/null; return 1
}

# ── 取 mosdns ──
if command -v mosdns >/dev/null; then MD="$(command -v mosdns)"; else
  case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) A="";; esac
  if [[ -n "$A" ]] && curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${A}.zip" -o "$WORK/m.zip" 2>/dev/null \
     && pdg_verify_sha256 "$WORK/m.zip" "${PDG_SHA256[mosdns-$A]:-}" mosdns >/dev/null 2>&1 \
     && (cd "$WORK" && unzip -q m.zip); then MD="$WORK/mosdns"; chmod +x "$MD"; fi
fi

# ── A. 升级迁移 ──────────────────────────────────────────────────────────────
cp "$WORK/v14.yaml" "$WORK/mig.yaml"
migrate_mosdns_mitm "$WORK/mig.yaml"
grep -q '  - tag: force_hijack$' "$WORK/mig.yaml" && ok "迁移: 补 force_hijack domain_set" || bad "缺 force_hijack domain_set"
grep -q '  - tag: force_hijack_seq' "$WORK/mig.yaml" && ok "迁移: 补 force_hijack_seq" || bad "缺 force_hijack_seq"
grep -q 'exec: goto force_hijack_seq' "$WORK/mig.yaml" && ok "迁移: 补优先级规则(goto force_hijack_seq)" || bad "缺优先级规则"
[[ -e "$WORK/rules/mitm_hijack.txt" ]] && ok "迁移: 自动补空 mitm_hijack.txt" || bad "未补 mitm_hijack.txt"
# 顺序: force_hijack 规则必须在第一条 geosite_cn 之前
python3 - "$WORK/mig.yaml" <<'PY' && ok "优先级规则在 geosite_cn 之前(CN 判定前强制接管)" || { echo "顺序错"; exit 1; }
import sys
s = open(sys.argv[1]).read()
b = s[s.index('- tag: internal_sequence'):s.index('- tag: main_sequence')]
assert b.index('qname $force_hijack') < b.index('qname $geosite_cn'), '顺序不对'
PY
# 迁移后与完整版结构一致(忽略注释)
diff <(grep -vE '^\s*#' "$WORK/mig.yaml") <(grep -vE '^\s*#' "$WORK/full.yaml") >/dev/null \
  && ok "迁移结果与当前完整版结构一致(byte 对齐, 忽略注释)" || bad "迁移结果与完整版不一致"
# 真起 mosdns 加载迁移后配置
if [[ -n "${MD:-}" ]] && command -v dig >/dev/null; then
  start_mosdns "$WORK/mig.yaml" && ok "迁移后 mosdns 真实加载通过(force_hijack 生效)" \
    || { bad "迁移后 mosdns 加载失败"; sed 's/^/  /' "$WORK/mos.out" | head -5; }
else
  echo "[SKIP] 无 mosdns/dig, 跳过真实加载(结构断言已覆盖)"
fi

# ── B. 幂等 ──────────────────────────────────────────────────────────────────
snap="$(cat "$WORK/mig.yaml")"
migrate_mosdns_mitm "$WORK/mig.yaml"
[[ "$(cat "$WORK/mig.yaml")" == "$snap" ]] && ok "幂等: 二跑不变(已有 force_hijack 即退)" || bad "二跑改动了文件"
[[ "$(grep -c 'tag: force_hijack$' "$WORK/mig.yaml")" == 1 ]] && ok "无重复 force_hijack" || bad "force_hijack 重复"

# ── C. 自定义配置 → 跳过 ──────────────────────────────────────────────────────
printf 'plugins:\n  - tag: foo\n    type: sequence\n    args: []\n' > "$WORK/custom.yaml"
snap="$(cat "$WORK/custom.yaml")"
migrate_mosdns_mitm "$WORK/custom.yaml"
[[ "$(cat "$WORK/custom.yaml")" == "$snap" ]] && ok "自定义配置(无锚点)→ 跳过不动" || bad "误改了自定义配置"

# ── D. 失败还原: 锚点不唯一 → 生成失败, 原样还原 ─────────────────────────────
# 锚点有两条分支: 配置里有明确代理集时用它, 老配置(没有)退回 ecs_china。两条都要验 ——
# 只验一条的话, 另一条分支上"锚点不唯一"会静静地把配置改成半截。
dup_case(){   # $1=用例名 $2=被复制的锚点行 $3=源文件
  local out="$WORK/dup.yaml"
  awk -v a="$2" 'BEGIN{done=0} {print} $0==a && !done{print "    type: ecs_handler"; print "    args: {}"; print a; done=1}' "$3" > "$out"
  [[ "$(grep -c -- "^$2$" "$out")" == 2 ]] || { bad "$1: 构造重复锚点失败"; return; }
  local snap; snap="$(cat "$out")"
  migrate_mosdns_mitm "$out"
  [[ "$(cat "$out")" == "$snap" ]] && ok "$1: 锚点不唯一 → 原样还原(不留半截)" || bad "$1: 失败未还原"
  grep -q 'tag: force_hijack$' "$out" && bad "$1: 失败却注入了 force_hijack" || ok "$1: 未注入 force_hijack"
  rm -f "$WORK"/dup.yaml.premitm.* 2>/dev/null
}
# D1: 有明确代理集 → 锚点是 explicit_proxy
dup_case "锚点=explicit_proxy" "  - tag: explicit_proxy" "$WORK/v14.yaml"
# D2: 老配置(摘掉明确代理集)→ 锚点退回 ecs_china
cp "$WORK/v14.yaml" "$WORK/v14-old.yaml"
python3 "$ROOT/tests/helpers/strip-explicit-proxy.py" "$WORK/v14-old.yaml" || bad "构造老配置失败"
dup_case "锚点=ecs_china(老配置)" "  - tag: ecs_china" "$WORK/v14-old.yaml"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 克制版低内存模式回归(不依赖 CI 主机实际内存, 用 fixture meminfo 注入):
#   A. 解析: 512MB/1GB→低内存, 2GB→标准; 显式 1/0 覆盖; profile 已有则沿用(不重新检测); 持久化。
#   B. 渲染: cache 占位符→2048/8192; journald→20M/50M; helper 值正确。
#   C. 迁移幂等: 旧 mosdns cache 8192 →(低内存)2048; 二跑不变; 用户上游保留; journald 50M→20M。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
eq(){ [[ "$1" == "$2" ]] && ok "$3 ($1)" || bad "$3: 期望 $2 实为 $1"; }

# 抽出低内存整段(LOWMEM_THRESHOLD_KB ... 到 migrate_lowmem 结束, 即 pdg_fetch_release_tags 之前)
sed -n '/^LOWMEM_THRESHOLD_KB=/,/^pdg_fetch_release_tags(){/p' "$ROOT/deploy/bot/pdg.sh" | sed '$d' > "$WORK/lowmem.sh"
cat > "$WORK/harness.sh" <<EOF
c_g(){ :; }; c_y(){ :; }
SVC_STATE=active
systemctl(){ [[ "\$1" == is-active ]] && echo "\$SVC_STATE"; return 0; }
source "$WORK/lowmem.sh"
EOF

mkfix(){ printf 'MemTotal:       %s kB\nMemFree: 1 kB\n' "$1" > "$2"; }
mkfix 512000  "$WORK/mem512"    # ~500 MiB
mkfix 1015000 "$WORK/mem1g"     # ~991 MiB(常见"1GB"VPS)
mkfix 2048000 "$WORK/mem2g"     # 2000 MiB
resolve(){ PDG_MEMINFO="$1" PDG_PROFILE="$2" PDG_LOWMEM="$3" bash -c "source '$WORK/harness.sh'; pdg_lowmem_resolve"; }

# ── A. 解析 ──────────────────────────────────────────────────────────────────
rm -f "$WORK/pa.env"; eq "$(resolve "$WORK/mem512" "$WORK/pa.env" auto)" 1 "512MB auto → 低内存"
rm -f "$WORK/pb.env"; eq "$(resolve "$WORK/mem1g"  "$WORK/pb.env" auto)" 1 "1GB auto → 低内存"
rm -f "$WORK/pc.env"; eq "$(resolve "$WORK/mem2g"  "$WORK/pc.env" auto)" 0 "2GB auto → 标准"
rm -f "$WORK/pd.env"; eq "$(resolve "$WORK/mem2g"  "$WORK/pd.env" 1)"    1 "2GB 显式=1 → 低内存"
rm -f "$WORK/pe.env"; eq "$(resolve "$WORK/mem512" "$WORK/pe.env" 0)"    0 "512MB 显式=0 → 标准"
# 持久化
eq "$(sed -n 's/^PDG_LOWMEM=//p' "$WORK/pa.env")" 1 "持久化写入 profile"
# 沿用: profile 已定=0, 512MB auto 不重新检测 → 仍 0
printf 'PDG_LOWMEM=0\n' > "$WORK/pf.env"
eq "$(resolve "$WORK/mem512" "$WORK/pf.env" auto)" 0 "profile 已定=0, auto 沿用(不重测)"
# 但显式仍可覆盖已定 profile
eq "$(resolve "$WORK/mem512" "$WORK/pf.env" 1)" 1 "显式=1 覆盖已定 profile"

# helper 值
eq "$(bash -c "source '$WORK/harness.sh'; pdg_cache_size 1")" 2048 "低内存 cache=2048"
eq "$(bash -c "source '$WORK/harness.sh'; pdg_cache_size 0")" 8192 "标准 cache=8192"
eq "$(bash -c "source '$WORK/harness.sh'; pdg_journald_max 1")" 20M "低内存 journald=20M"
eq "$(bash -c "source '$WORK/harness.sh'; pdg_journald_max 0")" 50M "标准 journald=50M"

# ── B. 渲染(install 用同款占位符替换)────────────────────────────────────────
sed 's/__MOSDNS_CACHE__/2048/' "$ROOT/deploy/mosdns/config.yaml" | grep -q 'size: 2048' && ok "低内存渲染 cache=2048" || bad "低内存 cache 渲染错"
sed 's/__MOSDNS_CACHE__/8192/' "$ROOT/deploy/mosdns/config.yaml" | grep -q 'size: 8192' && ok "标准渲染 cache=8192" || bad "标准 cache 渲染错"
sed 's/__JOURNALD_MAXUSE__/20M/' "$ROOT/deploy/firewall/journald-50-pdg.conf" | grep -q 'SystemMaxUse=20M' && ok "低内存渲染 journald=20M" || bad "journald 渲染错"
sed 's/__JOURNALD_MAXUSE__/50M/' "$ROOT/deploy/firewall/journald-50-pdg.conf" | grep -q 'SystemMaxUse=50M' && ok "标准渲染 journald=50M" || bad "journald 渲染错"
grep -q '__MOSDNS_CACHE__' "$ROOT/deploy/mosdns/config.yaml" && ok "模板用占位符(未写死)" || bad "模板未用占位符"

# ── C. 迁移(旧装: 已渲染成 8192 的配置 + 50M journald)──────────────────────
sed -e 's/__SERVER_IP__/10.0.0.9/g' -e 's#__INTERNAL_CIDR__#127.0.0.0/8#g' -e 's#__CERT_DIR__#/tmp/c#g' \
    -e 's/__MOSDNS_CACHE__/8192/g' "$ROOT/deploy/mosdns/config.yaml" > "$WORK/mos.yaml"
sed 's/__JOURNALD_MAXUSE__/50M/' "$ROOT/deploy/firewall/journald-50-pdg.conf" > "$WORK/jrnl.conf"
printf 'PDG_LOWMEM=1\n' > "$WORK/prof.env"     # 低内存 profile

run_mig(){ PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem512" bash -c "source '$WORK/harness.sh'; migrate_lowmem '$WORK/mos.yaml' '$WORK/jrnl.conf'"; }
run_mig
eq "$(awk '/tag: lazy_cache/{f=1} f&&/size:/{print $2; exit}' "$WORK/mos.yaml")" 2048 "迁移: cache 8192→2048"
grep -q 'SystemMaxUse=20M' "$WORK/jrnl.conf" && ok "迁移: journald 50M→20M" || bad "journald 未迁移"
grep -q 'tag: local_upstream' "$WORK/mos.yaml" && grep -q 'tag: remote_upstream' "$WORK/mos.yaml" && ok "用户上游保留" || bad "上游被破坏"
[[ "$(grep -c 'size:' "$WORK/mos.yaml")" == 1 ]] && ok "只改了唯一的 cache size 行" || bad "误改了多处 size"

snap="$(cat "$WORK/mos.yaml")"; run_mig
[[ "$(cat "$WORK/mos.yaml")" == "$snap" ]] && ok "迁移幂等(二跑不变)" || bad "迁移二跑改动了文件"

# 标准 profile → 回到 8192
printf 'PDG_LOWMEM=0\n' > "$WORK/prof.env"; run_mig
eq "$(awk '/tag: lazy_cache/{f=1} f&&/size:/{print $2; exit}' "$WORK/mos.yaml")" 8192 "标准 profile → cache 回 8192"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

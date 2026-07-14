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

# $3 = 历史"装错目录"路径(测试用临时路径, 避免碰真实系统路径)
run_mig(){ PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem512" bash -c "source '$WORK/harness.sh'; migrate_lowmem '$WORK/mos.yaml' '$WORK/jrnl.conf' '$WORK/legacy.conf'"; }
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

# 生成器失败(python3 返回非0)→ 原配置不变、不重启 mosdns
sed -e 's/__SERVER_IP__/10.0.0.9/g' -e 's#__INTERNAL_CIDR__#127.0.0.0/8#g' -e 's#__CERT_DIR__#/tmp/c#g' \
    -e 's/__MOSDNS_CACHE__/8192/g' "$ROOT/deploy/mosdns/config.yaml" > "$WORK/mosf.yaml"
printf '[Journal]\nSystemMaxUse=20M\n' > "$WORK/jrnlok.conf"   # 已是目标, journald 迁移不触发(隔离 mosdns 重启计数)
printf 'PDG_LOWMEM=1\n' > "$WORK/prof.env"
# 只数 mosdns 重启(journald 重启不算), 以隔离验证; journald 文件故意缺 RuntimeMaxUse, 用于证明 journald 仍被修
mosonly='systemctl(){ case "$1 $2" in "is-active mosdns") echo active;; "restart mosdns") MOS=$((MOS+1));; esac; return 0; }'
before="$(md5sum "$WORK/mosf.yaml" | awk '{print $1}')"
printf '[Journal]\nSystemMaxUse=20M\n' > "$WORK/jgen.conf"   # 缺 RuntimeMaxUse
out=$(PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem512" bash -c "
  c_g(){ :; }; c_y(){ :; }; MOS=0
  $mosonly
  python3(){ cat >/dev/null; return 1; }        # 生成器失败
  source '$WORK/lowmem.sh'
  migrate_lowmem '$WORK/mosf.yaml' '$WORK/jgen.conf' '$WORK/legacyx.conf'
  echo \"MOS=\$MOS\"")
[[ "$(md5sum "$WORK/mosf.yaml" | awk '{print $1}')" == "$before" ]] && ok "生成器失败: mosdns 配置原样不变" || bad "生成器失败却改了配置"
echo "$out" | grep -q 'MOS=0' && ok "生成器失败: 未重启 mosdns" || bad "生成器失败却重启了 mosdns"
ls "$WORK"/mosf.yaml.*.tmp >/dev/null 2>&1 && bad "残留临时文件未清理" || ok "临时文件已清理"
grep -qxE 'RuntimeMaxUse=20M' "$WORK/jgen.conf" && ok "mosdns 失败不连累 journald(仍补 RuntimeMaxUse)" || bad "mosdns 失败连带跳过了 journald"

# 原子替换(mv)失败 → 配置不变、不重启 mosdns、清临时文件; journald 仍被修
sed -e 's/__SERVER_IP__/10.0.0.9/g' -e 's#__INTERNAL_CIDR__#127.0.0.0/8#g' -e 's#__CERT_DIR__#/tmp/c#g' \
    -e 's/__MOSDNS_CACHE__/8192/g' "$ROOT/deploy/mosdns/config.yaml" > "$WORK/mosm.yaml"
before="$(md5sum "$WORK/mosm.yaml" | awk '{print $1}')"
printf '[Journal]\nSystemMaxUse=20M\n' > "$WORK/jgen2.conf"
out=$(PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem512" bash -c "
  c_g(){ :; }; c_y(){ :; }; MOS=0
  $mosonly
  mv(){ return 1; }                             # 原子替换失败
  source '$WORK/lowmem.sh'
  migrate_lowmem '$WORK/mosm.yaml' '$WORK/jgen2.conf' '$WORK/legacyx.conf'
  echo \"MOS=\$MOS\"")
[[ "$(md5sum "$WORK/mosm.yaml" | awk '{print $1}')" == "$before" ]] && ok "mv 失败: mosdns 配置原样不变" || bad "mv 失败却改了配置"
echo "$out" | grep -q 'MOS=0' && ok "mv 失败: 未重启 mosdns" || bad "mv 失败却重启了 mosdns"
ls "$WORK"/mosm.yaml.*.tmp >/dev/null 2>&1 && bad "mv 失败残留临时文件" || ok "mv 失败: 临时文件已清理"
grep -qxE 'RuntimeMaxUse=20M' "$WORK/jgen2.conf" && ok "mv 失败不连累 journald(仍补 RuntimeMaxUse)" || bad "mv 失败连带跳过了 journald"

# journald 装错目录的历史残留 → 清掉 + 正确目录补建目标值(旧装迁移场景)
sed -e 's/__SERVER_IP__/10.0.0.9/g' -e 's#__INTERNAL_CIDR__#127.0.0.0/8#g' -e 's#__CERT_DIR__#/tmp/c#g' \
    -e 's/__MOSDNS_CACHE__/8192/g' "$ROOT/deploy/mosdns/config.yaml" > "$WORK/mosj.yaml"
printf '[Journal]\nSystemMaxUse=50M\n' > "$WORK/legacyj.conf"   # 装错目录里有旧文件
rm -f "$WORK/correctj.conf"                                     # 正确目录没有
printf 'PDG_LOWMEM=0\n' > "$WORK/prof.env"                      # 标准 → 目标 50M
PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem2g" bash -c "source '$WORK/harness.sh'; migrate_lowmem '$WORK/mosj.yaml' '$WORK/correctj.conf' '$WORK/legacyj.conf'"
[[ ! -f "$WORK/legacyj.conf" ]] && ok "清掉装错目录的 journald 残留" || bad "错目录残留未清"
grep -q 'SystemMaxUse=50M' "$WORK/correctj.conf" 2>/dev/null && ok "正确目录补建 journald 封顶=50M" || bad "正确目录未补建"
grep -q 'RuntimeMaxUse=50M' "$WORK/correctj.conf" 2>/dev/null && ok "补建同时含 RuntimeMaxUse=50M" || bad "补建缺 RuntimeMaxUse"

# _journald_set_key: 只认未注释有效行 —— 缺则追加、注释不被蒙混、有则替换、幂等
jset(){ bash -c "source '$WORK/harness.sh'; _journald_set_key \"\$1\" \"\$2\" \"\$3\"" _ "$@"; }
printf '[Journal]\n' > "$WORK/j1.conf"                          # 无有效行
jset "$WORK/j1.conf" SystemMaxUse 20M
grep -qxE 'SystemMaxUse=20M' "$WORK/j1.conf" && ok "无有效行 → 追加 SystemMaxUse" || bad "无有效行未追加"
printf '[Journal]\n#SystemMaxUse=20M\n' > "$WORK/j2.conf"        # 只有注释行(易被误判已存在)
jset "$WORK/j2.conf" SystemMaxUse 20M
grep -qxE 'SystemMaxUse=20M' "$WORK/j2.conf" && ok "只有注释行 → 补有效行(不被蒙混)" || bad "被注释行蒙混跳过"
printf '[Journal]\nSystemMaxUse=50M\n' > "$WORK/j3.conf"         # 有效行值不同
jset "$WORK/j3.conf" SystemMaxUse 20M
[[ "$(grep -cE '^SystemMaxUse=' "$WORK/j3.conf")" == 1 ]] && grep -qxE 'SystemMaxUse=20M' "$WORK/j3.conf" && ok "有效行值不同 → 替换(不重复)" || bad "替换错误"
printf '[Journal]\nSystemMaxUse=20M\n' > "$WORK/j4.conf"         # 已是目标
if jset "$WORK/j4.conf" SystemMaxUse 20M; then bad "已是目标却报已改"; else ok "已是目标值 → 未改(幂等)"; fi

# 集成: migrate_lowmem 对"缺 SystemMaxUse 的现有文件"补齐 System+Runtime(不再假成功)
sed 's/8192/2048/' "$WORK/mosj.yaml" > "$WORK/mos2048.yaml"     # 已 2048, 低内存下 cache 无需动
printf '[Journal]\n' > "$WORK/jempty.conf"                       # 现有文件但无有效封顶行
printf 'PDG_LOWMEM=1\n' > "$WORK/prof.env"
PDG_PROFILE="$WORK/prof.env" PDG_MEMINFO="$WORK/mem512" bash -c "source '$WORK/harness.sh'; migrate_lowmem '$WORK/mos2048.yaml' '$WORK/jempty.conf' '$WORK/legacyz.conf'"
grep -qxE 'SystemMaxUse=20M' "$WORK/jempty.conf" && grep -qxE 'RuntimeMaxUse=20M' "$WORK/jempty.conf" \
  && ok "集成: 缺封顶行的现有文件被补齐 System+Runtime=20M" || bad "缺封顶行未被补齐(假成功)"

# P3: 零字节文件 → 补 [Journal] 段头 + key(选项必须在 [Journal] 下)
: > "$WORK/jzero.conf"
jset "$WORK/jzero.conf" SystemMaxUse 20M
grep -qxE '\[Journal\]' "$WORK/jzero.conf" && grep -qxE 'SystemMaxUse=20M' "$WORK/jzero.conf" \
  && ok "零字节文件 → 补 [Journal] 段头 + key" || bad "零字节文件处理错(缺段头/key)"
# P3: [Journal] 末尾无换行 → 不拼接成 [Journal]SystemMaxUse
printf '[Journal]' > "$WORK/jnonl.conf"
jset "$WORK/jnonl.conf" SystemMaxUse 20M
grep -qxE 'SystemMaxUse=20M' "$WORK/jnonl.conf" && ! grep -q 'Journal]SystemMaxUse' "$WORK/jnonl.conf" \
  && ok "末尾无换行 → 段头与 key 各占一行(不拼接)" || bad "拼接成了 [Journal]SystemMaxUse"

# P2-4: 写入失败(只读目录)→ 返回 2 + 迁移 warn 不假绿(需非 root)
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$WORK/ro"; printf '[Journal]\nSystemMaxUse=50M\n' > "$WORK/ro/j.conf"; chmod 0555 "$WORK/ro"
  rc=0; bash -c "source '$WORK/harness.sh'; _journald_set_key '$WORK/ro/j.conf' SystemMaxUse 20M" || rc=$?
  [[ "$rc" == 2 ]] && ok "写入失败(只读目录)→ _journald_set_key 返回 2" || bad "写入失败未返回 2(rc=$rc)"
  out=$(bash -c "
    c_g(){ echo GREEN; }; c_y(){ echo YELLOW; }
    systemctl(){ [[ \"\$1\" == is-active ]] && echo active; return 0; }
    source '$WORK/lowmem.sh'
    _migrate_journald_cap '$WORK/ro/j.conf' '$WORK/none.conf' 20M")
  { echo "$out" | grep -q YELLOW && ! echo "$out" | grep -q GREEN; } && ok "写入失败 → 迁移 warn 不假绿" || bad "写入失败却报绿(out=$out)"
  chmod 0755 "$WORK/ro"
else
  ok "写入失败测试(需非 root, 已跳过)"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

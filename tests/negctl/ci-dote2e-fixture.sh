#!/usr/bin/env bash
# dot-systemd-e2e 两套**夹具**的负控(真 E2E 级四格 + 一格反向对照)。
#
# 守卫级六格在 tests/negctl/ci-dote2e-wiring.py —— 那些只看 workflow 文本。这一支不同:
# 它真起 systemd、真跑 mosdns、真跑被登记的那两支 E2E, 回答的是"夹具前提松掉之后,
# 真测试会不会当场红, 还是悄悄绿过去"。
#
# 每格从 pristine 字节开始, 结束后核对夹具 SHA256 与 mode; 语法损坏不算有效负控。
#
# 用法(必须在一次性隔离环境, 每格自带干净机器):
#   PDG_CI_NEGCTL_IMAGE=pdg-ci:1 bash tests/negctl/ci-dote2e-fixture.sh
set -uo pipefail
IMG="${PDG_CI_NEGCTL_IMAGE:?需要 PDG_CI_NEGCTL_IMAGE(带钉定 mosdns 的基础镜像)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX=tests/helpers/ci-dot-fixture.sh
DK="sudo -n docker"

p=0; f=0
ok(){ p=$((p+1)); echo "[OK]   $*"; }
bad(){ f=$((f+1)); echo "[FAIL] $*"; }

PRISTINE="$(mktemp)"; cp -a "$ROOT/$FIX" "$PRISTINE"
BASE_SHA="$(sha256sum "$ROOT/$FIX" | cut -d' ' -f1)"
BASE_MODE="$(stat -c %a "$ROOT/$FIX")"
WORK="$(mktemp -d -t pdg-cifnc-XXXXXX)"
cleanup(){ $DK rm -f pdg-cifnc >/dev/null 2>&1; rm -rf "$WORK" "$PRISTINE"; }
trap cleanup EXIT INT TERM

# 每格一台干净机器: 快照 + v1.9.0 模板都重新注入, 上一格什么也带不过来。
boot(){
  $DK rm -f pdg-cifnc >/dev/null 2>&1
  $DK run -d --name pdg-cifnc --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw -e container=docker "$IMG" /sbin/init >/dev/null || return 1
  sleep 8
  $DK exec pdg-cifnc bash -c 'systemctl mask getty@tty1 >/dev/null 2>&1; systemctl reset-failed >/dev/null 2>&1'
  git -C "$ROOT" archive --format=tar HEAD \
    | $DK exec -i pdg-cifnc bash -c 'mkdir -p /srv/pdg-dote2e && tar x -C /srv/pdg-dote2e && chown -R root:root /srv/pdg-dote2e'
  git -C "$ROOT" show v1.9.0:deploy/mosdns/config.yaml \
    | $DK exec -i pdg-cifnc bash -c 'cat > /srv/v190-mosdns.yaml'
}

# 把(可能被改坏的)夹具送进机器
push_fixture(){ $DK cp "$1" pdg-cifnc:/srv/pdg-dote2e/$FIX >/dev/null; }

run_in(){ $DK exec pdg-cifnc bash -c "export PDG_E2E_ISOLATED=1 PDG_DOTW_REPO=/srv/pdg-dote2e; $1" 2>&1; }

mutate(){ # <old> <new> → 改坏副本路径
  local out="$WORK/fx.sh"
  cp -a "$PRISTINE" "$out"
  local n; n="$(grep -Fc "$1" "$out")"
  [[ "$n" == 1 ]] || { echo "__ANCHOR__$n"; return 1; }
  python3 - "$out" "$1" "$2" <<'PY'
import sys
p,o,n = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
assert s.count(o) == 1
open(p, "w", encoding="utf-8").write(s.replace(o, n, 1))
PY
  bash -n "$out" || { echo "__SYNTAX__"; return 1; }
  echo "$out"
}

echo "═══ 真 E2E 级夹具负控 ═══"

# ── 基线: 未改坏时两套夹具都成立 ───────────────────────────────────────────
echo
echo "── 基线 ──"
boot || { bad "基线机器起不来"; exit 1; }
push_fixture "$PRISTINE"
out="$(run_in "bash /srv/pdg-dote2e/$FIX pre dot.example.test /srv/v190-mosdns.yaml")"
[[ "$out" == *"pre 形态就绪"* ]] && ok "基线: pre 夹具成立" || { bad "基线 pre 夹具就不成立"; echo "$out" | tail -3; exit 1; }
out="$(run_in "PDG_NEGCTL=1 PDG_MIGRATE_SECTIONS=IDEMPOTENCY bash /srv/pdg-dote2e/tests/e2e-dot-migrate.sh")"
base_sum="$(grep -E '^通过 [0-9]+' <<< "$out" | tail -1)"
[[ "$base_sum" == *"失败 0"* ]] && ok "基线: 迁移矩阵子集绿($base_sum)" || { bad "基线矩阵就红: $base_sum"; exit 1; }

# ── 7) migrate 夹具不预置候选 dotwitness.py ────────────────────────────────
echo
echo "── 7) migrate 夹具漏装 dotwitness.py ──"
m="$(mutate 'install -m755 "$R/deploy/bot/dotwitness.py" /opt/pdg-bot/dotwitness.py' ':')" \
  && m2="$(mutate '[[ "$(sha256sum /opt/pdg-bot/dotwitness.py | cut -d'"'"' '"'"' -f1)" \' ':  # 负控: 连同摘要断言一起摘掉 \')" \
  || true
# 两处要一起摘(摘一处会被夹具自己的摘要断言先拦下, 那不是我们要验的归因)
cp -a "$PRISTINE" "$WORK/fx7.sh"
python3 - "$WORK/fx7.sh" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
a='install -m755 "$R/deploy/bot/dotwitness.py" /opt/pdg-bot/dotwitness.py\n'
assert s.count(a)==1
s=s.replace(a,"",1)
b=re.search(r'\[\[ "\$\(sha256sum /opt/pdg-bot/dotwitness\.py.*?\|\| die "dotwitness\.py 落地后与候选 blob 不一致"\n', s, re.S)
assert b
s=s[:b.start()]+s[b.end():]
open(p,"w",encoding="utf-8").write(s)
PY
if bash -n "$WORK/fx7.sh"; then
  boot >/dev/null; push_fixture "$WORK/fx7.sh"
  out="$(run_in "bash /srv/pdg-dote2e/$FIX pre dot.example.test /srv/v190-mosdns.yaml")"
  if [[ "$out" != *"pre 形态就绪"* ]]; then
    bad "7 夹具自己先崩了, 归因不到模块缺失: $(tail -1 <<< "$out")"
  else
    out="$(run_in "PDG_NEGCTL=1 PDG_MIGRATE_SECTIONS=IDEMPOTENCY bash /srv/pdg-dote2e/tests/e2e-dot-migrate.sh")"
    s7="$(grep -E '^通过 [0-9]+' <<< "$out" | tail -1)"
    if [[ "$s7" == *"失败 0"* ]]; then bad "7 矩阵竟然还绿($s7)"
    elif grep -q 'dotwitness.py 不在' <<< "$out"; then ok "7 矩阵转红并归因模块缺失($s7)"
    else bad "7 转红但归因不对: $(grep -m1 '^\[FAIL' <<< "$out")"; fi
  fi
else bad "7 改坏后语法不合法"; fi

# ── 8) migrate 夹具改用已带受管块的候选模板 ────────────────────────────────
echo
echo "── 8) migrate 夹具不用 v1.9.0 无受管块形态 ──"
boot >/dev/null; push_fixture "$PRISTINE"
out="$(run_in "bash /srv/pdg-dote2e/$FIX pre dot.example.test /srv/pdg-dote2e/deploy/mosdns/config.yaml")"
if grep -q '受管块' <<< "$out" && [[ "$out" != *"pre 形态就绪"* ]]; then
  ok "8 夹具前提转红: $(grep -m1 '❌' <<< "$out")"
else bad "8 竟然接受了带受管块的模板 —— 已部署形态冒充了迁移基线"; fi

# ── 9) P0: dotwitness.env 与实际受管路由不一致 ─────────────────────────────
echo
echo "── 9) P0 的 env 域名与实际路由不一致 ──"
boot >/dev/null; push_fixture "$PRISTINE"
out="$(run_in "bash /srv/pdg-dote2e/$FIX deployed dot.p0ci.test /srv/v190-mosdns.yaml")"
if [[ "$out" != *"deployed 形态就绪"* ]]; then bad "9 夹具没搭起来: $(tail -1 <<< "$out")"; else
  run_in "printf 'PDG_DOTWITNESS_SUFFIX=probe.dot.example.test\n' > /etc/privdns-gateway/dotwitness.env" >/dev/null
  out="$(run_in "bash /srv/pdg-dote2e/tests/e2e-dot-p0.sh")"
  s9="$(grep -E '^通过 [0-9]+' <<< "$out" | tail -1)"
  if [[ "$s9" == *"失败 0"* ]]; then bad "9 P0 竟然还绿($s9) —— 它回退用了缺省域名"
  elif grep -q '没出 evidence' <<< "$out"; then ok "9 P0 转红并点名 probe 没出 evidence($s9)"
  else bad "9 转红但归因不对: $(grep -m1 '^\[FAIL' <<< "$out")"; fi
fi

# ── 10) P0 夹具跳过生产 migrate_dotwitness, 只手工摆一部分 ─────────────────
echo
echo "── 10) P0 夹具跳过生产状态机 ──"
cp -a "$PRISTINE" "$WORK/fx10.sh"
python3 - "$WORK/fx10.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
a='migrate_dotwitness || die "生产状态机部署 witness 失败"\n'
assert s.count(a)==1
# 只手工摆 unit 一件, 其余不管 —— 典型的"自己拼一半"
s=s.replace(a, 'install -m644 "$R/deploy/bot/pdg-dotwitness.service" '
               '/etc/systemd/system/pdg-dotwitness.service\n', 1)
open(p,"w",encoding="utf-8").write(s)
PY
if bash -n "$WORK/fx10.sh"; then
  boot >/dev/null; push_fixture "$WORK/fx10.sh"
  out="$(run_in "bash /srv/pdg-dote2e/$FIX deployed dot.p0ci.test /srv/v190-mosdns.yaml")"
  if [[ "$out" == *"deployed 形态就绪"* ]]; then
    bad "10 夹具竟然认为半个部署也算就绪"
  else ok "10 完整部署前提转红: $(grep -m1 '❌' <<< "$out")"; fi
else bad "10 改坏后语法不合法"; fi

# ── 反向对照: 只加无关注释, 基线必须仍绿 ───────────────────────────────────
echo
echo "── 反向对照: 无关注释 ──"
cp -a "$PRISTINE" "$WORK/fxr.sh"
python3 - "$WORK/fxr.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding="utf-8").read()
a='# ── 4. mosdns 服务 '
assert s.count(a)==1
open(p,"w",encoding="utf-8").write(s.replace(a, '# 负控用的无关注释, 不改变任何行为\n' + a, 1))
PY
boot >/dev/null; push_fixture "$WORK/fxr.sh"
out="$(run_in "bash /srv/pdg-dote2e/$FIX pre dot.example.test /srv/v190-mosdns.yaml")"
if [[ "$out" == *"pre 形态就绪"* ]]; then
  out="$(run_in "PDG_NEGCTL=1 PDG_MIGRATE_SECTIONS=IDEMPOTENCY bash /srv/pdg-dote2e/tests/e2e-dot-migrate.sh")"
  sr="$(grep -E '^通过 [0-9]+' <<< "$out" | tail -1)"
  [[ "$sr" == *"失败 0"* ]] && ok "反向对照: 仍绿($sr), 判据不是见改就红" || bad "反向对照竟然红了: $sr"
else bad "反向对照: 夹具不成立"; fi

echo
echo "── 收尾 ──"
[[ "$(sha256sum "$ROOT/$FIX" | cut -d' ' -f1)" == "$BASE_SHA" ]] && ok "正式树 $FIX 逐字节一致" || bad "正式树夹具被改动了"
[[ "$(stat -c %a "$ROOT/$FIX")" == "$BASE_MODE" ]] && ok "正式树 $FIX mode=$BASE_MODE" || bad "mode 变了"
d="$(git -C "$ROOT" status --porcelain | grep -v '^?? tests/negctl/ci-dote2e-fixture.sh' | head -3)"
[[ -z "$d" ]] && ok "正式树 git status 干净" || bad "正式树有改动: $d"

echo
echo "──────────────────────────────────────────────────────────────"
echo "有效 $p, 失败 $f"
exit $(( f ? 1 : 0 ))

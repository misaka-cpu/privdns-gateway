#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# mosdns 单客户端 QPS 兜底(rate_limiter)回归:
#   A. 迁移幂等: 旧配置(无 limiter)→ 补上 client_limiter + internal_sequence 缓存前拦超限;
#      重复运行不产生重复 plugin/条目; 非本项目形态(无 internal_sequence)不动。
#   B. 实际限流: 渲染真实模板(qps/burst 调小)真起 mosdns v5.3.4, 连发超 burst → REFUSED,
#      限额内查询正常返回。
#   C. doctor 只读检查: 就位=ok; 抽掉 limiter=warn(不 fail)。
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

# ── A. 迁移幂等(纯文本, stub systemctl)──────────────────────────────────────
eval "$(sed -n '/^migrate_mosdns_ratelimit(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
c_g(){ :; }; c_y(){ :; }
SVC_STATE=active
systemctl(){ [[ "$1" == is-active ]] && echo "$SVC_STATE"; return 0; }

# 造一份"本项目形态、但还没有 limiter"的旧配置(截取真实模板并删掉 limiter 相关行)
python3 - "$ROOT/deploy/mosdns/config.yaml" "$WORK/old.yaml" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# 删掉 client_limiter 插件块
s = re.sub(r'  # 单客户端 QPS[^\n]*\n(  #[^\n]*\n)*  - tag: client_limiter\n    type: rate_limiter\n    args:[^\n]*\n', '', s)
# 删掉 internal_sequence 里的 limiter 步骤
s = s.replace('      - matches: "!$client_limiter"     # 单客户端超 QPS → REFUSED, 抢在缓存/上游之前拦掉\n        exec: reject 5\n', '')
open(dst, 'w').write(s)
PY
grep -q client_limiter "$WORK/old.yaml" && bad "构造旧配置失败(仍含 limiter)" || ok "构造旧配置(无 limiter)"

migrate_mosdns_ratelimit "$WORK/old.yaml"
grep -q 'type: rate_limiter' "$WORK/old.yaml" && grep -q '!\$client_limiter' "$WORK/old.yaml" \
  && ok "迁移补上 client_limiter + 拦截步骤" || bad "迁移未补上 limiter"
# 缓存前: internal_sequence 里 !$client_limiter 出现在 $lazy_cache 之前
python3 - "$WORK/old.yaml" <<'PY' && ok "拦截步骤在缓存查询之前" || exit 1
import sys
s=open(sys.argv[1]).read()
b=s[s.index('- tag: internal_sequence'):]
b=b[:b.index('- tag: main_sequence')]
assert b.index('!$client_limiter') < b.index('$lazy_cache'), '顺序不对'
PY

snap="$(cat "$WORK/old.yaml")"
migrate_mosdns_ratelimit "$WORK/old.yaml"
[[ "$(cat "$WORK/old.yaml")" == "$snap" ]] && ok "迁移幂等(二跑不变)" || bad "迁移二跑改动了文件"
[[ "$(grep -c 'type: rate_limiter' "$WORK/old.yaml")" == 1 ]] && ok "无重复 plugin" || bad "出现重复 plugin"

# 用户上游被保留(旧配置里的 remote_upstream/local_upstream 原样还在)
grep -q 'tag: local_upstream' "$WORK/old.yaml" && grep -q 'tag: remote_upstream' "$WORK/old.yaml" \
  && ok "用户上游被保留" || bad "上游被破坏"

# 非本项目形态 → 不动
printf 'plugins:\n  - tag: foo\n    type: sequence\n    args: []\n' > "$WORK/custom.yaml"
snap="$(cat "$WORK/custom.yaml")"
migrate_mosdns_ratelimit "$WORK/custom.yaml"
[[ "$(cat "$WORK/custom.yaml")" == "$snap" ]] && ok "非本项目形态 → 跳过不动" || bad "误改了自定义配置"

# ── B. 实际限流(真起 mosdns)────────────────────────────────────────────────
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) echo "跳过限流实测(未知架构)"; ARCH="";; esac
if command -v mosdns >/dev/null; then MD="$(command -v mosdns)"; fi
if [[ -z "${MD:-}" && -n "$ARCH" ]]; then
  if curl -fsSL "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-${ARCH}.zip" -o "$WORK/m.zip" 2>/dev/null \
     && pdg_verify_sha256 "$WORK/m.zip" "${PDG_SHA256[mosdns-$ARCH]:-}" "mosdns" >/dev/null 2>&1 \
     && (cd "$WORK" && unzip -q m.zip); then MD="$WORK/mosdns"; chmod +x "$MD"; fi
fi
if [[ -n "${MD:-}" ]] && command -v dig >/dev/null; then
  mkdir -p "$WORK/rules"; for f in geosite_cn geosite_apple custom_direct unlock; do : > "$WORK/rules/$f.txt"; done
  sed -e "s|__SERVER_IP__|10.0.0.9|g" -e "s|__INTERNAL_CIDR__|127.0.0.0/8|g" \
      -e "s|__CERT_DIR__|$WORK/certs|g" -e "s|__MOSDNS_CACHE__|8192|g" \
      "$ROOT/deploy/mosdns/config.yaml" > "$WORK/r.yaml"
  sed -i -e "s#/etc/mosdns/rules/#$WORK/rules/#g" -e 's#0.0.0.0:53#127.0.0.1:15353#g' \
         -e 's#qps: 200, burst: 400#qps: 3, burst: 3#' "$WORK/r.yaml"
  # 去掉 DoT server(测试无证书)
  python3 - "$WORK/r.yaml" <<'PY'
import re,sys
f=sys.argv[1]; s=open(f).read()
s=re.sub(r'  - tag: dot_server\n(?:.*\n)*?    args:.*\n','',s)
open(f,'w').write(s)
PY
  "$MD" start -c "$WORK/r.yaml" > "$WORK/mosdns.out" 2>&1 & PIDS+=($!)
  rdy=0; for _ in $(seq 1 30); do dig +short +time=1 +tries=1 @127.0.0.1 -p 15353 rdy.test A >/dev/null 2>&1 && { rdy=1; break; }; sleep 0.2; done
  if [[ "$rdy" == 1 ]]; then
    refused=0
    for i in $(seq 1 20); do
      st=$(dig @127.0.0.1 -p 15353 "burst$i.example.com" A 2>/dev/null | grep -oE 'status: [A-Z]+' | head -1)
      [[ "$st" == *REFUSED* ]] && refused=$((refused+1))
    done
    [[ "$refused" -gt 0 ]] && ok "连发 20 次触发 REFUSED($refused 次超限被拦)" || bad "超限未被 REFUSED"
    sleep 2   # 令牌桶回补
    st=$(dig @127.0.0.1 -p 15353 "slow.example.com" A 2>/dev/null | grep -oE 'status: [A-Z]+' | head -1)
    [[ "$st" == *NOERROR* ]] && ok "限额内查询正常(NOERROR)" || bad "限额内查询异常: $st"
  else
    echo "[SKIP] mosdns 未就绪, 跳过限流实测"; sed 's/^/  mosdns| /' "$WORK/mosdns.out" | head -5
  fi
else
  echo "[SKIP] 无 mosdns/dig, 跳过限流实测(迁移与 doctor 已覆盖)"
fi

# ── C. doctor 只读检查(就位=ok; 抽掉/参数错/动作错=warn)────────────────────
python3 - "$ROOT/deploy/bot/checks.py" "$WORK/old.yaml" <<'PY' && ok "doctor: 就位=ok / 抽掉·参数错·动作错=warn" || bad "doctor 检查不符"
import importlib.util, re, sys
spec=importlib.util.spec_from_file_location("checks", sys.argv[1])
c=importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
base=open(sys.argv[2]).read()
def st_of(text):
    p=sys.argv[2]+".t"; open(p,'w').write(text); c.MOSDNS_CONF=p
    return c.check_mosdns_ratelimit()[0]
assert st_of(base)=="ok", "就位应 ok"
# 抽掉 limiter → warn
gone=re.sub(r'  - tag: client_limiter\n    type: rate_limiter\n    args:[^\n]*\n','',base)
gone=gone.replace('      - matches: "!$client_limiter"\n        exec: reject 5\n','')
assert st_of(gone)=="warn", "抽掉应 warn"
# 参数错(qps 200→100)→ warn
assert st_of(base.replace('qps: 200','qps: 100'))=="warn", "qps 错应 warn"
# 参数错(mask4 32→24)→ warn
assert st_of(base.replace('mask4: 32','mask4: 24'))=="warn", "mask4 错应 warn"
# 动作错(reject 5→accept)→ warn
assert st_of(base.replace('        exec: reject 5','        exec: accept'))=="warn", "动作 accept 应 warn"
# 动作错(reject 5→reject 3)→ warn
assert st_of(base.replace('        exec: reject 5','        exec: reject 3'))=="warn", "reject 3 应 warn"
PY

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

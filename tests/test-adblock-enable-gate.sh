#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# `pdg adblock enable` 的**基础设施闭包门**:枚举不出 ACME DNS provider 的 API 域名时,
# 必须失败,而不是 WARN 之后照样启用。
#
# 为什么这条要 fail-closed:那个 provider 的 API 域名一旦落进第三方广告表,证书续期会从此
# **静默失败** —— 不是拦错一个网站那种一眼可见的故障,而是几十天后所有面板同时证书过期,
# 全程零告警。这与 v1.10.14 修的那个"续期是哑的"是同一类事故,只是触发源换了。
#
# 判据的立场:**枚举不到 ≠ 没有 provider**。后者是正常情形,不该报错。
#
# 跑的是**真的 cmd_adblock**(从 pdg.sh 原样抽取),不复制实现。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)" || exit 1
cleanup(){ [[ -n "${PDG_KEEP_TMP:-}" ]] && { echo "现场保留: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

# ── 抽生产函数(单行函数只取一行, 见 §9.7)────────────────────────────────────
extract(){
  local fn="$1" ln
  ln="$(grep -n "^${fn}()" "$ROOT/deploy/bot/pdg.sh" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || { echo "抽不到 $fn" >&2; return 1; }
  if sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)\{.*\}[[:space:]]*$'; then
    sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh"
  else
    sed -n "${ln},/^}/p" "$ROOT/deploy/bot/pdg.sh"
  fi
}
CLOSURE="$WORK/closure.sh"; : > "$CLOSURE"
for fn in c_g c_y _profile_set _pdg_module _adblock_intent _adblock_ensure_files \
          _adblock_gen_infra _adblock_apply _adblock_status cmd_adblock; do
  extract "$fn" >> "$CLOSURE" || { echo "[FAIL] 生产函数闭包抽取失败: $fn"; exit 1; }
  echo >> "$CLOSURE"
done
# 沙箱桩(**不是**生产函数): 权限门与服务管理不在本支的判据范围内。
cat >> "$CLOSURE" <<'STUB'
need_root(){ :; }
STUB

# ── 一格一个假根 ─────────────────────────────────────────────────────────────
new_box(){
  local w="$WORK/$1"; mkdir -p "$w/etc/mosdns/rules" "$w/var/adblock" "$w/bin" "$w/state" "$w/repo/deploy"
  ln -sfn "$ROOT/deploy/bot" "$w/repo/deploy/bot"
  printf 'PDG_INTERNAL_CIDR=172.22.0.0/16\n' > "$w/etc/privdns-gateway.profile"
  : > "$w/etc/mosdns/rules/adblock_allow.txt"
  printf 'domain:userblocked.invalid\n' > "$w/etc/mosdns/rules/adblock_block.txt"
  printf 'lkg1.invalid\nlkg2.invalid\n' > "$w/var/adblock/list.lkg"
  : > "$w/var/adblock/infra_allow.txt"; : > "$w/var/adblock/effective_block.txt"
  : > "$w/var/adblock/effective_list.txt"
  cat > "$w/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_CALLS"
case "$1" in restart) echo restarted >> "$FX_ROOT/state/restarts";; is-active) exit 0;; esac
exit 0
S
  chmod 755 "$w/bin/systemctl"
  echo "$w"
}

# acme 家目录: data/<域名>/<域名>.conf 里记 Le_Webroot
acme_setup(){
  local w="$1" prov="${2:-}" body="${3:-}"
  mkdir -p "$w/opt/pdg-acme/dnsapi"
  [[ -z "$prov" ]] && return 0
  mkdir -p "$w/opt/pdg-acme/data/panel.example.invalid"
  printf "Le_Domain='panel.example.invalid'\nLe_Webroot='%s'\n" "$prov" \
    > "$w/opt/pdg-acme/data/panel.example.invalid/panel.example.invalid.conf"
  printf '%s' "$body" > "$w/opt/pdg-acme/dnsapi/$prov.sh"
  # 一份"像凭据"的东西, 用来断言它不会被带进任何输出
  printf "ACCOUNT_EMAIL='someone@example.invalid'\nCF_Token='SECRET-TOKEN-VALUE'\n" \
    > "$w/opt/pdg-acme/data/account.conf"
}

run_box(){
  local w="$1" body="$2"
  ( set +e
    export FX_ROOT="$w" FX_CALLS="$w/calls.log"; : > "$FX_CALLS"
    PATH="$w/bin:$PATH"; export PATH
    REPO_DIR="$w/repo"; export REPO_DIR
    PROFILE_ENV="$w/etc/privdns-gateway.profile"
    ADB_STATE_DIR="$w/var/adblock"
    ADB_USER_ALLOW="$w/etc/mosdns/rules/adblock_allow.txt"
    ADB_USER_BLOCK="$w/etc/mosdns/rules/adblock_block.txt"
    ACME_HOME="$w/opt/pdg-acme"
    export PROFILE_ENV ADB_STATE_DIR ADB_USER_ALLOW ADB_USER_BLOCK ACME_HOME
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$body"
  ) > "$w/out.log" 2>&1
  echo $?
}

fp(){ [[ -e "$1" ]] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "-"; }
snap(){ echo "$(fp "$1/var/adblock/effective_block.txt") $(fp "$1/var/adblock/effective_list.txt") $(fp "$1/var/adblock/list.lkg") $(fp "$1/etc/mosdns/rules/adblock_allow.txt") $(fp "$1/etc/mosdns/rules/adblock_block.txt")"; }
intent(){ sed -n 's/^[[:space:]]*PDG_ADBLOCK_ENABLED=//p' "$1/etc/privdns-gateway.profile" 2>/dev/null | tail -1; }

CF_BODY='CF_Api="https://api.cloudflare.com/client/v4"
'
HE_BODY='# 这个插件的赋值行里没有任何 https 常量
'

echo "══ ① 可枚举的 provider → enable 可以继续 ══"
W="$(new_box a1)"; acme_setup "$W" dns_cf "$CF_BODY"
rc="$(run_box "$W" 'cmd_adblock enable')"
[[ "$rc" == 0 && "$(intent "$W")" == 1 ]] \
  && ok "dns_cf 可枚举 → enable 成功且启用位写入" \
  || bad "dns_cf 可枚举却没能启用(rc=$rc intent=$(intent "$W")): $(tail -2 "$W/out.log"|tr '\n' ' ')"
grep -q 'api.cloudflare.com' "$W/var/adblock/infra_allow.txt" \
  && ok "provider 的 API 域名进了基础设施白名单" || bad "API 域名没进白名单"

echo "══ ② 无法枚举的 provider → enable 必须失败 ══"
W="$(new_box a2)"; acme_setup "$W" dns_he "$HE_BODY"
before="$(snap "$W")"; before_intent="$(intent "$W")"
rc="$(run_box "$W" 'cmd_adblock enable')"
[[ "$rc" != 0 ]] && ok "无法枚举 → enable 返回非零($rc)" \
                 || bad "无法枚举却启用成功 —— 这正是要挡住的那一步"

echo "══ ③ 失败之后, 逐项不变量 ══"
[[ "$(intent "$W")" == "$before_intent" ]] \
  && ok "启用位未变(仍为 [${before_intent:-未设置}])" \
  || bad "启用位被写成了 [$(intent "$W")]"
[[ "$(snap "$W")" == "$before" ]] \
  && ok "编译产物 / LKG / 用户 allow-block 逐字节未变" \
  || bad "有文件被改动: 前=[$before] 后=[$(snap "$W")]"
[[ ! -e "$W/state/restarts" ]] \
  && ok "mosdns 未被重启(失败路径不碰服务)" || bad "失败路径仍重启了 mosdns"
grep -qE 'userblocked\.invalid|lkg1\.invalid' "$W/out.log" \
  && bad "输出里出现了规则域名 —— 这条路径不该打印任何域名" \
  || ok "输出里没有任何查询/规则域名(零 query log)"

echo "══ ④ 文案: 点名 provider, 但不泄露凭据 ══"
grep -q 'dns_he' "$W/out.log" \
  && ok "错误文案点名了 provider(dns_he)" || bad "文案没点名是哪个 provider"
grep -qE 'SECRET-TOKEN-VALUE|someone@example\.invalid' "$W/out.log" \
  && bad "文案里泄露了凭据或账号" || ok "文案不含凭据 / 账号"
grep -qE '未.*启用|没有.*启用|保持关闭' "$W/out.log" \
  && ok "文案说清了'去广告没有被启用'" || bad "文案没说清功能未被启用"

echo "══ ⑤ 没配 provider → 不得误判失败 ══"
W="$(new_box a5)"; acme_setup "$W" ""
rc="$(run_box "$W" 'cmd_adblock enable')"
[[ "$rc" == 0 && "$(intent "$W")" == 1 ]] \
  && ok "没配 ACME DNS provider → enable 正常继续" \
  || bad "没配 provider 却被判失败(rc=$rc): $(tail -2 "$W/out.log"|tr '\n' ' ')"

echo "══ ⑥ status 点名 provider 类型, 且不输出 token/账号 ══"
W="$(new_box a6)"; acme_setup "$W" dns_he "$HE_BODY"
run_box "$W" 'cmd_adblock status' >/dev/null
grep -q 'dns_he' "$W/out.log" && ok "status 点名 provider 类型" || bad "status 没点名 provider"
grep -qE 'SECRET-TOKEN-VALUE|someone@example\.invalid' "$W/out.log" \
  && bad "status 泄露了凭据 / 账号" || ok "status 不含凭据 / 账号"

echo "══ ⑦ 用户手工 allow 不得被包装成'产品已完整识别 provider' ══"
W="$(new_box a7)"; acme_setup "$W" dns_he "$HE_BODY"
printf 'domain:dns.he.net\n' > "$W/etc/mosdns/rules/adblock_allow.txt"
rc="$(run_box "$W" 'cmd_adblock enable')"
[[ "$rc" != 0 ]] \
  && ok "用户自己写了一条 allow, 仍然挡住启用(责任不偷偷推给用户)" \
  || bad "一条用户 allow 就把闭包门放过去了"

echo "─────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 老机器的 systemd unit 必须随 `pdg update` 一起更新。
#
# 现状: cmd_update 只装 pdg-health.service/timer, 从不重装 pdg-bot.service 与
# pdg-rules-update.service —— 于是老机器一直带着 `After=... sing-box.service ...`,
# 而 v1.6 已经没有 sing-box 了(依赖悬空, 且与实际内核不符, 排障时极易误导)。
#
# 重装还必须**保住装机时的 CERT_DIR**: pdg-bot.service 里是 Environment=PDG_CERT=<dir>/fullchain.pem,
# 拿模板直接覆盖会把占位符 __CERT_DIR__ 原样写进去, bot 就读不到证书了。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

sed -n '/^migrate_deploy_units(){/,/^}/p' "$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")" > "$WORK/fn.sh"
grep -q '^migrate_deploy_units(){' "$WORK/fn.sh" || { echo "[FAIL] pdg.sh 里没有 migrate_deploy_units —— update 不会为老机器更新 unit"; exit 1; }
sed -i -e 's#/etc/#$SB/etc/#g' "$WORK/fn.sh"

mk(){   # 造出老机器: unit 还写着 sing-box 依赖, 证书路径是装机时的自定义值
  SB="$WORK/root"; rm -rf "$SB"; mkdir -p "$SB/etc/systemd/system"
  cat > "$SB/etc/systemd/system/pdg-bot.service" <<'U'
[Unit]
Description=PrivDNS Gateway Telegram bot
After=network-online.target sing-box.service mosdns.service
Wants=network-online.target

[Service]
EnvironmentFile=-/etc/privdns-gateway/bot.env
Environment=PDG_CERT=/opt/mycerts/fullchain.pem
ExecStart=/usr/bin/python3 /opt/pdg-bot/bot.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
U
  cat > "$SB/etc/systemd/system/pdg-rules-update.service" <<'U'
[Unit]
Description=PrivDNS Gateway 定时刷新 geosite + 规则集
After=network-online.target sing-box.service mosdns.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/pdg-bot/scheduled-update.sh
U
  export SB
}

run(){ env SB="$SB" bash -c "
REPO_DIR='$ROOT'
c_g(){ echo \"\$*\"; }; c_y(){ echo \"\$*\"; }
systemctl(){ echo \"systemctl \$*\" >> '$WORK/sysctl.log'; return 0; }
source '$WORK/fn.sh'
migrate_deploy_units; echo \"RC=\$?\"" 2>&1; }

# ── 1. 老 unit 的 sing-box 依赖被换成 mihomo ──
mk; : > "$WORK/sysctl.log"
out=$(run)
grep -q 'RC=0' <<<"$out" || bad "1: 迁移返回非0: $out"
grep -q 'mihomo.service' "$SB/etc/systemd/system/pdg-bot.service" \
  && ok "pdg-bot.service 依赖已更新为 mihomo.service" || bad "pdg-bot.service 未更新: $(grep After= "$SB/etc/systemd/system/pdg-bot.service")"
grep -q 'sing-box.service' "$SB/etc/systemd/system/pdg-bot.service" \
  && bad "pdg-bot.service 仍带 sing-box 依赖" || ok "pdg-bot.service 已无 sing-box 悬空依赖"
grep -q 'mihomo.service' "$SB/etc/systemd/system/pdg-rules-update.service" \
  && ok "pdg-rules-update.service 依赖已更新" || bad "pdg-rules-update.service 未更新"

# ── 2. 装机时的证书路径必须保住(不能把占位符写进去, 也不能改成默认值) ──
grep -q 'Environment=PDG_CERT=/opt/mycerts/fullchain.pem' "$SB/etc/systemd/system/pdg-bot.service" \
  && ok "保住了装机时的 CERT_DIR(/opt/mycerts)" \
  || bad "CERT_DIR 丢了: $(grep PDG_CERT "$SB/etc/systemd/system/pdg-bot.service")"
grep -q '__CERT_DIR__' "$SB/etc/systemd/system/pdg-bot.service" \
  && bad "占位符 __CERT_DIR__ 被原样写进 unit(bot 会读不到证书)" || ok "无未渲染的占位符"

# ── 3. 改动后要 daemon-reload(否则新 unit 不生效) ──
grep -q 'daemon-reload' "$WORK/sysctl.log" && ok "改动后触发了 daemon-reload" || bad "没 daemon-reload"

# ── 4. 幂等: 已是新形态再跑一次 → 不重写、不重复 reload ──
: > "$WORK/sysctl.log"
before="$(sha256sum "$SB/etc/systemd/system/pdg-bot.service" | cut -d' ' -f1)"
out=$(run)
after="$(sha256sum "$SB/etc/systemd/system/pdg-bot.service" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && ok "幂等: 二跑不改动 unit" || bad "二跑改写了 unit"
grep -q 'daemon-reload' "$WORK/sysctl.log" && bad "无改动却仍 daemon-reload" || ok "幂等: 无改动则不 reload"

# ── 5. unit 不存在的机器(没装过 bot): 不该凭空造出来 ──
mk; rm -f "$SB/etc/systemd/system/pdg-bot.service"
run >/dev/null
[[ ! -e "$SB/etc/systemd/system/pdg-bot.service" ]] \
  && ok "unit 原本不存在 → 不凭空创建(只更新已装的)" || bad "凭空造出了 pdg-bot.service"

# ── 6. 仓库模板里不得再有 sing-box 依赖 ──
if grep -l 'sing-box.service' "$ROOT"/deploy/bot/*.service "$ROOT"/deploy/ios/*.service 2>/dev/null | grep -q .; then
  bad "仓库 unit 模板仍引用 sing-box.service: $(grep -l 'sing-box.service' "$ROOT"/deploy/bot/*.service 2>/dev/null | head -2)"
else
  ok "仓库 unit 模板已无 sing-box 依赖"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

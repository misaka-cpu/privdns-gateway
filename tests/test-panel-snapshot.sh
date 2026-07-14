#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# CLI 快照/回滚的面板临时态净化回归(与 bot backup_blob/restore_from 对称):
#   - 受管开启态(0.0.0.0 + 项目 UI + secret)被识别并净化为关闭态;
#   - 关闭态 / 用户自定义 clash_api 不被改动;
#   - 快照 cf+rf+gzip 打包出的 config 不含 secret、其它文件照常入档。
# 需要 jq(install.sh 装、CI 自带);无 jq 时跳过。退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
if ! command -v jq >/dev/null 2>&1; then echo "[SKIP] 无 jq, 跳过面板快照净化测试"; exit 0; fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

eval "$(sed -n '/^_sb_panel_managed_on(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
eval "$(sed -n '/^_sb_sanitize_panel(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"

SECRET="SEKRET_LEAK_zzz"
mkjson(){ printf '%s' "$1" > "$2"; }

# ── 受管开启态 → 识别 + 净化 ──────────────────────────────────────────────────
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"'"$SECRET"'","external_ui":"/etc/sing-box/ui/dist","external_ui_download_url":"https://x/z.zip"}},"outbounds":[]}' "$WORK/on.json"
_sb_panel_managed_on "$WORK/on.json" && ok "识别受管开启态" || bad "未识别受管开启态"
_sb_sanitize_panel "$WORK/on.json" && ok "净化返回已改" || bad "净化应返回已改"
grep -q "$SECRET" "$WORK/on.json" && bad "净化后仍含 secret" || ok "净化后无 secret/UI"
jq -e '.experimental.clash_api=={"external_controller":"127.0.0.1:9090"}' "$WORK/on.json" >/dev/null 2>&1 && ok "clash_api 收回本地控制器" || bad "clash_api 未收回"
jq -e '.outbounds==[]' "$WORK/on.json" >/dev/null 2>&1 && ok "其它字段保留" || bad "误动了其它字段"

# ── 关闭态 → 不动(返回非 0)──────────────────────────────────────────────────
mkjson '{"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}}}' "$WORK/off.json"
before="$(cat "$WORK/off.json")"; _sb_sanitize_panel "$WORK/off.json"; rc=$?
[[ "$rc" -ne 0 && "$(cat "$WORK/off.json")" == "$before" ]] && ok "关闭态 → 不动" || bad "关闭态被改动"

# ── 用户自定义(0.0.0.0 但非项目 UI 目录)→ 不动 ──────────────────────────────
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"x","external_ui":"/opt/other/ui"}}}' "$WORK/custom.json"
before="$(cat "$WORK/custom.json")"; _sb_sanitize_panel "$WORK/custom.json"; rc=$?
[[ "$rc" -ne 0 && "$(cat "$WORK/custom.json")" == "$before" ]] && ok "自定义 clash_api → 原样不动" || bad "自定义配置被误净化"

# ── 快照打包(cf 排除真实 config + rf 追加净化 config + gzip)→ 归档不含 secret ──
mkdir -p "$WORK/root/etc/sing-box"
cp "$WORK/on.json" "$WORK/root/etc/sing-box/config.json"        # 复位: 用带 secret 的原文件
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"'"$SECRET"'","external_ui":"/etc/sing-box/ui/dist"}}}' "$WORK/root/etc/sing-box/config.json"
echo "CERTDATA" > "$WORK/root/etc/sing-box/fullchain.pem"
stg="$WORK/stg"; mkdir -p "$stg/etc/sing-box"
jq '.experimental.clash_api={external_controller:"127.0.0.1:9090"}' "$WORK/root/etc/sing-box/config.json" > "$stg/etc/sing-box/config.json"
tar cf "$WORK/s.tar" --exclude='etc/sing-box/config.json' -C "$WORK/root" etc/sing-box 2>/dev/null
tar rf "$WORK/s.tar" -C "$stg" etc/sing-box/config.json 2>/dev/null
gzip -f "$WORK/s.tar"
mkdir -p "$WORK/ext"; tar xzf "$WORK/s.tar.gz" -C "$WORK/ext"
grep -q "$SECRET" "$WORK/ext/etc/sing-box/config.json" && bad "归档 config 仍含 secret" || ok "归档 config 已净化(无 secret)"
[[ "$(cat "$WORK/ext/etc/sing-box/fullchain.pem")" == "CERTDATA" ]] && ok "其它文件照常入档" || bad "其它文件丢失/损坏"
[[ "$(grep -c 'etc/sing-box/config.json' <(tar tzf "$WORK/s.tar.gz"))" == 1 ]] && ok "config.json 在档中唯一(未重复)" || bad "config.json 重复/缺失"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

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
eval "$(sed -n '/^_pdg_mktemp_dir(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
eval "$(sed -n '/^_sb_write_sanitized(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
eval "$(sed -n '/^_sb_sanitize_panel(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
eval "$(sed -n '/^_pdg_apply_snapshot_tree(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"

SECRET="SEKRET_LEAK_zzz"
mkjson(){ printf '%s' "$1" > "$2"; }

# ── 受管开启态 → 识别 + 净化 ──────────────────────────────────────────────────
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"'"$SECRET"'","external_ui":"/etc/sing-box/ui/dist","external_ui_download_url":"https://github.com/Zephyruso/zashboard/releases/download/v3.15.0/dist-no-fonts.zip"}},"outbounds":[]}' "$WORK/on.json"
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

# 同项目端口/UI 但下载地址来自第三方，Bot 会判 custom；CLI 必须保持同一归属口径。
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"KEEP","external_ui":"/etc/sing-box/ui/dist","external_ui_download_url":"https://example.com/custom-ui.zip"}}}' "$WORK/custom-url.json"
before="$(cat "$WORK/custom-url.json")"; _sb_sanitize_panel "$WORK/custom-url.json"; rc=$?
[[ "$rc" -ne 0 && "$(cat "$WORK/custom-url.json")" == "$before" ]] && ok "第三方 UI 地址 → 自定义且不动" || bad "第三方 UI 地址被误判为受管"

# 临时目录失败必须显式失败且不返回空路径，防止空路径退化成 /etc/sing-box。
if declare -F _pdg_mktemp_dir >/dev/null; then
  mktemp(){ return 1; }
  tmp_out="$(_pdg_mktemp_dir 2>/dev/null)"; rc=$?
  unset -f mktemp
  [[ "$rc" -ne 0 && -z "$tmp_out" ]] && ok "mktemp 失败 → 不产生空目录" || bad "mktemp 失败未被传播"
else
  bad "缺 _pdg_mktemp_dir 安全辅助函数"
fi

# 原子净化：最终替换失败时必须保留原配置；旧 cat > 原文件会错误地改成功。
mkdir -p "$WORK/atomic"
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"KEEP","external_ui":"/etc/sing-box/ui/dist"}}}' "$WORK/atomic/config.json"
before="$(cat "$WORK/atomic/config.json")"
mv(){ return 1; }
_sb_sanitize_panel "$WORK/atomic/config.json"; rc=$?
unset -f mv
[[ "$rc" -ne 0 && "$(cat "$WORK/atomic/config.json")" == "$before" ]] && ok "净化替换失败 → 原配置不变" || bad "净化失败仍覆盖/报成功"

# ── 快照打包(cf 排除真实 config + rf 追加净化 config + gzip)→ 归档不含 secret ──
mkdir -p "$WORK/root/etc/sing-box"
cp "$WORK/on.json" "$WORK/root/etc/sing-box/config.json"        # 复位: 用带 secret 的原文件
mkjson '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090","secret":"'"$SECRET"'","external_ui":"/etc/sing-box/ui/dist"}}}' "$WORK/root/etc/sing-box/config.json"
echo "CERTDATA" > "$WORK/root/etc/sing-box/fullchain.pem"
stg="$WORK/stg"; mkdir -p "$stg/etc/sing-box"
if declare -F _sb_write_sanitized >/dev/null; then
  _sb_write_sanitized "$WORK/root/etc/sing-box/config.json" "$stg/etc/sing-box/config.json" || bad "净化副本生成失败"
else
  bad "缺 _sb_write_sanitized 净化副本函数"
  jq '.experimental.clash_api={external_controller:"127.0.0.1:9090"}' "$WORK/root/etc/sing-box/config.json" > "$stg/etc/sing-box/config.json"
fi
[[ "$(stat -c %a "$stg/etc/sing-box/config.json")" == 600 ]] && ok "净化副本权限保持 600" || bad "净化副本权限不是 600"
tar cf "$WORK/s.tar" --exclude='etc/sing-box/config.json' -C "$WORK/root" etc/sing-box 2>/dev/null
tar rf "$WORK/s.tar" -C "$stg" etc/sing-box/config.json 2>/dev/null
gzip -f "$WORK/s.tar"
mkdir -p "$WORK/ext"; tar xzf "$WORK/s.tar.gz" -C "$WORK/ext"
grep -q "$SECRET" "$WORK/ext/etc/sing-box/config.json" && bad "归档 config 仍含 secret" || ok "归档 config 已净化(无 secret)"
[[ "$(cat "$WORK/ext/etc/sing-box/fullchain.pem")" == "CERTDATA" ]] && ok "其它文件照常入档" || bad "其它文件丢失/损坏"
[[ "$(grep -c 'etc/sing-box/config.json' <(tar tzf "$WORK/s.tar.gz"))" == 1 ]] && ok "config.json 在档中唯一(未重复)" || bad "config.json 重复/缺失"
[[ "$(stat -c %a "$WORK/ext/etc/sing-box/config.json")" == 600 ]] && ok "解包后 config 权限仍为 600" || bad "解包后 config 权限降级"

# 回滚必须按原成员清单精确落盘，不能把临时树隐式创建的 etc 目录权限覆盖到目标根。
if declare -F _pdg_apply_snapshot_tree >/dev/null; then
  tar tzf "$WORK/s.tar.gz" > "$WORK/members"
  mkdir -p "$WORK/apply/etc"; chmod 711 "$WORK/apply/etc"
  _pdg_apply_snapshot_tree "$WORK/ext" "$WORK/members" "$WORK/apply" || bad "临时树落盘失败"
  [[ "$(stat -c %a "$WORK/apply/etc")" == 711 ]] && ok "精确落盘不覆盖父目录权限" || bad "落盘误改父目录权限"
  [[ "$(stat -c %a "$WORK/apply/etc/sing-box/config.json")" == 600 ]] && ok "精确落盘保留配置权限" || bad "精确落盘丢失配置权限"
else
  bad "缺 _pdg_apply_snapshot_tree 精确落盘函数"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

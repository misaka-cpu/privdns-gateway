#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 重装时"哪些是用户的东西、必须原样留着"的判据。
#
# `PDG_FORCE_REINSTALL=1` 的语义是**重新部署程序与系统组件**, 不是"把这台机器恢复出厂"。
# 早期实现把两者混为一谈: 重装会 `: >` 清空四个规则集文件、拿模板覆盖 /etc/sing-box/config.json
# (那是出口、分流与默认出口的唯一数据源)、并用空 token 重写 bot.env。.200 上实测的后果是
# Telegram token 丢失、10 个出口连同 route.final 一起回到模板默认、WLOC 的接管域名被清空 ——
# 而这些东西没有任何提示地消失, 用户以为只是"重装了一下程序"。
#
# 判据只有一条: **文件存在且内容有效 → 保留**; 不存在 → 按全新安装初始化; 存在但损坏 →
# fail-closed 报错并给修复指引, 绝不静默换成默认值(那等于悄悄把用户的配置扔掉)。
# ─────────────────────────────────────────────────────────────────────────────

# 用户持久数据清单(相对根)。这是"重装不许动"的单一事实源, 测试按它逐项核对。
PDG_USER_DATA="etc/privdns-gateway/bot.env
etc/privdns-gateway/profile.env
etc/privdns-gateway/platform
etc/privdns-gateway/nft-input.d
etc/privdns-gateway/backend
etc/sing-box/config.json
etc/mosdns/rules/custom_direct.txt
etc/mosdns/rules/custom_hijack.txt
etc/mosdns/rules/ruleset_hijack.txt
etc/mosdns/rules/unlock.txt
etc/mosdns/rules/mitm_hijack.txt
opt/pdg-bot/rulesets.json
opt/pdg-bot/dot-domain"

pdg_user_data(){ printf '%s\n' "$PDG_USER_DATA"; }

# 文件在不在且非空 —— "空文件"对规则集来说是合法状态(休眠), 所以这里只判存在。
pdg_data_present(){ [[ -e "${1:-}" ]]; }

# 数据模型是否可用: 能解析成 JSON 且有 outbounds。空/坏 → 非 0(调用方 fail-closed)。
pdg_model_ok(){
  local f="${1:-}"
  [[ -s "$f" ]] || return 1
  python3 - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d.get("outbounds"), list) and d["outbounds"] else 1)
PY
}

# bot.env 里有没有真 token(只判"有没有", 绝不打印内容)
pdg_bot_env_ok(){
  local f="${1:-}"
  [[ -s "$f" ]] || return 1
  grep -qE '^PDG_BOT_TOKEN=[^[:space:]]+' "$f"
}

# 存在就保留, 不存在才初始化。$1=路径 $2..=初始化命令(为空则建空文件)。
# 返回 0 表示"保留了原文件", 1 表示"新建了"。调用方据此决定打印哪句话。
pdg_keep_or_init(){
  local f="$1"; shift
  if pdg_data_present "$f"; then
    return 0
  fi
  if (( $# )); then "$@"; else install -m644 /dev/null "$f" 2>/dev/null || : > "$f"; fi
  return 1
}

# before-image: 把一份用户数据连同权限/属主复制到备份目录, 供失败时逐项恢复。
# $1=源文件 $2=备份根。源不存在 → 记一个 .absent 标记(恢复时据此把新建的文件删掉)。
pdg_before_image(){
  local f="$1" root="$2" d
  d="$root/$(dirname "${f#/}")"
  install -d -m700 "$d" 2>/dev/null || return 1
  if [[ -e "$f" ]]; then
    cp -a "$f" "$d/" 2>/dev/null || return 1
  else
    : > "$d/$(basename "$f").absent" 2>/dev/null || return 1
  fi
  return 0
}

# 按 before-image 还原一份数据(内容 + mode + owner)。备份里是 .absent → 删掉现有文件。
pdg_restore_image(){
  local f="$1" root="$2" b
  b="$root/${f#/}"
  if [[ -e "$b.absent" ]]; then
    rm -f "$f" 2>/dev/null
    return 0
  fi
  [[ -e "$b" ]] || return 1
  cp -a "$b" "$f" 2>/dev/null || return 1
  return 0
}

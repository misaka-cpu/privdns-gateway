#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # 本文件供 source, 常量在 install.sh / pdg / 测试里用(同 lib/modules.sh)
# ─────────────────────────────────────────────────────────────────────────────
# 安装清单的**单一事实源**: install 与 `pdg update` 放到盘上的**程序文件**全集。
# 装完由 installset.py 按这份表写 /var/lib/privdns-gateway/install/manifest.json。
#
# 为什么要有它: 回滚是把快照 tar 覆盖写回去, 快照之后才出现的文件, 回滚从来不删; 盘上到底
# 装了什么, 也没有一份记录可查 —— 验收只能自己把文件逐个算哈希, 再拿去和仓库比。清单记下
# "这一版装了哪些程序文件、每个应当是什么内容", `pdg manifest verify` 与 doctor 据此回答
# "装着的是不是这一版"。后续的回滚撤除与卸载也按它来。
#
# 只收**程序文件**: 内容取自仓库、装上去逐字节相同的那些。分四类:
#   · module  /opt/pdg-bot 下的运行模块 —— 直接取 lib/modules.sh 的清单(按平台), 不另抄一份;
#   · bin     /usr/local/bin 下的 pdg、pdg-set-token 与两个证书辅助脚本;
#   · hook    证书续期钩子;
#   · unit    照原样装的 systemd unit。渲染出来的(pdg-bot、mihomo、mosdns、救援那两个)不算 ——
#             它们的内容随机器而变, 拿仓库哈希去比只会恒不同。
# 不进清单: 用户数据(lib/preserve.sh 的 PDG_USER_DATA)、运行时状态、渲染出来的配置、二进制、
# 内网面板。/opt/pdg-bot 里属于用户数据与运行时状态的那几项另列在 PDG_INSTALLSET_RUNTIME,
# 找"清单外的文件"时跳过它们。
#
# 格式(同 lib/modules.sh, 逐行拆字段的裸字符串, 串里不能写注释):
#   PDG_INSTALLSET_EXTRA   "<仓库内相对路径> <安装后的绝对路径> <mode> <类别>"
#   PDG_INSTALLSET_RUNTIME "<文件名或 fnmatch 模式>"(只认 /opt/pdg-bot 下的直接子项)
# ─────────────────────────────────────────────────────────────────────────────

# 清单文件的位置。放在 /var/lib 而不是 /etc/privdns-gateway: 它不进快照, 也不在验收采样的
# 目录里, 于是从旧版回滚时不会因为它多出一行差异。
PDG_INSTALLSET_DIR="${PDG_INSTALLSET_DIR:-/var/lib/privdns-gateway/install}"

# 运行模块以外的程序文件。install.sh 与 cmd_update 里各有一行 `install -m…` 装它们,
# 这里登记的源、目标、mode 必须与那几行一致(tests/test-install-manifest.py 逐条比对)。
PDG_INSTALLSET_EXTRA="deploy/bot/pdg.sh /usr/local/bin/pdg 755 bin
deploy/bot/pdg-set-token.sh /usr/local/bin/pdg-set-token 755 bin
deploy/cert/proxy-gateway-open-cert-http.sh /usr/local/bin/proxy-gateway-open-cert-http.sh 755 bin
deploy/cert/proxy-gateway-restore-firewall.sh /usr/local/bin/proxy-gateway-restore-firewall.sh 755 bin
deploy/cert/99-reload-cert.deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/99-pdg-cert.sh 755 hook
deploy/bot/pdg-rules-update.service /etc/systemd/system/pdg-rules-update.service 644 unit
deploy/bot/pdg-rules-update.timer /etc/systemd/system/pdg-rules-update.timer 644 unit
deploy/bot/pdg-health.service /etc/systemd/system/pdg-health.service 644 unit
deploy/bot/pdg-health.timer /etc/systemd/system/pdg-health.timer 644 unit
deploy/bot/pdg-probe81.service /etc/systemd/system/pdg-probe81.service 644 unit
deploy/bot/pdg-dotwitness.service /etc/systemd/system/pdg-dotwitness.service 644 unit"

# /opt/pdg-bot 里**不是**程序文件、但本来就该在那儿的东西。
# rulesets.json / dot-domain 是用户数据(lib/preserve.sh); health-state.json 是健康自检的状态;
# ios-qr.png 是 `pdg ios` 生成的二维码; pdg-report-*.txt 是 `pdg report` 的输出;
# __pycache__ 是字节码缓存。
PDG_INSTALLSET_RUNTIME="rulesets.json
dot-domain
health-state.json
ios-qr.png
pdg-report-*.txt
__pycache__"

# 运行模块那部分现取 lib/modules.sh(没 source 过就从本文件旁边找), 不在这里抄第二份。
# 必须在**调用方自己的 shell** 里 source —— 放进 $(…) 里做, 函数定义只活在那个子 shell。
_pdg_installset_need_modules(){
  declare -F pdg_platform_modules >/dev/null && declare -F pdg_legacy_modules >/dev/null && return 0
  # shellcheck source=lib/modules.sh
  source "${BASH_SOURCE[0]%/*}/modules.sh" 2>/dev/null
}

# 逐行输出某平台的程序文件全集: "<源> <目标> <mode> <类别>"。$1=平台(ios / android / 空)。
pdg_installset(){
  local plat="${1:-}" src name mode
  _pdg_installset_need_modules || return 1
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    printf '%s %s %s module\n' "$src" "${PDG_RUNTIME_DIR:-/opt/pdg-bot}/$name" "$mode"
  done < <(pdg_platform_modules "$plat")
  printf '%s\n' "$PDG_INSTALLSET_EXTRA"
}

pdg_installset_runtime(){ printf '%s\n' "$PDG_INSTALLSET_RUNTIME"; }

# 按仓库 $1、平台 $2 写清单; $3=谁写的(install / migrate), 只记录, 不影响内容判断。
# 用的是**仓库里**那份 installset.py —— 清单描述的是仓库这一版, 盘上那份可能还是旧的。
# 失败返回非 0, 调用方决定怎么报; 清单写不成不该拖垮安装或更新(它是记录, 不是功能)。
pdg_installset_write(){
  local repo="$1" plat="$2" by="${3:-}" py="$1/deploy/bot/installset.py" list
  [[ -f "$py" ]] || { echo "找不到 $py" >&2; return 1; }
  _pdg_installset_need_modules || { echo "读不到 lib/modules.sh" >&2; return 1; }
  list="$(pdg_installset "$plat")" || { echo "取不到程序文件清单" >&2; return 1; }
  printf '%s\n' "$list" | python3 -I "$py" write --repo "$repo" --platform "$plat" --by "$by" \
    --dir "$PDG_INSTALLSET_DIR" --runtime "$(pdg_installset_runtime)" --legacy "$(pdg_legacy_modules)"
}

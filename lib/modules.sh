#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # 本文件供 source, 常量在 install.sh / pdg / 测试里用(同 lib/versions.sh)
# ─────────────────────────────────────────────────────────────────────────────
# 运行模块的**单一事实源**: 装到 /opt/pdg-bot 的那一份 Python 代码到底有哪些。
#
# 为什么要有这个文件: 全新安装(install.sh)与升级(pdg update)原本各自维护一份清单, 而救援
# 平面的模块又散在 deploy/bot 与 deploy/rescue 两个目录。少装一个的后果不是报错 —— 是**整块
# 能力静默降级**: 救援页把「恢复受管配置」「紧急默认出口」标成"旧核心不支持", 而用户此刻正
# 指望它们把机器捞回来。这类缺口只有"两条路读同一份清单"才堵得住。
#
# 清单是从**真实入口**算传递闭包得出的, 不是照抄测试:
#   · 救援服务入口 deploy/rescue/rescue.py —— 注意它经 `_mod("x", API)` **动态导入**
#     cfgrestore / breakglass / pdgtx / emergency, 纯静态扫描看不见(emergency 就是这么漏掉过);
#   · 另外两个入口 breakglass.py 与 rescue_cred.py;
#   · pdg.sh 里 `_pdg_module <name>.py` 引用的模块(cidrgen / rescue_nft / pdgtx …)。
# tests/test-install-closure.py 会重新算一遍闭包与本表比对 —— 表漏了它就红。
#
# 格式: 每行 "<仓库内相对路径> <安装后的文件名> <mode>"。装的是**普通文件**, 绝不是指向
# 仓库的软链 —— 仓库可能被删、被移走、或停在另一个 tag 上, 那时软链指向的东西不再是这一版。
# ─────────────────────────────────────────────────────────────────────────────

PDG_RUNTIME_DIR="${PDG_RUNTIME_DIR:-/opt/pdg-bot}"

# 平台无关的运行模块(iOS 专属组件另见 install.sh 的平台分支, 不在本表)
PDG_RUNTIME_MODULES="deploy/bot/pdgtx.py pdgtx.py 755
deploy/bot/checks.py checks.py 755
deploy/bot/doctor.py doctor.py 755
deploy/bot/report.py report.py 755
deploy/bot/nftscan.py nftscan.py 755
deploy/bot/nftmerge.py nftmerge.py 755
deploy/bot/sb2mihomo.py sb2mihomo.py 755
deploy/bot/mihomorender.py mihomorender.py 755
deploy/bot/cfgrestore.py cfgrestore.py 755
deploy/bot/emergency.py emergency.py 755
deploy/bot/cidrgen.py cidrgen.py 755
deploy/bot/rescue_const.py rescue_const.py 755
deploy/bot/rescue_nft.py rescue_nft.py 755
deploy/rescue/rescue.py rescue.py 755
deploy/rescue/rescue_cred.py rescue_cred.py 755
deploy/rescue/breakglass.py breakglass.py 755
lib/rescue.sh rescue.sh 644"
# 最后那行不是 Python: rescue_const 解析的常量单一事实源。装一份副本, 于是仓库不在时也读得到
# (它按 /opt/pdg-bot/rescue.sh → 仓库 lib/rescue.sh 的顺序找)。

# 逐行输出清单(供 bash 侧遍历)
pdg_runtime_modules(){ printf '%s\n' "$PDG_RUNTIME_MODULES"; }

# 把清单里的模块装到目标目录。$1=仓库根, $2=目标目录(默认 /opt/pdg-bot)。
# 任一项失败即返回非 0 —— 调用方据此走各自的回滚, 绝不留新旧混装。
pdg_install_runtime_modules(){
  local repo="$1" dest="${2:-$PDG_RUNTIME_DIR}" src name mode
  install -d -m755 "$dest" || return 1
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    [[ -f "$repo/$src" ]] || { echo "运行模块缺失: $src" >&2; return 1; }
    install -m"$mode" "$repo/$src" "$dest/$name" || return 1
  done < <(pdg_runtime_modules)
  return 0
}

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

# 平台无关的项目静态文件。三方共用这一份: install.sh 装、`pdg update` 同步、uninstall 删。
# 每行是 `源路径 目标名 mode` —— 必须能表达**改名**(deploy/bot/pdg-bot.py → bot.py)与
# **不同源目录**(deploy/bot/ 与 deploy/ios/), 只登记 basename 靠调用方猜目录是不行的。
PDG_RUNTIME_MODULES="deploy/bot/pdgtx.py pdgtx.py 755
deploy/bot/checks.py checks.py 755
deploy/bot/doctor.py doctor.py 755
deploy/bot/report.py report.py 755
deploy/bot/nftscan.py nftscan.py 755
deploy/bot/nftlive.py nftlive.py 755
deploy/bot/linkstat.py linkstat.py 755
deploy/bot/linksess.py linksess.py 755
deploy/bot/probe81.py probe81.py 755
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
lib/rescue.sh rescue.sh 644
deploy/bot/pdg-bot.py bot.py 755
deploy/bot/parse-geosite.py parse-geosite.py 755
deploy/bot/update-rules.sh update-rules.sh 755
deploy/bot/scheduled-update.sh scheduled-update.sh 755
deploy/bot/healthcheck.py healthcheck.py 755"
# rescue.sh 那行不是 Python: rescue_const 解析的常量单一事实源。装一份副本, 于是仓库不在时
# 也读得到(它按 /opt/pdg-bot/rescue.sh → 仓库 lib/rescue.sh 的顺序找)。
#
# 末尾五项以前是 install.sh 里各写一行 `install -m755 …` 装的, 不在任何清单里。后果很实在:
# `pdg update` 从来不同步它们 —— Bot 本体、健康检查、规则更新脚本永远停在装机那一版;
# 卸载也不删, `.200` 上卸完还剩十来个项目程序文件。

# iOS 专属组件。它们是**平台相关**的静态文件: Android 机器上根本不装, 所以不能并进上面那份
# —— 并了之后 Android 装机会多出 MITM 与 :81 探测, 卸载又会去找一批本就不存在的文件。
# 格式完全一致, 同样表达改名与跨目录:
#   deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl → /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
PDG_IOS_MODULES="deploy/bot/iosprofile.py iosprofile.py 755
deploy/bot/iosstate.py iosstate.py 755
deploy/bot/mitm_ca.py mitm_ca.py 755
deploy/bot/mitm_server.py mitm_server.py 755
deploy/bot/mitm_wloc.py mitm_wloc.py 755
deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl pdg-dot.mobileconfig.tmpl 644"

# 早期版本装过、现在不再安装的运行文件(只有目标名, 没有源)。卸载要一并收走 —— 老机器上
# 留着一份不再被任何东西调用的旧脚本, 既误导人, 也让"卸载干净了吗"这个问题没有确定答案。
# nftpurge.py: 卸载改成直接从仓库跑它之后就不再往 /opt/pdg-bot 装, `.200` 上那份是旧版遗留。
PDG_LEGACY_MODULES="nftpurge.py"

# 逐行输出清单(供 bash 侧遍历)
pdg_runtime_modules(){ printf '%s\n' "$PDG_RUNTIME_MODULES"; }

# 某平台下的静态文件全集 = 通用清单 + 该平台专属清单。$1=平台(ios / android / 空)。
# install、`pdg update`、uninstall 三方都从这里取, 于是"装了什么、同步什么、删什么"
# 不可能再对不上 —— 这正是本轮之前那 11 个文件漏掉的原因: 它们只在 install.sh 里各写一行。
pdg_platform_modules(){
  printf '%s\n' "$PDG_RUNTIME_MODULES"
  [[ "${1:-}" == ios ]] && printf '%s\n' "$PDG_IOS_MODULES"
  return 0
}

# 旧版遗留的运行文件目标名(逐行)。
pdg_legacy_modules(){ printf '%s\n' "$PDG_LEGACY_MODULES"; }

# 把清单里的模块装到目标目录。$1=仓库根, $2=目标目录(默认 /opt/pdg-bot)。
# 任一项失败即返回非 0 —— 调用方据此走各自的回滚, 绝不留新旧混装。
# $3=平台(默认取 $PDG_PLATFORM)。install 与 update 传同一个值, 于是同步范围必然一致。
# 部署**之前**先把整份清单校验一遍。原先只判"源文件存在" —— 一份写坏的清单会被照单执行:
# 两个源映射到同一个目标名(后者静默覆盖前者, 而谁赢取决于清单顺序);
# mode 写成 7777 之类的非法值(install 会失败, 但那时前面的文件已经落地了);
# 目标名带 `../`(install -m755 src "$dest/../../etc/passwd" 会真的写出去)。
# 全部在动手前判掉, 一条不合格就整份拒绝 —— 半装比不装更糟。
pdg_validate_modules(){
  local plat="${1:-}" repo="${2:-}" src name mode seen="" why=""
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    [[ "$src" == *".."* || "$src" == /* ]] && { why="源路径逃出仓库: $src"; break; }
    [[ "$name" == *"/"* || "$name" == *".."* ]] && { why="目标名不是单个文件名: $name"; break; }
    [[ "$mode" =~ ^[0-7]{3}$ ]] || { why="mode 非法(只接受三位八进制): $name=$mode"; break; }
    case " $seen " in *" $name "*) why="目标名重复: $name"; break;; esac
    seen="$seen $name"
    [[ -z "$repo" || -f "$repo/$src" ]] || { why="运行模块缺失: $src"; break; }
  done < <(pdg_platform_modules "$plat")
  [[ -z "$why" ]] && return 0
  echo "运行模块清单不合法: $why" >&2
  return 1
}

pdg_install_runtime_modules(){
  local repo="$1" dest="${2:-$PDG_RUNTIME_DIR}" plat="${3:-${PDG_PLATFORM:-}}" src name mode
  pdg_validate_modules "$plat" "$repo" || return 1
  install -d -m755 "$dest" || return 1
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    [[ -f "$repo/$src" ]] || { echo "运行模块缺失: $src" >&2; return 1; }
    # `install` 是覆盖写, 不是"存在就跳过" —— 升级必须真的换掉旧版文件。
    install -m"$mode" "$repo/$src" "$dest/$name" || return 1
  done < <(pdg_platform_modules "$plat")
  # 换掉 .py 之后必须让旧字节码失效, 否则同一秒内改动可能仍读到陈旧 .pyc。
  rm -rf "$dest/__pycache__" 2>/dev/null || true
  return 0
}

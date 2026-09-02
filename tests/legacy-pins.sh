#!/usr/bin/env bash
# 跨版本换核测试用的**旧版**内核钉值。
#
# 为什么不写进 lib/versions.sh: 那是生产配置, 里面每个版本号都代表"这台机器应该跑什么"。
# 旧版只在测试里出现 —— 它是换核的**起点**, 不是任何机器的目标。混进去会让 MOSDNS_VER
# 旁边多出一个语义完全不同的版本号, 迟早有人照着它去装。
#
# 证据等级(必须如实说, 不能与 v5.3.4 混为一谈):
#   v5.3.4 —— GitHub 资产带 digest(sha256:3abcc730…), 与 lib/versions.sh 的 [mosdns-amd64]
#             逐字相同, 可以交叉核对。
#   v5.3.3 —— 该 release 早于 GitHub 资产 digest 字段, API 返回为空。证据链只有
#             「精确 tag + 精确资产名唯一命中 + 归档实算 SHA + 解压产物实算 SHA + 自报版本」。
#             这**低于** v5.3.4 那一档, 报告里不得冒充 digest 交叉验证。
# 这些常量供别的脚本 source, shellcheck 看不到跨文件使用
# shellcheck disable=SC2034
PDG_LEGACY_MOSDNS_VER="v5.3.3"
PDG_LEGACY_MOSDNS_SELFVER="v5.3.3-0-g025823c"
declare -A PDG_LEGACY_SHA256=(
  [mosdns-amd64]="ba56429521679e4c72de800addbfd95cc0cf9073f740a52dda6ce78c7f9350b5"
  [mosdns-bin-amd64]="c6c255ec47ef0698308fcecfa41c8af91ea1c8bea273d1254b5b53aa45dc317c"
)

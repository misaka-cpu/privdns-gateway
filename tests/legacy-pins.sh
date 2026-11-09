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

# ── 冻结桥接一跳的换核目标: mihomo v1.19.30 ─────────────────────────────────
# 冻结桥接的 lib/versions.sh 钉 MIHOMO_VER=v1.19.30, 夹具预装的却是现钉值 —— 于是升级类 E2E
# (e2e-upgrade-from-release / e2e-rescue-migration-lock)的「旧版→桥接」一跳里, 桥接自己的
# _update_core_binary 真的会去换核, 下一跳再由本版换回现钉值。冻结桥接不能改, 所以这两份归档
# 由取件 job 每 run 取一次件, E2E 经离线镜像(tests/e2e-lib.sh 的 e2e_release_mirror)供给,
# 桥接代码照常自己做「归档 SHA + 解压产物 SHA」两道校验。以前这一跳每次都现场去 GitHub 下,
# 2026-11-08 撞上未认证请求超时, 整支以「内核收敛: 按本次前像恢复 mihomo」回滚。
#
# 这三个值**抄自冻结桥接对象自己的 lib/versions.sh**, 不是另算的一份: 换桥接对象时这里跟着换,
# tests/test-bridge-mihomo-pins.sh 逐字核对(对象、版本、两份摘要, 以及两支 E2E 的默认桥接身份)。
# 证据等级与当时的生产钉值相同(桥接那份 versions.sh 记了 GitHub asset digest 交叉核对), 只备 amd64。
PDG_BRIDGE_PIN_COMMIT="542cc9177fc35c9d413ff3b62a7dac8bc468c136"
PDG_BRIDGE_MIHOMO_VER="v1.19.30"

declare -A PDG_LEGACY_SHA256=(
  [mosdns-amd64]="ba56429521679e4c72de800addbfd95cc0cf9073f740a52dda6ce78c7f9350b5"
  [mosdns-bin-amd64]="c6c255ec47ef0698308fcecfa41c8af91ea1c8bea273d1254b5b53aa45dc317c"
  # 桥接钉的 mihomo: 归档 mihomo-linux-amd64-v1.19.30.gz 与解压产物
  [mihomo-bridge-amd64]="cf06ce2c7d1421bdbda14ee4a5b6046672dc35ebf8eecd8e77504ec3c0ed9a84"
  [mihomo-bridge-bin-amd64]="3e92df24f5e80e86b9cf9183ceb7bb575f0bd132a9dc4081dae42e80f21076ae"
)

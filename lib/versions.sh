#!/usr/bin/env bash
# shellcheck disable=SC2034  # 本文件供 source, 变量在 install.sh / tests 里用
# ─────────────────────────────────────────────────────────────────────────────
# 单一可信源: 二进制版本 + 钉死 SHA256(供应链校验)。install.sh 与 tests/ 共用。
#
# 升级版本步骤:
#   1) 改下面的 *_VER;
#   2) 下载官方 release 重算: sha256sum mosdns-linux-<arch>.zip / mihomo-linux-<arch>-<ver>.gz
#   3) 把哈希同步到 PDG_SHA256(amd64 + arm64)。
# 哈希取自上游官方 GitHub Release(信任锚 = 官方发布页),装机/测试时逐字节比对,不符即拒装。
# ─────────────────────────────────────────────────────────────────────────────
MOSDNS_VER="v5.3.4"
MIHOMO_VER="v1.19.30"         # 流量内核: mihomo/clash.meta, sniffer.override-destination 无版本天花板, 活跃维护可更新
ZASHBOARD_VER="v3.15.0"       # 观测面板(纯静态前端, 由 external_ui 托管; dist-no-fonts 最小、不依赖 CDN; mihomo 原生 clash 核也可托管)

# ── 内网面板(方案 B)专用: 反代 + 证书签发 ──────────────────────────────────
# Caddy 用**官方原版**(不带任何 DNS 插件)。带插件要用 xcaddy 按服务商各构建一个 46MB
# 二进制, 等于只支持一家 DNS 服务商; 签发交给 acme.sh(覆盖 150+ 家), 证书落盘后 Caddy
# 用 `tls <cert> <key>` 读 —— 于是换服务商不用换二进制。
CADDY_VER="v2.11.4"
# acme.sh 按**commit sha** 钉, 不按 tarball 哈希。它是个 git 仓库而不是发布二进制,
# tag 可以被移动, 而 commit sha 是内容寻址的 —— clone 之后逐字核对这个 sha, 对不上就拒装。
# 自己算一份 tarball 哈希再钉上去只是 TOFU: 第一次下载就被换掉的话, 钉的正是被换过的那份。
ACME_SH_VER="3.1.4"
ACME_SH_COMMIT="3661fd86b6304115e42f43910e6dd452ab9866d6"

# key = <name>-<arch>(arch: amd64 / arm64); zashboard 为纯前端, 与架构无关(单一哈希)
declare -A PDG_SHA256=(
  [mosdns-amd64]="3abcc73080789eb1ccca78dab5049b85ac1e9b8f865ab60158a527b77cd72e85"
  [mosdns-arm64]="82d80a1a21606fca0bc6b65ac6f90d30cff6bb4a19a6ab6a246cf247dbb78bc0"
  # ── mosdns: **解压后二进制**本身的 SHA256 ──────────────────────────────────
  # 上面两行钉的是下载压缩包。它只在"真的下载了"那条路上起作用 —— 而安装器的短路条件是
  # "自报版本相同就跳过下载", 于是一个内容不同、自报 v5.3.4 的二进制会让整段安装被跳过,
  # 连带跳过 ZIP 校验; 落盘的那个文件本身, 项目从来没有钉过。
  #
  # 取值步骤(可复现, 换个人来照做应得到同一串):
  #   1) curl -fsSL https://github.com/IrineSistiana/mosdns/releases/download/v5.3.4/mosdns-linux-<arch>.zip -o m.zip
  #   2) 先用上面的 [mosdns-<arch>] 校验归档: sha256sum m.zip
  #   3) 校验通过后才解压: unzip -q m.zip
  #   4) sha256sum mosdns
  # 顺序不能颠倒: 先解压再算哈希, 等于给一个来路未经确认的文件盖章(TOFU)。
  # 版本 v5.3.4, 上游发布日 2026-01-11; 两个架构各自独立下载、独立校验、独立计算。
  [mosdns-bin-amd64]="5357fbb83c89f0a7acad275b72c33aa70d4c720cb5590525660132b10cee8af9"
  [mosdns-bin-arm64]="5e651992dbec784df43e0e483428319b0f2892f5fadfd4e39a1462a5d62cb495"
  # mihomo(流量内核): 官方 release 的 mihomo-linux-<arch>-<ver>.gz
  [mihomo-amd64]="cf06ce2c7d1421bdbda14ee4a5b6046672dc35ebf8eecd8e77504ec3c0ed9a84"
  [mihomo-arm64]="58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069"
  # ── mihomo: **解压后二进制**本身的 SHA256 ─────────────────────────────────
  # 与 mosdns 同一个道理, 而且这里的洞更大: 上面两行钉的是下载归档, 只在"真的下载了"
  # 那条路上起作用 —— 而跳过下载的短路条件曾经是 `pdg_mihomo_is_version`, 它问的是
  # **PATH** 上的 mihomo、而且只比**自报版本**。于是 PATH 上放一个自报 v1.19.30 的壳,
  # 或者把 /usr/local/bin/mihomo 的内容换掉、版本串留着, 整段下载与校验都会被跳过,
  # 而安装日志上连"下载 mihomo"这行都不会出现。落盘的那个文件本身从来没被钉过。
  #
  # 取值步骤(可复现, 换个人来照做应得到同一串):
  #   1) 按**精确资产名** mihomo-linux-<arch>-v1.19.30.gz 取(同 tag 下有 20+ 个相似名:
  #      -compatible- / -v1- / -v2- / -v3- / -go120- / -go123- 以及 .deb/.rpm/.pkg.tar.zst,
  #      通配一下就会抓错文件);
  #   2) 与上面的 [mihomo-<arch>] 核对归档摘要;
  #   3) 与 GitHub Release API 的 asset digest 交叉核对(见下方说明);
  #   4) 归档确认无误后才 gunzip;
  #   5) sha256sum 解压产物;
  #   6) 本机架构真跑一次 `-v` 核对自报版本, 另一架构核对完整 ELF 头。
  # 版本 v1.19.30; 两个架构各自独立下载、独立校验、独立计算。
  #
  # 关于 asset digest: 上游**没有**独立签名校验文件。GitHub 在 Release API 里给出
  # 服务器侧计算的 sha256 asset digest —— 它是一条**额外的交叉证据**, 与我们自己算的
  # 摘要相互印证; 它不构成独立的签名信任链(同一方既托管文件又给出摘要)。
  [mihomo-bin-amd64]="3e92df24f5e80e86b9cf9183ceb7bb575f0bd132a9dc4081dae42e80f21076ae"
  [mihomo-bin-arm64]="b9456718a8955364b9a77c80f74dca49ded10f071c1c6b4513a0ea68a3d87a50"
  [zashboard]="403b351d3663f5fe65db053cb2f3dc980108d8f86e8c6968d56164d3452592e1"
  # Caddy 官方 release 的 caddy_<ver>_linux_<arch>.tar.gz。
  # 上游发布的校验和文件里是 **SHA-512**, 本项目统一用 SHA-256, 所以这两个值是
  # "先用上游的 SHA-512 校验下载物、确认无误之后再算出来的" —— 不是直接对一个来路
  # 不明的文件算哈希盖章。换版本时按同一顺序重做: 先验 SHA-512, 再取 SHA-256。
  [caddy-amd64]="527fbf917c39189a1e3b31d34fa955601680b2d5c8055d2a87b8b9588dec7bb9"
  [caddy-arm64]="52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904"
)

# ── 内核版本判定: 必须精确匹配, 不能用子串 ──────────────────────────────────
# `mihomo -v | grep -q "$MIHOMO_VER"` 是子串判断: 期望 v1.19.1 时, 机器上跑 v1.19.10 也会被
# 判成"已是钉死版本" → 装机/更新都跳过下载, 内核实际没升上去。这类错判只在版本号进位到两位
# 数时才出现, 极难发现。故统一解析出完整版本字段后做等值比较。

# 从 `mihomo -v` 输出解析版本(如 v1.19.29); 解析不出则输出空。
pdg_mihomo_version(){
  local out
  out="$(mihomo -v 2>/dev/null | head -1)" || return 0
  [[ "$out" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]] && printf 'v%s\n' "${BASH_REMATCH[1]}"
}

# 当前 mihomo 是否**恰好**是 $1 指定的版本(带不带 v 前缀都行)。
# 读不到版本(没装/输出异常)一律返回非 0 —— 宁可多装一次, 也不能跳过该做的安装。
pdg_mihomo_is_version(){
  local want="${1#v}" got
  got="$(pdg_mihomo_version)"; got="${got#v}"
  [[ -n "$got" && "$got" == "$want" ]]
}

# pdg_mihomo_binary_ok <架构> [期望版本] [二进制路径]
#   → 0 **仅当**四件事同时成立: 架构有钉值、文件存在且可执行、`-v` 退出码为 0 且自报版本
#     精确相等、该文件的 SHA256 等于该架构的二进制钉值。任何一步存疑一律非 0。
#
# 为什么不能用 pdg_mihomo_is_version 当短路判据(它是本项目最久的一处假绿):
#   · 它问的是 **PATH** 上的 mihomo, 而 systemd 的 ExecStart 写的是 /usr/local/bin/mihomo。
#     PATH 上放一个自报正确版本的壳, 判据就答"已是钉死版" —— 而真正在跑的那个文件
#     可以是缺失、旧版, 或者内容被换过;
#   · 它只比**自报版本**, 而版本是二进制自己打印的字符串。
# 所以这里问的是**显式路径**(默认就是 systemd 执行的那个), 并且版本与内容都要核。
#
# 退出码单独取, 不经管道: `$(cmd | head -1)` 的退出码是 head 的, mihomo 自己非零会被吞掉
# —— 那正是"命令返回非零但输出里有正确版本号"这一格要挡的形态。
pdg_mihomo_binary_ok(){
  local arch="${1:-}" want="${2:-${MIHOMO_VER:-}}" bin="${3:-/usr/local/bin/mihomo}" out got exp
  [[ -n "$arch" && -n "$want" && -x "$bin" ]] || return 1
  exp="${PDG_SHA256[mihomo-bin-$arch]:-}"
  [[ -n "$exp" ]] || return 1
  out="$("$bin" -v 2>/dev/null)" || return 1        # 退出码必须是 0
  out="${out%%$'\n'*}"
  [[ "$out" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "${want#v}" ]] || return 1
  got="$(sha256sum "$bin" 2>/dev/null | awk '{print $1}')"
  [[ -n "$got" && "$got" == "$exp" ]]
}

# mosdns 同理。装机曾用 `command -v mosdns` 判定 —— PATH 上有任何一个 mosdns(第三方装的、
# 或早年遗留的老版)就跳过下载, 于是既不升到钉死版, 也**跳过了 SHA256 供应链校验**,
# 网关最终跑着一个来路不明的解析器, 而安装日志上连"下载 mosdns"这行都不会出现。
pdg_mosdns_version(){
  local out
  out="$(mosdns version 2>/dev/null | head -1)" || return 0
  [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && printf 'v%s\n' "${BASH_REMATCH[1]}"
}

pdg_mosdns_is_version(){
  local want="${1#v}" got
  got="$(pdg_mosdns_version)"; got="${got#v}"
  [[ -n "$got" && "$got" == "$want" ]]
}

# pdg_mosdns_binary_ok <架构> [期望版本] [二进制路径]
#   → 0 **仅当**语义版本相同 **且** 该文件的 SHA256 等于该架构的二进制钉值。
#
# 安装器拿它当"可以跳过下载吗"的唯一判据。以前那个判据只问版本, 而版本是二进制**自报**的:
# 换掉内容、保留版本串, 就能让安装器跳过整段下载与校验, 而安装日志上连"下载 mosdns"
# 这一行都不会出现(这个坑早年在 `command -v mosdns` 上踩过一次, 形态一模一样)。
#
# 版本读的是**这个文件**而不是 PATH 上的 mosdns: 问的是"要不要换掉这个文件", 那就必须
# 问它本人。任何一步存疑一律返回非 0 —— 宁可多装一次, 不能存疑就跳过。
pdg_mosdns_binary_ok(){
  local arch="${1:-}" want="${2:-${MOSDNS_VER:-}}" bin="${3:-/usr/local/bin/mosdns}" got exp
  [[ -n "$arch" && -n "$want" && -x "$bin" ]] || return 1
  exp="${PDG_SHA256[mosdns-bin-$arch]:-}"
  [[ -n "$exp" ]] || return 1
  got="$("$bin" version 2>/dev/null | head -1)" || return 1
  [[ "$got" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "${want#v}" ]] || return 1
  got="$(sha256sum "$bin" 2>/dev/null | awk '{print $1}')"
  [[ -n "$got" && "$got" == "$exp" ]]
}

# pdg_verify_sha256 <文件> <期望hash> [名称]  → 不符返回非 0 并打印期望/实际
pdg_verify_sha256(){
  local file="$1" exp="$2" name="${3:-$1}" got
  if [[ -z "$exp" ]]; then
    echo "[x] 缺少 $name 的钉死 SHA256(lib/versions.sh 未覆盖该版本/架构)" >&2
    return 1
  fi
  got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  if [[ "$got" != "$exp" ]]; then
    echo "[x] SHA256 校验失败: $name" >&2
    echo "    期望 $exp" >&2
    echo "    实际 ${got:-<空: 文件不存在或读不出>}" >&2
    return 1
  fi
  return 0
}

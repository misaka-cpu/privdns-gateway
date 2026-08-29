#!/usr/bin/env bash
# 打印本次 run 用来传递 mosdns 二进制的 artifact 名。
#
#   mosdns-<版本>-<架构>-<最终二进制 SHA256 前 12 位>
#   例: mosdns-v5.3.4-amd64-5357fbb83c89
#
# 三段都从 lib/versions.sh 现读, 这里**不写死任何版本号或摘要** —— 名字里带摘要的意义
# 就在于它由钉值生成: 钉值一改, 名字自动跟着变, 旧 artifact 不可能被错认成新的。
# producer 与每个 consumer 都调这一份, 于是「上传的叫什么」和「下载的要什么」没有第二个答案。
#
# 用法: mosdns-artifact-name.sh [架构]   架构缺省按 dpkg/uname 推断
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || { echo "读不到 lib/versions.sh" >&2; exit 1; }

arch="${1:-}"
if [[ -z "$arch" ]]; then
  arch="$(dpkg --print-architecture 2>/dev/null)" || arch=""
  [[ -n "$arch" ]] || case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;;
    *) echo "不支持的架构 $(uname -m)" >&2; exit 1;;
  esac
fi
sha="${PDG_SHA256[mosdns-bin-$arch]:-}"
[[ -n "$sha" ]] || { echo "lib/versions.sh 里没有 mosdns-bin-$arch 的钉值" >&2; exit 1; }
printf 'mosdns-%s-%s-%s\n' "$MOSDNS_VER" "$arch" "${sha:0:12}"

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# producer → artifact → 多个 consumer 这条链, 在本机走一遍真的。
#
# CI 里跨 job 传 artifact 的那一段(upload/download-artifact)本机证明不了, 只能等
# exact-head CI；但**消费者侧的四层校验**是纯本地逻辑, 完全可以在这里钉死:
# 自算 SHA、manifest 交叉核对、自报版本、生产判据。
#
# 重点是两个否定用例:
#   · 二进制改一个字节 → 必须硬失败(artifact 服务端摘要证明不了内容是官方那一份);
#   · manifest 写错但二进制没动 → 也必须被当前仓库钉值抓住(manifest 不是权威)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-artroundtrip.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh" || { echo "[FAIL] 读不到 lib/versions.sh"; exit 1; }
ARCH="$(dpkg --print-architecture 2>/dev/null)"; [[ "$ARCH" == arm64 ]] || ARCH=amd64
WANT="${PDG_SHA256[mosdns-bin-$ARCH]:-}"
[[ -n "$WANT" ]] || { echo "[FAIL] 没有 mosdns-bin-$ARCH 的钉值"; exit 1; }

echo "══ 0. 名字生成器: producer 与 consumer 必须算出同一个名字 ══"
n1="$(bash "$ROOT/tests/mosdns-artifact-name.sh" "$ARCH")"
n2="$(cd "$WORK" && bash "$ROOT/tests/mosdns-artifact-name.sh")"     # 不传架构, 自己推断
[[ -n "$n1" && "$n1" == "$n2" ]] && ok "两次调用一致: $n1" || bad "名字不一致: '$n1' vs '$n2'"
[[ "$n1" == "mosdns-${MOSDNS_VER}-${ARCH}-${WANT:0:12}" ]] \
  && ok "名字 = mosdns-<版本>-<架构>-<摘要前 12>" || bad "名字形态不对: $n1"

echo
echo "══ 1. producer: 造出真实钉定二进制 + manifest ══"
PROD="$WORK/producer"; mkdir -p "$PROD"
if [[ -x /usr/local/bin/mosdns ]] \
   && [[ "$(sha256sum /usr/local/bin/mosdns | cut -d' ' -f1)" == "$WANT" ]]; then
  cp /usr/local/bin/mosdns "$PROD/mosdns"          # 本机已有钉定版, 直接用(零网络)
else
  PDG_TEST_MOSDNS="$PROD/mosdns" bash "$ROOT/tests/prepare-mosdns.sh" >/dev/null 2>&1 || true
fi
if [[ -f "$PROD/mosdns" ]] && [[ "$(sha256sum "$PROD/mosdns" | cut -d' ' -f1)" == "$WANT" ]]; then
  ok "producer 产出的二进制 SHA256 命中钉值"
else
  bad "拿不到钉定版 mosdns —— 这一支未验(不是通过)。备一份: sudo bash tests/prepare-mosdns.sh"
  echo "────────────────────────────────────────"
  echo "test-mosdns-artifact-roundtrip.sh: 通过 $pass, 失败 $nfail"
  exit 1
fi
chmod 755 "$PROD/mosdns"
GOT="$(sha256sum "$PROD/mosdns" | cut -d' ' -f1)"
printf '{"version":"%s","arch":"%s","archive_sha256":"%s","binary_sha256":"%s","source_release":"%s","producer_commit":"%s"}\n' \
  "$MOSDNS_VER" "$ARCH" "${PDG_SHA256[mosdns-$ARCH]}" "$GOT" \
  "https://github.com/IrineSistiana/mosdns/releases/tag/$MOSDNS_VER" "0000000" \
  > "$PROD/manifest.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PROD/manifest.json" \
  && ok "manifest 是合法 JSON" || bad "manifest 不是合法 JSON"
grep -qiE 'token|secret|/home/|ts\.net' "$PROD/manifest.json" \
  && bad "manifest 里出现了不该有的环境数据" || ok "manifest 只含可公开的溯源事实"
bash "$ROOT/tests/mosdns-artifact-name.sh" "$ARCH" >/dev/null && ok "producer 侧名字可生成"

echo
echo "══ 2. 两个独立消费者: 各自复制 → 重新校验 → 安装 ══"
for c in consumerA consumerB; do
  D="$WORK/$c"; mkdir -p "$D/dl" "$D/bin"
  cp "$PROD/mosdns" "$PROD/manifest.json" "$D/dl/"          # 模拟 download-artifact
  out="$(bash "$ROOT/tests/install-mosdns-artifact.sh" "$D/dl" "$ARCH" "$D/bin/mosdns" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "$c 四层校验全过并装好" || bad "$c 失败 rc=$rc: $(tail -2 <<<"$out")"
  [[ -x "$D/bin/mosdns" ]] && ok "$c 目标可执行" || bad "$c 目标没装上"
  [[ "$(stat -c%a "$D/bin/mosdns" 2>/dev/null)" == 755 ]] \
    && ok "$c 安装 mode=755" || bad "$c mode=$(stat -c%a "$D/bin/mosdns" 2>/dev/null)"
  grep -q '四层过' <<<"$out" && ok "$c 报出了四层校验" || bad "$c 没报四层: $out"
done

echo
echo "══ 3. 否定用例 ══"
neg(){ # $1=场景 $2=准备命令
  local D="$WORK/neg"; rm -rf "$D"; mkdir -p "$D/dl" "$D/bin"
  cp "$PROD/mosdns" "$PROD/manifest.json" "$D/dl/"
  eval "$2"
  local out rc=0
  out="$(bash "$ROOT/tests/install-mosdns-artifact.sh" "$D/dl" "$ARCH" "$D/bin/mosdns" 2>&1)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    ok "$1 → 硬失败(rc=$rc): $(grep -m1 '\[FAIL\]' <<<"$out" | awk '{print substr($0,1,90)}')"
  else
    bad "$1 → 竟然通过了"
  fi
  [[ ! -e "$D/bin/mosdns" ]] && ok "$1 → 没有把坏件装上去" || bad "$1 → 坏件被装上了"
}
neg "二进制改一个字节" 'printf "\x00" >> "$D/dl/mosdns"'
neg "manifest 摘要写错但二进制没动" \
    'python3 -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d[\"binary_sha256\"]=\"0\"*64; json.dump(d,open(p,\"w\"))" "$D/dl/manifest.json"'
neg "manifest 版本写错" \
    'python3 -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d[\"version\"]=\"v0.0.1\"; json.dump(d,open(p,\"w\"))" "$D/dl/manifest.json"'
# 这一格专门隔离"自算 SHA"那一层: 二进制被换掉, manifest 也被同步改成与新内容一致 ——
# 于是 manifest 交叉核对是过的, 能抓住它的只剩"与 lib/versions.sh 钉值比对"这一步。
# 少了它, 把消费者的 SHA 校验整段摘掉也不会有任何一格转红(负控③当场量到 0 条)。
neg "二进制被换 + manifest 同步改成一致(只有仓库钉值能抓)" \
    'printf "\x00" >> "$D/dl/mosdns"
     python3 -c "
import json,sys,hashlib
p=sys.argv[1]; d=json.load(open(p))
d[\"binary_sha256\"]=hashlib.sha256(open(sys.argv[2],\"rb\").read()).hexdigest()
json.dump(d,open(p,\"w\"))" "$D/dl/manifest.json" "$D/dl/mosdns"'
neg "manifest 缺失" 'rm -f "$D/dl/manifest.json"'
neg "二进制缺失" 'rm -f "$D/dl/mosdns"'

echo
echo "══ 4. 消费者侧不联网 ══"
# 把 curl/wget 从 PATH 上摘掉再跑一遍 —— 真依赖网络的话这里必然露馅。
D="$WORK/nonet"; mkdir -p "$D/dl" "$D/bin" "$D/fakebin"
cp "$PROD/mosdns" "$PROD/manifest.json" "$D/dl/"
for c in curl wget; do printf '#!/bin/sh\necho "禁止联网: %s" >&2\nexit 97\n' "$c" > "$D/fakebin/$c"; chmod 755 "$D/fakebin/$c"; done
out="$(PATH="$D/fakebin:$PATH" bash "$ROOT/tests/install-mosdns-artifact.sh" "$D/dl" "$ARCH" "$D/bin/mosdns" 2>&1)"; rc=$?
{ [[ "$rc" == 0 ]] && ! grep -q '禁止联网' <<<"$out"; } \
  && ok "curl/wget 被换成拒绝桩后仍然成功 —— 消费者确实不联网" \
  || bad "消费者路径上有联网动作(rc=$rc): $(tail -2 <<<"$out")"

echo
echo "══ 5. 零残留 ══"
[[ -d "$WORK" ]] && ok "本轮临时物都在自建目录内($WORK)"
_leftover=0
for d in "${TMPDIR:-/tmp}"/pdg-artroundtrip.*; do
  [[ -e "$d" ]] || continue
  [[ "$d" == "$WORK" ]] || _leftover=$((_leftover+1))
done
[[ "$_leftover" == 0 ]] && ok "没有同前缀的旧残留" || bad "有 $_leftover 个同前缀残留"

echo "────────────────────────────────────────"
echo "test-mosdns-artifact-roundtrip.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

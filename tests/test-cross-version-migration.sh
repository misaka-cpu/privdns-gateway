#!/usr/bin/env bash
# 跨版本迁移矩阵: 从**历史发布 tag 的配置形态**跑当前的 mosdns 迁移链, 再用**真 mosdns**
# 验它起得来。
#
# 为什么需要这一支: 项目里已有 e2e-upgrade-from-release.sh, 但它只测**上一个 tag**。
# 跨大版本(v1.10.x → 现在)此前没有任何自动化覆盖 —— 而 v1.11.0 那个 P0 恰恰就是
# "存量机器根本装不上去": 迁移拿一行**注释**当插入锚点, 而那行注释只存在于新模板里,
# 存量机器的配置是老模板加一串迁移堆出来的, 一律没有。
#
# 与那两支既有 e2e 的分工:
#   · e2e-upgrade-from-release.sh —— 真跑一次完整 `pdg update`(要 overlay + userns);
#   · e2e-cross-version-rollback.sh —— 专治 v1.5.x 时代的失败回滚;
#   · 本支 —— 只验"配置改写"这一段, **不需要 overlay/userns**, 普通容器就能跑, 于是能在
#     矩阵里覆盖多个历史版本。
#
# 覆盖点是**算出来的**, 不是写死的清单(写死的会随新 tag 腐烂):
#   ① 仓库里最老的、模板能渲染的 tag;
#   ② 最后一个**没有**去广告受管块的 tag —— 这是形态分界的旧侧;
#   ③ 第一个**有**去广告受管块的 tag —— 分界的新侧;
#   ④ 最新的 tag。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }

# 这一支要读**历史 tag 的模板**, 没有 git 历史就什么都测不了。
# 但"读不到历史"有两种情况, 必须分开:
#   · CI / 完整 clone —— 有历史。读不到 = 真出事了, **硬失败**;
#   · 从 tarball 或 `git archive` 展开的树 —— 本来就没有 .git。那不是缺陷,
#     但也不能默默判绿, 所以**具名 SKIP 并退非零之外的码**, 让调用方看得见。
command -v git >/dev/null 2>&1 || {
  echo "[SKIP] 没有 git —— 这一支要读历史 tag, 本环境测不了(不是通过)"
  echo "通过 $pass, 失败 $nfail(已跳过)"; exit 0; }
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[SKIP] $ROOT 不是可用的 git 仓库(tarball / 断开的 worktree)—— 本环境测不了(不是通过)"
  echo "通过 $pass, 失败 $nfail(已跳过)"; exit 0
fi
_ntags="$(git -C "$ROOT" tag -l 'v*' 2>/dev/null | grep -c . || true)"
if [[ "${_ntags:-0}" -lt 4 ]]; then
  echo "[SKIP] 只有 ${_ntags:-0} 个 v* tag(浅克隆?)—— 矩阵没有意义, 本环境测不了(不是通过)"
  echo "通过 $pass, 失败 $nfail(已跳过)"; exit 0
fi

# 钉死版 mosdns。**拿不到就具名硬失败** —— 这一组测的就是"真 mosdns 认不认改写后的配置",
# 跳过等于零覆盖。
MOSDNS=""
for c in "${PDG_TEST_MOSDNS:-}" /usr/local/bin/mosdns "$WORK/mosdns"; do
  [[ -n "$c" && -x "$c" ]] && { MOSDNS="$c"; break; }
done
if [[ -z "$MOSDNS" ]]; then
  PDG_TEST_MOSDNS="$WORK/mosdns" bash "$ROOT/tests/prepare-mosdns.sh" >/dev/null 2>&1 || true
  [[ -x "$WORK/mosdns" ]] && MOSDNS="$WORK/mosdns"
fi
[[ -n "$MOSDNS" ]] && ok "拿到钉死版 mosdns" \
  || { bad "拿不到钉死版 mosdns —— 这一组测的是真 mosdns 的行为, 不跳过"; echo "通过 $pass, 失败 $nfail"; exit 1; }

# ── 选覆盖点 ─────────────────────────────────────────────────────────────────
has_block(){ git -C "$ROOT" show "$1:deploy/mosdns/config.yaml" 2>/dev/null \
             | grep -qc 'pdg-adblock managed block (plugins)' 2>/dev/null; }
mapfile -t TAGS < <(git -C "$ROOT" tag -l 'v*' --sort=v:refname 2>/dev/null \
                    | while read -r t; do
                        git -C "$ROOT" cat-file -e "$t:deploy/mosdns/config.yaml" 2>/dev/null && echo "$t"
                      done)
(( ${#TAGS[@]} >= 4 )) && ok "找到 ${#TAGS[@]} 个带 mosdns 模板的历史 tag" \
  || bad "带模板的 tag 只有 ${#TAGS[@]} 个 —— 矩阵没有意义"

last_without=""; first_with=""
for t in "${TAGS[@]}"; do
  if has_block "$t"; then [[ -z "$first_with" ]] && first_with="$t"
  else last_without="$t"; fi
done
PICK=()
[[ ${#TAGS[@]} -gt 0 ]] && PICK+=("${TAGS[0]}")
[[ -n "$last_without" ]] && PICK+=("$last_without")
[[ -n "$first_with"   ]] && PICK+=("$first_with")
[[ ${#TAGS[@]} -gt 0 ]] && PICK+=("${TAGS[-1]}")
mapfile -t PICK < <(printf '%s\n' "${PICK[@]}" | awk '!seen[$0]++')
echo "  覆盖点: ${PICK[*]}"
{ [[ -n "$last_without" ]] && [[ -n "$first_with" ]]; } \
  && ok "分界两侧都取到了(旧侧 $last_without / 新侧 $first_with)" \
  || bad "取不到形态分界 —— 矩阵覆盖不全(旧侧='$last_without' 新侧='$first_with')"

# ── 单个版本的验证 ───────────────────────────────────────────────────────────
render_and_migrate(){   # $1=tag  $2=盒子目录 ; 回显一行结果码
  local tag="$1" B="$2"
  rm -rf "$B"; mkdir -p "$B/etc/mosdns/rules" "$B/var/adblock" "$B/cert" "$B/repo"
  git -C "$ROOT" show "$tag:deploy/mosdns/config.yaml" > "$B/tmpl.old" 2>/dev/null || { echo "NO-TEMPLATE"; return; }
  sed -e "s|__SERVER_IP__|127.0.0.9|g" -e "s|__INTERNAL_CIDR__|127.0.0.0/8|g" \
      -e "s|__CERT_DIR__|$B/cert|g" -e "s|__SSH_PORT__|22|g" -e "s|__MOSDNS_CACHE__|2048|g" \
      -e "s|__JOURNALD_MAXUSE__|20M|g" -e "s|__HIJACK_SET_FILE__|geosite_geolocation-!cn.txt|g" \
      -e "s|__DOT_DOMAIN__|dot.xvtest.invalid|g" "$B/tmpl.old" > "$B/live.yaml"
  # 沙箱化: 路径指到盒子, 端口挪到高位(非 root 绑不了 53/853 —— 那是夹具限制, 不是迁移问题)
  sed -i "s|/etc/mosdns/rules/|$B/etc/mosdns/rules/|g; s|/var/lib/privdns-gateway/adblock/|$B/var/adblock/|g" "$B/live.yaml"
  sed -i 's|listen: "0.0.0.0:53"|listen: "127.0.0.1:15390"|; s|listen: "0.0.0.0:853"|listen: "127.0.0.1:15391"|' "$B/live.yaml"
  local f
  for f in geosite_cn geosite_apple custom_direct custom_hijack ruleset_hijack mitm_hijack \
           unlock "geosite_geolocation-!cn" adblock_allow adblock_block lan_hijack geosite_gfw; do
    : > "$B/etc/mosdns/rules/$f.txt"
  done
  for f in infra_allow effective_block effective_list; do : > "$B/var/adblock/$f.txt"; done
  openssl req -x509 -newkey rsa:2048 -keyout "$B/cert/privkey.pem" -out "$B/cert/fullchain.pem" \
    -days 2 -nodes -subj "/CN=dot.xvtest.invalid" >/dev/null 2>&1
  # 基线: 旧配置本身能起来吗。起不来就不是迁移的问题, 但也不能当成通过。
  if timeout 10 "$MOSDNS" start -c "$B/live.yaml" -d "$B" 2>&1 | grep -qi fatal; then
    echo "BASE-FAIL"; return
  fi
  # **复刻真迁移的前置门**: 没有 `- tag: explicit_proxy` 定义时, migrate_adblock **跳过**
  # 而不是失败 —— 插一个引用不存在插件的块会让 mosdns 起不来 → 整次更新回滚 → 那台机器
  # 再也升不上去。跳过是可恢复的: 等 explicit_proxy 到位, 下一次 update 会补上。
  # 夹具不照做的话, v1.0.0 这类老模板会红在"找不到插入锚点"上 —— 而真迁移根本走不到那里。
  if ! grep -qE '^ *- tag: explicit_proxy$' "$B/live.yaml"; then echo "PREREQ-SKIP"; return; fi
  # **复刻真迁移的短路**: migrate_adblock 在受管块已就位时直接返回, 根本不改写配置。
  # 不照做的话会对新版形态再插一遍块 → duplicate tag, 而那是夹具的错不是产品的。
  local npl nsq
  npl="$(grep -c 'pdg-adblock managed block (plugins)' "$B/live.yaml" || true)"
  nsq="$(grep -c 'pdg-adblock managed block (internal_sequence)' "$B/live.yaml" || true)"
  if [[ "$npl" == 2 && "$nsq" == 2 ]]; then echo "SHORTCIRCUIT"; return; fi
  # 跑当前版本的改写逻辑
  cp "$ROOT/deploy/mosdns/config.yaml" "$B/repo/tmpl.yaml"
  sed -i "s|/etc/mosdns/rules/|$B/etc/mosdns/rules/|g; s|/var/lib/privdns-gateway/adblock/|$B/var/adblock/|g" "$B/repo/tmpl.yaml"
  sed -n "/^migrate_adblock()/,/^}/p" "$ROOT/deploy/bot/pdg.sh" \
    | sed -n "/<<'PYEOF'/,/^PYEOF/p" | sed '1d;$d' > "$B/rewrite.py"
  [[ -s "$B/rewrite.py" ]] || { echo "NO-REWRITE"; return; }
  if ! python3 "$B/rewrite.py" "$B/live.yaml" "$B/repo/tmpl.yaml" "$B/cand.yaml" 2>"$B/err.txt"; then
    echo "REWRITE-FAIL:$(head -1 "$B/err.txt" | cut -c1-70)"; return
  fi
  sed -i 's|listen: "0.0.0.0:53"|listen: "127.0.0.1:15390"|; s|listen: "0.0.0.0:853"|listen: "127.0.0.1:15391"|' "$B/cand.yaml"
  local out; out="$(timeout 10 "$MOSDNS" start -c "$B/cand.yaml" -d "$B" 2>&1)"
  if grep -qi fatal <<<"$out"; then
    echo "POST-FAIL:$(grep -i fatal <<<"$out" | head -1 | sed 's/.*FATAL[[:space:]]*//' | cut -c1-70)"; return
  fi
  echo "OK"
}

echo
echo "══ 矩阵: 各历史版本 → 当前迁移 ══"
migrated=0
for tag in "${PICK[@]}"; do
  B="$WORK/box-$tag"
  r="$(render_and_migrate "$tag" "$B")"
  case "$r" in
    OK)
      migrated=$((migrated+1))
      npl="$(grep -c 'pdg-adblock managed block (plugins)' "$B/cand.yaml" || true)"
      nsq="$(grep -c 'pdg-adblock managed block (internal_sequence)' "$B/cand.yaml" || true)"
      nrj="$(grep -c 'exec: reject 3' "$B/cand.yaml" || true)"
      { [[ "$npl" == 2 ]] && [[ "$nsq" == 2 ]]; } \
        && ok "$tag → 迁移后真 mosdns 起得来, 受管块成对(pl=$npl sq=$nsq)" \
        || bad "$tag → 起来了但受管块不成对(pl=$npl sq=$nsq)"
      [[ "$nrj" -ge 2 ]] \
        && ok "$tag → 两条阻断规则都在(实得 $nrj)" \
        || bad "$tag → 阻断规则少了(实得 $nrj)" ;;
    SHORTCIRCUIT)
      ok "$tag → 受管块已在场, 真迁移短路返回(不改写配置)" ;;
    PREREQ-SKIP)
      ok "$tag → 没有 explicit_proxy, 真迁移跳过(可恢复; 不会拖垮更新)" ;;
    BASE-FAIL)
      bad "$tag → **旧配置本身**就起不来 —— 夹具或该版本模板有问题, 不能当成通过" ;;
    *)
      bad "$tag → $r" ;;
  esac
done
(( migrated >= 1 )) \
  && ok "至少有一个版本真的走了改写路径(实得 $migrated 个)—— 否则整个矩阵只是在测短路" \
  || bad "没有任何版本走到改写 —— 这个矩阵什么都没验"

echo
echo "══ P0 复现: 锚点必须是结构, 不是注释 ══"
# v1.11.0 的 P0: 拿 `  # MITM 接管域名的劫持序列` 当插入锚点, 而那行注释只存在于新模板里,
# 存量机器一律没有 → 迁移失败 → 整次更新回滚 → 那台机器再也升不上去。
if [[ -n "$last_without" ]]; then
  B="$WORK/box-p0"
  render_and_migrate "$last_without" "$B" >/dev/null
  sed -i '/MITM 接管域名的劫持序列/d' "$B/live.yaml"
  cp "$ROOT/deploy/mosdns/config.yaml" "$B/repo/tmpl.yaml"
  sed -i "s|/etc/mosdns/rules/|$B/etc/mosdns/rules/|g; s|/var/lib/privdns-gateway/adblock/|$B/var/adblock/|g" "$B/repo/tmpl.yaml"
  if python3 "$B/rewrite.py" "$B/live.yaml" "$B/repo/tmpl.yaml" "$B/cand2.yaml" 2>"$B/err2.txt"; then
    sed -i 's|listen: "0.0.0.0:53"|listen: "127.0.0.1:15390"|; s|listen: "0.0.0.0:853"|listen: "127.0.0.1:15391"|' "$B/cand2.yaml"
    o2="$(timeout 10 "$MOSDNS" start -c "$B/cand2.yaml" -d "$B" 2>&1)"
    grep -qi fatal <<<"$o2" \
      && bad "删掉那行注释后 mosdns 起不来: $(grep -i fatal <<<"$o2" | head -1 | cut -c1-70)" \
      || ok "删掉那行注释后仍能迁移并启动(锚点确实是结构而非注释)"
  else
    bad "删掉那行注释后改写就失败了 —— 锚点又回到注释上了: $(head -1 "$B/err2.txt" | cut -c1-70)"
  fi
  # 反面: 把**结构**锚点删掉, 迁移必须失败(而不是硬插一个坏配置)
  B3="$WORK/box-noanchor"
  render_and_migrate "$last_without" "$B3" >/dev/null
  sed -i '/^  - tag: force_hijack_seq$/d' "$B3/live.yaml"
  cp "$ROOT/deploy/mosdns/config.yaml" "$B3/repo/tmpl.yaml"
  sed -i "s|/etc/mosdns/rules/|$B3/etc/mosdns/rules/|g; s|/var/lib/privdns-gateway/adblock/|$B3/var/adblock/|g" "$B3/repo/tmpl.yaml"
  python3 "$B3/rewrite.py" "$B3/live.yaml" "$B3/repo/tmpl.yaml" "$B3/cand3.yaml" >/dev/null 2>&1 \
    && bad "结构锚点不在时改写居然成功了 —— 它应当 fail-closed, 而不是硬插" \
    || ok "结构锚点不在时改写失败(fail-closed, 现网不动)"
else
  bad "没有分界旧侧的 tag, P0 这一格测不了"
fi

echo
echo "══ 危险组合必须不存在于任何历史版本 ══"
# migrate_adblock 的两条路: 没有 explicit_proxy → 跳过(安全); 有 explicit_proxy 但没有
# force_hijack_seq → 改写失败 → rc=1 → **整次更新回滚, 那台机器再也升不上去**。
# 所以"有 ep 无 fh"是唯一会出事的组合。这一格证明它在历史上从未出现过 ——
# 一旦将来某个改动造出这个组合, 这里就会红。
danger=""
for t in "${TAGS[@]}"; do
  c="$(git -C "$ROOT" show "$t:deploy/mosdns/config.yaml" 2>/dev/null)"
  ep="$(grep -cE '^ *- tag: explicit_proxy$' <<<"$c" || true)"
  fh="$(grep -cE '^ *- tag: force_hijack_seq$' <<<"$c" || true)"
  { [[ "$ep" -ge 1 ]] && [[ "$fh" == 0 ]]; } && danger="$danger $t"
done
[[ -z "$danger" ]] \
  && ok "没有任何历史版本是「有 explicit_proxy 但无 force_hijack_seq」(检查了 ${#TAGS[@]} 个)" \
  || bad "这些版本会让更新整次回滚:$danger"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 更新前自检**不得执行还没通过摘要校验的 mosdns 文件**。
#
# 判据本体(lib/versions.sh 的 pdg_mosdns_binary_ok)自 v1.11.9 起已经是"先算摘要、再执行"。
# 但 _update_mosdns_preflight 在判据失败之后, 为了把原因分成 rc=5(版本漂移)/ rc=6(内容不符),
# **又直接跑了两次 `"$bin" version`** —— 于是一个摘要不符的文件仍然会在 root 的更新预检里
# 被执行。判据把它挡在门外, 诊断又把它请进来了。
#
# 这一支证明的是**行为**, 不是源码形状: 候选文件被执行时会写一个 marker, 断言看的是那个
# marker 在不在。源码里有没有那两行 `"$bin" version` 不是判据 —— 换个写法照样能执行。
#
# 契约(本轮裁决, 与 v1.11.9 那版相反):
#   · 没通过当前仓库钉值摘要的文件, **一律不执行**;
#   · 不再从未知文件的自报版本推断它"只是版本漂移";
#   · 摘要不符统一判为不可信内容, 拒绝更新;
#   · 没有 --force / 环境变量 / 隐藏后门可以跳过。
#
# 代价是有意接受的: 手工换过内核、摘要不属于当前正式版的机器, 不再被例行 update 自动抹平,
# 用户必须先恢复可信内核。反过来的默认(让例行更新顺手覆盖一个来路不明的二进制)会把这台
# 机器上最该报警的一件事变成一行没人看的日志。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-preexec.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){  echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

sed -n '/^_update_mosdns_preflight(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" > "$WORK/pre.sh"
[[ -s "$WORK/pre.sh" ]] || { bad "抽不出 _update_mosdns_preflight"; echo "通过 $pass, 失败 $nfail"; exit 1; }

BIN="$WORK/bin"; mkdir -p "$BIN"
MARK="$WORK/EXECUTED"

# 被执行就留痕。marker 是本支的全部判据来源 —— 它在, 就说明那个文件真的跑起来过。
mkbin(){   # $1=自报版本 $2=落地路径 $3=用来制造 SHA 差异的盐(空=不加)
  {
    echo '#!/bin/sh'
    printf ': > "%s"\n' "$MARK"
    printf 'case "$1" in version) echo "mosdns %s-0-gabc";; esac\n' "$1"
    echo 'exit 0'
    [[ -n "${3:-}" ]] && printf '# salt %s\n' "$3"
  } > "$2"
  chmod 755 "$2"
}

mkbin v9.9.9 "$WORK/mosdns.good"
GOOD_SHA="$(sha256sum "$WORK/mosdns.good" | cut -d' ' -f1)"

mkvers(){  # $1=仓库目录 $2=MOSDNS_VER $3=钉的 sha
  mkdir -p "$1/lib"
  { printf 'MOSDNS_VER="%s"\n' "$2"
    printf 'declare -A PDG_SHA256=( [mosdns-bin-amd64]="%s" [mosdns-bin-arm64]="%s" )\n' "$3" "$3"
    # 判据从**真的那份**取, 不在测试里另抄一遍
    sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p' "$ROOT/lib/versions.sh"
  } > "$1/lib/versions.sh"
}
mkvers "$WORK/vrepo" v9.9.9 "$GOOD_SHA"

ask(){     # $1=候选路径 [$2=仓库目录] → "rc|输出"; 每次先清 marker
  local repo="${2:-$WORK/vrepo}" rc=0 out
  rm -f "$MARK"
  out=$(bash -c "
    c_y(){ echo \"\$*\"; }
    c_g(){ echo \"\$*\"; }
    REPO_DIR='$repo'
    source '$WORK/pre.sh'
    _update_mosdns_preflight '$1'" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}

echo "══ 1. 摘要不符 + 自报正确版本: 拒绝, 且**一次都不许执行** ══"
mkbin v9.9.9 "$BIN/mosdns" tampered-same-version
r=$(ask "$BIN/mosdns"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "预检拒绝(rc=$rc)" || bad "摘要不符竟然放行(rc=0)"
[[ -e "$MARK" ]] && bad "**候选文件被执行了**(marker 存在)—— 摘要没过就不该跑它" \
                 || ok "候选文件未被执行(marker 不存在)"
grep -q '摘要' <<<"$out" && ok "原因具名到摘要" || bad "没说是摘要问题: $(tr '\n' ' ' <<<"$out"|cut -c1-110)"

echo
echo "══ 2. 摘要不符 + 自报另一个版本: 仍不执行, 且不得走旧的 rc=5 放行 ══"
mkbin v1.2.3 "$BIN/mosdns" tampered-other-version
r=$(ask "$BIN/mosdns"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "预检拒绝(rc=$rc)" \
  || bad "**摘要不符却因为「版本漂移」被放行**(rc=0)—— 未知内容不能靠自报版本洗白"
[[ -e "$MARK" ]] && bad "**候选文件被执行了**(marker 存在)" || ok "候选文件未被执行(marker 不存在)"
grep -q '收敛' <<<"$out" && bad "仍在说「会收敛到钉死版」—— 那是 rc=5 放行的措辞" \
  || ok "没有再把摘要不符说成版本漂移"

echo
echo "══ 3. 摘要相符 + version 正常: 放行(此时执行是允许的)══"
cp "$WORK/mosdns.good" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); rc="${r%%|*}"
[[ "$rc" == 0 ]] && ok "预检放行(rc=0)" || bad "合法却被拒(rc=$rc): ${r#*|}"
[[ -e "$MARK" ]] && ok "摘要过了之后才执行它(marker 存在, 这是预期)" \
                 || ok "摘要过了, 是否执行由判据决定(marker 不存在也可接受)"

echo
echo "══ 4. 摘要相符 + version 非零: 具名失败 ══"
{ echo '#!/bin/sh'; printf ': > "%s"\n' "$MARK"; echo 'exit 3'; } > "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
mkvers "$WORK/v_rc3" v9.9.9 "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)"
r=$(ask "$BIN/mosdns" "$WORK/v_rc3"); rc="${r%%|*}"; out="${r#*|}"
[[ "$rc" != 0 ]] && ok "预检拒绝(rc=$rc)" || bad "version 非零却放行"
grep -qE '非零|命令' <<<"$out" && ok "原因具名到 version 命令" \
  || bad "原因不具名: $(tr '\n' ' ' <<<"$out"|cut -c1-110)"

echo
echo "══ 5. 摘要相符但自报版本与钉值不一致: 拒绝(钉值/资产自相矛盾)══"
mkbin v1.2.3 "$BIN/mosdns"
mkvers "$WORK/v_mismatch" v9.9.9 "$(sha256sum "$BIN/mosdns" | cut -d' ' -f1)"
r=$(ask "$BIN/mosdns" "$WORK/v_mismatch"); rc="${r%%|*}"
[[ "$rc" != 0 ]] && ok "预检拒绝(rc=$rc)—— 钉值指着一个自报版本对不上的文件, 不能放行" \
  || bad "钉值与资产自相矛盾却放行(rc=0)"

echo
echo "══ 6. 文件不存在 / 不可执行 / 本架构无钉值: 各自具名失败 ══"
rm -f "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); [[ "${r%%|*}" != 0 ]] && grep -q '不存在' <<<"${r#*|}" \
  && ok "[不存在] 具名拒绝" || bad "[不存在] 未具名拒绝: ${r#*|}"
cp "$WORK/mosdns.good" "$BIN/mosdns"; chmod 644 "$BIN/mosdns"
r=$(ask "$BIN/mosdns"); [[ "${r%%|*}" != 0 ]] && grep -qE '执行不了|不可执行' <<<"${r#*|}" \
  && ok "[不可执行] 具名拒绝" || bad "[不可执行] 未具名拒绝: ${r#*|}"
chmod 755 "$BIN/mosdns"
mkdir -p "$WORK/v_noarch/lib"
{ printf 'MOSDNS_VER="v9.9.9"\n'; printf 'declare -A PDG_SHA256=( [mihomo-bin-amd64]="x" )\n'
  sed -n '/^pdg_mosdns_binary_ok(){/,/^}/p' "$ROOT/lib/versions.sh"; } > "$WORK/v_noarch/lib/versions.sh"
r=$(ask "$BIN/mosdns" "$WORK/v_noarch"); [[ "${r%%|*}" != 0 ]] \
  && ok "[本架构无钉值] 拒绝(fail-closed, 不在存疑时动手)" || bad "[本架构无钉值] 放行了"

echo
echo "══ 7. 正常跨正式版本升级不受影响 ══"
# 真机形态: 预检跑在 reset **之前**, 读的是**旧 checkout 的 versions.sh**。一台同步的旧版
# 机器上, 旧钉值与盘上那个旧二进制本来就一致 → 预检通过 → 更新过程再把它换到新钉值。
mkbin v5.3.3 "$WORK/mosdns.old"
cp "$WORK/mosdns.old" "$BIN/mosdns"; chmod 755 "$BIN/mosdns"
mkvers "$WORK/v_old" v5.3.3 "$(sha256sum "$WORK/mosdns.old" | cut -d' ' -f1)"
r=$(ask "$BIN/mosdns" "$WORK/v_old"); rc="${r%%|*}"
[[ "$rc" == 0 ]] && ok "旧版机器(旧 versions.sh + 与旧钉值一致的旧二进制)预检通过" \
  || bad "正常旧版机器被拦下了(rc=$rc)—— 这条路必须畅通: ${r#*|}"

echo
echo "══ 8. 拒绝路径不产生任何副作用 ══"
# 预检函数体内不得出现快照 / reset / 取件 / 迁移 / 重启。cmd_update 层面的顺序由
# test-update-mosdns-preflight.sh 的 3B 真跑一遍, 这里守的是函数本身。
# 只认**真正的动作**, 不认文案。拒绝时那句"未建快照, 未 reset…"里就带着这些词 ——
# 按词面扫会把如实说明当成副作用, 那是判据在看噪声(我第一版就这么误报了一次)。
for pat in 'cmd_snapshot' '_snapshot_' 'git .*reset' 'curl ' 'wget ' '__migrate' \
           'systemctl restart' 'systemctl start' 'daemon-reload' 'install -m'; do
  if grep -qE "^[^#]*$pat" "$WORK/pre.sh"; then
    bad "预检函数体里出现了副作用动作: $pat"
  else
    ok "预检函数体不含副作用动作: $pat"
  fi
done
grep -q '没动任何文件' "$WORK/pre.sh" && ok "拒绝时明说了没动任何文件" \
  || bad "拒绝时没说清有没有动过东西"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
exit $(( nfail > 0 ? 1 : 0 ))

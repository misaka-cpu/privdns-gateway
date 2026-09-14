#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役 · **错误输出能力**回归(PDG-WLOC-CR-01)。
#
# 缺陷长这样: deploy/bot/pdg.sh 调用 c_r 七处, 全仓却**没有任何地方定义它**。跑到那些
# 路径时 bash 打一句 "c_r: command not found", 而给用户的标题 ——
#   「❌ WLOC 退役: … 本次未做任何改动。」
#   「   ⚠️ **回滚本身也有步骤失败** …」
#   「   ⚠️ 回滚失败: …」
# —— 整句丢失。判定与退出码一直是对的, 缺的是把原因说出来的能力。
# 最难看的是回滚不完整那一格: 幸存下来的 c_y 那两行写着"上面那句是本来为什么失败, 这一句
# 是恢复没做干净", 而它指的两句**都不存在**。
#
# 这一支为什么能挡住复发:
#   · 判据是**具名行为**("那句标题在不在"), 不是"源码里有没有 c_r" 这种恒真静态检查;
#   · 输出函数**从产品文件里抽出来用**, 测试自己不提供替代实现 —— 以前几支 WLOC 退役测试
#     各自写了 `c_r(){ :; }`, 等于测试替生产补了一个它没有的函数, 那条路径于是永远不报错;
#   · 自带**反向对照**: 把产品里那一行定义去掉(只改临时副本, 不碰仓库)再跑一遍, 每个场景
#     都必须转红, 且红在"标题缺失", 不是夹具自己崩;
#   · 拒绝类场景同时验"现场一个字节都没动" —— 契约是"拒绝且零改动", 只看红字不算数。
#
# 抽函数而不是 source 整个 pdg.sh: 那个文件末尾会跑主入口。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

# ── 从产品文件里抽一个函数 ──────────────────────────────────────────────────
# 两种形态都要认: c_g/c_y/c_r 是**单行**定义, migrate_wloc_retire 这类是多行。
# 多行用仓库里既有的那个区间写法(到独占一行的 `}` 为止) —— 函数体内有以 `}` 结尾的行,
# 按"第一个以 } 结尾的行"截断会把函数腰斩。
_fn(){   # $1=文件 $2=函数名
  local one
  one="$(grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1" 2>/dev/null || true)"
  if [[ -n "$one" ]]; then printf '%s\n' "$one"; return 0; fi
  sed -n "/^$2(){/,/^}/p" "$1"
}

# ── 造一台"开着 WLOC 的老机器"的最小现场 ────────────────────────────────────
# 只用 PDG_RETIRE_ROOT 前缀, 不碰宿主任何真实路径; systemctl 是本场景自己的记账桩
# (这一支测的是**输出**, 不是服务管理; 真 systemd 的那一格由 tests/e2e-real-migration.sh 管)。
mkroot(){   # $1=场景名  → 打印 root 路径
  local d="$BOX/$1"
  mkdir -p "$d"/etc/{mosdns/rules,privdns-gateway/ca,mihomo,systemd/system} \
           "$d"/opt/pdg-bot "$d"/var/lib/privdns-gateway || return 1
  printf 'gs-loc.apple.com\ngs-loc-cn.apple.com\n' > "$d/etc/mosdns/rules/mitm_hijack.txt"
  printf '{\n  "wloc": { "enabled": true, "locations": [] }\n}\n' > "$d/etc/privdns-gateway/mitm.json"
  : > "$d/opt/pdg-bot/mitm_server.py"
  : > "$d/opt/pdg-bot/mitm_wloc.py"
  : > "$d/etc/systemd/system/pdg-mitm.service"
  printf '%s\n' "$d"
}

# 现场指纹: 拒绝类场景必须"一个字节都没动"。存在性 + 内容 + mode 一起算。
fingerprint(){   # $1=root
  ( cd "$1" && find . -type f -printf '%P %m ' -exec sha256sum {} \; 2>/dev/null | sort ) | sha256sum
}

# ── 跑一个场景 ──────────────────────────────────────────────────────────────
# $1=用哪份 pdg.sh  $2=场景(stray|static|undofail|clean)  $3=root
# 结果落在 $BOX/out(stdout) 与 $BOX/err(stderr), 返回被测函数的 rc。
run_case(){
  local src="$1" what="$2" root="$3" s="$BOX/case.sh"
  {
    echo 'set -uo pipefail'
    # **产品真实的纯输出函数**。抽不到就是抽不到 —— 测试不补替代实现。
    _fn "$src" c_g
    _fn "$src" c_y
    _fn "$src" c_r
    # 失败分支现在会调它给"该重跑什么"的指引 —— 同样从产品里抽真身, 不补替代实现。
    _fn "$src" _retire_rerun_hint
    # 这一条**本来就漏了**(冻结候选上 ④ 就因为它报 command not found): 少了它,
    # `if _retire_has_irreversible_work …` 恒为假, 能力门那一段在本支里从来没被走到过。
    _fn "$src" _retire_has_irreversible_work
    grep -m1 -E '^REPO_DIR=' "$src"      # _retire_ca_reader_dir 用得到, 从产品里取免得漂移
    echo '_RETIRE_UNDO=(); _RETIRE_TMP=""'
    echo '_retire_core_has_mitm(){ return 1; }'
    case "$what" in
      stray|clean)
        echo 'systemctl(){ case "$1" in is-active) echo inactive; return 3;; is-enabled) echo disabled; return 1;; esac; return 0; }';;
      static)
        # 自启状态 static: 既不能 enable 也不能 disable, 产品必须在动手之前整笔拒绝。
        echo 'systemctl(){ case "$1" in is-active) echo active; return 0;; is-enabled) echo static; return 0;; esac; return 0; }';;
      undofail)
        echo 'systemctl(){ return 0; }';;
    esac
    if [[ "$what" == undofail ]]; then
      _fn "$src" _retire_cleanup
      _fn "$src" _retire_undo_run
      _fn "$src" _retire_fail
      echo "_RETIRE_TMP=\"$root/.recovery-material\""
      echo 'mkdir -p "$_RETIRE_TMP"; printf keep > "$_RETIRE_TMP/pdg-mitm.service.bak"'
      # 一条**必然失败**的撤销动作: 回滚不完整这一格要的就是它。
      echo '_RETIRE_UNDO=("false")'
      echo '_retire_fail "停服务失败(本用例构造)。"'
      echo 'echo "RC=$?"'
    else
      _fn "$src" _retire_enable_supported
      # 「无事可做」那条短路仍会走到 schema 与 CA 报告两步 —— 它们也要用产品原文,
      # 少抽一个就会在正常路径上冒出别的 "command not found", 把本用例的判据搅浑。
      # _retire_ca_report 现在先问 _retire_ca_reader_dir "检查器在哪儿" —— 少抽它,
      # 正常路径会冒出一条与本用例无关的 command not found, 把 stderr 判据搅浑。
      _fn "$src" _retire_ca_reader_dir
      _fn "$src" _retire_ca_report
      _fn "$src" _retire_report_ca
      _fn "$src" _retire_ios_schema
      _fn "$src" migrate_wloc_retire
      echo "PDG_RETIRE_ROOT=\"$root\" migrate_wloc_retire"
      echo 'echo "RC=$?"'
    fi
  } > "$s"
  bash "$s" > "$BOX/out" 2> "$BOX/err"
  grep -oE 'RC=[0-9]+' "$BOX/out" | tail -1 | cut -d= -f2
}

# 产品原文 + 一份**去掉 c_r 定义**的反向副本(只改副本, 仓库一个字节不动)
PDG_NOCR="$BOX/pdg-no-cr.sh"
grep -vE '^c_r\(\)\{' "$PDG" > "$PDG_NOCR"
if [[ "$(grep -cE '^c_r\(\)\{' "$PDG")" == 1 && "$(grep -cE '^c_r\(\)\{' "$PDG_NOCR")" == 0 ]]; then
  ok "反向副本就位: 产品里有 1 处 c_r 定义, 副本里 0 处(只删这一行, 其余逐字节相同)"
else
  bad "反向副本没造对 —— 后面的对照失去依据(产品里 $(grep -cE '^c_r\(\)\{' "$PDG") 处)"
fi
[[ "$(diff <(grep -vE '^c_r\(\)\{' "$PDG") "$PDG_NOCR" | wc -l)" == 0 ]] \
  && ok "反向副本与产品原文的差异**仅**是那一行定义" || bad "反向副本还动了别的行"

# ══ ① 拒绝执行: 劫持表归属不清 ══════════════════════════════════════════════
echo; echo "══ ① 拒绝执行 · 劫持表里有不属于 WLOC 的条目 ══"
for variant in fixed nocr; do
  d="$(mkroot "stray-$variant")"
  printf 'gs-loc.apple.com\nmy-own-thing.example.com\n' > "$d/etc/mosdns/rules/mitm_hijack.txt"
  fp0="$(fingerprint "$d")"
  src="$PDG"; [[ "$variant" == nocr ]] && src="$PDG_NOCR"
  rc="$(run_case "$src" stray "$d")"
  if [[ "$variant" == fixed ]]; then
    grep -q '❌ WLOC 退役:' "$BOX/out" \
      && ok "① 修后: 标题「❌ WLOC 退役: …」真实可见" || bad "① 修后: 标题仍然缺失"
    grep -q '本次未做任何改动' "$BOX/out" \
      && ok "① 修后: 「本次未做任何改动」这句话到达了用户" || bad "① 修后: 没说现场动没动"
    grep -q 'my-own-thing.example.com' "$BOX/out" \
      && ok "① 修后: 点名了那条不属于 WLOC 的域名" || bad "① 修后: 没点名"
    grep -q 'command not found' "$BOX/err" \
      && bad "① 修后: stderr 里仍有未定义函数: $(grep -m1 'command not found' "$BOX/err")" \
      || ok "① 修后: stderr 里没有未定义函数"
  else
    grep -q 'c_r: command not found' "$BOX/err" \
      && ok "① 撤销定义(反向对照): stderr 出现 c_r: command not found" \
      || bad "① 撤销定义后没出现 command not found —— 对照失效"
    grep -q '❌ WLOC 退役:' "$BOX/out" \
      && bad "① 撤销定义后标题竟然还在 —— 判据抓不住这个缺陷" \
      || ok "① 撤销定义(反向对照): **标题整句丢失**(这正是修前用户看到的样子)"
    grep -q '归属不清就不能一把清空' "$BOX/out" \
      && ok "① 撤销定义后后续解释(c_y)反倒还在 —— 输出成了没有起因的补充说明" \
      || bad "① 反向对照: 连 c_y 的解释都没了, 说明夹具自己崩了而不是缺陷复现"
  fi
  # 两种形态都必须"拒绝且零改动" —— 这条与输出无关, 撤销定义不该改变它
  [[ "$rc" != 0 ]] && ok "① $variant: 返回非 0(rc=$rc)" || bad "① $variant: 归属不清却返回 0"
  [[ "$(fingerprint "$d")" == "$fp0" ]] \
    && ok "① $variant: 现场一个字节都没动(存在性/内容/mode 全量指纹一致)" \
    || bad "① $variant: 拒绝了却改了现场"
done

# ══ ② 拒绝执行: 自启状态不支持(static)══════════════════════════════════════
echo; echo "══ ② 拒绝执行 · pdg-mitm 的自启状态是 static ══"
for variant in fixed nocr; do
  d="$(mkroot "static-$variant")"
  fp0="$(fingerprint "$d")"
  src="$PDG"; [[ "$variant" == nocr ]] && src="$PDG_NOCR"
  rc="$(run_case "$src" static "$d")"
  if [[ "$variant" == fixed ]]; then
    grep -q '自启状态是 static' "$BOX/out" \
      && ok "② 修后: 标题写出了**实际的**自启状态(static), 不是泛泛一句失败" \
      || bad "② 修后: 没说清自启状态是什么"
    grep -q '本次未做任何改动' "$BOX/out" \
      && ok "② 修后: 「本次未做任何改动」可见" || bad "② 修后: 没说现场动没动"
    grep -q 'command not found' "$BOX/err" && bad "② 修后: stderr 仍有未定义函数" \
      || ok "② 修后: stderr 干净"
  else
    grep -q '自启状态是 static' "$BOX/out" \
      && bad "② 撤销定义后标题还在 —— 判据抓不住" \
      || ok "② 撤销定义(反向对照): 「自启状态是 static」整句丢失"
  fi
  [[ "$rc" != 0 ]] && ok "② $variant: 返回非 0(rc=$rc)" || bad "② $variant: 不支持的自启状态却返回 0"
  [[ "$(fingerprint "$d")" == "$fp0" ]] \
    && ok "② $variant: 现场一个字节都没动" || bad "② $variant: 拒绝了却改了现场"
done

# ══ ③ 回滚不完整: 三件事必须同时说出来, 且互不遮盖 ══════════════════════════
echo; echo "══ ③ 回滚不完整 · 原始失败 / 恢复失败 / 材料路径 ══"
for variant in fixed nocr; do
  d="$(mkroot "undofail-$variant")"
  src="$PDG"; [[ "$variant" == nocr ]] && src="$PDG_NOCR"
  rc="$(run_case "$src" undofail "$d")"
  if [[ "$variant" == fixed ]]; then
    grep -q '❌ WLOC 退役: 停服务失败' "$BOX/out" \
      && ok "③ 修后: **原始失败**可见(本来为什么失败)" || bad "③ 修后: 原始失败丢了"
    grep -q '回滚失败' "$BOX/out" \
      && ok "③ 修后: **恢复失败**逐条可见(哪一步没撤回去)" || bad "③ 修后: 恢复失败丢了"
    grep -q '回滚本身也有步骤失败' "$BOX/out" \
      && ok "③ 修后: 明确点出「回滚本身也有步骤失败」" || bad "③ 修后: 没点出回滚不完整"
    grep -q '恢复材料' "$BOX/out" && grep -q "$d/.recovery-material" "$BOX/out" \
      && ok "③ 修后: **材料路径**打了出来(用户找得到东西)" || bad "③ 修后: 材料路径没打出来"
    # 互不遮盖: 三件事各自独立出现, 不是一句话糊过去
    n3=0
    grep -q '停服务失败' "$BOX/out"           && n3=$((n3+1))
    grep -q '回滚失败' "$BOX/out"             && n3=$((n3+1))
    grep -q "$d/.recovery-material" "$BOX/out" && n3=$((n3+1))
    [[ "$n3" == 3 ]] && ok "③ 修后: 原始失败 / 恢复失败 / 材料路径三者同时在场, 互不遮盖" \
                     || bad "③ 修后: 三件事只到了 $n3 件"
    [[ -s "$d/.recovery-material/pdg-mitm.service.bak" ]] \
      && ok "③ 修后: 恢复材料**真的还在盘上**(没有被收尾顺手删掉)" || bad "③ 修后: 材料被删了"
    grep -q 'command not found' "$BOX/err" && bad "③ 修后: stderr 仍有未定义函数" \
      || ok "③ 修后: stderr 干净"
  else
    grep -q '❌ WLOC 退役: 停服务失败' "$BOX/out" \
      && bad "③ 撤销定义后原始失败还在 —— 判据抓不住" \
      || ok "③ 撤销定义(反向对照): **原始失败整句丢失**"
    grep -q '回滚本身也有步骤失败' "$BOX/out" \
      && bad "③ 撤销定义后「回滚不完整」还在" \
      || ok "③ 撤销定义(反向对照): 「回滚本身也有步骤失败」整句丢失"
    # 最难看的一格: 幸存的 c_y 指着两句不存在的话
    if grep -q '上面那句是本来为什么失败' "$BOX/out"; then
      ok "③ 撤销定义(反向对照): 幸存的解释行仍写着「上面那句…这一句…」, 而它指的两句都不在 —— 用户读到的是悬空指代"
    else
      bad "③ 反向对照: 连 c_y 的解释都没了, 夹具自己崩了"
    fi
    grep -q "$d/.recovery-material" "$BOX/out" \
      && ok "③ 撤销定义后材料路径仍可见(它走 c_y)—— 所以丢的确实只是红色那三句" \
      || bad "③ 反向对照: 材料路径也没了, 不是本缺陷的形态"
  fi
  [[ "$rc" == 1 ]] && ok "③ $variant: _retire_fail 返回 1" || bad "③ $variant: 返回码是 $rc"
done

# ══ ④ 正常路径不受影响 ══════════════════════════════════════════════════════
echo; echo "══ ④ 正常路径(没什么可退役的干净机器)══"
d="$(mkroot clean)"
rm -f "$d/etc/systemd/system/pdg-mitm.service" "$d/opt/pdg-bot/mitm_server.py" \
      "$d/opt/pdg-bot/mitm_wloc.py"
: > "$d/etc/mosdns/rules/mitm_hijack.txt"
printf '{\n  "wloc": { "enabled": false, "locations": [] }\n}\n' > "$d/etc/privdns-gateway/mitm.json"
rc="$(run_case "$PDG" clean "$d")"
[[ "$rc" == 0 ]] && ok "④ 干净机器返回 0" || bad "④ 干净机器返回 $rc: $(tail -3 "$BOX/out")"
grep -q '❌' "$BOX/out" && bad "④ 干净机器却打了错误标题" || ok "④ 干净机器没有任何错误标题"
grep -q 'command not found' "$BOX/err" && bad "④ 正常路径 stderr 有未定义函数" \
  || ok "④ 正常路径 stderr 干净"

# ══ ⑤ 测试自己不许再替生产补函数 ════════════════════════════════════════════
echo; echo "══ ⑤ WLOC 退役各支测试不得自带 c_r 的替代实现 ══"
selfdef=()
for f in "$HERE"/test-wloc-retire-*.sh; do
  [[ "$f" == "${BASH_SOURCE[0]}" ]] && continue
  grep -qE '^[[:space:]]*c_r\(\)' "$f" && selfdef+=("$(basename "$f")")
done
if [[ "${#selfdef[@]}" == 0 ]]; then
  ok "⑤ 没有任何 WLOC 退役测试自己定义 c_r(缺了就该红, 不该被夹具补上)"
else
  bad "⑤ 这些测试自带 c_r 的替代实现, 会把生产缺失遮掉: ${selfdef[*]}"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

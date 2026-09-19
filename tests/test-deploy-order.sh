#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 部署顺序决定「盘上换了新代码, 跑着的还是旧的」会不会发生。
#
# jp2 上出过一次: 我用 bundle 部署时**先** pdg_install_runtime_modules 装了模块, **再**
# 跑 pdg __migrate。而 migrate_deploy_botfiles 的重启判据是"装之前 vs 装之后的模块摘要"——
# 模块已经被我提前装好了, 它前后一算完全相同, 于是认定"没变化"直接返回, 一个服务都没转。
# 结果: /opt/pdg-bot/checks.py 是新的, pdg-bot 进程还持着旧的 checks。
#
# 这支测试把三条路径的真实行为摆出来, 而不是读源码猜:
#   A  旧模块在盘上 + 新 REPO_DIR → 直接 pdg __migrate
#   B  先 pdg_install_runtime_modules 装新模块 → 再 pdg __migrate   ← 我上一轮的顺序
#   C  cmd_update 在 __migrate 之后那段(它自己还会不会重启)
#
# 判据落在**真跑那两个 bash 函数**上, 用留痕的 systemctl 桩看实际发了什么命令。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

FN="$(awk '/^_pdg_modules_digest\(\)\{/,/^\}/' "$ROOT/deploy/bot/pdg.sh")
$(awk '/^migrate_deploy_botfiles\(\)\{/,/^\}/' "$ROOT/deploy/bot/pdg.sh")"
{ [[ -n "$FN" ]] && grep -q "_pdg_modules_digest()" <<<"$FN"; } \
  || { bad "抽不到 migrate_deploy_botfiles / _pdg_modules_digest"; echo "通过 $PASS, 失败 $FAIL"; exit 1; }

# 一个最小仓库替身: 与真 lib/modules.sh 同名同函数, 源文件由用例给定
mkbox(){                    # $1=box 目录; 造出 repo(新版) + dest(旧版已装)
  local box="$1"
  mkdir -p "$box/repo/deploy/bot" "$box/repo/lib" "$box/dest" "$box/bin"
  cat > "$box/repo/lib/modules.sh" <<'M'
PDG_RUNTIME_DIR="${PDG_RUNTIME_DIR:-/opt/pdg-bot}"
pdg_platform_modules(){ printf 'deploy/bot/checks.py checks.py 755\ndeploy/bot/bot.py bot.py 755\n'; }
pdg_validate_modules(){ return 0; }
pdg_install_runtime_modules(){
  local repo="$1" dest="$2" src name mode
  [[ -n "${FAIL_INSTALL:-}" ]] && return 1
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    install -m"$mode" "$repo/$src" "$dest/$name" || return 1
  done < <(pdg_platform_modules)
  return 0
}
M
  printf 'NEW checks\n' > "$box/repo/deploy/bot/checks.py"
  printf 'NEW bot\n'    > "$box/repo/deploy/bot/bot.py"
  printf 'OLD checks\n' > "$box/dest/checks.py"     # 盘上是旧版
  printf 'OLD bot\n'    > "$box/dest/bot.py"
  cat > "$box/bin/systemctl" <<S
#!/bin/sh
echo "systemctl \$*" >> "$box/calls.log"
exit 0
S
  chmod 755 "$box/bin/systemctl"
  : > "$box/calls.log"
}

digest(){ for f in "$1"/*.py; do sha256sum "$f"; done 2>/dev/null | sort | sha256sum | cut -c1-16; }

run_migrate(){              # $1=box; 真跑 migrate_deploy_botfiles
  local box="$1" body
  body="${FN//\/opt\/pdg-bot/$box/dest}"
  bash -c "set -u
PATH=\"$box/bin:\$PATH\"
REPO_DIR=\"$box/repo\"
_pdg_platform(){ echo ios; }
c_g(){ :; }; c_y(){ :; }
$body
migrate_deploy_botfiles" >/dev/null 2>&1
  echo $?
}

echo
echo "── A. 旧模块在盘上 + 新 REPO_DIR → 直接 __migrate ──"
A="$(mktemp -d)"; mkbox "$A"
A_BEFORE="$(digest "$A/dest")"
A_RC="$(run_migrate "$A")"
A_AFTER="$(digest "$A/dest")"
A_CALLS="$(cat "$A/calls.log" 2>/dev/null)"
echo "  盘上摘要 $A_BEFORE → $A_AFTER   rc=$A_RC"
[[ "$A_RC" == 0 ]] && ok "A: 返回 0" || bad "A: 返回 $A_RC"
[[ "$A_BEFORE" != "$A_AFTER" ]] && ok "A: 模块确实被换成新版" || bad "A: 模块没换"
grep -q 'try-restart' <<<"$A_CALLS" && ok "A: 发出了重启(实发: $(grep -m1 restart <<<"$A_CALLS"))" \
                                    || bad "A: 没有重启 —— 盘上新代码, 进程还是旧的"
grep -q 'pdg-mitm' <<<"$A_CALLS" && ok "A: iOS 上 pdg-mitm 也在名单里" || bad "A: 漏了 pdg-mitm"
rm -rf "$A"

echo
echo "── B. 先 pdg_install_runtime_modules, 再 __migrate(上一轮我用的顺序) ──"
B="$(mktemp -d)"; mkbox "$B"
B_BEFORE="$(digest "$B/dest")"
# 提前安装 —— 与 cmd_update 第 55 行、以及我上一轮 bundle 部署做的事完全相同
( source "$B/repo/lib/modules.sh"; pdg_install_runtime_modules "$B/repo" "$B/dest" ios ) >/dev/null 2>&1
B_MID="$(digest "$B/dest")"
: > "$B/calls.log"                       # 只统计迁移期间的调用
B_RC="$(run_migrate "$B")"
B_AFTER="$(digest "$B/dest")"
B_CALLS="$(cat "$B/calls.log" 2>/dev/null)"
echo "  盘上摘要 $B_BEFORE →(提前安装)→ $B_MID →(迁移后)→ $B_AFTER   rc=$B_RC"
[[ "$B_RC" == 0 ]] && ok "B: 迁移返回 0(它认为一切正常)" || bad "B: 返回 $B_RC"
[[ "$B_MID" != "$B_BEFORE" ]] && ok "B: 模块在迁移之前就已被换新" || bad "B: 前提不成立"
[[ "$B_MID" == "$B_AFTER" ]] && ok "B: 迁移看到的 before/after 摘要**完全相同**" \
                             || bad "B: 迁移期间摘要还变了?"
# 这是**特征化断言**, 不是缺陷断言: 迁移的判据("装之前 vs 装之后")本身是对的, 提前安装
# 只是把信号抽走了。B 不是受支持的部署路径 —— A(独立 __migrate)与 C(cmd_update)才是,
# 两条都满足"覆盖了正在运行的模块就必须让服务加载新代码"。所以修的是 SOP 不是产品。
# 钉住这个事实, 是为了以后谁再想"先装模块图省事"时, 这里立刻提醒他后果。
if grep -q 'restart' <<<"$B_CALLS"; then
  bad "B: 居然重启了 —— 与已知行为不符, 说明判据变了, 请重新确认 SOP 是否还需要那条禁令"
else
  ok "B: 提前安装后迁移零重启(判据被掏空)—— 正因如此, SOP 必须禁止这个顺序。\
jp2 上 PID 没变就是这么来的: 盘上 checks.py 是新的, pdg-bot 进程还持着旧的"
fi
rm -rf "$B"

echo
echo "── C. 正常 cmd_update 在 __migrate 之后是否还会重启 ──"
# 抽出 cmd_update 里 `__migrate` 之后那段, 真跑一遍看它发什么命令。
# 不是读源码断言 —— 那段代码是不是真的会执行到 restart, 只有跑过才知道。
#
# 这一节**只**证明一件事: cmd_update 在迁移之后确实发得出那几条重启。它不证明整条升级链
# 跑得通 —— 快照、二进制收敛、三道校验门、doctor 自检门都不在这个片段里, 那些归 e2e。
#
# 锚点为什么要分两层定。盘上的迁移调用带着环境前缀:
#     PDG_UPDATE_SVCSTATE="$snap_dir/svcstate.tsv" bash /usr/local/bin/pdg __migrate
# 而原来的锚点写死 `if ! bash /usr/local/bin/pdg __migrate; then` —— 前缀一加它就是 0 处,
# awk 范围取空, 判据从"迁移之后有没有重启"退化成"抽没抽到", 整节只剩一条红。
# 现在: ① 先切 cmd_update 的函数体(把"仍在 cmd_update 内"这个约束落成范围);
#       ② 在体内找**恰好一处**迁移调用(前缀随便怎么写都认, 但不能有第二处);
#       ③ 从它切到 `sleep 2`, 于是"迁移之后"是**位置**保证的, 不靠文本碰运气。
# 抽取失败 / 片段无效 / 执行失败 三种各自判红, 不合并成一句"没重启" —— 它们的处置完全不同。
# 不新建通用 Bash 解析器: 仍然只做行范围切分 + 选出 systemctl 动作行。
C="$(mktemp -d)"; mkdir -p "$C/bin"
cat > "$C/bin/systemctl" <<S
#!/bin/sh
echo "systemctl \$*" >> "$C/calls.log"
case "\$1" in is-enabled) exit 0;; esac
exit 0
S
chmod 755 "$C/bin/systemctl"; : > "$C/calls.log"
# ① cmd_update 的函数体
CU="$C/cmd_update.txt"
awk '/^cmd_update\(\)\{/{f=1} f{print} f&&/^\}$/{exit}' "$ROOT/deploy/bot/pdg.sh" > "$CU"
C_OK=1
if [[ ! -s "$CU" ]] || ! grep -q '^cmd_update(){' "$CU" || [[ "$(tail -1 "$CU")" != "}" ]]; then
  bad "C: 抽不到 cmd_update 的完整函数体(改名或结构变了)—— 本节判据无效, 不按'没重启'记"; C_OK=0
fi
# ② 体内恰好一处迁移调用
if [[ "$C_OK" == 1 ]]; then
  MIG_N="$(grep -cE 'bash /usr/local/bin/pdg __migrate' "$CU")"
  if [[ "$MIG_N" != 1 ]]; then
    bad "C: cmd_update 里的迁移调用有 $MIG_N 处(要求恰好 1 处)—— 锚点不成立, 本节判据无效"; C_OK=0
  fi
fi
# ③ 迁移调用 → sleep 2
if [[ "$C_OK" == 1 ]]; then
  MIG_L="$(grep -nE 'bash /usr/local/bin/pdg __migrate' "$CU" | head -1 | cut -d: -f1)"
  END_L="$(awk -v s="$MIG_L" 'NR>s && $0=="  sleep 2"{print NR; exit}' "$CU")"
  if [[ -z "$END_L" ]]; then
    bad "C: 迁移调用之后找不到 \`sleep 2\` 这个收尾锚点 —— 切不出'迁移之后'那段, 本节判据无效"; C_OK=0
  fi
fi
if [[ "$C_OK" == 1 ]]; then
  sed -n "${MIG_L},${END_L}p" "$CU" > "$C/post.txt"
  ok "C: 迁移调用在 cmd_update 体内第 $MIG_L 行, 取到 $END_L 行(\`sleep 2\`)为止 —— 片段整体位于迁移之后"
  # 选出这段里的 systemctl 重启类动作。反例走的是同一个函数, 不另写一份。
  _c_seg(){ grep -E 'systemctl (restart|is-enabled|reset-failed)' < "$1" > "$2"; }
  # 执行片段并收集实发命令; 退出码单独带回, 不吞。
  _c_run(){ : > "$C/calls.log"
            bash -c "PATH=\"$C/bin:\$PATH\"
$(cat "$1")" >/dev/null 2>&1; }
  _c_seg "$C/post.txt" "$C/seg.sh"
  if [[ ! -s "$C/seg.sh" ]]; then
    bad "C: 迁移之后那段里一条 systemctl 重启类动作都没有 —— 片段无效"
  elif ! bash -n "$C/seg.sh" 2>/dev/null; then
    bad "C: 抽出来的片段语法不过 —— 执行无效, 不能记成'没重启'"
  else
    ok "C: 抽到了迁移之后的重启段($(grep -c . "$C/seg.sh") 行)"
    C_RC=0; _c_run "$C/seg.sh" || C_RC=$?
    CC="$(cat "$C/calls.log" 2>/dev/null)"
    if [[ "$C_RC" != 0 ]]; then
      bad "C: 片段执行失败(rc=$C_RC)—— 本组判据无效, 同样不记成'没重启'。实发: ${CC:-无}"
    elif [[ -z "$CC" ]]; then
      bad "C: 片段跑完一条 systemctl 都没发出 —— 执行无效"
    else
      # 认的是**具体哪条 restart 打到哪个 unit**, 不是日志里出现过 restart 三个字。
      grep -qE '^systemctl restart( [^ ]+)* pdg-bot( |$)' <<<"$CC" \
        && ok "C: 正常 update 在迁移之后**无条件**重启 pdg-bot(实发: $(grep -m1 '^systemctl restart' <<<"$CC"))" \
        || bad "C: 没有一条 restart 打到 pdg-bot —— 那普通用户升级也会留旧进程。实发: ${CC:-无}"
      grep -qE '^systemctl restart( [^ ]+)* pdg-probe81( |$)' <<<"$CC" \
        && ok "C: pdg-probe81 也在同一条 restart 里" || bad "C: 没有 restart 打到 pdg-probe81。实发: ${CC:-无}"
      grep -qE '^systemctl restart( [^ ]+)* pdg-mitm( |$)' <<<"$CC" \
        && ok "C: pdg-mitm 也被重启(iOS)" || bad "C: 没有 restart 打到 pdg-mitm。实发: ${CC:-无}"
      # ── 反例: 把重启动作从同一段原文里摘掉, 其余逐字不动 ──────────────────
      # 只替换动词, 不删整行: 片段照样跑得起来、照样发得出 systemctl(is-enabled/reset-failed),
      # 所以上面那三条要是还绿, 只可能是它认的东西不对 —— 不是"片段空了"蒙混过去。
      sed 's/systemctl restart/: removed-restart/g' "$C/post.txt" > "$C/post-neg.txt"
      if ! diff -q "$C/post.txt" "$C/post-neg.txt" >/dev/null; then
        _c_seg "$C/post-neg.txt" "$C/seg-neg.sh"
        _c_run "$C/seg-neg.sh"
        NCC="$(cat "$C/calls.log" 2>/dev/null)"
        { ! grep -qE '^systemctl restart( [^ ]+)* pdg-bot( |$)' <<<"$NCC"; } \
          && ok "C-反例: 摘掉重启动作后同一条判据认不到 pdg-bot 的 restart(片段仍发出: ${NCC:-无}) —— 判据有区分力" \
          || bad "C-反例: 重启动作已摘掉, 判据竟仍然通过 —— 它认的不是重启"
      else
        bad "C-反例: 没能在原文里摘掉任何一条 restart —— 反例没有生效, 区分力未验"
      fi
    fi
  fi
fi
rm -rf "$C"

echo
echo "── D. 结论: 标准 bundle 部署不许再用 B 那个顺序 ──"
# 这条守着 SOP: 文档里必须写明正确顺序, 否则下次换人照样按 B 的顺序做。
#
# 判据来源必须是**仓库内受版本控制的文档** —— 早先这里指向开发机上的一个绝对路径
# (/home/<user>/…-HANDOFF.md), 于是本地永远绿、CI runner 上永远红, 而红的原因和被测
# 的部署顺序毫无关系。现在从脚本自身位置算仓库根, 不看 cwd、不看 HOME、不看用户名。
SOP="$ROOT/docs/BRANCH-BUNDLE-DEPLOYMENT.md"
if [[ ! -f "$SOP" ]]; then
  bad "找不到仓库内的部署 SOP: docs/BRANCH-BUNDLE-DEPLOYMENT.md"
else
  ok "SOP 在仓库内(随仓库走, 换机器/换账号都在)"
  # 步骤按**语义标记**查, 不逐字钉整段措辞 —— 文案可以改, 这几件事不能少。
  _miss=()
  grep -q "git bundle create" "$SOP"                      || _miss+=("生成 bundle")
  grep -qE "SHA256|sha256" "$SOP"                          || _miss+=("核对 SHA256")
  grep -q "rev-parse" "$SOP"                               || _miss+=("核对解出的 ref")
  grep -q "REPO_DIR" "$SOP"                                || _miss+=("同步完整 REPO_DIR")
  grep -q "/usr/local/bin/pdg" "$SOP"                      || _miss+=("安装 CLI")
  grep -q "pdg __migrate" "$SOP"                           || _miss+=("运行 pdg __migrate")
  grep -qE "不要提前调用 pdg_install_runtime_modules|不得提前调用 pdg_install_runtime_modules" "$SOP" \
                                                            || _miss+=("禁止提前装模块")
  grep -qE "不得用普通 pdg update|不得用 pdg update" "$SOP" || _miss+=("功能分支不许用 pdg update")
  [[ ${#_miss[@]} -eq 0 ]] && ok "SOP 十步的关键动作齐全" \
    || bad "SOP 缺步骤: ${_miss[*]}"

  # 顺序: 完整 REPO_DIR → CLI → __migrate。
  # 按**编号步骤**比, 不按行号 —— 原理说明里会先提到 `pdg __migrate`("如果在它之前就
  # 先装模块…"), 拿首次出现的行号比会把正确的文档判成写反了。
  _step_of(){                       # $1=要找的标记 → 它所在的 "### N." 步骤号
    awk -v pat="$1" '
      /^### [0-9]+[a-z]*\./ { n = $2; sub(/[a-z]*\./, "", n) }
      index($0, pat) > 0 && n != "" { print n; exit }
    ' "$SOP"
  }
  _s_repo=$(_step_of "REPO_DIR"); _s_cli=$(_step_of "/usr/local/bin/pdg"); _s_mig=$(_step_of "pdg __migrate")
  if [[ -n "$_s_repo" && -n "$_s_cli" && -n "$_s_mig" ]] \
     && [[ "$_s_repo" -lt "$_s_cli" && "$_s_cli" -lt "$_s_mig" ]]; then
    ok "SOP 顺序正确: 第 $_s_repo 步 REPO_DIR → 第 $_s_cli 步 CLI → 第 $_s_mig 步 __migrate"
  else
    bad "SOP 顺序不对: REPO_DIR=第${_s_repo:-?}步 CLI=第${_s_cli:-?}步 __migrate=第${_s_mig:-?}步(必须严格递增)"
  fi

  # "提前装模块"不许出现在 __migrate **之前**的步骤里。同样按步骤号比 —— 禁令那一步
  # (以及它的补充说明)本来就排在 __migrate 后面, 按行号比会把正确的文档判红。
  _bad_step=$(awk -v mig="$_s_mig" '
    /^### [0-9]+[a-z]*\./ { n = $2; sub(/[a-z]*\./, "", n) }
    /pdg_install_runtime_modules/ {
      # `<=` 而不是 `<`: 把"先装模块"塞进 __migrate 那一步(或拆成 6/6b)同样是写反了,
      # 用 `<` 会让它们算成同一步而放过去 —— 负控实测正是这么漏的。
      if (n != "" && n + 0 <= mig + 0 && $0 !~ /不要提前|不得提前|不能提前|禁止/) { print n; exit }
    }' "$SOP")
  [[ -z "$_bad_step" ]] && ok "SOP 没有把「提前装运行模块」写进 __migrate 之前的步骤" \
    || bad "SOP 第 $_bad_step 步(在 __migrate 之前)把提前装模块写成了正向动作"
fi

# 静态判据: 别再有人把判据指回宿主绝对路径。
_hostref=$(grep -rlE "/home/[a-z][a-z0-9_-]*/privdns-gateway-HANDOFF\.md" "$ROOT/tests" 2>/dev/null | tr '\n' ' ')
[[ -z "$_hostref" ]] && ok "tests/ 里没有指向宿主 HANDOFF 绝对路径的引用" \
  || bad "这些测试仍读宿主绝对路径: $_hostref"
_homeref=$(grep -nE "/home/[a-z][a-z0-9_-]*/" "$ROOT/tests/test-deploy-order.sh" | grep -v "^[0-9]*:#" | head -1)
[[ -z "$_homeref" ]] && ok "本测试里没有任何用户主目录绝对路径" \
  || bad "本测试仍有主目录绝对路径: $_homeref"

echo "────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

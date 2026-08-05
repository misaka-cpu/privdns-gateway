#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 换过运行模块就必须重启用它们的服务 —— 否则"盘上是新代码、跑着的是旧的"。
#
# 这个坑两天里踩了两次, 都是我手工部署时漏掉:
#   · `.153`: 装完新模块没重启 pdg-bot → Telegram 菜单里根本没有「📡 手机链路测试」,
#     而 `pdg status` 显示的版本、`/opt/pdg-bot/bot.py` 的内容都是新的 —— 从任何一处看
#     都"已经升级了", 只有那个进程还是旧的;
#   · `jp2`: 装完没重启 pdg-probe81 → 新 unit 的 RuntimeDirectory 没生效, /run/pdg-probe81
#     不存在, 建会话直接 STATE_UNWRITABLE。
#
# 两次都不是产品缺陷, 是**部署路径依赖人记得**。这类事不该靠记性: 迁移自己知道有没有换过
# 文件, 就该自己把服务转起来。
#
# 判据落在**真跑那个 bash 函数**上, 并用留痕的 systemctl 桩看它到底发了什么命令。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){ echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# 两个函数都要抽: migrate_deploy_botfiles 靠 _pdg_modules_digest 判断"有没有真的换过文件",
# 只抽前者的话后者是 command not found, 前后摘要都成空串 → 判成"没变" → 永远不重启,
# 那样这支测试会红得莫名其妙(第一版就是这么红的)。
FN="$(awk '/^_pdg_modules_digest\(\)\{/,/^\}/' "$ROOT/deploy/bot/pdg.sh")
$(awk '/^migrate_deploy_botfiles\(\)\{/,/^\}/' "$ROOT/deploy/bot/pdg.sh")"
{ [[ -n "$FN" ]] && grep -q "_pdg_modules_digest()" <<<"$FN"; } \
  && ok "抽到了 migrate_deploy_botfiles 与 _pdg_modules_digest($(grep -c . <<<"$FN") 行)" \
  || { bad "抽不到 —— 判据无从谈起"; echo "通过 $PASS, 失败 $FAIL"; exit 1; }

run_case(){   # $1=platform  $2=change|same|installfail
  local plat="$1" mode="$2"
  local box; box="$(mktemp -d)"
  mkdir -p "$box/repo/deploy/bot" "$box/repo/lib" "$box/dest" "$box/bin"
  # 一份最小的模块清单替身: 与真 lib/modules.sh 同名同函数, 只是源文件是我们造的
  cat > "$box/repo/lib/modules.sh" <<'M'
PDG_RUNTIME_DIR="${PDG_RUNTIME_DIR:-/opt/pdg-bot}"
pdg_platform_modules(){ printf 'deploy/bot/a.py a.py 755\ndeploy/bot/b.py b.py 755\n'; }
pdg_validate_modules(){ return 0; }
pdg_install_runtime_modules(){
  local repo="$1" dest="$2"
  [[ -n "${FAIL_INSTALL:-}" ]] && return 1
  local src name mode
  while read -r src name mode; do
    [[ -n "$src" ]] || continue
    install -m"$mode" "$repo/$src" "$dest/$name" || return 1
  done < <(pdg_platform_modules)
  return 0
}
M
  printf 'v1\n' > "$box/repo/deploy/bot/a.py"
  printf 'v1\n' > "$box/repo/deploy/bot/b.py"
  # dest 先放一份"已装好的"
  cp "$box/repo/deploy/bot/a.py" "$box/dest/a.py"
  cp "$box/repo/deploy/bot/b.py" "$box/dest/b.py"
  [[ "$mode" == change ]] && printf 'v2-新内容\n' > "$box/repo/deploy/bot/b.py"
  # 留痕的 systemctl 桩
  cat > "$box/bin/systemctl" <<S
#!/bin/sh
echo "systemctl \$*" >> "$box/calls.log"
exit 0
S
  chmod 755 "$box/bin/systemctl"
  local pre="PATH=\"$box/bin:\$PATH\"
REPO_DIR=\"$box/repo\"
_pdg_platform(){ echo \"$plat\"; }
c_g(){ :; }; c_y(){ :; }
"
  [[ "$mode" == installfail ]] && pre="FAIL_INSTALL=1
$pre"
  # 真函数里写死了 /opt/pdg-bot, 换成沙箱目录
  local body="${FN//\/opt\/pdg-bot/$box/dest}"
  local rc=0
  bash -c "set -u
$pre
$body
migrate_deploy_botfiles" >/dev/null 2>&1 || rc=$?
  CALLS="$(cat "$box/calls.log" 2>/dev/null || true)"
  RC=$rc
  DEST_B="$(cat "$box/dest/b.py" 2>/dev/null || echo '(缺)')"
  rm -rf "$box"
}

echo
echo "── 1. 模块内容变了 → 必须把用它们的服务转起来 ──"
run_case android change
[[ "$RC" == 0 ]] && ok "返回 0" || bad "返回 $RC"
grep -q 'v2-新内容' <<<"$DEST_B" && ok "新内容确实装进去了(前提成立)" || bad "没装进去: $DEST_B"
grep -qE 'restart .*pdg-bot|restart pdg-bot' <<<"$CALLS" \
  && ok "重启了 pdg-bot(实发: $(grep -m1 restart <<<"$CALLS"))" \
  || bad "没有重启 pdg-bot —— 盘上新代码, 跑着的还是旧的。实发: ${CALLS:-无}"
grep -qE 'restart .*pdg-probe81' <<<"$CALLS" \
  && ok "重启了 pdg-probe81(它的 RuntimeDirectory 只有重启才生效)" \
  || bad "没有重启 pdg-probe81。实发: ${CALLS:-无}"
grep -q 'try-restart' <<<"$CALLS" \
  && ok "用的是 try-restart —— 没装/没启用的服务不会因此报错" \
  || bad "不是 try-restart: 那样在没有该服务的平台上会失败。实发: ${CALLS:-无}"

echo
echo "── 2. 模块没变 → 不做无意义重启 ──"
run_case android same
[[ "$RC" == 0 ]] && ok "返回 0" || bad "返回 $RC"
grep -qE 'restart' <<<"$CALLS" \
  && bad "内容没变却重启了: $CALLS" \
  || ok "内容一致时不重启(每次迁移都重启会平白打断在用的连接)"

echo
echo "── 3. 安装失败 → 传出非零, 且不重启 ──"
run_case android installfail
[[ "$RC" != 0 ]] && ok "安装失败时返回非零($RC)" || bad "安装失败却返回 0"
grep -qE 'restart' <<<"$CALLS" \
  && bad "装了一半还去重启: $CALLS" || ok "失败时不重启"

echo
echo "── 4. iOS 上还要照顾 pdg-mitm ──"
run_case ios change
grep -qE 'restart .*pdg-mitm' <<<"$CALLS" \
  && ok "iOS: pdg-mitm 也在重启名单里(它同样加载 /opt/pdg-bot 下的模块)" \
  || bad "iOS 没重启 pdg-mitm。实发: ${CALLS:-无}"

echo "────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

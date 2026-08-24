#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 反代(pdg-lan)的重新加载必须只走 _lan_apply_proxy 这**一个入口**, 而且必须是
# `systemctl restart`, 不能是 `reload`。
#
# 为什么不能 reload: 生成的 caddy.conf 全局块里是 `admin off`(刻意的 —— 不该为了重载
# 去开 2019 端口), 而 unit 的 ExecReload 是 `caddy reload --config …`, 那条命令**走
# admin API**。于是 reload 必然失败:
#     Post "http://localhost:2019/load": connect: connection refused
# 而出站白名单又是靠 unit 的 ExecStartPre 加载进内核的, reload 根本不跑它。
#
# 两次真机事故都出在这条上:
#   ① acme 的 --reloadcmd 写的是 `systemctl reload pdg-lan 2>/dev/null || true` ——
#      `|| true` 把失败吞了, acme.sh 照样打印 "Reload successful"。后果不在当天:
#      **续期时新证书落盘、Caddy 内存里还是旧的**, 一直用到过期那天所有面板一起报错,
#      全程零告警。
#   ② `pdg lan render` 重新生成了配置却不重启 —— 2026-08-24 撞上: 文件是新的、
#      pdg-lan 还停在 9 小时前, 新规则没进内存, 手工重启才生效。
#
# 这两处的共同形态是"磁盘对了、进程没跟上"。守卫盯的就是这个形态。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT/deploy/bot/pdg.sh"
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ── ① 入口存在, 且用的是 restart ─────────────────────────────────────────────
if grep -q '^_lan_apply_proxy(){' "$F"; then
  ok "入口函数 _lan_apply_proxy 存在"
else
  bad "找不到 _lan_apply_proxy —— 守卫失效(没写? 被改名?)"
fi

if sed -n '/^_lan_apply_proxy()/,/^}/p' "$F" | grep -q 'systemctl restart pdg-lan'; then
  ok "入口里是 restart(白名单靠 ExecStartPre 进内核, reload 不跑它)"
else
  bad "入口里没有 systemctl restart pdg-lan"
fi

# ── ② 全文不许出现 reload pdg-lan ────────────────────────────────────────────
# admin off + ExecReload 走 admin API = reload 必败。写了就是错的, 不分场合。
hits="$(grep -nE 'systemctl +reload +pdg-lan' "$F" || true)"
if [[ -z "$hits" ]]; then
  ok "全文没有 systemctl reload pdg-lan"
else
  bad "这些地方还在 reload(admin off 下必败):"
  printf '%s\n' "$hits" | sed 's/^/    /'
fi

# ── ③ acme 的 reloadcmd: 必须 restart, 且不许吞失败 ──────────────────────────
rc="$(grep -n -- '--reloadcmd' "$F" || true)"
if [[ -z "$rc" ]]; then
  bad "找不到 --reloadcmd —— 判据失效"
else
  if grep -q -- '--reloadcmd "systemctl restart pdg-lan"' "$F"; then
    ok "acme reloadcmd 是 restart 且没有额外修饰"
  else
    bad "acme reloadcmd 形态不对:"; printf '%s\n' "$rc" | sed 's/^/    /'
  fi
  if printf '%s' "$rc" | grep -q '|| *true'; then
    bad "acme reloadcmd 里还有 \`|| true\` —— 它会把失败吞成成功"
  else
    ok "acme reloadcmd 没有 \`|| true\`"
  fi
fi

# ── ④ 写 caddy.conf 的路径都要接上入口 ───────────────────────────────────────
# _lan_render 只负责生成; 调它的每个地方都必须跟一次 _lan_apply_proxy。
callers="$(grep -nE '(^|[^_a-zA-Z])_lan_render' "$F" | grep -v '^\s*[0-9]*:_lan_render()' || true)"
n_call="$(printf '%s' "$callers" | grep -c . || true)"
n_apply="$(grep -cE '(^|[^_a-zA-Z])_lan_apply_proxy' "$F" || true)"
if [[ "$n_apply" -ge 2 ]]; then
  ok "_lan_apply_proxy 有定义之外的调用点($n_apply 处引用)"
else
  bad "_lan_apply_proxy 没有被任何地方调用($n_apply 处引用) —— 写了等于没写"
fi
echo "       (参考: _lan_render 的调用点 $n_call 处)"

# ── ⑤ 空测: 判据要认得出坏形态, 否则它永远绿 ─────────────────────────────────
if grep -qE 'systemctl +reload +pdg-lan' <<<'  systemctl reload pdg-lan 2>/dev/null || true'; then
  ok "反向对照: 判据认得出 reload 这一形态"
else
  bad "判据本身失效 —— 连一行明显的 reload 都匹配不到"
fi

echo "─────────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" -eq 0 ]]

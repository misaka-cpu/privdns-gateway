#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 防火墙模板同步 —— **真执行**回归。
#
# 为什么要单独一支: tests/test-firewall-template-sync.py 验的是静态形状(函数在不在、
# 挂没挂进调度、顺序对不对、参数 fail-closed)和"两版模板的内核指纹不同"。那些全绿, 却
# **从没真的调用过这个迁移函数、也没检查过调用之后规则变了没有** —— 于是本地 14/14 全绿,
# CI 六个升级类 job 全红, 报的还是"缺少 tailscale0 排除规则"。
#
# 这支补的就是那一步: 造一台"已装旧版 inet pdg"的真机现场, 调**生产函数本身**(不复制实现),
# 然后看内核里的规则到底有没有变。
#
# 需要真 nft + 真 /etc/nftables.conf + 仓库在 REPO_DIR —— 也就是 E2E 沙箱那种环境。
# 环境不足就 SKIP 并说明缺什么, 不假装验过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PDG_REPO_OVERRIDE:-$(cd "$HERE/.." && pwd)}"

pass=0; nfail=0; nskip=0
ok(){   echo "[OK]   $1"; pass=$((pass+1)); }
bad(){  echo "[FAIL] $1"; nfail=$((nfail+1)); }
skip(){ echo "[SKIP] $1"; nskip=$((nskip+1)); }
fin(){ echo; echo "──────────────────────────────────────────────"; \
       echo "通过 $pass, 失败 $nfail, 跳过 $nskip"; exit $(( nfail ? 1 : 0 )); }

command -v nft >/dev/null 2>&1 || { skip "缺 nft"; fin; }
[[ $EUID -eq 0 ]] || { skip "需要 root(要真加载 nft 并改 /etc/nftables.conf)"; fin; }
TPL="$ROOT/deploy/firewall/nftables-mihomo.conf"
[[ -f "$TPL" ]] || { skip "找不到模板 $TPL"; fin; }

CONF=/etc/nftables.conf
INCD=/etc/privdns-gateway/nft-input.d
BACKUP="$(mktemp -d)"
restore(){
  [[ -f "$BACKUP/nftables.conf" ]] && cp -a "$BACKUP/nftables.conf" "$CONF"
  rm -f "$INCD/zz-e2e-tplsync.conf"
  nft -f "$CONF" >/dev/null 2>&1 || true
  rm -rf "$BACKUP"
}
trap restore EXIT
[[ -f "$CONF" ]] && cp -a "$CONF" "$BACKUP/nftables.conf"

# ── 造"升级前"现场: 已在 inet pdg, 但规则里没有 Tailscale 隔离 ──────────────────
mkdir -p "$INCD"
echo 'tcp dport 65000 accept   # e2e 用户自定义规则(必须原样保留)' > "$INCD/zz-e2e-tplsync.conf"
USER_SHA="$(sha256sum "$INCD/zz-e2e-tplsync.conf" | cut -d' ' -f1)"

port=22; cidr=172.22.0.0/16
rport="$(python3 "$ROOT/deploy/bot/rescue_const.py" --port 2>/dev/null)"
[[ -n "$rport" ]] || { skip "读不到救援端口常量"; fin; }
sed -e "s|__SSH_PORT__|$port|g" -e "s|__SSH_MATCH__||g" -e "s|__INTERNAL_CIDR__|$cidr|g" -e "s|__RESCUE_PORT__|$rport|g" \
    "$TPL" | grep -v 'iifname "tailscale0"' > "$CONF"
if ! nft -f "$CONF" >/dev/null 2>&1; then bad "旧版现场加载失败(夹具问题)"; fin; fi
OLD_SHA="$(sha256sum "$CONF" | cut -d' ' -f1)"
[[ "$(nft list table inet pdg | grep -c tailscale0)" == 0 ]] \
  && ok "现场就绪: 已在 inet pdg, 内核里没有 tailscale0 排除规则" \
  || { bad "现场没造对(内核里已有 tailscale0 规则)"; fin; }

# ── 调**生产函数本身** ────────────────────────────────────────────────────────
# 只抽函数, 不复制实现; REPO_DIR 指向被测仓库。c_g/c_y 打桩避免颜色码干扰断言。
# shellcheck disable=SC2034  # 由下面 eval 进来的生产函数读取, 静态分析看不到那层引用
REPO_DIR="$ROOT"
# shellcheck disable=SC1090
eval "$(sed -n '/^_rescue_load()/,/^}/p' "$ROOT/deploy/bot/pdg.sh")" 2>/dev/null || true
# 判据 helper 必须一并抽出: 第一次调用走 A 态(重建)不碰它, 第二次走 B/C 态才会调 ——
# 漏了它, 幂等那格会以 command-not-found 的非零失败, 而现象看着像"同步不幂等"。
eval "$(sed -n '/^_fw_live_has_template_invariants()/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
eval "$(sed -n '/^migrate_firewall_template_sync()/,/^}/p' "$ROOT/deploy/bot/pdg.sh")"
c_g(){ echo "    [prod] $*"; }; c_y(){ echo "    [prod] $*"; }

set +e
migrate_firewall_template_sync
RC=$?
set -e

[[ "$RC" == 0 ]] && ok "生产函数返回 0" || bad "生产函数返回 $RC(应为 0)"

# ── 直接检查真实结果 ──────────────────────────────────────────────────────────
NEW_SHA="$(sha256sum "$CONF" | cut -d' ' -f1)"
[[ "$NEW_SHA" != "$OLD_SHA" ]] && ok "持久规则文件已更新" \
  || bad "持久规则文件**没变** —— 同步没有真的发生"

k_pre="$(nft -j list table inet pdg 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["nftables"]; i=0
for x in d:
    r=x.get("rule")
    if not r or r["chain"]!="prerouting": continue
    if "tailscale0" in json.dumps(r["expr"]): print(i); break
    i+=1
' 2>/dev/null)"
k_in="$(nft -j list table inet pdg 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["nftables"]; i=0; ex=None; sa=None
for x in d:
    r=x.get("rule")
    if not r or r["chain"]!="input": continue
    e=json.dumps(r["expr"])
    if "tailscale0" in e and ex is None: ex=i
    if "\"saddr\"" in e and sa is None: sa=i
    i+=1
print("%s %s" % (ex,sa))
' 2>/dev/null)"
[[ -n "$k_pre" ]] && ok "内核 prerouting 出现 tailscale0 排除规则(第 $k_pre 条)" \
  || bad "内核 prerouting **仍没有** tailscale0 排除规则"
read -r ex sa <<<"$k_in"
if [[ "$ex" != None && "$sa" != None && "$ex" -lt "$sa" ]]; then
  ok "内核 input 的排除规则排在来源匹配之前(第 $ex 条 < 第 $sa 条)"
else
  bad "内核 input 排除规则缺失或顺序不对(ex=$ex saddr=$sa)"
fi

[[ -f "$INCD/zz-e2e-tplsync.conf" ]] && \
  [[ "$(sha256sum "$INCD/zz-e2e-tplsync.conf" | cut -d' ' -f1)" == "$USER_SHA" ]] \
  && ok "用户 include 文件逐字节保留" || bad "用户 include 被改写或删除"
nft list table inet pdg 2>/dev/null | grep -q 'dport 65000' \
  && ok "用户自定义规则仍在内核里生效" || bad "用户自定义规则丢了"
nft -c -f "$CONF" >/dev/null 2>&1 && ok "同步后的配置 nft -c 通过" || bad "同步后的配置 nft -c 不过"

# ── 幂等 ─────────────────────────────────────────────────────────────────────
SHA1="$(sha256sum "$CONF" | cut -d' ' -f1)"; MT1="$(stat -c %Y "$CONF")"
SIG1="$(nft -j list table inet pdg | python3 -c 'import json,sys,hashlib;d=json.load(sys.stdin)["nftables"];print(hashlib.sha256("".join(json.dumps(x["rule"]["expr"],sort_keys=True) for x in d if "rule" in x).encode()).hexdigest())')"
set +e; migrate_firewall_template_sync; RC2=$?; set -e
SHA2="$(sha256sum "$CONF" | cut -d' ' -f1)"; MT2="$(stat -c %Y "$CONF")"
SIG2="$(nft -j list table inet pdg | python3 -c 'import json,sys,hashlib;d=json.load(sys.stdin)["nftables"];print(hashlib.sha256("".join(json.dumps(x["rule"]["expr"],sort_keys=True) for x in d if "rule" in x).encode()).hexdigest())')"
[[ "$RC2" == 0 && "$SHA1" == "$SHA2" && "$MT1" == "$MT2" && "$SIG1" == "$SIG2" ]] \
  && ok "二次调用完全幂等(摘要/mtime/内核语义指纹均不变)" \
  || bad "二次调用不幂等(rc=$RC2 sha:$([[ "$SHA1" == "$SHA2" ]] && echo 同 || echo 变) mtime:$([[ "$MT1" == "$MT2" ]] && echo 同 || echo 变) sig:$([[ "$SIG1" == "$SIG2" ]] && echo 同 || echo 变))"

fin

#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 真跑 install.sh 全新安装。用户最初报的
#   `install.sh: line 117: MIHOMO_INSTALLED: unbound variable`
# 就出在这条路上 —— 而且那条报错是**回滚**崩了, 把最初真正的安装失败盖住了。
#
# 打桩范围只限外部世界(apt / certbot / systemd / nft / 内核二进制下载), 安装脚本本身
# 一行没改: 参数收集、渲染、写盘、事务台账、EXIT trap、回滚全是真的。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

command -v openssl >/dev/null 2>&1 || e2e_skip "无 openssl(自签证书要用)"
e2e_stub_system

# 装机会改写 /etc/resolv.conf。容器里那是宿主 bind-mount 进来的, overlay/命名空间都挡不住,
# 写进去之后同一个 job 里后面的 e2e 就没 DNS 了 → 退出时把内容写回。
E2E_RESOLV_SAVE="$(cat /etc/resolv.conf 2>/dev/null)"
restore_resolv(){ [[ -n "$E2E_RESOLV_SAVE" ]] && printf '%s\n' "$E2E_RESOLV_SAVE" > /etc/resolv.conf 2>/dev/null; :; }
trap restore_resolv EXIT

# ── 打桩外部世界 ────────────────────────────────────────────────────────────
mkdir -p /usr/local/sbin
for c in apt-get dpkg certbot vnstat; do
  case "$c" in
    dpkg) cat > "/usr/local/bin/dpkg" <<'S'
#!/bin/sh
[ "$1" = "--print-architecture" ] && { echo amd64; exit 0; }
exit 0
S
      ;;
    *) printf '#!/bin/sh\nexit 0\n' > "/usr/local/bin/$c";;
  esac
  chmod 755 "/usr/local/bin/$c"
done
# 内核/解析器二进制: 装机会下载并校验 SHA, 这里用桩替代下载(下载与 SHA 校验有专门单测)
. "$E2E_ROOT/lib/versions.sh"
cat > /usr/local/bin/curl <<S
#!/bin/sh
# 只拦内核/规则下载: 造出一个"看起来对"的产物; 其余照常失败即可
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -z "\$out" ] && exit 1
case "\$out" in
  *.zip)  printf 'PK\003\004stub' > "\$out";;
  *.gz|*.tgz|*.tar.gz) printf 'stub' > "\$out";;
  *) printf 'stub' > "\$out";;
esac
exit 0
S
chmod 755 /usr/local/bin/curl
# 让"已是钉死版本"成立 → 跳过下载分支(下载本身另有单测覆盖)。
# 宿主已有真二进制时直接用真的(userns 里也改不动它)。
if ! command -v mosdns >/dev/null 2>&1; then
cat > /usr/local/bin/mosdns <<S
#!/bin/sh
case "\$1" in version) echo "v$MOSDNS_VER";; start) sleep 3600;; esac
exit 0
S
chmod 755 /usr/local/bin/mosdns
fi
if ! command -v sing-box >/dev/null 2>&1; then
cat > /usr/local/bin/sing-box <<S
#!/bin/sh
case "\$1" in version) echo "sing-box version $SINGBOX_VER";; check) exit 0;; esac
exit 0
S
chmod 755 /usr/local/bin/sing-box
fi

run_install(){   # $1=额外 env
  # shellcheck disable=SC2086
  env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaaBBbbCCccDDddEEeeFFffGGgg \
      PDG_ALLOWED=1 PDG_PLATFORM=android $1 \
      bash "$E2E_ROOT/install.sh" 2>&1
}
reset_box(){
  rm -rf /etc/mosdns /etc/sing-box /etc/mihomo /etc/privdns-gateway /opt/pdg-bot \
         /usr/local/bin/pdg /usr/local/bin/pdg-set-token /etc/systemd/system/pdg-*.service \
         /etc/systemd/system/mosdns.service /etc/systemd/system/sing-box.service
  rm -rf /tmp/e2e-svc; mkdir -p /tmp/e2e-svc
}

# ══ 1. 全新安装应当成功并落地全套 ════════════════════════════════════════════
echo "── 1. 全新安装 ──"
reset_box
out=$(run_install ""); rc=$?
[[ "$rc" == 0 ]] && ok "install.sh 全新安装成功(exit 0)" || bad "安装失败 rc=$rc: $(tail -6 <<<"$out")"
grep -q 'unbound variable' <<<"$out" && bad "出现 unbound variable(正是用户报的那类)" \
                                     || ok "全程无 unbound variable"
for f in /usr/local/bin/pdg /opt/pdg-bot/bot.py /etc/mosdns/config.yaml \
         /etc/sing-box/config.json /etc/privdns-gateway/backend /etc/nftables.conf \
         /etc/mosdns/rules/custom_hijack.txt; do
  [[ -e "$f" ]] || bad "装完却缺 $f"
done
ok "关键文件全部落地(pdg/bot/mosdns/sing-box/backend/nft/劫持表)"
[[ "$(cat /etc/privdns-gateway/platform 2>/dev/null)" == android ]] \
  && ok "平台标记按 PDG_PLATFORM 落地" || bad "平台标记=$(cat /etc/privdns-gateway/platform 2>/dev/null)"
[[ ! -e /etc/privdns-gateway/platform.guessed ]] \
  && ok "显式指定平台 → 不打推测标记" || bad "显式平台却被当成推测"
# all 模式(默认): 劫持门不应存在(排除式)
[[ "$(grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml)" == 0 ]] \
  && ok "默认 all 模式: mosdns 渲染成排除式(无劫持门)" || bad "all 模式却装了劫持门"
python3 -c "import json,sys; json.load(open('/etc/sing-box/config.json'))" \
  && ok "渲染出的 sing-box 配置是合法 JSON" || bad "config.json 不合法"
grep -q '__[A-Z_]*__' /etc/mosdns/config.yaml /etc/nftables.conf \
  && bad "渲染后仍残留占位符" || ok "模板占位符全部渲染完毕"

# ══ 2. 已有部署 → 默认拒绝重装(引导走 pdg update) ════════════════════════════
echo; echo "── 2. 已有部署上再跑 install.sh ──"
out=$(run_install ""); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '检测到已有 PrivDNS Gateway 部署' <<<"$out"; } \
  && ok "已有部署 → 拒绝并引导用 pdg update" || bad "rc=$rc: $(tail -3 <<<"$out")"

# ══ 3. 安装中途失败 → 回滚必须干净且不掩盖原始错误 ═══════════════════════════
echo; echo "── 3. 注入失败: 回滚路径 ──"
reset_box
# 让核心服务起不来 → 触发安装末尾的"服务未持续运行"判定 → 回滚
cat > /usr/local/bin/systemctl <<'S'
#!/bin/sh
D=/tmp/e2e-svc; mkdir -p "$D"
verb="$1"; shift
now=0; [ "$1" = "--now" ] && { now=1; shift; }
case "$verb" in
  daemon-reload|reset-failed|preset|mask|unmask) exit 0;;
  enable)  for u in "$@"; do echo 1 > "$D/${u}.en"; [ "$now" = 1 ] && echo 1 > "$D/${u}.ac"; done; exit 0;;
  disable) for u in "$@"; do echo 0 > "$D/${u}.en"; [ "$now" = 1 ] && echo 0 > "$D/${u}.ac"; done; exit 0;;
  start|restart) exit 0;;
  stop)    for u in "$@"; do echo 0 > "$D/${u}.ac"; done; exit 0;;
  is-active)  echo inactive; exit 3;;
  is-enabled) echo enabled; exit 0;;
  show) echo 0; exit 0;;
esac
exit 0
S
chmod 755 /usr/local/bin/systemctl
out=$(run_install ""); rc=$?
[[ "$rc" != 0 ]] && ok "核心服务起不来 → 安装返回非0" || bad "服务没起来却报成功"
grep -q 'unbound variable' <<<"$out" && bad "回滚过程出现 unbound variable(用户报的那条)" \
                                     || ok "回滚过程无 unbound variable(原始错误不被掩盖)"
grep -qE '回滚本次全新安装的改动' <<<"$out" && ok "确实进入了回滚流程" || bad "没有回滚: $(tail -4 <<<"$out")"
grep -qE '已回滚到安装前状态|回滚已尽力执行完' <<<"$out" \
  && ok "回滚跑到末尾并给出明确结论" || bad "回滚没跑完"
# 回滚后不该留下本次装的东西
left=""
for f in /usr/local/bin/pdg /opt/pdg-bot /etc/mosdns /etc/sing-box /etc/privdns-gateway; do
  [[ -e "$f" ]] && left="$left $f"
done
[[ -z "$left" ]] && ok "回滚后本次安装的文件/目录已清除" || bad "回滚后残留:$left"
[[ -z "$(find /usr/local/bin -name '*.pdg-preinstall' 2>/dev/null)" ]] \
  && ok "回滚后不残留 .pdg-preinstall 备份" || bad "有备份残留"

# ══ 4. /etc/resolv.conf 删不掉(LXC/Docker 把它 bind-mount 进来)═══════════════
# 这类环境里 `rm -f /etc/resolv.conf` 返 EBUSY, 在 set -e 下会把整场安装打断转入回滚,
# 而屏幕上只看得到"安装失败 → 回滚", 真原因被埋掉。删不掉就原地覆盖内容即可。
echo; echo "── 4. resolv.conf 不可删(容器/LXC 现场) ──"
reset_box; e2e_stub_system
locked=0
if ! rm -f /etc/resolv.conf 2>/dev/null; then
  locked=1                                        # CI 容器里本来就是 bind mount
elif { printf 'nameserver 9.9.9.9\n' > /tmp/rc-orig
       : > /etc/resolv.conf; mount --bind /tmp/rc-orig /etc/resolv.conf; } 2>/dev/null; then
  locked=1
fi
if [[ "$locked" == 1 ]]; then
  out=$(run_install ""); rc=$?
  [[ "$rc" == 0 ]] && ok "resolv.conf 删不掉 → 安装照常完成(不再被 set -e 打断)" \
    || bad "resolv.conf 不可删就装不上 rc=$rc: $(tail -6 <<<"$out")"
  grep -q '127.0.0.1' /etc/resolv.conf 2>/dev/null \
    && ok "内容原地写入成功(网关自身指向本机 mosdns)" || bad "resolv.conf 未更新: $(cat /etc/resolv.conf 2>/dev/null)"
else
  printf '%s\n' "$E2E_RESOLV_SAVE" > /etc/resolv.conf 2>/dev/null
  echo "[SKIP] 本环境造不出不可删的 resolv.conf(不允许 bind mount)"
fi

e2e_summary

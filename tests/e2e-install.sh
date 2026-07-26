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
# 走统一 hook 而不是自己 `trap ... EXIT`: 探针清理也挂在 EXIT 上, 谁后设置谁就把对方顶掉。
e2e_add_exit_hook restore_resolv

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
if ! command -v mihomo >/dev/null 2>&1; then
cat > /usr/local/bin/mihomo <<S
#!/bin/sh
case "\$1" in -v|version) echo "Mihomo Meta $MIHOMO_VER linux amd64";; -t) exit 0;; esac
exit 0
S
chmod 755 /usr/local/bin/mihomo
fi
# tcpdump 桩: 让 detect-internal-range.sh 解析出一个确定的内网卡段(交互用例的 CIDR 探测)
cat > /usr/local/bin/tcpdump <<'S'
#!/bin/sh
printf 'IP 172.22.0.5.55000 > 10.0.0.1.853: tcp\n172.22.0.5\n172.22.0.5\n'
exit 0
S
chmod 755 /usr/local/bin/tcpdump

run_install(){   # $1=额外 env
  # shellcheck disable=SC2086
  env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaaBBbbCCccDDddEEeeFFffGGgg \
      PDG_ALLOWED=1 PDG_PLATFORM=android $1 \
      bash "$E2E_ROOT/install.sh" 2>&1
}
# 交互模式装机: 不预置 PDG_NONINTERACTIVE, 也不预置 CIDR/PLATFORM/TOKEN → 全走交互 read;
# stdin=/dev/null 且无控制终端 → 每个 read 都撞 EOF/无 tty(等价用户报的现场)。只预置无默认值
# 的 DOT 域名。这条路专治 issue #2: 平台探测 `cat` 在 set -e 下的致命赋值 + 交互 read 的 EOF 韧性。
run_install_interactive(){
  env -u PDG_NONINTERACTIVE PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_DOT_DOMAIN=dot.e2e.test \
      bash "$E2E_ROOT/install.sh" </dev/null 2>&1
}
reset_box(){
  # /opt/privdns-gateway 也要清: 留着它, 后面的安装会走"已有 .git 就不复制"的分支,
  # 复制路径压根测不到(mosdns/mihomo 桩留在 /usr/local/bin, 那是本用例自己造的外部世界)
  rm -rf /etc/mosdns /etc/sing-box /etc/mihomo /etc/privdns-gateway /opt/pdg-bot \
         /opt/privdns-gateway \
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

# ══ 1b. 交互全新装: 无输入(EOF/无 tty)也要装完, 不因 set -e 挂在半路(issue #2)═════════
# 回归点: ① 平台探测 `_ep="$(cat …platform)"` 在全新装(文件不存在)时 cat 返 1 → set -e 致命赋值
#         → 回滚; ② 任一交互 read 撞 EOF → set -e → 回滚。两者都该被容错掉, 回落到探测值/默认值。
echo; echo "── 1b. 交互全新装 + 无输入(EOF/无 tty) ──"
reset_box; e2e_stub_system
out=$(run_install_interactive); rc=$?
[[ "$rc" == 0 ]] && ok "交互式安装无输入(EOF)仍成功(exit 0, 未回滚)" \
                 || bad "交互安装挂了 rc=$rc: $(tail -6 <<<"$out")"
grep -q '安装失败 → 回滚' <<<"$out" && bad "触发回滚(issue #2 症状: 平台 cat / read EOF 被 set -e 判死)" \
                                    || ok "未触发回滚"
grep -q 'unbound variable' <<<"$out" && bad "出现 unbound variable" || ok "无 unbound variable"
for f in /usr/local/bin/pdg /opt/pdg-bot/bot.py /etc/mosdns/config.yaml \
         /etc/sing-box/config.json /etc/privdns-gateway/backend /etc/nftables.conf; do
  [[ -e "$f" ]] || bad "交互装完却缺 $f"
done
ok "关键文件全部落地"
[[ "$(cat /etc/privdns-gateway/platform 2>/dev/null)" == android ]] \
  && ok "平台探测无输入 → 回落 android(平台 cat 不再致命)" \
  || bad "平台标记=$(cat /etc/privdns-gateway/platform 2>/dev/null)(平台探测把安装挂了?)"
grep -rq '172\.22\.0\.0/16' /etc/nftables.conf /etc/privdns-gateway 2>/dev/null \
  && ok "CIDR 无输入 → 回落到 tcpdump 探测值 172.22.0.0/16" \
  || bad "CIDR 未回落到探测值(装出来的配置里找不到 172.22.0.0/16)"

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
# ══ profile.env 必须真正落盘(装机选的模式不许悄悄丢) ═══════════════════════
# 旧写法 `{ printf …; [[ -f old ]] && grep -v … old; } > new && mv new old` 在新装时
# `[[ -f old ]]` 为假 → group 返回 1 → `&& mv` 不执行(&& 列表里的失败又不触发 set -e),
# 机器上只剩 profile.env.new: PDG_HIJACK_MODE 根本没落盘, 下一次 pdg restart 读不到就按默认
# all 把 mosdns 形态改回去 —— 用户装机时选的 gfw 就这么没了。
echo; echo "── 6. profile.env 落盘(PDG_HIJACK_MODE=gfw) ──"
reset_box; e2e_stub_system
out=$(run_install "PDG_HIJACK_MODE=gfw"); rc=$?
[[ "$rc" == 0 ]] && ok "gfw 模式全新安装成功" || bad "6: 安装失败 rc=$rc: $(tail -6 <<<"$out")"
[[ -f /etc/privdns-gateway/profile.env ]] \
  && ok "profile.env 确实存在(不再只剩 .new)" || bad "6b: profile.env 没落盘: $(ls -1 /etc/privdns-gateway/)"
[[ ! -e /etc/privdns-gateway/profile.env.new ]] \
  && ok "没有残留 profile.env.new" || bad "6c: 残留 .new"
grep -q '^PDG_HIJACK_MODE=gfw$' /etc/privdns-gateway/profile.env \
  && ok "PDG_HIJACK_MODE=gfw 已持久化" || bad "6d: $(cat /etc/privdns-gateway/profile.env)"
grep -qE '^PDG_LOWMEM=[01]$' /etc/privdns-gateway/profile.env \
  && ok "PDG_LOWMEM 已写入" || bad "6e: 缺 PDG_LOWMEM"
grep -q '^PDG_PLATFORM=android$' /etc/privdns-gateway/profile.env \
  && ok "PDG_PLATFORM 已写入" || bad "6f: 缺 PDG_PLATFORM"
# 5.2/T7: 内网卡段的**唯一真源**。装机把同一个值渲染进 nft 与 mosdns, 真源必须与它们逐字相同 ——
# 三处任一落后, 表现分别是"手机来源不被放行 / 分流劫持全失效 / 救援服务绑到不存在的地址上"。
_cidr_src="$(sed -n 's/^PDG_INTERNAL_CIDR=//p' /etc/privdns-gateway/profile.env | tail -1)"
_cidr_nft="$(grep -oE 'ip saddr [0-9.]+/[0-9]+' /etc/nftables.conf | head -1 | awk '{print $3}')"
_cidr_mos="$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+"' /etc/mosdns/config.yaml | head -1 | tr -d '"')"
[[ -n "$_cidr_src" ]] \
  && ok "6g: profile.env 写入了内网卡段真源($_cidr_src)" || bad "6g: 缺 PDG_INTERNAL_CIDR"
[[ "$_cidr_src" == "$_cidr_nft" && "$_cidr_src" == "$_cidr_mos" ]] \
  && ok "6h: 真源与 nft/mosdns 三处逐字一致" \
  || bad "6h: 三处不一致 src=$_cidr_src nft=$_cidr_nft mosdns=$_cidr_mos"
MOS_SHA="$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)"
grep -q 'geosite_gfw.txt' /etc/mosdns/config.yaml \
  && ok "mosdns 是 gfw 形态(装机选的模式真的生效了)" || bad "6g: mosdns 不是 gfw 形态"

# 第一次 pdg restart / update --dry-run 不得把模式改回 all
PDG_STABLE_SAMPLES=1 pdg restart >/dev/null 2>&1
grep -q '^PDG_HIJACK_MODE=gfw$' /etc/privdns-gateway/profile.env \
  && ok "pdg restart 后模式仍是 gfw" || bad "6h: restart 后被改成 $(sed -n 's/^PDG_HIJACK_MODE=//p' /etc/privdns-gateway/profile.env)"
[[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_SHA" ]] \
  && ok "pdg restart 后 mosdns 形态逐字节未变" || bad "6i: mosdns 形态被迁移改了"
pdg update --dry-run >/dev/null 2>&1
grep -q '^PDG_HIJACK_MODE=gfw$' /etc/privdns-gateway/profile.env \
  && ok "pdg update --dry-run 后模式仍是 gfw" || bad "6j: dry-run 改了模式"
[[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_SHA" ]] \
  && ok "pdg update --dry-run 后 mosdns 形态逐字节未变" || bad "6k: dry-run 改了 mosdns"

# 覆盖重装要保留未知键与 PDG_TFO, 且仍然真正落盘
printf 'PDG_TFO=1\n# 用户自己的注释\nPDG_CUSTOM_KEY=abc\n' >> /etc/privdns-gateway/profile.env
out=$(run_install "PDG_HIJACK_MODE=all PDG_FORCE_REINSTALL=1"); rc=$?
[[ "$rc" == 0 ]] && ok "覆盖重装成功" || bad "6l: 覆盖重装失败 rc=$rc: $(tail -6 <<<"$out")"
{ grep -q '^PDG_TFO=1$' /etc/privdns-gateway/profile.env \
  && grep -q '^PDG_CUSTOM_KEY=abc$' /etc/privdns-gateway/profile.env \
  && grep -q '用户自己的注释' /etc/privdns-gateway/profile.env; } \
  && ok "覆盖重装保留 PDG_TFO / 未知键 / 注释" || bad "6m: $(cat /etc/privdns-gateway/profile.env)"
grep -q '^PDG_HIJACK_MODE=all$' /etc/privdns-gateway/profile.env \
  && ok "覆盖重装把受管键更新为 all" || bad "6n: 受管键没更新"
[[ "$(grep -c '^PDG_HIJACK_MODE=' /etc/privdns-gateway/profile.env)" == 1 ]] \
  && ok "受管键只有一份(没有越写越多)" || bad "6o: 受管键重复"

# 旧文件只含受管键(grep -v 无输出 → 返回 1)也必须成功落盘
printf 'PDG_LOWMEM=0\nPDG_HIJACK_MODE=all\nPDG_PLATFORM=android\n' > /etc/privdns-gateway/profile.env
out=$(run_install "PDG_HIJACK_MODE=gfw PDG_FORCE_REINSTALL=1"); rc=$?
[[ "$rc" == 0 ]] && grep -q '^PDG_HIJACK_MODE=gfw$' /etc/privdns-gateway/profile.env \
  && ok "旧文件只有受管键时也正常落盘(grep -v 无输出不算失败)" \
  || bad "6p: rc=$rc  $(cat /etc/privdns-gateway/profile.env 2>/dev/null)"

# ══ 普通用户 clone + sudo 安装 → 之后 root 直接用 pdg ═════════════════════
# 常见做法: 普通账号 git clone, 再 sudo ./install.sh。复制到 /opt 的副本于是归那个普通用户,
# root 跑 pdg update 时 git 会以 "dubious ownership" 拒绝一切操作 —— 连 describe/tag 都读不到,
# 表现成"检查不出新版"这种莫名其妙的样子。
echo; echo "── 6b. 普通用户 clone + sudo 安装 ──"
reset_box; e2e_stub_system
if id -u pdguser >/dev/null 2>&1 || useradd -m pdguser 2>/dev/null; then
  USERREPO=/home/pdguser/privdns-gateway
  rm -rf "$USERREPO"; cp -a "$E2E_ROOT" "$USERREPO"
  chown -R pdguser:pdguser "$USERREPO" 2>/dev/null || true
  out=$(env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
        PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
        PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaaBBbbCCccDDddEEeeFFffGGgg \
        PDG_ALLOWED=1 PDG_PLATFORM=android \
        bash "$USERREPO/install.sh" 2>&1); rc=$?
  [[ "$rc" == 0 ]] && ok "普通用户 clone + sudo 安装成功" || bad "6b: rc=$rc: $(tail -6 <<<"$out")"
  [[ -d /opt/privdns-gateway/.git ]] && ok "仓库副本已落到 /opt/privdns-gateway" || bad "6b2: 没有仓库副本"
  [[ "$(stat -c %U /opt/privdns-gateway 2>/dev/null)" == root ]] \
    && ok "/opt 仓库属主是 root(不会触发 git dubious ownership)" \
    || bad "6b3: 属主是 $(stat -c %U /opt/privdns-gateway 2>/dev/null)"
  # 之后 root 直接跑 pdg: 版本必须读得出来(不是空, 也不是"未知")
  vout=$(pdg status 2>&1)
  grep -qE '代码版本 +未知' <<<"$vout" && bad "6b4: root 跑 pdg 读不到版本: $(grep 代码版本 <<<"$vout")" \
    || ok "root 直接跑 pdg status 能读到代码版本"
  gout=$(git -C /opt/privdns-gateway describe --tags --always 2>&1)
  grep -q 'dubious ownership' <<<"$gout" && bad "6b5: git 仍报 dubious ownership" \
    || ok "git 在 /opt 仓库上不报 dubious ownership"
  rm -rf "$USERREPO"
else
  echo "[SKIP] 造不出普通用户(无 useradd), 跳过属主用例"
fi

# ══ 仓库复制失败必须中止 ═══════════════════════════════════════════════════
echo; echo "── 6c. /opt 仓库复制失败 ──"
reset_box; e2e_stub_system
# 精确挡住"复制仓库"这一步: 在目标路径上挂一个只读 tmpfs —— rm -rf 删不掉(busy),
# cp -a 也写不进去, 而 /opt 的其它子目录(pdg-bot 等)照常可写, 于是失败必然发生在这一步。
if mkdir -p /opt/privdns-gateway 2>/dev/null \
   && mount -t tmpfs -o ro,size=64k tmpfs /opt/privdns-gateway 2>/dev/null; then
  out=$(run_install ""); rc=$?
  umount /opt/privdns-gateway 2>/dev/null; rm -rf /opt/privdns-gateway
  if [[ "$rc" != 0 ]]; then
    ok "复制仓库失败 → 安装中止(不再 || true 吞掉)"
    grep -qE '复制仓库|/opt/privdns-gateway' <<<"$out" && ok "说明了是仓库复制这一步失败" \
      || bad "6c2: 没说清: $(tail -4 <<<"$out")"
  else
    bad "6c: 复制失败却装成功了: $(tail -4 <<<"$out")"
  fi
else
  echo "[SKIP] 本环境挂不了 tmpfs, 跳过仓库复制失败用例"
fi

echo; echo "── 7. resolv.conf 不可删(容器/LXC 现场) ──"
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

# ══ 8. 卸载遇到 bind-mount 的 resolv.conf ══════════════════════════════════
# 装机那侧已经兼容了(删不掉就原地写内容), 卸载侧却还是直接 rm+mv: 失败也照样宣布"已完成",
# 而机器上留着指向本机 mosdns 的 resolv.conf —— mosdns 刚被卸载, 整机从此没 DNS。
echo; echo "── 8. 卸载时 resolv.conf 不可删 ──"
reset_box; e2e_stub_system
out=$(run_install ""); rc=$?
[[ "$rc" == 0 ]] || bad "8: 准备现场的安装失败 rc=$rc"
printf 'nameserver 9.9.9.9\n' > /etc/resolv.conf.pdg-orig      # 装机留下的备份(上游 DNS)
printf 'nameserver 127.0.0.1\n' > /tmp/rc-now
if mount --bind /tmp/rc-now /etc/resolv.conf 2>/dev/null; then
  out=$(bash "$E2E_ROOT/uninstall.sh" 2>&1); rc=$?
  grep -q 'nameserver 9.9.9.9' /etc/resolv.conf \
    && ok "bind-mount 的 resolv.conf: 内容被原地写回(上游 DNS 恢复)" \
    || bad "8b: 内容没写回: $(cat /etc/resolv.conf)"
  [[ ! -e /etc/resolv.conf.pdg-orig ]] \
    && ok "确认恢复成功后才删掉 .pdg-orig 备份" || bad "8c: 备份没删(说明没确认成功)"
  grep -q '尽量还原 DNS' <<<"$out" && ok "恢复成功时正常宣布完成" || bad "8d: $(tail -3 <<<"$out")"
  umount /etc/resolv.conf 2>/dev/null

  # 连内容都写不进去(整个文件只读)→ 必须明确 warning, 且**保留**备份供用户自救
  reset_box; e2e_stub_system
  out=$(run_install ""); rc=$?
  printf 'nameserver 9.9.9.9\n' > /etc/resolv.conf.pdg-orig
  chmod 444 /tmp/rc-now
  if mount --bind -o ro /tmp/rc-now /etc/resolv.conf 2>/dev/null \
     && ! (printf x > /etc/resolv.conf) 2>/dev/null; then
    out=$(bash "$E2E_ROOT/uninstall.sh" 2>&1); rc=$?
    grep -qE '未能还原|⚠️' <<<"$out" \
      && ok "写不回去 → 明确 warning, 不宣布已完全还原" || bad "8e: $(tail -4 <<<"$out")"
    [[ -e /etc/resolv.conf.pdg-orig ]] \
      && ok "恢复失败时保留 .pdg-orig 备份(用户可自救)" || bad "8f: 备份被删了"
    grep -q 'resolv.conf.pdg-orig' <<<"$out" \
      && ok "给出了手工恢复的具体命令" || bad "8g: 没给恢复指引"
    umount /etc/resolv.conf 2>/dev/null
  else
    umount /etc/resolv.conf 2>/dev/null
    echo "[SKIP] 本环境造不出「连内容都写不进」的 resolv.conf"
  fi
  chmod 644 /tmp/rc-now; rm -f /tmp/rc-now
else
  echo "[SKIP] 本环境不允许 bind mount, 跳过卸载 resolv.conf 用例"
fi

e2e_summary

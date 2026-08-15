#!/usr/bin/env bash
# CI 专用夹具: 在真 PID1 systemd 上搭出两支 DoT E2E 需要的两种形态。
#
#   pre       —— 迁移前形态: 真 mosdns 在跑, 配置是 **v1.9.0 的模板**(没有 witness 受管块),
#                /opt/pdg-bot/dotwitness.py 与 dot-domain 已就位。e2e-dot-migrate.sh 要的
#                就是这个: 它自己调状态机造基线, 所以进场时受管块必须还不存在。
#   deployed  —— 部署完成形态: 在 pre 之上**调用生产状态机** migrate_dotwitness 把 witness
#                四件套装上。e2e-dot-p0.sh 要的是这个。
#
# 纪律:
# · 不复制生产的迁移或安装逻辑。配置走 install.sh 里那个正式 render 闭包(与
#   e2e-dot-witness.sh / e2e-dot-isolation.sh 同一套抽法); 部署走生产的 migrate_dotwitness。
#   本文件自己只做"把外部世界摆好": 证书、规则文件、unit、停掉抢 53 端口的 resolved。
# · 不伪造 mosdns / systemctl / nft / DNS 客户端。抢不到真的就失败, 不降级。
# · 只碰本夹具创建的东西; 卸载交给调用方的 cleanup 步骤(见 workflow)。
set -uo pipefail

MODE="${1:?用法: ci-dot-fixture.sh <pre|deployed> <dot-domain> <v190-mosdns-template>}"
DOM="${2:?缺 DoT 域名}"
V190_TPL="${3:?缺 v1.9.0 mosdns 模板路径}"
R="${PDG_DOTW_REPO:?PDG_DOTW_REPO 未设置}"

die(){ echo "[fixture] ❌ $*" >&2; exit 1; }
say(){ echo "[fixture] $*"; }

# ── 0. 环境硬门: 缺一不可, 一律不降级 ──────────────────────────────────────
[[ "${PDG_E2E_ISOLATED:-}" == 1 ]] || die "需要 PDG_E2E_ISOLATED=1"
[[ "$(id -u)" == 0 ]] || die "需要 root"
[[ "$(ps -p 1 -o comm=)" == systemd ]] || die "PID 1 不是 systemd(当前 $(ps -p 1 -o comm=))"
# 影子桩只盯这四个: 它们在系统里另有真身, /usr/local/bin 抢在 PATH 前面就会顶掉真的。
# mosdns **不在**这个名单里 —— 钉定内核本来就装在 /usr/local/bin, 那是真身不是桩;
# 它是不是真的, 由下面的版本比对回答。
for p in systemctl nft ip python3; do
  [[ -e "/usr/local/bin/$p" ]] && die "发现影子桩 /usr/local/bin/$p —— 上一支测试没清干净, 拒绝在假程序上跑"
done
command -v mosdns >/dev/null || die "没有 mosdns 二进制"
command -v nft >/dev/null || die "没有 nft"
command -v dig >/dev/null || die "没有 dig"
[[ -f "$R/install.sh" && -f "$R/deploy/bot/pdg.sh" ]] || die "快照不完整: $R"
[[ -f "$V190_TPL" ]] || die "取不到 v1.9.0 模板: $V190_TPL"

# 钉定版本必须真命中 —— 版本号取自仓库单一真源, 不写死
# shellcheck source=lib/versions.sh
source "$R/lib/versions.sh"
have="$(mosdns version 2>&1 | head -1)"
[[ "$have" == *"${MOSDNS_VER#v}"* || "$have" == *"$MOSDNS_VER"* ]] \
  || die "mosdns 不是钉定版本 $MOSDNS_VER(实得: $have)"
say "mosdns = $have (钉定 $MOSDNS_VER)"

# ── 1. 让出 53 端口 ────────────────────────────────────────────────────────
# GitHub runner 上 systemd-resolved 占着 53。停它是本夹具的职责, workflow 的 cleanup
# 会把它开回去 —— 这里记一笔它原本开没开, 免得 cleanup 瞎猜。
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  echo enabled > /run/pdg-fixture-resolved.was
else
  echo other > /run/pdg-fixture-resolved.was
fi
systemctl stop systemd-resolved >/dev/null 2>&1 || true
# resolv.conf 指向 127.0.0.53 时 dig 默认走不通; 夹具全程用 @127.0.0.1 显式指定,
# 所以这里不改 resolv.conf —— 少动一样东西, cleanup 就少一样要还原的。

# ── 2. 自签证书(mosdns 的 853 tls_server 要) ───────────────────────────────
install -d -m755 /etc/mosdns/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=$DOM" -addext "subjectAltName=DNS:$DOM" \
  -keyout /etc/mosdns/certs/privkey.pem -out /etc/mosdns/certs/fullchain.pem \
  >/dev/null 2>&1 || die "自签证书生成失败"
chmod 600 /etc/mosdns/certs/privkey.pem
chmod 644 /etc/mosdns/certs/fullchain.pem

# ── 3. 走 install.sh 的正式 render 闭包渲染 v1.9.0 模板 ────────────────────
# 自己替换占位符的话, 产品哪天改了渲染规则这里不会知道 —— 与既有 DoT E2E 同一套抽法。
WORK="$(mktemp -d -t pdg-cifix-XXXXXX)" || die "临时目录失败"
RENDER_SH="$WORK/render.sh"
{ sed -n '/^DOTWITNESS_PORT=/,/^render(){/p' "$R/install.sh" | sed '$d'
  sed -n '/^render(){/,/"\$1"; }$/p' "$R/install.sh"; } > "$RENDER_SH"
grep -q '__DOT_DOMAIN__' "$RENDER_SH" || die "抽到的 render 闭包不含 __DOT_DOMAIN__ 替换 —— 抽错了"

( set -u
  SERVER_IP=203.0.113.1; INTERNAL_CIDR=172.22.0.0/16; CERT_DIR=/etc/mosdns/certs
  SSH_PORT=22; MOSDNS_CACHE=8192; JOURNALD_MAXUSE=200M
  HIJACK_SET_FILE='geosite_geolocation-!cn.txt'
  # shellcheck source=lib/rescue.sh
  source "$R/lib/rescue.sh"
  RESCUE_BIND=203.0.113.1
  DOT_DOMAIN="$DOM"; REPO_DIR="$R"
  export SERVER_IP INTERNAL_CIDR CERT_DIR SSH_PORT MOSDNS_CACHE JOURNALD_MAXUSE
  export HIJACK_SET_FILE PDG_RESCUE_PORT RESCUE_BIND DOT_DOMAIN REPO_DIR
  # shellcheck disable=SC1090
  source "$RENDER_SH" 2>/dev/null || true
  render "$V190_TPL"
) > "$WORK/config.yaml" 2>"$WORK/render.err"
[[ -s "$WORK/config.yaml" ]] || die "render 没产出: $(tail -2 "$WORK/render.err")"
left="$(grep -oE '__[A-Z0-9_]+__' "$WORK/config.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] || die "渲染产物残留占位符: $left"
grep -q 'pdg-dotwitness managed block' "$WORK/config.yaml" \
  && die "v1.9.0 模板里竟然有受管块 —— 取错模板了, 迁移前形态不成立"
say "已渲染 v1.9.0 形态配置($(wc -l <"$WORK/config.yaml") 行, 无受管块)"

install -d -m755 /etc/mosdns/rules
for n in $(grep -oE '/etc/mosdns/rules/[A-Za-z0-9_.!-]+' "$WORK/config.yaml" | sed 's#.*/##' | sort -u); do
  [[ -f "/etc/mosdns/rules/$n" ]] || : > "/etc/mosdns/rules/$n"
done
install -m644 "$WORK/config.yaml" /etc/mosdns/config.yaml

# ── 4. mosdns 服务 ─────────────────────────────────────────────────────────
cat > /etc/systemd/system/mosdns.service <<EOF
[Unit]
Description=mosdns (CI fixture)
After=network.target
[Service]
Type=simple
ExecStart=$(command -v mosdns) start -d /etc/mosdns -c config.yaml
Restart=no
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start mosdns || { journalctl -u mosdns -n 20 --no-pager; die "mosdns 起不来"; }
for _ in $(seq 1 30); do ss -lun 2>/dev/null | grep -q ':53 ' && break; sleep 1; done
ss -lun 2>/dev/null | grep -q ':53 ' || { journalctl -u mosdns -n 20 --no-pager; die "mosdns 没监听 53"; }
dig +short +time=3 +tries=2 @127.0.0.1 example.com A >/dev/null 2>&1 \
  || die "mosdns 起来了但解析不通 —— 后面每条断言都无从判断"
say "mosdns active, 53 在听, 普通解析可用"

# ── 5. 运行模块与 DoT 域名(真更新里由 migrate_deploy_botfiles 落地) ────────
install -d -m755 /opt/pdg-bot
install -m755 "$R/deploy/bot/dotwitness.py" /opt/pdg-bot/dotwitness.py
printf '%s\n' "$DOM" > /opt/pdg-bot/dot-domain
chmod 644 /opt/pdg-bot/dot-domain
[[ "$(sha256sum /opt/pdg-bot/dotwitness.py | cut -d' ' -f1)" \
   == "$(sha256sum "$R/deploy/bot/dotwitness.py" | cut -d' ' -f1)" ]] \
  || die "dotwitness.py 落地后与候选 blob 不一致"
say "dotwitness.py(755) 与 dot-domain 就位, 摘要与候选 blob 一致"

install -d -m755 /etc/privdns-gateway

if [[ "$MODE" == pre ]]; then
  [[ ! -e /etc/systemd/system/pdg-dotwitness.service ]] || die "pre 形态不该已有 witness unit"
  [[ ! -e /etc/privdns-gateway/dotwitness.env ]] || die "pre 形态不该已有 dotwitness.env"
  say "pre 形态就绪(受管块 0, witness 四件套未装)"
  rm -rf "$WORK"; exit 0
fi

[[ "$MODE" == deployed ]] || die "未知模式: $MODE"

# ── 6. deployed: 调**生产**状态机, 不自己拼 ────────────────────────────────
REPO_DIR="$R"
c_g(){ echo "$@"; }
c_y(){ echo "$@"; }
DW_MOS=/etc/mosdns/config.yaml
_fn="$(python3 - "$R" <<'PY'
import sys
s = open(sys.argv[1] + "/deploy/bot/pdg.sh").read()
a = s.index("# ── 6.2B: DoT 证据端(observer)的生命周期状态机")
b = s.index("migrate_probe81_public(){")
sys.stdout.write(s[a:b])
PY
)" || die "抽取状态机失败"
eval "$_fn"
[[ "$(type -t migrate_dotwitness)" == function ]] || die "载入 migrate_dotwitness 失败"
migrate_dotwitness || die "生产状态机部署 witness 失败"

[[ -f /etc/systemd/system/pdg-dotwitness.service ]] || die "unit 没装上"
[[ -f /etc/privdns-gateway/dotwitness.env ]] || die "env 没装上"
[[ "$(sed -n 's/^PDG_DOTWITNESS_SUFFIX=//p' /etc/privdns-gateway/dotwitness.env)" == "probe.$DOM" ]] \
  || die "env 后缀不是 probe.$DOM"
[[ "$(systemctl is-enabled pdg-dotwitness)" == enabled ]] || die "witness 未 enabled"
[[ "$(systemctl is-active pdg-dotwitness)" == active ]] || die "witness 未 active"
[[ "$(ss -lun | grep -c '127\.0\.0\.1:5399')" == 1 ]] || die "5399 未在回环监听"
[[ "$(ss -lun | grep ':5399' | grep -vc '127\.0\.0\.1:5399')" == 0 ]] || die "5399 绑了非回环地址"
[[ "$(grep -c 'pdg-dotwitness managed block' /etc/mosdns/config.yaml)" == 4 ]] || die "受管块标记数不是 4"
[[ "$(grep -c 'tag: dotwitness_fwd' /etc/mosdns/config.yaml)" == 1 ]] || die "dotwitness_fwd 不是一份"
say "deployed 形态就绪(四件套齐, 5399 仅回环, 受管块各一份)"
rm -rf "$WORK"

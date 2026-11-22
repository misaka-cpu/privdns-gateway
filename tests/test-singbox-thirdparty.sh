#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 第三方 sing-box 必须毫发无损(P0)。
#
# 之前的归属判据只看一条 ExecStart:
#     ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
# 这是**手工安装最常见的写法** —— 拿它当"本项目所有"的证明, 等于把别人按常规装的 sing-box
# 认成自家的, 然后在迁移/卸载时删掉它的 unit、二进制, 甚至整个 /etc/sing-box。不可逆。
#
# 现在要求: 只有 ① 可信归属标记, 或 ② **完整匹配**历史 PDG unit 形态 **且** 现场另有本项目
# 特征(config.json 确实是我们的数据模型 + 存在 backend 标记), 才算自家的。证明不了 → 全保留。
#
# 本用例造的第三方现场刻意"长得最像": ExecStart 与 PDG 历史形态**逐字一致**, 但 config.json
# 是他自己的(带唯一 sentinel)。断言: 迁移 / 卸载 / --purge 之后, unit、二进制、配置目录与
# sentinel 全部逐字节未变; 而确属旧版 PDG 的 sing-box 仍能被正常清理。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

SENTINEL='THIRD-PARTY-SENTINEL-9f2c1a'

# 历史 PDG unit 形态(v1.4.2 起逐字未变) —— 第三方也可能恰好这么写, 故不能只凭它认亲
PDG_UNIT='[Unit]
Description=sing-box
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target'

mk(){   # $1 = thirdparty | pdg
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/systemd/system" "$SB/etc/privdns-gateway" "$SB/usr/local/bin" \
           "$SB/etc/sing-box" "$SB/etc/mosdns" "$SB/etc/mihomo" "$SB/opt/pdg-bot" \
           "$SB/etc/systemd/journald.conf.d" "$SB/opt/privdns-gateway" "$SB/var/lib/privdns-gateway"
  printf '%s\n' "$PDG_UNIT" > "$SB/etc/systemd/system/sing-box.service"   # 两种现场都用同一形态
  printf 'BINARY-CONTENT\n' > "$SB/usr/local/bin/sing-box"; chmod 755 "$SB/usr/local/bin/sing-box"
  if [[ "$1" == thirdparty ]]; then
    # 他自己的配置(带唯一 sentinel), 不是本项目的数据模型
    cat > "$SB/etc/sing-box/config.json" <<J
{ "log": {"level": "info"}, "note": "$SENTINEL",
  "inbounds": [{"type": "mixed", "tag": "my-own-in", "listen_port": 1080}],
  "outbounds": [{"type": "direct", "tag": "direct"}] }
J
    printf 'my own notes %s\n' "$SENTINEL" > "$SB/etc/sing-box/mynotes.txt"
  else
    # 本项目的数据模型(特征入站齐全)+ 可信归属标记
    cat > "$SB/etc/sing-box/config.json" <<'J'
{ "inbounds": [{"type":"direct","tag":"in-https","listen_port":443},
               {"type":"direct","tag":"in-http","listen_port":80},
               {"type":"mixed","tag":"tg-proxy","listen_port":8445}],
  "outbounds": [{"type":"direct","tag":"jp"}],
  "route": {"rules": [], "final": "jp"} }
J
    printf 'PDG-SINGBOX-OWNED v1\ncreated=2026-01-01T00:00:00Z\n' > "$SB/etc/privdns-gateway/singbox.pdg-owned"
  fi
  printf 'singbox\n' > "$SB/etc/privdns-gateway/backend"
  printf 'x\n' > "$SB/usr/local/bin/mihomo"
  printf 'log: {}\n' > "$SB/etc/mosdns/config.yaml"
  export SB
}

snap(){   # 第三方那几样东西的指纹
  {
    sha256sum "$SB/etc/systemd/system/sing-box.service" 2>/dev/null
    sha256sum "$SB/usr/local/bin/sing-box" 2>/dev/null
    find "$SB/etc/sing-box" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
  } | sha256sum | cut -d' ' -f1
}

# ── 归属判据本身 ────────────────────────────────────────────────────────────
. "$ROOT/lib/singbox.sh"
mk thirdparty
PDG_ROOT_PREFIX="$SB" pdg_singbox_is_ours \
  && bad "第三方(ExecStart 与 PDG 历史形态逐字一致)被误判为本项目所有" \
  || ok "判据: 仅凭标准 ExecStart 不认亲(第三方判为非本项目)"
mk pdg
PDG_ROOT_PREFIX="$SB" pdg_singbox_is_ours \
  && ok "判据: 有可信归属标记 → 认定本项目所有" || bad "自家(带标记)被判成第三方"
# 标记内容不可信(空文件/乱写)不算数
mk pdg; printf 'garbage\n' > "$SB/etc/privdns-gateway/singbox.pdg-owned"
PDG_ROOT_PREFIX="$SB" pdg_singbox_is_ours \
  && ok "无标记但配置是本项目数据模型+形态完整匹配 → 仍认定自家" \
  || bad "自家(数据模型齐全)被判成第三方"
# 形态完整匹配, 但 config.json 是别人的 → 不认亲
mk thirdparty; rm -f "$SB/etc/privdns-gateway/singbox.pdg-owned"
PDG_ROOT_PREFIX="$SB" pdg_singbox_is_ours \
  && bad "形态匹配但配置是第三方的, 仍被认成自家" || ok "判据: 形态匹配但配置非本项目 → 不认亲"

# ── uninstall / --purge ─────────────────────────────────────────────────────
run_uninstall(){
  # 生产里 uninstall.sh 与 lib/ 同在仓库根 —— 沙箱里也要照此摆放, 否则它找不到归属判据
  mkdir -p "$WORK/lib"; cp "$ROOT/lib/singbox.sh" "$WORK/lib/"
  sed -e "s#/etc/#$SB/etc/#g" -e "s#/usr/local/bin/#$SB/usr/local/bin/#g" \
      -e "s#/opt/pdg-bot#$SB/opt/pdg-bot#g" -e "s#/opt/privdns-gateway#$SB/opt/privdns-gateway#g" \
      -e "s#/var/lib/privdns-gateway#$SB/var/lib/privdns-gateway#g" \
      -e "s#/run/systemd/#$SB/run/systemd/#g" "$ROOT/uninstall.sh" > "$WORK/u.sh"
  sed -i -e "s#$SB/usr/local/bin/sing-box run -c $SB/etc/sing-box/config#/usr/local/bin/sing-box run -c /etc/sing-box/config#" "$WORK/u.sh"
  sed -i -e 's#^\[\[ \$EUID -eq 0 \]\].*#true#' "$WORK/u.sh"
  env SB="$SB" PDG_ROOT_PREFIX="$SB" bash -c "systemctl(){ :; }; nft(){ :; }; bash '$WORK/u.sh' ${1:-}" 2>&1
}

mk thirdparty; before="$(snap)"
run_uninstall >/dev/null
[[ "$(snap)" == "$before" ]] && ok "普通卸载: 第三方 unit/二进制/配置目录逐字节未变" || bad "普通卸载动了第三方文件"
grep -qF "$SENTINEL" "$SB/etc/sing-box/config.json" 2>/dev/null \
  && ok "普通卸载: 第三方 config.json 的 sentinel 仍在" || bad "第三方配置被改/被删"

mk thirdparty; before="$(snap)"
run_uninstall --purge >/dev/null
[[ "$(snap)" == "$before" ]] && ok "--purge: 第三方 unit/二进制/配置目录逐字节未变" || bad "--purge 动了第三方文件"
[[ -f "$SB/etc/sing-box/mynotes.txt" ]] \
  && ok "--purge: 第三方配置目录整体保留(未 rm -rf /etc/sing-box)" || bad "--purge 删了第三方配置目录"
grep -qF "$SENTINEL" "$SB/etc/sing-box/config.json" 2>/dev/null \
  && ok "--purge: sentinel 仍在" || bad "--purge 删/改了第三方配置"
[[ ! -e "$SB/usr/local/bin/mihomo" ]] \
  && ok "--purge: 项目自己的东西照删(保护没把卸载变成空操作)" || bad "mihomo 没删"

# 确属旧版 PDG 的 sing-box 仍要能清掉
mk pdg
run_uninstall --purge >/dev/null
{ [[ ! -e "$SB/etc/systemd/system/sing-box.service" ]] && [[ ! -e "$SB/usr/local/bin/sing-box" ]]; } \
  && ok "--purge: 确属旧版 PDG 的 sing-box 仍被正常清理" || bad "自家 sing-box 没清掉"

# ── 迁移路径 ────────────────────────────────────────────────────────────────
# 判据整份 source 进来(生产里 pdg 也是 source lib/singbox.sh, 不是抽单个函数),
# 再抽出被测的清理函数 —— 它认 PDG_ROOT_PREFIX, 沙箱路径无需改写。
{ echo ". '$ROOT/lib/singbox.sh'"
  echo '_pdg_singbox_is_ours(){ pdg_singbox_is_ours "$@"; }'
  sed -n '/^_pdg_drop_singbox_files(){/,/^}/p' "$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")"
} > "$WORK/fn.sh"
grep -q '^_pdg_drop_singbox_files(){' "$WORK/fn.sh" || { echo "抽取 _pdg_drop_singbox_files 失败"; exit 1; }
mk thirdparty; before="$(snap)"
env SB="$SB" PDG_ROOT_PREFIX="$SB" bash -c "
c_g(){ echo \"\$*\"; }; c_y(){ echo \"\$*\"; }
systemctl(){ :; }
source '$WORK/fn.sh'
_pdg_drop_singbox_files 迁移" >/dev/null 2>&1
[[ "$(snap)" == "$before" ]] \
  && ok "迁移清理: 第三方 sing-box 逐字节未变" || bad "迁移清理动了第三方文件"

# ── 保守判据的另一面: 保留了什么、为什么、怎么手动清 ────────────────────────
# 判据宁可误判成"不是自家的"(删别人的东西不可逆)。代价是: 用户手工改过本项目的 unit 之后,
# 卸载会留下一堆文件却不说留了什么 —— 机器上从此挂着一个没人管的 sing-box。
# 故: 保留时必须逐条列出**确实存在**的路径, 说清判不出归属的原因, 并给出可直接执行的清理命令。
mk thirdparty
out="$(run_uninstall)"
grep -q "$SB/etc/systemd/system/sing-box.service" <<<"$out" \
  && ok "保留提示: 点名了 unit 路径" || bad "没列出保留的 unit: $out"
grep -q "$SB/usr/local/bin/sing-box" <<<"$out" \
  && ok "保留提示: 点名了二进制路径" || bad "没列出保留的二进制"
grep -qE 'rm -r?f .*sing-box' <<<"$out" \
  && ok "保留提示: 给了可直接执行的清理命令" || bad "没给清理命令: $out"
grep -qE 'config.json|数据模型' <<<"$out" \
  && ok "保留提示: 说清了判不出归属的原因" || bad "没说原因: $out"

# --purge 下 /etc/sing-box 整个保留 → 也要点名(否则用户根本不知道这个目录还在)
mk thirdparty
out="$(run_uninstall --purge)"
grep -q "$SB/etc/sing-box" <<<"$out" \
  && ok "--purge 保留提示: 点名了 /etc/sing-box 目录" || bad "没点名保留的配置目录"

# 不存在的东西不要瞎报(别让用户去 rm 一个根本没有的文件)
mk thirdparty; rm -f "$SB/usr/local/bin/sing-box"
out="$(run_uninstall)"
grep -q "$SB/usr/local/bin/sing-box" <<<"$out" \
  && bad "二进制已不存在却仍在保留清单里" || ok "保留清单只列**确实存在**的路径"

# 原因要随判据分支变化, 不能是一句放之四海的套话
mk pdg; rm -f "$SB/etc/privdns-gateway/singbox.pdg-owned" "$SB/etc/privdns-gateway/backend"
out="$(run_uninstall)"
grep -q 'backend' <<<"$out" \
  && ok "原因随分支变化: 缺 backend 标记时如实说明" || bad "原因是套话, 没指出缺 backend: $out"

# 迁移路径同样要点名 + 给命令
mk thirdparty
out="$(env SB="$SB" PDG_ROOT_PREFIX="$SB" bash -c "
c_g(){ echo \"\$*\"; }; c_y(){ echo \"\$*\"; }
systemctl(){ :; }
source '$WORK/fn.sh'
_pdg_drop_singbox_files 迁移" 2>&1)"
{ grep -q 'sing-box.service' <<<"$out" && grep -q 'rm -f' <<<"$out"; } \
  && ok "迁移清理: 保留时点名路径并给出清理命令" || bad "迁移提示不完整: $out"
grep -qE 'config.json|数据模型|backend|形态' <<<"$out" \
  && ok "迁移清理: 说清了判不出归属的原因" || bad "迁移提示没说原因: $out"

# ── /etc/sing-box 是**数据模型**目录: 与运行时归属分开判 ────────────────────
# v1.6 起本项目不装 sing-box 运行时 → 运行时归属恒为否。拿它决定 --purge 删不删
# /etc/sing-box, 结果就是纯 mihomo 的新装机器 purge 完, config.json 里的出口密码、UUID、
# 节点地址原样躺在盘上。模型归属另有标记与保守判据。
mk_mihomo_only(){   # 新装现场: 没有 sing-box 运行时, 但有本项目的数据模型 + 模型归属标记
  SB="$WORK/root"; rm -rf "$SB"
  mkdir -p "$SB/etc/systemd/system" "$SB/etc/privdns-gateway" "$SB/usr/local/bin" \
           "$SB/etc/sing-box" "$SB/etc/mosdns" "$SB/etc/mihomo" "$SB/opt/pdg-bot" \
           "$SB/etc/systemd/journald.conf.d" "$SB/opt/privdns-gateway" "$SB/var/lib/privdns-gateway"
  cat > "$SB/etc/sing-box/config.json" <<'J'
{ "inbounds": [{"type":"direct","tag":"in-https","listen_port":443},
               {"type":"direct","tag":"in-http","listen_port":80},
               {"type":"mixed","tag":"tg-proxy","listen_port":8445}],
  "outbounds": [{"type":"shadowsocks","tag":"hk","server":"1.2.3.4","server_port":8388,
                 "method":"aes-256-gcm","password":"SECRET-PASSWORD-9f2c"}],
  "route": {"rules": [], "final": "hk"} }
J
  printf 'mihomo\n' > "$SB/etc/privdns-gateway/backend"
  printf 'PDG_BOT_TOKEN=x\n' > "$SB/etc/privdns-gateway/bot.env"
  printf 'x\n' > "$SB/opt/pdg-bot/bot.py"
  printf 'x\n' > "$SB/opt/privdns-gateway/install.sh"
  printf 'log: {}\n' > "$SB/etc/mosdns/config.yaml"
  printf 'x\n' > "$SB/usr/local/bin/mihomo"
  export SB
}

mk_mihomo_only
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_mark_owned
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_is_ours \
  && ok "判据: 新装落了模型归属标记 → /etc/sing-box 判为本项目数据模型" || bad "新装的数据模型被判成第三方"
PDG_ROOT_PREFIX="$SB" pdg_singbox_is_ours \
  && bad "没有 sing-box 运行时却被判成运行时归本项目" || ok "判据: 运行时归属与模型归属互不牵连"
run_uninstall --purge >/dev/null
[[ ! -e "$SB/etc/sing-box" ]] \
  && ok "--purge: 本项目的数据模型目录被删除(出口密码/UUID 不留在盘上)" || bad "purge 后 /etc/sing-box 还在"

# 老 PDG 机器: 没有模型标记, 靠多个项目特征保守迁移
mk_mihomo_only; rm -f "$SB/etc/privdns-gateway/sbmodel.pdg-owned"
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_is_ours \
  && ok "判据: 老装无标记但项目特征齐全 → 保守认定为本项目数据模型" || bad "老装模型被判成第三方"
run_uninstall --purge >/dev/null
[[ ! -e "$SB/etc/sing-box" ]] && ok "--purge: 老 PDG 的数据模型同样被删除" || bad "老装模型没删掉"

# 第三方: config.json 不是本项目数据模型 → 一律保留(哪怕现场有本项目痕迹)
mk thirdparty; rm -f "$SB/etc/privdns-gateway/sbmodel.pdg-owned"
before="$(snap)"
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_is_ours \
  && bad "第三方配置目录被判成本项目数据模型" || ok "判据: 第三方 config.json → 模型不归本项目"
run_uninstall --purge >/dev/null
[[ "$(snap)" == "$before" ]] && ok "--purge: 第三方 sing-box 目录仍逐字节保留" || bad "purge 动了第三方目录"
grep -qF "$SENTINEL" "$SB/etc/sing-box/config.json" && ok "--purge: 第三方 sentinel 仍在" || bad "第三方配置被删"

# 混合场景: 数据模型是我们的, 但 sing-box 运行时是别人手工装的 → 模型删、运行时留
mk_mihomo_only
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_mark_owned
cat > "$SB/etc/systemd/system/sing-box.service" <<'U'
[Unit]
Description=sing-box service (third party, hand rolled)
[Service]
ExecStart=/opt/mysingbox/sing-box run -c /opt/mysingbox/my.json
U
printf 'THIRD-PARTY-BINARY\n' > "$SB/usr/local/bin/sing-box"; chmod 755 "$SB/usr/local/bin/sing-box"
out="$(run_uninstall --purge)"
[[ ! -e "$SB/etc/sing-box" ]] && ok "混合场景: 本项目的数据模型被删" || bad "混合场景模型没删"
{ [[ -e "$SB/etc/systemd/system/sing-box.service" ]] && [[ -e "$SB/usr/local/bin/sing-box" ]]; } \
  && ok "混合场景: 第三方运行时(unit + 二进制)原样保留" || bad "混合场景删了第三方运行时"
grep -q 'sing-box.service' <<<"$out" && ok "混合场景: 保留清单点名了第三方 unit" || bad "没点名保留项: $out"

# 无法确认: 有本项目数据模型形态, 但现场特征不足(只有 backend) → 保守保留并说明原因
mk_mihomo_only
rm -f "$SB/etc/privdns-gateway/sbmodel.pdg-owned" "$SB/etc/privdns-gateway/bot.env"
rm -rf "$SB/opt/pdg-bot" "$SB/opt/privdns-gateway" "$SB/etc/mosdns"
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_is_ours \
  && bad "特征不足却认定为本项目数据模型(该保守时不保守)" || ok "判据: 项目特征不足 → 不认定, 保守保留"
out="$(run_uninstall --purge)"
[[ -e "$SB/etc/sing-box/config.json" ]] && ok "--purge: 无法确认时数据模型保留" || bad "无法确认却删了"
grep -q '判不出归属的原因' <<<"$out" && ok "--purge: 说清了为何保留" || bad "没说原因: $out"

# 普通卸载(不带 --purge)照旧保留配置
mk_mihomo_only
PDG_ROOT_PREFIX="$SB" pdg_sbmodel_mark_owned
run_uninstall >/dev/null
[[ -e "$SB/etc/sing-box/config.json" ]] \
  && ok "普通卸载: 配置照旧保留(只有 --purge 才删)" || bad "普通卸载把配置删了"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

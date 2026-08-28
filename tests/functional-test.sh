#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 真功能测试(非静态): 真起 mihomo, 验证本项目的核心链路 ——
#   「单入口 + 按 TLS SNI 把流量分到不同出口」。
#
# 做法(全本地、可在 CI / 干净机跑, 仅需 python3 + 官方 mihomo):
#   1) 起 3 个本地 mock SOCKS5 当"出口", 各自记录收到的目标域名;
#   2) 用 redir 入口(开 sniffer + override-destination, 与生产同款)起 mihomo,
#      按域名规则分到出口 A/B、其余走 MATCH 兜底;
#   3) 按不同 SNI 发 TLS ClientHello 到入口, 断言每个 SNI 被嗅探并路由到正确出口。
#
# 生产上 80/443/5228-5230 由 nft REDIRECT 进这个 redir 端口(见 deploy/firewall/nftables-mihomo.conf);
# 测试里直接连该端口即可 —— sniffer 的 override-destination 会用嗅到的 SNI 顶掉原目的地,
# 正是生产中"手机连过来 → 嗅 SNI → 按域名选出口"那条路。
#
# 退出码 0 = 通过; 非 0 = 失败。**两种情况都打印 mihomo 输出** —— 绿的时候拿不到它,
# 真出事时就只能拿红 run 去猜正常长什么样。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"

WORK="$(mktemp -d)"
PIDS=()
NFT_TABLE=""                    # 非空 = 本次运行**确实建过**临时 conntrack 表, 清理要负责删掉
# 只删本轮自己建的那一张(名字带 PID, 唯一), 不动任何既有表, 更不 flush。
# 幂等: 没建过是 no-op; 删掉并确认不存在后注销登记, 重复调用第二次同样是 no-op。
drop_conntrack_table(){
  [[ -n "$NFT_TABLE" ]] || return 0
  sudo -n nft delete table inet "$NFT_TABLE" 2>/dev/null
  if sudo -n nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
    echo "[FAIL] 临时 conntrack 表 inet $NFT_TABLE 没删掉, 给现场留了残留" >&2
  else
    NFT_TABLE=""
  fi
}
# mihomo 的输出**成功时也要打出来**。以前只有失败路径 cat 它, 而 cleanup 又把整个 $WORK
# 删掉 —— 于是绿的那些 run 里根本拿不到 mihomo 日志。真出事的时候(HANDOFF §9.12 那个坑)
# 只能拿红 run 去猜"绿的时候它是什么样", 而那正是最需要对照的东西。
#
# 幂等: 失败路径已经就地 cat 过一次的, 这里不再重复(_MH_DUMPED)。
# 截断到最后 200 行: 一次跑只有几秒, 正常远不到这个量; 设上限是防"mihomo 疯狂刷日志"
# 那种情形把 CI 日志淹掉。截断了就说清楚, 不假装打全了。
_MH_DUMPED=0
dump_mihomo(){
  [[ "$_MH_DUMPED" == 1 ]] && return 0
  [[ -s "$WORK/mh.out" ]] || return 0
  _MH_DUMPED=1
  local n; n="$(wc -l < "$WORK/mh.out")"
  echo "---- mihomo 输出(共 $n 行$( (( n > 200 )) && echo ", 只显示最后 200 行" ))----" >&2
  tail -200 "$WORK/mh.out" >&2
  echo "---- mihomo 输出结束 ----" >&2
}
cleanup(){
  dump_mihomo
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
  drop_conntrack_table
}
trap cleanup EXIT
fail(){ echo "[FAIL] $*" >&2; exit 1; }
note(){ echo "[*] $*"; }

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;;
  *) fail "不支持的架构: $(uname -m)" ;;
esac

# ── 0. redir 入站的前提: 本 netns 的 conntrack 必须在跟踪 ───────────────────────
# mihomo 的 redir 入站在 accept 之后立刻 getsockopt(SOL_IP, SO_ORIGINAL_DST) 取回原始目的地
# (理由见 deploy/firewall/nftables-mihomo.conf 开头)。那个 sockopt 由 conntrack 提供 ——
# 本 netns 没启用 conntrack hook 时它返回 ENOENT, mihomo 于是**静默丢掉**这条连接。症状是
# 三个出口日志全空、第一个用例卡满轮询后失败, 而 mihomo 自己一个字都不打, 完全看不出真因。
#
# 生产上这个前提恒成立(nft 模板自带 nat prerouting 与 ct state 两类规则), 测试里却一直靠
# 宿主碰巧激活过 conntrack 白捡 —— runner 上捡不到就是一次假红: main 的 32722985743 与
# 32579827324 都是这么来的, 同一份代码在别的 run 上全绿。所以这里先探, 缺了就自己建。
#
# 与启动时那两行 `IP_TRANSPARENT … operation not permitted` 无关: 那是 Redir **UDP** 监听器
# 要 CAP_NET_ADMIN, TCP 那半照常 listen 成功, 而本测试只走 TCP。非 root 跑必然有那两行,
# 它不是失败条件 —— 别去压它, 压了就再也看不见真的权限问题了。
probe_origdst(){ python3 "$HERE/origdst_probe.py" 2>&1; }

ensure_conntrack(){
  local out rc t
  out="$(probe_origdst)"; rc=$?
  case "$rc" in
    0) note "conntrack 前提已满足($out), 不建任何临时规则" ; return 0 ;;
    3) : ;;                       # 未激活 → 往下自己建一张只属于本次运行的表
    *) fail "conntrack 前提探不出结论($out) —— 不猜, 也不跳过" ;;
  esac
  note "本 netns 的 conntrack 未激活($out), 建一张只属于本次运行的临时表"
  # 缺工具时**判失败而不是跳过**: 跳过等于零覆盖, 而零覆盖会以绿灯的样子出现, 正是本项目
  # 最怕的那种假绿 —— 真出问题时它一声不吭。
  sudo -n true 2>/dev/null \
    || fail "本 netns 缺 conntrack 且没有免密 sudo, 建不起前提(不跳过: 跳过等于零覆盖)"
  # 探 nft 用 `sudo -n nft --version`, 不用 `command -v nft`: nft 装在 /usr/sbin, 非 root 的
  # PATH 通常不含那一段 —— 按 command -v 判会把"其实有 nft 的机器"误判成没有, 平白把一次本
  # 可以自愈的运行变成硬失败。要问的是"待会那条命令跑不跑得起来", 那就照原样问一次。
  sudo -n nft --version >/dev/null 2>&1 \
    || fail "本 netns 缺 conntrack 且 sudo 下也调不到 nft, 建不起前提(不跳过: 跳过等于零覆盖)"
  t="pdgfunc$$"
  # 只**新建**一张名字唯一的表, 不 flush、不碰任何既有表。规则本身什么都不做(policy accept
  # 加一条 ct state 匹配), 它唯一的作用是让内核为本 netns 注册 conntrack hook —— 这正是
  # 定性实验里唯一改动的那一条: 改之前 5/5 红, 加上之后 5/5 绿。
  sudo -n nft add table inet "$t" || fail "建临时 conntrack 表失败: inet $t"
  NFT_TABLE="$t"                  # 建成即登记 —— 后面任何一步失败, 清理都能把它删掉
  sudo -n nft add chain inet "$t" input '{ type filter hook input priority 0; policy accept; }' \
    || fail "建临时 conntrack 链失败: inet $t"
  sudo -n nft add rule inet "$t" input ct state established,related accept \
    || fail "加 ct 规则失败: inet $t"
  # 建完必须**再探一次**: 三条 nft 命令全都返回 0, 不等于 conntrack 真的被激活了。
  # 少了这一步, 一个"成功但不生效"的 setup 就会冒充已准备好, 把假绿换成假红而已。
  out="$(probe_origdst)"; rc=$?
  [[ "$rc" == 0 ]] \
    || fail "临时表建好了但 SO_ORIGINAL_DST 仍拿不到($out) —— 前提不成立, 不继续碰运气"
  note "临时 conntrack 表 inet $t 已生效($out)"
}
ensure_conntrack

# ── 1. 取 mihomo ────────────────────────────────────────────────────────────
# PATH 上那个未必可信: 可能是别的测试留下的**桩**(只会回一句版本号), 拿它跑功能测试等于
# 什么都没验证却全绿。故两道关: ① 版本必须**精确**等于钉死版(pdg_mihomo_is_version, 子串
# 判断会让 v1.19.1 匹配上 v1.19.10); ② 真跑一次 `mihomo -t` 校验一份最小配置, 确认它确实
# 具备内核能力。任一不过就按钉死 SHA256 重新下载。
mihomo_usable(){
  command -v mihomo >/dev/null 2>&1 || return 1
  pdg_mihomo_is_version "$MIHOMO_VER" || return 1
  local d rc_good rc_bad
  d="$(mktemp -d)" || return 1
  # 正反两份配置都要判对, 才算真内核:
  #   好配置必须**通过** —— 排除"恒返回非零"的坏桩;
  #   坏配置必须**被拒** —— 排除"恒返回 0"的假桩(测试里的 mihomo 桩正是这种, 只回一句版本号
  #   然后 exit 0; 只看好配置的退出码根本识不破它, 功能测试会在什么都没验的情况下全绿)。
  printf '{"log-level":"silent","mixed-port":17890,"proxies":[],"rules":["MATCH,DIRECT"]}\n' > "$d/good.yaml"
  printf '{"proxies":[{"name":"x","type":"definitely-not-a-real-protocol","server":"1.1.1.1","port":1}],"rules":["MATCH,DIRECT"]}\n' > "$d/bad.yaml"
  mihomo -t -d "$d" -f "$d/good.yaml" >/dev/null 2>&1; rc_good=$?
  mihomo -t -d "$d" -f "$d/bad.yaml"  >/dev/null 2>&1; rc_bad=$?
  rm -rf "$d"
  [[ "$rc_good" == 0 && "$rc_bad" != 0 ]]
}
if mihomo_usable; then
  MH="$(command -v mihomo)"; note "用现有 mihomo: $MH ($(mihomo -v 2>/dev/null | head -1))"
else
  note "下载 mihomo $MIHOMO_VER ($ARCH)…"
  curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${ARCH}-${MIHOMO_VER}.gz" \
       -o "$WORK/m.gz" || fail "mihomo 下载失败"
  pdg_verify_sha256 "$WORK/m.gz" "${PDG_SHA256[mihomo-$ARCH]:-}" "mihomo $MIHOMO_VER ($ARCH)" \
    || fail "mihomo SHA256 校验失败"
  gunzip -c "$WORK/m.gz" > "$WORK/mihomo" || fail "mihomo 解压失败"
  chmod 755 "$WORK/mihomo"; MH="$WORK/mihomo"
fi

# ── 2. 起 3 个 mock SOCKS5 出口 ──
LOGA="$WORK/a.log"; LOGB="$WORK/b.log"; LOGD="$WORK/d.log"
: > "$LOGA"; : > "$LOGB"; : > "$LOGD"
python3 "$HERE/mock_socks.py" 11080 "$LOGA" & PIDS+=($!)
python3 "$HERE/mock_socks.py" 11081 "$LOGB" & PIDS+=($!)
python3 "$HERE/mock_socks.py" 11082 "$LOGD" & PIDS+=($!)

# ── 3. 写 mihomo 测试配置: redir 入口 + sniffer 覆盖目的地, 按域名分流, 其余走 MATCH ──
# (JSON 即合法 YAML —— 与生产渲染出的 /etc/mihomo/config.yaml 同一形态)
cat > "$WORK/cfg.yaml" <<'JSON'
{
  "log-level": "warning",
  "redir-port": 18443,
  "sniffer": {
    "enable": true,
    "override-destination": true,
    "sniff": { "TLS": { "ports": [443, 5228, 18443] } }
  },
  "proxies": [
    { "name": "exitA",       "type": "socks5", "server": "127.0.0.1", "port": 11080 },
    { "name": "exitB",       "type": "socks5", "server": "127.0.0.1", "port": 11081 },
    { "name": "exitDefault", "type": "socks5", "server": "127.0.0.1", "port": 11082 }
  ],
  "rules": [
    "DOMAIN-SUFFIX,alpha.test,exitA",
    "DOMAIN-SUFFIX,beta.test,exitB",
    "DOMAIN-SUFFIX,mtalk.google.com,exitB",
    "MATCH,exitDefault"
  ]
}
JSON

"$MH" -t -d "$WORK" -f "$WORK/cfg.yaml" || fail "mihomo -t 未通过(配置无效)"
"$MH" -d "$WORK" -f "$WORK/cfg.yaml" > "$WORK/mh.out" 2>&1 & PIDS+=($!)

# 等入口端口就绪
ready=0
for _ in $(seq 1 50); do
  if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(.2); sys.exit(0 if s.connect_ex(("127.0.0.1",18443))==0 else 1)'; then ready=1; break; fi
  sleep 0.1
done
[[ "$ready" == 1 ]] || { dump_mihomo; fail "mihomo 入口 :18443 未就绪"; }

# ── 4. 各 SNI 断言落到正确出口(只比对 host, 端口随入口口子) ──
check_case(){  # $1=SNI $2=期望日志文件 $3=出口名
  local sni="$1" log="$2" name="$3"
  python3 "$HERE/sni_client.py" 127.0.0.1 18443 "$sni"
  for _ in $(seq 1 30); do grep -q "^${sni}:" "$log" 2>/dev/null && { note "  $sni → $name ✓"; return 0; }; sleep 0.1; done
  dump_mihomo
  fail "SNI=$sni 未按预期到达 $name (A='$(tr '\n' ' ' <"$LOGA")' B='$(tr '\n' ' ' <"$LOGB")' D='$(tr '\n' ' ' <"$LOGD")')"
}

note "用例: 按 SNI 分流"
check_case alpha.test "$LOGA" "exitA(域名规则)"
check_case beta.test  "$LOGB" "exitB(域名规则)"
check_case gamma.test "$LOGD" "exitDefault(MATCH 兜底)"

note "用例: GMS 推送(mtalk 经嗅探按域名分流; 生产中 5228-5230 由 nft REDIRECT 进同一入口)"
check_case mtalk.google.com "$LOGB" "exitB(GMS 域名规则)"

# 反向断言: 命中规则的 SNI 不应串到别的出口
grep -q alpha.test "$LOGB" "$LOGD" 2>/dev/null && fail "alpha.test 串到了错误出口"
grep -q beta.test  "$LOGA" "$LOGD" 2>/dev/null && fail "beta.test 串到了错误出口"
grep -q mtalk.google.com "$LOGA" "$LOGD" 2>/dev/null && fail "mtalk.google.com 串到了错误出口"

echo
echo "✅ 功能测试通过: TLS SNI 嗅探 + 按域名多出口分流 + MATCH 兜底 + GMS 域名分流 均正确。"

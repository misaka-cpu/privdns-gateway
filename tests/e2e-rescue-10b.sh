#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 10b 硬门: 用**真 systemd** 与**真 nftables** 验救援平面, 逐条对应
# docs/rescue-plane-acceptance.md 第二节。
#
# 为什么必须单独一套骨架, 不能复用 tests/e2e-lib.sh: 那套用 user+mount namespace 把 /etc
# 覆盖掉, 里面**没有 PID 1 的 systemd** —— 而这里要验的恰恰是 systemd 自己的行为(socket
# activation、按需拉起、硬化)。拿桩验过的东西再用桩验一遍, 等于什么都没验。
#
# 隔离靠三件事, 宿主一个字节不动:
#   · 网络: 独立 netns(veth 两端 = 网关侧 / 客户端侧), 真 nft 规则只落在这个 netns 里,
#     宿主的 /etc/nftables.conf 与内核表全程不碰;
#   · 单元: 装到 /run/systemd/system(易失, 重启即无), 收尾 trap 删掉并 daemon-reload;
#   · 路径: 凭据/状态/模块全在临时沙盒里, 由 unit 的 Environment= 指过去 —— 生产 unit 正文
#     逐字节不改, 沙盒差异一律走 drop-in, 于是"验的是不是真那份 unit"这件事可核对。
#
# 机器上已经装了生产救援平面 → **拒绝运行**(不去动别人正在用的门)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0; SKIPPED=0
ok(){ echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
skip(){ echo "[SKIP] $1"; SKIPPED=$((SKIPPED+1)); }
die_skip(){ skip "$1"; echo "────────────────────────────────────────"
            echo "通过 0, 失败 0, 跳过 $SKIPPED(环境不满足 —— 未验收, 不是通过)"; exit 0; }

# shellcheck source=lib/rescue.sh
source "$ROOT/lib/rescue.sh"
RP="$PDG_RESCUE_PORT"
NS="pdgrescue10b"          # 网关侧(救援服务所在)
NSC="pdgrescue10bc"        # 客户端侧(流量必须真的过 veth 才进 input 钩子)
GW_IP="10.77.0.5"          # 网关侧(救援监听)
CIDR="10.77.0.0/16"        # 内网卡段
CLI_OK="10.77.0.9"         # 允许来源
CLI_BAD="192.168.77.9"     # 不允许来源(同一条链路进来, 只有 nft 会拦它)
NFT="$(command -v nft || echo /usr/sbin/nft)"

# ── 前置条件 ────────────────────────────────────────────────────────────────
[[ "$(id -u)" == 0 ]] || die_skip "需要 root(真 systemd/nft 操作) —— 跑: sudo bash tests/e2e-rescue-10b.sh"
[[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]] || die_skip "PID 1 不是 systemd, 硬门无从验起"
[[ -x "$NFT" ]] || die_skip "机器上没有 nft"
command -v ip >/dev/null || die_skip "机器上没有 iproute2"
if [[ -e /etc/systemd/system/$PDG_RESCUE_SOCKET_UNIT || -e /etc/systemd/system/$PDG_RESCUE_SERVICE_UNIT ]]; then
  [[ "${PDG_10B_FORCE:-}" == 1 ]] || die_skip "这台机器上已装生产救援平面 —— 拒绝在它身上做实验"
fi

# 沙盒放 /run 而不是 /tmp: 生产 unit 有 PrivateTmp=yes —— 服务眼里的 /tmp 是一个私有空目录,
# 把 ReadWritePaths 指到 /tmp/... 必然 226/NAMESPACE, 那是测试自己造的假故障, 与被测对象无关。
WORK="$(mktemp -d /run/pdg10b.XXXXXX)"
BOX="$WORK/box"
UNIT_D=/run/systemd/system
cleanup(){
  systemctl stop "$PDG_RESCUE_SOCKET_UNIT" "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
  systemctl reset-failed "$PDG_RESCUE_SOCKET_UNIT" "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
  # ${x:?} 不是形式主义: 这是 root 下的 rm -rf, 变量若空就成了 rm -rf /。
  rm -rf "${UNIT_D:?}/${PDG_RESCUE_SOCKET_UNIT:?}" "${UNIT_D:?}/${PDG_RESCUE_SERVICE_UNIT:?}" \
         "${UNIT_D:?}/${PDG_RESCUE_SERVICE_UNIT:?}.d" "${UNIT_D:?}/${PDG_RESCUE_SOCKET_UNIT:?}.d"
  systemctl daemon-reload >/dev/null 2>&1
  ip netns pids "$NS" 2>/dev/null | xargs -r kill -9 2>/dev/null
  ip netns pids "$NSC" 2>/dev/null | xargs -r kill -9 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  ip netns del "$NSC" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "══ 10b 硬门(真 systemd $(systemctl --version | head -1 | awk '{print $2}') / 真 nft $("$NFT" --version | awk '{print $2}')) ══"

# ── 现场: netns + veth + 沙盒 ───────────────────────────────────────────────
ip netns del "$NS" 2>/dev/null; ip netns del "$NSC" 2>/dev/null
ip netns add "$NS" || die_skip "建不了 netns"
ip netns exec "$NS" ip link set lo up
# 客户端**必须**在另一个 netns 里。第一版把两端放在同一个 netns, 于是 10.77.0.5 对客户端来说
# 是本机地址 —— 包走 lo 本地投递而不是网卡, 被 `iif "lo" accept` 直接放行, 来源约束那条断言
# 压根没被考验(它当时确实"通过"了, 通过的却是另一件事)。两个 netns 用 veth 连起来, 流量才
# 真的进 input 钩子。
ip netns add "$NSC" || die_skip "建不了客户端 netns"
ip netns exec "$NSC" ip link set lo up
ip netns exec "$NS" ip link add gw0 type veth peer name cli0
ip netns exec "$NS" ip link set cli0 netns "$NSC"
ip netns exec "$NS" ip addr add "$GW_IP/16" dev gw0
ip netns exec "$NS" ip link set gw0 up
ip netns exec "$NSC" ip addr add "$CLI_OK/16" dev cli0
ip netns exec "$NSC" ip addr add "$CLI_BAD/24" dev cli0
ip netns exec "$NSC" ip link set cli0 up
# 回程路由: 网关侧要知道怎么回 192.168.77.0/24, 否则"连不上"可能只是没路由 —— 那样断言就
# 不是在验防火墙了。第 6 节还有一条对照用例专门把这件事钉死。
ip netns exec "$NS" ip route add 192.168.77.0/24 dev gw0
ip netns exec "$NSC" ip route add "$GW_IP/32" dev cli0 2>/dev/null
mkdir -p "$BOX/etc/privdns-gateway/rescue" "$BOX/var/lib/privdns-gateway" "$BOX/opt/pdg-bot" "$BOX/run"
{ printf 'PDG_INTERNAL_CIDR=%s\n' "$CIDR"
  printf 'PDG_RESCUE_BIND=%s\n' "$GW_IP"; } > "$BOX/etc/privdns-gateway/profile.env"

# 运行模块: 走**生产安装函数**, 不在测试里另抄一份清单
# shellcheck source=lib/modules.sh
source "$ROOT/lib/modules.sh"
pdg_install_runtime_modules "$ROOT" "$BOX/opt/pdg-bot" >/dev/null || die_skip "装运行模块失败"
# 凭据必须落**沙盒**。不带这几个环境变量的话 rescue_cred 会老老实实写进真实的
# /etc/privdns-gateway/rescue —— 第一版就是这么把测试凭据落到宿主上的。下面还有一条自守卫
# 复查这件事: 测试自己污染宿主, 比被测代码出错更难发现。
export PDG_RESCUE_DIR="$BOX/etc/privdns-gateway/rescue"
export PDG_RESCUE_CERT="$PDG_RESCUE_DIR/cert.pem"
export PDG_RESCUE_KEY="$PDG_RESCUE_DIR/key.pem"
export PDG_RESCUE_TOKEN="$PDG_RESCUE_DIR/token"
export PDG_PROFILE_ENV="$BOX/etc/privdns-gateway/profile.env"
export PDG_RESCUE_STATE="$BOX/var/lib/privdns-gateway/rescue-state.json"
host_etc_before="$([[ -e /etc/privdns-gateway ]] && echo yes || echo no)"
python3 "$BOX/opt/pdg-bot/rescue_cred.py" ensure "$GW_IP" >/dev/null 2>&1 \
  || die_skip "生成救援凭据失败(缺 openssl?)"
[[ -s "$PDG_RESCUE_CERT" && -s "$PDG_RESCUE_KEY" && -s "$PDG_RESCUE_TOKEN" ]] \
  || die_skip "凭据没落到沙盒: $PDG_RESCUE_DIR"

# ── unit: 生产模板逐字节渲染 + 沙盒差异走 drop-in ───────────────────────────
render_unit(){   # $1=模板 $2=目标
  sed -e "s|__RESCUE_BIND__|$GW_IP|g" -e "s|__RESCUE_PORT__|$RP|g" "$1" > "$2"
}
render_unit "$ROOT/deploy/rescue/pdg-rescue.socket"  "$UNIT_D/$PDG_RESCUE_SOCKET_UNIT"
render_unit "$ROOT/deploy/rescue/pdg-rescue.service" "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT"
mkdir -p "$UNIT_D/$PDG_RESCUE_SOCKET_UNIT.d" "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT.d"
cat > "$UNIT_D/$PDG_RESCUE_SOCKET_UNIT.d/10-test.conf" <<EOF
[Socket]
NetworkNamespacePath=/run/netns/$NS
EOF
cat > "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT.d/10-test.conf" <<EOF
[Service]
NetworkNamespacePath=/run/netns/$NS
ExecStart=
ExecStart=/usr/bin/python3 $BOX/opt/pdg-bot/rescue.py
ReadWritePaths=$BOX
Environment=PDG_RESCUE_DIR=$BOX/etc/privdns-gateway/rescue
Environment=PDG_RESCUE_STATE=$BOX/var/lib/privdns-gateway/rescue-state.json
Environment=PDG_PROFILE_ENV=$BOX/etc/privdns-gateway/profile.env
Environment=PDG_RESCUE_BIND=$GW_IP
Environment=FSROOT=$BOX
Environment=PYTHONPYCACHEPREFIX=$BOX/run/pycache
EOF
systemctl daemon-reload

# 生产正文没被改过 —— 沙盒差异只允许出现在 drop-in 里
if diff <(sed -e "s|__RESCUE_BIND__|$GW_IP|g" -e "s|__RESCUE_PORT__|$RP|g" \
              "$ROOT/deploy/rescue/pdg-rescue.service") \
        "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT" >/dev/null; then
  ok "service 正文与生产渲染逐字节一致(沙盒差异全在 drop-in, 验的确实是那份 unit)"
else
  bad "service 正文被改过了 —— 那就不是在验生产 unit"
fi
for prop in ProtectSystem ProtectHome NoNewPrivileges MemoryDenyWriteExecute RestrictNamespaces; do
  grep -q "^$prop=" "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT" || { bad "生产 unit 缺 $prop"; break; }
done
grep -q "^MemoryMax=64M" "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT" && ok "硬化项与 MemoryMax 来自生产 unit(未被测试放宽)"

# ── 客户端: 在 netns 里发一个真 HTTPS 请求 ─────────────────────────────────
cat > "$WORK/probe.py" <<'PY'
import socket, ssl, sys
host, port, src = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else "")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
s = socket.socket()
s.settimeout(float(sys.argv[4]) if len(sys.argv) > 4 else 6.0)
if src:
    s.bind((src, 0))
try:
    s.connect((host, port))
    c = ctx.wrap_socket(s, server_hostname=host)
    c.sendall(b"GET / HTTP/1.0\r\nHost: pdg\r\n\r\n")
    data = b""
    while True:
        b_ = c.recv(4096)
        if not b_:
            break
        data += b_
    sys.stdout.write(data.decode("utf-8", "replace")[:400])
    sys.exit(0)
except Exception as e:            # noqa: BLE001  连不上/被拦都要成为可读结论
    print("PROBE-ERR %s: %s" % (type(e).__name__, e))
    sys.exit(7)
PY
probe(){ ip netns exec "$NSC" python3 "$WORK/probe.py" "$GW_IP" "$RP" "${1:-}" "${2:-6}" 2>&1; }
# MainPID 在 service 未运行时是 "0" —— 直接拿它去 kill 等于 `kill -9 0`, 那会杀掉**整个
# 进程组**, 连测试脚本自己一起带走(第一次跑就是这么被 SIGKILL 的)。所以这里只认 >1 的真 PID。
svc_pid(){
  local p; p="$(systemctl show -p MainPID --value "$PDG_RESCUE_SERVICE_UNIT" 2>/dev/null)"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) && printf '%s' "$p"
}
kill_svc(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )) || { bad "拿不到 service 的真实 PID(得到 %s) —— 崩溃场景无从造起"; return 1; }
  kill -9 "$p"
}

echo
echo "── 1. 真 socket activation ──"
systemctl start "$PDG_RESCUE_SOCKET_UNIT" 2>&1 | sed 's/^/    /'
sleep 0.5
s_sock="$(systemctl is-active "$PDG_RESCUE_SOCKET_UNIT" 2>&1)"
s_svc="$(systemctl is-active "$PDG_RESCUE_SERVICE_UNIT" 2>&1)"
if [[ "$s_sock" == active ]]; then ok "socket 起来了(真 systemd 持有监听口)"
else bad "socket 未 active: $s_sock"; fi
if [[ "$s_svc" == inactive ]]; then
  ok "**还没有人连**的时候 service 就是 inactive —— 这是健康态, 不是挂了"
else bad "service 状态应为 inactive, 实为 $s_svc"; fi
if [[ "$(ip netns exec "$NS" ss -ltn 2>/dev/null)" == *"$GW_IP:$RP"* ]]; then
  ok "netns 里真的有 $GW_IP:$RP 在监听(ss 看得见)"
else bad "监听口不在: $(ip netns exec "$NS" ss -ltn 2>/dev/null | tail -3)"; fi

out="$(probe "$CLI_OK")"
if grep -q "^HTTP/" <<<"$out"; then
  ok "从内网来源发起真 HTTPS 请求 → 拿到 HTTP 响应($(head -1 <<<"$out" | tr -d '\r'))"
else bad "请求没成: $(head -2 <<<"$out")"; fi
sleep 0.3
if [[ "$(systemctl is-active "$PDG_RESCUE_SERVICE_UNIT")" == active ]]; then
  ok "连接把 service 拉起来了(按需拉起, 不是常驻)"
else bad "service 没被拉起"; fi
pid1="$(svc_pid)"

out2="$(probe "$CLI_OK")"
pid2="$(svc_pid)"
if grep -q "^HTTP/" <<<"$out2" && [[ -n "$pid1" && "$pid1" == "$pid2" ]]; then
  ok "Accept=no: 第二次连接由**同一个**实例处理(PID $pid1 未变), 不是每连接一个进程"
else bad "Accept=no 语义不对: pid1=$pid1 pid2=$pid2"; fi
if ! systemctl list-units --all "pdg-rescue@*" 2>/dev/null | grep -q "pdg-rescue@"; then
  ok "没有 pdg-rescue@N 实例单元(那是 Accept=yes 才会有的形态)"
else bad "出现了实例单元 —— Accept 语义被改过?"; fi

echo
echo "── 2. 崩溃后仍能进得来 ──"
kill_svc "$pid1"
sleep 3
if [[ "$(systemctl is-active "$PDG_RESCUE_SOCKET_UNIT")" == active ]]; then
  ok "service 被 KILL 之后 socket 仍在监听(门没跟着塌)"
else bad "socket 也没了: $(systemctl is-active "$PDG_RESCUE_SOCKET_UNIT")"; fi
out3="$(probe "$CLI_OK" 10)"
pid3="$(svc_pid)"
if grep -q "^HTTP/" <<<"$out3"; then
  ok "崩溃后再连一次照样有响应(新实例 PID $pid3)"
else bad "崩溃后连不上了: $(head -2 <<<"$out3")"; fi
if [[ -n "$pid3" && "$pid3" != "$pid1" ]]; then
  ok "确实是**新**进程在服务(不是把 KILL 前的旧 PID 认成活着)"
else bad "PID 没变: $pid1 → $pid3"; fi

echo
echo "── 3. FreeBind ──"
systemctl stop "$PDG_RESCUE_SOCKET_UNIT" "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
ip netns exec "$NS" ip addr del "$GW_IP/16" dev gw0
if systemctl start "$PDG_RESCUE_SOCKET_UNIT" 2>/dev/null \
   && [[ "$(systemctl is-active "$PDG_RESCUE_SOCKET_UNIT")" == active ]]; then
  ok "地址还没起来时也绑得上(FreeBind=true 真的生效)"
else
  bad "地址不在就起不来 —— 网卡晚一步救援平面就没了: $(systemctl status "$PDG_RESCUE_SOCKET_UNIT" 2>&1 | tail -3)"
fi
ip netns exec "$NS" ip addr add "$GW_IP/16" dev gw0
sleep 0.5
out4="$(probe "$CLI_OK" 10)"
if grep -q "^HTTP/" <<<"$out4"; then ok "地址补回来之后无需重启就能服务"
else bad "地址回来后仍连不上: $(head -2 <<<"$out4")"; fi

echo
echo "── 4. 硬化真生效 ──"
# 探针跑在**同一组硬化属性**下: 属性不是手抄的, 是从刚渲染出来的生产 unit 里逐行抓出来
# 再交给 systemd-run —— 于是"unit 里写了"和"内核真的这么限制"这两件事被分开验, 而且
# unit 改了属性, 探针跟着改, 不会出现测试还在验旧策略的情况。
mapfile -t HARD < <(grep -E '^(ProtectSystem|ProtectHome|PrivateTmp|NoNewPrivileges|RestrictSUIDSGID|LockPersonality|MemoryDenyWriteExecute|RestrictRealtime|RestrictNamespaces|RestrictAddressFamilies|SystemCallFilter|SystemCallErrorNumber|MemoryMax|TasksMax|ReadWritePaths)=' "$UNIT_D/$PDG_RESCUE_SERVICE_UNIT")
if (( ${#HARD[@]} >= 10 )); then ok "从生产 unit 抓到 ${#HARD[@]} 条硬化属性交给探针(不是手抄)"
else bad "只抓到 ${#HARD[@]} 条硬化属性"; fi
hprobe(){
  local args=() h
  for h in "${HARD[@]}"; do args+=(-p "$h"); done
  systemd-run --quiet --wait --collect --pipe \
      -p "NetworkNamespacePath=/run/netns/$NS" -p "ReadWritePaths=$BOX" \
      "${args[@]}" "$@" 2>&1
}
if ! hprobe /usr/bin/touch /usr/lib/pdg10b-probe >/dev/null 2>&1; then
  ok "ProtectSystem=strict: 往 /usr 写被拒(真内核拒的, 不是我们自己判的)"
else bad "居然写进了 /usr —— ProtectSystem 没生效"; rm -f /usr/lib/pdg10b-probe; fi
if hprobe /usr/bin/touch "$BOX/var/lib/privdns-gateway/probe" >/dev/null 2>&1 \
   && [[ -e "$BOX/var/lib/privdns-gateway/probe" ]]; then
  ok "ReadWritePaths 里的路径照常可写(硬化没把该写的地方一起封死)"
else bad "声明过的可写路径写不进去"; fi
if hprobe /usr/bin/python3 -c "import socket; socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0)" >/dev/null 2>&1; then
  ok "AF_NETLINK 能开 —— nft 相关操作不会被 RestrictAddressFamilies 拦掉"
else bad "AF_NETLINK 被拦: 恢复防火墙这条路在硬化下走不通"; fi
if ! hprobe /usr/bin/python3 -c "import socket; socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0)" >/dev/null 2>&1; then
  ok "AF_PACKET 被拒(白名单确实在起作用, 不是全放行)"
else bad "AF_PACKET 也能开 —— RestrictAddressFamilies 形同虚设"; fi
if hprobe "$NFT" list tables >/dev/null 2>&1; then
  ok "硬化下 nft 子进程仍跑得起来"
else bad "nft 在硬化下跑不起来 —— 防火墙自救会断在这里"; fi
if hprobe /usr/bin/systemctl is-system-running >/dev/null 2>&1 \
   || [[ "$(hprobe /usr/bin/systemctl is-system-running 2>&1 | tail -1)" == degraded ]]; then
  ok "硬化下 systemctl 子进程仍可用(AF_UNIX 通)"
else bad "systemctl 在硬化下不可用"; fi

# 生效值直接问 systemd, 不看 unit 文件 —— 写错 section 的键会被静默忽略, 只有这里看得出来
eff(){ systemctl show -p "$1" --value "$PDG_RESCUE_SERVICE_UNIT" 2>/dev/null; }
[[ "$(eff MemoryMax)" == 67108864 ]] && ok "MemoryMax 生效值 = 64M" || bad "MemoryMax 实际是 $(eff MemoryMax)"
[[ "$(eff TasksMax)" == 16 ]] && ok "TasksMax 生效值 = 16" || bad "TasksMax 实际是 $(eff TasksMax)"
if [[ "$(eff StartLimitIntervalUSec)" =~ ^(0|infinity)$ ]]; then
  ok "StartLimitIntervalSec=0 **真的生效**(反复起不来也不会被判 failed 而放弃)"
else
  bad "重启限速仍是 $(eff StartLimitIntervalUSec) —— 键写错 section 会被静默忽略, 救援服务连崩几次就再也拉不起来"
fi
[[ "$(eff RestrictAddressFamilies)" == *AF_NETLINK* ]] \
  && ok "生效的地址族白名单含 AF_NETLINK" || bad "生效值里没有 AF_NETLINK: $(eff RestrictAddressFamilies)"

echo
echo "── 5. 真 nftables ──"
NFTNS(){ ip netns exec "$NS" "$NFT" "$@"; }
render_fw(){ sed -e "s|__INTERNAL_CIDR__|$CIDR|g" -e "s|__SSH_PORT__|22|g" -e "s|__RESCUE_PORT__|$RP|g" \
                 "$ROOT/deploy/firewall/nftables-mihomo.conf"; }
render_fw > "$BOX/etc/nftables.conf"
if NFTNS -c -f "$BOX/etc/nftables.conf" 2>/dev/null; then
  ok "真 nft -c 认可生产模板渲染出来的整份配置"
else bad "生产模板过不了真 nft -c: $(NFTNS -c -f "$BOX/etc/nftables.conf" 2>&1 | head -2)"; fi
apply_out="$(NFTNS -f "$BOX/etc/nftables.conf" 2>&1)"; apply_rc=$?
base_hash="$(NFTNS list ruleset | sha256sum | awk '{print $1}')"
# 先取到变量再判, **不要** `nft list ruleset | grep -q`: grep 命中就退出, nft 写管道收到
# SIGPIPE 而非 0 退出, 在 pipefail 下整条管道算失败 —— 于是规则明明应用成功了, 断言却报
# "内核里没有 inet pdg"。这类假红比假绿更浪费时间, 因为它指向的位置是错的。
ruleset="$(NFTNS list ruleset 2>/dev/null)"
if [[ "$apply_rc" == 0 ]] && [[ "$ruleset" == *"table inet pdg"* ]]; then
  ok "整份配置真的应用进内核了"
else
  bad "应用失败(rc=$apply_rc): ${apply_out:-无输出}; 内核现有: $(NFTNS list tables 2>&1 | tr '\n' ' ')"
fi

# 坏候选: -c 必须拒, 且现网一个字节不变
printf 'table inet pdg { chain input { type filter hook input priority 0; tcp dport } }\n' > "$BOX/bad.conf"
if ! NFTNS -c -f "$BOX/bad.conf" 2>/dev/null; then ok "坏候选被真 nft -c 拒掉"
else bad "坏候选居然过了校验"; fi
if [[ "$(NFTNS list ruleset 2>/dev/null | sha256sum | awk '{print $1}')" == "$base_hash" ]]; then
  ok "校验失败后现网 ruleset 逐字节未变(候选先校验再动现网)"
else bad "现网被坏候选动了"; fi

# 注入独立救援表: 真校验 → 真应用 → 幂等
inj(){ python3 "$BOX/opt/pdg-bot/rescue_nft.py" "$CIDR" "$RP" "$GW_IP" < "$1" > "$2"; }
inj "$BOX/etc/nftables.conf" "$BOX/cand1.conf"
if NFTNS -c -f "$BOX/cand1.conf" 2>/dev/null && NFTNS -f "$BOX/cand1.conf" 2>/dev/null; then
  ok "注入救援独立表的候选通过真校验并成功应用"
else bad "注入后的候选应用失败: $(NFTNS -c -f "$BOX/cand1.conf" 2>&1 | head -2)"; fi
n1="$(NFTNS list ruleset 2>/dev/null | grep -c "dport $RP accept")"
inj "$BOX/cand1.conf" "$BOX/cand2.conf"; NFTNS -f "$BOX/cand2.conf" 2>/dev/null
n2="$(NFTNS list ruleset 2>/dev/null | grep -c "dport $RP accept")"
if [[ "$n1" == "$n2" && "$n1" -ge 1 ]]; then
  ok "重复注入不堆规则: 两次应用后内核里仍是 $n1 条"
else bad "内核规则数从 $n1 变成 $n2"; fi
# 内核计数不够: 候选里带着 `delete table` 再重建, 所以就算文本堆了两份, 内核里也只会剩一条。
# 真正会失控的是**文件** —— 每跑一次 enable 就多一段, /etc/nftables.conf 无限增长, 而任何
# 内核层面的断言都看不出来。所以这里数候选文本里的块数。
b1="$(grep -c 'comment "pdg-rescue"' "$BOX/cand1.conf")"
b2="$(grep -c 'comment "pdg-rescue"' "$BOX/cand2.conf")"
if [[ "$b1" == 1 && "$b2" == 1 ]]; then
  ok "候选文本里也只有一条救援规则(反复注入不会让配置文件越堆越长)"
else bad "候选里救援规则堆到了 $b1/$b2 条"; fi
if [[ "$(grep -c 'table inet pdgrescue' "$BOX/cand2.conf")" == 0 ]]; then
  ok "候选里**没有**独立表(旧设计已废弃)"; else bad "候选里又出现独立表"; fi
# 先取变量再判 —— `nft list ... | grep -q` 在 pipefail 下会因 SIGPIPE 判失败(命中即退出),
# 报出"内核里没有规则"这种指错地方的假红。这个坑本文件前面已经踩过一次。
ktbl="$(NFTNS list table inet pdg 2>/dev/null)"
if [[ "$ktbl" == *'comment "pdg-rescue"'* ]]; then
  ok "救援放行落在项目自己的 inet pdg input 链里(内核实测)"
else bad "内核里没有链内救援规则"; fi
kline="$(grep 'comment "pdg-rescue"' <<<"$ktbl" | head -1)"
if [[ "$kline" == *"ip saddr $CIDR"* && "$kline" == *"ip daddr $GW_IP"* && "$kline" == *"dport $RP"* ]]; then
  ok "内核里的规则四要素齐全(来源段 + 目的地址 + 端口 + 标记)"
else bad "内核规则形态不对: $kline"; fi
kpos="$(grep -n 'comment "pdg-rescue"' <<<"$ktbl" | head -1 | cut -d: -f1)"
kdrop="$(grep -n 'policy drop' <<<"$ktbl" | head -1 | cut -d: -f1)"
if [[ -n "$kpos" && -n "$kdrop" && "$kpos" -gt "$kdrop" ]]; then
  ok "规则在 input 链内、位于链首(policy drop 声明之后即链体第一条)"
else bad "规则位置可疑: rule@$kpos drop@$kdrop"; fi
if [[ -z "$(NFTNS list tables 2>/dev/null | grep pdgrescue)" ]]; then
  ok "内核里没有独立表(不再制造 doctor 判为冲突的第二条 input 基链)"
else bad "内核里仍有独立表"; fi

echo
echo "── 6. 双层来源防护(真包真拦)──"
# 现在有两层独立机制: nft 的来源约束, 以及救援服务在 accept 之后、TLS 握手之前的来源校验。
# 顺序仍是**先证前提、再下结论**: 撤掉 default-drop 之后允许来源必须立刻可用, 否则下面
# 关于"谁被拦"的结论就没有意义(第一版正是因为删地址连带清掉回程路由而假绿过一次)。
ip netns exec "$NS" ip route replace 192.168.77.0/24 dev gw0
systemctl restart "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1; sleep 0.5
NFTNS delete table inet pdg 2>/dev/null
out_pre="$(probe "$CLI_OK" 8)"
if grep -q "^HTTP/" <<<"$out_pre"; then
  ok "(前提)没有 default-drop 时允许来源连得通 —— 路由与服务都正常"
else bad "(前提)撤掉防火墙允许来源也连不通($(head -1 <<<"$out_pre" | cut -c1-50))"; fi
# 防火墙**完全不在**的情况下, 非允许来源必须仍被应用层挡住 —— 这正是绑在可路由地址上时
# 唯一的兜底: nft 被清空 / 写错 / 恢复成旧版本, 门也不能就此敞开。
out_app="$(probe "$CLI_BAD" 8)"
if ! grep -q "^HTTP/" <<<"$out_app"; then
  ok "nft 完全不在时, 非允许来源仍被**应用层**拒绝($(head -1 <<<"$out_app" | cut -c1-46))"
else bad "没有 nft 时非允许来源直接进来了 —— 第二层形同虚设"; fi
if ! grep -qiE "救援 Token|状态总览|Traceback" <<<"$out_app"; then
  ok "被拒的来源拿不到登录页 / 状态页 / 堆栈(拒绝发生在读 body 与鉴权之前)"
else bad "泄漏了页面内容: $(head -2 <<<"$out_app")"; fi
NFTNS -f "$BOX/cand1.conf" 2>/dev/null             # 防火墙装回去
out_ok="$(probe "$CLI_OK" 8)"
if grep -q "^HTTP/" <<<"$out_ok"; then ok "两层都在时, 允许来源($CLI_OK)照常可用"
else bad "允许来源连不通: $(head -2 <<<"$out_ok")"; fi
out_bad="$(probe "$CLI_BAD" 5)"
if ! grep -q "^HTTP/" <<<"$out_bad"; then
  ok "两层都在时, 非允许来源($CLI_BAD)进不来($(head -1 <<<"$out_bad" | cut -c1-40))"
else bad "非允许来源进来了"; fi
# 伪造 HTTP 头不能改变判定(判据只用内核给的 peer 地址)
out_xff="$(ip netns exec "$NSC" python3 - "$GW_IP" "$RP" "$CLI_BAD" <<'PY' 2>&1
import socket, ssl, sys
host, port, src = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
s = socket.socket(); s.settimeout(6); s.bind((src, 0))
try:
    s.connect((host, port))
    c = ctx.wrap_socket(s, server_hostname=host)
    c.sendall(b"GET / HTTP/1.0\r\nHost: pdg\r\nX-Forwarded-For: 172.22.0.9\r\n"
              b"Forwarded: for=172.22.0.9\r\n\r\n")
    print(c.recv(200).decode("utf-8", "replace")[:120])
except Exception as e:
    print("PROBE-ERR %s" % type(e).__name__)
PY
)"
if ! grep -q "^HTTP/" <<<"$out_xff"; then
  ok "伪造 X-Forwarded-For / Forwarded 不改变判定(只认内核给的 peer 地址)"
else bad "伪造头骗过了来源校验: $(head -1 <<<"$out_xff")"; fi

echo
echo "── 6b. 恢复旧快照之后, 救援门还在不在 ──"
# 这是救援平面最核心的承诺, 也是 10b 抓到的最重的一条: 独立表的 accept **盖不过**另一张表的
# policy drop —— nftables 里同一 hook 上的多条基链会挨个走, accept 只终止本链。所以恢复一份
# 5.2 之前的旧防火墙(inet pdg 里没有救援放行)之后, 救援口曾经是**不可达**的。
# 现在的做法: 除了独立表, 还往每条 policy drop 的 input 链首补一条带标记的放行。
grep -v "tcp dport $RP accept" "$BOX/etc/nftables.conf" > "$BOX/old-snap.conf"   # 造"旧快照"
if ! grep -q "dport $RP accept" "$BOX/old-snap.conf"; then
  ok "(前提)旧快照里确实没有救援放行, 且 input 仍是 policy drop"
else bad "(前提)旧快照没造干净"; fi
python3 "$BOX/opt/pdg-bot/rescue_nft.py" "$CIDR" "$RP" "$GW_IP" < "$BOX/old-snap.conf" > "$BOX/old-cand.conf"
NFTNS -f "$BOX/old-cand.conf" 2>&1 | sed 's/^/    /'
systemctl restart "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1; sleep 0.5
out_old="$(probe "$CLI_OK" 8)"
if grep -q "^HTTP/" <<<"$out_old"; then
  ok "恢复旧快照后救援口**仍然可达** —— 门没被自己的恢复动作关上"
else bad "恢复旧快照后进不去了($(head -1 <<<"$out_old" | cut -c1-50)) —— 救援平面在最需要时失效"; fi
out_oldbad="$(probe "$CLI_BAD" 5)"
if ! grep -q "^HTTP/" <<<"$out_oldbad"; then
  ok "补进旧链的那条放行**仍带来源约束**(非内网来源照样拦)"
else bad "补规则把门开给了任意来源"; fi
# 幂等 + 可撤销: 反复注入不堆, strip 之后只摘我们标记过的那一行
python3 "$BOX/opt/pdg-bot/rescue_nft.py" "$CIDR" "$RP" "$GW_IP" < "$BOX/old-cand.conf" > "$BOX/old-cand2.conf"
m1="$(grep -c 'comment "pdg-rescue"' "$BOX/old-cand.conf")"
m2="$(grep -c 'comment "pdg-rescue"' "$BOX/old-cand2.conf")"
if [[ "$m1" == 1 && "$m2" == 1 ]]; then ok "注入是幂等的(两次注入仍只有 1 条)"
else bad "规则堆到了 $m1/$m2"; fi
python3 "$BOX/opt/pdg-bot/rescue_nft.py" --strip < "$BOX/old-cand2.conf" > "$BOX/old-strip.conf"
if [[ "$(grep -c 'comment "pdg-rescue"' "$BOX/old-strip.conf")" == 0 ]] \
   && diff "$BOX/old-snap.conf" "$BOX/old-strip.conf" >/dev/null; then
  ok "--strip 之后逐字节回到旧快照原样(补入的行与独立表都摘净, 别人的规则没动)"
else bad "strip 之后与原文不一致: $(diff "$BOX/old-snap.conf" "$BOX/old-strip.conf" | head -3 | tr '\n' ' ')"; fi
NFTNS -f "$BOX/cand1.conf" 2>/dev/null      # 恢复现场

echo
echo "── 7. 真 systemd 上的启停 ──"
systemctl enable "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
[[ "$(systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" 2>&1)" == enabled ]] \
  && ok "enable 后真 systemd 报 enabled" || bad "enable 没生效: $(systemctl is-enabled "$PDG_RESCUE_SOCKET_UNIT" 2>&1)"
systemctl disable --now "$PDG_RESCUE_SOCKET_UNIT" >/dev/null 2>&1
systemctl stop "$PDG_RESCUE_SERVICE_UNIT" >/dev/null 2>&1
sleep 0.5
if [[ "$(ip netns exec "$NS" ss -ltn 2>/dev/null)" != *"$GW_IP:$RP"* ]]; then
  ok "disable --now 之后监听口真的没了(不是只在文件上关掉)"
else bad "还在监听: $(ip netns exec "$NS" ss -ltn | grep "$RP")"; fi
out_off="$(probe "$CLI_OK" 5)"
if ! grep -q "^HTTP/" <<<"$out_off"; then ok "停用后连不进来(入口确实关闭)"
else bad "停用后还能进"; fi

echo
echo "── 宿主未被污染(测试自守卫)──"
if [[ "$host_etc_before" == "$([[ -e /etc/privdns-gateway ]] && echo yes || echo no)" ]]; then
  ok "/etc/privdns-gateway 的存在与否与跑之前一致(凭据没落到宿主)"
else bad "测试把宿主的 /etc/privdns-gateway 改了 —— 隔离没做到"; fi
if [[ ! -e /opt/pdg-bot ]]; then ok "宿主 /opt/pdg-bot 没被创建"; else bad "宿主被装了运行模块"; fi
if [[ "$("$NFT" list tables 2>/dev/null | grep -c "$PDG_RESCUE_TABLE")" == 0 ]]; then
  ok "宿主内核里没有救援表(nft 全部落在 netns 内)"
else bad "宿主内核里出现了 table inet $PDG_RESCUE_TABLE"; fi

echo "────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL, 跳过 $SKIPPED"
[[ "$PASS" -gt 0 ]] || { echo "零断言 —— 判失败"; exit 1; }
[[ "$FAIL" == 0 ]]

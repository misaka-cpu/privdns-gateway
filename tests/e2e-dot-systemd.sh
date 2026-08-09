#!/usr/bin/env bash
# 6.2A §8/§9: 真 systemd 下的 unit 硬化验收 + 配置缺失/损坏的 fail-closed 行为。
#
# 这支会真装 unit、真 start/stop、真占端口, 所以只在一次性隔离环境里跑; 宿主上一律 SKIP。
# 仓库树由调用方用 `git archive` 注入到 /srv/repo(只读快照), 不挂可写正式仓库。
set -uo pipefail
if [[ "${PDG_E2E_ISOLATED:-}" != 1 || "$(id -u)" != 0 ]]; then
  echo "[SKIP] 非一次性隔离环境(需 PDG_E2E_ISOLATED=1 且 root) —— 不在宿主上装 unit"
  echo; echo "通过 0, 失败 0, 跳过 1"; exit 0
fi
R="${PDG_DOTW_REPO:-/srv/repo}"; p=0; f=0; s=0
ok(){ p=$((p+1)); echo "[OK]   $*"; }; bad(){ f=$((f+1)); echo "[FAIL] $*"; }
sk(){ s=$((s+1)); echo "[SKIP] $*"; }; sec(){ echo; echo "── $* ──"; }

sec "0. 环境"
[ "$(ps -p 1 -o comm=)" = systemd ] && ok "PID1 是真 systemd" || { bad "PID1 不是 systemd"; exit 1; }
install -m755 "$R/deploy/bot/dotwitness.py" /opt/pdg-bot/dotwitness.py 2>/dev/null || {
  mkdir -p /opt/pdg-bot; install -m755 "$R/deploy/bot/dotwitness.py" /opt/pdg-bot/dotwitness.py; }
install -m644 "$R/deploy/bot/pdg-dotwitness.service" /etc/systemd/system/pdg-dotwitness.service
mkdir -p /etc/privdns-gateway
printf 'PDG_DOTWITNESS_SUFFIX=probe.dot.sysd.test\n' > /etc/privdns-gateway/dotwitness.env
systemctl daemon-reload
out=$(systemd-analyze verify /etc/systemd/system/pdg-dotwitness.service 2>&1)
[ -z "$out" ] && ok "systemd-analyze verify 无输出" || bad "verify: $out"

sec "1. 启动与实际生效值"
systemctl start pdg-dotwitness.service; sleep 1.5
systemctl is-active pdg-dotwitness >/dev/null && ok "service active" || { bad "起不来: $(journalctl -u pdg-dotwitness -n5 --no-pager)"; }
MP=$(systemctl show pdg-dotwitness -p MainPID --value)
U=$(ps -o user= -p "$MP" 2>/dev/null | tr -d ' ')
[ -n "$U" ] && [ "$U" != root ] && ok "以动态 UID 运行(user=$U, 不是 root)" || bad "以 $U 运行"
g(){ systemctl show pdg-dotwitness -p "$1" --value; }
chk(){ local k="$1" w="$2" v; v="$(g "$k")"; [ "$v" = "$w" ] && ok "$k=$v" || bad "$k=$v(期望 $w)"; }
chk DynamicUser yes
chk NoNewPrivileges yes
chk ProtectSystem strict
chk PrivateTmp yes
chk RuntimeDirectoryMode 0700
chk MemoryMax 67108864
chk TasksMax 16
chk Restart on-failure
chk LimitCORE 0
[ "$(g RestrictAddressFamilies)" = "AF_INET" ] && ok "RestrictAddressFamilies=AF_INET" || bad "RestrictAddressFamilies=$(g RestrictAddressFamilies)"
[ -z "$(g CapabilityBoundingSet)" ] && ok "CapabilityBoundingSet 为空" || bad "CapabilityBoundingSet=$(g CapabilityBoundingSet)"
v=$(g StartLimitIntervalUSec); [ "$v" = "5min" ] && ok "StartLimitIntervalUSec 从 [Unit] 生效(=$v)" || bad "StartLimitIntervalUSec=$v"
[ "$(g StartLimitBurst)" = 5 ] && ok "StartLimitBurst=5" || bad "StartLimitBurst=$(g StartLimitBurst)"
stat -c %a /run/pdg-dotwitness | grep -qx 700 && ok "RuntimeDirectory 实际 mode=700" || bad "mode=$(stat -c %a /run/pdg-dotwitness)"

sec "2. 监听面与写权限"
ss -lunp 2>/dev/null | grep -q '127.0.0.1:5399' && ok "只监听 127.0.0.1:5399" || bad "监听异常: $(ss -lunp | grep 5399)"
ss -lunp 2>/dev/null | grep -E '0\.0\.0\.0:5399|\[::\]:5399' && bad "监听了任意地址" || ok "没有监听任意地址"
q(){ py <<PY
import socket,struct
n="$1".rstrip(".").split(".")
w=b"".join(bytes([len(x)])+x.encode() for x in n)+b"\x00"
c=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);c.settimeout(2)
c.sendto(struct.pack("!HHHHHH",1,0x0100,1,0,0,0)+w+struct.pack("!HH",1,1),("127.0.0.1",5399))
try: print(len(c.recvfrom(4096)[0]))
except Exception: print(0)
PY
}
L=a1b2c3d4e5f6a7b8c9d0e1f2
[ "$(q "$L.probe.dot.sysd.test")" -gt 0 ] && ok "合法 probe 有应答" || bad "无应答"
sleep 0.3
E=/run/pdg-dotwitness/evidence.json
[ -f "$E" ] && ok "evidence 已生成" || bad "没生成 evidence"
[ "$(stat -c %a "$E" 2>/dev/null)" = 600 ] && ok "evidence mode=600" || bad "mode=$(stat -c %a "$E" 2>/dev/null)"
[ "$(stat -c %U "$E" 2>/dev/null)" = "$U" ] && ok "evidence owner 是动态 UID($U)" || bad "owner=$(stat -c %U "$E" 2>/dev/null)"
for d in /etc /opt "$R"; do
  systemd-run -q --uid="$U" --property=ProtectSystem=strict --wait --collect \
    /bin/sh -c "echo x > $d/pdg-dotw-probe 2>/dev/null && echo WROTE || echo DENIED" 2>/dev/null | grep -q WROTE \
    && bad "能写 $d" || ok "写不了 $d"
done

sec "3. 生命周期"
systemctl stop pdg-dotwitness; sleep 1
kill -0 "$MP" 2>/dev/null && bad "stop 后进程还在" || ok "stop 后进程消失"
ss -lunp 2>/dev/null | grep -q ':5399' && bad "stop 后端口还在" || ok "stop 后端口释放"
[ -d /run/pdg-dotwitness ] && bad "stop 后 RuntimeDirectory 还在" || ok "stop 后 RuntimeDirectory 被清"
systemctl start pdg-dotwitness; sleep 1.2
[ -f "$E" ] && bad "restart 后旧 evidence 还在" || ok "restart 后状态按 TTL 契约清空"
[ "$(systemctl show pdg-dotwitness -p NRestarts --value)" = 0 ] && ok "正常 stop 不算故障重启(NRestarts=0)" || bad "NRestarts=$(systemctl show pdg-dotwitness -p NRestarts --value)"

sec "4. 连续崩溃与限速"
systemctl stop pdg-dotwitness 2>/dev/null; systemctl reset-failed pdg-dotwitness 2>/dev/null
mv /opt/pdg-bot/dotwitness.py /opt/pdg-bot/dotwitness.py.bak
printf 'import sys\nsys.exit(3)\n' > /opt/pdg-bot/dotwitness.py
systemctl start pdg-dotwitness 2>/dev/null; sleep 12
st=$(systemctl show pdg-dotwitness -p ActiveState --value)
res=$(systemctl show pdg-dotwitness -p Result --value)
[ "$st" = failed ] && ok "连续崩溃后进入 failed(限速生效, Result=$res)" || bad "ActiveState=$st Result=$res"
mv /opt/pdg-bot/dotwitness.py.bak /opt/pdg-bot/dotwitness.py
systemctl reset-failed pdg-dotwitness
systemctl start pdg-dotwitness; sleep 1.2
systemctl is-active pdg-dotwitness >/dev/null && ok "reset-failed 后可恢复" || bad "恢复失败"

sec "5. 配置缺失与损坏(必须 fail-closed)"
bad_case(){ # $1=名字 $2=准备命令
  systemctl stop pdg-dotwitness 2>/dev/null; systemctl reset-failed pdg-dotwitness 2>/dev/null
  eval "$2"
  systemctl start pdg-dotwitness 2>/dev/null; sleep 1.5
  local act ev
  act=$(systemctl is-active pdg-dotwitness 2>/dev/null)
  ev=$([ -f /run/pdg-dotwitness/evidence.json ] && echo 有 || echo 无)
  q "$L.probe.dot.sysd.test" >/dev/null 2>&1
  sleep 0.3
  local ev2; ev2=$([ -f /run/pdg-dotwitness/evidence.json ] && echo 有 || echo 无)
  printf "       %s: active=%s evidence=%s→%s\n" "$1" "$act" "$ev" "$ev2"
  [ "$ev2" = 无 ] && ok "$1: 不写 evidence" || bad "$1: 写了 evidence"
  journalctl -u pdg-dotwitness -n 20 --no-pager 2>/dev/null | grep -qE "$L|probe\.dot\.sysd" \
    && bad "$1: journal 泄露了 label/qname" || ok "$1: journal 无敏感值"
}
SAVE=/etc/privdns-gateway/dotwitness.env
bad_case "env 不存在"      "rm -f $SAVE"
bad_case "suffix 为空"     "printf 'PDG_DOTWITNESS_SUFFIX=\n' > $SAVE"
bad_case "suffix 含空格"   "printf 'PDG_DOTWITNESS_SUFFIX=a b\n' > $SAVE"
bad_case "suffix 含路径"   "printf 'PDG_DOTWITNESS_SUFFIX=../etc/passwd\n' > $SAVE"
bad_case "suffix 前导点"   "printf 'PDG_DOTWITNESS_SUFFIX=.probe..x\n' > $SAVE"
printf 'PDG_DOTWITNESS_SUFFIX=probe.dot.sysd.test\n' > "$SAVE"
bad_case "Python 文件缺失" "mv /opt/pdg-bot/dotwitness.py /tmp/dw.bak"
mv /tmp/dw.bak /opt/pdg-bot/dotwitness.py
bad_case "Python 语法损坏" "cp /opt/pdg-bot/dotwitness.py /tmp/dw.ok; printf 'def (\n' > /opt/pdg-bot/dotwitness.py"
cp /tmp/dw.ok /opt/pdg-bot/dotwitness.py
systemctl stop pdg-dotwitness 2>/dev/null; systemctl reset-failed pdg-dotwitness 2>/dev/null
python3 -c "
import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',5399))
open('/tmp/hold.pid','w').write('x'); time.sleep(30)" &
HOLD=$!; sleep 0.6
systemctl start pdg-dotwitness 2>/dev/null; sleep 1.5
a=$(systemctl is-active pdg-dotwitness); r=$(systemctl show pdg-dotwitness -p Result --value)
[ "$a" != active ] && ok "端口被占用: fail-closed(active=$a result=$r)" || bad "端口被占用却仍 active"
kill $HOLD 2>/dev/null
systemctl reset-failed pdg-dotwitness 2>/dev/null
systemctl start pdg-dotwitness; sleep 1.2
systemctl is-active pdg-dotwitness >/dev/null && ok "端口释放后可恢复" || bad "恢复失败"

sec "6. 收尾"
systemctl stop pdg-dotwitness 2>/dev/null
systemctl disable pdg-dotwitness 2>/dev/null
rm -f /etc/systemd/system/pdg-dotwitness.service; systemctl daemon-reload
[ -d /run/pdg-dotwitness ] && bad "残留 RuntimeDirectory" || ok "无残留 RuntimeDirectory"
ss -lunp 2>/dev/null | grep -q ':5399' && bad "残留端口" || ok "无残留端口"
echo; echo "通过 $p, 失败 $f, 跳过 $s"
[ "$f" -gt 0 ] && exit 1 || exit 0

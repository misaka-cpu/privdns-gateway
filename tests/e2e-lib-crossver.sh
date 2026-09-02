#!/usr/bin/env bash
# 跨版本换核相关 E2E 的共用夹具: 真 systemd 现场 + 真闭包组装。
# 单独一份, 让 e2e-core-startlimit-recovery.sh 与 e2e-mosdns-crossver-swap.sh 共用同一套
# 现场与同一套闭包 —— 两支各写一遍的话, 它们迟早对"什么算恢复"给出不同答案。
set -uo pipefail

XV_UDP_PORT=15353; XV_DOT_PORT=15853; XV_UNIT=mosdns

xv_require_env(){   # 环境不够就**判失败**, 不 SKIP: 这类测试的全部价值在于它是真的
  [[ "$(id -u)" == 0 ]] || { echo "[FAIL] 需要 root(要写 unit、起服务); 不以「环境不足」为由跳过"; return 1; }
  [[ "$(ps -p 1 -o comm=)" == systemd ]] || { echo "[FAIL] PID 1 不是 systemd"; return 1; }
  local sc; sc="$(command -v systemctl)"
  [[ "$sc" == /usr/bin/systemctl || "$sc" == /bin/systemctl ]] \
    || { echo "[FAIL] systemctl 被影子桩顶掉了($sc) —— 判据必须打在真 systemd 上"; return 1; }
  local c
  for c in ss dig openssl unzip python3 journalctl; do
    command -v "$c" >/dev/null 2>&1 || { echo "[FAIL] 缺 $c"; return 1; }
  done
  [[ ! -e "/etc/systemd/system/$XV_UNIT.service" ]] \
    || { echo "[FAIL] 本机已存在 /etc/systemd/system/$XV_UNIT.service —— 拒绝覆盖别人的 unit"; return 1; }
}

xv_cleanup(){       # 幂等: 任何路径退出都能把现场收干净
  systemctl stop "$XV_UNIT" >/dev/null 2>&1 || true
  systemctl reset-failed "$XV_UNIT" >/dev/null 2>&1 || true
  systemctl disable "$XV_UNIT" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$XV_UNIT.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [[ -n "${XV_WORK:-}" ]] && rm -rf "$XV_WORK"
}

# 现场: 证书 + 配置 + unit。unit 的 Restart/RestartSec **逐字照抄生产**(install.sh 那一份),
# 否则"会不会撞 start-limit"这件事测的就不是生产的行为。
xv_setup_site(){    # $1=旧版二进制
  XV_BINDIR="$XV_WORK/bin"; XV_CFG="$XV_WORK/etc"; mkdir -p "$XV_BINDIR" "$XV_CFG"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$XV_CFG/key.pem" -out "$XV_CFG/cert.pem" \
    -days 1 -subj "/CN=e2e.invalid" >/dev/null 2>&1 || { echo "[FAIL] 生成自签证书失败"; return 1; }
  cat > "$XV_CFG/config.yaml" <<YAML
log:
  level: error
plugins:
  - tag: hosts_x
    type: hosts
    args:
      entries:
        - "e2e.invalid 127.0.0.99"
  - tag: main_sequence
    type: sequence
    args:
      - exec: \$hosts_x
      - matches: has_resp
        exec: accept
      - exec: reject 3
  - tag: udp_server
    type: udp_server
    args: {entry: main_sequence, listen: "127.0.0.1:$XV_UDP_PORT"}
  - tag: tcp_server
    type: tcp_server
    args: {entry: main_sequence, listen: "127.0.0.1:$XV_UDP_PORT"}
  - tag: dot_server
    type: tcp_server
    args: {entry: main_sequence, listen: "127.0.0.1:$XV_DOT_PORT", cert: "$XV_CFG/cert.pem", key: "$XV_CFG/key.pem"}
YAML
  install -m755 "$1" "$XV_BINDIR/mosdns"
  cat > "/etc/systemd/system/$XV_UNIT.service" <<UNITEOF
[Unit]
Description=mosdns
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$XV_BINDIR/mosdns start -d $XV_CFG -c config.yaml
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNITEOF
  # 供调用方做"unit 文件未被改动"的排除断言; shellcheck 看不到跨文件使用
  # shellcheck disable=SC2034
  XV_UNIT_SHA="$(sha256sum "/etc/systemd/system/$XV_UNIT.service" | cut -d' ' -f1)"
  systemctl daemon-reload
}

xv_listeners(){ ss -lntupH 2>/dev/null | awk -v s='"mosdns"' 'index($0,s){print $1":"$5}' | sort -u; }
xv_wait_listeners(){ local n="${1:-3}" i; for ((i=0;i<25;i++)); do [[ "$(xv_listeners | wc -l)" -ge "$n" ]] && return 0; sleep 1; done; return 1; }
xv_dns_ok(){ dig +short +time=2 +tries=1 @127.0.0.1 -p "$XV_UDP_PORT" e2e.invalid A 2>/dev/null | grep -q 127.0.0.99; }
xv_sha(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 从最终 blob 抽出真闭包, 写成文件, 过 bash -n + 完整性门。
# 拼在同一行会把函数糊成 `} 下一个(){`, 整个闭包语法错 —— 而下游"换核失败"的断言会因为
# **错误的理由**变绿。这个坑本项目踩过, 所以这里两道门都要。
xv_build_harness(){  # $1=输出文件 $2..=要抽的函数名
  local out="$1"; shift
  local fns=("$@") f miss=""
  {
    echo 'set -uo pipefail'
    echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }'
    echo 'curl(){ local o=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && { o="$2"; shift; }; shift; done; cp "$FEED" "$o"; }'
    grep -E '^PDG_CORE_(CONNECT_TIMEOUT|MAX_TIME)=' "$XV_ROOT/deploy/bot/pdg.sh"
    for f in "${fns[@]}"; do sed -n "/^$f(){/,/^}/p" "$XV_ROOT/deploy/bot/pdg.sh"; done
    echo 'HARNESS_OK=1'
  } > "$out"
  for f in "${fns[@]}"; do grep -q "^$f(){" "$out" || miss="$miss $f"; done
  [[ -z "$miss" ]] || { echo "[FAIL] 闭包缺函数:$miss"; return 1; }
  bash -n "$out" || { echo "[FAIL] 闭包语法不合法 —— 抽取被引号或拼行撑破"; return 1; }
}

xv_mkzip(){  # $1=输出 zip $2=二进制(成员名固定 mosdns)
  python3 -c 'import sys,zipfile
z,src=sys.argv[1],sys.argv[2]
f=zipfile.ZipFile(z,"w")
zi=zipfile.ZipInfo("mosdns"); zi.external_attr=0o755<<16
f.writestr(zi,open(src,"rb").read()); f.close()' "$1" "$2"
}

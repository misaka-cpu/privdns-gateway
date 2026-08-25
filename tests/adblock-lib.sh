#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 去广告这一组测试的共用 harness。
#
# 三条硬规矩,都是踩出来的:
#
#   ① **渲染用生产模板,不另抄一份配置。**判据要证明的是"现网那份 mosdns 配置"的行为;
#      拿一份手写的近似配置去测,测的是我自己写的东西。sed 表与 install.sh 的
#      `pdg_render`(install.sh:764 一带)同源 —— 那边加占位符这边不跟,渲染出来会留下
#      未替换的 __TOKEN__,而 mosdns 照常加载、只是那条分支永远不匹配(假绿)。
#
#   ② **上游必须记账。**"被阻断的查询不得访问上游"这条,客户端侧看不出来:阻断成功的
#      同时仍向上游发一份,拿到的响应一模一样。唯一的证据是上游收到了什么。
#
#   ③ **停进程按 comm 匹配并跳过自身。**`pkill -f mosdns` 会咬到执行它的那条命令行
#      (HANDOFF §9.13 咬了三次), 表现是 shell 自己被杀、后面的断言静默没跑。
# ─────────────────────────────────────────────────────────────────────────────

ADB_ROOT="${ADB_ROOT:?adblock-lib.sh 需要 ADB_ROOT 指向仓库根}"
ADB_UDP_PORT="${ADB_UDP_PORT:-15300}"
ADB_DOT_PORT="${ADB_DOT_PORT:-15853}"
ADB_UP_PORT="${ADB_UP_PORT:-15353}"

# 钉死版 mosdns。拿不到就**具名硬失败** —— 这一组测的是真 mosdns 的行为, 跳过等于零覆盖。
adb_mosdns(){
  local wd="$1"
  if [[ -x "${PDG_TEST_MOSDNS:-}" ]]; then echo "$PDG_TEST_MOSDNS"; return 0; fi
  if [[ -x /usr/local/bin/mosdns ]]; then echo /usr/local/bin/mosdns; return 0; fi
  PDG_TEST_MOSDNS="$wd/mosdns" bash "$ADB_ROOT/tests/prepare-mosdns.sh" >/dev/null 2>&1 \
    && [[ -x "$wd/mosdns" ]] && { echo "$wd/mosdns"; return 0; }
  return 1
}

# 用**生产模板**渲染一份可跑的配置。占位符表与 install.sh 的 pdg_render 同源。
adb_render(){
  local out="$1" wd="$2"
  sed -e "s|__SERVER_IP__|127.0.0.9|g" \
      -e "s|__INTERNAL_CIDR__|127.0.0.0/8|g" \
      -e "s|__CERT_DIR__|$wd/cert|g" \
      -e "s|__SSH_PORT__|22|g" \
      -e "s|__MOSDNS_CACHE__|2048|g" \
      -e "s|__JOURNALD_MAXUSE__|20M|g" \
      -e "s|__HIJACK_SET_FILE__|geosite_geolocation-!cn.txt|g" \
      -e "s|__DOT_DOMAIN__|dot.adb.invalid|g" \
      "$ADB_ROOT/deploy/mosdns/config.yaml" > "$out"
  # 把监听端口与上游改到沙盒(不改模板结构, 只改这三处地址)
  sed -i -e "s|listen: \"0.0.0.0:53\"|listen: \"127.0.0.1:$ADB_UDP_PORT\"|g" \
         -e "s|listen: \"0.0.0.0:853\"|listen: \"127.0.0.1:$ADB_DOT_PORT\"|g" "$out"
  python3 - "$out" "$ADB_UP_PORT" <<'PY'
import re, sys
p, up = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read()
# 三个上游全部指向沙盒 mock, 免得测试真的打公网
t = re.sub(r'upstreams: \[[^\]]*\]', 'upstreams: [ {addr: "udp://127.0.0.1:%s"} ]' % up, t)
open(p, "w", encoding="utf-8").write(t)
PY
  grep -q '__[A-Z_]*__' "$out" && { echo "adblock-lib: 渲染后仍有未替换占位符" >&2; return 1; }
  return 0
}

# 沙盒里 mosdns 需要的规则文件全家桶(缺一个 domain_set 会让 mosdns FATAL)
adb_rules_dir(){
  local d="$1"
  mkdir -p "$d/etc/mosdns/rules" "$d/var/adblock" "$d/cert"
  for f in geosite_cn geosite_apple custom_direct custom_hijack ruleset_hijack \
           mitm_hijack unlock "geosite_geolocation-!cn"; do
    : > "$d/etc/mosdns/rules/$f.txt"
  done
}

adb_cert(){
  local d="$1"
  openssl req -x509 -newkey rsa:2048 -keyout "$d/cert/privkey.pem" -out "$d/cert/fullchain.pem" \
    -days 2 -nodes -subj "/CN=dot.adb.invalid" >/dev/null 2>&1
}

# 起上游 + mosdns。返回 0 表示 mosdns 真的在应答。
adb_start(){
  local bin="$1" conf="$2" uplog="$3"
  : > "$uplog"
  python3 "$ADB_ROOT/tests/adblock_upstream.py" "$ADB_UP_PORT" 203.0.113.9 "$uplog" >/dev/null 2>&1 &
  "$bin" start -c "$conf" >/dev/null 2>&1 &
  local _i
  for _i in $(seq 1 40); do
    dig @127.0.0.1 -p "$ADB_UDP_PORT" +timeout=1 +tries=1 +short readycheck.adb.invalid A >/dev/null 2>&1 && return 0
    sleep 0.15
  done
  return 1
}

# 按 comm 匹配停进程, 显式跳过自身(§9.13)。绝不用 pkill -f。
adb_stop(){
  python3 - "$ADB_UP_PORT" <<'PY'
import os, signal, sys
me, up = os.getpid(), sys.argv[1]
for p in os.listdir("/proc"):
    if not p.isdigit() or int(p) == me:
        continue
    try:
        comm = open("/proc/%s/comm" % p).read().strip()
        cmd = open("/proc/%s/cmdline" % p).read().replace("\0", " ")
    except OSError:
        continue
    if comm == "mosdns" or (comm.startswith("python") and "adblock_upstream.py" in cmd and up in cmd):
        try:
            os.kill(int(p), signal.SIGTERM)
        except OSError:
            pass
PY
  sleep 0.3
}

# 查询: adb_q <域名> <类型> <udp|tcp>  → 回显 rcode
adb_q(){
  local extra=""; [[ "$3" == tcp ]] && extra="+tcp"
  dig @127.0.0.1 -p "$ADB_UDP_PORT" $extra +timeout=3 +tries=1 +noall +comments "$1" "$2" 2>/dev/null \
    | grep -oE 'status: [A-Z]+' | head -1 | awk '{print $2}'
}

# DoT 查询(真 TLS): adb_qdot <域名> <类型> → 回显 rcode
adb_qdot(){
  python3 - "$1" "$2" "$ADB_DOT_PORT" <<'PY'
import socket, ssl, struct, sys
name, qt, port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
qn = b"".join(bytes([len(x)]) + x.encode() for x in name.split(".")) + b"\x00"
m = struct.pack("!HHHHHH", 0xABCD, 0x0100, 1, 0, 0, 0) + qn + struct.pack("!HH", qt, 1)
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection(("127.0.0.1", port), timeout=6) as s:
        with ctx.wrap_socket(s) as t:
            t.sendall(struct.pack("!H", len(m)) + m)
            ln = struct.unpack("!H", t.recv(2))[0]; r = b""
            while len(r) < ln:
                r += t.recv(ln - len(r))
    print({0: "NOERROR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}.get(r[3] & 0xF, "rcode%d" % (r[3] & 0xF)))
except Exception as e:                                    # noqa: BLE001
    print("ERR:%s" % e.__class__.__name__)
PY
}

# 上游是否见过这个域名(证明"被阻断的查询没去上游")
adb_upstream_saw(){ grep -qE "^$1 " "$2" 2>/dev/null; }

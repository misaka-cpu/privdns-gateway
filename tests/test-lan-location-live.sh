#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 反代对 Location 头的改写 —— **真 Caddy、真 HTTP 响应头**。
#
# 为什么要有这一支: 原来只有静态测试(检查生成出来的 Caddyfile 文本)加 `caddy adapt`。
# 前者只证明"字符串长这样", 后者只证明"配置能解析" —— **两者都不证明响应头真的被改了**。
# 代价是实打实的: v1.10.13 那条规则要求主机名后必须跟 `/`, 于是
#     http://HOST:30035        (无路径)
#     http://HOST:30035?x=1    (直接跟 query)
#     http://HOST:30035#frag   (直接跟 fragment)
# 三种合法形态全部漏掉 —— 而静态测试对此一路绿灯。RFC 3986 里 authority 之后可以直接是
# `?`、`#` 或字符串结尾, "Location 总是带路径"是当初拍脑袋写进注释的断言, 不是事实。
#
# 判据的取样方式也是刻意的: **从 lanpanel.py 现场生成的配置里抠出那一行**, 不手抄。
# 手抄的那份迟早跟生成器分家, 而分家的方向恰恰是"测试还绿着、线上已经不对"。
#
# caddy 不在就地下载(版本与 SHA256 沿用 lib/versions.sh 那一套, 不另立信任链)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WD="$(mktemp -d -t pdg-loclive-XXXXXX)"
CADDY=""
cleanup(){
  [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null
  [[ -n "${CADDY_PID:-}" ]] && kill "$CADDY_PID" 2>/dev/null
  rm -rf "$WD"
}
trap cleanup EXIT

# ── 取 caddy ────────────────────────────────────────────────────────────────
if [[ -x /usr/local/bin/caddy ]]; then
  CADDY=/usr/local/bin/caddy
elif command -v caddy >/dev/null 2>&1; then
  CADDY="$(command -v caddy)"
else
  # shellcheck source=lib/versions.sh
  source "$ROOT/lib/versions.sh" 2>/dev/null || { bad "读不到 lib/versions.sh"; exit 1; }
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64) arch=arm64;; esac
  url="https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/caddy_${CADDY_VER#v}_linux_${arch}.tar.gz"
  if curl -fsSL --max-time 120 -o "$WD/caddy.tgz" "$url" 2>/dev/null \
     && pdg_verify_sha256 "$WD/caddy.tgz" "${PDG_SHA256[caddy-$arch]:-}" "caddy $CADDY_VER" >/dev/null 2>&1 \
     && tar -xzf "$WD/caddy.tgz" -C "$WD" caddy 2>/dev/null; then
    CADDY="$WD/caddy"; chmod +x "$CADDY"
  else
    bad "拿不到 caddy(下载或校验失败) —— 这支测的就是真 Caddy 的行为, 不能跳过"
    exit 1
  fi
fi
ok "caddy 可用: $($CADDY version 2>/dev/null | head -1)"

# ── 从生成器现场取那条指令 ──────────────────────────────────────────────────
HOST="nas.example.test"
DIRECTIVE="$(python3 - "$ROOT" "$HOST" <<'PY'
import importlib.util, json, sys
root, host = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("lp", root + "/deploy/bot/lanpanel.py")
lp = importlib.util.module_from_spec(spec); spec.loader.exec_module(lp)
cfg = {"panels": [{"name": "nas", "host": host,
                   "target": "http://192.168.77.9:30035"}]}
for line in lp.render_caddy(cfg, "/etc/pdg-lan/certs").splitlines():
    if "header_down Location" in line and host in line:
        print(line.strip()); break
PY
)"
if [[ -z "$DIRECTIVE" ]]; then
  bad "lanpanel.py 没有为本域名生成 header_down Location —— 判据取样失败"
  exit 1
fi
ok "取到生成器的指令: $DIRECTIVE"

# ── 桩上游: 按 query 回不同的 Location ──────────────────────────────────────
cat > "$WD/stub.py" <<'PY'
import http.server, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        self.send_response(301)
        self.send_header("Location", q.get("loc", [""])[0])
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18901), H).serve_forever()
PY
cat > "$WD/Caddyfile" <<EOF
{
	admin off
	auto_https off
}
http://127.0.0.1:18900 {
	reverse_proxy http://127.0.0.1:18901 {
		$DIRECTIVE
	}
}
EOF
python3 "$WD/stub.py" >/dev/null 2>&1 & STUB_PID=$!
"$CADDY" run --config "$WD/Caddyfile" --adapter caddyfile >"$WD/caddy.log" 2>&1 & CADDY_PID=$!
for _ in $(seq 1 40); do
  ss -ltn 2>/dev/null | grep -q 18900 && ss -ltn 2>/dev/null | grep -q 18901 && break
  sleep 0.25
done
if ! ss -ltn 2>/dev/null | grep -q 18900; then
  bad "caddy 没起来:"; tail -3 "$WD/caddy.log" | sed 's/^/    /'; exit 1
fi
ok "测试台起来了(桩 18901 ← caddy 18900)"

probe(){   # $1=上游发的 Location  → stdout: 反代给出的 Location
  local q; q="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1")"
  curl -s -o /dev/null -D - --max-time 8 "http://127.0.0.1:18900/?loc=$q" 2>/dev/null \
    | grep -i '^location:' | tr -d '\r' | sed 's/^[Ll]ocation: //'
}

# ── 该被改写的: 指向本域名, 但 scheme/端口不对 ─────────────────────────────
while IFS='|' read -r src want label; do
  [[ -z "$src" ]] && continue
  got="$(probe "$src")"
  if [[ "$got" == "$want" ]]; then ok "$label: $src → $got"
  else bad "$label: $src → 得到 '${got:-（空）}', 期望 '$want'"; fi
done <<EOF
http://$HOST:30035/dir/|https://$HOST/dir/|带路径
http://$HOST:30035|https://$HOST|无路径
http://$HOST:30035?x=1|https://$HOST?x=1|直接跟 query
http://$HOST:30035#frag|https://$HOST#frag|直接跟 fragment
http://$HOST/dir/|https://$HOST/dir/|只是 scheme 不对
http://$HOST|https://$HOST|无路径且无端口
EOF

# ── 不该被碰的 ─────────────────────────────────────────────────────────────
while IFS='|' read -r src label; do
  [[ -z "$src" ]] && continue
  got="$(probe "$src")"
  if [[ "$got" == "$src" ]]; then ok "$label 原样放行: $src"
  else bad "$label 被误改: $src → $got"; fi
done <<EOF
http://$HOST.evil.test/x|同前缀的别的域名
https://$HOST/ok|本来就正确的
http://other.example.test:30035/x|别的域名
EOF

echo "─────────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" -eq 0 ]]

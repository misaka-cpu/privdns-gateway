#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 内网面板这一组测试的共用夹具: 把 pdg.sh 里的**生产函数原样**抽进沙箱跑, 不复制实现。
#
# 为什么单独一份: test-lan-rollback-convergence.sh 与 negctl 那支要抽同一批函数, 两边
# 各写一遍迟早不一致 —— 而不一致的方向是"负控抽到了、正控没抽到", 于是负控看起来有牙,
# 实际上两边测的根本不是同一个闭包。
#
# ⚠️ 抽取有两个已知陷阱, 这里各堵一个:
#
#   ① **单行函数会被范围抽取吃穿**(§9.7)。`_lan_intent(){ …; }` 写在一行上, 而
#      `sed -n '/^_lan_intent()/,/^}/p'` 会一路吃到**下一个**函数的收尾花括号, 于是
#      沙箱里凭空多出半个函数定义。lan_fx_extract 先判形态再决定取一行还是取范围。
#
#   ② **漏抽依赖 = 静默 127**(§10.7)。被测函数新增一个内部调用而抽取清单没跟上时,
#      那次调用返回 127, 而报错指向别处("形态认不出""nft 动作不对")。lan_fx_guard127
#      把 command not found 提成**具名失败**, 不许它伪装成被测行为。
# ─────────────────────────────────────────────────────────────────────────────

LAN_FX_SRC="${LAN_FX_SRC:?lan-fixture.sh 需要 LAN_FX_SRC 指向 deploy/bot/pdg.sh}"

# 抽一个函数。单行形态只取那一行, 多行形态取到第一个顶格 `}`。
lan_fx_extract(){
  local fn="$1" ln
  ln="$(grep -n "^${fn}()" "$LAN_FX_SRC" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || { echo "lan-fixture: 抽不到函数 $fn(改名了?)" >&2; return 1; }
  if sed -n "${ln}p" "$LAN_FX_SRC" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)\{.*\}[[:space:]]*$'; then
    sed -n "${ln}p" "$LAN_FX_SRC"
  else
    sed -n "${ln},/^}/p" "$LAN_FX_SRC"
  fi
}

# 本组测试要用到的生产函数闭包。**新增内部调用时这张表要跟着改** —— 漏了会被
# lan_fx_guard127 抓成具名失败, 而不是变成一条看不懂的断言。
LAN_FX_FUNCS=(
  c_g c_y
  _pdg_mktemp_dir _pdg_module
  _profile_set
  _lan_hosts _lan_intent _lan_migrate_certs _lan_cert_missing
  _lan_render _lan_install_managed _lan_restore_pre
  _lan_apply_proxy _lan_sync_after_change _lan_disable
)

# 沙箱专用的桩(**不是**生产函数): need_root 在非 root 下会 exit 1, 而这一组测的不是
# 权限门。写在这里而不是各测试里各写一份, 免得两支对"沙箱里什么算已就绪"的假设分叉。
LAN_FX_STUB_FUNCS='need_root(){ :; }'


# 把闭包写成一个可 source 的文件。缺哪个就整体失败, 不半截交付。
lan_fx_emit(){
  local out="$1" fn extra
  : > "$out"
  for fn in "${LAN_FX_FUNCS[@]}" "${@:2}"; do
    lan_fx_extract "$fn" >> "$out" || return 1
    echo >> "$out"
  done
  printf '%s\n\n' "$LAN_FX_STUB_FUNCS" >> "$out"
  # 可选函数: 存在才抽(本轮新增的收敛入口在基线上还不存在, 缺席要能被具名报出来)
  for extra in "${LAN_FX_OPTIONAL[@]:-}"; do
    [[ -n "$extra" ]] || continue
    grep -q "^${extra}()" "$LAN_FX_SRC" && { lan_fx_extract "$extra" >> "$out"; echo >> "$out"; }
  done
  return 0
}

# 沙箱假根: 造出 LAN 那几条路径, 并把生产变量指过去。
# 凭据(dns.env / certs)一并造出来 —— 收敛路径**不许碰它们**, 没有它们就证明不了这一条。
lan_fx_sandbox(){
  local w="$1"
  mkdir -p "$w/etc/pdg-lan/certs" "$w/etc/privdns-gateway" "$w/etc/systemd/system" \
           "$w/var/lib/pdg-lan" "$w/bin" "$w/state"
  # 证书必须是**真 PEM**: 生成物要交给真 Caddy 校验, 假证书会让校验在到达注入点之前就失败,
  # 于是每一格都"红得很像样"而其实什么都没测到 —— 这支测试第一版就栽在这里。
  if [[ -n "${LAN_FX_PEM_DIR:-}" && -s "$LAN_FX_PEM_DIR/panel.crt" ]]; then
    cp "$LAN_FX_PEM_DIR/panel.crt" "$LAN_FX_PEM_DIR/panel.key" "$w/etc/pdg-lan/certs/"
  else
    echo "lan-fixture: 需要 LAN_FX_PEM_DIR 指向一对真 PEM" >&2; return 1
  fi
  echo "CF_Token=must-not-be-touched" > "$w/etc/pdg-lan/dns.env"
  chmod 600 "$w/etc/pdg-lan/dns.env"
}

# 沙箱里的 PATH 桩。systemctl/nft/caddy 都按**状态派生**回答, 不返回恒定的"健康"(§9.1)。
# 每个桩把自己的调用记进 $w/calls.log —— 断言要能指认是哪一步做的, 不能只看最终文件。
lan_fx_stubs(){
  local w="$1"
  cat > "$w/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_CALLS"
case "$1" in
  is-active)
    shift; [[ "${1:-}" == "--quiet" ]] && shift
    [[ -e "$FX_ROOT/state/active" ]] || exit 3
    echo active; exit 0;;
  daemon-reload) [[ -e "$FX_ROOT/state/reload-fails" ]] && exit 1; exit 0;;
  restart)
    [[ -e "$FX_ROOT/state/restart-fails" ]] && exit 1
    touch "$FX_ROOT/state/active"; exit 0;;
  disable) rm -f "$FX_ROOT/state/active"; exit 0;;
  *) exit 0;;
esac
STUB
  cat > "$w/bin/nft" <<'STUB'
#!/usr/bin/env bash
echo "nft $*" >> "$FX_CALLS"
# -c 是"只校验": 候选文件语法坏了要说不。故障注入用 state/nft-check-fails。
if [[ "${1:-}" == "-c" ]]; then
  [[ -e "$FX_ROOT/state/nft-check-fails" ]] && { echo "nft: syntax error" >&2; exit 1; }
  exit 0
fi
if [[ "${1:-}" == "delete" ]]; then rm -f "$FX_ROOT/state/pdglan-table"; exit 0; fi
if [[ "${1:-}" == "-f" ]]; then touch "$FX_ROOT/state/pdglan-table"; exit 0; fi
exit 0
STUB
  chmod 755 "$w/bin/systemctl" "$w/bin/nft"
}

# 生产变量绑到沙箱。REPO_DIR 指真仓库 —— lanpanel.py / units.sh 必须是**真的那一份**。
lan_fx_bind(){
  local w="$1" repo="$2"
  export FX_ROOT="$w" FX_CALLS="$w/calls.log"
  mkdir -p "$w/state"
  : > "$FX_CALLS"
  REPO_DIR="$repo"
  LAN_USER="$(id -un)"                      # 沙箱里不建系统用户: 用当前用户, install -o/-g 才可能成功
  LAN_ETC="$w/etc/pdg-lan"
  LAN_CADDYFILE="$LAN_ETC/caddy.conf"
  LAN_NFT_CONF="$w/etc/nftables-pdg-lan.conf"
  LAN_CERT_DIR="$LAN_ETC/certs"
  LAN_DNS_ENV="$LAN_ETC/dns.env"
  LAN_UNIT="$w/etc/systemd/system/pdg-lan.service"
  LAN_STATE_DIR="$w/var/lib/pdg-lan"
  LAN_TABLE_PATH="$w/etc/privdns-gateway/lan-panels.json"
  PROFILE_ENV="$w/etc/privdns-gateway/profile.env"
  ACME_HOME="$w/opt/pdg-acme"
  export REPO_DIR LAN_USER LAN_ETC LAN_CADDYFILE LAN_NFT_CONF LAN_CERT_DIR LAN_DNS_ENV \
         LAN_UNIT LAN_STATE_DIR LAN_TABLE_PATH PROFILE_ENV ACME_HOME
  PATH="$w/bin:$PATH"; export PATH
}

# 写一份面板表。参数: <文件> <name:host:ip:port> …
lan_fx_model(){
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
panels = []
for spec in sys.argv[2:]:
    name, host, ip, port = spec.split(":")
    panels.append({"name": name, "host": host, "target": "http://%s:%s" % (ip, port)})
json.dump({"panels": panels}, open(out, "w"), ensure_ascii=False, indent=2)
PY
}

# 从**任意** Caddyfile 抽 (host → 上游) 投影。正反两侧共用这一个抽取器 ——
# 抽取器自己有偏差时两边同样偏, 不会凭空造出"漂移"。
lan_fx_routes(){
  python3 - "$1" <<'PY'
import re, sys
try:
    txt = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
host = None
for line in txt.splitlines():
    m = re.match(r'^(\S+):443\s*\{', line)
    if m:
        host = m.group(1); continue
    m = re.match(r'^\s*reverse_proxy\s+(\S+)', line)
    if m and host:
        print("%s=%s" % (host, m.group(1))); host = None
PY
}

# 127 守卫: 漏抽依赖时把它提成具名失败, 不让它伪装成被测行为(§10.7)。
lan_fx_guard127(){
  local logf="$1"
  grep -q 'command not found' "$logf" 2>/dev/null && {
    echo "夹具漏抽依赖(127): $(grep -o '[A-Za-z_][A-Za-z0-9_]*: command not found' "$logf" | sort -u | tr '\n' ' ')"
    return 1
  }
  return 0
}

# 一对自签 PEM, 覆盖测试用的面板域名。生成一次, 各沙箱复制。
lan_fx_make_pem(){
  local d="$1"; mkdir -p "$d"
  openssl req -x509 -newkey rsa:2048 -keyout "$d/panel.key" -out "$d/panel.crt" \
    -days 2 -nodes -subj "/CN=lan.test" \
    -addext "subjectAltName=DNS:a.lan.test,DNS:b.lan.test,DNS:c.lan.test,DNS:p1.lan.test" \
    >/dev/null 2>&1 || return 1
  [[ -s "$d/panel.crt" && -s "$d/panel.key" ]]
}

# 真 Caddy: 本地 → PATH → 按 lib/versions.sh 钉死的 SHA 下载。拿不到**硬失败**, 不跳过 ——
# 口径与 tests/test-lan-location-live.sh 一致, 不另立一套信任链。
lan_fx_caddy(){
  local root="$1" wd="$2" arch url
  if [[ -x /usr/local/bin/caddy ]]; then echo /usr/local/bin/caddy; return 0; fi
  if command -v caddy >/dev/null 2>&1; then command -v caddy; return 0; fi
  # shellcheck source=lib/versions.sh
  source "$root/lib/versions.sh" 2>/dev/null || return 1
  case "$(dpkg --print-architecture 2>/dev/null)" in amd64) arch=amd64;; arm64) arch=arm64;; *) return 1;; esac
  url="https://github.com/caddyserver/caddy/releases/download/${CADDY_VER}/caddy_${CADDY_VER#v}_linux_${arch}.tar.gz"
  curl -fsSL --max-time 120 -o "$wd/caddy.tgz" "$url" 2>/dev/null || return 1
  pdg_verify_sha256 "$wd/caddy.tgz" "${PDG_SHA256[caddy-$arch]:-}" "caddy $CADDY_VER" >/dev/null 2>&1 || return 1
  tar -xzf "$wd/caddy.tgz" -C "$wd" caddy 2>/dev/null || return 1
  chmod +x "$wd/caddy"; echo "$wd/caddy"
}

#!/usr/bin/env bash
# WLOC 退役测试共用的**隔离沙箱**。三条路径各自隔离, 一条都不许回退到宿主:
#
#   · 数据路径  PDG_TX_FSROOT      → $SBOX(pdgtx/iosstate 的所有生产路径都挂在它下面)
#   · 锁路径    PDG_LOCKFILE       → $SBOX/run/privdns-gateway.lock
#   · 模块路径  $SBOX/opt/pdg-bot  → 从仓库复制出来的**真模块**(不是桩)
#
# 为什么必须把模块也隔离: 被测的 shell 函数里写着 `cd /opt/pdg-bot && python3 -c 'import …'`。
# 宿主上碰巧装过 pdg 的话, 测试会去 import **宿主那一份**, 于是"改了仓库里的代码"与"测试
# 结果"之间没有因果关系 —— 绿是假绿, 红也查不出是哪一份的红。
#
# 用法: source 本文件后 `sbox_new`, 拿到 $SBOX; 结束 `sbox_rm`。
# shellcheck shell=bash

_SBOX_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 真模块清单**从 lib/modules.sh 推导**, 不手列。
#
# 手列过一次, 结果是 bot.py `import cfgrestore` 当场 ModuleNotFoundError —— 那种炸看起来
# 完全像"被测逻辑坏了", 查半天才发现是夹具少复制了一个文件。清单跟着真实安装清单走, 加模块
# 时这里自动跟上。
_sbox_module_list(){
  # 每行 `源路径 目标名 mode`。**行首可能带 `VAR="`** —— 清单是多行字符串赋值, 第一项与
  # 变量名在同一行。第一版的正则锚在行首, 正好把 pdgtx.py(它是第一项)漏掉了, 表现成
  # `ModuleNotFoundError: No module named 'pdgtx'`, 看起来完全像被测逻辑坏了。
  sed -n 's/.*\(deploy\/bot\/[A-Za-z0-9_.-]*\.py\) \([A-Za-z0-9_.-]*\.py\) [0-7]*.*/\1 \2/p' \
      "$_SBOX_REPO/lib/modules.sh"
}

sbox_new(){
  SBOX="$(mktemp -d "${TMPDIR:-/tmp}/pdg-wloc-sbox.XXXXXXXX")" || return 1
  mkdir -p "$SBOX"/{run,state,opt/pdg-bot,etc/sing-box,etc/privdns-gateway/ca,etc/mosdns/rules,etc/mihomo,etc/systemd/system} \
           "$SBOX"/var/lib/privdns-gateway/ios-profile || return 1
  local src dst
  while read -r src dst; do
    [[ -n "$src" && -f "$_SBOX_REPO/$src" ]] || continue
    cp "$_SBOX_REPO/$src" "$SBOX/opt/pdg-bot/$dst"
  done < <(_sbox_module_list)
  # 清单里没有的那几个是**平台专属**(PDG_IOS_MODULES), 单独取 —— 这个沙箱造的就是 iOS 机器。
  for src in iosstate.py iosprofile.py mitm_ca.py; do
    [[ -f "$_SBOX_REPO/deploy/bot/$src" ]] && cp "$_SBOX_REPO/deploy/bot/$src" "$SBOX/opt/pdg-bot/$src"
  done
  cp "$_SBOX_REPO/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl" \
     "$SBOX/opt/pdg-bot/pdg-dot.mobileconfig.tmpl"
  # 自检: 沙箱**自己**要能把两个入口模块 import 起来。少复制一个文件的后果是
  # ModuleNotFoundError, 而那看起来与"被测逻辑坏了"一模一样 —— 在这里当场说清楚是夹具坏了。
  local _err
  if ! _err="$( cd "$SBOX/opt/pdg-bot" && PYTHONPATH="$SBOX/opt/pdg-bot" \
                PDG_TX_FSROOT="$SBOX" PDG_LOCKFILE="$SBOX/run/privdns-gateway.lock" \
                PDG_BOT_TOKEN=1:sbox python3 -c 'import bot, iosstate, pdgtx' 2>&1 )"; then
    echo "[夹具] 沙箱模块不完整, 不是被测逻辑的问题: $(printf '%s' "$_err" | tail -1)" >&2
    return 1
  fi
  export SBOX
  export PDG_TX_FSROOT="$SBOX"
  export PDG_LOCKFILE="$SBOX/run/privdns-gateway.lock"
  export PDG_RETIRE_ROOT="$SBOX"
  export PDG_BOT_TOKEN="${PDG_BOT_TOKEN:-1:sbox}"
  return 0
}

sbox_rm(){ [[ -n "${SBOX:-}" && "$SBOX" == */pdg-wloc-sbox.* ]] && rm -rf "$SBOX"; }

# 沙箱里跑一段 python, **模块路径只有沙箱那一份**。
sbox_py(){ ( cd "$SBOX/opt/pdg-bot" && PYTHONPATH="$SBOX/opt/pdg-bot" python3 -c "$1" ); }

# 造一台退役前的 iOS 机器。$1 = on|off(WLOC 开/关), $2... = SSID(可选)
sbox_legacy_ios(){
  local wloc="$1"; shift
  SBOX_WLOC="$wloc" SBOX_SSIDS="$*" sbox_py '
import hashlib, json, os, plistlib, sys
import iosprofile, iosstate as S
root = os.environ["PDG_TX_FSROOT"]
wloc = os.environ["SBOX_WLOC"] == "on"
ssids = [x for x in os.environ.get("SBOX_SSIDS", "").split() if x]
tmpl = os.path.join(root, "opt/pdg-bot/pdg-dot.mobileconfig.tmpl")
iid = "8f14e45f-ceea-4d4c-a3e6-5b0a1c2d3e4f"
ids = S.derive_ids(iid)
der = b""
if wloc:
    import subprocess, tempfile
    d = tempfile.mkdtemp()
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec",
                    "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", d + "/k.pem", "-out", d + "/c.pem", "-days", "30",
                    "-subj", "/CN=PDG Sandbox CA"], check=True, capture_output=True)
    der = iosprofile.ca_der_from_pem(open(d + "/c.pem", encoding="utf-8").read())
    os.makedirs(os.path.join(root, "etc/privdns-gateway/ca"), exist_ok=True)
    open(os.path.join(root, "etc/privdns-gateway/ca/ca.crt"), "w").write(
        open(d + "/c.pem", encoding="utf-8").read())
    open(os.path.join(root, "etc/privdns-gateway/ca/ca.key"), "w").write(
        open(d + "/k.pem", encoding="utf-8").read())


def render(rev_ssids):
    raw = iosprofile.render("dot.example.com", "203.0.113.10", rev_ssids, ids, tmpl)
    if not der:
        return raw
    pl = plistlib.loads(raw)
    pl["PayloadContent"].append({
        "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
        "PayloadIdentifier": iosprofile.ID_CA, "PayloadUUID": ids["ca"],
        "PayloadDisplayName": iosprofile.CA_DISPLAY, "PayloadContent": der,
        "PayloadCertificateFileName": iosprofile.CA_FILENAME})
    return plistlib.dumps(pl)


recs = []
art = os.path.join(root, "var/lib/privdns-gateway/ios-profile")
os.makedirs(art, exist_ok=True)
for rev in (1, 2):
    data = render(ssids)
    inp = {"schema": 1, "dot_host": iosprofile.norm_host("dot.example.com"),
           "server_addresses": iosprofile.norm_addrs("203.0.113.10"),
           "dns_protocol": "TLS", "probe_url": S.probe_url_for("203.0.113.10"),
           "ondemand_core": S.ondemand_core(tmpl),
           "ssids": iosprofile.norm_ssids(ssids),
           "wloc_enabled": bool(der),
           "wloc_ca_sha256": hashlib.sha256(der).hexdigest() if der else ""}
    recs.append({"revision": rev, "digest": S.digest_of(inp), "inputs": inp,
                 "sha256": hashlib.sha256(data).hexdigest(),
                 "generated_at": "2026-01-0%dT00:00:00Z" % rev, "sent_at": None})
    open(os.path.join(art, S.CUR if rev == 2 else S.PREV), "wb").write(data)
meta = {"schema": 1, "instance_id": iid, "created_at": "2026-01-01T00:00:00Z",
        "migration_pending": False, "current": recs[1], "previous": recs[0]}
p = os.path.join(root, "etc/privdns-gateway/ios-profile.json")
open(p, "w", encoding="utf-8").write(
    json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
os.chmod(p, 0o600)
print("OK")
'
}

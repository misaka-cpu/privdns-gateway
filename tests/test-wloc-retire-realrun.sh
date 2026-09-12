#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役 · **真模块参与**的迁移回环。
#
# tests/test-wloc-retire-migration.sh 验的是编排(顺序、判据、失败怎么恢复), 它把渲染器与
# schema 迁移换成了可控旋钮 —— 那是必要的, 因为"按需失败"没法用真实现造出来。
#
# 但只有那一支的话, 整条链上最要紧的一件事没人验: **真的渲染器真的把 MITM 路由撤掉了吗**,
# **真的 schema 迁移真的在 CLI 持锁时跑得通吗**。把它们换成"调用过即成功"的桩, 测试绿了只
# 说明编排没错, 而用户机器上那条指向 7894 的路由可能一条没少。
#
# 所以这一支反过来: 编排照跑, **一个被测函数都不打桩**(systemctl 除外 —— 沙箱里没有 systemd),
# 真模块从隔离出来的 $SBOX/opt/pdg-bot 里 import, 数据/锁/模块三条路径都不回退到宿主。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/helpers/wloc-retire-sandbox.sh
source "$HERE/helpers/wloc-retire-sandbox.sh"

pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
c_g(){ :; }; c_y(){ :; }; c_r(){ :; }

# systemctl 是环境, 不是被测逻辑 —— 沙箱里没有 systemd, 只能记账。
SC_LOG=""
systemctl(){
  echo "$*" >> "$SC_LOG"
  case "$1" in
    is-active) [[ -e "$SBOX/state/$2.active" ]] && { echo active; return 0; }
               echo inactive; return 3;;
    disable|stop) rm -f "$SBOX/state/${*: -1}.active"; return 0;;
    start|restart) : > "$SBOX/state/${*: -1}.active"; return 0;;
    *) return 0;;
  esac
}
export -f systemctl 2>/dev/null || true
_pdg_core_svc(){ echo mihomo; }

# 被测的**全部**是真的, 一个都不替换。
for _fn in _retire_svc_stopped _retire_core_has_mitm _retire_undo_push _retire_undo_run \
           _retire_fail _retire_rerender_core _retire_ios_schema _retire_disable_wloc_json \
           _retire_ca_report migrate_wloc_retire; do
  eval "$(sed -n "/^$_fn(){/,/^}/p" "$ROOT/deploy/bot/pdg.sh")"
  declare -F "$_fn" >/dev/null || { bad "pdg.sh 里抽不出 $_fn"; }
done
_RETIRE_UNDO=()

# ── 造一台**退役前的完整机器** ───────────────────────────────────────────────
full_machine(){   # $1 = SSID(可空)
  sbox_new || return 1
  SC_LOG="$SBOX/systemctl.log"; : > "$SC_LOG"
  mkdir -p "$SBOX/state"; : > "$SBOX/state/pdg-mitm.active"
  sbox_legacy_ios on ${1:-} >/dev/null || return 1
  echo ios > "$SBOX/etc/privdns-gateway/platform"
  printf 'domain:gs-loc.apple.com\ndomain:gs-loc-cn.apple.com\n' \
    > "$SBOX/etc/mosdns/rules/mitm_hijack.txt"
  printf '{"wloc":{"enabled":true,"active":"东京","locations":[{"name":"东京","lat":35.6,"lon":139.7}]}}\n' \
    > "$SBOX/etc/privdns-gateway/mitm.json"
  : > "$SBOX/opt/pdg-bot/mitm_server.py"; : > "$SBOX/opt/pdg-bot/mitm_wloc.py"
  echo "[Unit]" > "$SBOX/etc/systemd/system/pdg-mitm.service"
  # 真的数据模型 + 一份**带 MITM-OUT 的**旧内核配置(退役前那台机器盘上就是这样)
  cat > "$SBOX/etc/sing-box/config.json" <<'JSON'
{"log":{"level":"warn"},"inbounds":[],
 "outbounds":[{"type":"direct","tag":"direct"},
              {"type":"shadowsocks","tag":"hkt","server":"1.2.3.4","server_port":8388,
               "method":"aes-128-gcm","password":"PW"}],
 "route":{"rules":[{"domain_suffix":["ex.test"],"outbound":"hkt"}],"final":"direct"}}
JSON
  cat > "$SBOX/etc/mihomo/config.yaml" <<'YAML'
{"proxies":[{"name":"MITM-OUT","type":"socks5","server":"127.0.0.1","port":7894,"udp":false}],
 "rules":["DOMAIN-SUFFIX,gs-loc.apple.com,MITM-OUT","MATCH,DIRECT"]}
YAML
  return 0
}

# ══ 1. 全开的老机器, 在 CLI 持锁下走完整条链 ════════════════════════════════
echo "══ 1. 真模块 · CLI 持锁 · 完整退役 ══"
full_machine "Home Office" || bad "沙箱构造失败"
grep -q 'MITM-OUT' "$SBOX/etc/mihomo/config.yaml" && ok "前置: 内核配置里确实有 MITM-OUT" \
  || bad "前置构造错了"
out="$( ( exec 9>"$PDG_LOCKFILE"; flock -n 9 || exit 99; migrate_wloc_retire ) 2>&1 )"; rc=$?
[[ $rc -eq 0 ]] && ok "CLI 持锁下完整退役成功(真渲染器 + 真 schema 迁移)" \
  || bad "退役失败 rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"

grep -q 'MITM-OUT' "$SBOX/etc/mihomo/config.yaml" \
  && bad "**真的**渲染器没把 MITM-OUT 撤掉 —— 那条指向 7894 的路由还在" \
  || ok "真渲染器确实撤掉了 MITM-OUT(不是桩说'调过了')"
grep -q 'hkt' "$SBOX/etc/mihomo/config.yaml" \
  && ok "用户的出口与分流仍在(重渲不是把配置清空)" || bad "重渲把别的配置弄丢了"
[[ ! -s "$SBOX/etc/mosdns/rules/mitm_hijack.txt" ]] && ok "劫持表已清空" || bad "劫持表还有内容"
[[ -e "$SBOX/etc/mosdns/rules/mitm_hijack.txt" ]] && ok "劫持表文件仍在(mosdns 的 domain_set 指着它)" \
  || bad "劫持表文件被删了"
[[ ! -e "$SBOX/opt/pdg-bot/mitm_server.py" && ! -e "$SBOX/etc/systemd/system/pdg-mitm.service" ]] \
  && ok "退役模块与 unit 已删" || bad "模块/unit 还在"
[[ -e "$SBOX/etc/privdns-gateway/ca/ca.key" ]] \
  && ok "CA 材料按保留策略留着(不替用户永久销毁)" || bad "CA 私钥被删了"

# schema 与用户设置
sc="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["schema"])' \
      "$SBOX/etc/privdns-gateway/ios-profile.json")"
[[ "$sc" == 2 ]] && ok "真 schema 迁移跑通: 记录已是 schema 2" || bad "记录仍是 schema $sc"
ss="$(sbox_py '
import iosstate as S
m = S.load()
print(",".join(S.effective_inputs(m, "dot.example.com", "203.0.113.10", None,
      __import__("os").path.join(__import__("os").environ["PDG_TX_FSROOT"],
                                 "opt/pdg-bot/pdg-dot.mobileconfig.tmpl"))["ssids"]))')"
[[ "$ss" == "Home,Office" ]] && ok "用户的 SSID 名单活过了退役(实得 $ss)" \
  || bad "SSID 被退役顺手抹掉了(实得 '$ss')"
# 重新生成一份: 不含根证书
gen="$(sbox_py '
import os, plistlib
import iosstate as S
tmpl = os.path.join(os.environ["PDG_TX_FSROOT"], "opt/pdg-bot/pdg-dot.mobileconfig.tmpl")
m, lv, why, data, ch = S.generate("dot.example.com", "203.0.113.10", None, tmpl)
pl = plistlib.loads(data)
has = any(x.get("PayloadType") == "com.apple.security.root" for x in pl["PayloadContent"])
rules = pl["PayloadContent"][0].get("OnDemandRules") or []
print("%s|%s|%s" % (m["current"]["revision"], has, rules[0].get("SSIDMatch")))')"
IFS='|' read -r rev hasca ssm <<< "$gen"
[[ "$hasca" == "False" ]] && ok "退役后重新生成: 产物不含根证书" || bad "新产物里还有根证书"
[[ "$rev" == 3 ]] && ok "版本号接着退役那一版往下数(第 $rev 版)" || bad "版本号不对: $rev"
[[ "$ssm" == "['Home', 'Office']" ]] && ok "新产物里那条 SSID 规则仍在(真的渲染出来了)" \
  || bad "新产物里 SSID 规则不对: $ssm"
sbox_rm

# ══ 2. 幂等: 再跑一次不动任何东西, 也不重启服务 ═════════════════════════════
echo
echo "══ 2. 幂等 ══"
full_machine || bad "沙箱构造失败"
( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) >/dev/null 2>&1
before="$(cd "$SBOX" && find etc var opt -type f -exec sha256sum {} + 2>/dev/null | sort -k2)"
: > "$SC_LOG"
( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) >/dev/null 2>&1; rc2=$?
after="$(cd "$SBOX" && find etc var opt -type f -exec sha256sum {} + 2>/dev/null | sort -k2)"
[[ $rc2 -eq 0 ]] && ok "二次运行 rc=0" || bad "二次运行 rc=$rc2"
[[ "$before" == "$after" ]] && ok "二次运行一个字节都没改" \
  || bad "二次运行改了东西: $(diff <(echo "$before") <(echo "$after") | head -3 | tr '\n' ' ')"
grep -qE 'restart' "$SC_LOG" && bad "无事可做却重启了服务(白断一次 DNS)" \
  || ok "无事可做 → 不重启任何服务"
sbox_rm

# ══ 3. 渲染器没真撤掉路由时: 必须拒绝安装 ══════════════════════════════════
echo
echo "══ 3. 候选自证 ══"
# 这一格盯的是"候选先行"这条纪律本身: 渲染出来的东西在**装上去之前**要先被看一眼。
# 造法: 把沙箱里的 sb2mihomo 换成一个仍然注入 MITM-OUT 的版本(模拟"改了别处、漏改渲染器")。
full_machine || bad "沙箱构造失败"
python3 - "$SBOX/opt/pdg-bot/sb2mihomo.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = s.replace("    # ── 内网面板(方案 B): 面板域名 → 本机反代 ──",
              '    proxies.append({"name": "MITM-OUT", "type": "socks5",\n'
              '                    "server": "127.0.0.1", "port": 7894, "udp": False})\n'
              "    # ── 内网面板(方案 B): 面板域名 → 本机反代 ──", 1)
open(p, "w", encoding="utf-8").write(s)
PY
live_before="$(sha256sum "$SBOX/etc/mihomo/config.yaml" | cut -d' ' -f1)"
out="$( ( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) 2>&1 )"; rc3=$?
[[ $rc3 -ne 0 ]] && ok "候选里仍有 MITM-OUT → 拒绝安装(rc=$rc3)" \
  || bad "候选里还有 MITM-OUT 却照装不误"
[[ "$(sha256sum "$SBOX/etc/mihomo/config.yaml" | cut -d' ' -f1)" == "$live_before" ]] \
  && ok "被拒时现网内核配置一个字节都没动(候选先行成立)" || bad "拒绝了却把候选装上去了"
sbox_rm

# ══ 4. 模块路径不许回退到宿主 /opt ═════════════════════════════════════════
echo
echo "══ 4. 不回退宿主 ══"
full_machine || bad "沙箱构造失败"
rm -f "$SBOX/opt/pdg-bot/bot.py"            # 沙箱里没有渲染器了
out="$( ( exec 9>"$PDG_LOCKFILE"; flock -n 9; migrate_wloc_retire ) 2>&1 )"; rc4=$?
[[ $rc4 -ne 0 ]] && ok "沙箱里没有 bot.py → 失败(没有偷偷去读宿主 /opt 那一份)" \
  || bad "沙箱里没有渲染器却成功了 —— 它回退到宿主 /opt 去了"
sbox_rm

echo
echo "[SUM] OK=$pass FAIL=$nfail"
[[ $nfail -eq 0 ]]

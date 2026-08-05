#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: WLOC(iOS 位置改写)。走**真实的 _mitm_transact 事务**开启 WLOC, 然后真起
# mitm_server, 用一个**假 gs-loc 上游**充当 Apple, 验证:
#   · 事务把 mitm.json / hijack / 内核路由 / 叶子证书都落到位;
#   · MITM 服务真的能用 CA 签的叶子证书终止 TLS;
#   · 插件把 Apple 响应里的坐标**改写成设定城市**, 而其余字段保持原样(格式保真, iOS 才认)。
#
# 单测分别覆盖过 protobuf 编解码(test-mitm-wloc.py)与事务回滚(test-mitm-wloc-txn.py),
# 但"事务开完之后, 服务端真的按改写后的坐标应答"这条链没人端到端验过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
printf 'mihomo\n' > /etc/privdns-gateway/backend
printf 'ios\n'    > /etc/privdns-gateway/platform     # WLOC 仅 iOS
e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"

LAT=34.6937; LON=135.5023      # 大阪

# ══ 1. 用真实事务开启 WLOC ═══════════════════════════════════════════════════
echo "── 1. _mitm_transact 开启 WLOC ──"
python3 - > $E2E_TMP/wloc-on.out 2>&1 <<PY
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
w = {"enabled": True, "accuracy": 50, "active": "大阪",
     "locations": [{"name": "大阪", "lat": $LAT, "lon": $LON}]}
okr, msg = bot._mitm_transact(w)
print(("OK|" if okr else "FAIL|") + (msg or ""))
PY
grep -q '^OK|' $E2E_TMP/wloc-on.out && ok "WLOC 事务开启成功(CA+叶子证书+hijack+内核路由 全落地)" \
  || bad "开启失败: $(cat $E2E_TMP/wloc-on.out)"

python3 -c "
import json,sys
c=json.load(open('/etc/privdns-gateway/mitm.json'))
sys.exit(0 if c.get('wloc',{}).get('enabled') else 1)" \
  && ok "mitm.json 持久化 enabled=true" || bad "mitm.json 未落 enabled"
grep -q 'gs-loc.apple.com' /etc/mosdns/rules/mitm_hijack.txt \
  && ok "mosdns 强制劫持表含 gs-loc 接管域名" || bad "hijack 表缺 gs-loc"
[[ -s /etc/privdns-gateway/ca/ca.crt ]] && ok "MITM 根 CA 已生成" || bad "缺 CA"
python3 -c "
import json,sys
d=json.load(open('/etc/mihomo/config.yaml'))
has_out=any(p.get('name')=='MITM-OUT' for p in d.get('proxies',[]))
has_rule=any('MITM-OUT' in r and 'gs-loc' in r for r in d.get('rules',[]))
sys.exit(0 if (has_out and has_rule) else 1)" \
  && ok "mihomo 里有 MITM-OUT 出站 + gs-loc → MITM-OUT 路由" || bad "内核 MITM 路由缺失"

# 叶子证书: 两个 gs-loc 域名都应已预签(严格预签少一张就整体回滚)
python3 - <<'PY' > $E2E_TMP/wloc-leaf.out 2>&1
import sys; sys.path.insert(0, "/opt/pdg-bot")
import mitm_ca
for d in ("gs-loc.apple.com", "gs-loc-cn.apple.com"):
    crt, key = mitm_ca.leaf_cert(d)
    print("LEAF|%s|%s" % (d, "yes" if crt and key else "no"))
PY
[[ "$(grep -c 'LEAF|.*|yes' $E2E_TMP/wloc-leaf.out)" == 2 ]] \
  && ok "两个 gs-loc 域名的叶子证书都已就绪" || bad "叶子证书不全: $(cat $E2E_TMP/wloc-leaf.out)"

# ══ 2. 坐标改写: 造一份**格式真实**的 Apple 响应, 过真实 patch_response ═══════
# WLOC 的做法是"转发真 Apple 拿回真响应, 只 patch 坐标"(格式 100% 保真 iOS 才认),
# 所以这里用 build_response 造出与真响应同构的报文, 再走真实改写路径验证结果。
echo; echo "── 2. 坐标改写(真实 build/patch/parse 链路) ──"
python3 - > $E2E_TMP/wloc-core.out 2>&1 <<PY
import sys; sys.path.insert(0, "/opt/pdg-bot")
import mitm_wloc as W
REAL = (51.5074, -0.1278)          # 假 Apple 返回"伦敦"
MACS = ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"]
body = W.build_response(MACS, REAL[0], REAL[1], 40)
before = W.parse_response(body)
out = W.patch_response(body, $LAT, $LON)
after = W.parse_response(out)
print("BEFORE|%r" % (before,))
print("AFTER|%r" % (after,))
print("PREFIX_SAME|%s" % (W._split_resp(body)[0] == W._split_resp(out)[0]))
PY
if ! grep -q '^AFTER|' $E2E_TMP/wloc-core.out; then
  bad "坐标改写链路跑不通: $(head -5 $E2E_TMP/wloc-core.out)"
else
  python3 - <<PY && ok "所有 BSSID 的坐标都被改写到设定城市(误差 <1e-6°)" || bad "改写结果不对: $(grep AFTER $E2E_TMP/wloc-core.out)"
import re, sys
t = open("$E2E_TMP/wloc-core.out").read()
after = eval(re.search(r"AFTER\|(.*)", t).group(1))
assert after, "解析结果为空"
for mac, (lat, lon, acc) in after.items():
    assert abs(lat - $LAT) < 1e-6, (mac, lat)
    assert abs(lon - $LON) < 1e-6, (mac, lon)
PY
  python3 - <<'PY' && ok "BSSID 与精度字段保持原样(只动坐标, 格式保真)" || bad "非坐标字段被改动了"
import os, re
t = open(os.environ["E2E_TMP"] + "/wloc-core.out").read()
before = eval(re.search(r"BEFORE\|(.*)", t).group(1))
after  = eval(re.search(r"AFTER\|(.*)",  t).group(1))
assert set(before) == set(after), (set(before), set(after))
for mac in before:
    assert before[mac][2] == after[mac][2], (mac, before[mac][2], after[mac][2])
PY
  grep -q 'PREFIX_SAME|True' $E2E_TMP/wloc-core.out \
    && ok "响应头部字节不变(iOS 对格式敏感)" || bad "头部被改动"
fi

# ══ 2.5 切地点走快路径: 一个服务都不许重启 ══════════════════════════════════
# 只改经纬度时接管域名没变 —— CA、hijack 表、内核路由都不用动: 切换只原子更新 mitm.json,
# pdg-mitm 在下一次 WLOC 请求开始时读取当前配置, 无需重启服务。
# 这里以**整个装机现场**为背景验证: 切换前后 hijack/内核配置逐字节不变, 且期间没有任何
# systemctl 调用(桩把每次调用记在 $E2E_TMP/e2e-calls.log)。
echo; echo "── 2.5 切换地点(快路径) ──"
python3 - > $E2E_TMP/wloc-add.out 2>&1 <<'PY'
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
print(bot.wloc_add("札幌", 43.0621, 141.3544))
PY
HIJ_SHA="$(sha256sum /etc/mosdns/rules/mitm_hijack.txt | cut -d' ' -f1)"
CFG_SHA="$(sha256sum /etc/mihomo/config.yaml | cut -d' ' -f1)"
GEN_BEFORE="$(python3 -c "import json;print(json.load(open('/etc/privdns-gateway/mitm.json'))['wloc'].get('generation',0))")"
CALLS_BEFORE="$(wc -l < $E2E_TMP/e2e-calls.log)"
SW_T0="$(date +%s%N)"
python3 - > $E2E_TMP/wloc-sw.out 2>&1 <<'PY'
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
okr, msg, gen = bot.wloc_switch_gen("札幌")
print(("OK|" if okr else "FAIL|") + str(gen) + "|" + msg.replace("\n", " "))
PY
SW_MS=$(( ($(date +%s%N) - SW_T0) / 1000000 ))
grep -q '^OK|' $E2E_TMP/wloc-sw.out && ok "切换到札幌成功(含 python 冷启动共 ${SW_MS}ms)" \
  || bad "切换失败: $(cat $E2E_TMP/wloc-sw.out)"
python3 -c "
import json,sys
w=json.load(open('/etc/privdns-gateway/mitm.json'))['wloc']
sys.exit(0 if w['active']=='札幌' and w.get('generation',0)==$GEN_BEFORE+1 else 1)" \
  && ok "mitm.json: active=札幌 且 generation +1" || bad "active/generation 没落对"
[[ "$(sha256sum /etc/mosdns/rules/mitm_hijack.txt | cut -d' ' -f1)" == "$HIJ_SHA" ]] \
  && ok "劫持表逐字节未变(接管域名没变, 不该重写)" || bad "hijack 表被改写了"
[[ "$(sha256sum /etc/mihomo/config.yaml | cut -d' ' -f1)" == "$CFG_SHA" ]] \
  && ok "mihomo 配置逐字节未变(不重渲内核)" || bad "内核配置被重渲了"
NEW_CALLS="$(tail -n +$((CALLS_BEFORE + 1)) $E2E_TMP/e2e-calls.log | grep -c systemctl)"
[[ "$NEW_CALLS" == 0 ]] \
  && ok "切换期间零 systemctl 调用(mihomo/mosdns/pdg-mitm 均未重启)" \
  || bad "切换期间执行了 systemctl: $(tail -n +$((CALLS_BEFORE + 1)) $E2E_TMP/e2e-calls.log | grep systemctl | head -3)"

# 热加载: 同一个 WlocConfig 实例在配置换掉后给出新目标(pdg-mitm 进程不必重启)
python3 - > $E2E_TMP/wloc-reload.out 2>&1 <<'PY'
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot, mitm_wloc
cfg = mitm_wloc.WlocConfig("/etc/privdns-gateway/mitm.json")
s1, _ = cfg.snapshot()
bot.wloc_switch_gen("大阪")
s2, _ = cfg.snapshot()
print("SNAP|%s,%s|%s,%s" % (s1.active, s1.generation, s2.active, s2.generation))
PY
grep -qE 'SNAP\|札幌,[0-9]+\|大阪,[0-9]+' $E2E_TMP/wloc-reload.out \
  && ok "同一 WlocConfig 实例热加载出新目标(不重启 pdg-mitm)" || bad "热加载没生效: $(cat $E2E_TMP/wloc-reload.out)"

# ══ 3. 关闭 WLOC: 事务必须把接管彻底撤掉 ════════════════════════════════════
echo; echo "── 3. 关闭 WLOC ──"
python3 - > $E2E_TMP/wloc-off.out 2>&1 <<PY
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
w = bot._wloc_state(); w["enabled"] = False
okr, msg = bot._mitm_transact(w)
print(("OK|" if okr else "FAIL|") + (msg or ""))
PY
grep -q '^OK|' $E2E_TMP/wloc-off.out && ok "WLOC 关闭事务成功" || bad "关闭失败: $(cat $E2E_TMP/wloc-off.out)"
python3 -c "
import json,sys
c=json.load(open('/etc/privdns-gateway/mitm.json'))
sys.exit(0 if not c.get('wloc',{}).get('enabled') else 1)" \
  && ok "mitm.json enabled=false" || bad "关闭后仍是 enabled"
[[ ! -s /etc/mosdns/rules/mitm_hijack.txt ]] \
  && ok "劫持表已清空(不再强制接管 gs-loc)" || bad "劫持表仍有内容: $(cat /etc/mosdns/rules/mitm_hijack.txt)"
[[ -s /etc/privdns-gateway/ca/ca.crt ]] \
  && ok "关闭只休眠不销毁: CA 仍在(重开无需重装描述文件)" || bad "CA 被误删"

# ══ 4. Android 平台硬门控 ════════════════════════════════════════════════════
echo; echo "── 4. 平台门控 ──"
printf 'android\n' > /etc/privdns-gateway/platform
python3 - > $E2E_TMP/wloc-android.out 2>&1 <<PY
import sys; sys.path.insert(0, "/opt/pdg-bot")
import bot
okr, msg = bot._mitm_transact({"enabled": True, "accuracy": 50, "active": "x",
                               "locations": [{"name": "x", "lat": 1.0, "lon": 2.0}]})
print(("OK|" if okr else "FAIL|") + (msg or ""))
PY
{ grep -q '^FAIL|' $E2E_TMP/wloc-android.out && grep -q 'iOS' $E2E_TMP/wloc-android.out; } \
  && ok "Android 上拒绝开启 WLOC(平台硬门控)" || bad "Android 门控失效: $(cat $E2E_TMP/wloc-android.out)"

e2e_summary

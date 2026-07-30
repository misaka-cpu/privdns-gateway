#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: TG Bot 的操作 × 分流结果。全程走 **bot 的真实代码**, 用**真 mosdns**看域名解析成
# 什么、用**真 mihomo**看规则有没有进运行配置。
#
# 与 e2e-exit-rule.sh 的分工: 那条验"加出口 / 加删单条规则"这一串本身; 这条验**几件事凑在
# 一起**时的结果 —— 明确代理优先级、劫持模式切换、WDA 开关、改判直连、DNS 上游改动, 两两
# 叠加之后分流还对不对。本项目查出来的 bug 几乎都在这种接缝上:
#   · 用户点名的域名被 geosite_cn 抢先判直连(v1.7.1 修);
#   · WDA 内联规则被 add_rule 当成普通 jp 规则并进去(v1.7.1 修);
#   · 迁移在 cmd_update 的锁里开事务自锁(v1.7.1 之后修);
# 每一个都是"单看一条路径全绿, 凑在一起就错"。
#
# 上游用 mock_dns 应答固定 IP —— "没被劫持"因此是**返回了 198.51.100.7** 这样的正面证据,
# 而不是"查不到"这种既可能是没劫持、也可能是上游挂了的模糊结果。
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
printf 'mihomo\n'  > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform

e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制(无网络?)"
e2e_fetch_mosdns || e2e_skip "取不到 mosdns 二进制"
command -v dig >/dev/null 2>&1 || e2e_skip "没有 dig"

UP=198.51.100.7          # mock 上游对 A 查询的固定应答 = "没被劫持, 拿到了真实解析"
# 端口被占着就说明上一轮的 mock 还活着 —— 那样"真实解析"的答案来自别人的进程, 这一轮验的
# 是什么就说不清了。宁可直接失败, 不要静默复用。
if timeout 2 python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try: s.bind(("127.0.0.1",15999))
except OSError: sys.exit(1)' ; then :; else
  bad "上游 mock 端口 15999 已被占用(上一轮残留?), 拒绝复用别人的应答"
  e2e_summary; exit 1
fi
python3 "$E2E_ROOT/tests/mock_dns.py" 15999 "$UP" &
MOCKPID=$!
e2e_kill_mock(){ kill "$MOCKPID" 2>/dev/null; }
e2e_add_exit_hook e2e_kill_mock
# 确认它真的在应答, 否则后面每一条"真实解析"的断言都会因为上游沉默而变成误判
for _i in $(seq 1 30); do
  [[ -n "$(dig +short +time=1 +tries=1 @127.0.0.1 -p 15999 up.probe A 2>/dev/null)" ]] && break
  sleep 0.1
done
[[ "$(dig +short +time=1 +tries=1 @127.0.0.1 -p 15999 up.probe A 2>/dev/null)" == "$UP" ]] \
  && ok "上游 mock 就绪(答 $UP)" || { bad "上游 mock 没起来, 后面的判据全不可信"; e2e_summary; exit 1; }

# 造分流现场: 上游 geosite 把整个 byte-test.example 归进 CN(复刻 .200 那次现场),
# 另有一个真被墙的域名与一个普通海外域名, 用来区分 all / gfw 两种模式。
{ echo "domain:baidu.com"; echo "domain:byte-test.example"; } > /etc/mosdns/rules/geosite_cn.txt
echo "domain:blocked.example"  > /etc/mosdns/rules/geosite_gfw.txt
echo "domain:oversea.example"  > '/etc/mosdns/rules/geosite_geolocation-!cn.txt'

reload(){ e2e_mosdns_stop; e2e_mosdns_start; }
q(){ e2e_q "$1"; }
mosdns_ok(){ [[ -n "$(q probe.ready)" || -z "$(q probe.ready)" ]]; }   # 起没起来看下面的断言

# 每一步之后都要复核的两件事: mihomo 配置能过校验, 且没有规则被静默丢弃。
mihomo_sane(){ # $1=场景名
  local out
  if ! out="$(mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml 2>&1)"; then
    bad "$1: mihomo -t 不过: $(tail -1 <<<"$out")"; return 1
  fi
  ok "$1: mihomo -t 通过"
}

botpy(){ python3 -; }        # 便于阅读: 下面所有 bot 操作都从 stdin 读脚本

# ══ 1. 明确代理优先于 geosite_cn(真装机形态 + bot 的写入路径)═══════════════════
echo; echo "── 1. 点名指到出口的域名, 不该被 geosite_cn 抢先判直连 ──"
botpy > /tmp/e2e-bs1.out 2>&1 <<'PY'
import base64, sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
ssb = base64.b64encode(b"aes-128-gcm:secret123").decode().rstrip("=")
ob = bot.parse_link("ss://%s@5.6.7.8:8388#e-ss" % ssb)
def mod(c, ob=ob):
    c["outbounds"] = [o for o in c["outbounds"] if o.get("tag") != ob["tag"]]
    c["outbounds"].append(ob)
okk, msg = bot.apply_sb(mod)
print("ADD_EXIT", okk, msg)
okk, msg = bot.add_rule("perfops2.byte-test.example", "e-ss")
print("ADD_RULE", okk, msg)
PY
grep -q "^ADD_EXIT True" /tmp/e2e-bs1.out && ok "加落地出口 e-ss" || bad "加出口失败: $(head -2 /tmp/e2e-bs1.out)"
grep -q "^ADD_RULE True" /tmp/e2e-bs1.out && ok "把 perfops2.byte-test.example 指到 e-ss" \
  || bad "加规则失败: $(grep ADD_RULE /tmp/e2e-bs1.out)"
grep -q 'perfops2.byte-test.example' /etc/mosdns/rules/custom_hijack.txt \
  && ok "域名进了 custom_hijack.txt(不劫持=规则是死的)" || bad "劫持表里没有它"
mihomo_sane "1"
grep -q 'DOMAIN-SUFFIX,perfops2.byte-test.example,e-ss' /etc/mihomo/config.yaml \
  && ok "mihomo 运行配置里有指向 e-ss 的规则" || bad "mihomo 里没渲染出这条规则"

reload
[[ "$(q perfops2.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "真 mosdns: 点名域名 → 网关 $E2E_SIP(尽管上游把整站判成 CN)" \
  || bad "点名域名 → $(q perfops2.byte-test.example)(期望 $E2E_SIP)"
[[ "$(q perfops.byte-test.example)" == "$UP" ]] \
  && ok "同 zone 未点名的兄弟域名 → 真实解析 $UP(定向, 没把整站劫了)" \
  || bad "兄弟域名 → $(q perfops.byte-test.example)(期望 $UP)"
[[ "$(q www.baidu.com)" == "$UP" ]] \
  && ok "普通国内域名 → 真实解析(不退化)" || bad "国内域名 → $(q www.baidu.com)"

# ══ 2. 劫持模式 all ↔ gfw 切换不能把明确代理弄丢 ═══════════════════════════════
echo; echo "── 2. hijack-mode 切换后, 明确代理仍要优先 ──"
epline(){ grep -n 'qname \$explicit_proxy' /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }
cnline(){ grep -n 'qname \$geosite_cn'     /etc/mosdns/config.yaml | head -1 | cut -d: -f1; }

bash /usr/local/bin/pdg hijack-mode gfw >/tmp/e2e-hm.log 2>&1
rc=$?
[[ "$rc" == 0 ]] && ok "切到 gfw 模式" || bad "切 gfw 失败(rc=$rc): $(tail -2 /tmp/e2e-hm.log)"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "gfw: explicit_proxy($EP) 仍在 geosite_cn($CN) 之前" || bad "gfw 切换弄乱了顺序: $EP / $CN"
[[ "$(grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml)" == 2 ]] \
  && ok "gfw: 劫持门已装上" || bad "gfw: 劫持门数量 $(grep -c '!qname \$hijack_set' /etc/mosdns/config.yaml)"
reload
[[ "$(q perfops2.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "gfw: 点名域名仍进网关" || bad "gfw: 点名域名 → $(q perfops2.byte-test.example)"
[[ "$(q blocked.example)" == "$E2E_SIP" ]] \
  && ok "gfw: 被墙域名 → 网关" || bad "gfw: 被墙域名 → $(q blocked.example)"
[[ "$(q plain.example)" == "$UP" ]] \
  && ok "gfw: 非墙海外域名 → 真实解析(SSH/直连不被劫)" || bad "gfw: 非墙域名 → $(q plain.example)"

bash /usr/local/bin/pdg hijack-mode all >/tmp/e2e-hm2.log 2>&1
rc=$?
[[ "$rc" == 0 ]] && ok "切回 all 模式" || bad "切回 all 失败(rc=$rc): $(tail -2 /tmp/e2e-hm2.log)"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "all: explicit_proxy($EP) 仍在 geosite_cn($CN) 之前" || bad "all 切换弄乱了顺序: $EP / $CN"
reload
[[ "$(q perfops2.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "all: 点名域名仍进网关" || bad "all: 点名域名 → $(q perfops2.byte-test.example)"
[[ "$(q oversea.example)" == "$E2E_SIP" ]] \
  && ok "all: 策展分类内的海外域名 → 网关(原语义不变)" || bad "all: 海外域名 → $(q oversea.example)"

# ══ 3. 规则集劫持槽位(ruleset_hijack.txt)的语义 ════════════════════════════════
echo; echo "── 3. ruleset_hijack.txt: 写进去就劫持, 不写就不劫持 ──"
[[ -f /etc/mosdns/rules/ruleset_hijack.txt ]] \
  && ok "装机建出了 ruleset_hijack.txt" || bad "缺 ruleset_hijack.txt"
[[ "$(q rs.byte-test.example)" == "$UP" ]] \
  && ok "没写进去的规则集域名 → 真实解析(与 custom_hijack 无关)" || bad "→ $(q rs.byte-test.example)"
echo "domain:rs.byte-test.example" > /etc/mosdns/rules/ruleset_hijack.txt
reload
[[ "$(q rs.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "写进 ruleset_hijack.txt 后 → 网关(优先级与 custom_hijack 相同)" \
  || bad "写了仍不劫持 → $(q rs.byte-test.example)"
: > /etc/mosdns/rules/ruleset_hijack.txt

# ══ 4. 改判直连: 必须同时撤掉旧的劫持记录 ══════════════════════════════════════
echo; echo "── 4. 把同一个域名改判直连 ──"
botpy > /tmp/e2e-bs4.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
okk, msg = bot.add_rule("perfops2.byte-test.example", "direct")
print("TO_DIRECT", okk, msg)
print("IN_HIJACK", "perfops2.byte-test.example" in bot._read_hijack())
print("IN_DIRECT", "perfops2.byte-test.example" in bot._read_direct())
PY
grep -q "^TO_DIRECT True" /tmp/e2e-bs4.out && ok "改判直连成功" || bad "$(grep TO_DIRECT /tmp/e2e-bs4.out)"
grep -q "^IN_HIJACK False" /tmp/e2e-bs4.out && ok "旧的劫持记录被清掉" || bad "劫持记录还在"
grep -q "^IN_DIRECT True" /tmp/e2e-bs4.out && ok "进了直连表" || bad "没进直连表"
reload
[[ "$(q perfops2.byte-test.example)" == "$UP" ]] \
  && ok "真 mosdns: 改判直连后回到真实解析" || bad "改直连后仍被劫持 → $(q perfops2.byte-test.example)"

# ══ 5. WDA 开关 × 加普通分流规则(真形态)═══════════════════════════════════════
echo; echo "── 5. WDA 开着时加一条普通 jp 分流 ──"
botpy > /tmp/e2e-bs5.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
# WDA 的前置检查要连解锁 DNS —— 沙箱里没有, 打桩掉。被测的是开关之后 model 与
# unlock.txt 的状态, 不是"能不能探到中继"。
bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda d: (True, "")
JP = {"type": "shadowsocks", "tag": "jp", "server": "9.9.9.9", "server_port": 8388,
      "method": "aes-128-gcm", "password": "x"}
if not any(o.get("tag") == "jp" for o in bot.load()["outbounds"]):
    okk, msg = bot.apply_sb(lambda c: c["outbounds"].append(dict(JP)))
    print("SEED_JP", okk, msg[:60])
okk, msg = bot.set_wda_mode(True); print("WDA_ON", okk, msg[:40])
print("WDA_STATE_1", bot._wda_on())
okk, msg = bot.add_rule("mine.example", "jp"); print("ADD_JP", okk, msg)
print("WDA_STATE_2", bot._wda_on())
wda = [r for r in bot.load()["route"]["rules"]
       if r.get("outbound") == "jp" and len(r.get("domain_suffix") or []) > 10]
print("WDA_RULE_LEN", len(wda), len(wda[0]["domain_suffix"]) if wda else -1)
print("MINE_IN_WDA", bool(wda) and "mine.example" in wda[0]["domain_suffix"])
print("DELETABLE_HAS_WDA", any(d in bot.WDA_DOMAINS for d, _ in bot.deletable_domains()))
print("DELETABLE_HAS_MINE", any(d == "mine.example" for d, _ in bot.deletable_domains()))
okk, msg = bot.set_wda_mode(False); print("WDA_OFF", okk, msg[:40])
print("WDA_STATE_3", bot._wda_on())
print("MINE_KEPT", any("mine.example" in (r.get("domain_suffix") or [])
                       for r in bot.load()["route"]["rules"]))
print("NETFLIX_GONE", not any("netflix.com" in (r.get("domain_suffix") or [])
                              for r in bot.load()["route"]["rules"] if r.get("outbound") == "jp"))
PY
g(){ grep -q "^$1" /tmp/e2e-bs5.out; }
g "WDA_ON True"           && ok "开启 WDA" || bad "开 WDA 失败: $(grep WDA_ON /tmp/e2e-bs5.out)"
g "WDA_STATE_1 True"      && ok "开启后状态为真" || bad "开启后状态不对"
g "ADD_JP True"           && ok "加普通 jp 分流" || bad "$(grep ADD_JP /tmp/e2e-bs5.out)"
g "MINE_IN_WDA False"     && ok "用户域名没有被并进 WDA 规则" || bad "用户域名被并进 WDA 规则了"
grep -qE "^WDA_RULE_LEN 1 [0-9]+" /tmp/e2e-bs5.out \
  && ok "WDA 规则仍是单独一条(域名数 $(awk '/^WDA_RULE_LEN/{print $3}' /tmp/e2e-bs5.out))" \
  || bad "WDA 规则数量不对: $(grep WDA_RULE_LEN /tmp/e2e-bs5.out)"
g "WDA_STATE_2 True"      && ok "加完普通规则后 WDA 状态仍为真(面板不会显示成落地出口)" \
                          || bad "加完普通规则后 WDA 状态漂了"
g "DELETABLE_HAS_WDA False" && ok "删规则键盘不列 WDA 域名" || bad "删规则键盘列出了 WDA 域名"
g "DELETABLE_HAS_MINE True" && ok "用户自己的域名仍可删" || bad "用户域名不在可删列表里"
g "WDA_OFF True"          && ok "关闭 WDA" || bad "关 WDA 失败"
g "WDA_STATE_3 False"     && ok "关闭后状态为假" || bad "关不掉"
g "NETFLIX_GONE True"     && ok "关闭后 WDA 域名不再指向 jp" || bad "关闭后 WDA 域名还在"
g "MINE_KEPT True"        && ok "关闭 WDA 没有误删用户自己的 jp 规则" || bad "用户规则被误删"
[[ -e /etc/sing-box/rs/unlock.json ]] && bad "遗留 unlock.json 没被清掉" || ok "没有 unlock.json 残留"
grep -q "RULE-SET,unlock" /etc/mihomo/config.yaml && bad "mihomo 里出现了 RULE-SET,unlock" \
  || ok "mihomo 里没有 RULE-SET,unlock"
mihomo_sane "5"

# ══ 6. 改 DNS 上游之后, 明确代理结构不能被冲掉 ═════════════════════════════════
echo; echo "── 6. 改 DNS 上游 ──"
botpy > /tmp/e2e-bs6.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
okk, msg = bot.set_mosdns_upstream("local", ["udp://127.0.0.1:15999"])
print("UPSTREAM", okk, msg[:60])
PY
grep -q "^UPSTREAM True" /tmp/e2e-bs6.out && ok "改 local 上游成功" \
  || bad "改上游失败: $(grep UPSTREAM /tmp/e2e-bs6.out)"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "改上游后 explicit_proxy($EP) 仍在 geosite_cn($CN) 之前" || bad "改上游冲掉了结构: $EP / $CN"
grep -q 'tag: explicit_proxy$' /etc/mosdns/config.yaml && ok "明确代理域名集仍在" || bad "域名集没了"
reload
botpy > /dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot.add_rule("again.byte-test.example", "e-ss")
PY
reload
[[ "$(q again.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "改上游之后新加的点名规则照样生效" || bad "→ $(q again.byte-test.example)"


# ══ 8. 更狠的交叉: 出口改名 / 删出口 / WDA 域名改判直连 / WDA×劫持模式 ═══════════
echo; echo "── 8. 容易出错的几种叠加 ──"

# 8a. 出口改名: 指向它的分流规则、劫持表都得跟着走, 否则规则指向一个不存在的出口
botpy > /tmp/e2e-bs8a.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot.add_rule("renametest.example", "e-ss")
okk, msg = bot.rename_exit("e-ss", "e-ss2") if hasattr(bot, "rename_exit") else (None, "no-fn")
print("RENAME", okk, str(msg)[:60])
c = bot.load()
tags = [o.get("tag") for o in c["outbounds"]]
print("TAGS", tags)
dangling = [r.get("outbound") for r in c["route"]["rules"]
            if r.get("outbound") and r.get("outbound") not in tags + ["direct"]]
print("DANGLING", dangling)
print("HIJACK_KEPT", "renametest.example" in bot._read_hijack())
PY
if grep -q "^RENAME None" /tmp/e2e-bs8a.out; then
  echo "  [--] bot 没有 rename_exit, 跳过改名(由 test-exit-rename.py 覆盖)"
else
  grep -q "^RENAME True" /tmp/e2e-bs8a.out && ok "8a 出口改名成功" || bad "8a 改名失败: $(grep RENAME /tmp/e2e-bs8a.out)"
  grep -q "^DANGLING \[\]" /tmp/e2e-bs8a.out \
    && ok "8a 改名后没有指向不存在出口的悬空规则" || bad "8a 悬空规则: $(grep DANGLING /tmp/e2e-bs8a.out)"
  grep -q "^HIJACK_KEPT True" /tmp/e2e-bs8a.out \
    && ok "8a 改名后劫持表仍收录该域名(否则规则变成死的)" || bad "8a 改名把劫持表丢了"
  mihomo_sane "8a"
fi

# 8b. WDA 开着时把 WDA 里的域名改判直连 —— 两个意图直接冲突, 结果必须可解释
echo
botpy > /tmp/e2e-bs8b.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda d: (True, "")
bot.set_wda_mode(True)
okk, msg = bot.add_rule("netflix.com", "direct")
print("NF_DIRECT", okk, str(msg)[:60])
print("WDA_STILL_ON", bot._wda_on())
print("NF_IN_DIRECT", "netflix.com" in bot._read_direct())
print("NF_IN_WDA_RULE", any("netflix.com" in (r.get("domain_suffix") or [])
                            for r in bot.load()["route"]["rules"] if r.get("outbound") == "jp"))
PY
grep -q "^NF_DIRECT True" /tmp/e2e-bs8b.out && ok "8b 把 WDA 域名改判直连: 操作被接受" \
  || ok "8b 把 WDA 域名改判直连: 被拒绝($(grep NF_DIRECT /tmp/e2e-bs8b.out | cut -d' ' -f3-))"
reload
NFANS="$(q netflix.com)"
if grep -q "^NF_IN_DIRECT True" /tmp/e2e-bs8b.out; then
  # 直连表属于 geosite_cn 集; WDA 域名不在 custom_hijack 里, 所以 DNS 会返真实地址,
  # 流量不进内核 —— 此时 model 里那条 WDA 规则对它就是死的。这是可解释的语义, 但
  # bot 面板仍会显示"WDA 开启", 用户看不出这个域名已经被自己排除掉了。
  [[ "$NFANS" == "$UP" ]] \
    && ok "8b DNS 按直连意图返回真实地址(WDA 对该域名不再生效 —— 语义如此)" \
    || bad "8b 改判直连后仍被劫持 → $NFANS"
  grep -q "^WDA_STILL_ON True" /tmp/e2e-bs8b.out \
    && echo "  [注意] 此时面板仍显示 WDA 开启, 但 netflix.com 已被排除在外 —— 界面上看不出来"
else
  ok "8b bot 拒绝了冲突操作(WDA 域名不允许单独改直连)"
fi
# 收拾干净, 不影响后面
botpy > /dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda d: (True, "")
bot.del_rule("netflix.com")
bot.set_wda_mode(False)
PY

# 8c. WDA 开着时切劫持模式 —— 两套都会改 model / mosdns, 不能互相踩
echo
botpy > /dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda d: (True, "")
bot.set_wda_mode(True)
PY
bash /usr/local/bin/pdg hijack-mode gfw >/tmp/e2e-hm3.log 2>&1
botpy > /tmp/e2e-bs8c.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
print("WDA_AFTER_MODE", bot._wda_on())
wda = [r for r in bot.load()["route"]["rules"]
       if r.get("outbound") == "jp" and len(r.get("domain_suffix") or []) > 10]
print("WDA_RULES", len(wda))
PY
grep -q "^WDA_AFTER_MODE True" /tmp/e2e-bs8c.out \
  && ok "8c 切劫持模式后 WDA 状态未被冲掉" || bad "8c 切模式把 WDA 弄丢了"
grep -q "^WDA_RULES 1" /tmp/e2e-bs8c.out \
  && ok "8c 切模式后 WDA 规则仍是一条(没被复制)" || bad "8c WDA 规则数: $(grep WDA_RULES /tmp/e2e-bs8c.out)"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "8c WDA 开着切模式, 明确代理顺序仍对" || bad "8c 顺序乱了: $EP / $CN"
mihomo_sane "8c"
bash /usr/local/bin/pdg hijack-mode all >/dev/null 2>&1
botpy > /dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot._wda_authorized = lambda: True
bot._unlock_precheck = lambda d: (True, "")
bot.set_wda_mode(False)
PY

# 8d. 删掉一个还有分流规则指向它的出口(走 TG 回调 delx:, 那才是真路径)
echo
botpy > /tmp/e2e-bs8d.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot.edit = lambda *a, **k: None          # 不出网
bot.send = lambda *a, **k: None
bot.send_plain = lambda *a, **k: None
bot.add_rule("orphan.example", "e-ss2")
before = [o.get("tag") for o in bot.load()["outbounds"]]
print("BEFORE_TAGS", before)
bot.handle_cb(1, 9, "delx:e-ss2")        # = 用户在「出口 → 删除」里点了 e-ss2
c = bot.load()
tags = [o.get("tag") for o in c["outbounds"]]
print("AFTER_TAGS", tags)
print("DANGLING", [r.get("outbound") for r in c["route"]["rules"]
                   if r.get("outbound") and r.get("outbound") not in tags + ["direct"]])
tgt = [r.get("outbound") for r in c["route"]["rules"]
       if "orphan.example" in (r.get("domain_suffix") or [])]
print("ORPHAN_TARGET", tgt)
print("HIJACK_LEFT", "orphan.example" in bot._read_hijack())
print("FINAL", c["route"].get("final"))
PY
if grep -q "^AFTER_TAGS" /tmp/e2e-bs8d.out; then
  grep -q "^DANGLING \[\]" /tmp/e2e-bs8d.out \
    && ok "8d 删出口后没有指向不存在出口的悬空规则" \
    || bad "8d 悬空规则: $(grep DANGLING /tmp/e2e-bs8d.out)"
  echo "  [信息] 原本指向被删出口的规则改指到: $(awk '/^ORPHAN_TARGET/{print $2}' /tmp/e2e-bs8d.out)" \
       "(final=$(awk '/^FINAL/{print $2}' /tmp/e2e-bs8d.out))"
  # 规则被改指到 final 而不是删除, 所以劫持表里留着该域名是**一致**的 —— 但如果 final 是
  # direct, 这个域名就变成"DNS 劫到网关 + 内核判直连", 与用户在直连表里看到的不是一回事。
  if grep -q "^HIJACK_LEFT True" /tmp/e2e-bs8d.out; then
    if grep -q "^ORPHAN_TARGET \['direct'\]" /tmp/e2e-bs8d.out; then
      echo "  [注意] 出口被删 → 规则改判 direct, 但域名仍留在 custom_hijack.txt:"
      echo "         DNS 仍把它劫到网关, 由网关本机直出; 而 bot 的「直连表」里看不到它。"
    else
      ok "8d 规则改指到仍存在的出口, 劫持表保留该域名(一致)"
    fi
  else
    ok "8d 劫持表已同步清理"
  fi
  mihomo_sane "8d"
else
  bad "8d 删出口路径没跑起来: $(head -3 /tmp/e2e-bs8d.out)"
fi

# 8e. 规则集: 从本地 HTTP 源真加一个 .list, 看它进不进 mihomo 运行配置
echo
python3 - > /tmp/e2e-rs-srv.log 2>&1 <<'PY' &
import http.server, socketserver, threading
BODY = ("DOMAIN-SUFFIX,rsdemo.example\n"
        "DOMAIN-SUFFIX,rsdemo2.example\n").encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(BODY)))
        self.end_headers(); self.wfile.write(BODY)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 15801), H) as s:
    s.serve_forever()
PY
RSPID=$!
e2e_kill_rs(){ kill "$RSPID" 2>/dev/null; }
e2e_add_exit_hook e2e_kill_rs
# 就绪探测不用 curl —— 沙箱里的 curl 是桩(装机用例会造一个假的), 它"成功"说明不了服务起没起。
RSUP=0
for _i in $(seq 1 60); do
  if python3 -c 'import urllib.request,sys
try: urllib.request.urlopen("http://127.0.0.1:15801/probe.list", timeout=1).read()
except Exception: sys.exit(1)' 2>/dev/null; then RSUP=1; break; fi
  sleep 0.2
done
[[ "$RSUP" == 1 ]] && ok "8e 本地规则集源已就绪" \
  || bad "8e 本地规则集源没起来: $(tail -3 /tmp/e2e-rs-srv.log 2>/dev/null | tr '\n' ' ')"
botpy > /tmp/e2e-bs8e.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
# 8d 刚把 e-ss2 删了, 这里用现存的第一个出口 —— 写死出口名会让本节随上一节的改动而崩,
# 而那属于夹具坏了, 不是规则集本身有问题。
tgt = [t for t in bot.exit_tags(bot.load()) if t != "direct"][0]
okk, msg = bot.add_ruleset("http://127.0.0.1:15801/demo.list", tgt, "演示")
print("ADD_RS", okk, str(msg)[:80])
print("RS_META", list(bot._rs_meta().keys()))
PY
if grep -q "^ADD_RS True" /tmp/e2e-bs8e.out; then
  ok "8e 规则集加入成功"
  NAME="$(python3 -c "
import re,sys
m=re.search(r\"^RS_META \\[(.*)\\]\", open('/tmp/e2e-bs8e.out').read(), re.M)
print((m.group(1).split(',')[0].strip().strip(chr(39))) if m else '')")"
  grep -q "RULE-SET,$NAME" /etc/mihomo/config.yaml \
    && ok "8e 规则集渲染进 mihomo 运行配置(RULE-SET,$NAME)" \
    || bad "8e 规则集没进运行配置(收下了却不生效)"
  grep -q "rule-providers" /etc/mihomo/config.yaml \
    && ok "8e mihomo 有 rule-providers 段" || bad "8e 缺 rule-providers"
  mihomo_sane "8e"
  # 加规则集时, 域名要**自动**写进 mosdns 的派生劫持表。gfw 模式是判据所在: all 模式下
  # "不是国内就劫持"顺带兜住了, 看不出差别; gfw 模式下劫持集只有被墙域名, 派生表不写就等于
  # 规则集里的域名拿真实 IP、手机直连, 那条 RULE-SET 规则永远匹配不到。
  grep -q "^domain:rsdemo.example$" /etc/mosdns/rules/ruleset_hijack.txt \
    && ok "8e 规则集的域名自动进了派生劫持表" \
    || bad "8e 派生劫持表里没有它: $(head -5 /etc/mosdns/rules/ruleset_hijack.txt | tr '\n' '|')"
  grep -q "规则集派生劫持表" /etc/mosdns/rules/ruleset_hijack.txt \
    && ok "8e 派生表带了来源说明(手改会被覆盖)" || bad "8e 派生表没有表头"
  reload
  [[ "$(q rsdemo.example)" == "$E2E_SIP" ]] \
    && ok "8e all 模式: 规则集域名进网关" || bad "8e all 模式 → $(q rsdemo.example)"
  bash /usr/local/bin/pdg hijack-mode gfw >/dev/null 2>&1; reload
  [[ "$(q rsdemo.example)" == "$E2E_SIP" ]] \
    && ok "8e **gfw 模式: 规则集域名同样进网关(本轮修的就是这个)**" \
    || bad "8e gfw 模式下规则集仍是死规则 → $(q rsdemo.example)"
  [[ "$(q rsdemo2.example)" == "$E2E_SIP" ]] \
    && ok "8e gfw 模式: 同一规则集的第二个域名也进网关" || bad "8e 第二个域名 → $(q rsdemo2.example)"
  [[ "$(q notinrs.example)" == "$UP" ]] \
    && ok "8e 不在规则集里的海外域名仍走真实解析(没有殃及无辜)" || bad "8e → $(q notinrs.example)"
  # 删掉规则集 → 派生表要跟着收回, 不留死域名
  botpy > /tmp/e2e-bs8f.out 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
name = sorted(bot._rs_meta().keys())[0]
okk, msg = bot.del_ruleset(name)
print("DEL_RS", okk, str(msg)[:60])
PY
  grep -q "^DEL_RS True" /tmp/e2e-bs8f.out && ok "8e 删除规则集成功" || bad "8e $(grep DEL_RS /tmp/e2e-bs8f.out)"
  grep -q "rsdemo.example" /etc/mosdns/rules/ruleset_hijack.txt \
    && bad "8e 删了规则集, 派生表里还留着它的域名" || ok "8e 删除后派生表同步收回"
  reload
  [[ "$(q rsdemo.example)" == "$UP" ]] \
    && ok "8e 删除后该域名回到真实解析" || bad "8e 删除后仍被劫持 → $(q rsdemo.example)"
  bash /usr/local/bin/pdg hijack-mode all >/dev/null 2>&1; reload
else
  bad "8e 规则集加入失败: $(grep ADD_RS /tmp/e2e-bs8e.out)"
  echo "  源服务日志: $(tail -3 /tmp/e2e-rs-srv.log 2>/dev/null | tr '\n' ' ')"
fi


# ══ 9. 恢复旧版备份不能把分流优先级悄悄退回去 ═════════════════════════════════
# 备份里的 mosdns 配置是**原样**写回去的。一份 v1.7.0 时代的备份没有 explicit_proxy,
# 恢复完用户点名指到出口的域名就又会被上游 geosite 抢先判直连 —— 而恢复本身报的是
# "✅ 已恢复", 一处报错都没有, 只有事后跑 doctor 才看得出来。这正是 v1.7.1 要消灭的那类
# 静默退化, 不能在"恢复备份"这条路上又漏回去。
echo; echo "── 9. 从 v1.7.0 时代的备份恢复 ──"
cp /etc/mosdns/config.yaml /tmp/e2e-oldmos.yaml
python3 "$E2E_ROOT/tests/helpers/strip-explicit-proxy.py" /tmp/e2e-oldmos.yaml \
  && ok "9 造出一份不含明确代理的旧备份" || bad "9 夹具没造对"
botpy > /tmp/e2e-bs9.out 2>&1 <<'PY'
import io, sys, tarfile
sys.path.insert(0, "/opt/pdg-bot")
import bot
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as t:
    for rel, path in (("etc/mosdns/config.yaml", "/tmp/e2e-oldmos.yaml"),
                      ("etc/sing-box/config.json", "/etc/sing-box/config.json")):
        data = open(path, "rb").read()
        info = tarfile.TarInfo(rel); info.size = len(data); info.mode = 0o644
        t.addfile(info, io.BytesIO(data))
okk, msg = bot.restore_from(buf.getvalue())
print("RESTORE", okk)
print("MSG", str(msg).replace("\n", " | ")[:200])
PY
grep -q "^RESTORE True" /tmp/e2e-bs9.out && ok "9 恢复成功" || bad "9 恢复失败: $(grep MSG /tmp/e2e-bs9.out)"
[[ "$(grep -c 'qname \$explicit_proxy' /etc/mosdns/config.yaml)" == 1 ]] \
  && ok "9 恢复后明确代理这一层被补了回来(旧备份没把它带走)" \
  || bad "9 恢复把明确代理弄丢了 —— 分流会静默退回旧行为"
EP="$(epline)"; CN="$(cnline)"
{ [[ -n "$EP" && -n "$CN" ]] && [[ "$EP" -lt "$CN" ]]; } \
  && ok "9 补回来的位置也对(explicit_proxy $EP < geosite_cn $CN)" || bad "9 位置不对: $EP / $CN"
grep -q "旧版本" /tmp/e2e-bs9.out \
  && ok "9 恢复结果里如实告诉了用户这件事" || bad "9 悄悄补的, 用户不知道"
reload
botpy > /dev/null 2>&1 <<'PY'
import sys
sys.path.insert(0, "/opt/pdg-bot")
import bot
bot.add_rule("afterrestore.byte-test.example", "jp")
PY
reload
[[ "$(q afterrestore.byte-test.example)" == "$E2E_SIP" ]] \
  && ok "9 恢复之后新加的点名规则照样生效(真 mosdns)" \
  || bad "9 恢复之后点名规则失效 → $(q afterrestore.byte-test.example)"
python3 /opt/pdg-bot/doctor.py --json > /tmp/e2e-doc9.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" /tmp/e2e-doc9.json ok \
  && ok "9 恢复后 doctor 仍判 ok" || bad "9 恢复后 doctor: $(head -c 160 /tmp/e2e-doc9.json)"

# ══ 7. doctor 对最终状态的判断 ═════════════════════════════════════════════════
echo; echo "── 7. doctor ──"
python3 /opt/pdg-bot/doctor.py --json > /tmp/e2e-doc.json 2>/dev/null
python3 "$E2E_ROOT/tests/helpers/doctor-explicit-proxy.py" /tmp/e2e-doc.json ok \
  && ok "doctor: 明确代理优先级 = ok" || bad "doctor 判定不对: $(head -c 200 /tmp/e2e-doc.json)"

e2e_mosdns_stop
e2e_summary

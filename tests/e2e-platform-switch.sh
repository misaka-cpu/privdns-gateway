#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: `pdg platform <ios|android>` 必须是**完整事务**。
#
# 以前它只写个平台标记就 run_all_migrations, 且恒返回 0:
#   · Android→iOS 之后缺 pdg-probe81.service / probe81.py / pdg-dot.mobileconfig.tmpl,
#     doctor 报 "pdg-probe81 未运行 / :81 无响应";
#   · iOS→Android 之后 nft prerouting 里 GMS 5228-5230 回不来, doctor 报 GMS 缺失;
#   · WLOC 开着时切 Android, mitm.json 关了、hijack 清了, 但 mihomo 配置里 MITM-OUT 还在;
#   · 以上全都照样打印"平台已确认"并返回 0。
#
# 本用例在真实装机现场上跑真实命令, 断言组件、防火墙、内核配置三处都跟着平台走, 失败要回滚,
# 二次执行幂等。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

# 假 systemd 没有真实的重启动力学, 稳定性观察窗口取 1 个采样即可(不是放宽断言: is-active 与
# NRestarts 照常检查, 只是不为一个桩白等 3 秒 × 服务数 × 切换次数)。
export PDG_STABLE_SAMPLES=1

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft
printf 'mihomo\n' > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform
printf 'PDG_PLATFORM=android\n' > /etc/privdns-gateway/profile.env
# 真实装好的机器上这三个 unit 一定在(切平台的校验门会逐个查它们是否稳定运行)
# unit 取真实形态: 幂等迁移按 unit 内容判断要不要补 SAFE_PATHS, 占位 unit 会让它每次重跑
# shellcheck source=lib/units.sh
source "$E2E_ROOT/lib/units.sh"
pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service
for u in pdg-bot mosdns; do
  printf '[Unit]\nDescription=%s\n[Service]\nExecStart=/usr/local/bin/%s\n' "$u" "$u" \
    > "/etc/systemd/system/$u.service"
done
for u in pdg-bot mosdns mihomo; do echo 1 > "$E2E_TMP/e2e-svc/$u.ac"; echo 1 > "$E2E_TMP/e2e-svc/$u.en"; done
e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"

# nft 桩: 维护一份"已加载 ruleset", 好验证运行规则真的跟着变。
# 走 e2e-lib.sh 的唯一实现 —— 原来这里是私有简化桩, **没有 `-j` 分支**, 被测路径
# 一旦走到 nftlive 就会拿到一个空表, 而那不会报错, 只会让断言读到"看着健康"的空壳。
e2e_write_nft_stub
nft -f /etc/nftables.conf

# WLOC 退役后这三样在**两个平台上**都不该存在(对应 pdg.sh 的 _PLAT_RETIRED)。
RETIRED=(/opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py /etc/systemd/system/pdg-mitm.service)

# 造一台"老版开过 WLOC"的机器的**残留前像**。
# 只写制品本身(unit 文件 + 两个模块 + 一份带地点的 mitm.json + 一张 CA), 与
# tests/test-wloc-retire-migration.sh 造旧态的做法一致 —— 不调用新版已删除的开启入口,
# 也不恢复任何签发能力。前像是用来被**撤除**的, 造完立刻自检它确实存在。
seed_retired_residue(){
  install -d -m755 /opt/pdg-bot /etc/privdns-gateway/ca
  printf '[Unit]\nDescription=PDG MITM (retired)\n[Service]\nExecStart=/usr/bin/false\n' \
    > /etc/systemd/system/pdg-mitm.service
  printf '# retired module (pre-image only)\n' > /opt/pdg-bot/mitm_server.py
  printf '# retired module (pre-image only)\n' > /opt/pdg-bot/mitm_wloc.py
  printf '%s\n' '{"wloc":{"enabled":true,"accuracy":50,"active":"大阪","generation":1,"locations":[{"name":"大阪","lat":34.6937,"lon":135.5023}]}}' \
    > /etc/privdns-gateway/mitm.json
  printf -- '-----BEGIN CERTIFICATE-----\nretired-ca-material\n-----END CERTIFICATE-----\n' \
    > /etc/privdns-gateway/ca/ca.crt
  echo 1 > "$E2E_TMP/e2e-svc/pdg-mitm.ac"; echo 1 > "$E2E_TMP/e2e-svc/pdg-mitm.en"
}

gms_in_nft(){ grep -qE 'tcp dport [{][^}]*5228' /etc/nftables.conf; }
gms_in_ruleset(){ grep -qE 'tcp dport [{][^}]*5228' $E2E_TMP/e2e-nft-ruleset 2>/dev/null; }
mitm_out_in_core(){ grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null; }

# ══ 1. Android → iOS: 组件必须真部署 ═══════════════════════════════════════
echo "── 1. Android → iOS ──"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "切到 iOS 返回 0" || bad "1: rc=$rc: $(tail -5 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "platform 标记=ios" || bad "1b: 标记没改"
grep -q '^PDG_PLATFORM=ios$' /etc/privdns-gateway/profile.env \
  && ok "profile.env 的 PDG_PLATFORM 同步为 ios" || bad "1c: profile.env 没同步: $(cat /etc/privdns-gateway/profile.env)"
# iOS 必需件 = pdg.sh 的 _PLAT_IOS_REQUIRED 那四项 + 两个公共件。
# WLOC 退役后 mitm_server.py / mitm_wloc.py / pdg-mitm.service **不再是 iOS 组件**,
# 见 _PLAT_RETIRED: 它们在两个平台上都不该存在。
for f in /etc/systemd/system/pdg-probe81.service /opt/pdg-bot/probe81.py \
         /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/iosprofile.py \
         /opt/pdg-bot/iosstate.py /opt/pdg-bot/mitm_ca.py; do
  [[ -e "$f" ]] && ok "已部署 $(basename "$f")" || bad "1d: 缺 $f"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "pdg-probe81 已启用并运行" || bad "1e: probe81 未运行"
# 退役后的契约: 切 iOS **不再**安装、启动、启用 WLOC 专属执行模块与 pdg-mitm。
for f in "${RETIRED[@]}"; do
  [[ -e "$f" ]] && bad "1f: 切 iOS 又把已退役的 $f 装回来了" || ok "未安装已退役的 $(basename "$f")"
done
[[ "$(systemctl is-active pdg-mitm)" != active ]] \
  && ok "pdg-mitm 未运行(服务宿主已退役)" || bad "1f: pdg-mitm 竟然被起起来了"
gms_in_nft && bad "1g: iOS 的防火墙里仍有 GMS 5228-5230" || ok "iOS: 防火墙已无 GMS 5228-5230"

# ══ 2. 老版 WLOC 残留: 切平台必须撤除, 而且切回去也不复活 ═════════════════
# WLOC 已退役, 开启入口(bot._mitm_transact)随之删除 —— 本节不再"先开起来", 而是按
# 退役后真正要守的那条契约来: 一台老机器盘上可能还留着 MITM 宿主与 pdg-mitm 服务,
# **任一方向的平台切换都必须把它们撤掉**, 且旧 CA 与用户地点数据按保留策略不销毁。
echo; echo "── 2. 老版 WLOC 残留的撤除 ──"
seed_retired_residue
# 前像自检: 造不出来的话后面"已撤除"什么都证明不了。
_pre_ok=1
for f in "${RETIRED[@]}"; do [[ -e "$f" ]] || _pre_ok=0; done
[[ -s /etc/privdns-gateway/mitm.json && -s /etc/privdns-gateway/ca/ca.crt ]] || _pre_ok=0
[[ "$(systemctl is-active pdg-mitm)" == active ]] || _pre_ok=0
[[ "$_pre_ok" == 1 ]] && ok "前像就位: 三件退役制品在盘上, pdg-mitm 报 active, CA 与地点数据都在" \
  || bad "2: 残留前像没造出来, 这一节证明不了任何东西"

: > "$E2E_TMP/e2e-calls.log"
out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "带着残留切回 Android 返回 0" || bad "2b: rc=$rc: $(tail -5 <<<"$out")"
for f in "${RETIRED[@]}"; do
  [[ -e "$f" ]] && bad "2c: 切平台后仍残留 $f" || ok "已撤除 $(basename "$f")"
done
# "文件不在"还不够: 服务必须**真的停过**, 而且现在确实不在跑。
grep -qE 'disable --now pdg-mitm|stop pdg-mitm' "$E2E_TMP/e2e-calls.log" \
  && ok "确实对 pdg-mitm 发过 stop/disable(有调用记录)" || bad "2d: 没看到停服务的调用"
[[ "$(systemctl is-active pdg-mitm)" != active ]] \
  && ok "pdg-mitm 现在确实不在运行" || bad "2d: pdg-mitm 还活着"
# 保留策略: 旧 CA 与用户地点意图**不销毁**。
[[ -s /etc/privdns-gateway/ca/ca.crt ]] && ok "旧 CA 材料按保留策略留在盘上(不销毁)" || bad "2e: CA 被删了"
python3 -c "
import json,sys
c=json.load(open('/etc/privdns-gateway/mitm.json'))
locs=[l['name'] for l in c.get('wloc',{}).get('locations',[])]
sys.exit(0 if '大阪' in locs else 1)" \
  && ok "用户地点数据保留(撤除执行面不销毁用户意图)" || bad "2f: 地点数据被删了"
# 运行时接管面必须干净: 不再有 MITM 专属出站/路由, 共享劫持锚点保持休眠(空文件)。
mitm_out_in_core && bad "2g: mihomo 配置里仍有 MITM-OUT" || ok "内核配置里没有 MITM-OUT(渲染器不再产生)"
[[ -e /etc/mosdns/rules/mitm_hijack.txt && ! -s /etc/mosdns/rules/mitm_hijack.txt ]] \
  && ok "共享劫持锚点 mitm_hijack.txt 仍在且为空(休眠, 不是被删)" \
  || bad "2h: mitm_hijack.txt 状态不对: $(ls -l /etc/mosdns/rules/mitm_hijack.txt 2>&1 | tail -1)"

# 再来一次, 这回切**到 iOS** —— 退役必须与平台无关, 否则切一次平台就复活一次。
seed_retired_residue
: > "$E2E_TMP/e2e-calls.log"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "带着残留切到 iOS 也返回 0" || bad "2i: rc=$rc: $(tail -5 <<<"$out")"
_rev=0; for f in "${RETIRED[@]}"; do [[ -e "$f" ]] && _rev=1; done
[[ "$_rev" == 0 ]] && ok "切到 iOS 同样撤除干净(退役与平台无关, 不会复活)" \
  || bad "2j: 切回 iOS 让退役制品复活了"
[[ "$(systemctl is-active pdg-mitm)" != active ]] \
  && ok "切到 iOS 后 pdg-mitm 仍不在运行" || bad "2j: pdg-mitm 在 iOS 上又活了"
pdg platform android >/dev/null 2>&1     # 回到 android, 供下一节检查 GMS

# ══ 3. Android 侧的防火墙必须把 GMS 5228-5230 加回来 ═══════════════════════
echo; echo "── 3. Android 的 GMS 端口 ──"
gms_in_nft && ok "Android: 防火墙配置里有 GMS 5228-5230" || bad "3: GMS 没恢复: $(grep -n 'dport' /etc/nftables.conf | head -3)"
gms_in_ruleset && ok "Android: 运行中的 ruleset 也有 GMS(真的应用了)" || bad "3b: 运行规则里没有 GMS"
# 6.1B: probe81 已是 Android/iOS 公共件 —— 切到 Android **不许**把它清掉, 否则
# Android 少一个必需服务, 来回切平台也不幂等。只有真正 iOS 专属的才该被清。
for f in /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/mitm_ca.py; do
  [[ -e "$f" ]] && bad "3c: Android 上仍残留 iOS 专属件 $f" || ok "已移除 $(basename "$f")"
done
for f in /etc/systemd/system/pdg-probe81.service /opt/pdg-bot/probe81.py; do
  [[ -e "$f" ]] && ok "公共件 $(basename "$f") 仍在(切平台不该动它)" \
    || bad "3c: 公共件 $f 被平台切换删掉了"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "pdg-probe81 在 Android 上照常运行" || bad "3d: 公共件 probe81 被停了"

# ══ 4. 二次执行幂等 ════════════════════════════════════════════════════════
echo; echo "── 4. 二跑幂等 ──"
SHA_BEFORE="$(sha256sum /etc/nftables.conf /etc/mihomo/config.yaml | sha256sum)"
out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "重复切到同一平台仍返回 0" || bad "4: rc=$rc: $(tail -5 <<<"$out")"
[[ "$(sha256sum /etc/nftables.conf /etc/mihomo/config.yaml | sha256sum)" == "$SHA_BEFORE" ]] \
  && ok "二跑后防火墙与内核配置逐字节未变(幂等)" || bad "4b: 二跑改了东西"

# ══ 5. 失败必须回滚并返回非 0 ══════════════════════════════════════════════
# 注入: 让防火墙重建这一步失败(nft -c 判否), 现场必须整体回到 Android。
echo; echo "── 5. 失败回滚 ──"
NFT_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
cp /usr/local/bin/nft /usr/local/bin/nft.real
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
[ "$1" = "-c" ] && { echo "Error: 注入的校验失败" >&2; exit 1; }
exec /usr/local/bin/nft.real "$@"
S
chmod 755 /usr/local/bin/nft
out=$(pdg platform ios 2>&1); rc=$?
cp -f /usr/local/bin/nft.real /usr/local/bin/nft
[[ "$rc" != 0 ]] && ok "校验失败 → 返回非 0(不再谎报成功)" || bad "5: 竟然返回 0: $(tail -5 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == android ]] \
  && ok "失败后平台标记回到 android" || bad "5b: 平台标记停在 $(cat /etc/privdns-gateway/platform)"
grep -q '^PDG_PLATFORM=android$' /etc/privdns-gateway/profile.env \
  && ok "失败后 profile.env 也回到 android" || bad "5c: profile.env=$(grep PDG_PLATFORM /etc/privdns-gateway/profile.env)"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA" ]] \
  && ok "失败后防火墙配置逐字节未变" || bad "5d: 防火墙被改了"
grep -q '已恢复到原平台' <<<"$out" && ok "回滚有明确提示" || bad "5e: 没有回滚提示: $(tail -3 <<<"$out")"
# 平台专属文件必须一并回去 —— 否则平台标记明明回到 android, 盘上却留着半个 iOS 现场
for f in /opt/pdg-bot/pdg-dot.mobileconfig.tmpl /opt/pdg-bot/mitm_ca.py \
         /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py; do
  [[ -e "$f" ]] && bad "5f: 回滚后仍残留 $f(半个 iOS 现场)" || ok "回滚已清除 $(basename "$f")"
done
# 退役制品既不该被装上, 失败回滚也不该把它们"恢复"出来。
for f in "${RETIRED[@]}"; do
  [[ -e "$f" ]] && bad "5f: 回滚把已退役的 $f 弄回来了" || ok "回滚后没有已退役的 $(basename "$f")"
done
# 公共件不参与平台回滚: 它在 android 上本来就该有, 回滚把它删掉才是错的。
for f in /opt/pdg-bot/probe81.py /etc/systemd/system/pdg-probe81.service; do
  [[ -e "$f" ]] && ok "回滚保留了公共件 $(basename "$f")" || bad "5f: 回滚把公共件 $f 删了"
done
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "回滚后 pdg-probe81 仍在运行(公共件)" || bad "5g: 公共件 probe81 被停了"
[[ "$(systemctl is-active pdg-mitm)" != active ]] \
  && ok "回滚后 pdg-mitm 未在运行" || bad "5i: pdg-mitm 还在跑"

# ══ 6. 反向: iOS 上切 Android 失败 ═════════════════════════════════════════
# 拆成两档, 区别只有一个 —— **注入的范围**:
#   甲 只打前向(_switchcore_nft 合并出来的候选 …/merged.conf), 恢复那一路的 nft -c 照常
#      放行 ⇒ 现场该完整回到 iOS;
#   乙 前向与恢复校验一起打(所有 -c 都判失败) ⇒ 不许谎报恢复成功, 材料必须留下来。
# 原来一个桩对**所有** -c 判失败, 两件事被搅在一格里: 恢复到底是"没能恢复"还是"连恢复自己
# 的校验也被同一发子弹打掉了", 分不出来。
#
# 桩顺带记一条调用轨迹, 按**被校验的是哪个文件**归档:
#   前向 …/merged.conf          恢复 …/tree/etc/nftables.conf 与 …/nft.cand
# 轨迹只用来把"故障有没有命中目标阶段"**单独结算**: 没到达的阶段记**未执行**,
# 不拿"整支红了"冒充"注入生效了", 也不拿它替代现场判据。
echo; echo "── 6. iOS→Android 失败: 按注入范围分两档 ──"
IOS6=(/opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py
      /opt/pdg-bot/pdg-dot.mobileconfig.tmpl)

plat6_stub(){   # $1=fwd(只打前向) | all(前向与恢复校验一起打)   $2=轨迹落点
  export PDG_NFT_MODE="$1" PDG_NFT_TRACE="$2"
  : > "$PDG_NFT_TRACE"
  cp /usr/local/bin/nft /usr/local/bin/nft.real
  cat > /usr/local/bin/nft <<'S'
#!/bin/sh
printf 'CALL\t%s\n' "$*" >> "$PDG_NFT_TRACE"
if [ "$1" = "-c" ]; then
  case "$PDG_NFT_MODE:$3" in
    all:*)            printf 'FAIL\t%s\n' "$3" >> "$PDG_NFT_TRACE"
                      echo "Error: 注入的校验失败" >&2; exit 1;;
    fwd:*merged.conf) printf 'FAIL\t%s\n' "$3" >> "$PDG_NFT_TRACE"
                      echo "Error: 注入的校验失败" >&2; exit 1;;
    *)                printf 'PASSC\t%s\n' "$3" >> "$PDG_NFT_TRACE";;
  esac
fi
exec /usr/local/bin/nft.real "$@"
S
  chmod 755 /usr/local/bin/nft
}
plat6_unstub(){ cp -f /usr/local/bin/nft.real /usr/local/bin/nft; unset PDG_NFT_MODE PDG_NFT_TRACE; }

# 轨迹是**观察手段**, 它自己会坏在两处: 读不进来, 或者读进来之后数不出来。
# `grep -c` 的退出码有三种含义, 必须分开: 0=有匹配, 1=**正常的零匹配**, >=2=读取/执行错误。
# 出错那一档它照样会先打印一个 "0" —— 那个 0 一律不采信, 否则"数不出来"会被读成"没命中"。
plat6_cnt(){   # $1=具名前缀 $2=正则 $3=文本 → 设 CNT_OUT; 0=有效(含正常零匹配)
  local tag="$1" re="$2" txt="$3" v rc=0
  CNT_OUT=0
  v="$(grep -cE "$re" <<<"$txt")" || rc=$?
  if (( rc >= 2 )); then
    bad "$tag **观测无效** —— 轨迹计数失败(grep 退出 $rc), 它已经吐出的「$v」一律不采信"
    return 1
  fi
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    bad "$tag **观测无效** —— 轨迹计数结果不是数字($(printf '%q' "$v"))"
    return 1
  fi
  CNT_OUT="$v"; return 0
}
# 设 T_FWD(前向被判失败几次) / T_RECF(恢复校验被判失败几次) / T_RECP(恢复校验被放行几次)。
plat6_trace(){   # $1=轨迹文件 $2=具名前缀 → 0=可用
  local f="$1" tag="$2" rd=0 txt
  T_FWD=0; T_RECF=0; T_RECP=0
  txt="$(cat "$f")" || rd=$?
  if (( rd != 0 )); then
    bad "$tag **观测无效** —— 读 nft 调用轨迹失败(cat 退出 $rd), 它已经吐出的内容一律不采信"
    return 1
  fi
  plat6_cnt "$tag" '^FAIL	.*merged\.conf$'                          "$txt" || return 1
  T_FWD="$CNT_OUT"
  plat6_cnt "$tag" '^FAIL	.*(/tree/etc/nftables\.conf|/nft\.cand)$'  "$txt" || return 1
  T_RECF="$CNT_OUT"
  plat6_cnt "$tag" '^PASSC	.*(/tree/etc/nftables\.conf|/nft\.cand)$' "$txt" || return 1
  T_RECP="$CNT_OUT"
  return 0
}

# 每一档都自己造一次可核对的前像: 四件 iOS 必需文件必须**真的在盘上且非空**。
# 原来直接 sha256sum 四个路径就算前像 —— 文件不在时它报错并输出空, 前后两次拿到的是同一个
# "空哈希", "逐字节放回"那条判据恒真。所以先自检, 不成立就明说后面那条不作数。
# 四文件指纹。**每一次取指纹都自己检查两件事**: sha256sum 真的成功了, 且四行一个不少。
# "文件在且非空"不替代"摘要读到了": sha256sum 读不到某一件时会少输出一行并退出非零, 而
# 外面再套一层 sha256sum 永远成功 —— 于是"少读了一件"被压成一个看着很正常的哈希。
# 结果经 FP_OUT 回传而不是走 stdout: bad/ok 是往 stdout 打的, 命令替换会把红字一起吞掉。
plat6_fp(){   # $1=具名前缀 $2=这一次的名字 → 设 FP_OUT; 0=拿到了完整指纹
  local tag="$1" whose="$2" raw rc=0 good=0 l
  local -a lines=()
  FP_OUT=""
  raw="$(sha256sum "${IOS6[@]}" 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    bad "$tag **观测无效** —— ${whose}的四文件摘要没读成(sha256sum 退出 $rc), 它已经吐出的几行一律不采信"
    return 1
  fi
  mapfile -t lines <<< "$raw"
  for l in "${lines[@]}"; do [[ "$l" =~ ^[0-9a-f]{64}\ \  ]] && good=$((good+1)); done
  if (( good != ${#IOS6[@]} )); then
    bad "$tag **观测无效** —— ${whose}的摘要集合不完整(拿到 $good 条, 应为 ${#IOS6[@]} 条)"
    return 1
  fi
  FP_OUT="$raw"; return 0
}
plat6_seed(){   # $1=具名前缀 → 设 IOS_SHA; 0=前像成立
  local tag="$1" f miss=() out rc=0
  out=$(pdg platform ios 2>&1) || rc=$?
  [[ "$rc" == 0 ]] \
    && ok "$tag 健康对照: 正常切到 iOS 成功(rc=0), 现场备好" \
    || { bad "$tag 健康对照: 切 iOS 失败(rc=$rc): $(tail -4 <<<"$out")"; return 1; }
  IOS_SHA=""
  for f in "${IOS6[@]}"; do [[ -s "$f" ]] || miss+=("$f"); done
  if (( ${#miss[@]} != 0 )); then
    bad "$tag 前像没造出来(缺: ${miss[*]}) —— 「逐字节放回」这条不作数"
    return 1
  fi
  plat6_fp "$tag" 前像 || return 1
  ok "$tag 前像就位: 四件 iOS 必需文件都在盘上且非空, 四条摘要也都读到了"
  IOS_SHA="$FP_OUT"
  return 0
}

# ── 6 甲: 只打前向, 恢复校验照常可用 → 必须完整恢复 ─────────────────────────
echo; echo "── 6 甲: 只破坏前向(恢复校验可用) ──"
A_SEEDOK=1; plat6_seed "6甲:" || A_SEEDOK=0
plat6_stub fwd "$E2E_TMP/nft-trace-a.log"
out=$(pdg platform android 2>&1); rc=$?
plat6_unstub
A_TRACE=1; plat6_trace "$E2E_TMP/nft-trace-a.log" "6甲:" || A_TRACE=0
# ① 故障命中(与产品结论分开记)
if (( A_TRACE == 1 )); then
  (( T_FWD >= 1 )) \
    && ok "6甲-命中: 前向候选(merged.conf)的 nft -c 确实被判失败 $T_FWD 次" \
    || bad "6甲-命中: 前向根本没被打中(T_FWD=$T_FWD) —— 这一档什么都没验到"
  # ② 恢复校验有没有被**同一发注入**打掉 —— 这正是甲要排除的。
  #    恢复阶段根本没被调用到时, "一次都没判失败"是**平凡为真**: 既证不出范围没溢出,
  #    也证不出恢复可用。这一档要的就是"恢复那一路确实被走到且放行", 所以**必需阶段没到达
  #    就不能让最终结算成功** —— 记成具名的「场景未执行」进失败结算, 但它**不是**产品恢复失败。
  if (( T_RECF + T_RECP >= 1 )); then
    (( T_RECF == 0 )) \
      && ok "6甲-范围: 恢复那一路的 nft -c 被调用 $T_RECP 次且全部放行 —— 这发注入没有溢出到恢复" \
      || bad "6甲-范围: 恢复校验也被同一注入判失败 $T_RECF 次 —— 这一档的前提不成立"
  else
    bad "6甲-场景未执行: 必需的恢复校验阶段一次都没被调用到(T_RECF=$T_RECF T_RECP=$T_RECP) —— 这一档没跑成, **不是**产品恢复失败"
  fi
else
  bad "6甲-场景未执行: 轨迹观测无效 ⇒ 命中与范围都没有结论(见上面的「观测无效」) —— **不是**产品恢复失败"
fi
# ③ 产品退出码
[[ "$rc" != 0 ]] && ok "6甲-rc: 切 Android 失败 → 返回非 0(rc=$rc)" || bad "6甲-rc: 竟然成功了(rc=$rc)"
# ④ 现场结果(原 6c–6e 的判据一条不减; 不用日志代替现场)
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] \
  && ok "6甲-现场: 平台标记回到 ios" || bad "6甲-现场: 平台标记停在 $(cat /etc/privdns-gateway/platform)"
if (( A_SEEDOK == 1 )); then
  # 先各自确认"这一次的摘要真的读到了、四条一个不少", 再比。读不到 ≠ 内容不一致:
  # 前者是观测坏了, 后者才是产品没恢复 —— 两件事分开报。
  if plat6_fp "6甲:" 现场; then
    [[ "$FP_OUT" == "$IOS_SHA" ]] \
      && ok "6甲-现场: 被清理的 iOS 组件已逐字节放回(四条摘要逐条相同)" \
      || bad "6甲-现场: iOS 组件没恢复成原样(四条摘要与前像不一致)"
  else
    bad "6甲-场景未执行: 现场摘要没读成 ⇒ 「逐字节放回」没有结论 —— **不是**产品恢复失败"
  fi
else
  bad "6甲-场景未执行: 前像不成立 ⇒ 「逐字节放回」没有结论 —— **不是**产品恢复失败"
fi
[[ "$(systemctl is-active pdg-probe81)" == active ]] \
  && ok "6甲-现场: 回滚后 pdg-probe81 恢复运行" || bad "6甲-现场: probe81 没起回来"

# ── 6 乙: 前向与恢复校验同时被打掉 → 不许谎报恢复成功 ───────────────────────
# 乙**不替代**甲: 它验的是"恢复自己也坏掉时产品怎么说", 不是"恢复能不能做成"。
echo; echo "── 6 乙: 前向与恢复校验同时被破坏 ──"
plat6_seed "6乙:" || true
plat6_stub all "$E2E_TMP/nft-trace-b.log"
out=$(pdg platform android 2>&1); rc=$?
plat6_unstub
B_TRACE=1; plat6_trace "$E2E_TMP/nft-trace-b.log" "6乙:" || B_TRACE=0
if (( B_TRACE == 1 )); then
  (( T_FWD >= 1 )) \
    && ok "6乙-命中: 前向候选的 nft -c 被判失败 $T_FWD 次" \
    || bad "6乙-命中: 前向没被打中(T_FWD=$T_FWD)"
  # 三态要分开: T_RECF=0 既可能是"根本没调用到", 也可能是"调用了但被放行"。
  # 拿 T_RECF=0 直接解释成"没有调用"会把后者说成前者 —— 那是两种完全不同的现场。
  if (( T_RECF >= 1 )); then
    ok "6乙-命中: 恢复校验的 nft -c 也被判失败 $T_RECF 次(这一档的前提成立)"
  elif (( T_RECP >= 1 )); then
    bad "6乙-场景未执行: 恢复校验被调用了 $T_RECP 次却**全部放行**(T_RECF=0) —— 这一档的破坏没生效, **不是**产品恢复失败"
  else
    bad "6乙-场景未执行: 恢复校验一次都没被调用到(T_RECF=0 T_RECP=0, 恢复在更早的一步就停了) —— **不是**产品恢复失败"
  fi
else
  bad "6乙-场景未执行: 轨迹观测无效 ⇒ 命中没有结论(见上面的「观测无效」) —— **不是**产品恢复失败"
fi
[[ "$rc" != 0 ]] && ok "6乙-rc: 返回非 0(rc=$rc)" || bad "6乙-rc: 竟然成功了(rc=$rc)"
# 先把 ANSI 颜色码去掉再看: 不去的话抓路径会把行尾的 `[0m` 一起抓进来, 于是"盘上没有"
# 报的是夹具自己造出来的假路径, 与产品无关。
_outp="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$out")"
grep -q '恢复未完成' <<<"$_outp" \
  && ok "6乙-说法: 具名说明本次恢复未完成" || bad "6乙-说法: 没有具名说明恢复未完成: $(tail -4 <<<"$_outp")"
grep -q '不声称已恢复' <<<"$_outp" \
  && ok "6乙-说法: 明说不声称已恢复原平台与服务状态" || bad "6乙-说法: 缺「不声称已恢复」"
grep -q '已恢复到原平台' <<<"$_outp" \
  && bad "6乙-说法: 恢复没做完却报了「已恢复到原平台」(谎报)" || ok "6乙-说法: 没有谎报恢复成功"
# 产品声明保留的材料必须**真的在盘上** —— 只打印路径不算数。
# 但"逐项检查"之前得先确认**这份清单本身是完整枚举出来的**: 原来走的是进程替换,
# grep 与 sort 的退出码一个都看不见, 于是"枚举先吐一条再失败"留下的半截清单会被当成全部,
# 检查完还报"都在盘上"。所以枚举落到文件、逐步查码, 再用一次受检读取把它读回来。
# grep -o 的退出码同样三分: 0=有匹配, 1=**正常的零匹配**, >=2=读取/执行错误。
_KEPT_RAW="$E2E_TMP/p6-kept.raw"; _KEPT_LST="$E2E_TMP/p6-kept.lst"
rm -f "$_KEPT_RAW" "$_KEPT_LST"
_enum_ok=1; _enum_rc=0
grep -oE '(/tmp/[^ ]+|/var/lib/privdns-gateway/backups/[0-9-]+)' <<<"$_outp" > "$_KEPT_RAW" || _enum_rc=$?
if (( _enum_rc >= 2 )); then
  rm -f "$_KEPT_RAW"
  bad "6乙-场景未执行: 保留材料的路径枚举失败(grep 退出 $_enum_rc), 它已经吐出的半截清单一律不消费 —— **不是**材料真的缺失"
  _enum_ok=0
else
  _sort_rc=0
  sort -u "$_KEPT_RAW" > "$_KEPT_LST" || _sort_rc=$?
  if (( _sort_rc != 0 )); then
    rm -f "$_KEPT_LST"
    bad "6乙-场景未执行: 保留材料清单排序失败(sort 退出 $_sort_rc), 部分结果不消费 —— **不是**材料真的缺失"
    _enum_ok=0
  fi
fi
if (( _enum_ok == 1 )); then
  _rd_rc=0; _kept_txt="$(cat "$_KEPT_LST")" || _rd_rc=$?
  if (( _rd_rc != 0 )); then
    bad "6乙-场景未执行: 读保留材料清单失败(cat 退出 $_rd_rc), 已吐出的内容不消费 —— **不是**材料真的缺失"
  else
    _kept=0; _keptmiss=(); _keptarr=()
    [[ -n "$_kept_txt" ]] && mapfile -t _keptarr <<< "$_kept_txt"
    for _p in ${_keptarr+"${_keptarr[@]}"}; do
      [[ -n "$_p" ]] || continue
      _kept=$((_kept+1)); [[ -e "$_p" ]] || _keptmiss+=("$_p")
    done
    if (( _kept == 0 )); then
      bad "6乙-材料: 枚举成功但输出里一个保留材料的路径都没给出(产品没说材料留在哪)"
    elif (( ${#_keptmiss[@]} == 0 )); then
      ok "6乙-材料: 枚举完整($_kept 个路径), 逐个核过都确实在盘上"
    else
      bad "6乙-材料: 枚举完整($_kept 个), 但声明保留的这些盘上没有: ${_keptmiss[*]}"
    fi
  fi
fi

# ══ 7. Bot 凭据未配置(合法禁用态): 双向切换都必须成功 ═════════════════════
# bot.env 两项都空 = 这台机器不用 Telegram 管理, pdg-bot 不运行是正常的。以前平台切换的
# 校验门无条件把 pdg-bot 算进必需服务, 于是这种机器 `pdg platform ios` 必然卡在
# "pdg-bot 未稳定运行"并整体回滚 —— 而它本来就没打算起 bot。
echo; echo "── 7. Bot 凭据未配置 ──"
: > /etc/privdns-gateway/bot.env                 # 两项都空
systemctl disable --now pdg-bot >/dev/null 2>&1
e2e_svc_crash pdg-bot                            # 就算被谁启动了也起不来: 它不该被要求运行
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "未配凭据 + pdg-bot 停用 → 切到 iOS 成功" || bad "7: rc=$rc: $(tail -4 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "平台标记=ios" || bad "7b: 标记没改"
[[ "$(systemctl is-active pdg-probe81)" == active ]] && ok "iOS 组件照常起来" || bad "7c: probe81 没起"
out=$(pdg platform android 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "未配凭据 → 切回 Android 也成功" || bad "7d: rc=$rc: $(tail -4 <<<"$out")"
[[ "$(systemctl is-active pdg-bot)" != active ]] \
  && ok "全程没有强行启动未配置的 pdg-bot" || bad "7e: 竟然把没配凭据的 bot 拉起来了"

# 凭据配齐(ready)时, pdg-bot 起不来就必须失败并回滚
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
PLAT_BEFORE="$(cat /etc/privdns-gateway/platform)"
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "凭据 ready 但 pdg-bot 起不来 → 切换失败(非 0)" || bad "7f: 竟然成功了"
grep -q 'pdg-bot' <<<"$out" && ok "点名了未稳定运行的 pdg-bot" || bad "7g: 没点名: $(tail -3 <<<"$out")"
[[ "$(cat /etc/privdns-gateway/platform)" == "$PLAT_BEFORE" ]] \
  && ok "失败后平台标记已回滚" || bad "7h: 平台停在 $(cat /etc/privdns-gateway/platform)"
# 只配一半 = 配置错误, 要明确点出来
printf 'PDG_BOT_TOKEN=123456:AAaa\n' > /etc/privdns-gateway/bot.env
out=$(pdg platform ios 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '只配了一项' <<<"$out"; } \
  && ok "凭据只配一半 → 明确报配置错误并回滚" || bad "7i: rc=$rc: $(tail -3 <<<"$out")"
e2e_svc_heal pdg-bot
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
echo 1 > $E2E_TMP/e2e-svc/pdg-bot.ac; echo 1 > $E2E_TMP/e2e-svc/pdg-bot.en
pdg platform android >/dev/null 2>&1

# ══ 8. iOS 组件部署失败必须整体失败并回滚 ══════════════════════════════════
# 以前 _plat_deploy_ios 用 migrate_deploy_botfiles 装 MITM 模块, 那是**幂等迁移**的语义
# (`install … || true`): 装不上就当没这回事。于是注入 mitm_server.py 安装失败后, 命令照样
# RC=0、platform=ios, 而机器上既没有 mitm_server.py 也没有 pdg-mitm.service。
echo; echo "── 8. iOS 组件部署失败 ──"
snapshot_state(){
  { cat /etc/privdns-gateway/platform 2>/dev/null
    grep '^PDG_PLATFORM=' /etc/privdns-gateway/profile.env 2>/dev/null
    sha256sum /etc/nftables.conf /etc/mihomo/config.yaml 2>/dev/null
    for f in /opt/pdg-bot/probe81.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
             /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py \
             /etc/systemd/system/pdg-probe81.service "${RETIRED[@]}"; do
      printf '%s=%s\n' "$f" "$([[ -e $f ]] && echo yes || echo no)"
    done
    printf 'probe81=%s/%s mitm=%s/%s\n' \
      "$(systemctl is-active pdg-probe81 2>/dev/null)" "$(systemctl is-enabled pdg-probe81 2>/dev/null)" \
      "$(systemctl is-active pdg-mitm 2>/dev/null)" "$(systemctl is-enabled pdg-mitm 2>/dev/null)"
  } | sha256sum | cut -d' ' -f1
}
# 注入: 让指定源文件"装不上"(改成不可读, install 必失败)。真实失败, 不是打桩返回值。
# 只注入**平台专属**件: probe81.py / pdg-probe81.service 自 6.1B 起是公共件, 不归
# 平台切换管(它们装失败要在 install 与 `pdg update` 里拦, 见 test-update-faults 的
# 公共件注入那一组)。放在这里注入只会测出「平台切换不管公共件」这个既定设计。
# 注入目标取 _PLAT_IOS_REQUIRED 里**当前真实存在**的四项源文件。原来这里还注入
# deploy/bot/mitm_server.py 与 mitm_wloc.py —— 它们已随退役删除, `mv` 直接失败, 于是
# 那一轮根本没注入任何东西, 却拿"切换成功"当失败来判。
for target in deploy/bot/mitm_ca.py deploy/bot/iosprofile.py deploy/bot/iosstate.py \
              deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl; do
  n="$(basename "$target")"
  [[ -e "/opt/privdns-gateway/$target" ]] \
    || { bad "8: 注入前提不成立 —— 源文件 $target 不存在"; continue; }
  PLAT_BEFORE_INJ="$(cat /etc/privdns-gateway/platform)"   # 回滚要回到**本轮进入前**那个平台
  BEFORE="$(snapshot_state)"
  mv "/opt/privdns-gateway/$target" "/opt/privdns-gateway/$target.hidden"
  out=$(pdg platform ios 2>&1); rc=$?
  mv "/opt/privdns-gateway/$target.hidden" "/opt/privdns-gateway/$target"
  [[ "$rc" != 0 ]] && ok "$n 部署失败 → 返回非 0" || bad "8: $n 装不上却 RC=0: $(tail -3 <<<"$out")"
  [[ "$(cat /etc/privdns-gateway/platform)" == "$PLAT_BEFORE_INJ" ]] \
    && ok "$n: 平台标记已回滚到 $PLAT_BEFORE_INJ" \
    || bad "8b: $n 平台停在 $(cat /etc/privdns-gateway/platform), 应回到 $PLAT_BEFORE_INJ"
  [[ "$(snapshot_state)" == "$BEFORE" ]] \
    && ok "$n: 文件与服务状态完整回滚(逐项比对)" || bad "8c: $n 现场没回滚干净"
done

# 修好之后照常能切过去(证明上面失败不是因为环境坏了)
out=$(pdg platform ios 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "源文件恢复后切 iOS 正常成功" || bad "8d: rc=$rc: $(tail -4 <<<"$out")"
_need=(/opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py /opt/pdg-bot/iosstate.py \
       /opt/pdg-bot/probe81.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl \
       /etc/systemd/system/pdg-probe81.service)
_miss=0
for f in "${_need[@]}"; do [[ -s "$f" ]] || { bad "8e: 成功路径缺 $f"; _miss=1; }; done
[[ "$_miss" == 0 ]] && ok "成功路径 ${#_need[@]} 个必需文件全部就位"
# 成功路径同样不许把退役制品装回来。
for f in "${RETIRED[@]}"; do
  [[ -e "$f" ]] && bad "8e: 成功路径又出现了已退役的 $f" || ok "成功路径没有已退役的 $(basename "$f")"
done
pdg platform android >/dev/null 2>&1

rm -f /usr/local/bin/nft.real $E2E_TMP/e2e-nft-ruleset
e2e_summary

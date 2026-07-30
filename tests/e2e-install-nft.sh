#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: **全新安装**不得覆盖用户已有的 nftables 配置。
#
# install.sh 原先直接 `render 模板 > /etc/nftables.conf`: 机器上预先存在的 VPN/NAT/转发表
# 连同自定义 input 链一起消失, 而安装照样返回成功 —— 用户装完才发现 WireGuard 不通,
# 且 doctor 是在**装完之后**才报 input 链冲突, 那时原文件已经没了。
#
# 现在两条纪律(与迁移共用 nftscan.py / nftmerge.py, 不另立判据):
#   · 存在其它挂 hook input 的 base chain → **装之前**中止, 点名冲突位置, 一个字节都不动;
#   · 只有 NAT/forward/VPN 这类不冲突的表 → 逐字节保留, 只把 table inet pdg 合并进去。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

e2e_stub_system

# 打桩外部世界(apt/certbot/下载), 与 e2e-install.sh 同口径 —— 本用例要验的是防火墙合并,
# 不该被沙箱里的包管理器网络状况左右。
for c in apt-get certbot vnstat; do
  printf '#!/bin/sh\nexit 0\n' > "/usr/local/bin/$c"; chmod 755 "/usr/local/bin/$c"
done
cat > /usr/local/bin/dpkg <<'S'
#!/bin/sh
[ "$1" = "--print-architecture" ] && { echo amd64; exit 0; }
exit 0
S
chmod 755 /usr/local/bin/dpkg
. "$E2E_ROOT/lib/versions.sh"
if ! command -v mosdns >/dev/null 2>&1; then
  printf '#!/bin/sh\ncase "$1" in version) echo "v%s";; start) sleep 3600;; esac\nexit 0\n' \
    "$MOSDNS_VER" > /usr/local/bin/mosdns; chmod 755 /usr/local/bin/mosdns
fi
if ! command -v mihomo >/dev/null 2>&1; then
  printf '#!/bin/sh\ncase "$1" in -v|version) echo "Mihomo Meta %s linux amd64";; -t) exit 0;; esac\nexit 0\n' \
    "$MIHOMO_VER" > /usr/local/bin/mihomo; chmod 755 /usr/local/bin/mihomo
fi

# 带**真状态**的 nft 桩: `nft -f` 装载, `nft list …` 回显当前已加载规则。
#
# `-f` 必须区分**有没有 flush ruleset** —— 这正是本轮修复的判据所在:
#   · 文件里 flush 生效  → 整份 ruleset 被替换(文件外的表就此消失);
#   · 没有(或被注释掉)  → 按表合并(文件里声明的表被替换, 其余原样留着)。
# 桩要是一律 `cat FILE > STATE`, "Docker 的表有没有活下来"这个断言就永远成立, 等于没验。
NFT_STATE=/tmp/e2e-nft-ruleset
cat > /usr/local/bin/nft <<'S'
#!/bin/sh
STATE=/tmp/e2e-nft-ruleset
case "$1" in
  -c) exit 0 ;;
  -j) exit 1 ;;                 # 桩不实现 JSON → 合并侧走文本兜底(老 nft 也这样)
  -f) # 场景 4 会造一个"没有 python3"的 PATH 来验扫描器跑不起来时的行为 —— 那时桩退回
      # 最朴素的整份替换。那一节验的不是 flush 语义, 退化不影响它的判据。
      command -v python3 >/dev/null 2>&1 || { [ -f "$2" ] && cat "$2" > "$STATE"; exit 0; }
      [ -f "$2" ] && python3 - "$2" "$STATE" <<'PY'
import re, sys
new_f, state_f = sys.argv[1], sys.argv[2]
new = open(new_f).read()
flush = any(re.match(r"^\s*flush\s+ruleset\s*$", l) for l in new.split("\n"))
def tables(txt):
    """→ [(名字, 块文本)]; 只收顶层 table 块。"""
    out, cur, buf, depth = [], None, [], 0
    for l in txt.split("\n"):
        st = l.split("#", 1)[0].strip()
        m = re.match(r"^table\s+(\S+)\s+(\S+)", st)
        if m and cur is None:
            cur, buf, depth = "%s %s" % (m.group(1), m.group(2)), [l], l.count("{") - l.count("}")
            if depth <= 0 and "{" not in l:      # 只是声明行, 不是块
                cur, buf = None, []
            continue
        if cur is None:
            continue
        buf.append(l); depth += l.count("{") - l.count("}")
        if depth <= 0:
            out.append((cur, "\n".join(buf))); cur, buf = None, []
    return out
new_t = tables(new)
if flush:
    keep = []
else:
    names = {n for n, _ in new_t}
    try:
        old = open(state_f).read()
    except OSError:
        old = ""
    keep = [(n, b) for n, b in tables(old) if n not in names]
open(state_f, "w").write("\n".join(b for _, b in keep + new_t) + "\n")
PY
      exit 0 ;;
  list)
    case "$2" in
      tables) grep -oE '^table [a-z0-9]+ [A-Za-z0-9_.-]+' "$STATE" 2>/dev/null | sed 's/ *{$//'; exit 0 ;;
      table)  awk -v f="$3" -v n="$4" '
                $1=="table" && $2==f && $3==n {p=1}
                p {print}
                p && /^}/ {exit}' "$STATE" 2>/dev/null; exit 0 ;;
      *) cat "$STATE" 2>/dev/null; exit 0 ;;
    esac ;;
  delete) exit 0 ;;
esac
exit 0
S
chmod 755 /usr/local/bin/nft

run_install(){   # $1=额外 env
  # shellcheck disable=SC2086
  env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaaBBbbCCccDDddEEeeFFffGGgg \
      PDG_ALLOWED=1 PDG_PLATFORM=android $1 \
      bash "$E2E_ROOT/install.sh" 2>&1
}
reset_box(){
  rm -rf /etc/mosdns /etc/sing-box /etc/mihomo /etc/privdns-gateway /opt/pdg-bot \
         /usr/local/bin/pdg /usr/local/bin/pdg-set-token /etc/systemd/system/pdg-*.service \
         /etc/systemd/system/mosdns.service /etc/nftables.conf.pdg-orig
  rm -rf /tmp/e2e-svc; mkdir -p /tmp/e2e-svc
}

# ══ 1. 只有 NAT / forward / VPN 表(不挂 input hook)→ 逐字节保留并安全合并 ═══
echo "── 1. 已有自定义 NAT/forward 表 ──"
reset_box
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table ip mynat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.66.0.0/24 oifname "eth0" masquerade   # WireGuard 出网
    }
}

table inet myfwd {
    chain forward {
        type filter hook forward priority 0; policy accept;
        iifname "wg0" oifname "eth0" accept
    }
}
NFT
nft -f /etc/nftables.conf
CUSTOM_BEFORE="$(cat /etc/nftables.conf)"
out=$(run_install ""); rc=$?
[[ "$rc" == 0 ]] && ok "无冲突的自定义表 → 安装照常成功" || bad "1: 安装失败 rc=$rc: $(tail -6 <<<"$out")"
for probe in 'table ip mynat' 'masquerade' 'table inet myfwd' 'wg0'; do
  grep -qF "$probe" /etc/nftables.conf && ok "自定义规则保留: $probe" || bad "1b: 丢了 $probe"
done
# 用户区(pdg 管理区之前的部分)必须逐字节一致
CUSTOM_AFTER="$(awk '/PrivDNS Gateway 管理区|table inet pdg/{exit} {print}' /etc/nftables.conf)"
[[ "$(printf '%s\n' "$CUSTOM_AFTER" | sed '/^$/d')" == "$(printf '%s\n' "$CUSTOM_BEFORE" | sed '/^$/d')" ]] \
  && ok "用户区逐字节保留(只多了 pdg 管理区)" \
  || { bad "1c: 用户区被改写"; diff <(printf '%s\n' "$CUSTOM_BEFORE") <(printf '%s\n' "$CUSTOM_AFTER") | head -8; }
grep -q 'table inet pdg' /etc/nftables.conf && ok "pdg 管理区已合并进来" || bad "1d: pdg 表没进去"
[[ "$(grep -c '^table inet pdg {' /etc/nftables.conf)" == 1 ]] \
  && ok "pdg 表只有一份" || bad "1e: pdg 表重复"
grep -qF 'table ip mynat' "$NFT_STATE" \
  && ok "运行中的 ruleset 里也还有用户的表(真的加载了合并结果)" || bad "1f: 运行规则丢了用户表"

# ══ 2. 存在其它 input base chain → 安装前中止, 现场一个字节都不动 ═══════════
echo; echo "── 2. 已有自定义 input base chain ──"
reset_box
cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table inet myfilter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        tcp dport { 9443, 9444 } accept
        udp dport 51820 accept
    }
}
NFT
nft -f /etc/nftables.conf
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
out=$(run_install ""); rc=$?
[[ "$rc" != 0 ]] && ok "冲突现场 → 安装中止(返回非 0)" || bad "2: 竟然装成功了: $(tail -4 <<<"$out")"
grep -qE 'input|中止安装' <<<"$out" && ok "说明了原因(input 链冲突)" || bad "2b: 没说清原因: $(tail -4 <<<"$out")"
grep -q 'myfilter' <<<"$out" && ok "点名了冲突的表(myfilter)" || bad "2c: 没点名冲突表"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]] \
  && ok "中止后 /etc/nftables.conf 逐字节未变" || bad "2d: 原文件被改写"
[[ "$(sha256sum "$NFT_STATE" | cut -d' ' -f1)" == "$RULESET_SHA" ]] \
  && ok "中止后运行中的 ruleset 未变" || bad "2e: 运行规则被改了"
# 中止必须发生在"动任何东西之前": 二进制/服务/配置目录都不该出现
for p in /usr/local/bin/pdg /opt/pdg-bot/bot.py /etc/mosdns/config.yaml /etc/privdns-gateway/profile.env; do
  [[ -e "$p" ]] && bad "2f: 中止前已经动了 $p" || ok "未创建 $(basename "$p")(中止发生在动手之前)"
done

# ══ 3. 冲突解除后可以正常安装 ══════════════════════════════════════════════
echo; echo "── 3. 解除冲突后重装 ──"
python3 - <<'PY'
txt = open("/etc/nftables.conf", encoding="utf-8").read()
open("/etc/nftables.conf", "w", encoding="utf-8").write(
    txt.replace("hook input", "hook forward"))     # 把冲突链改挂到 forward
PY
nft -f /etc/nftables.conf
out=$(run_install ""); rc=$?
[[ "$rc" == 0 ]] && ok "冲突解除后安装成功" || bad "3: rc=$rc: $(tail -6 <<<"$out")"
grep -q 'table inet myfilter' /etc/nftables.conf && ok "用户的表仍在" || bad "3b: 用户表丢了"

# ══ 4. 扫描器跑不起来时, 绝不能静默继续 ═══════════════════════════════════
# 极简 Debian 12 没有 python3 → `python3 nftscan.py` 直接 127。旧写法的 case 只认 0 和 2,
# 127 静默落空, 于是"有冲突的机器照样装下去", 这道门等于不存在。
echo; echo "── 4. 扫描器退出码 ──"

REAL_PY="$(readlink -f "$(command -v python3)")"
cp -f "$REAL_PY" /usr/local/bin/py3-real 2>/dev/null || cp "$REAL_PY" /usr/local/bin/py3-real
: > /tmp/notexec; chmod 644 /tmp/notexec

put_py_stub(){   # 写一个 python3 桩(先删: 上一步可能留下指向真解释器的符号链接, 直接写会写穿)
  rm -f /usr/local/bin/python3
  cat > /usr/local/bin/python3
  chmod 755 /usr/local/bin/python3
}
restore_py(){ rm -f /usr/local/bin/python3; ln -sf /usr/local/bin/py3-real /usr/local/bin/python3; }
# 真实模拟"机器上没有 python3": 造一个 PATH 目录, 把系统各 bin 目录里的命令**除 python3**
# 全部软链进来, 然后只用它当 PATH。比 bind mount 可靠(bind 到符号链接上 `command -v` 仍能
# 找到), 也比"放个 exit 127 的桩"忠实 —— 后者是"python3 存在但坏了", 不是"没装"。
NOPY_BIN=/tmp/nopy-bin
build_nopy_path(){
  rm -rf "$NOPY_BIN"; mkdir -p "$NOPY_BIN"
  local d f b
  for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      case "$b" in python3*) continue;; esac
      [[ -e "$NOPY_BIN/$b" ]] || ln -sf "$f" "$NOPY_BIN/$b" 2>/dev/null || true
    done
  done
  ! PATH="$NOPY_BIN" command -v python3 >/dev/null 2>&1     # 真的找不到才算造成功
}
run_install_nopy(){   # 用"没有 python3"的 PATH 跑装机
  env -i PATH="$NOPY_BIN" HOME=/root \
      PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaaBBbbCCccDDddEEeeFFffGGgg \
      PDG_ALLOWED=1 PDG_PLATFORM=android \
      bash "$E2E_ROOT/install.sh" 2>&1
}

# 换现场必须连**内核状态**一起换 —— 只重置 /etc/nftables.conf 是不够的。
# nft 桩以前是"整份替换", 上一节装成功就顺带把内核状态洗干净了, 于是这个耦合看不出来;
# 桩改成按 flush 语义合并之后(没有 flush 就保留文件外的表), 上一节的表会活到下一节,
# 把"干净现场"污染成"有冲突现场"。清空它, 各节才真的互不影响。
reset_all(){ reset_box; rm -rf /opt/privdns-gateway; : > "${NFT_STATE:-/tmp/e2e-nft-ruleset}"; }

seed_conflict(){ cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table inet myfilter {
    chain input {
        type filter hook input priority 0; policy drop;
        tcp dport { 9443 } accept
    }
}
NFT
nft -f /etc/nftables.conf; }
seed_clean(){ cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table ip mynat {
    chain postrouting { type nat hook postrouting priority srcnat; policy accept; }
}
NFT
nft -f /etc/nftables.conf; }

untouched(){   # 中止后: 防火墙文件、运行规则、PDG 路径都不许被动过
  local tag="$1" bad_paths=() p
  [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]] \
    || bad_paths+=("/etc/nftables.conf 被改写")
  [[ "$(sha256sum "$NFT_STATE" | cut -d' ' -f1)" == "$RULESET_SHA" ]] \
    || bad_paths+=("运行 ruleset 被改")
  for p in /usr/local/bin/pdg /opt/pdg-bot/bot.py /etc/mosdns/config.yaml \
           /etc/privdns-gateway/profile.env /etc/systemd/system/pdg-bot.service; do
    [[ -e "$p" ]] && bad_paths+=("创建了 $p")
  done
  if [[ ${#bad_paths[@]} -eq 0 ]]; then ok "$tag: 中止后 nft 文件/运行规则/PDG 路径均未改变"
  else bad "$tag: ${bad_paths[*]}"; fi
}

# ── 4a. 机器上真没有 python3 + 冲突链 → 装上前置依赖后识别并中止 ──
reset_all; seed_conflict
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
# apt 桩: 被要求装 python3 时把真解释器放进那个 PATH 目录(等价于 apt 真的装好了)
cat > /usr/local/bin/apt-get <<'S'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    python3|python3-minimal) ln -sf /usr/local/bin/py3-real /tmp/nopy-bin/python3 ;;
  esac
done
exit 0
S
chmod 755 /usr/local/bin/apt-get
ln -sf /usr/local/bin/apt-get "$NOPY_BIN/apt-get" 2>/dev/null || true
if build_nopy_path; then
  ln -sf /usr/local/bin/apt-get "$NOPY_BIN/apt-get"
  out=$(run_install_nopy); rc=$?
  [[ "$rc" != 0 ]] && ok "无 python3 + 冲突链 → 安装中止(不再因 127 静默继续)" \
    || bad "4a: 竟然装成功了: $(tail -4 <<<"$out")"
  grep -q '安全检查前置依赖' <<<"$out" \
    && ok "明确区分了「安全检查前置依赖」与正式依赖安装" || bad "4a2: $(head -8 <<<"$out")"
  grep -q 'myfilter' <<<"$out" \
    && ok "装好 python3 后确实识别出冲突表并点名" || bad "4a3: 没识别冲突: $(tail -6 <<<"$out")"
  untouched "4a"
else
  echo "[SKIP] 造不出「没有 python3」的 PATH, 跳过该用例"
fi

# ── 4b. 真没有 python3 + 干净配置 → 装上前置依赖后照常继续 ──
reset_all; seed_clean
if build_nopy_path; then
  ln -sf /usr/local/bin/apt-get "$NOPY_BIN/apt-get"
  out=$(run_install_nopy); rc=$?
  [[ "$rc" == 0 ]] && ok "无 python3 + 干净配置 → 装上前置依赖后安装继续并成功" \
    || bad "4b: rc=$rc: $(tail -6 <<<"$out")"
  grep -q '安全检查前置依赖' <<<"$out" && ok "干净路径同样先补前置依赖再检查" || bad "4b2: 没提前置依赖"
  [[ -e "$NOPY_BIN/python3" ]] && ok "前置依赖真的被装上了(apt 被调用)" || bad "4b3: 没装 python3"
else
  echo "[SKIP] 同上"
fi
rm -rf "$NOPY_BIN"
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/apt-get; chmod 755 /usr/local/bin/apt-get

# ── 4c. 扫描器以各种异常码退出 → 一律中止(检查没跑成 ≠ 检查通过) ──
for code in 126 127 3 137; do
  reset_all; seed_clean
  CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
  RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
  put_py_stub <<S
#!/bin/sh
# 只拦"扫描"这一次调用(第二个参数是配置路径); --nft-path 是另一个用途, 放行给真解释器,
# 否则连"nft 在哪"都被注入的故障顶掉, 测的就不是同一件事了
case "\$1 \$2" in
  */nftscan.py\ --nft-path) ;;
  */nftscan.py*) echo "注入的扫描器故障(code $code)" >&2; exit $code ;;
esac
exec /usr/local/bin/py3-real "\$@"
S
  out=$(run_install ""); rc=$?
  restore_py
  [[ "$rc" != 0 ]] && ok "扫描器退出 $code → 安装中止" || bad "4c: 退出 $code 却继续装了: $(tail -3 <<<"$out")"
  grep -q "退出码 $code" <<<"$out" && ok "退出 $code: 报出了具体退出码" || bad "4c2($code): $(tail -3 <<<"$out")"
  grep -q '注入的扫描器故障' <<<"$out" \
    && ok "退出 $code: 带出了扫描器自己的 stderr(没被吞掉)" || bad "4c3($code): stderr 被吞了"
  untouched "退出 $code"
done

# ── 4d. 0/1/2 三种既有语义仍然正确 ──
for code in 0 1 2; do
  reset_all; seed_clean
  CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
  RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
  put_py_stub <<S
#!/bin/sh
case "\$1 \$2" in
  */nftscan.py\ --nft-path) ;;                 # 放行: 这是问"nft 在哪", 不是扫描
  */nftscan.py*) echo "注入: 模拟退出 $code"; exit $code ;;
esac
exec /usr/local/bin/py3-real "\$@"
S
  out=$(run_install ""); rc=$?
  restore_py
  case "$code" in
    0) { [[ "$rc" != 0 ]] && grep -q '不兼容的 nftables input 链' <<<"$out"; } \
         && ok "退出 0(有冲突)→ 中止并说明是 input 链冲突" || bad "4d(0): rc=$rc: $(tail -3 <<<"$out")"
       untouched "退出 0" ;;
    1) [[ "$rc" == 0 ]] && ok "退出 1(确认干净)→ 继续并装完" || bad "4d(1): rc=$rc: $(tail -4 <<<"$out")" ;;
    2) # nft 可用却读不到运行规则 → 不能盲目往下写规则
       { [[ "$rc" != 0 ]] && grep -q '无法确认现有 nftables 规则' <<<"$out"; } \
         && ok "退出 2 且 nft 可用 → 中止并说明读不到运行规则" || bad "4d(2): rc=$rc: $(tail -3 <<<"$out")"
       untouched "退出 2" ;;
  esac
done

# ── 4d2. nft 在 sbin 但 PATH 里没有 + 读不到运行规则 → 必须中止(不能当成"nft 没装") ──
# 真实现场: `su`(不带 -)/cron/某些容器的 root PATH 里没有 sbin。旧写法用 `command -v nft`
# 判"在不在", 于是这台机器被当成裸机, 一整套现网 input 链就这么放过去了。
reset_all; seed_clean
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
mkdir -p /usr/local/sbin
cp /usr/local/bin/nft /usr/local/sbin/nft            # nft 挪到 sbin(PATH 里没有它)
cat > /usr/local/sbin/nft <<'S'
#!/bin/sh
# 装着 nftables, 但读不到运行 ruleset(权限/内核异常的真实形态)
case "$1 $2" in
  "list ruleset") echo "Error: Could not process rule: Operation not permitted" >&2; exit 1 ;;
esac
exec /usr/local/bin/nft-real "$@"
S
chmod 755 /usr/local/sbin/nft
mv /usr/local/bin/nft /usr/local/bin/nft-real
out=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
      PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaa PDG_ALLOWED=1 PDG_PLATFORM=android \
      bash "$E2E_ROOT/install.sh" 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '无法确认现有 nftables 规则' <<<"$out"; } \
  && ok "nft 只在 sbin(PATH 里没有)且读不到运行规则 → 中止, 不再误判成「没装 nftables」" \
  || bad "4d2: rc=$rc: $(tail -4 <<<"$out")"
grep -qE 'nft 在 /\S*/nft' <<<"$out" \
  && ok "报出了实际找到 nft 的位置(不是含糊地说「nft 不可用」)" \
  || bad "4d2b: 没报出 nft 路径: $(tail -4 <<<"$out")"
untouched "4d2"
mv /usr/local/bin/nft-real /usr/local/bin/nft; rm -f /usr/local/sbin/nft

# ── 4e. 扫描器文件缺失 → 同样中止(不是"没检查出问题") ──
reset_all; seed_clean
rm -rf /tmp/repo-noscan && cp -a "$E2E_ROOT" /tmp/repo-noscan
rm -f /tmp/repo-noscan/deploy/bot/nftscan.py
out=$(env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaa PDG_ALLOWED=1 PDG_PLATFORM=android \
      bash /tmp/repo-noscan/install.sh 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '缺少防火墙冲突扫描器' <<<"$out"; } \
  && ok "扫描器文件缺失 → 中止并说明仓库不完整" || bad "4e: rc=$rc: $(tail -3 <<<"$out")"
rm -rf /tmp/repo-noscan
rm -f /usr/local/bin/py3-real /tmp/notexec; rm -rf "$NOPY_BIN"


# ══ 5. 全新 Debian 13: 文件是发行版自带的, 内核里还有 iptables-nft 建出来的空表 ═══
# 用户现场(2026-07-30 报): /etc/nftables.conf 就是 nftables 包自带那份 —— `flush ruleset`
# 加一个空的 `table inet filter`; 而内核里另有 `table ip nat` / `table ip filter`。Debian 上
# iptables 默认是 iptables-nft, 任何东西碰一下 iptables(cloud-init、包的 postinst、甚至
# 一句 `iptables -L`)就会把这两张空表建出来。装机因此中止在"flush 会冲掉运行中的表"。
#
# 那两张表一条规则都没有, 冲掉什么也不丢, iptables-nft 下次用到自己重建 —— 拦它等于
# **全新机器装不上**。真该拦的是里面有规则的(Docker / fail2ban), 下面 5b 验那一半。
echo; echo "── 5. 全新 Debian 13(文件里没有、内核里有的空表)──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
        chain forward {
                type filter hook forward priority filter;
        }
        chain output {
                type filter hook output priority filter;
        }
}
CONF
# 内核现状: 文件里那张 + iptables-nft 按需建出来的两张空表
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
	}
	chain output {
		type filter hook output priority filter; policy accept;
	}
}
table ip filter {
	chain INPUT {
		type filter hook input priority filter; policy accept;
	}
	chain FORWARD {
		type filter hook forward priority filter; policy accept;
	}
}
table ip nat {
	chain PREROUTING {
		type nat hook prerouting priority dstnat; policy accept;
	}
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
	}
}
STATE
out="$(run_install "")"; rc=$?
[[ "$rc" == 0 ]] && ok "5 全新 Debian 13 现场装机成功" \
  || bad "5 装机失败(rc=$rc): $(grep -E '冲突位置|无法安全合并|安装失败' <<<"$out" | head -2 | tr '\n' ' ')"
grep -q 'table inet pdg' /etc/nftables.conf \
  && ok "5 pdg 管理区已合并进配置文件" || bad "5 配置里没有 pdg 表"
grep -q 'table inet filter' /etc/nftables.conf \
  && ok "5 发行版自带的 inet filter 逐字节保留" || bad "5 把发行版自带的表弄丢了"
grep -q '什么都不会丢' <<<"$out" \
  && ok "5 如实告知了那两张空表会被 flush 掉但不丢东西" || bad "5 没有告知空表的处置"

# ── 5c. Docker 主机: 内核里那张表有真规则, 但文件里的表是空的 → 自动注释掉 flush, 一把装上 ──
# 这是"算不算真修好"的分界: 只改错误信息, 每个跑 Docker 的用户还得自己先动手改防火墙文件。
echo "── 5c. Docker 主机(文件表为空)→ 应自动处理并装成功 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}
table ip nat {
	chain DOCKER {
		policy accept;
	}
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "docker0" masquerade
	}
}
STATE
out="$(run_install "")"; rc=$?
[[ "$rc" == 0 ]] && ok "5c Docker 主机一把装上(不必人工改防火墙文件)"   || bad "5c 仍失败(rc=$rc): $(grep -E '冲突位置|无法安全合并' <<<"$out" | head -1)"
grep -qE '^# flush ruleset' /etc/nftables.conf   && ok "5c flush ruleset 被注释掉(原行留痕)" || bad "5c flush 没被处理"
grep -q '由 pdg 注释掉' /etc/nftables.conf   && ok "5c 文件里写清了是谁改的、怎么还原" || bad "5c 注释没有自我说明"
grep -q 'table inet pdg' /etc/nftables.conf   && ok "5c pdg 管理区已合并" || bad "5c pdg 表没进去"
grep -q '注释掉' <<<"$out" && ok "5c 终端上如实告知了这次改动" || bad "5c 终端没提这件事"
grep -qF 'table ip nat' "$NFT_STATE"   && ok "5c 运行中 Docker 的 NAT 表还在(没被冲掉)" || bad "5c Docker 的表被冲掉了"
grep -q 'PDG_KEEP_FLUSH' <<<"$out" && ok "5c 给了关掉这个行为的开关" || bad "5c 没给开关"

# ── 5d. 同现场但设了 PDG_KEEP_FLUSH=1 → 用户说别动就别动, 保持中止 ──
echo "── 5d. PDG_KEEP_FLUSH=1 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}
table ip nat {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "docker0" masquerade
	}
}
STATE
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
out="$(run_install "PDG_KEEP_FLUSH=1")"; rc=$?
[[ "$rc" != 0 ]] && ok "5d 设了 PDG_KEEP_FLUSH=1 → 保持中止" || bad "5d 设了开关还是自动改了"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]]   && ok "5d 中止后配置逐字节未变" || bad "5d 配置被改了"

# ── 5e. 边界: Docker 在跑, 用户自己的表也有规则 → 给那张表补自重建, 照样一把装上 ──
echo "── 5e. Docker + 用户自己的表有规则 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
        chain input {
                type filter hook input priority filter;
        }
}
table ip myforward {
        chain fwd {
                type filter hook forward priority filter; policy accept;
                ip saddr 10.8.0.0/24 accept
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
	}
}
table ip myforward {
	chain fwd {
		type filter hook forward priority filter; policy accept;
		ip saddr 10.8.0.0/24 accept
	}
}
table ip nat {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "docker0" masquerade
	}
}
STATE
out="$(run_install "")"; rc=$?
[[ "$rc" == 0 ]] && ok "5e Docker + 用户带规则的表 → 照样一把装上" \
  || bad "5e 仍失败(rc=$rc): $(grep -E '冲突位置|无法安全合并' <<<"$out" | head -1)"
grep -q 'delete table ip myforward' /etc/nftables.conf \
  && ok "5e 用户的表被补成自重建形态" || bad "5e 没给用户的表加自重建"
grep -qF 'table ip nat' "$NFT_STATE" \
  && ok "5e Docker 的 NAT 表还在" || bad "5e Docker 的表被冲掉了"
grep -qF 'ip saddr 10.8.0.0/24 accept' "$NFT_STATE" \
  && ok "5e 用户自己的转发规则也还在" || bad "5e 用户规则丢了"
# 重复应用不许累积 —— 自重建就是为了这个
"$(command -v nft)" -f /etc/nftables.conf >/dev/null 2>&1
"$(command -v nft)" -f /etc/nftables.conf >/dev/null 2>&1
[[ "$(grep -c 'ip saddr 10.8.0.0/24 accept' "$NFT_STATE")" == 1 ]] \
  && ok "5e 反复应用配置不会让规则累积(自重建生效)" \
  || bad "5e 规则累积到 $(grep -c 'ip saddr 10.8.0.0/24 accept' "$NFT_STATE") 条"

# ── 5b. 那张表**和别人共管**(内核里有它没声明的链)→ delete 会误伤, 只能中止 ──
echo "── 5b. 共管的表 → 只能中止 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f

flush ruleset

table ip filter {
        chain FORWARD {
                type filter hook forward priority filter; policy accept;
                ip saddr 10.8.0.0/24 accept
        }
}
CONF
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
cat > "$NFT_STATE" <<'STATE'
table ip filter {
	chain FORWARD {
		type filter hook forward priority filter; policy accept;
		ip saddr 10.8.0.0/24 accept
	}
	chain DOCKER-USER {
		policy accept;
		ip saddr 172.17.0.0/16 accept
	}
}
table ip nat {
	chain POSTROUTING {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "docker0" masquerade
	}
}
STATE
out="$(run_install "")"; rc=$?
[[ "$rc" != 0 ]] && ok "5b 共管的表 → 装机中止(加 delete 会误伤 Docker 那部分)" \
  || bad "5b 竟然装成功了, Docker 的 NAT 规则会被 flush 掉"
grep -q '共管' <<<"$out" && ok "5b 说明了原因(表是共管的)" || bad "5b 没说清原因"
grep -q 'nft list table ip nat' <<<"$out" \
  && ok "5b 给了查看内容的命令" || bad "5b 没给排查命令"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA" ]] \
  && ok "5b 中止后 /etc/nftables.conf 逐字节未变" || bad "5b 原文件被改写了"

rm -f "$NFT_STATE"
e2e_summary
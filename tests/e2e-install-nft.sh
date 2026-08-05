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
NFT_STATE=$E2E_TMP/e2e-nft-ruleset
{ printf '#!/bin/sh\nSTATE=%s\n' "$NFT_STATE"    # 引号 heredoc 不展开, 路径从生成的头行注入
  cat <<'S'
case "$1" in
  -c) exit 0 ;;
  -j) exit 1 ;;                 # 桩不实现 JSON → 合并侧走文本兜底(老 nft 也这样)
  -f) # 场景 4 会造一个"没有 python3"的 PATH 来验扫描器跑不起来时的行为 —— 那时桩退回
      # 最朴素的整份替换。那一节验的不是 flush 语义, 退化不影响它的判据。
      command -v python3 >/dev/null 2>&1 || { [ -f "$2" ] && cat "$2" > "$STATE"; exit 0; }
      [ -f "$2" ] && python3 - "$2" "$STATE" <<'PY'
import re, sys
new_f, state_f = sys.argv[1], sys.argv[2]
raw = open(new_f).read()
# 展开 include "glob" —— 真 nft 会做。桩不做的话, "自定义规则有没有进内核"那条断言
# 根本验不到东西(永远看不到规则, 也就永远是同一个结论)。
import glob as _g
_out = []
for _l in raw.split("\n"):
    _m = re.match(r'^\s*include\s+"([^"]+)"\s*$', _l)
    if _m:
        for _f in sorted(_g.glob(_m.group(1))):
            _out.append(open(_f).read().rstrip("\n"))
        continue
    _out.append(_l)
new = "\n".join(_out)
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
} > /usr/local/bin/nft
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
  rm -rf $E2E_TMP/e2e-svc; mkdir -p $E2E_TMP/e2e-svc
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

# ══ 2. 化解不了的 input 链冲突 → 安装前中止, 现场一个字节都不动 ═══════════
# 纯 accept 的现场现在会被自动搬进 nft-input.d 并照常装上(场景 7 守着那条路)。这里要验的是
# **化解不了时什么都不动**, 所以夹具里带一条 `drop` —— 那种规则不能自动搬(搬过去等于给用户
# 加限制, 是改变行为而不是保持行为)。
echo; echo "── 2. 已有自定义 input base chain(含搬不动的规则)──"
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
        tcp dport 23 drop
    }
}
NFT
nft -f /etc/nftables.conf
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
RULESET_SHA="$(sha256sum "$NFT_STATE" | cut -d' ' -f1)"
out=$(run_install ""); rc=$?
[[ "$rc" != 0 ]] && ok "化解不了的冲突 → 安装中止(返回非 0)" || bad "2: 竟然装成功了: $(tail -4 <<<"$out")"
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
: > $E2E_TMP/notexec; chmod 644 $E2E_TMP/notexec

put_py_stub(){   # 写一个 python3 桩(先删: 上一步可能留下指向真解释器的符号链接, 直接写会写穿)
  rm -f /usr/local/bin/python3
  cat > /usr/local/bin/python3
  chmod 755 /usr/local/bin/python3
}
restore_py(){ rm -f /usr/local/bin/python3; ln -sf /usr/local/bin/py3-real /usr/local/bin/python3; }
# 真实模拟"机器上没有 python3": 造一个 PATH 目录, 把系统各 bin 目录里的命令**除 python3**
# 全部软链进来, 然后只用它当 PATH。比 bind mount 可靠(bind 到符号链接上 `command -v` 仍能
# 找到), 也比"放个 exit 127 的桩"忠实 —— 后者是"python3 存在但坏了", 不是"没装"。
NOPY_BIN=$E2E_TMP/nopy-bin
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
reset_all(){ reset_box; rm -rf /opt/privdns-gateway; : > "${NFT_STATE:-$E2E_TMP/e2e-nft-ruleset}"; }

# 化解不了的冲突现场。带一条 `drop` —— 那种规则不能被自动搬进本项目的链(搬过去等于给用户
# 加限制, 是改变行为), 所以装机只能中止。纯 accept 的现场现在会被自动搬走并照常装上(场景 7),
# 那条路另有用例守着; 这里要验的是**化解不了时一个字节都不动现场**。
seed_conflict(){ cat > /etc/nftables.conf <<'NFT'
#!/usr/sbin/nft -f
table inet myfilter {
    chain input {
        type filter hook input priority 0; policy drop;
        tcp dport { 9443 } accept
        tcp dport 23 drop
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
{ printf '#!/bin/sh\nNOPY=%s\n' "$NOPY_BIN"       # 引号 heredoc 不展开, 路径从生成的头行注入
  cat <<'S'
for a in "$@"; do
  case "$a" in
    python3|python3-minimal) ln -sf /usr/local/bin/py3-real "$NOPY/python3" ;;
  esac
done
exit 0
S
} > /usr/local/bin/apt-get
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
  # 本节验的是"扫描器回 0/1/2 时 install 怎么做"这条既有语义。装机在冲突时还会再调一次
  # `nftscan.py --extract-accepts` 试着自动搬规则 —— 那条路另有场景 7 守着; 这里让它明确回 2
  # (搬不动), 否则桩的通配会把注入的那行文字当成"可搬的规则"喂进去, 本节就变成在验别的东西。
  put_py_stub <<S
#!/bin/sh
case "\$1 \$2" in
  */nftscan.py\ --nft-path) ;;                 # 放行: 这是问"nft 在哪", 不是扫描
  */nftscan.py\ --extract-accepts) echo "注入: 本节不验自动搬运" >&2; exit 2 ;;
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
rm -rf $E2E_TMP/repo-noscan && cp -a "$E2E_ROOT" $E2E_TMP/repo-noscan
rm -f $E2E_TMP/repo-noscan/deploy/bot/nftscan.py
out=$(env PDG_NONINTERACTIVE=1 PDG_SKIP_CERT=1 PDG_TAG_BOOTSTRAPPED=1 \
      PDG_SERVER_IP=203.0.113.1 PDG_SSH_PORT=22 PDG_INTERNAL_CIDR=127.0.0.0/8 \
      PDG_DOT_DOMAIN=dot.e2e.test PDG_BOT_TOKEN=123456:AAaa PDG_ALLOWED=1 PDG_PLATFORM=android \
      bash $E2E_TMP/repo-noscan/install.sh 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q '缺少防火墙冲突扫描器' <<<"$out"; } \
  && ok "扫描器文件缺失 → 中止并说明仓库不完整" || bad "4e: rc=$rc: $(tail -3 <<<"$out")"
rm -rf $E2E_TMP/repo-noscan
rm -f /usr/local/bin/py3-real $E2E_TMP/notexec; rm -rf "$NOPY_BIN"


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


# ══ 6. 自定义放行 include 点: 用户的规则活得过更新 ═══════════════════════════
# 报障那位用户的实际卡点: 他内核里 `inet filter` 的 input 链有 `tcp dport 80 accept`。
# 这道门拦得对(我们的 pdg 链是 policy drop, 不放行公网 80, 装上去他那条会被架空), 但以前给
# 的建议是"并入 table inet pdg 的 input chain" —— 那张表每次装机/迁移都按模板重建, 手加进去
# 的规则下次就没了, 等于**建议本身行不通**。
echo; echo "── 6. 自定义放行目录 ──"
reset_box
seed_clean
out="$(run_install "")"; rc=$?
[[ "$rc" == 0 ]] && ok "6 装机成功" || bad "6 装机失败(rc=$rc)"
[[ -d /etc/privdns-gateway/nft-input.d ]] \
  && ok "6 装机建出了自定义放行目录" || bad "6 没建目录"
[[ -e /etc/privdns-gateway/nft-input.d/README ]] \
  && ok "6 目录里有说明文件" || bad "6 没有说明"
[[ "$(ls /etc/privdns-gateway/nft-input.d/*.conf 2>/dev/null | wc -l)" == 0 ]] \
  && ok "6 说明文件不叫 .conf(不会被 include 进去当规则)" || bad "6 说明文件会被当成规则"
grep -qF 'include "/etc/privdns-gateway/nft-input.d/*.conf"' /etc/nftables.conf \
  && ok "6 防火墙配置里有 include 点" || bad "6 配置里没有 include"
# include 点必须在 pdg 表的 input chain 里, 而不是随便哪儿
python3 - <<'PY' && ok "6 include 点在 table inet pdg 的 input chain 内" || bad "6 include 点位置不对"
import re, sys
lines = open("/etc/nftables.conf", encoding="utf-8").read().split("\n")
i = next((k for k, l in enumerate(lines) if re.match(r"^table\s+inet\s+pdg\s*\{", l)), None)
if i is None: sys.exit(1)
depth, cs, ce = 0, None, None
for k in range(i, len(lines)):
    depth += lines[k].count("{") - lines[k].count("}")
    if cs is None and re.search(r"^\s*chain\s+input\s*\{", lines[k]): cs, cd = k, depth
    elif cs is not None and depth < cd: ce = k; break
sys.exit(0 if cs is not None and ce is not None
         and any("nft-input.d" in l for l in lines[cs:ce]) else 1)
PY

# 用户放一条规则进去 → 应用之后内核里要有它
printf 'tcp dport 9443 accept\n' > /etc/privdns-gateway/nft-input.d/10-mine.conf
if "$(command -v nft)" -f /etc/nftables.conf >/dev/null 2>&1; then
  grep -qF 'tcp dport 9443 accept' "$NFT_STATE" \
    && ok "6 自定义规则被 include 进运行 ruleset" || bad "6 自定义规则没生效"
else
  bad "6 应用带自定义规则的配置失败"
fi

# 关键: 再跑一次装机(模拟更新重建 pdg 表)——自定义规则必须还在。
# 覆盖重装要显式 PDG_FORCE_REINSTALL=1: install.sh 本来就拒绝在已有部署上重装(那是对的)。
out="$(run_install "PDG_FORCE_REINSTALL=1")"; rc=$?
[[ "$rc" == 0 ]] && ok "6 重跑装机成功" || bad "6 重跑失败(rc=$rc): $(tail -6 <<<"$out" | tr '\n' '|')"
[[ -f /etc/privdns-gateway/nft-input.d/10-mine.conf ]] \
  && ok "6 **重建 pdg 表之后, 用户的自定义规则文件仍在**" || bad "6 自定义规则被更新冲掉了"
grep -qF 'include "/etc/privdns-gateway/nft-input.d/*.conf"' /etc/nftables.conf \
  && ok "6 重建之后 include 点也还在" || bad "6 重建把 include 点弄丢了"

# doctor 要认这件事
python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc-nft.json 2>/dev/null
python3 - <<'PY' && ok "6 doctor: 自定义放行判 ok 并报出文件数" || bad "6 doctor 判定不对: $(head -c 200 $E2E_TMP/doc-nft.json)"
import json, os, sys
d = json.load(open(os.environ["E2E_TMP"] + "/doc-nft.json"))
hit = [x for x in d if x.get("check") == "自定义放行"]
sys.exit(0 if hit and hit[0]["level"] == "ok" and "10-mine.conf" in hit[0]["detail"] else 1)
PY

# 最坏的一种: 目录里有规则, 配置里却没 include —— 用户以为生效了, 其实一条没进内核
sed -i '/nft-input\.d/d' /etc/nftables.conf
python3 /opt/pdg-bot/doctor.py --json > $E2E_TMP/doc-nft2.json 2>/dev/null
python3 - <<'PY' && ok "6 有规则但没 include → doctor 判 fail(这种最容易被忽略)" || bad "6 doctor 没抓到"
import json, os, sys
d = json.load(open(os.environ["E2E_TMP"] + "/doc-nft2.json"))
hit = [x for x in d if x.get("check") == "自定义放行"]
sys.exit(0 if hit and hit[0]["level"] == "fail" else 1)
PY
rm -f /etc/privdns-gateway/nft-input.d/10-mine.conf $E2E_TMP/doc-nft.json $E2E_TMP/doc-nft2.json


# ══ 7. 自动搬运: 用户 input 链里的放行, 装机自己搬进 nft-input.d ══════════════
# 报障那位用户的实际卡点是 `tcp dport 80 accept`, 但跟端口无关 —— 80/443/WireGuard/
# node_exporter 甚至 SSH, 只要外来 input 链里有一条我们不放行的规则就会拦。让每个在网关上
# 还跑着别的服务的人都先手工改三步防火墙, 不现实。
#
# 关键认识: 问题不是"他有自己的 input 链", 而是本项目的 policy drop 架空了他的 accept。
# 把那些 accept **复制**一份进我们的链, 他的流量就通 —— 他自己那张表一个字节都不用改。
echo; echo "── 7. 装机自动搬运外来放行规则 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f
table inet filter {
        chain input {
                type filter hook input priority filter; policy accept;
                iif "lo" accept
                ct state established,related accept
                tcp dport 80 accept
                udp dport 51820 accept
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
		iif "lo" accept
		ct state established,related accept
		tcp dport 80 accept
		udp dport 51820 accept
	}
}
STATE
CONF_SHA="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
out="$(run_install "")"; rc=$?
ADOPT=/etc/privdns-gateway/nft-input.d/00-adopted-from-existing-firewall.conf
[[ "$rc" == 0 ]] && ok "7 有自定义放行的机器一把装上(不必先手工改防火墙)" \
  || bad "7 仍被拦(rc=$rc): $(grep -E '不兼容|中止' <<<"$out" | head -1)"
[[ -f "$ADOPT" ]] && ok "7 生成了自动搬运文件" || bad "7 没生成搬运文件"
grep -q '^tcp dport 80 accept$' "$ADOPT" 2>/dev/null \
  && ok "7 搬到了 tcp dport 80" || bad "7 没搬 80"
grep -q '^udp dport 51820 accept$' "$ADOPT" 2>/dev/null \
  && ok "7 搬到了 udp dport 51820(跟端口无关, 都能搬)" || bad "7 没搬 51820"
grep -q 'iif "lo"' "$ADOPT" 2>/dev/null \
  && bad "7 把我们本来就放行的也搬了(冗余)" || ok "7 我们已放行的那几条不重复搬"
grep -q '你原来那张表没有被改动' "$ADOPT" 2>/dev/null \
  && ok "7 文件里写清了来历与后续处理" || bad "7 搬运文件没有自我说明"
grep -q '已把你 input 链里的' <<<"$out" \
  && ok "7 终端上如实告知搬了哪些" || bad "7 终端没说"

# 用户自己那张表不许被动过 —— 我们只在自己的目录里加文件
python3 - <<'PY' && ok "7 用户的 inet filter 表逐字节未变(只在我们自己的目录加文件)" || bad "7 动了用户的表"
import re, sys
txt = open("/etc/nftables.conf", encoding="utf-8").read()
m = re.search(r"table inet filter \{.*?\n\}", txt, re.S)
sys.exit(0 if m and "tcp dport 80 accept" in m.group(0)
         and "udp dport 51820 accept" in m.group(0) else 1)
PY
# 真正的判据: 应用之后内核里我们的链也放行了 80
grep -qF 'tcp dport 80 accept' "$NFT_STATE" \
  && ok "7 运行 ruleset 里能看到被搬过来的放行" || bad "7 搬过来的规则没进内核"

# ── 7b. 搬不动的(drop / limit)→ 照旧中止并点名, 不硬来 ──
echo "── 7b. 有搬不动的规则 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f
table inet filter {
        chain input {
                type filter hook input priority filter; policy accept;
                tcp dport 80 accept
                tcp dport 23 drop
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 80 accept
		tcp dport 23 drop
	}
}
STATE
CONF_SHA2="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
out="$(run_install "")"; rc=$?
[[ "$rc" != 0 ]] && ok "7b 有 drop 规则 → 中止(搬过去会改变行为)" || bad "7b 竟然装成功了"
grep -q '判决不是 accept' <<<"$out" \
  && ok "7b 点名了搬不动的那条与原因" || bad "7b 没点名: $(tail -4 <<<"$out")"
[[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$CONF_SHA2" ]] \
  && ok "7b 中止后用户配置逐字节未变" || bad "7b 改了用户配置"
[[ -f /etc/privdns-gateway/nft-input.d/00-adopted-from-existing-firewall.conf ]] \
  && bad "7b 中止了却留下了半截搬运文件" || ok "7b 中止时不留半截文件"

# ── 7c. PDG_NO_ADOPT_RULES=1 → 用户说别搬就别搬 ──
echo "── 7c. PDG_NO_ADOPT_RULES=1 ──"
reset_box
cat > /etc/nftables.conf <<'CONF'
#!/usr/sbin/nft -f
table inet filter {
        chain input {
                type filter hook input priority filter; policy accept;
                tcp dport 80 accept
        }
}
CONF
cat > "$NFT_STATE" <<'STATE'
table inet filter {
	chain input {
		type filter hook input priority filter; policy accept;
		tcp dport 80 accept
	}
}
STATE
out="$(run_install "PDG_NO_ADOPT_RULES=1")"; rc=$?
[[ "$rc" != 0 ]] && ok "7c 设了 PDG_NO_ADOPT_RULES=1 → 保持中止" || bad "7c 设了开关还是搬了"
[[ -f /etc/privdns-gateway/nft-input.d/00-adopted-from-existing-firewall.conf ]] \
  && bad "7c 设了开关却仍生成了搬运文件" || ok "7c 没生成搬运文件"

rm -f "$NFT_STATE"
# ══ 8. 全新安装时 geosite 拿不到 → 只是"分类为空", 不该整场安装失败回滚 ═══════
# 用户现场(2026-07-30, 全新 Debian 13, v1.7.7): 装机走到"下载并解析 geosite 规则库"这步,
# 事务回了
#     REFUSED: 操作前这些硬门就是坏的: svc:mosdns, dns:127.0.0.1:53, port:853
# —— normal 模式那道"操作前组件就是坏的就别动它"的前置门。日常更新时它是对的; 但装机时
# mosdns 本来就还没起、53/853 本来就还没人听, 那不是"坏了"而是"还没装完"。于是规则文件一个
# 都没落盘, mosdns 的 domain_set 缺文件直接 FATAL, 重启 7 次后装机判定失败并回滚。
#
# 两处都要治: 装机侧用 repair 模式开事务; 同时先把 geosite 文件建成空的 —— 下载失败(没网、
# 源站抽风、被墙)本就该退化成"分类规则暂时是空的", 而不是"这台机器装不上"。
echo; echo "── 8. 装机时 geosite 下载失败 ──"
reset_box
seed_clean
# 只掐 geosite 那个下载, 其余 curl 照常(装机还要靠它拿别的东西)
REAL_CURL="$(command -v curl)"
cat > /usr/local/bin/curl <<S
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *geosite.dat*) echo "curl: (6) could not resolve host" >&2; exit 6 ;; esac
done
exec "$REAL_CURL" "\$@"
S
chmod 755 /usr/local/bin/curl
out="$(run_install "")"; rc=$?
[[ "$rc" == 0 ]] && ok "8 geosite 下载失败, 装机仍然成功(不再整场回滚)" \
  || bad "8 装机失败(rc=$rc): $(grep -E 'REFUSED|安装失败|未能持续' <<<"$out" | head -2 | tr '\n' ' ')"
grep -qE 'geosite 下载失败' <<<"$out" \
  && ok "8 如实告知下载失败" || bad "8 没告知下载失败"
grep -q '分类规则是空的' <<<"$out" \
  && ok "8 说清了影响(分类规则为空)而不是含糊带过" || bad "8 没说清影响"
grep -q '更新规则库' <<<"$out" \
  && ok "8 给了补救办法" || bad "8 没给补救办法"

# 判据本身: mosdns 配置里点名的每个规则文件都必须存在 —— 缺一个 mosdns 就 FATAL 起不来,
# 这正是用户那台机器起不来的直接原因。
python3 - <<'PY' && ok "8 config.yaml 里点名的规则文件全都存在(mosdns 能起来)" || bad "8 仍有规则文件缺失"
import os, re, sys
try:
    cfg = open("/etc/mosdns/config.yaml", encoding="utf-8").read()
except OSError as e:
    print("读不到 config.yaml:", e); sys.exit(1)
want = sorted(set(re.findall(r"(/etc/mosdns/rules/[^\s\"']+\.txt)", cfg)))
if not want:
    print("配置里一个规则文件都没点名 —— 断言无从成立"); sys.exit(1)
missing = [f for f in want if not os.path.exists(f)]
print("点名 %d 个, 缺 %d 个: %s" % (len(want), len(missing), missing[:5]))
sys.exit(1 if missing else 0)
PY
# 且确实是空的(证明上面那条不是靠"下载其实成功了"蒙混过关)
[[ -f /etc/mosdns/rules/geosite_cn.txt && ! -s /etc/mosdns/rules/geosite_cn.txt ]] \
  && ok "8 geosite_cn.txt 存在且为空(确认走的就是下载失败这条路)" \
  || bad "8 geosite_cn.txt 不是『存在且为空』, 这一节没验到下载失败的场景"
rm -f /usr/local/bin/curl

# ── 8b. 下载成功、但事务被那道前置硬门拒掉 ── 用户现场就是这一半 ──
# 直接跑真的 update-rules.sh, 不看源码字面量: 装机现场的特征是 mosdns 还没起、53/853 还没人
# 听 —— 硬门基线本来就是坏的。normal 模式必须拒(这道门对日常更新是对的, 不能拆),
# 装机侧的 repair 模式必须能写进去。
echo "── 8b. 下载成功但事务被拒 ──"
cat > /usr/local/bin/curl <<'S'
#!/bin/sh
o=""; while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift;; esac; shift; done
[ -n "$o" ] && echo dummy > "$o"
exit 0
S
chmod 755 /usr/local/bin/curl
cat > /opt/pdg-bot/parse-geosite.py <<'S'
import sys, os
os.makedirs(sys.argv[2], exist_ok=True)
for n in ("geosite_cn", "geosite_apple"):
    open(os.path.join(sys.argv[2], n + ".txt"), "w").write("domain:e2e-%s.test\n" % n)
S
: > /etc/mosdns/rules/geosite_cn.txt          # 回到"规则库是空的"
# 造出装机现场的基线: mosdns 还没起来。装完的沙箱里硬门是好的 —— 不先弄成降级状态,
# 这一节就什么都验不到(照样通过, 等于没验)。
e2e_svc_fail mosdns
systemctl is-active --quiet mosdns \
  && bad "8b 基线没能弄成降级状态, 本节前提不成立" \
  || ok "8b 前提成立: mosdns 未运行(与装机现场一致)"
out8b="$(bash /opt/pdg-bot/update-rules.sh 2>&1)"; rc8b=$?
[[ "$rc8b" != 0 ]] && ok "8b 日常更新(normal): 硬门坏着就拒 —— 那道门没被拆掉" \
  || bad "8b normal 模式竟然放行了, 前置硬门形同虚设"
grep -q '操作前这些硬门就是坏的' <<<"$out8b" \
  && ok "8b 拒绝理由正是用户报的那条" || bad "8b 拒绝理由不对: $(head -2 <<<"$out8b")"
[[ -s /etc/mosdns/rules/geosite_cn.txt ]] \
  && bad "8b 被拒了却把文件写进去了" || ok "8b 被拒时旧规则库原样不动"

out8c="$(PDG_TX_MODE=repair bash /opt/pdg-bot/update-rules.sh 2>&1)"; rc8c=$?
[[ "$rc8c" == 0 ]] && ok "8b 装机模式(repair): 同样的基线下写得进去" \
  || bad "8b repair 模式也失败(rc=$rc8c): $(head -3 <<<"$out8c" | tr '\n' ' ')"
grep -q 'domain:e2e-geosite_cn.test' /etc/mosdns/rules/geosite_cn.txt 2>/dev/null \
  && ok "8b 规则真的落到了 /etc/mosdns/rules(装机因此拿得到规则库)" \
  || bad "8b 文件没落盘: $(head -c 120 /etc/mosdns/rules/geosite_cn.txt 2>&1)"
rm -f /usr/local/bin/curl

e2e_summary
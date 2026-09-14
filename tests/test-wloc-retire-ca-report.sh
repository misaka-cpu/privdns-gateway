#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WLOC 退役 · **旧 CA 残留报告**的平台无关性与三态处理(PDG-WLOC-CAREPORT-02)。
#
# 缺陷长这样: `_retire_ca_report` 只在 `$R/opt/pdg-bot` 下找 mitm_ca, 而 mitm_ca.py 属于
# lib/modules.sh 的 **PDG_IOS_MODULES** —— Android 按平台契约根本不装它。于是一台从 iOS
# 切到 Android、盘上还留着根证书与私钥的机器, 退役迁移**一个字都不报**:
# ModuleNotFoundError 被 `except Exception: sys.exit(0)` 吞成空串, 上层 case 一个分支都不
# 匹配, 连它自己那条「无法确认」都不打。用户因此永远不知道手机上那份信任还要自己去撤。
#
# 而代码自己点名要覆盖这一格:
#   「**CA-only 的机器也要走到报告那一段**: 服务、劫持、模块都干净了, 而盘上那张根证书还在、
#     手机上那份信任也还在 —— 不说的话, 用户永远不知道还有这一步要做。」
#
# 判据分两层:
#   · 行为: A/B 两种模块布局下**报告语义必须一致**; C/D/E 三态各自具名, 一态都不许落空;
#   · 反向: 撤掉"第二个读取位置"要命中「Android 实际残留却未报告」这条**具名断言**;
#           撤掉兜底分支要命中「检查失败却静默」——都不是靠夹具崩溃或缺前像。
#
# 纪律: 只用 sed 抽函数(不 source 整个 pdg.sh —— 那会跑主入口), 只在一次性临时根里造现场,
# 不写任何生产目录、不启动任何服务、不回显证书或私钥正文。
# 退出码 0=全过。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="$ROOT/deploy/bot/pdg.sh"
BOX="$(mktemp -d)"; trap 'rm -rf "$BOX"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }
command -v openssl >/dev/null 2>&1 || { bad "缺 openssl, 造不出自造 CA"; echo "通过 0, 失败 1"; exit 1; }

# 单行定义与多行定义分开抽: c_* 是单行, _retire_* 是多行(区间到独占一行的 `}`)。
_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }

# 组装一个只含"报告路径"的可执行环境。$1 = 用哪份 pdg.sh
mk_runner(){
  local src="$1" s="$BOX/runner.sh"
  {
    echo 'set -uo pipefail'
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r      # **产品真实的输出函数**, 测试不补替代实现
    grep -m1 -E '^REPO_DIR=' "$src"                        # 路径常量也从产品里取, 免得漂移
    _fnN "$src" _retire_ca_reader_dir
    _fnN "$src" _retire_ca_report
    _fnN "$src" _retire_report_ca
    echo '_retire_report_ca "$1"'
  } > "$s"
  printf '%s\n' "$s"
}

# 造一台机器。$1=名字 $2=模块布局(ios|android|noreader|brokenreader) $3=CA 形态(full|keyonly|none|damaged)
mkroot(){
  local name="$1" layout="$2" ca="$3"
  local d="$BOX/$name"
  mkdir -p "$d/opt/pdg-bot" "$d/opt/privdns-gateway/deploy/bot" "$d/etc/privdns-gateway"
  case "$layout" in
    ios)   cp "$ROOT/deploy/bot/mitm_ca.py" "$ROOT/deploy/bot/iosprofile.py" "$d/opt/pdg-bot/";;
    android)
      # 平台契约: Android 不装 iOS 专属件; 但 /opt/privdns-gateway 这份受管源码两平台都有。
      cp "$ROOT/deploy/bot/mitm_ca.py" "$ROOT/deploy/bot/iosprofile.py" "$d/opt/privdns-gateway/deploy/bot/";;
    noreader) : ;;                                    # 两处都没有
    brokenreader)
      printf 'def broken(:\n' > "$d/opt/pdg-bot/mitm_ca.py"
      cp "$ROOT/deploy/bot/iosprofile.py" "$d/opt/pdg-bot/";;
  esac
  if [[ "$ca" != none ]]; then
    mkdir -p "$d/etc/privdns-gateway/ca"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
      -keyout "$d/etc/privdns-gateway/ca/ca.key" -out "$d/etc/privdns-gateway/ca/ca.crt" \
      -subj "/CN=pdg-careport-test" >/dev/null 2>&1
    chmod 700 "$d/etc/privdns-gateway/ca"; chmod 600 "$d/etc/privdns-gateway/ca/ca.key"
    chmod 644 "$d/etc/privdns-gateway/ca/ca.crt"
    case "$ca" in
      keyonly) rm -f "$d/etc/privdns-gateway/ca/ca.crt";;
      damaged) printf 'not a pem at all\n' > "$d/etc/privdns-gateway/ca/ca.crt";;
    esac
  fi
  printf '%s\n' "$d"
}

# 现场指纹: 报告是只读的, 前后必须逐字节一致(含 mode 与存在性)。
fp(){ ( cd "$1" && find . -path ./opt -prune -o -print0 2>/dev/null \
        | xargs -0 -I{} sh -c 'printf "%s %s\n" "{}" "$(stat -c %a "{}" 2>/dev/null)"' | sort ) | sha256sum; }

run_report(){   # $1=runner $2=root → stdout 落 $BOX/out, stderr 落 $BOX/err
  bash "$1" "$2" > "$BOX/out" 2> "$BOX/err"
}

say(){ cat "$BOX/out"; }

# ── 产品侧前提: c_r 必须仍然是产品自己定义的 ────────────────────────────────
DEFS="$(grep -cE '^c_r\(\)' "$PDG")"
[[ "$DEFS" == 1 ]] && ok "产品里 c_r 仍有且只有一处定义(PDG-WLOC-CR-01 的修复还在)" \
                   || bad "产品里 c_r 定义数 = $DEFS"
grep -qE '^[[:space:]]*c_r\(\)' "${BASH_SOURCE[0]}" \
  && bad "本测试自己定义了 c_r —— 那是拿夹具替生产补函数" \
  || ok "本测试不提供任何 c_* 的替代实现(全部从产品文件里抽)"

# ══ A. Android 形态: 没有 iOS 专属件, 盘上有真实自造 CA ═════════════════════
echo; echo "══ A. Android(无 iOS 专属件) + 盘上有 CA ══"
dA="$(mkroot A android full)"; fpA="$(fp "$dA")"
[[ ! -e "$dA/opt/pdg-bot/mitm_ca.py" ]] && ok "A 前提: /opt/pdg-bot 下**确实没有** mitm_ca.py(平台契约)" \
                                        || bad "A 前提没造对"
[[ -s "$dA/etc/privdns-gateway/ca/ca.key" && -s "$dA/etc/privdns-gateway/ca/ca.crt" ]] \
  && ok "A 前提: 盘上确有自造 CA 证书与私钥" || bad "A 前提: 没造出 CA"
run_report "$(mk_runner "$PDG")" "$dA"
say | sed 's/^/    /'
grep -q '盘上仍有 WLOC 时期的 CA 材料' "$BOX/out" \
  && ok "A: **Android 上也报告了 CA 残留**" \
  || bad "A: Android 实际残留却未报告(这正是 PDG-WLOC-CAREPORT-02)"
grep -q '证书信任设置' "$BOX/out" && ok "A: 给出了手机端撤信任指引" || bad "A: 没有撤信任指引"
grep -q 'command not found' "$BOX/err" && bad "A: stderr 有未定义函数: $(head -1 "$BOX/err")" \
                                       || ok "A: stderr 干净(command not found 为 0)"
[[ "$(fp "$dA")" == "$fpA" ]] && ok "A: 报告是只读的 —— CA 目录与文件的存在性/权限前后一致" \
                             || bad "A: 报告动了盘上的东西"

# ══ B. iOS 形态: 同一份 CA, 模块在 /opt/pdg-bot ═════════════════════════════
echo; echo "══ B. iOS(有 iOS 专属件) + 同样的 CA ══"
dB="$(mkroot B ios full)"; fpB="$(fp "$dB")"
run_report "$(mk_runner "$PDG")" "$dB"
say | sed 's/^/    /'
grep -q '盘上仍有 WLOC 时期的 CA 材料' "$BOX/out" && ok "B: iOS 形态同样报告了 CA 残留" || bad "B: iOS 形态没报"
grep -q '证书信任设置' "$BOX/out" && ok "B: 撤信任指引一致" || bad "B: 没有撤信任指引"
[[ "$(fp "$dB")" == "$fpB" ]] && ok "B: 只读, 现场未变" || bad "B: 动了盘上的东西"
# 语义一致: 两种布局的报告正文必须一样(差别只在模块在哪儿, 不在说什么)
run_report "$(mk_runner "$PDG")" "$dA"; cpA="$(sed "s|$dA||g" "$BOX/out")"
run_report "$(mk_runner "$PDG")" "$dB"; cpB="$(sed "s|$dB||g" "$BOX/out")"
[[ "$cpA" == "$cpB" ]] && ok "A/B: 两种模块布局下的报告正文**逐字一致**(不因布局不同而静默或改口)" \
                       || bad "A/B: 报告正文不一致"

# ══ C. 确认没有材料 ════════════════════════════════════════════════════════
echo; echo "══ C. 确认没有 CA 材料 ══"
dC="$(mkroot C android none)"
run_report "$(mk_runner "$PDG")" "$dC"
say | sed 's/^/    /'
[[ ! -s "$BOX/out" ]] && ok "C: 确认不在 ⇒ 不说话(absent 这一格显式命中, 没掉进兜底)" \
                      || bad "C: 没有材料却说了话: $(head -2 "$BOX/out")"
grep -q '无法确认' "$BOX/out" 2>/dev/null && bad "C: 把「确认不在」误报成「无法确认」" || ok "C: 没有误报为无法确认"
[[ ! -e "$dC/etc/privdns-gateway/ca" ]] && ok "C: **没有**凭空创建 CA 目录" || bad "C: 冒出了 CA 目录"
[[ -z "$(find "$dC" -name '*.lock' -o -name 'ca.key' 2>/dev/null)" ]] \
  && ok "C: 没有创建私钥或锁文件" || bad "C: 创建了不该有的文件"

# ══ D. 说不清的两种: 材料损坏 / 检查器跑不了 ═══════════════════════════════
echo; echo "══ D1. 材料损坏(证书不是合法 PEM)══"
dD1="$(mkroot D1 android damaged)"; fpD1="$(fp "$dD1")"
run_report "$(mk_runner "$PDG")" "$dD1"
say | sed 's/^/    /'
grep -q '没通过校验' "$BOX/out" && ok "D1: 具名报出「证书没通过校验」" || bad "D1: 没报出损坏"
grep -q '证书信任设置' "$BOX/out" && ok "D1: 仍然提醒手机端撤信任" || bad "D1: 漏了撤信任提醒"
grep -qi 'not a pem' "$BOX/out" && bad "D1: 回显了待检正文" || ok "D1: 没有回显证书正文"
[[ "$(fp "$dD1")" == "$fpD1" ]] && ok "D1: 只读, 现场未变" || bad "D1: 动了盘上的东西"

echo; echo "══ D2. 检查器无法运行(mitm_ca.py 在, 但是坏的)══"
dD2="$(mkroot D2 brokenreader full)"
run_report "$(mk_runner "$PDG")" "$dD2"
say | sed 's/^/    /'
grep -q '无法确认' "$BOX/out" \
  && ok "D2: 检查失败 ⇒ 具名报「无法确认」(没有静默, 也没冒充「没有 CA」)" \
  || bad "D2: 检查失败却静默 —— 空串落空"
grep -qE '无法完成检查|没有任何产出|找不到只读检查器' "$BOX/out" \
  && ok "D2: 说清了是哪一种说不清" || bad "D2: 没给出具名原因"

echo; echo "══ D3. 两处都没有检查器 ══"
dD3="$(mkroot D3 noreader full)"
run_report "$(mk_runner "$PDG")" "$dD3"
say | sed 's/^/    /'
grep -q '无法确认' "$BOX/out" && ok "D3: 找不到检查器 ⇒ 仍然具名提示, 不静默" || bad "D3: 静默了"
grep -q '找不到只读检查器' "$BOX/out" && ok "D3: 原因写明是「找不到检查器」" || bad "D3: 原因不具名"

# ══ E. CA-only(证书没了、私钥还在)══════════════════════════════════════════
echo; echo "══ E. 只剩私钥(签发原料仍在盘上)══"
dE="$(mkroot E android keyonly)"; fpE="$(fp "$dE")"
run_report "$(mk_runner "$PDG")" "$dE"
say | sed 's/^/    /'
grep -q '盘上仍有 WLOC 时期的 CA 材料' "$BOX/out" \
  && ok "E: 只剩私钥也照实报告(residue)" || bad "E: 私钥还在却没报"
[[ -s "$dE/etc/privdns-gateway/ca/ca.key" ]] && ok "E: 私钥仍在(按保留策略未删)" || bad "E: 私钥被删了"
[[ "$(stat -c %a "$dE/etc/privdns-gateway/ca/ca.key")" == 600 ]] \
  && ok "E: 私钥权限仍是 600" || bad "E: 私钥权限被改了"
[[ "$(fp "$dE")" == "$fpE" ]] && ok "E: 只读, 现场未变" || bad "E: 动了盘上的东西"

# ══ 反向对照 ═══════════════════════════════════════════════════════════════
echo; echo "══ 反向对照 ①: 撤掉「第二个读取位置」 ══"
NOFB="$BOX/pdg-no-fallback.sh"
sed 's|for d in "$R/opt/pdg-bot" "$R${REPO_DIR}/deploy/bot"; do|for d in "$R/opt/pdg-bot"; do|' "$PDG" > "$NOFB"
if ! cmp -s "$PDG" "$NOFB"; then
  ok "反向副本就位(只改 _retire_ca_reader_dir 的搜索位置这一行)"
  run_report "$(mk_runner "$NOFB")" "$dA"
  say | sed 's/^/    /'
  grep -q '盘上仍有 WLOC 时期的 CA 材料' "$BOX/out" \
    && bad "反向①: 撤掉之后居然还报得出来 —— 判据抓不住这个缺陷" \
    || ok "反向①: **命中「Android 实际残留却未报告」** —— 撤掉依赖修复就转红"
  grep -q '无法确认' "$BOX/out" \
    && ok "反向①: 退化后至少还落到兜底的「无法确认」(说明兜底那条是另一处独立保护)" \
    || bad "反向①: 连兜底都没打, 说明夹具自己崩了而不是缺陷复现"
else
  bad "反向①: 没造出反向副本(锚点漂了), 对照失效"
fi

echo; echo "══ 反向对照 ②: 撤掉兜底分支 ══"
NOCATCH="$BOX/pdg-no-catchall.sh"
python3 - "$PDG" "$NOCATCH" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
i = s.index('    *)\n      # unknown / 空产出 / 格式异常都落在这里')
j = s.index('  esac', i)
open(dst, "w", encoding="utf-8").write(s[:i] + s[j:])
PY
if ! cmp -s "$PDG" "$NOCATCH"; then
  ok "反向副本②就位(只删 case 的兜底分支)"
  run_report "$(mk_runner "$NOCATCH")" "$dD2"
  say | sed 's/^/    /'
  [[ -s "$BOX/out" ]] \
    && bad "反向②: 删了兜底居然还有输出 —— 判据抓不住" \
    || ok "反向②: **命中「检查失败却静默」** —— 删掉兜底分支就一个字都不报了"
else
  bad "反向②: 没造出反向副本, 对照失效"
fi

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

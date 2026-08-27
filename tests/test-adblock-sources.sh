#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 第三方源可配: `pdg adblock source list|add <URL>|del <URL>|reset`。
#
# 现状是 anti-AD 写死在 DEFAULT_SOURCES 里, 用户换不了 —— 那是一直开着的 P3
# 「单一默认源, 无自动回退」的后半句。前半句其实早就有: update_lists 会按顺序遍历 sources
# 并在失败时退到下一个, 只是没有任何接口能把用户的源传进去。
#
# 这一支钉接口契约与存储语义:
#   · 源存在 /etc/privdns-gateway/adblock-sources.txt, 一行一个, 允许 # 注释;
#   · 文件缺失或为空 → 沿用内置默认(向后兼容: 老机器升上来行为不变);
#   · add 时就按下载器的规矩校验 URL(https / 443 / 非 IP 字面量), 当场拒, 不拖到 update;
#   · add 幂等, del 精确匹配且删不存在的要报错, reset 回到默认;
#   · 任何一步失败都不写文件;
#   · 用户源是**用户数据**, 必须进版本快照。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT

extract(){
  local fn="$1" ln
  ln="$(grep -n "^${fn}()" "$ROOT/deploy/bot/pdg.sh" | head -1 | cut -d: -f1)"
  [[ -n "$ln" ]] || { echo "抽不到 $fn" >&2; return 1; }
  if sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)\{.*\}[[:space:]]*$'; then
    sed -n "${ln}p" "$ROOT/deploy/bot/pdg.sh"
  else
    sed -n "${ln},/^}/p" "$ROOT/deploy/bot/pdg.sh"
  fi
}
CLOSURE="$WORK/closure.sh"; : > "$CLOSURE"
for fn in c_g c_y _pdg_module _adblock_intent _adblock_ensure_files _adblock_status cmd_adblock; do
  extract "$fn" >> "$CLOSURE" || { bad "抽不到 $fn"; echo "通过 $pass, 失败 $nfail"; exit 1; }
  echo >> "$CLOSURE"
done
# pdg.sh 的**顶层常量**整体注入。只抽函数会漏掉它们, 而 pdg.sh 跑在 `set -u` 下 ——
# 漏一个就是 unbound variable, 而且往往只在某条分支上炸(本地与 CI 失败点不同, 就成了假绿)。
# 这一类缺口已经栽过三次: PDG_LOCKED、LOCK、ACME_HOME。不再一个个补, 整体注入了事。
# 安全性: 这 34 条里**零条含命令替换**(`grep -cE '^[A-Z][A-Z0-9_]*=.*\$\(' = 0`), 纯字面量
# 与变量引用, 注入不会执行任何东西。沙箱随后 export 的同名变量会覆盖它们。
grep -E '^[A-Z][A-Z0-9_]*=' "$ROOT/deploy/bot/pdg.sh" \
  | sed -E 's/^([A-Z][A-Z0-9_]*)=(.*)$/\1="${\1:-}"; [[ -z "${\1}" ]] \&\& \1=\2/' >> "$CLOSURE"
cat >> "$CLOSURE" <<'STUB'
need_root(){ :; }
_lock(){ :; }
PDG_LOCKED=""
STUB

# §6 的接缝: 把这个 box 的 adblock.py 换成一层薄壳。`update` 只调**真模块**的 read_sources()
# 把生效源打印出来, 不出网; 其余子命令 execv 原样转交真模块。
#
# 为什么必须这样: 原来那格直接断言 update 的真实输出里含用户源的主机名 —— 它**只在跑测试
# 的机器能连外网时才绿**。我本地能连, 所以本地 25/0; CI 连不上, 抓到 0 条, 于是红。这既是
# 假绿, 也违反"CI 不碰真实 anti-AD 网络"。壳挡掉的只有 socket 那一层: pdg.sh 是否把
# $ADB_SOURCES 交下去、真模块是否据此解析出用户源而非内置默认, 两件事都仍在真代码里跑。
shim_module(){
  local w="$1" d f
  d="$w/repo/deploy/bot"
  rm -f "$d"; mkdir -p "$d"
  for f in "$ROOT/deploy/bot"/*; do ln -sfn "$f" "$d/$(basename "$f")"; done
  rm -f "$d/adblock.py"
  cat > "$d/adblock.py" <<PYEOF
import os, sys, importlib.util
REAL = "$ROOT/deploy/bot/adblock.py"
if len(sys.argv) > 1 and sys.argv[1] == "update":
    spec = importlib.util.spec_from_file_location("adblock_real", REAL)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    for u in m.read_sources(sys.argv[3] if len(sys.argv) > 3 else None):
        print("WOULD-FETCH " + u)
    sys.exit(0)
os.execv(sys.executable, [sys.executable, REAL] + sys.argv[1:])
PYEOF
}

new_box(){
  local w="$WORK/$1"; mkdir -p "$w/etc/privdns-gateway" "$w/etc/mosdns/rules" "$w/var/adblock" "$w/repo/deploy" "$w/bin"
  ln -sfn "$ROOT/deploy/bot" "$w/repo/deploy/bot"
  : > "$w/etc/mosdns/rules/adblock_allow.txt"; : > "$w/etc/mosdns/rules/adblock_block.txt"
  printf 'PDG_INTERNAL_CIDR=172.22.0.0/16\n' > "$w/etc/privdns-gateway/profile.env"
  echo "$w"
}
run_box(){
  local w="$1" body="$2"
  ( set +e
    PATH="$w/bin:$PATH"; export PATH
    REPO_DIR="$w/repo"; PROFILE_ENV="$w/etc/privdns-gateway/profile.env"
    ADB_STATE_DIR="$w/var/adblock"
    ADB_USER_ALLOW="$w/etc/mosdns/rules/adblock_allow.txt"
    ADB_USER_BLOCK="$w/etc/mosdns/rules/adblock_block.txt"
    ADB_SOURCES="$w/etc/privdns-gateway/adblock-sources.txt"
    LOCK="$w/pdg.lock"
    export REPO_DIR PROFILE_ENV ADB_STATE_DIR ADB_USER_ALLOW ADB_USER_BLOCK ADB_SOURCES LOCK
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$body"
  ) > "$w/out.log" 2>&1
  echo $?
}
srcfile(){ echo "$1/etc/privdns-gateway/adblock-sources.txt"; }
U1="https://gcore.jsdelivr.net/gh/217heidai/adblockfilters@main/rules/adblockmosdns.txt"
U2="https://example.invalid/list.txt"

echo "══ ① 子命令存在 ══"
W="$(new_box s1)"; run_box "$W" 'cmd_adblock source list' >/dev/null
grep -q '用法: pdg adblock' "$W/out.log" && bad "source 落到了用法分支 —— 尚未实现" || ok "source 已被 cmd_adblock 识别"

echo
echo "══ ② 缺文件时沿用内置默认(向后兼容)══"
W="$(new_box s2)"; run_box "$W" 'cmd_adblock source list' >/dev/null
grep -qi 'anti-ad' "$W/out.log" && ok "list 在无用户源时列出内置默认" || bad "没列出内置默认: $(head -2 "$W/out.log"|tr '\n' ' ')"
[[ ! -e "$(srcfile "$W")" ]] && ok "list 是只读的, 没有凭空建出源文件" || bad "list 建了文件"

echo
echo "══ ③ add: 落盘 + 幂等 ══"
W="$(new_box s3)"
rc="$(run_box "$W" "cmd_adblock source add '$U1'")"
[[ "$rc" == 0 ]] && ok "add 合法 https URL 成功(rc=0)" || bad "rc=$rc: $(tail -2 "$W/out.log"|tr '\n' ' ')"
grep -qxF "$U1" "$(srcfile "$W")" 2>/dev/null && ok "URL 逐字落盘" || bad "没落盘"
before="$(sha256sum "$(srcfile "$W")" 2>/dev/null|cut -c1-16)"
rc="$(run_box "$W" "cmd_adblock source add '$U1'")"
[[ "$rc" == 0 ]] && ok "重复 add 幂等返回 0" || bad "重复 add rc=$rc"
[[ "$(sha256sum "$(srcfile "$W")" 2>/dev/null|cut -c1-16)" == "$before" ]] && ok "重复 add 文件逐字节未变" || bad "重复 add 改了文件"

echo
echo "══ ④ add 的 URL 门(当场拒, 不拖到 update)══"
W="$(new_box s4)"
for u in 'http://plain.example.com/l.txt' 'https://example.com:8443/l.txt' 'https://192.0.2.1/l.txt' 'ftp://x.example.com/l.txt' 'not-a-url'; do
  rc="$(run_box "$W" "cmd_adblock source add '$u'")"
  [[ "$rc" != 0 ]] && ok "拒绝 $u (rc=$rc)" || bad "竟然接受了 $u"
done
[[ ! -s "$(srcfile "$W")" ]] && ok "全部被拒后源文件仍为空" || bad "被拒的 URL 却落盘了: $(cat "$(srcfile "$W")" 2>/dev/null|tr '\n' ' ')"

echo
echo "══ ⑤ del 精确匹配 / reset 回默认 ══"
W="$(new_box s5)"
run_box "$W" "cmd_adblock source add '$U1'" >/dev/null
run_box "$W" "cmd_adblock source add '$U2'" >/dev/null
[[ "$(grep -c . "$(srcfile "$W")" 2>/dev/null)" == 2 ]] && ok "两个源都在" || bad "源数 $(grep -c . "$(srcfile "$W")" 2>/dev/null)"
rc="$(run_box "$W" "cmd_adblock source del '$U1'")"
{ [[ "$rc" == 0 ]] && grep -qxF "$U2" "$(srcfile "$W")" && ! grep -qxF "$U1" "$(srcfile "$W")"; } \
  && ok "del 只删掉指定的那一条" || bad "del 结果不对: $(cat "$(srcfile "$W")" 2>/dev/null|tr '\n' ' ')"
rc="$(run_box "$W" "cmd_adblock source del 'https://never-added.example.com/x.txt'")"
[[ "$rc" != 0 ]] && ok "del 不存在的源返回非零" || bad "del 不存在的源返回 0"
rc="$(run_box "$W" 'cmd_adblock source reset')"
[[ "$rc" == 0 ]] && ok "reset 返回 0" || bad "reset rc=$rc"
[[ ! -s "$(srcfile "$W")" ]] && ok "reset 后源文件为空(回到内置默认)" || bad "reset 没清空"

echo
echo "══ ⑥ update 真的用用户源 ══"
W="$(new_box s6)"; shim_module "$W"
run_box "$W" "cmd_adblock source add '$U1'" >/dev/null
run_box "$W" 'cmd_adblock update' >/dev/null 2>&1
out="$(cat "$W/out.log")"
grep -qF "gcore.jsdelivr.net" <<<"$out" \
  && ok "update 试的是用户配置的源" || bad "update 没有用上用户源: $(echo "$out"|tail -2|tr '\n' ' ')"
grep -qF "anti-ad.net" <<<"$out" \
  && bad "update 仍在试内置默认源(应当已被用户配置替换)" || ok "内置默认源没有被再试一遍"

echo
echo "══ ⑦ 用户源是用户数据, 必须进版本快照 ══"
grep -q 'adblock-sources' "$ROOT/deploy/bot/cfgrestore.py" \
  && ok "cfgrestore 的快照表里登记了 adblock-sources" || bad "源文件没进快照 —— 回滚会丢用户配置"

echo
echo "══ ⑧ 白名单跟着源走, 但只跟着**配置过的**源走 ══"
# 选的是"白名单从 内置默认 + 用户配置 算出来"这条路。安全价值在后面几道(零重定向 /
# 非公网拒绝 / DNS-连接绑定 / TLS 校验), 它们一条不松; 白名单在这里挡的是"URL 被改成
# 任意主机"。用户显式 source add 本身就是授权 —— 但**没 add 过的主机必须照样连不上**,
# 否则等于把这道门废了。
W="$(new_box s8)"
run_box "$W" "cmd_adblock source add '$U1'" >/dev/null
python3 - "$ROOT" "$(srcfile "$W")" <<'PY'
import sys, urllib.parse
sys.path.insert(0, sys.argv[1] + "/deploy/bot")
import adblock
srcfile = sys.argv[2]
try:
    hosts = adblock.allowed_fetch_hosts(adblock.read_sources(srcfile))
except AttributeError as e:
    print("[FAIL] 白名单还不是按源算的(缺 %s)" % e); sys.exit(0)
added = urllib.parse.urlsplit("https://gcore.jsdelivr.net/x").hostname
print("[OK]   add 过的主机进了白名单" if added in hosts
      else "[FAIL] add 过的主机不在白名单里")
print("[OK]   白名单只含生效源的主机(用户配置 = 替换而非追加, 否则内置源永远删不掉)"
      if "anti-ad.net" not in hosts else
      "[FAIL] 未配置的内置主机仍在白名单里 —— 那等于连不该连的地方也放行")
print("[OK]   没 add 过的主机仍被挡在外面" if "evil.example.com" not in hosts
      else "[FAIL] 没 add 过的主机竟然也在白名单里")
PY
for _ in 1 2 3; do :; done
# 上面 python 直接打印判据行, 这里把计数补上
n_ok=$(python3 - "$ROOT" "$(srcfile "$W")" <<'PY'
import sys, urllib.parse
sys.path.insert(0, sys.argv[1] + "/deploy/bot")
try:
    import adblock
    hosts = adblock.allowed_fetch_hosts(adblock.read_sources(sys.argv[2]))
    c = sum([urllib.parse.urlsplit("https://gcore.jsdelivr.net/x").hostname in hosts,
             "anti-ad.net" not in hosts, "evil.example.com" not in hosts])
except Exception:
    c = 0
print(c)
PY
)
pass=$((pass + n_ok)); nfail=$((nfail + 3 - n_ok))
run_box "$W" 'cmd_adblock source reset' >/dev/null
n2=$(python3 - "$ROOT" "$(srcfile "$W")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/deploy/bot")
try:
    import adblock
    hosts = adblock.allowed_fetch_hosts(adblock.read_sources(sys.argv[2]))
    print(1 if "anti-ad.net" in hosts else 0)
except Exception:
    print(0)
PY
)
[[ "$n2" == 1 ]] && ok "reset 之后白名单回到内置默认" || bad "reset 之后白名单没回到内置默认"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

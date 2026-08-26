#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# `pdg adblock check <域名>` 的输入契约。
#
# 上一轮安全终审量到的事实:非法输入(空值、换行、`../../etc/passwd`、
# `ads.invalid; rm -rf /`、`*.example.com`、IP 字面量、超长)一律被答成"未阻断"。
#
# 那不是安全洞 —— 这条命令只做字符串匹配,不碰文件系统、不发查询。但它是**诚实性缺口**:
# 用户问"这个东西会不会被拦",工具对一个根本不是域名的东西回答"不会被拦",
# 而正确答案是"你给的不是一个域名"。诊断命令给出看似确定的错答案,比报错更糟。
#
# 跑的是**真的 cmd_adblock**(从 pdg.sh 原样抽取),不复制实现。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok(){  echo "[OK]   $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)" || exit 1
cleanup(){ [[ -n "${PDG_KEEP_TMP:-}" ]] && { echo "现场保留: $WORK"; return; }; rm -rf "$WORK"; }
trap cleanup EXIT

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
for fn in c_g c_y _profile_set _pdg_module _adblock_intent _adblock_ensure_files \
          _adblock_gen_infra _adblock_apply _adblock_status cmd_adblock; do
  extract "$fn" >> "$CLOSURE" || { echo "[FAIL] 闭包抽取失败: $fn"; exit 1; }
  echo >> "$CLOSURE"
done
cat >> "$CLOSURE" <<'STUB'
need_root(){ :; }
STUB

BOX="$WORK/box"
mkdir -p "$BOX/etc/mosdns/rules" "$BOX/var/adblock" "$BOX/bin" "$BOX/repo/deploy" "$BOX/opt/pdg-acme"
ln -sfn "$ROOT/deploy/bot" "$BOX/repo/deploy/bot"
printf 'PDG_INTERNAL_CIDR=172.22.0.0/16\n' > "$BOX/etc/privdns-gateway.profile"
printf 'domain:ads.invalid\n' > "$BOX/etc/mosdns/rules/adblock_block.txt"
: > "$BOX/etc/mosdns/rules/adblock_allow.txt"
printf 'domain:infra.invalid\n' > "$BOX/var/adblock/infra_allow.txt"
printf 'domain:ads.invalid\n' > "$BOX/var/adblock/effective_block.txt"
printf 'domain:listed.invalid\n' > "$BOX/var/adblock/effective_list.txt"
cat > "$BOX/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_CALLS"; exit 0
S
chmod 755 "$BOX/bin/systemctl"

run_check(){   # run_check <参数...>  → 回显 rc, 输出落在 $WORK/out.log
  ( set +e
    export FX_CALLS="$WORK/calls.log"; : > "$FX_CALLS"
    PATH="$BOX/bin:$PATH"; export PATH
    REPO_DIR="$BOX/repo"; export REPO_DIR
    PROFILE_ENV="$BOX/etc/privdns-gateway.profile"
    ADB_STATE_DIR="$BOX/var/adblock"
    ADB_USER_ALLOW="$BOX/etc/mosdns/rules/adblock_allow.txt"
    ADB_USER_BLOCK="$BOX/etc/mosdns/rules/adblock_block.txt"
    ACME_HOME="$BOX/opt/pdg-acme"
    export PROFILE_ENV ADB_STATE_DIR ADB_USER_ALLOW ADB_USER_BLOCK ACME_HOME
    # shellcheck source=/dev/null
    source "$CLOSURE"
    cmd_adblock check "$@"
  ) > "$WORK/out.log" 2>&1
  echo $?
}

echo "══ 一、合法输入正常归一化 ══"
legal(){  # legal <输入> <应否阻断> <说明>
  local rc; rc="$(run_check "$1")"
  if [[ "$rc" != 0 ]]; then bad "$3: 合法输入被拒(rc=$rc)"; return; fi
  if grep -q "是否阻断  : $2" "$WORK/out.log"; then ok "$3(\"$1\" → $2)"
  else bad "$3: 期望「$2」, 实得: $(grep '是否阻断' "$WORK/out.log" | head -1)"; fi
}
legal "ads.invalid"        "是" "精确命中"
legal "ADS.INVALID"        "是" "大小写归一化"
legal "ads.invalid."       "是" "允许一个末尾点"
legal "deep.sub.ads.invalid" "是" "后缀匹配"
legal "nothing.invalid"    "否" "未命中"
legal "xn--fiqs8s.invalid" "否" "合法 punycode 形式被接受"
legal "a-b.c-d.invalid"    "否" "label 中间的连字符合法"

echo "══ 二、非法输入必须 fail-closed ══"
illegal(){  # illegal <说明> <输入...>
  local desc="$1"; shift
  local rc; rc="$(run_check "$@")"
  if [[ "$rc" == 0 ]]; then bad "$desc: 返回 0(应非零)"; return; fi
  if grep -q '是否阻断' "$WORK/out.log"; then bad "$desc: 仍然输出了「是否阻断」这类判定"; return; fi
  # 参数个数不对时给「用法」是更有用的固定文案, 与「域名格式无效」同属一类: 都明确说了
  # 这次没做判定。两者都接受, 但**必须**是其中之一 —— 不能只是静默非零。
  if ! grep -qE '域名格式无效|用法: pdg adblock check' "$WORK/out.log"; then
    bad "$desc: 没有给出「域名格式无效」或「用法」文案: $(head -1 "$WORK/out.log")"; return
  fi
  ok "$desc → 非零 + 域名格式无效, 且不作判定"
}
illegal "空值" ""
illegal "纯空白" "   "
illegal "前后空白" " ads.invalid "
illegal "换行注入" "ads.invalid
evil.invalid"
illegal "路径" "../../etc/passwd"
illegal "斜杠" "ads.invalid/x"
illegal "shell 标点" "ads.invalid; rm -rf /"
illegal "反引号" 'ads.invalid`id`'
illegal "美元符" 'ads.invalid$(id)'
illegal "通配符" "*.example.invalid"
illegal "IPv4 字面量" "203.0.113.9"
illegal "IPv6 字面量" "2606:4700::1111"
illegal "Unicode 原文" "广告.invalid"
illegal "空 label" "ads..invalid"
illegal "起始连字符" "-ads.invalid"
illegal "结尾连字符" "ads-.invalid"
illegal "单 label(无点)" "invalid"
illegal "超长 label" "$(printf 'a%.0s' {1..64}).invalid"
illegal "超长总长" "$(printf 'aaaaaaaa.%.0s' {1..30})invalid"
illegal "控制符" "$(printf 'ads\ax.invalid')"
illegal "多参数" "ads.invalid" "extra.invalid"

echo "══ 三、非法输入不得回显原文、不得动状态 ══"
run_check "ads.invalid; rm -rf /" >/dev/null
grep -q 'rm -rf' "$WORK/out.log" \
  && bad "非法输入被原样回显进输出(危险内容不该复述)" \
  || ok "非法输入不回显原文"
[[ ! -s "$WORK/calls.log" ]] \
  && ok "非法输入路径不调用 systemctl(不重启服务)" \
  || bad "非法输入路径调用了: $(cat "$WORK/calls.log")"
b1="$(sha256sum "$BOX/var/adblock/effective_block.txt" "$BOX/var/adblock/effective_list.txt" \
      "$BOX/etc/mosdns/rules/adblock_allow.txt" "$BOX/etc/mosdns/rules/adblock_block.txt" | cut -c1-16 | tr '\n' ' ')"
run_check "*.example.invalid" >/dev/null
b2="$(sha256sum "$BOX/var/adblock/effective_block.txt" "$BOX/var/adblock/effective_list.txt" \
      "$BOX/etc/mosdns/rules/adblock_allow.txt" "$BOX/etc/mosdns/rules/adblock_block.txt" | cut -c1-16 | tr '\n' ' ')"
[[ "$b1" == "$b2" ]] && ok "非法输入路径不改动任何规则文件" || bad "规则文件被改动了"

echo "══ 四、注入形状不得改变行为 ══"
MARK="$WORK/injected.marker"
run_check "ads.invalid\"; open('$MARK','w'); \"" >/dev/null
[[ ! -e "$MARK" ]] && ok "带 Python 引号的注入载荷没有产生标记文件" || bad "注入成功了 —— 载荷被当成代码执行"
run_check "ads.invalid'; import os; os.system('touch $MARK'); '" >/dev/null
[[ ! -e "$MARK" ]] && ok "带单引号的注入载荷没有产生标记文件" || bad "注入成功了"

echo "─────────────────────────────────────────"
echo "通过 $PASS, 失败 $FAIL"
[[ "$FAIL" == 0 ]]

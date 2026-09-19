#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 桥接验收(tests/e2e-real-bridge-hop.sh)的**观测判据**契约。
# 跑的是那支脚本里那几支函数的**原文**(按唯一成对标记抽), 用自有临时文件与一个
# PATH 上的 systemctl 桩驱动 —— 不装机、不碰宿主服务, 也不摘真实验收的 runner 安全闸。
#
# 本支盯四件事, 每一件都对应一条已经独立复现过的缺口:
#   ① 依赖: 抽得到只是第一步, 抽来的东西得**真被消费**(run 34978387896 就死在这)。
#   ② iOS 槽位: build_preimage 清场后只生成一次 ⇒ 合法形态是 current 有记录、previous=null。
#      槽位存在性必须**按记录**判, 不能预设 previous 一定在, 更不能复制 current / 改 revision /
#      建空文件去凑齐。有效性走**产品自己的**校验入口 iosstate.artifact_health ——
#      "schema==1"或"文件里有 <plist"只证明局部形态。
#   ③ 台账: 明确存在性 + 有效记录数 + 路径唯一性 + 集合完整性, 四条缺一不可。
#   ④ 服务采样: 采样当时就得把值/退出码/错误信息落进行里并当场判有效性。
#      **裁决时不许再查一次** —— 拿新查询给历史采样补证就是假绿。
#
# 纪律: 本支只对**桥接专用**判据与定向正控下手; 被测的一律是原文, 中途不重定义同名实现。
# 唯一被中和的是 ok/bad/note/_evn 这几支**汇报**用的辅助函数 —— 那是为了让被测函数自己的
# 断言不混进本支计数, 不是替换被测实现。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOP="$HERE/e2e-real-bridge-hop.sh"; PLAT="$HERE/e2e-real-platform-fail.sh"
REPO="$(cd "$HERE/.." && pwd)"
for f in "$HOP" "$PLAT"; do [[ -f "$f" ]] || { echo "[未执行] 找不到 $f"; exit 1; }; done
WORK="$(mktemp -d)" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"; ERR="$WORK/err"; mkdir -p "$OUT" "$ERR"

P=0; F=0; ALOG="$WORK/assert.log"; : > "$ALOG"
ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "$ALOG"; }
# 失败断言分两路累加, **不靠事后相减**:
#   bad      → 普通断言失败(F_PLAIN)
#   bad_sect → 分节审计这一条断言失败(F_AUDIT)
# 于是 F == F_PLAIN + F_AUDIT 是**加出来的**, 不可能为负。
# 分节审计另外还有一组**类别计数**, 单位是"节"(缺节/执行异常/重复/额外/完成度不足),
# 那是另一种量 —— 它与"失败断言条数"不可相加也不可相减, 两者各自成行。
F_PLAIN=0; F_AUDIT=0
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); F_PLAIN=$((F_PLAIN+1)); printf 'FAIL\t%s\n' "$1" >> "$ALOG"; }
bad_sect(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); F_AUDIT=$((F_AUDIT+1)); printf 'FAIL\t%s\n' "$1" >> "$ALOG"; }
note(){ printf '[NOTE] %s\n' "$1"; }
# 执行有效性. 两份东西**互相独立**, 缺一不可:
#   · SECT_EXPECT —— 本支声明"应该跑哪些节、每节至少几条断言"(写死在这里, 与正文分开);
#   · SECT_LOG    —— sect_end 在每节落幕时记下"实际跑了哪一节、产出几条"。
# 只看 SECT_LOG 是不够的: 整节正文连同它的 sect_end 一起消失时, 日志里根本没有那一行,
# 遍历日志的判据一条都看不见, 于是照报绿 —— 这正是本轮点名的那条(隔离复现: sect-repro)。
# 也不能改成钉住总数: 那只是把一个必然数字换成另一个必然数字, 任何增删断言都要改常量,
# 而少跑一整节照旧只表现为"数字不一样"。
SECT_EXPECT='1.依赖:8
2.槽位:11
3.台账:10
4.采样:24
5.裁决:14
6.空ref:5
7.顺序:8
8.记账:8
N.撤销:7'
SECT_LOG="$WORK/sect.log"; : > "$SECT_LOG"; _SECT_MARK=0
# 开始与落幕分别记, 于是三种毛病分得开:
#   声明了却没 begin        → **缺节**(整节正文与登记一起没了)
#   begin 了却没 end        → **执行异常**(跑到一半断了)
#   begin+end 但条数不够    → 完成度不足
SECT_BEG="$WORK/sect.beg"; : > "$SECT_BEG"
sect_begin(){ printf '%s\n' "$1" >> "$SECT_BEG"; }
sect_end(){ local n=$((P+F-_SECT_MARK)); printf '%s\t%d\n' "$1" "$n" >> "$SECT_LOG"; _SECT_MARK=$((P+F)); }
# sect_audit: 拿声明集合去核实际登记。四类问题分开报, 不互相抵消。
# 0=全对 / 1=有问题。**不看总数**。
# SECT_MISSING / SECT_ABORTED / SECT_SHORT / SECT_DUP / SECT_EXTRA: 各类计数, 供结算分开报。
sect_audit(){   # $1=实际登记文件 $2=声明集合(每行 "名字:最低条数") $3=开始记录文件(可省)
  local log="$1" decl="$2" beg="${3:-}" name want got dupes extra missing short rc=0
  SECT_MISSING=0; SECT_ABORTED=0; SECT_SHORT=0; SECT_DUP=0; SECT_EXTRA=0
  [[ -r "$log" ]] || { echo "  分节账读不了: $log"; return 1; }
  dupes="$(cut -f1 "$log" | sort | uniq -d)"
  while IFS=: read -r name want; do
    [[ -n "$name" ]] || continue
    local hits begun=0; hits="$(awk -F'\t' -v n="$name" '$1==n' "$log" | wc -l)"
    [[ -n "$beg" && -r "$beg" ]] && grep -qxF -- "$name" "$beg" && begun=1
    if (( hits == 0 )); then
      if (( begun == 1 )); then
        printf '    %-8s **执行异常** —— 开始了却没落幕(正文跑到一半断了, sect_end 没执行到)\n' "$name"
        SECT_ABORTED=$((SECT_ABORTED+1))
      else
        printf '    %-8s **缺失** —— 声明要跑, 但连开始都没有(整节正文与登记一起丢了)\n' "$name"
        SECT_MISSING=$((SECT_MISSING+1))
      fi
      rc=1; continue
    fi
    if (( hits > 1 )); then
      printf '    %-8s **重复登记 %d 次** —— 重复不能替另一节补账\n' "$name" "$hits"
      SECT_DUP=$((SECT_DUP+1)); rc=1
    fi
    got="$(awk -F'\t' -v n="$name" '$1==n{s+=$2} END{print s+0}' "$log")"
    if (( got >= want )); then printf '    %-8s %2d 条(至少 %d)\n' "$name" "$got" "$want"
    else printf '    %-8s %2d 条 —— **少于应有的 %d, 这一节没跑全**\n' "$name" "$got" "$want"; short=1; SECT_SHORT=$((SECT_SHORT+1)); rc=1; fi
  done <<< "$decl"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -q "^$name:" <<< "$decl" || { printf '    %-8s **额外** —— 登记了却不在声明集合里\n' "$name"; extra=1; SECT_EXTRA=$((SECT_EXTRA+1)); rc=1; }
  done < <(cut -f1 "$log" | sort -u)
  [[ -z "${dupes:-}" ]] || printf '    重复的节名: %s\n' "$(tr '\n' ' ' <<< "$dupes")"
  printf '  结论: 缺节=%d 执行异常=%d 重复=%d 额外=%d 完成度不足=%d\n' \
    "$SECT_MISSING" "$SECT_ABORTED" "$SECT_DUP" "$SECT_EXTRA" "$SECT_SHORT"
  : "${missing:-}" "${extra:-}" "${short:-}" "${dupes:-}"
  return $rc
}
grab(){ sed -n "/^# >>> PDG-EXTRACT-BEGIN $1\$/,/^# <<< PDG-EXTRACT-END $1\$/p" "$2" | sed '1d;$d'; }
# 被测函数自己也调 ok/bad/note/_evn。跑它时把这几支**汇报**辅助换成带前缀的打印,
# 免得它的断言混进本支计数 —— 被测实现本身一个字节都不换。
quiet(){ ( ok(){ printf '[被测OK] %s\n' "$1"; }; bad(){ printf '[被测FAIL] %s\n' "$1"; }
           note(){ :; }; _evn(){ :; }; "$@" ); }

# ── 被测原文(一律按唯一成对标记取) ──
UT="$WORK/under-test.sh"; : > "$UT"
for _n in extract_marked_fns extract_marked_decls deps_selfcheck \
          keep_fp ledger_build keep_compare ios_slots ios_slot_verdict \
          bridge_svc_sample bridge_row_valid bridge_set_check bridge_svc_class bridge_svc_verdict; do
  _f="$(grab "$_n" "$HOP")"
  [[ -n "$_f" ]] || { echo "[未执行] 从 e2e-real-bridge-hop.sh 按标记取不到 $_n"; exit 1; }
  printf '%s\n' "$_f" >> "$UT"
done
# bridge_svc_sample 判"该不该有 MainPID"用的是平台脚本里那支原文, 一并按标记取
_f="$(grab _unit_wants_mainpid "$PLAT")"
[[ -n "$_f" ]] || { echo "[未执行] 从 e2e-real-platform-fail.sh 按标记取不到 _unit_wants_mainpid"; exit 1; }
printf '%s\n' "$_f" >> "$UT"
bash -n "$UT" || { echo "[未执行] 被测原文组合后语法不过"; exit 1; }
_evn(){ :; }; EVID="$WORK/evid"; mkdir -p "$EVID"
# shellcheck disable=SC2034  # 被抽进来的采样器用它放临时 stderr 文件
E2E_TMP="$WORK"
# shellcheck source=/dev/null
source "$UT"
ok "0: 被测原文 14 支(抽取/依赖自检/台账/槽位/采样/行有效性/集合/归类/对账)全部按标记取到并加载"

# ═══════════════════════════════════════════════════════════════════════════
echo; echo "══ 1. 缺依赖后不许继续 ══"
sect_begin "1.依赖"
mkfix(){ mkdir -p "$WORK/fix"; printf '%s\n' "$2" > "$WORK/fix/$1"; printf '%s' "$WORK/fix/$1"; }
F_OK="$(mkfix ok.sh '# >>> PDG-EXTRACT-BEGIN A
A=(x.service y.timer)
# <<< PDG-EXTRACT-END A
# >>> PDG-EXTRACT-BEGIN B
B=(m n)
# <<< PDG-EXTRACT-END B')"
# shellcheck disable=SC2034  # 夹具落点, 由下面的子壳按名字引用
F_EMPTY="$(mkfix empty.sh '# >>> PDG-EXTRACT-BEGIN A
A=()
# <<< PDG-EXTRACT-END A')"
F_NOMARK="$(mkfix nomark.sh 'A=(x.service)')"
extract_marked_decls "$F_OK" "$WORK/d-ok.sh" A B >"$OUT/d1" 2>"$ERR/d1" \
  && ok "1a: 健康对照 —— 两个常量声明都抽得到" \
  || { bad "1a: 健康对照失败: $(cat "$ERR/d1")"; }
extract_marked_decls "$F_NOMARK" "$WORK/d-nm.sh" A >"$OUT/d2" 2>"$ERR/d2" \
  && bad "1b: 没有标记也抽出来了 —— 判据失效" \
  || ok "1b: 依赖声明没有标记 ⇒ 拒绝($(head -1 "$ERR/d2"))"
# 依赖自检要真的**消费** —— 它调 bridge_svc_sample + bridge_set_check, 桩在 PATH 上。
STUB="$WORK/stub"; mkdir -p "$STUB" "$WORK/sd"
cat > "$STUB/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
# systemctl 桩: 只读 $PDG_STUB_DIR 下的夹具文件, 不碰真实 systemd。
# 约定: <unit>.<key> = 标准输出; <unit>.<key>.rc = 退出码; <unit>.<key>.err = 标准错误。
d="${PDG_STUB_DIR:?}"
sub="$1"; shift
case "$sub" in
  show) prop=""; unit=""
        while (( $# )); do case "$1" in -p) prop="$2"; shift 2;; --value) shift;; *) unit="$1"; shift;; esac; done
        key="$unit.$prop";;
  is-active|is-enabled) unit="$1"; key="$unit.${sub//-/}";;
  *) exit 0;;
esac
[[ -f "$d/$key" ]]     && cat  "$d/$key"
[[ -f "$d/$key.err" ]] && cat  "$d/$key.err" >&2
if [[ -f "$d/$key.rc" ]]; then exit "$(cat "$d/$key.rc")"; fi
exit 0
STUBEOF
chmod +x "$STUB/systemctl"
export PDG_STUB_DIR="$WORK/sd"
PATH="$STUB:$PATH"
# 夹具写入: sset <unit> <key> <stdout> [rc] [stderr]
sset(){ local u="$1" k="$2"; printf '%s' "${3-}" > "$PDG_STUB_DIR/$u.$k"
        [[ -n "${4-}" ]] && printf '%s' "$4" > "$PDG_STUB_DIR/$u.$k.rc"
        [[ -n "${5-}" ]] && printf '%s' "$5" > "$PDG_STUB_DIR/$u.$k.err"; return 0; }
# 一个"健康的 simple service"整套字段
mkunit(){ local u="$1" act="${2:-active}" ufs="${3:-enabled}" pid="${4:-4242}" \
                inv="${5:-0123456789abcdef0123456789abcdef}" typ="${6:-simple}"
  sset "$u" Id "$u.service"; sset "$u" LoadState loaded; sset "$u" Type "$typ"
  sset "$u" ActiveState "$act"; sset "$u" SubState running; sset "$u" UnitFileState "$ufs"
  sset "$u" MainPID "$pid"; sset "$u" InvocationID "$inv"; sset "$u" NRestarts 0
  # 文件型 unit 的两条**独立分类依据**(systemd 252 实测: 普通 unit Transient=no、
  # FragmentPath 指向盘上的 unit 文件)。采样器只在 UnitFileState 读到空时才查它们。
  sset "$u" FragmentPath "/etc/systemd/system/$u.service"; sset "$u" Transient no
  sset "$u" isactive "$act"; sset "$u" isenabled "$ufs"; }
# timer / socket 健康夹具: SubState 取 systemd 252 上的真实取值(waiting / listening),
# MainPID=0、NRestarts 空 —— 那两个才是**服务专属**属性, 对它们不适用。
mktimer(){ sset "$1" Id "$1"; sset "$1" LoadState loaded
  sset "$1" ActiveState active; sset "$1" SubState waiting; sset "$1" UnitFileState enabled
  sset "$1" MainPID 0; sset "$1" InvocationID aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; sset "$1" NRestarts ""
  sset "$1" FragmentPath "/etc/systemd/system/$1"; sset "$1" Transient no
  sset "$1" isactive active; sset "$1" isenabled enabled; }
mksocket(){ sset "$1" Id "$1"; sset "$1" LoadState loaded
  sset "$1" ActiveState active; sset "$1" SubState listening; sset "$1" UnitFileState enabled
  sset "$1" MainPID 0; sset "$1" InvocationID bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; sset "$1" NRestarts ""
  sset "$1" FragmentPath "/etc/systemd/system/$1"; sset "$1" Transient no
  sset "$1" isactive active; sset "$1" isenabled enabled; }
mkunit m; mkunit n
( SVC_WATCH=(m n); E2E_OWNED_UNITS=(x.service y.timer); EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
  deps_selfcheck ) >"$OUT/d3" 2>"$ERR/d3" \
  && ok "1c: 健康对照 —— 依赖自检通过(数组非空 + 元素像 unit 名 + bridge_svc_sample 真采到对得上的集合)" \
  || bad "1c: 健康对照失败: $(cat "$ERR/d3")"
( SVC_WATCH=(m n); E2E_OWNED_UNITS=(); EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
  deps_selfcheck ) >/dev/null 2>"$ERR/d4" \
  && bad "1d: 空数组占位竟然过了 —— 判据失效" \
  || ok "1d: 空数组占位 ⇒ 拒绝($(head -1 "$ERR/d4"))"
( SVC_WATCH=(m m); E2E_OWNED_UNITS=(x.service); EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
  deps_selfcheck ) >/dev/null 2>"$ERR/d5" \
  && bad "1e: SVC_WATCH 里有重名项, 消费者采出重复行却判过了" \
  || ok "1e: 依赖集合里有重名项 ⇒ 消费者采出重复行, 集合判据当场拒($(head -1 "$ERR/d5"))"
( SVC_WATCH=(m n); E2E_OWNED_UNITS=("不是 unit 名"); EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
  deps_selfcheck ) >/dev/null 2>"$ERR/d6" \
  && bad "1f: 非法元素竟然过了" \
  || ok "1f: 依赖集合异常(元素不像 unit 名)⇒ 拒绝($(head -1 "$ERR/d6"))"
_L_HARD="$(grep -n 'deps_selfcheck || _hard' "$HOP" | head -1 | cut -d: -f1)"
_L_PRE="$(grep -n '^build_preimage$\|^build_preimage ' "$HOP" | head -1 | cut -d: -f1)"
{ [[ -n "$_L_HARD" ]] && [[ -n "$_L_PRE" ]] && (( _L_HARD < _L_PRE )); } \
  && ok "1g: 依赖自检失败直接 _hard(第 $_L_HARD 行), 排在前像构造(第 $_L_PRE 行)之前" \
  || bad "1g: 顺序不对(自检 $_L_HARD / 前像 $_L_PRE)"

# ═══════════════════════════════════════════════════════════════════════════
sect_end "1.依赖"
echo; echo "══ 2. iOS 槽位: 存在性按记录判, 有效性走产品入口, 单/双版本各用真实生成器造 ══"
sect_begin "2.槽位"
# **旧版**生成器必须从 v1.11.15 取件: 验收线自己的 deploy/bot 已经是退役版(SCHEMA=2,
# WLOC 已退役, generate 连 ca_der 参数都没有了), 拿它构造前像等于换了被测对象。
OLD_TAG_C="${PDG_OLD_TAG:-v1.11.15}"
OLDBOT="$WORK/oldsrc/deploy/bot"; TPL="$WORK/oldsrc/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl"
mkdir -p "$OLDBOT" "$WORK/oldsrc/deploy/ios"
_OLDOK=1
if git -C "$REPO" rev-parse -q --verify "$OLD_TAG_C^{commit}" >/dev/null 2>&1; then
  git -C "$REPO" archive "$OLD_TAG_C" deploy/bot deploy/ios 2>/dev/null | tar x -C "$WORK/oldsrc" 2>/dev/null || _OLDOK=0
else
  _OLDOK=0
fi
if (( _OLDOK == 0 )) || [[ ! -f "$OLDBOT/iosstate.py" || ! -f "$TPL" ]]; then
  bad "2: 取不到旧版($OLD_TAG_C)的生成器原文与描述文件模板 —— 本节无法用真实生成器构造, 没有拿别的版本顶替"
else
  _OLD_SCHEMA="$(grep -m1 '^SCHEMA = ' "$OLDBOT/iosstate.py" | tr -dc '0-9')"
  [[ "$_OLD_SCHEMA" == 1 ]] \
    && ok "2-1: 旧版生成器取自 $OLD_TAG_C(SCHEMA=$_OLD_SCHEMA, generate 带 ca_der/wloc_enabled) —— 不是验收线上那份退役版" \
    || bad "2-1: 取到的生成器 SCHEMA=$_OLD_SCHEMA, 不是旧版该有的 1"
  CA_DER="$WORK/ca.der"
  if openssl req -x509 -newkey rsa:2048 -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
       -days 2 -nodes -subj "/CN=pdg-obs-contract-ca" >/dev/null 2>&1 \
     && openssl x509 -in "$WORK/ca.crt" -outform DER -out "$CA_DER" 2>/dev/null; then
    ok "2-0: 用 openssl 造出一张**真的** X.509 自签 CA($(stat -c%s "$CA_DER") 字节) —— 产品会校验 DER 结构, 假字节串过不去"
  else
    bad "2-0: 造不出 CA, 本节后续用不了真实生成器"
  fi
  # gen <根目录> <dot 主机> <地址> → 用**旧版真实生成器**在沙箱里跑一次
  gen(){ PDG_TX_FSROOT="$1" python3 - "$OLDBOT" "$TPL" "$CA_DER" "$2" "$3" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import iosstate
der = open(sys.argv[3], "rb").read()
iosstate.generate(sys.argv[4], [sys.argv[5]], ssids=[], ca_der=der,
                  wloc_enabled=True, template=sys.argv[2], lock=False)
PY
  }
  mkroot(){ local r="$WORK/$1"; rm -rf "$r"; mkdir -p "$r/etc/privdns-gateway" "$r/var/lib/privdns-gateway"; printf '%s' "$r"; }
  META_REL=/etc/privdns-gateway/ios-profile.json
  ART_REL=/var/lib/privdns-gateway/ios-profile

  # ── 2a 单版本: 只生成一次 = 前像的合法形态 ──
  R1="$(mkroot r-single)"
  if gen "$R1" dot.one.test 10.0.0.1 >"$OUT/g1" 2>"$ERR/g1"; then
    S1="$(ios_slots "$R1$META_REL" "$R1$ART_REL" "$OLDBOT")"
    ios_slot_verdict "$S1" "$_OLD_SCHEMA" >"$OUT/v-single" 2>&1; RC1=$?
    if (( RC1 == 0 )) && grep -q '^previous	无记录	文件不在	missing' <<<"$S1"; then
      ok "2a: **真实生成器跑一次** ⇒ current 有记录/文件在/healthy, previous 无记录/文件不在/missing —— 合法的单版本前像"
    else
      bad "2a: 单版本形态不对(rc=$RC1)"; printf '%s\n' "$S1" | sed 's/^/      /'
    fi
  else
    bad "2a: 真实生成器跑不起来: $(tail -1 "$ERR/g1")"
  fi
  # ── 2b 双版本: 两次**不同的合法输入**, 不是复制 current ──
  R2="$(mkroot r-double)"
  if gen "$R2" dot.one.test 10.0.0.1 >"$OUT/g2" 2>"$ERR/g2" \
     && gen "$R2" dot.two.test 10.0.0.2 >>"$OUT/g2" 2>>"$ERR/g2"; then
    S2="$(ios_slots "$R2$META_REL" "$R2$ART_REL" "$OLDBOT")"
    ios_slot_verdict "$S2" "$_OLD_SCHEMA" >"$OUT/v-double" 2>&1; RC2=$?
    D_CUR="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["current"]["digest"])' "$R2$META_REL" 2>/dev/null)"
    D_PRV="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["previous"]["digest"])' "$R2$META_REL" 2>/dev/null)"
    H_CUR="$(sha256sum "$R2$ART_REL/current.mobileconfig"  2>/dev/null | cut -d' ' -f1)"
    H_PRV="$(sha256sum "$R2$ART_REL/previous.mobileconfig" 2>/dev/null | cut -d' ' -f1)"
    if (( RC2 == 0 )) && grep -q '^previous	有记录	文件在	healthy' <<<"$S2" \
       && [[ -n "$D_CUR" && "$D_CUR" != "$D_PRV" ]] && [[ -n "$H_CUR" && "$H_CUR" != "$H_PRV" ]]; then
      ok "2b: **真实生成器跑两次不同合法输入** ⇒ 两个槽位都有记录/文件在/healthy, 且两版摘要互不相同(记录 digest 与产物 sha256 都不同)"
    else
      bad "2b: 双版本形态不对(rc=$RC2, cur digest=${D_CUR:0:8} prev=${D_PRV:0:8}, cur sha=${H_CUR:0:8} prev=${H_PRV:0:8})"
      printf '%s\n' "$S2" | sed 's/^/      /'
    fi
  else
    bad "2b: 第二次生成失败: $(tail -1 "$ERR/g2")"
  fi
  # ── 2c 反例: 无记录却凭空多一个 previous 文件(那正是"复制一份凑齐"会留下的痕迹) ──
  R3="$(mkroot r-fake)"; gen "$R3" dot.one.test 10.0.0.1 >/dev/null 2>&1
  cp "$R3$ART_REL/current.mobileconfig" "$R3$ART_REL/previous.mobileconfig" 2>/dev/null
  S3="$(ios_slots "$R3$META_REL" "$R3$ART_REL" "$OLDBOT")"
  ios_slot_verdict "$S3" "$_OLD_SCHEMA" >"$OUT/v3" 2>&1
  { [[ $? != 0 ]] && grep -q 'previous.*不自洽' "$OUT/v3"; } \
    && ok "2c: 记录里没有 previous 却把 current 复制过去 ⇒ 判**不自洽**(凑齐文件骗不过按记录判的槽位)" \
    || { bad "2c: 伪造的 previous 没被发现"; sed 's/^/      /' "$OUT/v3"; }
  # ── 2d 反例: 产物被改成损坏的 XML ⇒ 产品入口判 corrupt, 不是"文件还在就算数" ──
  R4="$(mkroot r-corrupt)"; gen "$R4" dot.one.test 10.0.0.1 >/dev/null 2>&1
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>x' > "$R4$ART_REL/current.mobileconfig"
  S4="$(ios_slots "$R4$META_REL" "$R4$ART_REL" "$OLDBOT")"
  if grep -q '^current	有记录	文件在	corrupt' <<<"$S4"; then
    ok "2d: 损坏的 XML(仍以 <plist 开头, 仍是'文件在')⇒ iosstate.artifact_health 判 **corrupt** —— grep '<plist' 这种局部形态判据在这里正好会判绿"
  else
    bad "2d: 损坏产物没被判 corrupt"; printf '%s\n' "$S4" | sed 's/^/      /'
  fi
  # ── 2e 反例: 记录与产物对不上(改 sha256/revision, 文件本身仍是合法 plist) ──
  R5="$(mkroot r-mismatch)"; gen "$R5" dot.one.test 10.0.0.1 >/dev/null 2>&1
  python3 - "$R5$META_REL" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["current"]["sha256"] = "0" * 64      # 记录说的那一份, 与盘上那一份对不上
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2, sort_keys=True)
PY
  S5="$(ios_slots "$R5$META_REL" "$R5$ART_REL" "$OLDBOT")"
  if grep -qE '^current	有记录	文件在	(corrupt|state_mismatch)' <<<"$S5"; then
    ok "2e: 记录与产物不匹配(文件仍是合法 plist)⇒ 产品入口判 $(awk -F'\t' '$1=="current"{print $4}' <<<"$S5") —— 只看形态的判据在这里同样会判绿"
  else
    bad "2e: 记录/产物不匹配没被发现"; printf '%s\n' "$S5" | sed 's/^/      /'
  fi
  # ── 2f 反例: 记录读不出来 ⇒ 是**读取失败**, 不是"槽位为空" ──
  R6="$(mkroot r-badmeta)"; gen "$R6" dot.one.test 10.0.0.1 >/dev/null 2>&1
  printf '{ 这不是 json' > "$R6$META_REL"
  S6="$(ios_slots "$R6$META_REL" "$R6$ART_REL" "$OLDBOT")"
  ios_slot_verdict "$S6" "$_OLD_SCHEMA" >"$OUT/v6" 2>&1; RC6=$?
  { (( RC6 == 2 )) && grep -q '记录不可用' "$OUT/v6"; } \
    && ok "2f: 记录读不出来 ⇒ 单独判**读取失败**(rc=2), 不当成'槽位为空'也不当成'没变'" \
    || { bad "2f: 坏记录的处置不对(rc=$RC6)"; sed 's/^/      /' "$OUT/v6"; }
  # ── 2h/2i 操作后仍如此: 这一跳**不该**动槽位形态 ──
  # 2h 正: 什么都没发生 ⇒ 前后逐字节相同, 判据仍过
  S1B="$(ios_slots "$R1$META_REL" "$R1$ART_REL" "$OLDBOT")"
  { [[ "$S1B" == "$S1" ]] && ios_slot_verdict "$S1B" "$_OLD_SCHEMA" >/dev/null 2>&1; } \
    && ok "2h: 这一跳什么都没动 ⇒ 槽位报告**逐字节相同**且仍自洽(单版本前像的'操作后仍如此')" \
    || { bad "2h: 什么都没动, 槽位报告却变了"; diff <(printf '%s\n' "$S1") <(printf '%s\n' "$S1B") | sed 's/^/      /'; }
  # 2i 负: 这一跳里冒出了一个 previous 产物(记录仍说没有)⇒ 必须被抓到
  cp "$R1$ART_REL/current.mobileconfig" "$R1$ART_REL/previous.mobileconfig" 2>/dev/null
  S1C="$(ios_slots "$R1$META_REL" "$R1$ART_REL" "$OLDBOT")"
  ios_slot_verdict "$S1C" "$_OLD_SCHEMA" >"$OUT/v-after" 2>&1; RC1C=$?
  { [[ "$S1C" != "$S1" ]] && (( RC1C != 0 )); } \
    && ok "2i: 这一跳里凭空多出 previous 产物(记录仍无该槽位)⇒ 逐字节比较与槽位判据**两条都抓到**" \
    || { bad "2i: 事后多出来的 previous 没被抓到(逐字节变化=$( [[ "$S1C" != "$S1" ]] && echo 有 || echo 无), 判据 rc=$RC1C)"; }
  rm -f "$R1$ART_REL/previous.mobileconfig"
  # ── 2g 反例: schema 被推进 ⇒ 判不过 ──
  R7="$(mkroot r-schema)"; gen "$R7" dot.one.test 10.0.0.1 >/dev/null 2>&1
  ios_slot_verdict "$(ios_slots "$R7$META_REL" "$R7$ART_REL" "$OLDBOT")" 99 >"$OUT/v7" 2>&1
  { [[ $? != 0 ]] && grep -q 'schema 读到' "$OUT/v7"; } \
    && ok "2g: 期望 schema 与实际不符 ⇒ 具名判红(不是空==空那种恒真)" \
    || { bad "2g: schema 判据没起作用"; sed 's/^/      /' "$OUT/v7"; }
fi

# ═══════════════════════════════════════════════════════════════════════════
sect_end "2.槽位"
echo; echo "══ 3. 台账: 明确存在性 + 有效记录数 + 路径唯一性 + 集合完整性 ══"
sect_begin "3.台账"
LD="$WORK/led.tsv"; EX="$WORK/exp.txt"; mkdir -p "$WORK/keep"
K1="$WORK/keep/a"; K2="$WORK/keep/b"; K3="$WORK/keep/c"
printf 'AAA\n' > "$K1"; printf 'BBB\n' > "$K2"; printf 'CCC\n' > "$K3"
ledger_build "$LD" "$EX" "$K1" "$K2" -- "$K3"
keep_compare "$LD" "$EX" >"$OUT/l1" 2>&1 \
  && ok "3a: 健康对照 —— 没动过时对账通过($(tail -1 "$OUT/l1"))" \
  || { bad "3a: 健康对照失败"; sed 's/^/      /' "$OUT/l1"; }
printf 'BBB2\n' > "$K2"
keep_compare "$LD" "$EX" >"$OUT/l2" 2>&1; R=$?
{ (( R == 1 )) && grep -q '变了' "$OUT/l2"; } \
  && ok "3b: 保留对象**内容变了**被发现(rc=1, 逐项列出)" \
  || { bad "3b: 内容变化没被发现(rc=$R)"; sed 's/^/      /' "$OUT/l2"; }
printf 'BBB\n' > "$K2"; chmod 600 "$K1"
keep_compare "$LD" "$EX" >"$OUT/l3" 2>&1; R=$?
{ (( R == 1 )) && grep -q '变了' "$OUT/l3"; } \
  && ok "3c: 只改 **mode** 也被发现(内容一样也不放过)" \
  || { bad "3c: mode 变化没被发现(rc=$R)"; sed 's/^/      /' "$OUT/l3"; }
chmod 644 "$K1"; rm -f "$K2"
keep_compare "$LD" "$EX" >"$OUT/l4" 2>&1; R=$?
{ (( R == 1 )) && grep -q '没了' "$OUT/l4"; } \
  && ok "3d: 保留对象**没了**被发现(台账那一行明写着 present)" \
  || { bad "3d: 缺失没被发现(rc=$R)"; sed 's/^/      /' "$OUT/l4"; }
printf 'BBB\n' > "$K2"
# 台账里明确记 absent 的对象, 事后冒出来也要报
K4="$WORK/keep/d"; ledger_build "$LD" "$EX" "$K1" "$K2" "$K4"
printf 'D\n' > "$K4"
keep_compare "$LD" "$EX" >"$OUT/l5" 2>&1; R=$?
{ (( R == 1 )) && grep -q '凭空出现' "$OUT/l5"; } \
  && ok "3e: 台账记 absent 的对象事后**凭空出现**也被发现(存在性是明写的一列, 不靠'没写就当没有')" \
  || { bad "3e: 凭空出现没被发现(rc=$R)"; sed 's/^/      /' "$OUT/l5"; }
rm -f "$K4"
# 非空台账但零条有效记录
printf '%s\tabsent\t-\n' "$WORK/keep/zz" > "$WORK/led-zero.tsv"; printf '%s\n' "$WORK/keep/zz" > "$WORK/exp-zero.txt"
keep_compare "$WORK/led-zero.tsv" "$WORK/exp-zero.txt" >"$OUT/l6" 2>&1; R=$?
{ (( R == 2 )) && grep -q '零条有效记录' "$OUT/l6"; } \
  && ok "3f: **非空文件但零条有效记录** ⇒ rc=2 明确判无效(不是'没有出入所以通过')" \
  || { bad "3f: 零有效记录被放过(rc=$R)"; sed 's/^/      /' "$OUT/l6"; }
: > "$WORK/led-empty.tsv"
keep_compare "$WORK/led-empty.tsv" "$EX" >"$OUT/l7" 2>&1; R=$?
(( R == 2 )) && ok "3g: 空台账 ⇒ rc=2(零项台账不能证明保留成功)" || bad "3g: 空台账没被判无效(rc=$R)"
# 重复记录
ledger_build "$LD" "$EX" "$K1" "$K2"
cat "$LD" "$LD" > "$WORK/led-dup.tsv"
keep_compare "$WORK/led-dup.tsv" "$EX" >"$OUT/l8" 2>&1; R=$?
{ (( R == 3 )) && grep -q '重复路径' "$OUT/l8"; } \
  && ok "3h: **重复记录** ⇒ rc=3(重复行会让同一个对象算两次, 掩盖另一项的缺失)" \
  || { bad "3h: 重复记录被放过(rc=$R)"; sed 's/^/      /' "$OUT/l8"; }
# 漏项: 期望集合里有, 台账里没有
{ cat "$EX"; printf '%s\n' "$WORK/keep/never"; } > "$WORK/exp-more.txt"
keep_compare "$LD" "$WORK/exp-more.txt" >"$OUT/l9" 2>&1; R=$?
{ (( R == 4 )) && grep -q '漏项' "$OUT/l9"; } \
  && ok "3i: **漏项**(期望集合里的对象没进台账)⇒ rc=4, 按名字核集合而不是只数行" \
  || { bad "3i: 漏项被放过(rc=$R)"; sed 's/^/      /' "$OUT/l9"; }
keep_compare "$WORK/没有这个文件.tsv" "$EX" >"$OUT/l10" 2>&1; R=$?
(( R == 5 )) && ok "3j: 台账**读取失败** ⇒ rc=5(与'没有出入'分得开)" || bad "3j: 读取失败没被单列(rc=$R)"

# ═══════════════════════════════════════════════════════════════════════════
sect_end "3.台账"
echo; echo "══ 4. 服务采样: 采样当时定有效性, 裁决时不再查 ══"
sect_begin "4.采样"
# 每一格都把桩清干净再摆, 免得上一格的夹具漏进来。
reset_stub(){ rm -rf "$PDG_STUB_DIR"; mkdir -p "$PDG_STUB_DIR"; }
sample_one(){ ( SVC_WATCH=("$1"); bridge_svc_sample "$2" ); }
row_of(){ awk -F'\t' -v u="$1" '$1==u' "$2" | head -1; }
valid_col(){ cut -f13 <<<"$1"; }

reset_stub; mkunit svc-ok
sample_one svc-ok "$WORK/s1.tsv"
ROW="$(row_of svc-ok "$WORK/s1.tsv")"
{ [[ "$(awk -F'\t' '{print NF}' <<<"$ROW")" == 13 ]] && bridge_row_valid "$ROW"; } \
  && ok "4a: 健康对照 —— simple/active/enabled 的 service 采成 13 列且判有效" \
  || bad "4a: 健康对照失败(第13列=[$(valid_col "$ROW")])"

reset_stub; mkunit svc-r1; sset svc-r1 ActiveState "" 3 ""
sample_one svc-r1 "$WORK/s2.tsv"; ROW="$(row_of svc-r1 "$WORK/s2.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'ActiveState 查询失败(rc=3)' <<<"$(valid_col "$ROW")" \
  && ok "4b: 拒绝① rc 异常且 stdout/stderr **都空** ⇒ 采样当场判无效, 且留下字段名与返回码($(valid_col "$ROW"))" \
  || bad "4b: rc 异常+双空没被拒($(valid_col "$ROW"))"

reset_stub; mkunit svc-r5a; sset svc-r5a MainPID 0
sample_one svc-r5a "$WORK/s3.tsv"; ROW="$(row_of svc-r5a "$WORK/s3.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'MainPID' <<<"$(valid_col "$ROW")" \
  && ok "4c: 拒绝⑤ 适用字段缺失 —— Type=simple 的 service 处于 active 却 MainPID=0($(valid_col "$ROW"))" \
  || bad "4c: MainPID 适用性没判($(valid_col "$ROW"))"

reset_stub; mkunit svc-r5b; sset svc-r5b InvocationID ""
sample_one svc-r5b "$WORK/s4.tsv"; ROW="$(row_of svc-r5b "$WORK/s4.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'InvocationID' <<<"$(valid_col "$ROW")" \
  && ok "4d: 拒绝⑤ active 却没有合法 InvocationID($(valid_col "$ROW"))" \
  || bad "4d: InvocationID 适用性没判($(valid_col "$ROW"))"

reset_stub; mkunit svc-r5c; sset svc-r5c ActiveState "运行中"; sset svc-r5c isactive "运行中"
sample_one svc-r5c "$WORK/s5.tsv"; ROW="$(row_of svc-r5c "$WORK/s5.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q '非法值' <<<"$(valid_col "$ROW")" \
  && ok "4e: 拒绝⑤ 适用字段**非法** —— ActiveState 不是已知取值($(valid_col "$ROW"))" \
  || bad "4e: 非法 ActiveState 没被拒($(valid_col "$ROW"))"

# 正常的 inactive/disabled: is-active 返回 3、is-enabled 返回 1, 但**有值** ⇒ 那是答案
reset_stub; mkunit svc-inact inactive disabled 0 "" simple
sset svc-inact SubState dead; sset svc-inact isactive inactive 3; sset svc-inact isenabled disabled 1
sample_one svc-inact "$WORK/s6.tsv"; ROW="$(row_of svc-inact "$WORK/s6.tsv")"
bridge_row_valid "$ROW" \
  && ok "4f: 正常的 inactive/disabled —— is-active rc=3、is-enabled rc=1 但都**有值** ⇒ 仍判有效(非零返回码是答案)" \
  || bad "4f: 把正常的 inactive 非零返回码当成了查询失败($(valid_col "$ROW"))"

reset_stub; sset svc-nf Id ""; sset svc-nf LoadState not-found; sset svc-nf ActiveState inactive
sset svc-nf SubState dead; sset svc-nf UnitFileState ""; sset svc-nf MainPID 0
sset svc-nf InvocationID ""; sset svc-nf NRestarts 0
sset svc-nf isactive "" 3 "Unit svc-nf.service could not be found."
sset svc-nf isenabled "" 1 "Failed to get unit file state for svc-nf.service: No such file or directory"
sample_one svc-nf "$WORK/s7.tsv"; ROW="$(row_of svc-nf "$WORK/s7.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q '读不到 Id' <<<"$(valid_col "$ROW")" \
  && ok "4g: not-found 的措辞被认成**答案**(没写进查询失败), 但读不到 Id 仍被具名判无效 —— 两种原因分得开($(valid_col "$ROW"))" \
  || bad "4g: not-found 的处置不对($(valid_col "$ROW"))"

reset_stub; mkunit svc-r1b; sset svc-r1b isactive "" 1 ""
sample_one svc-r1b "$WORK/s8.tsv"; ROW="$(row_of svc-r1b "$WORK/s8.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'is-active 无值且 stderr 为空' <<<"$(valid_col "$ROW")" \
  && ok "4h: is-active **无值且无 stderr** ⇒ 查询失败(不是'没有 stderr 就算有效')" \
  || bad "4h: 无值无 stderr 被当成有效($(valid_col "$ROW"))"

# timer: 没有 Type、NRestarts 合法地为空 ⇒ 不该因为"字段空"判无效
reset_stub
sset tm Id tm.timer; sset tm LoadState loaded; sset tm ActiveState active; sset tm SubState waiting
sset tm UnitFileState enabled; sset tm MainPID 0; sset tm NRestarts ""
sset tm InvocationID aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sset tm isactive active; sset tm isenabled enabled
sample_one tm "$WORK/s9.tsv"; ROW="$(row_of tm "$WORK/s9.tsv")"
bridge_row_valid "$ROW" \
  && ok "4i: timer 没有 Type、NRestarts 合法为空 ⇒ 按类型判**不适用**, 不因字段空判无效" \
  || bad "4i: timer 的不适用字段被当成了缺失($(valid_col "$ROW"))"

# ═══════════════════════════════════════════════════════════════════════════

# ── show 查询失败: 只坏一个**适用字段**, 其余全正常 ──
reset_stub; mkunit svc-sub; sset svc-sub SubState "" 97 "Failed to get properties: Connection timed out"
sample_one svc-sub "$WORK/sa1.tsv"; ROW="$(row_of svc-sub "$WORK/sa1.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'SubState 查询失败(rc=97' <<<"$(valid_col "$ROW")" \
  && ok "4j: 只有 **SubState** 查询失败(rc=97/stdout 空/stderr 明确), 其余正常 ⇒ 采样当场判无效, 并留下字段名+返回码+原因" \
  || bad "4j: SubState 查询失败被放过($(valid_col "$ROW"))"
reset_stub; mkunit svc-ufs; sset svc-ufs UnitFileState "" 97 "Failed to get properties: Connection timed out"
sample_one svc-ufs "$WORK/sa2.tsv"; ROW="$(row_of svc-ufs "$WORK/sa2.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q 'UnitFileState 查询失败(rc=97' <<<"$(valid_col "$ROW")" \
  && ok "4k: 只有 **UnitFileState** 查询失败 ⇒ 同样当场判无效(而不是把空值当成'被禁用了')" \
  || bad "4k: UnitFileState 查询失败被放过($(valid_col "$ROW"))"
# rc=0 但 stdout 空而 stderr 有: 命令自己报了错, 同样算查询失败
reset_stub; mkunit svc-e0; sset svc-e0 MainPID "" "" "Failed to get properties: Access denied"
sample_one svc-e0 "$WORK/sa3.tsv"; ROW="$(row_of svc-e0 "$WORK/sa3.tsv")"
{ ! bridge_row_valid "$ROW"; } && grep -q '无值却有错误输出' <<<"$(valid_col "$ROW")" \
  && ok "4l: rc=0 但 stdout 空而 stderr 有 ⇒ 按**查询失败**处理(不是'值恰好是空')" \
  || bad "4l: rc=0+stderr 的查询失败被放过($(valid_col "$ROW"))"
# 不适用 与 读取失败 必须分开: timer 的 NRestarts 查询成功且空 = 不适用; 查询失败 = 无效
reset_stub
sset tm2 Id tm2.timer; sset tm2 LoadState loaded; sset tm2 ActiveState active; sset tm2 SubState waiting
sset tm2 UnitFileState enabled; sset tm2 MainPID 0; sset tm2 NRestarts ""
sset tm2 InvocationID aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; sset tm2 isactive active; sset tm2 isenabled enabled
sample_one tm2 "$WORK/sa4.tsv"; ROW_NA="$(row_of tm2 "$WORK/sa4.tsv")"
sset tm2 NRestarts "" 97 "Failed to get properties: Connection timed out"
sample_one tm2 "$WORK/sa5.tsv"; ROW_FAIL="$(row_of tm2 "$WORK/sa5.tsv")"
{ bridge_row_valid "$ROW_NA" && ! bridge_row_valid "$ROW_FAIL"; } \
  && ok "4m: timer 的 NRestarts —— **查询成功且空**判不适用(有效), **查询失败**判无效; 两者分得开" \
  || bad "4m: 不适用与读取失败没分开(不适用行=$(valid_col "$ROW_NA") / 失败行=$(valid_col "$ROW_FAIL"))"

# ── "查询成功但适用字段缺失": 指定字段 rc=0 / stdout 空 / stderr 空 ──
# 每一格都**从采样一路走到最终裁决**, 不只看提示文字: 记录由真实 bridge_svc_sample 生成,
# 裁决由真实 bridge_svc_verdict 给出, 只替换外部查询(PATH 上的 systemctl 桩)。
e2e_case(){   # $1=标签 $2=unit $3=构造器 $4..=(属性 值 rc 错误) 三元组式的置空动作
  local lbl="$1" u="$2" mk="$3"; shift 3
  reset_stub; "$mk" "$u"
  while (( $# >= 4 )); do sset "$u" "$1" "$2" "$3" "$4"; shift 4; done
  sample_one "$u" "$WORK/e2e-$lbl.b.tsv"; sample_one "$u" "$WORK/e2e-$lbl.a.tsv"
  E2E_ROW="$(row_of "$u" "$WORK/e2e-$lbl.b.tsv")"
  E2E_VALID=0; bridge_row_valid "$E2E_ROW" && E2E_VALID=1
  ( SVC_WATCH=("$u"); ok(){ printf '[被测OK] %s\n' "$1"; }; note(){ :; }; _evn(){ :; }
    bad(){ printf '[被测FAIL] %s\n' "$1"; return 1; }
    bridge_svc_verdict "$WORK/e2e-$lbl.b.tsv" "$WORK/e2e-$lbl.a.tsv" "$lbl" >"$OUT/e2e-$lbl" 2>&1 ); E2E_RC=$?
}
# 健康对照: 三种 unit 各自从采样走到裁决
for _x in "svc-h:mkunit" "tm-h.timer:mktimer" "sk-h.socket:mksocket"; do
  e2e_case "h-${_x%%:*}" "${_x%%:*}" "${_x##*:}"
  { (( E2E_VALID == 1 )) && (( E2E_RC == 0 )); } \
    && ok "4n-${_x%%:*}: 健康对照 —— 采样判有效(第13列=ok)且最终裁决通过(退出状态 0)" \
    || bad "4n-${_x%%:*}: 健康对照不过(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
done
# ① loaded timer 的 SubState 空
e2e_case sub-timer tm-e.timer mktimer SubState "" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )) && grep -q 'SubState' <<<"$(valid_col "$E2E_ROW")"; } \
  && ok "4o: **loaded timer 的 SubState** 查询成功却空 ⇒ 判必需字段缺失, 裁决退出状态 $E2E_RC(不因'不是 service'免检)" \
  || bad "4o: timer 的 SubState 空被放过(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
# ② loaded socket 的 SubState 空
e2e_case sub-socket sk-e.socket mksocket SubState "" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )) && grep -q 'SubState' <<<"$(valid_col "$E2E_ROW")"; } \
  && ok "4p: **loaded socket 的 SubState** 查询成功却空 ⇒ 同样判必需字段缺失, 裁决退出状态 $E2E_RC" \
  || bad "4p: socket 的 SubState 空被放过(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
# ③ 文件型 service 的 UnitFileState 空(本验收要据此核自启态)
e2e_case ufs-file svc-e mkunit UnitFileState "" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )) && grep -q 'UnitFileState 为空而 LoadState=loaded' <<<"$(valid_col "$E2E_ROW")"; } \
  && ok "4q: **loaded service 的 UnitFileState** 查询成功却空 ⇒ 判必需字段缺失, 裁决退出状态 $E2E_RC" \
  || bad "4q: 文件型 service 的 UFS 空被放过(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
# 4r/4s/4t **旧预期已作废**。它们原本断言"UnitFileState 空 + Transient=yes / FragmentPath 空
# ⇒ 判不适用, 仍有效", 依据是"瞬态 unit 本来就没有 unit 文件"。那个依据是错的:
# 本机 systemd 252 实测, 真实瞬态 unit 的 UnitFileState = **transient**(词表内的合法非空值),
# Transient=yes, 且 FragmentPath 指向 /run/systemd/transient/<名字> —— 文件确实在盘上。
# 也就是说, 合法 transient 根本走不到"空值"这一支; 那条豁免从来没有真实来源支撑,
# 只是给"取不到自启态"开了一道口子。豁免已删除, 下面三格改成**必须被拒**。
e2e_case ufs-allempty svc-t mkunit UnitFileState "" 0 "" Transient "" 0 "" FragmentPath "" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )); } \
  && ok "4r: UnitFileState / Transient / FragmentPath **三项全空且查询都成功** ⇒ 判必需字段缺失, 裁决退出状态 $E2E_RC(旧预期'判不适用仍有效'已作废)" \
  || bad "4r: 三项全空仍被接受(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
e2e_case ufs-badbool svc-f mkunit UnitFileState "" 0 "" Transient "maybe" 0 "" FragmentPath "" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )); } \
  && ok "4s: UnitFileState 空 + **Transient 是非法布尔值** ⇒ 同样判必需字段缺失(不再拿它做分类依据, 也就不存在'非法值被当成 no')" \
  || bad "4s: 非法布尔仍被当成放行依据(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
e2e_case ufs-realtransient svc-c mkunit UnitFileState "" 0 "" Transient yes 0 "" FragmentPath "/run/systemd/transient/svc-c.service" 0 ""
{ (( E2E_VALID == 0 )) && (( E2E_RC != 0 )); } \
  && ok "4t: UnitFileState 空 + Transient=yes + **FragmentPath 非空** ⇒ 判必需字段缺失 —— 这恰是真实瞬态 unit 的属性组合, 而它本该报 transient 而不是空" \
  || bad "4t: 该组合仍被放行(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
# 合法的非空 transient 走既有词表, 不受影响
e2e_case ufs-transient-word svc-w mkunit UnitFileState "transient" 0 ""
{ (( E2E_VALID == 1 )) && (( E2E_RC == 0 )); } \
  && ok "4u: UnitFileState = **transient**(合法非空状态)⇒ 按既有词表正常通过, 删豁免没有误伤它" \
  || bad "4u: 合法的 transient 被误判(有效=$E2E_VALID 裁决退出=$E2E_RC; $(valid_col "$E2E_ROW"))"
# not-found 不与 loaded 混判: 它的 UnitFileState 本来就是空
reset_stub
sset nf-u Id ""; sset nf-u LoadState not-found; sset nf-u ActiveState inactive; sset nf-u SubState dead
sset nf-u UnitFileState ""; sset nf-u MainPID 0; sset nf-u InvocationID ""; sset nf-u NRestarts 0
sset nf-u isactive "" 3 "Unit nf-u.service could not be found."
sset nf-u isenabled "" 1 "Failed to get unit file state for nf-u.service: No such file or directory"
sample_one nf-u "$WORK/nf.tsv"; ROW="$(row_of nf-u "$WORK/nf.tsv")"
{ ! bridge_row_valid "$ROW"; } && ! grep -q 'UnitFileState 为空' <<<"$(valid_col "$ROW")" \
  && ok "4v: **not-found 不与 loaded 混判** —— 它的空 UnitFileState 没有触发'必需字段缺失', 判无效的理由另有其名($(valid_col "$ROW"))" \
  || bad "4v: not-found 被按 loaded 的规则判了($(valid_col "$ROW"))"
sect_end "4.采样"
echo; echo "══ 5. 集合与裁决: 名称+唯一性+完整性; 历史无效不靠新查询翻案; 窗口另算 ══"
sect_begin "5.裁决"
mkrow(){ printf '%s\t%s.service\tservice\tsimple\tloaded\t%s\trunning\t%s\t%s\t%s\t0\tisa=%s/0;ise=%s/0\t%s\n' \
           "$1" "$1" "$2" "$3" "$4" "$5" "$2" "$3" "${6:-ok}"; }
B="$WORK/b.tsv"; A="$WORK/a.tsv"
{ mkrow mosdns   active enabled 111 0123456789abcdef0123456789abcdef
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567; } > "$B"
{ mkrow mosdns   active enabled 999 fedcba9876543210fedcba9876543210
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567; } > "$A"

# 5a 健康对照: 桥接链内的变化判正常, 实例更替单列, 意外 0
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$A" t1 ) >"$OUT/v1" 2>&1
{ grep -q '意外 0' "$OUT/v1" && grep -q '实例更替' "$OUT/v1"; } \
  && ok "5a: 健康对照 —— 桥接链内变化判正常, 实例更替**单列**, 意外 0" \
  || { bad "5a: 健康对照不对"; tail -4 "$OUT/v1" | sed 's/^/      /'; }

# 5b pdg-mitm 被停/禁 ⇒ 桥接清单判意外
A2="$WORK/a2.tsv"
{ mkrow mosdns   active   enabled  111 0123456789abcdef0123456789abcdef
  mkrow pdg-mitm inactive disabled 0   ""; } > "$A2"
sed -i 's/\tinactive\trunning/\tinactive\tdead/' "$A2"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$A2" t2 ) >"$OUT/v2" 2>&1
grep -q '意外 1' "$OUT/v2" \
  && ok "5b: pdg-mitm 被停/禁 ⇒ **桥接**清单判意外(退役动作不在这一跳的允许范围)" \
  || { bad "5b: 停/禁没被判意外"; tail -4 "$OUT/v2" | sed 's/^/      /'; }

# 5c 拒绝② 历史字段无效, 后来查询恢复正常 —— 不许用新查询翻案
B_BAD="$WORK/b-bad.tsv"
{ mkrow mosdns   active enabled 111 0123456789abcdef0123456789abcdef
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567 "bad:is-active 查询失败(rc=1, stderr: Connection timed out);"; } > "$B_BAD"
reset_stub; mkunit mosdns; mkunit pdg-mitm      # 桩现在**完全健康** —— 真去查就会"恢复正常"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B_BAD" "$A" t3 ) >"$OUT/v3" 2>&1
{ grep -q '观测无效 1' "$OUT/v3" && grep -q 'Connection timed out' "$OUT/v3" && ! grep -q '意外 0, 观测无效 0' "$OUT/v3"; } \
  && ok "5c: 拒绝② 历史采样那一行无效, **哪怕现在查什么都正常**, 裁决仍判观测无效 —— 不拿新查询给旧采样补证" \
  || { bad "5c: 历史无效被新查询翻案了"; tail -4 "$OUT/v3" | sed 's/^/      /'; }

# 5c2 前后两份记录**各自**证明自己有效: 这次坏在"后"那一份
A_BAD="$WORK/a-bad.tsv"
{ mkrow mosdns   active enabled 999 fedcba9876543210fedcba9876543210
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567 "bad:MainPID 非法值 [];"; } > "$A_BAD"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$A_BAD" t3b ) >"$OUT/v3b" 2>&1
{ grep -q '观测无效 1' "$OUT/v3b" && grep -q '后: MainPID 非法值' "$OUT/v3b"; } \
  && ok "5c2: **后**那一份记录自己无效 ⇒ 同样判观测无效并标明是哪一份(前后各自证明自己, 不互相担保)" \
  || { bad "5c2: 后一份的无效没被单独认出来"; tail -4 "$OUT/v3b" | sed 's/^/      /'; }

# 5d 拒绝③ 用重复服务行顶替缺失服务
DUP="$WORK/dup.tsv"
{ mkrow mosdns active enabled 111 0123456789abcdef0123456789abcdef
  mkrow mosdns active enabled 111 0123456789abcdef0123456789abcdef; } > "$DUP"
( SVC_WATCH=(mosdns pdg-mitm); bridge_set_check "$DUP" t4 ) >"$OUT/v4" 2>&1; R=$?
{ (( R != 0 )) && grep -q '重复服务行' "$OUT/v4"; } \
  && ok "5d: 拒绝③ 用**重复服务行**顶替缺失服务 ⇒ 集合判据当场拒($(cat "$OUT/v4"))" \
  || { bad "5d: 重复行顶替没被拒(rc=$R)"; sed 's/^/      /' "$OUT/v4"; }

# 5e 拒绝④ 行数相同但服务名集合不同
WRONG="$WORK/wrong.tsv"
{ mkrow mosdns active enabled 111 0123456789abcdef0123456789abcdef
  mkrow sshd   active enabled 222 89abcdef0123456789abcdef01234567; } > "$WRONG"
( SVC_WATCH=(mosdns pdg-mitm); bridge_set_check "$WRONG" t5 ) >"$OUT/v5" 2>&1; R=$?
{ (( R != 0 )) && grep -qE '缺服务|清单外' "$OUT/v5"; } \
  && ok "5e: 拒绝④ **行数相同但名字集合不同** ⇒ 判红($(cat "$OUT/v5")) —— 集合核对不是只数行" \
  || { bad "5e: 名字集合不同被放过(rc=$R)"; sed 's/^/      /' "$OUT/v5"; }

# 5f 窗口: 前后采样**逐字节相同**, 但窗口里确实被启动过 ⇒ 单独报"窗口内动作"
WIN="$WORK/win.tsv"; printf 'mosdns\t2\t-\npdg-mitm\t0\t-\n' > "$WIN"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$B" t6 "$WIN" ) >"$OUT/v6" 2>&1
{ grep -q '窗口内动作' "$OUT/v6" && grep -q '窗口内动作 1' "$OUT/v6"; } \
  && ok "5f: 前后采样逐字节相同、窗口里却被启动 2 次 ⇒ **窗口内动作单独报**(两次采样相同不能证明中间没动过)" \
  || { bad "5f: 窗口内动作没被单列"; tail -4 "$OUT/v6" | sed 's/^/      /'; }

# 5g 窗口观测失败 ⇒ 不许只写 note 然后照报"意外 0"
WINBAD="$WORK/winbad.tsv"; printf 'mosdns\tINVALID\t界桩写进去了却读不回来\npdg-mitm\t0\t-\n' > "$WINBAD"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$B" t7 "$WINBAD" ) >"$OUT/v7" 2>&1
{ grep -q '窗口观测无效' "$OUT/v7" && grep -q '被测FAIL' "$OUT/v7"; } \
  && ok "5g: **窗口观测无效** ⇒ 判红并具名, 不产出'意外 0'(没看见 ≠ 没发生)" \
  || { bad "5g: 窗口观测失败被放过"; tail -4 "$OUT/v7" | sed 's/^/      /'; }

# 5h 给了窗口文件却读不了 ⇒ 同样不许说"意外 0"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B" "$B" t8 "$WORK/根本没有这个窗口文件" ) >"$OUT/v8" 2>&1
grep -q '被测FAIL' "$OUT/v8" \
  && ok "5h: 给了窗口结果文件却读不了 ⇒ 判红(不能在没有窗口证据时说'意外 0')" \
  || { bad "5h: 读不了的窗口文件被当成没事"; tail -3 "$OUT/v8" | sed 's/^/      /'; }

# ═══════════════════════════════════════════════════════════════════════════

# 5c3 前后**都**坏 ⇒ 仍然拒绝(而且两边都要点名)
B_BAD2="$WORK/b-bad2.tsv"; A_BAD2="$WORK/a-bad2.tsv"
{ mkrow mosdns   active enabled 111 0123456789abcdef0123456789abcdef
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567 "bad:SubState 查询失败(rc=97, stderr: timed out);"; } > "$B_BAD2"
{ mkrow mosdns   active enabled 111 0123456789abcdef0123456789abcdef
  mkrow pdg-mitm active enabled 222 89abcdef0123456789abcdef01234567 "bad:SubState 查询失败(rc=97, stderr: timed out);"; } > "$A_BAD2"
( SVC_WATCH=(mosdns pdg-mitm); quiet bridge_svc_verdict "$B_BAD2" "$A_BAD2" t3c ) >"$OUT/v3c" 2>&1
{ grep -q '观测无效 1' "$OUT/v3c" && ! grep -q '意外 0, 观测无效 0' "$OUT/v3c"; } \
  && ok "5c3: **前后都坏** ⇒ 仍然拒绝 —— 两份记录逐字节相同也不算'没变过'" \
  || { bad "5c3: 前后都坏却过了"; tail -4 "$OUT/v3c" | sed 's/^/      /'; }
# 5c4 两个空值相同不能证明恢复: 同一字段前后都读不出来, 值都是 <空>
B_E="$WORK/b-empty.tsv"; A_E="$WORK/a-empty.tsv"
printf 'pdg-mitm\tpdg-mitm.service\tservice\tsimple\tloaded\tactive\t<空>\tenabled\t222\t89abcdef0123456789abcdef01234567\t0\tisa=active/0;ise=enabled/0;showfail=SubState/rc=97\tbad:SubState 查询失败(rc=97, stderr: timed out);\n' > "$B_E"
cp "$B_E" "$A_E"
( SVC_WATCH=(pdg-mitm); quiet bridge_svc_verdict "$B_E" "$A_E" t3d ) >"$OUT/v3d" 2>&1
{ grep -q '观测无效 1' "$OUT/v3d" && grep -q '被测FAIL' "$OUT/v3d"; } \
  && ok "5c4: 同一字段前后**都没读到**, 两个 <空> 相同 ⇒ 判观测无效, **不当成'它恢复了/没变过'**" \
  || { bad "5c4: 两个空值相同被当成了正常"; tail -4 "$OUT/v3d" | sed 's/^/      /'; }

# 5f2/5f3/5f4 前记录缺失 / 后记录缺失 / 前后同时缺失 —— 三份记录全部由**真实采样函数**
# 按各自那一刻的桩状态生成, 再交**真实裁决函数**处理; 不手填任何标签。
two_sided(){   # $1=标签 $2=unit $3=前是否置空(1/0) $4=后是否置空(1/0)
  local lbl="$1" u="$2"
  reset_stub; mkunit "$u"; (( $3 )) && sset "$u" UnitFileState "" 0 ""
  sample_one "$u" "$WORK/ts-$lbl.b.tsv"
  reset_stub; mkunit "$u"; (( $4 )) && sset "$u" UnitFileState "" 0 ""
  sample_one "$u" "$WORK/ts-$lbl.a.tsv"
  TS_B="$(valid_col "$(row_of "$u" "$WORK/ts-$lbl.b.tsv")")"
  TS_A="$(valid_col "$(row_of "$u" "$WORK/ts-$lbl.a.tsv")")"
  ( SVC_WATCH=("$u"); ok(){ printf '[被测OK] %s\n' "$1"; }; note(){ :; }; _evn(){ :; }
    bad(){ printf '[被测FAIL] %s\n' "$1"; return 1; }
    bridge_svc_verdict "$WORK/ts-$lbl.b.tsv" "$WORK/ts-$lbl.a.tsv" "$lbl" >"$OUT/ts-$lbl" 2>&1 ); TS_RC=$?
}
two_sided before-only svc-b 1 0
{ (( TS_RC != 0 )) && [[ "$TS_B" == bad:* && "$TS_A" == ok ]] && grep -q '前:' "$OUT/ts-before-only"; } \
  && ok "5f2: **只有前记录**那一份缺了必需字段 ⇒ 裁决拒绝(退出状态 $TS_RC)并标明坏在'前'" \
  || { bad "5f2: 前记录缺失没被拒(前=$TS_B 后=$TS_A rc=$TS_RC)"; tail -3 "$OUT/ts-before-only" | sed 's/^/      /'; }
two_sided after-only svc-a 0 1
{ (( TS_RC != 0 )) && [[ "$TS_B" == ok && "$TS_A" == bad:* ]] && grep -q '后:' "$OUT/ts-after-only"; } \
  && ok "5f3: **只有后记录**那一份缺了必需字段 ⇒ 裁决拒绝(退出状态 $TS_RC)并标明坏在'后'" \
  || { bad "5f3: 后记录缺失没被拒(前=$TS_B 后=$TS_A rc=$TS_RC)"; tail -3 "$OUT/ts-after-only" | sed 's/^/      /'; }
two_sided both svc-ab 1 1
{ (( TS_RC != 0 )) && [[ "$TS_B" == bad:* && "$TS_A" == bad:* ]]; } \
  && ok "5f4: **前后同时缺失** ⇒ 仍然拒绝(退出状态 $TS_RC) —— 两边一样空不算'没变过', 更不算恢复" \
  || { bad "5f4: 前后同时缺失被当成正常(前=$TS_B 后=$TS_A rc=$TS_RC)"; tail -3 "$OUT/ts-both" | sed 's/^/      /'; }
sect_end "5.裁决"
echo; echo "══ 6. 显式空目标(--ref '' / --ref=)落入默认最新版 —— 冻结原文复现 ══"
sect_begin "6.空ref"
# 用**桥接候选**的 install.sh 参数解析原文驱动。只解析, 不安装。
# 验收线自己的 install.sh 没有 --ref(那是桥接版加的), 所以必须按 SHA 取件, 不拿手边那份顶替。
BR_SHA="${PDG_BRIDGE_SHA:-944ccdb302ebf6f2f24c637348cf338d2d3a3686}"
PARSE="$WORK/parse.sh"
if git -C "$REPO" cat-file -e "$BR_SHA^{commit}" 2>/dev/null \
   && git -C "$REPO" show "$BR_SHA:install.sh" > "$WORK/br-install.sh" 2>/dev/null; then
  { echo 'die(){ echo "die: $*"; exit 9; }'
    sed -n '/^PDG_TARGET_REF=""$/,/^fi$/p' "$WORK/br-install.sh"; } > "$PARSE"
else
  : > "$PARSE"
fi
if grep -q 'PDG_TARGET_REF=""' "$PARSE" && bash -n "$PARSE" 2>/dev/null; then
  ok "6-0: 参数解析原文取自桥接候选 ${BR_SHA:0:12}(install.sh 含 $(grep -c -- '--ref' "$WORK/br-install.sh") 处 --ref)"
  probe_ref(){ ( set -- "$@"
    # shellcheck source=/dev/null
    source "$PARSE"
    if [[ -n "$PDG_TARGET_REF" ]]; then echo "目标=$PDG_TARGET_REF"; else echo "目标=<默认: 最新发布>"; fi ) 2>&1; }
  R_NONE="$(probe_ref)"; R_GOOD="$(probe_ref --ref v1.11.16)"
  R_E1="$(probe_ref --ref '')"; R_E2="$(probe_ref --ref=)"
  [[ "$R_NONE" == "目标=<默认: 最新发布>" ]] && ok "6a: 健康对照 —— 省略参数走默认(最新发布)" || bad "6a: 省略参数的行为不对($R_NONE)"
  [[ "$R_GOOD" == "目标=v1.11.16" ]]         && ok "6b: 健康对照 —— 合法指定命中目标" || bad "6b: 合法指定不对($R_GOOD)"
  [[ "$R_E1" == "$R_NONE" ]] && ok "6c: **缺陷复现** --ref '' 与省略参数不可区分 ⇒ 悄悄落入默认最新版" || bad "6c: --ref '' 的行为变了($R_E1)"
  [[ "$R_E2" == "$R_NONE" ]] && ok "6d: **缺陷复现** --ref= 同样落入默认最新版" || bad "6d: --ref= 的行为变了($R_E2)"
  note "6: 这是**产品缺陷**, 本轮只登记不修(A4): 最小修法是给解析加一个'给过 --ref 吗'的标记,"
  note "   给了却为空就报错 —— 不改默认路径, 不加新开关, 也不顺带动已有部署拒绝门(A3)。"
else
  bad "6: 取不到桥接候选 ${BR_SHA:0:12} 的 install.sh 参数解析原文 —— 本节没跑, 没有拿验收线那份顶替"
fi

# ═══════════════════════════════════════════════════════════════════════════
sect_end "6.空ref"
echo; echo "══ 7. 真实加载顺序: 依赖自检的消费者必须先定义, 自检又必须排在前像之前 ══"
sect_begin "7.顺序"
# 这一节验的是**被测脚本自己的先后**, 不是本支把函数全抽出来加载完之后的先后 ——
# 后者与真实执行顺序无关, 正是它把上一版的顺序错误盖住了。
# 组装出来的准备段只覆盖"定义 + 依赖加载 + 自检调用", 不切进 ①/② 那两节(建裸库/取件),
# 也不改写被测脚本第 27-32 行的四道安全闸 —— 本支从来没跑到它们那里。
_DEF_END="$(grep -n '^# <<< PDG-EXTRACT-END bridge_set_check$' "$HOP" | cut -d: -f1)"
_CALL="$(grep -n '^deps_selfcheck || _hard' "$HOP" | head -1 | cut -d: -f1)"
_GUARD="$(grep -n '^for _f in deps_selfcheck bridge_svc_sample bridge_set_check bridge_row_valid; do$' "$HOP" | cut -d: -f1)"
_PRE="$(grep -n '^build_preimage ' "$HOP" | head -1 | cut -d: -f1)"
_DEPS_END="$(grep -n '^# <<< PDG-EXTRACT-END deps_selfcheck$' "$HOP" | cut -d: -f1)"
for _n in bridge_svc_sample bridge_set_check bridge_row_valid; do
  _d="$(grep -n "^$_n(){" "$HOP" | head -1 | cut -d: -f1)"
  { [[ -n "$_d" ]] && [[ -n "$_CALL" ]] && (( _d < _CALL )); } \
    && ok "7a-$_n: 定义@$_d 排在依赖自检调用@$_CALL 之前(调用时已在符号表里)" \
    || bad "7a-$_n: 定义@${_d:-无} **不在**调用@${_CALL:-无}之前 —— 调用时还没定义"
done
{ [[ -n "$_CALL" ]] && [[ -n "$_PRE" ]] && (( _CALL < _PRE )); } \
  && ok "7b: 依赖自检@$_CALL 仍排在前像构造@$_PRE 之前(自检没过就不许动前像与服务)" \
  || bad "7b: 依赖自检@${_CALL:-无} 跑到前像@${_PRE:-无}后面去了"
{ [[ -n "$_GUARD" ]] && (( _GUARD < _CALL )) && (( _CALL - _GUARD < 8 )); } \
  && ok "7c: '消费者已定义'守卫@$_GUARD 紧贴调用@$_CALL —— 顺序再错会当场具名, 不是一句 command not found" \
  || bad "7c: 守卫缺失或离调用太远(守卫@${_GUARD:-无} 调用@${_CALL:-无})"
# 组装准备段。$2=after 用被测脚本现在的先后; before 把守卫与调用挪回定义之前(修前的样子)。
_mkprep(){
  { echo 'set -uo pipefail'
    echo '_hard(){ echo "[HARD-STOP] $1" >&2; exit 1; }'
    echo 'note(){ :; }; ok(){ :; }; SECT(){ :; }; _ev(){ :; }; _evn(){ :; }'
    echo "E2E_TMP=\"$WORK/prep\"; PLAT_SRC=\"$PLAT\""
    echo 'PDG_BRIDGE_SHA=0000000000000000000000000000000000000000'   # 身份输入, 不是安全闸
    echo 'PDG_RETIRE_SHA=1111111111111111111111111111111111111111'
    if [[ "$2" == before ]]; then
      sed -n "51,${_DEPS_END}p" "$HOP"; sed -n "${_GUARD},${_CALL}p" "$HOP"
      sed -n "$((_DEPS_END+1)),${_DEF_END}p" "$HOP"
    else
      sed -n "51,${_DEF_END}p" "$HOP"; sed -n "${_GUARD},${_CALL}p" "$HOP"
    fi
    echo 'echo PREP-OK'
  } > "$1"; }
mkdir -p "$WORK/prep"
_mkprep "$WORK/prep-after.sh" after
bash "$WORK/prep-after.sh" >"$OUT/p1" 2>"$ERR/p1"; _RA=$?
{ (( _RA == 0 )) && grep -q PREP-OK "$OUT/p1"; } \
  && ok "7d: 健康准备按**真实先后**跑完 —— 依赖自检通过(rc=0), 且此刻前像与服务动作都还没开始" \
  || { bad "7d: 健康准备没过(rc=$_RA)"; tail -2 "$ERR/p1" | sed 's/^/      /'; }
_mkprep "$WORK/prep-before.sh" before
bash "$WORK/prep-before.sh" >"$OUT/p2" 2>"$ERR/p2"; _RB=$?
{ (( _RB != 0 )) && grep -q 'bridge_svc_sample' "$ERR/p2" && grep -q 'HARD-STOP' "$ERR/p2"; } \
  && ok "7e: 把调用挪回定义之前(修前的位置)⇒ **具名硬停**(rc=$_RB, 点名 bridge_svc_sample), 不是含糊失败" \
  || { bad "7e: 修前的位置没有具名硬停(rc=$_RB)"; tail -2 "$ERR/p2" | sed 's/^/      /'; }
grep -q PREP-OK "$OUT/p2" \
  && bad "7f: 硬停之后居然还走到了 PREP-OK" \
  || ok "7f: 硬停之后**前像与服务动作都没发生**(PREP-OK 没打印, 准备段就地终止)"
sect_end "7.顺序"

# ═══════════════════════════════════════════════════════════════════════════
echo; echo "══ 8. 汇总记账: 两种口径分开, 不相减 ══"
sect_begin "8.记账"
# 用**真实** sect_audit 与**真实** tally_print(按唯一成对标记取自本文件原文)驱动。
TALLY_SRC="$WORK/tally.sh"
{ grab tally_print "$HERE/$(basename "${BASH_SOURCE[0]}")"; } > "$TALLY_SRC"
{ [[ -s "$TALLY_SRC" ]] && bash -n "$TALLY_SRC"; } \
  && ok "8a: 按标记取到真实 tally_print 原文($(grep -c . "$TALLY_SRC") 行)且语法通过 —— 下面每格跑的都是它" \
  || bad "8a: 取不到真实汇总原文"
# tally_case: $1=普通失败条数 $2=审计是否失败(0/1) $3..=五类计数(缺节 执行异常 重复 额外 完成度不足)
tally_case(){
  ( P=0; F=0; F_PLAIN=0; F_AUDIT=0
    local i; for ((i=0;i<$1;i++)); do F=$((F+1)); F_PLAIN=$((F_PLAIN+1)); done
    (( $2 )) && { F=$((F+1)); F_AUDIT=$((F_AUDIT+1)); }
    _MISS_N="$3"; _ABRT_N="$4"; _DUP_N="$5"; _EXTRA_N="$6"; _SHORT_N="$7"
    # shellcheck source=/dev/null
    source "$TALLY_SRC"
    tally_print; echo "rc=$?" )
}
_neg(){ grep -qE -- '-[0-9]' <<<"$1"; }   # 出现任何负数即判红
# 健康
T="$(tally_case 0 0 0 0 0 0 0)"
{ grep -q '失败 0 条   (普通断言失败 0 条 + 分节审计断言失败 0 条)' <<<"$T" && grep -q 'rc=0' <<<"$T" && ! _neg "$T"; } \
  && ok "8b: 健康 —— 失败 0 条, 两路都是 0, 无负数" || { bad "8b: 健康汇总不对"; sed 's/^/      /' <<<"$T"; }
# 单类缺陷: 只有缺节
T="$(tally_case 0 1 1 0 0 0 0)"
{ grep -q '失败 1 条   (普通断言失败 0 条 + 分节审计断言失败 1 条)' <<<"$T" \
  && grep -q '缺节 1 节 / 执行异常 0 节' <<<"$T" && ! _neg "$T"; } \
  && ok "8c: **单类缺陷**(只有缺节)⇒ 断言条数 1 条全部记在分节审计那一路, 类别行单独报 1 节" \
  || { bad "8c: 单类缺陷汇总不对"; sed 's/^/      /' <<<"$T"; }
# 缺节与中断并存 —— 就是修前算出 -1 的那一组
T="$(tally_case 0 1 1 1 0 0 0)"
{ grep -q '失败 1 条   (普通断言失败 0 条 + 分节审计断言失败 1 条)' <<<"$T" \
  && grep -q '缺节 1 节 / 执行异常 1 节' <<<"$T" && ! _neg "$T"; } \
  && ok "8d: **缺节与中断并存** ⇒ 仍是 1 条审计断言, 类别行报 缺节 1 节 + 执行异常 1 节, **不再出现负数**(修前这里是 -1)" \
  || { bad "8d: 缺节+中断汇总不对"; sed 's/^/      /' <<<"$T"; }
# 普通断言失败与二者并存
T="$(tally_case 3 1 1 1 0 0 0)"
{ grep -q '失败 4 条   (普通断言失败 3 条 + 分节审计断言失败 1 条)' <<<"$T" \
  && grep -q '缺节 1 节 / 执行异常 1 节' <<<"$T" && ! _neg "$T"; } \
  && ok "8e: **普通断言失败与二者并存** ⇒ 4 条 = 普通 3 条 + 审计 1 条(加出来的), 类别行另计" \
  || { bad "8e: 混合场景汇总不对"; sed 's/^/      /' <<<"$T"; }
# 重复/额外/完成度不足不能误归为普通断言失败
T="$(tally_case 0 1 0 0 2 1 3)"
{ grep -q '普通断言失败 0 条' <<<"$T" && grep -q '重复 2 节 / 额外 1 节 / 完成度不足 3 节' <<<"$T" && ! _neg "$T"; } \
  && ok "8f: **重复/额外/完成度不足**只出现在类别行(共 6 节), 普通断言失败仍是 0 条 —— 没被误归" \
  || { bad "8f: 三类被误归"; sed 's/^/      /' <<<"$T"; }
# 五类之和 != 断言条数, 这是允许的(不同计量单位)
T="$(tally_case 0 1 1 1 1 1 1)"
{ grep -q '失败 1 条' <<<"$T" && grep -q '缺节 1 节 / 执行异常 1 节 / 重复 1 节 / 额外 1 节 / 完成度不足 1 节' <<<"$T" && grep -q 'rc=0' <<<"$T"; } \
  && ok "8g: 五类合计 5 节 vs 失败 1 条 —— 两种计量单位不必相等, 汇总自检仍通过(rc=0), 不靠截零或改退出码" \
  || { bad "8g: 单位不同被当成错误"; sed 's/^/      /' <<<"$T"; }
# 撤销对照: 把汇总换回"相减"那一版, 同一组输入重现负数
printf '%s\n' 'tally_print(){ printf "通过 %d, 失败 %d   (其中: 正常断言失败 %d / 缺节 %d / 执行异常 %d)\n" \' \
              '  "$P" "$F" "$(( F - (_MISS_N>0) - (_ABRT_N>0) ))" "${_MISS_N:-0}" "${_ABRT_N:-0}"; }' > "$WORK/tally-old.sh"
T="$( ( P=0; F=1; F_PLAIN=0; F_AUDIT=1; _MISS_N=1; _ABRT_N=1
        # shellcheck source=/dev/null
        source "$WORK/tally-old.sh"; tally_print ) )"
_neg "$T" \
  && ok "8h: 撤销对照 —— 换回相减那一版, 同一组输入(缺节 1 + 执行异常 1, 审计只报 1 条)重现负数: $T" \
  || { bad "8h: 撤销版本没有重现错误计数"; sed 's/^/      /' <<<"$T"; }
sect_end "8.记账"

# ═══════════════════════════════════════════════════════════════════════════
echo; echo "══ N. 撤销对照 ══"
sect_begin "N.撤销"
# N1 撤回"空数组不许占位" ⇒ 1d 那一格失守
sed 's/(( cnt > 0 )) ||/(( cnt >= 0 )) ||/' "$UT" > "$WORK/rev-deps.sh"
reset_stub; mkunit m; mkunit n
( # shellcheck source=/dev/null
  source "$WORK/rev-deps.sh"
  # shellcheck disable=SC2034  # 被 eval/source 进来的被测原文读, 静态分析看不到那层引用
  E2E_OWNED_UNITS=(); SVC_WATCH=(m n)
  # shellcheck disable=SC2034  # 被 eval/source 进来的被测原文读, 静态分析看不到那层引用
  EXTRACT_DEPS=(E2E_OWNED_UNITS SVC_WATCH)
  deps_selfcheck ) >/dev/null 2>&1 \
  && ok "N1: 撤回'空数组不许占位' ⇒ 空依赖被放行, 1d 那一格失守(证明该格在测这条路径)" \
  || bad "N1: 撤销版本仍然拒绝, 反例没有区分力"
# N2 撤回"采样当时定有效性", 改成裁决时现查 ⇒ 5c 那一格失守
sed 's/^  \[\[ "\$v" == ok \]\] || { OBS_WHY="\${v#bad:}"; return 1; }$/  systemctl is-active "$(cut -d"$TAB" -f1 <<<"$1")" >\/dev\/null 2>\&1; return 0/' "$UT" > "$WORK/rev-obs.sh"
grep -q 'systemctl is-active' "$WORK/rev-obs.sh" || cp "$UT" "$WORK/rev-obs.sh"
( # shellcheck source=/dev/null
  source "$WORK/rev-obs.sh"; SVC_WATCH=(mosdns pdg-mitm)
  ok(){ printf '[被测OK] %s\n' "$1"; }; bad(){ printf '[被测FAIL] %s\n' "$1"; }; note(){ :; }; _evn(){ :; }
  bridge_svc_verdict "$B_BAD" "$A" n2 ) >"$OUT/n2" 2>&1
grep -q '观测无效 0' "$OUT/n2" \
  && ok "N2: 撤回'采样当时定有效性'、改成裁决时现查 ⇒ 桩现在健康, 历史那一行被翻案成有效, 5c 那一格失守" \
  || { bad "N2: 撤销版本没暴露出来"; tail -3 "$OUT/n2" | sed 's/^/      /'; }
# N3 撤回"桥接专用清单": 把同一笔数据交给**退役**那一对(svc_class + svc_verdict 的原文)
( eval "$(grab svc_class "$PLAT")"; eval "$(grab svc_verdict "$PLAT")"
  SVC_WATCH=(mosdns pdg-mitm); EVID="$WORK/evid"; _evn(){ :; }
  ok(){ printf '[被测OK] %s\n' "$1"; }; bad(){ printf '[被测FAIL] %s\n' "$1"; }; note(){ :; }
  # 退役那一对读的是 7 列格式, 给它喂等价的 7 列
  printf 'mosdns\tactive\trunning\tenabled\t111\t0123456789abcdef0123456789abcdef\t0\npdg-mitm\tactive\trunning\tenabled\t222\t89abcdef0123456789abcdef01234567\t0\n' > "$WORK/b7.tsv"
  printf 'mosdns\tactive\trunning\tenabled\t111\t0123456789abcdef0123456789abcdef\t0\npdg-mitm\tinactive\tdead\tdisabled\t0\t\t0\n' > "$WORK/a7.tsv"
  # shellcheck disable=SC2034  # 被 eval/source 进来的被测原文读, 静态分析看不到那层引用
  sc_get(){ SC_VAL="x"; SC_RC=0; SC_ERR=""; }
  svc_verdict "$WORK/b7.tsv" "$WORK/a7.tsv" n3 ) >"$OUT/n3" 2>&1
{ grep -q '意外 0' "$OUT/n3" && grep -q 'WLOC 退役专属 1' "$OUT/n3"; } \
  && ok "N3: 同一笔数据交给**退役**那一对判 ⇒ pdg-mitm 被停/禁算成'退役专属'且意外 0 —— 借用它就会放过 5b" \
  || { bad "N3: 退役那一对没给出预期归类"; tail -3 "$OUT/n3" | sed 's/^/      /'; }
# N4 撤回"槽位按记录判", 改成硬把 previous 当必需 ⇒ 2a 那一格失守
if [[ -d "${R1:-/nonexistent}" ]]; then
  [[ -e "$R1$ART_REL/previous.mobileconfig" ]] \
    && bad "N4: 单版本前像里居然有 previous 产物 —— 反例前提不成立" \
    || ok "N4: 撤回'按记录判槽位'、改成硬要求 previous.mobileconfig 存在 ⇒ 合法的单版本前像会被判成'保留失败'(该文件本就不该有)"
else
  bad "N4: 2a 的沙箱没建起来, 这一格没跑"
fi
# N5 无关注释对照
sed '1a\# 这行注释不参与任何判定' "$UT" > "$WORK/cmt.sh"
( # shellcheck source=/dev/null
  # shellcheck disable=SC2034  # 被 eval/source 进来的被测原文读, 静态分析看不到那层引用
  source "$WORK/cmt.sh"
  # shellcheck disable=SC2034  # 被 eval/source 进来的被测原文读, 静态分析看不到那层引用
  SVC_WATCH=(mosdns pdg-mitm)
  ok(){ printf '[被测OK] %s\n' "$1"; }; bad(){ printf '[被测FAIL] %s\n' "$1"; }; note(){ :; }; _evn(){ :; }
  bridge_svc_verdict "$B" "$A2" n5 ) >"$OUT/n5" 2>&1
_norm(){ sed -E 's/\b(t2|n5)\b/<场景>/g' "$1"; }
if diff -q <(_norm "$OUT/v2") <(_norm "$OUT/n5") >/dev/null 2>&1; then
  ok "N5: 无关注释对照 —— 结论与输出逐字节相同(只有场景名不同), 零新增失败"
else
  bad "N5: 只加一行注释, 输出却变了"; diff <(_norm "$OUT/v2") <(_norm "$OUT/n5") | head -6 | sed 's/^/      /'
fi

# ═══════════════════════════════════════════════════════════════════════════
echo; echo "──────────────────────────────────────────────"
# N6 撤回"每次 show 查询都看 rc/stderr" ⇒ 4j/4k 失守
sed 's/^    if (( SRC != 0 )); then$/    if false; then/' "$UT" > "$WORK/rev-showq.sh"
reset_stub; mkunit svc-n6; sset svc-n6 SubState "" 97 "Failed to get properties: Connection timed out"
( # shellcheck source=/dev/null
  source "$WORK/rev-showq.sh"
  # shellcheck disable=SC2034  # 被 source 进来的被测原文读
  SVC_WATCH=(svc-n6)
  bridge_svc_sample "$WORK/n6.tsv" ) >/dev/null 2>&1
ROW="$(row_of svc-n6 "$WORK/n6.tsv" 2>/dev/null)"
{ [[ -n "$ROW" ]] && ! grep -q 'SubState 查询失败' <<<"$(valid_col "$ROW")"; } \
  && ok "N6: 撤回'show 查询看 rc' ⇒ SubState 那次失败不再被记成查询失败, 4j 那一格失守" \
  || bad "N6: 撤销版本仍然记了查询失败, 反例没有区分力(第13列=$(valid_col "$ROW"))"
# N7 撤回"loaded 的空 UnitFileState 判必需字段缺失" ⇒ 4q/4r/4s/4t 一起失守
#    撤法: 把空值那一支改回"什么都不做"(即上一版豁免的极限形态 —— 一律放行)
sed 's/^                     "") \[\[ "\$load" == loaded \]\] \\$/                     "") if false; then :; fi \\/' "$UT" > "$WORK/rev-ufs.sh"
sed -i 's/^                           \&\& why="\${why}UnitFileState 为空而 LoadState=loaded.*$/                           ;;/' "$WORK/rev-ufs.sh"
if bash -n "$WORK/rev-ufs.sh" 2>/dev/null; then
  reset_stub; mkunit n7svc; sset n7svc UnitFileState "" 0 ""
  ( # shellcheck source=/dev/null
    source "$WORK/rev-ufs.sh"
    # shellcheck disable=SC2034  # 被 source 进来的被测原文读
    SVC_WATCH=(n7svc)
    bridge_svc_sample "$WORK/n7.tsv" ) >/dev/null 2>&1
  _r="$(row_of n7svc "$WORK/n7.tsv" 2>/dev/null)"
  { [[ -n "$_r" ]] && bridge_row_valid "$_r"; } \
    && ok "N7: 撤回'loaded 的空 UnitFileState 判缺失' ⇒ 该记录**重新被接受**, 4q/4r/4s/4t 一起失守" \
    || bad "N7: 撤销版本仍然判无效, 反例没有区分力($(valid_col "$_r"))"
else
  bad "N7: 撤销版本语法不过, 这一格没跑"
fi
sect_end "N.撤销"
echo "── 执行有效性: 声明集合 vs 实际登记 ──"
sect_audit "$SECT_LOG" "$SECT_EXPECT" "$SECT_BEG" >"$OUT/audit" 2>&1; _AUDRC=$?
sed 's/^/  /' "$OUT/audit"
(( _AUDRC == 0 )) \
  && ok "执行有效性: $(grep -c . <<<"$SECT_EXPECT") 个**声明**要跑的节全部跑到且条数达标(缺节/执行异常/重复/额外/完成度五类分别核过, 不看总数)" \
  || bad_sect "执行有效性: 缺节 $SECT_MISSING 节 / 执行异常 $SECT_ABORTED 节 / 重复 $SECT_DUP 节 / 额外 $SECT_EXTRA 节 / 完成度不足 $SECT_SHORT 节(上面逐类列出)"
_MISS_N="$SECT_MISSING"; _ABRT_N="$SECT_ABORTED"; _DUP_N="$SECT_DUP"; _EXTRA_N="$SECT_EXTRA"; _SHORT_N="$SECT_SHORT"
# 判据自身的区分力: 拿合成的分节账喂给同一支 sect_audit, 四类问题各验一次。
_sa(){ printf '%b' "$1" > "$WORK/sa.log"; printf '%b' "${3:-甲\n乙\n}" > "$WORK/sa.beg"
       sect_audit "$WORK/sa.log" "$2" "$WORK/sa.beg" >"$OUT/sa" 2>&1; echo $?; }
_D=$'甲:2\n乙:2'
[[ "$(_sa '甲\t2\n乙\t2\n' "$_D")" == 0 ]] \
  && ok "审计自证 a: 健康完整执行 ⇒ 通过" || { bad "审计自证 a: 健康的也判红"; sed 's/^/      /' "$OUT/sa"; }
{ [[ "$(_sa '甲\t1\n乙\t2\n' "$_D")" != 0 ]] && grep -q '没跑全' "$OUT/sa"; } \
  && ok "审计自证 b: **正文少跑但登记还在** ⇒ 判红(完成度不足)" || { bad "审计自证 b: 少跑没被发现"; sed 's/^/      /' "$OUT/sa"; }
{ [[ "$(_sa '甲\t2\n' "$_D" '甲\n')" != 0 ]] && grep -q '缺失' "$OUT/sa" && grep -q '缺节=1 执行异常=0' "$OUT/sa"; } \
  && ok "审计自证 c: **整节连开始都没有** ⇒ 记**缺节**(不是执行异常) —— 遍历日志的旧判据在这里看不见它" || { bad "审计自证 c: 整节缺失没被发现或归错类"; sed 's/^/      /' "$OUT/sa"; }
{ [[ "$(_sa '甲\t2\n' "$_D" '甲\n乙\n')" != 0 ]] && grep -q '执行异常' "$OUT/sa" && grep -q '缺节=0 执行异常=1' "$OUT/sa"; } \
  && ok "审计自证 f: **开始了却没落幕**(正文跑到一半断了)⇒ 记**执行异常**, 与缺节分开记账" || { bad "审计自证 f: 执行异常没被单列"; sed 's/^/      /' "$OUT/sa"; }
{ [[ "$(_sa '甲\t2\n甲\t2\n' "$_D" '甲\n')" != 0 ]] && grep -q '重复登记' "$OUT/sa" \
  && grep -q '乙.*缺失' "$OUT/sa" && grep -q '缺节=1 执行异常=0 重复=1' "$OUT/sa"; } \
  && ok "审计自证 d: **重复登记抵不掉缺节** ⇒ 重复与缺节两条一起报, 各自计数" || { bad "审计自证 d: 重复抵消了缺节"; sed 's/^/      /' "$OUT/sa"; }
{ [[ "$(_sa '甲\t2\n乙\t2\n丙\t2\n' "$_D")" != 0 ]] && grep -q '额外' "$OUT/sa"; } \
  && ok "审计自证 e: **额外的节**(登记了却不在声明集合里)⇒ 判红" || { bad "审计自证 e: 额外节没被发现"; sed 's/^/      /' "$OUT/sa"; }
_PRINTED="$(grep -c . "$ALOG")"; _TOTAL=$((P+F))
if [[ "$_PRINTED" == "$_TOTAL" ]]; then ok "计数对账: 打印 $_PRINTED 条断言, 全部进了总数"
else bad "计数对账: 打印 $_PRINTED 条, 只有 $_TOTAL 条进了总数"; fi
note "stdout/stderr/退出码分别留在 $OUT 与 $ERR(随本支退出清理); 本支不产生真实服务动作。"
echo "──────────────────────────────────────────────"
# 两种口径各自成行, 明确计量单位, 互不相减:
#   第一行  断言条数(单位: 条)  —— F 由 F_PLAIN 与 F_AUDIT 相加而来, 不是减出来的;
#   第二行  分节审计发现(单位: 节) —— 类别数量, 与断言条数不是同一种量,
#           它们的总和**不必**等于失败断言条数(五类可以同时出现在同一条断言里)。
# >>> PDG-EXTRACT-BEGIN tally_print
tally_print(){   # 汇总打印的**唯一实现**; 定向测试按标记取它的原文来驱动
printf '通过 %d, 失败 %d 条   (普通断言失败 %d 条 + 分节审计断言失败 %d 条)\n' \
  "$P" "$F" "$F_PLAIN" "$F_AUDIT"
printf '分节审计发现(单位: 节, 不计入上面的条数): 缺节 %d 节 / 执行异常 %d 节 / 重复 %d 节 / 额外 %d 节 / 完成度不足 %d 节\n' \
  "${_MISS_N:-0}" "${_ABRT_N:-0}" "${_DUP_N:-0}" "${_EXTRA_N:-0}" "${_SHORT_N:-0}"
(( F == F_PLAIN + F_AUDIT )) \
  || { printf '汇总自检失败: F=%d 而 F_PLAIN+F_AUDIT=%d\n' "$F" "$((F_PLAIN+F_AUDIT))"; return 2; }
return 0
}
# <<< PDG-EXTRACT-END tally_print
tally_print || exit 2
(( F == 0 )) || exit 1

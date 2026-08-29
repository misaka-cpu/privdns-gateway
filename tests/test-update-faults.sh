#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Issue 2 回归: cmd_update 关键步骤失败必须**立即回滚 + 返回非0 + 不打印"✅ 已更新"**。
# 覆盖故障注入: git reset 失败 / 必需文件安装失败 / __migrate 非0 / 内核更新失败 /
#              daemon-reload 失败; 以及正常路径仍走到"✅ 已更新"。
# 沙箱化: 抽出 cmd_update, 打桩全部外部副作用(git/install/systemctl/内核/快照/回滚),
#         用环境开关注入单点故障, 断言"是否调用了 cmd_rollback"与"是否谎报成功"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }

sed -n '/^cmd_update(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" > "$WORK/upd.sh"
# cmd_update 现在先问一次"这次到底是不是在往前走"(_update_release_relation)。判据要**真**跟着
# 抽出来: 缺了它, cmd_update 会在第一道门上就 command-not-found → 判不出关系 → 拒绝执行,
# 于是下面每一条故障注入都打在同一个空处, 而它们本来是要测后面那些阶段的。
sed -n '/^_update_release_relation(){/,/^}/p' "$ROOT/deploy/bot/pdg.sh" >> "$WORK/upd.sh"

mkdir -p "$WORK/repo/.git"          # 让 [[ -d $REPO_DIR/.git ]] 为真, 跳过 clone
# cmd_update 会 source 运行模块清单(lib/modules.sh)。桩仓库里给一份**同名同函数**的替身:
# 真的那份会去校验源文件存在, 而这里的"仓库"是空的。替身同时提供 FAIL_MODULES 故障注入 ——
# "运行模块装不上"必须和其它必需文件一样触发回滚, 否则会留下新旧混装。
mkdir -p "$WORK/repo/lib"
# 名字取自**真实**清单(source 它拿到 PDG_RUNTIME_MODULES), 于是逐模块的 FAIL_INSTALL 注入
# 照旧有效 —— 桩内调的是被打桩的 install。
# 桩必须**按平台**展开, 与真实 pdg_platform_modules 同构。只展开 PDG_RUNTIME_MODULES 的话,
# `PLATFORM=ios` 下 iOS 那五件根本不会被 install 碰到 —— 于是"iOS 组件装失败必须回滚"那几条
# 注入永远打空, 而测试照样全绿(注入未命中守卫就是为抓这个加的)。
( source "$ROOT/lib/modules.sh"
  echo 'pdg_install_runtime_modules(){'
  echo '  [[ -n "${FAIL_MODULES:-}" ]] && return 1'
  echo '  local _plat="${3:-${PDG_PLATFORM:-}}"'
  while read -r _src _name _mode; do
    [[ -n "$_src" ]] || continue
    echo "  install -m$_mode \"\$1/$_src\" \"\${2:-/opt/pdg-bot}/$_name\" || return 1"
  done <<< "$PDG_RUNTIME_MODULES"
  echo '  if [[ "$_plat" == ios ]]; then'
  while read -r _src _name _mode; do
    [[ -n "$_src" ]] || continue
    echo "    install -m$_mode \"\$1/$_src\" \"\${2:-/opt/pdg-bot}/$_name\" || return 1"
  done <<< "$PDG_IOS_MODULES"
  echo '  fi'
  echo '  return 0'
  echo '}'
) > "$WORK/repo/lib/modules.sh"

cat > "$WORK/harness.sh" <<'EOF'
REPO_DIR="$WORK/repo"; REPO_URL="file:///dev/null"; ENVF="$WORK/none.env"
need_root(){ :; }; _lock(){ :; }
c_g(){ echo "$*"; }; c_y(){ echo "$*"; }
sleep(){ :; }
_pdg_platform(){ echo "${PLATFORM:-android}"; }
_pdg_core(){ echo singbox; }
pdg_fetch_release_tags(){ return 0; }
# 全桩 git: 只控制 reset 成败, 其余给出稳定输出
git(){
  local a=("$@"); [[ "${a[0]:-}" == "-C" ]] && a=("${a[@]:2}")
  case "${a[0]:-}" in
    reset)     [[ -n "${FAIL_RESET:-}" ]] && return 1; return 0;;
    rev-parse) echo "0000000000000000000000000000000000000000";;
    tag)       echo "v9.9.9";;
    describe)  echo "v9.9.9";;
    log)       :;;
    *)         return 0;;
  esac
}
# 必需文件安装的故障注入。判据是**受管目标的 basename 或序号**, 不是命令行的字面形态 ——
# 把 `install … /opt/pdg-bot/` 换成 `install … /opt/pdg-bot/<name>` 这种等价改写, 旧的
# 子串匹配就静默失效, 于是"iOS 组件装失败必须回滚"那五条一条都不会真跑, 而测试照样全绿。
#
# FAIL_TARGET=<basename>  命中该目标名时失败
# FAIL_NTH=<n>            第 n 个落在受管目录下的目标失败(1 起)
# 命中与否写进 $WORK/e2e-inject-hit, 由 assert_fail_rollback 复核 —— 没命中就判测试自己失败。
PDG_MANAGED_DIR=/opt/pdg-bot
: > "$WORK"/e2e-inject-hit
install(){
  local last="${*: -1}" base n
  base="$(basename -- "$last")"
  case "$last" in
    "$PDG_MANAGED_DIR"/*|"$PDG_MANAGED_DIR")
      n=$(( $(wc -l < "$WORK"/e2e-inject-count 2>/dev/null || echo 0) + 1 ))
      echo "$n $base" >> "$WORK"/e2e-inject-count
      if [[ -n "${FAIL_TARGET:-}" && "$base" == "${FAIL_TARGET}" ]]; then
        echo "hit target=$base" >> "$WORK"/e2e-inject-hit; return 1
      fi
      if [[ -n "${FAIL_NTH:-}" && "$n" == "${FAIL_NTH}" ]]; then
        echo "hit nth=$n base=$base" >> "$WORK"/e2e-inject-hit; return 1
      fi;;
  esac
  # 兼容既有用例仍在用的整路径子串形态(/usr/local/bin/pdg 之类的非受管目标)
  if [[ -n "${FAIL_INSTALL:-}" && "$*" == *"${FAIL_INSTALL}"* ]]; then
    echo "hit substr=${FAIL_INSTALL}" >> "$WORK"/e2e-inject-hit; return 1
  fi
  return 0
}
# __migrate 经 `bash /usr/local/bin/pdg __migrate` 调用 → 拦 bash 函数
bash(){ [[ "$*" == *__migrate* ]] && return "${MIGRATE_RC:-0}"; command bash "$@"; }
_update_core_binary(){ [[ -n "${FAIL_CORE:-}" ]] && return 1; return 0; }
systemctl(){ [[ "${1:-}" == daemon-reload && -n "${FAIL_RELOAD:-}" ]] && return 1; return 0; }
python3(){
  case "$*" in
    *py_compile*) return 0;;
    *doctor.py*)
      [[ -n "${DOCTOR_RC:-}" ]] && return "$DOCTOR_RC"
      case "${DOCTOR_OUT:-ok}" in
        ok)      echo '[{"level":"ok","check":"服务","detail":"都在"}]';;
        warn)    echo '[{"level":"ok","check":"服务","detail":"都在"},{"level":"warn","check":"证书","detail":"30天内到期"}]';;
        fail)    echo '[{"level":"fail","check":"防火墙","detail":"7893 对全网开放"}]'; return 1;;
        onlybot) echo '[{"level":"ok","check":"平台","detail":"android"},{"level":"fail","check":"服务","detail":"未运行: pdg-bot"}]'; return 1;;
        empty)   printf '';;
        badjson) echo '{ not json';;
        notarr)  echo '{"level":"ok"}';;
      esac
      return 0;;
    *) command python3 "$@";;
  esac
}
sing-box(){ return 0; }
mihomo(){ return 0; }
nft(){ return 0; }
# 快照: 造真文件让门通过; 回滚: 只记录被调用(并返回0, 便于观察上层是否谎报成功)
cmd_snapshot(){ _PDG_SNAP_CREATED="$WORK/snap"; mkdir -p "$_PDG_SNAP_CREATED"; : | gzip > "$_PDG_SNAP_CREATED/snap.tar.gz"; return 0; }
cmd_rollback(){ echo "ROLLBACK_CALLED $*"; return 0; }
EOF

export WORK
run(){ # $1=额外环境赋值串(NAME=VALUE, 无空格); 运行 cmd_update, 打印 "<rc>|<输出>"
  local rc=0 out
  # shellcheck disable=SC2086  # $1 需按词拆成 env 的 NAME=VALUE 参数
  out=$(env $1 bash -c "source '$WORK/harness.sh'; source '$WORK/upd.sh'; cmd_update" 2>&1) || rc=$?
  printf '%s\n' "$rc|$out"
}

assert_success(){ # 正常路径: rc0 + 有"✅ 已更新" + 无 ROLLBACK
  local r; r=$(run "$1"); local rc="${r%%|*}" out="${r#*|}"
  { [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out" && ! grep -q ROLLBACK_CALLED <<<"$out"; } \
    && ok "正常路径: 走到 ✅ 已更新, 未回滚" || bad "happy: rc=$rc out=$out"
}
assert_fail_rollback(){ # 故障路径: rc非0 + 有 ROLLBACK + 无"✅ 已更新"
  local desc="$1" env="$2" r
  : > "$WORK"/e2e-inject-hit; : > "$WORK"/e2e-inject-count
  r=$(run "$env"); local rc="${r%%|*}" out="${r#*|}"
  # 注入没命中就说明这条根本没测到东西 —— 判测试自己失败, 不是判产品通过。
  if [[ "$env" == *FAIL_TARGET=* || "$env" == *FAIL_NTH=* || "$env" == *FAIL_INSTALL=* ]] \
     && [[ ! -s "$WORK"/e2e-inject-hit ]]; then
    bad "$desc: 故障注入**未命中**(受管目标共 $(wc -l < "$WORK"/e2e-inject-count 2>/dev/null || echo 0) 个) —— 这条没测到任何东西"
    # 结构化结果: 让外层守卫能区分"updater 正常失败"/"注入未命中"/"测试环境损坏",
    # 而不是都看成一个非零退出码。
    echo "RESULT=injection-not-hit" >> "${PDG_FAULT_RESULT:-/dev/null}"
    return
  fi
  { [[ "$rc" != 0 ]] && grep -q ROLLBACK_CALLED <<<"$out" && ! grep -q '✅ 已更新' <<<"$out"; } \
    && ok "$desc → 回滚 + 非0 + 不谎报成功" || bad "$desc: rc=$rc out=$out"
}

# 受控的"故意打空"自检场景: 指定一个**不存在**的受管目标名, 真跑一次 harness。
# fake install 不会产生命中记录 → 上面那条守卫必须让整套判失败。外层 false-green 守卫
# 靠它做行为验证, 而不是 grep 本文件里有没有某个字符串。
if [[ -n "${PDG_FAULT_SELFTEST:-}" ]]; then
  assert_fail_rollback "自检: 指定不存在的受管目标(应报未命中)" "PLATFORM=ios FAIL_TARGET=__no_such_target__"
  echo "────────────────────────────────────────"
  echo "通过 $pass, 失败 $nfail"
  [[ "$nfail" == 0 ]]
  exit $?
fi

assert_success ""
assert_fail_rollback "git reset 失败"        "FAIL_RESET=1"
assert_fail_rollback "必需文件(bot.py)安装失败" "FAIL_INSTALL=/opt/pdg-bot/bot.py"
assert_fail_rollback "必需文件(report.py)安装失败" "FAIL_INSTALL=report.py"
assert_fail_rollback "必需文件(pdg 主脚本)安装失败" "FAIL_INSTALL=/usr/local/bin/pdg"
assert_fail_rollback "__migrate 迁移非0"       "MIGRATE_RC=1"
assert_fail_rollback "运行模块安装失败"         "FAIL_MODULES=1"
assert_fail_rollback "内核二进制更新失败"       "FAIL_CORE=1"
assert_fail_rollback "daemon-reload 失败"      "FAIL_RELOAD=1"
# ── doctor 校验门: 命令失败/输出不可信一律回滚, 绝不跳过后报成功 ──
assert_fail_rollback "doctor 命令非0"          "DOCTOR_RC=2"
assert_fail_rollback "doctor 输出为空"          "DOCTOR_OUT=empty"
assert_fail_rollback "doctor 输出非法 JSON"     "DOCTOR_OUT=badjson"
assert_fail_rollback "doctor 输出不是数组"      "DOCTOR_OUT=notarr"
assert_fail_rollback "doctor 报 fail 项"        "DOCTOR_OUT=fail"

# 校验门不再按**文案**豁免任何检查项。以前是: 未配 token 时把 detail 恰好等于
# "未运行: pdg-bot" 的那条 fail 挑出来忽略 —— 只要 doctor 那句话改个措辞或多一个服务名,
# 豁免就失效, 没配 bot 的机器会永远升级失败。现在改由 doctor 自己按凭据状态决定要不要把
# pdg-bot 列进必需服务(checks.expected_services), 校验门只管"有没有 fail"。
grep -q '未运行: pdg-bot' "$ROOT/deploy/bot/pdg.sh" \
  && bad "pdg.sh 里仍有按文案豁免的逻辑(应改由 checks.expected_services 决定)" \
  || ok "校验门不再按 detail 文案豁免检查项"
r=$(run "DOCTOR_OUT=onlybot"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" != 0 ]] && grep -q ROLLBACK_CALLED <<<"$out" && ! grep -q '✅ 已更新' <<<"$out"; } \
  && ok "doctor 报 fail(不论文案是什么)→ 一律回滚, 不再有例外" || bad "文案豁免仍在: rc=$rc out=$out"

# 只有 warn: 应当仍算成功, 且把警告展示出来
r=$(run "DOCTOR_OUT=warn"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out" && grep -q '证书' <<<"$out" && ! grep -q ROLLBACK_CALLED <<<"$out"; } \
  && ok "仅 warn: 正常完成 + 警告被解析展示" || bad "warn 路径: rc=$rc out=$out"

# ══ iOS 平台组件: 在 iOS 上是必需件, 装失败必须回滚(不能 ||true 后留旧版混装) ══
# 按**受管目标名**注入(mobileconfig 在目标侧是改名后的 pdg-dot.mobileconfig.tmpl)
for f in mitm_ca.py mitm_server.py mitm_wloc.py pdg-dot.mobileconfig.tmpl; do
  assert_fail_rollback "iOS: $f 安装失败" "PLATFORM=ios FAIL_TARGET=$f"
done
# probe81.py 是**公共件**(6.1B): 两平台都装, 所以两平台装失败都必须回滚 ——
# 放进上面的 iOS 循环会漏掉 Android 那一半。
for p in ios android; do
  assert_fail_rollback "$p: probe81.py(公共件)安装失败" "PLATFORM=$p FAIL_TARGET=probe81.py"
done
# 第一个 / 中间 / 最后一个受管目标各失败一次 —— 覆盖遍历的头、中、尾
assert_fail_rollback "受管目标 #1 安装失败"  "PLATFORM=ios FAIL_NTH=1"
assert_fail_rollback "受管目标 #12 安装失败" "PLATFORM=ios FAIL_NTH=12"
# 清单**末项**。数字跟着 lib/modules.sh 的 iOS 全集走 —— tests/test-false-green-guard.sh
# 会核对这里的 FAIL_NTH 是否等于当前全集项数, 对不上就红。改清单必须一起改这里, 否则
# "末项失败也能回滚"这条就没被测到, 而它恰恰是最容易漏的那一项。
# 沿革: 6.1C 加 nftlive.py, 6.2B 加 dotwitness.py, 内网面板加 lanroute.py + lanpanel.py。
assert_fail_rollback "受管目标 #36 安装失败" "PLATFORM=ios FAIL_NTH=36"   # 末项序号 = iOS 清单长度; 加模块时必须跟着改(见 HANDOFF §10.5)

# Android: 这几个 iOS 专属文件根本不该被安装 → 即使注入同名失败也不影响更新。
# probe81.py 不在此列了 —— 它现在 Android 也装, 装失败必须回滚(见上面的公共件循环)。
for f in mitm_ca.py pdg-dot.mobileconfig.tmpl; do
  r=$(run "PLATFORM=android FAIL_TARGET=$f"); rc="${r%%|*}"; out="${r#*|}"
  { [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out"; } \
    && ok "Android: 不安装 iOS 文件 $f(注入其失败也不影响更新)" || bad "Android/$f: rc=$rc out=$out"
done

# iOS 全部就绪 → 正常完成
r=$(run "PLATFORM=ios"); rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" == 0 ]] && grep -q '✅ 已更新' <<<"$out" && ! grep -q ROLLBACK_CALLED <<<"$out"; } \
  && ok "iOS: 五个平台组件均安装成功 → 正常完成" || bad "iOS happy: rc=$rc out=$out"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

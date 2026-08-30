#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 换内核版本时, 唯一容易出错的一步是**手工抄两串 64 位十六进制**。抄错一位的后果不是
# "少了点什么", 而是装机直接 die 在 SHA 校验上 —— 而报错指向供应链异常, 看不出是笔误。
#
# tools/bump-kernel.sh 把那一步做掉: 取件 → 核对这份二进制确实是要的那个版本 → 改写
# lib/versions.sh → 打印 diff。**它只改钉值, 不提交、不推送、不发版** —— 后面那一整套
# (全量 + E2E + PR + CI + tag)一步都不省, 因为 E2E 矩阵按 MIHOMO_VER 取件, 钉值一改
# 就是在新内核上真跑一遍, 那才是"这版会不会弄坏分流"的答案来源。
#
# 这一支钉住工具的契约, 不联网(取件动作由调用方在真实环境验证)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-bumpkernel.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
TOOL="$ROOT/tools/bump-kernel.sh"

echo "══ 1. 工具存在且可执行 ══"
[[ -f "$TOOL" ]] && ok "tools/bump-kernel.sh 存在" || bad "tools/bump-kernel.sh 不存在"
[[ -x "$TOOL" ]] && ok "可执行位已设" || bad "没有可执行位"
[[ -f "$TOOL" ]] || { echo "────────"; echo "test-bump-kernel-tool.sh: 通过 $pass, 失败 $nfail"; exit 1; }
bash -n "$TOOL" && ok "bash -n 通过" || bad "语法错"

echo
echo "══ 2. 只改钉值: 不提交、不推送、不打 tag、不发版 ══"
# 工具越界最难查 —— 它跑在维护者的真仓库上。这几条按**代码**判(去注释), 不看说明文字。
code(){ sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#[^"'"'"']*$//' "$TOOL"; }
for w in 'git commit' 'git push' 'git tag' 'gh release' 'gh pr' 'git add'; do
  if code | grep -q -- "$w"; then bad "工具里出现 \`$w\` —— 越界了"; else ok "没有 \`$w\`"; fi
done
code | grep -qE '\bsudo\b' && bad "工具里出现 sudo(它只改仓库文件, 不该动系统)" || ok "没有 sudo"
# 只允许写 lib/versions.sh
# 只盯**仓库内**的写入。工具当然要往自己的临时下载目录写东西, 那不是越界 ——
# 第一版把 `> "$out/binary"` 也算进去了, 而 $out 是 mktemp 出来的。
w=$(code | grep -oE '>[[:space:]]*"?\$(ROOT|VERSIONS)[^"]*' | grep -v 'VERSIONS' | head -3)
[[ -z "$w" ]] && ok "没有往 lib/versions.sh 以外的仓库路径写" || bad "疑似写了仓库别处: $w"

echo
echo "══ 3. 用法与参数校验(不联网也应立刻拒绝坏输入)══"
run(){ ( cd "$WORK" && PDG_BUMP_ROOT="$WORK/repo" bash "$TOOL" "$@" 2>&1 ); }
mkdir -p "$WORK/repo/lib"; cp "$ROOT/lib/versions.sh" "$WORK/repo/lib/versions.sh"
# 前像: 「没误伤另一侧」那两格拿它比, 而不是写死某个版本号
PRE_MIHOMO="$(sed -n 's/^MIHOMO_VER="\([^"]*\)".*/\1/p' "$ROOT/lib/versions.sh")"
PRE_MOSDNS="$(sed -n 's/^MOSDNS_VER="\([^"]*\)".*/\1/p' "$ROOT/lib/versions.sh")"
out=$(run); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE '用法|usage' <<<"$out"; } && ok "无参数 → 非零 + 打印用法" || bad "无参数时 rc=$rc: $(head -2 <<<"$out")"
out=$(run nosuchcomp v1.2.3); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE 'mihomo|mosdns' <<<"$out"; } && ok "组件名非法 → 拒绝并列出支持的组件" || bad "组件名非法时 rc=$rc"
for v in 1.19.30 v1.19 vX.Y.Z 'v1.19.30; rm -rf /'; do
  out=$(run mihomo "$v"); rc=$?
  [[ "$rc" != 0 ]] && ok "版本号形态非法被拒: $(printf %q "$v")" || bad "接受了非法版本号: $(printf %q "$v")"
done

echo
echo "══ 4. 两种钉值形状都要认 ══"
# mihomo 只钉归档; mosdns 还多钉一份"解压后二进制"。工具漏掉后者 = 换版之后 doctor 判红。
c=$(code)
# 键名是拼出来的(${COMP}-bin-${arch}), 字面量 "mosdns-bin-" 不会出现在代码里 ——
# 判"有没有区分两种钉值形状"这件事本身; 真正的证据在第 8 节(改完读文件核对)。
grep -q -- '-bin-' <<<"$c" && ok "区分了两种钉值形状(多出的 -bin- 那一份)" \
  || bad "没处理 -bin- 那一份 —— 换 mosdns 版本会漏掉一半钉值"
grep -qE 'mihomo-linux-\$\{?[A-Za-z_]+\}?-\$' <<<"$c" && ok "mihomo 资产名带版本号(官方就是这个形态)" \
  || bad "mihomo 资产名拼错(官方是 mihomo-linux-<arch>-<ver>.gz)"
grep -qE 'mosdns-linux-\$\{?[A-Za-z_]+\}?\.zip' <<<"$c" && ok "mosdns 资产名不带版本号(官方就是这个形态)" \
  || bad "mosdns 资产名拼错(官方是 mosdns-linux-<arch>.zip)"
for a in amd64 arm64; do grep -q "$a" <<<"$c" && ok "覆盖 $a" || bad "漏了 $a"; done

echo
echo "══ 5. 取件后必须核对「这份东西确实是要的那个版本」══"
grep -qE 'sha256sum' <<<"$c" && ok "算 SHA256" || bad "不算 SHA256"
grep -qE '\-v|version' <<<"$c" && ok "核对二进制自报版本(防哈希贴错对象)" || bad "不核自报版本"
grep -qE 'ELF|e_machine|\\x7fELF|od |xxd|head -c' <<<"$c" \
  && ok "对跑不动的那个架构也有校验(ELF 机器类型), 不是只信 URL" \
  || bad "非本机架构完全没校验 —— 下错架构不会被发现"
grep -qE 'curl -fsSL|curl -f' <<<"$c" && ok "curl 带 -f(HTTP 错误不当成成功)" || bad "curl 没带 -f"

echo
echo "══ 6. 改写是**替换钉值**, 不是追加, 且改完给人看 ══"
grep -qE 'diff|git diff' <<<"$c" && ok "改完打印 diff 供人过目" || bad "不打印 diff"
# 同上: 常量名由组件名推出来(VER_KEY), 字面量不出现。判那条路存在, 行为证据在第 7 节。
grep -q 'VER_KEY' <<<"$c" && ok "会改版本常量本身(经 VER_KEY)" || bad "只改哈希不改版本号"
# 幂等/安全: 工作树脏时应拒绝, 免得把别人的改动混进去
grep -qE 'porcelain|diff --quiet|status' <<<"$c" && ok "会检查工作树是否干净" || bad "不检查工作树, 可能把无关改动混进去"

echo
echo "══ 7. 真跑一次改写(离线, 用预置的假下载器)══"
# 只验"改写"这一半: 取件那一半要真网络, 由调用方在真实环境验证(见工具自己的输出)。
if grep -q 'PDG_BUMP_FETCHER' <<<"$c"; then
  ok "留了可替换的取件入口(PDG_BUMP_FETCHER), 改写逻辑可离线验证"
  cat > "$WORK/fake-fetch.sh" <<'F'
#!/usr/bin/env bash
# $1=组件 $2=版本 $3=架构 $4=输出目录 → 造出 <dir>/archive 与 <dir>/binary, 并打印两行 sha
set -euo pipefail
mkdir -p "$4"
printf 'archive-%s-%s-%s' "$1" "$2" "$3" > "$4/archive"
printf 'binary-%s-%s-%s' "$1" "$2" "$3" > "$4/binary"
F
  chmod 755 "$WORK/fake-fetch.sh"
  out=$( cd "$WORK" && PDG_BUMP_ROOT="$WORK/repo" PDG_BUMP_FETCHER="$WORK/fake-fetch.sh" \
         PDG_BUMP_SKIP_VERIFY=1 bash "$TOOL" mihomo v9.9.9 2>&1 ); rc=$?
  if [[ "$rc" == 0 ]]; then
    ok "离线改写跑通"
    grep -q 'MIHOMO_VER="v9.9.9"' "$WORK/repo/lib/versions.sh" && ok "版本常量已改写" || bad "版本常量没改"
    n=$(grep -cE '^MIHOMO_VER=' "$WORK/repo/lib/versions.sh")
    [[ "$n" == 1 ]] && ok "版本常量仍只有一行(替换而非追加)" || bad "版本常量变成 $n 行"
    a=$(printf 'archive-mihomo-v9.9.9-amd64' | sha256sum | cut -d' ' -f1)
    grep -q "\[mihomo-amd64\]=\"$a\"" "$WORK/repo/lib/versions.sh" && ok "amd64 钉值 = 归档的真实 sha256" || bad "amd64 钉值不对"
    b=$(printf 'archive-mihomo-v9.9.9-arm64' | sha256sum | cut -d' ' -f1)
    grep -q "\[mihomo-arm64\]=\"$b\"" "$WORK/repo/lib/versions.sh" && ok "arm64 钉值 = 归档的真实 sha256" || bad "arm64 钉值不对"
    # 比的是**前像**, 不是写死的版本号: 那个值每次换版都会合法地变, 钉死它等于让这支测试
    # 在工具第一次真被使用的那天自己转红(第一版就是这样)。
    grep -q "MOSDNS_VER=\"$PRE_MOSDNS\"" "$WORK/repo/lib/versions.sh" \
      && ok "没有误伤 mosdns 那一侧(仍是 $PRE_MOSDNS)" || bad "动了 mosdns"
    bash -n "$WORK/repo/lib/versions.sh" && ok "改写后 versions.sh 仍能解析" || bad "改写后语法坏了"
    ( set -a; . "$WORK/repo/lib/versions.sh"; [[ "${PDG_SHA256[mihomo-amd64]}" == "$a" ]] ) \
      && ok "source 出来的关联数组取值正确" || bad "source 后取不到正确的值"
  else
    bad "离线改写失败 rc=$rc: $(tail -3 <<<"$out")"
  fi
else
  bad "没有可替换的取件入口 —— 改写逻辑无法离线验证(那这一支就只能扫字符串)"
fi

echo
echo "══ 8. mosdns 侧: 两份钉值都要动 ══"
if grep -q 'PDG_BUMP_FETCHER' <<<"$c"; then
  cp "$ROOT/lib/versions.sh" "$WORK/repo/lib/versions.sh"
  out=$( cd "$WORK" && PDG_BUMP_ROOT="$WORK/repo" PDG_BUMP_FETCHER="$WORK/fake-fetch.sh" \
         PDG_BUMP_SKIP_VERIFY=1 bash "$TOOL" mosdns v8.8.8 2>&1 ); rc=$?
  [[ "$rc" == 0 ]] && ok "mosdns 改写跑通" || bad "mosdns 改写失败: $(tail -2 <<<"$out")"
  grep -q 'MOSDNS_VER="v8.8.8"' "$WORK/repo/lib/versions.sh" && ok "MOSDNS_VER 已改" || bad "MOSDNS_VER 没改"
  za=$(printf 'archive-mosdns-v8.8.8-amd64' | sha256sum | cut -d' ' -f1)
  ba=$(printf 'binary-mosdns-v8.8.8-amd64' | sha256sum | cut -d' ' -f1)
  grep -q "\[mosdns-amd64\]=\"$za\"" "$WORK/repo/lib/versions.sh" && ok "归档钉值已改" || bad "归档钉值不对"
  grep -q "\[mosdns-bin-amd64\]=\"$ba\"" "$WORK/repo/lib/versions.sh" && ok "解压后二进制钉值已改(两份都动了)" || bad "mosdns-bin 钉值没改"
  [[ "$za" != "$ba" ]] && ok "两份钉值确实是不同的对象" || bad "两份钉值相同, 说明钉错了对象"
  grep -q "MIHOMO_VER=\"$PRE_MIHOMO\"" "$WORK/repo/lib/versions.sh" \
    && ok "没有误伤 mihomo 那一侧(仍是 $PRE_MIHOMO)" || bad "动了 mihomo"
fi

echo "────────────────────────────────────────"
echo "test-bump-kernel-tool.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

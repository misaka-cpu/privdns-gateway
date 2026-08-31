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
# shellcheck source=tests/repoguard.sh
source "$ROOT/tests/repoguard.sh"    # e2e_git: 守卫与动作绑成一件事(见 test-e2e-repo-guard.py)

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
    _act(){ sed -n "s/^  \\[$1\\]=\"\\([^\"]*\\)\".*/\\1/p" "$WORK/repo/lib/versions.sh" | head -1; }
    grep -q "\[mihomo-amd64\]=\"$a\"" "$WORK/repo/lib/versions.sh" && ok "amd64 钉值 = 归档的真实 sha256" \
      || bad "amd64 钉值不对: 实得 '$(_act mihomo-amd64)', 期望 '$a'; 工具输出: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
    b=$(printf 'archive-mihomo-v9.9.9-arm64' | sha256sum | cut -d' ' -f1)
    grep -q "\[mihomo-arm64\]=\"$b\"" "$WORK/repo/lib/versions.sh" && ok "arm64 钉值 = 归档的真实 sha256" \
      || bad "arm64 钉值不对: 实得 '$(_act mihomo-arm64)', 期望 '$b'"
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
  _act2(){ sed -n "s/^  \\[$1\\]=\"\\([^\"]*\\)\".*/\\1/p" "$WORK/repo/lib/versions.sh" | head -1; }
  grep -q "\[mosdns-amd64\]=\"$za\"" "$WORK/repo/lib/versions.sh" && ok "归档钉值已改" \
    || bad "归档钉值不对: 实得 '$(_act2 mosdns-amd64)', 期望 '$za'; 工具输出: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  grep -q "\[mosdns-bin-amd64\]=\"$ba\"" "$WORK/repo/lib/versions.sh" && ok "解压后二进制钉值已改(两份都动了)" \
    || bad "mosdns-bin 钉值不对: 实得 '$(_act2 mosdns-bin-amd64)', 期望 '$ba'"
  [[ "$za" != "$ba" ]] && ok "两份钉值确实是不同的对象" || bad "两份钉值相同, 说明钉错了对象"
  grep -q "MIHOMO_VER=\"$PRE_MIHOMO\"" "$WORK/repo/lib/versions.sh" \
    && ok "没有误伤 mihomo 那一侧(仍是 $PRE_MIHOMO)" || bad "动了 mihomo"
fi

echo
echo "══ 9. awk 实现无关: mawk 与 gawk 都要给出同一个结果 ══"
# 由来是一次真事故: 改写用 `awk -v pat='^  \[mihomo-amd64\]='` 传正则, 而 -v 会处理转义 ——
# gawk 把 `\[` 变成裸 `[`, 于是 pat 成了字符类 `[mihomo-amd64]`, a-6 是非法区间 → gawk fatal,
# awk 进程死掉、`&&` 短路、文件原样不动。Debian 默认 mawk 保持原样, 照常匹配。
# 于是同一份脚本本机全绿、CI(gawk)上**版本号换了哈希没换**, 而且不报错。
# 现在改写走 index()+ENVIRON(都不碰正则也不做转义), 这一格拿两种 awk 各跑一遍钉住它。
if grep -q 'ENVIRON\[' <<<"$c" && ! grep -qE "awk -v (pat|p)=" <<<"$c"; then
  ok "改写不再把正则喂给 awk -v(用 index()+ENVIRON)"
else
  bad "改写仍在用 awk -v 传正则 —— gawk 上会静默失效"
fi
for AWKBIN in mawk gawk; do
  command -v "$AWKBIN" >/dev/null 2>&1 || { echo "[NOTE] 本机没有 $AWKBIN, 该实现未验(CI 上有 gawk)"; continue; }
  d="$WORK/awk-$AWKBIN"; mkdir -p "$d/bin" "$d/repo/lib"
  ln -sf "$(command -v "$AWKBIN")" "$d/bin/awk"
  cp "$ROOT/lib/versions.sh" "$d/repo/lib/versions.sh"
  if PATH="$d/bin:$PATH" PDG_BUMP_ROOT="$d/repo" PDG_BUMP_FETCHER="$WORK/fake-fetch.sh" \
     PDG_BUMP_SKIP_VERIFY=1 bash "$TOOL" mihomo v9.9.9 >/dev/null 2>&1; then
    x=$(printf 'archive-mihomo-v9.9.9-amd64' | sha256sum | cut -d' ' -f1)
    grep -q "\[mihomo-amd64\]=\"$x\"" "$d/repo/lib/versions.sh" \
      && ok "$AWKBIN 下钉值写对了" \
      || bad "$AWKBIN 下钉值没写对(实得 $(sed -n 's/^  \[mihomo-amd64\]="\([^"]*\)".*/\1/p' "$d/repo/lib/versions.sh" | head -1))"
    grep -q 'MIHOMO_VER="v9.9.9"' "$d/repo/lib/versions.sh" && ok "$AWKBIN 下版本常量也对" || bad "$AWKBIN 下版本常量没改"
  else
    bad "$AWKBIN 下工具直接失败了"
  fi
done

echo
echo "══ 10. 原子性: 中途失败时正式文件逐字节不变 ══"
# 这个脚本要改 3~6 行, 其中大多数是 64 位十六进制。逐次直写正式文件时, 中途任何一次失败
# 都会把它停在"版本换了、第二个哈希没换"的半套状态 —— 装机会 die 在 SHA 校验上, 报错
# 指向供应链异常, 现场根本看不出是工具写了一半。
atom(){ rm -rf "$WORK/atom"; mkdir -p "$WORK/atom/lib"; cp "$ROOT/lib/versions.sh" "$WORK/atom/lib/versions.sh"; }
atom
# 制造"第二个哈希替换失败": 把 [mihomo-bin-arm64] 那一行删掉 → 该锚点命中 0 次 → 必须整体放弃
grep -v '\[mihomo-bin-arm64\]' "$WORK/atom/lib/versions.sh" > "$WORK/atom/lib/v2" \
  && mv "$WORK/atom/lib/v2" "$WORK/atom/lib/versions.sh"
BEFORE="$(sha256sum "$WORK/atom/lib/versions.sh" | cut -d' ' -f1)"
out=$( cd "$WORK" && PDG_BUMP_ROOT="$WORK/atom" PDG_BUMP_FETCHER="$WORK/fake-fetch.sh" \
       PDG_BUMP_SKIP_VERIFY=1 bash "$TOOL" mihomo v9.9.9 2>&1 ); rc=$?
AFTER="$(sha256sum "$WORK/atom/lib/versions.sh" | cut -d' ' -f1)"
[[ "$rc" != 0 ]] && ok "锚点命中 0 次 → 非零退出" || bad "缺锚点却成功了(rc=$rc)"
[[ "$BEFORE" == "$AFTER" ]] \
  && ok "中途失败后正式文件**逐字节不变**(sha ${BEFORE:0:12}…)" \
  || bad "正式文件被改成了半套状态 —— 这正是原子性要挡的"
grep -qE 'MIHOMO_VER="v9\.9\.9"' "$WORK/atom/lib/versions.sh" \
  && bad "版本号已经被写进去了(半套状态)" || ok "版本号也没被写进去(不是只回滚了哈希)"
compgen -G "$WORK/atom/lib/versions.sh.pdg-bump.*" >/dev/null \
  && bad "留下了暂存文件残骸" || ok "没有暂存文件残留"

echo
echo "══ 11. 暂存文件必须与目标同目录(跨文件系统 mv 不是原子的)══"
c2="$(sed -E 's/^[[:space:]]*#.*$//' "$TOOL")"
[[ "$(grep -c 'mktemp "${VERSIONS}' <<<"$c2" || true)" != 0 ]] \
  && ok "暂存文件建在 \$VERSIONS 同目录" || bad "暂存文件不在目标同目录 —— mv 可能跨文件系统"
[[ "$(grep -c 'mv -f "\$STAGE" "\$VERSIONS"' <<<"$c2" || true)" != 0 ]] \
  && ok "用 mv 原子替换(不是 cat 覆盖)" || bad "没有用 mv 做原子替换"

echo
echo "══ 12. 目标文件已有改动时拒绝(注释与实现必须一致)══"
atom
printf '\n# someone else was here\n' >> "$WORK/atom/lib/versions.sh"
# 会写 ref/config 的 git 一律走 e2e_git —— 守卫与动作绑成一件事, 不存在"忘了守"的形态。
# (`git init` 不受限: 仓库还不存在时守卫必然假拒。)
git init -q -b main "$WORK/atom" >/dev/null 2>&1
e2e_git "$WORK/atom" config user.email t@t        >/dev/null 2>&1
e2e_git "$WORK/atom" config user.name t           >/dev/null 2>&1
e2e_git "$WORK/atom" config commit.gpgsign false  >/dev/null 2>&1
e2e_git "$WORK/atom" add -A                       >/dev/null 2>&1
e2e_git "$WORK/atom" commit -qm base              >/dev/null 2>&1
printf '\n# uncommitted change\n' >> "$WORK/atom/lib/versions.sh"
B2="$(sha256sum "$WORK/atom/lib/versions.sh" | cut -d' ' -f1)"
out=$( cd "$WORK" && PDG_BUMP_ROOT="$WORK/atom" PDG_BUMP_FETCHER="$WORK/fake-fetch.sh" \
       PDG_BUMP_SKIP_VERIFY=1 bash "$TOOL" mihomo v9.9.9 2>&1 ); rc=$?
{ [[ "$rc" != 0 ]] && [[ "$(sha256sum "$WORK/atom/lib/versions.sh" | cut -d' ' -f1)" == "$B2" ]]; } \
  && ok "目标文件有未提交改动 → 拒绝且不动它" || bad "目标文件脏时仍然改写了(rc=$rc)"
# 注释若写"工作树必须干净", 实现却只查目标文件 —— 文案要准确
[[ "$(grep -c '工作树必须干净' "$TOOL" || true)" == 0 ]] \
  && ok '注释没把范围说成整个工作区(实现查的只是目标文件)' \
  || bad "注释说工作树, 实现只查 lib/versions.sh —— 文案与实现不符"

echo
echo "══ 13. 官方 asset digest: 精确资产名 + 不一致就拒绝 ══"
[[ "$(grep -c '_official_digest' <<<"$c2" || true)" != 0 ]] \
  && ok "有官方 digest 交叉核对" || bad "没有 digest 交叉核对"
[[ "$(grep -c 'select(.name==' <<<"$c2" || true)" != 0 ]] \
  && ok "按**精确资产名**匹配(==), 不是通配" || bad "资产名不是精确匹配 —— 同 tag 下有 20+ 个相似名"
[[ "$(grep -c 'releases/tags/\$ver' <<<"$c2" || true)" != 0 ]] \
  && ok "按精确 tag 取" || bad "没有按精确 tag 取"
[[ "$(grep -c '拒绝写文件' <<<"$c2" || true)" != 0 ]] \
  && ok "digest 不一致 → 拒绝写文件" || bad "digest 不一致没有拒绝写文件"
# 相似资产名不得命中: 用真实的 mihomo 资产名家族做判据
for n in mihomo-linux-amd64-compatible-v1.19.30.gz mihomo-linux-amd64-v1-v1.19.30.gz \
         mihomo-linux-amd64-v3-go123-v1.19.30.gz mihomo-linux-amd64-v1.19.30.deb; do
  [[ "$n" == "mihomo-linux-amd64-v1.19.30.gz" ]] && bad "相似名 $n 与目标名相等?!" || :
done
ok "相似资产名清单(compatible/-v1-/-v3-go123-/.deb)与目标名互不相等 —— 精确匹配才不会抓错"
# 文案: 不许把 GitHub digest 说成独立签名
[[ "$(grep -c '不构成独立的签名信任链' "$TOOL" || true)" != 0 ]] \
  && ok "文案说清 digest 不是独立签名信任链" || bad "文案把 digest 说成了独立信任链"
[[ "$(grep -c '不发布独立的签名校验文件' "$TOOL" || true)" != 0 ]] \
  && ok "文案说清上游没有独立签名校验文件" || bad "文案没交代上游无签名文件"

echo
echo "══ 14. PDG_BUMP_SKIP_VERIFY 不得成为正式取件路径的后门 ══"
atom
out=$( cd "$WORK" && PDG_BUMP_ROOT="$WORK/atom" PDG_BUMP_SKIP_VERIFY=1 \
       bash "$TOOL" mihomo v9.9.9 2>&1 ); rc=$?
{ [[ "$rc" != 0 ]] && grep -q 'PDG_BUMP_FETCHER' <<<"$out"; } \
  && ok "官方下载路径 + SKIP_VERIFY → 明确拒绝(它只能配测试取件器)" \
  || bad "SKIP_VERIFY 在官方路径上被接受了 —— 那是跳过全部证据的后门(rc=$rc)"

echo
echo "══ 15. 非本机架构: 完整 ELF 头, 伪造 e_machine 不够 ══"
[[ "$(grep -c '_elf_header_ok' <<<"$c2" || true)" != 0 ]] && ok "用的是完整 ELF 头判据" || bad "还是只读 e_machine"
for k in '7f454c46' 'EI_CLASS' 'EI_DATA'; do
  [[ "$(grep -c "$k" "$TOOL" || true)" != 0 ]] && ok "ELF 判据覆盖 $k" || bad "ELF 判据没覆盖 $k"
done
# 真造一个"只把 18-19 伪造成 amd64"的非 ELF 文件, 它必须过不了
mkdir -p "$WORK/elf"
python3 - "$WORK/elf/fake" <<'PYX'
import sys
b = bytearray(b'NOT-AN-ELF-AT-ALL...' + b'\x00'*40)
b[18:20] = b'\x3e\x00'          # 伪造 e_machine = x86-64
open(sys.argv[1], 'wb').write(bytes(b))
PYX
if bash -c "source <(sed -n '/^_elf_header_ok(){/,/^}/p' '$TOOL'); say(){ :; }; _elf_header_ok '$WORK/elf/fake' amd64" 2>/dev/null; then
  bad "伪造 e_machine 的非 ELF 文件通过了判据"
else ok "伪造 e_machine 的非 ELF 文件被拒(magic/class 挡住了)"; fi

echo
echo "══ 16. 反向对照: 无关注释不得凭空制造失败 ══"
# 上面多条断言扫的是**去注释后**的代码。往工具里塞一段只含关键词的注释, 断言数不该变。
cp "$TOOL" "$WORK/tool-commented.sh"
printf '\n# 无关注释: git commit git push sudo 工作树必须干净 select(.name== \n' >> "$WORK/tool-commented.sh"
c3="$(sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#[^"'"'"']*$//' "$WORK/tool-commented.sh")"
n_extra=0
for w in 'git commit' 'git push' 'sudo'; do
  [[ "$(grep -c -- "$w" <<<"$c3" || true)" != 0 ]] && n_extra=$((n_extra+1))
done
[[ "$n_extra" == 0 ]] && ok "注释里的关键词不会被算成代码(去注释判据有效)" \
  || bad "注释被当成代码了 —— 会造出 $n_extra 条假失败"

echo "────────────────────────────────────────"
echo "test-bump-kernel-tool.sh: 通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

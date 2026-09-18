#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 公开入口 `--ref <版本 tag>` 的判定契约: **指定的版本确实被装上**, 而不是"永远装最新"。
#
# 跑法有意分两层, 分开记账:
#   · 真两段自举(端到端): 建一个**自有测试源**(一次性裸库, 里面有三个版本 tag), clone 出来,
#     用 `unshare --map-root-user` 拿到 EUID=0(不是真 root, 也不装任何东西)跑**真的** install.sh。
#     它会真的 fetch、真的 checkout、真的 exec 重跑自己, 走到"显式目标贯穿到实际安装"那道门,
#     然后在 source lib/versions.sh 处被测试源里的哨兵挡下(exit 77) —— 整机安装一步都不做。
#   · 取件身份: 判据落在 **git 实读**(HEAD 的 commit、tag 对象类型)上, 不是数命令字符串,
#     也不是"函数被调用过"。
#
# 测试源里的 v9.9.x-*-TEST 是**只存在于这个一次性裸库**的私有 tag: 不推官方、不伪造 Release,
# 本支通过 **不** 等于"正式发布来源已验证"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$ROOT/install.sh"
[[ -f "$INSTALL" ]] || { echo "[未执行] 找不到 $INSTALL"; exit 1; }
command -v git >/dev/null || { echo "[未执行] 没有 git"; exit 1; }
unshare --map-root-user --mount true 2>/dev/null || { echo "[未执行] 建不出用户命名空间(拿不到 EUID=0), 不退回真 root, 也不冒充通过"; exit 1; }
WORK="$(mktemp -d)" || { echo "[未执行] 建不出临时目录"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
PWNED="$WORK/pwned-sentinel"   # "带 shell 内容"那一格的哨兵: 真被执行才会出现

P=0; F=0; ALOG="$WORK/assert.log"; : > "$ALOG"
ok(){  printf '[OK]   %s\n' "$1"; P=$((P+1)); printf 'OK\t%s\n' "$1" >> "$ALOG"; }
bad(){ printf '[FAIL] %s\n' "$1"; F=$((F+1)); printf 'FAIL\t%s\n' "$1" >> "$ALOG"; }
note(){ printf '[NOTE] %s\n' "$1"; }
g(){ git -C "$1" "${@:2}"; }

# ── 自有测试源: 一次性裸库, 三个版本 tag(旧版 / 桥接 / 版本号更高的退役目标)─────
SRCREPO="$WORK/src"; BARE="$WORK/origin.git"
mkdir -p "$SRCREPO"; g "$SRCREPO" init -q -b main
g "$SRCREPO" config user.email t@e2e.test; g "$SRCREPO" config user.name t
mkver(){   # $1=版本名 $2=tag
  mkdir -p "$SRCREPO/deploy/mosdns" "$SRCREPO/lib"
  printf '%s\n' "$1" > "$SRCREPO/VERSION-MARK"
  printf 'listen: "0.0.0.0:53"   # %s\n' "$1" > "$SRCREPO/deploy/mosdns/config.yaml"
  cp "$INSTALL" "$SRCREPO/install.sh"
  # 哨兵: install.sh 走完自举与身份门之后第一件事就是 source 它 —— 在这里停住,
  # 整机安装一步都不做。这不是给被测脚本加开关, 而是**测试源自己**的内容。
  printf '#!/usr/bin/env bash\necho "SENTINEL-VERSION=%s"\nexit 77\n' "$1" > "$SRCREPO/lib/versions.sh"
  g "$SRCREPO" add -A; g "$SRCREPO" commit -qm "$1"
  g "$SRCREPO" tag -a "$2" -m "$2"
  g "$SRCREPO" rev-parse HEAD
}
C_OLD="$(mkver old-v1.11.15 v1.11.15)"
C_BRIDGE="$(mkver bridge v9.9.8-bridge-TEST)"
C_RETIRE="$(mkver retire v9.9.9-retire-TEST)"
git clone -q --bare "$SRCREPO" "$BARE"
ok "0: 自有测试源就绪 —— 旧版 ${C_OLD:0:7}(v1.11.15) / 桥接 ${C_BRIDGE:0:7}(v9.9.8-bridge-TEST) / 退役 ${C_RETIRE:0:7}(v9.9.9-retire-TEST, 版本号最高)"
[[ "$(g "$BARE" tag -l 'v*' --sort=-v:refname | head -1)" == v9.9.9-retire-TEST ]] \
  && ok "0b: 按 install.sh 用的排序规则, 最高版本是**退役目标** —— 指定桥接时它就是最容易被误装的那个" \
  || bad "0b: 排序不对: $(g "$BARE" tag -l 'v*' --sort=-v:refname | head -1)"

# ── 真两段自举: clone 一份工作副本, 跑真的 install.sh ────────────────────────
run_install(){   # $@=传给 install.sh 的参数 → 打印 "RC=<码>" 与全部输出
  local d="$WORK/wc.$RANDOM"; git clone -q "$BARE" "$d" >/dev/null 2>&1
  g "$d" checkout -q "$C_OLD"          # 机器上现在是旧版, 和真实升级现场一样
  local out rc
  out="$(unshare --map-root-user --mount env -u PDG_TAG_BOOTSTRAPPED PDG_NONINTERACTIVE=1 \
         bash "$d/install.sh" "$@" 2>&1)"; rc=$?
  printf 'HEAD=%s\n' "$(g "$d" rev-parse HEAD)"
  printf 'RC=%s\n' "$rc"
  printf '%s\n' "$out"
}
gv(){ grep -m1 "^$1=" <<<"$OUT" | cut -d= -f2-; }

echo; echo "══ 1. 显式指定桥接版: 装的必须是桥接, 不是最高版本 ══"
OUT="$(run_install --ref v9.9.8-bridge-TEST)"
[[ "$(gv HEAD)" == "$C_BRIDGE" ]] \
  && ok "1a: 两段自举跑完, 仓库 HEAD = 桥接 ${C_BRIDGE:0:7}(不是最高版 ${C_RETIRE:0:7})" \
  || bad "1a: HEAD=$(gv HEAD)"
grep -q 'SENTINEL-VERSION=bridge' <<<"$OUT" \
  && ok "1b: 实际安装链**走到了**桥接那一版的文件(哨兵来自 v9.9.8 的 lib/versions.sh)" || bad "1b: 哨兵不对"
grep -q '指定版本已贯穿到实际安装' <<<"$OUT" \
  && ok "1c: 安装前那道身份门明确说了「指定版本已贯穿」" || bad "1c: 没有身份门的输出"
grep -q '使用\*\*指定\*\*发布 v9.9.8-bridge-TEST' <<<"$OUT" \
  && ok "1d: 日志写明了这是**指定**版本(含 tag 对象类型与 commit)" || bad "1d"
[[ "$(gv RC)" == 77 ]] && ok "1e: 停在测试源自己的哨兵上(rc=77), 整机安装一步没做" || bad "1e: rc=$(gv RC)"

echo; echo "══ 2. 不给参数: 原有默认契约不变(仍是最新发布 tag) ══"
OUT="$(run_install)"
[[ "$(gv HEAD)" == "$C_RETIRE" ]] && ok "2a: 默认入口仍选最高版本 ${C_RETIRE:0:7}" || bad "2a: HEAD=$(gv HEAD)"
grep -q '使用最新发布 v9.9.9-retire-TEST' <<<"$OUT" && ok "2b: 日志仍是「使用最新发布」" || bad "2b"
grep -q 'SENTINEL-VERSION=retire' <<<"$OUT" && ok "2c: 走到的是最高版本的文件" || bad "2c"

echo; echo "══ 3. 两段自举之后身份仍然一致 ══"
OUT="$(run_install --ref v1.11.15)"
{ [[ "$(gv HEAD)" == "$C_OLD" ]] && grep -q 'SENTINEL-VERSION=old-v1.11.15' <<<"$OUT"; } \
  && ok "3a: 指定更**旧**的版本也照样命中(HEAD=${C_OLD:0:7}) —— 不是只会往新走" || bad "3a: HEAD=$(gv HEAD)"
grep -c '指定版本已贯穿到实际安装' <<<"$OUT" | grep -qx 1 \
  && ok "3b: 身份门在最终那一段跑了一次(自举标记只管控制流, 不替代核验)" || bad "3b"

echo; echo "══ 4. 拒绝的那些: 都要明确失败, 不许悄悄回退到最新版 ══"
rej(){   # $1=说明 $2..=参数
  local why="$1"; shift
  OUT="$(run_install "$@")"
  { [[ "$(gv RC)" != 0 ]] && [[ "$(gv RC)" != 77 ]] && [[ "$(gv HEAD)" == "$C_OLD" ]] \
    && ! grep -q 'SENTINEL-VERSION=retire' <<<"$OUT"; } \
    && ok "4: $why ⇒ 明确拒绝(rc=$(gv RC)), 仓库仍停在旧版, **没有**改装最新版" \
    || bad "4: $why 没被拒(rc=$(gv RC) HEAD=$(gv HEAD))"
}
rej "不存在的 tag"            --ref v9.9.7-nope-TEST
rej "分支名当版本"            --ref main
rej "裸 SHA 当版本"           --ref "$C_BRIDGE"
# 这一格喂的是**单个**恶意参数, 不是让它执行。哨兵放在本支自有的临时目录里:
# 写死 /tmp/pwned 会被临时物卫生守卫判红(它盯的就是写死的 /tmp 路径), 而且真被执行时
# 会在宿主 /tmp 里留下东西。$PWNED 随 $WORK 一起被 EXIT trap 清掉。
rej "带 shell 内容"           --ref "v1.0; touch $PWNED"
[[ ! -e "$PWNED" ]] \
  && ok "4: 那段 shell 内容**没有被执行**(哨兵未生成: $PWNED)" \
  || bad "4: 哨兵被创建了 —— 参数里的 shell 内容真的跑了: $PWNED"
rej "带路径分隔符"            --ref refs/tags/v1.11.15
rej "--ref 后面没跟值"        --ref
# tag 存在但 peel 不出提交(指向 blob 的轻量 tag)⇒ 也要停
g "$SRCREPO" tag -f v9.9.6-blob-TEST "$(printf x | git -C "$SRCREPO" hash-object -w --stdin)" >/dev/null 2>&1
g "$BARE" fetch -q "$SRCREPO" '+refs/tags/*:refs/tags/*' 2>/dev/null
rej "tag 指向的不是提交"      --ref v9.9.6-blob-TEST
# 取件失败(origin 不可达)⇒ 停, 不拿本地旧对象凑合
D="$WORK/wc-broken"; git clone -q "$BARE" "$D" >/dev/null 2>&1; g "$D" checkout -q "$C_OLD"
g "$D" remote set-url origin "$WORK/no-such-origin.git"
OUTB="$(unshare --map-root-user --mount env -u PDG_TAG_BOOTSTRAPPED PDG_NONINTERACTIVE=1 \
        bash "$D/install.sh" --ref v9.9.8-bridge-TEST 2>&1)"; RCB=$?
{ [[ "$RCB" != 0 ]] && [[ "$RCB" != 77 ]] && [[ "$(g "$D" rev-parse HEAD)" == "$C_OLD" ]] \
  && grep -q '取件失败' <<<"$OUTB"; } \
  && ok "4: 取件失败 ⇒ 明确失败并具名(rc=$RCB), 没有拿本地对象假装装上了" \
  || bad "4: 取件失败没停 rc=$RCB: $(tail -1 <<<"$OUTB")"

echo; echo "══ 5. 原有参数与安装保护没被破坏 ══"
OUT="$(run_install --ref v9.9.8-bridge-TEST --some-future-flag)"
[[ "$(gv HEAD)" == "$C_BRIDGE" ]] && ok "5a: 其它参数原样透传, 不影响版本选择" || bad "5a: HEAD=$(gv HEAD)"
_body="$(sed -n '/^PDG_TARGET_REF=""/,/^fi$/p' "$INSTALL")"
grep -qiE 'FORCE|SKIP|BYPASS|--no-verify|verify=0' <<<"$_body" \
  && bad "5b: 入口里夹带了 FORCE/SKIP/BYPASS 之类的绕过开关" || ok "5b: 入口里没有任何绕过开关"
grep -q 'PDG_TAG_BOOTSTRAPPED' <<<"$(sed -n '/显式目标必须\*\*贯穿到实际安装\*\*/,/^fi$/p' "$INSTALL")" \
  && bad "5c: 身份门竟然拿自举标记当依据" || ok "5c: 身份门读的是仓库真实 HEAD, 不是自举标记"
grep -c 'pdg_verify_sha256' "$INSTALL" | grep -qE '^[1-9]' \
  && ok "5d: 二进制供应链校验(pdg_verify_sha256)仍在, 本轮没碰它" || bad "5d: 校验不见了"

echo; echo "══ N. 撤销对照 ══"
# N1 在第二段把显式目标丢掉(模拟"中途重新选最新")⇒ 身份门必须判红
python3 - "$INSTALL" "$WORK/inst-drop.sh" <<'PYN'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = '  TAG=$(pdg_checkout_release_tag "$REPO_DIR" "$PDG_TARGET_REF") \\'
new = '  TAG=$(pdg_checkout_release_tag "$REPO_DIR" "") \\'   # 撤销对照: 第二段丢掉显式目标
assert s.count(old) == 1
open(dst, "w", encoding="utf-8").write(s.replace(old, new))
PYN
D2="$WORK/wc-drop"; git clone -q "$BARE" "$D2" >/dev/null 2>&1; g "$D2" checkout -q "$C_OLD"
cp "$WORK/inst-drop.sh" "$D2/install.sh"
OUT2="$(unshare --map-root-user --mount env -u PDG_TAG_BOOTSTRAPPED PDG_NONINTERACTIVE=1 \
        bash "$D2/install.sh" --ref v9.9.8-bridge-TEST 2>&1)"; RC2=$?
{ [[ "$RC2" != 0 ]] && [[ "$RC2" != 77 ]] && grep -q '指定版本没有贯穿到实际安装' <<<"$OUT2"; } \
  && ok "N1: 第二段丢掉显式目标 ⇒ 身份门当场判红(rc=$RC2), 错误的版本选择被直接暴露" \
  || bad "N1: 没暴露出来 rc=$RC2: $(tail -2 <<<"$OUT2" | tr '\n' ' ')"
# N2 无关注释对照
sed '0,/^PDG_TARGET_REF=""/s//# 本行仅为无关注释对照\nPDG_TARGET_REF=""/' "$INSTALL" > "$WORK/inst-cmt.sh"
D3="$WORK/wc-cmt"; git clone -q "$BARE" "$D3" >/dev/null 2>&1; g "$D3" checkout -q "$C_OLD"
cp "$WORK/inst-cmt.sh" "$D3/install.sh"
OUT3="$(unshare --map-root-user --mount env -u PDG_TAG_BOOTSTRAPPED PDG_NONINTERACTIVE=1 \
        bash "$D3/install.sh" --ref v9.9.8-bridge-TEST 2>&1)"; RC3=$?
{ [[ "$RC3" == 77 ]] && [[ "$(g "$D3" rev-parse HEAD)" == "$C_BRIDGE" ]] \
  && grep -q 'SENTINEL-VERSION=bridge' <<<"$OUT3"; } \
  && ok "N2: 无关注释对照 —— 结论相同(rc=77, HEAD=桥接, 哨兵也一样), 零新增失败" \
  || bad "N2: rc=$RC3 HEAD=$(g "$D3" rev-parse HEAD)"

note "本支用的 v9.9.x-*-TEST 只存在于这个一次性裸库: 没推官方、没伪造 Release;"
note "  它证明的是「指定版本确实指到并装上了」, **不**等于正式发布来源已验证。"
A_ALL="$(awk 'END{print NR}' "$ALOG" 2>/dev/null)"; A_ALL="${A_ALL:-0}"
if [[ "$((P+F))" == "$A_ALL" ]]; then ok "计数对账: 打印 $A_ALL 条断言, 全部进了总数"
else bad "计数对账: 打印 $A_ALL 条, 只有 $((P+F)) 条进了总数"; fi
echo "──────────────────────────────────────────────"
echo "通过 $P, 失败 $F"
[[ "$F" == 0 ]]

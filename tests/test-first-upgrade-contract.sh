#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 格里赋值的变量由 source 进来的被测原文按名字读取(静态看不到)
# ──────────────────────────────────────────────────────────────────
# S-1 验收器(tests/e2e-real-first-upgrade.sh)的接线契约与本地模型格(不碰真实服务; 不需要 root / systemd; 本机与 CI 都能跑)。
#   一、workflow 接线: real_scope 多了 first-upgrade 这一个选项(整块原文登记); 文件末尾追加的 real-first-upgrade 是最后一个 job;
#       它的准备步骤与 ③ job 逐字相同、② 步只换名称行、S-1 步与留证步按登记生成; 相对 2982aa54 只有这两处改动。
#   二、静态: 只有六个路径相对 2982aa54 有变化; 共享输入逐字节不变; 验收器按它自己的抽法从"现在"与 2982aa54 各抽一次逐名逐字相同且非空;
#       不得调用 r3_gated_invoke / r3_quiesce / r3_q_*; 没有 _dw_settle、没有对 dotwitness 的 systemctl 动作、没有 systemctl 包装;
#       唯一调用入口 r3_invoke 恰一处; ③ 的环境常量与内联判据逐字照抄(后者只换判词前缀)。
#   三、模型格(登记见 382 证据 reg/REGISTRY.txt): 被测函数一律按唯一成对标记从验收器抽原文执行; 只替换外部命令(systemctl / ss / journalctl /
#       升级 CLI 替身)与本格登记的叶子函数; 每格一个子壳, 带随机串结束标记; 没有结束标记、子壳非零退出或结果读不了 ⇒ 本格执行无效, 不算通过。
#   383 增补(登记见 383 证据 reg/REGISTRY-383.txt): 读取链注入格(L7–L10、R13–R16)、M2 / M3、结算语义格(S21–S24)、同一游标(J12)、
#       调用返回后主流程的组合格(K1–K5), 以及契约自身的有效性元格(V4–V15); 判定分执行无效 / 结果无效 / 业务不成立三类。
#   这些都是模型验证, 不冒充真实 systemd、journal、DNS 或 root 环境的验收。
# 用法: bash tests/test-first-upgrade-contract.sh
#       PDG_S1C_ONLY="wiring static R1 J6 …" 只跑点名的节(wiring / static)与模型格, 供撤销对照用; 不点名时全跑。
# ──────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDG_S1C_BASE:-2982aa54dc4600af097a0764c04afeacd45a0131}"   # 验收冻结基线(S-1 之前的验收 HEAD)
S1="$ROOT/tests/e2e-real-first-upgrade.sh"; R3="$ROOT/tests/e2e-real-retire-hop.sh"; HOP2="$ROOT/tests/e2e-real-bridge-hop.sh"
PLAT="$ROOT/tests/e2e-real-platform-fail.sh"; WF="$ROOT/.github/workflows/ci.yml"; ME="$ROOT/tests/test-first-upgrade-contract.sh"
ONLY="${PDG_S1C_ONLY:-}"
pass=0; nfail=0; nexec=0; nres=0; nbiz=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
fin(){ echo "────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"
  echo "失败分类(383): 模型格执行无效 $nexec / 结果无效 $nres / 业务不成立 $nbiz / 其它(接线、静态、元格、生产者没走完等) $((nfail - nexec - nres - nbiz))"
  (( nfail == 0 && pass > 0 )) || exit 1; exit 0; }
rdf(){   # $1=文件 → 0 整份读出(放在 RDV) / 1 不存在、读不了或读到一半失败(已输出的部分不采信)
  local v
  RDV=""
  [[ -f "$1" ]] || return 1
  v="$(cat -- "$1" 2>/dev/null)" || return 1
  RDV="$v"
}
want(){ [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
blk(){   # $1=名字 $2=来源 → 打印唯一成对标记之间的原文; 标记不唯一成对或之间为空 ⇒ 非 0
  local n="$1" src="$2" b e
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] || return 1
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || return 1
  sed -n "$((b+1)),$((e-1))p" "$src"
}
pres(){   # 383: $1=生产者退出码 $2=生产者输出 $3=生产者 stderr $4=节名 $5..=项 → 生产者走完(退出 0、输出读得出、END 恰一行且在末行)
          # 才逐项采信 OK / BAD(每项恰一行); 否则每项都记"未取得", 不为依赖它的保护项背书
  local prc="$1" f="$2" ef="$3" sec="$4" why="" id l n line ends=0
  shift 4
  if ! rdf "$f"; then why="生产者输出读不了"
  elif [[ "$prc" != 0 ]]; then why="生产者退出 $prc"
  else
    while IFS= read -r l; do [[ "$l" == END ]] && ends=$((ends+1)); done <<< "$RDV"
    if (( ends != 1 )) || [[ "${RDV##*$'\n'}" != END ]]; then why="生产者没有以唯一的 END 收尾"; fi
  fi
  [[ -z "$why" ]] || why="$why($(head -c 160 "$ef" 2>/dev/null | tr '\n' ' '))"
  for id in "$@"; do
    if [[ -n "$why" ]]; then bad "$id 未取得($sec 的生产者没走完: $why) —— 不为依赖它的保护项背书"; continue; fi
    n=0; line=""
    while IFS= read -r l; do
      case "$l" in "OK"$'\t'"$id"$'\t'*|"BAD"$'\t'"$id"$'\t'*) n=$((n+1)); line="$l";; esac
    done <<< "$RDV"
    if (( n != 1 )); then bad "$id 未取得($sec 的结果行 $n 条, 应恰 1 条)"; continue; fi
    case "${line%%$'\t'*}" in OK) ok "$id ${line#*$'\t'*$'\t'}";; *) bad "$id ${line#*$'\t'*$'\t'}";; esac
  done
}
T="$(mktemp -d "${TMPDIR:-/tmp}/s1c.XXXXXX")" || { echo "[未执行] 建不出临时目录"; echo "通过 0, 失败 1"; exit 1; }
trap 'chmod -R u+rwx -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
for f in "$S1" "$R3" "$HOP2" "$PLAT" "$WF" "$ME"; do [[ -f "$f" ]] || { bad "找不到 $f"; fin; }; done
[[ -n "$ONLY" ]] && echo "[NOTE] 只跑点名部分(PDG_S1C_ONLY=$ONLY) —— 这不是整支运行"
git -C "$ROOT" cat-file -e "$BASE^{commit}" 2>/dev/null || { bad "取不到验收基线对象 $BASE —— 接线与共享输入核对无从谈起"; fin; }

# ══ 一. workflow 接线 ══
if want wiring; then
echo "══ 一. workflow 接线 ══"
if git -C "$ROOT" show "$BASE:.github/workflows/ci.yml" > "$T/base-ci.yml" 2>/dev/null && [[ -s "$T/base-ci.yml" ]]; then
python3 - "$WF" "$T/base-ci.yml" > "$T/wiring.txt" 2> "$T/wiring.err" <<'PY'
import re, sys
wf, basewf = sys.argv[1], sys.argv[2]
ctext = open(wf, encoding="utf-8").read(); btext = open(basewf, encoding="utf-8").read()
c = ctext.split("\n"); b = btext.split("\n")
def R(i, good, mok, mbad):
    print(("OK" if good else "BAD") + "\t" + i + "\t" + (mok if good else mbad))
OPT = '        options: ["all", "platform", "retire", "bridge", "retire-hop", "late-failure", "retire-hop-bc", "first-upgrade"]'
NOW = [
    '      real_scope:',
    '        # 只在 real_acceptance=true 时有意义。默认 all = 与以前逐字节相同的三 job 语义;',
    '        # 选 platform 就只跑⑤a/⑤b 两个平台方向, 选 retire 就只跑①旧 CLI 直跳被拒。',
    '        # 选 retire-hop 就只跑③(已安装桥接 → 退役候选; 同一 job 里先原样跑 ② 取得真实桥接前像)。',
    '        # 选 late-failure 就只跑④(退役成功后的晚期失败 → 产品自己回滚到本次快照; 同一 job 里先原样跑 ②)。',
    '        # 选 retire-hop-bc 就只跑 B / C2 两跳(前像在本 job 里构造, 再经桥接入口与已装桥接 CLI 两跳到退役候选; b / c2 各一格)。',
    '        # 选 first-upgrade 就只跑 S-1(已安装桥接 → 新候选的首次升级, 不施加准备阶段静置; 同一 job 里先原样跑 ②; 观测 pdg-dotwitness 触限、恢复与父进程收尾)。',
    '        # 是**显式范围选择**, 不是用 continue-on-error 把失败绕过去 —— 被选中的 job',
    '        # 该红照样红, 没被选中的 job 直接不启动(不产生结果, 也不冒充通过)。',
    '        description: "真实验收的范围(默认 all; platform = 只跑⑤a/⑤b; retire = 只跑①旧 CLI 直跳被拒; bridge = 只跑② v1.11.15→桥接; retire-hop = ②+③ 同一 job; late-failure = ②+④ 同一 job; retire-hop-bc = B/C2 两跳; first-upgrade = ②+S-1 同一 job)"',
    '        type: choice',
    '        options: ["all", "platform", "retire", "bridge", "retire-hop", "late-failure", "retire-hop-bc", "first-upgrade"]',
    '        default: "all"'
]
def region(lines):
    if lines.count("      real_scope:") != 1:
        return None
    i = lines.index("      real_scope:"); j = i
    while j < len(lines) and lines[j] != '        default: "all"':
        j += 1
    return (i, j + 1) if j < len(lines) else None
R("W1", c.count(OPT) == 1, "real_scope 选项整行逐字相符(原有七项顺序不变, 末尾是 first-upgrade)", "real_scope 选项整行不对")
rc, rb = region(c), region(b)
R("W2", rc is not None and c[rc[0]:rc[1]] == NOW, "real_scope 整块与登记原文逐字相符(%d 行)" % len(NOW), "real_scope 整块与登记原文不符或定位不到")
S1H = "\n  real-first-upgrade:\n"
s1 = ctext[ctext.index(S1H) + 1:] if ctext.count(S1H) == 1 else ""
heads_s1 = re.findall(r"^  ([a-z][a-z0-9-]*):$", s1, re.M)
good3 = False
if rc and rb and s1 and heads_s1 == ["real-first-upgrade"]:
    bm = "\n".join(b[:rb[0]] + ["<<REAL_SCOPE>>"] + b[rb[1]:]); cm = "\n".join(c[:rc[0]] + ["<<REAL_SCOPE>>"] + c[rc[1]:])
    good3 = (cm == bm + "\n" + s1)
R("W3", good3, "相对 2982aa54: 只改了 real_scope 块, 其余改动只有文件末尾追加的 1 个空行 + real-first-upgrade(%d 行, 块内只有它一个 job 头)" % s1.count("\n"),
  "相对 2982aa54 有登记之外的改动, 或 real-first-upgrade 不是恰 1 处 / 后面还有别的 job")
heads = re.findall(r"^  ([a-z][a-z0-9-]*):$", ctext, re.M)
R("W4", heads[-2:] == ["real-retire-hop-bc", "real-first-upgrade"], "最后一个 job 是 real-first-upgrade, 紧挨在 real-retire-hop-bc 之后",
  "最后两个 job 是 %r" % (heads[-2:],))
def jb(name):
    h = "  %s:" % name
    if c.count(h) != 1:
        return None
    i = c.index(h); j = i + 1
    while j < len(c) and not re.match(r"^  [a-z][a-z0-9-]*:$", c[j]):
        j += 1
    out = c[i:j]
    while out and out[-1] == "":
        out.pop()
    return out
r3, sj = jb("real-retire-hop"), jb("real-first-upgrade")
HEAD = ["  real-first-upgrade:",
        "    needs: prepare-mosdns-fixture",
        "    if: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.real_acceptance == 'true'",
        "            && github.event.inputs.real_scope == 'first-upgrade' }}",
        "    runs-on: ubuntu-24.04",
        "    timeout-minutes: 50",
        '    name: "真实验收 S-1: 已安装桥接 → 新候选的首次升级(同一 runner 先原样跑 ②; 不静置; 观测 pdg-dotwitness 触限、恢复与父进程收尾)"']
CONTRACT = ['      - name: "前置: S-1 契约 (接线/共享输入与抽取/门与唯一调用/触限·恢复·报告·健康分层结算; 模型)"',
            "        run: bash tests/test-first-upgrade-contract.sh"]
R2NAME = '      - name: "② 原样: 按 docs/BRIDGE-ENTRY.md 的入口流程把 v1.11.15 升到桥接版(本次 S-1 的真实前像)"'
S1STEP = ['      - name: "真实验收 S-1: 现役桥接 CLI 执行 update --to 新候选(② 成功才启动; 不施加准备阶段静置)"',
          "        id: s1",
          "        if: ${{ success() && steps.real2.outcome == 'success' }}",
          "        env:",
          '          PDG_E2E_ISOLATED: "1"',
          '          PDG_REAL_MIGRATION_OK: "1"',
          '          PDG_S1_EVID: "/tmp/real-acceptance-evidence-s1"',
          '          PDG_REAL2_LOG: "/tmp/real2-stdout.log"',
          "          PDG_BRIDGE_SHA: ${{ github.event.inputs.bridge_candidate }}",
          "          PDG_RETIRE_SHA: ${{ github.event.inputs.product_candidate }}",
          "        run: sudo -E bash tests/e2e-real-first-upgrade.sh"]
EVMAP = [
 ('      - name: "留证: ② 与 ③ 的证据文件、③ 调用次数与 journal(成败都留)"',
  '      - name: "留证: ② 与 S-1 的证据文件、S-1 调用次数与 journal(成败都留)"'),
 ('          # 321: ③ 结束之后, 先对 pdg-dotwitness 取证:',
  '          # 382(同 321): S-1 结束之后, 先对 pdg-dotwitness 取证:'),
 ('也不改变本步骤与 ③ 的结论。',
  '也不改变本步骤与 S-1 的结论。'),
 ('echo "########## ③ 升级调用次数: $(sudo cat /tmp/real-acceptance-evidence-retire/00-retire-invoke-count.txt 2>/dev/null || echo \'<未取得: ③ 没启动或没写>\') ##########"',
  'echo "########## S-1 升级调用次数: $(sudo cat /tmp/real-acceptance-evidence-s1/00-s1-invoke-count.txt 2>/dev/null || echo \'<未取得: S-1 没启动或没写>\') ##########"'),
 ('for d in /tmp/real-acceptance-evidence /tmp/real-acceptance-evidence-retire; do',
  'for d in /tmp/real-acceptance-evidence /tmp/real-acceptance-evidence-s1; do')
]
def idx(lines, x):
    k = [i for i, l in enumerate(lines) if l == x]
    return k[0] if len(k) == 1 else None
if r3 is None or sj is None:
    for i in ("W5", "W6", "W7", "W8", "W9", "W10", "W11", "W12"):
        R(i, False, "", "③ job 或 S-1 job 取不到 —— 本格未取得")
else:
    stxt = "\n".join(sj)
    R("W5", sj[2:4] == HEAD[2:4] and stxt.count("real_scope ==") == 1 and "real_scope == 'first-upgrade'" in stxt,
      "real-first-upgrade 只在 workflow_dispatch + real_acceptance=true + real_scope=first-upgrade 时启动(不搭别的范围的车)", "real-first-upgrade 的启动条件不对")
    R("W6", "continue-on-error" not in stxt, "S-1 job 里没有 continue-on-error", "S-1 job 里有 continue-on-error")
    st3, st1 = idx(r3, "    steps:"), idx(sj, "    steps:")
    c3 = idx(r3, '      - name: "前置: ③ 契约 (接线/② 结果门/桥接身份门/目标到达与观测有效性/退役链服务对账)"')
    r2a = idx(r3, '      - name: "② 原样: 按 docs/BRIDGE-ENTRY.md 的入口流程把 v1.11.15 升到桥接版(本次 ③ 的真实前像)"')
    r3s = idx(r3, '      - name: "真实验收③: 现役桥接 CLI 执行 update --to 退役候选(② 成功才启动)"')
    ev3 = idx(r3, '      - name: "留证: ② 与 ③ 的证据文件、③ 调用次数与 journal(成败都留)"')
    c1, r2b, s1s = idx(sj, CONTRACT[0]), idx(sj, R2NAME), idx(sj, S1STEP[0])
    ev1 = idx(sj, '      - name: "留证: ② 与 S-1 的证据文件、S-1 调用次数与 journal(成败都留)"')
    allidx = None not in (st3, st1, c3, r2a, r3s, ev3, c1, r2b, s1s, ev1)
    prep3 = r3[st3:c3] if allidx else None; prep1 = sj[st1:c1] if allidx else None
    R("W7", allidx and prep3 == prep1, "S-1 job 的准备步骤与 ③ job 逐字相同(%d 行; 只把 ③ 契约步换成 S-1 契约步)" % (len(prep1) if prep1 else 0), "准备步骤与 ③ job 不同或定位不到")
    R("W8", allidx and sj[c1:c1 + 2] == CONTRACT and c1 + 2 == r2b, "S-1 契约步恰在准备步骤之后、② 步之前", "S-1 契约步不对")
    real2a = r3[r2a:r3s] if allidx else None; real2b = sj[r2b:s1s] if allidx else None
    R("W9", allidx and real2b[0] == R2NAME and real2a[1:] == real2b[1:], "② 步除名称行外与 ③ job 的 ② 步逐字相同(同一脚本、同一组 env、tee 留档)", "② 步与 ③ job 不同")
    R("W10", allidx and sj[s1s:ev1] == S1STEP, "S-1 步 id / if(② 成功才启动)/ env(恰 6 项, 不含静置 / 超时 / 能力句柄覆盖)/ run 恰为登记", "S-1 步与登记不符")
    evt = "\n".join(r3[ev3:]) if allidx else ""
    good11 = allidx and all(evt.count(x) == 1 for x, _ in EVMAP)
    if good11:
        for x, y in EVMAP:
            evt = evt.replace(x, y)
        good11 = evt.split("\n") == sj[ev1:] and "        if: ${{ always() }}" in sj[ev1:]
    R("W11", good11, "留证步 = ③ 的留证步按登记 %d 处替换(证据目录 / 计数文件 / 名称); if: always()" % len(EVMAP), "留证步与登记不符")
    R("W12", allidx and sj == HEAD + prep1 + CONTRACT + real2b + S1STEP + sj[ev1:], "S-1 job 整块 = 登记的头 + 准备 + 契约 + ② + S-1 + 留证(顺序与内容), 之后没有别的步骤",
      "S-1 job 整块不是登记的拼接")
print("END")
PY
wrc=$?
pres "$wrc" "$T/wiring.txt" "$T/wiring.err" "一 接线核对" W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12
else bad "一 基线 ci.yml 取不到 —— 接线核对无从谈起"; fi
fi

# ══ 二. 静态 ══
if want static; then
echo "══ 二. 静态: 六路径、共享输入、抽取块、禁用调用、照抄原文 ══"
SIX="$(printf '%s\n' .github/workflows/ci.yml tests/e2e-real-first-upgrade.sh tests/test-first-upgrade-contract.sh tests/test-late-failure-contract.sh \
  tests/test-retire-hop-bc-contract.sh tests/test-retire-hop-contract.sh | LC_ALL=C sort)"
if d1="$(git -C "$ROOT" diff --name-only "$BASE" -- 2>/dev/null)" && d2="$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)"; then
  chg="$(printf '%s\n%s\n' "$d1" "$d2" | grep -v '^$' | LC_ALL=C sort -u)"
  [[ "$chg" == "$SIX" ]] && ok "S1 相对 2982aa54 只有登记的六个路径有变化(已跟踪改动 + 未跟踪新文件)" || bad "S1 变化路径不是登记的六个: [$(tr '\n' ' ' <<< "$chg")]"
else bad "S1 未取得: 改动清单取不到(git diff / ls-files 失败) —— 不说成没有登记外改动"; fi
n2=0; why2=""
for rel in tests/e2e-real-bridge-hop.sh tests/e2e-real-retire-hop.sh tests/e2e-real-late-failure.sh tests/e2e-real-platform-fail.sh tests/e2e-real-retire-hop-bc.sh \
           tests/e2e-real-retire-refusal.sh tests/e2e-lib.sh tests/helpers/dns-stub.py tests/repoguard.sh tests/test-bridge-observation-contract.sh \
           tests/test-bridge-extract-contract.sh tests/test-dns-instrument-real.sh tests/test-ci-coverage.py tests/test-platform-startlimit-quiesce.sh; do
  if ! git -C "$ROOT" show "$BASE:$rel" > "$T/base-one" 2>/dev/null; then why2="$why2 $rel(基线取不到)"; continue; fi
  cmp -s -- "$T/base-one" "$ROOT/$rel"; r=$?
  case "$r" in 0) n2=$((n2+1));; 1) why2="$why2 $rel(变了)";; *) why2="$why2 $rel(比较失败 rc=$r)";; esac
done
[[ -z "$why2" && "$n2" == 14 ]] && ok "S2 ①②③④⑤、B / C2 验收器、共享夹具与相关契约 / 守卫相对 2982aa54 逐字节不变($n2 个)" || bad "S2 共享输入不成立:$why2"
# S3: 按验收器自己的抽法(s1_seed → ③ r3_bootstrap → ② extract_marked_fns / decls)从"现在"与 2982aa54 两侧各抽一次, 逐名逐字比, 两侧各自非空
mkdir -p "$T/s3/now" "$T/s3/base"
s3ok=1
if blk s1_seed "$S1" > "$T/s3/seed.sh" && blk s1_lists "$S1" > "$T/s3/lists.sh" && bash -n "$T/s3/seed.sh" && bash -n "$T/s3/lists.sh"; then
  cp "$R3" "$T/s3/now/r3.sh"; cp "$HOP2" "$T/s3/now/hop2.sh"; cp "$PLAT" "$T/s3/now/plat.sh"
  git -C "$ROOT" show "$BASE:tests/e2e-real-retire-hop.sh" > "$T/s3/base/r3.sh" 2>/dev/null || s3ok=0
  git -C "$ROOT" show "$BASE:tests/e2e-real-bridge-hop.sh" > "$T/s3/base/hop2.sh" 2>/dev/null || s3ok=0
  git -C "$ROOT" show "$BASE:tests/e2e-real-platform-fail.sh" > "$T/s3/base/plat.sh" 2>/dev/null || s3ok=0
  for side in now base; do
    ( set +u
      # shellcheck source=/dev/null
      source "$T/s3/seed.sh"; source "$T/s3/lists.sh"
      D="$T/s3/$side"; E2E_TMP="$D"; export E2E_TMP
      s1_seed r3_bootstrap "$D/r3.sh" > "$D/boot.sh" && bash -n "$D/boot.sh" || exit 2
      # shellcheck source=/dev/null
      source "$D/boot.sh"
      r3_bootstrap "$D/hop2.sh" "$D/extractor.sh" extract_marked_fns extract_marked_decls || exit 2
      # shellcheck source=/dev/null
      source "$D/extractor.sh"
      for n in "${S1_PLAT_FNS[@]}"; do extract_marked_fns "$D/plat.sh" "$D/x-p-$n" "$n" || exit 3; done
      for n in "${S1_PLAT_DECLS[@]}"; do extract_marked_decls "$D/plat.sh" "$D/x-d-$n" "$n" || exit 3; done
      for n in "${S1_HOP2_FNS[@]}"; do extract_marked_fns "$D/hop2.sh" "$D/x-h-$n" "$n" || exit 3; done
      for n in "${S1_R3_BLOCKS[@]}"; do r3_bootstrap "$D/r3.sh" "$D/x-r-$n" "$n" || exit 3; done
      printf '%s\n' "${S1_PLAT_FNS[@]/#/x-p-}" "${S1_PLAT_DECLS[@]/#/x-d-}" "${S1_HOP2_FNS[@]/#/x-h-}" "${S1_R3_BLOCKS[@]/#/x-r-}" > "$D/names"
      for f in "${S1_FORBID[@]}"; do [[ " ${S1_R3_BLOCKS[*]} " != *" $f "* ]] || exit 4; done
    ) > "$T/s3/$side.log" 2>&1 || s3ok=0
  done
  if (( s3ok )) && rdf "$T/s3/now/names" && [[ -n "$RDV" ]]; then
    nn=0; why3=""
    while IFS= read -r x; do
      [[ -s "$T/s3/now/$x" && -s "$T/s3/base/$x" ]] || { why3="$why3 $x(空或没抽到)"; continue; }
      cmp -s "$T/s3/now/$x" "$T/s3/base/$x" && nn=$((nn+1)) || why3="$why3 $x(两侧不同)"
    done <<< "$RDV"
    [[ -z "$why3" ]] && ok "S3 验收器按自己的抽法抽到的 $nn 个共享块 / 函数 / 依赖, 与 2982aa54 两侧逐名逐字相同且各自非空; 不得调用的函数不在抽取表里" || bad "S3 抽取比对不成立:$why3"
  else bad "S3 抽取没走完(现在一侧: $(tail -1 "$T/s3/now.log" 2>/dev/null); 基线一侧: $(tail -1 "$T/s3/base.log" 2>/dev/null)) —— 共享块比对没做"; fi
else bad "S3 验收器的 s1_seed / s1_lists 抽不到或语法不过"; fi
# S4: 禁用调用(去掉注释行; 抽取表 / 不得调用表那两行除外)
CODE_OK=0
if grep -vE '^[[:space:]]*#' "$S1" > "$T/s1code.txt" 2>/dev/null && [[ -s "$T/s1code.txt" ]]; then CODE_OK=1; fi
cq(){ (( CODE_OK == 1 )) || { echo 错; return; }; grep -vE '^(S1_FORBID|S1_R3_BLOCKS)=\(' "$T/s1code.txt" | grep -cE -- "$1"; }
s4(){   # $1=格 $2=说明 $3=ERE $4=应有条数
  local n; n="$(cq "$3")"
  [[ "$n" == "$4" ]] && ok "$1 $2" || bad "$1 $2 —— 实得 [$n] 处(应为 $4)"; }
s4 S4a "不调用 r3_gated_invoke / r3_quiesce(去注释代码里 0 处)" '\b(r3_gated_invoke|r3_quiesce)\b' 0
s4 S4b "不调用 r3_q_*(去注释代码里 0 处)" '\br3_q_[a-z_]+' 0
s4 S4c "不直接运行产品内部函数 _dw_settle(0 处)" '_dw_settle' 0
s4 S4d "验收器不对 pdg-dotwitness 做 systemctl 动作(reset-failed / start / restart / stop / enable … 0 处)" \
  'systemctl[^#]*\b(reset-failed|start|restart|stop|enable|disable|kill|mask|unmask|reload|try-restart)\b[^#]*pdg-dotwitness' 0
s4 S4e "不定义 systemctl / journalctl / ss / timeout 的包装函数、不改 PATH" '(^[[:space:]]*(systemctl|journalctl|ss|timeout)[[:space:]]*\(\))|(^|[^A-Za-z_])PATH=' 0
s4 S4f "不以命令形式直接调用升级 CLI(只经 r3_invoke)" '(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?(env[^"]*[[:space:]])?(timeout[^"]*[[:space:]])?bash[[:space:]]+"?(\$R3_CLI|/usr/local/bin/pdg)' 0
s4 S4g "唯一调用入口 r3_invoke 在去注释代码里恰 1 处" '\br3_invoke\b' 1
s4 S4h "不覆盖静置参数与超时(R3_Q_* / PDG_RETIRE_HOP_TIMEOUT 0 处赋值)" '(\bR3_Q_[A-Z_]*=|\bPDG_RETIRE_HOP_TIMEOUT=)' 0
if (( CODE_OK == 1 )); then
  inv_in="$(awk '/^s1_gated_invoke\(\)\{/{f=1} f && /\<r3_invoke\>/ && !/^[[:space:]]*#/ {print "IN"; exit} f && /^}$/{exit}' "$S1")"
  [[ "$inv_in" == IN ]] && ok "S4i 那一处 r3_invoke 在 s1_gated_invoke 里(门全过之后)" || bad "S4i r3_invoke 不在 s1_gated_invoke 里"
else bad "S4i 去注释代码没取得 —— 不判"; fi
# S5 / S6: ③ 原文照抄
python3 - "$R3" "$S1" > "$T/s56.txt" 2> "$T/s56.err" <<'PY'
import sys
r3 = open(sys.argv[1], encoding="utf-8").read().split("\n"); s1 = open(sys.argv[2], encoding="utf-8").read().split("\n")
def seg(lines, a, b):
    ia = [i for i, l in enumerate(lines) if l.startswith(a)]; ib = [i for i, l in enumerate(lines) if l.startswith(b)]
    if len(ia) != 1 or len(ib) != 1 or ib[0] < ia[0]:
        return None
    return lines[ia[0]:ib[0] + 1]
def mark(lines, n):
    a = [i for i, l in enumerate(lines) if l == "# >>> PDG-EXTRACT-BEGIN " + n]; b = [i for i, l in enumerate(lines) if l == "# <<< PDG-EXTRACT-END " + n]
    return lines[a[0] + 1:b[0]] if len(a) == 1 and len(b) == 1 and b[0] > a[0] + 1 else None
cr = seg(r3, 'BRIDGE_SHA="${PDG_BRIDGE_SHA:-}"; RETIRE_SHA="${PDG_RETIRE_SHA:-}"', "R3_DNS_PPRE=")
cs = mark(s1, "s1_r3_const")
ok5 = cr is not None and cs is not None and len(cs) >= 2 and cs[0].startswith("#") and cs[1:] == cr
print(("OK" if ok5 else "BAD") + "\tS5\t" + ("③ 的环境常量 %d 行逐行照抄(本支的 R3_TMP 已指向自己的临时目录)" % len(cr) if ok5 else "③ 环境常量的照抄与原文不符或定位不到"))
ir = seg(r3, 'if r3_modules "$R3_RTSRC" "$R3_MODDIR"; then', 'else bad "③-3 K2 观测无效: 平台标记读不了"; fi')
im = mark(s1, "s1_r3_inline")
body = None
if im is not None:
    k = [i for i, l in enumerate(im) if l == "s1_inline_post(){"]
    if len(k) == 1 and im[-1] == "}":
        body = im[k[0] + 1:-1]
ok6 = ir is not None and body is not None and body == [l.replace("③-", "S1-") for l in ir]
print(("OK" if ok6 else "BAD") + "\tS6\t" + ("③ 的内联判据 %d 行逐字照抄(只把判词前缀 ③- 换成 S1-)" % len(ir) if ok6 else "③ 内联判据的照抄与原文不符或定位不到"))
print("END")
PY
s56rc=$?
pres "$s56rc" "$T/s56.txt" "$T/s56.err" "S5 / S6 照抄核对" S5 S6
s7=1
for x in 'EVID="${PDG_S1_EVID:-}"' '[[ "$EVID" == /* ]] || _hard' 'R3_COUNT="$EVID/00-s1-invoke-count.txt"' 'JBOUND_TAG="pdg-e2e-jbound-s1"' \
         'for _f in "${S1_FORBID[@]}"; do declare -F "$_f" >/dev/null && _hard'; do grep -qF -- "$x" "$S1" || { s7=0; bad "S7 验收器里没有「$x」"; }; done
(( s7 )) && ok "S7 证据目录必须显式绝对路径、计数文件与界桩名是本支自己的、运行时核实不得调用的函数没被抽进来"
[[ -x "$S1" && -x "$ME" ]] && ok "S8 验收器与本契约可执行" || bad "S8 验收器或本契约不可执行"
fi

# ══ 三. 模型格 ══
echo "══ 三. 模型格(被测原文按标记抽取; 每格一个子壳) ══"
M_OK=1
( for n in s1_dw s1_journal s1_report s1_precall s1_gated s1_post s1_settle; do blk "$n" "$S1" || exit 1; done ) > "$T/s1fns.sh" 2>/dev/null || M_OK=0
{ blk r3_count "$R3" && blk r3_invoke "$R3"; } > "$T/r3m.sh" 2>/dev/null || M_OK=0
( for n in _j_why_file _j_err_file _j_fail _j_why _j_err _j_sync _j_tag_after; do blk "$n" "$PLAT" || exit 1; done ) > "$T/jm.sh" 2>/dev/null || M_OK=0
for f in s1fns r3m jm; do bash -n "$T/$f.sh" 2>/dev/null && [[ -s "$T/$f.sh" ]] || M_OK=0; done
(( M_OK )) && ok "M0 被测原文抽取成功且非空(验收器 7 段、③ r3_count / r3_invoke、⑤ journal 界桩函数), 语法通过" || { bad "M0 被测原文抽取失败 —— 模型格无从谈起"; fin; }
K_OK=1
blk s1_main "$S1" > "$T/kmain.sh" 2>/dev/null || K_OK=0
{ blk r3_read "$R3" && blk r3_post "$R3" && blk r3_svc_class "$R3" && blk r3_svc_verdict "$R3" && blk bridge_row_valid "$HOP2" && blk SVC_WATCH "$PLAT"; } > "$T/kdeps.sh" 2>/dev/null || K_OK=0
for f in kmain kdeps; do bash -n "$T/$f.sh" 2>/dev/null && [[ -s "$T/$f.sh" ]] || K_OK=0; done
grep -q '^s1_after_call(){$' "$T/kmain.sh" 2>/dev/null || K_OK=0
(( K_OK )) && ok "M3 组合格的被测原文抽取成功且非空(验收器 s1_main 段即调用返回后的主流程、③ r3_read / r3_post / r3_svc_class / r3_svc_verdict、② bridge_row_valid、⑤ SVC_WATCH), 语法通过" \
  || bad "M3 组合格的被测原文抽取失败 —— K 格将判执行无效"
mkdir -p "$T/bin"; : > "$T/trip.log"
cat > "$T/bin/systemctl" <<'EOS'
#!/usr/bin/env bash
d="${S1M_DIR:?}"; printf '%s\n' "$*" >> "$d/systemctl.calls"
case "$1" in
  show) [[ -f "$d/show.out" ]] && cat "$d/show.out"; exit "$(cat "$d/show.rc" 2>/dev/null || echo 0)";;
  cat)  [[ -f "$d/cat.out" ]] && cat "$d/cat.out"; exit "$(cat "$d/cat.rc" 2>/dev/null || echo 0)";;
  *)    exit 0;;
esac
EOS
cat > "$T/bin/ss" <<'EOS'
#!/usr/bin/env bash
d="${S1M_DIR:?}"; printf '%s\n' "$*" >> "$d/ss.calls"; [[ -f "$d/ss.out" ]] && cat "$d/ss.out"; exit "$(cat "$d/ss.rc" 2>/dev/null || echo 0)"
EOS
cat > "$T/bin/journalctl" <<'EOS'
#!/usr/bin/env python3
import json, os, sys
d = os.environ["S1M_DIR"]; a = sys.argv[1:]
with open(os.path.join(d, "journalctl.calls"), "a") as fh:
    fh.write(" ".join(a) + "\n")
if a == ["--sync"]:
    sys.exit(0)
unit = tag = cur = None; out = "short"; boot = False; i = 0
while i < len(a):
    x = a[i]
    if x == "-u": unit = a[i + 1]; i += 2
    elif x == "-t": tag = a[i + 1]; i += 2
    elif x == "--after-cursor": cur = a[i + 1]; i += 2
    elif x == "-o": out = a[i + 1]; i += 2
    elif x == "-b": boot = True; i += 2
    elif x == "--no-pager": i += 1
    elif x.startswith("--output-fields="): i += 1
    else:
        sys.stderr.write("替身 journalctl: 不认识的参数 %s\n" % x); sys.exit(2)
p = os.path.join(d, "journal.jsonl")
lines = open(p, encoding="utf-8").read().splitlines() if os.path.exists(p) else []
ents = []
for l in lines:
    if l.startswith("RAW "):
        ents.append((l[4:], None))
    elif l.strip():
        ents.append((l, json.loads(l)))
if cur is not None:
    k = [j for j, (r, e) in enumerate(ents) if e is not None and e.get("__CURSOR") == cur]
    if not k:
        sys.stderr.write("替身 journalctl: 游标不存在\n"); sys.exit(1)
    ents = ents[k[0] + 1:]
def match(e):
    if e is None:
        return unit is not None
    if unit:
        return unit in (e.get("UNIT"), e.get("_SYSTEMD_UNIT"), e.get("OBJECT_SYSTEMD_UNIT"))
    if tag:
        return e.get("SYSLOG_IDENTIFIER") == tag
    return True
for r, e in ents:
    if match(e):
        print(r if out == "json" else (e.get("MESSAGE", "") if e is not None else r))
fail = (unit and os.path.exists(os.path.join(d, "jfail.u"))) or (boot and os.path.exists(os.path.join(d, "jfail.b")))
sys.exit(1 if fail else 0)
EOS
cat > "$T/bin/fakecli" <<'EOS'
#!/usr/bin/env bash
{ printf '%s\n' "$*" >> "${S1M_DIR:?}/calls.log"; } 2>/dev/null || { echo "替身 CLI: 调用记录写不进 ${S1M_DIR:-?}/calls.log" >&2; exit 97; }
echo "替身 CLI: $*"; exit 0
EOS
chmod +x "$T/bin/systemctl" "$T/bin/ss" "$T/bin/journalctl" "$T/bin/fakecli"

cell(){ local id="$1" code="$2" C="$T/cell-$1" nonce="$RANDOM$RANDOM$RANDOM"
  mkdir -p "$C/evid" "$C/wk" "$C/k"; printf '%s\n' "$nonce" > "$C/nonce"; : > "$C/calls.log"; : > "$C/inj.log"
  ( set +u
    # shellcheck source=/dev/null
    source "$T/r3m.sh"; source "$T/jm.sh"; source "$T/s1fns.sh"
    ok(){ echo "VOK $1"; }; bad(){ echo "VBAD $1"; }; note(){ echo "VNOTE $1"; }
    for f in r3_quiesce r3_gated_invoke r3_q_rec _dw_settle; do eval "$f(){ echo \"$id $f\" >> \"$T/trip.log\"; return 1; }"; done
    EVID="$C/evid"; S1_TMP="$C/wk"; R3_TMP="$C/wk"; E2E_TMP="$C/wk"; export E2E_TMP
    JBOUND_TAG=pdg-e2e-jbound-s1; J_ERR=""; S1_RECBAD=0; S1_BOOT="$BOOT"
    export PATH="$T/bin:$PATH" S1M_DIR="$C"
    eval "$code"
    echo "CELL-END $nonce"
  ) > "$C/out" 2>&1
  echo "$?" > "$C/rc"
}
cvalid(){   # 383: 执行有效 = 子壳退出 0, 且"CELL-END <本格随机串>"恰在末行、全文只出现一次(不认子串、不认前缀相同的别的串)
  local C="$T/cell-$1" n r l cnt=0
  rdf "$C/nonce" || return 1; n="$RDV"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  rdf "$C/rc" || return 1; r="$RDV"
  [[ "$r" == 0 ]] || return 1
  rdf "$C/out" || return 1
  [[ "${RDV##*$'\n'}" == "CELL-END $n" ]] || return 1
  while IFS= read -r l; do [[ "$l" == "CELL-END $n" ]] && cnt=$((cnt+1)); done <<< "$RDV"
  (( cnt == 1 ))
}
# 383: 结果读法 —— jcls 先把本格输出整份读进 JOUT, RES 恰 1 行、记号都是 k=v 且键不重复才解析进 JRES; 条件里的读取只读这两份,
#   不再经外部管道。帮助函数三态: 0 成立 / 1 不成立 / 2 结果无效(同时记进 JC_INV, 取反或子壳都抹不掉)。
declare -A JRES=(); JOUT=""; JID=""; JC_INV=""; JC_WHY=""; JL_WHY=""; JW=""; TRIPLOG="$T/trip.log"
jload(){   # $1=格 → 0 读好 / 1 读不了或结构不对(JL_WHY)
  local l n=0 rline="" t k
  local -a toks=()
  JOUT=""; JRES=(); JID="$1"; JL_WHY=""
  rdf "$T/cell-$1/out" || { JL_WHY="输出读不了"; return 1; }
  JOUT="$RDV"
  while IFS= read -r l; do [[ "$l" == "RES "* ]] && { n=$((n+1)); rline="$l"; }; done <<< "$JOUT"
  (( n == 1 )) || { JL_WHY="RES 行 $n 条(应恰 1 条)"; return 1; }
  read -r -a toks <<< "${rline#RES }"
  for t in "${toks[@]}"; do
    [[ "$t" == *=* ]] || { JL_WHY="RES 记号 [$t] 不是 键=值"; return 1; }
    k="${t%%=*}"
    [[ -z "${JRES[$k]+x}" ]] || { JL_WHY="RES 键 $k 重复"; return 1; }
    JRES[$k]="${t#*=}"
  done
}
jmine(){ [[ "$1" == "$JID" ]] || { JC_INV="$JC_INV [只能引用本格($JID)的结果, 实引 $1]"; return 2; }; }
rq(){ jmine "$1" || return 2; [[ -n "${JRES[$2]+x}" ]] || { JC_INV="$JC_INV [RES 里没有键 $2]"; return 2; }; [[ "${JRES[$2]}" == "$3" ]]; }
has(){ jmine "$1" || return 2; [[ "$JOUT" == *"$2"* ]]; }
whyhas(){   # 最后一行 WHY: 里含 $2; 没有 WHY 行 ⇒ 结果无效
  local l n=0
  jmine "$1" || return 2
  JW=""; while IFS= read -r l; do [[ "$l" == "WHY: "* ]] && { n=$((n+1)); JW="${l#WHY: }"; }; done <<< "$JOUT"
  (( n >= 1 )) || { JC_INV="$JC_INV [没有 WHY 行]"; return 2; }
  [[ "$JW" == *"$2"* ]]
}
fhas(){   # $1=文件 $2=文本 [$3=x 整行] → 0 有 / 1 没有 / 2 读不了(记 JC_INV)
  local r
  if [[ "${3:-}" == x ]]; then grep -qxF -- "$2" "$1" 2>/dev/null; else grep -qF -- "$2" "$1" 2>/dev/null; fi; r=$?
  case "$r" in 0|1) return "$r";; *) JC_INV="$JC_INV [$1 读不了(grep 退出 $r)]"; return 2;; esac
}
trip0(){   # $1=格 → 0 确认没有绊线记录 / 1 有 / 2 查询出错(记 JC_INV; 不当成"没有")
  local r
  grep -q "^$1 " "$TRIPLOG" 2>/dev/null; r=$?
  case "$r" in 0) return 1;; 1) return 0;; *) JC_INV="$JC_INV [绊线记录读不了(grep 退出 $r)]"; return 2;; esac
}
jcls(){   # $1=格 $2..=条件 → 0 成立 / 1 业务不成立 / 3 执行无效 / 4 结果无效; 说明在 JC_WHY
  local id="$1" c r f=""
  shift
  JC_INV=""; JC_WHY=""
  if ! cvalid "$id"; then JC_WHY="执行无效(子壳退出码 $(cat "$T/cell-$id/rc" 2>/dev/null || echo 未取得)、结束标记不是唯一的末行或输出读不了)"; return 3; fi
  if ! jload "$id"; then JC_WHY="结果无效($JL_WHY)"; return 4; fi
  for c in "$@"; do
    eval "$c"; r=$?
    if (( r == 1 )); then f="$f [$c]"; elif (( r != 0 )); then JC_INV="$JC_INV [$c 返回 $r]"; fi
  done
  if [[ -n "$JC_INV" ]]; then JC_WHY="结果无效:$JC_INV"; return 4; fi
  [[ -z "$f" ]] && return 0
  JC_WHY="不成立:$f"; return 1
}
jc(){   # $1=格 $2=说明 $3..=条件(在本壳里求值) → 执行有效、结果有效且条件全真才 OK; 三类失败分别计数
  local id="$1" desc="$2" r
  shift 2
  jcls "$id" "$@"; r=$?
  case "$r" in
    0) ok "$id $desc";;
    3) nexec=$((nexec+1)); bad "$id $desc —— $JC_WHY";;
    4) nres=$((nres+1)); bad "$id $desc —— $JC_WHY";;
    *) nbiz=$((nbiz+1)); bad "$id $desc —— $JC_WHY";;
  esac
}
mt(){ if eval "$2"; then ok "$1"; else bad "$1 —— 不成立"; fi; }

BOOT=0123456789abcdef0123456789abcdef
SHOW_OK='LoadState=loaded
UnitFileState=enabled
ActiveState=active
SubState=running
Result=success
MainPID=4915
InvocationID=cdaa252d54774cb6bff2ad5c0ff4e9ff
NRestarts=0
StartLimitIntervalUSec=5min
StartLimitBurst=5
FragmentPath=/etc/systemd/system/pdg-dotwitness.service
DropInPaths=
ControlGroup=/system.slice/pdg-dotwitness.service'
# 380 真实组件日志里 d1-recover-end/d1b-listen 的 ss 原文格式(表头 + 一行 5399 + 其它监听)
SS_HEAD='State  Recv-Q Send-Q  Local Address:Port Peer Address:PortProcess'
ss_line(){ printf 'UNCONN 0      0           %s      0.0.0.0:*    users:(("python3",pid=%s,fd=3))\n' "$1" "$2"; }
SS_OTHER='UNCONN 0      0          127.0.0.54:53        0.0.0.0:*    users:(("systemd-resolve",pid=420,fd=16))'
# journal 的消息原文(句式与 380 真实组件日志逐字同款; 描述换成生产 unit 的 Description)
DESC='PrivDNS Gateway DoT 证据端 (仅回环; 每会话探测证据)'
M_START="Started pdg-dotwitness.service - $DESC."; M_STOPPING="Stopping pdg-dotwitness.service - $DESC..."; M_STOPPED="Stopped pdg-dotwitness.service - $DESC."
M_REP="pdg-dotwitness.service: Start request repeated too quickly."; M_RES="pdg-dotwitness.service: Failed with result 'start-limit-hit'."
M_FST="Failed to start pdg-dotwitness.service - $DESC."
je(){   # $1=游标 $2=消息 [$3=UNIT(- 省略)] [$4=_PID] [$5=INVOCATION_ID(- 省略)] [$6=_BOOT_ID] [$7=OBJECT_SYSTEMD_UNIT(- 省略)]
  python3 -c 'import json, sys
c, m, u, p, inv, b, ob = sys.argv[1:8]
d = {"__CURSOR": c, "__MONOTONIC_TIMESTAMP": "100", "_BOOT_ID": b, "_PID": p, "MESSAGE": m}
if u != "-": d["UNIT"] = u
if inv != "-": d["INVOCATION_ID"] = inv
if ob != "-": d["OBJECT_SYSTEMD_UNIT"] = ob
print(json.dumps(d, ensure_ascii=False))' "$1" "$2" "${3:-pdg-dotwitness.service}" "${4:-1}" "${5:--}" "${6:-$BOOT}" "${7:--}"; }
jbnd(){ printf '{"__CURSOR": "%s", "SYSLOG_IDENTIFIER": "pdg-e2e-jbound-s1", "MESSAGE": "BOUNDARY %s", "_BOOT_ID": "%s", "_PID": "999"}\n' "$1" "$1" "$BOOT"; }
REAL380='\033[1;32m  DoT 证据端: 观察到启动限额命中(Result=start-limit-hit, NRestarts=0); 已做一次定向恢复(reset-failed 退出 0, start 退出 0), 恢复后运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有 —— 本次核验已恢复。\033[0m'
L_PASS='\033[1;32m  DoT 证据端: 核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有。\033[0m'
L_UNOBS='\033[1;33m  ⚠️  DoT 证据端: 状态未取得(systemctl show 退出 1, 已输出的内容不采信), 本步不做任何动作。\033[0m'
L_NOTREADY_POST='\033[1;33m  ⚠️  DoT 证据端: 观察到启动限额命中(Result=start-limit-hit, NRestarts=0); 已做一次定向恢复(reset-failed 退出 0, start 退出 0), 但恢复后确认未就绪(最后一次观察 ActiveState=failed, SubState=failed, Result=start-limit-hit, LoadState=loaded, UnitFileState=enabled); 不再重试。查看 journalctl -u pdg-dotwitness。\033[0m'
L_PASS_YELLOW='\033[1;33m  ⚠️  DoT 证据端: 核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有。\033[0m'
L_READY='\033[1;32m  ✅ DoT 证据端已就绪(模块 + unit + env + mosdns 受管路由)。\033[0m'
L_ROLLBACK='\033[1;33m迁移(__migrate)失败, 回滚到更新前快照…\033[0m'
# 383: 冻结候选 0fe5fb90 的 _dw_settle 在核验子壳退出 3 时的实际输出(383 证据 repro/cand-reports/INCOMPLETE.out 逐字节)
L_INCOMPLETE='\033[1;33m  ⚠️  DoT 证据端: 本次核验未完成(核验过程异常退出, 退出码 3); 不据此判断服务是否故障, 也不代表已恢复; 本步不再做任何动作。\033[0m'
SEDPAT='s/^0::\(\/.*\)$/\1/p'
real_sha="$(printf '%b' "$REAL380" | sha256sum | cut -c1-64)"
[[ "$real_sha" == fa56d4ef42570b0b551155e45a25ea5bc7130aa50ee134b3c2697334a3e7cc34 ]] \
  && ok "M1 R1 用的报告行与 380 真实组件日志里的原文逐字节相同(sha256 fa56d4ef…, 251 字节)" || bad "M1 R1 的报告行不是 380 原文(sha256 $real_sha)"
inc_sha="$(printf '%b' "$L_INCOMPLETE" | sha256sum | cut -c1-64)"
[[ "$inc_sha" == 3b809f72da0140424bc40e3a095ebc468f5a5c332e69a34fbc73d644082f3a4e ]] \
  && ok "M2 R16 用的 INCOMPLETE 报告行与冻结候选 _dw_settle 的实际输出(核验子壳退出 3)逐字节相同(sha256 3b809f72…)" || bad "M2 R16 的报告行不是冻结候选的实际输出(sha256 $inc_sha)"

# ── R 报告(s1_report) ──
RCODE='s1_report "$C/log.txt" "$C/rep.txt"; r=$?; echo "RES rc=$r cls=$S1_REP n=$S1_REP_N nr=$S1_REP_NR chain=$S1_CHAIN"'
rlog(){ local f="$T/rlog-$1"; shift; printf '%b\n' "$@" > "$f"; }
rlog R1 '  前面的产品输出…' "$REAL380" 'SETTLE 后面的输出' '\033[1;32m✅ 已更新。\033[0m'
rlog R2 "$L_PASS"; rlog R3 "$L_UNOBS"; rlog R4 "$L_NOTREADY_POST"; rlog R5 "$L_PASS_YELLOW"; rlog R6 "$L_PASS" "$L_PASS"
rlog R7 "$L_PASS" "$REAL380"; rlog R8 '\033[1;32m✅ 已更新。\033[0m' '其它输出'; rlog R10 "$L_READY" "$L_PASS"
rlog R11 '  DoT 证据端: 核验通过 —— 运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有。'; rlog R12 '迁移链开始' "$L_ROLLBACK"
rlog R16 "$L_INCOMPLETE"
for id in R1 R2 R3 R4 R5 R6 R7 R8 R10 R11 R12 R16; do want "$id" && cell "$id" "cp \"$T/rlog-$id\" \"\$C/log.txt\"; $RCODE"; done
want R9 && cell R9 "$RCODE"
# 383 A3: 归类结果读取的注入(只对本格的 rep.txt / log.txt 生效; 命中记进本格 inj.log)
GREPF='grep(){ if [[ "${*: -1}" == "$C/rep.txt" ]]; then command grep "$@"; echo "grep 注入: 原样输出, 原退出 $?, 改返回 2" >> "$C/inj.log"; return 2; fi; command grep "$@"; }'
pyf(){ printf 'python3(){ if [[ "${1:-}" == - && "${2:-}" == "$C/log.txt" ]]; then command cat > /dev/null; printf "%%b" "%s"; echo "python3 注入: %s" >> "$C/inj.log"; return 0; fi; command python3 "$@"; }' "$1" "$2"; }
want R13 && cell R13 "cp \"$T/rlog-R1\" \"\$C/log.txt\""$'\n'"$GREPF"$'\n'"$RCODE"
want R14 && cell R14 "cp \"$T/rlog-R1\" \"\$C/log.txt\""$'\n'"$(pyf 'CLASS=RECOVERED\nN=1\nNR=0\nCHAIN=ok\nCLASS=PASS\n' 'CLASS 重复')"$'\n'"$RCODE"
want R15 && cell R15 "cp \"$T/rlog-R1\" \"\$C/log.txt\""$'\n'"$(pyf 'CLASS=RECOVERED\nN=1\nCHAIN=ok\n' '缺 NR')"$'\n'"$RCODE"
want R1 && jc R1 "380 真实'已恢复'原文(颜色码 / 缩进)⇒ RECOVERED, 1 条, NRestarts=0" 'rq R1 rc 0 && rq R1 cls RECOVERED && rq R1 n 1 && rq R1 nr 0'
want R2 && jc R2 "源码派生'核验通过'(绿)⇒ PASS" 'rq R2 cls PASS'
want R3 && jc R3 "源码派生'状态未取得'(黄 + ⚠️)⇒ UNOBS" 'rq R3 cls UNOBS'
want R4 && jc R4 "源码派生'恢复后确认未就绪'(黄)⇒ SLH_POST_NOTREADY" 'rq R4 cls SLH_POST_NOTREADY'
want R5 && jc R5 "'核验通过'句式配黄色前缀 ⇒ UNRECOGNIZED(颜色与句式不符)" 'rq R5 cls UNRECOGNIZED'
want R6 && jc R6 "两行相同报告 ⇒ DUPLICATE(不默认健康)" 'rq R6 cls DUPLICATE && rq R6 n 2'
want R7 && jc R7 "两行不同报告 ⇒ CONFLICT" 'rq R7 cls CONFLICT'
want R8 && jc R8 "没有'DoT 证据端:'行 ⇒ NONE, 迁移链 ok" 'rq R8 cls NONE && rq R8 chain ok'
want R9 && jc R9 "日志读不了 ⇒ 返回 2(未取得)" 'rq R9 rc 2 && rq R9 cls ""'
want R10 && jc R10 "migrate_dotwitness 的'✅ DoT 证据端已就绪'不计, 另一行核验通过 ⇒ PASS, 1 条" 'rq R10 cls PASS && rq R10 n 1'
want R11 && jc R11 "纯文本(无颜色前缀)的核验通过 ⇒ UNRECOGNIZED(不宽泛剥离)" 'rq R11 cls UNRECOGNIZED'
want R12 && jc R12 "迁移失败回滚且无报告 ⇒ NONE, 迁移链 failed" 'rq R12 cls NONE && rq R12 chain failed'
want R13 && jc R13 "R1 输入, 读归类字段的 grep 先输出全部字段再失败(注入)⇒ 2(已输出的不采信)" 'rq R13 rc 2 && rq R13 cls ""' 'fhas "$T/cell-R13/inj.log" "grep 注入"'
want R14 && jc R14 "归类结果里 CLASS 重复(生产者注入)⇒ 2(不取任一行)" 'rq R14 rc 2 && rq R14 cls ""' 'fhas "$T/cell-R14/inj.log" "python3 注入"'
want R15 && jc R15 "归类结果缺 NR 行(生产者注入)⇒ 2(缺字段不默认)" 'rq R15 rc 2 && rq R15 cls ""' 'fhas "$T/cell-R15/inj.log" "python3 注入"'
want R16 && jc R16 "冻结候选实际输出的 INCOMPLETE 原文 ⇒ INCOMPLETE, 1 条" 'rq R16 rc 0 && rq R16 cls INCOMPLETE && rq R16 n 1'

# ── D 读数(s1_dw_show) ──
DCODE='s1_dw_show; r=$?; echo "RES rc=$r act=${S1_DW[ActiveState]:-}"; echo "WHY: $S1_WHY"'
want D1 && cell D1 "printf '%s\n' \"\$SHOW_OK\" > \"\$C/show.out\"; $DCODE"
want D2 && cell D2 "printf '%s\n' \"\$SHOW_OK\" > \"\$C/show.out\"; echo 1 > \"\$C/show.rc\"; $DCODE"
want D3 && cell D3 "printf '%s\n' \"\$SHOW_OK\" | grep -v '^ControlGroup=' > \"\$C/show.out\"; $DCODE"
want D4 && cell D4 "{ printf '%s\n' \"\$SHOW_OK\"; echo 'ActiveState=failed'; } > \"\$C/show.out\"; $DCODE"
want D5 && cell D5 "{ printf '%s\n' \"\$SHOW_OK\"; echo 'Foo=bar'; } > \"\$C/show.out\"; $DCODE"
want D1 && jc D1 "正常输出 ⇒ 0, 值取全" 'rq D1 rc 0 && rq D1 act active'
want D2 && jc D2 "先输出完整内容后退出 1 ⇒ 2(已输出的不采信)" 'rq D2 rc 2 && rq D2 act ""'
want D3 && jc D3 "缺 ControlGroup ⇒ 2" 'rq D3 rc 2'
want D4 && jc D4 "键重复 ⇒ 2" 'rq D4 rc 2'
want D5 && jc D5 "多出未请求的键 ⇒ 2" 'rq D5 rc 2'

# ── L 监听(s1_listen_owner) ──
LDW='declare -gA S1_DW=([ControlGroup]=/system.slice/pdg-dotwitness.service)'
LPRE="$LDW"$'\n''s1_cg_of(){ case "$1" in 4915) echo /system.slice/pdg-dotwitness.service;; 777) echo /system.slice/other.service;; *) return 2;; esac; }'
LCODE='s1_listen_owner; r=$?; echo "RES rc=$r"; echo "WHY: $S1_WHY"'
lss(){ local f="$T/lss-$1"; shift; { printf '%s\n' "$SS_HEAD"; "$@"; printf '%s\n' "$SS_OTHER"; } > "$f"; }
ss_two(){ printf 'UNCONN 0      0           127.0.0.1:5399      0.0.0.0:*    users:(("python3",pid=4915,fd=3),("evil",pid=777,fd=4))\n'; }
lss L1 ss_line 127.0.0.1:5399 4915; lss L2 true; lss L3 ss_line 127.0.0.1:5399 777; lss L5 ss_line 127.0.0.1:5399 888; lss L6 ss_line 127.0.0.1:53990 4915; lss L7 ss_two
for id in L1 L2 L3 L5 L6 L7; do want "$id" && cell "$id" "$LPRE"$'\n'"cp \"$T/lss-$id\" \"\$C/ss.out\"; $LCODE"; done
want L4 && cell L4 "$LPRE"$'\n'"cp \"$T/lss-L1\" \"\$C/ss.out\"; echo 1 > \"\$C/ss.rc\"; $LCODE"
# 383 A1 / A2: PID 管道与真 s1_cg_of 的注入(命中记进本格 inj.log)
SORTF='sort(){ if [[ "$*" == -u ]]; then command sort -u | head -n 1; echo "sort 注入: 只输出第一项, 改返回 1" >> "$C/inj.log"; return 1; fi; command sort "$@"; }'
CGF='cat(){ if [[ $# == 1 && "$1" == /proc/*/cgroup ]]; then echo "cat 替身: $1" >> "$C/inj.log"; local p="${1#/proc/}"; p="${p%/cgroup}"; [[ -f "$C/cg-$p" ]] || return 1; command cat -- "$C/cg-$p"; return; fi; command cat "$@"; }
printf "0::/system.slice/pdg-dotwitness.service\n" > "$C/cg-4915"'
SEDF='sed(){ if [[ "${1:-}" == -n && "${2:-}" == "$SEDPAT" ]]; then command sed "$@"; echo "sed 注入: 原样输出, 原退出 $?, 改返回 1" >> "$C/inj.log"; return 1; fi; command sed "$@"; }'
want L8 && cell L8 "$LPRE"$'\n'"$SORTF"$'\n'"cp \"$T/lss-L7\" \"\$C/ss.out\"; $LCODE"
want L9 && cell L9 "$LDW"$'\n'"$CGF"$'\n'"$SEDF"$'\n'"cp \"$T/lss-L1\" \"\$C/ss.out\"; $LCODE"
want L10 && cell L10 "$LDW"$'\n'"$CGF"$'\n'"cp \"$T/lss-L1\" \"\$C/ss.out\"; $LCODE"
want L1 && jc L1 "5399 的监听者在该 unit 的 cgroup ⇒ 0" 'rq L1 rc 0'
want L2 && jc L2 "没有 5399 监听 ⇒ 1" 'rq L2 rc 1'
want L3 && jc L3 "监听者 cgroup 不是该 unit ⇒ 1" 'rq L3 rc 1'
want L4 && jc L4 "ss 非零退出 ⇒ 2(不当成没有监听)" 'rq L4 rc 2'
want L5 && jc L5 "监听进程的 cgroup 读不到 ⇒ 2" 'rq L5 rc 2'
want L6 && jc L6 "只有 127.0.0.1:53990(前缀相似)⇒ 1(不误认为 5399)" 'rq L6 rc 1'
want L7 && jc L7 "同一行两个监听者(本 unit 4915 + 外来 777), 管道正常 ⇒ 1(确认存在外来监听者; 对照)" 'rq L7 rc 1' 'whyhas L7 "777:"'
want L8 && jc L8 "同 L7 输入, PID 管道的 sort -u 只输出第一项后失败(注入)⇒ 2(不漏掉外来监听者判成健康)" 'rq L8 rc 2' 'fhas "$T/cell-L8/inj.log" "sort 注入"'
want L9 && jc L9 "真 s1_cg_of: sed 先输出正确路径再失败(注入)⇒ 2(提取失败不采信)" 'rq L9 rc 2' 'fhas "$T/cell-L9/inj.log" "sed 注入"'
want L10 && jc L10 "真 s1_cg_of 读同一份 /proc 夹具、无注入 ⇒ 0(对照)" 'rq L10 rc 0' 'fhas "$T/cell-L10/inj.log" "cat 替身"'

# ── P 门 17(s1_dw_precall) ──
PPRE='s1_boot_id(){ S1_BOOT=0123456789abcdef0123456789abcdef; return 0; }
s1_mono(){ echo 2000000000000; }
echo "# /etc/systemd/system/pdg-dotwitness.service" > "$C/cat.out"
printf "{\"__CURSOR\": \"p1\", \"__MONOTONIC_TIMESTAMP\": \"1999900000\", \"UNIT\": \"pdg-dotwitness.service\", \"_PID\": \"1\", \"MESSAGE\": \"%s\"}\n" "$M_START" > "$C/journal.jsonl"'
PCODE='s1_dw_precall; r=$?; echo "RES rc=$r"'
want P1 && cell P1 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" > \"\$C/show.out\"; $PCODE"
want P2 && cell P2 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" | sed -e 's/^ActiveState=.*/ActiveState=failed/' -e 's/^SubState=.*/SubState=failed/' -e 's/^Result=.*/Result=start-limit-hit/' > \"\$C/show.out\"; $PCODE"
want P3 && cell P3 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" | sed 's/^StartLimitBurst=.*/StartLimitBurst=10/' > \"\$C/show.out\"; $PCODE"
want P4 && cell P4 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" | sed 's|^DropInPaths=.*|DropInPaths=/etc/systemd/system/pdg-dotwitness.service.d/x.conf|' > \"\$C/show.out\"; $PCODE"
want P5 && cell P5 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" > \"\$C/show.out\"; echo 1 > \"\$C/show.rc\"; $PCODE"
want P6 && cell P6 "$PPRE"$'\n'"printf '%s\n' \"\$SHOW_OK\" > \"\$C/show.out\"; : > \"\$C/jfail.b\"; $PCODE"
want P1 && jc P1 "调用前健康、限额 5min / 5、实际 unit 无 drop-in、cat 与时间线取得 ⇒ 0" 'rq P1 rc 0' 'fhas "$T/cell-P1/evid/06-s1-dw-precall.txt" "调用前 300 s 内"'
want P2 && jc P2 "调用前已是 failed / start-limit-hit ⇒ 1(前提不成立)" 'rq P2 rc 1' 'has P2 "前提不成立"'
want P3 && jc P3 "StartLimitBurst=10 ⇒ 1" 'rq P3 rc 1'
want P4 && jc P4 "DropInPaths 非空 ⇒ 1" 'rq P4 rc 1'
want P5 && jc P5 "show 失败 ⇒ 1(观测无效)" 'rq P5 rc 1'
want P6 && jc P6 "本次 boot 的时间线读失败 ⇒ 1" 'rq P6 rc 1'

# ── J 窗口(s1_jwin + s1_jsum) ──
JCODE='s1_jwin pdg-dotwitness.service cA cB "$C/w.tsv"; r=$?; echo "WHY: $S1_WHY"; s1_jsum "$C/w.tsv"; s=$?
echo "RES rc=$r sum=$s slhany=$S1_N_SLHANY start=$S1_N_START after=$S1_N_START_AFTER last=$S1_LAST_KIND refail=$S1_REFAIL otheru=$S1_N_OTHERU crit=$S1_N_UNATTR_CRIT inv=$S1_INV_LAST"'
jfix(){ local f="$T/jfix-$1"; shift; { jbnd cA; "$@"; jbnd cB; } > "$f"; }
j_J1(){ je e1 "$M_REP"; je e2 "$M_RES"; je e3 "$M_FST"; je e4 "$M_START" pdg-dotwitness.service 1 inv-new; }
j_J2(){ je e1 "$M_STOPPING"; je e2 "$M_STOPPED"; je e3 "$M_START"; }
j_J3(){ je e1 "$M_REP"; je e2 "$M_RES"; je e3 "$M_START"; je e4 "$M_REP"; je e5 "$M_RES"; }
j_J4(){ je e1 "$M_RES"; je e2 "$M_START"; je e3 "$M_STOPPING"; je e4 "$M_STOPPED"; je e5 "$M_START"; }
j_J5(){ je e1 "$M_RES"; je e2 "$M_START"; }
j_J6(){ je e1 "$M_RES" other.service 1 - "$BOOT" pdg-dotwitness.service; je e2 "$M_START"; }
j_J7(){ je e1 "$M_RES"; je e2 "$M_START" pdg-dotwitness.service 1 - ffffffffffffffffffffffffffffffff; }
j_J8(){ je e1 "$M_RES"; je e2 "$M_START"; }
j_J9(){ je e1 "$M_RES"; je e2 "$M_START"; }
j_J10(){ je e1 "$M_RES"; echo 'RAW {"__CURSOR": "e2", "MESSAGE": 坏'; }
j_J11(){ je e1 "$M_RES" - 1 - "$BOOT" pdg-dotwitness.service; je e2 "$M_START"; }
j_J12(){ je e1 "$M_RES"; je e2 "$M_START"; }
for id in J1 J2 J3 J4 J5 J6 J7 J8 J9 J10 J11 J12; do want "$id" && jfix "$id" "j_$id"; done
for id in J1 J2 J3 J4 J5 J6 J7 J10 J11; do want "$id" && cell "$id" "cp \"$T/jfix-$id\" \"\$C/journal.jsonl\"; $JCODE"; done
want J8 && cell J8 "cp \"$T/jfix-J8\" \"\$C/journal.jsonl\"; : > \"\$C/jfail.u\"; $JCODE"
want J9 && cell J9 "cp \"$T/jfix-J9\" \"\$C/journal.jsonl\"; s1_jwin pdg-dotwitness.service cB cA \"\$C/w.tsv\"; echo \"RES rc=\$?\"; echo \"WHY: \$S1_WHY\""
want J12 && cell J12 "cp \"$T/jfix-J12\" \"\$C/journal.jsonl\"; s1_jwin pdg-dotwitness.service cA cA \"\$C/w.tsv\"; echo \"RES rc=\$?\"; echo \"WHY: \$S1_WHY\""
want J1 && jc J1 "触限(repeat / result / Failed to start)→ Started ⇒ 有效; 触限 2 条; 末次触限后启动 1; 末态 start; 实例字段取到" \
  'rq J1 rc 0 && rq J1 slhany 2 && rq J1 after 1 && rq J1 last start && rq J1 inv inv-new'
want J2 && jc J2 "只有 Stopping / Stopped / Started ⇒ 触限 0" 'rq J2 rc 0 && rq J2 slhany 0 && rq J2 start 1'
want J3 && jc J3 "触限 → Started → 再次触限 ⇒ 再次触限 1, 末次触限后无启动, 末态 slh" 'rq J3 refail 1 && rq J3 after 0 && rq J3 last slh'
want J4 && jc J4 "触限 → Started → Stopping → Stopped → Started ⇒ 末次触限后启动 2, 末态 start, 再次触限 0" 'rq J4 after 2 && rq J4 last start && rq J4 refail 0'
want J5 && jc J5 "事件没有 INVOCATION_ID ⇒ 窗口照样有效, 实例字段'-'(只影响实例对照)" 'rq J5 rc 0 && rq J5 inv - && rq J5 slhany 1'
want J6 && jc J6 "触限字样消息的 UNIT 是别的 unit ⇒ 不计入目标触限(0), 记他 unit 1" 'rq J6 rc 0 && rq J6 slhany 0 && rq J6 otheru 1'
want J7 && jc J7 "有一条 _BOOT_ID 不是本次 boot ⇒ 返回 2" 'rq J7 rc 2' 'whyhas J7 "不属于本次 boot"'
want J8 && jc J8 "journalctl -u 先输出后失败 ⇒ 返回 2" 'rq J8 rc 2'
want J9 && jc J9 "界桩顺序不成立 ⇒ 返回 2" 'rq J9 rc 2' 'whyhas J9 "界桩顺序不成立"'
want J10 && jc J10 "JSON 行损坏 ⇒ 返回 2" 'rq J10 rc 2'
want J11 && jc J11 "触限消息既无 UNIT 也无 _SYSTEMD_UNIT(PID 1)⇒ 窗口有效但归属未取得的关键事件 1" 'rq J11 rc 0 && rq J11 crit 1 && rq J11 slhany 0'
want J12 && jc J12 "起止为同一游标 ⇒ 返回 2, 理由界桩顺序不成立(尾段核对对同一游标放行, 这一形态只靠界桩顺序核对; 383 另立登记, 不算 382 已覆盖)" 'rq J12 rc 2' 'whyhas J12 "界桩顺序不成立"'

# ── S 结算(s1_settle) ──
sbase(){ S1_G=0; S1_GATE_NAME=""; S1_CNT=1; S1_UPG=OK; S1_WIN=OK; S1_WIN_WHY=""; S1_N_EV=4; S1_N_SLHANY=2; S1_N_SLH=1; S1_N_SLHREP=1
  S1_N_START=1; S1_N_START_AFTER=1; S1_LAST_KIND=start; S1_REFAIL=0; S1_N_UNATTR=0; S1_N_UNATTR_CRIT=0; S1_N_OTHERU=0; S1_N_FAILX=0; S1_INV_LAST=-
  S1_REP=RECOVERED; S1_REP_N=1; S1_REP_NR=0; S1_CHAIN=ok; S1_POST=OK; S1_POST_WHY=""; S1_POST_INV=cdaa252d54774cb6bff2ad5c0ff4e9ff; }
SCODE='s1_settle; echo "RES verdict=$S1_VERDICT"; echo "WHY: $S1_VERDICT_WHY"'
scell(){ want "$1" && cell "$1" "sbase; $2; $SCODE"; }
NOSLH='S1_N_SLHANY=0; S1_N_SLH=0; S1_N_SLHREP=0; S1_N_START_AFTER=0'
scell S1 "$NOSLH; S1_REP=PASS"
scell S2 ':'
scell S3 'S1_POST=BAD; S1_POST_WHY="调用返回后不是健康运行(loaded / enabled / failed / failed, Result=start-limit-hit)"'
scell S4 'S1_POST=BAD; S1_POST_WHY="5399 监听: 127.0.0.1:5399 的监听者不在该 unit 的 cgroup"'
scell S5 'S1_REFAIL=1; S1_N_START_AFTER=0; S1_LAST_KIND=slh; S1_POST=BAD; S1_POST_WHY="调用返回后不是健康运行"'
scell S6 'S1_N_START=2; S1_N_START_AFTER=2'
scell S7 'S1_G=17; S1_GATE_NAME="pdg-dotwitness 调用前门"; S1_CNT=0'
scell S8 'S1_WIN=INVALID; S1_WIN_WHY="界桩游标缺失"'
scell S9 'S1_POST=UNOBT; S1_POST_WHY="调用后读数观测无效"'
scell S10 'S1_REP=CONFLICT; S1_REP_N=2'
scell S11 'S1_UPG=FAIL; S1_CHAIN=failed; S1_REP=NONE; S1_REP_N=0'
scell S12 'S1_REP=PASS'
scell S13 'S1_REP=NONE; S1_REP_N=0'
scell S14 'S1_REP=SLH_START_FAIL; S1_POST=BAD; S1_POST_WHY="调用返回后不是健康运行"'
scell S15 'S1_CNT=""'
scell S16 'S1_REFAIL=1'
scell S17 'S1_N_UNATTR=1; S1_N_UNATTR_CRIT=1'
scell S18 'S1_N_START_AFTER=0; S1_LAST_KIND=fail'
scell S19 'S1_REP=SLH_POST_NOTREADY'
scell S20 'S1_REP=NOTREADY'
scell S21 'S1_REP=INCOMPLETE'
scell S22 "$NOSLH; S1_REP=INCOMPLETE"
scell S23 "$NOSLH; S1_REP=PASS; S1_POST=UNOBT; S1_POST_WHY=\"调用后读数观测无效\""
scell S24 "$NOSLH; S1_REP=PASS; S1_POST=BAD; S1_POST_WHY=\"调用返回后不是健康运行\""
v(){ rq "$1" verdict "$2"; }
want S1 && jc S1 "健康升级、未触限、报告核验通过 ⇒ 未覆盖(层5 未覆盖, 层6 一致)" 'v S1 UNCOVERED' 'has S1 "层5 恢复现象: 未覆盖"' 'has S1 "层6 产品报告与观测: 一致"'
want S2 && jc S2 "触限 → 启动, 报告已恢复, 返回后健康 ⇒ PASS; 层8 次数与来源未取得" 'v S2 PASS' 'has S2 "reset-failed 的次数与调用者: 未取得"' 'whyhas S2 "精确动作次数和来源未直接取得"'
want S3 && jc S3 "报告已恢复但返回后 failed ⇒ 恢复失败; 层6 分别记录两个时点, 不判报告不实(383 语义更正)" 'v S3 RECOVERY_FAILED' 'has S3 "时点不同"' '! has S3 "层6 产品报告与观测: 不一致"'
want S4 && jc S4 "报告已恢复但监听不归属 ⇒ 恢复失败; 层6 分别记录两个时点, 不判报告不实(383 语义更正)" 'v S4 RECOVERY_FAILED' 'has S4 "时点不同"' '! has S4 "层6 产品报告与观测: 不一致"'
want S5 && jc S5 "触限 → 启动 → 再次触限, 返回后 failed ⇒ 恢复失败" 'v S5 RECOVERY_FAILED'
want S6 && jc S6 "末次触限后启动 2 次 ⇒ PASS 且注明来源未取得、不判重复恢复" 'v S6 PASS' 'has S6 "不判为重复恢复"'
want S7 && jc S7 "门 17 未过 ⇒ 前提不成立, 判词不含'升级失败'" 'v S7 PRECOND' '! whyhas S7 "升级失败"' 'has S7 "层2 调用次数: 0"'
want S8 && jc S8 "窗口无效 ⇒ 未取得" 'v S8 UNOBTAINED'
want S9 && jc S9 "返回后健康未取得 ⇒ 未取得" 'v S9 UNOBTAINED'
want S10 && jc S10 "报告矛盾 ⇒ 未取得" 'v S10 UNOBTAINED'
want S11 && jc S11 "链失败(升级层不成立、无报告)⇒ 升级失败, 层6 新步骤按路径不应执行" 'v S11 UPGRADE_FAILED' 'has S11 "新步骤按路径不应执行"'
want S12 && jc S12 "触限 → 启动, 报告核验通过 ⇒ 未覆盖(恢复来源未取得)" 'v S12 UNCOVERED' 'whyhas S12 "恢复来源未取得"'
want S13 && jc S13 "链成功但无报告(有触限、返回后健康)⇒ 未取得" 'v S13 UNOBTAINED'
want S14 && jc S14 "报告 start 失败、返回后 failed ⇒ 恢复失败, 层6 一致" 'v S14 RECOVERY_FAILED' 'has S14 "层6 产品报告与观测: 一致"'
want S15 && jc S15 "已调用但计数读不出 ⇒ 未取得" 'v S15 UNOBTAINED'
want S16 && jc S16 "触限 → 启动 → 触限 → 启动, 返回后健康 ⇒ 未取得" 'v S16 UNOBTAINED'
want S17 && jc S17 "有归属未取得的触限 / 失败类事件 ⇒ 未取得" 'v S17 UNOBTAINED'
want S18 && jc S18 "返回后健康但末次触限后没有启动事件 ⇒ 未取得" 'v S18 UNOBTAINED'
want S19 && jc S19 "报告'恢复后确认未就绪'但返回后健康 ⇒ 未取得(两个时点分别记录)" 'v S19 UNOBTAINED'
want S20 && jc S20 "触限 → 启动, 报告'未就绪(不重置、不启动)', 返回后健康 ⇒ 未覆盖; 层6 分别记录两个时点(383 语义更正)" 'v S20 UNCOVERED' 'has S20 "时点不同"' '! has S20 "层6 产品报告与观测: 不一致"'
want S21 && jc S21 "触限 → 启动, 报告 INCOMPLETE, 返回后健康 ⇒ 未取得; 层8 不写'没有做恢复动作', 判词不写'未覆盖'" 'v S21 UNOBTAINED' '! has S21 "没有做恢复动作"' '! whyhas S21 "未覆盖"' 'has S21 "推不出是否执行过 reset-failed / start"'
want S22 && jc S22 "未触限, 报告 INCOMPLETE, 返回后健康 ⇒ 未覆盖; 层5 不写'没有被走到', 层6 不判报告不实, 层8 不写'没有做恢复动作'" 'v S22 UNCOVERED' '! has S22 "没有被走到"' '! has S22 "层6 产品报告与观测: 不一致"' '! has S22 "没有做恢复动作"' 'has S22 "恢复分支的覆盖证据未取得"'
want S23 && jc S23 "未触限, 报告核验通过, 返回后健康未取得 ⇒ 未覆盖; 层6 不判(观测无效不作为报告不实的证据)" 'v S23 UNCOVERED' 'has S23 "层6 产品报告与观测: 不判"' '! has S23 "层6 产品报告与观测: 不一致"'
want S24 && jc S24 "未触限, 报告核验通过, 返回后不健康 ⇒ 未覆盖; 层6 分别记录两个时点, 不判报告不实" 'v S24 UNCOVERED' 'has S24 "时点不同"' '! has S24 "层6 产品报告与观测: 不一致"'

# ── G 门组合与唯一调用(s1_gated_invoke) ──
GPRE='r3_real2_gate(){ echo real2 >> "$C/order.log"; R3_WHY=替身; return "${G_R2:-0}"; }
r3_bridge_identity_gate(){ echo identity >> "$C/order.log"; return "${G_ID:-0}"; }
r3_dns_instrument(){ echo dns >> "$C/order.log"; return "${G_DNS:-0}"; }
r3_runtime_gate(){ echo runtime >> "$C/order.log"; return "${G_RT:-0}"; }
s1_dw_precall(){ echo precall >> "$C/order.log"; return "${G_PC:-0}"; }
r3_precapture(){ echo precapture >> "$C/order.log"; return "${G_CAP:-0}"; }
s1_mono(){ echo 123; }
: > "$C/order.log"; R3_COUNT="$C/count.txt"; r3_count_init
R3_CLI="$T/bin/fakecli"; RETIRE_TAG=v9.9.9-retire-TEST; R3_TIMEOUT=10; R3_REAL2_LOG="$C/real2.log"
R3_LOG="$C/wk/up.log"; R3_RCFILE="$C/wk/up.rc"; R3_TOERR="$C/wk/up.toe"'
# 383 B5: 零调用结论依赖的三份记录(计数 / 独立调用记录 / 门顺序)读不了 ⇒ 本格执行无效(不补成 0, 也不记成业务不符); 替身 CLI 记录写不进(退出 97)同样无效
GCODE='s1_gated_invoke; r=$?
c="$(cat -- "$C/count.txt")" || { echo "计数文件读不了 —— 本格无效"; exit 3; }
k="$(wc -l < "$C/calls.log")" || { echo "独立调用记录读不了 —— 本格无效"; exit 3; }
[[ "$k" =~ ^[0-9]+$ ]] || { echo "独立调用记录的行数不是整数([$k]) —— 本格无效"; exit 3; }
o="$(tr "\n" , < "$C/order.log")" || { echo "门顺序记录读不了 —— 本格无效"; exit 3; }
if [[ -s "$R3_RCFILE" && "$(cat -- "$R3_RCFILE")" == 97 ]]; then echo "替身 CLI 的调用记录写不进 —— 本格无效"; exit 3; fi
echo "RES rc=$r cnt=$c calls=$k order=$o"'
gcell(){ want "$1" && cell "$1" "$GPRE"$'\n'"$2"$'\n'"$GCODE"; }
gcell G1 ':'; gcell G2 'G_R2=1'; gcell G3 'G_ID=1'; gcell G4 'G_DNS=1'; gcell G5 'G_RT=1'; gcell G6 'G_PC=1'; gcell G7 'G_CAP=1'
gcell G8 'r3_count_write 1'; gcell G9 'echo x > "$C/count.txt"'
g0(){ rq "$1" rc "$2" && rq "$1" calls 0 && rq "$1" order "$3"; }
want G1 && jc G1 "全过 ⇒ 0; 计数 1; 替身 CLI 调用 1(独立记录); 门顺序登记; 绊线 0" \
  'rq G1 rc 0 && rq G1 cnt 1 && rq G1 calls 1 && rq G1 order "real2,identity,dns,runtime,precall,precapture,"' \
  'fhas "$T/cell-G1/calls.log" "update --to v9.9.9-retire-TEST" x' 'trip0 G1'
want G2 && jc G2 "② 门不过 ⇒ 10, 零调用, 后续门未调用" 'g0 G2 10 real2,' 'rq G2 cnt 0'
want G3 && jc G3 "身份门不过 ⇒ 11, 零调用" 'g0 G3 11 real2,identity,' 'rq G3 cnt 0'
want G4 && jc G4 "DNS 仪器不过 ⇒ 15, 零调用" 'g0 G4 15 real2,identity,dns,' 'rq G4 cnt 0'
want G5 && jc G5 "运行态门不过 ⇒ 12, 零调用" 'g0 G5 12 real2,identity,dns,runtime,' 'rq G5 cnt 0'
want G6 && jc G6 "dotwitness 调用前门不过 ⇒ 17, 零调用" 'g0 G6 17 real2,identity,dns,runtime,precall,' 'rq G6 cnt 0'
want G7 && jc G7 "调用前观测没取全 ⇒ 13, 零调用" 'g0 G7 13 real2,identity,dns,runtime,precall,precapture,' 'rq G7 cnt 0'
want G8 && jc G8 "计数已是 1 ⇒ 14, 替身 CLI 零调用(第二次调用被阻断)" 'g0 G8 14 real2,identity,dns,runtime,precall,precapture,' 'rq G8 cnt 1'
want G9 && jc G9 "计数读不了 ⇒ 14, 替身 CLI 零调用" 'g0 G9 14 real2,identity,dns,runtime,precall,precapture,'
for id in G1 G2 G3 G4 G5 G6 G7 G8 G9 R1 J1 S2; do
  want "$id" || continue
  trip0 "$id"; tr0=$?
  case "$tr0" in
    0) ;;
    1) bad "T-$id 绊线被触发: $(grep "^$id " "$TRIPLOG" | head -2 | tr '\n' ' ')";;
    *) nres=$((nres+1)); bad "T-$id 绊线记录读不了(trip0 返回 $tr0) —— 不说成没有触发";;
  esac
done

# ── K 组合格(383 D1): 调用返回后的真实主流程接线(s1_main 段原样执行) ──
# 真执行: s1_after_call 里的全部接线、s1_jwin / s1_jsum / s1_report / s1_dw_post / s1_settle / s1_verdict_say、③ r3_post_runtime(经真 r3_unit_q)、
#   ③ r3_svc_verdict(经真 r3_set_check / r3_win_check / r3_win_policy / r3_svc_class 与 ② bridge_row_valid)、⑤ SVC_WATCH。
# 叶子替身: r3_arrival_verdict、s1_inline_post、r3_stable_assert、r3_http_code、r3_dns_phase、snap_state、bridge_svc_sample、_j_interval、_evn、_cnt_say、s1_boot_id、s1_cg_of;
#   外部命令替身: systemctl(show / is-active / is-enabled; 每次调用记进 systemctl.calls)、ss、journalctl。ok / bad 换成带计数的版本(同 e2e-lib 的语义)。
mkdir -p "$T/kbin"
cat > "$T/kbin/systemctl" <<'EOS'
#!/usr/bin/env bash
d="${S1M_DIR:?}"; printf '%s\n' "$*" >> "$d/systemctl.calls"
case "$1" in
  show)
    if [[ "${2:-}" == pdg-dotwitness.service ]]; then [[ -f "$d/show.out" ]] && cat "$d/show.out"; exit "$(cat "$d/show.rc" 2>/dev/null || echo 0)"; fi
    if [[ "${2:-}" == -p && "${3:-}" == LoadState && "${4:-}" == --value ]]; then echo loaded; exit 0; fi
    exit 1;;
  is-active|is-enabled)
    f="$d/k/${1#is-}.$2"
    if [[ -f "$f" ]]; then read -r v rc < "$f"; echo "$v"; exit "$rc"; fi
    [[ "$1" == is-active ]] && echo active || echo enabled; exit 0;;
  *) exit 0;;
esac
EOS
chmod +x "$T/kbin/systemctl"
krow(){ printf '%s\t%s.id\tservice\tsimple\t%s\t%s\t%s\t%s\t%s\t%s\t0\t-\t%s\n' "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-ok}"; }
ksvc(){   # $1=before|after $2=调用后 pdg-dotwitness 行
  krow mosdns loaded active running enabled 101 m1; krow mihomo loaded active running enabled 102 h1
  krow pdg-bot loaded active running enabled 103 b1; krow pdg-probe81 loaded active running enabled 104 p1
  if [[ "$1" == before ]]; then krow pdg-dotwitness loaded active running enabled 4915 dwA; else printf '%s\n' "$2"; fi
  krow pdg-health.timer loaded active waiting enabled 0 t1
  if [[ "$1" == before ]]; then krow pdg-mitm loaded active running enabled 106 x1; else krow pdg-mitm not-found inactive dead "" 0 ""; fi
  krow sing-box not-found inactive dead "" 0 ""; krow pdg-rescue.socket loaded inactive dead disabled 0 ""
  krow ssh loaded active running enabled 107 s1; krow cron loaded active running enabled 108 c1
}
M_FEX="pdg-dotwitness.service: Failed with result 'exit-code'."
SHOW_B="${SHOW_OK/MainPID=4915/MainPID=5000}"; SHOW_B="${SHOW_B/InvocationID=cdaa252d54774cb6bff2ad5c0ff4e9ff/InvocationID=dwB}"
SHOW_F="$(printf '%s\n' "$SHOW_OK" | sed -e 's/^ActiveState=.*/ActiveState=failed/' -e 's/^SubState=.*/SubState=failed/' -e 's/^Result=.*/Result=exit-code/' -e 's/^MainPID=.*/MainPID=0/')"
kfix(){   # $1=格 $2=journal 夹具函数 $3=报告(REAL380 / L_PASS / ROLLBACK) $4=调用后 dotwitness 行 $5=show 内容 $6=show rc $7=5399 监听 pid [$8=dotwitness is-active "值 rc"]
  local D="$T/kin-$1"; mkdir -p "$D/k"
  { jbnd cA; "$2"; jbnd cB; } > "$D/journal.jsonl"
  case "$3" in ROLLBACK) printf '%b\n' "$L_ROLLBACK" > "$D/up.log";; *) printf '%b\n' "${!3}" '\033[1;32m✅ 已更新。\033[0m' > "$D/up.log";; esac
  ksvc before > "$D/before.tsv"; ksvc after "$4" > "$D/after.tsv"
  printf '%s\n' "$5" > "$D/show.out"; echo "$6" > "$D/show.rc"
  { printf '%s\n' "$SS_HEAD"; ss_line 127.0.0.1:5399 "$7"; printf '%s\n' "$SS_OTHER"; } > "$D/ss.out"
  [[ -z "${8:-}" ]] || printf '%s\n' "$8" > "$D/k/active.pdg-dotwitness"
}
kj1(){ je e1 "$M_REP"; je e2 "$M_RES"; je e3 "$M_START" pdg-dotwitness.service 1 dwB; }
kj2(){ je e1 "$M_STOPPING"; je e2 "$M_STOPPED"; je e3 "$M_START" pdg-dotwitness.service 1 dwA; }
kj3(){ je e1 "$M_RES"; je e2 "$M_START" pdg-dotwitness.service 1 dwB; je e3 "$M_FEX"; }
kj4(){ je e1 "$M_RES"; je e2 "$M_START" pdg-dotwitness.service 1 dwB; }
KPRE='# shellcheck source=/dev/null
source "$T/kdeps.sh"; source "$T/kmain.sh"
export PATH="$T/kbin:$PATH"
E2E_PASS=0; E2E_FAIL=0
ok(){ echo "VOK $1"; E2E_PASS=$((E2E_PASS+1)); }; bad(){ echo "VBAD $1"; E2E_FAIL=$((E2E_FAIL+1)); }; SECT(){ echo "SECT $1"; }
r3_arrival_verdict(){ echo "替身 r3_arrival_verdict($K_ARR)" >> "$C/calls.log"; R3_OBS=VALID; R3_WRAP_RC=0
  if [[ "$K_ARR" == OK ]]; then R3_PROC=OK; R3_ARRIVE=OK; R3_RC=0; return 0; fi; R3_PROC=FAIL; R3_ARRIVE=FAIL; R3_RC=1; return 1; }
s1_inline_post(){ echo "替身 s1_inline_post($K_ARR)" >> "$C/calls.log"
  if [[ "$K_ARR" == OK ]]; then ok "S1-2 / S1-3 撤除·迁移·保留判据(替身: 成立)"; else bad "S1-2 A4 ios 模块与候选树不同(替身: 迁移链失败回滚)"; fi; }
r3_stable_assert(){ echo "stable $*" >> "$C/calls.log"; return 0; }
r3_http_code(){ R3_VAL=200; return 0; }
r3_dns_phase(){ echo "dns_phase $*" >> "$C/calls.log"; ok "S1-4 DNS(替身: W / C / P 路径成立)"; return 0; }
snap_state(){ :; }
bridge_svc_sample(){ echo "sample $1" >> "$C/calls.log"; cp "$C/after.tsv" "$1"; }
_j_interval(){ case "$1" in pdg-dotwitness) echo 2;; mosdns) echo 1;; *) echo 0;; esac; }
_evn(){ :; }; _cnt_say(){ printf "%s" 1; }
s1_boot_id(){ S1_BOOT="$BOOT"; return 0; }
s1_cg_of(){ echo "s1_cg_of $1" >> "$C/calls.log"; case "$1" in 4915|5000) echo /system.slice/pdg-dotwitness.service;; *) return 2;; esac; }
R3_COUNT="$C/count.txt"; printf "1\n" > "$R3_COUNT"
R3_LOG="$C/up.log"; R3_REPO=/x; R3_CLI=/x; RETIRE_TAG=v9.9.9-retire-TEST; RETIRE_SHA=x; BRIDGE_TAG=x; BRIDGE_SHA=x; R3_ORIGIN=x; R3_TIMEOUT=1
C3_0=cA; S1_C1=cB; S1_G=0; S1_GATE_NAME=""
cp "$C/before.tsv" "$R3_TMP/svc-retire-before.tsv"'
KCODE='s1_after_call; echo "RES upg=$S1_UPG core=${S1_UPG_CORE_N:-} rt=${S1_UPG_RT_N:-} verdict=$S1_VERDICT post=$S1_POST efail=$E2E_FAIL"'
kcell(){ want "$1" || return 0; (( K_OK )) || return 0; cell "$1" "cp -r \"$T/kin-$1/.\" \"\$C/\"; K_ARR=$2"$'\n'"$KPRE"$'\n'"$KCODE"; }
want K1 && kfix K1 kj1 REAL380 "$(krow pdg-dotwitness loaded active running enabled 5000 dwB)" "$SHOW_B" 0 5000
want K2 && kfix K2 kj2 L_PASS "$(krow pdg-dotwitness loaded active running enabled 4915 dwA)" "$SHOW_OK" 0 4915
want K3 && kfix K3 kj3 REAL380 "$(krow pdg-dotwitness loaded failed failed enabled 0 dwB)" "$SHOW_F" 0 5000 "failed 3"
want K4 && kfix K4 kj4 REAL380 "$(krow pdg-dotwitness "" "" "" "" "" "" 'bad:ActiveState 查询失败(rc=1)')" "$SHOW_B" 1 5000
want K5 && kfix K5 kj2 ROLLBACK "$(krow pdg-dotwitness loaded active running enabled 4915 dwA)" "$SHOW_OK" 0 4915
kcell K1 OK; kcell K2 OK; kcell K3 OK; kcell K4 OK; kcell K5 FAIL
want K1 && jc K1 "组合(真实主流程接线): 全部健康、触限 → 启动、报告已恢复 ⇒ PASS; 升级层成立, 两段失败数 0" \
  'rq K1 upg OK && rq K1 verdict PASS && rq K1 post OK && rq K1 core 0 && rq K1 rt 0 && rq K1 efail 0'
want K2 && jc K2 "组合: 全部健康、未触限、核验通过 ⇒ 未覆盖(整体非零)" 'rq K2 upg OK && rq K2 verdict UNCOVERED && rq K2 post OK && rq K2 core 0 && rq K2 rt 0' '! rq K2 efail 0'
want K3 && jc K3 "组合: 产品退出 0、目标到达, dotwitness 终态 failed ⇒ 升级层仍不成立(共享运行态 / 服务对账, 不清零), 结论升级失败; 层3 子项、层5 恢复失败、层7 不健康照记" \
  'rq K3 upg FAIL && rq K3 verdict UPGRADE_FAILED && rq K3 post BAD && rq K3 core 0' '! rq K3 rt 0' '! rq K3 rt ""' '! rq K3 efail 0' \
  'has K3 "含 pdg-dotwitness"' 'has K3 "层5 恢复现象: 恢复失败"' 'has K3 "层7 调用返回后健康: 不健康"' '! has K3 "层5 恢复现象: 不判"'
want K4 && jc K4 "组合: 产品退出 0、目标到达, dotwitness 健康观测无效 ⇒ 升级层仍不成立, 结论升级失败; 层3 注明共享判据把观测无效记为失败, 层5 / 层7 未取得" \
  'rq K4 upg FAIL && rq K4 verdict UPGRADE_FAILED && rq K4 post UNOBT && rq K4 core 0' '! rq K4 rt 0' '! rq K4 rt ""' '! rq K4 efail 0' \
  'has K4 "观测无效也记为失败"' 'has K4 "层5 恢复现象: 未取得"' 'has K4 "层7 调用返回后健康: 未取得"' '! has K4 "层5 恢复现象: 不判"'
want K5 && jc K5 "组合: 升级自身失败(产品退出 1、迁移链回滚、无报告)⇒ 升级失败, 层6 新步骤按路径不应执行, 层5 照记窗口事实" \
  'rq K5 upg FAIL && rq K5 verdict UPGRADE_FAILED' '! rq K5 core 0' 'has K5 "新步骤按路径不应执行"' '! has K5 "层5 恢复现象: 不判"'

# ── V 契约自身的执行有效性(元格) ──
if want V; then
  cell V0 'echo "RES x=1"'; cell V1 'exit 3'; cell V2 'exec >/dev/null 2>&1'; cell V3 'echo "RES x=1"'
  chmod 000 "$T/cell-V3/out" 2>/dev/null
  mt "V0 正控: 正常走完的格判为执行有效" 'cvalid V0'
  mt "V1 子壳中途 exit 3 ⇒ 执行无效(不算通过)" '! cvalid V1'
  mt "V2 结束标记被吞掉(子壳退出 0)⇒ 执行无效" '! cvalid V2'
  if [[ "$(id -u)" == 0 ]]; then echo "[NOTE] V3 以 root 运行时 chmod 000 挡不住读取, 这一格不判(不计入通过)"
  else mt "V3 结果文件读不了 ⇒ 执行无效" '! cvalid V3'; fi
  # 383 B: 结束标记、结果结构、绊线与取反、生产者、零调用记录 —— 执行无效(3)/ 结果无效(4)/ 业务不成立(1)分开
  vfix(){ local d="$T/cell-$1"; mkdir -p "$d"; printf '%s\n' 12345 > "$d/nonce"; printf '%s\n' 0 > "$d/rc"; printf '%b' "$2" > "$d/out"; }
  vfix V4 'RES x=1\nCELL-END 12345\nCELL-END 12345\n'; vfix V5 'RES x=1\nCELL-END 12345\nRES y=2\n'
  vfix V6 'RES x=1\nxCELL-END 12345\n'; vfix V6b 'RES x=1\nCELL-END 123456\n'
  vfix V7 'RES rc=1\nRES rc=0\nCELL-END 12345\n'; vfix V8 'RES rc=1 rc=0\nCELL-END 12345\n'; vfix V9 'RES rc=0\nCELL-END 12345\n'
  vfix V10 'RES rc=0 junk\nCELL-END 12345\n'; vfix V11 'RES rc=0\nCELL-END 12345\n'; mkdir -p "$T/v11-trip.d"
  mt "V4 结束标记出现两次 ⇒ 执行无效" '! cvalid V4'
  mt "V5 结束标记后面还有输出(不是末行)⇒ 执行无效" '! cvalid V5'
  mt "V6 只有结束标记的子串, 或前缀相同的另一随机串 ⇒ 执行无效" '! cvalid V6 && ! cvalid V6b'
  mt "V7 两条 RES 行 ⇒ 结果无效(不取最后一条)" 'jcls V7 "rq V7 rc 0"; [[ $? == 4 ]]'
  mt "V8 RES 同名键 ⇒ 结果无效(不取第一个)" 'jcls V8 "rq V8 rc 1"; [[ $? == 4 ]]'
  mt "V9 条件引用的键不存在 ⇒ 结果无效(不当成业务不成立)" 'jcls V9 "rq V9 cls PASS"; [[ $? == 4 ]]'
  mt "V10 RES 有不含 = 的记号 ⇒ 结果无效" 'jcls V10 "rq V10 rc 0"; [[ $? == 4 ]]'
  mt "V11 绊线记录读不了 ⇒ 结果无效; 绊线循环同一查询返回 2(不当成没有绊线)" \
    'TRIPLOG="$T/v11-trip.d"; jcls V11 "trip0 V11"; a=$?; trip0 V11; b=$?; TRIPLOG="$T/trip.log"; [[ $a == 4 && $b == 2 ]]'
  mt "V12 取反条件里的读取失败(没有 WHY 行)⇒ 结果无效, 不因取反变成立" 'jcls V9 "! whyhas V9 x"; [[ $? == 4 ]]'
  printf 'OK\tP1\tx\nEND\n' > "$T/v13a.txt"; printf 'OK\tP1\tx\n' > "$T/v13b.txt"; printf 'OK\tP1\tx\nBAD\tP1\ty\nEND\n' > "$T/v13c.txt"
  mkdir -p "$T/v13d.txt"; : > "$T/v13.err"
  v13(){ ( ok(){ echo "OKLINE $1"; }; bad(){ echo "BADLINE $1"; }; pres "$1" "$2" "$T/v13.err" 元格 P1 ) > "$T/v13-$3.out" 2>&1
         [[ "$(grep -c '^OKLINE' "$T/v13-$3.out")" == 0 && "$(grep -c '^BADLINE P1 未取得' "$T/v13-$3.out")" == 1 ]]; }
  mt "V13a 生产者打印了 OK 却非零退出 ⇒ 依赖项未取得, 0 条 OK" 'v13 1 "$T/v13a.txt" a'
  mt "V13b 生产者没有 END ⇒ 依赖项未取得" 'v13 0 "$T/v13b.txt" b'
  mt "V13c 同一项两行结果 ⇒ 未取得" 'v13 0 "$T/v13c.txt" c'
  mt "V13d 生产者输出读不了 ⇒ 未取得" 'v13 0 "$T/v13d.txt" d'
  mt "V13e 正控: 生产者走完、恰一行 OK ⇒ 采信 OK" '( ok(){ echo "OKLINE $1"; }; bad(){ echo "BADLINE $1"; }; pres 0 "$T/v13a.txt" "$T/v13.err" 元格 P1 ) | grep -qx "OKLINE P1 x"'
  cell V14a "$GPRE"$'\n''r3_real2_gate(){ echo real2 >> "$C/order.log"; rm -f "$C/calls.log"; mkdir "$C/calls.log"; return 1; }'$'\n'"$GCODE"
  cell V14b "$GPRE"$'\n''r3_real2_gate(){ echo real2 >> "$C/order.log"; rm -f "$C/count.txt"; mkdir "$C/count.txt"; return 1; }'$'\n'"$GCODE"
  cell V15 "$GPRE"$'\n''mkdir -p "$C/alt/calls.log"; export S1M_DIR="$C/alt"'$'\n'"$GCODE"
  mt "V14a 零调用依赖的独立调用记录读不了 ⇒ 执行无效(jc 归为执行无效, 不记业务不符)" \
    '! cvalid V14a && grep -q "独立调用记录读不了" "$T/cell-V14a/out" && { jcls V14a "g0 V14a 10 real2,"; [[ $? == 3 ]]; }'
  mt "V14b 零调用依赖的计数文件读不了 ⇒ 执行无效" '! cvalid V14b && grep -q "计数文件读不了" "$T/cell-V14b/out" && { jcls V14b "g0 V14b 10 real2,"; [[ $? == 3 ]]; }'
  mt "V15 替身 CLI 的调用记录写不进 ⇒ 替身退出 97, 该格执行无效" '! cvalid V15 && grep -q "替身 CLI 的调用记录写不进" "$T/cell-V15/out"'
fi
fin

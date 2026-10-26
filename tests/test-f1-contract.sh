#!/usr/bin/env bash
# shellcheck disable=SC2034  # 全文件: 格里赋值的变量由 source 进来的被测原文按名字读取(静态看不到)
# ──────────────────────────────────────────────────────────────────
# F-1 验收器(tests/e2e-real-f1.sh)与占用者(tests/helpers/f1-occupant.py)的接线契约与本地模型格(不碰真实服务; 不需要 root / systemd)。
#   一、workflow 接线: real_scope 多了 f1 这一个选项(整块原文登记); 文件末尾追加的 real-f1(矩阵 variant [a, b])是最后一个 job;
#       它的准备步骤与 S-1 job 逐字相同、② 步只换名称行、F-1 步与留证步按登记生成; 相对 93bb2152 只有这两处改动。
#   二、静态: 只有登记的八个路径相对 93bb2152 有变化; S-1 验收器与全部共享输入逐字节不变; 验收器按它自己的抽法从"现在"与 93bb2152
#       各抽一次逐名逐字相同且非空; 不得调用的函数、对 pdg-dotwitness 的 systemctl 动作、systemctl 包装都没有; 唯一调用入口与静置调用点各恰一处;
#       f1_seed / f1_post_runtime 与原文的差只有登记的那几处; 受监视服务表恰去掉 pdg-dotwitness; 占用者 unit 全文按登记。
#   三、模型格: 占用者程序真跑(非特权、随机高位端口、自建 NOTIFY_SOCKET); 被测函数一律按唯一成对标记从验收器抽原文执行;
#       只替换外部命令与本格登记的叶子函数; 每格一个子壳, 带随机串结束标记; 没有结束标记、子壳非零退出或结果读不了 ⇒ 本格执行无效, 不算通过。
#   这些都是模型验证, 不冒充真实 systemd、journal 或 root 环境的验收。
# 用法: bash tests/test-f1-contract.sh
#       PDG_F1C_ONLY="wiring static O1 J1 …" 只跑点名的节(wiring / static)与模型格, 供撤销对照用; 不点名时全跑。
# ──────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${PDG_F1C_BASE:-93bb2152802c1a1be5b6a46bdc6b7674ee0a1241}"   # 验收冻结基线(F-1 之前的验收 HEAD)
F1="$ROOT/tests/e2e-real-f1.sh"; S1="$ROOT/tests/e2e-real-first-upgrade.sh"; R3="$ROOT/tests/e2e-real-retire-hop.sh"
HOP2="$ROOT/tests/e2e-real-bridge-hop.sh"; PLAT="$ROOT/tests/e2e-real-platform-fail.sh"; WF="$ROOT/.github/workflows/ci.yml"
ME="$ROOT/tests/test-f1-contract.sh"; OCC="$ROOT/tests/helpers/f1-occupant.py"
ONLY="${PDG_F1C_ONLY:-}"
pass=0; nfail=0; nexec=0; nres=0; nbiz=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
fin(){ echo "────────────────────────────────────────"; echo "通过 $pass, 失败 $nfail"
  echo "失败分类: 模型格执行无效 $nexec / 结果无效 $nres / 业务不成立 $nbiz / 其它(接线、静态、生产者没走完等) $((nfail - nexec - nres - nbiz))"
  (( nfail == 0 && pass > 0 )) || exit 1; exit 0; }
rdf(){   # $1=文件 → 0 整份读出(放在 RDV) / 1 不存在、读不了或读到一半失败(已输出的部分不采信)
  local v
  RDV=""
  [[ -f "$1" ]] || return 1
  v="$(cat -- "$1" 2>/dev/null)" || return 1
  RDV="$v"
}
want(){ [[ -z "$ONLY" || " $ONLY " == *" $1 "* ]]; }
# 截断一律按字符(按 UTF-8 解码, 坏字节换成替换符); 不用按字节切的 cut -c / head -c, 免得把汉字切成半个(REG-F1-03)
chars(){   # $1=字符数 → 从 stdin 取前 N 个字符
  python3 -I -B -c 'import sys; s = sys.stdin.buffer.read().decode("utf-8", "replace"); sys.stdout.write(s[:int(sys.argv[1])])' "$1"; }
blk(){   # $1=名字 $2=来源 → 打印唯一成对标记之间的原文; 标记不唯一成对或之间为空 ⇒ 非 0
  local n="$1" src="$2" b e
  [[ "$(grep -c "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src")" == 1 && "$(grep -c "^# <<< PDG-EXTRACT-END $n\$" "$src")" == 1 ]] || return 1
  b="$(grep -n "^# >>> PDG-EXTRACT-BEGIN $n\$" "$src" | cut -d: -f1)"
  e="$(grep -n "^# <<< PDG-EXTRACT-END $n\$" "$src" | cut -d: -f1)"
  (( e - b >= 2 )) || return 1
  sed -n "$((b+1)),$((e-1))p" "$src"
}
pres(){   # $1=生产者退出码 $2=生产者输出 $3=生产者 stderr $4=节名 $5..=项 → 生产者走完(退出 0、输出读得出、END 恰一行且在末行)
          # 才逐项采信 OK / BAD(每项恰一行); 否则每项都记"未取得", 不为依赖它的保护项背书
  local prc="$1" f="$2" ef="$3" sec="$4" why="" id l n line ends=0
  shift 4
  if ! rdf "$f"; then why="生产者输出读不了"
  elif [[ "$prc" != 0 ]]; then why="生产者退出 $prc"
  else
    while IFS= read -r l; do [[ "$l" == END ]] && ends=$((ends+1)); done <<< "$RDV"
    if (( ends != 1 )) || [[ "${RDV##*$'\n'}" != END ]]; then why="生产者没有以唯一的 END 收尾"; fi
  fi
  [[ -z "$why" ]] || why="$why($(chars 160 2>/dev/null < "$ef" | tr '\n' ' '))"
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
T="$(mktemp -d "${TMPDIR:-/tmp}/f1c.XXXXXX")" || { echo "[未执行] 建不出临时目录"; echo "通过 0, 失败 1"; exit 1; }
trap 'chmod -R u+rwx -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
for f in "$F1" "$S1" "$R3" "$HOP2" "$PLAT" "$WF" "$ME" "$OCC"; do [[ -f "$f" ]] || { bad "找不到 $f"; fin; }; done
[[ -n "$ONLY" ]] && echo "[NOTE] 只跑点名部分(PDG_F1C_ONLY=$ONLY) —— 这不是整支运行"
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
OPT = '        options: ["all", "platform", "retire", "bridge", "retire-hop", "late-failure", "retire-hop-bc", "first-upgrade", "f1"]'
NOW = [
    '      real_scope:',
    '        # 只在 real_acceptance=true 时有意义。默认 all = 与以前逐字节相同的三 job 语义;',
    '        # 选 platform 就只跑⑤a/⑤b 两个平台方向, 选 retire 就只跑①旧 CLI 直跳被拒。',
    '        # 选 retire-hop 就只跑③(已安装桥接 → 退役候选; 同一 job 里先原样跑 ② 取得真实桥接前像)。',
    '        # 选 late-failure 就只跑④(退役成功后的晚期失败 → 产品自己回滚到本次快照; 同一 job 里先原样跑 ②)。',
    '        # 选 retire-hop-bc 就只跑 B / C2 两跳(前像在本 job 里构造, 再经桥接入口与已装桥接 CLI 两跳到退役候选; b / c2 各一格)。',
    '        # 选 first-upgrade 就只跑 S-1(已安装桥接 → 新候选的首次升级, 不施加准备阶段静置; 同一 job 里先原样跑 ②; 观测 pdg-dotwitness 触限、恢复与父进程收尾)。',
    '        # 选 f1 就只跑 F-1 的 a / b 两格(已安装桥接 → 新候选的首次升级里, 外来进程占住 127.0.0.1:5399 时新步骤的分支、政策与报告; 同一 job 里先原样跑 ②; a 先静置, b 不静置)。',
    '        # 是**显式范围选择**, 不是用 continue-on-error 把失败绕过去 —— 被选中的 job',
    '        # 该红照样红, 没被选中的 job 直接不启动(不产生结果, 也不冒充通过)。',
    '        description: "真实验收的范围(默认 all; platform = 只跑⑤a/⑤b; retire = 只跑①旧 CLI 直跳被拒; bridge = 只跑② v1.11.15→桥接; retire-hop = ②+③ 同一 job; late-failure = ②+④ 同一 job; retire-hop-bc = B/C2 两跳; first-upgrade = ②+S-1 同一 job; f1 = ②+F-1a / ②+F-1b 各一格)"',
    '        type: choice',
    OPT,
    '        default: "all"'
]
def region(lines):
    if lines.count("      real_scope:") != 1:
        return None
    i = lines.index("      real_scope:"); j = i
    while j < len(lines) and lines[j] != '        default: "all"':
        j += 1
    return (i, j + 1) if j < len(lines) else None
R("W1", c.count(OPT) == 1, "real_scope 选项整行逐字相符(原有八项顺序不变, 末尾是 f1)", "real_scope 选项整行不对")
rc, rb = region(c), region(b)
R("W2", rc is not None and c[rc[0]:rc[1]] == NOW, "real_scope 整块与登记原文逐字相符(%d 行)" % len(NOW), "real_scope 整块与登记原文不符或定位不到")
FH = "\n  real-f1:\n"
f1 = ctext[ctext.index(FH) + 1:] if ctext.count(FH) == 1 else ""
heads_f1 = re.findall(r"^  ([a-z][a-z0-9-]*):$", f1, re.M)
good3 = False
if rc and rb and f1 and heads_f1 == ["real-f1"]:
    bm = "\n".join(b[:rb[0]] + ["<<REAL_SCOPE>>"] + b[rb[1]:]); cm = "\n".join(c[:rc[0]] + ["<<REAL_SCOPE>>"] + c[rc[1]:])
    good3 = (cm == bm + "\n" + f1)
R("W3", good3, "相对 93bb2152: 只改了 real_scope 块, 其余改动只有文件末尾追加的 1 个空行 + real-f1(%d 行, 块内只有它一个 job 头)" % f1.count("\n"),
  "相对 93bb2152 有登记之外的改动, 或 real-f1 不是恰 1 处 / 后面还有别的 job")
heads = re.findall(r"^  ([a-z][a-z0-9-]*):$", ctext, re.M)
R("W4", heads[-3:] == ["real-retire-hop-bc", "real-first-upgrade", "real-f1"], "最后一个 job 是 real-f1, 依次紧挨在 real-retire-hop-bc、real-first-upgrade 之后",
  "最后三个 job 是 %r" % (heads[-3:],))
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
s1j, fj = jb("real-first-upgrade"), jb("real-f1")
HEAD = ["  real-f1:",
        "    # ── 真实验收 F-1: 已安装桥接 → 新候选的首次升级里, 一个产品之外的 runtime unit(f1-occupant, PartOf=mosdns、Before=pdg-dotwitness)",
        "    # 在 WLOC 退役那次 mosdns 重启时先占住 127.0.0.1:5399, 观测新步骤对这类真实启动失败的分支、政策与报告 ──",
        "    # a = 调用前静置 303 s(目标: 非 start-limit-hit 分支); b = 不静置(目标: 限额命中 → 定向恢复一次 → 恢复后未就绪)。两格互不依赖。",
        "    needs: prepare-mosdns-fixture",
        "    if: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.real_acceptance == 'true'",
        "            && github.event.inputs.real_scope == 'f1' }}",
        "    runs-on: ubuntu-24.04",
        "    timeout-minutes: 50",
        "    strategy:",
        "      fail-fast: false",
        "      matrix:",
        "        variant: [a, b]",
        '    name: "真实验收 F-1${{ matrix.variant }}: 已安装桥接 → 新候选的首次升级里外来进程占住 5399(同一 runner 先原样跑 ②; a 先静置 / b 不静置)"']
CONTRACT = ['      - name: "前置: F-1 契约 (接线/共享输入与抽取/占用者/门与唯一调用/构造·分支·政策·报告分层结算; 模型)"',
            "        run: bash tests/test-f1-contract.sh"]
R2S1 = '      - name: "② 原样: 按 docs/BRIDGE-ENTRY.md 的入口流程把 v1.11.15 升到桥接版(本次 S-1 的真实前像)"'
R2NAME = '      - name: "② 原样: 按 docs/BRIDGE-ENTRY.md 的入口流程把 v1.11.15 升到桥接版(本次 F-1 的真实前像)"'
F1STEP = ['      - name: "真实验收 F-1${{ matrix.variant }}: 装出外来占用者后, 现役桥接 CLI 执行 update --to 新候选(② 成功才启动)"',
          "        id: f1",
          "        if: ${{ success() && steps.real2.outcome == 'success' }}",
          "        env:",
          '          PDG_E2E_ISOLATED: "1"',
          '          PDG_REAL_MIGRATION_OK: "1"',
          '          PDG_F1_EVID: "/tmp/real-acceptance-evidence-f1"',
          "          PDG_F1_VARIANT: ${{ matrix.variant }}",
          '          PDG_REAL2_LOG: "/tmp/real2-stdout.log"',
          "          PDG_BRIDGE_SHA: ${{ github.event.inputs.bridge_candidate }}",
          "          PDG_RETIRE_SHA: ${{ github.event.inputs.product_candidate }}",
          "        run: sudo -E bash tests/e2e-real-f1.sh"]
EVMAP = [
 ('      - name: "留证: ② 与 S-1 的证据文件、S-1 调用次数与 journal(成败都留)"',
  '      - name: "留证: ② 与 F-1 的证据文件、F-1 调用次数、占用者与 journal(成败都留)"'),
 ('          # 382(同 321): S-1 结束之后, 先对 pdg-dotwitness 取证:',
  '          # F-1(同 321 / 382): F-1 结束之后, 先对 pdg-dotwitness 与占用者取证:'),
 ('也不改变本步骤与 S-1 的结论。',
  '也不改变本步骤与 F-1 的结论。'),
 ('          diag mosdns-journal sudo journalctl -b 0 -u mosdns.service --no-pager -o short-monotonic',
  '          diag mosdns-journal sudo journalctl -b 0 -u mosdns.service --no-pager -o short-monotonic\n'
  '          diag occupant-show systemctl show f1-occupant.service -p LoadState -p ActiveState -p SubState -p Result -p MainPID -p PartOf -p Before -p FragmentPath\n'
  '          diag occupant-cat systemctl cat f1-occupant.service\n'
  '          diag occupant-journal sudo journalctl -b 0 -u f1-occupant.service --no-pager -o short-monotonic\n'
  '          diag ss-udp sudo ss -lunp'),
 ('echo "########## S-1 升级调用次数: $(sudo cat /tmp/real-acceptance-evidence-s1/00-s1-invoke-count.txt 2>/dev/null || echo \'<未取得: S-1 没启动或没写>\') ##########"',
  'echo "########## F-1 升级调用次数: $(sudo cat /tmp/real-acceptance-evidence-f1/00-f1-invoke-count.txt 2>/dev/null || echo \'<未取得: F-1 没启动或没写>\') ##########"'),
 ('for d in /tmp/real-acceptance-evidence /tmp/real-acceptance-evidence-s1; do',
  'for d in /tmp/real-acceptance-evidence /tmp/real-acceptance-evidence-f1; do')
]
def idx(lines, x):
    k = [i for i, l in enumerate(lines) if l == x]
    return k[0] if len(k) == 1 else None
if s1j is None or fj is None:
    for i in ("W5", "W6", "W7", "W8", "W9", "W10", "W11", "W12"):
        R(i, False, "", "S-1 job 或 F-1 job 取不到 —— 本格未取得")
else:
    ftxt = "\n".join(fj)
    R("W5", fj[5:7] == HEAD[5:7] and ftxt.count("real_scope ==") == 1 and "real_scope == 'f1'" in ftxt,
      "real-f1 只在 workflow_dispatch + real_acceptance=true + real_scope=f1 时启动(不搭别的范围的车)", "real-f1 的启动条件不对")
    R("W6", "continue-on-error" not in ftxt, "F-1 job 里没有 continue-on-error", "F-1 job 里有 continue-on-error")
    sts, stf = idx(s1j, "    steps:"), idx(fj, "    steps:")
    c1 = idx(s1j, '      - name: "前置: S-1 契约 (接线/共享输入与抽取/门与唯一调用/触限·恢复·报告·健康分层结算; 模型)"')
    r2a, s1s = idx(s1j, R2S1), idx(s1j, '      - name: "真实验收 S-1: 现役桥接 CLI 执行 update --to 新候选(② 成功才启动; 不施加准备阶段静置)"')
    ev1 = idx(s1j, '      - name: "留证: ② 与 S-1 的证据文件、S-1 调用次数与 journal(成败都留)"')
    cf, r2b, ffs = idx(fj, CONTRACT[0]), idx(fj, R2NAME), idx(fj, F1STEP[0])
    evf = idx(fj, '      - name: "留证: ② 与 F-1 的证据文件、F-1 调用次数、占用者与 journal(成败都留)"')
    allidx = None not in (sts, stf, c1, r2a, s1s, ev1, cf, r2b, ffs, evf)
    prepS, prepF = (s1j[sts:c1], fj[stf:cf]) if allidx else (None, None)
    R("W7", allidx and prepS == prepF, "F-1 job 的准备步骤与 S-1 job 逐字相同(%d 行; 只把 S-1 契约步换成 F-1 契约步)" % (len(prepF) if prepF else 0), "准备步骤与 S-1 job 不同或定位不到")
    R("W8", allidx and fj[cf:cf + 2] == CONTRACT and cf + 2 == r2b, "F-1 契约步恰在准备步骤之后、② 步之前", "F-1 契约步不对")
    ra, rb2 = (s1j[r2a:s1s], fj[r2b:ffs]) if allidx else (None, None)
    R("W9", allidx and rb2[0] == R2NAME and ra[1:] == rb2[1:], "② 步除名称行外与 S-1 job 的 ② 步逐字相同(同一脚本、同一组 env、tee 留档)", "② 步与 S-1 job 不同")
    R("W10", allidx and fj[ffs:evf] == F1STEP, "F-1 步 id / if(② 成功才启动)/ env(恰 7 项: 不含静置 / 超时覆盖)/ run 恰为登记", "F-1 步与登记不符")
    evt = "\n".join(s1j[ev1:]) if allidx else ""
    good11 = allidx and all(evt.count(x) == 1 for x, _ in EVMAP)
    if good11:
        for x, y in EVMAP:
            evt = evt.replace(x, y)
        good11 = evt.split("\n") == fj[evf:] and "        if: ${{ always() }}" in fj[evf:]
    R("W11", good11, "留证步 = S-1 的留证步按登记 %d 处替换(证据目录 / 计数文件 / 名称 / 另加 4 项占用者与端口取证); if: always()" % len(EVMAP), "留证步与登记不符")
    R("W12", allidx and fj == HEAD + prepF + CONTRACT + rb2 + F1STEP + fj[evf:], "F-1 job 整块 = 登记的头 + 准备 + 契约 + ② + F-1 + 留证(顺序与内容), 之后没有别的步骤",
      "F-1 job 整块不是登记的拼接")
try:
    import yaml
    d = yaml.safe_load(ctext)
    jj = d["jobs"]["real-f1"]
    R("W13", jj["strategy"] == {"fail-fast": False, "matrix": {"variant": ["a", "b"]}} and jj["needs"] == "prepare-mosdns-fixture",
      "整份 workflow 能按 YAML 解析, real-f1 的矩阵是 variant [a, b]、fail-fast: false, needs prepare-mosdns-fixture", "real-f1 的 YAML 结构不对")
except ImportError:
    print("NOTE\tW13\t本机没有 PyYAML, YAML 解析这一格未验(文本核对已覆盖接线; 不计入通过)")
except Exception as e:
    R("W13", False, "", "workflow 按 YAML 解析失败或取不到 real-f1(%s)" % type(e).__name__)
print("END")
PY
wrc=$?
grep -E '^NOTE'$'\t' "$T/wiring.txt" 2>/dev/null | sed 's/^NOTE\t/[NOTE] /; s/\t/ /'
if grep -qE '^NOTE'$'\t''W13' "$T/wiring.txt" 2>/dev/null; then
  pres "$wrc" "$T/wiring.txt" "$T/wiring.err" "一 接线核对" W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12
else
  pres "$wrc" "$T/wiring.txt" "$T/wiring.err" "一 接线核对" W1 W2 W3 W4 W5 W6 W7 W8 W9 W10 W11 W12 W13
fi
else bad "一 基线 ci.yml 取不到 —— 接线核对无从谈起"; fi
fi

# ══ 二. 静态 ══
if want static; then
echo "══ 二. 静态: 八路径、共享输入、抽取块、禁用调用、照抄原文、占用者 unit ══"
EIGHT="$(printf '%s\n' .github/workflows/ci.yml tests/e2e-real-f1.sh tests/helpers/f1-occupant.py tests/test-f1-contract.sh \
  tests/test-first-upgrade-contract.sh tests/test-late-failure-contract.sh tests/test-retire-hop-bc-contract.sh tests/test-retire-hop-contract.sh | LC_ALL=C sort)"
if d1="$(git -C "$ROOT" diff --name-only "$BASE" -- 2>/dev/null)" && d2="$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)"; then
  chg="$(printf '%s\n%s\n' "$d1" "$d2" | grep -v '^$' | LC_ALL=C sort -u)"
  [[ "$chg" == "$EIGHT" ]] && ok "S1 相对 93bb2152 只有登记的八个路径有变化(已跟踪改动 + 未跟踪新文件)" || bad "S1 变化路径不是登记的八个: [$(tr '\n' ' ' <<< "$chg")]"
else bad "S1 未取得: 改动清单取不到(git diff / ls-files 失败) —— 不说成没有登记外改动"; fi
n2=0; why2=""
for rel in tests/e2e-real-first-upgrade.sh tests/e2e-real-bridge-hop.sh tests/e2e-real-retire-hop.sh tests/e2e-real-late-failure.sh tests/e2e-real-platform-fail.sh \
           tests/e2e-real-retire-hop-bc.sh tests/e2e-real-retire-refusal.sh tests/e2e-lib.sh tests/helpers/dns-stub.py tests/repoguard.sh \
           tests/test-bridge-observation-contract.sh tests/test-bridge-extract-contract.sh tests/test-dns-instrument-real.sh tests/test-ci-coverage.py \
           tests/test-platform-startlimit-quiesce.sh; do
  if ! git -C "$ROOT" show "$BASE:$rel" > "$T/base-one" 2>/dev/null; then why2="$why2 $rel(基线取不到)"; continue; fi
  cmp -s -- "$T/base-one" "$ROOT/$rel"; r=$?
  case "$r" in 0) n2=$((n2+1));; 1) why2="$why2 $rel(变了)";; *) why2="$why2 $rel(比较失败 rc=$r)";; esac
done
[[ -z "$why2" && "$n2" == 15 ]] && ok "S2 S-1 验收器、①②③④⑤、B / C2 验收器、共享夹具与相关契约 / 守卫相对 93bb2152 逐字节不变($n2 个)" || bad "S2 共享输入不成立:$why2"
# S3: 按验收器自己的抽法(f1_seed → S-1 s1_lists → ③ r3_bootstrap → ② extract_marked_fns / decls; S-1 块经 f1_seed)两侧各抽一次
mkdir -p "$T/s3/now" "$T/s3/base"
s3ok=1
if blk f1_seed "$F1" > "$T/s3/seed.sh" && blk f1_lists "$F1" > "$T/s3/lists.sh" && bash -n "$T/s3/seed.sh" && bash -n "$T/s3/lists.sh"; then
  cp "$R3" "$T/s3/now/r3.sh"; cp "$HOP2" "$T/s3/now/hop2.sh"; cp "$PLAT" "$T/s3/now/plat.sh"; cp "$S1" "$T/s3/now/s1.sh"
  git -C "$ROOT" show "$BASE:tests/e2e-real-retire-hop.sh" > "$T/s3/base/r3.sh" 2>/dev/null || s3ok=0
  git -C "$ROOT" show "$BASE:tests/e2e-real-bridge-hop.sh" > "$T/s3/base/hop2.sh" 2>/dev/null || s3ok=0
  git -C "$ROOT" show "$BASE:tests/e2e-real-platform-fail.sh" > "$T/s3/base/plat.sh" 2>/dev/null || s3ok=0
  git -C "$ROOT" show "$BASE:tests/e2e-real-first-upgrade.sh" > "$T/s3/base/s1.sh" 2>/dev/null || s3ok=0
  for side in now base; do
    ( set +u
      # shellcheck source=/dev/null
      source "$T/s3/seed.sh"; source "$T/s3/lists.sh"
      D="$T/s3/$side"; E2E_TMP="$D"; export E2E_TMP
      f1_seed s1_lists "$D/s1.sh" > "$D/s1lists.sh" && bash -n "$D/s1lists.sh" || exit 2
      # shellcheck source=/dev/null
      source "$D/s1lists.sh"
      f1_seed r3_bootstrap "$D/r3.sh" > "$D/boot.sh" && bash -n "$D/boot.sh" || exit 2
      # shellcheck source=/dev/null
      source "$D/boot.sh"
      r3_bootstrap "$D/hop2.sh" "$D/extractor.sh" extract_marked_fns extract_marked_decls || exit 2
      # shellcheck source=/dev/null
      source "$D/extractor.sh"
      for n in "${S1_PLAT_FNS[@]}"; do extract_marked_fns "$D/plat.sh" "$D/x-p-$n" "$n" || exit 3; done
      for n in "${S1_PLAT_DECLS[@]}"; do extract_marked_decls "$D/plat.sh" "$D/x-d-$n" "$n" || exit 3; done
      for n in "${S1_HOP2_FNS[@]}"; do extract_marked_fns "$D/hop2.sh" "$D/x-h-$n" "$n" || exit 3; done
      for n in "${S1_R3_BLOCKS[@]}" "${F1_R3_EXTRA[@]}"; do r3_bootstrap "$D/r3.sh" "$D/x-r-$n" "$n" || exit 3; done
      for n in "${F1_S1_FNS[@]}" "$F1_S1_CONST" "$F1_S1_INLINE" s1_lists; do f1_seed "$n" "$D/s1.sh" > "$D/x-s-$n" || exit 3; done
      printf '%s\n' "${S1_PLAT_FNS[@]/#/x-p-}" "${S1_PLAT_DECLS[@]/#/x-d-}" "${S1_HOP2_FNS[@]/#/x-h-}" "${S1_R3_BLOCKS[@]/#/x-r-}" "${F1_R3_EXTRA[@]/#/x-r-}" \
        "${F1_S1_FNS[@]/#/x-s-}" "x-s-$F1_S1_CONST" "x-s-$F1_S1_INLINE" x-s-s1_lists > "$D/names"
      for f in "${F1_FORBID[@]}"; do [[ " ${S1_R3_BLOCKS[*]} ${F1_R3_EXTRA[*]} ${F1_S1_FNS[*]} " != *" $f "* ]] || exit 4; done
    ) > "$T/s3/$side.log" 2>&1 || s3ok=0
  done
  if (( s3ok )) && rdf "$T/s3/now/names" && [[ -n "$RDV" ]]; then
    nn=0; why3=""
    while IFS= read -r x; do
      [[ -s "$T/s3/now/$x" && -s "$T/s3/base/$x" ]] || { why3="$why3 $x(空或没抽到)"; continue; }
      cmp -s "$T/s3/now/$x" "$T/s3/base/$x" && nn=$((nn+1)) || why3="$why3 $x(两侧不同)"
    done <<< "$RDV"
    [[ -z "$why3" ]] && ok "S3 验收器按自己的抽法抽到的 $nn 个共享块 / 函数 / 依赖(含 S-1 的 7 个块), 与 93bb2152 两侧逐名逐字相同且各自非空; 不得调用的函数不在抽取表里" || bad "S3 抽取比对不成立:$why3"
  else bad "S3 抽取没走完(现在一侧: $(tail -1 "$T/s3/now.log" 2>/dev/null); 基线一侧: $(tail -1 "$T/s3/base.log" 2>/dev/null)) —— 共享块比对没做"; fi
else bad "S3 验收器的 f1_seed / f1_lists 抽不到或语法不过"; fi
# S4: 禁用调用与唯一入口(去掉注释行; 不得调用表那一行除外)
CODE_OK=0
if grep -vE '^[[:space:]]*#' "$F1" > "$T/f1code.txt" 2>/dev/null && [[ -s "$T/f1code.txt" ]]; then CODE_OK=1; fi
cq(){ (( CODE_OK == 1 )) || { echo 错; return; }; grep -vE '^F1_FORBID=\(' "$T/f1code.txt" | grep -cE -- "$1"; }
s4(){   # $1=格 $2=说明 $3=ERE $4=应有条数
  local n; n="$(cq "$3")"
  [[ "$n" == "$4" ]] && ok "$1 $2" || bad "$1 $2 —— 实得 [$n] 处(应为 $4)"; }
s4 S4a "不调用 r3_gated_invoke / s1_gated_invoke / s1_after_call / s1_settle / s1_verdict_say / s1_dw_post(去注释代码里 0 处)" \
  '\b(r3_gated_invoke|s1_gated_invoke|s1_after_call|s1_settle|s1_verdict_say|s1_dw_post)\b' 0
s4 S4b "不直接运行产品内部函数 _dw_settle(0 处)" '_dw_settle' 0
s4 S4c "验收器不对 pdg-dotwitness 做 systemctl 动作(reset-failed / start / restart / stop / enable … 0 处)" \
  'systemctl[^#]*\b(reset-failed|start|restart|stop|enable|disable|kill|mask|unmask|reload|try-restart)\b[^#]*pdg-dotwitness' 0
s4 S4d "不定义 systemctl / journalctl / ss / timeout 的包装函数、不改 PATH" '(^[[:space:]]*(systemctl|journalctl|ss|timeout)[[:space:]]*\(\))|(^|[^A-Za-z_])PATH=' 0
s4 S4e "不以命令形式直接调用升级 CLI(只经 r3_invoke)" '(^|[;&|][[:space:]]*)(sudo[[:space:]]+)?(env[^"]*[[:space:]])?(timeout[^"]*[[:space:]])?bash[[:space:]]+"?(\$R3_CLI|/usr/local/bin/pdg)' 0
s4 S4f "唯一调用入口 r3_invoke 在去注释代码里恰 1 处" '\br3_invoke\b' 1
s4 S4g "不覆盖静置参数与超时(R3_Q_* / PDG_RETIRE_HOP_TIMEOUT 0 处赋值)" '(\bR3_Q_[A-Z_]*=|\bPDG_RETIRE_HOP_TIMEOUT=)' 0
s4 S4h "systemctl 的动作只有两处: daemon-reload 一次、start \"\$F1_OCC_UNIT\" 一次" \
  'systemctl[[:space:]]+(daemon-reload|reset-failed|start|restart|stop|enable|disable|kill|mask|unmask|reload|try-restart)\b' 2
s4 S4i "r3_quiesce 在去注释代码里恰 3 处(抽取表、存在核对、唯一调用点)" '\br3_quiesce\b' 3
if (( CODE_OK == 1 )); then
  fin_in="$(awk '/^f1_gated_invoke\(\)\{/{f=1} f && /\<r3_invoke\>/ && !/^[[:space:]]*#/ {print "IN"; exit} f && /^}$/{exit}' "$F1")"
  q_in="$(awk '/^f1_gated_invoke\(\)\{/{f=1} f && $0 == "  if [[ \"$F1_VARIANT\" == a ]]; then r3_quiesce || return 16; fi" {n++} f && /^}$/{exit} END{print n+0}' "$F1")"
  sa="$(grep -cxF '  systemctl start "$F1_OCC_UNIT" >/dev/null 2>&1; rc=$?' "$F1")"; sd="$(grep -cxF '  systemctl daemon-reload >/dev/null 2>&1; rc=$?' "$F1")"
  [[ "$fin_in" == IN ]] && ok "S4j 那一处 r3_invoke 在 f1_gated_invoke 里(门全过之后)" || bad "S4j r3_invoke 不在 f1_gated_invoke 里"
  [[ "$q_in" == 1 ]] && ok "S4k 静置的唯一调用点在 f1_gated_invoke 里, 且只在变体 a 执行(整行逐字)" || bad "S4k 静置调用点不对(f1_gated_invoke 里的登记行 [$q_in] 处)"
  [[ "$sa" == 1 && "$sd" == 1 ]] && ok "S4l 那两处 systemctl 动作就是 start 占用者与 daemon-reload(整行逐字)" || bad "S4l systemctl 动作行不对(start [$sa] / daemon-reload [$sd])"
else bad "S4j–S4l 去注释代码没取得 —— 不判"; fi
# S5 / S6: 照抄原文
python3 - "$F1" "$S1" "$R3" > "$T/s56.txt" 2> "$T/s56.err" <<'PY'
import sys
f1 = open(sys.argv[1], encoding="utf-8").read().split("\n"); s1 = open(sys.argv[2], encoding="utf-8").read().split("\n")
r3 = open(sys.argv[3], encoding="utf-8").read().split("\n")
def mark(lines, n):
    a = [i for i, l in enumerate(lines) if l == "# >>> PDG-EXTRACT-BEGIN " + n]; b = [i for i, l in enumerate(lines) if l == "# <<< PDG-EXTRACT-END " + n]
    return lines[a[0] + 1:b[0]] if len(a) == 1 and len(b) == 1 and b[0] > a[0] + 1 else None
def fn(lines, head):
    k = [i for i, l in enumerate(lines) if l.startswith(head)]
    if len(k) != 1:
        return None
    j = k[0]
    while j < len(lines) and lines[j] != "}":
        j += 1
    return lines[k[0]:j + 1] if j < len(lines) else None
a, b = mark(f1, "f1_seed"), mark(s1, "s1_seed")
fa, fb = (fn(a, "f1_seed(){") if a else None), (fn(b, "s1_seed(){") if b else None)
ok5 = fa is not None and fb is not None and fa == [fb[0].replace("s1_seed(){", "f1_seed(){", 1)] + fb[1:] and len(a) == len(fa) + 1 and a[0].startswith("#")
print(("OK" if ok5 else "BAD") + "\tS5\t" + ("f1_seed 与 S-1 的 s1_seed 同文(%d 行, 只换函数名; 块前恰 1 行注释)" % len(fa) if ok5 else "f1_seed 与 s1_seed 的差不止函数名, 或定位不到"))
m = mark(f1, "f1_post_runtime"); o = fn(r3, "r3_post_runtime(){")
OLD = "  for u in pdg-dotwitness pdg-health.timer; do"; NEW = "  for u in pdg-health.timer; do"
SCD = "# shellcheck disable=SC2043  # 照抄 ③ 的循环, 去掉 pdg-dotwitness 之后只剩一项; 有意保留循环写法, 便于逐行对照原文"
ok6 = m is not None and o is not None and o.count(OLD) == 1 and len(m) == len(o) + 2 and m[0].startswith("#") and m[1] == SCD and \
      m[2:] == [o[0].replace("r3_post_runtime(){", "f1_post_runtime(){", 1)] + [NEW if l == OLD else l for l in o[1:]]
print(("OK" if ok6 else "BAD") + "\tS6\t" + ("f1_post_runtime = ③ r3_post_runtime 原文 %d 行, 只改函数名与 pdg-dotwitness 那一行(块前恰 1 行说明 + 1 行登记的 SC2043 豁免)" % len(o) if ok6 else "f1_post_runtime 与 ③ 原文的差不是登记的两处, 或定位不到"))
print("END")
PY
s56rc=$?
pres "$s56rc" "$T/s56.txt" "$T/s56.err" "S5 / S6 照抄核对" S5 S6
# S7: 受监视服务表 —— 用 ⑤ 的 SVC_WATCH 原文跑本支的 f1_watch
if blk SVC_WATCH "$PLAT" > "$T/sw.sh" && blk f1_watch "$F1" > "$T/fw.sh" && bash -n "$T/sw.sh" && bash -n "$T/fw.sh"; then
  s7="$( set +u
    # shellcheck source=/dev/null
    source "$T/sw.sh"; source "$T/fw.sh"
    f1_watch; r1=$?; echo "R1=$r1 W=${SVC_WATCH[*]}"
    SVC_WATCH=(mosdns mihomo); f1_watch; r2=$?; echo "R2=$r2 W=${SVC_WATCH[*]}"
    SVC_WATCH=(pdg-dotwitness mosdns pdg-dotwitness); f1_watch; r3=$?; echo "R3=$r3 W=${SVC_WATCH[*]}"; echo S7END )"
  if [[ "$s7" == $'R1=0 W=mosdns mihomo pdg-bot pdg-probe81 pdg-health.timer pdg-mitm sing-box pdg-rescue.socket ssh cron\nR2=1 W=mosdns mihomo\nR3=1 W=pdg-dotwitness mosdns pdg-dotwitness\nS7END' ]]; then
    ok "S7 受监视服务 = ⑤ 原表恰去掉 pdg-dotwitness(10 项, 顺序不变); 原表里没有它 / 有两个时返回 1 且不改表"
  else bad "S7 受监视服务表不对: [$(tr '\n' '|' <<< "$s7")]"; fi
else bad "S7 ⑤ 的 SVC_WATCH 或本支的 f1_watch 抽不到"; fi
# S8: 占用者 unit 全文
if blk f1_occ "$F1" > "$T/occ.sh" && bash -n "$T/occ.sh"; then
  s8="$( set +u; EVID=/E; E2E_ROOT=/R; HIJ=/etc/mosdns/rules/mitm_hijack.txt
    # shellcheck source=/dev/null
    source "$T/occ.sh"; f1_occ_text; echo "S8END:$F1_OCC_UNIT:$F1_OCC_FILE" )"
  want8=$'[Unit]\nDescription=F-1 acceptance occupant of 127.0.0.1:5399 (test fixture, not part of the product)\nPartOf=mosdns.service\nBefore=pdg-dotwitness.service\n\n[Service]\nType=notify\nNotifyAccess=main\nTimeoutStartSec=20\nExecStart=/usr/bin/python3 /R/tests/helpers/f1-occupant.py --port 5399 --arm /etc/mosdns/rules/mitm_hijack.txt --log /E/10-f1-occupant.log\nS8END:f1-occupant.service:/run/systemd/system/f1-occupant.service'
  [[ "$s8" == "$want8" ]] && ok "S8 占用者 unit 全文按登记(PartOf=mosdns、Before=pdg-dotwitness、Type=notify、ExecStart 指向检出里的占用者程序; 放在 /run/systemd/system, 名字不带 pdg- 前缀)" \
    || bad "S8 占用者 unit 全文与登记不符: [$(chars 300 <<< "$s8" | tr '\n' '|')]"
else bad "S8 本支的 f1_occ 抽不到"; fi
[[ -x "$F1" && -x "$ME" && -x "$OCC" ]] && ok "S9 验收器、本契约与占用者程序可执行" || bad "S9 验收器、本契约或占用者程序不可执行"
s10=1
for x in 'EVID="${PDG_F1_EVID:-}"' '[[ "$EVID" == /* ]] || _hard' 'F1_VARIANT="${PDG_F1_VARIANT:-}"' '[[ "$F1_VARIANT" == a || "$F1_VARIANT" == b ]] || _hard' \
         'R3_COUNT="$EVID/00-f1-invoke-count.txt"' 'JBOUND_TAG="pdg-e2e-jbound-f1"' 'for _f in "${F1_FORBID[@]}"; do declare -F "$_f" >/dev/null && _hard' \
         'f1_watch || _hard' 'S1_SRC="$E2E_ROOT/tests/e2e-real-first-upgrade.sh"'; do grep -qF -- "$x" "$F1" || { s10=0; bad "S10 验收器里没有「$x」"; }; done
n13="$(grep -vE '^[[:space:]]*#' "$ME" | grep -vF 'S13' | grep -cE '(cut -c|head -c)')"; [[ "$n13" == 0 ]] && ok "S13 本契约的代码里没有按字节截断的 cut -c / head -c(失败说明不会把汉字切成半个)" || bad "S13 本契约的代码里还有 $n13 处 cut -c / head -c"
(( s10 )) && ok "S10 证据目录必须显式绝对路径、变体只认 a / b、计数文件与界桩名是本支自己的、运行时核实不得调用的函数没被抽进来、受监视表改不成就停"
# S12: 从 S-1 抽进来的块里引用、但块内没有赋值的 S1_* 变量, 本支自己必须赋值(否则 set -u 下验收器会在用到它的那一刻退出)
python3 - "$F1" "$S1" > "$T/s12.txt" 2> "$T/s12.err" <<'PY'
import re, sys
f1 = open(sys.argv[1], encoding="utf-8").read(); s1 = open(sys.argv[2], encoding="utf-8").read().split("\n")
def mark(lines, n):
    a = [i for i, l in enumerate(lines) if l == "# >>> PDG-EXTRACT-BEGIN " + n]; b = [i for i, l in enumerate(lines) if l == "# <<< PDG-EXTRACT-END " + n]
    return "\n".join(lines[a[0] + 1:b[0]]) if len(a) == 1 and len(b) == 1 and b[0] > a[0] + 1 else None
m = re.search(r"^F1_S1_FNS=\(([^)]*)\)$", f1, re.M)
names = (m.group(1).split() if m else []) + ["s1_r3_const", "s1_r3_inline"]
txt = [mark(s1, n) for n in names]
if not m or None in txt:
    print("BAD\tS12\t抽取表或 S-1 的块定位不到"); print("END"); sys.exit(0)
code = "\n".join(l for l in "\n".join(txt).split("\n") if not l.lstrip().startswith("#"))
ref = set(re.findall(r"\$\{?(S1_[A-Z0-9_]+)", code))
asg = set(re.findall(r"(?<![\w$])(S1_[A-Z0-9_]+)(?:\[[^\]]*\])?\+?=", code)) | set(re.findall(r"declare -g?A? ?(S1_[A-Z0-9_]+)", code))
for rl in re.findall(r"\bread -r ((?:S1_[A-Z0-9_]+ ?)+)", code):
    asg |= set(rl.split())
free = sorted(ref - asg)
f1code = "\n".join(l for l in f1.split("\n") if not l.lstrip().startswith("#"))
miss = [v for v in free if not re.search(r"(?<![\w$])%s=" % v, f1code)]
print(("OK" if free and not miss else "BAD") + "\tS12\t" + ("S-1 块里块内未赋值的 S1_* 变量 %s 本支都赋了值" % free if free and not miss else "本支没有赋值的: %s(块内未赋值的全集 %s)" % (miss, free)))
print("END")
PY
s12rc=$?
pres "$s12rc" "$T/s12.txt" "$T/s12.err" "S12 未定义变量核对" S12
if (( CODE_OK == 1 )); then
  nm="$(grep -cxE 'f1_after_call' "$T/f1code.txt")"; nd="$(grep -cxE 'f1_after_call\(\)\{' "$T/f1code.txt")"
  [[ "$nm" == 1 && "$nd" == 1 ]] && ok "S11 调用返回后的主流程 f1_after_call 定义一处、顶层调用一处" || bad "S11 f1_after_call 的定义 [$nd] / 调用 [$nm] 不是各一处"
else bad "S11 去注释代码没取得 —— 不判"; fi
fi

# ══ 三. 模型格 ══
echo "══ 三. 模型格(被测原文按标记抽取; 每格一个子壳) ══"
M_OK=1
( for n in f1_occ f1_gated f1_classify f1_post f1_settle; do blk "$n" "$F1" || exit 1; done ) > "$T/f1fns.sh" 2>/dev/null || M_OK=0
( for n in s1_dw s1_report; do blk "$n" "$S1" || exit 1; done ) > "$T/s1fns.sh" 2>/dev/null || M_OK=0
for f in f1fns s1fns; do bash -n "$T/$f.sh" 2>/dev/null && [[ -s "$T/$f.sh" ]] || M_OK=0; done
(( M_OK )) && ok "M0 被测原文抽取成功且非空(F-1 验收器 5 段、S-1 的 s1_dw / s1_report), 语法通过" || { bad "M0 被测原文抽取失败 —— 模型格无从谈起"; fin; }
cat > "$T/stubs.sh" <<'EOF'
ok(){ echo "LIB-OK: $1"; }
bad(){ echo "LIB-BAD: $1"; }
note(){ echo "LIB-NOTE: $1"; }
s1_rec(){ :; }
EOF
# cell 格 说明 脚本 期望...: 期望写法 "has:子串" / "not:子串"; 结束标记缺失、子壳非零 ⇒ 执行无效
cell(){
  local id="$1" desc="$2" body="$3" mk out rc e why=""
  shift 3
  want "$id" || return 0
  mk="CELLEND-$RANDOM$RANDOM$RANDOM"; out="$T/cell-$id.out"
  ( set +u
    # shellcheck source=/dev/null
    source "$T/stubs.sh"; source "$T/s1fns.sh"; source "$T/f1fns.sh"; source "$T/stubs.sh"
    eval "$body"; echo "$mk" ) > "$out" 2> "$T/cell-$id.err"; rc=$?
  if (( rc != 0 )); then nexec=$((nexec+1)); bad "$id 执行无效(子壳退出 $rc: $(chars 160 2>/dev/null < "$T/cell-$id.err" | tr '\n' ' ')) —— $desc"; return; fi
  if ! rdf "$out"; then nres=$((nres+1)); bad "$id 结果读不了 —— $desc"; return; fi
  if [[ "${RDV##*$'\n'}" != "$mk" ]]; then nexec=$((nexec+1)); bad "$id 执行无效(没有走到结束标记) —— $desc"; return; fi
  for e in "$@"; do
    case "$e" in
      has:*) [[ "$RDV" == *"${e#has:}"* ]] || why="$why 缺「${e#has:}」;";;
      not:*) [[ "$RDV" != *"${e#not:}"* ]] || why="$why 不该有「${e#not:}」;";;
      *) why="$why 期望写法不认 [$e];";;
    esac
  done
  if [[ -n "$why" ]]; then nbiz=$((nbiz+1)); bad "$id $desc ——$why(输出: $(grep -v "^$mk\$" "$out" | tail -4 | tr '\n' '|' | chars 300))"; else ok "$id $desc"; fi
}

# ── O: 占用者程序真跑(非特权; 随机高位端口; 自建 NOTIFY_SOCKET) ──
cat > "$T/occrun.py" <<'PY'
import os, socket, subprocess, sys, time
occ, case, d = sys.argv[1], sys.argv[2], sys.argv[3]
def freeport():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
port = freeport()
arm = os.path.join(d, "arm-" + case); log = os.path.join(d, "log-" + case)
if case in ("nonempty", "taken"):
    open(arm, "w").write("gs-loc.apple.com\n")
if case in ("empty", "taken-armed"):
    open(arm, "w").close()
if case == "unreadable":
    os.makedirs(os.path.join(d, "locked"), exist_ok=True)
    arm = os.path.join(d, "locked", "arm"); open(arm, "w").close(); os.chmod(os.path.join(d, "locked"), 0)
if case == "badlog":
    open(arm, "w").close(); log = os.path.join(d, "no-such-dir", "log")
blocker = None
if case == "taken-armed":
    blocker = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); blocker.bind(("127.0.0.1", port))
ns = os.path.join(d, "notify-" + case)
n = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); n.bind(ns); n.settimeout(5)
env = dict(os.environ, NOTIFY_SOCKET=ns)
p = subprocess.Popen([sys.executable, "-I", "-B", occ, "--port", str(port), "--arm", arm, "--log", log], env=env,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
ready = "no"
try:
    msg = n.recv(64); ready = "yes" if msg == b"READY=1" else "other:" + repr(msg)
except socket.timeout:
    ready = "timeout"
time.sleep(0.2)
alive = p.poll() is None
held_by_occ = "na"
if blocker is None:
    t = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        t.bind(("127.0.0.1", port)); held_by_occ = "no"
    except OSError as e:
        held_by_occ = "yes" if e.errno == 98 else "err%d" % e.errno
    t.close()
if alive:
    p.terminate()
try:
    p.wait(5)
except subprocess.TimeoutExpired:
    p.kill(); p.wait()
if case == "unreadable":
    os.chmod(os.path.join(d, "locked"), 0o700)
try:
    lines = open(log).read().split("\n")
except OSError:
    lines = ["<nolog>"]
print("READY=%s" % ready); print("ALIVE=%s" % ("yes" if alive else "no")); print("RC=%s" % ("-" if alive else p.returncode))
print("HELD_BY_OCC=%s" % held_by_occ)
for l in lines:
    if l:
        print("LOG=" + l)
PY
occ_cell(){   # $1=格 $2=情形 $3=说明 $4..=期望
  local id="$1" case="$2" desc="$3"; shift 3
  cell "$id" "$desc" "python3 -I -B \"$T/occrun.py\" \"$OCC\" $case \"$T\"; F1_OCC_LOG=\"$T/log-$case\"; f1_occ_log; echo \"PARSE=\$? \$(f1_occ_say)\"" "$@"
}
occ_cell O1 nonempty "接管表非空 ⇒ 不绑端口、记 idle、照常报 READY、一直活着" has:READY=yes has:ALIVE=yes has:HELD_BY_OCC=no has:"PARSE=0 idle 1 / held 0 / hold-failed 0 / arm-unreadable 0"
occ_cell O2 empty "接管表存在且为空 ⇒ 先绑 UDP 127.0.0.1:端口(另一个进程再绑报 EADDRINUSE)、记 held、再报 READY" has:READY=yes has:ALIVE=yes has:HELD_BY_OCC=yes has:"PARSE=0 idle 0 / held 1 / hold-failed 0 / arm-unreadable 0"
occ_cell O3 missing "接管表不存在 ⇒ 当作非空: 不绑、记 idle(不存在不等于空)" has:READY=yes has:HELD_BY_OCC=no has:"PARSE=0 idle 1 / held 0"
occ_cell O4 taken-armed "已激活但端口被别人占着 ⇒ 记 hold-failed errno=98、照常报 READY、不退出" has:READY=yes has:ALIVE=yes has:"hold-failed errno=98" has:"PARSE=0 idle 0 / held 0 / hold-failed 1 / arm-unreadable 0"
occ_cell O5 unreadable "接管表 stat 不了(EACCES)⇒ 记 arm-unreadable errno=13、不绑、照常报 READY" has:READY=yes has:HELD_BY_OCC=no has:"arm-unreadable errno=13" has:"PARSE=0 idle 0 / held 0 / hold-failed 0 / arm-unreadable 1"
occ_cell O6 badlog "记录写不进 ⇒ 非零退出、不报 READY(本次启动失败, 由验收器看见)" has:READY=timeout has:ALIVE=no not:RC=0 has:LOG=\<nolog\>

# ── P: 占用者记录解析(f1_occ_log) ──
pcell(){ local id="$1" desc="$2" content="$3"; shift 3
  printf '%s' "$content" > "$T/plog-$id"
  cell "$id" "$desc" "F1_OCC_LOG=\"$T/plog-$id\"; f1_occ_log; echo \"PARSE=\$? \$(f1_occ_say) H1=\$F1_OCC_HELD1 PID=\$F1_OCC_HELD_PID\"" "$@"; }
pcell P1 "一条 idle ⇒ 计数 1/0/0/0" $'1000 idle pid=7\n' has:"PARSE=0 idle 1 / held 0 / hold-failed 0 / arm-unreadable 0 H1= PID="
pcell P2 "idle + 两次 held ⇒ held 2, 第一次 held 的纳秒与 pid 取第一条" $'1000 idle pid=7\n2000 held pid=8\n3000 held pid=9\n' has:"PARSE=0 idle 1 / held 2 / hold-failed 0 / arm-unreadable 0 H1=2000 PID=8"
pcell P3 "有不认的行 ⇒ 观测无效(rc 2), 不按部分计数" $'1000 idle pid=7\n2000 grabbed pid=8\n' has:"PARSE=2"
pcell P4 "有空行 ⇒ 观测无效" $'1000 idle pid=7\n\n2000 held pid=8\n' has:"PARSE=2"
cell P5 "记录文件不存在 ⇒ 观测无效" "F1_OCC_LOG=\"$T/no-such-log\"; f1_occ_log; echo \"PARSE=\$?\"" has:"PARSE=2"
pcell P6 "单调时间为 0 开头 ⇒ 不认(观测无效)" $'0123 idle pid=7\n' has:"PARSE=2"

# ── G: 门与唯一调用的先后(门函数替身记账; 其余用原文) ──
GSTUB='CALLS=""; gs(){ CALLS="$CALLS $1"; }
r3_real2_gate(){ gs real2; R3_WHY=ok; return ${G_REAL2:-0}; }
r3_bridge_identity_gate(){ gs bridge; return ${G_BRIDGE:-0}; }
r3_dns_instrument(){ gs dns; return ${G_DNS:-0}; }
f1_occ_install(){ gs occ_install; return ${G_OCCI:-0}; }
r3_quiesce(){ gs quiesce; return ${G_Q:-0}; }
r3_runtime_gate(){ gs runtime; return ${G_RT:-0}; }
s1_dw_precall(){ gs precall; return ${G_PRE:-0}; }
f1_occ_check(){ gs occ_check; return ${G_OCCC:-0}; }
r3_precapture(){ gs precapture; return ${G_CAP:-0}; }
r3_count_read(){ gs count; R3_VAL="${G_CNT:-0}"; return 0; }
s1_mono(){ gs mono; echo 123; }
r3_invoke(){ gs invoke; return 0; }'
gcell(){ local id="$1" desc="$2" pre="$3"; shift 3
  cell "$id" "$desc" "$GSTUB; $pre; f1_gated_invoke; echo \"RC=\$? CALLS=\$CALLS\"" "$@"; }
gcell G1 "变体 a 门全过 ⇒ 依次 ②、身份、DNS、装占用者、静置、运行态、dotwitness 调用前、占用者调用前、调用前观测、计数, 然后恰一次调用(时钟在命令替换里读, 不进记账)" 'F1_VARIANT=a' \
  has:"RC=0 CALLS= real2 bridge dns occ_install quiesce runtime precall occ_check precapture count invoke"
gcell G2 "变体 b 门全过 ⇒ 同上但没有静置" 'F1_VARIANT=b' has:"RC=0 CALLS= real2 bridge dns occ_install runtime precall occ_check precapture count invoke"
gcell G3 "占用者装出门不成立 ⇒ 18, 之后的门与调用都不发生" 'F1_VARIANT=a; G_OCCI=1' has:"RC=18 CALLS= real2 bridge dns occ_install" not:invoke
gcell G4 "变体 a 静置不成立 ⇒ 16, 不调用" 'F1_VARIANT=a; G_Q=1' has:"RC=16 CALLS= real2 bridge dns occ_install quiesce" not:invoke
gcell G5 "占用者调用前门不成立 ⇒ 19, 不调用" 'F1_VARIANT=b; G_OCCC=1' has:"RC=19 " not:invoke
gcell G6 "计数已是 1 ⇒ 14, 不调用(只许一次)" 'F1_VARIANT=b; G_CNT=1' has:"RC=14 " not:invoke
gcell G7 "dotwitness 调用前门不成立 ⇒ 17, 占用者调用前门与调用都不发生" 'F1_VARIANT=a; G_PRE=1' has:"RC=17 " not:occ_check not:invoke
gcell G8 "DNS 仪器不成立 ⇒ 15, 占用者都没装" 'F1_VARIANT=a; G_DNS=1' has:"RC=15 CALLS= real2 bridge dns" not:occ_install

# ── R: 新步骤报告(S-1 的 s1_report 原文归类 + 本支细分); 句式取自候选 deploy/bot/pdg.sh 6402–6430 的原文 ──
Y=$'\033[1;33m'; G=$'\033[1;32m'; Z=$'\033[0m'
H6430="${Y}  ⚠️  DoT 证据端: 未就绪(ActiveState=activating, SubState=auto-restart, Result=exit-code), 本步不重置、不启动。查看 journalctl -u pdg-dotwitness。${Z}"
H6407D="${Y}  ⚠️  DoT 证据端: 未就绪(观察期内没能确认就绪; 最后一次观察 ActiveState=activating, SubState=auto-restart, Result=exit-code, LoadState=loaded, UnitFileState=enabled), 本步不重置、不启动。查看 journalctl -u pdg-dotwitness。${Z}"
H6407O="${Y}  ⚠️  DoT 证据端: 未就绪(观察期内没能确认就绪; 10 次观察里没有连续两次成立), 本步不重置、不启动。查看 journalctl -u pdg-dotwitness。${Z}"
H6405="${Y}  ⚠️  DoT 证据端: 服务 active, 但 127.0.0.1:5399 由别的进程持有(unit: /system.slice/pdg-dotwitness.service; 监听者: 1234:/system.slice/f1-occupant.service 5678:/system.slice/x.service); 本步不处理。${Z}"
H6425="${Y}  ⚠️  DoT 证据端: 观察到启动限额命中(Result=start-limit-hit, NRestarts=0); 已做一次定向恢复(reset-failed 退出 0, start 退出 0), 但恢复后确认未就绪(最后一次观察 ActiveState=activating, SubState=auto-restart, Result=exit-code, LoadState=loaded, UnitFileState=enabled); 不再重试。查看 journalctl -u pdg-dotwitness。${Z}"
H6421="${G}  DoT 证据端: 观察到启动限额命中(Result=start-limit-hit, NRestarts=0); 已做一次定向恢复(reset-failed 退出 0, start 退出 0), 恢复后运行中, 127.0.0.1:5399 由 pdg-dotwitness 持有 —— 本次核验已恢复。${Z}"
H6404="${Y}  ⚠️  DoT 证据端: 服务 active, 但 127.0.0.1:5399 没有监听; 本步不处理。${Z}"
rcell(){ local id="$1" desc="$2" lines="$3"; shift 3
  printf '刷新代码…\n%s\n✅ 已更新。\n' "$lines" > "$T/rlog-$id"
  cell "$id" "$desc" "s1_report \"$T/rlog-$id\" \"$T/rrep-$id\"; echo \"REP=\$? CLASS=\$S1_REP\"; f1_rep_form \"$T/rrep-$id\"; echo \"FORM_RC=\$? FORM=\$F1_FORM ACT=\$F1_R_ACT SUB=\$F1_R_SUB RES=\$F1_R_RES PIDS=[\$F1_R_PIDS]\"" "$@"; }
rcell R1 "6430 句式 ⇒ NOTREADY / N6430, 取出 ActiveState / SubState / Result" "$H6430" has:"REP=0 CLASS=NOTREADY" has:"FORM_RC=0 FORM=N6430 ACT=activating SUB=auto-restart RES=exit-code PIDS=[]"
rcell R2 "6407 句式(最后一类 down)⇒ N6407, 从最后一次观察里取出状态" "$H6407D" has:"CLASS=NOTREADY" has:"FORM=N6407 ACT=activating SUB=auto-restart RES=exit-code"
rcell R3 "6407 句式(没有连续两次成立)⇒ N6407, 没有状态字段" "$H6407O" has:"CLASS=NOTREADY" has:"FORM=N6407 ACT= SUB= RES= PIDS=[]"
rcell R4 "6405 句式 ⇒ FOREIGN, 取出全部监听者 pid" "$H6405" has:"CLASS=FOREIGN" has:"FORM=FOREIGN" has:"PIDS=[1234 5678]"
rcell R5 "6425 句式 ⇒ SLH_POST_NOTREADY / SLHNR, 从恢复后的最后一次观察里取出状态" "$H6425" has:"CLASS=SLH_POST_NOTREADY" has:"FORM=SLHNR ACT=activating SUB=auto-restart RES=exit-code"
rcell R6 "6421 句式 ⇒ RECOVERED(不是 F-1 的目标)" "$H6421" has:"CLASS=RECOVERED" has:"FORM=RECOVERED"
rcell R7 "两条不同的报告 ⇒ CONFLICT(不采信任何一条)" "$H6430"$'\n'"$H6405" has:"CLASS=CONFLICT" has:"FORM=CONFLICT"
rcell R8 "6404 句式 ⇒ NOLISTEN" "$H6404" has:"CLASS=NOLISTEN" has:"FORM=NOLISTEN"
printf 'N=1\nNR=\nCHAIN=ok\n' > "$T/rrep-bad"
cell R9 "归类留证里没有 CLASS 行 ⇒ 细分观测无效(rc 2)" "f1_rep_form \"$T/rrep-bad\"; echo \"FORM_RC=\$?\"" has:"FORM_RC=2"

# ── J: 窗口启动来源推定(f1_jclass; TSV 列同 s1_jwin: 序号 游标 单调 归属 unit pid INV 进程INV 类别 消息) ──
jrow(){ printf '%s\tc%s\t%s\ttarget\tpdg-dotwitness.service\t%s\t-\t-\t%s\t%s\n' "$1" "$1" "$2" "$3" "$4" "$5"; }
jtsv(){ local f="$1"; shift; : > "$f"; local i=0 e; for e in "$@"; do i=$((i+1)); IFS='|' read -r m p k msg <<< "$e"; jrow "$i" "$m" "$p" "$k" "$msg" >> "$f"; done; }
BF='dotwitness: bind failed (OSError)'; FX="pdg-dotwitness.service: Failed with result 'exit-code'."; ME_="pdg-dotwitness.service: Main process exited, code=exited, status=4/NOPERMISSION"
SR='pdg-dotwitness.service: Scheduled restart job, restart counter is at 1.'
jtsv "$T/j1.tsv" "100|1|stopping|Stopping pdg-dotwitness.service - X..." "101|1|stopped|Stopped pdg-dotwitness.service - X." "200|1|start|Started pdg-dotwitness.service - X." \
  "250|900|other|$BF" "260|1|main_exit|$ME_" "261|1|fail_result|$FX" "2300|1|sched_restart|$SR" "2301|1|stopped|Stopped pdg-dotwitness.service - X." \
  "2302|1|start|Started pdg-dotwitness.service - X." "2350|901|other|$BF" "2360|1|main_exit|$ME_" "2361|1|fail_result|$FX"
jcell(){ local id="$1" desc="$2" tsv="$3" held="$4"; shift 4
  cell "$id" "$desc" "f1_jclass \"$tsv\" \"$held\"; echo \"JRC=\$? S=\$F1_J_START A=\$F1_J_AUTO J=\$F1_J_JOBR E=\$F1_J_EXPL U=\$F1_J_UNK EAS=\$F1_J_EXPL_AFTER_SLH SLH=\$F1_J_SLH BF=\$F1_J_BF FAE=\$F1_J_FAIL_AFTER_EXPL BAH=\$F1_J_BF_AFTER_HELD FR=\$F1_J_FAILRES\"" "$@"; }
jcell J1 "变体 a 的形态: 传播来的重启 → 绑不上 → 自动重启 → 绑不上 ⇒ 重启任务 1、自动 1、显式 0; bind failed 2 条且晚于 held" "$T/j1.tsv" 150000 \
  has:"JRC=0 S=2 A=1 J=1 E=0 U=0 EAS=0 SLH=0 BF=2 FAE=0 BAH=yes FR=exit-code"
jtsv "$T/j2.tsv" "100|1|stopping|Stopping pdg-dotwitness.service - X..." "101|1|stopped|Stopped pdg-dotwitness.service - X." \
  "102|1|slh_repeat|pdg-dotwitness.service: Start request repeated too quickly." "103|1|slh_result|pdg-dotwitness.service: Failed with result 'start-limit-hit'." \
  "104|1|fail_start|Failed to start pdg-dotwitness.service - X." "1100|1|starting|Starting pdg-dotwitness.service - X..." "1101|1|start|Started pdg-dotwitness.service - X." \
  "1150|902|other|$BF" "1160|1|main_exit|$ME_" "1161|1|fail_result|$FX" "3200|1|sched_restart|$SR" "3201|1|stopped|Stopped pdg-dotwitness.service - X." "3202|1|start|Started pdg-dotwitness.service - X."
jcell J2 "变体 b 的形态: 限额命中 → 显式启动一次 → 绑不上 → 自动重启 ⇒ 显式 1 且在限额命中之后、其后有失败结果" "$T/j2.tsv" 50000 \
  has:"JRC=0 S=2 A=1 J=0 E=1 U=0 EAS=1 SLH=2 BF=1 FAE=1 BAH=yes FR=exit-code"
jtsv "$T/j3.tsv" "100|1|stopping|Stopping pdg-dotwitness.service - X..." "101|1|stopped|Stopped pdg-dotwitness.service - X." "102|1|start|Started pdg-dotwitness.service - X." \
  "150|900|other|$BF" "160|1|main_exit|$ME_" "161|1|fail_result|$FX" "500|1|start|Started pdg-dotwitness.service - X."
jcell J3 "失败之后紧接着一次启动(没有 Scheduled restart / Stopped)⇒ 推定为显式启动" "$T/j3.tsv" 50000 has:"JRC=0 S=2 A=0 J=1 E=1 U=0"
jtsv "$T/j4.tsv" "100|1|start|Started pdg-dotwitness.service - X." "150|900|other|$BF"
jcell J4 "窗口里第一条目标事件就是启动 ⇒ 归不了类(U=1), 不当成任何一种" "$T/j4.tsv" 50000 has:"JRC=0 S=1 A=0 J=0 E=0 U=1"
jcell J5 "第一条 bind failed 不晚于占用者第一次 held ⇒ BAH=no" "$T/j1.tsv" 300000 has:"BAH=no"
jcell J6 "占用者 held 时刻取不到 ⇒ BAH=na(不当成成立)" "$T/j1.tsv" "" has:"BAH=na"
printf '1\tc1\t100\ttarget\tpdg-dotwitness.service\t1\t-\t-\tstart\n' > "$T/j7.tsv"
jcell J7 "TSV 行不是 10 列 ⇒ 观测无效(rc 2)" "$T/j7.tsv" 50000 has:"JRC=2"
{ cat "$T/j1.tsv"; printf '99\tc99\t2400\tother\tmosdns.service\t1\t-\t-\tstart\tStarted mosdns.service - M.\n'; } > "$T/j8.tsv"
jcell J8 "归属别的 unit 的记录不计入(计数与 J1 相同)" "$T/j8.tsv" 150000 has:"JRC=0 S=2 A=1 J=1 E=0 U=0"
jtsv "$T/j9.tsv" "100|1|stopping|Stopping pdg-dotwitness.service - X..." "101|1|stopped|Stopped pdg-dotwitness.service - X." "102|1|start|Started pdg-dotwitness.service - X." \
  "160|1|main_exit|$ME_" "161|1|fail_result|$FX" "2300|1|sched_restart|$SR" "2302|1|start|Started pdg-dotwitness.service - X." \
  "2360|1|main_exit|$ME_" "2361|1|fail_result|$FX" "2400|1|stopped|Stopped pdg-dotwitness.service - X." "2401|1|start|Started pdg-dotwitness.service - X."
jcell J9 "Scheduled restart 紧挨启动 ⇒ 自动; 失败之后 Stopped → 启动 ⇒ 重启任务(对已失败 unit 的传播重启)" "$T/j9.tsv" 50000 has:"JRC=0 S=3 A=1 J=2 E=0 U=0"
cell J10 "bind failed 那条的单调时间不是数 ⇒ 观测无效" "jrow 1 abc 900 other '$BF' > \"$T/j10b.tsv\"; f1_jclass \"$T/j10b.tsv\" 1; echo \"JRC=\$?\"" has:"JRC=2"

# ── L: 分层结算(f1_settle + f1_verdict_say; 输入按登记逐格给定) ──
LBASE='F1_G=0; F1_GATE_NAME=""; F1_CNT=1; F1_UPG=OK; F1_UPG_CORE_N=0; F1_UPG_RT_N=0
F1_OCCL=OK; F1_OCC_N_IDLE=1; F1_OCC_N_HELD=1; F1_OCC_N_HF=0; F1_OCC_N_AU=0; F1_OCC_HELD1=150000000; F1_OCC_HELD_PID=1234
F1_WIN=OK; F1_J=OK; F1_7B=0; F1_RF=OK; F1_POST=DOWN; F1_POST_WHY="failed / failed"
F1_J_START=2; F1_J_AUTO=1; F1_J_JOBR=1; F1_J_EXPL=0; F1_J_UNK=0; F1_J_EXPL_AFTER_SLH=0; F1_J_SLH=0; F1_J_BF=2; F1_J_FAIL_AFTER_EXPL=0
F1_J_BF_AFTER_HELD=yes; F1_J_FAILRES=exit-code'
LA="$LBASE; F1_VARIANT=a; S1_REP=NOTREADY; S1_REP_N=1; F1_FORM=N6430; F1_R_ACT=activating; F1_R_SUB=auto-restart; F1_R_RES=exit-code; F1_R_PIDS="
LB="$LBASE; F1_VARIANT=b; S1_REP=SLH_POST_NOTREADY; S1_REP_N=1; F1_FORM=SLHNR; F1_R_ACT=activating; F1_R_SUB=auto-restart; F1_R_RES=exit-code; F1_R_PIDS=; F1_J_EXPL=1; F1_J_EXPL_AFTER_SLH=1; F1_J_SLH=2; F1_J_FAIL_AFTER_EXPL=1; F1_J_JOBR=0"
lcell(){ local id="$1" desc="$2" pre="$3"; shift 3
  cell "$id" "$desc" "$pre; f1_settle; f1_verdict_say; echo \"VERDICT=\$F1_VERDICT\"" "$@"; }
lcell L1 "a: 6430 句式、显式启动 0、Result 在窗口里出现过 ⇒ PASS" "$LA" has:VERDICT=PASS has:"LIB-OK: F1 结论: 目标分支证据取得" has:"层6 政策: 守政策"
lcell L2 "a: FOREIGN 句式且报告的监听者含占用者 pid ⇒ PASS" "$LA; S1_REP=FOREIGN; F1_FORM=FOREIGN; F1_R_PIDS='1234 99'; F1_R_RES=" has:VERDICT=PASS has:"含占用者 held 记录的 pid 1234"
lcell L3 "a: 报告进了限额恢复分支(SLHNR)⇒ UNCOVERED(目标分支未覆盖)" "$LA; S1_REP=SLH_POST_NOTREADY; F1_FORM=SLHNR" has:VERDICT=UNCOVERED has:"LIB-BAD: F1 结论: 未覆盖" has:"层6 政策: 不判"
lcell L4 "a: 命中目标但 journal 推定的显式启动 1 次 ⇒ POLICY_VIOLATION" "$LA; F1_J_EXPL=1" has:VERDICT=POLICY_VIOLATION has:"LIB-BAD: F1 结论: 违反政策"
lcell L5 "a: 占用者一次也没占住 ⇒ UNOBTAINED(构造不成立)" "$LA; F1_OCC_N_HELD=0" has:VERDICT=UNOBTAINED has:"构造不成立" has:"一次也没有占住"
lcell L6 "a: 第一条 bind failed 不晚于 held ⇒ UNOBTAINED" "$LA; F1_J_BF_AFTER_HELD=no" has:VERDICT=UNOBTAINED has:"不晚于占用者第一次 held"
lcell L7 "a: 升级日志里有 ⑦b 回滚句 ⇒ 构造不成立(先于分支层; 升级层成立时)" "$LA; F1_7B=1" has:VERDICT=UNOBTAINED has:"⑦b"
lcell L8 "a: 调用返回后 pdg-dotwitness 健康 ⇒ UNOBTAINED(构造在返回后失效)" "$LA; F1_POST=HEALTHY" has:VERDICT=UNOBTAINED has:"构造在调用返回后已失效"
lcell L9 "a: 报告 Result 在窗口失败结果里没出现过 ⇒ UNOBTAINED(报告与当刻状态对不上)" "$LA; F1_R_RES=signal" has:VERDICT=UNOBTAINED has:"对不上"
lcell L10 "a: 有归不了类的启动事件 ⇒ UNOBTAINED(政策层未取得)" "$LA; F1_J_UNK=1" has:VERDICT=UNOBTAINED has:"归不了类"
lcell L11 "b: SLHNR、显式启动恰 1 次且在限额命中之后、其后有失败 ⇒ PASS" "$LB" has:VERDICT=PASS has:"守政策(报告自述 reset-failed 与 start 各一次"
lcell L12 "b: 报告是 6430(没有命中限额)⇒ UNCOVERED" "$LB; S1_REP=NOTREADY; F1_FORM=N6430" has:VERDICT=UNCOVERED
lcell L13 "b: 显式启动 2 次 ⇒ POLICY_VIOLATION" "$LB; F1_J_EXPL=2; F1_J_EXPL_AFTER_SLH=2" has:VERDICT=POLICY_VIOLATION has:"多于新步骤允许的 1 次"
lcell L14 "b: 报告说启动过, journal 推定的显式启动 0 次 ⇒ UNOBTAINED" "$LB; F1_J_EXPL=0; F1_J_EXPL_AFTER_SLH=0" has:VERDICT=UNOBTAINED has:"报告自述执行过 start"
lcell L15 "门 18 不成立 ⇒ PRECOND, 写明门名, 层3–8 未执行" "$LA; F1_G=18; F1_GATE_NAME=占用者装出门; F1_CNT=0" has:VERDICT=PRECOND has:"门 18: 占用者装出门" has:"层3–8: 未执行"
lcell L16 "门全过但调用次数不是 1 ⇒ UNOBTAINED" "$LA; F1_CNT=2" has:VERDICT=UNOBTAINED has:"调用次数 2"
lcell L17 "升级层不成立 ⇒ UPGRADE_FAILED(先于构造与分支)" "$LA; F1_UPG=FAIL; F1_OCC_N_HELD=0" has:VERDICT=UPGRADE_FAILED has:"LIB-BAD: F1 结论: 升级失败"
lcell L18 "升级层未取得 ⇒ UNOBTAINED" "$LA; F1_UPG=UNKNOWN" has:VERDICT=UNOBTAINED has:"升级层未取得"
lcell L19 "a: FOREIGN 但监听者里没有占用者 pid ⇒ UNOBTAINED(对不上)" "$LA; S1_REP=FOREIGN; F1_FORM=FOREIGN; F1_R_PIDS='77 88'" has:VERDICT=UNOBTAINED has:"对不上"
lcell L20 "a: NOLISTEN 句式 ⇒ PASS(没有可对照字段, 只记录)" "$LA; S1_REP=NOLISTEN; F1_FORM=NOLISTEN; F1_R_RES=" has:VERDICT=PASS has:"可对照的字段没有"
lcell L21 "报告 CONFLICT ⇒ UNOBTAINED(报告不采信)" "$LA; S1_REP=CONFLICT; F1_FORM=CONFLICT" has:VERDICT=UNOBTAINED has:"报告类别 CONFLICT"
lcell L22 "报告句式细分失败 ⇒ UNOBTAINED" "$LA; F1_RF=BAD; F1_RF_WHY=测试" has:VERDICT=UNOBTAINED has:"报告句式细分: 测试"
lcell L23 "a: 6407 句式但没有状态字段 ⇒ UNOBTAINED(对照无从谈起)" "$LA; F1_FORM=N6407; F1_R_ACT=; F1_R_SUB=; F1_R_RES=" has:VERDICT=UNOBTAINED has:"没带 Result 字段"
lcell L24 "a: 6430 但 ActiveState=active ⇒ UNOBTAINED(对不上: 6430 只在非 active 时出现)" "$LA; F1_R_ACT=active" has:VERDICT=UNOBTAINED has:"对不上"
lcell L25 "占用者记录读不了 ⇒ UNOBTAINED(构造未取得)" "$LA; F1_OCCL=BAD; F1_OCC_WHY=测试" has:VERDICT=UNOBTAINED has:"占用者记录: 测试"
lcell L26 "a: 占用者有 hold-failed 记录 ⇒ UNOBTAINED(构造不成立)" "$LA; F1_OCC_N_HF=1" has:VERDICT=UNOBTAINED has:"绑不上 / 判不了"

# ── D: 返回后读数(f1_dw_post; s1_dw_show / s1_listen_owner / ss 换成替身) ──
DSTUB='EVID="$T"; s1_dw_show(){ [[ "${D_SHOW:-ok}" == ok ]] || { S1_WHY=替身; return 2; }; declare -gA S1_DW=([LoadState]=loaded [UnitFileState]=enabled [ActiveState]="${D_ACT:-failed}" [SubState]="${D_SUB:-failed}" [Result]=exit-code [NRestarts]=4); }
s1_dw_line(){ echo line; }
s1_listen_owner(){ S1_LISTEN="${D_OWN_LISTEN:-}"; S1_WHY="${D_OWN_WHY:-}"; return "${D_OWN_RC:-0}"; }
ss(){ [[ "${D_SS:-ok}" == ok ]] || return 1; printf "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\nUNCONN 0 0 127.0.0.1:5399 0.0.0.0:* users:((\"python3\",pid=%s,fd=3))\n" "${D_PID:-1234}"; }'
dcell(){ local id="$1" desc="$2" pre="$3"; shift 3
  cell "$id" "$desc" "$DSTUB; $pre; f1_dw_post; echo \"POST=\$F1_POST OCC=\$F1_POST_OCC LP=[\$F1_LPIDS]\"" "$@"; }
dcell D1 "pdg-dotwitness failed、5399 由占用者持有 ⇒ DOWN, 占用者在监听者里" 'F1_OCC_HELD_PID=1234' has:"POST=DOWN OCC=yes LP=[1234]"
dcell D2 "active / running 且 5399 监听者都在它的 cgroup ⇒ HEALTHY" 'F1_OCC_HELD_PID=1234; D_ACT=active; D_SUB=running; D_PID=4321; D_OWN_RC=0' has:"POST=HEALTHY OCC=no"
dcell D3 "ss 失败 ⇒ UNOBT(不判健康与否)" 'F1_OCC_HELD_PID=1234; D_SS=bad' has:"POST=UNOBT"
dcell D4 "读数观测无效 ⇒ UNOBT" 'F1_OCC_HELD_PID=1234; D_SHOW=bad' has:"POST=UNOBT"
dcell D5 "active / running 但监听者不在它的 cgroup ⇒ DOWN" 'F1_OCC_HELD_PID=1234; D_ACT=active; D_SUB=running; D_OWN_RC=1; D_OWN_WHY=不在' has:"POST=DOWN OCC=yes"

fin

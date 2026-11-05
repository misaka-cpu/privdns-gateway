#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pdg kernel(内核跟随上游)的编排: 真的 _kernel_* / _core_swap_verify / _update_core_binary,
# 真的 kernelfollow.py 判定, 真的钉死版 mihomo(tests/.bin/mihomo)做配置校验。
#
# 打桩的只有三样外部世界, 都在测试这一侧, 生产代码里没有任何测试开关:
#   · 取件: curl 桩从本地目录喂文件(喂的是**真** mihomo 重新 gzip 的下载物);
#   · 上游 API / 换核体检 / Telegram: kernelfollow.py 换成一个薄壳, 载入真模块后只替换
#     _http_get、health、notify 三个函数(分别读夹具文件 / 按序列返回体检结果 / 记日志);
#   · systemd: systemctl 桩(与 test-mihomo-real-swap.sh 同一套)。
#
# 断言的是落盘结果, 不是输出文案: 内核文件的摘要、本机记录的字段、通知日志、取件次数。
# 每一格先确认夹具真的执行过(函数抽得到、shim 真被调用), 再谈"没动"。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdg-kfcli.XXXXXX")"
[[ -n "${PDG_KEEP_TMP:-}" ]] || trap 'rm -rf "$WORK"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
finish(){ echo "通过 $pass, 失败 $nfail"; [[ "$nfail" == 0 ]]; exit $?; }
# shellcheck source=lib/versions.sh
source "$ROOT/lib/versions.sh"

REAL="${PDG_TEST_MIHOMO:-$ROOT/tests/.bin/mihomo}"
if [[ ! -x "$REAL" ]]; then
  if [[ -n "${PDG_TEST_STRICT:-}${CI:-}" ]]; then
    bad "拿不到钉死版 mihomo —— 严格模式下这是失败, 不是跳过。备一份: bash tests/prepare-mihomo.sh"; finish
  fi
  echo "[SKIP] 没有钉死版 mihomo(bash tests/prepare-mihomo.sh 可备好) —— 这是未验, 不是通过"; exit 0
fi
MARCH=amd64
[[ "$(dpkg --print-architecture 2>/dev/null || echo amd64)" == amd64 ]] \
  || { echo "[SKIP] 本支只在 amd64 上跑(夹具用的是 amd64 真内核)"; exit 0; }
PIN="$MIHOMO_VER"; PIN_BIN="${PDG_SHA256[mihomo-bin-$MARCH]:-}"
[[ "$(sha256sum "$REAL" | cut -d' ' -f1)" == "$PIN_BIN" ]] \
  && ok "前提: tests/.bin/mihomo 就是钉死版 $PIN" \
  || { bad "tests/.bin/mihomo 与钉值不符 —— 夹具不可信"; finish; }

# ── 抽取生产函数 ──────────────────────────────────────────────────────────────
# 单行函数(`f(){ …; }`)只取那一行: 按 /^f(){/,/^}/ 取会读穿到下一个函数的结尾, 把别的函数一起带进来。
xt(){
  awk -v f="$1(){" '
    index($0, f) == 1 { print; if ($0 ~ /; *}[[:space:]]*$/) exit; on = 1; next }
    on { print; if ($0 ~ /^}/) exit }' "$ROOT/deploy/bot/pdg.sh"
}
FNS=(_core_bindir _pdg_sha _core_stash_kernel _core_restore_prev _core_kernel_stable _core_restart_clean
     _core_listeners _core_swap_verify _pdg_mktemp_dir _core_dl_reason _update_core_binary _pdg_module
     _kf _kernel_arch _kernel_installed _kernel_install _kernel_note _kernel_exit_notify _kernel_host _kernel_upgrade
     _kernel_revert _kernel_tick _kernel_status cmd_kernel)
: > "$WORK/h.sh"
miss=""
for f in "${FNS[@]}"; do
  body="$(xt "$f")"
  [[ -n "$body" ]] || miss="$miss $f"
  printf '%s\n' "$body" >> "$WORK/h.sh"
done
[[ -z "$miss" ]] && ok "生产函数全部抽到(${#FNS[@]} 个)" || bad "抽不到:$miss"
BIN="$WORK/bin"; CFG="$WORK/etc-mihomo"; ETC="$WORK/etc"; SRV="$WORK/serve"
mkdir -p "$BIN" "$CFG" "$ETC" "$SRV" "$WORK/repo/lib" "$WORK/repo/deploy/bot"
{
  grep -E '^PDG_CORE_(CONNECT_TIMEOUT|MAX_TIME)=' "$ROOT/deploy/bot/pdg.sh"
  grep -E '^KF_[A-Z]+=' "$ROOT/deploy/bot/pdg.sh"      # 全局状态行原样取自生产文件
  echo 'c_g(){ echo "$*"; }; c_y(){ echo "$*"; }; sleep(){ :; }; need_root(){ :; }; _lock(){ :; }'
  echo 'hostname(){ echo testgw; }; dpkg(){ echo amd64; }; ss(){ :; }'
  # 取件桩: 记下 URL, 按 URL 的文件名从本地目录喂; 没有这个文件 → curl 的 22(HTTP 错误)
  echo "curl(){ local o='' u=''; while [[ \$# -gt 0 ]]; do case \"\$1\" in -o) o=\"\$2\"; shift;; https://*) u=\"\$1\";; esac; shift; done"
  echo "        echo \"\$u\" >> '$WORK/curl.log'; [[ -f '$SRV/'\"\${u##*/}\" ]] || return 22; cp '$SRV/'\"\${u##*/}\" \"\$o\"; }"
  echo "_core_config_check(){ \"\$2/mihomo\" -t -d '$CFG' -f '$CFG/config.yaml' > '$WORK/cfgchk.log' 2>&1; }"
  echo 'systemctl(){ case "$1" in is-active) echo active;; reset-failed) return 1;; show) echo 0;; esac; return 0; }'
  echo 'HARNESS_OK=1'
} >> "$WORK/h.sh"
bash -n "$WORK/h.sh" 2>/dev/null && ok "夹具可解析" || { bad "夹具语法错 —— 后面的断言都不算数"; finish; }

cat > "$CFG/config.yaml" <<'Y'
mixed-port: 17898
mode: rule
log-level: silent
external-controller: ''
rules:
  - MATCH,DIRECT
Y

# 下载物: 真 mihomo 重新 gzip。钉值那一格的归档摘要随之算出, 注入夹具 versions.sh; 二进制钉值用真的。
gzip -nc "$REAL" > "$SRV/mihomo-linux-amd64-$PIN.gz"
GZ_SHA="$(sha256sum "$SRV/mihomo-linux-amd64-$PIN.gz" | cut -d' ' -f1)"
{ echo "MIHOMO_VER=\"$PIN\""
  echo "declare -A PDG_SHA256=( [mihomo-$MARCH]=\"$GZ_SHA\" [mihomo-bin-$MARCH]=\"$PIN_BIN\" )"
  for f in pdg_mihomo_version pdg_mihomo_is_version pdg_mihomo_binary_ok pdg_verify_sha256; do
    sed -n "/^$f(){/,/^}/p" "$ROOT/lib/versions.sh"
  done
} > "$WORK/repo/lib/versions.sh"

# kernelfollow.py 的测试壳: 真模块 + 三个替换(上游 API / 体检 / 通知)。生产文件一个字节都不改。
cat > "$WORK/repo/deploy/bot/kernelfollow.py" <<PY
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("kernelfollow", "$ROOT/deploy/bot/kernelfollow.py")
kf = importlib.util.module_from_spec(spec); spec.loader.exec_module(kf)
kf.STATE = "$ETC/kernel.json"
def _bump(name):
    p = "$WORK/" + name + ".n"
    n = int(open(p).read()) if os.path.exists(p) else 0
    open(p, "w").write(str(n + 1)); return n
def _http_get(url):
    _bump("api"); open("$WORK/api.log", "a").write(url + "\n")
    return open("$WORK/release.json", "rb").read()
def health():
    n = _bump("health")
    seq = [l for l in open("$WORK/health.seq").read().splitlines() if l.strip()]
    return json.loads(seq[min(n, len(seq) - 1)])
def notify(text):
    open("$WORK/notify.log", "a").write(text + "\n"); return True
kf._http_get, kf.health, kf.notify = _http_get, health, notify
sys.exit(kf.main(sys.argv[1:]))
PY

OLDV=v1.19.29
mkold(){ printf '#!/bin/sh\n# OLD-%s\ncase "$1" in -v) echo "Mihomo Meta %s linux amd64";; esac\nexit 0\n' "$OLDV" "$OLDV" \
           > "$BIN/mihomo"; chmod 755 "$BIN/mihomo"; sha256sum "$BIN/mihomo" | cut -d' ' -f1; }
# 一个"上游新版"的桩: 只用于"已装着、被不被认"那几格(不经取件, 所以不需要是 ELF)
mknext(){ printf '#!/bin/sh\n# NEXT-%s\ncase "$1" in -v) echo "Mihomo Meta %s linux amd64";; esac\nexit 0\n' "$1" "$1" \
            > "$BIN/mihomo"; chmod 755 "$BIN/mihomo"; sha256sum "$BIN/mihomo" | cut -d' ' -f1; }
release(){ # $1=tag $2=归档摘要 [$3=prerelease] [$4=发布时刻]
  printf '{"tag_name":"%s","prerelease":%s,"draft":false,"published_at":"%s","assets":[{"name":"mihomo-linux-amd64-%s.gz","digest":"sha256:%s"}]}' \
    "$1" "${3:-false}" "${4:-2026-10-01T00:00:00Z}" "$1" "$2" > "$WORK/release.json"; }
health_seq(){ printf '%s\n' "$@" > "$WORK/health.seq"; }
HOK='{"ctrl":"ok","dns":"ok","out:DIRECT":"ok","out:jp":"ok"}'
HBAD='{"ctrl":"ok","dns":"ok","out:DIRECT":"ok","out:jp":"fail"}'
state(){ # $1=mode $2=auto [$3=current json]
  printf '{"schema":1,"mode":"%s","auto":%s,"current":%s,"previous":null,"last":null}\n' "$1" "$2" "${3:-null}" > "$ETC/kernel.json"; }
cur_json(){ printf '{"version":"%s","sha256":"%s","source":"upstream","archive_digest":"sha256:%s","at":"2026-11-01T00:00:00Z"}' "$1" "$2" "${3:-$GZ_SHA}"; }
field(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1]));
for k in sys.argv[2].split("."): d = (d or {}).get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$ETC/kernel.json" "$1" 2>/dev/null; }
fresh(){ rm -f "$WORK"/*.n "$WORK/curl.log" "$WORK/api.log" "$WORK/notify.log" "$ETC/kernel.json"; }
run(){ env REPO_DIR="$WORK/repo" PDG_CORE_BINDIR="$BIN" bash -c "source '$WORK/h.sh'; [[ \$HARNESS_OK == 1 ]] || exit 99; $*" \
         > "$WORK/out" 2>&1; echo $?; }
n_of(){ cat "$WORK/$1.n" 2>/dev/null || echo 0; }
binsha(){ sha256sum "$BIN/mihomo" | cut -d' ' -f1; }

echo
echo "══ 1. 跟发布时 upgrade 拒绝, 一样东西都不碰 ══"
fresh; OLD="$(mkold)"; release "$PIN" "$GZ_SHA"; health_seq "$HOK"
rc="$(run _kernel_upgrade)"
[[ "$rc" == 1 ]] && grep -q 跟发布 "$WORK/out" && ok "没有记录(跟发布)→ 拒绝并说明" || bad "跟发布下 upgrade 应当拒绝(rc=$rc)"
[[ "$(binsha)" == "$OLD" && "$(n_of api)" == 0 && ! -e "$WORK/curl.log" && ! -e "$ETC/kernel.json" ]] \
  && ok "内核未动、没查上游、没取件、没建记录" || bad "跟发布下 upgrade 有了副作用"

echo
echo "══ 2. 跟上游: 取件 → 核对 → 换核 → 体检一致 → 记录 ══"
fresh; OLD="$(mkold)"; state upstream false; release "$PIN" "$GZ_SHA"; health_seq "$HOK" "$HOK"
rc="$(run _kernel_upgrade --notify)"
[[ "$rc" == 0 ]] && ok "upgrade rc=0" || { bad "upgrade 应当成功(rc=$rc)"; sed -n '1,40p' "$WORK/out"; }
[[ "$(binsha)" == "$PIN_BIN" ]] && ok "落盘内核就是下载物解出来的那一份" || bad "内核没换上"
[[ "$(field current.version)" == "$PIN" && "$(field current.source)" == upstream \
   && "$(field current.sha256)" == "$PIN_BIN" && "$(field current.archive_digest)" == "sha256:$GZ_SHA" ]] \
  && ok "记录: 版本 / 来源 upstream / 二进制摘要 / 上游 digest 都对" || bad "记录不对: $(cat "$ETC/kernel.json")"
[[ "$(field last.result)" == ok ]] && ok "最近一次尝试记为 ok" || bad "last 没记成 ok"
[[ "$(n_of health)" -ge 2 ]] && ok "体检前后都采了($(n_of health) 次)" || bad "体检没采够"
grep -q "https://github.com/MetaCubeX/mihomo/releases/download/$PIN/mihomo-linux-amd64-$PIN.gz" "$WORK/curl.log" \
  && ok "取件 URL 由 tag 拼出, 指向官方 Release" || bad "取件 URL 不对: $(cat "$WORK/curl.log" 2>/dev/null)"
grep -q '✅' "$WORK/notify.log" 2>/dev/null && ok "--notify 发了成功通知" || bad "没发成功通知"
ls "$BIN"/.mihomo.pdg-prev.* >/dev/null 2>&1 && bad "旧核备份没清掉" || ok "成功后旧核备份已清"

echo
echo "══ 3. 已是目标版本 → 什么都不做 ══"
rm -f "$WORK"/*.n "$WORK/curl.log"
rc="$(run _kernel_upgrade)"
[[ "$rc" == 0 && "$(n_of health)" == 0 && ! -e "$WORK/curl.log" ]] && grep -q 已是 "$WORK/out" \
  && ok "上游最新 = 已装且被认 → 不取件、不体检" || bad "已是最新时不该再换(rc=$rc)"

echo
echo "══ 4. 下载物与上游 digest 不符 → 拒绝, 内核与记录都不动 ══"
fresh; OLD="$(mkold)"; state upstream false; release "$PIN" "$(printf 'f%.0s' {1..64})"; health_seq "$HOK"
rc="$(run _kernel_upgrade --notify)"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" && -z "$(field current.version)" && "$(n_of health)" == 0 ]] \
  && ok "digest 不符 → rc=1、旧核原样、没有记录、没走到体检" || bad "digest 不符时有副作用(rc=$rc)"
[[ "$(field last.result)" == fail ]] && grep -q '❌' "$WORK/notify.log" 2>/dev/null \
  && ok "失败记进 last 并通知" || bad "失败没留痕"

echo
echo "══ 4b. 下载失败(与版本无关)记 error, 自动第二天照样再试 ══"
fresh; OLD="$(mkold)"; state upstream true; release "$PIN" "$GZ_SHA" false "$(date -u -d '-5 days' +%FT%TZ)"; health_seq "$HOK" "$HOK"
mv "$SRV/mihomo-linux-amd64-$PIN.gz" "$SRV/hidden.gz"
rc="$(run _kernel_upgrade "$PIN" --notify)"
mv "$SRV/hidden.gz" "$SRV/mihomo-linux-amd64-$PIN.gz"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" && "$(field last.result)" == error ]] \
  && ok "下载失败 → rc=1、旧核原样、记为 error(不是 fail)" || bad "下载失败的记法不对(rc=$rc, last=$(field last.result))"
rm -f "$WORK/curl.log"
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && grep -q "$PIN" "$WORK/curl.log" 2>/dev/null \
  && ok "上次只是下载失败 → 下一次自动照常重试并换上" || bad "一次下载失败把自动卡住了(rc=$rc)"

echo
echo "══ 4c. 换核前体检一项 ok 都没有 → 不换(没有可对照的前像) ══"
fresh; OLD="$(mkold)"; state upstream false; release "$PIN" "$GZ_SHA"
health_seq '{"ctrl":"na","dns":"fail"}'
rc="$(run _kernel_upgrade)"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" && -z "$(field current.version)" ]] && grep -q 无从对照 "$WORK/out" \
  && ok "前像全不 ok → 不换、说明无从对照" || bad "没有前像也换了(rc=$rc)"
[[ "$(field last.result)" == fail ]] && ok "记为 fail(这一版换上去也验不出好坏, 自动不重复试)" || bad "无前像不该记成 $(field last.result)"

echo
echo "══ 5. 换核后体检持续变差 → 换回旧核 ══"
fresh; OLD="$(mkold)"; state upstream false; release "$PIN" "$GZ_SHA"; health_seq "$HOK" "$HBAD"
rc="$(run _kernel_upgrade --notify)"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" ]] && ok "体检变差 → rc=1, 旧核逐字节换回" || bad "体检变差却没换回(rc=$rc, sha=$(binsha))"
[[ -z "$(field current.version)" ]] && ok "记录没写(没换成就不记)" || bad "没换成却写了记录"
grep -q 'out:jp' "$WORK/out" && ok "原因里点名了变差的那一项(out:jp)" || bad "原因没点名退步项"
[[ "$(n_of health)" -ge 5 ]] && ok "后像有界重试过($(( $(n_of health) - 1 )) 次)再判" || bad "后像没重试就判了"
ls "$BIN"/.mihomo.pdg-prev.* >/dev/null 2>&1 && bad "还原后残留备份" || ok "还原后不留备份文件"

echo
echo "══ 6. 换核后头一次体检没就绪、重试后一致 → 不误判 ══"
fresh; OLD="$(mkold)"; state upstream false; release "$PIN" "$GZ_SHA"; health_seq "$HOK" "$HBAD" "$HOK"
rc="$(run _kernel_upgrade)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && ok "重试内恢复 → 保留新核" || bad "一次没就绪就把新核换回了(rc=$rc)"

echo
echo "══ 7. 护栏: 低于钉值 / 预发布 ══"
fresh; OLD="$(mkold)"; state upstream false; health_seq "$HOK"
release v1.19.20 "$GZ_SHA"
rc="$(run _kernel_upgrade)"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" && ! -e "$WORK/curl.log" ]] && grep -q 钉值 "$WORK/out" \
  && ok "上游低于钉值 → 不换、不取件" || bad "低于钉值时不该换(rc=$rc)"
[[ "$(field last.result)" == skip ]] && ok "记为 skip" || bad "last 不是 skip"
release "$PIN" "$GZ_SHA" true
rc="$(run _kernel_upgrade)"
[[ "$rc" == 1 && "$(binsha)" == "$OLD" && ! -e "$WORK/curl.log" ]] && ok "预发布 → 不换、不取件" || bad "预发布不该换(rc=$rc)"

echo
echo "══ 8. pdg update 的保留判据 ══"
fresh; NX="v${PIN#v}"; NX="${NX%.*}.$(( ${PIN##*.} + 1 ))"
NSHA="$(mknext "$NX")"; state upstream false "$(cur_json "$NX" "$NSHA")"
rc="$(run _update_core_binary)"
[[ "$rc" == 0 && "$(binsha)" == "$NSHA" && ! -e "$WORK/curl.log" ]] && grep -q "保留 $NX" "$WORK/out" \
  && ok "跟上游且被认的 $NX → 保留, 不降级、不取件" || bad "pdg update 把被认的上游内核换掉了(rc=$rc)"
state pinned false "$(cur_json "$NX" "$NSHA")"
rc="$(run _update_core_binary)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && ok "改回跟发布 → pdg update 换回钉值" || bad "跟发布下没换回钉值(rc=$rc)"
[[ "$(field current.source)" == pin && "$(field current.version)" == "$PIN" && "$(field previous.version)" == "$NX" ]] \
  && ok "有记录的机器: 换回钉值后记录跟着改成 pin, 上一份挪进 previous" || bad "换回钉值后记录没跟上: $(cat "$ETC/kernel.json")"
fresh; mknext "$NX" >/dev/null
state upstream false "$(cur_json "$NX" "$(printf '0%.0s' {1..64})")"
rc="$(run _update_core_binary)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && ok "记录摘要与文件不符 → 不认, 换回钉值" || bad "摘要不符却被保留(rc=$rc)"
fresh; mkold >/dev/null
rc="$(run _update_core_binary)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" && ! -e "$ETC/kernel.json" ]] \
  && ok "没有记录的机器: 行为与以前一样(换成钉值), 也不新建记录" || bad "没有记录的机器上行为变了(rc=$rc)"

echo
echo "══ 9. revert: 改回跟发布(自动一并关)并换回发布钉值 ══"
fresh; NSHA="$(mknext "$NX")"; state upstream true "$(cur_json "$NX" "$NSHA")"; health_seq "$HOK"
rc="$(run _kernel_revert --notify)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && ok "revert → 内核等于钉值" || bad "revert 没换回(rc=$rc)"
[[ "$(field mode)" == pinned && "$(field auto)" == False ]] \
  && ok "模式改成 pinned、自动关掉(不会第二天被自动换回上游)" || bad "revert 后模式不对: $(field mode)/$(field auto)"
[[ "$(field current.source)" == pin && "$(field previous.version)" == "$NX" ]] \
  && ok "记录改成 pin, 上游那份挪进 previous" || bad "revert 后记录不对"
grep -q '✅' "$WORK/notify.log" 2>/dev/null && ok "--notify 发了结果" || bad "revert 没发结果"
release "$NX" "$GZ_SHA" false "$(date -u -d '-5 days' +%FT%TZ)"; rm -f "$WORK/curl.log" "$WORK/api.n"
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" && "$(n_of api)" == 0 ]] && ok "revert 之后的定时检查不动内核" || bad "revert 之后被自动换回上游了"
rc="$(run _kernel_revert)"
[[ "$rc" == 0 && ! -e "$WORK/curl.log" ]] && grep -q 已是 "$WORK/out" && ok "已是钉值时 revert 什么都不做" || bad "已是钉值时不该取件"
fresh; mkold >/dev/null
rc="$(run _kernel_revert)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" && ! -e "$ETC/kernel.json" ]] \
  && ok "没用过跟随的机器: revert 换回钉值, 不多出一份记录" || bad "没有记录的机器上 revert 建了记录或没换回(rc=$rc)"

echo
echo "══ 10. tick: 只有跟上游 + 自动才动; 等待期; 失败过不重试 ══"
fresh; OLD="$(mkold)"; health_seq "$HOK"
release "$PIN" "$GZ_SHA" false "$(date -u -d '-5 days' +%FT%TZ)"
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(n_of api)" == 0 && "$(binsha)" == "$OLD" ]] && ok "没有记录 → tick 安静返回, 不查上游" || bad "跟发布的机器上 tick 有动作"
state upstream false
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(n_of api)" == 0 ]] && ok "跟上游但自动关 → 不查上游" || bad "自动关时 tick 查了上游"
state upstream true
release "$PIN" "$GZ_SHA" false "$(date -u -d '-1 days' +%FT%TZ)"
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(binsha)" == "$OLD" && ! -e "$WORK/curl.log" ]] && grep -q 等待期 "$WORK/out" \
  && ok "上游发布不满 3 天 → 不换" || bad "等待期内换了(rc=$rc)"
release "$PIN" "$GZ_SHA" false "$(date -u -d '-5 days' +%FT%TZ)"
python3 - "$ETC/kernel.json" "$PIN" <<'P'
import json, sys
d = json.load(open(sys.argv[1])); d["last"] = {"at": "x", "result": "fail", "version": sys.argv[2], "why": "t"}
json.dump(d, open(sys.argv[1], "w"))
P
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(binsha)" == "$OLD" && ! -e "$WORK/curl.log" ]] && grep -q 失败过 "$WORK/out" \
  && ok "同一版自动换失败过 → 不再自动重试" || bad "失败过的版本被自动重试了"
state upstream true
rc="$(run _kernel_tick)"
[[ "$rc" == 0 && "$(binsha)" == "$PIN_BIN" ]] && grep -q '✅' "$WORK/notify.log" 2>/dev/null \
  && ok "满 3 天、没失败过 → 自动换上并通知" || bad "该自动换的时候没换(rc=$rc)"

echo
echo "══ 11. cmd_kernel: 模式 / 自动 / 用法 ══"
fresh
rc="$(run cmd_kernel auto on)"
[[ "$rc" != 0 ]] && ok "跟发布下开自动 → 拒绝" || bad "跟发布下开自动应当拒绝"
rc="$(run cmd_kernel mode upstream)"
[[ "$rc" == 0 && "$(field mode)" == upstream ]] && ok "mode upstream 写进记录" || bad "mode upstream 失败(rc=$rc)"
rc="$(run cmd_kernel auto on)"
[[ "$rc" == 0 && "$(field auto)" == True ]] && ok "auto on" || bad "auto on 失败(rc=$rc, auto=$(field auto))"
rc="$(run cmd_kernel mode pinned)"
[[ "$rc" == 0 && "$(field mode)" == pinned && "$(field auto)" == False ]] && ok "mode pinned 一并关自动" || bad "mode pinned 不对"
rc="$(run cmd_kernel mode latest)"
[[ "$rc" != 0 && "$(field mode)" == pinned ]] && ok "不认识的模式 → 拒绝, 记录不变" || bad "不认识的模式被接受了"
fresh; mkold >/dev/null; state upstream false; release "$PIN" "$GZ_SHA"; health_seq "$HOK"
rc="$(run '_lock(){ echo "⛔ 已有 pdg 操作在运行"; exit 1; }; cmd_kernel upgrade --notify')"
[[ "$rc" == 1 ]] && grep -q 没有做完 "$WORK/notify.log" 2>/dev/null \
  && ok "后台任务拿不到锁 → 仍补发一条通知(不让 bot 那边干等)" || bad "拿不到锁时没有通知(rc=$rc)"
rm -f "$WORK/notify.log"
rc="$(run '_lock(){ exit 1; }; cmd_kernel upgrade')"
[[ ! -e "$WORK/notify.log" ]] && ok "不带 --notify 时不发通知(终端里本来就看得到)" || bad "没要通知却发了"
state upstream false "$(cur_json "$PIN" "$PIN_BIN")"; cp "$REAL" "$BIN/mihomo"
rc="$(run cmd_kernel upgrade --notify)"
[[ "$rc" == 0 && "$(grep -c . "$WORK/notify.log" 2>/dev/null)" == 1 ]] && grep -q 已是 "$WORK/notify.log" \
  && ok "已是最新 → 恰好一条「没有换」的通知(不重复补发)" || bad "已是最新时通知不对: $(cat "$WORK/notify.log" 2>/dev/null)"
rc="$(run cmd_kernel frobnicate)"
[[ "$rc" == 2 ]] && grep -q '用法: pdg kernel' "$WORK/out" && ok "未知子命令 → 用法, rc=2" || bad "未知子命令处理不对(rc=$rc)"
rc="$(run cmd_kernel status)"
[[ "$rc" == 0 ]] && grep -q '内核跟随: 跟上游' "$WORK/out" && grep -q "已装: $PIN(发布钉值)" "$WORK/out" \
  && ok "status 可读, 模式与已装来源对得上" || bad "status 不对(rc=$rc): $(head -3 "$WORK/out")"

echo
finish

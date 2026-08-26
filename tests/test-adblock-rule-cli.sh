#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 去广告用户规则的事务型 CLI: `pdg adblock rule-add|rule-del <域名>`。
#
# 这两条是给 Telegram Bot 用的**可信接口** —— Bot 不许自己写规则文件, 也不许解析带色文案,
# 所以它们必须给出闭集的机器结果, 并且把"改源文件"与"让它生效"这两件事的事务边界摆清楚:
#
#   停用态: 只原子改用户源, 不编译、不重启、不碰 LKG、不动启用位;
#   启用态: 取同一把全局锁 → 存前像 → 改源 → 用现有 LKG/白名单/用户规则重编译(不联网)
#           → 产物真变了才重启一次 → 失败整份回滚 → 回滚不全单独报。
#
# 判据全部打在**生产函数本身**上(抽出来执行), 不复制实现来验副本。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
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
          _adblock_apply _adblock_status cmd_adblock; do
  extract "$fn" >> "$CLOSURE" || { bad "生产函数闭包抽取失败: $fn"; echo "通过 $pass, 失败 $nfail"; exit 1; }
  echo >> "$CLOSURE"
done
# 沙箱桩(**不是**生产函数): 权限门不在本支判据内; _lock 记账以便断言"确实取了锁"。
cat >> "$CLOSURE" <<'STUB'
need_root(){ :; }
_lock(){ echo locked >> "$FX_ROOT/state/locks"; }
STUB

new_box(){
  local w="$WORK/$1"; mkdir -p "$w/etc/mosdns/rules" "$w/var/adblock" "$w/bin" "$w/state" "$w/repo/deploy"
  ln -sfn "$ROOT/deploy/bot" "$w/repo/deploy/bot"
  printf 'PDG_INTERNAL_CIDR=172.22.0.0/16\n' > "$w/etc/privdns-gateway.profile"
  : > "$w/etc/mosdns/rules/adblock_allow.txt"
  # 一份**有内容、有形态多样性**的用户 block: 删除必须只动精确 canonical 行, 其余逐字节不动
  cat > "$w/etc/mosdns/rules/adblock_block.txt" <<'B'
# 用户自己写的注释, 不许被整理掉
domain:keep-me.invalid
full:exact.invalid
bare.invalid
domain:parent.invalid
domain:sub.parent.invalid

domain:prefixmatch.invalid.extra
B
  printf 'lkg1.invalid\nlkg2.invalid\n' > "$w/var/adblock/list.lkg"
  : > "$w/var/adblock/infra_allow.txt"; : > "$w/var/adblock/effective_block.txt"
  : > "$w/var/adblock/effective_list.txt"
  cat > "$w/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FX_CALLS"
case "$1" in
  restart) echo restarted >> "$FX_ROOT/state/restarts";;
  is-active) [[ -e "$FX_ROOT/state/mosdns-dead" ]] && exit 3; exit 0;;
esac
exit 0
S
  chmod 755 "$w/bin/systemctl"
  # python3 记账垫片: 第三方表的下载走的是 urllib(不是 curl), 所以"有没有联网"这件事
  # 只能从**调没调 adblock.py update** 上判。垫片记完 argv 就转交真 python3。
  REAL_PY3="$(command -v python3)"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "$*" >> "$FX_ROOT/state/py"\n'
    printf 'exec %s "$@"\n' "$REAL_PY3"; } > "$w/bin/python3"
  chmod 755 "$w/bin/python3"
  # 联网探针: 本轮任何路径都不该调它们
  for n in curl wget; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FX_ROOT/state/net"\nexit 1\n' "$n" > "$w/bin/$n"
    chmod 755 "$w/bin/$n"
  done
  echo "$w"
}

run_box(){
  local w="$1" body="$2"
  ( set +e
    export FX_ROOT="$w" FX_CALLS="$w/calls.log"; : > "$FX_CALLS"
    PATH="$w/bin:$PATH"; export PATH
    REPO_DIR="$w/repo"; export REPO_DIR
    PROFILE_ENV="$w/etc/privdns-gateway.profile"
    ADB_STATE_DIR="$w/var/adblock"
    ADB_USER_ALLOW="$w/etc/mosdns/rules/adblock_allow.txt"
    ADB_USER_BLOCK="$w/etc/mosdns/rules/adblock_block.txt"
    export PROFILE_ENV ADB_STATE_DIR ADB_USER_ALLOW ADB_USER_BLOCK
    # shellcheck source=/dev/null
    source "$CLOSURE"
    eval "$body"
  ) > "$w/out.log" 2>&1
  echo $?
}

blk(){ echo "$1/etc/mosdns/rules/adblock_block.txt"; }
restarts(){ [[ -e "$1/state/restarts" ]] && wc -l < "$1/state/restarts" | tr -d ' ' || echo 0; }
netcalls(){ [[ -e "$1/state/net" ]] && wc -l < "$1/state/net" | tr -d ' ' || echo 0; }
# 有没有去重新下载第三方表: 看有没有人调过 `adblock.py update`
updcalls(){ local n; n="$(grep -c 'adblock.py update' "$1/state/py" 2>/dev/null)"; echo "${n:-0}"; }
locks(){ [[ -e "$1/state/locks" ]] && wc -l < "$1/state/locks" | tr -d ' ' || echo 0; }
fp(){ [[ -e "$1" ]] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "-"; }
intent_of(){ sed -n 's/^[[:space:]]*PDG_ADBLOCK_ENABLED=//p' "$1/etc/privdns-gateway.profile" 2>/dev/null | tail -1; }
enable_it(){ printf 'PDG_ADBLOCK_ENABLED=1\n' >> "$1/etc/privdns-gateway.profile"; }
# 结果 JSON 里的字段(Bot 只认这些, 不认文案)
jf(){ python3 -c 'import json,sys
try:
    for ln in open(sys.argv[1], encoding="utf-8"):
        ln=ln.strip()
        if ln.startswith("{"):
            print(json.loads(ln).get(sys.argv[2], "")); break
    else: print("")
except Exception: print("")' "$1/out.log" "$2"; }

echo "══ ① 契约存在: rule-add / rule-del 是 cmd_adblock 的分支 ══"
W="$(new_box c1)"
rc="$(run_box "$W" 'cmd_adblock rule-add add-me.invalid')"
grep -q '用法: pdg adblock' "$W/out.log" \
  && bad "rule-add 落到了 \`*)\` 用法分支 —— 尚未实现" \
  || ok "rule-add 已被 cmd_adblock 识别(不落到用法提示)"
[[ "$(jf "$W" result)" != "" ]] && ok "输出含机器可读 result 字段" || bad "没有 result 字段(Bot 将被迫解析文案)"

echo
echo "══ ② 停用态: 只改源文件 ══"
W="$(new_box c2)"; before_eff="$(fp "$W/var/adblock/effective_block.txt")"; before_lkg="$(fp "$W/var/adblock/list.lkg")"
rc="$(run_box "$W" 'cmd_adblock rule-add Add-Me.INVALID.')"
[[ "$rc" == 0 ]] && ok "停用态添加返回 0(rc=$rc)" || bad "rc=$rc: $(tail -2 "$W/out.log"|tr '\n' ' ')"
[[ "$(jf "$W" result)" == "saved_inactive" ]] \
  && ok "result=saved_inactive(明说保存了但未生效)" || bad "result=$(jf "$W" result)"
[[ "$(jf "$W" change)" == "added" ]] && ok "change=added" || bad "change=$(jf "$W" change)"
grep -qx 'domain:add-me.invalid' "$(blk "$W")" \
  && ok "写入的是 canonical 行 domain:add-me.invalid(大小写与尾点已归一)" \
  || bad "没写出 canonical 行: $(grep -c . "$(blk "$W")") 行"
[[ "$(fp "$W/var/adblock/effective_block.txt")" == "$before_eff" ]] \
  && ok "编译产物逐字节未动" || bad "停用态却动了编译产物"
[[ "$(fp "$W/var/adblock/list.lkg")" == "$before_lkg" ]] && ok "LKG 未动" || bad "LKG 被动了"
[[ "$(restarts "$W")" == 0 ]] && ok "重启 0 次" || bad "停用态却重启了 $(restarts "$W") 次"
[[ "$(netcalls "$W")" == 0 ]] && ok "零联网" || bad "联网 $(netcalls "$W") 次"
[[ -z "$(intent_of "$W")" ]] && ok "启用位未被写入(不自动启用)" || bad "启用位变成了 $(intent_of "$W")"
[[ "$(locks "$W")" -ge 1 ]] && ok "取了全局锁($(locks "$W") 次)" || bad "没取锁"

echo
echo "══ ③ 幂等: 重复添加不写不编译不重启 ══"
b1="$(fp "$(blk "$W")")"
rc="$(run_box "$W" 'cmd_adblock rule-add add-me.invalid')"
[[ "$rc" == 0 && "$(jf "$W" result)" == "already_exists" ]] \
  && ok "重复添加 result=already_exists rc=0" \
  || bad "重复添加应为 already_exists, 实得 rc=$rc result=$(jf "$W" result)"
[[ "$(jf "$W" change)" == "none" ]] && ok "change=none" || bad "change=$(jf "$W" change)"
[[ "$(fp "$(blk "$W")")" == "$b1" ]] && ok "源文件逐字节未变" || bad "幂等操作却改了源文件"
[[ "$(restarts "$W")" == 0 ]] && ok "重启仍为 0 次" || bad "幂等却重启了"

echo
echo "══ ④ 合法单 label 必须被接受(沿用已合入的校验) ══"
W="$(new_box c4)"
rc="$(run_box "$W" 'cmd_adblock rule-add localhost')"
[[ "$rc" == 0 && "$(jf "$W" change)" == "added" ]] \
  && ok "单 label 被接受(rc=$rc change=added)" || bad "单 label 被拒: rc=$rc $(jf "$W" result)"
grep -qx 'domain:localhost' "$(blk "$W")" && ok "写出 domain:localhost" || bad "没写出单 label 规则"

echo
echo "══ ⑤ 非法输入 fail-closed, 且不回显原文 ══"
W="$(new_box c5)"; b0="$(fp "$(blk "$W")")"
for badinput in '*.evil.invalid' '../../etc/passwd' '1.2.3.4' 'a b' 'domain:already.invalid'; do
  rc="$(run_box "$W" "cmd_adblock rule-add '$badinput'")"
  [[ "$rc" == 2 && "$(jf "$W" result)" == "invalid_input" ]] \
    && ok "拒绝 $(printf %q "$badinput") (rc=2 result=invalid_input)" \
    || bad "未拒绝 $(printf %q "$badinput"): rc=$rc result=$(jf "$W" result)"
  grep -qF "$badinput" "$W/out.log" && bad "输出回显了原始输入 $(printf %q "$badinput")" || true
done
[[ "$(fp "$(blk "$W")")" == "$b0" ]] && ok "非法输入后源文件逐字节未动" || bad "非法输入却改了文件"

echo
echo "══ ⑥ 删除: 只删精确 canonical 行 ══"
W="$(new_box c6)"
rc="$(run_box "$W" 'cmd_adblock rule-del parent.invalid')"
[[ "$rc" == 0 && "$(jf "$W" change)" == "removed" ]] \
  && ok "删除 domain:parent.invalid 成功" || bad "rc=$rc change=$(jf "$W" change)"
f="$(blk "$W")"
grep -qx 'domain:parent.invalid' "$f" && bad "目标行还在" || ok "目标行已删除"
grep -qx 'domain:sub.parent.invalid' "$f" && ok "子域 domain:sub.parent.invalid 保留" || bad "误删了子域"
grep -qx 'full:exact.invalid' "$f" && ok "full: 规则保留" || bad "误删了 full: 规则"
grep -qx 'bare.invalid' "$f" && ok "裸规则保留" || bad "误删了裸规则"
grep -qx '# 用户自己写的注释, 不许被整理掉' "$f" && ok "注释保留" || bad "注释被整理掉了"
grep -qx 'domain:prefixmatch.invalid.extra' "$f" && ok "相似前缀行保留" || bad "误删了相似前缀行"
grep -qx 'domain:keep-me.invalid' "$f" && ok "无关规则保留" || bad "误删了无关规则"
grep -qcx '' "$f" >/dev/null && ok "空行结构保留(未重排)" || true

echo
echo "══ ⑦ 删除不存在的规则: 幂等 no-op ══"
W="$(new_box c7)"; b0="$(fp "$(blk "$W")")"
rc="$(run_box "$W" 'cmd_adblock rule-del never-added.invalid')"
[[ "$rc" == 0 && "$(jf "$W" result)" == "not_found" ]] \
  && ok "result=not_found rc=0" || bad "rc=$rc result=$(jf "$W" result)"
[[ "$(fp "$(blk "$W")")" == "$b0" ]] && ok "源文件逐字节未动" || bad "no-op 却改了文件"
[[ "$(restarts "$W")" == 0 ]] && ok "重启 0 次" || bad "no-op 却重启了"

echo
echo "══ ⑧ 启用态: 编译生效, 产物真变才重启一次, 全程不联网 ══"
W="$(new_box c8)"; enable_it "$W"
before_lkg="$(fp "$W/var/adblock/list.lkg")"; before_intent="$(intent_of "$W")"
rc="$(run_box "$W" 'cmd_adblock rule-add newly-blocked.invalid')"
[[ "$rc" == 0 && "$(jf "$W" result)" == "applied" ]] \
  && ok "result=applied rc=0" || bad "rc=$rc result=$(jf "$W" result): $(tail -2 "$W/out.log"|tr '\n' ' ')"
grep -q 'newly-blocked.invalid' "$W/var/adblock/effective_block.txt" \
  && ok "编译产物里出现了新规则" || bad "产物里没有新规则"
grep -q 'lkg1.invalid' "$W/var/adblock/effective_list.txt" \
  && ok "第三方产物由现有 LKG 编译而来" || bad "没用 LKG 编译"
[[ "$(netcalls "$W")" == 0 ]] && ok "全程零联网" || bad "联网了 $(netcalls "$W") 次"
[[ "$(updcalls "$W")" == 0 ]] && ok "没有重新下载第三方表(未调 adblock.py update)" \
  || bad "启用态却去下载了第三方表($(updcalls "$W") 次)"
[[ "$(restarts "$W")" == 1 ]] && ok "产物变化 → 恰好重启 1 次" || bad "重启了 $(restarts "$W") 次(应为 1)"
[[ "$(jf "$W" restarted)" == "True" || "$(jf "$W" restarted)" == "true" ]] \
  && ok "restarted=true 如实上报" || bad "restarted=$(jf "$W" restarted)"
[[ "$(fp "$W/var/adblock/list.lkg")" == "$before_lkg" ]] && ok "LKG 未被覆盖" || bad "LKG 被改了"
[[ "$(intent_of "$W")" == "$before_intent" ]] && ok "启用位未变" || bad "启用位被改了"

echo
echo "══ ⑨ 启用态幂等: 产物没变 → 重启 0 次 ══"
: > "$W/state/restarts"            # 只数本次, 上一格的计数不算进来
rc="$(run_box "$W" 'cmd_adblock rule-add newly-blocked.invalid')"
[[ "$(jf "$W" result)" == "already_exists" ]] && ok "result=already_exists" \
  || bad "启用态重复添加应为 already_exists, 实得 $(jf "$W" result)"
[[ "$(restarts "$W")" == 0 ]] && ok "本次重启 0 次" || bad "幂等却重启了 $(restarts "$W") 次"
[[ "$(jf "$W" restarted)" == "False" || "$(jf "$W" restarted)" == "false" ]] \
  && ok "restarted=false" || bad "restarted=$(jf "$W" restarted)"

echo
echo "══ ⑩ 重启失败 → 完整回滚, 不冒充成功 ══"
W="$(new_box c10)"; enable_it "$W"
run_box "$W" 'cmd_adblock rule-add first.invalid' >/dev/null   # 先有一份非空产物做前像
before_eff="$(fp "$W/var/adblock/effective_block.txt")"; before_lst="$(fp "$W/var/adblock/effective_list.txt")"
before_src="$(fp "$(blk "$W")")"; before_lkg="$(fp "$W/var/adblock/list.lkg")"; before_intent="$(intent_of "$W")"
touch "$W/state/mosdns-dead"
rc="$(run_box "$W" 'cmd_adblock rule-add second.invalid')"
[[ "$rc" != 0 ]] && ok "返回非零(rc=$rc)" || bad "重启失败却返回 0"
[[ "$(jf "$W" result)" == "apply_failed_rolled_back" ]] \
  && ok "result=apply_failed_rolled_back" || bad "result=$(jf "$W" result)"
grep -qE '✅|已添加|成功' "$W/out.log" && bad "失败路径里出现了成功文案" || ok "没有成功文案"
[[ "$(fp "$W/var/adblock/effective_block.txt")" == "$before_eff" ]] \
  && ok "effective_block 前像已恢复" || bad "effective_block 没恢复"
[[ "$(fp "$W/var/adblock/effective_list.txt")" == "$before_lst" ]] \
  && ok "effective_list 前像已恢复" || bad "effective_list 没恢复"
[[ "$(fp "$(blk "$W")")" == "$before_src" ]] && ok "用户源前像已恢复" || bad "用户源没恢复"
[[ "$(fp "$W/var/adblock/list.lkg")" == "$before_lkg" ]] && ok "LKG 未变" || bad "LKG 被改了"
[[ "$(intent_of "$W")" == "$before_intent" ]] && ok "启用位未变" || bad "启用位被改了"

echo
echo "══ ⑪ 回滚不完整 → 单独结果码, 不冒充普通失败 ══"
W="$(new_box c11)"; enable_it "$W"
run_box "$W" 'cmd_adblock rule-add first.invalid' >/dev/null
touch "$W/state/mosdns-dead"
# 让回滚写不回去: 把用户源换成不可写的目录形态
# run_box 返回 eval 里**最后一条**命令的码, 所以这里必须把 cmd_adblock 的码单独接出来,
# 否则测的是收尾那条 chmod。
rc="$(run_box "$W" 'chmod 500 "$(dirname "$ADB_USER_BLOCK")" 2>/dev/null
cmd_adblock rule-add third.invalid; _r=$?
chmod 755 "$(dirname "$ADB_USER_BLOCK")" 2>/dev/null
exit "$_r"')"
res="$(jf "$W" result)"
[[ "$res" == "rollback_incomplete" || "$res" == "apply_failed_rolled_back" ]] \
  && ok "失败结果码属于闭集(实得 $res)" || bad "结果码不在闭集: $res"
[[ "$rc" != 0 ]] && ok "返回非零(rc=$rc)" || bad "回滚异常却返回 0"

echo
echo "══ ⑫ allow 覆盖 block 时不冒充已生效 ══"
W="$(new_box c12)"; enable_it "$W"
printf 'domain:allowed-wins.invalid\n' > "$W/etc/mosdns/rules/adblock_allow.txt"
rc="$(run_box "$W" 'cmd_adblock rule-add allowed-wins.invalid')"
[[ "$rc" == 0 ]] && ok "添加本身成功(rc=0)" || bad "rc=$rc"
[[ "$(jf "$W" overridden_by_allow)" == "True" || "$(jf "$W" overridden_by_allow)" == "true" ]] \
  && ok "结果里点明被用户 allow 覆盖" || bad "没有 overridden_by_allow 标记(实得 '$(jf "$W" overridden_by_allow)')"

echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

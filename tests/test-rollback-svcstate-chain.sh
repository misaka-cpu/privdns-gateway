#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 走**真实 cmd_rollback** 的整条服务恢复链, 跑在**自有临时根**里。
#
# 隔离: 用 unshare 建私有挂载命名空间, 把 /etc /opt /usr/local/bin 绑到一次性目录上。
# 宿主的这些路径在命名空间外一动不动。**不**依赖"非 root 写 /etc 会失败"这种兜底 ——
# 那不是隔离, 只是碰巧没写成。建不出隔离就直接报"未执行"并以非 0 退出, 不冒充通过。
#
# 被测的是产品原文: cmd_rollback、_pdg_apply_snapshot_tree(真的落盘到自有根)、
# _core_kernel_activate / _pdg_kernel_converge(真的编排 enable/start/disable)、
# _pdg_svcstate_plan、_pdg_restore_svcstate、_pdg_svcstate_valid、_pdg_svc_q。
# 只对**外部系统边界**建模: systemctl、nft。仍被替换的产品函数在结尾逐条列出。
#
# 判据分三类, 不混算:
#   · 命令调用条数 —— systemctl 被调用了几次;
#   · 涉及 unit 数 —— 这些调用一共点到几个 unit;
#   · 状态变化次数 —— 桩里 .en/.ac 真正被改写了几次(中途的启动/永久启用就藏在这里)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── 隔离入口 ────────────────────────────────────────────────────────────────
# 三段式: 未进隔离(变量空) → 进了 unshare(=1) → 进了 bwrap(=2)。
# 最外层判据必须是"变量为空", 不能写成 `!= 1` —— bwrap 那条回退路径会把变量设成 2,
# 用 `!= 1` 判就会**再进一次初始化分支**, 变成递归入口。
# 自有根一建出来就先挂上清理; 交接给 exec 出去的进程时再撤掉(那边有自己的清理)。
if [[ -z "${PDG_CHAIN_NS:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)" || { echo "[未执行] 建不出自有根"; exit 1; }
  trap 'rm -rf "$FAKE"' EXIT          # 这一段里任何退出路径都归它清
  mkdir -p "$FAKE/etc/privdns-gateway" "$FAKE/etc/systemd/system" "$FAKE/etc/mosdns/rules" \
           "$FAKE/etc/mihomo" "$FAKE/opt/pdg-bot" "$FAKE/usr/local/bin" "$FAKE/run" \
    || { echo "[未执行] 自有根建不全"; exit 1; }
  # /etc 整个被换掉会让走 /etc/alternatives 的命令(awk)消失, 先把必需的几样放进去。
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  export FAKE
  if unshare --map-root-user --mount --propagation private true 2>/dev/null; then
    export PDG_CHAIN_NS=1; trap - EXIT      # 所有权交给下面 exec 出去的那个进程
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  elif bwrap --version >/dev/null 2>&1; then   # 看它**能不能用**, 不只是 PATH 里有
    export PDG_CHAIN_NS=2; trap - EXIT
    exec bwrap --dev-bind / / --bind "$FAKE/etc" /etc --bind "$FAKE/opt" /opt \
               --bind "$FAKE/usr/local/bin" /usr/local/bin --bind "$FAKE/run" /run \
               -- bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare/bwrap)。"
  echo "         这一支会让真实 cmd_rollback 会往 /etc /opt /usr/local/bin 落盘, 没有自有根就不能跑 ——"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
# 进到这里说明已经在隔离里。先把清理挂上, 再做挂载 —— 挂载失败也有人负责清。
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
if [[ "${PDG_CHAIN_NS}" == 1 ]]; then
  mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
  mount --bind "$FAKE/opt" /opt || { echo "[未执行] 绑定 /opt 失败"; exit 1; }
  mount --bind "$FAKE/usr/local/bin" /usr/local/bin || { echo "[未执行] 绑定 /usr/local/bin 失败"; exit 1; }
  mount --bind "$FAKE/run" /run || { echo "[未执行] 绑定 /run 失败"; exit 1; }
fi
# 隔离自检: **只读**核实归属 —— 比 /etc 与自有根里那一份的 dev:inode 是不是同一个。
# 不往宿主路径写探针: 真要没隔离住, 那一笔就落到宿主上了, 判据本身成了事故。
for _m in etc opt usr/local/bin run; do
  if [[ "$(stat -c '%d:%i' "/$_m" 2>/dev/null)" != "$(stat -c '%d:%i' "$FAKE/$_m" 2>/dev/null)" ]]; then
    echo "[未执行] 隔离自检失败: /$_m 不是自有根里的那一份(只读核实, 未做任何写入)"
    exit 1
  fi
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PDG="${PDG_UNDER_TEST:-$ROOT/deploy/bot/pdg.sh}"
WORK="${PDG_CHAIN_KEEP:-$(mktemp -d)}"
[[ -n "${PDG_CHAIN_KEEP:-}" ]] || trap 'rm -rf "$WORK" "$FAKE"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
SC="$WORK/sc"; mkdir -p "$SC"
set_u(){ echo "$2" > "$SC/$1.en"; echo "$3" > "$SC/$1.ac"; echo running > "$SC/$1.sub"; echo "INV-$1-orig" > "$SC/$1.inv"; }

# systemctl / nft 桩: 外部系统边界。除了记账与回答状态, 还单独记"状态真的被改写"的次数。
STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1"
  case "$act" in
    daemon-reload|reset-failed) return 0;;
    is-enabled) local v; v="$(cat "$SC_DIR/$u.en" 2>/dev/null)" || { echo not-found; return 1; }
                echo "$v"; case "$v" in enabled|enabled-runtime|static|indirect|generated|alias) return 0;; *) return 1;; esac;;
    is-active)  local a; a="$(cat "$SC_DIR/$u.ac" 2>/dev/null)" || { echo inactive; return 3; }
                echo "$a"; [[ "$a" == active ]] && return 0 || return 3;;
    show) case "$3" in
            LoadState)    [[ -e "$SC_DIR/$u.en" ]] && echo loaded || echo not-found;;
            SubState)     cat "$SC_DIR/$u.sub" 2>/dev/null || echo dead;;
            InvocationID) cat "$SC_DIR/$u.inv" 2>/dev/null || echo "";;
            *) echo "";;
          esac; return 0;;
  esac
  local now
  case "$act" in
    enable)  if [[ "$2" == --runtime ]]; then now=enabled-runtime; else now=enabled; fi
             _chg "$u" en "$now"
             if [[ "${2:-}" == --now || "${3:-}" == --now ]]; then
               _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv"
             fi;;
    disable) _chg "$u" en disabled; [[ "${2:-}" == --now ]] && _chg "$u" ac inactive;;
    start|restart) _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv";;
    stop)    _chg "$u" ac inactive;;
  esac
  return 0
}
_chg(){   # $1=unit $2=en|ac $3=新值; 只有真的变了才记一次"状态变化"
  local cur; cur="$(cat "$SC_DIR/$1.$2" 2>/dev/null)"
  [[ "$cur" == "$3" ]] && return 0
  echo "$3" > "$SC_DIR/$1.$2"
  echo "$1 $2 $cur -> $3" >> "$SC_CHG"
}
nft(){ return 0; }'

# 产品原文(本轮涉及的编排一律真跑)
prodfns(){
  _fn1 "$PDG" c_g; _fn1 "$PDG" c_y; _fn1 "$PDG" c_r
  echo 'need_root(){ :; }; _lock(){ :; }'
  echo '_pdg_core(){ echo mihomo; }; _pdg_core_svc(){ echo mihomo; }'
  echo '_pdg_mktemp_dir(){ mktemp -d; }'
  echo '_sb_panel_managed_on(){ return 1; }'
  echo 'pdg_write_unit(){ printf "[Unit]\n" > "$2"; return 0; }'
  echo 'pdg_unit_mihomo(){ echo "[Unit]"; }'
  echo '_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }'
  echo '_lan_rollback_converge(){ return 0; }'
  echo '_nft_apply_main(){ return 0; }'
  echo '_snap_meta_commit(){ echo ""; }'
  echo '_pdg_ios_verify_tree(){ return 0; }'
  # ↓ 本轮涉及的编排: 全部用产品原文
  grep -m1 '^_PDG_IOS_STATE_REL=' "$PDG"; grep -m1 '^_PDG_IOS_ART_REL=' "$PDG"
  _fnN "$PDG" _pdg_apply_snapshot_tree
  _fnN "$PDG" _pdg_ios_group_in_members
  _fnN "$PDG" _core_kernel_activate
  grep -q '^_pdg_kernel_converge(){' "$PDG" && _fnN "$PDG" _pdg_kernel_converge
  _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
  _fnN "$PDG" _pdg_save_svcstate; _fnN "$PDG" _pdg_svcstate_valid
  grep -m1 '^declare -A _PDG_WANT_EN' "$PDG"
  grep -m1 '^_PDG_SVC_MODE=' "$PDG"; grep -m1 '^_PDG_SVC_WHY=' "$PDG"; grep -m1 '^_PDG_SVC_SRC=' "$PDG"
  grep -q '^_pdg_svcstate_plan(){' "$PDG" && { _fnN "$PDG" _pdg_svcstate_plan; _fn1 "$PDG" _pdg_now_ac; _fn1 "$PDG" _pdg_now_en; }
  # 自启恢复现在由 _pdg_set_enable_state 一处负责(持久/运行时两层要分别撤) —— 抽真身, 不补替代实现。
  grep -q '^_pdg_set_enable_state(){' "$PDG" && _fnN "$PDG" _pdg_set_enable_state
  _fnN "$PDG" _pdg_restore_svcstate
  _fnN "$PDG" cmd_rollback
}

# 造现场: $1=快照目录名, $2..=前像里 mihomo 的 (en ac)
mkcase(){
  local name="$1" mih_en="$2" mih_ac="$3"
  local d="$WORK/$name"; mkdir -p "$d/snap" "$d/stage/etc/privdns-gateway" "$d/stage/opt/pdg-bot"
  rm -f "$SC"/*; local u
  for u in $U_ALL; do set_u "$u" enabled active; done
  set_u mihomo "$mih_en" "$mih_ac"
  # 快照内容 = "切换/升级之前"的文件
  printf 'OLD-BACKEND\n'  > "$d/stage/etc/privdns-gateway/backend"
  printf 'OLD-PROFILE\n'  > "$d/stage/etc/privdns-gateway/profile.env"
  printf 'OLD-MODULE\n'   > "$d/stage/opt/pdg-bot/bot.py"
  chmod 640 "$d/stage/etc/privdns-gateway/profile.env"
  chmod 755 "$d/stage/opt/pdg-bot/bot.py"
  ( cd "$d/stage" && tar czf "$d/snap/snap.tar.gz" etc opt ) 2>/dev/null
  chmod 600 "$d/snap/snap.tar.gz"
  # 现网 = "升级之后"的文件(内容与属性都不同), 等着被回滚盖回去
  install -d -m755 /etc/privdns-gateway /opt/pdg-bot
  printf 'NEW-BACKEND\n' > /etc/privdns-gateway/backend
  printf 'NEW-PROFILE\n' > /etc/privdns-gateway/profile.env; chmod 600 /etc/privdns-gateway/profile.env
  printf 'NEW-MODULE\n'  > /opt/pdg-bot/bot.py; chmod 700 /opt/pdg-bot/bot.py
  # 前像(用产品原文的保存函数写, 记的就是上面 set_u 的那套状态)
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$SC\"; SC_LOG=\"$d/save.log\"; SC_CHG=\"$d/save.chg\"; : > \"\$SC_LOG\"; : > \"\$SC_CHG\""
    echo "$STUB"
    _fn1 "$PDG" c_g; _fn1 "$PDG" c_y
    _fnN "$PDG" _pdg_svcstate_units; _fnN "$PDG" _pdg_svc_known; _fnN "$PDG" _pdg_svc_q
    _fnN "$PDG" _pdg_save_svcstate
    echo "_pdg_save_svcstate \"$d/snap\" >/dev/null"
  } > "$d/save.sh"
  [[ "${4:-}" == no-preimage ]] || bash "$d/save.sh"
  # 回滚之后"现场"的服务状态: 自启链接没了、服务也没起(快照不收 wants/)
  for u in $U_ALL; do set_u "$u" disabled inactive; done
  echo "$d"
}

run_chain(){   # $1=场景目录
  local d="$1"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$SC\"; SC_LOG=\"$d/chain.log\"; SC_CHG=\"$d/chain.chg\"; : > \"\$SC_LOG\"; : > \"\$SC_CHG\""
    echo "$STUB"
    echo "SNAP_DIR=\"$d\"; REPO_DIR=\"$d/norepo\""
    prodfns
    echo "cmd_rollback --dir \"$d/snap\" --no-git"
    echo 'echo "CHAIN_RC=$?"'
    local u
    for u in $U_ALL; do
      echo "printf 'FINAL\t$u\t%s\t%s\n' \"\$(cat \"$SC/$u.en\" 2>/dev/null)\" \"\$(cat \"$SC/$u.ac\" 2>/dev/null)\""
    done
  } > "$d/chain.sh"
  bash "$d/chain.sh" 2>&1 | tee "$d/chain.out"
}
plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
fin(){ grep -P "^FINAL\t$2\t" <<<"$1" | cut -f3,4 | tr '\t' '/'; }
chg(){ grep -c "^$2 " "$1/chain.chg" 2>/dev/null || true; }

echo "隔离: $( [[ "${PDG_CHAIN_NS}" == 1 ]] && echo 'unshare 私有挂载' || echo 'bwrap' ) —— /etc /opt /usr/local/bin 已绑到一次性目录"
echo
echo "══ 一. 前像 = mihomo 本来 disabled/inactive ══"
d="$(mkcase A disabled inactive)"
o="$(run_chain "$d")"; p="$(plain "$o")"
echo "   —— 文件四维(自有根内真实内容与属性) ——"
# 注: /etc/privdns-gateway/backend 会被 cmd_rollback 自己按"唯一内核"重写成 mihomo,
# 所以文件这一维的判据取**回滚不再改写**的那几个。
[[ "$(cat /etc/privdns-gateway/profile.env)" == OLD-PROFILE ]] && ok "A0a: profile.env 内容已回到快照版本" || bad "A0a: 实得 $(cat /etc/privdns-gateway/profile.env 2>&1)"
[[ "$(cat /opt/pdg-bot/bot.py)" == OLD-MODULE ]] && ok "A0b: /opt/pdg-bot/bot.py 内容已回到快照版本" || bad "A0b: 实得 $(cat /opt/pdg-bot/bot.py 2>&1)"
[[ "$(stat -c %a /etc/privdns-gateway/profile.env)" == 640 ]] && ok "A0c: profile.env 权限位也回到 640(不只是内容)" || bad "A0c: 实得 $(stat -c %a /etc/privdns-gateway/profile.env)"
echo "   —— 服务 ——"
[[ "$(fin "$o" mihomo)" == "disabled/inactive" ]] && ok "A1: mihomo 最终回到 disabled/inactive" || bad "A1: 实得 $(fin "$o" mihomo)"
[[ "$(chg "$d" mihomo)" == 0 ]] && ok "A2: **全过程**里 mihomo 的状态一次都没被改写(没有先 enable --now 再纠正)" \
  || { bad "A2: mihomo 状态被改写 $(chg "$d" mihomo) 次:"; grep '^mihomo ' "$d/chain.chg" | sed 's/^/        /'; }
grep -qE '^enable --now mihomo' "$d/chain.log" && bad "A3: 出现了 enable --now mihomo(永久启用)" || ok "A3: 没有 enable --now mihomo"
grep -q 'CHAIN_RC=0' <<<"$p" && ok "A4: 整条链返回 0" || bad "A4: $(grep -o 'CHAIN_RC=.*' <<<"$p")"

echo
echo "══ 二. 前像 = mihomo 本来 enabled-runtime/active ══"
d="$(mkcase B enabled-runtime active)"
o="$(run_chain "$d")"; p="$(plain "$o")"
[[ "$(fin "$o" mihomo)" == "enabled-runtime/active" ]] && ok "B1: mihomo 最终回到 enabled-runtime/active(没被提升成永久 enabled)" || bad "B1: 实得 $(fin "$o" mihomo)"
# 盯的是**任意一次**中途变更, 不只是最后一次 —— 先永久 enable 再纠正回 runtime 也算。
if grep -qE '^mihomo en .* -> enabled$' "$d/chain.chg"; then
  bad "B2: 中途把 mihomo 改成过永久 enabled: $(grep '^mihomo en' "$d/chain.chg" | tr '\n' ';')"
else ok "B2: 中途一次都没把 mihomo 改成永久 enabled"; fi
grep -qE '^enable --now mihomo' "$d/chain.log" && bad "B3: 出现了 enable --now mihomo" || ok "B3: 没有 enable --now mihomo"
grep -q 'CHAIN_RC=0' <<<"$p" && ok "B4: 整条链返回 0" || bad "B4: $(grep -o 'CHAIN_RC=.*' <<<"$p")"
grep -qE '^disable --now sing-box' "$d/chain.log" && ok "B5: 旧核冲突检查仍在(disable --now sing-box 照做)" || bad "B5: 旧核那一步丢了"

echo
echo "══ 三. 本来停着的服务全过程不许被启动 ══"
d="$(mkcase C enabled active)"
set_u pdg-bot disabled inactive
# 重新写一份把 pdg-bot 记成 disabled/inactive 的前像
bash "$d/save.sh"
for u in $U_ALL; do set_u "$u" disabled inactive; done
set_u mihomo disabled inactive
o="$(run_chain "$d")"
[[ "$(fin "$o" pdg-bot)" == "disabled/inactive" ]] && ok "C1: pdg-bot 最终仍是 disabled/inactive" || bad "C1: 实得 $(fin "$o" pdg-bot)"
[[ "$(chg "$d" pdg-bot)" == 0 ]] && ok "C2: 全过程里 pdg-bot 状态零改写" || { bad "C2: 被改写 $(chg "$d" pdg-bot) 次"; grep '^pdg-bot ' "$d/chain.chg" | sed 's/^/        /'; }

echo
echo "══ 四. 没有前像(旧快照): 历史兼容路径要单独说清 ══"
d="$(mkcase D enabled active no-preimage)"
o="$(run_chain "$d")"; p="$(plain "$o")"
grep -q 'CHAIN_RC=1' <<<"$p" && ok "D1: 整条链返回 1" || bad "D1: $(grep -o 'CHAIN_RC=.*' <<<"$p")"
grep -q '✅ 已回滚并重启服务' <<<"$p" && bad "D2: 仍然报了「已回滚并重启服务」" || ok "D2: 没有报「已回滚并重启服务」"
grep -q '服务前像缺失/不可用' <<<"$p" && ok "D3: 未恢复项点名了服务前像这一格" || bad "D3"
grep -qE '按历史行为|不是按前像' <<<"$p" && ok "D4: 内核这一步明说走的是历史兼容路径, 不是按前像精确恢复" || bad "D4: 没有把两条路径分开报告"
[[ "$(cat /etc/privdns-gateway/profile.env)" == OLD-PROFILE && "$(cat /opt/pdg-bot/bot.py)" == OLD-MODULE ]] \
  && ok "D5: 文件恢复照常做(缺前像不影响文件这一维)" || bad "D5"

echo
echo "══ 五. 撤销对照: 把内核收敛换回无条件 enable --now ══"
REV="$WORK/pdg-rev-kernel.sh"
if grep -q '^_pdg_kernel_converge(){' "$PDG"; then
  awk '/^_pdg_kernel_converge\(\)\{/{print "_pdg_kernel_converge(){ _core_kernel_activate \"$1\" \"$2\"; }"; skip=1; next}
       skip && /^\}/{skip=0; next} !skip{print}' "$PDG" > "$REV"
  if cmp -s "$PDG" "$REV" || ! bash -n "$REV" 2>/dev/null; then
    bad "E0: 没造出反向副本 —— 本格记无效"
  else
    ok "E0: 反向副本就位(只把内核收敛换回 _core_kernel_activate)"
    _pdg_keep="$PDG"; PDG="$REV"
    d="$(mkcase E disabled inactive)"
    o="$(run_chain "$d")"
    PDG="$_pdg_keep"
    [[ "$(chg "$d" mihomo)" -ge 1 ]] && ok "E1: 撤回之后 mihomo 的状态**中途真的被改写**了 $(chg "$d" mihomo) 次 —— A2 确实由这处修复保住" \
      || bad "E1: 反向对照没体现差异 —— 本格记无效"
    grep -qE '^enable --now mihomo' "$d/chain.log" && ok "E2: 且出现了 enable --now mihomo(永久启用)" || bad "E2: 反向对照无效"
    [[ "$(fin "$o" mihomo)" == "disabled/inactive" ]] \
      && ok "E3: 而最终状态仍被纠正回 disabled/inactive —— 只看最终状态抓不住这件事" || bad "E3: 实得 $(fin "$o" mihomo)"
  fi
else
  bad "E0: 被测副本里没有 _pdg_kernel_converge —— 本格记无效(首红运行时这是预期的)"
fi

echo
echo "──────── 本支仍被替换的产品函数, 以及因此未覆盖的性质 ────────"
cat <<'NOTE'
  need_root / _lock                 → 未覆盖: 真实取锁与并发互斥(由 test-inherited-lock-proof.py 等覆盖)
  _pdg_core / _pdg_core_svc         → 未覆盖: 内核标记的真实读取
  _sb_panel_managed_on              → 未覆盖: sing-box 面板托管判定
  pdg_write_unit / pdg_unit_mihomo  → 未覆盖: unit 模板的真实渲染内容
  _pdg_drop_singbox_files / _pdg_singbox_is_ours → 未覆盖: sing-box 归属判定与清理
  _lan_rollback_converge            → 未覆盖: 内网面板派生产物收敛(由 test-lan-rollback-convergence.sh 覆盖)
  _nft_apply_main / nft             → 未覆盖: 真实 nft 规则装载
  _snap_meta_commit                 → 未覆盖: 快照元数据里的 git_commit 解析(由 test-update-rollback.sh 覆盖)
  _pdg_ios_verify_tree              → 未覆盖: iOS 生命周期联合校验
  systemctl                         → 未覆盖: 真实 systemd 的状态机与时序
  ⇒ 这一支证明的是**编排顺序与状态判据**, 不是真实 systemd 行为。
NOTE
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

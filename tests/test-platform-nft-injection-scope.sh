#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 定性 tests/e2e-platform-switch.sh §6 的那两条红灯(6c 平台标记 / 6d iOS 组件)。
#
# §6 的注入方式是: 把 /usr/local/bin/nft 换成一个"凡 `-c` 一律失败"的壳, 直到
# `pdg platform android` **返回之后**才换回来。而恢复自己也要跑 `nft -c`:
#   cmd_rollback 在落盘**之前**有一道
#       [[ -f "$tree/etc/nftables.conf" ]] && { nft -c -f … || { echo "❌ 快照的 nftables 语法错, 中止"; return 1; } }
#   —— 也就是说, 那个注入**同时阻断了前向操作和恢复**, 恢复在"还没动任何东西"时就按设计中止了。
#
# 这一支把两件事分开验, 不删 6c/6d, 也不先判定产品缺陷:
#   甲. **只让前向失败, 恢复条件正常** → 平台标记 / iOS 组件 / 配置 / 服务都必须恢复;
#   乙. **恢复条件也故障**(复刻 §6 的 nft 壳) → 必须报告未完成、非零退出、保留材料,
#       而**不要求**它穿过持续故障仍完整恢复。
#
# 跑的是产品原文的 cmd_platform / _plat_fail_restore / cmd_rollback / 清理与迁移;
# 隔离与 systemctl 建模沿用 tests/test-platform-fail-restore.sh 的那一套。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── 隔离入口 ────────────────────────────────────────────────────────────────
# 三段式: 未进隔离(变量空) → 进了 unshare(=1) → 进了 bwrap(=2)。
# 最外层判据必须是"变量为空", 不能写成 `!= 1` —— bwrap 那条回退路径会把变量设成 2,
# 用 `!= 1` 判就会**再进一次初始化分支**, 变成递归入口。
# 自有根一建出来就先挂上清理; 交接给 exec 出去的进程时再撤掉(那边有自己的清理)。
if [[ -z "${PDG_NFTSCOPE_NS:-}" ]]; then
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
    export PDG_NFTSCOPE_NS=1; trap - EXIT      # 所有权交给下面 exec 出去的那个进程
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  elif bwrap --version >/dev/null 2>&1; then   # 看它**能不能用**, 不只是 PATH 里有
    export PDG_NFTSCOPE_NS=2; trap - EXIT
    exec bwrap --dev-bind / / --bind "$FAKE/etc" /etc --bind "$FAKE/opt" /opt \
               --bind "$FAKE/usr/local/bin" /usr/local/bin --bind "$FAKE/run" /run \
               -- bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare/bwrap)。"
  echo "         这一支会让真实 cmd_platform 会往 /etc /opt /usr/local/bin 落盘, 没有自有根就不能跑 ——"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
# 进到这里说明已经在隔离里。先把清理挂上, 再做挂载 —— 挂载失败也有人负责清。
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
if [[ "${PDG_NFTSCOPE_NS}" == 1 ]]; then
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
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" "$FAKE"' EXIT
pass=0; nfail=0
ok(){ echo "[OK]   $1"; pass=$((pass+1)); }
bad(){ echo "[FAIL] $1"; nfail=$((nfail+1)); }
[[ -f "$PDG" ]] || { bad "找不到 $PDG"; echo "通过 0, 失败 1"; exit 1; }

_fn1(){ grep -m1 -E "^$2\(\)\{.*\}[[:space:]]*\$" "$1"; }
_fnN(){ sed -n "/^$2(){/,/^}/p" "$1"; }
_arr(){ sed -n "/^$2=(/,/^)/p" "$1"; }

U_ALL="pdg-mitm pdg-bot pdg-probe81 mosdns mihomo pdg-dotwitness pdg-health.timer pdg-rules-update.timer"
SC="$WORK/sc"; mkdir -p "$SC"
set_u(){ echo "$2" > "$SC/$1.en"; echo "$3" > "$SC/$1.ac"; echo running > "$SC/$1.sub"; echo "INV-$1-orig" > "$SC/$1.inv"; }

STUB='
systemctl(){
  echo "$*" >> "$SC_LOG"
  local u="${*: -1}" act="$1" now
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
  case "$act" in
    enable)  if [[ "$2" == --runtime ]]; then now=enabled-runtime; else now=enabled; fi
             _chg "$u" en "$now"
             if [[ "${2:-}" == --now || "${3:-}" == --now ]]; then _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv"; fi;;
    disable) _chg "$u" en disabled; [[ "${2:-}" == --now ]] && _chg "$u" ac inactive;;
    start|restart) _chg "$u" ac active; echo "INV-$u-$RANDOM$RANDOM" > "$SC_DIR/$u.inv";;
    stop)    _chg "$u" ac inactive;;
  esac
  return 0
}
_chg(){ local cur; cur="$(cat "$SC_DIR/$1.$2" 2>/dev/null)"
  [[ "$cur" == "$3" ]] && return 0
  echo "$3" > "$SC_DIR/$1.$2"; echo "$1 $2 $cur -> $3" >> "$SC_CHG"; }
# 复刻 tests/e2e-platform-switch.sh §6 的注入壳: 凡 `nft -c` 一律失败。
# 由 NFT_C_FAIL 开关控制 —— 本支比较的就是「恢复条件正常 vs 恢复条件也故障」这一个变量。
nft(){ [[ "${NFT_C_FAIL:-0}" == 1 && "$1" == -c ]] && { echo "Error: 注入的校验失败" >&2; return 1; }; return 0; }'

# 造一台"还留着退役件"的老机器
seed_machine(){   # $1=当前平台
  rm -rf /etc/privdns-gateway /etc/systemd/system /etc/mosdns /etc/mihomo /opt/pdg-bot
  mkdir -p /etc/privdns-gateway /etc/systemd/system /etc/mosdns/rules /etc/mihomo /opt/pdg-bot
  printf '%s\n' "$1" > /etc/privdns-gateway/platform
  printf 'PROFILE-ORIG\n' > /etc/privdns-gateway/profile.env; chmod 640 /etc/privdns-gateway/profile.env
  printf '{"wloc": {"enabled": true, "lat": 1}}\n' > /etc/privdns-gateway/mitm.json
  # 劫持表里放**真正属于 WLOC** 的那条(gs-loc.apple.com)。放别的域名会被退役迁移按
  # "归属不清"合法拒绝 —— 那是它该有的行为, 不是本支要测的东西。
  printf 'full:gs-loc.apple.com\n' > /etc/mosdns/rules/mitm_hijack.txt
  printf 'MIHOMO-ORIG\n' > /etc/mihomo/config.yaml
  # 真机上这份存在且**进快照** —— cmd_rollback 落盘前会对它跑一次 `nft -c`。
  # 不放进来就摸不到 e2e-platform-switch §6 真正撞上的那道安全门。
  printf 'table inet pdg {\\n}\\n' > /etc/nftables.conf
  printf '[Unit]\nDescription=pdg-mitm ORIG\n' > /etc/systemd/system/pdg-mitm.service; chmod 644 /etc/systemd/system/pdg-mitm.service
  local f
  for f in mitm_ca.py mitm_server.py mitm_wloc.py iosprofile.py iosstate.py pdg-dot.mobileconfig.tmpl pdg-mitm.mobileconfig.tmpl; do
    printf 'ORIG-%s\n' "$f" > "/opt/pdg-bot/$f"; chmod 755 "/opt/pdg-bot/$f"
  done
  write_fake_bot
  # iosstate.py 依赖同目录的 pdgtx.py(真机上它们本来就一起部署)。用仓库里的真文件。
  cp -a "$ROOT/deploy/bot/pdgtx.py" /opt/pdg-bot/pdgtx.py
  rm -f "$SC"/*
  for f in $U_ALL; do set_u "$f" enabled active; done
}
mkrepo(){   # REPO_DIR: iOS 专属件用**仓库里的真文件**, 否则装上去的 iosstate.py 一 import 就炸,
            # 后面的记录格式迁移等于没测。
  local r="$WORK/repo"; [[ -d "$r" ]] && { echo "$r"; return; }
  mkdir -p "$r/deploy/ios" "$r/deploy/bot"
  cp -a "$ROOT/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl" "$r/deploy/ios/" 2>/dev/null \
    || printf 'TMPL\n' > "$r/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl"
  local m
  for m in iosprofile.py iosstate.py mitm_ca.py; do cp -a "$ROOT/deploy/bot/$m" "$r/deploy/bot/$m"; done
  echo "$r"
}

# 渲染器: 内核配置渲染是外部边界(真 bot.py 依赖整台机器的数据模型)。这里放一个**最小但真**
# 的 bot.py, 让产品原文的 _retire_rerender_core 能跑完它自己那一串检查(空产出? 还有 MITM-OUT?
# mihomo -t 过不过? 属性跟随? 原子替换? 重启后 is-active?), 而不是把整个函数换成成功。
write_fake_bot(){
  cat > /opt/pdg-bot/bot.py <<'BOT'
import os
SB = "/etc/sing-box/config.json"
MIHOMO_DIR = "/etc/mihomo"
MIHOMO_CFG = "/etc/mihomo/config.yaml"
LAN_TABLE_FILE = "/etc/privdns-gateway/lan.json"
RS_META = "/etc/privdns-gateway/rulesets.json"
MITM_CONFIG = "/etc/privdns-gateway/mitm.json"
IOS_META = "/etc/privdns-gateway/ios-profile.json"
IOS_ART_DIR = "/var/lib/privdns-gateway/ios-profile"


def _platform(p="/etc/privdns-gateway/platform"):
    return open(p).read().strip() if os.path.exists(p) else "android"


def load():
    return {}


def _render_mihomo_bytes(_m):
    return (b"mixed-port: 7890\nproxies: []\nrules:\n  - MATCH,DIRECT\n", {})


def _render_mihomo_file():
    data, _ = _render_mihomo_bytes(load())
    os.makedirs(MIHOMO_DIR, exist_ok=True)
    with open(MIHOMO_CFG, "wb") as f:
        f.write(data)
BOT
  chmod 755 /opt/pdg-bot/bot.py
}

# 真实 cmd_platform 的运行壳。只对外部系统边界与本轮不涉及的编排打桩。
run_platform(){   # $1=目标平台 $2=fail|nofail $3=场景目录 [$4=被测 pdg.sh]
  local tgt="$1" mode="$2" d="$3" src="${4:-$PDG}"
  mkdir -p "$d/snaps"
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$SC\"; SC_LOG=\"$d/sc.log\"; SC_CHG=\"$d/sc.chg\"; MIG_LOG=\"$d/mig.log\""
    echo "NFT_C_FAIL=\"${NFT_C_FAIL:-0}\""
    echo ': > "$SC_LOG"; : > "$SC_CHG"; : > "$MIG_LOG"'
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
    echo 'need_root(){ :; }; _lock(){ :; }'
    # ── 迁移链: 先把**所有** migrate_* 定成空转, 再把本轮关心的那几支换成产品原文。
    # 顺序有讲究: 空转在前, 原文在后, 后者覆盖前者。
    # 这样 cmd_platform 末尾那句 `run_all_migrations || true` 才是真的在跑, 而不是
    # 撞上一个未定义函数(command not found + 127)被 `|| true` 吞掉。
    grep -oE '^migrate_[a-z0-9_]+\(\)\{' "$src" | sed 's/(){$//' | sort -u | while read -r _m; do
      [[ "$_m" == migrate_wloc_retire ]] && continue
      printf '%s(){ echo "MIGRATE-NOOP %s" >> "$MIG_LOG"; return 0; }\n' "$_m" "$_m"
    done
    echo "SNAP_DIR=\"$d/snaps\"; REPO_DIR=\"$(mkrepo)\"; LOCK=\"$d/lock\""
    echo '_pdg_core(){ echo mihomo; }; _pdg_core_svc(){ echo mihomo; }; _pdg_mktemp_dir(){ mktemp -d; }'
    echo '_sb_panel_managed_on(){ return 1; }'
    echo 'pdg_write_unit(){ printf "[Unit]\n" > "$2"; return 0; }; pdg_unit_mihomo(){ echo "[Unit]"; }'
    echo '_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }'
    echo '_lan_rollback_converge(){ return 0; }; _nft_apply_main(){ return 0; }; _snap_meta_commit(){ echo ""; }'
    echo '_pdg_ios_verify_tree(){ return 0; }'
    echo '_plat_write_profile(){ printf "PROFILE-%s\n" "$1" > /etc/privdns-gateway/profile.env; return 0; }'
    echo 'migrate_probe81_public(){ return 0; }'
    echo '_pdg_nft_bin(){ echo /bin/true; }; _pdg_required_svcs(){ echo mosdns; }'
    echo 'migrate_ios_gms_cleanup(){ return 0; }; _plat_verify(){ return 0; }'
    echo '_pdg_bot_cred(){ echo ready; }; _core_kernel_stable(){ return 0; }'
    echo '_pdg_svc_stable(){ return 0; }; _pdg_nft_ok(){ return 0; }'
    echo 'doctor(){ return 0; }'
    # cmd_snapshot: 本轮不涉及它的实现, 但**材料必须是真的** —— 真打一份 tar。
    echo "cmd_snapshot(){ local s=\"$d/snaps/\$(date +%s%N)\"; mkdir -p \"\$s\""
    echo '  tar czf "$s/snap.tar.gz" -C / etc/privdns-gateway etc/systemd/system etc/mosdns etc/mihomo etc/nftables.conf opt/pdg-bot 2>/dev/null'
    echo '  chmod 600 "$s/snap.tar.gz"; _PDG_SNAP_CREATED="$s"; return 0; }'
    # 失败注入点: 退役件已经撤除之后、切换宣布成功之前的第一处可失败步骤。
    if [[ "$mode" == fail-delete ]]; then
      # 退役件已经撤除、平台件已经装上之后失败; 同时把**本次新增**的一件变成非空目录 ——
      # 后面 `rm -f` 对它必然 EISDIR, 这就是"恢复动作自身失败"的确定性反例。
      echo "_switchcore_nft(){ rm -f /opt/pdg-bot/pdg-dot.mobileconfig.tmpl; mkdir -p /opt/pdg-bot/pdg-dot.mobileconfig.tmpl"
      echo "  : > /opt/pdg-bot/pdg-dot.mobileconfig.tmpl/keep"
      echo "  printf 'unit=%s server=%s wloc=%s\n' \\"
      echo "    \"\$( [[ -e /etc/systemd/system/pdg-mitm.service ]] && echo present || echo gone )\" \\"
      echo "    \"\$( [[ -e /opt/pdg-bot/mitm_server.py ]] && echo present || echo gone )\" \\"
      echo "    \"\$( [[ -e /opt/pdg-bot/mitm_wloc.py ]] && echo present || echo gone )\" > \"$d/stage-proof\"; return 1; }"
    elif [[ "$mode" == fail ]]; then
      echo "_switchcore_nft(){ printf 'unit=%s server=%s wloc=%s\n' \\"
      echo "  \"\$( [[ -e /etc/systemd/system/pdg-mitm.service ]] && echo present || echo gone )\" \\"
      echo "  \"\$( [[ -e /opt/pdg-bot/mitm_server.py ]] && echo present || echo gone )\" \\"
      echo "  \"\$( [[ -e /opt/pdg-bot/mitm_wloc.py ]] && echo present || echo gone )\" > \"$d/stage-proof\"; return 1; }"
    else
      echo '_switchcore_nft(){ return 0; }'
    fi
    # python3 **不打桩** —— 记录格式迁移与渲染都要真跑。mihomo 是外部二进制, 打桩。
    echo 'mihomo(){ return 0; }'
    # 产品原文: 本轮涉及的全部编排
    grep -m1 '^_PDG_IOS_STATE_REL=' "$src"; grep -m1 '^_PDG_IOS_ART_REL=' "$src"
    grep -m1 '^_PDG_RETIRE_OK=' "$src"; grep -m1 '^_PDG_RETIRE_DONE=' "$src"
    _arr "$src" _PLAT_RETIRED; _arr "$src" _PLAT_IOS_REQUIRED
    _fnN "$src" _pdg_apply_snapshot_tree; _fnN "$src" _pdg_ios_group_in_members
    _fnN "$src" _core_kernel_activate
    grep -q '^_pdg_kernel_converge(){' "$src" && _fnN "$src" _pdg_kernel_converge
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_save_svcstate; _fnN "$src" _pdg_svcstate_valid
    grep -m1 '^declare -A _PDG_WANT_EN' "$src"
    grep -m1 '^_PDG_SVC_MODE=' "$src"; grep -m1 '^_PDG_SVC_WHY=' "$src"; grep -m1 '^_PDG_SVC_SRC=' "$src"
    _fnN "$src" _pdg_svcstate_plan; _fn1 "$src" _pdg_now_ac; _fn1 "$src" _pdg_now_en
    _fnN "$src" _pdg_restore_svcstate; _fnN "$src" cmd_rollback
    _fnN "$src" _retire_caller_gate; _fnN "$src" _retire_allowed
    _fnN "$src" _retire_android_pending; _fnN "$src" _retire_plat_pending
    _fnN "$src" _pdg_lock_proof
    echo "_pdg_module(){ printf '%s\\n' \"$ROOT/deploy/bot/\$1\"; }"
    echo '_pdg_platform(){ cat /etc/privdns-gateway/platform 2>/dev/null; }'
    # WLOC 退役那一整条: 全部产品原文。**不**用恒成功的桩代替 —— 那样 schema 那一步等于没测。
    grep -m1 '^_RETIRE_UNDO=' "$src"; grep -m1 '^_RETIRE_TMP=' "$src"
    grep -oE '^_retire_[a-z0-9_]+\(\)\{' "$src" | sed 's/(){$//' | sort -u | while read -r _rf; do
      _fnN "$src" "$_rf"
    done
    _fnN "$src" _retire_svc_stopped; _fnN "$src" _retire_core_has_mitm
    _fnN "$src" migrate_wloc_retire
    _fnN "$src" run_all_migrations
    _fnN "$src" _plat_purge_retired; _fnN "$src" _plat_deploy_ios; _fnN "$src" migrate_android_cleanup
    _fnN "$src" cmd_platform
    echo "exec 9>\"$d/lock\"; flock -n 9"
    echo "cmd_platform $tgt"
    echo 'echo "PLAT_RC=$?"'
    local u
    for u in $U_ALL; do
      echo "printf 'FINAL\t$u\t%s\t%s\n' \"\$(cat \"$SC/$u.en\" 2>/dev/null)\" \"\$(cat \"$SC/$u.ac\" 2>/dev/null)\""
    done
  } > "$d/run.sh"
  bash "$d/run.sh" 2>&1
}
plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
# 执行有效性: 壳里少装了函数(command not found)、或脚本异常中断, 都不是产品行为判据 ——
# 这种运行整个作废, 必须当场点出来, 不能拿它的"表现"去给产品定性。
exec_valid(){   # $1=输出 $2=标签
  local bad_lines
  bad_lines="$(plain "$1" | grep -nE 'command not found|未找到命令|syntax error|unbound variable' | head -3)"
  if [[ -n "$bad_lines" ]]; then
    bad "$2: **执行无效** —— 壳里有未定义/异常, 这次运行不作为产品判据:"
    sed 's/^/        /' <<<"$bad_lines"
    return 1
  fi
  ok "$2: 执行有效(无未定义调用、无异常中断)"
}
# 一份**故意不合格**的 schema-1 记录: 真实代码会按字段白名单拒掉它。
mkschema1_bad(){
  python3 - "$1" <<'PYREC'
import json, sys, uuid, datetime
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "instance_id": str(uuid.uuid4()), "created_at": now,
           "current": {"revision": 3, "created_at": now,
                       "inputs": {"wloc_enabled": False, "ssids": ["home"]}},
           "previous": None, "migration_pending": False},
          open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PYREC
}
fin(){ grep -P "^FINAL\t$2\t" <<<"$1" | cut -f3,4 | tr '\t' '/'; }

check_dir(){   # 四维核验, $1=输出 $2=场景目录 $3=方向名
  local o="$1" d="$2" n="$3"
  [[ -f "$d/stage-proof" ]] && grep -q 'unit=gone' "$d/stage-proof" \
    && ok "$n: 失败确实注入在**退役件已经撤除之后**($(cat "$d/stage-proof"))" \
    || bad "$n: 没命中那个阶段($(cat "$d/stage-proof" 2>/dev/null || echo 未生成))"
  # ① 文件: 内容 + 存在性 + 属性
  [[ "$(cat /etc/systemd/system/pdg-mitm.service 2>/dev/null | tail -1)" == "Description=pdg-mitm ORIG" ]] \
    && ok "$n: pdg-mitm.service 回来了且内容是原来的" || bad "$n: unit 没回来/内容不对"
  [[ "$(stat -c %a /etc/systemd/system/pdg-mitm.service 2>/dev/null)" == 644 ]] \
    && ok "$n: 且权限位也是原来的 644" || bad "$n: 权限位 $(stat -c %a /etc/systemd/system/pdg-mitm.service 2>/dev/null)"
  [[ "$(cat /opt/pdg-bot/mitm_server.py 2>/dev/null)" == ORIG-mitm_server.py ]] \
    && ok "$n: mitm_server.py 回来了" || bad "$n: mitm_server.py 没回来"
  [[ "$(cat /opt/pdg-bot/mitm_wloc.py 2>/dev/null)" == ORIG-mitm_wloc.py ]] \
    && ok "$n: mitm_wloc.py 回来了" || bad "$n: mitm_wloc.py 没回来"
  [[ "$(cat /etc/privdns-gateway/platform)" == "$4" ]] && ok "$n: 平台标记回到 $4" || bad "$n: 平台标记是 $(cat /etc/privdns-gateway/platform)"
  # ② 运行态 ③ 自启态
  [[ "$(fin "$o" pdg-mitm)" == "enabled/active" ]] && ok "$n: pdg-mitm 的自启与运行态都回到切换前" || bad "$n: 实得 $(fin "$o" pdg-mitm)"
  # ④ 已加载配置: 配置消费者的进程被换过(InvocationID 变了)
  [[ "$(cat "$SC/mosdns.inv")" != "INV-mosdns-orig" ]] && ok "$n: mosdns 的进程被换过(恢复出来的配置有被重新读)" || bad "$n: mosdns 仍是原进程"
  # ⑤ 报告与退出码
  grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && bad "$n: 切换失败却返回 0" || ok "$n: 返回非 0"
  grep -q '按本次快照恢复到切换前' <<<"$(plain "$o")" && ok "$n: 报告说明了走的是快照整体恢复" || bad "$n: 报告没说清"
}


note(){ echo "[NOTE] $1"; }

# 现场: iOS 机器, 退役件齐全。切 Android 时 migrate_android_cleanup 先把退役件撤掉
# (⇒ _PDG_RETIRE_DONE=1), 随后在**平台组件清理之后**的第一处可失败步骤(_switchcore_nft)
# 失败 —— 这正是 e2e-platform-switch.sh §6 注入所命中的位置。
# 甲 与 乙 的前向失败**完全相同**, 唯一差别是恢复自己要用的 `nft -c` 正不正常。
setup_i2a(){ seed_machine ios; }
snap_ios_files(){ sha256sum /opt/pdg-bot/mitm_ca.py /opt/pdg-bot/iosprofile.py \
                            /opt/pdg-bot/iosstate.py /opt/pdg-bot/pdg-dot.mobileconfig.tmpl 2>/dev/null | sha256sum; }

echo "══ 甲. 只让前向失败, **恢复条件正常**(nft -c 正常) ══"
setup_i2a
IOS_SHA_BEFORE="$(snap_ios_files)"
PLAT_BEFORE="$(cat /etc/privdns-gateway/platform)"
PROF_BEFORE="$(sha256sum /etc/privdns-gateway/profile.env | awk '{print $1}')"
UNIT_SHA_BEFORE="$(sha256sum /etc/systemd/system/pdg-mitm.service 2>/dev/null | awk '{print $1}')"
d="$WORK/ok"; mkdir -p "$d"
o="$(NFT_C_FAIL=0 run_platform android fail "$d")"; p="$(plain "$o")"
exec_valid "$o" "甲"
grep -q 'PLAT_RC=0' <<<"$p" && bad "甲0: 切换竟然成功了 —— 失败条件没到达" || ok "甲0: 切换返回非 0"
[[ -f "$d/stage-proof" ]] && grep -q 'unit=gone' "$d/stage-proof" \
  && ok "甲1: 阶段成立 —— 失败发生在退役件**已经撤除之后**($(cat "$d/stage-proof"))" \
  || bad "甲1: 没到达那个阶段($(cat "$d/stage-proof" 2>/dev/null || echo 未生成))"
grep -q '本次已经撤除过退役件/推进过记录格式' <<<"$p" && ok "甲2: 善后走「已经撤除过退役件」那一支" || bad "甲2"
grep -q '已按本次快照恢复到切换前' <<<"$p" && ok "甲3: 恢复自报完成" || note "甲3: 恢复自报未完成(逐项看下面)"
[[ "$(cat /etc/privdns-gateway/platform)" == "$PLAT_BEFORE" ]] \
  && ok "甲4: **平台标记回到 $PLAT_BEFORE**" || bad "甲4: 平台标记停在 $(cat /etc/privdns-gateway/platform)"
[[ "$(sha256sum /etc/privdns-gateway/profile.env | awk '{print $1}')" == "$PROF_BEFORE" ]] \
  && ok "甲5: profile.env 逐字节回到前像" || bad "甲5: profile.env 与前像不同($(cat /etc/privdns-gateway/profile.env 2>/dev/null | head -1))"
[[ "$(snap_ios_files)" == "$IOS_SHA_BEFORE" ]] \
  && ok "甲6: **被清理的 iOS 组件逐字节放回**(mitm_ca/iosprofile/iosstate/模板)" || bad "甲6: iOS 组件没恢复"
[[ "$(sha256sum /etc/systemd/system/pdg-mitm.service 2>/dev/null | awk '{print $1}')" == "$UNIT_SHA_BEFORE" ]] \
  && ok "甲7: pdg-mitm unit 逐字节回来了" || bad "甲7: unit 没回来"
[[ -e /opt/pdg-bot/mitm_server.py && -e /opt/pdg-bot/mitm_wloc.py ]] \
  && ok "甲8: 两个 MITM 模块也回来了" || bad "甲8: MITM 模块没回来"
[[ "$(cat "$SC/pdg-mitm.ac" 2>/dev/null)" == active ]] && ok "甲9: pdg-mitm 回到运行态" || bad "甲9: pdg-mitm=$(cat "$SC/pdg-mitm.ac" 2>/dev/null)"

echo
echo "══ 乙. 前向失败相同, 但**恢复条件也故障**(复刻 §6: nft -c 一律失败) ══"
setup_i2a
IOS_SHA_BEFORE2="$(snap_ios_files)"
d="$WORK/broken"; mkdir -p "$d"
o="$(NFT_C_FAIL=1 run_platform android fail "$d")"; p="$(plain "$o")"
exec_valid "$o" "乙"
grep -q 'PLAT_RC=0' <<<"$p" && bad "乙0: 切换竟然成功了" || ok "乙0: 切换返回非 0"
[[ -f "$d/stage-proof" ]] && grep -q 'unit=gone' "$d/stage-proof" \
  && ok "乙1: 同样到达「退役件已撤除」之后" || bad "乙1: 阶段不同, 两组不可比"
grep -q '快照的 nftables 语法错, 中止' <<<"$p" \
  && ok "乙2: 恢复在**落盘之前**按设计中止 —— 它自己的 nft -c 安全门也被这次注入挡住了" \
  || note "乙2: 没看到那条中止提示(实际输出见证据)"
grep -q '已按本次快照恢复到切换前' <<<"$p" && bad "乙3: 穿不过持续故障却宣称完整恢复" || ok "乙3: **没有**宣称完整恢复"
grep -q '恢复未完成' <<<"$p" && ok "乙4: 明说恢复未完成" || bad "乙4: 没有如实报告未完成"
grep -qE '新增文件清单: |局部备份    : |本次快照    : ' <<<"$p" && ok "乙5: 保留材料并给出可定位路径" || bad "乙5: 没给材料路径"
if [[ "$(snap_ios_files)" == "$IOS_SHA_BEFORE2" ]]; then
  note "乙6: iOS 组件仍回到了前像 —— 说明这次注入没挡住这一部分"
else
  ok "乙6: iOS 组件**没有**回来 —— 与「恢复在落盘前中止」一致, 而产品已如实报告未完成"
fi

echo
echo "──────── 判读 ────────"
cat <<'NOTE'
  · 甲 与 乙 的前向失败完全相同(同一处 _switchcore_nft 失败, 同一条调用链),
    唯一差别是恢复自己要用的 `nft -c` 正不正常。
  · 甲 全绿 ⇒ 恢复条件正常时, iOS→Android 失败后平台标记、profile.env、iOS 组件、
    退役件与服务都能回到前像。
  · 乙 的现象与 e2e-platform-switch.sh §6 一致: 恢复在**落盘之前**被它自己的
    `nft -c` 安全门挡住并中止(现网零改动), 产品如实报"恢复未完成"、非零退出、保留材料。
  ⇒ §6 的 6c/6d 是在**注入仍然生效**的前提下要求"完整恢复" —— 与产品的安全设计冲突。
    这是**注入范围**的问题, 不是恢复漏做。本轮不删 6c/6d, 也不改产品。
NOTE
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

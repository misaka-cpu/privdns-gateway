#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 平台切换: **退役件已经撤除之后**才失败, 善后到底把东西还回来了没有。
#
# 为什么单独一支: cmd_platform 现在会存快照与服务前像, 但"存下来"不等于"失败时会用"。
# 原来的 _plat_rollback 只认四个 iOS 文件, 名单里**没有** pdg-mitm.service、mitm_server.py、
# mitm_wloc.py —— 而那三样正是 _plat_purge_retired / migrate_android_cleanup 删掉的。
# 于是"有快照、有前像、门放行"三件事凑在一起, 也不等于这个调用方具备可靠恢复能力。
#
# 跑的是**真实** cmd_platform → 真实清理 → 真实失败善后 → 真实 cmd_rollback, 不是单独调清理。
# 隔离: unshare 私有挂载, /etc /opt /usr/local/bin 绑到一次性目录; 宿主一动不动。
# 建不出隔离就报"未执行"并非 0 退出, 不靠权限失败兜底。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── 隔离入口 ────────────────────────────────────────────────────────────────
# 三段式: 未进隔离(变量空) → 进了 unshare(=1) → 进了 bwrap(=2)。
# 最外层判据必须是"变量为空", 不能写成 `!= 1` —— bwrap 那条回退路径会把变量设成 2,
# 用 `!= 1` 判就会**再进一次初始化分支**, 变成递归入口。
# 自有根一建出来就先挂上清理; 交接给 exec 出去的进程时再撤掉(那边有自己的清理)。
if [[ -z "${PDG_PLAT_NS:-}" ]]; then
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
    export PDG_PLAT_NS=1; trap - EXIT      # 所有权交给下面 exec 出去的那个进程
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  elif bwrap --version >/dev/null 2>&1; then   # 看它**能不能用**, 不只是 PATH 里有
    export PDG_PLAT_NS=2; trap - EXIT
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
if [[ "${PDG_PLAT_NS}" == 1 ]]; then
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
nft(){ return 0; }'

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
    echo '  tar czf "$s/snap.tar.gz" -C / etc/privdns-gateway etc/systemd/system etc/mosdns etc/mihomo opt/pdg-bot 2>/dev/null'
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
    # 自启恢复现在由 _pdg_set_enable_state 一处负责(持久/运行时两层要分别撤) —— 抽真身, 不补替代实现。
    _fnN "$src" _pdg_set_enable_state
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

echo "══ 一. iOS ← Android 方向: 退役件撤除之后失败 ══"
seed_machine android; d="$WORK/ios"; mkdir -p "$d"
o="$(run_platform ios fail "$d")"
exec_valid "$o" "A"
check_dir "$o" "$d" "A" android

echo
echo "══ 二. Android ← iOS 方向: 退役件撤除之后失败 ══"
seed_machine ios; d="$WORK/android"; mkdir -p "$d"
o="$(run_platform android fail "$d")"
exec_valid "$o" "B"
check_dir "$o" "$d" "B" ios

echo
echo "══ 三. 正常切换 / 干净机器 / 幂等 ══"
seed_machine android; d="$WORK/okios"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; p="$(plain "$o")"
exec_valid "$o" "C"
grep -q 'PLAT_RC=0' <<<"$p" && ok "C1: 正常切换仍然成功" || { bad "C1: $(grep -o 'PLAT_RC=.*' <<<"$p")"; grep -vE '^FINAL' <<<"$p" | head -20 | sed 's/^/      /'; }
[[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "C2: 平台标记确实切到了 ios" || bad "C2"
d="$WORK/okios2"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && ok "C3: 同方向再切一次(幂等)仍然成功" || bad "C3"
# 干净机器: 没有任何退役件
rm -f /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
printf '{"wloc": {"enabled": false}}\n' > /etc/privdns-gateway/mitm.json
d="$WORK/clean"; mkdir -p "$d"
o="$(run_platform android nofail "$d")"; grep -q 'PLAT_RC=0' <<<"$(plain "$o")" && ok "C4: 已经清干净的机器切换照常成功" || bad "C4"

echo
echo "══ 四. 撤销对照: 失败善后退回只用局部还原 ══"
REV="$WORK/pdg-rev-plat.sh"
awk '/^  _plat_fail_restore\(\)\{/{print "  _plat_fail_restore(){ _plat_rollback; return; }"; skip=1; next}
     skip && /^  \}$/{skip=0; next} !skip{print}' "$PDG" > "$REV"
if cmp -s "$PDG" "$REV" || ! bash -n "$REV" 2>/dev/null; then
  bad "D0: 没造出反向副本 —— 本格记无效"
else
  ok "D0: 反向副本就位(失败善后只走 _plat_rollback)"
  seed_machine android; d="$WORK/rev"; mkdir -p "$d"
  o="$(run_platform ios fail "$d" "$REV")"
  [[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "D1: 局部还原补不回 pdg-mitm.service —— 这正是原来的现场" || bad "D1: 反向对照没体现差异"
  [[ ! -e /opt/pdg-bot/mitm_server.py ]] && ok "D2: 也补不回 mitm_server.py" || bad "D2: 反向对照没体现差异"
fi

echo
echo "══ 五. 恢复动作自身失败: 不能被后续成功盖过去 ══"
# 确定性反例: 退役件已经撤除, 随后失败; 恢复时**只让一项本次新增文件删不掉**
# (把它变成非空目录, rm -f 必然 EISDIR), 而快照恢复本身正常成功。
seed_machine android
# 让 pdg-dot.mobileconfig.tmpl 成为"**本次新增**"的那一件(切换前盘上没有它)。
rm -f /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
d="$WORK/delfail"; mkdir -p "$d"
o="$(run_platform ios fail-delete "$d")"; p="$(plain "$o")"
exec_valid "$o" "E"
grep -q 'PLAT_RC=0' <<<"$p" && bad "E1: 切换失败却返回 0" || ok "E1: 返回非 0"
grep -q '已按本次快照恢复到切换前' <<<"$p" && bad "E2: 有东西没删掉却仍宣称完整恢复" || ok "E2: **没有**宣称完整恢复"
grep -q '恢复未完成' <<<"$p" && ok "E3: 明说恢复未完成" || bad "E3"
grep -q '/opt/pdg-bot/pdg-dot.mobileconfig.tmpl' <<<"$p" && ok "E4: 没能删掉的那个文件被**具名**列出" || { bad "E4"; grep -vE '^FINAL' <<<"$p" | tail -16 | sed 's/^/      /'; }
grep -qE '快照恢复: (已完成|\*\*未完成\*\*)' <<<"$p" \
  && ok "E5: 原始操作失败与恢复失败分开报($(grep -o '快照恢复: .*' <<<"$p" | head -1))" || bad "E5"
grep -qE '新增文件清单: .*/newfiles' <<<"$p" && ok "E6: 打出了新增文件清单的可定位路径" || bad "E6"
[[ -d "$(sed -n 's/.*局部备份    : \(.*\)$/\1/p' <<<"$p" | tail -1)" ]] \
  && ok "E7: 局部备份目录**确实还在**(恢复不完整时保留材料)" || bad "E7: 材料被删了"
[[ -e /opt/pdg-bot/pdg-dot.mobileconfig.tmpl ]] && ok "E8: 那个删不掉的东西确实还在盘上(与报告一致)" || bad "E8"
# 四维分别核验(不看输出、不看退出码)
f=/etc/systemd/system/pdg-mitm.service
[[ -e "$f" ]] && ok "E9a: 存在性: pdg-mitm.service 回来了" || bad "E9a"
[[ "$(tail -1 "$f" 2>/dev/null)" == "Description=pdg-mitm ORIG" ]] && ok "E9b: 内容: 与快照一致" || bad "E9b: $(tail -1 "$f" 2>/dev/null)"
[[ "$(stat -c %a "$f" 2>/dev/null)" == 644 ]] && ok "E9c: mode: 644" || bad "E9c: $(stat -c %a "$f" 2>/dev/null)"
[[ "$(stat -c '%u:%g' "$f" 2>/dev/null)" == "0:0" ]] && ok "E9d: uid:gid: 0:0(与打包时一致)" || bad "E9d: $(stat -c '%u:%g' "$f" 2>/dev/null)"

echo
echo "══ 六. WLOC/schema 在可恢复阶段内: 失败必须传播 ══"
# 现场: 没有退役模块、没有 unit, 只有一份 schema-1 记录需要处理。
# 这份记录**故意是坏的** —— 真实代码会按"记录格式/字段白名单"合法拒绝。本支不把这种拒绝
# 改成放行, 只验它**传不传得出去**: 以前它落在 `rm -rf $wd` 之后、又被 `|| true` 吞掉。
# (一份**结构完好**的 schema-1 记录还要配套产物与摘要, 那一格由 tests/test-wloc-retire-schema.py 覆盖。)
seed_machine android
rm -f /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
printf '{"wloc": {"enabled": false}}\n' > /etc/privdns-gateway/mitm.json
: > /etc/mosdns/rules/mitm_hijack.txt
mkschema1_bad /etc/privdns-gateway/ios-profile.json
d="$WORK/schemafail"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; p="$(plain "$o")"
exec_valid "$o" "F"
grep -q 'PLAT_RC=0' <<<"$p" && bad "F1: schema 那一步失败, 切换却返回 0" || ok "F1: 返回非 0"
grep -q '平台已确认' <<<"$p" && bad "F2: 仍然打印了「平台已确认」" || ok "F2: **没有**打印「平台已确认」"
grep -q 'WLOC 退役迁移未完成' <<<"$p" && ok "F3: 明说卡在 WLOC 退役迁移这一步" || bad "F3"
[[ "$(python3 -c 'import json;print(json.load(open("/etc/privdns-gateway/ios-profile.json")).get("schema"))' 2>/dev/null)" == 1 ]] \
  && ok "F4: 记录仍是 schema 1 —— 坏记录被拒就是被拒, 没有被「迁移」过去" || bad "F4"
grep -qE '改用本次快照做整体恢复|已恢复.?原平台' <<<"$p" && ok "F5: 走了恢复路径(不是失败后原地不动)" || bad "F5"
[[ "$(cat /etc/privdns-gateway/platform)" == android ]] && ok "F6: 平台标记回到 android" || bad "F6: $(cat /etc/privdns-gateway/platform)"

echo
echo "══ 七. 成功路径按原样清理; 末尾迁移链真的跑了 ══"
seed_machine android; rm -f /etc/privdns-gateway/ios-profile.json
d="$WORK/okclean"; mkdir -p "$d"
o="$(run_platform ios nofail "$d")"; p="$(plain "$o")"
exec_valid "$o" "G"
grep -q 'PLAT_RC=0' <<<"$p" && ok "G1: 正常切换返回 0" || { bad "G1"; grep -vE '^FINAL' <<<"$p" | tail -12 | sed 's/^/      /'; }
[[ -s "$d/mig.log" ]] && ok "G2: run_all_migrations **真的执行了**($(grep -c . "$d/mig.log") 支幂等迁移被点到)" \
  || bad "G2: 末尾迁移链没跑起来 —— 壳里没装它, 或者被 || true 吞了"
grep -q 'MIGRATE-NOOP migrate_drop_singbox' "$d/mig.log" && ok "G3: 链尾那几支也点到了(不是只跑了前半截)" || bad "G3"
grep -q '材料保留在' <<<"$p" && bad "G4: 成功路径却进了「保留材料」分支" \
  || ok "G4: 成功路径没有保留材料(只有恢复不完整时才留)"

echo
echo "══ 八. 撤销对照: 把本轮两处修复分别撤回 ══"
# ① 恢复动作失败不再累计 → "有东西没删掉却仍宣称完整恢复"当场回来
REV1="$WORK/pdg-rev-acct.sh"
python3 - "$PDG" "$REV1" <<'PYREV'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = """        rm -f "$nf" 2>/dev/null
        [[ -e "$nf" || -L "$nf" ]] && left+=("$nf")"""
b = """        rm -f "$nf" 2>/dev/null"""
assert s.count(a) == 1
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(a, b, 1))
PYREV
if ! bash -n "$REV1" 2>/dev/null || cmp -s "$PDG" "$REV1"; then
  bad "H0: 没造出「不累计删除失败」的反向副本 —— 本格记无效"
else
  ok "H0: 反向副本就位(只删掉「删不掉就记一笔」那一行)"
  seed_machine android; rm -f /opt/pdg-bot/pdg-dot.mobileconfig.tmpl
  d="$WORK/revacct"; mkdir -p "$d"
  o="$(run_platform ios fail-delete "$d" "$REV1")"; p="$(plain "$o")"
  exec_valid "$o" "H"
  grep -q '已按本次快照恢复到切换前' <<<"$p" \
    && ok "H1: 撤回之后, 有东西没删掉却仍**宣称完整恢复** —— E2 确实由这处修复保住" \
    || bad "H1: 反向对照没体现差异 —— 本格记无效"
  [[ -e /opt/pdg-bot/pdg-dot.mobileconfig.tmpl ]] \
    && ok "H2: 而那个东西确实还在盘上(宣称与现场不符)" || bad "H2: 反向对照无效"
fi

# ② WLOC/schema 挪回 `rm -rf $wd` 之后、`|| true` 里 → "schema 失败却报成功"当场回来
REV2="$WORK/pdg-rev-commit.sh"
python3 - "$PDG" "$REV2" <<'PYREV'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = """  if ! migrate_wloc_retire; then
    echo "❌ WLOC 退役迁移未完成(详见上方), 平台切换回退"
    _plat_fail_restore; return 1
  fi
  rm -rf "$wd\""""
b = """  rm -rf "$wd\""""
assert s.count(a) == 1, s.count(a)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(a, b, 1))
PYREV
if ! bash -n "$REV2" 2>/dev/null || cmp -s "$PDG" "$REV2"; then
  bad "I0: 没造出「WLOC 挪回末尾」的反向副本 —— 本格记无效"
else
  ok "I0: 反向副本就位(只把 WLOC 那一步挪回 rm -rf \$wd 之后的 || true 里)"
  seed_machine android
  rm -f /etc/systemd/system/pdg-mitm.service /opt/pdg-bot/mitm_server.py /opt/pdg-bot/mitm_wloc.py
  printf '{"wloc": {"enabled": false}}\n' > /etc/privdns-gateway/mitm.json
  : > /etc/mosdns/rules/mitm_hijack.txt
  mkschema1_bad /etc/privdns-gateway/ios-profile.json
  d="$WORK/revcommit"; mkdir -p "$d"
  o="$(run_platform ios nofail "$d" "$REV2")"; p="$(plain "$o")"
  exec_valid "$o" "I"
  grep -q 'PLAT_RC=0' <<<"$p" && ok "I1: 撤回之后, schema 那一步失败**仍然返回 0** —— F1 确实由这处修复保住" || bad "I1: 反向对照没体现差异"
  grep -q '平台已确认' <<<"$p" && ok "I2: 且照样打印了「平台已确认」" || bad "I2: 反向对照无效"
  [[ "$(cat /etc/privdns-gateway/platform)" == ios ]] && ok "I3: 平台停在 ios(失败没有被恢复)" || bad "I3"
fi

echo
echo "══ 九. 隔离入口本身 ══"
grep -q 'if \[\[ -z "${PDG_PLAT_NS:-}" \]\]; then' "$HERE/$(basename "${BASH_SOURCE[0]}")" \
  && ok "J1: 最外层判据是「变量为空」, bwrap 那条回退路径(=2)不会再进初始化分支" || bad "J1"
# 判据自身不能匹配自身: 只看**非注释、非 grep** 的行里有没有往 /etc 写东西。
if grep -vE '^[[:space:]]*(#|grep)' "$HERE/$(basename "${BASH_SOURCE[0]}")" | grep -qE '>[[:space:]]*/etc/'; then
  bad "J2: 还在往宿主路径写探针来判断隔离"
else ok "J2: 隔离自检是只读的(比 dev:inode, 不写探针)"; fi
# 行为: 预置 NS=2 且给一个没挂载的自有根 → 必须以"未执行"退出, 不递归、不冒充通过
_probe="$WORK/nsprobe"; mkdir -p "$_probe/etc" "$_probe/opt" "$_probe/usr/local/bin" "$_probe/run"
_out="$(PDG_PLAT_NS=2 FAKE="$_probe" timeout 30 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" 2>&1)"; _rc=$?
if [[ "$_rc" == 124 ]]; then bad "J3: 预置 NS=2 时超时 —— 递归入口还在"
elif grep -q '未执行' <<<"$_out" && [[ "$_rc" != 0 ]]; then ok "J3: 预置 NS=2 且未挂载 → 报「未执行」并非 0 退出(rc=$_rc), 没有递归"
else bad "J3: rc=$_rc, 输出: $(head -2 <<<"$_out" | tr '\n' ' ')"; fi
# 行为: 屏蔽 unshare/bwrap → 必须明确未执行并非 0
mkdir -p "$WORK/shim"; ln -sf /bin/false "$WORK/shim/unshare"; ln -sf /bin/false "$WORK/shim/bwrap"
# 要把 PDG_PLAT_NS/FAKE 一起摘掉 —— 不然子进程以为自己已经在隔离里, 会直接跑整套用例。
_out="$(env -u PDG_PLAT_NS -u FAKE PATH="$WORK/shim:$PATH" timeout 30 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" 2>&1)"; _rc=$?
if grep -q '建不出挂载隔离' <<<"$_out" && [[ "$_rc" != 0 ]]; then ok "J4: 没有 unshare/bwrap 时明确「未执行」并非 0 退出(rc=$_rc)"
else bad "J4: rc=$_rc, 输出: $(head -2 <<<"$_out" | tr '\n' ' ')"; fi

echo
echo "──────── 本支仍被替换的产品函数, 以及因此未覆盖的性质 ────────"
cat <<'NOTE'
  cmd_snapshot            → 未覆盖: 快照清单裁剪与元数据写入(材料本身是真打的 tar)
  _plat_write_profile     → 未覆盖: profile.env 的真实渲染内容
  migrate_probe81_public / migrate_ios_gms_cleanup / _plat_verify → 未覆盖: 这三步自身的判据
  _switchcore_nft         → 被用作失败注入点; 未覆盖: 防火墙按平台重建
  mihomo / nft            → 未覆盖: 真实 mihomo -t 校验与真实 nft 装载
  /opt/pdg-bot/bot.py     → 本支放的是**最小但真**的渲染器(产品原文的 _retire_rerender_core
                            会对它的产物做空产出/MITM-OUT/mihomo -t/属性跟随/原子替换/重启核验);
                            未覆盖: 真实 bot.py 的分流与 hosts 段渲染
  (python3 **没有**打桩: 记录格式迁移与渲染都真跑; iosstate.py / pdgtx.py / iosprofile.py /
   mitm_ca.py 用的是仓库里的真文件)
  need_root / _lock       → 未覆盖: 真实取锁
  _pdg_bot_cred / _core_kernel_stable / _pdg_svc_stable / _pdg_nft_ok / doctor
                          → 未覆盖: 切换后的稳定性与自检判据(由 test-platform-install.sh 覆盖)
  systemctl               → 未覆盖: 真实 systemd 的状态机与时序
  ⇒ 这一支证明的是**失败善后把不把东西还回来**, 不是真实 systemd 行为。
NOTE
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

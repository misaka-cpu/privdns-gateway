#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 组合验证: **合法**旧记录 → 平台切换 → schema 真正推进 → 失败善后选中整体恢复 →
# 记录与产物恢复。
#
# 为什么单独一支: 平台那支用的是**坏**记录(证明"真实校验的拒绝能传给调用方"),
# schema 单测证明"格式转换本身对不对"。两者都没覆盖"合法旧记录被真正推进之后, 失败善后
# 能不能把记录与产物一起还回来"。
#
# 现场刻意只剩记录/产物待迁移: 退役 unit 与执行模块都不在、服务不在跑、劫持表空、
# 内核配置里没有 MITM-OUT —— 这样 _PDG_RETIRE_DONE 只可能由**这一次 schema 推进**置上,
# 不会借到模块清理留下的记号。这几条前提在关键阶段直接确认, 不靠推断。
#
# 旧记录与产物用 tests/wloc_legacy_fixture.py 造(那一份是从 test-wloc-retire-schema.py
# 原样提取出来的), 并且在用之前先过**产品自己的 schema-1 校验门**自证合法。
# 证书是本用例现场自签的测试 CA; 不恢复任何生产签发入口, 不使用真实用户证书或描述文件。
#
# 隔离: unshare 私有挂载, /etc /opt /usr/local/bin /run /var 绑到一次性目录。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── 隔离入口 ────────────────────────────────────────────────────────────────
# 三段式: 未进隔离(变量空) → 进了 unshare(=1) → 进了 bwrap(=2)。
# 最外层判据必须是"变量为空", 不能写成 `!= 1` —— bwrap 那条回退路径会把变量设成 2,
# 用 `!= 1` 判就会**再进一次初始化分支**, 变成递归入口。
# 自有根一建出来就先挂上清理; 交接给 exec 出去的进程时再撤掉(那边有自己的清理)。
if [[ -z "${PDG_SCHEMA_NS:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FAKE="$(mktemp -d)" || { echo "[未执行] 建不出自有根"; exit 1; }
  trap 'rm -rf "$FAKE"' EXIT          # 这一段里任何退出路径都归它清
  mkdir -p "$FAKE/etc/privdns-gateway" "$FAKE/etc/systemd/system" "$FAKE/etc/mosdns/rules" \
           "$FAKE/etc/mihomo" "$FAKE/opt/pdg-bot" "$FAKE/usr/local/bin" "$FAKE/run" "$FAKE/var/lib/privdns-gateway/ios-profile" \
    || { echo "[未执行] 自有根建不全"; exit 1; }
  # /etc 整个被换掉会让走 /etc/alternatives 的命令(awk)消失, 先把必需的几样放进去。
  cp -a /etc/alternatives "$FAKE/etc/" 2>/dev/null
  for _f in passwd group nsswitch.conf localtime hosts resolv.conf; do cp -a "/etc/$_f" "$FAKE/etc/" 2>/dev/null; done
  # openssl 要读 /etc/ssl/openssl.cnf —— /etc 整个换掉之后它就不在了, 现场签测试 CA 会失败。
  cp -a /etc/ssl "$FAKE/etc/" 2>/dev/null
  export FAKE
  if unshare --map-root-user --mount --propagation private true 2>/dev/null; then
    export PDG_SCHEMA_NS=1; trap - EXIT      # 所有权交给下面 exec 出去的那个进程
    exec unshare --map-root-user --mount --propagation private bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  elif bwrap --version >/dev/null 2>&1; then   # 看它**能不能用**, 不只是 PATH 里有
    export PDG_SCHEMA_NS=2; trap - EXIT
    exec bwrap --dev-bind / / --bind "$FAKE/etc" /etc --bind "$FAKE/opt" /opt \
               --bind "$FAKE/usr/local/bin" /usr/local/bin --bind "$FAKE/run" /run --bind "$FAKE/var" /var \
               -- bash "$HERE/$(basename "${BASH_SOURCE[0]}")" "$@"
  fi
  echo "[未执行] 建不出挂载隔离(没有可用的 unshare/bwrap)。"
  echo "         这一支会让真实 cmd_platform 会往 /etc /opt /usr/local/bin 落盘, 没有自有根就不能跑 ——"
  echo "         不靠权限失败兜底, 也不冒充通过。"
  exit 1
fi
# 进到这里说明已经在隔离里。先把清理挂上, 再做挂载 —— 挂载失败也有人负责清。
trap 'rm -rf "${WORK:-}" "$FAKE"' EXIT
if [[ "${PDG_SCHEMA_NS}" == 1 ]]; then
  mount --bind "$FAKE/etc" /etc || { echo "[未执行] 绑定 /etc 失败"; exit 1; }
  mount --bind "$FAKE/opt" /opt || { echo "[未执行] 绑定 /opt 失败"; exit 1; }
  mount --bind "$FAKE/usr/local/bin" /usr/local/bin || { echo "[未执行] 绑定 /usr/local/bin 失败"; exit 1; }
  mount --bind "$FAKE/run" /run || { echo "[未执行] 绑定 /run 失败"; exit 1; }
  mount --bind "$FAKE/var" /var || { echo "[未执行] 绑定 /var 失败"; exit 1; }
fi
# 隔离自检: **只读**核实归属 —— 比 /etc 与自有根里那一份的 dev:inode 是不是同一个。
# 不往宿主路径写探针: 真要没隔离住, 那一笔就落到宿主上了, 判据本身成了事故。
for _m in etc opt usr/local/bin run var; do
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
command -v openssl >/dev/null 2>&1 || { echo "[未执行] 没有 openssl, 造不出测试 CA"; exit 1; }

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

TMPL="$ROOT/deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl"

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

# 造一台「只剩记录/产物待迁移」的机器。$1=wloc(带 CA)|nowloc(不带 CA)
seed_machine(){
  local kind="$1"
  rm -rf /etc/privdns-gateway /etc/systemd/system /etc/mosdns /etc/mihomo /opt/pdg-bot \
         /var/lib/privdns-gateway
  mkdir -p /etc/privdns-gateway /etc/systemd/system /etc/mosdns/rules /etc/mihomo \
           /opt/pdg-bot /var/lib/privdns-gateway/ios-profile
  printf 'android\n' > /etc/privdns-gateway/platform
  printf 'PROFILE-ORIG\n' > /etc/privdns-gateway/profile.env; chmod 640 /etc/privdns-gateway/profile.env
  printf '{"wloc": {"enabled": false}}\n' > /etc/privdns-gateway/mitm.json
  : > /etc/mosdns/rules/mitm_hijack.txt
  printf 'mixed-port: 7890\nproxies: []\nrules:\n  - MATCH,DIRECT\n' > /etc/mihomo/config.yaml
  local m
  for m in iosprofile.py iosstate.py mitm_ca.py pdgtx.py; do cp -a "$ROOT/deploy/bot/$m" /opt/pdg-bot/; done
  write_fake_bot
  local f; for f in $U_ALL; do set_u "$f" enabled active; done
  set_u pdg-mitm not-found inactive          # 退役 unit 根本不在
  rm -f "$SC/pdg-mitm.en"                    # is-enabled → not-found
  # 旧记录 + 产物: 用提取出来的夹具造
  local gen="$WORK/gen-$kind"; rm -rf "$gen"; mkdir -p "$gen"
  local args=(--modules /opt/pdg-bot --tmpl "$TMPL" --out "$gen" --ssid home --ssid office)
  [[ "$kind" == wloc ]] && args+=(--wloc)
  FIXINFO="$(python3 "$HERE/wloc_legacy_fixture.py" "${args[@]}")" || return 1
  cp -a "$gen/ios-profile.json" /etc/privdns-gateway/ios-profile.json
  chmod 600 /etc/privdns-gateway/ios-profile.json
  cp -a "$gen"/art/. /var/lib/privdns-gateway/ios-profile/
  echo "$FIXINFO" > "$WORK/fixinfo-$kind.json"
}

# 读盘上的记录/产物, 打一份可比对的摘要
inspect(){
  python3 - <<'INS'
import hashlib, json, os, sys
sys.path.insert(0, "/opt/pdg-bot")
import iosstate as S
sys.path.insert(0, os.environ.get("FIXDIR", ""))
import wloc_legacy_fixture as F
mp = "/etc/privdns-gateway/ios-profile.json"
ar = "/var/lib/privdns-gateway/ios-profile"
try:
    m = json.load(open(mp, encoding="utf-8"))
except Exception as e:                                    # noqa: BLE001
    print(json.dumps({"error": str(e)})); raise SystemExit(0)
cur, prev = m.get("current"), m.get("previous")
def art(n):
    p = os.path.join(ar, n)
    if not os.path.exists(p):
        return {"exists": False}
    b = open(p, "rb").read()
    st = os.stat(p)
    return {"exists": True, "sha256": hashlib.sha256(b).hexdigest(),
            "mode": oct(st.st_mode & 0o7777), "uid": st.st_uid, "gid": st.st_gid,
            "has_ca": F.has_ca(p)}
print(json.dumps({
    "schema": m.get("schema"), "instance_id": m.get("instance_id"),
    "cur_rev": (cur or {}).get("revision"), "prev_rev": (prev or {}).get("revision"),
    "cur_ssids": ((cur or {}).get("inputs") or {}).get("ssids"),
    "cur_wloc": ((cur or {}).get("inputs") or {}).get("wloc_enabled"),
    "cur_ca_sha": ((cur or {}).get("inputs") or {}).get("wloc_ca_sha256"),
    "cur_digest": (cur or {}).get("digest"),
    "meta_mode": oct(os.stat(mp).st_mode & 0o7777),
    "meta_uid": os.stat(mp).st_uid, "meta_gid": os.stat(mp).st_gid,
    "retired_revision": m.get("retired_revision"),
    "retired_ssids": (m.get("retired_inputs") or {}).get("ssids"),
    "art_cur": art(S.CUR), "art_prev": art(S.PREV),
}, ensure_ascii=False))
INS
}
jqf(){ python3 -c 'import json,sys;d=json.load(sys.stdin);k=sys.argv[1].split(".");v=d
for x in k: v=(v or {}).get(x) if isinstance(v,dict) else None
print(json.dumps(v,ensure_ascii=False) if not isinstance(v,str) else v)' "$1"; }

# 前像自证: 用**产品自己**的 schema-1 校验门验一遍
selfproof(){
  python3 - <<'SP'
import json, sys
sys.path.insert(0, "/opt/pdg-bot")
import iosstate as S
mp = "/etc/privdns-gateway/ios-profile.json"
ar = "/var/lib/privdns-gateway/ios-profile"
m = json.load(open(mp, encoding="utf-8"))
try:
    S._check_meta_object(m, schema=1)
    ids = S.derive_ids(m["instance_id"])
    for which in ("current", "previous"):
        if m.get(which) is None:
            continue
        data = open(S.art_path(which, ar), "rb").read()
        S._check_artifact(m, which, data, ids, schema=1)
except Exception as e:                                    # noqa: BLE001
    print("REFUSED %s" % e); raise SystemExit(1)
print("OK")
SP
}

# 真实 cmd_platform 的运行壳。$1=目标平台 $2=nofail|boundary-fail $3=场景目录 [$4=被测 pdg.sh]
run_platform(){
  local tgt="$1" mode="$2" d="$3" src="${4:-$PDG}"
  mkdir -p "$d/snaps"
  local repo="$WORK/repo"
  if [[ ! -d "$repo" ]]; then
    mkdir -p "$repo/deploy/ios" "$repo/deploy/bot"
    cp -a "$TMPL" "$repo/deploy/ios/"
    local m; for m in iosprofile.py iosstate.py mitm_ca.py; do cp -a "$ROOT/deploy/bot/$m" "$repo/deploy/bot/"; done
  fi
  { echo 'set -uo pipefail'
    echo "SC_DIR=\"$SC\"; SC_LOG=\"$d/sc.log\"; SC_CHG=\"$d/sc.chg\"; MIG_LOG=\"$d/mig.log\""
    echo "BOUNDARY=\"$d/boundary\""
    echo ': > "$SC_LOG"; : > "$SC_CHG"; : > "$MIG_LOG"'
    echo "$STUB"
    _fn1 "$src" c_g; _fn1 "$src" c_y; _fn1 "$src" c_r
    echo 'need_root(){ :; }; _lock(){ :; }'
    # 所有 migrate_* 先定成空转, 再把 WLOC 那一支换成产品原文(顺序: 空转在前, 原文在后)
    grep -oE '^migrate_[a-z0-9_]+\(\)\{' "$src" | sed 's/(){$//' | sort -u | while read -r _m; do
      [[ "$_m" == migrate_wloc_retire ]] && continue
      printf '%s(){ echo "MIGRATE-NOOP %s" >> "$MIG_LOG"; return 0; }\n' "$_m" "$_m"
    done
    echo "SNAP_DIR=\"$d/snaps\"; REPO_DIR=\"$repo\"; LOCK=\"$d/lock\""
    echo '_pdg_core(){ echo mihomo; }; _pdg_core_svc(){ echo mihomo; }; _pdg_mktemp_dir(){ mktemp -d; }'
    echo '_sb_panel_managed_on(){ return 1; }'
    echo 'pdg_write_unit(){ printf "[Unit]\n" > "$2"; return 0; }; pdg_unit_mihomo(){ echo "[Unit]"; }'
    echo '_pdg_drop_singbox_files(){ :; }; _pdg_singbox_is_ours(){ return 1; }'
    echo '_lan_rollback_converge(){ return 0; }; _nft_apply_main(){ return 0; }; _snap_meta_commit(){ echo ""; }'
    echo '_plat_write_profile(){ printf "PROFILE-%s\n" "$1" > /etc/privdns-gateway/profile.env; return 0; }'
    echo 'migrate_probe81_public(){ return 0; }; migrate_ios_gms_cleanup(){ return 0; }; _plat_verify(){ return 0; }'
    echo '_pdg_nft_bin(){ echo /bin/true; }; _pdg_required_svcs(){ echo mosdns; }'
    echo '_pdg_bot_cred(){ echo ready; }; _core_kernel_stable(){ return 0; }'
    echo '_switchcore_nft(){ return 0; }'
    echo 'mihomo(){ return 0; }'
    echo "cmd_snapshot(){ local s=\"$d/snaps/\$(date +%s%N)\"; mkdir -p \"\$s\""
    echo '  tar czf "$s/snap.tar.gz" -C / etc/privdns-gateway etc/systemd/system etc/mosdns etc/mihomo opt/pdg-bot var/lib/privdns-gateway/ios-profile 2>/dev/null'
    echo '  chmod 600 "$s/snap.tar.gz"; _PDG_SNAP_CREATED="$s"; return 0; }'
    # 产品原文
    grep -m1 '^_PDG_IOS_STATE_REL=' "$src"; grep -m1 '^_PDG_IOS_ART_REL=' "$src"
    grep -m1 '^_PDG_RETIRE_OK=' "$src"; grep -m1 '^_PDG_RETIRE_DONE=' "$src"
    _arr "$src" _PLAT_RETIRED; _arr "$src" _PLAT_IOS_REQUIRED
    local g; for g in _pdg_ios_group_in_members _pdg_ios_group_rels _pdg_ios_capture \
                      _pdg_ios_rollback _pdg_ios_reconcile _pdg_ios_verify_tree \
                      _pdg_apply_snapshot_tree _core_kernel_activate; do _fnN "$src" "$g"; done
    grep -q '^_pdg_kernel_converge(){' "$src" && _fnN "$src" _pdg_kernel_converge
    _fnN "$src" _pdg_svcstate_units; _fnN "$src" _pdg_svc_known; _fnN "$src" _pdg_svc_q
    _fnN "$src" _pdg_save_svcstate; _fnN "$src" _pdg_svcstate_valid
    grep -m1 '^declare -A _PDG_WANT_EN' "$src"
    grep -m1 '^_PDG_SVC_MODE=' "$src"; grep -m1 '^_PDG_SVC_WHY=' "$src"; grep -m1 '^_PDG_SVC_SRC=' "$src"
    _fnN "$src" _pdg_svcstate_plan; _fn1 "$src" _pdg_now_ac; _fn1 "$src" _pdg_now_en
    _fnN "$src" _pdg_restore_svcstate; _fnN "$src" cmd_rollback
    _fnN "$src" _pdg_lock_proof
    grep -m1 '^_RETIRE_UNDO=' "$src"; grep -m1 '^_RETIRE_TMP=' "$src"
    grep -oE '^_retire_[a-z0-9_]+\(\)\{' "$src" | sed 's/(){$//' | sort -u | while read -r _rf; do _fnN "$src" "$_rf"; done
    _fnN "$src" migrate_wloc_retire
    _fnN "$src" run_all_migrations
    _fnN "$src" _plat_purge_retired; _fnN "$src" _plat_deploy_ios; _fnN "$src" migrate_android_cleanup
    echo "_pdg_module(){ printf '%s\n' \"/opt/pdg-bot/\$1\"; }"
    echo '_pdg_platform(){ cat /etc/privdns-gateway/platform 2>/dev/null; }'
    _fnN "$src" cmd_platform
    if [[ "$mode" == boundary-fail ]]; then
      # ★ 受控边界故障注入 ★
      # 产品里 schema 成功之后到"平台已确认"之间**没有**可失败的步骤(短路分支是
      # `_retire_ios_schema || return 1; _retire_report_ca; return 0`, 回到 cmd_platform 只剩
      # `rm -rf $wd` / `run_all_migrations || true` / 成功)。所以这里让**真实**迁移照常跑完,
      # 只在它的**调用边界**把返回值改成非 0。这不是自然发生的产品失败, 也没有为了造失败
      # 往生产流程里加步骤 —— 它只用来验"恢复选的是哪条路"。
      echo 'eval "_real_mwr() $(declare -f migrate_wloc_retire | sed 1d)"'
      echo 'migrate_wloc_retire(){'
      echo '  printf "before=%s\n" "${_PDG_RETIRE_DONE:-0}" > "$BOUNDARY"'
      echo '  _real_mwr "$@"; local rc=$?'
      echo '  printf "real_rc=%s\nafter=%s\n" "$rc" "${_PDG_RETIRE_DONE:-0}" >> "$BOUNDARY"'
      echo '  [[ "$rc" == 0 ]] && return 1; return "$rc"; }'
    fi
    echo "exec 9>\"$d/lock\"; flock -n 9"
    echo "cmd_platform $tgt"
    echo 'echo "PLAT_RC=$?"'
  } > "$d/run.sh"
  bash "$d/run.sh" > "$d/stdout" 2> "$d/stderr"
  echo "PLAT_EXIT=$?" >> "$d/stdout"
  cat "$d/stdout" "$d/stderr"
}
plain(){ sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
exec_valid(){
  local b; b="$(plain "$1" | grep -nE 'command not found|未找到命令|syntax error|unbound variable' | head -3)"
  if [[ -n "$b" ]]; then bad "$2: **执行无效** —— 壳里有未定义/异常, 不作为产品判据:"; sed 's/^/        /' <<<"$b"; return 1; fi
  ok "$2: 执行有效(无未定义调用、无异常中断)"
}

export FIXDIR="$HERE"

check_premise(){   # 现场前提: 只剩记录/产物待迁移
  local n="$1"
  [[ ! -e /etc/systemd/system/pdg-mitm.service ]] && ok "$n: 前提 退役 unit 不存在" || bad "$n: 前提 unit 还在"
  [[ ! -e /opt/pdg-bot/mitm_server.py && ! -e /opt/pdg-bot/mitm_wloc.py ]] && ok "$n: 前提 执行模块不存在" || bad "$n: 前提 模块还在"
  [[ "$(cat "$SC/pdg-mitm.ac" 2>/dev/null)" != active ]] && ok "$n: 前提 服务不在运行" || bad "$n: 前提 服务在跑"
  [[ ! -s /etc/mosdns/rules/mitm_hijack.txt ]] && ok "$n: 前提 没有待撤除的劫持内容" || bad "$n: 前提 劫持表非空"
  grep -q 'MITM-OUT' /etc/mihomo/config.yaml 2>/dev/null && bad "$n: 前提 内核配置里还有 MITM-OUT" || ok "$n: 前提 内核配置里没有 MITM-OUT"
  grep -q '"enabled": *true' /etc/privdns-gateway/mitm.json 2>/dev/null && bad "$n: 前提 mitm.json 仍启用" || ok "$n: 前提 mitm.json 未启用"
}

for kind in nowloc wloc; do
  [[ "$kind" == nowloc ]] && title="不带 CA 的合法旧产物" || title="带 CA 的合法旧产物"
  echo
  echo "══ $kind. $title: 正常迁移 ══"
  seed_machine "$kind" || { bad "$kind: 造不出夹具"; continue; }
  sp="$(selfproof 2>&1)"
  [[ "$sp" == OK ]] && ok "$kind-A1: 前像过了**产品自己**的 schema-1 校验门(记录 + 两份产物)" \
    || { bad "$kind-A1: 前像自证失败: $sp"; continue; }
  B="$(inspect)"
  [[ "$(jqf schema <<<"$B")" == 1 ]] && ok "$kind-A2: 前像 schema=1" || bad "$kind-A2"
  iid_b="$(jqf instance_id <<<"$B")"; ssid_b="$(jqf cur_ssids <<<"$B")"
  rev_b="$(jqf cur_rev <<<"$B")"
  cursha_b="$(jqf art_cur.sha256 <<<"$B")"; prevsha_b="$(jqf art_prev.sha256 <<<"$B")"
  ca_b="$(jqf art_cur.has_ca <<<"$B")"
  if [[ "$kind" == wloc ]]; then
    [[ "$ca_b" == true ]] && ok "$kind-A3: 前像产物里确实嵌着 CA" || bad "$kind-A3: has_ca=$ca_b"
  else
    [[ "$ca_b" == false ]] && ok "$kind-A3: 前像产物里没有 CA" || bad "$kind-A3: has_ca=$ca_b"
  fi
  check_premise "$kind-A"
  d="$WORK/ok-$kind"; mkdir -p "$d"
  o="$(run_platform ios nofail "$d")"; p="$(plain "$o")"
  exec_valid "$o" "$kind-B"
  grep -q 'PLAT_RC=0' <<<"$p" && ok "$kind-B1: 正常切换返回 0" || { bad "$kind-B1: $(grep -o 'PLAT_RC=.*' <<<"$p")"; grep -vE '^FINAL' <<<"$p" | tail -10 | sed 's/^/      /'; }
  A="$(inspect)"
  [[ "$(jqf schema <<<"$A")" == 2 ]] && ok "$kind-B2: 记录 schema 1 → 2(**真的**推进了)" || bad "$kind-B2: schema=$(jqf schema <<<"$A")"
  [[ "$(jqf instance_id <<<"$A")" == "$iid_b" ]] && ok "$kind-B3: instance_id 不变" || bad "$kind-B3"
  [[ "$(jqf cur_wloc <<<"$A")" == null ]] && ok "$kind-B4: 记录里不再有 wloc_enabled 字段" || bad "$kind-B4: $(jqf cur_wloc <<<"$A")"
  if [[ "$kind" == wloc ]]; then
    [[ "$(jqf retired_ssids <<<"$A")" == "$ssid_b" ]] \
      && ok "$kind-B5: 当前槽位已退役, 用户意图(SSID)由 retired_inputs 原样承接: $ssid_b" \
      || bad "$kind-B5: retired_inputs.ssids=$(jqf retired_ssids <<<"$A"), 前像=$ssid_b"
    [[ "$(jqf art_cur.has_ca <<<"$A")" != true ]] && ok "$kind-B6: 带 CA 的旧产物**确实被处理了**(当前槽位已无嵌 CA 产物)" \
      || bad "$kind-B6: 产物里仍有 CA"
    [[ -n "$(jqf retired_revision <<<"$A")" && "$(jqf retired_revision <<<"$A")" != null ]] \
      && ok "$kind-B7: 记录标出了被退役的槽位(retired_revision=$(jqf retired_revision <<<"$A"))" || bad "$kind-B7"
  else
    [[ "$(jqf cur_ssids <<<"$A")" == "$ssid_b" ]] && ok "$kind-B5: 用户意图(SSID)原样保留: $ssid_b" || bad "$kind-B5: $(jqf cur_ssids <<<"$A")"
    [[ "$(jqf art_cur.sha256 <<<"$A")" == "$cursha_b" ]] && ok "$kind-B6: 仍合法的产物原样保留(sha 未变)" || bad "$kind-B6"
    [[ "$(jqf cur_rev <<<"$A")" == "$rev_b" ]] && ok "$kind-B7: revision 不变($rev_b)" || bad "$kind-B7"
  fi
  [[ -s "$d/mig.log" ]] && ok "$kind-B8: 末尾迁移链真的跑了($(grep -c . "$d/mig.log") 支空转被点到)" || bad "$kind-B8"
  # 幂等
  d2="$WORK/idem-$kind"; mkdir -p "$d2"
  o2="$(run_platform ios nofail "$d2")"; p2="$(plain "$o2")"
  grep -q 'PLAT_RC=0' <<<"$p2" && ok "$kind-B9: 重复执行仍成功(幂等)" || bad "$kind-B9"
  [[ "$(jqf schema <<<"$(inspect)")" == 2 ]] && ok "$kind-B10: 幂等后 schema 仍是 2" || bad "$kind-B10"
done

echo
echo "══ 三. schema 推进之后失败: 恢复要把「记录—产物」这一对一起还回来 ══"
echo "   (失败点性质: **受控边界故障注入** —— 产品里 schema 成功之后到「平台已确认」之间"
echo "    没有可失败的步骤, 所以让真实迁移照常跑完, 只在它的调用边界把返回值改成非 0。"
echo "    这不是自然发生的产品失败, 也没有为造失败往生产流程里加步骤。)"
seed_machine wloc || bad "C: 造不出夹具"
sp="$(selfproof 2>&1)"; [[ "$sp" == OK ]] && ok "C0: 前像自证通过" || bad "C0: $sp"
check_premise "C"
B="$(inspect)"
iid_b="$(jqf instance_id <<<"$B")"; ssid_b="$(jqf cur_ssids <<<"$B")"
rev_b="$(jqf cur_rev <<<"$B")"; prevrev_b="$(jqf prev_rev <<<"$B")"
cursha_b="$(jqf art_cur.sha256 <<<"$B")"; prevsha_b="$(jqf art_prev.sha256 <<<"$B")"
curmode_b="$(jqf art_cur.mode <<<"$B")"; curuid_b="$(jqf art_cur.uid <<<"$B")"; curgid_b="$(jqf art_cur.gid <<<"$B")"
metamode_b="$(jqf meta_mode <<<"$B")"; metauid_b="$(jqf meta_uid <<<"$B")"; metagid_b="$(jqf meta_gid <<<"$B")"
d="$WORK/boundary"; mkdir -p "$d"
o="$(run_platform ios boundary-fail "$d")"; p="$(plain "$o")"
exec_valid "$o" "C"
# 先证明"确实推进了、确实处理了旧产物", 再判恢复
grep -q 'real_rc=0' "$d/boundary" && ok "C1: 真实 migrate_wloc_retire **自己返回 0**(迁移真的成功了)" || bad "C1: $(cat "$d/boundary" 2>/dev/null | tr '\n' ' ')"
grep -q '^before=0' "$d/boundary" && ok "C2: 进这一步之前 _PDG_RETIRE_DONE=0(没有借到模块清理的记号)" || bad "C2"
grep -q '^after=1' "$d/boundary" && ok "C3: 出来之后 =1 —— 这次变化**只可能**来自 schema 推进" || bad "C3"
grep -q 'iOS 描述文件记录已迁移到新格式' <<<"$p" && ok "C4: 产品自己也报了记录已迁移" || bad "C4"
grep -q 'PLAT_RC=0' <<<"$p" && bad "C5: 边界注入了非 0, 切换却返回 0" || ok "C5: 切换返回非 0"
grep -q '平台已确认' <<<"$p" && bad "C6: 仍然打印了「平台已确认」" || ok "C6: 没有打印「平台已确认」"
grep -q '改用本次快照做整体恢复' <<<"$p" && ok "C7: 恢复选的是**整体快照恢复**, 不是局部平台还原" || bad "C7: $(grep -oE '已恢复.{0,12}|改用.{0,12}' <<<"$p" | head -2 | tr '\n' ' ')"
# 恢复之后: 记录与产物回到前像
A="$(inspect)"
[[ "$(jqf schema <<<"$A")" == 1 ]] && ok "C8: 记录回到 schema 1" || bad "C8: schema=$(jqf schema <<<"$A")"
[[ "$(jqf instance_id <<<"$A")" == "$iid_b" ]] && ok "C9: instance_id 回到前像" || bad "C9"
[[ "$(jqf cur_ssids <<<"$A")" == "$ssid_b" ]] && ok "C10: SSID 回到前像: $ssid_b" || bad "C10: $(jqf cur_ssids <<<"$A")"
[[ "$(jqf cur_rev <<<"$A")" == "$rev_b" && "$(jqf prev_rev <<<"$A")" == "$prevrev_b" ]] \
  && ok "C11: 槽位关系回到前像(current=$rev_b / previous=$prevrev_b)" || bad "C11: cur=$(jqf cur_rev <<<"$A") prev=$(jqf prev_rev <<<"$A")"
[[ "$(jqf retired_revision <<<"$A")" == null ]] && ok "C12: 记录里不再有 retired_revision(不是只把 schema 数字改回来)" || bad "C12"
# 产物四维分别核对
[[ "$(jqf art_cur.exists <<<"$A")" == true ]] && ok "C13a: 存在性: current 产物回来了" || bad "C13a"
[[ "$(jqf art_cur.sha256 <<<"$A")" == "$cursha_b" ]] && ok "C13b: 内容: current 产物与前像逐字节相同" || bad "C13b"
[[ "$(jqf art_cur.mode <<<"$A")" == "$curmode_b" ]] && ok "C13c: mode: $curmode_b" || bad "C13c: $(jqf art_cur.mode <<<"$A")"
[[ "$(jqf art_cur.uid <<<"$A")" == "$curuid_b" && "$(jqf art_cur.gid <<<"$A")" == "$curgid_b" ]] \
  && ok "C13d: uid:gid: $curuid_b:$curgid_b" || bad "C13d"
[[ "$(jqf art_cur.has_ca <<<"$A")" == true ]] && ok "C14: 嵌着 CA 的那份产物**真的回来了**(退役被撤销)" || bad "C14"
[[ "$(jqf art_prev.sha256 <<<"$A")" == "$prevsha_b" ]] && ok "C15: previous 产物也回到前像" || bad "C15"
[[ "$(jqf meta_mode <<<"$A")" == "$metamode_b" && "$(jqf meta_uid <<<"$A")" == "$metauid_b" && "$(jqf meta_gid <<<"$A")" == "$metagid_b" ]] \
  && ok "C16: 记录文件的 mode/uid/gid 也回到前像($metamode_b $metauid_b:$metagid_b)" || bad "C16"
# 恢复出来的东西仍然过真实校验
sp="$(selfproof 2>&1)"; [[ "$sp" == OK ]] && ok "C17: 恢复出来的记录与产物**仍然过产品自己的 schema-1 校验门**" || bad "C17: $sp"

echo
echo "══ 四. 撤销对照: 只撤掉「schema 推进时设置恢复记号」那一处 ══"
REV="$WORK/pdg-rev-schemamark.sh"
python3 - "$PDG" "$REV" <<'PYREV'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
a = """  printf '%s' "$out" | grep -q '"changed": true' && {
    _PDG_RETIRE_DONE=1
    c_g "  ✅ iOS 描述文件记录已迁移到新格式(不再含 WLOC 字段)。"; }"""
b = """  printf '%s' "$out" | grep -q '"changed": true' && \\
    c_g "  ✅ iOS 描述文件记录已迁移到新格式(不再含 WLOC 字段)。\""""
assert s.count(a) == 1, s.count(a)
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(a, b, 1))
PYREV
if ! bash -n "$REV" 2>/dev/null || cmp -s "$PDG" "$REV"; then
  bad "D0: 没造出反向副本 —— 本格记无效"
else
  ok "D0: 反向副本就位(只去掉 _retire_ios_schema 里那一行 _PDG_RETIRE_DONE=1)"
  seed_machine wloc || bad "D: 造不出夹具"
  B="$(inspect)"; cursha_b="$(jqf art_cur.sha256 <<<"$B")"; ssid_b="$(jqf cur_ssids <<<"$B")"
  d="$WORK/rev"; mkdir -p "$d"
  o="$(run_platform ios boundary-fail "$d" "$REV")"; p="$(plain "$o")"
  exec_valid "$o" "D"
  grep -q 'real_rc=0' "$d/boundary" && ok "D1: 真实迁移同样成功(对照的起点一样)" || bad "D1"
  grep -q '^after=0' "$d/boundary" && ok "D2: 但记号没被置上(撤销生效)" || bad "D2: $(cat "$d/boundary" | tr '\n' ' ')"
  grep -q '改用本次快照做整体恢复' <<<"$p" && bad "D3: 仍然选了整体恢复 —— 反向对照没体现差异" || ok "D3: 恢复退回了局部平台还原"
  A="$(inspect)"
  # 直接的记录/产物错误, 不是少一行日志
  [[ "$(jqf schema <<<"$A")" == 2 ]] && ok "D4: **记录被留在 schema 2** —— 局部还原补不回一条已改写的记录" || bad "D4: schema=$(jqf schema <<<"$A")"
  [[ "$(jqf art_cur.has_ca <<<"$A")" != true ]] && ok "D5: **嵌 CA 的产物没有回来**(退役没被撤销)" || bad "D5"
  [[ "$(jqf art_cur.sha256 <<<"$A")" != "$cursha_b" ]] && ok "D6: current 产物内容与前像不同(恢复错了, 不只是报告少一句)" || bad "D6"
  sp="$(selfproof 2>&1)"; [[ "$sp" == OK ]] && bad "D7: 撤销之后居然还过 schema-1 校验?" || ok "D7: 恢复出来的东西过不了 schema-1 校验门(现场确实坏了)"
fi

echo
echo "══ 五. 无关注释对照: 零新增失败 ══"
NOCOM="$WORK/pdg-nocomment.sh"
grep -v '^  # 记录格式一旦推进就回不去(嵌着根证书的旧产物会被删掉), 与删模块/删 unit 同级 ——$' "$PDG" > "$NOCOM"
if cmp -s "$PDG" "$NOCOM" || ! bash -n "$NOCOM" 2>/dev/null; then
  bad "E0: 没造出无关注释对照"
else
  seed_machine wloc || bad "E: 造不出夹具"
  d="$WORK/nocom"; mkdir -p "$d"
  o="$(run_platform ios boundary-fail "$d" "$NOCOM")"; p="$(plain "$o")"
  exec_valid "$o" "E"
  A="$(inspect)"
  if grep -q '改用本次快照做整体恢复' <<<"$p" && [[ "$(jqf schema <<<"$A")" == 1 && "$(jqf art_cur.has_ca <<<"$A")" == true ]]; then
    ok "E1: 只删一行注释 → 判据一条都没变(仍选整体恢复, 记录与产物照样回到前像)"
  else
    bad "E1: 注释对照也红了, 判据不干净"
  fi
fi

echo
echo "──────── 本支仍被替换的产品函数, 以及因此未覆盖的性质 ────────"
cat <<'NOTE'
  cmd_snapshot            → 未覆盖: 快照清单裁剪与元数据写入(材料是真打的 tar, 含
                            var/lib/privdns-gateway/ios-profile)
  _plat_write_profile     → 未覆盖: profile.env 的真实渲染内容
  migrate_probe81_public / migrate_ios_gms_cleanup / _plat_verify / _switchcore_nft
                          → 未覆盖: 这几步自身的判据(本支让它们成功, 好把现场停在 schema 这一格)
  mihomo / nft            → 未覆盖: 真实 mihomo -t 校验与真实 nft 装载
  /opt/pdg-bot/bot.py     → 最小但真的渲染器; 未覆盖: 真实 bot.py 的分流与 hosts 段渲染
  need_root / _lock       → 未覆盖: 真实取锁
  _pdg_bot_cred / _core_kernel_stable → 未覆盖: 切换后稳定性判据
  systemctl               → 未覆盖: 真实 systemd 的状态机与时序; 服务状态沿用既有模型,
                            InvocationID 变化只证明进程更替, 本支**不**据此声称配置已重新加载
  其余 25 支 migrate_*    → 空转(只记账)
  **没有**打桩的: python3、iosstate.migrate_schema、_retire_ios_schema、migrate_wloc_retire、
  全部 _retire_*、cmd_platform、cmd_rollback、_pdg_apply_snapshot_tree 与 iOS 生命周期那一组。
NOTE
echo "────────────────────────────────────────"
echo "通过 $pass, 失败 $nfail"
[[ "$nfail" == 0 ]]

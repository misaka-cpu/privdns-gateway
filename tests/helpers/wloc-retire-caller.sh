#!/usr/bin/env bash
# 三支迁移模型共用的真实调用方前置条件。只 source，不独立运行。
# 服务来自各测试的状态模型；锁、快照及服务前像由真实产品函数取得，不绕过能力门。
# shellcheck shell=bash
_RETIRE_CALLER_BOX="$(mktemp -d /tmp/pdg-retire-callers.XXXXXXXX)" || return 1
_RETIRE_CALLER_DEPS=(
  _pdg_svcstate_units _pdg_svc_known _pdg_svc_q _pdg_save_svcstate
  _pdg_svcstate_valid _pdg_now_en _pdg_set_enable_state _pdg_lock_proof
  _retire_caller_gate _retire_allowed _retire_has_irreversible_work
  _retire_rerun_hint _retire_ca_reader_dir
)
for _fn in "${_RETIRE_CALLER_DEPS[@]}"; do
  _def="$(awk -v f="$_fn" '
    index($0,f"(){")==1 {on=1; print; if ($0 ~ /}[[:space:]]*$/) exit; next}
    on {print; if ($0 ~ /^}/) exit}
  ' "$ROOT/deploy/bot/pdg.sh")"
  [[ -n "$_def" ]] || { echo "夹具缺产品函数: $_fn" >&2; return 1; }
  eval "$_def"
done
unset _fn _def
eval "$(grep -m1 '^REPO_DIR=' "$ROOT/deploy/bot/pdg.sh")"
retire_caller_dependencies(){
  local fn
  for fn in "${_RETIRE_CALLER_DEPS[@]}"; do declare -F "$fn" >/dev/null || return 1; done
}
retire_caller_dependencies || return 1
# 提取缺项必须拒绝；不能把空对空、或 127 当成预期业务拒绝。
if ( unset -f _retire_has_irreversible_work; retire_caller_dependencies ); then
  echo '夹具缺函数负控未拒绝' >&2; return 1
fi
_def="$(declare -f migrate_wloc_retire)" || return 1
eval "_fixture_product_retire${_def#migrate_wloc_retire}"
unset _def
_pdg_module(){ [[ -f "$ROOT/deploy/bot/$1" ]] && printf '%s\n' "$ROOT/deploy/bot/$1"; }
migrate_wloc_retire(){
  local d rc own_lock=0 LOCK _PDG_RETIRE_OK="" PDG_UPDATE_SVCSTATE
  d="$(mktemp -d "$_RETIRE_CALLER_BOX/call.XXXXXXXX")" || return 99
  LOCK="${PDG_LOCKFILE:-$d/lock}"
  if ! retire_caller_dependencies; then
    echo '缺产品函数' > "$d/invalid"; return 99
  fi
  if ! _pdg_lock_proof; then
    exec 9>"$LOCK" || { echo '锁文件未取得' > "$d/invalid"; return 99; }
    flock -n 9 || { echo '未持锁' > "$d/invalid"; exec 9>&-; return 99; }
    own_lock=1
  fi
  PDG_UPDATE_SVCSTATE="$d/svcstate.tsv"
  if ! tar -czf "$d/snap.tar.gz" -C "$PDG_RETIRE_ROOT" . ||
     ! _pdg_save_svcstate "$d" > "$d/save.out" 2> "$d/save.err"; then
    echo '本次前像未取得' > "$d/invalid"
    rc=99
  else
    _fixture_product_retire "$@" > "$d/out" 2> "$d/err"; rc=$?
    cat "$d/out"
    cat "$d/err" >&2
    if grep -E 'command not found|unbound variable|Traceback|ModuleNotFoundError' "$d/out" "$d/err"; then
      echo '调用闭包无效' > "$d/invalid"; rc=99
    fi
  fi
  if (( own_lock )); then flock -u 9; exec 9>&-; fi
  return "$rc"
}
retire_caller_check(){
  local failures
  failures="$(find "$_RETIRE_CALLER_BOX" -name invalid -type f -print)" || return 1
  if [[ -n "$failures" ]]; then
    echo "夹具/调用闭包失败: $failures" >&2
    return 1
  fi
  [[ -n "$(find "$_RETIRE_CALLER_BOX" -name svcstate.tsv -type f -print -quit)" ]] || return 1
  rm -rf -- "$_RETIRE_CALLER_BOX"
}

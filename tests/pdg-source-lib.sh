#!/usr/bin/env bash
# tests 共享的 pdg.sh 源码入口(建议 4; 规则与实现都在 tests/pdg_source.py, 这里只是 bash 的门面)。
#
# 测试要读"逻辑上的整份 pdg.sh"时, 用它给的路径, 不直接写 deploy/bot/pdg.sh:
#   · 入口里没有 `# @pdg-part <段>` 拆分标记: 给出的就是 deploy/bot/pdg.sh 本身;
#   · 有标记: 给出拼回的整份。拼回只有 pdg_source.py 那一份实现; 这里按同一套字节流算内容哈希,
#     缓存里已有就直接给路径(不起 Python), 没有才调 pdg_source.py 去拼、写缓存。
#
# 两种用法:
#   bash tests/pdg-source-lib.sh path <仓库根>      # 打印路径(测试里写成 "$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")")
#   source tests/pdg-source-lib.sh; pdg_src_path <仓库根>; pdg_extract_fn <函数名> <文件>

_PDG_SRC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 缓存目录, 与 pdg_source.cache_dir() 同一规则
_pdg_src_cache_dir(){
  local b="${XDG_CACHE_HOME:-}"
  [[ -z "$b" && -n "${HOME:-}" ]] && b="$HOME/.cache"
  if [[ -n "$b" ]]; then printf '%s/pdg-source\n' "$b"; else printf '%s/pdg-source-%s\n' "${TMPDIR:-/tmp}" "$(id -u)"; fi
}

pdg_src_path(){
  local root="${1:?用法: pdg_src_path <仓库根>}" entry n f key ok=1
  local -a names=()
  entry="$root/deploy/bot/pdg.sh"
  [[ -f "$entry" ]] || { echo "pdg-source: 找不到 $entry" >&2; return 1; }
  mapfile -t names < <(sed -n 's/^# @pdg-part \([a-z0-9][a-z0-9_-]*\)$/\1/p' "$entry")
  if (( ${#names[@]} == 0 )); then printf '%s\n' "$entry"; return 0; fi
  # 快路径: 段都在才算哈希(缺段的报错交给 Python 那一份, 措辞只有一处)
  for n in "${names[@]}"; do [[ -f "$root/lib/pdg/$n.sh" ]] || ok=0; done
  if (( ok )); then
    key="$( { printf '%s\0' pdg-source-v2; cat -- "$entry"
              for n in "${names[@]}"; do printf '\0%s\0' "$n"; cat -- "$root/lib/pdg/$n.sh"; done; } | sha256sum)" || key=""
    key="${key%% *}"
    f="$(_pdg_src_cache_dir)/$key.sh"
    if [[ "$key" =~ ^[0-9a-f]{64}$ && -s "$f" ]]; then
      touch -c -- "$f" 2>/dev/null || true   # 刷新时间, 免得被清理; 刷不了不影响结果
      printf '%s\n' "$f"; return 0
    fi
  fi
  python3 "$_PDG_SRC_HERE/pdg_source.py" path "$root"
}

# 按名抽函数(与 pdg_source.extract 同规则): 抽不到 / 同名多处 / 找不到收尾都返回非 0, 绝不输出空串。
pdg_extract_fn(){
  local name="${1:?}" file="${2:?}"
  PDG_SOURCE_PY="$_PDG_SRC_HERE/pdg_source.py" python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("pdg_source", os.environ["PDG_SOURCE_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    print(m.extract(sys.argv[1], open(sys.argv[2], encoding="utf-8", newline="").read()))
except LookupError as e:
    sys.stderr.write("pdg-source: %s\n" % e); sys.exit(1)
' "$name" "$file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    path) shift; pdg_src_path "$@";;
    *) echo "用法: bash tests/pdg-source-lib.sh path <仓库根>" >&2; exit 2;;
  esac
fi

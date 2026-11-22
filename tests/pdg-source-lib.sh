#!/usr/bin/env bash
# tests 共享的 pdg.sh 源码入口(建议 4 第 0 步; 与 tests/pdg_source.py 同一规则)。
#
# 测试要读"逻辑上的整份 pdg.sh"时, 用它给的路径, 不再直接写 deploy/bot/pdg.sh:
#   · 入口里没有 `# @pdg-part <段>` 拆分标记(现在就是这样): 给出的就是 deploy/bot/pdg.sh 本身;
#   · 有标记时: 把每个标记行换成 lib/pdg/<段>.sh 的全文, 写到一个临时文件, 给出它的路径。
#
# 两种用法:
#   bash tests/pdg-source-lib.sh path <仓库根>      # 打印路径(测试里写成 "$(bash "$ROOT/tests/pdg-source-lib.sh" path "$ROOT")")
#   source tests/pdg-source-lib.sh; pdg_src_path <仓库根>; pdg_extract_fn <函数名> <文件>
# 有标记时临时文件留在 ${TMPDIR:-/tmp}/pdg-source.XXXXXX 下, 由系统的临时目录清理收走(每次调用都新建, 不复用)。

pdg_src_path(){
  local root="${1:?用法: pdg_src_path <仓库根>}" entry tmp line name part
  entry="$root/deploy/bot/pdg.sh"
  [[ -f "$entry" ]] || { echo "pdg-source: 找不到 $entry" >&2; return 1; }
  if ! grep -q -E '^# @pdg-part [a-z0-9][a-z0-9_-]*$' "$entry"; then
    printf '%s\n' "$entry"; return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pdg-source.XXXXXX")" || return 1
  # 与 pdg_source.py 同一规则: 段文件 = 它的内容 + 恰好一个行尾(段文件末尾有没有换行都一样);
  # 入口最后一行没有换行就照样不补 —— 拼出来的必须与 python 版逐字节相同。
  local nl body
  while :; do
    if IFS= read -r line; then nl=1; elif [[ -n "$line" ]]; then nl=0; else break; fi
    if [[ "$line" =~ ^#\ @pdg-part\ ([a-z0-9][a-z0-9_-]*)$ ]]; then
      name="${BASH_REMATCH[1]}"; part="$root/lib/pdg/$name.sh"
      [[ -f "$part" ]] || { echo "pdg-source: 拆分标记指向的段文件不存在: $part" >&2; return 1; }
      body="$(cat -- "$part"; printf x)"; body="${body%x}"; body="${body%$'\n'}"
      printf '%s' "$body"
    else
      printf '%s' "$line"
    fi
    [[ "$nl" == 1 ]] && printf '\n'
    [[ "$nl" == 0 ]] && break
  done < "$entry" > "$tmp/pdg.sh" || return 1
  printf '%s\n' "$tmp/pdg.sh"
}

# 按名抽函数(与 pdg_source.extract 同规则): 抽不到 / 同名多处 / 找不到收尾都返回非 0, 绝不输出空串。
pdg_extract_fn(){
  local name="${1:?}" file="${2:?}"
  PDG_SOURCE_PY="$(dirname "${BASH_SOURCE[0]}")/pdg_source.py" python3 -c '
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

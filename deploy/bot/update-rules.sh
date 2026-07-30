#!/usr/bin/env bash
# 更新 geosite 规则库: 下载 geosite.dat → 解析到**临时目录** → 经统一配置事务落盘 → 重载 mosdns。
# 依赖本机能解析 DNS (resolv.conf 指向 127.0.0.1=mosdns)。
#
# 5.1 之前这里是直接把解析结果写进 /etc/mosdns/rules(非原子: 一个文件写到一半就是坏的),
# 然后 `systemctl restart mosdns` 且**不检查它有没有起来** —— 而这条路径每天 04:30 由 timer
# 自动跑, 既不上锁(可与 Bot/CLI 的写操作对撞), 出事也没有任何回退材料。
# 现在: 解析进临时目录 → 逐个 stage 进事务 → 事务在锁内校验、落盘、重启并观察 mosdns;
# 任一步不成立就整批回到旧规则库, 现网 DNS 不受影响。
set -euo pipefail
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/geosite.dat" \
  https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
mkdir -p "$WORK/rules"
python3 /opt/pdg-bot/parse-geosite.py "$WORK/geosite.dat" "$WORK/rules"

shopt -s nullglob
files=("$WORK"/rules/*.txt)
[[ ${#files[@]} -gt 0 ]] || { echo "geosite 解析没产出任何规则文件, 保留旧库"; exit 1; }

TX=""
for m in /opt/privdns-gateway/deploy/bot/pdgtx.py /opt/pdg-bot/pdgtx.py; do
  [[ -f "$m" ]] && { TX="$m"; break; }
done
[[ -n "$TX" ]] || { echo "找不到事务核心 pdgtx.py, 拒绝直接改现网规则库"; exit 1; }

# 事务模式。normal 有一道前置硬门: "操作前这些组件就是坏的 → 拒绝在坏掉的东西上做普通变更"。
# 那道门对**日常更新**是对的, 但对**全新安装**是错的 —— 那时 mosdns 还没起、53/853 还没人听,
# 不是"坏了", 是"还没装完"。装机因此拿不到 geosite 文件, mosdns 又因为 domain_set 缺文件起不来,
# 整场安装失败回滚。装机侧传 PDG_TX_MODE=repair: 允许降级基线, 但"操作前好、操作后坏"照旧回滚。
TXMODE="${PDG_TX_MODE:-normal}"
ID="$(python3 "$TX" new --source scheduler --op geosite_update --mode "$TXMODE")"
for f in "${files[@]}"; do
  python3 "$TX" stage --tx "$ID" --target "mosdns_rule:$(basename "$f")" --file "$f"
done
python3 "$TX" service --tx "$ID" --action restart:mosdns

if python3 "$TX" apply --tx "$ID" >/dev/null; then
  echo "geosite 规则库已更新并重载 mosdns (事务 $ID, ${#files[@]} 个文件)"
  exit 0
fi
echo "geosite 更新未提交(事务 $ID): 旧规则库仍在使用, mosdns 未受影响" >&2
exit 1

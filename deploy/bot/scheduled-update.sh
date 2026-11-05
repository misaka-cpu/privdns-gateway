#!/usr/bin/env bash
# 定时刷新规则库: geosite (update-rules.sh) + 各 Surge/Clash 规则集 (bot.refresh_rulesets)。
# 由 pdg-rules-update.timer 每日触发。失败不致命, 保留旧规则。
#
# 两步现在各自是一笔配置事务(source=scheduler): 拿不到全局锁就**直接放弃这一次**并留痕 ——
# 定时任务不该排队等人工操作做完(等到一半用户还在改配置, 两边就撞上了), 明天还会再跑。
set -uo pipefail
rc=0

/bin/bash /opt/pdg-bot/update-rules.sh || { rc=1; echo "geosite 更新未提交, 保留旧库"; }

# 空 token 前缀: 只导入 bot 模块刷规则集, 不需要也不连 Telegram
# shellcheck disable=SC1007
cd /opt/pdg-bot && PDG_BOT_TOKEN= /usr/bin/python3 -c \
  "import bot,sys; n,f=bot.refresh_rulesets(); print('rulesets refreshed:', n, 'failed:', f); sys.exit(1 if f else 0)" \
  || { rc=1; echo "规则集刷新有未更新项(见上面的 failed 列表; 未刷上的仍用上一份好档)"; }

# 内核跟随上游的每日检查(pdg kernel tick): 只有「跟上游 + 自动」的机器才会动, 其余直接返回。
# 它自己取全局锁、自己发 Telegram 通知; 换核失败时旧核已还原。它的成败不算进规则库这次的退出码 ——
# 规则库刷成功了就是成功, 内核那边的结果另有通知与 `sudo pdg kernel status` 可查。
if [[ -x /usr/local/bin/pdg ]]; then
  /usr/local/bin/pdg kernel tick || echo "内核自动检查没做完(见上面的输出; 现有内核没动或已还原)"
fi

# 未完成的事务要让人看得见: doctor 也会报, 这里顺手在日志里点一句
for m in /opt/privdns-gateway/deploy/bot/pdgtx.py /opt/pdg-bot/pdgtx.py; do
  [[ -f "$m" ]] || continue
  python3 "$m" pending || echo "⚠️ 有未完成的配置事务, 需要 sudo pdg tx recover"
  break
done
exit "$rc"

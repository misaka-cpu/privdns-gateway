# 机读事件(`pdg-event`)

换内核、续面板证书、切手机平台这几件事做完, 除了给人看的那几行(带颜色、措辞会改), 还会往 journal
打**一行固定格式**的事件。验收、`pdg doctor`、监控要判"这件事发生过没有、结果是什么", 认这一行就行,
不用去对人话。

以前的验收就栽在这里: 换核成功那一行带着颜色转义, 措辞也和 Telegram 里那条不一样, 按 Telegram 的写法去
journal 里找, 永远找不到; bot 上点的按钮则根本不进 journal, 只能截图。

## 格式

```
event=<事件名> <键>=<值> <键>=<值> …
```

- journal 里的标识(`SYSLOG_IDENTIFIER`)固定是 `pdg-event`, 级别 info。命令行一侧由 `pdg.sh` 的 `_pdg_event`
  调 `logger` 写, bot 一侧由 `pdg-bot.py` 的 `pdg_event` 经 syslog 写; 两边对同一组输入打出的行逐字相同
  (`tests/test-bot-events.py` 盯着)。
- `event=` 永远在最前。事件名是小写词加点(`kernel.switch`); 不合这个词形的一律记成 `event=unknown`。
- 每个值都整理成**一个不含空白的词**: 空白换成 `_`, 控制字符删掉, 空值写 `-`, 超过 200 个字符截断并加 `…`
  (按字符截, 不会截出半个汉字)。所以按空格切开就是全部字段, 不需要处理引号。
- 键是小写词(`[a-z][a-z0-9_]*`), 不合的键整个丢掉。
- 写不进去(没有 `logger`、没有 `/dev/log`)就算了: 打日志失败不改变任何操作的结果, 也不打任何错误。

## 怎么查

```bash
journalctl -t pdg-event --since '2026-11-12 00:00:00 UTC' --no-pager -o short-iso
journalctl -t pdg-event --since '2026-11-12 00:00:00 UTC' --no-pager -o cat | grep -F 'event=kernel.switch'
```

两个坑, 都踩过:

- systemd 252(Debian 12)的 `journalctl --since` **不认** ISO 的 `2026-11-12T00:00:00Z` 写法, 直接报
  `Failed to parse timestamp` 退出; 要是又把错误丢进 `2>/dev/null`, 计数就全成了 0。用 `'YYYY-MM-DD HH:MM:SS UTC'`。
- `-o short-iso` 按本机时区打时间。要按日分组就先 `TZ=UTC`。

远端取证脚本直接用 `tools/evidence/evlib.sh` 的 `ev_events` / `ev_count_tokens`, 这两条它都处理了。
判"有一行同时是 `result=ok` 和 `to=v1.19.34`"要按**整词**比, 不要按子串: `to=v1.19.3` 是 `to=v1.19.34` 的子串。

## 事件一览

`via` 说明是谁起的这一次: `cli` = 不带 `--notify` 直接调的(终端里敲的, 也包括 bot 同步调的
`pdg kernel mode` / `auto`); `notify` = 带 `--notify` 的后台任务(bot 点的换核 / 换回 / 切平台, 或者
`pdg-lan-cert.timer`); `auto` = 每日定时 `pdg kernel tick` 自己换的。

| 事件 | 什么时候打 | `result` 的取值 | 其它字段 |
|---|---|---|---|
| `kernel.switch` | `pdg kernel upgrade` 每一个出口, 包括 tick 发起的那一次 | `ok` 换上了且体检一致 · `fail` 这一版本身的问题(摘要不符、体检变差…) · `error` 这一次没做成、与版本无关(下载失败、记录读不出…) · `skip` 不换(跟发布、护栏拒绝) · `noop` 已是目标版本 | `via` `from`(换前被认可的版本, 认不出写 `未知`) `to` `why` |
| `kernel.revert` | `pdg kernel revert` 每一个出口 | `ok` 换回钉值 · `noop` 本来就是钉值 · `error` | `via` `to` `why` |
| `kernel.tick` | 每日定时每跑一次 tick 都打一行, **没开跟随的机器也打**(`off`), 证明定时确实走到了这一步 | `off` 不是「跟上游 + 自动」· `latest` 已是上游最新 · `skip` 护栏不换 · `wait` 还没满等待期 · `held` 这一版自动换失败过、不再自动重试 · `due` 该换了(紧接着一行 `kernel.switch via=auto`) · `error` | `via=auto` `target` `published` `mode` `auto` `why` |
| `kernel.mode` | `pdg kernel mode <pinned\|upstream>` | `ok` · `fail` | `via` `to` |
| `kernel.auto` | `pdg kernel auto <on\|off>` | `ok` · `fail`(比如跟发布下开自动) | `via` `to` |
| `lan.cert.renew` | `pdg lan renew` 每一个出口(`--supported` 除外) | `ok` 续上了、反代给出的就是新证书 · `converged` 没续(不到时候), 但把还拿着旧证书的反代收敛了 · `noop` 什么都不用做 · `fail` 续期失败 / 进了 14 天没续 / 反代没收敛 · `skip` 不归这里续 | `via` `renewed`(0/1) `conv`(same/inactive/restarted/stale/restartfail/unreadable) `acme_rc` `not_after`(盘上那张的到期日, UTC) `why` |
| `platform.switch` | `pdg platform <ios\|android>`, 终端和 bot 两条路都记; 无参(看用法)不记 | `ok` 退出码 0 **且**切完确实是目标平台 · `fail` 其余情况(退出码 0 但平台没变也算 fail) | `via` `from` `to` `now` `rc` |
| `bot.callback` | 放行用户点了一个按钮 | — | `action`: callback_data 第一个 `:` 之前那段; 不是小写词形就写 `other` |
| `bot.text` | 放行用户发了一条文字 | — | `kind=command` + `name`(`/start` → `start`), 否则 `kind=input` |
| `bot.document` | 放行用户发了一个文件 | — | 无 |

bot 一侧只记"点了 / 发了什么动作"。动作的结果由它调起的 `pdg` 命令自己记(比如按「换到上游最新」之后,
那次 `pdg kernel upgrade --notify` 会打一行 `kernel.switch via=notify`), 两行按时间对得上。

## 不记什么

- 凭据: token、密码、私钥、DNS 插件的 API 凭据、代理凭据。
- 身份: Telegram 用户 id、chat id。
- 内容: bot 里敲的文字(输入框里可能就是 token 或订阅地址)、发来的文件名、callback_data 冒号后面那段
  (可能带域名、面板名、序号)。
- 面板名、内网主机名与地址。

## 还没覆盖的

- `pdg update` 本身、certbot 续 DoT 证书的部署钩子、去广告与出口管理之类 bot 里直接做完的操作的**结果**
  (bot 那一行只说明按了什么)。
- 拿不到锁直接 `exit` 的那一刻(`_lock`), 那一次没有事件; 带 `--notify` 的后台任务会照旧补发 Telegram。

## 改格式的规矩

加字段、加事件随时可以。改事件名、删字段、改 `result` 的取值, 要同时改本文、`tools/evidence/` 里的用法和
用到它的测试, 并在 CHANGELOG 里写明 —— 验收脚本是按这些词找的, 悄悄改名等于让它们一行都找不到。

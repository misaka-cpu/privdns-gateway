# 取证工具(`tools/evidence/`)

发版验收要去真机上采证据: 日志里某件事发生过几次、文件摘要对不对、服务在不在跑。这些脚本以前每一轮
手写一份, 而出过的错大多不是产品的错, 是临时脚本自己的错; 每错一次就要多一轮补采。这里把那些写法收成
一个带测试的库和一个静态检查。

- `evlib.sh`: 远端取证脚本的共用函数(只读)。
- `ev-lint.py`: 取证脚本的静态检查, 只查下面表里踩过的坑。

两者都不含任何机器名、地址或凭据; 连哪台机器、用哪把钥匙, 仍由每一轮自己的包装脚本决定。

## 怎么用

远端脚本一般经 ssh 以 `bash -s` 喂进去, 库就拼在它前面:

```bash
python3 tools/evidence/ev-lint.py round/*.sh                  # 跑之前先查
cat tools/evidence/evlib.sh round/check.sh | ssh … bash -s    # 脚本走管道进 stdin, 后面别再接 < /dev/null
```

`check.sh` 的样子:

```bash
ev_init || exit 1
FROM='2026-11-12 09:54:30 UTC'; UNTIL='2026-11-15 05:20:00 UTC'
ev_journal A "$FROM" "$UNTIL" -u pdg-rules-update.service; arc=$?
ev_guard_rc "A 段 journalctl" "$arc"                       # 采不到就停, 不当成 0 条
printf '%s\n' "$A"
ev_count_by_day "$A" '还没满等待期'
ev_events E "$FROM" "$UNTIL" || exit 1
echo "换核成功: $(ev_count_tokens "$E" event=kernel.switch result=ok to=v1.19.34)"
ev_run "pdg doctor" pdg doctor                              # stdin 接 /dev/null, 不吃掉后面的脚本
ev_guard_sha256 /usr/local/bin/mihomo "$WANT_SHA"
```

机读事件(`event=… 键=值 …`)的格式与事件表见 [docs/events.md](../../docs/events.md)。

## 函数

| 函数 | 做什么 | 对着哪个坑 |
|---|---|---|
| `ev_init` | `LC_ALL=C.UTF-8 TZ=UTC`, 并确认 C.UTF-8 真的可用 | short-iso 按本机时区打时间, 按日分组错位; C 区域下按字节截汉字 |
| `ev_ts_ok` / `ev_ts_from_iso` | 只认 `'YYYY-MM-DD HH:MM:SS UTC'`; 把 `%FT%TZ` 转成它 | systemd 252 的 `journalctl --since` 不认 ISO 的 T/Z, 有一轮验收因此一整段采空 |
| `ev_journal <变量> <起> <止> [选择…]` | 取一段日志进变量(`-q -a -o short-iso`), 打抬头, 出错返回 3 并原样打出 stderr | 原来写 `2>/dev/null`, 采不到被当成 0 条; 不加 `-a` 带颜色的行显示成 blob |
| `ev_events <变量> <起> <止>` | 同上, 只取 `pdg-event` | — |
| `ev_lines` / `ev_has` / `ev_count_fixed` | 非空行数 / 有没有 / 按字面计数, 纯 bash | `上游 \| grep -q` 在 pipefail 下被 SIGPIPE 翻转; 本机交互壳的 grep 是包装函数; 字串里的 `[` 被当正则 |
| `ev_count_tokens <文本> <词…>` | 同时含这些**整词**的行数 | 按子串比时 `to=v1.19.3` 也算 `to=v1.19.34` |
| `ev_count_by_day <文本> <字串>` | 按行首日期分组计数, 不用 awk | 远端 mawk 不认 `{n}` 区间, 有一轮验收因此采空一段 |
| `ev_cut_chars <字串> <N>` | 前 N 个**字符** | `tr` / `cut -c` 按字节切, 判定器松紧失真 |
| `ev_run <标签> <命令…>` | 打段落标题, stdin 接 `/dev/null`, 打 `[标签 rc=N]` | `bash -s` 的脚本在 stdin 上, 中间一条命令读了 stdin 就把后面的脚本吃掉 |
| `ev_guard_eq` / `ev_guard_nonempty` / `ev_guard_rc` / `ev_guard_sha256` | 不通过就打 `[ev 守卫失败]` 并以 86 退出整个脚本; 通过也打一行 | `cmp && echo` 在 set -e 下失败不停, 一次改 Release 前的复核因此没拦住; 两边都抽成空串时"相等" |

守卫只能在脚本主流程里调: 放进 `$(…)`、管道或 `( … )` 里, `exit` 只退出那个子 shell(ev-lint 的 E9 会拦)。

## ev-lint 的规则

| 规则 | 级别 | 查什么 |
|---|---|---|
| E1 | error | `journalctl --since/--until` 用了 ISO 的 T/Z(含 `$(date … %FT%TZ)`) |
| E2 | error | `journalctl … 2>/dev/null` |
| E3 | error | `awk` 程序里有 `{n}` / `{n,m}` 区间(`gawk` 不查) |
| E4 | error / warning | 不加引号的 heredoc 正文里有反引号(error) / `$(…)`(warning) |
| E5 | error / warning | `cmp` / `diff` / `sha256sum -c` 后面只有 `&&`(error), 或 `\|\|` 后面不是 exit / return(warning) |
| E6 | error | 开了 pipefail 时 `\| grep -q` / `\| grep -m` / `\| head` |
| E7 | error / warning | `tr` 参数里有非 ASCII(error); `cut -c` / `cut -b`(warning) |
| E8 | warning | `pgrep -f` 会匹配到自己的 shell |
| E9 | error | `ev_guard_*` 放进了 `$(…)` / 管道 / 子 shell |
| E10 | warning | `ssh` 调用没给 stdin(`< /dev/null`、`<<`、`\|`、`-n`) |
| E11 | warning | `journalctl --since/--until` 接变量(拿不准格式; 用 `ev_journal`) |
| E12 | warning | 用了 `-o short-iso` 却没固定 `TZ=UTC` |

它不是 shell 解析器: 认得单引号、双引号、`$'…'`、注释、heredoc 与续行; 双引号里的 `"$(…)"` 当代码看,
其余引号里的字当文字 —— 提示语里出现 `journalctl` 字样不算数。拿不准的报 warning。确属有意的那一行,
行尾写 `# ev-lint: ignore=E5`。退出码: 0 没有 error(`--strict` 时 warning 也算), 1 有, 2 用法不对。

## 测试

`tests/test-evidence-lib.sh`(库, 含仿 systemd 252 的 journalctl 替身)与 `tests/test-evidence-lint.py`
(每条规则一正一反, 外加"引号里的字不算"那几格)都在 CI 里跑。

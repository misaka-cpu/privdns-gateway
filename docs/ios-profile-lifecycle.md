# iOS 描述文件生命周期(5.4)

## 0. 为什么要做

v1.7.8 及以前,每次生成描述文件都现取两个随机 UUID:

- Bot:`_ios_profile()` 用 `uuid.uuid4()` 填 `__UUID1__`/`__UUID2__`,WLOC CA payload 也是随机 UUID;
- CLI:`cmd_ios` 用 `/proc/sys/kernel/random/uuid` 填同样两个占位符。

对 iOS 来说,`PayloadIdentifier` + `PayloadUUID` 就是描述文件的身份。身份每次都变 ⇒ 每装一次
就是**新增**一个描述文件,而不是更新原来那个。用户手机上会越堆越多,而服务器这边完全不知道
堆了几个、哪个还在用。

5.4 要解决的就是这件事:给网关一个**永久身份**,让后续每次生成都是"同一份文件的新版本"。

## 1. 不做什么(产品语义边界)

本项目**不是 MDM**,服务器无法确认 iPhone 上此刻装没装、装的是哪一版。所以文案只允许说:

- 当前生成版本 / 上次生成时间 / 上次发送时间;
- 当前网关配置相对已生成版本**是否发生变化**;
- "需要安装" / "建议重新安装" / "无需重新生成"。

**禁止**出现"已安装""设备已是最新版""更新已在手机生效""已替换手机上的旧描述文件"这类断言。

## 2. 稳定身份

- 首次启用时生成一次 `instance_id`(`uuid4`),持久化在元数据里,**永不再变**;
- 所有 payload 的 identifier/UUID 由 `uuid5(NS, instance_id + ":" + 角色)` 派生:
  角色固定为 `root` / `dns` / `ca`;
- 因此:同一网关重复生成完全稳定;不同网关的 `instance_id` 不同 ⇒ 身份不会互相替换;
- `instance_id` **不从** DoT 域名、IP、主机名、SSID、WLOC 状态推导 —— 那些都会变;
- `PayloadVersion` 恒为 Apple 规定的 `1`,不拿它当业务修订号(业务修订号是独立的 `revision`)。

## 3. 修订号与语义 digest

`revision` 从 1 开始,**只有规范化语义输入变化时才 +1**。参与 digest 的字段:

`schema` · `dot_host` · `server_addresses` · `dns_protocol` · `probe_url` ·
`ondemand`(结构化规则,SSID 列表已排序) · `wloc_enabled` · `wloc_ca_sha256`

**不参与**:时间戳、临时路径、随机值、发送时间、文件名。于是"点一下重新生成"在输入没变时
产出**逐字节相同**的文件,revision 不动,previous 不被顶掉,也不会凭空制造"需要更新"。

## 4. 三档更新判定

分级表集中在 `iosprofile.FIELD_LEVELS` 一处,Bot 与 CLI 都读它,不各写一份。

| 等级 | 触发字段 | 说明 |
|---|---|---|
| `none` 无需更新 | 规范化输入与当前版本一致 | 重新发送即可 |
| `recommended` 建议更新 | `ondemand_ssid`(SSID 排除)、`display`(显示说明) | 核心连接仍可用 |
| `required` 必须更新 | `dot_host`、`server_addresses`、`dns_protocol`、`probe_url`、`ondemand_core`、`wloc_enabled`、`wloc_ca_sha256`、`identity_migration`、`schema`、产物缺失/损坏 | 不更新会连不上或信任链不对 |

## 5. current / previous

- `current.mobileconfig` + 元数据里的 `current`;
- `previous.mobileconfig` + 元数据里的 `previous`(只留一份,不做无限历史);
- **只有真正产生新 revision 时**,旧 current 才进入 previous;
- 可以重新发送 current、查看 current↔previous 的**字段级**差异、发送 previous 供手工回退;
- "发送 previous" **不会**把服务器的 current 改回旧版 —— 它只是把那份文件再给你一次;
- 差异只显示字段变化;CA 只显示 sha256 指纹,不输出证书正文;
- token、私钥、代理链接一律不进文件、日志、审计与任何输出。

## 6. 老机器迁移

v1.7.8 之前每次都是随机身份,服务器**不知道**用户手机上装的是哪一份。所以首次启用受管生命
周期时:

1. 生成新的稳定身份,revision=1,标记 `migration_pending`;
2. 更新等级强制 `required`,文案明确要求**先手工删除旧的 PrivDNS Gateway 描述文件**再安装新的;
3. **不声称**新文件会自动替换旧的随机身份文件(iOS 不会那么做,身份不同就是两个文件);
4. 完成一次迁移之后,身份固定,后续版本 iOS 会按"更新同一个描述文件"处理。

提供「我已按说明安装,关闭迁移提示」的**本地确认**开关,它只是用户自述,不作为"已安装"的证据。

## 7. 原子性

产物与元数据要么一起更新,要么一起不动。实现是最小文件事务(`iosprofile._Txn`),证据与
`pdgtx` 对齐:

- 用**同一把**全局锁 `/run/privdns-gateway.lock`(`flock` 非阻塞),锁不可用即 fail-closed;
- 候选先行:先写 `.cand`,`plistlib` 解析 + 语义校验通过才允许成为 current;
- 精确 before-image:记录每个目标的内容/mode/uid/gid;
- 原子 `os.replace`;
- 任一步失败按 before-image 逐项还原(内容 + mode + owner),还原后复核;
- 崩溃后残留的 `.cand` 可识别可清理;不留下 current 与元数据 revision 不一致的半成功状态;
- 元数据损坏时**不自动重建身份**(那会造出第二个身份把用户手机上的文件变成孤儿),而是
  fail-closed 并给出修复办法。

WLOC 已启用但 CA 缺失/损坏,或检测到私钥混入,一律**拒绝生成**。描述文件里只允许公开 CA 证书。

## 8. 文件位置

| 路径 | 内容 | 备份语义 |
|---|---|---|
| `/etc/privdns-gateway/ios-profile.json` | 身份 + revision + digest + 时间戳 | 在快照 `etc/` 范围内,snapshot/restore 自动覆盖 |
| `/var/lib/privdns-gateway/ios-profile/current.mobileconfig` | 当前产物 | 可由元数据 + 当前配置**确定性重建**;缺失即判"必须更新" |
| `/var/lib/privdns-gateway/ios-profile/previous.mobileconfig` | 上一版产物 | 同上 |

元数据是**用户持久数据**:普通 update、`FORCE_REINSTALL` 都不得重置;卸载按既有语义清理。

## 9. 统一生成器

`deploy/bot/iosprofile.py` 是唯一的生成实现:

- Bot(`deploy/bot/pdg-bot.py`)与 CLI(`deploy/bot/pdg.sh` 的 `cmd_ios`)都调它;
- 它**不反向 import** `pdg-bot.py`,输入全部显式传参,不读 Telegram 会话状态;
- 只用标准库(`plistlib` / `hashlib` / `uuid` / `json`),不新增第三方依赖;
- 注册进 `lib/modules.sh` 的 `PDG_IOS_MODULES`(install / update / uninstall 三方同一份清单)。

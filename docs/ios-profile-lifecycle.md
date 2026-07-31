# iOS 描述文件生命周期(5.4)

## 0. 为什么要做

v1.7.8 及以前,每次生成描述文件都现取两个随机 UUID:

- Bot:`_ios_profile()` 用 `uuid.uuid4()` 填 `__UUID1__`/`__UUID2__`,WLOC CA payload 也是随机 UUID;
- CLI:`cmd_ios` 用 `/proc/sys/kernel/random/uuid` 填同样两个占位符。

对 iOS 来说,`PayloadIdentifier` + `PayloadUUID` 就是描述文件的身份。身份每次都变 ⇒ 每装一次
就是**新增**一个描述文件,而不是更新原来那个。用户手机上会越堆越多,而服务器这边完全不知道
堆了几个、哪个还在用。

同时期还有两条各自独立的病:CLI 那条路不支持强制直连 SSID、也不附 WLOC 根证书,于是同一台
网关走两条路拿到的文件内容不一样;WLOC 开着但 CA 读不出来时,Bot 会悄悄发一份**不含根证书**
的描述文件——装到手机上表现为被接管的站点全部证书报错,而没有任何一处指向真正的原因。

5.4 把这三件事一起收掉:给网关一个**永久身份**,把生成收敛成一份实现,并让"该拒绝的时候
真的拒绝"。

## 1. 不做什么(产品语义边界)

本项目**不是 MDM**,服务器无法确认 iPhone 上此刻装没装、装的是哪一版。所以文案只允许说:

- 当前生成版本 / 上次生成时间 / 上次**发送**时间;
- 当前网关配置相对已生成版本**是否发生变化**;
- "需要安装" / "建议重新安装" / "无需重新生成"。

**禁止**出现"已安装""设备已是最新版""更新已在手机生效""已替换手机上的旧描述文件"这类断言。
`tests/test-ios-profile-ux.py` 把这份禁用词表钉在每一屏文案上。

同一条原则也决定了**首次启用时要问一句**:"你以前在这台网关上装过描述文件吗?"服务器没有
任何办法知道,而用户知道。Bot 给两个按钮,CLI 问一行(`PDG_IOS_LEGACY` 供非交互场景显式
给出)。猜错的代价是用户手机上悄悄多出一个永远不会被更新的描述文件。

## 2. 稳定身份

- 首次启用时生成一次 `instance_id`(`uuid4`),持久化在元数据里,**永不再变**;
- 所有 payload 的 identifier/UUID 由 `uuid5(NS, instance_id + ":" + 角色)` 派生:
  角色固定为 `root` / `dns` / `ca`;
- 因此:同一网关重复生成完全稳定;不同网关的 `instance_id` 不同 ⇒ 身份不会互相替换
  (有人同时用两台网关);
- `instance_id` **不从** DoT 域名、IP、主机名、SSID、WLOC 状态推导 —— 那些都会变;
- `PayloadVersion` 恒为 Apple 规定的 `1`,不拿它当业务修订号(iOS 并不按它判新旧;
  业务修订号是独立的 `revision`)。

## 3. 修订号与语义 digest

`revision` 从 1 开始,**只有规范化语义输入变化时才 +1**。参与 digest 的字段:

`schema` · `dot_host` · `server_addresses` · `dns_protocol` · `probe_url` ·
`ondemand_core`(模板给出的按需规则骨架) · `ssids`(已排序去重) ·
`wloc_enabled` · `wloc_ca_sha256`

**不参与**:时间戳、临时路径、随机值、发送时间、文件名、模板路径。于是"点一下重新生成"在
输入没变时产出**逐字节相同**的文件,revision 不动,previous 不被顶掉,也不会凭空制造
"需要更新"。

`ondemand_core` 取自模板本身:升级换了模板能被识别成一次必须更新,而不是让用户拿着一份
规则骨架已经过时的描述文件继续用。

## 4. 两个互不相干的状态

这两件事必须分开表达。混成一句的后果很实在:用户以为该去动手机,而真正坏掉的**服务端文件**
反倒被一句温和的提示盖了过去。

### 4.1 配置变化等级 —— 关于设备

只回答一个问题:网关当前的语义配置相对已生成的那一版变了没有。分级表集中在
`iosstate.FIELD_LEVELS` 一处,Bot 与 CLI 都读它。`classify()` 的签名里**不接收产物字节**
——这条界限不是靠自觉维持的。

| 等级 | 触发 | 说明 |
|---|---|---|
| `none` 无需更新 | 规范化输入与当前版本一致 | 重新发送即可 |
| `recommended` 建议更新 | `ssids`(强制直连名单) | 核心连接仍可用 |

**SSID 名单是配置, 不是每次都要重报的参数。** 它进了 digest, 就等于成了受管配置的一部分,
所以"调用方没传"解释成**沿用**(`iosstate.effective_ssids`: `None` = 沿用, 传列表 = 明确
设置, 传空列表 = 明确清空)。反过来做的下场是两条: 状态页每次拿空名单跟记录比, 于是永远挂着
一条谁也没做过的「建议更新」; 而下一次普通生成会把用户配好的名单悄悄抹掉并推进一个版本。
| `required` 必须更新 | `dot_host`、`server_addresses`、`dns_protocol`、`probe_url`、`ondemand_core`、`wloc_enabled`、`wloc_ca_sha256`、`schema`;还没生成过;迁移未完成 | 不更新会连不上或信任链不对 |

### 4.2 产物健康状态 —— 关于服务端

`iosstate.artifact_health(meta, which)` 单独给出,current 与 previous 各判各的:

| 状态 | 含义 | 用户看到的 |
|---|---|---|
| `healthy` | 文件在、是普通文件、内容与记录逐字节相符、身份与 CA 指纹都对得上 | ✅ 服务端描述文件完整 |
| `missing` | 文件不在服务器上 | ⚠️ 服务端描述文件缺失,需要先修复后才能发送 |
| `corrupt` | 软链/硬链/空文件/读不出来/不是合法描述文件/组或其它可写/属主不对/含私钥 | ❌ 描述文件与生命周期记录不一致,已拒绝发送 |
| `state_mismatch` | 是一份好文件,但**不是记录说的那一份**:sha 不符、身份不是本网关、CA 指纹不符,或干脆是另一个 revision 串位过来的 | ❌ 描述文件与生命周期记录不一致,已拒绝发送 |

两条都不声称知道手机上的安装状态。

## 4.3 发送前一律 fail-closed

下面这些入口读取或发送文件之前**必须**走同一个 `iosstate.verified_artifact()`:
CLI 取 current / 取 previous、Bot 发 current / 发 previous、临时 HTTP 下载与二维码那一份、
diff、status。校验不过就抛,绝不退而求其次发一份旧的——"先看看有没有,有就发"是这类功能最
容易写成的样子,也是最坏的样子:用户拿到一份与服务器记录对不上的描述文件,而两边都以为一切
正常。

## 4.4 自动修复的边界

`current` 缺失或损坏时,**只有**下面几条全部成立才允许按记录复原(`iosstate.repair_current`):

- 元数据完整可读,记录里有 `current` 且带 `inputs` 与 `sha256`;
- 手上这张公开 CA 的**指纹与记录里那一版一致**(元数据里只有指纹,证书正文只在产物里——
  指纹对不上就说明手上的不是那一版用的证书,拿它渲染出来的是另一份文件);
- 用记录里的 `inputs` + 稳定身份重新渲染,结果的 sha256 与记录**精确相等**。

然后才写盘,且:**revision 不变、previous 一个字节不动、写完复核**。任何一条不成立就拒绝,
不猜、不新建身份、不推进 revision。

**`previous` 永远不重建。** 那一版用的根证书只在产物里有正文,服务器上早就没有了——凭当前的
证书"重建"出来的是另一份文件。丢了只有两条路:从备份恢复,或者如实显示"上一版不可用"。

## 5. current / previous

- `current.mobileconfig` + 元数据里的 `current`;
- `previous.mobileconfig` + 元数据里的 `previous`(只留一份,不做无限历史);
- **只有真正产生新 revision 时**,旧 current 才进入 previous;
- 可以重新发送 current、查看 current↔previous 的**字段级**差异、取回 previous 供手工回退;
- "取回 previous" **不会**把服务器的 current 改回旧版 —— 它只是把那份文件再给你一次;
- 差异只显示字段变化;CA 只显示 sha256 指纹前缀,不输出证书正文;
- token、私钥、代理链接一律不进文件、日志、审计与任何输出。

## 6. 老机器迁移

v1.7.8 之前每次都是随机身份,服务器**不知道**用户手机上装的是哪一份。所以首次启用受管生命
周期时(用户回答"以前装过"):

1. 生成新的稳定身份,revision=1,标记 `migration_pending`;
2. 更新等级强制 `required`,文案明确要求**先手工删除旧的 PrivDNS Gateway 描述文件**再安装新的;
3. **不声称**新文件会自动替换旧的随机身份文件(iOS 不会那么做,身份不同就是两个文件);
4. 完成一次迁移之后,身份固定,后续版本 iOS 会按"更新同一个描述文件"处理。

提供「旧描述文件我已删除」的**本地确认**开关(Bot 按钮 / `pdg ios ack`),它只是用户自述,
界面上直说"服务器无从核实",不作为"已安装"的证据。

## 7. 原子性

产物与元数据要么一起更新,要么一起不动。实现是最小文件事务(`iosstate._Txn`),证据与
`pdgtx` 对齐:

- 用**同一把**全局锁 `/run/privdns-gateway.lock`(`flock` 非阻塞),锁不可用即 fail-closed;
- 精确 before-image:记录每个目标的内容/mode/uid/gid;
- 原子 `os.replace`(复用 `pdgtx.atomic_write`);
- 任一步失败按 before-image 逐项还原(内容 + mode + owner),**还原后复核**;还原本身也
  失败时,把"回滚不完整"和原始错误一起报出来,不许只报后一件;
- **元数据最后写**。中途崩溃时产物可能比记录新,那种偏差下一次能发现(sha 对不上)并按
  记录重建;反过来则无法恢复——记录说的那一版已经没有文件了;
- 崩溃后残留的 `.cand` / `.pdgtx.*` 可识别可清理(`pdg ios recover`);
- 元数据损坏时**不自动重建身份**(那会造出第二个身份、把用户手机上的文件变成孤儿),而是
  fail-closed 并给出修复办法。

> ⚠️ 本模块的写操作**不能**在已持有那把锁的路径里调用(`pdg update` 持锁调 `__migrate`
> 就是这种路径),否则自死锁。生命周期只在用户主动生成时初始化。

WLOC 已启用但 CA 缺失/损坏/误指向 key 文件,一律**拒绝生成**。描述文件里只允许公开 CA
证书:PEM 解析、传入的 DER、最终字节各查一遍私钥标记(`iosprofile.reject_key_material`)。

## 8. 文件位置与备份语义

| 路径 | 内容 | pdgtx 目标 | 备份语义 |
|---|---|---|---|
| `/etc/privdns-gateway/ios-profile.json` | 身份 + revision + digest + 时间戳 | `ios_profile_state`(0600) | 进 CLI 快照、Bot 备份与恢复白名单 |
| `/var/lib/privdns-gateway/ios-profile/current.mobileconfig` | 当前产物 | `ios_profile_current`(0644) | 同上 |
| `/var/lib/privdns-gateway/ios-profile/previous.mobileconfig` | 上一版产物 | `ios_profile_previous`(0644) | 同上 |

三个目标的动作映射**显式写成空**,不是"没登记"——`actions_for_targets` 对没登记的目标是
fail-closed,靠遗漏表达"不需要动作"会在恢复时变成一次拒绝,而那看起来像是恢复功能坏了。

产物必须跟着备份走,不能靠"反正能重建":**previous 那一版用的根证书只在产物里有正文**,
元数据里只有指纹。它丢了就是真的没了。为此 `cmd_snapshot` 的候选集与 `cmd_rollback` 的越界
守卫都放行了 `var/lib/privdns-gateway/ios-profile` 这**一个子树**(不是整个 `var/lib`——
放宽到那一层等于让一份构造出来的快照可以往 tx 记录、备份包所在的地方写文件)。

### 恢复的原子性与旧格式备份

记录 + 两份产物挂在**同一笔** pdgtx 事务里(`_stage_ios_profile`),要么整组换过去,要么
一个都不动:绝不出现"记录说第 2 版、盘上躺着第 3 版"。任一目标落盘失败,三件一起回到操作前。

5.4 早期(以及更老)的备份里只有记录、没有产物。这种包被**认出来**并如实说明,不伪装成完整
恢复:记录里的 `previous` 一并清掉(不留一个点开就报错的"上一版"),`current` 保留记录但
产物需要另行修复——能不能修由 4.4 那几条决定,这里不越权替用户决定。

元数据是**用户持久数据**:普通 update、强制重装、平台来回切都不得动它;只有
`uninstall --purge` 或 `iosstate.clear()` 会放弃身份。`tests/test-ios-profile-persist.py`
把这四条路径逐个跑一遍再看盘上剩下什么。

## 9. 统一生成器

`deploy/bot/iosprofile.py` 是唯一的生成实现,`deploy/bot/iosstate.py` 是唯一的状态机:

- Bot(`deploy/bot/pdg-bot.py`)与 CLI(`deploy/bot/pdg.sh` 的 `cmd_ios`)都调它们;
- 它们**不反向 import** `pdg-bot.py`,输入全部显式传参,不读 Telegram 会话状态;
- 只用标准库(`plistlib` / `hashlib` / `uuid` / `json`),不新增第三方依赖;
- 注册进 `lib/modules.sh` 的 `PDG_IOS_MODULES`(install / update / uninstall 三方同一份清单);
- 输出只有一条序列化路径(始终 `plistlib.dumps`)。v1.7.8 在"没有 SSID 也没有 CA"时直接吐
  模板原文,连模板里那段讲部署细节的 XML 注释一起发给用户——受管生命周期要拿"字节是否
  相同"当证据,格式就不能取决于走了哪个分支。

## 10. 命令与入口

```
pdg ios                 # 生成/更新并临时提供下载(二维码)
pdg ios status          # 当前版本 / 上次发送 / 三档判定
pdg ios diff            # current ↔ previous 的字段级差异
pdg ios previous        # 取出上一版产物(不改当前版本)
pdg ios ack             # 用户自述旧描述文件已删除, 关掉迁移提示
pdg ios recover         # 清理中断残留, 检查产物与记录是否一致
pdg ios repair          # 按记录逐字节复原 current(复原不了就拒绝)
```

Bot:「📱 客户端」→「📱 iOS 描述文件」。Android 平台上这些入口既不显示,后端也逐个拒绝
(旧消息里的按钮被点、`/ios` 被打都拒),并且不产生任何文件、不写任何记录。

## 11. 相关用例

| 用例 | 盯的是什么 |
|---|---|
| `tests/test-ios-profile-legacy.py` | v1.7.8 现状的特征化快照;翻转出现在它的 diff 里 |
| `tests/test-ios-profile-shared.py` | Bot 与 CLI **真的跑两条路**再逐字节比对;私钥零外泄 |
| `tests/test-ios-profile-lifecycle.py` | 稳定身份、三档判定、current/previous、事务原子性 |
| `tests/test-ios-profile-ux.py` | 两个界面同一份记录、禁用词表、Android 全拒 |
| `tests/test-ios-profile-persist.py` | update / 快照回滚 / 备份恢复 / 平台来回切都不丢身份与产物 |
| `tests/test-ios-profile-integrity.py` | 六种人为损坏必须检出;两个状态互不污染;修复边界 |
| `tests/test-ios-profile-restore.py` | 快照与备份逐字节恢复(CA A→B→C)、旧格式备份、失败整组回滚、软链/硬链/权限 |

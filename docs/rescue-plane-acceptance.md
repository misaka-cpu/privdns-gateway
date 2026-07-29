# 独立救援平面 · 验收登记

救援平面(5.2)是"网关把自己配挂了之后,还能从内网卡进去把它捞回来"的那条通道。它的价值
全在**出事那一刻**兑现,所以哪些性质已经被真实验证过、哪些只是在沙盒里用桩比划过,必须
写下来分清楚 —— 否则等真出事的时候,没人知道当初到底验没验。

本文件是这件事的**唯一正式记录**。测试里的 `[SKIP]` 行可以引用它,但不能代替它:测试文件
会被重构、被拆分,而一条"还没验"的账不该跟着代码一起漂走。

- 代码位置:`lib/rescue.sh`(常量与清单真源)、`deploy/rescue/`(服务本体)、
  `deploy/bot/rescue_nft.py`(放行注入)、`deploy/bot/pdg.sh` 的 `cmd_rescue` / `migrate_rescue_plane`
- 相关测试:`tests/test-rescue-lifecycle.sh`、`tests/test-rescue-sets.py`、
  `tests/test-rescue-breakglass.py`、`tests/test-rescue-legacy-confirm.py`、
  `tests/test-rescue-server.py`、`tests/test-rescue-socket.py`、`tests/test-rescue-auth.py`

---

## 一、已验收(10a)

沙盒 + 有状态桩下的**行为验证**,不是源码比对:

| 性质 | 在哪验 |
| --- | --- |
| 四种意图状态可区分(未部署 / 用户开 / 用户关 / 装过但挂了) | lifecycle §12 |
| 用户 disable 过,升级迁移不许开回来 | lifecycle §5 |
| 只绑内网卡段内的本机地址,拒绝通配 | lifecycle §8 |
| 放行带来源约束、重复 enable 不堆规则 | lifecycle §2 |
| 撤放行只摘自己注入的独立表,不按端口删行 | lifecycle §9、§11 |
| 任一步失败回到操作前(unit / 启用 / 意图 / 防火墙) | lifecycle §14 |
| 两条 unit 渲染路径逐字节一致 | lifecycle §10 |
| 卸载删净装的东西、留下用户的东西、残留逐条上报 | lifecycle §9 |
| socket active + service inactive 判为健康、迁移零改动 | lifecycle §16 |
| 凭据不从 status / fingerprint / 日志 / 残留报告漏出 | lifecycle §3、§9 |
| 保护集 ⊂ 安装全集,且两者不是同一份 | sets §1–§3 |
| 救援模块闭包 = 真实入口算出来的那份 | sets §4、install-closure |
| 完整恢复能把业务模块换成旧版 | breakglass §1 |
| 换成旧版/损坏模块后仍能开页、标"旧核心不支持"、继续完整恢复 | legacy-confirm §2 |

---

## 二、10b 硬门(**已验收 · 2026-07-28**)

跑法:`sudo bash tests/e2e-rescue-10b.sh`(48 条断言全绿)。
环境:Debian 12 / Linux 6.1.0-35-cloud-amd64 / **systemd 252** / **nftables v1.0.6**,
真 PID 1 的 systemd,真内核 nft。隔离靠两个 netns + veth(客户端与网关分处两侧,流量真的过
网卡进 input 钩子)、`/run/systemd/system` 下的易失 unit、`/run` 下的沙盒目录;
脚本自带守卫复核宿主的 `/etc/privdns-gateway`、`/opt/pdg-bot` 与内核表全程未被改动。
unit 正文与生产渲染逐字节一致,沙盒差异只走 drop-in。

**这一轮抓到三个真缺陷**(都已修,各自有负控):

1. `ReadWritePaths` 没带 `-` 前缀 → 目录不存在时整个服务 `226/NAMESPACE` 起不来。
   纯 mihomo 装机没有 `/etc/sing-box`、换内核后没有 `/etc/mosdns`、新机器没有
   `/etc/nftables.conf` —— 救援平面偏偏会在**配置最乱的那台机器上**起不来。
2. `StartLimitIntervalSec=0` 写在 `[Service]`,systemd 当未知键**静默忽略**
   (252 原话:`Unknown key 'StartLimitIntervalSec' in section [Service]`),默认 10 秒 5 次
   仍然生效 —— 连崩几次就被判 failed 而不再拉起。已挪到 `[Unit]`,并用 `systemctl show`
   核实际生效值。
3. **独立表的 `accept` 盖不过另一张表的 `policy drop`**。nftables 同一 hook 上的多条基链会
   挨个走完,`accept` 只终止本链。于是恢复一份 5.2 之前的旧防火墙(`inet pdg` 里没有救援
   放行)之后,救援口**实测不可达** —— "恢复整份旧防火墙不会顺手切断救援入口"这个核心承诺
   当时是假的。现在除独立表外,还往每条 `policy drop` 的 input 基链链首补一条带标记的放行,
   幂等且可按标记精确撤销(不碰用户自己写的同端口规则)。

### systemd socket activation
- [x] 真 socket activation:socket 常驻监听,service 由连接触发(`ss` 在 netns 里看得见监听口)
- [x] `Accept=no` 语义下按需拉起:第二次连接由**同一个 PID** 处理,且没有 `pdg-rescue@N` 实例单元
- [x] 空闲时 service 就是 `inactive` —— 首次连接前实测 inactive,这是健康态
- [x] `FreeBind=true`:把地址从网卡删掉后 socket 照样 start 成功,地址补回来即可服务
- [x] service 崩溃(`kill -9`)后 socket 仍 active,下一次连接由**新 PID** 服务
- [x] `enable` / `disable --now` 在真 systemd 上的行为:disable 后监听口真的消失、连不进来

### 服务硬化(探针属性从生产 unit 逐行抓取后交给 `systemd-run`,不是手抄)
- [x] `ProtectSystem=strict`:往 `/usr` 写被真内核拒绝
- [x] `ReadWritePaths` 里的路径照常可写(硬化没把该写的地方一起封死)
- [x] `RestrictAddressFamilies` 含 `AF_NETLINK`(能开),`AF_PACKET` 被拒(白名单确实生效)
- [x] 硬化下 `nft` 与 `systemctl` 子进程仍可执行
- [x] 生效值核对:`MemoryMax=67108864`、`TasksMax=16`、`StartLimitIntervalUSec=0`

### nftables
- [x] 真实 `nft -c`:生产模板渲染出的整份配置通过;坏候选被拒
- [x] 真实应用与失败回滚:校验失败后现网 ruleset 逐字节未变
- [x] 反复注入不重复:内核规则数不变,**候选文本**里也只有一块一行(文件不会越堆越长)
- [x] 私网绑定与来源约束:内网来源连得通、非内网来源被拦。
      **先证前提再下结论** —— 撤掉 default-drop 后同一来源立刻连通,证明拦它的是防火墙
      而不是路由(第一版正是因为删地址连带清掉了回程路由,"拦住"过一次假绿)
- [x] 恢复旧快照后救援口仍可达(见上文第 3 条缺陷),补入行仍带来源约束、幂等、可精确撤销

---

## 三、10c 验收(性能与兼容性边界,**已验收 · 2026-07-29 · `.200`**)

- [x] 大事务 / 大快照的耗时 —— 归档 27,485,438 B / 180 成员 / 展开 69,379,265 B,事务内 1.397 s,端到端 2.20 s
- [x] `MemoryMax=64M` 下的真实表现 —— `memory.peak` 19,542,016 B(18.6 MiB),展开体积 66 MiB **超过**内存上限而没有被 OOM kill,证明是流式解包;`NRestarts=0`
- [x] 浏览器中途断线 —— 提交后立刻断开,事务照样 COMMITTED,文件逐字节回到基线,服务端吞掉写失败并记一行日志
- [x] 浏览器收尾断线 —— 断在事务结束前 0.067 s(回写撞到死连接,被吞)与结束后 0.035 s(响应已入缓冲区,零错误)两侧都覆盖
- [x] APPLYING 阶段 SIGTERM —— 已接下的写操作跑完(客户端仍拿到 200/COMMITTED),之后干净退出并被拉起
- [x] APPLYING 阶段 SIGKILL —— 事务停在 APPLYING;随后新写入被拒(事务目录数不变)、`pdg tx recover` 还原内容+权限+属主、再走一笔正常事务成功
- [x] `TimeoutStopSec` —— 临时把它压到 1 s 后 `systemctl stop`:`State 'stop-sigterm' timed out. Killing.` + SIGKILL + `Failed with result 'timeout'`;撤除临时 drop-in 后恢复 2 min,零残留
- [x] 跨版本快照矩阵 —— 见 `tests/test-snapshot-matrix.py`,样本由各版本自己的 `cmd_snapshot` 清单生成
- [x] iOS / Android 指纹核对说明 —— 见 `docs/rescue-plane-access.md`;Android 一节标了 `[SKIP:无真实设备]`

### 跨版本快照矩阵(实测)

样本不是手搓的:成员清单从各版本 `cmd_snapshot` 的 `cand=()` 里解析,legacy 用仓库最早那份真实
`deploy/dnsdist/dnsdist.conf`。只读历史对象,不切分支、不建 worktree。

| 样本 | 格式识别 | 受管恢复 | 完整恢复 | 末 6 位确认 |
|---|---|---|---|---|
| 当前分支 | `v1.6` | 允许 | 允许 | 要求 |
| v1.6.2 | `v1.6` | 允许 | 允许 | 要求 |
| v1.5.6(无 mihomo,9 项) | `v1.6` | 允许 | 允许 | 要求 |
| legacy-dnsdist | `legacy-dnsdist` | **拒绝** | 允许(强确认) | 要求 |
| unknown | `unknown` | **拒绝** | **拒绝** | — |
| 特征混合 | `ambiguous:v1.6+legacy-dnsdist` | **拒绝** | **拒绝** | — |
| 快照内坏业务模块(×3) | `v1.6` | 允许 | 允许 | 要求 |

v1.6.2 放行**不是**因为版本号新:它与 HEAD 的 `cmd_snapshot` 逐字节相同,结构确实一样。v1.5.6 那版
清单只有 9 项、且没有 `etc/mihomo/`,用它当前提哨兵,确保矩阵不是在拿同一份清单跟自己比。

`legacy-dnsdist` 只承诺"能整包解回去",**不承诺**恢复后核心服务一定能起来 —— 确认页原文就是这么写的。

### 自签证书指纹的安全语义(README / 登录页 / CLI / `docs/rescue-plane-access.md` 同一套说法)

1. 自签 HTTPS 只保证连接被加密,**不证明对面是谁**;能区分身份的只有证书指纹。
2. 指纹必须从独立渠道取得:SSH 上 `pdg rescue fingerprint`,或安装时预先存下。
3. **页面自己显示的指纹不能用来核对页面自己** —— 能伪造页面的人也能伪造上面那串指纹。
4. 浏览器看不到完整 SHA-256 指纹时,不要输 token;换电脑或改用 SSH。
5. `rotate cert` 之后指纹必然改变,必须重新从独立渠道核对一次;"我刚轮换过"不是跳过核对的理由。
6. `rotate token` 不改变证书指纹,只让已登录会话立即失效。
7. bind 是全局可路由地址时,访问控制靠 nft 来源网段 + 应用层按内核对端地址校验两层;这两层管
   "谁能连上来",不替代指纹核对。
8. token 与指纹不要放在同一条聊天记录/截图里。

### iOS / Android 实测状态

- iOS:`[SKIP:本会话无法驱动真实 iOS 设备]`。文档按版本中立表述写(不写死按钮名)。可从服务端
  确认的部分已实测:指纹值、`rotate cert` 后指纹确实改变、用旧指纹做证书固定确实连不上。
- Android:`[SKIP:无真实 Android 设备]`,只写与浏览器无关、可从协议本身确认的通用流程。

---

## 四、记账规矩

1. 沙盒里用桩验的,记在第一节,并在描述里写明"桩行为";**不许**往第二、三节打勾。
2. 真机验过的,勾上并补一行:日期、机器、内核/systemd 版本、跑了什么命令。
3. 环境不具备而没跑的测试,输出必须是 `[SKIP]` 且说明缺什么 —— 零断言退出 0 由总守卫判失败。
4. 本文件与测试里的 `[SKIP]` 文案对不上时,以本文件为准,并把测试改回来。

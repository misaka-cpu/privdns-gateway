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

## 三、10c 验收(性能与兼容性边界,**尚未验收**)

- [ ] 大事务 / 大快照的耗时(恢复几百 MB 快照时页面不能假死)
- [ ] `MemoryMax=64M` 下的真实表现:大快照会不会被 OOM kill
- [ ] 浏览器中途断线:已提交的事务不因连接断开而半途而废
- [ ] `TimeoutStopSec`:停服务时长事务的收尾行为
- [ ] 跨版本快照矩阵(v1.4.x / v1.5.x / v1.6 结构互相恢复)
- [ ] iOS / Android 上自签证书指纹的核对说明是否够用(用户第一次访问必须能核对指纹)

---

## 四、记账规矩

1. 沙盒里用桩验的,记在第一节,并在描述里写明"桩行为";**不许**往第二、三节打勾。
2. 真机验过的,勾上并补一行:日期、机器、内核/systemd 版本、跑了什么命令。
3. 环境不具备而没跑的测试,输出必须是 `[SKIP]` 且说明缺什么 —— 零断言退出 0 由总守卫判失败。
4. 本文件与测试里的 `[SKIP]` 文案对不上时,以本文件为准,并把测试改回来。

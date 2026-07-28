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

## 二、10b 硬门(**尚未验收**)

需要真 systemd 与真 nftables 的机器。沙盒里的桩只能证明"我们的代码按预期调用了它们",
证明不了"systemd/nft 真的那样做"。以下每一条在跑通之前,都不许记作已验证。

### systemd socket activation
- [ ] 真 socket activation:socket 常驻监听,service 由连接触发
- [ ] `Accept=no` 语义下按需拉起(一个 service 实例处理后续连接,不是每连接一个)
- [ ] 空闲时 service 就是 `inactive` —— 这是健康态,监控与文案都按此判
- [ ] `FreeBind=true`:绑定地址在网卡起来之前也能 listen
- [ ] service 崩溃后 socket 仍在监听,下一次连接能重新拉起
- [ ] `enable` / `disable` / `update` / `uninstall` 在真 systemd 上的行为与沙盒一致

### 服务硬化
- [ ] `ProtectSystem=strict` 下服务仍能读写它该读写的东西
- [ ] `ReadWritePaths` 覆盖到位(凭据目录、状态文件、事务暂存)
- [ ] `RestrictAddressFamilies` 含 `AF_NETLINK` —— 少了它 nft 相关子进程会被拦
- [ ] 硬化生效后 `nft` / `systemctl` 子进程仍可正常执行

### nftables
- [ ] 真实 `nft -c` 对候选内容的校验(桩里恒真)
- [ ] 真实应用、失败回滚、反复 enable 不产生重复规则
- [ ] 私网地址上的真实绑定与来源约束(内网可达、其它来源不可达)

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

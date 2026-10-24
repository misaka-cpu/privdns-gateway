# 发版前检查清单

每个要打 `v*` tag 的发布对象, 在打 tag 之前, 都在**一台 throwaway 机**(全新 Debian 12/13 或 Ubuntu 22/24)上把下面适用的各节跑一遍。
单元测试(`tests/`)覆盖不到"装机 / 升级 / sing-box→mihomo 迁移 / 退役"这类集成问题 —— 本清单专门抓它们。

**执行前登记**(登记在本次发布的包外发布记录里, 不写进本文件): 执行日期、throwaway 载体与它的身份、安装参数、证书路径、
取件来源、各条证据的存放路径与摘要。登记内容执行前核验; 核验不过就不执行。

**记录规则**
- 每一条都记三种结果之一: 判据成立 / 判据不成立 / 未取得(条件没提供或证据没拿到)。"结果已记录"不等于"判据成立"。
- 条件没提供时记"未取得", 不改检查口径, 不拿别的检查顶替。
- 一个发布对象的条目不能用另一个发布对象的检查结果顶替。
- 证据分三类, 各记各的, 不互相顶替:
  1. 历史验收: 在合成 tag 下、对指定候选提交做过的验收;
  2. 隔离预验: 用最终提交与**正式同名** tag, 在隔离取件源上做的验证;
  3. 官方取件验证: 对应 tag 推送到官方仓库之后, 从官方仓库取件做的验证。
  历史验收里用的是合成 tag, 不能把命令里的合成 tag 换成正式版本号后仍称"已验证"。
- `pdg update` 选中某个版本, 不等于这次升级成功; 升级是否成功只按各条的判据记。没有实测过的放行或拒绝行为, 写明"源码推断"。
- 任何一条判据不成立或未取得, 该发布对象就停在推送之前。要缩小范围或接受风险, 必须具名写出、获得明确批准;
  批准后原结果照原样保留, 不改成"判据成立"。
- 不读取、不记录任何秘密凭据的内容。

> **2026-08-20 订正**: ①里三处仍按"probe81 是 iOS 专属"写, 那是 6.1B 之前的形态 ——
> 它现在是**两平台公共必需件**。发 v1.10.5 时在沙盒里实测 Android 全新安装
> `pdg-probe81=active`, 回查 `lib/modules.sh:43`(公共清单)与 `migrate_probe81_public`
> ("自 6.1B 起是 Android/iOS 公共必需服务")确认是清单过时, 不是产品错。
>
> 本清单是照着真实翻过的车写的: v1.5.1(WLOC 开着时 `pdg update` 误回滚)、v1.5.2(从 v1.4.x 升级漏装
> `sb2mihomo`/`mitm_*` → switch-core 报 ModuleNotFoundError)、v1.5.5(切 mihomo 后 TG 代理 :8445 没渲染)。
> 这几个单测全绿、却都是部署才炸。

## 外部前提(执行前在包外发布记录登记并核验; 没有就记"未取得", 不降口径)

| 前提 | 用到的条目 |
|---|---|
| 有公网 IP 的 throwaway 机(载体与身份执行前登记) | 全部 |
| 测试用 bot 凭据与一个客户端账号(只登记"已提供", 不记录内容) | ① 的 pdg-bot active、平台隔离、旧 WLOC 按钮; ③ 测出口; ④ 描述文件; 桥接版 ① ④ 的 bot 条目 |
| 测试用 DoT 域名、它的 A 记录、匹配的内网卡段 | 安装本身(DoT 域名必需)、正式证书、各条"doctor 全绿" |
| 真实可达的出口 | ③ 测出口 |
| 仍支持 sing-box 的旧 tag 的安装来源 | ③(两个发布对象) |
| 真 iPhone | 桥接版 ④ 最后一条 |
| ② 各节的旧版前像 | ②-桥接、②-a、②-b(要求见"前像要求") |
| 两台线上金丝雀机器与生产授权 | "打 tag / 发布"一节里的金丝雀 |

装机用非交互 env。尖括号里的值全部取自执行前的参数登记, 不填生产值:
```bash
PDG_NONINTERACTIVE=1 \
PDG_PLATFORM=<ios|android> \
PDG_DOT_DOMAIN=<登记的测试 DoT 域名> \
PDG_SERVER_IP=<登记的公网IP> \
PDG_INTERNAL_CIDR=<登记的内网卡来源段, 如 172.22.0.0/16> \
PDG_SSH_PORT=<登记的 SSH 端口> \
PDG_BOT_TOKEN=<登记的测试 bot token, 可留空> PDG_ALLOWED=<登记的客户端账号 id, 可留空> \
[PDG_SKIP_CERT=1] \
  bash install.sh
```
- `PDG_DOT_DOMAIN` 是必需的: 非交互时为空, 安装器直接停止(install.sh 第 662 行)。
- `PDG_INTERNAL_CIDR` 取不到来源段时安装器也停止; `PDG_SERVER_IP`、`PDG_SSH_PORT` 不给时按探测值; `PDG_PLATFORM` 不给时非交互默认 android。
- `PDG_BOT_TOKEN` / `PDG_ALLOWED` 可留空, 但留空时依赖 bot 的条目记"未取得"。

证书三件事分开记, 不互相代替:
- **自签占位**(`PDG_SKIP_CERT=1`): 不签正式证书, 生成一张 CN 为 DoT 域名的自签占位证书。只用于不验证书的条目。
- **正式证书**(不设 `PDG_SKIP_CERT`): 安装时由 certbot 签发, 要求 DoT 域名的 A 记录已指向本机、80 口能从公网到达; 签不出来安装就停。
  证书是否被客户端信任, 另外从外部按证书链校验一次并记录; 安装成功不等于这一项成立。
- **doctor**: "证书"一项只看证书文件存在、离过期 14 天以上; `--deep` 的"DoT 握手"只看握手完成、CN 与 DoT 域名一致, 不校验证书链。
  所以"doctor 全绿"不证明正式证书有效, 用自签占位时同样可以全绿。

## 本次发布的顺序与各节适用范围(路线: 先桥接后退役)

本次有两个发布对象, 各自打 tag 之前各跑一遍适用的条目:

1. **桥接版 v1.11.16**(tag 指向正式桥接提交 `7d0020852b18eeac8597a1f01d627a458ced9e4f`, 即 `release/v1.11.16-bridge` 的 head)。
   - 桥接版是 WLOC 退役**之前**的形态(iOS 上仍装 `pdg-mitm` 与 WLOC 模块)。本清单的 ①、④ 写的是退役后的期望, **不适用于桥接版**。
   - 桥接版逐项跑"桥接版逐项"一节(来自它自己 tag 树里的清单 ①③④⑤)与"②-桥接"一节。
   - 本清单的"执行前登记""外部前提"与"记录规则"同样适用。
2. **退役版 v1.12.0**(tag 指向退役发布提交; tag 与提交的对应在提交完成后登记于包外发布记录, 不写回本文件)。
   - 按本清单全文: ①、④、⑤; ② 按"②-a / ②-b"; ③ 的范围【待决定】。

打 tag 之前的验证用最终提交与隔离取件源(给最终提交打**与正式同名**的 tag)。
让 throwaway 机从隔离取件源装机、升级、而不改被测对象, 这件事的可行性【待确认】; 不可行的条目记"未取得", 不拿官方取件的结果顶替。
依赖官方仓库取件的条目, 在对应 tag 推送之后才取得(见"打 tag / 发布"), 不作为该 tag 自身的推送前提。

---

## 桥接版逐项(只对桥接版 v1.11.16)

依据: 桥接版 tag 树里的 `docs/RELEASE-CHECKLIST.md`(blob 04f60dcb)。下面逐条照录, 编号后的行号是那份清单的行号; 一条不删。
桥接版的 ② 由下面的"②-桥接"代替(逐条对应见那一节)。范围未定的条目标【待决定】, 在决定之前原样保留, 不视为本次不覆盖。

### 桥接 ① 全新安装(两种平台; 那份清单第 22–39 行)
至少跑 **iOS** 和 **Android** 两组(内核统一 mihomo)。全新安装要装到桥接版本身; 入口的两段来源与目标选择按"打 tag / 发布"的登记要求记录。
- [ ] (26)`pdg doctor` 全绿(无 🔴/🟡)。【前提: DoT 域名与内网卡段; doctor 的证书项含义见上】
- [ ] (27)服务全 active: `systemctl is-active mosdns mihomo pdg-bot pdg-probe81`(iOS 追加 `pdg-mitm`); `pdg-probe81` 两个平台都 active;
      Android 上 `pdg-mitm` 不存在(`systemctl is-enabled` 报 not-found), 7894 不监听; sing-box 二进制 / 服务都不存在。【pdg-bot 的前提: bot 凭据】
- [ ] (32)平台专属模块只在对应平台: iOS `ls /opt/pdg-bot/{mitm_ca,mitm_server,mitm_wloc}.py` 齐; Android 这三个 + 描述文件模板都不存在; `sb2mihomo.py` 与 `probe81.py` 两平台都在。
- [ ] (34)平台门控: iOS doctor 有「MITM 插件」「MITM结构」「平台=ios」无「GMS 推送」; Android 反之(有 GMS、无 MITM); probe81 两平台都有。
- [ ] (36)平台隔离(硬门控): Android bot「📱 客户端」无「iOS 描述文件」按钮; 点旧消息里的 iOS/WLOC 按钮被拒; `sudo pdg ios` 友好拒绝(不装 qrencode、不开 8443); iOS 有描述文件/WLOC。【前提: bot 凭据与客户端】
- [ ] (37)描述文件取件通道: `sudo pdg ios` 与 `sudo pdg ios previous` 都打出二维码, 其间 8443 有监听与临时放行; 回车收尾后两者都没有。
- [ ] (38)iOS 无 GMS 残留: `grep -c in-gms /etc/sing-box/config.json` = 0; `nft list ruleset | grep 5228` 无。
- [ ] (39)平台标记: `cat /etc/privdns-gateway/platform` 为 ios/android; 缺失时 `pdg status`/doctor 明确提示「按 Android 回退」而非静默。

### 桥接 ③ 从 sing-box 旧版升级 → 自动迁移到 mihomo(那份清单第 53–64 行)
本节对桥接版是否适用、用哪个旧 tag: 【待决定(支持范围; 须在推桥接 tag 之前决定)】。决定之前原样保留。
先装一个仍支持 sing-box 的旧 tag(如 `PDG_CORE=singbox` 装 v1.5.x), 确认在 sing-box 上跑通, 再 `pdg update` 到桥接版。旧 tag 前像按"前像要求"核身份。
- [ ] (59)`pdg update` 成功、不回滚; `cat /etc/privdns-gateway/backend` = `mihomo`。
- [ ] (60)sing-box 已彻底移除: `systemctl is-enabled sing-box` 报 not-found、`ls /usr/local/bin/sing-box` 不存在。
- [ ] (61)`systemctl is-active mihomo` = active; `pdg doctor` 全绿。【前提同桥接 ①】
- [ ] (62)所有入站都在: `ss -tlnp | grep -E ':(80|443|5228|8445)'` —— 尤其 :8445(TG 代理)有人听。
- [ ] (63)出口 / 分流全保留: bot「🚦 测出口」每个出口都返回延迟; direct 出口(jp)也通。【前提: bot 凭据与真实出口】
- [ ] (64)有不可转换出口时: config.json 里放一个 mihomo 不支持的出站, `pdg update` 应中止并回滚到旧 sing-box 版(数据无损), 报出该出口名。

### 桥接 ④ WLOC(仅 iOS 装机; 那份清单第 66–71 行)
- [ ] (68)bot「🍏 位置改写」: 加地点(点按钮和直接发「名称 纬度,经度」两种都试)、切换、开启。【前提: bot 凭据与客户端】
- [ ] (69)`systemctl is-active pdg-mitm` = active; `pdg doctor` 有「🟢 MITM 插件」。
- [ ] (70)`/etc/mihomo/config.yaml` 有 `MITM-OUT` + `DOMAIN-SUFFIX,gs-loc*` 规则; `mitm_hijack.txt` 有 gs-loc 两域名。
- [ ] (71)(有真 iPhone 时)内网卡 + 控制中心关 WiFi + 定位服务关开 → 定位改到设定城市。【前提: 真 iPhone】

### 桥接 ⑤ 卸载(那份清单第 73–79 行)
```bash
bash uninstall.sh --purge
```
- [ ] (78)服务全 disable + 删: `mosdns sing-box mihomo pdg-bot pdg-probe81 pdg-mitm`。
      桥接版 uninstall.sh 另外处理的服务是否一并核对【待决定】。
- [ ] (79)`--purge` 后 `/etc/privdns-gateway`、`/etc/mihomo` 都删掉。

---

## ① 全新安装(两种平台; 只对退役版)

至少跑 **iOS** 和 **Android** 两组(内核统一 mihomo)。装完:

- [ ] `pdg doctor` 全绿(无 🔴/🟡)。【前提: DoT 域名与内网卡段; doctor 的证书项含义见上】
- [ ] 服务全 active: `systemctl is-active mosdns mihomo pdg-bot pdg-probe81`。【pdg-bot 的前提: bot 凭据】
      **`pdg-mitm` 两个平台都不该存在**(WLOC 已退役): `systemctl is-enabled pdg-mitm` 报 not-found, 7894 不监听。
      **`pdg-probe81` 两个平台都该 active** —— 它自 6.1B 起是公共必需件(链路诊断的 HTTP 会话入口),
      见 `lib/modules.sh` 的公共清单与 `migrate_probe81_public`。
      **sing-box 二进制 / 服务都不应存在**。
- [ ] **DoT 证据端**: `pdg-dotwitness` loaded / enabled / active, 127.0.0.1:5399 的监听者在它的 cgroup 里。
- [ ] **平台专属模块只在对应平台**: iOS `ls /opt/pdg-bot/{iosprofile,iosstate,mitm_ca}.py` 齐;
      **`mitm_server.py` / `mitm_wloc.py` 两个平台都不该在**(已退役);
      **Android 这三个 + 描述文件模板都不应存在**。`sb2mihomo.py` 与 **`probe81.py`** 两平台都在。
- [ ] 平台门控对: **iOS** doctor 有「平台=ios」无「GMS 推送」; **Android** 反之。
      doctor 里**不该再有**「MITM 插件」「MITM结构」两项(已随 WLOC 退役移除)。
      probe81 不在门控范围内 —— 两平台都有。
- [ ] **平台隔离(硬门控)**: **Android** bot「📱 客户端」无「iOS 描述文件」按钮; 点旧消息里的 iOS 按钮被拒;
      `sudo pdg ios` 友好拒绝(不装 qrencode、不开 8443)。**iOS** 有描述文件。【bot 部分的前提: bot 凭据与客户端】
- [ ] **旧 WLOC 按钮**: 两个平台点旧消息里的 `wloc:*` 按钮都回**退役提示**(不是沉默、不是堆栈), 运维菜单里没有「位置改写」入口。
      【前提: bot 凭据、客户端与一段旧版会话】
- [ ] **描述文件取件通道**: `sudo pdg ios` 与 `sudo pdg ios previous` **都**打出二维码, 其间 `ss -ltn | grep 8443` 有监听、
      `nft list ruleset | grep 8443` 有临时放行; 回车收尾后两者都没有。(5.4 早期 `previous` 只把文件写到服务器上, 手机拿不到。)
- [ ] **iOS 无 GMS 残留**: `grep -c in-gms /etc/sing-box/config.json` = 0; `nft list ruleset | grep 5228` 无。
      (`/etc/sing-box/config.json` 是数据模型, 全新安装会生成; 不是 sing-box 运行时。)
- [ ] **平台标记**: `cat /etc/privdns-gateway/platform` 为 ios/android; 缺失时 `pdg status`/doctor 明确提示「按 Android 回退」而非静默。

## ② 从上一个发布版升级(最容易翻车)

### 前像要求(②-桥接、②-a、②-b 共用)
- 前像是旧版**已经安装**好的机器, 不是旧源码。现役 CLI(`/usr/local/bin/pdg`)、`/opt/pdg-bot` 下的模块、
  systemd unit 与服务, 都要来自那一版的安装。
- 只在 `/opt/privdns-gateway` 里 `git checkout <旧 tag>` **不算**前像: 那只换了源码树, 已装的 CLI、模块和服务还是原来的。
- 升级前核身份并记录, 任何一项核不出就不算前像:
  - `/opt/privdns-gateway` 的 HEAD 等于旧 tag 的提交;
  - `/usr/local/bin/pdg` 与那个提交里的 `deploy/bot/pdg.sh` 逐字节相同;
  - `/opt/pdg-bot` 下的模块按那个提交 `lib/modules.sh` 的平台清单逐个逐字节相同;
  - 平台、WLOC 开关、服务运行态与自启态记录在案。
- 前像怎么建【待决定】; 建完按上面核身份。入口的两段要分别登记(见"打 tag / 发布")。已知的入口行为(源码阅读与隔离模型):
  - v1.11.15 与它之前的 install.sh 两段都不解析 `--ref`, 也没有身份门; 作第二段时会照装取件后最高的 `v*` tag。
    桥接 tag 推出之后, 直接用 v1.11.15 的入口装, 实际装到的是桥接版。
  - 桥接或退役版的 install.sh 作第一段、带 `--ref v1.11.15` 时, 第一段选中 v1.11.15 并把参数交给 v1.11.15 的第二段("方案 B")。
    这条接线有隔离模型证据(本地隔离裸库与合成 tag, 止于已有部署门之前); 完整安装没有运行过。用它建前像时,
    安装是否完成、装出的是不是 v1.11.15, 一律按上面的身份要求核, 不以接线证据代替。
- 是否另用 v1.11.15 自己的完整安装入口装一台, 作为前像忠实度的对照【待决定】。若做, 安排在推送桥接 tag 之前; 未决定不等于不做。
- 每一次升级调用各用一台单独重建、核过身份的前像。
  同一台机器升级完成后再换一种调用, 只会走"已是最新 / 已是钉版目标 —— 无需更新"的短路。那不是另一条升级路线的结果, 不得记为通过。

### ②-桥接: v1.11.15 → 桥接版(只对桥接版)
对应桥接树清单的 ②(第 41–51 行)。那一节写的是"先装上一个 tag, 再 `pdg update` 到本版"; 这里把它拆成两种调用,
每种调用都核那一节的全部四条, 并加上桥接版新增能力的一条。
**不能用退役版的检查抵充**: ②-b 的模块检查核的是退役版的模块清单; ④ 与 ②-b 的 WLOC 条目核的是 `pdg-mitm` 已经撤除,
而桥接版上 `pdg-mitm` 仍在, 要核的是它被正确重启。

两种调用, 各在一台按"前像要求"单独重建并核过身份的 v1.11.15 前像上跑, 结果分开记:
1. 普通 `pdg update`(旧版 CLI 按选择逻辑会选中当时最高的 `v*` tag; 选中不等于升级成功, 是否成功按下面各条记);
2. 按 `docs/BRIDGE-ENTRY.md` 的入口流程, 从核验过的副本运行 `pdg update --to v1.11.16`。

每种调用都核:
- [ ] `pdg update` **成功、没触发回滚**(校验门过)。
- [ ] **新增的 bot 模块升级后就位**(`ls /opt/pdg-bot/sb2mihomo.py` 等, 按桥接树 `lib/modules.sh` 的平台清单)
      —— 靠 `migrate_deploy_botfiles` 自愈; 缺了说明迁移没跑到。
- [ ] `pdg doctor` 全绿。【前提同①】
- [ ] **iOS + WLOC 开着**时升级: 不因「pdg-mitm 未运行」误回滚(pdg-mitm 有被 `reset-failed` + 重启)。
      每种调用至少有一台前像是 iOS 且 WLOC 开着, 而且这是一次真实升级(从 v1.11.15 升到桥接版);
      已经在桥接版上再跑一次 `pdg update` 只会走"无需更新"短路, 不算。
- [ ] **桥接版新增能力就位**: 现役 CLI 有 `_pdg_save_svcstate` / `_pdg_restore_svcstate`。

证据类别与时点:
- 推送桥接 tag **之前**: 两种调用都做隔离预验(正式同名 tag v1.11.16); 各条判据都要成立。
- 桥接 tag 推送**之后**: 普通 `pdg update` 那一种做官方取件验证。与隔离预验分开记, 不能互相顶替。

### ②-a: 旧版直接 `pdg update` 到退役版(不经桥接; 只对退役版)
前像按"前像要求"建并核身份。
- [ ] 前像有退役工作(WLOC 开着、或 iOS 记录待推进)时, 按实际执行顺序核:
      - 旧版 CLI 做完更新前快照、取件(切到退役版 tag)和装件(装上退役版的 CLI 与模块);
      - 旧版调用退役版的 `pdg __migrate`, 退役版在迁移链入口(调用方门)拒绝, 迁移链里后面的迁移一个都不跑;
      - 旧版接着按更新前快照回滚; 现场回到更新前(文件、服务运行态与自启态、DNS 行为), CLI 与仓库回到旧版;
      - 输出说清下一步;
      - 回滚输出里描述文件那一行是新文案。文字与实际恢复结果分开核, 文字不作恢复证据。
      这一条核的是整次 update 的顺序与终态。"拒绝那一刻退役工作一项都没做"是另一件事: 要单独采样拒绝那一刻,
      不能由终态推出, 也不能把它外推到整次 update。
- [ ] 前像没有退役工作时: 记录实际结果(被放行时按 ②-b 的判据核终态)。这一条按源码会被放行(源码推断), 尚无实测。

### ②-b: 旧版 → 桥接版 → 退役版(只对退役版)
- [ ] 进入桥接: 入口流程加 `--to` 的方式有历史验收(合成 tag 下, 条件见 `docs/BRIDGE-ENTRY.md` 第六节); 普通 `pdg update` 进入桥接的结果按"②-桥接"另记。
      进入后按"前像要求"核桥接版身份(HEAD = `7d0020852b18eeac8597a1f01d627a458ced9e4f`、CLI 与模块逐字节等于桥接树), 再往下做。
- [ ] 在桥接版上升到退役版, 两种方式各在一台单独的桥接版前像上跑(同一台升过一次就已是最新, 第二次只会走"无需更新"短路, 不算):
      `pdg update --to v1.12.0` 与普通 `pdg update`。都要**成功、没触发回滚**。
      普通 update 选中退役版 tag 不等于升级成功, 以本节各条为准。
      证据类别与时点: 推送退役 tag **之前**, 两种方式都做隔离预验(正式同名 tag v1.12.0), 判据都要成立;
      退役 tag 推送**之后**, 普通 update 做官方取件验证, 分开记。
- [ ] **新增的 bot 模块升级后就位**(`ls /opt/pdg-bot/sb2mihomo.py` 等, 按平台清单逐字节等于本版) —— 靠 `migrate_deploy_botfiles` 自愈; 缺了说明迁移没跑到。
- [ ] 升级输出里恰有一行"DoT 证据端: …", 记录它的类别。
      它是经 `__migrate` 入口且迁移链成功后的核验, 不是整次升级的最终健康保证;
      本步骤按退出政策甲返回 0, 父进程后续步骤仍可能失败并回滚。
      升级后另核: `pdg-dotwitness` active, 5399 由它持有。
      出现警告类报告时照实记录, 不当成升级失败, 也不当成服务健康。
- [ ] `pdg doctor` 全绿。【前提同①】
- [ ] **从一台 WLOC 开着的老机器**升级: `pdg update` 后
      - pdg-mitm 已停且 unit 已删;
      - `mitm_hijack.txt` 空;
      - `/etc/mihomo/config.yaml` 无 `MITM-OUT`;
      - `mitm.json` 里 `enabled=false` 但地点还在;
      - `/etc/privdns-gateway/ca/` **仍在**(保留策略), 且升级输出里提示了它。
      **再升一次不重启任何服务(幂等)。**

## ③ 从 sing-box 旧版升级 → 自动迁移到 mihomo(v1.6.0 关键路径; 只对退役版)

本节对退役版是否适用、具体用哪个旧 tag: 【待决定】。
在决定之前, 本节要求原样保留, 不视为本次不覆盖。(桥接版的 ③ 见"桥接版逐项"。)

先装一个**仍支持 sing-box 的旧 tag**(如 `PDG_CORE=singbox` 装 v1.5.x), 确认在 sing-box 上跑通, 再按 ②-b 的顺序经过桥接版升到本版。
旧 tag 前像同样按"前像要求"核身份。经桥接时第一次跑 `migrate_drop_singbox` 的是桥接版。
```bash
pdg update     # __migrate 里自动 sing-box → mihomo
```
- [ ] `pdg update` 成功、不回滚; `cat /etc/privdns-gateway/backend` = `mihomo`。
- [ ] **sing-box 已彻底移除**: `systemctl is-enabled sing-box` 报 not-found、`ls /usr/local/bin/sing-box` 不存在。
- [ ] `systemctl is-active mihomo` = active; `pdg doctor` 全绿。【前提同①】
- [ ] **所有入站都在**: `ss -tlnp | grep -E ':(80|443|5228|8445)'` —— 尤其 **:8445(TG 代理)有人听**。
      (5228 只在 Android 平台存在: iOS 上数据模型不含 GMS 入站, 见 install.sh 的 iOS 分支。)
- [ ] **出口 / 分流全保留**: bot「🚦 测出口」每个出口都返回延迟、不报「超时/不通」;
      **direct 出口(jp)** 也通(它在 mihomo 里映射成内建 `DIRECT`)。【前提: bot 凭据与真实出口】
- [ ] **有不可转换出口时**: config.json 里放一个 mihomo 不支持的出站, `pdg update` 应**中止并回滚到旧 sing-box 版**(数据无损), 报出该出口名。

## ④ WLOC 退役核验(老机器升级后; 只对退役版)

- [ ] `systemctl is-active pdg-mitm` 报 inactive/not-found; `ss -lntp | grep 7894` 无输出。
- [ ] `/etc/mihomo/config.yaml` 里**没有** `MITM-OUT`, 也没有 `DOMAIN-SUFFIX,gs-loc*`。
- [ ] `/etc/mosdns/rules/mitm_hijack.txt` **存在且为空**(文件本身不能删 —— mosdns 的 `force_hijack` domain_set 指着它, 删了 mosdns 起不来)。
- [ ] `/etc/privdns-gateway/mitm.json` 里 `"enabled": false`, `locations` 仍在(用户数据保留)。
- [ ] `/etc/privdns-gateway/ca/` **仍在**, 升级输出提示了"取消手机上的信任 + 可自行删除"。
- [ ] bot 里重新生成一份 iOS 描述文件: **不含** `com.apple.security.root` payload。【前提: bot 凭据与客户端】
- [ ] `pdg doctor` 全绿, 且没有「MITM 插件 / MITM结构 / WLOC」任何一项。【前提同①】

## ⑤ 卸载(只对退役版)

```bash
bash uninstall.sh --purge
```
- [ ] 服务全 disable + 删:
      `mosdns sing-box mihomo pdg-bot pdg-probe81 pdg-mitm pdg-dotwitness pdg-health.timer pdg-rules-update.timer pdg-rescue.socket pdg-rescue.service pdg-lan`。
      (后六个是本次补进核对的, 依据: 本版 uninstall.sh 对它们都有处理。)
- [ ] `--purge` 后 `/etc/privdns-gateway`、`/etc/mihomo` 都删掉。

---

## 打 tag / 发布(路线: 先桥接后退役)

**要点**
- 推送 `v*` tag 就开始影响用户: `pdg update`、bot「检查更新」与 `install.sh` 默认安装都取本地取到的最高 `v*` tag。
  是否创建 Release、是否标 latest, 都不是隔离手段。tag 推出后再删或改指向, 撤不回已经据此升级的机器。
- README 一键安装的第一段取自 main 当时指向的提交; main 推送会改变这一段, 并触发 `ci.yml`(push 只认 main); tag 推送不触发。
- 每一个推送动作(分支、桥接 tag、退役 tag、main)都要: 本节为它列出的推送前判据全部成立, 并有针对这一个动作的明确授权。
  只核远端现状或先后顺序, 不足以执行。建 Release 与金丝雀同样单独授权。
- 推送后才能取得的检查, 不是该动作自身的推送前提; 它们判据不成立或未取得时, 停止之后的动作(下一个 tag、main、Release、金丝雀、推广)。
- 推送前核对官方仓库: 没有同名 tag; main 与本次依赖的祖先关系仍成立。另行授权查询; 发现冲突就停, 不自行换号。

**入口的登记要求**(凡是经 install.sh 安装的条目, 隔离预验与官方取件验证都按此登记):
- 第一段: 来源(URL 或本地路径、取自哪个 ref)与 sha256、与哪个提交的 install.sh 相同、是否解析 `--ref`;
- 参数交接: 第一段交给第二段的参数与环境(原样记录);
- 目标选择: 由哪一段选、选中哪个 tag 与提交;
- 第二段: 实际执行的 install.sh 的来源与 sha256;
- 身份门: 在哪一段、放行还是拒绝、原文输出;
- 安装是否完成与装出的身份, 按 ① 或"前像要求"另核。
  第一段不解析 `--ref`, 不等于参数无效: 第二段是桥接版或之后的版本时, 由第二段的身份门判定(指定的是当时最高 tag 时按源码放行,
  低于最高 tag 或不存在时拒绝、不进入安装); 第二段是 v1.11.15 时参数被忽略。不能用其中一段的行为推断整条入口。

**第一步: 桥接版 v1.11.16**
- 推送前判据(全部成立):
  - 桥接版标准 CI 判据成立(正式桥接提交上已有 run 39788138250 / #511 attempt 1 success; tag 若改指别的提交须重取);
  - "桥接版逐项"与"②-桥接"的隔离预验, 各条判据成立;
  - 适用于桥接版的风险处置与支持范围已经明确决定(见包外待决表), 范围变更或风险接受已具名批准;
  - 是否做完整旧安装入口对照已经决定, 若做, 判据成立;
  - 桥接窗口期间的用户说明已经在【桥接窗口用户说明渠道待决定】就位, 入口流程要用的预期身份已经可以从【受信交付渠道待决定】取得;
  - 官方仓库核对无冲突;
  - 针对这次推送的明确授权。
```bash
git tag -a v1.11.16 7d0020852b18eeac8597a1f01d627a458ced9e4f -m "v1.11.16"
git push origin v1.11.16                  # 不推 main: 桥接提交不能快进 main
```
- Release 正文: 【待决定(现行写法为正文留空)】。
- 推送后(官方取件验证): "②-桥接"的普通 update 一条; install.sh 默认安装(按入口登记要求); `--ref v1.11.16` 经 README 入口(第二段身份门判定); bot 检查更新; 其它官方取件项目【待决定】。
- 金丝雀【另行授权】: 两台线上 `pdg update`, 各 `pdg doctor --deep` 收尾。
- 桥接窗口什么时候结束、进入第二步【待决定】。

**第二步: 退役版 v1.12.0**
两个推送动作, 各自的推送前判据与授权分开:
- 动作 T(推退役 tag)的推送前判据(全部成立):
  - 退役发布提交的树差异: 相对父提交只改 `CHANGELOG.md`、`docs/RELEASE-CHECKLIST.md`、`docs/BRIDGE-ENTRY.md`; 其它树条目的路径、类型、权限和内容不变;
    `docs/BRIDGE-ENTRY.md` 的执行标记段逐字节不变;
  - 退役发布提交的标准 CI 判据成立;
  - 本清单 ①–⑤ 的隔离预验, 各条判据成立;
  - 第一步推送后的各项判据成立; 桥接窗口结束条件已满足;
  - 官方仓库核对无冲突;
  - 针对这次推送的明确授权。
- 动作 M(main 快进到退役发布提交)的推送前判据(全部成立):
  - 退役发布提交的标准 CI 判据成立, 树差异同上;
  - 退役版 install.sh 作为 README 入口第一段时的隔离预验判据成立 —— 按快进那一刻官方仓库里实际会有的 tag 集合做(取决于先后);
  - 官方 main 仍是退役发布提交的祖先(另行授权查询);
  - 针对这次推送的明确授权。
- 两个动作的先后【待决定】, 本清单不规定。各种先后下的中间状态写在包外发布材料里。本文件旧版第 94 行的写法是先推 main 再推 tag, 本次不沿用为既定顺序。
```bash
# 动作 T: 打退役 tag 并推送。<退役发布提交> 用提交完成后在包外发布记录里登记的 40 位 SHA。
git tag -a v1.12.0 <退役发布提交> -m "v1.12.0"
git push origin v1.12.0
# 动作 M: main 快进到退役发布提交。会在该提交上触发 ci.yml。
git push origin <退役发布提交>:main
```
- Release 正文: 【待决定】。
- 推送后(官方取件验证), 按选定的先后分别做, 不互为前提:
  - 先 T 后 M: T 之后 —— ②-b 的普通 update 一条、经 README 入口(第一段仍是旧 main)的默认安装; M 之后 —— 经 README 入口(第一段换成退役版)的默认安装、main 上 ci.yml 的结果;
  - 先 M 后 T: M 之后 —— main 上 ci.yml 的结果、经 README 入口(第一段是退役版, 最高 tag 仍是桥接)的默认安装; T 之后 —— ②-b 的普通 update 一条、默认安装;
  - ②-a 经官方取件是否纳入【待决定】。
- 金丝雀【另行授权】: 先确认 jp2 的 doctor 现状; 两台线上先确认已在桥接版, 再 `pdg update`, 各 `pdg doctor --deep` 收尾。

# PrivDNS Gateway

**单入口、多出口的「私密 DNS 分流网关」** —— 手机端**只设系统私密 DNS(DoT)**,不装任何 VPN / Clash / sing-box 客户端;
服务端按域名把流量分到不同落地或直连。

> 🚀 **第一次部署?** 跟着 **[新手图文教程 →](docs/QUICKSTART.md)** 一步步来(从买 VPS 到手机连上,全程带图)。

```
 手机 (Android 私密DNS / iOS 描述文件, 仅 DoT)
   │  DoT :853
   ▼
 网关 VPS ── mosdns ──► 国内域名: 返回真实 IP (直连)
   │                   代理域名: A 记录劫持成「本机 IP」, AAAA/HTTPS 置空
   │  :80/:443 sniff SNI
   ▼
 sing-box ──► 按域名分流: AI/加密→落地A  其余国际→落地B  默认→本机直出
```

核心思想:**把 DNS 当策略引擎**。
代理域名的 A 记录被改写成网关自己的 IP,流量于是回到网关;
sing-box 嗅探 SNI/Host 后再决定走哪个落地。
手机全程只有一条「私密 DNS」设置,没有任何客户端、没有 tun。

---

## ⚠️ 这个项目适合谁 / 前提

它**不是通用翻墙工具**,依赖一个特定拓扑:

- 一台**墙外 VPS**(网关 + DNS)。
- 一张运营商「**内网卡 / 定向内网 SIM**」—— 手机的移动流量经运营商私网到达你 VPS,且**源 IP 是固定私有段**(如 `172.x`)。
  网关靠这个私有源段来区分「该劫持的查询」和别人。
  - 没有这种内网卡 → DNS 劫持会影响到所有查询源,不适用本项目。
- 一个你能改 DNS 记录的**域名**(给 DoT 用,签 Let's Encrypt 证书)。
- 一个 **Telegram bot**(管理出口/分流)。
- 一个或多个**落地节点**,用来出国际流量(可选,默认其余国际从 VPS 直出)。出口跑在 sing-box 上,**协议支持 sing-box 的全部出站**;bot 能直接粘贴的链接见下。

---

## 一键安装 (Debian 12+ / Ubuntu 22+)

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

入口脚本只负责自举,实际安装会自动切到最新 `v*` 发布 tag,不安装 main 上未发布的中间提交。

### 选择流量内核:sing-box(默认)还是 mihomo

装机时可选内核,**其余一切相同**(DNS 决策 / 单入口 / bot / 面板都不变;出口、分流规则、故障组配置两核通用)。上面那条命令装的是默认 sing-box;要 mihomo 就加 `PDG_CORE=mihomo`:

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo PDG_CORE=mihomo bash
```

| 内核 | 特点 | 更新 |
|---|---|---|
| **sing-box 1.12.x**(默认) | 稳定、久经实战 | 内核**钉死 1.12.x**——1.13 移除了本网关依赖的 `sniff_override_destination`,内核无法再升级(bot 代码仍可更新) |
| **mihomo**(clash.meta) | 活跃维护;原生 clash 核,观测面板更顺、UDP/QUIC 更成熟 | 内核**可持续升级**(`sniffer.override-destination` 无版本天花板);`pdg update` / bot 更新按钮会随发布把内核升到最新钉死版 |

> 不确定就用默认 sing-box;想要**内核能一直更新到最新**,就选 mihomo。两者手机端配置(DoT 域名)完全一样。

或克隆后运行(便于先看代码):

```bash
git clone https://github.com/misaka-cpu/privdns-gateway.git
cd privdns-gateway
git fetch --tags
git checkout "$(git tag -l 'v*' --sort=-v:refname | head -1)"
sudo ./install.sh
```

脚本会装好 mosdns、sing-box(1.12)、管理 bot、防火墙和证书,自动识别公网 IP 和内网卡段,再交互填 DoT 域名(**bot token 可留空**,装完随时 `sudo pdg-set-token` 再设并启用)。
域名 A 记录这步留给你自己做(脚本会等你确认指向本机后再签证书)。
详见 [docs/INSTALL.md](docs/INSTALL.md)。

卸载:`sudo ./uninstall.sh`(加 `--purge` 连配置一起删)。

## 装完之后

1. 手机【私密 DNS / DoT】填你的域名(如 `dot.example.com`)。
2. Telegram 给 bot 发 `/start`:
   - **📤 出口管理 → 添加**:直接粘贴节点链接。
     > **bot 能直接粘**:`ss:// / vmess:// / trojan:// / vless://(含 reality)/ hysteria2:// / tuic:// / anytls:// / socks5:// / http://`,以及 Surge 的 `名字 = ss, …` 行。
     > sing-box 还支持 **shadowtls / ssh / hysteria(v1)/ wireguard(endpoint)** 等——这些手写 `/etc/sing-box/config.json`,或开 issue 让 bot 加解析。
   - **📑 分流管理**:把域名、`.list` / `.txt` 等规则集指到出口(默认其余国际走 VPS 直出)。
   - **🔀 故障切换组**:多落地自动选最快 / 坏了自动切。
3. iOS:bot **📱 客户端 → iOS 描述文件**;**不用 bot 的话** `sudo pdg ios` 会直接在终端打出二维码,手机(走内网卡)扫码 → Safari → 装。
   Wi-Fi/蜂窝都按 `:81` 探测自动判定启不启用(带分流代理的普通 Wi-Fi 自动直连、互不干扰);
   bot 生成时还可指定「强制直连」的 Wi-Fi 名单(SSID,治 captive portal 误判)。
4. 换域名:bot **🌐 DoT 自定义域名**,自动签证书并切换。

## 日常管理

```bash
sudo pdg            # 进管理菜单
sudo pdg doctor     # 自检(只读); --json 可脚本化; --deep 加端到端检查(DoT握手/:81/DNS/clash)
sudo pdg status     # 状态
sudo pdg update     # 更新(更新前自动快照, 失败自动回滚; --dry-run 看待更新)
sudo pdg snapshot   # 手动留一份配置快照
sudo pdg rollback   # 回滚到最近快照
sudo pdg token      # 设置 / 更换 bot token
sudo pdg restart    # 重启服务
sudo pdg log [n]    # 看日志
sudo pdg traffic    # 网卡流量(vnstat)
sudo pdg ios        # 不用 bot, 直接出 iOS 描述文件二维码
sudo pdg report     # 脱敏诊断报告(隐藏 token/密码/uuid); --redact-ip 连IP/域名也隐藏; --full 不脱敏
sudo pdg detect-cidr # 抓包重新识别内网卡来源段, 与现配不符可一键写回并重启
sudo pdg uninstall [--purge]   # 卸载(--purge 连配置删)
```

> 健康自检每 10 分钟自动跑,服务挂 / DNS 不应答 / 证书快到期会 Telegram 私信你。

> 分工:`pdg` 管**生命周期**(装/更新/卸载/token/状态);**出口 / 分流 / DNS 上游**等运行时配置都在 Telegram bot 里。

## 📍 iOS 位置改写 (WLOC,可选)

把 iPhone 的**网络定位**改写到设定城市 —— **手机不用装任何 App**,靠系统 DoT + 一次性信任网关 CA,在 Telegram bot 里管多地点、一键切换。原理:网关截 `gs-loc.apple.com` 定位查询、转发给真 Apple 拿回真响应、只把坐标改成设定点(格式 100% 保真,iOS 才接受)。

> ✅ 适用:今日水印相机 / 小红书同城 / 室内打卡这类**走网络定位**的场景。
> ❌ 不适用:连续 GPS 的导航 / 打车 / 定位游戏(那类要电脑侧 GPS 级虚拟定位工具);户外 GPS 信号强时也会盖过它。

### 一次性设置
1. 装机时平台选 **iOS**(`PDG_PLATFORM=ios`)→ 自动装 `pdg-mitm` 服务。
2. bot「📱 客户端 → iOS 描述文件」装到 iPhone(描述文件已内含网关 CA)。
3. **iPhone 手动信任 CA**(缺这步定位不会变):设置 → 通用 → VPN与设备管理 → 装描述文件;再 设置 → 通用 → 关于 → **证书信任设置** → 对「PrivDNS Gateway MITM CA」**开启完全信任**。

### 日常使用
**先在 bot 里设城市**:「🛠 运维 → 🍏 位置改写」→「➕ 添加地点」发「`名称 纬度,经度`」(如 `上海 31.2304,121.4737`)→「📍 地点/切换」点城市 →「✅ 开启」。多地点随时增删、开启中热切换。

**然后手机端**(全程用内网卡):
1. **控制中心关 WiFi** —— 下拉控制中心把 WiFi 图标点灰(⚠️ **不是「设置」里关!** 设置里关会连 Wi-Fi 定位扫描一起关掉,就没东西可改了)。
2. **关闭定位服务** —— 设置 → 隐私与安全性 → 定位服务 → 关。
3. **还原位置与隐私 + 重启**(⚠️ **仅首次 / 后续无法改定位时**)—— 设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私 → 重启手机。
4. **开启定位服务** —— 设置 → 隐私与安全性 → 定位服务 → 开。

开好后打开 Apple 地图 / 今日水印相机看即可。

### 大概等待时间
| 场景 | 操作 | 等待 |
|---|---|---|
| 首次开启 / 从真实位置切到假位置 | 定位服务关开一次 | ~1 分钟 |
| **国内城市之间**切换(如 上海→北京) | 定位服务关开一次 | **几十秒 ~ 1 分钟** |
| **跨国**切换(如 上海→东京) | 飞行模式 ON ~15 秒 → OFF,耐心等 | **数分钟**(iOS 反作弊+缓存,会先"转圈"再稳) |

### 注意
- **iOS 26 缓存极重**:切城市后不做"定位服务关开 / 重启",会一直显示旧位置。
- **别在中↔日之间反复横跳**:会把 iOS 弄进"不信 Wi-Fi 定位、退回真实 GPS"的状态,连累之后的国内切换也变慢;真进了这状态,飞行模式 ON→OFF 几次 + 耐心等可恢复。
- **别收紧精度**:过度精确的假定位会触发 iOS 反作弊、直接退回真实定位(项目已默认不动精度)。
- 原理 / 踩坑详见 [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md)。

## 组成

| 层 | 用什么 | 说明 |
|---|---|---|
| DNS | **mosdns v5** | 国内直连 / 代理域名 A 劫持到本机 + AAAA/HTTPS 置空 / 按来源 IP 分支 / ECS 分治 / 缓存;DoT(853);可选 GFWList 劫持模式 |
| 流量(双核可切) | **sing-box 1.12** 或 **mihomo** | sing-box:`direct` 监听 + `sniff_override_destination`(不用 tproxy);mihomo:nft REDIRECT 入站 + redir 监听 + SNI 嗅探,内核可持续更新。多出口 urltest 故障切换;clash_api 测速/流量。**`pdg switch-core` 无损互切**(出口/分流/证书全不动) |
| 管理 | **Telegram bot**(纯标准库) | 出口 / 分流 / 规则集 / 测速 / 流量 / 备份恢复 / iOS 描述文件 / 自定义域名 / **WLOC 位置改写**,改配置前 `check` + 回滚 |
| 位置改写 | **pdg-mitm**(可选,iOS) | 自签 CA + TLS 终止 + forward+patch 改写 `gs-loc` 网络定位(见上文「iOS 位置改写 WLOC」) |
| 证书 | **certbot standalone** | Let's Encrypt,自动续期(已处理 80 口被内核占的坑) |
| 防火墙 | **nftables** | 对全网只留 SSH;DNS / 数据 / 探测口只放行内网卡来源段;mihomo 用 REDIRECT 入站(同样限内网卡) |

> ⚠️ 用 **sing-box** 内核时**必须 1.12.x** —— 1.13 移除了 `sniff_override_destination` 会失效(install.sh 已固定版本)。想让内核持续更新到最新,装机选 `PDG_CORE=mihomo` 或事后 `pdg switch-core mihomo`(mihomo 无此版本天花板,见上文「选择流量内核」)。

## 文档

- [docs/INSTALL.md](docs/INSTALL.md) — 安装细节 / DNS 配置 / 端口 / 版本注意
- [docs/TROUBLESHOOTING-PLAYBOOK.md](docs/TROUBLESHOOTING-PLAYBOOK.md) — 排障手册(症状 → 查 → 修)
- [docs/production-notes.md](docs/production-notes.md) — 实战记录与踩坑(sing-box 版本坑、QUIC 自环、ECS、安全加固等)
- [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md) — iOS 位置改写 (WLOC) 设计、forward+patch 原理与配方
- [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) — 发版前检查清单(装机 / 升级 / 切核 / WLOC 集成自测)
- [CHANGELOG.md](CHANGELOG.md) — 更新日志

## 免责声明

本项目仅供**学习与合法网络管理**用途。请遵守你所在地的法律法规;使用者自行承担责任。作者不对任何使用后果负责。

## License

[MIT](LICENSE)

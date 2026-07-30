# PrivDNS Gateway

PrivDNS Gateway 是一个基于系统私密 DNS（DoT）的域名分流网关。手机端只需配置 DoT，网关根据域名决定直连，或把流量交给指定出口。手机不需要安装 VPN、Clash 或 sing-box 客户端。

> 第一次部署可参考图文教程：[docs/QUICKSTART.md](docs/QUICKSTART.md)。

## 1. 项目简介

手机把系统 DNS 指向网关的 DoT 域名后，域名解析统一由网关处理：

- 国内域名返回真实 IP，手机直连。
- 需要走代理的域名，网关把 A 记录改写成网关自己的 IP，流量因此回到网关；网关嗅探 SNI/Host，再按域名把连接交给对应出口，或从本机直出。

手机上只有一条私密 DNS 设置，没有客户端，也没有 tun。出口、分流规则、故障组、DoT 域名等都在 Telegram Bot 或 `pdg` 命令里管理。

## 2. 工作原理

```
手机（Android 私密 DNS / iOS 描述文件，仅 DoT）
   │  DoT :853
   ▼
网关 VPS
   ├─ mosdns：国内域名返回真实 IP（直连）
   │           代理域名把 A 记录改写为网关 IP，AAAA / HTTPS 置空
   │
   ▼  入站 :80 / :443 等，按 SNI / Host 嗅探
流量内核（mihomo / clash.meta）
   └─ 按域名分流：指定域名 → 落地 A / 落地 B；其余国际 → 本机直出
```

- DNS 层用 mosdns：按来源 IP 判断是否属于内网卡，再决定国内直连、代理域名劫持到网关、或抑制 AAAA / HTTPS。
- 流量层用 mihomo（clash.meta）：嗅探连接的域名后按规则分流。
- mosdns 只对内网卡来源段生效，其他来源的 DNS 查询不受影响。

## 3. 使用前提

本项目依赖一个特定拓扑，不是通用代理工具：

- 一台墙外 VPS，同时作为网关和 DNS。
- 一张运营商内网卡（定向内网 SIM）。手机的移动流量经运营商私网到达 VPS，来源 IP 是固定私有段（例如 `172.x`）。网关用这个私有源段区分「需要劫持的查询」和其他来源。没有这种内网卡时，DNS 劫持会影响到所有查询来源，不适用本项目。
- 一个可以自行修改解析记录的域名，用于 DoT 并签发 Let's Encrypt 证书。
- 一个 Telegram Bot，用于管理出口和分流。
- 一个或多个落地节点用于出国际流量（可选；默认其余国际从 VPS 直出）。

## 4. 安装

Debian 12+ / Ubuntu 22+，需要 root。

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

入口脚本只负责自举，实际安装会切到最新的 `v*` 发布 tag，不安装 main 上未发布的中间提交。

安装会部署 mosdns、mihomo 内核、管理 Bot、防火墙和证书，自动识别公网 IP 和内网卡来源段，再交互填写 DoT 域名（Bot token 可以留空，装完后随时用 `sudo pdg-set-token` 设置并启用）。域名的 A 记录需要你自己指向本机，脚本会等你确认后再签发证书。

也可以克隆后运行（便于先查看代码）：

```bash
git clone https://github.com/misaka-cpu/privdns-gateway.git
cd privdns-gateway
git fetch --tags
git checkout "$(git tag -l 'v*' --sort=-v:refname | head -1)"
sudo ./install.sh
```

更多安装细节见 [docs/INSTALL.md](docs/INSTALL.md)。卸载：`sudo ./uninstall.sh`（加 `--purge` 连配置一起删除）。

## 5. 手机平台选择

一台网关对应一个手机号，平台是每台机器的固定属性，装机时确定（`PDG_PLATFORM=ios` 或 `android`；不指定则安装时询问）。平台决定客户端接入方式和是否提供 iOS 专属功能：

- Android：手机在系统「私密 DNS」里直接填 DoT 域名。不安装 iOS 描述文件、pdg-probe81、MITM/WLOC 相关组件。
- iOS：通过 iOS 描述文件接入，另外安装 pdg-probe81（`:81` 探测）和 MITM/WLOC 组件。

## 6. 流量内核（mihomo）

流量层统一使用 mihomo（clash.meta）：nft REDIRECT 入站 + redir 监听 + SNI 嗅探；提供 clash_api，可开观测面板。内核版本由 `pdg update` 随 PrivDNS Gateway 发布版指定并校验后安装。

> 早期版本曾支持 sing-box / mihomo 二选一。sing-box 1.13 移除了本网关依赖的 `sniff_override_destination`、被钉死在 1.12.x 死胡同，因此 **v1.6.0 起已彻底移除 sing-box 运行时**，mihomo 成为唯一内核。旧的 sing-box 机器执行 `sudo pdg update` 时会自动迁移到 mihomo（出口、分流、证书、DoT 全部保留；若有 mihomo 无法转换的出口，更新会中止并回滚，提示先在 Bot 里处理该出口）。

## 7. 手机接入

- Android：系统「设置 → 网络 → 私密 DNS」选「指定的 DNS 服务提供商主机名」，填 DoT 域名（例如 `dot.example.com`）。
- iOS：在 Bot「📱 客户端 → iOS 描述文件」生成并安装描述文件；不使用 Bot 时，`sudo pdg ios`（仅 iOS 平台可用）会在终端打出二维码，手机走内网卡扫码后在 Safari 里安装。Wi-Fi 与蜂窝是否启用私密 DNS 由 `:81` 探测自动判定（能连到网关才启用），生成时还可指定强制直连的 Wi-Fi 名单（SSID）。

## 8. Telegram Bot 使用

给 Bot 发 `/start` 进入菜单，常用功能：

- 📤 出口管理：添加、删除、改名、排序出口，设置默认出口，新建/编辑故障切换组。
  - 可直接粘贴的链接：`ss://`、`vmess://`、`vless://`（含 reality）、`trojan://`、`hysteria2://`、`tuic://`、`anytls://`、`socks5://`、`http://`，以及 Surge 的 `名字 = ss, …` 行。
  - shadowtls、ssh、hysteria（v1）、wireguard（endpoint）等出站不在直接支持之列：它们需要手写数据模型 `/etc/sing-box/config.json`，且 mihomo 未必能转换（渲染失败会被拒绝，不会静默丢弃）。
- 📑 分流管理：把域名、`.list` / `.txt` 等规则集指到出口；默认其余国际走 VPS 直出。
- 🔀 故障切换组：按探测延迟选择出口，并在出口不可用时切换。
- 📱 客户端：Android 显示私密 DNS 主机名；iOS 显示 iOS 描述文件入口。两个平台都提供「🌐 DoT 自定义域名」和「✈️ Telegram 出口」。
- 🛠 运维：重启服务、更新规则库、备份/恢复、DNS 上游、TFO、观测面板；iOS 平台另有「🍏 位置改写（WLOC）」。

Telegram 出口（Bot 内置 SOCKS5，端口 8445）用于给手机上的 Telegram 单独指定出口，在客户端菜单里配置。

## 9. 日常管理命令

```bash
sudo pdg            # 进管理菜单
sudo pdg status     # 状态
sudo pdg doctor     # 自检（只读）；--json 可脚本化；--deep 加端到端检查
sudo pdg update     # 更新（更新前自动快照，失败自动回滚；--dry-run 查看待更新）
sudo pdg snapshot   # 手动留一份配置快照
sudo pdg rollback   # 回滚到最近快照
sudo pdg token      # 设置 / 更换 Bot token
sudo pdg restart    # 重启服务
sudo pdg log [n]    # 查看日志
sudo pdg traffic    # 网卡流量（vnstat）
sudo pdg ios        # 仅 iOS：在终端打出 iOS 描述文件二维码
sudo pdg report     # 脱敏诊断报告；--redact-ip 连 IP/域名一起隐藏；--full 不脱敏
sudo pdg detect-cidr           # 重新识别内网卡来源段，与现配不符可写回并重启
sudo pdg hijack-mode <all|gfw>          # 切换劫持模式
sudo pdg uninstall [--purge]            # 卸载（--purge 连配置删）
```

`pdg update` 只跟随项目的 `v*` 发布 tag，不安装 main 上未发布的中间提交；更新会同时安装该发布版指定并校验过的内核版本。健康自检每 10 分钟自动运行，服务异常、DNS 不应答、证书临近到期会通过 Telegram 通知。生命周期（安装、更新、卸载、token、状态）用 `pdg` 命令管理；出口、分流、DNS 上游等运行时配置在 Telegram Bot 里。

## 10. iOS 位置改写（WLOC，可选）

WLOC 只修改 Apple 网络定位响应中的坐标，不修改 GPS 数据。它把 `gs-loc.apple.com` 的定位查询转发给 Apple，取回真实响应后只替换其中的坐标。适用于依赖网络定位的场景；连续 GPS 定位（导航、打车等）不适用，户外 GPS 信号较强时也会覆盖它。WLOC 仅 iOS 平台提供。

首次使用顺序：

1. 在 Bot「🛠 运维 → 🍏 位置改写」里「➕ 添加地点」（发送「`名称 纬度,经度`」，例如 `上海 31.2304,121.4737`），然后「✅ 开启」。
2. 返回「📱 客户端 → iOS 描述文件」，重新生成并安装 iOS 描述文件。
3. 在「设置 → 通用 → 关于本机 → 证书信任设置」中，信任 PrivDNS Gateway MITM CA。

**切换地点的推荐顺序（全程用内网卡）：**

1. 控制中心把 Wi-Fi 点灰（不是在设置里关 Wi-Fi）
2. 在 Bot「📍 地点 / 切换」里点目标地点
3. 等 Bot 显示「WLOC 已热加载」
4. 设置 → 隐私与安全性 → 定位服务：关闭，等 2 秒后重新开启
5. 打开目标 App
6. iOS 26 如果一直没有发起新的 WLOC 请求，可能仍需重启手机

切换地点只原子更新 `mitm.json`；`pdg-mitm` 在下一次 WLOC 请求开始时读取当前配置，因此无需重启服务，进程不重启、DNS 也不会断。网关只能保证下一次请求使用新坐标，不能主动清除 iOS locationd 缓存。开关 WLOC（接管域名发生变化）才走完整事务。

Bot 在切换后会等最多 30 秒，看手机是否真的发来了新的 WLOC 请求：收到了就回报「已收到 iPhone 的新定位请求」，没收到就如实提示还没等到，并给出排查项。

**边界（网关做不到的部分）：** 网关只能保证**下一次** Apple 网络定位请求使用新坐标，无法让 iOS 清除 locationd 缓存，也无法强制手机立刻发起新请求。「网关已改写响应」不等于「手机显示的位置已经变了」——地图仍显示旧位置可能是 iOS 缓存或户外 GPS 覆盖。

长期无法定位时：设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私 → 重启手机

多个地点可以随时增删，开启状态下可切换。原理与配置见 [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md)。

## 11. 救援平面（网关自己出问题时的入口）

代理挂了、DNS 不应答、Bot 起不来的时候，管理入口往往也一起没了。救援平面是为这种时刻准备的一个独立 HTTPS 页面：不依赖 mihomo / mosdns / Bot / tailscaled 中的任何一个，只监听内网地址，用来看状态、看事务、必要时恢复配置。

```bash
sudo pdg rescue status        # 是否启用、监听在哪、来源段、nft 规则、证书指纹
sudo pdg rescue fingerprint   # 只打印证书的 SHA-256 指纹
sudo pdg rescue enable        # 启用（默认关闭）
sudo pdg rescue bind <IPv4>   # 指定监听地址
sudo pdg rescue rotate token  # 换 token（已登录会话立即失效，证书指纹不变）
sudo pdg rescue rotate cert   # 重签证书（指纹一定改变，需要重新核对）
```

### 先核对指纹，再输入 token

页面用的是**自签证书**，浏览器一定会警告。自签证书本身不证明你连到的是自己那台机器 —— 它只保证这条连接被加密。能把"对面是我的网关"和"对面是别人"区分开的，只有**证书指纹**，而且指纹必须从另一条路拿到：

```bash
ssh <你的网关> sudo pdg rescue fingerprint
```

安装时把这串指纹存下来也可以。**不要**用页面上显示的那串指纹去核对页面自己 —— 中间人能同时伪造页面和页面上的指纹，自己给自己作证没有意义。

- 浏览器里看不到完整的 SHA-256 指纹时，**不要**先输 token。换一个能看到证书详情的浏览器，或者改用 SSH。
- `pdg rescue rotate cert` 之后指纹必然变化，浏览器会重新警告；那是预期的，但必须重新从 SSH 取一次新指纹再核对。
- `pdg rescue rotate token` 不改变证书指纹，只让已登录的会话立即失效。
- 监听地址是公网可路由地址时，端口的访问控制靠两层：nft 的来源网段限制，加上服务内按内核给出的对端地址做的校验（不看 `X-Forwarded-For`）。这两层限制的是"谁能连上来"，不替代指纹核对——指纹解决的是"这台机器是不是你的"。
- token 和指纹不要放在同一条聊天记录里，也不建议截图转发。

手机上的具体步骤见 [docs/rescue-plane-access.md](docs/rescue-plane-access.md)。

## 12. 项目组成

| 层 | 组件 | 说明 |
|---|---|---|
| DNS | mosdns v5 | 按来源 IP 分支；判断顺序为 WLOC/MITM 接管 → **你点名指到出口的域名** → 国内直连 → 自动海外判断；代理域名 A 记录劫持到本机、AAAA / HTTPS 置空；ECS 处理；缓存；DoT（853）；可选 GFWList 劫持模式 |
| 流量 | mihomo（clash.meta） | nft REDIRECT 入站 + redir 监听 + SNI 嗅探。多出口故障切换；提供 clash_api（观测面板）。改配置前先校验，失败回滚 |
| 管理 | Telegram Bot（Python 标准库） | 出口、分流、规则集、测速、流量、备份恢复、iOS 描述文件、自定义域名、WLOC；改配置前先校验，失败回滚 |
| 位置改写 | pdg-mitm（可选，iOS） | 自签 CA + 终止 TLS + 转发并替换 `gs-loc` 响应坐标 |
| 证书 | certbot standalone | Let's Encrypt，自动续期 |
| 防火墙 | nftables | 对全网只放行 SSH；DNS、数据、探测端口只放行内网卡来源段；mihomo 用 REDIRECT 入站，同样限内网卡来源 |

内核版本由 `pdg update` 随 PrivDNS Gateway 发布版指定并逐字节校验（SHA256）后安装。

**你点名的规则优先于自动判断。** 在 Bot 里把某个域名指到出口后，mosdns 会在「这个域名算不算
国内」之前就先按你的规则劫持它。上游的 geosite 分类是策展结果，会把整个二级域（含它下面本
该走代理的子域）归进国内；判断排在后面时，DNS 先返回了真实地址，流量根本不进 mihomo，内核
里那条出口规则永远匹配不到 —— 规则在、`pdg doctor` 也绿，就是不生效。这一层只决定「进不进
mihomo」，**具体走哪个出口仍由数据模型里的真实规则决定**，与 iOS 的 MITM 接管（`pdg-mitm`）
是两条独立的链路，普通代理域名不会被送去终止 TLS。

管到这件事的两个文件：

- `/etc/mosdns/rules/custom_hijack.txt` —— Bot 里「域名 → 出口」写入，改判直连或删规则时移出。
- `/etc/mosdns/rules/ruleset_hijack.txt` —— **由启用中的规则集自动生成**，加/删/刷新规则集时
  在同一笔事务里重算。文本、`.list`、`.yaml` 类规则集直接取域名；mihomo 原生的 `.mrs` 是二进制，
  用内核自己的 `convert-ruleset` 反向导出域名清单，所以**同样能自动派生**。`ipcidr` 类型的规则集
  本来就没有域名，跳过。只有真读不出来的（文件损坏、类型认不出）才会被点名。
  手写过内容的文件（表头不是自动生成的那行）更新时不会被覆盖。

  这一层只在 `gfw` 模式下看得出差别：`all` 模式"不是国内就劫持"本来就把规则集的域名兜住了。

**配置写入统一走事务。** 出口、分流、规则集、DNS 上游、防火墙、TFO、证书、WLOC 开关、备份恢复
等所有会改动生产配置的操作，都在一笔配置事务里完成：候选先校验，再原子落盘，然后按目标状态
拉起/停掉服务并观察健康门，任一步失败整体回滚；进程被杀也能用 `sudo pdg tx recover <id>` 收尾，
`sudo pdg doctor` 会点名未完成的事务。两处**受控例外**：

- **WLOC 切地点 / 改坐标**：只改一个文件（`mitm.json`）、一次原子替换、不动任何服务
  （pdg-mitm 在下一次 WLOC 请求开始时读当前配置），没有多组件半成功的可能，因此走快路径以保证
  切换在 1 秒内完成；它仍在同一把全局配置锁内，并写一条脱敏审计（只记操作与 generation 变化，
  不记地点名与经纬度）。
- **观测面板前端资源（zashboard）**：固定版本 + SHA256 校验 + 暂存目录 + 原子替换，属于静态
  缓存资源，不是 DNS/分流生产配置，因此不纳入配置事务。

## 13. 文档

- [docs/QUICKSTART.md](docs/QUICKSTART.md) — 新手图文教程
- [docs/INSTALL.md](docs/INSTALL.md) — 安装细节 / DNS 配置 / 端口 / 版本说明
- [docs/TROUBLESHOOTING-PLAYBOOK.md](docs/TROUBLESHOOTING-PLAYBOOK.md) — 排障手册（症状 → 排查 → 修复）
- [docs/production-notes.md](docs/production-notes.md) — 实战记录与已知问题
- [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md) — iOS 位置改写（WLOC）设计与原理
- [docs/rescue-plane-access.md](docs/rescue-plane-access.md) — 救援平面的手机端访问与指纹核对
- [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) — 发版前检查清单
- [CHANGELOG.md](CHANGELOG.md) — 更新日志

## 14. 免责声明与 License

本项目仅供学习与合法网络管理用途。请遵守你所在地的法律法规，使用者自行承担责任，作者不对使用后果负责。

License：[MIT](LICENSE)

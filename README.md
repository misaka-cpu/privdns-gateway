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

- DNS 层用 mosdns：按来源 IP 判断是否属于内网卡，再决定国内直连、把代理域名改写到网关、或抑制 AAAA / HTTPS。
- 流量层用 mihomo（clash.meta）：嗅探连接的域名后按规则分流。
- mosdns 只对内网卡来源段生效，其他来源的 DNS 查询不受影响。

## 3. 使用前提

本项目依赖一个特定拓扑，不是通用代理工具：

- 一台境外 VPS，同时作为网关和 DNS。
- 一张运营商内网卡（定向内网 SIM）。手机的移动流量经运营商私网到达 VPS，来源 IP 是固定私有段（例如 `172.x`）。网关用这个私有源段区分「需要接管的查询」和其他来源。没有这种内网卡时，DNS 接管会影响到所有查询来源，不适用本项目。
- 一个可以自行修改解析记录的域名，用于 DoT 并签发 Let's Encrypt 证书。
- 一个 Telegram Bot，用于管理出口和分流。
- 一个或多个出口节点（下文简称落地节点）用于出国际流量（可选；默认其余国际从 VPS 直出）。

## 4. 安装

Debian 12+ / Ubuntu 22+，需要 root。

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

安装命令会自动切换到最新发布版本（`v*` tag），不安装 main 上未发布的中间提交。

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

> 早期版本曾支持 sing-box / mihomo 二选一。sing-box 1.13 移除了本网关依赖的 `sniff_override_destination`，导致它无法继续升级到 1.13 及后续版本，因此 **v1.6.0 起已彻底移除 sing-box 运行时**，mihomo 成为唯一内核。旧的 sing-box 机器执行 `sudo pdg update` 时会自动迁移到 mihomo（出口、分流、证书、DoT 全部保留；若有 mihomo 无法转换的出口，更新会中止并回滚，提示先在 Bot 里处理该出口）。

## 7. 手机接入

- Android：系统「设置 → 网络 → 私密 DNS」选「指定的 DNS 服务提供商主机名」，填 DoT 域名（例如 `dot.example.com`）。
- iOS：在 Bot「📱 客户端 → iOS 描述文件」生成并安装描述文件；不使用 Bot 时，`sudo pdg ios`（仅 iOS 平台可用）会在终端打出二维码，手机走内网卡扫码后在 Safari 里安装。Wi-Fi 与蜂窝是否启用私密 DNS 由 `:81` 探测自动判定（能连到网关才启用），生成时还可指定强制直连的 Wi-Fi 名单（SSID）。

  描述文件由网关**统一管理版本**：网关使用固定的身份标识，后续每次更新都是同一份描述文件的新版本，iPhone 上不会越堆越多。界面会告诉你当前是第几版、上次什么时候发送的、以及相对当前网关配置是「无需更新 / 建议更新 / 必须更新」，也能看当前版与上一版的字段级差异。

  首次启用时会问一句「以前在这台网关上装过描述文件吗」——**旧版本每次生成都用随机身份标识**，iOS 会把新的当成另一个描述文件并存，所以答"装过"的话请先在 iPhone 上删掉旧的那份再安装。

  服务器不是 MDM，**无法确认手机上此刻装的是哪一版**，界面上所有信息都只反映网关这边的生成/发送记录。细节见 [docs/ios-profile-lifecycle.md](docs/ios-profile-lifecycle.md)。

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
sudo pdg ios        # 仅 iOS：生成/更新描述文件并在终端打出二维码
sudo pdg ios status # 仅 iOS：当前第几版 / 上次发送 / 是否需要重新安装
sudo pdg ios diff   # 仅 iOS：当前版与上一版的字段级差异
sudo pdg ios previous  # 仅 iOS：取回上一版并打出二维码（只是把旧文件再给你一次，当前版本不回退）
sudo pdg report     # 脱敏诊断报告；--redact-ip 连 IP/域名一起隐藏；--full 不脱敏
sudo pdg detect-cidr           # 重新识别内网卡来源段，与现配不符可写回并重启
sudo pdg hijack-mode <all|gfw>          # 切换域名接管模式
sudo pdg link status                    # 链路诊断：服务器侧准备状态（只读，不改任何配置）
sudo pdg link session <start|status|stop>   # 手机协助诊断会话（一次性链接，5 分钟有效）
sudo pdg ssh-source <status|tailnet|any|confirm>   # SSH 来源限制（收紧为只允许经 Tailscale 登录）
sudo pdg lan <status|list|add|rm|cert|enable|disable|purge>   # 内网面板（见第 13 节）
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
3. 等 Bot 显示「网关目标地点已切换，网关服务无需重启」
4. 设置 → 隐私与安全性 → 定位服务：关闭，等 2 秒后重新开启
5. 打开目标 App
6. iOS 26 如果一直没有发起新的 WLOC 请求，可能仍需重启手机

切换地点只原子更新 `mitm.json`；`pdg-mitm` 在下一次 WLOC 请求开始时读取当前配置，因此无需重启服务，进程不重启、DNS 也不会断。网关只能保证下一次请求使用新坐标，不能主动清除 iOS locationd 缓存。开关 WLOC（接管域名发生变化）才走完整事务。

Bot 在切换后会等最多 30 秒，看手机是否真的发来了新的 WLOC 请求：收到了就回报「已收到 iPhone 的新定位请求」，没收到就如实提示还没等到，并给出排查项。

**边界（网关做不到的部分）：** 网关只能保证**下一次** Apple 网络定位请求使用新坐标，无法让 iOS 清除 locationd 缓存，也无法强制手机立刻发起新请求。「网关已改写响应」不等于「手机显示的位置已经变了」——地图仍显示旧位置可能是 iOS 缓存或户外 GPS 覆盖。

长期无法定位时：设置 → 通用 → 传输或还原 iPhone → 还原 → 还原位置与隐私 → 重启手机

多个地点可以随时增删，开启状态下可切换。原理与配置见 [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md)。

### 链路诊断能观察到什么、观察不到什么

`sudo pdg link status` 分两段输出：**服务器准备状态**（DoT 监听、证书、防火墙、核心服务等，
全部在本机可验证）和**手机实时证据**。两段的可信度不一样，不要混着读。

手机那一段有两种发起方式，用的是同一套会话：

- **Telegram Bot**（推荐，手机上就能操作）：「📱 客户端 → 📡 手机链路测试 → ▶️ 开始测试」，
  Bot 会给一个「🌐 打开测试页」按钮，点它即可；结果出来后 Bot 会自动更新那条消息。
  Android 与 iOS 都有这个入口。
- **服务器上**：`sudo pdg link session start`，把它给出的链接在手机上打开。

**测试链接是一次性的，5 分钟内有效。** 开始之前请关闭普通 Wi-Fi、只保留内网卡，否则请求会从
Wi-Fi 出去，来源就不在内网卡段里了。测试期间可以随时点「🔄 查看结果」；Bot 重启过也不影响，
只要会话还没过期，点「查看结果」仍能读到结论。不想继续就点「✖️ 取消测试」，链接立即失效。

**能观察到三件事，每一件只证明它自己**：

| 证据 | 它证明的 | 它**不**证明的 |
|---|---|---|
| HTTP 探测到达 | 网关收到了本次会话的那个 HTTP 请求 | 手机的其它流量走没走这条路 |
| 来源网段 | 那个请求的来源落在配置的内网卡来源段里 | 请求一定来自你本人的手机——任何拿到链接的人都能打开它 |
| DoT 查询到达 | 时间窗内有**一次专门的 DoT 查询**进了网关的 DoT 端口 | 手机的其它 DNS 查询也走了这条路 |

第三条由 `pdg-dotwitness` 提供。它是本项目自己的观测点，只记随机标识的摘要，不碰查询内容，
也**没有**打开 mosdns 的 metrics 接口——那条路因为同一个监听端口会连带暴露 DNS 缓存导出
（内含明文查询域名）与缓存投喂端点，安全审查没让它通过，至今仍然关着
（[docs/ROADMAP.md](docs/ROADMAP.md)）。

三条加起来仍然**不能**断言 SIM/APN 正常、移动网络正常或整体链路正常——它们证明的是几次
**到达**，不是这条路持续可用。没有证据同样不等于手机故障，只说明这次没有观察到；观测点
本身不可信时（比如中途重启过）会明说「说不出结论」，而不是报「没看到」。诊断会话只保存
请求来源的 `/16` 网段，不保存完整 IP。

输出结尾那段说明是按**本次真拿到的证据**拼的：拿到 DoT 证据就说到 DoT，没拿到就直说没拿到。

服务器侧还没准备好（比如 `:81` 探测端点没起来）时，不会创建会话、也不会发测试链接——那时候
拿着一条注定失败的链接去手机上折腾，只会把服务器的问题误诊成手机的问题。

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

## 12. Tailscale（可选，但装了就有硬约束）

这个项目不会帮你装 Tailscale，也不替你管它的账号、密钥和后台策略——那些都在你自己手里。
但它**会**盯着 Tailscale 和这套系统碰头的那几个点：入口隔离、`nodivert`、`detect-cidr` 的
样本排除、卸载残留，`pdg doctor` 每次都查。装不装、怎么装由你决定，装了之后这几条就不是可选的了。

这一节只讲一件事：Tailscale 和这套系统会在两个地方碰头，而且碰得不轻。事先不知道的话，出的故障从表面上看跟它一点关系都没有。

另外，如果你想用「内网面板」（第 13 节），那 Tailscale 就不是可选的了 —— 整条链路都要经它。

### 为什么会打架

Tailscale 给节点分的地址来自 `100.64.0.0/10`。巧的是，运营商的 SIM/APN 内网卡也合法使用同一个段（RFC 6598），而这套系统恰恰是靠「来源在内网卡段」来决定要不要接管一个客户端的流量的。

也就是说，光看源地址，分不开「这是我的手机」和「这是我的 tailnet 节点」。

所以这里按**入口接口**排除，不按地址段排除：

```
table inet pdg {
  chain prerouting {
    iifname "tailscale0" return     # 第一条 —— tailnet 流量根本走不到 REDIRECT
    ...
  }
  chain input {
    ...
    tcp dport 22 accept             # SSH 排在前面, 所以你仍然能从 tailnet 登进来
    ip protocol icmp accept
    iifname "tailscale0" return     # 从这里起, tailnet 拿不到内网卡客户端的待遇
    ip saddr <你的内网段> tcp dport { 53, 81, 853, 7893, 8445 } accept
  }
}
```

为什么不图省事按段拒绝？因为真实的运营商 CGNAT 用户本来就在 `100.64.x.x` 里 —— 看见这个段就拒绝的话，会把他们一起挡掉。

最后的效果是：从 tailnet 能 SSH、能 ping，已经建好的连接也不受影响；但拿不到 DNS 和代理那几个内网卡专用端口，流量也不会被送进透明代理。这是有意的，管理通道和数据面本来就该分开。

### 先看清现在是什么样

`tailscale up` 是**整套覆盖**，不是增量——漏写一个参数就等于把它改回默认值。所以动手之前先只读地
看一眼当前状态：

```bash
tailscale debug prefs
```

要留意的几行：`NetfilterMode`（`1` = nodivert，见下）、`RouteAll`（接不接受别人宣告的路由）、
`AdvertiseRoutes`、`ExitNodeIP`、`RunSSH`、`CorpDNS`（`--accept-dns`）。

### 起法：管理用途 / 内网面板用途

只把 Tailscale 当**管理通道**（SSH 进来、Bot 用不着它）：

```bash
sudo tailscale up \
  --netfilter-mode=nodivert \
  --accept-dns=false \
  --accept-routes=false
```

要用**内网面板**（第 13 节）的话，网关必须能走到家里那台子网路由器宣告的段，所以只改一个参数：

```bash
sudo tailscale up \
  --netfilter-mode=nodivert \
  --accept-dns=false \
  --accept-routes=true          # 只有这一项跟上面不同
```

`--accept-dns=false` 是必须的：网关自己的 DNS 由 mosdns 管，让 Tailscale 去改 `/etc/resolv.conf`
会把本机解析绕开 mosdns，症状是「手机好好的、网关自己解析不对」。

**默认不要开**的几样，本项目一个都不需要，开了只是白白扩大暴露面：出口节点
（`--advertise-exit-node` / `--exit-node`）、路由宣告（`--advertise-routes`，网关是**用**路由的
一侧，不是宣告的一侧）、Tailscale SSH（`--ssh`，它会绕过 sshd 和你自己的 SSH 策略）、
以及 Serve / Funnel（Funnel 会把服务开到公网上，跟这套系统的整个方向相反）。

### nodivert 模式：这条没得商量

```bash
sudo tailscale up --netfilter-mode=nodivert   # 其余参数按上面两种起法补全
```

默认模式（`--netfilter-mode=on`）下，Tailscale 会往 `INPUT` 链里插一条跳到 `ts-input` 的规则。那条链和本项目的 `inet pdg` 挂在同一个 hook 上，而 nftables 里同一个 hook 上的每条 base chain 都会执行 —— 于是 `pdg doctor` 会判「防火墙链冲突」，而升级会因为这条自检整次回滚。

`nodivert` 只是不建那条跳转，Tailscale 的其余功能照常。至于「谁挡下了伪造源地址的包」，本项目
实测到的事实只有一条：从非 tailscale0 接口伪造 `100.64.x.x` 源地址的包**进不来**，而 `ts-input`
的计数器纹丝不动——挡下它的是 `inet pdg` 的入口隔离加默认丢弃。`ts-input` 在 `nodivert` 下不被
执行，所以本项目**没有**验证过它自己的反欺骗保护还生效；需要那一层的话请以 Tailscale 官方文档
为准，别拿这里的实测结果当依据。

这个设置会持久化，重启 tailscaled 或整机都不会丢。而且 Tailscale 自己会拦住误改：不带参数直接跑 `tailscale up`，它会报错要求你把所有非默认参数写全。

### Access controls：新 tailnet 默认是全通的

这一条最容易被跳过，因为**不配它一切都能用**。新建的 tailnet 默认策略是 allow-all——你的每个
节点都能访问其它每个节点的每个端口。网关一旦接受了家里的子网路由（上面那个
`--accept-routes=true`），这句话就变成：**一台被拿下的网关能摸到你家整个内网**。

策略写在 tailnet 后台的 Access controls 里。新写请用 **Grants**（`grants:`）；老的 `acls:` 仍然
能用，但那是 legacy 写法，新功能只往 Grants 上加。

```jsonc
{
  // ① 先声明这个 tag 归谁所有 —— 没有这一段, tag 不能用
  "tagOwners": {
    "tag:pdg-gateway": ["autogroup:owner"],
  },

  "grants": [
    // ② 你自己 → 网关: 只给 SSH
    {
      "src": ["autogroup:member"],
      "dst": ["tag:pdg-gateway"],
      "ip":  ["tcp:22"],
    },
    // ③ 网关 → 家里内网: **只**给面板表里那几个 IP:端口, 一个不多
    {
      "src": ["tag:pdg-gateway"],
      "dst": ["192.168.100.90/32", "192.168.100.141/32"],
      "ip":  ["tcp:443", "tcp:8080"],
    },
  ],
}
```

老写法长这样（对照用，新配置别再这么写）：

```jsonc
{
  "acls": [
    { "action": "accept", "src": ["tag:pdg-gateway"],
      "dst": ["192.168.100.90:443", "192.168.100.141:8080"] },
  ],
}
```

**tag 不会自己长到节点上**，两步缺一不可：先在 `tagOwners` 里声明它（否则后台直接报错），
再让节点带上它——

```bash
sudo tailscale up --advertise-tags=tag:pdg-gateway   # 其余参数照上面补全
```

打标签会**换掉节点的身份**，所以这一步需要重新认证一次；在后台机器列表里给机器改 tag 也可以，
效果一样。带 tag 的节点还有个副作用是好事：它的密钥**不会过期**（见下）。

改完之后，`pdg doctor --deep` 会从网关往一个**不在面板表里**的地址试着连一下。这个探测只能往
一个方向读：**连得上、或者收到 RST，就说明还没收紧**。反过来不成立——探不到既可能是策略把包
丢了，也可能是那个地址上本来就没有设备，两种情形观测一模一样。所以它**不能**替你证明
Access controls 已经配对了，那件事只能你自己去后台核对。

### 几条运维边界，事先知道能省很多事

- **密钥会过期。** 节点密钥默认 180 天到期，到期后那台机器**掉出 tailnet**。对这套系统来说
  后果是连锁的：内网面板全部打不开，而如果 SSH 已经收紧成只走 tailnet（`pdg ssh-source
  tailnet`），你连进都进不去，只剩服务商的网页控制台。要么在后台给网关关掉 key expiry，要么
  给它打上 tag（带 tag 的节点密钥不过期）。
- **Android 的「私密 DNS」跟 Tailscale 没有关系。** 私密 DNS 是系统 DNS 设置，走的是普通网络；
  Tailscale 是 VPN 隧道。手机上开不开 Tailscale App，都不影响私密 DNS 指向这台网关——反过来
  也一样，Tailscale 连着不代表 DNS 就走了这条路。
- **「手机零 App」只覆盖网关反代出来的 HTTP/HTTPS 面板。** 也就是第 13 节里你手工加进面板表的
  那几个。SSH、SMB、RDP、以及那些直接连内网 IP 的原生 App，都不在其中——那些仍然要手机上装
  Tailscale。

### 装了之后 `pdg detect-cidr` 会变谨慎

这条命令靠抓包猜你的内网卡段。装了 Tailscale 之后：

tailnet 的样本会按入口接口被排除，不会被误选成内网段。但要是这台机器的 `tcpdump` 老到 `-i any` 不打印接口名，「入口接口」这个事实就拿不到了 —— 那时它会直接拒绝猜，让你手输。

宁可麻烦你也不赌，是因为猜错的代价不小：nft 的 REDIRECT 会被改挂到 tailnet 上，管理流量被送进透明代理，而这种故障从配置上完全看不出来。

### 卸载之后有两样要手工收

Tailscale 卸载时不还原自己改过的东西。`pdg doctor` 会提醒你，但不会替你动手：

```bash
sysctl -w net.ipv4.conf.all.src_valid_mark=0   # 它改成 1 且不落 /etc/sysctl.d, 重启才恢复
```

第一条留着不至于立刻出事，但它会制造「重启前后行为不一致」这种最难查的现象 —— 你今天验过没问题，下次重启之后行为就变了。

还有一样是 `/usr/bin/tailscale` 本身：`apt purge` 之后它可能仍然留着，`command -v tailscale`
照样能找到它，按「命令在不在」判断的脚本就会被骗。**删之前先确认它已经没人认领**：

```bash
dpkg -S /usr/bin/tailscale        # 报 no path found = 孤儿, 这时才可以删
sudo rm -f /usr/bin/tailscale
```

要是 `dpkg -S` 报出了包名，那说明 Tailscale **还装着**（可能只是 `tailscale down` 了，或者
tailscaled 停着），这个文件归包管，删了会把包弄成破损状态，而且要到下次 `apt` 操作才看得出来。
`pdg doctor` 用的是同一条判据：先看包在不在，包还在就整项不适用，不会建议你删。

### 怎么确认没配错

```bash
sudo pdg doctor          # 看「Tailscale 入口隔离」与「Tailscale 卸载残留」两项
```

手机上点 Bot 的 🩺 自检也一样，跑的是同一套检查库。

## 13. 内网面板（可选，手机零 App 打开家里的 Web 面板）

人在外面，想开一下家里路由器的后台、NAS、UPS、交换机这些 Web 面板 —— 而且不想在手机上装或者开任何 App。

链路是这样的：手机 →（SIM）→ 网关 → tailnet → 家里的设备。手机侧一个字都不用改，它只是在访问一个普通的 HTTPS 网站。

需要家里有一台常开的机器跑 Tailscale 子网路由（OpenWrt、群晖、树莓派都行）。设计细节和风险取舍见 [`docs/design-lan-panels.md`](docs/design-lan-panels.md)。

### 三道门

这三条不是加固，是这个功能能不能安全存在的前提，所以都写进了代码，而不是写在文档里等人去读。

**一、拒绝重叠的子网路由。**家里通告过来的网段一旦和网关正在用的段相交，手机的分流就会错乱 —— 而 nft、mosdns、mihomo 三份配置一个字都没变，只是包不走原来那条路了。这种故障从配置上完全看不出来，所以判据必须在接受之前跑，而且拒绝时会点名是哪个网段跟什么冲突。想先问一句：

```bash
sudo pdg lan routes 192.168.1.0/24
```

**二、反代只认白名单。**域名到 `IP:端口` 一对一，不接受通配。上游还必须写字面 IP —— 写域名的话，决定网关去连哪台机器的就成了 DNS，而这台网关自己就在做 DNS 劫持。

**三、反代进程只能连白名单里的地址。**按运行它的 uid 过滤，不按端口（端口挡不住别的进程发起同样的连接）。这条规则挂在反代的启动路径上：加载不上就不让它起来。

### 用起来

```bash
sudo pdg lan add --name nas --host nas.example.com \
     --target https://192.168.1.50 --insecure
sudo pdg lan cert dns_cf          # DNS-01 签发, 凭据放 /etc/pdg-lan/dns.env (600)
sudo pdg lan enable
```

`add` 之后会自己把四份派生物跟上（反代配置、出站白名单、DNS 劫持集、分流规则），并且告诉你证书里还缺哪些面板。所有面板共用一张证书，所以加过面板就要重签一次。

Telegram 里也有：**运维 → 🏠 内网面板**，能看列表和状态、加删面板，还有一排直达按钮点一下就开。证书还没覆盖到的面板，按钮上会标着「待重签」—— 不至于点下去才发现是证书错误。

手机要走蜂窝网络。连着 WiFi 时 DNS 查询不是从内网卡过来的，网关不会劫持这些域名，点了打不开。

### 家用设备的那些毛病

这些是在七台真机上一台台踩出来的，生成器从第一版就带着，不用你自己发现：

设备会把自己的局域网 IP 写进跳转头（`--rewrite-location`）；有些会校验 `Referer`/`Origin` 必须是它自己的地址（`--fix-referer`）；老设备可能只提供 RSA 密钥交换的套件，现代 Go 默认不接受，症状是 502 加 handshake failure，看着像证书问题（`--legacy-tls`）；前后端分离的应用要在入口带参数，否则每台设备都得手输一遍后端地址（`--entry-query`）；家用设备的证书基本都是自签的，所以 `--insecure` 得你按设备逐个确认，不给默认值。

### 有一条风险要你自己判断

如果面板域名和本项目的 DoT 域名在同一个 DNS zone 里，那么给面板签证书用的那个 API token **也能签发你的 DoT 域名** —— 一台被拿下的网关可以拿它给 DoT 域名签张真证书，反过来 MITM 你自己的 DNS。这是权限升级，不只是多一个凭据。

`pdg lan status` 每次都会提醒。收窄的办法有两个：面板用另一个域名（token 就碰不到 DoT 那个 zone），或者把 `_acme-challenge` 用 CNAME 委派到单独的 zone，然后 `pdg lan cert <dns插件名> <委派zone>`。

还有一条：网关拿到了主动访问你家内网的能力。真正的硬边界不在网关上，而在家里那台子网路由器 —— Tailscale 的包过滤在目标节点执行，所以网关就算被 root 了，往 ACL 之外的地址发包也会被家里那台丢掉。ACL 要你自己在 tailnet 后台配（写法见第 12 节的 Access controls 一段）。`pdg doctor --deep` 会
主动探一个不在面板表里的地址，**连得上就说明还没收紧**；但探不到并不能反过来证明收紧了——那个
地址是猜的，它上面没有设备时的观测跟策略把包丢掉一模一样。所以这一项只帮你发现越界，
不出具安全证明。

### 不想要了

```bash
sudo pdg lan disable              # 停用, 面板表和证书都留着
sudo pdg lan purge                # 连配置、证书、DNS 凭据、caddy 一起清掉
```

`pdg uninstall` 也会一并带走，包括 DNS API 凭据和 acme 账户密钥 —— 服务没了而能改你 DNS 记录的凭据还留在盘上，比不卸载更糟。删不掉的会逐条点名。

## 14. 项目组成

| 层 | 组件 | 说明 |
|---|---|---|
| DNS | mosdns v5 | 按来源 IP 分支；判断顺序为 WLOC/MITM 接管 → **你指定要走出口的域名** → 国内直连 → 自动海外判断；代理域名 A 记录改写到本机、AAAA / HTTPS 置空；ECS 处理；缓存；DoT（853）；可选 GFWList 劫持模式 |
| 流量 | mihomo（clash.meta） | nft REDIRECT 入站 + redir 监听 + SNI 嗅探。多出口故障切换；提供 clash_api（观测面板）。改配置前先校验，失败回滚 |
| 管理 | Telegram Bot（Python 标准库） | 出口、分流、规则集、测速、流量、备份恢复、iOS 描述文件、自定义域名、WLOC；改配置前先校验，失败回滚 |
| 位置改写 | pdg-mitm（可选，iOS） | 自签 CA + 终止 TLS + 转发并替换 `gs-loc` 响应坐标 |
| 链路证据 | pdg-dotwitness | 手机链路测试的 DoT 侧观测点。只在诊断会话的时间窗内记「有没有一次专门的 DoT 查询到达」，落盘的是随机标识的摘要，不含查询内容。不依赖 mosdns 的 metrics 接口 |
| 内网面板 | Caddy（可选，方案 B） | 官方原版不带插件，只监听环回；证书由 acme.sh 走 DNS-01 签发。进程以 `pdg-lan` 身份跑，出站按 uid 白名单限死在面板表里的 `IP:端口` |
| 证书 | certbot standalone | Let's Encrypt，自动续期 |
| 防火墙 | nftables | 基座是独立的 `table inet pdg`：对全网只放行 SSH；DNS、数据、探测端口只放行内网卡来源段；mihomo 用 REDIRECT 入站，同样限内网卡来源。启用内网面板后另有一张 `table inet pdglan`，按 uid 把反代进程的**出站**限死在面板表里的 `IP:端口`。`/etc/nftables.conf` 里你自己的表逐字节保留 |

内核版本由 `pdg update` 随 PrivDNS Gateway 发布版指定并逐字节校验（SHA256）后安装。

### 分流优先级

**用户规则优先于自动规则。** 在 Bot 中为域名指定出口后，该规则会优先于国内/海外自动分类。
WDA 只处理没有手动指定出口的域名；WLOC 所需的 Apple 定位域名保持最高优先级。
`sudo pdg doctor` 会列出被其他规则抢先匹配、当前无法生效的规则。

规则**自上而下、第一条命中即止**，所以顺序就是优先级。这一层只决定域名进不进 mihomo，
**具体走哪个出口仍由你在 Bot 里配置的规则决定**。

管到这件事的两个文件：

- `/etc/mosdns/rules/custom_hijack.txt` —— Bot 里「域名 → 出口」写入，改判直连或删规则时移出。
- `/etc/mosdns/rules/ruleset_hijack.txt` —— **由启用中的规则集自动生成**，加/删/刷新规则集时
  在同一笔事务里重算。文本、`.list`、`.yaml` 类规则集直接取域名；mihomo 原生的 `.mrs` 是二进制，
  用内核自己的 `convert-ruleset` 反向导出域名清单，所以**同样能自动派生**。`ipcidr` 类型的规则集
  本来就没有域名，跳过。只有真读不出来的（文件损坏、类型认不出）才会被报出。
  手写过内容的文件（表头不是自动生成的那行）更新时不会被覆盖。

  这一层只在 `gfw` 模式下看得出差别：`all` 模式"不是国内就接管"本来就把规则集的域名兜住了。

**网关上还跑着别的服务？** 本项目的 `table inet pdg` 是 `policy drop`，而 nftables 里同一 hook 上
每条 base chain 都会执行——你写在别处的 `accept` 会被它架空（端口看着开着、实际不通）。

**装机会自动处理**：检测到你的 input 链里有放行规则时，会把那些 `accept` 复制一份进下面这个目录，
**你自己的防火墙文件一个字节都不改**（原来那些规则留着，只是变成冗余，确认无误后可自行删除）。
带 `drop`/`limit`/`jump` 的规则搬过去会改变行为，那种只会中止并逐条列出，交给你处理。
`PDG_NO_ADOPT_RULES=1` 可以关掉自动搬运。

要自己加放行也写进这个目录：

```bash
echo 'tcp dport 80 accept' | sudo tee /etc/privdns-gateway/nft-input.d/10-web.conf
sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables
```

它被 `include` 进 `pdg` 的 input chain 末尾（`policy drop` 之前），**且不受 `pdg update` 影响**——
`pdg` 那张表每次更新都按模板重建，手加在里面的规则会丢，加在这个目录的不会。写错语法会让整份防火墙
加载失败，改完先用 `nft -c` 校验。

**跑 Docker 的机器**：Debian 自带的 `/etc/nftables.conf` 开头有一行 `flush ruleset`，它会在每次
`systemctl reload nftables` 时把 Docker（以及 fail2ban、libvirt、k8s）建在内核里的表整个冲掉——
这跟本项目无关，是那台机器上本来就有的隐患。装机检测到这种组合时，会把那一行**注释掉**（保留原
文并写清怎么还原），必要时给你自己的表补上 `table X` + `delete table X`，让每张表各自重建——
去掉全局 flush 之后重复应用也不会累积规则。不希望我们动这个文件：`PDG_KEEP_FLUSH=1 bash install.sh`，
那时遇到冲突会中止并告诉你怎么手工处理。

**配置写入统一走事务。** 出口、分流、规则集、DNS 上游、防火墙、TFO、证书、WLOC 开关、备份恢复
等所有会改动生产配置的操作，都在一笔事务里完成：新配置先校验再写入，然后重启相关服务并确认它们
真的起来了；任何一步不成立就整笔回滚，现网配置保持原样。进程被杀这类中断可以用
`sudo pdg tx recover <id>` 收尾，`sudo pdg doctor` 会报出未完成的事务。两处**受控例外**：

- **WLOC 切地点 / 改坐标**：只改一个文件、一次原子替换、不动任何服务，没有多组件半成功的可能，
  因此走一条更短的路径以保证切换在 1 秒内完成；它仍与其它配置操作互斥，并写一条脱敏审计
  （不记地点名称与经纬度）。
- **观测面板前端资源（zashboard）**：固定版本 + SHA256 校验 + 暂存目录 + 原子替换，属于静态
  缓存资源，不是 DNS/分流生产配置，因此不纳入配置事务。

## 15. 文档

- [docs/QUICKSTART.md](docs/QUICKSTART.md) — 新手图文教程
- [docs/INSTALL.md](docs/INSTALL.md) — 安装细节 / DNS 配置 / 端口 / 版本说明
- [docs/TROUBLESHOOTING-PLAYBOOK.md](docs/TROUBLESHOOTING-PLAYBOOK.md) — 排障手册（症状 → 排查 → 修复）
- [docs/production-notes.md](docs/production-notes.md) — 实战记录与已知问题
- [docs/design-mitm-plugins.md](docs/design-mitm-plugins.md) — iOS 位置改写（WLOC）设计与原理
- [docs/rescue-plane-access.md](docs/rescue-plane-access.md) — 救援平面的手机端访问与指纹核对
- [docs/design-lan-panels.md](docs/design-lan-panels.md) — 内网面板访问（手机零 App）的设计、两种架构对比，以及端到端实测记录（含三个沙盒查不出来的坑）
- [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) — 发版前检查清单
- [CHANGELOG.md](CHANGELOG.md) — 更新日志

## 16. 免责声明与 License

本项目仅供学习与合法网络管理用途。请遵守你所在地的法律法规，使用者自行承担责任，作者不对使用后果负责。

License：[MIT](LICENSE)

# 安装 / 部署细节

## 0. 前提清单

- 墙外 VPS:**Debian 12+ / Ubuntu 22+**,root,**1 vCPU / 512MB+ 即可**(常驻 ~90MB)。
- 运营商**内网卡**:手机移动流量经私网到达 VPS,源 IP 是固定私有段。
- 一个**域名**,且你能改它的 DNS 记录(给 DoT 用)。
- 一个 **Telegram bot**(找 @BotFather 建,拿 token)和你自己的 **user id**(找 @userinfobot)。

## 1. 先把 DNS 准备好(这一步留给你)

给一个子域(如 `dot.example.com`)加一条 **A 记录指向你 VPS 的公网 IP**。

- **Cloudflare**:必须用「**仅 DNS / 灰云**」,**不要开橙云代理**(代理不覆盖 853 端口,会导致 DoT 连不上)。
- 其它 DNS 商:普通 A 记录即可。
- 等生效(`dig +short dot.example.com` 能返回你的 IP)再装。

## 2. 跑安装

一行装(脚本会自动把仓库拉到 `/opt/privdns-gateway` 再跑):

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

入口脚本只负责自举,实际安装会自动切到最新 `v*` 发布 tag,不安装 main 上未发布的中间提交。

或克隆后运行:

```bash
git clone https://github.com/misaka-cpu/privdns-gateway.git
cd privdns-gateway
git fetch --tags
git checkout "$(git tag -l 'v*' --sort=-v:refname | head -1)"
sudo ./install.sh
```

过程中:

1. **自动检测公网 IP**(可改)。
2. **自动检测 SSH 端口**(可改)——⚠️ 防火墙会按它放行,改错会把自己关门外。
3. **自动识别内网卡段**:脚本抓包 ~40 秒,期间用手机(走内网卡/蜂窝)打开 `http://<你的IP>` 或 ping 它一下,脚本据此推断 CIDR。
   没抓到可手填。
4. 填 **bot token / 你的 TG id / DoT 域名**。
5. 确认 A 记录已生效后,脚本用 **certbot standalone** 签证书(此时会临时占用 80 口)。
6. 下载 geosite、起服务、应用防火墙。

## 3. 装完

见 [README](../README.md#装完之后):手机设私密 DNS、bot 加出口/分流、iOS 下发描述文件。

默认路由是「**国内直连 / 其余国际从 VPS 直出**」。要把国际流量走你的落地节点,在 bot 里加出口再把 `final` 或具体规则指过去。

## 排障

| 现象 | 排查 |
|---|---|
| 证书签发失败 | A 记录没生效?80 口被云厂商安全组挡了?`dig +short 域名` 对不对 |
| 手机没 DNS | 私密 DNS 主机名填对了吗?手机确实走内网卡?`systemctl status mosdns` |
| 代理域名打不开 | `systemctl status sing-box`;出口加了吗、密码对不对(bot「🚦 测出口」)|
| 内网卡段填错 | 改 `/etc/mosdns/config.yaml` 的 `npn_clients` 和 `/etc/nftables.conf`,`systemctl restart mosdns && nft -f /etc/nftables.conf` |
| bot 不理你 | `systemctl status pdg-bot`;token / user id 对不对(`/etc/privdns-gateway/bot.env`)|

日志:`journalctl -u mosdns -u sing-box -u pdg-bot -n 50`。

## 非交互 / 自动化安装

预置环境变量 + `PDG_NONINTERACTIVE=1` 即可无人值守(适合脚本化/复刻):

```bash
sudo PDG_NONINTERACTIVE=1 \
     PDG_SERVER_IP=203.0.113.10 \
     PDG_SSH_PORT=22 \
     PDG_INTERNAL_CIDR=172.22.0.0/16 \
     PDG_BOT_TOKEN=123456:xxxx \
     PDG_ALLOWED=11111111 \
     PDG_DOT_DOMAIN=dot.example.com \
     ./install.sh
```

- 缺省项会自动探测(公网 IP / SSH 端口)或用默认值。
- `PDG_SKIP_CERT=1`:跳过 certbot,生成**自签占位证书**(先把服务跑起来,之后用 bot「🌐 DoT 自定义域名」补正式证书)。
- 安装会**自动关闭 systemd-resolved**(它占 `127.0.0.53:53`,与 mosdns 的 `0.0.0.0:53` 冲突)。

> 本仓库的 install.sh 已在全新 Debian 12 上实跑验证(mosdns/sing-box/bot/防火墙全部起来、DNS 劫持分流正确)。

## 需要开放的端口

本机 nftables 由 install.sh 自动配置(已按下表收敛);**云厂商安全组(控制台那层防火墙)也要放行**。

| 端口 | 协议 | 开放范围 | 用途 |
|---|---|---|---|
| 22 | tcp | 全网 | SSH 管理 |
| 853 | tcp | 仅内网卡段 | **DoT — 手机私密 DNS 入口(核心)** |
| 443 | tcp+udp | 仅内网卡段 | **sing-box 数据入口(嗅 SNI / QUIC)** |
| 80 | tcp | 仅内网卡段 | sing-box HTTP 入口(嗅 Host) |
| 53 | tcp+udp | 仅内网卡段 | 明文 DNS |
| 81 | tcp | 仅内网卡段 | iOS OnDemand 探测端点 |
| 5228-5230 | tcp | 仅内网卡段 | GMS/FCM 推送(mtalk.google.com 原生端口,经 sing-box 嗅探分流) |
| 9090 | tcp | 仅 127.0.0.1 | sing-box clash_api(bot 用,不对外) |
| 8443 | tcp | 临时·仅内网卡 | `pdg ios` 下发描述文件时短开,用完自动关 |

Bot 的“临时观测/控制面板”开启期间，9090 会临时监听 `0.0.0.0`，但 nftables 只允许安装时识别的内网卡段访问；面板可查看流量/连接并断开连接，持久规则和出口配置仍通过 Bot/CLI 修改。关闭、到时或 Bot 重启后会收回到 `127.0.0.1`。

⚠️ **证书签发/续期需要从公网访问 80 端口**(Let's Encrypt HTTP-01 校验):签发时 pre-hook 会把 80 临时对全网开放(并停 sing-box),完后还原。
所以**云安全组必须允许入站 80**,否则证书续期会失败。

出站:`output` 链 policy accept(全放行);网关需能访问 Telegram API、DNS 上游(1.1.1.1/8.8.8.8/223.5.5.5)、各落地节点、GitHub。

## 版本注意

- **sing-box 固定 1.12.x**。1.13 移除了 `sniff_override_destination`,升级即失效。
- mosdns v5.x。

### 看到 "入站字段已废弃 / 将在 1.12.0 中被移除" 怎么办

**说明你的 sing-box 版本不对(太旧),不是我们锁的 1.12.x。**
本仓库 install.sh 装的是项目锁定的 **1.12.x**(当前 **1.12.25**),实测 `sing-box check` 零告警——这条 "将在 1.12.0 中移除" 是 **1.11.x** 才会打的旧提示。

`sing-box version` 确认一下;如果不是 1.12.x,重跑 install.sh(会自动下项目锁定版)或手动换成 1.12.x。

> 本项目**锁 1.12.x** 的原因:1.13 移除了 `sniff_override_destination`,而它的新写法(`action: sniff`)**不覆盖目标地址**、会导致流量回环。
> 所以**别升 1.13+,也别用比 1.12 旧的版本**。

## 升级

- 日常升级用 `sudo pdg update`:**更新到最新发布 tag**(只跟 `v*` tag、不拉 main 上未发布的中间提交)+ 校验门 + 失败自动回滚到更新前快照,不动出口/分流/证书。版本号(`pdg status` / bot『🔄 更新』)用 `git describe` 显示,如 `v1.1.0`。
- **不要**用 `install.sh` 在已有部署上覆盖升级——它会拒绝并提示走 `pdg update`(确要覆盖重装才 `sudo PDG_FORCE_REINSTALL=1 ./install.sh`,会先打快照)。

### 旧版升上来的一次性防火墙迁移

早期版本的防火墙是 `flush ruleset` + `table inet filter`;新版改用独立表 **`inet pdg`**(不再清掉 Docker/fail2ban 等其它表)。

- 从旧版 `pdg update` 上来时,**下一次以 root 运行"管理类"命令**(`update` / `restart` / 直接 `sudo pdg` 进菜单等)会**幂等自动迁移**到 `inet pdg`(解析旧 SSH端口/内网段 → 渲染 → `nft -c` 校验 → 备份 → 加载新表确认在内核 → 才删旧表;全程 SSH 不断)。
- **只读命令**(`status` / `doctor` / `log` / `traffic` / `report`)**不会触发迁移**,以保持"只读不写"。只跑只读命令的可显式 `sudo pdg migrate-fw` 迁移。
- **改过防火墙的不会被自动重建**:迁移是用标准模板重建(只保留 SSH 端口 + 内网段)。若你在旧 `/etc/nftables.conf` 里**手动加过端口/规则/别的 table**,自动迁移会**检测到并跳过**(避免静默丢失),旧配置原样保留。届时请把自定义规则并入 `deploy/firewall/nftables.conf` 同风格后手动 `nft -f`,或 `sudo pdg migrate-fw` 迁标准部分后再补回自定义规则。
- 即使**尚未迁移**也能正常用:证书续期 hook 与 `doctor` 都兼容旧 `inet filter`。

## 流媒体/服务解锁(WDA,可选)

如果你的 VPS 厂商提供 **SmartDNS 解锁(WDA)** 服务,可在 bot『🌐 DNS 上游』用两个按钮整体切换:

- **🛬 解锁走落地出口**(默认):Netflix/Disney+/AI 等走各自分流出口(hk/tw)。
- **🔓 解锁走 WDA**:这些服务整体 → **本机(jp)直出** + 经解锁 DNS 解析到中继。中继是干净 IP,能避开 Netflix 对机房裸 IP 的代理封锁。

**开 WDA 前必须先在解锁服务商后台,把本机公网 IP 加白授权**(解锁按 IP 授权;多台网关要**每台 IP 各自加白**)。没授权就点 🔓,bot 会**自检后拦下并提示**(避免解锁服务拿不到中继、流媒体反而挂)。

- 解锁地区取决于你在厂商面板选的平台(VPS 在日本→选 JP 平台→日本区)。
- 解锁 DNS 默认对接 `22.22.22.22`(本项目所用厂商)。换别家解锁服务需同步改 `deploy/mosdns/config.yaml` 的 `unlock_upstream` 与 `deploy/bot/pdg-bot.py` 的 `UNLOCK_DNS`。
- 某个服务在 WDA 下不灵,点 🛬 整体切回落地即可(目前是整体开关,非按服务)。

## 卸载

```bash
sudo ./uninstall.sh           # 停服务、删 systemd 单元(留配置/证书/二进制)
sudo ./uninstall.sh --purge   # 连 /etc/mosdns /etc/sing-box /opt/pdg-bot 与二进制一起删
```

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

```bash
git clone https://github.com/misaka-cpu/privdns-gateway.git
cd privdns-gateway
sudo ./install.sh
```

过程中:

1. **自动检测公网 IP**(可改)。
2. **自动检测 SSH 端口**(可改)——⚠️ 防火墙会按它放行,改错会把自己关门外。
3. **自动识别内网卡段**:脚本抓包 ~40 秒,期间用手机(走内网卡/蜂窝)打开 `http://<你的IP>` 或 ping 它一下,脚本据此推断 CIDR。没抓到可手填。
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
| bot 不理你 | `systemctl status pdg-bot`;token / user id 对不对(`/etc/systemd/system/pdg-bot.service`)|

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

## 版本注意

- **sing-box 固定 1.12.x**。1.13 移除了 `sniff_override_destination`,升级即失效。
- mosdns v5.x。

## 卸载

```bash
sudo ./uninstall.sh           # 停服务、删 systemd 单元(留配置/证书/二进制)
sudo ./uninstall.sh --purge   # 连 /etc/mosdns /etc/sing-box /opt/pdg-bot 与二进制一起删
```

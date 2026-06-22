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
- 一个或多个**落地节点**(ss2022 / vmess / trojan / vless),用来出国际流量(可选,默认其余国际从 VPS 直出)。

---

## 一键安装 (Debian 12+ / Ubuntu 22+)

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

或克隆后运行(便于先看代码):

```bash
git clone https://github.com/misaka-cpu/privdns-gateway.git
cd privdns-gateway && sudo ./install.sh
```

脚本会装好 mosdns、sing-box(1.12)、管理 bot、防火墙和证书,自动识别公网 IP 和内网卡段,再交互填 DoT 域名(**bot token 可留空**,装完随时 `sudo pdg-set-token` 再设并启用)。
域名 A 记录这步留给你自己做(脚本会等你确认指向本机后再签证书)。
详见 [docs/INSTALL.md](docs/INSTALL.md)。

卸载:`sudo ./uninstall.sh`(加 `--purge` 连配置一起删)。

## 装完之后

1. 手机【私密 DNS / DoT】填你的域名(如 `dot.example.com`)。
2. Telegram 给 bot 发 `/start`:
   - **📤 出口管理 → 添加**:粘贴 `ss:// / vmess:// / trojan:// / vless://` 落地链接。
   - **📑 分流管理**:把域名、`.list` / `.txt` 等规则集指到出口(默认其余国际走 VPS 直出)。
   - **🔀 故障切换组**:多落地自动选最快 / 坏了自动切。
3. iOS:bot **📱 客户端 → iOS 描述文件**;**不用 bot 的话** `sudo pdg ios` 会直接在终端打出二维码,手机(走内网卡)扫码 → Safari → 装。
   蜂窝双卡探测 `:81` 已自动配好。
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

## 组成

| 层 | 用什么 | 说明 |
|---|---|---|
| DNS | **mosdns v5** | 国内直连 / 代理域名 A 劫持到本机 + AAAA/HTTPS 置空 / 按来源 IP 分支 / ECS 分治 / 缓存。DoT(853) |
| 流量 | **sing-box 1.12** | `direct` 监听 + `sniff_override_destination`(**不用 tproxy**);多出口 urltest 故障切换;clash_api 测速/流量 |
| 管理 | **Telegram bot**(纯标准库) | 出口/分流/规则集/测速/流量/备份恢复/iOS下发/自定义域名,改 sing-box 前 `check`+回滚 |
| 证书 | **certbot standalone** | Let's Encrypt,自动续期(已处理 80 口被 sing-box 占的坑) |
| 防火墙 | **nftables** | 对全网只留 SSH;DNS/数据/探测口只放行内网卡来源段 |

> ⚠️ sing-box **必须 1.12.x** —— 1.13 移除了 `sniff_override_destination`,本网关会失效。install.sh 已固定版本。

## 文档

- [docs/INSTALL.md](docs/INSTALL.md) — 安装细节 / DNS 配置 / 端口 / 版本注意
- [docs/TROUBLESHOOTING-PLAYBOOK.md](docs/TROUBLESHOOTING-PLAYBOOK.md) — 排障手册(症状 → 查 → 修)
- [docs/production-notes.md](docs/production-notes.md) — 实战记录与踩坑(sing-box 版本坑、QUIC 自环、ECS、安全加固等)
- [CHANGELOG.md](CHANGELOG.md) — 更新日志

## 免责声明

本项目仅供**学习与合法网络管理**用途。请遵守你所在地的法律法规;使用者自行承担责任。作者不对任何使用后果负责。

## License

[MIT](LICENSE)

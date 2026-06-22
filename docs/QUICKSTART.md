# 新手上手图文教程

面向**第一次部署**的人,一步步带你装好、连上、配好。已经熟悉的直接看 [INSTALL.md](INSTALL.md) 就行。

> 图片是占位,实际部署时把对应截图放到 `docs/images/` 即可。

---

## 1. 先准备这些

| 要什么 | 说明 |
|---|---|
| 一台 **kfchost vps** | Debian 12+ / Ubuntu 22+,1 vCPU / 512MB 就够(常驻约 60MB) |
| 一张**浙江联通手机号 SIM(暂时)** | 手机移动流量经运营商私网到达 VPS,源 IP 是固定私有段(如 `172.x`) |
| 一个**域名** | 你能改它的 DNS 记录(给 DoT 用) |
| 一个 **Telegram bot** | 找 [@BotFather](https://t.me/BotFather) 建,拿 token;再找 [@userinfobot](https://t.me/userinfobot) 拿你自己的 user id |
| 一个或多个**落地节点** | 用来出国际流量(可选) |

> 没有"浙江联通手机号 SIM"这类固定私有源段的 SIM,本项目不适用——它靠这个私有源段来区分该处理的查询。

VPS 用的是 **kfchost**:
- 官网(无 aff):https://kfchost.com/center/
- 邀请注册(aff):https://kfchost.com/center/dashboard?aff=AFF1113558QDH

---

## 2. 准备域名

给一个子域(如 `dot.example.com`)加一条 **A 记录指向你 VPS 的公网 IP**。

- **Cloudflare**:务必用「**仅 DNS / 灰云**」,不要开橙云代理。
- 等生效:`dig +short dot.example.com` 能返回你的 IP 再继续。

![DNS 控制台加 A 记录](images/dns.png)
*在域名控制台把子域 A 记录指向 VPS 公网 IP*

---

## 3. 注册并绑定 5GPN 门户

手机与 VPS 之间的私网连通,由 kfchost 的 **5GPN** 提供。开通流程:

1. 登录 [kfchost 控制台](https://kfchost.com/center/),打开你已购买的那台 VPS。
2. 在下方「**增值服务 → 5GPN**」里点「**生成链接**」,再点「**打开门户**」,浏览器会跳到 5GPN 网站。
3. 在 5GPN 网站**注册账号**(邮箱和 kfchost 用同一个或另一个都行)。

![5GPN 入口与门户](images/5gpn-portal.png)
*VPS 控制台 增值服务 → 5GPN → 生成链接 → 打开门户*

4. 注册后在门户里完成**与本机 VPS 的绑定**,并按门户指引在**手机侧**配置好 5GPN(具体以你看到的门户界面为准)。

![5GPN 绑定 / 手机端配置](images/5gpn-bind.png)
*5GPN 门户绑定与手机端配置*

> <!-- TODO: 这里按你实际的 5GPN 门户/手机端步骤补充细节 + 截图 -->
> 配好后,手机走这张 SIM 的流量才会以**固定私有源段**到达你的 VPS——这是后面分流能生效的前提。

---

## 4. 一键安装

SSH 登录 VPS,跑:

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

过程中它会:
1. **自动检测**公网 IP、SSH 端口、内网卡来源段(抓包识别,期间用手机走这张 SIM 访问一次本机)。
2. 让你填 **bot token / 你的 user id / DoT 域名**(token 可留空,装完再设)。
3. 确认 A 记录生效后自动签 Let's Encrypt 证书,起服务、应用防火墙。

![安装过程](images/install.png)
*install.sh 运行过程*

> 抓内网卡段那步若没抓到:先随便填(如 `172.22.0.0/16`),装完用 `sudo pdg detect-cidr` 从容重测并写回。

---

## 5. 建 Telegram bot 并启用管理

1. Telegram 找 **@BotFather** → `/newbot` 起名 → 拿到 **token**;再找 **@userinfobot** 拿你的 **user id**。

2. VPS 上跑(若安装时已填 token 可跳过):

   ```bash
   sudo pdg-set-token
   ```
   按提示粘 token 和 user id。**出口、分流规则都在 bot 里设,这步必须做**,否则没法配。

---

## 6. 手机设置:只填一个「私密 DNS」

**Android**:设置 → 网络和互联网 → **私人 DNS** → 选「指定主机名」→ 填你的域名 `dot.example.com`。

![Android 私人 DNS](images/android-dns.png)
*Android 私人 DNS 填域名*

**iOS**:Telegram 给 bot 发 `/start` → **📱 客户端 → iOS 描述文件**,存到「文件」App 再去 设置→通用→描述文件 安装;
不用 bot 也行,VPS 上跑 `sudo pdg ios` 直接出二维码,手机(走这张 SIM)扫码安装。

![iOS 描述文件](images/ios-profile.png)
*iOS 安装描述文件 / 扫码*

---

## 7. 在 bot 里配置出口和分流

Telegram 给 bot 发 `/start`,出现主菜单:

![bot 主菜单](images/bot-menu.png)
*bot `/start` 主菜单*

- **📤 出口管理 → ➕ 添加**:粘贴你的落地节点链接(`ss:// / vmess:// / trojan:// / vless://`)。
  ![添加出口](images/add-exit.png)
  *粘贴落地节点链接添加出口*

- **📑 分流管理**:把域名或规则集指到某个出口;不指的默认走「其余国际」的默认出口。
  ![分流管理](images/rules.png)
  *把域名/规则集指到出口*

- **🚦 测出口**:看各出口的延迟、是否可用。
  ![测出口](images/test.png)
  *测各出口延迟*

---

## 8. 日常管理:一条命令

VPS 上 `sudo pdg` 进管理菜单(状态 / 自检 / 更新 / 快照回滚 / 换 token / 日志 / 流量 / 识别内网卡段 / 卸载):

![pdg 管理菜单](images/pdg-menu.png)
*`sudo pdg` 管理菜单*

常用:
```bash
sudo pdg doctor       # 自检, 一眼看哪不对; --deep 加端到端检查
sudo pdg update       # 更新(更新前自动快照, 失败自动回滚)
sudo pdg report       # 生成脱敏诊断报告(贴出来求助用)
```

> 健康自检每 10 分钟自动跑,服务挂 / DNS 不应答 / 证书快到期会 Telegram 私信你。

---

## 9. 常见问题

- **手机完全没网** → 多半 mosdns 没应答:`sudo pdg doctor` 看「服务 / 本机DNS」。
- **某域名没生效** → bot **📑 分流管理 → 🔎 测域名**,看它命中哪条规则/出口。
- **iOS 蜂窝下不激活** → 删旧描述文件重装(新版探测 `:81` 已配好),开关一次飞行模式。
- 更多见 [排障手册](TROUBLESHOOTING-PLAYBOOK.md)。

---

装完之后,手机全程只有一条「私密 DNS」设置,其余都在 Telegram bot 里管。出问题先 `sudo pdg doctor`。

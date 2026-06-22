# 新手上手图文教程

面向**第一次部署**的人,一步步带你装好、连上、配好。已经熟悉的直接看 [INSTALL.md](INSTALL.md) 就行。

> 文中配图均为**示意图**(示例数据,非真实截图):域名按 `dot.example.com`、IP 按 `203.0.113.x`、手机号按 `187****1234`。

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

VPS 用的是 **kfchost** — 官网:<https://kfchost.com/center/> · 邀请注册:<https://kfchost.com/center/dashboard?aff=AFF1113558QDH>

---

## 2. 准备域名

给一个子域(如 `dot.example.com`)加一条 **A 记录指向你 VPS 的公网 IP**。

- **Cloudflare**:务必用「**仅 DNS / 灰云**」,不要开橙云代理。
- 等生效:`dig +short dot.example.com` 能返回你的 IP 再继续。

<p align="center">
  <img src="images/dns.svg" alt="DNS 控制台加 A 记录" width="520"><br>
  <sub>在域名控制台把子域 A 记录指向 VPS 公网 IP(仅 DNS)</sub>
</p>

---

## 3. 开通并绑定 5GPN(浙江联通专网)

手机与 VPS 之间的私网连通,靠 **5GPN**(联通「5G 双域专网 / 随行专网」,kfchost 代开)。
它把你**浙江联通手机号**的流量,经联通专网以**固定专网内网 IP** 送到你绑定的 VPS。

**① 在 kfchost 生成门户链接** — 登录 [kfchost 控制台](https://kfchost.com/center/) → 打开你的 VPS → 下方「**增值服务 → 5GPN**」→「**生成链接**」→「**打开门户**」。

<p align="center">
  <img src="images/5gpn-portal.svg" alt="kfchost 5GPN 生成链接" width="640"><br>
  <sub>kfchost 控制台:增值服务 → 5GPN → 生成链接 → 打开门户</sub>
</p>

> ⚠️ 仅限**浙江联通手机卡**;开通约**工作日 3 小时**内完成,非工作日顺延。

**② 在 5GPN 门户里完成开通和绑定**

1. **邮箱验证码**登录门户。
2. **手机号绑定**:填你的浙江联通手机号,系统据此识别对应的专网内网 IP。
3. **开通流量包**:确认开通「浙江-5G 随行专网超享包(10 元 50G)」(每号仅一次,走话费)。
4. **外站绑定**:门户里会看到 kfchost 传来的 VPS 加速目标,**确认绑定**(状态变「已生效」)。
5. **专网检测**:用这张联通卡的 **5G 网络**(关 WiFi)打开门户,确认显示「专网内」。

<p align="center">
  <img src="images/5gpn-bind.svg" alt="5GPN 客户门户" width="680"><br>
  <sub>5GPN 客户门户:手机号绑定 / 外站绑定(VPS)/ 专网检测</sub>
</p>

> 绑定生效后,手机走这张卡的流量才会以固定专网内网 IP 到达 VPS——这是后面分流能生效的前提。
> 云机暂停/删除会自动取消绑定;自助关闭只取消绑定、不退款。

---

## 4. 一键安装

SSH 登录 VPS,跑:

```bash
curl -fsSL https://raw.githubusercontent.com/misaka-cpu/privdns-gateway/main/install.sh | sudo bash
```

过程中它会:**①** 自动检测公网 IP、SSH 端口、内网卡来源段(抓包识别,期间用手机走这张 SIM 访问一次本机);**②** 让你填 bot token / 你的 user id / DoT 域名(token 可留空,装完再设);**③** 确认 A 记录生效后自动签 Let's Encrypt 证书,起服务、应用防火墙。

<p align="center">
  <img src="images/install.svg" alt="安装过程" width="600"><br>
  <sub>install.sh 运行过程</sub>
</p>

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

- **Android**:设置 → 网络和互联网 → **私人 DNS** → 选「指定主机名」→ 填你的域名 `dot.example.com`。
- **iOS**:Telegram 给 bot 发 `/start` → **📱 客户端 → iOS 描述文件**,存到「文件」App 再去 设置→通用→描述文件 安装;不用 bot 也行,VPS 上 `sudo pdg ios` 直接出二维码,手机(走这张 SIM)扫码安装。

<table align="center">
  <tr>
    <td align="center"><img src="images/android-dns.svg" alt="Android 私人 DNS" width="240"><br><sub>Android 私人 DNS 填域名</sub></td>
    <td align="center"><img src="images/ios-profile.svg" alt="iOS 描述文件" width="240"><br><sub>iOS 安装描述文件</sub></td>
  </tr>
</table>

---

## 7. 在 bot 里配置出口和分流

Telegram 给 bot 发 `/start`,出现主菜单:

<p align="center">
  <img src="images/bot-menu.svg" alt="bot 主菜单" width="280"><br>
  <sub>bot <code>/start</code> 主菜单</sub>
</p>

- **📤 出口管理 → ➕ 添加**:粘贴你的落地节点链接(`ss:// / vmess:// / trojan:// / vless://`)。
- **📑 分流管理**:把域名或规则集指到某个出口;不指的默认走「其余国际」的默认出口。
- **🚦 测出口**:看各出口的延迟、是否可用。

<table align="center">
  <tr>
    <td align="center"><img src="images/add-exit.svg" alt="添加出口" width="240"><br><sub>添加出口</sub></td>
    <td align="center"><img src="images/rules.svg" alt="分流管理" width="240"><br><sub>分流管理</sub></td>
    <td align="center"><img src="images/test.svg" alt="测出口" width="240"><br><sub>测出口</sub></td>
  </tr>
</table>

---

## 8. 日常管理:一条命令

VPS 上 `sudo pdg` 进管理菜单(状态 / 自检 / 更新 / 快照回滚 / 换 token / 日志 / 流量 / 识别内网卡段 / 卸载):

<p align="center">
  <img src="images/pdg-menu.svg" alt="pdg 管理菜单" width="440"><br>
  <sub><code>sudo pdg</code> 管理菜单</sub>
</p>

```bash
sudo pdg doctor       # 自检, 一眼看哪不对; --deep 加端到端检查
sudo pdg update       # 更新(更新前自动快照, 失败自动回滚)
sudo pdg report       # 生成脱敏诊断报告(贴出来求助用)
```

> 健康自检每 10 分钟自动跑,服务挂 / DNS 不应答 / 证书快到期会 Telegram 私信你。

---

## 9. 局限与补丁

「DNS + SNI」这套只兜走 **80 / 443、能按域名/SNI 判定**的流量。下面这些天生不走这套,属正常:

- **Speedtest 测速 / 纯 UDP(游戏联机、WebRTC)/ 直连 IP 的 App**:可在手机上常备一个 iOS 自带的**全局 VPN(IKEv2)**作兜底,要用时一键开、不用时关。
- **QUIC / HTTP3**:网关已 reject 手机源 UDP/443,逼客户端回落 TCP/443(才能被嗅 SNI 分流)。
- **Telegram App**:走直连 IP,不吃 DNS+SNI 分流。已内置一个**仅内网卡可达的 SOCKS5(网关 IP:8445)**:在 Telegram「设置 → 数据和存储 → 代理」加 SOCKS5、填 `网关IP:8445`(无需账号密码)即可。它的出口**跟随你的默认出口**(想走 hk 就把默认出口设成 hk)。

---

## 10. 常见问题

- **手机完全没网** → 多半 mosdns 没应答:`sudo pdg doctor` 看「服务 / 本机DNS」。
- **某域名没生效** → bot **📑 分流管理 → 🔎 测域名**,看它命中哪条规则/出口。
- **iOS 蜂窝下不激活** → 删旧描述文件重装(新版探测 `:81` 已配好),开关一次飞行模式。
- 更多见 [排障手册](TROUBLESHOOTING-PLAYBOOK.md)。

---

装完之后,手机全程只有一条「私密 DNS」设置,其余都在 Telegram bot 里管。出问题先 `sudo pdg doctor`。

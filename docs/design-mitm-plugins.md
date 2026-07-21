# 设计:MITM 插件框架 + Apple WLOC 位置改写(v1.5.0 特性 B)

> 状态:**✅ 已跑通并真机验证**(2026-07-21,.200 + iPhone iOS 26.5.2:北京、东京丸之内均成功切换)。框架(自签 CA + TLS 终止 + forward+patch + 多地点 bot + mosdns 强制劫持 + mihomo 路由)全部实现,单元测试 + 真机双重覆盖。首个插件:Apple WLOC(截 gs-loc.apple.com / gs-loc-cn.apple.com,把网络定位改写成设定坐标)。

## 0. 跑通配方与已知限制(务必先读)

WLOC 改的是 **Apple 网络定位查询**(`gs-loc.apple.com` / 国区 `gs-loc-cn.apple.com` 的 `/clls/wloc`)。**手机零 App**,靠系统 DoT + 信任网关 CA。生效需三个条件:

1. **手机内网卡(蜂窝)在用** —— gs-loc 查询经内网卡打到网关(DoT OnDemand 在内网卡路径上激活)。
2. **控制中心关 WiFi**(⚠️ **不是"设置里关 WiFi"**)—— 控制中心关只断网络、**radio 仍扫 AP**,于是设备照发 Wi-Fi 定位查询、数据走蜂窝到网关。"设置里关 WiFi" = radio 全关、不扫不查 → 没东西可改(**这是早期反复失败的误区**)。
3. **装并信任网关 MITM CA**(见「使用」)。

### 关键实现:forward+patch(**不能自造响应**)
早期版本"凭空构造"一个 gs-loc 响应,头部/格式对不上,iOS 直接丢弃。现在 `mitm_wloc.handle` 改成:**把手机原始请求(连 `User-Agent: locationd/...` 等头一起、去掉 Accept-Encoding)转发给真 gs-loc → 拿回真 protobuf 响应 → 递归把每个 location 子消息的 field1/field2(纬/经×1e8)patch 成目标坐标 → 原样返回**。格式 100% 保真,iOS 才接受。要点:响应按 Content-Length 读完就停(别等 close,否则 200 keep-alive 会超时丢响应);上游真 IP 用外部 DNS(8.8.8.8/1.1.1.1/223.5.5.5)解析,绕开本机 mosdns 的劫持。

### 能力与限制
- ✅ **任意城市,含跨国**(北京、东京丸之内均实测成功)。早期"跨国转圈定不了位"是**切换瞬态**,不是永久拒绝。
- ⏳ **iOS 26 缓存极重**:切城市后手机严重滞后,必须「设置→隐私→定位服务」关开一次或重启才刷新;切到差很远的地方会先转圈再稳。
- ⚠️ 仅影响**网络定位**:户外 GPS 强时 GPS 盖过它。对**今日水印相机 / 小红书同城 / 室内打卡**这类网络定位场景有效;**不适用**连续 GPS 的导航 / 打车 / 定位游戏(那类需电脑侧 GPS 级虚拟定位工具)。

## 使用

1. 装机选 iOS(`PDG_PLATFORM=ios`)→ 自动装 `pdg-mitm` 服务。
2. bot「🛠 运维 → 🍏 位置改写」→「➕ 添加地点」发「名称 纬度,经度」(如 `上海 31.2304,121.4737`)→「📍 地点/切换」点城市 →「✅ 开启」。多地点随时增删,开启中热切换。
3. bot「📱 客户端 → iOS 描述文件」装到 iPhone(描述文件已内含网关 CA)。
4. **iPhone 手动信任 CA**:设置 → 通用 → VPN与设备管理(装描述文件)→ 关于 → 证书信任设置 → 对「PrivDNS Gateway MITM CA」开完全信任。
5. 用时:内网卡在用 + **控制中心关 WiFi**;切城市后去「定位服务」关开一次刷新。

> ⚠️ **信任代价**:设备信任这张 CA = 它能解密该设备**所有 HTTPS**。系统只对声明的接管域名(gs-loc)实际 MITM,其余不解密,但能力是广的。仅用于自己的设备。

## 1. 目标与边界

- **能做**:让网关对**声明的接管域名**做 MITM(自签 CA 终止 TLS、解密、按插件改写响应),其余流量**照旧只嗅 SNI 不解密**、出口仍由 mihomo/sing-box 的分流规则决定。
- **首个插件**:Apple WLOC —— 截 `gs-loc.apple.com`,把设备查询到的 Wi-Fi AP 位置全部改写成用户设定的坐标,使设备定位落在该点。
- **重信任前提**:MITM 需设备**安装并信任一张自签根 CA**。这张 CA 理论上能解密信任它的设备的**所有 HTTPS**;本系统只对接管域名实际解密(其余域名内核根本不路由到 MITM),但**能力是广的**,必须在文档/UI/描述文件里如实告知用户。
- **用途定位**:自托管网关、用户自己的设备;**仅适用「内网卡路由 WiFi」拓扑**(见 §0,SIM 插手机蜂窝的用不了)。不面向他人设备。

## 2. 数据流

**现状(无 MITM,不变)**
```
手机 → DoT → mosdns 劫持代理域名→网关IP
手机 → 网关:443 (SNI=X) → nft REDIRECT→7893 → mihomo 嗅 SNI → 按域名分流 → 出口 → 真站
```

**接管域名的新流(以 gs-loc.apple.com 为例)**
```
① DNS:mosdns 把"接管域名"强制劫持→网关IP
      (gs-loc.apple.com 属 Apple/国内直连集, 默认不劫持 → 插件启用后进 force_hijack 集, 强制劫持)
② 手机 → 网关:443 (SNI=gs-loc.apple.com) → nft REDIRECT→7893 → mihomo 嗅 SNI
③ mihomo 规则:接管域名 → 路由到 MITM 出站(socks5 → 127.0.0.1:MITM_PORT)
④ MITM 服务:收到 socks 目标 = gs-loc.apple.com:443 → 不连真站, 用 CA 现签该域名叶子证书、
   终止 TLS → 解密 HTTP → 交对应插件 → 插件构造改写后的响应 → 回给手机
```
> 出口"仍由内核决定"= 非接管域名完全不进 MITM;接管域名由 mihomo 规则显式指到 MITM 出站。

## 3. 组件

| 组件 | 职责 | 落点 |
|---|---|---|
| **CA 管理** | 生成/存自签根 CA(私钥 600);按域名现签叶子证书(缓存);公钥 CA 供设备信任 | `/etc/privdns-gateway/ca/`(key 600) |
| **MITM 服务** | 本地 socks5 服务:对接管域名用 SNI 回调选叶子证书、终止 TLS、分发给插件;非接管目标可选直连兜底 | 新 systemd 服务 `pdg-mitm`,听 127.0.0.1:MITM_PORT |
| **插件框架** | 插件声明 `{name, version, domains[], handler(req)->resp}`;启用即把 domains 注入 force_hijack 集 + MITM 注册表 + 内核路由规则 | `/opt/pdg-bot/plugins/` |
| **mosdns 集成** | 接管域名进 `force_hijack` 域名集(优先级高于 CN/直连),确保劫持到网关 | mosdns internal_sequence 加一段 |
| **内核集成** | 加 MITM 出站(socks5→MITM 服务)+ 接管域名 → MITM 出站的规则 | mihomo:proxies+rules;sing-box:outbound+route(两核对称) |
| **Apple WLOC 插件** | 解 `gs-loc.apple.com` 的 protobuf 请求、构造把各 BSSID 映射到指定坐标的响应 | 内置插件 |
| **iOS 下发** | 描述文件追加 CA 根证书 payload;提示用户去「证书信任设置」手动启用完全信任 | pdg-dot mobileconfig |

## 4. 关键决策点(需你拍板)

1. **MITM 服务语言**:
   - **Python(推荐)**:纯 stdlib `ssl`(`SSLContext.sni_callback` 按 SNI 现选证书)+ 一个小 protobuf 编解码;**不新增编译二进制、不动供应链信任锚**;定位查询量极低,性能足够。
   - Go:更快,但要引入一个新构建/二进制 + SHA 供应链。
   → 我倾向 **Python**(与本项目"纯标准库、不加二进制"的一贯风格一致)。
2. **CA 信任范围**:确认你接受「设备信任这张 CA = 它能解密该设备所有 HTTPS」这个代价(系统只对接管域名实际解密,但能力是广的)。iOS 还需手动去「证书信任设置」开完全信任。
3. **插件分发**:v1 只做**内置插件**(项目自带 WLOC),先不做 5GPN-X 那种「从 URL 安装」的第三方插件市场(那会引入插件签名/沙箱一整套信任问题)。
4. **双核**:MITM 服务与内核解耦;接管域名的强制劫持在 mosdns(两核通用);"路由到 MITM 出站"在内核配置(mihomo 与 sing-box 都要生成对应规则)。v1.5.0 以 mihomo 为主,sing-box 对称补上。
5. **WLOC 坐标**:由用户在 bot 里设定目标经纬度(默认可给一个点);是否需要多档/按 SSID 不同坐标?v1 先做**单一全局坐标**。

## 5. 分阶段实现计划

1. **CA 骨架**:生成根 CA + 现签叶子证书 + 缓存(可单元测试:签出的叶子证书链能被 CA 验)。
2. **MITM 服务**:socks5 入口 + SNI 回调 TLS 终止 + 插件分发骨架(先用一个 echo 插件真机验证「手机连接管域名 → 被 MITM 终止」)。
3. **mosdns force_hijack + 内核路由**:接管域名强制劫持 + mihomo 规则路由到 MITM;netns 真机验证接管域名确实进 MITM。
4. **Apple WLOC 插件**:protobuf 编解码 + 坐标改写;真机(iPhone 装 CA)验证定位被改写。
5. **iOS 下发 CA + bot UI**:描述文件带 CA;bot 管理插件启用/坐标设置;doctor 覆盖。
6. **测试 + 文档**,并入 v1.5.0。

## 6. 安全与合规注记

- MITM + 根 CA 是**重信任**操作,文档、bot 提示、iOS 描述文件都要**显著告知**用户其含义与范围。
- 系统默认只对**明确声明的接管域名**做 MITM,其余 HTTPS 不解密。
- 面向用户自己的设备与自托管网关;不提供针对他人的能力。

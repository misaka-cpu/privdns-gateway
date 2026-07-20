# 设计:MITM 插件框架 + Apple WLOC 位置改写(v1.5.0 特性 B)

> 状态:**设计稿,待用户确认方向后动手**。仿 5GPN-X 的「声明接管域名 → 网关执行动作 → 出口仍由内核决定」。首个插件:Apple WLOC(把 Apple 的 Wi-Fi 定位响应改写成指定坐标)。

## 1. 目标与边界

- **能做**:让网关对**声明的接管域名**做 MITM(自签 CA 终止 TLS、解密、按插件改写响应),其余流量**照旧只嗅 SNI 不解密**、出口仍由 mihomo/sing-box 的分流规则决定。
- **首个插件**:Apple WLOC —— 截 `gs-loc.apple.com`,把设备查询到的 Wi-Fi AP 位置全部改写成用户设定的坐标,使设备定位落在该点。
- **重信任前提**:MITM 需设备**安装并信任一张自签根 CA**。这张 CA 理论上能解密信任它的设备的**所有 HTTPS**;本系统只对接管域名实际解密(其余域名内核根本不路由到 MITM),但**能力是广的**,必须在文档/UI/描述文件里如实告知用户。
- **用途定位**:自托管网关、用户自己的设备、内网卡 SIM 场景下让定位与出口一致/隐私。不面向他人设备。

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

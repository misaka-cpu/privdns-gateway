# 发版前检查清单

打 `v*` tag 前,在**一台 throwaway 机**(全新 Debian 12/13 或 Ubuntu 22/24)上把下面四个场景跑一遍。
单元测试(`tests/`)覆盖不到"装机 / 升级 / sing-box→mihomo 迁移"这类集成问题——本清单专门抓它们。

> 本清单是照着真实翻过的车写的:v1.5.1(WLOC 开着时 `pdg update` 误回滚)、v1.5.2(从 v1.4.x 升级漏装 `sb2mihomo`/`mitm_*` → switch-core 报 ModuleNotFoundError)、v1.5.5(切 mihomo 后 TG 代理 :8445 没渲染)。这几个单测全绿、却都是部署才炸。

装机用非交互 env(`PDG_SKIP_CERT=1` 自签占位,免签真证书):
```bash
PDG_NONINTERACTIVE=1 PDG_SERVER_IP=<公网IP> PDG_INTERNAL_CIDR=172.22.0.0/16 \
  PDG_SSH_PORT=22 PDG_SKIP_CERT=1 PDG_PLATFORM=<ios|android> \
  bash install.sh
```

---

## ① 全新安装(两种平台)

至少跑 **iOS** 和 **Android** 两组(内核统一 mihomo)。装完:

- [ ] `pdg doctor` 全绿(无 🔴/🟡)。
- [ ] 服务全 active:`systemctl is-active mosdns mihomo pdg-bot`(iOS 追加 `pdg-probe81` `pdg-mitm`)。**Android 上 `pdg-probe81`/`pdg-mitm` 应不存在**(`systemctl is-enabled` 报 not-found),81/7894 不监听。**sing-box 二进制/服务都不应存在**。
- [ ] **平台专属模块只在对应平台**:iOS `ls /opt/pdg-bot/{mitm_ca,mitm_server,mitm_wloc}.py` 齐; **Android 这三个 + `probe81.py` + 描述文件模板都不应存在**。`sb2mihomo.py` 两平台都在。
- [ ] 平台门控对:**iOS** doctor 有「MITM 插件」「MITM结构」「平台=ios」无「GMS 推送」「iOS 探测」缺失;**Android** 反之(有 GMS、无 MITM/probe81)。
- [ ] **平台隔离(硬门控)**:**Android** bot「📱 客户端」无「iOS 描述文件」按钮;点旧消息里的 iOS/WLOC 按钮被拒;`sudo pdg ios` 友好拒绝(不装 qrencode、不开 8443)。**iOS** 有描述文件/WLOC。
- [ ] **描述文件取件通道**:`sudo pdg ios` 与 `sudo pdg ios previous` **都**打出二维码,其间 `ss -ltn | grep 8443` 有监听、`nft list ruleset | grep 8443` 有临时放行;回车收尾后两者都没有。(5.4 早期 `previous` 只把文件写到服务器上,手机拿不到。)
- [ ] **iOS 无 GMS 残留**:`grep -c in-gms /etc/sing-box/config.json` = 0;`nft list ruleset | grep 5228` 无。
- [ ] **平台标记**:`cat /etc/privdns-gateway/platform` 为 ios/android;缺失时 `pdg status`/doctor 明确提示「按 Android 回退」而非静默。

## ② 从上一个发布版升级(最容易翻车)

先装**上一个** tag,再 `pdg update` 到本版——复现"旧脚本装新版"的时序滞后:
```bash
git -C /opt/privdns-gateway checkout <上一个tag>   # 或直接用旧 tag 装
pdg update                                          # 切到本版
```
- [ ] `pdg update` **成功、没触发回滚**(校验门过)。
- [ ] **新增的 bot 模块升级后就位**(`ls /opt/pdg-bot/sb2mihomo.py` 等)——靠 `migrate_deploy_botfiles` 自愈;缺了说明迁移没跑到。
- [ ] `pdg doctor` 全绿。
- [ ] **iOS + WLOC 开着**时再 `pdg update`:不因「pdg-mitm 未运行」误回滚(pdg-mitm 有被 `reset-failed`+重启)。

## ③ 从 sing-box 旧版升级 → 自动迁移到 mihomo(v1.6.0 关键路径)

先装一个**仍支持 sing-box 的旧 tag**(如 `PDG_CORE=singbox` 装 v1.5.x),确认在 sing-box 上跑通,再 `pdg update` 到本版,验证 `migrate_drop_singbox` 自动迁移:
```bash
pdg update     # __migrate 里自动 sing-box → mihomo
```
- [ ] `pdg update` 成功、不回滚;`cat /etc/privdns-gateway/backend` = `mihomo`。
- [ ] **sing-box 已彻底移除**:`systemctl is-enabled sing-box` 报 not-found、`ls /usr/local/bin/sing-box` 不存在。
- [ ] `systemctl is-active mihomo` = active;`pdg doctor` 全绿。
- [ ] **所有入站都在**:`ss -tlnp | grep -E ':(80|443|5228|8445)'` —— 尤其 **:8445(TG 代理)有人听**。
- [ ] **出口/分流全保留**:bot「🚦 测出口」每个出口都返回延迟、不报「超时/不通」;**direct 出口(jp)** 也通(它在 mihomo 里映射成内建 `DIRECT`)。
- [ ] **有不可转换出口时**:config.json 里放一个 mihomo 不支持的出站,`pdg update` 应**中止并回滚到旧 sing-box 版**(数据无损),报出该出口名。

## ④ WLOC(仅 iOS 装机)

- [ ] bot「🍏 位置改写」:加地点(点按钮 **和** 直接发「名称 纬度,经度」两种都试)、切换、开启。
- [ ] `systemctl is-active pdg-mitm` = active;`pdg doctor` 有「🟢 MITM 插件」。
- [ ] `/etc/mihomo/config.yaml`(mihomo)有 `MITM-OUT` + `DOMAIN-SUFFIX,gs-loc*` 规则;`mitm_hijack.txt` 有 gs-loc 两域名。
- [ ] (有真 iPhone 时)内网卡 + 控制中心关 WiFi + 定位服务关开 → 定位改到设定城市。

## ⑤ 卸载

```bash
bash uninstall.sh --purge
```
- [ ] 服务全 disable+删:`mosdns sing-box mihomo pdg-bot pdg-probe81 pdg-mitm`。
- [ ] `--purge` 后 `/etc/privdns-gateway`、`/etc/mihomo` 都删掉。

---

## 打 tag / 发布

四个场景都过,再:
```bash
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin HEAD:main && git push origin vX.Y.Z
gh release create vX.Y.Z --latest --title "vX.Y.Z" --notes ""   # 标题只写版本号, 正文留空
```
两台线上 `pdg update`,各 `pdg doctor --deep` 收尾。

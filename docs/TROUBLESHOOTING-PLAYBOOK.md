# 排障手册 (Playbook)

出问题先跑一条 **`sudo pdg doctor`** —— 只读检查会直接点出大部分故障(服务、mihomo 版本、DoT A 记录、dot-domain 一致性、内网卡段、防火墙、代理入口、GMS 推送、限流、内存模式、证书、本机 DNS、mihomo 配置 check)。
下面是按症状的细查。

---

## iOS 能连但上不了外网 / DoT 没激活
iOS 靠描述文件的 OnDemand「探测 `:81` 成功才启用 DoT」。
- **查**:服务器 `:81` 必须返回 **HTTP 200**(不是 204,iOS 不认 204);手机抓不到 DoT(`:853`)说明没激活。
  服务器上:`curl -s -o /dev/null -w '%{http_code}' --interface <内网卡IP> http://<本机IP>:81/probe` 应为 `200`。
- **修**:① 确认 `pdg-probe81` 在跑、:81 返 200;② **手机删掉旧描述文件**(老的可能探 :80)→ `sudo pdg ios` 扫码装新的 → 开关飞行模式。

## 手机完全没网(连国内都打不开)
多半是 mosdns 没在应答。
- **查**:`sudo pdg doctor` 看「服务 / 本机DNS」;`systemctl status mosdns`;`journalctl -u mosdns -n 30`。
- **常见根因**:mosdns 证书路径不对(如跨机导入了别人配置,指向不存在的 `/etc/dnsdist/certs`)→ mosdns 崩溃重启。
  doctor 的「DoT A 记录 / mihomo 配置」也会连带异常。
- **修**:把 `/etc/mosdns/config.yaml` 的 `cert:` 指到真实存在的证书(`/etc/mosdns/certs/…`),`systemctl restart mosdns`。

## 流量没到本机 / 内网卡不通
- **查**:`tcpdump -ni any host <本机公网IP> and not port 22`,让手机(走内网卡,关 WiFi)访问网页,看有没有 `172.x → 本机` 的包。
- **没有包** = 内网卡没路由到这台(运营商侧的事,脚本管不了);确认手机私密 DNS 域名指向本机的 DoT 域名。

## 证书续期失败 / 快到期
- **查**:`sudo pdg doctor` 的「证书」;`certbot renew --dry-run`。
- **根因**:① 云厂商安全组挡了入站 **80**(Let's Encrypt HTTP-01 要从公网访问 80);
  ② `dot-domain` 文件与证书 CN 不一致(doctor 的「DoT 域名一致性」会警告)→ 续期会部署错证书。
- **修**:① 安全组放行 80;② `echo <证书CN域名> > /opt/pdg-bot/dot-domain`。

## 内核版本不对 / 行为异常
- **根因**:mihomo 版本与本发布版钉死的不一致(手工换过内核, 或更新中途失败)。
- **修**:`mihomo -v` 确认;不对就 `sudo pdg update`(会按 lib/versions.sh 钉死版本装并校验 SHA256)。doctor 的「mihomo 版本」「mihomo 配置」会 WARN/FAIL。
- > v1.6.0 起已彻底移除 sing-box 运行时(它被钉死在 1.12.x:1.13+ 移除了本网关依赖的 `sniff_override_destination`)。老机器 `sudo pdg update` 会自动迁到 mihomo。

## 代理域名走错出口 / 不确定某域名走哪
- 用 bot **📑 分流管理 → 🔎 测域名**,或思路:mosdns 先判直连(国内)还是劫持(其余),mihomo 再按规则首条匹配选出口。
- **规则明明加了却不生效**:内核**自上而下第一条命中即止**,排在前面的规则会让后面同域名的那条永远轮不到。
  先跑 `sudo pdg doctor` 看「**分流优先级**」那一项——它会点名"哪条点名规则被谁压住了"、该怎么办。
  自动生成的规则有两批,处置不同:
  - 🔓 **WDA 解锁**(55 个流媒体/AI 域名 → jp 直出,内核里显示 `DIRECT`)排在**你点名的单域名规则之后**;
    老机器上如果还是旧顺序(WDA 是在你加规则之后开的),下一次在 bot 里改任何配置就会自动重排,
    也可以立刻关一次再开 🔓 WDA。
  - **MITM 接管**(`gs-loc*.apple.com` → `MITM-OUT`,仅 iOS)**故意**排在最前(WLOC 要先接管 TLS),
    它不会给点名规则让路——要么删掉那条规则,要么关掉 WLOC。
- 想看内核真正的求值顺序:`curl -s 127.0.0.1:9090/rules | python3 -m json.tool | head -60`(顺序即优先级;
  面板设了 secret 就加 `-H "Authorization: Bearer <secret>"`)。

## bot 按钮反应慢
- 点一次按钮 = 2 个到 Telegram 的来回,延迟下限就是本机到 `api.telegram.org` 的 RTT(物理距离,代码压不掉)。
- 若**又慢又时灵时不灵**:大概率**两台机用同一个 bot token**在抢 getUpdates。
  一个 token 只能一个实例轮询——要么只在一台跑 `pdg-bot`,要么各用各的 bot。

## 流量统计"看着不准"
- bot 📈流量 的「实时」来自 clash_api = **内核本会话**(mihomo 重启即清零)且**只算经代理的流量**;不是机器总用量。
- 要准确的今日/本月/累计看「总用量(vnstat·网卡真实)」或 `sudo pdg traffic`(vnstat 刚装需跑几分钟才有数)。

## 改坏了想退回
- `sudo pdg rollback`(默认回最近一次快照;`pdg snapshot` 可手动留底)。`pdg update` 失败会自动回滚。

## 想把现场贴给别人排障
- `sudo pdg report` 生成一份**脱敏**诊断快照到 `/opt/pdg-bot/pdg-report-*.txt`(600)。
  已自动隐藏 token / 密码 / uuid / 出口链接;内容含 doctor、服务、日志、版本、端口、证书、A 记录、防火墙。贴出前再扫一眼更稳。

# 设计:内网面板访问(手机零 App)

> 状态:**方案 B 已实现**(2026-08-22)。方案 A 的实测经验见第 6 节 —— 那些设备毛病
> 在 B 里一条都没消失, 反代生成器从第一版就带着它们。
>
> **实现到哪一步、哪些没验, 见第 9 节。**别把"沙盒里产物正确"当成"手机能打开面板":
> 后者要真实的 tailnet 子网路由与真实设备, 沙盒造不出来。

## 1. 要解决什么

用户在外面想访问家里的内网面板(路由器、NAS、IPMI、ESXi 之类的 Web UI),
**而且不想在手机上装或开任何 App**。

传统做法要么开端口转发 + DDNS(暴露面大、依赖公网 IP),要么装 VPN App(违背"零 App")。

这个项目恰好有一个别人没有的支点:**它已经在替手机做 DNS 解析和流量分流**。
把内网面板的域名劫持到网关、再从网关经 tailnet 回到家里,手机侧一个字都不用改 ——
它只是在访问一个"普通的 HTTPS 网站"。

## 2. 两种架构

链路的两端是固定的:手机 →(SIM)→ 网关 → ??? → 家里的设备。差别只在 **??? 那一段谁做什么**。

### 方案 A:复杂度留在家里

```
手机 --SIM--> jp:443 --REDIRECT--> mihomo --socks5 出口--> 家里的机器
                                                          ├─ SOCKS5(只绑 tailnet)
                                                          └─ 反代(按 Host 分发到设备)
```

- 家里那台要跑:Tailscale + SOCKS5 + 反代 + ACME(DNS-01)
- **网关侧零新增权限** —— jp 只是多了一个 socks5 出口,它够不到家里任何别的东西
- 家里那台必须是能跑这些的 Linux

### 方案 B:复杂度留在网关

```
手机 --SIM--> jp:443 --REDIRECT--> mihomo --> jp 上的反代 --tailnet--> 家里的设备
                                                                      └─ 只要 Tailscale
```

- 家里只要能跑 **Tailscale 子网路由**(OpenWrt / 群晖 / 树莓派都行)
- 反代、证书、映射表全在 jp —— 那是项目本来就控制的环境,可以脚本化
- **代价:jp 获得了主动访问用户家内网的能力**

**给别人用应当选 B。**家里那侧的门槛降到"能装 Tailscale",而复杂的部分落在项目自己
管得住的机器上。A 更安全但要求家里有一台能跑反代的 Linux,那是少数人的条件。

## 3. B 的三道门(必须写进代码,不能只写进文档)

### 门一:拒绝重叠路由 —— 唯一的灾难级

家里通告的网段一旦与 `PDG_INTERNAL_CIDR` 或 jp 自身网段重叠,**手机的流量会被路由进
tailnet**,数据面直接错乱,而且从配置上完全看不出来。

判据(纯计算,可常驻 doctor):

- 接受的每个网段与 `PDG_INTERNAL_CIDR` 做重叠检测,有交集就拒绝;
- 与 jp 自身任一接口地址所在网段有交集就拒绝;
- **一律拒绝默认路由通告**(`0.0.0.0/0` / `::/0`)—— 那会把网关变成家里的出口节点。

拒绝时必须点名是哪个网段与什么冲突,而不是笼统说"路由不合法"。

### 门二:反代只做白名单映射

域名到 `IP:端口` **一对一**,不接受通配、不按 Host 动态解析目标。
否则任何能触发 SNI 的人都能让 jp 去连家里的任意地址。

配置形如(存 `/etc/privdns-gateway/lan-panels.json`,mode 600,纳入 pdgtx 事务目标):

```json
{"panels": [
  {"name": "nas",    "host": "nas.home.example.com",    "target": "https://192.168.1.50",      "insecure_upstream": true},
  {"name": "router", "host": "router.home.example.com", "target": "https://192.168.1.1:8443",  "insecure_upstream": true}
]}
```

`insecure_upstream` 必须显式写:家用设备几乎都是自签证书,但**默认跳过校验是错的** ——
那应当是用户按设备逐个确认的决定。

### 门三:出站白名单

jp 只允许经 `tailscale0` 访问**配置里出现过的** `IP:端口`,其余一律 reject。
按运行反代的那个 uid 过滤,不按端口 —— 端口挡不住"别的进程发起同样的连接"。

这一层挡不住 jp 被 root(攻击者能改防火墙),但挡得住**进程级失守**(反代被利用)。

## 4. 真正的硬边界不在 jp 上

**Tailscale 的包过滤在目标节点执行。**把 ACL 写成只允许网关访问那几个 `IP:端口`,
执行者是**家里那台子网路由器** —— jp 就算被 root 了,往别的地址发包也会被家里那台丢掉,
它改不了别人机器上的过滤器。

```json
{"acls": [{
  "action": "accept",
  "src": ["tag:pdg-gateway"],
  "dst": ["192.168.1.50:443", "192.168.1.1:8443"]
}]}
```

**项目管不了用户的 tailnet 后台**,但可以:

- 文档给出 ACL 模板(按配置里的面板集合自动生成一份让用户粘贴);
- **doctor 主动探测**:尝试连一个**不在**面板集合里的内网地址,连得上就说明 ACL 没配对 ——
  这是能测出来的,不是只能靠嘱咐。

## 5. 实施拆解

| 部分 | 内容 | 参照现有实现 |
|---|---|---|
| 配置 | `PDG_LAN_ENABLED` / `PDG_LAN_DOMAIN` 进 `profile.env`;面板表进 `lan-panels.json` | 救援平面的 `PDG_RESCUE_ENABLED` / `PDG_RESCUE_BIND` |
| CLI | `pdg lan <status\|enable\|disable\|add\|rm\|list>` + 菜单项 | `pdg rescue`、`pdg ssh-source` |
| 反代 | 由面板表**生成**配置,不让用户手写 | mihomo 配置由 `sb2mihomo.py` 生成 |
| 证书 | DNS-01;token 存 600 文件,经 systemd `EnvironmentFile` 注入 | 见第 7 节的风险 |
| 事务 | 面板表纳入 pdgtx 目标,改配置走 before-image + 回滚 | `"model"` / `"mosdns_conf"` |
| doctor | 路由重叠、面板可达性、ACL 越界探测、证书剩余天数 | `check_rescue_firewall` 等 |
| 卸载 | 反代 + 证书 + token + 防火墙规则 + 通告路由的接受态 | `uninstall.sh` 里的救援平面清理 |
| 测试 | 重叠检测的单元测试(含边界);白名单生成的负控;E2E 走一遍 enable→访问→disable | — |

体量估计:产品代码 **600~1000 行**,测试 **6~10 支**。作参照,救援平面是 3166 行 + 19 支,
WLOC 是 940 行 + 7 支 —— 所以这个功能**比救援平面小**,与 WLOC 相当。

## 6. 已实测的部分(方案 A,2026-08-21)

这些数字来自真机,不是设计推演:

- 链路成立:手机(零 App)经 SIM → jp → tailnet → 家里 → 七个面板全部 HTTP 200,
  证书是 Let's Encrypt 真证书(`ssl_verify_result=0`)。
- **设备会把自己的局域网 IP 写进 `Location` 跳转头**(Zyxel 交换机、华为 UPS 实测),
  反代必须改写,否则手机跟着跳到一个到不了的地址。
- **有些设备校验 `Referer`/`Origin` 必须是自己的地址**(华为 UPS2000 实测,返回
  `Error Referer Request!`),反代要在上行方向改回去。
- **老设备的 TLS 套件可能被现代 Go 拒绝**:华为 UPS2000 只提供 `AES256-GCM-SHA384`
  (RSA 密钥交换),Go 1.22 起默认禁用 —— 表现为 502 + `handshake failure`,看着像证书问题。
- **`sub-store` 这类前后端分离的应用**要在跳转里带 `?magicpath=` 之类的参数,否则每台设备
  都得手输后端地址。
- ACME 必须走 **DNS-01**:家里那台在 NAT 后面,HTTP-01 签不了。

上面这五条**在方案 B 里一条都不会消失** —— 它们是设备的毛病,与反代跑在哪无关。
所以 B 的反代生成器要从一开始就带这些改写能力,不能等踩到再补。

## 7. 风险与取舍(不粉饰)

**① jp 被拿下 = 用户家内网暴露。**这是 B 的固有代价,不是 bug。第 4 节的 ACL 能把它压到
"只有配置过的那几个 IP:端口",但压不到零。A 没有这个风险 —— 那也是 A 存在的理由。

**② DNS API token 的爆炸半径。**B 里 token 放在 jp 上。Cloudflare 的 token 只能按 zone 授权,
而那个 zone 里通常还有**本项目自己的 DoT 域名** —— 一个被拿下的 jp 可以用它签发
`dot.example.com` 的证书,进而 MITM 用户的 DoT。这是**权限升级**,不只是"多一个凭据"。

缓解:面板用**独立的子域并把 `_acme-challenge` CNAME 委派到单独的 zone**,让 token 只控制
那一个 zone。文档必须把这一条写在最前面,而不是当作可选建议。

**③ 触发条件是网段而不是身份。**判据是"源地址在 `PDG_INTERNAL_CIDR`",所以同运营商网络里
能路由到网关的设备理论上可以用任意 SNI 走进来,最后一道防线只剩面板自身的登录。
这是**现有分流机制就有的**性质,B 没让它更糟,但做成给别人用的功能时要正面写清楚,
并提供收紧手段(客户端证书,或给规则加来源限制)。

## 8. 明确不做

- **不支持非 HTTP/HTTPS 的服务**。SSH / SMB / RDP 走不了 —— 反代只能按 SNI 或 Host 还原目标,
  裸 TCP 没有这个信息。要那些请装 Tailscale App,那是对的工具。
- **不自动发现内网设备**。扫描用户网段并自动建映射,既不礼貌也不可靠。
- **不代管 Tailscale 的安装与认证**(与 README 第 12 节同一条口径):那是一次性的系统级操作、
  要交互式认证,而真出事时 Bot 可能就起不来 —— 恰恰是 Tailscale 要救的场景。


## 9. 实现状态与**没有验过的东西**(2026-08-22)

### 已实现

| 部分 | 落点 |
|---|---|
| 门一 路由重叠拒绝 | `deploy/bot/lanroute.py` + `pdg lan routes` + doctor 常驻 |
| 门二 面板表校验 / 反代生成 | `deploy/bot/lanpanel.py`(含五条设备毛病) |
| 门三 出站白名单 | `lanpanel.py render_nft` + unit 的 `ExecStartPre` |
| 风险② DNS token 权限升级 | `pdg lan status` 每次都会说, 不只写在第 7 节 |
| CLI | `pdg lan status/list/check/routes/add/rm/cert/enable/disable/render/wire/purge` |
| 反代与证书 | Caddy 官方原版(钉版本+SHA256) + acme.sh(钉 commit) |
| 手机侧接线 | mosdns `lan_hijack.txt` 挂进 `explicit_proxy`; mihomo `hosts:` + 面板规则 |
| doctor | 路由重叠 / 白名单漂移 / 证书剩余 / ACL 越界探测(--deep) |
| 卸载 | `pdg lan purge` 与 `uninstall.sh` 两条路, 残留逐条报出来 |

### 已在沙盒真机上验过的

- 全新安装 → `pdg lan add/rm` 走事务 → 快照回滚能把面板表还原;
- 反代真跑起来: 以 `pdg-lan` 身份、只监听 `127.0.0.1:443`、TLS 握手成功、SNI 路由生效;
- **门三的决定性验证**: 同一请求、同一份 Caddyfile、同一个上游, 只改白名单 ——
  含该上游时 caddy 报 `connection refused`(放行了), 不含时报 `no route to host`(被拒);
- **规则顺序的正负控**(两个容器走真 nft REDIRECT): 面板规则在 REJECT 之前 → HTTP 200;
  在之后 → HTTP 000 `match IPCIDR(127.0.0.0/8) using REJECT`;
- `wire` 之后三份派生物同时正确: mosdns 劫持集、mihomo `hosts:` 段、面板规则在 0/1 位。

### **没有验过的**(别当成验过了)

- **手机真的打开了面板** —— 整条链路端到端。这要真实的 tailnet 子网路由 + 真实设备,
  沙盒造不出来。上面验的全是"产物正确", 不是"链路通"。
- **ACL 越界探测**打在真 tailnet 上的表现。判据的三种读法有单元测试覆盖(连上/被拒/
  不可达), 但没在真 ACL 上跑过。
- **acme.sh 的真实签发**。容器里签不了 `.example.com`, 证书全是自签顶替的。
  证书装到位之后 Caddy 能读、能握手 —— 这一段验过; 签发本身没有。
- **续期**。acme.sh 装的 cron 是否真的把证书续上, 没有跨越 60 天验证过。
  doctor 的证书项就是为这条不确定性存在的。

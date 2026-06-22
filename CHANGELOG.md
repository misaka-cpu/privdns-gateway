# 更新日志

本项目无正式版本号,按日期记录主要变化;完整提交见 git 历史。

## 2026-06-21 — bot 分流/出口编辑

- **分流管理 → ✏️ 改出口**:选一条已有规则(域名组或规则集)直接改到别的出口,不用删了重加(同出口域名自动合并保持整洁)。
- **出口管理 → ↕️ 出口排序**:发一行新顺序即可重排出口列表。
- **出口管理 → ✏️ 改故障组**:选故障组→发新成员(空格分隔、按顺序),原地改、列表位置不变;`🔀 故障切换组` 改名为 `🔀 新建故障组`。
- **分流管理 → ✏️ 改规则集名**:给规则集起看得懂的显示名(如「币安」「OpenAI」),分流规则列表不再只显示 `rs_xxxx`;加规则集时也可在末尾直接带名称(`URL 出口 名称`)。加规则集提示改为「后缀 .list / .txt / .srs」。
- bot 发消息 HTML 解析失败时退回纯文本重试,避免出错信息(如 sing-box 报错含 `<`、`&`)导致消息+按钮静默丢失。
- **删规则改多选**:列出现有单域名(显示 `域名 → 出口`),勾选多个 → 点「✅ 确认删除(N)」**一次性删、只重启一次 sing-box**;留「✍️ 手动输入」兜底。
- **修复**:连续快速改配置(如连点删域名)会在 10 秒内多次 `restart sing-box`,撞上 systemd start-limit 把 sing-box 锁成 failed(配置本身没问题)。`apply_sb` 现在 restart 前先 `reset-failed`,且重启失败自动还原上一份配置重试,不会把代理留在挂掉状态。
- bot `answerCallbackQuery`(停按钮转圈)改后台异步,连点菜单不再每步叠加一个到 Telegram 的来回。

## 2026-06-21 — 工程化收口

不新增代理协议、不改分流语义,只做工程化与安全加固:

- **Token 迁移到 `bot.env`**:TG token / 允许 id 从 systemd unit 移到 `/etc/privdns-gateway/bot.env`(目录 700 / 文件 600),unit 改用 `EnvironmentFile=`。
  `pdg-set-token`、`healthcheck` 同步改读 bot.env;**旧装升级时自动迁移**(把 unit 里的明文 token 搬进 bot.env)。
- **`pdg update` 校验门加强**:更新前快照不变;更新后跑 `py_compile` + `sing-box check` + `nft -c` + `pdg doctor --json`。
  有 `fail` 自动回滚,`warn` 仅提示;未配置 token 时不把「pdg-bot 未运行」误判为失败。
- **新增 `pdg report`**:一条命令生成**脱敏**诊断快照(doctor / 服务 / 日志 / 版本 / 端口 / 证书 / A 记录 / 防火墙),自动隐藏 token、密码、uuid、出口链接,输出文件 600。
- **GitHub Actions CI**:`py_compile` + `bash -n` + JSON 模板渲染校验 + ShellCheck;另加 mobileconfig plist 校验 + `systemd-analyze verify`(best-effort)。纯静态,不启动服务。
- **文档**:README / INSTALL / 排障手册按句换行,便于阅读与 diff。
- **`pdg doctor --deep`**:在常规自检外追加慢速端到端检查(DoT 853 TLS 握手 / `:81` 探测 200 / mosdns 解析 / clash_api);代理劫持仅对内网卡来源生效,本机不可复现,如实标注。
- **`pdg report --redact-ip / --full`**:`--redact-ip` 连公网 IP、内网 CIDR、DoT 域名一并隐藏(贴公开 issue 用);`--full` 不脱敏仅本机看。默认行为与 600 权限不变。
- **bot 主菜单**:「📊 状态」按钮改为「🔄 更新」(检查→确认→后台 `systemd-run` 执行,不被自身重启打断)。
- **并发加锁**:`pdg update / rollback / snapshot` 用 `flock`(`/run/privdns-gateway.lock`)串行化,防 bot 更新按钮与命令行同时操作。
- **内网卡识别增强**:抓包过滤补 CGNAT `100.64.0.0/10`、改抓"打到网关服务的包"(不限 SYN,已连的 DoT 也能抓);新增 **`pdg detect-cidr`**——装完随时从容重测,与现配不符可一键写回 mosdns+nftables 并重启。安装时识别失败的提示改为引导用它。
- **防火墙拒 QUIC**:对内网卡来源的 **UDP/443 改为 `reject`**(原先放行),逼客户端回落 TCP/443(才能被嗅 SNI 分流),也避免 UDP 443 进 sing-box 自环。
- **文档**:QUICKSTART 新增「局限与补丁」节(Speedtest/纯 UDP/直连 IP/Telegram 不走这套及兜底思路);新手图文教程(含示意配图)+ README 顶部入口。

## 2026-06-20 — 首个公开版本

### 网关核心
- **DNS 层 mosdns**:国内直连 / 代理域名 A 记录劫持到本机 + AAAA·HTTPS 置空 / 按来源 IP 分支 / ECS 分治 / 响应缓存;DoT(853)。
- **流量层 sing-box 1.12**:`direct` 监听 + `sniff_override_destination`(不用 tproxy);多出口,urltest 故障切换;clash_api。
- **一键安装** `install.sh`(自动识别公网 IP / 内网卡段,DNS 那步留用户)、`uninstall.sh`。

### 管理
- **`pdg` CLI**:`status` / `doctor` / `update [--dry-run]` / `snapshot` / `rollback` / `token` / `restart` / `log` / `traffic` / `ios` / `uninstall`。
- **Telegram bot**:出口(ss/vmess/trojan/vless)、故障切换组、分流规则、Surge 规则集、🔎测域名、测出口、流量、DNS 上游、TFO、配置备份/恢复、iOS 描述文件下发、自定义 DoT 域名。
  改 sing-box 前 check + 自动回滚。

### 可靠性与运维
- **`pdg doctor`** 只读自检(服务 / sing-box 版本 / DoT A 记录 / dot-domain 一致性 / 内网卡段 / 防火墙 / 证书 / 本机 DNS / sing-box check),支持 `--json`。
- **健康自检告警**:`pdg-health.timer` 每 10 分钟跑,异常 Telegram 私信(仅状态变化)。
- **snapshot / rollback**:整机配置 + 防火墙 + service 快照到 `/var/lib/privdns-gateway/backups`(留最近 10 份);
  `pdg update` 更新前自动快照、失败自动回滚。
- **配置备份/恢复机器感知**:跨机导入只搬出口/分流/规则集,本机 IP/证书路径/内网卡段保留。
- **证书** Let's Encrypt 自动续期(已处理续期时 80 口被 sing-box 占用的问题);**vnstat** 网卡流量统计。

### 安全
- nftables 暴露面收敛:对全网仅 SSH;`53/80/81/443/853` 仅放行内网卡来源段。

> ⚠️ sing-box 必须 1.12.x:1.13+ 移除了 `sniff_override_destination`,本网关会失效。详见 [docs/INSTALL.md](docs/INSTALL.md)。

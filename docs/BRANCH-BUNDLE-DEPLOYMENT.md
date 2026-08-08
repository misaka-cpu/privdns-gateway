# 功能分支的 bundle 部署 SOP

适用于把**没有发布 tag 的功能分支**部署到一台真机上做验收。
正式发布版走 `pdg update`，不适用本文。

> 这份文档是 `tests/test-deploy-order.sh` 第 D 节的判据来源。改动这里的步骤顺序，
> 那支测试会红——它盯的正是"下一个人会不会照着错误顺序做"。

## 为什么顺序要紧

`migrate_deploy_botfiles` 判断"要不要重启服务"，靠的是**它自己安装前后**的运行模块目录摘要。
如果在 `pdg __migrate` 之前就先把模块装好，它前后一算完全相同 → 认定"没有变化" →
**一个服务都不重启**，然后返回 0 说一切正常。

结果是一台"盘上是新代码、跑着的是旧代码"的机器：版本号、文件内容看起来全都升级了，
而进程还持着旧模块。这种现场在真机上出现过。

## 步骤

### 1. 从精确目标 commit 生成 bundle

在开发机上对**确定的那个 commit**（不是分支名）打包：

```bash
git bundle create <file>.bundle <commit-sha>
```

### 2. 核对 bundle 的 SHA256

在开发机与目标机各算一次，**比对一致后**再解包。传输过程出错要在这一步暴露，
而不是等到装了一半。

### 3. 解出的 ref 必须精确等于目标 commit

在目标机上从 bundle 取出之后，核对 `git rev-parse` 的结果与第 1 步那个 SHA 逐字符相同。
不一致就停下——不要"看起来差不多"就继续。

### 4. 先把完整仓库内容同步到 REPO_DIR

**整棵树**同步到 `/opt/privdns-gateway`，不是只传几个改动过的文件。
只传部分文件装出来的是一台半新半旧的机器，之后任何排查都不可信。

### 5. 再从该目标 commit 安装 CLI

```bash
install -m755 <REPO_DIR>/deploy/bot/pdg.sh /usr/local/bin/pdg
```

CLI 必须来自同一个 commit，否则接下来跑的迁移是"旧脚本读新仓库"。

### 6. 直接运行 pdg __migrate

```bash
sudo pdg __migrate
```

### 7. 运行模块安装、迁移与服务重启都交给 __migrate

它自己会装模块、跑迁移、并在**模块内容确实变化时**重启相关服务。
不要替它做这些事。

### 8. 不得提前调用 pdg_install_runtime_modules

这是本文最要紧的一条：**不要提前调用 pdg_install_runtime_modules**。
提前装会把第 7 步那个"模块内容是否变化"的判据掏空，该重启的服务不会重启。
（`pdg_install_runtime_modules` 的签名是 `(仓库根, 目标目录, 平台)`，三个参数都要给；
漏掉会 fail-closed 报"运行模块缺失"——那是对的行为。）

### 9. 迁移后核对

- 相关服务确实在跑，且**进程是新起的**（不是只有盘上文件变了）；
- `pdg doctor` 结果与部署前的预期一致；
- 用户数据无损；
- 工作区干净。

### 10. 功能分支没有发布 tag 时，不得用普通 pdg update 冒充部署

`pdg update` 的设计是"只跟随 `v*` 发布 tag"。拿它去部署功能分支，要么装不上，
要么把机器拉回上一个 release —— 等于把要验收的东西全撤掉。

## 一句话记住

**完整 REPO_DIR → CLI → `pdg __migrate`**

# 临时面板加固实施计划

> 设计依据：`docs/superpowers/specs/2026-07-14-panel-hardening-design.md`

## 目标

以最小改动修复面板事务、计时并发、配置归属、备份净化和 UI 完整性问题，并让 Bot/CLI 文案准确反映方案 A 的“临时观测/控制”边界。

## 任务 1：先锁定配置归属与事务失败

**文件：**

- 修改：`tests/test-panel.py`
- 修改：`deploy/bot/pdg-bot.py`

**步骤：**

1. 新增测试：项目默认关闭态可开启；项目管理开启态可关闭；自定义 `clash_api` 的开启和关闭均被拒绝且配置不变。
2. 新增测试：nft 查询、删除、插入或最终核验失败时，开启返回失败并恢复关闭态。
3. 运行 `python3 tests/test-panel.py`，确认新增断言先失败。
4. 增加精确归属判定和有返回值的防火墙操作；让 `set_panel()` 串行执行并在防火墙失败时回滚配置。
5. 再次运行测试，确认本组通过。

## 任务 2：固定并验证 Zashboard

**文件：**

- 修改：`tests/test-panel.py`
- 修改：`deploy/bot/pdg-bot.py`
- 读取：`lib/versions.sh`

**步骤：**

1. 新增测试：版本和 SHA 从版本清单读取；归档 SHA 不符拒绝安装；已安装 UI 内容被替换后触发重装。
2. 运行面板测试并确认失败。
3. 增加版本清单解析、受管 UI 指纹文件、临时目录解压和原子替换。
4. 开启态写入固定的 `external_ui_download_url`，关闭态一并移除。
5. 运行面板测试，确认本组通过。

## 任务 3：修复链接发送与计时状态机

**文件：**

- 修改：`tests/test-panel.py`
- 修改：`deploy/bot/pdg-bot.py`

**步骤：**

1. 新增测试：发送链接失败会立即关闭面板且不报告成功。
2. 新增测试：重新计时删除旧链接；旧代号回调不能关闭新会话；关闭失败保留链接并安排重试。
3. 新增测试：手动关闭失败不预先丢弃计时器/链接；启动清理只对项目管理开启态执行并检查结果。
4. 运行面板测试并确认失败。
5. 增加状态锁、会话代号和统一的成功后清理/失败后重试逻辑；提取可测试的开启回调与启动清理辅助函数。
6. 运行面板测试，确认本组通过。

## 任务 4：净化备份与恢复

**文件：**

- 修改：`tests/test-panel.py`
- 修改：`deploy/bot/pdg-bot.py`

**步骤：**

1. 新增测试：面板开启态生成的备份中仅保留关闭态；恢复旧备份时在校验和落盘前净化。
2. 新增测试：用户自定义 `clash_api` 不被净化。
3. 运行面板测试并确认失败。
4. 增加一个只处理项目管理开启态的纯配置净化函数；备份时用内存内容替代原 sing-box 文件，恢复时复用同一函数。
5. 运行面板测试，确认本组通过。

## 任务 5：校正文案与 CLI 状态

**文件：**

- 修改：`tests/test-maintenance-polish.py`
- 修改：`deploy/bot/pdg-bot.py`
- 修改：`deploy/bot/pdg.sh`
- 修改：`docs/INSTALL.md`
- 修改：`docs/production-notes.md`

**步骤：**

1. 新增静态断言：Bot 明确说明面板能断开连接；CLI 根据 `external_controller` 区分本地与临时开放。
2. 运行 `python3 tests/test-maintenance-polish.py`，确认新增断言先失败。
3. 最小修改文案和状态生成逻辑；安装文档保留默认端口表，并补充临时开放条件。
4. 运行杂项回归和面板回归。

## 任务 6：全量验证与差异复审

**步骤：**

1. 运行 `python3 -m py_compile deploy/bot/*.py tests/*.py`。
2. 运行 CI 中全部 Python 回归测试。
3. 运行 CI 中全部 Shell 回归、`bash -n` 和 ShellCheck。
4. 运行 sing-box/mosdns 功能测试和出站 schema 测试。
5. 运行 `git diff --check`，检查工作树与差异统计。
6. 逐项对照设计成功标准；只提交与本计划直接相关的文件，不推送、不打 tag、不发 release。

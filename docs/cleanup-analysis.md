# 清理影响 AI 分析测试版

在「空间清理」中展开一个类别，点击具体项目右侧的「AI 分析」。窗口先展示将发送的目录摘要，点击「开始分析」才调用本机 Codex。结果解释删除后果、恢复方式、建议及资料来源；不会改变勾选或执行清理。

「设置 → 清理 AI 分析」可指定 Codex 路径、模型和思考强度，默认自动查找 CLI，使用 `gpt-6.1-sol` 和 `medium`。需要本机已安装并登录 Codex；必要时在终端运行 `codex login`。WonderBox 不读取或复制登录凭据。自动查找优先使用 PATH 和常见安装位置；从多套 NVM 安装中选择时，按 Codex 的 npm 安装版本选择最新版，而非 Node 版本。手动指定路径时始终使用该路径。

摘要包含匿名化路径、扫描得到的大小、最多两层目录名称、可能关联的应用及版本。不读取清理目标内的文件内容，也不跟随符号链接。摘要与结果仅保留在当前窗口中，目录名称仍可能包含个人信息，发送前应查看预览。Codex 请求可能消耗订阅额度。

缓存目录可能包含不能重建的数据，例如 JetBrains 的 LocalHistory。分析对应当前实际清理范围：选中父目录会连同所有子目录一起删除，现有清理不会自动保留分析中建议保留的子目录。

## 构建与使用

```sh
PREVIEW=1 ./scripts/package_app.sh
open build/WonderBox-AI-Preview.app
```

测试版使用独立名称及 Bundle ID `com.wondercraft.WonderBox.AIPreview`，设置与正式版分开保存，不覆盖 `/Applications/WonderBox.app`。无需为 AI 分析启用开机启动或特权 helper。

## 验证

```sh
swift test
```

新增测试集中覆盖摘要、真实删除范围、目录深度与符号链接，以及模拟 Codex 的调用参数、结构化结果、失败、取消、超时和缺少搜索事件。

本机只有 Command Line Tools，缺少 XCTest；原生 `swift test` 无法运行。验证时使用构建目录内的临时运行器直接执行测试方法与断言，该工具不进入产品或仓库。真实联网验证仅使用此前批准的 JetBrains 匿名元数据，不执行清理。

2026-09-30 复核：此前联网测试使用了另一份 Codex CLI，不能代表应用实际自动找到的 CLI。原生应用选中了 NVM v25 环境中的 Codex 0.156.1，该版本使用 ChatGPT 登录时拒绝 `gpt-6.1-sol`；用户命令行使用的是 NVM v22 环境中的 Codex 0.159.2。已在原生应用中复现错误，并修正多套 NVM 下的自动选择逻辑，保留原模型与思考强度。此前关于实际应用可正常使用的验证结论不完整。

当前 Codex 的搜索依赖 `code_mode_host`，保留该默认能力，关闭 shell、插件与 hooks 等无关能力。

修复后验证：42 个测试方法的断言通过（使用上述临时运行器，非原生 XCTest），发布构建与签名校验通过。直接启动独立测试版，设置中的自动查找结果为 `~/.nvm/versions/node/v22.22.0/bin/codex`（0.159.2）；运行中的子进程路径、`gpt-6.1-sol` 和 `model_reasoning_effort=medium` 均已核对。

在原生界面点击 JetBrains 项目的「开始分析」，成功显示「已使用网页搜索」、整目录删除及 LocalHistory 丢失的影响，并展示 JetBrains 官方目录、Local History、Invalidate Caches 三个来源链接。再点击「重新分析 → 取消」，等待状态结束，「开始分析」按钮恢复，相关 Codex 分析子进程为零。全过程未执行清理，未改动勾选。

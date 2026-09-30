# 清理影响 AI 分析测试版

在「空间清理」中展开一个类别，点击具体项目右侧的「AI 分析」。窗口先展示将发送的目录摘要，点击「开始分析」才调用本机 Codex。结果解释删除后果、恢复方式、建议及资料来源；不会改变勾选或执行清理。

「设置 → 清理 AI 分析」可指定 Codex 路径、模型和思考强度，默认自动查找 CLI，使用 `gpt-6.1-sol` 和 `medium`。需要本机已安装并登录 Codex；必要时在终端运行 `codex login`。WonderBox 不读取或复制登录凭据。

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

2026-09-30 验证：41 个测试方法的断言通过，发布构建成功；`gpt-6.1-sol / medium` 成功执行网页搜索并打开 JetBrains 官方目录、Local History 和 Invalidate Caches 文档。当前 Codex 的搜索依赖 `code_mode_host`，保留该默认能力，关闭 shell、插件与 hooks 等无关能力。

# 参与 QingType 项目

感谢你愿意为清言输入法贡献时间。无论是报告问题、改进文档、提出想法，还是提交代码，都很欢迎。

## 反馈问题前

1. 确认使用的是哪个 QingType 版本，以及 macOS 版本。
2. 搜索现有 [Issues](https://github.com/0D00-0721-0/qingyan-shurufa/issues)，避免重复提交。
3. 使用仓库中的 Bug 反馈模板，尽量提供稳定、可重复的复现步骤。
4. 提交日志、截图或诊断摘要前，先检查并删除个人信息。

请勿在公开 Issue 中发布真实输入内容、个人词库、模型文件、密码、访问令牌或未经检查的完整日志。

## 提出功能建议

请使用 [功能建议模板](https://github.com/0D00-0721-0/qingyan-shurufa/issues/new?template=feature_request.yml)。优先说明：
- 当前遇到的实际问题；
- 受影响的使用场景；
- 期望的行为；
- 是否有可行的替代方案。

## 本机开发环境

当前项目面向 Apple Silicon Mac，最低目标系统为 macOS 14。需要 Swift 工具链和 macOS SDK，可使用 Xcode 或 Command Line Tools。

```sh
git clone https://github.com/0D00-0721-0/qingyan-shurufa.git
cd qingtype
./scripts/build-dev.sh
./scripts/test.sh
./scripts/package-app.sh
```

构建脚本会根据仓库中的锁定文件获取并校验固定版本的运行库。请勿提交构建产物、个人配置、模型、词库或本机诊断数据。

## 提交代码

1. Fork 仓库并从 `main` 创建功能分支。
2. 尽量围绕一个明确问题进行小范围修改。
3. 修改后运行 `./scripts/build-dev.sh` 和 `./scripts/test.sh`；涉及安装包时再运行 `./scripts/package-app.sh`。
4. 在 Pull Request 中说明问题背景、修改内容、验证方式，以及尚未覆盖的场景。
5. UI 变化建议附上不含个人信息的截图。

请不要在未经讨论的情况下大规模重构输入引擎、修改第三方依赖版本或改变用户数据格式。涉及数据迁移、安装、更新、卸载和词库行为的修改，应特别说明兼容性与回滚策略。

## 代码与许可证

提交代码前请确认你有权贡献相关内容。项目主代码采用 GPL-3.0；第三方依赖和资源可能采用不同许可证，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。提交 Pull Request 即表示你同意在项目适用许可证下发布你的贡献。

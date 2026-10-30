# Phase 0：稳定基线

本文件保留 Phase 0 的历史基线。当前 0.6.0 状态以 PROGRESS.md、VALIDATION.md 与 docs/DEPENDENCIES.md 为准：默认运行库已脱离本机鼠须管，自动学习和 QQ 搜索框有新验收证据。

起点：QingType 0.2.2，提交 `57e3ead`。开始此阶段时 Git 工作区干净。

| 项目 | 已记录版本/来源 |
| --- | --- |
| Xcode | 27.1，27A9275 |
| Swift | Apple Swift 6.4，swiftlang-6.4.0.34.1 |
| 本机系统 | macOS 27.0.1，26A434；Apple Silicon arm64 |
| Squirrel 基础 | 1.1.2，`876adebaf2f612951dcdca8a591de65401222b9a` |
| librime 头文件 | 1.16.0，`a251145d3aafa33871824a40bbec04c966bd8b56` |
| Yams | 5.0.6，Package.resolved 固定提交 |
| 模型 | 用户导入的独立 .gram；本地基线记录语言、SHA-256、大小和简繁类型，不复制模型或词条内容 |

可重复生成包含实际运行库版本及二进制 SHA-256 的本机记录：

```sh
./scripts/build-dev.sh
./scripts/test.sh > build/baseline-tests.log 2>&1
python3 scripts/capture-baseline.py
```

报告保存在被 Git 忽略的 `build/baseline.json`。检查运行库实际版本，不以头文件版本代替运行时版本。

| 验收项 | 证据/状态 |
| --- | --- |
| 从源码构建开发版、签名与包结构 | 本机脚本通过；已有 GitHub 干净 runner 构建通过 |
| 原有内部检查 | 61 项：9 设置保护 + 13 导入/迁移 + 19 引擎 + 17 候选交互 + 3 缓存保护 |
| 拼音、候选、空格上屏 | 用户此前用真实键盘确认 nihao→你好；引擎亦有独立测试 |
| Safari 切换 | 用户确认完整退出并重新打开 Safari 后恢复；不是由 TIS selected=true 推断 |
| QQ 输入 | 曾出现旧输入源缓存崩溃，修复已安装；长期/完整输入流程仍待用户验证 |
| 多屏、缩放、全屏、休眠、长时间输入 | 尚未系统验证，不能因静态窗口测试通过标记完成 |
| 自动学习行为与恢复 | 未完整验证，Phase 2 |
| 个人词库编辑、文本导入导出、部署回滚 | Phase 1 实施与新增测试范围 |

## 安装、卸载与配置恢复

- `scripts/install-dev.sh` 等待旧输入服务退出、备份应用 ZIP、复制新包、备份输入源缓存并刷新注册。更新连接配置后，正在运行的浏览器可能需要 ⌘Q 重开。
- `scripts/uninstall-dev.sh` 停用并退出清言，将应用移入废纸篓。代码审查确认它不删除 `~/Library/QingType`；本阶段不为验证而卸载用户正在使用的输入法。
- 配置保存先校验、保护手工配置，再将上一版受管理文件复制到 `~/Library/QingType/backups/<UUID>/`。写文件失败时恢复先前内容。
- 手工恢复前先退出输入服务；将同一份备份中的受管理配置作为整体恢复，再从设置重新部署。不要覆盖或删除任何 `.userdb` 学习数据。Phase 1 会将部署失败后的恢复纳入同一个应用事务。
- 导入的词库和模型使用独立命名空间的副本；原始 `~/Library/Rime` 不作为可写目标。

依赖授权说明在 THIRD_PARTY.md。当前开发版复用上游发行运行库、采用临时签名；尚未具备正式发行所需的完整二进制授权清单、Developer ID 或公证。干净 CI 已存在，但默认本机构建仍从鼠须管取运行时，Phase 3 尚未完成。

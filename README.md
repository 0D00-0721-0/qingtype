# 清言输入法 · QingType

基于 Rime 与鼠须管的开源 macOS 输入法。目标是用 Mac 原生界面完成日常输入、
自定义词库添加及万象等本地语言模型管理。当前为 **0.3.1 开发原型**，GPL-3.0。

## 使用

打开已安装输入法内的“清言设置”，在系统输入菜单选择清言。
也可以使用系统的输入源切换快捷键。
0.2.1 包含 QQ 切换输入源时崩溃的缓存修复与候选展开重写。
0.2.2 更正输入法连接命名并避免重复服务争用端点；用户已确认完整重启 Safari 后可以切换。
更新涉及连接配置时，请用 ⌘Q 完整退出并重新打开浏览器。

- **输入**：全拼简体、全拼繁体、小鹤双拼简体；候选数量、Shift 切换及试打。
- **雾凇拼音**：在「输入」页下载官方完整方案，或从完整方案文件夹导入；
  安装后选择雾凇并保存应用。保留个人词库、快捷短语和简体语言模型。
  [安装与数据保护](docs/RIME_ICE.md)。
- **外观**：单行、右侧箭头与展开网格使用同一个非激活 AppKit 窗口；
  支持横排／竖排与字号。展开态按原生参考调整为小编号、对齐的文字、浅灰背景，
  按用户要求不显示底部工具栏。右上角箭头或 Esc 可收起。
- **个人词库**：词语、拼音、词频的新增、编辑、删除、搜索、排序和重复校验；
  CSV／TSV／TXT 预检、错误行报告、冲突策略及导出。点击“保存并应用”后编译生效。
  [使用格式与验收](docs/PERSONAL_DICTIONARY.md)。
- **导入词库**：导入 `.dict.yaml`，支持同一文件夹内通过 `import_tables` 引用的依赖。
  选中要启用的词库，再点“保存并应用”。
- **语言模型**：导入 Rime `.gram`，或从已有 Rime 数据目录复制万象模型。
  选择模型后“保存并应用”，界面会显示实际的编译与模型加载结果。
- **快捷短语**：编辑字母编码和短语；独立于固定词库与语言模型。

清言数据位于 `~/Library/QingType`。模型、词库均复制到清言自己的目录，源文件不作修改。
用户导入的词库、模型和学习数据不随源代码上传。

## 数据管理

导入词库时检查依赖、循环与越界路径，将所有数据文件归入独立命名空间。
生成的主词库直接列出所有依赖表，适配 Rime 不递归展开 `import_tables` 的行为。
词库入口支持 Rime 数据词库，不导入任意 `.schema.yaml`、Lua 插件包或搜狗 `.scel`。
雾凇完整方案由独立的方案安装入口检查依赖、哈希和资源路径。
词库编码需要与拼音方案兼容；万象整套方案不等同于单独的 `.gram` 模型。

模型按文件头、索引范围和 SHA-256 校验。启用时生成当前方案的 `grammar/language`
与拼音索引配置。部署检查同时读取 Rime 日志和插件标准错误输出，确认模型被引擎加载。
加载成功不代表已证明整句准确率提高；效果仍需在实际语料中比较。

设置应用管理 `settings.json`、`default.custom.yaml`、`squirrel.custom.yaml`、
`custom_phrase.txt`、`qingtype_main.dict.yaml`、`qingtype_personal.dict.yaml` 和各支持方案的 `.custom.yaml`；
安装雾凇时另生成 `qingtype_ice_main.dict.yaml`，方案资源有独立清单及备份。
保存前验证所有内容并备份上一份配置；手动维护的同名文件不会直接覆盖。
部署失败时恢复旧配置并验证恢复后的编译；恢复失败或检测到并发手工修改时，保留备份并明确报告。
删除固定个人词条不会删除 Rime 学习记录，已学过的同名词仍可能出现在候选中。
固定词库和模型的导入记录存于设置中，Rime 学习词频仍由用户词库数据库管理。

## 本机开发

```sh
./scripts/build-dev.sh
./scripts/test.sh
open "build/QingType.app/Contents/Applications/QingType Settings.app"
```

构建使用 `swiftc`、macOS SDK 和固定版本的 Yams。默认从
`~/Library/Input Methods/Squirrel.app` 复制本机 Rime 运行库、插件和基础方案；
可设置 `QINGTYPE_RUNTIME_APP` 指向另一份鼠须管。
需要 macOS SDK 和 Swift 工具链，可使用 Xcode 或 Command Line Tools。
输出为 `build/QingType.app`，内含原生 SwiftUI 设置应用。

```sh
./scripts/install-dev.sh
./scripts/uninstall-dev.sh
```

安装到 `~/Library/Input Methods/QingType.app`。卸载脚本将程序移到废纸篓，保留用户数据。
更新前的程序备份保存为 ZIP，避免备份内的同名 app 被系统重复注册。
安装器会备份并移走系统输入源缓存，再刷新注册，处理沙盒应用仍使用旧输入源表的问题。
只处理 `com.apple.IntlDataCache.le` / `.le.kbdx`，备份在本地 `build/install-backups/`。

## 验证与后续

项目长期目标见 [AGENTS.md](AGENTS.md)，阶段验收见 [ROADMAP.md](ROADMAP.md)，当前交接进度见 [PROGRESS.md](PROGRESS.md)，基线见 [BASELINE.md](BASELINE.md)。

详见 `VALIDATION.md`。目前已验证个人词库 CRUD 与文本导入导出、词库导入、全拼／双拼挂载、模型实际加载、
数据保护和设置迁移。用户已确认基本真实键盘输入。

仍需完成浏览器、微信、Word、VS Code、终端、多显示器和长时间使用测试，
继续打磨候选窗与苹果拼音的交互差异，并完成词库移除／导出、在线更新、
独立可复现的 Rime 依赖构建以及正式发行签名与公证。

当前产物采用本地临时签名，未配置公开发行与更新流程。上游工程和工作流保留供参考；
开发请使用当前 `scripts/` 脚本。来源见 `THIRD_PARTY.md`，原始说明见 `README.upstream.md`。

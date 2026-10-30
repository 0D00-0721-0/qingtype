# Caps Lock 切换保留拼音验收

日期：2026-10-30。维护者报告键盘左侧中/英（Caps Lock）键会丢弃未上屏的 `nihao`，期望切到英文时原样上屏。

## 原因与修复

- 生成的默认配置只覆盖 Shift，继承了上游 `Caps_Lock: clear`。新增 `commit_code` 策略，Shift 设置保持原值。
- 单独更改策略后，真实引擎探针仍复现光标位于中间时只提交前缀：`nihao` 只得到 `ni`。Caps Lock 进入英文且有效策略为 commit_code 时，先将组合光标移到输入末尾，再交给原有 Rime 事件处理及上屏路径。
- 策略读取遵循 Rime 的方案优先、默认后备规则；不改变其他按键、释放事件、返回中文或显式手工方案的切换策略。候选窗口呈现、词库、学习和排序逻辑未改。

实现文件为 `shared/QingTypeSettings.swift`、`sources/QingTypeInputModeSwitch.swift` 和控制器的一处调用。新增引擎用例在 `sources/QingTypeInputModeDiagnostics.swift`，由已有工厂/雾凇引擎诊断调用；配置策略由 `tests/SettingsSafetyTests.swift` 覆盖。

## 自动化结果

- 先加入回归用例，旧配置实际失败于 Caps Lock 未提交原始字母；修复前日志为私有忽略文件 `build/caps-lock-before-test.log`。
- 基础方案及关闭 Shift 的完整雾凇各 21 项真实引擎检查通过，包含普通/退格编辑/中间光标/分隔符、空输入、Esc 取消、切回中文、无重复提交及策略边界；另有两种 Shift 偏好的配置检查。
- 标准 arm64 构建、必需雾凇夹具完整回归通过：275 条 PASS 输出，无 FAIL/SKIP；原候选 73 项、学习 65 项等继续通过。
- 从干净 `df11bfa526fe6b02a216d987da77c5b2c20c2c75` 重建后，严格来源/签名结构/挂载 DMG 及包内 39 项工厂引擎检查通过。
- 同一提交的 [CI 41061319357](https://github.com/0D00-0721-0/qingyan-shurufa/actions/runs/41061319357) 在 macOS 14/15/26 Apple Silicon 构建、完整回归及严格包检查全部通过。

## 本机安装与数据

固定包版本为 0.6.5，DMG SHA-256 为 `4547a27b87fd9c885888f5c41b9bb0106f02eb2e8bcf5162cda166f998fd6f58`，只读参考位于忽略的 `build/caps-lock-reference/`。

正常设置应用与输入服务已通过现有程序事务更新，并通过现有配置应用事务重新生成和部署配置。当前 default.custom.yaml 及已编译 default.yaml 均为 commit_code；原 Shift 关闭、模型、输入方案等设置值未改。输入服务以正常后台方式启动并选中清言简体。八份版本/BuildInfo、完整内容和运行映像均与固定包一致。

更新前的 1,248 个文件/链接已离线复制并逐项核验，旧程序 ZIP 和事务收据保留在私有 `build/caps-lock-live-backup/`。应用配置后，66 项模型/雾凇/词库/设置等文件摘要与原副本一致，三个学习数据库目录保留；部署和运行后有数据库元数据更新及文件轮换，不据此声称学习库逐字节不变。未执行个人数据恢复、重置或清除，原始用户数据不提交。

真人测试前后 artifactId 均为 `f72ff3d339019a4d703ee6392200dbca9185ff00080619cede5da9bb279feeb9`，snapshotId 分别为 `e89e1b7cdd8990f1567cf12b229d0a3473e1d2504eb752fa24b086205245594b`、`0faa6d3846f1200f4cd3f9b12bb88a1d794e57591772d4a798f25f5c03379898`。完整包内容及运行实例相同，测试后仍选中清言简体。快照的 inputAcceptanceVerified=false 保持原义：工具只证明程序与运行来源，真人结论独立记录。

## 真人范围

**PASS / 有限真人结果 F**：macOS 27.0.1，Codex 26.1027.30824 (22943) 消息框。用户按指定步骤输入 nihao 并看到候选，不选词、不按空格，按 Caps Lock 后原样上屏 nihao；切回中文再输入 nihao 并空格上屏，明确回复“nihao 原样上屏，切回中文也正常”。该结果与前后同包/同运行实例快照绑定。

只覆盖上述动作，不扩大为整个应用通过。其他应用、实际中间光标、复杂已确认组合、长按 Caps Lock、大写及其他输入源往返仍未验；中间光标的完整拼音保护目前仅有真实引擎自动化证据。

本轮未创建新 Release、移动版本标签或更改候选窗口行为。

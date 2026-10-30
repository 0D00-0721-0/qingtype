# 向上展开动画补漏验收

日期：2026-10-29。用户在 Codex 底部消息框报告候选向上展开没有过渡，截图显示展开窗口位于输入位置上方。首版 `1a4a5df` 的 TextEdit 短输入通过结果不覆盖这个路径。

## 原因与修改

| 文件 | 修改与原因 |
| --- | --- |
| `sources/QingTypeExpandedCandidates.swift` | 旧 `sameSide` 条件在折叠行位于下方、展开必须翻到上方时禁止动画。移除该限制，显式展开/收起均从当前窗口尺寸过渡到目标。记录上方定位，仅在候选数据、输入位置和显示设置相同且窗口可见时复用，防止收起及相同刷新把短胶囊重新放到下方。 |
| `sources/QingTypeDiagnostics.swift` | 原有即时翻转断言按用户要求改为检测向上动画；另补上方终点、中间尺寸、收起锚点、相同刷新、再次展开、快速反向退出、初始位于上方及减少动态效果。候选检查从 66 项增加到 73 项，其余既有断言保留。 |
| `PROGRESS.md`、`VALIDATION.md`、`docs/COMPATIBILITY.md`、本文及首版动画记录 | 分开记录首版已有结果与本次截图路径的证据。 |

先只加入回归用例，旧代码按预期失败于 `expanding across the lower screen edge starts an upward transition from the visible capsule`；再修改实现，该用例及完整候选专项通过。旧测试曾明确要求翻转立即定位，这是上一版的行为选择，不能证明用户现在要求的向上过渡已经完成。

保留约 180 ms 展开、140 ms 收起的 ease-out，字形不缩放，窗口仍不获取键盘焦点。普通键入、输入位置或应用变化立即更新，减少动态效果仍禁用动画；不改候选内容、词库、学习、模型、排序、编号和自然宽度规则。目标窗口仍受可见屏幕边界限制。

## 固定安装包

- 干净提交：`6de81c09a808e0212b57222eba16c0bdc22ee13f`，arm64 / macOS 14+，版本仍为 0.6.5。
- 只读 DMG：本机忽略目录 `build/candidate-upward-reference/QingType-0.6.5-arm64.dmg`。
- SHA-256：`c6542593f379359af9ae658a81ab5b720acf9a19544a01c026bd1a9070d600b0`。
- artifactId：`e13a5353e8f2f7062a4e44618a5875f867ddc13cc1a987d2aef6835e703497a8`。
- 核对清言选中后的真人输入前 snapshotId：`7ede5f56edd47f2825a8e5d8420a470db3b0e8c745e9aad3230c0a1264785857`，私有路径 `build/candidate-upward-snapshots/before-input-qingtype.json`。更早安装后快照另存为 `before-input.json`，不用于替代这次选源确认。
- 纠正输入源后的真人输入后 snapshotId：`7d6817cddeb04ff3a99cb4292e20e2cd9f7f147fdd292f3b6c6baf7548bccc33`，私有路径 `build/candidate-upward-snapshots/after-input-qingtype.json`。前后 artifactId、DMG、构建记录、完整程序内容及运行 PID/启动标识/UUID 全部相同，清言简体在前后查询中均启用并选中。
- 输入服务 PID 66595，映像 UUID `fe764723df8937a6b17c381d17eecdf0`，启动标识 `5083556776657`。

使用现有程序事务及 `scripts/install-dev.sh` 统一正常应用和输入服务，正常后台启动。八份版本/BuildInfo、完整程序内容及运行映像与上述固定包核对通过。安装前、后清言简体均保持启用；最初系统当前为自带拼音。首次反馈未见过渡后，用户提供带系统拼音工具栏的截图并说明搞错；只读查询也确认当时为 `com.apple.inputmethod.SCIM.ITABC`，不能据此判定清言的过渡或间距。随后实际查询已核对为 `org.qingtype.inputmethod.QingType.Hans`，启用、选中均为 true，并重新生成复验前快照。没有根据系统拼音的截图修改清言间距。

旧输入服务 ZIP 校验通过，正常应用事务 ZIP 和离线数据副本均保留在私有忽略目录 `build/candidate-upward-live-backup/`。安装后、启动服务前的 1,248 个用户文件/链接与离线副本逐项一致：新增 0、删除 0、改动 0。没有恢复、清除或重置真实数据；后续正常输入的学习变化不包含在此检查点结论内。

## 测试结果及边界

- **PASS**：本机标准构建；候选 73 项；必需雾凇夹具完整回归 232 条 PASS 输出，无 FAIL/SKIP。
- **PASS**：从干净提交重建后，候选 73 项再次通过；严格来源、版本、签名结构、完整 DMG 内容和 18 项离线工厂引擎检查通过。
- **PASS**：安装检查点的数据保留、固定包内容及运行身份核对。
- **PASS / 远端 CI**：[40900147446](https://github.com/0D00-0721-0/qingtype/actions/runs/40900147446) 的完整提交 `6de81c09a808e0212b57222eba16c0bdc22ee13f`，macOS 14/15/26 Apple Silicon 构建、完整回归、严格来源及 DMG 检查全部通过；与实际安装的产品提交相同。后续仅补验收文档。
- **PASS / 真人有限结果 E**：核对实际选中清言后，用户在原 Codex 底部消息框展开/收起各两次并空格上屏，明确回复“现在都正常”。宿主版本为 26.1023.51421 (22530)，macOS 27.0.1。该结果与上述前后快照绑定，不沿用系统拼音或 TextEdit 的 D 结果，不记录具体候选或草稿内容。快照的 `inputAcceptanceVerified=false` 仍表示工具没有替代真人输入，真人确认独立记录于本项。

内部窗口动画检查在离屏窗口执行，证明控制与几何路径，不能代替实际显示器、宿主组合输入和视觉感受。本次真人结果仅覆盖指定 Codex 控件的向上展开/收起与空格上屏，不扩展为长句、数字/鼠标选词、光标、中英切换或整个应用通过。原生动画仍未完成动态测量，不声称时长或曲线精确一致。真实多屏、缩放、全屏、其他应用及长时间使用继续待验。

本机忽略日志 `build/candidate-upward-{before-build,before-tests,build,tests,full-tests,clean-build,clean-tests,package,distribution,before-upgrade,installed-check,corrected-before,corrected-after}.log` 保存预期失败、修复及安装证据；原始快照、用户数据和备份不提交。源码已同步 main，本轮不创建 Release、不移动 tag、不覆盖公开资产，不重新开启长期观测。

# 候选展开与收起动画验收

日期：2026-10-29。用户在收到独立预览窗口的正常速度实录后，同意采用这版动画。范围仅为现有候选窗口的呈现，保留 Rime、候选内容与排序、自然宽度、数字映射和现有 UI。

本文记录首版 `1a4a5df` 的验收。之后用户指出底部消息框向上展开没有过渡，该路径已另行修复并记录于 [向上展开补漏验收](CANDIDATE_UPWARD_ANIMATION_VALIDATION.md)，不把下方首版 TextEdit 结果扩大到该路径。

## 修改文件、原因与实现

| 文件 | 原问题与修改 |
| --- | --- |
| `sources/QingTypeExpandedCandidates.swift` | 原先直接改变窗口尺寸，并在展开/收起时替换整个背景及内容。现在保留背景和可复用首行按钮，使用 AppKit 非阻塞窗口动画；下方候选由裁切逐步显露，字形不缩放，箭头和圆角同步过渡。 |
| `sources/QingTypeCandidatePresenter.swift` | 仅显式展开/收起启动动画；首次出现、输入更新、位置改变立即更新。重复展开不重启动画，可注入“减少动态效果”查询供测试。 |
| `sources/QingTypeDiagnostics.swift` | 保留原 53 项候选测试，增加 13 项真实 AppKit 离屏动画与中断检查；现有预览入口可用 `--keep-open` 保持显示。 |
| `PROGRESS.md`、`VALIDATION.md`、`docs/COMPATIBILITY.md`、本文 | 记录试版采用、固定包安装、自动化结果及真人/CI 验收范围。 |

展开约 180 ms、收起约 140 ms，使用 ease-out；普通键入不排队等待动画。反向操作从当前窗口尺寸继续，隐藏时取消，旧完成回调不能移除新会话内容。跨越输入位置的屏边翻转及系统“减少动态效果”立即定位。候选窗仍不获取键盘焦点。

上述参数为试调值。系统拼音的自动按键只产生字母，未触发原生候选动画，不能声称已测量或精确复刻 Apple 的曲线、时长和全部动态行为。

## 固定安装包与运行身份

- 产品提交：`1a4a5dfad78241e9becedc2db22870afc5f76d0f`，干净构建，arm64 / macOS 14+，版本仍为 0.6.5。
- 固定 DMG：本机忽略目录 `build/animation-1a4a5df/reference/QingType-0.6.5-arm64.dmg`，参考文件只读。
- DMG SHA-256：`7b52ea1570709fb6db3725742b63ac464316e97a664cab38bed01905a49ab88e`。
- artifactId：`0bb29cf9776f84dd28fbcd981f59ae262a32371478e81444afac58f98918629a`。
- 安装后快照：`6f68f13e79c70aed2caad1a8677c0c3ca27bc7a414f34a7d2dcd8b24c3e7e03c`，本机私有路径 `build/animation-1a4a5df/snapshots/before-input.json`。
- 真人输入后快照：`09f4b1d5d976e00696150415fc6508a83e10d54e5c001bcffdbcc6771a23d13f`，本机私有路径 `build/animation-1a4a5df/snapshots/after-input.json`。前后 artifactId、DMG、构建记录、完整内容及运行 PID/启动标识/UUID 全部相同。
- 输入服务 PID 63637，映像 UUID `cda5c019d96e303a9be2454a8a38538d`，启动标识 `5050284558015`。

已用现有程序更新事务和 `scripts/install-dev.sh` 统一正常应用、内嵌载荷、实际输入服务及内嵌设置；八份版本/BuildInfo、两个完整 bundle 的内容与参考 DMG 一致，运行映像与磁盘文件一致。正常后台启动服务，没有启动另一个设置界面或留下预览进程。

安装前校验旧固定包及运行身份，保存旧输入服务 ZIP、正常应用事务 ZIP 和离线数据副本；ZIP 校验通过。安装后、启动服务前，全部 1,247 个用户文件/链接与离线副本逐项一致：新增 0、删除 0、改动 0。没有重置、恢复或清除真实用户数据。该检查点不限制后续正常输入学习引起的数据变化。备份仅保留在私有忽略目录 `build/animation-live-backup-1a4a5df/`。

## 测试结果

- **PASS**：本机 arm64 标准构建，干净来源为上述提交；候选 66 项再次通过。
- **PASS**：相同产品代码在试版阶段执行必需雾凇夹具完整 `scripts/test.sh`，225 条 PASS 输出，无 FAIL/SKIP；原有测试保留。
- **PASS**：严格来源、版本、签名结构、完整 DMG 内容及 18 项离线工厂引擎检查；不将临时签名称为 Apple 公证。
- **PASS**：安装及固定包快照核对；当前清言简体注册、启用并选中。
- **PASS / 远端 CI**：[40896020237](https://github.com/0D00-0721-0/qingtype/actions/runs/40896020237) 的完整提交 `1a4a5dfad78241e9becedc2db22870afc5f76d0f`，macOS 14/15/26 Apple Silicon 构建、完整回归、严格来源与 DMG 检查全部通过；与实际安装的产品提交相同。后续仅补验收文档。
- **PASS / 真人有限范围 D**：用户在 TextEdit 1.21 (419)、macOS 27.0.1 新空白文稿执行 `ni`、展开/收起各两次、空格上屏后，明确回复“动画和上屏都正常”。不记录具体词条或文稿内容；不扩大为长句、数字/鼠标选词、光标、中英切换、其他应用或原生动画精确一致。快照中 `inputAcceptanceVerified=false` 仍表示工具没有替代真人输入，该确认单独绑定于此。

本机日志为忽略的 `build/candidate-animation-{build,tests,full-tests,clean-build,clean-tests,package,distribution,installed-check,after-input}.log`；预览实录为 `build/candidate-animation-trial.mp4`。原始快照、备份和用户数据不提交。

## 验收边界

真实多屏、缩放、全屏、跨应用动画及长时间使用仍待验。本轮不改词库、模型、排序和输入偏好，不重新开启已取消的长期观测。源码已同步 main；未创建新 Release、移动 tag 或覆盖公开资产。后续测试继续按固定 DMG、构建、应用及具体控件记录，不能沿用旧包的真人通过结论。

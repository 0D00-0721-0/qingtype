# 引导式卸载与回归验收 — 2026-10-29

本轮保留现有架构和用户数据，按已确认的引导式卸载方案验收。环境为 Apple Silicon、macOS 27.0.1、Xcode 27.1 / Swift 6.4。本记录区分真实系统操作、隔离故障注入和仍未验证的输入体验。

## 修改与原因

| 文件 | 原问题与新行为 |
| --- | --- |
| `shared/QingTypeUninstallPreflight.swift`、`sources/InputSource.swift`、`sources/Main.swift` | 原检查只看子模式，缺失或未知状态可能放行；现在使用版本化只读快照，成功读取完整启用列表后确认父输入源、当前源及模式状态。父源移除后遗留的子模式 enabled 记录不会单独阻塞卸载。 |
| `shared/QingTypeReadOnlyProbe.swift` | 独立查询设置超时和输出上限；先核对命令能力，拒绝旧控制程序、失败退出和异常响应。 |
| `shared/QingTypeGuidedUninstall.swift`、`settings/ProgramMaintenanceService.swift`、`scripts/UninstallDev.swift` | 应用与脚本统一为检查、退出、独占锁、重新检查、移动的顺序；移动/回收失败恢复程序，恢复不完整明确保留位置。默认不动用户数据或其他应用缓存。 |
| `settings/MaintenancePage.swift`、`settings/SettingsApp.swift` | 返回前台和系统输入源变化时刷新维护状态；仅确认移除后显示卸载入口，丢弃过时查询结果。 |
| `settings/InstallationService.swift`、`settings/WelcomePage.swift` | 父源移除而子模式残留 enabled 时不能显示可输入；安装后如仍需添加输入源，明确引导到系统设置。 |
| `tests/GuidedUninstallTests.swift`、`scripts/test.sh` | 测试实际共享生产事务及状态探针；原有卸载测试保留。 |
| `tests/ContentMemoryTests.swift` | 为大文件校验补峰值内存、真实摘要与取消回归，防止曾出现的整模型滞留内存问题复发。 |
| `sources/QingTypeDiagnostics.swift` | 补跨屏、较小屏幕、外部非有限坐标和组合会话切换检查；不改候选布局。 |
| `scripts/bundle_identity.py`、`tests/BuildIdentityTests.py`、`tests/DistributionTests.py`、`.github/workflows/qingtype-release.yml` | 同版本可能混入不同提交或脏构建；三个 bundle 的完整来源必须一致，挂载包来源也须匹配；公开发布要求干净且来自当前发布提交。 |
| `PROGRESS.md`、`VALIDATION.md`、`docs/MAINTENANCE.md`、`docs/QA_CHECKLIST.md`、`docs/COMPATIBILITY.md` | 更新真实证据、先切离再移除的引导及未验证范围。 |

## PASS：本机实际操作

1. **源仍启用时安全拒绝**：新版开发卸载停止于预检，服务 PID、程序和设置摘要保持原值。
2. **系统移除**：先切到 ABC，再在系统设置移除清言；独立新进程确认父输入源不在启用列表、当前为 ABC。简体模式的 enabled 记录仍为 true，当前没有选中清言。直接移除当前清言曾仅切离、重开设置后条目仍在，因此引导明确先切离，最终以重新读取的状态为准。
3. **GUI 默认卸载**：通过完整应用的维护页执行卸载，两个已安装程序均移除、服务退出。停止服务并持有独占锁时做的离线快照，共 1,153 个用户文件/链接；卸载后全部保留、内容一致，新增 0、改动 0。程序回收文件夹和程序 ZIP 均保留，未清空废纸篓。
4. **GUI 重新安装**：从正常应用实际点击安装，完成复制与部署；如实提示添加输入源，随后通过系统设置重新添加。个人词库、模型与设置保留；数据库重新打开时仅出现 LevelDB 日志/清单变化。在隔离副本上导出并比较，三个学习数据库共 678 条逻辑记录及权重一致。没有恢复、重置或清除真实学习记录。
5. **维护页双向自动刷新**：维护页保持打开，系统移除源后卸载入口出现，重新添加后入口自动隐藏；没有点「重新检查」或切换清言页面。
6. **最终安装一致**：正常应用、输入服务、内置载荷和内嵌设置均为干净 `c97c026` / 0.6.5，四份 BuildInfo 相同，已安装可执行文件摘要与检查过的包相同；输入源已添加且服务运行。核心卸载实测为 `13258c7`，安装可用状态实测含 `786fcc9`，通知刷新实测为 `6262c5b`；最终提交额外完善切到 ABC 的提示，没有把最终版本再次卸载一遍。

## PASS：自动化与包检查

- 本机完整 `scripts/test.sh` 使用固定雾凇夹具及 `QINGTYPE_REQUIRE_RIME_ICE_TEST=1`，190 条 PASS 输出，无 FAIL/SKIP。输出条数不是独立断言总数；其中卸载专项 82 项、候选位置/交互 36 项、学习行为 65 项。
- 卸载专项覆盖有效/未知/矛盾输入源状态、父子记录差异、旧控制程序、无效 JSON、非零退出、超时、超量输出、退出失败、锁失败、移动前状态变化、服务重启、移动/回收/部分回收失败及文件恢复。使用临时目录和假用户数据，没有对真实程序注入故障。
- 256 MiB 合成文件 SHA-256 与独立期望值一致；单独进程的峰值 RSS 增量约 2.8 MiB，低于 64 MiB 上限；开始前取消、读取期间取消和后续正常校验通过。这是单次回归指标，不是长期内存保证。
- 构建来源负例覆盖同版本不同提交、不同 clean 标志和架构，原有测试保留。
- 最终 `c97c026` 干净 arm64 构建、签名结构、DMG 打包与挂载检查通过；`DistributionTests.py` 包含 18 项离线工厂引擎检查。发行目录通过 `QINGTYPE_DISTRIBUTION_DIR` 明确指定，严格模式要求来源提交等于 checkout。

本机复现入口：

```sh
./scripts/build-dev.sh
QINGTYPE_REQUIRE_RIME_ICE_TEST=1 \
QINGTYPE_RIME_ICE_TEST_PACKAGE="$PWD/build/rime-ice-fixture" ./scripts/test.sh
./scripts/package-app.sh
QINGTYPE_REQUIRE_CLEAN_BUILD=1 python3 tests/DistributionTests.py
```

运行严格包检查前必须提交或还原工作区变化，并从该干净提交重新构建。使用其他输出目录时设置 `QINGTYPE_DISTRIBUTION_DIR`，不能仅传位置参数。测试夹具必须为工作流中固定的雾凇提交。

本地证据位于被忽略的 `build/`：`guided-ready-test.log`、`guided-installed-build.log`、`guided-installed-package.log`、`guided-installed-distribution.log`，以及私有 `guided-live-backup/` 中的文件清单比较、逻辑记录比较和最终安装身份摘要。个人快照、词条、学习导出、模型及绝对用户路径不提交或上传。

## 未验证与限制

- **真人输入待验**：最终安装后，TextEdit 的 Computer Use 按键只得到字母，未观察到组合输入；无法据此区分事件注入限制和产品问题。用户当时不方便测试，因此候选框及中文上屏没有记录为通过，也没有据此新建兼容性缺陷。
- **真实故障注入未做**：复制、停止、移动、废纸篓和恢复失败由隔离测试覆盖；没有在当前真实用户目录制造损坏、断电或删除数据。
- **数据删除未做**：「删除清言用户数据」仍为独立操作，本轮未对真实数据执行该入口。
- **跨应用和持续运行待验**：不将卸载/重装通过扩展为 Phase 7 整体通过。多屏、全屏、休眠及长期运行依旧按兼容性矩阵逐项记录。
- **独立 VM 未就绪**：官方虚拟化示例已构建，恢复镜像下载遇到 DNS 失败；没有虚拟机验收结果。本次成功路径是在当前 Mac 备份后执行。
- **GitHub / PASS**：本轮源码已推送 main，[CI 40846479704](https://github.com/0D00-0721-0/qingtype/actions/runs/40846479704) 在 `57ed25a` 的 macOS 14/15/26 Apple Silicon 构建、完整测试、DMG 打包与挂载检查全部成功。随后仅更新验收文档；已安装 `c97c026` 与被 CI 检查的 `57ed25a` 之间只有文档差异。既有 `v0.6.5-preview.1` 资产不包含本轮修复，不移动标签或覆盖旧资产。

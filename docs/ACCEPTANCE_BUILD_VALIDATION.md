# 稳定性建议第 5 项：固定同来源发行包验收

日期：2026-10-29；范围为 GitHub / arm64 DMG 的构建一致性、实际安装与记录绑定。保留现有 UI 和输入架构。

## 修改文件与原因

| 文件 | 原问题与新行为 |
| --- | --- |
| `scripts/acceptance_build.py` | BuildInfo 相同不能证明完整内容相同。哈希路径、类型、权限、链接和文件内容，拒绝缺失/残留/篡改/越界链接及检查中的变化；核对八份来源和版本、复核运行身份。 |
| `scripts/verify-acceptance-build.py` | 一次性只读核对 DMG 摘要、挂载内容、已安装程序及运行映像 UUID，生成不可覆盖的私有快照，不启动后台观测。 |
| `tests/AcceptanceBuildTests.py` | 14 项反例与正常路径，覆盖相同版本/BuildInfo 下内容不同、旧文件、权限、链接、混入来源、签名/查询失败、进程改变、无效 UUID、旧包混入、卸载镜像重试、并发修改和快照保护。 |
| `tests/DistributionTests.py`、`scripts/test.sh` | 保留原测试；DMG 与未挂载应用增加完整内容比对，输出目录只允许本次一个 DMG。共用原有 EBUSY 重试，不强制卸载磁盘。 |
| `.github/workflows/qingtype-ci.yml` | 普通 CI 的可下载产物也要求干净来源且提交等于 checkout，与既有 Release 严格检查一致。 |
| `docs/COMPATIBILITY_TEST_TEMPLATE.md`、`docs/COMPATIBILITY.md` | 真人记录绑定 artifactId、前后快照、DMG 摘要、实际构建和具体应用/控件，只填写已确认的步骤。 |
| `PROGRESS.md`、`VALIDATION.md`、本文 | 记录包、安装、数据保留和真人确认的范围。 |

## 固定基线

从干净提交 `24cf60ac1fc6cbdd76ec9047832ee04ee7e0e552` 构建，版本来自该提交的 `VERSION`：**0.6.5**。本机为 Apple Silicon、macOS 27.0.1、Xcode 27.1 / Swift 6.4。

- DMG：`QingType-0.6.5-arm64.dmg`
- SHA-256：`cd66a7b2b58762a51a258766513bcea47e203d573608f29495a51ffe38f75c88`
- artifactId：`7d4a118c29bc9d0e755a8f9913005e958f1e2e707d56eac5f5c13958d0a58e14`
- 只读参考包：本机忽略目录 `build/acceptance-24cf60a/reference/`。DMG 和校验文件另存并设为只读，后续构建使用其他目录。

artifactId 包含 DMG 摘要、完整 BuildInfo 摘要、应用/输入服务内容摘要、版本与提交。同一提交重新构建的另一份包，也须另建记录，不能只凭版本/提交相同沿用真人结果。

## PASS：实际一致性与安装

1. **先识别混用**：原本机程序为干净 `05c1bd5`，旧构建目录为干净 `48f8f2e`，都显示 0.6.5；命令拒绝混用，未生成通过快照。
2. **识别旧产物**：旧 `build/acceptance-distribution/` 同时残留 0.6.2 和 0.6.5 DMG，被新检查拒绝。旧包保留，改用按提交命名的新目录。
3. **统一安装**：用户确认测试通过后可更新；使用现有程序事务及 `scripts/install-dev.sh` 更新正常应用和输入服务，保留旧程序 ZIP 及数据离线快照。
4. **数据保留**：安装检查点的 1,247 个文件/链接全部保留，新增 0、删除 0；词库、学习库、模型和设置内容不变。仅 `user.yaml` 的 `last_build_time` 与模型状态的 `observedAt` 更新时间，已逐项确认。没有恢复、重置或清除真实数据；检查点在真人输入之前，正常学习后文件可能变化。
5. **八份记录一致**：参考 DMG 的主应用/载荷/内嵌设置、正常安装应用的对应三份、实际输入服务及内嵌设置，版本和完整 BuildInfo 均一致。两个已安装根 bundle 的完整内容与参考包对应根一致。
6. **运行映像**：服务 PID 56136，UUID `d9933c4322763ee78a0b912acd4848bb`；加载映像与磁盘文件一致，检查前后启动标识相同。原简体选择已恢复。该检查本身不证明能输入。

## PASS：同一包下的有限真人结果 C

用户按指定步骤确认：**TextEdit 1.21 / 419，新建空白文稿正文，选择清言后输入 `nihao`，候选显示并以空格中文上屏正常**。未记录具体词条或文稿内容。

- 输入前 snapshotId：`ef68b57bbc4017996e4a5b063407fb844867f7e74825678ff347abf57e6c6d7f`
- 输入后 snapshotId：`6937ad4a17d3bef22c78e294f000897dc2e51867a2deee86e3401075d3a3eeea`
- 两份快照的 artifactId、DMG 摘要、构建记录、完整内容和运行 PID/启动标识/UUID 均相同。
- 私有快照位于 `build/acceptance-24cf60a/snapshots/before-input.json` 和 `after-input.json`，权限 0600，不提交原始报告。

不扩大为组合标记细节、展开/长候选、数字/鼠标选词、光标、切换或其他应用已通过。快照中 `inputAcceptanceVerified=false` 表示工具没有做真人输入；用户确认单独绑定在本段。

## PASS：自动化与包检查

- 14 项新增验收单测和原构建来源单测通过。
- 标准干净 arm64 构建、必需雾凇夹具完整回归通过：212 条 PASS 输出，无 FAIL/SKIP；原候选、学习、个人词库及其他测试保留。
- 固定包版本、来源、签名结构、完整内容、DMG 挂载及 18 项离线工厂引擎检查通过。签名结构检查不将临时签名称为 Apple 公证。
- [远端 CI 40889155593](https://github.com/0D00-0721-0/qingtype/actions/runs/40889155593)：完整提交 `14b8029a3a0f6a7a89a5c06ac28d9e86fdc31f61` 的 macOS 14/15/26 Apple Silicon 构建、完整回归、严格来源及 DMG 检查全部通过。相对实际安装的 `24cf60a`，仅增加验收文档与普通 CI 的干净来源门禁，没有修改产品代码；CI 包仍须按自身摘要另建真人验收记录。

本机证据为忽略的 `build/acceptance-clean-build.log`、`acceptance-package.log`、`acceptance-distribution.log`、`acceptance-full-test.log`、`acceptance-before-upgrade-confirmation.log`、`acceptance-snapshot-before.log` 和 `acceptance-snapshot-after.log`。程序与个人数据备份仅保留在私有 `build/acceptance-live-backup/`。

## 后续每次怎样记录

从干净固定提交构建，在新目录打包并运行 `DistributionTests.py`。保留选定 DMG 和校验文件，把该包的正常应用和输入服务统一安装；不要混入另一份本地构建。测试前后各运行一次只读命令，输出使用新文件名：

```sh
mkdir -p build/acceptance-snapshots
python3 scripts/verify-acceptance-build.py \
  --dmg <选定DMG> --expected-commit <该包完整40位提交> \
  --pid <确认的服务PID> --output build/acceptance-snapshots/before.json
# 执行已记录应用、版本和控件的真人步骤。
python3 scripts/verify-acceptance-build.py \
  --dmg <同一DMG> --expected-commit <同一完整提交> \
  --pid <同一服务PID> --output build/acceptance-snapshots/after.json
```

默认检查 `~/Applications/清言.app` 和用户级输入服务；若正常应用位于 `/Applications`，显式传 `--installed-app /Applications/清言.app`。VERSION 从固定提交读取，后续仅改文档不必把旧记录换成当前 HEAD。快照只代表检查时点，前后仍须核对 artifactId 和运行身份，不是持续监控。

检查失败就停止该次验收，不产生新通过快照或覆盖旧快照。修复安装/选择正确产物后重做，不把混装直接归为某个 App 的兼容性故障。按 [真实应用模板](COMPATIBILITY_TEST_TEMPLATE.md) 填写实际操作和剩余项。

本轮未创建 Release、移动标签或覆盖旧资产。以后发布新 tag，须针对实际下载的那个包重新生成快照；本地基线通过不等于公开资产已完成安装验收。

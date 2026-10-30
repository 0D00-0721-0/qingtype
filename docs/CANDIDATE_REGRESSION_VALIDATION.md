# 稳定性建议第 3 项：候选回归

日期：2026-10-29。范围是现有 AppKit 候选窗口的回归测试及测试发现的旧回调问题；没有进入 App Store 实验，没有更换候选系统、调整外观或改动词库排序。

## 修改文件与原因

| 文件 | 修改 |
| --- | --- |
| `sources/QingTypeCandidatePresenter.swift` | 隐藏/退出会话后，窗口残留按钮仍可能触发选择回调。提交前核对候选仍属于当前会话；为确定性屏幕测试传递可选的可见区域查询。默认查询行为不变。 |
| `sources/QingTypeExpandedCandidates.swift` | 列表替换后，新词可能复用旧词的绝对编号。旧按钮的选择/悬停回调现在核对按钮对象仍属于当前渲染列表，不能仅按编号判断。屏幕查询可注入测试区域，默认仍读取实际 NSScreen。 |
| `sources/QingTypeDiagnostics.swift` | 在原有 36 项候选检查之外增加 17 项；使用真实 AppKit 按钮、窗口及离屏绘制，不向其他应用发送按键或鼠标事件。 |
| `PROGRESS.md`、`VALIDATION.md`、`docs/COMPATIBILITY.md`、本文 | 记录来源、确实执行的结果和仍待真人/实际显示设备验收的边界。 |

## 先复现，再修复

1. 保留旧按钮，展开后调用与控制器退出会话相同的 `hide()`，再触发旧按钮：修复前失败，旧候选仍被回调提交。
2. 加入会话检查后，更换候选文字但复用绝对编号，再触发旧按钮：第二个用例仍失败。只检查编号不足以证明按钮属于当前列表。
3. 加入当前按钮对象检查后，旧选择和旧悬停不再影响新列表；新按钮仍可正常选择。

这些是进程内的回归复现，没有证据表明用户此前一定遇到过同一个事件时序问题。

## 新增覆盖

- 会话结束后的旧选择回调；复用编号的新列表与旧按钮；旧悬停事件；当前按钮的正常选择。
- 候选减少和重排后清除已不存在的选中项；展开及收起后的数字键映射；不可见编号不落入引擎；引擎高亮变化后的空格选择；空列表结束交互。
- 两个应用会话的 presenter 独立维护展开和回调，旧会话不能向新会话提交候选。该项模拟控制器已执行会话退出清理，不是实际跨应用输入验收。
- 1×/2×离屏绘制确实产生候选内容，逻辑尺寸及选择不变；显示模式减少逻辑可见区域后重新定位；移动到较小、带负纵坐标和小数边界的显示区域；保持同一窗口、选中项和首行编号，候选不与展开箭头重叠。
- AppKit 会把实际窗口对齐到 backing 像素，实际窗口边界检查允许一个设备像素的取整误差；纯几何布局的已有精确断言保留。

参考小麦 CandidateKit 的现有测试方法，未引入其 UI 或实现代码：

- [CandidateReconfigurationTests](https://github.com/openvanilla/McBopomofo/blob/18e2060dd5d0b511753ad79a8fe0d112e944f1af/Packages/CandidateKit/Tests/CandidateKitTests/CandidateReconfigurationTests.swift)：重配置后的标签/编号映射、候选替换的最终选择、窗口重定位及设备像素误差。
- [CandidateInteractionTests](https://github.com/openvanilla/McBopomofo/blob/18e2060dd5d0b511753ad79a8fe0d112e944f1af/Packages/CandidateKit/Tests/CandidateKitTests/CandidateInteractionTests.swift)：状态过渡时拦截候选动作。
- [CandidatePlacementTests](https://github.com/openvanilla/McBopomofo/blob/18e2060dd5d0b511753ad79a8fe0d112e944f1af/Packages/CandidateKit/Tests/CandidateKitTests/CandidatePlacementTests.swift)：显示器选择、边缘约束及展开位置。

## 测试及构建记录

本机环境为 Apple Silicon、macOS 27.0.1、Xcode 27.1 / Swift 6.4；arm64、最低 macOS 14。原有候选及引擎测试均保留。

```sh
./scripts/build-dev.sh
build/QingType.app/Contents/MacOS/QingType --candidate-ui-test
QINGTYPE_REQUIRE_RIME_ICE_TEST=1 \
QINGTYPE_RIME_ICE_TEST_PACKAGE="$PWD/build/rime-ice-fixture" ./scripts/test.sh
```

**PASS**：本机标准构建及固定雾凇夹具完整回归通过，207 条 PASS 输出，无 FAIL/SKIP；候选专项 53 项（原有 36 + 新增 17），原有 65 项学习行为及其他测试保留。产品修改提交 `67cff01`。

**PASS**：随后从干净 `05c1bd5` 重新构建并打包，严格发行包来源、挂载 DMG、签名结构及 18 项离线工厂引擎检查通过；包内候选专项 53 项通过。本机正常应用、输入服务、内置载荷及内嵌设置四份 BuildInfo 一致，两个已安装可执行文件摘要与检查过的包一致。

**PASS**：停服务并取得数据独占锁后备份；完成程序替换、服务重新启动之前，个人目录的 1,247 个文件/链接与离线快照逐项一致，新增/删除/改动均为 0。没有恢复、重置或清除真实数据。旧输入服务 ZIP 和旧正常应用事务 ZIP 均保留；随后后台启动服务，独立查询确认父源启用、简体选中且当前为清言。该状态不是中文上屏证据。

**PASS / 远端 CI**：已推送，`05c1bd5` 的运行 [40850109938](https://github.com/0D00-0721-0/qingtype/actions/runs/40850109938) 在 macOS 14/15/26 Apple Silicon 全部完成构建、完整回归及 DMG 检查。随后只补文档，不改变已安装产品代码，不覆盖既有预览 Release。

本机日志在忽略的 `build/`：`candidate-transitions-before-test.log`、`candidate-transitions-hidden-test.log` 保存修复前的两次预期失败；`candidate-transitions-build.log`、`candidate-transitions-full-test.log` 保存当前构建和回归。`candidate-clean-*` 保存干净构建、包及包内专项结果；私有 `candidate-live-backup/` 保存程序备份、数据快照比较和最终安装身份摘要，不上传个人文件。

## 未验证事项

- 没有操作真实显示器缩放/热插拔、跨显示器拖动或全屏切换。注入屏幕区域和离屏像素比例只能覆盖内部几何及绘制。
- 没有在多个实际应用中完成组合输入、展开、切换、再输入的真人闭环。最新版真人候选与中文上屏继续待验，用户此前表示暂不方便测试。
- 没有将内部回归通过扩大为 Phase 7 全部通过。本轮不继续第 4 项的长期内存观测，也不重新执行已通过的真实卸载。

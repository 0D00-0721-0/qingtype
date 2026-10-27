# 固定依赖与来源

默认构建无需安装鼠须管。首次执行 `scripts/build-dev.sh` 会获取官方发行包，
校验大小与 SHA-256，解包到忽略目录 `build/runtime/1.1.2`，不会运行安装器。
缓存每次还会核对 `dependencies/runtime-files.lock.json` 中 181 个资源/运行库文件，
出现缺失、增添或内容变化时重新从固定包解出。

| 组成 | 固定来源 | 许可/用途 |
| --- | --- | --- |
| Squirrel 前端基础 | 1.1.2，876adebaf2f612951dcdca8a591de65401222b9a | GPL-3.0，清言保留上游历史 |
| 运行库与基础方案包 | 官方 Squirrel-1.1.2.pkg，SHA-256 614746013212937623d5bbab9901e9c43d1ec937aa32307d6b6092a05e308287 | 精确字节来源见 runtime.lock.json |
| librime API 头文件 | a251145d3aafa33871824a40bbec04c966bd8b56；运行 API 返回 1.16.0 | BSD-3-Clause |
| librime-lua | 上游 1.16.0 SDK 记录 68f9c364a2d25a04c7d4794981d7c796b05ab627 | BSD-3-Clause；包内 Lua 字符串为 5.4.6，MIT |
| librime-octagram | SDK 记录 dfcc15115788c828d9dd7b4bff68067d3ce2ffb8 | GPL-3.0；本地语言模型支持 |
| librime-predict | SDK 记录 920bd41ebf6f9bf6855d14fbe80212e54e749791 | BSD-3-Clause |
| Yams | 5.0.6，0d9ee7ea8c4ebd4a489ad7a73d5c6cad55d6fed3 | MIT，包含 libyaml |
| 小鹤方案 | 01a13287cbd27819be1c34fa1ddc1b3643d5001b | BSD，清言简体方案在其基础上扩展 |

上游运行库还使用 glog、LevelDB、yaml-cpp、marisa、OpenCC、Boost、Darts-clone、utf8cpp、
X11 keysyms。固定来源与许可文件 SHA-256 记录于 `dependencies/components.lock.json`。
构建会核对并向正常应用、输入服务及设置程序复制 16 份许可文本；GPL、librime 与小鹤原许可一并保留。
googletest 等仅用于上游构建的测试库不作为本应用的运行时依赖。

## 证据的界限

Squirrel 1.1.2 的 action-install.sh 指向 Rime 1.16.0/a251145；对应 SDK 的
version-info.txt 记录上述插件 revision。这些是上游配方来源，不证明 PKG 和 SDK 二进制完全相同。
本次实际比较 Mach-O UUID 不同，PKG 中 Lua 为 5.4.6，而 SDK 为 5.4.8，故清言没有
以 SDK 替换已验证的运行库，也没有把这些 revision 写成经过字节证明的 PKG 插件版本。
运行库的确定性依赖于固定 PKG 和逐文件哈希。完整源码到二进制的重建溯源仍是后续审计事项。

## 构建环境

macOS 14+，Xcode 或含合适 macOS SDK/Swift 的 Command Line Tools，Git、Python 3。
执行 `git submodule update --init --depth 1 librime` 获取固定 API；Yams 由 SwiftPM 依据
Package.resolved 获取。不需要将上游 Squirrel、Sparkle 或用户词库安装到本机。

```sh
./scripts/build-dev.sh
./scripts/test.sh
./scripts/package-app.sh
python3 tests/DistributionTests.py
```

默认按宿主处理器编译，运行库为 universal；CI 在多个 macOS 与 Intel runner 构建和测试。
Intel 的 CI 不等于真人 Intel Mac 的图形验收。
`QINGTYPE_RUNTIME_APP` 为显式开发覆盖；公共分发检查拒绝含该覆盖的产物。

每份应用 `Contents/Resources/BuildInfo.json` 记录源码提交、工作区是否干净、架构、
Swift/SDK 版本、上游包和运行库哈希，不记录开发者绝对路径。发布工作流拒绝脏源码记录。

## 获取上游源码

本项目源码见 GitHub 对应 tag 与 Release 源码附件。Squirrel 原始基础、librime 及插件源代码
可从 THIRD_PARTY.md 和 components.lock.json 的 repository/revision 固定获取；例如：

```sh
git clone https://github.com/lotem/librime-octagram.git
git -C librime-octagram checkout dfcc15115788c828d9dd7b4bff68067d3ce2ffb8
```

若需要证明 PKG 插件的精确对应源码，应先完成上面的二进制重建溯源，不能把 SDK 配方当作证明。
雾凇/万象为用户主动下载的可选资源，不随基础 DMG 分发；安装时保留上游来源、许可与资源清单。

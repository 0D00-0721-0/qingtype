import AppKit
import SwiftUI

extension SettingsModel {
  func chooseRimeIceFolder() {
    guard !busy, !loadFailed else { return }
    let panel = NSOpenPanel()
    panel.title = "导入完整雾凇方案"
    panel.message = "选择包含 rime_ice.schema.yaml、英文及拆字方案、词典与 Lua 资源的文件夹。"
    panel.prompt = "安装方案"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    installRimeIce(folder: url)
  }

  func installRimeIce(folder: URL? = nil, activate: Bool = false) {
    guard !busy, !loadFailed, inputReady else { return }
    guard !isDirty else { failed = true; message = "请先保存当前更改，再安装雾凇。"; return }
    busy = true; failed = false
    message = folder == nil ? "正在下载并校验雾凇官方完整包…" : "正在校验雾凇完整方案…"
    canCancelDownload = folder == nil; transferProgress = nil
    componentTask = Task {
      defer { busy = false; canCancelDownload = false; transferProgress = nil; componentTask = nil }
      var downloaded: RimeIceDownload?
      defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded.directory) } }
      do {
        if folder == nil {
          downloaded = try await QingTypeRimeIceDownload.official { [self] progress in
            Task { @MainActor in if self.canCancelDownload { self.transferProgress = progress } }
          }
        }
        try Task.checkCancellation()
        canCancelDownload = false; transferProgress = nil
        let root = folder ?? downloaded!.root
        message = "正在安装雾凇依赖并验证当前方案…"
        let result = try await DeploymentService.installRimeIce(from: root, saved: saved,
          provenance: downloaded?.provenance ?? "本地方案文件夹", sha256: downloaded?.sha256, activate: activate)
        // Preserve all other unsaved edits; package installation does not select a schema.
        saved = result.0
        settings = result.0
        deployment = result.1
        message = activate ? "雾凇拼音已安装并启用。" : "雾凇已安装。选择“雾凇拼音”并保存应用即可使用。"
      } catch {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { message = "已取消下载，当前输入设置保持不变。" }
        else { failed = true; message = error.localizedDescription }
      }
    }
  }
}

struct RimeIceSection: View {
  @ObservedObject var model: SettingsModel
  var body: some View {
    Section("雾凇拼音") {
      if let asset = model.settings.rimeIce {
        LabeledContent("已安装方案", value: "雾凇拼音 · \(asset.version)")
        Text("\(asset.source) · \(asset.files.count) 个资源文件")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      } else {
        Text("安装官方完整方案，包含中文词库、英文、拆字反查及 Lua 扩展。")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Button(model.settings.rimeIce == nil ? "下载并安装官方方案" : "检查并安装官方更新") { model.installRimeIce() }
        Button("从方案文件夹导入…", action: model.chooseRimeIceFolder)
        Link("上游项目", destination: URL(string: "https://github.com/iDvel/rime-ice")!)
      }.disabled(model.busy || model.loadFailed || !model.inputReady)
      Text("安装后可在上方选择雾凇拼音；个人词库、快捷短语和已启用的简体语言模型会一同使用。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

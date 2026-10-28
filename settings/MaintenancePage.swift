import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MaintenancePage: View {
  @ObservedObject var model: SettingsModel
  @State private var confirmUpdate = false
  @State private var confirmUninstall = false
  @State private var confirmRemoveData = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      GroupBox("应用更新") {
        VStack(alignment: .leading, spacing: 12) {
          Text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")")
          Toggle("打开清言时检查更新", isOn: Binding(get: { model.maintenance.checkUpdatesOnLaunch }, set: { model.setAutomaticUpdateCheck($0) }))
          Text("从清言 GitHub 仓库检查预览版和正式版。安装前校验文件并备份旧程序，完成后重启清言；不会自动下载。")
            .font(.callout).foregroundStyle(.secondary)
          HStack {
            Button("检查更新", systemImage: "arrow.clockwise") { model.checkAppUpdates() }
            if let update = model.appUpdate {
              Link("发行说明", destination: update.page)
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
              if update.version.compare(current, options: .numeric) == .orderedDescending {
                Button("安装 \(update.version)…") { confirmUpdate = true }.buttonStyle(.borderedProminent)
              }
            }
          }.disabled(model.busy || model.isDirty || model.loadFailed)
          if let message = model.updateSummary { Text(message).font(.callout).foregroundStyle(.secondary) }
          if model.isDirty { Text("请先保存其他更改，再更新或卸载。").font(.caption).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("卸载清言") {
        VStack(alignment: .leading, spacing: 12) {
          Text("卸载输入服务和已安装的清言应用，并退出清言。默认保留个人词库、模型、学习记录及配置，以便以后重新安装。")
            .font(.callout).foregroundStyle(.secondary)
          Text("移除的文件会放在同一个恢复文件夹中，可从废纸篓找回。请先完成当前输入。")
            .font(.caption).foregroundStyle(.secondary)
          if model.inputEnabled {
            Label("请先在系统设置中移除清言输入源", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text("macOS 27 不允许程序可靠地停用输入法父输入源。请在「系统设置 → 键盘 → 文字输入 → 输入源」移除清言；完成后回到这里卸载。")
              .font(.caption).foregroundStyle(.secondary)
            Button("打开键盘设置", action: model.openKeyboardSettings)
              .disabled(model.busy)
          } else {
            Button("卸载清言…", role: .destructive) { confirmUninstall = true }
              .disabled(model.busy || model.isDirty)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("单独删除用户数据") {
        VStack(alignment: .leading, spacing: 12) {
          Text("请先卸载输入法，再从安装包打开清言。此操作会将个人词库、配置、模型、学习记录和本地备份全部移到废纸篓，不会自动清空废纸篓。")
            .font(.callout).foregroundStyle(.secondary)
          Button("删除清言用户数据…", role: .destructive) { confirmRemoveData = true }
            .disabled(model.busy || model.isDirty || model.installedVersion != nil)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("诊断与反馈") {
        VStack(alignment: .leading, spacing: 12) {
          Text("导出版本、输入源状态、屏幕信息及配置统计，便于排查兼容性问题。报告不包含词条、输入内容或学习记录。")
            .font(.callout).foregroundStyle(.secondary)
          Button("导出诊断摘要…", systemImage: "doc.text.magnifyingglass") { model.exportDiagnostics() }.disabled(model.busy)
          Link("问题反馈", destination: URL(string: "https://github.com/0D00-0721-0/qingtype/issues")!)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }
    .disabled(model.busy)
    .onAppear { model.refreshInstallation() }
    .alert("安装更新并重启清言？", isPresented: $confirmUpdate) {
      Button("取消", role: .cancel) {}
      Button("安装并重启") { model.installAppUpdate() }
    } message: { Text("旧程序会先备份。个人词库、模型和学习记录保留；请先完成当前输入。") }
    .alert("卸载清言并退出？", isPresented: $confirmUninstall) {
      Button("取消", role: .cancel) {}
      Button("卸载", role: .destructive) { model.uninstallQingType() }
    } message: {
      Text("程序将移到废纸篓，用户数据保留在 ~/Library/QingType。")
    }
    .alert("删除全部清言用户数据？", isPresented: $confirmRemoveData) {
      Button("取消", role: .cancel) {}
      Button("移到废纸篓", role: .destructive) { model.removeQingTypeUserData() }
    } message: {
      Text("个人词库、模型、配置、学习记录和本地备份都会移到废纸篓。清空废纸篓后无法通过清言恢复。")
    }
  }
}

extension SettingsModel {
  func exportDiagnostics() {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "清言.qingdiagnostics.json"; panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let target = panel.url else { return }
    busy = true; failed = false
    Task {
      defer { busy = false }
      do {
        let app = InstallationService.payload ?? InstallationService.installedURL
        let data = try await InstallationService.command(["--diagnostic-report"], app: app)
        _ = try JSONSerialization.jsonObject(with: data)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        message = "诊断摘要已导出，未包含词条或学习记录。"
      } catch { failed = true; message = error.localizedDescription }
    }
  }
  func setAutomaticUpdateCheck(_ value: Bool) {
    guard !busy else { return }
    maintenance.checkUpdatesOnLaunch = value
    do { try maintenance.save() }
    catch { failed = true; message = error.localizedDescription }
  }

  func checkAppUpdates(automatic: Bool = false) {
    guard !busy else { return }
    if automatic, let last = maintenance.lastChecked, Date().timeIntervalSince(last) < 86400 { return }
    busy = true; failed = false; updateSummary = "正在检查更新…"
    Task {
      defer { busy = false }
      do {
        appUpdate = try await QingTypeAppUpdates.check()
        maintenance.lastChecked = Date(); try maintenance.save()
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if let update = appUpdate {
          let order = update.version.compare(current, options: .numeric)
          updateSummary = order == .orderedDescending ? "可更新到 \(update.version)。" : order == .orderedSame ? "已是当前公开版本。" : "当前版本高于公开发布的 \(update.version)。"
        } else { updateSummary = "暂时没有适合这台 Mac 的安装包。" }
      } catch {
        // Never keep an older candidate around: a failed check must not offer an install.
        appUpdate = nil
        updateSummary = "检查失败：\(error.localizedDescription)"
      }
    }
  }

  func installAppUpdate() {
    guard !busy, !isDirty, !loadFailed, let update = appUpdate else { return }
    busy = true; failed = false; canCancelDownload = true; message = "正在下载新版清言…"
    componentTask = Task {
      defer { busy = false; canCancelDownload = false; transferProgress = nil; componentTask = nil }
      var downloaded: QingTypeDownloadedAsset?
      defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded.directory) } }
      do {
        downloaded = try await QingTypeAppUpdates.download(update) { [self] progress in
          Task { @MainActor in if canCancelDownload { transferProgress = progress } }
        }
        try Task.checkCancellation()
        canCancelDownload = false; transferProgress = nil; message = "正在校验并安装更新…"
        let file = downloaded!
        let receipt = try await Task.detached { try ProgramMaintenanceService.prepareUpdate(file, update: update) }.value
        try await ProgramMaintenanceService.launchUpdated(receipt)
      } catch {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { message = "更新下载已取消。" }
        else { failed = true; message = error.localizedDescription }
      }
    }
  }

  func completePendingAppUpdate() {
    busy = true; failed = false; message = "正在完成清言更新…"
    Task {
      defer { busy = false; refreshInstallation() }
      do {
        deployment = try await ProgramMaintenanceService.finishUpdate()
        settings = try .load(); saved = settings
        message = "清言更新完成，原有设置与学习记录已保留。"
      } catch { failed = true; message = error.localizedDescription }
    }
  }

  func uninstallQingType() {
    guard !busy, !isDirty else { return }
    busy = true; failed = false; message = "正在安全卸载清言…"
    Task {
      do {
        _ = try await ProgramMaintenanceService.uninstall()
        NSApplication.shared.terminate(nil)
      } catch { busy = false; failed = true; message = error.localizedDescription; refreshInstallation() }
    }
  }

  func removeQingTypeUserData() {
    guard !busy, !isDirty else { return }
    busy = true; failed = false; message = "正在移除清言用户数据…"
    Task {
      do {
        _ = try await ProgramMaintenanceService.removeUserData()
        NSApplication.shared.terminate(nil)
      } catch { busy = false; failed = true; message = error.localizedDescription; refreshInstallation() }
    }
  }
}

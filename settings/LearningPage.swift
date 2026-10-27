import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LearningPage: View {
  @ObservedObject var model: SettingsModel
  @State private var confirmation: String?
  @State private var restoreURL: URL?
  private var actionsDisabled: Bool { model.busy || model.isDirty || model.loadFailed }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      GroupBox {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("自动学习选词", isOn: $model.settings.learningEnabled)
          Text("根据选过的词语调整后续候选。更改后请点击“保存并应用”。关闭时不使用或新增学习记录，已有记录保留。")
            .font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("备份与恢复") {
        VStack(alignment: .leading, spacing: 12) {
          Text(model.learningSummary).foregroundStyle(.secondary)
          HStack {
            Button("立即备份", systemImage: "externaldrive.badge.plus") { model.manageLearning("backup") }
            Button("恢复备份…", systemImage: "arrow.counterclockwise") { chooseRestore() }
            Button("导出最近备份…", systemImage: "square.and.arrow.up") { exportLatest() }
              .disabled(model.latestLearningBackup == nil)
          }.disabled(actionsDisabled)
          Button("打开学习备份文件夹", systemImage: "folder") { model.openLearningBackups() }
          Text("恢复时会合并已有记录，并自动保存恢复前的备份。全拼与小鹤共享学习记录，雾凇使用独立记录。")
            .font(.callout).foregroundStyle(.secondary)
          if model.isDirty { Text("请先保存其他设置，再管理学习数据。").font(.callout).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      GroupBox("学习数据与隐私") {
        VStack(alignment: .leading, spacing: 12) {
          Text("学习数据包含选过的词组、拼音编码、使用次数及排序权重，可能含姓名、地址等私人词语。数据保存在本机，清言不会主动上传。备份也包含这些信息，请妥善保管。")
            .font(.callout).foregroundStyle(.secondary)
          HStack {
            Button("重置学习记录…", role: .destructive) { confirmation = "reset" }
            Button("清除记录及本机备份…", role: .destructive) { confirmation = "erase" }
          }.disabled(actionsDisabled)
          Text("重置会保留一份恢复备份。彻底清除会同时删除本地同步快照与清言学习备份；手动导出的副本需自行删除。如不希望继续积累记录，请先关闭自动学习并保存。")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }
    .task { model.refreshLearningSummary() }
    .alert(confirmation == "restore" ? "恢复并合并学习备份？" : confirmation == "reset" ? "重置当前学习记录？" : "清除学习记录及本机备份？",
           isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
      let action = confirmation ?? ""
      Button("取消", role: .cancel) { confirmation = nil }
      Button(action == "restore" ? "恢复并合并" : action == "reset" ? "备份并重置" : "清除", role: action == "erase" ? .destructive : nil) {
        model.manageLearning(action, source: restoreURL); confirmation = nil
      }
    } message: {
      Text(confirmation == "restore" ? "现有学习记录会保留，操作前会自动备份。"
        : confirmation == "reset" ? "清除当前学习记录和本地同步快照，重置前自动备份。个人词库与模型保留。"
        : "删除所有方案的本机学习记录、同步快照及清言学习备份。此操作无法通过清言撤销；手动导出的副本需自行删除。个人词库与模型保留。")
    }
  }

  private func chooseRestore() {
    let panel = NSOpenPanel()
    panel.title = "恢复清言学习备份"; panel.allowedContentTypes = [.data]
    panel.directoryURL = QingTypeLearning.localBackups(in: QingTypePaths.userDirectory)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { _ = try QingTypeLearningBackup.load(url); restoreURL = url; confirmation = "restore" }
    catch { model.failed = true; model.message = error.localizedDescription }
  }

  private func exportLatest() {
    guard let source = model.latestLearningBackup else { return }
    let panel = NSSavePanel()
    panel.title = "导出学习备份"; panel.nameFieldStringValue = "清言学习备份.qinglearning"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try QingTypeLearningBackup.load(source).write(to: url)
      model.failed = false; model.message = "学习备份已导出，包含私人词语，请妥善保管。"
    } catch { model.failed = true; model.message = error.localizedDescription }
  }
}

extension SettingsModel {
  var latestLearningBackup: URL? {
    (try? FileManager.default.contentsOfDirectory(at: QingTypeLearning.localBackups(in: QingTypePaths.userDirectory), includingPropertiesForKeys: [.contentModificationDateKey]))?
      .filter { $0.pathExtension == "qinglearning" }.max {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
          ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
      }
  }

  func refreshLearningSummary() {
    do {
      let count = try QingTypeLearning.databases(in: QingTypePaths.userDirectory).count
      let backups = (try? FileManager.default.contentsOfDirectory(at: QingTypeLearning.localBackups(in: QingTypePaths.userDirectory), includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "qinglearning" }.count ?? 0
      learningSummary = "本机有 \(count) 个学习数据库、\(backups) 份学习备份。"
    } catch { learningSummary = error.localizedDescription }
  }

  func openLearningBackups() {
    do {
      let path = QingTypeLearning.localBackups(in: QingTypePaths.userDirectory)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      NSWorkspace.shared.open(path)
    } catch { failed = true; message = error.localizedDescription }
  }

  func manageLearning(_ action: String, source: URL? = nil) {
    guard !busy, !isDirty, !loadFailed else { return }
    busy = true; failed = false; message = "正在安全管理学习数据…"
    Task {
      defer { busy = false; refreshLearningSummary() }
      do { message = try await LearningService.run(action: action, source: source, saved: saved).message }
      catch { failed = true; message = error.localizedDescription }
    }
  }
}

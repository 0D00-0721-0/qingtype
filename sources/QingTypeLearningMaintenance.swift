import Foundation

enum QingTypeLearningMaintenance {
  static func backup(api: RimeApi_stdbool, directory: URL) throws -> QingTypeLearningBackup {
    let names = try QingTypeLearning.databases(in: directory)
    let workspace = try QingTypeLearning.workspace()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try QingTypeLearning.clone(names, from: directory, to: workspace)
    // Preserve local sync history too: resetting must not discard an unmerged
    // snapshot from another device that was absent from the active database.
    let local = try QingTypeLearning.localSnapshots(in: directory).map { file -> QingTypeLearningSnapshot in
      guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
        throw SettingsError.invalid("本地学习快照超过备份容量限制，未修改原数据。")
      }
      let snapshot = QingTypeLearningSnapshot(name: String(file.lastPathComponent.dropLast(11)), data: try Data(contentsOf: file))
      try snapshot.validate(); return snapshot
    }
    let allNames = Array(Set(names + local.map(\.name))).sorted()
    guard Set(allNames.map { $0.lowercased() }).count == allNames.count else { throw SettingsError.invalid("学习数据库名称存在大小写冲突。") }
    if !local.isEmpty { try QingTypeLearningEngine.restore(api: api, directory: workspace, snapshots: local) }
    let snapshots = allNames.isEmpty ? [] : try QingTypeLearningEngine.snapshots(api: api, directory: workspace, names: allNames)
    let result = QingTypeLearningBackup(rimeVersion: api.get_version().map { String(cString: $0) } ?? "unknown", snapshots: snapshots)
    try result.validate()
    return result
  }

  static func run(api: RimeApi_stdbool, action: String, directory: URL,
                  source: URL? = nil) throws -> QingTypeLearningResult {
    let names = try QingTypeLearning.databases(in: directory)
    switch action {
    case "backup":
      let backup = try self.backup(api: api, directory: directory)
      let path = try QingTypeLearning.makeBackupURL(in: directory)
      try backup.write(to: path)
      return .init(message: "已备份 \(backup.snapshots.count) 个学习数据库及本地同步历史。备份包含私人词语，请妥善保管。", databaseCount: backup.snapshots.count, backupPath: path.path)
    case "restore":
      guard let source else { throw SettingsError.invalid("请选择学习备份。") }
      let backup = try QingTypeLearningBackup.load(source)
      guard !backup.snapshots.isEmpty else { throw SettingsError.invalid("这个备份没有学习记录。") }
      let workspace = try QingTypeLearning.workspace()
      defer { try? FileManager.default.removeItem(at: workspace) }
      // Merge into clones first. A damaged snapshot never touches live records.
      let restoredNames = backup.snapshots.map(\.name)
      try QingTypeLearning.clone(names.filter { restoredNames.contains($0) }, from: directory, to: workspace)
      try QingTypeLearningEngine.restore(api: api, directory: workspace, snapshots: backup.snapshots)
      let safety = try QingTypeLearning.makeBackupURL(in: directory)
      try self.backup(api: api, directory: directory).write(to: safety)
      let targets = names.filter { restoredNames.contains($0) }.map { directory.appendingPathComponent($0 + ".userdb") }
      let replacements = Dictionary(uniqueKeysWithValues: restoredNames.map { ($0, workspace.appendingPathComponent($0 + ".userdb")) })
      try QingTypeLearning.replace(in: directory, targets: targets, replacements: replacements)
      return .init(message: "已恢复并合并 \(restoredNames.count) 个学习数据库，原有记录保留。恢复前备份已保存。", databaseCount: restoredNames.count, backupPath: safety.path)
    case "reset", "erase":
      // All targets are checked before creating a safety copy or moving data.
      let targets = try QingTypeLearning.resetTargets(in: directory, includeBackups: action == "erase")
      var safety: URL?
      if action == "reset" {
        safety = try QingTypeLearning.makeBackupURL(in: directory)
        try self.backup(api: api, directory: directory).write(to: safety!)
      }
      try QingTypeLearning.replace(in: directory, targets: targets)
      return .init(message: action == "reset"
        ? "当前学习记录及本地同步快照已重置。重置前备份已保留，可用于恢复。"
        : "本机学习数据库、本地同步快照及清言学习备份已清除。手动导出的副本需自行删除。",
        databaseCount: names.count, backupPath: safety?.path)
    default: throw SettingsError.invalid("不支持的学习数据操作。")
    }
  }
}

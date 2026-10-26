import Foundation

struct QingTypeApplyError: LocalizedError {
  var reason: String
  var configurationRestored: Bool
  var recoveryVerified: Bool
  var backupDirectory: String
  var recoveryError: String?
  var errorDescription: String? {
    if recoveryVerified { return "应用失败，已恢复上一版配置并重新编译。更改仍保留在编辑界面。原因：\(reason)" }
    return "应用失败。\(configurationRestored ? "配置已恢复，但恢复后的编译未通过" : "配置恢复未完成")，输入服务将保持停止。备份：\(backupDirectory)。原因：\(reason)；\(recoveryError ?? "请检查部署日志。")"
  }
}

// Operates only on the exact generated configuration names. Runtime databases,
// imported assets, and user-learning files are outside this transaction.
enum QingTypeConfigurationApply {
  static func apply(_ settings: QingTypeSettings, to directory: URL,
                    deploy: () async throws -> QingTypeDeploymentReport) async throws -> QingTypeDeploymentReport {
    let attempted = try settings.generatedFiles()
    let manager = FileManager.default
    var previous: [String: Data] = [:]
    for name in attempted.keys {
      let url = directory.appendingPathComponent(name)
      if manager.fileExists(atPath: url.path) { previous[name] = try Data(contentsOf: url) }
    }
    let backup = directory.appendingPathComponent("backups/apply-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: backup, withIntermediateDirectories: true)
    for (name, data) in previous { try data.write(to: backup.appendingPathComponent(name), options: .atomic) }
    let absent = attempted.keys.filter { previous[$0] == nil }.sorted()
    try JSONEncoder().encode(absent).write(to: backup.appendingPathComponent("absent-files.json"), options: .atomic)

    // save() validates all ownership and required files before mutation. If it
    // fails, it restores partial writes itself and no deployment is attempted.
    var saved = false
    do {
      try settings.save(to: directory)
      saved = true
      let report = try await deploy()
      guard report.success else { throw SettingsError.invalid(report.message) }
      return report
    } catch {
      if !saved {
        let unchanged = (try? attempted.keys.allSatisfy { name in
          let url = directory.appendingPathComponent(name)
          let current = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
          return current == previous[name]
        }) ?? false
        if unchanged { throw error }
      }
      let originalError = error.localizedDescription
      var restored = false
      do {
        // Refuse to overwrite an external edit made while the worker ran.
        for (name, data) in attempted {
          let url = directory.appendingPathComponent(name)
          let current = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
          guard current == data || current == previous[name] else {
            throw SettingsError.invalid("\(name) 在部署期间被其他程序修改，已保留该内容。")
          }
        }
        for name in attempted.keys.sorted() {
          let url = directory.appendingPathComponent(name)
          if let data = previous[name] { try data.write(to: url, options: .atomic) }
          else if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        restored = true
        let recovery = try await deploy()
        guard recovery.success else { throw SettingsError.invalid(recovery.message) }
      } catch let recoveryError {
        throw QingTypeApplyError(reason: originalError, configurationRestored: restored, recoveryVerified: false,
                                backupDirectory: backup.path, recoveryError: recoveryError.localizedDescription)
      }
      throw QingTypeApplyError(reason: originalError, configurationRestored: true, recoveryVerified: true,
                              backupDirectory: backup.path)
    }
  }
}

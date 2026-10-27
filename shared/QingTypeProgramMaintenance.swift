import Foundation

enum QingTypeProgramKind {
  case inputService, application
  var bundleID: String { self == .inputService ? QingTypeAppInstallation.bundleID : "org.qingtype.app" }
  var executable: String { self == .inputService ? "QingType" : "QingTypeSettings" }
}

struct QingTypeAppUpdateReceipt: Codable {
  var destination: String
  var archive: String
  var archiveSHA256: String
  var previousVersion: String
  var version: String
  var attempts = 0
}

struct QingTypeUninstallItem {
  var url: URL
  var kind: QingTypeProgramKind?
}

enum QingTypeProgramMaintenance {
  static func version(at app: URL, kind: QingTypeProgramKind) throws -> String {
    guard (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("程序路径包含符号链接，操作已停止。")
    }
    let prefix = app.resolvingSymlinksInPath().path + "/"
    guard app.appendingPathComponent("Contents/Info.plist").resolvingSymlinksInPath().path.hasPrefix(prefix),
          app.appendingPathComponent("Contents/MacOS/" + kind.executable).resolvingSymlinksInPath().path.hasPrefix(prefix) else {
      throw SettingsError.invalid("程序内容指向应用包以外，操作已停止。")
    }
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
    guard info?["CFBundleIdentifier"] as? String == kind.bundleID,
          info?["CFBundleExecutable"] as? String == kind.executable,
          let version = info?["CFBundleShortVersionString"] as? String,
          version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + kind.executable).path) else {
      throw SettingsError.invalid("清言程序身份或版本不正确。")
    }
    return version
  }

  static func run(_ binary: String, _ arguments: [String]) throws {
    let task = Process(); task.executableURL = URL(fileURLWithPath: binary); task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw SettingsError.invalid("程序文件操作失败，请检查权限和可用空间。") }
  }

  static func installApplication(source: URL, destination: URL, backups: URL,
                                 allowDowngrade: Bool = false,
                                 validate: (URL) throws -> Void) throws -> QingTypeAppUpdateReceipt {
    let fm = FileManager.default
    let incoming = try version(at: source, kind: .application)
    try validate(source)
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath(),
          (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("程序更新路径无效。")
    }
    let previousVersion = try version(at: destination, kind: .application)
    try validate(destination)
    guard allowDowngrade || incoming.compare(previousVersion, options: .numeric) != .orderedAscending else {
      throw SettingsError.invalid("安装包比当前清言版本旧，已停止更新。")
    }
    try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let archive = backups.appendingPathComponent("Previous.zip")
    guard !fm.fileExists(atPath: archive.path) else { throw SettingsError.invalid("更新备份已经存在，已停止覆盖。") }
    try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", destination.path, archive.path])
    let archiveSHA256 = try QingTypeContent.digest(of: archive)
    let stage = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-update-\(UUID())")
    let previous = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-previous-\(UUID())")
    defer { try? fm.removeItem(at: stage) }
    try fm.copyItem(at: source, to: stage)
    _ = try version(at: stage, kind: .application); try validate(stage)
    try fm.moveItem(at: destination, to: previous)
    var installed = false
    do {
      try fm.moveItem(at: stage, to: destination); installed = true
      try validate(destination)
    } catch {
      do {
        if installed { try fm.removeItem(at: destination) }
        try fm.moveItem(at: previous, to: destination)
      } catch { throw SettingsError.invalid("程序更新失败且恢复未完成，旧程序保留在 \(previous.path)，备份：\(archive.path)。") }
      throw SettingsError.invalid("程序更新失败，已恢复旧版清言。")
    }
    // A verified archive already exists. Cleanup failure must not turn an
    // installed update into an unrecorded failure without a recovery receipt.
    try? fm.removeItem(at: previous)
    return .init(destination: destination.path, archive: archive.path, archiveSHA256: archiveSHA256, previousVersion: previousVersion, version: incoming)
  }

  static func restoreApplication(_ receipt: QingTypeAppUpdateReceipt, validate: (URL) throws -> Void) throws {
    let archive = URL(fileURLWithPath: receipt.archive)
    guard try QingTypeContent.digest(of: archive) == receipt.archiveSHA256 else { throw SettingsError.invalid("旧版程序备份校验失败。") }
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-app-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: workspace) }
    try run("/usr/bin/ditto", ["-x", "-k", archive.path, workspace.path])
    let apps = try FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)
    guard apps.count == 1, try version(at: apps[0], kind: .application) == receipt.previousVersion else { throw SettingsError.invalid("旧版程序备份身份不匹配。") }
    _ = try installApplication(source: apps[0], destination: URL(fileURLWithPath: receipt.destination),
                               backups: archive.deletingLastPathComponent().appendingPathComponent("failed-version"), allowDowngrade: true, validate: validate)
  }

  // Prepare an owned, recoverable folder. The caller switches/disables input
  // sources and stops the service before entering this transaction. Recycle a
  // single folder only after every move succeeds, so partial failures roll back.
  static func stageUninstall(items: [QingTypeUninstallItem], allowed: [URL], userData: URL,
                             staging: URL, afterMove: () throws -> Void = {}) throws -> URL {
    let fm = FileManager.default
    let allowedPaths = Set(allowed.map { $0.standardizedFileURL.path })
    guard !items.isEmpty, Set(items.map { $0.url.path }).count == items.count,
          items.allSatisfy({ allowedPaths.contains($0.url.standardizedFileURL.path) }),
          !staging.standardizedFileURL.path.hasPrefix(userData.standardizedFileURL.path + "/") else {
      throw SettingsError.invalid("卸载目标不在清言管理范围内。")
    }
    for item in items {
      guard (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SettingsError.invalid("卸载目标包含链接，操作已停止。") }
      if let kind = item.kind { _ = try version(at: item.url, kind: kind) }
      else if item.url.standardizedFileURL != userData.standardizedFileURL { throw SettingsError.invalid("不允许移动其他用户目录。") }
    }
    try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let entries = items.enumerated().map { ["original": $0.element.url.path, "staged": "item-\($0.offset)"] }
    var moved: [(URL, URL)] = []
    do {
      try JSONEncoder().encode(entries).write(to: staging.appendingPathComponent("recovery.json"), options: .atomic)
      let instructions = "清言卸载恢复文件夹\n\n可重新下载安装清言，无需手动恢复旧程序。\n若要找回用户数据，请先退出清言，将下方对应目录移回原位置；如原位置已有文件，请先备份，避免覆盖。\n\n" +
        items.enumerated().map { index, item in
          let label = item.kind == .application ? "清言应用（恢复时保留 .app 后缀）" : item.kind == .inputService ? "输入服务（恢复时保留 .app 后缀）" : "用户数据"
          return "\(label)：item-\(index) → \(item.url.path)\n"
        }.joined()
      try instructions.write(to: staging.appendingPathComponent("恢复说明.txt"), atomically: true, encoding: .utf8)
      for (index, item) in items.enumerated() {
        let target = staging.appendingPathComponent("item-\(index)")
        try fm.moveItem(at: item.url, to: target); moved.append((item.url, target))
        try afterMove()
      }
    } catch {
      do {
        for (original, saved) in moved.reversed() { try fm.moveItem(at: saved, to: original) }
        try fm.removeItem(at: staging)
      } catch { throw SettingsError.invalid("卸载恢复未完成，请保留 \(staging.path) 并按 recovery.json 恢复。") }
      throw SettingsError.invalid("卸载失败，已恢复原程序与用户数据。")
    }
    return staging
  }

  static func undoStagedUninstall(_ staging: URL, allowed: [URL]) throws {
    let fm = FileManager.default
    let entries = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: staging.appendingPathComponent("recovery.json")))
    let paths = Set(allowed.map { $0.standardizedFileURL.path })
    guard Set(entries.compactMap { $0["original"] }).count == entries.count,
          Set(entries.compactMap { $0["staged"] }).count == entries.count else { throw SettingsError.invalid("卸载恢复清单重复，已停止恢复。") }
    for entry in entries {
      guard let original = entry["original"], let staged = entry["staged"], staged.range(of: "^item-[0-9]+$", options: .regularExpression) != nil,
            paths.contains(URL(fileURLWithPath: original).standardizedFileURL.path), !fm.fileExists(atPath: original),
            fm.fileExists(atPath: staging.appendingPathComponent(staged).path),
            (try? staging.appendingPathComponent(staged).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
        throw SettingsError.invalid("卸载恢复清单或目标状态已改变，请保留 \(staging.path)。")
      }
    }
    for entry in entries.reversed() { try fm.moveItem(at: staging.appendingPathComponent(entry["staged"]!), to: URL(fileURLWithPath: entry["original"]!)) }
    try fm.removeItem(at: staging)
  }
}

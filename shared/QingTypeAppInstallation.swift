import Foundation

enum QingTypeAppInstallation {
  static let bundleID = "org.qingtype.inputmethod.QingType"
  static func version(at app: URL) throws -> String {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          info["CFBundleIdentifier"] as? String == bundleID,
          info["CFBundleExecutable"] as? String == "QingType",
          let version = info["CFBundleShortVersionString"] as? String,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/QingType").path) else {
      throw SettingsError.invalid("输入法程序不完整，请重新下载清言安装包。")
    }
    return version
  }

  // Configuration and learning data live elsewhere and are not copied here.
  // Staging/rollback directories have no .app extension, avoiding duplicate TIS registration.
  static func install(source: URL, destination: URL, backups: URL,
                      activate: () async throws -> Void) async throws {
    let manager = FileManager.default
    let sourceVersion = try version(at: source)
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath(),
          (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
          (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("输入法安装目标包含链接或与来源相同，已停止安装。")
    }
    let existed = manager.fileExists(atPath: destination.path)
    if existed {
      let currentVersion = try version(at: destination)
      guard sourceVersion.compare(currentVersion, options: .numeric) != .orderedAscending else {
        throw SettingsError.invalid("已安装的输入法比此安装包更新，请使用新版清言应用。")
      }
    }
    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stage = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-stage-\(UUID())")
    let previous = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-previous-\(UUID())")
    defer { try? manager.removeItem(at: stage) }
    try manager.copyItem(at: source, to: stage)
    _ = try version(at: stage)
    if existed {
      try manager.createDirectory(at: backups, withIntermediateDirectories: true)
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      task.arguments = ["-c", "-k", "--keepParent", destination.path, backups.appendingPathComponent("QingType.zip").path]
      task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
      try task.run(); task.waitUntilExit()
      guard task.terminationStatus == 0 else { throw SettingsError.invalid("无法备份旧输入法，请检查可用空间后重试。") }
      try manager.moveItem(at: destination, to: previous)
    }
    var moved = false
    do {
      try manager.moveItem(at: stage, to: destination); moved = true
      try await activate()
    } catch {
      do {
        if moved { try manager.removeItem(at: destination) }
        if existed { try manager.moveItem(at: previous, to: destination) }
      } catch let recovery {
        throw SettingsError.invalid("安装失败且程序恢复未完成。旧程序：\(previous.path)，备份：\(backups.path)。\(recovery.localizedDescription)")
      }
      throw error
    }
    if existed { try? manager.removeItem(at: previous) }
  }
}

enum QingTypeInputCache {
  static let names: Set<String> = ["com.apple.IntlDataCache.le", "com.apple.IntlDataCache.le.kbdx"]
  static func backUp(root: URL, to backup: URL) throws -> Int {
    let manager = FileManager.default
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let backup = backup.resolvingSymlinksInPath().standardizedFileURL
    guard !backup.pathComponents.starts(with: root.pathComponents) else { throw SettingsError.invalid("缓存备份目录必须位于缓存目录以外。") }
    guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return 0 }
    var count = 0
    for case let file as URL in iterator {
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
      guard names.contains(file.lastPathComponent), values?.isRegularFile == true else { continue }
      let canonical = file.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.pathComponents.starts(with: root.pathComponents) else { continue }
      let relative = canonical.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
      let target = backup.appendingPathComponent(relative)
      guard !manager.fileExists(atPath: target.path) else { continue }
      do {
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: file, to: target); count += 1
      } catch { continue } // Protected or concurrently regenerated caches are disposable.
    }
    return count
  }
}

import Foundation
import Darwin

final class QingTypeInstallLock {
  private let descriptor: Int32
  let destination: URL
  init(destination: URL) throws {
    self.destination = destination.standardizedFileURL
    let parent = destination.deletingLastPathComponent()
    guard (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("输入法安装目录包含符号链接。")
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    descriptor = open(parent.appendingPathComponent(".qingtype-install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw SettingsError.invalid("无法创建安装锁，安装已停止。") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw SettingsError.invalid("另一项清言安装正在进行，请稍后重试。") }
  }
  deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

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
                      lock: QingTypeInstallLock? = nil,
                      copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) },
                      validate: (URL) throws -> Void = { _ in },
                      rollback: (Bool) async throws -> Void = { _ in },
                      activate: () async throws -> Void) async throws {
    let manager = FileManager.default
    let sourceVersion = try version(at: source)
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath(),
          (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
          (try? destination.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("输入法安装目标包含链接或与来源相同，已停止安装。")
    }
    let heldLock = try lock ?? QingTypeInstallLock(destination: destination)
    defer { withExtendedLifetime(heldLock) {} }
    guard heldLock.destination == destination.standardizedFileURL else { throw SettingsError.invalid("安装锁与目标不匹配。") }
    let existed = manager.fileExists(atPath: destination.path)
    if existed {
      let currentVersion = try version(at: destination)
      guard sourceVersion.compare(currentVersion, options: .numeric) != .orderedAscending else {
        throw SettingsError.invalid("已安装的输入法比此安装包更新，请使用新版清言应用。")
      }
    }
    let stage = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-stage-\(UUID())")
    var stageContainsOld = false
    defer { if !stageContainsOld { try? manager.removeItem(at: stage) } }
    try copy(source, stage)
    _ = try version(at: stage)
    try validate(stage)
    if existed {
      try manager.createDirectory(at: backups, withIntermediateDirectories: true)
      let task = Process()
      task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      task.arguments = ["-c", "-k", "--keepParent", destination.path, backups.appendingPathComponent("QingType.zip").path]
      task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
      try task.run(); task.waitUntilExit()
      guard task.terminationStatus == 0 else { throw SettingsError.invalid("无法备份旧输入法，请检查可用空间后重试。") }
    }
    var moved = false
    do {
      if existed {
        guard renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        stageContainsOld = true
      } else { try manager.moveItem(at: stage, to: destination) }
      moved = true
      try await activate()
    } catch {
      let original = error.localizedDescription
      do {
        if moved && existed {
          guard renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
          }
          stageContainsOld = false
        } else if moved { try manager.removeItem(at: destination) }
      } catch let recovery {
        throw SettingsError.invalid("安装失败且程序恢复未完成。旧程序：\(stage.path)，备份：\(backups.path)。\(original)；\(recovery.localizedDescription)")
      }
      if moved {
        do { try await rollback(existed) }
        catch { throw SettingsError.invalid("安装失败，程序已恢复，但输入源或缓存恢复未确认。备份：\(backups.path)。\(original)；\(error.localizedDescription)") }
      }
      throw SettingsError.invalid("安装失败，回退操作已完成。\(original)")
    }
    if existed { stageContainsOld = false }
  }
}

enum QingTypeInputCache {
  static let names: Set<String> = ["com.apple.IntlDataCache.le", "com.apple.IntlDataCache.le.kbdx"]
  private static func maySkip(_ error: Error) -> Bool {
    let value = error as NSError
    if value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(ENOENT)].contains(value.code) { return true }
    if value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileNoSuchFileError].contains(value.code) { return true }
    if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { return maySkip(underlying) }
    return false
  }
  static func backUp(root: URL, to backup: URL) throws -> Int {
    let manager = FileManager.default
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let backup = backup.resolvingSymlinksInPath().standardizedFileURL
    guard !backup.pathComponents.starts(with: root.pathComponents) else { throw SettingsError.invalid("缓存备份目录必须位于缓存目录以外。") }
    guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { throw SettingsError.invalid("无法读取输入源缓存目录。") }
    var count = 0
    for case let file as URL in iterator {
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
      guard names.contains(file.lastPathComponent), values?.isRegularFile == true else { continue }
      let canonical = file.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.pathComponents.starts(with: root.pathComponents) else { continue }
      let relative = canonical.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
      let target = backup.appendingPathComponent(relative)
      guard !manager.fileExists(atPath: target.path) else { throw SettingsError.invalid("输入源缓存备份已存在，已停止安装。") }
      try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      do {
        try manager.moveItem(at: file, to: target); count += 1
      } catch {
        if maySkip(error) { continue } // Protected or concurrently regenerated caches are disposable.
        throw error
      }
    }
    return count
  }

  static func restore(root: URL, from backup: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: backup.path) else { return }
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let backup = backup.resolvingSymlinksInPath().standardizedFileURL
    guard !backup.pathComponents.starts(with: root.pathComponents),
          let iterator = manager.enumerator(at: backup, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
      throw SettingsError.invalid("缓存备份目录无效。")
    }
    var failures: [String] = []
    for case let file as URL in iterator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
      guard values.isRegularFile == true, names.contains(file.lastPathComponent) else { continue }
      let canonical = file.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.pathComponents.starts(with: backup.pathComponents) else { throw SettingsError.invalid("缓存备份路径异常。") }
      let relative = canonical.pathComponents.dropFirst(backup.pathComponents.count).joined(separator: "/")
      let target = root.appendingPathComponent(relative)
      do {
        guard !manager.fileExists(atPath: target.path),
              target.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.starts(with: root.pathComponents) else {
          throw SettingsError.invalid("缓存已重新生成或路径改变。")
        }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: file, to: target)
      } catch { failures.append(relative) }
    }
    if !failures.isEmpty { throw SettingsError.invalid("部分缓存未恢复（可能已被其他应用重建），原件保留在 \(backup.path)：\(failures.joined(separator: ", "))") }
  }
}

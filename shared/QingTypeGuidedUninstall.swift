import Foundation

enum QingTypeGuidedUninstall {
  struct RecycleResult {
    var location: URL
    var error: Error? = nil
  }

  /// Both the settings app and developer script use this exact ordering.
  /// Input sources are never modified, so failure recovery restores files only.
  static func run(read: () async throws -> QingTypeGuidedUninstallState,
                  stop: () async throws -> Void,
                  requireStopped: () throws -> Void,
                  acquireDataLock: () throws -> QingTypeDataLock,
                  remove: () async throws -> URL) async throws -> URL {
    try QingTypeUninstallPreflight.requireRemoved(await read())
    try Task.checkCancellation()
    try await stop()
    let lock = try acquireDataLock()
    defer { withExtendedLifetime(lock) {} }
    try QingTypeUninstallPreflight.requireRemoved(await read())
    try requireStopped()
    try Task.checkCancellation()
    return try await remove()
  }

  static func removePrograms(items: [QingTypeUninstallItem], allowed: [URL], userData: URL,
                             staging: URL, afterMove: () throws -> Void = {},
                             recycle: (URL) async throws -> RecycleResult) async throws -> URL {
    guard items.allSatisfy({ $0.kind != nil && $0.url.standardizedFileURL != userData.standardizedFileURL }) else {
      throw SettingsError.invalid("默认卸载仅移除程序，用户数据保留。")
    }
    _ = try QingTypeProgramMaintenance.stageUninstall(items: items, allowed: allowed,
      userData: userData, staging: staging, afterMove: afterMove)
    var location = staging
    do {
      let result = try await recycle(staging)
      location = result.location
      if let error = result.error { throw error }
      return location
    } catch {
      let reason = error.localizedDescription
      do { try QingTypeProgramMaintenance.undoStagedUninstall(location, allowed: allowed) }
      catch { throw SettingsError.invalid("卸载恢复未完成，请保留恢复文件夹 \(location.path)：\(reason)；\(error.localizedDescription)") }
      throw SettingsError.invalid("卸载失败，原程序已恢复，用户数据保留：\(reason)")
    }
  }
}

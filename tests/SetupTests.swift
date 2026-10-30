import Foundation

@main
struct SetupTests {
  static func main() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("qingtype-setup-tests-\(UUID())")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
      guard try condition() else { throw SettingsError.invalid("FAIL: \(name)") }; checks += 1
    }
    func rejects(_ operation: () throws -> Void) throws {
      do { try operation() } catch { checks += 1; return }; throw SettingsError.invalid("Invalid setup input was accepted")
    }
    func rejectsAsync(_ operation: () async throws -> Void) async throws -> Error {
      do { try await operation() } catch { checks += 1; return error }
      throw SettingsError.invalid("Expected setup operation to fail")
    }
    var rejectedUnexpectedSuccess = false
    do { _ = try await rejectsAsync {} } catch { rejectedUnexpectedSuccess = true }
    try expect(rejectedUnexpectedSuccess, "failure assertion rejects a successful operation")
    let factory = QingTypeSettings()
    try expect(factory.schema == "luna_pinyin_simp" && factory.rimeIce == nil && factory.activeModelID == nil && factory.models.isEmpty, "factory input needs no optional component")
    let files = try factory.generatedFiles()
    try expect(files["rime_ice.custom.yaml"] == nil && files["qingtype_ice_main.dict.yaml"] == nil, "factory configuration does not enable Rime Ice")
    try expect(QingTypeWanxiang.filename(schema: "luna_pinyin") == "wanxiang-lts-zh-hant.gram" && QingTypeWanxiang.filename(schema: "rime_ice") == "wanxiang-lts-zh-hans.gram", "model catalog follows selected simplified/traditional schema")
    let asset = QingTypeRelease.Asset(name: "model.gram", browser_download_url: URL(string: "https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/model.gram")!, size: 100, digest: "sha256:" + String(repeating: "a", count: 64))
    try expect(try asset.validate(repository: QingTypeWanxiang.repository, limit: 1024) == String(repeating: "a", count: 64), "official asset metadata yields its checksum")
    var invalid = asset; invalid.digest = nil
    try rejects { _ = try invalid.validate(repository: QingTypeWanxiang.repository, limit: 1024) }
    invalid = asset; invalid.browser_download_url = URL(string: "https://example.com/model.gram")!
    try rejects { _ = try invalid.validate(repository: QingTypeWanxiang.repository, limit: 1024) }
    try rejects { _ = try asset.validate(repository: "someone/else", limit: 1024) }
    try rejects { _ = try asset.validate(repository: QingTypeWanxiang.repository, limit: 99) }
    try expect(QingTypeTransferProgress(received: 150, total: 100).fraction == 1 && QingTypeTransferProgress(received: 0, total: 0).fraction == 0, "progress tolerates missing or changed content length")
    func fakeApp(_ name: String, version: String) throws -> URL {
      let app = root.appendingPathComponent(name)
      try manager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info = ["CFBundleIdentifier": QingTypeAppInstallation.bundleID, "CFBundleExecutable": "QingType", "CFBundleShortVersionString": version]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
      let binary = app.appendingPathComponent("Contents/MacOS/QingType")
      try Data("fixture only".utf8).write(to: binary)
      try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      return app
    }
    let source = try fakeApp("source.app", version: "2")
    let destination = try fakeApp("installed.app", version: "1")
    let backups = root.appendingPathComponent("backups/update")
    try Data("obsolete".utf8).write(to: destination.appendingPathComponent("obsolete-file"))
    try Data("new".utf8).write(to: source.appendingPathComponent("new-file"))
    let userData = root.appendingPathComponent("private-learning.userdb")
    try Data("private learning unchanged".utf8).write(to: userData)
    var activated = false
    try await QingTypeAppInstallation.install(source: source, destination: destination, backups: backups) {
      activated = true
      try expect(try QingTypeAppInstallation.version(at: destination) == "2", "activation sees the new input app")
    }
    try expect(activated && manager.fileExists(atPath: backups.appendingPathComponent("QingType.zip").path), "upgrade retains a ZIP backup")
    try expect(!manager.fileExists(atPath: destination.appendingPathComponent("obsolete-file").path) && manager.fileExists(atPath: destination.appendingPathComponent("new-file").path), "upgrade replaces the complete bundle")
    var blockedConcurrentInstall = false
    try await QingTypeAppInstallation.install(source: source, destination: destination, backups: root.appendingPathComponent("backups/lock")) {
      do { try await QingTypeAppInstallation.install(source: source, destination: destination, backups: backups) {} }
      catch { blockedConcurrentInstall = true }
    }
    try expect(blockedConcurrentInstall, "concurrent install is rejected before another replacement")
    let newer = try fakeApp("newer.app", version: "3")
    var restored = false
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: newer, destination: destination, backups: root.appendingPathComponent("backups/failure"), rollback: { existed in
        restored = existed ? (try QingTypeAppInstallation.version(at: destination)) == "2" : false
      }) {
        throw SettingsError.invalid("simulated activation failure")
      }
    }
    try expect(try QingTypeAppInstallation.version(at: destination) == "2", "failed activation restores previous app")
    try expect(restored, "external state is rolled back after restoring the previous bundle")
    var activatedDuringCopyFailure = false
    var copyAttempted = false
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: newer, destination: destination, backups: backups, copy: { _, stage in
        copyAttempted = true
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: stage.appendingPathComponent("partial"))
        throw SettingsError.invalid("simulated copy failure")
      }) { activatedDuringCopyFailure = true }
    }
    try expect(copyAttempted && !activatedDuringCopyFailure && (try QingTypeAppInstallation.version(at: destination)) == "2", "copy failure leaves previous bundle intact and never activates")
    var activatedDuringInvalidStage = false
    var validationAttempted = false
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: newer, destination: destination, backups: backups, validate: { _ in
        validationAttempted = true
        throw SettingsError.invalid("simulated signature failure")
      }) { activatedDuringInvalidStage = true }
    }
    try expect(validationAttempted && !activatedDuringInvalidStage && (try QingTypeAppInstallation.version(at: destination)) == "2", "staged validation failure leaves previous bundle intact and never activates")
    let recoveryError = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: newer, destination: destination, backups: root.appendingPathComponent("backups/recovery-failure"), rollback: { _ in
        throw SettingsError.invalid("injected source restore failure")
      }) { throw SettingsError.invalid("injected activation failure") }
    }
    try expect(recoveryError.localizedDescription.contains("恢复未确认") && (try QingTypeAppInstallation.version(at: destination)) == "2", "incomplete external recovery is reported even when the bundle was restored")
    let fresh = root.appendingPathComponent("fresh.app")
    var freshActivationAttempted = false
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: source, destination: fresh, backups: backups) {
        freshActivationAttempted = true
        throw SettingsError.invalid("simulated first-install failure")
      }
    }
    try expect(freshActivationAttempted && !manager.fileExists(atPath: fresh.path), "failed first installation removes the unactivated app")
    try await QingTypeAppInstallation.install(source: source, destination: fresh, backups: backups) {}
    try expect(try QingTypeAppInstallation.version(at: fresh) == "2", "fresh installation succeeds")
    try expect(try String(contentsOf: userData, encoding: .utf8) == "private learning unchanged", "app transactions never alter user learning")
    let older = try fakeApp("older.app", version: "1")
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: older, destination: destination, backups: backups) {}
    }
    try expect(try QingTypeAppInstallation.version(at: destination) == "2", "older installation media cannot silently downgrade the input app")
    let link = root.appendingPathComponent("link.app")
    try manager.createSymbolicLink(at: link, withDestinationURL: destination)
    _ = try await rejectsAsync {
      try await QingTypeAppInstallation.install(source: source, destination: link, backups: backups) {}
    }
    try expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true, "symlink install targets are preserved")
    let cache = root.appendingPathComponent("cache"), cacheBackup = root.appendingPathComponent("cache-backup")
    try manager.createDirectory(at: cache, withIntermediateDirectories: true)
    for name in QingTypeInputCache.names { try Data(name.utf8).write(to: cache.appendingPathComponent(name)) }
    try Data("keep preferences".utf8).write(to: cache.appendingPathComponent("preferences.plist"))
    let count = try QingTypeInputCache.backUp(root: cache, to: cacheBackup)
    try expect(count == 2 && manager.fileExists(atPath: cache.appendingPathComponent("preferences.plist").path), "native cache helper moves only the two allowlisted input caches")
    try rejects { _ = try QingTypeInputCache.backUp(root: cache, to: cache.appendingPathComponent("bad")) }
    try expect(try String(contentsOf: cacheBackup.appendingPathComponent("com.apple.IntlDataCache.le"), encoding: .utf8) == "com.apple.IntlDataCache.le", "input-cache backup is recoverable")
    try QingTypeInputCache.restore(root: cache, from: cacheBackup)
    try expect(try String(contentsOf: cache.appendingPathComponent("com.apple.IntlDataCache.le"), encoding: .utf8) == "com.apple.IntlDataCache.le", "cache restore returns original bytes")
    _ = try QingTypeInputCache.backUp(root: cache, to: cacheBackup)
    try Data("new external cache".utf8).write(to: cache.appendingPathComponent("com.apple.IntlDataCache.le"))
    try rejects { try QingTypeInputCache.restore(root: cache, from: cacheBackup) }
    try expect(try String(contentsOf: cache.appendingPathComponent("com.apple.IntlDataCache.le"), encoding: .utf8) == "new external cache", "cache rollback never overwrites a regenerated cache")
    let leftovers = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".qingtype-stage-") }
    try expect(leftovers.isEmpty, "successful and recovered installations leave no duplicate app checkouts")
    print("PASS: \(checks) factory setup, optional catalog, installation rollback and native cache checks")
  }
}

import Foundation

@main
struct MaintenanceRecoveryTests {
  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SettingsError.invalid("FAIL: \(message)") }
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-recovery-tests-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // Backup retention keeps only the newest QingType-owned transaction backups.
    let backups = root.appendingPathComponent("backups")
    try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    func makeDirectory(_ name: String, age: TimeInterval) throws -> URL {
      let url = backups.appendingPathComponent(name)
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
      return url
    }
    let newest = try makeDirectory("install-11111111-1111-4111-8111-111111111111", age: 10)
    let middle = try makeDirectory("apply-22222222-2222-4222-8222-222222222222", age: 100)
    let oldest = try makeDirectory("install-33333333-3333-4333-8333-333333333333", age: 1_000)
    for owned in [newest, middle, oldest] { try QingTypeBackupRetention.markOwned(owned) }
    for (owned, age) in [(newest, 10.0), (middle, 100.0), (oldest, 1_000.0)] {
      try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: owned.path)
    }
    let personal = try makeDirectory("install-personal-copy", age: 2_000)
    let unmarked = try makeDirectory("install-44444444-4444-4444-8444-444444444444", age: 2_000)
    let renamed = backups.appendingPathComponent("install-55555555-5555-4555-8555-555555555555")
    try fm.copyItem(at: oldest, to: renamed)
    let modified = try makeDirectory("install-66666666-6666-4666-8666-666666666666", age: 2_000)
    try QingTypeBackupRetention.markOwned(modified)
    try Data("personal".utf8).write(to: modified.appendingPathComponent("my-copy.txt"))
    let learning = try makeDirectory("learning-backup", age: 1_000)
    let appUpdate = try makeDirectory("app-update-1", age: 1_000)
    try Data("not a backup".utf8).write(to: backups.appendingPathComponent("install-file.txt"))
    let removed = try QingTypeBackupRetention.prune(in: backups, prefixes: ["install-", "apply-"], keeping: 2)
    try expect(removed.map(\.lastPathComponent) == [oldest.lastPathComponent], "retention removes only the oldest owned transaction backup")
    try expect(fm.fileExists(atPath: newest.path) && fm.fileExists(atPath: middle.path),
               "retention keeps the newest backups")
    try expect(fm.fileExists(atPath: learning.path) && fm.fileExists(atPath: appUpdate.path),
               "retention never touches learning backups or app-update receipts")
    try expect(fm.fileExists(atPath: backups.appendingPathComponent("install-file.txt").path),
               "retention never removes plain files")
    try expect([personal, unmarked, renamed, modified].allSatisfy { fm.fileExists(atPath: $0.path) },
               "retention preserves user-named, unmarked, renamed and modified directories")

    // Build artifacts are moved aside and restored, so a failed rebuild is safe.
    try expect(QingTypeBuildRecovery.isCompileFailure(SettingsError.invalid("部署失败：dictionary 'qingtype_main' failed to compile.")),
               "compile failures are recognised")
    try expect(QingTypeBuildRecovery.isCompileFailure(SettingsError.invalid("部署失败：Error translating syllable_id '383'.")),
               "user dictionary syllable errors are recognised")
    try expect(!QingTypeBuildRecovery.isCompileFailure(SettingsError.invalid("输入法尚未退出，请结束当前输入后重试。")),
               "lock errors are not treated as compile failures")
    let build = root.appendingPathComponent("build")
    try fm.createDirectory(at: build.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("table".utf8).write(to: build.appendingPathComponent("qingtype_main.table.bin"))
    try Data("prism".utf8).write(to: build.appendingPathComponent("qingtype_main.prism.yaml"))
    try Data("keep".utf8).write(to: build.appendingPathComponent("notes.txt"))
    try Data("directory".utf8).write(to: build.appendingPathComponent("nested/keep.bin"))
    let buildBackup = root.appendingPathComponent("build-backup")
    let moved = try QingTypeBuildRecovery.moveDerivedArtifacts(in: build, to: buildBackup)
    try expect(moved == 2, "only derived files are moved aside")
    try expect(!fm.fileExists(atPath: build.appendingPathComponent("qingtype_main.table.bin").path),
               "derived table is moved out of the build directory")
    try expect(fm.fileExists(atPath: build.appendingPathComponent("notes.txt").path),
               "unrelated files stay in the build directory")
    try expect(fm.fileExists(atPath: build.appendingPathComponent("nested/keep.bin").path),
               "subdirectories are not touched")
    try QingTypeBuildRecovery.restore(from: buildBackup, to: build)
    try expect(fm.fileExists(atPath: build.appendingPathComponent("qingtype_main.table.bin").path),
               "failed rebuild restores the previous artifacts")
    var missingBackupError: Error?
    do { try QingTypeBuildRecovery.restore(from: root.appendingPathComponent("missing-backup"), to: build) }
    catch { missingBackupError = error }
    try expect(missingBackupError != nil, "a missing recovery backup must not report success")
    let foreignBackup = root.appendingPathComponent("foreign-backup")
    try fm.createDirectory(at: foreignBackup, withIntermediateDirectories: true)
    try Data("personal".utf8).write(to: foreignBackup.appendingPathComponent("notes.txt"))
    var foreignBackupError: Error?
    do { try QingTypeBuildRecovery.restore(from: foreignBackup, to: build) }
    catch { foreignBackupError = error }
    try expect(foreignBackupError != nil && fm.fileExists(atPath: foreignBackup.appendingPathComponent("notes.txt").path),
               "unexpected backup content must be preserved and reported")

    let interrupted = root.appendingPathComponent("interrupted")
    let interruptedBackup = root.appendingPathComponent("interrupted-backup")
    try fm.createDirectory(at: interrupted, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: interrupted.appendingPathComponent("a.bin"))
    try Data("second".utf8).write(to: interrupted.appendingPathComponent("b.yaml"))
    var moves = 0
    var interruptedError: Error?
    do {
      _ = try QingTypeBuildRecovery.moveDerivedArtifacts(in: interrupted, to: interruptedBackup, move: { source, target in
        moves += 1
        if moves == 2 { throw SettingsError.invalid("injected move failure") }
        try fm.moveItem(at: source, to: target)
      })
    } catch { interruptedError = error }
    try expect(interruptedError != nil && moves == 3, "partial move failure must trigger a rollback")
    try expect(try Data(contentsOf: interrupted.appendingPathComponent("a.bin")) == Data("first".utf8),
               "partial move rollback restores the original artifact")
    try expect(try Data(contentsOf: interrupted.appendingPathComponent("b.yaml")) == Data("second".utf8),
               "unmoved artifact remains intact")

    var failedRollbackMoves = 0
    var failedRollback: Error?
    do {
      _ = try QingTypeBuildRecovery.moveDerivedArtifacts(in: interrupted, to: root.appendingPathComponent("failed-rollback"), move: { source, target in
        failedRollbackMoves += 1
        if failedRollbackMoves >= 2 { throw SettingsError.invalid("injected failure") }
        try fm.moveItem(at: source, to: target)
      })
    } catch { failedRollback = error }
    try expect(failedRollback?.localizedDescription.contains("failed-rollback") == true,
               "failed rollback must report the recoverable backup location")
    try expect(fm.fileExists(atPath: root.appendingPathComponent("failed-rollback/a.bin").path),
               "failed rollback retains the original artifact in the reported backup")

    // Signature verification separates a complete install from a damaged one.
    func makeApp(_ name: String) throws -> URL {
      let app = root.appendingPathComponent(name)
      try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info: [String: Any] = ["CFBundleIdentifier": QingTypeAppInstallation.bundleID,
                                 "CFBundleExecutable": "QingType", "CFBundleShortVersionString": "0.6.4"]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      let binary = app.appendingPathComponent("Contents/MacOS/QingType")
      // codesign needs a real Mach-O executable, so reuse a small system binary.
      try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      try fm.createDirectory(at: app.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
      try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                      to: app.appendingPathComponent("Contents/Frameworks/librime.1.dylib"))
      try fm.createDirectory(at: app.appendingPathComponent("Contents/SharedSupport"), withIntermediateDirectories: true)
      try Data("dict".utf8).write(to: app.appendingPathComponent("Contents/SharedSupport/luna_pinyin.dict.yaml"))
      return app
    }
    let app = try makeApp("signed.app")
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", app.path]
    sign.standardOutput = FileHandle.nullDevice
    sign.standardError = FileHandle.nullDevice
    try sign.run(); sign.waitUntilExit()
    try expect(sign.terminationStatus == 0, "ad-hoc signing the fixture succeeds")
    try QingTypeInstallationCheck.verifySignature(at: app)
    var status = QingTypeInstallationCheck.inspect(destination: app, payload: nil,
                                                   signature: QingTypeInstallationCheck.verifySignature)
    try expect(status.state == .installedSameVersion, "a signed complete install reports installed")
    let tampered = FileHandle(forWritingAtPath: app.appendingPathComponent("Contents/MacOS/QingType").path)!
    tampered.seekToEndOfFile(); tampered.write(Data("tampered".utf8)); try tampered.close()
    do {
      try QingTypeInstallationCheck.verifySignature(at: app)
      throw SettingsError.invalid("FAIL: tampered signature was accepted")
    } catch {}
    status = QingTypeInstallationCheck.inspect(destination: app, payload: nil,
                                               signature: QingTypeInstallationCheck.verifySignature)
    try expect(status.state == .corrupted, "signature failure marks the install as corrupted")

    print("PASS: backup retention keeps the newest transaction backups and ignores unrelated entries")
    print("PASS: compile failures move derived artifacts aside and restore them on failure")
    print("PASS: signature verification marks tampered installs as corrupted")
  }
}

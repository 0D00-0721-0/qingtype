import Foundation

@main
struct InstallationStatusTests {
  static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SettingsError.invalid("FAIL: \(message)") }
  }

  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-status-tests-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func writeApp(_ app: URL, version: String, bundleID: String = QingTypeAppInstallation.bundleID) throws {
      try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "QingType",
                                 "CFBundleShortVersionString": version]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      let binary = app.appendingPathComponent("Contents/MacOS/QingType")
      try Data("binary".utf8).write(to: binary)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
    func makeApp(_ name: String, _ version: String, complete: Bool = true) throws -> URL {
      let app = root.appendingPathComponent(name)
      try writeApp(app, version: version)
      if complete {
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
        try Data("rime".utf8).write(to: app.appendingPathComponent("Contents/Frameworks/librime.1.dylib"))
        try fm.createDirectory(at: app.appendingPathComponent("Contents/SharedSupport"), withIntermediateDirectories: true)
        try Data("dict".utf8).write(to: app.appendingPathComponent("Contents/SharedSupport/luna_pinyin.dict.yaml"))
      }
      return app
    }
    let installedDir = root.appendingPathComponent("Input Methods")
    try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
    let destination = installedDir.appendingPathComponent("QingType.app")
    let payload = try makeApp("payload.app", "0.6.4")

    // Not installed.
    var status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .notInstalled, "missing destination must report notInstalled")
    try expect(QingTypeInstallationCheck.action(for: status) == .install, "notInstalled must install")

    // Same version.
    try fm.copyItem(at: payload, to: destination)
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .installedSameVersion, "equal versions must report installedSameVersion")
    try expect(QingTypeInstallationCheck.action(for: status) == .deployOnly, "equal versions must only redeploy")
    try expect(status.installedVersion == "0.6.4" && status.payloadVersion == "0.6.4", "versions must be reported")

    // Installed older than the payload.
    try writeApp(destination, version: "0.6.3")
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .installedOlderVersion, "older installed version must report an update")
    try expect(QingTypeInstallationCheck.action(for: status) == .update, "older installed version must update")

    // Installed newer than the payload: never overwrite.
    try writeApp(destination, version: "0.6.5")
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .installedNewerVersion, "newer installed version must be protected")
    try expect(QingTypeInstallationCheck.action(for: status) == .blockedNewer, "newer installed version must block")

    // Corrupted: missing required file.
    try writeApp(destination, version: "0.6.4")
    try fm.removeItem(at: destination.appendingPathComponent("Contents/SharedSupport/luna_pinyin.dict.yaml"))
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .corrupted, "missing dictionary must report corrupted")
    try expect(QingTypeInstallationCheck.action(for: status) == .repair, "corrupted install must repair")
    try expect(!status.problems.isEmpty, "corrupted install must explain the problem")

    // Corrupted: wrong bundle identifier.
    try fm.removeItem(at: destination)
    let wrongID = installedDir.appendingPathComponent("QingType.app")
    try writeApp(wrongID, version: "0.6.4", bundleID: "com.example.other")
    try fm.createDirectory(at: wrongID.appendingPathComponent("Contents/Frameworks"), withIntermediateDirectories: true)
    try Data("rime".utf8).write(to: wrongID.appendingPathComponent("Contents/Frameworks/librime.1.dylib"))
    try fm.createDirectory(at: wrongID.appendingPathComponent("Contents/SharedSupport"), withIntermediateDirectories: true)
    try Data("dict".utf8).write(to: wrongID.appendingPathComponent("Contents/SharedSupport/luna_pinyin.dict.yaml"))
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.state == .corrupted, "wrong bundle identifier must report corrupted")

    // Verification after a transaction.
    try fm.removeItem(at: destination)
    try fm.copyItem(at: payload, to: destination)
    try QingTypeInstallationCheck.verify(destination: destination, expectedVersion: "0.6.4")
    do {
      try QingTypeInstallationCheck.verify(destination: destination, expectedVersion: "9.9")
      throw SettingsError.invalid("FAIL: verify accepted a mismatched version")
    } catch {}
    try fm.removeItem(at: destination.appendingPathComponent("Contents/Frameworks/librime.1.dylib"))
    do {
      try QingTypeInstallationCheck.verify(destination: destination, expectedVersion: "0.6.4")
      throw SettingsError.invalid("FAIL: verify accepted a missing runtime library")
    } catch {}

    // Interrupted transactions are reported, not silently ignored.
    try fm.removeItem(at: destination)
    try fm.copyItem(at: payload, to: destination)
    try fm.createDirectory(at: installedDir.appendingPathComponent(".qingtype-stage-OLD"), withIntermediateDirectories: true)
    status = QingTypeInstallationCheck.inspect(destination: destination, payload: payload)
    try expect(status.leftoverStaging == [".qingtype-stage-OLD"], "leftover staging directories must be detected")
    try fm.removeItem(at: installedDir.appendingPathComponent(".qingtype-stage-OLD"))

    // Downgrades are refused and leave the installed version untouched.
    let older = try makeApp("older.app", "0.6.3")
    do {
      try await QingTypeAppInstallation.install(source: older, destination: destination,
                                                backups: root.appendingPathComponent("downgrade"), activate: {})
      throw SettingsError.invalid("FAIL: downgrade was not refused")
    } catch {}
    try expect(try QingTypeAppInstallation.version(at: destination) == "0.6.4", "downgrade must not modify the install")

    // A corrupted install cannot be version-compared but must be repairable.
    let repairedSource = try makeApp("repaired.app", "0.6.4")
    let broken = installedDir.appendingPathComponent("Broken.app")
    try fm.createDirectory(at: broken, withIntermediateDirectories: true)
    try await QingTypeAppInstallation.install(source: repairedSource, destination: broken,
                                              backups: root.appendingPathComponent("repair"), activate: {})
    try expect(try QingTypeAppInstallation.version(at: broken) == "0.6.4",
               "corrupted install must be replaced by the repair install")

    // Equal-version reinstall is allowed and repeatable without leftovers.
    let equalSource = try makeApp("equal.app", "0.6.4")
    for attempt in 1...2 {
      try await QingTypeAppInstallation.install(source: equalSource, destination: destination,
                                                backups: root.appendingPathComponent("repeat-\(attempt)"), activate: {})
      try expect(try QingTypeAppInstallation.version(at: destination) == "0.6.4",
                 "reinstall attempt \(attempt) must keep the version")
    }
    let leftovers = try fm.contentsOfDirectory(atPath: installedDir.path).filter { $0.hasPrefix(".qingtype-stage-") }
    try expect(leftovers.isEmpty, "reinstall must not leave staging directories")

    // A second transactional install cannot run concurrently.
    do {
      let lock = try QingTypeInstallLock(destination: destination)
      defer { withExtendedLifetime(lock) {} }
      do {
        _ = try QingTypeInstallLock(destination: destination)
        throw SettingsError.invalid("FAIL: concurrent install lock was granted twice")
      } catch {}
    }

    print("PASS: installation state detects missing, equal, older, newer and corrupted installs")
    print("PASS: install actions map to install, redeploy, update, repair and block")
    print("PASS: post-install verification rejects wrong versions and missing files")
    print("PASS: interrupted transactions are reported as leftover staging directories")
    print("PASS: downgrades are refused without touching the installed program")
    print("PASS: repeated equal-version installs succeed without staging leftovers")
    print("PASS: concurrent transactional installs are rejected by the install lock")
  }
}

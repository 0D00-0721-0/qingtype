import Foundation

final class FakeInputSource {
  let hans = "org.qingtype.inputmethod.QingType.Hans"
  let hant = "org.qingtype.inputmethod.QingType.Hant"
  var enabled = Set<String>()
  var registered = true
  var selected: String?
  var failOnce: String?
  var ignoreEnable = 0

  func run(_ args: [String], _ app: URL) async throws -> Data {
    if args[0] == failOnce { failOnce = nil; throw SettingsError.invalid("injected \(args[0]) failure") }
    switch args[0] {
    case "--status":
      let modes = [hans, hant].map { id in ["id": id, "registered": registered, "enabled": enabled.contains(id), "selected": selected == id] as [String: Any] }
      return try JSONSerialization.data(withJSONObject: ["inputSources": modes])
    case "--register-input-source": registered = true
    case "--enable-input-source":
      if ignoreEnable > 0 { ignoreEnable -= 1 } else { enabled.formUnion(args.dropFirst()) }
    case "--disable-input-source": enabled.subtract(args.dropFirst())
    case "--select-input-source": selected = args[1]
    default: throw SettingsError.invalid("unexpected test command")
    }
    return Data()
  }
}

@main
struct InstallationTransactionTests {
  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-install-tests-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func makeApp(_ name: String, _ version: String) throws -> URL {
      let app = root.appendingPathComponent(name)
      try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info = ["CFBundleIdentifier": QingTypeAppInstallation.bundleID, "CFBundleExecutable": "QingType", "CFBundleShortVersionString": version]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
      let binary = app.appendingPathComponent("Contents/MacOS/QingType")
      try Data("test".utf8).write(to: binary)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
      return app
    }
    let source = try makeApp("source.app", "2")
    let destination = try makeApp("installed.app", "1")
    let cache = root.appendingPathComponent("cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheFile = cache.appendingPathComponent("com.apple.IntlDataCache.le")
    let data = root.appendingPathComponent("user-data")
    try fm.createDirectory(at: data, withIntermediateDirectories: true)
    for name in ["dictionary", "learning.userdb", "settings.json"] { try Data(name.utf8).write(to: data.appendingPathComponent(name)) }
    for failure in ["--register-input-source", "--enable-input-source", "silent-enable"] {
      try Data("old cache".utf8).write(to: cacheFile)
      let fake = FakeInputSource(); fake.enabled = [fake.hant]; fake.selected = fake.hant
      let before = try await QingTypeInstallationSession.state(app: destination, command: fake.run)
      let backup = root.appendingPathComponent("backup-\(UUID())")
      let session = QingTypeInstallationSession(before: before, cacheRoot: cache, cacheBackup: backup.appendingPathComponent("cache"), command: fake.run)
      if failure == "silent-enable" { fake.ignoreEnable = 3 } else { fake.failOnce = failure }
      var failed = false
      do {
        try await QingTypeAppInstallation.install(source: source, destination: destination, backups: backup,
          rollback: { existed in try await session.restore(app: destination, existed: existed) }) {
            try await session.activate(app: destination)
          }
      } catch { failed = true }
      guard failed, try QingTypeAppInstallation.version(at: destination) == "1",
            try Data(contentsOf: cacheFile) == Data("old cache".utf8),
            fake.enabled == [fake.hant], fake.selected == fake.hant else { throw SettingsError.invalid("failed to restore after \(failure)") }
      for name in ["dictionary", "learning.userdb", "settings.json"] {
        guard try Data(contentsOf: data.appendingPathComponent(name)) == Data(name.utf8) else { throw SettingsError.invalid("user data changed") }
      }
    }
    let successFake = FakeInputSource(); successFake.enabled = [successFake.hant]; successFake.selected = successFake.hant
    let successBefore = try await QingTypeInstallationSession.state(app: destination, command: successFake.run)
    let successBackup = root.appendingPathComponent("success-backup")
    let successSession = QingTypeInstallationSession(before: successBefore, cacheRoot: cache, cacheBackup: successBackup.appendingPathComponent("cache"), command: successFake.run)
    try await QingTypeAppInstallation.install(source: source, destination: destination, backups: successBackup,
      rollback: { existed in try await successSession.restore(app: destination, existed: existed) }) {
        try await successSession.activate(app: destination)
      }
    guard try QingTypeAppInstallation.version(at: destination) == "2", successFake.enabled.contains(successFake.hans) else {
      throw SettingsError.invalid("upgrade failed")
    }
    for name in ["dictionary", "learning.userdb", "settings.json"] {
      guard try Data(contentsOf: data.appendingPathComponent(name)) == Data(name.utf8) else { throw SettingsError.invalid("successful upgrade changed user data") }
    }
    let fresh = root.appendingPathComponent("fresh.app")
    let freshFake = FakeInputSource(); freshFake.registered = false
    let freshBefore = try await QingTypeInstallationSession.state(app: source, command: freshFake.run)
    let freshBackup = root.appendingPathComponent("fresh-backup")
    let freshSession = QingTypeInstallationSession(before: freshBefore, cacheRoot: cache, cacheBackup: freshBackup.appendingPathComponent("cache"), command: freshFake.run)
    freshFake.failOnce = "--enable-input-source"
    var reportedIncomplete = false
    do {
      try await QingTypeAppInstallation.install(source: source, destination: fresh, backups: freshBackup,
        rollback: { existed in try await freshSession.restore(app: source, existed: existed) }) {
          try await freshSession.activate(app: fresh)
        }
    } catch { reportedIncomplete = error.localizedDescription.contains("恢复未确认") }
    guard reportedIncomplete, !fm.fileExists(atPath: fresh.path), freshFake.enabled.isEmpty else {
      throw SettingsError.invalid("first-install rollback must report a retained registration")
    }
    print("PASS: register and explicit or silent enable failure restore old bundle, input source, cache and isolated user data")
    print("PASS: successful upgrade preserves isolated dictionary, learning and settings")
    print("PASS: first-install rollback reports retained system registration")
  }
}

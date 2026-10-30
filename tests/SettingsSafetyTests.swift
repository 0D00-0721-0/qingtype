import Foundation

@main
struct SettingsSafetyTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-settings-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
      guard value else { throw SettingsError.invalid("FAIL: \(message)") }
      checks += 1
    }
    func rejects(_ operation: () throws -> Void) throws {
      do { try operation() }
      catch { checks += 1; return }
      throw SettingsError.invalid("Expected a rejected write")
    }

    var settings = QingTypeSettings()
    settings.phrases = [.init(code: "jj", text: "继续加油")]
    try settings.save(to: root)
    let restored = try QingTypeSettings.load(from: root)
    try expect(restored == settings, "settings and Unicode phrases survive restart")

    let originalJSON = try Data(contentsOf: root.appendingPathComponent("settings.json"))
    settings.phrases.append(.init(code: "bad\ncode", text: "不能写入"))
    try rejects { try settings.save(to: root) }
    let unchanged = try Data(contentsOf: root.appendingPathComponent("settings.json"))
    try expect(originalJSON == unchanged, "invalid data leaves saved state intact")
    settings.phrases.removeLast()

    settings.phrases.append(.init(code: "jj", text: "重复编码"))
    try rejects { try settings.save(to: root) }
    settings.phrases.removeLast()

    let patchURL = root.appendingPathComponent("squirrel.custom.yaml")
    let handEdited = Data("patch:\n  style/font_point: 23\n".utf8)
    try handEdited.write(to: patchURL)
    settings.fontSize = 24
    try rejects { try settings.save(to: root) }
    let retained = try Data(contentsOf: patchURL)
    let retainedJSON = try Data(contentsOf: root.appendingPathComponent("settings.json"))
    try expect(retained == handEdited && retainedJSON == originalJSON,
               "manual configuration remains untouched and no partial settings commit occurs")

    try FileManager.default.removeItem(at: patchURL)
    try settings.save(to: root)
    let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
    try expect(try backups.contains { try Data(contentsOf: $0.appendingPathComponent("settings.json")) == originalJSON },
               "previous configuration can be recovered from backup")
    try Data("broken JSON".utf8).write(to: root.appendingPathComponent("settings.json"))
    try rejects { _ = try QingTypeSettings.load(from: root) }
    try expect(QingTypePaths.userDirectory.lastPathComponent == "QingType", "dedicated user directory")
    print("PASS: \(checks) settings safety checks")
  }
}
